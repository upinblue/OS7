# OS/7 Setup — text-mode installer plan

**Status: Phase 0, 1 and 2 complete. Phase 3 next.** The four spikes
this plan gates itself on — S1, S2, S3, S4 — have all passed, and `os7-setup`
now exists: [src/OS7.Setup/](src/OS7.Setup/), running from the ISO's *Install
OS/7* entry on tty1, and it **writes to a disk** — partition table, ESP, LUKS2
container, both pools and the §4.4 dataset hierarchy. There is no operating
system on the result yet; that is Phase 3, and screen 12 says so.
Findings: [../docs/SESSION-PHASE1-SETUP.md](../docs/SESSION-PHASE1-SETUP.md)
and [../docs/SESSION-PHASE2-STORAGE.md](../docs/SESSION-PHASE2-STORAGE.md).

This document answers three questions asked on 2026-08-22 and turns the answers
into a phased plan:

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

**Sibling document, added 2026-08-23:**
[../docs/RELEASE-AND-UPDATE-PLAN.md](../docs/RELEASE-AND-UPDATE-PLAN.md) covers
what happens to a system *after* Setup has installed it — versioning, the update
train, and rollback. Thinking that through changed this plan twice: it closed D8
(§9), and it found that the dataset layout in §4.4 was wrong in a way only
updates expose — **D10, decided 2026-08-23, splits `/var`** instead of placing
all of it inside the boot environment. §4.4 carries the revised layout.

---

## 1. Verdict

| Question | Answer |
|---|---|
| DOS / Win2000-text-phase look on a Linux console | **Yes**, and more faithfully than expected — the Linux VT palette is programmable, so an exact brand colour is a literal palette entry, not an approximation. |
| Exact brand colour | **Yes on the kernel console, measured exact** (via `setvtrgb` and `/etc/vtrgb`; *not* via the kernel command line — §2.1). **No over serial/SSH** unless the client does truecolor — there we fall back. Note D5: the *field* is `#0057ad`, a darkened `#1289ff`, because white text on `#1289ff` is only 3.47 : 1 (§2.2). `#1289ff` is the title stripe on every screen. |
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
| **On every boot, and the one that works** | Ship the palette as **`/etc/vtrgb`**. Ubuntu already enables `setvtrgb.service` in `sysinit.target.wants`, which runs `/sbin/setvtrgb /etc/vtrgb` before the console is displayed. `setvtrgb` accepts a legible hex form — 16 lines of `#RRGGBB` — so the palette is reviewable in a diff. |
| At runtime, e.g. to switch to high-contrast | `setvtrgb <file>` from `kbd`, **plus a full repaint** — see below. |
| ~~From the first kernel frame~~ | ~~Kernel cmdline `vt.default_red/grn/blu` plus `vt.color=0x4f`~~ — **measured useless on Ubuntu, S1 2026-08-24.** |

**Corrected by S1** ([../docs/SESSION-S1-LOOK.md](../docs/SESSION-S1-LOOK.md)),
because the original table above had the priority backwards:

* **The kernel command line does not survive userspace.** `setvtrgb.service`
  ships enabled and replaces the whole palette from `/etc/vtrgb` at ~11.8 s;
  `fbcon` takes the console over at ~14.0 s. There is no window in which the
  command-line palette is ever displayed, and nothing reports an error. Proven
  both ways: with `systemd.mask=setvtrgb.service` the command line gives exactly
  `#0057ad`; stock, it gives Ubuntu's `#006fb8`. BUILD-NOTES #25.
* **`vt.color=0x4f` does nothing.** It is accepted and reads back correctly from
  `/sys/module/vt/parameters/color`, and four different values all left the
  default attribute on palette index 1. Setup must set an explicit foreground and
  background on every cell — which the renderer does by construction — and
  "blue before Setup paints" needs the §2.6 unit rather than a kernel parameter.
* **A palette change does not retint pixels already drawn.** The framebuffer is
  truecolor, so each cell was resolved to RGB when it was written. `F5` is a
  palette switch **and** a full redraw.

The colours themselves are exact. Measured off the framebuffer, every pixel of
1 280×800: index 4 `#0057ad`, index 6 `#1289ff`, index 7 `#c0c0c0`, index 0
`#000000`, high-contrast `#003366`.

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

### 2.3 The font — Fixedsys Excelsior (decided)

