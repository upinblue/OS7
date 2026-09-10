# Session — the machine with no journal: journald flushes onto the wrong dataset, and zfs mount -a buries it

**2026-08-28, on the x64 Windows host**, in a worktree fast-forwarded to the
update-train branch (`3befe71`). The starting point is
[SESSION-UPDATE-DELIVERY.md](SESSION-UPDATE-DELIVERY.md) §6: the installed
amd64 machine has NO systemd journal at all — `journalctl` says "No journal
files were found" on a running machine whose journald reads active, whose
/etc/machine-id is populated, and where BOTH `/run/log/journal` and
`/var/log/journal` exist and are empty. Storage= is at its commented default,
no drop-in anywhere. The #104 diagnosis paid for this directly: when it needed
"who touched boot-efi.mount", there was no journal on any boot to ask.

The defect is diagnosed, fixed with one line of systemd configuration, and the
fix is verified on a booted machine. It is BUILD-NOTES **#109**, and it is the
**third symptom of #104's root cause** — this image ships no
`/etc/zfs/zfs-list.cache`, so `zfs-mount-generator` emits no mount units and
nothing in systemd's ordering graph knows that `/var/log` is a filesystem.

---

## 1. What the image says (the squashfs, #93's authority)

Mounted out of `OS7-1.0.0.134-amd64.iso`, the ISO the defect was reported
against:

* `/var/log/journal` EXISTS in the image (empty, root:systemd-journal 2755) —
  so journald's default `Storage=auto` behaves as persistent-once-flushed.
* `journald.conf` carries nothing but the `[Journal]` section header. No
  drop-in directory exists — /etc, /usr/lib or /run. No mask, no override of
  `systemd-journald.service` or `systemd-journal-flush.service`. The journald
  binary is the real one.
* `systemd-journal-flush.service` as shipped is `DefaultDependencies=no`,
  `After=systemd-remount-fs.service`, `Before=systemd-tmpfiles-setup.service`,
  `RequiresMountsFor=/var/log/journal`.
* `/etc/zfs/zfs-list.cache` does not exist — not even as an empty directory —
  and the generator list confirms `zfs-mount-generator` is present and
  therefore emits nothing every boot.

That last pair is the whole defect. `RequiresMountsFor=/var/log/journal` is
upstream's own guard against exactly this failure, and it orders against
NOTHING here: there is no unit whose path covers /var/log, so the dependency
is satisfied by `-.mount` (the root filesystem) and the flush is free to run
the moment journald is up.

## 2. The dataset layout makes the miss expensive

