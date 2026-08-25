# Cascadia Mono for the installed console — what was measured

**2026-08-25.** Requirement raised: where possible, make
[Cascadia Code](https://github.com/microsoft/cascadia-code) the default font in
**non-GUI mode**. This session answers whether that is possible, what it looks
like, and how it would be built — and it does so against the artefact rather
than against the documentation, because a font is exactly the kind of component
that reports success and renders the wrong picture (BUILD-NOTES #26).

Nothing in `build/` changed. This is the evidence and the design; the
implementation is specified in [../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md)
§2.8 and decided as D15.

**Scope decided during the session:** Cascadia is for the **installed console
only**. `os7-setup` keeps Fixedsys Excelsior — the installer is a deliberate
MS-DOS 6.22 / Windows 2000 reproduction and Fixedsys is load-bearing for that.
D9 is therefore split rather than replaced.

---

## 1. Verdict

**It works, and Cascadia covers OS/7's requirements more completely than
Fixedsys does.** Both PSFs built in this session pass `build/lib/psf.py verify`
with **no failures and no notes** — which the shipping Fixedsys font does not:
it emits four `note` lines for glyphs it lacks.

| | Fixedsys Excelsior (shipping) | Cascadia Mono 2407.24 |
|---|---|---|
| REQUIRED codepoints (356) | 356 — complete | **356 — complete** |
| WANTED codepoints | 9 absent (`U+2030`, `U+2194`, 5 Geometric Shapes, 2 CP437) | **1 absent (`U+21B5`)** |
| Monospaced across the cmap | no — 4 230 of 6 192 at 8 px, needs `fixedwidth` | **yes — 1 810 of 1 863 at exactly 8 px, the other 53 are zero-advance combining marks** |
| Cell tiling | draws 15 px of ink in a 16 px cell, needs `fillcell` (#27) | **overdraws the cell on purpose, tiles unaided** |
| 16×32 | pixel-doubled from 8×16 | **rasterised natively** |
| Licence | public domain / CC0, no obligations | **OFL 1.1 — licence text must ship, and the PSF must not carry the reserved name** |

The one thing Cascadia does *not* do better: its shade characters `░▒▓` are
drawn as diagonal hatching, not as the CP437 dither. §5 says why they are
synthesised instead of rasterised, which settles that and `U+2594` together.

---

## 2. The font, measured

Read out of the shipped binary with `fontTools` 4.63.0, not from the upstream
README.

```
unitsPerEm     2048
hhea           ascender 1900, descender -480, lineGap 0   -> line box 2380
OS/2 typo      1900 / -480 / 0            (agrees with hhea)
OS/2 win       usWinAscent 2226, usWinDescent 480         -> win box  2706
advance        1200 for 2 373 of 2 426 codepoints; 0 for the other 53
capHeight      1420      xHeight 1060
post.isFixedPitch  1
codepoints     2 426
```

**The console cell is 1 : 2, and Cascadia's line box is 1200 : 2380 = 1 : 1.9833.**
That near-coincidence is what makes an 8×16 cell viable at all, and it is the
first thing to check on any candidate font: a face whose line box is not close
to 1 : 2 has to be stretched to fit a console, and stretching monochrome
outlines at 16 px is visible.

### 2.1 Two cell heights, and the font uses both

The block and box characters are **not** drawn to the line box. They are drawn
to the **win box**:

| glyph | x extent (units) | y extent (units) | relative to the win box |
|---|---|---|---|
| `U+2588 █` | 0 … 1200 | **−480 … 2226** | exactly 0.000 … 1.000 |
| `U+2580 ▀` | 0 … 1200 | 873 … 2226 | 0.500 … 1.000 |
| `U+2584 ▄` | 0 … 1200 | −480 … 873 | 0.000 … 0.500 |
| `U+2500 ─` | **−104 … 1304** | 603 … 811 | overhangs both sides |
| `U+2502 │` | 496 … 704 | **−530 … 2226** | overhangs top and bottom |

Two consequences, and they pull in opposite directions:

* **The box-drawing overhang is a gift.** `U+2500` extends 104 units past each
  edge and `U+2502` 50 units below the descender, so the strokes meet across
  cell boundaries by construction. Fixedsys needed `psf.py fillcell` to close a
  one-pixel seam (#27); Cascadia needs nothing. Measured on the built PSF:
  `psf.py verify` reports *cell tiling continuous (12 joins, 7 non-joins)* for
  both sizes, first try.
* **The block elements are half a cell out.** `U+2580 ▀` splits the *win* box
  at its midpoint, which is 0.569 of the *line* box. Rasterise it into a
  line-box cell and the upper half block covers 7 of 16 rows instead of 8, and
  `U+2594 ▔` — the upper one-eighth — lands outside the cell entirely and comes
  out **blank**. Confirmed: the first build failed `psf.py verify` with
  `FAIL Block Elements: present but BLANK: U+2594`, and nothing else.

§5 resolves this by not rasterising them.

### 2.2 Coverage against OS/7's own table

Checked with `build/lib/psf.py`'s `REQUIRED` / `WANTED` lists, so the question
asked is OS/7's, not a generic one.

```
REQUIRED   ASCII printable      95/95      Box Drawing        128/128
           Latin-1 Supplement   96/96      Block Elements      32/32
           Bullet                1/1       Arrows U+2190-2193   4/4
           -> 356 of 356, every one of them advance 1200

WANTED     cp1252 letters       10/10      Geometric Shapes    10/10
           Punctuation          16/16      CP437 symbols       11/11
           Currency / marks      2/2       Arrows (the rest)    3/4
           -> only U+21B5 (carriage-return arrow) absent
```

`U+25B2`/`U+25BC` are present. Fixedsys lacks them, which is why
`Tui/Widgets/SelectionList.cs` draws its scroll hints with `U+2191`/`U+2193`
instead (SESSION-PHASE1-SETUP). That workaround stays — it is on the Setup side,
which keeps Fixedsys — but it is worth recording that it would not be needed
here.

---

## 3. Where the font comes from — and why not from GitHub

The upstream release publishes **one asset: a 150 454 761-byte ZIP** containing
246 entries (every family × weight × format). Pinning that means a 150 MB
download per cold build to extract roughly 600 KB.

**The pinned Ubuntu snapshot already carries the same upstream version:**

```
Package    fonts-cascadia-code
Version    2407.24-3            (upstream 2407.24 — the same release)
Component  universe             Architecture: all
Path       pool/universe/f/fonts-cascadia-code/fonts-cascadia-code_2407.24-3_all.deb
Size       1 355 014 bytes
SHA256     bf3514c3d4617ccf42906724baf48e98c201c565d9a5bb5a2a7f1378b5845184
```

resolved under `OS7_ARCHIVE_BASE/OS7_ARCHIVE_SNAPSHOT` — the pin that
`build/config/os7-release.conf` already holds. That is strictly better than a
second pinned URL on a second domain: the hash is published in the archive's own
`Packages` index and is therefore independently checkable, the transfer is 1.3 MB
instead of 150 MB, and no new trust root is introduced.

The file used out of it:

```
/usr/share/fonts/truetype/cascadia-code/CascadiaMono.ttf
688 612 bytes
SHA256 4bac5958d02c6fcf2b9365c5fdf65b9dc3a500a572c80357da7533d9fca9b098
family "Cascadia Mono", version "Version 2407.024"
fvar: wght 200 .. 400 (default) .. 700
```

**Mono, not Code.** The two are the same drawing; `Cascadia Code` adds
programming ligatures. A PSF is a fixed cell grid with no shaping engine, so the
ligatures are discarded either way — exactly the `FSEX302-alt.ttf` reasoning in
SETUP-PLAN §2.3, and the same conclusion.

### 3.1 The two sources are not interchangeable — measured

The Debian package ships the **variable** font. The GitHub release also ships
static instances. They are not the same bytes and they do not rasterise the
same:

```
CascadiaMono-Regular.ttf (GitHub, static)   version "Version 2407.024; ttfautohint (v1.8.4)"
CascadiaMono.ttf         (Ubuntu, variable) version "Version 2407.024"

pixel-identical glyphs, over a 132-character sample:
   8x16  hinting on   -> 106 of 132 DIFFER
   8x16  hinting off  ->   1 of 132 differs
  16x32  hinting on   -> 113 of 132 DIFFER
  16x32  hinting off  ->  10 of 132 differ
```

Both files carry `fpgm`/`prep`/`cvt `/`gasp`, but only the static one was run
through `ttfautohint`. With hinting enabled the choice of source therefore
changes almost every glyph on screen; with hinting disabled the two nearly
converge.

**This is a pin, not a preference.** Whichever source is chosen has to stay
chosen, and swapping it silently re-renders the console. Recorded as
BUILD-NOTES #53.

Neither variant produces a collision or a blank glyph: over the 94 printable
ASCII characters, all four combinations give **0 identical pairs and 0 blank
cells**. Hinting is therefore a quality choice, not a correctness one. D15 takes
hinting **on**, because TrueType hinting exists precisely to snap stems to the
pixel grid at small sizes and 8×16 is that case.

---

## 4. The existing pipeline cannot hit the cell — measured

`build/lib/build-console-font.sh` runs `otf2bdf` → `bdf2psf`. That route works
for Fixedsys because Fixedsys's em **is** the cell: `unitsPerEm = 160`,
ascender 130, descender −30, so `-p 16` gives ascent 13 + descent 3 = 16 exactly.

Cascadia's em is not its cell, and the route cannot be made to compensate:

```
otf2bdf -p 14 -rh N -rv N   CascadiaMono-Regular.ttf

  -rh 71  (ppem 13.81)  ascent 12  descent 3  cell 15   DWIDTH 8
  -rh 72  (ppem 14.00)  ascent 12  descent 3  cell 15   DWIDTH 8
  -rh 73  (ppem 14.19)  ascent 12  descent 3  cell 15   DWIDTH 8
  -rh 74  (ppem 14.39)  ascent 12  descent 3  cell 15   DWIDTH 8
  -rh 75  (ppem 14.58)  ascent 13  descent 3  cell 16   DWIDTH 9   <-- width moved too
  -rh 76  (ppem 14.78)  ascent 13  descent 3  cell 16   DWIDTH 9
  -rh 77  (ppem 14.97)  ascent 13  descent 3  cell 16   DWIDTH 9
```

**`-rv` does not affect glyph scaling.** It is documented as "set the vertical
resolution", and it changes the BDF's `RESOLUTION_Y` field, but the outlines are
scaled uniformly from `-p × -rh`: sweeping `-rv` from 70 to 74 against a fixed
`-rh 70` moved neither ascent, descent nor `DWIDTH`. So height follows width,
and at Cascadia's 1200 : 2380 the only cells reachable are **8×15** and **9×16**.
There is no 8×16 on this route.

9×16 is not a free alternative: SETUP-PLAN §2.4's geometry rule is anchored on
1280×800 giving exactly 80×25 with a 16×32 cell. An 18×32 cell gives 71×25 and
the reference geometry is gone.

Recorded as BUILD-NOTES #52. Two other observations from the same runs:

* **`otf2bdf` exits 8 on Cascadia too**, at every size tried — so trap #24 is
  not specific to Fixedsys, and the existing assert-the-artefact handling in
  `build-console-font.sh` is the right shape for both fonts.
* `otf2bdf` reports `SPACING "P"` with `AVERAGE_WIDTH 69` despite
  `post.isFixedPitch = 1`, because the 53 zero-advance combining marks drag the
  average off an integer. `bdf2psf` would refuse the file with *"the width is
  not integer number"* — the same message Fixedsys produced, for a much smaller
  reason. `psf.py fixedwidth` would clear it by dropping 53 glyphs instead of
  1 921.

---

## 5. The route that does work

Rasterise **straight to the cell**, with x and y scaled independently, then
write PSF2 directly. FreeType is the same engine `otf2bdf` uses; what changes is
that the cell is stated rather than inferred.

```
x_ppem   = W · 2048 / 1200        the advance maps to exactly W px
y_ppem   = H · 2048 / 2380        the line box maps to exactly H px
baseline = H − round(480 / 2380 · H)      rows above the baseline

  8×16  -> x_ppem 13.653  y_ppem 13.766  baseline row 13
 16×32  -> x_ppem 27.307  y_ppem 27.532  baseline row 26
```

The two ppem values differ by 0.8 %, which is the whole distortion: Cascadia's
line box is 1 : 1.9833 and the cell is 1 : 2. At 8 px of advance that is
0.06 px of horizontal stretch — below the rasteriser's resolution, and it is
what buys an exact 8×16.

**16×32 is rasterised, not doubled.** This is the visible win. Fixedsys's 16×32
is a mechanical pixel-doubling of its 8×16 (SETUP-PLAN §2.4) and looks it;
Cascadia at 16×32 has twice the outline detail because it is a second
rasterisation. `/etc/default/console-setup` ships 16×32 as the default, so this
is the size users actually see.

### 5.1 Block Elements are synthesised, not rasterised

`U+2580`–`U+259F` are pure geometry — halves, eighths, quadrants and dither.
Computing them is exact where rasterising them is approximate, and §2.1 showed
rasterising them is also *wrong*: they are drawn to the win box, so the eighths
land in the wrong rows and `U+2594` disappears.

Synthesised instead: halves and quadrants from `W//2` and `H//2`, the eighths
from `round(n·H/8)` and `round(n·W/8)`, and the three shades as the CP437
patterns — `░` 25 %, `▒` a checkerboard, `▓` the inverse of `░`. That last part
is not only a fix but a look decision: Cascadia draws the shades as diagonal
hatching, and a progress bar built from diagonal hatching does not read as the
DOS one.

This is the same class of intervention as `psf.py fillcell` — the font is right
about itself and wrong about a console cell — and it replaces it, since
Cascadia needs no seam closing.

### 5.2 Result

```
409 codepoints requested (REQUIRED + WANTED), 32 of them synthesised
os7-console-8x16.psf    7 916 bytes    ->  3 027 bytes gzipped
os7-console-16x32.psf  27 548 bytes    ->  5 281 bytes gzipped
```

`build/lib/psf.py verify --expect 8x16,16x32`, run unmodified from the repo
against both files:

```
  ok    ASCII printable: 95/95          ok    Box Drawing: 128/128
  ok    Latin-1 Supplement: 96/96       ok    Block Elements: 32/32
  ok    Bullet: 1/1                     ok    Arrows: 4/4
  ok    cp1252 letters: 10/10           ok    Punctuation: 16/16
  ok    Currency / marks: 2/2           ok    Arrows (the rest): 4/4
  ok    Geometric Shapes: 10/10         ok    CP437 symbols: 11/11
  ok    cell tiling continuous (12 joins, 7 non-joins)
  ok    9 shape distinctions held
```

Both sizes, every line `ok`. The nine shape distinctions include
`U+2500`/`U+2550` and `U+2591`/`U+2592`, so the failure mode that cost spike S1
a rebuild (#26) is checked and clear here too.

---

## 6. Licence — the part that is not free

Fixedsys is CC0 and ships with no obligation. Cascadia is **SIL OFL 1.1**,
`Copyright 2019-2024 Aaron Bell`, **with Reserved Font Name "Cascadia Code"**.
Two obligations follow, both cheap and both easy to forget:

1. **The licence text must ship with the font** (OFL §2: every copy must carry
   the copyright notice and the licence, as a stand-alone file or a readable
   header). The PSFs are binary, so it is a file:
   `/usr/share/doc/os7-console-font/LICENSE`, staged beside them by the build.
2. **The PSF is a Modified Version and must not carry the reserved name.** OFL
   defines a Modified Version as any derivative made "by changing formats", so
   TTF → PSF qualifies unambiguously. §3 then forbids the reserved name on it.
   Hence **`os7-console-8x16.psf`**, not `os7-cascadia-8x16.psf`.

The asymmetry with `os7-fixedsys-*.psf` is deliberate: Fixedsys may be named
because CC0 imposes nothing, Cascadia may not.

**Not a blocker for anything else.** OFL explicitly permits bundling and
redistribution with software, including inside an ISO, and imposes no fee and no
copyleft on documents or on the rest of the image. The only prohibition that
could bite — §1, the font must not be sold by itself — describes something OS/7
does not do.

---

## 7. What this does not answer

* **Nothing was booted.** Everything here is the artefact measured on the host
  and in the build container: the font file, the BDF, the PSF, and `psf.py
  verify`'s reading of the PSF. What a real framebuffer does with an
  8×16 PSF built this way is unproven, and the repo's own rule says an exit code
  and a verifier are both diagnostics. The check that would close it is the one
  S1 already built: `installer/testing/vmscreen` reads the screen back through
  the console font, so pointing it at a Cascadia console is a small job on top
  of existing machinery.
* **No `console-setup` round trip.** `setupcon` takes `FONT=` verbatim
  (build/config/includes.chroot/etc/default/console-setup explains why), and the
  new filenames are ordinary, but that path has not been exercised.
* **`fbcon` accepts the geometry** — 8×16 and 16×32 are both already in use in
  this image, so nothing new is asked of the kernel. This is inherited, not
  re-measured.
* **The GUI side is out of scope by the requirement.** Worth recording as a free
  extra: installing `fonts-cascadia-code` into the image proper (14 MB) would
  give GNOME Terminal and VS Code the same face *and* satisfy obligation 1
  through the package's own `copyright` file. That is a separate decision.

---

## 8. Reproducing this

Everything was measured with `fontTools`, `freetype-py` and the repo's own
`build/lib/psf.py`, plus `otf2bdf` from the arm64 build container. The font came
from the pinned snapshot:

```bash
curl -fsSLO https://snapshot.ubuntu.com/ubuntu/20260824T000000Z/pool/universe/f/fonts-cascadia-code/fonts-cascadia-code_2407.24-3_all.deb
```

The `otf2bdf` sweep in §4 is the one measurement that needs the container, since
`otf2bdf` is not on the host:

```bash
docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w os7-build:arm64 \
  otf2bdf -p 14 -rh 75 -rv 75 -o /tmp/p.bdf CascadiaMono.ttf
```
