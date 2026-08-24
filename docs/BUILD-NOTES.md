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

---

# Build status — 2026-08-22

First end-to-end build attempt against this scaffold.

| Target | Result |
|---|---|
| `lb config` | **Passes.** live-build `3.0~a57-1`; `ubuntu:26.04` ships a `resolute` debootstrap script, so the newer build base works. |
| `make build-arm64` | **Produces a bootable ISO** — `out/os7-arm64.iso`, 1.4 GB. |
| arm64 ISO boots? | **Yes.** UEFI → `BOOTAA64.EFI` → GRUB 2.14 → kernel → casper → systemd → `serial-getty`. Verified in QEMU/HVF. |
| `make build-amd64` | **Blocked locally** on Apple Silicon. See below. |

This closes the prior session's open item 3 ("arm64 UEFI boot — real test pending"): the remaster script's output does boot, not merely validate structurally. The ISO carries an El Torito UEFI entry pointing at `/boot/grub/efiboot.img` plus an `0xef` MBR partition for USB.

Two incidental findings:

- **`casper` came in on its own.** Harvested fix 5 warned it must be in the base package list. With `--mode ubuntu` live-build pulls it in by default, so the missing package list was not fatal here. The `--bootappend-live "boot=casper ..."` half is still required.
- **`casper-md5check.service` fails on the arm64 ISO.** Expected: the remaster rebuilds the ISO *after* live-build generates the checksums, so they no longer match. Harmless, but it is a visible red `[FAILED]` at boot — regenerate the checksums inside the remaster step before shipping anything to users.

## What the arm64 ISO actually contains

348 packages — a bare Ubuntu 26.04 live system, exactly as the stub `auto/config`
predicts. Confirmed absent: `zfsutils-linux`, `zfs-initramfs`, `powershell`,
`dotnet-sdk`, `authd`, `authd-msentraid`, `calamares`, `gnome-shell`,
`microsoft-edge-stable`.

So the build *pipeline* works end to end; only the OS/7 *content* is missing.
That content is the next unit of work, and it needs the installer-time
GUI/headless split designed first.

## 12. amd64 cannot be built on Apple Silicon (host limitation, not a config bug)

`make build-amd64` fails at the first debootstrap extraction:

```
I: Extracting base-files...
E: Tried to extract package, but tar failed. Exit...
```

This looks like harvested fix 3 (the VirtioFS problem) but **is not**. The real
error, in a *container-local* path:

```
tar: ./etc/os-release: Cannot open: Function not implemented
tar: ./usr/share/common-licenses/GPL: Cannot create symlink to 'GPL-3': Function not implemented
```

`Function not implemented` is `ENOSYS`. Isolated with four tests:

| Test — identical command and image definition | Result |
|---|---|
| Extract in native **arm64** container | exit 0 |
| Extract in emulated **amd64** container | exit 2, `ENOSYS` |
| `mkdir -p` / `touch` / `ln -s` in emulated amd64 | all fine |
| Python `tarfile` on the same archive, emulated amd64 | fine |

The filesystem and ordinary syscalls work. **GNU tar 1.35's** extraction path
(almost certainly `openat2`) is what Docker Desktop's x86-on-ARM emulation does
not implement — GNU tar fails even on an archive it just created itself.

**Do not work around this by replacing `tar`.** A Python or busybox extractor
mishandles ownership, device nodes and xattrs, which is precisely what a root
filesystem depends on; the result is a subtly broken ISO instead of an honest
failure.

**Re-tested on Docker 29.7.2 (2026-08-23): still broken, identical error.** Do
not expect a Docker update to fix it.

### How to actually build amd64

| Host | What to do |
|---|---|
| **x86_64** — Intel/AMD Mac, x64 Windows, x86_64 Linux | `make build-amd64`. Native, fast, nothing special needed. |
| **arm64** — Apple Silicon | `make build-amd64-vm`. Full QEMU x86 VM. |

