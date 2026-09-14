# GUI applications — the OS/7 app family

**This file is authoritative for OS/7's own graphical applications: which toolkit they are written
in and why, what they are allowed to contain, how they reach a privilege they do not have, where
the design language lives, and how a family of them stays one product rather than five.**

**The toolkit and the look are decided. The mechanism is not.** *Decided 2026-09-14* by the owner:
**G1** (Avalonia, after the alternatives were put side by side and the footprint was measured rather
than estimated — §2), **G2** (framework-dependent), **G8** (the classic idiom, not the pixel grid)
and **G8a** (the window manager draws the title bar). Everything else — G3–G7 and G9–G12 — is
*Proposed 2026-09-14*. Decisions are G1–G12 with G8a, limitations GL1–GL9. A measurement still owed
is `O-G1…`, so the prefix tells "measured" from "owed".

**The first application is BUILT, and it HAS been seen** (2026-09-14).
`src/OS7.Ui/` and `src/OS7.App.SoftwareUpdate/` are in the tree,
`os7-app-softwareupdate` builds as a 7.0 MiB `.deb`, and the checks are green —
`os7-software-update --self-test` (51), `check-gui-tokens.py`, `check-gui-logic.py`, each proven to
go red against a planted defect.

**On an amd64 GUI machine the window draws, in OS/7's own idiom, with Mutter's themed title bar
above it; it lists real releases from a signed repository with their sizes and says why each cannot
be installed; and the privileged path works end to end — polkit prompts naming the unit, systemd
runs the update as root, `Update-OS7` refuses in its own words.** O-G1, O-G3 and O-G6 are answered.
What is NOT done is the delivery half: no ISO has yet carried the package, and no successful update
has ever been performed from the window, because every release the bench can reach is
development-signed and v1 refuses those by design.

