# OS/7 build notes — harvested findings

Findings carried over from an earlier OS/7 build session (**2026-06-24**) whose
repository history was deliberately replaced by the current scaffold. That
session got as far as a **structurally bootable arm64 ISO** (~2.3 GB) before the
project was re-architected (see below).

Everything here was discovered by hitting the failure, not by reading
documentation. Each item says what breaks if you undo it. Nothing here has been
re-validated against the current scaffold.

## What was kept, and what was dropped

**Kept** — carried into this repo:

| File | Why |
|---|---|
| `build/build.sh` | The two staging fixes below (3, 6) are required for any build to work on macOS. |
| `build/lib/arm64-efi-remaster.sh` | 95 lines of GRUB/EFI work; the only reason an arm64 ISO boots at all. Verbatim. |
| `scripts/run-vm.sh` | QEMU + HVF runner for Apple Silicon, incl. the UEFI vars/pflash handling. Verbatim. |
| Fixes 1–8 below | Applied inline to `Dockerfile`, `Makefile`, `build/config/auto/config`. |

**Dropped** — deliberately not carried over:

- The **Subiquity autoinstall** path (`installer/autoinstall/user-data`,
  `installer/os7-install.sh`). The current README locks the installer to
  **Calamares**. Little was lost: that session's own handoff recorded the
  live→installer→ZFS-root integration as *not started*, so only a draft profile
  and one script went.
- Package lists, hooks and `includes.chroot` content. These encoded the older
  design (one image, GUI/headless as a **runtime** toggle). The current README
  makes GUI vs. headless an **installer-time** choice, so they need re-authoring
  rather than porting. Their transferable gotchas are recorded as 9–11 below.

## The fixes

### 1. Arch-matched build container — `Dockerfile`
GRUB bootloader binaries are architecture-specific and not cross-available from
one archive: amd64 has `grub-pc-bin` + `grub-efi-amd64-bin`, arm64 has
`grub-efi-arm64-bin`. Installing both in a single image **can never resolve**.
Key the install on `TARGETARCH`.

### 2. `zstd` / `xz-utils` / `lz4` — `Dockerfile`
`unmkinitramfs` needs them to decompress Ubuntu's zstd-compressed initrd during
`lb_binary_disk`. Without them the binary stage fails.

### 3. Never build on the bind mount — `build/build.sh`
**The most important one on macOS.** Docker Desktop shares the repo over
VirtioFS, and a Linux root filesystem cannot be faithfully extracted onto it —
device nodes, ownership and hardlinks don't survive. debootstrap fails with
`tar failed` / a missing `/usr/bin/env`. Stage into a container-local directory
(`/os7-build`, on the container's own overlayfs) and copy only the finished ISO
back to the mount.

### 4. `--debian-installer false`, not `none` — `auto/config`
This live-build rejects `none` with `flavour none not supported`. `false` is the
value that disables it.

### 5. `casper` + `boot=casper` — `auto/config` and the base package list
Ubuntu-mode live-build expects the casper initramfs at
`binary/casper/initrd.img`. Without the `casper` package in the base list **and**
`--bootappend-live "boot=casper ..."`, `lb_binary_disk` fails.

### 6. Assemble the standard live-build tree — `build/build.sh`
live-build reads, relative to the build root:

```
auto/config
config/package-lists/   config/hooks/   config/includes.chroot/
```

This repo authors them under `build/config/` (per README "Repository layout"),
so staging must re-map them. Get it wrong and live-build **silently ignores all
of them**: the build succeeds and hands you a bare Ubuntu image with no OS/7
content. There is no warning — check the ISO, not the exit code.

### 7. live-build emits no arm64 bootloader — `build/lib/arm64-efi-remaster.sh`
`lb_binary_grub2` is gated to `amd64 i386`. On arm64 live-build produces a
complete live filesystem inside an **unbootable** ISO: no `/EFI`, empty
El-Torito catalog. The remaster script builds `BOOTAA64.EFI` via
`grub-mkstandalone`, makes a FAT ESP image, and rebuilds the ISO with an EFI
El-Torito entry plus an appended `0xef` partition for USB. amd64 needs none of
this — live-build's grub/isolinux steps already produce a bootable ISO there.

### 8. No `-it` on batch targets — `Makefile`
Breaks CI with `the input device is not a TTY`. Keep it on the `shell-*` targets
only.

## Gotchas from the dropped content (still true)

### 9. Package lists don't support trailing inline comments
Every token on a non-comment line is passed to apt as a package name. Comments
must be on their own line.

### 10. Microsoft packages must be installed from a hook, not a package list
The package-list pass runs **before** any hook, i.e. before the hook that adds
the Microsoft APT repo exists. `powershell`, `code`, `edge` etc. have to be
installed in the hook itself.

### 11. There may be no Microsoft APT repo for `resolute` yet
The prior session pointed at `ubuntu/24.04/prod noble`. Packages built for noble
may hit dependency mismatches on resolute. Re-check whether Microsoft publishes
a 26.04 path before assuming this works.

## Still-open items inherited from that session

- **amd64 has never been built end-to-end.** Only arm64 reached an ISO, and
  local amd64 on Apple Silicon is emulated and slow. Native CI is the place to
  confirm it.
- **The arm64 ISO was never actually booted** — verified structurally (EFI
  El-Torito entry, `BOOTAA64.EFI`, `0xef` partition, `grub.cfg`) but not run.
- **No build cache.** `build.sh` wipes the work directory every run, so each
  build re-bootstraps and re-downloads. Fine for CI; for local iteration,
  consider persisting live-build's bootstrap/cache in a Docker volume.
- **dash-to-panel / ArcMenu are not in the resolute archive.** GNOME Shell 50
  was too new for packaged builds of either. The README's "familiar feel" goal
  needs them vendored in-repo or pulled from extensions.gnome.org at build time.
