# 2 Getting started

## 2.1 Logging in

An OS/7 machine without a desktop greets you at the console with a sign-in
prompt that names the machine's version. After you log in a greeting appears,
and then **a PowerShell prompt directly**.

![The console after logging in: /etc/issue names the version, the greeting follows, and the login lands in PowerShell — not at a bash prompt.](images/00-login.png)

That holds for all three ways onto the machine:

| Route | Where you land |
|---|---|
| Console (screen or serial line) | PowerShell |
| `ssh user@machine` (interactive) | PowerShell |
| `ssh user@machine 'command'` | **bash** |
| A terminal window on the desktop | PowerShell |

The third line matters and is deliberate. A non-interactive SSH invocation
stays in `bash`, because `scp`, `rsync`, `git` and every tool that fires a
command over SSH depends on it. Switching that path too would not produce a
PowerShell prompt — it would break every file transfer to the machine.

## 2.2 Which machine is this?

The first question on an unfamiliar machine:

```powershell
Get-OS7Version
```

![Get-OS7Version names the version. The output is an object, not a line of text.](images/10-get-os7version.png)

Every field the machine knows about itself — the commit it was built from, the
archive snapshot it was built against, the boot environment it is running out
of:

```powershell
Get-OS7Version | Format-List *
```

![All the version fields. They come from /usr/lib/os7/release.json, the same file Setup and the boot-menu entry read.](images/11-get-os7version-list.png)

### Two ways of writing a version

OS/7 shows a **person** three fields and a **machine** four:

| | Example | Where it appears |
|---|---|---|
| short | `1.0.0 (development)` | title row, `PRETTY_NAME`, `/etc/issue`, the greeting, `Get-OS7Version` |
| long | `1.0.0.159` | dataset names, `IMAGE_VERSION`, the ISO filename, `--version`, the boot menu, Setup's Complete screen |

This is a **display rule, not a second number**. Wherever two builds have to be
told apart, the long form appears; wherever a human reads, the short one.

### What the machine calls itself, and to whom

An OS/7 machine says **OS/7 where a person looks, and Ubuntu where software
looks.** Branded: `PRETTY_NAME`, `/etc/issue`, the greeting header and the GRUB
menu. Not branded: `NAME`, `ID`, `ID_LIKE`, `VERSION`, `VERSION_ID`,
`VERSION_CODENAME`, `/etc/lsb-release` and `uname`.

The reason is practical: Microsoft's onboarding script for Azure Arc reads
`NAME` and gives up if it does not contain `buntu`. Other tools read other
fields. So every branded surface reads a file of OS/7's own
(`/usr/lib/os7/product`) and none of the `os-release` fields.

## 2.3 Finding the commands

Every administrative command lives in six modules present on every OS/7
machine:

```powershell
Get-Module -ListAvailable OS7,Zfs,Net,Time,Systemd
```

![The modules as the machine reports them, with their paths and versions.](images/12-modules.png)

From here you work with PowerShell's own tools. Everything on one topic:

```powershell
Get-Command -Module OS7 -Noun OS7BootEnvironment
```

![Every command about boot environments, found through the noun.](images/13-be-commands.png)

Wildcards widen the topic:

```powershell
Get-Command -Module OS7 -Verb Get -Noun OS7B*
```

![The Get commands whose noun starts with OS7B: boot environments and backup.](images/14-verbs.png)

And onwards:

```powershell
Get-Command -Module OS7 -Noun *Backup*     # everything about backup
Get-Command -Module OS7 -Verb Set          # everything that changes something
Get-Help Update-OS7 -Full                  # the full help
Get-Help Restore-OS7 -Examples             # just the examples
```

The complete list of all 194 commands is **Appendix A**.

## 2.4 The naming rules

Knowing the rules means looking things up less often.

**A `Get-` never changes anything.** Without exception.

**A `Test-` answers a question and, on "no", says which part failed.**
`Test-OS7Network` does not merely report that an endpoint is unreachable; it
says which one, and at which step the chain broke.

**A `Set-` checks afterwards.** `Set-OS7NetworkAdapter` writes the
configuration, applies it, asks the kernel whether an address is actually
present — **and puts the old configuration back when it is not.**

**Destructive commands ask.** `Remove-OS7BootEnvironment`, `Remove-ZfsDataset`,
`Remove-Zpool` and `Restore-ZfsSnapshot` are classed as high-impact and require
confirmation. In a script you suppress it with `-Confirm:$false`, and then it
is a deliberate decision.

**Secrets are never strings.** Every cmdlet that takes one takes a
`[securestring]` or a `[pscredential]`. There is no parameter that accepts a
password in clear text, and none of these objects reaches an output that can be
serialised.

## 2.5 Where to start

On an unfamiliar machine these five commands give a complete picture in about a
minute:

```powershell
Get-OS7Version                  # which OS/7 is this
Get-OS7BootEnvironment          # what can it boot, what is running
Get-OS7Service -Detailed | ? { $_.Healthy -eq $false }   # what is not well
Test-OS7Network                 # can it get out, and to where
Get-OS7ManagementStatus         # is it managed, and if not, why not
```

Chapter 14 builds a complete diagnostic order out of these.
