# Session — 1.0.0.277, the sixth preview: the archive of 2026-11-09, PowerShell 7.6.9, four things a person sees, and the first update from one published release to the next

**2026-11-09.** The owner asked whether the update path works yet, and for a new
preview with current software and security fixes, built and then taken by an
existing OS/7 machine. Four quality-of-life items from SESSION-QOL-SURVEY §3
were chosen by the owner for the same release. Everything below was measured on
the x64 Windows host unless it says otherwise.

| | |
|---|---|
| version | `1.0.0.277` (preview) — 275 and 276 built and not released (§5) |
| commit | `7e5b516` — clean tree; the pin change is `9bdae5e` |
| archive snapshot | `20261109T000000Z` (was `20261029T000000Z`) |
| archive exception | **none** (1.0.0.272 had linux 7.0.0-43.43 from `resolute-proposed`) |
| PowerShell | `7.6.9` (was `7.6.5`) |
| supersedes | `1.0.0.272` |

## 1. Where the update path stood, asked before anything was changed

* **From 1.0.0.272 on, prepared and never run end to end.** 272 carries #193's
  fix and a machine installed from its medium had read the published
  repository (SESSION-CVE-2026-98432 §10). An update FROM 272 needs a later
  published release, and there was none. This release is that test.
* **1.0.0.267 and earlier: no.** Their own `Get-OS7Release` fetches the index
  without the credential and the Storage Box answers 401 (#193). How those
  machines get past their own updater is still not decided.

The existing machine chosen by the owner is bench `p272`, installed unattended
(Headless) from the published `OS7-1.0.0.272-amd64.iso`. Asked on 2026-11-09:
1.0.0.272, `7.0.0-43-generic`, one boot environment
(`os7_1.0.0.272_202610311921`), and the update channel in the SHIPPED state —
`/etc/apt/sources.list.d/os7.sources` says `Enabled: no`, no
`/etc/os7/update.conf`.

**Its first boot of the day stalled** after the passphrase: the serial log ended
with an XTGETTCAP query (`P+q6E616D65`) and nothing else for half an hour, ssh
never answered, the screen said "Display output is not active". An Enter on the
serial line and one through QMP changed nothing. Powered off and booted again,
the same disk reached a login in about 15 minutes. #188's shape (`splash` and a
serial console), not reproduced and not explained further.

## 2. The pin

### 2.1 The archive, 20261029T000000Z → 20261109T000000Z

`.../20261109T000000Z/dists/resolute-updates/Release` dated Sun, 08 Nov 2026
00:30:00 UTC, `-security` 00:29:29. Every (name, architecture) pair in both
1.0.0.272 manifests — 1 976 of them — asked of a clean `ubuntu:26.04` pointed
at each snapshot in turn, with ONE `apt-cache policy` call per snapshot (one
call per package would have taken 80 minutes). Unanswered at both: the 23 that
are OS/7's own and Microsoft's.

**47 pairs moved (32 names), 35 of them to a version in `resolute-security`**:
`apt`/`libapt-pkg7.0` 3.2.0 → 3.2.1ubuntu0.1; `dotnet-runtime-10.0`, `-host`,
`-hostfxr` and `aspnetcore-runtime-10.0` 10.0.13 → 10.0.14 (what the GUI
applications run on); `bind9-host`/`-dnsutils`/`-libs`; `gnome-shell` and
`-common` 50.1-0ubuntu1.4 → 1.5; `gvfs` and five subpackages; `libsoup-3.0`
and its gir; `libpcre2-8-0`/`-32-0`; `libsnmp40t64`/`libsnmp-base`;
`python3-pil`. From `-updates` only: `base-files`, `vim`/`xxd`, and
`linux-image-generic` 7.0.0-42.42 → 7.0.0-43.43.

**The first measurement was a false green**, and in the shape this repository
keeps meeting: `snapshot.ubuntu.com` redirects http to https, `ubuntu:26.04`
has no `ca-certificates`, and `apt-get update` exited 0 having fetched nothing —
so both snapshots "answered" with nothing, and "0 moved" was printed. The
script now installs `ca-certificates` first and refuses a run in which apt
printed any `W:`, `E:` or `Err:` line.

### 2.2 The archive exception goes

