# Session — the backup feature

**2026-08-25 → 2026-08-26.** Designed and built OS/7's backup feature on `sanoid`
and `syncoid`. What was measured, what was not, and what it changes.

Run from **Windows 11**, which decided the shape of the result more than any
other single fact: there is no QEMU/hvf here, so every harness in
`installer/testing/` that boots a machine was unavailable. Everything below was
therefore built to be checkable *without* one — and the thing that would prove it
on a machine was written and left unrun, rather than claimed.

---

## 1. What this session did

| | |
|---|---|
| Design | [BACKUP-PLAN.md](BACKUP-PLAN.md) — B1–B15, BL1–BL10, the measurements |
| Code | 17 cmdlets in `powershell/OS7/OS7.Backup*.ps1` |
| Generic layer | Z14 in `powershell/Zfs` — `-ComputerName` reads, `Clear-ZpoolLabel` |
| Image | `sanoid` + `procps` in the package list, three units, hook 0090, `release.json` |
| Tests | `Test-OS7Backup` (63 checks, green), `run-backup.py` (**never run**) |
| Findings | BUILD-NOTES #73, #74, #75, #76; DECISIONS open question 8 |

---

## 2. What was measured

Everything here was obtained on this machine and is reproducible from it.

**M-B1 — the package is in the pin, and so is everything it needs.** Fetched
`sanoid_2.3.0-1_all.deb` from
`snapshot.ubuntu.com/ubuntu/20260824T000000Z/pool/universe/s/sanoid/` and hashed
it: 56 770 bytes, SHA256 `24bc2809f01eab894383b5a8a09f6346a9ad19280268928c167e04a4ae1d603d`.
Its five dependencies resolve from the same snapshot's `main` and `universe`
indexes — `pv 1.10.3-1`, `lzop 1.04-2build4`, `mbuffer 20251025+ds1-1`,
`libconfig-inifiles-perl 3.000003-4build1`, `libcapture-tiny-perl 0.50-1`.
≈357 KB downloaded, ≈1.1 MB installed. `perl` is already in the image, checked
against `out/OS7-1.0.0.95-amd64.packages.manifest` — which also shows `rsync`,
`openssh-client`, `cryptsetup`, `gdisk` and `acl` present, and **`attr` absent**
(so nothing on the image can `getfattr` a restored file to verify its xattrs).

**M-B2 — what is actually in the package.** No `dpkg-deb` on this host and the
archive member is zstd-compressed, so it was extracted with a hand-written `ar`
reader plus `zstandard`. Three programs in `/usr/sbin`, three systemd units, one
`cron.d` conffile that disables itself under systemd, `sanoid.defaults.conf` —
**and no `/etc/sanoid/sanoid.conf` and no `/etc/sanoid` directory at all.** The
postinst enables *and starts* `sanoid.timer` unconditionally.

**M-B3 — sanoid cannot reach a boot environment**, by two independent filters.
`getsnaps()` writes into `%snaps` only for names matching `/^autosnap/`
(`sanoid:914`), and only for lines matching `@(.*ly)` (`:909`); the pruner reads
nothing else and is scoped to configured sections (`:325`, `:797`). OS/7's boot
environments are `os7_<release>_<yyyyMMddHHmm>` and fail both. This is the
measurement B7 rests on, and it is why `Assert-OS7DatasetSafe` is the *second*
line of defence rather than the only one. The route that defeats both is
`recursive = zfs`, which runs `zfs snapshot -r` over a whole subtree including
datasets sanoid has no section for (`:669`) — OS/7 never emits it, and the
self-test asserts that.

**M-B4 — the five-hour monitor cache.** `sanoid:69-85`: given only `--monitor-*`,
`$cacheTTL` becomes 18000. A status verb built on `sanoid --monitor-snapshots`
would be reading a file, not a pool. This single fact decided §8 of the plan.

**M-B5 — `/home/<user>` is not where the layout says.** `New-OS7Storage`'s
`-UserName` defaults to `os7`; `os7-setup`'s `New-OS7Storage` command string
carries `-Root`, `-RootDevice`, `-BootDevice`, `-BootEnvironment` and nothing
else; `run-phase3.py` installs the account `os7admin`. So the one machine this
repository has booted has an empty dataset at `/home/os7` and its real home
inside the boot environment. BUILD-NOTES #74, DECISIONS open question 8.

**M-B6 — both self-tests are green on this machine**, under the same PowerShell
7.6.5 the image ships:

```
Zfs self-test:        75 passed, 0 failed
OS/7 Backup self-test: 63 passed, 0 failed
Z1 (check-layering.py): 0 direct invocation(s); baseline 0
```

**M-B7 — every changed file is LF.** `tr -dc '\r' < f | wc -c` is 0 for all 22,
checked the way BUILD-NOTES #70 says to check it (not with `sed`, which strips CR
silently on this host and would have agreed with a broken tree).

---

## 3. What was NOT measured, and must be

Everything about how sanoid and syncoid **behave**. Every statement in this
session about those two programs comes from reading their perl. No snapshot has
been taken, no stream has been sent, and no file has been restored by this code
on any machine.

`installer/testing/run-backup.py` is what would change that, and it has never
executed. It is `qemu-system-aarch64 -machine virt,accel=hvf`, like every other
harness here, so it needs the Apple Silicon host.

Also unmeasured, and listed here so they are not mistaken for design:

* whether `.zfs/snapshot` is traversable by explicit path when `snapdir=hidden`,
  which is what the whole restore path assumes (BL9). `Get-OS7FileVersion` is
  written to *say so* if it turns out to be false, rather than reporting "no
  versions";
* whether `zfs receive -u` plus a `mountpoint=none` target pool is enough to keep
  a received copy of `/home/...` from mounting over the live one — both were
  chosen for that reason, and only a machine can confirm it;
* what the units do on a real boot. `systemctl show` was never run against them.

---

## 4. The two decisions worth arguing with

**The generic layer is somebody else's program, not a PowerShell module.** The
`Zfs` module exists because `Get-ZfsDataset` is worth having on a TrueNAS box.
There is no such module to write here: subtract sanoid and syncoid and what is
left is entirely OS/7 knowledge — which datasets the update train owns, where
`/home` really is, how to prove a copy arrived. So the backup code is four
dot-sourced files in `powershell/OS7/` and there is no third module and no third
`.deb`.

**Layer 2 grew instead, by two functions.** Verifying a remote target means
asking the target's ZFS, and the alternative to `-ComputerName` on the read
cmdlets was an `ssh` call from `powershell/OS7` — which `check-layering.py` would
have had to be weakened to permit. Growing the generic module by a generic
capability was the cheaper of the two, and Z1 stayed at 0. `Clear-ZpoolLabel`
came along for the same reason: creating a pool on a reused disk needs it, and
Layer 3 may not call `zpool`.

---

## 5. What it changed elsewhere

| File | Change |
|---|---|
| `powershell/Zfs/Zfs.psm1`, `.psd1` | Z14: `-ComputerName` on the four read cmdlets, `Clear-ZpoolLabel`, 19 new self-test checks |
| `powershell/OS7/OS7.psm1`, `.psd1` | dot-sources the four backup files; exports 17 more functions |
| `build/config/package-lists/os7-base.list.chroot` | `sanoid`, and `procps` — which neither program declares and both need |
| `build/config/os7-release.conf` | `OS7_SANOID_VERSION` / `_DEB_SHA256`, so a pin and a measurement can disagree loudly |
| `build/config/hooks/0060` | the new exports, and that all four backup files are non-empty |
| `build/config/hooks/0075` | `components.sanoid` — pinned *and* installed |
| `build/config/hooks/0090` | new: the programs, the defaults file, `ps`, the units, and that **no policy is baked into the image** |
| `build/config/includes.chroot/` | the three units and their two scripts — its second, third and fourth files ever |
| `installer/testing/check-image.py` | runs `Test-OS7Backup` against the shipped module, and checks the image's own share |
| `docs/DECISIONS.md` | the locked decision, and open question 8 |
| `docs/BUILD-NOTES.md` | #73–#76, and the "numbers above N are free" line, which had been wrong since #62 |
| `README.md` | status row; and `Restore-OS7`'s row, which still said "not implemented" three commits after it was |

---

## 6. One thing that went wrong, and why it is in the file

The `Clear-ZpoolLabel` self-test failed the first time it ran, and the cmdlet
looked broken. It was not: the fake had a counter captured by
`.GetNewClosure()`, which captures a **value**, so `$n++` incremented a copy and
every call looked like the first. The cmdlet was correctly reporting a label that
survived two successful `labelclear` calls — which is exactly the failure it
exists to catch, arriving from the test rather than from ZFS.

It is BUILD-NOTES #76 because the fix is not obvious from the symptom, and
because the same file already depends on `.GetNewClosure()` for the opposite
reason. Three minutes on this host. In a VM it would have been a boot cycle,
which is the argument for tier 1 existing at all.
