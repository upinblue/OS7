#!/bin/bash
# =============================================================================
# OS/7 — build the os7-desktop-theme .deb.
#
#   build-desktop-theme.sh <release-conf> <output-dir>
#
# Produces one architecture-independent package from
# build/packages/os7-desktop-theme/ and drops it in <output-dir>, which
# build.sh points at config/packages.chroot-amd64/ so live-build installs it
# into the image.
#
# WHY A PACKAGE AND NOT includes.chroot. Files copied in by live-build belong
# to nobody: dpkg cannot list them, an update cannot replace them, and a
# conffile from a later Ubuntu silently overwrites them. A package owns its
# files, carries the release version, and can be removed. The theme is a
# product component with a version, not a pile of assets.
#
# THE FONTS. Windows 2000's UI font is Tahoma and it is not redistributable.
# Wine ships a metrically compatible replacement under LGPL-2.1+, which is. In
# the archive `fonts-wine` holds only symlinks; the real TTFs are inside
# `wine-common`, an 11 MB package whose name on a managed corporate desktop is
# a support question waiting to happen. So the two files are extracted here,
# from a .deb pinned by version AND hash in os7-release.conf — the same pattern
# hook 0020 uses for PowerShell.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../packages/os7-desktop-theme"

RELEASE_CONF="${1:-}"
OUT_DIR="${2:-}"

if [[ -z "${RELEASE_CONF}" || -z "${OUT_DIR}" ]]; then
	echo "usage: build-desktop-theme.sh <release-conf> <output-dir>" >&2
	exit 2
fi

if [[ ! -r "${RELEASE_CONF}" ]]; then
	echo "!!! release pin not readable: ${RELEASE_CONF}" >&2
	exit 1
fi
# shellcheck disable=SC1090
source "${RELEASE_CONF}"

# OS7_VERSION is computed by build.sh (its BUILD field comes from git) and
# exported. Refuse rather than invent one - trap #43's lesson, applied here.
if [[ -z "${OS7_VERSION:-}" ]]; then
	echo "!!! OS7_VERSION is not set. build.sh must export it." >&2
	echo "!!! A package version nobody chose is worse than a failed build." >&2
	exit 1
fi

for var in OS7_ARCHIVE_BASE OS7_ARCHIVE_SNAPSHOT OS7_CLASSICFONT_POOL OS7_CLASSICFONT_SHA256; do
	if [[ -z "${!var:-}" ]]; then
		echo "!!! ${var} missing from ${RELEASE_CONF}" >&2
		exit 1
	fi
done

echo ">>> Desktop theme: os7-desktop-theme ${OS7_VERSION}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
STAGE="${WORK}/pkg"

mkdir -p "${STAGE}"
cp -a "${SRC}/tree/." "${STAGE}/"

# ---------------------------------------------------------------------------
# The fonts.
# ---------------------------------------------------------------------------
FONT_DIR="${STAGE}/usr/share/fonts/truetype/os7-classic"
mkdir -p "${FONT_DIR}"

FONT_DEB="${WORK}/classicfonts.deb"
FONT_URL="${OS7_ARCHIVE_BASE}/${OS7_ARCHIVE_SNAPSHOT}/${OS7_CLASSICFONT_POOL}"

echo "    fetching ${OS7_CLASSICFONT_POOL}"
curl -fsSL --retry 3 -o "${FONT_DEB}" "${FONT_URL}"

GOT="$(sha256sum "${FONT_DEB}" | cut -d' ' -f1)"
if [[ "${GOT}" != "${OS7_CLASSICFONT_SHA256}" ]]; then
	echo "!!! font package hash mismatch" >&2
	echo "!!!   expected ${OS7_CLASSICFONT_SHA256}" >&2
	echo "!!!   got      ${GOT}" >&2
	echo "!!! Either the snapshot moved or the download was tampered with." >&2
	exit 1
fi
echo "    sha256 ok"

dpkg-deb -x "${FONT_DEB}" "${WORK}/fontdeb"

WINE_FONTS="${WORK}/fontdeb/usr/share/wine/fonts"
for face in tahoma.ttf tahomabd.ttf; do
	if [[ ! -s "${WINE_FONTS}/${face}" ]]; then
		echo "!!! ${face} not found in the font package at usr/share/wine/fonts/" >&2
		echo "!!! The upstream layout changed; fix the path here, not by skipping." >&2
		exit 1
	fi
	install -m 0644 "${WINE_FONTS}/${face}" "${FONT_DIR}/${face}"
done

# ASK THE FONT ITSELF what family it is. The theme selects 'Tahoma' by name and
# fontconfig substitutes silently when that name resolves to nothing.
python3 "${HERE}/ttf-family.py" verify --expect "Tahoma:Regular" "${FONT_DIR}/tahoma.ttf"
python3 "${HERE}/ttf-family.py" verify --expect "Tahoma:Bold"    "${FONT_DIR}/tahomabd.ttf"

# LGPL-2.1+ requires the notice to travel with the files.
install -d "${STAGE}/usr/share/doc/os7-desktop-theme"
if [[ -r "${WORK}/fontdeb/usr/share/doc/wine-common/copyright" ]]; then
	install -m 0644 "${WORK}/fontdeb/usr/share/doc/wine-common/copyright" \
		"${STAGE}/usr/share/doc/os7-desktop-theme/copyright.fonts"
