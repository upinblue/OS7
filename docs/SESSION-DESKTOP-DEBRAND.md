# Session — the amd64 desktop: what it was showing, and why

**2026-08-26.** Three complaints about a booted amd64 GUI machine, answered
against the shipped `OS7-1.0.0.109-amd64.iso` rather than against the source
tree. The ISO was loop-mounted, its squashfs mounted inside that, and every
claim below comes out of a file in it or out of a rendering made from a file in
it.

The complaints, in the order they were made:

1. the UI font is wrong
2. there is still too much Ubuntu in it, and the Ubuntu logo has to go
3. the onboarding screens are unwanted — and it must stay that way over updates
4. VS Code should be preinstalled beside Edge and Intune
5. there are graphical glitches on the desktop

Two of them turned out to be the same bug, and it was not the one anybody would
have guessed.

---

## 1. What the screen was actually showing

Three screenshots: `gnome-initial-setup` on its Ubuntu Pro page, the same on its
"Help Improve Ubuntu" page, and a desktop with the Intune agent open.

| what is on screen | what the image says it is |
|---|---|
| black top panel, `Apps` / `Places` in washed-out grey | **Ubuntu session**, Yaru shell stylesheet |
| a `Home` icon on an otherwise bare desktop | `ding@rastersoft.com`, enabled by `modes/ubuntu.json` |
| a bevelled grey taskbar along the bottom | `window-list`, enabled by OS/7's dconf defaults |
| a blue-gradient caption bar on the Intune window | `OS7-Classic` GTK 3 theme — the one part that *was* working |
| body text with vertical stems missing | GTK 4 + `font-antialiasing='none'` |
| the Intune window's text, crisp | GTK 3 + the same setting |

So the desktop was **half OS/7 and half Ubuntu at the same time**, which is what
"graphical glitches" was describing. Nothing was corrupt.

---

## 2. The theme was installed, verified, and never loaded

