#!/usr/bin/env python3
"""
Rasterise a scalable font into an EXACT console cell and write PSF2.

    cellfont.py build  <font.ttf> <out.psf> <W>x<H> [--no-hinting]
    cellfont.py cell   <font.ttf>                    report the cell arithmetic

Why this exists next to build-console-font.sh rather than inside it: the
`otf2bdf` -> `bdf2psf` route cannot produce an 8x16 cell from Cascadia Mono, and
no flag combination fixes it (BUILD-NOTES #52). `otf2bdf` scales both axes from
`-p x -rh` together, so cell height follows cell width; at Cascadia's advance:line
ratio of 1200:2380 the only reachable cells are 8x15 and 9x16.

That route is still correct for Fixedsys Excelsior and is not touched. Fixedsys's
em IS its cell (unitsPerEm 160, ascender 130, descender -30), so `-p 16` lands on
8x16 exactly. Nothing about that generalises, which is the whole reason this file
exists.

WHAT THIS DOES DIFFERENTLY: it states the cell instead of inferring it. The two
axes are scaled independently, from the font's own advance width and line box:

    x_ppem = W * upem / advance      the advance maps to exactly W px
    y_ppem = H * upem / lineBox      the line box maps to exactly H px

Same rasteriser underneath - FreeType is what otf2bdf uses too - so this is not a
bespoke renderer, it is the same engine asked a better-posed question.

TWO THINGS THAT ARE NOT OPTIONAL, both learned the hard way:

  * `.notdef` IS NOT AN ABSENT GLYPH (BUILD-NOTES #57). FreeType answers every
    request; ask for a codepoint the font lacks and it returns glyph 0, which in
    Cascadia is a hollow rectangle. `bdf2psf` used to refuse and log; replacing
    it removed that guarantee silently. So the cmap is consulted first and a
    missing codepoint is SKIPPED, never rasterised.

  * BLOCK ELEMENTS ARE SYNTHESISED, NOT RASTERISED. Cascadia draws U+2580-259F
    to its *win* box (usWinAscent+usWinDescent = 2706 units), not to the line box
    the text sits in. Rasterised into a line-box cell the eighths land in the
    wrong rows and U+2594 falls outside the cell entirely and comes out blank -
    which is exactly how the first build failed `psf.py verify`. They are pure
    geometry, so computing them is exact where rasterising is both approximate
    and wrong. See blocks() for the shading decision, which is also a look
    decision.

Depends on freetype-py (`python3-freetype`) and on this directory's psf.py for
the codepoint table. No fontTools: FreeType answers the cmap question itself via
get_char_index(), and one dependency is better than two.
"""
import struct
import sys

try:
    import freetype
except ImportError:  # pragma: no cover - the container installs it
    sys.stderr.write(
        "cellfont.py needs freetype-py (Debian/Ubuntu: python3-freetype).\n")
    raise

import psf as psfmod


PSF2_MAGIC = 0x864AB572
PSF2_HAS_UNICODE = 1


# ---------------------------------------------------------------------------
# The cell arithmetic, read out of the font rather than assumed.
#
# `advance` is taken from the advance width of 'M' rather than from an average:
# the average is dragged off an integer by zero-advance combining marks, which
# is the same thing that makes otf2bdf report SPACING "P" on a font whose
# post.isFixedPitch is 1.
#
# `line box` is hhea ascender - descender. NOT the win box: on Cascadia the two
# differ (2380 vs 2706) and the win box is 1:2.255 against a console cell of
# 1:2, which would shrink the letters to fit a box nothing else uses. The
# consequence - that the block elements ARE drawn to the win box - is handled by
# synthesising them, not by distorting every letter to suit thirty-two glyphs.
# ---------------------------------------------------------------------------
def cell_metrics(face):
    upem = face.units_per_EM
    face.load_char("M", freetype.FT_LOAD_NO_SCALE | freetype.FT_LOAD_NO_HINTING)
    advance = face.glyph.metrics.horiAdvance
    line = face.ascender - face.descender
    return upem, advance, line


