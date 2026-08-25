#!/usr/bin/env bash
# =============================================================================
# OS/7 — build the INSTALLED console's font (SETUP-PLAN §2.8, decision D15).
#
#   Usage: build-installed-console-font.sh <output-dir> [<cache-dir>]
#
# Cascadia Mono ships as a TTF and the Linux console reads PSF, so a conversion
# is unavoidable. It happens HERE, in the build container, and the toolchain
# never enters the image — the same shape as build-console-font.sh, which does
# the same job for os7-setup's Fixedsys.
#
#   fonts-cascadia-code_*.deb --dpkg-deb--> CascadiaMono.ttf
#                             --cellfont--> os7-console-8x16.psf
#                             --cellfont--> os7-console-16x32.psf
#                             --psf.py verify--> or the build stops
#
# WHY THIS IS A SECOND SCRIPT AND NOT A SECOND CALL TO THE FIRST: the two fonts
# need two different routes, and that is a property of the fonts rather than a
# tidiness failure. Fixedsys's em IS the console cell (unitsPerEm 160, ascender
# 130, descender −30), so `otf2bdf -p 16` lands on 8×16 exactly and `bdf2psf`
# takes it from there. Cascadia's em is 2048 against a 1200×2380 cell, and
# otf2bdf scales both axes together, so on that route only 8×15 and 9×16 exist
# and there is no flag that changes it — measured, BUILD-NOTES #52.
#
# BOTH SIZES ARE RASTERISED. Fixedsys's 16×32 is its 8×16 pixel-doubled, because
# a bitmap face has no more detail to give. Cascadia is an outline font, so the
# large cell is a second rasterisation and carries twice the detail. 16×32 is
# what /etc/default/console-setup selects, i.e. the size actually seen.
#
# LICENCE: unlike Fixedsys (CC0), Cascadia is OFL 1.1 with Reserved Font Name
# "Cascadia Code". Two obligations, both handled below and both invisible once
# done, which is why they are asserted rather than trusted (L29):
#   1. the licence text ships beside the PSFs;
#   2. the PSFs are NOT named after the font — OFL calls a format change a
#      Modified Version, and forbids the reserved name on one.
# =============================================================================

set -euo pipefail

OUT_DIR="${1:?usage: build-installed-console-font.sh <output-dir> [<cache-dir>]}"
CACHE_DIR="${2:-/var/cache/os7-fonts}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The pin lives in os7-release.conf and nowhere else (CLAUDE.md: "the only place
# a version number or an archive URL may live"). This script asserts what it
# reads; it does not carry a default for any of it.
RELEASE_CONF="${OS7_RELEASE_CONF:-${HERE}/../config/os7-release.conf}"
if [[ ! -f "${RELEASE_CONF}" ]]; then
	echo "!!! release pin not found: ${RELEASE_CONF}" >&2
	exit 1
fi
# shellcheck source=../config/os7-release.conf
source "${RELEASE_CONF}"

for v in OS7_ARCHIVE_BASE OS7_ARCHIVE_SNAPSHOT OS7_CASCADIA_PACKAGE \
         OS7_CASCADIA_VERSION OS7_CASCADIA_DEB_SHA256 OS7_CASCADIA_TTF \
         OS7_CASCADIA_TTF_SHA256 OS7_CASCADIA_PSF_SHA256_8x16 \
         OS7_CASCADIA_PSF_SHA256_16x32; do
	if [[ -z "${!v:-}" ]]; then
		echo "!!! ${v} is not set in ${RELEASE_CONF}" >&2
		exit 1
	fi
done

PSF_8x16="os7-console-8x16.psf"
PSF_16x32="os7-console-16x32.psf"
LICENCE_NAME="LICENSE"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo ">>> Installed console font: Cascadia Mono (${OS7_CASCADIA_PACKAGE} ${OS7_CASCADIA_VERSION})"

# ---------------------------------------------------------------------------
# 1. Fetch and verify the .deb.
#
#    The pool path is derived, not pinned: Debian's layout puts a package under
#    pool/<component>/<first letter>/<source>/. Deriving it means the pin holds
#    one fact (the version) instead of two that can disagree.
#
#    Cached, so a full ISO rebuild does not re-download and an offline rebuild
#    works — same as the Fixedsys fetch.
# ---------------------------------------------------------------------------
DEB="${OS7_CASCADIA_PACKAGE}_${OS7_CASCADIA_VERSION}_all.deb"
POOL="pool/universe/${OS7_CASCADIA_PACKAGE:0:1}/${OS7_CASCADIA_PACKAGE}/${DEB}"
URL="${OS7_ARCHIVE_BASE}/${OS7_ARCHIVE_SNAPSHOT}/${POOL}"

