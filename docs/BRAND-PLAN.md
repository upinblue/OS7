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

**What is NOT built:** none of the image's surfaces shows this mark yet. The
app icon, the login screen and the boot-splash fallback are still `<text>` in
DejaVu Sans Bold on blue (§4, Stage 2); the boot splash is Ubuntu's `bgrt`
theme with that icon diverted into its fallback, and no installed machine has
ever shown it, because the installer puts neither `quiet` nor `splash` on the
kernel command line (§2c, §5, Stage 3). Nothing in Stage 1 has been rendered on
a machine (BRL5).

Decisions are **BR1–BR8**, limitations **BRL1–BRL7**, owed measurements
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
| **BR8** | **The boot splash is an OS/7 Plymouth theme drawn from these shapes, on both architectures.** A `script`-plugin theme whose sprites are rasterised from the master at build time, set as `default.plymouth`, with `quiet splash` on the installed machine's command line; Ubuntu's `bgrt` theme with the diverted fallback is interim. The animation: the four shapes appear in sequence, the slash last, over a segmented progress bar in the Windows 2000 idiom; Esc shows the details; the passphrase prompt is the theme's. §5 has the mechanism and the measurements it owes. | **Proposed** — nothing built |

---

## 4. The consumers

Every surface that shows the name as a picture, what it shows today, what it
is to show, and when. The check's §8 reads the first two rows on every run.

| surface | file | today | target | stage |
|---|---|---|---|---|
| app icon, `LOGO=os7`, GNOME About | `build/config/includes.chroot/usr/share/icons/hicolor/scalable/apps/os7.svg` | blue tile, `<text>` | byte-identical to `brand/os7-tile.svg` | 2 |
| boot splash fallback | `spinner/bgrt-fallback.png`, diverted by hook 0035 from the icon | follows the icon | goes away with the theme (BR8) | 3 |
| login screen | `build/packages/os7-desktop-theme/tree/usr/share/pixmaps/os7-logo-login.svg` | `<text>` in white, a rule, the vendor mark | a lockup GENERATED from `os7-wordmark-white.svg` and the vendor file, natural size chosen as the current one was (216×98, read out of `LoginDialog`) | 2 |
| website header, footer, tab | `upinblue/os7-web`, `site/brand/` | the master's origin; comment above the `<svg>` tag | byte copies of `brand/` (BR3) | 2, other repository |
| GUI applications | none yet | — | the tile, with the orange entering `Tokens.axaml` as a token first (G9 forbids a colour anywhere else under `src/`) | 2 or later |
| administrator manual | `docs/manual/` | no mark | not planned | — |
| GRUB menus (medium, installed) | text | text | stays text (§6) | — |
| the text-mode installer | Setup's title row | the name in Fixedsys | stays — D5/D7's surface, not this file's | — |

---

## 5. The boot splash (BR8) — mechanism, and what it owes

**Mechanism.** A theme directory `os7/` under `/usr/share/plymouth/themes/`
with `os7.plymouth` (`ModuleName=script`) and `os7.script`, plus the sprites:
four PNGs — O, S, slash, 7 — and the progress bar's block, rasterised from
`brand/os7-wordmark.svg` at build time with `rsvg-convert`, which hook 0035
already installs and removes for the current fallback. `update-alternatives`
points `default.plymouth` at it; `update-initramfs` carries it into the
initramfs, which `Update-OS7` rebuilds anyway. The ground is black (7.28:1);
the ink is orange. No text, because arm64 has no label plugin (§2d) and
because BR2.

**The animation.** The script plugin animates by opacity, position and scale
per frame. The four shapes appear in order — O, S, 7, then the slash cutting
in — within about a second; below them a segmented progress bar fills from
`Plymouth.SetBootProgressFunction`, in the Windows 2000 idiom of blocks rather
than a spinner. `SetDisplayPasswordFunction` draws the passphrase prompt as a
field under the mark; `SetMessageFunction` shows what systemd says; Esc toggles
Plymouth's details, as it does in every theme.

**What changes in the product:**

* `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"` in `SystemSteps.cs` for new
  installs, and a **firstboot migration** for machines already installed — the
  C10 migration record, so it rolls back with the release.
