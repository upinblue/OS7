#!/bin/bash
# =============================================================================
# OS/7 — Phase 0 spike S4, TPM2 half: enrol the TPM and teach the initramfs to
# use it, so an installed system unlocks `rpool` without a passphrase.
#
#   installer/SETUP-PLAN.md §10 Phase 0 S4, and L17 ("enrol TPM2 in the
#   install's configure step, keep a passphrase as recovery").
#
# Runs INSIDE the system S3 installed, as root, after a normal passphrase boot.
#
# THE THING THIS SPIKE EXISTS TO FIND OUT: `systemd-cryptenroll` writes a
# LUKS2 token, but Debian/Ubuntu's `cryptsetup-initramfs` knows nothing about
# tokens. Its hook copies cryptsetup, dmsetup, askpass and sed — and no token
# handler — and its boot script feeds a passphrase to `cryptsetup open` on
# stdin, which skips token activation entirely. Enrolling alone therefore
# changes nothing at boot. Two small pieces close that gap, and they are the
# deliverable here:
#
#   1. a hook that carries libcryptsetup-token-systemd-tpm2.so into the initrd
#   2. a local-top script that runs BEFORE cryptroot and opens the device with
#      `cryptsetup open --token-only`; cryptroot then finds the mapping already
#      present and returns without prompting
#
# `--token-only` is what keeps the TPM-less case working: it never falls back
# to a passphrase itself, so a machine with no TPM simply fails this step and
# lands in cryptroot's normal prompt.
#
# Usage:  sudo bash s4-tpm-enroll.sh [passphrase]
# =============================================================================
set -euo pipefail

PASSPHRASE="${1:-os7spike}"
LUKSDEV=/dev/disk/by-partlabel/os7-luks
LOG=/run/os7-s4.log

exec > >(tee -a "$LOG") 2>&1

say()  { printf '\n=== S4 %s ===\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nS4-ENROLL: FAILED — %s\n' "$*"; exit 1; }

trap 'S4_FAIL_LINE=$LINENO' ERR
trap 'rc=$?; [ $rc -eq 0 ] || printf "\nS4-ENROLL: FAILED at line %s (exit %s)\n" "${S4_FAIL_LINE:-unknown}" "$rc"' EXIT

# -----------------------------------------------------------------------------
say "0  preflight"
# -----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -b "$LUKSDEV" ]    || die "$LUKSDEV not found — is this the S3-installed system?"

# The kernel has TCG_TPM, TCG_TIS and TCG_CRB built in on this image, so the
# device is there or it is not; there is no module to load and nothing for the
# initramfs hook to add.
[ -c /dev/tpmrm0 ] || die "no /dev/tpmrm0 — the VM has no TPM attached"
note "tpm      $(tpm2_getcap properties-fixed 2>/dev/null | grep -A1 TPM2_PT_MANUFACTURER | tail -1 | tr -d ' ' || echo unknown)"

# PCR 7 is what systemd-cryptenroll binds to by default: the Secure Boot policy
# PCR. Print it, because "auto-unlock works" means something quite different
# when the firmware never measured anything into it (see the session notes).
note "PCR 7 before enrolment:"
tpm2_pcrread sha256:7 | sed 's/^/        /'

# -----------------------------------------------------------------------------
say "1  enrol the TPM into the LUKS2 header"
# -----------------------------------------------------------------------------
# $PASSWORD is how systemd-cryptenroll takes the EXISTING passphrase without a
# prompt. The passphrase keyslot is deliberately left in place — L17 wants it as
# the recovery path, and the TPM-less test depends on it.
# --wipe-slot=tpm2 first so re-running this script replaces the previous TPM
# keyslot instead of stacking another one beside it.
PASSWORD="$PASSPHRASE" systemd-cryptenroll --wipe-slot=tpm2 \
    --tpm2-device=auto --tpm2-pcrs=7 "$LUKSDEV"

