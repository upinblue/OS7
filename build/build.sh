#!/usr/bin/env bash
# =============================================================================
# OS/7 — live-build orchestration.
#
#   Usage: build.sh <amd64|arm64|clean>
#
#   *** The OS/7 content this is supposed to build does not exist yet. ***
#
# The two things this script is careful about are HARVESTED FROM A PRIOR BUILD
# SESSION (2026-06-24). Both were discovered the hard way; neither is obvious
# from live-build's documentation. See docs/BUILD-NOTES.md.
#
# Runs inside the os7-build container (see Dockerfile / Makefile).
# =============================================================================

set -euo pipefail

ARCH="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_CONFIG="${HERE}/config"   # authored live-build config, on the bind mount
WORK="/os7-build"             # container-local build root (overlayfs)
OUT_DIR="/work/out"

usage() { echo "Usage: $0 <amd64|arm64|clean>" >&2; exit 2; }

clean() {
	rm -rf "${WORK}"
	# Clear host-side litter from any older in-place build.
	rm -rf "${SRC_CONFIG}/chroot" "${SRC_CONFIG}/cache" "${SRC_CONFIG}/config" \
	       "${SRC_CONFIG}/.build" "${SRC_CONFIG}/local" "${SRC_CONFIG}/binary" \
	       "${SRC_CONFIG}"/*.log "${SRC_CONFIG}"/*.iso
}

case "${ARCH}" in
	clean)       clean; exit 0 ;;
	amd64|arm64) ;;
	*)           usage ;;
esac

echo ">>> Building OS/7 for ${ARCH}"

# ---------------------------------------------------------------------------
# HARVESTED FIX 3: build in a CONTAINER-LOCAL directory, never under /work.
#
# On Docker Desktop for Mac the repo is bind-mounted over VirtioFS, and a Linux
# root filesystem cannot be faithfully extracted onto it (device nodes,
# ownership, hardlinks). debootstrap fails there with "tar failed" / a missing
# /usr/bin/env. The container's own overlayfs handles it correctly. Only the
# finished ISO is copied back to /work/out.
# ---------------------------------------------------------------------------
rm -rf "${WORK}"
mkdir -p "${WORK}/config"

# ---------------------------------------------------------------------------
# HARVESTED FIX 6: assemble the STANDARD live-build tree.
#
# live-build reads, relative to the build root:
#     auto/config
#     config/package-lists/  config/hooks/  config/includes.chroot/
#
# This repo authors them under build/config/ (per README "Repository layout"),
# so they must be re-mapped while staging. Get this wrong and live-build
# SILENTLY IGNORES all of them — the build "succeeds" and produces a bare
# Ubuntu image with no OS/7 content in it.
# ---------------------------------------------------------------------------
cp -a "${SRC_CONFIG}/auto" "${WORK}/auto"

for sub in package-lists hooks includes.chroot; do
	if [[ -d "${SRC_CONFIG}/${sub}" ]]; then
		cp -a "${SRC_CONFIG}/${sub}" "${WORK}/config/${sub}"
	else
		# STUB: none of these are authored yet. Expected, for now.
		echo "    (no ${sub}/ authored yet - skipping)"
	fi
done

# ---------------------------------------------------------------------------
# Stage the OS7 PowerShell module from its ONE source of truth (powershell/OS7)
# into the image, at a path already on PowerShell 7's default PSModulePath.
# Hook 0060 verifies it imports. Keeping a second copy checked in under
# includes.chroot - as the June-2026 tree did - just lets the two drift.
# ---------------------------------------------------------------------------
OS7_MODULE_SRC="${HERE}/../powershell/OS7"
OS7_MODULE_DST="${WORK}/config/includes.chroot/usr/local/share/powershell/Modules/OS7"
if [[ -d "${OS7_MODULE_SRC}" ]]; then
	mkdir -p "${OS7_MODULE_DST}"
	cp -a "${OS7_MODULE_SRC}/." "${OS7_MODULE_DST}/"
	echo "    staged OS7 PowerShell module -> ${OS7_MODULE_DST#${WORK}/}"
else
	echo "!!! OS7 module source missing: ${OS7_MODULE_SRC}" >&2
	exit 1
fi

cd "${WORK}"

export OS7_ARCH="${ARCH}"   # read by auto/config
lb config

echo ">>> Running live-build (needs network access to the Ubuntu archives)"
lb build 2>&1 | tee "${WORK}/build-${ARCH}.log"

mkdir -p "${OUT_DIR}"
DEST="${OUT_DIR}/os7-${ARCH}.iso"

if [[ "${ARCH}" = "arm64" ]]; then
	# HARVESTED FIX 7: live-build emits NO arm64 bootloader (lb_binary_grub2 is
	# gated to "amd64 i386"), so the arm64 ISO it produces has no /EFI and an
	# empty El-Torito catalog - a complete live filesystem that cannot boot.
	# Re-master it.
	"${HERE}/lib/arm64-efi-remaster.sh" "${WORK}" "${DEST}"
	echo ">>> Done: ${DEST}"
else
	ISO="$(ls -1 "${WORK}"/*.iso 2>/dev/null | head -n1 || true)"
	if [[ -n "${ISO}" ]]; then
		cp -f "${ISO}" "${DEST}"
		echo ">>> Done: ${DEST}"
	else
		echo "!!! No ISO produced - see ${WORK}/build-${ARCH}.log (in container)" >&2
		tail -n 40 "${WORK}/build-${ARCH}.log" >&2 || true
		exit 1
	fi
fi
