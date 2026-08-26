# `os7-desktop-theme` — OS/7 Classic

The Windows 2000 surface for OS/7's amd64 GUI product. Built as a Debian
package out of this directory, installed into the image through
`config/packages.chroot-amd64/`, and — this is the point — **written so that an
Ubuntu release upgrade leaves it working.**

## The rule the whole package obeys

> Build the classic look out of parts Ubuntu itself keeps in step with GNOME,
> plus one package that touches no file it does not own.

Everything below is a consequence of that sentence.

| Layer | What it is | Survives a generation upgrade? |
|---|---|---|
| **Which session runs at all** | `org.gnome.desktop.session session-name = 'gnome-classic'` in the dconf database | **Yes**, and it is the load-bearing one — see below |
| Session | GNOME Classic extensions from GNOME's **own** `gnome-shell-extensions` source package | **Yes.** Ubuntu updates them with `gnome-shell` — `50.0-1` against `gnome-shell` `50.1`, `Depends: gnome-shell (>= 50~), (<< 51~)` |
| Widgets | `gtk-3.0/gtk.css` | **Yes.** GTK 3 is frozen at 3.24 and imports Adwaita rather than replacing it |
| Shell | `gnome-shell/gnome-shell.css` via `user-theme` | **Partly.** Shell CSS is internal; the file styles colour only, so a renamed node costs one surface, not the desktop |
| GTK 4 | `os7-theme/gtk-4.0/os7-classic.css`, colours only | **Partly.** `@define-color` is the only lever libadwaita honours; structural CSS there breaks on upgrade and is therefore forbidden in that file |
| Defaults | `/etc/dconf/db/os7.d/` | **Yes.** A key GNOME drops becomes silently inert instead of failing |

## The one key that decides whether any of the rest is seen

Added 2026-08-26, after this package had shipped in an ISO and been verified by
its own hook while producing **an Ubuntu desktop**.

GDM reads `org.gnome.desktop.session session-name` to pick the session for a
user who has not chosen one. Ubuntu sets it to `"ubuntu"` in
`10_ubuntu-settings.gschema.override`. This package set sixty-odd keys and not
that one, so the session that ran was Ubuntu's — and `modes/ubuntu.json` carries
its **own** `stylesheetName` (`Yaru/gnome-shell.css`), its own
`themeResourceName`, and its own extension list including `ding`. A session
mode's stylesheet is not a default a user theme can be relied on to beat.

