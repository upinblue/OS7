# OS/7 Setup — text-mode installer plan

**Status: plan only. Nothing below is implemented.** This document answers three
questions asked on 2026-08-22 and turns the answers into a phased plan:

1. Can OS/7's installer look like MS-DOS 6.22 Setup / the Windows 2000
   text-mode ("non-GUI") Setup phase, in up in blue blue `#1289ff`?
2. Can a text-mode installer cover *everything* an installer has to do —
   including partitioning — with **ZFS as the only filesystem**?
3. How much of it can be Microsoft stack (.NET / C#) at that point in the
   install?

Short answers: **yes**, **yes with three unavoidable exceptions**, and
**most of it, but not the storage primitives**. Details below.

This supersedes the Calamares decision in [../README.md](../README.md) and in
[README.md](README.md) (this directory). See "What this changes" at the end.

---

## 1. Verdict

| Question | Answer |
|---|---|
| DOS / Win2000-text-phase look on a Linux console | **Yes**, and more faithfully than expected — the Linux VT palette is programmable, so an exact brand colour is a literal palette entry, not an approximation. |
| Exact brand colour | **Yes on the kernel console** (`vt.default_red/grn/blu`, `setvtrgb`). **No over serial/SSH** unless the client does truecolor — there we fall back. Note D5: the *field* is `#0057ad`, a darkened `#1289ff`, because white text on `#1289ff` is only 3.47 : 1 (§2.2). `#1289ff` is the title stripe on every screen. |
| Can text mode do partitioning | **Yes.** Partitioning is `sgdisk` + `zpool create`; a GUI adds nothing a keyboard-driven list can't do. Windows NT/2000 did exactly this in text mode. |
| ZFS as the only filesystem | **Almost.** A FAT32 EFI System Partition is mandatory (UEFI firmware spec). With zram swap, it is the only non-ZFS *filesystem* on disk — but encryption adds a **LUKS2 container underneath** `rpool` (D3, §4.5), which is a block layer rather than a filesystem, and a `bpool` for GRUB (D1, §5), which is still ZFS. |
| Written in C# / .NET | **Yes** for UI, flow, state, logging and orchestration. **No** for the storage primitives — there are no libzfs/libblkid bindings for .NET, so Setup drives `zpool`/`zfs`/`sgdisk` as processes. Calamares does the same thing; this is not a downgrade. |
| Works on arm64 too | **Yes — and this is the big win.** One installer for both architectures. It closes [README.md](README.md) open problem #1 (arm64 had no install path because Calamares is a Qt GUI app). Subiquity is no longer needed. |

The single largest engineering risk is **not** the UI. It is ZFS-root on LUKS +
bootloader + Secure Boot (§4.5, §5), which is the same risk the Calamares plan
had, minus Calamares' help.

---

## 2. The look — how each element is actually produced

Reference: MS-DOS 6.22 Setup and the Windows 2000 text-mode Setup phase.
Both share one design language:

* full-screen blue field
* row 0: title in white, row 1: a solid light bar under it
* body: white text, single-line boxes, selection = black on light grey
* last row: light-grey status bar, black text, `ENTER=Continue  F1=Help  F3=Exit`

### 2.1 Colour — the mechanism

The Linux virtual console has a **programmable 16-entry palette**. Two ways in,
both needed:

| When | Mechanism |
|---|---|
| From the first kernel frame | Kernel cmdline `vt.default_red=`, `vt.default_grn=`, `vt.default_blu=` (16 comma-separated 0–255 values each) plus `vt.color=0x4f` (background 4 = our blue, foreground 15 = bright white). Set on the **Install OS/7** GRUB entry only, so the live-desktop entry keeps normal colours. |
| At runtime, e.g. to switch to high-contrast | `setvtrgb <file>` from `kbd` — 3 lines of 16 comma-separated values (R, G, B). |

Palette (**decided, D5**; slots 1,2,3,5 keep their defaults so kernel messages
still look normal):

| Idx | Colour | Use | Background-capable? |
|---|---|---|---|
| 0 | `#000000` black | text on the status bar and on selections | yes |
| 4 | `#0057ad` **OS/7 field blue** | the field — `#1289ff` darkened, identical hue | yes |
| 6 | `#1289ff` **up in blue** | title stripe, progress bar fill, accents | yes |
| 7 | `#c0c0c0` light grey | status bar, selection bar | yes |
| 15 | `#ffffff` white | body text, box borders, title | — |
| (alt 4) | `#003366` | high-contrast field, toggled with `F5` | yes |

**Why low indices:** the Linux console renders only **8 background colours**
(0–7); 8–15 are foreground-only. Both blues are used as backgrounds, so both
need a low slot. Index 4 ("blue") takes the field; index 6 ("cyan") is
repurposed for the brand blue — it is the least load-bearing slot for kernel
output, which uses red for errors and grey/white for everything else.

### 2.2 Contrast — measured, and why the field is a darkened blue

`#1289ff` with white text is **3.47 : 1**. WCAG AA wants 4.5 : 1 for body text;
it only clears the 3 : 1 large-text bar. The original DOS/Win2k blue is dark
precisely because that is what a full screen of white text needs.

Darkening `#1289ff` along its own hue (HSL 209.9°, saturation 100%, lightness
53.5%) gives a ladder — every entry below is the *same blue*, only dimmer:

| HSL L | Hex | White text | Verdict |
|---|---|---|---|
| 53.5% | `#1289ff` (brand, as given) | 3.47 : 1 | fails AA |
| 44% | `#0071e0` | 4.74 : 1 | AA |
| 38% | `#0061c2` | 6.00 : 1 | AA |
| **34%** | **`#0057ad`** | **7.07 : 1** | **AAA — chosen** |
| 20% | `#003366` | 12.58 : 1 | AAA — high-contrast mode |
| — | `#0000a8` (original VGA blue) | 13.41 : 1 | for reference |

**Decided (D5):** the field is **`#0057ad`** — the same hue and saturation as
`#1289ff`, 20 points darker, clearing WCAG **AAA** for body text. It reads as
"a darker up in blue", not as a different colour, and it stays visibly more
vivid than the 1990s original, so Setup looks like OS/7 rather than a Windows
2000 clone.

`#1289ff` itself is **not** demoted to an accent that nobody sees. It is:

* the **full-width stripe under the title** on every single screen — where the
  original had a plain light-grey rule, OS/7 puts the brand colour;
* the **progress bar fill**;
* every accent and emphasis mark.

So the brand colour appears on every screen, at the top, and the surface people
actually read from is AAA. `F5` swaps the field to `#003366` (12.58 : 1) for
high-contrast/projector use; the `#1289ff` stripe stays in both modes.

### 2.3 Glyphs and geometry

* **Box drawing** (`┌ ─ ┐ │ └ ┘ ═ █`): present in every console font Ubuntu
  ships and in the kernel's built-in fonts. No custom font strictly required.
* **Cell size.** Ubuntu's kernel has `CONFIG_FONT_TER16x32` enabled (Launchpad
  #1819881), so `fbcon=font:TER16x32` on the cmdline gives 16×32 cells with no
  userspace font loading — chunky and period-correct on a modern panel.
* **80×25 is not obtainable everywhere.** UEFI hands us whatever GOP mode the
  firmware likes. At 1280×800 with TER16x32 you get exactly 80×25; at 1920×1080
  you get 120×33.

  **Layout rule:** chrome is **full-bleed** (title row and status row always
  touch the screen edges, as in the original), body content is laid out in a
  column capped at 80 cells and centred. This keeps the look at any geometry and
  avoids 200-character-wide paragraphs. `os7.setup.geometry=80x25` forces a
  letterboxed exact-80×25 canvas for screenshots and marketing.

### 2.4 The rest of the boot is blue too

Cheap authenticity, worth doing in phase 4:

* GRUB `gfxterm` theme on the ISO in the same palette (the boot menu is the
  first thing anybody sees).
* `plymouth.enable=0 quiet loglevel=0` on the Install entry, so nothing
  scrolls over the blue.
* A systemd unit that prints `Setup is inspecting your computer's hardware
  configuration...` while udev settles and pools are scanned — the Win2k line,
  and it is honest about what is actually happening.

### 2.5 Where it does *not* work

| Surface | Result |
|---|---|
| Kernel console / fbcon (the normal case) | Exact palette — `#0057ad` field, `#1289ff` stripe. |
| Serial console (headless servers — a real OS/7 target) | Palette cannot be set. Emit 24-bit SGR (`ESC[48;2;18;137;255m`); a truecolor-capable client shows it exactly, others degrade to their own blue. |
| SSH into a running Setup | Same as serial. |
| The Linux VT itself receiving 24-bit SGR | fbcon accepts the sequence but snaps it to the nearest of its 16 palette entries — so on the VT the *palette* is the mechanism, not SGR. Setup must pick per surface, not emit both. |

---

## 3. Screen inventory

Windows 2000's text phase handed off to a GUI phase. We have no GUI phase, so
the text mode has to carry what Win2k did in its GUI stage as well (computer
name, admin account, network). That is not a problem — NT 3.x did all of it in
text — but it is why the screen list is longer than Win2k's text phase.

| # | Screen | Modelled on | Keys |
|---|---|---|---|
| 1 | Welcome to Setup | Win2k "Welcome to Setup" | `ENTER` `R` `F3` |
| 2 | Licence | Win2k EULA | `F8` `ESC` `PGDN` |
| 3 | Regional settings (language, keyboard, timezone) | MS-DOS 6.22 settings box | arrows, `ENTER` `F1` `F3` |
| 4 | Select a disk | Win2k partition list | arrows, `ENTER` `F5` `F3` |
| 5 | Storage layout (topology, encryption, swap) | MS-DOS 6.22 settings box | arrows, `ENTER` |
| 6 | Confirm — destructive | Win2k format warning | `F` `ESC` |
| 7 | Computer name and administrator account | Win2k GUI phase, in text | `TAB` `ENTER` |
| 8 | Install mode: GUI or Headless (amd64 only) | — | arrows, `ENTER` |
| 9 | Network (headless: DHCP/static) | Win2k network settings | `TAB` `ENTER` |
| 10 | Copying files | Win2k copy phase | — |
| 11 | Configuring the system | Win2k "Setup is configuring..." | — |
| 12 | Setup is complete | Win2k restart prompt | `ENTER` |
| E | Setup cannot continue (error) | Win2k blue error screen | `ENTER` `F2` `F3` |

`R` on screen 1 is the interesting one. Win2k's `R=Repair` maps almost exactly
onto a ZFS concept: **import an existing `rpool` and install into a new boot
environment beside the current one**, leaving `rpool/USERDATA` untouched. That
is an upgrade/repair path Calamares would never have given us. Phase 6.

### 3.1 Mockups

These are the visual spec. `═` stands for the solid **`#1289ff`** stripe under
the title (rendered as full-width reverse-video cells, not as a character).

**1 — Welcome**

```
 OS/7 Setup
 ═══════════════════════════════════════════════════════════════════════════════

     Welcome to Setup.

     This portion of the Setup program prepares OS/7 to run on your
     computer.

       • To set up OS/7 now, press ENTER.

       • To repair or extend an existing OS/7 installation, press R.

       • To quit Setup without installing OS/7, press F3.



 ENTER=Continue   R=Repair   F3=Quit
```

**4 — Select a disk**

```
 OS/7 Setup
 ═══════════════════════════════════════════════════════════════════════════════

     Setup will install OS/7 on the disk selected below.

     Use the UP and DOWN ARROW keys to select a disk, then press ENTER.

     ┌──────────────────────────────────────────────────────────────────────┐
     │  nvme0n1   SAMSUNG MZVL21T0HCLR-00B    953 GB   GPT, 3 partitions    │
     │  sda       ATA WDC WD10EZEX-08W        931 GB   empty                │
     │  sdb       SanDisk Cruzer Blade       14.4 GB   -- SETUP MEDIUM --   │
     └──────────────────────────────────────────────────────────────────────┘

     Every partition on the selected disk will be destroyed.

 ENTER=Select   F5=Advanced   F3=Quit
```

The medium Setup booted from is listed but never selectable. F5 opens the
per-partition view (create/delete/keep free space) for the dual-boot case.

**5 — Storage layout**, the MS-DOS 6.22 homage:

```
 OS/7 Setup
 ═══════════════════════════════════════════════════════════════════════════════

     Setup will use the following storage settings:

     ┌──────────────────────────────────────────────────────────────────────┐
     │   Disk:            nvme0n1  (953 GB)                                 │
     │   Layout:          single disk                                       │
     │   EFI partition:   512 MB   FAT32                                    │
     │   Boot pool:       2 GB     ZFS  (bpool, GRUB-readable features)     │
     │   Root pool:       950 GB   ZFS  (rpool)                             │
     │   Encryption:      LUKS2, aes-xts-plain64  (TPM2 + passphrase)       │
     │   Swap:            zram, 50% of RAM (no swap on disk)                │
     ├──────────────────────────────────────────────────────────────────────┤
     │   The settings are correct.                                          │
     └──────────────────────────────────────────────────────────────────────┘

     If all the settings are correct, press ENTER.

     To change a setting, press the UP or DOWN ARROW keys to select it.
     Then press ENTER to see alternatives.

 ENTER=Continue   F1=Help   F3=Exit
```

**10 — Copying files**

```
 OS/7 Setup
 ═══════════════════════════════════════════════════════════════════════════════



           Setup is copying files to the OS/7 boot environment.


           ┌──────────────────────────────────────────────────┐
           │██████████████████████████                        │
           └──────────────────────────────────────────────────┘
                                47%

           Copying:  /usr/lib/aarch64-linux-gnu/libLLVM.so.20.1


 Please wait...
```

**E — Setup cannot continue.** Errors get a screen, never a scrolled stack
trace. Every error screen names the command that failed and its output:

```
 OS/7 Setup
 ═══════════════════════════════════════════════════════════════════════════════

     Setup cannot continue.

     The selected disk (nvme0n1) already contains a ZFS pool named 'rpool'
     which Setup could not import.

       zpool import -f -N -R /target rpool
       cannot import 'rpool': pool was previously in use from another system

     A full log has been written to /var/log/os7-setup/setup.log
     Press F2 to write the log to removable media.

 ENTER=Back   F2=Save log   F3=Quit
```

---

## 4. "ZFS only" — what is achievable and what is not

Four things cannot be ZFS. Ranked by how unavoidable they are:

### 4.1 The EFI System Partition — unavoidable

UEFI firmware can only read FAT from the ESP. That is the specification, not a
Linux limitation. **512 MB, FAT32, mounted at `/boot/efi`.** There is no
configuration in which this goes away on a UEFI machine.

### 4.2 The boot pool (`bpool`) — avoidable, but only by giving up Secure Boot

GRUB can read ZFS, but only the read-only-compatible feature set. Ubuntu's
answer, and the shape its own ZFS-root installs use, is a second small pool
created with a restricted feature list holding `/boot`. `bpool` **is ZFS**, so
this does not violate "ZFS only" — but it is a wart: it can never be
`zpool upgrade`d, and it is a second pool to keep healthy.

The alternative that removes it is **ZFSBootMenu**: an EFI executable with a
full ZFS implementation that boots kernels straight out of `rpool`, understands
boot environments natively, and can unlock ZFS native encryption at boot. It
would give OS/7 a far better boot-environment story than GRUB. Its cost is
Secure Boot — see §5.

### 4.3 Swap — must not be ZFS

Swap on a zvol still deadlocks (openzfs/zfs#7734, open since 2018; reproduced
again on Ubuntu 25.10 in openzfs/zfs#18200, February 2026), and ZFS does not
support swapfiles.

**Default: `zram`** — compressed swap in RAM, nothing on disk. This is what
keeps "the only non-ZFS thing on disk is the ESP" true.
**Optional:** a plain swap partition, offered only if the user asks for
hibernation. Hibernation onto a system whose root is ZFS is its own risk; keep
it opt-in and documented.

### 4.4 Resulting on-disk layout

```
nvme0n1
 ├─ p1   512 MB   EF00  FAT32   /boot/efi     unencrypted — Intune ignores it
 ├─ p2     2 GB   BF00  ZFS     bpool         unencrypted — Intune ignores it
 └─ p3     rest   8309  LUKS2   os7_root      encrypted (§4.5, D3)
                         └─ ZFS rpool
```

Dataset layout — this is OS/7's design decision, not something a tool hands us,
and it is what makes `Update-OS7` / `Restore-OS7` possible:

```
bpool/BOOT/os7_<id>                  -> /boot
rpool/ROOT/os7_<id>                  -> /            the boot environment
rpool/ROOT/os7_<id>/var              -> /var
rpool/ROOT/os7_<id>/var/log          -> /var/log
rpool/USERDATA/<user>_<uuid>         -> /home/<user>  OUTSIDE ROOT — survives rollback
rpool/USERDATA/root_<uuid>           -> /root
```

The critical property: **`USERDATA` sits outside `ROOT`**, so rolling back a bad
release does not roll back the user's files. Getting this wrong is the classic
boot-environment mistake and it cannot be fixed after the fact.

`<id>` naming: `os7_<release>_<yyyymmddHHMM>`, e.g. `os7_2026.08.1_202608221430`.
Pinned here because `Restore-OS7 -BootEnvironment` needs a scheme it can list
and sort, and the stub in `powershell/OS7/OS7.psm1` explicitly has none.

### 4.5 Encryption — DECIDED: LUKS2 under ZFS, not ZFS native (D3)

This closes this directory's [README.md](README.md) open problem #3. It was
decided by going and reading what Intune actually measures, which turned out to
be unambiguous. From Microsoft's own reference for Linux compliance settings
(page updated 2026-05-20):

> Intune recognizes any encryption system that uses the underlying **dm-crypt**
> subsystem […] The preferred method of setting up dm-crypt is to use the
> **LUKS** format with the **cryptsetup** tool.

ZFS native encryption does not go through dm-crypt. It would therefore report a
managed OS/7 desktop as **unencrypted**, and every device would fail the
*Require Device Encryption* compliance rule. That is not a technical failure —
the data would be perfectly encrypted — but it is a product failure, and it
would be discovered by a customer, not by us.

So: **`rpool` lives inside a LUKS2 container.**

```
p3 → cryptsetup luksFormat → /dev/mapper/os7_root → zpool create rpool
```

Three things fall out of that, all good:

* **The ESP and `bpool` stay unencrypted, and that is explicitly fine.** The
  same Microsoft page lists what the compliance check ignores: read-only
  partitions, pseudo-filesystems, and *"the /boot or /boot/efi partitions"*.
  The layout in §4.4 is compliant as drawn.
* **TPM2 auto-unlock becomes possible** (`systemd-cryptenroll --tpm2-device=auto`,
  or Clevis). ZFS native encryption has no TPM story at all. On a managed fleet
  this is the difference between a passphrase prompt on every boot and none.
* Microsoft explicitly recommends *"setting up disk encryption while installing
  the operating system"* — which is exactly what an installer is for, and it is
  another argument against making encryption a post-install exercise.

What we give up, stated plainly: per-dataset encryption granularity, raw
encrypted `zfs send` streams, and the ability to have a dataset present but
locked. None of those are on OS/7's roadmap; compliance is.

**Do not enable both.** LUKS *and* ZFS native encryption is double encryption —
double the CPU, no extra security worth the name.

**One thing this does not settle (L18).** Microsoft exempts `/boot`, but `bpool`
is an unencrypted fixed writable partition holding a ZFS *pool member* rather
than a mounted filesystem. Whether the Intune agent maps it to `/boot` and
exempts it is not documented anywhere. It has to be observed in a real
enrolment, not reasoned about — and if it fails, D1 reopens, because the way out
is putting `/boot` inside `rpool` and switching to ZFSBootMenu.

**TRIM:** the LUKS container must be opened with `--allow-discards` (or
`discard` in `crypttab`) or ZFS TRIM never reaches the SSD. Standard, easily
forgotten, and it silently costs write endurance.

**Mirrors:** one LUKS container per member disk, all unlocked before import.
Standard, but it is extra work in the storage executor — note it, do not
discover it in Phase 2.

**Servers / arm64:** Azure Arc has no equivalent encryption compliance rule, so
encryption is optional there. Use the same LUKS2 path anyway when it is enabled —
one code path, one test matrix.

### 4.6 Intune compatibility is a hard requirement

Recorded in the root [../README.md](../README.md) as a locked decision on
2026-08-22: on the x86_64 GUI product, **Intune's constraints outrank OS/7's
technical preferences** wherever the two collide. D3 is the first case where
that rule actually bit — ZFS native encryption is the technically nicer option
and it lost. Expect it to bite again; check Intune's live docs before changing
disk layout, encryption, OS identity, desktop or browser.

The rest of this section is what the same source turned up alongside the
encryption answer.

The same Microsoft page states the supported platforms for Linux compliance:

> Ubuntu Desktop **24.04 LTS or 26.04 LTS** (physical or Hyper-V machine with
> x86/64 CPUs)

Two consequences for OS/7:

1. **26.04 is officially supported.** The root README's Intune claim holds on
   `resolute`, and the x86-64-only wording confirms the arm64-is-server-only
   decision from the Microsoft side as well.
2. **New risk: OS/7's own identity may fail the "Allowed distributions"
   check.** That rule matches on distribution type and version, which come from
   `/etc/os-release`. If OS/7 rebrands `ID=` to `os7`, an Intune policy that
   allows "Ubuntu 26.04" will not match it. Mitigation: keep
   `ID=ubuntu`, `ID_LIKE=ubuntu` and `VERSION_ID="26.04"`, and brand only
   `NAME` / `PRETTY_NAME` / `HOME_URL`. This is an installer- *and* branding-level
   decision and it has not been made anywhere in this repo yet — see L16.

---

## 5. Bootloader and Secure Boot — the real fork

| | **A. shim + signed GRUB + bpool** | **B. ZFSBootMenu** |
|---|---|---|
| Secure Boot | Works out of the box — `shim-signed` (Microsoft-signed) chains to `grub-efi-*-signed` (Canonical-signed). | Not signed by the Microsoft UEFI CA. Needs self-signed keys via `sbctl`/`sbsign` + MOK or custom db enrolment, or Secure Boot off. |
| ZFS module under Secure Boot | Fine — Canonical's **prebuilt** `zfs.ko` is signed with the kernel key. (Another reason the "never zfs-dkms" decision matters: DKMS modules would need MOK signing.) | Same. |
| Boot environments | GRUB has no BE awareness any more. Canonical's `zsys` was dropped from the installer in 23.04 and is effectively unmaintained. **OS/7 has to write its own `grub.d` generator** enumerating `rpool/ROOT/*` and emitting `root=ZFS=rpool/ROOT/<be>` entries. | Native. Listing, selecting, snapshotting and cloning BEs is the whole point of the tool. |
| `bpool` needed | Yes | No — single `rpool`, closer to "ZFS only" |
| Encryption unlock at boot | LUKS2 via initramfs / TPM2 — see §4.5 | LUKS2 the same way; its ZFS-native unlock is moot under D3 |
| Supply chain | in the Ubuntu archive | third party, must be vendored and pinned at build time |
| Fleet/enterprise fit | matches what Intune/Entra-managed estates expect | MOK enrolment is an interactive blue firmware screen on first boot — breaks unattended provisioning |

**DECIDED (D1): A — shim + signed GRUB + `bpool`.** OS/7's audience runs
Secure-Boot-on, Intune-managed hardware; an installer that requires disabling
Secure Boot is a non-starter there. This accepts `bpool`, and it accepts writing
the `grub.d` boot-environment generator — roughly 100 lines, and OS/7 has to own
BE naming anyway.

**Keep B on the roadmap** as an opt-in "advanced boot" for the headless/server
and homelab cases, where Secure Boot is often off and BE ergonomics matter more.
The installer's storage step should be written so the bootloader is a
*strategy*, not hard-coded — that is a cheap decision now and expensive later.

**Also decide: UEFI only, or BIOS too?** Recommendation: **UEFI only for v1.**
BIOS adds a `EF02` BIOS-boot partition, an unsigned `grub-pc` path and a second
bootloader install path to test, for hardware OS/7 is not aimed at.

---

## 6. How much of this can be C# / .NET

### 6.1 The runtime question — solved

.NET is available at install time, and it does not even need to be installed in
the live image: **publish `os7-setup` as a NativeAOT single-file binary**.

```
dotnet publish -c Release -r linux-x64  -p:PublishAot=true
dotnet publish -c Release -r linux-arm64 -p:PublishAot=true
```

Result: a self-contained native ELF (~10–15 MB) with no .NET runtime
dependency. It starts instantly, which matters for something that runs before
anything else on the machine.

Two constraints, both already satisfied by this repo:

* NativeAOT cross-architecture builds need a cross linker; OS/7's build
  containers are **already architecture-matched** (Dockerfile, harvested fix 1),
  so each arch is built natively and the question never comes up.
* A NativeAOT binary built on Ubuntu 26.04 runs on 26.04 and newer — and the
  build base *is* the target. Fine.

`dotnet-sdk-10.0` stays in the base package list for the shipped OS regardless
(root README, "Core, non-negotiable"); the installer does not depend on it.

### 6.2 What is C# and what is not

| Layer | Implementation | Microsoft stack? |
|---|---|---|
| Screen buffer, renderer, damage tracking | C# | yes |
| Key decoding, raw terminal mode | C# + `DllImport("libc")` `tcgetattr`/`tcsetattr` | yes |
| Screen flow / state machine | C# | yes |
| Install plan model, validation, JSON (source-generated, AOT-safe) | C# `System.Text.Json` | yes |
| Structured logging, error screens, log export | C# | yes |
| Unattended mode (`--unattend plan.json`) | C# | yes |
| Disk enumeration | C# reading `/sys/block`, `/dev/disk/by-id`, plus `lsblk --json` | mostly |
| Partitioning | `sgdisk`, `wipefs`, `partprobe` as processes | no |
| Pool/dataset creation, boot environments | `zpool`, `zfs` — **via `pwsh` calling the OS7 module**, see below | partly |
| Copying the system | `unsquashfs` / `rsync` | no |
| Chroot configuration, bootloader | `chroot`, `update-initramfs`, `grub-install`, `update-grub` | no |

**There are no libzfs or libblkid bindings for .NET, and writing them is not
worth it.** Calamares — the thing being replaced — is C++ and Python shelling
out to exactly the same binaries. Nothing is lost by being honest about this.

### 6.3 Route the ZFS work through PowerShell — deliberately

The one place where "more Microsoft stack" also produces a *better* design:

`Update-OS7` and `Restore-OS7` (today stubs in `powershell/OS7/OS7.psm1`) need
boot-environment creation, activation and rollback logic. **Setup needs the
identical logic** to create the first boot environment. Writing it twice
guarantees drift.

So: put it once, in PowerShell, in the OS7 module — `New-OS7BootEnvironment`,
`Set-OS7BootEnvironment`, `New-OS7Storage` — and have the C# installer invoke
`pwsh -NoProfile -File …` for those steps, consuming JSON on stdout. `pwsh` is
already in the live image (hook 0020).

Not `Microsoft.PowerShell.SDK` hosted in-process: it is large and reflection-heavy,
which NativeAOT cannot handle. Out-of-process `pwsh` keeps both properties.

### 6.4 Terminal.Gui — considered, rejected

`Terminal.Gui` is the obvious .NET TUI library, but its widgets carry their own
aesthetic and fighting it to reach a pixel-faithful Win2k layout costs more than
writing the renderer. The renderer we need is small and fully specified:

* an 80×N `Cell[,]` buffer (rune + fg + bg), diffed against the previous frame,
  flushed as one `write(2)`
* raw mode via `tcsetattr`, `SIGWINCH` handling, guaranteed restore on exit,
  crash and signal
* a hand-written escape-sequence decoder for arrows / F-keys / PgUp / PgDn.
  We target exactly two terminal types (Linux VT, and a serial `vt100`-ish
  client), so a table beats depending on .NET's terminfo layer — which has known
  gaps around F-keys under `TERM=linux`.

Estimated 700–900 lines. Everything above it is screens and steps.

### 6.5 Proposed source layout

```
installer/
  SETUP-PLAN.md               this document
  src/
    OS7.Setup/
      Program.cs              arg parsing, unattended vs. interactive
      Tui/                    Screen, Renderer, Input, Theme, Widgets/
      Screens/                Welcome, Licence, Regional, Disk, Layout,
                              Confirm, Account, Mode, Network, Copy,
                              Configure, Complete, Error
      Model/                  InstallPlan.cs + JSON source-gen context
      Steps/                  IStep, Partition, Zfs, Unpack, Chroot,
                              Bootloader, ModeSplit, Finalise
      Native/                 Termios.cs, Ioctl.cs (DllImport libc)
    OS7.Setup.Tests/          plan validation + renderer golden frames
  assets/
    os7-setup.service         systemd unit, tty1
    palette-default.vtrgb     #0057ad field + #1289ff stripe
    palette-contrast.vtrgb    #003366 field + #1289ff stripe
    grub-theme/               blue ISO boot menu
```

### 6.6 The install plan is a file — the `unattend.xml` idea, done right

Every interactive screen only edits one `InstallPlan` object. Execution happens
strictly afterwards, from that object alone. Consequences, all free:

* `os7-setup --unattend plan.json` — unattended installs, which is what a
  Microsoft-shop audience will ask for within a week of the first release.
* `os7-setup --dry-run --print-plan` — the plan without touching a disk.
* **CI can install OS/7 end-to-end** in QEMU over a serial console and assert
  the result. That is the only affordable way to keep an installer honest.

---

## 7. Where Setup runs

* GRUB / isolinux menu on the ISO gains: **Install OS/7** (default), *Try OS/7
  without installing* (amd64 only — arm64 has no desktop), *Check disc*.
* The Install entry carries the palette, font and quiet parameters:

  ```
  boot=casper fbcon=font:TER16x32 plymouth.enable=0 quiet loglevel=0 \
  vt.color=0x4f vt.default_red=... vt.default_grn=... vt.default_blu=... \
  os7.setup=1
  ```

* A systemd unit runs `os7-setup` on `tty1` (`StandardInput=tty`,
  `TTYPath=/dev/tty1`, `TTYReset=yes`, `TTYVHangup=yes`), with `getty@tty1`
  masked on that path. `gdm3` is not started when `os7.setup=1`.
* `tty2` keeps a plain root shell for diagnosis, and `os7-setup --serial` on
  `ttyS0`/`ttyAMA0` when a serial console is present — which is a genuine gain
  for headless server installs that Calamares could never have offered.

### 7.1 Packages the ISO still needs

None of these are in the lists today; all are needed at install time:

`squashfs-tools` (or `rsync`), `gdisk`, `dosfstools`, `efibootmgr`,
`grub-efi-amd64-signed` / `grub-efi-arm64-signed`, `shim-signed`, `kbd`,
`console-setup`, `util-linux` (present), `zfsutils-linux` + `zfs-initramfs`
(present).

Added by D3 (LUKS2 under ZFS) — these go into the **installed system** as well
as the ISO, or it will not boot: `cryptsetup`, `cryptsetup-initramfs`,
`tpm2-tools`, and a zram provider (`systemd-zram-generator`) for D4.

`calamares` can be dropped from `build/config/package-lists-amd64/os7-desktop.list.chroot`.

---

## 8. Limitations — the honest list

| # | Limitation | Mitigation |
|---|---|---|
| L1 | "ZFS only" cannot be literal: FAT32 ESP is mandatory | none possible; document it |
| L2 | Secure Boot forces GRUB, which forces `bpool` | **accepted (D1)**; ZFSBootMenu stays behind a strategy interface for later (§5) |
| L3 | Swap cannot live on ZFS | zram by default; optional plain partition for hibernation |
| L4 | GRUB has no boot-environment awareness since `zsys` was dropped | OS/7 writes its own `grub.d` generator (~100 lines) |
| L5 | The palette can only be set on the kernel console | truecolor SGR fallback on serial/SSH |
| L6 | White on `#1289ff` is 3.47 : 1, below WCAG AA | **resolved (D5)**: field darkened to `#0057ad` (7.07 : 1, AAA), `#1289ff` kept as the title stripe and progress fill; `F5` → `#003366` |
| L7 | 80×25 is not guaranteed on UEFI | full-bleed chrome + 80-column body; `os7.setup.geometry=` to force |
| L8 | No screen reader equivalent to GNOME's Orca | `espeakup`/`speakup` and `brltty` do work on the Linux console (Debian's installer relies on this) — a phase-6 item, not a blocker |
| L9 | Console fonts cap at ~512 glyphs — no CJK, no RTL | English + German for v1; state the limit rather than pretending |
| L10 | Dropping Calamares means owning what it gave us free: partitioning UI, locale/keyboard lists, LUKS, OEM mode, 70+ translations, upstream maintenance | read the system's own data (`/usr/share/zoneinfo`, `xkb/rules/base.lst`, `i18n/SUPPORTED`) instead of hand-maintaining lists; accept the translation loss |
| L11 | NativeAOT needs `clang` + `zlib1g-dev` and restores `Microsoft.DotNet.ILCompiler` from NuGet at publish time — unvalidated against Canonical's `dotnet-sdk-10.0` | **spike S2 below.** Fallback is a framework-dependent build against the `dotnet-runtime` already in the image — bounded risk |
| L12 | Setup must never offer its own boot medium as a target; NVMe/mmc/multipath naming, pre-existing `rpool` name collisions and stale pool hostids are all real failure modes | explicit exclusion + `zpool import -f -N -R`, `zpool labelclear`, `zgenhostid`; each gets a named error screen |
| L13 | `/etc/hostid` must agree between install time and the target initramfs or the pool will not import at boot | `zgenhostid` into the target *before* `update-initramfs`; classic ZFS-root footgun |
| L14 | Booting straight into Setup loses "try before you install" | keep both GRUB entries |
| L15 | Intune's encryption check only recognises **dm-crypt**, so ZFS native encryption would report as unencrypted | **resolved (D3)**: `rpool` goes inside LUKS2 (§4.5). Cost: no per-dataset encryption, no raw encrypted `zfs send`, and mirrors need one container per disk |
| L16 | Intune's "Allowed distributions" rule matches on `/etc/os-release`; branding OS/7 as its own `ID=` could make every device fail it | keep `ID=ubuntu` / `ID_LIKE=ubuntu` / `VERSION_ID="26.04"`, brand only `NAME` / `PRETTY_NAME` (§4.6). **Not decided anywhere in this repo yet** |
| L17 | LUKS unlock at boot needs a passphrase prompt unless TPM2 enrolment happens at install time | enrol TPM2 in the install's configure step (`systemd-cryptenroll`), keep a passphrase as recovery — and test that a TPM-less VM still boots |
| L18 | **`bpool` may still trip the encryption check.** Microsoft exempts `/boot`, but `bpool` is an unencrypted fixed writable partition holding a ZFS *pool member*, not a directly mounted filesystem. Whether the agent maps it to `/boot` and exempts it is undocumented | verify in the first real enrolment test (Phase 6). If it fails: either move `/boot` into `rpool` and switch to ZFSBootMenu (D1 reopens), or carry a custom-compliance script. Do not assume it passes |

---

## 9. Decisions

| # | Decision | Outcome |
|---|---|---|
| D1 | Bootloader: signed GRUB + `bpool`, or ZFSBootMenu | **DECIDED 2026-08-22 — GRUB + `bpool`.** ZFSBootMenu stays possible behind a bootloader strategy interface; do not hard-code GRUB into the executor |
| D2 | UEFI only, or BIOS as well | **UEFI only for v1** (recommendation, unchallenged) |
| D3 | Encryption: ZFS native or LUKS | **DECIDED 2026-08-22 — LUKS2 under ZFS.** Forced by Microsoft's documented dm-crypt-only detection (§4.5) |
| D4 | Swap: zram only, or offer a partition | **zram default**, partition opt-in for hibernation |
| D5 | Field colour vs. white-text contrast | **DECIDED 2026-08-22 — field `#0057ad`** (`#1289ff` darkened along its own hue, 7.07 : 1, WCAG AAA); `#1289ff` becomes the full-width title stripe and the progress fill; `F5` → `#003366` (§2.2) |
| D6 | Does the *installed* system keep the blue console palette | recommend yes, opt-out — free brand identity on every tty |
| D7 | Root README brand colour is orange `#ff6912`; Setup is blue `#1289ff` | **Still open as a documentation question.** Proposed wording: orange stays the marketing/logo identity, blue `#1289ff` is the *product* identity — Setup, console, boot menu. Two unqualified "the brand colour is" statements in one repo will otherwise be read as a mistake |
| D8 | `/etc/os-release` identity: brand it as OS/7, or stay `ID=ubuntu` for Intune | **New, raised by §4.6.** Recommend `ID=ubuntu` + branded `NAME`/`PRETTY_NAME`; needs a decision before the first Intune enrolment test |

---

## 10. Plan

### Phase 0 — Spikes. Do these before writing any installer code.

Each is cheap, each kills the project's biggest unknowns, and none requires the
UI to exist. **Gate: all four pass before Phase 1 starts.**

| Spike | Question | Method | Done when |
|---|---|---|---|
| **S1** | Does the look actually work | Boot the existing arm64 ISO in QEMU with the palette + `fbcon=font:TER16x32` cmdline; paint one static mockup screen; `screendump` from the QEMU monitor | Field is exactly `#0057ad`, stripe exactly `#1289ff`, box glyphs render, arrows and F-keys decode |
| **S2** | Does NativeAOT build in the OS/7 container | `dotnet publish -p:PublishAot=true` for both arches in `os7-build` | Two static binaries that run in the ISO |
| **S3** | **Does a ZFS-on-LUKS root install boot at all** | Hand-scripted bash, no UI: partition → `cryptsetup luksFormat` → `bpool` + `rpool` on `/dev/mapper/os7_root` → `unsquashfs` → `zgenhostid` → `crypttab` → chroot config → `update-initramfs` → `grub-install` → reboot | A VM asks for the passphrase and boots to a login prompt from `rpool/ROOT/os7_*` |
| **S4** | Does it survive Secure Boot, and does TPM2 unlock work | Repeat S3 under OVMF with Secure Boot on and Microsoft keys, plus a software TPM (`swtpm`) and `systemd-cryptenroll --tpm2-device=auto` | Boots with SB enabled; second boot needs no passphrase; a TPM-less VM still boots via passphrase |

S3 is the one that matters. If S3 fails, no amount of UI work helps — and the
existing repo has never installed OS/7 to a disk by any means, so this is
genuinely unknown territory. **Do S3 first.**

D3 made S3 harder than it was when this document was first written: the
encryption layer is now part of the *first* spike rather than a later refinement.
That is deliberate. Retrofitting LUKS under an already-working ZFS-root sequence
means redoing the initramfs, `crypttab` and bootloader work anyway.

### Phase 1 — `os7-setup` skeleton
TUI layer (buffer, renderer, input, theme, both palettes), screens 1–3 and 12,
error screen, logging. Boots from the ISO via the systemd unit and the GRUB
entry. **Strictly non-destructive** — nothing touches a disk yet.
*Deliverable:* you can walk the whole flow in a VM and it looks right.

### Phase 2 — Storage
Disk enumeration and the plan model; screens 4–6; the executor for
partition + pool + dataset creation, driven by S3's proven sequence;
`--unattend` and `--dry-run`. Failure rolls back **only** what Setup created.

### Phase 3 — System configuration
`unsquashfs` with real progress; chroot configuration (locale, timezone,
hostname, users, `zgenhostid`, `update-initramfs`); bootloader install and the
`grub.d` BE generator; screens 7–11; the GUI/headless split (offline
`apt purge` of the desktop for headless, `systemctl set-default multi-user.target`).
*Deliverable:* a machine installed by Setup boots into OS/7.

### Phase 4 — Authenticity and polish
GRUB theme, boot palette, "inspecting your computer's hardware configuration",
`F1` help on every screen, `F3` quit confirmation, log export to removable
media, the `#003366` high-contrast mode.

### Phase 5 — arm64 and serial
The same binary on arm64; serial-console mode; drop Calamares from the package
list; retire the Subiquity option in this directory's README. **After this, both
architectures have one install path** — the open problem that started this.

### Phase 6 — Integration and the long tail
Move the BE logic into the OS7 PowerShell module and have both Setup and
`Update-OS7`/`Restore-OS7` call it. `R=Repair`: import an existing `rpool` and
install a new BE beside the current one. Entra/Intune/Arc onboarding hand-off
(collect intent at install, execute on first boot — tenant credentials do not
belong in an installer log). `espeakup` accessibility. CI installs in QEMU.

---

## 11. What this changes in the repo

| Where | Change |
|---|---|
| Root `README.md`, "Locked decisions" → Installer | Calamares → **`os7-setup`, an OS/7-authored text-mode installer in C#/.NET**. One installer for both architectures. |
| Root `README.md`, "arm64 is server-only" → consequence | The "Calamares cannot install arm64" consequence is **resolved**, not merely noted. |
| Root `README.md`, Branding | Reconcile orange `#ff6912` with Setup's blue `#1289ff` (D7). |
| `installer/README.md` | Open problem #1 (arm64 has no install path) closes. Subiquity and the preinstalled-image options are no longer needed. **Problem #3 (encryption undecided) closes — LUKS2, see §4.5.** Problem #4 (Calamares branding) becomes moot; this plan replaces it. Only problem #2 (the `authd-msentraid` snap) is untouched and still blocking. |
| `build/config/package-lists-amd64/os7-desktop.list.chroot` | Drop `calamares`. Its header rationale ("Calamares needs a running desktop, therefore GNOME ships in the live image on every architecture") is now stale — and was already inaccurate, since the file is amd64-only. |
| `build/config/package-lists/os7-base.list.chroot` | Add the install-time tools from §7.1, including the `cryptsetup` family that D3 makes mandatory. |
| Wherever `/etc/os-release` gets branded | Must not change `ID` / `VERSION_ID` without deciding D8 first — Intune's "Allowed distributions" rule reads them (§4.6). |
| `build/config/auto/config` | `--bootappend-live` gains the palette/font parameters; the ISO grows an Install entry. |
| `build/build.sh` | New stage: `dotnet publish` `os7-setup` into `includes.chroot/usr/lib/os7-setup/`. |
| `Dockerfile` | `dotnet-sdk-10.0` + `clang` + `zlib1g-dev` in the build container (pending S2). |
| `powershell/OS7/OS7.psm1` | Gains the BE primitives Setup and `Update-OS7` share; `Restore-OS7 -BootEnvironment` gets the naming scheme from §4.4. |

Nothing here has been implemented and no file above has been modified by this
plan. A build was running in another session while this was written; the changes
in §11 should be made deliberately, not folded into an in-flight build.

---

## 12. What was verified, and how

Everything load-bearing above was checked on **2026-08-22** rather than
remembered. What was *not* checked is marked as a spike in Phase 0.

| Claim | Source |
|---|---|
| Linux VT palette is programmable per-slot; `setvtrgb` takes 3×16 decimal values; `vt.default_red/grn/blu` and `vt.color` are kernel parameters | [setvtrgb(8)](https://www.man7.org/linux//man-pages/man8/setvtrgb.8.html), [Ubuntu setvtrgb(1)](https://manpages.ubuntu.com/manpages/focal/man1/setvtrgb.1.html), [kernel-parameters vt options](https://nv-tegra.nvidia.com/r/plugins/gitiles/linux-2.6/+/55ff9780e7cedc9168dab4d42483c70011c53ace%5E%21/Documentation/kernel-parameters.txt) |
| fbcon accepts 24-bit SGR but degrades it to its 16-colour palette (and only 8 backgrounds) | [Terminal.Gui #48 truecolor discussion](https://github.com/gui-cs/Terminal.Gui/issues/48) |
| Ubuntu kernels enable `CONFIG_FONT_TER16x32`, usable via `fbcon=font:TER16x32` | [LP #1819881](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1819881), [Ubuntu Discourse: HiDPI kernel font](https://discourse.ubuntu.com/t/high-dpi-kernel-font-for-tty-consoles/10439) |
| Secure Boot chain is Microsoft-signed `shim-signed` → Canonical-signed `grub-efi-*-signed`; ZFS root installs use `bpool`, which must be named `bpool`; GRUB opens pools read-only so only read-only-compatible features count | [OpenZFS Ubuntu 22.04 Root on ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html), [Ubuntu Secure Boot docs](https://documentation.ubuntu.com/security/security-features/platform-protections/secure-boot/) |
| `zsys` was dropped from the Ubuntu installer in 23.04 and is effectively unmaintained; ZFS root itself remains supported | [ubuntu/zsys #230](https://github.com/ubuntu/zsys/issues/230) |
| ZFSBootMenu bundles kernel+initramfs+cmdline into one EFI binary that can be signed with `sbsign`/`sbctl`; boot environments are its core feature | [zfsbootmenu.org](https://zfsbootmenu.org/), [UEFI booting docs](https://docs.zfsbootmenu.org/en/latest/general/uefi-booting.html), [zfsbootmenu-sb signing hooks](https://github.com/KorewaKiyo/zfsbootmenu-sb) |
| Swap on a zvol still deadlocks — reproduced on Ubuntu 25.10 in February 2026 | [openzfs/zfs #7734](https://github.com/openzfs/zfs/issues/7734), [openzfs/zfs #18200](https://github.com/openzfs/zfs/issues/18200) |
| NativeAOT can target linux-arm64; cross-arch needs a cross linker and target-arch zlib; a binary built on Ubuntu *N* runs on *N* and newer | [Native AOT cross-compilation](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/cross-compile), [Native AOT overview](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/) |
| NativeAOT restores `Microsoft.DotNet.ILCompiler` from NuGet at publish time | [dotnet/sdk #34049](https://github.com/dotnet/sdk/issues/34049) |
| **Intune's Linux encryption compliance recognises only dm-crypt, prefers LUKS + cryptsetup, and explicitly ignores `/boot` and `/boot/efi`** — the basis for D3 | [Linux device compliance settings in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/compliance/ref-linux-settings) (page updated 2026-05-20) |
| **Intune Linux compliance supports Ubuntu Desktop 26.04 LTS, x86/64 only** — confirms the base choice and the arm64-is-server-only decision | same page |
| Intune's "Allowed distributions" rule matches distribution type and version, which is what raises L16/D8 | same page |

Contrast ratios in §2.2 were computed from the sRGB relative-luminance formula,
not taken from a source.
