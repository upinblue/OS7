#!/usr/bin/env python3
"""Put the Setup and desktop pictures into the administrator manual — and prove
each one is the screen the manual says it is.

    python installer/testing/place-manual-shots.py --check      # read, place nothing
    python installer/testing/place-manual-shots.py setup
    python installer/testing/place-manual-shots.py desktop
    python installer/testing/place-manual-shots.py all

WHY THIS FILE EXISTS. The manual's console half has come from a machine since
`shoot-manual.py`, which writes a PICTURE AND A TRANSCRIPT from the same bytes.
Its Setup and desktop halves did not: `docs/manual/README.md` pointed at
`out/screenshots/`, which is **gitignored**, and the tools that filled it live
there too. So the provenance of 25 pictures was a README outside the repository,
and on 2026-09-21 `make-release-dir.py` refused them for being older than the
medium they claimed to describe — by then they were from **1.0.0.116**, which is
printed on the pictures themselves.

Reading them back said something worse than "stale". That route ran `os7-setup`
in a chroot with `lsblk` SHADOWED and `/sys/class/net` laid out by hand, so the
disks and the network adapters on screens 4, 5, 6 and 9 were a fixture: a
512 GB Samsung NVMe and an `iwlwifi` Wi-Fi card no OS/7 machine in this
repository has ever had. Its own README says so, honestly, in a table. A picture
of a real machine is worth more than a prettier picture of a plausible one.

WHAT IT DOES NOT DO: take pictures. `run-phase3.py walk` takes the Setup screens
— it walks the whole flow by keypress on a real VM and installs from the medium
— and `shoot-desktop.py` takes the desktop ones off a GUI bench. This file is
the MAPPING between what those produce and what the manual's chapters reference,
which is the part that was previously somebody's memory.

AND IT VERIFIES, because a mapping is exactly the kind of thing that rots
silently. Every Setup picture is read back through the console font it was drawn
with (`vmscreen.read_text`, the same glyph-exact match `run-phase3.py` asserts
with) and must contain a needle chosen from the screen's own text. `setup-06`
pointing at the account screen would be a picture of the wrong thing under a
right-looking name, and that is the failure this catches. The version on the
screen is checked against the medium's `release.json` as well: a picture of a
build cannot be placed under a claim about a different one.

Each placed picture also gets `docs/manual/transcripts/<name>.txt` — the screen
as text, from the same pixels. The console half has had that since the manual
was written; the Setup half now does too, so what is on a screen is greppable
without opening a PNG.
"""

import argparse
import collections
import importlib.util
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

from vmscreen import load_font, read_text                          # noqa: E402

IMAGES = os.path.join(REPO, "docs", "manual", "images")
TRANSCRIPTS = os.path.join(REPO, "docs", "manual", "transcripts")