`make build-amd64` now refuses early on a non-x86_64 host rather than spending a
Docker build to reach a known failure. Override with
`OS7_FORCE_EMULATED_AMD64=1` if you want to re-test the emulation.

**Why the VM works when Docker does not:** QEMU emulates a whole x86 machine
running a real x86 kernel, so no syscall translation happens and the gap does
not exist. Proven locally — the Session 0 amd64 VM installed ZFS packages fine,
which is exactly the dpkg/tar path that fails under Docker.

The cost is speed: there is no hardware acceleration for x86 on an ARM host, so
it runs under TCG and takes **hours**. It is a correctness escape hatch, not a
development loop — iterate on arm64, which is native and fast.

`scripts/build-amd64-vm.sh` handles it: downloads and checksum-verifies the
Ubuntu 26.04 amd64 cloud image, seeds it via cloud-init with the same packages
the Dockerfile installs, copies the repo in over SSH, runs `build/build.sh
amd64`, and copies `out/os7-amd64.iso` back. `make build-amd64-vm-reset` throws
the VM away.

**Also worth trying, one minute:** Docker Desktop → Settings → General → "Use
Rosetta for x86_64/amd64 emulation on Apple Silicon". No key for it exists in
`settings-store.json`, so it is at the default; flipping it selects a different
emulator that may implement the missing syscall. If that ever works, plain
`make build-amd64` becomes viable on Apple Silicon again.

## 13. Hooks live at `config/hooks/*.chroot` — FLAT, not `config/hooks/normal/`

**A silent failure, and the most expensive kind: the build succeeds anyway.**

live-build `3.0~a57-1` globs local hooks at:

```
config/hooks/*.chroot          # lb_chroot_hooks, line ~87
```

The older Debian live-build layout — `config/hooks/normal/` — does **not**
match. When nothing matches, live-build prints `Begin executing hooks...`, runs
nothing, and exits 0. `lb_chroot_hooks` and `lb_chroot_hacks` land on the same
timestamp; that one-second gap is the only visible symptom.

Cost when this bit on 2026-08-22: a full arm64 build produced a 1.7 GB ISO that
looked fine. Package lists had worked (ZFS, `authd`, `dotnet-sdk-10.0`, `casper`
all present across 523 packages), so the image was plausible. But **every hook
had been skipped** — no PowerShell, no Microsoft repos, no Azure tooling, and no
OS7 module verification. Proven by `azcmagent` and `azure-cli` being absent from
`casper/filesystem.manifest`: those come only from hook 0040.

Note this very likely bit the June-2026 session too — that tree also used
`config/hooks/normal/`. Its handoff describes hook behaviour (repo setup, `GAP:`
logging) that probably never actually executed. Treat any claim about hook
effects from that session as unverified.

`build.sh` now hard-fails if hooks are authored but none land at
`config/hooks/*.chroot`. Do not remove that guard: live-build will not warn you.

**Verification habit this argues for:** never conclude a hook worked because the
build exited 0. Check for its *effect* — a package it installs, a file it
writes — in the produced image.

## 14. PowerShell module discovery is broken inside `chroot(2)`

**Build-time only. Not an OS/7 defect — do not "fix" it in the image.**

Under `chroot`, PowerShell mangles every `PSModulePath` entry, dropping the
character at **index 1**:

```
/root/.local/share/powershell/Modules  ->  /oot/.local/share/powershell/Modules
/usr/local/share/powershell/Modules    ->  /sr/local/share/powershell/Modules
/opt/microsoft/powershell/7/Modules    ->  /pt/microsoft/powershell/7/Modules
```

It therefore finds nothing and reports *"no valid module file was found in any
module directory"*. `$env:PSModulePath` itself reads back **correctly** — only
discovery mangles it.

Proven, not inferred: creating the mangled path
`/pt/microsoft/powershell/7/Modules` as a symlink to the real one made
`Get-Module -ListAvailable` return all 10 modules and `Write-Host` work
immediately.

