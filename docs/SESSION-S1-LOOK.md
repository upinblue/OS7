# Session S1 — does the look actually work?

Answers spike **S1** from [../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md)
§10, the last of the four Phase 0 spikes and the only one about something a
person sees. Its pass criteria are stated as measurements, so this session takes
them as measurements:

> Field is exactly `#0057ad`, stripe exactly `#1289ff`, box glyphs render,
> arrows and F-keys decode.

**Date:** 2026-08-24 · **Method:** the arm64 ISO booted in QEMU with a
`virtio-gpu-pci` display, screendumps taken over QMP and analysed pixel by pixel,
keypresses injected over QMP as qcodes to a USB keyboard.

- The console font pipeline: [`build/lib/build-console-font.sh`](../build/lib/build-console-font.sh) + [`build/lib/psf.py`](../build/lib/psf.py)
- The palette: [`build/lib/palette.py`](../build/lib/palette.py) — one table, and the contrast check that keeps D5 honest
- The painter: [`installer/spikes/s1-look/`](../installer/spikes/s1-look/) — NativeAOT C#
- The guest side: [`installer/spikes/s1-look.sh`](../installer/spikes/s1-look.sh)
- The harness: [`installer/spikes/run-s1.py`](../installer/spikes/run-s1.py)

```bash
./installer/spikes/run-s1.py all
```

Roughly 20 minutes on Apple Silicon, five boots. Screendumps land in `.vm/s1/shots/`.

## Verdict

| # | Question | Result |
|---|---|---|
| **Q1** | Is the field exactly `#0057ad` and the stripe exactly `#1289ff`? | **Yes, to the byte** — and only through `setvtrgb`. The kernel command line is silently reverted before anything is displayed. The one element that came out wrong was the progress bar, and it took a *regional* check to see it. |
| **Q2** | Do the box glyphs render? | **Yes.** 126 cells compared against the font bitmap-for-bitmap, all identical. Two problems had to be fixed in the font build first, and neither was visible in a coverage count. |
| **Q3** | Do arrows and F-keys decode? | **Yes, all 16 tested.** §6.4's claim about `TERM=linux` is confirmed exactly: F1–F5 arrive in a form no other terminal uses. |
| **Q4** | Is the reference geometry real? | **Yes.** 1280×800 with the 16×32 font gives exactly the 80×25 §2.4 predicts. |
| **S1** | | **PASS on arm64. Phase 0 is closed.** |

Three things in SETUP-PLAN are wrong or incomplete as written; they are §2.1's
palette mechanism, §2.5's font pipeline, and §7's kernel command line. All three
are corrected below and in the plan itself.

---

## Q1 — the colours

### They are exact

Read out of the framebuffer, one palette slot at a time, by filling the screen
with an explicit background index and taking a screendump:

| Slot | Intended | Measured | Use |
|---|---|---|---|
| 4 | `#0057ad` | **`#0057ad`** | the field |
| 6 | `#1289ff` | **`#1289ff`** | the title stripe and the progress fill |
| 7 | `#c0c0c0` | **`#c0c0c0`** | the status bar and the selection |
| 0 | `#000000` | **`#000000`** | text on both of those |
| 4 (`F5`) | `#003366` | **`#003366`** | the high-contrast field |

Not "close to", not "reads as" — every pixel of 1 024 000 carried the exact
value. D5 is confirmed on real hardware-shaped output rather than on a
manual page. The contrast ratios recomputed from these measured values are
7.08 : 1 for the field and 12.61 : 1 for high contrast, matching §2.2's 7.07 and
12.58 to rounding.

The colours are always selected **by palette index**, never as 24-bit SGR. §2.7
predicted that fbcon accepts a truecolor sequence and snaps it to its nearest
palette entry; nothing here tested that, because nothing here emits one.

### But the kernel command line does not survive userspace

§2.1 gives two mechanisms and reads as though the first is primary:

| When | Mechanism |
|---|---|
| From the first kernel frame | `vt.default_red/grn/blu`, `vt.color` |
| At runtime | `setvtrgb` |

On Ubuntu the first one is **overwritten before anything is ever displayed**.

```
live-red = 1,222,57,255,0,118,44,204,…      (not what the command line said)
vtrgb    = /etc/console-setup/vtrgb
service  = active
```

