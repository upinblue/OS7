#!/usr/bin/env bash
#
# ---------------------------------------------------------------------------
# HARVESTED VERBATIM from the prior OS/7 build session (2026-06-24), whose
# repository history was replaced by the current scaffold. Kept because it
# encodes hard-won, non-obvious work that would otherwise have to be
# rediscovered from scratch.
#
# NOT re-validated against this scaffold. Treat as reference-grade, not
# known-good. See docs/BUILD-NOTES.md.
# ---------------------------------------------------------------------------
#
# Inject a GRUB EFI bootloader into the live-build binary/ tree and re-master a
# bootable UEFI ISO for arm64.
#
# WHY THIS EXISTS: Debian live-build does NOT produce an arm64 bootloader — its
# grub steps (lb_binary_grub2) are gated to "amd64 i386" only. So on arm64 the
# tool assembles a complete live filesystem (binary/casper/{vmlinuz,initrd.img,
# filesystem.squashfs}) but leaves the ISO unbootable (no /EFI, empty El Torito
# catalog). This script fills that gap with the GRUB tooling already in the build
# container (grub-mkstandalone + /usr/lib/grub/arm64-efi, mtools, mkfs.vfat,
# xorriso).
#
# Usage: arm64-efi-remaster.sh <work_dir> <out_iso>
#   <work_dir> contains the live-build "binary/" tree (after `lb build`).
#
# NOTE: this produces a STRUCTURALLY bootable UEFI ISO (EFI El Torito entry +
# appended EF-type partition + /EFI/BOOT/BOOTAA64.EFI). Real-hardware/QEMU UEFI
# boot verification is still an open handoff item (see HANDOFF.md).
set -euo pipefail

WORK="${1:?work dir required}"
OUT_ISO="${2:?output iso path required}"
BIN="${WORK}/binary"

cd "${WORK}"

[ -d "${BIN}/casper" ] || { echo "!!! ${BIN}/casper missing — live-build did not produce a live tree" >&2; exit 1; }

# Resolve the kernel/initrd basenames live-build placed under /casper.
VMLINUZ="$(cd "${BIN}/casper" && ls -1 vmlinuz* | head -n1)"
INITRD="$(cd "${BIN}/casper" && ls -1 initrd.img* initrd* 2>/dev/null | head -n1)"
[ -n "${VMLINUZ}" ] && [ -n "${INITRD}" ] || { echo "!!! kernel/initrd not found under ${BIN}/casper" >&2; exit 1; }
echo ">>> arm64 EFI: kernel=${VMLINUZ} initrd=${INITRD}"

# The on-disk GRUB menu the firmware will load. Uses /.disk/info (always present
# on a live-build ISO) to locate the media regardless of device naming.
#
# SETUP-PLAN §7: Install is the default entry, and the live entry stays, because
# booting straight into Setup would lose "try before you install" (L14).
#
# The Install entry's command line is SHORTER than §7 originally proposed, and
# spike S1 is why. `vt.default_red/grn/blu` is replaced by Ubuntu's enabled
# setvtrgb.service before the console is ever displayed, and `vt.color=0x4f` has
# no observable effect on the default attribute at all - so both were removed
# and Setup applies its palette itself from /usr/share/os7. BUILD-NOTES #25.
#
# What is left earns its place:
#   systemd.wants=...      what actually starts Setup; the unit has no [Install]
#   os7.setup=1            os7-setup.service's ConditionKernelCommandLine, as a belt
#   fbcon=font:TER16x32    the closest built-in match until setfont runs (L20)
#   fbcon=nodefer          the framebuffer console exists from the start
#   plymouth.enable=0      nothing scrolls over the field
#   quiet loglevel=0       nor does the kernel
#
# `nodefer` is not a tuning flag. By default fbcon DEFERS taking the console
# over and completes the takeover only when something writes to it, so tty1
# stays the kernel's dummy device - on which KDFONTOP returns ENOSYS, so no font
# can be loaded and no palette applies. Setup recovers from that on its own
# (BUILD-NOTES #31), but recovering from a race is worse than not having one.
mkdir -p "${BIN}/boot/grub"
cat > "${BIN}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=10
insmod all_video
menuentry "Install OS/7 (arm64)" {
    search --no-floppy --set=root --file /.disk/info
    linux  /casper/${VMLINUZ} boot=casper os7.setup=1 systemd.wants=os7-setup.service fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 ---
    initrd /casper/${INITRD}
}
menuentry "OS/7 (arm64) — live session, without installing" {
    search --no-floppy --set=root --file /.disk/info
    linux  /casper/${VMLINUZ} boot=casper quiet splash ---
    initrd /casper/${INITRD}
}
menuentry "OS/7 (arm64) — live session (safe graphics)" {
    search --no-floppy --set=root --file /.disk/info
    linux  /casper/${VMLINUZ} boot=casper nomodeset ---
    initrd /casper/${INITRD}
}
EOF

# Standalone EFI image. Its embedded /boot/grub/grub.cfg just finds the media and
# hands off to the real menu above.
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
cat > "${TMP}/embed.cfg" <<'EOF'
search --no-floppy --set=root --file /.disk/info
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

grub-mkstandalone \
    --format=arm64-efi \
    --output="${TMP}/bootaa64.efi" \
    --modules="part_gpt part_msdos fat iso9660 normal linux configfile search search_fs_file echo all_video gfxterm test true" \
    "boot/grub/grub.cfg=${TMP}/embed.cfg"

# Expose the loader on the ISO9660 side too (some firmwares look here).
mkdir -p "${BIN}/EFI/BOOT"
cp "${TMP}/bootaa64.efi" "${BIN}/EFI/BOOT/BOOTAA64.EFI"

# FAT EF-system-partition image holding the same loader — this is what the EFI
# El Torito entry points at, and what makes a USB dd of the ISO bootable.
EFIIMG="${BIN}/boot/grub/efiboot.img"
rm -f "${EFIIMG}"
# Size the FAT image to comfortably hold the standalone EFI binary (which embeds
# a GRUB memdisk and can be several MB). 24 MiB is generous and cheap.
mkfs.vfat -C "${EFIIMG}" 24576 >/dev/null
mmd   -i "${EFIIMG}" ::EFI ::EFI/BOOT
mcopy -i "${EFIIMG}" "${TMP}/bootaa64.efi" ::EFI/BOOT/BOOTAA64.EFI

echo ">>> arm64 EFI: re-mastering bootable ISO -> ${OUT_ISO}"
rm -f "${OUT_ISO}"
xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames \
    -volid "OS7-arm64" \
    -J -joliet-long -rational-rock \
    -e boot/grub/efiboot.img -no-emul-boot \
    -append_partition 2 0xef "${EFIIMG}" \
    -partition_cyl_align all \
    -o "${OUT_ISO}" \
    "${BIN}"
