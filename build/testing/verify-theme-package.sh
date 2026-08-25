#!/bin/bash
# =============================================================================
# OS/7 — build the desktop theme package and interrogate it, without an ISO.
#
#   docker run --rm --platform linux/arm64 -v "$PWD":/work -w /work \
#       os7-build:arm64 bash build/testing/verify-theme-package.sh
#
# It must be the OS/7 build image, not a bare ubuntu:26.04: the snapshot
# service is HTTPS-only and a bare Ubuntu image ships no ca-certificates, so
# apt cannot fetch the package that would fix apt.
#
# WHAT THIS PROVES AND WHAT IT DOES NOT.
#
#   Proves: the package builds from a clean tree; the fonts extract and carry
#   the family name the theme selects by; the dconf keyfile actually compiles
#   and the compiled database holds the values; GTK's own CSS parser accepts
#   the stylesheet; fontconfig resolves Tahoma to Tahoma.
#
#   Does NOT prove: that a GNOME session looks right. That needs a booted
#   amd64 image and a screenshot, and it is a separate measurement.
#
# It runs on arm64 deliberately: the package is Architecture: all and CSS is
# architecture-independent, so this measurement does not need the amd64 image
# that cannot be built on Apple Silicon (BUILD-NOTES #12/#23).
#
# Everything installs from the PINNED snapshot, so this test sees the same
# GTK and dconf the image will.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CONF="${ROOT}/build/config/os7-release.conf"

# shellcheck disable=SC1090
source "${CONF}"

: "${OS7_VERSION:=0.0.0.0-test}"
export OS7_VERSION

echo "=========================================================================="
echo "OS/7 theme package verification"
echo "  version   ${OS7_VERSION}"
echo "  archive   ${OS7_ARCHIVE_BASE}/${OS7_ARCHIVE_SNAPSHOT}"
echo "=========================================================================="

# --- 0. The pinned archive, and only it ---------------------------------
SNAP="${OS7_ARCHIVE_BASE}/${OS7_ARCHIVE_SNAPSHOT}"
cat > /etc/apt/sources.list.d/ubuntu.sources <<SOURCES
Types: deb
URIs: ${SNAP}
Suites: ${OS7_DISTRIBUTION} ${OS7_DISTRIBUTION}-updates ${OS7_DISTRIBUTION}-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
rm -f /etc/apt/sources.list

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	dpkg-dev fontconfig dconf-cli curl ca-certificates python3 \
	python3-gi gir1.2-gtk-3.0 libgtk-3-0t64 \
	`# gsettings itself - the schema check in 3b is the whole point` \
	libglib2.0-bin >/dev/null

# The GSettings schemas 3b checks against, installed HERE and not down there.
# After step 2's `dpkg -i --force-depends` the dpkg state has unmet
# dependencies and apt refuses to install anything else until they are
# resolved - so a schema install placed after it silently does nothing, and 3b
# then verifies zero keys. Measured: all five packages failed that way.
#
# One at a time, because a single name that does not exist would otherwise take
# the whole transaction down and leave the check with nothing.
SCHEMA_PKGS_OK=0
for pkg in gsettings-desktop-schemas gnome-shell-common mutter-common \
	nautilus-data gnome-shell-extension-user-theme
do
	if apt-get install -y -qq --no-install-recommends "${pkg}" >/dev/null 2>&1; then
		echo "    schemas: ${pkg}"
		SCHEMA_PKGS_OK=$((SCHEMA_PKGS_OK + 1))
	else
		echo "    schemas: (no ${pkg} - its keys cannot be checked here)"
	fi
done
glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
echo "    schemas: ${SCHEMA_PKGS_OK} package(s) available for the schema check"

# --- 1. Build ------------------------------------------------------------
echo
echo ">>> 1. Build the package"
OUT=/tmp/pkgs
rm -rf "${OUT}"
"${ROOT}/build/lib/build-desktop-theme.sh" "${CONF}" "${OUT}"
DEB="$(ls "${OUT}"/os7-desktop-theme_*.deb)"

# --- 2. Install ----------------------------------------------------------
# --force-depends because the GNOME Shell extensions this package depends on
# would drag in the whole desktop, and none of them is what is under test here.
# The dependency itself is exercised by the real image build.
echo
echo ">>> 2. Install it"
dpkg -i --force-depends "${DEB}"

# --- 3. Did the defaults actually compile? ------------------------------
# `dconf update` ran in postinst. postinst already refuses a database that did
# not carry the theme name, so reaching this point is itself a result. Read the
# rest back out of the BINARY database, which is what a session consults.
echo
echo ">>> 3. Read the defaults back out of the compiled dconf database"
export DCONF_PROFILE=/etc/dconf/profile/user
fail=0
check() {
	got="$(dconf read "$1" 2>/dev/null || true)"
	if [ "${got}" = "$2" ]; then
		printf '    ok   %-58s %s\n' "$1" "${got}"
	else
		printf '    FAIL %-58s got %s, want %s\n' "$1" "${got:-<unset>}" "$2"
		fail=1
	fi
}
check /org/gnome/desktop/interface/gtk-theme          "'OS7-Classic'"
check /org/gnome/desktop/interface/font-name          "'Tahoma 9'"
check /org/gnome/desktop/interface/enable-animations  "false"
check /org/gnome/desktop/background/primary-color     "'#000000'"
check /org/gnome/desktop/background/picture-uri       "''"
check /org/gnome/desktop/wm/preferences/button-layout "':minimize,maximize,close'"
check /org/gnome/desktop/wm/preferences/titlebar-font "'Tahoma Bold 9'"
check /org/gnome/shell/extensions/user-theme/name     "'OS7-Classic'"

