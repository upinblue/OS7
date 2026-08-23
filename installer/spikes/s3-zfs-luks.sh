#!/bin/bash
# =============================================================================
# OS/7 — Phase 0 spike S3: does a ZFS-on-LUKS root install boot at all?
#
#   installer/SETUP-PLAN.md §10 Phase 0. This is the spike that gates
#   everything: if this layout cannot boot, no amount of Setup UI helps.
#
# THROWAWAY IN QUALITY, LOAD-BEARING IN SEQUENCE. The order of the steps below
# is the deliverable — os7-setup's storage executor is meant to be a front-end
# over exactly this sequence, so every non-obvious ordering constraint is
# commented where it bites, not summarised at the top.
#
# Runs INSIDE the live ISO, as root. It is NOT the installer and never will be:
# no UI, no disk selection, no rollback. It takes one target device, destroys
# everything on it, and lays down the layout from SETUP-PLAN §4.4:
#
#   <target>
#    ├─ p1   512 MiB  EF00  FAT32   /boot/efi
#    ├─ p2     2 GiB  BF00  ZFS     bpool          (unencrypted, GRUB reads it)
#    └─ p3     rest   8309  LUKS2   os7_root       (encrypted, D3)
#                            └─ ZFS rpool
#
# Usage (inside the live session):
#   sudo bash s3-zfs-luks.sh /dev/vdb [passphrase]
#
# Env:
#   OS7_RELEASE   release string baked into the boot-environment name
#   OS7_SQUASHFS  override the source squashfs path
# =============================================================================
set -euo pipefail

TARGET="${1:?usage: s3-zfs-luks.sh <target-disk> [passphrase]}"
PASSPHRASE="${2:-os7spike}"
OS7_RELEASE="${OS7_RELEASE:-2026.08.1}"

LOG=/run/os7-s3.log
KEYFILE=/run/os7-luks.key
# Not /mnt: whatever carries the installer is usually mounted there, and it
# is usually read-only, so ZFS cannot create its mountpoints underneath.
# /target is what d-i and subiquity use for the same reason.
MNT=/target

# Boot-environment id. SETUP-PLAN §4.4 pins the scheme because
# Restore-OS7 -BootEnvironment needs something it can list and sort.
BE="os7_${OS7_RELEASE}_$(date -u +%Y%m%d%H%M)"
SUFFIX="$(tr -dc 'a-z0-9' </dev/urandom | head -c6 || true)"

exec > >(tee -a "$LOG") 2>&1

say()  { printf '\n=== S3 %s ===\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nS3-SPIKE: FAILED — %s\n' "$*"; exit 1; }

# $LINENO inside an EXIT trap is the trap's own line, so an EXIT trap that
# prints it reports "line 1" for every failure anywhere in the script. Capture
# the real line in an ERR trap, which fires at the failing command.
trap 'S3_FAIL_LINE=$LINENO' ERR
trap 'rc=$?; [ $rc -eq 0 ] || printf "\nS3-SPIKE: FAILED at line %s (exit %s)\n" "${S3_FAIL_LINE:-unknown}" "$rc"' EXIT

# -----------------------------------------------------------------------------
say "0  preflight"
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -b "$TARGET" ]     || die "$TARGET is not a block device"

# L12: Setup must never offer its own boot medium as a target. The spike has to
# honour the same rule or a mistyped device eats the live ISO out from under it.
LIVE_SRC="$(findmnt -no SOURCE /cdrom 2>/dev/null || true)"
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
for guard in "$LIVE_SRC" "$ROOT_SRC"; do
    case "$guard" in
        "$TARGET"|"$TARGET"[0-9]*|"$TARGET"p[0-9]*) die "$TARGET carries the live medium" ;;
    esac
done
if grep -q " ${TARGET}[0-9p]* " /proc/mounts; then die "$TARGET has mounted partitions"; fi

# The squashfs casper booted from is the payload we install.
SQUASHFS="${OS7_SQUASHFS:-}"
if [ -z "$SQUASHFS" ]; then
    for c in /cdrom/casper/filesystem.squashfs \
             /run/live/medium/casper/filesystem.squashfs \
             /media/cdrom/casper/filesystem.squashfs; do
        if [ -f "$c" ]; then SQUASHFS="$c"; break; fi
    done
