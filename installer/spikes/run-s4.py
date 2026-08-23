#!/usr/bin/env python3
"""
Host-side harness for spike S4: Secure Boot, and TPM2 auto-unlock.

Takes the system S3 installed and asks three questions of it:

    ./run-s4.py sb        boot it under Secure Boot with Microsoft keys
    ./run-s4.py enroll    enrol the TPM and rebuild the initramfs
    ./run-s4.py auto      boot again — must NOT ask for a passphrase
    ./run-s4.py notpm     boot with no TPM — must ask for one again
    ./run-s4.py all       all four, in order          (default)
    ./run-s4.py reset     discard S4 state (the S3 disk is left alone)

It works on a COPY of .vm/s3/s3-target.qcow2, so S3's result stays reproducible.

Two things Homebrew's QEMU cannot supply, and where they come from instead:

* **Secure Boot firmware.** There is no `edk2-aarch64-secure-code.fd` in the
  Homebrew build — only i386 and x86_64 have secure variants, and aarch64 has no
  vars template at all. Ubuntu's `qemu-efi-aarch64` package ships
  `AAVMF_CODE.secboot.fd` plus `AAVMF_VARS.ms.fd` with the Microsoft KEK/db
  already enrolled, which is exactly the S4 condition. `fetch_firmware()` pulls
  it out of the build container.
* **A TPM.** `swtpm` from Homebrew, driven over a control socket.

Note what Secure Boot on arm64 does NOT give you: there is no SMM, so the
variable store is not tamper-proof the way it is on x86. Signature enforcement
is real; the threat model is weaker. That is a property of the platform.
"""
import contextlib
import os
import re
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, qemu_prefix, run, to_plain_bash

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPIKES = os.path.join(REPO, "installer", "spikes")
VM = os.path.join(REPO, ".vm", "s4")
FW = os.path.join(REPO, ".vm", "firmware")
S3_DISK = os.path.join(REPO, ".vm", "s3", "s3-target.qcow2")
DISK = os.path.join(VM, "s4-target.qcow2")
VARS = os.path.join(VM, "AAVMF_VARS.fd")
PAYLOAD = os.path.join(VM, "payload.iso")
TPMDIR = os.path.join(VM, "tpm")
TPMSOCK = os.path.join(TPMDIR, "swtpm-sock")

PASSPHRASE = "os7spike"
MEM = "4096"
CPUS = "4"

CODE_SECBOOT = os.path.join(FW, "AAVMF_CODE.secboot.fd")
VARS_MS = os.path.join(FW, "AAVMF_VARS.ms.fd")


# ---------------------------------------------------------------------------
# Firmware and TPM plumbing
# ---------------------------------------------------------------------------
def fetch_firmware():
    """AAVMF with Secure Boot and the Microsoft keys, out of ubuntu:26.04."""
    if os.path.exists(CODE_SECBOOT) and os.path.exists(VARS_MS):
        return
    os.makedirs(FW, exist_ok=True)
    print("    fetching qemu-efi-aarch64 (Secure Boot firmware) …")
    run("docker", "run", "--rm", "--platform", "linux/arm64",
        "-v", f"{FW}:/fw", "ubuntu:26.04", "bash", "-c",
        "set -e; apt-get update -qq >/dev/null 2>&1; "
        "apt-get download qemu-efi-aarch64 >/dev/null 2>&1; "
        "dpkg-deb -x qemu-efi-aarch64_*.deb /x; cp /x/usr/share/AAVMF/* /fw/",
        stdout=subprocess.DEVNULL)
    for f in (CODE_SECBOOT, VARS_MS):
        if not os.path.exists(f):
            raise SystemExit(f"firmware extraction did not produce {f}")


