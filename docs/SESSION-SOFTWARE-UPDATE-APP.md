# Session — Software Update, the first OS/7 GUI application

**2026-09-14, x64 Windows host.** The toolkit decision
([GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) G1) was made and measured
([SESSION-AVALONIA-FOOTPRINT.md](SESSION-AVALONIA-FOOTPRINT.md)) earlier the
same day. This built the first application against it.

**NO WINDOW HAS BEEN DRAWN.** Everything below is source, packaging and checks
that run with no display. The application compiles, its decisions are exercised,
its package builds and installs' worth of files land in the right places — and
whether it *looks* like anything is unknown. O-G1, O-G3 and O-G5 are exactly as
owed as they were this morning. That is the honest summary and §6 does not
soften it.

---

## 1. What was built

| Path | What |
|---|---|
| `src/OS7.Ui/` | The design system: 17 colour tokens, the metrics, `BevelBorder`, and control themes for Button, CheckBox, ListBox, ListBoxItem, ProgressBar, ScrollBar and Thumb |
| `src/OS7.App.SoftwareUpdate/` | The application: model, view model, two services, one window, and `--self-test` |
| `build/packages/os7-app-softwareupdate/` | The package: `os7-update@.service`, the polkit rule, `os7-update-run.ps1`, the desktop entry |
| `build/lib/build-os7-packages.sh` | `build_os7_app_softwareupdate`, and the package joins `ALL` |
| `installer/testing/check-gui-tokens.py` | G9 — one palette, checked against the theme package |
| `installer/testing/check-gui-logic.py` | G3 — the layer rule, and the application's own self-test |

Measured on this host:

```
dotnet build                         0 warnings, 0 errors
os7-software-update --self-test      46 ok, 0 failed
check-gui-tokens.py                  all ok  (17 tokens agree, value for value)
check-gui-tokens.py --self-test      3 ok    (three planted defects caught)
check-gui-logic.py --docker …        all ok  (layer rule + the 46)
check-gui-logic.py --self-test       2 ok    (two planted defects caught)
build-os7-packages.sh …              os7-app-softwareupdate_…_amd64.deb, 7 317 036 bytes,
                                     7 required paths present
```

The `.deb` is 7.0 MiB compressed from the 22.1 MiB published tree.

---

## 2. What the building measured, and what it corrected

### 2a. #151 — `$` is not end-of-string in .NET, and both guards had it

The self-test's first run went red on one case out of forty-six:

```
      FAIL  '1.0.0.204\n' is refused, not escaped
```

`^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$` accepts a trailing newline, because .NET's `$`
matches at end-of-input *and* immediately before a final newline. The value was
on its way into `os7-update@%i.service`.