G3–G7 and G9–G12 stay *Proposed* until §10's remaining measurements are in.
[SESSION-SOFTWARE-UPDATE-APP.md](SESSION-SOFTWARE-UPDATE-APP.md) has the whole run, and the part
worth reading twice is which instrument found which of the five defects: **three of the five were
reachable only by running it** — a hand-written `InitializeComponent` that left every control null
with three green checks (BUILD-NOTES #152), PowerShell's ANSI colour codes drawn as literal text,
and a header that said "up to date" with a newer release listed beneath it.

It exists because of a question with a picture attached — *"can we build a Software Update app, the
way old macOS had one?"* — and because the answer to that question is only worth having if it also
answers the next four apps.

Related authority: [DECISIONS.md](DECISIONS.md) (GUI is amd64-only; arm64 is server-only; Intune
outranks preference); [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) C2 (the runtime
stays) and C3 (the Foundation Framework, which this is the first consumer of);
[POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) P2 (a subsystem gets a generic layer,
policy sits above it) and P12 (this file's layer cut, recorded there);
[RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §4.2 and
[CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) §9 (C10) for what the first app is a
front-end to; [BUILD-NOTES.md](BUILD-NOTES.md) #66, #84, #85, #110, #111, #148, #149; and
[SESSION-CLASSIC-DESKTOP.md](SESSION-CLASSIC-DESKTOP.md) for the desktop these windows open on.

---

## 1. Verdict

**OS/7 writes its own applications in Avalonia, framework-dependent against the .NET runtime the
image already carries, and they contain no policy of their own — every one of them is a front-end
over cmdlets that already exist and already have a test.**

The toolkit argument is short and it is already written down in this repository. OS/7's desktop
theme concedes, in its own header, that GTK 4 cannot be given this product's face
([`os7-classic.css`](../build/packages/os7-desktop-theme/tree/usr/share/os7-theme/gtk-4.0/os7-classic.css)):

> libadwaita ignores `gtk-theme-name` by design. There is no supported way to give a GTK 4
> application a classic widget shape, and every project that has tried has produced a broken UI on
> the next libadwaita release.

That concession is correct and it is about *Ubuntu's* applications, which OS/7 does not write. For
applications OS/7 *does* write, accepting it would be a choice rather than a constraint — and the
choice would be to build the product's most visible components in the one toolkit whose maintainers
have said the product's design language is out of scope. Avalonia draws its own widgets onto Skia
and does not use GTK at all, so the concession does not apply to them. That is the whole of the
argument; the .NET runtime already being on the image (C2) and the team already writing C#
(`os7-setup`) are what make it cheap, not what make it right.

**What this is not:** it is not a decision to build a desktop environment, not a decision to replace
any GNOME application, and not a decision that anything becomes GUI-only. G7 is the counterweight
and it is not negotiable — arm64 has no desktop at all, and a feature that can only be reached by
clicking does not exist on half the product.

---

## 2. What was measured, and what was not

**Measured before deciding:**

| # | Fact | How |
|---|---|---|
| M-G1 | libadwaita will not take a classic widget shape; the OS/7 theme ships colour-only for GTK 4 and says so | [`os7-classic.css`](../build/packages/os7-desktop-theme/tree/usr/share/os7-theme/gtk-4.0/os7-classic.css) header, and the GTK 3 / GTK 4 split in the same package |
| M-G2 | The .NET runtime is already on every OS/7 image, both architectures | `dotnet-runtime-10.0` + `aspnetcore-runtime-10.0` in [`os7-base.list.chroot`](../build/config/package-lists/os7-base.list.chroot); C2 records 79 MiB + 26 MiB Installed-Size |
| M-G3 | C3 expects a first-party consumer for that runtime and names it `os7-foundation` | [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) §4.1, C3 |
| M-G4 | `Update-OS7` and `Get-OS7Release` already emit typed objects, so a front-end needs no new API | `[OutputType('OS7.Update')]`, `[OutputType('OS7.Release')]` in [`OS7.Update.ps1`](../powershell/OS7/OS7.Update.ps1) |
| M-G5 | A changing cmdlet refuses politely without root and names the `sudo pwsh -c` form | `Assert-OS7Elevated`, #148/#149, `installer/testing/check-privilege.py` |
| M-G6 | The classic palette already exists as constants in two files and would be a third | `#d4d0c8`, `#0a246a`, `#808080`, the 82-step caption gradient — `gtk-3.0/gtk.css` and `gtk-4.0/os7-classic.css` |

**Measured while writing this file** — see §2a, filled in from
[SESSION-AVALONIA-FOOTPRINT.md](SESSION-AVALONIA-FOOTPRINT.md).

**NOT measured, and each one can still change a decision below:**

- ~~**O-G1 — no OS/7 machine has displayed an Avalonia window.**~~ **ANSWERED 2026-09-14.** The
  Software Update window draws on an amd64 GUI machine: `#d4d0c8` face, bevelled buttons, the
  default button's black ring, the sunken list, the navy selection, a taskbar entry, and the menu
  entry under System Tools. It took two attempts — the first died in its own constructor
  (BUILD-NOTES #152).
- **O-G2 — how XWayland behaves here.** *Answered in part by M-G12:* it is X11 under a Wayland
  compositor, not a native Wayland client. What that costs in scaling, capture and shortcuts is
  still unmeasured (GL4).
- ~~**O-G3 — window decorations.**~~ **ANSWERED 2026-09-14.** Mutter draws the frame and the theme
  styles it: the Windows 2000 caption gradient sits above a window `os7-ui` never painted, with
  square caption buttons. G8a costs nothing, exactly as the theme package's `decoration` block
  predicted.
- **O-G4 — whether a screen reader reads these windows.** *Narrowed by M-G13:* the AT-SPI component
  ships, so the question is no longer whether the mechanism exists but whether Orca reads a list, a
  checkbox and a progress bar usefully. Answerable on the GUI bench (GL5).
- **O-G7 — the trimmed size.** 22.1 MiB is untrimmed, and about 1.2 MiB of it is visibly for other
  operating systems (`Avalonia.Win32.dll`, `Avalonia.Native.dll`).
- ~~**O-G6 — the polkit path, end to end.**~~ **ANSWERED 2026-09-14, on a machine.** As `uid=1000`
  in a desktop session, through `Start-SystemdUnit`: polkit put up *"Authentication is required to
  start 'os7-update@1.0.0.164.service'"* naming the exact unit, accepted the password in its own
  dialog, systemd ran the unit as root, and `Update-OS7` refused in preflight because the release is
  development-signed — its sentence, in the journal, identical to the one the window shows. G5
  holds. (The first attempt hit `Method call timed out`: systemd's D-Bus call gives up after ~25 s,
  so the prompt has to be answered promptly — a harness lesson, not a product one.)
- **O-G9 — a successful update from the window.** New, and the largest gap left. Every release this
  bench can reach is development-signed, which v1 refuses from the GUI by design (§4, G10). So the
  refusal path is proven and the *success* path — install, journal progress, Finished, the restart
  notice — has never run. It needs a production-signed repository, which is C7a.
- ~~**O-G10 — the package on an ISO.**~~ **ANSWERED 2026-09-14.** `OS7-1.0.0.216-amd64.iso` carries
  `os7-app-softwareupdate` — `install ok installed`, all seven files at the right modes, and named
  in `os7-desktop`'s own `Depends` so C6's membership holds — asked of the medium's own squashfs
  rather than of a container made from it (#93). It took four attempts: two failed correctly on a
  `policykit-1` dependency that does not exist on 26.04 (hook 0022 refusing rather than shipping it
  missing), one on an upstream HTTP 504 fetching the PowerShell tarball.
- **O-G8 — `additionalProbingPaths`.** The mechanism that would let `os7-ui` carry the 13.3 MiB
  native payload once for the whole family (C14) is unmeasured, because a family of one does not
  need it yet.
- **O-G5 — startup time.** A framework-dependent .NET application on a cold page cache against a
  GTK application that the session has already paged in. If "Software Update" takes four seconds to
  draw, that is the whole impression of the product.
- **O-G6 — what a privileged helper costs.** No polkit action exists in this repository yet; the
  RemoteDesktop work only ever *read* other people's (§5).

## 2a. The footprint, measured

**2026-09-14, in `os7-build:amd64`, with the package version left floating so the feed would say what
current is rather than this file asserting it.** Full transcript and commands:
[SESSION-AVALONIA-FOOTPRINT.md](SESSION-AVALONIA-FOOTPRINT.md).

| # | Fact | Value |
|---|---|---|
| M-G7 | What the feed resolved to | `Avalonia` **12.1.2**, `SkiaSharp` 3.119.4 |
| M-G8 | One application, framework-dependent | **22.1 MiB** |
| M-G9 | The same application, self-contained (control) | **100.8 MiB** |
| M-G10 | Of that 22.1, the native payload identical in every app | **13.3 MiB** (`libSkiaSharp.so` 10.65, `libHarfBuzzSharp.so` 2.68) |
| M-G11 | Managed remainder, per application | 8.8 MiB |
| M-G12 | Avalonia 12.1.2 has **no Wayland backend** — `Avalonia.X11.dll`, no Wayland assembly | X11, therefore XWayland under GNOME 50 |
| M-G13 | AT-SPI accessibility **does** ship | `Avalonia.FreeDesktop.AtSpi.dll`, 0.54 MiB |
| M-G14 | `libSkiaSharp.so` needs `libfontconfig.so.1`, which `os7-build` lacks and the desktop image has | present on `os7img:175` (indicative only — #93) |

Three of those change decisions below, and they are worth reading as a set:

- **G2 now has a number: 78.7 MiB per application, 472 MiB across a family of six.** The runtime C2
  kept costs 105 MiB once; paying for it again per application exceeds that on the second one.
- **G9 and G11 stop being a design preference and become arithmetic.** Six applications each
  publishing everything is 132.6 MiB; `os7-ui` carrying the native payload once is **66.1 MiB**. The
  shared package was proposed so five windows could not drift into five different greys. It is also
  where 13.3 MiB of identical native code belongs. "Each application is its own package" (G11) must
  not be read as "each application is its own copy".
- **GL4 and GL5 were both written from memory and both were wrong in direction.** XWayland is a
  fact, not a risk; accessibility exists as a component rather than being absent. Both are rewritten
  below.

---

## 3. Why Avalonia, and what was refused

Four candidates were put side by side. The refusals are recorded because the next person to ask
"why not just GTK" deserves the answer without re-deriving it.

| Candidate | Refused because |
|---|---|
| **GTK 4 + libadwaita** | The product's own theme package documents that the classic widget shape is unreachable and that trying breaks on libadwaita upgrades (M-G1). It would also mean a third language in the tree, and it inherits #84 — GNOME 50 will not draw 1-bit text, which is the product's typographic idiom in the text phase. |
| **GTK 3** | Themeable, and #84 measured that GTK 3 renders the classic face correctly where GTK 4 does not. Refused on lifetime: starting a new application family on a toolkit in maintenance buys a rewrite inside this product's first LTS generation. |
| **Qt 6 / QML** | The strongest alternative, and refused on cost rather than merit. QML is a better styling system than XAML for this job. But it is a new toolchain, a new language, and ~100 MB of Qt on an image that curates hard (C-decisions), for a product whose team already writes C# and whose image already carries a .NET runtime it was told to expect a consumer for. |
| **Tauri / Electron** | A second browser engine beside Edge, a Rust toolchain, and a privilege story that gets worse rather than better. The design-system argument is real — CSS tokens could be shared with the website — and it does not outweigh the rest. |
| **PowerShell itself** | Named only to rule it out, because it is the intuitive guess on a product like this one. WinForms and WPF are Windows-only; PowerShell has no GUI toolkit on Linux. |

### G1 — The toolkit is Avalonia. Decided 2026-09-14.

Every OS/7-authored graphical application is an Avalonia application targeting the .NET version the
pin names. No OS/7 application is written in GTK, Qt, or a webview.

This does not apply to anything OS/7 does not write. GNOME's applications stay GNOME's, wear the
theme's colours, and keep their modern shape — that limitation is stated in the theme package and is
unchanged by this file.

### G2 — Framework-dependent, not NativeAOT per application. Decided 2026-09-14.

`os7-setup` is NativeAOT because it must run with .NET deleted, in an installer environment
(spike S2). An application on an installed machine has no such constraint: the runtime is on the
image, C2 paid for it, and C3 said a consumer was coming. Publishing each of six or seven
applications self-contained would pay for that runtime again per application.

The trade is recorded rather than assumed: §2a has both numbers.

---

## 4. The layer cut — what a GUI application may contain

### G3 — A GUI application implements no policy. Proposed 2026-09-14.

**An OS/7 application decides nothing that a cmdlet does not already decide.** It arranges, it
labels, it asks for confirmation, and it reports. Every judgement — which release is newer, whether
a driver regressed, whether a backup is healthy, whether an adapter came up — is made by the
PowerShell surface and read by the application.

This is the repository's most expensive lesson pointed at a new surface. `Update-OS7` is §4.2 as C10
corrects it: the clone, the assembly, both repositories, the metapackage, the migrations, the
initramfs, the menu, the driver gate, the activation, the pruning. A C# re-implementation would be a
*third* language for one specification — BUILD-NOTES #66's exact shape (the installer's TPM step
paraphrasing a spike that worked, and taking a different route), and the shape P3 is currently
spending two steps deleting from the netplan renderer. The failure mode of a second implementation
is not that it is wrong; it is that it is *nearly* right, and diverges silently under maintenance.

The rule has a check attached (G12). Without one it is a paragraph, and this repository has measured
what paragraphs are worth: P2-time was written in capitals in a file header while the code under it
called `chronyc makestep`.

### G4 — The wire format is JSON, from the cmdlets' own objects. Proposed 2026-09-14.

The application invokes `pwsh -NoProfile -NonInteractive -Command` and reads `ConvertTo-Json` off
stdout. It does not screen-scrape formatted output, and it does not define its own DTOs beyond what
deserialises from those objects.

**PowerShell is not hosted in-process, and that is a measurement rather than a preference.** The
`pwsh` on an OS/7 image is the self-contained upstream tarball hook 0020 installs — Microsoft ships
no arm64 `.deb` — not a referencable library. Taking `Microsoft.PowerShell.SDK` as a NuGet
dependency would put a *second* PowerShell inside every application, at a version the pin does not
name, which is the same class of defect as #93: two things that look like the product and are not
the product.

### G5 — A GUI application never runs as root, and never asks the user to. Proposed 2026-09-14.

The application runs in the user's session. Work requiring root goes to a privileged helper behind a
polkit action, and the user authenticates in polkit's own dialog. `pkexec pwsh` spawning a whole
shell as root from a GUI is not acceptable as the shipping mechanism.

Three things fall out of this and the third is the one that matters:

1. #148's guard is the *backstop*, not the mechanism. An application that reaches
   `Assert-OS7Elevated`'s refusal has already failed to route correctly.
2. The helper owns the lock. `/run/os7-update.lock` is held by one thing, so the helper is where
   "an update is already running" is answered — including for a second GUI instance and for an
   operator at a console.
3. **A long operation needs progress, and a blocking `pwsh` call cannot give it one.** An update
   takes minutes. This is the real reason the helper is a *service* with a channel and not a
   `pkexec` invocation: the shape of the privilege escalation and the shape of the progress
   reporting are the same problem, and solving them separately produces a dialog with an
   indeterminate spinner and no cancel.

The mechanism is unbuilt and its shape is open (§12, open question 3). `aspnetcore-runtime` being on
the image (C2) means a local HTTP channel is available without a new dependency, which is noted as
an option rather than chosen.

### G6 — Reading is not privileged, and the split is by cmdlet, not by application. Proposed 2026-09-14.

`Get-OS7Release`, `Get-OS7Device`, `Get-OS7BackupStatus` and their kind run as the user and need no
helper. Only the changing verbs cross the boundary. So an application draws its whole window,
truthfully, before any authentication happens, and the polkit prompt appears at the moment the
operator presses the button that changes something — which is also the only moment it can be
honestly explained.

### G7 — Every application has a cmdlet that does the same job, and the cmdlet is authoritative. Proposed 2026-09-14.

No capability is GUI-only. arm64 is server-only and amd64 installs headless by operator choice, so a
GUI-only feature would be absent from most of the product. Since G3 makes the application a
front-end anyway, this costs nothing to hold and is worth stating because it is the kind of thing
that erodes one convenience at a time.

The direction is one-way: a cmdlet may exist with no application. An application may not exist with
no cmdlet.

---

## 5. The design system

### G8 — The apps take their information architecture from the reference, and their shell from OS/7 Classic. Proposed 2026-09-14.

The Apple Software Update window that prompted this work is a good model for the *problem*: a
checkbox list of available items, a version and size column, a detail pane describing the selected
item, an explicit restart notice, and a primary button that counts what it will do ("Install 5
Items"). That architecture is adopted.

Its *chrome* is not. [DECISIONS.md](DECISIONS.md) fixes the desktop as Windows 2000 "Windows
Standard", the text phase is deliberately period (D5/D9), and an Aqua-styled window on that desktop
would read as an unfinished port rather than a quotation. The applications are drawn in the classic
idiom the theme already defines.

**How literal "classic" is, is decided: the idiom, not the pixel grid.** Owner's call, 2026-09-14.
The palette, the greys, the bevelled relief and the flat rectangular shapes are Windows 2000's. The
*metrics* are not: row heights, hit targets and internal padding are sized for a machine somebody
uses today, not for an 800×600 CRT. Pixel-exact reproduction was considered and refused — it would
make the applications unmistakably OS/7's, and it buys that with small click targets on a stack
where scaling already goes through XWayland (M-G12).

This puts OS/7's own applications between GNOME's (modern shape, classic colour, by the theme's
stated concession) and the text phase (period-exact by D5/D9). That is a known cost of the choice
and is recorded so nobody later reads it as drift.

### G8a — The window manager draws the title bar. Decided 2026-09-14.

Server-side decorations. Mutter draws the frame, the OS/7 Classic theme colours it, and an OS/7
application looks like every other window on the desktop in the window list, in Alt-Tab and under
tiling.

The alternative — the application drawing its own caption with the measured 82-step gradient — was
refused because it buys internal consistency by making OS/7's own windows the odd ones on the
desktop, and because moving, maximising, snapping and multi-monitor behaviour would all become
`os7-ui`'s to get right.

**This narrows O-G3 rather than closing it.** The question is no longer which side draws; it is
whether Mutter's frame under OS7-Classic actually looks correct above an Avalonia window, which
needs a window on a machine.

### G9 — The design system is a package, and its tokens have exactly one source. Proposed 2026-09-14.

`os7-ui` is an Avalonia library carrying the control themes, the palette, the typography and the
shared layout primitives. Every application references it and defines no colour of its own.

The palette already exists twice — in `gtk-3.0/gtk.css` and `gtk-4.0/os7-classic.css`, deliberately,
as "the same constants as gtk-3.0/gtk.css". `os7-ui` must not become the third hand-maintained copy.
One file is the source and the others are generated or checked against it; which direction is open
(§12, open question 2).

This is the netplan two-language renderer arriving in a new place, recognised early rather than
late. The failure it produces is not a crash — it is five applications that are almost the same
grey.

### G10 — What the applications deliberately do not do. Proposed 2026-09-14.

- **No application is a general shell.** No terminal, no "run arbitrary command" field. That is what
  PowerShell is, and it is one click away.
- **No application polls.** A window that is not doing anything makes no calls.
- **No application writes to a system path directly.** Every change goes through a cmdlet (G3),
  which is also what makes the change appear in that cmdlet's log rather than nowhere.
- **No application carries its own update mechanism.** They ship in the image and move with the
  release train like everything else.

---

## 6. The family

The order is a proposal; only the first is being built.

| Application | Cmdlets behind it | Why it earns a window |
|---|---|---|
| **Software Update** | `Get-OS7Release -Available`, `Update-OS7`, `Get-OS7Version`, later `Set-OS7UpdateChannel` | The first one. Small, bounded, and the one operation whose progress an operator genuinely wants to watch. (**Not** `Test-OS7Update` — that is the module's own self-test, not "is an update available". Written into this table wrongly once already.) |
| **System Restore** (boot environments) | `Get-/New-/Set-/Remove-OS7BootEnvironment`, `Restore-OS7` | The product's most distinctive capability, and the one for which a Windows administrator has no mental model — which is exactly when a picture is worth more than a cmdlet. |
| **Device Manager** | `Get-OS7Device`, `Repair-OS7Driver` | P10 already designed it as a Windows administrator expects it: what is wrong, not what is there. |
| **Backup** | `Get-OS7BackupStatus`, `Get-OS7BackupCoverage`, the policy verbs | Status at a glance is the whole job; B-5's gate is unrun, so this waits. |
| **Network** | `Get-/Set-OS7NetworkAdapter`, `Test-OS7Network` | Needs `Set-`'s rollback behaviour (`RollbackFailed`) represented honestly, which is a design problem worth having once. |
| **Scheduled Tasks** | the `*-OS7ScheduledTask` family | P9 is already shaped like the Windows tool. |

Identity and domain join are deliberately absent from v1: the installer's screen 9D has never drawn
on a machine, and a GUI over an unexercised path would be the second consumer of something with no
first one.

### G11 — Each application is its own package. Proposed 2026-09-14.

`os7-app-<name>`, depending on `os7-ui`, built from `build/packages/` like `os7-desktop-theme` and
the rest (C7). A headless machine installs none of them; the GUI metapackage pulls them in. This is
what makes "we shipped Software Update but not Backup" a fact about a package list rather than a
build flag.

**Its own package must not be read as its own copy.** M-G10 measured 13.3 MiB of native code that is
byte-identical in every application; `os7-ui` carries it once, and the family costs 66.1 MiB rather
than 132.6 MiB.

**And `os7-ui` declares its native dependencies itself.** `libSkiaSharp.so` needs
`libfontconfig.so.1`, plus the X11 libraries; on a GUI image those are present transitively behind
`ubuntu-desktop-minimal`, which is not the same as being depended on. The failure that produces is a
window that draws no letters, on the first path that does not come through the desktop metapackage.

### G12 — The rules above are checks, or they are decoration. Proposed 2026-09-14.

Three, in the shape `check-layering.py` established — a named baseline that may fall and may not
rise, and each violation named on every run:

- **G3** — no OS/7 application assembly calls a system path, `zfs`, `apt`, `systemctl` or
  `Invoke-*Command` directly; it calls the PowerShell surface.
- **G9** — no application defines a colour literal; every brush resolves to an `os7-ui` token, and
  the token file agrees with the theme package's constants.
- **G7** — every operation an application offers maps to an exported cmdlet that exists, with
  parameters it has. `check-installer-cmdlets.py` already does exactly this for `os7-setup` and
  found #108 while six other checks were green; this is that check pointed at a second caller.

---

## 7. Limitations — the honest list

- **GL1 — amd64 GUI only.** arm64 is server-only, and an amd64 headless install has no desktop.
  Most OS/7 machines will never run one of these.
- **GL2 — an application can do nothing the cmdlets cannot.** By G3 this is deliberate, and it means
  a GUI gap is fixed one layer down, which is slower and correct.
- **GL3 — Avalonia is not GTK, so it inherits none of GNOME's integration.** File choosers, portals,
  drag-and-drop between applications, and the session's own conventions are work rather than
  defaults.
- **GL4 — these run under XWayland, and that is measured (M-G12).** Avalonia 12.1.2 ships an X11
  backend and no Wayland one, while GNOME 50 is a Wayland session. It works; what it costs is not
  yet known. Fractional scaling is XWayland's rather than the compositor's, screen capture and
  global shortcuts behave differently, and anything reasoning about the display server sees X11 on a
  Wayland machine. O-G2 is no longer "whether" but "how badly".
- **GL5 — accessibility ships as a component, and that is not the same as working (M-G13).**
  `Avalonia.FreeDesktop.AtSpi.dll` is in the published output, so AT-SPI is not absent — this
  limitation said it was, written from memory before the measurement. What is unknown is whether
  Orca reads a list, a checkbox and a progress bar in one of these windows usefully. For
  public-sector procurement in the EU this has a standard number on it (EN 301 549), so it is a
  shipping question, and it is answerable on the GUI bench before the family grows past the first
  application (O-G4).
- **GL6 — every application is a second face for one capability**, and two faces can disagree. G3
  and G12 are what keep the disagreement to layout rather than behaviour.
- **GL7 — the theme's own limitation reaches these windows from outside.** Whatever Mutter draws
  around an application is not drawn by `os7-ui` (O-G3).
- **GL8 — v1 is English-only, and the manual is not.** Decided 2026-09-14, matching the cmdlets. The
  cost is named rather than deferred: `os7-setup` already localises, the administrator manual ships
  DE and EN, and a German operator will therefore meet a German manual describing an English window.
  Strings must not be hard-coded into XAML in the meantime — retrofitting them is the two-copies
  problem again, and this repository has paid for that twice (#66, P3).
- **GL9 — nothing here is built.** Every G from 3 onward is a proposal, and the first application is
  where they get tested against something real.

---

## 8. Open questions

1. ~~**How literal is "Windows 2000"?**~~ — **RESOLVED 2026-09-14: the idiom, not the pixel grid.**
   See G8.
2. **Where do the palette constants live, and which direction do they flow** — theme CSS to
   `os7-ui`, `os7-ui` to theme CSS, or both from a third file? Decides G9's check. **Still open, and
   now the most urgent of these**, because the first application is what creates the second copy.
3. ~~**What is the privileged helper?**~~ — **RESOLVED 2026-09-14 by building it: systemd plus
   polkit, and no new IPC.** `os7-update@<version>.service` runs
   `pwsh -File /usr/libexec/os7-update-run.ps1 -Version %i`; the application asks systemd to start
   it, polkit governs that and prompts in its own dialog, and progress is the unit's journal. No
   D-Bus library, no local HTTP service, and **no change to `Update-OS7`** — so nothing here owes
   `run-s5.py`'s gate a re-run. It reaches systemd through `Start-SystemdUnit` rather than
   `systemctl`, which is what keeps G12 true. The mechanism is **written and unexercised** (O-G6).
   [SESSION-SOFTWARE-UPDATE-APP.md](SESSION-SOFTWARE-UPDATE-APP.md) §3a.
4. ~~**DE and EN, or EN only for v1?**~~ — **RESOLVED 2026-09-14: EN only for v1**, matching the
   cmdlets. GL8 records what that costs and when it has to be paid.
5. ~~**One window or several?**~~ — **RESOLVED 2026-09-14: several, and no host shell.** Each
   application is its own menu entry, its own window and its own package (G11). There is
   deliberately no "OS/7 Control Panel" holding them: a shell would couple the applications'
   lifetimes to each other and give the family a front door that has to be maintained before there
   is anything behind it. If one is wanted later, it can be added over applications that already
   stand alone — the reverse is a rewrite.
6. **Does `os7-ui` live inside `os7-foundation` (C3) or beside it?** C3 is defined as "a .NET library
   and set of services" and has no content yet, so this is genuinely open.
7. **`Software Update` and `Software Updater` now sit side by side in the menu**, with near-identical
   icons. The second is Ubuntu's `update-manager`, which knows nothing about the OS/7 update train,
   boot environments or `Update-OS7`. Measured on a machine 2026-09-14. An operator cannot tell them
   apart and the wrong one does the wrong thing quietly. The fix is a curation decision — hide its
   desktop entry, rename it, or accept it — so it belongs with the C-decisions rather than in a
   window.

---

## 9. What this changes in the repository

| File | Change |
|---|---|
| [DECISIONS.md](DECISIONS.md) | **DONE 2026-09-14.** Locked decisions carries the toolkit; open question 11 carries what is still open |
| [CLAUDE.md](../CLAUDE.md) | **DONE 2026-09-14.** "Where authority lives" points here; the two checks are in the command list |
| [POWERSHELL-SURFACE-PLAN.md](POWERSHELL-SURFACE-PLAN.md) | **DONE 2026-09-14.** P12 — a GUI is a front-end; the layer cut sits beside P2 |
| [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) | **DONE 2026-09-14.** C14, proposed, with the measured sizes to argue from |
| [build/config/os7-release.conf](../build/config/os7-release.conf) | **NOT DONE, and deliberately.** C14 says Avalonia needs a version and a SHA256 in the pin. Until then the version lives once, in `src/Directory.Packages.props`, which says so at length. Editing the release definition belongs to the release that first carries the component |
| `src/OS7.Ui/`, `src/OS7.App.SoftwareUpdate/` | **DONE 2026-09-14** — the design system and the first application |
| `build/packages/os7-app-softwareupdate/` | **DONE 2026-09-14** — and it joins `ALL` in `build-os7-packages.sh` |
| `installer/testing/check-gui-tokens.py`, `check-gui-logic.py` | **DONE 2026-09-14**, G9 and G3. G12's third rule (every offered operation maps to a cmdlet that exists) is **not built** — `check-installer-cmdlets.py` is the template for it |
| `build/packages/os7-ui/` | Not built. C14's shared native payload needs a second application before it saves anything (O-G8) |

---

## 10. Measurements owed before locking

Nothing in G3–G12 may move from *Proposed* to *Decided* until the first application is on a machine
and these are answered: O-G1 (a window on this desktop), O-G2 (what XWayland costs), O-G3
(decorations), O-G4 (Orca against a real window), O-G5 (startup time), O-G6 (the helper), O-G7 (the
trimmed size).

The first application is therefore not only a feature. It is the experiment that decides whether the
other five are worth building, and it should be judged that way.
