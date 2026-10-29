# 6 Updates

An update on OS/7 is not a swap of packages in the running system. It is the
filling of a **new boot environment** beside the running one, followed by a
switch. While the update runs the machine is unchanged and usable; if something
goes wrong there is nothing to undo, because nothing was changed.

## 6.1 What a release is

OS/7 is not delivered as a stream of individual packages but as **curated
releases**. Each release is a complete bill of materials: a version, the Ubuntu
archive snapshot it was built against, and a version and a hash for every
component. Two machines on the same release hold the same packages, regardless
of when they were installed.

Releases come from a **signed repository**. The signature is verified not only
on download but on the index and on each release descriptor, before anything is
listed at all.

## 6.2 Setting the channel

A freshly installed machine has **no** update source configured. That is
deliberate: which source a machine uses, and how quickly it takes releases, is
an operational decision.

```powershell
Set-OS7UpdateChannel -Uri https://updates.example.com/os7 -Channel stable
```

Three channels:

| Channel | For |
|---|---|
| `stable` | normal operation |
| `preview` | validating a release before it is approved |
| `development` | development builds |

Turning the source off without forgetting it:

```powershell
Set-OS7UpdateChannel -Disable
```

## 6.3 Seeing what is on offer

```powershell
Get-OS7Release
```