fi
[ -n "$SQUASHFS" ] && [ -f "$SQUASHFS" ] || die "cannot find filesystem.squashfs"

modprobe zfs
modprobe dm-crypt 2>/dev/null || true

# Fail here rather than four steps in, where the message is about a ZFS
# mountpoint and says nothing about why.
mkdir -p "$MNT"
if ! touch "$MNT/.os7-writable" 2>/dev/null; then
    die "$MNT is not writable — something read-only is mounted there"
fi
rm -f "$MNT/.os7-writable"
if mountpoint -q "$MNT"; then die "$MNT is already a mount point"; fi

note "target      $TARGET  ($(blockdev --getsize64 "$TARGET" | numfmt --to=iec))"
note "squashfs    $SQUASHFS  ($(stat -c%s "$SQUASHFS" | numfmt --to=iec))"
note "boot env    $BE"
note "zfs         $(zfs version | head -1)"
note "cryptsetup  $(cryptsetup --version)"

# -----------------------------------------------------------------------------
say "1  hostid — before the pools exist, not after"
# -----------------------------------------------------------------------------
# L13, and the single most expensive ZFS-root footgun there is. A pool records
# the hostid of whoever last imported it; if the installed system's hostid does
# not match, the pool refuses to import at boot and you land in the initramfs.
#
# The ordering that makes this safe: generate the hostid on the LIVE system
# FIRST, create the pools under it, then copy that exact file into the target.
# Doing it the other way round (zgenhostid into the target at the end) leaves
# the pools stamped with whatever the live system happened to have.
if [ ! -s /etc/hostid ]; then
    zgenhostid -f
fi
note "hostid $(hostid) from /etc/hostid"

# -----------------------------------------------------------------------------
say "2  partition $TARGET"
# -----------------------------------------------------------------------------
# Stale ZFS labels on a reused disk make `zpool create` refuse or, worse,
# resurrect a phantom pool. Clear them explicitly (L12).
zpool labelclear -f "$TARGET" 2>/dev/null || true
for p in "$TARGET"[0-9]* "$TARGET"p[0-9]*; do
    [ -b "$p" ] && zpool labelclear -f "$p" 2>/dev/null || true
done
wipefs -a "$TARGET" >/dev/null 2>&1 || true
sgdisk --zap-all "$TARGET" >/dev/null

sgdisk -n1:1M:+512M  -t1:EF00 -c1:os7-esp   "$TARGET" >/dev/null
sgdisk -n2:0:+2G     -t2:BF00 -c2:os7-bpool "$TARGET" >/dev/null
sgdisk -n3:0:0       -t3:8309 -c3:os7-luks  "$TARGET" >/dev/null

partprobe "$TARGET" 2>/dev/null || true
udevadm settle --timeout=30

# Address partitions by GPT name, never by "$TARGET$n" — /dev/vdb1 vs
# /dev/nvme0n1p1 vs /dev/mmcblk0p1 is exactly the naming trap in L12.
ESP=/dev/disk/by-partlabel/os7-esp
BDEV=/dev/disk/by-partlabel/os7-bpool
LUKSDEV=/dev/disk/by-partlabel/os7-luks
for d in "$ESP" "$BDEV" "$LUKSDEV"; do
    [ -b "$d" ] || die "partition $d did not appear"
done
sgdisk -p "$TARGET"

# -----------------------------------------------------------------------------
say "3  ESP + LUKS2 container"
# -----------------------------------------------------------------------------
mkfs.vfat -F32 -n OS7ESP "$ESP" >/dev/null

# The keyfile must hold the passphrase bytes with NO trailing newline:
# luksFormat consumes the file verbatim, while the boot prompt strips the
# newline. A here-doc or `echo` here means the passphrase you typed at install
# time is not the one that unlocks at boot.
printf '%s' "$PASSPHRASE" > "$KEYFILE"
chmod 600 "$KEYFILE"

