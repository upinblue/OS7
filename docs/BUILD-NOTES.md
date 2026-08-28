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

**#79 was, for a few hours on 2026-08-26, and the mechanism worked.** Four
source comments cited it before the entry existed; a second session read this
table, left it alone and took #80 instead. That is the first time this rule has
been exercised on purpose rather than after a collision — worth recording,
because the rule costs a commit and its value is invisible when it works.

Everything below is written. Numbers above 105 are free. (#94–#96 are claimed
by the Active Directory session and land with its commit; this tree jumps from
#93 to #97 on purpose rather than colliding.)

*(That line said 61 until 2026-08-26 and had been wrong since #62 landed —
it is the one line in this file nothing checks, and it is exactly the line a
session reads in good faith before claiming a number. Update it in the same
commit as the entry.)*

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

**And the same trap applies to what you do with the text afterwards**, which is
where it keeps coming back. A helper that returns everything the console showed
returns the shell's echo of the question along with the answer, so *any* test
against that text can be answered by the question:

* `command -v X || echo MISSING` → `"MISSING" in out` is **always true**;
* `modprobe … && echo LOADED` → `"LOADED" not in out` is **always false** — a
  green line that means nothing, which is the worse of the two;
* `test -e X && echo PRESENT || echo ABSENT` types **both** words;
* "the first integer in the text" finds the harness's own `OK<n>` marker. On
  2026-08-25 that reported 8, 10 and 11 for counts whose real values were 15, 2
  and 0, and called a leak in a file that had none.

Five instances in one file. The fix is the same shape as the rule above — let the
**shell** build what you match on: `printf 'N=%s\n' $(…)` types `N=%s`, which has
no digits in it, so a search for `N=` followed by digits cannot match the echo.
`installer/testing/run-phase3b-network.py`'s `ask_number()` is that.

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
---

## 60. `Write-Verbose` writes to STDOUT in PowerShell 7, and it breaks a JSON contract

`powershell/OS7/OS7.psm1` writes its progress with a hand-rolled
`[Console]::Error.WriteLine()`, and its header explains the contract it serves:
`os7-setup` runs `pwsh -NoProfile -Command …` and reads **exactly one JSON
object on stdout**, with progress on stderr, so the two can be told apart
(SETUP-PLAN §6.3).

That looks like something to modernise. `Write-Verbose` is the idiomatic way to
emit progress from a cmdlet, PowerShell has a verbose *stream*, and streams
other than Output conventionally go to stderr. Replacing the `[Console]` call
with `Write-Verbose` is a one-line cleanup that a reviewer would wave through.

**It is wrong, and the failure is silent.** Measured 2026-08-25, in the shipped
image (PowerShell 7.6.5, arm64), redirecting the two file descriptors of the
`pwsh` process separately:

```
Write-Verbose "V"   ->  STDOUT   "VERBOSE: V"
Write-Warning "W"   ->  STDOUT   "WARNING: W"
Write-Output  "O"   ->  STDOUT   "O"
Write-Error   "E"   ->  stderr
```

Only the error stream reaches stderr. Verbose and warning are rendered to the
host, and the host's output is stdout. So:

```powershell
function f { [CmdletBinding()] param() Write-Verbose "progress"; [pscustomobject]@{a=1} }
f -Verbose | ConvertTo-Json -Compress
```

puts this on stdout:

```
VERBOSE: progress
{"a":1}
```

which fails `json.load` outright — the installer would report that PowerShell
returned an unparseable result, about a module that did exactly what it was
asked.

**Why it would not be caught.** The pollution only appears when the verbose
stream is switched on, and nothing switches it on in the normal path: not
`--unattend`, not `run-phase3.py`, not a hand-run install. It appears the first
time somebody debugs a storage problem by adding `-Verbose` — which is to say,
at the worst possible moment, and it makes the diagnostic look like the fault.

**The rules that follow**, both now in `powershell/Zfs/Zfs.psm1` (Z5) and true
of `OS7.psm1` as it already stands:

* Machine-readable progress goes through an explicit stderr writer
  (`Write-ZfsStep` / `Write-OS7Step`). Always. That code is not a crutch.
* `Write-Verbose` is for humans, and never on a path whose stdout is somebody
  else's data channel.
* The IPC boundary suppresses the other streams by mechanism as well as by
  convention: `3>$null 4>$null 6>$null` before the pipe. A convention is a rule
  people follow; a redirect is a rule the runtime enforces.

**The general form**, which is the part worth carrying: *a stream is not a file
descriptor.* PowerShell's six streams are a host-level concept, and how a host
maps them onto fd 1 and fd 2 is the host's business — not something to infer
from the name. If a contract depends on which descriptor a byte lands on, write
to the descriptor.

---

## 61. A payload ISO lowercases its names, and the harness reported a tidy skip

Every VM harness here hands a script to the guest the same way: stage a
directory, `hdiutil makehybrid -iso -joliet` it into a small ISO, attach it, and
`mount -L OS7SPIKE /mnt` inside. `run-s3.py` has done it since Phase 0.

`run-zfs.py` staged a PowerShell module the same way — a directory `Zfs/`
containing `Zfs.psd1` — and the guest could not find it:

```
BOOTSTRAP-OK
ZFS-SELFTEST-SKIP (no module staged yet)
ALL-DONE
```

The module was on the medium. macOS, reading the same ISO, showed
`/Volumes/OS7ZFS/Zfs/Zfs.psd1`. Linux showed something else:

```
/p/payload.iso on /m type iso9660 (ro,relatime,nojoliet,check=s,map=n,blocksize=2048)

dr-xr-xr-x  zfs                 <- the directory is "Zfs" on the medium
-rw-r--r--  b.sh
-rwxr-xr-x  zfs-fixtures.sh
```

**`hdiutil makehybrid` writes no Rock Ridge**, and Linux mounted the result
`nojoliet` — so names come through the plain ISO 9660 directory records, which
Linux renders in lower case. `[ -f /mnt/Zfs/Zfs.psd1 ]` was false about a file
that was there.

**Why no harness had hit it in four months:** every earlier payload carried only
`b.sh`, `s3-zfs-luks.sh`, `s4-*.sh` — names that were already lower case, so the
mapping was the identity function and nobody could tell it was happening.

**Two things were wrong, and the second one cost the time.** The first is the
name mapping. The second is that the script tested `[ -f … ]` and, on false,
printed *"no module staged yet"* — a sentence describing a **different**
situation, one where the harness had deliberately not staged anything. A clean
skip is indistinguishable from success at a glance, and the run reported
`ALL-DONE` and exited. This is the standing shape again: the program reported a
normal outcome and the thing it was meant to do had not happened.

**The fix is to remove the class, not the instance.** The module now travels as
`module.tar` and is unpacked in the guest: a tar carries its own names, so
ISO 9660's rules and the mount options stop mattering. And when the module is
still not there, the script now prints `ls -la /mnt` and the unpack target
before giving up, so the next failure explains itself instead of being tidy.

**Carry this into any new payload:** anything with an upper-case letter, a name
longer than the ISO 9660 rules allow, or a nested directory should go through a
tar. `hdiutil makehybrid -iso -joliet` is only safe for a handful of lower-case
files at the top level, which is exactly the shape the existing spikes use and
exactly why they never revealed the limit.

## 62. `--mode ubuntu` makes live-build install the kernel, and it is not the one the package list names

**Found 2026-08-25** while implementing decision §4.2 of
[CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) — swap
`linux-generic` for `linux-image-generic` and drop 90 MiB of kernel headers that
exist to build DKMS modules OS/7 does not build.

`build/config/package-lists/os7-base.list.chroot` was changed from
`linux-generic` to `linux-image-generic`. **The build succeeded.** The shipped
manifest then said:

```
linux-generic                        7.0.0-30.30
linux-headers-7.0.0-30               7.0.0-30.30
linux-headers-7.0.0-30-generic       7.0.0-30.30
linux-headers-generic                7.0.0-30.30
linux-image-7.0.0-30-generic         7.0.0-30.30
linux-image-generic                  7.0.0-30.30
```

Both metapackages, and every header package the change was made to remove.

**Live-build installs a kernel of its own, beside the package lists.**
`lb_chroot_linux-image` writes `"${LB_LINUX_PACKAGES}-${LB_LINUX_FLAVOURS}"`
into `chroot/root/packages.chroot`, and the derived value differs by mode. Read
back out of the generated `config/chroot`:

```
--mode ubuntu   LB_LINUX_PACKAGES="linux"         ->  linux-generic
--mode debian   LB_LINUX_PACKAGES="linux-image"   ->  linux-image-generic
```

OS/7 is `--mode ubuntu`. So the package list was adding `linux-image-generic`,
live-build was adding `linux-generic`, apt satisfied both, and nothing anywhere
was wrong enough to complain. **A package list cannot remove what live-build adds
beside it.**

**The fix is one flag**, in `build/config/auto/config`:

```
--linux-packages "linux-image"
```

and it is verified the way BUILD-NOTES #36 says to verify every other flag —
by running `lb config` and reading `config/chroot` back, rather than by
reasoning about what live-build derives.

**Why this is worth a number.** The change was measured on the pinned archive's
own dependency graph beforehand, correctly; the graph said exactly what would
happen *if the package list were the thing that decided*. It was not. The only
reason this was caught is that the two manifests were diffed rather than the
build being believed — which is the standing rule in this repository, and this is
the fourth time it has paid: an exit code is a diagnostic, and so is a package
list.

**Related:** #13 (hooks that do not run and exit 0), #36 (fourteen mirror flags,
not five — read `config/bootstrap` back), #39 (`unsquashfs` exits 0 for a file
that is not there).

## 63. A `zfs clone` does not carry the origin's local properties, and a boot environment IS its properties

**Found 2026-08-25** by spike S5, on the first attempt to activate a cloned boot
environment.

`New-OS7BootEnvironment` cloned `rpool/ROOT/<be>` and its children and inferred
what to set: *if the source is `canmount=on`, make the clone `noauto`; otherwise
leave it alone.* The clone came out like this:

```
rpool/ROOT/os7_1.0.1.0_202608252123            on        <- source was noauto
rpool/ROOT/os7_1.0.1.0_202608252123/var        on        <- source was off
rpool/ROOT/os7_1.0.1.0_202608252123/var/lib    on        <- source was off
rpool/ROOT/os7_1.0.1.0_202608252123/var/cache  noauto
```

**A clone is created the way `zfs create` is** — properties come from its place
in the hierarchy, not from the origin. And **`canmount` does not inherit at
all**: a dataset that is not told takes the default, which is `on`. So every
inference about "the source was X, so the clone is X" is wrong, in both
directions.

Two consequences, and the second is the one that stopped the spike:

* **`canmount=on` with `mountpoint=/`** is a dataset the next `zfs mount -a`
  would mount over the running root. The same for `/var` and `/var/lib`.
* **`mountpoint` was `none`**, inherited from `rpool/ROOT`, because the source's
  `/` was a *local* property and local properties are not copied. GRUB's
  `10_linux_zfs` finds boot environments by looking for `mountpoint=/`, so **the
  clone was not a boot environment at all.** `update-grub` listed the origin
  snapshot and never the clone:

  ```
  Found linux image: vmlinuz-7.0.0-30-generic in rpool/ROOT/os7_1.0.0.95_202608251919
  Found linux image: vmlinuz-7.0.0-30-generic in rpool/ROOT/os7_1.0.0.95_202608251919@os7_1.0.1.0_202608252123
  ```

**What saved the machine was the guard, not the code.**
`Set-OS7BootEnvironment` reads the generated menu and refuses to point the ESP at
an environment that has no entry in it. It refused. Without that step the ESP
would have been aimed at a dataset GRUB cannot boot, and the next start would
have been a GRUB prompt on a machine that had been working a minute earlier.

**The fix is to stop inferring.** Both properties are read off the source WITH
THEIR SOURCE and set explicitly on every clone: `mountpoint` where the source
holds it locally, `canmount` always — mirrored, except that `on` becomes `noauto`
because a new environment is inactive until it is activated. And the function
then asks ZFS what it actually holds, because `zfs clone` exiting 0 says nothing
about either property.

**The check that let it through was worse than the bug.** The harness asserted
"no dataset in the clone is `canmount=on`" with a regex anchored `^\S+\ton$`
under `re.MULTILINE` — against text from a **serial console, which ends every
line with CR LF**. `$` never matched, the assertion was green, and the clone had
three such datasets. `body_of()` now strips CR once for every check in the file,
and the assertion counts and prints the offending lines rather than testing for
absence. Compare #16: the same class of harness bug, from the other end.

## 64. `systemd-cryptsetup` moved to `/usr/bin`, and the TPM handler asked for the old path

**Found 2026-08-25**, the first time TPM2 enrolment was ever actually performed
(spike S5). Everything worked except the boot:

```
install log   New TPM2 token enrolled as key slot 1
              sealed to PCR 7
              ok       libtss2-esys
              ok       libtss2-rc
              ok       systemd-cryptsetup
luksDump      Tokens:  0: systemd-tpm2   tpm2-hash-pcrs: 7   tpm2-srk: true
initramfs     scripts/local-top/os7-tpm2      present
              usr/bin/systemd-cryptsetup      present
              usr/lib/.../libtss2-*.so.*      present
ORDER         cryptopensc, os7-tpm2, zfs, cryptroot     <- ours runs BEFORE cryptroot
```

and the machine asked for the passphrase anyway.

**`scripts/local-top/os7-tpm2` began with**

```sh
[ -x /usr/lib/systemd/systemd-cryptsetup ] || exit 0
```

**On resolute (systemd 258) the binary is `/usr/bin/systemd-cryptsetup`.** So the
handler exited at its second line, every boot, silently — and an early `exit 0`
in a local-top script is indistinguishable at boot from a machine that has no
TPM at all.

**Three checks were in place and none of them could see it.** The enrolment step
greps the initramfs listing for `libtss2-esys`, `libtss2-rc` and
`systemd-cryptsetup`; the third one matched `usr/bin/systemd-cryptsetup` and
reported `ok`. The question it asked was "is it in there". The question that
mattered was "is it at a path the handler looks in", and those are different
questions about the same string. The grep is now **anchored to exactly the paths
the handler tries**, the handler's presence is asserted separately, and the
handler *searches* the candidate paths rather than naming one.

**And the handler now says why it gave up.** Every `exit 0` prints a line to the
console first. The reason this cost a whole install-and-boot cycle to find is
that the failing path produced no output at all — the correct diagnosis was
indistinguishable from "this machine has no TPM", which is a supported state.

**The hypothesis that was wrong, recorded because it was expensive to hold:**
that our script ran *after* `cryptroot` and therefore found the disk already
unlocked. `initramfs-tools` builds `scripts/local-top/ORDER` at image-build time
with `get_prereq_pairs | tsort`, and reasoning about tsort's tie-breaking from a
Mac (whose `tsort` orders differently) predicted the opposite of the truth. The
ORDER file inside the shipped initramfs is the answer, and reading it took two
minutes.

## 65. `$from` IS `-From`: a PowerShell variable name collided with a parameter, and the error named neither

**Found 2026-08-25** by spike S5, twenty-five minutes into a VM run.
`New-OS7BootEnvironment` took its two snapshots and then died with:

```
New-OS7BootEnvironment: Cannot convert value "mountpoint" to type "System.Int32".
Error: "The input string 'mountpoint' was not in a correct format."
```

The code:

```powershell
param([string]$Name, [string]$From, [string]$Release)
...
    $from = $props[$d.Name]              # a hashtable of this dataset's properties
    $mp   = if ($from) { $from['mountpoint'] } else { $null }
```

**PowerShell variable names are case-insensitive, so `$from` is `$From`** — the
parameter. It is declared `[string]`, and assigning to a type-constrained
variable *coerces silently*: the hashtable became the string
`"System.Collections.Hashtable"`. The next line then indexes a **string** with
the word `mountpoint`, and a string's indexer wants an `Int32`.

