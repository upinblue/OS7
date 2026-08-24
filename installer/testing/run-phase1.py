#!/usr/bin/env python3
"""
Walking os7-setup in a VM — the Phase 1 deliverable, checked.

SETUP-PLAN §10 Phase 1 ends with "you can walk the whole flow in a VM and it
looks right". "Looks right" is not a result, so this walks it and measures:

    ./run-phase1.py live      does the LIVE entry leave the machine alone
    ./run-phase1.py boot      does the Install entry start Setup on tty1
    ./run-phase1.py walk      Welcome -> Licence -> Regional -> Complete
    ./run-phase1.py contrast  F5 switches to the high-contrast field
    ./run-phase1.py all       all three, in one boot     (default)
    ./run-phase1.py reset     discard the VM state

Every screen is verified by READING IT BACK THROUGH THE CONSOLE FONT — the PSF
the image actually ships, pulled out of the squashfs — rather than by looking at
the PNG. A cell is cut out of the screendump, matched against every glyph in the
font, and the one that matches exactly wins. So "the Welcome screen appeared" is
a statement about the characters on the screen, and a font that failed to load,
a screen that painted in the wrong place, or a frame that never arrived all fail
it. The PNGs are written too, for people.

Keys go in as QMP qcodes to a USB keyboard, so they travel HID -> the kernel
keymap -> the VT's XLATE translation and arrive at os7-setup as the bytes a
person's keypress would produce.

The serial line is used for two things only: logging in to ask systemd whether
the unit is running, and reading /var/log/os7-setup/setup.log at the end. That
log is independent evidence — it says what Setup THOUGHT happened, next to a
screendump of what it drew.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmscreen import (FB_W, REPO, Lab, assert_region, hexc, histogram,
                      load_font, read_text, run)

# The palette OS/7 ships, imported from the one table that generates it.
sys.path.insert(0, os.path.join(REPO, "build", "lib"))
import palette                                                  # noqa: E402

FIELD = palette.FIELD
BRAND = palette.BRAND
GREY = palette.GREY
CONTRAST = palette.CONTRAST

lab = Lab("phase1")
FONT = os.path.join(lab.dir, "os7-fixedsys-16x32.psf.gz")

# 16x32 at 1280x800 is exactly 80x25 — SETUP-PLAN §2.4's reference geometry,
# confirmed by spike S1. Every row/column below is in those cells.
CELL = (16, 32)

# The Install entry's command line, verbatim from build/lib/arm64-efi-remaster.sh
# plus a serial console so the harness can log in. If these ever disagree, the
# harness is testing something the ISO does not do.
CMDLINE = ("boot=casper os7.setup=1 systemd.wants=os7-setup.service "
           "fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 "
           "console=ttyAMA0,115200")


def fetch_font():
    """Take the PSF out of the ISO's squashfs — the one the image ships.

    Not the one build-console-font.sh makes on the host. They are identical by
    construction, and that is exactly why using the shipped one is worth the
    extra step: if they ever differ, the glyph comparison says so instead of
    agreeing with itself.
    """
    if os.path.exists(FONT):
        return
    os.makedirs(lab.dir, exist_ok=True)
    print("    taking the console font out of the ISO …")
    run("docker", "run", "--rm", "--privileged", "--platform", "linux/arm64",
        "-v", f"{os.path.dirname(lab.iso)}:/iso:ro", "-v", f"{lab.dir}:/out",
        "os7-build:arm64", "bash", "-c",
        f"set -e; mkdir -p /mnt/iso /mnt/sq; "
        f"mount -o loop,ro /iso/{os.path.basename(lab.iso)} /mnt/iso; "
        "mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq; "
        "cp /mnt/sq/usr/share/consolefonts/os7-fixedsys-16x32.psf.gz /out/; "
        "umount /mnt/sq; umount /mnt/iso", stdout=subprocess.DEVNULL)
    if not os.path.exists(FONT):
        raise SystemExit(f"the ISO has no {os.path.basename(FONT)}")


# ---------------------------------------------------------------------------
# Reading a screen
# ---------------------------------------------------------------------------
def line(w, h, rgb, font, row, col=0, length=80, fg=(255, 255, 255)):
    """Read a run of cells back as text, clamped to the screen.

    The clamp is not defensive tidiness: reading 80 characters from column 1 on
    an 80-column screen walks one cell past the right edge, and the pixel index
    for it is off the end of the buffer.
    """
    cols = w // font.width
    length = max(0, min(length, cols - col))
    return read_text(w, h, rgb, font, row, col, length, fg).rstrip()


def expect_line(w, h, rgb, font, row, needle, what, col=0, fg=(255, 255, 255)):
    """Assert a specific ROW, for the chrome — where the position IS the spec."""
    got = line(w, h, rgb, font, row, col, 80, fg)
    if needle in got:
        print(f"      ok    {what}")
        return True
    print(f"      FAIL  {what}")
    print(f"            wanted '{needle}'")
    print(f"            row {row} reads '{got}'")
    return False


def expect_text(w, h, rgb, font, needle, what, fg=(255, 255, 255)):
    """Assert the text is ON THE SCREEN, wherever the layout put it.

    Body content is asserted this way and chrome is not, and the difference is
    the contract. §2.4 pins the title row, the stripe and the status bar to the
    screen edges, so for those the row IS the claim. Everything else moves when a
    box grows or the geometry changes, and a harness that hard-codes those rows
    tests the harness.

    The foreground matters as much as the text: a selected row is black on grey
    and the brand-coloured lines are #1289ff, so reading them as white finds
    nothing and says "the text is missing" about text that is right there.
    """
    rows = h // font.height
    for row in range(rows):
        if needle in line(w, h, rgb, font, row, 0, 200, fg):
            print(f"      ok    {what}")
            return True
    print(f"      FAIL  {what}: '{needle}' is not on the screen in {hexc(fg)}")
    return False


def expect_chrome(w, h, rgb, font, title, status):
    """Title row, brand stripe and status bar — the three things every screen has."""
    ok = expect_line(w, h, rgb, font, 0, title, f"title row says '{title}'", col=1)
    # The stripe is row 1 of the cell grid, i.e. y = 32..63 with a 32px cell.
    band = histogram(w, h, rgb, box=(0, 40, w, 56))
    if band[0][0] != BRAND:
        print(f"      FAIL  title stripe is {hexc(band[0][0])}, expected {hexc(BRAND)}")
        ok = False
    else:
        print(f"      ok    title stripe is {hexc(BRAND)}")
    # The status bar is black on grey, so its text reads with a black foreground.
    ok &= expect_line(w, h, rgb, font, 24, status, f"status bar says '{status}'",
                      col=1, fg=(0, 0, 0))
    return ok


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
# The live entry's command line: the same medium, without os7.setup=1.
LIVE_CMDLINE = ("boot=casper fbcon=nodefer quiet splash console=ttyAMA0,115200")


def phase_live():
    """The other half of the contract: booting live must change nothing.

    A regression test for a bug that shipped. `os7-setup.service` carried
    `Conflicts=getty@tty1.service`, which is resolved when systemd BUILDS the
    transaction — before ConditionKernelCommandLine is evaluated when the job
    RUNS. So on a live boot the unit never started and getty@tty1 was stopped
    anyway: tty1 had no login prompt, and because nothing then wrote to that
    console, fbcon's deferred takeover never completed either.

    L14 is the reason this matters beyond tidiness: "booting straight into Setup
    loses try-before-you-install", and the mitigation is keeping both entries. An
    entry that boots to a dead console is not the live session it promises.

    Its own boot, because that is the only way to ask the question.
    """
    print("\n  live — the live entry must leave the machine alone")
    c, q = lab.boot(LIVE_CMDLINE, "live")
    ok = True
    try:
        c.drop()
        c.send("systemctl is-active os7-setup.service getty@tty1.service; "
               "sudo stty -F /dev/tty1 size")
        c.expect(r"\d+ \d+", 90, "unit states")
        text = c.text()

        # Setup must NOT be running: the condition was not met.
        if "\ninactive" in text or text.count("inactive") >= 1:
            print("      ok    os7-setup.service did not start")
        else:
            print("      FAIL  os7-setup.service started without os7.setup=1")
            ok = False

        if "active" in text.replace("inactive", ""):
            print("      ok    getty@tty1.service is running — tty1 has a login prompt")
        else:
            print("      FAIL  getty@tty1.service is not running; tty1 is dead")
            for l in text.splitlines():
                if l.strip() in ("active", "inactive", "failed"):
                    print(f"            {l.strip()}")
            ok = False

        # And the console is a real framebuffer console, not the dummy device.
        c.drop()
        c.send("sudo showconsolefont -i")
        c.expect(r"x\d+|ERROR", 60, "console font")
        if "ERROR" in c.text():
            print("      FAIL  tty1 is still the kernel's dummy device "
                  "(KDFONTOP is not implemented on it)")
            ok = False
        else:
            for l in c.text().splitlines():
                if "x" in l and l.strip().replace("x", "").isdigit():
                    print(f"      ok    tty1 is a framebuffer console ({l.strip()})")
                    break
        return ok
    finally:
        q.close()
        c.close()


def phase_boot(c, q, font):
    """Did the Install entry actually start Setup, and did Setup take the console?"""
    print("\n  boot — the unit, the palette and the first frame")
    ok = True

    c.drop()
    c.send("systemctl is-active os7-setup.service; systemctl show -p SubState os7-setup")
    c.expect(r"SubState=", 60, "unit state")
    text = c.text()
    if "SubState=running" in text:
        print("      ok    os7-setup.service is running")
    else:
        print("      FAIL  os7-setup.service is not running")
        for l in text.splitlines():
            if "SubState" in l or "active" in l:
                print(f"            {l.strip()}")
        ok = False

    time.sleep(2)
    w, h, rgb = lab.shoot(q, "01-welcome")

    if (w, h) != (FB_W, 800):
        print(f"      note  framebuffer is {w}x{h}, not {FB_W}x800")

    # The palette Setup applied itself. This is the whole of spike S1's finding
    # closing the loop: the kernel command line no longer carries a palette, so
    # a blue field here means os7-setup ran setvtrgb against the file the image
    # ships (BUILD-NOTES #25).
    hist = histogram(w, h, rgb)
    if hist[0][0] != FIELD:
        print(f"      FAIL  the field is {hexc(hist[0][0])}, expected {hexc(FIELD)} — "
              "Setup did not apply its palette")
        ok = False
    else:
        print(f"      ok    the field is {hexc(FIELD)} over "
              f"{100.0 * hist[0][1] / (w * h):.0f}% of the screen")

    # Is the console actually the 80x25 the 16x32 font gives on this
    # framebuffer? Checked BEFORE anything is read back, because every row and
    # column below is in 16x32 cells and a console in fbcon's own 8x16 font
    # would fail all of them as "the text is wrong" rather than as what it is.
    #
    # The status bar is the cheap tell: on an 80x25 grid it is the last cell row,
    # y = 768..799. On a 160x50 grid that band is field colour and the status bar
    # is somewhere else entirely.
    bar = histogram(w, h, rgb, box=(0, h - 24, w, h - 8))
    if bar[0][0] != GREY:
        cols = w // font.width
        print(f"      FAIL  the console is not {cols}x{h // font.height} cells of "
              f"{font.width}x{font.height} — the last row is {hexc(bar[0][0])}, "
              f"not the {hexc(GREY)} status bar. Setup did not get its font.")
        ok = False
    else:
        print(f"      ok    the grid is {w // font.width}x{h // font.height} cells "
              f"of {font.width}x{font.height}")

    ok &= expect_chrome(w, h, rgb, font, "OS/7 Setup",
                        "ENTER=Continue   R=Repair   F3=Quit")
    ok &= expect_text(w, h, rgb, font, "Welcome to Setup.", "screen 1 is Welcome")
    ok &= expect_text(w, h, rgb, font, "To set up OS/7 now, press ENTER.",
                      "the bullet list rendered")
    return ok


def phase_walk(c, q, font):
    """Welcome -> Licence -> Regional -> Complete, one key at a time."""
    print("\n  walk — the whole flow")
    ok = True

    # ---- screen 2, the licence -------------------------------------------
    q.send_key("ret")
    time.sleep(1.5)
    w, h, rgb = lab.shoot(q, "02-licence")
    ok &= expect_chrome(w, h, rgb, font, "OS/7 Setup",
                        "F8=I agree   ESC=I do not agree   PGDN=Next page")
    ok &= expect_text(w, h, rgb, font, "OS/7 Licence Agreement", "screen 2 is the licence")
    # The licence text is a file on the image, not compiled in. If it were
    # missing the screen would say so instead, which is a different string.
    ok &= expect_text(w, h, rgb, font, "MIT License", "the licence text is the shipped file")

    # PGDN is checked by what it DID, not by the page number it printed. The
    # indicator is a decoration; the licence text moving is the behaviour.
    before = line(w, h, rgb, font, 6, 0, 80)
    q.send_key("pgdn")
    time.sleep(1.0)
    w, h, rgb = lab.shoot(q, "03-licence-page2")
    after = line(w, h, rgb, font, 6, 0, 80)
    if before != after and after.strip():
        print("      ok    PGDN scrolled the licence text")
    else:
        print(f"      FAIL  PGDN did not scroll: row 6 still reads '{after}'")
        ok = False
    ok &= expect_text(w, h, rgb, font, "Page 2 of 2", "the page indicator counts the end",
                      fg=BRAND)

    # ---- screen 3, regional ----------------------------------------------
    q.send_key("f8")
    time.sleep(1.5)
    w, h, rgb = lab.shoot(q, "04-regional")
    ok &= expect_text(w, h, rgb, font, "regional settings", "screen 3 is Regional")
    # Black on grey: this row is the selection, so white finds nothing.
    ok &= expect_text(w, h, rgb, font, "Language:", "the settings box rendered", fg=(0, 0, 0))
    ok &= expect_text(w, h, rgb, font, "Time zone:", "every setting is listed")

    # The selected row is black on light grey and spans the full inner width —
    # checked as a REGION, because "grey is present somewhere" is not a
    # statement about which row is selected (BUILD-NOTES #30).
    ok &= assert_region(w, h, rgb, CELL, (6, 6, 74, 7), {GREY, (0, 0, 0)}, GREY,
                        "the Language row is the selection")

    # ---- the picker ------------------------------------------------------
    q.send_key("ret")
    time.sleep(1.5)
    w, h, rgb = lab.shoot(q, "05-language-picker")
    ok &= expect_text(w, h, rgb, font, "Select a language", "ENTER opened the picker")
    ok &= expect_chrome(w, h, rgb, font, "OS/7 Setup",
                        "ENTER=Choose   ESC=Cancel")

    # Type-to-find, then cancel: the value must NOT change, which is the part of
    # ESC that is easy to get wrong.
    q.send_key("g")
    time.sleep(0.8)
    q.send_key("esc")
    time.sleep(1.5)
    w, h, rgb = lab.shoot(q, "06-picker-cancelled")
    ok &= expect_text(w, h, rgb, font, "English", "ESC left the language alone", fg=(0, 0, 0))

    # ---- pick a timezone -------------------------------------------------
    q.send_key("down")
    q.send_key("down")
    time.sleep(0.8)
    q.send_key("ret")
    time.sleep(1.5)
    w, h, rgb = lab.shoot(q, "07-timezone-picker")
    ok &= expect_text(w, h, rgb, font, "Select a time zone", "the timezone picker opened")
    q.send_key("e")
    time.sleep(0.8)
    q.send_key("ret")
    time.sleep(1.5)
    w, h, rgb = lab.shoot(q, "08-timezone-chosen")

    # ---- accept ----------------------------------------------------------
    q.send_key("down")
    time.sleep(0.5)
    q.send_key("ret")
    time.sleep(2.0)
    w, h, rgb = lab.shoot(q, "09-complete")
    ok &= expect_text(w, h, rgb, font, "Setup has collected the settings",
                      "screen 12 is Complete")
    ok &= expect_text(w, h, rgb, font, "Europe/", "the chosen time zone is on the summary")
    # The sentence that stops someone concluding a machine was installed. Drawn
    # in the brand colour, so it is read in the brand colour.
    ok &= expect_text(w, h, rgb, font, "NOTHING HAS BEEN WRITTEN TO ANY DISK",
                      "Complete says nothing was written", fg=BRAND)

    # ---- the log, as independent evidence --------------------------------
    c.drop()
    c.send("sudo tail -n 20 /var/log/os7-setup/setup.log")
    c.expect(r"plan:", 60, "setup log")
    print("      what Setup logged:")
    for l in c.text().splitlines():
        s = l.strip()
        if any(k in s for k in ("intent:", "licence accepted", "Timezone =",
                                "Language =", "regional:", "plan:")):
            print(f"        {s[:110]}")
    if '"timezone"' not in c.text():
        print("      FAIL  the log has no plan in it")
        ok = False
    return ok


def phase_contrast(c, q, font):
    """F5 — the high-contrast field from D5."""
    print("\n  contrast — F5")
    q.send_key("f5")
    time.sleep(2.0)
    w, h, rgb = lab.shoot(q, "10-high-contrast")
    hist = histogram(w, h, rgb)
    if hist[0][0] != CONTRAST:
        print(f"      FAIL  the field is {hexc(hist[0][0])}, expected {hexc(CONTRAST)}")
        return False
    print(f"      ok    F5 switched the field to {hexc(CONTRAST)}")
    # And back, because a toggle that only goes one way is not a toggle.
    q.send_key("f5")
    time.sleep(2.0)
    w, h, rgb = lab.shoot(q, "11-back-to-default")
    hist = histogram(w, h, rgb)
    if hist[0][0] != FIELD:
        print(f"      FAIL  F5 did not switch back: {hexc(hist[0][0])}")
        return False
    print(f"      ok    F5 switched back to {hexc(FIELD)}")
    return True


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        lab.reset()
        return 0

    print("### os7-setup Phase 1 — walking the flow")
    lab.prepare()
    fetch_font()
    font = load_font(FONT)
    print(f"    console font: {font.width}x{font.height}, "
          f"{len(font.table)} codepoints")

    results = {}
    if what in ("all", "live"):
        results["live"] = phase_live()
    if what == "live":
        print("\n### Phase 1 result")
        print(f"    live      {'PASS' if results['live'] else 'FAIL'}")
        return 0 if results["live"] else 1

    c, q = lab.boot(CMDLINE, "phase1")
    try:
        if what in ("all", "boot"):
            results["boot"] = phase_boot(c, q, font)
        if what in ("all", "walk"):
            results["walk"] = phase_walk(c, q, font)
        if what in ("all", "contrast"):
            results["contrast"] = phase_contrast(c, q, font)
    finally:
        q.close()
        c.close()

    if not results:
        raise SystemExit(__doc__)
    print("\n### Phase 1 result")
    for name, ok in results.items():
        print(f"    {name:<9} {'PASS' if ok else 'FAIL'}")
    print(f"    screendumps in {lab.shots}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
