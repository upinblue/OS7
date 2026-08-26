#!/usr/bin/env python3
"""
S5 — clone, change, activate, reboot, roll back. And two other firsts.

docs/RELEASE-AND-UPDATE-PLAN.md §10 Phase 0 lists S5 as the last open gate spike:
*does the clone-update-activate-rollback cycle work at all.* S6 and S7 passed on
2026-08-23 and -24; this is the one that gates `Update-OS7`, and until it passed
the product's headline promise — rollback-safe updates — was a sentence with no
machine behind it.

    ./run-s5.py install   install from the current ISO, WITH A TPM ATTACHED
    ./run-s5.py boot      boot the disk alone and type NO passphrase
    ./run-s5.py cycle     clone -> change -> activate -> reboot -> roll back
    ./run-s5.py all       all three, in one sitting                  (default)
    ./run-s5.py reset     discard the VM state

THREE THINGS ARE PROVED HERE AND THEY ARE DELIBERATELY IN ONE HARNESS, because
they need the same expensive fixture — an installed machine — and because two of
them have never run at all:

  1. TPM2 ENROLMENT, for the first time ever. `TpmEnrolStep` has existed since
     Phase 3 and every run so far was on a VM with no TPM, so it took its "no TPM
     on this machine" path and reported success for a path it never entered
     (docs/HANDOFF.md §2). `install` attaches swtpm; `boot` then types NOTHING at
     the passphrase prompt and requires a login prompt anyway. That is the only
     evidence that counts: the machine unlocked itself.
  2. THE CURATED IMAGE, on the installed system rather than in the ISO.
     CURATION-AND-DELIVERY-PLAN C2 removes the .NET SDK and §4.2 swaps
     linux-generic for linux-image-generic; the second one could take the ZFS
     module with it, and the failure mode is a machine that does not boot. So
     `boot` asks the booted machine what it has.
  3. THE S5 CYCLE ITSELF.

WHY THE PHASES ARE SEPARATE, and it is the same reason run-phase3 splits them:
`boot` and every step of `cycle` attach NO ISO. A VM with the setup medium still
in it can boot from the medium and look exactly like a working installed system.

WHY NOT A ONE-SHOT `grub-reboot` INSTEAD OF ACTIVATING. Measured: this machine
mounts with `zfs mount -a` and has no zfs-list.cache, so an environment that is
booted without being activated gets the ACTIVATED environment's /boot and
/var/lib/dpkg — the half-activated pair RELEASE-AND-UPDATE-PLAN §4.3 forbids.
Activation is therefore the only supported switch, and it is reversible, which is
what `Restore-OS7` is.
"""

import os
import re
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, qemu_prefix, to_plain_bash    # noqa: E402
from vmscreen import Lab                                                # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PASSPHRASE = "os7-s5-passphrase"
PASSWORD = "os7-s5-password"
HOSTNAME = "os7-s5"
USERNAME = "os7admin"

# The release the cloned boot environment is named for. It is a LABEL, not an
# update: there is no OS/7 release to apply yet (CURATION-AND-DELIVERY-PLAN C7),
# and pretending otherwise is the one thing §5 says makes a version number worse
# than none. What the clone actually gets is one package, below.
NEXT_RELEASE = "1.0.1.0"

# The change that makes the two environments distinguishable at a glance, and
# distinguishable in the only place that matters — the package database, which
# is INSIDE the boot environment by decision D10. `hello` is 144 KiB, is in the
# pinned snapshot (checked before this was written), and depends on libc alone.
MARKER_PACKAGE = "hello"

# The change that must survive the same rollback the package must not, and the
# two together are what SETUP-PLAN §4.4's split means: package state is INSIDE
# the boot environment, the user's files are OUTSIDE it. Added 2026-08-26 with
# BUILD-NOTES #74 — until then no harness here had ever looked at /home, and the
# machine this repository installs kept the home inside the boot environment
# where a rollback un-said it.
HOME_MARKER = f"/home/{USERNAME}/s5-written-in-the-clone.txt"

lab = Lab("s5", target_gb=24, iso_as_disk=True, nic=True)

TPMDIR = os.path.join(lab.dir, "tpm")
TPMSOCK = os.path.join(TPMDIR, "swtpm-sock")

TARGET = "/dev/disk/by-id/virtio-os7target"
LIVE_CMDLINE = "boot=casper fbcon=nodefer quiet console=ttyAMA0,115200"

_mark = 0


