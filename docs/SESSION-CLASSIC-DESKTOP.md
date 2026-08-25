# Session — the classic desktop theme

**2026-08-25.** A Windows 2000-styled desktop for the amd64 GUI product,
shipped and selected by default, built to survive Ubuntu upgrades, and
buildable by anyone who clones the repository.

What follows is what was measured, what was decided, and — the part that
matters most here — **what was not measured.**

---

## 1. The short version

| | |
|---|---|
| **Ships as** | `os7-desktop-theme`, a `.deb` built from `build/packages/os7-desktop-theme/` into `config/packages.chroot-amd64/` |
| **Session** | GNOME Classic's extensions, from GNOME's **own** `gnome-shell-extensions` source package — not dash-to-panel, not ArcMenu |
| **Defaults** | a dconf system database, `/etc/dconf/db/os7.d/`, 49 keys across 11 schemas |
| **Reversible** | `Set-OS7Theme -Name Classic|Stock`, implemented, not a stub |
| **Measured** | package builds; fonts extract and identify themselves; 46 of 49 defaults verified against GNOME's real schemas; GTK parses both stylesheets; no file collides with another package; **and the GTK half renders in the Windows 2000 palette — measured from the pixels** |
| **NOT measured** | **the GNOME Shell half.** The panel, the taskbar along the bottom edge and the black desktop need a session, and no amd64 image has been built |

The one-sentence rule the whole thing obeys:

> **Build the classic look out of parts Ubuntu itself keeps in step with GNOME,
> plus one package that touches no file it does not own.**

---

## 2. This overturns a locked decision

`README.md` said, under Locked decisions:

> GUI mode → GNOME, with dash-to-panel + arc-menu for a familiar feel (**not**
> a retro skin).

and

> **Branding:** classic/retro visual identity … applies to marketing/branding
> only, **not** to the GNOME desktop itself.

Both are now changed, on the product owner's instruction, and the change is
written into README rather than left to be discovered by the next session
reading a plan that contradicts the code.

Two things are worth recording about *why* the change is defensible rather than
merely instructed:

* **OS/7's text phase is already deliberately historical** — `os7-setup` is
  styled after MS-DOS 6.22 Setup and the Windows 2000 text phase, with a
  measured palette and a bitmap console font (SETUP-PLAN D5/D9). The open
  question was never whether OS/7 may look like this. It was where the line
  runs between *familiar to a Windows administrator* and *costume*.
* **The half of the old decision that was load-bearing survives intact.** What
  README actually needed was a taskbar and a start menu for administrators who
  live in Windows. That requirement is now met *better* than the old plan met
  it — see §4.

---

## 3. Three constraints, and what each one removed

**Intune decides the desktop, not us.** Microsoft's enrollment documentation is
explicit: *"Intune only supports Linux Ubuntu Desktop with a GNOME graphical
desktop environment,"* on Ubuntu Desktop 24.04 or 26.04 LTS, with Microsoft
Edge. Under README's own rule — Intune's constraints outrank OS/7's technical
preferences — that removes XFCE, KDE and every other desktop, however much
easier a classic look would be on them.

**GNOME 50 dropped the X.org session** and Ubuntu 26.04's desktop is
Wayland-only. That removes GNOME Flashback, Metacity and the whole family of
X11 window managers whose theme formats have been stable for fifteen years —
which is exactly what a Windows 2000 reproduction would want.

**libadwaita ignores widget themes by design.** GTK 4 applications can be given
colours through `@define-color` in the user's own `~/.config/gtk-4.0/gtk.css`,
and nothing else. There is no supported system-wide path and no supported way
to change their shape.

So the achievable target was fixed before any code was written: **GNOME Shell
on Wayland, repainted.** Not a different desktop, not a different toolkit.

---

## 4. Why GNOME Classic, and why this closes hook 0070's gap

Hook `0070-gnome-familiarity` existed to record that README's chosen taskbar and
start menu were not installable: neither `dash-to-panel` nor ArcMenu had a
GNOME-50-compatible build. Re-measured against the pinned snapshot
`20260824T000000Z`, resolute main + universe, amd64:

```
gnome-shell-extension-dash-to-panel     ABSENT
gnome-shell-extension-arc-menu          ABSENT
gnome-shell-extension-dashtodock        ABSENT

gnome-shell                             50.1
gnome-shell-extensions                  50.0-1   Recommends: gnome-classic
gnome-shell-extension-window-list       50.0-1   Depends: gnome-shell (>= 50~), (<< 51~)
gnome-shell-extension-apps-menu         50.0-1   "
gnome-shell-extension-places-menu       50.0-1   "
gnome-shell-extension-user-theme        50.0-1   "
gnome-classic                           50.0-1
```

