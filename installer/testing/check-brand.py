#!/usr/bin/env python3
"""
The OS/7 mark, held to one geometry. No VM, no Docker, no renderer — seconds.

    ./check-brand.py
    ./check-brand.py --self-test

WHY IT EXISTS. docs/BRAND-PLAN.md BR1 says there is one mark - the four shapes
in brand/os7-wordmark.svg - and that everything else showing OS/7's name as a
picture is derived from it. On 2026-10-29 the repository had FOUR marks: the
website's drawn wordmark, and three <text> elements in DejaVu Sans Bold on blue
tiles in the image - the app icon, the boot splash it is rasterised into, and
the login screen. Nobody had decided that; it had happened, one consumer at a
time, each with a reasonable comment.

That is the shape this repository pays for most often: one specification
written several times, with nothing that says when they stop agreeing (the
netplan renderer in two languages, the palette in two files, the TPM step that
paraphrased a spike - BUILD-NOTES #66). The failure here is not a crash. It is
a product whose logo depends on which file you are looking at.

So: the master has the geometry BR1 records, every derived file is the
generator's output byte for byte, nothing in brand/ is set in a font, every
file keeps `<svg` inside the first 256 bytes (#111), the two inks are the only
colours, and the contrast numbers BR4 was decided on still hold. The consumers
in the image are a BASELINE: the ones that do not yet carry the mark are named
on every run, and their number may fall and may not rise.

WHAT THIS IS NOT. It does not render anything and says nothing about how the
mark LOOKS at 22px or on a framebuffer. Those are measurements on a screen,
owed in BRAND-PLAN §7.

PROVEN TO FIRE. OS7_BRAND_ROOT and OS7_SCAN_ROOT point the rules at another
tree, and --self-test plants each defect in a copy and requires this file to go
red on it - and, first, requires a CORRECT tree to pass at baseline zero, so
that a rule no tree can satisfy is caught as well.
"""
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "build", "lib"))
import brand  # noqa: E402

BRAND_DIR = os.environ.get("OS7_BRAND_ROOT", os.path.join(REPO, "brand"))
SCAN_ROOT = os.environ.get("OS7_SCAN_ROOT", REPO)
WEB_ROOT = os.environ.get("OS7_WEB_ROOT", os.path.join(os.path.dirname(REPO), "os7-web"))

# The consumers in the image are brand.CONSUMERS (BRAND-PLAN §4): each must be
# the generator's output byte for byte - the icon a copy of the tile, the login
# mark the lockup rendered over the master and the vendor file.
#
# Debt, named on every run: consumers that are NOT that output. It may fall and
# may not rise. It was 2 when this file was written on 2026-10-29, and Stage 2
# took it to 0 the same day.
BASELINE_DEFAULT = 0

# BR1, recorded. The master is authoritative for the mark and this is the
# check's record of it, so that a coordinate cannot move by accident - moving
# one on purpose means moving it here too, in the same change.
CANON = {
    "O": ("ellipse", {"cx": "21", "cy": "36", "rx": "14.8", "ry": "20.8"}),
    "S": ("path", {"d": "M 78.4 21.5 C 78.4 17.2, 72.0 15.2, 64.0 15.2 "
                        "C 55.6 15.2, 49.6 18.6, 49.6 24.2 "
                        "C 49.6 29.8, 55.6 32.0, 64.0 33.8 "
                        "C 72.4 35.6, 78.4 38.2, 78.4 44.4 "
                        "C 78.4 50.6, 72.4 56.8, 64.0 56.8 "
                        "C 55.6 56.8, 49.6 53.2, 49.6 48.6"}),
    "slash": ("path", {"d": "M 88.55 68 L 95.45 68 L 121.45 4 L 114.55 4 Z"}),
    "7": ("path", {"d": "M 124.8 24 L 124.8 8.8 L 167.62 8.8 L 148.42 60 "
                        "L 141.58 60 L 158.38 15.2 L 131.2 15.2 L 131.2 24 Z"}),
}
WEIGHT = 6.4
CAP_TOP, CAP_BOTTOM = 12.0, 60.0

