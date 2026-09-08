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
# THE MEDIUM'S BOOT PATH IS THE ARCHIVE'S, NOT OURS (since 2026-09-07).
#
# Until then this script built the loader with grub-mkstandalone, which nobody
# has signed, so the medium booted only with Secure Boot OFF — while what Setup
# installed to the disk was shim + Canonical-signed GRUB all along. On amd64,
# where firmware ships with Secure Boot ENABLED, that made the product's own
# install medium the one thing a factory-configured machine would refuse.
#
# So the four files are taken out of the squashfs THIS BUILD just produced:
#
#   /usr/lib/shim/shim<sfx>.efi.signed         -> /EFI/BOOT/BOOT<ARCH>.EFI
#   /usr/lib/grub/<target>-efi-signed/gcd<sfx>.efi.signed -> /EFI/BOOT/grub<sfx>.efi
#   /usr/lib/shim/mm<sfx>.efi                  -> /EFI/BOOT/mm<sfx>.efi
#   a stub grub.cfg beside them, which is where that GRUB looks
#
# Out of the SQUASHFS and not out of the build container, for one reason that
# matters: the squashfs is what ships, so the pin in build/config/os7-release.conf
# governs the medium's loader exactly as it governs the installed machine's. The
# medium's shim is then byte-identical to the one grub-install will put on the
# disk, and installer/testing/check-image.py requires that rather than hoping.
#
# gcd<sfx>, NOT grub<sfx>. The two differ in the prefix compiled into them —
# /boot/grub against /EFI/ubuntu, measured 2026-09-07 — and /EFI/ubuntu is a
# directory no OS/7 medium has. The disk build is signed correctly, chains
# correctly from shim, and lands at a GRUB prompt.
#
# One path serves both worlds: shim with Secure Boot off simply chains onward
# without verifying, which is how every Ubuntu medium boots on a machine with
# it disabled. There is deliberately no second, unsigned branch to keep working.
#
# docs/SESSION-SECUREBOOT-MEDIUM.md has the measurements.
set -euo pipefail

ARCH="${1:?arch required (amd64|arm64)}"
WORK="${2:?work dir required}"
OUT_ISO="${3:?output iso path required}"
BIN="${WORK}/binary"

# The only things that actually differ. Everything below this table is shared,
# and that is the point of the file.
case "${ARCH}" in
	arm64)
		EFI_SUFFIX="aa64"
		GRUB_TARGET="arm64"
		EFI_ONDISK="BOOTAA64.EFI"
		;;
	amd64)
		EFI_SUFFIX="x64"
		GRUB_TARGET="x86_64"
		EFI_ONDISK="BOOTX64.EFI"
		;;
	*)
		echo "!!! efi-remaster: unsupported architecture '${ARCH}'" >&2
		exit 1
		;;
esac