**The absence and the version constraint are the same fact seen twice.** A
third-party Shell extension is an independent project that must chase each
GNOME generation; four months after GNOME 50 shipped, three of them still had
not arrived in a released archive. GNOME's own Classic extensions ship from the
same source package as the Shell and carry a hard `>= 50~, << 51~` dependency,
so Ubuntu updates them *together with* gnome-shell or not at all.

That inverts the maintenance question. The old plan needed someone to re-vendor
two extensions every generation. This one needs nobody: the taskbar is
`window-list`, the start menu is `apps-menu` plus `places-menu`, and Canonical
carries them.

So hook 0070 is gone, replaced by
`0090-desktop-theme-verify.hook.chroot`, which verifies rather than records.
**HANDOFF §6's open line about the familiarity gap is closed by this session.**

---

## 5. What it is made of, ranked by how long it will last

| Layer | Mechanism | Durability |
|---|---|---|
| Session | GNOME Classic extensions | **Highest.** Versioned with the Shell by Ubuntu |
| Widgets | `gtk-3.0/gtk.css`, `@import`ing Adwaita and repainting it | **High.** GTK 3 is frozen at 3.24; the file adds no structure |
| Defaults | dconf system database | **High.** A key GNOME drops goes silently inert (see §7) |
| Shell | `gnome-shell/gnome-shell.css` via `user-theme` | **Medium.** Shell CSS is internal; the file touches colour only, so a renamed node costs one surface |
| GTK 4 | `@define-color` only | **Medium.** The only lever libadwaita honours; structural CSS there is forbidden by the file's own header |

**Three rules make that table true**, and any future change should be checked
against them:

1. **Colour and edge, never structure.** The GTK 3 theme imports Adwaita and
   overrides it. It does not replace it.
2. **Own every file you ship, and ship no file anyone else owns.** Verified
   mechanically: `dpkg -S` over every installed path finds no second claimant.
   This is what makes a release upgrade a no-op rather than a conffile fight.
   It is also why `/etc/dconf/profile/user` is *edited* by `postinst` instead of
   shipped — GDM and Ubuntu may claim that path.
3. **Nothing is locked.** There is no `locks/` directory. Fleet enforcement
   belongs in an Intune policy, where a support engineer can see it; a look
   baked in so hard it cannot be turned off is indistinguishable from a bug.

---

## 6. What was measured

All in a container against the pinned archive, `./build/testing/verify-theme-package.sh`:

```
package builds from a clean tree             118 518 B, 10 required paths present
tahoma.ttf   name table                      family='Tahoma'  subfamily='Regular'
tahomabd.ttf name table                      family='Tahoma'  subfamily='Bold'
dconf database compiles                      8 spot-checked keys read back correctly
defaults verified against GNOME's schemas    46 of 49   (3 need gnome-shell, hook 0090 has them)
GTK 3 parses gtk-3.0/gtk.css                 0 parse errors, from GTK's own parser
GTK parses the libadwaita overrides          0 parse errors
fc-match Tahoma                              -> Tahoma, our file, no substitution
every shipped file owned by us alone         no second claimant, all paths
PowerShell module parses; manifest exports   7 functions incl. Get/Set-OS7Theme
Set-OS7Theme's key parser vs. the keyfile    49 pairs / 11 schemas, matching an
                                             independent grep count of 49 and 11
```

### The measurement that changed the design

BUILD-NOTES **#54** started life as the claim *"`dconf update` exits 0 for a
keyfile it cannot parse"*. That is false, and measuring it said so: a syntax
error exits 1 and writes no database at all.

What is true is worse. dconf has **no knowledge of GSettings schemas**. A
misspelled group or key compiles, stores, and reads back perfectly while GNOME
uses the default:

```
dconf read  …/interface/gtk-theme-name    ['OS7-Classic']    <- no such key
dconf read  …/interfase/font-name         ['Tahoma 9']       <- no such schema
gsettings get …interface font-name        'Adwaita Sans 11'  <- what GNOME uses
```

**And the first version of this session's own verifier passed that.** It read
our keys back out of our database — both sides of the comparison came from the
same misspelled file, so it proved only that the file agreed with itself. That
is the repository's own rule, *a diagnostic must not depend on the subsystem it
is diagnosing*, broken by someone who had read it that morning. The fix is to
ask GSettings, which knows what exists; both the hook and the test now do.

BUILD-NOTES **#55** is the other trap: `fonts-wine` contains no font data at
all, only symlinks into `wine-common`. Depend on the first without the second
and fontconfig substitutes silently.

---

### The GTK half, rendered and read back

`./build/testing/render-theme.sh` starts an X server, runs
`gtk3-widget-factory` under the theme, screenshots it and counts pixels. The
expected colours are typed into the test, not read from the theme — §6's
lesson, applied.

