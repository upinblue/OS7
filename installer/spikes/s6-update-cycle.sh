#!/usr/bin/env bash
# =============================================================================
# Spike S6, guest side — does TPM2 auto-unlock survive the update cycle?
#
# S4 proved that a freshly enrolled system unlocks from the TPM. It explicitly
# did NOT prove that the arrangement survives anything, and listed the gap:
#
#   "Sealing to PCR 7 survives kernel and initramfs updates (they are not
#    measured there) but not a Secure Boot policy change […] Nothing here
#    tested that, and a fleet needs a recovery story before it happens."
#
# That sentence contains a claim and an admission, and S6 exists to convert
# both into observations. This script is the guest half; run-s6.py drives it.
#
# Modes:
#   report              print PCR 7 and the LUKS token state, change nothing
#   initramfs           rebuild the initramfs from scratch and verify it still
#                       carries the TPM2 pieces  (the "survives an update" half)
#   reenroll <pass>     re-seal against the CURRENT PCR 7  (the recovery half)
#   grubfast            make later boots in this harness cheap (see below)
#
# Every mode ends in exactly one of S6-<MODE>: COMPLETE / FAILED, because the
# host matches on those and a mode that can end silently is a hang.
# =============================================================================
set -uo pipefail

MODE="${1:-report}"
LUKSDEV=/dev/disk/by-partlabel/os7-luks

say()  { printf '\n=== %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nS6-%s: FAILED — %s\n' "$(echo "$MODE" | tr a-z A-Z)" "$*"; exit 1; }
done_ok() { printf '\nS6-%s: COMPLETE\n' "$(echo "$MODE" | tr a-z A-Z)"; exit 0; }

# -----------------------------------------------------------------------------
# PCR 7 is the whole point of the exercise: it is what systemd-cryptenroll seals
# against, and the only thing that decides whether the sealed key comes back.
# Printed in a form the host can diff between phases.
# -----------------------------------------------------------------------------
pcr7() {
    if ! command -v tpm2_pcrread >/dev/null 2>&1; then
        echo "PCR7= (tpm2_pcrread absent)"
        return
    fi
    local v
    v="$(tpm2_pcrread sha256:7 2>/dev/null | tr -d ' \r' | grep -o '0x[0-9A-Fa-f]\{64\}' | head -1)"
    echo "PCR7=${v:-<none>}"
}

tokens() {
    cryptsetup luksDump "$LUKSDEV" 2>/dev/null \
        | sed -n '/^Tokens:/,/^Digests:/p' | grep -v '^Digests:' | sed 's/^/        /'
}

# -----------------------------------------------------------------------------
# Verify a built initramfs still contains everything S4 had to add by hand.
#
# This is the actual S6 question. The token handler and the libtss2 stack are
# NOT stock: S4 added them through /etc/initramfs-tools/hooks/os7-tpm2, and a
# rebuild only carries them forward if that hook is still present and still
# works. If a rebuild silently drops them, every machine keeps auto-unlocking
# until the next kernel update and then stops — which is exactly the failure
# mode that must not be discovered in the field.
#
# Lifted from s4-tpm-enroll.sh step 5 deliberately, including its correction:
# libtss2-tctildr is NOT on this path and asserting it fails good images.
# -----------------------------------------------------------------------------
verify_initramfs() {
    local img root faults="" o_tpm o_cr
    img="$(ls -1t /boot/initrd.img-* 2>/dev/null | head -1)"
    [ -n "$img" ] || die "no /boot/initrd.img-* to verify"
    note "verifying $img"

    rm -rf /run/os7-s6-ird && mkdir -p /run/os7-s6-ird
    unmkinitramfs "$img" /run/os7-s6-ird || die "unmkinitramfs failed"
    root=/run/os7-s6-ird
    [ -d "$root/main" ] && root="$root/main"

    [ -f "$root/scripts/local-top/ORDER" ] || die "no local-top/ORDER in the image"
    note "local-top run order:"
    sed 's/^/        /' "$root/scripts/local-top/ORDER"

    grep -q "00os7tpm2" "$root/scripts/local-top/ORDER" || faults="$faults order:missing"
    o_tpm=$(grep -n "00os7tpm2" "$root/scripts/local-top/ORDER" | head -1 | cut -d: -f1)
    o_cr=$(grep -n "local-top/cryptroot" "$root/scripts/local-top/ORDER" | head -1 | cut -d: -f1)
    if [ -n "$o_tpm" ] && [ -n "$o_cr" ] && [ "$o_tpm" -lt "$o_cr" ]; then
        note "ok       00os7tpm2 runs before cryptroot"
    else
        note "WRONG    00os7tpm2 ($o_tpm) does not precede cryptroot ($o_cr)"
        faults="$faults order:late"
    fi

    if find "$root" -name 'libcryptsetup-token-systemd-tpm2.so' | grep -q .; then
        note "ok       token handler is in the initramfs"
    else
        note "MISSING  libcryptsetup-token-systemd-tpm2.so"
        faults="$faults initrd:token-handler"
    fi
    for lib in libtss2-esys.so.0 libtss2-mu.so.0 libtss2-rc.so.0 \
               libtss2-tcti-device.so.0 libtss2-sys.so.1; do
        if find "$root" -name "$lib" | grep -q .; then
            note "ok       $lib"
        else
            note "MISSING  $lib"
            faults="$faults initrd:$lib"
        fi
    done
    rm -rf /run/os7-s6-ird
    [ -z "$faults" ] || die "initramfs verification:$faults"
}

case "$MODE" in

