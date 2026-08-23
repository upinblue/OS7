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
| S4 | Does it survive Secure Boot, and does TPM2 unlock work | not started |

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