```
                              OS7-Classic          stock Adwaita
3D face          #d4d0c8      410 055 px  52.14%          0.04%
3D highlight     #ffffff      216 878 px  27.58%
caption start    #0a246a        9 614 px   1.22%          0.00%
caption gradient              82 distinct steps, reaching 96% of the way to #a6caf0
```

The stock-Adwaita column is what makes the first one mean anything: without it,
a render where no theme loaded at all could pass on a grey default.

Two things came out of looking at the picture rather than the numbers. Several
widget classes were still Adwaita — checkboxes and radios filled with accent
blue, round switch and scale handles, an accent underline on the current
notebook tab, hairline progress bars — because Adwaita states those rules more
specifically than the generic ones and therefore wins. They are fixed in a
clearly marked section at the bottom of `gtk-3.0/gtk.css`. And the first
version of the gradient check demanded the exact end colour `#a6caf0` and
measured 0.00%: the right-hand end of the caption bar is covered by the window
buttons, so that stop is never painted. The check now measures the gradient
instead of one of its endpoints.

### The baseline this theme will be compared against

`./installer/testing/check-image.py amd64` was run against
`OS7-1.0.0.48-amd64.iso` — the CI image built from `c4b3ddb`, i.e. **before**
this theme. Every check passed, and the two numbers that matter for spike S7
are recorded here so the next comparison has something to subtract from:

```
version            1.0.0.48    BUILD=48  commit=c4b3ddb29f38
package manifest   1528 packages
archive snapshot   20260824T000000Z, every apt source in the image on it
```

That image answers nothing about this theme — it does not contain it. Its value
is as the *before* half of a difference: an image built from this branch should
show `os7-desktop-theme` plus roughly eight archive packages for GNOME Classic,
and a moved manifest hash. That movement is intended, and is stated in the
commit so a later S7 run reads it as intent rather than drift. os7-b1's three
network packages move the same baseline independently.

Note for whoever runs this next: `check-image.py` resolves the ISO through a
container, so a **symlink** into another worktree's `out/` fails with
`failed to setup loop device`. A hardlink works.

## 7. What is still NOT measured

**The GNOME Shell half.** The panel, the taskbar and the desktop background are
drawn by gnome-shell, which needs a session — not an X server with one
application in it.

Specifically unproven:

* that `user-theme` loads `gnome-shell.css` and the panel turns grey
* that the window list appears along the bottom edge
* that the desktop is black rather than Ubuntu's default background
* that the Applications and Places menus appear and are usable
* that Edge and `intune-portal` — the two applications that decide whether this
  product is usable — do not look broken inside it
* that Tahoma at 9 points is legible on a real display at real DPI. The render
  says it draws; it does not say it reads well.

Also unmeasured, and worth naming: **the upgrade claim itself.** The argument
in §5 is structural, not empirical. Nobody has run this theme across an actual
distribution upgrade. The pinned snapshot makes that testable today without
waiting for 28.04 — install against one snapshot, `apt full-upgrade` to a later
one, and re-read the same pixels — and that is the test which would turn §5
from an argument into a result.

---

## 8. What to do next, in order

1. **Build an amd64 ISO with it.** Nothing else on this list can start until
   that exists, and it cannot be built on Apple Silicon (BUILD-NOTES #12/#23).
2. **Boot it and read the screen back.** The colours to check are exact:
   desktop `#000000`, caption gradient starting `#0A246A`, window face
   `#D4D0C8`. `installer/testing/vmscreen.py` does this for the text phase, but
   it is wired to `qemu-system-aarch64` — **an amd64 harness that synchronises
   on markers rather than wall-clock does not exist and is a task in its own
   right.**
3. **Then the upgrade test**, per §7: two snapshots, same pixels.
4. **Then Edge and `intune-portal` inside the theme.** They are Chromium and
   GTK respectively and neither has been looked at.
5. **Screen 8's GUI branch has still never run** (HANDOFF §2) — the installer's
   desktop-removal path and this theme meet there.

---

## 9. Files

```
build/packages/os7-desktop-theme/     the package: tree/, control.in, postinst, postrm
build/lib/build-desktop-theme.sh      builds the .deb, extracts and asserts the fonts
build/lib/ttf-family.py               reads a TTF's name table; the font assertion
build/testing/verify-theme-package.sh the container test in §6
build/testing/render-theme.sh         renders the GTK half and counts pixels
build/config/hooks-amd64/0090-…       verifies the installed image (replaces 0070)
build/config/package-lists-amd64/     GNOME Classic's extensions
build/config/os7-release.conf         the font pin: pool path + SHA-256
powershell/OS7/OS7.psm1               Get-OS7Theme, Set-OS7Theme
build/build.sh                        packages.chroot staging + the amd64 theme build
```