# Explicit, modest PBKDF cost. The default targets a time and sizes memory from
# the live system's RAM; the initramfs has to reproduce it on possibly smaller
# hardware. Pin it so install-time and boot-time agree.
cryptsetup luksFormat "$LUKSDEV" "$KEYFILE" \
    --type luks2 --batch-mode \
    --label OS7ROOT \
    --pbkdf argon2id --pbkdf-memory 524288 --pbkdf-parallel 2 --iter-time 2000

# --allow-discards --persistent: writes the discard flag into the LUKS2 header
# so it also applies to the unlock the initramfs does at boot. Without TRIM
# reaching the SSD, ZFS autotrim is silently a no-op (§4.5).
cryptsetup open --key-file "$KEYFILE" --allow-discards --persistent "$LUKSDEV" os7_root
[ -b /dev/mapper/os7_root ] || die "LUKS mapping did not appear"
cryptsetup status os7_root | sed 's/^/    /'

# -----------------------------------------------------------------------------
say "4  pools"
# -----------------------------------------------------------------------------
# bpool: GRUB can only read the read-only-compatible feature set (§4.2).
# `-o compatibility=grub2` is the modern way to say that — ZFS ships the list at
# /usr/share/zfs/compatibility.d/grub2, so it tracks GRUB instead of being a
# hand-maintained -d -o feature@... incantation that rots.
# Note it excludes zstd, so bpool compresses with lz4.
zpool create -f \
    -o ashift=12 -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off -O acltype=posixacl -O xattr=sa \
    -O compression=lz4 -O normalization=formD -O relatime=on \
    -O canmount=off -O mountpoint=/boot -R "$MNT" \
    bpool "$BDEV"

# rpool sits on the mapper node, never on the partition (D3).
zpool create -f \
    -o ashift=12 -o autotrim=on \
    -o cachefile=/etc/zfs/zpool.cache \
    -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
    -O compression=lz4 -O normalization=formD -O relatime=on \
    -O canmount=off -O mountpoint=/ -R "$MNT" \
    rpool /dev/mapper/os7_root

# -----------------------------------------------------------------------------
say "5  datasets (SETUP-PLAN §4.4)"
# -----------------------------------------------------------------------------
zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

# canmount=noauto on the boot environment: several BEs will exist side by side
# and only the one named on the cmdline may claim /. The initramfs mounts it.
zfs create -o canmount=noauto -o mountpoint=/ "rpool/ROOT/$BE"
zfs mount "rpool/ROOT/$BE"

zfs create "rpool/ROOT/$BE/var"
zfs create "rpool/ROOT/$BE/var/log"

# THE decision this layout exists for: USERDATA is a sibling of ROOT, not a
# child. Rolling back a bad release must not roll back the user's files, and it
# cannot be retrofitted later (§4.4).
zfs create -o canmount=off -o mountpoint=none rpool/USERDATA
zfs create -o mountpoint=/root       "rpool/USERDATA/root_${SUFFIX}"
zfs create -o mountpoint=/home/os7   "rpool/USERDATA/os7_${SUFFIX}"

zfs create -o mountpoint=/boot "bpool/BOOT/$BE"

zfs list -o name,used,mountpoint,canmount -r rpool bpool | sed 's/^/    /'

# -----------------------------------------------------------------------------
say "6  unsquashfs the live filesystem into the pool"
# -----------------------------------------------------------------------------
# The ESP is mounted AFTER this. unsquashfs -f writes /boot wholesale, and a
# mounted FAT filesystem underneath it is a good way to lose the ESP contents.
unsquashfs -f -d "$MNT" "$SQUASHFS" > /run/os7-unsquashfs.log 2>&1 \
    || { tail -20 /run/os7-unsquashfs.log; die "unsquashfs failed"; }
tail -3 /run/os7-unsquashfs.log | sed 's/^/    /'
mkdir -p "$MNT/boot/efi"
mount "$ESP" "$MNT/boot/efi"
note "rpool now holds $(zfs list -H -o used rpool)"

