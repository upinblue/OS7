#!/usr/bin/env python3
"""
The OS/7 brand — docs/BRAND-PLAN.md BR1–BR8, as code.

    brand.py write      regenerate every derived file from the master: the two
                        beside it in brand/, and the copies the image consumes
    brand.py verify     each of those is what the master makes, byte for byte
    brand.py show       the tokens, and the contrast numbers BR4 was decided on

ONE SOURCE. brand/os7-wordmark.svg is the mark (BR1). This module reads it,
validates that it still has the four shapes it is supposed to have, and derives
everything else from them: the white variant for the Setup field, the tile for
icon sizes, the login screen's lockup, and the copy of the tile that LOGO=os7
names in the image. Nothing derived is ever edited by hand; `write` regenerates
it and installer/testing/check-brand.py requires the result byte for byte
(BR6).

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

# ---------------------------------------------------------------------------
# The consumers in the image (BRAND-PLAN §4): what `write` writes there and
# what check-brand.py and check-image.py hold. Repository-relative.
#
#   "tile"    a byte copy of brand/os7-tile.svg - the icon LOGO=os7 names,
#             which hook 0035 also rasterises into the interim boot splash
#   "lockup"  render_login_lockup() over the master and the vendor file -
#             what the login screen draws
# ---------------------------------------------------------------------------
CONSUMERS = [
    ("the app icon LOGO=os7 names",
     "build/config/includes.chroot/usr/share/icons/hicolor/scalable/apps/os7.svg",
     "tile"),
    ("the login screen's mark",
     "build/packages/os7-desktop-theme/tree/usr/share/pixmaps/os7-logo-login.svg",
     "lockup"),
]

# The vendor mark, verbatim - the lockup carries its paths beneath the wordmark.
VENDOR_REL = "build/packages/os7-desktop-theme/tree/usr/share/pixmaps/upinblue-logo.svg"

# The lockup's geometry. The natural size is what gnome-shell's LoginDialog
# draws (load_file_sync at -1, -1 times the scale factor - read out of
# libshell-18.so for the previous file); the viewBox, the rule and the vendor
# group are the previous lockup's, unchanged, so that only the wordmark moved.
LOCKUP_WIDTH, LOCKUP_HEIGHT = 216, 98
LOCKUP_VIEW_W, LOCKUP_VIEW_H = 880, 400
LOCKUP_SCALE = 2.7           # cap height 48 -> 129.6 units, the old text's cap height was ~131
LOCKUP_CAP_FOOT = 180        # where the cap line's foot lands: the old text's baseline
LOCKUP_RULE = (220, 226, 440, 4, 0.55)             # x, y, width, height, opacity
LOCKUP_VENDOR_TRANSFORM = "translate(286.75 262) scale(0.6)"
LOCKUP_VENDOR_OPACITY = 0.85

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
    os.makedirs(os.path.dirname(path), exist_ok=True)
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
    The shapes of a mark, in document order, with their group's paint
    attributes folded in and every `d` normalised:

        [(tag, {attribute: value}), ...]

    This is what two copies of the mark are compared by. It deliberately
    ignores comments, the <title>, width/height and anything outside the
    groups - those may differ between the master and a consumer without the
    MARK differing. Groups nest in the vendor's file, so it descends.
    """
    root = ET.fromstring(text)
    out = []

    def walk(node, paint):
        for child in node:
            tag = strip_ns(child.tag)
            if tag == "g":
                walk(child, {**paint, **child.attrib})
            elif tag in ("ellipse", "path", "rect", "circle", "polygon", "line"):
                attrs = dict(paint)
                for key, value in child.attrib.items():
                    attrs[key] = normalise_d(value) if key == "d" else value
                out.append((tag, attrs))

    for group in root:
        if strip_ns(group.tag) == "g":
            walk(group, dict(group.attrib))
    return out


def view_box(text):
    """The root's viewBox as four floats."""
    root = ET.fromstring(text)
    return [float(v) for v in root.attrib["viewBox"].split()]


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
  GENERATED by build/lib/brand.py from {source}. Do not edit this file:
  change the master and run `python3 build/lib/brand.py write`.
  installer/testing/check-brand.py requires it to be that output byte for byte.