# THIS USED TO CHECK THE CONTAINER'S OWN /usr/lib/grub/<format>, because
# grub-mkstandalone read its modules from there and a mismatched container
# produced an error naming a module rather than the cause. Nothing here reads
# the container's GRUB any more — the loader comes out of the image being
# built — so the check would now guard a dependency that no longer exists.
#
# What replaced it is stricter and about the right thing: the four files are
# looked for IN THE SQUASHFS by name, after extraction, and a missing one names
# itself. See the EFI assembly below.
command -v unsquashfs >/dev/null || {
	echo "!!! efi-remaster: no unsquashfs in this container - see Dockerfile." >&2
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
#   systemd.unit=multi-user.target   amd64 has a DISPLAY MANAGER and arm64 does not
#   fbcon=font:TER16x32    the closest built-in match until setfont runs (L20)
#   fbcon=nodefer          the framebuffer console exists from the start
#   plymouth.enable=0      nothing scrolls over the field
#   quiet loglevel=0       the kernel, until systemd-sysctl overrules it - see
#                          below, this line is NOT the whole answer
#
# `loglevel=0` DOES NOT KEEP THE KERNEL OFF THIS SCREEN, and for two months the
# line above said it did. The image overrules it:
#
#     /usr/lib/sysctl.d/55-console-messages.conf:  kernel.printk = 4 4 1 7
#
# read out of the shipped amd64 squashfs on 2026-08-26. systemd-sysctl applies
# that during boot, so by the time Setup paints its first frame console_loglevel
# is 4 again and everything at KERN_ERR or above lands on top of the installer -
# which is how an out-of-memory cascade came to be legible only in a photograph
# of the screen. The command line still earns its place: it covers the interval
# between the kernel starting and systemd-sysctl running. The REST of the answer
# is that os7-setup takes console_loglevel down to 1 for as long as it owns the
# console and puts it back on the way out (Tui/Terminal.cs, QuietTheKernel), and
# that the serious lines are copied into Setup's own log when an install fails
# (Diagnostics/KernelLog.cs). docs/BUILD-NOTES.md #79.
#
# The same note is why the Install entry now boots a QUIET medium as well as a
# quiet console: /usr/lib/systemd/system-generators/os7-setup-quiesce masks the
# desktop image's background workload - unattended-upgrades, snapd, packagekit,
# apt-daily and fifteen other timers - whenever os7.setup=1 is on this line. It
# is keyed to THIS entry's token, so the live entries below are untouched.
#
# `nodefer` is not a tuning flag. By default fbcon DEFERS taking the console
# over and completes the takeover only when something writes to it, so tty1
# stays the kernel's dummy device - on which KDFONTOP returns ENOSYS, so no font
# can be loaded and no palette applies. Setup recovers from that on its own
# (BUILD-NOTES #31), but recovering from a race is worse than not having one.
#
# `systemd.unit=multi-user.target` is the amd64 lesson and it cost a boot to
# learn. The Install entry pulls in os7-setup.service, which takes tty1 - and on
# amd64 the image also has gdm3, enabled, pulled in by graphical.target. Both
# want the screen; the display manager wins. Measured 2026-08-25 by booting the
# first re-mastered amd64 ISO: GRUB fine, kernel fine, and then a GNOME desktop
# where Setup should have been, with tty1 blank grey (GDM's) and a plain
# `ubuntu login:` on tty3. BUILD-NOTES #49.
#
# Asking for multi-user.target is better than fighting graphical.target with
# another Conflicts=: the Install entry is a text-mode installer and simply has
# no business reaching the graphical target. It is INERT on arm64, which is
# server-only and never reaches it anyway - so both architectures carry the same
# line and it does something on exactly one of them.
#
# The LIVE entry deliberately does NOT get this. On amd64 "try before you
# install" means a desktop (L14), and that is the entry that promises it.
# AND IT USES ONLY COMMANDS THE SIGNED GRUB ALREADY HAS.
#
# `insmod all_video` was here until 2026-09-07 and had to go: under Secure Boot
# the signed image refuses to load a module from disk, so a menu that calls
# insmod works on a Secure-Boot-OFF bench and nowhere else - which is the worst
# shape a defect can have, because the bench this medium was developed on is
# exactly that bench. What is left (`set`, `menuentry`, `search --file`,
# `linux`, `initrd`) is built into gcd<sfx>.efi.signed; `search --file` needs
# search_fs_file and iso9660, both of which Ubuntu's own install media boot on.
mkdir -p "${BIN}/boot/grub"
cat > "${BIN}/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=10
menuentry "Install OS/7 (${ARCH})" {
    search --no-floppy --set=root --file /.disk/info
    linux  /casper/${VMLINUZ} boot=casper os7.setup=1 systemd.wants=os7-setup.service systemd.unit=multi-user.target fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 ---
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

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# ---------------------------------------------------------------------------
# The signed boot chain, lifted out of the squashfs this build just wrote.
# ---------------------------------------------------------------------------
SQUASH="${BIN}/casper/filesystem.squashfs"
[ -f "${SQUASH}" ] || { echo "!!! efi-remaster: no squashfs at ${SQUASH}" >&2; exit 1; }

SBROOT="${TMP}/sb"
# /etc/alternatives comes along because shim<sfx>.efi.signed IS a symlink into
# it (measured), and unsquashfs extracts only what it is asked for.
unsquashfs -q -n -f -d "${SBROOT}" "${SQUASH}" \
	"usr/lib/shim" \
	"usr/lib/grub/${GRUB_TARGET}-efi-signed" \
	"etc/alternatives" >/dev/null 2>&1 || true

# ASK FOR THE FILES, THEN LOOK FOR THEM. `unsquashfs -d out image a/path/that/
# does/not/exist` extracts nothing and EXITS 0 - measured 2026-08-24 and the
# reason build.sh reads its manifest back the same way. So the exit code above
# is discarded on purpose and every file is required by name below.

# RESOLVED INSIDE THE EXTRACTED TREE, NEVER WITH readlink -f.
#
# /usr/lib/shim/shim<sfx>.efi.signed points at /etc/alternatives/... and that
# target is ABSOLUTE: `readlink -f` would resolve it against the BUILD
# CONTAINER's root and hand back a file that is not the product's - or nothing.
# This walks the chain within ${SBROOT}, which is the same resolution
# grub-install performs inside the installed system, so the medium's shim and
# the disk's shim are the same bytes.
resolve_in() {
	local root="$1" p="$2" hops=0 t
	while [ -L "${root}${p}" ]; do
		hops=$((hops + 1))
		[ "${hops}" -le 8 ] || { echo "!!! efi-remaster: symlink loop at ${p}" >&2; return 1; }
		t="$(readlink "${root}${p}")"
		case "${t}" in
			/*) p="${t}" ;;
			*)  p="$(dirname "${p}")/${t}" ;;
		esac
	done
	printf '%s' "${p}"
}

SHIM_IN_IMAGE="$(resolve_in "${SBROOT}" "/usr/lib/shim/shim${EFI_SUFFIX}.efi.signed")"
SHIM="${SBROOT}${SHIM_IN_IMAGE}"
GRUB="${SBROOT}/usr/lib/grub/${GRUB_TARGET}-efi-signed/gcd${EFI_SUFFIX}.efi.signed"
MOKM="${SBROOT}/usr/lib/shim/mm${EFI_SUFFIX}.efi"

MISSING=""
for f in "${SHIM}" "${GRUB}" "${MOKM}"; do
	[ -s "${f}" ] || MISSING="${MISSING} ${f#${SBROOT}}"
done
[ -z "${MISSING}" ] || {
	echo "!!! efi-remaster: the image carries no signed boot chain for ${ARCH}:${MISSING}" >&2
	echo "!!! shim-signed and grub-efi-${ARCH}-signed must be in the package lists," >&2
	echo "!!! and installer/testing/check-image.py checks that on the finished ISO." >&2
	exit 1
}
echo ">>> ${ARCH} EFI: shim=$(basename "${SHIM_IN_IMAGE}") ($(stat -c %s "${SHIM}") B)," \
     "grub=gcd${EFI_SUFFIX} ($(stat -c %s "${GRUB}") B)"

# WHERE THAT GRUB LOOKS FOR ITS CONFIGURATION, and it is not folklore: Ubuntu's
# GRUB reads the grub.cfg next to the binary it was loaded from ($cmdpath).
# The installed ESP already depends on it - /EFI/BOOT/grub.cfg is the file that
# names which boot environment's menu is read, and that machine boots from a
# FAT filesystem with no /boot/grub on it at all
# (docs/SESSION-BOOT-ENVIRONMENTS.md). gcd's own compiled-in prefix is
# /boot/grub, which resolves on the ISO9660 side; this stub covers the FAT one.
cat > "${TMP}/stub.cfg" <<'EOF'
search --no-floppy --set=root --file /.disk/info
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF

# The ISO9660 side. Some firmware looks here rather than at the El Torito image,
# and check-image.py requires the two sides to carry the same loader, because a
# medium whose sides disagree boots differently depending on the machine.
mkdir -p "${BIN}/EFI/BOOT"
cp "${SHIM}" "${BIN}/EFI/BOOT/${EFI_ONDISK}"
cp "${GRUB}" "${BIN}/EFI/BOOT/grub${EFI_SUFFIX}.efi"
cp "${MOKM}" "${BIN}/EFI/BOOT/mm${EFI_SUFFIX}.efi"
cp "${TMP}/stub.cfg" "${BIN}/EFI/BOOT/grub.cfg"

# FAT EF-system-partition image holding the same four files — this is what the
# EFI El Torito entry points at, and what makes a USB dd of the ISO bootable.
#
# shim looks for its second stage by a name compiled into it (grub<sfx>.efi in
# its own directory), and launches mm<sfx>.efi when it cannot verify what it
# was asked to load - so MokManager is what gives a refusal somewhere to go
# instead of a machine that stops with nothing to act on.
EFIIMG="${BIN}/boot/grub/efiboot.img"
rm -f "${EFIIMG}"
# 24 MiB against ~4.3 MB of loaders. Generous, cheap, and unchanged from when
# the single standalone image lived here.
mkfs.vfat -C "${EFIIMG}" 24576 >/dev/null
mmd   -i "${EFIIMG}" ::EFI ::EFI/BOOT
mcopy -i "${EFIIMG}" "${SHIM}"            "::EFI/BOOT/${EFI_ONDISK}"
mcopy -i "${EFIIMG}" "${GRUB}"            "::EFI/BOOT/grub${EFI_SUFFIX}.efi"
mcopy -i "${EFIIMG}" "${MOKM}"            "::EFI/BOOT/mm${EFI_SUFFIX}.efi"
mcopy -i "${EFIIMG}" "${TMP}/stub.cfg"    "::EFI/BOOT/grub.cfg"

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
