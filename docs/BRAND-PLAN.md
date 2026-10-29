# Brand — the mark, where it lives, and what may be done with it

**This file is authoritative for the OS/7 mark: which file is the logo, what is
derived from it and how, which ink goes on which ground, which surfaces show it,
and what the boot splash is to become.** It decides nothing about the product's
on-screen palette — that is SETUP-PLAN D5/D7 for the text phase and
GUI-APPS-PLAN G9 for the desktop — and it does not move the orange onto either
of them.

**STAGE 1 IS BUILT (2026-10-29): there is one mark, in `brand/`, and a check
holds every copy to it.** `brand/os7-wordmark.svg` is the website's drawn
wordmark, moved here shape for shape; `build/lib/brand.py` derives the white
variant and the tile from it; `installer/testing/check-brand.py` holds the
geometry, the two inks, the byte-identity of the derived files, the contrast
numbers and `<svg`-before-byte-256 at **26 checks**, and names the consumers in
the image that do not yet carry the mark — **two, and that is the baseline**.

**STAGE 2 IS BUILT ON THE IMAGE SIDE (2026-10-29, the same day).** The icon
`LOGO=os7` names is a byte copy of the tile; the login screen's lockup is
generated from the master and the vendor mark; `brand.py write` writes both,
`check-brand.py` holds both at **baseline 0**, `check-image.py` compares both
against the repository inside a built ISO, and hook 0090 fails a build whose
greeter mark contains `<text>`. Rendered through librsvg 2.61.3 in a plain
`ubuntu:26.04` container — the lockup at natural size, 2× and 4× on the field,
the tile at 16, 64 and 128 px — and legible at every one; **not** yet through
the greeter on a machine (O-BR5), and no ISO has been built with it.

**STAGE 3, THE BOOT SPLASH, IS BUILT AND HAS BEEN SEEN ON A MACHINE (2026-10-29,
the same day).** `os7-console` ships a Plymouth `script` theme on both
architectures; its seven sprites are rendered from the master by
`build/lib/brand_raster.py` — pure Python, no renderer — and `check-brand.py`
and `check-image.py` require each to decode to the master's pixels. Setup
writes `quiet splash`; firstboot migration 80 gives it to machines already
installed; and getting there found **BUILD-NOTES #181** — OS/7's own menu
entries had frozen the kernel command line at a machine's first activation, so
no `/etc/default/grub` change had ever reached the entry a machine boots. On a
1.0.0.245 machine with the theme installed, the intro was captured at 18 frames
a second (O, S, 7, the slash cutting in, done at 1.06 s), the passphrase was
asked in the theme's field and answered through the VM keyboard, and the bar
filled to the login (§5a). **What a GATE has said** is in §5a too — it is the
difference between "seen on a bench" and "true of the product".

**What is NOT built:** the website's copies (BR3, the other repository), the
tile in the GUI applications (BRL7), the arm64 boot (the Mac), the removal of
Ubuntu's text splash on arm64 (BRL4), and any decision about GRUB's 30-second
EFI menu wait, which is Ubuntu's and measured (BRL8).

Decisions are **BR1–BR9**, limitations **BRL1–BRL8**, owed measurements
**O-BR1–O-BR6** (§7).

Related authority: [DECISIONS.md](DECISIONS.md) "Branding" (the orange, and
which surfaces it does not apply to); [IDENTITY-PLAN.md](IDENTITY-PLAN.md) I1
(`LOGO=os7` and what a person sees versus what software reads);
[SETUP-PLAN.md](../installer/SETUP-PLAN.md) D5 (the field colour the white
variant stands on); [GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) G9 (one palette, and
why a colour outside `Tokens.axaml` fails a check); [BUILD-NOTES.md](BUILD-NOTES.md)
#111 (why every brand file keeps `<svg` inside the first 256 bytes), #85 and
#110 (how the login screen came to show its mark at all).

---

## 1. Verdict

