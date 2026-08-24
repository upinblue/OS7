#!/usr/bin/env bash
# =============================================================================
# OS/7 — build the amd64 ISO inside a full QEMU x86_64 VM.
#
# WHEN YOU NEED THIS
#   Only on an ARM host (Apple Silicon). On a real x86_64 machine - an Intel or
#   AMD Mac, an x64 Windows box with Docker Desktop, or an x86_64 Linux host -
#   `make build-amd64` runs NATIVELY and is far faster. Use that instead.
#
# WHY IT EXISTS
#   Docker Desktop's amd64 emulation on Apple Silicon translates syscalls, and
#   the translation layer does not implement one that GNU tar 1.35 needs. The
#   base system therefore cannot be unpacked:
#       E: Tried to extract package, but tar failed. Exit...
#       tar: ./etc/default: Cannot mkdir: Function not implemented
#   (ENOSYS. Still present on Docker 29.7.2. See docs/BUILD-NOTES.md #12.)
#
#   Full SYSTEM emulation does not have that gap: QEMU emulates a whole x86
#   machine running a real x86 kernel, so no syscall translation happens. This
#   is proven locally - the Session 0 amd64 VM installed ZFS packages fine,
#   which is exactly the dpkg/tar path that fails under Docker.
#
#   The cost is speed. There is no hardware acceleration for x86 on an ARM Mac,
#   so this runs under TCG and takes HOURS, not minutes. It is a correctness
#   escape hatch, not a development loop. Iterate on arm64.
#
# Usage:  scripts/build-amd64-vm.sh [--reset]
# Output: out/os7-amd64.iso
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
VM_DIR="${REPO}/.vm-amd64"
OUT_DIR="${REPO}/out"

IMG_URL="https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img"
SUMS_URL="https://cloud-images.ubuntu.com/resolute/current/SHA256SUMS"
BASE_IMG="${VM_DIR}/base-amd64.img"
DISK="${VM_DIR}/os7-builder.qcow2"
SEED="${VM_DIR}/seed.iso"
KEY="${VM_DIR}/id_ed25519"
SSH_PORT="${OS7_VM_SSH_PORT:-2222}"
VM_CPUS="${OS7_VM_CPUS:-8}"
VM_MEM="${OS7_VM_MEM:-8192}"
DISK_SIZE="${OS7_VM_DISK:-60G}"

