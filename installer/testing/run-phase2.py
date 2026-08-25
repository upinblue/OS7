#!/usr/bin/env python3
"""
Phase 2 — os7-setup writes to a disk, and the disk is checked afterwards.

SETUP-PLAN §10 Phase 2 is the storage executor. Unlike Phase 1 the deliverable
is not a screen, it is a partitioned, encrypted, ZFS-populated disk — so the
screens are walked and then the RESULT IS READ BACK OFF THE DEVICE:

    ./run-phase2.py dryrun     --unattend --dry-run: every command, none run
    ./run-phase2.py unattend   --unattend for real, then verify the disk
    ./run-phase2.py walk       drive screens 4-6 by hand, up to the gate
    ./run-phase2.py rollback   make a step fail; check nothing is left behind
    ./run-phase2.py existing   install, then point Setup at that same disk again
    ./run-phase2.py all        all five                     (default)
    ./run-phase2.py reset      discard the VM state

EVERY INVOCATION HERE PASSES `--storage-only`, and that is the harness's
contract rather than an oversight. `--unattend` on its own now performs the WHOLE
install - Phase 3 made that the default, because an unattended mode that does
less than the interactive one is a mode nothing tests the same way. This file
tests the storage executor, so it asks for exactly that; the full install and the
boot that follows it belong to `run-phase3.py`.

`walk` OBEYS THAT CONTRACT BY STOPPING, and it is worth saying why rather than
leaving it as a shorter phase than it used to be. THERE IS NO INTERACTIVE
`--storage-only`: from screen 7 onwards the interactive path installs an entire
operating system. So the walk drives screens 4, 5 and 6, presses `F`, checks that
the ACCOUNT SCREEN is what appears - and checks on the device that pressing `F`
wrote nothing - and hands over. `./run-phase3.py walk` drives the whole flow to
the Complete screen.

That handover is the fix for a bug this file helped hide. Phase 3 inserted
screens 7 and 8 between the confirmation and the executor; this walk still
pressed `F` and waited for a progress bar, so a flow that could not get past
screen 6 was reported as "the executor is running: FAIL".

The VM gets a SECOND, BLANK disk. The live medium is the first one, which is
also the point: L12 requires Setup to refuse its own boot medium, and a run with
only one disk could not tell a correct refusal from a broken enumeration.

WHAT "VERIFY" MEANS HERE, and it is the whole reason this file is longer than
the screens it drives: `sgdisk -p`, `cryptsetup luksDump`, `zpool list` and
`zfs list` are asked what is on the disk, and their answers are compared with
SETUP-PLAN §4.4. Not "the installer said it worked" — the installer says that
into its own log, which is exactly the class of evidence this project has been
bitten by four times.

`existing` is the odd one out and the newest: every other phase starts from a
blank disk, so none of them meets the case a real machine is usually in — an
OS/7 is already installed. It creates that fixture itself with one unattended
run, reboots, and then checks that Setup RECOGNISES it, READS ITS VERSION OFF
THE DISK, and requires a second deliberate ENTER before erasing it. That is also
the only round trip the version number gets: written into a dataset name by one
boot, read back by a different mechanism in the next.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmscreen import Lab, hexc, histogram, load_font, read_text, run

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "build", "lib"))
import palette                                                   # noqa: E402

FIELD, BRAND, GREY = palette.FIELD, palette.BRAND, palette.GREY

lab = Lab("phase2", target_gb=24, iso_as_disk=True)
FONT = os.path.join(lab.dir, "os7-fixedsys-16x32.psf.gz")
CELL = (16, 32)

CMDLINE = ("boot=casper os7.setup=1 systemd.wants=os7-setup.service "
           "fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 "
           "console=ttyAMA0,115200")

# The live entry: no Setup, so the harness owns the machine and can run
# os7-setup by hand with --unattend.
LIVE_CMDLINE = "boot=casper fbcon=nodefer quiet splash console=ttyAMA0,115200"

# The disk QEMU gives the guest, by the serial= in vmscreen's -device line. The
# installer stores a by-id path in the plan, so this is what the plan must say.
TARGET = "/dev/disk/by-id/virtio-os7target"
PASSPHRASE = "os7-phase2-passphrase"

# §4.4's hierarchy, as the thing to compare against. Not a copy of what the
# code creates - a transcription of the PLAN, so that a change in the code that
# is not a change in the plan fails here.
WANT_DATASETS = [
    "rpool/ROOT", "rpool/DATA", "rpool/USERDATA",
    "rpool/DATA/log", "rpool/DATA/spool", "rpool/DATA/tmp", "rpool/DATA/srv",
    "rpool/DATA/snapd", "rpool/DATA/lib/networkmanager", "rpool/DATA/lib/authd",
    "rpool/DATA/lib/azcmagent",
    "bpool/BOOT",
]


def fetch_font():
    if os.path.exists(FONT):
        return
    os.makedirs(lab.dir, exist_ok=True)
    run("docker", "run", "--rm", "--privileged", "--platform", "linux/arm64",
        "-v", f"{os.path.dirname(lab.iso)}:/iso:ro", "-v", f"{lab.dir}:/out",
        "os7-build:arm64", "bash", "-c",
        f"set -e; mkdir -p /mnt/iso /mnt/sq; "
        f"mount -o loop,ro /iso/{os.path.basename(lab.iso)} /mnt/iso; "
        "mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq; "
        "cp /mnt/sq/usr/share/consolefonts/os7-fixedsys-16x32.psf.gz /out/; "
        "umount /mnt/sq; umount /mnt/iso", stdout=subprocess.DEVNULL)


_mark = 0


def ask(c, command, label, timeout=180, marker=None):
    """Run something in the guest and return everything it printed.

    THE MARKER IS BUILT BY THE SHELL, NOT TYPED. `…; echo DONE` and then waiting
    for "DONE" matches the shell's ECHO of the command being typed, so `expect`
    returns before the command has run and the caller reads an empty buffer.
    That is docs/BUILD-NOTES.md #16 — "never expect a marker that the typed
    command itself contains" — and this harness walked straight into it: two
    `zpool list` checks reported missing pools that were plainly there, on the
    same disk whose datasets the next check listed successfully.

    `printf 'OK%s\n' 7` types the literal `OK%s` and prints `OK7`, so the two
    cannot be confused.
    """
    global _mark
    if marker is None:
        _mark += 1
        n = _mark
        marker = f"OK{n}"
        command = f"{command}; printf 'OK%s\n' {n}"
    c.drop()
    c.send(command)
    c.expect(marker, timeout, label)
    return c.text()


def show(text, keep):
    for line in text.splitlines():
        s = line.rstrip()
        if any(k in s for k in keep):
            print(f"        {s[:150]}")


# ---------------------------------------------------------------------------
# Reading the disk back
# ---------------------------------------------------------------------------
def verify_disk(c, encrypted=True):
    """Ask the disk what is on it, and compare with SETUP-PLAN §4.4."""
    ok = True
    print("      verifying the disk itself")

    # -- the partition table ------------------------------------------------
    text = ask(c, "sudo sgdisk -p " + TARGET, "partition table")
    for want in ("os7-esp", "os7-bpool", "os7-luks"):
        if want in text:
            print(f"      ok    partition {want}")
        else:
            print(f"      FAIL  partition {want} is not in the table")
            ok = False
    if "EF00" in text and "8309" in text:
        print("      ok    partition types EF00 (ESP) and 8309 (LUKS)")
    else:
        print("      FAIL  the partition types are wrong")
        show(text, ("Number", "EF00", "BF00", "8309"))
        ok = False

    # -- the ESP ------------------------------------------------------------
    text = ask(c, "sudo blkid /dev/disk/by-partlabel/os7-esp", "ESP")
    if 'TYPE="vfat"' in text and "OS7ESP" in text:
        print("      ok    the ESP is FAT32, labelled OS7ESP")
    else:
        print("      FAIL  the ESP is not a labelled FAT32 filesystem")
        show(text, ("os7-esp",))
        ok = False

    # -- the LUKS2 header ---------------------------------------------------
    if encrypted:
        text = ask(c, "sudo cryptsetup luksDump /dev/disk/by-partlabel/os7-luks | "
                      "grep -E 'Version|Label|PBKDF|Cipher:'", "LUKS header")
        if "Version:       	2" in text or "Version: \t2" in text or "Version:" in text and "2" in text:
            print("      ok    LUKS2 header present")
        else:
            print("      FAIL  no LUKS2 header")
            ok = False
        # argon2id and the pinned cost are D3/§4.5's decision: the default sizes
        # memory from the LIVE system's RAM, and the initramfs has to reproduce
        # it at boot with far less available.
        if "argon2id" in text:
            print("      ok    PBKDF is argon2id, as pinned")
        else:
            print("      FAIL  the PBKDF is not the pinned argon2id")
            show(text, ("PBKDF", "Version", "Label"))
            ok = False

        # And the passphrase actually opens it. Everything above is a header
        # that exists; this is the only check that the passphrase typed at
        # install time is the one that will unlock at boot - the trailing-newline
        # trap S3 found lives exactly here.
        text = ask(c,
                   f"printf '%s' '{PASSPHRASE}' | sudo cryptsetup open --test-passphrase "
                   "/dev/disk/by-partlabel/os7-luks && printf 'PASS%s\\n' OK "
                   "|| printf 'PASS%s\\n' BAD",
                   "passphrase test", marker="PASSOK|PASSBAD")
        if "PASSOK" in text:
            print("      ok    the passphrase opens the container")
        else:
            print("      FAIL  the passphrase does NOT open the container")
            ok = False

    # -- the pools ----------------------------------------------------------
    text = ask(c, "sudo zpool list -H -o name,health", "pools")
    for pool in ("rpool", "bpool"):
        if pool in text:
            print(f"      ok    pool {pool} exists")
        else:
            print(f"      FAIL  pool {pool} is missing")
            ok = False

    # bpool must be GRUB-readable or the machine cannot boot (D1, §4.2). The
    # feature set is what makes that true, so it is what gets asked.
    text = ask(c, "sudo zpool get -H -o value compatibility bpool", "bpool compat")
    if "grub2" in text:
        print("      ok    bpool is created with compatibility=grub2")
    else:
        print("      FAIL  bpool has no grub2 compatibility set — GRUB may not read it")
        ok = False

    # -- the dataset hierarchy (§4.4, D10) ----------------------------------
    text = ask(c, "sudo zfs list -H -o name -r rpool bpool", "datasets")
    for want in WANT_DATASETS:
        if want in text:
            print(f"      ok    dataset {want}")
        else:
            print(f"      FAIL  dataset {want} is missing")
            ok = False

    # THE decision the whole layout exists for. USERDATA and DATA must be
    # SIBLINGS of ROOT, never children of the boot environment - rolling back a
    # release must not roll back the user's files or the agents' state, and it
    # cannot be retrofitted afterwards (§4.4, D10).
    strays = [l.strip() for l in text.splitlines()
              if "rpool/ROOT/" in l and ("/USERDATA" in l or "/DATA" in l)]
    if strays:
        print(f"      FAIL  USERDATA or DATA is inside the boot environment: {strays[:3]}")
        ok = False
    else:
        print("      ok    USERDATA and DATA are siblings of ROOT, not children")

    # /var/lib/dpkg is inside the BE, and that one is non-negotiable: the
    # package database describes exactly the /usr that rolls with it.
    be = [l.strip() for l in text.splitlines() if l.strip().startswith("rpool/ROOT/os7_")]

    # -- THE VERSION REACHED THE DISK --------------------------------------
    #
    # This is the load-bearing check for the whole release-identity chain, and
    # it is here rather than in a build hook because here is the only place all
    # of it is real: build hook 0075 wrote the manifest, the OS7 module read it,
    # os7-setup asked the module for a name, and ZFS created a dataset with that
    # name on an actual disk. Every earlier check in that chain verifies a step;
    # this one verifies the RESULT.
    #
    # The version comes from the guest's own manifest rather than from a string
    # in this harness — the same argument run-phase1.fetch_release makes. A
    # harness that carries the expected version passes until somebody forgets to
    # edit it.
    manifest = ask(c, "cat /usr/lib/os7/release.json", "release manifest")
    version = None
    for raw in manifest.splitlines():
        stripped = raw.strip().rstrip(",")
        # The FIRST "version" key, which json.dump writes before any nested one.
        if stripped.startswith('"version"'):
            version = stripped.split(":", 1)[1].strip().strip('"')
            break

    if not version:
        print("      FAIL  the live medium has no version in /usr/lib/os7/release.json")
        print(f"            manifest read as: {manifest[:200]!r}")
        ok = False
    elif not be:
        print("      FAIL  there is no rpool/ROOT/os7_* boot environment to check")
        ok = False
    else:
        # os7_<release>_<stamp>; the dataset is rpool/ROOT/<that>.
        named = [l for l in be if f"/os7_{version}_" in l + "_"]
        if named:
            print(f"      ok    the boot environment carries version {version}: "
                  f"{named[0].split('/')[-1] if named[0].count('/') == 2 else named[0]}")
        else:
            print(f"      FAIL  no boot environment is named after version {version}")
            print(f"            the disk holds: {[l for l in be if l.count('/') == 2][:3]}")
            print("            0.0.0.0 here means the module did not read the manifest")
            ok = False

    if any(l.endswith("/var/lib/dpkg") for l in be):
        print("      ok    /var/lib/dpkg is inside the boot environment")
    else:
        print("      FAIL  /var/lib/dpkg is not inside the boot environment")
        ok = False
    if any(l.startswith("rpool/DATA/log") for l in text.splitlines()):
        print("      ok    /var/log is outside it")

    return ok


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
def write_plan(c, encrypt=True, disk=TARGET):
    """Put a plan file and a passphrase file in the guest's /tmp."""
    plan = ('{"version":1,"intent":"Install","language":"de_DE.UTF-8",'
            '"keyboard":"de","timezone":"Europe/Berlin","mode":"Headless",'
            f'"storage":{{"disk":"{disk}","layout":"single","efiMiB":512,'
            f'"bpoolGiB":2,"encrypt":{"true" if encrypt else "false"},"swap":"zram"}}}}')
    c.drop()
    c.send(f"printf '%s' '{plan}' > /tmp/plan.json")
    c.settle()
    c.drop()
    c.send(f"printf '%s' '{PASSPHRASE}' > /tmp/pass")
    c.settle()
    c.drop()
    c.send("sh -c 'wc -c < /tmp/plan.json; wc -c < /tmp/pass'")
    c.expect(r"\d+", 30, "plan written")


