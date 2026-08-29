# 1 Introduction

## 1.1 What OS/7 is

OS/7 is a Linux operating system built on **Ubuntu 26.04 LTS** for
administrators who come from the Microsoft world. It does not change what Linux
is — it changes what you drive it with and how you manage it.

Four decisions shape everything that follows:

**PowerShell is the interface.** Log in and you land in PowerShell, not `bash`.
The administrative commands are cmdlets with the familiar verb-noun names, and
they return **objects** rather than lines of text —
`Get-OS7Service -Detailed | ? { $_.Healthy -eq $false }` is a sensible line and
needs no `grep`, no `awk` and no assumption about column widths.

**Management goes through Microsoft's own tools.** Entra ID for sign-in, Intune
for device management, Azure Arc for inventory. Where a technical preference of
OS/7's collides with something those services require, the service wins — which
matters most for the disk layout, the encryption, and the names the machine
reports itself under.

**The filesystem is ZFS, and updates roll back.** An update never modifies the
running system. It makes a copy, changes the copy, and switches afterwards. If
something goes wrong, the way back is one command and a restart — not a restore
from backup.

**Setup is a text-mode installer styled after MS-DOS 6.22 and the Windows 2000
text phase.** That is not nostalgia: an installer that works on any serial
console and in any remote-management window is worth more on a server than one
that needs a graphics stack.

## 1.2 Who this manual is for

Administrators who run OS/7 machines. It assumes you are comfortable with
Windows Server and PowerShell. Linux knowledge helps but is nowhere assumed:
where a Linux concept is unavoidable — ZFS, systemd, netplan — the manual
explains it at the point where it is needed.

The manual is organised **by task**, not by module. If you want to know how an
update is rolled back, that is chapter 5, with everything that belongs to it.
The complete list of every command is **Appendix A**.

## 1.3 The two architectures

OS/7 exists for two processor architectures, and they are **not the same
product**:

| | **amd64** (x86-64) | **arm64** (AArch64) |
|---|---|---|
| Desktop | yes — GNOME in the classic appearance | no |
| Microsoft Edge | yes | no |
| Intune portal | yes | no |
| Server / headless | yes | yes |
| PowerShell, ZFS, boot environments, updates, network, time, directory | yes | yes |

The reason for the split is simple: Microsoft ships no desktop stack for arm64.
Everything OS/7 builds itself exists on both; everything that comes from
Microsoft exists where Microsoft ships it. Installing on amd64 you choose
between **GUI** and **Headless**; on arm64 the question does not arise.

## 1.4 How the system is put together

The commands in this manual come from six PowerShell modules. The split is not
cosmetic — it is the reason the commands behave alike:

![The six modules and the direction between them. The five generic modules each know one subsystem of the operating system and nothing about OS/7; the OS7 module is the product on top of them and holds every decision that is OS/7-specific.](images/diagram-layers-en.svg)

What that means in practice:

* **`Get-Zpool` works on any Ubuntu.** The generic modules are tools for their
  subsystem and nothing else. They know no boot environments, no releases and
  no policy.
* **`Get-OS7BootEnvironment` exists only here.** Anything with `OS7` in the
  name is product knowledge and rests on the layer below it.
* **The `OS7` prefix is canonical.** There is no `Get-Service`, there is
  `Get-OS7Service`. That is deliberate: the parameters of these cmdlets do not
  match those of the Windows cmdlets of the same name, and a command that takes
  the same name and understands a third of the parameters turns a copied script
  into one that half-works — which is worse than one that fails on its first
  line.

## 1.5 Two answers, never one

One pattern runs through the whole command surface and is unfamiliar at first
reading: **where there is a stored intent and a running reality, OS/7 reports
both, separately.**

`Get-OS7NetworkConfiguration` tells you what netplan says **and** what is
actually on the adapters. `Get-OS7Service` tells you what systemd thinks of the
unit **and** whether the service is genuinely well. The interesting machine is
the one where the two disagree — a merged field would hide exactly that
machine.

For the same reason every cmdlet asks the thing itself rather than trusting a
tool's report: `netplan apply` returns 0 for a configuration that brought
nothing up; `systemctl is-active` says `active` for a service in a restart
loop; `useradd -m` exits 0 and creates no home when the directory already
exists. An exit code is a diagnostic, not an answer.

## 1.6 Conventions in this manual

Input is shown in code blocks, exactly as it is typed:

```powershell
Get-OS7BootEnvironment | Format-Table Name, Active, Running
```

Screen illustrations show the console of a running OS/7 machine.

> **Elevation.** Nearly every changing cmdlet and many reading ones need
> administrative rights, because they touch ZFS, systemd or files under `/etc`.
> On OS/7 you start an elevated PowerShell for that:
> ```powershell
> sudo pwsh
> ```
> Every example in this manual assumes you are in such a session unless it says
> otherwise.