mkdir -p "${CACHE_DIR}"
DEB_PATH="${CACHE_DIR}/${DEB}"
if [[ ! -f "${DEB_PATH}" ]]; then
	echo "    fetching ${URL}"
	curl -fsSL --retry 3 -o "${DEB_PATH}.part" "${URL}"
	mv "${DEB_PATH}.part" "${DEB_PATH}"
fi

ACTUAL_SHA="$(sha256sum "${DEB_PATH}" | cut -d' ' -f1)"
if [[ "${ACTUAL_SHA}" != "${OS7_CASCADIA_DEB_SHA256}" ]]; then
	echo "!!! ${DEB} does not match the pin." >&2
	echo "!!!   expected sha256 ${OS7_CASCADIA_DEB_SHA256}" >&2
	echo "!!!   got      sha256 ${ACTUAL_SHA}" >&2
	echo "!!! Delete ${DEB_PATH} to re-fetch, or update the pin deliberately." >&2
	exit 1
fi
echo "    ${DEB}  $(stat -c %s "${DEB_PATH}") bytes  sha256 ok"

# ---------------------------------------------------------------------------
# 2. Extract, and hash the TTF SEPARATELY.
#
#    Not belt-and-braces. The .deb hash says which archive file arrived; the TTF
#    hash says which bytes become pixels. Cascadia ships the same version as a
#    hinted static instance and an unhinted variable font and they rasterise
#    differently (BUILD-NOTES #53), so "2407.24" does not identify a rendering
#    and the file that does has to be named.
# ---------------------------------------------------------------------------
dpkg-deb -x "${DEB_PATH}" "${WORK}/deb"
TTF="${WORK}/deb/${OS7_CASCADIA_TTF}"
if [[ ! -f "${TTF}" ]]; then
	echo "!!! ${OS7_CASCADIA_TTF} is not in ${DEB} — the package layout changed." >&2
	echo "!!! What it does contain:" >&2
	dpkg-deb -c "${DEB_PATH}" | awk '{print "!!!   " $NF}' | grep -i '\.ttf$' >&2 || true
	exit 1
fi

TTF_SHA="$(sha256sum "${TTF}" | cut -d' ' -f1)"
if [[ "${TTF_SHA}" != "${OS7_CASCADIA_TTF_SHA256}" ]]; then
	echo "!!! ${OS7_CASCADIA_TTF} does not match the pin." >&2
	echo "!!!   expected sha256 ${OS7_CASCADIA_TTF_SHA256}" >&2
	echo "!!!   got      sha256 ${TTF_SHA}" >&2
	echo "!!! The .deb hash matched, so the package is right and the font inside" >&2
	echo "!!! it changed. That changes every glyph on the console - see #53." >&2
	exit 1
fi
echo "    $(basename "${OS7_CASCADIA_TTF}")  $(stat -c %s "${TTF}") bytes  sha256 ok"

# The cell arithmetic, printed rather than assumed — it is the one number that
# decides whether this font can be a console font at all, and it is cheap to
# show in the build log where a later reader can see it.
python3 "${HERE}/cellfont.py" cell "${TTF}" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# 3. Rasterise both cells.
# ---------------------------------------------------------------------------
echo "    rasterising to an exact cell"
PYTHONPATH="${HERE}" python3 "${HERE}/cellfont.py" build "${TTF}" "${WORK}/${PSF_8x16}"  8x16
PYTHONPATH="${HERE}" python3 "${HERE}/cellfont.py" build "${TTF}" "${WORK}/${PSF_16x32}" 16x32

# ---------------------------------------------------------------------------
# 4. The guard. Same verifier the Fixedsys pipeline uses, deliberately: one
#    definition of "the console font is complete", applied to both fonts.
#
#    It is expected to emit ONE note here — U+21B5, which Cascadia does not
#    have. That is the honest outcome and it is why cellfont.py skips a missing
#    codepoint instead of rasterising it: rasterising would map it to .notdef, a
#    hollow rectangle, and this verifier would then pass it (BUILD-NOTES #57).
# ---------------------------------------------------------------------------
echo ">>> Verifying coverage"
python3 "${HERE}/psf.py" verify --expect 8x16,16x32 \
	"${WORK}/${PSF_8x16}" "${WORK}/${PSF_16x32}"