* A package carrying the theme, built on both architectures. Whether it is
  `os7-desktop-theme` or its own package is open: the desktop theme is
  amd64-only and the splash is not.
* The arm64 image loses `plymouth-theme-ubuntu-text`, which the amd64 hook
  already pins and purges.
* The medium's Install entry keeps `plymouth.enable=0`. Setup is the product's
  text-mode face.
* `check-image.py` learns the theme: `default.plymouth` resolves to it, the
  sprites are PNGs of the expected sizes, and the diversion of
  `bgrt-fallback.png` is retired rather than left behind.

**What it must measure before "it works" (also §7):**

* **O-BR1, the passphrase prompt under a splash.** `run-s5.py` and
  `run-secureboot.py policy` expect `Enter passphrase` / `passphrase for` on the
  serial line and type there. With `splash`, Plymouth owns the prompt and
  shows it on serial consoles through its text renderer. Whether the harnesses'
  patterns still match is the one real risk to the gate, and it is a
  measurement, not a guess.
* **O-BR2, the splash seen.** Screenshots over QMP during boot — `os7lab.py
  shot` or `vmscreen` — on amd64 here; `run-phase3.py boot` cannot watch an
  installed amd64 machine (#132). arm64 boots only on the Mac.
* **O-BR3, the TPM boot with a splash**: `run-s5.py boot` must still reach a
  login prompt with nothing typed.
* **O-BR4, hardware with a BGRT table**: that the theme shows OS/7's mark and
  not the firmware's, which is the whole point of replacing `bgrt`.

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
| **BRL2** | The image's consumers do not carry the mark: the icon and the login screen are `<text>` in DejaVu Sans Bold, and the boot fallback is rasterised from the icon. Debt 2, held as a baseline that may fall and may not rise. |
| **BRL3** | No installed machine boots with `splash`; the current boot mark has never been shown on one (by the code, §2c — not measured on a screen). |
| **BRL4** | The arm64 image ships `plymouth-theme-ubuntu-text`, the Ubuntu wordmark's text splash; the debrand hook that removes it is amd64-only. Dormant without `splash`. |
| **BRL5** | Nothing in Stage 1 has been rendered: not the master at the website's 22 px, not the white variant on the field, not the tile at 16 px. |
| **BRL6** | The website's light theme shows the orange mark on white at 2.88:1, below the 3:1 floor for non-text contrast. BR4 says nothing about a white ground; the website decides whether the light theme darkens the mark or the ground. |
| **BRL7** | The GUI applications have no brand token: `check-gui-tokens.py` forbids a colour literal anywhere under `src/` outside `Tokens.axaml`, so the orange must enter as a token before the tile can appear in an application. |

| # | Measurement owed | Harness |
|---|---|---|
| **O-BR1** | The passphrase prompt under a Plymouth splash on the serial line: do `run-s5.py` and `run-secureboot.py policy` still see and answer it | `run-s5.py boot` with a wrong-policy firmware, `run-secureboot.py policy`, once Stage 3 exists |
| **O-BR2** | The splash drawn: a screenshot sequence of a boot on amd64, and one on arm64 (Mac) | `os7lab.py shot` over QMP; `vmscreen` |
| **O-BR3** | The TPM boot with `splash`: nothing typed, a login prompt reached | `run-s5.py boot` |
| **O-BR4** | A machine with a BGRT table shows OS/7's mark and not the firmware's | hardware; no VM has a BGRT table |
| **O-BR5** | The login lockup generated from the white variant, rendered at scale 1 and 2 at natural size, and the greeter still constructing (#111) | `check-image.py` for the file, `os7lab.py --mode Gui` for the screen |
| **O-BR6** | The tile at 16 px and the wordmark at 22 px, rendered, legible | `rsvg-convert` in the build container; eyes |

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
   rendered (O-BR5, O-BR6) before it is called done.
3. **Stage 3 — the boot splash (BR8).** The theme, the sprites, the command
   line and its migration, the package on both architectures, `check-image.py`
   taught the theme; then O-BR1 to O-BR4. The passphrase prompt is measured
   first, because it is the one thing here that can break a gate.