HEX_LITERAL = re.compile(r"#[0-9a-fA-F]{3,8}\b")
PAINT = re.compile(r'\b(?:fill|stroke)="([^"]+)"')

FAILS = []
CHECKS = 0


def check(ok, what, detail=""):
    global CHECKS
    CHECKS += 1
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)


def note(text):
    print(f"      NOTE  {text}")


def blank_comments(text):
    """Comments explain colours; a colour NAMED is not a colour USED (check-gui-tokens learned that)."""
    return re.sub(r"<!--.*?-->", lambda m: re.sub(r"[^\n]", " ", m.group(0)), text, flags=re.S)


def svg_offset(text):
    return text.find("<svg")


def geometry(attrs):
    """A shape's geometry alone: its coordinates, not its paint."""
    return {k: v for k, v in attrs.items() if k in ("cx", "cy", "rx", "ry", "d")}


def brand_svgs():
    return sorted(name for name in os.listdir(BRAND_DIR) if name.endswith(".svg"))


def carries_wordmark(text):
    """Does this file contain the four shapes of the mark, in either ink?"""
    if "<text" in blank_comments(text):
        return False
    try:
        present = [geometry(a) for _, a in brand.shapes_of(text)]
    except Exception:  # not even XML
        return False
    return all(geometry(attrs) in present for _, attrs in CANON.values())


