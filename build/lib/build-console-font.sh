#!/usr/bin/env bash
# =============================================================================
# OS/7 — build the console font (SETUP-PLAN §2.5, decision D9).
#
#   Usage: build-console-font.sh <output-dir> [<cache-dir>]
#
# Fixedsys Excelsior ships as a TTF and the Linux console reads PSF only, so a
# conversion is unavoidable. It happens HERE, in the build container, and the
# toolchain never enters the image:
#
#   FSEX302.ttf --otf2bdf--> fixedsys-16.bdf --bdf2psf--> os7-fixedsys-8x16.psf
#                                            --psf.py--> os7-fixedsys-16x32.psf
#
# Two sizes, because 8x16 is unreadable on a modern panel: at 1920x1080 it gives
# a 240x67 grid. The 16x32 is a mechanical pixel-doubling, not a redraw (§2.4).
#
# Nothing here is best-effort. `psf.py verify` fails the build if a glyph the
# Setup UI draws is missing OR present-but-blank, which is L19's mitigation:
# PSF caps at 512 positions against the font's 6 192 codepoints, so the subset
# is a choice and a choice has to be checked.
# =============================================================================

set -euo pipefail

OUT_DIR="${1:?usage: build-console-font.sh <output-dir> [<cache-dir>]}"
CACHE_DIR="${2:-/var/cache/os7-fonts}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# The pin. Verified 2026-08-22 against the DOWNLOADED RELEASE BINARY, not the
# repository — the two differ by one codepoint, which is exactly why.
#
# Note that the release tag (kika's ligature work) and the font's internal
# version (Darien Valentine's 3.02 base) disagree on purpose. Do not "fix" it.
#
# FSEX302-alt.ttf is the sibling with programming ligatures. It is the WRONG
# file: a PSF is a fixed cell grid with no shaping engine, so the conversion
# discards them either way, and picking the alt just makes the hash wrong.
# ---------------------------------------------------------------------------
FONT_TAG="v3.09.10"
FONT_FILE="FSEX302.ttf"
FONT_BYTES="580724"
FONT_SHA256="842f8fbf80f57d867aeb1d2988140d3ea8b4718e5f687035b0a3b66756df3899"
FONT_URL="https://github.com/kika/fixedsys/releases/download/${FONT_TAG}/${FONT_FILE}"

PSF_8x16="os7-fixedsys-8x16.psf"
PSF_16x32="os7-fixedsys-16x32.psf"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo ">>> Console font: Fixedsys Excelsior ${FONT_TAG}"

# ---------------------------------------------------------------------------
# 1. Fetch and verify. Cached, because a full ISO build should not re-download
#    it and because an offline rebuild is worth having.
# ---------------------------------------------------------------------------
mkdir -p "${CACHE_DIR}"
TTF="${CACHE_DIR}/${FONT_FILE}"
if [[ ! -f "${TTF}" ]]; then
	echo "    fetching ${FONT_URL}"
	curl -fsSL --retry 3 -o "${TTF}.part" "${FONT_URL}"
	mv "${TTF}.part" "${TTF}"
fi

ACTUAL_BYTES="$(stat -c %s "${TTF}")"
ACTUAL_SHA="$(sha256sum "${TTF}" | cut -d' ' -f1)"
if [[ "${ACTUAL_BYTES}" != "${FONT_BYTES}" || "${ACTUAL_SHA}" != "${FONT_SHA256}" ]]; then
	echo "!!! ${FONT_FILE} does not match the pin." >&2
	echo "!!!   expected ${FONT_BYTES} bytes, sha256 ${FONT_SHA256}" >&2
	echo "!!!   got      ${ACTUAL_BYTES} bytes, sha256 ${ACTUAL_SHA}" >&2
	echo "!!! Delete ${TTF} to re-fetch, or update the pin deliberately." >&2
	exit 1
fi
echo "    ${FONT_FILE}  ${ACTUAL_BYTES} bytes  sha256 ok"

# ---------------------------------------------------------------------------
# 2. TTF -> BDF at exactly 16 pixels.
#
#    -p 16 -r 72 is the whole trick: at 72 dpi a point IS a pixel, so this is a
#    16-pixel em. The font has unitsPerEm = 160, i.e. 10 units per pixel, so
#    every outline edge lands on a pixel boundary and the rasterisation is exact
#    rather than approximated (§2.3).
#
#    -n turns hinting OFF. Hinting exists to snap outlines to the pixel grid;
#    these outlines are already ON it, so hinting can only move them. Wrong here
#    in a way that would show up as a one-pixel-off box corner.
#
#    Not passing -l: converting the whole cmap costs seconds and a range list is
#    one typo away from silently dropping a block. bdf2psf takes what it needs.
# ---------------------------------------------------------------------------
#    otf2bdf's EXIT CODE IS NOT USABLE ON THIS FONT. It returns 8 for
#    FSEX302.ttf at every point size tried (8, 12, 15, 16, 17, 24, 32) while
#    writing a complete, correct BDF; Liberation fonts through the same command
#    return 0. Measured 2026-08-24, BUILD-NOTES #24.
#
#    So the artefact is asserted instead of the status — the repo's own rule
#    (docs/BUILD-NOTES.md, "a diagnostic must be checked against the thing it
#    claims to check"). Three properties, all cheap: the declared CHARS count
#    matches the blocks actually written, the file is terminated, and the glyphs
#    the UI is drawn from are in it. A truncated conversion fails all three.
BDF="${WORK}/fixedsys-16.bdf"
echo "    otf2bdf -p 16 -r 72 -n"
set +e
otf2bdf -p 16 -r 72 -n -o "${BDF}" "${TTF}" 2> "${WORK}/otf2bdf.log"
OTF_STATUS=$?
set -e
[[ -s "${WORK}/otf2bdf.log" ]] && sed 's/^/      /' "${WORK}/otf2bdf.log" >&2

