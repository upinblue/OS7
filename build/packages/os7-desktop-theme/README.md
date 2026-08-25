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
| Session | GNOME Classic extensions from GNOME's **own** `gnome-shell-extensions` source package | **Yes.** Ubuntu updates them with `gnome-shell` — `50.0-1` against `gnome-shell` `50.1`, `Depends: gnome-shell (>= 50~), (<< 51~)` |
| Widgets | `gtk-3.0/gtk.css` | **Yes.** GTK 3 is frozen at 3.24 and imports Adwaita rather than replacing it |
| Shell | `gnome-shell/gnome-shell.css` via `user-theme` | **Partly.** Shell CSS is internal; the file styles colour only, so a renamed node costs one surface, not the desktop |
| GTK 4 | `os7-theme/gtk-4.0/os7-classic.css`, colours only | **Partly.** `@define-color` is the only lever libadwaita honours; structural CSS there breaks on upgrade and is therefore forbidden in that file |
| Defaults | `/etc/dconf/db/os7.d/` | **Yes.** A key GNOME drops becomes silently inert instead of failing |

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