![Get-OS7Release lists what this machine's channel offers.](images/40-get-release.png)

`-Available` shows only releases newer than the installed one. `-Channel` and
`-Source` query a different channel or source without changing the machine's
setting:

```powershell
Get-OS7Release -Available
Get-OS7Release -Channel preview -Source https://updates.example.com/os7
```

Before anything is listed the command verifies the index's signature and each
descriptor's hash. A release whose descriptor does not match its hash does not
appear — it is not listed with a warning.

## 6.4 Updating

```powershell
Update-OS7
```

This one needs an elevated session — see *Elevation* in chapter 1, including
why `sudo Update-OS7` is not the way to get one. Run as an ordinary user on
this release it fails with a message about `/run/os7-update.lock` being denied,
which is this cmdlet's way of saying it needs root.

With no parameters this takes the next release on the configured channel. What
then happens, in the order it happens:

![The steps of an update. The running environment is never modified.](images/diagram-update-en.svg)

The parameters that matter:

| Parameter | Effect |
|---|---|
| `-Version` | a specific release instead of the next one |
| `-Channel`, `-Source` | once, from a different channel or source |
| `-Stage` | fill the new environment but do **not** activate it |
| `-Reboot` | restart immediately after a successful update |
| `-Keep` | how many old boot environments survive |
| `-AllowDevelopment` | accept development builds too |

A typical maintenance-window sequence:

```powershell
Update-OS7 -Stage                 # during the day: fill, switch nothing
# … in the window:
Set-OS7BootEnvironment -Name os7_1.0.1.0_202609010200
Restart-Computer
```

Or in one go:

```powershell
Update-OS7 -Reboot -Keep 2
```

## 6.5 Software Update, the window

On a desktop machine the same update is available as a window: **Apps →
System Tools → Software Update**. It comes from the `os7-app-softwareupdate` package
and exists on amd64 GUI installations only — there is no desktop on arm64, and a
headless install removes the desktop.

![Software Update, with the releases the channel offers.](images/app-software-update.png)

The list is the releases the configured channel holds, newest first. For the
selected one the pane below names the full release time, the apt suite, the
Ubuntu archive snapshot it was built against, the key it was signed with and how
many first-boot migrations it carries — the same facts `Get-OS7Release` prints.

The heading is one of four sentences:

| Heading | What it means |
|---|---|
| *Your software is up to date.* | nothing newer is on the channel |
| *New software is available for your computer.* | at least one release can be installed here |
| *New software exists, but none of it can be installed on this computer.* | there are newer releases and every one of them is ruled out; each row says why |
| *This machine could not be asked about updates.* | the channel could not be read, and the line below carries the reason |

The third is a separate sentence from the first deliberately. "Nothing newer
exists" and "something newer exists that this machine will not take" send an
administrator to two different places.

A release that cannot be installed here still gets a row, with its checkbox
disabled and the reason in the pane: it was built for another architecture, it
is not newer than the running release, it is a hotfix for a release this machine
does not have — update to that one first — or it crosses a major version, which
is an installation and not an update.

**The window decides none of that.** Whether a release is applicable is read off
`Get-OS7Release` and never recomputed, so the window and the cmdlet cannot
disagree about the same release. The primary button counts what it will do —
it reads *Install 1 Item* with one release ticked — and starts
`os7-update@<version>.service`; polkit asks for an administrator password first,
naming what it is for, and systemd then runs `Update-OS7` as root. The
application never holds those rights itself. Everything in 6.4 applies, because
below the window it is the same code — including the restart, which the window
states before it starts anything.

**A release that is not signed for production is refused here**, and the row
says so with the key that signed it. The cmdlet is the only way to take one:

```powershell
sudo pwsh -c 'Update-OS7 -Version 1.0.0.246 -AllowDevelopment'
```

That is the sentence the row itself prints, with the version filled in. Until a
release is published under the production key, a machine offered one will show
it in the list and refuse to install it from there.

## 6.6 After the restart

On the first boot of the new environment the release's **first-boot
migrations** run. Those are the steps that can only be done on a running
machine — re-sealing the TPM key against the real boot chain, for instance.

Then check the result:

```powershell
Get-OS7Version
Get-OS7BootEnvironment | Format-Table Name, Active, Running, Menu, Release
Get-OS7Service -Detailed | ? { $_.Healthy -eq $false }
```

If something is wrong, one command goes back:

```powershell
Restore-OS7
```

## 6.7 Checking the decisions without updating

`Test-OS7Update` checks the update path's logic on this machine — with no
repository, no ZFS changes and no restart:

![Test-OS7Update checks the decisions of the update path on this machine.](images/41-test-update.png)

This is the command for "is this machine fundamentally in order" before you
start an update.

## 6.8 Checking unattended

OS/7 ships a timer that looks periodically for something new on the channel.

The timer is `os7-update-check.timer`, and it is a *scheduled task* — the same
distinction Windows makes between a service and a task in the Task Scheduler.
Chapter 9.5 has the whole surface; the one command that matters here:

```powershell
Get-OS7ScheduledTask os7-update-check.timer
```

![The unattended update check, as a scheduled task.](images/43-update-timer.png)

`NextRun` is the answer to "will this fleet stay current without anyone
typing anything": a date means yes, an empty field means the timer is not
armed — and `Healthy` says so.

The check has a fixed contract on its exit code, and that is what a monitoring
system evaluates:

| Exit code | Meaning |
|---|---|
| `0` | nothing to do — or no channel configured |
| `2` | an update has been staged and is waiting to be switched to |
| `1` | the check failed |

Turning it on and off:

```powershell
Enable-OS7ScheduledTask  os7-update-check.timer
Disable-OS7ScheduledTask os7-update-check.timer
```

## 6.9 What an update takes with it, and what it does not

The layout from chapter 3 decides, and it is worth repeating because it
explains the whole procedure:

**Rolls with it:** the system itself — `/`, `/usr`, `/etc`, the package
database under `/var/lib/dpkg` and `/var/lib/apt`, the package cache, the
kernel and the initramfs.

**Does not roll with it:** the home directories, `/var/log`, `/var/spool`,
`/var/tmp`, `/srv`, the services' data under `/var/lib/<service>`, and the
management agents' state.

The last of those is the most important and the least obvious. Entra, Intune
and Arc hold the other end of a device identity — enrolment records,
certificates that rotate on their own schedule, compliance state. The tenant
does not roll back. A machine that came back from a rollback presenting a stale
identity would be a tenant problem rather than a device problem — and therefore
invisible from the device. So that state lives outside the boot environment.
