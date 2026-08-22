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
# scripts/run-vm.sh — boot OS/7 arm64 ISO (or installed disk) in QEMU with HVF.
#
# Usage:
#   ./scripts/run-vm.sh           # same as --live
#   ./scripts/run-vm.sh --live    # boot ISO as cdrom + blank test disk
#   ./scripts/run-vm.sh --disk-boot  # boot the installed qcow2 only
#   ./scripts/run-vm.sh --reset   # delete test disk + UEFI vars (recreated on next run)
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VM_DIR="$REPO_ROOT/.vm"
ISO="$REPO_ROOT/out/os7-arm64.iso"
DISK="$VM_DIR/os7-test.qcow2"
VARS_FILE="$VM_DIR/edk2-vars.fd"

# ---------------------------------------------------------------------------
# Parse mode flag
# ---------------------------------------------------------------------------
MODE="live"
case "${1:-}" in
    --live)       MODE="live" ;;
    --disk-boot)  MODE="disk-boot" ;;
    --reset)      MODE="reset" ;;
    "")           MODE="live" ;;
    *)
        echo "Unknown flag: $1"
        echo "Usage: $0 [--live|--disk-boot|--reset]"
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# --reset: remove the test disk + UEFI vars and exit
# ---------------------------------------------------------------------------
if [[ "$MODE" == "reset" ]]; then
    removed=0

    if [[ -f "$DISK" ]]; then
        rm "$DISK"
        echo "Deleted $DISK"
        removed=1
    else
        echo "No test disk found at $DISK"
    fi

    if [[ -f "$VARS_FILE" ]]; then
        rm "$VARS_FILE"
        echo "Deleted $VARS_FILE"
        removed=1
    else
        echo "No UEFI vars file found at $VARS_FILE"
    fi

    if [[ "$removed" -eq 1 ]]; then
        echo "VM state reset complete — disk and firmware vars will be recreated on next run."
    else
        echo "Nothing to reset."
    fi

    exit 0
fi

# ---------------------------------------------------------------------------
# Check QEMU is installed
# ---------------------------------------------------------------------------
if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "ERROR: qemu-system-aarch64 not found."
    echo "Install it with:"
    echo "  brew install qemu"
    exit 1
fi

# ---------------------------------------------------------------------------
# Locate UEFI firmware (installed by Homebrew under $(brew --prefix qemu))
# ---------------------------------------------------------------------------
QEMU_PREFIX="$(brew --prefix qemu 2>/dev/null || true)"
if [[ -z "$QEMU_PREFIX" || ! -d "$QEMU_PREFIX" ]]; then
    # Fallback: derive prefix from the qemu-system-aarch64 binary location
    QEMU_PREFIX="$(dirname "$(dirname "$(command -v qemu-system-aarch64)")")"
fi

FIRMWARE_CODE="$QEMU_PREFIX/share/qemu/edk2-aarch64-code.fd"

# The vars template may be named differently across QEMU versions
FIRMWARE_VARS_TEMPLATE=""
for candidate in \
    "$QEMU_PREFIX/share/qemu/edk2-arm-vars.fd" \
    "$QEMU_PREFIX/share/qemu/edk2-aarch64-vars.fd"; do
    if [[ -f "$candidate" ]]; then
        FIRMWARE_VARS_TEMPLATE="$candidate"
        break
    fi
done

if [[ ! -f "$FIRMWARE_CODE" ]]; then
    echo "ERROR: UEFI firmware code not found: $FIRMWARE_CODE"
    echo "Try: brew reinstall qemu"
    exit 1
fi

if [[ -z "$FIRMWARE_VARS_TEMPLATE" ]]; then
    echo "ERROR: UEFI vars template not found under $QEMU_PREFIX/share/qemu/"
    echo "Tried: edk2-arm-vars.fd, edk2-aarch64-vars.fd"
    echo "Try: brew reinstall qemu"
    exit 1
fi

# ---------------------------------------------------------------------------
# Prepare .vm/ directory, writable vars copy, and test disk
# ---------------------------------------------------------------------------
mkdir -p "$VM_DIR"

if [[ ! -f "$VARS_FILE" ]]; then
    echo "Copying UEFI vars template → $VARS_FILE"
    cp "$FIRMWARE_VARS_TEMPLATE" "$VARS_FILE"
fi

if [[ ! -f "$DISK" ]]; then
    echo "Creating test disk: $DISK (30 GB qcow2)"
    qemu-img create -f qcow2 "$DISK" 30G
fi

# ---------------------------------------------------------------------------
# Check ISO exists when it's needed
# ---------------------------------------------------------------------------
if [[ "$MODE" == "live" && ! -f "$ISO" ]]; then
    echo "ERROR: ISO not found: $ISO"
    echo "Build it first:"
    echo "  make build-arm64"
    exit 1
fi

# ---------------------------------------------------------------------------
# HVF availability check (Apple Hypervisor Framework, Apple Silicon / Intel Mac)
# ---------------------------------------------------------------------------
ACCEL="hvf"
HV_SUPPORT="$(sysctl -n kern.hv_support 2>/dev/null || echo 0)"
if [[ "$HV_SUPPORT" != "1" ]]; then
    echo "WARNING: kern.hv_support != 1 — HVF unavailable."
    echo "         Falling back to TCG (software emulation, significantly slower)."
    ACCEL="tcg"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "------------------------------------------------------"
echo "  OS/7 arm64 VM"
echo "  Mode       : $MODE"
echo "  Accel      : $ACCEL"
echo "  Firmware   : $FIRMWARE_CODE (read-only)"
echo "  UEFI vars  : $VARS_FILE (writable)"
echo "  Test disk  : $DISK"
if [[ "$MODE" == "live" ]]; then
    echo "  ISO        : $ISO"
fi
echo "------------------------------------------------------"

# ---------------------------------------------------------------------------
# Build QEMU argument list
# ---------------------------------------------------------------------------
QEMU_ARGS=(
    -machine  "virt,accel=$ACCEL"
    -cpu      host
    -smp      4
    -m        4096

    # UEFI pflash: code read-only, vars read-write
    -drive    "if=pflash,format=raw,file=${FIRMWARE_CODE},readonly=on"
    -drive    "if=pflash,format=raw,file=${VARS_FILE}"

    # Display
    -device   virtio-gpu-pci
    -display  cocoa

    # Network (user-mode NAT; the guest gets internet access automatically)
    -device   virtio-net-pci,netdev=net0
    -netdev   "user,id=net0"

    # USB controller + explicit keyboard/tablet for reliable GUI input on arm64 virt
    -device   qemu-xhci
    -device   usb-kbd
    -device   usb-tablet

    # Serial to stdio (for boot log / console fallback)
    -serial   stdio

    # Test disk (always attached so the installer can target it)
    -drive    "file=${DISK},if=virtio,format=qcow2"
)

if [[ "$MODE" == "live" ]]; then
    # Boot from ISO; disk is attached but not the boot device
    QEMU_ARGS+=(
        -cdrom  "$ISO"
        -boot   d
    )
    # In live mode boot order: cdrom first
fi

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------
exec qemu-system-aarch64 "${QEMU_ARGS[@]}"
