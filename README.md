# OS/7

**A Microsoft-admin-friendly Linux: PowerShell-first management, Entra ID / Intune enrollment, Azure Arc for servers — built on Ubuntu 26.04 LTS.**

Maintained by [up in blue GmbH](https://github.com/upinblue).

## What is OS/7?

OS/7 is an Ubuntu 26.04 LTS ("Resolute Raccoon") based operating system for IT admins and organizations that already run a Microsoft-centric stack (Entra ID, Intune, Azure) and want a Linux option that speaks the same language: PowerShell-controlled, Entra-joinable, Intune- or Azure-Arc-manageable, with ZFS-backed, rollback-safe updates.

It is **not** aimed at desktop consumers. Two primary targets, chosen at install time:

- **GUI mode** — admin/developer workstations, GNOME desktop, Intune-enrolled.
- **Headless mode** — servers hosting Microsoft-adjacent workloads, no desktop packages, managed via Azure Arc-enabled Servers instead of Intune.

## Status

The arm64 ISO builds and boots into OS/7 Setup, in OS/7's own colours and console font, and **Setup installs a machine that boots** — partitions, ESP, LUKS2, both pools, the dataset layout, the system, an administrator account, the initramfs and the bootloader. Verified by starting the installed disk with no setup medium attached. That a *finished* OS/7 boots from such a disk under Secure Boot with TPM2 auto-unlock was proven separately by spikes S3, S4 and S6, from a hand-written sequence rather than from the installer. `os7-setup` itself is not written yet, and amd64 is unvalidated. Read this table before assuming any command in this repo actually works.

| Component | Status |
|---|---|
| Repo scaffold / README | done (this commit) |
| `build/config/auto/config` (live-build config) | **validated, and pinned** — `lb config` passes, an arm64 ISO builds from it, and every mirror resolves to a fixed `snapshot.ubuntu.com` timestamp. That takes fourteen mirror flags, not five ([docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) #36), and it removed the `archive`/`ports` per-architecture branch |
| `powershell/OS7/` module | **half implemented** — `New-OS7Storage` and `New-OS7BootEnvironmentName` create the pools and the §4.4 dataset hierarchy and are what `os7-setup` calls (SETUP-PLAN §6.3, so `Update-OS7` cannot drift from it). `Set-OS7Mode`/`Update-OS7`/`Restore-OS7` are still stubs. The on-disk format, transport and ZFS layout its stubs say they lack are now designed: [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) |
| Updates / release train | **release engineering done and measured; the update mechanism is not started.** [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) Phase 1 shipped on 2026-08-24: one pin file, the build resolves against a fixed `snapshot.ubuntu.com` timestamp, and every image carries `/usr/lib/os7/release.json` plus a branded `IMAGE_VERSION`. **Spike S7 passed** — two builds from one pin hold identical package sets (549 packages, same manifest hash), so the number names a state rather than a moment: [docs/SESSION-RELEASE-IDENTITY.md](docs/SESSION-RELEASE-IDENTITY.md). `Update-OS7` / `Restore-OS7` and the `Get-OS7Version` surface are still ahead, and spike S5 (does the clone-update-rollback cycle boot) still gates them; U8 is open question 7 below |
| Installer (`os7-setup`) | **Phases 1–3 done — a machine it installs BOOTS.** On arm64, from the ISO's *Install OS/7* entry: partitions, ESP, LUKS2, both ZFS pools and the §4.4 datasets, then the system itself, an administrator account, the initramfs, TPM2 enrolment and the bootloader — with `--unattend`, `--dry-run` and `--storage-only`. 3.6 MB NativeAOT, no .NET runtime at run time. It shows the OS/7 release on every screen and names an existing OS/7 installation before offering to erase it. Verified by booting the installed disk with no ISO attached: [docs/SESSION-PHASE3-SYSTEM.md](docs/SESSION-PHASE3-SYSTEM.md), [docs/SESSION-PHASE2-STORAGE.md](docs/SESSION-PHASE2-STORAGE.md), [docs/SESSION-PHASE1-SETUP.md](docs/SESSION-PHASE1-SETUP.md). Screen 9 (network) is the one part of screens 7–11 not delivered |
| `os7-setup` toolchain (NativeAOT) | **works on both arches** — spike S2: 3.2–3.4 MB native binary, no .NET runtime needed at run time. The SDK is now in the build container: [docs/SESSION-S2-NATIVEAOT.md](docs/SESSION-S2-NATIVEAOT.md) |
| Installing to a disk | **works on arm64** — the install sequence is proven end to end by spike S3, ahead of any Setup code: [docs/SESSION-S3-ZFS-LUKS.md](docs/SESSION-S3-ZFS-LUKS.md) |
| Secure Boot + TPM2 unlock | **works on arm64** — spike S4: boots against the Microsoft UEFI CA, TPM2 auto-unlock, TPM-less fallback intact: [docs/SESSION-S4-SECUREBOOT-TPM.md](docs/SESSION-S4-SECUREBOOT-TPM.md) |
| TPM2 unlock across updates | **holds on arm64** — spike S6: survives an initramfs rebuild with PCR 7 unchanged; a Secure Boot policy change breaks it *detectably and recoverably*, and one re-enrolment restores it: [docs/SESSION-S6-UPDATE-CYCLE.md](docs/SESSION-S6-UPDATE-CYCLE.md) |
| `.devcontainer` / VS Code dev environment | stub, untested |
| CI (`.github/workflows`) | stub — never run; now the only way to build amd64 (see [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) #12) |
| Text-mode look (palette, font, keys) | **works on arm64** — spike S1: the field measures exactly `#0057ad` and the stripe exactly `#1289ff` on a real framebuffer, 126 test-card cells match the console font bitmap-for-bitmap, and all 16 arrow/F-keys decode. It also found that Ubuntu's `setvtrgb.service` silently replaces a palette set on the kernel command line: [docs/SESSION-S1-LOOK.md](docs/SESSION-S1-LOOK.md) |
| Console font (Fixedsys Excelsior → PSF) | **built, asserted and shipped** — `build/lib/build-console-font.sh` converts the pinned TTF at build time and fails the build if a glyph the UI draws is missing, blank, or has been collapsed onto another shape |
| Bootable ISO | **arm64: builds and boots** to a live session (bare Ubuntu, no OS/7 content yet). amd64: blocked on Apple Silicon, needs a native runner |

## Locked decisions

Treated as fixed. Do not re-architect without discussion — see "Open questions" for what's still genuinely undecided.

- **Base:** Ubuntu 26.04 LTS, codename `resolute` ("Resolute Raccoon"), x86_64 + arm64 — but the two are **different products**, see below.
- **GUI vs. headless:** one shared package base per architecture. On **x86_64**, the **installer** asks at setup time whether to install a GUI (GNOME) or stay headless — a setup-time choice, not just a runtime toggle.
  - GUI mode → GNOME, with dash-to-panel + arc-menu for a familiar feel (**not** a retro skin). Required for Microsoft Intune enrollment. **x86_64 only.**
  - Headless mode → no desktop packages. Not eligible for Intune (Linux enrollment requires GNOME); managed via Azure Arc-enabled Servers instead.
- **arm64 is server-only** (decided 2026-08-22). No GUI target, so no GNOME, no Calamares and no Microsoft desktop stack in the arm64 image — Azure Arc is its only management path. This also matches upstream reality: Microsoft ships no arm64 Linux Edge, and `intune-portal` / `microsoft-identity-broker` are x86_64-only, so an arm64 GUI could never have been Intune-enrolled.
  - **Consequence, resolved 2026-08-22:** Calamares is a GUI installer and could not install arm64. It has been replaced by `os7-setup`, a text-mode installer that serves both architectures — see Installer below and [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md).
- **Intune compatibility is a hard requirement, not a feature** (decided 2026-08-22). On the x86_64 GUI product, a design that cannot pass Intune compliance is not shippable, and **Intune's constraints outrank OS/7's technical preferences** wherever the two collide. Verified against [Microsoft's Linux compliance settings reference](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-linux-settings) on 2026-08-22. What it currently dictates:
  - **Ubuntu Desktop 26.04 LTS is officially supported**, x86/64 only, physical or Hyper-V. The base choice is confirmed from Microsoft's side, and so is arm64-is-server-only.
  - **Disk encryption must go through `dm-crypt`.** Microsoft: *"Intune recognizes any encryption system that uses the underlying dm-crypt subsystem […] The preferred method […] is to use the LUKS format with the cryptsetup tool."* ZFS **native** encryption is therefore disqualified — it would report every managed device as unencrypted. See Storage below.
  - **`/boot` and `/boot/efi` are explicitly exempt** from the encryption check, which is what makes an unencrypted ESP and boot pool acceptable.
  - **`/etc/os-release` must stay Ubuntu-identifiable.** Intune's *Allowed distributions* rule matches on distribution type and version. Brand `NAME` / `PRETTY_NAME` / `HOME_URL`; keep `ID=ubuntu`, `ID_LIKE=ubuntu`, `VERSION_ID="26.04"`. Rebranding `ID` would make every device fail the rule. **Resolved 2026-08-23:** the OS/7 product identity goes in `IMAGE_ID` / `IMAGE_VERSION` instead — standard os-release fields for exactly this case — so nothing has to be traded against Intune. See [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) §3.5.
  - **GNOME and Microsoft Edge stay mandatory** for GUI installs — Microsoft requires both for enrollment; they are not optional extras.
  - **Rule for future changes:** anything touching disk layout, encryption, OS identity, desktop or browser is checked against Intune's live docs *first*. Do not discover a compliance failure at a customer.
- **Storage:** ZFS root everywhere, using the GA-kernel-matched prebuilt ZFS module (not `zfs-dkms`), so kernel and ZFS ship in lockstep. **ZFS is the only filesystem OS/7 installs** — the sole non-ZFS filesystem on disk is the FAT32 EFI System Partition, which UEFI firmware mandates.
  - **Encryption: LUKS2 *underneath* ZFS** (decided 2026-08-22), forced by the Intune requirement above. LUKS is a block layer, not a filesystem: the stack is `partition -> LUKS2 -> zpool -> datasets`, and ZFS keeps snapshots, rollback, compression, checksums and boot environments unchanged. Trade-off accepted: no per-dataset encryption and no raw encrypted `zfs send`. Do **not** also enable ZFS native encryption — that is double encryption for no gain.
  - **Boot layout:** shim + Canonical-signed GRUB, so Secure Boot works out of the box. GRUB reads ZFS read-only, which requires the standard unencrypted `bpool` for `/boot` alongside the encrypted `rpool`. Both are ZFS. Full reasoning and the ZFSBootMenu alternative: [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md).
  - **Swap is never on ZFS** — swap-on-zvol still deadlocks upstream. Default is zram (RAM only, nothing on disk); a plain swap partition is opt-in for hibernation.
  - **Known risk:** OpenZFS on the Linux 7.0 kernel (Ubuntu 26.04's default) has been logging an "EXPERIMENTAL / SERIOUS DATA LOSS may occur" warning — see upstream issue [openzfs/zfs#18488](https://github.com/openzfs/zfs/issues/18488). Validated 2026-08-22 — not a real defect, ZFS root confirmed safe to build on: [docs/SESSION-0-ZFS-VALIDATION.md](docs/SESSION-0-ZFS-VALIDATION.md).
- **Shell:** bash stays the actual system/login shell (cron, systemd, dpkg hooks, and Intune's bash-based custom compliance scripts all assume it's there and working). PowerShell 7 auto-launches as the visible, interactive shell for every human session — the lived experience is "PowerShell by default" without breaking anything that expects bash underneath.
  - PowerShell itself updates through the **same** OS7 release train as the rest of the system (`Update-OS7`, new ZFS boot environment), not a standalone `apt upgrade powershell` — keeps the whole system atomically rollback-safe.
- **Identity:**
  - `authd` + `authd-msentraid` for native Microsoft Entra ID login. **Correction (verified 2026-08-22):** `authd` is in the Ubuntu archive, but `authd-msentraid` is **not** — it is a Canonical-verified **snap** (0.4.1, both architectures). No PPA is needed either way, but the delivery mechanism differs; see [installer/README.md](installer/README.md).
  - GUI installs: Microsoft Intune enrollment (requires GNOME + Microsoft Edge — both mandatory per Microsoft's current docs, not optional extras). Compliance is a hard requirement — see "Intune compatibility" above.
  - Headless installs: Azure Arc-enabled Servers as the management path. Verify current Ubuntu 26.04 support against Microsoft's live Arc prerequisites page before treating this as locked.
- **Updates:** curated release train over ZFS boot environments, driven by the OS7 PowerShell module: `Set-OS7Mode`, `Update-OS7`, `Restore-OS7`. Specified in full — mechanics, versioning, drift, cadence — in [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md). What is settled and what is not:
  - **Ubuntu security patches within 26.04 need no OS/7 code change.** OS/7 is real Ubuntu; what changes is the *delivery* (into a cloned boot environment), not the source. Four things do break under ordinary patches, all of them consequences of OS/7's own design — see the plan §2.2, and Open question 7 below for the worst of them.
  - **Ubuntu 26.04 → 28.04 is a product generation, not an update.** Five pins in five files plus two external dependencies OS/7 does not control (Microsoft publishing a matching suite; Intune re-verification). Budgeted once per LTS, never automatic. The mitigation is to centralise the pins in one `build/config/os7-release.conf`, not to avoid the work.
  - **One product version number: `Major.Minor.Patch.Build`** (decided 2026-08-23, U2), where **Major is the Ubuntu LTS generation** — `1.x` = 26.04, `2.x` = 28.04 — Minor is an OS/7 feature release, Patch is the maintenance train, Build is the CI build and the out-of-band hotfix field. Alongside it, a **release manifest** at `/usr/lib/os7/release.json` lists what the release consists of (archive snapshot, kernel, ZFS, PowerShell, .NET, `os7-setup`, OS7 module, Microsoft components) — the number identifies the state, the manifest describes it. Components are *not* mapped one-per-field; that breaks as soon as a component has its own versioning.
  - **Every release pins the archive to one timestamp** (decided 2026-08-23, U4). `snapshot.ubuntu.com` serves `resolute`, `resolute-updates` and `resolute-security` addressed by timestamp — verified 2026-08-23, **including arm64 under the same path**, so pinning *removes* the archive/ports split in `build/config/auto/config` rather than adding work, and no private mirror is needed. This is not separable from the version number: without a pinned archive, two machines reporting the same version hold different packages and the number is worse than none, because it will be trusted. Canonical publishes no retention guarantee, so a release also archives the `.debs` it actually installs (UL6).
  - **Product identity goes in `IMAGE_ID` / `IMAGE_VERSION`** (decided 2026-08-23, U3), leaving `ID=ubuntu`, `ID_LIKE=ubuntu` and `VERSION_ID="26.04"` untouched for Intune. This closes SETUP-PLAN's D8 without a trade-off. Note that `BUILD_ID` is the *wrong* field: systemd defines it as the original installation base, which by design does not move during updates. `/etc/os-release` is a `base-files` conffile, so the branding is re-asserted after every update rather than written once at install.
  - **Release cadence is not yet decided (U5).** Proposed: a monthly `stable` train plus an out-of-band hotfix channel on the Build field. A pinned archive means security patches wait for the next release, which is a regression against plain Ubuntu unless the hotfix path exists — so this needs a business decision, not a technical one.
  - **`apt` stays present and usable**, because bash stays the system shell — so `Get-OS7Version` must detect drift and report it rather than assert a version it cannot back up. Same for the `authd-msentraid` snap, which self-refreshes on snapd's schedule unless held.
  - **Command surface:** `Set-OS7Mode` means GUI/headless only; the release channel gets its own cmdlet. This resolves the ambiguity the stub documents about itself in `powershell/OS7/OS7.psm1`.
- **Target audience:** IT admins, MSPs, and organizations running a Microsoft-centric stack — not a consumer desktop distro.
- **Branding:** classic/retro visual identity (logo, boot splash, website) in up in blue Orange `#ff6912` — applies to marketing/branding only, **not** to the GNOME desktop itself.
- **Console font: [Fixedsys Excelsior](https://github.com/kika/fixedsys)** (decided 2026-08-22) — the default font for `os7-setup` **and** for the installed system in **non-GUI mode**. Public domain / CC0, so it ships inside the ISO with no obligation. It is a deliberate simulation of the 8×16 bitmap font DOS and Windows used, drawn to be rendered without antialiasing at 16 px, which is what makes the text-mode look reproduce rather than approximate.
  - The console cannot read TTF, so the image build converts it to **PSF** (`otf2bdf` → `bdf2psf`) and ships two sizes: 8×16 and a pixel-doubled 16×32 for modern panels. Toolchain lives in the build container, not in the image.
  - **Pinned**, fetched at build time rather than vendored, the same shape as PowerShell in hook 0020: `v3.09.10` / `FSEX302.ttf` / 580 724 bytes / SHA256 `842f8fbf80f57d867aeb1d2988140d3ea8b4718e5f687035b0a3b66756df3899`.
  - **Built and verified since 2026-08-24** by `build/lib/build-console-font.sh`. Two things the conversion had to be taught, both found by spike S1 and neither visible in a coverage count: `bdf2psf`'s stock equivalences hand `═` the glyph of `─` and collapse the whole double-line box, and the font draws 15 pixels of ink in a 16-pixel cell, which leaves a one-pixel gap at every cell boundary and makes every vertical box border dashed.
  - **Verified 2026-08-22:** its cmap carries Box Drawing `U+2500–257F` complete (128/128) and Block Elements `U+2580–259F` complete (32/32). That was the real risk — upstream advertises only the windows-125x codepages, which contain no box-drawing characters, and the entire installer UI is built from them.
  - PSF caps at 512 glyphs against the font's 6 193 codepoints, so the shipped subset is Latin-focused (English + German). Does **not** apply to the GNOME desktop.
- **Dev environment:** VS Code Dev Container wrapping the Docker-based build container; `.vscode/tasks.json` wires up `docker build`, `lb config`, `make build-amd64` / `make build-arm64`. Note that the *native* architecture is the fast one on any given machine — see "Building" below; on Apple Silicon the amd64 ISO is built in a QEMU x86 VM instead of under Docker emulation.
- **CI:** GitHub Actions — `amd64` on standard hosted runners, `arm64` on the free native arm64 hosted runners (public repo), so nothing builds under QEMU emulation.
- **Installer: `os7-setup`** (decided 2026-08-22, replacing Calamares) — an OS/7-authored, keyboard-driven **text-mode** installer written in C#/.NET and published as a NativeAOT binary, styled after MS-DOS 6.22 Setup and the Windows 2000 text-mode Setup phase. Field colour `#0057ad` (up in blue `#1289ff` darkened to WCAG AAA against white text), with `#1289ff` as the title stripe and progress fill on every screen.
  - **One installer serves both architectures**, which is why Calamares went: it is a Qt GUI application and could never have installed the desktop-less arm64 image. Subiquity is no longer needed either.
  - Nothing is implemented yet. Design, limitations, decisions and the phased plan — including the spikes that must pass before any installer code is written: [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md).
  - **Phase 0 is complete.** S2, S3 and S4 passed 2026-08-23, S1 on 2026-08-24, so the gate on writing installer code is open. `os7-setup` publishes as a NativeAOT binary on both architectures (3.2–3.4 MB, no .NET runtime needed at run time) — [docs/SESSION-S2-NATIVEAOT.md](docs/SESSION-S2-NATIVEAOT.md).
  - **Phase 1 is done** — [docs/SESSION-PHASE1-SETUP.md](docs/SESSION-PHASE1-SETUP.md). The TUI layer, screens 1–3 and 12, the error screen and logging, on tty1 from a systemd unit, with the language/keyboard/timezone lists read out of the system's own data (154/99/313 in the current image) rather than hand-maintained. `installer/testing/run-phase1.py` walks the flow in a VM and checks every screen by reading it back through the console font the image ships — and boots the *live* entry separately, to prove Setup's unit leaves an ordinary live session alone (L14).
  - **The look is measured, not asserted** — [docs/SESSION-S1-LOOK.md](docs/SESSION-S1-LOOK.md). Field `#0057ad` and stripe `#1289ff` exact on a framebuffer; the box-drawing and block glyphs verified against the font pixel for pixel; every arrow and F-key decoded. The palette ships as `/etc/vtrgb`, **not** on the kernel command line: Ubuntu's `setvtrgb.service` replaces that before the console is ever displayed.
  - **Storage and boot:** the install sequence Setup's storage step will drive is written and proven end to end on arm64, and the installed system boots under Secure Boot with TPM2 auto-unlock — [installer/spikes/](installer/spikes/), [docs/SESSION-S3-ZFS-LUKS.md](docs/SESSION-S3-ZFS-LUKS.md), [docs/SESSION-S4-SECUREBOOT-TPM.md](docs/SESSION-S4-SECUREBOOT-TPM.md).

## Microsoft technology scope (v1 draft)

| Tier | Components | GUI-mode only? |
|---|---|---|
| Core (non-negotiable) | PowerShell 7 (installed from the pinned upstream tarball — Microsoft ships no arm64 `.deb`), .NET SDK/Runtime (`dotnet-sdk-10.0`, from the **Ubuntu** archive — resolute has .NET 10, not 9), `authd` + `authd-msentraid` | No |
| Core for GUI installs | Microsoft Edge, Microsoft Intune app (+ `microsoft-identity-broker`, which brokers the Entra sign-in enrollment needs) — **x86_64 only, no arm64 builds exist** | Yes |
| Core for headless installs | Azure Connected Machine agent (Azure Arc) — available for x86_64 **and** arm64 | Headless only |
| Recommended addition | Azure CLI | No |
| Recommended addition, GUI only | VS Code — default to **VSCodium** (MIT, no proprietary MS additions); official MS build optional/opt-in | Yes |
| Deliberately excluded from v1 | OneDrive sync (no official Linux client, only a community GPLv3 client), Microsoft Defender for Endpoint (own tenant licensing) | — |

## Open questions

Genuinely undecided — flag before making irreversible choices in a Claude Code session:

1. ~~**ZFS-on-kernel-7.0 risk**~~ — **RESOLVED 2026-08-22, proceed.** Validated hands-on on both architectures: the warning is present (kernel `7.0.0-28-generic`, ZFS `2.4.1-1ubuntu5`), but it marks build *provenance*, not a defect — confirmed by the OpenZFS and Ubuntu ZFS maintainers on the upstream issue. A real pool passed create / write / export / import / scrub / snapshot / rollback with zero errors. Upstream fixed this in ZFS 2.4.2; 26.04 has not received the SRU yet. Full evidence and caveats: [docs/SESSION-0-ZFS-VALIDATION.md](docs/SESSION-0-ZFS-VALIDATION.md).
2. **Azure Arc-enabled Servers + Ubuntu 26.04** — exact current support status should be checked against Microsoft's live prerequisites page before it's treated as a locked decision.
3. ~~**Calamares ZFS module maturity**~~ — **MOOT 2026-08-22.** Calamares was replaced by `os7-setup` ([installer/SETUP-PLAN.md](installer/SETUP-PLAN.md)). The underlying hard part moved to spike S3 — a ZFS-on-LUKS root that actually boots — which was the project's highest-risk unknown. ~~**S3**~~ — **RESOLVED 2026-08-23 on arm64.** OS/7 now installs to a disk and boots from it: LUKS2 passphrase prompt, then a login prompt served from `rpool/ROOT/os7_*`, with the designed dataset layout intact. Sequence, harness and findings: [docs/SESSION-S3-ZFS-LUKS.md](docs/SESSION-S3-ZFS-LUKS.md). **amd64 remains uninstalled and unvalidated**, because no amd64 ISO has been built yet.
   - **Newly open, from the Intune work:** does Intune's encryption check treat the unencrypted `bpool` partition as a non-compliant fixed writable disk? Microsoft exempts `/boot`, but `bpool` is a ZFS pool member rather than a directly mounted partition, so the exemption may not be recognised. Verify in the first real enrollment test, before it becomes a customer's discovery.
   - ~~**Newly open, from the Intune work:** `/etc/os-release` branding vs. the *Allowed distributions* rule~~ — **RESOLVED 2026-08-23, no trade-off.** `IMAGE_ID=os7` + `IMAGE_VERSION=<version>` carry the product identity; `ID` / `ID_LIKE` / `VERSION_ID` stay Ubuntu for Intune. This also closes D8 in [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md). Reasoning and the systemd citation: [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) §3.5.
4. **`authd-msentraid` cannot be put in the image yet.** `authd` is in the archive; its Entra broker is a Canonical-verified **snap** (0.4.1, both architectures), and seeding a snap into a live-build image is unsolved (`snap download` + `snap ack` into `/var/lib/snapd/seed` plus a seed manifest, none of which plain live-build supports). Until it is, **no OS/7 build can log in with Entra ID** — a headline feature. Not an installer problem; an image one. Detail: [installer/README.md](installer/README.md).
5. **License** — this README currently assumes MIT for OS7's own tooling/scripts (matching up in blue's other public repos); Ubuntu/upstream components keep their own licenses regardless. Confirm before the first public commit.
6. ~~**Is `/var` inside the boot environment?**~~ — **RESOLVED 2026-08-23 (U6 / D10): split, not placed.** Package state (`/var/lib/dpkg`, `/var/lib/apt`, `/var/cache`) stays inside the boot environment, because it describes exactly the `/usr` that rolls with it. Everything a rollback should not un-say moves out to `rpool/DATA`: logs, spool, workload data, snapd, and the state of the agents holding this device's identity in Entra, Intune and Arc — **the tenant has no rollback**, so a machine returning with a stale identity or an expired certificate is a worse problem than the update that caused it. Deciding rule: a path belongs in the BE only if rolling it back makes the system *more correct*. Layout: [installer/SETUP-PLAN.md](installer/SETUP-PLAN.md) §4.4; reasoning: [docs/RELEASE-AND-UPDATE-PLAN.md](docs/RELEASE-AND-UPDATE-PLAN.md) §4.4.
7. **Where does the recovery key live?** (U8. Raised 2026-08-23, **narrowed the same day by spike S6**.) TPM2 auto-unlock seals against PCR 7, so a `shim` or `dbx` update — an entirely routine Ubuntu patch — invalidates it and drops every machine back to a passphrase prompt. S6 measured what that actually looks like ([docs/SESSION-S6-UPDATE-CYCLE.md](docs/SESSION-S6-UPDATE-CYCLE.md)): the failure names its own cause, the passphrase still works, and one `systemd-cryptenroll` against the new PCR 7 restores auto-unlock with no reinstall. So the recovery *mechanism* exists and is demonstrated. What does not exist is the **escrowed recovery passphrase** it needs to run unattended — Entra, an OS/7-managed store, or Intune's own escrow. Still blocking for fleet deployment, but now a key-management design rather than an unknown.

## Working on this repository

[CLAUDE.md](CLAUDE.md) is the orientation file: where authority lives, the
commands that actually work, how work is done here, and the traps that cost the
most. [docs/HANDOFF.md](docs/HANDOFF.md) is the state of play and what to do
next; [docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) is every trap found so far and
is worth reading before debugging anything.

## Repository layout

```
os7/
├── build/config/auto/config   # live-build configuration (DISTRIBUTION=resolute)
├── powershell/OS7/            # OS7 PowerShell module (Set-OS7Mode, Update-OS7, Restore-OS7)
├── installer/                 # os7-setup design (SETUP-PLAN.md) + Phase 0 spikes
├── docs/                      # plans, handoff, build notes, session results
├── .devcontainer/             # VS Code Dev Container definition
├── .vscode/                   # tasks.json for the local build workflow
└── .github/workflows/         # CI: amd64 + arm64 ISO builds
```

## Building

**Which command depends on your host architecture.** This is not a preference —
Docker's amd64 emulation on Apple Silicon cannot unpack a Debian rootfs
(`tar: Cannot mkdir: Function not implemented`), so the x86 build has to happen
somewhere that runs real x86 code. See
[docs/BUILD-NOTES.md](docs/BUILD-NOTES.md) #12.

| Your machine | arm64 ISO | amd64 ISO |
|---|---|---|
| **x64 Windows / Intel Mac / x86_64 Linux** | `make build-arm64` — emulated; **untested on an x86 host** (different emulation path than the broken one, so it may well work) | **`make build-amd64`** — native, fast |
| **Apple Silicon Mac** | **`make build-arm64`** — native, fast | `make build-amd64-vm` — full QEMU x86 VM, takes hours |

In short: **each architecture is fast on its own kind of hardware.** Build the
one that matches your machine for day-to-day work; reach for the slow path only
when you need the other architecture's ISO.

`make build-amd64` refuses early on a non-x86_64 host and tells you to use
`build-amd64-vm`, so you cannot lose 20 minutes reaching a known failure.
`make build-amd64-vm-reset` throws the builder VM away.

Prerequisites: Docker Desktop (or Docker Engine) running. On Apple Silicon, the
VM path additionally needs QEMU (`brew install qemu`).

Output lands in `out/`. See [docs/HANDOFF.md](docs/HANDOFF.md) for what works
today and what to do next, and `installer/SETUP-PLAN.md` for the installer.

---

Maintained by [up in blue GmbH](https://github.com/upinblue).
