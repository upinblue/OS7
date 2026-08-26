# Session — OS/7 becomes something dpkg knows about

**2026-08-26**, on the x64 Windows host. `Update-OS7` was the task; this is what
had to exist first, and the reason is in the stub's own help:

> **WHAT IS STILL MISSING IS THE RELEASE ITSELF** … there is nothing yet to
> point them AT. There is no OS/7 package repository, nothing on a running
> system belongs to an OS/7 package, and no release index is published or
> signed. Until that exists, this cmdlet could only apply plain Ubuntu updates
> and call them an OS/7 release, which is the one thing §5 says makes the
> version number worse than none.

So this session did C7 — [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md)
§6 — and stopped there. `Update-OS7` is still a stub, and it now has somewhere
to point.

---

## 1. What was unowned, and now is not

§6.1's table, checked again in the shipped image before anything was written:

| component | where it lands today | owned by a package? |
|---|---|---|
| PowerShell 7.6.5 | `tar -xzf` → `/opt/microsoft/powershell/7` (hook 0020) | no |
| OS7 + Zfs modules | `/usr/local/share/powershell/Modules/` (build.sh, hook 0060) | no |
| `os7-setup` + its unit | `/usr/lib/os7-setup/` (build.sh, hook 0080) | no |
| release manifest | `/usr/lib/os7/release.json` (hook 0075) | no |
| console fonts, palettes | `includes.chroot` | no |
| os-release branding | rewritten in place (hook 0075) | no — it is `base-files`' conffile |

Nine packages now exist, built by `build/lib/build-os7-packages.sh`:

```
os7-release      the pin, the release facts, the trust anchor, the apt source,
                 and the os-release identity — which it DIVERTS from base-files
os7-console      the four PSFs, both palettes, the console-setup defaults
os7-powershell   the pinned upstream tarball, repacked, plus the profile drop-in
os7-module       OS7 and Zfs, stamped with the release version
os7-backup       the units, the two libexec scripts, the design document
os7-setup        the NativeAOT binary, its unit, the quiesce generator
os7-base         membership: release + console + powershell + module, all `= version`
os7-server       base + backup
os7-desktop      base + backup + os7-desktop-theme
```

