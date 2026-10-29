#!/usr/bin/env python3
"""
The OS/7 brand — docs/BRAND-PLAN.md BR1–BR8, as code.

    brand.py write      regenerate brand/'s derived files from the master
    brand.py verify     the derived files are what the master makes, byte for byte
    brand.py show       the tokens, and the contrast numbers BR4 was decided on

ONE SOURCE. brand/os7-wordmark.svg is the mark (BR1). This module reads it,
validates that it still has the four shapes it is supposed to have, and derives
everything else from them: the white variant for the Setup field, the tile for
icon sizes, and - in a later stage - the sprites the boot splash is drawn from.
Nothing derived is ever edited by hand; `write` regenerates it and
installer/testing/check-brand.py requires the result byte for byte (BR6).

It sits beside palette.py and imports it, because the one colour the brand
shares with the product's screens - the Setup field - must not be spelled a
second time. palette.py's FIELD is the field; this file does not know the
number.

No dependencies beyond the standard library, for the same reason palette.py
has none: it runs in the build container and on either host.
"""
import os
import re
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import palette  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
BRAND_DIR = os.path.join(REPO, "brand")

MASTER_NAME = "os7-wordmark.svg"
WHITE_NAME = "os7-wordmark-white.svg"
TILE_NAME = "os7-tile.svg"

# ---------------------------------------------------------------------------
# The tokens (BR4). Two inks, and the two grounds they were decided against.
# ---------------------------------------------------------------------------
ORANGE = "#ff6912"                  # up in blue's orange - DECISIONS.md "Branding"
INK = "#ffffff"                     # the mark on the Setup field
DARK = "#0a0d12"                    # the website's page colour, the orange's home ground
FIELD = palette.hexc(palette.FIELD)  # #0057ad, from the one place it lives

TOKENS = {"orange": ORANGE, "ink": INK, "dark": DARK, "field": FIELD}

# (name, ground, ink, floor, must_pass). The third row is REQUIRED TO FAIL: it
# is the measurement that made the white variant necessary, and if the field
# ever changed so that orange cleared 4.5:1 on it, the rule would need
# re-deciding and the check should say so rather than quietly pass.
CONTRAST_RULES = [
    ("orange on the dark ground", DARK, ORANGE, 4.5, True),
    ("white on the Setup field", FIELD, INK, 7.0, True),
    ("orange on the Setup field", FIELD, ORANGE, 4.5, False),
]

# The tile (BR5): the website's favicon geometry, kept to the digit so that the
# tile here and the favicon there are one shape. check-brand.py recomputes
# where these put the 7's centre and requires (32, 32) within 0.05.
TILE_SIZE = 64
TILE_RADIUS = 12
TILE_SCALE = 0.664
TILE_TX = -65.07
TILE_TY = 9.16

START_TAG = re.compile(r"<svg\b[^>]*>", re.S)
SVG_NS = "{http://www.w3.org/2000/svg}"


