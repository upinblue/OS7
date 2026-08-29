# Working on OS/7

OS/7 is a Microsoft-admin-friendly Linux built on Ubuntu 26.04 LTS: PowerShell as
the interactive shell, Entra ID / Intune / Azure Arc as the management path, ZFS
root with rollback-safe updates, and an OS/7-authored text-mode installer styled
after MS-DOS 6.22 Setup and the Windows 2000 text phase.

Everything runs **locally**. No cloud, no paid services. Builds are Docker; VMs
are QEMU.

**Two hosts, and which one you are on decides what you can do.** This line used
to read "locally on an Apple Silicon Mac", and it stopped being the whole truth
on 2026-08-25:

| host | builds | tests |
|---|---|---|
| **Apple Silicon Mac** | `make build-arm64`, native, ~5 min. amd64 **cannot** be built here (#12/#23) | every `run-*.py` harness, on the arm64 branch of `installer/testing/vmarch.py` — `qemu-system-aarch64 -machine virt,accel=hvf` as a HOST process, byte-identical to the pre-port construction (`check-vm-arch.py` holds it) |
| **x64 Windows + Docker Desktop** | `make build-amd64` — through WSL's make; native, ~20 min ([SESSION-AMD64-ON-WINDOWS.md](docs/SESSION-AMD64-ON-WINDOWS.md)) | `check-image.py`, `check-os7-repo.py`, the container checks — **and `run-s5.py` since 2026-08-28**: vmarch.py's amd64 branch runs `qemu-system-x86_64 -machine q35,accel=kvm` with OVMF INSIDE the `os7-vm:amd64` container, serial over the docker client's stdio ([SESSION-VM-HARNESS-PORT.md](docs/SESSION-VM-HARNESS-PORT.md)). The other harnesses are ported and UNRUN on this host |

**The x86_64 port exists since 2026-08-28 and `run-s5.py all` has passed on
it IN FULL** — install, boot (which measured #69 for the first time, see
#100), the cycle, `Update-OS7` against a served repository (N → N+1,
firstboot migrations, rollback by recorded ancestry) and the unattended
timer's exit-code contract, on this box, on a fully packaged ISO
(docs/SESSION-UPDATE-DELIVERY.md). `installer/testing/vmarch.py` is the ONE place machine,
accelerator, firmware and execution vehicle come from; `check-vm-arch.py`
rebuilds the pre-port arm64 command lines from commit 8700095's literals and
requires the refactored harnesses to emit exactly those bytes, so the Mac's
branch cannot drift unnoticed while nobody is on a Mac. The KVM facts that
made it possible, re-measured 2026-08-28: WSL2 has nested virtualisation on,
`/dev/kvm` exists, `docker run --device /dev/kvm` passes it through
(`query-kvm → {"enabled": true}`), no elevation, no Hyper-V by hand. Beware
#102 — Git Bash mangles `--device /dev/kvm` into a Windows path; PowerShell
and subprocess do not.

So "not yet verified on a machine" still means different things on the two
hosts — arm64 boots happen only on the Mac — and a session that cannot run a
harness should say so rather than leave the next reader to assume it was run.
There **is** a GitHub Actions workflow (`.github/workflows/build-iso.yml`),
dispatch-only; nothing in this repository depends on it having run.

---

## Where authority lives

Do not decide something these files have already decided. Do not restate them
here either — this file points, they rule.

| Question | The file that answers it |
|---|---|
| What version this is, what archive it was built against, what is in it | [build/config/os7-release.conf](build/config/os7-release.conf) — the pin. **The only place a version number or an archive URL may live.** |
| What is locked, what is still open | [docs/DECISIONS.md](docs/DECISIONS.md) — "Locked decisions" and "Open questions". Moved out of README.md on 2026-08-25; the README is now the public front page and decides nothing |
| The installer: design, screens, decisions D1–D10, limitations L1–L22, phases | [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md) — **authoritative** |
| Versioning, the update train, rollback, `/var` | [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) |
| What the product CONTAINS, how a release is delivered, decisions C1–C12 | [docs/CURATION-AND-DELIVERY-PLAN.md](docs/CURATION-AND-DELIVERY-PLAN.md) — **§9 (C10) CORRECTS three steps of the release plan's §4.2**, so read them together and let C10 win. C7a — where a release signing key lives — is open |
| What the machine calls itself and to whom, the friendly `1.x.x`, `Get-OS7Version`, decisions I1–I10 | [docs/IDENTITY-PLAN.md](docs/IDENTITY-PLAN.md) — **it supersedes the `NAME=` row of the release plan's §3.5** |
| What works today and what to do next | [docs/HANDOFF.md](docs/HANDOFF.md) — **read this first** |
| ZFS from PowerShell: the two layers, decisions Z1–Z14, the v1 surface | [docs/ZFS-POWERSHELL-PLAN.md](docs/ZFS-POWERSHELL-PLAN.md) |
| What OS/7 exposes as cmdlets, what it deliberately does not, how the layers are cut, decisions P1–P7 | [docs/POWERSHELL-SURFACE-PLAN.md](docs/POWERSHELL-SURFACE-PLAN.md) |
| Backup: what is snapshotted, where copies go, how it is verified, B1–B15 | [docs/BACKUP-PLAN.md](docs/BACKUP-PLAN.md) |
| Active Directory: the admin session, the domain join, what is deliberately absent, decisions A1–An | [docs/AD-PLAN.md](docs/AD-PLAN.md) — **authoritative**. The admin session is proven against a real domain controller; the join has never run on a machine |
| Every trap found so far, numbered | [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) — **read before debugging** |
| What a past session actually measured | `docs/SESSION-*.md` |

**Intune's constraints outrank OS/7's technical preferences** wherever the two
collide (DECISIONS, "Intune compatibility is a hard requirement"). Anything touching
disk layout, encryption, OS identity, desktop or browser gets checked against
Microsoft's live docs *first*.

---

## The commands that work

```bash
make build-arm64                          # the ISO. ~5 min. Docker, privileged.
make build-amd64                          # x86_64 hosts only - refuses elsewhere
make build-amd64-vm                       # on Apple Silicon: a QEMU x86 VM, hours

./installer/testing/check-image.py        # ask a built ISO what it is - no boot
make repo-amd64                           # OS/7's own SIGNED package repository
./installer/testing/check-os7-repo.py     # and the check that matters: install
                                          #   from it, in a plain ubuntu:26.04,
                                          #   then swap the key and require apt
                                          #   to REFUSE. No VM, ~4 min
./installer/testing/check-update-logic.py # the update train's DECISIONS and the
                                          #   ORDER of them, against fake zfs,
                                          #   apt and chroot - with REAL mounts
                                          #   and REAL signatures. ~3 min, no VM
./installer/testing/check-ps-traps.py     # THREE PowerShell traps this repo has
                                          #   paid for (#65, #91, #82), asked of
                                          #   the parser. Seconds; needs only pwsh.
                                          #   #82 is the import-scope one: it went
                                          #   red on the tree whose ISO build had
                                          #   just died of it, in one second
./installer/testing/run-phase1.py all     # walk os7-setup in a VM and check it
./installer/testing/run-phase3.py all     # install, BOOT THE DISK ALONE, then
                                          #   install again BY KEYPRESS (walk)
./installer/spikes/run-s1.py all          # the look: palette, font, glyphs, keys
./installer/spikes/run-s3.py all          # install to a disk and boot from it
./installer/spikes/run-s4.py all          # Secure Boot + TPM2 unlock (budget 1h)
./installer/spikes/run-s6.py all          # TPM2 unlock across an update
./installer/spikes/run-s7.py all          # is the version number true (two builds)
./installer/testing/run-s5.py all         # S5 and the update train's gate:
                                          #   install WITH A TPM, boot with no
                                          #   passphrase typed, the clone cycle,
                                          #   then Update-OS7 against a SERVED
                                          #   repository (N -> N+1, firstboot
                                          #   migrations, rollback) and the
                                          #   unattended check's exit codes.
                                          #   Runs on BOTH hosts since
                                          #   2026-08-28 (amd64: KVM in Docker)
./installer/testing/check-vm-arch.py      # the harness port's own check: the
                                          #   arm64 command lines byte-identical
                                          #   to the pre-port construction, the
                                          #   amd64 ones by property. No QEMU,
                                          #   no Docker, ~2s, both hosts
./installer/testing/check-be-logic.py     # the BE cmdlets' decisions, no VM, 3s
./installer/testing/check-home-logic.py   # Get-/Move-OS7Home's decisions: a fake
                                          #   zfs whose datasets are real tmpfs
                                          #   mounts. No VM, no ZFS, ~4s. Runs
                                          #   itself in a container (#74, #78)

./installer/testing/run-zfs.py capture    # real ZFS output -> test fixtures
./installer/testing/run-zfs.py test       # Test-ZfsModule -Live, on a booted VM
./installer/testing/check-layering.py     # Z1, P2, P2-time, P2-systemd: does OS7
                                          #   still reach ZFS, the network, the
                                          #   clock or systemd directly. FOUR
                                          #   rules; the first three at 0, the
                                          #   systemd one at 2 and named
./installer/testing/check-management-logic.py # Entra/Intune/Arc DECISIONS against
                                          #   a real image with systemd as PID 1.
                                          #   25 checks. Proves the thing that
                                          #   matters: brokers.d is EMPTY, so
                                          #   Entra sign-in cannot work (C8a)
./installer/testing/check-ad.py           # the AD surface against a DIRECTORY
                                          #   THAT ANSWERS: a real Samba AD DC
                                          #   in a container, and every write
                                          #   read back with ldbsearch inside
                                          #   it. Stage 1 is run a second time
                                          #   with the join tooling moved out
                                          #   of PATH
./installer/testing/check-directory-logic.py # the Directory DECISIONS, no DC,
                                          #   no VM: 15 checks, seconds
./installer/testing/check-installer-cmdlets.py # does os7-setup call cmdlets
                                          #   that EXIST, with parameters they
                                          #   HAVE. Reads the C# for what will
                                          #   be typed and asks PowerShell what
                                          #   will bind. It found the installer
                                          #   naming -Root and -PasswordFile on
                                          #   a cmdlet that has -TargetRoot and
                                          #   -Password (#108), while six other
                                          #   checks were green
./installer/testing/check-service-logic.py # Get-OS7Service's HEALTHY rule: ten
                                          #   unit states, the WORKING ones as
                                          #   carefully as the broken. No systemd
./installer/testing/check-ssh-login.py    # what an SSH login ACTUALLY lands in,
                                          #   against a REAL sshd: interactive ->
                                          #   PowerShell (with the drop-in moved
                                          #   aside as a control), ssh host cmd
                                          #   -> bash, sftp intact, and
                                          #   Enter-PSSession before AND after
                                          #   Enable-OS7Remoting. Needs an os7img:*
                                          #   container image; says NOT CHECKED
                                          #   without one
./installer/testing/check-network-logic.py # the OS/7 network layer's DECISIONS
                                          #   against a fake ip and a fake
                                          #   netplan - INCLUDING the rollback:
                                          #   34 checks, eleven machines, no
                                          #   network, no VM, seconds
./installer/testing/check-netplan-rule.py # the netplan DOCUMENT, in both
                                          #   languages, BYTE FOR BYTE: 17 cases
                                          #   plus the refusal, no VM, seconds.
                                          #   --docker os7-build:<arch> for the
                                          #   C# half off a Mac or Windows box
./installer/testing/check-version-rule.py # the version DISPLAY RULE, in both
                                          #   languages: 82 checks, no VM, ~10s.
                                          #   --docker os7-build:<arch> for the
                                          #   C# half off a Mac or Windows box

./installer/testing/run-backup.py all     # backup, against real ZFS and real
                                          #   sanoid. NEVER RUN - it is the gate
                                          #   docs/BACKUP-PLAN.md B-5 names
```

The two self-tests need no VM, no ZFS and no ISO, and both are green:

```bash
pwsh -c 'Import-Module ./powershell/Zfs/Zfs.psd1 -Force; Test-ZfsModule'   # 75
pwsh -c 'Import-Module ./powershell/OS7/OS7.psd1 -Force; Test-OS7Backup'   # 63
```

**Boot environments are real since 2026-08-25**, and none of it is a ZFS
operation. `Get-/New-/Set-/Remove-OS7BootEnvironment` and `Restore-OS7` live in
`powershell/OS7/`. Three facts decide what a machine boots, all measured:
**OS/7 writes its own menu** (`/etc/grub.d/09_os7-boot-environments`, one entry
per environment) because `10_linux_zfs` emits only one without `zsys` (#67); a
file on the **ESP** names which environment's menu is read
(`set prefix=($root)'/BOOT/<be>@/grub'`); and `saved_entry` in that
environment's `grubenv` names the entry. No ZFS property takes part.
[docs/SESSION-BOOT-ENVIRONMENTS.md](docs/SESSION-BOOT-ENVIRONMENTS.md).

**The update train HAS RUN ON A MACHINE since 2026-08-28, on this Windows box.**
`Update-OS7` in `powershell/OS7/OS7.Update.ps1` is §4.2's sequence as C10
corrects it: clone the pair, assemble it, point apt at both repositories,
`apt install os7-<mode>=<version>` → `full-upgrade` → `autoremove`, run the
release's migrations, rebuild the initramfs, regenerate the menu, activate and
prune. `Get-OS7Release` verifies the signed index and each descriptor's hash
before it lists anything; `Set-OS7UpdateChannel` switches on the apt source
`os7-release` deliberately ships disabled. **`run-s5.py all` is the gate and it
PASSES on x64 Windows** — install, TPM boot, cycle, a served 1.0.0.137 -> .138
update and the unattended timer, all five, on fully packaged ISOs
([docs/SESSION-UPDATE-DELIVERY.md](docs/SESSION-UPDATE-DELIVERY.md)). Four runs,
four numbered defects (#104-#107), zero flakes. This paragraph said "NEVER RUN"
and "needs the Mac" until the 2026-08-28 merge, because the branch that ran it
and the branch carrying this sentence could not see each other. What arm64 owes
is the same gate on HVF: ported, byte-identical, never executed.

**`Active` on a boot environment is ZFS's `mounted` — "mounted ANYWHERE" — and
an update mounts a clone.** So there is a `Running` beside it, computed from the
dataset the kernel says serves `/`, and everything that means "the system that is
running" reads that. Reading `Active` as "running" put the running machine's
kernel into another environment's menu entry, which is §4.3's half-activated
pair reached by a road nothing checks.
[docs/SESSION-UPDATE-TRAIN.md](docs/SESSION-UPDATE-TRAIN.md).

**Six PowerShell modules since 2026-08-28, and the direction between them
matters.** `powershell/Zfs/`, `powershell/Net/`, `powershell/Time/`,
`powershell/Systemd/` and `powershell/Directory/` are the generic layers — none
knows anything about OS/7, and all five would run on any Ubuntu host.
`powershell/OS7/` is the product layer on top, and it is 95 of the 185 functions.
Z1 says OS7 reaches ZFS only through Zfs, P2 says the same about the network,
**P2-time** about the clock, **P2-systemd** about units and **P2-directory**
about the directory; `check-layering.py` holds **all five** at baselines that may
fall and may not rise. The full inventory, generated by asking the modules rather
than written from memory, is [docs/POWERSHELL-REFERENCE.md](docs/POWERSHELL-REFERENCE.md).

This line said "four" until 2026-08-28 and had been wrong since `Systemd` landed.
A count in prose has nothing checking it, which is the argument for the reference
file being generated rather than maintained.

**P2-time was 1 for about ten minutes**, and that is the argument for a check
rather than a paragraph: `Sync-OS7Time` called `chronyc makestep` itself, under a
file header that said in capitals it did no such thing. The paragraph was already
written; the code under it did the other thing.

**The clock is chrony, not systemd-timesyncd**, and `powershell/Time/` exists
because measuring that corrected the plan — `POWERSHELL-SURFACE-PLAN.md` P2 had
offered the time zone as the example of a subsystem too thin to deserve a module.
`Get-OS7TimeSynchronization` has **three** outcomes: `$null` when chronyd could
not be asked, `$false` when it was asked and is not disciplining, `$true` when it
is. Time is Tier 1 because Kerberos refuses a ticket more than five minutes out,
and a drifting clock does not report a clock problem — it reports that the
password is wrong.

**No OS/7 machine has ever joined a domain, and administering Active Directory
does not need one.** An administrator signs in to a domain controller *from* an
OS/7 machine with their own AD admin account and works as themselves; that is an
outbound LDAPS connection and nothing else — no machine account, no keytab, no
new package. The last clause is a measurement rather than a hope:
`System.DirectoryServices.Protocols` ships **inside** pwsh 7.6.5 on Linux,
resolves with no `Add-Type` and reaches `libldap`, and `libldap2` is a Depends of
`libcurl4t64` while `curl` is in `os7-base.list.chroot`, so it is there on both
architectures. `System.DirectoryServices` (ADSI) loads on the same host and
*then* throws "not supported on this platform" — one of those two is a
foundation and the other is a trap, and only asking separates them. A second
measurement decides the credential path: `AuthType.Negotiate` with an explicitly
supplied credential returns **LDAP rc 92**, AD refuses a simple bind on port 389,
and `SessionOptions.Sealing` throws on Linux, so it is a simple bind over LDAPS
on 636 and there is no third option. `powershell/Directory/` is the generic layer
(P2-directory, the first layering rule to start at **1**, with its one site named
in the rule); `OS7.Directory.ps1`, `OS7.DirectoryObject.ps1` and `OS7.Domain.ps1`
are the product layer on top. The join is Stage 2 — written, builds, green in a
container, **never run on a machine** — and arm64 is unmeasured for all of it.
[docs/AD-PLAN.md](docs/AD-PLAN.md).

**The netplan document is generated in two languages and that is temporary.**
`NetworkPlan.ToNetplanYaml` (C#, what `os7-setup` writes) and
`New-NetplanDocument` (PowerShell, what the cmdlets will write) are one
specification written twice — BUILD-NOTES #66's shape, and the failure it makes
is a machine netplan configures with nothing and complains about not at all.
`check-netplan-rule.py` owns the cases and requires the two to agree **byte for
byte**; P3 in
[docs/POWERSHELL-SURFACE-PLAN.md](docs/POWERSHELL-SURFACE-PLAN.md) is the
two-step plan for deleting one of them, and step 2 needs the Mac. The Zfs module checks itself
against **recorded real ZFS output** shipped beside it:

```bash
pwsh -c 'Import-Module ./powershell/Zfs/Zfs.psd1 -Force; Test-ZfsModule'
```
**Backups are sanoid and syncoid, wrapped — not reimplemented.** `powershell/OS7`
decides which datasets, which targets and *whether it actually worked*; the
snapshot policy, the retention thinning and the `zfs send`/`receive` are the
`sanoid` package's, shelled out to (GPL-3.0+, never vendored). The wrapper
exists because **both tools report success in cases where nothing happened** —
sanoid exits 0 after a failed `zfs snapshot`, and its `--monitor-snapshots`
answers from a cache deliberately allowed to be five hours old (#73). So
`Get-OS7BackupStatus` asks ZFS, on the source and over ssh on the target, and
never asks either tool. [docs/BACKUP-PLAN.md](docs/BACKUP-PLAN.md).


**One file defines the release:**
[build/config/os7-release.conf](build/config/os7-release.conf) — the version, the
archive snapshot, and every component version and hash. Nothing else in the repo
may carry a version number or an archive URL. The build turns it into
`/usr/lib/os7/release.json`, `IMAGE_VERSION` in `/etc/os-release`, the ISO
filename and the boot-environment name, so those four cannot disagree. What a
built ISO actually contains is beside it:

```bash
./installer/testing/check-image.py        # seconds, no VM
```

That last one is the check nothing else can make: it reads
`/etc/apt/sources.list` out of the **shipped** image and fails if a single source
escaped the pin. Hook 0075 runs mid-build and cannot see what live-build does to
apt afterwards.

**A person is shown three fields, a machine four** (2026-08-26,
[docs/IDENTITY-PLAN.md](docs/IDENTITY-PLAN.md) §5). `1.0.0 (development)` is
chrome — the title row, `PRETTY_NAME`, `/etc/issue`, the MOTD,
`Get-OS7Version`; `1.0.0.95` is anything that has to tell two builds apart —
dataset names, `IMAGE_VERSION`, the ISO filename, `--version`, the
boot-environment menu, the Complete screen. It is a **display rule, not a second
number**, implemented **four times** — `Model/Release.cs` `Short`/`Full`,
`Get-OS7Version`, `installer/testing/os7version.py` and
`build/lib/version-rule.sh` — so `check-version-rule.py` owns the case table and
drives all four, and says which ones a given run reached. `Get-OS7Version` reads
the same `/usr/lib/os7/release.json` os7-setup and `New-OS7BootEnvironmentName`
read, and its `Drift` is **empty until `-CheckDrift`, never `$false`**.

**And the machine says OS/7 where a person looks, Ubuntu where software does.**
`PRETTY_NAME`, `/etc/issue`, the MOTD header and the GRUB menu are branded;
`NAME`, `ID`, `ID_LIKE`, `VERSION`, `VERSION_ID`, `VERSION_CODENAME`,
`/etc/lsb-release` and `uname` are not, and **`NAME` is on that list because
Microsoft's Arc onboarding script reads it and exits 133 on anything without
`buntu` in it** (#80). Every branded surface reads
`/usr/lib/os7/product` — OS/7's own file — so if `PRETTY_NAME` ever has to be
given back, nothing else changes.

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

**`os7-setup` installs a machine that boots** (Phase 3, 2026-08-24). From screen
10 onwards it writes to the disk, and screen 6 is the gate before that. The
proof is `run-phase3.py boot`: a VM with **no ISO attached**, starting the disk
Setup installed. Any claim about the installer that has not been through that is
a claim about code, not about a computer.

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
- **#80 — `/etc/os-release` is a folk convention, not a contract.** Three
  Microsoft consumers read three different field sets: Arc's onboarding script
  keys on **`NAME`** and exits 133 without ever reading `ID`; `intune-agent`
  reads `ID`, `VERSION`, `VERSION_ID` **and** `PRETTY_NAME`. D8 branded `NAME`
  because "Intune matches on `ID`" — never verified, and wrong for at least one
  tool. Never protect "the field they match on"; make the brand independent of
  all of them ([docs/IDENTITY-PLAN.md](docs/IDENTITY-PLAN.md) I1).
- **#85 — a theme can be installed, verified, and never loaded.** Hook 0090
  reported the classic desktop verified and every statement was true; the screen
  was Ubuntu's, because `00-os7-classic` set sixty keys and not
  `org.gnome.desktop.session session-name`, and `modes/ubuntu.json` carries its
  own `stylesheetName` that no user theme beats. Same shape as #62: every
  declaration satisfied, and the thing they were about decided elsewhere. The
  second half of the fix is checking that the session the key names **exists** —
  dconf stores any string and GDM falls back silently.
- **#110 — the LOGIN screen reads a different database, and GNOME's documented
  way of branding it does nothing on Ubuntu.** `/usr/share/dconf/profile/gdm`
  has **no `system-db:`** — only `file-db:/var/lib/gdm3/greeter-dconf-defaults`,
  which `gdm.service`'s `ExecStartPre` recompiles from **`/usr/share/gdm/dconf/`**
  at every start. So a keyfile in `/etc/dconf/db/gdm.d/` compiles, stores, and is
  read by nobody. And the Ubuntu logo and the orange accent are *named* in
  `10_ubuntu-settings.gschema.override`, owned by a package
  `ubuntu-desktop-minimal` Depends on: they cannot be removed, only **out-ranked**
  — a dconf value beats a schema default. The check that means anything is a
  CONTROL: ask GSettings through the compiled database, then ask again with the
  keyfile removed and require Ubuntu's answer back.
- **#111 — the login screen came up EMPTY, because the check used a tool the
  greeter does not.** gnome-shell loads the greeter logo through **GdkPixbuf**,
  which decides whether a file is an image by SNIFFING A 256-BYTE PREFIX rather
  than parsing it; a 35-line documentation header put `<svg` at byte 2764.
  `load_file_sync` then THROWS inside `LoginDialog`, mid-construction, so what
  is lost is not the logo but the whole dialog. Hook 0035 had rasterised the
  same file with `rsvg-convert` and reported it green, because rsvg parses and
  never sniffs. Ask which program actually opens the file. (And `--` inside an
  XML comment is illegal, which fails the same way with a different message.)
- **#84 — GNOME 50 will not draw 1-bit text.** `font-antialiasing='none'` was a
  deliberate Windows-2000 choice against a GNOME that no longer honours it: GTK 4
  loses vertical stems, GTK 3 on the same screen at the same size does not.
  Twelve renderings outside the desktop say the font is fine. Never conclude a
  font is at fault before rendering it somewhere the toolkit is not.
- **#86 — `/etc/profile.d` is read by LOGIN shells, and a terminal window is not
  one.** PowerShell greeted every console and ssh login and never once greeted a
  GUI terminal, because a terminal emulator starts bash non-login and
  `/etc/bash.bashrc` on this image sources nothing at all. Fixed with
  `login-shell=true` on gnome-terminal's default profile, so the *same* guarded
  hand-off runs. Hook 0050 now proves it by piping a PowerShell expression into
  `bash --login -i` and requiring the pinned version back.
  **And since 2026-08-27 the ssh half is tested too**, which it never was:
  `check-ssh-login.py` runs a REAL sshd and shows `PS /home/os7admin>` for an
  interactive login and `logout` with the drop-in moved aside as a control. The
  same run proves `ssh host 'command'` stays in **bash** — if that guard ever
  went, the symptom would not be a PowerShell prompt, it would be every scp,
  git and rsync to the machine breaking, with nothing to connect it to a shell
  setting. Writing that check also walked straight into **#16**: the first
  version grepped for a marker the pty had merely ECHOED.
- **#93 — a container image made from an ISO is NOT the ISO.** `os7img:*` is a
  fast way to ask an OS/7 image questions and it may carry anything anybody did
  to it after the ISO was written. One measurement in seven this way was
  contaminated, and it was a PAM stack that read as a serious identity defect;
  two files that `pam-auth-update` writes in one run carried timestamps three
  hours apart, which is what caught it. **`check-image.py` mounts the ISO's own
  squashfs — that is the authority.**
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
- **#43 — in a git WORKTREE, `.git` is a FILE pointing outside the bind mount**,
  so git in the build container cannot answer and every ISO came out `1.0.0.0`,
  commit "unknown". Build through the **Makefile**, which asks git on the host
  (`scripts/os7-source-facts.sh`) and hands the three facts in; `build.sh` now
  refuses rather than inventing a version. Claude Code sessions run in a
  worktree by default, so this is hit on the first build, not the tenth.
- **#45 — a screen must validate only what IT collected.** Screen 6 checked the
  whole plan, including an account nobody had been asked for yet, and screen 7
  was unreachable for a whole commit. `--unattend`, `--storage-only` and the
  screen-walking harness each missed it for a different reason. The whole plan is
  checked once, at `ExecuteScreen.Start`.
- **#74 — `/home/<user>` was NOT on a USERDATA dataset unless the account was
  called `os7`.** `New-OS7Storage`'s `-UserName` defaulted to `os7` and
  `os7-setup` never passed it, so the machine this repo has booted has an empty
  dataset at `/home/os7` and the real home inside the boot environment — where
  `Restore-OS7` rolls it back and no snapshot policy may follow. **Fixed in code
  2026-08-26 and NOT YET VERIFIED**: the fix changes the storage step and the
  account step of the only path that produces a machine that boots, so it needs
  `run-phase3.py all`, which is STILL UNRUN. It went through the vmarch.py port
  with the rest (it reaches QEMU through `vmscreen`), so it is no longer
  Mac-only - it has simply never been executed on either host since the fix.
  Nothing in `installer/testing/`
  looked at `/home` — which is why an installer that passed `run-phase3.py all`
  still had it — and checks 9 and 10 are now what stop that recurring.
- **#78 — `useradd -m` does NOTHING when the home directory already exists.**
  It warns, **exits 0**, copies no `/etc/skel` and changes no ownership
  (measured on this image's `passwd`). Since #74's fix the home is always there
  first, so this is the only path an OS/7 install takes: the naive one-parameter
  fix yields a correctly-placed home that is `root:root`, empty, and unwritable
  by its owner. `AccountStep` finishes the job and proves it from `stat`.
- **#79 — the setup medium boots a DESKTOP's background workload while it
  installs, and `loglevel=0` does not keep the kernel off Setup's screen.**
  Both halves measured out of the shipped amd64 squashfs after a 6 GB VM's
  install died at the pool step: the Install entry's `multi-user.target` pulls
  in **39** units and **15** timers — `unattended-upgrades`, six `snapd` units,
  `apt-daily.timer` — onto a medium whose writable root is RAM and which has no
  swap, with `zfs_arc_max` at its default half of memory; and
  `/usr/lib/sysctl.d/55-console-messages.conf` sets `kernel.printk = 4 4 1 7`,
  so `systemd-sysctl` undoes the command line before the first frame. Fixed by
  `os7-setup-quiesce` (a *generator*, so nothing is started and then stopped;
  keyed to `os7.setup=1`, so the live entry is untouched),
  `InstallerEnvironmentStep` (caps the ARC and reads it back), and
  `Terminal.QuietTheKernel`. **Not verified on a machine.**
- **#66 — code that replaces a spike must be DIFFED against it.** The installer's
  TPM step was written from the same notes as `s4-tpm-enroll.sh` and took a
  different route: no LUKS2 token handler in the initramfs, and
  `systemd-cryptsetup attach` instead of `cryptsetup open --token-only`. The
  spike boots; the paraphrase never had.
- **#69 — sealing to PCR 7 from the installer seals against the INSTALLER's
  PCR 7.** The live session boots with `-kernel`; the installed machine boots
  through shim, which extends PCR 7. Same TPM, different measurement, and
  `cryptsetup` says "TPM policy does not match current system state". Enrolment
  belongs on FIRST BOOT, which is why spike S4 worked and the install step does
  not.
- **#67 — `10_linux_zfs` lists ONE boot environment per machine without zsys.**
  Its `history` section is zsys-only, and the running environment always sorts
  first, so a second one can never appear in a menu generated from the first.
  OS/7 writes its own entries (`/etc/grub.d/09_os7-boot-environments`), built by
  substitution into the running entry.
- **#65 — `$from` IS the `-From` parameter.** PowerShell variable names are
  case-insensitive and a typed parameter coerces silently, so a hashtable
  assigned to `$from` became the string "System.Collections.Hashtable". Never
  reuse a parameter name for a local. `installer/testing/check-be-logic.py`
  finds this class in seconds instead of a VM cycle.
- **#64 — an early `exit 0` in an initramfs script is invisible.** The TPM
  handler asked for `/usr/lib/systemd/systemd-cryptsetup`, which is
  `/usr/bin/systemd-cryptsetup` on resolute, and gave up silently on every boot
  while three checks reported it present. Search for a binary, never name it,
  and say why you gave up.
- **#63 — a `zfs clone` does not carry the origin's local properties**, and
  `canmount` does not inherit at all, so a cloned boot environment comes out
  `canmount=on mountpoint=none` — mountable over the running root, and invisible
  to `10_linux_zfs`, which finds boot environments by `mountpoint=/`. Set both
  explicitly and ask ZFS back.
- **#62 — the package lists do not decide which kernel is installed.** In
  `--mode ubuntu` live-build derives `LB_LINUX_PACKAGES="linux"` and installs
  `linux-generic` beside whatever the lists name, so swapping the list entry
  removed nothing and the build was green. Set `--linux-packages` in
  `auto/config`, and read `config/chroot` back — the same rule as #36.

---

## Repository layout

```
build/                      the ISO: live-build config, hooks, and build.sh
  config/auto/config        live-build configuration (DISTRIBUTION=resolute)
  config/hooks/             common hooks, FLAT (trap #13); hooks-amd64/ for x86
  config/package-lists/     common; -amd64/ and -arm64/ for the split
  config/includes.chroot/   files copied verbatim into the image
  lib/build-console-font.sh Fixedsys TTF -> two PSFs, coverage and shape asserted
                            (os7-setup's font, D9)
  lib/build-installed-console-font.sh
                            Cascadia Mono .deb -> two PSFs (the INSTALLED
                            console, D15). A second route because otf2bdf
                            cannot reach an 8x16 cell from that font (#52)
  lib/cellfont.py           rasterise an outline font into an EXACT console
                            cell and write PSF2; skips what the cmap lacks (#57)
  lib/psf.py                the font subset table, the fixes, and the guard -
                            shared by both fonts, deliberately
  lib/palette.py            the palette, and D5's contrast check
  config/os7-release.conf   THE PIN: version, archive snapshot, component hashes
  config/hooks/0075-*       turns the pin into os-release, release.json and the
                            package manifest - and checks what it wrote
  lib/efi-remaster.sh       neither arch gets a usable bootloader out of
                            live-build; this makes the ISO boot, and owns
                            and owns the ISO's GRUB menu
installer/
  SETUP-PLAN.md             the installer design. Authoritative.
  src/OS7.Setup/            os7-setup itself
  assets/                   the systemd unit
  spikes/                   Phase 0 spikes: evidence, not templates
  testing/                  the VM harness: vmconsole (serial), vmscreen
                            (framebuffer, QMP, reading the screen back through
                            the console font), run-phase1.py
powershell/Directory/       the GENERIC directory layer (P2-directory). LDAP
                            over System.DirectoryServices.Protocols, which ships
                            inside pwsh and needs no Add-Type, plus realm
                            membership through adcli, kinit and getent. Knows
                            nothing about Active Directory's POLICY and nothing
                            about OS/7
powershell/Net/             the GENERIC network layer (P2). Knows netplan,
                            iproute2, networkd, NetworkManager and resolved;
                            knows nothing about OS/7. New-NetplanDocument is the
                            PowerShell half of the two-language renderer P3 is
                            collapsing
powershell/Time/            the GENERIC clock layer (P2). chrony's CSV (-c, so
                            no table parsing), the /etc/localtime symlink and
                            the /etc/adjtime RTC question. NTP servers go in
                            sources.d, NOT chrony.conf - measured
powershell/OS7/             the OS7 module - ONE source. It reaches an image as
                            the os7-module .deb (hook 0022) and NOT by staging;
                            build.sh stages the tests/ fixtures alone
  OS7.Backup*.ps1           backup: policy, targets, restore, self-test. Four of
                            the FOURTEEN files DOT-SOURCED by OS7.psm1, so a copy
                            that took the .psm1 alone is a real failure mode -
                            hook 0060 names all fourteen, and so does the .deb
                            content check since the 2026-08-28 merge. This line
                            said "four ... all five" while the file said FOURTEEN
                            sixty lines below it
  OS7.Home.ps1              where a home directory lives, and the migration for
                            machines installed before Setup passed -UserName
                            (#74). Dot-sourced too - it was the fifth of five
                            when this table was written, and is one of fourteen
  OS7.Network.ps1           the network as an operator asks about it: Get-/Set-
                            OS7NetworkAdapter, Get-OS7NetworkConfiguration,
                            Test-OS7Network, Get-OS7Endpoint. Set- verifies by
                            asking ip and ROLLS BACK when nothing came up;
                            RollbackFailed is the outcome that must never be
                            quiet. The endpoints are a DATA FILE beside the
                            module (sovereign clouds have other hostnames).
                            Contains NO call to ip/netplan/nmcli - that is P2 and
                            check-layering.py holds it. The first code here that
                            says L28 out loud: a netplan document matching no
                            adapter on this machine is REPORTED, where netplan
                            accepts it in silence
  OS7.Time.ps1              the clock as an operator asks about it. Carries the
                            one piece of OS/7 policy here: FIVE MINUTES, the
                            Kerberos skew, past which a clock problem presents
                            as a failed sign-in
  OS7.Directory.ps1         the admin session: which controller, and who the
                            SERVER says you are (RFC 4532 - a bind that raised
                            no exception is not proof of identity, and that is
                            what catches a fall back to anonymous). The
                            credential is used and then forgotten; a session
                            that could re-authenticate is a password at rest
  OS7.DirectoryObject.ps1   users, groups, computers and OUs - and raw filters,
                            DNs and attribute names beside them, because a
                            curated directory surface that cannot be escaped
                            would have to be complete
  OS7.Domain.ps1            the join, the logon policy and Kerberos tickets.
                            Domain users' homes are put OUTSIDE the boot
                            environment, which is #74's shape in a second place
  OS7.Update.ps1            the update train: Update-OS7, Get-OS7Release,
                            Set-OS7UpdateChannel, Test-OS7Update. LAST of the
                            FOURTEEN dot-sourced files, and last because it
                            calls every helper above it and PowerShell defines
                            functions as the script runs
build/packages/             OS/7's own .debs (C7). Each is a control.in plus an
                            optional tree/; build/lib/build-os7-packages.sh
                            builds them from the SAME sources build.sh stages
                            from, and build-os7-repo.sh signs a suite over them
  os7-release/tree/usr/lib/os7/migrations/README
                            the migration contract C10 asked for and no document
                            had written down: <version>/<chroot|firstboot>/NN-name
build/config/includes.chroot/
                            files copied verbatim into the image: the console
                            defaults, and the os7-backup units and their scripts
docs/                       plans, handoff, build notes, session results
out/, .vm/                  artefacts and VM state. Both gitignored.
```

**The website is NOT in this repository.** `web/` was here from 2026-08-27 to
2026-08-28 and now lives in **`upinblue/os7-web`**, which is PRIVATE while this
one is public. The pages' history went with it. Nothing here depends on it, and
the reverse dependency is one way and worth knowing about: `tools/prepare-
images.py` over there reads **this** repository's gitignored
`out/screenshots`, and `tools/publish-release.py` is pointed at ISOs in
`out/`, both assuming the two checkouts are siblings.

Two things over there that this repository will eventually meet. Its
`infra/main.bicep` creates a second blob container, `repo`, on the same storage
account as the ISOs, for the signed suite `build/lib/build-os7-repo.sh`
produces — so when `OS7_REPO_URI` in the pin finally points somewhere, that is
where. And the storage account name is unchosen: it lands in every published
download URL and in the apt source of every installed machine.

**arm64 and amd64 are different products** (DECISIONS): arm64 is server-only — no
GNOME, no Edge, no Intune — because Microsoft ships no arm64 desktop stack.
That split is still true. **"Everything proven is arm64 only; no amd64 ISO has
ever been built" was this line until 2026-08-28 and had been wrong for days** -
amd64 ISOs are built routinely on the x64 Windows host, four of them carried the
update train through its gate, and `out/` holds several
([SESSION-AMD64-ON-WINDOWS.md](docs/SESSION-AMD64-ON-WINDOWS.md),
[SESSION-UPDATE-DELIVERY.md](docs/SESSION-UPDATE-DELIVERY.md)). What is arm64-only
is the DESKTOP evidence and every `run-*.py` harness except `run-s5.py`.