def phase_dryrun():
    """--dry-run must print every command and run none of them.

    Checked by looking at the DISK afterwards, not by trusting the word "would":
    a dry run that partitions is the single worst bug this option could have.
    """
    print("\n  dryrun — --unattend --dry-run writes nothing")
    c, q = lab.boot(LIVE_CMDLINE, "dryrun")
    ok = True
    try:
        write_plan(c)
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json --storage-only "
                      "--passphrase-file /tmp/pass --dry-run", "dry run")
        show(text, ("OS7-SETUP",))
        if "OS7-SETUP-DONE storage" in text:
            print("      ok    the dry run completed")
        else:
            print("      FAIL  the dry run did not complete")
            ok = False

        # The disk must be untouched. sgdisk on an empty disk says so.
        text = ask(c, f"sudo sgdisk -p {TARGET}", "disk after dry run")
        if "os7-esp" in text:
            print("      FAIL  --dry-run PARTITIONED THE DISK")
            ok = False
        else:
            print("      ok    the disk is still empty")
        return ok
    finally:
        q.close()
        c.close()


def phase_unattend():
    """The real thing, from a plan file, and then the disk is read back."""
    print("\n  unattend — --unattend for real")
    c, q = lab.boot(LIVE_CMDLINE, "unattend")
    ok = True
    try:
        write_plan(c)
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json --storage-only "
                      "--passphrase-file /tmp/pass", "unattended install", timeout=900)
        show(text, ("OS7-SETUP",))
        if "OS7-SETUP-DONE storage" not in text:
            print("      FAIL  the unattended run did not finish")
            show(text, ("FAILED", "command:", "output:"))
            return False

        ok &= verify_disk(c, encrypted=True)

        # Export and re-import, which is the question that matters at boot: a
        # pool that cannot be exported cleanly is a pool the installed system
        # will find "in use from another system" (L12).
        c.drop()
        c.send("sudo sh -c 'zpool export rpool bpool && printf \'EXP%s\\n\' OK "
               "|| printf \'EXP%s\\n\' BAD'")
        c.expect(r"EXP(OK|BAD)", 180, "export")
        if "EXPOK" in c.text():
            print("      ok    both pools export cleanly")
        else:
            print("      FAIL  the pools do not export")
            ok = False
        return ok
    finally:
        q.close()
        c.close()