{what}
-->
"""


def generated_comment(what, source="os7-wordmark.svg"):
    return GENERATED.format(what=what.rstrip("\n"), source=source)


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
  website, and what LOGO=os7 in /etc/os-release names on the image, where it
  lives as a byte copy at usr/share/icons/hicolor/scalable/apps/os7.svg and is
  also rasterised by hook 0035 into plymouth's bgrt fallback until the boot
  splash has a theme of its own (BR8).

  It is the 7 alone and not the wordmark because the wordmark is 2.4 times as
  wide as it is tall: rendered into a 16px favicon it would be about six pixels
  of cap height, which is illegible. A tile with one figure on it is the shape
  that survives that size, and the 7 is the half of "OS/7" nothing else in a
  browser tab or an icon grid looks like."""

LOCKUP_WHAT = """\
  THE LOGIN SCREEN'S MARK (BRAND-PLAN BR4, BR6): the OS/7 wordmark in its white
  ink, a rule, and the vendor's mark beneath it, on the greeter's field -
  #0057ad, set in /usr/share/gdm/dconf/95-os7-login-screen beside the key that
  names this file. The only thing that decides that it is shown at all is that
  key: /org/gnome/login-screen/logo. docs/BUILD-NOTES.md #110.

  WHY WHITE. The mark is orange, and orange on the field is {orange_on_field}:1;
  white is {ink_on_field}:1. Those are BR4's two inks, and the ground chose this one.

  THE SIZE IS NOT A GUESS. gnome-shell's LoginDialog._updateLogoTexture, read
  out of libshell-18.so, loads this file at natural size (-1, -1) times the
  HiDPI scale factor - so width and height here ARE the pixels drawn, with the
  viewBox fixing nothing but the aspect ratio. Ubuntu's is 187x72; {w}x{h} is
  the same order and leaves the vendor mark about 100 px to work with. Its
  2.4-unit stripes resolve into a soft frame at scale 1 and sharpen at scale
  2, which is a property of that mark and not a defect here.

  THE WORDMARK is the master's four shapes under one transform: scale {scale},
  so cap height 48 becomes {cap:g} units, with the cap line's foot on
  y={foot} - where the previous, font-set wordmark had its baseline - and
  centred. The previous file was <text> in DejaVu Sans Bold, which is one of
  the three marks BR1 replaced.

  THE VENDOR PATHS are upinblue-logo.svg's {n}, in document order, with the
  class attribute dropped so that the group's fill colours them: the vendor's
  own #417cbf on this field is about 1.7:1. Edit the vendor file and
  regenerate; never these.

  WHY THIS COMMENT IS INSIDE THE <svg> ELEMENT: because a comment above it
  blanked this very screen on a real machine (#111). GdkPixbuf decides whether
  a file is an image by sniffing a 256-byte prefix; `<svg` past byte 256 and
  load_file_sync throws inside LoginDialog, which then does not exist."""


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


def vendor_paths(vendor_text):
    """The vendor mark's <path> elements, in document order, class attribute dropped."""
    paths = re.findall(r"<path\b[^>]*/>", vendor_text)
    if not paths:
        raise ValueError("the vendor file has no <path> elements")
    return [re.sub(r'\s+class="[^"]*"', "", p) for p in paths]


def lockup_transform(master_text):
    """Where the wordmark goes in the lockup: centred, cap foot on LOCKUP_CAP_FOOT."""
    shapes = validate_master(master_text)
    _, _, width, _ = view_box(master_text)
    o = shapes["O"]
    cap_foot = float(o["cy"]) + float(o["ry"]) + float(o["stroke-width"]) / 2
    tx = (LOCKUP_VIEW_W - width * LOCKUP_SCALE) / 2
    ty = LOCKUP_CAP_FOOT - cap_foot * LOCKUP_SCALE
    return tx, ty