# -----------------------------------------------------------------------------
say "7  target identity: hostid, pool cache, crypttab, fstab"
# -----------------------------------------------------------------------------
install -d "$MNT/etc/zfs"
cp /etc/hostid          "$MNT/etc/hostid"          # step 1's file, verbatim
cp /etc/zfs/zpool.cache "$MNT/etc/zfs/zpool.cache" # so zfs-import-cache finds bpool
echo os7 > "$MNT/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tos7\n' > "$MNT/etc/hosts"
: > "$MNT/etc/machine-id"                          # regenerated on first boot

LUKS_UUID="$(blkid -s UUID -o value "$LUKSDEV")"
ESP_UUID="$(blkid -s UUID -o value "$ESP")"

# `initramfs` is not optional here. cryptsetup-initramfs decides what to embed
# by resolving the root device; with root=ZFS=... it cannot resolve anything, so
# without this keyword the hook embeds nothing and the machine stops at an
# initramfs prompt with no way to unlock rpool.
cat > "$MNT/etc/crypttab" <<EOF
os7_root UUID=$LUKS_UUID none luks,discard,initramfs
EOF

# Belt and braces for the same failure — force the hook on regardless.
install -d "$MNT/etc/cryptsetup-initramfs"
echo 'CRYPTSETUP=y' > "$MNT/etc/cryptsetup-initramfs/conf-hook"

# ZFS datasets carry their own mountpoints; only the ESP belongs in fstab.
cat > "$MNT/etc/fstab" <<EOF
UUID=$ESP_UUID  /boot/efi  vfat  umask=0077,shortname=winnt  0  1
EOF

# D4: swap is zram, so nothing on disk stays non-ZFS except the ESP.
install -d "$MNT/etc/systemd"
cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
EOF

note "luks uuid $LUKS_UUID"
note "esp  uuid $ESP_UUID"

# -----------------------------------------------------------------------------
say "8  bind mounts + chroot configuration"
# -----------------------------------------------------------------------------
# The bind mounts live in their own mount namespace, and the chroot runs inside
# it. This is not tidiness — it is the only reliable way to get the pool back.
#
# `mount --make-private --rbind` (the incantation every ZFS-root guide uses)
# makes the NEW mount private after the fact, but by then the mount has already
# propagated to every peer of the live system's shared root, including
# namespaces belonging to systemd services. Unmounting in this namespace then
# leaves copies alive in theirs, and `zpool export rpool` fails with
#
#   cannot export 'rpool': pool is busy
#
# with nothing whatsoever visible under $MNT, and `-f` does not help either.
# A private namespace never propagates in the first place, and every mount in it
# disappears when it exits — no teardown to get wrong.
cat > /run/os7-chroot-wrap.sh <<WRAP
#!/bin/bash
set -euo pipefail
mount --rbind /dev  "$MNT/dev"
mount --rbind /proc "$MNT/proc"
mount --rbind /sys  "$MNT/sys"
mount -t tmpfs tmpfs "$MNT/run"
mkdir -p "$MNT/run/lock"
exec chroot "$MNT" bash /tmp/os7-chroot.sh
WRAP

# GRUB_CMDLINE_LINUX, and why every token is there:
#
#   boot=zfs   REQUIRED, and nothing generates it for you. initramfs-tools'
#              /init defaults BOOT=local, /scripts/local has no ZFS handling at
#              all, and grub.d/10_linux_zfs emits only root=ZFS=... . Without
#              boot=zfs the initramfs tries to mount the literal string
#              "ZFS=rpool/ROOT/..." as a device and drops to a prompt.
#              It also buys the LUKS ordering: /scripts/zfs's pre_mountroot()
#              runs /scripts/local-top, where cryptroot unlocks os7_root before
#              the pool import is attempted.
#   root=ZFS=  deliberately NOT here. grub.d/10_linux_zfs emits it per menu
#              entry, one per boot environment. Anything appended via
#              GRUB_CMDLINE_LINUX lands after it and therefore wins, so pinning
#              a dataset here makes every BE in the menu boot the same one —
#              which is exactly the feature the layout exists for.
#   console=   spike-only, so the whole boot is visible on QEMU's serial line.
cat > "$MNT/etc/default/grub" <<EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_DISTRIBUTOR="OS/7"
GRUB_CMDLINE_LINUX="boot=zfs console=tty1 console=ttyAMA0,115200"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_DISABLE_OS_PROBER=true
GRUB_DISABLE_RECOVERY=true
EOF

