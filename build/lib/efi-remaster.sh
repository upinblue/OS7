#!/usr/bin/env bash
#
# ---------------------------------------------------------------------------
# ONE remaster, both architectures. Grown out of arm64-efi-remaster.sh, which
# was HARVESTED VERBATIM from the prior OS/7 build session (2026-06-24) and
# carried the note "reference-grade, not known-good". The arm64 half is now
# known-good — every arm64 ISO since 2026-08-22 came out of it, and
# run-phase3.py boots what it produces. The amd64 half is new on 2026-08-25 and
# has exactly as much evidence behind it as its first green run.
#
# THE TWO ARCHITECTURES MUST NOT DRIFT. What this script writes is the GRUB
# menu of SETUP-PLAN §7 — the entries a person sees before OS/7 is installed.
# Two copies of that menu would disagree eventually, and the disagreement would
# be invisible until someone booted the other architecture.
# ---------------------------------------------------------------------------
#
# Inject a GRUB EFI bootloader into the live-build binary/ tree and re-master a
# bootable UEFI ISO.
#
# WHY THIS EXISTS, and it is now two reasons:
#
#   arm64 — live-build does NOT produce an arm64 bootloader at all; lb_binary_grub2
#           is gated to "amd64 i386". It assembles a complete live filesystem and
#           leaves the ISO unbootable: no /EFI, empty El Torito catalog.
#   amd64 — live-build's amd64 default IS a bootloader, and it is the wrong one.
#           LB_BOOTLOADER defaults to "syslinux", which is BIOS, while OS/7 boots
#           UEFI with shim and a Canonical-signed GRUB. Worse, the stage cannot
#           run: it asks a 2026 archive for syslinux-themes-ubuntu-oneiric, a
#           package from Ubuntu 11.10. So auto/config sets --bootloader none and
#           amd64 arrives here in exactly the state arm64 was always in.
#           BUILD-NOTES #47.
#
# Usage: efi-remaster.sh <arch> <work_dir> <out_iso>
#   <arch>     amd64 | arm64
#   <work_dir> contains the live-build "binary/" tree (after `lb build`).
#
# NOTE: this produces a STRUCTURALLY bootable UEFI ISO (EFI El Torito entry +
# appended EF-type partition + /EFI/BOOT/BOOT<ARCH>.EFI). The GRUB it embeds is
# built by grub-mkstandalone and is therefore UNSIGNED: the medium boots with
# Secure Boot OFF. That is a property of the MEDIUM only — what Setup installs
# to the disk is shim + Canonical-signed GRUB, which is what spikes S4 and S6
# proved. A Secure-Boot-bootable install medium is an open item, and it matters
# more on amd64, where firmware ships with Secure Boot enabled: see
# docs/SESSION-AMD64-FIRST-ISO.md.
set -euo pipefail

ARCH="${1:?arch required (amd64|arm64)}"
WORK="${2:?work dir required}"
OUT_ISO="${3:?output iso path required}"
BIN="${WORK}/binary"

# The only things that actually differ. Everything below this table is shared,
# and that is the point of the file.
case "${ARCH}" in
	arm64)
		GRUB_FORMAT="arm64-efi"
		EFI_BASENAME="bootaa64.efi"
		EFI_ONDISK="BOOTAA64.EFI"
		;;
	amd64)
		GRUB_FORMAT="x86_64-efi"
		EFI_BASENAME="bootx64.efi"
		EFI_ONDISK="BOOTX64.EFI"
		;;
	*)
		echo "!!! efi-remaster: unsupported architecture '${ARCH}'" >&2
		exit 1
		;;
esac

# grub-mkstandalone reads its modules from /usr/lib/grub/<format>, and the
# Dockerfile installs only the one matching the container's own architecture
# (grub-efi-arm64-bin OR grub-pc-bin + grub-efi-amd64-bin). A missing directory
# here means the wrong container, and saying so beats grub-mkstandalone's own
# error, which names a module rather than the cause.
[ -d "/usr/lib/grub/${GRUB_FORMAT}" ] || {
	echo "!!! efi-remaster: /usr/lib/grub/${GRUB_FORMAT} is not in this container." >&2
	echo "!!! ${ARCH} must be re-mastered in the ${ARCH} build image - see Dockerfile." >&2
	exit 1
}

