#!/bin/bash
# =============================================================================
# OS/7 — render the classic theme and read the pixels back.
#
#   docker run --rm --platform linux/arm64 -v "$PWD":/work -w /work \
#       os7-build:arm64 bash build/testing/render-theme.sh [OUTDIR]
#
# WHAT THIS PROVES AND WHAT IT DOES NOT.
#
#   Proves: GTK 3 applies the theme, and the colours that come out of the
#   renderer are the Windows 2000 constants the theme asked for. The check is
#   on PIXELS from GTK's own drawing, not on the CSS that was fed to it.
#
#   Does NOT prove: the GNOME Shell half. The panel, the window list along the
#   bottom edge and the black desktop are drawn by gnome-shell, which needs a
#   session, not an X server with one application in it. That measurement needs
#   a booted amd64 image and does not exist yet — see
#   docs/SESSION-CLASSIC-DESKTOP.md §7.
#
# Runs on arm64 because GTK renders the same colours on both, and the amd64
# image cannot be built on Apple Silicon (BUILD-NOTES #12/#23).
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
CONF="${ROOT}/build/config/os7-release.conf"
OUTDIR="${1:-${ROOT}/out/theme}"

# shellcheck disable=SC1090
source "${CONF}"
: "${OS7_VERSION:=0.0.0.0-render}"
export OS7_VERSION

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
echo ">>> Installing GTK, an X server and a test application"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
	xvfb x11-utils imagemagick dbus-x11 fontconfig dconf-cli libglib2.0-bin \
	gtk-3-examples libgtk-3-0t64 gsettings-desktop-schemas \
	python3 python3-gi gir1.2-gtk-3.0 >/dev/null

echo ">>> Building and installing the theme"
rm -rf /tmp/pkgs
"${ROOT}/build/lib/build-desktop-theme.sh" "${CONF}" /tmp/pkgs >/dev/null
dpkg -i --force-depends /tmp/pkgs/os7-desktop-theme_*.deb >/dev/null 2>&1
fc-cache -f >/dev/null 2>&1

mkdir -p "${OUTDIR}"

# The theme is selected through GTK_THEME rather than through gsettings: this
# X server has no settings daemon to read the dconf database, and what is under
# test is the stylesheet, not the delivery mechanism. The dconf side is
# verified separately by verify-theme-package.sh and hook 0090.
# The UI font comes from the dconf database on a real system, and there is no
# settings daemon here to read it. Set it the way GTK reads it without one, so
# the render shows the font the theme actually asks for rather than the
# fallback — the difference between "authentic" and "unreadable" is exactly
# what a render is for.
mkdir -p /root/.config/gtk-3.0
cat > /root/.config/gtk-3.0/settings.ini <<'SETTINGS'
[Settings]
gtk-font-name = Tahoma 9
gtk-xft-antialias = 0
gtk-xft-hinting = 1
gtk-xft-hintstyle = hintfull
gtk-enable-animations = 0
gtk-decoration-layout = :minimize,maximize,close
SETTINGS

render() {
	local name="$1" theme="$2"
	echo ">>> Rendering ${name} (GTK_THEME=${theme})"
	rm -f /tmp/x.pid
	Xvfb :99 -screen 0 1024x768x24 >/dev/null 2>&1 &
	local xvfb=$!
	sleep 2
	DISPLAY=:99 GTK_THEME="${theme}" dbus-run-session -- \
		gtk3-widget-factory >/dev/null 2>&1 &
	local app=$!
	sleep 5
	DISPLAY=:99 import -window root "${OUTDIR}/${name}.png"
	kill "${app}" 2>/dev/null || true
	kill "${xvfb}" 2>/dev/null || true
	wait "${xvfb}" 2>/dev/null || true
	echo "    wrote ${OUTDIR}/${name}.png"
}

render "os7-classic" "OS7-Classic"
render "stock-adwaita" "Adwaita"

# ---------------------------------------------------------------------------
# Read the pixels back.
#
# THE EXPECTED VALUES ARE WRITTEN HERE, NOT READ FROM THE THEME. A check that
# takes its expectations from the file it is checking proves only that the file
# agrees with itself — BUILD-NOTES #54 is this session's own example of getting
# that wrong.
# ---------------------------------------------------------------------------
echo
echo ">>> Reading the rendered pixels back"
python3 - "${OUTDIR}/os7-classic.png" "${OUTDIR}/stock-adwaita.png" <<'PYEOF'
import subprocess
import sys
from collections import Counter

