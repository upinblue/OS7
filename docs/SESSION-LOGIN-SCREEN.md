# Session — the login screen: the fourth Ubuntu, and the database nothing looked at

**2026-08-29.** One complaint about a booted amd64 GUI machine: the login screen
still shows the Ubuntu logo and still looks like Ubuntu, and whatever fixes it
has to survive Ubuntu updates.

Everything below was measured out of the **shipped** `OS7-1.0.0.150-amd64.iso` —
loop-mounted, its squashfs mounted inside that, an overlay on top so the image's
own root could be chrooted into and asked questions. Nothing here was read out
of the source tree, and nothing was concluded from a build log.

---

## 1. Why every existing check was green

`docs/SESSION-CLASSIC-DESKTOP.md` and BUILD-NOTES #85 had already found one
theme that was installed, selected, correct and never asked for. This is the
same shape, one layer further out, and the reason it survived #85's fix is
simple: **the greeter does not read the database the desktop reads.**

```
the session   /etc/dconf/profile/user       -> system-db:os7
                                            -> /etc/dconf/db/os7
the greeter   /usr/share/dconf/profile/gdm  -> user-db:user
                                            -> file-db:/var/lib/gdm3/greeter-dconf-defaults
```

Hook 0090 checked `/etc/dconf/db/os7`. `check-image.py` dumped
`/org/gnome/` through `/etc/dconf/profile/user`. Both were right about the
session and neither had ever opened the file the login screen reads. The
greeter runs as the `gdm` user, before any of it exists.

---

## 2. Where the Ubuntu logo comes from

Not from a default nobody set. From a named line in a package that cannot be
removed:

```
/usr/share/glib-2.0/schemas/10_ubuntu-settings.gschema.override:72
    [org.gnome.login-screen]
    logo='/usr/share/pixmaps/ubuntu-logo-text-dark.svg'
    [org.gnome.desktop.interface]
    accent-color = 'orange'
```

`ubuntu-settings` owns that file; `ubuntu-desktop-minimal` **Depends** on
`ubuntu-settings`; hook 0035's header already lists it among the things that
cannot leave. So the file stays, and anything OS/7 does has to **out-rank** it
rather than remove it.

The orange highlight ring in the screenshot is the second line of the same
stanza, and it was not Yaru being Ubuntu. Both shell themes on the image honour
`accent-color`:

| gresource | occurrences of `-st-accent-color` |
|---|---|
| `gnome-shell/gnome-shell-theme.gresource` (GNOME's own) | 807 |
| `gnome-shell/theme/Yaru/gnome-shell-theme.gresource` | 903 |

and a grep for Ubuntu orange (`#e95420`) in Yaru's `gnome-shell.css` returns
nothing. The colour was arriving from a **setting**, applied system-wide — so
the OS/7 *desktop* had been drawing Ubuntu orange too, under a theme whose
entire point is that it does not look like Ubuntu.

---

## 3. GNOME's documented fix does nothing on Ubuntu

GNOME's System Administration Guide has one instruction for this: put a keyfile
in `/etc/dconf/db/gdm.d/` and run `dconf update`. Measured on the image:

```
/etc/dconf/db/gdm.d/           does not exist
/etc/dconf/profile/gdm         does not exist
/etc/dconf/db/                 ibus  ibus.d  os7  os7.d      <- no gdm
/usr/share/dconf/profile/gdm   user-db:user
                               file-db:/var/lib/gdm3/greeter-dconf-defaults
```

There is **no `system-db:gdm`** in that profile. `dconf update` would happily
read a `gdm.d` tree, write `/etc/dconf/db/gdm`, and exit 0 — and the greeter
would never open the file. That is the trap, and it is worth a number
(BUILD-NOTES #110) because the failure is silent at every step.

The mechanism that *is* real is Debian's, and it is written down in the file
next to the one we add:

```
/usr/share/gdm/dconf/00-upstream-settings, lines 1-6
    # This file is part of the GDM packaging and should not be changed.
    # Instead create your own file next to it with a higher numbered prefix,
    # and run `dconf update`
```

```
/usr/share/gdm/generate-config
    dconf compile '/var/lib/gdm3/greeter-dconf-defaults' '/usr/share/gdm/dconf'
/usr/lib/systemd/system/gdm.service:27
    ExecStartPre=/usr/share/gdm/generate-config
```

So the directory is recompiled on **every gdm start**, which is what makes a
file dropped into it durable without a trigger, a hook, or anything of OS/7's
running at boot. Sort order is precedence:

```
00-upstream-settings                          gdm3's own
90-debian-settings -> /etc/gdm3/greeter.dconf-defaults   the ucf conffile
95-os7-login-screen                           ours, and it sorts last
locks/                                        gdm3's, untouched
```

91–94 and 96–99 are deliberately left free: an operator can out-rank OS/7
without editing a shipped file, the same rule `00-os7-classic` follows about
not shipping a `locks/` directory.

---

## 4. The measurement that actually settles it

Reading our own keyfile back proves nothing — both sides come from this
repository. The question is not "is the value stored" but "does it beat the
override", and only **GSettings** resolves those two against each other.

So: compile `/usr/share/gdm/dconf` the way `generate-config` does, point a
throwaway profile at the result, and ask. Then do it again with our keyfile
removed, because a test whose control also passes measures nothing (#16, about
markers the command itself could have produced).

Run inside the shipped image's own root, with the new files overlaid, before
any of this was committed:

```
=== directory, in compile order ===
00-upstream-settings   90-debian-settings   95-os7-login-screen   locks

=== WITH 95-os7-login-screen ===
logo        = '/usr/share/pixmaps/os7-logo-login.svg'
accent      = 'blue'
font-name   = 'Tahoma 11'
antialias   = 'grayscale'
bg-colour   = '#0057ad'

=== CONTROL: same query, our keyfile removed ===
logo        = '/usr/share/pixmaps/ubuntu-logo-text-dark.svg'
accent      = 'orange'
bg-colour   = ''
```

The control is the half that matters. Without it, the first block would be
consistent with the value arriving from anywhere at all.

All four schemas and all twelve keys were also checked against
`gsettings list-schemas` / `list-keys` on the image, which is what catches the
slow failure: a key a future GNOME drops, leaving a line that compiles, stores
and does nothing.

---

## 5. The background, and why it is a Canonical key

The greeter background normally lives in the Shell stylesheet
(`#lockDialogGroup`), inside a gresource belonging to `gnome-shell` —
unreachable without replacing another package's file. Ubuntu patched their
Shell to read it from settings instead, and the consumer is real:

```
grep -rl com.ubuntu.login-screen  ->  /usr/lib/gnome-shell/libshell-18.so
```

and nothing else on the image. `com.ubuntu.login-screen background-color` is
therefore a supported lever **on this distribution and nowhere else**. If
Ubuntu drops the patch, the schema goes with it, hook 0090's schema check turns
red at build time, and a shipped machine falls back to the stylesheet's dark
grey. For a cosmetic that is the correct failure; the wrong one would have been
a stale CSS file nobody notices.

`#0057ad` is FIELD from `build/lib/palette.py` — `os7-setup`'s own screen
colour — so the greeter and the installer the administrator just walked through
are the same blue.

---

## 6. The stylesheet is chosen, not replaced

```
/var/lib/dpkg/alternatives/gdm-theme.gresource
  link  /usr/share/gnome-shell/gdm-theme.gresource                    (auto)
  10    /usr/share/gnome-shell/gnome-shell-theme.gresource            gnome-shell
  15    /usr/share/gnome-shell/theme/Yaru/gnome-shell-theme.gresource yaru-theme-gnome-shell
```

Yaru wins by priority on every machine, for ever, and cannot be removed —
`yaru-theme-gnome-shell` is a Depends of `ubuntu-session`, which `gdm3` depends
on. But this is an `update-alternatives` decision, which is dpkg's own mechanism
for choosing between two packages' implementations of one thing. `--set` picks
gnome-shell's own and puts the link in **manual** mode, so an upgrade of either
package cannot take it back — identical reasoning and identical mechanism to
`x-terminal-emulator` in hook 0035 step 5a.

Measured in the chroot:

```
theme -> /usr/share/gnome-shell/gnome-shell-theme.gresource
icons -> /usr/share/gnome-shell/gnome-shell-icons.gresource
```

What is traded is less than it sounds, because the two gresources were diffed
rather than assumed about:

| | Yaru | gnome-shell's own |
|---|---|---|
| distinct `.login-dialog*` selectors | 30 | 30, **and the sets are equal** |
| `authd` / `broker` / `web-login` strings | 328 | 328 |
| contains `gdm.css` | yes | yes |

Yaru is a **recolour** of the same upstream stylesheet, not a structural fork.
Nothing on the greeter loses its styling — including the authd surfaces the
Entra sign-in path will eventually need (C8a). What changes is the palette, and
the palette is the point: GNOME's own honours `accent-color`, so the login
screen recolours from a setting instead of from CSS OS/7 would have to maintain
against every GNOME generation. Reversible with
`update-alternatives --auto gdm-theme.gresource`.

---

## 7. The mark

`gnome-shell` renders the logo at **natural size times the HiDPI scale
factor**, which is a measurement and not a guess — from
`LoginDialog._updateLogoTexture`, read out of `libshell-18.so`:

```js
const texture = this._textureCache.load_file_sync(
    St.TextureCachePolicy.NONE, this._logoFile,
    -1, -1, scaleFactor, resourceScale);
```

`-1, -1` is natural size. Ubuntu's own is `width="187" height="72"`. So the file
that goes here is a wide lockup, not the square 128×128 `os7.svg` that
`/etc/os-release`'s `LOGO=` names — a square tile on that wide empty strip below
the user list reads as a misplaced app icon.

`/usr/share/pixmaps/os7-logo-login.svg` is 216×98: the OS/7 wordmark in white, a
rule, and up in blue GmbH's mark beneath it. The vendor mark ships beside it
verbatim as `upinblue-logo.svg`; the copy inside the lockup is the same 215
paths recoloured white, because its own `#417cbf` against `#0057ad` is a
contrast ratio of about 1.7:1. Rendered with `rsvg-convert` at 1× and 2× before
it shipped: the mark's 2.4-unit stripes resolve into a soft frame at scale 1 and
sharpen at scale 2, which is a property of the artwork at that size and not a
defect in the file.

The wordmark is `<text>`, the same deliberate trade `os7.svg` makes. That was
originally checked by rasterising it with `rsvg-convert` in hook 0035, which
had librsvg in its hands for the plymouth mark. **That check was wrong, and
§11 is what it cost.** It now lives in hook 0090 and asks GdkPixbuf.

---

## 8. What changed

| file | what |
|---|---|
| `build/packages/os7-desktop-theme/tree/usr/share/gdm/dconf/95-os7-login-screen` | new — the greeter's defaults |
| `.../tree/usr/share/pixmaps/os7-logo-login.svg` | new — the lockup |
| `.../tree/usr/share/pixmaps/upinblue-logo.svg` | new — the vendor mark, verbatim |
| `.../tree/etc/dconf/db/os7.d/00-os7-classic` | `accent-color='blue'` — the session had Ubuntu orange too |
| `.../control.in` | `libglib2.0-bin`, for the `gsettings` the postinst now needs |
| `.../postinst` | job 4: the mechanism, then the precedence proof |
| `build/config/hooks-amd64/0035-debrand-desktop.hook.chroot` | step 7a rasterises the greeter mark; step 9 sets the two gresource alternatives |
| `build/config/hooks-amd64/0090-desktop-theme-verify.hook.chroot` | §3b now runs over both keyfiles; new §6 with the compile, the GSettings query and the control |
| `installer/testing/check-image.py` | the same questions asked of the finished ISO |
| `build/lib/build-desktop-theme.sh` | the three new paths added to the `.deb`'s `MUST` list — 10 required paths became 13 |
| `CLAUDE.md` | #110 beside #85 in the trap list; they are the same failure one layer apart |

---

## 9. What the build measured

`make build-amd64` on the Windows host, 2026-08-29, produced
**`OS7-1.0.0.153-amd64.iso`**. Zero `FAIL` lines in the whole log; both hooks
ended with `done`. The new checks, verbatim:

```
hook 0035:  ok: greeter mark rasterises: 7492 bytes at 432x196
hook 0035:  ok: fc-match 'DejaVu Sans' -> DejaVu Sans (the greeter wordmark's face)
hook 0035:  ok: gdm-theme.gresource -> /usr/share/gnome-shell/gnome-shell-theme.gresource
hook 0035:  ok: gdm-icons.gresource -> /usr/share/gnome-shell/gnome-shell-icons.gresource
hook 0090:  ok: 95-os7-login-screen: 12 defaults checked against GNOME's own schema list
hook 0090:  ok: /usr/share/dconf/profile/gdm reads file-db:/var/lib/gdm3/greeter-dconf-defaults
hook 0090:  ok: /usr/share/gdm/generate-config compiles /usr/share/gdm/dconf
hook 0090:  ok: 95-os7-login-screen sorts last in /usr/share/gdm/dconf
hook 0090:  ok: greeter org.gnome.login-screen logo = /usr/share/pixmaps/os7-logo-login.svg
hook 0090:  ok: greeter org.gnome.desktop.interface accent-color = blue
hook 0090:  ok: greeter com.ubuntu.login-screen background-color = #0057ad
hook 0090:  ok: control: without 95-os7-login-screen the greeter shows
                 /usr/share/pixmaps/ubuntu-logo-text-dark.svg
hook 0090:  ok: /usr/share/pixmaps/os7-logo-login.svg (14019 bytes) owned by os7-desktop-theme
```

and `check-image.py amd64` on the finished artefact:

```
ok  the login screen shows the OS/7 mark, not Ubuntu's — /usr/share/pixmaps/os7-logo-login.svg
ok  and its accent is OS/7 blue, not Ubuntu orange — blue
ok  and its background is the Setup field colour — #0057ad
ok  and the greeter's stylesheet is GNOME's, not Yaru's
ok  and OS/7's greeter defaults sort last in /usr/share/gdm/dconf
ok  and both marks the greeter names are in the image
```

Three negative controls were run, because none of the above would mean anything
without them:

| control | result |
|---|---|
| compile the greeter directory with `95-os7-login-screen` removed | logo comes back as Ubuntu's, accent as `orange` |
| point the keyfile's `logo` at a path that is not the shipped mark | the postinst refuses and `dpkg` fails the install |
| delete the keyfile from the package tree and rebuild the `.deb` | `build-desktop-theme.sh` exits 1, so `build.sh` aborts the ISO |

## 10. What is still NOT measured

* **No machine has booted this ISO.** Everything above is the image and the
  mechanism. What the screen actually looks like — whether the blue reads well
  behind GNOME's translucent user tiles, whether the lockup sits well under the
  user list — is a question only a booted machine answers.
* **arm64 is untouched and unaffected** — it is server-only, there is no GDM on
  it, and both hooks are amd64-only.
* **The session chooser still says "Ubuntu"**, and that is not fixed here.
  `ubuntu-session` ships `/usr/share/wayland-sessions/ubuntu.desktop` and `gdm3`
  Depends on `ubuntu-session`. The default session is `gnome-classic`; the
  names in the menu are Ubuntu's.
* **Whether the composition looks good** is a matter of taste that a rendering
  at 1× and 2× can only half answer. The background colour is one dconf value
  and the logo one file path.

---

## 11. What booting it found: the login screen came up EMPTY

**Same day, an hour after §9.** The machine installed from
`OS7-1.0.0.153-amd64.iso` booted to the OS/7 blue background with a working top
bar and **no login dialog at all** — nothing to type a password into. Every
check in §9 had been green, including three negative controls.

`gnome-shell` loads `org.gnome.login-screen logo` through
`St.TextureCache.load_file_sync`, which goes through **GdkPixbuf** — glycin on
Ubuntu 26.04 — and GdkPixbuf decides whether a file is an image by **sniffing a
fixed prefix**, not by parsing it. Asked of the image's own loader:

```
OK   ubuntu-logo-text-dark.svg   187 x 72
FAIL os7-logo-login.svg          Couldn't recognize the image file format
```

Binary search against a known-good SVG with a padded comment pinned the window
exactly:

```
'<svg' beginning at byte 256  ->  loads
'<svg' beginning at byte 257  ->  refused
```

This repository writes long documentation headers. §7's file had a 35-line one,
which put `<svg` at **byte 2764**. And the symptom is not a missing logo:
`load_file_sync` throws inside `LoginDialog._updateLogoTexture` *while the
dialog is being constructed*, so the background (painted by Ubuntu's patch) and
the panel (a separate actor) survive, and the dialog never exists.

**Why §9's checks did not catch it.** Hook 0035 already had `librsvg2-bin`
installed for the plymouth mark, so it rasterised the greeter mark with
`rsvg-convert` and reported it green. `rsvg-convert` parses the XML properly and
never sniffs anything. It is simply **not the loader the greeter uses** — this
repository's own rule, *a diagnostic must be checked against the thing it claims
to check*, broken in the same session that wrote three controls for the feature
next to it.

A second, independent trap surfaced while fixing it, with a **different** error
message: moving the comment inside `<svg>` is not enough if the comment contains
`--`, which is illegal in XML. A dashed heading underline is exactly that.

```
byte offset wrong  ->  "Couldn't recognize the image file format"        (sniffing)
'--' in a comment  ->  "Failed to load image ... org.gnome.glycin.Error" (parsing)
```

Both produce the same empty screen, so the check asks both questions.

### The fix

| | |
|---|---|
| both SVGs | documentation moved **inside** `<svg>`; `<svg` at byte 39 whatever gets written about them later |
| hook 0035 | the `rsvg-convert` check **deleted** — a check that goes green while the machine is broken is worse than none |
| hook 0090 §6c | asks **GdkPixbuf** through `python3-gi`, at natural size and at scale 2, plus the byte-offset assertion and `fc-match` for the `<text>` face |
| `check-image.py` | the same question, of the finished ISO |

### The controls that make it a fix

| file the check was run against | result |
|---|---|
| the repaired marks | `ok: 216x98, '<svg' at byte 39` |
| **the file exactly as 1.0.0.153 shipped it** | `FAIL: '<svg' at byte 2764, past the 256-byte sniff window` |
| a file with an illegal `--` in its comment | `FAIL: Failed to load image ... glycin.Error` |

A check that cannot fail on the artefact that caused the incident is not a fix.

`OS7-1.0.0.154-amd64.iso` was built with all of it: zero `FAIL` lines, and
`check-image.py` green including

```
ok  and GdkPixbuf — the loader gnome-shell uses — loads the greeter mark — OK 216x98 off=39
ok  and GdkPixbuf — the loader gnome-shell uses — loads the vendor mark  — OK 511x224 off=39
```

**Still not measured: nobody has booted 1.0.0.154.** The broken machine was
repaired in place with `sed -i '/^<!--$/,/^-->$/d'` over the shipped SVG — the
same transformation, verified against the image's own loader before it was
handed over.

[BUILD-NOTES #111](BUILD-NOTES.md).
