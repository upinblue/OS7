#!/usr/bin/env python3
"""
Host-side harness for spike S6: does TPM2 auto-unlock survive the update cycle?

S4 got a system to unlock from its TPM and then listed, honestly, what it had
not shown:

    "Sealing to PCR 7 survives kernel and initramfs updates (they are not
     measured there) but not a Secure Boot policy change — a shim/dbx update
     or toggling SB will drop the machine back to the passphrase. Nothing here
     tested that, and a fleet needs a recovery story before it happens."

S6 turns that paragraph into observations. Three questions, in order of how
much they cost if the answer is bad:

    1. Does an initramfs rebuild keep auto-unlock working?   (routine, monthly)
    2. What exactly happens when Secure Boot policy changes? (rare, fleet-wide)
    3. Is it repairable without a reinstall?                 (this is U8)

Phases:

    ./run-s6.py baseline    boot the S4 system, record PCR 7, speed up GRUB
    ./run-s6.py initramfs   rebuild the initramfs from scratch
    ./run-s6.py survive     boot again — must NOT ask for a passphrase   [Q1]
    ./run-s6.py policy      swap the SB variable store, boot — must ask   [Q2]
    ./run-s6.py recover     re-seal against the new PCR 7, boot clean     [Q3]
    ./run-s6.py all         all of the above, in order        (default)
    ./run-s6.py reset       discard S6 state (S4's disk is left alone)

Like S4 on S3, this works on a COPY of .vm/s4 — disk, variable store AND the
swtpm state directory, because the sealed key lives in the TPM and copying the
disk without it would test nothing.

HOW THE POLICY CHANGE IS SIMULATED, and its limit: the harness swaps
AAVMF_VARS.ms.fd (Microsoft KEK/db, Secure Boot on) for the stock empty
AAVMF_VARS.fd (no keys, Secure Boot off). That is not a dbx update — issuing
one needs a KEK private key nobody outside Microsoft has. It is a proxy, and it
is the right proxy for this question: PCR 7 measures Secure Boot *policy*, and
what S6 needs to characterise is what happens when that measurement changes,
not which of the several ways of changing it was used. Stated here because the
distinction belongs in the record, not in a footnote.
"""
import contextlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, to_plain_bash

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPIKES = os.path.join(REPO, "installer", "spikes")
VM = os.path.join(REPO, ".vm", "s6")
FW = os.path.join(REPO, ".vm", "firmware")
S4 = os.path.join(REPO, ".vm", "s4")

DISK = os.path.join(VM, "s6-target.qcow2")
VARS_SB = os.path.join(VM, "AAVMF_VARS.sb.fd")      # Microsoft keys, SB on
VARS_NOSB = os.path.join(VM, "AAVMF_VARS.nosb.fd")  # empty store, SB off
PAYLOAD = os.path.join(VM, "payload.iso")
TPMDIR = os.path.join(VM, "tpm")
TPMSOCK = os.path.join(TPMDIR, "swtpm-sock")
STATE = os.path.join(VM, "state.json")

CODE_SECBOOT = os.path.join(FW, "AAVMF_CODE.secboot.fd")
VARS_EMPTY_SRC = os.path.join(FW, "AAVMF_VARS.fd")

PASSPHRASE = "os7spike"
MEM = "4096"
CPUS = "4"


# ---------------------------------------------------------------------------
# State carried between phases, so each one can be re-run on its own.
# ---------------------------------------------------------------------------
def state_get():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {}


def state_put(**kw):
    s = state_get()
    s.update(kw)
    with open(STATE, "w") as f:
        json.dump(s, f, indent=2)


def pcr_of(text):
    """Pull the PCR7=0x… line the guest script prints."""
    m = re.search(r"PCR7=(0x[0-9A-Fa-f]{64}|<none>|\s*\(.*\))", text)
    return m.group(1).strip() if m else None


# ---------------------------------------------------------------------------
# TPM and QEMU plumbing — same shape as run-s4.py, see its notes.
# ---------------------------------------------------------------------------
class Tpm:
    def __init__(self, enabled=True):
        self.enabled = enabled
        self.proc = None

    def __enter__(self):
        if not self.enabled:
            return self
        if not shutil.which("swtpm"):
            raise SystemExit("swtpm not found — brew install swtpm")
        os.makedirs(TPMDIR, exist_ok=True)
        if os.path.exists(TPMSOCK):
            os.remove(TPMSOCK)
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


def qemu_args(tpm, varsfile, with_payload=False):
    args = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", CPUS, "-m", MEM,
        "-drive", f"if=pflash,format=raw,file={CODE_SECBOOT},readonly=on",
        "-drive", f"if=pflash,format=raw,file={varsfile}",
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
    stage = os.path.join(VM, "payload")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    shutil.copy(os.path.join(SPIKES, "s6-update-cycle.sh"), stage)
    with open(os.path.join(stage, "r.sh"), "w") as f:
        f.write('#!/bin/sh\necho BOOTSTRAP-OK\nexec bash /mnt/s6-update-cycle.sh "$@"\n')
    if os.path.exists(PAYLOAD):
        os.remove(PAYLOAD)
    subprocess.run(["hdiutil", "makehybrid", "-iso", "-joliet",
                    "-default-volume-name", "OS7S6", "-o", PAYLOAD, stage],
                   check=True, stdout=subprocess.DEVNULL)


