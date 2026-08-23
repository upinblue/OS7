# Session S3 — ZFS-on-LUKS root, installed and booted

Answers `installer/SETUP-PLAN.md` **§10 Phase 0 spike S3**: *does a ZFS-on-LUKS
root install boot at all?* It is the spike that gated everything — the repo had
never installed OS/7 to a disk by any means.

**Date:** 2026-08-23 · **Method:** `out/os7-arm64.iso` booted in QEMU
(arm64/HVF) with a blank 40 GB virtio disk; a hand-written bash script does the
whole install from inside the live session; the VM is then powered off and
booted **from the disk alone**, with no ISO attached.

- The install sequence: [`installer/spikes/s3-zfs-luks.sh`](../installer/spikes/s3-zfs-luks.sh)
- The harness that drives it: [`installer/spikes/run-s3.py`](../installer/spikes/run-s3.py)

```bash
./installer/spikes/run-s3.py all
```

## Verdict

| Question | Answer |
|---|---|
| Does a LUKS2 → ZFS root install boot? | **Yes.** |
| Does it ask for the passphrase? | **Yes** — `Please unlock disk os7_root:` from the initramfs. |
| Does `/` come from `rpool/ROOT/os7_*`? | **Yes** — `findmnt -no SOURCE,FSTYPE /` → `rpool/ROOT/os7_2026.08.1_202608230935 zfs`. |
| Does the §4.4 dataset layout survive the boot intact? | **Yes** — every dataset lands on its designed mountpoint, `USERDATA` included. |
| **S3** | **PASS.** Phase 0's gate is open. |

What actually came back from the booted machine — one clean
`run-s3.py all`, blank disk to login prompt:

```
$ findmnt -no SOURCE,FSTYPE /
rpool/ROOT/os7_2026.08.1_202608230935 zfs

$ cat /proc/cmdline
BOOT_IMAGE=/BOOT/os7_2026.08.1_202608230935@/vmlinuz-7.0.0-30-generic \
  root=ZFS=rpool/ROOT/os7_2026.08.1_202608230935 ro boot=zfs \
  console=tty1 console=ttyAMA0,115200

$ zfs list -o name,mountpoint
NAME                                           MOUNTPOINT
bpool                                          /boot
bpool/BOOT                                     none
bpool/BOOT/os7_2026.08.1_202608230935          /boot
rpool                                          /
rpool/ROOT                                     none
rpool/ROOT/os7_2026.08.1_202608230935          /
rpool/ROOT/os7_2026.08.1_202608230935/var      /var
rpool/ROOT/os7_2026.08.1_202608230935/var/log  /var/log
rpool/USERDATA                                 none
rpool/USERDATA/os7_1doutq                      /home/os7
rpool/USERDATA/root_1doutq                     /root

$ zpool list
NAME    SIZE  ALLOC   FREE   FRAG    CAP  HEALTH  ALTROOT
bpool  1.88G   113M  1.76G     5%     5%  ONLINE  -
rpool    37G  2.67G  34.3G     0%     7%  ONLINE  -

$ lsblk -o NAME,TYPE,FSTYPE,SIZE
NAME         TYPE  FSTYPE       SIZE
zram0        disk  swap         2.9G
vda          disk                40G
|-vda1       part  vfat         512M
|-vda2       part  zfs_member     2G
`-vda3       part  crypto_LUKS 37.5G
  `-os7_root crypt zfs_member  37.5G
```

The `lsblk` tree is the whole D3 claim in five lines: an unencrypted FAT ESP, an
unencrypted `bpool` member, and everything else inside a `crypto_LUKS` container
whose `dm-crypt` mapping carries `rpool`. That is the shape Intune's
dm-crypt-only detection is documented to recognise (§4.5) — recognised in a real
enrolment is a separate question and still open (L18).

`zram0` is there too, so D4's swap works on the installed system without
anything non-ZFS landing on disk.

`USERDATA` is a sibling of `ROOT`, not a child — the one property in §4.4 that
cannot be retrofitted, and it is there.

