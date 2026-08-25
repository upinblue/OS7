# amd64 on Windows — two blockers, and the first ISO built outside CI

**Date:** 2026-08-25. Against `main` at `11dd676`, working tree dirty with the
changes below. Host: **Windows 11 Pro + WSL2 + Docker Desktop, native x86_64** —
a third build host, and the first that is neither an Apple Silicon Mac nor
GitHub Actions.

**`OS7-1.0.0.95-amd64.iso` exists, built locally.** 3.26 GB, 1539 packages,
`check-image.py amd64` green on every check. **It has not been booted, and
nothing here claims it has.**

---

## What was asked

`make build-amd64` failed on the first line of output with

```
env: $'bash\r': No such file or directory
```

Two separate traps were in the way. Neither had anything to do with the other,
and the second could not have been found until the first was gone.

---

## #62 — the checkout, not the build

Git for Windows ships `core.autocrlf = true` in its **system** config, so 166
files landed on disk with CRLF and `#!/usr/bin/env bash\r` stopped naming an
interpreter.

**What made it expensive to see is that git agrees nothing is wrong.** The
conversion is symmetric: every blob in the history is LF (`git show HEAD:… |
od -c`), no commit contains a CR byte (`git grep -I -l $'\r$' HEAD` → nothing),
and `git status` is clean. There is no diff, no bad object, and no commit to
blame — the corruption exists only in the files on disk, which is the only place
`env` looks.

Fixed with `.gitattributes` (`* text=auto eol=lf`), which **overrides**
`core.autocrlf` and therefore fixes every future clone rather than one machine.
`powershell/Zfs/tests/fixtures/**` is marked `-text`: those are recorded real
ZFS output and an end-of-line filter must never edit a measurement.

**Measured, not assumed:** renormalising produced **zero** content diff, which
is the proof that the history was always clean.

---

## #63 — a local apt repository signed with gnupg 1.x code

With the shebangs fixed the build ran ~1500 lines further and died in
`lb_chroot_archives`, first with `env: 'gpg': No such file or directory` and
then, once gnupg existed, with `signing failed: No secret key`.

A non-empty `config/packages.chroot` makes live-build build a **local apt
repository** inside the chroot and sign it. Its signing code predates GnuPG 2:
`--secret-keyring`/`--keyring` are ignored by gnupg ≥ 2.1, and `--batch
--gen-key` has no `%no-protection`, so gpg wants a passphrase, finds no tty, and
fails.

**Why it had never been seen, established from git rather than guessed:** the
theme package landed in `eb5d600`, a **descendant** of `c395e4c`
(SESSION-AMD64-FIRST-ISO.md). The CI ISO was built when `packages.chroot` was
still empty — 1528 packages, no theme. The change that gave amd64 a desktop is
the change that broke its build, and in the 50 commits since, no amd64 build ran
anywhere: CI was not dispatched again, Apple Silicon is blocked by #12, Windows
by #62.

**Three ways out, each measured and rejected:**

| | why not |
|---|---|
| `LB_APT_SECURE=false` | `lb_bootstrap_debootstrap:112` turns it into `debootstrap --no-check-gpg` — the pinned snapshot stops being verified |
| an earlier hook | none exists: `chroot_archives` is stage **52**, `early_hooks` 57, `includes` 77, `hooks` 78 |
| patch live-build | carries an upstream patch; OS/7's answer to "live-build cannot" is `efi-remaster.sh` — do it ourselves |

**The fix removes the class.** `packages.chroot` is now used by neither
architecture. The theme `.deb` is staged into `config/includes.chroot` and
installed by new hook `0085-install-desktop-theme.hook.chroot` with `apt-get`
(which resolves Depends against the pinned archive; `dpkg -i` would not). It
asks `dpkg -s` whether the install happened, then deletes the `.deb` so a build
input does not ship. Verification stays in 0090 — installing and checking in one
hook would be a program marking its own work. `build.sh` refuses to build if
anything reaches `packages.chroot` again.

---

## What was measured

* `check-image.py amd64` — every check `ok` on the **shipped** image: all six
  apt sources on `snapshot.ubuntu.com` at `20260824T000000Z`, `IMAGE_VERSION`
  1.0.0.95, `os7-setup --self-test` passing chrooted into the image,
  `Test-ZfsModule` 56/0, volume `OS7-1.0.0.95-amd64`.
* `xorriso -report_el_torito` — a **UEFI** El Torito image at
  `/boot/grub/efiboot.img`, so `efi-remaster.sh` ran on amd64.
* Hooks 0085 and 0090 in the build log: theme installed, build input removed,
  and 0090's 19 independent checks all `ok` — including `dconf` defaults checked
  against GNOME's own schema list and `fc-match Tahoma → Tahoma`.
* Every tracked file at **0** CR bytes after renormalisation.

## What was NOT measured

* **Whether this medium boots.** No QEMU and no OVMF on this host.
  SESSION-AMD64-EFI-REMASTER.md measured an amd64 medium booting, so the path is
  proven in general — but not for this build.
* **arm64.** Untouched by intent, and not rebuilt here. The `packages.chroot`
  change cannot affect it (arm64 never populated it) and `LB_BOOTSTRAP_INCLUDE`
  adds a package it already installs, but that is reasoning, not a build.
* **Whether `LB_BOOTSTRAP_INCLUDE=gnupg` is still required.** It is not, in the
  strict sense: the guard makes the signing path unreachable. It is kept as the
  second line of defence and costs nothing, but no build has proven that
  removing it is safe.

## What it changes in the plan

* **Windows 11 + WSL2 + Docker Desktop is a working amd64 build host**, and the
  only one that is neither a Mac nor CI. `make build-amd64` takes ~20 minutes
  here end to end.
* **`config/packages.chroot` is off-limits** on both architectures, enforced by
  build.sh. Anything OS/7 builds itself is delivered through
  `includes.chroot` + a hook.
* Four places still say amd64 has never been built — `Makefile:4`, `CLAUDE.md:208`,
  `SESSION-PHASE2-STORAGE.md:213`, `SESSION-SCREEN6-GATE.md:261`. They were
  already stale before this session (SESSION-AMD64-FIRST-ISO.md says the
  repository "said, in four places, that amd64 had never been attempted"), and
  they are staler now. Left alone here rather than half-corrected.

## Two things to carry

* **Do not trust an exit status marshalled back through `wsl.exe`.** `rc=$?`
  after `make` came back `0` and then empty for builds that had printed
  `make: *** Error 127`. The artefact and the log are the facts.
* **Git Bash's `sed` strips CR silently.** It showed clean `\n` for a Makefile
  that had 162 CRs in it. On this host only `od -c` and `tr -dc '\r' | wc -c`
  can be believed about line endings.