The trigger is `chroot(2)` itself. Same binary, same filesystem: works
unchrooted, fails chrooted, regardless of environment or working directory.
Since live-build runs **every** hook inside a chroot, no hook can test anything
that needs module discovery.

Verified on Docker Desktop / macOS arm64. Not yet re-checked on a native Linux
builder.

**Confirmed non-chrooted, against the shipped image (2026-08-23).** Running the
ISO's *own* pwsh from the mounted squashfs, outside any chroot:

```
PSHOME        = /mnt/sq/opt/microsoft/powershell/7
ListAvailable = 10
Write-Host    : OK (Utility loaded by NAME)
Import-Module OS7 by NAME: OK
OS7 exports   = Restore-OS7, Set-OS7Mode, Update-OS7
Update-OS7 throws as designed: NotImplementedException
```

The booted ISO independently agrees: it reaches a working `PS /home/ubuntu>`
prompt with PSReadLine (itself an on-disk module) active. The image is correct;
only chroot is affected.

Note on method: driving the boot over QEMU's serial console proved unreliable -
bytes sent faster than the console consumes arrive corrupted, and PSReadLine's
rendering makes capture worse. Mounting the squashfs and running the image's own
binaries is faster and gives clean, quotable output. Prefer it.

### What this means for hooks

Test what *works* in a chroot, and say plainly what doesn't:

| Works in chroot | Does NOT work in chroot |
|---|---|
| `Import-Module <full path>` | `Import-Module <name>` |
| `Get-Command -Module X` | `Get-Module -ListAvailable` |
| Compiled-in Core cmdlets | Anything from an on-disk module (`Write-Host`, `Join-Path`, `New-Object`, …) |

Hooks 0020 and 0060 hard-fail on the left column and only *note* the right one.

### The trap that cost the most time

**`pwsh --version` is not a health check.** The version banner,
`Import-Module` by path and `Get-Command` are compiled into the binary, so they
succeed while the entire on-disk module tree is unusable. The failure surfaces
much later as a confusing `The term 'Write-Host' is not recognized`.

### The rule this argues for

**A diagnostic must not depend on the subsystem it is diagnosing.**

Three separate diagnostics here were confounded by exactly that, each sending
the investigation somewhere wrong:

1. reported through `Write-Host` — from `Microsoft.PowerShell.Utility`
2. built a path with `Join-Path` — from `Microsoft.PowerShell.Management`
3. printed file sizes with `New-Object` — `Utility` again

(2) and (3) produced a confident but **false** "the directory is empty" reading,
which sent the hunt after a filesystem/extraction bug that never existed. The
directory always had its file; the *printing* was what failed.

Filesystem facts now come from `bash` (`ls`, `find`). PowerShell facts use pure
.NET (`[Console]::WriteLine`, `[System.IO.*]`) only.

### Ruled out — don't re-test these

`dotnet-sdk-10.0`; `--privileged`; globalization / ICU invariant mode; the
module analysis cache; working directory; incomplete tar extraction (the tree is
byte-identical to a healthy install: 580 files, 10 modules).

**`/dev/urandom` is a real and separate hazard**, though it was not this bug:
without it .NET's `Guid.NewGuid()` throws `CryptographicException` and
PowerShell dies at startup. live-build's chroot has a working `/dev/urandom`,
but hook 0020 keeps a cheap guard because the failure mode is so obscure.

---

## 15. A ZFS root needs `boot=zfs`, and nothing puts it there for you

Found while writing spike S3 ([SESSION-S3-ZFS-LUKS.md](SESSION-S3-ZFS-LUKS.md)).
An installed system whose command line says only
`root=ZFS=rpool/ROOT/<be>` **will not boot** — it drops to an initramfs prompt.
Three separate pieces have to agree, and none of them supplies the missing one:

| Piece | What it does |
|---|---|
| `initramfs-tools` `/init` | Defaults to `BOOT=local`. Sets `BOOT` only from a `boot=` on the command line (plus one NFS special case). |
| `scripts/local` | Has **no ZFS handling at all** — `grep -i zfs` finds nothing. |
| `scripts/zfs` | Is the ZFS root logic. Its own header: *"Enable this by passing `boot=zfs` on the kernel command line."* |
| `grub.d/10_linux_zfs` | Emits `root=ZFS="<dataset>" ro` plus `$GRUB_CMDLINE_LINUX`. Does **not** emit `boot=zfs`. |

So it must come from `GRUB_CMDLINE_LINUX` in `/etc/default/grub`.

Two consequences worth carrying forward:

* **It also fixes the LUKS ordering** the handoff flagged as a risk.
  `/scripts/zfs`'s `pre_mountroot()` runs `/scripts/local-top` before importing
  anything, and `local-top/cryptroot` is what prompts for the passphrase — so
  the unlock always precedes the import. No sequencing work needed.
* **Do not also pin `root=ZFS=` there.** `10_linux_zfs` emits one per boot
  environment; anything appended via `GRUB_CMDLINE_LINUX` lands after it and
  wins, so every entry in the menu boots the same dataset. It boots fine, which
  is what makes it dangerous.

## 16. Driving a serial console: Enter is CR, and silence kills PowerShell

HANDOFF §5 says not to drive a boot over QEMU's serial console. That is right
about *typing*, and `installer/spikes/run-s3.py` shows what it takes to do it
anyway — reading freely, typing one character at a time, re-sending a step whose
acknowledgement never arrives.

**Enter is `\r`, not `\n`.** The console lands in PowerShell (hook 0050) and
PSReadLine reads raw *keys*: LF is not the Enter key. Commands sent with `\n`
accumulated into a single line that was never submitted — **while the echo of
them still matched what the harness was waiting for.** The run reported success
for a command that never ran. Two rules fall out:

* send `\r`; a getty in canonical mode accepts it too, so it is right everywhere;
* never expect a marker the typed command itself contains — split it
  (`echo OS7-"READY"`) so the echo cannot be mistaken for the output.

**Unanswered terminal queries kill the session.** With nothing on the far end of
the line, PSReadLine's startup DSR/OSC probes go unanswered and pwsh exits
within a second of printing its prompt; agetty respawns a fresh `login:`.
Answering DSR, DA and OSC 10/11 keeps it alive. **This is a product finding, not
just a test-rig one** — OS/7 ships PowerShell as its interactive shell, and
`installer/SETUP-PLAN.md` §7 wants `os7-setup --serial` on `ttyAMA0`.

**Answer the size probe honestly.** A program measures the terminal by parking
the cursor at 32766;32766 and asking where it landed. Replying `ESC[24;1R` says
"one column wide" and casper's `apt` step then hangs forever. Reply
`ESC[24;80R`, and arm the responder only once the login prompt appears so a
wrong answer can never wedge the boot itself.

## 17. `chpasswd` cannot set a password inside a chroot on this image

```
chpasswd: (user os7) pam_chauthtok() failed, error:
Failed preliminary check by password service
```

`common-password` runs `pam_authd_exec.so`, and authd's helper cannot work in a
chroot. **Anything that sets a password through PAM fails there.** `passwd -d`
and writing the crypt hash directly both bypass PAM and work.

Related, and easy to miss: **the squashfs contains no users at all.** casper
creates the live `ubuntu` account at boot, in the overlay, so none of it
survives into an install. An installer that forgets to create one produces a
system that boots perfectly to a login prompt nobody can get past.

## 18. `mount --make-private --rbind` is not enough for an installer chroot

`zpool export` after an install fails with

```
cannot export 'rpool': pool is busy
```

while **nothing is mounted under the target**, no process has a cwd or root
inside it, and `zpool export -f` fails identically.

`--make-private` makes the *new* mount private **after the fact**. By then the
`--rbind` of `/dev`, `/proc` and `/sys` has already propagated to every peer of
the live system's shared root, including mount namespaces owned by systemd
services. Unmounting in your namespace leaves live copies in theirs, and those
hold the pool; `-f` cannot force what your namespace can no longer see.