At `20261109T000000Z`, `resolute-updates` offers `linux-image-generic`
7.0.0-43.43 on both architectures (`-security` still 42.42). All nine files the
exception pinned — five amd64, four arm64 — were looked up in that suite's
`Packages` by name: **every one the same sha256**. A machine on 1.0.0.272
already holds exactly what the snapshot now offers, so nothing on it moves when
the exception does. The pin's block became a short section saying none is
declared, why the last one went, and the format, which `build.sh`, hooks 0005
and 0075, `build-os7-repo.sh` and `check-image.py` still read. Each of those
was read for what it does with an empty declaration before the block went: all
take the "none declared" path, and `check-image.py` then requires the image to
carry none.

### 2.3 PowerShell 7.6.5 → 7.6.9

pwsh's tarball carries its own .NET, so pwsh's patch level is the runtime
every cmdlet runs on. Asked in one container: **7.6.5 reports .NET 10.0.11,
7.6.9 reports 10.0.14**. Microsoft's .NET 10 release metadata marks 10.0.12
(2026-09-08), 10.0.13 (2026-10-13) and 10.0.14 (2026-10-25) all
`security: true`, with 6, 44 and 4 CVE ids.

The bump had been held since 2026-09-21 because `check-compat-windows.py` is
recorded from a real Windows pwsh and moving the pin meant re-recording. This
host's Windows pwsh is 7.6.9: **its 14 parameter sets are identical to the
7.6.5 recording.** On Linux, 7.6.5 against 7.6.9: the same 47
`Microsoft.PowerShell.Management` commands, `System.DirectoryServices.Protocols`
resolving, `Invoke-WebRequest -UnixSocket` present. The two hashes are of the
downloaded files and equal GitHub's asset digests — whose digest for 7.6.5's x64
tarball equals what the pin carried, which is what made that source worth
comparing against.

## 3. The build container (BUILD-NOTES #197)

The no-VM gate on the working tree was green except `check-os7-repo.py`, which
builds every package and stopped at the installer:

    error NU1903: Warning As Error: Package 'Microsoft.DotNet.ILCompiler'
    10.0.11 has a known high severity vulnerability,
    https://github.com/advisories/GHSA-p3jp-9v83-76w9

CVE-2026-111497, the .NET Brotli decoder, out-of-bounds write; GitHub published
it 2026-11-03, after 1.0.0.272 was built with the same toolchain; fixed in
10.0.14. `os7-setup` is NativeAOT and carries the SDK's runtime, the SDK came
from the live archive, and `make image-<arch>` had reused a two-month-old layer:
SDK 10.0.111, runtime 10.0.11.

Both containers rebuilt with `--no-cache` (old ones kept as
`os7-build:<arch>-pre-20261109`). amd64: 62 of 257 packages moved, among them
`dotnet-sdk-10.0` 10.0.111 → 10.0.114 (runtime 10.0.14), `libfreetype6`
ubuntu0.1 → ubuntu0.2, `systemd`, `libc6`, `gnupg`; `live-build`
3.0~a57-1ubuntu54, `debootstrap` 1.0.142ubuntu2, `xorriso` and
`squashfs-tools` unchanged. arm64: SDK 10.0.114, the same libfreetype. Both
console fonts rebuilt in the new amd64 container first, because libfreetype
decides their pixels: **both PSFs `sha256 ok` against the pin**. Then
`check-os7-repo.py` green (439 s), and the four checks that build C# in the
container (`check-version-rule`, `check-netplan-rule`, `check-gui-logic`,
`check-installer-cmdlets`) green again.

## 4. Four things a person sees (SESSION-QOL-SURVEY §3, chosen by the owner)

### 4.1 The boot menu (Q5, BRAND-PLAN BRL8)

Read first on bench `p272`, `/boot/grub/grub.cfg` as root — and it corrected
an assumption made from reading the image's scripts: the menu was **not**
monochrome. `05_debian_theme` gives `white/black` only to
`GRUB_DISTRIBUTOR=Ubuntu|Kubuntu`, and Setup writes `"OS/7"`, so every
installed machine's menu was `cyan/blue` / `white/blue`. The same file held
`set timeout=30` twice (the recordfail blocks), "Advanced options for OS/7 …"
and **eight** memory-test entries (x64 and ia32, each with a serial twin, from
two places).

