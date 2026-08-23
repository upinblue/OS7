# Phase 0 spikes

Throwaway scripts that answer one question each, from
[`../SETUP-PLAN.md`](../SETUP-PLAN.md) §10 Phase 0. **None of this is `os7-setup`
and none of it should grow into it** — no UI, no error handling worth the name,
no rollback. What survives a spike is its *sequence* and what it taught, not its
code.

| Spike | Question | State |
|---|---|---|
| S1 | Does the look actually work | not started |
| S2 | Does NativeAOT build in the `os7-build` container | not started |
| **S3** | **Does a ZFS-on-LUKS root install boot at all** | **PASS 2026-08-23 (arm64)** |
| **S4** | **Does it survive Secure Boot, and does TPM2 unlock work** | **PASS 2026-08-23 (arm64)** |

## S3

```bash
./run-s3.py probe      # boot the live ISO and prove the console is drivable; writes nothing
./run-s3.py install    # blank disk -> installed ZFS-on-LUKS system
./run-s3.py boot       # boot from that disk ALONE and verify the pass criterion
./run-s3.py all        # both, in order (~25 min on Apple Silicon)
./run-s3.py reset      # discard the VM state
```

Needs `out/os7-arm64.iso` (`make build-arm64`) and `qemu-system-aarch64`.
VM state and full serial logs land in `../../.vm/s3/`, which is gitignored.
The passphrase is `os7spike` and the spike leaves the `os7` account
**passwordless** so the harness can log in — a spike affordance, not a pattern.

- [`s3-zfs-luks.sh`](s3-zfs-luks.sh) runs **inside** the live session and does
  the install. Its comments explain every non-obvious ordering constraint at the
  point where it bites; that is the deliverable.
- [`run-s3.py`](run-s3.py) runs on the **host**: builds a payload ISO, drives
  QEMU's serial console, and checks the result.
- [`../../docs/SESSION-S3-ZFS-LUKS.md`](../../docs/SESSION-S3-ZFS-LUKS.md) is
  what it proved, what it does not prove, and the eight things it depends on.

`s3-zfs-luks.sh` destroys everything on the disk it is given. It refuses the
live medium and a target with mounted partitions, and that is the extent of its
safety.

## S4

```bash
./run-s4.py sb        Secure Boot on, Microsoft keys, no TPM
./run-s4.py enroll    enrol the TPM and rebuild the initramfs
./run-s4.py auto      boot again — must NOT ask for a passphrase
./run-s4.py notpm     boot with no TPM — must ask for one again
./run-s4.py all       all four, in order
./run-s4.py reset     discard S4 state (the S3 disk is left alone)
```

Needs S3 to have run (it boots a **copy** of `.vm/s3/s3-target.qcow2`) and
`brew install swtpm`. Secure Boot firmware is fetched from the `ubuntu:26.04`
container into `../../.vm/firmware/` automatically — Homebrew's QEMU ships none
for aarch64.

**Budget an hour for `all`.** Ubuntu's AAVMF renders GRUB's 30-second countdown
on a 238-column serial console, which takes 10–15 minutes of wall time per boot.
The work itself takes seconds.

- [`s4-tpm-enroll.sh`](s4-tpm-enroll.sh) runs **inside** the installed system:
  `systemd-cryptenroll`, plus the two initramfs pieces that make the LUKS2 token
  actually get used at boot — which is the part nobody tells you about.
- [`run-s4.py`](run-s4.py) drives QEMU with `AAVMF_CODE.secboot.fd` and `swtpm`.
- [`../../docs/SESSION-S4-SECUREBOOT-TPM.md`](../../docs/SESSION-S4-SECUREBOOT-TPM.md)
  is the write-up.

## Shared

[`vmconsole.py`](vmconsole.py) holds the serial-console driving both harnesses
use: an expect loop, character-at-a-time typing, and just enough terminal
emulation to keep PowerShell alive on a line with nothing on the other end
(docs/BUILD-NOTES.md #16).