Do the bind mounts and the `chroot` inside
`unshare --mount --propagation private` instead. Nothing propagates out, and
every mount vanishes when the namespace exits — no teardown to get wrong. See
`installer/spikes/s3-zfs-luks.sh` step 8.

## 19. `systemd-cryptenroll` alone does nothing at boot on this image

Found in spike S4 ([SESSION-S4-SECUREBOOT-TPM.md](SESSION-S4-SECUREBOOT-TPM.md)).
`systemd-cryptenroll --tpm2-device=auto` succeeds and writes a valid LUKS2
token — and the next boot asks for the passphrase exactly as before, with no
error to explain why. Two independent reasons, either of which is sufficient:

* the stock `cryptsetup-initramfs` hook copies `cryptsetup`, `dmsetup`,
  `askpass` and `sed`, and **no token handler** — `grep -i tpm2` over the hook
  and its boot script returns nothing at all;
* `local-top/cryptroot` feeds a passphrase to `cryptsetup open` on stdin, and
  supplying key material is what makes cryptsetup skip token activation.

Closing it takes two pieces, both in `installer/spikes/s4-tpm-enroll.sh`:
a hook that carries `libcryptsetup-token-systemd-tpm2.so`, and a `local-top`
script that runs **before** `cryptroot` and calls
`cryptsetup open --token-only`. `--token-only` never falls back to a passphrase
itself, so a machine with no TPM lands in cryptroot's normal prompt — the
recovery path is a property of the flag, not an afterthought.

The name matters: `initramfs-tools` orders `local-top` with
`get_prereq_pairs | tsort`, which for scripts with no prereqs falls back to the
directory glob. `00os7tpm2` is what puts it ahead of `cryptroot` — and the
generated `ORDER` is worth checking rather than trusting, because `tsort` is not
pure alphabetical once any prereqs exist.

## 20. `copy_exec` cannot see a dlopen — systemd's TPM stack is dlopened

The same spike, and the trap most likely to recur. `copy_exec` resolves ELF
`NEEDED`, which is not how systemd loads optional features:

```
$ objdump -p libcryptsetup-token-systemd-tpm2.so | grep NEEDED
  NEEDED   libsystemd-shared-259.so
  NEEDED   libcryptsetup.so.12
  NEEDED   libc.so.6
```

`libsystemd-shared` does not link the TPM stack either. It dlopens it, and
advertises exactly that in its own metadata:

```
[{"feature":"tpm","description":"Support for TPM","priority":"suggested",
  "soname":["libtss2-esys.so.0"]}]
```

Result: an initramfs containing the token handler and **no libtss2 at all**,
which fails at boot with nothing useful on the console. Any hook putting
systemd functionality in an initramfs has to name the dlopened libraries:
`libtss2-esys.so.0`, `libtss2-mu.so.0`, `libtss2-rc.so.0`, and
`libtss2-tcti-device.so.0` one level further down (systemd builds the string
`device:/dev/tpmrm0` and dlopens the TCTI backend itself — it never calls
`Tss2_TctiLdr_*`, so `libtss2-tctildr` is **not** on this path).

## 21. Homebrew's QEMU has no Secure-Boot firmware for aarch64

`$(brew --prefix qemu)/share/qemu/` has `edk2-i386-secure-code.fd` and
`edk2-x86_64-secure-code.fd` — and for aarch64 only `edk2-aarch64-code.fd`, with
no secure variant and no vars template at all (`scripts/run-vm.sh` and
`run-s3.py` fall back to `edk2-arm-vars.fd`).

Ubuntu's `qemu-efi-aarch64` package has what is needed:
`AAVMF_CODE.secboot.fd` plus `AAVMF_VARS.ms.fd` with the Microsoft KEK/db
pre-enrolled. `installer/spikes/run-s4.py` pulls it out of the `ubuntu:26.04`
container into `.vm/firmware/` on first use.

