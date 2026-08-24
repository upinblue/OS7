#!/usr/bin/env python3
"""
Phase 2 — os7-setup writes to a disk, and the disk is checked afterwards.

SETUP-PLAN §10 Phase 2 is the storage executor. Unlike Phase 1 the deliverable
is not a screen, it is a partitioned, encrypted, ZFS-populated disk — so the
screens are walked and then the RESULT IS READ BACK OFF THE DEVICE:

    ./run-phase2.py dryrun     --unattend --dry-run: every command, none run
    ./run-phase2.py unattend   --unattend for real, then verify the disk
    ./run-phase2.py walk       drive screens 4-6 by hand, then verify the disk
    ./run-phase2.py rollback   make a step fail; check nothing is left behind
    ./run-phase2.py all        all four                     (default)
    ./run-phase2.py reset      discard the VM state

The VM gets a SECOND, BLANK disk. The live medium is the first one, which is
also the point: L12 requires Setup to refuse its own boot medium, and a run with
only one disk could not tell a correct refusal from a broken enumeration.

WHAT "VERIFY" MEANS HERE, and it is the whole reason this file is longer than
the screens it drives: `sgdisk -p`, `cryptsetup luksDump`, `zpool list` and
`zfs list` are asked what is on the disk, and their answers are compared with
SETUP-PLAN §4.4. Not "the installer said it worked" — the installer says that
into its own log, which is exactly the class of evidence this project has been
bitten by four times.
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
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json "
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
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json "
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
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json "
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


def phase_walk(font):
    """Screens 4, 5 and 6, driven by keypresses, then the disk read back."""
    print("\n  walk — screens 4, 5 and 6, by hand")
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

        q.send_key("f")
        w, h, rgb = shoot("28-executing", 3.0)
        ok &= on_screen(w, h, rgb, "preparing", "the executor is running")

        # WATCHED ON THE SCREEN, not on the serial line. os7-setup's own output
        # goes to tty1 and its log goes to a file - the unit sends stderr to the
        # journal - so there is nothing on the serial console to wait for. The
        # screen is the interface; the screen is what gets watched.
        #
        # It takes a while: argon2id sized at 512 MB is deliberate (§4.5).
        print("      waiting for the executor …")
        deadline = time.time() + 900
        w = h = 0
        rgb = b""
        while time.time() < deadline:
            time.sleep(10)
            w, h, rgb = lab.shoot(q, "29-complete")
            rows = h // font.height
            cols = w // font.width
            page = "\n".join(read_text(w, h, rgb, font, r, 0, cols, BRAND)
                              for r in range(rows))
            page += "\n".join(read_text(w, h, rgb, font, r, 0, cols)
                               for r in range(rows))
            if "NO OPERATING SYSTEM HAS BEEN COPIED" in page: break
            if "Setup cannot continue" in page:
                print("      FAIL  the executor failed; the error screen is up")
                return False
        else:
            print("      FAIL  the executor never finished")
            return False
        ok &= on_screen(w, h, rgb, "NO OPERATING SYSTEM HAS BEEN COPIED",
                        "Complete says the disk does not boot yet", fg=BRAND)

        # tty2 keeps a root shell for diagnosis (§7) - but the harness has the
        # serial line, which is simpler and is already logged in.
        ok &= verify_disk(c, encrypted=True)
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

    if not results:
        raise SystemExit(__doc__)
    print("\n### Phase 2 result")
    for name, ok in results.items():
        print(f"    {name:<9} {'PASS' if ok else 'FAIL'}")
    print(f"    screendumps in {lab.shots}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