log() { printf '>>> %s\n' "$*"; }
die() { printf '!!! %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--reset" ]; then
	log "removing ${VM_DIR}"
	rm -rf "${VM_DIR}"
	exit 0
fi

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not found. brew install qemu"
command -v ssh >/dev/null || die "ssh not found"

mkdir -p "${VM_DIR}" "${OUT_DIR}"

# --- base image, checksum-verified -------------------------------------------
if [ ! -f "${BASE_IMG}" ]; then
	log "downloading the Ubuntu 26.04 amd64 cloud image (~900 MB, once)"
	curl -fsSL --retry 5 --retry-delay 3 -o "${BASE_IMG}.part" "${IMG_URL}"
	log "verifying checksum"
	want="$(curl -fsSL --retry 5 "${SUMS_URL}" | grep 'resolute-server-cloudimg-amd64.img' | head -1 | awk '{print $1}')"
	got="$(shasum -a 256 "${BASE_IMG}.part" | awk '{print $1}')"
	[ -n "${want}" ] || die "could not fetch the expected checksum"
	[ "${want}" = "${got}" ] || die "checksum mismatch: expected ${want}, got ${got}"
	mv "${BASE_IMG}.part" "${BASE_IMG}"
	log "checksum OK"
fi

# --- ssh key ------------------------------------------------------------------
if [ ! -f "${KEY}" ]; then
	ssh-keygen -t ed25519 -N '' -f "${KEY}" -C os7-builder >/dev/null
fi
PUBKEY="$(cat "${KEY}.pub")"

# --- cloud-init seed ----------------------------------------------------------
# The VM needs exactly what the Dockerfile installs for an amd64 target.
if [ ! -f "${SEED}" ]; then
	log "building the cloud-init seed"
	SEED_DIR="${VM_DIR}/seed"
	rm -rf "${SEED_DIR}"; mkdir -p "${SEED_DIR}"
	cat > "${SEED_DIR}/meta-data" <<-EOF
	instance-id: os7-amd64-builder
	local-hostname: os7-builder
	EOF
	cat > "${SEED_DIR}/user-data" <<-EOF
	#cloud-config
	users:
	  - name: builder
	    sudo: ALL=(ALL) NOPASSWD:ALL
	    shell: /bin/bash
	    ssh_authorized_keys:
	      - ${PUBKEY}
	package_update: true
	packages:
	  - live-build
	  - debootstrap
	  - squashfs-tools
	  - xorriso
	  - isolinux
	  - syslinux-common
	  - grub-pc-bin
	  - grub-efi-amd64-bin
	  - mtools
	  - dosfstools
	  - zstd
	  - xz-utils
	  - lz4
	  - ca-certificates
	  - curl
	  - gnupg
	  - git
	  - make
	  - rsync
	runcmd:
	  - [ touch, /var/lib/cloud/os7-ready ]
	EOF
	if command -v hdiutil >/dev/null; then
		hdiutil makehybrid -iso -joliet -default-volume-name CIDATA -o "${SEED}" "${SEED_DIR}" >/dev/null
	elif command -v genisoimage >/dev/null; then
		genisoimage -output "${SEED}" -volid CIDATA -joliet -rock "${SEED_DIR}" >/dev/null 2>&1
	elif command -v xorriso >/dev/null; then
		xorriso -as genisoimage -output "${SEED}" -volid CIDATA -joliet -rock "${SEED_DIR}" >/dev/null 2>&1
	else
		die "need hdiutil, genisoimage or xorriso to build the cloud-init seed"
	fi
fi

# --- disk ---------------------------------------------------------------------
if [ ! -f "${DISK}" ]; then
	log "creating a ${DISK_SIZE} overlay disk"
	qemu-img create -q -f qcow2 -F qcow2 -b "${BASE_IMG}" "${DISK}" "${DISK_SIZE}"
fi

# --- boot ---------------------------------------------------------------------
# TCG: there is no x86 hardware acceleration on an ARM host. thread=multi helps.
log "booting the x86_64 builder VM (TCG - slow by nature)"
qemu-system-x86_64 \
	-machine q35 -accel tcg,thread=multi \
	-smp "${VM_CPUS}" -m "${VM_MEM}" \
	-drive file="${DISK}",if=virtio,format=qcow2 \
	-drive file="${SEED}",if=virtio,format=raw,readonly=on \
	-netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
	-device virtio-net-pci,netdev=net0 \
	-device virtio-rng-pci \
	-display none -serial file:"${VM_DIR}/console.log" \
	> "${VM_DIR}/qemu.log" 2>&1 &
QEMU_PID=$!
trap 'kill "${QEMU_PID}" 2>/dev/null || true' EXIT

SSH_OPTS=(-i "${KEY}" -p "${SSH_PORT}"
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=5)

log "waiting for ssh (first boot also installs packages; allow ~10 min under TCG)"
for _ in $(seq 1 240); do
	if ssh "${SSH_OPTS[@]}" builder@127.0.0.1 true 2>/dev/null; then break; fi
	kill -0 "${QEMU_PID}" 2>/dev/null || die "VM died - see ${VM_DIR}/console.log"
	sleep 10
done
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 true 2>/dev/null || die "ssh never came up - see ${VM_DIR}/console.log"
log "ssh up"

log "waiting for cloud-init to finish installing the build tools"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 'cloud-init status --wait >/dev/null 2>&1 || true; test -e /var/lib/cloud/os7-ready' \
	|| die "cloud-init did not complete - see ${VM_DIR}/console.log"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 'command -v lb >/dev/null' \
	|| die "live-build missing in the VM - cloud-init package install failed"

log "copying the repo into the VM"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 'rm -rf ~/os7 && mkdir -p ~/os7'
tar -C "${REPO}" -cf - \
	--exclude=.git --exclude=out --exclude=.vm --exclude=.vm-amd64 . \
	| ssh "${SSH_OPTS[@]}" builder@127.0.0.1 'tar -C ~/os7 -xf -'

# The tar above excludes .git, so the VM has no repository to ask. Compute the
# source facts HERE, where the repository is, and hand them to build.sh - which
# accepts them precisely for this path. Without it every amd64 ISO would carry
# BUILD=0 and reproducible=false for a reason that has nothing to do with the
# build (docs/RELEASE-AND-UPDATE-PLAN.md §3.3).
GIT_COMMIT="$(git -C "${REPO}" rev-parse --short=12 HEAD)"
GIT_COUNT="$(git -C "${REPO}" rev-list --count HEAD)"
if [[ -n "$(git -C "${REPO}" status --porcelain)" ]]; then GIT_DIRTY=true; else GIT_DIRTY=false; fi
log "source: ${GIT_COMMIT}, build ${GIT_COUNT}$( [[ "${GIT_DIRTY}" = true ]] && echo ' (DIRTY)' )"

log "running the build in the VM (hours under TCG)"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 \
	"set -e; mkdir -p ~/out; sudo \
	   OS7_OUT_DIR=/home/builder/out \
	   OS7_VERSION_BUILD='${GIT_COUNT}' \
	   OS7_GIT_COMMIT='${GIT_COMMIT}' \
	   OS7_GIT_DIRTY='${GIT_DIRTY}' \
	   bash ~/os7/build/build.sh amd64"

# The VERSIONED artefacts, and the manifests beside them - not just the stable
# symlink. Two builds of one release are compared by diffing their manifests
# (spike S7), and an amd64 build that brought back only the ISO could not take
# part in that.
log "copying the ISO and its manifest back"
scp "${SSH_OPTS[@]}" \
	"builder@127.0.0.1:/home/builder/out/OS7-*-amd64.iso" \
	"builder@127.0.0.1:/home/builder/out/OS7-*-amd64.release.json" \
	"builder@127.0.0.1:/home/builder/out/OS7-*-amd64.packages.manifest" \
	"${OUT_DIR}/"

# Recreate the stable name the harnesses open by. build.sh makes it in the VM,
# and scp resolves symlinks rather than copying them.
VERSIONED="$(ls -1t "${OUT_DIR}"/OS7-*-amd64.iso 2>/dev/null | head -n1 || true)"
if [[ -z "${VERSIONED}" ]]; then
	log "no OS7-*-amd64.iso came back - the build did not produce one"
	exit 1
fi
ln -sfn "$(basename "${VERSIONED}")" "${OUT_DIR}/os7-amd64.iso"

log "shutting the VM down"
ssh "${SSH_OPTS[@]}" builder@127.0.0.1 'sudo poweroff' 2>/dev/null || true
sleep 5

log "done: ${VERSIONED}"
ls -lh "${VERSIONED}" "${OUT_DIR}/os7-amd64.iso"