note "LUKS2 tokens and keyslots now:"
cryptsetup luksDump "$LUKSDEV" | sed -n '/^Keyslots:/,$p' \
    | grep -E "^  [0-9]+:|^Tokens:|^  [0-9]+: systemd|Key:|PBKDF:" | sed 's/^/        /'

# -----------------------------------------------------------------------------
say "2  carry the token handler into the initramfs"
# -----------------------------------------------------------------------------
install -d /etc/initramfs-tools/hooks
cat > /etc/initramfs-tools/hooks/os7-tpm2 <<'HOOK'
#!/bin/sh
# OS/7: put the systemd-tpm2 LUKS2 token handler in the initramfs.
#
# cryptsetup loads external token handlers from a compiled-in directory
# (/usr/lib/<triplet>/cryptsetup). The stock cryptsetup-initramfs hook copies
# none of them, so `cryptsetup open --token-only` inside the initrd can only
# fail. copy_exec places the .so at the same absolute path and drags in its
# shared-library dependencies (libtss2-*, libcrypto, ...) on its own.
set -e
[ "$1" = prereqs ] && { echo; exit 0; }
. /usr/share/initramfs-tools/hook-functions

found=
for so in /usr/lib/*/cryptsetup/libcryptsetup-token-systemd-tpm2.so; do
    [ -e "$so" ] || continue
    copy_exec "$so"
    found=y
done
[ -n "$found" ] || {
    echo "os7-tpm2: libcryptsetup-token-systemd-tpm2.so not found" >&2
    exit 1
}

# copy_exec follows ELF NEEDED, and that is not enough here. The token handler
# links libsystemd-shared, and libsystemd-shared *dlopens* the TPM stack as an
# optional feature:
#
#   [{"feature":"tpm","description":"Support for TPM","priority":"suggested",
#     "soname":["libtss2-esys.so.0"]}]
#
# Nothing that walks NEEDED can see those, so they have to be named. Same story
# one level down: libtss2-tctildr dlopens a TCTI backend by name, and
# /dev/tpmrm0 is served by libtss2-tcti-device.so.0.
for lib in libtss2-esys.so.0 libtss2-mu.so.0 libtss2-rc.so.0 \
           libtss2-tcti-device.so.0; do
    hit=
    for cand in /usr/lib/*/"$lib" /usr/lib/"$lib"; do
        [ -e "$cand" ] || continue
        copy_exec "$cand"
        hit=y
        break
    done
    [ -n "$hit" ] || { echo "os7-tpm2: $lib not found" >&2; exit 1; }
done
HOOK
chmod 0755 /etc/initramfs-tools/hooks/os7-tpm2

# -----------------------------------------------------------------------------
say "3  unlock via the token before cryptroot gets to ask"
# -----------------------------------------------------------------------------
# The name matters. initramfs-tools orders local-top scripts with
# `get_prereq_pairs | tsort`, which for scripts that declare no prereqs falls
# back to the directory glob — i.e. alphabetical. A leading "00" is what puts
# this ahead of `cryptroot`; step 5 checks the generated ORDER rather than
# trusting that.
install -d /etc/initramfs-tools/scripts/local-top
cat > /etc/initramfs-tools/scripts/local-top/00os7tpm2 <<'TOP'
#!/bin/sh
# OS/7: try to unlock every initramfs crypttab entry from the TPM2 token.
#
# Deliberately best-effort and silent about failure: --token-only never falls
# back to a passphrase, so if the TPM is absent, sealed against different PCRs,
# or simply says no, this exits 0 and the stock cryptroot script prompts as it
# always did. That IS the TPM-less recovery path.
[ "$1" = prereqs ] && { echo; exit 0; }
[ -e /scripts/functions ] && . /scripts/functions

[ -c /dev/tpmrm0 ] || exit 0
[ -s /cryptroot/crypttab ] || exit 0

