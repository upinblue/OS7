#!/usr/bin/env python3
"""
Host-side harness for spike S1 — does the look actually work.

SETUP-PLAN §10 S1 is done when "the field is exactly #0057ad, the stripe exactly
#1289ff, box glyphs render, and arrows and F-keys decode". Each of those is a
measurement, and each phase below takes exactly one of them:

    ./run-s1.py font       build the console font and assert its coverage
    ./run-s1.py build      publish the NativeAOT painter for arm64
    ./run-s1.py palette    boot with the palette on the kernel command line and
                           read the field colour back out of the framebuffer
    ./run-s1.py mockup     load the font, paint the §3.1 screens, screendump each
    ./run-s1.py keys       press arrows and F-keys; check what the decoder made
    ./run-s1.py all        all five, in order       (default)
    ./run-s1.py reset      throw the VM state away

S1 is the only Phase 0 spike that needs a FRAMEBUFFER — S3, S4 and S6 all run
with `-display none` and a serial console, because nothing they prove is visible.
Here the visible result IS the result, so:

  * `-device virtio-gpu-pci` gives a display without a window. Its default mode
    is 1280x800, which with a 16x32 font is exactly the 80x25 grid §2.4 names as
    the reference geometry — so the mockups are measured at the size they were
    drawn for rather than at whatever the firmware felt like.
  * screendumps come out over QMP. `-display none` does not mean "no surface":
    QEMU keeps the scanout in memory and dumps it on request.
  * keys go IN over QMP too, as qcodes to a USB keyboard, so they travel the
    whole real path — HID, the kernel keymap, the VT's XLATE translation — and
    arrive at the program as the bytes a person's keypress would produce. A test
    that wrote the escape sequences into a pipe would have proved nothing about
    the two layers that actually differ between a VT and a serial line.

The kernel and initrd are pulled out of the ISO and booted directly, rather than
through GRUB. That is only about control: `-append` lets each phase set its own
command line, where driving GRUB's editor over a serial console is the kind of
thing docs/HANDOFF.md §5 warns about. Everything measured here is a property of
the kernel and userspace, so the bootloader is not part of the question — S4
already answered the one question that was about it.
"""
import gzip
import os
import shutil
import sys
import time

# The VM harness library. vmconsole drives the serial line; vmscreen adds the
# framebuffer, QMP screendumps, key injection and reading the screen back
# through the console font. Both live in installer/testing/ because os7-setup's
# own verification shares them - the spikes only wrote them first.
sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "testing"))
from vmscreen import (REPO, Lab, assert_region, assert_uniform, histogram,   # noqa: E402
                      hexc, load_font, run, verify_glyphs)

SPIKES = os.path.join(REPO, "installer", "spikes")
BIN = os.path.join(REPO, "out", "s1", "arm64", "os7-s1")

lab = Lab("s1")
FONTS = os.path.join(lab.dir, "fonts")
SHOTS = lab.shots


