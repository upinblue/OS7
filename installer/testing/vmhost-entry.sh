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
# The repository server for the end-to-end update test: the guest's 10.0.2.2
# is this container's own stack, so the files it must fetch are served from
# here. Read-only mount, loopback-adjacent, gone with the container.
if [ -n "${OS7_HTTP_PORT:-}" ] && [ -d "${OS7_HTTP_DIR:-}" ]; then
    python3 -m http.server "${OS7_HTTP_PORT}" \
        --directory "${OS7_HTTP_DIR}" --bind 0.0.0.0 >/dev/null 2>&1 &
fi
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
