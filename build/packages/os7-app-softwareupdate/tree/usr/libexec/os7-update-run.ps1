#!/usr/bin/env pwsh
<#
.SYNOPSIS
	What os7-update@<version>.service runs. Internal.

.DESCRIPTION
	docs/GUI-APPS-PLAN.md G5. The Software Update window never runs as root and
	never asks for a password: it asks systemd to start this unit, polkit decides
	whether that is allowed, and the operator authenticates in polkit's own
	dialog.

	THIS FILE EXISTS SO THE UNIT DOES NOT HAVE TO QUOTE. Putting the update
	command inline in ExecStart= means a version string crossing systemd's `%i`
	substitution, a shell-free but still literal expansion, and PowerShell's own
	parsing — three layers, each with its own escaping rules, for a value that
	arrives from outside. A -File invocation binds it as a PARAMETER instead, and
	the validation below is the only place the shape is decided.

	`\z`, NOT `$`. In .NET — and therefore in PowerShell — `$` matches at the end
	of the string AND immediately before a trailing newline, so `^[0-9.]+$`
	accepts "1.0.0.204`n". The GUI's own guard was written with `$` and its
	self-test caught it the first time it ran (BUILD-NOTES #151). The same
	mistake here would put a newline into a unit name and then into this
	parameter.

	IT DOES NOT TRUST ITS CALLER. The window validates the version before it
	starts the unit, and this validates it again, because `systemctl start
	os7-update@anything.service` is a command an administrator can type.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidatePattern('^[0-9]{1,6}(\.[0-9]{1,6}){0,3}\z')]
	[string]$Version
)

$ErrorActionPreference = 'Stop'

Import-Module OS7

# -Confirm:$false because Update-OS7 is ConfirmImpact='High' and nothing here
# can answer a prompt: this runs under systemd with no terminal. The operator
# already confirmed, twice — once by pressing the button and once in polkit.
Update-OS7 -Version $Version -Confirm:$false