`setvtrgb.service` ships **enabled** in `sysinit.target.wants`, runs
`/sbin/setvtrgb /etc/vtrgb`, and `/etc/vtrgb` is an alternatives symlink to
Ubuntu's own console palette. It ran at 11.8 s; `fbcon: Taking over console` came
at 14.0 s. **There is no window in which the command-line palette is visible.**

Measured both ways, because measuring it once gives a confidently wrong answer:

| Boot | Command line | Result |
|---|---|---|
| `systemd.mask=setvtrgb.service` | palette on the cmdline | field `#0057ad` — the kernel mechanism works |
| stock | the same cmdline | field `#006fb8` — Ubuntu's palette, index 4 |
| stock + `setvtrgb <OS/7 file>` | the same cmdline | field `#0057ad` — the remedy works |

Testing only the stock boot concludes "the kernel parameters do not work".
Testing only the masked boot ships an installer that comes up in Ubuntu's
colours on every machine. Both were needed.

**Consequence.** The palette is a file applied by `setvtrgb`, not a kernel
parameter. `setvtrgb` accepts a legible hex form — 16 lines of `#RRGGBB` — so it
is reviewable in a diff, and [`build/lib/palette.py`](../build/lib/palette.py)
generates both palettes from one table and re-checks D5's contrast ratios on
every build.

The image now ships them at **`/usr/share/os7/`**, deliberately *not* as
`/etc/vtrgb`. Setup applies the palette itself when it starts — it has to, since
the command line is dead here — and whether the **installed console** keeps it
afterwards is **D6**, which is still open. Pointing `/etc/vtrgb` at these files
is the one-line change that decides it, and Ubuntu's already-enabled
`setvtrgb.service` would then do the rest. So D6 went from "recommended, no
mechanism" to "one symlink, and the file is already there".

### `vt.color` does nothing

§7 puts `vt.color=0x4f` on the Install entry so that the screen is blue before
Setup paints. The parameter is accepted and reads back correctly from
`/sys/module/vt/parameters/color`, and it has **no observable effect**. Erasing
with the default attribute — `ESC[0m ESC[2J`, after a terminal reset so the
value is re-applied — produced palette index 1 for every value tried:

```
vt.color=0x4f  →  index 1        vt.color=0x07  →  index 1
vt.color=0x27  →  index 1        vt.color=0x60  →  index 1
```