def describe(path):
    face = freetype.Face(path)
    upem, advance, line = cell_metrics(face)
    print(f"{path}")
    print(f"  unitsPerEm  {upem}")
    print(f"  advance(M)  {advance}")
    print(f"  line box    {line}   (ascender {face.ascender}, descender {face.descender})")
    print(f"  cell ratio  {advance} : {line} = 1 : {line/advance:.4f}"
          f"   (a console cell is 1 : 2)")
    for w, h in ((8, 16), (16, 32)):
        xp = w * upem / advance
        yp = h * upem / line
        print(f"  {w}x{h}: x_ppem {xp:.3f}  y_ppem {yp:.3f}"
              f"  baseline row {h - round(-face.descender / line * h)}"
              f"  stretch {abs(xp/yp - 1)*100:.2f}%")


# ---------------------------------------------------------------------------
# Block Elements U+2580-259F, computed.
#
# Halves and quadrants split the cell; eighths are round(n*H/8) so that the
# eight steps of a progress bar are monotonic and the last one fills the cell.
#
# THE SHADES ARE A LOOK DECISION, not only a correctness one. Cascadia draws
# U+2591-2593 as diagonal hatching, which is a defensible modern choice and
# wrong here: a progress bar built from diagonal hatching does not read as the
# DOS one, and OS/7's console is meant to. These are the CP437 patterns -
# 25%, a checkerboard, and the inverse of the 25% - which is what Fixedsys
# produces and what the reference screenshots show.
# ---------------------------------------------------------------------------
QUADRANTS = {  # bit 3 = top-left, 2 = top-right, 1 = bottom-left, 0 = bottom-right
    0x2596: 0b0010, 0x2597: 0b0001, 0x2598: 0b1000, 0x2599: 0b1011,
    0x259A: 0b1001, 0x259B: 0b1110, 0x259C: 0b1101, 0x259D: 0b0100,
    0x259E: 0b0110, 0x259F: 0b0111,
}