Both guards had it — the C# one and the `[ValidatePattern]` in the unit's own
script — because both were written from the same wrong idea in the same hour.
**Two independent-looking checks written by one author on one afternoon are one
check.** Fixed with `\z` in both. [BUILD-NOTES #151](BUILD-NOTES.md).

The note's first draft claimed the same trap was live across this repository's
PowerShell. That was checked and is **too strong**: `[ValidatePattern]` appears
nowhere else in `powershell/`, and the anchored patterns that do exist parse
lines already split out of command output, where the behaviour is harmless. The
note now says so.

### 2b. Both checks were wrong before they were right, in the same way

`check-gui-tokens.py` went red on its first run, on two "colour literals":

```
UpdateRunner.cs:76   #151          ← a BUILD-NOTES reference
Os7Theme.axaml:41    #808080       ← a comment explaining GRAYTEXT is 3DSHADOW
```

`check-gui-logic.py` went red on its first run, on one "forbidden program":

```
ReleaseRow.cs:127    sudo          ← the message telling the operator to run
                                     sudo pwsh -c 'Update-OS7 … -AllowDevelopment'
```

All three are the same mistake in the checker: **naming a thing is not doing
it**, and a repository that writes its reasoning into its code will trip any
rule that cannot tell the two apart. The fixes are both about the *action*:
comments are blanked before scanning (preserving line numbers), and the
forbidden-program scan applies only to files that can actually invoke something
— a set computed from the source rather than listed, and sound because a
separate rule holds that only `Os7Cli.cs` may start a process.

The third one is worth keeping in mind as a product fact rather than a checker
fact: had the rule stood, the fix would have been *to stop telling operators the
command that works*. A check that makes the product worse to stay green is a
check that gets switched off.

### 2c. The theme already styles this application's title bar

G8a says Mutter draws the frame. Reading the theme package to confirm that was
plausible turned up better than plausible — `gtk.css` has:

```css
/* Mutter draws server-side decorations for X11/Xwayland clients from these. */
decoration { border-radius: 0; … background-color: @os7_face; }
```

An Avalonia 12.1.2 application is an X11 client under XWayland (M-G12), so it is
exactly the client that block is about. G8a costs nothing, and O-G3 narrows to
"does it actually look right", which still needs a machine.

---

## 3. Decisions taken while building, which the plan did not settle

### 3a. Open question 3 is answered: systemd plus polkit, and no new IPC

`os7-update@<version>.service` runs
`pwsh -File /usr/libexec/os7-update-run.ps1 -Version %i`. The window asks
systemd to start it; polkit governs that and prompts in its own dialog; the
window follows the unit's journal.

Three things fall out, and the third is the one that made it the right answer:

- **`Update-OS7` gains no code.** A cmdlet `run-s5.py`'s gate covers is not
  touched, so nothing here owes that gate a re-run.
- **No D-Bus library, no local HTTP service, nothing written.** systemd, polkit
  and journald are already on the machine.
- **The privilege escalation and the progress reporting are the same problem**,
  and this solves both at once. Solving them separately is how a dialog ends up
  with an indeterminate spinner and no cancel.

It goes through `Start-SystemdUnit` in `powershell/Systemd/` rather than calling
`systemctl`, which is what keeps G12's layer rule true. That cmdlet has no
elevation guard and runs `systemctl start` with no `sudo`, so polkit is reached
identically — checked in the source before relying on it.

### 3b. The window does not offer `-AllowDevelopment`

`Development` is **not** part of the cmdlet's `Applicable` — that is
`newer AND same-major AND on-base AND not-foreign`, and provenance is not in it.
`Update-OS7` refuses a development release separately.

So a release can be `Applicable` and still not installable from the window, and
a window that read `Applicable` as "there is a button" would offer one that dies
in a systemd unit with the reason in a journal. v1 lists such a release, does
not let it be ticked, and prints the command that would work:

> Not signed for production (the descriptor names no key). To install it anyway,
> run `sudo pwsh -c 'Update-OS7 -Version 1.0.0.206 -AllowDevelopment'`.

The switch exists, in the cmdlet's own words, so that an operator says out loud
that they are installing something of unknown provenance. **A checkbox in a
window is not that sentence.**

### 3c. One release is pre-ticked, not all of them

The window this is modelled on arrived with everything ticked. Here an update is
a boot environment and a restart, so the default is the newest installable
release and nothing else.

### 3d. The restart notice is shown before installing, not after

An operator deciding whether to start a ten-minute update needs to know it ends
in a restart *before* they press the button.

### 3e. Size is summed in the application, and that is a seam

`OS7.Release` has no size. The descriptor states one per component, so the
window adds them up. It is arithmetic over a stated field rather than a
judgement — but it is a number this application produces and no cmdlet does, and
if "download size" ever stops meaning "all components" this is where it will be
wrong alone. A `DownloadSize` property on `OS7.Release` is the better home and
is **owed**.

---

## 4. Deliberately not built

- **No channel switching.** `Set-OS7UpdateChannel` changes which train a machine
  is on; that is a bigger decision than this window's subject.
- **No rollback.** Boot environments are System Restore's application.
- **No scheduling.** The unattended check is a systemd timer
  ([RELEASE-AND-UPDATE-PLAN.md](RELEASE-AND-UPDATE-PLAN.md) §6). "Not Now"
  closes the window and writes nothing — a window quietly disabling a fleet's
  update schedule would be a policy change made by one click.
- **No localisation.** GL8: v1 is English, matching the cmdlets. No string is
  hard-coded into XAML, so the retrofit is a retrofit and not a rewrite.
- **No shared `os7-ui` package.** C14's 13.3 MiB saving needs a second
  application to be a saving at all. `OS7.Ui` is a project reference for now,
  and the `additionalProbingPaths` mechanism that would split it is **unmeasured
  (O-G8)**.

---

## 4a. THE MACHINE RUN, 2026-09-14 — and the two defects it found

**The window has now been drawn**, on the `gui` bench (amd64, KVM in a
container), an OS/7 1.0.0.163 GUI machine. The package was built at that
machine's exact version — its `Depends` are versioned `(= @OS7_VERSION@)` — and
installed with `apt-get install`.

**Say which machine, because it matters (#93).** This is a long-lived bench that
has carried AD and RDP work for five days, not a machine off an ISO. It answers
*"does the window come up and what does it look like"*, which is what it was
asked. It does not answer *"does the package reach an image"* — that is the ISO
half, below.

### What went right

| | |
|---|---|
| The menu entry | `Software Update` appears under **System Tools**, with its icon, after `gnome-menus` and `desktop-file-utils` triggers ran |
| The window | Draws. `#d4d0c8` face, bevelled buttons, the default button's black ring on *Install*, the sunken white list pane, a taskbar entry |
| **G8a, confirmed on a machine** | **Mutter draws the title bar and the theme styles it** — the Windows 2000 caption gradient is there, on a window `os7-ui` never painted. O-G3's "which side draws" half is answered |
| **M-G12, confirmed on a machine** | `XDG_SESSION_TYPE=wayland`, `Xwayland :0` running, and the application reached X11 through it. The prediction from the assembly list is now a measurement |
| polkit | `polkitd` 127 restarts clean with the rule installed — a malformed rules file is logged, and nothing was |
| The unit | `systemctl cat os7-update@1.0.0.999.service` resolves; `LoadState=loaded` |

### #152 — the window did not come up at all, the first time

Clicking the menu entry closed the menu and left the desktop empty. No dialog,
no message. The journal had `NullReferenceException at MainWindow..ctor()`.

The cause: this code-behind wrote its own `InitializeComponent()`. Avalonia
**generates** that method, and the generated one both loads the XAML *and*
assigns every `x:Name`'d control to its field. The hand-written one did the
first half, compiled without a warning, and left `CloseButton` and
`InstallButton` null.

**Three instruments were green while this was true**: the build, the 46-check
`--self-test` (it exercises view models and constructs no window), and
`check-gui-logic.py` (it reads for layer violations and this is not one). Each
was correct about what it measures. None of them measures *does the window come
up*. [BUILD-NOTES #152](BUILD-NOTES.md).

Fixed by deleting the method, and **held**: `check-gui-logic.py` §2 now requires
that no `.axaml.cs` defines its own `InitializeComponent`, and its `--self-test`
plants that exact defect and requires the rule to go red.

### The ANSI escapes, which no check in this repository could have seen

With the window up, the first thing it said to an operator was:

```
This machine could not be asked about updates.
 [31;1mOperationStopped:  [0m/usr/local/share/powershell/…/OS7.Update.ps1:417 [0m
```

PowerShell colours its error records **even with nothing attached to a
terminal**, so the SGR sequences arrived inside the message and were drawn as
literal text. Invisible to every check here, because not one of them starts a
`pwsh`.

Fixed twice over: `$PSStyle.OutputRendering = 'PlainText'` is prefixed to every
script (the real fix, PowerShell 7.2+), and an ANSI strip in `Clean()` as a belt,
because this application runs whatever `pwsh` is on PATH and the pin is not the
only possible version.

**The error itself was correct and useful** — the bench's channel points at
`file:///usr/lib/os7/repo`, which has no index, and the cmdlet said exactly that
and named `Set-OS7UpdateChannel`. That is the *Failed* phase of §3's four
window states, drawn correctly on a machine, which is worth as much as the happy
one.

A second, smaller thing the same screenshot showed: a fifteen-line error pushed
the release list off the bottom of the window. The second line is now capped and
scrolls.

### The window said "up to date" with a newer release listed beneath it

With the bench pointed at a served repository offering **1.0.0.164** against its
own 1.0.0.163, the window drew this:

> **Your software is up to date.**
> The channel offers releases, but none can be installed on this machine.

Both sentences were produced by rules written that morning, and together they are
a contradiction an operator would be right to distrust. 1.0.0.164 is newer,
applicable, and blocked here only because the bench repository is signed with the
**development** key (§3b). `InstallableCount` was 0, and the header was keyed on
that alone.

**"Nothing newer exists" and "something newer exists that this machine will not
install" are two different facts**, and the cmdlet one layer down already insists
on that distinction — it reports four separate reasons precisely because
"'not applicable' for four different reasons is four different conversations with
the operator". The window collapsed them back into one.

Fixed with `AnythingNewer`, and the header now has three states rather than two:

> **New software exists, but none of it can be installed on this computer.**
> Each release below says why. Nothing here changes this machine.

Five self-test cases hold it, including the bench's own case verbatim. The
self-test went from 46 to 51, and one of the 46 had been asserting the wrong
sentence.

### O-G6 — the polkit path, proven end to end

From a terminal in the desktop session, as `uid=1000 os7admin`, through
`Start-SystemdUnit` — the same call `UpdateRunner.cs` makes:

| step | what happened |
|---|---|
| 1 | polkit put up **Authentication Required — "Authentication is required to start 'os7-update@1.0.0.164.service'"**, naming the exact unit |
| 2 | the password was accepted in polkit's own dialog; this application never sees one |
| 3 | systemd started the unit as root and ran `/usr/libexec/os7-update-run.ps1 -Version 1.0.0.164` |
| 4 | `Update-OS7` refused **in preflight, before touching the disk**: *"1.0.0.164 is signed by a DEVELOPMENT key (17C46067…), which means it is not a published release. Pass -AllowDevelopment to apply it anyway."* |
| 5 | `status=1/FAILURE`, the reason in the unit's journal — which is where the window reads progress from |

**That is the whole of G5, on a machine.** And it closes the loop on G3 in a way
no static check could: the sentence the window shows in its detail pane and the
sentence the cmdlet writes to the journal are the same refusal, for the same
reason, because there is only one implementation of it.

**One harness lesson, not a product one.** The first attempt failed with
`Method call timed out` — systemd's D-Bus call gives up after about 25 seconds
and the screenshot-then-type sequence was slower than that. The password then
went to the shell behind the dialog. Answer the prompt within a few seconds, or
the thing being measured has already ended.

### The medium carries it — asked of the ISO's own squashfs

`OS7-1.0.0.216-amd64.iso` was built on this host and asked directly, by mounting
its `casper/filesystem.squashfs` rather than by trusting a container image made
from it (#93):

```
Package: os7-app-softwareupdate
Status: install ok installed
Version: 1.0.0.216
Depends: dotnet-runtime-10.0, libfontconfig1, libx11-6, libice6, libsm6,
         polkitd, os7-module (= 1.0.0.216)
```

All seven files are there with the modes they were given — the binary `0755`,
`libSkiaSharp.so` `0644` — and `os7-desktop`'s own `Depends` names the package,
so C6's membership contract holds and a headless purge takes it with the
desktop.

`check-image.py amd64` is otherwise green on the medium; its **4 failures are all
the missing repository credential**, which is what `OS7_REPO_NO_CREDENTIAL=1`
means and which the build announced before it started. A bench medium, not a
publishable one.

**Two host notes, neither about the product.** `check-image.py` cannot run from
Windows Python on this tree any more — its docker probe exceeds the 32 KiB
command-line limit and dies in `CreateProcess` with `WinError 206`; from WSL it
runs. And with no architecture argument it picks the arm64 ISO and fails with
`exec format error`, which is #140's binfmt registration not surviving a Docker
Desktop restart, not a fault in the medium.

### The ISO build refused the package, and that was correct

The first two ISO builds failed in hook 0022 with

```
os7-app-softwareupdate : Depends: policykit-1 but it is not installable or
                                  polkit but it is not installable
```

`policykit-1` was a transitional package and is **gone** from Ubuntu 26.04;
`polkit` has never been a binary package name there. Measured on the machine:
`polkitd` 127-2ubuntu1 is what provides `/usr/lib/polkit-1/polkitd`, and
`policykit-1` has no candidate at all. The dependency was written from memory and
was wrong.

Worth recording for the opposite reason as well: **hook 0022 failed the build**
rather than producing a medium with the package quietly missing. That is #13's
rule doing its job — a hook that cannot do its work must not let the build
succeed.

### A product finding that is not a defect in this application

The System Tools menu now holds **`Software Update`** and **`Software Updater`**
side by side, with near-identical icons. The second is Ubuntu's own
`update-manager`, which knows nothing about the OS/7 update train, boot
environments or `Update-OS7`. An operator cannot tell them apart, and the wrong
one does the wrong thing quietly.

Not fixed here, because the fix is a curation decision rather than a code change
— hide `update-manager`'s desktop entry on an OS/7 image, rename it, or accept
it — and it belongs with C-decisions rather than in a window. **Recorded as owed.**

---

## 5. What is owed, in the order it costs

**Answered by this run:** O-G1 (the window draws), O-G3 (Mutter's frame, themed,
above an Avalonia window), O-G6 (polkit end to end) and the `XDG_SESSION_TYPE`
half of O-G2.

**Still owed:**

1. **The package is on a medium, but no machine has been INSTALLED from that
   medium.** `OS7-1.0.0.216-amd64.iso` carries it (above); what has not happened
   is `os7lab.py install --mode Gui` from that ISO and the window opened on the
   machine it produces. Everything visual above was `apt-get install` onto a
   five-day-old bench, and #93 is the reason that distinction is kept.
2. **No successful update has ever been performed from the window.** Every
   release the bench can reach is development-signed, and v1 refuses those from
   the GUI by design (§3b). So the *refusal* path is proven and the *success*
   path — install, progress from the journal, Finished, restart notice — is
   entirely unexercised. It needs a production-signed repository, which is C7a's
   open question wearing a different hat.
3. **O-G5 — startup time**, properly measured rather than eyeballed between
   screenshots.
4. **O-G4 — Orca against a real window.** `Avalonia.FreeDesktop.AtSpi.dll`
   ships; whether a screen reader reads a list, a checkbox and a progress bar
   usefully is a different question, and one the GUI bench can now answer.
5. **O-G2's remainder** — what XWayland costs in scaling and capture. The
   session is Wayland and the application is an X11 client; that it *works* is
   now measured, what it *costs* is not.
6. **O-G7 — the trimmed size**, and **O-G8 — `additionalProbingPaths`**.
7. **Real fixtures.** The self-test's releases are CONSTRUCTED from the shape
   `Get-OS7Release` emits. A recorded set is now cheap to capture — this bench
   has a signed repository in front of it — and would have caught the header
   defect before a machine did.
8. **The `Software Update` / `Software Updater` menu collision** (above). A
   curation decision, not a code change.
9. **The date column.** `Released` arrives from the cmdlet already formatted to
   the machine's culture — `Get-OS7Release` does `[string]` over a value
   `ConvertFrom-Json` has turned into a `DateTime` — and the column truncates it.
   Cosmetic, but it is the cmdlet's formatting leaking through a display rule,
   which is the kind of thing IDENTITY-PLAN would rather decide once.

---

## 6. The honest summary

**The experiment answered.** The window draws on an OS/7 machine, in OS/7's own
idiom, with Mutter's themed title bar above it; it lists real releases read from
a signed repository, with sizes, and says correctly why each one cannot be
installed; and the privileged path works end to end — polkit prompts naming the
unit, systemd runs the update as root, and `Update-OS7` refuses for its own
reason in its own words. The toolkit, the layer cut, the design system, the
packaging and the privilege mechanism all hold on a machine.

**Five defects were found, and where each was found is the point:**

| | found by | could the others have found it? |
|---|---|---|
| #151, `$` vs `\z` in a unit name | the app's `--self-test`, first run | no — a source grep cannot evaluate a regex |
| the wrong header when nothing installable is newer | **the machine** | no — no check knew what the sentence *should* say until a real repository made it wrong |
| #152, hand-written `InitializeComponent` | **the machine** | no — build green, self-test green, layer rule green. Now held by a grep |
| ANSI escapes drawn as text | **the machine** | no — nothing here starts a `pwsh` |
| `policykit-1` does not exist on 26.04 | **the ISO build** | no — and hook 0022 correctly refused rather than shipping it missing |

Three of the five were only reachable by running the thing. That is the argument
for the machine run, and it is also the argument against believing the next
application will be cheaper: the checks now cover the classes these taught, and
the next window will have classes of its own.

**What is still not true:** no machine has been *installed* from the medium that
carries the package — the ISO has it, and the window has only ever been opened on
a bench it was copied onto (§5.1). And the application has never performed a
successful update: every release the bench can reach is development-signed, which
v1 deliberately refuses from the GUI. The refusal path is proven; the success
path is not.
