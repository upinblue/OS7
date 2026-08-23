#!/usr/bin/env bash
# =============================================================================
# Host-side harness for spike S2 (installer/spikes/s2-nativeaot.sh).
#
#   ./run-s2.sh build [arch]   publish the NativeAOT binary in os7-build:<arch>
#   ./run-s2.sh iso  [arch]    run that binary inside the ISO's own root
#   ./run-s2.sh all  [arch]    both, in order              (default, arm64)
#
# SETUP-PLAN §10 S2 is done when there are "two static binaries that run in the
# ISO". `build` answers the first half, `iso` the second — and they are separate
# because the build container is ubuntu:26.04 while the ISO is a live-build
# image with its own package set, and "it ran where it was compiled" is not the
# claim being made.
#
# No VM here: S2 needs no boot. `iso` overlays a tmpfs on the read-only squashfs
# and chroots into it, so the binary meets the image's real glibc and its real
# (absent or present) ICU, in seconds rather than minutes.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WHAT="${1:-all}"
ARCH="${2:-arm64}"

case "$ARCH" in
    arm64|amd64) ;;
    *) echo "unknown arch: $ARCH (expected arm64 or amd64)" >&2; exit 1 ;;
esac

ISO="$REPO/out/os7-$ARCH.iso"
BIN="$REPO/out/s2/$ARCH/os7-s2"

step() { printf '\n### %s\n' "$*"; }

build() {
    step "build — NativeAOT publish in os7-build:$ARCH"
    docker image inspect "os7-build:$ARCH" >/dev/null 2>&1 \
        || { echo "os7-build:$ARCH missing. Build it with: make image-$ARCH" >&2; exit 1; }
    # Not privileged and no --platform surprises: this is a plain compile, and
    # the container is already architecture-matched (Dockerfile, harvested fix 1).
    docker run --rm --platform "linux/$ARCH" \
        -v "$REPO":/work \
        "os7-build:$ARCH" bash /work/installer/spikes/s2-nativeaot.sh
}

iso() {
    step "iso — run the binary inside the ISO's own root"
    [ -f "$BIN" ] || { echo "$BIN not found. Run: ./run-s2.sh build $ARCH" >&2; exit 1; }
    [ -f "$ISO" ] || { echo "$ISO not found. Build it with: make build-$ARCH" >&2; exit 1; }

    # Privileged: loop mounts and overlayfs. The squashfs stays read-only; the
    # overlay's upper layer is a tmpfs, so nothing here can modify the image.
    # -i, and deliberately not -it: the script arrives on stdin, and BUILD-NOTES
    # #8 is about -t failing where there is no TTY. -i alone is safe headless.
    docker run --rm -i --privileged --platform "linux/$ARCH" \
        -v "$REPO/out":/host-out:ro \
        -e OS7_ARCH="$ARCH" \
        "os7-build:$ARCH" bash -euo pipefail -s <<'INNER'
mkdir -p /mnt/iso /mnt/sq /ovl /mnt/root
mount -o loop,ro "/host-out/os7-${OS7_ARCH}.iso" /mnt/iso
mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq
mount -t tmpfs tmpfs /ovl
mkdir -p /ovl/upper /ovl/work
mount -t overlay overlay \
    -o lowerdir=/mnt/sq,upperdir=/ovl/upper,workdir=/ovl/work /mnt/root

cp "/host-out/s2/${OS7_ARCH}/os7-s2" /mnt/root/tmp/os7-s2
chmod +x /mnt/root/tmp/os7-s2

echo "    image    $(sed -n 1p /mnt/root/etc/os-release)"
echo "    glibc    $(chroot /mnt/root /usr/bin/ldd --version | head -1)"

mount -t proc  proc /mnt/root/proc
mount -t sysfs sys  /mnt/root/sys
mount --rbind  /dev /mnt/root/dev

echo
echo "--- as the image ships ---"
chroot /mnt/root /tmp/os7-s2

# The ISO DOES carry dotnet-sdk-10.0 — it is in the base package list — so
# running it here proves nothing about runtime independence on its own. Take
# the runtime away and run again. The overlay's upper layer is a tmpfs, so the
# image itself is untouched.
echo
echo "--- with the .NET runtime removed from the image ---"
echo "    was at   $(chroot /mnt/root bash -c 'command -v dotnet' || echo '(absent)')"
rm -rf /mnt/root/usr/lib/dotnet /mnt/root/usr/bin/dotnet /mnt/root/usr/share/dotnet
if chroot /mnt/root bash -c 'command -v dotnet' >/dev/null 2>&1; then
    echo "    STILL THERE — the removal did not take"; exit 1
fi
echo "    gone     no dotnet anywhere on PATH, and no /usr/lib/dotnet"
chroot /mnt/root /tmp/os7-s2
INNER
}

case "$WHAT" in
    build) build ;;
    iso)   iso ;;
    all)   build; iso; printf '\nS2 (%s): PASS\n' "$ARCH" ;;
    *) sed -n '3,12p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