def phase_rollback():
    """A failing step must leave nothing behind.

    Forced by pointing the plan at a disk that does not exist. The partition
    step fails, and what matters is that the executor's undo list runs and the
    real target is untouched — "rolls back ONLY what Setup created" cuts both
    ways.
    """
    print("\n  rollback — a failure leaves nothing behind")
    c, q = lab.boot(LIVE_CMDLINE, "rollback")
    ok = True
    try:
        write_plan(c, disk="/dev/disk/by-id/virtio-does-not-exist")
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json --storage-only "
                      "--passphrase-file /tmp/pass", "failing install", timeout=300)
        show(text, ("OS7-SETUP", "command:", "output:"))
        if "OS7-SETUP-FAILED" in text:
            print("      ok    it failed, and said what failed")
        else:
            print("      FAIL  a plan naming a missing disk did not fail")
            ok = False

        # The real disk must be untouched, and no mapping or pool left over.
        text = ask(c, f"sudo sh -c 'sgdisk -p {TARGET} 2>&1 | tail -3; "
                      "ls /dev/mapper/; zpool list 2>&1 | tail -2'", "leftovers")
        show(text, ("os7", "no pools", "control", "rpool", "bpool"))
        if "os7-esp" in text:
            print("      FAIL  the target disk was partitioned anyway")
            ok = False
        else:
            print("      ok    the target disk is untouched")
        if "os7_root" in text:
            print("      FAIL  a LUKS mapping was left open")
            ok = False
        else:
            print("      ok    no LUKS mapping was left behind")
        if "rpool" in text or "bpool" in text:
            print("      FAIL  a pool was left behind")
            ok = False
        else:
            print("      ok    no pool was left behind")
        return ok
    finally:
        q.close()
        c.close()