`New-OS7Storage` puts `/var/log` on `rpool/DATA/log`, deliberately OUTSIDE the
boot environment (SETUP-PLAN §4.4: the log explaining a failed update must not
vanish with the update). Datasets outside the BE are mounted by
`zfs-mount.service` (`zfs mount -a`), which runs after
`systemd-udev-settle.service`, `zfs-load-module.service` and
`zfs-import.target`. The initramfs mounts only the BE's OWN child datasets
(var/cache, var/lib/apt, var/lib/dpkg — visible in every boot's serial log);
`rpool/DATA/log` waits for zfs-mount.service, seconds later.

So on every boot there is a window in which `/var/log` is a plain directory on
the BE's root dataset, and the journal flush lands inside that window.

## 3. The mechanism, measured on serial consoles

The gate run of 2026-08-28 (a 1.0.0.136 machine, `.vm/s5/*.serial.log`) shows
the order without needing a journal to ask:

* Every boot: `systemd-journald` starts → "Received client request to flush
  runtime journal" → `Finished systemd-journal-flush.service` → **then**
  `Starting zfs-mount.service`. The race is lost in the same direction every
  time — journald and the flush complete ~0.2 s after journald starts, while
  zfs-mount waits for the ZFS import chain.
* Two boots say where the flush went: `cycle-2` (first boot of the clone) and
  `update-1` both print, BEFORE zfs-mount starts,

      systemd-journald[502]: File /var/log/journal/96175bbda74e493c9a662768328df5cb/system.journal
      corrupted or uncleanly shut down, renaming and replacing.

  A persistent journal for this machine-id EXISTS on the boot environment's
  root dataset — the flush had been writing there on the boots before. (Why
  those two boots found it UNCLEAN is §4's clone finding: a snapshot taken
  while the shadowed journal is online captures a file that was never closed.)

So the sequence, every boot: journald opens the runtime journal in
`/run/log/journal/<id>`; the flush runs with `/var/log` still the BE root's
directory, opens `/var/log/journal/<id>/system.journal` THERE, moves the
runtime entries into it and deletes `/run/log/journal/<id>`; zfs-mount then
mounts `rpool/DATA/log` over `/var/log`. Both visible journal roots are now
empty — the dataset's `journal/` is the image's empty one, the runtime one was
consumed by the flush — while journald keeps writing through its open
descriptors into a directory no path reaches. `systemctl is-active` says
active because journald IS active. Nothing errors, because nothing is wrong at
the layer each tool checks: the mount table is consistent, journald's writes
succeed, journalctl correctly reports the (visible) roots empty.

## 4. Measured on the machine this session installed

A fresh machine was installed from `OS7-1.0.0.134-amd64.iso` — the ISO the
defect was reported against — with run-s5.py's own machinery under a separate
lab name (`.vm/jrnl`, container os7vm-jrnl), so the concurrent gate run's VM
was never touched. All 17 Setup steps completed; the probes ran as root on the
booted machine.

**Boot 1** (the machine's first boot, machine-id `33c727d2…`):

* `journalctl` and `journalctl --header`: "No journal files were found" — the
  defect reproduces on the FIRST boot; nothing in the machine's later life is
  needed.
* Unit order, from systemd's own monotonic timestamps (µs):
  journald **8 096 496** → journal-flush finished **8 241 123**
  (ExecMainStatus 0, Result success) → zfs-load-module 9 059 084 →
  zfs-import-cache 9 256 418 → **zfs-mount 9 350 961** →
  tmpfiles-setup 9 441 970. The flush beat the /var/log mount by 1.1 s.
* journald's own file descriptor:
  `23 -> /var/log/journal/33c727d2…/system.journal` — and a bind mount of `/`
  (the BE root dataset, unshadowed) shows that file: **8 MiB, mtime this
  minute, being written** — while the visible /var/log/journal (the dataset;
  its mtime is the image build's) is empty and /run/log/journal is an empty
  directory with the flushed flag set.
* The BE root's `/var/log` contains ONLY `journal/`, created at THIS boot's
  8-second mark: **journald's flush creates the whole
  /var/log/journal/<machine-id> chain itself**, `Storage=auto`
  notwithstanding, so the defect needs no helper to provide the directory.
* `rpool/DATA/log` has `overlay=on` (the OpenZFS default), which is why
  mounting over the now-non-empty directory succeeds in silence.
* The one place the machine says anything at all is dmesg:
  `systemd-journald: Failed to open user journal file, falling back to system
  journal: No such file or directory` — journald opening user-*.journal BY
  PATH against the visible (empty) dataset directory, ~19 s after the flush
  had populated the hidden one. A cryptic line, in the one log that still
  exists precisely because it is not journald's.
* Same mount namespace as PID 1, real journald binary, no AppArmor denials —
  the replaced/masked/confined theories are all dead.

**Boot 2**, passive: the identical picture. Flush finished at 8 649 567 µs,
zfs-mount at 10 010 684 µs — 1.36 s apart, same direction; journalctl empty;
journald's fd on a fresh shadowed system.journal (the BE root's journal tree
GREW between the boots — boot 1's file is still under there); /run and the
dataset both empty. The flush re-uses boot 1's shadowed file silently — no
"corrupted or uncleanly shut down" appeared on this machine's boots, because
its shutdowns were clean and the var-log unmount at shutdown never touches
journald's descriptors, which point into the BE root. The gate machine's
corrupted-journal lines (cycle-2, update-1) came from its clone-and-activate
history — a `zfs snapshot` of a boot environment whose shadowed journal is
ONLINE captures a file that is, by definition, uncleanly shut down — which is
also how that machine's clones each inherited a journal tree on their root
dataset.

**Boot 2, the active experiment** — the diagnosis's own control:
`systemctl restart systemd-journald`, with /var/log now properly mounted and
the flushed flag standing, made journald open the DATASET's /var/log/journal:
`journalctl --header` showed a real file (State: ONLINE) at the visible path
for the first time in the machine's life, `/var/log/journal/<id>/` appeared on
rpool/DATA/log with root:systemd-journal 2755 and the ACLs, and a `logger`
marker came back out of `journalctl -b`. Ordering is the WHOLE defect: the
same journald, the same config and the same filesystems work the moment the
mount is there before the open.

## 5. The fix, and where it lives

One drop-in, shipped by os7-release:

    /usr/lib/systemd/system/systemd-journal-flush.service.d/os7.conf
    [Unit]
    After=zfs-mount.service

Ordering only — no Wants=, so a machine without the job (the flush unit runs
on the live medium too) is unaffected; and no new critical-path work, because
`zfs-mount.service` is already `Before=local-fs.target` and
`systemd-tmpfiles-setup.service` (which the flush precedes) is already
`After=local-fs.target` — the drop-in inserts the flush into a chain both ends
of which exist. There is no cycle to build.

With the flush ordered after zfs-mount, journald's runtime journal holds every
early-boot message until `/var/log` is the real dataset, and the flush then
moves them where journalctl looks. Nothing is lost in the reordering — that
is what the runtime journal is for.

Delivery:

* `build/packages/os7-release/tree/.../systemd-journal-flush.service.d/os7.conf`
  — arrives on the ISO through hook 0022 like every os7-release file, and on
  installed machines through the first update that carries it (the new boot
  environment's /usr has it; the old environment keeps the old behaviour,
  which is what a rollback means).
* `build/lib/build-os7-packages.sh` asserts its mode like every tree file.
* `check-image.py` now reads the drop-in out of the shipped squashfs and
  requires `After=zfs-mount.service` — the guard against the package losing
  the file.

**Verified on the machine, mechanism first.** The drop-in was written to the
installed machine's /etc (the twin of the shipped /usr/lib file — same unit,
same semantics) and the machine rebooted. The boot after it, from systemd's
monotonic clock: journald 8 066 697 µs → zfs-load-module 9 271 167 →
zfs-import-cache 9 487 487 → **zfs-mount 9 560 361 → journal-flush
9 742 342** → tmpfiles-setup 9 798 402. The order flipped, and
tmpfiles-setup landed at the same ~9.8 s it always had — the drop-in added no
measurable boot time, exactly as the no-new-edges argument predicts.
`journalctl --header` shows ONLINE journal files at the visible path,
`journalctl -b` returns entries, journald's descriptors point at
`rpool/DATA/log`'s files — the user journal too, so the dmesg ENOENT lines
are gone. The boots before the fix left ~8 MiB of shadowed journal on the BE
root dataset; it stays there, inert and invisible, and is noted rather than
cleaned (§6).

**The shipped form's own gate, run to the end.** An amd64 ISO was built from
this tree (OS7-1.0.0.136, this worktree's out/), `check-image.py` came back
green on it — 105 ok, 0 FAIL, among them the new "the journal flush is
ordered after zfs-mount.service (#109)", read out of the shipped squashfs —
and a
machine was installed from it and booted. Its FIRST boot, nothing done by
hand (machine-id `afad2646…`):

* `journalctl --header`: State ONLINE at the visible
  `/var/log/journal/<id>/system.journal`; `journalctl -b` returns entries.
* Order, monotonic µs: journald 9 643 666 → zfs-load-module 10 690 583 →
  zfs-import-cache 10 878 656 → **zfs-mount 10 954 930 → journal-flush
  11 098 096** → tmpfiles-setup 11 819 592. The shipped /usr/lib drop-in did
  it — this machine never carried the /etc twin.
* journald's descriptors: system.journal AND user-1000.journal, both on
  `rpool/DATA/log`.
* Under a bind mount of `/`: the boot environment's root dataset has **no
  /var/log/journal at all** — the wrong dataset was never written, not once.

The machine that proves the fix and the machine that measured the defect are
two fresh installs of the same lab, five boots apart.

## 6. What was expressly NOT done

* **zfs-list.cache stays absent.** The structural fix — give systemd real
  mount units for every ZFS dataset by shipping `/etc/zfs/zfs-list.cache` and
  the ZED cacher — would have made upstream's `RequiresMountsFor` work as
  designed, ordered boot-efi.mount without #104's fstab option, and covered
  every future early-boot consumer of a DATA dataset. It is the right long
  answer and it touches the initramfs, ZED, Setup and the update assembler at
  once; this session fixed the one measured consumer the way #104 fixed the
  ESP, and leaves the cache as an open question beside it.
* **No arm64 measurement.** The mechanism is architecture-independent (same
  units, same layout), the fix ships on both, but every number above is from
  amd64 VMs; the Mac owes the arm64 confirmation whenever run-s5 next runs
  there.
* **Shutdown-path ordering** was not separately proven: with the drop-in, the
  flush's ExecStop (`--smart-relinquish-var`) now stops before zfs-mount
  unmounts /var/log, which should end the "corrupted or uncleanly shut down"
  line on the following boot — observed gone on the verify boot, but one boot
  is an observation, not a claim about every shutdown.
