#!/usr/bin/env python3
"""
Host-side harness for spike S3 (installer/spikes/s3-zfs-luks.sh).

Boots out/os7-arm64.iso in QEMU with a blank target disk, runs the spike inside
the live session, then reboots FROM THE DISK ALONE and checks the pass
criterion: the VM asks for the passphrase and reaches a login prompt served from
rpool/ROOT/os7_*.

The serial-console driving lives in vmconsole.py, which run-s4.py shares.

    ./run-s3.py probe       check the console can be driven; writes nothing
    ./run-s3.py install     lay the system down on a blank disk
    ./run-s3.py boot        boot the installed disk and verify
    ./run-s3.py all         both, in order          (default)
    ./run-s3.py reset       throw the VM state away
"""
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import (Console, live_login, qemu_prefix, run,
                       to_plain_bash)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPIKES = os.path.join(REPO, "installer", "spikes")
VM = os.path.join(REPO, ".vm", "s3")
ISO = os.path.join(REPO, "out", "os7-arm64.iso")
DISK = os.path.join(VM, "s3-target.qcow2")
VARS = os.path.join(VM, "edk2-vars.fd")
PAYLOAD = os.path.join(VM, "payload.iso")

PASSPHRASE = "os7spike"
DISK_SIZE = "40G"
MEM = "6144"
CPUS = "4"


def qemu_args(with_iso, with_payload):
    pre = qemu_prefix()
    code = os.path.join(pre, "share", "qemu", "edk2-aarch64-code.fd")
    args = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", CPUS, "-m", MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={VARS}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={DISK},format=qcow2",
        "-device", "virtio-blk-pci,drive=target",
    ]
    if with_payload:
        args += ["-drive", f"if=none,id=payload,file={PAYLOAD},format=raw,readonly=on",
                 "-device", "virtio-blk-pci,drive=payload"]
    if with_iso:
        args += ["-cdrom", ISO, "-boot", "d"]
    return args


def build_payload():
    """A tiny ISO9660 volume carrying the spike. Read-only, label OS7SPIKE, so
    the one command that has to be typed by hand stays under 50 characters."""
    stage = os.path.join(VM, "payload")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    shutil.copy(os.path.join(SPIKES, "s3-zfs-luks.sh"), stage)

    # b.sh runs inside the live session. It resolves the target disk rather than
    # trusting /dev/vdX ordering: the live medium, the payload and the target are
    # all virtio-blk and their names depend on PCI enumeration.
    #
    # The /mnt path below must match the mount point in the typed bootstrap
    # command in phase_install(). They are deliberately the two halves of one
    # 50-character line, which is the only thing typed by hand in the whole run.
    with open(os.path.join(stage, "b.sh"), "w") as f:
        f.write(f"""#!/bin/sh
echo BOOTSTRAP-OK
LIVE=$(findmnt -no SOURCE /cdrom 2>/dev/null | sed 's/[0-9]*$//')
PAY=$(readlink -f /dev/disk/by-label/OS7SPIKE)
TGT=
for d in /dev/vd?; do
    [ "$d" = "$LIVE" ] && continue
    [ "$d" = "$PAY" ] && continue
    case "$PAY" in "$d"[0-9]*) continue ;; esac
    TGT="$d"; break
done
echo "BOOTSTRAP-TARGET=$TGT  (live=$LIVE payload=$PAY)"
[ -n "$TGT" ] || {{ echo "S3-SPIKE: FAILED - no target disk found"; exit 1; }}
exec bash /mnt/s3-zfs-luks.sh "$TGT" '{PASSPHRASE}'
""")
    if os.path.exists(PAYLOAD):
        os.remove(PAYLOAD)
    run("hdiutil", "makehybrid", "-iso", "-joliet",
        "-default-volume-name", "OS7SPIKE", "-o", PAYLOAD, stage,
        stdout=subprocess.DEVNULL)
    print(f"    payload  {PAYLOAD}")


def prepare(fresh_disk):
    os.makedirs(VM, exist_ok=True)
    if not os.path.exists(ISO):
        raise SystemExit(f"ISO not found: {ISO}\nBuild it with: make build-arm64")
    if fresh_disk:
        # Start phase 1 from a blank disk AND blank firmware: the NVRAM boot
        # entry the install creates is part of what phase 2 has to exercise.
        for stale in (DISK, VARS):
            if os.path.exists(stale):
                os.remove(stale)
    if not os.path.exists(VARS):
        pre = qemu_prefix()
        for c in ("edk2-arm-vars.fd", "edk2-aarch64-vars.fd"):
            src = os.path.join(pre, "share", "qemu", c)
            if os.path.exists(src):
                shutil.copy(src, VARS)
                break
        else:
            raise SystemExit("no EDK2 vars template found")
    if not os.path.exists(DISK):
        run("qemu-img", "create", "-f", "qcow2", DISK, DISK_SIZE,
            stdout=subprocess.DEVNULL)
        print(f"    disk     {DISK} ({DISK_SIZE}, blank)")