`os7-desktop-theme` was already a real `.deb` before this session — built by
`build-desktop-theme.sh` and installed by hook 0085 with `apt-get install
<path>`, because `config/packages.chroot` cannot be used at all (BUILD-NOTES
#71). **That is the shape this generalises.** Nothing new was invented; the one
package that already worked became nine, and they went into a repository.

## 2. The mechanism, and the one decision it forced

`build/lib/build-os7-repo.sh` produces:

```
keyring/os7-archive-keyring.gpg        the trust anchor os7-release ships
pool/main/o/<pkg>/<pkg>_<v>_<a>.deb
dists/os7-1.0/main/binary-<arch>/Packages{,.gz}
dists/os7-1.0/Release, Release.gpg, InRelease
releases/<version>/release.json        the release DESCRIPTOR (C9)
index/development.json{,.asc}          the release INDEX (§6.4)
```

The suite is `os7-1.0` — named after MAJOR.MINOR and not after the release,
because C11 says any version may move to any later version within one Major and
C12 says `Update-OS7` must refuse to cross one. A suite per release would make
every update a `sources.list` edit; a suite per generation makes it an apt
operation.

**C7a is untouched and stays open.** Where a release signing key lives and who
holds it is, in the plan's own words, "not a technical question, and not one to
answer by accident on the day the first repo is published". So the script signs
with a key handed to it in `OS7_REPO_GNUPGHOME`, and when there is none it
generates one whose user ID reads

```
OS/7 DEVELOPMENT signing key — NOT FOR RELEASE <os7-dev@localhost>
```

prints its fingerprint on every run, and records `"development": true` in the
release descriptor — so a machine can refuse a development release without
having to recognise a fingerprint.

## 3. UL10 closes, by mechanism rather than by remembering

`/etc/os-release` is a symlink to `/usr/lib/os-release`, and `base-files` owns
that as a **conffile**. Before this, every `apt` run that touched `base-files`
could revert the OS/7 branding, and the release plan mitigated it with

> an idempotent reassert as a step in the update sequence, not a one-time write
> at install.

A step that has to be remembered forever is a defect. `os7-release` now
`dpkg-divert`s the path: `base-files` writes to `.distrib` and can no longer
touch the real name at all.

**It does not ship the file.** The branded os-release has to carry base-files'
*own* values for `NAME`, `ID`, `ID_LIKE`, `VERSION`, `VERSION_ID` and
`VERSION_CODENAME` — fields that belong to somebody else (IDENTITY-PLAN I4) and
that OS/7 must never invent. Shipping a static file would be inventing them. So
the postinst derives ours **from** `.distrib`, and a dpkg file trigger re-derives
it when base-files writes a new one.

Hook 0075's rewriter moved out into `build/lib/os-release-identity.py` for this,
because there are now two writers of that file — the hook at image-build time
and the postinst on an installed machine — and two writers must not be two
implementations.

## 4. Six things the check found, none of which a reading would have

Every one of these was found by running the thing, and every one of them
produced a green-looking build first.

### Sourcing the pin silently discards the environment

`docker run -e OS7_REPO_URI=file:///repo` followed by `source os7-release.conf`
leaves `OS7_REPO_URI` at the **pin's** value: a plain assignment in a sourced
file wins over an exported variable, and says nothing. So `os7-release` shipped
an apt source pointing at a path that does not exist. The symptom appeared two
steps later and named neither:

```
E: Unable to locate package os7-setup
```

— because `os7-release`'s postinst had replaced the harness's sources file with
its own, apt lost the OS/7 source, and the next `apt update` failed on a URI
nobody had asked for. Both scripts now capture the three repository-facing
values before sourcing and restore them after.

### An apt source that points nowhere is not harmless — so it ships **off**

The placeholder URI is a local path nothing creates, so every OS/7 machine would
have printed, on every `apt update`, forever:

```
E: The repository 'file:/usr/lib/os7/repo os7-1.0 Release' does not have a Release file.
```

An administrator seeing that on a fresh machine cannot tell it from a broken
mirror. `OS7_REPO_ENABLED` is a new pin, it is `"no"`, and the source ships
`Enabled: no` — declared and switched off, which is the true statement: OS/7 has
a repository and this machine has not been told where it is.
`Set-OS7UpdateChannel` is the verb that will turn it on.

### `(Get-OS7Version).FullVersion` does not print a version

It is a `[version]`, and PowerShell formats one as a **table**:

```
Major  Minor  Build  Revision
-----  -----  -----  --------
1      0      0      119
```

in ANSI colour. The type is deliberate — it is what makes `-ge [version]'1.1.0'`
work without a parse (IDENTITY-PLAN §7) — and the cost is that every shell
caller must ask for `.ToString()`. This is the same `[version]` trap §7 names,
in its other guise: not a comparison that misreads, a value that will not print.

### Both font builders leave their uncompressed intermediate behind

`os7-fixedsys-8x16.psf` and `os7-console-8x16.psf` sit beside the `.psf.gz`
files they were compressed into. Nothing reads them: `/etc/default/console-setup`
names a `.psf.gz`, `os7-setup` names a `.psf.gz`, and both builders' own checks
only ever look for the compressed name. The package now ships four files rather
than six — and **the ISO has the same two today**, because `build.sh` stages the
same directory into `includes.chroot`. Small, and worth removing in the change
that switches the image over.

### `apt-ftparchive`'s `ValidUntil` is accepted, ignored and silent

### `apt-ftparchive`'s `ValidUntil` is accepted, ignored and silent

Full account in [BUILD-NOTES #88](BUILD-NOTES.md). `-o APT::FTPArchive::
Release::ValidUntil=<date>` and `...::Valid-Until=<date>` are both taken, both
ignored, and the Release comes out with no expiry and exit code 0. Only
`ValidTime`, in seconds, produces the field. An index that never expires is
exactly the replay §6.3 is about, and nothing anywhere reports it.

What caught it was the readback — `grep -q '^Valid-Until:'` on the file that had
just been written — which was there because this repository's rule is that a
program which writes a file re-reads it. It earned its place on the first run.

### `ubuntu:26.04` ships no CA certificates

`ca-certificates` is `un` and `/etc/ssl/certs/ca-certificates.crt` does not
exist, so every fetch from `https://snapshot.ubuntu.com` fails — and **apt
reports that as a warning and exits 0**. The only visible symptom was that
`sanoid`, a `universe` dependency of `os7-backup`, became "not installable" with
no explanation. The harness now hands the container a trust store taken out of
the build image and says why; it is a fact about the base image, not about OS/7's
packages, which is why it is not fixed in a package.

### `bash` on a Windows host is two different programs

This is the first harness in `installer/testing/` written to run on the x64
Windows box as well as on the Mac, and getting `scripts/os7-source-facts.sh` to
run cost three attempts:

| attempt | what happened |
|---|---|
| execute the `.sh` directly | `OSError [WinError 193] %1 is not a valid Win32 application` |
| `bash C:\…\os7-source-facts.sh` | bash removes the backslashes as escapes and opens `C:…os7-source-facts.sh` |
| `bash C:/…/os7-source-facts.sh` | **`bash` on PATH is WSL's** (`C:\Windows\System32\bash.exe`), which cannot see `C:/…` at all — it wants `/mnt/c/…` |

All three produce **BUILD=0**, which is precisely the value BUILD-NOTES #43 is
about: a version number that means "git could not be asked". The first run built
a whole repository as `1.0.0.0` and reported success at every step. The guard
that now refuses a BUILD field of 0 outright is what turned it into a failure
instead of a release nobody could tell from another.

The check resolves the shell from `git`'s own install location and falls back,
trying each candidate until one answers with three lines.

## 5. What is checked, and what is not

`installer/testing/check-os7-repo.py` builds the repository and then does the
only thing that can say whether it works: it takes a **plain `ubuntu:26.04`**,
points apt at the repository, and asks apt to make it an OS/7 machine. Every
claim is read back off the resulting filesystem — the modules are imported by
name, PowerShell is run, `os7-setup --self-test` is run out of its package,
`base-files` is reinstalled to see whether the branding survives, and
`os7-release` is removed to see whether the diversion comes back.

**The negative check is what makes the positive one mean anything.** The run ends
by swapping the trust anchor for a key that did not sign the repository, and
requiring apt to refuse — then putting the right key back and requiring the same
isolated update to succeed, so that "it refused" cannot be an artefact of the
isolation. A signature check that cannot be seen to fail is not a signature
check.

**Green on 2026-08-26, 45 checks, 0 failures, `1.0.0.119`, amd64.** The lines worth quoting:

```
ok  apt install os7-server succeeds
ok  os7-release owns /usr/lib/os-release by diversion
ok  the branding survived a base-files reinstall
ok  the machine is a plain Ubuntu again      (after removing os7-release)
ok  both modules import BY NAME at the release version — 1.0.0.119|1.0.0.119
ok  a login shell lands in PowerShell — 7.6.5
ok  os7-setup --self-test is clean — 146 ok, 0 failed
ok  apt update fails against a foreign signing key — exit 100
ok  while the same isolated update with the right key still succeeds — exit 0
```

**Not covered, and none of it accidentally:**

* **The ISO does not install these packages yet.** `build.sh` still stages the
  same files through `includes.chroot`. So this says the packages are correct,
  not that the image uses them. That switch is its own change, its own
  `check-image.py` run and its own 20-minute build.
* **Nothing here boots.** The units are installed and their enablement symlinks
  are checked as files; no systemd runs.
* **arm64 is unrun.** The builder is architecture-aware and `make repo-arm64`
  exists; nothing has built it, because this host is x86_64 and the arm64
  container would be emulated.
* **`os7-desktop` names OS/7's own desktop parts and not Microsoft's.** Edge,
  the Intune portal, the identity broker and VS Code come from
  `packages.microsoft.com`, which has no snapshot service, so they are pinned by
  version and hash in the release pin and installed by hook 0030 rather than
  depended on here. Putting them in the metapackage would make membership
  resolve against a repository OS/7 does not control — UL4 is the standing
  limitation and this does not change it.
* **The repository is signed by a development key** (see §2).

### `check-be-logic.py` does not run on this host, and it is not broken

Worth writing down, because the next session on the Windows box will see it fail
and reach for the module. It reports **20 failures**, all downstream of one:

```
Invoke-ZfsNative: The variable '$LASTEXITCODE' cannot be retrieved because
it has not been set.
```

Its fake `zfs` is a Python script with a shebang, and PowerShell on Windows does
not run one as a native command, so `$LASTEXITCODE` is never set. The same file,
same module, in an `ubuntu:26.04` container with `os7-powershell` installed:
**all checks passed.** `Test-ZfsModule` (75) and `Test-OS7Backup` (63) are green
in that container too.

### Two seams this leaves, named so they are not discovered later

**The PowerShell drop-in exists twice.** `/etc/profile.d/95-os7-powershell.sh`
is a heredoc inside hook 0050, which is how it reaches an ISO, and a file in
`build/packages/os7-powershell/`, which is how it reaches a machine through the
package. Two copies of five guards, each of which exists to avoid breaking
something specific, is the drift C7 exists to end. Until the ISO switches over,
`check-os7-repo.py` compares them and a difference is a failure rather than a
surprise on somebody's machine. Measured identical, 924 bytes each.

**And two files called `release.json`.**

`os7-release` ships `/usr/lib/os7/release.json` with the release facts — the
shape `Model/Release.cs` and `Get-OS7Version` read. Hook 0075 **also** writes a
`release.json`, and its version is a superset: it carries the package manifest
and the component versions **measured out of the built image**.

Two files, one name, two authors. Today they cannot collide, because the ISO
does not install `os7-release`. The day it does, one of them has to move — and
the honest split is the one C9 already implies: the *release* says what it is
(the package's file), and a *materialisation* says what it turned out to contain
(the hook's measurement). Recorded here rather than resolved, because resolving
it means touching the only build in this repository that produces a bootable
medium.

## 6. Next

1. **`Update-OS7`**, which is what all of this was for. §4.2 steps 1, 2 and 9
   are already real code (the boot-environment cmdlets, VM-proven); steps 3–8
   are the S5 harness's shell, and they now have a suite and a metapackage to
   point at. C10's step 6′ — migrations, keyed by the version being upgraded
   from — has a home in the descriptor and no implementation.
2. **`Get-OS7Release -Available`**, which reads the signed index. Without it
   `Update-OS7 -WhatIf` has nothing to report.
3. **Switch the ISO over**: build.sh stops staging into `includes.chroot`, the
   hooks become package installs, and the seam in §5 gets resolved. That is the
   change that makes `check-image.py` the check of a *packaged* system.
