#!/usr/bin/env python3
"""
Phase 3 — os7-setup installs a system, and the system boots.

SETUP-PLAN §10 Phase 3's deliverable is one sentence: *a machine installed by
Setup boots into OS/7.* Everything before it could be checked by reading the
disk; this one cannot. The only evidence that counts is a machine starting from
that disk with nothing else attached.

    ./run-phase3.py install    install unattended from the live medium
    ./run-phase3.py boot       BOOT THE DISK ALONE and log in as the account
    ./run-phase3.py walk       install by KEYPRESS, screens 1-7 to Complete
    ./run-phase3.py all        install, boot, walk  (default)
    ./run-phase3.py reset      discard the VM state

`install` and `boot` are separate phases on purpose, and the separation is the
whole design: `boot` attaches NO ISO. A VM that still has the setup medium in it
can boot from the medium and look exactly like a successful install — which is
how an installer ships a bootloader that has never been exercised. Spike S3 made
the same split for the same reason and it is the only reason S3 counts as
evidence.

WHAT IS ASSERTED, in order, because each one fails differently:

  1. the LUKS passphrase prompt appears        - GRUB, kernel and initramfs work
  2. it is not `(initramfs)` or a kernel panic - the failure signature, watched
                                                 for explicitly so a dead boot
                                                 costs seconds not the timeout
  3. a login prompt                            - the pool imported and / mounted
  4. the account Setup created accepts its password
  5. `/` is served from rpool/ROOT/os7_<version>_<stamp>
  6. the version on the disk is the version on the medium
  7. /etc/os-release says OS/7, and still says ID=ubuntu for Intune
  8. the hostname is the one that was typed
  9. /home/<account> is a rpool/USERDATA dataset, and st_dev agrees
 10. it belongs to the account and was furnished from /etc/skel

7 is the check nothing else can make: os-release on the INSTALLED system, after
`unsquashfs` copied it and ReleaseIdentityStep rewrote VARIANT.

9 AND 10 ARE HERE BECAUSE THEIR ABSENCE SHIPPED A BUG. Until 2026-08-26
`grep -rIn "/home" installer/testing/*.py` returned nothing — every harness in
this directory checked the pools, the datasets, the bootloader and the account's
ability to log in, and none of them looked at where that account's FILES landed.
`New-OS7Storage`'s `-UserName` defaulted to `os7` and Setup never passed it, so
every machine this repository installed had an empty dataset at /home/os7 and
the real home an ordinary directory inside the boot environment — which
`Restore-OS7` rolls back with the system, and which is exactly what SETUP-PLAN
§4.4 puts USERDATA outside ROOT to prevent. It passed `all` throughout.
BUILD-NOTES #74; #78 is the half `useradd` contributed.

`walk` IS HERE AND NOT IN run-phase2.py, and that is a decision rather than a
filing choice. The interactive path performs a FULL INSTALL - there is no
interactive equivalent of `--storage-only`, and run-phase2's contract is that
every invocation asks for storage alone. It is also the only phase in this
repository that proves the flow can be walked at all: `install` above hands
os7-setup a plan file with an account already in it, which is exactly why it kept
passing on 2026-08-24 while the interactive flow could not get past screen 6.

`walk` and `install` type the same passphrase, password, computer name and
account name, so `boot` verifies whichever of them ran last.
"""

import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, to_plain_bash            # noqa: E402
from vmscreen import Lab, hexc, load_font, read_text, run           # noqa: E402

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "build", "lib"))
import palette                                                     # noqa: E402

# §3.1's brand blue. `walk` reads the screen back through the console font, and
# the sentences that matter most on those screens are drawn in this colour
# rather than in white - reading only white finds nothing and calls it absent.
BRAND = palette.BRAND

PASSPHRASE = "os7-phase3-passphrase"
PASSWORD = "os7-phase3-password"
HOSTNAME = "os7-phase3"
USERNAME = "os7admin"

# 24 GB: the §4.4 layout needs 16 as a floor, and the copied system needs room.
# nic=True since Phase 3b: screen 9 does not appear on a machine with no network
# adapter (NetworkScreen.Entry skips it), so a lab without one cannot walk it -
# and `boot` has always had a NIC, which is how the network gap in L23 stayed
# invisible for so long. User-mode networking is deterministic: 10.0.2.15.
lab = Lab("phase3", target_gb=24, iso_as_disk=True, nic=True)

# What QEMU's user-mode network hands out, every time. Named rather than
# repeated, because it is asserted on the live medium AND on the installed disk.
DHCP_ADDRESS = "10.0.2.15"

CMDLINE = ("boot=casper os7.setup=1 systemd.wants=os7-setup.service systemd.unit=multi-user.target "
           "fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 "
           f"console={lab.arch.serial_tty},115200")
LIVE_CMDLINE = f"boot=casper fbcon=nodefer quiet console={lab.arch.serial_tty},115200"