def run():
    del FAILS[:]
    global CHECKS
    CHECKS = 0

    print("OS/7 brand — one mark, held to one geometry")
    print()

    # ---------------------------------------------------------------- 1
    print("  1. The master is the mark BR1 records")

    master_path = os.path.join(BRAND_DIR, brand.MASTER_NAME)
    if not os.path.exists(master_path):
        check(False, "brand/os7-wordmark.svg exists", master_path)
        return FAILS
    master = brand.read_text(master_path)

    offset = svg_offset(master)
    check(0 <= offset < 256, "the master's <svg> begins inside the first 256 bytes (#111)",
          f"byte {offset}")

    try:
        shapes = brand.validate_master(master)
        check(True, "four shapes: a stroked O and S, a filled slash and 7")
    except ValueError as error:
        check(False, "four shapes: a stroked O and S, a filled slash and 7", str(error))
        return FAILS

    for name, (tag, wanted) in CANON.items():
        got = geometry(shapes[name])
        check(got == wanted, f"the {name} has the recorded geometry",
              "" if got == wanted else f"{got}")

    check(shapes["O"].get("stroke-width") == str(WEIGHT)
          and shapes["S"].get("stroke-width") == str(WEIGHT),
          f"the O and the S are stroked at {WEIGHT}")

    def horizontal_weight(d, top_index, bottom_index):
        """A filled stroke's horizontal width, against what a 6.4 stroke of its slope would be."""
        pts = brand.path_points(d)
        (x_top, y_top), (x_bottom, y_bottom) = pts[top_index], pts[bottom_index]
        rise = abs(y_bottom - y_top)
        length = math.hypot(x_bottom - x_top, y_bottom - y_top)
        return WEIGHT * length / rise

    slash_pts = brand.path_points(shapes["slash"]["d"])
    slash_width = slash_pts[1][0] - slash_pts[0][0]
    slash_wanted = horizontal_weight(shapes["slash"]["d"], 3, 0)
    check(abs(slash_width - slash_wanted) < 0.02,
          f"the slash is a {WEIGHT} stroke cut horizontally",
          f"width {slash_width:.2f}, a {WEIGHT} stroke of that slope cuts at {slash_wanted:.2f}")

    seven_pts = brand.path_points(shapes["7"]["d"])
    seven_width = seven_pts[3][0] - seven_pts[4][0]
    seven_wanted = horizontal_weight(shapes["7"]["d"], 2, 3)
    check(abs(seven_width - seven_wanted) < 0.02,
          f"the 7's diagonal is a {WEIGHT} stroke cut horizontally",
          f"width {seven_width:.2f}, a {WEIGHT} stroke of that slope cuts at {seven_wanted:.2f}")

    o = shapes["O"]
    o_top = float(o["cy"]) - float(o["ry"]) - WEIGHT / 2
    o_bottom = float(o["cy"]) + float(o["ry"]) + WEIGHT / 2
    s_x0, s_y0, s_x1, s_y1 = brand.bbox(brand.path_points(shapes["S"]["d"]))
    check((o_top, o_bottom) == (CAP_TOP, CAP_BOTTOM)
          and (s_y0 - WEIGHT / 2, s_y1 + WEIGHT / 2) == (CAP_TOP, CAP_BOTTOM),
          f"the O and the S stand on one cap line, y {CAP_TOP:g}..{CAP_BOTTOM:g}",
          f"O {o_top:g}..{o_bottom:g}, S {s_y0 - WEIGHT / 2:g}..{s_y1 + WEIGHT / 2:g}")

    # ---------------------------------------------------------------- 2
    print()
    print("  2. Drawn, not set (BR2)")

    for name in brand_svgs():
        text = blank_comments(brand.read_text(os.path.join(BRAND_DIR, name)))
        check("<text" not in text and "font-family" not in text,
              f"{name} contains no <text> and names no font")

    # ---------------------------------------------------------------- 3
    print()
    print("  3. <svg> inside the first 256 bytes of every brand file (BR7, #111)")

    for name in brand_svgs():
        offset = svg_offset(brand.read_text(os.path.join(BRAND_DIR, name)))
        check(0 <= offset < 256, f"{name}", f"byte {offset}")

    # ---------------------------------------------------------------- 4
    print()
    print("  4. Two inks, and nothing else (BR4)")

    inks = {brand.ORANGE, brand.INK}
    for name in brand_svgs():
        text = blank_comments(brand.read_text(os.path.join(BRAND_DIR, name)))
        literals = {literal.lower() for literal in HEX_LITERAL.findall(text)}
        paints = {value.lower() for value in PAINT.findall(text)}
        strange = sorted((literals | paints) - inks - {"none"})
        check(not strange, f"{name} paints only in {brand.ORANGE} or {brand.INK}",
              ", ".join(strange))

    # ---------------------------------------------------------------- 5
    print()
    print("  5. Every derived file is the generator's output, byte for byte (BR6)")

    stale = brand.verify(BRAND_DIR)
    check(not stale, "os7-wordmark-white.svg and os7-tile.svg are what the master makes",
          ", ".join(stale))

    # ---------------------------------------------------------------- 6
    print()
    print("  6. The tile is the wordmark's 7 (BR5)")

    tile_path = os.path.join(BRAND_DIR, brand.TILE_NAME)
    if os.path.exists(tile_path):
        tile = brand.read_text(tile_path)
        match = re.search(r'<path[^>]*\bd="([^"]+)"', tile)
        tile_d = brand.normalise_d(match.group(1)) if match else ""
        check(tile_d == CANON["7"][1]["d"], "the tile's path is the 7's path")
        cx, cy = brand.tile_centre(tile_d or CANON["7"][1]["d"])
        half = brand.TILE_SIZE / 2
        check(abs(cx - half) < 0.05 and abs(cy - half) < 0.05,
              f"the transform centres the 7 on ({half:g}, {half:g})", f"({cx:.3f}, {cy:.3f})")
    else:
        check(False, "brand/os7-tile.svg exists")

    # ---------------------------------------------------------------- 7
    print()
    print("  7. The contrast BR4 was decided on")

    for name, ground, ink, floor, must_pass in brand.CONTRAST_RULES:
        ratio = brand.contrast(ground, ink)
        passes = ratio >= floor
        if must_pass:
            check(passes, f"{name} clears {floor}:1", f"{ratio:.2f}:1")
        else:
            check(not passes, f"{name} stays BELOW {floor}:1 - the reason the white variant exists",
                  f"{ratio:.2f}:1")

    # ---------------------------------------------------------------- 8
    print()
    print("  8. The consumers in the image - each the generator's output (BR6)")

    tile_bytes = brand.read_text(tile_path) if os.path.exists(tile_path) else None
    vendor_path = os.path.join(SCAN_ROOT, brand.VENDOR_REL)
    vendor_text = brand.read_text(vendor_path) if os.path.exists(vendor_path) else None
    if vendor_text is None:
        note(f"the vendor file is missing at {vendor_path}; the lockup cannot be rendered")
    debt = 0
    for what, rel, kind in brand.CONSUMERS:
        path = os.path.join(SCAN_ROOT, rel)
        if not os.path.exists(path):
            print(f"      ----  {what}: {rel} is absent")
            debt += 1
            continue
        text = brand.read_text(path)
        wanted = None
        if kind != "lockup" or vendor_text is not None:
            try:
                wanted = brand.render_consumer(kind, master, vendor_text)
            except ValueError as error:
                note(f"{what}: {error}")
        same = wanted is not None and text == wanted
        print(f"      {'ok  ' if same else '----'}  {what}: "
              f"{'is' if same else 'is NOT'} byte-identical to what brand.py renders")
        if not same:
            debt += 1
        if kind == "lockup":
            # The meaning behind the bytes, asked separately: a generator that
            # itself emitted <text> would pass the byte rule and fail BR2.
            check(carries_wordmark(text),
                  "the login screen's mark carries the four shapes and sets nothing in a font")

    baseline = int(os.environ.get("OS7_BRAND_BASELINE", BASELINE_DEFAULT))
    check(debt <= baseline, f"consumers not carrying the mark: {debt}, baseline {baseline}",
          "" if debt <= baseline else "the debt ROSE")
    if debt < baseline:
        note(f"the debt fell to {debt}; lower BASELINE_DEFAULT in this file to hold it there")

    # ---------------------------------------------------------------- 9
    print()
    print("  9. The boot splash: the master's pixels, and a script that agrees (BR8)")

    theme = os.path.join(SCAN_ROOT, brand.SPLASH_REL)
    sprites = brand.splash_sprites(master)
    for name, want in sprites.items():
        check(brand.sprite_matches(os.path.join(theme, name), want),
              f"{name} decodes to what brand_raster.py renders from the master")

    script_path = os.path.join(theme, "os7.script")
    script = brand.read_text(script_path) if os.path.exists(script_path) else ""
    check(bool(script), "os7.script exists", script_path)
    code = re.sub(r"#[^\n]*", "", script)
    for key, value in brand.SPLASH_LAYOUT.items():
        m = re.search(rf"^\s*{key}\s*=\s*(\d+)\s*;", code, re.M)
        got = int(m.group(1)) if m else None
        check(got == value, f"os7.script's {key} is brand.py's {value}",
              "" if got == value else f"the script says {got}")
    loaded = set(re.findall(r'Image\(\s*"([^"]+)"\s*\)', code)) \
        | set(re.findall(r'scaled\(\s*"([^"]+)"\s*\)', code))
    check(loaded == set(sprites),
          "the script loads exactly the sprites the generator makes",
          "" if loaded == set(sprites) else
          f"loads {sorted(loaded - set(sprites))} that do not exist, "
          f"never loads {sorted(set(sprites) - loaded)}")

    plymouth_path = os.path.join(theme, "os7.plymouth")
    plymouth = brand.read_text(plymouth_path) if os.path.exists(plymouth_path) else ""
    for line in ("ModuleName=script",
                 "ImageDir=/usr/share/plymouth/themes/os7",
                 "ScriptFile=/usr/share/plymouth/themes/os7/os7.script"):
        check(line in plymouth.splitlines(), f"os7.plymouth says {line}")

    # ---------------------------------------------------------------- 10
    print()
    print(" 10. The website's copies, where a checkout is beside this one (BR3)")

    web_mark = os.path.join(WEB_ROOT, "site", "brand", "os7-wordmark.svg")
    web_icon = os.path.join(WEB_ROOT, "site", "brand", "favicon.svg")
    if os.path.exists(web_mark):
        try:
            same = [geometry(a) for _, a in brand.shapes_of(brand.read_text(web_mark))] == \
                   [geometry(a) for _, a in brand.shapes_of(master)]
        except Exception as error:  # the website's file is not parseable XML
            same = False
            note(f"the website's wordmark did not parse: {error}")
        check(same, "the website's wordmark has the master's geometry", web_mark)
        if os.path.exists(web_icon):
            icon = brand.read_text(web_icon)
            d = re.search(r'<path[^>]*\bd="([^"]+)"', icon)
            t = re.search(r'transform="([^"]+)"', icon)
            tile_t = re.search(r'transform="([^"]+)"', tile_bytes or "")
            check(d is not None and brand.normalise_d(d.group(1)) == CANON["7"][1]["d"]
                  and t is not None and tile_t is not None and t.group(1) == tile_t.group(1),
                  "the website's favicon is the tile's 7, same transform")
        else:
            note(f"NOT CHECKED: no favicon at {web_icon}")
    else:
        note(f"NOT CHECKED: no website checkout at {WEB_ROOT} (set OS7_WEB_ROOT)")

    return FAILS


