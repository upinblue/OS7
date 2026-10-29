# OS/7 - the profile every PowerShell on this machine loads ($PSHOME/profile.ps1,
# "AllUsersAllHosts"). POWERSHELL-SURFACE-PLAN P13, owner's decision 2026-10-29.
#
# ONE JOB: `sudo` takes a PowerShell command. An operator told by #148's refusal
# that Update-OS7 needs root types `sudo Update-OS7` and got
#     sudo: 'Update-OS7': command not found
# because every verb on this product is a PowerShell FUNCTION and sudo resolves
# executables. The refusal names the `sudo pwsh -c '...'` form, which is right
# and is one more thing to learn on a product whose promise is that a Windows
# administrator already knows how to drive it.
#
# WHY THE PROFILE AND NOT THE OS7 MODULE. Measured on an install from
# OS7-1.0.0.247-amd64.iso: a function called `sudo` exported by a module that is
# not yet loaded does NOT win - `Get-Command sudo` answers Application
# /usr/bin/sudo, because PowerShell searches PATH before it autoloads. So the
# function has to exist when the session starts, and this file is what every
# pwsh not given -NoProfile reads first. Microsoft's tarball ships no
# profile.ps1, so os7-powershell owns this path outright.
#
# KEPT SMALL AND SIDE-EFFECT FREE. It runs at the start of every pwsh without
# -NoProfile, interactive or not: it imports nothing, starts no process, and
# only defines two functions and - in an interactive root session - sets the
# window title.

function ConvertTo-OS7SudoCommand {
	<#
	.SYNOPSIS
		Internal. Decides what `sudo <arguments>` means. Pure: no process.

	.DESCRIPTION
		Returns Kind 'Passthrough' (hand every argument to /usr/bin/sudo
		untouched), 'PowerShell' (Command is a statement for an elevated pwsh)
		or 'Refused' (Reason says why, and names the form that works).

		Separate from `sudo` so installer/testing/check-sudo.py can ask it
		every case without a sudo, a password or a Linux host.

		ONE LIMIT, MEASURED: a function receives a typed `-Name` and a quoted
		'-Name' as the same string, so a VALUE that begins with a dash is passed
		on as a parameter name. `sudo pwsh -c '...'` is the way around it.
	#>
	param([object[]]$ArgumentList)

	if (-not $ArgumentList -or $ArgumentList.Count -eq 0) {
		return [pscustomobject]@{ Kind = 'Passthrough'; Command = $null; Reason = $null }
	}
	$first = $ArgumentList[0]
	# sudo's own options (-i, -u, -E, ...) and anything that is not a name:
	# those are sudo's business, unchanged.
	if ($first -isnot [string] -or $first.StartsWith('-')) {
		return [pscustomobject]@{ Kind = 'Passthrough'; Command = $null; Reason = $null }
	}

	$found = Get-Command -Name $first -ErrorAction Ignore | Select-Object -First 1
	if ($found -and $found.CommandType -eq 'Alias') { $found = $found.ResolvedCommand }
	# Not found, or a program: exactly what sudo did before this file existed.
	if (-not $found -or $found.CommandType -notin @('Function', 'Cmdlet', 'Filter', 'ExternalScript')) {
		return [pscustomobject]@{ Kind = 'Passthrough'; Command = $null; Reason = $null }
	}

	$render = {
		param($Value)
		if ($null -eq $Value) { return '$null' }
		if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }
		if ($Value -is [System.Management.Automation.SwitchParameter]) {
			return $(if ($Value.IsPresent) { '$true' } else { '$false' })
		}
		if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
			return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
		}
		if ($Value -is [string]) { return "'" + $Value.Replace("'", "''") + "'" }
		if ($Value -is [array]) {
			$items = foreach ($item in $Value) { & $render $item }
			if (@($items) -contains $null) { return $null }
			return '@(' + (@($items) -join ', ') + ')'
		}
		return $null
	}

	$parts = [System.Collections.Generic.List[string]]::new()
	$parts.Add('& ' + (& $render $first))
	$refusedType = $null
	for ($i = 1; $i -lt $ArgumentList.Count; $i++) {
		$a = $ArgumentList[$i]
		if ($a -is [string] -and $a -match '^-[A-Za-z_][\w-]*:$' -and $i + 1 -lt $ArgumentList.Count) {
			$v = & $render $ArgumentList[$i + 1]
			if ($null -eq $v) { $refusedType = $ArgumentList[$i + 1].GetType().FullName; break }
			$parts.Add($a + $v)
			$i++
			continue
		}
		if ($a -is [string] -and $a -match '^-[A-Za-z_][\w-]*$') {
			$parts.Add($a)
			continue
		}
		$v = & $render $a
		if ($null -eq $v) { $refusedType = $a.GetType().FullName; break }
		$parts.Add($v)
	}
	if ($refusedType) {
		return [pscustomobject]@{
			Kind    = 'Refused'
			Command = $null
			Reason  = ("sudo cannot hand an object of type $refusedType to an elevated " +
				"PowerShell - only text, numbers, `$true/`$false and lists of them cross " +
				"into another process. Run it there instead: sudo pwsh -c '...'")
		}
	}
	return [pscustomobject]@{ Kind = 'PowerShell'; Command = ($parts -join ' '); Reason = $null }
}

function sudo {
	<#
	.SYNOPSIS
		sudo, for programs and for PowerShell commands. POWERSHELL-SURFACE-PLAN P13.

	.DESCRIPTION
		`sudo Update-OS7 -AllowDevelopment` runs Update-OS7 in an elevated
		PowerShell, with the arguments as this session evaluated them - so
		`sudo Remove-OS7BootEnvironment $name` works. `sudo apt update` is
		exactly what it always was: anything that is not a PowerShell command,
		and every sudo option, goes to /usr/bin/sudo untouched.

		What comes back from an elevated PowerShell is its output as TEXT, the
		same as from any program run under sudo; objects do not cross the
		process boundary, and neither does pipeline input into a PowerShell
		command.
	#>
	$program = if ($env:OS7_SUDO_PROGRAM) { $env:OS7_SUDO_PROGRAM } else { '/usr/bin/sudo' }
	$decision = ConvertTo-OS7SudoCommand -ArgumentList $args

	switch ($decision.Kind) {
		'Passthrough' {
			if ($MyInvocation.ExpectingInput) { $input | & $program @args }
			else { & $program @args }
		}
		'PowerShell' {
			if ($MyInvocation.ExpectingInput) {
				Write-Error ("sudo cannot pipe objects into an elevated PowerShell. Run the " +
					"whole pipeline there instead: sudo pwsh -c '...'")
				return
			}
			& $program ([System.Environment]::ProcessPath) -NoLogo -NoProfile -Command $decision.Command
		}
		default { Write-Error $decision.Reason }
	}
}

# THE WINDOW SAYS WHEN IT IS ELEVATED, where Windows says it: the title. The
# effective uid comes from /proc/self/status, the way Assert-OS7Elevated asks -
# no process, and not confused by an account that happens to be called root.
# Only for a session somebody is looking at: a redirected pwsh writing a title
# escape into a file or a journal would be a defect.
if ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
	try {
		$os7Uid = (Get-Content -LiteralPath /proc/self/status -ErrorAction Stop |
			Where-Object { $_ -like 'Uid:*' } | Select-Object -First 1) -split '\s+'
		if ($os7Uid.Count -ge 3 -and $os7Uid[2] -eq '0') {
			$Host.UI.RawUI.WindowTitle = 'Administrator: PowerShell'
		}
	}
	catch { }
	Remove-Variable -Name os7Uid -ErrorAction Ignore
}