def _module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------------------
# The mapping
# ---------------------------------------------------------------------------
# destination in docs/manual/images  <-  (source, a needle ON THAT SCREEN)
#
# THE NEEDLE IS THE EVIDENCE. Each was read off the screen it names with this
# file's own reader, never copied from a filename, and each is a phrase that
# appears on that screen and on no other in the flow. Two screens of the same
# kind that differ only by SELECTION (the mode screen, the layout screen before
# and after the passphrase) cannot be told apart by their text at all, so the
# needle is what they share and the source name is what distinguishes them —
# which is why those rows carry a comment saying what the difference is and how
# it was established.
SETUP = [
    # 1 — Welcome. The one screen that prints the full four-field version.
    ("setup-01-welcome.png", "40-welcome", "Welcome to Setup"),
    # F5's high-contrast field (D5). The TEXT is identical to the screen above;
    # what differs is the field colour, and `check_contrast` below is what
    # separates them — a needle never could.
    ("setup-01-welcome-high-contrast.png", "40b-welcome-high-contrast",
     "Welcome to Setup"),
    # 2 — the licence, first page. PGDN is offered, which the last page does not.
    ("setup-02-licence.png", "41-licence", "PGDN=Next page"),
    # 3 — Regional, the summary screen (the language LIST is a sub-screen of it
    # and the walk does not open it; see the note in `main`).
    ("setup-03-regional.png", "40c-regional", "regional settings"),
    # 4 — the disks.
    ("setup-04-disk.png", "42-disk", "install OS/7 on the disk"),
    # 5 — the layout, before a passphrase has been set.
    ("setup-05-layout.png", "43-layout", "storage settings"),
    # 5 — the passphrase prompt.
    ("setup-05-layout-passphrase.png", "44-passphrase",
     "passphrase for the encrypted disk"),
    # 5 — the layout again, with the passphrase set. Same text as
    # `setup-05-layout`; the walk's own ordering is what tells them apart, and
    # it asserts the prompt in between.
    ("setup-05-layout-ready.png", "44b-passphrase-set", "storage settings"),
    # 6 — the gate. F=Format appears nowhere else.
    ("setup-06-confirm.png", "45-confirm", "F=Format"),
    # 7 — the account form, empty and filled. Distinguished by the typed name,
    # which is a needle: HOSTNAME comes from run-phase3 so the two cannot swap.
    ("setup-07-account.png", "46-account", "a name for this computer"),
    ("setup-07-account-filled.png", "47-account-filled", None),   # see below
    # 8 — the mode screen, ONE ROW APART.
    #
    # This is the pair the old set got wrong: `setup-08-mode-desktop.png` and
    # `setup-08-mode-headless.png` were BYTE-IDENTICAL (md5
    # a81e9c57…), both showing Headless selected, and the manual captioned them
    # as two different states. The walk produces both, because it arrives on
    # Headless (InstallPlan.Mode's default) and presses UP to choose Desktop.
    # `check_selected` below is what holds them apart, on the pixels.
    ("setup-08-mode-headless.png", "47b-after-account",
     "Choose how this computer will be used"),
    ("setup-08-mode-desktop.png", "47c-mode-desktop",
     "Choose how this computer will be used"),
    # 9 — the network, AFTER F4. The old picture said "Not yet tested."; this one
    # carries a real DHCP lease taken on the live medium, which is what the
    # chapter's caption claims happens.
    ("setup-09-network.png", "48-network-tested", "The settings work."),
    # 10 — the executor, mid-flight. The old picture was at 0% / "Starting…"
    # because that route ran --dry-run and every step finished in ~0 s; its
    # README says a bar in mid-flight "needs a real install, which needs a VM".
    # This is that picture.
    ("setup-10-execute-1.png", "49-copying", "Do not turn off the computer"),
    # 12 — Complete. Prints the full version of the installed machine.
    ("setup-12-complete.png", "49-complete", "Setup has prepared this computer"),
]

# The needle for the filled account form is the computer name the walk types,
# which is the only thing that separates it from the empty one. Taken from
# run-phase3 rather than written here, so the two cannot drift apart.
SETUP_FILLED = "setup-07-account-filled.png"

# destination  <-  (source, what it must show)
#
# A DESKTOP SHOT CANNOT BE READ THROUGH A CONSOLE FONT, so the verification is a
# different and weaker one: the geometry, and that the capture is not mostly one
# colour. The failure mode being caught is real and has a name in this
# repository — #111, where the login screen came up EMPTY and every check was
# green — and the manual shipped it for three weeks. Measured 2026-09-22 on the
# set this replaces:
#
#     desktop-01b-desktop-no-overview.png   1920x1080    84 colours   94.7% black
#     desktop-01-desktop.png                1920x1080  2466 colours   94.6% black
#     console-version.png                   1280x800      3 colours   95.8% black
#
# The first of those is the picture chapter 13 captions "The OS/7 desktop in its
# classic appearance". It is a panel and a status bar on a void; the headless
# GNOME it came from drew no desktop at all, and its own README said "what is
# not the machine's own: nothing on the screen".
#
# SO THE THRESHOLD IS ON THE DOMINANT COLOUR AND NOT ON THE COUNT. 84 distinct
# colours sounds like a picture; 94.7% of one colour is the thing that was
# wrong. A rule tuned to what was actually broken, rather than to what sounded
# like it would be.
DOMINANT_MAX = 80.0
DESKTOP = [
    ("desktop-01-desktop.png", "01-desktop-menu"),
    ("desktop-02-terminal.png", "02-terminal-version"),
    ("desktop-03-files.png", "03-files"),
    ("desktop-04-edge.png", "04-edge"),
    ("desktop-05-intune.png", "05-intune"),
    ("app-software-update.png", "10-app-software-update"),
    ("app-versions-menu.png", "11-app-versions-menu"),
    ("app-versions.png", "12-app-versions"),
    ("app-versions-restore.png", "13-app-versions-restore"),
]