# --- 3b. Is every default a setting GNOME actually HAS? -----------------
# BUILD-NOTES #54, and the check that matters most here.
#
# The first version of this block read our own keys back out of our own
# database and called that verification. It is not: dconf stores anything you
# give it, so a misspelled group or key round-trips perfectly and both sides of
# the comparison come from the same file. It proves the keyfile agrees with
# itself while GNOME quietly uses the default.
#
# GSettings is the independent authority, because GSettings is what reads these
# values at login and it knows which schemas and keys exist.
echo
echo ">>> 3b. Every default names a schema and key GNOME has"

python3 - <<'PYEOF'
import subprocess
import sys

KEYFILE = "/etc/dconf/db/os7.d/00-os7-classic"


def lines(args):
    done = subprocess.run(args, capture_output=True, text=True)
    return done.stdout.split() if done.returncode == 0 else []


pairs, group = [], None
for raw in open(KEYFILE):
    line = raw.strip()
    if line.startswith("[") and line.endswith("]"):
        group = line[1:-1].strip("/").replace("/", ".")
    elif group and line and not line.startswith("#") and "=" in line:
        pairs.append((group, line.split("=", 1)[0].strip()))

schemas = set(lines(["gsettings", "list-schemas"]))
keys, present, absent, unavailable = {}, 0, [], {}

for schema, key in pairs:
    if schema not in schemas:
        # Not installable here without pulling in the whole desktop. NOT a
        # pass - hook 0090 checks these inside the image, where they exist.
        unavailable.setdefault(schema, 0)
        unavailable[schema] += 1
        continue
    if schema not in keys:
        keys[schema] = set(lines(["gsettings", "list-keys", schema]))
    if key in keys[schema]:
        present += 1
    else:
        absent.append(f"{schema} has no key '{key}'")

status = "ok  " if present else "FAIL"
print(f"    {status} {present} of {len(pairs)} defaults verified against installed schemas")
for message in absent:
    print(f"    FAIL {message}")
if unavailable:
    total = sum(unavailable.values())
    print(f"    NOT CHECKED HERE: {total} default(s) in {len(unavailable)} schema(s):")
    for schema in sorted(unavailable):
        print(f"         {schema}")
    print("         These need gnome-shell or its extensions. Hook 0090 checks")
    print("         them in the image, where they are installed.")

# Verifying NOTHING is not a pass. If no schema was installable, this check did
# not run, and a run that checked zero things must not report success — that is
# the same silence the check was written to catch.
if not present:
    print("    FAIL this check verified nothing at all; treat it as not run", file=sys.stderr)
sys.exit(1 if (absent or not present) else 0)
PYEOF
[ $? -eq 0 ] || fail=1

# --- 4. Does GTK accept the stylesheet? ---------------------------------
# GTK's own parser is the only authority on this. A CSS file with a syntax
# error still "installs" perfectly.
echo
echo ">>> 4. GTK 3 parses the stylesheet"
python3 - <<'PYEOF'
import gi, sys
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gio

errors = []
def on_error(provider, section, error):
    start = section.get_start_location().lines + 1
    errors.append(f"line {start}: {error.message}")

for path in ("/usr/share/themes/OS7-Classic/gtk-3.0/gtk.css",
             "/usr/share/os7-theme/gtk-4.0/os7-classic.css"):
    provider = Gtk.CssProvider()
    provider.connect("parsing-error", on_error)
    before = len(errors)
    try:
        provider.load_from_file(Gio.File.new_for_path(path))
    except Exception as exc:                       # noqa: BLE001
        errors.append(f"{path}: {exc}")
    found = len(errors) - before
    print(f"    {'ok  ' if found == 0 else 'FAIL'} {path}: {found} parse error(s)")

for message in errors:
    print(f"         {message}")
sys.exit(1 if errors else 0)
PYEOF
[ $? -eq 0 ] || fail=1

# --- 5. Does the UI font resolve to itself? -----------------------------
# The theme asks for 'Tahoma'. fontconfig substitutes silently when it cannot
# find a family, so this is the only question that catches a wrong font.
echo
echo ">>> 5. fontconfig resolves the UI font"
fc-cache -f >/dev/null 2>&1 || true
for want in "Tahoma:Regular" "Tahoma:Bold"; do
	family="${want%%:*}"
	style="${want##*:}"
	got="$(fc-match -f '%{family}|%{style}|%{file}' "${family}:style=${style}")"
	if [ "${got%%|*}" = "${family}" ]; then
		printf '    ok   %-16s -> %s\n' "${want}" "${got}"
	else
		printf '    FAIL %-16s -> %s (substituted)\n' "${want}" "${got}"
		fail=1
	fi
done

# --- 6. Does it own only its own files? ---------------------------------
# The whole upgrade-durability argument rests on this. If the package ships a
# path another package owns, a distribution upgrade is a conffile conflict.
echo
echo ">>> 6. No file belongs to another package"
conflict=0
while read -r path; do
	owner="$(dpkg -S "${path}" 2>/dev/null | grep -v '^os7-desktop-theme' || true)"
	if [ -n "${owner}" ]; then
		echo "    FAIL ${path} also claimed by: ${owner}"
		conflict=1
	fi
done < <(dpkg -L os7-desktop-theme | grep -E '^/(usr|etc)/.*\.[a-z]+$' || true)
if [ "${conflict}" -eq 0 ]; then
	echo "    ok   every shipped file is owned by os7-desktop-theme alone"
else
	fail=1
fi

echo
echo "=========================================================================="
if [ "${fail}" -ne 0 ]; then
	echo "RESULT: FAILED"
	exit 1
fi
echo "RESULT: all checks passed"
echo "=========================================================================="