else
	echo "!!! the font package carries no copyright file - refusing to ship its fonts" >&2
	exit 1
fi

cat > "${STAGE}/usr/share/fonts/truetype/os7-classic/README" <<'FONTREADME'
Tahoma and Tahoma Bold, metrically compatible replacements from the Wine
project, LGPL-2.1+, Copyright (c) 1993-2022 Wine project authors.

Extracted at build time from the wine-common package in the pinned Ubuntu
snapshot; see build/lib/build-desktop-theme.sh. The full notice is in
/usr/share/doc/os7-desktop-theme/copyright.fonts.

These are NOT Microsoft's Tahoma, which is not redistributable.
FONTREADME
chmod 0644 "${STAGE}/usr/share/fonts/truetype/os7-classic/README"

# ---------------------------------------------------------------------------
# Pre-enable the user unit by shipping the symlink, rather than by running
# `systemctl --global enable` from postinst. In a chroot systemctl can fail for
# reasons that have nothing to do with the theme, and a postinst that swallows
# that failure leaves a package that reports success and enabled nothing.
# A symlink is a file: dpkg installs it or the install fails.
# ---------------------------------------------------------------------------
install -d "${STAGE}/usr/lib/systemd/user/default.target.wants"
ln -sfn ../os7-theme-user-setup.service \
	"${STAGE}/usr/lib/systemd/user/default.target.wants/os7-theme-user-setup.service"

install -m 0644 "${SRC}/README.md" "${STAGE}/usr/share/doc/os7-desktop-theme/README.md"

# ---------------------------------------------------------------------------
# Control and maintainer scripts.
# ---------------------------------------------------------------------------
install -d "${STAGE}/DEBIAN"
sed "s|@OS7_VERSION@|${OS7_VERSION}|g" "${SRC}/control.in" > "${STAGE}/DEBIAN/control"
install -m 0755 "${SRC}/postinst" "${STAGE}/DEBIAN/postinst"
install -m 0755 "${SRC}/postrm"   "${STAGE}/DEBIAN/postrm"

if grep -q "@OS7_VERSION@" "${STAGE}/DEBIAN/control"; then
	echo "!!! control still contains @OS7_VERSION@ after substitution" >&2
	exit 1
fi

find "${STAGE}/usr" "${STAGE}/etc" -type d -exec chmod 0755 {} +
find "${STAGE}/usr" "${STAGE}/etc" -type f -exec chmod 0644 {} +
chmod 0755 "${STAGE}/usr/libexec/os7-theme-user-setup"

# ---------------------------------------------------------------------------
# Build, then interrogate the artefact. `dpkg-deb --build` exiting 0 says the
# archive was written; it says nothing about what is inside it.
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"
DEB="${OUT_DIR}/os7-desktop-theme_${OS7_VERSION}_all.deb"
dpkg-deb --build --root-owner-group "${STAGE}" "${DEB}" >/dev/null

MUST=(
	"./usr/share/themes/OS7-Classic/gtk-3.0/gtk.css"
	"./usr/share/themes/OS7-Classic/gnome-shell/gnome-shell.css"
	"./usr/share/themes/OS7-Classic/index.theme"
	"./usr/share/os7-theme/gtk-4.0/os7-classic.css"
	"./usr/share/fonts/truetype/os7-classic/tahoma.ttf"
	"./usr/share/fonts/truetype/os7-classic/tahomabd.ttf"
	"./usr/libexec/os7-theme-user-setup"
	"./usr/lib/systemd/user/os7-theme-user-setup.service"
	"./usr/lib/systemd/user/default.target.wants/os7-theme-user-setup.service"
	"./etc/dconf/db/os7.d/00-os7-classic"
	# THE LOGIN SCREEN, and it is listed here for the reason the whole list
	# exists: these three arrive by `cp -a tree/.` and nothing else would
	# notice a rename, a moved directory or a .gitignore swallowing them. The
	# greeter keyfile is the one that matters - without it the login screen
	# silently goes back to showing Ubuntu's logo, which is precisely the
	# failure this package was changed to fix. docs/BUILD-NOTES.md #110.
	"./usr/share/gdm/dconf/95-os7-login-screen"
	"./usr/share/pixmaps/os7-logo-login.svg"
	"./usr/share/pixmaps/upinblue-logo.svg"
)
CONTENTS="$(dpkg-deb -c "${DEB}")"
missing=0
for path in "${MUST[@]}"; do
	if ! grep -qF " ${path}" <<< "${CONTENTS}"; then
		echo "!!! built package is missing ${path}" >&2
		missing=1
	fi
done
if (( missing )); then
	echo "!!! refusing to ship an incomplete theme package" >&2
	exit 1
fi

BUILT_VERSION="$(dpkg-deb -f "${DEB}" Version)"
if [[ "${BUILT_VERSION}" != "${OS7_VERSION}" ]]; then
	echo "!!! package says version ${BUILT_VERSION}, build says ${OS7_VERSION}" >&2
	exit 1
fi

echo "    built ${DEB##*/} ($(stat -c%s "${DEB}") bytes), ${#MUST[@]} required paths present"