# ---------------------------------------------------------------------------
# 4b. The OUTPUT pin — the check the input hashes cannot make.
#
#     The rasteriser is libfreetype, which is a container package rather than an
#     archive-pinned one. Measured 2026-08-25: 41 of 409 glyphs differ between
#     libfreetype 2.13.2 and 2.14.2 from the same TTF through this same script.
#     So a rebuilt container is enough to change the console while the version
#     number, the .deb hash and the TTF hash all stay put.
#
#     Coverage checks cannot see it — every glyph is present and non-blank in
#     both. Only the bytes can, which is this repo's habit applied one layer
#     down: assert the artefact, not the inputs that were supposed to determine
#     it.
#
#     Architecture is not a factor: arm64 and amd64 containers on one
#     libfreetype produce byte-identical PSFs.
# ---------------------------------------------------------------------------
echo ">>> Verifying the rasterisation is the pinned one"
FT_VER="$(python3 -c 'import freetype; print(".".join(str(v) for v in freetype.version()))')"
psf_drift=0
for pair in "${PSF_8x16}:${OS7_CASCADIA_PSF_SHA256_8x16}" \
            "${PSF_16x32}:${OS7_CASCADIA_PSF_SHA256_16x32}"; do
	f="${pair%%:*}"; want="${pair##*:}"
	got="$(sha256sum "${WORK}/${f}" | cut -d' ' -f1)"
	if [[ "${got}" != "${want}" ]]; then
		echo "!!! ${f} is not the pinned rasterisation." >&2
		echo "!!!   expected ${want}" >&2
		echo "!!!   got      ${got}" >&2
		psf_drift=1
	else
		echo "    ${f}  sha256 ok"
	fi
done
if [[ "${psf_drift}" -ne 0 ]]; then
	echo "!!!" >&2
	echo "!!! The font and the script are pinned, so the renderer moved:" >&2
	echo "!!!   libfreetype in this container is ${FT_VER}" >&2
	echo "!!! This changes what every console looks like without changing any" >&2
	echo "!!! version number. Look at the glyphs before accepting it - if the" >&2
	echo "!!! hinting improved, update OS7_CASCADIA_PSF_SHA256_* deliberately" >&2
	echo "!!! and say so in the commit; if it got worse, hold the container." >&2
	exit 1
fi
echo "    libfreetype ${FT_VER}"

# ---------------------------------------------------------------------------
# 5. Install: the PSFs, gzipped, plus the licence.
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
for f in "${PSF_8x16}" "${PSF_16x32}"; do
	gzip -9nc "${WORK}/${f}" > "${OUT_DIR}/${f}.gz"
	echo "    ${OUT_DIR}/${f}.gz  ($(stat -c %s "${OUT_DIR}/${f}.gz") bytes)"
done
cp "${WORK}/${PSF_8x16}" "${OUT_DIR}/${PSF_8x16}"

# The licence is an obligation, so it is copied out of the package that carries
# it rather than transcribed — a transcribed licence is a licence that can drift
# from the font it covers.
LIC_SRC="${WORK}/deb/usr/share/doc/${OS7_CASCADIA_PACKAGE}/copyright"
if [[ ! -s "${LIC_SRC}" ]]; then
	echo "!!! ${OS7_CASCADIA_PACKAGE} carries no copyright file — cannot ship" >&2
	echo "!!! the font without it (OFL 1.1 section 2, SETUP-PLAN L29)." >&2
	exit 1
fi
LIC_DIR="${OUT_DIR}/../doc/os7-console-font"
mkdir -p "${LIC_DIR}"
cp "${LIC_SRC}" "${LIC_DIR}/${LICENCE_NAME}"
echo "    $(cd "${LIC_DIR}" && pwd)/${LICENCE_NAME}  ($(stat -c %s "${LIC_DIR}/${LICENCE_NAME}") bytes)"

# L29's other half, asserted rather than remembered: the PSF must not carry the
# reserved font name. This is a naming rule with no runtime symptom, so nothing
# else would ever catch a rename.
for f in "${OUT_DIR}/${PSF_8x16}" "${OUT_DIR}/${PSF_8x16}.gz" "${OUT_DIR}/${PSF_16x32}.gz"; do
	base="$(basename "${f}")"
	if [[ "${base}" == *cascadia* || "${base}" == *Cascadia* ]]; then
		echo "!!! ${base} carries the OFL Reserved Font Name 'Cascadia Code'." >&2
		echo "!!! A PSF is a Modified Version under OFL 1.1 and may not use it." >&2
		exit 1
	fi
done

echo ">>> Installed console font done"
