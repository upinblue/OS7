# Session: the manual learns the two applications, and its pictures get a road back to a machine

**2026-09-22, on the x64 Windows host.** Two tasks from
[SESSION-PREVIEW-245.md](SESSION-PREVIEW-245.md) §10: the administrator manual
describes neither GUI application, and 25 of its pictures are older than the
build they claim to describe. Everything below was measured on this machine;
where something was not measured, it says so in place.

The second task turned out to be the interesting one. It was posed as "no tool
puts these 25 pictures there", and that is true of this repository — but a tool
did exist, outside it, and reading the pictures back said something worse than
"stale".

---

## 1. What the old pictures actually were

`installer/testing/vmscreen.py` has `read_text()`: it compares each cell of a
screen against the glyphs of the PSF the screen was drawn with, exactly, lowest
codepoint winning on a shared bitmap (BUILD-NOTES #46). It is written for a live
screendump with one known foreground colour. A saved PNG carries several colour
pairs at once — title row, field, grey status bar, a black-on-grey selected row
— so the ink was derived per ROW instead: the commonest colour across a row's
band is the background and everything else is ink.

With that, the manual's 18 `setup-*.png` read back as text. The first line of
the first one:

```
     OS/7 1.0.0.116 (development)
     Ubuntu 26.04 base, archive 20260824T000000Z
```

**1.0.0.116**, printed on the picture itself. `make-release-dir.py` had refused
them for being older than the 1.0.0.245 medium; the version on the glass says by
how much.

`out/screenshots/README.md` — gitignored, and therefore invisible to anything in
this repository — records honestly how they were made, and it is worth quoting
because it changes what "refresh these" means:

* the Setup screens came from `os7-setup` **run in a chroot on a pseudo-terminal
  under `--dry-run`**, with `lsblk` **shadowed** and `/sys/class/net` laid out by
  hand. So `nvme0n1 SAMSUNG MZVL2512HCJQ-00B 512.11 GB` and the `wlp3s0` Wi-Fi
  adapter on screens 4, 5, 6 and 9 were a fixture, not a machine.
* the desktop screens came from **GNOME Shell on mutter's headless backend in a
  container**, screenshotting itself.

Neither is a criticism of that session — its README says all of this in a table
headed "what is not the machine's own", which is the repository's discipline
working. It is the reason a refresh is a different job from a copy: the
replacements come from a booted VM, so they show `vda`, `vdb` and `virtio_net`
instead of a plausible laptop. Less like a laptop, and true.

### 1.1 Two of them were the same file

```
a81e9c576c6ccefa521e892de2a3f9cb  setup-08-mode-desktop.png
a81e9c576c6ccefa521e892de2a3f9cb  setup-08-mode-headless.png
```

Byte-identical, both with **Headless** selected, captioned in both languages as
two different states — *"The choice between desktop and headless"* and *"The
same choice with the headless entry selected"*. Reading the pictures found it;
reading the filenames never would have.

### 1.2 And four were referenced by nothing

`setup-02-licence-end.png`, `setup-03-regional-language.png` and
`console-version.png` are named by no chapter in either language.
`console-version.png` is **3 distinct colours and 95.8% black**. All three are
removed.

---

## 2. The Setup pictures now come from `run-phase3.py walk`

The walk boots the medium in a VM and drives the whole flow by keypress. It
already produced 17 screens; the manual references 14, of which 12 had a direct
equivalent. The two it did not photograph were added to the walk, each with an
assertion, because a picture nothing checks is the thing this repository keeps
paying for:

* **`40b-welcome-high-contrast`** — F5, the high-contrast field (D5). Asserted
  by counting pixels of `palette.FIELD` and `palette.CONTRAST`: F5 must turn the
  first into the second and F5 again must turn it back. Measured on the run:
  `#0057ad × 911932` before, `#003366 × 911932` after, and back. The two PNGs
  are the same size to the byte, which is why a size comparison would have
  reported the toggle working when it was not.
* **`40c-regional`** — screen 3. The walk pressed ENTER here with **nothing
  checking that screen 3 was on the glass**; a screen that stopped appearing
  would have been walked past and the ENTER would have landed on whatever came
  next. That is BUILD-NOTES #45's shape in the third place inside one function.

`./installer/testing/run-phase3.py walk` → **PASS**, 27 `ok` lines, two of
them the new ones. (Counted from the run's output rather than written from
memory — the first draft of this line said 30.)

### 2.1 The mapping, and how each row was established

`installer/testing/place-manual-shots.py` owns it. Every row was read off the
screen with the reader from §1 — never inferred from a filename — and the tool
re-reads every picture at placement time and requires a phrase from that screen,
plus the version in the title row against the medium's own `release.json`.

| the manual's name | from the walk | what separates it |
|---|---|---|
| `setup-01-welcome` | `40-welcome` | "Welcome to Setup" |
| `setup-01-welcome-high-contrast` | `40b-welcome-high-contrast` | identical TEXT; the field colour |
| `setup-02-licence` | `41-licence` | "PGDN=Next page" |
| `setup-03-regional` | `40c-regional` | "regional settings" |
| `setup-04-disk` | `42-disk` | "install OS/7 on the disk" |
| `setup-05-layout` | `43-layout` | "storage settings" |
| `setup-05-layout-passphrase` | `44-passphrase` | "passphrase for the encrypted disk" |
| `setup-05-layout-ready` | `44b-passphrase-set` | same text as `layout`; the walk's order |
| `setup-06-confirm` | `45-confirm` | "F=Format" |
| `setup-07-account` | `46-account` | the empty form |
| `setup-07-account-filled` | `47-account-filled` | the typed computer name |
| `setup-08-mode-headless` | `47b-after-account` | which row is black-on-grey |
| `setup-08-mode-desktop` | `47c-mode-desktop` | which row is black-on-grey |
| `setup-09-network` | `48-network-tested` | "The settings work." |
| `setup-10-execute-1` | `49-copying` | the bar in mid-flight |
| `setup-12-complete` | `49-complete` | "Setup has prepared this computer" |

Two of these are better pictures than the ones they replace, and both were
predicted by the old README:

* `setup-09-network` used to say **"Not yet tested."** under two invented
  adapters. It now carries a real DHCP lease taken on the live medium:
  *"enp0s6 was given 10.0.2.15/24. The settings work."*
* `setup-10-execute-1` used to be **0% / "Starting…"** with an empty bar,
  because under `--dry-run` every step finished in about no time. The old README
  says in as many words that a bar in mid-flight "needs a real install, which
  needs a VM". It is now **70% / "Creating the administrator account…"**.

### 2.2 The checks are proven to fire

Three defects planted on a copy of the walk's output, each required to go red:

| planted | what the tool said |
|---|---|
| the two mode screens swapped | `the selected row is 'Desktop …', not Headless` (and the converse) |
| the high-contrast shot replaced by the plain one | `the field is not the high-contrast colour` / `the default field colour is still on it` |
| the confirm screen replaced by the account screen | `'F=Format' is not on that screen` |

The first of those is the defect the manual actually shipped (§1.1).

Each placed picture also gets `docs/manual/transcripts/setup-*.txt` — the screen
as text, from the same pixels — which is what the console half has had since the
manual was written.

---

## 3. The desktop pictures, and the one that was a void

`installer/testing/shoot-desktop.py` signs in at the greeter, drives the session
through QMP and takes the set; `place-manual-shots.py desktop` files it. The
bench is `os7lab.py install gui --mode Gui` from
`OS7-1.0.0.245-amd64.iso`, and the machine says so itself — the terminal picture
is `Get-OS7Version | Format-List` showing `FullVersion : 1.0.0.245`.

Measured on the set being replaced:

| picture | size | colours | one colour |
|---|---|---|---|
| `desktop-01b-desktop-no-overview.png` | 1920x1080 | 84 | **94.7% black** |
| `desktop-01-desktop.png` | 1920x1080 | 2466 | **94.6% black** |
| `console-version.png` | 1280x800 | 3 | **95.8% black** |

The first is the picture chapter 13 captioned *"The OS/7 desktop in its classic
appearance"*. It is a panel and a status bar on a void, and it had been in the
manual since 2026-08-29.

So the desktop half of `place-manual-shots.py` rejects a picture in which one
colour covers more than 80% of the frame — a rule tuned to what was actually
wrong rather than to what sounded like it would be. A count of distinct colours
would **not** have caught it: 84 colours sounds like a picture.

**The replacement is the start menu open**, not a bare desktop, because the bare
desktop is black ON PURPOSE: `00-os7-classic` sets
`org.gnome.desktop.background primary-color='#000000'` and empties
`picture-uri`, with the comment "The black desktop. picture-uri must be emptied
or it wins over the colour." A picture of that is a true picture of nothing. The
menu open shows the theme, the categories and what is installed, in one frame.

### 3.1 What the applications' pictures show

Both applications were photographed doing the thing the new chapters describe,
and both windows draw in the Windows 2000 palette with a Mutter-drawn title bar.

**Software Update**, pointed at a signed repository served to the bench
(`os7lab.py release gui` → 1.0.0.246, `up --serve`), shows the third of its four
header states:

> New software exists, but none of it can be installed on this computer.
> Each release below says why. Nothing here changes this machine.

with the row's checkbox disabled and the reason underneath —
*"Not signed for production (17C460671FF8A8DC2FD8AFA64A0EDD17EF8591AC). To
install it anyway, run sudo pwsh -c 'Update-OS7 -Version 1.0.0.246
-AllowDevelopment'."* `Get-OS7Release` on the machine returns
`Applicable = True` and `Development = True`, and `ReleaseRow.Decide` turns the
pair into that sentence. So the window and the cmdlet agree, which is G3.

**Versions** was reached the documented way — right click in Files, *Versions* —
and that entry appearing at all is the first proof on a machine that the
`nautilus-python` extension loads. Its own file says the failure is silent:
Nautilus logs a traceback to the session journal and carries on with no menu
entry, which looks exactly like a machine where the package was never installed.

### 3.2 And the restore was answered, not just photographed

The window's *Restore…* was clicked through on a file with four snapshots:

```
quote.txt                                       624
quote.txt.os7-before-restore-20260922-095613    357
```

The live file came back as the selected version, and what was there was
**renamed** beside it. That is V19's unprivileged branch — the window runs as
the person using it, `zfs snapshot` is root's (M-V22), so the strongest thing
available where the file stands is a rename. First time that path has run from
the window on a machine.

`shoot-desktop.py` asserts it rather than trusting the picture: no
`.os7-before-restore-` file beside the restored one is a failure, because
"the question was asked" and "the bytes were kept" are different claims. It has
been through that path twice, and the second time sanoid's own timer fired at
10:00 in the middle of the run and took a real hourly snapshot — which is why
the window in `app-versions.png` says **six** versions where the fixture made
four and a live file. A machine doing its own work during a photograph is the
kind of thing a fixture cannot produce.

The final set: **25 pictures placed, 80 references resolving, 0 older than the
medium**, against the 26 that `make-release-dir.py` refused.

---

## 4. Three defects found on the machine, none of them in scope

Written down rather than fixed, because each needs an owner's decision and none
of them is "describe the two applications".

### 4.1 Ubuntu's Software Updater is in the same menu, with the same icon

Under **Apps → System Tools**, adjacent, indistinguishable:

```
os7-software-update.desktop   Name=Software Update    Exec=/usr/lib/os7/apps/software-update/os7-software-update
update-manager.desktop        Name=Software Updater   Exec=/usr/bin/update-manager
```

Both draw the `system-software-update` icon. The second is Ubuntu's
update-manager, which apt-upgrades **the running system** — precisely what the
update train exists not to do: §4.2 fills a NEW boot environment and switches to
it. An operator who clicks the wrong one of two identically-iconed neighbours
gets the one that cannot be rolled back.

The image already suppresses `update-notifier`'s autostart
(`includes.chroot-amd64/etc/xdg/autostart/update-notifier.desktop`), so the
question was considered for the notification and not for the menu entry.

### 4.2 `Get-OS7RestoreAside` promises unprivileged and throws

Its own docstring: *"Read-only, and unprivileged: these live in the operator's
own directories and asking about them needs nothing."* As the file's owner:

```
Get-Content: /usr/local/share/powershell/Modules/OS7/OS7.Backup.ps1:347
  | Access to the path '/etc/os7/backup.json' is denied.
```

`/etc/os7/backup.json` is `600 root:root`, and it is where the DEFAULT dataset
list comes from. With `-Dataset rpool/USERDATA/os7admin_…` named explicitly the
cmdlet works as the user and finds the file. So the defect is precise: the
default path needs root, and the refusal arrives as a raw .NET exception rather
than as a sentence — #148 and #149's shape in a cmdlet neither of them reached.

The manual now gives the elevated form and the `-Dataset` form, because that is
what is true.

### 4.3 The shell panel is not the colour the theme declares

`OS7-Classic/gnome-shell/gnome-shell.css` line 32: `#panel { background-color:
#d4d0c8; }`. The session journal at sign-in:

```
gnome-shell[9758]: loading user theme: /usr/share/themes/OS7-Classic/gnome-shell/gnome-shell.css
```

`Get-OS7Theme` reports `Name: Classic`, `GtkTheme: 'OS7-Classic'`, `ShellTheme:
'OS7-Classic'`. And the pixels at the top panel are **`#131313`**.

Everything else the theme owns is right: the Apps menu, the popup, the taskbar
button and both applications' windows are `#d4d0c8` with square bevels. Only the
panel's own background is not. That is BUILD-NOTES #85's shape — every
declaration satisfied and the thing they were about decided elsewhere — and the
1.0.0.116 container pictures had a grey panel, so something between then and
GNOME 50 on a real session changed. The cause is NOT established here.

---

## 5. Four things the tooling learned

### 5.1 `os7lab.py type --layout de` was silently wrong for every AltGr character

`Get-OS7Version | Format-List` arrived at the terminal as
`Get-OS7Version ' Format-List`, and PowerShell sat at a continuation prompt
waiting for a closing quote. The keystrokes were perfect: `|` is not in the `de`
table, so it fell through to US's `shift-backslash`, which on a German board is
`'`.

`<`, `>`, `|`, `@`, `\`, `{`, `[`, `]`, `}` and `~` were all missing — every one
of them a character a PowerShell command line contains. They are now in the
table, with `<` and `>` on the 105-key board's extra key (`less`) and the rest
behind AltGr (`alt_r-…`). `^`, `` ` `` and `´` are entered as `None` and now
REFUSE with a sentence, because they are dead keys: the press produces nothing
until the next one. The backtick is PowerShell's line continuation, so that
refusal is load-bearing.

Verified by asking the machine, not by reading a keymap. Typed at the terminal,
ENTER, then `(Get-PSReadLineOption).HistorySavePath` read back over ssh —
PSReadLine records the line as it ARRIVED:

```
sent:     # <>|@\{[]}~ -_+*#'/()=&%$"!?;: ABZYabzy09
arrived:  # <>|@\{[]}~ -_+*#'/()=&%$"!?;: ABZYabzy09
```

The comment above that table claimed the mapping was verified by
`os7lab.py type <bench> --verify`. **There is no `--verify` option**, in that
file or anywhere. The comment now says how it is actually done.

### 5.2 `locale -a` under-reports, and the control is what said so

`/etc/default/locale` on the bench says `LANG=de_DE.UTF-8`; `locale -a` lists
only `C`, `C.utf8`, `POSIX`; `/usr/lib/locale` holds one directory. That reads
like a machine whose configured locale does not exist — which would be an
installer defect.

It is not:

```
LC_ALL=de_DE.UTF-8 date +%A   ->  Dienstag
LC_ALL=xx_YY.UTF-8 date +%A   ->  Tue
```

The bogus locale falls back and the real one does not, so `de_DE.UTF-8` resolves
and `locale -a` simply does not list it. A diagnostic gave a confident wrong
answer and the control corrected it, which is BUILD-NOTES' oldest rule.

What IS true, and matters for the pictures: **no language pack is installed**
(`language-pack-de` is absent; `/usr/share/locale/de/LC_MESSAGES` holds 26 files
from individual packages and none of GNOME's). So a machine installed with
German runs an **English** desktop. That is consistent with GUI-APPS-PLAN's "the
application family is English in v1", and it is why one shared picture set
serves both language editions without a second bench.

### 5.3 Three guards that said "fine" about a greeter

`shoot-desktop.py` drives a desktop through QMP, so every step is a click at a
pixel and every failure looks like a picture. Getting the sign-in guard right
took four attempts and each wrong one is worth the line:

1. **No guard.** The first run clicked at where the password field *would* be —
   the greeter starts on a user TILE and the field does not exist until an
   account is chosen — typed a password into nothing, and then spent four
   minutes clicking at a desktop that was not there. Eleven pictures of a
   greeter, exit 0.
2. **Compare the frame before and after, byte for byte.** Looks decisive. The
   greeter draws a **clock**, so two pictures of the same greeter a minute apart
   differ, and the guard passed on every one.
3. **Ask logind, and exclude the greeter by user name.** The greeter's session
   is on `seat0` and is `wayland`, exactly like a person's. It runs as
   **gdm-greeter**, so `user != "gdm"` passed.
4. **Exclude it by uid >= 1000.** Ubuntu gives that dynamic account **60578**.
   Passed.

What works is logind's own **`Class`** property — `greeter` against `user` —
which is the distinction logind exists to make. The negative control is what
proved it: asked at the greeter, the probe returns nothing, which none of the
three earlier rules ever did.

And one question genuinely cannot be asked of logind: whether a widget is
drawn. That one is answered on the pixels, in the rectangle the field occupies,
and it immediately earned its place — the next run began with the field already
on screen from an aborted run, so the ENTER meant to choose the account
submitted an EMPTY password instead, and GDM bounced back to the tile. Measured:
100% of that rectangle is not the background colour when the field is there, and
0% when it is not.

### 5.4 A window's close button is not a place

The run after the sign-in was fixed took all fourteen pictures and then failed
on its last assertion: **the restore had not happened** — `quote.txt` was still
357 bytes and nothing lay beside it. The pictures said why. The Software Update
window had never closed, because `CLOSE_CLASSIC` was measured on the *Versions*
window's title bar and used on Software Update's, which sits 100 pixels lower.
It stayed on top for the rest of the run, and every click after it landed on
whatever was underneath.

Underneath was a Files window in a different place from the one the coordinates
came from: `x=193` in one run, `x=0` in the next. **A window's position is not a
fact that survives between runs**, and three of the coordinates in this file
were positions inside windows.

They are gone. What replaced them cannot miss:

| was | is |
|---|---|
| click the window's X, three different ones | **ALT+F4** — closes whatever has focus |
| click the file's row | **type its name** — which starts a SEARCH in GNOME Files and narrows the view to that one file |
| right-click the row | **SHIFT+F10** — the shortcut every GTK widget honours, after DOWN moves the focus out of the search entry |
| click *Versions* | **UP UP** from the opened menu — counting from the bottom, which does not move with the window |

The panel and the start menu keep their coordinates, because they are fixed
furniture at a fixed resolution. The lesson is narrower than "don't drive a GUI
by pixels": aim at the things that do not move, and use the keyboard for the
things that do.

Two of those took a second attempt as well, and both for the same reason —
**the keyboard route has to be verified too**. Typing in Files starts a search
rather than selecting by type-ahead, so the focus stayed in the search entry and
the context-menu key went to a text box. And the search view's context menu has
*Properties* under *Versions*, where the plain view's ends at *Versions* — so
one UP opened the wrong dialog. Each is now followed by a check that the thing
it was for actually appeared: enough of the screen changed for a menu, and much
more of it for a window.

And the assertion that caught it is the one that matters. Fourteen pictures had
been taken, every one of them of something, and the only reason the run did not
report success is that it asked the FILESYSTEM whether the restore had left a
file behind.

---

## 6. What the manual now says

* **6.5 Software Update, the window** (new) — the four header states, why the
  third is separate from the first, the reasons a row can be blocked, the polkit
  and systemd path, and the development-signature refusal with the command that
  takes such a release anyway. 6.5–6.8 became 6.6–6.9; the two cross-references
  to "chapter 6.7" in chapter 9 were moved with them.
* **12.8 Versions, the window** (new) — the context-menu entry, the range in the
  subheading, sanoid's buckets on each card, the three buttons and which of them
  change anything, the confirmation, and the rename-aside rule with
  `Get-OS7RestoreAside`.
* **13.2 The two OS/7 applications** (new) — the pair in a table with where each
  one lives and where it is described; why Versions has no Start-menu entry; and
  that neither holds administrator rights.
* **13.6** no longer says there is no graphical administration surface, which
  stopped being true when these two shipped. It says what is still true: they
  are windows onto cmdlets and not a second set of rules.
* Screen 8 is called **Desktop** in chapters 3 and 13, which is the word on the
  screen. `InstallMode.Gui` is the enum behind it and appears on no screen.
* The menu path is **Apps → System Tools**, not "Start menu → System". Read off
  the menu rather than off `Categories=System;Settings;PackageManager;` in the
  desktop file, which is what the first draft said — GNOME's apps-menu maps
  those categories onto its own names.
* Three sentences were corrected against the code or the machine after being
  written from the plans: *Copy to…* writes the file itself (`File.Copy` in the
  window) rather than going through a cmdlet, so the claim that the window
  "copies no file" was wrong; `Get-OS7RestoreAside` needs an elevated session
  for its default dataset list (§4.2); and the example subheading now quotes
  what the picture beside it actually shows.

Both known limits are in the chapters as facts rather than as warnings, in the
form an operator meets them: a development-signed release is **refused by the
window** and only the cmdlet with `-AllowDevelopment` takes one (which is why
the window has still never completed an update — every release a bench can reach
is development-signed); and a file whose dataset keeps nothing gets the heading
*"Previous versions could not be listed."* while nothing has failed.

---

## 7. What this run does NOT say

* **arm64 is unmeasured**, as always. There is no desktop there at all, so the
  desktop half is amd64 by definition; the Setup pictures could be taken on the
  Mac and were not.
* **The two applications were driven, not tested.** `--self-test` (57 decisions
  for Software Update, 70 for Versions) and `check-gui-logic.py` are the gates
  and were not re-run here; this session photographed the windows and clicked
  one restore through.
* **Software Update has still never performed an update.** The row it was
  photographed with is refused on purpose.
* **The bench asked for the disk passphrase**, which `run-s5.py boot` would fail
  on. That is the bench's own note — it attaches a GPU, an xHCI controller, a
  keyboard and a tablet that the gate does not, and PCRs 0–7 measure the
  platform. It is not a TPM result about the product.
* **The cause of §4.3 is not established**, only that the declaration and the
  pixels disagree.
* **Nothing was rebuilt.** No ISO, no package. The pictures come from
  `OS7-1.0.0.245-amd64.iso` as published.
* **The PDFs were rebuilt and nothing checks them.** `build-pdf.py` renders
  through Edge and both came out (2.5 MiB each, up from 2.0); that they LOOK
  right on the new pages is unverified — nobody opened them.
* **`shoot-desktop.py` has run four times and only the last two were clean.**
  Its coordinates are measured on this bench at 1280x800; a different
  resolution needs them measured again, and the file says which are which.
* **Two BUILD-NOTES entries were added**, #185 (the AltGr table) and #186 (the
  greeter's session class). The three PRODUCT defects in §4 got none — they are
  not traps that cost this session time, they are defects waiting for an owner,
  and HANDOFF.md §2 is where they are named.