mkdir -pm0700 /run/cryptsetup

while read -r name source key options; do
    case "$name" in ''|\#*) continue ;; esac
    case "$source" in
        UUID=*) dev="/dev/disk/by-uuid/${source#UUID=}" ;;
        *)      dev="$source" ;;
    esac
    [ -b "$dev" ] || continue
    if /sbin/cryptsetup open --token-only -- "$dev" "$name" 2>/dev/null; then
        echo "os7-tpm2: unlocked $name from the TPM"
    fi
done < /cryptroot/crypttab
exit 0
TOP
chmod 0755 /etc/initramfs-tools/scripts/local-top/00os7tpm2

# -----------------------------------------------------------------------------
say "4  rebuild the initramfs"
# -----------------------------------------------------------------------------
update-initramfs -u -k all

# -----------------------------------------------------------------------------
say "5  verify the initramfs before rebooting into it"
# -----------------------------------------------------------------------------
# Checking the built image beats finding out at the passphrase prompt, and the
# ordering claim in step 3 is exactly the kind of thing that must be observed
# rather than assumed.
IMG="$(ls -1 /boot/initrd.img-* | head -1)"
rm -rf /run/os7-ird && mkdir -p /run/os7-ird
unmkinitramfs "$IMG" /run/os7-ird
ROOTDIR=/run/os7-ird
[ -d "$ROOTDIR/main" ] && ROOTDIR=$ROOTDIR/main

note "local-top run order:"
sed 's/^/        /' "$ROOTDIR/scripts/local-top/ORDER"

FAULTS=""
grep -q "00os7tpm2" "$ROOTDIR/scripts/local-top/ORDER" || FAULTS="$FAULTS order:missing"
# The line for 00os7tpm2 must come before the one for cryptroot.
o_tpm=$(grep -n "00os7tpm2" "$ROOTDIR/scripts/local-top/ORDER" | head -1 | cut -d: -f1)
o_cr=$(grep -n "local-top/cryptroot" "$ROOTDIR/scripts/local-top/ORDER" | head -1 | cut -d: -f1)
if [ -n "$o_tpm" ] && [ -n "$o_cr" ] && [ "$o_tpm" -lt "$o_cr" ]; then
    note "ok       00os7tpm2 runs before cryptroot"
else
    note "WRONG    00os7tpm2 ($o_tpm) does not precede cryptroot ($o_cr)"
    FAULTS="$FAULTS order:late"
fi

if find "$ROOTDIR" -name 'libcryptsetup-token-systemd-tpm2.so' | grep -q .; then
    note "ok       token handler is in the initramfs"
else
    note "MISSING  libcryptsetup-token-systemd-tpm2.so"
    FAULTS="$FAULTS initrd:token-handler"
fi
# libtss2-sys is here because copy_exec SHOULD have brought it along as a
# NEEDED of libtss2-esys; checking it is how we find out if that stopped being
# true. libtss2-tctildr is deliberately absent from this list: esys does not
# link it and systemd never calls Tss2_TctiLdr_*, it builds "device:/dev/tpmrm0"
# and dlopens libtss2-tcti-device.so.0 itself. An earlier version of this check
# asserted tctildr and failed a perfectly good initramfs for it.
for lib in libtss2-esys.so.0 libtss2-mu.so.0 libtss2-rc.so.0 \
           libtss2-tcti-device.so.0 libtss2-sys.so.1; do
    if find "$ROOTDIR" -name "$lib" | grep -q .; then
        note "ok       $lib"
    else
        note "MISSING  $lib"
        FAULTS="$FAULTS initrd:$lib"
    fi
done

[ -z "$FAULTS" ] || die "initramfs verification:$FAULTS"

trap - EXIT
cat <<EOF

S4-ENROLL: COMPLETE
    The next boot should reach a login prompt WITHOUT asking for a passphrase.
    A boot with no TPM attached should still ask for one.
EOF
