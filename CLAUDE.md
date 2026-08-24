# Working on OS/7

OS/7 is a Microsoft-admin-friendly Linux built on Ubuntu 26.04 LTS: PowerShell as
the interactive shell, Entra ID / Intune / Azure Arc as the management path, ZFS
root with rollback-safe updates, and an OS/7-authored text-mode installer styled
after MS-DOS 6.22 Setup and the Windows 2000 text phase.

Everything runs **locally on an Apple Silicon Mac**. No cloud, no CI, no paid
services. Builds are Docker; VMs are QEMU.

---

## Where authority lives

Do not decide something these files have already decided. Do not restate them
here either — this file points, they rule.

| Question | The file that answers it |
|---|---|
| What is locked, what is still open | [README.md](README.md) — "Locked decisions" and "Open questions" |
| The installer: design, screens, decisions D1–D10, limitations L1–L22, phases | [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md) — **authoritative** |
| Versioning, the update train, rollback, `/var` | [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) |
| What works today and what to do next | [docs/HANDOFF.md](docs/HANDOFF.md) — **read this first** |
| Every trap found so far, numbered | [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) — **read before debugging** |
| What a past session actually measured | `docs/SESSION-*.md` |

**Intune's constraints outrank OS/7's technical preferences** wherever the two
collide (README, "Intune compatibility is a hard requirement"). Anything touching
disk layout, encryption, OS identity, desktop or browser gets checked against
Microsoft's live docs *first*.

---

## The commands that work

```bash
make build-arm64                          # the ISO. ~5 min. Docker, privileged.
make build-amd64                          # x86_64 hosts only - refuses elsewhere
make build-amd64-vm                       # on Apple Silicon: a QEMU x86 VM, hours

./installer/testing/run-phase1.py all     # walk os7-setup in a VM and check it
./installer/spikes/run-s1.py all          # the look: palette, font, glyphs, keys
./installer/spikes/run-s3.py all          # install to a disk and boot from it
./installer/spikes/run-s4.py all          # Secure Boot + TPM2 unlock (budget 1h)
./installer/spikes/run-s6.py all          # TPM2 unlock across an update
```

Building `os7-setup` alone, without an ISO:

```bash
docker run --rm --platform linux/arm64 -v "$PWD":/work os7-build:arm64 bash -c \
  'cd /work/installer/src/OS7.Setup && dotnet publish -c Release -r linux-arm64 \
   -p:PublishAot=true -o /tmp/pub && /tmp/pub/os7-setup --self-test'
```

`--self-test` is the first thing to run when anything about Setup looks wrong. It
also runs **inside the chroot during the ISO build** (hook 0080), so a missing
font or palette fails the build rather than a boot.

---

## How work is done here

This is not a style preference; the repo is built on it and the docs assume it.

**Measure, do not assert.** Every claim in `docs/` has a number behind it and
says how it was obtained. When a session finds something, it writes a
`docs/SESSION-*.md` with what was measured, what was *not*, and what it changes
in the plan. Commit messages are long-form: what was found, what it means, what
it changed.

**A diagnostic must not depend on the subsystem it is diagnosing**, and **a
diagnostic must be checked against the thing it claims to check.** Both rules are
in BUILD-NOTES because both were learned by getting a confident, wrong answer.
The recurring shape of the expensive bugs in this repo is: *a program reported
success and the thing it was meant to change did not change.* An exit code is a
diagnostic. So is a log line. Ask the thing itself.

**Spikes are evidence, not templates.** `installer/spikes/` records what was
done and what it taught. Do not "fix" a spike to match a later decision —
`s3-zfs-luks.sh` predates D10 and is meant to.

**Non-destructive until the phase says otherwise.** `os7-setup` is at Phase 1 and
opens no block device. Screen 12 says so on the screen.

---

## The traps that cost the most

Full list and evidence in [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md). These are
the ones a fresh session hits first.

- **#13 — hooks must be at `config/hooks/*.chroot`, FLAT.** Wrong layout and
  live-build runs nothing, prints "Begin executing hooks…", and **exits 0**.
  Never conclude a hook ran because the build succeeded.
- **#12 / #23 — amd64 ISOs cannot be built on Apple Silicon** (ENOSYS in
  debootstrap's tar under Docker emulation), but amd64 **.NET binaries can**. Do
  not generalise the first into the second.
- **#15 — a ZFS root needs `boot=zfs` on the kernel command line**, and nothing
  generates it for you.
- **#16 — driving a serial console:** Enter is `\r`; an unanswered terminal query
  kills PowerShell; and never expect a marker the typed command itself contains,
  or the shell's echo reports success for a command that never ran.
- **#25 — Ubuntu's `setvtrgb.service` replaces the console palette** set on the
  kernel command line, before anything is ever displayed and without an error.
  Ship `/etc/vtrgb` or apply it yourself.
- **#31 — fbcon DEFERS taking the console over** and completes it only when
  something *writes*. Until then tty1 is the dummy device and `KDFONTOP` returns
  ENOSYS. `fbcon=nodefer`.
- **#33 — `Conflicts=` is resolved when systemd builds the transaction;
  `Condition…=` when the job runs.** An enabled unit with a failing condition has
  already conflicted its target away.

---

## Repository layout

```
build/                      the ISO: live-build config, hooks, and build.sh
  config/auto/config        live-build configuration (DISTRIBUTION=resolute)
  config/hooks/             common hooks, FLAT (trap #13); hooks-amd64/ for x86
  config/package-lists/     common; -amd64/ and -arm64/ for the split
  config/includes.chroot/   files copied verbatim into the image
  lib/build-console-font.sh Fixedsys TTF -> two PSFs, coverage and shape asserted
  lib/psf.py                the font subset table, the fixes, and the guard
  lib/palette.py            the palette, and D5's contrast check
  lib/arm64-efi-remaster.sh arm64 has no live-build bootloader; this fixes it,
                            and owns the ISO's GRUB menu
installer/
  SETUP-PLAN.md             the installer design. Authoritative.
  src/OS7.Setup/            os7-setup itself
  assets/                   the systemd unit
  spikes/                   Phase 0 spikes: evidence, not templates
  testing/                  the VM harness: vmconsole (serial), vmscreen
                            (framebuffer, QMP, reading the screen back through
                            the console font), run-phase1.py
powershell/OS7/             the OS7 module - ONE source, staged by build.sh
docs/                       plans, handoff, build notes, session results
out/, .vm/                  artefacts and VM state. Both gitignored.
```

**arm64 and amd64 are different products** (README): arm64 is server-only — no
GNOME, no Edge, no Intune — because Microsoft ships no arm64 desktop stack.
Everything proven so far is **arm64 only**; no amd64 ISO has ever been built.