Built in `os7-console`, both files conffiles:
`/etc/default/grub.d/50-os7-boot-menu.cfg` — `GRUB_RECORDFAIL_TIMEOUT=5` and
`GRUB_DISABLE_MEMTEST=true` — and `/etc/grub.d/06_os7_theme`, which says
`light-gray/black` / `black/light-gray` after 05 (built-in variables, no
module). Read in the image before writing them: `grub-mkconfig` sources
`/etc/default/grub.d/*.cfg` and exports `GRUB_RECORDFAIL_TIMEOUT`;
`20_memtest86+`'s own `config_item` reads the directory — 8 entries without
the file, 0 with it.

**Not done: the "Advanced options" submenu.** `GRUB_DISABLE_SUBMENU=y` would
put its entries at the top level rather than remove them, and hiding
`10_linux_zfs` would hide what OS/7's own menu code reads when it activates a
boot environment.

### 4.2 The terminal (Q11)

The default profile in `00-os7-classic` gains `font='Cascadia Mono 11'`,
Windows Terminal's Campbell palette (`#CCCCCC` on `#0C0C0C`, sixteen colours),
`use-theme-colors=false`, 120×30 and `visible-name='PowerShell'`;
`os7-desktop-theme` Depends on `fonts-cascadia-code` (2407.24-3, the archive
file the console PSFs are made from, same sha256). A menu entry *PowerShell*
starts `gnome-terminal -- /usr/bin/pwsh -Login -NoLogo`: `-Login` runs
`/etc/profile` through a non-interactive `sh -l`, so the hand-off's first guard
keeps it from handing off twice. Read back in `os7img:175`: the keyfile
compiled into a private database and asked through **GSettings with the real
schema**, which drops a wrongly typed value in silence — all ten keys came back
typed; the control (no keyfile) answered `'Monospace 12'` and 80.
`desktop-file-validate` clean.

### 4.3 `Get-OS7RestoreAside` as the owner of the files

