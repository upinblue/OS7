# Session — the mark, frozen: one wordmark, a generator, and a check that holds every copy to it

**2026-10-29.** Asked: lock the logo down, bring it into the distribution, and
— as the crowning piece — show it animated while the machine boots. This
session did the first of the three and measured what the other two need. It
ran on the x64 Windows host, in a worktree of its own because another session
was working in the main checkout; nothing here is committed.

The result is Stage 1 of [BRAND-PLAN.md](BRAND-PLAN.md): `brand/` with the
master and two generated files, `build/lib/brand.py`,
`installer/testing/check-brand.py`, and the plan itself. Stages 2 and 3 are
written down with the measurements they owe and are not built.

---

## 1. What was found before anything was written

### 1a. Four marks, none decided

| where | what | font | colour |
|---|---|---|---|
| website header, footer (`upinblue/os7-web`, `site/brand/os7-wordmark.svg`) | drawn geometry — an ellipse ring, a bezier spine, two polygons | none | `#ff6912` on transparent |
| website tab (`favicon.svg`) | the 7 from the wordmark on an orange tile | none | `#ff6912`, `#ffffff` |
| image: `LOGO=os7`, GNOME About (`usr/share/icons/hicolor/scalable/apps/os7.svg`) | 128-unit blue tile, `#1289ff` stripe, "OS/7" | DejaVu Sans Bold, `<text>` | `#0057ad`, `#1289ff`, `#ffffff` |
| image: boot splash (`spinner/bgrt-fallback.png`, diverted by hook 0035) | the icon above, rasterised at 128 px | DejaVu Sans Bold | as above |
| image: login screen (`usr/share/pixmaps/os7-logo-login.svg`) | "OS/7", a rule, the vendor's 215 paths in white | DejaVu Sans Bold, `<text>` | `#ffffff` on `#0057ad` |

