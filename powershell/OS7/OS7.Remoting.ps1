# =============================================================================
# OS/7 — PowerShell over SSH
#
# TWO DIFFERENT THINGS LIVE UNDER THE WORD "REMOTING" AND THEY ARE NOT THE SAME
# MECHANISM. Getting them confused is why this file has a long header.
#
#   1. `ssh os7box`, interactively, landing in PowerShell.
#      That is /etc/profile.d/95-os7-powershell.sh (hook 0050) handing an
#      interactive LOGIN SHELL over to pwsh. It has worked since the image had
#      that drop-in, and it was MEASURED over a real sshd on 2026-08-27 rather
#      than assumed: an interactive session reaches `PS /home/os7admin>`, and
#      `ssh host 'command'` stays in bash — which is what keeps scp, sftp, git
#      and rsync working. `Get-OS7Remoting` reports it as `InteractiveShell`.
#
#      IT IS NOT A LOGIN-SHELL CHANGE, and must not become one. DECISIONS locks
#      bash as the system shell because cron, systemd units, dpkg maintainer
#      scripts and Intune's bash-based compliance scripts all assume it; pwsh is
#      deliberately not in /etc/shells. The drop-in gives the lived experience
#      without any of that breaking.
#
#   2. `Enter-PSSession -HostName os7box`.
#      That does not run a login shell at all. sshd starts a SUBSYSTEM directly,
#      and PowerShell 7.6 on this image has the client half already while the
#      server half was simply absent — `sshd -T` listed `sftp` and nothing else.
#      That is what `Enable-OS7Remoting` adds.
#
# NO GENERIC LAYER FOR THIS ONE, and P2's test is why rather than laziness: the
# split earns its keep where a subsystem has its own vocabulary AND the product
# has policy on top. sshd has plenty of vocabulary; OS/7 uses exactly one
# keyword of it. A module for one keyword would be P2 applied by reflex, which
# P2 forbids in the same paragraph.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

# The drop-in OS/7 owns. Never /etc/ssh/sshd_config: openssh owns that file, a
# package upgrade may replace it, and line 24 of it is already
# `Include /etc/ssh/sshd_config.d/*.conf` (measured).
$script:OS7SshDropIn = '/etc/ssh/sshd_config.d/60-os7-powershell.conf'
$script:OS7SshSubsystemLine = 'Subsystem powershell /usr/bin/pwsh -sshs -NoLogo'
$script:OS7PwshProfileDropIn = '/etc/profile.d/95-os7-powershell.sh'

function Get-OS7SshdEffectiveConfig {
	<#
	.SYNOPSIS
		Internal. What sshd itself says its configuration is.

	.DESCRIPTION
		`sshd -T` AND NOT A grep OF THE FILE. The file is one of several — line
		24 of sshd_config includes a whole directory — and a `Match` block can
		change the answer for some users and not others. Reading a file tells
		you what somebody wrote; `sshd -T` tells you what sshd resolved. That
		distinction is the same one `Get-OS7NetworkConfiguration` draws between
		configured and effective, and it is P6.
	#>
	$r = Invoke-OS7Native -Command '/usr/sbin/sshd' -Arguments @('-T')
	return @($r -split "`n")
}