On 2026-10-29 the repository had four marks and had decided none of them. The
website carried a drawn wordmark in orange; the image carried three `<text>`
elements in DejaVu Sans Bold — the app icon on a blue tile, the boot-splash
fallback rasterised from it, and the login screen's lockup — each with a
reasonable comment and none looking like the other. DECISIONS.md had said since
August that logo, boot splash and website are orange; the image's marks were
blue and white.

The website's wordmark is the one worth keeping, and not on taste alone: it is
the only one of the four that renders the same everywhere, because it depends
on no font, and the only one whose licensing is clean. So it is the mark
(BR1), it lives here rather than on the website because the build, the check
and the public history are here (BR3), everything else is derived from it and
never hand-edited (BR6), and the two inks are decided by the ground the mark
stands on, by measurement (BR4).

The boot splash is the part that was asked for and the part furthest away. It
needs an OS/7 Plymouth theme — not a PNG swapped into Ubuntu's — and it needs an
installed machine to boot with `splash` at all, which today none does. Both are
Stage 3, and both are measurable here before anybody claims them (§5).

---

## 2. What was measured, 2026-10-29

Read out of the two checkouts, the shipped `1.0.0.245` package manifests and
the `os7img:175` container image, and computed. Nothing in this section was
rendered on a screen.

### 2a. The inventory

| where | file | what it is | font | colour |
|---|---|---|---|---|
| website header, footer | `site/brand/os7-wordmark.svg` | drawn geometry: ellipse, bezier spine, two polygons | none | `#ff6912` on transparent |
| website tab | `site/brand/favicon.svg` | the 7 from the wordmark on an orange tile | none | `#ff6912`, `#ffffff` |
| image, `LOGO=os7` | `usr/share/icons/hicolor/scalable/apps/os7.svg` | 128-unit blue tile, `#1289ff` stripe, "OS/7" | DejaVu Sans Bold, `<text>` | `#0057ad`, `#1289ff`, `#ffffff` |
| image, boot splash | `spinner/bgrt-fallback.png` (diverted) | the icon above, rasterised at 128 px by hook 0035 | DejaVu Sans Bold | as above |
| image, login screen | `usr/share/pixmaps/os7-logo-login.svg` | "OS/7", a rule, the vendor's 215 paths in white | DejaVu Sans Bold, `<text>` | `#ffffff` on `#0057ad` |

The website's wordmark and favicon are one geometry: the favicon's path is the
wordmark's 7, byte for byte, under `translate(-65.07, 9.16) scale(0.664)`,
which puts the 7's bounding-box centre at (32.013, 32.002) in a 64-unit tile.
The master in `brand/` has the website's four shapes attribute for attribute;
`shapes_of()` in `build/lib/brand.py` compared them.

### 2b. The numbers

WCAG relative luminance, computed by `palette.py`'s `ratio()` — the same
arithmetic D5 used for the Setup field:

| ink | ground | ratio | meaning |
|---|---|---|---|
| `#ff6912` | `#0a0d12` (the website's page) | **6.75 : 1** | the orange is drawn for this ground |
| `#ff6912` | `#000000` | 7.28 : 1 | a black boot splash works |
| `#ff6912` | `#0057ad` (the Setup field) | **2.45 : 1** | not usable — why the white variant exists |
| `#ffffff` | `#0057ad` | 7.08 : 1 | clears D5's 7:1 floor for the field |
| `#ff6912` | `#ffffff` | 2.88 : 1 | the website's light theme shows the mark just below the 3:1 non-text floor (BRL6) |

The mark's weight is one number: the O and S are stroked at 6.4; the slash
polygon is 6.90 wide and a 6.4 stroke of its slope, cut horizontally, is 6.91;
the 7's diagonal is 6.84 wide against 6.84. The O and the S stand on one cap
line, y 12..60. All four are asserted by the check from the coordinates, not
from the comment that states them.

### 2c. The boot path, as the code has it

* The installer writes `GRUB_CMDLINE_LINUX="boot=zfs"` and
  `GRUB_CMDLINE_LINUX_DEFAULT=""` (`SystemSteps.cs`). An installed machine
  therefore boots with neither `quiet` nor `splash`, and Plymouth draws a
  graphical theme only when `splash` is on the command line. **The diverted
  boot mark has, by the code, never been shown on an installed machine.** Only
  the medium's live-session entry carries `quiet splash`
  (`build/lib/efi-remaster.sh`); the Install entry carries `plymouth.enable=0`
  on purpose, and keeps it.
* `default.plymouth` is `bgrt`, whose `[boot-up]` sets
  `UseFirmwareBackground=true`: on hardware with an ACPI BGRT table it shows
  the **firmware vendor's** logo and a spinner; the diverted PNG is the
  fallback for machines and VMs without one. That is Ubuntu's design, and it
  is why an OS/7 mark at boot needs an OS/7 theme and not a replaced file
  ([SESSION-DESKTOP-DEBRAND.md](SESSION-DESKTOP-DEBRAND.md) §5).
* The LUKS container is sealed to **PCR 7 only** (`systemd-cryptenroll
  --tpm2-pcrs=7`, `SystemSteps.cs`). A changed initramfs — which a Plymouth
  theme is — does not move PCR 7, so the TPM unlock is not in the path of this
  work. The passphrase prompt is (O-BR1).
* The amd64 debrand hook (`hooks-amd64/0035`) pins and purges
  `plymouth-theme-ubuntu-text`; **the arm64 image still ships it** —
  `OS7-1.0.0.245-arm64.packages.manifest` lists it. Dormant today for the same
  reason the mark is: no `splash`.

### 2d. What Plymouth has on the image

Out of the `1.0.0.245` manifests and `dpkg -L` in `os7img:175`:

| | amd64 | arm64 |
|---|---|---|
| `plymouth` (daemon, `details.so`, `text.so`, **`script.so`**, `two-step.so`, `tribar.so`, drm + framebuffer renderers) | yes | yes |
| `plymouth-theme-spinner` (the `bgrt` theme lives here too) | yes | no |
| `plymouth-label` (`label-pango.so` — text in a theme) | yes | **no** |
| `plymouth-theme-ubuntu-text` | purged by hook 0035 | **shipped** |
| `/usr/share/initramfs-tools/hooks/plymouth` | yes | yes |

So a script-plugin theme runs on both architectures with no new package, and a
theme that wanted to draw TEXT would work on one of them. BR2 was already the
answer for the website; the arm64 manifest makes it the answer at boot as well.

---

## 3. Decisions

| # | Decision | Status |
|---|---|---|
| **BR1** | **One mark.** The four shapes in `brand/os7-wordmark.svg` — a stroked O and S, a filled slash and 7, cap height 48, weight 6.4 — are the OS/7 mark. Every other rendering of the name as a picture, in this repository, on the image and on the website, is one of the three files in `brand/` byte for byte or is generated from the master. `check-brand.py` records the geometry (`CANON`) and names every copy that disagrees. | **Decided 2026-10-29** |
| **BR2** | **Drawn, not set.** No brand file and no consumer of one contains `<text>` or names a font. Three reasons, each sufficient: a wordmark in live text is three marks, one per platform's fallback font (the website's own placeholder was Segoe on Windows, Helvetica on macOS, DejaVu on Linux); converting a proprietary font's glyphs to outlines is not licensed in a public repository; and the arm64 image has no Plymouth label plugin, so a boot splash set in a font would exist on one architecture (§2d). | **Decided 2026-10-29** |
| **BR3** | **The source is this repository.** `brand/` here is where the mark lives; `upinblue/os7-web` copies the three files byte for byte and changes nothing in them. Until 2026-10-29 the direction was the reverse and the private repository held the better mark. The build, the check and the public history are here, and the website's own tooling already reads this repository's output tree. §9 of the check compares a sibling checkout when there is one and says NOT CHECKED when there is not (BRL1). | **Decided 2026-10-29** |
| **BR4** | **Two inks, decided by the ground.** Orange `#ff6912` on a dark ground (≥ 4.5:1 — 6.75:1 on the website's `#0a0d12`, 7.28:1 on black); white on the Setup field `#0057ad` (7.08:1, above D5's 7:1 floor) and on any ground where orange falls below 4.5:1. Orange on the field is 2.45:1 and the check requires it to STAY below the floor: if the field ever changed enough to pass, this decision would need re-deciding and should not quietly stop mattering. There is no third ink, no gradient, no outline, and no copy of the mark is recoloured by hand — the white file is generated. The orange stays off the desktop palette and the text phase, as DECISIONS.md says. | **Decided 2026-10-29** |
| **BR5** | **The tile is the mark at icon size.** The 7 alone, on an orange tile with a 12-unit corner, is what a browser tab, an icon grid and `LOGO=os7` in `/etc/os-release` show — because the wordmark is 2.4 times as wide as it is tall and a 16px rendering of it is six pixels of cap height. The tile's transform is the website favicon's, to the digit, so the two are one shape; the check recomputes that it centres the 7. | **Decided 2026-10-29**; the icon switch is Stage 2 |
| **BR6** | **Derived files are generated and never edited.** `build/lib/brand.py write` produces `os7-wordmark-white.svg` and `os7-tile.svg` from the master; `verify` and the check require the checked-in files to be that output byte for byte. A consumer in the image is either a byte-identical copy of a brand file or a lockup generated from one; the check holds the icon to byte-identity and the login mark to carrying the four shapes with no `<text>`. | **Decided 2026-10-29** |
| **BR7** | **`<svg` inside the first 256 bytes, in every brand file.** GdkPixbuf sniffs a fixed prefix to decide whether a file is an image; a 35-line comment above the tag blanked a real login screen (#111). The rule is applied to the whole of `brand/` and not only to the greeter's copy, so that a byte-identical copy into any consumer is safe without anyone remembering why. The prose lives inside the element. | **Decided 2026-10-29** |
| **BR8** | **The boot splash is an OS/7 Plymouth theme drawn from these shapes, on both architectures.** A `script`-plugin theme in `os7-console`, whose seven sprites are rendered from the master by `brand_raster.py` and checked pixel for pixel; registered as the `default.plymouth` alternative at 150 against Ubuntu's `bgrt` at 110, so a manual choice stays the administrator's; `quiet splash` on the installed machine's command line. The animation: the four shapes appear in sequence, the slash last and moving along its own slope, over a segmented progress bar in the Windows 2000 idiom; the passphrase is asked in the bar's frame with bullets; Esc shows Plymouth's details. **Text is drawn only where text can be** — the prompt and cryptsetup's messages through `Image.Text`, which needs `plymouth-label` and so exists on amd64 alone; the mark is never text (BR2). **On a serial console no theme draws at all**: plymouthd forces `details` there (#182), which is Plymouth's design and accepted. | **Built 2026-10-29**; seen on an amd64 bench, the gate in §5a |
| **BR9** | **A migration changes only a line nobody else owns.** Firstboot migrations re-run at every release's first boot (build-os7-packages.sh ships `migrations.d` under each version), so "add `splash` where it is missing" would overrule, at every update, an administrator who removed it. Migration 80 therefore edits `GRUB_CMDLINE_LINUX_DEFAULT` only when it is empty — what Setup wrote before 2026-10-29 — or holds nothing but `console=` arguments, which serial servers and this repository's harnesses add; anything else is left alone and the reason printed. `nosplash` is the word for no, honoured whatever else the line says. | **Decided 2026-10-29** |

---

## 4. The consumers

Every surface that shows the name as a picture, what it shows today, what it
is to show, and when. The check's §8 reads the first two rows on every run.

| surface | file | today | target | stage |
|---|---|---|---|---|
| app icon, `LOGO=os7`, GNOME About | `build/config/includes.chroot/usr/share/icons/hicolor/scalable/apps/os7.svg` | **a byte copy of `brand/os7-tile.svg` since 2026-10-29** (was a blue tile with `<text>`) | as today; `check-image.py` compares it inside the ISO | 2, built |
| Settings > About on **Ubuntu's** gnome-control-center | `build/packages/os7-desktop-theme/tree/usr/share/pixmaps/ubuntu-logo-text{,-dark}.svg`, diverted from base-files (BUILD-NOTES #169) | **a byte copy of `brand/os7-tile.svg`**. These arrived from the quality-of-life work on the same day as this list, as a fifth mark — `<text>` in DejaVu Sans on the old tile — because Ubuntu's build hard-codes these two paths and never reads `LOGO=`. Folded into `brand.CONSUMERS` when the two lines of work were merged (2026-10-29): their own comment said they were meant to show what `LOGO=` would have shown, which is the tile. **Not looked at on a screen**: the old file's natural size was 96 px, the tile's is 64 | as today; hook 0090 and `check-image.py` require both to be byte-identical to the app icon | 2, built |
| **boot splash** | `build/packages/os7-console/tree/usr/share/plymouth/themes/os7/` — `os7.plymouth`, `os7.script`, seven PNGs | **built 2026-10-29**: the mark animated over the progress bar; sprites generated, held pixel for pixel by `check-brand.py` §9 and inside the ISO by `check-image.py` | as today | 3, built |
| boot splash fallback | `spinner/bgrt-fallback.png`, diverted by hook 0035 from the icon | follows the icon: the tile at 128 px; reached only if somebody selects `bgrt` by hand | kept — the diversion still keeps Ubuntu's logo off a machine where someone does | — |
| login screen | `build/packages/os7-desktop-theme/tree/usr/share/pixmaps/os7-logo-login.svg` | **GENERATED since 2026-10-29** from the master and the vendor file: the wordmark in white at scale 2.7, cap foot on y=180, the rule, the vendor mark; natural size 216×98 as before, read out of `LoginDialog` (was `<text>` in white) | as today; hook 0090 refuses `<text>`, `check-image.py` re-renders it from the shipped vendor file and compares | 2, built |
| website header, footer, tab | `upinblue/os7-web`, `site/brand/` | the master's origin; comment above the `<svg>` tag | byte copies of `brand/` (BR3) | 2, other repository |
| GUI applications | none yet | — | the tile, with the orange entering `Tokens.axaml` as a token first (G9 forbids a colour anywhere else under `src/`) | 2 or later |
| administrator manual | `docs/manual/` | no mark | not planned | — |
| GRUB menus (medium, installed) | text | text | stays text (§6) | — |
| the text-mode installer | Setup's title row | the name in Fixedsys | stays — D5/D7's surface, not this file's | — |

---

## 5. The boot splash (BR8) — as built

**The theme.** `/usr/share/plymouth/themes/os7/` in `os7-console`, on both
architectures, because "what the machine looks like before anything logs in" is
that package's whole subject and the desktop theme is amd64-only. It holds
`os7.plymouth` (`ModuleName=script`), the hand-written `os7.script`, and seven
PNGs GENERATED by `build/lib/brand.py write`: the four shapes, each on a canvas
the size of the whole mark so the script places all four at one point; the
progress frame; a block; a bullet. The native size is scale 3 — the mark
510×216 px — and the script scales DOWN to about a quarter of the screen width
and never above native, because Plymouth's `Image.Scale` is bilinear. Ground
black (7.28:1), ink orange, the frame and bullets white (BR4).

**The renderer is this repository's own** (`build/lib/brand_raster.py`).
`rsvg-convert` is not in either build image, and a PNG it wrote could not be
held to anything without the same renderer at the same version on every host.
The mark is small enough not to need one: an ellipse ring (its true offset
curves, not two ellipses), a stroked cubic spine with butt caps, two polygons,
filled nonzero with exact horizontal coverage and eight sub-scanlines. It uses
only `+ − × ÷` and `sqrt` — correctly rounded on every platform — and walks the
ellipse by the rational parametrisation rather than `cos`/`sin`, which differ in
the last place between C libraries. So the check compares DECODED PIXELS, which
is stable across zlib implementations where the PNG bytes are not. Compared
with librsvg 2.61.3 at the same size: ink area 22 662 against 22 640 px
(+0.1 %), mean edge difference 0.58 of 255, three pixels apart by more than 64.
The PNGs were written on Windows and the package build verified them under
Linux — the determinism claim, exercised once.

**The animation** (50 frames a second, eased): O from frame 4, S from 10, 7 from
16, each fading in over 12; the slash from 28 over 14, travelling 18 units down
its own slope as it arrives; the frame from 40. Then the 20 blocks follow
`Plymouth.SetBootProgressFunction`. On shutdown the mark is drawn and the bar is
not. The passphrase is asked in the bar's frame with white bullets, the prompt
above it in the system face where `Image.Text` exists; cryptsetup's messages
appear under the bar the same way.

**What changed in the product:**

* `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"` in `SystemSteps.cs`, with two
  NOTE lines — not faults — that ask the installed initramfs for the theme and
  the menu for the word.
* `os7-console`: `Depends: plymouth`; the postinst registers the alternative at
  150 and says so when an administrator's manual choice wins; the prerm removes
  it; a `triggers` file activates `update-initramfs`; the package build runs
  `brand.py verify` and refuses stale sprites; ten splash paths are required in
  the built `.deb`.
* Firstboot migration 80 (`os7-release/migrations.d/firstboot/80-boot-splash`)
  for machines already installed, under BR9's rule, rebuilding OS/7's menu
  through `Set-OS7BootEnvironment` and reading `grub.cfg` back.
* `New-OS7MenuFragment` takes the kernel arguments from 10_linux_zfs's own
  entry (#181) — without that, the migration's line would never have reached
  the entry a machine boots.
* `run-secureboot.py policy` waits for what a rejection prints, not for the
  prompt it redraws (#182).
* The medium's Install entry keeps `plymouth.enable=0`. Setup is the product's
  text-mode face. The live session's entry already had `quiet splash` and now
  shows the OS/7 mark.

### 5a. What was measured, 2026-10-29

On a copy of the `manual` bench (a 1.0.0.245 headless install, one boot
environment as a dataset) with the theme installed by hand, the new module
swapped in, and its initramfs rebuilt. **A bench is for looking** (the
os7-lab skill's own rule): what counts for the product is the gate below.

| question | answer |
|---|---|
| O-BR1: with `quiet splash console=ttyS0`, no TPM — what is on the serial line? | `Please unlock disk os7_root`, from the `details` plugin plymouthd forces on serial; redrawn at every keystroke with one more `*`; the passphrase typed there unlocks and a login follows. A wrong one prints `No key available with this passphrase.` and `cryptsetup failed, bad password or options?` (#182) |
| O-BR2: without a serial console — what is on the display? | the mark, the prompt and the field; bullets as typed through the VM keyboard; then the bar filling with `cryptsetup: os7_root: set up successfully` under it, then tty1's login, ~15 s after the passphrase. The intro captured at 18 frames a second: O at 0.05 s, S 0.22, 7 0.38, the slash cutting in from 0.78, done at 1.06 |
| the migration, on that machine | first run: the line became `quiet splash console=ttyS0,115200`, the menu was rebuilt, every OS/7 entry carried `splash`; second run: `nothing to do` |
| the package's maintainer scripts, in `os7img:175` | install: `auto`, OS/7 at 150 over bgrt at 110, the initramfs trigger fired; a manual choice survives a reinstall with a printed note; remove: `auto`, back to bgrt |

**And one defect the bench found in the script itself**, in slow motion: the
passphrase prompt was drawn at once and the field only with the intro's 40th
frame, because the refresh function owned the frame's opacity. Fixed, and the
real-speed capture above is the fixed script.

**THE GATE, on `OS7-1.0.0.249-amd64.iso` built from this tree.**
`check-image.py`: every brand and splash check green (five red ones are the
test build's development key and absent credential, by construction).
`run-s5.py all`: install, boot, cycle, update and timer all PASS, no FAIL line —
the TPM boot reached a login with `quiet splash` on the line and nothing typed
(O-BR3), the cycle activated twice through #181's menu code and booted what it
was told, and migration 80 ran in 1.0.0.250's firstboot list and exited 0.
`run-secureboot.py all`: 32 ok, 0 failed, its `policy` phase passing through
seventeen per-keystroke redraws of the prompt that the old expectation would
have read as a rejection (#182).
Details in [SESSION-BRAND-FREEZE.md](SESSION-BRAND-FREEZE.md) §7e. The gate
watches a serial line and never a display, so that the theme DRAWS is the
bench's evidence, not the gate's.

**Still owed:** **O-BR4**, hardware with an ACPI BGRT table (no VM has one);
the arm64 boot (the Mac).

**Why not the GRUB menu.** A `gfxterm` background would need `png`,
`gfxterm` and `video` modules in the SIGNED GRUB image, which refuses to
`insmod` from disk under Secure Boot — the same shape that kept an unsigned
loader on the ISO for months (#134) and that `efi-remaster.sh` records for
`all_video`. Whether Ubuntu builds those modules in is unmeasured. The menu is
the boot-environment chooser and its text face fits the idiom; it stays.

---

## 6. What it deliberately does not do

* **It does not move the orange onto the desktop or the text phase.**
  DECISIONS.md "Branding" keeps those on the Windows 2000 palette and on
  `#0057ad` / `#1289ff`; this file agrees and the check does not touch
  `Tokens.axaml` or `gtk.css`.
* **It does not make a second palette.** Two inks and the two grounds they
  were measured against; `brand.py` imports the field colour from `palette.py`
  rather than restating it.
* **It does not recolour the vendor mark.** `upinblue-logo.svg` is the
  vendor's, verbatim; the login lockup's white copy of it is generated from it
  today and stays that way.
* **It does not theme GRUB** (§5).
* **It does not render anything in Stage 1.** The numbers are arithmetic; the
  first pixel of this mark on an OS/7 screen is Stage 2's to measure.

---

## 7. Limitations and owed measurements

| # | Limitation |
|---|---|
| **BRL1** | The website cannot be checked from this repository: it is private and a sibling checkout is optional. The check's §9 compares one when `OS7_WEB_ROOT` or `../os7-web` exists and says NOT CHECKED otherwise. Run from a worktree the default path resolves to nothing. |
| **BRL2** | **Closed 2026-10-29.** The icon and the login mark are the generator's output byte for byte and the check's baseline is 0; the boot fallback follows the icon. What remains outside the image is the website's copies (BRL1) and the GUI applications (BRL7). |
| **BRL3** | **Closed 2026-10-29.** New installs boot with `quiet splash`, migration 80 gives it to existing machines under BR9's rule, and #181 is what made that reach the entry they boot. A machine whose administrator edited the line keeps it and is told why. |
| **BRL4** | The arm64 image ships `plymouth-theme-ubuntu-text`, the Ubuntu wordmark's text splash; the debrand hook that removes it is amd64-only. It is now reachable: `text.plymouth` is what plymouthd falls back to when the default theme cannot draw — no pixel display and no serial console. Not removed here. |
| **BRL5** | Rendered through librsvg 2.61.3 in a container — the lockup at 1×, 2× and 4× on the field, the tile at 16, 64 and 128 px, the wordmark at 22 px and 3× on dark — which is the library GdkPixbuf's SVG loader uses, and legible at every size. NOT yet through the greeter's own natural-size path on a machine, and not on a framebuffer. O-BR5 stays owed. |
| **BRL6** | The website's light theme shows the orange mark on white at 2.88:1, below the 3:1 floor for non-text contrast. BR4 says nothing about a white ground; the website decides whether the light theme darkens the mark or the ground. |
| **BRL7** | The GUI applications have no brand token: `check-gui-tokens.py` forbids a colour literal anywhere under `src/` outside `Tokens.axaml`, so the orange must enter as a token before the tile can appear in an application. |
| **BRL8** | **Every EFI boot of an installed machine waits 30 seconds in GRUB's menu**, whatever `GRUB_TIMEOUT` says. Ubuntu's `/etc/grub.d/00_header`, read in `os7img:175`: when GRUB cannot write its environment — `recordfail_broken=1`, which is ZFS — it emits `if [ $grub_platform = efi ]; then set timeout=${GRUB_RECORDFAIL_TIMEOUT:-30}`, so a failed boot can still be caught at the menu even though it could not be recorded. Measured on the bench: the menu said "executed automatically in 9s" 26 s after it first drew. `GRUB_RECORDFAIL_TIMEOUT` is the knob. Shortening it trades the recovery window for boot time, which is a product decision and is not taken here. |

| # | Measurement owed | Harness |
|---|---|---|
| **O-BR1** | ~~The passphrase prompt under a Plymouth splash on the serial line~~ **Done 2026-10-29**: measured on a bench (§5a) — the prompt is `details`', the patterns before typing still match, the one after typing in `run-secureboot.py policy` did not and is fixed (#182) — and then on the gate: `run-secureboot.py all` on 1.0.0.249, 32 ok, its policy log carrying seventeen redraws of the prompt and the passphrase still unlocking | `run-secureboot.py policy` |
| **O-BR2** | The splash drawn: **amd64 done on a bench 2026-10-29** (§5a, frames at 18/s); arm64 owed (Mac) | `os7lab.py shot` / QMP screendump |
| **O-BR3** | ~~The TPM boot with `splash`: nothing typed, a login prompt reached~~ **Done 2026-10-29**: `run-s5.py all` on 1.0.0.249, every phase PASS, the boot with `quiet splash console=ttyS0,115200` unlocked by the TPM (after this harness's usual #69 re-enrolment) | `run-s5.py boot` |
| **O-BR4** | A machine with a BGRT table shows OS/7's mark and not the firmware's | hardware; no VM has a BGRT table |
| **O-BR5** | The generated login lockup THROUGH THE GREETER on a machine: the dialog constructing (#111) and the mark at natural size and at scale 2. Rendered through librsvg at 1×/2×/4× on 2026-10-29 and legible; the greeter itself not yet | `check-image.py` for the file (built), `os7lab.py --mode Gui` for the screen |
| **O-BR6** | ~~The tile at 16 px and the wordmark at 22 px, rendered, legible~~ **Done 2026-10-29 through librsvg:** the 7 reads at 16 px, the wordmark at 22 px is 52×22 and reads. Not on a device | `rsvg-convert` in `ubuntu:26.04` |

---

## 8. Order of work

1. **Stage 1 — the mark, frozen.** `brand/` with the master, the two derived
   files and a README; `build/lib/brand.py`; `installer/testing/check-brand.py`
   with a self-test that plants seven defects; this plan; DECISIONS.md's
   "Branding" line pointed here. **Built 2026-10-29**
   ([SESSION-BRAND-FREEZE.md](SESSION-BRAND-FREEZE.md)).
2. **Stage 2 — the consumers.** The hicolor icon becomes the tile, byte for
   byte; the login lockup is generated from the white variant and the vendor
   file, at the natural size the current one measured; the website copies
   `brand/`; the orange enters `Tokens.axaml` and the tile reaches the
   applications' About. The check's baseline goes to 0. Each landing is
   rendered (O-BR5, O-BR6) before it is called done. **The image side was
   built the same day, 2026-10-29**: icon, lockup, baseline 0, `check-image.py`
   and hook 0090 taught both, rendered through librsvg; the website's copies and
   the applications remain ([SESSION-BRAND-FREEZE.md](SESSION-BRAND-FREEZE.md) §6).
3. **Stage 3 — the boot splash (BR8). Built 2026-10-29** (§5, §5a,
   [SESSION-BRAND-FREEZE.md](SESSION-BRAND-FREEZE.md) §7). As planned: the theme, the sprites, the command
   line and its migration, the package on both architectures, `check-image.py`
   taught the theme; then O-BR1 to O-BR4. The passphrase prompt is measured
   first, because it is the one thing here that can break a gate.