[DECISIONS.md](DECISIONS.md) "Branding" had said since 2026-08 that logo, boot
splash and website are orange `#ff6912`, and that the orange stays off the
desktop and the text phase. The website followed the first half; the image's
three marks followed neither — they were blue and white, in a font, each with
a comment arguing for `<text>` ("a path version cannot be read or corrected by
a human"). The website's file argues the opposite, and has the stronger case:
a wordmark in live text is three marks, one per platform's fallback font, and
converting a proprietary font's glyphs to outlines is not licensed in public.

The website's wordmark and favicon turned out to be ONE geometry: the favicon's
path is the wordmark's 7 byte for byte under
`translate(-65.07, 9.16) scale(0.664)`. That transform puts the 7's
bounding-box centre at (32.013, 32.002) in a 64-unit tile — computed, and now
asserted.

### 1b. The numbers behind "which ink on which ground"

WCAG relative luminance through `palette.py`'s `ratio()`, the arithmetic D5
used for the Setup field:

| ink | ground | ratio |
|---|---|---|
| `#ff6912` | `#0a0d12` (the website's page) | 6.75 : 1 |
| `#ff6912` | `#000000` | 7.28 : 1 |
| `#ff6912` | `#0057ad` (the Setup field) | **2.45 : 1** |
| `#ffffff` | `#0057ad` | 7.08 : 1 |
| `#ff6912` | `#ffffff` | 2.88 : 1 |

So the orange mark is a dark-ground mark, white is the ink for the field, and
the website's light theme shows the mark at 2.88:1 on white — below the 3:1
non-text floor, which is now BRL6 and the website's to decide.

The mark's weight, recomputed from the coordinates: the O and S are stroked at
6.4; the slash polygon is 6.90 wide where a 6.4 stroke of its slope cut
horizontally would be 6.91; the 7's diagonal is 6.84 against 6.84; the O and S
stand on y 12..60. The comment in the file says all of this; the check now
asserts it.

### 1c. The boot path, read out of the code and the manifests

* `SystemSteps.cs` writes `GRUB_CMDLINE_LINUX_DEFAULT=""`. An installed machine
  boots with neither `quiet` nor `splash`, and Plymouth draws a graphical theme
  only with `splash`. **The diverted boot mark has, by the code, never been
  shown on an installed machine.** The medium's live entry carries
  `quiet splash`; the Install entry carries `plymouth.enable=0` on purpose.
* `default.plymouth` is `bgrt`, which shows the FIRMWARE's logo on hardware
  with an ACPI BGRT table and the diverted PNG only as a fallback. An OS/7 mark
  at boot therefore needs an OS/7 theme, not a replaced file.
* The LUKS seal is `--tpm2-pcrs=7`, PCR 7 alone. A Plymouth theme changes the
  initramfs and not PCR 7, so the TPM unlock is not in this work's path. The
  passphrase prompt is: `run-s5.py` and `run-secureboot.py policy` match
  `Enter passphrase` / `passphrase for` on the serial line, and with `splash`
  Plymouth owns that prompt (O-BR1).
* `OS7-1.0.0.245-arm64.packages.manifest` lists `plymouth-theme-ubuntu-text`,
  the Ubuntu wordmark's text splash. The hook that pins and purges it on amd64
  is in `hooks-amd64/`. Dormant for the same reason as the mark.

### 1d. What Plymouth has on the image

`dpkg -L` in `os7img:175` (amd64), the `1.0.0.245` manifests for both:

| | amd64 | arm64 |
|---|---|---|
| `plymouth`: `details.so`, `text.so`, **`script.so`**, `two-step.so`, `tribar.so`, drm and framebuffer renderers | yes | yes |
| `plymouth-theme-spinner` (carries `bgrt` too) | yes | no |
| `plymouth-label` (`label-pango.so`) | yes | **no** |
| `plymouth-theme-ubuntu-text` | purged | shipped |

The script plugin is in the core package on both architectures; the one that
renders text is on one. A theme set in a font would exist on amd64 only, which
is BR2's third reason.

---

## 2. What was built

| what | where |
|---|---|
| the master | `brand/os7-wordmark.svg` — the website's four shapes, attribute for attribute (compared by `shapes_of()`); only the prose moved from above the `<svg>` tag to inside the element, so `<svg` is at byte 39 |
| the white variant | `brand/os7-wordmark-white.svg` — generated: the master's head and shape block with `#ff6912` → `#ffffff`, nothing else |
| the tile | `brand/os7-tile.svg` — generated: the master's 7 under the favicon's transform, on a 64-unit orange tile with a 12-unit corner |
| the generator | `build/lib/brand.py` — `write`, `verify`, `show`; validates the master before deriving anything; imports `palette.py` for the field colour |
| the check | `installer/testing/check-brand.py` — nine sections, 26 checks, 28 with a website checkout beside the repository |
| the plan | `docs/BRAND-PLAN.md` — BR1–BR8, BRL1–BRL7, O-BR1–O-BR6, the consumer table, the boot-splash mechanism |
| the readme | `brand/README.md` |

The check's `--self-test` is a CONTROL and seven planted defects, and the
control came first on purpose: a copy of `brand/` with a scan root in which
every consumer carries the mark must pass at baseline 0, so that a rule no
tree can satisfy is caught before the defects are. The seven: a coordinate
moved in the master; a `<text>` element in a brand file; `<svg` pushed past
byte 256; a third colour; a derived file edited by hand; a consumer that stops
carrying the mark; an icon one byte off the tile. All eight results green.

Run against the sibling `os7-web` checkout (`OS7_WEB_ROOT`), §9 confirms the
website's wordmark has the master's geometry and its favicon is the tile's 7
under the same transform. From a worktree the default sibling path resolves to
nothing and the section says NOT CHECKED (BRL1).

---

## 3. What was NOT measured

* **Nothing was rendered.** Not the master at the website's 22 px, not the
  white variant on the field, not the tile at 16 px, nothing on a framebuffer.
  The contrast ratios are arithmetic.
* **No boot.** The `splash`-less command line is read out of `SystemSteps.cs`,
  not watched on a screen; "never shown on an installed machine" is a
  conclusion from the code.
* **No Plymouth theme exists**, so none of O-BR1–O-BR4 could be attempted.
* **The website was not changed.** BR3 reverses the copy direction; the
  website's three files are to become byte copies of `brand/` and have not.

---

## 4. What it changes

* [DECISIONS.md](DECISIONS.md) "Branding" now points at BRAND-PLAN as the
  authority and records that, until this day, the line was true of the website
  alone.
* `CLAUDE.md` gains the authority row, the check in the command list, and
  `brand/` and `lib/brand.py` in the layout.
* [HANDOFF.md](HANDOFF.md) gains a row saying what is built and, in the same
  breath, that the image still shows the old marks.
* The image's three marks are now DEBT with a number — 2 — rather than three
  reasonable comments. Stage 2 takes it to zero; the check refuses to let it
  rise.

---

## 5. What comes next

**Stage 2 — the consumers** (BRAND-PLAN §8): the hicolor icon becomes the tile
byte for byte; the login lockup is generated from the white variant and the
vendor file at the natural size the current one measured (216×98, read out of
`LoginDialog`); the website copies `brand/`; the orange enters `Tokens.axaml`
as a token before the tile reaches an application. Each landing rendered
(O-BR5, O-BR6).

**Stage 3 — the boot splash** (BR8): a `script`-plugin theme with sprites
rasterised from the master, `quiet splash` on new installs and by firstboot
migration on existing ones, the package on both architectures, the arm64 text
theme gone, `check-image.py` taught the theme. O-BR1 first — the passphrase
prompt on the serial line is the one thing here that can break a gate.