# ---------------------------------------------------------------------------
# The palette — SETUP-PLAN §2.1 and decision D5.
#
# Imported from build/lib/palette.py rather than restated, because the image
# ships the same sixteen values and a spike that measures a second copy of them
# measures nothing. That file is also where the reasoning lives (why index 6,
# why the kernel form is kept but unused).
# ---------------------------------------------------------------------------
def _load(name):
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(REPO, "build", "lib", f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


palette = _load("palette")

FIELD = palette.FIELD
BRAND = palette.BRAND
GREY = palette.GREY
CONTRAST = palette.CONTRAST
OS7_PALETTE = palette.DEFAULT
OS7_CONTRAST = palette.HIGH_CONTRAST


def palette_cmdline(overrides):
    """The kernel-parameter form, plus vt.color.

    Both halves are measured dead on Ubuntu — the arrays are replaced by
    setvtrgb.service before anything is displayed, and vt.color has no effect on
    the default attribute at all. They stay on the command line here because
    phase_palette's first boot masks that service and shows what they do on
    their own, which is the only way to tell "the mechanism is broken" from
    "something else overwrote it".
    """
    return palette.cmdline(overrides) + " vt.color=0x4f"


def vtrgb_hex(overrides):
    return palette.vtrgb(overrides)


def base_cmdline(overrides=None):
    return " ".join([
        "boot=casper", "quiet", "loglevel=0", "plymouth.enable=0",
        "console=ttyAMA0,115200",
        # The closest built-in match until userspace can call setfont — L20. The
        # kernel cannot load a PSF from disk, so this covers the frames between
        # the firmware handing over and Setup starting.
        "fbcon=font:TER16x32",
        # And the framebuffer console from the start rather than deferred. By
        # default fbcon waits for something to write to the console before
        # taking it over, and a harness that only probes with ioctls is not
        # writing: tty1 stays the dummy device, KDFONTOP returns ENOSYS, and
        # nothing measured here would be about a framebuffer at all.
        "fbcon=nodefer",
    ] + ([palette_cmdline(overrides)] if overrides else []))


def build_payload():
    """Stage S1's payload: the fonts, the painter, the palettes and the runner."""
    stage = os.path.join(lab.dir, "payload")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(os.path.join(stage, "fonts"))

    # Decompressed onto the payload, and that is not tidiness.
    #
    # `hdiutil makehybrid -iso -joliet` writes ISO9660 names with AT MOST ONE
    # DOT: os7-fixedsys-16x32.psf.gz arrives in the guest as
    # os7-fixedsys-16x32psf.gz, and setfont then reports "Unable to find file"
    # about a path that is right in every listing on the host. The rest of the
    # name survives, so a single-dot name is enough to avoid it entirely.
    #
    # This is why `ready` prints the directory rather than just saying "mounted":
    # the mangled name is visible there and nowhere else.
    for size in ("8x16", "16x32"):
        src = os.path.join(FONTS, f"os7-fixedsys-{size}.psf.gz")
        if not os.path.exists(src):
            raise SystemExit(f"missing {src} — run: ./run-s1.py font")
        with gzip.open(src, "rb") as fin, \
                open(os.path.join(stage, "fonts", f"os7-fixedsys-{size}.psf"), "wb") as fout:
            shutil.copyfileobj(fin, fout)

    if not os.path.exists(BIN):
        raise SystemExit(f"missing {BIN} — run: ./run-s1.py build")
    shutil.copy(BIN, os.path.join(stage, "os7-s1"))

    with open(os.path.join(stage, "palette-default.vtrgb"), "w") as f:
        f.write(vtrgb_hex(OS7_PALETTE))
    with open(os.path.join(stage, "palette-contrast.vtrgb"), "w") as f:
        f.write(vtrgb_hex(OS7_CONTRAST))

    shutil.copy(os.path.join(SPIKES, "s1-look.sh"), stage)
    return stage


def prepare():
    lab.prepare(payload_dir=None)
    lab.build_payload(build_payload())


def boot(cmdline, label):
    """Boot the live session and return (console, qmp) at a plain bash prompt."""
    c, q = lab.boot(cmdline, label)
    lab.mount_payload(c)
    # The acknowledgement comes from a FILE ON THE VOLUME, so it cannot be the
    # shell echoing the command back. BUILD-NOTES #16: an earlier version used
    # `&& echo MOUNT-OK` and reported success for a mount that had failed with
    # "must be superuser".
    c.drop()
    c.send("sh /mnt/s1-look.sh ready")
    c.expect(r"S1-READY", 60, "payload mounted and readable")

    # Nothing may touch tty1 before fbcon owns it. See `waitfb` for why, and
    # docs/BUILD-NOTES.md #31 for what it looks like when this is skipped.
    c.drop()
    c.send("sudo sh /mnt/s1-look.sh waitfb")
    c.expect(r"S1-FB-OK", 180, "fbcon takeover")
    return c, q


def shoot(q, name):
    return lab.shoot(q, name)


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
def phase_font():
    """Build the PSFs and assert their coverage. No VM: this is a file question."""
    print("\n### font — Fixedsys Excelsior -> PSF, and the L19 coverage guard")
    os.makedirs(FONTS, exist_ok=True)
    run("docker", "run", "--rm", "--platform", "linux/arm64",
        "-v", f"{REPO}:/work", "-v", f"{FONTS}:/fonts",
        "os7-build:arm64", "bash", "/work/build/lib/build-console-font.sh", "/fonts")
    print("    font built and verified")


def phase_build():
    """Publish the NativeAOT painter. Same shape as run-s2.sh: compile in the
    architecture-matched container, never cross."""
    print("\n### build — NativeAOT publish of the S1 painter")
    out = os.path.dirname(BIN)
    os.makedirs(out, exist_ok=True)
    run("docker", "run", "--rm", "--platform", "linux/arm64",
        "-v", f"{REPO}:/work", "os7-build:arm64", "bash", "-euo", "pipefail", "-c",
        "cd /work/installer/spikes/s1-look && "
        "export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 && "
        "dotnet publish -c Release -r linux-arm64 -p:PublishAot=true "
        "  -o /work/out/s1/arm64 2>&1 | tail -20")
    if not os.path.exists(BIN):
        raise SystemExit(f"publish produced no {BIN}")
    size = os.path.getsize(BIN)
    print(f"    {BIN}  ({size / 1024 / 1024:.1f} MB)")


def phase_palette():
    """Is the field exactly #0057ad and the stripe exactly #1289ff.

    Two boots, because one produced a confidently wrong answer. SETUP-PLAN §2.1
    offers two mechanisms — kernel parameters "from the first kernel frame", and
    setvtrgb "at runtime" — and reads as though the first is primary. On Ubuntu
    it is not, and nothing about that is visible from a single boot:
    `setvtrgb.service` ships ENABLED, runs at sysinit, and replaces the whole
    palette with /etc/vtrgb before fbcon has even taken the console over.

        boot 1, setvtrgb.service masked   does the kernel mechanism work at all
        boot 2, stock                     what a real machine actually shows

    Measuring only the second concludes "the kernel parameters do not work".
    Measuring only the first ships an installer that comes up in Ubuntu's colours
    on every machine.

    Colours are read back through EXPLICIT background fills, one palette index at
    a time, and never through a plain `clear`. Two reasons, both found the hard
    way here: `vt.color` turns out not to set the default attribute at all (see
    below), and a cleared screen therefore measures something other than the
    slot under test.
    """
    print("\n### palette — is the field exactly #0057ad")
    prepare()
    ok = True

    # ---- boot 1: the palette itself, with nothing competing -------------------
    print("\n  [1/2] the kernel command line, setvtrgb.service masked")
    c, q = boot(base_cmdline(OS7_PALETTE) + " systemd.mask=setvtrgb.service", "palette-cmdline")
    try:
        c.send("sudo sh /mnt/s1-look.sh free")
        c.expect(r"S1-FREE-OK", 60, "tty1 free")

        for idx, want, what in ((4, FIELD, "field"), (6, BRAND, "stripe / bar fill"),
                                (7, GREY, "status bar"), (0, (0, 0, 0), "text on grey")):
            c.drop()
            c.send(f"sudo sh /mnt/s1-look.sh fillbg {idx}")
            c.expect(r"S1-FILLBG-OK", 60, f"fill index {idx}")
            time.sleep(1.5)
            w, h, rgb = shoot(q, f"01-slot{idx}")
            ok &= assert_uniform(histogram(w, h, rgb), w * h, want,
                                 f"palette index {idx} ({what})")

        # setvtrgb — the runtime path, which is what F5 would use.
        #
        # AND THE REPAINT, which is not optional: the framebuffer is truecolor,
        # so every cell was already resolved to RGB when it was drawn. Changing
        # the palette changes what LATER writes resolve to and leaves the pixels
        # already on screen exactly as they are. Measured here: after switching to
        # the high-contrast palette the screen stayed #0057ad until it was
        # repainted, then became #003366. F5 must redraw, not just re-map.
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh palette /mnt/palette-contrast.vtrgb")
        c.expect(r"S1-PALETTE-OK", 60, "setvtrgb contrast")
        time.sleep(1.5)
        w, h, rgb = shoot(q, "02-contrast-before-repaint")
        stale = histogram(w, h, rgb)[0][0]
        print(f"      note  before repainting, the screen is still {hexc(stale)} — "
              "a palette change does not retint pixels already drawn")

        c.drop()
        c.send("sudo sh /mnt/s1-look.sh fillbg 4")
        c.expect(r"S1-FILLBG-OK", 60, "repaint")
        time.sleep(1.5)
        w, h, rgb = shoot(q, "03-contrast-after-repaint")
        ok &= assert_uniform(histogram(w, h, rgb), w * h, CONTRAST,
                             "setvtrgb + repaint (the F5 high-contrast field)")

        # vt.color is in §7's proposed command line. It does nothing here, and
        # the harness says so with numbers rather than leaving it assumed.
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh palette /mnt/palette-default.vtrgb")
        c.expect(r"S1-PALETTE-OK", 60, "restore palette")
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh vtcolor")
        c.expect(r"S1-VTCOLOR-OK", 60, "vt.color")
        for line in c.text().splitlines():
            if line.strip().startswith("vt.color"):
                print(f"      {line.strip()}")
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh fillbg 2")
        c.expect(r"S1-FILLBG-OK", 60, "fill green")
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh defclear")
        c.expect(r"S1-DEFCLEAR-OK", 60, "default-attribute erase")
        time.sleep(1.5)
        w, h, rgb = shoot(q, "04-default-attribute")
        got = histogram(w, h, rgb)[0][0]
        if got == FIELD:
            print(f"      ok    vt.color=0x4f gives a {hexc(FIELD)} default attribute")
        else:
            print(f"      finding  vt.color=0x4f does NOT set the default attribute: "
                  f"erasing with it gives {hexc(got)}, not {hexc(FIELD)}. "
                  "Setup must paint every cell explicitly, which it does.")
    finally:
        q.close()
        c.close()

    # ---- boot 2: what stock Ubuntu userspace does to it -----------------------
    print("\n  [2/2] the same command line, stock userspace")
    c, q = boot(base_cmdline(OS7_PALETTE), "palette-stock")
    try:
        c.send("sudo sh /mnt/s1-look.sh free")
        c.expect(r"S1-FREE-OK", 60, "tty1 free")
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh fillbg 4")
        c.expect(r"S1-FILLBG-OK", 60, "fill index 4")
        time.sleep(1.5)
        w, h, rgb = shoot(q, "05-stock-userspace")
        got = histogram(w, h, rgb)[0][0]
        if got == FIELD:
            print(f"      note  the command line survived userspace after all — "
                  "setvtrgb.service must have stopped shipping enabled")
        else:
            print(f"      finding  index 4 renders as {hexc(got)}, not {hexc(FIELD)}: "
                  "userspace replaced the palette after boot")

        # Name the culprit rather than infer it: what the kernel was told, what
        # the console is using now, and what is on disk to explain the gap.
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh whopalette")
        c.expect(r"S1-WHO-OK", 60, "palette provenance")
        for line in c.text().splitlines():
            t = line.strip()
            if t.startswith(("cmdline-red=", "live-red=", "vtrgb=", "service=")):
                print(f"      {t}")

        # And the remedy, measured: the file OS/7 would ship as /etc/vtrgb,
        # applied through the service's own mechanism.
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh palette /mnt/palette-default.vtrgb")
        c.expect(r"S1-PALETTE-OK", 60, "apply the OS/7 palette")
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh fillbg 4")
        c.expect(r"S1-FILLBG-OK", 60, "repaint")
        time.sleep(1.5)
        w, h, rgb = shoot(q, "06-stock-plus-vtrgb")
        ok &= assert_uniform(histogram(w, h, rgb), w * h, FIELD,
                             "OS/7's palette applied the way /etc/vtrgb would")
        return ok
    finally:
        q.close()
        c.close()



def phase_mockup():
    """The §3.1 screens, at the geometry they were drawn for."""
    print("\n### mockup — the font, the glyphs and the screens")
    prepare()
    c, q = boot(base_cmdline(OS7_PALETTE), "mockup")
    ok = True
    try:
        c.send("sudo sh /mnt/s1-look.sh free")
        c.expect(r"S1-FREE-OK", 60, "tty1 free")

        # Ubuntu's own palette is live by now — the palette phase established
        # that setvtrgb.service replaces the command line's before fbcon even
        # starts. Apply OS/7's the way shipping /etc/vtrgb would, so the mockups
        # are measured in the colours they are meant to have.
        c.send("sudo sh /mnt/s1-look.sh palette /mnt/palette-default.vtrgb")
        c.expect(r"S1-PALETTE-OK", 60, "OS/7 palette")

        c.send("sudo sh /mnt/s1-look.sh font 16x32")
        c.expect(r"S1-FONT-OK", 60, "setfont")

        c.send("sudo sh /mnt/s1-look.sh probe")
        c.expect(r"S1-PROBE-OK", 60, "probe")
        for line in c.text().splitlines():
            if line.startswith("S1-PROBE-"):
                print(f"      {line.strip()}")
        if "S1-PROBE-GEOMETRY=80x25" not in c.text():
            print("      note  geometry is not 80x25; the layout rule (§2.4) covers it,"
                  " but the mockups were drawn at 80x25")
        if "KEYTABLE=AMBIGUOUS" in c.text():
            print("      FAIL  the key table has a prefix conflict")
            ok = False

        for screen in ("testcard", "welcome", "disk", "layout", "copying"):
            c.drop()
            c.send(f"sudo sh /mnt/s1-look.sh paint {screen}")
            c.expect(r"S1-PAINT-OK", 60, f"paint {screen}")
            time.sleep(1.5)
            w, h, rgb = shoot(q, f"1{'0' if screen == 'testcard' else ''}-{screen}")

            hist = histogram(w, h, rgb)
            present = {colour for colour, _ in hist}
            for name, want in (("field", FIELD), ("stripe", BRAND), ("grey", GREY)):
                if want not in present:
                    print(f"      FAIL  {screen}: no pixel is {hexc(want)} ({name})")
                    ok = False

            # The stripe is row 1 of the character grid — with a 32-pixel-tall
            # cell that is y = 32..63. Checking the band rather than the whole
            # frame is what makes this an assertion about the LAYOUT and not just
            # about the colour existing somewhere.
            band = histogram(w, h, rgb, box=(0, 40, w, 56))
            if band[0][0] != BRAND:
                print(f"      FAIL  {screen}: the title stripe band is "
                      f"{hexc(band[0][0])}, expected {hexc(BRAND)}")
                ok = False
            elif screen == "testcard":
                print(f"      ok    title stripe band is {hexc(BRAND)} "
                      f"across {100.0 * band[0][1] / (w * 16):.0f}% of its rows")

            # The progress bar fill is the ONLY place the brand blue is a
            # foreground rather than a background, and that difference is
            # exactly where it went wrong: the fill came out #55ffff (entry 14)
            # because the Linux console's bright-foreground sequences leave bold
            # set and the next colour inherits it. Checked as its own region
            # because "is #1289ff somewhere in the frame" was true the whole
            # time - the title stripe was providing it.
            if screen == "copying":
                ok &= assert_region(w, h, rgb, (16, 32), (12, 10, 34, 11),
                                    {BRAND, FIELD}, BRAND, "progress bar fill")

        # kbd's own screendump reads the VT's CHARACTER CELLS out of /dev/vcs -
        # a different path from QEMU's framebuffer grab all the way down. It only
        # settles the ASCII: /dev/vcs returns one byte per cell in the console's
        # own mapping, so anything above U+00FF comes back as a placeholder and
        # the box glyphs are unreadable there by construction. Worth running for
        # the layout, not worth believing about the glyphs.
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh paint testcard")
        c.expect(r"S1-PAINT-OK", 60, "repaint testcard")
        c.drop()
        c.send("sudo sh /mnt/s1-look.sh text 4,6")
        c.expect(r"S1-TEXT-OK", 60, "vcs text dump")
        print("      VT cells via /dev/vcs (ASCII only - see the comment):")
        for line in c.text().splitlines():
            t = line.strip()
            if t.startswith(("Box Drawing", "Block Elements", "German")):
                print(f"        {t}")

        # The glyphs themselves, settled against the font rather than by eye.
        time.sleep(1.0)
        w, h, rgb = shoot(q, "11-testcard-verified")
        font = load_font(os.path.join(FONTS, "os7-fixedsys-16x32.psf.gz"))
        for row, col, text, label in TESTCARD_ROWS:
            wrong, missing = verify_glyphs(w, h, rgb, font, row, col, text)
            if missing:
                print(f"      FAIL  {label}: not in the font: {' '.join(missing)}")
                ok = False
            if wrong:
                print(f"      FAIL  {label}: {len(wrong)}/{len(text)} cells do not match "
                      f"the font: {' '.join(r for _, r in wrong[:8])}")
                ok = False
            if not wrong and not missing:
                print(f"      ok    {label}: all {len(text)} cells match the font "
                      "pixel for pixel")
        return ok
    finally:
        q.close()
        c.close()


# Rows of the test card to read back, as (screen row, screen column, text).
# They have to agree with Screens.TestCard - the point is to compare the SCREEN
# with the FONT, so the expected text is stated once, here, and the screen is
# asked whether it holds it.
TESTCARD_ROWS = [
    (3, 2, "Box Drawing    \u250c\u2500\u252c\u2500\u2510 \u251c\u253c\u2524 "
           "\u2514\u2534\u2518 \u2502   \u2554\u2550\u2566\u2550\u2557 "
           "\u2560\u256c\u2563 \u255a\u2569\u255d \u2551", "box drawing"),
    (4, 2, "Block Elements \u2588\u2593\u2592\u2591 \u2580\u2584 \u258c\u2590",
           "block elements"),
    (5, 2, "German         \u00c4\u00d6\u00dc \u00e4\u00f6\u00fc \u00df   "
           "Bullet \u2022   Dash \u2014   Euro \u20ac", "German and UI marks"),
]


# QEMU qcode -> what the decoder must call it. The Linux console's F1-F5 are the
# interesting rows: they arrive as ESC[[A..ESC[[E, a form no other terminal uses,
# and .NET's terminfo layer is what §6.4 says gets them wrong.
KEY_PLAN = [
    ("up", "Up"), ("down", "Down"), ("left", "Left"), ("right", "Right"),
    ("f1", "F1"), ("f2", "F2"), ("f3", "F3"), ("f5", "F5"),
    ("f8", "F8"), ("f10", "F10"),
    ("pgup", "PageUp"), ("pgdn", "PageDown"),
    ("home", "Home"), ("end", "End"),
    ("ret", "Enter"), ("tab", "Tab"),
]


def phase_keys():
    print("\n### keys — do arrows and F-keys decode on a real VT")
    prepare()
    c, q = boot(base_cmdline(OS7_PALETTE), "keys")
    try:
        c.send("sudo sh /mnt/s1-look.sh free")
        c.expect(r"S1-FREE-OK", 60, "tty1 free")
        c.send("sudo sh /mnt/s1-look.sh font 16x32")
        c.expect(r"S1-FONT-OK", 60, "setfont")
        c.send("sudo sh /mnt/s1-look.sh paint testcard")
        c.expect(r"S1-PAINT-OK", 60, "paint")
        c.drop()

        # The reader runs in the foreground and reports each key on stderr, i.e.
        # on this serial line, as it arrives. So the harness presses a key and
        # then waits for that key's own line - no sleeping, no guessing, and a
        # key that never arrives fails on the key it was rather than as a count.
        c.send(f"sudo sh /mnt/s1-look.sh keys {len(KEY_PLAN)}")
        c.expect(r"S1-KEYS-DRAINED=", 60, "key reader ready")
        for line in c.text().splitlines():
            if "S1-KEYS-DRAINED=" in line and "DRAINED=0" not in line:
                print(f"      note  {line.strip()} — input was queued before the screen was up")

        for i, (qcode, _) in enumerate(KEY_PLAN):
            q.send_key(qcode)
            c.expect(rf"S1-KEY {i}:", 30, f"key {qcode}")
        c.expect(r"S1-KEYS-DONE", 60, "key reader finished")

        got = []
        for line in c.text().splitlines():
            s = line.strip()
            if s.startswith("S1-KEY "):
                print(f"      {s}")
                got.append(s)

        ok = True
        for i, (qcode, expected) in enumerate(KEY_PLAN):
            match = [g for g in got if g.startswith(f"S1-KEY {i}:")]
            if not match:
                print(f"      FAIL  {qcode}: nothing decoded")
                ok = False
            elif not match[0].rstrip().endswith(expected):
                print(f"      FAIL  {qcode}: expected {expected}, got {match[0]}")
                ok = False
        if ok:
            print(f"      ok    all {len(KEY_PLAN)} keys decoded as intended")
        return ok
    finally:
        q.close()
        c.close()


def phase_reset():
    lab.reset()
    return True


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    phases = {
        "font": phase_font, "build": phase_build, "palette": phase_palette,
        "mockup": phase_mockup, "keys": phase_keys, "reset": phase_reset,
    }
    if what == "all":
        phase_font()
        phase_build()
        results = {n: phases[n]() for n in ("palette", "mockup", "keys")}
        print("\n### S1 result")
        for name, ok in results.items():
            print(f"    {name:<8} {'PASS' if ok else 'FAIL'}")
        print(f"    screendumps in {SHOTS}")
        raise SystemExit(0 if all(results.values()) else 1)
    if what not in phases:
        raise SystemExit(__doc__)
    result = phases[what]()
    raise SystemExit(0 if result is not False else 1)


if __name__ == "__main__":
    main()
