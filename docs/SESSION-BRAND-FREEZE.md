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

---

## 6. Stage 2, the same day: the image carries the mark

Asked for after §1–§5 were written, in the same session and the same
worktree. Scope as agreed: the icon becomes the tile, the login lockup is
generated, the baseline goes to 0, `check-image.py` learns both. The website's
copies and the GUI applications stay outside (BR3, BRL7).

### 6a. What changed

| what | how |
|---|---|
| `build/lib/brand.py` | knows the two consumers (`CONSUMERS`) and the vendor file (`VENDOR_REL`); `write` writes them, `verify` holds them. `render_login_lockup()` builds the greeter's file from the master's four shapes and the vendor's 215 paths; `shapes_of()` descends into nested groups because the vendor's file nests three deep |
| `usr/share/icons/hicolor/scalable/apps/os7.svg` | a byte copy of `brand/os7-tile.svg` (1510 bytes; was 1705 with `<text>`) |
| `usr/share/pixmaps/os7-logo-login.svg` | generated: the wordmark in white under `translate(210.5 18) scale(2.7)` — cap height 48 → 129.6 units, the cap line's foot on y=180 where the old text's baseline was, centred in the 880-unit viewBox — then the rule and the vendor group exactly as before. 218 `<path>` elements: 215 vendor, 3 wordmark. Natural size 216×98 unchanged. 13994 bytes; was 15014 |
| `check-brand.py` | §8 now requires each consumer to be the generator's output byte for byte, plus "carries the four shapes and sets nothing in a font" for the lockup; `BASELINE_DEFAULT = 0`. 27 checks, 29 with the website checkout; the self-test's control writes the consumers through the same generator and copies the vendor file in as an input |
| `check-image.py` | three new sections brought home from the squashfs (`desktop.iconsvg`, `desktop.loginsvg`, `desktop.vendorsvg`) and three new checks: the icon equals `brand/os7-tile.svg`, the login mark equals what `brand.py` renders from the repository's master and the IMAGE's vendor file, and it contains no `<text>` |
| hook 0090 | the `fc-match 'DejaVu Sans'` block — "the greeter wordmark's face" — is replaced by `grep -q '<text'` on the lockup, which FAILS the build if a font-set mark ever comes back |
| `os7-desktop-theme/README.md` | says the file is generated and where from |

### 6b. What was measured

**Rendered through librsvg 2.61.3**, in a plain `ubuntu:26.04` container with
`librsvg2-bin` installed — the library behind GdkPixbuf's SVG loader, which is
what the greeter uses, though not the greeter's own natural-size path:

