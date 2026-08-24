# Phase 1 — the `os7-setup` skeleton

[../installer/SETUP-PLAN.md](../installer/SETUP-PLAN.md) §10 Phase 1:

> TUI layer (buffer, renderer, input, theme, both palettes), screens 1–3 and 12,
> error screen, logging. Boots from the ISO via the systemd unit and the GRUB
> entry. **Strictly non-destructive** — nothing touches a disk yet.
> *Deliverable:* you can walk the whole flow in a VM and it looks right.

**Date:** 2026-08-24 · **Done, and "looks right" is measured rather than looked
at.** The whole flow — Welcome → Licence → Regional → Complete — runs from the
ISO's *Install OS/7* entry on tty1, and every screen is verified by reading it
back through the console font the image ships.

```bash
./installer/testing/run-phase1.py all      # ~10 minutes, two boots
```

```
### Phase 1 result
    live      PASS      the live entry still boots to a login prompt
    boot      PASS      the Install entry starts Setup on tty1, in OS/7's colours
    walk      PASS      Welcome -> Licence -> Regional -> Complete
    contrast  PASS      F5 switches the field to #003366 and back
```

- The installer: [`installer/src/OS7.Setup/`](../installer/src/OS7.Setup/)
- The unit: [`installer/assets/os7-setup.service`](../installer/assets/os7-setup.service)
- The harness: [`installer/testing/run-phase1.py`](../installer/testing/run-phase1.py)

## What exists

| | |
|---|---|
| `Tui/` | `Frame` (cell buffer, row-level damage tracking, one `write(2)` per frame), `Terminal` (raw mode, palette, font, guaranteed restore), `Input` (the measured key table plus the ESC timer), `Geometry` (`TIOCGWINSZ`, `os7.setup.geometry=`), `Theme` (the palette slots and the font rule) |
| `Screens/` | 1 Welcome, 2 Licence, 3 Regional, 12 Complete, E Error, and the flow that drives them |
| `Model/` | `InstallPlan` with source-generated JSON, and the language/keyboard/timezone lists read from the system's own data |
| `Diagnostics/` | the log, as a file and as a ring in memory, and `F2` to export it |
| `Native/` | `Termios`, `Ioctl`, `Poll`, `Tty` — all `LibraryImport` into libc |

3.6 MB NativeAOT, no .NET runtime at run time, zero warnings with
`TreatWarningsAsErrors`.

**Nothing opens a block device.** Screen 12 says so on the screen, in the brand
colour, in those words: `NOTHING HAS BEEN WRITTEN TO ANY DISK.` A skeleton that
could be mistaken for a finished installer would be worse than no skeleton.

### The lists are read, not written

L10's mitigation for dropping Calamares was to read the system's own data rather
than hand-maintain lists that go stale silently. Measured in the image:

```
154 languages from /usr/share/i18n/SUPPORTED
99 keyboard layouts from /usr/share/X11/xkb/rules/base.lst
313 timezones from /usr/share/zoneinfo
```

Each reader falls back to a short built-in list and **says so in the log** — a
Setup showing five languages is recoverable, a Setup showing none is not.

### `--self-test`, and where it runs

`os7-setup --self-test` checks the things that have no visible symptom until a
screen is already on a console: the key table has no ambiguous prefix, both
palettes and both fonts exist, the font rule picks 16×32 at 1280×800, the
licence text is present, the plan round-trips through source-generated JSON, the
lists are non-empty, and every screen renders into an off-screen frame.

It runs **at build time**, inside the chroot, from hook 0080 — so a missing PSF
or an unstaged palette fails the ISO build rather than a boot:

```
SELFTEST ok   console font for 1280x800 is 16x32 -> 80x25
SELFTEST ok   install plan round-trips through JSON
SELFTEST-DONE failures=0
```

## What Phase 1 measured that the plan did not know

Five things, and every one of them was invisible from reading code.

