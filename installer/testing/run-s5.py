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
    ./run-s5.py update    Update-OS7 against a locally served repository:
                          N -> N+1, firstboot migrations, and back (the gate)
    ./run-s5.py timer     the unattended check's exit-code contract, measured
    ./run-s5.py all       all five, in one sitting                   (default)
    ./run-s5.py serialize give an existing amd64 disk a serial console
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
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, to_plain_bash                # noqa: E402
from vmarch import SoftTpm                                              # noqa: E402
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

TARGET = "/dev/disk/by-id/virtio-os7target"
LIVE_CMDLINE = f"boot=casper fbcon=nodefer quiet console={lab.arch.serial_tty},115200"

_mark = 0


def Tpm(enabled=True):
    """The software TPM, from vmarch: a sibling swtpm process on the Mac, a
    swtpm inside the QEMU container on the x86_64 path (vmhost-entry.sh). Its
    STATE directory is the same either way, so enrolment survives across boots
    on both."""
    return SoftTpm(lab.arch, TPMDIR, enabled)


def disk_only_args():
    """QEMU with the target disk, the TPM, and no medium of any kind.

    The same shape as run-phase3's, and for the same reason: the bootloader is
    part of what is under test, so the firmware has to find it on the ESP by
    itself. The TPM is attached here as well as during the install, because a
    sealed key with no TPM to unseal it is the L17 case and not this one.
    """
    p = lab.arch.path
    return lab.arch.base_args() + [
        "-smp", lab.CPUS, "-m", lab.MEM,
    ] + lab.arch.firmware_args(lab.vars) + [
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={p(lab.target)},format=qcow2",
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
# The serial console the amd64 machine does not have.
#
# On arm64 the installed machine speaks on the serial line without being asked:
# QEMU's virt machine hands the kernel a device tree whose chosen node names
# ttyAMA0, and Linux takes it as the console. x86 has no such mechanism — the
# kernel's default console is tty0, and an installed amd64 machine is therefore
# SILENT on the serial line this harness drives: the passphrase prompt, the
# boot, and the login all happen on a display nothing is attached to.
#
# So after an amd64 install, the harness gives the machine a serial console:
# unlock the container with the passphrase it just set, import the pools, put
# `console=ttyS0,115200` into the GRUB defaults, regenerate the menu through
# the machine's own update-grub, and export everything again. THIS IS THE
# HARNESS'S DOING, NOT THE PRODUCT'S — whether an OS/7 server image should
# ship a serial console by default is a real product question
# (RELEASE-AND-UPDATE-PLAN §6 already requires every cmdlet to work over
# serial), and it is left open rather than decided here in passing. What the
# `boot` phase then exercises is unchanged: OVMF finds shim, shim finds GRUB,
# GRUB finds the boot environment, the initramfs asks the TPM.
# ---------------------------------------------------------------------------
# The mounts and the chroot run INSIDE `unshare --mount --propagation private`
# (BUILD-NOTES #18): a bind done in the shared namespace propagates before it
# can be made private, and `zpool export` then says "pool is busy" with
# nothing visibly mounted and -f powerless. The first version of this script
# did exactly that and measured exactly that. The namespace evaporates with
# the inner shell, taking every mount with it, and the outer script exports
# clean pools. update-grub's own chatter goes to stderr so the inner stdout is
# the one number the caller wants.
SERIAL_INNER = r"""
set -e
BE=$1
M=/mnt/cfg
mkdir -p $M
mount -t zfs -o zfsutil rpool/ROOT/$BE $M
mount -t zfs -o zfsutil bpool/BOOT/$BE $M/boot
for d in dev proc sys; do mount --rbind /$d $M/$d; mount --make-rslave $M/$d; done
if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' $M/etc/default/grub; then
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200"' >> $M/etc/default/grub
elif ! grep -q 'console=ttyS0' $M/etc/default/grub; then
  sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 console=ttyS0,115200"/' $M/etc/default/grub
fi
chroot $M update-grub >&2 2>&1
grep -c 'console=ttyS0' $M/boot/grub/grub.cfg
"""

SERIAL_CONSOLE = r"""
set -e
LUKS=/dev/disk/by-partlabel/os7-luks
test -e "$LUKS"
cryptsetup status os7cfg >/dev/null 2>&1 || cryptsetup open "$LUKS" os7cfg --key-file=/tmp/pass
zpool list -H rpool >/dev/null 2>&1 || zpool import -N -f rpool
zpool list -H bpool >/dev/null 2>&1 || zpool import -N -f bpool
BE=$(zfs list -H -o name -d 1 rpool/ROOT | grep '^rpool/ROOT/os7_' | head -1 | cut -d/ -f3)
test -n "$BE"
N=$(unshare --mount --propagation private bash /tmp/serialize-inner.sh "$BE" | tail -1)
zpool export bpool
zpool export rpool
cryptsetup close os7cfg
echo "SERIAL-LINES=$N"
echo SERIAL-CONSOLE-OK
"""


def give_serial_console(c):
    """Run SERIAL_CONSOLE in the live session. Returns True when the machine's
    own grub.cfg came back carrying the console — asked of the file, not of the
    script's exit code."""
    send_script(c, "serialize-inner.sh", SERIAL_INNER)
    send_script(c, "serialize.sh", SERIAL_CONSOLE)
    text = ask(c, "sudo bash /tmp/serialize.sh 2>&1 | tail -8",
               "give the machine a serial console", timeout=600)
    body = body_of(text, "tail -8")
    if "SERIAL-CONSOLE-OK" not in body:
        print("      FAIL  the machine could not be given a serial console")
        print(body.strip()[-1200:])
        return False
    m = re.search(r"SERIAL-LINES=(\d+)", body)
    n = int(m.group(1)) if m else 0
    if n < 1:
        print("      FAIL  update-grub ran and no menu entry carries console=ttyS0")
        return False
    print(f"      ok    the machine has a serial console ({n} menu lines carry it)")
    return True


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
        c = Console(lab.arch.command(args, name=lab.name, tpm=tpm),
                    os.path.join(lab.dir, "install.serial.log"))
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

            # amd64 only: the installed machine would otherwise be silent on
            # the serial line every later phase drives (see SERIAL_CONSOLE).
            if lab.arch.serial_tty != "ttyAMA0":
                if not give_serial_console(c):
                    return False
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
        self.c = Console(lab.arch.command(disk_only_args() + self.tpm.args(),
                                          name=lab.name, tpm=self.tpm),
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
    reenrolled = False
    with Machine("boot") as m:
        c = m.c
        if m.unlocked_by_tpm:
            print("      ok    1/7 THE TPM UNLOCKED THE DISK — no passphrase was typed")
        elif lab.arch.serial_tty == "ttyAMA0":
            print("      FAIL  1/7 the machine asked for the passphrase: the TPM did not")
            print("                unlock it. Everything below still runs.")
            ok = False
        else:
            # MEASURED 2026-08-28, first amd64 boot ever: the enrolment is
            # correct (token in slot 1, handler and libtss2 in the initramfs)
            # and the seal does not open, because TpmEnrolStep sealed against
            # the LIVE SESSION's PCR 7 and this machine boots through shim,
            # which extends it — BUILD-NOTES #69's prediction, now a
            # measurement. arm64 never hit it because QEMU's arm64 path boots
            # the same way in both sessions. The recovery is S6's: one
            # systemd-cryptenroll on the booted machine, against the PCR 7
            # that the real boot path produces. The product's own fix is the
            # UL1 first-boot migration; until an image ships it, the harness
            # performs the documented recovery and THE VERDICT IS THE NEXT
            # BOOT, which must unlock with nothing typed.
            print("      note  1/7 the FIRST amd64 boot asked for the passphrase — #69:")
            print("            the install-time seal is against the live session's PCR 7")
            print("            and this machine boots through shim. Re-enrolling (S6's")
            print("            recovery); the verdict is the next boot.")
            text = ask(c, f"PASSWORD='{PASSPHRASE}' systemd-cryptenroll --wipe-slot=tpm2 "
                          "--tpm2-device=auto --tpm2-pcrs=7 "
                          "/dev/disk/by-partlabel/os7-luks 2>&1 | tail -3",
                       "re-enrol against the booted PCR 7", timeout=300)
            if "enrolled" in body_of(text, "tail -3"):
                print("      ok         re-enrolled against the boot path's own PCR 7")
                reenrolled = True
            else:
                print("      FAIL  1/7 the re-enrolment did not report a new token:")
                print("            " + body_of(text, "tail -3").strip()[:300])
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
        if reenrolled:
            m.power_off()

    # The other half of the amd64 1/7 verdict: after S6's recovery, the NEXT
    # boot must unlock with nothing typed — that, and not the recovery's exit
    # code, is what says the re-enrolment worked.
    if reenrolled:
        with Machine("boot-tpm") as m2:
            if m2.unlocked_by_tpm:
                print("      ok    1/7 THE TPM UNLOCKED THE DISK on the boot after")
                print("                re-enrolment — no passphrase was typed")
            else:
                print("      FAIL  1/7 the re-enrolled TPM still did not unlock the disk")
                ok = False
            m2.power_off()
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


# ---------------------------------------------------------------------------
# update — the end-to-end proof. RELEASE-AND-UPDATE-PLAN's whole promise, asked
# of a machine: a release N+1 is built from this tree with the SAME development
# key the ISO's os7-release trusts, served to the guest over local HTTP (the
# guest's 10.0.2.2 is QEMU's host side — the os7-vm container on this box, the
# Mac itself there), the machine is pointed at it with Set-OS7UpdateChannel,
# and Update-OS7 does what until now only the harness's own hands had done.
# Every claim below is answered by the machine, not by an exit code.
# ---------------------------------------------------------------------------
UPDATE_REPO = os.path.join(lab.dir, "repo")
HTTP_PORT = 8907


def next_build(version):
    head, _, build = version.rpartition(".")
    return f"{head}.{int(build) + 1}"


def build_release_repo(version):
    """Release <version> into UPDATE_REPO, signed with the shared key.

    The key mount is the load-bearing part: the ISO's os7-release ships the
    public half of out/os7-gnupg's key (Makefile KEYDIR), so a repository
    signed from the same home is one the installed machine can verify —
    and one signed anywhere else is the negative case check-os7-repo.py
    already owns."""
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "check_os7_repo", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                       "check-os7-repo.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    facts = mod.source_facts()
    if facts is None:
        raise SystemExit("git could not be asked for the source facts (BUILD-NOTES #43)")
    env_args = []
    for line in facts.stdout.splitlines():
        if "=" in line:
            env_args += ["-e", line.strip()]
    keydir = os.path.join(REPO, "out", "os7-gnupg")
    os.makedirs(keydir, exist_ok=True)
    os.makedirs(UPDATE_REPO, exist_ok=True)
    print(f"    building release {version} into {UPDATE_REPO} …")
    got = subprocess.run(
        ["docker", "run", "--rm", "--platform", lab.arch.docker_platform,
         "-v", f"{REPO}:/work", "-v", f"{UPDATE_REPO}:/out",
         "-v", f"{keydir}:/os7-gnupg", "-e", "OS7_REPO_GNUPGHOME=/os7-gnupg",
         *env_args,
         "-e", f"OS7_VERSION={version}", "-e", f"OS7_ARCH={lab.arch.arch}",
         "-e", f"OS7_REPO_URI={lab.arch.guest_host_url(HTTP_PORT)}",
         "-e", "OS7_REPO_ENABLED=yes",
         lab.arch.build_image, "bash", "-c",
         "/work/build/lib/build-os7-repo.sh /work/build/config/os7-release.conf /out"],
        capture_output=True, text=True)
    for line in got.stdout.splitlines():
        if line.startswith((">>>", "    ")):
            print("      " + line.strip())
    if got.returncode != 0:
        print(got.stdout[-2500:])
        print(got.stderr[-1500:])
        raise SystemExit(f"the {version} repository did not build")


def phase_update():
    print("\n### update — Update-OS7 against a served repository, end to end")
    for need, what in ((lab.target, "an installed disk"), (lab.vars, "a firmware store")):
        if not os.path.exists(need):
            print(f"      FAIL  no {what} at {need}. Run install first.")
            return False
    ok = True
    lab.arch.serve_http(UPDATE_REPO, HTTP_PORT)
    url = lab.arch.guest_host_url(HTTP_PORT)

    with Machine("update-1") as m:
        c = m.c
        text = ps(c, "Import-Module OS7; (Get-OS7Version).FullVersion.ToString()",
                  "the running version")
        got = re.search(r"\b(\d+\.\d+\.\d+\.\d+)\b", body_of(text, "ToString()"))
        if not got:
            print("      FAIL  the machine does not know its version")
            return False
        vfrom = got.group(1)
        vnext = next_build(vfrom)
        print(f"      ok    1/8 the machine runs {vfrom}; the update target is {vnext}")

        build_release_repo(vnext)

        text = ps(c, f"Import-Module OS7; Set-OS7UpdateChannel -Uri {url} "
                     "-Channel development | Format-List Channel,Uri,Enabled | Out-String",
                  "point the machine at the repository", timeout=600)
        body = body_of(text, "Out-String")
        if url in body and "Enabled" in body:
            print(f"      ok    2/8 Set-OS7UpdateChannel took {url}, and apt verified it")
        else:
            print("      FAIL  2/8 the channel could not be configured:")
            print(body.strip()[-800:])
            return False

        text = ps(c, "Import-Module OS7; $r = Update-OS7 -AllowDevelopment -Confirm:$false; "
                     "$r | ConvertTo-Json -Compress",
                  "Update-OS7", timeout=3600)
        body = body_of(text, "ConvertTo-Json -Compress")
        made = re.search(r'"BootEnvironment":\s*"(os7_[0-9.]+_\d{12})"', body)
        if f'"To":"{vnext}"' in body.replace(" ", "") and '"Applied":true' in body.replace(" ", "") and made:
            new_be = made.group(1)
            print(f"      ok    3/8 UPDATE-OS7 RAN THROUGH: {vfrom} -> {vnext} into {new_be}")
        else:
            print("      FAIL  3/8 Update-OS7 did not apply the release:")
            print(body.strip()[-1500:])
            return False
        old_be_text = ask(c, "printf 'S5-%s\\n' OLD; findmnt -no SOURCE /", "the old root")
        found = re.search(r"rpool/ROOT/(os7_[0-9.]+_\d{12})", body_of(old_be_text, "S5-OLD"))
        if not found:
            print("      FAIL  the running root is not a boot environment")
            return False
        old_be = found.group(1)
        m.power_off()

    # ---- the machine that comes back must be N+1 ----------------------------
    with Machine("update-2") as m:
        c = m.c
        text = ask(c, "printf 'S5-%s\\n' NOW; findmnt -no SOURCE /; "
                      "dpkg-query -W -f='${Version}\\n' os7-base; "
                      "cat /usr/lib/os7/release.json | grep -o '\"version\": *\"[^\"]*\"' | head -1",
                   "which system came back", timeout=240)
        now = body_of(text, "S5-NOW")
        if f"rpool/ROOT/{new_be}" in now:
            print(f"      ok    4/8 THE MACHINE BOOTED {vnext} — / is {new_be}")
        else:
            print("      FAIL  4/8 the machine did not boot the new environment:")
            print(now.strip()[:600])
            ok = False
        if vnext in now:
            print(f"      ok         os7-base and release.json both say {vnext}")
        else:
            print(f"      FAIL       the packages do not say {vnext}: {now.strip()[:300]}")
            ok = False
        text = ps(c, "Import-Module OS7; (Get-OS7Version).FullVersion.ToString()",
                  "Get-OS7Version on the updated machine")
        if vnext in body_of(text, "ToString()"):
            print(f"      ok    5/8 Get-OS7Version says {vnext}")
        else:
            print(f"      FAIL  5/8 Get-OS7Version does not say {vnext}")
            ok = False

        # The firstboot migration runner (C10 §6', package C), on the machine:
        # the stamp is there, the pending record was consumed, and the log
        # says what ran. UL1's script found the seal opening (PCR 7 unmoved
        # by an update, S6) and said "nothing to do" — that IS its verdict
        # path, and the stamp proves the runner drove it.
        text = ask(c, f"printf 'S5-%s\\n' MIG; ls /var/lib/os7/migrations/{vnext}/ 2>&1; "
                      "test -e /var/lib/os7/migrations/pending && echo PENDING-STILL-THERE "
                      "|| echo PENDING-CONSUMED; "
                      "grep firstboot /var/log/os7/update.log | tail -3",
                   "the firstboot migrations", timeout=180)
        mig = body_of(text, "S5-MIG")
        print("\n--- the firstboot migration state ---")
        print(mig.strip()[:600])
        print("---")
        if "50-tpm2-reseal" in mig and "PENDING-CONSUMED" in mig and "ran " in mig:
            print(f"      ok    6/8 THE FIRSTBOOT MIGRATION RAN at the first boot of {vnext}")
        else:
            print("      FAIL  6/8 the firstboot migration did not run (or left pending)")
            ok = False

        be = be_table(c, "after the update")
        if be.count("os7_") >= 2 and old_be in be:
            print(f"      ok    7/8 both environments are there — -Keep 2 kept {old_be}")
        else:
            print(f"      FAIL  7/8 the previous environment {old_be} is gone")
            ok = False
        text = ask(c, "printf 'S5-%s\\n' SRC; cat /etc/apt/sources.list.d/os7.sources",
                   "the channel survived the upgrade", timeout=120)
        if url in body_of(text, "S5-SRC"):
            print("      ok         the upgrade kept the operator's channel (conffile)")
        else:
            print("      FAIL       os7-release's upgrade reverted the channel — the")
            print("                 conffile did not hold")
            ok = False

        text = ps(c, "Import-Module OS7; Restore-OS7 -Confirm:$false | "
                     "Format-List Name | Out-String", "roll back", timeout=900)
        if old_be in body_of(text, "Out-String"):
            print(f"      ok         Restore-OS7 chose {old_be}")
        else:
            print("      FAIL       Restore-OS7 did not choose the previous environment")
            ok = False
        m.power_off()

    # ---- and the rollback must un-say the release ---------------------------
    with Machine("update-3") as m:
        c = m.c
        text = ask(c, "printf 'S5-%s\\n' BACK; findmnt -no SOURCE /; "
                      "dpkg-query -W -f='${Version}\\n' os7-base",
                   "which system came back", timeout=240)
        back = body_of(text, "S5-BACK")
        if f"rpool/ROOT/{old_be}" in back and vfrom in back:
            print(f"      ok    8/8 THE ROLLBACK TOOK — the machine runs {vfrom} again")
        else:
            print("      FAIL  8/8 the machine did not come back on the old release:")
            print(back.strip()[:500])
            ok = False
        m.power_off()
    return ok


# ---------------------------------------------------------------------------
# timer — §6's unattended path, on the machine (package E's gate). The service
# is asked for its REAL exit status through systemd, against the contract the
# unit declares: 0 nothing-to-do, 2 staged, 1 failed.
# ---------------------------------------------------------------------------
def phase_timer():
    print("\n### timer — the unattended check: nothing without a channel, staged with one")
    if not os.path.isdir(UPDATE_REPO):
        print("      FAIL  no repository at " + UPDATE_REPO + ". Run update first.")
        return False
    ok = True
    lab.arch.serve_http(UPDATE_REPO, HTTP_PORT)
    url = lab.arch.guest_host_url(HTTP_PORT)

    def service_status(c, label):
        text = ask(c, "systemctl start os7-update-check.service; "
                      "printf 'S5-%s\\n' ST; "
                      "systemctl show -p ExecMainStatus --value os7-update-check.service; "
                      "tail -2 /var/log/os7/update.log",
                   label, timeout=3600)
        body = body_of(text, "S5-ST")
        code = next((l.strip() for l in body.splitlines() if l.strip().isdigit()), "?")
        return code, body

    with Machine("timer-1") as m:
        c = m.c
        ask(c, "test -f /usr/lib/systemd/system/timers.target.wants/os7-update-check.timer "
               "&& printf 'S5-%s\\n' TIMER-ENABLED || printf 'S5-%s\\n' TIMER-MISSING",
            "the timer ships enabled")
        if "TIMER-ENABLED" in c.text():
            print("      ok    1/4 os7-update-check.timer ships enabled")
        else:
            print("      FAIL  1/4 the timer is not enabled on the machine")
            ok = False

        # A. No reachable channel: the machine is put back into the shipped
        # state (the rollback brought the configured channel back with /etc).
        ps(c, "Import-Module OS7; Set-OS7UpdateChannel -Disable | Out-Null",
           "disable the channel", timeout=300)
        code, body = service_status(c, "the check with no channel")
        if code == "0" and "no update channel is configured" in body:
            print("      ok    2/4 without a channel: exit 0, and the log says why")
        else:
            print(f"      FAIL  2/4 expected exit 0 + reason, got {code}:")
            print(body.strip()[:400])
            ok = False

        # B. A reachable channel offering a release: the check STAGES it and
        # says so with exit 2. The environment the update phase staged and the
        # rollback left behind is removed first, so the timer's own staging is
        # what is measured rather than found.
        ps(c, f"Import-Module OS7; Set-OS7UpdateChannel -Uri {url} -Channel development "
             "| Out-Null", "re-enable the channel", timeout=600)
        ask(c, "printf 'OS7_UPDATE_UNATTENDED_ALLOW_DEVELOPMENT=\"yes\"\\n' "
               ">> /etc/os7/update.conf", "allow development releases unattended")
        text = ps(c, "Import-Module OS7; Get-OS7BootEnvironment | Where-Object "
                     "{ -not $_.Running } | Remove-OS7BootEnvironment -Confirm:$false; "
                     "@(Get-OS7BootEnvironment).Count",
                  "clear the staged leftovers", timeout=600)
        code, body = service_status(c, "the check with a reachable channel")
        if code == "2":
            print("      ok    3/4 with a channel: exit 2 — staged, reboot pending")
        else:
            print(f"      FAIL  3/4 expected exit 2, got {code}:")
            print(body.strip()[:500])
            ok = False
        text = ps(c, "Import-Module OS7; (Get-OS7BootEnvironment | Where-Object "
                     "{ -not $_.Running } | Select-Object -Last 1).Release",
                  "the staged release is there")
        staged = body_of(text, ".Release").strip().splitlines()
        staged = next((s.strip() for s in staged if re.match(r"^\d+\.\d+\.\d+\.\d+$", s.strip())), "")
        if staged:
            print(f"      ok         a boot environment for {staged} exists — the release is there")
        else:
            print("      FAIL       the check reported staged and no environment exists")
            ok = False
        # And running it again stages nothing twice.
        code, body = service_status(c, "the check, again")
        if code == "2" and "already" in body:
            print("      ok    4/4 a second run finds it already staged — nothing minted twice")
        else:
            print(f"      FAIL  4/4 expected exit 2 + already-staged, got {code}")
            ok = False
        m.power_off()
    return ok


def phase_serialize():
    """The SERIAL_CONSOLE step alone, for a disk that was installed before the
    step existed (or whose configuration was lost with the pool). Boots the
    live medium, configures, powers off. A no-op on arm64, which never needed
    it."""
    print("\n### serialize — give an already-installed amd64 disk a serial console")
    if lab.arch.serial_tty == "ttyAMA0":
        print("      note  arm64 speaks on ttyAMA0 by itself; nothing to do")
        return True
    if not os.path.exists(lab.target):
        print(f"      FAIL  no installed disk at {lab.target}. Run install first.")
        return False
    # NOT lab.prepare(): prepare() recreates the target BLANK, which is right
    # before an install and would destroy the installed disk here. Only the
    # boot files and the firmware store are ensured.
    lab.arch.prepare_vars(lab.vars)
    lab.extract_boot_files()
    c = Console(lab.arch.command(lab.qemu_args(LIVE_CMDLINE, payload=False), name=lab.name),
                os.path.join(lab.dir, "serialize.serial.log"))
    try:
        live_login(c)
        to_plain_bash(c)
        c.send(f"printf '%s' '{PASSPHRASE}' > /tmp/pass")
        ok = give_serial_console(c)
        c.send("sudo poweroff -f")
        deadline = time.time() + 120
        while time.time() < deadline and c.proc.poll() is None:
            time.sleep(0.5)
        return ok
    finally:
        c.close()


PHASES = {"install": phase_install, "boot": phase_boot, "cycle": phase_cycle,
          "update": phase_update, "timer": phase_timer,
          "serialize": phase_serialize}


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        lab.reset()
        return
    order = ["install", "boot", "cycle", "update", "timer"] if what == "all" else [what]
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
