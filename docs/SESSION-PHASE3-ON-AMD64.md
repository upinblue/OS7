# Session: run-phase3.py on the amd64 host — two of three phases, and why the third cannot

**Date:** 2026-09-07 · **Host:** x64 Windows 11 + WSL2 + Docker Desktop · **Medium:** `OS7-1.0.0.190-amd64.iso`, built this session from a pristine worktree at `628730e`

`run-phase3.py` had never run on this host — CLAUDE.md's host table said the harnesses other
than `run-s5.py` were "ported and UNRUN" here, and BUILD-NOTES #74's fix had been waiting for it
since 2026-08-26. It has now run.

| phase | verdict |
|---|---|
| `install` | **PASS** — 18/18 steps, both assertions |
| `boot` | **harness FAIL, machine good.** The assertion cannot be made on amd64; see below |
| `walk` | **PASS** — every screen 1 to 12, including **screen 9D, which had never drawn on a machine** |

## What `install` and `walk` settle

`install` ran unattended to `OS7-SETUP-DONE`, and `walk` did the whole thing again **by
keypress**: screens 1–12, the passphrase typed and confirmed, the account form, the mode screen,
the network screen taking a real DHCP lease on the live medium (10.0.2.15), **screen 9D drawn and
declined**, the executor starting, the copy bar advancing (19% → 57% over 7 samples), and the
Complete screen naming the medium's version (1.0.0.190), the disk, the encryption, the computer
name, the account and the mode. Both phases exported both pools.

**Screen 9D drawing is the news.** AD-PLAN AL1 and [SESSION-AD-JOIN.md](SESSION-AD-JOIN.md) both
recorded that the installer's road to the join was unexercised. It is drawn now, and it declines
correctly when the domain field is left blank — which is what `walk` types. What is still
unexercised is a join FROM the installer, and with it the `-UseLdapPassword` retry: `walk`
deliberately leaves 9D blank, so `DomainStep` takes its "not joining" branch (step 15 of 18).

## BUILD-NOTES #74 and A9, on a machine, at last

The reason #74's fix had been waiting for this harness. Read off the installed machine:

```
rpool/USERDATA/os7admin_0f855748    /home/os7admin
rpool/DATA/lib/os7-domain-homes     /var/lib/os7/domain-homes
rpool/ROOT/os7_1.0.0.190_202609071408   /
```

- **#74** (assertions 9 and 10): the account's home is a `rpool/USERDATA` dataset of its own, not
  a directory inside the boot environment. The bug that shipped an empty `/home/os7` and the real
  home inside the BE is gone, verified on a machine Setup installed.
- **A9**: `rpool/DATA/lib/os7-domain-homes` exists, mounted at `/var/lib/os7/domain-homes`, under
  `rpool/DATA` and therefore outside the boot environment. This session's A9 fix
  ([SESSION-AD-JOIN.md](SESSION-AD-JOIN.md)) is in a machine rather than in a dry run.
- The rest of the layout matches `run-phase2.py`'s `WANT_DATASETS` exactly.

## Why `boot` cannot pass on amd64 — #132

`boot` attaches no ISO and watches the serial console for the LUKS passphrase prompt. It timed
out after 600 s with **398 bytes** of serial output, ending at

```
BdsDxe: starting Boot0002 "OS/7" from HD(1,GPT,…)/\EFI\OS7\shimx64.efi
```

**The machine is fine.** Opened as an `os7lab` bench and photographed, it does all of this:

| what the screen showed | which assertion it satisfies |
|---|---|
| GRUB 2.14, branded blue, `*OS/7 1.0.0 (preview)`, auto-boot countdown | 1 — GRUB works |
| kernel messages, then `Please unlock disk os7_root:` | 1 — kernel and initramfs work |
| after the passphrase: `OS/7 1.0.0 (preview) os7-phase3 tty1`, `os7-phase3 login:` | 3, 8 — pool imported, `/` mounted, hostname |
| `os7admin` + its password → `PS /home/os7admin>` | 4 — the account Setup created |
| MOTD: `boot environment os7_1.0.0.190_202609071408` | 5 — `/` from the right dataset |
| `Get-OS7Version` → `OS/7 1.0.0 (preview)`, `Ubuntu 26.04 base, Server, amd64` | 6 |

None of it reaches the serial line, and `/proc/cmdline` says why:

```
BOOT_IMAGE=/BOOT/os7_1.0.0.190_202609071408@/vmlinuz-7.0.0-30-generic
root=ZFS=rpool/ROOT/os7_1.0.0.190_202609071408 ro boot=zfs crashkernel=…
```

**There is no `console=` at all**, so the installed machine speaks only to tty0. The live medium
gets `console=ttyS0` because the harness puts it on the direct-boot command line; the installed
system inherits nothing. On arm64 the serial port is the primary console and the same harness
sees everything, which is why this was invisible until the port was exercised here.

It is **not** a regression from this session's changes: adding a dataset cannot remove a console
parameter, and `install` — which uses the same Setup — passed.

**Two ways to fix it, and they are not equivalent.** Left open deliberately:

1. **Setup writes a console onto the installed command line.** For a product whose arm64 edition
   is server-only this is arguably right, and it would make every installed machine observable
   over serial. But it changes what the console IS on every machine OS/7 installs, which is a
   D-level decision and not a harness detail.
2. **The boot phase observes the screen on amd64**, as `walk` already does through the console
   font. Cheaper in principle, except that the phase does not only WATCH: after login it runs
   ten assertions over the console as a command channel. Without serial it needs ssh — which is
   `os7lab`'s arrangement, and would make the phase a different shape on each architecture.

## Three traps paid for on the way to the first successful build

Three builds were needed. Two of the failures were real findings, and neither was in the code.

**A concurrent session edited a build input mid-build.** The first build died in hook 0060 with

```
OS7: FAILED: OS7 module does not export n
```

A single letter as an expected cmdlet name — which in a shell is what an argument becomes when a
line continuation is broken. The committed hook is clean: the shell itself lists 74 well-formed
names, the module exports all 74 (123 exports in total), and the freshly built
`os7-module_1.0.0.190_all.deb` carries all 21 files. The file's mtime told the story: another
session wrote it at **15:13:37**, eight minutes into a build that reads the working tree through
a bind mount, and live-build copied a half-saved version into the chroot. Nothing to fix; the
lesson is that a build from a bind-mounted working tree is not reproducible while anybody is
editing it. A `git worktree` at HEAD is the answer, and it is what produced the ISO here.

**#131 — a worktree created by Windows git is unusable from WSL.** The second build refused:

```
!!! /work/.git is a FILE - this is a git worktree, and it says:
!!!   gitdir: C:/Users/BastianWirth/source/repos/OS7/.git/worktrees/os7-phase3-build
!!! refusing to build an ISO whose version identifies nothing.
```

BUILD-NOTES #43 says to build through the Makefile because it asks git on the HOST. On this host
"the host" is two things: Windows git wrote a Windows path into `.git`, and WSL git cannot follow
`C:/…`. So `os7-source-facts.sh` produced nothing and `build.sh` correctly refused rather than
stamping `1.0.0.0`. Rewriting the pointer to `/mnt/c/…` fixed it, and the third build produced
`OS7-1.0.0.190-amd64.iso` with `OS7_GIT_DIRTY=false`.

**And the reverse of that fix broke a check.** With the pointer pointing at `/mnt/c/…`,
**Windows** git could no longer read the worktree, so `check-image.py` reported

```
FAIL  the 0 authored includes.chroot files carry git's modes
```

Zero expected files. The check is right to fail on that — `bool(want) and not wrong` treats an
empty expectation as a failure, which is the same "cannot tell is not clean" rule the rest of
this repository follows. Pointer restored, 12 files, and `check-image.py amd64` green on every
check: *OS/7 1.0.0.190 (preview), amd64, archive 20260824T000000Z, and every source in it says
so.*

## What this does not say

- **`boot` did not pass.** The machine was verified by hand, from screenshots, with a person
  reading them. That is evidence about this machine; it is not a harness result and must not be
  quoted as one.
- **No join happened.** Step 15 was "Not joining a domain", so `DomainStep`'s join path — and the
  `-UseLdapPassword` retry — remain unexecuted by an installer.
- **The TPM was sealed to (step 13) and never tested here.** #69 is `run-s5.py boot`'s question.
- **arm64 is untouched.** Everything above is amd64.
- The evidence screenshots and the three logs are under
  `D:\HyperV\OS7-DC01\lab-scripts\phase3-evidence\`, outside the repository, because `.vm/` is
  gitignored and the worktree is disposable.