### 1. fbcon defers taking the console over, and completes it only when something writes

This is the big one, and it took several boots because the symptom points
somewhere else entirely.

```
[    0.000431] Console: colour dummy device 80x25
[    0.569495] fbcon: Deferring console take-over
[    0.570004] virtio-pci ... [drm] fb0: virtio_gpudrmfb frame buffer device
```

— and then nothing. `fb0` exists, the DRM driver is loaded, and tty1 is still
the kernel's **dummy** device, on which `KDFONTOP` returns `ENOSYS`: no font can
be loaded and no palette applies.

**What completes the takeover is output arriving, not time passing.** Normally
the getty's login prompt does it. The first version of the S1 harness's wait step
polled for two minutes with ioctls and the console never moved — because polling
is not writing.

Two fixes, and OS/7 uses both. `fbcon=nodefer` on the Install entry removes the
race at its source; and Setup **re-takes the console** anyway — the font and the
palette go back on whenever the grid is not what the chosen font should have
produced, at most once a second, up to eight times. Recovering from a race is
worse than not having one, but the same mechanism covers a mode change and a
serial client resizing.

Two follow-on findings came out of the same place:

* **`setfont` returning 0 does not mean the font loaded.** While fbcon was
  settling, `setfont -C /dev/tty1` exited 0 and the console stayed in its own
  8×16 font; the identical command from a shell a minute later worked. So the
  console is asked afterwards — Setup knows what grid its font should give and
  insists on it — rather than the exit code being believed.
* **A retake always means redraw.** `setfont` clears the console, so a retake
  that loads the same font again wipes the screen *without changing its size*.
  A `Refresh()` that answered "nothing changed" left the screen wiped, because
  damage tracking compares against the frame Setup still believes is on screen.
  It looked like a Welcome screen with a status bar and nothing above it.

### 2. Reading input needs a deadline, for two unrelated reasons

`read(2)` blocks, and .NET installs its signal handlers with `SA_RESTART`, so a
`SIGWINCH` does not break it. A reader blocked in `read` would have left the
screen blank from fbcon's takeover until somebody pressed a key.

The same deadline pays spike S1's outstanding debt: a lone `ESC` is the prefix
of every sequence in the key table, so a blocking reader waits on it forever.
`poll(2)` with a 200 ms idle tick and a 100 ms deadline once a sequence has
started handles both — and `poll` separates "nothing arrived" from "the terminal
went away", which `VMIN`/`VTIME` cannot: with a timer both are `read` returning
0, and an installer that cannot tell an idle user from a hangup will either spin
or quit on somebody thinking.

### 3. The font rule was arithmetic, and it was written as a guess

The first version used "16×32 above 900 pixels of height". A 1280×800 console
therefore picked 8×16 and Setup drew a **perfectly correct 80×25 screen into the
top-left quarter of the framebuffer**. The rule is not a threshold, it is the
reference grid: 16×32 needs 80·16 = 1280 across and 25·32 = 800 down, which is
exactly the geometry §2.4 names and spike S1 measured.

### 4. `Conflicts=` is transaction-time; `Condition…=` is run-time

The unit was written the way it reads:

```ini
ConditionKernelCommandLine=os7.setup=1
Conflicts=getty@tty1.service
[Install]
WantedBy=multi-user.target
```

"On a live boot the condition fails, so nothing happens" — and that is not what
happens. **systemd resolves `Conflicts=` while building the transaction and
evaluates `Condition…=` when the job runs.** An enabled unit whose condition
later fails has already had `getty@tty1` stopped.

So the *live* entry booted to a tty1 with no login prompt. And because nothing
then wrote to that console, fbcon's deferred takeover never completed either —
which is how a missing `WantedBy` presented as "the console does not support
fonts". L14 is what makes it more than tidiness: keeping the live entry is the
mitigation for "booting straight into Setup loses try-before-you-install", and
an entry that boots to a dead console is not the live session it promises.

