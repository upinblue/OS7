# OS/7 build notes — harvested findings

Findings carried over from an earlier OS/7 build session (**2026-06-24**) whose
repository history was deliberately replaced by the current scaffold. That
session got as far as a **structurally bootable arm64 ISO** (~2.3 GB) before the
project was re-architected (see below).

Everything here was discovered by hitting the failure, not by reading
documentation. Each item says what breaks if you undo it. Nothing here has been
re-validated against the current scaffold.

## Claiming a number

The entries below are numbered and the numbers are referenced from CLAUDE.md,
README, SETUP-PLAN, session documents, source comments and harnesses. **Two
entries with the same number stop the list from being a list**, and on
2026-08-25 that nearly happened twice in one afternoon: several Claude Code
sessions were running at once, each picked "the next free number" independently,
and two of them picked the same one.

So: **claim the number here, in this table, in a commit, before you write the
entry.** A number that is spoken for but not yet written looks free otherwise,
and the next session takes it in good faith.

**And check against `origin/main`, not against your own tree.** The rule above
failed once on 2026-08-25 anyway: a claim existed for eight minutes in a branch
that had not been pushed, and the other session read the state it had, which was
correct and out of date. `git fetch` first — a commit nobody can see is the same
as a conversation.

*No number is currently claimed but unwritten.*

Everything below is written. Numbers above 59 are free.

## What was kept, and what was dropped

**Kept** — carried into this repo:

| File | Why |
|---|---|
| `build/build.sh` | The two staging fixes below (3, 6) are required for any build to work on macOS. |
| `build/lib/efi-remaster.sh` | GRUB/EFI work; the only reason an OS/7 ISO boots at all. Harvested verbatim for arm64, generalised to both architectures on 2026-08-25 (#48). |
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

### 7. live-build emits no arm64 bootloader — `build/lib/efi-remaster.sh` (arm64-only when this was written; see #48)
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

## 31. fbcon DEFERS taking the console over, and completes it only when something writes

Found in Phase 1 ([SESSION-PHASE1-SETUP.md](SESSION-PHASE1-SETUP.md)), and it
cost several boots because the symptom points somewhere else entirely.

`os7-setup` starts from a systemd unit on tty1 and immediately loads its console
font. On a virtio-gpu machine:

```
[    0.000431] Console: colour dummy device 80x25
[    0.569495] fbcon: Deferring console take-over
[    0.570004] virtio-pci ... [drm] fb0: virtio_gpudrmfb frame buffer device
```

and then **nothing**. `fb0` exists, the DRM driver is loaded, and tty1 is still
the kernel's *dummy* device. On it:

```
setfont:          ERROR ... put_font_kdfontop: Unable to load such font with
                  such kernel version
showconsolefont:  ERROR ... get_font_kdfontop: ioctl(KDFONTOP): Function not
                  implemented
```

ENOSYS, because a dummy console implements no font operations. A palette applied
to it goes nowhere either.

**The takeover completes when output arrives on the console, not when time
passes.** Normally the getty's login prompt does it. A harness that waits by
probing with ioctls waits forever — the first version of the S1 `waitfb` step
polled for two minutes and the console never moved, *because polling is not
writing*.

Two fixes, and use both:

* **`fbcon=nodefer` on the kernel command line.** The framebuffer console then
  exists from the start and the race does not. This is on OS/7's Install entry
  and in the spike harnesses.
* **Notice and re-take.** A program that owns the console should re-apply its
  font and palette whenever the console is not what its font should have
  produced, with a backoff. Recovering from a race is worse than not having one,
  but it also covers a mode change and a serial client resizing.

**And `setfont` exiting 0 does not mean the font loaded.** During the same
window, `setfont -C /dev/tty1 <psf>` exited **0** and the console stayed in its
8x16 font; the identical command from a shell a minute later worked. So the
question "did the font load" is a question about the console's geometry
afterwards, never about an exit code:

```
expected grid = framebuffer / cell size      e.g. 1280x800 / 16x32 = 80x25
```

**Related, and the reason a broken screen looked half-drawn:** `setfont` CLEARS
the console. A re-take that loads the same font again therefore wipes the screen
*without changing its size*, and a renderer with row-level damage tracking then
sends nothing, because the frame it believes is on screen has not changed. Any
code path that re-applies the font must invalidate the frame AND report that
something changed. The symptom was a Welcome screen with a status bar and
nothing above it.

## 32. `read(2)` needs a deadline: SIGWINCH will not break it, and neither will ESC

Found in Phase 1, and it is two problems with one answer.

**.NET installs its POSIX signal handlers with `SA_RESTART`.** A `SIGWINCH`
therefore does not interrupt a blocking `read`, so a program that only repaints
when a key arrives will sit on a stale screen indefinitely — which is exactly
what happens when fbcon takes the console over (#31) while Setup waits for
input.

**A lone ESC is the prefix of every escape sequence**, so a reader that blocks
until the accumulated string can be decided waits forever on the Escape key.
Spike S1 recorded this as the debt Phase 1 owes.

`poll(2)` answers both: a 200 ms idle tick so the caller can look around and
repaint, and a 100 ms deadline once a sequence has started so a bare ESC decides
itself.

**Use `poll`, not `VMIN`/`VTIME`.** With a `VTIME` timer, "nothing arrived" and
"the terminal went away" are both `read` returning 0, and an installer that
cannot tell an idle user from a hangup will either spin or quit on somebody
thinking. `poll` reports `POLLHUP` separately.


## 33. `Conflicts=` is resolved when the transaction is built; `Condition…=` when the job runs

Found in Phase 1. A one-line unit file mistake that took the whole live session
with it, and produced a symptom in a different subsystem.

`os7-setup.service` is meant to run only when the boot entry asks for it:

```ini
ConditionKernelCommandLine=os7.setup=1
Conflicts=getty@tty1.service      # tty1 is Setup's for the duration
[Install]
WantedBy=multi-user.target
```

That reads as "on a live boot the condition fails, so nothing happens". It is
not what happens. **systemd resolves `Conflicts=` while building the
transaction, and evaluates `Condition…=` when the job actually runs.** An enabled
unit whose condition later fails has *already* had getty@tty1 stopped.

The result on the live entry: tty1 had no login prompt. And because nothing then
wrote to that console, fbcon's deferred takeover never completed either (#31), so
tty1 stayed the kernel's dummy device for the whole session — which is how a
missing `WantedBy` presented as "the console does not support fonts".

**The fix is not to drop `Conflicts=`.** Drop `[Install]` instead, and start the
unit from the kernel command line:

```
linux ... os7.setup=1 systemd.wants=os7-setup.service ...
```

Then the unit is not in the live boot's transaction at all and nothing about it
applies there.

**Do not "fix" it with `ExecStartPre=systemctl stop getty@tty1.service`
either** — that was tried, and it is worse. `getty@tty1` has `TTYReset=yes`, so
stopping it resets the VT, and **a VT reset restores the palette from the
kernel's module defaults** — i.e. whatever `setvtrgb.service` put there, i.e.
Ubuntu's. The screen went back to Ubuntu's colours a moment after Setup painted
it in OS/7's. `Conflicts=` happens before `ExecStart`, so there is nothing to
race.

## 34. QEMU's `send-key` holds each key for 100 ms, so keys sent faster overlap and vanish

Found in Phase 2 ([SESSION-PHASE2-STORAGE.md](SESSION-PHASE2-STORAGE.md)) while
typing a passphrase into `os7-setup` from the harness.

`send-key` presses and releases; the release is `hold-time` milliseconds later
and **the default is 100**. Two calls closer together than that overlap, and a
USB HID keyboard cannot report two independent presses at once — so all but one
are lost.

The symptom is not a dropped key, it is a nearly empty field:

```
13 characters sent at 20 ms apart  ->  1 character on screen
13 characters sent at 80 ms apart  ->  1 character on screen
```

and Setup correctly complaining that the passphrase is too short. It reads as an
input bug in the product, which is where an hour goes.

Set the hold time and then leave more than that between calls:

```python
q.cmd("send-key", keys=[{"type": "qcode", "data": ch}], **{"hold-time": 20})
time.sleep(0.12)
```

**The conclusion is the opposite of the usual one.** The product does not need
to accept 50 keystrokes a second — nobody types that fast, and a console that
kept up with it would be solving a problem OS/7 does not have. The harness is
what was wrong.

## 35. `-cdrom` makes the live medium invisible to an installer's disk list

Found in Phase 2. It matters because it makes a safety test pass for the wrong
reason.

L12 requires Setup to list its own boot medium and never let it be selected.
With the ISO attached as `-cdrom`, `lsblk` reports it as `type="rom"` — and an
installer that (correctly) only offers `type="disk"` never sees it at all. The
refusal is untestable, and a harness asserting "the medium is refused" against
that VM is asserting something that cannot fail.

Attach the ISO as a block device instead:

```
-drive if=none,id=live,file=os7-arm64.iso,format=raw,readonly=on
-device virtio-blk-pci,drive=live,serial=os7live
```

casper finds `/casper/filesystem.squashfs` by scanning block devices, so a raw
ISO on virtio-blk boots exactly as a USB stick does — **which is also the shape
a real install has.** Almost nobody installs from an optical drive any more, so
the CD was the unrealistic case as well as the untestable one.

Order the `-device` lines so the medium enumerates first, and the harness lands
on it without having to know which name it got.

## 36. Pinning live-build's archive takes ALL the mirror flags — the two that matter are `*_VOLATILE`

Found on 2026-08-24, pinning the build to `snapshot.ubuntu.com` (release plan
§3.2). It is the same shape as #25 and #13: something silently keeps its default,
and the default is the thing you were trying to replace.

`auto/config` set the five obvious flags — `--mirror-bootstrap`,
`--mirror-chroot`, `--mirror-chroot-security`, `--mirror-binary`,
`--mirror-binary-security`. Reading `config/bootstrap` back after `lb config`
showed the pin had *not* taken everywhere:

```
LB_MIRROR_CHROOT_VOLATILE="http://archive.ubuntu.com/ubuntu/"
LB_MIRROR_BINARY_VOLATILE="http://archive.ubuntu.com/ubuntu/"
```

**"Volatile" is Debian's name for what Ubuntu calls `-updates`.** So the two
flags nobody thinks to set are the ones covering the suite that *moves*. A build
like that draws its base from a fixed snapshot and its updates from whatever the
archive holds today, and is therefore not reproducible — while every flag on
screen says it is pinned. On arm64 it is also pointed at a host that does not
carry the architecture at all (`archive.ubuntu.com` vs `ports.ubuntu.com`).

Set both families, all of them:

```
--parent-mirror-{bootstrap,chroot,chroot-security,chroot-volatile,binary,binary-security,binary-volatile}
--mirror-{bootstrap,chroot,chroot-security,chroot-volatile,binary,binary-security,binary-volatile}
```

`*_BACKPORTS` may stay `"none"` — that is disabled, not defaulted.

**The check that finds this costs thirty seconds and no build.** Run `lb config`
alone and grep what it recorded:

```bash
grep -E "^LB_(PARENT_)?MIRROR" config/bootstrap | grep -v snapshot.ubuntu.com
```

Anything that prints is a leak. Do not reason about which flags live-build
derives from which — read what it wrote.

Two things measured the same day, both worth having:

* **`security.ubuntu.com` does serve arm64** for `resolute-security`
  (`binary-arm64/Packages.gz` → 200). The unpinned security mirror in the
  pre-pin ISO was a reproducibility hole, not a broken source. Checked before
  claiming it, because the `archive`/`ports` split makes the opposite obvious
  and wrong.
* **The snapshot service has no `archive`/`ports` split at all.** arm64 is under
  the same `/ubuntu/<stamp>/` path as amd64, so pinning *removes* the
  per-architecture branch `auto/config` used to carry.

## 37. `/etc/os-release` is a symlink, and `dpkg --get-selections` cannot detect drift

Two findings from writing the release identity (hook 0075).

**The file to write is `/usr/lib/os-release`.** On Ubuntu 26.04
`/etc/os-release` is a symlink to `../usr/lib/os-release`, and `base-files` owns
the target as a *conffile*. Writing through the symlink works today and breaks
silently the day the symlink is not there; and because it is a conffile, an
`apt` run that reinstalls `base-files` reverts the branding — which is why the
update sequence has to re-assert it (release plan §4.2 step 6).

Read it back by **sourcing** it, never by scraping it. os-release(5) defines the
file as shell-compatible and every real consumer reads it with `.`; a
`sed`-and-strip-quotes reader agrees right up to the first value quoted the other
way, then disagrees in silence. The first version of hook 0075's own readback
check stripped only double quotes while its writer emitted single ones.

Also: the release plan's §3.5 example shows `ID_LIKE=ubuntu`. The actual file
says `ID_LIKE=debian`. It does not matter — the field is one of the three left
untouched for Intune — but do not "fix" the real file to match the example.

**`dpkg --get-selections` is the wrong basis for drift detection.** §3.4
specifies it for `packages_manifest`, and §5 wants that manifest to catch an
admin typing `apt upgrade` behind the release train's back. It cannot: selections
record package *names* and an install state, so a system holding
`linux-image 7.0.0-28` and one holding `7.0.0-31` produce **byte-identical**
selections. The hash would match and the drift would be invisible.

Hook 0075 writes `package<TAB>version<TAB>architecture`, sorted, instead. It is
a strict superset of the selections list and it makes both of the things the
manifest exists for actually work — drift detection (§5) and comparing two
builds of one release (spike S7).

## 38. Two different chroots: bundled cmdlets resolve in one and not in the other

Measured 2026-08-24, and then **contradicted by the build the same afternoon.**
Read the correction at the bottom before relying on the measurement.

#14 says PowerShell's module discovery is broken inside `chroot(2)` — it probes
`PSModulePath` with the character at index 1 dropped — and hook 0020 adds that
`Write-Host` therefore "cannot work at build time". Hook 0075 has to read
`/usr/lib/os7/release.json` through `New-OS7BootEnvironmentName`, which calls
`Test-Path`, `Get-Content`, `ConvertFrom-Json` and `Get-Date`, all from the same
bundled `Microsoft.PowerShell.Utility`. If #14 read the way it appears to, that
check could not exist.

So it was measured rather than assumed: overlay the shipped squashfs, bind
`/dev` and `/proc`, `chroot`, and ask.

```
chroot /mnt/root /usr/bin/pwsh -NoLogo -NoProfile -Command \
  "Import-Module /usr/local/share/powershell/Modules/OS7/OS7.psd1 -Force; New-OS7BootEnvironmentName"
os7_1.0.0.32_202608241502
```

**It works.** Chrooted, importing by path, with every bundled cmdlet resolving.

The distinction #14 was always making, now visible:

| | under `chroot(2)` |
|---|---|
| `Import-Module <name>` / `Get-Module -ListAvailable` | broken — this is #14 |
| `Import-Module <absolute path>` | works, and #14 says so |
| **Bundled cmdlets from `$PSHOME/Modules`** | **work** |

And the reason the third row ever looked broken is in hook 0020's own root cause,
one paragraph further down than the part that gets quoted: with no usable
`/dev/urandom`, .NET throws `CryptographicException` while initialising a
runspace, and then *no on-disk module can load at all* — which presents as
"`Write-Host` is not recognized" and looks exactly like a discovery failure. A
live-build chroot gets only `/dev/pts`, so that was the state when the note was
written. Hook 0020 now `mknod`s the device nodes, so every hook numbered after it
runs with a working RNG.

### The correction — the same command fails in live-build's chroot

The measurement above is real and reproducible. It is also **not representative
of the chroot a hook actually runs in.** The first ISO build after it printed:

```
OS/7 hook 0075:   NOTE: the module produced no boot-environment name.
OS/7 hook 0075:   NOTE: pwsh said: … included, verify that the path is correct and try again.
```

That sentence is the tail of PowerShell's *command-not-found* message, not of an
import failure — and in the same build, twenty lines earlier:

```
OS/7 hook 0060:   manifest loads, exports: New-OS7BootEnvironmentName, New-OS7Storage, …
```

So in live-build's chroot the module **imports** by path and its functions are
**listed** — and *calling* one fails. The distinction that matters is therefore
not import-by-path versus import-by-name:

| | overlay + bind-mounted /dev | live-build's chroot |
|---|---|---|
| `Import-Module <path>` | works | **works** |
| `Get-Command -Module OS7` | works | **works** |
| **Calling a function that uses `Get-Content` / `ConvertFrom-Json`** | works | **fails** |

Hook 0060 has always been written to stay on the right side of that line, and
its comments say so without quite saying why: it uses `Get-Command` (compiled
into the engine, in `Microsoft.PowerShell.Core`) and `[Console]::WriteLine`
(pure .NET), and touches nothing that has to be **autoloaded by name** out of
`$PSHOME/Modules`. `New-OS7BootEnvironmentName` calls `Test-Path`,
`Get-Content`, `ConvertFrom-Json` and `Get-Date`, all of which do — and that
autoload is #14's mangled-path lookup.

**Why the overlay test disagreed has not been isolated.** The environment differs
(a hook inherits live-build's), and so does how `/dev` came to exist. Both are
plausible; neither is measured. Do not build on the overlay result.

**The operative rule, unchanged from #14 and now with a reason:**

> A build-time hook may `Import-Module` by path and inspect what it exports. It
> must not CALL anything that needs a bundled cmdlet. If it needs real work done,
> do it in `python3` or `bash`.

**And the design rule this cost nothing because of.** Hook 0075 treats
"PowerShell produced no answer" as a NOTE and "PowerShell produced the WRONG
version" as fatal. Had it treated both as fatal — the obvious way to write it —
this build would have failed on a perfectly good image. The load-bearing check
that the version reaches the disk is `installer/testing/run-phase2.py`, on a
booted system, where none of this applies.

## 39. `unsquashfs` exits 0 when the file you asked for is not in the image

Measured 2026-08-24, while making `build.sh` lift `/usr/lib/os7/release.json`
out of the finished squashfs.

```
unsquashfs -q -n -f -d /tmp/probe image.squashfs usr/lib/os7/release.json
echo $?        # 0
find /tmp/probe -type f | wc -l    # 0
```

It extracts nothing and reports success. So the exit code cannot answer the one
question the extraction exists to ask — *did hook 0075 actually write the
manifest into the image* — which is trap #13's shape again, one layer down: the
build "succeeds" and the artefact is not there.

**Ask for the files, then look for them.** Ignore the status, test the paths:

```bash
unsquashfs -q -n -f -d "${DIR}" "${SQ}" usr/lib/os7/release.json ... || true
for want in release.json packages.manifest; do
    [[ -s "${DIR}/usr/lib/os7/${want}" ]] || { echo "not in the image" >&2; exit 1; }
done
```

The check is worth having rather than dropping, because an ISO with no manifest
is not merely missing a file: nothing on it knows which version it is, and every
boot environment it installs would be named `0.0.0.0`.

Verified on `unsquashfs` 4.7.5 (2026/03/01), the version in the build container.

### A second hazard, from the same session

**Do not edit `build/build.sh` while a build is running.** Bash reads a script
lazily, by byte offset, so inserting lines ahead of the point the interpreter has
not reached yet misaligns everything after it — and the failure appears at the
very end of a long build, in the post-processing, looking like a bug in the code
you just wrote. Let the build finish, or kill it, before editing.

## 40. `--iso-volume` does nothing on arm64 — the remaster discards it

Found 2026-08-24 by reading the label off a finished ISO, which is the only way
it could have been found.

`auto/config` passes `--iso-volume "OS7-<version>-<arch>"`, and `lb config`
records it faithfully:

```
config/binary:LB_ISO_VOLUME="OS7-1.0.0.32-arm64"
```

The ISO said `OS7-arm64`.

`build/lib/efi-remaster.sh` does not modify live-build's ISO — it builds a
**new one** with `xorriso`, because live-build emits no arm64 bootloader at all
(harvested fix 7). So every ISO9660 property live-build was told about is
discarded at the last step, and the `-volid "OS7-arm64"` hardcoded on the xorriso
line quietly won over the flag.

**The nastiest part is that it is architecture-dependent.** amd64 keeps
live-build's ISO, so there the same flag works. One setting, two behaviours, and
the difference only shows on the artefact.

The fix takes the volume id from the output filename the caller already passes —
`OS7-<version>-<arch>.iso` → `OS7-<version>-<arch>` — rather than adding a second
variable. The label on the medium and the name of the file then cannot disagree,
and there is nothing new for a future caller to forget.

**The general form, worth carrying:** anything that re-masters an image discards
everything the tool that built it was configured with. Check the artefact, not
the configuration — `blkid -o value -s LABEL image.iso` costs nothing.
`installer/testing/check-image.py` does this and four other things the build
cannot check from inside itself.

## 41. The VM harnesses test the ISO's os7-setup, not the source tree's

Cost one VM cycle on 2026-08-24, the first time Phase 3 was run.

`run-phase3.py` failed with "the install did not finish". The serial log said:

```
os7-setup: unknown option '--password-file'
...
Phase 2: from the Confirm screen onwards this WRITES TO A DISK.
```

The harness was passing a Phase 3 option to a **Phase 2 binary**. `os7-setup` is
compiled by `build/build.sh` and baked into the squashfs; the VM boots the ISO,
so it runs whatever was current when that ISO was built. Editing
`installer/src/OS7.Setup/` changes nothing a harness can see until
`make build-arm64` runs again.

Obvious once stated, and easy to lose because the OTHER loop is so much faster:

```bash
# seconds - and tests the SOURCE
docker run --rm --platform linux/arm64 -v "$PWD":/work os7-build:arm64 bash -c \
  'cd /work/installer/src/OS7.Setup && dotnet publish -c Release -r linux-arm64 \
   -p:PublishAot=true -o /tmp/pub && /tmp/pub/os7-setup --self-test'

# ~25 minutes - and is what run-phase1/2/3 actually run
make build-arm64
```

The tell is in the usage text the failure prints: it says which phase the binary
thinks it is. `os7-setup --version` on the medium answers the same question for
the release.

`run-phase3.py` now prints the last 25 lines the guest produced on any failed
install, and names this specific cause when it sees `unknown option` or a usage
block. A harness that reports only its verdict makes you read a serial log by
hand to find a one-line answer.

## 42. `bpool` mounts INSIDE `rpool`, so it must be exported first

Found on 2026-08-24 by the first Phase 3 install, which reported success.

The teardown ran `zpool export rpool` and then `zpool export bpool`. `bpool` is
mounted at `<target>/boot` — **inside rpool's tree** — so rpool cannot export
while it is there. The result:

```
OS7-SETUP-DONE install
      FAIL  a pool is still imported after the install finished
rpool
```

All fourteen steps ran, the installer reported a finished install, and rpool was
still imported. `zpool export` had returned non-zero into a `TryExec` that
ignores failure, so nothing said so.

**Export `bpool` before `rpool`.** Spike S3's step 10 does, and everything else
in that step is there for a reason too:

```
sync
umount "$MNT/boot/efi"
umount -R "$MNT"
zfs umount -a
zpool export bpool
zpool export rpool
cryptsetup close os7_root
```

Two things worth carrying beyond the ordering:

* **It recovers, and that is not the same as being correct.** The installed
  system carries the same `/etc/hostid` the pools were created with (L13), so it
  imports them at boot regardless — the machine booted perfectly well with rpool
  left imported. An unclean export is a pool ZFS has to decide about at boot
  rather than simply open, and a check that only asked "does it boot" would never
  have found this.
* **`zpool export` failing into a `TryExec` is silent by construction.** The
  step now asks `zpool list` afterwards and logs an error if anything is left,
  which is the same shape as every other check in this repository: ask the thing
  itself, do not read the exit code of the command that was supposed to change it.

When it still will not export, S3's diagnostic is the one worth copying: print
what is still mounted below the target AND which processes have a cwd or root
inside it. "Pool is busy" names no culprit, and the two candidates need different
fixes — and `-f` does not help against a mount held in another namespace, which
is what the chroot's `unshare` exists to avoid (#18).

## 43. A git WORKTREE has no repository inside the build container — and the build blamed the wrong thing

Found on 2026-08-24, building from `.claude/worktrees/<name>` rather than from
the main checkout. `make build-arm64` produced `out/OS7-1.0.0.0-arm64.iso`:
BUILD `0`, commit `unknown`, `"reproducible": false` — from a tree whose HEAD was
`1d764e0ed080`, commit count 34, and clean.

`build/build.sh` derives the BUILD field (release plan §3.3) by asking git inside
the container, across the bind mount:

```
git -c safe.directory=/work -C /work rev-list --count HEAD
```

In a normal checkout `/work/.git` is a directory and that works. In a **git
worktree** `.git` is a FILE holding a single line:

```
gitdir: /Users/…/OS7/.git/worktrees/<name>
```

— an absolute path to the *main* repository's admin directory, which is not under
the bind mount. Measured in the build container:

```
$ ls -la /work/.git
-rw-r--r-- 1 root root 89 Aug 24 18:50 /work/.git

$ git -c safe.directory=/work -C /work rev-parse --short=12 HEAD
fatal: not a git repository: /Users/…/OS7/.git/worktrees/<name>
exit=128
```

`safe.directory` is irrelevant here; so is the mount being read-write. git
resolves the pointer, finds nothing at the far end, and stops.

Two separate failures, and only one of them is about git.

**The version was wrong.** Every ISO built from a worktree — and Claude Code
sessions run in one by default — was `1.0.0.0`, no matter what was in it. That
number is not merely uninformative: two such builds share a filename, they
overwrite each other in `out/`, and each takes over the `out/os7-<arch>.iso`
symlink that six harnesses open by name. A version that identifies nothing is
worse than no version, which is §3.1's whole argument.

**The message was wrong about why.** The build said:

```
NOTE: no git repository at /work and no OS7_VERSION_BUILD - BUILD field is 0
```

There *is* a repository at `/work`. What is missing is the admin directory it
points at, on the other side of a mount boundary. The note was true enough to be
believed and wrong enough to send you looking at `safe.directory`, at file
ownership, at the Dockerfile's git — anywhere except at the one line in `.git`.

**The fix is the one that was already there for amd64.** `build.sh` has always
accepted `OS7_VERSION_BUILD` / `OS7_GIT_COMMIT` / `OS7_GIT_DIRTY` from its
caller, because `scripts/build-amd64-vm.sh` copies the tree into a QEMU VM with
`--exclude=.git` and has to. The host can always answer — a worktree is a
first-class repository *there* — so the host answers, and hands the facts in:

```
scripts/os7-source-facts.sh     # the three questions, asked once, on the host
Makefile                        # -e OS7_VERSION_BUILD=… -e OS7_GIT_COMMIT=… …
```

The script prints facts and **never a version string**: §3 gives that job to
`build/config/os7-release.conf` plus `build/build.sh`, and a second place that
assembled `MAJOR.MINOR.PATCH.BUILD` would be a second thing to keep in step.

`build.sh` no longer falls through to `0` when `/work/.git` exists and git cannot
use it. That is a broken environment, not a legitimate state, and it now **stops
the build** with git's own error, the `gitdir:` line, and the command that fixes
it. The tarball case — no `.git` at all, which is what an export or the amd64 VM
looks like — still builds with BUILD 0 and `reproducible: false`, as designed.
Handed-in values are checked for shape first: hook 0075 tests `OS7_GIT_DIRTY`
against the literal `"true"`, so `yes` would have read as *clean* and put
`"reproducible": true` in the manifest of a dirty build.

`check-image.py` had a `version != "0.0.0.0"` guard and it did not fire: the
worktree ISOs were `1.0.0.0`, since MAJOR.MINOR.PATCH come from the pin file and
only BUILD comes from git. The guard was written against *no manifest at all*.
It now checks the BUILD field and the commit on their own, so the tool that
exists to ask the artefact what it is can no longer answer "it knows its
version" about an image that does not know what it was built from.

Two things worth carrying beyond this bug:

* **`.git` is not always a directory, and "git says no" is not "there is no
  repository."** Worktrees, submodules and `GIT_DIR` all make `.git` a pointer.
  Anything that asks git across a mount, a container or a copy has to assume the
  pointer leads out of the box, and to tell the two answers apart.
* **A diagnostic that names a cause has to have checked that cause.** This one
  reported the *branch it had taken* — "no git repository" — as if it were the
  reason, which is the same shape as every other expensive bug here: a program
  reporting confidently about something it never asked.

## 44. `lb_binary_memtest` copies `chroot/boot/.bin` — an amd64-only trap arm64 can never hit

Found on 2026-08-25, not by building, but by **asking GitHub what it remembers**.
`gh run list` returned one run this repository has no commit for: 2026-06-24,
`.github/workflows/build.yml`, head `716be695` — an object `git cat-file` cannot
find here, from the history that commit e1a63f9 harvested and replaced. GitHub
kept it: [run 28103636078](https://github.com/upinblue/OS7/actions/runs/28103636078).

It changes two sentences that had been repeated in README, Makefile and HANDOFF
since the scaffold:

* `build-arm64` on `ubuntu-24.04-arm` **succeeded** — 15m2s, ISO artifact
  uploaded. The runner label was never unverified; nobody had looked.
* `build-amd64` on a native `ubuntu-24.04` runner **got past everything Apple
  Silicon blocks**. No ENOSYS, no tar failure (#12): debootstrap, chroot and the
  package stages all completed, and it died in the *binary* stage:

```
P: Begin installing memtest...
cp: cannot stat 'chroot/boot/.bin': No such file or directory
make: *** [Makefile:38: build-amd64] Error 1
```

### The mechanism, from live-build's own source

`/usr/lib/live/build/lb_binary_memtest` in live-build `3.0~a57-1`, the version in
the OS/7 build container:

```sh
MEMTEST_BIN="${LB_MEMTEST}"                                    # line 65
...
[ -e "chroot/boot/${LB_MEMTEST}x64.bin" ] && _MEMTEST_BIN="${LB_MEMTEST}x64"
...
cp "chroot/boot/${_MEMTEST_BIN}.bin" "${DESTDIR}"/memtest      # line 118
```

Line 65 sets `MEMTEST_BIN`. Line 118 reads `_MEMTEST_BIN`, with a leading
underscore — **a different variable**, and the only thing that ever assigns it is
the `[ -e … ]` test. When `memtest86+x64.bin` is not in the chroot, `_MEMTEST_BIN`
stays empty and the copy becomes `cp chroot/boot/.bin`, which is the exact string
in the June log. The stage does not check whether the package it just tried to
install arrived; it interpolates and copies.

### Why no OS/7 build has ever seen it

Two guards upstream, and arm64 trips the second:

```sh
if [ "${LB_MEMTEST}" = "false" ] || [ "${LB_MEMTEST}" = "none" ]; then exit 0; fi
...
if [ "${LB_ARCHITECTURES}" != "amd64" ] && [ "${LB_ARCHITECTURES}" != "i386" ]; then
	Echo_warning "skipping binary_memtest, foreign architecture."
	exit 0
fi
```

memtest86+ is x86-only, so **the entire stage is skipped on arm64** — every ISO
this project has ever built. And `build/config/auto/config` sets no `--memtest`,
so the default stands. Measured on today's tree, `lb config` for amd64:

```
LB_MEMTEST="memtest86+"
```

That is the value that reaches line 118. The trap is loaded in the tree right
now and is unreachable from the only architecture that builds here — which is
the same shape as #12 and #23: **an arm64 pass is not an amd64 result, in either
direction.**

### The fix, and what is still unproven about it

`--memtest none` hits the first `exit 0` above; both `none` and `false` are
accepted by `lb config` (measured — unlike `--debian-installer`, where HARVESTED
FIX 4 found `none` rejected and `false` required). OS/7 wants nothing from this
stage: the medium carries exactly two GRUB entries by design, and on arm64 the
menu is written by `build/lib/efi-remaster.sh` regardless.

**What has NOT been measured: that an amd64 ISO now builds.** This is the next
failure removed, not the last one — nothing in either history has ever run past
`lb_binary_memtest` on amd64. The claim here is exactly: today's config would
reach a stage whose own source cannot succeed without a file the chroot does not
have, and `--memtest none` stops it from being reached.

### Worth carrying

**A history that was replaced still ran somewhere.** Four documents in this
repository asserted "never attempted" about a job that had been attempted,
because the evidence lived in GitHub Actions rather than in git, and nothing here
had thought to ask. Before writing *never* about a build, run `gh run list` —
the repository name outlives the history under it.
---

## 45. A screen that validates the whole plan makes the next screen unreachable — and every automated path hid it

Found on 2026-08-25 by walking `os7-setup` by hand. On `main` at 1d764e0 —
"Phase 3: os7-setup installs a machine, and the machine boots" — **the
interactive installer could not get past screen 6.**

Welcome → Licence → Regional → Disk → Layout → Confirm, press `F`, and what
appears is:

```
Setup cannot continue.
Setup cannot continue with the settings as they are.
  no user account was named
  the account has no password
```

Both halves came in with the same commit. `ConfirmScreen` called
`_plan.Validate(out problems)` — the WHOLE-plan check, which unconditionally
runs `Account.Validate` — and only then transitioned to `new AccountScreen`. So
the plan was checked for an account **one screen before the account is typed**.
Screen 7 was unreachable interactively; the error screen was the only thing past
screen 6.

### The comment on the line was the bug

The call was not careless. It carried this:

> The last gate before anything is written, and the first place the WHOLE plan
> is complete enough to check … after here there is no screen left to catch it
> on.

Every word of that was true when it was written, and Phase 2's session notes say
the same thing: *"The full check runs in exactly two places: `--unattend`, and
the Confirm screen the moment before anything is written."* Phase 3 then inserted
screens 7 and 8 between the confirmation and the executor, and the sentence
quietly became false while the code it justified stayed put. **A comment that
states a structural fact is a claim with a lifetime**, and nothing checks it.

The general shape: *when a screen is inserted into a flow, the screen before it
inherits a promise it can no longer keep.*

### Why nothing caught it — three paths, three different reasons

This is the part worth carrying, because the repository's whole discipline is
supposed to make this impossible and it did not:

| path | why it passed |
|---|---|
| `--unattend` | the plan file it is handed **already contains an account**, so the whole-plan check is correct there and always has been |
| `--storage-only` | skips the account check **by design** — a plan that is complete for preparing a disk should not be refused for lacking a login (`Program.cs`) |
| `run-phase2.py walk` | the one path that drives the screens by hand. It pressed `F` and then waited for a progress bar, **because at Phase 2 the executor was what came next**. Nobody told it about screens 7 and 8. |

The third is the expensive one, and its failure output is the lesson: the walk
reported

```
FAIL  the executor is running
```

which reads as an executor problem, points at the storage steps, and is not
about the executor at all. **A harness that asserts "the next thing appeared"
without naming which thing reports the wrong subsystem when the flow changes
underneath it.** The fix now reads the error screen first and prints it whole, so
a returning bug is diagnosed from the log rather than from a screendump.

### The fix: the gate moved down, it did not move up

`ConfirmScreen` now calls `ValidateThroughStorage` — the regional half and the
storage half, which is exactly what screens 3 to 5 collected. The whole-plan
check moved to `ExecuteScreen.Start`, and **`ExecuteScreen`'s constructor is now
private** so that factory is the only way to build one. Constructing that object
starts a thread that partitions a disk, so "did anybody check the plan first?"
must not be a question about the caller.

That is the same rule as #33 and #42 in a third costume: *put the check on the
thing, not on whoever happens to call it today.*

### The regression guard is in `--self-test`, so it fails the BUILD

Two `Handle` calls on screens built without a terminal:

```
SELFTEST ok   screen 6's check passes a plan that has no account yet
SELFTEST ok   and the whole-plan check still refuses the same plan — no user account was named; the account has no password
SELFTEST ok   F on screen 6 reaches screen 7 with no account in the plan — AccountScreen
SELFTEST ok   the executor's own gate refuses a plan with no account — ErrorScreen
```

Hook 0080 runs `--self-test` inside the chroot during the ISO build, so a flow
that cannot reach screen 7 now fails `make build-arm64` rather than a VM run.
The third line is the one that matters: it asks the **transition**, not the
predicate behind it. The bug was a screen calling the wrong check, so asking the
check is asking the wrong question.

What the self-test must NOT do is walk past screen 7. A complete plan through
`ExecuteScreen.Start` returns an executor, and an executor is a thread
partitioning a disk — inside a build chroot, as root. Only the refusal is safe to
ask for, and the refusal is the half that guards a person.

---

## 46. `read_text` decoded a plain hyphen as U+00AD — eight bitmaps in the console font belong to more than one codepoint

Found on 2026-08-25 by the first harness assertion that ever put a hyphen in a
needle.

`installer/testing/vmscreen.py`'s `read_text` is the repository's OCR: it cuts a
cell out of a screendump and compares it against every glyph in the PSF, and the
one that matches exactly wins. That is the right design — the screen was drawn
from this font, so an exact match is the only correct answer.

It is also ambiguous, and nothing said so. **Eight bitmaps in
`os7-fixedsys-16x32.psf` are drawn by more than one glyph:**

```
[('0xad', '\xad'), ('0x2d', '-'), ('0x2010', '‐'), ('0x2212', '−')]  -> returned 0xad
[('0x20', ' '), ('0xa0', '\xa0')]                                    -> returned 0x20
[('0x2c', ','), ('0x201a', '‚')]                                     -> returned 0x2c
[('0x2022', '•'), ('0x2219', '∙')]                                   -> returned 0x2022
[('0x25c8', '◈'), ('0x2666', '♦'), ('0xfffd', '�')]                  -> returned 0x25c8
[('0x3a9', 'Ω'), ('0x2126', 'Ω')]                                    -> returned 0x3a9
[('0x394', 'Δ'), ('0x2206', '∆')]                                    -> returned 0x394
[('0x2014', '—'), ('0x2015', '―')]                                   -> returned 0x2014
```

They are **separate glyph indices holding identical pixels** — U+002D is glyph
45 and U+00AD is glyph 16 — not one glyph with several names, so the PSF itself
makes no claim about which is meant. The decoder built its lookup with
`setdefault`, so the winner was whichever codepoint came first in the unicode
table: **glyph order, an artefact of how `build/lib/psf.py` assembles the
subset.** For the dash that is U+00AD SOFT HYPHEN.

The symptom, from a screen that was completely correct:

```
FAIL  the computer name that was typed (os7-phase3): 'os7-phase3' is not on the screen in #ffffff
ok    the account that was typed (os7admin)
```

`os7admin` has no hyphen and `os7-phase3` does. The screendump beside it reads
`Computer:     os7-phase3` in plain sight.

**The lowest codepoint wins.** It is the ASCII one wherever there is an ASCII
one — which is the character a program printing text actually used — and it is
the same answer every run, which glyph order was not. It changes only the dash
in practice; the other seven already resolved to the lower codepoint by accident.

Two things worth carrying:

* **A screen genuinely cannot distinguish them.** The pixels are the same, so
  this is a naming rule, not a recognition improvement. `verify_glyphs` is
  unaffected: it is told which character to expect and compares that glyph, which
  is never ambiguous.
* **This is #41's shape again from the other side** — a diagnostic that had never
  been checked against the thing it claims to check. `read_text` had been in use
  since spike S1 and had been right every time, because every needle anyone had
  ever written happened to avoid the eight ambiguous glyphs. The first assertion
  about a typed computer name found it in one run.

## 47. CI builds arm64, and amd64 buys exactly one stage per dispatch

2026-08-25, [run 32830869552](https://github.com/upinblue/OS7/actions/runs/32830869552)
— the first `workflow_dispatch` of `.github/workflows/build-iso.yml` in this
history, from `main` at cfdc0bf.

**arm64: SUCCESS, 15m57s, artifact uploaded.** An OS/7 ISO — `OS7-1.0.0.42-arm64.iso`
— now builds on a hosted runner and not only on this Mac. The `ubuntu-24.04-arm`
label scheduled the job, which is the second measurement of the thing #44 said
was never unverified.

**amd64: FAILURE, 23m2s — and it confirmed #44's fix before it died.** The
binary stage reads:

```
[2026-08-25 09:37:19] lb_binary_memtest
[2026-08-25 09:37:19] lb_binary_grub
```

Thirty-five milliseconds, no `P: Begin installing memtest...`, no
`cp chroot/boot/.bin`. `--memtest none` reached the early `exit 0` on a real
native x86_64 build, which is the check #44 said had not been made. The same log
carries `--memtest none` on the `lb_config` line, so the flag arrived where it
was aimed.

Then, one stage later:

```
[2026-08-25 09:37:19] lb_binary_syslinux
P: Begin installing syslinux...
Package gfxboot-theme-ubuntu is not available, but is referred to by another package.
E: Unable to locate package syslinux-themes-ubuntu-oneiric
E: Package 'gfxboot-theme-ubuntu' has no installation candidate
make: *** [Makefile:126: build-amd64] Error 100
```

### The mechanism

`lb_binary_syslinux`, Ubuntu branch:

```sh
case "${LB_SYSLINUX_THEME}" in
	live-build)   Check_package chroot/usr/bin/rsvg librsvg2-bin ;;
	*)            Check_package …/themes/${LB_SYSLINUX_THEME} syslinux-themes-${LB_SYSLINUX_THEME}
	              case "${LB_MODE}" in ubuntu) Check_package … gfxboot-theme-ubuntu ;; esac ;;
esac
```

The default theme name is **`ubuntu-oneiric`**. Oneiric Ocelot is Ubuntu 11.10.
The stage asks a 2026 archive for a package named after a release from 2011, and
`gfxboot-theme-ubuntu` is gone as well. The literal string `live-build` is the
one value that takes the other branch. Measured after the change: `lb config`
yields `LB_SYSLINUX_THEME="live-build"` on both architectures, and arm64 does not
care either way — `lb_binary_syslinux` exits at `[ "${LB_BOOTLOADER}" != "syslinux" ]`
long before the theme is read.

### The larger thing this exposed

`LB_BOOTLOADER` is **`syslinux`** on amd64 today, and syslinux is a BIOS
bootloader. OS/7 boots UEFI, with shim and a Canonical-signed GRUB (README,
locked decisions), and this live-build has **no grub-efi stage at all**:

```
lb_binary_grub  lb_binary_grub2  lb_binary_syslinux  lb_binary_yaboot  lb_binary_silo
```

— `--bootloader` accepts `grub|syslinux|yaboot`, and nothing there emits an EFI
boot path. That is the *same hole* `build/lib/efi-remaster.sh` was written
to fill on arm64, and it means **the amd64 medium needs its own remaster before
it can boot the way the product requires.** `--syslinux-theme live-build` is a
stopgap that lets the build reach a point where there is something to remaster;
it is not the amd64 boot story.

### Also measured, and cheap

`path: out/*.iso` in the upload step matches the versioned ISO **and** the
`os7-<arch>.iso` symlink beside it, and `upload-artifact` follows the symlink:
the arm64 artifact came out at **3974 MiB for one 2 GB image.** `out/OS7-*.iso`.

### The third death, in the same stage, and why the poking stopped

[Run 32833370939](https://github.com/upinblue/OS7/actions/runs/32833370939), with
`--syslinux-theme live-build` in place: the theme packages were gone, the stage
got further, and it fell over on the next line.

```
P: Begin installing syslinux...
cp: cannot stat '/root/isolinux/vesamenu.c32': No such file or directory
```

arm64 was green again in the same run — 15m21s — and the artifact came out at
**1987 MiB**, half the previous one, which is the `out/OS7-*.iso` fix measured.

At this point the interesting measurement is not the next missing file. It is
this pair:

```
amd64: LB_BOOTLOADER="syslinux"
arm64: LB_BOOTLOADER=""
```

**arm64 has been building with no bootloader stage at all since the first ISO**,
and that is precisely why `build/lib/efi-remaster.sh` exists — OS/7 already
owns its medium's boot path on one architecture. Every bootloader stage guards on
`[ "${LB_BOOTLOADER}" != "<its own name>" ]`, and `lb_binary_iso`'s
`case "${LB_BOOTLOADER}"` has no branch for an unknown value, so `none` is inert
on both. `--bootloader none` therefore does not disable something amd64 needed;
it puts amd64 in the position arm64 has been in all along.

And the thing being disabled was never shippable: syslinux is a **BIOS**
bootloader, OS/7 boots UEFI with shim and a Canonical-signed GRUB, and this
live-build has no grub-efi stage to offer instead. Three fixes into
`lb_binary_syslinux` would have produced a boot path OS/7 cannot use.

**What it costs, stated plainly:** live-build now emits an amd64 ISO with no El
Torito entry — contents without a boot path. `check-image.py` reads all of it
without booting, which is where the unanswered amd64 questions actually live
(does the rootfs carry GNOME, Edge and Intune; does `os7-setup` run on x86_64;
did the pin hold). Making that medium boot is an **amd64 EFI remaster**, the
sibling of the arm64 one, and it is not written.

### The fourth: `isohybrid`, exit 127, and the same asymmetry a third time

[Run 32835838228](https://github.com/upinblue/OS7/actions/runs/32835838228), with
`--bootloader none`: **every bootloader stage passed straight through** —
`lb_binary_memtest`, `lb_binary_grub`, `lb_binary_grub2`, `lb_binary_syslinux`,
four stage markers inside 105 ms and not one line of work between them — and the
build reached `lb_binary_iso`, wrote the medium to **99.97%**, removed its build
depends, and then died with no message at all:

```
make: *** [Makefile:126: build-amd64] Error 127
```

127 is *command not found*, and nothing in the log names the command. It is in
live-build's source: `lb_binary_iso` writes a `binary.sh`, and when
`LB_BINARY_IMAGES` is `iso-hybrid` it appends one more line to it —

```sh
isohybrid ${ISOHYBRID_OPTIONS} ${IMAGE}
```

`isohybrid` is in **syslinux-utils**. The stage installs **syslinux**. So the
script runs `genisoimage` successfully and then calls a command that was never
there; `sh binary.sh` returns 127, and `set -euo pipefail` in `build/build.sh`
carries it all the way to make. **The ISO had already been written when the build
failed.**

The defaults, measured:

```
amd64: LB_BINARY_IMAGES="iso-hybrid"
arm64: LB_BINARY_IMAGES="iso"
```

Third time in one afternoon: the amd64 default is the BIOS-flavoured one, the
arm64 default is the plain one, and OS/7 wants the arm64 shape on both.
`isohybrid` writes an MBR so a stick boots under legacy BIOS — a thing a UEFI
product does not want, on a medium that is going to be re-mastered anyway.

One more consequence to keep, because it is not free: with no `LB_BOOTLOADER`
case matching, `lb_binary_iso` never adds `-r`, and genisoimage says so —
*"creating filesystem with Joliet extensions but without Rock Ridge"*. The amd64
ISO live-build now emits has no Rock Ridge and no boot path. It is an artefact to
**read**, not to boot, until the amd64 remaster exists.

### Worth carrying

**Each dispatch buys exactly one stage — until you ask why you are in the stage
at all.** Three amd64 deaths, all in `lb_binary_*` code that has not been touched
since Ubuntu renamed what it asks for, and the third one was in a stage whose
output the product had already decided it would not use. The rootfs is not the
hard part on amd64; assembling the medium is. And the cheapest way through a
stale stage is to establish that you never wanted it — which the *other*
architecture's config had been saying the whole time, in one empty variable.

## 48. Refactoring something proven: the hash said it changed, and the hash was the wrong instrument

2026-08-25. `build/lib/arm64-efi-remaster.sh` became `build/lib/efi-remaster.sh`
and took an architecture argument, so that amd64 could be re-mastered by the same
code rather than by a copy of it. The thing being edited was the only reason any
OS/7 ISO boots, and the edit had to be proved not to change arm64.

### The obvious check gives a wrong answer

Run the old script, run the new one, compare the ISOs:

```
old      57978880  b07ff871437cf228
new      57978880  4b47b07a40b30938
```

Different. On that evidence the refactor changed the artefact — and the
conclusion would have been wrong. **The control is the whole experiment:** run
the OLD script twice, against two identical synthetic trees.

```
old1     57978880  b07ff871437cf228
old2     57978880  d5fb4ff80984ff15
```

The old script does not reproduce itself either. `xorriso` stamps a creation time
into the PVD, so two runs a second apart differ. Comparing hashes across a
refactor of this script can only ever produce "different", whatever the change
was — the instrument reads noise at full scale.

### What can be compared, and was

* **The GRUB menu** — `diff` on `binary/boot/grub/grub.cfg`: identical. This is
  the file SETUP-PLAN §7 specifies and the one a person actually sees.
* **The EFI binary** — `grub-mkstandalone` IS deterministic here: all three runs
  produced the same 6811648 bytes, same SHA-256. So the payload that boots the
  machine is provably unchanged, even though its container is not.
* **The ISO's structure** — `xorriso -indev … -report_el_torito plain -find /`,
  with dates filtered out: **no difference**. Same tree, same El Torito catalog,
  one UEFI boot image at `/boot/grub/efiboot.img`, MBR cyl-align-all.

Three instruments that can distinguish signal from noise, in place of one that
cannot.

### Worth carrying

**Before comparing two artefacts, find out whether one of them equals itself.**
The reproducibility of the output is a property of the tool, not of the change,
and it decides which comparison means anything. This repository already knew the
neighbouring version of that rule — an exit code is a diagnostic, ask the thing
itself — and this is the same mistake wearing a checksum.

### While in there: the medium is UNSIGNED, on both architectures

`grub-mkstandalone` produces an unsigned GRUB, so **the OS/7 install medium boots
only with Secure Boot OFF**. That has been true of every arm64 ISO this project
ever built, and nothing had written it down, because the arm64 harnesses do not
enable Secure Boot and spike S4 tested the INSTALLED disk — shim plus
Canonical-signed GRUB on the ESP, which is a different boot path from the one the
ISO takes.

It matters more on amd64: that firmware ships with Secure Boot enabled, so the
first person to try the medium on real hardware meets it. The pieces for the
other approach are already in the image (`shim-signed` 1.59+15.8,
`grub-efi-amd64-signed` 1.215+2.14, and their arm64 equivalents), and the cost is
that a signed GRUB has a fixed prefix and loads only signed modules, so the
embedded-config trick above cannot be used. Open item, recorded here rather than
in a fix.

## 49. The Install entry booted amd64 into GNOME, and only a boot could have said so

2026-08-25, the first boot of a re-mastered amd64 ISO — `OS7-1.0.0.47-amd64.iso`,
under `qemu-system-x86_64` with edk2, TCG, on Apple Silicon.

Everything the remaster is responsible for worked, and the serial log says so:

```
BdsDxe: starting Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x3,0x0)
GNU GRUB  version 2.14
*Install OS/7 (amd64)
```

Firmware found `/EFI/BOOT/BOOTX64.EFI`, GRUB loaded, the menu is OS/7's, the
default entry is Install. Then the ten-second timeout ran out, the entry booted —
and at 160 s the screen held **a GNOME desktop**.

Walking the VTs settles what that means, because a photograph of a desktop cannot
tell two different bugs apart:

| VT | what is on it |
|---|---|
| tty1 | blank grey — the display manager's |
| tty2 | the GNOME session |
| tty3 | `Ubuntu 26.04 LTS ubuntu tty3` / `ubuntu login:` |

**os7-setup is on none of them** — at 200 s. That sentence is as far as this
measurement reaches, and the first version of this entry went further than it
should have: it said *absent*, meaning never started. That is wrong, and the
correction is below.

### Why

Read out of the image itself, no VM involved:

```
/usr/lib/systemd/system/os7-setup.service          present
  ConditionKernelCommandLine=os7.setup=1           satisfied by the Install entry
  Conflicts=getty@tty1.service   TTYPath=/dev/tty1
/etc/systemd/system/display-manager.service -> gdm3   ENABLED
```

Both are correct in isolation. The Install entry pulls in `os7-setup.service`,
which takes tty1; `graphical.target` pulls in gdm3, which takes the screen; the
display manager wins. **arm64 is server-only and has no display manager at all,
so nothing on arm64 could ever have exposed this** — the entry has worked there
since Phase 1, and every screenshot in `.vm/phase1/shots/` was taken on a machine
with nothing to lose the race to.

### CORRECTION, measured the same afternoon: displaced, not absent

Booting the same ISO again and photographing earlier:

| t | what is on the screen |
|---|---|
| 95 s | **OS/7 Setup**, Welcome screen, painted, version 1.0.0.47 |
| 310 s | the GNOME desktop |

So `os7-setup` **starts, wins tty1, and paints** — and is then displaced by the
desktop. The VT walk above ran at 200 s, i.e. after the hand-over, and read an
absence at one moment as a cause. That is the same error as the cancelled CI
build earlier that day: a thing not being somewhere when you look is not the same
as it never having been there.

The direction of the diagnosis survives — `graphical.target` takes the screen —
but "never started" was wrong, and it mattered: it would have sent the next
person looking for a unit that failed to start, when the unit works.

### The fix, verified, and why it is a command line rather than another `Conflicts=`

`systemd.unit=multi-user.target` typed into GRUB's editor on the same ISO, on the
`linux` line, booted with ctrl-x: **at 310 s the Welcome screen is still there.**
The unmodified entry had been showing a desktop at that same point. One variable,
one run each.

Three caveats, because this is a probe and not a harness:
* one run per condition, not repeated;
* in the test the parameter sits **after `---`** (that is where End puts the
  cursor), while the shipped entry has it before. systemd reads `/proc/cmdline`
  either way, but the shipped placement is not what was tested — the CI ISO is;
* 310 s is a moment, not a proof that Setup survives indefinitely. It is past the
  point where the desktop had already taken over.

Two earlier attempts at this test proved nothing and are worth recording, because
both failed the same way — an assumption where a measurement belonged. The first
waited 95 s for the menu while GRUB's own `set timeout=10` had long fired: the
entry booted unmodified and the keystrokes went into Setup's Welcome screen. The
second synchronised on GRUB's serial banner but pressed `down` twice, and the
body of a menu entry is `setparams` / **blank** / `search` / `linux` / `initrd` —
so the parameter landed on the `search` line and the kernel never saw it.

**What caught both was photographing the edited line before booting it.** Without
that frame, the second run would have been reported as "the fix does not work".

`systemd.unit=multi-user.target` on the Install entry. The entry is a text-mode
installer and has no business reaching the graphical target; not asking for it
beats out-fighting it. The line is **inert on arm64**, which never reaches that
target anyway, so both architectures carry the same command line and it does
something on exactly one of them.

The **live** entry deliberately does not get it. On amd64 "try before you
install" (L14) means a desktop, and the live entry is what promises one.

### The copies

`run-phase1.py`, `run-phase2.py` and `run-phase3.py` each carry the Install
command line verbatim, with a comment in phase 1 that says why: *"If these ever
disagree, the harness is testing something the ISO does not do."* All three were
updated with the remaster. Four copies of one string is a standing invitation to
the bug that comment describes — the harnesses need to read the line off the ISO
rather than restate it, and that is not done here.

### Worth carrying

**A result on the architecture without the competing component is not a result.**
This is #12 and #23 in a third costume: an arm64 pass said nothing about amd64,
not because the code differs but because the *image* does. Whenever the two
package sets diverge — and they diverge by 979 packages — any claim about
behaviour has to name which image it was measured on.

## 50. The consumer of a unit is enabled and the producer is not — and the enable-list reads like proof

`systemctl is-enabled` was asked of a machine installed by os7-setup, booted from
its own disk with a NIC attached, on 2026-08-25:

```
systemctl is-enabled networkd-dispatcher     enabled
systemctl is-enabled systemd-networkd        disabled
systemctl is-active  systemd-networkd        inactive
```

`networkd-dispatcher` exists to run scripts when `systemd-networkd` changes an
interface's state. It is a **consumer**. It was in
`/etc/systemd/system/multi-user.target.wants/` and the thing it consumes was not
enabled at all.

The machine's actual state:

```
2: enp0s2: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN
ip -o addr show    1: lo  inet 127.0.0.1/8     (and nothing else)
ip route show      (empty)
```

`qdisc noop` is the queueing discipline of an interface nothing has ever
configured. Not "DHCP did not answer" — that leaves a link UP and an empty
address. The link was never brought up, there was no route, and **nothing on the
machine reported a problem.**

**Why this is a trap and not just a bug.** Anyone diagnosing "why is this server
unreachable" looks at what is enabled. `networkd-dispatcher.service` is there,
its name contains `networkd`, and the natural reading is that networking is
configured and something else is wrong. The wrong conclusion is available before
the right question is asked.

It is the same family as #48 and #49 — a diagnostic that answers a neighbouring
question — but from a new direction: not a program reporting success without
changing anything, but a **status word about component A being read as a
statement about component B.** Two more instances turned up the same afternoon:
a peer session read a CI run's `completed/success` as "normal" without
subtracting the timestamps (it had taken four times as long), and an idle
notification about a *session* was nearly read as a statement about the *VM* that
session had started.

**The guard:** ask the producer, and ask it for behaviour rather than for
configuration. `is-enabled` is a statement about a symlink. `ip -o addr` and
`ip route` are statements about a computer. Where a unit's presence is the
evidence, name which unit does the work.

**How it got there:** the shipped image enables `networkd-dispatcher` because
Ubuntu's package does, and nothing enabled `systemd-networkd` because nothing had
ever needed to — `/etc/netplan/` is empty, there is no `cloud-init`, and on the
amd64 desktop `network-manager` takes every device and hides the whole question.
Fixed by SETUP-PLAN Phase 3b's `NetworkStep`, which enables it and then checks
the symlinks rather than `systemctl`'s exit code. L23.

---

## 51. `iw scan` escapes non-printable SSID bytes — the byte level is not the character level

A hidden network advertises a zero-length or zero-filled SSID. `iw dev … scan`
does not print those bytes; it prints them **escaped**, four characters per byte:

```
BSS aa:bb:cc:dd:ee:04(on wlan0)
	signal: -80.00 dBm
	SSID: \x00\x00\x00
```

A parser filtering `ssid.All(c => c == '\0')` therefore filters nothing. The
network reaches the picker as a row of literal backslash-x-zero-zero, which
nobody can select and nobody can remove.

Same shape as #46, where `read_text` decoded a plain hyphen as U+00AD because
eight bitmaps in the console font belong to more than one codepoint. Both times
the byte level and the character level were confused; both times the result
looked plausible.

**Evidence, and its limit.** Found by feeding a *recorded* `iw scan` to the
parser in `os7-setup --self-test` on 2026-08-25, not by scanning with a radio.
The Wi-Fi association test that exists (`run-phase3b-network.py wifi`, over
`mac80211_hwsim`) does a real scan but does not broadcast a hidden network, so
the escaping itself is still lab evidence rather than field evidence.

**The guard:** separate the parser from the command that produces the text, and
test it against captured output. `WifiScan.Parse` in
`installer/src/OS7.Setup/Model/NetworkLinks.cs` is a pure function for exactly
this reason — a parser whose only test is a wireless card is a parser tested on
one network, once.

---

## 52. `otf2bdf` scales uniformly, so a font whose em is not its cell can never hit an 8×16

Found while evaluating Cascadia Mono for the installed console
([SESSION-CASCADIA-CONSOLE.md](SESSION-CASCADIA-CONSOLE.md), SETUP-PLAN §2.8).

`build/lib/build-console-font.sh` gets an exact 8×16 out of Fixedsys Excelsior
because that font's em **is** the console cell: `unitsPerEm = 160`, ascender 130,
descender −30, so `-p 16 -r 72` gives ascent 13 + descent 3 = 16 and an advance
of exactly 8. Nothing about that is generic, and it is easy to read the pipeline
as if it were.

Cascadia's em is 2048 while its line box is 1200 × 2380. Sweeping the horizontal
resolution at a fixed point size:

```
otf2bdf -p 14 -rh N -rv N  CascadiaMono.ttf

  -rh 74  (ppem 14.39)   ascent 12  descent 3  cell 15   DWIDTH 8
  -rh 75  (ppem 14.58)   ascent 13  descent 3  cell 16   DWIDTH 9
```

The cell height reaches 16 in the same step the width leaves 8. **There is no
setting in between**, and `-rv` is not the escape hatch it looks like: it is
documented as "set the vertical resolution" and it does change the BDF's
`RESOLUTION_Y` field, but the outlines are scaled from `-p × -rh` alone. Sweeping
`-rv` 70…74 against a fixed `-rh 70` moved neither ascent, descent nor `DWIDTH`
by one pixel.

So the reachable cells for this font are **8×15 and 9×16**, and which one you get
is not a choice you make separately from the width. Taking 9×16 is not a free
escape either — it makes the large cell 18×32, and SETUP-PLAN §2.4's geometry
rule is anchored on 1280×800 giving exactly 80×25, which becomes 71×25.

**The fix is not a flag.** Rasterise straight to the cell with the two axes
scaled independently (`x_ppem = W·upem/advance`, `y_ppem = H·upem/lineBox`) and
write PSF2 directly. Same rasteriser underneath — FreeType is what `otf2bdf`
uses — but the cell is stated instead of inferred from metrics that were never
about a console.

**Also confirmed here: trap #24 is not Fixedsys-specific.** `otf2bdf` exits 8 on
Cascadia too, at every size tried, while writing a correct BDF. So the
assert-the-artefact handling in `build-console-font.sh` is the right shape for
any font, not a workaround for one.

## 53. Two files, one font version, different pixels — "2407.24" does not identify a rasterisation

Found in the same evaluation.

`fonts-cascadia-code` in the Ubuntu archive and the upstream GitHub release are
both Cascadia **2407.24**, and both report `Version 2407.024` internally. They do
not render the same. Over a 132-character sample, rasterised into identical
cells:

```
  8×16  hinting on    106 of 132 glyphs DIFFER
  8×16  hinting off     1 of 132 differs
 16×32  hinting on    113 of 132 glyphs DIFFER
 16×32  hinting off    10 of 132 differ
```

The archive ships the **variable** font; the release also ships static
instances, and only those were run through `ttfautohint` — visible in the name
table as `Version 2407.024; ttfautohint (v1.8.4)` versus a bare
`Version 2407.024`. Both files carry `fpgm`, `prep`, `cvt ` and `gasp`, so
"is it hinted" cannot be answered by asking which tables exist.

**What makes this a trap rather than a curiosity:** every obvious identifier
agrees. Same upstream version, same family name, same metrics, same coverage,
same licence. A future session swapping the source for a good reason — the ZIP
is 150 MB, or the package moved — would have no signal that it just re-rendered
every character on every console, and no coverage check would notice, because
coverage is unchanged.

Same shape as #26: the codepoint is mapped, the picture is different. The guard
is the same too — **pin the file, not the version**, and treat the source as
part of the pin. SETUP-PLAN §2.8 records the SHA256 of the exact TTF, not just
the package version.


## 57. A direct rasteriser answers every request — `.notdef` passed both coverage checks

Found while building the Cascadia PSFs
([SESSION-CASCADIA-CONSOLE.md](SESSION-CASCADIA-CONSOLE.md), SETUP-PLAN §2.8),
one step after #52 removed `bdf2psf` from that route.

`bdf2psf` will not emit a glyph the source font does not have; it leaves the
position out and logs it. Replacing it with a FreeType-based rasteriser removes
that behaviour without announcing it: **FreeType answers every request.** Ask it
for a codepoint the font lacks and it returns glyph 0 — and in Cascadia glyph 0
is a hollow rectangle, not an empty cell.

So the first build mapped `U+21B5` (absent from Cascadia's cmap) to a box, and
`psf.py verify` reported the font **complete**:

```
ok    Arrows (the rest): 4/4
```

Both of the guards that exist for this failed to fire, and neither was wrong to:

* the **coverage** check asks whether the codepoint is mapped — it is;
* the **blank** check asks whether the bitmap has ink — it has plenty.

The only signal was a contradiction between two measurements taken minutes
apart: reading Cascadia's `cmap` directly said `U+21B5` was missing, and reading
the built PSF said it was present. Nothing in the pipeline compared the two.

**Fix:** consult the source font's `cmap` before rasterising and skip what is not
there. `verify` then reports the absence as a note, which is the truth. The
one-line version of the rule, already in this file twice (#26, #46): *a codepoint
being mapped is not evidence that it is mapped to the right picture.*

Worth stating in general, because the next font conversion will meet it too:
**when a pipeline step is replaced, its silent guarantees go with it.** `bdf2psf`
was not only converting — it was also refusing, and the refusal was load-bearing.

## 58. The rasteriser is a container package, so rebuilding the container changes the console

Found while putting SETUP-PLAN §2.8's route into the build.

The Cascadia pipeline pins two inputs — the `.deb` from the archive snapshot and
the TTF inside it — and both hashes matched on every run. The output still moved:

```
same TTF, same cellfont.py, same 8x16 cell

  libfreetype 2.13.2 (host)          }
  libfreetype 2.14.2 (container)     }  41 of 409 glyphs DIFFER
```

It is not subtle where it lands. `U+0022 "` goes from two one-pixel strokes to a
solid four-pixel block, and most accented capitals shift a row. The affected
glyphs are the ones with fine detail — exactly where hinting decides things.

**Nothing in the pin could see this.** `libfreetype6` comes from the build
container, which is `FROM ubuntu:26.04` and not archive-pinned; the font pin
describes what goes *in*, and the rasteriser is not an input, it is the
machinery. So `docker build` on a different day is enough to change what every
console looks like while `os7-release.conf`, the `.deb` hash and the TTF hash all
stay exactly as they were.

That is the same rule spike S7 tested one layer up (two builds from one pin hold
identical package sets, SESSION-RELEASE-IDENTITY): **a version number is only
honest if what it names is fixed.** A pinned input does not fix an output when
something unpinned sits between them.

**Fix: pin the artefact.** `OS7_CASCADIA_PSF_SHA256_8x16` / `_16x32` hold the
SHA256 of the built PSFs, and `build-installed-console-font.sh` fails the build
when they do not match, naming the libfreetype version it found. Drift becomes a
build failure with a diff to look at, instead of a silent redraw.

**Measured and NOT a factor: architecture.** arm64 and amd64 containers on the
same libfreetype produce byte-identical PSFs, so one pair of hashes covers both.
Worth stating because the opposite would have needed two pins and an explanation
of which is authoritative.

Related, same session: `dpkg-deb -x` inside the **amd64** container on Apple
Silicon dies with `Cannot open: Function not implemented` on every file — trap
#12's `ENOSYS` again, since `dpkg-deb` shells out to GNU tar. So this script
cannot run for amd64 on this Mac, exactly like `debootstrap`. It fails loudly
rather than producing a short font, and CI is unaffected.

## 54. dconf does not know what a GSettings key is — a typo compiles, stores, and reads back correctly

The classic desktop's defaults — theme name, black background, window button
layout, which GNOME extensions are on — are a keyfile at
`/etc/dconf/db/os7.d/00-os7-classic`, compiled into a binary database by
`dconf update`.

**The claim this entry started as was wrong, and the measurement is what said
so.** The guess was that `dconf update` exits 0 for a keyfile it cannot parse.
It does not. Measured in a container against the pinned archive
(`20260824T000000Z`, `dconf-cli 0.49.0-4`):

```
well-formed keyfile          exit=0   database 339 B   both keys read back
duplicated group header      exit=0   database 442 B   both keys read back
line with no '='             exit=1   database ABSENT  "not a key-value pair"
unquoted string value        exit=1   database ABSENT  "invalid value: 0:expected value"
```

So syntax is checked, loudly, and a duplicated group header is not even an
error — GKeyFile merges the two. `set -e` in a postinst is enough for that
whole class.

**What is not checked is whether any of it means anything.** dconf is a
key-value store with no knowledge of GSettings schemas. Same container, one
keyfile with a misspelled key and a misspelled group, no syntax error anywhere:

```
[org/gnome/desktop/interface]
gtk-theme='OS7-Classic'
gtk-theme-name='OS7-Classic'        <- no such key

[org/gnome/desktop/interfase]       <- no such schema
font-name='Tahoma 9'
```
```
dconf update                             exit=0, database 446 bytes
dconf read …/interface/gtk-theme         ['OS7-Classic']
dconf read …/interface/gtk-theme-name    ['OS7-Classic']   <- stored happily
dconf read …/interfase/font-name         ['Tahoma 9']      <- stored happily
dconf read …/interface/font-name         []                <- where it was meant
gsettings get …interface font-name       'Adwaita Sans 11' <- what GNOME uses
```

Every layer reads as healthy. The package installed, `dpkg -V` is clean, the
keyfile is right there, `dconf update` succeeded, a database exists, and the
values read back — from the paths that are wrong. The desktop comes up stock
and nothing anywhere says why.

**The part worth remembering is what this did to the guard.** The first version
of `build/testing/verify-theme-package.sh` walked every group in the keyfile and
checked that each one reached the database. Against this failure it passes:
both sides of the comparison come from the same misspelled file, so it proves
the keyfile agrees with itself. That is exactly the rule at the top of this
repository — *a diagnostic must not depend on the subsystem it is diagnosing* —
being broken by the person who wrote the rule down that morning.

The independent authority is GSettings, because GSettings is what actually
reads these values, and it knows which schemas and keys exist:

```
gsettings list-schemas | grep -qx "$schema"      does the schema exist
gsettings list-keys "$schema" | grep -qx "$key"  does the key exist in it
```

Both `build/config/hooks-amd64/0090-desktop-theme-verify.hook.chroot` and
`verify-theme-package.sh` now run every `(schema, key)` pair from the keyfile
through that, which also catches the slow version of the same failure: a key
GNOME removes in a future generation, leaving a line in our keyfile that
compiles, stores, reads back, and does nothing.

## 55. `fonts-wine` contains no fonts

Windows 2000's UI font is Tahoma, which is not redistributable. Wine ships a
metrically compatible replacement under LGPL-2.1+, which is — so `fonts-wine`
looks like the obvious dependency for a classic theme.

It is not. Measured by unpacking both packages from the pinned snapshot:

```
fonts-wine_10.0~repack-12ubuntu1_all.deb        4418 B download, 56 KB installed
  usr/share/fonts/truetype/wine/tahoma.ttf   -> ../../../wine/fonts/tahoma.ttf
  usr/share/fonts/truetype/wine/tahomabd.ttf -> ../../../wine/fonts/tahomabd.ttf
  … 13 files, ALL symlinks, zero bytes of font data

wine-common_10.0~repack-12ubuntu1_all.deb    1866768 B download, 11 MB installed
  usr/share/wine/fonts/tahoma.ttf                145040 B   <- the actual font
  usr/share/wine/fonts/tahomabd.ttf              139144 B
```

A 4 KB package named `fonts-*` that installs 13 `.ttf` paths reads exactly like
a font package. It is a symlink farm, and its `Depends: wine-common` is the
only thing that makes the links resolve. Copy the files out of `fonts-wine`
alone — the obvious way to avoid putting `wine-common` on a managed corporate
desktop — and you ship 13 dangling symlinks. **fontconfig then substitutes the
default sans face and reports nothing**, which is the same silence as #26 and
#53: the request is satisfied by something that is not what was asked for.

Two consequences, both now in the build:

* `build/lib/build-desktop-theme.sh` extracts the two faces from `wine-common`
  and ships them in OS/7's own package with the LGPL notice beside them. Nothing
  called `wine` is installed on the running system.
* Neither the filename nor the package version is evidence of what a font is.
  `build/lib/ttf-family.py` reads the `name` table out of each extracted file
  and fails the build unless it says `family='Tahoma'`, `subfamily='Regular'`
  and `'Bold'` — because `font-name='Tahoma 9'` in the dconf database resolves
  by family name and by nothing else. Hook 0090 asks the same question of the
  installed image from the other end, with `fc-match`.
---


## 56. The interface name changes between installing and running, and netplan says nothing

The same machine, the same NIC, the same MAC — two names, measured 2026-08-25:

```
installing, setup medium attached      enp0s5
booted from the disk, medium removed   enp0s2
MAC, throughout                        52:54:00:12:34:56
```

Predictable interface names are derived from the PCI topology, and **the setup
medium is a PCI device**. Removing it renumbers the slots. So the name Setup sees
while it is installing is not the name the installed machine will use.

os7-setup wrote `/etc/netplan/01-os7-network.yaml` naming `enp0s5`. After the
reboot that interface does not exist, netplan matched nothing, and **netplan
accepts a match that matches nothing in silence.** The machine came up:

```
2: enp0s2: <BROADCAST,MULTICAST> qdisc noop state DOWN
ip -o addr show    1: lo  inet 127.0.0.1/8    (and nothing else)
ip route show      (empty)
```

— which is, line for line, the failure #50 describes. The screen built to prevent
it would have produced it.

**Every check was correct, and every check was about the wrong moment:**

| check | said | why it did not help |
|---|---|---|
| `--self-test` on the generated YAML | correct | it named a real interface — just not the one that would exist later |
| `netplan generate` in the chroot | a valid networkd unit | a unit that matches nothing is still a unit |
| reading that unit back for `Address=` | present | on an interface that would not exist |

**The only instrument that could see it was a machine booted with the medium
removed.** That split — `run-phase3.py boot` and `run-phase3b-network.py boot`
attach no ISO — came from spike S3 for a completely different reason: a VM that
still has the setup medium in it can boot *from the medium* and look exactly like
a successful install. It has now paid for itself twice, for reasons that have
nothing to do with each other.

**The guard:** match on the MAC, never on the name — `NetworkPlan.MacAddress`,
SETUP-PLAN L30. And the general form, which is the part worth carrying: **a
property read from the install environment is not automatically a property of the
installed machine.** The medium is part of the hardware while Setup runs and is
gone afterwards. Anything derived from PCI enumeration, device order or slot
numbering is suspect; anything derived from the device itself — a MAC, a serial,
a UUID, a by-id path — is not. `StoragePlan.Disk` already took this lesson (L12,
`/dev/disk/by-id/…` and never `/dev/sdb`); the network half had to learn it
again.

## 59. `setfont` refuses a font whose glyph POSITION 32 is not blank

Found by the vmscreen check on the installed console
([SESSION-CASCADIA-CONSOLE.md](SESSION-CASCADIA-CONSOLE.md)), and it is the
reason that check exists.

The installed machine came up showing the **8×16 kernel font**, not Cascadia at
16×32 — while `console-setup.service` was `enabled`, `active (exited)`,
`status=0/SUCCESS`. The service reported success and the screen said otherwise.

Asking `setfont` directly, on tty1, is what produced the answer:

```
# setfont /usr/share/consolefonts/os7-console-16x32.psf.gz < /dev/tty1 > /dev/tty1
setfont: ERROR setfont.c:142 try_loadfont: font position 32 is nonblank
setfont: ERROR setfont.c:154 try_loadfont: background will look funny
  exit 71

# the same command with the Fixedsys PSF
  exit 0        and `stty size < /dev/tty1` then reads  25 80
```

**`kbd` requires glyph position 32 to be empty**, because the console uses that
slot as its erase character — a screen clear paints position 32, so a font with
ink there fills the background with it. `cellfont.py` had packed the codepoints
in `psf.py` table order, which put `U+0040 @` at position 32, and the kernel
refused the whole font.

**Every check that existed was green, and every one of them was right.**
`psf.py verify` asks about coverage, about shapes that must differ, and about
cell tiling. This is a question about **positions**, and nothing asked it. The
build was green, the ISO carried the right bytes, the hash on the disk matched
the pin — and the console displayed a different font.

Same week, same class, three different axes:

| | every check correct, but about… |
|---|---|
| #57 `.notdef` | the wrong **glyph** — mapped, non-blank, and a hollow rectangle |
| #56 (os7-b1) | the wrong **moment** — the interface name before the medium was removed |
| this one | the wrong **property** — coverage and shape, never position |

None of them would have been caught by checking harder. Each needed an axis
nobody had thought to measure.

**Fix, structural rather than a guard.** ASCII now sits at position == codepoint,
so slot 32 is `U+0020` and blank by construction; 0–31 are left empty and the
rest follows from 127. `cellfont.py` also asserts position 32 is blank before
writing, so a future layout change cannot reintroduce it quietly — but the
assertion is the second line of defence, not the first.

### And then it failed again, differently

With position 32 blank, `setfont` got one step further and the KERNEL refused it:

```
setfont: ERROR kdfontop.c:240 put_font_kdfontop: ioctl(KDFONTOP): Invalid argument
  exit 71
```

`fbcon` accepts two glyph counts and no others:

```c
/* drivers/video/fbdev/core/fbcon.c, fbcon_set_font() */
if (charcount != 256 && charcount != 512)
        return -EINVAL;
```

The font had **441**. A perfectly valid PSF, and an unloadable console font.

**The number was in the repo the whole time and written down as the wrong kind
of fact.** `build-console-font.sh` passes `512` to `bdf2psf`; `psf.py` calls it
`PSF_MAX_GLYPHS`; SETUP-PLAN §2.5 says "PSF caps at 512 glyphs". Every one of
those reads as an upper bound, so a font with fewer looked comfortably inside
it. It is not a cap — it is one of exactly two permitted values, and Fixedsys
only ever worked because `bdf2psf` was told to emit 512 and pads to fill them.

`cellfont.py` now pads to 256 or 512. Measured after the change, on the running
machine: `setfont` returns 0 and `stty size < /dev/tty1` goes from `50 160` to
**`25 80`** — the reference geometry §2.4 anchors the layout rule on.

**Two refusals, one lesson, and it is not "check harder".** Both requirements
belong to the CONSUMER — kbd and the kernel — and neither is visible in the
artefact's own definition of correctness. A PSF can satisfy every property this
repo knows how to assert and still be rejected by the thing that loads it. The
only check that closes that gap is handing the artefact to the real consumer,
which here meant booting a machine and reading `$?`.

**Both are now asserted, for both fonts.** `psf.py verify` gained the two rules
as `PSF_GLYPH_COUNTS = (256, 512)` and `PSF_ERASE_POSITION = 32`, so the Fixedsys
pipeline is covered by them too — it happens to satisfy both already, because
`bdf2psf` is told 512 and pads, and puts `U+0020` at position 32. That is the
point: it satisfies them *by luck of a tool's defaults*, and nothing said so.

The guards were made to fire before they were trusted. A 441-glyph copy and a
copy with ink painted into slot 32:

```
FAIL  441 glyphs — fbcon accepts 256 or 512 and nothing else; setfont would
      report ioctl(KDFONTOP): Invalid argument                        exit 1
FAIL  glyph position 32 is not blank (it holds U+0020) — setfont refuses
      the font: 'font position 32 is nonblank'                        exit 1
```

`PSF_MAX_GLYPHS` survives as a derived alias so older references keep working,
with a comment saying it is not a maximum. SETUP-PLAN §2.5, L9 and L19 said
"caps at 512" and now say what the kernel actually does.

**And the lesson that generalises past fonts:** a build artefact can satisfy
every property its own verifier knows about and still be rejected by the thing
that consumes it. The only check that closes that gap is handing the artefact to
the real consumer. Here that meant booting a machine, and nothing cheaper would
have done.