def phase_probe():
    """Boot the live ISO and prove the console can be driven. Touches nothing."""
    print("\n### probe — live console only, no disk is written")
    prepare(fresh_disk=False)
    build_payload()
    log = os.path.join(VM, "probe.serial.log")
    print(f"    serial   {log}")
    c = Console(qemu_args(with_iso=True, with_payload=True), log)
    try:
        live_login(c)
        print(f"    logged in; answered {c.replies} terminal queries so far")
        c.settle(quiet=3.0, timeout=60)
        c.drop()
        c.send('echo OS7-PROBE-"PWSH-ALIVE"')
        try:
            c.expect(r"OS7-PROBE-PWSH-ALIVE", 30, "echo from pwsh")
            print("    pwsh survived and executes commands")
        except SystemExit:
            print("    pwsh did NOT echo")
        to_plain_bash(c)
        print("    plain bash reached")
        c.drop()
        c.send("sudo sh -c 'mount -L OS7SPIKE /mnt; ls /mnt; blkid | tr \"\\n\" \"|\"'")
        c.expect(r"s3-zfs-luks\.sh", 60, "payload listing")
        c.settle(quiet=2.0, timeout=30)
        print("\n--- last console output ---")
        print(c.text()[-2500:])
        print(f"\n    terminal queries answered: {c.replies}")
        print("PROBE: PASS")
    finally:
        c.close()


def phase_install():
    print("\n### phase 1 — install onto a blank disk")
    prepare(fresh_disk=True)
    build_payload()
    log = os.path.join(VM, "install.serial.log")
    print(f"    serial   {log}")
    c = Console(qemu_args(with_iso=True, with_payload=True), log)
    try:
        live_login(c)
        print("    live session up")
        to_plain_bash(c)

        # The only hand-typed command of the whole run. Acknowledged by
        # BOOTSTRAP-OK; retyped rather than assumed if it never arrives.
        cmd = "sudo sh -c 'mount -L OS7SPIKE /mnt; sh /mnt/b.sh'"
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

        print("    spike running (unsquashfs of ~2 GB takes a while)")
        i = c.expect([r"S3-SPIKE: INSTALL COMPLETE", r"S3-SPIKE: FAILED"],
                     3600, "spike result")
        if i == 1:
            print(c.text()[-4000:])
            raise SystemExit("S3 install phase FAILED — see the log above")
        print("    S3-SPIKE: INSTALL COMPLETE")
        c.send("sudo sync; sudo poweroff -f")
        time.sleep(8)
    finally:
        c.close()


def phase_boot():
    print("\n### phase 2 — boot the installed disk, nothing else attached")
    prepare(fresh_disk=False)
    log = os.path.join(VM, "boot.serial.log")
    print(f"    serial   {log}")
    c = Console(qemu_args(with_iso=False, with_payload=False), log)
    try:
        # Watch for the failure signature as well as the success one: dropping
        # to (initramfs) is the exact shape of "LUKS never opened" or "the pool
        # never imported", and waiting out the full timeout for it wastes a
        # cycle and tells you less.
        i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                      r"\(initramfs\)", r"Kernel panic"],
                     420, "LUKS passphrase prompt")
        if i >= 3:
            print(c.text()[-4000:])
            raise SystemExit("dropped to the initramfs — root was never mounted")
        print("    PASS 1/3 — the passphrase prompt appeared")
        c.send(PASSPHRASE)

        j = c.expect([r"\blogin:", r"\(initramfs\)", r"Kernel panic",
                      r"No key available", r"Failed to import pool"],
                     900, "login prompt")
        if j >= 1:
            print(c.text()[-4000:])
            raise SystemExit("never reached a login prompt")
        print("    PASS 2/3 — reached a login prompt")
        live_login(c, user="os7")          # the spike leaves it passwordless
        to_plain_bash(c)

        c.drop()
        # The markers are split with quotes so the shell's own echo of the
        # command cannot be mistaken for the command's output.
        c.send('echo S3-VERIFY-"BEGIN"; findmnt -no SOURCE,FSTYPE /; '
               'cat /proc/cmdline; zfs list -o name,mountpoint; '
               'zpool list; '
               # lsblk needs no privileges and shows the whole stack in one
               # view: partition -> crypt -> zfs_member. `cryptsetup status`
               # would need root, and sudo stops to ask for a password.
               'lsblk -o NAME,TYPE,FSTYPE,SIZE; '
               'echo S3-VERIFY-"END"')
        c.expect(r"S3-VERIFY-END", 180, "verification output")
        body = (c.text().split("S3-VERIFY-BEGIN", 1)[-1]
                        .split("S3-VERIFY-END", 1)[0])
        print("\n--- verification ---")
        print(body.strip())
        if not re.search(r"rpool/ROOT/os7_\S+\s+zfs", body):
            raise SystemExit("root is NOT a rpool/ROOT/os7_* ZFS dataset")
        print("    PASS 3/3 — / is served from rpool/ROOT/os7_*")
        print("\nS3: PASS")
        c.send("sudo poweroff -f")
        time.sleep(5)
    finally:
        c.close()


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        shutil.rmtree(VM, ignore_errors=True)
        print(f"removed {VM}")
        return
    if what == "probe":
        phase_probe()
        return
    if what in ("install", "all"):
        phase_install()
    if what in ("boot", "all"):
        phase_boot()
    if what not in ("install", "boot", "all"):
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