Not root-caused; four values with the same answer is enough to stop relying on
it. The consequence is small because the renderer sets an explicit foreground
and background on every cell it writes — a screen painted by Setup is unaffected.
What is affected is the *pre-Setup* frame: "blue from the first kernel frame"
needs something else, and the cheapest something else is Setup painting
immediately (§2.6's "Setup is inspecting your computer's hardware
configuration…" unit is already the right shape for it).

### The bar fill came out the wrong colour, and only one check could see it

Every screen looked right. One was not: the progress bar's fill measured
`#55ffff` — palette entry 14, bright cyan — where it had asked for `#1289ff`,
entry 6.

`ESC[90m`–`ESC[97m` on the Linux console are not "colour 8–15". They are
*"colour n−90 **and bold**"*, and the bold half is sticky. The renderer emitted
`ESC[97m` for white body text, which is correct, and then `ESC[36m` for the fill
— colour 6, inheriting the bold, rendered as entry 6+8. Fixed by emitting the
intensity explicitly on every colour change (`ESC[22;3xm` or `ESC[1;3xm`),
never inheriting it. BUILD-NOTES #30.

**The interesting part is why nothing caught it.** Three checks were already
running over that frame and all three passed:

* "is `#1289ff` present?" — yes, in the title stripe, on every screen.
* the glyph comparison — passed, because it compares *shapes* and the shape was
  a correct full block.
* "is the title stripe band `#1289ff`?" — yes, unaffected.

The progress bar is the **only** place in §3.1 where the brand blue is a
foreground rather than a background, so it was the only element that could go
wrong and the only one no check was looking at. What catches it now asks about
the bar's own rectangle and requires every pixel in it to be field or brand.
Colour assertions have to be **regional**; "the right colour is somewhere in the
frame" is not a statement about anything.

### A palette change does not retint what is already drawn

The framebuffer is truecolor, so each cell was resolved to RGB when it was
written. Switching palettes changes what *later* writes resolve to and leaves
the screen exactly as it is:

```
fill index 4, default palette         →  #0057ad
setvtrgb high-contrast, no repaint    →  #0057ad     (unchanged)
repaint                               →  #003366
```

**Consequence for `F5`:** the high-contrast toggle is a palette change *and* a
full redraw. On a palettised framebuffer it would have been free, which is
exactly why this is worth writing down rather than discovering as "F5 does
nothing on this machine".

---

## Q2 — the glyphs

### How they were checked

Not by looking. Each cell of the test card is cut out of the screendump,
thresholded to a bitmap, and compared with the glyph the console font holds for
the character the program was asked to draw. The expected bitmap comes from the
PSF on disk, so the check is independent of the renderer.

```
ok    box drawing: all 48 cells match the font pixel for pixel
ok    block elements: all 25 cells match the font pixel for pixel
ok    German and UI marks: all 53 cells match the font pixel for pixel
```

A missing glyph, a font that never loaded, or a wrong glyph at the right
position all fail this; none of them fails a coverage count.

### Coverage held exactly where §2.3 said it would

| Block | Result |
|---|---|
| ASCII printable | 95 / 95 |
| Latin-1 Supplement (the German umlauts and ß) | 96 / 96 |
| Box Drawing `U+2500–257F` | **128 / 128** |
| Block Elements `U+2580–259F` | **32 / 32** |
| `U+2022` BULLET | 1 / 1 |

409 codepoints requested, 434 mapped into 512 positions, so **L19's cap was
never close to binding**. Nine of the decorative extras are absent — `U+2030 ‰`,
`U+2194 ↔`, `U+25A0 ■`, `U+25AC ▬`, `U+25BA ►`, `U+25C4 ◄`, `U+25D9 ◙`,
`U+263C ☼`, `U+266B ♫` — which refines §2.3's "Arrows and Geometric Shapes:
partial" into a list. Six of them are absent for a reason worth knowing: they
are **16 pixels wide** in Fixedsys and a PSF cell is 8, so they are unavailable
by construction rather than merely unmapped.

### Two defects the pipeline had to fix, neither visible in a count

**1. The stock equivalences destroyed the double-line box.**

`bdf2psf` takes an equivalents file declaring codepoints that may share one PSF
position; its own header states the rule — *when the source font supports several
symbols from a class, the last supported symbol is used*. Line 217 of
`standard.equivalents` ends its class with `U+2500`, so `U+2550 ═` was handed the
**single** horizontal rule. Verified by rendering the built font:
`╔═╦═╗╠╬╣╚╩╝║` came out byte-identical to `┌─┬─┐├┼┤└┴┘│`.

Coverage checks pass through this untouched: the codepoint *is* mapped — to the
wrong picture. Fixedsys carries the real glyphs (`U+2550` is `FF 00 FF`, two
rules), so the equivalence was pure loss. The pipeline now drops any equivalence
class touching a codepoint OS/7 requires, and `psf.py verify` asserts nine
shape distinctions that must not collapse.

**2. The font is 15 pixels of ink in a 16-pixel cell.**

Read out of `FSEX302.ttf` in font units (`unitsPerEm` 160, so 10 units = 1 px):

```
hhea      ascender 130, descender -30       ->  a 16 px line
U+2588 █  y -30 .. 120                      ->  15 px of ink
U+2580 ▀  y  40 .. 120     U+2584 ▄  y -30 .. 50
```

The em is 16 and the ink is 15, so **the top row of every cell is empty**. The
font is right about itself — Windows' Fixedsys is an 8×15 face — and wrong for a
console, where the cell *is* the character. Left alone it puts a one-pixel gap at
every cell boundary: the vertical borders of every box in Setup come out dashed
and a progress bar never touches the top of its row.

Closed mechanically, only inside Box Drawing and Block Elements: `row0 := row1`
where row 1 equals row 2 (a stroke continuing upward), `row0 := row2` where row 1
equals row 3 (a two-row shading pattern), otherwise nothing. Everything that must
not grow falls into the third case or is a no-op — `┌` and `▄` have an empty row
1, so the rule copies empty onto empty, and letters are out of range entirely
(`Ä` has its diaeresis in row 1 and would otherwise have gained a third row of
dots). `psf.py verify` asserts twelve joins that must reach the top row and seven
non-joins that must not.

### The pipeline itself

```
FSEX302.ttf --otf2bdf--> BDF --psf.py fixedwidth--> BDF --bdf2psf--> 8x16 PSF
                                     --psf.py fillcell--> --psf.py double--> 16x32 PSF
```

Two steps in that chain are not in §2.5 and both are load-bearing:

* **`fixedwidth`.** Fixedsys is not monospaced across its cmap — 4 230 glyphs
  advance 8 px, 1 575 advance more, 346 advance 0 — so `otf2bdf` reports
  `SPACING "P"` with `AVERAGE_WIDTH 77` and `bdf2psf` refuses the file outright
  with *"the width is not integer number"*. Narrowing to the cell is not a
  workaround for that message: a 16-pixel glyph has nowhere to go in an 8-pixel
  cell, and keeping it hands `bdf2psf` something to truncate. All 352 REQUIRED
  codepoints advance exactly 8, so nothing the UI draws is lost.
* **`fillcell`**, above.

`otf2bdf` **exits 8 on this font at every point size tried** (8, 12, 15, 16, 17,
24, 32) while writing a complete and correct BDF; Liberation fonts through the
same command return 0. The pipeline therefore asserts the artefact — declared
`CHARS` matches the blocks written, the file ends with `ENDFONT`, and the
required glyphs are present and non-blank — rather than the exit status.
BUILD-NOTES #24.

---

## Q3 — the keys

Sixteen keys, injected as QMP qcodes into a USB keyboard so they travel the
whole real path: HID → the kernel keymap → the VT's XLATE translation → a
raw-mode `read(2)` in the program. A test that wrote escape sequences into a pipe
would have proved nothing about the two layers that differ between a VT and a
serial line.

```
S1-KEY  0: raw=[ESC[A]    -> Up          S1-KEY  8: raw=[ESC[19~] -> F8
S1-KEY  1: raw=[ESC[B]    -> Down        S1-KEY  9: raw=[ESC[21~] -> F10
S1-KEY  2: raw=[ESC[D]    -> Left        S1-KEY 10: raw=[ESC[5~]  -> PageUp
S1-KEY  3: raw=[ESC[C]    -> Right       S1-KEY 11: raw=[ESC[6~]  -> PageDown
S1-KEY  4: raw=[ESC[[A]   -> F1          S1-KEY 12: raw=[ESC[1~]  -> Home
S1-KEY  5: raw=[ESC[[B]   -> F2          S1-KEY 13: raw=[ESC[4~]  -> End
S1-KEY  6: raw=[ESC[[C]   -> F3          S1-KEY 14: raw=[CR]      -> Enter
S1-KEY  7: raw=[ESC[[E]   -> F5          S1-KEY 15: raw=[TAB]     -> Tab
```

**§6.4's premise is confirmed exactly.** The Linux console splits its function
keys across two encodings — `ESC[[A`…`ESC[[E` for F1–F5, a form no other
terminal emits, and the DEC `ESC[<n>~` form from F6 up. `F3=Quit` and
`F5=Advanced` are on the Linux-only side, so they are precisely the keys a
terminfo layer with "known gaps around F-keys under `TERM=linux`" would get
wrong. The hand-written table is ~40 entries and it is checked at start-up for
the one property the reader depends on: no sequence is a proper prefix of
another.

Enter arrives as **CR**, not LF — the same fact BUILD-NOTES #16 records from the
other direction.

Two things the input path needed, both of which Phase 1 inherits:

* **`read(2)` directly, not `Console.OpenStandardInput()`.** .NET's console
  stream carries its own terminal handling and applies termios settings of its
  own; with it in the path the reader returned exactly one byte and then reported
  end of input on a tty that was perfectly open. §6.2 already puts key decoding
  on `DllImport("libc")`; this is why.
* **Drain the queue before the first read.** Whatever was typed before the screen
  appeared was not aimed at what is on it. A stray LF was sitting in the queue at
  start-up and was spent on the first entry of the key plan.

**Not tested: the bare Escape key.** A lone ESC is the prefix of every sequence
in the table, so the reader blocks on it until the next key arrives. Every
terminal program solves this with a timer — after ESC, switch to `VMIN=0`/
`VTIME=1` and treat "nothing followed within ~100 ms" as Escape. §3.1 screen 2
offers `ESC`, so **Phase 1 owes this**. Recorded as an omission, not an oversight.

---

## Q4 — geometry

```
Console: switching to colour frame buffer device 80x25
S1-PROBE-GEOMETRY=80x25   S1-PROBE-BODY=80 left=0
```

`virtio-gpu-pci` defaults to 1280×800, which with the 16×32 font is exactly the
80×25 §2.4 names as the reference. The mockups were therefore measured at the
size they were drawn for. `ioctl(TIOCGWINSZ)` on the framebuffer tty agrees with
the kernel, so the layout rule (full-bleed chrome, body capped at 80 and centred)
has a number to work from at run time.

This is one geometry, not a survey. §2.4's warning stands: UEFI hands out
whatever GOP mode the firmware likes, and 80×25 is not obtainable everywhere
(L7).

---

## What this does to the plan

| Where | Change |
|---|---|
| §2.1 | The kernel command line is **not** the mechanism on Ubuntu. Ship `/etc/vtrgb`; `setvtrgb.service` is already enabled. |
| §2.2 / D5 | Confirmed exactly, on a framebuffer. |
| §2.5 | The pipeline needs `fixedwidth` and `fillcell`, and a filtered equivalents file. Now in [`build/lib/`](../build/lib/) and wired into `build.sh`. |
| §2.4 / L20 | 80×25 at 1280×800 confirmed. `fbcon=font:TER16x32` is still the pre-userspace font. |
| §6.4 | Confirmed with the raw bytes. The table beats terminfo for the reason given. The renderer must set SGR intensity explicitly on every colour change — bright foregrounds leave bold set and the next colour inherits it (BUILD-NOTES #30). |
| §7 | Drop `vt.color=0x4f` from the Install entry — it does nothing. |
| D6 | Has a mechanism and costs nothing: the palettes ship at `/usr/share/os7/`, and pointing `/etc/vtrgb` at one of them is the whole decision. |
| L19 | Not binding: 434 codepoints in 512 positions, all REQUIRED blocks complete. |
| Phase 1 | Owes the ESC timer, and gets the renderer, the key table and the font for free. |

## Added 2026-08-24: S1's harness had a race, and it had it all along

Phase 1 ([SESSION-PHASE1-SETUP.md](SESSION-PHASE1-SETUP.md)) found that **fbcon
defers taking the console over and completes it only when something writes to
it**. Until then tty1 is the kernel's dummy device, on which `KDFONTOP` returns
`ENOSYS`: no font loads and no palette applies.

Everything measured above is unaffected — the numbers were read off a real
framebuffer console — but the harness reached that console **by luck**. It logs
in over the serial line and drives tty1; the getty's login prompt on tty1 had
already completed the takeover, so the console was always ready by the time the
harness looked. Nothing in the harness required that, and the moment the getty
stopped appearing (a systemd-unit bug in Phase 1, BUILD-NOTES #33) every S1 phase
failed at once with "the console never accepted a font".

Two changes, and both are in the committed harness:

* `fbcon=nodefer` on S1's kernel command line, so the framebuffer console exists
  from the first frame and the race does not.
* A `waitfb` step that waits for the console to accept a font — and waits by
  **loading one and asking the console what it holds**, not by watching for a
  dmesg line. The first version watched dmesg and deadlocked for two minutes:
  probing with ioctls is not writing, so the takeover it was waiting for could
  never happen. That is this repo's own rule, in a new place — a diagnostic must
  not depend on the subsystem it is diagnosing, and must be checked against the
  thing it claims to check.

## What S1 does not show

* **arm64 only**, like S3, S4 and S6 — there is still no amd64 ISO.
* **One geometry.** 1280×800 was chosen because it is the reference; the
  letterboxing path (`os7.setup.geometry=`) and the 120×33 case are untested.
* **Nothing over serial.** §2.7 says the palette cannot be set there and Setup
  must emit 24-bit SGR instead, picking per surface. That code does not exist and
  was not exercised. `os7-setup --serial` is Phase 5.
* **No GRUB.** The kernel and initrd are booted directly so each phase can set
  its own command line. The boot-menu theme (§2.6) is untouched.
* **The screens are static.** S1 asks whether the look works, not whether the
  flow does. No screen here reacts to a key.