# ---------------------------------------------------------------------------
# The software TPM. Lifted from installer/spikes/run-s4.py, which is where it
# was made to work — including the two flags that are not obvious.
# ---------------------------------------------------------------------------
class Tpm:
    """A software TPM 2.0, or nothing at all when `enabled` is false."""

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
        # not-need-init,startup-clear: AAVMF on arm64 does not reliably send
        # TPM2_Startup, and an un-started TPM answers every command with
        # TPM_RC_INITIALIZE. run-s4.py found this; it is not guesswork.
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


def disk_only_args():
    """QEMU with the target disk, the TPM, and no medium of any kind.

    The same shape as run-phase3's, and for the same reason: the bootloader is
    part of what is under test, so the firmware has to find it on the ESP by
    itself. The TPM is attached here as well as during the install, because a
    sealed key with no TPM to unseal it is the L17 case and not this one.
    """
    pre = qemu_prefix()
    code = os.path.join(pre, "share", "qemu", "edk2-aarch64-code.fd")
    return [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", lab.CPUS, "-m", lab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={lab.vars}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={lab.target},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]


def ask(c, command, label, timeout=240):
    """Run something in the guest and return everything it printed.

    THE MARKER IS BUILT BY THE SHELL, NOT TYPED (BUILD-NOTES #16): `…; echo DONE`
    matches the shell's echo of the command as it is typed, so `expect` returns
    before the command has run.
    """
    global _mark
    _mark += 1
    n = _mark
    c.drop()
    c.send(f"{command}; printf 'OK%s\\n' {n}")
    c.expect(f"OK{n}", timeout, label)
    return c.text()


def body_of(text, command_fragment):
    """What a command printed, with the echo of the command itself dropped.

    CARRIAGE RETURNS ARE STRIPPED HERE, once, for everything. A serial console
    ends every line with CR LF, so a regex anchored with `$` under re.MULTILINE
    matches nothing — and the check does not fail, it silently passes. That cost
    a run: the assertion that the clone carries no canmount=on dataset was
    anchored with a dollar, was green, and the clone had three of them.
    """
    body = text.split(command_fragment, 1)[-1] if command_fragment in text else text
    return body.replace("\r", "")


def ps(c, script, label, timeout=300):
    """One OS7 cmdlet, through a fresh pwsh.

    NOT an interactive PowerShell session. BUILD-NOTES #16: PSReadLine repaints,
    answers terminal queries it never gets, and dies on a serial line — every
    harness here drops to `bash --norc` for exactly that reason. `pwsh -Command`
    per command keeps the shell that is being driven a plain bash one, and gives
    each cmdlet a clean exit code.

    SINGLE-QUOTED, and it is not a style choice: PowerShell and the shell share
    the `$` sigil, so under double quotes bash would expand `$false` to nothing
    and hand pwsh a bare `-Confirm:` — a syntax error reported as a cmdlet
    failure, about the wrong thing. The price is that the script may not contain
    a single quote, which is asserted rather than trusted.
    """
    if "'" in script:
        raise SystemExit(f"ps() script contains a single quote and cannot be sent: {script}")
    return ask(c, f"pwsh -NoProfile -Command '{script}' 2>&1", label, timeout)


# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
def write_plan(c):
    plan = ('{"version":1,"intent":"Install","language":"de_DE.UTF-8",'
            '"keyboard":"de","timezone":"Europe/Berlin","mode":"Headless",'
            f'"storage":{{"disk":"{TARGET}","layout":"single","efiMiB":512,'
            '"bpoolGiB":2,"encrypt":true,"swap":"zram"},'
            f'"account":{{"hostname":"{HOSTNAME}","username":"{USERNAME}",'
            '"fullName":"OS/7 S5"},'
            '"network":{"interface":"auto","kind":"Wired","method":"Dhcp"}}')
    c.drop()
    c.send(f"printf '%s' '{plan}' > /tmp/plan.json")
    c.send(f"printf '%s' '{PASSPHRASE}' > /tmp/pass")
    c.send(f"printf '%s' '{PASSWORD}' > /tmp/pw")
    ask(c, "wc -c /tmp/plan.json /tmp/pass /tmp/pw", "plan files")


def phase_install():
    print("\n### install — unattended, with a TPM attached")
    lab.prepare()

    with Tpm() as tpm:
        args = lab.qemu_args(LIVE_CMDLINE, payload=False) + tpm.args()
        c = Console(args, os.path.join(lab.dir, "install.serial.log"))
        try:
            live_login(c)
            to_plain_bash(c)

            # THE FIXTURE ITSELF IS CHECKED FIRST. Every Phase 3 run so far
            # believed it was exercising TpmEnrolStep and was not, because the
            # step's first act is to look for /sys/class/tpm/tpm0 and quietly
            # take the other path. A harness that cannot see the TPM would
            # repeat that mistake in a new file.
            text = ask(c, "ls -d /sys/class/tpm/tpm0 2>&1", "the guest's TPM")
            if "/sys/class/tpm/tpm0" not in body_of(text, "2>&1"):
                print("      FAIL  the guest has no TPM — swtpm is not reaching it,")
                print("            and this run would test the same nothing as every")
                print("            run before it")
                return False
            print("      ok    the guest can see a TPM")

            write_plan(c)
            text = ask(c, "sudo os7-setup --unattend /tmp/plan.json "
                          "--passphrase-file /tmp/pass --password-file /tmp/pw",
                       "unattended install", timeout=2400)
            for line in text.splitlines():
                s = line.strip()
                if "OS7-SETUP" in s or ">>>" in s or "!!!" in s or "TPM" in s:
                    print("        " + s)
            if "OS7-SETUP-DONE install" not in text:
                print("      FAIL  the install did not finish")
                for line in text.replace("\r", "").splitlines()[-25:]:
                    if line.strip():
                        print("        " + line.strip())
                return False
            print("      ok    Setup reported a finished install")

            # Did the enrolment actually run, or did it take the no-TPM path
            # again? The step prints one of two sentences and they are not the
            # same claim.
            if "no TPM on this machine" in text:
                print("      FAIL  Setup still took the no-TPM path")
                return False
            if "enrolling the TPM" in text:
                print("      ok    Setup entered the enrolment path")
            else:
                # Expected, and not a warning: os7-setup prints step headings to
                # the console and the chroot's own output to its log. What the
                # enrolment actually did is read from
                # /var/log/os7-setup/install.log in `boot`, on the machine.
                print("      note  the console shows headings only; `boot` reads the log")

            text = ask(c, "zpool list -H -o name || true", "imported pools")
            if re.search(r"\b[rb]pool\b", body_of(text, "|| true")):
                print("      FAIL  a pool is still imported after the install")
                return False
            print("      ok    the installer exported both pools")
            return True
        finally:
            c.close()


# ---------------------------------------------------------------------------
# boot
# ---------------------------------------------------------------------------
class Machine:
    """One boot of the installed disk, to a root shell.

    `expect_unlock=True` means: this boot must NOT ask for a passphrase. That is
    the whole TPM assertion and it is expressed as a fixture rather than as a
    check, because everything after it needs a shell either way — a run that
    stopped at the first failure would leave the rollback untested for a reason
    that has nothing to do with rollback.
    """

    def __init__(self, label, expect_unlock=True, tpm=True):
        self.label = label
        self.expect_unlock = expect_unlock
        self.tpm = Tpm(tpm)
        self.unlocked_by_tpm = None
        self.c = None

    def __enter__(self):
        self.tpm.__enter__()
        self.c = Console(disk_only_args() + self.tpm.args(),
                         os.path.join(lab.dir, f"{self.label}.serial.log"))
        c = self.c
        i = c.expect([r"\blogin:", r"unlock disk", r"Enter passphrase", r"passphrase for",
                      r"\(initramfs\)", r"Kernel panic", r"No bootable"],
                     900, "a login prompt or a passphrase prompt")
        if i >= 4:
            print(c.text()[-3000:])
            raise SystemExit(f"{self.label}: the machine did not start")
        self.unlocked_by_tpm = (i == 0)
        if not self.unlocked_by_tpm:
            # Type it, so that whatever this run was really about can still be
            # measured. The verdict is on self.unlocked_by_tpm, not on getting in.
            c.send(PASSPHRASE)
            c.expect([r"\blogin:"], 900, "a login prompt")
        live_login(c, user=USERNAME, password=PASSWORD)
        to_plain_bash(c)
        c.drop()
        c.send(f"sudo -S true <<< '{PASSWORD}' 2>/dev/null; sudo -i bash --norc")
        c.expect(r"bash-\d[\d.]*#", 90, "a root shell")
        return self

    def power_off(self, timeout=180):
        """Shut the machine down and WAIT for QEMU to exit.

        Not `reboot` followed by killing QEMU a few seconds later, which is what
        this did first: the pool would then be left without a clean export, and
        while ZFS survives that, the next boot is no longer testing the thing
        the run is about. Waiting for the process to go is the acknowledgement —
        the guest's own last words are not, because the serial line stops being
        read at exactly the wrong moment.
        """
        self.c.send("sync; systemctl poweroff")
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.c.proc.poll() is not None:
                print("      ok         the machine powered off cleanly")
                return True
            time.sleep(0.5)
        print("      note       the machine did not power off within "
              f"{timeout}s; taking the VM down anyway")
        return False

    def __exit__(self, *exc):
        try:
            self.c.close()
        finally:
            self.tpm.__exit__()


def phase_boot():
    print("\n### boot — the disk alone. NOTHING is typed at the passphrase prompt.")
    for need, what in ((lab.target, "an installed disk"),
                       (lab.vars, "a firmware variable store")):
        if not os.path.exists(need):
            print(f"      FAIL  no {what} at {need}. Run `./run-s5.py install` first.")
            return False

    ok = True
    with Machine("boot") as m:
        c = m.c
        if m.unlocked_by_tpm:
            print("      ok    1/7 THE TPM UNLOCKED THE DISK — no passphrase was typed")
        else:
            print("      FAIL  1/7 the machine asked for the passphrase: the TPM did not")
            print("                unlock it. Everything below still runs.")
            ok = False

        # THE ENROLMENT STEP'S OWN WORDS, from the install log ON THIS MACHINE.
        # Not from the serial line: os7-setup prints step headings to the console
        # and the chroot output to its log, so `install` can only report that the
        # step ran. Whether it worked is written here — L31 is what makes this
        # readable at all, the log used to die with the live session.
        text = ask(c, "printf 'S5-%s\\n' BEGIN; findmnt -no SOURCE,FSTYPE /; "
                      "cat /proc/cmdline; "
                      "systemd-cryptenroll /dev/disk/by-partlabel/os7-luks 2>&1 | head -5; "
                      "grep -iE 'tpm|tss2|sealed|MISSING' /var/log/os7-setup/install.log "
                      "| tail -12",
                   "what the machine is", timeout=180)
        body = body_of(text, "S5-BEGIN")
        print("\n--- the installed system ---")
        print(body.strip()[:1200])
        print("---")

        if "rpool/ROOT/os7_" in body and "zfs" in body:
            print("      ok    2/7 / is a boot environment on ZFS")
        else:
            print("      FAIL  2/7 / is not a boot environment")
            ok = False
        if "boot=zfs" in body:
            print("      ok    3/7 boot=zfs is on the kernel command line")
        else:
            print("      FAIL  3/7 boot=zfs is missing")
            ok = False
        if re.search(r"\btpm2\b", body):
            print("      ok    4/7 the LUKS header carries a tpm2 token")
        else:
            print("      note  4/7 no tpm2 token listed (the header may not be at that path)")

        # -- C2 and §4.2, on the machine rather than in the ISO ---------------
        # ${db:Status-Abbrev}, NOT just ${Package}. dpkg-query -W lists every
        # package dpkg KNOWS OF, installed or not — so an image that merely has
        # a record of linux-headers reports it as present. The first version of
        # this check did exactly that and called a correct image broken.
        text = ask(c, "printf 'S5-%s\\n' PKG; "
                      "dpkg-query -W -f='${db:Status-Abbrev} ${Package}\\n' 'dotnet-sdk*' "
                      "'dotnet-runtime*' 'aspnetcore-runtime*' 'linux-headers*' 'linux-generic' "
                      "'linux-image-generic' 'linux-main-modules-zfs*' 2>/dev/null "
                      "| awk '$1 ~ /^i/ {print $2}' | sort; "
                      "printf 'S5-%s\\n' MOD; find /lib/modules -name 'zfs.ko*' | head -2; "
                      "printf 'S5-%s\\n' WIFI; ls /lib/modules/*/kernel/drivers/net/wireless/ | wc -l",
                   "the curated package set", timeout=180)
        pkg = body_of(text, "S5-PKG")
        print("\n--- what the installed system carries ---")
        print(pkg.strip()[:1200])
        print("---")

        if re.search(r"^dotnet-sdk", pkg, re.M):
            print("      FAIL  5/7 the .NET SDK is still installed (C2)")
            ok = False
        else:
            print("      ok    5/7 no .NET SDK (C2)")
        if "dotnet-runtime-10.0" in pkg and "aspnetcore-runtime-10.0" in pkg:
            print("      ok         the .NET runtime is there, as C2 requires")
        else:
            print("      FAIL       the .NET runtime is missing — C2 keeps it")
            ok = False
        if re.search(r"^linux-headers", pkg, re.M):
            print("      FAIL  6/7 kernel headers are still installed (§4.2)")
            ok = False
        else:
            print("      ok    6/7 no kernel headers (§4.2)")
        # THE ONE THAT DECIDES WHETHER THE SWAP WAS SAFE. The machine booted
        # from ZFS, so the module loaded — this says which package still ships
        # it, which is the claim §4.2 makes and the one that could have been
        # wrong.
        if "linux-main-modules-zfs" in pkg and "zfs.ko" in body_of(text, "S5-MOD"):
            print("      ok    7/7 zfs.ko is on the disk and its package survived the swap")
        else:
            print("      FAIL  7/7 the ZFS module package did not survive the swap")
            ok = False
        # THE COUNT THE SWAP COULD HAVE CHANGED AND MUST NOT. Measured on the
        # machine built before it (ISO 1.0.0.78): 19 directories. The swap drops
        # linux-headers and the linux-tools chain and touches
        # linux-modules-<abi>-generic, where the drivers live, not at all — so
        # the right assertion is "unchanged", not "some".
        wifi = body_of(text, "S5-WIFI").strip().splitlines()
        n = next((w.strip() for w in wifi if w.strip().isdigit()), "?")
        if n == "19":
            print(f"      ok         {n} wireless driver directories — unchanged by the swap")
        else:
            print(f"      FAIL       {n} wireless driver directories; it was 19 before the swap")
            ok = False
    return ok


# ---------------------------------------------------------------------------
# cycle — the spike itself
# ---------------------------------------------------------------------------
def be_table(c, label="boot environments"):
    text = ps(c, "Import-Module OS7; Get-OS7BootEnvironment | "
                 "Format-Table Name,Active,Menu,Complete,Release -AutoSize | Out-String -Width 200",
              label)
    body = body_of(text, "Out-String -Width 200")
    print("\n--- " + label + " ---")
    print(body.strip()[:1500])
    print("---")
    return body


# Assemble the clone and change it. This is docs/RELEASE-AND-UPDATE-PLAN.md
# §4.2 steps 3 to 5, performed by hand because `Update-OS7` cannot do it yet —
# there is no OS/7 release to apply (CURATION-AND-DELIVERY-PLAN C7). Doing it
# here rather than skipping it is the difference between testing a rollback and
# testing a `zfs clone`: the two environments have to actually DIFFER.
ASSEMBLE = r"""
set -e
BE=$1
M=/mnt/be
mkdir -p $M
mount -t zfs -o zfsutil rpool/ROOT/$BE $M
for d in var/lib/dpkg var/lib/apt var/cache; do
  ds=rpool/ROOT/$BE/$d
  if ! zfs list -H -o name $ds >/dev/null 2>&1; then continue; fi
  if zfs list -H -o canmount $ds 2>/dev/null | grep -q off; then continue; fi
  mount -t zfs -o zfsutil $ds $M/$d
done
mount -t zfs -o zfsutil bpool/BOOT/$BE $M/boot
mount --bind /boot/efi $M/boot/efi
mount --bind /var/log $M/var/log
for d in dev proc sys run; do
  mount --rbind /$d $M/$d
  mount --make-rslave $M/$d
done
echo ASSEMBLED
"""

DISASSEMBLE = r"""
M=/mnt/be
for p in $(awk '{print $2}' /proc/mounts | grep "^$M" | sort -r); do
  umount -l $p 2>/dev/null || true
done
echo DISASSEMBLED
"""


def send_script(c, name, text):
    """Write a shell script into the guest, one printf per line.

    Not a heredoc: `expect` would have to match a terminator that the typed text
    itself contains, which is the exact shape BUILD-NOTES #16 warns about.
    """
    c.drop()
    c.send(f": > /tmp/{name}")
    for line in text.strip().splitlines():
        # NOT escaping backslashes: printf %s passes its argument through
        # verbatim, so doubling them here would put them in the file twice.
        safe = line.replace("'", "'\\''")
        c.send(f"printf '%s\\n' '{safe}' >> /tmp/{name}")
    ask(c, f"wc -l /tmp/{name}", f"{name} written")


def phase_cycle():
    print("\n### cycle — clone, change, activate, reboot, roll back")
    ok = True

    # ---- 1. clone and change, on the machine as installed -------------------
    with Machine("cycle-1") as m:
        c = m.c
        before = be_table(c, "before")
        first = re.search(r"os7_[0-9.]+_\d{12}", before)
        if not first:
            print("      FAIL  Get-OS7BootEnvironment listed nothing")
            return False
        old_be = first.group(0)
        print(f"      ok    1/9 Get-OS7BootEnvironment sees the installed environment: {old_be}")

        text = ps(c, "Import-Module OS7; "
                     f"$be = New-OS7BootEnvironment -Release {NEXT_RELEASE} -Confirm:$false; "
                     "$be.Name",
                  "clone the pair", timeout=600)
        made = re.search(r"os7_" + re.escape(NEXT_RELEASE) + r"_\d{12}", text)
        if not made:
            print("      FAIL  2/9 the clone did not happen")
            print(text.replace("\r", "")[-1500:])
            return False
        new_be = made.group(0)
        print(f"      ok    2/9 cloned: {new_be}")

        # THE HAZARD, asked rather than assumed. A clone whose datasets kept
        # canmount=on would be mounted straight over the running system by the
        # next `zfs mount -a`, and the running system's /var/lib/dpkg would
        # silently become the clone's.
        text = ask(c, f"printf 'S5-%s\\n' CM; zfs list -H -o name,canmount -r rpool/ROOT/{new_be} "
                      f"bpool/BOOT/{new_be}; zfs mount -a 2>&1 | head -3; "
                      "printf 'S5-%s\\n' AFTER; findmnt -no SOURCE /var/lib/dpkg",
                   "the clone cannot mount over the running system", timeout=180)
        cm = body_of(text, "S5-CM")
        print("\n--- the clone's canmount, and what /var/lib/dpkg is after `zfs mount -a` ---")
        print(cm.strip()[:900])
        print("---")
        # Counted rather than pattern-matched-for-absence, so the number is in
        # the output either way and a check that stops matching cannot look like
        # a check that passed.
        on = [l for l in cm.splitlines() if re.match(r"^\S+\s+on\s*$", l)]
        if on:
            print(f"      FAIL  3/9 {len(on)} dataset(s) in the clone are canmount=on:")
            for l in on:
                print("            " + l)
            ok = False
        elif f"/{new_be}" in body_of(text, "S5-AFTER"):
            print("      FAIL  3/9 the clone took over /var/lib/dpkg")
            ok = False
        else:
            print("      ok    3/9 the clone is inert: nothing of it mounted itself")

        # -- assemble it and put one package in it ---------------------------
        send_script(c, "assemble.sh", ASSEMBLE)
        send_script(c, "disassemble.sh", DISASSEMBLE)
        text = ask(c, f"bash /tmp/assemble.sh {new_be} 2>&1 | tail -5", "assemble the clone",
                   timeout=300)
        if "ASSEMBLED" not in body_of(text, "tail -5"):
            print("      FAIL  4/9 the clone could not be assembled")
            print(text.replace("\r", "")[-1200:])
            return False
        print("      ok    4/9 the clone is assembled at /mnt/be")

        text = ask(c, "chroot /mnt/be sh -c 'apt-get -qq update >/dev/null 2>&1; "
                      f"DEBIAN_FRONTEND=noninteractive apt-get -y install {MARKER_PACKAGE} "
                      "2>&1 | tail -3; update-initramfs -u 2>&1 | tail -2' ",
                   "change the clone", timeout=1200)
        print("        " + body_of(text, "update-initramfs -u").replace("\r", "").strip()[:400])

        text = ask(c, f"printf 'S5-%s\\n' DIFF; chroot /mnt/be dpkg-query -W {MARKER_PACKAGE} 2>&1; "
                      f"dpkg-query -W {MARKER_PACKAGE} 2>&1",
                   "the two package databases differ", timeout=180)
        diff = body_of(text, "S5-DIFF")
        print("\n--- " + MARKER_PACKAGE + " in the clone, then in the running system ---")
        print(diff.strip()[:600])
        print("---")
        if re.search(MARKER_PACKAGE + r"\s+\d", diff) and "no packages found" in diff:
            print("      ok    5/9 the clone has the package and the running system does not")
        else:
            print("      note  5/9 could not read both databases apart; the reboot decides")

        ask(c, "bash /tmp/disassemble.sh", "disassemble", timeout=180)

        # -- activate --------------------------------------------------------
        text = ps(c, "Import-Module OS7; "
                     f"Set-OS7BootEnvironment -Name {new_be} -Confirm:$false | "
                     "Format-List Name,Active,Menu | Out-String",
                  "activate the clone", timeout=900)
        print("        " + body_of(text, "Out-String").replace("\r", "").strip()[:700])

        # THE WINDOW BETWEEN ACTIVATION AND THE REBOOT. Activation sets the
        # target's datasets to canmount=on while the OLD environment is still
        # running, so for as long as the operator waits to reboot, a `zfs mount
        # -a` would mount the target's /var/lib/dpkg over the running system's.
        # The window is inherent to §4.2, where step 10 is "reboot on the
        # operator's schedule" — so what is checked is the narrower and more
        # useful claim: that activation does not trigger it ITSELF.
        text = ask(c, f"printf 'S5-%s\\n' WIN; zfs list -H -o name,canmount,mounted -r "
                      f"rpool/ROOT/{new_be}; findmnt -no SOURCE /var/lib/dpkg",
                   "nothing of the target mounted itself", timeout=180)
        win = body_of(text, "S5-WIN")
        mounted = [l for l in win.splitlines() if re.match(r"^\S+\s+\S+\s+yes\s*$", l)]
        if mounted:
            print("      FAIL       activation mounted the target over the running system:")
            for l in mounted:
                print("            " + l)
            ok = False
        else:
            print("      ok         activation mounted nothing of the target")

        text = ask(c, "printf 'S5-%s\\n' ESP; cat /boot/efi/EFI/BOOT/grub.cfg; "
                      "grub-editenv /boot/grub/grubenv list",
                   "what the ESP now says", timeout=180)
        esp = body_of(text, "S5-ESP")
        print("\n--- the ESP stub and grubenv after activation ---")
        print(esp.strip()[:800])
        print("---")
        if new_be in esp:
            print(f"      ok    6/9 the ESP stub and grubenv name {new_be}")
        else:
            print("      FAIL  6/9 the ESP stub was not repointed — the reboot will not switch")
            ok = False

        m.power_off()

    # ---- 2. the machine that comes back must be the CLONE --------------------
    with Machine("cycle-2") as m:
        c = m.c
        text = ask(c, "printf 'S5-%s\\n' NOW; findmnt -no SOURCE /; findmnt -no SOURCE /boot; "
                      "findmnt -no SOURCE /var/lib/dpkg; "
                      f"dpkg-query -W {MARKER_PACKAGE} 2>&1",
                   "which environment came back", timeout=240)
        now = body_of(text, "S5-NOW")
        print("\n--- after the reboot ---")
        print(now.strip()[:800])
        print("---")
        if f"rpool/ROOT/{new_be}" in now:
            print(f"      ok    7/9 THE MACHINE BOOTED THE CLONE — / is {new_be}")
        else:
            print("      FAIL  7/9 the machine came back in the old environment")
            ok = False
        if f"bpool/BOOT/{new_be}" in now and f"rpool/ROOT/{new_be}/var/lib/dpkg" in now:
            print("      ok         /boot and /var/lib/dpkg are the CLONE's, not the old pair's")
        else:
            print("      FAIL       the pair is half-activated: /boot or /var/lib/dpkg is wrong")
            ok = False
        if re.search(MARKER_PACKAGE + r"\s+\d", now):
            print(f"      ok         {MARKER_PACKAGE} is installed here — the change came with it")
        else:
            print(f"      FAIL       {MARKER_PACKAGE} is not installed: this is not the changed clone")
            ok = False

        be_table(c, "in the clone")

        # -- A FILE IN THE HOME, WRITTEN FROM THE CLONE -----------------------
        #
        # THE PROPERTY THE WHOLE DATASET LAYOUT EXISTS FOR, and until 2026-08-26
        # nothing in this repository tested it. SETUP-PLAN §4.4 puts USERDATA
        # outside ROOT so that rolling back a release does not roll back the
        # user's files. Written HERE — in the clone, after the switch — and
        # looked for after the rollback, because that is the only ordering that
        # can tell the two layouts apart: a home inside the boot environment
        # would take this file with the clone and it would be gone; a home on a
        # USERDATA dataset is the same dataset in both environments.
        #
        # BUILD-NOTES #74 is what happens when nobody checks: `New-OS7Storage`'s
        # -UserName defaulted to `os7`, Setup never passed it, and the home this
        # writes to was an ordinary directory in rpool/ROOT/<be> on every
        # machine this repository has ever installed.
        ask(c, f"install -d -o {USERNAME} -g {USERNAME} /home/{USERNAME} && "
               f"printf 'written from the clone\\n' > {HOME_MARKER} && "
               f"chown {USERNAME}:{USERNAME} {HOME_MARKER} && "
               f"printf 'S5-%s\\n' MARKWRITTEN; findmnt -no SOURCE /home/{USERNAME}",
            "write a file into the home", timeout=180)
        text = ask(c, f"printf 'S5-%s\\n' HOMEDS; findmnt -no SOURCE,FSTYPE "
                      f"/home/{USERNAME}; stat -c '%U:%G' {HOME_MARKER}",
                   "which dataset serves the home", timeout=180)
        homeds = body_of(text, "S5-HOMEDS")
        print("\n--- the home, in the clone ---")
        print(homeds.strip()[:300])
        print("---")
        if "rpool/USERDATA/" in homeds:
            print(f"      ok         /home/{USERNAME} is a USERDATA dataset, so the "
                  "rollback below is a real test of §4.4")
        else:
            # NOT a pass, and not a silent one either. On a machine with #74 the
            # marker WILL disappear at the rollback, and reporting that as "the
            # rollback works" would be the exact inversion of the truth.
            print(f"      FAIL       /home/{USERNAME} is not on a USERDATA dataset "
                  "(BUILD-NOTES #74). The rollback check below cannot mean what "
                  "it says on this machine.")
            ok = False

        # -- and back ---------------------------------------------------------
        text = ps(c, "Import-Module OS7; Restore-OS7 -Confirm:$false | "
                     "Format-List Name,Active,Menu | Out-String",
                  "roll back", timeout=900)
        print("        " + body_of(text, "Out-String").replace("\r", "").strip()[:700])

        # NOT "did the cmdlet print something". Restore-OS7 takes no argument
        # here — the whole point is that it works out which environment the
        # previous one is — so the check is that it picked the right one AND
        # that the ESP now says so. Anything weaker passes on a cmdlet that
        # imported a module and gave up.
        text = ask(c, "printf 'S5-%s\\n' RB; cat /boot/efi/EFI/BOOT/grub.cfg; "
                      "grub-editenv /boot/grub/grubenv list",
                   "what the ESP says after the rollback", timeout=180)
        rb = body_of(text, "S5-RB")
        print("\n--- the ESP stub after the rollback ---")
        print(rb.strip()[:600])
        print("---")
        if old_be in rb and new_be not in rb.split("saved_entry")[0]:
            print(f"      ok    8/9 Restore-OS7 chose {old_be} and the ESP stub names it")
        else:
            print(f"      FAIL  8/9 the ESP stub does not name {old_be} after the rollback")
            ok = False

        m.power_off()

    # ---- 3. and the machine that comes back must be the ORIGINAL -------------
    with Machine("cycle-3") as m:
        c = m.c
        text = ask(c, "printf 'S5-%s\\n' BACK; findmnt -no SOURCE /; findmnt -no SOURCE /boot; "
                      f"dpkg-query -W {MARKER_PACKAGE} 2>&1",
                   "which environment came back", timeout=240)
        back = body_of(text, "S5-BACK")
        print("\n--- after the rollback ---")
        print(back.strip()[:800])
        print("---")
        if f"rpool/ROOT/{new_be}" in back:
            print("      FAIL  9/9 the rollback did not take: still in the clone")
            ok = False
        elif "rpool/ROOT/os7_" in back:
            print("      ok    9/9 THE ROLLBACK TOOK — / is the original environment again")
        else:
            print("      FAIL  9/9 / is not a boot environment at all")
            ok = False
        if re.search(MARKER_PACKAGE + r"\s+\d", back):
            print(f"      FAIL       {MARKER_PACKAGE} is still installed — the rollback "
                  "did not un-say the change")
            ok = False
        else:
            print(f"      ok         {MARKER_PACKAGE} is gone: the rollback un-said the change")

        # AND THE OTHER HALF OF THE SAME SENTENCE. The package is gone because
        # it was inside the boot environment; the file must still be here
        # because the home is not (SETUP-PLAN §4.4). One rollback, two opposite
        # outcomes, and a layout that gets either of them wrong is a layout that
        # cannot be corrected afterwards.
        text = ask(c, f"printf 'S5-%s\\n' HOMEBACK; cat {HOME_MARKER} 2>&1; "
                      f"findmnt -no SOURCE /home/{USERNAME}",
                   "the file written from the clone", timeout=180)
        homeback = body_of(text, "S5-HOMEBACK")
        print("\n--- the home, after the rollback ---")
        print(homeback.strip()[:300])
        print("---")
        if "written from the clone" in homeback:
            print("      ok         THE USER'S FILE SURVIVED THE ROLLBACK — USERDATA "
                  "is outside ROOT and it shows")
        else:
            print(f"      FAIL       {HOME_MARKER} is gone: the rollback took the "
                  "user's files with the system (BUILD-NOTES #74, SETUP-PLAN §4.4)")
            ok = False

        final = be_table(c, "after the rollback")
        if final.count("os7_") >= 2:
            print("      ok         both environments are still there and both are complete")
        else:
            print("      FAIL       an environment disappeared")
            ok = False
        if m.unlocked_by_tpm:
            print("      ok         and the TPM still unlocked the disk, on the third boot")
        else:
            print("      note       the TPM did not unlock this boot")
    return ok


PHASES = {"install": phase_install, "boot": phase_boot, "cycle": phase_cycle}


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        lab.reset()
        return
    order = ["install", "boot", "cycle"] if what == "all" else [what]
    if any(p not in PHASES for p in order):
        raise SystemExit(f"usage: run-s5.py [{'|'.join(PHASES)}|all|reset]")

    print(f"ISO      {lab.iso}")
    results = {}
    for p in order:
        results[p] = PHASES[p]()
        if not results[p] and p == "install":
            print("\ninstall failed — nothing after it can mean anything")
            break

    print("\n" + "=" * 70)
    for p, r in results.items():
        print(f"  {p:8s} {'PASS' if r else 'FAIL'}")
    print("=" * 70)
    sys.exit(0 if all(results.values()) else 1)


if __name__ == "__main__":
    main()