# The target is the SECOND disk. The first is the live medium, attached as a
# block device rather than a CD so that it is a `disk` to lsblk - BUILD-NOTES
# #35, and the only shape in which "the medium is refused" can be tested at all.
TARGET = "/dev/disk/by-id/virtio-os7target"

# The console font, for reading the screen back through it. `walk` is the only
# phase that needs it - `install` and `boot` are serial-line phases - so it is
# fetched lazily rather than on every run.
FONT = os.path.join(lab.dir, "os7-fixedsys-16x32.psf.gz")

# QEMU qcodes for the characters `walk` types. Letters and digits are their own
# qcode; everything else has a name.
QCODE = {"-": "minus", "_": "shift-minus", ".": "dot", "/": "slash", " ": "spc"}

_mark = 0


def disk_only_args():
    """QEMU with THE TARGET DISK AND NOTHING ELSE.

    Written here rather than taken from `Lab.qemu_args`, because that one is
    built for the other direction and every difference matters:

      * NO `-kernel` / `-initrd`. Every other harness in this directory boots the
        kernel directly, which is the right call when what is under test is
        userspace and driving GRUB over a serial line is what HANDOFF §5 warns
        about. Here the BOOTLOADER IS THE THING UNDER TEST - `grub-install` and
        the generated menu are Phase 3 deliverables - so the firmware has to find
        it on the ESP by itself.
      * NO ISO. A VM that still has the setup medium attached can boot from the
        medium and look exactly like a successful install. That is how an
        installer ships a bootloader nobody has ever exercised.
      * THE SAME VARIABLE STORE the install ran with, so an NVRAM entry written
        by `grub-install` is there to be used - and if it is not, the removable
        EFI/BOOT path has to stand in, which is the case that matters on
        hardware with a cleared CMOS.

    Spike S3 made exactly this split and it is the only reason S3 counts as
    evidence rather than as a log.
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


def ask(c, command, label, timeout=180):
    """Run something in the guest and return everything it printed.

    THE MARKER IS BUILT BY THE SHELL, NOT TYPED (BUILD-NOTES #16). `…; echo DONE`
    and then waiting for "DONE" matches the shell's ECHO of the command being
    typed, so `expect` returns before the command has run.
    """
    global _mark
    _mark += 1
    n = _mark
    c.drop()
    c.send(f"{command}; printf 'OK%s\\n' {n}")
    c.expect(f"OK{n}", timeout, label)
    return c.text()


def medium_release():
    """The version on the SETUP MEDIUM, taken out of the ISO.

    What the installed system must turn out to be. Read from the image rather
    than written into this file, for the same reason run-phase1 does it: a
    harness carrying the expected version passes until somebody forgets to edit
    it.
    """
    out = os.path.join(lab.dir, "medium-release.json")
    os.makedirs(lab.dir, exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    # THE UNMOUNTS ARE NOT PART OF THE WORK, and until 2026-08-28 they could
    # fail the whole phase after the work had succeeded. /mnt/sq is backed by a
    # file INSIDE /mnt/iso, and the loop device holding that file is not always
    # released by the time `umount /mnt/sq` returns — so `umount /mnt/iso` says
    #
    #     umount: /mnt/iso: target is busy.
    #
    # and `set -e` turned a tidy-up race into "walk failed", with
    # medium-release.json already written and correct. Measured on the x64
    # Windows host; it is why `run-phase3.py walk` could not start there at all.
    #
    # The container is `--rm`: it and every mount in it are discarded a moment
    # later, so the unmounts buy nothing and are explicitly allowed to fail.
    # `-d` still asks for the loop device back when it can. What must NOT be
    # allowed to fail is the copy, which is why it keeps `set -e` above it and
    # why the file is read back below — the same rule as everywhere else here:
    # the exit code is a diagnostic, the file is the thing itself.
    run("docker", "run", "--rm", "--privileged", "--platform", lab.arch.docker_platform,
        "-v", f"{os.path.dirname(lab.iso)}:/iso:ro", "-v", f"{lab.dir}:/out",
        lab.arch.build_image, "bash", "-c",
        f"set -e; mkdir -p /mnt/iso /mnt/sq; "
        f"mount -o loop,ro /iso/{os.path.basename(lab.iso)} /mnt/iso; "
        "mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq; "
        "cp /mnt/sq/usr/lib/os7/release.json /out/medium-release.json; "
        "set +e; umount -d /mnt/sq; umount -d /mnt/iso; exit 0",
        stdout=subprocess.DEVNULL)
    if not os.path.exists(out):
        raise SystemExit(f"medium_release: {out} was not written; the container "
                         "could not read /usr/lib/os7/release.json off the medium")
    return json.load(open(out))


def fetch_font():
    """The console font off the ISO, so the screen can be read through it.

    THE THIRD COPY of this function in installer/testing/ — run-phase1 and
    run-phase2 have the same one. It is left duplicated rather than hoisted in a
    bug-fix change: the other two are proven and this file is the one being
    added to. Somewhere to put it is `vmscreen.Lab`.
    """
    if os.path.exists(FONT):
        return
    os.makedirs(lab.dir, exist_ok=True)
    run("docker", "run", "--rm", "--privileged", "--platform", lab.arch.docker_platform,
        "-v", f"{os.path.dirname(lab.iso)}:/iso:ro", "-v", f"{lab.dir}:/out",
        lab.arch.build_image, "bash", "-c",
        f"set -e; mkdir -p /mnt/iso /mnt/sq; "
        f"mount -o loop,ro /iso/{os.path.basename(lab.iso)} /mnt/iso; "
        "mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq; "
        "cp /mnt/sq/usr/share/consolefonts/os7-fixedsys-16x32.psf.gz /out/; "
        "umount /mnt/sq; umount /mnt/iso", stdout=subprocess.DEVNULL)


def write_plan(c):
    """A complete plan, plus the two secrets as separate files.

    §6.6: the passphrase is not in the plan and neither is the account password.
    They are different secrets with different consequences, so they are two
    files - a fleet that rotates one should not have to rewrite the other.
    """
    plan = ('{"version":1,"intent":"Install","language":"de_DE.UTF-8",'
            '"keyboard":"de","timezone":"Europe/Berlin","mode":"Headless",'
            f'"storage":{{"disk":"{TARGET}","layout":"single","efiMiB":512,'
            '"bpoolGiB":2,"encrypt":true,"swap":"zram"},'
            f'"account":{{"hostname":"{HOSTNAME}","username":"{USERNAME}",'
            '"fullName":"OS/7 Phase 3"},'
            # `interface: auto` and not `enp0s1`, deliberately — L28. A plan file
            # is written on one machine and replayed on another, and an interface
            # name is a property of whichever machine was in front of the person
            # who wrote it. `auto` becomes a netplan `match: name: "en*"`, so this
            # is the path an unattended fleet install really takes, and therefore
            # the one worth exercising here rather than the interactive one.
            '"network":{"interface":"auto","kind":"Wired","method":"Dhcp"}}')
    c.drop()
    c.send(f"printf '%s' '{plan}' > /tmp/plan.json")
    c.send(f"printf '%s' '{PASSPHRASE}' > /tmp/pass")
    c.send(f"printf '%s' '{PASSWORD}' > /tmp/pw")
    ask(c, "wc -c /tmp/plan.json /tmp/pass /tmp/pw", "plan files")


def phase_install():
    print("\n  install — the whole thing, unattended")
    lab.prepare()
    c, q = lab.boot(LIVE_CMDLINE, "install")
    try:
        write_plan(c)
        # Twenty minutes: unsquashfs of a 2 GB image onto ZFS-on-LUKS in a VM is
        # minutes, update-initramfs is minutes, and a timeout that fires during
        # a working install is a harness that reports a bug it created.
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json "
                      "--passphrase-file /tmp/pass --password-file /tmp/pw",
                   "unattended install", timeout=1800)
        for line in text.splitlines():
            if "OS7-SETUP" in line or ">>>" in line or "!!!" in line:
                print("        " + line.strip())
        if "OS7-SETUP-DONE install" not in text:
            print("      FAIL  the install did not finish")
            # SHOW WHAT IT SAID. The first version of this printed the verdict
            # and nothing else, and the actual cause - an ISO carrying an
            # os7-setup that predated the option being passed to it - was
            # visible only by reading the serial log by hand afterwards.
            print("      --- the last of what the guest printed ---")
            for line in text.replace("\r", "").splitlines()[-25:]:
                if line.strip():
                    print("        " + line.strip())
            print("      ---")
            if "unknown option" in text or "Usage: os7-setup" in text:
                print("      NOTE: the ISO's os7-setup does not understand an option this")
                print("      NOTE: harness passed. The binary is baked in at BUILD time -")
                print("      NOTE: rebuild the ISO (make build-arm64) after changing Setup.")
            return False
        print("      ok    Setup reported a finished install")

        # ASK WHETHER THE POOLS ARE STILL IMPORTED, do not export them here.
        # TeardownStep is the last thing the installer runs and exporting is its
        # job; a harness that exports as well would pass whether or not the
        # installer did it, and the next boot is where that difference shows.
        text = ask(c, "zpool list -H -o name || true", "imported pools")
        body = text.split("zpool list -H -o name || true", 1)[-1]
        if "rpool" in body or "bpool" in body:
            print("      FAIL  a pool is still imported after the install finished")
            print("            " + body.replace("\r", "").strip()[:200])
            return False
        print("      ok    the installer exported both pools")
        return True
    finally:
        q.close()
        c.close()


def phase_boot():
    """THE DELIVERABLE. No ISO attached — the disk boots or it does not."""
    print("\n  boot — the installed disk, with nothing else attached")

    # `boot` on its own, with no install behind it, would start a VM with a
    # blank disk and a missing variable store and report "does not boot" —
    # true, and about a machine nothing ever installed.
    for need, what in ((lab.target, "an installed disk"),
                       (lab.vars, "a firmware variable store")):
        if not os.path.exists(need):
            print(f"      FAIL  no {what} at {need}. Run `./run-phase3.py install` first.")
            return False

    rel = medium_release()
    version = rel["version"]

    log = os.path.join(lab.dir, "boot.serial.log")
    print(f"    serial   {log}")
    c = Console(lab.arch.command(disk_only_args(), name=lab.name), log)
    ok = True
    try:
        # The failure signatures are watched for BESIDE the success one. Dropping
        # to (initramfs) is the exact shape of "LUKS never opened" or "the pool
        # never imported", and waiting out a 7-minute timeout for it wastes a
        # cycle and says less than the word does.
        i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                      r"\(initramfs\)", r"Kernel panic", r"No bootable"],
                     600, "the passphrase prompt")
        if i >= 3:
            print(c.text()[-3000:])
            print("      FAIL  the machine never got as far as asking for the passphrase")
            return False
        print("      ok    1/10 GRUB, the kernel and the initramfs all ran")
        c.send(PASSPHRASE)

        j = c.expect([r"\blogin:", r"\(initramfs\)", r"Kernel panic",
                      r"No key available", r"Failed to import pool"],
                     900, "a login prompt")
        if j >= 1:
            print(c.text()[-3000:])
            print("      FAIL  unlocked, but never reached a login prompt")
            return False
        print("      ok    2/10 the pool imported and / was mounted")
        print("      ok    3/10 a login prompt")

        # 4: THE ACCOUNT SETUP CREATED, with the password Setup hashed.
        # This is the check BUILD-NOTES #17 exists for: `chpasswd` cannot work in
        # the chroot, so AccountStep writes the hash instead - and the only proof
        # that the hash is right is a login.
        live_login(c, user=USERNAME, password=PASSWORD)
        to_plain_bash(c)
        print(f"      ok    4/10 {USERNAME} logged in with the password Setup set")

        # WHY findmnt AND stat AND ls FOR /home, and no `zfs list` anywhere:
        # this is a login shell belonging to the account Setup created, and
        # `zfs list` needs /dev/zfs, so it would need a sudo password typed over
        # a serial line. findmnt names the dataset serving a path — which is the
        # whole question — and stat answers from st_dev, which needs nothing at
        # all. AccountStep asks the same two questions inside the chroot.
        body = ask(c, "echo P3-"'"BEGIN"'"; "
                      "findmnt -no SOURCE,FSTYPE /; "
                      f"echo HOMEMNT $(findmnt -no SOURCE,FSTYPE /home/{USERNAME}); "
                      f"echo HOMESTAT $(stat -c '%U:%G %a %d' /home/{USERNAME}); "
                      "echo ROOTDEV $(stat -c '%d' /); "
                      f"echo HOMEHAS $(ls -A /home/{USERNAME} | tr '\\n' ' '); "
                      "echo HOMEDIRS $(ls -1 /home | tr '\\n' ' '); "
                      "cat /etc/os-release; "
                      "hostname; "
                      "cat /proc/cmdline; "
                      "echo P3-"'"END"',
                   "verification", timeout=180)
        body = body.split("P3-BEGIN", 1)[-1].split("P3-END", 1)[0]
        print("\n--- what the installed system says ---")
        print(body.strip())
        print("--- ")

        # 5: / is served from a boot environment, not from anything else.
        if f"rpool/ROOT/os7_{version}_" in body and "zfs" in body:
            print(f"      ok    5/10 / is rpool/ROOT/os7_{version}_…")
        else:
            print(f"      FAIL  / is not a boot environment named for {version}")
            ok = False

        # 6/7: the identity, on the INSTALLED system.
        if f'IMAGE_VERSION="{version}"' in body or f"IMAGE_VERSION={version}" in body:
            print(f"      ok    6/10 IMAGE_VERSION is {version}")
        else:
            print(f"      FAIL  IMAGE_VERSION on the disk is not {version}")
            ok = False
        if "ID=ubuntu" in body and 'VERSION_ID="26.04"' in body:
            print("      ok    7/10 ID and VERSION_ID are untouched (Intune, L16)")
        else:
            print("      FAIL  the Intune-matched os-release fields were changed")
            ok = False
        if 'VARIANT_ID="server"' in body:
            print("      ok         VARIANT_ID=server (the headless install)")
        else:
            print("      note       VARIANT_ID is not 'server'")

        # 8: the name that was typed.
        if HOSTNAME in body:
            print(f"      ok    8/10 the computer is called {HOSTNAME}")
        else:
            print(f"      FAIL  the hostname is not {HOSTNAME}")
            ok = False

        # And the one that decides everything else, BUILD-NOTES #15.
        if "boot=zfs" in body:
            print("      ok         boot=zfs is on the kernel command line")
        else:
            print("      FAIL  boot=zfs is missing - this boot was luck")
            ok = False

        # -- 9 and 10: WHERE THE USER'S FILES ARE ---------------------------
        #
        # ADDED 2026-08-26, and the reason it is worth a paragraph is that its
        # ABSENCE is what let BUILD-NOTES #74 ship. `grep -rIn "/home"
        # installer/testing/*.py` returned nothing: every harness here checked
        # the pools, the datasets, the bootloader and the account's ability to
        # log in, and not one of them looked at where that account's files
        # landed. So a machine whose home directory was inside the boot
        # environment — the one thing SETUP-PLAN §4.4's layout exists to
        # prevent — passed `run-phase3.py all` for two months.
        #
        # Setup now passes -UserName to New-OS7Storage and AccountStep proves
        # the home is its own filesystem inside the chroot. This is the same
        # claim, made about a MACHINE THAT HAS BOOTED, which is the only place
        # `zfs mount -a` and the dataset's canmount have had their say.
        def line(tag):
            for l in body.replace("\r", "").splitlines():
                if l.strip().startswith(tag + " "):
                    return l.strip()[len(tag) + 1:].strip()
            return ""

        home_mnt = line("HOMEMNT")
        home_stat = line("HOMESTAT")
        root_dev = line("ROOTDEV")
        home_has = line("HOMEHAS")
        home_dirs = line("HOMEDIRS")
        print(f"    /home/{USERNAME}: {home_mnt or '(not a mount point)'} | {home_stat}")
        print(f"    /home holds: {home_dirs}")

        if "rpool/USERDATA/" in home_mnt and "zfs" in home_mnt:
            print(f"      ok    9/10 /home/{USERNAME} is {home_mnt.split()[0]}")
        else:
            print(f"      FAIL  9/10 /home/{USERNAME} is NOT on a USERDATA dataset "
                  "- a rollback would take the user's files with the system "
                  "(BUILD-NOTES #74)")
            ok = False

        # THE SECOND WITNESS, and it is not redundant: findmnt reads
        # /proc/self/mountinfo, and st_dev is the kernel's answer about the
        # inode itself. The failure this pair catches is a mount table that says
        # one thing while the directory is served by another.
        parts = home_stat.split()
        if len(parts) == 3 and root_dev and parts[2] != root_dev:
            print(f"      ok         st_dev agrees: {parts[2]}, and / is {root_dev}")
        else:
            print(f"      FAIL       st_dev says /home/{USERNAME} is on the same "
                  f"filesystem as / ({home_stat!r} vs {root_dev!r})")
            ok = False

        owned = parts[0] == f"{USERNAME}:{USERNAME}" if parts else False
        furnished = ".bashrc" in home_has
        if owned and furnished:
            print(f"      ok   10/10 it is {parts[0]}, mode {parts[1]}, "
                  "and furnished from /etc/skel")
        else:
            # `useradd -m` finds the directory already there, warns, EXITS 0 and
            # copies no skel and changes no ownership (BUILD-NOTES #78). A home
            # the account cannot write to is the failure this catches.
            print(f"      FAIL 10/10 /home/{USERNAME} is '{home_stat}' holding "
                  f"'{home_has}' - useradd left it alone (BUILD-NOTES #78)")
            ok = False

        # The phantom. Every machine installed before 2026-08-26 has an empty
        # dataset here, named after New-OS7Storage's old -UserName default.
        if " os7 " in f" {home_dirs} ":
            print("      FAIL       /home/os7 exists: New-OS7Storage was not told "
                  "the account name")
            ok = False
        else:
            print("      ok         and there is no phantom /home/os7 beside it")
        return ok
    finally:
        c.close()


def phase_walk(font):
    """THE INTERACTIVE PATH, all of it — screens 1 to 9 by hand, to the Complete
    screen, with a real install behind it.

    This phase exists because `--unattend` cannot stand in for it, and the reason
    is not a preference. At 1d764e0 - the commit whose message is "os7-setup
    installs a machine, and the machine boots" - os7-setup could not get past
    screen 6: the confirmation validated the WHOLE plan, including an account
    nobody had been asked for yet, so pressing `F` produced "no user account was
    named" and screen 7 was unreachable. Every automated check in the repository
    passed throughout. `--unattend` hands over a plan that already has an account in it,
    `--storage-only` skips the account check by design, and the one harness that
    drove the screens by hand had never been taught that Phase 3 inserted screens
    7 and 8 - it pressed `F`, waited for a progress bar, and reported the error
    screen as "the executor is running: FAIL".

    So: the KEYBOARD is the input, from the first ENTER to the Complete screen,
    and every value on that last screen is one somebody typed.

    THERE IS NO INTERACTIVE `--storage-only`. From screen 7 onwards this installs
    an entire operating system, which is why it lives here and not in
    run-phase2.py - that file's contract is that every invocation asks for
    storage alone.

    It types the same passphrase, password, computer name and account name that
    `install` puts in its plan file, so the disk it leaves behind is one
    `./run-phase3.py boot` can verify without knowing which of the two built it.
    """
    print("\n  walk — the whole flow, driven by keypresses")

    # THE PRECONDITION FOR SCREEN 9, CHECKED BEFORE ANY KEY IS PRESSED.
    #
    # NetworkScreen.Entry SKIPS screen 9 entirely on a machine with no network
    # adapter — deliberately, because an air-gapped appliance is a real machine
    # and a list with one apologetic row is worse than not stopping. The
    # consequence for this harness is that a lab without a NIC walks straight
    # past the screen it is here to test AND REPORTS SUCCESS, because every
    # remaining assertion still holds.
    #
    # That is the same class as BUILD-NOTES #45 and it is worth naming in its
    # general form: A CHECK THAT CANNOT SEE SOMETHING MUST SAY "NOT CHECKED",
    # NEVER "FINE". Raised by os7-d7, who hit the same shape twice in one
    # afternoon from the other direction.
    if not lab.nic:
        print("      FAIL  this lab has no NIC, so screen 9 would be SKIPPED and")
        print("            this walk would prove nothing about it. Lab(nic=True).")
        return False

    rel = medium_release()
    version = rel["version"]

    lab.prepare()
    c, q = lab.boot(CMDLINE, "walk")
    ok = True
    try:
        def shoot(name, pause=1.5):
            time.sleep(pause)
            return lab.shoot(q, name)

        def page_of(w, h, rgb):
            """Everything on the screen, in white AND in the brand blue.

            Both, because §3.1 puts the sentences that matter most in the brand
            colour - "ALL DATA ON THIS DISK WILL BE LOST", "Do not turn off the
            computer" - and reading only white finds nothing and calls it absent.
            """
            rows, cols = h // font.height, w // font.width
            white = [read_text(w, h, rgb, font, r, 0, cols).rstrip() for r in range(rows)]
            brand = [read_text(w, h, rgb, font, r, 0, cols, BRAND).rstrip()
                     for r in range(rows)]
            return "\n".join(white + brand)

        def on_screen(w, h, rgb, needle, what, fg=(255, 255, 255)):
            rows, cols = h // font.height, w // font.width
            for row in range(rows):
                if needle in read_text(w, h, rgb, font, row, 0, cols, fg).rstrip():
                    print(f"      ok    {what}")
                    return True
            print(f"      FAIL  {what}: '{needle}' is not on the screen in {hexc(fg)}")
            return False

        def press(qcode, gap=0.06):
            """One key, then a gap.

            THE GAP IS NOT POLITENESS - BUILD-NOTES #34. QEMU holds each key for
            a fixed time (20 ms as vmscreen sends them) and a USB HID keyboard
            cannot report two independent presses at once, so keys sent closer
            together than the hold OVERLAP and all but one vanish. That is how a
            typed passphrase once arrived as a single character, with Setup
            correctly complaining it was too short.
            """
            q.send_key(qcode)
            time.sleep(gap)

        def typed(text):
            """Type a string, THROUGH THE HID KEYBOARD.

            So it travels the path a person's keystrokes do - USB, the kernel
            keymap, the VT's XLATE translation. Writing escape sequences into a
            pipe would prove nothing about either layer.
            """
            for ch in text:
                press(QCODE.get(ch, ch), 0.03)

        # -- screens 1, 2, 3: Welcome, Licence, Regional ---------------------
        w, h, rgb = shoot("40-welcome", 3.0)
        ok &= on_screen(w, h, rgb, "Welcome to Setup", "screen 1 is Welcome")
        press("ret")
        w, h, rgb = shoot("41-licence", 1.5)
        press("f8", 1.5)
        # The defaults are accepted: this phase is about the flow, and the
        # regional values have their own coverage in run-phase1. ENTER continues
        # on arrival; this was three DOWNs to get past a screen that came up on
        # Language (BUILD-NOTES #77).
        time.sleep(0.5)
        press("ret")

        # -- screen 4: the disk ----------------------------------------------
        w, h, rgb = shoot("42-disk", 2.0)
        ok &= on_screen(w, h, rgb, "install OS/7 on the disk", "screen 4 is Select a disk")
        press("down")               # past the setup medium, which L12 refuses
        time.sleep(0.5)
        press("ret")

        # -- screen 5: the layout, and the passphrase ------------------------
        w, h, rgb = shoot("43-layout", 2.0)
        ok &= on_screen(w, h, rgb, "storage settings", "screen 5 is Storage layout")
        press("ret", 1.0)           # refused: there is no passphrase yet
        #
        # ENTER AGAIN, WITHOUT MOVING FIRST. Refusing also moves the selection
        # onto the offending row, which is right for a person and wrong for a
        # harness that navigates there itself: run-phase2 once pressed UP as
        # well, landed on Encryption, and turned encryption off.
        press("ret")                # ENTER on the row it moved the selection to
        w, h, rgb = shoot("44-passphrase", 1.5)
        ok &= on_screen(w, h, rgb, "passphrase for the encrypted disk",
                        "the passphrase prompt")
        for _ in range(2):
            typed(PASSPHRASE)
            press("ret", 1.0)
        w, h, rgb = shoot("44b-passphrase-set", 1.5)
        press("ret")                # The settings are correct

        # -- screen 6: the gate ----------------------------------------------
        w, h, rgb = shoot("45-confirm", 2.0)
        ok &= on_screen(w, h, rgb, "about to write to the disk",
                        "screen 6 is the confirmation")
        press("f")

        # -- screen 7: the account -------------------------------------------
        w, h, rgb = shoot("46-account", 2.5)
        if "Setup cannot continue" in page_of(w, h, rgb):
            print("      FAIL  screen 6 refused its own plan - screen 7 is unreachable")
            for line in page_of(w, h, rgb).splitlines():
                if line:
                    print(f"            {line}")
            return False
        ok &= on_screen(w, h, rgb, "a name for this computer", "screen 7 is the account form")

        # The computer name arrives PRE-FILLED with "os7" (AccountScreen fills
        # the fields from the plan so ESC and ENTER show what was typed), so it
        # is cleared before anything is typed into it. More backspaces than
        # characters: an empty field returns them unhandled, which costs nothing.
        for _ in range(10):
            press("backspace", 0.03)
        typed(HOSTNAME)
        press("tab")
        typed(USERNAME)
        press("tab")                # Full name, left blank - it is optional
        press("tab")
        typed(PASSWORD)
        press("tab")
        typed(PASSWORD)
        w, h, rgb = shoot("47-account-filled", 1.0)
        ok &= on_screen(w, h, rgb, HOSTNAME, "the computer name is in the field")
        ok &= on_screen(w, h, rgb, USERNAME, "and the account name")
        press("ret")

        # -- screen 8 does not exist here, and that is the assertion ---------
        #
        # arm64 is server-only (README), so ModeScreen.Next skips the GUI/headless
        # question. On amd64 there would be one more ENTER here; no amd64 ISO has
        # ever been walked.
        w, h, rgb = shoot("47b-after-account", 3.0)
        page = page_of(w, h, rgb)
        if "Choose how this computer will be used" in page:
            print("      FAIL  screen 8 appeared on arm64, which ships no desktop")
            return False
        if "Setup cannot continue" in page:
            print("      FAIL  the plan was refused after screen 7")
            for line in page.splitlines():
                if line:
                    print(f"            {line}")
            return False

        # -- screen 9: the network (Phase 3b) --------------------------------
        #
        # THIS IS WHERE BUILD-NOTES #45 WOULD HAVE STRUCK AGAIN. Screen 9 was
        # inserted between screen 8 and the executor, and this walk previously
        # went straight from screen 7's ENTER to a progress bar. A harness that
        # was not taught about the new screen would press ENTER into it, get the
        # executor anyway, and report success - which is exactly how the screen-6
        # gate bug survived every automated check in the repository.
        ok &= on_screen(w, h, rgb, "network connection", "screen 9 is the network screen")

        # IN BLACK, because the adapter row is SELECTED. SelectionList draws the
        # highlighted row black-on-grey across the full inner width, so reading
        # only white finds nothing and would report the NIC as absent - which is
        # the same mistake `page_of` exists to avoid for the brand-blue
        # sentences, in a third colour.
        ok &= on_screen(w, h, rgb, "virtio_net", "the virtio NIC is in the adapter list",
                        fg=(0, 0, 0))

        # F4 = apply it here and now (D12). The live medium has the whole stack,
        # so this is a REAL DHCP lease on a REAL interface, and the address is
        # known before the VM started because user-mode networking is fixed.
        #
        # POLLED, NOT SLEPT. NetworkProbe waits up to 30 s for a lease, and how
        # long it actually takes depends on how loaded this Mac is. A fixed sleep
        # would photograph a screen that has not got there yet and report "no
        # lease" — os7-d7 hit exactly that twice in one afternoon on 2026-08-25
        # with a probe that waited 95 s of wall-clock time for a GRUB menu, and
        # both times the diagnosis named a cause the screen did not have.
        press("f4")
        print("      testing the live network … (a real DHCP lease, up to 45s)")
        got_lease = False
        for attempt in range(15):
            time.sleep(3)
            w, h, rgb = lab.shoot(q, "48-network-tested")
            page = page_of(w, h, rgb)
            if DHCP_ADDRESS in page:
                got_lease = True
                break
            if "did not" in page or "Check the passphrase" in page:
                break
        if got_lease:
            print(f"      ok    F4 took a real lease on the live medium ({DHCP_ADDRESS})")
        else:
            ok = False
            print(f"      FAIL  F4 did not produce {DHCP_ADDRESS} within 45s")
            for line in page.splitlines():
                if line.strip():
                    print(f"            {line.rstrip()}")

        press("ret")

        w, h, rgb = shoot("48b-executing", 4.0)
        page = page_of(w, h, rgb)
        if "Setup cannot continue" in page:
            print("      FAIL  the plan was refused at the executor's gate")
            for line in page.splitlines():
                if line:
                    print(f"            {line}")
            return False
        if "Do not turn off the computer" in page:
            print("      ok    the executor is running after screen 9")
        else:
            print("      FAIL  the executor did not start after screen 9")
            for line in page.splitlines():
                if line:
                    print(f"            {line}")
            return False

        # -- screens 10 and 11, watched, then 12 -----------------------------
        #
        # WATCHED ON THE SCREEN, not on the serial line: os7-setup writes to tty1
        # and logs to a file, so there is nothing on the console to wait for. The
        # screen is the interface, so the screen is what gets read.
        #
        # Thirty minutes, because that is what this actually is: unsquashfs of a
        # 2 GB image onto ZFS-on-LUKS, argon2id sized at 512 MB (§4.5), and
        # update-initramfs. A timeout that fires during a working install is a
        # harness reporting a bug it created.
        print("      waiting for the install … (unsquashfs + initramfs; ~15-25 min)")
        deadline = time.time() + 1800
        seen = ""
        while time.time() < deadline:
            time.sleep(20)
            w, h, rgb = lab.shoot(q, "49-complete")
            page = page_of(w, h, rgb)
            if "Setup has prepared this computer" in page:
                break
            if "Setup cannot continue" in page:
                print("      FAIL  the install failed; the error screen is up")
                for line in page.splitlines():
                    if line:
                        print(f"            {line}")
                return False
            # The step name, printed when it changes, so a stall is visible as a
            # step that stopped moving rather than as a silent twenty minutes.
            for line in page.splitlines():
                stripped = line.strip()
                if stripped.endswith("…") and stripped != seen:
                    seen = stripped
                    print(f"        {stripped}")
        else:
            print("      FAIL  the install never reached the Complete screen")
            return False

        # -- screen 12: what it says is what was typed -----------------------
        print("      the Complete screen:")
        ok &= on_screen(w, h, rgb, "Setup has prepared this computer",
                        "screen 12 is Setup is complete")
        ok &= on_screen(w, h, rgb, version, f"it names the version on the medium ({version})")
        ok &= on_screen(w, h, rgb, TARGET, "and the disk that was chosen")
        ok &= on_screen(w, h, rgb, "LUKS2 (passphrase set)", "encryption, with a passphrase")
        ok &= on_screen(w, h, rgb, HOSTNAME, f"the computer name that was typed ({HOSTNAME})")
        ok &= on_screen(w, h, rgb, USERNAME, f"the account that was typed ({USERNAME})")
        ok &= on_screen(w, h, rgb, "(headless)", "headless, as arm64 must be")
        ok &= on_screen(w, h, rgb, "press ENTER to restart", "and it offers a restart")

        # NOT "NO OPERATING SYSTEM HAS BEEN COPIED". That sentence was Phase 2's
        # Complete screen being honest about a disk that could not boot; Phase 3
        # copies a system, so a Complete screen still saying it would be the
        # screen lying in the other direction.
        if "NO OPERATING SYSTEM" in page_of(w, h, rgb):
            print("      FAIL  the Complete screen still carries the Phase 2 wording")
            ok = False
        else:
            print("      ok    it no longer says the disk holds no operating system")

        # The pools are exported by TeardownStep, not by this harness - the same
        # argument `install` makes. Asked, because the next boot is where the
        # difference between "the installer did it" and "the harness did it"
        # shows, and by then it is too late to tell them apart.
        text = ask(c, "zpool list -H -o name || true", "imported pools")
        body = text.split("zpool list -H -o name || true", 1)[-1]
        if "rpool" in body or "bpool" in body:
            print("      FAIL  a pool is still imported after the Complete screen")
            ok = False
        else:
            print("      ok    the installer exported both pools")

        print("      note  the disk on the bench is now the one this walk built;")
        print("            `./run-phase3.py boot` boots it.")
        return ok
    finally:
        q.close()
        c.close()


PHASES = {"install": phase_install, "boot": phase_boot, "walk": phase_walk}


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        lab.reset()
        return 0

    print("### os7-setup Phase 3 — the disk becomes a system")
    results = {}
    if what in ("all", "install"):
        results["install"] = phase_install()
        # No point booting a disk the install did not finish on: the failure
        # would be reported as "does not boot", which is true and useless.
        if what == "all" and not results["install"]:
            print("\n### Phase 3 result\n    install   FAIL (boot not attempted)")
            return 1
    if what in ("all", "boot"):
        results["boot"] = phase_boot()
    if what in ("all", "walk"):
        # LAST in `all`, on purpose. It rebuilds the target disk from scratch, so
        # running it before `boot` would have `boot` verify the walk's machine
        # and never the unattended one. Afterwards the disk on the bench is the
        # walk's, and `./run-phase3.py boot` will say whether that one boots too.
        fetch_font()
        results["walk"] = phase_walk(load_font(FONT))
    if not results:
        raise SystemExit(__doc__)

    print("\n### Phase 3 result")
    for name, good in results.items():
        print(f"    {name:<9} {'PASS' if good else 'FAIL'}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