So the message is about the right value at the wrong place, names no variable,
points at a line that is correct in isolation, and describes a type that appears
nowhere in the function. It also silently corrupted `$From` for everything after
it — the second half of the loop would have cloned from
`rpool/ROOT/System.Collections.Hashtable`.

**Two things to carry out of this:**

1. **Never reuse a parameter's name for a local**, in any case. `$From` /
   `$from` / `$FROM` are one variable, and a typed parameter turns the mistake
   into a coercion rather than an error.
2. **This is why `installer/testing/check-be-logic.py` exists.** The bug is
   three lines of decision logic and it cost a 25-minute install-and-boot cycle
   to reach. Running the real module against a fake `zfs` finds it in three
   seconds — and found a second one in the same run, where
   `(Get-ZfsProperty … -Property mountpoint).Value` trusted that exactly one
   object comes back.

**Related:** #60 (`Write-Verbose` goes to stdout and breaks a JSON contract) —
the same shape of PowerShell behaviour that is correct, documented, and lethal
in a place nobody looks.

### It happened again on 2026-08-26, and the second one was quieter

`Get-OS7PackageDrift` computed a hash into `$installed` while carrying an
`-Installed` parameter typed `[string[]]`. Same collision, opposite direction:
the string was coerced into a **one-element array**, and nothing threw.

What makes this one worth recording separately is that **every downstream
comparison went on being right**. `@('sha256:x') -eq 'sha256:x'` returns the
matching element, which is truthy, so `if ($computed -eq $Recorded)` still took
the Clean branch for a clean machine. The only thing that was wrong was the
value handed back to the caller — an array where a hash belonged — which is
invisible until somebody prints it or compares it with `-is [string]`.

`installer/testing/check-version-rule.py` caught it on its first run, by
comparing the reported hash against one computed independently in Python. Rule 2
above, holding for the second time: the class of bug is found in seconds by a
harness that asks an independent question, and not at all by one that asks the
module whether it agrees with itself.

## 67. `10_linux_zfs` lists ONE boot environment per machine, unless zsys is installed

**Found 2026-08-25** by spike S5, on its third run, after two other bugs had been
fixed out of the way.

`Set-OS7BootEnvironment` clones a boot environment, runs `update-grub`, and looks
for the clone's entry in the generated menu before pointing the machine at it.
`update-grub` said:

```
Found linux image: vmlinuz-7.0.0-30-generic in rpool/ROOT/os7_1.0.0.95_202608252004
Found linux image: vmlinuz-7.0.0-30-generic in rpool/ROOT/os7_1.0.0.95_202608252004@os7_1.0.1.0_202608252207
Found linux image: vmlinuz-7.0.0-30-generic in rpool/ROOT/os7_1.0.1.0_202608252207
```

— it found the clone — and the guard still refused, because **the menu contained
no entry for it.**

In `/etc/grub.d/10_linux_zfs`:

```sh
if [ "${section}" = "history" ]; then
    if [ "${iszsys}" != "yes" ] || [ "${iszsys}" = "yes" -a -z "${have_zsys}" ]; then
        continue
    fi
fi
```

`iszsys` is `zfs get com.ubuntu.zsys:bootfs` on the base dataset. **OS/7 has no
zsys and never will** — it was retired upstream, and the layout in SETUP-PLAN
§4.4 deliberately replaces its property-based scheme with structure. So the whole
`history` section is skipped, and `main` and `advanced` are emitted for exactly
one dataset per machine-id: the one that sorts first by `last_used`. The running
environment is handed `date +%s` by the same generator, so **it always sorts
first, and a second boot environment can never appear in a menu generated from
the first.**