BDF_DECLARED="$(sed -n 's/^CHARS \([0-9]*\)/\1/p' "${BDF}" 2>/dev/null | head -n1)"
BDF_ACTUAL="$(grep -c '^STARTCHAR' "${BDF}" 2>/dev/null || echo 0)"
BDF_BOX="$(sed -n 's/^FONTBOUNDINGBOX \(.*\)/\1/p' "${BDF}" 2>/dev/null | head -n1)"

if [[ -z "${BDF_DECLARED}" || "${BDF_DECLARED}" -eq 0 ]]; then
	echo "!!! otf2bdf produced no glyphs (exit ${OTF_STATUS})" >&2; exit 1
fi
if [[ "${BDF_DECLARED}" != "${BDF_ACTUAL}" ]]; then
	echo "!!! BDF truncated: header declares ${BDF_DECLARED} glyphs, file has ${BDF_ACTUAL}" >&2
	exit 1
fi
if [[ "$(tail -n1 "${BDF}")" != "ENDFONT" ]]; then
	echo "!!! BDF does not end with ENDFONT - conversion was cut short" >&2; exit 1
fi
echo "    ${BDF_ACTUAL} glyphs, bounding box ${BDF_BOX}, ENDFONT present (otf2bdf exit ${OTF_STATUS})"

# ---------------------------------------------------------------------------
# 3. BDF -> PSF, 512 positions.
#
#    The symbol set is GENERATED from psf.py's table so that the thing built and
#    the thing asserted cannot drift. `useful.set` is appended with a leading
#    colon (bdf2psf: "no warnings about missing symbols") purely to fill the
#    positions the OS/7 set leaves free — nothing depends on what lands there.
# ---------------------------------------------------------------------------
SETFILE="${WORK}/os7.set"
python3 "${HERE}/psf.py" symbols "${SETFILE}"

# bdf2psf's stock equivalences would hand U+2550 the SINGLE horizontal rule and
# collapse the whole double-line box onto the single-line one - Fixedsys has the
# real glyphs, so that is a downgrade, and a silent one. psf.py explains it.
EQUIV="${WORK}/os7.equivalents"
python3 "${HERE}/psf.py" equivalents \
	/usr/share/bdf2psf/standard.equivalents "${EQUIV}"

# The font is NOT monospaced across its whole cmap, and bdf2psf will not take it
# in that state ("the width is not integer number"). Narrow it to the console
# cell first; psf.py explains why that is the correct operation and not a
# workaround, and it fails loudly if a REQUIRED glyph is among the wide ones.
CELL_BDF="${WORK}/fixedsys-16-cell.bdf"
python3 "${HERE}/psf.py" fixedwidth "${BDF}" "${CELL_BDF}" 8

echo "    bdf2psf --fb  -> 512 positions"
bdf2psf --fb --log "${WORK}/bdf2psf.log" \
	"${CELL_BDF}" \
	"${EQUIV}" \
	"${SETFILE}+:/usr/share/bdf2psf/useful.set" \
	512 \
	"${WORK}/${PSF_8x16}"

if [[ -s "${WORK}/bdf2psf.log" ]]; then
	echo "    bdf2psf notes (first 10):"
	sed 's/^/      /' "${WORK}/bdf2psf.log" | head -n 10
fi

# ---------------------------------------------------------------------------
# 4. Close the 15-in-16 seam, THEN double, so both sizes inherit the fix.
# ---------------------------------------------------------------------------
python3 "${HERE}/psf.py" fillcell "${WORK}/${PSF_8x16}"
python3 "${HERE}/psf.py" double "${WORK}/${PSF_8x16}" "${WORK}/${PSF_16x32}"

# ---------------------------------------------------------------------------
# 5. The guard. This is the step that makes the pipeline trustworthy; if it is
#    ever "temporarily" skipped, the font silently becomes decoration.
# ---------------------------------------------------------------------------
echo ">>> Verifying coverage"
python3 "${HERE}/psf.py" verify --expect 8x16,16x32 \
	"${WORK}/${PSF_8x16}" "${WORK}/${PSF_16x32}"

# ---------------------------------------------------------------------------
# 6. Install. Gzipped: console-setup and setfont both read .psf.gz directly, and
#    it is how every font in /usr/share/consolefonts already ships.
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
for f in "${PSF_8x16}" "${PSF_16x32}"; do
	gzip -9nc "${WORK}/${f}" > "${OUT_DIR}/${f}.gz"
	echo "    ${OUT_DIR}/${f}.gz  ($(stat -c %s "${OUT_DIR}/${f}.gz") bytes)"
done

# The uncompressed 8x16 is kept beside them: `setfont` in an initramfs or a
# rescue shell may have no gzip, and it costs 9 KB.
cp "${WORK}/${PSF_8x16}" "${OUT_DIR}/${PSF_8x16}"
echo ">>> Console font done"