So the theme was installed, selected, correct, and never asked for. The panel
stayed Yaru-dark, `ding` drew desktop icons onto a desktop that is meant to be
bare, and every check in hook 0090 passed. [BUILD-NOTES #85](../../../docs/BUILD-NOTES.md).

The fix is one key. The **second** part of the fix matters as much: hook 0090
and `check-image.py` now also assert that the session that key names is on the
image, because dconf stores any string happily and GDM falls back without a
word.

## Antialiasing is on, and that is not a change of taste

The keyfile used to set `font-antialiasing='none'`, on the correct observation
that Windows 2000 drew its UI text without antialiasing. GNOME 50 will not do
it: GTK 4 / libadwaita text loses vertical stems while GTK 3 text on the same
screen at the same size stays crisp, because the Shell draws through a GPU glyph
atlas and a 1-bit glyph has no partial coverage to spend when anything
downstream resamples it.

Twelve renderings outside the desktop — two rasterisers, six sizes, both AA
modes — say the font is not at fault. [BUILD-NOTES #84](../../../docs/BUILD-NOTES.md)
has them. `font-hinting` stays `'full'`; the palette, the bevels, the square
corners and the metrics are what carry the classic look, and none of them is
touched by this.

## The terminal lands in PowerShell, and that is also one boolean

`login-shell=true` on gnome-terminal's default profile. Not a custom command:
OS/7 already hands interactive human sessions to PowerShell from
`/etc/profile.d/95-os7-powershell.sh`, with five guards and an `OS7_NO_PWSH`
opt-out, and `/etc/profile.d` is read by **login shells only** — which a
terminal window is not, unless it is told to be one.

`use-custom-command=/usr/bin/pwsh` would have skipped `/etc/profile` entirely,
so `PATH`, the locale and the .NET environment would be missing inside the
window and the opt-out would not exist. [BUILD-NOTES #86](../../../docs/BUILD-NOTES.md).

The profile UUID is gnome-terminal's built-in default, read back out of the
image (`gsettings get org.gnome.Terminal.ProfilesList default`) rather than
copied from anywhere, and hook 0090 asks the same question at build time — if a
future gnome-terminal changes it, this setting lands in a profile nobody opens.

## Why not the obvious alternatives

**Why not dash-to-panel and ArcMenu**, which `README.md` used to call for?
Measured against the pinned archive (`20260824T000000Z`, resolute, amd64):
`gnome-shell-extension-dash-to-panel`, `-arc-menu` and `-dashtodock` are all
**absent** from main and universe. That is not bad luck, it is what a
third-party Shell extension does — it trails each GNOME generation by months.
GNOME's own Classic extensions do not, because they ship from the same source
package as the Shell.

**Why not GNOME Flashback, Metacity or XFCE**, which would give a far more
faithful Windows 2000 look with far less CSS? Two independent blocks. GNOME 50
dropped the X.org session and Ubuntu 26.04's desktop is Wayland-only, so the
classic X11 window managers have no session to run in. And Microsoft's Intune
documentation is explicit that only Ubuntu Desktop with GNOME is supported for
enrollment — under `README.md`'s own rule, Intune's constraint outranks OS/7's
technical preference.

**Why not replace `gnome-shell-theme.gresource`**, the way several retro
desktops do? Because it belongs to `gnome-shell`, and every upgrade takes it
back. That is precisely the maintenance treadmill this package exists to avoid.

## What it cannot do

Stated here so it is not rediscovered as a bug:

* **GTK 4 / libadwaita applications get classic colours and modern shapes.**
  Nautilus, Settings and most of GNOME's own applications are libadwaita, which
  ignores widget themes by design.
* **GDM is nearly untouched** — background and cursor only. The login screen's
  appearance lives in a `gnome-shell` file, and `user-theme` is a user
  extension that does not apply to the greeter.
* **The Applications menu sits top-left, not bottom-left.** GNOME Classic puts
  its menus on the top panel and the window list on the bottom. Moving the menu
  to the bottom edge means rebuilding Shell layout, which is exactly the kind of
  change that breaks on the next generation.
* **Client-side decorations stay client-side.** GTK application title bars are
  painted to look like classic caption bars; they are not real ones.

## Layout

```
tree/                                     the package's files, 1:1
  usr/share/themes/OS7-Classic/           the theme proper (GTK 3 + Shell)
  usr/share/os7-theme/gtk-4.0/            libadwaita colour overrides
  usr/share/fonts/truetype/os7-classic/   Tahoma (LGPL, from Wine) — see below
  usr/libexec/os7-theme-user-setup        links the GTK 4 overrides into $HOME
  usr/lib/systemd/user/                   the unit that runs it, pre-enabled
  etc/dconf/db/os7.d/00-os7-classic       the defaults
control.in                                @OS7_VERSION@ comes from the pin
postinst / postrm                         dconf profile, database, font cache
```

`../../lib/build-desktop-theme.sh` turns this into a `.deb`.

## The fonts

Windows 2000's UI font is Tahoma, which is not redistributable. The Wine
project ships a metrically compatible replacement under **LGPL-2.1+**
(`Copyright (c) 1993-2022 Wine project authors`), which is.

`fonts-wine` in the archive contains only symlinks — the actual TTFs live in
`wine-common`, an 11 MB package. Rather than put `wine-common` on a managed
corporate desktop, the build downloads that `.deb` from the pinned snapshot,
verifies its SHA-256 against `build/config/os7-release.conf`, and extracts the
two files it needs. Nothing named `wine` is installed on the running system;
the LGPL notice ships beside the fonts.

## Nothing here is locked

There is no `locks/` directory in the dconf database, on purpose. These are
defaults an operator may change. Fleet-wide enforcement belongs in an Intune
policy, where it is visible and auditable — not baked into an image, where a
support case cannot tell a policy from a bug.

Switching is `Set-OS7Theme -Name Classic|Stock`.
