# Phase 3 — the disk becomes a system

[../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §10 Phase 3:

> `unsquashfs` with real progress; chroot configuration (locale, timezone,
> hostname, users, `zgenhostid`, `update-initramfs`); bootloader install and the
> `grub.d` BE generator; screens 7–11; the GUI/headless split.
> *Deliverable: a machine installed by Setup boots into OS/7.*

**Date:** 2026-08-24.

Every phase before this one could be checked by reading the disk. This one
cannot. The deliverable is a sentence about a machine starting, and the only
evidence for it is a machine starting — from that disk, with nothing else
attached.

```bash
./installer/testing/run-phase3.py all      # install, then boot the disk alone
```

---

## What exists now

`os7-setup` runs fourteen steps, and the last five decide whether the result is
a computer:

| | |
|---|---|
| 1–5 | Phase 2's storage — partitions, ESP, LUKS2, pools, datasets |
| 6 | **`unsquashfs`**, with the real progress §3.1's screen 10 draws |
| 7 | hostid, `zpool.cache`, hostname, hosts, machine-id, crypttab, fstab, zram, locale, keymap, timezone |
| 8 | the release identity on the TARGET — `VARIANT`, with `ID`/`VERSION_ID` verified untouched |
| 9 | **the administrator account**, hashed outside PAM |
| 10 | GUI or headless, offline |
| 11 | **`update-initramfs`**, and the check that it can unlock and import |
| 12 | **TPM2 enrolment**, with the initramfs pieces S4 proved |
| 13 | **the bootloader**, and the check that its menu resolves a boot environment |
| 14 | teardown — unmount, export, and ask whether anything is still imported |

Screens 7 (account) and 8 (GUI/headless) are new. Screens 10 and 11 are ONE
screen object, and the reason is mechanical rather than a shortcut: they are
separate to look at — the first has a filename moving under the bar, the second
does not — but they are one Executor run on one worker thread, and a second
Screen would have to attach to a thread already in flight and hand the rollback
list between them. The heading follows the step instead.

Screen 12 now offers a restart, which is the first time it honestly could. It is
allowed to say "complete" only because InitramfsStep checked the startup image
can unlock and import, and BootloaderStep checked the menu resolves a boot
environment.

---

## The decision that shaped all of it: the target root is a parameter

`TargetRoot`, and every Phase 3 step takes one. None of them reaches for
`StorageSteps.Target`.

That is not a refactoring. RELEASE-AND-UPDATE-PLAN §4.2 describes `Update-OS7`
as this same sequence from step 3 onwards, run against a **cloned boot
environment mounted somewhere else** — "everything from 3 onward is S3 code with
a different root". SETUP-PLAN §6.3 already routes the ZFS work through the OS7
module for the same reason.

Phase 3 was the last moment at which the root could be made a parameter for
free. Hard-coding `/target` would have meant writing every chroot step a second
time for the update path, and re-validating all of Phase 3 to do it.

`TargetRoot` also owns the chroot runner, and with it BUILD-NOTES #18: the bind
mounts and the `chroot` happen inside `unshare --mount --propagation private`,
because the incantation every ZFS-root guide uses makes the mount private *after*
it has already propagated to every peer of the live system's shared root — and
the pool then will not export, with nothing visible under the target and `-f`
powerless.

---

## The password could not go through PAM, and now does not

BUILD-NOTES #17 recorded that `chpasswd` cannot work in this image's chroot.
Confirmed in the shipped image on 2026-08-24, in
`/etc/pam.d/common-password` line 25:

```
password [success=2 …] pam_authd_exec.so /usr/libexec/authd-pam
```

Spike S3 worked around it with `passwd -d` — an **empty password** — and said in
its own comments that a real installer must write the hash instead.

It now does. The hash is made on the **live** system, where PAM is not involved,
and handed to `useradd -p`:

```
printf '%s' "$password" | openssl passwd -6 -stdin
```

Three things measured before choosing that:

* **`openssl` is in the image.** So is `perl`.
* **`python3`'s `crypt` module is not** — removed from the standard library in
  Python 3.13, and the image ships 3.14. The obvious alternative was not one.
* **pam_unix defaults new passwords to yescrypt** in this image. That is about
  what it *generates*; it verifies whatever the shadow entry holds, and `$6$`
  SHA-512 is accepted.

`-stdin`, so the password is never in argv and therefore never in `ps` output or
in the log Setup offers to export to removable media. `Executor.ExecSecret` logs
the command line and not the input.

---

## Four bugs found by reading the generated bash, not by running it

The chroot scripts are C# interpolated raw strings. Two layers of quoting sit
between what is written and what `bash` sees, and both can produce a script that
**compiles fine** and fails halfway through an install.

`--dry-run` writes every script it would run into the log. Reading them found:

1. **A `/etc/shadow` check that would have failed every install.** Written as
   `grep -q "^$user:\$"`, the shell ate the `$` and the pattern became *"the line
   ends after the colon"* — which matches an account with an **empty** password
   and fails on a correct one. Replaced with `grep | cut`, which reads the field
   instead of matching a pattern against it.
2. **`{` collides with C# interpolation.** `awk '{print $2}'` and `${#HASH}` do
   not compile inside `$"""…"""`, and the error points at C# rather than at the
   shell. The script now uses no shell braces at all — and neither do its
   comments, because the first attempt at explaining this rule broke the build by
   containing the characters it was about.
3. **`systemd-cryptenroll --unlock-key-file=/dev/stdin` with a redirect**, where
   a plain path works.
4. **`[ -f /boot/efi/EFI/BOOT/BOOT*.EFI ]`** — with more than one match, `test`
   gets several arguments and complains about them instead of answering.

Then every generated script was run through `bash -n`. All five pass, and that
check is now part of `check-image.py`: it asks the **shipped** binary for its
scripts with `--dry-run` and syntax-checks them against **the image's own bash**.

---

## One VM cycle lost to something obvious — BUILD-NOTES #41

The first Phase 3 run failed with "the install did not finish". The serial log
said:

```
os7-setup: unknown option '--password-file'
Phase 2: from the Confirm screen onwards this WRITES TO A DISK.
```

**The VM harnesses test the ISO's `os7-setup`, not the source tree's.** The
binary is compiled by `build/build.sh` and baked into the squashfs; editing
`installer/src/` changes nothing a harness can see until `make build-arm64` runs
again. Obvious once stated, and easy to lose because the source-level loop is
seconds and the ISO loop is twenty-five minutes.

The harness's own reporting was worse than the bug: it printed the verdict and
nothing else, so the one-line cause had to be found by reading a serial log by
hand. It now prints the last 25 lines the guest produced, and names this specific
cause when it sees `unknown option`.

---

## The deliverable, met

```
  boot — the installed disk, with nothing else attached
      ok    1/8 GRUB, the kernel and the initramfs all ran
      ok    2/8 the pool imported and / was mounted
      ok    3/8 a login prompt
      ok    4/8 os7admin logged in with the password Setup set
      ok    5/8 / is rpool/ROOT/os7_1.0.0.33_…
      ok    6/8 IMAGE_VERSION is 1.0.0.33
      ok    7/8 ID and VERSION_ID are untouched (Intune, L16)
      ok         VARIANT_ID=server (the headless install)
      ok    8/8 the computer is called os7-phase3
      ok         boot=zfs is on the kernel command line
```

A VM with **no ISO attached**, booting the disk `os7-setup` installed. What it
says about itself:

```
rpool/ROOT/os7_1.0.0.33_202608241802 zfs
PRETTY_NAME="OS/7 1.0.0.33"
NAME="OS/7"
ID=ubuntu
VERSION_ID="26.04"
IMAGE_ID="os7"
IMAGE_VERSION="1.0.0.33"
VARIANT="Server"
os7-phase3
BOOT_IMAGE=/BOOT/os7_1.0.0.33_202608241802@/vmlinuz-7.0.0-30-generic
  root=ZFS=rpool/ROOT/os7_1.0.0.33_202608241802 ro boot=zfs
```

Four of those lines are worth more than the rest:

* **`os7admin` logged in.** BUILD-NOTES #17 is closed: the hash `openssl` made on
  the live system, written by `useradd -p`, is one PAM accepts on a real login.
  Nothing before this could have told the difference between a correct hash and a
  plausible one.
* **`IMAGE_VERSION` on the disk equals the version on the medium**, while `ID` and
  `VERSION_ID` are exactly what Intune's "Allowed distributions" rule expects.
  D8's claim — that the product can be identifiable as itself without touching a
  field Intune matches on — is now true of an installed machine and not only of
  an image.
* **`VARIANT="Server"`.** The image says what it *could* be; ReleaseIdentityStep
  wrote what it *is*.
* **`boot=zfs`.** BUILD-NOTES #15, the finding that decides whether any of this
  boots, present on a command line generated by `update-grub` rather than by hand.

---

## The bug the boot could not have found — BUILD-NOTES #42

The same run reported a finished install **and left `rpool` imported.**

The teardown exported `rpool` and then `bpool`. `bpool` is mounted at
`<target>/boot`, inside rpool's tree, so rpool could never export while it was
there — and `zpool export` had returned non-zero into a `TryExec` that ignores
failure, so nothing said so.

**It boots anyway.** The installed system carries the same `/etc/hostid` the
pools were created with (L13), so it imports them regardless — which is exactly
why this is worth writing down. A check that asked only *does it boot* would have
passed, twice, on a machine whose last act of installation had silently failed.

The step now follows S3's order — `sync`, unmount the ESP, `umount -R`,
`zfs umount -a`, **bpool then rpool**, `cryptsetup close` — and afterwards asks
`zpool list` whether anything is left, rather than trusting the exit code of the
command that was supposed to change it.

---

## What is deliberately not here

**Screen 9, the network screen.** DHCP is the default on a fresh install and a
machine that boots can be configured from a shell; a machine that does not boot
cannot be configured at all. So the deliverable does not depend on it. It is
owed rather than dropped — a headless server that comes up with no network is a
site visit, which is the release plan's own argument for keeping
`/var/lib/NetworkManager` outside the boot environment (§4.4).

**TPM2 enrolment is best-effort by design.** A machine with no TPM, a TPM the
firmware hides, or a PCR set that will not seal must still finish installing and
still boot — on the passphrase, which is intact either way. Spike S6 measured
what a broken seal looks like and it is benign: `cryptsetup` names the cause and
the passphrase path works. **U8 — the escrowed recovery passphrase that
unattended re-enrolment needs — is untouched**, and the layout screen still says
so where the operator can act on it.

**amd64 remains unbuilt**, so the GUI half of screen 8 and `InstallModeStep`'s
desktop-removal branch have never run. Both are written; neither is evidence.