cat > "$MNT/tmp/os7-chroot.sh" <<CHROOT
#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

echo ">>> chroot: casper"
# The squashfs is a LIVE image. Left installed, casper's initramfs hook and
# boot script ship in an initrd that has no business being on an installed
# system. It is inert without boot=casper, but remove it rather than rely on
# that.
dpkg --purge casper >/dev/null 2>&1 || echo "    (casper purge skipped)"

echo ">>> chroot: a user to log in as"
# The squashfs has no users at all — casper creates the live 'ubuntu' account at
# boot, in the overlay, so none of it survives into the install. Without this
# the installed system boots to a login prompt nobody can get past, and the
# spike could not be verified.
useradd -M -d /home/os7 -s /bin/bash -G sudo os7

# NOT chpasswd. This image's PAM password stack runs authd's helper
# (pam_authd_exec.so in common-password), which cannot work inside a chroot:
#
#   chpasswd: (user os7) pam_chauthtok() failed, error:
#   Failed preliminary check by password service
#
# Clear the password instead — the same thing casper does for the live user,
# and pam_unix carries nullok in this image, so an empty password logs in.
# passwd -d edits /etc/shadow directly and never enters the PAM stack.
# Fine for a throwaway spike VM; a real installer sets the password from
# outside PAM too (write the crypt hash), never through chpasswd in a chroot.
passwd -d os7

# Passwordless sudo too, for the same reason and with the same caveat: sudo
# stops to ask even when the account has no password, which is enough to hang
# an unattended harness forever.
echo 'os7 ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/os7-spike
chmod 0440 /etc/sudoers.d/os7-spike

cp -a /etc/skel/. /home/os7/ 2>/dev/null || true
chown -R os7:os7 /home/os7

echo ">>> chroot: initramfs"
update-initramfs -u -k all || update-initramfs -c -k all

# Everything below records what it found and keeps going. A spike that stops at
# the first problem costs a whole 15-minute cycle per problem; one that gets to
# the end reports all of them at once. FAULTS decides the exit code.
FAULTS=""

echo ">>> chroot: verifying the initramfs can actually unlock and import"
IMG=\$(ls -1 /boot/initrd.img-* | head -1)
lsinitramfs "\$IMG" > /tmp/initrd.list
# 'cryptroot/crypttab', not the pre-2.x 'conf/conf.d/cryptroot': at
# initramfs stage /lib/cryptsetup/functions sets TABFILE=/cryptroot/crypttab,
# and that is the file local-top/cryptroot reads. Checking the old path reports
# a missing unlock config on an image that has one.
for want in cryptsetup zpool 'cryptroot/crypttab' 'etc/hostid' 'scripts/zfs'; do
    if grep -q "\$want" /tmp/initrd.list; then
        echo "    ok       \$want"
    else
        echo "    MISSING  \$want"
        FAULTS="\$FAULTS initrd:\$want"
    fi
done
echo "    --- what the initramfs actually carries:"
grep -E 'cryptroot|hostid|scripts/zfs|sbin/(zpool|cryptsetup)$' /tmp/initrd.list \
    | sed 's/^/        /' | head -20 || true

echo ">>> chroot: grub-install (removable path first)"
# \EFI\BOOT\BOOTAA64.EFI is what firmware boots when NVRAM holds no entry for
# this disk — a reset CMOS, a disk moved to another machine, a USB install.
# It needs no efivars, so do it first and treat it as the one that must work.
grub-install --target=arm64-efi --efi-directory=/boot/efi --removable --recheck \
    || FAULTS="\$FAULTS grub-install:removable"