# ---------------------------------------------------------------------------
# Reading a saved picture back to text
# ---------------------------------------------------------------------------
def png_rgb(path):
    """A PNG's pixels, without a PNG library.

    `vmscreen.write_png` wrote these: one zlib stream of filter-0 scanlines, no
    interlacing, 8-bit truecolour. Decoding exactly that shape is a dozen lines
    and keeps this file's dependencies at "the standard library", which is what
    every other harness here manages.
    """
    import struct
    import zlib
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path}: not a PNG")
    i, w, h, idat = 8, None, None, bytearray()
    while i < len(data):
        (length,) = struct.unpack(">I", data[i:i + 4])
        kind = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + length]
        if kind == b"IHDR":
            w, h, depth, colour = struct.unpack(">IIBB", body[:10])
            if (depth, colour) != (8, 2):
                raise SystemExit(f"{path}: depth {depth} colour {colour}, "
                                 "expected 8-bit truecolour")
            if body[12] != 0:
                raise SystemExit(f"{path}: interlaced")
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
        i += 12 + length
    raw = zlib.decompress(bytes(idat))
    stride = w * 3
    out = bytearray()
    for y in range(h):
        p = y * (stride + 1)
        if raw[p] != 0:
            raise SystemExit(f"{path}: scanline {y} uses filter {raw[p]}")
        out += raw[p + 1:p + 1 + stride]
    return w, h, bytes(out)


def _bitmap_table(font):
    """Every glyph's bitmap -> its lowest codepoint.

    The lowest wins, which is `vmscreen.read_text`'s rule and BUILD-NOTES #46's
    lesson: eight bitmaps in this font belong to more than one codepoint, the
    hyphen among them, and a plain `-` decoded as U+00AD SOFT HYPHEN until the
    tie was broken this way.
    """
    out = {}
    for cp, glyph in font.table.items():
        key = tuple(tuple(r) for r in font.bitmap(glyph))
        if cp < out.get(key, 0x110000):
            out[key] = cp
    return out