# ---------------------------------------------------------------------------
# Does the rule FIRE?
# ---------------------------------------------------------------------------
def self_test():
    print("OS/7 brand — does the rule FIRE?")
    print()

    results = []
    work = tempfile.mkdtemp(prefix="os7-brand-")
    try:
        planted = os.path.join(work, "brand")
        scan = os.path.join(work, "scan")

        def fresh():
            """A pristine copy of brand/, and a scan root whose consumers ALL carry the mark."""
            shutil.rmtree(planted, ignore_errors=True)
            shutil.rmtree(scan, ignore_errors=True)
            shutil.copytree(os.path.join(REPO, "brand"), planted)
            master_text = brand.read_text(os.path.join(planted, brand.MASTER_NAME))
            # The vendor file is an INPUT, not a consumer: it comes along verbatim.
            vendor_text = brand.read_text(os.path.join(REPO, brand.VENDOR_REL))
            brand.write_text(os.path.join(scan, brand.VENDOR_REL), vendor_text)
            for _, rel, kind in brand.CONSUMERS:
                brand.write_text(os.path.join(scan, rel),
                                 brand.render_consumer(kind, master_text, vendor_text))
            # The splash theme: its two hand-written files copied, its sprites
            # rendered fresh into the scan root.
            os.makedirs(os.path.join(scan, brand.SPLASH_REL), exist_ok=True)
            for name in ("os7.script", "os7.plymouth"):
                shutil.copy(os.path.join(REPO, brand.SPLASH_REL, name),
                            os.path.join(scan, brand.SPLASH_REL, name))
            brand.write_sprites(scan, master_text)

        def run_check(baseline=0):
            env = {**os.environ, "OS7_BRAND_ROOT": planted, "OS7_SCAN_ROOT": scan,
                   "OS7_BRAND_BASELINE": str(baseline),
                   "OS7_WEB_ROOT": os.path.join(work, "no-website")}
            return subprocess.run([sys.executable, os.path.abspath(__file__)],
                                  env=env, capture_output=True, text=True).returncode

        def edit(name, old, new, root=None):
            path = os.path.join(root or planted, name)
            text = brand.read_text(path)
            assert old in text, f"planting {name}: {old!r} not found"
            brand.write_text(path, text.replace(old, new, 1))

        # The CONTROL first: a correct tree, every consumer branded, baseline 0.
        fresh()
        results.append(("a correct tree with every consumer carrying the mark passes at baseline 0",
                        run_check() == 0))

        # Defect 1: a coordinate moves in the master.
        fresh()
        edit(brand.MASTER_NAME, 'rx="14.8"', 'rx="14.9"')
        results.append(("a coordinate moved in the master is caught", run_check() != 0))

        # Defect 2: a font sneaks into a brand file.
        fresh()
        edit(brand.WHITE_NAME, "</svg>",
             '  <text x="0" y="0" font-family="DejaVu Sans">OS/7</text>\n</svg>')
        results.append(("a <text> element planted in a brand file is caught", run_check() != 0))

        # Defect 3: the prose moves above the <svg> tag (#111).
        fresh()
        edit(brand.MASTER_NAME, "<svg", "<!-- " + "x" * 300 + " -->\n<svg")
        results.append(("<svg> pushed past byte 256 is caught", run_check() != 0))

        # Defect 4: a third colour.
        fresh()
        edit(brand.TILE_NAME, f'fill="{brand.INK}"', 'fill="#ff0000"')
        results.append(("a colour that is not one of the two inks is caught", run_check() != 0))

        # Defect 5: a derived file edited by hand.
        fresh()
        edit(brand.TILE_NAME, "L 167.62 8.8", "L 167.0 8.8")
        results.append(("a derived file that is no longer the generator's output is caught",
                        run_check() != 0))

        # Defect 6: a consumer stops carrying the mark.
        fresh()
        edit(brand.CONSUMERS[1][1], "</svg>",
             '  <text x="440" y="180" font-family="DejaVu Sans">OS/7</text>\n</svg>', root=scan)
        results.append(("a consumer that stops carrying the mark raises the debt and is caught",
                        run_check() != 0))

        # Defect 7: the consumer that must be byte-identical drifts by a byte.
        fresh()
        edit(brand.CONSUMERS[0][1], 'rx="12"', 'rx="13"', root=scan)
        results.append(("an icon that is no longer byte-identical to the tile is caught",
                        run_check() != 0))

        # Defect 8: one pixel of one splash sprite changes. Written through the
        # module's own encoder, so the file is a valid PNG and only the PIXELS
        # say anything is wrong.
        fresh()
        sprite = os.path.join(scan, brand.SPLASH_REL, "seven.png")
        with open(sprite, "rb") as handle:
            width, height, rows = brand.brand_raster.decode_png(handle.read())
        middle = bytearray(rows[height // 2])
        middle[(width // 2) * 4 + 3] ^= 0x01
        rows = rows[:height // 2] + [bytes(middle)] + rows[height // 2 + 1:]
        with open(sprite, "wb") as handle:
            handle.write(brand.brand_raster.encode_png(width, height, rows))
        results.append(("a splash sprite one alpha step off the master is caught",
                        run_check() != 0))

        # Defect 9: the script's layout drifts from the generator's — a block
        # pitch the frame PNG was not drawn for.
        fresh()
        edit(os.path.join(brand.SPLASH_REL, "os7.script"),
             "block_pitch = 25;", "block_pitch = 26;", root=scan)
        results.append(("a script layout number that disagrees with brand.py is caught",
                        run_check() != 0))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    for what, ok in results:
        print(f"      {'ok  ' if ok else 'FAIL'}  {what}")

    bad = [what for what, ok in results if not ok]
    print()
    print(f"  {len(results) - len(bad)} ok, {len(bad)} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())

    failures = run()
    print()
    if failures:
        print(f"  FAILED: {len(failures)} of {CHECKS} checks")
        for failure in failures:
            print(f"    {failure}")
        sys.exit(1)
    print(f"  {CHECKS} checks, all ok")
    sys.exit(0)