class Tpm:
    """A software TPM 2.0, or nothing at all when `enabled` is false.

    The TPM-less case is a test, not a degradation: L17 requires that a machine
    with no TPM still boots via the passphrase."""

    def __init__(self, enabled):
        self.enabled = enabled
        self.proc = None

    def __enter__(self):
        if not self.enabled:
            return self
        if not shutil.which("swtpm"):
            raise SystemExit("swtpm not found — brew install swtpm")
        os.makedirs(TPMDIR, exist_ok=True)
        for stale in (TPMSOCK,):
            if os.path.exists(stale):
                os.remove(stale)
        # not-need-init,startup-clear: AAVMF on arm64 does not reliably send
        # TPM2_Startup, and an un-started TPM answers every command with
        # TPM_RC_INITIALIZE.
        self.proc = subprocess.Popen(
            ["swtpm", "socket", "--tpm2",
             "--tpmstate", f"dir={TPMDIR}",
             "--ctrl", f"type=unixio,path={TPMSOCK}",
             "--flags", "not-need-init,startup-clear"],
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        for _ in range(100):
            if os.path.exists(TPMSOCK):
                break
            time.sleep(0.05)
        else:
            raise SystemExit("swtpm never created its control socket")
        return self

    def __exit__(self, *exc):
        if self.proc:
            self.proc.send_signal(signal.SIGTERM)
            try:
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()

    def args(self):
        if not self.enabled:
            return []
        return ["-chardev", f"socket,id=chrtpm,path={TPMSOCK}",
                "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", "tpm-tis-device,tpmdev=tpm0"]


def qemu_args(tpm, with_payload=False):
    args = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", CPUS, "-m", MEM,
        "-drive", f"if=pflash,format=raw,file={CODE_SECBOOT},readonly=on",
        "-drive", f"if=pflash,format=raw,file={VARS}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={DISK},format=qcow2",
        "-device", "virtio-blk-pci,drive=target",
    ]
    if with_payload:
        args += ["-drive", f"if=none,id=payload,file={PAYLOAD},format=raw,readonly=on",
                 "-device", "virtio-blk-pci,drive=payload"]
    return args + tpm.args()


def build_payload():
    """The enrolment script, on a labelled ISO, exactly as S3 delivers its own."""
    stage = os.path.join(VM, "payload")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    shutil.copy(os.path.join(SPIKES, "s4-tpm-enroll.sh"), stage)
    with open(os.path.join(stage, "e.sh"), "w") as f:
        f.write(f"""#!/bin/sh
echo BOOTSTRAP-OK
exec bash /mnt/s4-tpm-enroll.sh '{PASSPHRASE}'
""")
    if os.path.exists(PAYLOAD):
        os.remove(PAYLOAD)
    run("hdiutil", "makehybrid", "-iso", "-joliet",
        "-default-volume-name", "OS7S4", "-o", PAYLOAD, stage,
        stdout=subprocess.DEVNULL)


def prepare():
    os.makedirs(VM, exist_ok=True)
    fetch_firmware()
    if not os.path.exists(DISK):
        if not os.path.exists(S3_DISK):
            raise SystemExit(
                f"{S3_DISK} not found.\n"
                "S4 boots the system S3 installed. Run:  ./run-s3.py all")
        print("    copying the S3-installed disk (S3's own copy is left alone) …")
        shutil.copy(S3_DISK, DISK)
    if not os.path.exists(VARS):
        # Fresh Microsoft-key variable store every time it is (re)created, so
        # "Secure Boot was on" is never an artefact of a previous run.
        shutil.copy(VARS_MS, VARS)


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
@contextlib.contextmanager
def booted(logname, tpm_enabled, expect_passphrase, with_payload=False):
    """Boot the installed disk, land on a plain bash prompt, hand back the console.

    `expect_passphrase` is an assertion, not a hint: a prompt that should not be
    there and one that should are both failures, and telling them apart is the
    whole of S4's TPM half."""
    log = os.path.join(VM, logname)
    print(f"    serial   {log}")
    with Tpm(tpm_enabled) as tpm:
        c = Console(qemu_args(tpm, with_payload), log)
        try:
            i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                          r"\blogin:", r"\(initramfs\)", r"Kernel panic",
                          r"Secure Boot.*[Vv]iolation", r"Access Denied"],
                         600, "passphrase prompt or login")
            if i >= 4:
                print(c.text()[-4000:])
                raise SystemExit("boot did not reach a login prompt")
            asked = i <= 2
            if asked != expect_passphrase:
                print(c.text()[-3000:])
                raise SystemExit(
                    f"passphrase prompt: expected={expect_passphrase} got={asked}")
            if asked:
                print("    passphrase prompt appeared (as expected)")
                c.send(PASSPHRASE)
                c.expect([r"\blogin:"], 600, "login prompt")
            else:
                print("    NO passphrase prompt — unlocked without one")
            live_login(c, user="os7")
            to_plain_bash(c)
            yield c
        finally:
            c.close()