SESSION-MANUAL-APPS-AND-SHOTS §4.2: the verb says it is unprivileged and died
with .NET's "Access to the path … is denied", because the backup policy is
`0600 root`. Now the policy read is caught, and the default sources —
`rpool/USERDATA`, `rpool/DATA/srv`, `rpool/DATA/lib/os7-domain-homes`, where an
owner's own restores put things — are walked instead.
`Get-OS7BackupPolicy` refuses in #148's words and keeps the exception's type,
so a caller can tell this from a broken file. `check-storage-logic.py` §9
gained the unprivileged case (the same files found, the default roots asked);
**red on the old code with three failures, green on the new.** The real
cmdlets as `nobody` in a container against a real `0600` file: the refusal
sentence, and `Get-OS7RestoreAside` on to the default roots (where the
container's missing ZFS module stopped it — the machine is in §8).

### 4.4 "An update is waiting" (Q13)

`os7-update-check` writes `/run/os7/update-pending` (`Version`,
`BootEnvironment`) in both branches that exit 2, only when it changes, and
removes it in both branches that exit 0. `/etc/update-motd.d/41-os7-update`
(in `os7-release`, so it reaches machines that update; `40-os7-storage` is in
`includes.chroot` and does not) prints *"ready to install … Finish it: sudo
Set-OS7BootEnvironment <be>"*, or *"Restart to finish"* once the ESP stub names
that environment — a file read, run as root by `pam_motd`, no ZFS. A user path
unit in `os7-app-softwareupdate` raises a desktop notification at sign-in and
whenever the file changes. All three states of the banner and the notifier's
arguments dry-run in `os7img:175`; `run-s5.py timer` now asserts the file, both
banner sentences (with a real activation) and the 5-second menu on a machine.

## 5. Two version numbers that were built and not released: 275 and 276

The owner approved the release commit `9bdae5e` (build 275) after the no-VM
gate was green on it. Before anything was published, three things went wrong
that nothing short of a medium and a machine could show, and each cost a commit,
so the release is **1.0.0.277**. The 275 and 276 media and repository cuts were
deleted; nothing of either left this host.

| | found by | what | fixed in |
|---|---|---|---|
| **#198** | the field update **rehearsed** on `p272`: 272 → 275 against the cut repository, served locally | the update applied and activated, the machine rebooted into 275 on 7.0.0-43, pwsh 7.6.9 on .NET 10.0.14, no failed unit — and the menu GRUB had just read was 272's: two `set timeout=30`, `cyan/blue`, eight memory-test entries. `Set-OS7BootEnvironment` builds the target's menu in the RUNNING environment (steps 1 and 4), which has neither new file; `grub.cfg`'s mtime was the activation's. Run for the running 275 environment, the same cmdlet wrote the right menu | `7f672fd` (276): firstboot migration `81-boot-menu` and `check-boot-menu-migration.py` |
| **#199** | `check-image.py amd64` on `OS7-1.0.0.275-amd64.iso` | `41-os7-update` was `0644` in the image and `0755` on the bench that updated: hook 0075's MOTD keep-list named two files and took the execute bit from the third | `7f672fd` (276): the hook keeps every `NN-os7-*`; `check-image.py amd64` on the 276 medium then green, 212 ok |
| **#198, again** | the rehearsal 272 → 276 | `81-boot-menu` found all three stale, rebuilt a CORRECT menu, then failed its own read-back at every boot — it asked for the word `memtest86+`, which grub-mkconfig's `### BEGIN /etc/grub.d/20_memtest86+ ###` always contains. The check had been green because its fake generator wrote no section markers | `7e5b516` (277): count `--class memtest` entries; the fake writes the markers; a second plant restores the word and goes red. The old file against a menu holding only the marker: exit 1; the new one: 0; the new one on the bench's real menu: "nothing to do" |

The rehearsal is what made this cheap: an update from the previous published
release to the CUT tree, on a machine installed from that release's published
medium, before step 6. `run-s5.py update` takes a medium to the next build of
the SAME tree, so it can never see a defect that lives in the difference
between two releases — and #198 lives exactly there.

## 6. The disk filled, and the large data moved to D:

Midway through 277's builds the owner stopped the session: `C:` had 0.5 GB
free. Measured: `.vm/` 123 GB (19 benches), `out/` 61 GB, Docker's
`docker_data.vhdx` 84 GB — all on `C:`. With the owner's decision: the 17
benches no longer needed and the unpublished development media
(216/222/231/233/247/262/266) deleted; `p272`, `gui` (the AD-join snapshots),
the published media (203, 245, 264, 267, 272) and every repository tree moved
to `D:\OS7` (≈45 MB/s). `out/` and `.vm/` are now NTFS junctions to `D:\OS7\out`
and `D:\OS7\vm`, measured transparent for Windows-side Docker and for WSL
(`/mnt/c/…` appears as a symlink to `/mnt/d/…`, and `docker -v` mounts through
it). WSL's git then listed both as untracked — `.gitignore` says `out/` and
`.vm/`, directories only, and WSL sees a junction as a symlink — so they are
excluded in `.git/info/exclude`, not in `.gitignore`: a commit would have moved
the build number again. The moved 272 media and 203's amd64 medium hash to
their published values.

One trap on the way: `out/os7-repo` had been moved aside while `p272`'s HTTP
container still served it, and afterwards the name could neither be listed nor
created (`mkdir: Already exists`, `stat: No such file`) — a delete-pending
directory. The cuts went to `out/cut-<build>/os7-repo` (`make repo-<arch>
OUT=… KEYDIR=out/os7-gnupg`, the key held where it was so the cut is signed by
the development key 272 trusts). Never move a directory a running container
mounts.

## 7. The field update, rehearsed: 1.0.0.272 → 1.0.0.277 before publication

Bench `p272` restored to its snapshot `pre-275` (1.0.0.272, the update channel
in the shipped state), the cut tree `out/cut-277/os7-repo` served at
`http://10.0.2.2:8907`, and what an operator types, as root:
`Set-OS7UpdateChannel -Uri … -Channel preview`, `Get-OS7Release -Available`,
`Update-OS7 -Version 1.0.0.277 -AllowDevelopment` (the cut is still
development-signed before step 6; 272's trust anchor holds that key beside the
release key).

* `Get-OS7Release` listed 12 entries, the published ten and 277 for both
  architectures, 277 amd64 `Applicable`.
* `Update-OS7`: `From 1.0.0.272 To 1.0.0.277`, `Applied`, `Activated`.
* After the reboot: 1.0.0.277, `7.0.0-43-generic`, `/` from
  `rpool/ROOT/os7_1.0.0.277_202611091419`, pwsh 7.6.9 on .NET 10.0.14, `apt`
  3.2.1ubuntu0.1, `dotnet-runtime-10.0` 10.0.14, **no failed unit**.
* **`81-boot-menu`**: *"the menu was generated from another environment's
  configuration: wait memtest colours"* → *"done: … wait 5 s, memory tests off,
  colours light-gray/black"*; all eight firstboot migrations complete, the unit
  `inactive` (succeeded). The menu GRUB reads: no `set timeout=30`,
  `light-gray/black` after Debian's blue, no memory-test entry.
* `41-os7-update` `0755`, silent with nothing staged; `os7-update-check` with the
  channel set: exit 0, *"nothing to do: this machine runs the newest release"*,
  no `/run/os7/update-pending`.
* As `os7admin`, `Get-OS7RestoreAside` answered (*"the backup policy cannot be
  read by this session; walking the default sources …"*, 0 files), and
  `Get-OS7BackupPolicy -ConfigOnly` refused as an `UnauthorizedAccessException`
  with the `sudo pwsh -c` sentence.

**One boot of the restored 272 environment stalled** before this run: the serial
log ends with systemd's terminal queries (`ESC[6n`, an OSC 3008 context
sequence) and `[!!!!!!] Failed to start up manager.` — #188's signature — and
the bench's login gave up. A cold start of the same disk booted normally. It is
the second stall of the day on this bench (§1) and the third recorded on a
`p272`/`f267` bench; all under `quiet splash` with a serial console attached.
Kept as `D:\OS7\p272-stall-2026-11-09-1405.log`; not reproduced on demand.

## 8. The media and the gate, from `7e5b516`

| medium | bytes | sha256 |
|---|---|---|
| `OS7-1.0.0.277-amd64.iso` | 3 426 037 760 | `6d9dd913db5ba16806c4f9c633cacb4c6fa936cac0e451faed3929fe18cb7a48` |
| `OS7-1.0.0.277-arm64.iso` | 1 850 454 016 | `c61f8dae3635dd8d6966c53ed159f1e6fb24f71c02ff0b449fcc9f642d748e62` |

Both `reproducible: true`, `source.commit 7e5b516a59d7`, `dirty: false`; 1 532
packages on amd64, 586 on arm64. Built with `OS7_RELEASE_PUBKEY` and
`OS7_REPO_CREDENTIAL` from a script that refused another HEAD, a dirty tree, a
missing key or credential and (arm64) an emulation not answering `aarch64`;
arm64 first, amd64 once arm64's log said `>>> Running live-build`.

| on the medium (amd64) | |
|---|---|
| `check-image.py amd64` | **212 ok, 0 failed** |
| `run-s5.py all` | install, boot (TPM, nothing typed), cycle 9/9, update 277 → 278 8/8 (firstboot migrations, rollback), timer 4/4 — and the timer phase's new assertions: the installed menu has no `set timeout=30`, `/run/os7/update-pending` names the staged release, the banner says "ready to install" and the command. **One red line, the harness's own**: the activation this session added called `Set-OS7BootEnvironment` without `-Confirm:$false`, and the cmdlet (ConfirmImpact High) asked. Fixed; `run-s5.py timer` again: PASS, 11 ok, including "once activated, it says: restart to finish" |
| `run-firstrun.py --bench s5` | 13 ok |
| `run-phase3.py install`, `walk` | PASS, PASS (walk 27 ok) |
| `run-secureboot.py all` | medium, install, disk: **32 ok**. **policy: the first run stalled** after the passphrase in systemd's terminal-query block, redrawn until the 600 s ran out — and the harness had switched answering on BEFORE typing the passphrase, #188's trigger. The phase alone: 3 ok. With the harness fixed (answering starts at `live_login`, as `os7lab.py`'s did since #188): 3 ok again. Whether the early answering was the cause is not proven — the stall is a race and passed twice without the fix too; it is the documented trigger and is gone |
| `check-image.py arm64` | **153 ok, 0 failed**; apt in a clean container resolves `os7-server=1.0.0.277` from the cut tree. arm64's whole evidence (RELEASE-PROCESS §2) |

The no-VM gate on the tree that became `9bdae5e`, re-run on what changed since:
all green, `check-boot-menu-migration.py` included.

## 9. Published (RELEASE-PROCESS §3 steps 6–8)

`publish-277.sh` is `publish-272.sh` with the version, the commit and the tree's
place moved on — 272's script was gone with its scratchpad and was recovered
from that session's transcript, byte for byte, before it was edited. Its
`--check` was green first. The operator typed the release key's passphrase, the
publish sub-account's password and `yes` twice.

1. **Step 6**: both 277 descriptors rewritten to `development: false`, the index
   re-hashed, `Release.gpg`, `InRelease` and `index/preview.json.asc` signed by
   `E39B3127…B3F5FAF9` and asked back against the release key's public half
   alone: one signature each; all twelve descriptors' hashes match the index.
2. **8a**, the payload to `repo/` on the Storage Box; **8b**, 272's images off the
   webspace, 277's two and `SHA256SUMS` on, in 2 minutes, read back off the
   server and hashed — `6d9dd913…`, `c61f8dae…`, `SHA256SUMS adfa809b…`, each
   equal to the file on disk; **8c**, the index last.

**Asked back from outside**, over the read-only account, into a fresh directory
on `D:`: all **98 pool files** (1 279 496 868 bytes) at their recorded size and
sha256; the whole fetched tree **identical** (`diff -rq`) to the signed local
one; `InRelease`, `Release.gpg` and the index each one good signature against
the release key alone; 277 supersedes 272 and says `development: false`;
`Valid-Until: Wed, 09 Dec 2026`.

## 10. The field update, from the published repository

The owner's question was whether an existing OS/7 machine updates. Bench `p272`
restored to `pre-275` once more — installed from the published 1.0.0.272
medium, the update channel in the shipped state (`Enabled: no`) — and, as root,
the commands the 277 release notes give a 272 machine, **without
`-AllowDevelopment`**:

* `Set-OS7UpdateChannel -Channel preview` → `Uri https://u661569-sub2.your-storagebox.de`,
  `Enabled True`.
* `Get-OS7Release -Available` → twelve entries; 1.0.0.277 amd64 `Applicable`,
  `Development False`.
* `Update-OS7` → `From 1.0.0.272 To 1.0.0.277`, `Applied`, `Activated`.
* After the reboot (one stall again, §11; a cold start booted): 1.0.0.277,
  `7.0.0-43-generic`, `/` from `rpool/ROOT/os7_1.0.0.277_202611091628`, pwsh
  7.6.9 on .NET 10.0.14, no failed unit; `81-boot-menu` rebuilt the menu (no
  `set timeout=30`, monochrome, no memory-test entry) and all eight firstboot
  migrations completed; `41-os7-update` `0755` and silent.

**So: a machine on 1.0.0.272 updates to 1.0.0.277 with its own updater, from
the published repository, signed by the release key.** This is the first time
an OS/7 machine has done that — every earlier update in this repository's
record was from a local or development-signed tree, or needed #193 bypassed.

## 11. What is not done, and what is owed

* **Machines on 1.0.0.267 or earlier** still cannot read the published
  repository through their own updater (#193). Unchanged; the decision is open.
* **The bench stalls.** Three boots of `p272` today (two of 272, one of 277)
  stopped after the passphrase in systemd's terminal-query block on the serial
  console, and a cold start booted each time; `run-secureboot.py policy` once,
  with the harness answering queries early. All under `quiet splash` with a
  serial console attached — #188's conditions, which a default install does not
  have. Not reproduced on demand, cause not separated; the logs are kept on
  `D:\OS7`.
* **Not seen on a screen:** the terminal profile (Cascadia, Campbell, 120×30)
  and the desktop notification. Both are asked of the medium by
  `check-image.py`, the notifier's arguments ran in a container; no GUI machine
  ran 277.
* **Q5's rest**: the "Advanced options" submenu and readable titles for OS/7's
  own entries.
* **#198 in general**: a later release that changes GRUB's configuration needs
  a migration of its own, or activation has to build the target's menu from the
  target's configuration.
* **The build container is still unpinned** (#197); RELEASE-PROCESS now says to
  rebuild it without the cache for a release.
* **arm64** has, as for every release, no boot gate.
* **The download path by name** over HTTP was not fetched: `os7.org` does not
  resolve from this host's network (RELEASE-PROCESS §3 step 10).