def phase_existing(font):
    """Setup, pointed at a disk that ALREADY carries an OS/7 installation.

    Every other phase here starts from a blank disk (`lab.prepare()` recreates
    the qcow2), so nothing else in this harness ever exercises the one case a
    real machine is usually in: **there is already an OS/7 on it.**

    Two things are under test and only the second is about safety:

      1. `ExistingInstalls.Probe` — screen 4 imports the existing `bpool`
         READ-ONLY, reads the boot-environment names out of it, and reports the
         version. That path is written against `zpool(8)` and had never been run
         against a disk this installer made. This is where the argument becomes
         evidence.
      2. Erasing an installation takes a SECOND, deliberate ENTER, and the first
         one names what it found.

    It is also the only check that the version SURVIVES a round trip: the number
    the installer wrote into a dataset name in the first boot is read back off
    the disk, by a different mechanism, in the second.

    Done in one phase and two boots rather than two phases, because the disk the
    first boot leaves behind IS the fixture the second needs.
    """
    print("\n  existing — Setup meets an OS/7 that is already there")

    # -- boot one: put an OS/7 on the disk, unattended (no UI, no keypresses) --
    c, q = lab.boot(LIVE_CMDLINE, "existing-install")
    version = None
    try:
        write_plan(c)
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json --storage-only "
                      "--passphrase-file /tmp/pass", "unattended install", timeout=900)
        if "OS7-SETUP-DONE storage" not in text:
            print("      FAIL  could not create the fixture: the install did not finish")
            show(text, ("FAILED", "command:", "output:"))
            return False

        manifest = ask(c, "cat /usr/lib/os7/release.json", "release manifest")
        for raw in manifest.splitlines():
            stripped = raw.strip().rstrip(",")
            if stripped.startswith('"version"'):
                version = stripped.split(":", 1)[1].strip().strip('"')
                break

        # Export, or the second boot finds the pools "in use from another
        # system" and the probe measures that instead of what it came for.
        c.drop()
        c.send("sudo sh -c 'zpool export rpool bpool && printf \'EXP%s\\n\' OK "
               "|| printf \'EXP%s\\n\' BAD'")
        c.expect(r"EXP(OK|BAD)", 180, "export")
        if "EXPOK" not in c.text():
            print("      FAIL  the fixture pools would not export")
            return False
        print(f"      ok    fixture: a disk carrying OS/7 {version}")
    finally:
        q.close()
        c.close()

    if not version:
        print("      FAIL  the live medium has no version to compare against")
        return False

    # -- boot two: run Setup interactively and look at screen 4 ---------------
    c, q = lab.boot(CMDLINE, "existing-detect")
    ok = True
    try:
        def shoot(name, pause=1.5):
            time.sleep(pause)
            return lab.shoot(q, name)

        def on_screen(w, h, rgb, needle, what, fg=(255, 255, 255)):
            rows, cols = h // font.height, w // font.width
            for row in range(rows):
                if needle in read_text(w, h, rgb, font, row, 0, cols, fg).rstrip():
                    print(f"      ok    {what}")
                    return True
            print(f"      FAIL  {what}: '{needle}' is not on the screen in {hexc(fg)}")
            return False

        # Welcome -> Licence -> Regional -> Disk, as phase_walk does.
        for key, pause in (("ret", 1.5), ("f8", 1.5)):
            q.send_key(key)
            time.sleep(pause)
        for _ in range(3):
            q.send_key("down")
        time.sleep(0.5)
        q.send_key("ret")
        w, h, rgb = shoot("30-disk-existing", 2.0)
        ok &= on_screen(w, h, rgb, "install OS/7 on the disk", "screen 4 is Select a disk")

        # The cheap tier: the LIST says so, from partition labels alone.
        ok &= on_screen(w, h, rgb, "OS/7 installation",
                        "the list marks the disk as carrying OS/7")

        # Past the setup medium to the target, then ENTER.
        q.send_key("down")
        time.sleep(0.5)
        q.send_key("ret")

        # POLLED, not slept.
        #
        # ENTER here runs the probe: import bpool read-only, list its boot
        # environments, export it. That is seconds rather than frames, and how
        # many seconds depends on the VM. A fixed sleep would be a coin toss
        # between a flaky failure and a slow harness, and the failure would read
        # as "Setup did not detect the installation" — which is a wrong answer,
        # not a slow one.
        needle = f"already carries OS/7 {version}"
        deadline = time.time() + 90
        w = h = rgb = None
        while True:
            w, h, rgb = shoot("31-existing-named", 2.0)
            rows, cols = h // font.height, w // font.width
            if any(needle in read_text(w, h, rgb, font, r, 0, cols, BRAND).rstrip()
                   for r in range(rows)):
                break
            if time.time() > deadline:
                print(f"      FAIL  screen 4 never named the installed version "
                      f"({version}) within 90s")
                # What it DID say, so the failure is diagnosable from the log
                # rather than only from the screendump.
                for r in range(rows):
                    line = read_text(w, h, rgb, font, r, 0, cols, BRAND).rstrip()
                    if line:
                        print(f"            brand row {r}: {line}")
                return False

        print(f"      ok    screen 4 names the installed version ({version})")
        ok &= on_screen(w, h, rgb, "Press ENTER again",
                        "erasing it needs a second ENTER", fg=BRAND)

        # And the second ENTER does move on — a confirmation that cannot be
        # confirmed is a dead end, not a safeguard.
        q.send_key("ret")
        w, h, rgb = shoot("32-existing-confirmed", 2.5)
        ok &= on_screen(w, h, rgb, "storage settings",
                        "a second ENTER continues to screen 5")
        return ok
    finally:
        q.close()
        c.close()


