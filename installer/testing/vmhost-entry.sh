#!/bin/sh
# Entry point of the os7-vm image (Dockerfile.vmhost).
#
# One job beyond exec: when OS7_SWTPM=1, start a software TPM in THIS container
# before QEMU, because the two must share a unix control socket and a bind
# mount cannot carry one — Docker Desktop's Windows file sharing (gRPC-FUSE)
# refuses bind(2) on a mounted path, so the socket lives on the container's own
# filesystem and only the TPM STATE directory (/tpmstate) is a mount that
# persists across runs. The flags are run-s4.py's, found not guessed: firmware
# does not reliably send TPM2_Startup, and an un-started TPM answers every
# command with TPM_RC_INITIALIZE.
set -e
if [ "${OS7_SWTPM:-0}" = "1" ]; then
    mkdir -p /tpmstate
    swtpm socket --tpm2 \
        --tpmstate dir=/tpmstate \
        --ctrl type=unixio,path=/run/swtpm.sock \
        --flags not-need-init,startup-clear &
    i=0
    while [ ! -S /run/swtpm.sock ]; do
        i=$((i + 1))
        if [ "$i" -gt 100 ]; then
            echo "vmhost-entry: swtpm never created its control socket" >&2
            exit 1
        fi
        sleep 0.05
    done
fi
exec "$@"
