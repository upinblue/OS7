# Session 0 — ZFS-on-kernel-7.0 validation

Answers README **Open Question #1**: is the OpenZFS
[#18488](https://github.com/openzfs/zfs/issues/18488) warning present on Ubuntu
26.04, and is ZFS root safe enough to build OS/7 on?

**Date:** 2026-08-22 · **Method:** clean Ubuntu 26.04 cloud images booted in
QEMU (arm64 native/HVF, amd64 emulated/TCG), driven by cloud-init. Both arches
tested independently and agreed on every result.

## Verdict

| Question | Answer |
|---|---|
| Is the warning present? | **Yes** — on both arches, unchanged. |
| Does it indicate a real defect? | **No** — it marks build *provenance*, not a known bug. Confirmed by both the OpenZFS and Ubuntu ZFS maintainers on the issue. |
| Safe enough to build OS/7 on? | **Yes, with one thing to track** (see "The catch"). |

## What was actually observed

Environment: `Ubuntu 26.04 LTS (Resolute Raccoon)`, kernel
**`7.0.0-28-generic`**, ZFS **`2.4.1-1ubuntu5`**.

Note the kernel is `-28`, not the `-15` in the upstream issue — so this is not a
stale report. The warning still fires on a current 26.04 kernel, in the exact
text the README cites:

```
ZFS: Using ZFS with kernel 7.0.0-28-generic is EXPERIMENTAL and SERIOUS DATA LOSS may occur!
```

Present in both `dmesg` and `journalctl -b`, emitted at module load, on **amd64
and arm64 alike**.

Two README requirements were confirmed satisfied at the same time:

- The module is the **GA-kernel-matched prebuilt** one —
  `/lib/modules/7.0.0-28-generic/kernel/zfs/zfs.ko.zst`, vermagic
  `7.0.0-28-generic`. Kernel and ZFS do ship in lockstep.
- **`zfs-dkms` is not installed**, and is not pulled in by `zfsutils-linux`.
- Userland and kmod versions match exactly (`zfs-2.4.1-1ubuntu5` /
  `zfs-kmod-2.4.1-1ubuntu5`) — no version skew.

## Functional test — it works

Beyond reading the log line, a real pool was exercised on a spare 4 GB disk.
Identical results on both architectures:

| Step | Result |
|---|---|
| `zpool create` | exit 0, pool `ONLINE` |
| Write 512 MB of random data | exit 0 |
| `zpool export` / `zpool import` | exit 0 / exit 0 |
| `zpool scrub` | `repaired 0B ... with 0 errors` |
| SHA-256 before vs. after | **identical** |
| READ / WRITE / CKSUM counters | **0 / 0 / 0**, `No known data errors` |
| `zfs snapshot` + `zfs rollback` | exit 0, checksum restored intact |
| `dmesg` during real I/O | no ZFS complaints beyond the load-time banner |

The snapshot/rollback result matters specifically: that pair is the primitive
`Update-OS7` and `Restore-OS7` are built on, and it behaved correctly.

## What the warning actually means

The issue is **closed as completed**. From the discussion:

- **OpenZFS maintainer (`robn`)** — there is no *official* OpenZFS release
  supporting 7.0 kernels, and the warning exists to say the build is not an
  official release and hasn't had the same testing and review. They add that it
  is probably fine, since vendors don't tend to patch OpenZFS in breaking ways.
  The warning was written for exactly this case: telling users a packager did
  something unusual.
- **Ubuntu's ZFS maintainer (`john-cabaj`)** — Ubuntu chose a 7.0 kernel for
  26.04 knowing OpenZFS wouldn't officially support it by release. The packaged
  2.4.1 **already carries the upstream Linux 7.0 compatibility patches**. The
  modules are built against Ubuntu kernels and regression-tested on package
  upload. The warning appears because building outside OpenZFS's blessed kernel
  range requires a Makefile "experimental" hook, which is what Ubuntu used.

So: a support-status marker, not evidence of corruption. That matches what the
functional test found.

## The catch — the warning is now stale, and Ubuntu hasn't caught up

Upstream added official 7.0-kernel support months ago, but 26.04 has not
received it:

| Release | zfs-linux version | Officially supports kernel 7.0? |
|---|---|---|
| **resolute (26.04 LTS)** | `2.4.1-1ubuntu5` — **Release pocket only, no `-updates`** | No — hence the warning |
| stonking (26.10) | `2.4.2-2ubuntu4` (Release), `2.4.3-3ubuntu1` (Proposed) | Yes |

Upstream OpenZFS shipped 7.0 support in **2.4.2 on 2026-05-12** (PRs
[#18462](https://github.com/openzfs/zfs/pull/18462),
[#18451](https://github.com/openzfs/zfs/pull/18451)); 2.4.3 followed in June and
2.4.4 on 2026-08-21.

Ubuntu's ZFS maintainer stated on the issue that an amended SRU process is being
worked on, and that the 26.10 ZFS version would likely be backported to earlier
releases, 26.04 included.

**What to watch:** the appearance of a `zfs-linux` version ≥ `2.4.2` in
**`resolute-updates`**. Today that pocket has no `zfs-linux` entry at all. When
it lands, the warning goes away on its own and this question closes fully.

## Recommendation for OS/7

**Proceed with ZFS root.** The locked Storage decision stands. Rationale:

1. No functional defect was reproducible — every integrity check passed on both
   architectures.
2. The mechanism behind the warning is understood and maintainer-confirmed.
3. Canonical ships this as the ZFS in an LTS and regression-tests it; OS/7 is
   not doing anything Ubuntu itself isn't doing.
4. The fix exists upstream and is expected to reach 26.04 by SRU.

Carry these caveats:

- **The warning will be visible to OS/7 users** in `journalctl` until the SRU
  lands. For an OS aimed at IT admins, that log line will get noticed and asked
  about. Plan a release-note line; do **not** patch the warning out — it is
  accurate about the support status.
- **Do not switch to `zfs-dkms`** to chase a newer ZFS. That breaks the locked
  "kernel and ZFS in lockstep" property and trades a cosmetic warning for a real
  class of failure (module build failures on kernel update).
- **Re-test after any 26.04 kernel SRU.** The ZFS module is kernel-matched, so a
  kernel bump is also a ZFS-module bump.
- **`Update-OS7` / `Restore-OS7` remain unblocked** — snapshot and rollback both
  verified working.

## Reproducing

Cloud images from `https://cloud-images.ubuntu.com/resolute/current/`
(checksum-verified against `SHA256SUMS`), booted with a NoCloud cloud-init seed
that installs `zfsutils-linux`, loads the module, greps `journalctl -b`, then
runs the pool/scrub/snapshot test and powers off. arm64 runs natively under HVF
in about a minute; amd64 runs under TCG emulation and takes appreciably longer.
