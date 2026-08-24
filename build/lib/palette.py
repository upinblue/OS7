#!/usr/bin/env python3
"""
The OS/7 console palette — SETUP-PLAN §2.1 and decision D5.

    palette.py write <dir>     emit palette-default.vtrgb and palette-contrast.vtrgb
    palette.py verify          recompute the contrast ratios D5 was decided on
    palette.py show            print both palettes as a table

One source of truth for a decision that otherwise ends up spelled out in four
places: the file the image ships, the file the spike harness applies, the
kernel command line, and prose. Spike S1 measured every value below off a real
framebuffer, so they are not proposals.

No dependencies. It runs in the build container and on the host, and
installer/spikes/run-s1.py imports it rather than keeping a second copy.
"""
import sys


# ---------------------------------------------------------------------------
# The Linux console's own 16 entries, and OS/7's three changes to them.
#
# Slots 1, 2, 3 and 5 keep their defaults deliberately: kernel messages still
# have to look like kernel messages, and red still has to mean error.
#
# Index 6 is nominally "cyan" and is repurposed for the brand blue. The choice
# is forced rather than aesthetic — the console renders only EIGHT background
# colours (0-7), and both OS/7 blues are used as backgrounds, so both need a low
# slot. Index 6 is the least load-bearing one in kernel output.
# ---------------------------------------------------------------------------
DEFAULT_RED = [0x00, 0xAA, 0x00, 0xAA, 0x00, 0xAA, 0x00, 0xAA,
               0x55, 0xFF, 0x55, 0xFF, 0x55, 0xFF, 0x55, 0xFF]
DEFAULT_GRN = [0x00, 0x00, 0xAA, 0x55, 0x00, 0x00, 0xAA, 0xAA,
               0x55, 0x55, 0xFF, 0xFF, 0x55, 0x55, 0xFF, 0xFF]
DEFAULT_BLU = [0x00, 0x00, 0x00, 0x00, 0xAA, 0xAA, 0xAA, 0xAA,
               0x55, 0x55, 0x55, 0x55, 0xFF, 0xFF, 0xFF, 0xFF]

FIELD    = (0x00, 0x57, 0xAD)   # #0057ad  the field. #1289ff darkened 20 points
BRAND    = (0x12, 0x89, 0xFF)   # #1289ff  up in blue. Title stripe, progress fill
GREY     = (0xC0, 0xC0, 0xC0)   # #c0c0c0  status bar, selection bar
BLACK    = (0x00, 0x00, 0x00)   # #000000  text on both of those
CONTRAST = (0x00, 0x33, 0x66)   # #003366  the F5 high-contrast field

FIELD_SLOT, BRAND_SLOT, GREY_SLOT, BLACK_SLOT = 4, 6, 7, 0

DEFAULT  = {FIELD_SLOT: FIELD,    BRAND_SLOT: BRAND, GREY_SLOT: GREY}
HIGH_CONTRAST = {FIELD_SLOT: CONTRAST, BRAND_SLOT: BRAND, GREY_SLOT: GREY}

# White text has to clear WCAG AAA (7:1) on anything it is read from at length.
# The status bar carries BLACK text, so it is checked the other way round.
CONTRAST_FLOOR = {
    "field":          (FIELD,    (255, 255, 255), 7.0),
    "high contrast":  (CONTRAST, (255, 255, 255), 7.0),
    "status bar":     (GREY,     (0, 0, 0),       7.0),
}


def arrays(overrides):
    red, grn, blu = list(DEFAULT_RED), list(DEFAULT_GRN), list(DEFAULT_BLU)
    for idx, (r, g, b) in overrides.items():
        red[idx], grn[idx], blu[idx] = r, g, b
    return red, grn, blu


def vtrgb(overrides):
    """setvtrgb(8)'s hex form: 16 lines of #RRGGBB.

    The decimal form - three lines of sixteen comma-separated values - is what
    /etc/vtrgb ships as, and it is unreadable in a diff. setvtrgb takes either
    and detects which at run time, so OS/7 uses the one a person can check.
    """
    red, grn, blu = arrays(overrides)
    return "".join(f"#{red[i]:02X}{grn[i]:02X}{blu[i]:02X}\n" for i in range(16))


def cmdline(overrides):
    """The kernel-parameter form.

    KEPT FOR REFERENCE AND NOT USED. Spike S1 measured it as dead on Ubuntu:
    setvtrgb.service replaces the whole palette from /etc/vtrgb at ~11.8 s and
    fbcon takes the console over at ~14.0 s, so nothing is ever displayed in
    it - and no error is reported anywhere. docs/BUILD-NOTES.md #25.

    To see what it does on its own, boot with systemd.mask=setvtrgb.service.
    """
    red, grn, blu = arrays(overrides)
    j = lambda xs: ",".join(str(x) for x in xs)
    return (f"vt.default_red={j(red)} vt.default_grn={j(grn)} "
            f"vt.default_blu={j(blu)}")


# ---------------------------------------------------------------------------
# Contrast, computed rather than remembered (§2.2)
# ---------------------------------------------------------------------------
def luminance(c):
    out = []
    for v in c:
        s = v / 255
        out.append(s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def ratio(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def hexc(c):
    return "#%02x%02x%02x" % c


def verify():
    """D5 is a contrast decision. Check it against the numbers, every build."""
    ok = True
    for name, (bg, fg, floor) in CONTRAST_FLOOR.items():
        r = ratio(bg, fg)
        mark = "ok  " if r >= floor else "FAIL"
        if r < floor:
            ok = False
        print(f"    {mark} {name}: {hexc(fg)} on {hexc(bg)} = {r:.2f}:1 "
              f"(floor {floor}:1)")
    # The brand blue is deliberately NOT a text background - 3.47:1 - which is
    # the whole reason D5 darkened the field. Stated here so that "why not just
    # use #1289ff" has an answer in the build output.
    print(f"    note white on {hexc(BRAND)} is {ratio(BRAND, (255,255,255)):.2f}:1 — "
          "why the brand blue is a stripe and a bar fill, never a text field")
    return ok


def write(directory):
    import os
    os.makedirs(directory, exist_ok=True)
    for name, table in (("palette-default.vtrgb", DEFAULT),
                        ("palette-contrast.vtrgb", HIGH_CONTRAST)):
        path = os.path.join(directory, name)
        with open(path, "w") as f:
            f.write(vtrgb(table))
        print(f"    {path}")


def show():
    for name, table in (("default", DEFAULT), ("high contrast", HIGH_CONTRAST)):
        red, grn, blu = arrays(table)
        changed = set(table)
        print(f"  {name}")
        for i in range(16):
            c = (red[i], grn[i], blu[i])
            print(f"    {i:>2}  {hexc(c)}  {'<- OS/7' if i in changed else ''}")


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    if argv[1] == "write":
        write(argv[2])
    elif argv[1] == "verify":
        raise SystemExit(0 if verify() else 1)
    elif argv[1] == "show":
        show()
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