def phase_walk(font):
    """Screens 4, 5 and 6, driven by keypresses, up to and through the gate.

    The storage SCREENS, which is a different subject from the storage EXECUTOR
    the other four phases test. It ends where Phase 2 ends: `F` is pressed, the
    account screen appears, ESC comes back, and the target disk is asked whether
    any of that touched it. Nothing here runs an executor, so nothing here needs
    `--storage-only` to be told not to.
    """
    print("\n  walk — screens 4, 5 and 6, by hand, up to the gate")
    c, q = lab.boot(CMDLINE, "walk")
    ok = True
    try:
        def shoot(name, pause=1.5):
            time.sleep(pause)
            return lab.shoot(q, name)

        def on_screen(w, h, rgb, needle, what, fg=(255, 255, 255)):
            rows = h // font.height
            cols = w // font.width
            for row in range(rows):
                if needle in read_text(w, h, rgb, font, row, 0, cols, fg).rstrip():
                    print(f"      ok    {what}")
                    return True
            print(f"      FAIL  {what}: '{needle}' is not on the screen in {hexc(fg)}")
            return False

        # Welcome -> Licence -> Regional -> Disk
        for key, pause in (("ret", 1.5), ("f8", 1.5)):
            q.send_key(key)
            time.sleep(pause)
        q.send_key("down")          # Keyboard
        q.send_key("down")          # Time zone
        q.send_key("down")          # The settings are correct
        time.sleep(0.5)
        q.send_key("ret")
        w, h, rgb = shoot("20-disk", 2.0)
        ok &= on_screen(w, h, rgb, "install OS/7 on the disk", "screen 4 is Select a disk")

        # L12: the live medium is listed and refused. It is the FIRST disk, so
        # the selection starts on it - pressing ENTER must be refused with a
        # reason rather than doing anything.
        q.send_key("ret")
        w, h, rgb = shoot("21-refused")
        ok &= on_screen(w, h, rgb, "cannot be used", "the setup medium is refused", fg=BRAND)

        # Down to the blank target, then continue.
        q.send_key("down")
        time.sleep(0.5)
        q.send_key("ret")
        w, h, rgb = shoot("22-layout", 2.0)
        ok &= on_screen(w, h, rgb, "storage settings", "screen 5 is Storage layout")
        # White: the selected row is "The settings are correct", so the
        # Encryption row is ordinary body text. Reading it as the selection
        # colour finds nothing and reports missing text that is on the screen.
        ok &= on_screen(w, h, rgb, "LUKS2", "encryption is LUKS2 by default")

        # ENTER on "The settings are correct" must be REFUSED without a
        # passphrase - the one place the flow will not move on.
        q.send_key("ret")
        w, h, rgb = shoot("23-needs-passphrase")
        ok &= on_screen(w, h, rgb, "Set a passphrase", "it refuses to continue without one", fg=BRAND)

        # ENTER straight away, WITHOUT moving first. Refusing to continue also
        # moves the selection onto the offending row - which is the right thing
        # for a person and the wrong assumption for a harness that "helpfully"
        # navigates there itself: the extra UP landed on Encryption and the
        # ENTER turned encryption off, so the next twelve checks failed about
        # a passphrase screen that was never going to appear.
        q.send_key("ret")
        w, h, rgb = shoot("24-passphrase")
        ok &= on_screen(w, h, rgb, "passphrase for the encrypted disk", "the passphrase prompt")
        ok &= on_screen(w, h, rgb, "no way to recover", "it says what a lost passphrase costs", fg=BRAND)
        for _ in range(2):
            for ch in PASSPHRASE:
                q.send_key(QCODE.get(ch, ch))
                time.sleep(0.02)
            q.send_key("ret")
            time.sleep(1.0)
        w, h, rgb = shoot("25-passphrase-set")

        q.send_key("ret")           # The settings are correct
        w, h, rgb = shoot("26-confirm", 2.0)
        ok &= on_screen(w, h, rgb, "about to write to the disk", "screen 6 is the confirmation")
        ok &= on_screen(w, h, rgb, "ALL DATA ON THIS DISK WILL BE LOST", "it says so plainly", fg=BRAND)

        # ENTER must do NOTHING here. Every other screen advances on ENTER, so a
        # person walking through with it would walk through this one too; F is
        # used nowhere else and cannot be pressed by momentum.
        q.send_key("ret")
        w, h, rgb = shoot("27-enter-does-nothing")
        ok &= on_screen(w, h, rgb, "about to write to the disk",
                        "ENTER does not confirm a destructive step")

        # F: THE GATE. It leads to SCREEN 7, and it writes nothing on the way.
        #
        # This is the assertion that was missing, and its absence cost a release.
        # At Phase 2 the executor was what came after `F`, so this harness
        # pressed `F` and waited for a progress bar. Phase 3 inserted screens 7
        # and 8 between the two and nothing here was told. What actually appeared
        # was the error screen - "no user account was named", ONE SCREEN BEFORE
        # the account is typed - and the walk reported FAIL at "the executor is
        # running", which reads as an executor problem and was not one.
        q.send_key("f")
        w, h, rgb = shoot("28-account", 2.5)

        # The regression's own signature, read first and printed whole. A
        # returning bug should be diagnosable from this log alone rather than
        # from three assertions failing about text that is not there.
        rows, cols = h // font.height, w // font.width
        page = "\n".join(read_text(w, h, rgb, font, r, 0, cols).rstrip()
                         for r in range(rows))
        if "Setup cannot continue" in page:
            print("      FAIL  screen 6 refused its own plan - the error screen is up")
            print("            screen 7 is unreachable; this is the 1d764e0 regression")
            for r in range(rows):
                line = read_text(w, h, rgb, font, r, 0, cols).rstrip()
                if line:
                    print(f"            {line}")
            return False

        ok &= on_screen(w, h, rgb, "a name for this computer",
                        "F on screen 6 leads to screen 7")
        ok &= on_screen(w, h, rgb, "Computer name:", "screen 7 asks for a computer name")
        ok &= on_screen(w, h, rgb, "User name:", "and for an account to administer it")

        # ESC comes back. Screen 6 is a gate, not a door that locks behind you -
        # and it is the first thing anybody does after being asked for a name
        # they have not decided on yet.
        q.send_key("esc")
        w, h, rgb = shoot("29-back-at-the-gate", 2.0)
        ok &= on_screen(w, h, rgb, "about to write to the disk",
                        "ESC from screen 7 returns to the confirmation")

        # AND NOTHING WAS WRITTEN. Asked of the DEVICE, not of the screen.
        #
        # §3 numbers the account 7 and the copy 10, so `F` is a decision and not
        # an action - which is a claim about a disk and therefore has to be
        # checked on the disk. lsblk lists the target's children: a blank disk
        # has none, a partitioned one has three.
        text = ask(c, f"lsblk -rno NAME,TYPE {TARGET}", "the target's partitions")
        parts = [l.split()[0] for l in text.replace("\r", "").splitlines()
                 if l.strip().endswith(" part")]
        if parts:
            print(f"      FAIL  F partitioned the disk before screen 7: {parts}")
            ok = False
        else:
            print("      ok    the target is still blank - F decides, it does not write")

        # AND THAT IS WHERE THIS PHASE STOPS, deliberately.
        #
        # Everything past screen 7 installs a whole operating system: there is no
        # interactive equivalent of `--storage-only`, so an interactive walk that
        # goes on from here would break this file's contract (see the top) and
        # take twenty-five minutes doing it. The full interactive install, to the
        # Complete screen, is `./run-phase3.py walk`.
        return ok
    finally:
        q.close()
        c.close()


# QEMU qcodes for the characters in the passphrase. Letters and digits are their
# own qcode; the rest have names.
QCODE = {"-": "minus", "_": "shift-minus", ".": "dot", "/": "slash", " ": "spc"}


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        lab.reset()
        return 0

    print("### os7-setup Phase 2 — the storage executor")
    lab.prepare()
    fetch_font()
    font = load_font(FONT)

    results = {}
    if what in ("all", "dryrun"):
        results["dryrun"] = phase_dryrun()
    if what in ("all", "unattend"):
        lab.prepare()                      # a fresh blank disk for each phase
        results["unattend"] = phase_unattend()
    if what in ("all", "rollback"):
        lab.prepare()
        results["rollback"] = phase_rollback()
    if what in ("all", "walk"):
        lab.prepare()
        results["walk"] = phase_walk(font)
    if what in ("all", "existing"):
        lab.prepare()
        results["existing"] = phase_existing(font)

    if not results:
        raise SystemExit(__doc__)
    print("\n### Phase 2 result")
    for name, ok in results.items():
        print(f"    {name:<9} {'PASS' if ok else 'FAIL'}")
    print(f"    screendumps in {lab.shots}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
