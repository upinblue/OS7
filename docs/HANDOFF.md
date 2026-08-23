# OS/7 — handoff

**Written 2026-08-23.** State of the repo and the next steps, in order.
Everything here runs **locally on an Apple Silicon Mac**. No cloud, no CI, no
paid services.

---

## 1. What works today

| Thing | State |
|---|---|
| `make build-arm64` | **Works.** Produces `out/os7-arm64.iso`, ~2 GB. |
| That ISO boots | **Yes.** UEFI → GRUB → casper → systemd → login prompt, in QEMU. |
| PowerShell | **Works.** Login lands at `PS /home/ubuntu>`. `Import-Module OS7` resolves by name and exports all three functions (they are stubs that throw by design). `bash` is still the login shell; `pwsh` is deliberately *not* in `/etc/shells`. |
| ZFS | **Works and is safe.** `zfs.target` reached on boot. See [SESSION-0-ZFS-VALIDATION.md](SESSION-0-ZFS-VALIDATION.md). |
| arm64 server-only split | **Works.** No GNOME/gdm3/Edge/Intune in the arm64 image. |
| `make build-amd64` | **Blocked locally.** See §3. |
| Installing to a disk | **Never done, by any means.** This is the gap. |

The ISO is a **live** image only. `os7-setup` does not exist yet — not a
skeleton, not a stub.

## 2. Do this first — spike S3

`installer/SETUP-PLAN.md` §10 Phase 0 defines four spikes and says S3 gates
everything. That is correct and nothing below changes it.

**S3: prove a ZFS-on-LUKS root can boot at all.**

No UI, no C#, no Setup code. A hand-written bash script in a QEMU VM:

1. Boot `out/os7-arm64.iso` in QEMU with a blank second disk.
2. On that disk: `sgdisk` an ESP + a LUKS partition.
3. `cryptsetup luksFormat`, open it.
4. `bpool` on its own partition, `rpool` on `/dev/mapper/os7_root`.
5. Datasets per SETUP-PLAN §4.4.
6. `unsquashfs` the ISO's `/casper/filesystem.squashfs` into the pool.
7. `zgenhostid`, write `/etc/crypttab` and `/etc/fstab`.
8. chroot in, `update-initramfs -u -k all`, `grub-install`, `update-grub`.
9. Reboot **from the disk only** and see what happens.

**Pass = the VM asks for the passphrase and reaches a login prompt from
`rpool/ROOT/os7_*`.**

Why first: if the layout cannot boot, every hour spent on Setup's screens is
wasted. If it passes, the script *is* the install sequence, and Setup becomes a
front-end over steps already proven to work.

Keep the script in `installer/spikes/s3-zfs-luks.sh`. It is throwaway in
quality but its **sequence** is the deliverable.

**Watch for:** the ZFS-on-root initramfs ordering (LUKS must open before the
pool imports), `bpool` needing conservative feature flags so GRUB can read it,
and `zgenhostid` — get the hostid wrong and the pool refuses to import on the
next boot.

## 3. amd64 — why it fails here, and the two local options

`make build-amd64` dies unpacking the base system:

```
E: Tried to extract package, but tar failed. Exit...
tar: ./etc/default: Cannot mkdir: Function not implemented
```

`Function not implemented` is `ENOSYS`. It is **not** an OS/7 bug and not the
VirtioFS problem in BUILD-NOTES #3 — it happens in a container-local path.
Docker Desktop's *syscall-translation* emulation lacks a syscall GNU tar 1.35
uses. Proven by A/B: the identical extraction exits 0 on native arm64 and 2
under amd64 emulation, while coreutils and Python's `tarfile` both work.

Still present on Docker **29.7.2**.

**Do not** work around it by swapping the extractor. That mishandles ownership,
device nodes and xattrs — you get a subtly broken rootfs instead of an honest
failure.

**Which command to run depends on the host:**

| Host | Command |
|---|---|
| **x86_64** — Intel/AMD Mac, x64 Windows, x86_64 Linux | `make build-amd64` — native and fast |
| **arm64** — Apple Silicon | `make build-amd64-vm` — full QEMU x86 VM, hours |

`make build-amd64` refuses early on a non-x86_64 host and points at the VM
target, so you cannot accidentally spend 20 minutes reaching a known failure.