def prepare():
    """Copy S4's finished state — disk, variables AND the TPM — into .vm/s6."""
    os.makedirs(VM, exist_ok=True)
    if not os.path.exists(CODE_SECBOOT):
        raise SystemExit(
            f"{CODE_SECBOOT} not found. Run ./run-s4.py sb once to fetch the firmware.")
    if not os.path.exists(DISK):
        src = os.path.join(S4, "s4-target.qcow2")
        if not os.path.exists(src):
            raise SystemExit(f"{src} not found.\nS6 continues S4. Run:  ./run-s4.py all")
        print("    copying the S4 disk (S4's own copy is left alone) …")
        shutil.copy(src, DISK)
    if not os.path.exists(VARS_SB):
        src = os.path.join(S4, "AAVMF_VARS.fd")
        if not os.path.exists(src):
            raise SystemExit(f"{src} not found — S4 has not run")
        shutil.copy(src, VARS_SB)
    if not os.path.exists(VARS_NOSB):
        # The stock, key-less variable store: Secure Boot off. This is the
        # policy change, see the module docstring.
        shutil.copy(VARS_EMPTY_SRC, VARS_NOSB)
    if not os.path.isdir(TPMDIR):
        src = os.path.join(S4, "tpm")
        if not os.path.isdir(src):
            raise SystemExit(f"{src} not found — the sealed key lives there")
        print("    copying the swtpm state (the sealed key is in it) …")
        shutil.copytree(src, TPMDIR)
        for stale in ("swtpm-sock", ".lock"):
            p = os.path.join(TPMDIR, stale)
            if os.path.exists(p):
                os.remove(p)
    build_payload()


# ---------------------------------------------------------------------------
# Boot / run
# ---------------------------------------------------------------------------
@contextlib.contextmanager
def booted(logname, varsfile, expect_passphrase, tpm_enabled=True):
    """Boot and land on a plain bash prompt.

    `expect_passphrase` is an assertion, exactly as in S4: for S6 it IS the
    result. A prompt that should not be there and one that should are both
    failures, and which one happened is the finding."""
    log = os.path.join(VM, logname)
    print(f"    serial   {log}")
    print(f"    vars     {os.path.basename(varsfile)}")
    with Tpm(tpm_enabled) as tpm:
        c = Console(qemu_args(tpm, varsfile, with_payload=True), log)
        try:
            i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                          r"\blogin:", r"\(initramfs\)", r"Kernel panic",
                          r"Secure Boot.*[Vv]iolation", r"Access Denied",
                          r"Shell>", r"No bootable"],
                         900, "passphrase prompt or login")
            if i >= 4:
                print(c.text()[-4000:])
                raise SystemExit(f"boot did not reach a login prompt (matched #{i})")
            asked = i <= 2
            if asked != expect_passphrase:
                print(c.text()[-3000:])
                raise SystemExit(
                    f"passphrase prompt: expected={expect_passphrase} got={asked}")
            if asked:
                print("    passphrase prompt appeared (as expected)")
                c.send(PASSPHRASE)
                c.expect([r"\blogin:"], 900, "login prompt")
            else:
                print("    NO passphrase prompt — the TPM unlocked it")
            live_login(c, user="os7")
            to_plain_bash(c)
            yield c
        finally:
            c.close()


def run_mode(c, mode, arg="", timeout=1200):
    """Run one mode of the guest script off the payload ISO."""
    cmd = f"sudo sh -c 'mount -L OS7S6 /mnt 2>/dev/null; sh /mnt/r.sh {mode} {arg}'"
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
    up = mode.upper()
    i = c.expect([rf"S6-{up}: COMPLETE", rf"S6-{up}: FAILED"], timeout, f"{mode} result")
    out = c.text()
    if i == 1:
        print(out[-4000:])
        raise SystemExit(f"S6 {mode} FAILED — see above")
    return out


def shutdown(c):
    c.send("sudo sync; sudo poweroff -f")
    time.sleep(8)


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
def phase_baseline():
    print("\n### baseline — the S4 system as it stands: TPM unlock, SB on")
    prepare()
    with booted("baseline.serial.log", VARS_SB, expect_passphrase=False) as c:
        out = run_mode(c, "report", timeout=300)
        pcr = pcr_of(out)
        print(f"\n    PCR 7 (Secure Boot on) = {pcr}")
        if not pcr or not pcr.startswith("0x"):
            raise SystemExit("could not read PCR 7 — the rest of S6 is meaningless")
        state_put(pcr_sb=pcr)
        # Cheaper boots for the five that follow. Not part of the experiment.
        run_mode(c, "grubfast", timeout=600)
        print("    PASS — inherited state is intact, PCR 7 recorded")
        shutdown(c)