**Everything downstream of that was correct and useless.** The ESP stub names an
environment (#M3), `saved_entry` names an entry, submenu paths are joined with
`>` — all of it works, and none of it can point GRUB at an entry that is not in
the file.

**So OS/7 generates its own entries.** `Set-OS7BootEnvironment` writes
`/etc/os7/grub-boot-environments.cfg` and a two-line `/etc/grub.d/09_os7-boot-
environments` that emits it, then runs `update-grub`. The entries are **built by
substitution into the running environment's own entry** rather than written from
scratch: both environments live in the same two pools, so the `search --fs-uuid`
line, the `insmod`s and the ordering are identical, and only the dataset name and
the kernel filenames differ. A hand-written menuentry would be a guess about a
bootloader; a substitution into a known-good one is not.

**Why this matters beyond activation:** with the stock generator the menu holds
only the active environment, so an environment that fails to boot leaves the
operator with no way to choose the other one from the console. A rollback that
requires a working system is not a rollback. OS/7's fragment lists every complete
environment, every time.

**Two smaller things the same code needed, both PowerShell rather than GRUB:**
`[regex]::Replace` anchors `^`/`$` to the whole string unless `(?m)` is given —
without it the id substitution silently replaced nothing and two entries claimed
the same id — and `$` in a .NET replacement string is a group reference, so a
literal one is `$$`.

**And one that only the SECOND activation could show.** Once an environment OS/7
created is the running one, `10_linux_zfs` has no `gnulinux-<dataset>-…` entry
for it — its only entry is OS/7's own `os7-be-…`. Every lookup over the menu
therefore has to know both shapes, and the one that had not been taught was the
*template* lookup, so a rollback refused with "the running system has no entry of
its own": true of the shape, false of the menu. The lesson is not the line; it is
that **a check which activates once passes while a rollback cannot run at all**,
which is why `installer/testing/check-be-logic.py` now performs both.

## 68. In PowerShell the comma binds tighter than `+`

```powershell
$wanted = @("gnulinux-" + $ds + "-", "os7-be-" + $leaf)
```

is **one** element, not two. The comma builds `("-", "os7-be-")`, adding an array
to a string joins it with `$OFS`, and the result is

```
gnulinux-rpool/ROOT/os7_b- os7-be-os7_b
```

— a single string with a space in the middle of it, which matches nothing and
reports no error. Parenthesise each element:

```powershell
$wanted = @(("gnulinux-" + $ds + "-"), ("os7-be-" + $leaf))
```

Found 2026-08-25 when a menu lookup that had passed its unit test the hour before
started returning nothing. It cost three minutes because
`installer/testing/check-be-logic.py` runs the real module on the host; in a VM
it would have cost a boot cycle. Same family as #65 and #60: PowerShell doing
exactly what it documents, somewhere nobody looks.

## 69. Sealing to PCR 7 from the installer seals against the INSTALLER's PCR 7

**Found 2026-08-25**, on the fourth S5 run, once the two bugs in front of it
(#64, and a busybox `sed` dialect) had been cleared and `cryptsetup` could
finally say what it thought:

```
Begin: Running /scripts/local-top ... OS/7 TPM: the TPM would not unlock os7_root
Please unlock disk os7_root: TPM policy does not match current system state.
Either system has been tempered with or policy out-of-date: Operation not permitted.
```

Everything is in place at that point: the token is enrolled in key slot 1 sealed
to PCR 7, the `libcryptsetup-token-systemd-tpm2.so` handler and the libtss2
libraries are in the initramfs, `/dev/tpmrm0` is there, the handler runs before
`cryptroot`, and it calls the invocation spike S4 proved. **The seal simply does
not match the machine that is trying to open it.**

**PCR 7 is Secure Boot policy, and the two boots do not measure the same one.**
`TpmEnrolStep` runs during the install, from a live session the harness starts
with QEMU's `-kernel`/`-initrd` — no EFI loader takes part. The installed machine
starts from its own ESP through `shim` and GRUB, and shim extends PCR 7 with its
own certificate measurements. Same TPM, same disk, different PCR 7.

**Spike S4 does not have this problem because it enrols from the INSTALLED
machine** — `s4-tpm-enroll.sh` runs on a booted system, so the PCR 7 it seals
against is the PCR 7 that will be presented at the next boot. Nothing in S4 was
wrong; the installer put the same code in a different world.

**So enrolment cannot be an install-time step.** It has to happen in a boot that
measures what the target boots measure, which means **first boot**: a one-shot
service that enrols and disables itself, with the passphrase available to it
exactly once. That is a Phase 4 mechanism — a unit, a state file, an idempotent
path, and a decision about where the passphrase lives for the length of one boot
— and not something to bolt onto the install.

**What the installer should do meanwhile** is say so rather than report a sealed
key that will not open. The step's own log now carries the enrolment and the
initramfs checks; the sentence it still owes the operator is that the seal is
made against the installer's measurements and will be re-made on first boot.

**Related:** #19 and #20 (what the initramfs needs), #64 (the handler's path),
S4 and S6 in `installer/spikes/`.

## 66. The installer's TPM step had diverged from the spike that proved it

**Found 2026-08-25.** `installer/spikes/s4-tpm-enroll.sh` is named in HANDOFF as
"the working version" of TPM2 unlock, and it is. `TpmEnrolStep` in `os7-setup`
was written from the same notes and did something else:

| | spike S4 | the installer step |
|---|---|---|
| unlocks with | `cryptsetup open --token-only` | `systemd-cryptsetup attach` |
| carries into the initramfs | `libcryptsetup-token-systemd-tpm2.so` + four named libtss2 | `systemd-cryptsetup` + a glob of libtss2 |
| checks the ORDER file | yes, reads it back | no |

**The token handler is the part that matters.** `cryptsetup` loads external LUKS2
token handlers from a compiled-in directory, `/usr/lib/<triplet>/cryptsetup`, and
the stock `cryptsetup-initramfs` hook copies none of them — so `--token-only`
inside the initramfs can only fail, and the installer's initramfs did not have it
at all. That is exactly what #19 and #20 are about; the step was written against
the right notes and then took a different route.

**Corrected**: the hook copies the handler and names `libtss2-esys`, `-mu`,
`-rc` and `-tcti-device` (the last is dlopened by `libtss2-tctildr` to reach
`/dev/tpmrm0`); the local-top script uses `cryptsetup open --token-only`; and the
enrolment step asserts the handler, the TCTI backend, the script and the ORDER —
the last by unpacking the initramfs it just built and reading the file, rather
than by trusting a name to sort.

**The rule this is an instance of:** *a spike is evidence, not a template* —
and the corollary that had not been written down until now is that **code which
replaces a spike has to be diffed against it**, not merely inspired by it. The
spike boots; the paraphrase had never been booted, and it did not.
## 70. Git for Windows checks the repo out with CRLF, and the shebang stops naming an interpreter

*Found 2026-08-25, on Windows 11 + WSL2 + Docker Desktop, first attempt at
`make build-amd64` on that host.*

```
$ make build-amd64
[+] Building 132.9s (7/7) FINISHED
 => => naming to docker.io/library/os7-build:amd64
env: $'bash\r': No such file or directory
env: use -[v]S to pass options in shebang lines
mkdir -p /mnt/c/.../out
docker run --rm --platform linux/amd64 --privileged ... /work/build/build.sh amd64
env: $'bash\r': No such file or directory
env: use -[v]S to pass options in shebang lines
make: *** [Makefile:126: build-amd64] Error 127
```

**Git for Windows ships `core.autocrlf = true` in its SYSTEM config**
(`C:/Program Files/Git/etc/gitconfig`) — the default of the "Checkout
Windows-style, commit Unix-style" option in its installer. Every text file is
therefore converted **on checkout**. 166 of this repo's files landed with CRLF.

`#!/usr/bin/env bash\r` does not ask for `bash`. It asks for a program whose
name ends in a carriage return, and `env` says so — but it says so as
`$'bash\r'`, which reads at a glance like it simply could not find bash.

**Nothing in the history is damaged, and that is what makes it invisible.**
`autocrlf=true` converts back to LF on the way *in*, so:

* `git show HEAD:build/build.sh | od -c` → `\n`. Every blob is clean.
* `git grep -I -l $'\r$' HEAD` → nothing. No commit contains a CR byte.
* `git status` → **clean**. The filter is symmetric, so the mangled working
  tree is byte-identical to HEAD *as far as git is concerned*.

There is no diff to find, no commit to blame, and no bad object to fix. The
corruption exists only in the files on disk, which is the only place the
interpreter ever looks.

**Two scripts failed, and only one of them stopped anything.** The first
`env:` line — the one printed *before* `mkdir`, above — is the Makefile's
`SOURCE_FACTS` shell-out to `scripts/os7-source-facts.sh`. It died into a
`$(shell …)` substitution, and **make does not check the exit status of
`$(shell …)`**: `SOURCE_FACTS` simply came out empty and the recipe ran on to
`docker run` regardless. Nothing in the log says a version lookup failed. The
build stopped only because `build.sh` had CRLF *too*.

*What that near-miss is actually worth was measured, not assumed.* With no facts
handed in, `build.sh` falls through to its `elif` and asks git inside the
container — and on this host it gets the right answer:

```
$ docker run --rm --platform linux/amd64 -v "$PWD":/work os7-build:amd64     bash -c 'git -c safe.directory=/work -C /work rev-parse --short=12 HEAD'
11dd6765983b          # identical to the host's answer, and rev-list --count = 95
```

So on a **plain checkout** the empty `SOURCE_FACTS` is survivable: this repo has
a real `.git` directory, the bind mount carries it, and the fallback is correct.
It is in a **git worktree** that the same silence turns into #43 — there `.git`
is a *file* pointing outside the mount, git cannot answer, and `build.sh`
refuses rather than inventing a version. Claude Code sessions run in a worktree
by default. The hole is not the fallback; it is that `$(shell …)` can fail
without a word, so which of those two paths you are on decides the outcome and
the log looks the same either way.

**The fix is `.gitattributes`, not a git config.** A `core.autocrlf=false` fixes
one machine, silently, until the next clone or the next contributor:

```
* text=auto eol=lf
```

`eol=lf` **overrides `core.autocrlf`**, so the repo now defends itself wherever
it is cloned, rather than depending on how each machine's Git was installed.
`powershell/Zfs/tests/fixtures/**` is marked `-text`: those are recorded real
ZFS output, and an end-of-line filter must never edit a measurement (and the
serial harness speaks CR on purpose — #16).

Renormalising an already-clean tree is a re-checkout, not an edit:

```
git rm --cached -r -q .   &&   git reset --hard
```

**Do not use `sed` or `file` to check for this on Windows.** Git Bash's `sed`
reads in text mode and **strips CR silently**: `sed -n '26,30p' Makefile | od -c`
showed clean `\n` for a file that had 162 CRs in it. The diagnostic agreed the
problem was fixed while the problem was still there — the standing rule (*a
diagnostic must not depend on the subsystem it is diagnosing*) applied to the
line endings themselves. `tr -dc '\r' < f | wc -c` and `od -c` are honest;
they read bytes.

**What proves it is fixed** is not that `make` got further. It is:

```
for f in $(git ls-files); do tr -dc '\r' < "$f" | wc -c; done   # every one 0
docker run --rm --platform linux/amd64 -v "$PWD":/work os7-build:amd64 \
  /work/build/build.sh                    # -> "Usage: ... <amd64|arm64|clean>"
```

The second is the real check: no argument, so `build.sh` reaches `usage()` and
stops. Reaching `usage()` means `env` resolved the shebang and bash parsed the
whole file — proven **inside the container that will run it**, and without
starting a build.

## 71. A local package repository is signed with gnupg 1.x code, and only amd64 has one

*Found 2026-08-25 on Windows 11 + WSL2 + Docker Desktop, native x86_64 — the
first amd64 build attempted anywhere since the desktop theme landed.*

Two failures, one after the other, from the same cause. The first:

```
env: 'gpg': No such file or directory
E: GPG exited with error status 127
```

and once gpg existed, the second:

```
gpg: key generation failed: Inappropriate ioctl for device
gpg: WARNING: "--secret-keyring" is an obsolete option - it has no effect
gpg: signing failed: No secret key
```

**What asks for gpg.** `lb_chroot_archives` builds a **local apt repository**
inside the chroot out of whatever is in `config/packages.chroot`, and when
`LB_APT_SECURE` is true it signs it — `Chroot chroot "gpg --batch --gen-key"`,
then `gpg ... -abs -o /root/packages/Release.gpg`.

**Why no arm64 build has ever met it.** `build.sh` stages the desktop theme
`.deb` into `config/packages.chroot` **on amd64 only** — arm64 is server-only
and leaves the directory empty, and an empty `packages.chroot` skips the entire
local-repository block. The one architecture that has ever produced an ISO
cannot reach this code.

**The first half is a missing package.** debootstrap installs `gpgv`, the
verify-only half of GnuPG, and never `gnupg`. Measured from the build log:
`Unpacking gpgv` once, `Unpacking gnupg` zero times. `gnupg` *is* in
`os7-base.list.chroot`, but package lists are installed at `lb_chroot` stage 62
and the signing runs at stage 52. Fixed with `LB_BOOTSTRAP_INCLUDE=gnupg`
(debootstrap `--include=`), which has **no `lb config` flag** — `lb_config`
reads it from the environment.

**The second half cannot be fixed, and that is the finding.** live-build's
signing code predates GnuPG 2:

* it passes `--secret-keyring` / `--keyring`, which **gnupg >= 2.1 ignores**, so
  the key it just made is not the key it then looks for;
* its `--batch --gen-key` parameter file has no `%no-protection`, so gpg 2.x
  tries to prompt for a passphrase, finds no tty, and fails with *Inappropriate
  ioctl for device*;
* `%secring` / `%pubring` in that parameter file are likewise obsolete.

Nothing in live-build's configuration reaches any of it.

**Three dead ends, each measured rather than reasoned about:**

| Way out | Why it is not one |
|---|---|
| `LB_APT_SECURE=false` | Not scoped to the local repo. `lb_bootstrap_debootstrap:112` turns it into `debootstrap --no-check-gpg`, so **the pinned snapshot stops being verified** — the opposite of why it is pinned. |
| A hook that runs earlier | None exists. `lb_chroot` order: `chroot_archives` **52**, `chroot_early_hooks` 57, `chroot_install-packages` 62, `chroot_includes` 77, `chroot_hooks` 78. Even the *early* hooks are five stages too late. |
| Patch `lb_chroot_archives` in the container | Carries an upstream patch that a live-build update can silently invalidate. OS/7's standing answer to "live-build cannot" is `efi-remaster.sh`: do it ourselves. |

**The fix removes the class.** `config/packages.chroot` is now used by neither
architecture, so the local-repository path cannot run at all:

* `build.sh` writes the theme `.deb` into
  `config/includes.chroot/usr/lib/os7/packages` — stage 77 copies it into the
  chroot as an ordinary file;
* new hook `0085-install-desktop-theme.hook.chroot` runs `apt-get install` on
  that path at stage 78. **`apt-get` and not `dpkg -i`**: it resolves the
  theme's Depends against the pinned archive. It then asks `dpkg -s` whether the
  install actually happened, and deletes the `.deb` so a build input does not
  ship inside the squashfs;
* installing and verifying stay in **separate** hooks — 0085 installs, 0090
  verifies — because a program that checks its own work is the failure this
  repo keeps re-learning;
* `build.sh` **refuses to build** if anything is ever staged into
  `packages.chroot` again, naming this note.

**How long it was latent, and why nobody tripped it.** The theme package landed
in `eb5d600`, which is a DESCENDANT of `c395e4c` - the commit carrying
SESSION-AMD64-FIRST-ISO.md. So `OS7-1.0.0.45-amd64.iso` was built when
`packages.chroot` was still empty (1528 packages, no theme), and the very change
that gave amd64 a desktop also gave it a build that could not finish. Between
those two commits no amd64 build ran anywhere: CI was not dispatched again,
Apple Silicon is blocked by #12, and Windows was blocked by #70. The trap was
armed for 50 commits with nothing to spring it.

**What it produced.** `OS7-1.0.0.95-amd64.iso`, 3.26 GB, **1539** packages -
the 1528 of the CI baseline plus the theme and its dependencies. Not the first
amd64 ISO (that is SESSION-AMD64-FIRST-ISO.md, built in GitHub Actions), but the
first built **locally** rather than in CI, the first on a **Windows** host, and
the first that contains the desktop theme at all. `check-image.py amd64` passes
every check against the **shipped** image - the pin holds on all six apt
sources, `os7-setup --self-test` passes chrooted into it, and `xorriso` reports
an El Torito **UEFI** boot image at `/boot/grub/efiboot.img`.

**NOT MEASURED: whether THIS medium boots.** SESSION-AMD64-EFI-REMASTER.md
measured an amd64 medium booting - firmware, GRUB, OS/7's menu - so the remaster
path is proven in general. It was not re-run here: this host has no QEMU and no
OVMF. The El Torito record says a firmware would find something; it does not say
what happens next for this build.

**Two smaller things worth carrying.** `MAKE_EXIT` was captured three times from
`wsl.exe -- bash -lc '… ; rc=$?'` and came back `0`, then empty, for builds that
had failed — the log said `make: *** Error 127` and `out/` was empty. Do not
trust an exit status marshalled back through `wsl.exe`; ask for the artefact.
And Git Bash's `sed` strips CR (#70), so neither is a reliable witness on this
host.

## 72. `systemctl enable gdm3` enables nothing, and the branch that said so had never been parsed

*Found 2026-08-25 while making "install WITH a desktop" mean "boots to one".*

The GUI half of `InstallModeStep` was two lines:

```bash
systemctl set-default graphical.target
systemctl enable gdm3 2>/dev/null || echo "    (no gdm3 to enable)"
```

**The second line cannot do what it looks like it does.** Measured by reading the
units out of the shipped amd64 squashfs:

* `gdm.service`'s `[Install]` section contains **only**
  `Alias=display-manager.service`. There is **no `WantedBy=`**, so enabling it
  adds nothing to any target's `.wants` — there is nothing to add.
* `/etc/systemd/system/display-manager.service` → `/lib/systemd/system/gdm3.service`
  is **already in the image**; the package's postinst wrote it at build time.
* `graphical.target` carries `Wants=display-manager.service`.
* `/usr/lib/systemd/system/default.target` → `graphical.target` is already the
  vendor default.

So the whole chain that makes a desktop appear is complete before the installer
touches anything, `enable` is at best a no-op, and at worst it **fails** on the
alias symlink that is already there — which is exactly what `2>/dev/null ||
echo` was hiding. The note it printed reads like information and is a swallowed
error. Meanwhile the branch checked **nothing**, in a file whose own
`TargetRoot.Chroot` says *"Every chroot script in this codebase ends by checking
its own work."* The headless branch does. This one did not.

**The worse half: no bash had ever parsed it.** `check-image.py` ran its
`--dry-run` with `"mode":"Headless"`, `InstallPlan.Mode` defaults to `Headless`,
and arm64 forces it. The `all N generated chroot scripts are valid bash` check —
the one thing standing between a typo and an install that dies mid-chroot — had
therefore never seen the GUI script at all. An unrun branch is not a working
branch, and this one is the entire difference between the two products amd64
ships.

**What was changed.** The GUI branch now proves its result the way the headless
one does: it reads `systemctl get-default` and resolves
`/etc/systemd/system/display-manager.service`, prints both, and **fails the
install** if the default target is not `graphical.target` or no display manager
resolves. Both are single symlinks that cannot be wrong on a correct image, and
the alternative to failing is handing back a machine that is quietly the wrong
one. `enable` is kept — it would repair an image that ever lost the alias — but
its exit status is explicitly ignored, because the check is what decides.
`check-image.py` now runs a **second** `--dry-run` with `"mode":"Gui"` and holds
that script to the same bar.

**Two things that could have overridden all of it, and do not.** The installed
system's `GRUB_CMDLINE_LINUX` is `boot=zfs` with an empty
`GRUB_CMDLINE_LINUX_DEFAULT` — no `systemd.unit=`, so nothing on the kernel
command line forces a target. And `os7-setup.service` has **no `[Install]`
section** (deliberately, see #33), so its `Conflicts=getty@tty1.service` is never
in a transaction on an installed machine and cannot take anything with it.

**The check was verified against a binary that fails it.** Run against
`OS7-1.0.0.95-amd64.iso`, which was built before this change, `check-image.py`
reports the GUI script as generated and as valid bash, and **FAILS** "the GUI
mode script proves its own result". A check that has never failed is a check
nobody has tested.

**STILL NOT MEASURED: an amd64 install of either kind.** HANDOFF §1 has said so
since the first amd64 ISO and it is still true. What changed here is that the
GUI branch is now generated, parsed and asserted from the shipped binary — not
that any machine has run it.

## 73. `sanoid` reports success it cannot have, and its monitor answers from a five-hour-old cache

**Found 2026-08-26**, by reading `/usr/sbin/sanoid` out of the `sanoid 2.3.0-1`
deb the archive pin resolves to, before writing anything that would depend on it
(docs/BACKUP-PLAN.md §13, M-B4). Not by hitting it — which is the point: this one
was cheap because it was looked for.

**Two separate ways the program says yes.**

*The exit code.* `sanoid --take-snapshots --prune-snapshots` ends in a bare
`exit 0` (`sanoid:144`). A `zfs snapshot` that fails is reported with perl's
`warn` — text on stderr containing the words `CRITICAL ERROR` — and never
touches the status. A destroy that fails is `warn "could not remove $snap"`
(`:412-414`) and the loop continues. So a run in which nothing was snapshotted
and nothing was pruned is indistinguishable, by exit code, from one that worked.

*The monitor.* `sanoid --monitor-snapshots` does not ask ZFS. It answers from
`/var/cache/sanoid/snapshots.txt`, and when **only** monitor flags are given —
no `--cron`, `--force-update`, `--take-snapshots`, `--prune-snapshots` or
`--cache-ttl` — the TTL is deliberately raised from 1200 seconds to **18000**
(`sanoid:69-85`):

```perl
# Allow a much older snapshot cache file than default if _only_ "--monitor-*"
        $cacheTTL = 18000; # 5 hours
```

That is upstream being reasonable about a monitoring plugin's cost. It is also a
diagnostic that can report OK about a state which stopped being true four hours
ago, and CRIT about one that was fixed three hours ago.

**What it means here.** This is the repo's standing rule arriving in a
dependency: *a diagnostic must not depend on the subsystem it is diagnosing*, and
*an exit code is a diagnostic, not evidence.* `Get-OS7BackupStatus` therefore
asks `Get-ZfsSnapshot` for creation times and never runs `--monitor-snapshots`,
and `Start-OS7Backup` counts the snapshots ZFS reports before and after rather
than reading sanoid's status. Same treatment for `syncoid`, whose exit code is
the worst outcome over all datasets and which several post-transfer steps —
sync-snapshot pruning, target-snapshot deletion, hold release — only `warn` about
and cannot reach.

**The one place sanoid's own answer IS used**, and it is used because it is the
only thing that can give it: `sanoid --readonly --take-snapshots` against a
scratch `--configdir` is what validates a rendered `sanoid.conf` before it is
installed. An unrecognised key anywhere in that file is a **fatal die**
(`sanoid:975`), not a warning, and no renderer can know the legal set — OS/7
reads it out of `[template_default]` in the shipped defaults for the same reason.

## 74. `/home/<user>` is not on a USERDATA dataset unless the account is called `os7`

**Found 2026-08-26** while deciding what a backup policy should cover. It is not
a backup bug; the backup feature is just the first thing that had to look.

```
New-OS7Storage ... -UserName 'os7'        # powershell/OS7/OS7.psm1, the DEFAULT
    -> rpool/USERDATA/os7_<suffix>   mountpoint=/home/os7
```

`os7-setup` builds its invocation with `-Root`, `-RootDevice`, `-BootDevice` and
`-BootEnvironment` — **and no `-UserName`** (`StorageSteps.cs`, the
`New-OS7Storage` command string). The account is created afterwards, in a
different step, by `useradd -m` with whatever name the operator typed. On the one
machine this repository has installed and booted that name is **`os7admin`**
(`installer/testing/run-phase3.py`).

So on that machine:

```
/home/os7        a mounted ZFS dataset containing nothing
/home/os7admin   an ordinary directory inside rpool/ROOT/<BE>
```

**Two consequences, and the second is the expensive one.**

`Restore-OS7` rolls the machine back to an earlier boot environment — which now
takes the user's home directory with it. That is precisely what SETUP-PLAN §4.4
puts USERDATA outside ROOT to prevent, defeated by a parameter that is never
passed. And no snapshot policy can cover that home without snapshotting the boot
environment, which is the one thing a snapshot policy must never do.

**Nothing here checks `/home`.** `grep -rIn "/home" installer/testing/*.py`
returns nothing: the install harnesses verify the pools, the datasets, the
bootloader and the account's ability to log in, and none of them looks at where
the account's files landed. That is why an installer that has been through
`run-phase3.py all` still has this.

**The fix is one parameter**, plus a migration for machines already installed —
a dataset created and the existing directory moved into it, which is not a
one-liner and is not safe to write blind. `Get-OS7BackupCoverage` reports the gap
on every machine in the meantime, and docs/BACKUP-PLAN.md B-Q1 holds it open.
Do not close it without running `run-phase3.py all`.

### What was written on 2026-08-26, and what is still owed

**The one parameter is passed.** `StorageSteps.PoolsAndDatasetsStep` now builds
`-UserName '<account>'` into the `New-OS7Storage` command. The name is available
there because the whole plan is validated at `ExecuteScreen.Start` and at
`--unattend`, which are the executor's only two doors, so
`plan.Account.Username` has already been through `AccountPlan.IsValidUsername`
by the time any storage step runs. That is not a violation of #45 — #45 is about
a SCREEN validating what it did not collect; this is the executor, whose
contract is a complete plan.

**And the default is gone.** `New-OS7Storage -UserName` no longer defaults to
`os7`; empty means **no home dataset is created at all**, and the result object
gained `userName` and `userDataset` so the install log records which home was
made. `--storage-only` — the one caller that legitimately has no account name —
therefore produces no `/home/<x>` dataset instead of one named after a default
nobody chose. A dataset for an account nobody has been asked for is what this
whole entry is about.

**The second half was not the parameter, and it is #78.** With the dataset
mounted at `/home/<user>` before the account exists, `useradd -m` takes its
"already exists" path: it warns, **exits 0**, copies no `/etc/skel` and changes
no ownership. The naive one-line fix therefore produces a machine whose home is
correctly placed, `root:root`, and empty — the account cannot write to it. It is
measured, and `AccountStep` now finishes the job and proves it did.

**Three checks now look at `/home`, where none did:**

| | |
|---|---|
| `AccountStep`, in the chroot | st_dev of the home against st_dev of `/`, then owner, mode and what is in it. Fails the install rather than producing the machine this entry describes |
| `run-phase3.py boot`, checks 9 and 10 | the same claim about a machine that has BOOTED, which is the only place `zfs mount -a` and `canmount` have had their say. `findmnt` names the dataset and `stat -c %d` is the second witness |
| `run-s5.py cycle` | a file written into the home **from the clone**, looked for after the rollback. The package must be gone and the file must not: one rollback, two opposite outcomes, which is the whole of §4.4 in one assertion |

**For machines already installed: `Get-OS7Home` and `Move-OS7Home`**
(`powershell/OS7/OS7.Home.ps1`). The design problem that makes the migration
more than a `mv` is that **OpenZFS has defaulted to `overlay=on` since 0.8**, so
`zfs create -o mountpoint=/home/<user>` mounts straight over the live directory
and hides every file in it, silently. So the dataset is created on a staging
path under `/run`, filled, verified against the original, and only then moved
into place — after the original has been renamed aside, never deleted, with the
boot environment snapshotted first. `installer/testing/check-home-logic.py` runs
all of that against a fake `zfs` whose datasets are real tmpfs mounts, in
seconds: 45 checks, green.

**WHAT IS STILL OWED, and it is the whole of the reason this entry is not
closed:** `./installer/testing/run-phase3.py all` has not been run. It is
`qemu-system-aarch64 -machine virt,accel=hvf` and needs the Apple Silicon host;
the work above was done on Windows. The installer is the only code path in this
repository proven to produce a machine that boots, and it has been changed. The
migration has additionally never touched real ZFS — BACKUP-PLAN B-6.

## 75. A package can enable a timer whose services are gated on a file it does not ship

**Found 2026-08-26**, reading the `sanoid` package's own postinst and units.

```
sanoid.service        ConditionFileNotEmpty=/etc/sanoid/sanoid.conf
sanoid-prune.service  ConditionFileNotEmpty=/etc/sanoid/sanoid.conf
sanoid.timer          OnCalendar=*:0/15  Persistent=true   [Install] timers.target
postinst              deb-systemd-helper enable 'sanoid.timer'      (unconditional)
                      deb-systemd-invoke start 'sanoid.service' 'sanoid.timer'
```

and the package's only `/etc` content is a `cron.d` entry that disables itself
under systemd. **There is no `/etc/sanoid/sanoid.conf` and no `/etc/sanoid`.**

So on a freshly installed machine the timer is `enabled` and `active`, fires
every fifteen minutes, and both services skip — successfully, because a failed
condition is not a failure. `systemctl is-enabled sanoid.timer` says `enabled`,
`systemctl is-active sanoid.timer` says `active`, `systemctl is-failed` says
`inactive`, and nothing on the machine has ever been snapshotted.

**Related to #33 and not the same thing.** #33 is `Conflicts=` being resolved
when systemd BUILDS the transaction while `Condition...=` is evaluated when the
job RUNS — an enabled unit with a failing condition has already conflicted its
target away. Here nothing conflicts; what is new is that the *packaging* arms a
schedule whose work is gated on configuration the package leaves to somebody
else. The shared lesson is the one that matters: **`enabled` is a statement about
a symlink, never about work being done.**

OS/7 depends on this behaviour rather than fighting it — writing
`/etc/sanoid/sanoid.conf` is what starts the schedule, and removing it is what
`Disable-OS7Backup` does. Two things follow. Hook 0090 fails the build if a
`sanoid.conf` is ever baked into the **image**, because that would start
snapshotting on the live medium against datasets only an installed machine has.
And `Get-OS7BackupStatus` reports whether ZFS holds a recent snapshot, never
whether a timer is enabled.

## 76. `.GetNewClosure()` captures a value, so `$n++` inside the closure increments a copy

**Found 2026-08-26**, by a self-test failing the first time it was run — which is
the right way round, and is the whole argument for tier 1 existing.

The Zfs self-test installs a scriptblock into the seam so a cmdlet can be run
without ZFS. `.GetNewClosure()` is mandatory there and the module already says
why: without it the block resolves its captured variables when it RUNS, by which
time the defining scope is gone, and under `Set-StrictMode` that is an error
rather than a silent `$null`.

What is easy to miss is the other half. A closure captures **the value**, so a
counter written this way never advances:

```powershell
$n = 0
$script:ZfsCommandOverride = {
    param($cmd, $a)
    $n++                                   # increments a COPY
    [pscustomobject]@{ ExitCode = ($n -eq 1 ? 0 : 1) }
}.GetNewClosure()
```

Every call sees `$n -eq 1`. The test that found it was checking
`Clear-ZpoolLabel`'s verification — which asks `zpool labelclear` a SECOND time,
because that command exits non-zero when there is nothing to clear, so a second
success means the label survived the first. With a frozen counter the fake said
"cleared" twice and the cmdlet correctly threw, which read as a broken cmdlet
rather than as a broken fake.

**Use a reference type instead.** The list the calls are already being recorded
in is one:

```powershell
$calls = [System.Collections.Generic.List[string]]::new()
$script:ZfsCommandOverride = {
    param($cmd, $a)
    $calls.Add("$cmd $($a -join ' ')")
    [pscustomobject]@{ ExitCode = ($calls.Count -eq 1 ? 0 : 1) }
}.GetNewClosure()
```

The object reference is captured; the object it points at is shared. Same family
as #60, #65 and #68 — PowerShell doing exactly what it documents, somewhere
nobody looks.

## 77. Screen 3 arrived on a row where its own `ENTER=Continue` opened a picker, and every harness walked past it with three literal DOWNs

**Found 2026-08-26**, from a report of the first amd64 ISO being driven by hand
in a Hyper-V VM: *"it sticks on the regional settings and I can't proceed."*
Nothing about amd64 or Hyper-V is involved. Screen 3 was a dead end on every
architecture from the day it was written, and three green harnesses said it was
fine.

`RegionalScreen` came up with the selection on **Language**:

```csharp
private Setting _row = Setting.Language;      // screen 3
private Setting _row = Setting.Accept;        // screen 5, the SAME box
```

The screen tells the operator two things, and both were false where the cursor
actually was:

```
 ENTER=Continue   ↑↓=Select   F3=Quit          <- the status bar
     If all the settings are correct, press ENTER.   <- the body, row 13
```

ENTER on the Language row opens the language picker — 490 entries out of
`/usr/share/i18n/SUPPORTED`. ESC closes it and returns to **the same row**, so
ENTER opens it again. And ESC on the summary is `Transition.Back`, which lands
on the licence, where ESC means *I do not agree* and quits Setup. So the two
keys the screen names are a loop and an exit, and the way forward is three DOWNs
that nothing on the screen asks for.

**Why nothing was red.** All three VM harnesses encode the workaround as a
literal:

```python
run-phase1.py   assert_region(..., (6, 6, 74, 7), ...)  # "the Language row is the selection"
run-phase2.py   for _ in range(3): q.send_key("down")
run-phase3.py   for _ in range(3): press("down")
```

`run-phase1.py` did not merely tolerate the wrong row — it **asserted** it, and
`expect_text("Language:", fg=(0,0,0))` asserted its colour too. A harness that
replays a key sequence tests the sequence, not the screen: it cannot notice that
the sequence is one no operator would find. Same family as **#45** (a screen
unreachable for a whole commit while `--unattend`, `--storage-only` and the
walker each missed it for a different reason) and the note in `DiskScreen.Layout`
about a rebuilt list that "looked like a keyboard that was not working rather
than like a bug".

**The fix is the sibling screen.** `LayoutScreen` draws the same box, ends it
with the same `The settings are correct.` row and prints the same sentence
underneath, and it already started on `Accept` — which is also what MS-DOS 6.22
Setup did, and the only arrangement in which `ENTER=Continue` is true. Screen 3
now does the same, and the three harnesses lost their DOWNs.

**And it is checked without a VM.** `--self-test` renders screen 3 and screen 5
into an off-screen frame and asserts that the row carrying
`The settings are correct.` is the one drawn black on grey. Hook 0080 runs
`--self-test` inside the chroot, so the ISO build fails if this regresses.
Verified by putting the bug back: `RegionalScreen` goes red, `LayoutScreen`
stays green, `failures=11 image-files-absent=10` — so the count no longer
matches the "every failure is an image file" note either.

**What is still owed:** no ISO has been rebuilt with this, and nobody has driven
the fixed screen 3 on a machine. The evidence here is the source, the three
harnesses, and `--self-test` on the host.

## 78. `useradd -m` does nothing at all when the home directory already exists

**Measured 2026-08-26**, on Ubuntu 26.04's own `passwd 1:4.17.4-2ubuntu3`, while
fixing #74. Three runs of the identical command, differing only in what was at
`/home/<user>` beforehand:

```
home does not exist          exit 0   home is  fresh:fresh 750   [.bash_logout .bashrc .profile]
home exists as a directory   exit 0   home is  root:root   755   []
home exists as a MOUNT       exit 0   home is  root:root  1777   []
```

and in the second and third cases, on stderr:

```
useradd: warning: the home directory /home/<user> already exists.
useradd: Not copying any file from skel directory into it.
```

**A warning, and exit 0.** That is shadow-utils behaving exactly as documented —
`create_home()` does nothing if the directory is there, and the `copy_tree` of
`/etc/skel` is inside the branch that created it, as is the `chown`. Nothing is
wrong with `useradd`. What is wrong is expecting `-m` to mean "make sure the
home is usable" when it means "make the directory if there is none".

**Why it matters to OS/7 specifically, and why it is the OPPOSITE of a corner
case here.** The fix for #74 is that `New-OS7Storage` creates the USERDATA
dataset for `/home/<user>` in Phase 2 and ZFS mounts it. So on an OS/7 install
the home directory ALWAYS exists before `useradd` runs, and this path is the
only one ever taken. The naive one-parameter fix would therefore have produced:

```
/home/os7admin   rpool/USERDATA/os7admin_<suffix>, correctly placed,
                 owned by root:root, mode 0755, and empty
```

— a home its owner cannot write to and that has no `.profile`, on a machine
where every automated check passes. That is a worse machine than the one #74
describes, arrived at by fixing #74.

**So the step that creates an account owns the home, not `useradd`.**
`AccountStep` copies `/etc/skel` when the directory is empty (and deliberately
not when it is not — `R=Repair` installs beside an existing USERDATA), chowns,
chmods to the `HOME_MODE` it READS out of `/etc/login.defs` — 0750 on this
image, not the 0755 that gets assumed — and then asks the filesystem what it
actually did: owner, mode, and how many entries are in there.

**The check for skel was wrong the first time, and running it is what said so.**
It asserted `.bashrc` unconditionally, which fails the repair case where not
copying skel is the correct behaviour. Both the correct case and the two failure
cases were exercised by extracting the generated script out of `os7-setup
--dry-run`'s log and running it against a real `useradd` in a container — the
same argument as #16 and #64: the shell an installer GENERATES is a program, and
nobody had ever run it.

Same family as #72 and #75, and the family is the largest in this file: **a
command reported success and the thing it was meant to change did not change.**

---

## 79. The setup medium boots a desktop's background workload while it installs, and the kernel writes its complaints across Setup's screen

**Reported from a Hyper-V VM on 2026-08-26**, and it is the first install this
repository has ever heard about on **amd64** — HANDOFF's table says "nothing
past the menu is measured" and this is what was past the menu. A generation 2
VM, 6 GB of RAM, a 64 GB virtual disk, booting `OS7-1.0.0.95-amd64.iso` from
the Install entry. Setup reached **"Creating the ZFS pools and datasets", 25%**,
and then, at 258 seconds of kernel time:

```
Out of memory: Killed process 1099 (networkd-dispat) total-vm:46488kB, anon-rss:4kB, …
Out of memory: Killed process 1283 (unattended-upgr) total-vm:124832kB, anon-rss:4kB, …
```

and at 492 seconds, still on the same step and the same 25%:

```
INFO: task systemd:1 blocked for more than 122 seconds.
INFO: task cron:1180 blocked for more than 122 seconds.
INFO: task DefaultAggregat:2093 blocked for more than 122 seconds.
```

**The two names in the OOM lines are the whole finding.** Nothing in `os7-setup`
starts `networkd-dispatcher` or `unattended-upgrades`. They are the shipped
image's own enabled units, running while Setup installs — and by the time the
kernel was choosing between them, they were among the largest things it was
allowed to kill.

### What the image says, asked rather than assumed

The squashfs was taken off the ISO in a container and read directly — no VM, no
boot, about four minutes:

```bash
bsdtar -xOf out/OS7-1.0.0.95-amd64.iso casper/filesystem.squashfs > fs.squashfs
unsquashfs -d x fs.squashfs /etc/systemd/system /usr/lib/sysctl.d \
                            /etc/modprobe.d /var/lib/dpkg/status
```

Three facts came back, and each is one third of the failure.

**One — the Install entry starts a full Ubuntu desktop's background workload.**
`/etc/systemd/system/multi-user.target.wants/` holds **39** units and
`timers.target.wants/` holds **15**. Among them: `unattended-upgrades.service`,
**six** `snapd` units, `packagekit`, `cups` and `cups-browsed`, `avahi-daemon`,
`sssd`, `openvpn`, `rsyslog`, `sysstat`, `apport`/`whoopsie`,
`ubuntu-advantage` — and `apt-daily.timer` with
`APT::Periodic::Update-Package-Lists "1"` in `/etc/apt/apt.conf.d/10periodic`,
which is an `apt update` downloading into a filesystem that is RAM.

`systemd.unit=multi-user.target` on the Install entry was put there to keep
gdm3 off tty1 (#49). It does that. It does **not** make the medium an
installer: everything above is in multi-user.target, which is exactly where the
command line sends it.

**Two — there is nowhere for any of it to go.** casper's writable root is a
tmpfs on the overlay, so an apt download is resident memory that cannot be
evicted, and a live medium has **no swap at all**.

**Three — the ZFS ARC had no ceiling.** `/etc/modprobe.d` and
`/usr/lib/modprobe.d` in the shipped image contain **no `zfs` options
whatsoever**, so `zfs_arc_max` is the OpenZFS default of half of physical
memory — about 2.9 GB of this machine — and Setup was about to hand ZFS a disk.

### And a fourth thing, which is why any of it was visible

The Install entry carries `quiet loglevel=0`, and the comment beside it in
`build/lib/efi-remaster.sh` said that was the kernel dealt with. **It is not**,
and the image says so in one line:

```
/usr/lib/sysctl.d/55-console-messages.conf:  kernel.printk = 4 4 1 7
```

`systemd-sysctl` applies that during boot, long before Setup paints anything, so
`console_loglevel` is back to 4 by the first frame and everything at KERN_ERR or
above lands on top of the installer. That is why an out-of-memory cascade was
legible only as a photograph of a corrupted screen: the kernel had taken the
screen, and Setup's own log — which would have carried it properly — said
nothing about memory at all, because nothing had ever asked.

This is the same shape as #25 and #62 and #67, for the third and fourth time:
**a kernel command-line parameter is a request, and the image gets the last
word.** Set it, then read back what the running system actually has.

### What was changed

Four things, in three places, and none of them touches the live entries — "try
before you install" (L14) still boots a desktop with its snapd and its cron.

* **`/usr/lib/systemd/system-generators/os7-setup-quiesce`** — a systemd
  generator, so it runs *before* systemd builds its first transaction and the
  units are never queued rather than started and stopped. It masks 62 units
  (symlink to `/dev/null` in the early generator directory) **only** when
  `os7.setup=1` is on the kernel command line. Deliberately not masked:
  `casper-md5check` (it is the check that catches a bad USB stick, and it is
  I/O rather than memory), `cloud-init` (not implicated, and casper's
  relationship with it has not been measured here), `NetworkManager` and
  `wpa_supplicant` (screen 9 needs them), `thermald`, `ufw`, `systemd-oomd`.
* **`InstallerEnvironmentStep`** — the new first step of every install, before
  `HostIdStep`, at the head of `StorageSteps.For` so that `--storage-only` gets
  it too. It writes `min(MemTotal/8, 1 GiB)` (floor 128 MiB) to
  `/sys/module/zfs/parameters/zfs_arc_max` and then **reads the file back**,
  because a `write(2)` that returned is not a ceiling that moved. On the machine
  in this note that is **742.6 MiB instead of ~2.9 GB**. It also logs
  MemTotal/MemAvailable/Shmem/SwapTotal, and warns below 4 GiB.
* **`Terminal.QuietTheKernel`** — Setup takes `console_loglevel` to 1 for as
  long as it owns the console and puts the original back on the way out, on the
  same ProcessExit/SIGINT/SIGTERM/SIGHUP guarantee as raw mode and the palette.
  Nothing is lost: the ring buffer is untouched, and `Diagnostics.KernelLog`
  copies the kernel's error-and-worse lines into Setup's own log when an install
  fails — which is where they were needed in the first place.
* **The executor logs the machine**: `MemTotal/MemAvailable/Shmem/SwapTotal`
  before the first step, every step's real duration and the MemAvailable either
  side of it, and the whole lot again at a failure. "Was it memory?" is now a
  question `/var/log/os7-setup/install.log` answers.

### What was measured about the fix, and what was not

The generator's gate was run rather than read, against four command lines:

| `/proc/cmdline` | units masked |
|---|---|
| `… boot=casper os7.setup=1 quiet` | **62**, each a symlink to `/dev/null` |
| `… boot=casper quiet splash` (the live entry) | **0** |
| `… noos7.setup=10 quiet` (the substring trap) | **0** |
| `os7.setup=1x quiet` | **0** |

The third row is the one that matters: `grep os7.setup=1` matches it, and taking
cron and snapd away from a session nobody asked to install from is a failure
that would never be looked for. Hook `0070-installer-quiesce.hook.chroot` runs
all of it again inside the chroot at build time, plus the mode, the CR check
(#70) and a count of how many of the 62 names resolve to a real unit — a list of
typos passes every other check there is.

**NOT MEASURED: no ISO has been rebuilt and no install has been run.** Every
claim above about the fix is a claim about code and about a squashfs; the claim
about the *failure* is a claim about a computer. What settles it is a fresh
amd64 build and an install in the same VM — and the first thing to look at
afterwards is `/var/log/os7-setup/install.log`, which now carries the numbers
this note had to go and find by hand.

**And one thing this note cannot answer**: whether that VM really had 6 GB.
Hyper-V's Dynamic Memory gives a guest its startup allocation and grows it only
if the guest onlines what the balloon hot-adds, so "configured with 6 GB" and
"MemTotal says 6 GB" are different sentences. `Get-VM` needs Hyper-V
Administrator rights, which the session that found this did not have. It is
why `InstallerEnvironmentStep` logs `MemTotal` rather than trusting anybody's
recollection of a dialog box.

## 80. Microsoft's own tools disagree about which `/etc/os-release` field names the distribution — and OS/7 branded the one Arc reads

**Measured 2026-08-26**, by downloading Microsoft's code rather than by hitting
the failure, because [../CLAUDE.md](../CLAUDE.md) requires anything touching OS
identity to be checked against Microsoft's live material first. It belongs in
this file anyway: the ISO in `out/` ships the broken value today, and the only
reason nobody has hit it is that nothing in this repository has ever enrolled a
device.

D8 decided the product identity may brand `NAME` and `PRETTY_NAME` while `ID`,
`ID_LIKE` and `VERSION_ID` stay Ubuntu's, on the grounds that Intune's "Allowed
distributions" rule matches on `ID`. Hook 0075 asserts exactly that, in both
directions, and passes.

**`ID` is not the field the Azure Arc onboarding script reads.**
`https://aka.ms/azcmagent`, 1014 lines,
`sha256 4a8ecb57997d12ed9f2c5fb9c0370e60c92e8a980e6092b47d562b073643682b`:

```sh
372   distro=$(grep ^NAME /etc/os-release | awk -F"=" '{ print $2 }' | tr -d '"')
597   *buntu*)
749   exit_failure 133 "$0: unsupported Linux distribution: ${distro}:..."
```

`NAME="OS/7"` matches no arm of that `case`, so the script exits 133 having
never looked at `ID=ubuntu`.

And the Intune agent reads a third set. Strings in
`intune-portal_1.2607.4-resolute_amd64.deb` —
`sha256 5978332c7eee9af07be686f34c6616f84677784d73c5d20934534a71a358d38b`, the
version the amd64 image already ships:

| Binary | reads |
|---|---|
| `intune-agent`, `intune-portal` | `/etc/os-release`, `/usr/lib/os-release`, and `ID`, `VERSION`, `VERSION_ID` — plus `PRETTY_NAME`, through a function called `tryReadPrettyName` |
| `intune-daemon`, `pam_intune.so` | none of it |

Three consumers, three different field sets, and **the field D8 chose to protect
is not the one either script keys on first**. There is no hardcoded distribution
allowlist anywhere in the agent — the only `ubuntu` literals in 11 MB of binary
are `/run/mnt/ubuntu-seed` and `/run/mnt/ubuntu-boot`, inside the *encryption*
check. It reports `OSDistribution` and `OSVersion` to the service and the
service decides, so the value that actually matters is one the machine cannot
observe.

**The reusable part is the general shape:** `/etc/os-release` looks like a schema
and behaves like a folk convention. `os-release(5)` says what each field *means*;
it does not say which one a given program will use, and three programs from one
vendor picked three answers. A design that protects "the field Intune matches
on" is protecting a guess.

So the fix is not to protect a different field. It is to stop the product
identity depending on any single one — [IDENTITY-PLAN.md](IDENTITY-PLAN.md) I1:
every user-facing surface reads `/usr/lib/os7/release.json`, which no Microsoft
component reads, and `os-release` carries only what has to be there.

Two things that keep this from being bigger than it is, and both have to be
said, because either one alone misleads:

* **OS/7 does not run that script.** Hook 0040 caches the `azcmagent` `.deb` and
  Phase 3 installs it. What breaks is the path Microsoft's own documentation
  tells an administrator to take.
* **The script rejects 26.04 anyway**, at `-eq 24`, for reasons that have
  nothing to do with branding. A green Arc install today would therefore prove
  nothing, and a green one after Microsoft adds 26.04 would expose this
  immediately. Do not read the first as evidence about the second.

Same family as #38: a check produced a confident answer to a question it was not
actually asking.

---

## 81. Handing a shell program to `sh` from Windows Python: three ways, three wrong error messages

**Measured 2026-08-26**, writing the shell arm of
`installer/testing/check-version-rule.py` — a harness that sources
`build/lib/version-rule.sh` and asks it to render eight version strings. The
library was correct the whole time. Getting it *into* a shell took three
attempts, and **not one of the three errors named the actual problem**:

| How | What it said | What it was |
|---|---|---|
| `sh -c <program> sh <lib> <args…>` | `os7_short: command not found` | Python quotes the program for the Windows command line and the MSYS shell re-parses it with different backslash rules. The `\t` in `printf`'s format shifted the quoting far enough that **`$1` arrived empty**, so `. "$1"` sourced nothing. Reads like a broken library; was a broken argument. |
| a temp script file | `…/drive-version-rule.sh: No such file or directory` | `tempfile.mkdtemp()` returned `C:/Users/BASTIA~1/…` and the shell cannot open an **8.3 short name**. |
| `sh -s` with the path as `$1` | `…/version-rule.sh: No such file or directory` about a file `ls` finds | depends on **which** shell got picked. `/usr/bin/sh.exe` opens `C:/…` happily; the `bin\bash.exe` wrapper that a PowerShell `PATH` finds instead does not — and `shutil.which("sh")` returns different answers depending on whether Python was started from Git Bash or from PowerShell. |

And a fourth, hit on the way: `subprocess.run(input=…, text=True)` wraps the
pipe in a `TextIOWrapper` with `newline=None`, which **translates `\n` to
`os.linesep` on write**. On Windows the shell therefore received the program
with CRLF, `. "$1"` became `. "$1"\r`, and the path it could not open was the
right path with a carriage return glued to the end. Same family as **#70**,
where a CRLF checkout stopped a shebang from naming an interpreter: the
carriage return is invisible in every error message it causes.

**What works:** put both the library and the driver on **stdin** (`sh -s`),
encode the bytes yourself, and let nothing but plain arguments cross the
boundary — no program text, no paths.

```python
p = subprocess.run([sh, "-s", *args], input=program.encode("utf-8"),
                   capture_output=True)          # bytes, NOT text=True
```

**The general rule, and it is not a Windows rule:** *the Windows/POSIX boundary
reports every one of its own failures as a failure of the thing on the other
side.* A harness that cannot run where the code is edited eventually reports NOT
CHECKED forever, so it is worth crossing properly — but budget for the fact that
the first three error messages will send you after the wrong file.

## 82. The OS7 module's IMPORT crossed the line #38 draws for hooks, and no ISO could be built for a day

**Found on 2026-08-26** by the first ISO build since the backup feature landed.
Hook 0060 failed:

```
OS/7 hook 0060:   OS7: FAILED: The term 'Join-Path' is not recognized as a name
of a cmdlet, function, script file, or executable program.
```

Every build after `3a25763` (2026-08-26 00:17) would have failed the same way.
Nobody saw it because **nobody built one in between** — the last amd64 ISO is
`11dd6765`, 2026-08-25 19:35, and the Mac that builds arm64 was not in the room.

#38's rule is written about hooks:

> A build-time hook may `Import-Module` by path and inspect what it exports. It
> must not CALL anything that needs a bundled cmdlet.

Hook 0060 has always obeyed it and its comments say so: `Get-Command`, which is
compiled into the engine, and `[Console]::WriteLine`, which is .NET. It touches
nothing that has to be autoloaded by name out of `$PSHOME/Modules` — the lookup
#14 mangles inside `chroot(2)`.

**The module moved the work across the line on the hook's behalf.** The backup
feature added a loop at MODULE SCOPE that dot-sources the five parts:

```powershell
foreach ($part in @('OS7.Backup.ps1', …)) {
	$file = Join-Path $PSScriptRoot $part          # ← runs during Import-Module
	if (-not (Test-Path -LiteralPath $file)) { … }
	. $file
}
```

`Join-Path` and `Test-Path` are both `Microsoft.PowerShell.Management`, both
autoloaded by name. So `Import-Module` itself became the forbidden call, and it
did so **without anybody editing a hook**. The note considers a hook calling a
function; it did not consider the module doing the calling before the hook has
run a statement of its own.

The fix is that a module staged into an image must have an import path that
needs nothing looked up by name:

```powershell
$file = [System.IO.Path]::Combine($PSScriptRoot, $part)
if (-not [System.IO.File]::Exists($file)) { … }
```

`[System.IO.Path]` and `[System.IO.File]` are .NET types. They are always
present and are never resolved through `PSModulePath`.

Every other statement at module scope in the six files was audited at the same
time: they are string and array assignments, plus `Set-StrictMode`, which is
`Microsoft.PowerShell.Core` and compiled in. `Test-OS7Backup` is 63 passed,
0 failed with the change, and the ISO that follows this note builds.

**The general shape, and it is the one worth carrying:** #38's rule bounds what
a HOOK may do, and a hook's `Import-Module` is only as safe as the module's own
top level. A rule about a caller is not a rule about everything the caller
reaches. When the rule is "do not need an autoloaded cmdlet", the import path of
every module in the image is inside the rule.

## 83. `ldconfig -p | grep -q` under `pipefail` is a race, and it failed a build over a library that was there

**Measured on 2026-08-26.** Hook 0080 stopped an amd64 build with

```
OS/7 hook 0080: no libicu in the image - os7-setup cannot start.
```

and the same build's log says, four hundred lines earlier,
`Setting up libicu78:amd64 (78.2-2ubuntu1)`, and in hook 0020,
`libicu78 is already the newest version`. The library was installed. The check
was wrong. The line was:

```sh
set -euo pipefail
…
if ! ldconfig -p | grep -q 'libicuuc\.so'; then
```

`grep -q` exits at its first match and closes the pipe. Read out of the
**previous shipped image**, `ldconfig -p` there is:

| | |
|---|---|
| entries | 893 |
| bytes | **75 100** |
| pipe buffer | 65 536 |
| `libicuuc` at | entry 437, **34 915 bytes in** |

So `grep` leaves with roughly ten kilobytes still unwritten, `ldconfig` takes
SIGPIPE for them, and `pipefail` makes the pipeline's status **141**. The `!`
reads 141 as "no libicu". Whether it happens at all depends on scheduling —
which is why the line stood for months and then failed, on an image that had got
*smaller*.

The mechanism was confirmed on its own (`yes | grep -q y` → 141 under
`pipefail`) and the sizes above are why it applies here and to nothing else in
the build: every other `| grep -q` pipes `ldd` on one binary, `head -c 2`,
`systemctl show -p` or `gsettings list-keys`, all far below the buffer.

**Two of this repository's standing rules were broken by one line**, and they
are the two BUILD-NOTES keeps restating:

* *A cache is a diagnostic.* `/etc/ld.so.cache` is a cache; the library file is
  the thing itself.
* *An exit status is a diagnostic.* This one was reporting on a signal, not on
  the question that was asked.

The check now globs the library directories, which cannot be poisoned by
`pipefail` and is what `dlopen` does anyway — those are default search paths. It
was checked both ways in a `resolute` container: MISSING before `libicu78` is
installed, PRESENT after, and 0 under `set -euo pipefail`.

**And the check was never the proof.** Twenty lines below it, hook 0080 runs
`os7-setup --self-test` — a .NET binary built `InvariantGlobalization=false`,
which aborts before `Main` without ICU. The `ldconfig` line exists so that the
failure reads as a missing package instead of as a crashing installer, which is
exactly the job it had stopped doing.

---

## 84. GNOME 50 will not draw 1-bit text, and the setting that asked it to was a theme default

**Measured on 2026-08-26**, from screenshots of a booted amd64 machine plus
renderings taken outside the desktop.

`os7-desktop-theme` shipped, in `/etc/dconf/db/os7.d/00-os7-classic`:

```ini
font-antialiasing='none'
font-hinting='full'
font-name='Tahoma 9'
```

with the stated reason that 1-bit text is what makes a small UI font look like
1999 rather than like a blurry modern one. On screen, body text in
`gnome-initial-setup` came out with whole vertical stems missing — `Upgrade`
read as `Uograde`, `Ubuntu` as `Jountu`, `Free` as `-ree`. Headings, buttons and
the window title were fine.

**The first thing that was measured is where the fault is NOT.** The shipped
`tahoma.ttf` was pulled out of the image and re-rendered outside the desktop
entirely:

| renderer | sizes | modes | result |
|---|---|---|---|
| FreeType via Pillow | 12 px | mono, grayscale | legible, both |
| Pango/Cairo | 12 px | `antialias=NONE` × `hint_metrics` on **and off** | legible, all three |
| Pango/Cairo | 8, 9, 10, 11, 12, 13 px | mono and grayscale | legible at every size |

Twelve renderings, none of which reproduces the damage. So nothing in the font,
in fontconfig, in FreeType or in Pango is broken, and "the Wine Tahoma clone is
badly hinted" — the obvious first answer, and the one this note exists to
close — is wrong.

**What separates the broken text from the intact text is the toolkit.** On the
same screen, at the same size, with the same font:

| surface | toolkit | result |
|---|---|---|
| `gnome-initial-setup` body text | GTK 4 / libadwaita | stems missing |
| `intune-portal` window | GTK 3 | crisp, correct |
| Shell panel labels | Clutter | thin, washed out |

GNOME 50 draws text through a GPU glyph atlas. A grayscale glyph carries partial
coverage, so a stem that lands between two pixels survives as two grey pixels. A
1-bit glyph has no partial coverage to spend: the same stem is either one hard
pixel or nothing, and every stage downstream — the atlas, a fractional glyph
origin, a scaled VM console — is one more chance for it to round to nothing.
GTK 3's cairo path positions glyphs on integer pixels and never gives it that
chance, which is why the one non-GTK-4 window on the screen looked right.

**The rule this breaks.** `font-antialiasing='none'` is not a rendering hint
that GNOME may honour approximately; it is an instruction to throw away the only
information later stages can use to be approximately right. The classic look
does not depend on it: the palette, the bevels, the square corners and the
metrics all survive `grayscale` untouched.

**Fixed** by `font-antialiasing='grayscale'` in the same keyfile, with
`font-hinting='full'` unchanged. Verified by hook 0090 reading the key back out
of the compiled dconf database, and by `check-image.py` reading it out of the
shipped ISO.

**NOT verified on a machine at the time of writing.** The one-line check that
settles it, on the booted VM, is:

```bash
gsettings set org.gnome.desktop.interface font-antialiasing grayscale
```

which takes effect immediately and needs no rebuild.

---

## 85. A theme can be installed, verified, and never loaded — because the session mode ships its own stylesheet

**Measured on 2026-08-26** out of the shipped `OS7-1.0.0.109-amd64.iso`.

Hook 0090 reported the classic desktop verified: `os7-desktop-theme` installed,
`/usr/share/themes/OS7-Classic/gnome-shell/gnome-shell.css` present, all four
GNOME Classic extensions present and declaring the right shell generation,
`/etc/dconf/db/os7` compiled, every key reading back the value it was given.
Every one of those statements was true. The desktop on screen had a **black
Ubuntu panel**, an Ubuntu `ding` desktop-icon layer, and none of the theme's
colours.

The image says why:

```
/usr/share/gnome-shell/modes/ubuntu.json
  "stylesheetName":    "Yaru/gnome-shell.css"
  "themeResourceName": "theme/Yaru/gnome-shell-theme.gresource"
  "enabledExtensions": [ ubuntu-dock, ubuntu-appindicators, ding,
                         tiling-assistant, snapd-prompting,
                         snapd-search-provider, web-search-provider ]

/usr/share/glib-2.0/schemas/10_ubuntu-settings.gschema.override
  [org.gnome.desktop.session]
  session-name = "ubuntu"
```

GDM reads `org.gnome.desktop.session session-name` to choose the session for a
user who has not chosen one. `00-os7-classic` set sixty-odd keys and **did not
set that one**, so every first login landed in the Ubuntu session — and a
session mode's `stylesheetName` is not a default that a user theme can be relied
on to beat. The theme was on disk, selected, and never asked for.

**The shape of the mistake is the interesting part**, and it is one this
repository has hit before in other clothes (#62: the package list did not decide
which kernel was installed). *Every declaration was satisfiable on paper and
satisfied — and the thing they were declared about was decided somewhere else.*
Hook 0090 could check that the theme was installed. It could not check that
anything would load it, because nothing it looked at knew.

**Fixed** by `[org/gnome/desktop/session] session-name='gnome-classic'` in the
same keyfile. `modes/classic.json` sets no stylesheet and no theme resource,
forces the light colour scheme, and enables exactly the four extensions the file
already asked for.

**And a second check was added, because the first one is not enough.** A session
name that names nothing is the silent half of the same bug: dconf stores any
string, GDM falls back without a word. Hook 0090 now also asserts that
`/usr/share/wayland-sessions/gnome-classic.desktop` and
`/usr/share/gnome-shell/modes/classic.json` exist, and `check-image.py` asserts
both against the shipped ISO.

**What is deliberately NOT fixed.** `ubuntu-session`, `ubuntu-settings` and
`gnome-shell-ubuntu-extensions` stay on the image. `gdm3` **Depends** on
`ubuntu-session`, so the Ubuntu session and its Yaru stylesheet cannot be
removed while GDM is the greeter. They are inert once the default names a
different session, and inert-and-present is a state a support case can inspect;
a curated desktop package set with something missing is not.

---

## 86. `/etc/profile.d` is read by login shells, and a terminal window is not one

**Measured on 2026-08-26** out of the shipped `OS7-1.0.0.109-amd64.iso`.

OS/7 hands interactive human sessions to PowerShell from
`/etc/profile.d/95-os7-powershell.sh`, written by hook 0050. That is a
deliberate design and it is a good one: `bash` stays the login shell in
`/etc/passwd`, so cron, systemd units, dpkg maintainer scripts and Intune's
bash-based compliance scripts all keep working, and only real interactive
humans get `exec /usr/bin/pwsh`. On the console and over ssh it works — the
repository has watched it work.

On the desktop it never ran. Three facts, each ordinary:

| | |
|---|---|
| `/etc/profile.d/*.sh` is sourced by | `/etc/profile`, which **only a login shell reads** |
| a terminal emulator starts bash as | an interactive **non-login** shell |
| a non-login interactive bash reads | `/etc/bash.bashrc` |

and the fourth, which is the one that closes it: **`/etc/bash.bashrc` on this
image sources nothing at all.** 79 lines, no `.d` loop, no `source`, no `.` —
Debian ships no drop-in directory for it. So the hand-off had no path into a
GUI terminal, and nothing anywhere reported a problem, because from every
component's point of view nothing had gone wrong.

**And there were two terminals.** OS/7's amd64 package list names
`gnome-terminal`; `ubuntu-desktop-minimal` **Recommends** `ptyxis`, which
Ubuntu 26.04 ships as its terminal. Both register `x-terminal-emulator` at
**priority 40**, so the winner was decided by sort order rather than by anyone,
and on the shipped image it was:

```
/etc/alternatives/x-terminal-emulator -> /usr/bin/ptyxis
```

while OS/7's `favorite-apps` named `org.gnome.Terminal.desktop`. Three places
naming a terminal and two answers between them.

### The fix, and why it is one boolean

```ini
[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]
login-shell=true
```

`login-shell=true` makes the terminal start bash the way a console login does,
so the **same** drop-in runs, with the same five guards and the same
`OS7_NO_PWSH` opt-out. The obvious alternative — `use-custom-command=true`,
`custom-command=/usr/bin/pwsh` — was rejected: it skips `/etc/profile`
altogether, so `PATH`, the locale and the .NET environment would all be missing
inside the window, and the opt-out would not exist.

`ptyxis` is purged and pinned, and `x-terminal-emulator` is `--set` to
`gnome-terminal.wrapper` — which is not belt-and-braces for the purge: `--set`
moves the link to **manual** mode, so a future package registering at priority
41 cannot quietly take the terminal back.

**The UUID is read, not copied.** `b1dcc9dd-5262-4d8d-a863-c897e6d979b9` is
gnome-terminal's built-in default profile, and the image was asked:

```
gsettings get org.gnome.Terminal.ProfilesList default
  -> 'b1dcc9dd-5262-4d8d-a863-c897e6d979b9'
```

Hook 0090 asks the same question at build time, because if a future
gnome-terminal changes it, `login-shell=true` lands in a profile nobody opens —
stored, readable, and inert.

### Two checks that had to be repaired to make this checkable

**A relocatable schema is not a path with dots in it.** Hook 0090 verifies every
key in the dconf keyfile against `gsettings`, by turning the group into a schema
name with `s|/|.|g`. For a per-profile terminal setting that produces
`org.gnome.terminal.legacy.profiles:.:<uuid>`, which is not a schema — the check
would have reported "no such schema" about a group that is perfectly correct.
A check that fails on right answers gets deleted, and then it stops catching the
wrong ones. It now carries a small explicit table mapping a group prefix to the
schema it instantiates, and asks `gsettings list-keys SCHEMA:PATH`.

**And then it failed on a right answer anyway**, one build later, for a second
reason inside the same repair — worth recording because the two look identical
from the log. The new branch confirmed the schema existed by looking for it in
`gsettings list-schemas`, and it is not there:

```
gsettings list-schemas             | grep -cx org.gnome.Terminal.Legacy.Profile  -> 0
gsettings list-relocatable-schemas | grep -cx org.gnome.Terminal.Legacy.Profile  -> 1
```

The two lists are **disjoint**: `list-schemas` reports only schemas with a fixed
path. Build `1.0.0.114` died on `no such relocatable schema:
org.gnome.Terminal.Legacy.Profile` about a schema that was installed, listed and
answering `list-keys` correctly in the same hook eight lines further down.
Measured against the shipped image before the next build rather than after it.

**The hand-off itself had never been proven anywhere.** Hook 0050 wrote a file
and stopped; the evidence that it worked was a human looking at a console once.
It now runs the mechanism:

```sh
printf '$PSVersionTable.PSVersion.ToString()\nexit\n' | bash --login -i
```

If the hand-off fires, what reads those lines is PowerShell and it answers with
its own version, which must equal `OS7_PWSH_VERSION` from the release pin. If it
does not, bash reads them and fails. The opt-out is checked the same way:
`OS7_NO_PWSH=1` must still answer with `$BASH_VERSION`.

This runs under `chroot(2)`, where PowerShell's module **discovery** is broken
(hook 0020 documents that at length). `$PSVersionTable` is an automatic variable
compiled into the binary rather than a cmdlet from the module tree, which is why
it is the expression used here — confirmed against the shipped image before the
check was written, not after it failed.

### The surface this does not reach

VS Code's integrated terminal runs `$SHELL` — `/bin/bash` from `/etc/passwd` —
as a non-login shell, and VS Code has no system-wide settings file. Making
*that* PowerShell means either `terminal.integrated.defaultProfile.linux` in a
per-user `settings.json`, which never reaches the home directories `authd`
creates for Entra ID accounts, or overwriting `base-files`' `/etc/bash.bashrc`
conffile, which would then fight every `base-files` upgrade. Neither was done.
It is named here so that it is a known gap rather than a surprise.

---

## 87. `whoopsie-preferences` is a hard dependency of GNOME Settings, and purging it took the whole desktop

**Measured on 2026-08-26**, by a hook that failed a build on purpose.

Hook 0035 removes the Ubuntu onboarding, telemetry and crash reporting from the
amd64 desktop. Its header records a measurement for every name in its list:
each is a **Recommends** of `ubuntu-desktop-minimal` and nothing Depends on it.
That measurement was correct for every name in it. The build still ended with:

```
OS/7 hook 0035: FAIL: ubuntu-desktop-minimal was removed as collateral
OS/7 hook 0035: FAIL: gnome-shell was removed as collateral
OS/7 hook 0035: FAIL: gdm3 was removed as collateral
```

because the list contained one name that had **not** been measured:
`whoopsie-preferences`, added beside `whoopsie` because it is obviously the same
feature. It is not the same package.

```
gnome-control-center     Depends: whoopsie-preferences
gnome-shell              Depends: gnome-control-center
ubuntu-desktop-minimal   Depends: gnome-control-center
gdm3                     Depends: ubuntu-session -> gnome-shell
```

Simulated afterwards, one name at a time, against the shipped image:

| purged alone | packages removed |
|---|---|
| `gnome-initial-setup` | 1 |
| `whoopsie` | 1 |
| `apport` | 3 |
| `ubuntu-docs` | 2 |
| **`whoopsie-preferences`** | **18, including gnome-shell, gdm3 and gnome-control-center** |

`whoopsie-preferences` is the D-Bus service that stores the "send error reports"
preference, which the Settings Privacy panel talks to. With `whoopsie` itself
purged there is nothing for it to enable, so it stays, inert, and the desktop
stands up.

### The mistake is not the package, it is where the list stopped

Reverse dependencies were measured for the packages that were in the list at the
time. Then one more was added from the same family, and the measurement was not
re-run. Everything the header said stayed true, and the header stopped
describing the code.

### And the check that caught it was the weaker of the two possible checks

The hook had a survivor list — `ubuntu-desktop-minimal`, `gnome-shell`, `gdm3`,
`nautilus`, … — checked **after** the purge. It worked here only because
somebody had thought to name gnome-shell. A cascade into something nobody
listed would have shipped.

So the hook now asks apt what it would do **before it does it**:

```sh
SIM="$(apt-get -s purge "${PRESENT[@]}")"
# the set apt would remove must be EXACTLY the set asked for
# and apt must need to install NOTHING
```

Both halves matter. The second is not redundant: the failing transaction wanted
to **install** `notification-daemon` and `policykit-1-gnome`, because
`gnome-shell` *Provides* those and was about to be taken away. An `Inst` line in
a purge simulation is a cascade wearing a different hat, and it is visible
before anything is removed.

The corrected list was then simulated in full: exactly the thirteen named
packages removed, nothing installed, `ubuntu-desktop-minimal`, `gnome-shell`,
`gdm3`, `gnome-control-center`, `ubuntu-session`, `gnome-classic` and
`gnome-terminal` all kept.

### What went right

The build **stopped**. `E: config/hooks/0035-debrand-desktop.hook.chroot failed
(exit non-zero)`, no later hook ran, and no ISO was written — the previous
image in `out/` was untouched. A hook that checks its own work and exits
non-zero is the difference between a bad build and a bad ISO that boots to no
desktop, and #13 is the reminder that live-build will happily do the second.

## 88. `apt-ftparchive`'s `ValidUntil` is accepted, ignored, and silent — the repository then never expires

**Measured on 2026-08-26**, on `apt-ftparchive` from resolute
(`apt-utils 3.1.7`), while building OS/7's own package repository (C7).

`Release` files carry `Valid-Until`, and apt enforces it on the client. That
field is not decoration: CURATION-AND-DELIVERY-PLAN §6.3 names the attack it
exists for.

> A signed package set with an unsigned index of *which* set is current lets an
> attacker serve an older, still-validly-signed release.

Authenticity and freshness are different properties, and `Valid-Until` is the
one that covers freshness. So `build-os7-repo.sh` asked for it the obvious way:

```
apt-ftparchive -o APT::FTPArchive::Release::ValidUntil="Fri, 25 Sep 2026 …" \
               release dists/os7-1.0
```

The result, with an empty `Packages` beside it so nothing else could interfere:

| option passed | `Valid-Until` in the output |
|---|---|
| `APT::FTPArchive::Release::ValidUntil=<RFC 1123 date>` | **absent** |
| `APT::FTPArchive::Release::Valid-Until=<RFC 1123 date>` | **absent** |
| `APT::FTPArchive::Release::ValidTime=2592000` | `Valid-Until: Fri, 25 Sep 2026 19:00:21 +0000` |

Exit code 0 in all three. No warning, on stdout or stderr. An unknown key under
`APT::FTPArchive::Release::` is simply a configuration item nobody reads, and
apt's configuration space has no schema to be wrong against.

**The failure is invisible from both ends.** The build succeeds. The repository
signs and verifies. `apt update` against it succeeds, because a Release with no
`Valid-Until` is perfectly valid — it just never goes stale. Nothing anywhere
reports a problem, and the property the field was added for is simply absent.

Correct: **`ValidTime`, in seconds.**

```
VALID_SECONDS=$(( OS7_REPO_VALID_DAYS * 86400 ))
apt-ftparchive -o "APT::FTPArchive::Release::ValidTime=${VALID_SECONDS}" …
```

### What caught it

Not the option, and not a document — the readback:

```bash
grep -q '^Valid-Until:' "${DISTS}/Release" || exit 1
```

It was written because this repository's rule is that a program which writes a
file re-reads it, and it earned its place on the first run. The same shape as
#25, #36, #62 and #72: a setting was accepted by the thing that was supposed to
act on it, and the thing did not act on it. **A configuration key is not an
interface. Read back what it was supposed to change.**

## 89. `Sort-Object Name -Descending` picked the OLDER kernel, and only an update could reveal it

**Measured on 2026-08-27**, while writing `Update-OS7`.

`Get-OS7BootEnvironmentKernel` chose which kernel a boot environment's menu
entry would name:

```powershell
$k = Get-ChildItem -Path $dir -Filter 'vmlinuz-*' |
     Sort-Object Name -Descending | Select-Object -First 1
```

That is a **string** sort. Asked directly:

```
'vmlinuz-7.0.0-9-generic','vmlinuz-7.0.0-31-generic' | Sort-Object -Descending
  -> vmlinuz-7.0.0-9-generic
```

because `'9'` is greater than `'3'` at the fourth character of the ABI number.
The menu would have named `7.0.0-9` while `/boot` held `7.0.0-31`.

### Why it had never mattered, and what changes that

Every boot environment this repository has ever produced held **exactly one**
kernel. An installer unpacks one; nothing afterwards added a second. With one
candidate the sort cannot be wrong.

**An update is precisely the operation that leaves two.** `apt full-upgrade`
inside a cloned environment installs the new kernel and leaves the old one until
an autoremove takes it — so the first release ever applied to a machine would
have produced an environment whose menu entry named the kernel it was replacing.

The symptom would have been a machine booting the **older kernel against the
newer root**: §4.3's half-activated pair, reached by a different road. Nothing
would have reported it. `update-grub` is not involved — OS/7 writes its own menu
entries (#67) — and the entry it wrote would have been internally consistent and
pointing at the wrong file.

### The fix, and the shape to remember

Sort on the numbers, in order, with the flavour as the tie-break:

```powershell
$n = @([regex]::Matches($release, '\d+') | ForEach-Object { [int]$_.Value })
```

`Get-OS7NewestKernel` in `OS7.Update.ps1` does the same thing for the same
reason, and `Test-OS7Update` checks both against a `/boot` holding `7.0.0-9`,
`7.0.0-30` and `7.0.0-31`.

**The general shape: a sort that has only ever seen one element has not been
tested.** The same applies to the migration ordering in step 6′, which is why
that is a numeric prefix and not a lexical one.

---

## 90. A freshness check that cannot read the date is a freshness check that is not running

**Measured on 2026-08-27** by `installer/testing/check-update-logic.py`, on its
first run.

`Get-OS7ReleaseIndex` refuses a release index whose `valid_until` has passed —
CURATION-AND-DELIVERY-PLAN §6.3's defence against a withdrawn release being
served forever, because *"authenticity and freshness are different properties"*.

It parsed the field with

```powershell
[datetime]::TryParse($validUntil, [cultureinfo]::InvariantCulture, …, [ref]$when)
```

and, when that returned false, **warned and carried on**.

Three spellings of the same instant are in circulation in this repository:

| written by | spelling | `TryParse` |
|---|---|---|
| `apt-ftparchive` into the `Release` file | `Fri, 25 Sep 2026 19:00:55 +0000` | **yes** |
| `.ToString('r')` in the self-test | `Fri, 25 Sep 2026 19:00:55 GMT` | **yes** |
| `date -u +'%a, %d %b %Y %H:%M:%S UTC'` | `Fri, 25 Sep 2026 19:00:55 UTC` | **no** |

RFC 1123 spells the zone `GMT`, and that is what .NET accepts. `UTC` is not a
zone designator it knows. So an index carrying the third spelling — the one
`build-os7-repo.sh` composed before it started reading the `Release` file back —
parsed as nothing, produced a warning, and was **accepted while expired**.

### Two fixes, and the second is the one that matters

`" UTC"` is normalised to `" GMT"` before parsing. That is the small half.

The large half is that the `else` branch now **throws**. A check that cannot run
must never read as a check that passed, which is the same rule that keeps
`Get-OS7Version`'s `Drift` empty rather than `$false` until it is asked for
(IDENTITY-PLAN I7), and the same rule as #72 and #85. An index with no
`valid_until` at all is refused for the same reason.

**The warning was written by someone who knew the parse could fail** — that is
what the branch was for — and who then made not-parsing the harmless case. It is
the harmful one: it is the only case in which the field is doing nothing.

---

## 91. `@('a', $b, $c + $d)` is FOUR elements, and it reads as three

**Measured on 2026-08-27**, five times in one file, the first three by a
`mount` that refused its own arguments.

```powershell
Invoke-OS7Native -Command 'mount' -Arguments @('--bind', $mp, $Root + $mp)
```

produces

```
mount --bind /srv /run/os7-update /srv
```

Four arguments, not three. The array literal binds first and the `+` then
**appends to it**: the expression is `('--bind', $mp, $Root) + $mp`. PowerShell's
own parser says so exactly —

```
$ast.FindAll({ $args[0] -is [BinaryExpressionAst] }, $true)
op=Plus  Left=ArrayLiteralAst ['--bind', $mp, $Root]  Right=$mp
```

— and parenthesising the concatenation gives the three elements that were meant.

### Why this one got through five times

It reads correctly. `$Root + $mp` beside two other arguments looks like a path
being built, and in every other position in the language it would be. Nothing
warns: the array is valid, the call is valid, and the command it produces is a
command.

**Three of the five failed loudly and two would not have.** `mount --bind /srv
/run/os7-update /srv` is rejected by mount. But

```powershell
Invoke-OS7InRoot -Root $Root -Command @('sh', '-c', "…" + "…" + "…")
```

hands `sh -c` the first fragment and the rest as `$0 $1 $2` — a valid
invocation, silently running a third of the intended script.

### The mechanism

`installer/testing/check-ps-traps.py` keys on that AST signature, which is
unambiguous: a `BinaryExpressionAst` with operator `Plus` whose left side is an
`ArrayLiteralAst`. A deliberate append is written `$list + $x`, with the list in
a variable — a `VariableExpressionAst`, not a literal — so the rule cannot fire
on correct code. It found the fifth instance thirty seconds after it was
written, in code that had just been reviewed by its author.

The same file carries #65's rule, for the same reason: **both are defects that
read correctly, parse correctly, and mean something else.** A note is not a
defence against that; a parser is.

---

## 92. A one-element result is not a list, and `[0]` on it indexes into a STRING

**Measured on 2026-08-27**, twice in one file, while writing
`Get-NetplanConfiguration`.

```powershell
function Get-NetplanValue { … ; return @($r.StdOut -split "`n" | … ) }

$renderer = ConvertFrom-NetplanScalar (Get-NetplanValue -Key 'network.renderer')[0]
```

`netplan get network.renderer` answers one line, `networkd`. The `@(…)` inside
the function is real and does nothing that survives: **PowerShell unrolls a
single-element array on return**, so the caller gets a `[string]`, and `[0]` on
a string is its first **character**.

```
Renderer = [n]
```

The second instance was worse, because it produced a plausible wrong answer
instead of an obviously broken one. `netplan get …dhcp4` answers `false`, `[0]`
made that `f`, and

```powershell
Dhcp4 = [bool]'f'      # $true
```

A statically configured machine reported DHCP. Nothing threw, nothing logged,
and the value is of the right type.

The third instance had no `[0]` at all: a helper returning `@()` for "no
addresses" returns **`$null`**, and `$null.Count` under `Set-StrictMode` is a
terminating error — which is how the other two were finally found.

### Two more instances, and the distinction that separates them

**Measured 2026-08-27**, both while fixing the first two.

`@($null)` has **Count 1**. `@(<an empty foreach>)` has **Count 0**. Those look
like the same expression and are not:

```powershell
$a = foreach ($x in @()) { 1 }   # AutomationNull, not $null
$null -eq $a                      # True  — it compares equal
@($a).Count                       # 0     — and collapses to nothing
@($null).Count                    # 1     — a real $null does not
```

So a field that a parser omits — `ip -j` drops `addr_info` for a link with no
address, which is every unplugged port on a machine — comes back as a **real**
`$null`, and `@(…)` around it produces a one-element array whose element is
nothing. `foreach` then runs once with nothing in hand. The `rfkill` version of
the same mistake would have counted a missing `rfkilldevices` key as **one
blocked radio**, which grounds a working adapter.

And a function **cannot hand back an empty array**: `return @()` unwraps to
AutomationNull too, so a helper written to remove this trap reintroduces it at
its own return. `powershell/Net` has `Get-NetJsonArray` for the missing-field
case and **its callers still wrap it in `@(…)`**, because no helper can fix the
return.

That is the rule, and it is the same one as above: **the array is forced at the
boundary, not inside the function.**

### Why there is no rule for this in check-ps-traps.py

Unlike #65 and #91, the AST signature is not unambiguous. Indexing a command
result is only dangerous when the result can be a **string**: PowerShell 3+
gives every scalar an indexer, and `$object[0]` returns the object itself. The
repository has five `(Command …)[0]` sites and **four of them are correct**,
because they index collections of objects — `(Get-ZpoolStatus)[0]` is fine and
always was. A rule keying on the syntax would report four false positives out of
five, and a check that cries wolf is a check people delete.

### The defence, in the absence of a parser

**Force the array at the boundary, not inside the function.** `@(…)` on the
*return* is a decoration; `@(…)` at the *call site* is the guarantee. In
`powershell/Net` every list result is wrapped by its caller and one helper —
`Get-NetplanScalarValue` — owns the "first line of a possibly-scalar answer"
question so nothing else has to index.

### What actually found it

Not review. The self-test's **section guard**: `Test-NetModule` wraps each
section in a `catch` that records a FAILURE, because the first run of that
section threw on `Get-ChildItem`'s `UnixMode` and the module reported
`36 passed, 0 failed, PASS` — a section that contributed no checks at all read
as a clean run. The guard turned "this silently did not happen" into a failing
check, and the two indexing defects surfaced on the next run.

That is the generalisable half of this note: **a count is not a result unless
something guarantees the count was reached.** Same shape as #13's hooks that
never ran and #62's package list that removed nothing.

---

## 93. A container image made from an ISO is not the ISO, and it took a near-miss to notice

**Measured on 2026-08-27**, one command before a false product defect was
written into this file.

`os7img:116` is an OS/7 image as a docker image — a convenience this repository
now leans on heavily, because it answers questions in seconds that would
otherwise need a VM. Asked what its PAM stack looked like, it said:

```
     1	auth sufficient pam_unix.so
     2	#
     3	# /etc/pam.d/common-auth - authentication settings common to all services
```

**Line 1 sits above the file's own header comment**, which `pam-auth-update`
writes first — so something prepended it. Its effect is not subtle: PAM
evaluates top-down, `sufficient` plus success means STOP, and therefore for any
account with a local password neither `pam_authd_exec.so` (Entra) nor
`pam_intune.so` runs at all. On a product whose headline is Entra sign-in and
Intune management, that is a serious defect.

It is not a defect. It is not in the product.

### What caught it

Two files generated by the same tool in the same run, with different
timestamps:

```
2026-08-26 15:04:46   /etc/pam.d/common-auth
2026-08-26 11:23:09   /etc/pam.d/common-account
```

`pam-auth-update` writes both. A three-hour-forty gap between them is not
something one run produces. The rest followed:

```
OS7-1.0.0.116-amd64.iso   written 13:27:46
common-auth               modified 15:04:46
os7img:116                created  15:21:04     (1 layer, no build commands)
```

The modification is **between the ISO and the container image**, so it belongs
to whoever prepared the container. Asked directly — squashfs mounted out of the
ISO — the shipped file starts at its header comment and both PAM files carry
the same `11:23:09` build stamp.

### The rule

**An artefact derived from the product is not the product, and a convenience
that answers in seconds is exactly the one nobody re-checks.** `check-image.py`
already exists for this and mounts the ISO's squashfs; that is the authority.
A container image is a fast approximation of it and may carry anything anybody
did to it afterwards.

Everything else this session measured against `os7img:116` was re-checked
against `OS7-1.0.0.116-amd64.iso` and all of it held: `sshd_config` offering
only `sftp` with zero drop-ins, `chrony` present and `systemd-timesyncd`
absent, `/etc/localtime` a symlink with no `/etc/timezone` and no
`/etc/adjtime`, `/etc/profile.d/95-os7-powershell.sh` present at 924 bytes,
`/etc/netplan` empty, PowerShell 7 present. One measurement in seven was
contaminated, and it was the one that mattered most.

### And one real finding, from the same look

**`/etc/authd/brokers.d` is EMPTY in the shipped ISO.** authd is installed, PAM
is wired to it, and there is no broker for it to talk to — so Entra sign-in
cannot work on an OS/7 image as built today. That is C8a
([CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)) as an open
question already says, but it had been reasoned about rather than measured on
the artefact. It is measured now.

## #97 — gpg cannot put its agent socket on a Windows bind mount, and the failure was invisible

**2026-08-28.** The first ISO build that had to generate the signing key inside
the container died at `make build-amd64` with no line naming gpg at all: the
keygen sat inside `>/dev/null 2>&1`, and `set -e` took the build down on its
exit code alone.

The cause is the same one that moved the harness's QMP endpoint to TCP:
**a unix socket cannot be created on Docker Desktop's Windows file sharing.**
`GNUPGHOME` was a bind mount of `out/os7-gnupg` (it has to be — the ISO and
the repository must share one key, so the key lives outside both containers),
and gpg-agent's first act is to bind `S.gpg-agent` inside it. On a 9p/drvfs
mount, bind(2) is refused and every gpg operation dies before it starts.

GnuPG's own answer is the socket directory under `/run/user/<uid>`, which it
uses automatically **when it exists** — and a build container has no logind to
create it. `build/lib/os7-signing-key.sh` creates it and runs
`gpgconf --create-socketdir` before touching the keyring, and the keygen's
output is no longer discarded, because a silenced failure cost the whole build
to learn one line.

### The rule

A directory that must be SHARED across containers cannot also be where a
program wants a SOCKET. Give the program its socket on a container-local
filesystem and keep only the STATE on the mount — the same split
`vmhost-entry.sh` makes for swtpm.

## #98 — apt satisfies a strict `Depends (= old)` from CANDIDATE versions only

**2026-08-28, measured by check-os7-repo.py.** With three releases of the OS/7
suite in one pool, `apt-get install os7-server=1.0.0.130` fails:

    os7-server:amd64=1.0.0.130 Depends os7-base (= 1.0.0.130)
      but none of the choices are installable:
      - os7-base:amd64=1.0.0.130 is not selected for install

The version is IN the index — `apt-cache policy` lists it — but apt's resolver
only considers each package's **candidate** (the newest, unless pinned) when
satisfying dependencies. An exact-version metapackage whose members' candidates
have moved on is therefore uninstallable by name alone, however complete the
repository.

The fix is a `preferences.d` pin (`Package: os7-* / Pin: version <v> /
Pin-Priority: 1001`) for the duration of the operation — which is exactly the
pin `Update-OS7` already writes for its own run, found independently by its
review (SESSION-UPDATE-TRAIN §2a, "full-upgrade undid the pinned version").
One apt fact, paid for twice, now written down once.

## #99 — an installed amd64 machine says NOTHING on the serial line

**2026-08-28.** The first amd64 `run-s5.py boot` hung for fifteen minutes on a
machine that was booting perfectly: OVMF found shim, GRUB drew its menu into
the serial console (via the firmware's ConOut), and then — silence. The kernel
had put its console on tty0, and the passphrase prompt, the boot messages and
the login all went to a display nothing was attached to.

On arm64 nobody ever had to think about this: QEMU's `virt` machine hands the
kernel a device tree whose `chosen` node names ttyAMA0, and Linux takes it as
the console. **x86 has no such mechanism** — no `console=` on the command line
means tty0, and the installed machine's command line is written by os7-setup,
which (correctly) says nothing about serial consoles.

The harness now gives the machine `console=ttyS0,115200` through its own
`update-grub` after the install (`run-s5.py serialize`), inside
`unshare --mount --propagation private` — the first attempt did the mounts in
the shared namespace and re-measured #18: `zpool export` said "pool is busy"
with nothing visibly mounted. Whether the PRODUCT should ship a serial console
on the server image is a real question (§6 wants every cmdlet usable over
serial) and is left open rather than decided by a test harness.

## #100 — the install-time TPM seal does not open through shim: #69, now measured

**2026-08-28, the first amd64 boot of a machine this repository installed.**
The enrolment was perfect — token in slot 1, sealed to PCR 7, handler and
libtss2 in the initramfs, ordered before cryptroot — and the machine asked for
the passphrase anyway. `TpmEnrolStep` seals from the LIVE session, which QEMU
boots via `-kernel`; the installed machine boots through `shimx64.efi`, which
extends PCR 7. Same TPM, different measurement: exactly the road #69 named
when it moved enrolment "to first boot", predicted and never before seen on a
machine.

arm64 never hit it because its live and installed boot paths measure alike on
QEMU — which is why `run-s5.py boot` passed there with install-time sealing
and would have kept passing forever.

Two consequences, both built the same day: the harness performs S6's recovery
(one `systemd-cryptenroll` on the booted machine; the NEXT boot must unlock
with nothing typed, and did), and the UL1 firstboot migration
(`50-tpm2-reseal`, shipped by os7-release, run by `os7-migrations-firstboot`)
is the product's own version of the same move — it asks whether the seal opens
against THIS boot and re-enrols when it does not. Unattended re-enrolment
still needs a secret nobody escrows: U8 is open and the migration says so out
loud instead of failing the boot.

## #101 — a worktree made by Windows git is unreadable to WSL git

**2026-08-28.** `make` on this box lives in WSL, and `make build-amd64` from a
worktree died in `scripts/os7-source-facts.sh`: the worktree's `.git` is a
FILE holding `gitdir: C:/Users/…/OS7/.git/worktrees/<name>` — an absolute
WINDOWS path, which WSL's git resolves relative to the worktree and reports
"not a git repository". #43's family, one layer up: not the container this
time, but the OTHER operating system on the same machine.

git accepts a RELATIVE gitdir pointer, and `gitdir: ../OS7/.git/worktrees/…`
resolves under both roots. One line, and both worlds read the same repository.
(The back-pointer in `.git/worktrees/<name>/gitdir` stays absolute and only
matters to `git worktree` management commands run from the main checkout.)

## #102 — Git Bash rewrites `--device /dev/kvm` into `--device C:/…`

**2026-08-28.** `docker run --device /dev/kvm` from Git Bash (MSYS) fails with
`error gathering device information while adding custom device "C"`: MSYS
path conversion sees a leading `/` and helpfully turns `/dev/kvm` into a
Windows path before docker ever sees it. The same command from PowerShell, or
from Python's `subprocess` (no shell), passes the literal string and works —
which is why the harness never hits this and an interactive probe does.
`MSYS_NO_PATHCONV=1` or a doubled slash (`//dev/kvm`) are the escapes.

## #103 — DEBIAN_FRONTEND=noninteractive does not answer dpkg's conffile prompt

**2026-08-28, one check-os7-repo iteration.** The harness writes its own
`/etc/apt/sources.list.d/os7.sources` before installing os7-release — which
ships the same path as a CONFFILE since the same day — and the install died
with

    *** os7.sources (Y/I/N/O/D/Z) [default=N] ? dpkg: error processing
    package os7-release (--configure):
     end of file on stdin at conffile prompt

`DEBIAN_FRONTEND=noninteractive` silences DEBCONF; dpkg's conffile prompt is
dpkg's own, and with stdin at EOF it is an ERROR, not a default. The nine
failures it produced downstream all described a machine that was never
branded — none of them named the prompt. The answer is
`Dpkg::Options { "--force-confdef"; "--force-confold"; }` (apt.conf, or
`-o Dpkg::Options::=` per call), which is exactly what `Update-OS7`'s own apt
runs have carried since their review — the production path never had the bug,
only the harness that judges it did.

## #104 — an activation that fails halfway keeps half its work, and the next boot is the half-activated pair

**2026-08-28, the first end-to-end `Update-OS7` run.** The update built the
new environment, upgraded it, and threw at activation step 6: "no ESP stub
was rewritten — /boot/efi is not mounted". The catch said, as designed,
*"os7_1.0.0.134… is built, INACTIVE and left in place; this machine still
boots what it booted."* Both halves of that sentence were false.

`Set-OS7BootEnvironment` had already run step 3 — canmount flipped across
every environment, the target's datasets to `on` — before it threw. Nothing
took the flips back. The environment was therefore not inactive but ARMED:
on the next boot, `zfs mount -a` mounted the target's `bpool/BOOT` dataset
**over the running system's /boot**, burying the ESP's vfat mount under it —
`findmnt /boot/efi` still showed vfat (the shadowed mount entry survives in
mountinfo) while the PATH resolved to an empty directory on the target's
dataset. Measured directly:

    556 … /efi /run/os7-update/boot/efi … zfs bpool/BOOT/os7_1.0.0.134_…

— a `mount --bind /boot/efi` that carried the CLONE's empty efi directory,
because /boot/efi no longer meant the ESP. That is §4.3's half-activated
pair, reached by an activation that failed halfway and kept half its work,
and it is the road "nothing checks" that the plan warned about.

Three changes, one per layer:

* **The flips are transactional now.** Every canmount change records the
  value it replaced, and any throw between the flips and the end of
  activation restores them before rethrowing — "left in place, INACTIVE" is
  a promise the catch can keep.
* **Every plain bind the update assembler makes is `--make-slave`d** the
  moment it exists: on a systemd system every mount is shared, so a bind
  JOINS ITS SOURCE'S PEER GROUP, and a scaffold must receive events, not
  send them — the reasoning the rbinds carried all along.
* **`Assert-OS7EspMounted`** runs before anything globs the ESP: an
  unmounted /boot/efi reads as "grub-install never wrote one", and a
  precondition that can be stated should not be inferred from an empty glob.
  It asks systemd (`boot-efi.mount`, through the Systemd layer — P2-systemd's
  baseline may not rise) to mount it where possible.

WHAT WAS NOT PROVEN AT FIRST WRITING — why /boot/efi was unavailable at
step 6 *within the failing run itself* — WAS MEASURED A DAY LATER, and it
was never an in-session loss at all. **The machine had booted broken.**

/boot is a ZFS mount (bpool/BOOT/&lt;be&gt;, mounted by zfs-mount.service), and
systemd has no unit for it — this image ships no /etc/zfs/zfs-list.cache,
so zfs-mount-generator emits nothing and the fstab-generated boot-efi.mount
has NOTHING to order against. Every boot is a race. When the ESP mounts
first, the /boot dataset lands ON TOP of it: mountinfo showed
/boot/efi with a LOWER mount id than /boot — mounted earlier, buried under
the later ZFS mount. The vfat stays in the mount table, so every
diagnostic that reads the TABLE lies: `findmnt /boot/efi` lists it,
`boot-efi.mount` reads active, `systemctl start` is a no-op that exits 0 —
while every diagnostic that resolves the PATH tells the truth: `ls
/boot/efi/EFI` finds nothing, and activation's glob finds no stubs. The
"mechanism that moved between runs" was this race lost at boot and then
misread as an in-session event — four probe runs "proved" the ESP survived
assembly and disassembly by asking findmnt, the table, and never once the
path. A diagnostic must be checked against the thing it claims to check;
these four were checked against the mount table.

The fix is ordering, in three places:

* **Setup writes the ordering into fstab** for new machines:
  `x-systemd.requires=zfs-mount.service` on the /boot/efi line —
  systemd.mount(5) makes that Requires= and After=, so the ESP mounts onto
  the ZFS /boot, never under it.
* **Migration 60-fstab-esp-ordering** appends the same option on machines
  installed before the fix, at their first boot after an update.
* **`Assert-OS7EspMounted` heals a lost race at runtime**: EFI directory
  missing while /boot is ZFS-served means the orphan shape — it takes the
  whole /boot stack down (the orphaned vfat goes with it), remounts the
  running environment's boot dataset, and then asks systemd, which has just
  watched the umounts and now agrees the unit is dead and actually mounts
  the ESP again.

## #105 — the revert was transactional, and a file the catch never knew about voted anyway

The end-to-end gate on the first fully packaged ISO (2026-08-28,
[SESSION-UPDATE-DELIVERY.md](SESSION-UPDATE-DELIVERY.md)). Activation of a
cloned boot environment threw at step 6 — the ESP was unmounted again, #104's
still-open mechanism — and the #104 fix WORKED: all eight canmount flips were
restored, the cmdlet said so, and nothing about the datasets had changed. The
machine then rebooted into the half-activated pair anyway.

The voter was `saved_entry`. Step 5 wrote it into the RUNNING system's
grubenv — before step 6, on the argument that a machine that "never gets as
far as step 6" should still boot what was asked for. That argument is
backwards, and the gate measured why: the running grubenv takes effect THE
MOMENT it is written, because until step 6 the ESP stub still points at the
running environment's menu. So the failed activation left `GRUB_DEFAULT=saved`
pointing at a clone whose canmount the catch had just carefully taken back,
and the next boot assembled §4.3's pair from the menu side: / from the clone,
/boot and /var/lib/dpkg from the origin. `run-s5.py` then reported "THE
MACHINE BOOTED THE CLONE — ok", because the harness's own checks accepted a
grubenv line as proof of a stub rewrite that had never happened.

Three corrections:

* **The running system's grubenv is written AFTER the stub rewrite.** The
  stub rewrite is the point of no return; everything that takes effect
  immediately now sits behind it. The target's own grubenv (step 5) stays
  where it was — it is inert until the stub makes it the file GRUB loads.
* **A failure after the point of no return leaves the activation STANDING.**
  Reverting the flips once the ESP names the target would manufacture the
  half-activated pair; the catch now says the activation stands and rethrows.
  `Update-OS7`'s catch asks `Get-OS7BootEnvironment` whether the stub was
  rewritten before claiming "this machine still boots what it booted".
* **The harness now requires the activation's own success line** ("ESP
  stub(s) now point at") and matches the stub's `/BOOT/<name>@` prefix line,
  not any occurrence of the name — a grubenv entry is not a stub.

A second, smaller defect fell out of the same boot: on the half-activated
machine, /boot is ALREADY served by the rollback target's boot dataset, and
step 4's `Copy-Item` of /boot/grub/grub.cfg into that same dataset refuses
("cannot overwrite the item with itself") — so the one activation that would
REPAIR the state was the one that could not run. The copy is now skipped,
with a step line, when findmnt says /boot's source IS the target's dataset.

The general rule, one more time and from a new side: a transaction is only as
transactional as the LIST of things it undoes. The flips were recorded and
restored; the grubenv write was in the same try block and in nobody's ledger.
When a catch promises "nothing changed", every write above it must be in the
ledger, or the promise is a claim about the ledger, not the machine.

## #106 — a KEY="value" file written without a trailing newline corrupts on the first append

`Set-OS7UpdateChannel` wrote `/etc/os7/update.conf` without a final newline.
The unattended-check harness then did what any operator will do:
`printf 'OS7_UPDATE_UNATTENDED_ALLOW_DEVELOPMENT="yes"\n' >> update.conf`.
The append glued onto the last line, and the file's channel became

    OS7_UPDATE_CHANNEL="development"OS7_UPDATE_UNATTENDED_ALLOW_DEVELOPMENT="yes"

The module's conf parser stripped the OUTERMOST quote pair and returned
`development"OS7_UPDATE_UNATTENDED_ALLOW_DEVELOPMENT="yes` as the channel
name; the unattended check went looking for an index file by that name, found
nothing, and exited 1 — a corrupted CHANNEL out of an append that meant to
set a FLAG, with both settings lost.

Fixed at both layers, because each would have contained the other: the writer
ends the file with a newline (a KEY=value file that invites `echo >>` must),
and the parser treats a quoted value as ending at the NEXT matching quote —
trailing garbage after the closing quote is now a loud `FormatException`
naming the file and line, not a silently wrong value. The harness append
starts with `\n` regardless, for images whose module predates the fix.

The rule: a file format is defined by what will be APPENDED to it, not just
by what is written into it. If the convention is "operators add KEY=value
lines", the writer's last byte is load-bearing.

## #107 — "previous" is ancestry, not age: Restore-OS7 rolled back to the experiment

The second full gate run (2026-08-28): install, boot, cycle and timer all
PASS, and update failed its LAST check — the machine rolled back from
1.0.0.136 and came up in `os7_1.0.1.0_…`, the cycle phase's leftover clone,
not in the 1.0.0.135 the update had been applied to. `Restore-OS7` without
an argument picked "the newest boot environment older than the running one",
which was the documented rule — and with a third environment on the machine
the rule picked the experiment, because the experiment was newer than the
environment the update actually came from. The one-word panic path landed a
machine that meant "undo the update" on a clone with somebody's test package
in it.

The fix: "previous" is ANCESTRY first. The running environment's root
dataset carries its `origin` — the snapshot of the dataset it was cloned
from — and that is a record, not a heuristic. Restore-OS7 now asks ZFS for
the origin, rolls back to that environment when it is present and complete,
and falls back to newest-older only when there is no origin in the list (a
promoted clone, or the original install).

The harness half, same shape as #105's: the check had matched `old_be`
ANYWHERE in Restore-OS7's output — and the name appeared in the menu-fragment
listing even when the cmdlet chose the clone, so "Restore-OS7 chose
1.0.0.135" printed ok one boot before 8/8 measured the truth. It now
requires the cmdlet's own step lines: "rolling back to the previous boot
environment: <old>" and "ESP stub(s) now point at <old>".

The rule is #16's, met a fourth way: never accept a marker the output would
carry anyway. A name in a listing is not a decision; the line where the
program SAYS what it decided is.

## #108 — the machine with no journal: the flush beats zfs-mount, and the real /var/log buries what it wrote

**2026-08-28, diagnosed on a machine installed for the purpose from
OS7-1.0.0.134-amd64.iso** ([SESSION-MISSING-JOURNAL.md](SESSION-MISSING-JOURNAL.md)).
The installed machine had NO systemd journal at all — `journalctl` said "No
journal files were found" while journald read active, machine-id was
populated, and BOTH journal roots existed, empty. It cost the #104 diagnosis
its forensics: no journal on any boot to ask.

The mechanism is #104's root cause producing its third symptom. `/var/log` is
`rpool/DATA/log` (outside the boot environment, §4.4), the image ships no
`/etc/zfs/zfs-list.cache`, so zfs-mount-generator emits nothing and NOTHING
in systemd's graph knows /var/log is a filesystem —
`systemd-journal-flush.service`'s own `RequiresMountsFor=/var/log/journal`,
upstream's guard against exactly this, orders against nothing. Measured on
boot 1 of the fresh machine, from systemd's own monotonic clock: flush
finished at 8.24 s, zfs-mount ran at 9.35 s. In between, journald flushed the
runtime journal into `/var/log/journal/<machine-id>` ON THE BOOT
ENVIRONMENT'S ROOT DATASET — creating the whole chain itself, Storage=auto
notwithstanding — and deleted `/run/log/journal/<machine-id>`. Then
`zfs mount -a` put the real /var/log on top (`overlay=on` is the OpenZFS
default, so mounting over the now-non-empty directory is silent). journald's
fd 23 pointed at the shadowed file — 8 MiB and growing under a bind mount of
/, invisible at every path journalctl checks. Every boot, deterministically:
the flush takes ~0.2 s, the ZFS import chain ~1.2 s.

Nothing errors, because nothing is wrong at the layer each tool checks:
journald's writes succeed, the mount table is consistent, journalctl
truthfully reports the visible roots empty, `systemctl is-active
systemd-journald` truthfully says active. The one line the machine ever
prints is journald's "Failed to open user journal file, falling back to
system journal: No such file or directory" — in dmesg, the log that still
works precisely because it is not journald's.

The control that closed the diagnosis: `systemctl restart systemd-journald`
on the running machine (mount now present, flushed flag standing) made the
journal appear on the DATASET and `journalctl` return entries for the first
time in the machine's life. Ordering is the whole defect.

The fix is one drop-in, shipped by os7-release
(`/usr/lib/systemd/system/systemd-journal-flush.service.d/os7.conf`):
`After=zfs-mount.service`. Ordering only, no Wants=; no new critical-path
work, since zfs-mount is already Before=local-fs.target and tmpfiles-setup —
which the flush precedes — is already After=local-fs.target. The runtime
journal holds every early message until the real /var/log is there, which is
what it is for. Verified on the machine: with the drop-in, the next boot's
journal is on rpool/DATA/log and journalctl answers. `check-image.py` now
requires the drop-in in the shipped squashfs.

Two rules this paid for again: a subsystem that reports success is not a
subsystem that worked (#73's shape — journald, the flush unit and zfs-mount
all exited 0 on every affected boot); and the structural fix — shipping
zfs-list.cache so EVERY dataset gets a real mount unit and RequiresMountsFor
works as upstream designed — stays open beside this, as it did beside #104's
fstab option.
