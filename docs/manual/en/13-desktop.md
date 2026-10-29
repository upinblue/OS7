# 13 The desktop

The desktop belongs to the **amd64** edition of OS/7; there is none on arm64,
because Microsoft ships no desktop stack there. It is chosen during
installation (screen 8, "Desktop").

## 13.1 What is on it

![The desktop with the start menu open: the classic appearance, and what is installed.](images/desktop-01-desktop.png)

Technically it is GNOME. Appearance and behaviour are brought onto the classic
Windows pattern: a bar at the bottom, a start menu on the left, a notification
area on the right, square windows with visible frames.

![The file manager.](images/desktop-03-files.png)

**Microsoft Edge** ships as the default browser, along with the **Intune
Company Portal**:

![Microsoft Edge, on a machine where it has not been started before.](images/desktop-04-edge.png)

![The Intune Company Portal.](images/desktop-05-intune.png)

## 13.2 The two OS/7 applications

Two applications on the desktop are OS/7's own. Both are front ends over
cmdlets this manual already describes, and neither adds a rule of its own:

| Application | Where it is | What it is for | Described in |
|---|---|---|---|
| **Software Update** | Apps → System Tools | install a new release | 6.5 |
| **Versions** | right click a file in Files → *Versions* | look at and restore previous versions of a file | 12.8 |

![Software Update: the releases the channel offers.](images/app-software-update.png)

![Versions: the history of one file.](images/app-versions.png)

Software Update has a start-menu entry and Versions deliberately does not:
Versions is a question about *one file* and is given a path, so the way in is
the file manager. Both are English, as the whole application family is in this
release.

Their windows are drawn by the same design system — square bevelled frames, the
Windows 2000 palette, a title bar Mutter draws from the desktop theme — and the
palette is one table shared with the desktop's own CSS rather than a second set
of colours that could drift.

Neither holds administrator rights. Software Update asks polkit and lets systemd
run `Update-OS7` as root; Versions runs entirely as the person using it, which
is why a restore it performs keeps the replaced file by renaming it rather than
by taking a snapshot (12.8).

## 13.3 The terminal window

A terminal window on the desktop lands in **PowerShell**, exactly like the
console and an interactive SSH login:

![A terminal window on the desktop: PowerShell, as everywhere else.](images/desktop-02-terminal.png)

That is arranged explicitly and is not automatic. A terminal emulator normally
starts the shell **not** as a login shell, and the file that holds the hand-off
to PowerShell is read only by login shells. On OS/7 the terminal's default
profile is therefore set to "run as a login shell" — so the same hand-off runs
as everywhere else.

## 13.4 Switching the appearance

```powershell
Get-OS7Theme
Set-OS7Theme -Name Classic     # the classic OS/7 appearance
Set-OS7Theme -Name Stock       # untouched GNOME
```

The switch applies to the **current session** and takes full effect at the next
sign-in.

`Stock` is not merely decorative: when a problem appears on the desktop,
switching to `Stock` separates "is it the appearance" from "is it GNOME" — and
on a rendering problem that is the first useful bisection.

## 13.5 The sign-in screen and the console

The sign-in screen is branded too. It reads its settings from a **different**
database than the signed-in session — anyone changing something there changes
it in two places or in none.

The text console uses a different font from the installer: the installer shows
Fixedsys, the installed console **Cascadia Mono**. That is deliberate — Setup
should look like an installer from that era, the installed machine like a
working tool of today.

## 13.6 What is not different on the desktop

Everything in this manual. The two applications in 13.2 are windows onto
cmdlets and not a second set of rules: an update started from Software Update is
the same `Update-OS7`, and a version restored from Versions is the same
`Restore-OS7File`, with the same safety rule and the same refusals. Everything
else — boot environments, network, backup, the directory — has no window at all
and is driven on a desktop machine with the same commands as on a server.