def phase_initramfs():
    print("\n### initramfs — rebuild it from scratch, as a kernel update would")
    prepare()
    with booted("initramfs.serial.log", VARS_SB, expect_passphrase=False) as c:
        out = run_mode(c, "initramfs", timeout=1800)
        pcrs = re.findall(r"PCR7=(0x[0-9A-Fa-f]{64})", out)
        if len(pcrs) >= 2:
            print(f"\n    PCR 7 before rebuild = {pcrs[0]}")
            print(f"    PCR 7 after  rebuild = {pcrs[-1]}")
            if pcrs[0] != pcrs[-1]:
                print("    NOTE: PCR 7 CHANGED across an initramfs rebuild.")
                print("          That contradicts the premise in SETUP-PLAN L17.")
                state_put(pcr_changed_by_initramfs=True)
            else:
                print("    PCR 7 unchanged, as L17 assumed")
                state_put(pcr_changed_by_initramfs=False)
        print("    rebuild done and the image still carries the TPM2 pieces")
        shutdown(c)


def phase_survive():
    print("\n### survive — boot the rebuilt initramfs; a passphrase here is a FAIL")
    prepare()
    with booted("survive.serial.log", VARS_SB, expect_passphrase=False) as c:
        out = run_mode(c, "report", timeout=300)
        print("\n--- state after the rebuild ---")
        print(out[-1500:])
        state_put(q1_survives_initramfs_rebuild=True)
        print("    PASS [Q1] — auto-unlock survives an initramfs rebuild")
        shutdown(c)


def phase_policy():
    print("\n### policy — Secure Boot policy changed; a passphrase here is EXPECTED")
    prepare()
    # The policy change itself: a variable store with no Microsoft keys in it.
    with booted("policy.serial.log", VARS_NOSB, expect_passphrase=True) as c:
        out = run_mode(c, "report", timeout=300)
        pcr = pcr_of(out)
        before = state_get().get("pcr_sb")
        print(f"\n    PCR 7 with SB on  = {before}")
        print(f"    PCR 7 with SB off = {pcr}")
        if pcr and before and pcr == before:
            raise SystemExit(
                "PCR 7 did NOT change — the proxy did not actually change policy, "
                "so this phase proves nothing. Investigate before recording a result.")
        state_put(pcr_nosb=pcr, q2_policy_change_breaks_unlock=True)
        print("    PASS [Q2] — a policy change moves PCR 7 and the seal no longer opens.")
        print("    The passphrase still works, so the machine is recoverable, not bricked.")
        shutdown(c)


def phase_recover():
    print("\n### recover — re-seal against the NEW policy, then prove it took")
    prepare()
    print("\n  [1/2] boot on the passphrase and re-enrol")
    with booted("recover-enroll.serial.log", VARS_NOSB, expect_passphrase=True) as c:
        run_mode(c, "reenroll", PASSPHRASE, timeout=900)
        print("    re-enrolled against the current PCR 7")
        shutdown(c)
    print("\n  [2/2] boot again — a passphrase here means recovery does NOT work")
    with booted("recover-verify.serial.log", VARS_NOSB, expect_passphrase=False) as c:
        out = run_mode(c, "report", timeout=300)
        print("\n--- state after recovery ---")
        print(out[-1200:])
        state_put(q3_recoverable_by_reenrolment=True)
        print("    PASS [Q3] — the passphrase alone is enough to restore auto-unlock.")
        print("    U8's recovery story is therefore: escrow a recovery key, detect the")
        print("    fallback, re-enrol unattended on the next boot.")
        shutdown(c)


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        shutil.rmtree(VM, ignore_errors=True)
        print(f"removed {VM}")
        return
    phases = {"baseline": phase_baseline, "initramfs": phase_initramfs,
              "survive": phase_survive, "policy": phase_policy,
              "recover": phase_recover}
    order = (["baseline", "initramfs", "survive", "policy", "recover"]
             if what == "all" else [what])
    for name in order:
        if name not in phases:
            raise SystemExit(__doc__)
        phases[name]()
    if what == "all":
        s = state_get()
        print("\n" + "=" * 70)
        print("S6 summary")
        print(f"  Q1 auto-unlock survives an initramfs rebuild : "
              f"{s.get('q1_survives_initramfs_rebuild')}")
        print(f"  Q2 a policy change breaks it                 : "
              f"{s.get('q2_policy_change_breaks_unlock')}")
        print(f"  Q3 re-enrolment restores it                  : "
              f"{s.get('q3_recoverable_by_reenrolment')}")
        print(f"  PCR 7 SB on  : {s.get('pcr_sb')}")
        print(f"  PCR 7 SB off : {s.get('pcr_nosb')}")
        print("=" * 70)
        print("\nS6: PASS")


if __name__ == "__main__":
    main()