echo ">>> chroot: grub-install (NVRAM entry)"
# This one calls efibootmgr and therefore needs a writable efivarfs. Best
# effort: without it the machine still boots via the removable path above.
grub-install --target=arm64-efi --efi-directory=/boot/efi \
    --bootloader-id=OS7 --recheck --no-floppy \
    || echo "    NOTE: no NVRAM entry (efivars unavailable?) — removable path stands in"

echo ">>> chroot: update-grub"
update-grub || FAULTS="\$FAULTS update-grub"

# Which generator actually produced the entries matters, so check rather than
# assume. grub.d/10_linux hands ZFS over to 10_linux_zfs whenever that file
# exists; 10_linux_zfs is the zsys-era boot-environment generator and it looks
# for a dataset whose mountpoint is '/', which an altroot'd install may not
# present. If it emitted nothing, stand it down and let plain 10_linux do it —
# that path resolves the ZFS root itself and needs no code of ours.
if ! grep -q "root=ZFS" /boot/grub/grub.cfg; then
    echo "    10_linux_zfs produced no ZFS entry — falling back to 10_linux"
    chmod -x /etc/grub.d/10_linux_zfs
    update-grub || true
fi

echo ">>> chroot: generated boot entries"
grep -E "menuentry |linux\s|root=ZFS" /boot/grub/grub.cfg | head -20 || true

if [ -n "\$FAULTS" ]; then
    echo ">>> chroot: FAULTS ->\$FAULTS"
    exit 1
fi
echo ">>> chroot: clean"
CHROOT

unshare --mount --propagation private -- bash /run/os7-chroot-wrap.sh
rm -f "$MNT/tmp/os7-chroot.sh" /run/os7-chroot-wrap.sh

# -----------------------------------------------------------------------------
say "9  verify before tearing down"
# -----------------------------------------------------------------------------
note "grub.cfg root= line:"
grep -m1 "root=ZFS" "$MNT/boot/grub/grub.cfg" | sed 's/^/    /' || die "no ZFS root entry in grub.cfg"
note "ESP:"
find "$MNT/boot/efi" -name '*.EFI' -o -name '*.efi' | sed 's/^/    /'
note "kernel + initrd on bpool:"
ls -la "$MNT/boot"/vmlinuz-* "$MNT/boot"/initrd.img-* | sed 's/^/    /'
note "crypttab:"; sed 's/^/    /' "$MNT/etc/crypttab"

# -----------------------------------------------------------------------------
say "10  export"
# -----------------------------------------------------------------------------
sync
# /dev, /proc, /sys and /run went away with the namespace in step 8. Only the
# ESP and the ZFS mounts are left.
umount "$MNT/boot/efi" 2>/dev/null || true
umount -R "$MNT" 2>/dev/null || true
zfs umount -a 2>/dev/null || true

note "mount state before export:"
findmnt -t zfs -A 2>/dev/null | sed 's/^/        /' || note "        (no zfs mounts)"
note "processes rooted or working inside $MNT:"
ls -l /proc/*/cwd /proc/*/root 2>/dev/null | grep -- "$MNT" | sed 's/^/        /' \
    || note "        (none)"

export_pool() {
    local pool="$1"
    zpool export "$pool" && return 0
    note "$pool would not export — still mounted below $MNT:"
    findmnt -R "$MNT" 2>/dev/null | sed 's/^/        /' || note "(nothing)"
    # Forcing is safe here only because everything above already ran: the data
    # is written and synced. A real installer should treat this as a bug to fix,
    # not a step to normalise — and note that -f does NOT help against a mount
    # held in another namespace, which is what step 8's unshare exists to avoid.
    note "forcing export of $pool"
    zpool export -f "$pool" || die "$pool would not export even with -f"
}
export_pool bpool
export_pool rpool
cryptsetup close os7_root
shred -u "$KEYFILE" 2>/dev/null || rm -f "$KEYFILE"

trap - EXIT
cat <<EOF

S3-SPIKE: INSTALL COMPLETE
    boot environment : rpool/ROOT/$BE
    passphrase       : $PASSPHRASE
    log              : $LOG

Now power off and boot the target disk ALONE. Pass = it asks for the
passphrase and reaches a login prompt from rpool/ROOT/$BE.
EOF