**Decided: [Fixedsys Excelsior](https://github.com/kika/fixedsys) is the font
`os7-setup` is drawn in.**

> **Scope narrowed 2026-08-25 by D15.** D9 originally gave Fixedsys to Setup
> *and* to the installed system in non-GUI mode. The second half now belongs to
> **Cascadia Mono** — see §2.8. Everything in this section is still current for
> Setup, which is where the DOS reproduction has to hold; nothing about the
> installer changed. Both fonts ship in the image and neither replaces the
> other.

It is the right choice for more than nostalgia: it is a deliberate simulation of
the 8×16 bitmap font Windows and DOS actually used, drawn to be rendered
*without* antialiasing at 16 px, so it reproduces the reference screenshots
rather than approximating them.

Verified on 2026-08-22 — first against the repository, then **re-verified against
the downloaded release binary**, which is what actually ships. The two differ by
one codepoint, which is exactly why the second pass was worth doing:

| | |
|---|---|
| Licence | **Public domain / CC0.** No attribution obligation, no redistribution constraint — it can be shipped inside the ISO. |
| Release | `v3.09.10` → `FSEX302.ttf`, **580 724 bytes** |
| **SHA256** | **`842f8fbf80f57d867aeb1d2988140d3ea8b4718e5f687035b0a3b66756df3899`** |
| Internal version | `Fixedsys Excelsior 3.022` — note this differs from the release tag; kika's tag versions the ligature work, Darien Valentine's base font is 3.02 |
| Format | **TTF only** (source is an 8.9 MB TTX). The Linux console needs **PSF**, so a conversion step is unavoidable — see §2.5. |
| Design metrics | `unitsPerEm = 160`, i.e. **exactly 10 font units per pixel at 16 px**. The "constructed from 10×10 pixel squares" claim is literally true, so every outline edge lands on a pixel boundary and a 16 px rasterisation is exact, not approximated. |
| Coverage | 6 192 codepoints |

The unused sibling, recorded so nobody has to re-derive it: `FSEX302-alt.ttf`,
580 716 bytes, SHA256
`21b801fe4179dc884a9836d1fbd570ce83249d77204a0a017fbae14aa2dea132`.

**The coverage question was the real risk, and it passed.** The upstream README
only advertises windows-1250/1251/1252/1253/1254, none of which contain
box-drawing characters — and OS/7's entire UI is built from them. Reading the
cmap straight out of `FSEX302.ttf` settled it:

| Unicode block | Coverage |
|---|---|
| Box Drawing `U+2500–257F` | **128 / 128 — complete** |
| Block Elements `U+2580–259F` | **32 / 32 — complete** |
| ASCII, Latin-1 Supplement, Latin Extended-A | complete |
| Greek, Cyrillic, Arrows, Geometric Shapes | partial |

Every glyph the mockups in §3.1 use — `─ │ ┌ ┐ └ ┘ ├ ┤ ═ ║ ╔ ╗ ╚ ╝ ▀ ▄ █ ░ ▒ ▓ •`
and the German umlauts — is present. **Had this failed**, the fallback was
grafting the `U+2500` block in from another font during the PSF build, since box
drawing at 8×16 is a handful of straight lines. It is not needed.

**Use `FSEX302.ttf`, not `FSEX302-alt.ttf`.** The two differ only in programming
ligatures, and ligatures are meaningless in a PSF: the console is a fixed cell
grid with no shaping engine. The conversion discards them either way.

### 2.4 Geometry

* **Two sizes get built**, because 8×16 is unreadable on a modern panel — at
  1920×1080 it gives a 240×67 grid. Pixel-doubling the PSF to **16×32** is a
  mechanical transform (duplicate each bit horizontally, each row vertically)
  and needs no redraw. **Confirmed by S1**: at 1280×800 the 16×32 font gives
  exactly `Console: switching to colour frame buffer device 80x25`, and
  `ioctl(TIOCGWINSZ)` agrees, so the reference geometry is real and the layout
  rule has a number to work from at run time. Setup picks by framebuffer height; the installed console
  gets the same treatment.
* **fbcon handles 16-wide fonts** — the kernel's own `TER16x32` is proof.
* **80×25 is not obtainable everywhere.** UEFI hands us whatever GOP mode the
  firmware likes. At 1280×800 with a 16×32 font you get exactly 80×25; at
  1920×1080 you get 120×33.

  **Layout rule:** chrome is **full-bleed** (title row and status row always
  touch the screen edges, as in the original), body content is laid out in a
  column capped at 80 cells and centred. This keeps the look at any geometry and
  avoids 200-character-wide paragraphs. `os7.setup.geometry=80x25` forces a
  letterboxed exact-80×25 canvas for screenshots and marketing.
* **Before userspace runs, the font is still the kernel's.** `setfont` is a
  userspace tool, so the GRUB entry keeps `fbcon=font:TER16x32` as the closest
  built-in match and Setup calls `setfont` with the Fixedsys PSF before it paints
  its first screen. On the *installed* system, `console-setup` applies it from
  the initramfs (`FRAMEBUFFER=y`), i.e. before the root filesystem is mounted —
  so only the earliest boot frames use the kernel font.

### 2.5 Building the console font

A build-time step, not a runtime one. It belongs in the **build container**, so
no font toolchain ships in the image:

**BUILT AND WORKING since 2026-08-24** —
[`build/lib/build-console-font.sh`](../build/lib/build-console-font.sh) and
[`build/lib/psf.py`](../build/lib/psf.py), run by `build/build.sh` and staged
into `includes.chroot/usr/share/consolefonts/`. The pipeline is two steps longer
than the sketch below, and both additions are mandatory rather than tidying:

```
FSEX302.ttf --otf2bdf -p 16 -r 72 -n--> fixedsys-16.bdf
            --psf.py fixedwidth 8-----> only the cell-width glyphs
            --bdf2psf + FILTERED equivalents + generated symbol set--> 8x16 PSF
            --psf.py fillcell---------> the 15-in-16 seam closed
            --psf.py double-----------> 16x32 PSF
            --psf.py verify-----------> or the build stops
```

* **`fixedwidth`** — Fixedsys is not monospaced across its cmap. 4 230 glyphs
  advance 8 px, 1 575 advance more and 346 advance 0, so `otf2bdf` reports
  `SPACING "P"` with `AVERAGE_WIDTH 77` and `bdf2psf` refuses the file outright:
  *"the width is not integer number."* Dropping the wide glyphs is not a
  workaround for that message — a 16-pixel glyph has nowhere to go in an 8-pixel
  cell, and keeping it hands `bdf2psf` something to truncate. All 352 required
  codepoints advance exactly 8.
* **`fillcell`** — the font draws 15 pixels of ink in a 16-pixel cell (`hhea`
  ascender 130, descender −30, `U+2588` spanning y −30…120 at 10 units/px), so
  the top row of every cell is empty and every vertical box border comes out
  dashed. BUILD-NOTES #27.
* **The equivalents file is filtered, not the stock one.**
  `standard.equivalents` line 217 gives `U+2550 ═` the glyph of `U+2500 ─`, and
  the whole double-line box collapses onto the single-line one. No coverage check
  can see it — the codepoint is mapped, to the wrong picture. BUILD-NOTES #26.

`bdf2psf` is the Debian tool `console-setup` itself uses, so this is the
supported path rather than a bespoke one.

**Rasterise the outlines. Do not extract the embedded bitmaps.** The font
carries an `EBDT`/`EBLC` bitmap strike, and using it looks like the obviously
more authentic choice. It is a trap:

| Strike | ppem | Bit depth | Glyph IDs |
|---|---|---|---|
| 0 | 12 × 12 | 1 | 1699 only — a single glyph |
| 1 | **16 × 16** | 1 | **66 … 4219** |

Glyph 66 is `A`. Everything below it — **space, all ten digits, and every ASCII
punctuation mark**, `U+0020`–`U+0040`, 33 codepoints — has *no* bitmap in the
strike. A conversion built on `EBDT` yields a font with letters and perfect box
drawing and no digits, which is the kind of defect that survives a casual look
at the screen and then shows up in a partition size.

Rasterising is not a compromise here: with `unitsPerEm = 160`, 16 px is exactly
10 units per pixel, so `otf2bdf -p 16` reproduces the intended pixels rather
than interpreting them.

Three things this step must do, and a fourth it must never skip:

1. **Pin the download.** Fetched and hashed on 2026-08-22; assert before use,
   exactly as hook 0020 pins the PowerShell tarball:

   ```
   URL    https://github.com/kika/fixedsys/releases/download/v3.09.10/FSEX302.ttf
   SIZE   580724
   SHA256 842f8fbf80f57d867aeb1d2988140d3ea8b4718e5f687035b0a3b66756df3899
   ```

   The font is **not vendored into this repo** — the hook fetches and verifies
   it, the same shape as PowerShell in hook 0020. Bump the tag and the hash
   together.
2. **Subset to 512 glyphs.** PSF on the Linux console caps at 512, and the font
   has 6 192 codepoints. The subset is ASCII + Latin-1 + the Latin Extended-A
   characters German needs + Box Drawing + Block Elements + the punctuation the
   UI uses. Greek and Cyrillic do not fit alongside that, which is consistent
   with L9 (English and German for v1).
3. **Emit the Unicode table** so `setfont` maps codepoints, not raw byte values.
4. **Assert the result.** `psf.py verify` decodes the produced PSF's Unicode
   table and fails the build on a missing codepoint — and on three things a
   missing-codepoint check alone would pass:

   * a codepoint that is **present but blank**;
   * two shapes that must differ and do not (nine pairs, e.g. `U+2500`/`U+2550`)
     — this is what caught the equivalences;
   * a cell join that does not reach the top row, or a non-join that does — this
     is what catches a regression in `fillcell`.

   [docs/BUILD-NOTES.md](../docs/BUILD-NOTES.md) #13's habit applied to fonts:
   never conclude a step worked because it exited 0. Especially here — `otf2bdf`
   exits **8** on this font at every size while producing a perfectly correct
   BDF, so the exit code is not usable at all (BUILD-NOTES #24).

   **Measured 2026-08-24:** 409 codepoints requested, 434 mapped into 512
   positions, every REQUIRED block complete — ASCII 95/95, Latin-1 96/96, Box
   Drawing 128/128, Block Elements 32/32. Nine decorative extras are absent, six
   of them because they are 16 pixels wide in this font and a PSF cell is 8.

**Optional, not required by the decision:** dropping `FSEX302.ttf` into
`/usr/share/fonts/truetype/fixedsys-excelsior/` costs 580 KB and makes the same
font available to GNOME Terminal and VS Code on GUI installs. The instruction
covers the console; this is a cheap extra, and it is the *only* place the TTF
itself is useful, since the console never reads TTF.

### 2.6 The rest of the boot is blue too

Cheap authenticity, worth doing in phase 4:

* GRUB `gfxterm` theme on the ISO in the same palette (the boot menu is the
  first thing anybody sees).
* `plymouth.enable=0 quiet loglevel=0` on the Install entry, so nothing
  scrolls over the blue.
* A systemd unit that prints `Setup is inspecting your computer's hardware
  configuration...` while udev settles and pools are scanned — the Win2k line,
  and it is honest about what is actually happening.

### 2.7 Where it does *not* work

| Surface | Result |
|---|---|
| Kernel console / fbcon (the normal case) | Exact palette — `#0057ad` field, `#1289ff` stripe. |
| Serial console (headless servers — a real OS/7 target) | Palette cannot be set. Emit 24-bit SGR (`ESC[48;2;18;137;255m`); a truecolor-capable client shows it exactly, others degrade to their own blue. |
| SSH into a running Setup | Same as serial. |
| The Linux VT itself receiving 24-bit SGR | fbcon accepts the sequence but snaps it to the nearest of its 16 palette entries — so on the VT the *palette* is the mechanism, not SGR. Setup must pick per surface, not emit both. |

### 2.8 The installed console — Cascadia Mono (decided)

**Decided 2026-08-25 (D15): the installed system's non-GUI console is
[Cascadia Mono](https://github.com/microsoft/cascadia-code) 2407.24.** Setup
keeps Fixedsys (§2.3); the machine you are left with afterwards does not.

The split is the point rather than a compromise. Setup is a reproduction of
MS-DOS 6.22 and Windows 2000 Setup, and Fixedsys is what those were drawn in.
The installed console is where an administrator works in PowerShell — and
Cascadia is the font Microsoft ships for exactly that, as the Windows Terminal
default. Same house, correct era in each half.

Full measurements: [../docs/SESSION-CASCADIA-CONSOLE.md](../docs/SESSION-CASCADIA-CONSOLE.md).
The load-bearing parts:

| | |
|---|---|
| Licence | **SIL OFL 1.1**, `Copyright 2019-2024 Aaron Bell`, **Reserved Font Name "Cascadia Code"**. Redistribution inside the ISO is permitted; two obligations follow — see below. This is the one place Cascadia is *worse* than Fixedsys, which is CC0 and imposes nothing. |
| Source | **The pinned Ubuntu snapshot**, not GitHub: `fonts-cascadia-code` `2407.24-3`, universe, `all`, 1 355 014 bytes, SHA256 `bf3514c3d4617ccf42906724baf48e98c201c565d9a5bb5a2a7f1378b5845184`. Upstream publishes only a **150 454 761-byte ZIP** of every family × weight × format, so the archive route is 1.3 MB instead of 150 MB, on a domain already pinned by `os7-release.conf`, with a hash published in the archive's own index. |
| File used | `/usr/share/fonts/truetype/cascadia-code/CascadiaMono.ttf`, 688 612 bytes, SHA256 `4bac5958d02c6fcf2b9365c5fdf65b9dc3a500a572c80357da7533d9fca9b098` — the **variable** font, `wght 200..400..700`, default 400 |
| **Mono, not Code** | The two are one drawing; `Cascadia Code` adds programming ligatures, and a PSF is a fixed cell grid with no shaping engine. Same reasoning that rejects `FSEX302-alt.ttf` in §2.3, same conclusion. |
| Design metrics | `unitsPerEm = 2048`; hhea ascender 1900, descender −480 → **line box 2380** against an advance of **1200**. That is **1 : 1.9833** where the console cell is 1 : 2 — the near-coincidence is what makes an exact 8×16 reachable. |
| Coverage | 2 426 codepoints. **All 356 REQUIRED present**, every one of them advance 1200. Of WANTED only `U+21B5` is absent — against nine absent in Fixedsys, including `U+25B2`/`U+25BC`. |

**The pin is the source, not just the version.** The Debian variable font and
the GitHub static instances are both "2407.24" and they do **not** rasterise
alike: with hinting on, 106 of 132 sampled glyphs differ at 8×16. Only the
static files were run through `ttfautohint`. Changing where the font comes from
silently re-renders every console — BUILD-NOTES #53.

**Two licence obligations, both cheap and both easy to forget:**

1. **The licence text ships with the font.** OFL §2 requires the copyright
   notice and licence in every copy. The PSFs are binary, so it is a file:
   `/usr/share/doc/os7-console-font/LICENSE`, staged beside them.
2. **The PSF must not carry the reserved name.** OFL defines a Modified Version
   as any derivative made "by changing formats", so TTF → PSF qualifies, and §3
   then forbids the reserved name on it. Hence **`os7-console-8x16.psf`** and
   `os7-console-16x32.psf` — *not* `os7-cascadia-*`. The asymmetry with
   `os7-fixedsys-*.psf` is deliberate: CC0 imposes no such restriction.

#### Building it — a second route, not a second call to the first

`otf2bdf` → `bdf2psf` (§2.5) **cannot produce an 8×16 cell from this font**, and
no flag combination fixes it. `otf2bdf` scales uniformly — `-rv` changes the
BDF's `RESOLUTION_Y` field and nothing about the outlines — so cell height
follows cell width, and at 1200 : 2380 the only cells reachable are **8×15** and
**9×16**. Measured across `-rh 71…77`; BUILD-NOTES #52. 9×16 is not a way out
either: it makes the cell 18×32 at the large size, and 1280×800 then gives 71×25
instead of the 80×25 §2.4 anchors the whole layout rule on.

So this font is rasterised **straight to the cell**, with the two axes scaled
independently, and written as PSF2 directly. Same engine underneath — FreeType
is what `otf2bdf` uses — but the cell is stated instead of inferred:

```
x_ppem   = W · 2048 / 1200                 advance maps to exactly W px
y_ppem   = H · 2048 / 2380                 line box maps to exactly H px
baseline = H − round(480 / 2380 · H)

   8×16 -> x_ppem 13.653  y_ppem 13.766  baseline row 13
  16×32 -> x_ppem 27.307  y_ppem 27.532  baseline row 26
```

The two ppem values differ by 0.8 %, i.e. 0.06 px of horizontal stretch at an
8 px advance. That is the entire distortion, and it is below the rasteriser's
resolution.

Three things this route does *not* need, and one it does:

* **No `fillcell`.** Cascadia overdraws its cell on purpose — `U+2500` spans
  x −104…1304 and `U+2502` spans y −530…2226 — so strokes meet across cell
  boundaries by construction. `psf.py verify` reported *cell tiling continuous*
  on the first build. This is the exact opposite of trap #27.
* **No pixel doubling.** 16×32 is a second rasterisation, so it carries twice
  the outline detail rather than twice the pixel size. `/etc/default/console-setup`
  ships 16×32 as the default, so this is the size that is actually seen.
* **Barely any `fixedwidth`.** 1 810 of 1 863 glyphs advance exactly 8 px; the
  other 53 are zero-advance combining marks. Fixedsys needed 1 921 glyphs
  dropped.
* **But Block Elements must be synthesised, not rasterised.** `U+2580`–`U+259F`
  are drawn to Cascadia's *win* box (2706 units), not its line box, so the
  eighths land in the wrong rows and `U+2594 ▔` falls outside the cell and comes
  out **blank** — which is precisely how the first build failed `psf.py verify`.
  They are pure geometry, so computing them is exact where rasterising is both
  approximate and wrong: halves and quadrants from `W//2` / `H//2`, eighths from
  `round(n·H/8)`, and the three shades as the CP437 patterns. That last part is
  also a look decision — Cascadia draws `░▒▓` as diagonal hatching, and a
  progress bar built from diagonal hatching does not read as the DOS one.

**Result, measured 2026-08-25:** 409 codepoints, 32 of them synthesised;
`os7-console-8x16.psf` 7 916 bytes (3 027 gzipped) and `os7-console-16x32.psf`
27 548 bytes (5 281 gzipped). `build/lib/psf.py verify`, run unmodified against
both files, returns **`ok` on every line — no failures and no notes**, which the
shipping Fixedsys PSFs do not manage: they emit four notes for glyphs the font
lacks.

**Not yet booted.** Everything above is the artefact measured on the host and in
the build container. `psf.py verify` is a diagnostic like any other, and this
repo's rule is to check a diagnostic against the thing it claims to check — so
the outstanding work is to point `installer/testing/vmscreen` at a console
running this font and read the screen back through it, the way S1 did for
Fixedsys. Until then this is a claim about a file, not about a computer.

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
| 9 | Network — adapter and method | Win2k network settings | arrows, `TAB` `ENTER` `F4` |
| 9S | Static TCP/IP settings | Win2k TCP/IP properties | `TAB` `ENTER` `F4` `ESC` |
| 9W | Wi-Fi — network and authentication | — | arrows, `TAB` `ENTER` `F6` `F4` `ESC` |
| 10 | Copying files | Win2k copy phase | — |
| 11 | Configuring the system | Win2k "Setup is configuring..." | — |
| 12 | Setup is complete | Win2k restart prompt | `ENTER` |
| E | Setup cannot continue (error) | Win2k blue error screen | `ENTER` `F2` `F3` |

**Screen 6 is the gate, not the last check.** It is the last screen before the
one that decides to write, and the writing starts at 10 — so `F` is a decision,
not an action, and the disk is untouched while 7 and 8 are filled in. A screen
may only refuse for something it could have got right, so screen 6 checks the
regional and storage halves and no more. The whole plan is checked once, at
`ExecuteScreen.Start`, which is where "there is no screen left to catch it on"
is a true sentence. It was screen 6's sentence until Phase 3 inserted 7 and 8,
and for one commit that made screen 7 unreachable — BUILD-NOTES #45.

`R` on screen 1 is the interesting one. Win2k's `R=Repair` maps almost exactly
onto a ZFS concept: **import an existing `rpool` and install into a new boot
environment beside the current one**, leaving `rpool/USERDATA` untouched. That
is an upgrade/repair path Calamares would never have given us. Phase 6.

**9S and 9W are lettered, not numbered, and that is the whole reason they are
lettered.** Renumbering the screen list is how BUILD-NOTES #45 happened: a screen
was inserted, and the screen before it went on keeping a promise it could no
longer keep. Everything downstream of 9 — the copy phase, the configure phase,
the Complete screen, and `run-phase3.py walk`, which counts screens by keypress —
keeps its number. 9S is reached only when the method is Static; 9W only when the
chosen adapter is wireless. Neither is a step in a line every install walks, so
neither earns a number in one.

**Screen 9 is after screen 8, and that ordering is load-bearing.** The netplan
*renderer* is decided by the install mode (L24), so the network screen can only
be asked once the mode is known. Putting network before mode would mean writing a
file whose backend has not been chosen yet — which is the same class of mistake
as screen 6 validating an account nobody had typed.

**Screen 9 is no longer optional, and that changed on evidence.** Phase 3 left it
out on the grounds that "DHCP is the default on a fresh Ubuntu install". Both
shipped images were asked on 2026-08-25 and that sentence does not hold for them:
`/etc/netplan/` is empty, `/etc/systemd/network/` is empty, there is no
`cloud-init` to write `50-cloud-init.yaml`, and `systemd-networkd` is not
enabled — only `networkd-dispatcher.service` is, which is its *consumer*. See
L23, and see M1 for the measurement that is still owed before this is stated as a
fact about a running machine rather than about an image.

### 3.1 Mockups

These are the visual spec. `═` stands for the solid **`#1289ff`** stripe under
the title (rendered as full-width reverse-video cells, not as a character).

**The release is chrome, on every screen.** `Version <four fields>` sits
right-aligned on the title row, with the channel in brackets whenever it is not
`stable`. It is drawn by `Frame.Chrome` and never by a screen, for the same
reason the title is: it must be identical everywhere, and the question every
support call opens with is which version this is — so whichever screen somebody
photographed, the answer is in the picture. The value comes from
`/usr/lib/os7/release.json` (RELEASE-AND-UPDATE-PLAN §3.4) and never from a
constant compiled into the binary; §6.7 says why. On a console too narrow to
hold both strings the stamp is DROPPED rather than truncated, because half a
version number still reads as a version number.

**1 — Welcome**

```
 OS/7 Setup                                       Version 1.0.0.32 (development)
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
 OS/7 Setup                                       Version 1.0.0.32 (development)
 ═══════════════════════════════════════════════════════════════════════════════

     Setup will install OS/7 on the disk selected below.

     Use the UP and DOWN ARROW keys to select a disk, then press ENTER.

     ┌──────────────────────────────────────────────────────────────────────┐
     │  nvme0n1   SAMSUNG MZVL21T0HCLR-00B    953 GB   OS/7 installation    │
     │  sda       ATA WDC WD10EZEX-08W        931 GB   empty                │
     │  sdb       SanDisk Cruzer Blade       14.4 GB   -- SETUP MEDIUM --   │
     └──────────────────────────────────────────────────────────────────────┘

     Every partition on the selected disk will be destroyed.

     nvme0n1 already carries OS/7 1.0.0.29, 2 boot environments.
     Press ENTER again to erase it.

 ENTER=Select   F5=Advanced   F3=Quit
```

The medium Setup booted from is listed but never selectable. F5 opens the
per-partition view (create/delete/keep free space) for the dual-boot case.

**An OS/7 already on the disk is named before it is destroyed**, and destroying
it takes a second, deliberate ENTER. Two things make that affordable:

* **Recognising the layout is free.** `os7-esp`, `os7-bpool` and `os7-luks` are
  GPT partition names this installer writes, and they come back in the `lsblk`
  call screen 4 already makes. So the list can say "OS/7 installation" instead of
  "GPT, 3 partitions" for every disk, at no cost.
* **Reading the VERSION costs an import**, so it happens only for the disk
  somebody selected. `bpool` is deliberately unencrypted (§4.2, D3, because GRUB
  must read it), and the boot environment names in it carry the release —
  `os7_<release>_<stamp>`, §4.4. So the version of an installed system is
  readable *without the passphrase*, which is the only reason this works at all:
  the release manifest itself lives on `rpool`, behind LUKS. The import is
  `-o readonly=on -N -f -R <altroot> -d <partition>` and is exported in a
  `finally`.

**This is where the upgrade path attaches.** Screen 1's `R=Repair` — install into
a new boot environment beside the existing one — and `Update-OS7`
(RELEASE-AND-UPDATE-PLAN §4.2) both have to begin by answering *what is on this
disk and which version is it*. That answer is measured now; the offer that uses
it is Phase 6. An offer Setup cannot honour would be worse than no offer.

**Checked on a real disk, not argued for.** `run-phase2.py existing` installs
OS/7 unattended, reboots, and points Setup at that same disk — the only phase in
that harness which does not start from a blank one. It is also the only round
trip the version number gets: written into a dataset name by one boot, read back
off the disk by a different mechanism in the next.

**5 — Storage layout**, the MS-DOS 6.22 homage:

```
 OS/7 Setup                                       Version 1.0.0.32 (development)
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

**9 — Network.** The adapter list is read from `/sys/class/net`, and the one
with carrier is pre-selected — a plugged-in cable is the operator telling Setup
which port they mean, and it costs one file read to notice.

**Test is `F4`, not `T`, on all three of these screens.** `SelectionList`
consumes letters for type-to-find and `TextBox` consumes them as text, so `T`
would mean two things depending on where the cursor was — the one property a
keyboard-driven installer cannot afford, and the same reason `SetupFlow` handles
`F3` and `F5` itself rather than letting screens own them. The first draft of
these mockups used `T` and the code disagreed with them within the hour.

```
 OS/7 Setup                                       Version 1.0.0.32 (development)
 ═══════════════════════════════════════════════════════════════════════════════

     Setup can configure this computer's network connection now.

     ┌──────────────────────────────────────────────────────────────────────┐
     │   enp1s0    Ethernet    Intel I219-V              link up            │
     │   enp3s0    Ethernet    Realtek RTL8111           no link            │
     │   wlp2s0    Wi-Fi       Intel AX211                                  │
     └──────────────────────────────────────────────────────────────────────┘

     ┌──────────────────────────────────────────────────────────────────────┐
     │   Obtain an address automatically (DHCP)                             │
     │   Specify an address (static TCP/IP)                                 │
     │   Leave this computer without a network connection                   │
     └──────────────────────────────────────────────────────────────────────┘

     Setup will apply these settings now and test them before writing them
     to the installed system.

 TAB=Next list   F4=Test   ENTER=Continue   ESC=Back   F3=Quit
```

**9S — Static TCP/IP settings.** Reached only from "Specify an address".
`TAB` moves, exactly as on screen 7, because it is the same kind of object: a
form with more than one thing in it.

```
 OS/7 Setup                                       Version 1.0.0.32 (development)
 ═══════════════════════════════════════════════════════════════════════════════

     Setup needs the addresses this computer will use on enp1s0.

     ┌──────────────────────────────────────────────────────────────────────┐
     │   IP address:        [ 10.42.0.17/24                     ]           │
     │   Default gateway:   [ 10.42.0.1                         ]           │
     │   DNS servers:       [ 10.42.0.1, 1.1.1.1                ]           │
     │   Search domains:    [ corp.example.com                  ]           │
     └──────────────────────────────────────────────────────────────────────┘

     The address is written with its prefix length, as 10.42.0.17/24.
     Leave the gateway blank for a network segment with no route off it.

     Not yet tested.

 TAB=Next field   F4=Test   ENTER=Continue   ESC=Back   F3=Quit
```

**9W — Wi-Fi.** `R` rescans. The auth block below the list changes shape with
the network's advertised security, and 802.1X is the one that is honest about
what it cannot do (L27).

```
 OS/7 Setup                                       Version 1.0.0.32 (development)
 ═══════════════════════════════════════════════════════════════════════════════

     Setup found these wireless networks on wlp2s0.

     ┌──────────────────────────────────────────────────────────────────────┐
     │   CORP-SECURE          ▂▄▆█   WPA2 Enterprise (802.1X)               │
     │   CORP-GUEST           ▂▄▆    WPA2/WPA3 Personal                     │
     │   Branch-Office-5G     ▂▄     WPA2/WPA3 Personal                     │
     │   (enter a hidden network name)                                      │
     └──────────────────────────────────────────────────────────────────────┘

     ┌──────────────────────────────────────────────────────────────────────┐
     │   Authentication:    PEAP / MSCHAPv2                                 │
     │   Identity:          [ bastian@corp.example.com          ]           │
     │   Password:          [ ******************                ]           │
     │   CA certificate:    [ (none — the network is not verified) ]        │
     └──────────────────────────────────────────────────────────────────────┘

     Setup will associate now and report whether it worked.

 R=Rescan   TAB=Next field   F4=Test   ENTER=Continue   ESC=Back   F3=Quit
```

**10 — Copying files**

```
 OS/7 Setup                                       Version 1.0.0.32 (development)
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
 OS/7 Setup                                       Version 1.0.0.32 (development)
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
and it is what makes `Update-OS7` / `Restore-OS7` possible. **Revised 2026-08-23
by D10**, which split `/var`; the earlier drawing put all of `/var` inside the
boot environment.

```
bpool/BOOT/os7_<id>                  -> /boot          part of the BE
rpool/ROOT/os7_<id>                  -> /              the boot environment
rpool/ROOT/os7_<id>/var              -> /var           canmount=off, container only
rpool/ROOT/os7_<id>/var/lib          -> /var/lib       canmount=off, container only
rpool/ROOT/os7_<id>/var/lib/dpkg     -> /var/lib/dpkg  IN the BE — see below
rpool/ROOT/os7_<id>/var/lib/apt      -> /var/lib/apt   IN the BE
rpool/ROOT/os7_<id>/var/cache        -> /var/cache     IN the BE

rpool/DATA/log                       -> /var/log       OUTSIDE ROOT — survives rollback
rpool/DATA/spool                     -> /var/spool     OUTSIDE
rpool/DATA/tmp                       -> /var/tmp       OUTSIDE
rpool/DATA/srv                       -> /srv           OUTSIDE
rpool/DATA/lib/<service>             -> /var/lib/<s>   OUTSIDE — workload + agents
rpool/DATA/snapd                     -> /var/lib/snapd OUTSIDE

rpool/USERDATA/<user>_<uuid>         -> /home/<user>   OUTSIDE ROOT
rpool/USERDATA/root_<uuid>           -> /root          OUTSIDE ROOT
```

The critical property: **`USERDATA` sits outside `ROOT`**, so rolling back a bad
release does not roll back the user's files. Getting this wrong is the classic
boot-environment mistake and it cannot be fixed after the fact.

#### D10 — DECIDED 2026-08-23: `/var` is split, not placed

The same argument applies to `/var`, and the first drawing got it wrong: rolling
back a bad update would also have rolled back `/var/lib/<service>` — a database,
a container store — on the headless product, which is the server target. That is
the `USERDATA` mistake in a second location, and equally unfixable afterwards.

The rule that decides each path, and it is not "system vs. user":

> **A path belongs inside the boot environment if, and only if, rolling it back
> makes the system more correct.** State that something outside this machine also
> believes must stay outside, because the other side does not roll back.

Applied:

| Path | Placement | Why |
|---|---|---|
| `/`, `/usr`, `/etc` | **in** | The system itself. `/etc` in particular: configuration belongs to the release that shipped it, and pulling it out would additionally require `ZFS_INITRD_ADDITIONAL_DATASETS` (see below). |
| `/var/lib/dpkg`, `/var/lib/apt` | **in** | **Non-negotiable.** The package database describes exactly the `/usr` that rolls with it. Shared, a rollback leaves dpkg claiming `libfoo 2.0` while `/usr` holds `1.0`, and the next `apt install` builds on a false premise. |
| `/var/cache` | **in** | Package cache; belongs to the same package state. Worthless to keep, harmless to roll. |
| `/var/log` | **out** | The logs that explain why an update failed must not vanish with the update. Also the journal, which is evidence for compliance. |
| `/var/lib/<workload>` — databases, containers, libvirt, `/var/www`, `/srv` | **out** | The workload's data is not the release's property. |
| `/var/spool`, `/var/tmp` | **out** | In-flight work: mail, cron spool, print jobs. |
| **`/var/lib/snapd`** | **out** | `authd-msentraid` is a snap, and snapd manages its own revisions and rollbacks. Rolling a BE over the top would be two rollback systems fighting over one directory. |
| **Management-agent state** — `authd`'s cache, `microsoft-identity-broker`, `intune-portal`, `azcmagent` (`/var/opt/azcmagent`) | **out** | **The OS/7-specific half of this decision, and the reason the rule above is phrased the way it is.** Entra, Intune and Arc hold the other end of a device identity: enrolment records, certificates that rotate on their own schedule, compliance state. The tenant has no rollback. A machine that comes back from a rollback presenting a stale identity or an expired certificate is a tenant problem, not a device problem — and a much worse one, because it is invisible from the device. |
| `/var/lib/NetworkManager` | **out** | Practical rather than principled: a rolled-back headless server that has lost its network configuration is a site visit. |

`/var` and `/var/lib` themselves are `canmount=off` containers, exactly as the
OpenZFS Ubuntu root-on-ZFS layout does it — the directories live in the BE's root
dataset and only the named children are separate datasets.

**Two consequences the executor has to honour:**

1. **Structure, not discipline.** The out-of-BE datasets hang under `rpool/DATA`,
   *not* under `rpool/ROOT/<be>` with a "do not clone me" property. zsys used a
   property (`com.ubuntu.zsys:bootfs=no`) and zsys is gone; OS/7 writes its own
   clone logic, and a dataset that is not a child of the BE **cannot** be cloned
   into the next one by mistake. Forgetting a property is a bug that ships; the
   hierarchy makes the bug unrepresentable.
2. **A cloned BE must be assembled, not just mounted.** `Update-OS7` mounts the
   clone and then has to mount the `rpool/DATA` datasets into it before chrooting,
   or `apt` runs against a `/var` with holes in it. Release plan §4.2, step 3.

**The honest cost:** a rollback restores the *system*, not the *world*. If an
update migrates an on-disk data format — a database engine major, a container
store layout — rolling the system back leaves the old release facing new data,
and no dataset layout can fix that. This is not a flaw in the split; it is what
"keep the data" means. The mitigation is that the update sequence's `@pre-<version>`
snapshot covers the `rpool/DATA` datasets too, so an operator *can* roll a data
set back deliberately and individually. Automatically, never.

**Boot-path footgun:** the OpenZFS guide notes that any directory required for
booting that becomes its own dataset must be listed in
`ZFS_INITRD_ADDITIONAL_DATASETS` in `/etc/default/zfs`; `canmount=off` datasets
do not count. Nothing in the split above is needed at boot, so the list stays
empty today — but it is the trap waiting for whoever later decides to separate
`/etc`. Recorded as L21.

Full reasoning and the update-time consequences:
[../docs/RELEASE-AND-UPDATE-PLAN.md](../docs/RELEASE-AND-UPDATE-PLAN.md) §4.4.

`<id>` naming: `os7_<release>_<yyyymmddHHMM>`, e.g. `os7_1.0.0.0_202608231430`.
Pinned here because `Restore-OS7 -BootEnvironment` needs a scheme it can list
and sort, and the stub in `powershell/OS7/OS7.psm1` explicitly has none.
`<release>` is the four-field OS/7 product version — the release plan §3.3
defines it, and §3.5 puts the same value in `/etc/os-release` as
`IMAGE_VERSION`. (The example previously read `os7_2026.08.1_…`, from before a
version scheme existed.)

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

Result: a self-contained native ELF with no .NET runtime dependency. It starts
instantly, which matters for something that runs before anything else on the
machine.

**Measured by S2 (2026-08-23):** 3.3 MB arm64 / 3.2 MB x64 for a minimal
program — the ~10–15 MB guessed here was pessimistic — linked against nothing
but `libc` and `libm`, and verified to run inside the ISO with
`/usr/lib/dotnet` deleted.

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

The other side of that shared surface is now specified:
[../docs/RELEASE-AND-UPDATE-PLAN.md](../docs/RELEASE-AND-UPDATE-PLAN.md) §4.2
gives the update sequence, which is this plan's install sequence with a different
root, and §4.3 adds a constraint Setup must honour too — **a boot environment is
a *pair* of datasets** (`rpool/ROOT/<id>` and `bpool/BOOT/<id>`, one per pool,
because D1 forces `bpool`). They are created, activated and destroyed together;
the primitives must treat the pair as one object and never expose the halves.

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
  flushed as one `write(2)`. **Any code path that re-applies the console font
  must invalidate that diff**, because `setfont` clears the screen without
  changing its size and the renderer would then have nothing to send
  (BUILD-NOTES #31). **Emit SGR intensity explicitly on every colour
  change** — `ESC[22;3xm` for indices 0–7 and `ESC[1;3xm` for 8–15. The bright
  sequences `ESC[90m`–`ESC[97m` mean "colour n−90 *and bold*" on the Linux
  console and the bold is sticky, so a later `ESC[36m` renders palette entry 14
  rather than 6. S1 hit exactly that on the progress bar, which is the only
  element in §3.1 that uses the brand blue as a foreground (BUILD-NOTES #30)
* raw mode via `tcsetattr`, `SIGWINCH` handling, guaranteed restore on exit,
  crash and signal
* a hand-written escape-sequence decoder for arrows / F-keys / PgUp / PgDn.
  We target exactly two terminal types (Linux VT, and a serial `vt100`-ish
  client), so a table beats depending on .NET's terminfo layer — which has known
  gaps around F-keys under `TERM=linux`.

Estimated 700–900 lines. Everything above it is screens and steps.

**Confirmed by S1 (2026-08-24)**, with the raw bytes rather than by reasoning.
The Linux console splits its function keys across two encodings:

```
F1 ESC[[A   F2 ESC[[B   F3 ESC[[C   F5 ESC[[E      a form no other terminal emits
F8 ESC[19~  F10 ESC[21~                            the DEC/xterm form, F6 upwards
```

`F3=Quit` and `F5=Advanced` are on the Linux-only side, i.e. exactly the keys a
terminfo layer with gaps would get wrong. All 16 keys tested decoded correctly;
the table is checked at start-up for the property the reader depends on — no
sequence is a proper prefix of another. `installer/spikes/s1-look/Tui/Keys.cs` is
the measured version to start Phase 1 from.

Two things the input path needs and this list omitted:

* **`read(2)` through `LibraryImport`, not `Console.OpenStandardInput()`.** .NET's
  console stream applies termios settings of its own; with it in the path a
  raw-mode reader returned one byte and then reported end of input on an open tty
  (BUILD-NOTES #29).
* **A timer for the bare `ESC` key.** A lone ESC is the prefix of every sequence
  in the table, so a reader blocks on it until the next key arrives. After ESC,
  switch to `VMIN=0`/`VTIME=1` and treat "nothing within ~100 ms" as Escape. §3.1
  screen 2 offers `ESC`; S1 did not test it and Phase 1 owes it.

### 6.5 Proposed source layout

Proposed in 2026-08-22; what Phase 1 actually built is marked, and the three
differences are noted below.

```
installer/
  SETUP-PLAN.md               this document
  src/
    OS7.Setup/                DONE
      Program.cs              arg parsing, --self-test, --print-plan
      Platform.cs             [assembly: SupportedOSPlatform("linux")]
      Tui/                    Frame, Terminal, Input, Geometry, Theme, Widgets/
      Screens/                Welcome, Licence, Regional, Complete, Error,
                              SetupFlow   (Disk, Layout, Confirm, Account, Mode,
                              Network, Copy, Configure are Phases 2-3)
      Model/                  InstallPlan.cs + JSON source-gen, SystemLists.cs
      Steps/                  Phase 2
      Native/                 Termios.cs, Ioctl.cs, Poll.cs, Tty.cs
    OS7.Setup.Tests/          not written; --self-test covers the same ground
                              from inside the binary, and runs in the chroot at
                              BUILD time from hook 0080, which a test project
                              could not
  assets/
    os7-setup.service         DONE - systemd unit, tty1
    grub-theme/               Phase 4
  testing/                    the VM harness: vmconsole (serial), vmscreen
                              (framebuffer, QMP, screendumps, reading the screen
                              back through the console font), run-phase1.py
```

Three deliberate differences from the proposal:

* **`Poll.cs` and `Tty.cs` are not optional extras.** `poll(2)` is what gives a
  bare `ESC` a deadline and what lets Setup notice the console changing under it
  (BUILD-NOTES #31, #32); `ttyname` is what tells a virtual console from a
  serial line, which is the fork §2.7 requires and the reason `setfont -C` gets
  the right console.
* **The palettes are not in `assets/`.** They are generated by
  `build/lib/palette.py` from one table, together with the contrast check that
  keeps D5 honest, and staged to `/usr/share/os7/` (§2.1).
* **No test project.** `--self-test` does the same work from inside the shipped
  binary and runs where it matters: in the chroot, during the ISO build.

### 6.6 The install plan is a file — the `unattend.xml` idea, done right

Every interactive screen only edits one `InstallPlan` object. Execution happens
strictly afterwards, from that object alone. Consequences, all free:

* `os7-setup --unattend plan.json` — unattended installs, which is what a
  Microsoft-shop audience will ask for within a week of the first release.
* `os7-setup --dry-run --print-plan` — the plan without touching a disk.
* **CI can install OS/7 end-to-end** in QEMU over a serial console and assert
  the result. That is the only affordable way to keep an installer honest.

### 6.7 The version is read, never compiled in

Setup shows the OS/7 release on every screen (§3.1) and it takes the number from
`/usr/lib/os7/release.json`, the manifest the build writes
(RELEASE-AND-UPDATE-PLAN §3.4). Not from a constant, not from `/etc/os-release`,
and not from anything the installer composes itself.

**Why not a constant.** A version baked into the binary is correct exactly once,
at the moment it is compiled. The binary is then published into an image whose
package set is fixed later; and the SAME binary is what an upgrade path
(§3 screen 1, `R=Repair`) would run against an already-installed system carrying
a different version entirely. A constant would be right about the medium and
wrong about the target, with nothing on screen saying which one it meant.

**Why the manifest and not `/etc/os-release`.** They agree by construction —
hook 0075 writes both from one value — but the manifest is what
`New-OS7BootEnvironmentName` reads (§6.3). Setup's title bar and the name of the
dataset Setup creates therefore come from one file, and cannot end up quoting
different numbers.

**Why the reader takes a path.** `Release.Load(path)` is parameterised because
the same reader answers two questions: *what is on this medium*
(`/usr/lib/os7/release.json`) and *what is on that disk*
(`/target/usr/lib/os7/release.json`). The second is what an upgrade needs in
order to say what it would replace. Writing it for one path and generalising
later would mean writing it twice.

**What "no manifest" looks like.** `0.0.0.0`, `Known == false`, and
"Version unknown" on screen. Deliberately not a plausible number: an installer
that invents a version is worse than one that admits it does not have one.
`--self-test` fails on it, and because hook 0075 runs before hook 0080, that
failure happens during the ISO build rather than on a booted console.

---

## 7. Where Setup runs

* GRUB / isolinux menu on the ISO gains: **Install OS/7** (default), *Try OS/7
  without installing* (amd64 only — arm64 has no desktop), *Check disc*.
* The Install entry carries the palette, font and quiet parameters:

  ```
  boot=casper fbcon=font:TER16x32 plymouth.enable=0 quiet loglevel=0 os7.setup=1
  ```

  **Shorter than it was, because S1 measured the rest as useless.**
  `vt.default_red/grn/blu` is replaced by `setvtrgb.service` before the console
  is ever displayed, and `vt.color=0x4f` has no observable effect on the default
  attribute at all. The palette comes from `/etc/vtrgb` instead — one file, on
  every boot, for Setup and the installed console alike. §2.1 and BUILD-NOTES
  #25.

* A systemd unit runs `os7-setup` on `tty1` (`StandardInput=tty`,
  `TTYPath=/dev/tty1`, `TTYReset=yes`, `TTYVHangup=yes`), with `getty@tty1`
  masked on that path. `gdm3` is not started when `os7.setup=1`.
* `tty2` keeps a plain root shell for diagnosis, and `os7-setup --serial` on
  `ttyS0`/`ttyAMA0` when a serial console is present — which is a genuine gain
  for headless server installs that Calamares could never have offered.

### 7.1 Packages the ISO still needs

None of these are in the lists today; all are needed at install time:

**Done since 2026-08-24:** `build/config/package-lists/os7-base.list.chroot`
carries the list below, and the console font itself is built by
`build/lib/build-console-font.sh` and staged with a matching
`/etc/default/console-setup`. `build.sh` fails if either half is missing — a
system with the fonts and no config boots in the Debian default and says nothing.

`squashfs-tools` (or `rsync`), `gdisk`, `dosfstools`, `efibootmgr`,
`grub-efi-amd64-signed` / `grub-efi-arm64-signed`, `shim-signed`, `kbd`,
`console-setup`, `util-linux` (present), `zfsutils-linux` + `zfs-initramfs`
(present).

Added by D3 (LUKS2 under ZFS) — these go into the **installed system** as well
as the ISO, or it will not boot: `cryptsetup`, `cryptsetup-initramfs`,
`tpm2-tools`, and a zram provider (`systemd-zram-generator`) for D4.

The Fixedsys font (§2.3) adds nothing to the image beyond the built PSF files
themselves plus `kbd` and `console-setup`, which are already listed. Its
toolchain — `otf2bdf` and `bdf2psf` — belongs in the **build container**, not
in the shipped system.

`calamares` can be dropped from `build/config/package-lists-amd64/os7-desktop.list.chroot`.

**Added by screen 9 (Wi-Fi), arm64 only:** `wpasupplicant`, `iw`, `rfkill`.
Three packages, roughly 4 MB. amd64 needs nothing — see §7.2 for what each image
already carries, measured rather than assumed.

---

### 7.2 The network — what is on the medium, and what reaches the target

**Both shipped images were asked on 2026-08-25** by mounting the squashfs and
reading `/usr/lib/os7/packages.manifest`, `/etc/netplan/`,
`/etc/systemd/network/` and `/etc/systemd/system/`. Nothing here is inferred from
what Ubuntu usually does.

| | arm64 (1.0.0.46, 549 packages) | amd64 (1.0.0.47, 1528 packages) |
|---|---|---|
| `netplan.io`, `netplan-generator`, `libnetplan1` | 1.2 | 1.2 |
| `systemd-resolved`, `networkd-dispatcher` | yes | yes |
| `network-manager` | **no** | 1.54.3 |
| `wpasupplicant` | **no** | 2:2.11 |
| `iw`, `rfkill` | **no** | 6.17, 2.41.3 |
| `modemmanager`, `libnm0` | no | yes |
| wireless firmware (Intel, Broadcom, Realtek, MediaTek, Qualcomm, Marvell) | **yes** | yes |
| `/etc/netplan/` | **empty** | **empty** |
| `/etc/systemd/network/` | **empty** | **empty** |
| `cloud-init` | **absent** | **absent** |
| `systemd-networkd` enabled | **no** | no |

Two things fall out of that table, and they are the whole reason this section
exists.

**First: nothing on this image configures a network by itself, except
NetworkManager.** `/etc/netplan/` being empty is not a neutral state — netplan
generates nothing from nothing, `systemd-networkd` is not enabled, and the only
`.network` files under `/usr/lib/systemd/network/` are for containers, VM
tunnels, 6rd and `.example` templates. What *is* enabled is
`networkd-dispatcher.service`, which reacts to networkd's state changes: the
consumer is switched on and the producer is not. On amd64 the desktop rescues
this, because `network-manager` ships
`/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf` and takes every
device — which is exactly why the GUI product has never shown the problem and the
headless one would. On Ubuntu Server the default that Phase 3 relied on comes from
`cloud-init` writing `/etc/netplan/50-cloud-init.yaml`, and this image has no
`cloud-init`.

**Second: Wi-Fi is nearly free on amd64 and costs three packages on arm64.** The
firmware — the part that is large and that cannot be added later without a
network — is already on both images, via `linux-firmware` and its 19 companion
packages. What arm64 lacks is the userspace: `wpasupplicant` to associate, `iw`
to scan, `rfkill` to notice a hardware kill switch.

**And the drivers are there too — checked, because the opposite was assumed.**
The manifest carries `linux-modules-7.0.0-30-generic` and **no
`linux-modules-extra`**, which on older Ubuntu layouts is where the wireless
drivers lived; the natural conclusion is that this image has Wi-Fi firmware and
no Wi-Fi drivers, which would make D13 unbuildable. Looking inside the squashfs
on 2026-08-25 says otherwise:

| | |
|---|---|
| `kernel/net/wireless/cfg80211.ko.zst`, `kernel/net/mac80211/mac80211.ko.zst` | present |
| `drivers/net/wireless/` | 20 vendor directories — ath, intel, broadcom, marvell, mediatek, ralink, realtek, ti, … |
| wireless driver modules | **197** |
| named spot checks | `ath9k`, `ath11k` (and their `_pci`/`_ahb` variants) |
| `drivers/net/wireless/virtual/mac80211_hwsim.ko.zst` | **present** — which is what makes Phase 3b's Wi-Fi test possible at all |
| modules in the image, total | 8 544 |

Recorded with the wrong guess still attached, because "no `linux-modules-extra`,
therefore no wireless drivers" is a plausible inference from a package list and
it is wrong for this release. The package list is not the module list.

#### The renderer is decided by screen 8, never by what is installed

| Product | Renderer | Why |
|---|---|---|
| amd64, GUI | `NetworkManager` | NM is installed and manages every device; a networkd-rendered netplan would leave GNOME's own network UI describing a connection it does not own |
| amd64, headless | `networkd` | `SystemSteps`' headless path runs `apt-get purge ubuntu-desktop-minimal …` followed by `apt-get autoremove -y --purge`, which takes `network-manager` with it |
| arm64 | `networkd` | NM was never installed |

The renderer therefore comes from `plan.Mode` — a value screen 8 has already
collected — and never from probing the target for `network-manager`. Probing
gives a different answer depending on whether the purge has run yet, which makes
the outcome depend on step order rather than on the plan. L24 states the failure.

#### Applied live, and written to the target — and they are different jobs

Screen 9 does both, and the distinction matters:

* **Live is the verification.** In the live environment the full stack is
  present, so Setup can bring the interface up, take a DHCP lease, associate with
  an access point and see whether any of it worked. This is the only moment at
  which a mistyped Wi-Fi passphrase or a dead VLAN can be caught by the person who
  typed it. It is also the prerequisite for Entra/Intune/Arc onboarding ever
  happening during an install rather than on first boot (Phase 6).
* **The target write is the deliverable.** `/etc/netplan/01-os7-network.yaml`,
  mode `0600`, renderer from the table above.

**The check is never an exit code.** `netplan apply` cannot run in a chroot —
it needs a live systemd, the same reason `SystemSteps` already avoids `systemctl`
there. What *can* run in the chroot is `netplan generate`, which turns the YAML
into `/run/systemd/network/10-netplan-<iface>.network`. Setup reads that
generated file back and asserts the thing it actually cares about — `DHCP=ipv4`,
or the `Address=` that was typed — rather than trusting that `netplan` exited 0.
That is a diagnostic which does not depend on the subsystem it is diagnosing:
it needs no running networkd, no link, and no DHCP server.

#### The plan file, and what must never enter it

`NetworkPlan` follows §6.6 like the rest: screens edit it, execution reads it.
Two fields are `[JsonIgnore]` for the same reason the LUKS passphrase and the
account password are — this is the third instance of that rule, and the first two
were each written as though they were the only one:

* the Wi-Fi PSK
* the 802.1X password

Unattended installs take them from `--wifi-secret-file`, matching the existing
`--passphrase-file` and `--password-file`.

The interface name is the subtler one. §6.6 makes the plan a file that can be
written on one machine and replayed on another, and `enp1s0` is not a property of
the plan — it is a property of the machine that happened to be in front of the
operator. An interactive install writes the chosen name; an unattended plan may
say `"interface": "auto"`, which becomes a netplan `match:` on `en*` for wired and
`wl*` for wireless. L28.

### 7.3 Accounts — root, sudo, and where Entra fits

**Nothing about the current implementation changes.** `SystemSteps` already
creates one account with `useradd -m -s /bin/bash -G sudo` and never gives root a
password, so root keeps the `!` it has in the base image. That is Ubuntu's model
and it is the right one here for three separate reasons, only the first of which
is convention:

1. **Ubuntu's own rationale.** There is no root account to brute-force; `sudo`
   writes each command to `/var/log/auth.log` under the *human's* name; and
   administrative rights move by group membership rather than by a shared secret.
2. **It is the model `authd` assumes.** The Entra broker makes the first user to
   authenticate the **owner**, `owner_extra_groups = sudo` grants them
   administrative rights, and `allowed_users = OWNER` is the default. On a
   managed OS/7 machine, admin rights are meant to arrive from the tenant.
3. **A root password is the thing Entra and Intune exist to remove.** It cannot
   be rotated across a fleet, it appears in no audit trail, and it lives outside
   the tenant that is supposed to be the authority on who may administer the
   device. Offering it as an *option* would be worse than either extreme: a fleet
   in which some machines have one and nobody can say which.

What the plan does add is a **name for the role the local account already
plays**. It is the break-glass account: the credential that still works when
Entra is unreachable, when the network is down, or when the machine has been
rolled back. Screen 7 should say so, because an operator who thinks they are
creating a throwaway first user will choose a throwaway password for the only
non-cloud credential on the machine.

Two consequences worth writing down rather than discovering:

* **A rollback un-says a local password change (L26).** `/etc/shadow` is inside
  the boot environment. D10 moved the Entra/Intune/Arc agent state *out* of the BE
  because the tenant on the other end has no rollback; the mirror-image case —
  the local credential that a rollback quietly reverts — was not considered at the
  time.
* **A second, non-administrative account is not offered.** Ubuntu does not,
  Subiquity does not, and on OS/7 further users come from Entra. Every extra field
  in a text installer is a field somebody types wrong.

Recovery on a machine with a locked root is the GRUB recovery entry, which on an
encrypted OS/7 install sits behind the LUKS passphrase. **M2 owes the measurement**
— whether that entry exists in the generated menu and what it asks for has not
been checked on an installed machine.

---

## 8. Limitations — the honest list

| # | Limitation | Mitigation |
|---|---|---|
| L1 | "ZFS only" cannot be literal: FAT32 ESP is mandatory | none possible; document it |
| L2 | Secure Boot forces GRUB, which forces `bpool` | **accepted (D1)**; ZFSBootMenu stays behind a strategy interface for later (§5) |
| L3 | Swap cannot live on ZFS | zram by default; optional plain partition for hibernation |
| L4 | GRUB has no boot-environment awareness since `zsys` was dropped | **Softened by S3 (2026-08-23).** `grub-common` still ships `/etc/grub.d/10_linux_zfs`, `10_linux` defers to it, and it generated correct `rpool/ROOT/*` entries unassisted — so the generator may not need writing. Two caveats: it also emits zsys-era *Revert* entries OS/7 has no `zsys` to serve, and it titles the menu from `PRETTY_NAME`, so the entry reads "Ubuntu 26.04 LTS" (ties into D8/L16). **And a new hazard:** it emits one `root=ZFS=` per boot environment, so anything appended via `GRUB_CMDLINE_LINUX` lands after it and wins — pinning a dataset there makes every entry in the menu boot the same one. **Partly addressed 2026-08-23:** the generator titles entries from the release manifest rather than `PRETTY_NAME`, so the menu reads the OS/7 version instead of "Ubuntu 26.04 LTS" (release plan §3.5) |
| L5 | The palette can only be set on the kernel console | truecolor SGR fallback on serial/SSH |
| L6 | White on `#1289ff` is 3.47 : 1, below WCAG AA | **resolved (D5)**: field darkened to `#0057ad` (7.07 : 1, AAA), `#1289ff` kept as the title stripe and progress fill; `F5` → `#003366` |
| L7 | 80×25 is not guaranteed on UEFI | full-bleed chrome + 80-column body; `os7.setup.geometry=` to force |
| L8 | No screen reader equivalent to GNOME's Orca | `espeakup`/`speakup` and `brltty` do work on the Linux console (Debian's installer relies on this) — a phase-6 item, not a blocker |
| L9 | Console fonts cap at ~512 glyphs — no CJK, no RTL | English + German for v1; state the limit rather than pretending |
| L10 | Dropping Calamares means owning what it gave us free: partitioning UI, locale/keyboard lists, LUKS, OEM mode, 70+ translations, upstream maintenance | read the system's own data (`/usr/share/zoneinfo`, `xkb/rules/base.lst`, `i18n/SUPPORTED`) instead of hand-maintaining lists; accept the translation loss |
| L11 | NativeAOT needs `clang` + `zlib1g-dev` and restores `Microsoft.DotNet.ILCompiler` from NuGet at publish time — unvalidated against Canonical's `dotnet-sdk-10.0` | **RESOLVED by S2 (2026-08-23).** It works against SDK `10.0.111` with zero warnings, on both arches, and the fallback is not needed. The build container needs `dotnet-sdk-10.0 clang zlib1g-dev libc6-dev binutils` added before Phase 1 — the Dockerfile does not have them yet. **New, smaller limitation:** `LibraryImport` marshals blittable types only, so `Native/Termios.cs` must use a `fixed byte c_cc[32]` and the project `AllowUnsafeBlocks` (BUILD-NOTES #22) |
| L12 | Setup must never offer its own boot medium as a target; NVMe/mmc/multipath naming, pre-existing `rpool` name collisions and stale pool hostids are all real failure modes | explicit exclusion + `zpool import -f -N -R`, `zpool labelclear`, `zgenhostid`; each gets a named error screen |
| L13 | `/etc/hostid` must agree between install time and the target initramfs or the pool will not import at boot | `zgenhostid` into the target *before* `update-initramfs`; classic ZFS-root footgun |
| L14 | Booting straight into Setup loses "try before you install" | keep both GRUB entries |
| L15 | Intune's encryption check only recognises **dm-crypt**, so ZFS native encryption would report as unencrypted | **resolved (D3)**: `rpool` goes inside LUKS2 (§4.5). Cost: no per-dataset encryption, no raw encrypted `zfs send`, and mirrors need one container per disk |
| L16 | Intune's "Allowed distributions" rule matches on `/etc/os-release`; branding OS/7 as its own `ID=` could make every device fail it | keep `ID=ubuntu` / `ID_LIKE=ubuntu` / `VERSION_ID="26.04"`, brand only `NAME` / `PRETTY_NAME` (§4.6). **RESOLVED 2026-08-23 (D8):** the product identity moves to `IMAGE_ID` / `IMAGE_VERSION`, so OS/7 is identifiable as itself without touching a field Intune matches on |
| L17 | LUKS unlock at boot needs a passphrase prompt unless TPM2 enrolment happens at install time | **Tested by S4 (2026-08-23), and bigger than it looked.** `systemd-cryptenroll` writes a valid LUKS2 token and **changes nothing at boot**: `cryptsetup-initramfs` copies no token handler and feeds `cryptsetup open` a passphrase on stdin, which skips token activation. Setup must also install an initramfs hook carrying `libcryptsetup-token-systemd-tpm2.so` *and the libtss2 libraries systemd dlopens* (BUILD-NOTES #20), plus a `local-top` script running before `cryptroot` that calls `cryptsetup open --token-only`. With that, auto-unlock works and a TPM-less machine still prompts. **New risk, now measured — S6 (2026-08-23):** sealing to PCR 7 survives kernel and initramfs updates (PCR 7 came back byte-identical across a from-scratch rebuild, and the hook survived with it) but **not** a Secure Boot policy change — a shim/dbx update drops the fleet back to passphrases. S6 characterised that failure and it is better than feared: `cryptsetup` names the cause instead of failing silently, the passphrase path is intact, and one `systemd-cryptenroll` re-seal against the new PCR 7 restores auto-unlock without touching the initramfs. What is still missing is the escrowed recovery key that would let that run unattended — tracked as U8 in [../docs/RELEASE-AND-UPDATE-PLAN.md](../docs/RELEASE-AND-UPDATE-PLAN.md). Evidence: [../docs/SESSION-S6-UPDATE-CYCLE.md](../docs/SESSION-S6-UPDATE-CYCLE.md) |
| L18 | **`bpool` may still trip the encryption check.** Microsoft exempts `/boot`, but `bpool` is an unencrypted fixed writable partition holding a ZFS *pool member*, not a directly mounted filesystem. Whether the agent maps it to `/boot` and exempts it is undocumented | verify in the first real enrolment test (Phase 6). If it fails: either move `/boot` into `rpool` and switch to ZFSBootMenu (D1 reopens), or carry a custom-compliance script. Do not assume it passes |
| L19 | PSF caps at 512 glyphs; Fixedsys Excelsior has 6 192 codepoints | **RESOLVED by S1 (2026-08-24), and it was never close to binding.** 409 codepoints requested, 434 mapped into 512 positions, every required block complete (ASCII 95/95, Latin-1 96/96, Box Drawing 128/128, Block Elements 32/32). Latin Extended-A turned out unnecessary: German is entirely inside Latin-1, so only the cp1252 extras are carried. **The real risks were not the cap** — `bdf2psf`'s stock equivalences silently replaced the double-line box with the single-line one, and the font draws 15 px of ink in a 16-px cell so every vertical border came out dashed. Both are fixed in the pipeline and both are now asserted; neither was visible in a coverage count. BUILD-NOTES #26 and #27 |
| L20 | `setfont` is userspace, so the earliest boot frames use the kernel's built-in font, not Fixedsys | `fbcon=font:TER16x32` as the closest built-in; `console-setup` from the initramfs on the installed system, so the gap is a few frames (§2.4). **S1 note:** the same is true of the palette and for the same reason, except that there the gap is not a few frames — `setvtrgb.service` runs *before* fbcon takes the console over, so nothing is ever displayed in the pre-userspace palette at all (BUILD-NOTES #25) |
| L22 | **A palette change does not retint pixels already drawn.** The framebuffer is truecolor, so every cell was resolved to RGB when it was written | `F5` is a palette switch **and** a full redraw. Free on a palettised framebuffer, which is why it is easy to miss; measured 2026-08-24 |
| L29 | **The installed console's font carries a licence obligation the installer's does not.** Cascadia Mono is OFL 1.1 with Reserved Font Name "Cascadia Code" (§2.8), so the licence text must ship beside the PSFs and the PSFs must not be named after the font. Fixedsys is CC0 and imposes neither | Two files and a naming rule: `/usr/share/doc/os7-console-font/LICENSE`, and `os7-console-*.psf` rather than `os7-cascadia-*.psf`. Cheap, but invisible once done — nothing in the build fails if the licence file is dropped, so it belongs in the same staging check that already pairs the consolefonts with `/etc/default/console-setup` (`build.sh`) |
| L21 | Any boot-required directory split into its own dataset must be listed in `ZFS_INITRD_ADDITIONAL_DATASETS` (`/etc/default/zfs`), or the system will not boot; `canmount=off` datasets are exempt | Nothing in the D10 split needs this — the list stays empty today. Recorded because it is the trap waiting for whoever later separates `/etc`, and the failure is at boot, not at install (§4.4) |
| L23 | **An installed OS/7 machine comes up with no network at all.** Measured on a booted arm64 machine 2026-08-25 (M1): the interface is `state DOWN` with `qdisc noop`, `ip -o addr` shows only `lo`, the routing table is empty, `systemd-networkd` is *disabled and inactive* while its consumer `networkd-dispatcher` is *enabled*, and `/etc/netplan` and `/run/systemd/network` are both empty. The image explains it — no `cloud-init`, so nothing writes `50-cloud-init.yaml` the way Ubuntu Server does. Phase 3 left screen 9 out on the grounds that "DHCP is the default on a fresh Ubuntu install" | **Screen 9 is mandatory, not owed.** On amd64-GUI the problem is masked by `network-manager`'s `10-globally-managed-devices.conf`, which is why it was never seen; arm64 and amd64-headless have nothing equivalent. Every headless arm64 machine this installer has produced needed a keyboard and a monitor to be reached. Evidence: §10 Phase 3b, "M1, measured"; image side in §7.2. **amd64 is still unmeasured — M3** |
| L24 | **The netplan renderer depends on a step that may not have run yet.** `SystemSteps`' headless path purges the desktop and then runs `apt-get autoremove -y --purge`, which removes `network-manager`. A NetworkManager-rendered netplan written before that purge leaves an installed machine with a config naming a backend that is no longer installed — no network, and no error at install time | The renderer comes from `plan.Mode` (§7.2), never from probing the target, and the network step runs **after** the mode step. Deriving it from the plan makes the outcome independent of step order; probing makes it depend on it |
| L25 | **The Wi-Fi PSK and the 802.1X password reach the target in plaintext**, inside `/etc/netplan/01-os7-network.yaml`. That is netplan's design and Ubuntu does the same; it is not a defect Setup can fix | `chmod 0600` on the file, and it is named here rather than left to be discovered. Neither secret is ever serialised into the plan JSON (`[JsonIgnore]` — the third instance of that rule after the LUKS passphrase and the account password); `--unattend` takes them from `--wifi-secret-file` |
| L26 | **A rollback un-says a local password change.** `/etc/shadow` is inside the boot environment, so a password changed after install is reverted along with `/usr` when a BE is rolled back. D10 moved the Entra/Intune/Arc agent state *out* of the BE because the tenant has no rollback; the mirror-image case — the local break-glass credential — was not considered | Not fixed here, and possibly not worth fixing: moving `/etc` out of the BE is exactly the split L21 warns about. Named so that whoever hits it recognises it, and so that "the local admin password is the credential of last resort" (§7.3) is read with this attached |
| L27 | **802.1X in a text installer has no certificate store.** PEAP/MSCHAPv2 verifies the RADIUS server against a CA certificate, and there is no UI in 80×25 for importing, viewing or trusting one. The honest options are a file path on the install medium, or associating without server verification | The CA field takes a path, and leaving it blank is a **visible choice with its consequence printed on the screen** — "the network is not verified" — never a silent default. TLS client-certificate EAP is out of scope for v1 |
| L28 | **An interface name pinned into the plan file breaks replay.** §6.6 makes the plan a file written on one machine and replayed on another, and `enp1s0` is a property of the machine, not of the plan | An unattended plan may say `"interface": "auto"`, which becomes a netplan `match:` glob — `en*` for wired, `wl*` for wireless. The same trap as `/dev/sdb` in `StoragePlan.Disk`, and the same fix. **L30 is the harder half of this and was not foreseen here** |
| L30 | **THE INTERFACE NAME CHANGES BETWEEN INSTALLING AND RUNNING — on the same machine, with the same NIC.** Measured 2026-08-25: `enp0s5` while installing, `enp0s2` once booted from the disk, MAC `52:54:00:12:34:56` throughout. Predictable names are derived from the PCI topology and **the setup medium is a PCI device**, so removing it renumbers the slots. A netplan file naming the install-time interface matches nothing afterwards, and netplan accepts that in silence: no address, no route, no error — the exact failure this phase exists to prevent, produced *by* the phase | **netplan matches on the MAC, never on the name** (`NetworkPlan.MacAddress`). The device id in the YAML is `os7net` rather than an interface name, so nothing reads as if the name selected the hardware. `Interface` is still recorded — it is what the operator saw on screen 9 and what the log and screen 12 say — but it selects nothing. Asserted in `--self-test` ("a chosen adapter is matched by MAC, never by name") and end to end by `run-phase3b-network.py boot`. **Found only because the deliverable was checked on a booted machine rather than on the disk it was written to** |

---

## 9. Decisions

**Claiming a D or an L number.** Take the next free one **in this file, in a
commit, before you write the entry** — not in a conversation, and not in a branch
nobody has pulled. On 2026-08-25 two sessions independently reached for `D11` and
`L23` within the same hour, and a third had reserved BUILD-NOTES `#50` by saying
so out loud; every one of those claims existed only where it had been said. A
number claimed in the file survives `git pull`, which is what a numbered list
needs in order to keep being one.

**Taken as of 2026-08-25: D1–D15, L1–L30.** The next free numbers are **D16** and
**L31**. If you take one, move this line in the same commit. The same rule and
the same table live at the top of [../docs/BUILD-NOTES.md](../docs/BUILD-NOTES.md)
for its numbers.

`D15` and `L29` are the Cascadia console decision, claimed by a different session
on the same day. **If the table below has no `D15` row, that work has not landed
yet and the number is still spoken for, not free** — check with
`grep -c '^| D15 |' installer/SETUP-PLAN.md`, and look for it in the diff rather
than reusing the number. This is the one weakness the rule still has: a claim can
be recorded here a few minutes before the entry it points at.

| # | Decision | Outcome |
|---|---|---|
| D1 | Bootloader: signed GRUB + `bpool`, or ZFSBootMenu | **DECIDED 2026-08-22 — GRUB + `bpool`.** ZFSBootMenu stays possible behind a bootloader strategy interface; do not hard-code GRUB into the executor |
| D2 | UEFI only, or BIOS as well | **UEFI only for v1** (recommendation, unchallenged) |
| D3 | Encryption: ZFS native or LUKS | **DECIDED 2026-08-22 — LUKS2 under ZFS.** Forced by Microsoft's documented dm-crypt-only detection (§4.5) |
| D4 | Swap: zram only, or offer a partition | **zram default**, partition opt-in for hibernation |
| D5 | Field colour vs. white-text contrast | **DECIDED 2026-08-22 — field `#0057ad`** (`#1289ff` darkened along its own hue, 7.07 : 1, WCAG AAA); `#1289ff` becomes the full-width title stripe and the progress fill; `F5` → `#003366` (§2.2). **Confirmed on a framebuffer 2026-08-24:** every pixel of 1 280×800 carried the exact value, for all four slots and for the high-contrast field. Ratios recomputed from the measured pixels are 7.08 : 1 and 12.61 : 1 |
| D6 | Does the *installed* system keep the blue console palette | recommend yes, opt-out — free brand identity on every tty. **S1 gave it a mechanism and made it free:** the palette has to be shipped as `/etc/vtrgb` for Setup to work at all (§2.1), Ubuntu already enables `setvtrgb.service` to apply it, and that same file is what the installed console reads. Keeping the palette is now the default outcome and *removing* it would be the extra work |
| D7 | Root README brand colour is orange `#ff6912`; Setup is blue `#1289ff` | **Still open as a documentation question.** Proposed wording: orange stays the marketing/logo identity, blue `#1289ff` is the *product* identity — Setup, console, boot menu. Two unqualified "the brand colour is" statements in one repo will otherwise be read as a mistake |
| D9 | Console font | **DECIDED 2026-08-22 — [Fixedsys Excelsior](https://github.com/kika/fixedsys)**, for Setup and for the installed system in non-GUI mode. Public domain/CC0, and verified to carry the complete Box Drawing and Block Elements blocks the UI depends on (§2.3). **Scope narrowed 2026-08-25 by D15:** the second half of that — the installed system in non-GUI mode — is now Cascadia Mono. Fixedsys keeps Setup, which is the half the DOS reproduction depends on |
| D15 | The font of the *installed* console, as distinct from Setup's | **DECIDED 2026-08-25 — [Cascadia Mono](https://github.com/microsoft/cascadia-code) 2407.24** for the installed system in non-GUI mode; `os7-setup` keeps Fixedsys (§2.8). The reasoning is that the two halves are different eras of the same house: Setup reproduces MS-DOS 6.22 and Windows 2000, the installed console is a PowerShell workstation and Cascadia is what Microsoft ships for that. **Measured before deciding, not after:** all 356 REQUIRED codepoints present and uniform-width, only `U+21B5` missing from WANTED against nine missing in Fixedsys, and both built PSFs pass `psf.py verify` with no failures *and no notes*. Comes from the **already-pinned Ubuntu snapshot** (`fonts-cascadia-code 2407.24-3`, 1.3 MB) rather than upstream's 150 MB ZIP. Two consequences that are not free: it is OFL 1.1 rather than CC0 (L29), and it needs a **second build route** because `otf2bdf` cannot produce an 8×16 cell from it (BUILD-NOTES #52). Evidence: [../docs/SESSION-CASCADIA-CONSOLE.md](../docs/SESSION-CASCADIA-CONSOLE.md). **Not yet booted** — the artefact is verified, a console running it is not |
| D8 | `/etc/os-release` identity: brand it as OS/7, or stay `ID=ubuntu` for Intune | **CLOSED 2026-08-23, and without a trade-off.** os-release has fields for exactly this: `IMAGE_ID=os7` + `IMAGE_VERSION=<version>` carry the product identity while `ID=ubuntu` / `ID_LIKE=ubuntu` / `VERSION_ID="26.04"` stay untouched for Intune, and `NAME` / `PRETTY_NAME` / `HOME_URL` are branded as already proposed. Note `BUILD_ID` is the **wrong** field — systemd defines it as the original installation base, which by design does not move during updates. Details and the systemd citation: [../docs/RELEASE-AND-UPDATE-PLAN.md](../docs/RELEASE-AND-UPDATE-PLAN.md) §3.5. One caveat inherited: `/etc/os-release` is a conffile of `base-files`, so the branding must be re-asserted idempotently after every update, not written once at install |
| D10 | Is `/var` inside the boot environment | **DECIDED 2026-08-23 — split, not placed (§4.4).** Package state (`dpkg`, `apt`, `cache`) stays inside the BE, because it describes the `/usr` that rolls with it. Everything a rollback should not un-say moves out to `rpool/DATA`: logs, spool, workload data, snapd, and — the OS/7-specific part — the state of the agents that hold a device identity in Entra, Intune and Arc, because the tenant on the other end has no rollback. Out-of-BE datasets hang under `rpool/DATA` rather than carrying a do-not-clone property, so the mistake is structurally impossible rather than merely discouraged |

| D11 | The account model: a root password, or Ubuntu's locked root plus a `sudo` account | **DECIDED 2026-08-25 — locked root, first account in `sudo`, and no root-password field at any point.** It is what `SystemSteps` already does, so nothing changes in code; what changes is that it is now a decision with three reasons rather than an inherited default. Ubuntu's own: no root account to brute-force, `sudo` logs each command under the human's name, rights move by group. `authd`'s: the first Entra user to authenticate becomes the **owner**, `owner_extra_groups = sudo` grants them administration, `allowed_users = OWNER` is the default — administrative rights are meant to arrive from the tenant. And the fleet's: a root password cannot be rotated across 500 machines, appears in no audit trail, and lives outside the tenant that is supposed to be the authority on the device. Offering it as an *option* is worse than either extreme, because then nobody can say which machines have one. §7.3 |
| D12 | Does screen 9 apply the network live, write it to the target, or both | **DECIDED 2026-08-25 — both, and they are different jobs.** Live is the *verification*: the live medium has the whole stack, so a lease, an association and a reachability check can happen in front of the person who typed the settings. The target write is the *deliverable*. This is the only point at which a mistyped Wi-Fi passphrase is catchable by anyone but a site visit, and it is the prerequisite for Entra/Intune/Arc onboarding ever moving into the install (Phase 6). **The check is never an exit code**: `netplan generate` runs in the chroot, and Setup reads back the `/run/systemd/network/10-netplan-*.network` it produced and asserts `DHCP=` or `Address=` from the file. That diagnostic needs no running networkd, no link and no DHCP server — it does not depend on the subsystem it diagnoses (§7.2) |
| D13 | Wi-Fi in v1, and with what authentication | **DECIDED 2026-08-25 — Wi-Fi is in v1, with WPA2/WPA3-PSK *and* 802.1X (PEAP/MSCHAPv2).** The materials are cheap and measured: amd64 already carries `wpasupplicant`, `iw`, `rfkill` and `network-manager`, arm64 needs three packages and about 4 MB, and the wireless firmware — the part that is large and cannot be fetched without a network — is already on both. 802.1X is in because the product's users are Microsoft-administered fleets, and a corporate WLAN is 802.1X far more often than it is PSK; a Wi-Fi screen that silently cannot join the network it was built for would be worse than none. The cost is L27: there is no certificate store, so server verification is a path or an explicit, printed absence. TLS client-certificate EAP is out of scope |
| D14 | Where the netplan renderer comes from | **DECIDED 2026-08-25 — from `plan.Mode`, and screen 9 therefore sits after screen 8.** amd64-GUI renders to `NetworkManager` because NM is installed and owns every device; amd64-headless and arm64 render to `networkd`. Probing the target for `network-manager` gives a different answer depending on whether the headless purge has run, which would make an installed machine's network depend on step ordering. L24 |

---

## 10. Plan

### Phase 0 — Spikes. Do these before writing any installer code.

Each is cheap, each kills the project's biggest unknowns, and none requires the
UI to exist. **Gate: all four pass before Phase 1 starts.**

| Spike | Question | Method | Done when |
|---|---|---|---|
| **S1** | Does the look actually work | Boot the arm64 ISO under `virtio-gpu-pci`, build and load the Fixedsys PSF, paint the §3.1 mockups from a NativeAOT painter, `screendump` over QMP and inject keypresses as qcodes | **PASS 2026-08-24 (arm64).** All four criteria measured, not eyeballed: the field is exactly `#0057ad` and the stripe exactly `#1289ff`; 126 cells match the font bitmap-for-bitmap; all 16 keys decode. `installer/spikes/s1-look/` + `run-s1.py`; findings in [../docs/SESSION-S1-LOOK.md](../docs/SESSION-S1-LOOK.md) |
| **S2** | Does NativeAOT build in the OS/7 container | `dotnet publish -p:PublishAot=true` for both arches in `os7-build` | **PASS 2026-08-23.** Both arches, zero warnings, 3.2–3.4 MB; the arm64 binary runs in the ISO *with .NET deleted from it*. `installer/spikes/s2-nativeaot/` + `run-s2.sh`; findings in [../docs/SESSION-S2-NATIVEAOT.md](../docs/SESSION-S2-NATIVEAOT.md) |
| **S3** | **Does a ZFS-on-LUKS root install boot at all** | Hand-scripted bash, no UI: partition → `cryptsetup luksFormat` → `bpool` + `rpool` on `/dev/mapper/os7_root` → `unsquashfs` → `zgenhostid` → `crypttab` → chroot config → `update-initramfs` → `grub-install` → reboot | **PASS 2026-08-23 (arm64).** `installer/spikes/s3-zfs-luks.sh`, driven by `installer/spikes/run-s3.py`; findings in [../docs/SESSION-S3-ZFS-LUKS.md](../docs/SESSION-S3-ZFS-LUKS.md) |
| **S4** | Does it survive Secure Boot, and does TPM2 unlock work | Repeat S3 under OVMF with Secure Boot on and Microsoft keys, plus a software TPM (`swtpm`) and `systemd-cryptenroll --tpm2-device=auto` | **PASS 2026-08-23 (arm64).** All three: SB enabled, second boot needs no passphrase, TPM-less VM still boots. `installer/spikes/s4-tpm-enroll.sh` + `run-s4.py`; findings in [../docs/SESSION-S4-SECUREBOOT-TPM.md](../docs/SESSION-S4-SECUREBOOT-TPM.md) |

S3 was the one that mattered, and it **passed on 2026-08-23**: a VM asks for
the passphrase and reaches a login prompt served from
`rpool/ROOT/os7_2026.08.1_*`, with the §4.4 dataset layout intact and `USERDATA`
outside `ROOT`. The script's *sequence* is the deliverable — Phase 2's storage
executor should be a front-end over it, not a re-derivation.

Two corrections it forces on this document, both in §4.4/§5 territory:

* **`boot=zfs` is mandatory on the kernel command line** and nothing generates
  it. `initramfs-tools` defaults to `BOOT=local`, `scripts/local` has no ZFS
  handling at all, and `10_linux_zfs` emits only `root=ZFS=`. Without it the
  machine drops to an initramfs prompt. It also settles the LUKS ordering
  worry: `/scripts/zfs`'s `pre_mountroot()` runs `/scripts/local-top` before
  importing, so `cryptroot` always unlocks first.
* **`root=ZFS=` must not be pinned in `GRUB_CMDLINE_LINUX`** — see L4 below.

**S4 passed on 2026-08-23** and settles D1 on the platform it was decided
for: `shim-signed` chains to Canonical's signed GRUB, the firmware accepts it
against the Microsoft UEFI CA, and ZFS-on-LUKS root comes up underneath. TPM2
auto-unlock works too — but **not** from `systemd-cryptenroll` alone. See L17.

**S2 passed on 2026-08-23** too: NativeAOT builds against Canonical's SDK on
both architectures, and the binary runs in the ISO without .NET present. Note
that the amd64 binary builds fine on an Apple Silicon host even though the amd64
*ISO* cannot (BUILD-NOTES #23), so Phase 1 is not blocked by that.

**S1 passed on 2026-08-24**, and with it **Phase 0 is closed and Phase 1 is
unblocked.** It also corrected this document in three
places, all of which are folded in above and below: §2.1's palette mechanism does
not survive Ubuntu's userspace, §2.5's font pipeline was missing two mandatory
steps, and §7's `vt.color=0x4f` does nothing at all.

Two things S1 hands Phase 1 rather than merely clearing: the console font is
built, asserted and staged into the image by `build/build.sh`, and the key table
in `installer/spikes/s1-look/Tui/Keys.cs` is the measured one.

D3 made S3 harder than it was when this document was first written: the
encryption layer is now part of the *first* spike rather than a later refinement.
That is deliberate. Retrofitting LUKS under an already-working ZFS-root sequence
means redoing the initramfs, `crypttab` and bootloader work anyway.

### Phase 1 — `os7-setup` skeleton
**DONE 2026-08-24.** TUI layer (buffer, renderer, input, theme, both palettes),
screens 1–3 and 12, the error screen and logging. Boots from the ISO's *Install
OS/7* entry, runs on tty1 from `os7-setup.service`, and is strictly
non-destructive — nothing opens a block device, and screen 12 says so.

`./installer/testing/run-phase1.py all` walks the flow and checks it by reading
every screen back through the console font the image ships, rather than by
looking at a screenshot. Findings, including four things this document did not
know, in [../docs/SESSION-PHASE1-SETUP.md](../docs/SESSION-PHASE1-SETUP.md):

* **fbcon defers taking the console over** and completes it only when something
  writes to it. Until then tty1 is the dummy device, `KDFONTOP` returns ENOSYS,
  and no font or palette applies. `fbcon=nodefer` is on the Install entry, and
  Setup re-takes the console anyway (BUILD-NOTES #31).
* **The unit is started by `systemd.wants=` on the boot entry, not by
  `[Install]`.** `Conflicts=` is resolved when systemd builds the transaction and
  `Condition…=` when the job runs, so an enabled unit with a failing condition
  still conflicted `getty@tty1` away — and the LIVE entry booted to a console
  with no login prompt on it (BUILD-NOTES #33). L14 is what that costs.
* **`setfont` exiting 0 does not mean the font loaded**, so Setup checks the
  console's geometry against the grid its font should give.
* **Reading input needs a deadline** — `SIGWINCH` will not break a blocking
  `read`, and neither will a bare `ESC` (BUILD-NOTES #32).
* **A codepoint the installer draws belongs in `psf.py`'s REQUIRED set.** The
  scroll hints were `▲`/`▼`, which Fixedsys does not have and `bdf2psf` had been
  quietly substituting for.

### Phase 2 — Storage
**DONE 2026-08-24.** Disk enumeration and the plan model; screens 4–6; the
executor for partition + pool + dataset creation, driven by S3's proven
sequence; `--unattend` and `--dry-run`. Failure rolls back only what Setup
created.

`./installer/testing/run-phase2.py all` runs it four ways and **reads the disk
back** each time — `sgdisk -p`, `blkid`, `cryptsetup luksDump`, `zpool list`,
`zfs list` — rather than trusting the installer's own log. Findings in
[../docs/SESSION-PHASE2-STORAGE.md](../docs/SESSION-PHASE2-STORAGE.md):

* **The ZFS layer is `New-OS7Storage` in the OS7 PowerShell module**, exactly as
  §6.3 asks, because `Update-OS7` needs the identical logic and the hierarchy it
  creates cannot be corrected after the fact. Setup calls it out-of-process and
  reads one JSON object off stdout.
* **A screen validates what IT collected, never the whole plan.** §6.6 has the
  screens filling the plan in one at a time, so the plan is incomplete for most
  of the flow by design — screen 3 calling the whole-plan check produced an
  error screen reading "no disk selected" three screens before the disk screen.
  The full check runs in exactly two places: `--unattend`, and
  `ExecuteScreen.Start`, whose factory is the only way to build an executor
  because building one begins writing to a disk.

  *Corrected 2026-08-25.* That second place used to be the Confirm screen, which
  was true for exactly as long as the Confirm screen was the last one before the
  executor. Phase 3 put the account at 7 and the mode at 8; screen 6 went on
  demanding an account nobody had been offered a chance to type, and **screen 7
  became unreachable interactively.** Screen 6 now checks
  `ValidateThroughStorage` — the regional and storage halves, which is what
  screens 3 to 5 collected. BUILD-NOTES #45.
* **`--dry-run` runs nothing**, including the parts that only read. The first
  version still started `pwsh` to ask for a boot-environment name, which makes
  the option fail on a machine where the real run would have worked and turns
  its promise into "almost nothing".
* **The passphrase is never in the plan file** — `[JsonIgnore]`, with
  `--passphrase-file` as a separate artefact. A plan file goes into a
  repository, a log and a screenshot.

### Phase 3 — System configuration
**DONE 2026-08-24** — a machine installed by Setup boots into OS/7, verified by
`./installer/testing/run-phase3.py all` on a VM with no ISO attached. Findings in
[../docs/SESSION-PHASE3-SYSTEM.md](../docs/SESSION-PHASE3-SYSTEM.md). Screen 9
(network) is the one part not delivered — see below.

`unsquashfs` with real progress; chroot configuration (locale, timezone,
hostname, users, `zgenhostid`, `update-initramfs`); bootloader install and the
`grub.d` BE generator; screens 7–11; the GUI/headless split (offline
`apt purge` of the desktop for headless, `systemctl set-default multi-user.target`).
*Deliverable:* a machine installed by Setup boots into OS/7.

**The flow was walked by hand on 2026-08-25, and that is what found the gate
bug.** `./installer/testing/run-phase3.py walk` installs by keypress alone —
screens 1 to 7, a typed passphrase and a typed account, to the Complete screen —
because `--unattend` cannot stand in for it: an unattended plan already carries
an account, so it kept passing while the interactive flow could not get past
screen 6. run-phase2's `walk` now stops at the gate, checks that `F` reaches
screen 7, and asks the device whether anything was written (it was not).

**Screen 9 is NOT in the Phase 3 delivery, and that is a decision.** DHCP is
the default on a fresh Ubuntu install and a machine that boots can be configured
from a shell; a machine that does not boot cannot be configured at all. So the
deliverable — *a machine installed by Setup boots into OS/7* — does not depend on
it, and it is the one screen of 7–11 still outstanding. It matters for the
headless product (a rolled-back server with no network is a site visit, release
plan §4.4), so it is owed, not dropped.

> **The first sentence of that paragraph is wrong for this image, and the
> correction is Phase 3b.** Both ISOs were read on 2026-08-25: `/etc/netplan/`
> empty, `/etc/systemd/network/` empty, no `cloud-init`, `systemd-networkd` not
> enabled. On Ubuntu Server the DHCP default comes from cloud-init writing
> `50-cloud-init.yaml`, and this image does not carry cloud-init; on amd64-GUI
> the default comes from NetworkManager, which arm64 and amd64-headless do not
> have. So "a machine that boots can be configured from a shell" holds only for
> somebody standing at the machine — which for the headless product is the site
> visit the paragraph was trying to avoid. See L23 and §7.2, and note that M1 is
> the boot that turns this from a statement about an image into one about a
> computer. The reasoning above is kept rather than edited, because the shape of
> the mistake is the point: the premise was true of Ubuntu and was never asked of
> *this* image.

**Scope decided 2026-08-24, three additions:**

* **TPM2 enrolment is IN this phase.** Spikes S4 and S6 proved it works and what
  it costs, and the layout screen already tells the operator that Setup will seal
  the passphrase to the TPM if it can. Phase 3 builds the initramfs regardless,
  and the enrolment is not `systemd-cryptenroll` alone: it needs the initramfs
  hook carrying the token handler **and the libtss2 libraries systemd dlopens**,
  plus a `local-top` script running before `cryptroot` (BUILD-NOTES #19, #20;
  `installer/spikes/s4-tpm-enroll.sh` is the working version). Doing it later
  means building and re-validating the initramfs twice. U8 — the escrowed
  recovery passphrase unattended re-enrolment needs — stays open and stays on the
  screen.
* **Every chroot step takes the target root as a PARAMETER.** Not
  `StorageSteps.Target` as a constant. `Update-OS7` performs the same sequence
  from step 3 onwards against a *cloned boot environment mounted somewhere else*
  (RELEASE-AND-UPDATE-PLAN §4.2: "everything from 3 onward is S3 code with a
  different root"), and §6.3 already routes Setup's ZFS work through the OS7
  module for exactly this reason. This costs nothing now and cannot be retrofitted
  without re-validating all of Phase 3.
* **Write the release identity onto the TARGET.** `/etc/os-release` branding (D8)
  and the GRUB menu title (L4) both come from the manifest, which Phase 3 copies
  in with the system — so the same values that named the ISO name the installed
  machine. The mechanism exists: `build/config/hooks/0075-release-identity.hook.chroot`
  does it for the image, and re-asserting it is a documented step of the update
  sequence (§4.2 step 6) rather than a one-off.

### Phase 3b — Network, and the account model named

**WRITTEN 2026-08-25. NOT YET RUN ON A MACHINE.** Screen 9 was the one part of
screens 7–11 that Phase 3 did not deliver, on a premise that turns out not to
hold for this image (L23). This phase delivers it, together with the Wi-Fi
screens D13 puts in v1 and the screen-7 wording D11 makes necessary.

The distinction in that first line is the whole of this repository's discipline
and it is not modesty. The code exists, compiles with zero warnings, and passes
**24 new `--self-test` assertions** — 18 on the netplan generator, the `iw scan`
parser, the secret canaries and the step order, and six on the three new screens
— taking the suite from 85 to 109. Every shell string it generates has been
parsed as bash *and* executed in the condition its error message was written for;
every plan file the harnesses build has been parsed as JSON and fed to the real
binary.
**None of that is a boot.** No ISO carries this code, no VM has run it, and M1 —
the measurement that justifies the phase at all — is unmade. Until then every
claim here is a claim about code.

Four defects were found by those checks before a machine could have found them,
and they are listed because the *kind* of check that caught each one is the
transferable part:

| Found by | Defect |
|---|---|
| a captured `iw scan` fed to the parser | **`iw` escapes a hidden SSID rather than emitting it** — a zero-filled SSID arrives as the literal text `\x00\x00…`, not as NUL bytes. A check for `c == '\0'` filtered nothing and would have put every hidden network into 9W's list as a row of gibberish |
| running the generated shell with its target files absent | **`set -euo pipefail` killed the diagnostic before it printed.** `ls` on a glob matching nothing exits non-zero, `pipefail` propagates it, the assignment fails and the script dies three lines above its own `echo`. Demonstrated: the pre-fix script exits 1 with *no output at all*. `bash -n` passes it, so check-image would have shipped it |
| reading SetupFlow's order against the code | **the Wi-Fi scan blocked before the screen it was scanning for was drawn** — and carried a comment claiming the opposite |
| asking what the walk VM actually had | **the walk VM had no NIC**, so screen 9 would have been skipped and the walk would have reported success without ever seeing it. BUILD-NOTES #45 from the other side |

The first two are the same class as everything expensive in this repository: a
tool reported something that *looked* like what was expected, and was not.

*Deliverable:* **a machine installed by Setup boots into OS/7 and is reachable
over the network the operator configured** — proved the same way Phase 3 proved
its own claim, by booting the installed disk with no ISO attached and asking the
machine itself.

#### The measurements come first, and two of them can overturn the phase

This repo's rule is that a diagnostic must be checked against the thing it claims
to check. §7.2's table was read out of two squashfs images; it is evidence about
what is *on* the medium and not about what a computer *does*. Before any code:

| # | Question | Method | Overturns what |
|---|---|---|---|
| **M1** | Does an installed arm64 machine really come up with no network | `run-phase3b-network.py m1`: boot a disk installed by a PRE-3b build, alone, with a virtio NIC, and ask it | **MEASURED 2026-08-25, and L23 holds.** See below — this is no longer a prediction from a squashfs |
| **M2** | What does recovery look like on a machine with a locked root | Boot an installed machine, open the GRUB menu, take the recovery entry, and see what it asks for | D11's closing sentence. If recovery is unreachable without a root password, D11 needs a mitigation, not a footnote |
| **M3** | Does the amd64 headless purge actually remove `network-manager` | Install headless on amd64, then `dpkg -l network-manager` on the booted machine | L24's premise. If `autoremove` spares it, the renderer question is softer than stated — but the fix (derive from `plan.Mode`) is correct either way |

M1 is cheap: the harness already boots an installed disk, and this adds a NIC and
three commands. **It is also the one that decides whether this phase is urgent or
merely owed, so it runs before the model is written, not after.**

#### M1, measured 2026-08-25 — and the machine is worse off than the image said

A disk installed by a **pre-Phase-3b** build (`.vm/phase3`, 2026-08-24), booted
alone with no ISO and a virtio NIC attached, logged into over the serial console
and asked. Verbatim:

```
2: enp0s2: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN
ip -o addr show          1: lo  inet 127.0.0.1/8      (and nothing else)
ip route show            (empty)
systemctl is-enabled systemd-networkd        disabled
systemctl is-active  systemd-networkd        inactive
systemctl is-enabled networkd-dispatcher     enabled
ls -A /etc/netplan/                          (empty)
ls -A /run/systemd/network/                  EMPTY
dpkg -l network-manager                      un  (not installed)
```

**The interface is DOWN with `qdisc noop`, there is no address on it, and the
routing table is empty.** Not "DHCP did not answer" — the link was never brought
up at all. The machine is unreachable, and nothing on it reports a problem.

And the shape L23 predicted is there in one line pair:
`networkd-dispatcher` is **enabled** while `systemd-networkd` is **disabled and
inactive**. The consumer is switched on and the producer is not, so an operator
skimming the enabled units sees a networking service and concludes networking is
configured.

This upgrades L23 from a property of a squashfs to a fact about a computer, and
it settles the phase's priority: screen 9 is not a convenience. Every headless
arm64 machine this installer has ever produced needed a keyboard and a monitor to
be reached.

**What M1 does NOT say.** It is one machine, arm64, in QEMU, installed by one
build. It says nothing about amd64 — where `network-manager` IS installed on the
GUI product and would have brought the link up by itself, which is exactly why
this went unnoticed — and nothing about hardware whose driver behaves differently
from `virtio_net`. M3 is the amd64 half and is still owed.

#### The model

`NetworkPlan`, hanging off `InstallPlan` beside `StoragePlan` and `AccountPlan`,
and validated the way §6.6 and BUILD-NOTES #45 require — `NetworkPlan.Validate`
is called from `InstallPlan.Validate`, which has exactly two callers, and neither
is a screen. `ConfirmScreen` keeps calling `ValidateThroughStorage` and learns
nothing about the network, because at screen 6 nobody has been asked.

```
NetworkPlan
  Interface   string?    "enp1s0", or "auto" for a match: glob (L28)
  Kind        Wired | Wireless
  Method      Dhcp | Static | None
  Address     string?    "10.42.0.17/24" — with the prefix, as netplan wants it
  Gateway     string?
  Nameservers string[]
  Search      string[]
  Wifi        WifiPlan?
      Ssid        string
      Hidden      bool
      Security    WpaPsk | Wpa8021x
      Psk         string?   [JsonIgnore]   L25
      Identity    string?
      Password    string?   [JsonIgnore]   L25
      CaCert      string?   a path, or blank = unverified, printed as such (L27)
```

`Method = None` is an explicit choice on the screen, not the absence of one.
A machine deliberately kept off the network and a machine nobody configured
should not be the same state in the plan file.

#### The screens

Screens 9, 9S and 9W as mocked in §3.1. Three notes that are design, not layout:

* **The adapter list comes from `/sys/class/net`**, with `carrier`, `operstate`
  and the driver name read per interface, and the first wired adapter with carrier
  pre-selected. A plugged-in cable is the operator saying which port they mean.
* **`T` = Test is on all three screens** and is what D12 is about. It applies the
  configuration in the live environment and reports what happened — a lease and
  its address, an association and its signal, or a named failure. Until it has run,
  the screen says *"Not yet tested"* rather than nothing, because a blank field
  reads as approval.
* **`T` is never mandatory.** An operator installing a machine whose network does
  not exist yet — a bench build for a site that is not wired — must be able to
  type a static address and continue. The screen records that it was untested and
  the Complete screen repeats it.

#### The steps

Two, and they are separate because they fail differently:

1. **`NetworkSteps.ApplyLive`** — live environment only, never the target. On
   amd64 the live system has NetworkManager running and owning every device, so
   this path talks to NM there and to `netplan`/`wpa_supplicant` on arm64. This is
   the one place in Setup where "what is installed right now" is the correct
   question, because it is a question about the live medium and not about the
   plan.
2. **`NetworkSteps.WriteTarget`** — takes the target root as a parameter, like
   every other chroot step (Phase 3's second scope note, for `Update-OS7`'s sake).
   Writes `/etc/netplan/01-os7-network.yaml` at mode `0600`, renderer from
   `plan.Mode` (D14), then runs `netplan generate` in the chroot and **reads back
   `/run/systemd/network/10-netplan-*.network`** to assert `DHCP=ipv4` or the
   typed `Address=`. Exit codes are not evidence.

**Ordering: `WriteTarget` runs after the mode step**, so the desktop purge has
already happened and cannot remove the backend the file names (L24).

For the `networkd` renderer, the step must also **enable `systemd-networkd` and
`systemd-resolved` on the target** — §7.2 measured that neither is enabled in the
image, so on a machine installed before this phase nothing did.

Whether `netplan-generator` would have enabled networkd by itself once
`/etc/netplan` has content is **not known and is not assumed here**. It runs as a
systemd generator at boot and might; that has not been measured. Enabling it
explicitly costs one `systemctl` and removes the question, and the answer that
counts comes from the booted machine — `run-phase3b-network.py boot` asks
`systemctl is-active systemd-networkd`, which is a different word from `enabled`
and the exact distinction L23 is about.

#### Packages

`wpasupplicant`, `iw`, `rfkill` into
`build/config/package-lists/os7-base.list.chroot`. They land on amd64 too, where
they are already pulled in by `network-manager`; naming them explicitly costs
nothing and stops arm64's Wi-Fi from depending on a transitive dependency of a
package arm64 does not have. **This touches a build file, and `os7-d7` owns the
build tree — coordinate before editing.**

#### The testing contract

`installer/testing/run-phase3b-network.py`, following `run-phase3.py`'s shape,
and the checks that matter are the ones that ask a computer:

| Target | What is asserted | How |
|---|---|---|
| `walk` | Screens 9 → 9S → 9W are reachable by keypress and `ESC` returns | The framebuffer harness, reading text back through the console font. It extends the existing walk rather than replacing it — screens 1–7 keep their keypress sequence, which is what BUILD-NOTES #45 costs if it changes |
| `static` | **The address typed into 9S is the address the installed machine has.** Install with `10.0.2.99/24`, boot the disk **with no ISO attached**, `ip -o addr show` over serial | QEMU user-mode networking is deterministic — gateway `10.0.2.2`, DNS `10.0.2.3` — so the expected value is known before the VM starts |
| `dhcp` | The installed machine takes a lease | Same boot, expecting `10.0.2.15`, QEMU's fixed first lease |
| `renderer` | A headless install names `networkd` and a GUI install names `NetworkManager`, in the file on the disk | Read `/etc/netplan/01-os7-network.yaml` off the installed disk. Two installs, one assertion each |
| `wifi` | Association and a lease over Wi-Fi, both PSK and PEAP/MSCHAPv2 | `mac80211_hwsim` gives the VM a virtual radio and `hostapd` an access point; `hostapd`'s built-in EAP server (`eap_server=1`, `eap_user_file`) serves the 802.1X half without a real RADIUS. No hardware, and it is reproducible |
| `none` | `Method = None` writes no netplan file and enables nothing | Absence, asserted on the installed disk |

`--self-test` gains the same treatment the screen-6 fix got: the generated netplan
YAML is checked as YAML and the generated chroot script as bash, in hook 0080, so
a broken generator fails the **ISO build** rather than a VM an hour later.

#### Screen 7, amended — wording only

D11 changes no code. It changes one line of `AccountScreen`: *"The account is
added to sudo and administers this machine"* becomes a sentence that names the
role — this is the account that still works when Entra is unreachable — and the
Complete screen repeats it. Nothing is added to the form. L26 goes in the notes,
not on the screen; a rollback semantics lecture does not belong in an 80×25 form.

**Not in this phase, and named so it is not silently assumed:** SSH public-key
import (Subiquity has it, and it is the other half of not stranding a headless
box — Phase 6), VLANs, bonds, bridges, static IPv6, proxy configuration, and
TLS client-certificate EAP.

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
| `installer/README.md` | **DONE 2026-08-24 — rewritten.** It was a Calamares planning document that declared itself superseded and then went on for a hundred lines; three of its four open problems had been closed by this plan (arm64's install path, encryption, branding) and the fourth is not an installer problem at all. It is now a directory README. The one live finding, the `authd-msentraid` snap, is open question 4 in the root README so it does not depend on anyone opening this one. |
| `build/config/package-lists-amd64/os7-desktop.list.chroot` | Drop `calamares`. Its header rationale ("Calamares needs a running desktop, therefore GNOME ships in the live image on every architecture") is now stale — and was already inaccurate, since the file is amd64-only. |
| `build/config/package-lists/os7-base.list.chroot` | Add the install-time tools from §7.1, including the `cryptsetup` family that D3 makes mandatory. |
| Wherever `/etc/os-release` gets branded | **D8 is decided (§9):** brand `NAME` / `PRETTY_NAME` / `HOME_URL`, add `IMAGE_ID` / `IMAGE_VERSION`, and leave `ID` / `ID_LIKE` / `VERSION_ID` alone — Intune's "Allowed distributions" rule reads them (§4.6). Re-assert after every update: the file is a `base-files` conffile. |
| `build/config/auto/config` | `--bootappend-live` gains the palette/font parameters; the ISO grows an Install entry. |
| `build/build.sh` | New stage: `dotnet publish` `os7-setup` into `includes.chroot/usr/lib/os7-setup/`. |
| `Dockerfile` | **DONE 2026-08-24.** `dotnet-sdk-10.0` + `clang` + `zlib1g-dev` + `libc6-dev` + `binutils` (the list S2 established), plus `otf2bdf` + `bdf2psf` for the console font (§2.5). |
| `build/build.sh` (font) | **DONE 2026-08-24.** Calls `build/lib/build-console-font.sh`, which fetches and hash-pins `FSEX302.ttf`, converts to `os7-fixedsys-8x16.psf` and `os7-fixedsys-16x32.psf`, asserts coverage and shape, and stages into `includes.chroot/usr/share/consolefonts/`. The build fails if either PSF or the `console-setup` include is missing. |
| `build/config/includes.chroot/etc/default/console-setup` | **DONE 2026-08-24.** `FONT="os7-fixedsys-16x32.psf.gz"` — set through `FONT=` rather than `FONTFACE`/`FONTSIZE`, because setupcon composes a Debian-named filename out of the latter and would go looking for a font that does not exist. |
| `build/config/includes.chroot/usr/share/os7/palette-*.vtrgb` | **DONE 2026-08-24.** Generated by `build/lib/palette.py`, which also re-checks D5's contrast ratios on every build. Setup applies one of them itself at start-up, because the kernel command line is dead here (§2.1). |
| `/etc/vtrgb` | **Deliberately not wired, because that is D6.** Pointing it at `/usr/share/os7/palette-default.vtrgb` makes the *installed* console keep the palette; Ubuntu's already-enabled `setvtrgb.service` does the rest. Alternatives-managed, so install it as an alternative rather than overwriting the symlink. |
| `installer/spikes/s3-zfs-luks.sh` | **Left as-is on purpose** — it records what S3 actually did, and S3 predates D10. The storage executor deliberately diverges from it: S3 creates `rpool/ROOT/$BE/var` and `/var/log` as BE children, which §4.4 now splits. Do not "fix" the spike; it is evidence, not a template. |
| `powershell/OS7/OS7.psm1` | Gains the BE primitives Setup and `Update-OS7` share (as a *pair* of datasets, §6.3); `Restore-OS7 -BootEnvironment` gets the naming scheme from §4.4. The full cmdlet surface, and the on-disk format these stubs say they lack, are in [../docs/RELEASE-AND-UPDATE-PLAN.md](../docs/RELEASE-AND-UPDATE-PLAN.md) §6. |

Nothing here has been implemented and no file above has been modified by this
plan. A build was running in another session while this was written; the changes
in §11 should be made deliberately, not folded into an in-flight build.

---

## 12. What was verified, and how

Everything load-bearing above was checked on **2026-08-22** rather than
remembered. What was *not* checked is marked as a spike in Phase 0.

| Claim | Source |
|---|---|
| Linux VT palette is programmable per-slot; `setvtrgb` takes 3×16 decimal values (or 16 `#RRGGBB` lines); `vt.default_red/grn/blu` and `vt.color` are kernel parameters — **but on Ubuntu the first is overwritten by `setvtrgb.service` before anything is displayed and the second has no effect at all, measured 2026-08-24** | [setvtrgb(8)](https://www.man7.org/linux//man-pages/man8/setvtrgb.8.html), [Ubuntu setvtrgb(1)](https://manpages.ubuntu.com/manpages/focal/man1/setvtrgb.1.html), [kernel-parameters vt options](https://nv-tegra.nvidia.com/r/plugins/gitiles/linux-2.6/+/55ff9780e7cedc9168dab4d42483c70011c53ace%5E%21/Documentation/kernel-parameters.txt) |
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
| **Fixedsys Excelsior is public domain / CC0**, ships as TTF only, simulates an 8×16 bitmap drawn for 16 px without antialiasing; release `v3.09.10`, `FSEX302.ttf`, 580 724 bytes | [kika/fixedsys](https://github.com/kika/fixedsys) and its release metadata |
| **Its cmap covers Box Drawing `U+2500–257F` 128/128 and Block Elements `U+2580–259F` 32/32**, so every glyph the OS/7 UI draws is present — the upstream README advertises only windows-125x, which would not have been enough | read out of the **downloaded `FSEX302.ttf`**, 6 192 codepoints total (the repository's `FSEX.ttx` has 6 193 — checking the shipped artefact, not the source, is the point) |
| `FSEX302.ttf` is 580 724 bytes, SHA256 `842f8fbf…3899`; `unitsPerEm = 160`, so 16 px is exactly 10 units per pixel | downloaded and hashed 2026-08-22 |
| **The 16 ppem `EBDT` bitmap strike starts at glyph 66 (`A`)** — space, digits and ASCII punctuation have no embedded bitmap, so the conversion must rasterise outlines, not extract bitmaps | `EBLC` strike table read from the same file |
| **Cascadia Mono is SIL OFL 1.1 with Reserved Font Name "Cascadia Code"**, `Copyright 2019-2024 Aaron Bell` — so it may ship inside the ISO, but the licence must ship with it and a PSF built from it may not carry the name (L29) | [LICENSE](https://github.com/microsoft/cascadia-code/blob/main/LICENSE) and the `name` table of the shipped TTF, both read 2026-08-25. OFL's own definition of a Modified Version includes "by changing formats", which is what makes TTF → PSF one |
| **`fonts-cascadia-code 2407.24-3` is in the pinned snapshot's `universe`** — same upstream release as GitHub's, 1 355 014 bytes, SHA256 `bf3514c3…5184`, versus a 150 454 761-byte ZIP as upstream's only release asset | `dists/resolute/universe/binary-arm64/Packages.gz` under `OS7_ARCHIVE_SNAPSHOT`, and the GitHub release API, both read 2026-08-25 |
| **Cascadia's line box is 1200 : 2380 = 1 : 1.9833**, against a console cell of 1 : 2 — which is what makes an exact 8×16 reachable at all; but its Block Elements are drawn to the **win** box (2706), so rasterising them puts the eighths in the wrong rows and blanks `U+2594` | `head`/`hhea`/`OS/2`/`hmtx` and per-glyph outline bounds read out of the shipped `CascadiaMono.ttf` with fontTools 4.63.0; the blank was then reproduced as a real `psf.py verify` failure |
| **`otf2bdf` cannot yield an 8×16 cell from Cascadia** — `-rv` does not scale outlines, so height follows width and only 8×15 and 9×16 exist on that route | swept `-p 14 -rh 71…77` in `os7-build:arm64`, 2026-08-25 (BUILD-NOTES #52). Also confirms trap #24 is not Fixedsys-specific: `otf2bdf` exits 8 on this font too |
| **Both Cascadia PSFs pass `psf.py verify` with no failures and no notes** — 409 codepoints, 32 synthesised, cell tiling continuous, all nine shape distinctions held | the repo's own `build/lib/psf.py verify --expect 8x16,16x32`, run unmodified against the built files, 2026-08-25 |

Contrast ratios in §2.2 were computed from the sRGB relative-luminance formula,
not taken from a source.

**Added 2026-08-25, for §7.2, §7.3 and Phase 3b.** The first four rows were read
out of the shipped squashfs images, not out of documentation — the images are
`OS7-1.0.0.46-arm64.iso` and `OS7-1.0.0.47-amd64.iso`, mounted read-only in the
build container.

| Claim | Source |
|---|---|
| **arm64 carries `netplan.io` 1.2, `systemd-resolved` and `networkd-dispatcher`, and carries no `wpasupplicant`, `iw`, `rfkill` or `network-manager`** (549 packages) | `/usr/lib/os7/packages.manifest` in the arm64 squashfs |
| **amd64 additionally carries `network-manager` 1.54.3, `wpasupplicant` 2:2.11, `iw` 6.17, `rfkill`, `modemmanager` and `libnm0`** (1528 packages) | same file in the amd64 squashfs |
| **Wireless firmware for Intel, Broadcom, Realtek, MediaTek, Qualcomm and Marvell is on *both* images** — 19 `linux-firmware*` packages, architecture-independent | same files |
| **`/etc/netplan/` and `/etc/systemd/network/` are empty on both images, there is no `cloud-init`, and `systemd-networkd` is not enabled — only `networkd-dispatcher.service` is** | directory listings and `/etc/systemd/system/multi-user.target.wants/` in both squashfs images |
| **This is evidence about the image and not about a running machine.** No installed OS/7 machine has been booted with a NIC attached and asked `ip -o addr` | stated as M1 in Phase 3b, deliberately unmeasured as of 2026-08-25 |
| Ubuntu locks the root account by default and puts the first user in `sudo`; the reasons given are no root account to brute-force, `sudo` logging to `/var/log/auth.log`, and rights moving by group membership | [Ubuntu community: RootSudo](https://help.ubuntu.com/community/RootSudo) |
| **`authd` makes the first user to authenticate the "owner"; `owner_extra_groups` (e.g. `sudo`) grants that user administrative rights, and `allowed_users = OWNER` is the default** — the basis for D11's second reason | [authd: group and privilege management](https://documentation.ubuntu.com/authd/latest/reference/group-management/), [authd: configure authd](https://documentation.ubuntu.com/authd/latest/howto/configure-authd/) |
| netplan's renderer defaults to `networkd` when unset; ethernet DHCP is `dhcp4`, static addressing is `addresses` + `routes: [{to: default, via: …}]` + `nameservers`, and Wi-Fi is `wifis:` → `access-points:` | [netplan YAML configuration reference](https://netplan.readthedocs.io/en/stable/netplan-yaml/) |