def blocks(cp, W, H):
    """The bitmap for a Block Element, or None if cp is not one."""
    if not (0x2580 <= cp <= 0x259F):
        return None
    g = [[0] * W for _ in range(H)]

    def fill(r0, r1, c0, c1):
        for r in range(max(0, r0), min(H, r1)):
            for c in range(max(0, c0), min(W, c1)):
                g[r][c] = 1

    if cp == 0x2580:                      # upper half
        fill(0, H // 2, 0, W)
    elif 0x2581 <= cp <= 0x2587:          # lower one-eighth .. seven-eighths
        fill(H - round((cp - 0x2580) * H / 8), H, 0, W)
    elif cp == 0x2588:                    # full block
        fill(0, H, 0, W)
    elif 0x2589 <= cp <= 0x258F:          # left seven-eighths .. one-eighth
        fill(0, H, 0, round((0x2590 - cp) * W / 8))
    elif cp == 0x2590:                    # right half
        fill(0, H, W // 2, W)
    elif cp == 0x2594:                    # upper one-eighth
        fill(0, round(H / 8), 0, W)
    elif cp == 0x2595:                    # right one-eighth
        fill(0, H, W - round(W / 8), W)
    elif cp == 0x2591:                    # light shade, 25%
        for r in range(H):
            for c in range(W):
                if r % 2 == 0 and (c + r // 2) % 2 == 0:
                    g[r][c] = 1
    elif cp == 0x2592:                    # medium shade, checkerboard
        for r in range(H):
            for c in range(W):
                if (r + c) % 2 == 0:
                    g[r][c] = 1
    elif cp == 0x2593:                    # dark shade, the inverse of light
        for r in range(H):
            for c in range(W):
                if not (r % 2 == 0 and (c + r // 2) % 2 == 0):
                    g[r][c] = 1
    else:                                 # quadrants
        m = QUADRANTS[cp]
        if m & 0b1000: fill(0, H // 2, 0, W // 2)
        if m & 0b0100: fill(0, H // 2, W // 2, W)
        if m & 0b0010: fill(H // 2, H, 0, W // 2)
        if m & 0b0001: fill(H // 2, H, W // 2, W)
    return g


# ---------------------------------------------------------------------------
# Rasterisation.
#
# FT_LOAD_TARGET_MONO asks for a 1-bit bitmap with a 50% coverage threshold,
# which is what a PSF is. Hinting is ON by default: TrueType hinting exists to
# snap stems to the pixel grid at small sizes, and 8x16 is precisely that case.
#
# Note that hinting makes the SOURCE FILE matter - the same Cascadia release
# ships as a hinted static instance and an unhinted variable font, and they
# render differently (BUILD-NOTES #53). The pin is the file, not the version.
# ---------------------------------------------------------------------------
def rasteriser(path, W, H, hinting=True):
    face = freetype.Face(path)
    upem, advance, line = cell_metrics(face)
    face.set_char_size(int(round(W * upem / advance * 64)),
                       int(round(H * upem / line * 64)), 72, 72)
    flags = freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_MONO
    if not hinting:
        flags |= freetype.FT_LOAD_NO_HINTING
    baseline = H - round(-face.descender / line * H)

    def has(cp):
        return face.get_char_index(cp) != 0

    def glyph(cp):
        face.load_char(cp, flags)
        bm = face.glyph.bitmap
        rows = [[0] * W for _ in range(H)]
        for r in range(bm.rows):
            y = baseline - face.glyph.bitmap_top + r
            if not (0 <= y < H):
                continue
            for c in range(bm.width):
                x = face.glyph.bitmap_left + c
                if 0 <= x < W and bm.buffer[r * bm.pitch + (c >> 3)] & (0x80 >> (c & 7)):
                    rows[y][x] = 1
        return rows

    return has, glyph, baseline


# ---------------------------------------------------------------------------
# PSF2 out.
#
# The Unicode table is what makes `setfont` map codepoints rather than raw byte
# positions; without it the console would show the right pixels for the wrong
# characters. One codepoint per glyph here - no equivalence classes, which is
# the mechanism that silently collapsed the double-line box in the bdf2psf
# route (BUILD-NOTES #26). Nothing is shared, so nothing can be shared wrongly.
# ---------------------------------------------------------------------------
def write_psf2(path, glyphs, codepoints, W, H):
    stride = (W + 7) // 8
    bpg = stride * H
    out = struct.pack("<IIIIIIII", PSF2_MAGIC, 0, 32, PSF2_HAS_UNICODE,
                      len(glyphs), bpg, H, W)
    for bm in glyphs:
        for row in bm:
            v = 0
            for bit in row:
                v = (v << 1) | bit
            out += (v << (stride * 8 - W)).to_bytes(stride, "big")
    # One entry per POSITION, in order. A position with no codepoint gets an
    # empty sequence — legal PSF2, and it is what keeps every later position at
    # the index build() computed for it. Dropping the empty entries instead
    # would shift the whole table by however many slots are unused.
    out += b"".join((b"" if cp is None else chr(cp).encode("utf-8")) + b"\xff"
                    for cp in codepoints)
    with open(path, "wb") as f:
        f.write(out)
    return len(out)


def build(font, out, W, H, hinting=True):
    has, glyph, baseline = rasteriser(font, W, H, hinting)

    wanted, seen = [], set()
    for cp in psfmod.required_codepoints() + psfmod.wanted_codepoints():
        if cp not in seen:
            seen.add(cp)
            wanted.append(cp)

    # ---------------------------------------------------------------------
    # ASCII SITS AT ITS OWN POSITION. This is not tidiness — `setfont` refuses
    # the font otherwise:
    #
    #     setfont: ERROR setfont.c:142 try_loadfont: font position 32 is nonblank
    #     setfont: ERROR setfont.c:154 try_loadfont: background will look funny
    #     exit 71
    #
    # kbd checks that glyph POSITION 32 is blank, because the console uses it as
    # the erase character. Packing the codepoints in table order put U+0040 '@'
    # there and the kernel would not load the font at all — while `psf.py verify`
    # passed everything, because it asks about coverage, shapes and tiling and
    # this is a question about POSITIONS. BUILD-NOTES #59.
    #
    # Laying ASCII out at position == codepoint fixes it structurally rather
    # than by special-casing one slot: 32 is U+0020 and a space is blank by
    # construction. It is also the classic layout, so anything that renders
    # without consulting the Unicode table still gets ASCII right.
    #
    # Positions 0-31 are left empty. 512 - 32 = 480 slots remain against ~408
    # glyphs, so the cap (L19) is still not close to binding.
    # ---------------------------------------------------------------------
    ASCII_LO, ASCII_HI = 0x20, 0x7E
    slots = {}
    rest = []
    for cp in wanted:
        if ASCII_LO <= cp <= ASCII_HI:
            slots[cp] = cp          # position == codepoint
        else:
            rest.append(cp)
    nxt = ASCII_HI + 1
    for cp in rest:
        slots[cp] = nxt
        nxt += 1

    ordered = sorted(slots, key=lambda cp: slots[cp])
    codepoints, glyphs, synthesised, skipped = [], [], [], []
    blank = [[0] * W for _ in range(H)]
    for pos in range(max(slots.values()) + 1 if slots else 0):
        cp = next((c for c in ordered if slots[c] == pos), None)
        if cp is None:
            # An unused slot below ASCII. It must still exist so the positions
            # of everything after it are the ones computed above.
            codepoints.append(None)
            glyphs.append(blank)
            continue
        bm = blocks(cp, W, H)
        if bm is not None:
            synthesised.append(cp)
        elif not has(cp):
            # #57: rasterising this would map it to .notdef and every coverage
            # check downstream would then pass on a hollow rectangle.
            skipped.append(cp)
            codepoints.append(None)
            glyphs.append(blank)
            continue
        else:
            bm = glyph(cp)
        codepoints.append(cp)
        glyphs.append(bm)

    erase = psfmod.PSF_ERASE_POSITION
    if len(glyphs) > erase and any(any(r) for r in glyphs[erase]):
        sys.stderr.write(f"!!! glyph position {erase} is not blank; setfont would "
                         "refuse this font (BUILD-NOTES #59)\n")
        sys.exit(1)

    # ---------------------------------------------------------------------
    # PAD TO EXACTLY 256 OR 512. fbcon accepts nothing else:
    #
    #     drivers/video/fbdev/core/fbcon.c, fbcon_set_font()
    #         if (charcount != 256 && charcount != 512) return -EINVAL;
    #
    # and the kernel reports that as
    #
    #     setfont: ERROR kdfontop.c:240 put_font_kdfontop:
    #              ioctl(KDFONTOP): Invalid argument
    #
    # 441 glyphs is a perfectly good PSF and an unloadable console font.
    # `build-console-font.sh` has always passed 512 to bdf2psf, and psf.py calls
    # the number PSF_MAX_GLYPHS - so the figure was in the repo all along,
    # written down as a CAP. It is not a cap; it is one of two permitted values.
    # BUILD-NOTES #59.
    # ---------------------------------------------------------------------
    target = next((n for n in psfmod.PSF_GLYPH_COUNTS if len(glyphs) <= n), None)
    if target is None:
        sys.stderr.write(f"!!! {len(glyphs)} glyphs exceeds "
                         f"{max(psfmod.PSF_GLYPH_COUNTS)}\n")
        sys.exit(1)
    while len(glyphs) < target:
        glyphs.append(blank)
        codepoints.append(None)

    if len(glyphs) > psfmod.PSF_MAX_GLYPHS:
        sys.stderr.write(f"!!! {len(glyphs)} glyphs exceeds the PSF cap of "
                         f"{psfmod.PSF_MAX_GLYPHS}\n")
        sys.exit(1)

    # A REQUIRED codepoint that is missing is a build failure, not a note. The
    # UI is drawn out of these (SETUP-PLAN 3.1) and a hole in them is a hole in
    # every screen.
    required = set(psfmod.required_codepoints())
    fatal = [cp for cp in skipped if cp in required]
    if fatal:
        sys.stderr.write("!!! font lacks REQUIRED codepoints: "
                         + " ".join(f"U+{c:04X}" for c in fatal) + "\n")
        sys.exit(1)

    size = write_psf2(out, glyphs, codepoints, W, H)
    mapped = sum(1 for c in codepoints if c is not None)
    print(f"    {out}  {W}x{H}  {len(glyphs)} positions, {mapped} mapped  {size} bytes")
    print(f"      baseline row {baseline}, {len(synthesised)} synthesised, "
          f"{len(skipped)} skipped"
          + (" (" + " ".join(f"U+{c:04X}" for c in skipped) + ")" if skipped else "")
          + f"; position 32 blank (setfont, #59)")
    return len(glyphs)


def main(argv):
    if len(argv) >= 3 and argv[1] == "cell":
        describe(argv[2])
        return 0
    if len(argv) >= 5 and argv[1] == "build":
        font, out, geom = argv[2], argv[3], argv[4]
        W, H = (int(v) for v in geom.lower().split("x"))
        build(font, out, W, H, hinting="--no-hinting" not in argv)
        return 0
    sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