function Get-OS7Remoting {
	<#
	.SYNOPSIS
		Whether this machine can be reached with PowerShell — both ways it can
		be meant.

	.DESCRIPTION
		Two fields, because they are two mechanisms:

		  InteractiveShell   `ssh os7box` lands in PowerShell. The
		                     /etc/profile.d drop-in, which is what actually does
		                     that (BUILD-NOTES #86).
		  Subsystem          `Enter-PSSession -HostName os7box` works. The sshd
		                     subsystem, asked of `sshd -T` rather than of a file.

		A machine can have either without the other, and an operator who cannot
		`Enter-PSSession` into a box they can `ssh` into needs to be told which
		of the two is missing.

	.EXAMPLE
		Get-OS7Remoting
	#>
	[CmdletBinding()]
	param()

	$subsystem = $null
	$sshdReason = $null
	try {
		$subsystem = @(Get-OS7SshdEffectiveConfig |
			Where-Object { $_ -match '^subsystem\s+powershell\s' })
	}
	catch {
		# `sshd -T` fails without host keys and needs root. That is "cannot
		# tell", not "not configured" — the rule this repository keeps
		# re-learning.
		$sshdReason = $_.Exception.Message
	}

	$profileDropIn = Test-Path -LiteralPath $script:OS7PwshProfileDropIn

	[pscustomobject]@{
		# $null, never $false, when sshd could not be asked.
		Subsystem        = if ($sshdReason) { $null } else { @($subsystem).Count -gt 0 }
		SubsystemLine    = if ($subsystem) { @($subsystem)[0] } else { $null }
		SubsystemReason  = $sshdReason
		DropInPath       = $script:OS7SshDropIn
		DropInPresent    = (Test-Path -LiteralPath $script:OS7SshDropIn)
		InteractiveShell = $profileDropIn
		InteractivePath  = $script:OS7PwshProfileDropIn
		# The bit an operator actually asks about, and it deliberately does NOT
		# collapse the two above into one boolean.
		Detail           = if ($sshdReason) { "sshd could not be asked: $sshdReason" }
		elseif (@($subsystem).Count -gt 0 -and $profileDropIn) {
			'ssh lands in PowerShell, and Enter-PSSession works'
		}
		elseif ($profileDropIn) {
			'ssh lands in PowerShell; Enter-PSSession needs Enable-OS7Remoting'
		}
		elseif (@($subsystem).Count -gt 0) {
			'Enter-PSSession works; an interactive ssh lands in bash'
		}
		else { 'neither: this machine answers ssh with bash and refuses Enter-PSSession' }
	}
}

function Enable-OS7Remoting {
	<#
	.SYNOPSIS
		Makes `Enter-PSSession -HostName` work against this machine.

	.DESCRIPTION
		Writes the subsystem drop-in and reloads sshd. It opens NO new port and
		adds no way in: the subsystem runs over the same authenticated ssh
		connection sftp already does, and it is subject to the same
		`AllowUsers`, keys and `Match` blocks. What it changes is what a session
		can ask for once it is already authenticated.

		IT VALIDATES BEFORE IT RELOADS. `sshd -t` parses the configuration; a
		reload with a broken drop-in is an sshd that fails to start, on a
		machine whose only route in is ssh. The file is removed again if the
		parse fails, and that is said out loud rather than reported as a tidy
		failure — the same shape as `Set-OS7NetworkAdapter`'s rollback and for
		the same reason.

		THE ANSWER COMES FROM `sshd -T` AFTERWARDS, not from the exit code of
		the reload.

	.EXAMPLE
		Enable-OS7Remoting
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param()

	if (-not $PSCmdlet.ShouldProcess('sshd', 'offer the PowerShell subsystem')) {
		return Get-OS7Remoting
	}

	$existed = Test-Path -LiteralPath $script:OS7SshDropIn
	$dir = [System.IO.Path]::GetDirectoryName($script:OS7SshDropIn)
	if (-not [System.IO.Directory]::Exists($dir)) {
		[void][System.IO.Directory]::CreateDirectory($dir)
	}
	[System.IO.File]::WriteAllLines($script:OS7SshDropIn, [string[]]@(
			'# Written by Enable-OS7Remoting. The subsystem PowerShell remoting speaks.',
			'# An interactive `ssh` landing in PowerShell is a DIFFERENT mechanism -',
			'# /etc/profile.d/95-os7-powershell.sh - and is not affected by this file.',
			$script:OS7SshSubsystemLine))

	# PARSE BEFORE RELOADING. A broken drop-in plus a reload is an sshd that
	# will not come back, on a machine reachable only by ssh.
	$parsed = $true
	$why = ''
	try { Invoke-OS7Native -Command '/usr/sbin/sshd' -Arguments @('-t') | Out-Null }
	catch { $parsed = $false; $why = $_.Exception.Message }

	if (-not $parsed) {
		if (-not $existed) { Remove-Item -Force -LiteralPath $script:OS7SshDropIn }
		throw [System.InvalidOperationException]::new(
			"sshd refused the configuration and nothing was reloaded: $why")
	}

	# Reload, not restart: a restart drops every session on the machine,
	# including the one running this cmdlet.
	# Through the Systemd module, not systemctl: P2-systemd. Reload and not
	# restart, because a restart drops every ssh session on the machine -
	# including the one running this cmdlet.
	try { Import-OS7SystemdLayer; Update-SystemdUnit -Name 'ssh' -Confirm:$false | Out-Null }
	catch {
		Write-OS7Step "reloading ssh failed: $($_.Exception.Message)"
	}

	Get-OS7Remoting
}

function Disable-OS7Remoting {
	<#
	.SYNOPSIS
		Stops offering the PowerShell subsystem.

	.DESCRIPTION
		Removes the drop-in and reloads. It does NOT touch
		/etc/profile.d/95-os7-powershell.sh, so `ssh os7box` still lands in
		PowerShell afterwards — those are two mechanisms and this cmdlet owns
		one of them. `Get-OS7Remoting` reports both separately for exactly this
		reason.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param()

	if (-not $PSCmdlet.ShouldProcess('sshd', 'stop offering the PowerShell subsystem')) {
		return Get-OS7Remoting
	}

	if (Test-Path -LiteralPath $script:OS7SshDropIn) {
		Remove-Item -Force -LiteralPath $script:OS7SshDropIn
	}
	# Through the Systemd module, not systemctl: P2-systemd. Reload and not
	# restart, because a restart drops every ssh session on the machine -
	# including the one running this cmdlet.
	try { Import-OS7SystemdLayer; Update-SystemdUnit -Name 'ssh' -Confirm:$false | Out-Null }
	catch {
		Write-OS7Step "reloading ssh failed: $($_.Exception.Message)"
	}

	Get-OS7Remoting
}