# ---------------------------------------------------------------------------
# Reading the master
# ---------------------------------------------------------------------------
def read_text(path):
    # newline="" so that the bytes compared later are the bytes on disk.
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def write_text(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def master_path(brand_dir=BRAND_DIR):
    return os.path.join(brand_dir, MASTER_NAME)


def normalise_d(d):
    """A path's `d` with its whitespace collapsed - the geometry, not the layout."""
    return " ".join(d.split())


def strip_ns(tag):
    return tag[len(SVG_NS):] if tag.startswith(SVG_NS) else tag


def shapes_of(text):
    """
    The four shapes of a wordmark, in document order, with their group's paint
    attributes folded in and every `d` normalised:

        [(tag, {attribute: value}), ...]

    This is what two copies of the mark are compared by. It deliberately
    ignores comments, the <title>, width/height and anything outside the two
    groups - those may differ between the master and a consumer without the
    MARK differing.
    """
    root = ET.fromstring(text)
    out = []
    for group in root:
        if strip_ns(group.tag) != "g":
            continue
        paint = {k: v for k, v in group.attrib.items()}
        for shape in group:
            tag = strip_ns(shape.tag)
            attrs = dict(paint)
            for key, value in shape.attrib.items():
                attrs[key] = normalise_d(value) if key == "d" else value
            out.append((tag, attrs))
    return out


def validate_master(text):
    """
    The master has exactly the shapes BR1 says it has: a stroked O and S, a
    filled slash and 7. Returns them as a dict by name. Raises ValueError with
    a sentence when it does not - the generators refuse rather than derive a
    file from something that is not the mark.
    """
    shapes = shapes_of(text)
    if len(shapes) != 4:
        raise ValueError(f"the master has {len(shapes)} shapes, not the four of BR1")
    tags = [tag for tag, _ in shapes]
    if tags != ["ellipse", "path", "path", "path"]:
        raise ValueError(f"the master's shapes are {tags}, not ellipse, path, path, path")
    o, s, slash, seven = shapes
    for name, (_, attrs) in (("O", o), ("S", s)):
        if attrs.get("fill") != "none" or attrs.get("stroke") != ORANGE:
            raise ValueError(f"the {name} is not stroked in {ORANGE}")
    for name, (_, attrs) in (("slash", slash), ("7", seven)):
        if attrs.get("fill") != ORANGE or "stroke" in attrs:
            raise ValueError(f"the {name} is not filled in {ORANGE}")
    return {"O": o[1], "S": s[1], "slash": slash[1], "7": seven[1]}


def split_master(text):
    """
    -> (head, shapes_block)

    head is everything up to and including </title>; shapes_block is everything
    after the master's own comment up to </svg>. The derived files keep the
    head and the block and replace the comment, so that a derived file is the
    master with one colour changed and nothing else - which is what makes the
    byte-for-byte rule mean something.
    """
    start = START_TAG.search(text)
    if not start:
        raise ValueError("no <svg> start tag")
    title_end = text.index("</title>", start.end()) + len("</title>")
    comment_start = text.index("<!--", title_end)
    comment_end = text.index("-->", comment_start) + len("-->")
    block = text[comment_end:text.rindex("</svg>")]
    return text[:title_end], block.lstrip("\n")


# ---------------------------------------------------------------------------
# The derived files
# ---------------------------------------------------------------------------
GENERATED = """<!--
  GENERATED by build/lib/brand.py from os7-wordmark.svg. Do not edit this file:
  change the master and run `python3 build/lib/brand.py write`.
  installer/testing/check-brand.py requires it to be that output byte for byte.

{what}
-->
"""


def generated_comment(what):
    return GENERATED.format(what=what.rstrip("\n"))


WHITE_WHAT = """\
  THE WHITE VARIANT (BRAND-PLAN BR4): the wordmark's geometry, unchanged, with
  the orange replaced by white. It exists because the mark is drawn for a dark
  ground and the login screen stands on the Setup field, #0057ad, where orange
  is 2.5:1 and unreadable; white there is above 7:1. These are the two inks the
  mark has. Where the ground is dark, use the master; where it is the field,
  use this."""

TILE_WHAT = """\
  THE TILE (BRAND-PLAN BR5): the 7 from the wordmark, the same polygon, scaled
  by {scale} into a {size}-unit tile with a {radius}-unit corner and reversed
  out of the brand orange. It is the mark at icon size - the favicon on the
  website, and what LOGO=os7 in /etc/os-release is to name on the image.

  It is the 7 alone and not the wordmark because the wordmark is 2.4 times as
  wide as it is tall: rendered into a 16px favicon it would be about six pixels
  of cap height, which is illegible. A tile with one figure on it is the shape
  that survives that size, and the 7 is the half of "OS/7" nothing else in a
  browser tab or an icon grid looks like."""


def render_white(master_text):
    validate_master(master_text)
    head, block = split_master(master_text)
    return (head + "\n" + generated_comment(WHITE_WHAT) + "\n"
            + block.replace(ORANGE, INK) + "</svg>\n")


def render_tile(master_text):
    seven = validate_master(master_text)["7"]["d"]
    size, radius = TILE_SIZE, TILE_RADIUS
    what = TILE_WHAT.format(scale=TILE_SCALE, size=size, radius=radius)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" '
        f'width="{size}" height="{size}"\n'
        '     role="img" aria-label="OS/7">\n'
        '  <title>OS/7</title>\n'
        + generated_comment(what) +
        f'  <rect width="{size}" height="{size}" rx="{radius}" fill="{ORANGE}"/>\n'
        f'  <path transform="translate({TILE_TX}, {TILE_TY}) scale({TILE_SCALE})" '
        f'fill="{INK}"\n'
        f'        d="{seven}"/>\n'
        '</svg>\n'
    )


DERIVED = [
    (WHITE_NAME, render_white),
    (TILE_NAME, render_tile),
]


# ---------------------------------------------------------------------------
# Geometry questions the check asks (BR1's "the weight is one number")
# ---------------------------------------------------------------------------
def path_points(d):
    """Every coordinate pair in a path of M/L/C/Z commands, in order."""
    numbers = [float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", d)]
    return list(zip(numbers[0::2], numbers[1::2]))


def bbox(points):
    xs = [x for x, _ in points]
    ys = [y for _, y in points]
    return min(xs), min(ys), max(xs), max(ys)


def tile_centre(d):
    """Where the tile's transform puts the 7's bounding-box centre."""
    x0, y0, x1, y1 = bbox(path_points(d))
    cx = TILE_TX + TILE_SCALE * (x0 + x1) / 2
    cy = TILE_TY + TILE_SCALE * (y0 + y1) / 2
    return cx, cy


def hex_to_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


def contrast(ground, ink):
    return palette.ratio(hex_to_rgb(ground), hex_to_rgb(ink))


# ---------------------------------------------------------------------------
# The commands
# ---------------------------------------------------------------------------
def write(brand_dir=BRAND_DIR):
    master = read_text(master_path(brand_dir))
    for name, render in DERIVED:
        write_text(os.path.join(brand_dir, name), render(master))
        print(f"    wrote {name}")


def verify(brand_dir=BRAND_DIR):
    """Each derived file is byte for byte what the master makes. Returns the list of stale ones."""
    master = read_text(master_path(brand_dir))
    stale = []
    for name, render in DERIVED:
        path = os.path.join(brand_dir, name)
        if not os.path.exists(path):
            print(f"    FAIL {name}: missing")
            stale.append(name)
            continue
        same = read_text(path) == render(master)
        print(f"    {'ok  ' if same else 'FAIL'} {name}: "
              f"{'is' if same else 'is NOT'} the master's output")
        if not same:
            stale.append(name)
    return stale


def show():
    print("  tokens")
    for name, value in TOKENS.items():
        print(f"    {name:8} {value}")
    print("  contrast (BR4)")
    for name, ground, ink, floor, must_pass in CONTRAST_RULES:
        r = contrast(ground, ink)
        verdict = "passes" if r >= floor else "fails"
        wanted = "and must" if must_pass else "and must NOT"
        print(f"    {name}: {ink} on {ground} = {r:.2f}:1, floor {floor}:1 - {verdict}, {wanted}")


def main(argv):
    if len(argv) < 2 or argv[1] not in ("write", "verify", "show"):
        print(__doc__)
        return 2
    if argv[1] == "write":
        write()
        return 0
    if argv[1] == "verify":
        return 1 if verify() else 0
    show()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
