# 13 The desktop

The desktop belongs to the **amd64** edition of OS/7; there is none on arm64,
because Microsoft ships no desktop stack there. It is chosen during
installation (screen 8, "GUI").

## 13.1 What is on it

![The OS/7 desktop in its classic appearance.](images/desktop-01b-desktop-no-overview.png)

Technically it is GNOME. Appearance and behaviour are brought onto the classic
Windows pattern: a bar at the bottom, a start menu on the left, a notification
area on the right, square windows with visible frames.

![The file manager.](images/desktop-03-desktop-files.png)

**Microsoft Edge** ships as the default browser, along with the **Intune
Company Portal**:

![Microsoft Edge.](images/desktop-04-desktop-edge.png)

![The Intune Company Portal.](images/desktop-05-desktop-intune.png)

## 13.2 The terminal window

A terminal window on the desktop lands in **PowerShell**, exactly like the
console and an interactive SSH login:

![A terminal window on the desktop: PowerShell, as everywhere else.](images/desktop-02b-desktop-terminal-version.png)

That is arranged explicitly and is not automatic. A terminal emulator normally
starts the shell **not** as a login shell, and the file that holds the hand-off
to PowerShell is read only by login shells. On OS/7 the terminal's default
profile is therefore set to "run as a login shell" — so the same hand-off runs
as everywhere else.

## 13.3 Switching the appearance

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

## 13.4 The sign-in screen and the console

The sign-in screen is branded too. It reads its settings from a **different**
database than the signed-in session — anyone changing something there changes
it in two places or in none.

The text console uses a different font from the installer: the installer shows
Fixedsys, the installed console **Cascadia Mono**. That is deliberate — Setup
should look like an installer from that era, the installed machine like a
working tool of today.

## 13.5 What is not different on the desktop

Everything in this manual. There is no graphical administration surface that
would open a second set of rules beside the cmdlets: boot environments,
updates, network, backup and the directory are driven on a desktop machine with
the same commands as on a server.