Two things to know before using it:

* **It is slow.** AAVMF drives a 238-column serial console, and GRUB's
  30-second `recordfail` countdown takes 10–15 minutes of wall time to render
  over it. That is per boot.
* **arm64 has no SMM**, so the Secure Boot variable store is not tamper-proof
  the way it is on x86. Signature enforcement is real; the threat model is
  weaker. A platform property, not a configuration mistake.

## 22. `LibraryImport` only marshals blittable types — `termios` needs a `fixed` buffer

Found in spike S2 ([SESSION-S2-NATIVEAOT.md](SESSION-S2-NATIVEAOT.md)), and it
lands squarely on `Native/Termios.cs` in SETUP-PLAN §6.5.

`struct termios` carries `cc_t c_cc[NCCS]`. Declared the obvious way —

```csharp
[MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]
public byte[] Cc;
```

— the build fails:

```
SYSLIB1051: The type 'Termios' is not supported by source-generated P/Invokes.
SYSLIB1062: LibraryImportAttribute requires unsafe code.
```

The `LibraryImport` source generator handles blittable types only. Use a
`fixed byte Cc[32]` inside an `unsafe struct`, and set
`<AllowUnsafeBlocks>true</AllowUnsafeBlocks>`.

The older `[DllImport]` accepts the array form — and gives up the generated,
AOT-friendly marshalling that is the entire reason to prefer `LibraryImport`.
Take the fixed buffer.

(The layout is the same on both target arches: four 4-byte flag words, `c_line`,
32 control chars, two 4-byte speeds — 60 bytes.)

## 23. amd64 .NET builds work under emulation, even though amd64 ISO builds do not

#12 says Docker's amd64 emulation on Apple Silicon cannot unpack a Debian
rootfs, so `make build-amd64` is unavailable here. It is easy to generalise that
into "nothing amd64 can be built on this machine". **That is wrong.**

Spike S2 published a working `linux-x64` NativeAOT binary in `os7-build:amd64`
on an Apple Silicon Mac, with zero warnings. The `ENOSYS` in #12 is specific to
what GNU tar does during debootstrap; ordinary compilation is unaffected.

Consequence: `os7-setup` can be built and iterated for **both** architectures
locally, long before an amd64 ISO exists. Phase 1 is not blocked by #12.

## 24. `otf2bdf` exits non-zero on Fixedsys Excelsior while producing a correct BDF

Found in spike S1 ([SESSION-S1-LOOK.md](SESSION-S1-LOOK.md)) while building the
console font (SETUP-PLAN §2.5).

```
otf2bdf -p 16 -r 72 -n -o out.bdf FSEX302.ttf   ; echo $?
8
```

The BDF is **complete and correct**: 6 192 glyphs declared, 6 192 written, the
file ends with `ENDFONT`, and the glyphs the UI draws are byte-for-byte what the
outlines say they should be. Exit 8 comes back at every point size tried — 8,
12, 15, 16, 17, 24, 32 — and the same command on Liberation fonts returns 0. Not
root-caused; the failure is specific to this font, not to the size or the flags.

`set -e` in a build script turns that into a build that stops for no reason.
Suppressing it and moving on turns it into a build that never notices a real
truncation. `build/lib/build-console-font.sh` does neither: it ignores the status
and asserts the artefact — declared `CHARS` equals the blocks actually written,
the file is terminated, and `psf.py verify` then requires every glyph the UI
draws to be present and non-blank.

The rule this is an instance of is already in this file: **a diagnostic must be
checked against the thing it claims to check.** An exit code is a diagnostic.

## 25. `setvtrgb.service` silently replaces the console palette set on the kernel command line

Found in spike S1. This is the one that would have cost a Phase 1 session.

SETUP-PLAN §2.1 sets the OS/7 palette with `vt.default_red/grn/blu` on the
Install entry — "from the first kernel frame". Ubuntu ships `setvtrgb.service`
**enabled** in `sysinit.target.wants`:

```
ExecStart=/sbin/setvtrgb /etc/vtrgb          # -> /etc/console-setup/vtrgb
```

It runs at ~11.8 s. `fbcon: Taking over console` happens at ~14.0 s. So the
command-line palette is replaced **before anything is ever displayed with it** —
there is no window in which it is visible, and no error anywhere.

What it looks like when you hit it: the screen comes up in colours that are
obviously *a* palette rather than the default VGA one, so the natural conclusion
is "the parameters are wrong" and the natural next step is to fiddle with them.
`/sys/module/vt/parameters/default_red` shows the replaced values, not the
command line's, which makes it look as though the kernel never took them.

The fix is a file, not a parameter: ship OS/7's palette as `/etc/vtrgb`. It is
also the better mechanism — one file serves Setup and the installed console
(SETUP-PLAN D6), and `setvtrgb` accepts a legible hex form:

```
#000000
#AA0000
...       16 lines of #RRGGBB
```

To see what the kernel parameters alone do, boot with
`systemd.mask=setvtrgb.service`.

**Related, same session:** `vt.color=0x4f` is accepted, reads back correctly from
`/sys/module/vt/parameters/color`, and has no observable effect on the default
attribute — four different values all produced palette index 1. Do not rely on
it; paint every cell explicitly.

**Also related:** on a truecolor framebuffer, changing the palette does **not**
retint pixels already drawn — each cell was resolved to RGB when it was written.
A palette switch is a palette switch *and* a full repaint.

## 26. `bdf2psf`'s stock equivalences collapse the double-line box onto the single-line one

Found in spike S1.

`bdf2psf` takes an equivalents file listing codepoints that may share one PSF
position. `/usr/share/bdf2psf/standard.equivalents` states its own rule: *when
the source font supports several symbols from a class, the last supported symbol
is used.* Line 217 is

```
U+2550 U+254D U+254C ... U+2501 U+2500
```

so `U+2550 ═` is given the glyph of `U+2500 ─`. Built that way,
`╔═╦═╗╠╬╣╚╩╝║` renders **byte-identical** to `┌─┬─┐├┼┤└┴┘│`.

The file exists for fonts that lack the rarer glyph and can only approximate it.
Fixedsys Excelsior has the real ones — `U+2550` is `FF 00 FF`, two rules — so
applying it is pure loss.

**No coverage check can see this.** The codepoint *is* mapped, to the wrong
picture, so every count comes back 128/128. The only guard is not creating the
problem: `build/lib/psf.py` drops any equivalence class touching a codepoint OS/7
requires, and `psf.py verify` asserts nine pairs of shapes that must stay
distinct.

## 27. Fixedsys Excelsior draws 15 pixels of ink in a 16-pixel cell

Found in spike S1. Read out of `FSEX302.ttf` in font units (`unitsPerEm` 160,
so 10 units = 1 pixel):

```
hhea      ascender 130, descender -30     ->  a 16 px line
U+2588 █  y -30 .. 120                    ->  15 px of ink
U+2580 ▀  y  40 .. 120    U+2584 ▄  y -30 .. 50
```

The em is 16 and the ink is 15, so **the top row of every cell is empty**. The
font is right about itself — Windows' Fixedsys is an 8×15 face — and wrong for a
console, where the cell *is* the character.

Left alone, every vertical box border comes out dashed with a one-pixel gap at
each cell boundary, and a progress bar never touches the top of its row. On the
pixel-doubled 16×32 it is a two-pixel gap.

`psf.py fillcell` closes it, only inside Box Drawing and Block Elements:

```
row1 == row2  ->  row0 := row1      a stroke or fill continuing upward
row1 == row3  ->  row0 := row2      a two-row shading pattern
otherwise     ->  leave it alone
```

Everything that must not grow is a no-op under that rule — `┌` and `▄` have an
empty row 1, so the first case copies empty onto empty — and letters are out of
range entirely, which matters: `Ä` has its diaeresis in row 1 and would otherwise
have gained a third row of dots.