Full account in [BUILD-NOTES #85](BUILD-NOTES.md). The short version:

`00-os7-classic` set sixty-odd keys and did not set
`org.gnome.desktop.session session-name`. Ubuntu sets it to `"ubuntu"` from
`10_ubuntu-settings.gschema.override`, GDM reads it to choose the session for a
user who has not chosen one, and `modes/ubuntu.json` carries

```json
"stylesheetName":    "Yaru/gnome-shell.css",
"themeResourceName": "theme/Yaru/gnome-shell-theme.gresource",
"enabledExtensions": ["ubuntu-dock", "ubuntu-appindicators", "ding",
                      "tiling-assistant", "snapd-prompting",
                      "snapd-search-provider", "web-search-provider"]
```

A session mode's own stylesheet is not a default a user theme can be relied on
to beat. Hook 0090 was checking that the theme was **installed**. Nothing it
looked at knew whether anything would **load** it.

Fixed with one line — `session-name='gnome-classic'` — plus a second check,
because a session name that names nothing fails exactly as silently:
hook 0090 and `check-image.py` now both assert that
`/usr/share/wayland-sessions/gnome-classic.desktop` and
`/usr/share/gnome-shell/modes/classic.json` are on the image.

---

## 3. The font: twelve renderings that say where the fault is not

Full account in [BUILD-NOTES #84](BUILD-NOTES.md).

The obvious answer — "the Wine Tahoma replacement is badly hinted at 9 pt" — is
**wrong**, and it took twelve renderings to say so. `tahoma.ttf` was copied out
of the image and drawn outside the desktop:

| renderer | sizes | modes | result |
|---|---|---|---|
| FreeType via Pillow | 12 px | mono, grayscale | legible |
| Pango/Cairo | 12 px | `antialias=NONE`, `hint_metrics` on and off | legible |
| Pango/Cairo | 8–13 px | mono and grayscale | legible at every size |

What separates broken text from intact text on the real screen is the **toolkit**,
not the font: GTK 4 loses stems, GTK 3 does not, at the same size in the same
session. GNOME 50 draws through a GPU glyph atlas, and a 1-bit glyph has no
partial coverage left to spend when anything downstream resamples it.

`font-antialiasing='none'` was a deliberate choice, made for a real reason
(Windows 2000 rendered its UI text without antialiasing), against a GNOME that
no longer honours it. It is now `'grayscale'`. Hinting stays `'full'`; the
palette, bevels, square corners and metrics carry the classic look and none of
them changes.

**This is the one finding that can be tested without a rebuild**, on the machine
that showed the problem:

```bash
gsettings set org.gnome.desktop.interface font-antialiasing grayscale
```

---

## 4. The Ubuntu that can leave, and the Ubuntu that cannot

Read out of `/var/lib/dpkg/status` in the shipped image. The distinction that
decides everything here is **Depends** against **Recommends**.

**Only Recommended — purged, and pinned so they stay gone:**

| package | what it is |
|---|---|
| `gnome-initial-setup` | the first-login wizard in the screenshots |
| `ubuntu-report`, `ubuntu-insights` | telemetry to Canonical |
| `whoopsie`, `apport*` | crash reporting to Canonical |
| `ubuntu-docs`, `gnome-user-docs` | Ubuntu-branded help |
| `firefox` | the browser of this product is Edge |
| `plymouth-theme-ubuntu-text` | the Ubuntu wordmark on the text splash |

**Hard dependencies — they stay, and are made inert:**

| package | what depends on it | how it is silenced |
|---|---|---|
| `ubuntu-wallpapers` | `gnome-shell` | background is `#000000` |
| `ubuntu-session`, `yaru-theme-gnome-shell` | `gdm3`, `ubuntu-desktop-minimal` | the default session is `gnome-classic` |
| `gnome-shell-ubuntu-extensions` | `ubuntu-session` | `classic.json` does not enable them |
| `ubuntu-settings` | `ubuntu-desktop-minimal` | its gschema override is outranked by the dconf system db |
| `update-notifier` | `ubuntu-desktop-minimal` | autostart entry `Hidden=true` |
| `ubuntu-release-upgrader-gtk` | `ubuntu-desktop-minimal` | `Prompt=never` |
| `ubuntu-pro-client` | `ubuntu-minimal` | the Pro notification autostart is `Hidden=true` |

`gdm3` **Depends** on `ubuntu-session`, so the Ubuntu session and the Yaru shell
theme are on the image whatever else is done. That is why the fix is a session
default and not a package removal.

**snapd stays.** `firefox` was the only package depending on it, so the instinct
is to let the autoremove take it. `authd-msentraid` — the Entra ID broker
`installer/README.md` names as the route to Entra sign-in — is a Canonical snap
with no `.deb`. Removing snapd now would block the identity story before it is
built. It is marked `manual` so the autoremove cannot take it.

### The durable half is the pin, not the purge

Purging lasts until the first `apt full-upgrade` re-satisfies a Recommends of
`ubuntu-desktop-minimal`. `/etc/apt/preferences.d/os7-desktop-exclusions.pref`
ships in the image at `Pin-Priority: -1`, which is apt's own "never install
this, not even for a Recommends". It governs the installed machine and every
update after it, which was the actual requirement.

The hook does **not** read that file back. It runs `apt-cache policy` and
requires `Candidate: (none)`, because asking apt what it would now do is the
only thing that can tell a correct pin from a mistyped one.

---

## 5. The Ubuntu logo has two surfaces

The one in the screenshot belongs to `gnome-initial-setup` and leaves with it.

The other is the boot splash, and it would have been missed. `default.plymouth`
is `bgrt`, whose `[boot-up]` sets `UseFirmwareBackground=true`. On hardware with
an ACPI BGRT table that draws the firmware's own logo; on **every VM**, and on
plenty of machines, plymouth falls back to
`/usr/share/plymouth/themes/spinner/bgrt-fallback.png` — which, opened, is the
Ubuntu Circle of Friends. dpkg says the file belongs to `plymouth-theme-spinner`,
which cannot be removed because the `bgrt` theme itself lives in the same
package.

`dpkg-divert --local --rename` is what dpkg provides for exactly this: theirs
moves to `.distrib`, ours takes the name, and a future
`plymouth-theme-spinner` upgrade writes to the diverted name and leaves ours
alone. The check for it is the existence of `.distrib`, not the exit code of
`dpkg-divert`.

What replaces it is `usr/share/icons/hicolor/scalable/apps/os7.svg`, rasterised
at build time — which is also the icon that `LOGO="os7"` in `/etc/os-release`
has been promising since the identity work of the same day, and that nothing was
resolving.

---

## 6. VS Code

`packages.microsoft.com/repos/code`, suite `stable`, is signed by
**`EB3E94ADBE1229CF`** — the legacy key, the same one hook 0010 already installs
for `repos/edge`. Read out of the `InRelease` signature rather than assumed,
because the wrong key fails a build with "is not signed" and nothing else.

It is the one Microsoft package here that *does* have an arm64 build, so its
amd64-only-ness is entirely OS/7's decision that arm64 is a server target. That
is recorded in the hook so a future arm64 desktop is a product decision and not
a packaging discovery.

---

## 7. What was measured, and what was not

**Measured**, all against the shipped ISO or files taken out of it:

* the session mode files, the Ubuntu gschema override, and the absence of
  `session-name` from OS/7's own dconf keyfile
* twelve font renderings across two rasterisers, six sizes and both AA modes
* `Depends` against `Recommends` for 24 packages, out of the image's `dpkg/status`
* the signing key of `repos/code`, out of its `InRelease`
* that `bgrt-fallback.png` is the Ubuntu logo, by opening it
* that `LOGO="os7"` resolved to no icon anywhere in the image

**NOT measured — the whole point of writing it down:**

* **None of the fixes has been seen on a booted machine.** The build that
  carries them is `1.0.0.111`; `check-image.py amd64` checks the artefact, and
  an artefact is not a running desktop.
* The GTK 4 glyph-atlas explanation for #84 is the best account of the evidence,
  and it is an *explanation*, not a measurement. What is measured is that
  nothing outside the desktop reproduces the damage and that GTK 3 and GTK 4
  disagree on the same screen. The fix does not depend on the explanation being
  right: grayscale coverage survives every path 1-bit coverage does not.
* Whether the GNOME Classic session changes anything about **Intune enrollment**
  has not been tested. Microsoft's requirement is Ubuntu Desktop with GNOME, and
  Classic is GNOME Shell with a different mode file — but that reading has not
  been put to an actual enrollment.
* `authd`/`authd-msentraid` still is not installed, so keeping `snapd` is a
  decision made for a path nobody has walked yet.

## 8. Next

1. Boot `1.0.0.111` in the VM and look at the panel. It is grey or it is not.
2. `./installer/testing/check-image.py amd64` — eleven new checks about this.
3. If the panel is right and the text is legible, the remaining Ubuntu surfaces
   worth a decision are the GDM greeter (Yaru, and `gdm3` Depends on it) and
   `apt`'s Ubuntu Pro news lines, which have a supported off switch
   (`pro config set apt_news=false`) that this session did not take.