def render_login_lockup(master_text, vendor_text):
    shapes = validate_master(master_text)
    paths = vendor_paths(vendor_text)
    tx, ty = lockup_transform(master_text)
    o = shapes["O"]
    cap = (float(o["cy"]) + float(o["ry"]) + float(o["stroke-width"]) / 2
           - (float(o["cy"]) - float(o["ry"]) - float(o["stroke-width"]) / 2))
    what = LOCKUP_WHAT.format(
        orange_on_field=f"{contrast(FIELD, ORANGE):.2f}",
        ink_on_field=f"{contrast(FIELD, INK):.2f}",
        w=LOCKUP_WIDTH, h=LOCKUP_HEIGHT, scale=LOCKUP_SCALE,
        cap=cap * LOCKUP_SCALE, foot=LOCKUP_CAP_FOOT, n=len(paths))
    transform = f'transform="translate({tx:g} {ty:g}) scale({LOCKUP_SCALE})"'
    rx, ry, rw, rh, ro = LOCKUP_RULE
    vendor = "\n".join(f"    {p}" for p in paths)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" version="1.1"\n'
        f'     width="{LOCKUP_WIDTH}" height="{LOCKUP_HEIGHT}" '
        f'viewBox="0 0 {LOCKUP_VIEW_W} {LOCKUP_VIEW_H}">\n'
        '  <title>OS/7</title>\n'
        + generated_comment(what, source="os7-wordmark.svg and upinblue-logo.svg") +
        '\n'
        '  <!-- OS/7, the product: the wordmark, white. -->\n'
        f'  <g {transform} fill="none" stroke="{INK}" '
        f'stroke-width="{o["stroke-width"]}" stroke-linecap="{o["stroke-linecap"]}">\n'
        f'    <ellipse cx="{o["cx"]}" cy="{o["cy"]}" rx="{o["rx"]}" ry="{o["ry"]}"/>\n'
        f'    <path d="{shapes["S"]["d"]}"/>\n'
        '  </g>\n'
        f'  <g {transform} fill="{INK}">\n'
        f'    <path d="{shapes["slash"]["d"]}"/>\n'
        f'    <path d="{shapes["7"]["d"]}"/>\n'
        '  </g>\n'
        '\n'
        '  <!-- The rule that separates product from vendor. -->\n'
        f'  <rect x="{rx}" y="{ry}" width="{rw}" height="{rh}" fill="{INK}" opacity="{ro}"/>\n'
        '\n'
        '  <!-- up in blue GmbH, the vendor: 510.9 x 223.7 at scale 0.6 is 306.5 x 134.2,\n'
        '       centred at x=(880-306.5)/2 and resting on the viewBox floor. -->\n'
        f'  <g transform="{LOCKUP_VENDOR_TRANSFORM}" fill="{INK}" opacity="{LOCKUP_VENDOR_OPACITY}">\n'
        f'{vendor}\n'
        '  </g>\n'
        '</svg>\n'
    )


DERIVED = [
    (WHITE_NAME, render_white),
    (TILE_NAME, render_tile),
]


def render_consumer(kind, master_text, vendor_text):
    if kind == "tile":
        return render_tile(master_text)
    if kind == "lockup":
        return render_login_lockup(master_text, vendor_text)
    raise ValueError(f"unknown consumer kind {kind!r}")


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
def write(brand_dir=BRAND_DIR, repo_root=REPO):
    master = read_text(master_path(brand_dir))
    vendor = read_text(os.path.join(repo_root, VENDOR_REL))
    for name, render in DERIVED:
        write_text(os.path.join(brand_dir, name), render(master))
        print(f"    wrote brand/{name}")
    for _, rel, kind in CONSUMERS:
        write_text(os.path.join(repo_root, rel), render_consumer(kind, master, vendor))
        print(f"    wrote {rel}")


def verify(brand_dir=BRAND_DIR, repo_root=REPO):
    """
    Each derived file - in brand/ and in the image's tree - is byte for byte
    what the master makes. Returns the list of stale ones.
    """
    master = read_text(master_path(brand_dir))
    vendor_path = os.path.join(repo_root, VENDOR_REL)
    vendor = read_text(vendor_path) if os.path.exists(vendor_path) else None
    stale = []

    def compare(path, label, wanted):
        if not os.path.exists(path):
            print(f"    FAIL {label}: missing")
            stale.append(label)
            return
        same = read_text(path) == wanted
        print(f"    {'ok  ' if same else 'FAIL'} {label}: "
              f"{'is' if same else 'is NOT'} the master's output")
        if not same:
            stale.append(label)

    for name, render in DERIVED:
        compare(os.path.join(brand_dir, name), f"brand/{name}", render(master))
    for _, rel, kind in CONSUMERS:
        if kind == "lockup" and vendor is None:
            print(f"    FAIL {rel}: the vendor file is missing at {vendor_path}")
            stale.append(rel)
            continue
        compare(os.path.join(repo_root, rel), rel, render_consumer(kind, master, vendor))
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
    master = read_text(master_path())
    tx, ty = lockup_transform(master)
    print("  lockup")
    print(f"    wordmark at translate({tx:g} {ty:g}) scale({LOCKUP_SCALE}), "
          f"natural size {LOCKUP_WIDTH}x{LOCKUP_HEIGHT}")


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
