# Session — where OS/7 still feels like a modified Ubuntu, walked on a fresh desktop

**2026-10-29.** Asked: *what would make the next version feel rounder — like an
operating system of its own and not like a modified Ubuntu? Fix the bugs found
on the way.*

The method was the one this repository trusts: install a machine from the
newest medium and use it the way a person does. `os7lab.py install qol --mode
Gui` from `OS7-1.0.0.245-amd64.iso` (the gated, unpublished third preview),
`de_DE.UTF-8`, keyboard `de`, then GRUB, the login screen, the first desktop
login through GDM, the Apps menu, Settings, the terminal, the console login and
apt — read off the screen and asked of the machine over ssh. Everything below
was seen on that machine unless it says otherwise. amd64 only; arm64 has no
desktop.

**It found four defects, all four fixed here:** the first login lands in the
Ubuntu session (#168), Settings > About shows the Ubuntu logo (#169), the
installer never generates the locale it names (#170), and #84 was never fixed —
every GTK 4 window drops letters, because Wine's Tahoma carries embedded bitmap
strikes at the UI size (#171). §3 is the list of improvements proposed for the
next version, in the order recommended.

---

## 1. The walk

| surface | what it showed on 1.0.0.245 | verdict |
|---|---|---|
| **GRUB** | Debian's blue box with cyan entries, `GNU GRUB version 2.14`, `OS/7 1.0.0 (preview)`, `Advanced options for OS/7 1.0.0 (preview)`, two `Memory test (mt86+x64…)` entries, `UEFI Firmware Settings`; a countdown of about 30 s on this boot although `/etc/default/grub` says 5 (consistent with Ubuntu's recordfail timeout; not traced further) | Ubuntu's look, OS/7's name |
| **boot** | `GRUB_CMDLINE_LINUX_DEFAULT=""` (`SystemSteps.cs`), so no `splash`: kernel and systemd text, then `Please unlock disk os7_root:` as console text. On this bench the kernel console was the serial line, so the screen itself was blank; the claim is from the installer's source | Linux, not a product |
| **login screen** | OS/7 blue, OS/7 mark, `up in blue` — but `Thu Oct 29` and `Not listed?` in English on a German install | OS/7 (#110 holds), wrong language (#170) |
| **first desktop login** | `gnome-shell --mode=ubuntu`: black Yaru panel, Ubuntu's `ding` Home icon. The `v20` bench's screenshot from 1.0.0.233 shows the same | **Ubuntu (#168)** |
| **OS/7 Classic, once selected** | grey panel, Tahoma, `Apps` / `Places`, taskbar — and the session OPENS IN THE ACTIVITIES OVERVIEW with a dock of four favourites, not on the desktop | right look, wrong first screen |
| **Apps menu** | `Software Update` (OS/7) directly above `Software Updater` (Ubuntu's update-manager), same icon; `Language Support`; `TeXInfo`; `Vim`; `Sysprof`; `Help` (yelp, with every help document purged by hook 0035); `Extensions` | two of everything, and developer tools on an admin desktop |
| **Settings** | GTK 4 text with letters missing — `Mult tasking`, `Not fications`, `Onl ne Accounts` (#171) | broken text |
| **Settings > About** | a large **Ubuntu** wordmark above `Operating System: OS/7 1.0.0 (preview)` | **Ubuntu (#169)** |
| **Settings > System > Software Updates** | starts Ubuntu's `update-manager`: *"Updated software has been issued since Ubuntu 26.04 was released. Do you want to install it now? 523.6 MB"* — Edge 153→156, Code 1.138→1.144, Intune portal, azure-cli, into the RUNNING boot environment | Ubuntu, and outside the update train |
| **Terminal** | PowerShell, correctly (#86 holds); white 80×24 window; PSReadLine's yellow on white; `Get-Help Get-Item` → *"Get-Help cannot find the Help files for this cmdlet on this computer … use Update-Help"* | works, looks unfinished |
| **console login** | `OS/7 1.0.0 (preview)`, the boot environment — then *"The programs included with the Ubuntu system are free software … Ubuntu comes with ABSOLUTELY NO WARRANTY"* (`/etc/legal`, first login per user) | Ubuntu's text |
| **apt** | `pro config show`: `apt_news True` (`motd.ubuntu.com/aptnews.json`); `/etc/apt/apt.conf.d/20apt-esm-hook.conf`; `APT::Periodic::Unattended-Upgrade "1"`; `update-notifier-motd.timer` enabled | Canonical's channels, live |
| **pwsh** | `~/.cache/powershell/7.6.5/update1_v7.6.9_2026-10-25`: the update check called Microsoft on the first login and found a release this product will never take that way; `telemetry.uuid` present | phones home, twice |
| **`useradd`** | six lines of `[sss_cache] … Can't find configuration db, was SSSD configured and run?` for one local account (sssd installed, not configured until a join) | alarming noise |
| **locale** | `locale: Cannot set LC_CTYPE to default locale`; `locale -a` → `C C.utf8 POSIX`; the desktop under `LANG=C.UTF-8` | **broken (#170)** |

What is right and should stay as it is: the login screen's brand, the Classic
theme itself once its session is selected, PowerShell in every terminal and on
every console, the MOTD header, `/etc/issue`, the home folders (xdg-user-dirs
works), and `Resources` and `Document Viewer` being there.

---

## 2. Fixed in this session

| # | defect | fix | held by |
|---|---|---|---|
| **#168** | first login = Ubuntu session; GDM never read the dconf key #85 set | `/etc/accountsservice/user-templates/{administrator,standard}` with `Session=gnome-classic` in `os7-desktop-theme`; firstboot migration `72-classic-session-default` for records GDM already wrote | `build-desktop-theme.sh` required paths, hook 0090, `check-image.py` |
| **#169** | Settings > About = Ubuntu logo, from two paths gnome-control-center hard-codes | the two `ubuntu-logo-text*.svg` diverted by `os7-desktop-theme`'s preinst, the product mark at the name | hook 0090 (diversion owner, `.distrib`, GdkPixbuf load), `check-image.py` |
| **#170** | the installer wrote `LANG=` and never ran `locale-gen` — every language, every install | `TargetIdentityStep.GenerateLocale`: enable the SUPPORTED line in `/etc/locale.gen`, `locale-gen`, prove with `locale -a`; firstboot migration `73-generate-named-locale` for installed machines | the step's own proof line; `run-phase3.py`/a fresh install is what decides it |
| **#171** | GTK 4 text drops letters (`Not fications`) — Wine's `tahoma.ttf` has bitmap strikes at 8–16 ppem, the UI size is 12 px, and GTK 4's GPU path draws them wrongly | `/etc/fonts/conf.d/64-os7-tahoma-outlines.conf`: `embeddedbitmap=false` for Tahoma alone; the font file is untouched | hook 0090, `check-image.py` (fontconfig's pattern at 12 px: `Tahoma True` on 1.0.0.245) |

**The image checks fire on the medium that has the defects.** `check-image.py
amd64` against `OS7-1.0.0.245-amd64.iso` with this tree's checks: **5 problems,
exactly the five new assertions** — both session templates, Tahoma at 12 px
(`Tahoma True`), both About logos (`diverted by nobody`) — and every other check
green. The first run of that showed a defect in the new probe itself:
`fc-match -f` prints no newline, so the next section's marker was glued to its
answer (`Tahoma True<<<desktop.aboutlogo>>>`) and the check would have been red
on a CORRECT medium too. Fixed with a trailing `echo`, run again, read as above.

**#171, one variable at a time** (each with a freshly started Settings): hinting
full or slight — broken; `GSK_RENDERER=ngl` — broken; `GSK_RENDERER=cairo` —
correct; Adwaita Sans — correct; Tahoma with every hinting instruction stripped —
no change, because it has none; Tahoma with `EBDT`/`EBLC` removed — correct
(`/proc/<pid>/maps` showed that file); the unchanged Tahoma under the
fontconfig rule — correct. The rule's cost: GTK 3 and the Shell draw Tahoma from
outlines too, softer than the pixel strikes. That is a visible change to the
Classic look and the owner should see it before a release carries it.

**The theme package, as an UPDATE.** `os7-desktop-theme` rebuilt from this tree at
the bench's own version (1.0.0.245, so `os7-desktop`'s exact dependency held) and
installed over the one the bench came with — which is the path `Update-OS7`
takes: the diversions appear without a warning, Ubuntu's two files are kept at
`.distrib`, fontconfig resolves Tahoma at 12 px with `embeddedbitmap=False`, the
templates are in place, Settings > About draws the OS/7 mark and every GTK 4
label is whole. `dpkg -r` puts Ubuntu's files back and removes the diversions;
installing again repeats the first result.

**Measured on the bench, by hand:** the template gives a new account
`gnome-classic` over D-Bus and a `--mode=classic` first login (twice, the second
time with the shipped, commented files); migration 72 moved `os7admin` and the
next login was `--mode=classic`; migration 73 generated `de_DE.utf8` on a
machine without it and was a no-op the second time; the locale procedure turned
`date` and the greeter's clock German.

**Verified on a fresh install from a medium carrying the fixes:** see §5.

**The two migrations' decisions are held by a check:**
`installer/testing/check-desktop-migrations.py` runs both in an `os7img:175`
container (the real `locales`, SUPPORTED and session files) through 24
scenarios — headless is untouched and gets no marker; `ubuntu` and empty are
moved and `gnome`, `ubuntu-xorg` and `gnome-classic` are not; a later,
deliberate `ubuntu` survives the next release's run; 73 generates, is a no-op
the second time, ignores `C.UTF-8`, and does not fail an update over a name
glibc does not support. And each migration's read-back is proven to FIRE: a copy
with the edit (72) or the `locale-gen` (73) removed exits non-zero. 24 checks,
0 failed.

**Not verified:** either migration under `os7-migrate-firstboot` after a real
`Update-OS7` (`run-s5.py all` is the gate that runs that path, and it runs
headless, where 72 exits early); the diversion on an UPGRADE of
`os7-desktop-theme` rather than a fresh install; arm64 (nothing here applies to
it except #170, which does).

---

## 3. Proposed for the next version

Numbered so they can be approved one by one. **Q-numbers, not decisions** —
where a plan document owns the question, the item says which.

### A. Remove what still says Ubuntu (cheap, mechanical, visible)

**Q1 — One updater.** Hide `update-manager`'s launcher and send everything that
starts it (Settings > System > Software Updates, update-notifier's "Show
Updates") to OS/7's Software Update, by diverting `/usr/bin/update-manager` to a
shim that runs `os7-software-update`. `update-manager` cannot be removed
(`ubuntu-release-upgrader-gtk` Depends on it, and `ubuntu-desktop-minimal` on
that), so this is #169's mechanism again. Measured today: the Settings row
starts `/usr/bin/python3 /usr/bin/update-manager`, found by name, not by
desktop file — so hiding the launcher alone leaves the row. *Small.*

**Q2 — A menu an administrator recognises.** Out of the Apps menu: `Language
Support` (it installs language packs with apt, outside the train — Q16 replaces
it), `TeXInfo`, `Vim`'s launcher, `Sysprof`, `Extensions` (it can switch off the
four extensions the Classic desktop is made of), and `Help` until Q10 gives it
something to show. Mechanism to be measured per entry: a package diversion of
the `.desktop` file (proven by #169) works in the overview and the menu alike;
an `applications-merged` menu file only reaches the Classic Apps menu. *Small.*

**Q3 — `/etc/legal`.** One honest OS/7 paragraph instead of "the Ubuntu
system": OS/7 is built on Ubuntu, the same licence pointer, the same warranty
sentence. `base-files` conffile, so hook-edited or diverted like #169. *Tiny.*

**Q4 — Canonical's channels off.** `pro config set apt_news=false` (the
switch SESSION-DESKTOP-DEBRAND §8 named and did not take), the ESM advertising
apt hook made silent, and `update-notifier-motd.timer` disabled (the release
upgrader is already `Prompt=never`). `ubuntu-pro-client` is a Depends of
`ubuntu-minimal` and stays installed. *Small.*

**Q5 — A boot menu that looks like OS/7.** Monochrome, NT-loader style —
`menu_color_normal=light-gray/black`, `menu_color_highlight=black/light-gray`,
which are built-in GRUB commands and therefore safe under Secure Boot (efi-
remaster's rule: no module from disk); `GRUB_DISABLE_SUBMENU=y` so there is no
"Advanced options for" line; memtest out of the main list; and entry titles a
person can read — `OS/7 1.0.0` and `OS/7 1.0.0.203 — previous version
(2026-09-09)` instead of `OS/7 1.0.0.245 — os7_1.0.0.245_202610290955`
(`OS7.psm1:1691`). Applies to installed machines and, separately, to the
medium's own menu in `efi-remaster.sh`. A gfxmenu theme would need modules and
is out unless measured under Secure Boot. *Small–medium; run-secureboot.py is
the gate.*

**Q6 — A graphical boot on desktop machines.** `quiet splash` on GUI installs
and an OS/7 plymouth theme (the mark, a progress line, the LUKS passphrase
prompt in the product's blue) instead of kernel text and a console prompt.
Headless stays text: it is a server, and `run-phase3.py`/#132 read the serial
line. Costs to measure: the TPM-unlock path is unchanged by plymouth, but the
passphrase fallback moves into it; #25/#31's palette and fbcon behaviour on the
console after plymouth quits. *Medium.*

**Q7 — Open on the desktop, not the overview.** GNOME Classic starts in the
Activities overview; Windows starts on the desktop. There is no setting; it is
a few lines of Shell extension. **Owner decision:** DECISIONS (2026-08-25)
admits only GNOME's own extensions because a third-party one must chase every
GNOME generation — a first-party `os7-shell@os7` of a dozen lines has the same
cost, paid by OS/7. Without it, the overview stays.

**Q8 — Decide the look #171's fix gives the Classic desktop.** The fix is
made (§2) and it trades the pixel-exact bitmap Tahoma in GTK 3 and the Shell for
outline Tahoma everywhere. If the owner wants the pixel look back in GTK 3 and
the Shell, the alternatives measured today are worse: GTK 4 windows in
`Adwaita Sans` (correct, loses the period face there) or `GSK_RENDERER=cairo`
for the whole session (correct, costs GPU rendering for every GTK 4 window).
A real GPU is still unmeasured. *A look at a screen, then nothing or tiny.*

### B. PowerShell that feels native

**Q9 — `sudo Update-OS7` just works.** #148's message is correct and still
sends the operator to `sudo pwsh -c '…'`. A `sudo` function in the interactive
profile — executables go to `/usr/bin/sudo` untouched; a PowerShell command
runs as `sudo pwsh -NoProfile -Command <the statement as typed>` — removes the
most common first-hour stumble. Plus the Windows convention of an
`Administrator:` window title when elevated. **Owner decision:** it shadows a
system command, as P1a already does for `Restart-Computer` (#142), and
`check-compat-windows.py` is the model for holding it.

**Q10 — Help on the machine.** `build-pdf.py --html` already renders the
administrator manual; ship it (DE and EN, with images) as an `os7-docs` package
under `/usr/share/doc/os7/`, give it an `OS/7 Help` launcher (Q2's empty `Help`
becomes this), and an `about_OS7` topic so `Get-Help about_OS7` says where to
start. And offline help for the built-in modules — `Save-Help` at build time,
hashed like every other input — so `Get-Help Get-Item` is not "partial help".
The manual still lacks chapters for Software Update and Versions (owner's
decision 2026-09-21: a session of their own). *Medium.*

**Q11 — A terminal that looks intended.** The gnome-terminal default profile
(already OS/7's, #86): Cascadia Mono (in the pinned archive — 1.3 MB download;
the console's PSFs are already made from it), a dark scheme (Windows Terminal's
Campbell) so PSReadLine's colours are legible, and 120×30. A launcher named
`PowerShell` beside `Terminal`, because that is the word a Windows
administrator types into a menu. VS Code's integrated terminal is still bash
(SESSION-DESKTOP-DEBRAND §7). *Small.*

**Q12 — PowerShell stops calling home.** `POWERSHELL_UPDATECHECK=Off` in the
`os7-powershell` package: measured, the check reached Microsoft on the first
login and found 7.6.9, and DECISIONS ("Shell") says PowerShell updates only
through the train. **Owner decision** for `POWERSHELL_TELEMETRY_OPTOUT=1`,
which would be consistent with hook 0035 purging Canonical's telemetry ("a
managed fleet reports to whoever manages it"). *Tiny.*

### C. Updates that feel like an operating system's

**Q13 — "Restart to finish installing."** `os7-update-check` stages a release
(exit 2) and tells nobody. Write its state where the storage banner's is
(`/run/os7/…`), add a MOTD line, raise a desktop notification, and give
Software Update a *Restart now* — Windows' own sequence. *Medium.*

**Q14 — Edge, Code, Intune: who updates them?** Today nobody, by design — and
Ubuntu's updater offers 523.6 MB of them to anyone who clicks Settings >
Software Updates, into the running environment. Edge at 153 against 156
upstream is a browser three major versions behind, five weeks after the medium
was cut. **Owner decision, and the
most consequential one here:** pin them in the release (RP4, #144: every Edge
release becomes a release event), or a separate in-place channel for the
Microsoft applications, reported as drift. Q1 and Q15 should follow whatever
this decides.

**Q15 — One update mechanism.** `unattended-upgrades` runs daily against
Ubuntu sources that are a frozen snapshot: inert, present, and one more thing
an auditor asks about. Disable it explicitly (or give it Q14's job, if Q14
says so). *Tiny.*

### D. First impression of the installed system

**Q16 — The language the operator chose.** After #170 a German install has
German formats under an English desktop. `language-pack-de-base` +
`language-pack-gnome-de-base` are **22.5 MB installed, 5.2 MB to download**
(measured, pinned archive); English is 5.9 MB. Ship DE and EN on the GUI
medium and install the pack for screen 3's language; other languages stay
English UI with local formats, said on screen 3. **Owner decision:** which
languages. *Small.*

**Q17 — `useradd` without six error lines.** sssd is installed for the domain
join and unconfigured until one, and shadow's tools call `sss_cache`, which
complains on every account operation. A diverted `sss_cache` that is silent
exactly when `/var/lib/sss/db/config.ldb` does not exist. *Small.*

**Q18 — The shortcuts a Windows administrator's hands know.** Super+E → Files,
Ctrl+Shift+Esc → Resources, Super+R → the run dialog, Super+D → show desktop.
dconf keys in `00-os7-classic`, held by hook 0090's schema check. *Tiny.*

**Q19 — The next application.** GUI-APPS-PLAN §6 already orders the family;
*System Restore* (boot environments) is the one with no Windows mental model
and the most to gain from a picture. Its cmdlets are gated by `run-s5.py` — and
the removal defect below should be fixed before a window offers *Delete*.

**Q20 — The pools are not drives.** Found while doing Block A: GNOME Files lists
`rpool` and `bpool` in its sidebar beside Documents and Downloads, as if they
were removable volumes a person might open or eject — the system's own ZFS
pools, one click from an *Unmount*. udisks sees the LUKS and ZFS members as
block devices; the usual lever is a udev rule setting `UDISKS_IGNORE=1` on
them. To be measured, including that nothing OS/7 asks of udisks needs them.
*Small.*

### E. Defects already on record that belong in the same release

- `Remove-OS7BootEnvironment` cannot remove the environment a machine rolled
  back from, and says so in ZFS's words (SESSION-PREVIEW-245 §11); with it,
  `run-s5.py`'s timer phase precondition that is stated and not checked (§11.1).
- The Complete screen says nothing about Secure Boot, nor about a domain join's
  outcome (HANDOFF §2).
- The manual's Setup and desktop pictures are 1.0.0.175-era (SESSION-PREVIEW-245
  §10) — and every desktop picture will change again with #168 and Q2–Q11.

### Recommended order

1. **This session's four fixes**, verified (§5), then `run-s5.py all` for the
   two migrations. Whether 1.0.0.245 should still be published as it is, with
   #168 and #170 in it, is the owner's call.
2. ~~**Q1–Q4, Q12, Q15, Q17, Q18**~~ — **DONE the same day, §6**, each with a
   hook 0090 or `check-image.py` assertion that fails on 1.0.0.245 first. It
   found two more defects on the way (#172, #173).
3. **Q8** (a look, not work), then **Q11** and **Q5** — the things a person
   looks at for longest.
4. **Q10** and **Q13** — help and the restart notice, both medium.
5. ~~**Decisions wanted**~~ — **MADE 2026-10-29, §7.** Q7 (an OS/7 Shell extension), Q9 (shadowing `sudo`),
   Q12's telemetry half, **Q14** (Microsoft packages), Q16 (languages).
6. **Q6** (graphical boot) and **Q19** (System Restore) — the largest, and both
   worth a session of their own.

---

## 4. What was NOT measured

- A real GPU. #171 and the overview were seen on virtio-gpu.
- The live session on the medium. Everything here is the installed system.
- arm64, which has no desktop; #170 applies to it and was not run there.
- Whether the Classic session changes Intune enrollment (still open since
  SESSION-DESKTOP-DEBRAND §7) — #168 makes this more urgent, because until now
  nobody has used a freshly installed machine in the Classic session at all.
- Q-items are proposals; none has been tried beyond what its paragraph says.

---

## 5. Verification on a medium carrying the fixes

`OS7-1.0.0.247-amd64.iso`, built from this tree (dirty, so `reproducible:
false`; `OS7_REPO_NO_CREDENTIAL=1`, development key — a development medium,
not a release candidate). A first build was stopped half-way because the tree
had moved on under it (the fontconfig rule, `--no-rename`, migration 73); the
medium measured here carries all of it.

**The build.** Hook 0090 green, including every new line: both templates
`Session=gnome-classic`, `Tahoma at 12 px resolves with embeddedbitmap=False`,
both logos diverted by `os7-desktop-theme` with `.distrib` kept and loaded by
GdkPixbuf at `'<svg' at byte 0`. `os7-release` carries 22 required paths (73 is
the new one), `os7-desktop-theme` 18. No `--rename` warning from this package;
the three that remain in the log are live-build's and hook 0075's own, and older.

**The artefact.** `check-image.py amd64`: the five new assertions **ok**
(they are red on 1.0.0.245), and 5 failures that are the known shape of a
development medium — the trust anchor holds only the development key, and the
repository credential is absent by `OS7_REPO_NO_CREDENTIAL=1` (four lines for
that one fact, as on 1.0.0.222).

**The machine** — `os7lab.py install qol2 --mode Gui`, unattended, `de_DE.UTF-8`,
then used:

| | fresh 1.0.0.245 | fresh 1.0.0.247 |
|---|---|---|
| `locale -a` | `C C.utf8 POSIX` | `C C.utf8 de_DE.utf8 POSIX` |
| `locale` | three "Cannot set …" errors | none |
| install.log | — | `locale de_DE.UTF-8 generated (locale -a lists de_DE.utf8)` |
| login screen clock | `Thu Oct 29` | `Do Okt 29` |
| first GDM login of the installer's account | `gnome-shell --mode=ubuntu`, `LANG=C.UTF-8` | `gnome-shell --mode=classic`, `XDG_SESSION_DESKTOP=gnome-classic`, `LANG=de_DE.UTF-8` |
| Settings > About | Ubuntu wordmark | the OS/7 mark |
| GTK 4 labels | `Not fications`, `Onl ne Accounts` | whole |
| `fc-match` Tahoma at 12 px | `embeddedbitmap` True | False |

The desktop's own strings stay English — no language pack, Q16 — and the
session still opens in the overview, Q7. Both are §3's, not defects of the fix.

---

## 6. Block A — Q1–Q4, Q12, Q15, Q17, Q18, done the same day

Approved by the owner after §3 was written. Each item ships in the package
that owns the concern, so `Update-OS7` carries it to machines already
installed, and each is held by a check that is RED on 1.0.0.245.

| Q | what changed | package / place | held by |
|---|---|---|---|
| Q1 | `/usr/bin/update-manager` is a shim that starts OS/7's Software Update; Ubuntu's program and its "Software Updater" launcher are diverted away (`--rename`; update-manager is not Essential) | `os7-app-softwareupdate` preinst/postrm + `tree/usr/bin/update-manager` | hook 0090 3d, `check-image.py` |
| Q2 | Language Support, TeXInfo and Vim launchers diverted out of the menu (all three packages are hard dependencies); `sysprof` and `gnome-shell-extension-prefs` purged and pinned (only Recommends — a purge simulation removed exactly the two). **Help is NOT hidden**: yelp is the `help:` handler, so F1 would break — Q10 gives it content instead | `os7-desktop-theme` preinst/postrm; hook 0035 | hook 0090 3d, `check-image.py` |
| Q3 | `/etc/legal`: "OS/7 is built on Ubuntu. The programs included with it are free software…" | hook 0075, like `/etc/issue` | hook 0075's own check, `check-image.py` |
| Q4 | the Ubuntu Pro ESM advertisement hook cleared (`#clear binary::apt::AptCli::Hooks::Upgrade`); `apt-news.service`, `esm-cache.service`, `update-notifier-motd.timer` and `update-notifier-download.timer` masked, once per machine (a marker, so an administrator's unmask is not undone by the next update) | `os7-release`: `/etc/apt/apt.conf.d/99os7-one-update-path` (a conffile), postinst | `check-image.py` |
| Q12 | `POWERSHELL_UPDATECHECK=Off` for login shells and for the desktop session | `os7-powershell`: profile.d, `/usr/lib/environment.d/60-os7-powershell.conf` | hook 0050 (asked of the handed-off PowerShell), `check-image.py` |
| Q15 | `APT::Periodic::Unattended-Upgrade "0"` | `os7-release`, the same apt.conf part | `check-image.py` |
| Q17 | `/usr/sbin/sss_cache` is a wrapper that exits 0 silently while `/var/lib/sss/db/config.ldb` does not exist and is sss_cache once it does; sssd-tools' binary diverted to `.distrib` | `os7-release` preinst/postrm + `tree/usr/sbin/sss_cache` | `check-image.py` (runs it in the image) |
| Q18 | Super+E Files, Super+R run dialog, Super+D show desktop, Ctrl+Shift+Esc Resources ("Task Manager", a custom keybinding under a relocatable schema) | `00-os7-classic` | hook 0090 (compiled db + schema), `check-image.py` |

**Two defects found by doing it**, both now fixed and numbered:

- **#172** — `Set-OS7Theme`, the documented off-switch for the Classic look,
  threw on every machine since 2026-08-26: its keyfile parser turned the
  relocatable terminal-profile group into a schema that does not exist. Found by
  asking how the existing relocatable key was handled before adding a second.
- **#173** — the theme's terminal default was written to
  `/org/gnome/desktop/default-applications/terminal/`, the schema's ID spelled as
  a path; the schema lives at `/org/gnome/desktop/applications/terminal/`, so
  GSettings never read it. Hook 0090 passed it because it derived the id from
  the path. Fixing the module's resolution found that two schemas share
  `/org/gnome/mutter/`.

**Measured on the bench before the build** (`qol2`, 1.0.0.247, every package's
real maintainer scripts run as dpkg would, files put where the packages put
them):

| | before | after |
|---|---|---|
| `useradd -m` output | 4 lines of sss_cache errors | 0 |
| `APT::Periodic::Unattended-Upgrade` | `"1"` | `"0"` |
| ESM hook in `AptCli::Hooks::Upgrade` | 1 | 0 (the snap hook under `Install` kept) |
| the four Ubuntu units | static, static, enabled, enabled | masked ×4; a second postinst run changes nothing |
| launchers in `/usr/share/applications` | update-manager, language selector, info, vim | all four diverted |
| Ctrl+Shift+Esc | nothing | `/usr/bin/resources` |
| Super+E | nothing | Files at the home folder |
| Settings > System > Software Updates | Ubuntu's update-manager, 523.6 MB offered | OS/7's Software Update |
| `systemctl --user show-environment` | — | `POWERSHELL_UPDATECHECK=Off` |
| handed-off PowerShell (hook 0050's question) | — | `OS7_UPDATECHECK=Off` |
| `Set-OS7Theme Stock`, then `Classic` | throws at the terminal key | both exit 0, 61 keys |
| `Get-OS7Theme` overridden | 1 (a false report, #173) | 0 |
| `gsettings get … terminal exec` | `'xdg-terminal-exec'` | `'gnome-terminal'` |
| hook 0090, run on the bench | — | green except sysprof/extension-prefs, which hook 0035 removes at build time and the bench never ran |

**The checks fire on the medium that has the defects.** `check-image.py amd64`
against `OS7-1.0.0.245-amd64.iso` with this tree's checks: **15 problems, every
one of them a new assertion** — the five of §2 and ten from Block A — and every
other check green. Read off the artefact: `/etc/legal` "The programs included
with the Ubuntu system…", `Unattended-Upgrade "1"`, `esmhooks 1`, four units
unmasked, `sss_cache` printing two lines with no diversion, no shortcut set,
update-manager undiverted with no shim, six launchers present, and #172 itself:
`gsettings has no org.gnome.terminal.legacy.profiles:.:b1dcc9dd-… login-shell`.
#173 is the one this cannot see on 1.0.0.245, because that module spelled the
wrong path into an id that exists; hook 0090's 3b is what holds it.

**The first two builds of Block A failed, on a check of my own.** Hook 0090
got a new section 3c that called `Get-OS7ThemeKeys` in the chroot. The first
build stopped at *"no valid module file was found"* (imported by name), the
second at *"The term 'Test-Path' is not recognized"* (imported by path). Both
are BUILD-NOTES #14/#38, which hooks 0060 and 0075 already explain: under
live-build's chroot a hook may import a module and list its exports, and may not
call a function that needs a bundled cmdlet. The snippet had been tried on a
booted bench, where both work. The check now lives only in `check-image.py`,
where it already was and where it was already red on 1.0.0.245. Everything else
in both builds was green, including 3b's stricter path rule over all 73 keys of
both keyfiles.

**On a medium carrying Block A** — `OS7-1.0.0.247-amd64.iso` rebuilt from this
tree (development: dev key, no repository credential), the third build:

- **the build:** hooks 0035, 0050, 0075 and 0090 green on every new line —
  `POWERSHELL_UPDATECHECK=Off` asked of the handed-off PowerShell, `/etc/legal`
  names OS/7, the four launchers out of the menu, sysprof and extension-prefs
  not installed, the shortcuts in the compiled database, 3b's path rule over all
  73 keys.
- **the artefact:** `check-image.py amd64` — **all fifteen new assertions ok**
  (red on 1.0.0.245), and the same five development-medium failures as before.
- **a fresh install from it** (`qol3`, unattended, GUI, `de_DE.UTF-8`), used:
  `useradd` printed nothing; `Unattended-Upgrade "0"`, no ESM hook, the four
  units masked; `/etc/legal` OS/7's; the six launchers hidden and the eight
  diversions owned by the right packages; the handed-off PowerShell has
  `POWERSHELL_UPDATECHECK=Off` and so does the desktop session; `de_DE.utf8`
  generated, Tahoma from outlines, the session template in place. Through GDM:
  the Apps menu holds ONE Software Update (System Tools: Software Update, Disks,
  Settings, Logs, Resources; Accessories: Characters, Clocks, Files, Help, Text
  Editor); Ctrl+Shift+Esc started `resources` and Super+E Files, each asked of
  the process table; Settings > System > Software Updates started
  `/usr/lib/os7/apps/software-update/os7-software-update`; `Set-OS7Theme` Stock
  and Classic both exit 0 over 126 steps; `Get-OS7Theme` reports nothing
  overridden; GSettings reads the terminal default as `'gnome-terminal'`.

**Not verified:** `Update-OS7` carrying these packages to a machine installed
from 1.0.0.245 — the maintainer scripts were run by hand on a 1.0.0.247 bench as
dpkg would, and the diversion cycle of `os7-desktop-theme` was run by dpkg
itself, but nothing has gone through the update train with them; and arm64,
where `os7-release`'s half (Q4, Q15, Q17) applies too.

**Not done in Block A, on purpose:** `pro config set apt_news=false` (masking
the service that fetches the news is the stronger form and needs no `pro` run in
a chroot); hiding Help (above); existing machines' `/etc/legal` (it is a
base-files conffile and only new images get the new text).

---

## 7. The decisions §3 asked for — made by the owner, 2026-10-29

Each is recorded in the document that owns its question, not only here.

| Q | decision | recorded in |
|---|---|---|
| **Q14** | **Edge updates itself, as on Windows; VS Code, the Intune portal and the identity broker are pinned in the release** (version + SHA256, like pwsh), which closes #144. Edge in place is drift by design; a rollback takes it back with its boot environment. The mechanism is still to be chosen and measured | CURATION-AND-DELIVERY-PLAN **C15** (and it corrects RELEASE-AND-UPDATE-PLAN §3.4 for Edge) |
| **Q16** | **Several EU languages on the desktop medium** — German, English, French, Dutch, Italian, Spanish; Setup installs the pack screen 3's language needs. German and English measured (22.5 MB and 5.9 MB installed); the other four to be measured before they are added | CURATION-AND-DELIVERY-PLAN **C16** |
| **Q9** | **`sudo` becomes a PowerShell function** in the interactive session: executables pass through untouched, PowerShell commands run as `sudo pwsh -NoProfile -Command <statement>`, and an elevated session titles its window `Administrator:`. Held by a check in `check-compat-windows.py`'s shape | POWERSHELL-SURFACE-PLAN **P13** |
| **Q7** | **An OS/7-owned Shell extension, `os7-shell@os7`**, so the session opens on the desktop — the one exception to "GNOME's own extensions only", kept small and checked against the installed Shell's version | DECISIONS.md, GUI mode |
| **Q8** | **Tahoma from outlines, everywhere** — the state #171's fix already ships; decided after the two looks were compared on screen | DECISIONS.md, GUI mode |
| **Q12** | **PowerShell's telemetry off as well as its update check** (`POWERSHELL_TELEMETRY_OPTOUT=1`, in the same two places) | CURATION-AND-DELIVERY-PLAN **C17** |

What these unblock, in the order §3 recommended: Q11 and Q5 need no decision
and come next; Q9, Q7, Q12's telemetry half and Q16 are now work rather than
questions; Q14 needs its mechanism measured first — whether Edge's own updater
works under a read-only `/opt` and an apt-managed package, or whether a
dedicated timer with an apt origin pin restricted to Microsoft's Edge
repository is the honest form.

---

## 8. The decisions, built — Q12's telemetry, Q9, Q7, Q16

Approved by the owner after §7. Q14 is not here: its mechanism is still to be
measured.

| | what was built | measured before / while building |
|---|---|---|
| **Q12** telemetry | `POWERSHELL_TELEMETRY_OPTOUT=1` beside `POWERSHELL_UPDATECHECK=Off`, in the profile.d hand-off and in `environment.d` | hook 0050 asks the handed-off PowerShell for both (`OS7_UPDATECHECK=Off OS7_TELEMETRY=1`); a login shell on the bench reads `1/Off` |
| **Q9** `sudo` | `$PSHOME/profile.ps1` in `os7-powershell`: a `sudo` function and `ConvertTo-OS7SudoCommand`, which decides; an interactive root session titles its window `Administrator: PowerShell` | a module exporting `sudo` does NOT win — PowerShell searches PATH before it autoloads (so the profile, which Microsoft's tarball does not ship); `$args` carries `-Name` and `'-Name'` as the same string and evaluated values (so session variables work elevated); `check-sudo.py` 13 cases + 3 planted defects |
| **Q7** desktop first | `os7-shell@os7` in `os7-desktop-theme`, enabled by the defaults, its shell-version checked by hook 0090 and `check-image.py` | the well-known start-up trick was ACTIVE, error-free and did nothing — GNOME 50 enables user extensions after start-up, with the overview already shown (BUILD-NOTES #174); the shipped version hides it on the first enable of a session — once the overview has finished opening, since §9 (#177) |
| **Q16** languages | `language-pack-{de,en,fr,nl,it,es}` and `language-pack-gnome-*` in the desktop package list — all six in the image, not only the one screen 3 names (C16 says why) | 98 MiB installed for all six; apt installs exactly the 24 packages, nothing else, with or without Recommends |

**On the bench** (`qol3`, the Block A medium, these files put in place and the
language packs installed from the pinned snapshot): the login screen reads
`Passwort` and `Do, 29. Okt`; the first screen after login is the DESKTOP, its
panel `Anwendungen` / `Orte`; `sudo Get-OS7Version` in GNOME Terminal asked
`[sudo: authenticate] Passwort:` and printed the version; `sudo pwsh` titled the
window and its taskbar button `Administrator: PowerShell`, and `exit` put
`Terminal` back; programs, the `| sudo tee` idiom and pipeline refusals behaved
as P13 says.

**The checks fire on the medium without them:** `check-image.py amd64` against
`OS7-1.0.0.245-amd64.iso` — **18 problems**, the fifteen of §2 and §6 and the
three new ones (telemetry: `<not set anywhere>`; the extension: `MISSING
metadata.json; MISSING extension.js`, `not in enabled-extensions`; the
languages: every one of the twelve `-base` packages lacking), every other check
green.

**The first build of this round failed, and not on anything this round
changed:** hook 0090 reported `org.gnome.desktop.interface` as having no
`accent-color`, a check that had passed three builds running. It was a race in
how that check had been written since #54 — `gsettings list-keys | grep -q`
under `pipefail`, 4 false negatives in 2000 on the bench — and #83 had exempted
exactly that producer as safe. BUILD-NOTES #175; the hook reads the answer whole
now, and passed on the bench before the build was started again.

## 9. A fresh install of the decisions — and what it found

`OS7-1.0.0.247-amd64.iso` (this round's tree, development-signed), installed on
bench `qol4` with `os7lab.py install --mode Gui`, nothing put in place by hand.
`check-image.py amd64` on the medium: every check of §6 and §8 green, the five
known development-medium failures and nothing else.

**What held, read off the installed machine:** the greeter in German
(`Nicht aufgeführt?`, `Do, 29. Okt`), all 24 language packs installed and
`de_DE.utf8` generated — the packs generate their languages' other locales too,
`de_AT` to `nl_NL`; the desktop session's user manager
carries `POWERSHELL_UPDATECHECK=Off POWERSHELL_TELEMETRY_OPTOUT=1`;
`$PSHOME/profile.ps1` present; `os7-shell@os7` and the window list both
`ACTIVE` in a `gnome-shell --mode=classic` session; Ubuntu's four update and
advertisement units masked; `APT::Periodic::Unattended-Upgrade "0"`; `/etc/legal`
OS/7's; `update-manager` the OS/7 shim; sysprof not installed;
`Get-OS7Version` 1.0.0.247.

**What it found — three things, one of them in the product's update path.**

**#176, the language packs translated two words something was reading.** The
bench's own `login` waited for `Password:` and the serial line said
`Passwort:`: Ubuntu ships main's translations in the language packs, so until
C16 a German machine had the German locale (#170) and English messages. The
harness pattern now covers both (`vmconsole.PASSWORD_PROMPT`). The same cause
reached `Set-OS7UpdateChannel`: its read-back keys on apt's `Get:`/`Hit:`, which
in German are `Holen:`/`OK:`, and on this machine it answered `unfetched` for a
source apt had just fetched — `fetched` under `LC_ALL=C.UTF-8`, a second later.
Fixed by asking apt in C, and proven both ways: `check-update-logic.py`'s fake
apt now speaks German when the locale says so, and the new case was **red on the
old code and green on the fix** (70 checks); the fixed function on the bench
answers `fetched` in the German session. The sweep that says this is not the
only site: all 114 Get-/Test- verbs run twice in one pwsh, German and C, differ
only in measurements; the three message matches against tool output are safe
for measured reasons (BUILD-NOTES #176).

**C17 had three roads open.** The profile.d and environment.d files reach a
login shell and the desktop; `ssh host command` (the bench's `exec` left
`telemetry.uuid` behind — pwsh writes it only with telemetry on, measured both
ways), `sudo` (an exported value arrives empty) and services (six OS/7 units run
pwsh) were not covered. Now: a `system.conf.d` drop-in for services (a unit sees
`1` after daemon-reload, nothing without the file) and two lines in
`/etc/environment` for every PAM session (an ssh command's pwsh and a sudo'd one
both see `1` and write no `telemetry.uuid`). One trap in the instrument:
**`telemetry.uuid` is not written at all when `$HOME` is unset**, so for a
service its absence proves nothing — the variable reaching the unit is what was
measured there.

**#177, os7-shell could leave a desktop that took no input.** The first
graphical login on the fresh install opened on the desktop, as Q7 wants, and
then ignored every key and click; the window list never appeared; opening and
closing the overview over D-Bus brought it back. The extension closed the
overview from `enable()`, and `enable()` runs inside the overview's start-up
animation more often than not (logged: `SHOWING` 12 of 19, `SHOWN` 7). The
shipped code: **2 dead in 22 logins**, both after a `hide()` from `SHOWING`,
never caught with the probe in it — the mechanism is GNOME 50's
`overview.js`, read off the machine, not the failure measured. The fix waits for
the overview's `shown` and hides from there: **9 of 9 logins took input**,
three of them first logins of a restored install, and every `hide()` came from
`SHOWN`. Hook 0090 now requires the private state the fix reads.

**And the medium carrying all three fixes**, rebuilt from this tree (still
1.0.0.247, development-signed): hook 0090 `ok: the Shell's overview still has
the state os7-shell@os7 waits on (libshell-18.so)`; `check-image.py` the five
known development-medium failures and nothing else, both new C17 checks green
(systemd's merged `system.conf` carries both variables; `/etc/environment` both
lines beside its `PATH`). Installed fresh as bench `qol5`: the serial login
went through `Passwort:` with the new pattern; an ssh command's environment,
a sudo'd shell and a `systemd-run` unit all see `POWERSHELL_TELEMETRY_OPTOUT=1`
at first boot, and the ssh command's pwsh left no `telemetry.uuid`; the
shipped module's apt read-back answers `fetched` in the German session; and the
first graphical login, with the shipped (uninstrumented) extension, opened on
the desktop with `OverviewActive false`, took Ctrl+Alt+T, drew the window
list, and `sudo pwsh` asked `[sudo: authenticate] Passwort:` and titled the
window `Administrator: PowerShell`.