| file | size | result |
|---|---|---|
| lockup on `#0057ad` | 216×98 (natural), 432×196, 864×392 | wordmark crisp at all three; the vendor stripes a soft frame at 1×, resolved at 2× — as the previous file's comment predicted of that mark |
| tile | 16×16, 64×64, 128×128 | the 7 reads at 16 px |
| wordmark on `#0a0d12` | 52×22 (the website header's height), 510×216 | reads at 22 px |

**`check-image.py` against the shipped `OS7-1.0.0.245-amd64.iso`**, hard-linked
into the worktree's `out/` for the run and removed after: the three new checks
go RED on the old medium — 1705 bytes read against 1510 expected for the icon,
15014 against 13994 for the lockup, `<text>` present — and every other check
stays as it was. The rule fires on the thing it is for.

**And that run found a trap in the probe itself.** The first run also failed
"the update and Ubuntu Pro autostart entries are hidden" with `<nothing read>`,
which the committed `check-image.py` passes on the same ISO. The shipped
`upinblue-logo.svg` ends WITHOUT a newline — its last byte is the `>` of
`</svg>` — so `cat` left the cursor there, the next `<<<desktop.autostart>>>`
marker landed on the same line, `parse_sections()` did not recognise it, and
the autostart lines were appended to the vendor section while their own key
never existed. `emit()` now ends every section with an `echo`;
`parse_sections()` strips, so it costs nothing. Any `emit` of a file's contents
had this hole; it was never hit because every file brought home before today
ended in a newline. Recorded as BUILD-NOTES #180. It was written here as #172,
numbered above the main checkout's WORKING COPY, which another session had
taken to #171 (uncommitted) while this worktree sat on 97335e4 (#167) and two
sibling worktrees each held a #169. When the branch was merged on 2026-10-29
`main` had reached #179, so this branch's #172, #173 and #174 became **#180,
#181 and #182** everywhere in its own text. The branch's three commit messages
still carry the old numbers.

### 6c. What was NOT measured

* **The greeter on a machine.** librsvg rendering the file is not
  `LoginDialog._updateLogoTexture` loading it at natural size times the scale
  factor; the previous lockup's size reasoning carries over, but O-BR5 is owed
  until `os7lab.py --mode Gui` shows the login screen with this file.
* **No ISO has been built with it**, so the three new `check-image.py` checks
  have gone red on an old medium and never green on a new one. Hook 0090's
  `<text>` refusal has not run in a build.
* **The website** is unchanged: its three files are to become byte copies of
  `brand/` (BR3) and are not yet.

---

## 7. Stage 3, the same day: the boot splash

Asked for after Stage 2 was committed: the OS/7 mark animated while the machine
boots ([BRAND-PLAN.md](BRAND-PLAN.md) BR8). The session restarted between the
two stages and came back into this worktree; the other session was working in
the main checkout and its own worktrees throughout, building an ISO and running
the `qol2` bench, and nothing of theirs was touched — the bench used here is a
COPY of `.vm/manual` made into this worktree's `.vm/splash`.

### 7a. O-BR1 first, because it is the one thing that can break a gate

On the copied 1.0.0.245 bench, `quiet splash` was put ahead of the harness's
`console=ttyS0,115200` and the machine booted with no TPM, so it had to ask.

* **Without `splash` plymouthd is never started** — the initramfs's
  `init-premount/plymouth` reads `/proc/cmdline` for that word — and `askpass`
  prints `Please unlock disk os7_root: ` itself. That is every OS/7 boot until
  today.
* **With it, plymouthd forces `details` on a serial console.** The string is in
  the shipped binary (`serial consoles detected, managing them with details
  forced`) and the screen agreed: `Display output is not active` on the display,
  the prompt on serial. So **no theme ever draws where a harness looks** — the
  O-BR1 answer does not depend on which theme is installed.
* **The prompt is redrawn per keystroke** (`…os7_root*`, `…**`, …), a wrong
  passphrase prints `No key available with this passphrase.` and
  `cryptsetup failed, bad password or options?`, the right one leads to a login.
  `run-secureboot.py policy` waited for "unlock disk" AFTER typing and would
  have read the redraw as a rejection: BUILD-NOTES **#182**, fixed in the
  harness. Every other harness waits for a login after typing.

### 7b. Then #181, found by trying to deliver the command line

`update-grub` after editing `/etc/default/grub` put `quiet splash` into all four
`10_linux_zfs` entries and into neither OS/7 entry — and `saved_entry` names an
OS/7 entry. `New-OS7MenuFragment` built each fragment by substitution into the
first entry for the running dataset, which from the second activation on is
OS/7's own previous entry: the kernel command line had been copied forward from
a machine's first activation for ever. BUILD-NOTES **#181**. The arguments now
come from the stock generator's entry; `check-be-logic.py` holds it in a new
section (all green, and the first assertion comes back `crashkernel=OLD`
against a copy of the module without the fix).

Two things seen beside it and NOT caused by it, recorded rather than fixed:

* the bench's old fragment listed `os7_1.0.1.0_…` and `os7_1.0.0.246_…`, which
  exist only as snapshots of `os7_1.0.0.245_…` — rebuilding dropped them;
* `grub-reboot` cannot clear `next_entry` on ZFS (`error: sparse file not
  allowed`), so a one-time entry sticks until `grub-editenv … unset next_entry`.

### 7c. What was built

| what | where |
|---|---|
| the renderer | `build/lib/brand_raster.py` — polygons from the master's shapes, nonzero fill, exact horizontal coverage × 8 sub-scanlines, PNG in and out; `+ − × ÷ sqrt` only |
| the sprites | seven PNGs in `build/packages/os7-console/tree/usr/share/plymouth/themes/os7/`, written by `brand.py write` (only when the pixels differ), held by `brand.py verify` |
| the theme | `os7.plymouth`, `os7.script` beside them — hand-written; five layout numbers held equal to `brand.py`'s `SPLASH_LAYOUT` |
| the package | `os7-console`: `Depends: plymouth`, postinst/prerm for the alternative, `triggers` for the initramfs, `brand.py verify` and ten required paths in its build |
| new installs | `SystemSteps.cs`: `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"`, and NOTE lines for the theme in the initramfs and the word in the menu |
| existing machines | migration `80-boot-splash`, BR9's rule |
| the menu | `Get-OS7StockKernelArgument` + `New-OS7MenuFragment` (#181) |
| the checks | `check-brand.py` §9 (17 checks; 44 in all, 46 with the website), self-test now a control plus nine defects; `check-image.py` asks the medium for the alternative, the owner and every theme file; `check-be-logic.py` #181 section; `run-secureboot.py` #182 |

### 7d. What was measured

**The renderer against librsvg 2.61.3**, same size: ink 22 662 against 22 640 px,
mean edge difference 0.58/255, three pixels apart by more than 64. The package
build — which runs `brand.py verify` under Linux on PNGs written under Windows —
passed.

**The package, in `os7img:175`**: install selects OS/7 at 150 over bgrt at 110
in auto mode and fires the initramfs trigger; a manual `bgrt` survives a
reinstall with the postinst's note; removal hands `default.plymouth` back to
bgrt.

**The migration, on the bench**: run 1 rewrote `" console=ttyS0,115200"` to
`quiet splash console=ttyS0,115200` (after a fix: the first version wrote two
spaces), rebuilt the menu, and read every OS/7 entry back with `splash`; run 2:
`nothing to do`.

**The splash, on the bench without a serial console** — screenshots over QMP:
the mark, the prompt in the theme's field, bullets as typed through the VM
keyboard, the bar filling with `cryptsetup: os7_root: set up successfully`
under it, tty1's login about 15 s after the passphrase. The intro at 18 frames
a second by PNG screendumps into the bench container's own `/tmp` (onto the
bind mount it managed 1.3/s): O 0.05 s, S 0.22, 7 0.38, the slash cutting in
from 0.78, complete at 1.06. A slow-motion run (the frame counter at 0.1 per
tick, on the bench only) is what showed the field arriving 0.8 s after the
prompt; the script was fixed and the real-speed capture is of the fixed one.

**GRUB, measured in passing**: every EFI boot waited 30 s in the menu.
`00_header` sets `timeout=${GRUB_RECORDFAIL_TIMEOUT:-30}` on EFI whenever GRUB
cannot write its environment, which on ZFS it cannot. BRAND-PLAN BRL8; a
product decision, not taken.

### 7e. The gate

**The first ISO built from this tree failed — on Stage 2's own instrument.**
Hook 0090, as committed in dc73cf3, asked `grep -q '<text'` of the login
lockup, and the lockup's GENERATED comment says the previous file "was <text>
in DejaVu Sans Bold". The build stopped at
`FAIL: … contains <text>: the greeter mark is set in a font again`, about a
file with no text element in it — GdkPixbuf had loaded it two lines earlier.
`check-image.py`'s matching check had the same blind spot. Both now strip
comments non-greedily and look for a `<text` ELEMENT; the probe was tried on
the real lockup (no element, though the bytes contain `<text`) and on a copy
with one planted (found). It is #151's lesson in a third place: naming a thing
is not doing it. Everything before hook 0090 in that build had gone as planned
— os7-console configured, `default.plymouth` set to the OS/7 theme in auto mode,
the initramfs trigger processed, the installer's `--self-test` green.

**The second build produced `OS7-1.0.0.249-amd64.iso`** (BUILD 249 from host
git, dirty, handed in the way the Makefile's SOURCE_FACTS does — `wsl` is not
reachable from this worktree's session, so the `docker run` the Makefile
composes was issued directly, with a development key in this worktree's
`out/os7-gnupg` and `OS7_REPO_NO_CREDENTIAL=1`).

**`check-image.py amd64` on it**: every brand and splash check green — 
`default.plymouth` is the OS/7 theme in auto mode, owned by os7-console,
`os7.plymouth` and `os7.script` byte for byte the repository's, all seven
sprites decoding to the master's pixels; and Stage 2's three: the icon is the
tile byte for byte, the login mark is what `brand.py` renders from the master
and the SHIPPED vendor file, and it has no `<text>` element. The same eleven
splash checks were red on `OS7-1.0.0.245-amd64.iso`, as they must be. **Five
checks are red on 249 and are the test build's, by construction**: a `preview`
medium trusting only a development key, and no read credential in os7-release
(four lines). A release medium has to pass them; this one was built not to.

**`run-s5.py all` on it: install PASS, boot PASS, cycle PASS, update PASS,
timer PASS — no FAIL line anywhere in the run** (`out/run-s5-249.log`).
What each phase said about this stage's work:

* **boot (O-BR3).** `/proc/cmdline` read
  `… ro boot=zfs quiet splash console=ttyS0,115200 crashkernel=…` — Setup's
  line, then the harness's console. The FIRST boot asked for the passphrase,
  which is #69 on this harness and not the splash: run-s5 installs from a live
  session started with `-kernel`, so the install-time seal is against a PCR 7
  that never saw shim, and the harness re-enrols. That prompt was found on the
  serial line under `splash` and answered — O-BR1, on a gate. The boot after
  it reached a login with nothing typed: 7 of 7.
* **cycle**: 9 of 9. Two activations through `Set-OS7BootEnvironment` — the
  clone, then `Restore-OS7` back — each built OS/7's menu with #181's code, and
  each time the machine booted the environment it was told to. The TPM unlocked
  the third boot too.
* **update**: 8 of 8, 1.0.0.249 → 1.0.0.250 from a served repository, and the
  firstboot list at 1.0.0.250's first boot ran
  `50-tpm2-reseal 60-fstab-esp-ordering 70-domain-home-dataset
  71-domain-homes-in-backup-policy 80-boot-splash` to completion. Migration 80's
  normal case on a machine Setup installed with `quiet splash` is "nothing to
  do", and it exited 0 inside the unit that fails loudly when a migration fails.
* **timer**: 4 of 4.

What this gate CANNOT say: it never looks at a display — its machine has a
serial console, so plymouthd runs `details` there — and it boots every time
with `console=ttyS0`. That the theme draws is the bench's evidence (§7d), not
the gate's.

**`run-secureboot.py all` on the same medium: 32 ok, 0 failed**
(`out/run-secureboot-249.log`) — the medium through its own signed loader, an
install from it, the disk with Secure Boot on unlocked by the TPM with nothing
typed (on the FIRST boot: booting the medium through shim makes the
install-time seal match, #100), and the `policy` control. That last phase is
the one #182 changed, and its serial log shows why it had to be changed:
`Please unlock disk os7_root*` … `Please unlock disk os7_root*****************`,
seventeen redraws of the prompt while the passphrase was typed, which is
plymouthd's `details` plugin under `splash`. The harness now waited past them
for a login, and got one: "the TPM refused to unseal under a changed policy",
"and the passphrase still unlocks it". With the old expectation the first
redraw would have been read as "the machine asked again".

### 7f. What was NOT measured

* **arm64**: no arm64 medium was built and no arm64 machine booted; the theme
  uses only the `script` plugin, which the arm64 manifest's `plymouth` carries,
  and that is an inference from the package list, not a boot.
* **O-BR4**: a machine with an ACPI BGRT table.
* **HiDPI and multi-head**: the bench has one 1280×800 virtio display.
* **Shutdown and reboot** with the theme (the mark without the bar) were not
  photographed.