# THE VOLUME ID IS SET HERE AND NOWHERE ELSE.
#
# auto/config passes `--iso-volume "OS7-<version>-<arch>"` and it has NO EFFECT
# on either architecture now: this script does not modify live-build's ISO, it
# builds a NEW one with xorriso. Every ISO9660 property live-build was told
# about is discarded here.
#
# On arm64 that was already true and BUILD-NOTES #40 is how it was found - by
# reading the label off a finished image with `blkid`: `lb config` had recorded
# LB_ISO_VOLUME="OS7-1.0.0.32-arm64" and the ISO said "OS7-arm64". amd64 used to
# keep live-build's ISO, so there the flag DID work; since 2026-08-25 it does
# not, and the two architectures agree again - this time about the value being
# ignored rather than about it being honoured.
#
# DERIVED FROM THE OUTPUT FILENAME, not from a second environment variable.
# build.sh already names the artefact OS7-<version>-<arch>.iso, so the basename
# without its extension IS the volume id - which means the label on the medium
# and the name of the file can never disagree, and there is no new variable for
# a future caller to forget to set.
#
# ISO9660 volume IDs are capped at 32 characters; "OS7-1.0.0.45-amd64" is 18.
# The cut is here rather than left to xorriso, so an over-long id is visibly
# truncated instead of silently rejected.
OS7_ISO_VOLID="$(basename "${OUT_ISO}")"
OS7_ISO_VOLID="${OS7_ISO_VOLID%.iso}"
OS7_ISO_VOLID="${OS7_ISO_VOLID:0:32}"
[ -n "${OS7_ISO_VOLID}" ] || OS7_ISO_VOLID="OS7-${ARCH}"

cd "${WORK}"

[ -d "${BIN}/casper" ] || { echo "!!! ${BIN}/casper missing — live-build did not produce a live tree" >&2; exit 1; }

# Resolve the kernel/initrd basenames live-build placed under /casper.
VMLINUZ="$(cd "${BIN}/casper" && ls -1 vmlinuz* | head -n1)"
INITRD="$(cd "${BIN}/casper" && ls -1 initrd.img* initrd* 2>/dev/null | head -n1)"
[ -n "${VMLINUZ}" ] && [ -n "${INITRD}" ] || { echo "!!! kernel/initrd not found under ${BIN}/casper" >&2; exit 1; }
echo ">>> ${ARCH} EFI: kernel=${VMLINUZ} initrd=${INITRD}"

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
menuentry "Install OS/7 (${ARCH})" {
    search --no-floppy --set=root --file /.disk/info
    linux  /casper/${VMLINUZ} boot=casper os7.setup=1 systemd.wants=os7-setup.service fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 ---
    initrd /casper/${INITRD}
}
menuentry "OS/7 (${ARCH}) — live session, without installing" {
    search --no-floppy --set=root --file /.disk/info
    linux  /casper/${VMLINUZ} boot=casper quiet splash ---
    initrd /casper/${INITRD}
}
menuentry "OS/7 (${ARCH}) — live session (safe graphics)" {
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
    --format="${GRUB_FORMAT}" \
    --output="${TMP}/${EFI_BASENAME}" \
    --modules="part_gpt part_msdos fat iso9660 normal linux configfile search search_fs_file echo all_video gfxterm test true" \
    "boot/grub/grub.cfg=${TMP}/embed.cfg"

# Expose the loader on the ISO9660 side too (some firmwares look here).
mkdir -p "${BIN}/EFI/BOOT"
cp "${TMP}/${EFI_BASENAME}" "${BIN}/EFI/BOOT/${EFI_ONDISK}"

# FAT EF-system-partition image holding the same loader — this is what the EFI
# El Torito entry points at, and what makes a USB dd of the ISO bootable.
EFIIMG="${BIN}/boot/grub/efiboot.img"
rm -f "${EFIIMG}"
# Size the FAT image to comfortably hold the standalone EFI binary (which embeds
# a GRUB memdisk and can be several MB). 24 MiB is generous and cheap.
mkfs.vfat -C "${EFIIMG}" 24576 >/dev/null
mmd   -i "${EFIIMG}" ::EFI ::EFI/BOOT
mcopy -i "${EFIIMG}" "${TMP}/${EFI_BASENAME}" "::EFI/BOOT/${EFI_ONDISK}"

echo ">>> ${ARCH} EFI: re-mastering bootable ISO -> ${OUT_ISO}"
rm -f "${OUT_ISO}"
xorriso -as mkisofs \
    -iso-level 3 -full-iso9660-filenames \
    -volid "${OS7_ISO_VOLID}" \
    -J -joliet-long -rational-rock \
    -e boot/grub/efiboot.img -no-emul-boot \
    -append_partition 2 0xef "${EFIIMG}" \
    -partition_cyl_align all \
    -o "${OUT_ISO}" \
    "${BIN}"