def screen_text(w, h, rgb, font, table):
    """The whole screen as lines of text.

    `read_text` takes ONE foreground colour, which is right against a live
    screendump where the caller knows what it is asking about. A saved picture
    carries several pairs at once — the title row, the field, the grey status
    bar, a black-on-grey selected row — so the ink is derived per ROW instead:
    the commonest colour across the row's band is the background and everything
    else is ink. That is the same reasoning `run-phase3.phase_walk` applies by
    reading each screen in white AND in the brand blue, generalised so that no
    colour has to be named in advance.
    """
    cw, ch = font.width, font.height
    lines = []
    for r in range(h // ch):
        tally = collections.Counter()
        for y in range(r * ch, (r + 1) * ch):
            row = rgb[y * w * 3:(y + 1) * w * 3]
            for x in range(0, w, 2):
                tally[row[x * 3:x * 3 + 3]] += 1
        bg = tally.most_common(1)[0][0]
        line = []
        for c in range(w // cw):
            key = tuple(
                tuple(rgb[((r * ch + y) * w + c * cw + x) * 3:
                          ((r * ch + y) * w + c * cw + x) * 3 + 3] != bg
                      for x in range(cw))
                for y in range(ch))
            cp = table.get(key)
            line.append(chr(cp) if cp is not None
                        else ("�" if any(any(b) for b in key) else " "))
        lines.append("".join(line).rstrip())
    return lines


# ---------------------------------------------------------------------------
def tally(rgb, colour):
    """How many pixels are exactly this colour.

    Triple-aligned, unlike a `bytes.count`, because this is also used to compare
    two screens that differ only in a palette slot and a wrong answer there
    would be invisible.
    """
    needle = bytes(colour)
    return sum(1 for i in range(0, len(rgb), 3) if rgb[i:i + 3] == needle)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", nargs="?", default="all",
                    choices=("all", "setup", "desktop"))
    ap.add_argument("--check", action="store_true",
                    help="verify the sources and place nothing")
    ap.add_argument("--setup-shots",
                    default=os.path.join(REPO, ".vm", "phase3", "shots"),
                    help="where run-phase3.py walk left its screens")
    ap.add_argument("--desktop-shots",
                    default=os.path.join(REPO, ".vm", "gui", "shots"),
                    help="where shoot-desktop.py left its screens")
    a = ap.parse_args()

    phase3 = _module("run_phase3", os.path.join(HERE, "run-phase3.py"))
    palette = _module("palette", os.path.join(REPO, "build", "lib", "palette.py"))

    print("### the manual's Setup and desktop pictures")
    ok = True
    placed = 0

    if a.what in ("all", "setup"):
        ok_setup, n = do_setup(a, phase3, palette)
        ok &= ok_setup
        placed += n

    if a.what in ("all", "desktop"):
        ok_desktop, n = do_desktop(a)
        ok &= ok_desktop
        placed += n

    ok &= audit_references()

    print(f"\n### {'checked' if a.check else 'placed'} {placed} picture(s) — "
          f"{'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


def audit_references():
    """Every `images/…` a chapter names must exist, in BOTH languages.

    A placer that can leave a chapter pointing at nothing is half a tool: the
    PDF renders a broken image as a gap and says nothing, and the two languages
    are edited separately, so a picture added to one and not the other is the
    likely shape of the mistake. Unreferenced files are reported and are NOT a
    failure — `shoot-manual.py` takes a whole set and the chapters use a
    subset, deliberately.
    """
    import glob
    import re
    print("\n  references — every images/… a chapter names")
    used, missing = set(), []
    for chapter in sorted(glob.glob(os.path.join(REPO, "docs", "manual", "??", "*.md"))):
        body = open(chapter, encoding="utf-8").read()
        for m in re.finditer(r"\]\(images/([^)]+)\)", body):
            used.add(m.group(1))
            if not os.path.exists(os.path.join(IMAGES, m.group(1))):
                missing.append((os.path.relpath(chapter, REPO), m.group(1)))
    if missing:
        print(f"      FAIL  {len(missing)} reference(s) point at no file:")
        for where, name in sorted(set(missing)):
            print(f"            {where} -> {name}")
        return False

    on_disk = {os.path.basename(p) for p in glob.glob(os.path.join(IMAGES, "*"))}
    spare = sorted(on_disk - used)
    print(f"      ok    {len(used)} reference(s) resolve, {len(on_disk)} file(s) present")
    if spare:
        print(f"      note  {len(spare)} file(s) no chapter names: "
              + ", ".join(spare))
    return True


def do_setup(a, phase3, palette):
    """The Setup screens, verified through the console font."""
    print("\n  setup — read back through the font the screen was drawn with")

    if not os.path.isdir(a.setup_shots):
        print(f"      FAIL  no screens at {a.setup_shots}")
        print("            Take them first:  python installer/testing/"
              "run-phase3.py walk")
        return False, 0

    # The medium's own account of itself, so a picture cannot be placed under a
    # claim about a build it does not show.
    release = phase3.medium_release()
    version = release["version"]
    channel = release.get("channel", "")
    title = f"Version {'.'.join(version.split('.')[:3])}"
    if channel:
        title += f" ({channel})"
    print(f"      medium   {version}, channel {channel}")

    # The font off that same medium. run-phase3's own fetch, not a second copy
    # of the docker invocation that mounts an ISO's squashfs (BUILD-NOTES #66).
    phase3.fetch_font()
    font = load_font(phase3.FONT)
    table = _bitmap_table(font)

    ok, placed = True, 0
    for dest, source, needle in SETUP:
        src = os.path.join(a.setup_shots, source + ".png")
        if not os.path.exists(src):
            print(f"      FAIL  {dest}: no {source}.png in {a.setup_shots}")
            ok = False
            continue

        w, h, rgb = png_rgb(src)
        lines = screen_text(w, h, rgb, font, table)
        page = "\n".join(lines)

        if dest == SETUP_FILLED:
            needle = phase3.HOSTNAME

        problems = []
        if needle and needle not in page:
            problems.append(f"'{needle}' is not on that screen")

        # THE VERSION, on every screen that prints one. The title row carries
        # the three-field form on all of them; Welcome and Complete carry the
        # four-field one as well, and those two are where a picture of the wrong
        # build is most misleading, because they are the pictures a reader
        # checks a version against.
        if title not in page:
            problems.append(f"the title row does not say '{title}'")
        if dest in ("setup-01-welcome.png", "setup-01-welcome-high-contrast.png",
                    "setup-12-complete.png") and version not in page:
            problems.append(f"it does not name {version}")

        # F5: the SAME TEXT as the screen above it, a different field colour.
        # No needle can see this, and it is the thing the picture is for.
        if dest == "setup-01-welcome-high-contrast.png":
            if tally(rgb, palette.CONTRAST) < 1000:
                problems.append("the field is not the high-contrast colour")
            if tally(rgb, palette.FIELD):
                problems.append("the default field colour is still on it")
        if dest == "setup-01-welcome.png":
            if tally(rgb, palette.FIELD) < 1000:
                problems.append("the field is not the default colour")

        # The mode screen's two rows. SelectionList draws the selected row
        # black-on-grey across the full inner width, so which row is selected is
        # a question about WHERE the grey is, and is answered on the pixels.
        if dest in ("setup-08-mode-desktop.png", "setup-08-mode-headless.png"):
            want = "Desktop" if dest.endswith("desktop.png") else "Headless"
            got = selected_row(w, h, rgb, font, table, palette)
            if got is None:
                problems.append("no row is selected on it")
            elif not got.strip().startswith(want):
                problems.append(f"the selected row is '{got.strip()[:40]}', "
                                f"not {want}")

        if problems:
            ok = False
            print(f"      FAIL  {dest}  <- {source}.png")
            for p in problems:
                print(f"            {p}")
            continue

        print(f"      ok    {dest}  <- {source}.png")
        if not a.check:
            place(src, dest, lines)
            placed += 1

    return ok, placed


def selected_row(w, h, rgb, font, table, palette):
    """The text of the row drawn black-on-grey, or None.

    The status bar at the bottom is grey too and is not a selection, so the last
    row is skipped. Read in BLACK, which is the selected row's ink — the same
    third colour `run-phase3.phase_walk` had to reach for to find the NIC.
    """
    cw, ch = font.width, font.height
    grey = bytes(palette.GREY)
    for r in range(h // ch - 1):
        band = sum(1 for y in range(r * ch, (r + 1) * ch)
                   for x in range(0, w, 8)
                   if rgb[(y * w + x) * 3:(y * w + x) * 3 + 3] == grey)
        if band < 100:
            continue
        return read_text(w, h, rgb, font, r, 0, w // cw, (0, 0, 0)).rstrip()
    return None


def do_desktop(a):
    """The desktop screens. Geometry and "not blank", which is all the pixels
    of a GUI capture can be asked without a second implementation of the
    desktop."""
    print("\n  desktop — geometry, and that the capture is not blank")

    if not os.path.isdir(a.desktop_shots):
        print(f"      FAIL  no screens at {a.desktop_shots}")
        print("            Take them first:  python installer/testing/"
              "shoot-desktop.py")
        return False, 0

    provenance = os.path.join(a.desktop_shots, "provenance.txt")
    if not os.path.exists(provenance):
        print(f"      FAIL  {provenance} is missing — a desktop picture with no "
              "record of the machine it came from")
        return False, 0
    print("      " + open(provenance, encoding="utf-8").read().strip()
          .replace("\n", "\n      "))

    ok, placed, sizes = True, 0, {}
    for dest, source in DESKTOP:
        src = os.path.join(a.desktop_shots, source + ".png")
        if not os.path.exists(src):
            print(f"      FAIL  {dest}: no {source}.png")
            ok = False
            continue
        w, h, rgb = png_rgb(src)
        px = [rgb[i:i + 3] for i in range(0, len(rgb), 3)]
        top, count = collections.Counter(px).most_common(1)[0]
        share = count / len(px) * 100
        sizes.setdefault((w, h), []).append(dest)

        if w < 1024 or h < 768:
            print(f"      FAIL  {dest}: {w}x{h} is smaller than 1024x768")
            ok = False
            continue
        # #111's shape: a capture that failed looks like a capture that worked.
        if share > DOMINANT_MAX:
            print(f"      FAIL  {dest}: {share:.1f}% of it is one colour "
                  f"(#{top[0]:02x}{top[1]:02x}{top[2]:02x}) — that is a panel "
                  "on a void, not a desktop")
            ok = False
            continue
        print(f"      ok    {dest}  <- {source}.png  "
              f"({w}x{h}, dominant colour {share:.1f}%)")
        if not a.check:
            place(src, dest, None)
            placed += 1

    # ONE SIZE FOR THE WHOLE SET. The manual lays these out at a single width,
    # so a set at two geometries reads as two products - and mixing them is the
    # shape a half-refreshed set takes.
    if len(sizes) > 1:
        ok = False
        print("      FAIL  the set is not one geometry:")
        for (w, h), names in sorted(sizes.items()):
            print(f"            {w}x{h}: {', '.join(names)}")

    return ok, placed


def place(src, dest, lines):
    """Copy the picture, and its text beside it where there is text.

    copy2, so the MTIME comes from when the picture was TAKEN and not from when
    it was filed. `make-release-dir.py` refuses a picture older than the medium
    it would describe, and that rule is only worth anything if the timestamp
    still belongs to the machine.
    """
    os.makedirs(IMAGES, exist_ok=True)
    shutil.copy2(src, os.path.join(IMAGES, dest))
    if lines is None:
        return
    os.makedirs(TRANSCRIPTS, exist_ok=True)
    out = os.path.join(TRANSCRIPTS, os.path.splitext(dest)[0] + ".txt")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines).rstrip() + "\n")


if __name__ == "__main__":
    sys.exit(main())