**Also:** the font is not monospaced across its cmap. 4 230 glyphs advance 8 px,
1 575 advance more, 346 advance 0, so `otf2bdf` reports `SPACING "P"` with
`AVERAGE_WIDTH 77` and `bdf2psf` refuses the file: *"the width is not integer
number."* `psf.py fixedwidth` drops everything that is not exactly one cell wide.
That is not a workaround for the message — a 16-pixel glyph has nowhere to go in
an 8-pixel cell, and keeping it hands `bdf2psf` something to truncate.

## 28. `hdiutil makehybrid` keeps only ONE dot per filename

Found in spike S1, and it costs a boot cycle every time.

The spike harnesses build their payload volume with

```
hdiutil makehybrid -iso -joliet -default-volume-name OS7S1 -o payload.iso stage/
```

`os7-fixedsys-16x32.psf.gz` arrives in the guest as **`os7-fixedsys-16x32psf.gz`**.
The rest of the name survives; only the extra dot is dropped. `setfont` then says

```
setfont: ERROR ... Unable to find file: /mnt/fonts/os7-fixedsys-16x32.psf.gz
```

about a path that is right in every listing on the host.

Keep payload filenames to a single dot. `run-s1.py` decompresses the fonts onto
the volume for exactly this reason, and its `ready` step prints the directory
rather than only reporting "mounted" — the mangled name is visible there and
nowhere else.

## 29. .NET's `Console` input stream cannot be used for raw-mode key reading

Found in spike S1, and it lands on `Native/` in SETUP-PLAN §6.5.

With the terminal put into raw mode by `tcsetattr` and input read through

```csharp
using var stdin = Console.OpenStandardInput();
int b = stdin.ReadByte();
```

the reader returned **exactly one byte and then reported end of input**, on a tty
that was open and had keys arriving. .NET's console stream carries its own
terminal handling and applies termios settings of its own; a raw-mode reader
sitting on top of a layer that also wants to configure the terminal is not raw.

Read with `read(2)` through `LibraryImport` instead, and retry on `EINTR`.
§6.2 already puts key decoding on `DllImport("libc")` — this is the reason.

**And drain the queue before the first read.** Whatever was typed before the
screen appeared was not aimed at what is on it. S1 found a stray LF sitting in
the queue at start-up and spending itself on the first expected keypress, which
shifted every comparison after it by one. Drain with `VMIN=0`/`VTIME=0`, then set
`VMIN=1` and start.


## 30. On the Linux console, a bright foreground leaves BOLD set — and the next colour inherits it

Found in spike S1, on the one screen where it could be found: the progress bar.

`ESC[90m`–`ESC[97m` are not "colour 8-15". On the Linux console they are
**"colour n−90, AND bold"**, and the bold half is *sticky*. A later `ESC[36m`
sets colour 6, inherits the bold, and the console renders palette entry **6+8 =
14**:

```
asked for  #1289ff   palette entry 6    (up in blue)
got        #55ffff   palette entry 14   (bright cyan)
```

The renderer emitted `ESC[97m` for white body text — which is correct — and then
`ESC[36m` for the bar fill. Everything on screen looked right except the one
element that used a low-numbered colour as a **foreground**.

Emit the intensity explicitly on every colour change, never inherit it:

```
fg 8-15  ->  ESC[1;3<fg-8>m
fg 0-7   ->  ESC[22;3<fg>m
```

**Why no check caught it, and what does now.** The frame-level assertion asked
whether `#1289ff` appeared anywhere — it did, in the title stripe, on every
screen. The glyph comparison passed too, because it compares *shapes* and the
shape was a correct full block. The check that catches it looks at the bar's own
rectangle and requires every pixel in it to be the field colour or the brand
colour. Colour assertions have to be **regional**; "the right colour is present"
is not a statement about anything.

The progress bar is the only place in SETUP-PLAN §3.1 where the brand blue is a
foreground rather than a background, so this had exactly one place to show up.