# Windows 2000 "Windows Standard", typed out here on purpose.
FACE = (0xD4, 0xD0, 0xC8)
CAPTION = (0x0A, 0x24, 0x6A)
CAPTION_END = (0xA6, 0xCA, 0xF0)
WHITE = (0xFF, 0xFF, 0xFF)


def pixels(path):
    """Every pixel as (r, g, b), via ImageMagick's raw text format."""
    out = subprocess.run(["convert", path, "-depth", "8", "txt:-"],
                         capture_output=True, text=True, check=True).stdout
    found = Counter()
    for line in out.splitlines()[1:]:
        if "#" not in line:
            continue
        hexpart = line.split("#", 1)[1][:6]
        found[(int(hexpart[0:2], 16), int(hexpart[2:4], 16), int(hexpart[4:6], 16))] += 1
    return found


def near(a, b, tol=2):
    return all(abs(x - y) <= tol for x, y in zip(a, b))


classic = pixels(sys.argv[1])
stock = pixels(sys.argv[2])
total = sum(classic.values())
print(f"    {total} pixels, {len(classic)} distinct colours in the classic render")

failures = []


def require(name, colour, minimum_pct):
    count = sum(n for c, n in classic.items() if near(c, colour))
    pct = 100.0 * count / total
    verdict = "ok  " if pct >= minimum_pct else "FAIL"
    if pct < minimum_pct:
        failures.append(f"{name}: {pct:.2f}% < {minimum_pct}%")
    print(f"    {verdict} {name:<28} #{colour[0]:02x}{colour[1]:02x}{colour[2]:02x}"
          f"  {count:>7} px  {pct:5.2f}%")
    return pct


# The 3D face is the dominant colour of a classic dialog.
require("3D face (windows, buttons)", FACE, 20.0)
require("caption gradient start", CAPTION, 0.05)
# Bevel highlights are one pixel wide but everywhere.
require("3D highlight / window base", WHITE, 2.0)


def gradient_reach():
    """How far along CAPTION -> CAPTION_END does the rendered gradient get?

    Requiring the exact end colour was the first version of this check and it
    failed at 0.00%: the right-hand end of the caption bar is covered by the
    window buttons, so the last stop is never painted. What the theme actually
    claims is a GRADIENT, so that is what gets measured — how many distinct
    steps along the line appear, and how far the brightest one reaches.
    """
    delta = [e - s for s, e in zip(CAPTION, CAPTION_END)]
    steps, furthest = set(), 0.0
    for colour, _count in classic.items():
        # Project onto the line, then check the point actually lies on it.
        ts = [(c - s) / d for c, s, d in zip(colour, CAPTION, delta) if d]
        if not ts:
            continue
        t = sum(ts) / len(ts)
        if not 0.0 <= t <= 1.0:
            continue
        want = tuple(round(s + t * d) for s, d in zip(CAPTION, delta))
        if near(colour, want, 3):
            steps.add(round(t, 2))
            furthest = max(furthest, t)
    return steps, furthest


steps, furthest = gradient_reach()
verdict = "ok  " if (len(steps) >= 15 and furthest >= 0.5) else "FAIL"
if verdict == "FAIL":
    failures.append(f"caption gradient: {len(steps)} steps, reaches t={furthest:.2f}")
print(f"    {verdict} caption gradient             {len(steps):>3} distinct steps, "
      f"reaches {furthest * 100:.0f}% of the way to #a6caf0")

# The comparison that makes the numbers mean something: stock Adwaita must NOT
# be full of these colours. Without this, a renderer that failed to apply any
# theme could still pass by accident on a grey default.
face_stock = 100.0 * sum(n for c, n in stock.items() if near(c, FACE)) / sum(stock.values())
cap_stock = 100.0 * sum(n for c, n in stock.items() if near(c, CAPTION)) / sum(stock.values())
print(f"    ---- same measurements against stock Adwaita ----")
print(f"         3D face                      {face_stock:5.2f}%")
print(f"         caption gradient start       {cap_stock:5.2f}%")
if face_stock > 1.0:
    failures.append(f"stock Adwaita is also {face_stock:.2f}% #d4d0c8 - the "
                    "measurement does not distinguish the themes")

if failures:
    print()
    for message in failures:
        print(f"    FAIL {message}")
    sys.exit(1)
print("    ok   the classic palette is present and stock Adwaita is not")
PYEOF

echo
echo "=========================================================================="
echo "RESULT: the GTK half of the theme renders in the Windows 2000 palette."
echo "The GNOME Shell half - panel, window list, black desktop - is NOT covered"
echo "by this test and remains unmeasured."
echo "=========================================================================="