The fix is not to drop `Conflicts=`. It is to drop `[Install]` and start the
unit from the boot entry with `systemd.wants=os7-setup.service`, so it is not in
the live boot's transaction at all.

**And not `ExecStartPre=systemctl stop getty@tty1.service` either.** That was
tried and is worse: `getty@tty1` has `TTYReset=yes`, so stopping it resets the
VT — and **a VT reset restores the palette from the kernel's module defaults**,
i.e. whatever `setvtrgb.service` put there, i.e. Ubuntu's. The screen went back
to Ubuntu's colours a moment after Setup painted it in OS/7's.

`run-phase1.py live` is the regression test, and it boots the live entry to ask.

### 5. `▲`/`▼` are not in the font, and looked as though they were

The scroll hints on the list widget were drawn with `U+25B2`/`U+25BC`. Fixedsys
has no glyph for either; `bdf2psf` had been mapping them onto something else
through an equivalence class, exactly as it did to the double-line box
(BUILD-NOTES #26). They are now `U+2191`/`U+2193`, which are real glyphs — and
those four codepoints moved into `psf.py`'s **REQUIRED** set, because *the
installer draws them*. Promoting them dropped the equivalence class that had
been covering for the triangles, and the coverage report started reporting them
absent, which is the honest answer.

The rule this makes explicit, now written into `psf.py`: **a codepoint the
installer draws belongs in REQUIRED.** WANTED means "included if the font has
it", and the font not having it is not the visible failure.

### The shape all five share

Four of the five are the same mistake in different clothes: **a program said it
succeeded and the thing it was supposed to change did not change.** `setfont`
exited 0. The unit's condition was correct. The exit code, the config file and
the log all agreed with each other and disagreed with the console. The only
diagnostic that ever caught any of them was asking the console itself — which is
the rule already written in [BUILD-NOTES.md](BUILD-NOTES.md), one layer up from
where it was first learned.

## What the harness checks, and how

Not by looking at the PNGs. Each cell is cut out of the screendump, thresholded
to a bitmap, and matched against every glyph in the PSF **taken out of the ISO's
own squashfs** — so a font that failed to load, a screen painted in the wrong
place, or a frame that never arrived all fail, and none of them can be mistaken
for "the text is wrong".

Keys go in as QMP qcodes to a USB keyboard, so they travel HID → the kernel
keymap → the VT's XLATE translation and arrive as the bytes a person's keypress
would produce.

Two rules the harness follows, both learned here:

* **Chrome is asserted by position, body content is not.** §2.4 pins the title
  row, the stripe and the status bar to the screen edges, so for those the row
  *is* the claim. Everything else moves when a box grows, and a harness that
  hard-codes those rows tests the harness.
* **Read a line in the colour it was drawn in.** A selected row is black on
  grey and the brand-coloured lines are `#1289ff`; reading them as white finds
  nothing and reports missing text that is plainly on the screen.

The Setup log is read back over the serial line at the end as independent
evidence — what Setup *thought* happened, beside a screendump of what it drew.

## What Phase 1 does not do

* **arm64 only.** There is still no amd64 ISO.
* **No disk, no accounts, no bootloader.** Screens 4–11 do not exist. Phase 2
  is storage; Phase 3 is system configuration.
* **`--unattend` is not implemented.** `--print-plan` writes the plan a fresh
  run starts from, which is as much as §6.6 can mean before screens 4–11 exist.
* **Nothing over serial.** `Terminal` detects the surface and skips the font and
  the palette when the output is not a virtual console, which is the seam §2.7
  describes — but the 24-bit SGR fallback behind it is Phase 5.
* **No `F1` help and no `F3` confirmation.** Both are Phase 4. `F3` quits
  immediately today.
* **One geometry.** 1280×800 is the reference; `os7.setup.geometry=` exists and
  is untested, and the 120×33 case at 1920×1080 has not been looked at.