The VM works because QEMU emulates a whole x86 machine rather than translating
syscalls. `scripts/build-amd64-vm.sh` does everything: fetches and
checksum-verifies the cloud image, provisions it with cloud-init, copies the
repo in over SSH, builds, and copies the ISO back to `out/`.
`make build-amd64-vm-reset` discards the VM.

Worth one minute first: Docker Desktop → Settings → General → "Use Rosetta for
x86_64/amd64 emulation on Apple Silicon" is at its default (no key in
`settings-store.json`). Flipping it selects a different emulator which may
implement the missing syscall; if it does, plain `make build-amd64` works here
again.

Until an amd64 ISO is actually built, **amd64 is unvalidated** — and since GUI
mode is amd64-only, the entire GUI path is unvalidated with it.

## 4. Traps that already cost time — read before debugging

Full detail in [BUILD-NOTES.md](BUILD-NOTES.md). The three that bite hardest:

- **#13 — hooks must be at `config/hooks/*.chroot`, FLAT.** The older
  `config/hooks/normal/` layout does not match; live-build then runs nothing,
  prints "Begin executing hooks...", and **exits 0**. `build.sh` now hard-fails
  if hooks are authored but none stage. Never conclude a hook ran because the
  build succeeded — check the image for its effect.
- **#14 — PowerShell module discovery is broken inside `chroot(2)`.** It probes
  `PSModulePath` with the character at index 1 dropped (`/opt/...` → `/pt/...`).
  Build-time only; the shipped image is fine. So no hook can test anything
  needing discovery — `Write-Host`, `Get-Module -ListAvailable`, or
  `Import-Module <name>`. Import **by path** works and is what hooks check.
- **`pwsh --version` is not a health check.** The banner, `Import-Module` by
  path and `Get-Command` are compiled into the binary and succeed while the
  whole on-disk module tree is unusable.

And the rule the whole episode argues for:

> **A diagnostic must not depend on the subsystem it is diagnosing.**

Three diagnostics here broke that rule — reporting via `Write-Host`, building
paths with `Join-Path`, printing sizes with `New-Object`, all from the modules
that would not load. Two produced a confident but **false** "the directory is
empty" reading that sent the investigation after a filesystem bug that did not
exist. Filesystem facts come from `bash`; PowerShell facts use pure .NET.

## 5. Verifying a built ISO — the fast way

Do **not** drive the boot over QEMU's serial console to check things. Bytes sent
faster than the console consumes arrive corrupted, and PSReadLine's rendering
makes capture worse; several attempts produced garbage.

Mount the squashfs and run the image's own binaries instead — fast, clean,
quotable:

```bash
docker run --rm --privileged --platform linux/arm64 -v "$PWD/out":/iso os7-build:arm64 bash -c '
  mkdir -p /mnt/iso /mnt/sq
  mount -o loop,ro /iso/os7-arm64.iso /mnt/iso
  mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq
  # inspect /mnt/sq, or run /mnt/sq/opt/microsoft/powershell/7/pwsh directly
'
```

Boot the ISO when you need to prove it *boots*; use the squashfs for everything
else.

## 6. After S3 passes

Follow `installer/SETUP-PLAN.md` §10. Phase 1 is the `os7-setup` skeleton and is
**strictly non-destructive** — walk the whole flow in a VM before anything
touches a disk. S1 (the look) and S2 (NativeAOT in the build container) are
independent of S3 and can run in any order.

Two open items not yet decided anywhere:

- **The live ISO and the setup ISO are currently the same image.** SETUP-PLAN §7
  has Setup running from the live medium. If they are meant to diverge, that
  needs deciding before Phase 1.
- **dash-to-panel / ArcMenu have no GNOME 50 build** in the resolute archive, so
  the "familiar desktop" goal is unmet on amd64. Hook 0070 logs the gap.
  Options are in BUILD-NOTES.

## 7. Repo orientation

```
build/config/auto/config          live-build config (DISTRIBUTION=resolute)
build/build.sh                    staging + orchestration; read its comments first
build/config/package-lists/       common packages
build/config/package-lists-{amd64,arm64}/   arch-specific
build/config/hooks/               common hooks, FLAT (see trap #13)
build/config/hooks-amd64/         amd64-only hooks
build/lib/arm64-efi-remaster.sh   arm64 has no live-build bootloader; this fixes it
powershell/OS7/                   the OS7 module - ONE source of truth, staged by build.sh
installer/SETUP-PLAN.md           the installer design and decisions. Authoritative.
docs/BUILD-NOTES.md               every trap found so far. Read before debugging.
```