def guest(c, cmd, marker, timeout=180):
    """Run a command in the guest and return everything it printed."""
    c.drop()
    c.send(f'echo {marker}-"BEGIN"; {cmd}; echo {marker}-"END"')
    c.expect(rf"{marker}-END", timeout, f"{marker} output")
    return (c.text().split(f"{marker}-BEGIN", 1)[-1]
                    .split(f"{marker}-END", 1)[0]).strip()


def phase_sb():
    print("\n### sb — Secure Boot on, Microsoft keys, no TPM")
    prepare()
    with booted("sb.serial.log", tpm_enabled=False, expect_passphrase=True) as c:
        out = guest(c, "mokutil --sb-state; "
                       "findmnt -no SOURCE,FSTYPE /; "
                       "sudo sbverify --list /boot/efi/EFI/BOOT/BOOTAA64.EFI "
                       "2>&1 | head -4", "S4SB")
        print("\n--- verification ---")
        print(out)
        if not re.search(r"SecureBoot enabled", out):
            raise SystemExit("Secure Boot is NOT enabled in this firmware")
        if not re.search(r"rpool/ROOT/os7_\S+\s+zfs", out):
            raise SystemExit("root is not a rpool/ROOT/os7_* ZFS dataset")
        print("    PASS — booted with Secure Boot enabled, root still on ZFS")
        c.send("sudo poweroff -f")
        time.sleep(5)


def phase_enroll():
    print("\n### enroll — TPM present, seal a key into it")
    prepare()
    build_payload()
    with booted("enroll.serial.log", tpm_enabled=True,
                expect_passphrase=True, with_payload=True) as c:
        cmd = "sudo sh -c 'mount -L OS7S4 /mnt; sh /mnt/e.sh'"
        for attempt in range(1, 4):
            c.drop()
            c.send(cmd)
            try:
                c.expect(r"BOOTSTRAP-OK", 45, "bootstrap acknowledgement")
                break
            except SystemExit:
                print(f"    bootstrap not acknowledged (attempt {attempt}) — retyping")
                c.send("")
        else:
            raise SystemExit("bootstrap never acknowledged over serial")
        i = c.expect([r"S4-ENROLL: COMPLETE", r"S4-ENROLL: FAILED"], 900,
                     "enrolment result")
        if i == 1:
            print(c.text()[-4000:])
            raise SystemExit("TPM enrolment FAILED — see above")
        print("    S4-ENROLL: COMPLETE")
        c.send("sudo sync; sudo poweroff -f")
        time.sleep(8)


def phase_auto():
    print("\n### auto — same TPM, expect NO passphrase prompt")
    prepare()
    with booted("auto.serial.log", tpm_enabled=True, expect_passphrase=False) as c:
        out = guest(c, "mokutil --sb-state; findmnt -no SOURCE,FSTYPE /; "
                       "sudo cryptsetup luksDump /dev/disk/by-partlabel/os7-luks "
                       "| grep -A2 '^Tokens:'", "S4AUTO")
        print("\n--- verification ---")
        print(out)
        if not re.search(r"rpool/ROOT/os7_\S+\s+zfs", out):
            raise SystemExit("root is not a rpool/ROOT/os7_* ZFS dataset")
        print("    PASS — TPM2 unlocked the root pool with no passphrase")
        c.send("sudo poweroff -f")
        time.sleep(5)


def phase_notpm():
    print("\n### notpm — no TPM attached, expect the passphrase prompt back")
    prepare()
    with booted("notpm.serial.log", tpm_enabled=False, expect_passphrase=True) as c:
        out = guest(c, "findmnt -no SOURCE,FSTYPE /; ls /dev/tpm* 2>&1 | head -2",
                    "S4NOTPM")
        print("\n--- verification ---")
        print(out)
        if not re.search(r"rpool/ROOT/os7_\S+\s+zfs", out):
            raise SystemExit("root is not a rpool/ROOT/os7_* ZFS dataset")
        print("    PASS — a TPM-less machine still boots on the passphrase")
        c.send("sudo poweroff -f")
        time.sleep(5)


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        shutil.rmtree(VM, ignore_errors=True)
        print(f"removed {VM}")
        return
    phases = {"sb": phase_sb, "enroll": phase_enroll,
              "auto": phase_auto, "notpm": phase_notpm}
    order = ["sb", "enroll", "auto", "notpm"] if what == "all" else [what]
    for name in order:
        if name not in phases:
            raise SystemExit(__doc__)
        phases[name]()
    if what == "all":
        print("\nS4: PASS")


if __name__ == "__main__":
    main()