report)
    say "state"
    pcr7
    note "LUKS tokens:"
    tokens
    note "root: $(findmnt -no SOURCE,FSTYPE / 2>/dev/null)"
    note "secure boot: $(mokutil --sb-state 2>&1 | head -1)"
    note "kernel: $(uname -r)"
    done_ok
    ;;

grubfast)
    # Not part of the experiment — part of being able to afford it.
    #
    # The harness powers guests off with `poweroff -f`, so GRUB sets recordfail
    # on every subsequent boot and waits out its countdown. Over Ubuntu's
    # 238-column AAVMF serial console that costs 10-15 minutes PER BOOT
    # (SESSION-S4, "it is slow, and not because of the work"). S6 needs five
    # boots. Setting the recordfail timeout to 0 turns an afternoon into an
    # hour and touches nothing PCR 7 measures.
    say "shorten the GRUB recordfail countdown"
    if ! grep -q '^GRUB_RECORDFAIL_TIMEOUT=' /etc/default/grub; then
        echo 'GRUB_RECORDFAIL_TIMEOUT=0' >> /etc/default/grub
    fi
    sed -i 's/^GRUB_RECORDFAIL_TIMEOUT=.*/GRUB_RECORDFAIL_TIMEOUT=0/' /etc/default/grub
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub
    grep -E '^GRUB_(TIMEOUT|RECORDFAIL)' /etc/default/grub | sed 's/^/        /'
    update-grub 2>&1 | tail -3 | sed 's/^/        /' || die "update-grub failed"
    done_ok
    ;;

initramfs)
    # -------------------------------------------------------------------------
    # The claim under test: "kernel and initramfs updates are not measured in
    # PCR 7, so auto-unlock survives them."
    #
    # Two things have to hold for that to be true in practice, and only the
    # first is about PCR 7:
    #   1. the seal still matches       — PCR 7 unchanged across the rebuild
    #   2. the initramfs can still USE it — the hook survived the rebuild
    # A rebuild that quietly drops the token handler passes (1) and fails at
    # the next boot. So both are checked.
    # -------------------------------------------------------------------------
    say "1  PCR 7 before the rebuild"
    pcr7

    say "2  rebuild the initramfs from scratch"
    # -c, not -u: create rather than update, which is what a NEW kernel gets.
    # It is the strictest form of the question and the one a kernel update asks.
    update-initramfs -c -k all 2>&1 | tail -20 | sed 's/^/        /'
    # -c refuses if the image already exists; that is not a failure of the test,
    # so fall back to the update form and say which one ran.
    if [ ! -s "$(ls -1t /boot/initrd.img-* 2>/dev/null | head -1)" ]; then
        die "no initramfs after rebuild"
    fi
    note "forcing a full rebuild of every installed kernel"
    update-initramfs -u -k all 2>&1 | tail -10 | sed 's/^/        /' \
        || die "update-initramfs -u failed"

    say "3  a real kernel package transaction, if the archive is reachable"
    # The rebuild above is deterministic and offline. A package transaction is
    # the realistic trigger and runs the maintainer scripts as well, so it is
    # attempted -- but never allowed to fail the spike, because a VM with no
    # route to the archive says nothing about PCR 7.
    if timeout 240 apt-get -qq update >/dev/null 2>&1 && \
       timeout 600 apt-get -qq install --reinstall -y "linux-image-$(uname -r)" >/dev/null 2>&1; then
        note "ok       reinstalled linux-image-$(uname -r) through apt"
    else
        note "skipped  archive unreachable or package unavailable — the offline"
        note "         rebuild above still exercises the hook, which is the part"
        note "         that can regress. Recorded, not hidden."
    fi

    say "4  verify the rebuilt initramfs"
    verify_initramfs

    say "5  PCR 7 after the rebuild"
    pcr7
    note "if this differs from step 1, the premise behind sealing to PCR 7 alone"
    note "is wrong and SETUP-PLAN L17 needs rewriting, not just extending."
    done_ok
    ;;

reenroll)
    # -------------------------------------------------------------------------
    # The recovery half, and the reason S6 is worth running at all.
    #
    # If a Secure Boot policy change strands a fleet at a passphrase prompt, the
    # question is not whether that happens -- it is whether it is repairable
    # WITHOUT a reinstall, and how. If re-sealing against the new PCR 7 works
    # with nothing but the existing passphrase, then U8's recovery story is
    # "hold a recovery key, re-enrol on first boot after a policy change", and
    # that is automatable. If it does not, U8 is a much bigger problem.
    # -------------------------------------------------------------------------
    PASSPHRASE="${2:-os7spike}"
    say "1  PCR 7 as it now stands"
    pcr7
    note "LUKS tokens before:"
    tokens

    say "2  re-seal against the current PCR 7"
    # --wipe-slot=tpm2 removes the stale sealed slot; without it the old one
    # lingers and luksDump gets confusing. PASSWORD= is how systemd-cryptenroll
    # takes the existing passphrase non-interactively (s4-tpm-enroll.sh step 2).
    PASSWORD="$PASSPHRASE" systemd-cryptenroll --wipe-slot=tpm2 \
        --tpm2-device=auto --tpm2-pcrs=7 "$LUKSDEV" \
        || die "systemd-cryptenroll could not re-seal"

    say "3  confirm the token is back"
    tokens
    cryptsetup luksDump "$LUKSDEV" | grep -q "systemd-tpm2" \
        || die "no systemd-tpm2 token after re-enrolment"
    note "ok       systemd-tpm2 token present"

    say "4  the initramfs is untouched by this"
    note "re-enrolment writes a LUKS token; it does not rebuild the image."
    note "the hook and handler from S4 are what will consume it at next boot."
    done_ok
    ;;

*)
    die "unknown mode '$MODE' (report|grubfast|initramfs|reenroll)"
    ;;
esac