The whole live root — 549 packages — occupies **2.67 GB** in `rpool` after
`lz4`, and `bpool` holds 113 MB of kernel and initrd.

## The nine things that had to be right

Every one of these is load-bearing. Some came from reading the image before a
line of the spike was written; the rest from the spike failing and being made to
say why.

### 1. `boot=zfs` is required, and nothing generates it

The single most important finding. Without it the machine drops to an initramfs
prompt, and nothing in the toolchain will put it there for you:

- `initramfs-tools`' `/init` defaults to `BOOT=local` and only ever sets `BOOT`
  from a `boot=` on the command line (plus one special case for NFS root).
- `/scripts/local` contains **no ZFS handling at all** — `grep -i zfs` finds
  nothing.
- The ZFS root logic lives in `/scripts/zfs`, whose own header says: *"Enable
  this by passing `boot=zfs` on the kernel command line."*
- `grub.d/10_linux_zfs` emits `root=ZFS="<dataset>" ro` and appends
  `$GRUB_CMDLINE_LINUX` — it does **not** add `boot=zfs`.

So `boot=zfs` has to come from `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, and
`os7-setup` must write it.

It also buys the LUKS ordering the handoff flagged as a risk: `/scripts/zfs`'s
`pre_mountroot()` runs `/scripts/local-top` **before** it imports anything, and
`local-top/cryptroot` is where the passphrase prompt comes from. The unlock
therefore always precedes the import. No sequencing work was needed.

### 2. `root=ZFS=` must *not* be pinned in `GRUB_CMDLINE_LINUX`

`10_linux_zfs` already emits one `root=ZFS=` per menu entry, one entry per boot
environment. Anything appended through `GRUB_CMDLINE_LINUX` lands *after* it on
the command line and therefore wins — so pinning a dataset there makes every
boot environment in the menu boot the same one. That is precisely the feature
the `rpool/ROOT/*` layout exists to provide.

The spike did this at first. It booted fine, which is what makes it dangerous.

### 3. `10_linux_zfs` works — OS/7 does not need its own generator yet

SETUP-PLAN **L4** assumes OS/7 must write a `grub.d` boot-environment generator
(~100 lines) because `zsys` was dropped. It may not have to: `grub-common` still
ships `/etc/grub.d/10_linux_zfs`, `10_linux` defers to it whenever it is
present, and on this layout it produced correct entries unassisted:

```
menuentry 'Ubuntu 26.04 LTS' ... {
    linux "/BOOT/os7_2026.08.1_202608230935@/vmlinuz-7.0.0-30-generic" \
      root=ZFS="rpool/ROOT/os7_2026.08.1_202608230935" ro boot=zfs ...
```

Two caveats before treating L4 as closed. It also emits zsys-era *"Revert system
only"* / *"Revert system and user data"* entries that OS/7 has no `zsys` to
serve, and it titles the menu from `/etc/os-release`, so the entry reads
**"Ubuntu 26.04 LTS"** and not OS/7 — `GRUB_DISTRIBUTOR` only reached the CSS
class (`--class os_7`). Branding the menu is now entangled with D8/L16, which
want `ID=ubuntu` kept for Intune.

The spike keeps a fallback that stands `10_linux_zfs` down and lets plain
`10_linux` generate the entries (it resolves a ZFS root by itself). It did not
need to fire.

### 4. The `initramfs` keyword in `/etc/crypttab`

`cryptsetup-initramfs` decides what to embed by resolving the root device. With
`root=ZFS=…` there is no device to resolve, so it would embed nothing and the
machine would stop at an initramfs prompt with no way to unlock `rpool`. The
`initramfs` option marks the entry for inclusion explicitly:

```
os7_root UUID=<luks-uuid> none luks,discard,initramfs
```

`CRYPTSETUP=y` in `/etc/cryptsetup-initramfs/conf-hook` is set as well.

### 5. The hostid goes in before the pools exist, not after

SETUP-PLAN **L13**. A pool records the hostid of whoever last imported it; if
the installed system's differs, it refuses to import and the boot ends in the
initramfs. The ordering that makes this safe is:

1. `zgenhostid` on the **live** system,
2. create the pools under that hostid,
3. copy that exact `/etc/hostid` into the target.

Doing it the other way round — `zgenhostid` into the target at the end, as the
handoff's step list suggested — stamps the pools with whatever the live system
happened to have.

### 6. `bpool` gets `-o compatibility=grub2`

GRUB reads only the read-only-compatible feature set (§4.2). ZFS ships the list
as `/usr/share/zfs/compatibility.d/grub2`, so `-o compatibility=grub2` tracks
GRUB instead of being a hand-maintained `-d -o feature@…` incantation that rots.
Note it excludes `zstd`, so `bpool` compresses with `lz4`.

### 7. `chpasswd` cannot work in the chroot

```
chpasswd: (user os7) pam_chauthtok() failed, error:
Failed preliminary check by password service
```

This image's `common-password` runs `pam_authd_exec.so`, and authd's helper
cannot work inside a chroot. Anything that sets a password **through PAM** will
fail there. `passwd -d` edits `/etc/shadow` directly and works; a real installer
should write the crypt hash directly for the same reason.

Related: the squashfs contains **no users at all** — casper creates the live
`ubuntu` account at boot, in the overlay, so none of it survives into an
install. An installer that forgets to create one produces a system that boots
perfectly to a login prompt nobody can get past.

### 8. The install root must not be `/mnt`

Whatever carries the installer is usually mounted at `/mnt` and is usually
read-only, so ZFS cannot create mountpoints underneath it:

```
cannot mount '/mnt/os7': failed to create mountpoint: Read-only file system
```

`/target`, as d-i and subiquity use, and a writability check in preflight.

### 9. The chroot's bind mounts need their own mount namespace

The last thing to fail, and the least obvious:

```
=== S3 10  export ===
cannot export 'rpool': pool is busy
```

— with **nothing whatsoever mounted under `/target`**, no process with a cwd or
root inside it, and `zpool export -f` failing exactly the same way.

`mount --make-private --rbind` — the incantation every ZFS-root guide uses —
makes the *new* mount private after the fact. By then it has already propagated
to every peer of the live system's shared root, including mount namespaces
belonging to systemd services. Unmounting in the installer's namespace leaves
live copies in theirs, and those hold the pool. `-f` does not help, because from
this namespace there is nothing left to force.

Doing the binds and the `chroot` inside `unshare --mount --propagation private`
fixes it at the source: nothing propagates out, and every mount disappears when
the namespace exits — there is no teardown left to get wrong. `zpool export`
then succeeds first time.

Worth carrying into Phase 2 verbatim. An installer that cannot cleanly export
the pool it just wrote has no safe way to say "done".

## Two smaller ones

**`grub-install` twice.** `--removable` writes `\EFI\BOOT\BOOTAA64.EFI`, which
is what firmware boots when NVRAM holds no entry for this disk — a cleared
CMOS, a disk moved between machines, a USB install. It needs no efivars, so the
spike does it first and treats it as the one that must succeed; the
`--bootloader-id=OS7` NVRAM entry is best effort. Both worked here, leaving
`/EFI/OS7/shimaa64.efi` + `grubaa64.efi` on the ESP — the shim chain S4 needs.

**Nothing leaked through the altroot.** The pools are created with `-R /target`
and their `zpool.cache` is copied into the installed system; the booted machine
shows `ALTROOT -` and every dataset on its real mountpoint. `/var`, `/var/log`,
`/home/os7` and `/root` all mounted without a `zfs-mount-generator` /
`zfs-list.cache` setup, on `canmount=on` plus `zfs-mount.service` alone.

## Driving the console — how the harness works, and why

`docs/HANDOFF.md` §5 says not to drive the boot over QEMU's serial console.
That advice is right about *typing*, and the harness works within it: it reads
freely, types one character at a time, and re-sends a step whose acknowledgement
never arrives rather than assuming it landed. Three things had to be solved.

**Enter is CR, not LF.** The console lands in PowerShell (hook 0050), and
PSReadLine puts the terminal in raw mode and reads *keys* — `\n` is not the
Enter key. Commands sent with `\n` accumulated into one line that was never
submitted, **while the echo of them still matched whatever the harness was
waiting for**. That produced a confident, wrong "pwsh executes commands".

**Terminal queries must be answered.** There is nothing on the far end of the
serial line but the harness, so every terminal query goes unanswered. agetty and
`login` shrug that off; PowerShell does not — with no reply to the DSR and OSC
probes PSReadLine makes at startup, the session ended within a second of the
prompt appearing and agetty respawned a fresh `login:`. Answering DSR, DA and
OSC 10/11 keeps it alive. **This is a product finding, not just a test-rig one:**
OS/7 ships PowerShell as its interactive shell and SETUP-PLAN §7 wants
`os7-setup --serial` on `ttyAMA0`.

**Answer the size probe honestly.** A program measures the terminal by parking
the cursor at 32766;32766 and asking where it landed. Replying `ESC[24;1R`
tells it the console is one column wide, and casper's `apt` step hangs there
forever. `ESC[24;80R`. The responder is also armed only once the login prompt
appears, so a wrong answer can never wedge the boot itself.

## The diagnostic rule bit again

BUILD-NOTES' rule — *a diagnostic must not depend on the subsystem it is
diagnosing* — has a sibling that cost a cycle here: **a diagnostic must be
checked against the thing it claims to check.**

The spike asserts that the generated initramfs really can unlock and import,
and it reported:

```
MISSING  conf/conf.d/cryptroot
```

The image was fine. `conf/conf.d/cryptroot` is the pre-2.x path;
`/lib/cryptsetup/functions` sets `TABFILE=/cryptroot/crypttab` at initramfs
stage, and that is the file `local-top/cryptroot` reads. The check now uses the
real path **and prints what the initramfs actually contains**, so a wrong
expectation shows up as a mismatch instead of a verdict.

That assertion is still the most valuable thing in the script. It is the
difference between "the boot failed" and "the boot failed *because the unlock
config never made it in*", and it costs seconds instead of a boot cycle.

## What this does NOT prove

| Not covered | Where it belongs |
|---|---|
| Secure Boot enabled, Microsoft keys | **S4.** The shim chain is on the ESP but was never enforced. |
| TPM2 auto-unlock (`systemd-cryptenroll`) | **S4**, together with "a TPM-less VM still boots via passphrase" (L17). |
| amd64 | Blocked on an amd64 ISO existing at all (HANDOFF §3). |
| Real hardware, real NVMe | Everything here is one virtio disk in QEMU. |
| Mirrors — one LUKS container per member disk | §4.5 names it; the spike does single-disk only. |
| Boot-environment rollback actually working | Datasets are laid out for it; nothing has cloned or activated a second BE. |
| `bpool` vs Intune's encryption check (L18) | Needs a real enrolment, not a VM. |
| Anything about the installed system beyond "it boots and logs in" | zram, TRIM reaching the device, `/var` ordering under load. |

The spike also leaves the `os7` account **passwordless** (`passwd -d`, which is
what casper does for the live user) so the harness can log in and check. That is
a spike affordance, not a pattern for Setup.

## Reproducing

```bash
./installer/spikes/run-s3.py probe     # console only; writes nothing
./installer/spikes/run-s3.py install   # blank disk -> installed system
./installer/spikes/run-s3.py boot      # boot from the disk alone and verify
./installer/spikes/run-s3.py all       # both, in order
./installer/spikes/run-s3.py reset     # discard the VM state
```

State and full serial logs land in `.vm/s3/` (gitignored). Passphrase:
`os7spike`. The install takes roughly 15 minutes on Apple Silicon, most of it
`unsquashfs`.
