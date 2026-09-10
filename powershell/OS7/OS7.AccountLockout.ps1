# =============================================================================
# OS/7 — the account lockout
#
# docs/REMOTE-DESKTOP-PLAN.md R10, arrived at from the Remote Desktop work and
# DELIBERATELY NOT NAMED AFTER IT. R10 wanted a lockout "on the remote greeter
# path only, scoped so a lockout never reaches the console"; measuring the login
# paths killed that idea twice over, and what is left is honest about its own
# reach:
#
#   * THE LOCAL AND THE REMOTE LOGIN SCREEN ARE THE SAME PAM SERVICE on this
#     image (`gdm-authd`, measured), so a lockout on the graphical path reaches
#     the physical console by construction. There is no scoping that separates
#     them.
#   * `pam_faillock`'s `authfail` MUST FOLLOW the authentication modules, and a
#     service file that ends in an `@include` has no position a prepending
#     writer can reach. Doing it anyway broke every login on the service
#     (BUILD-NOTES #125).
#
# So it lives where Ubuntu puts shared auth policy — `common-auth`, through
# `pam-auth-update` — and it is therefore ACCOUNT-WIDE: ssh, the text console,
# `sudo` and both login screens. That is what Windows does too, and it is the
# noun this file is named for. `Get-OS7RemoteDesktop` reports it; it does not
# own it.
#
# THE ORDER IS THE WHOLE DESIGN, and `pam-auth-update` is what makes it
# reachable. Two profiles, because one block cannot straddle the authenticators:
#
#     priority 1100   pam_faillock.so preauth     refuse an already-locked account
#     priority 1050   pam_authd_exec.so           (Ubuntu's)
#     priority  256   pam_unix.so                 (Ubuntu's)
#     priority  128   pam_sss.so                  (Ubuntu's)
#     priority   64   pam_faillock.so authfail    record the failure
#                     pam_deny.so / pam_permit.so (pam-auth-update's own)
#
# pam-auth-update recomputes the jump chain when it regenerates the file, which
# is the reason this is safe to add and would not be safe to hand-write: the
# `success=3` on pam_unix became `success=4` by itself, so a SUCCESSFUL
# authentication still jumps over `authfail` and lands on `pam_permit`.
#
# WHAT IT DOES NOT DO, measured rather than assumed: A SUCCESSFUL LOGIN DOES NOT
# CLEAR THE TALLY. `pam_faillock authsucc` is the module that would, and there
# is no position in a pam-auth-update stack for it — the success path jumps to
# the end. The counter therefore clears by TIME, through `fail_interval`, which
# is exactly what Windows' "reset account lockout counter after N minutes"
# does. Ten failures spread over more than the interval never lock anything.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

$script:OS7LockoutConf = '/etc/security/faillock.conf'
$script:OS7LockoutProfileDir = '/usr/share/pam-configs'
$script:OS7LockoutCommonAuth = '/etc/pam.d/common-auth'
$script:OS7LockoutProfiles = @('os7-faillock-preauth', 'os7-faillock-authfail')

function Get-OS7LockoutProfileText {
	<#
	.SYNOPSIS
		Internal. The two pam-configs profiles, as pam-auth-update reads them.

	.DESCRIPTION
		`Default: no` on both, deliberately, and belt-and-braces: these profiles
		are WRITTEN BY `Set-OS7AccountLockout` rather than shipped in a package,
		so a machine that never enables the lockout never carries them at all,
		and `pam-auth-update --package` run by something else can never switch
		on a policy nobody asked for. A lockout that arrived with an update and
		locked somebody out of a headless server is the change this avoids.

		`Auth-Type: Primary` on both, and that is not decoration. An
		`Additional` block is placed AFTER `pam_deny`/`pam_permit`, where a
		`[default=die]` decides nothing because the result is already settled —
		so `authfail` would record failures and never deny. Primary is the only
		type whose position is inside the chain pam-auth-update computes.
	#>
	param([Parameter(Mandatory)][string]$Name)

	if ($Name -eq 'os7-faillock-preauth') {
		return @(
			'Name: OS/7 account lockout (check)'
			'Default: no'
			'Priority: 1100'
			'Auth-Type: Primary'
			'Auth:'
			"`trequired`tpam_faillock.so preauth"
			'Auth-Initial:'
			"`trequired`tpam_faillock.so preauth"
		)
	}
	return @(
		'Name: OS/7 account lockout (record)'
		'Default: no'
		'Priority: 64'
		'Auth-Type: Primary'
		'Auth:'
		"`t[default=die]`tpam_faillock.so authfail"
		'Auth-Initial:'
		"`t[default=die]`tpam_faillock.so authfail"
	)
}

function Get-OS7LockoutConfValue {
	<#
	.SYNOPSIS
		Internal. One `key = value` out of faillock.conf, or $null.
	#>
	param([AllowNull()][string[]]$Lines, [Parameter(Mandatory)][string]$Key)

	if (-not $Lines) { return $null }
	foreach ($line in $Lines) {
		$t = $line.Trim()
		if ($t.StartsWith('#') -or -not $t) { continue }
		if ($t -match "^$([regex]::Escape($Key))\s*=\s*(.+)$") { return $Matches[1].Trim() }
		# The boolean options are bare words, not assignments.
		if ($t -eq $Key) { return 'true' }
	}
	return $null
}

function Get-OS7LockoutEffective {
	<#
	.SYNOPSIS
		Internal. Are the two lines actually IN the stack a login reads?

	.DESCRIPTION
		P6, and here the two halves come apart in a way that matters: the
		profiles can be present and enabled while `common-auth` does not carry
		them, because `pam-auth-update` is what turns one into the other and it
		may not have been run. The file a login actually reads is the effective
		answer, so that is what this asks.
	#>
	if (-not (Test-Path -LiteralPath $script:OS7LockoutCommonAuth)) {
		return [pscustomobject]@{ Preauth = $null; AuthFail = $null; Order = $null }
	}
	$lines = @([System.IO.File]::ReadAllLines($script:OS7LockoutCommonAuth) |
		Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() })
	$pre = -1; $fail = -1; $unix = -1
	for ($i = 0; $i -lt $lines.Count; $i++) {
		if ($lines[$i] -match 'pam_faillock\.so\s+preauth') { $pre = $i }
		elseif ($lines[$i] -match 'pam_faillock\.so\s+authfail') { $fail = $i }
		if ($lines[$i] -match 'pam_unix\.so') { $unix = $i }
	}
	return [pscustomobject]@{
		Preauth  = ($pre -ge 0)
		AuthFail = ($fail -ge 0)
		# The property the whole thing rests on: preauth before the
		# authenticators, authfail after them. Reported rather than trusted,
		# because getting it wrong is BUILD-NOTES #125.
		Order    = if ($pre -ge 0 -and $fail -ge 0 -and $unix -ge 0) {
			($pre -lt $unix) -and ($fail -gt $unix)
		}
		else { $null }
	}
}

function Get-OS7LockedAccount {
	<#
	.SYNOPSIS
		Internal. Which accounts have failures recorded against them.

	.DESCRIPTION
		`faillock`'s own output, parsed: a line ending in a colon names an
		account, and the rows under it are failures with a `V` in the last
		column while they still count toward the limit. An expired row is left
		in the file and stops counting, which is why the V is read rather than
		the rows being counted.
	#>
	param([int]$Deny = 10)

	# NOT Invoke-OS7Native, for two measured reasons. On a machine where no
	# failure has ever been recorded `faillock` writes "Error reading tally
	# directory: No such file or directory" to STDERR AND EXITS 0 - so the exit
	# code says nothing, and Invoke-OS7Native would echo that line to the
	# console on every Get-. Both streams are captured here and neither is
	# treated as a verdict.
	$errFile = [System.IO.Path]::GetTempFileName()
	$out = ''
	try {
		$global:LASTEXITCODE = $null
		$raw = & 'faillock' 2> $errFile
		$code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
		if ($null -eq $code) { return $null }
		$out = ($raw -join "`n")
	}
	catch { return $null }
	finally { Remove-Item -Force -ErrorAction SilentlyContinue $errFile }

	$result = [System.Collections.Generic.List[object]]::new()
	$user = $null
	$valid = 0
	$last = $null
	foreach ($line in @($out -split "`n")) {
		$t = $line.TrimEnd()
		if ($t -match '^(\S+):$') {
			if ($user) {
				$result.Add([pscustomobject]@{
						PSTypeName = 'OS7.AccountLockout.Account'
						Name = $user; ValidFailures = $valid
						Locked = ($valid -ge $Deny); LastFailure = $last
					})
			}
			$user = $Matches[1]; $valid = 0; $last = $null
			continue
		}
		if ($t -match '^\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s') {
			$stamp = $Matches[1]
			if ($t -match '\sV\s*$') {
				$valid++
				$last = $stamp
			}
		}
	}
	if ($user) {
		$result.Add([pscustomobject]@{
				PSTypeName = 'OS7.AccountLockout.Account'
				Name = $user; ValidFailures = $valid
				Locked = ($valid -ge $Deny); LastFailure = $last
			})
	}
	# `,` AND NOT a bare return: PowerShell unrolls a collection on the way out,
	# and an EMPTY one becomes nothing at all - so "nobody is locked" would
	# arrive at the caller as $null, which this surface reserves for "could not
	# be asked". BUILD-NOTES #92, and it was found by running this on a machine
	# that had never recorded a failure.
	return ,$result
}

function Get-OS7AccountLockout {
	<#
	.SYNOPSIS
		Whether a wrong password costs anything on this machine, and to whom.

	.DESCRIPTION
		WHAT IT IS: Windows' *Account lockout policy*, and it reaches the same
		things Windows' does — every way of signing in. On this machine that is
		ssh, the text console, `sudo`, and both login screens, because the local
		and the remote graphical login are one PAM service (measured). It is NOT
		a Remote Desktop setting, although the Remote Desktop work is what asked
		for it.

		TWO ANSWERS, NEVER ONE (P6). `ProfilesEnabled` is what
		`pam-auth-update` has been told; `Effective` is whether the lines are in
		the file a login actually reads. They disagree on a machine where the
		profiles were enabled and pam-auth-update has not run since, and that
		machine has no lockout while believing it has one.

		`OrderCorrect` is the property the whole feature rests on: the check
		before the authenticators, the record after them. It is reported rather
		than assumed, because the arrangement that reads correct and is wrong
		broke every login on a service once already (BUILD-NOTES #125).

		A SUCCESSFUL LOGIN DOES NOT CLEAR THE COUNTER — it clears by time,
		after `ResetMinutes`. That is Windows' "reset account lockout counter
		after N minutes" and it is measured, not assumed.

		`RootExempt` is `$true` unless somebody added `even_deny_root`. Locking
		root out of a machine whose console is the last way in is the failure
		this surface exists to avoid.

	.EXAMPLE
		Get-OS7AccountLockout | Format-List

	.EXAMPLE
		(Get-OS7AccountLockout).LockedAccounts
	#>
	[CmdletBinding()]
	param()

	$confLines = $null
	if (Test-Path -LiteralPath $script:OS7LockoutConf) {
		$confLines = @([System.IO.File]::ReadAllLines($script:OS7LockoutConf))
	}

	$deny = Get-OS7LockoutConfValue -Lines $confLines -Key 'deny'
	$unlock = Get-OS7LockoutConfValue -Lines $confLines -Key 'unlock_time'
	$interval = Get-OS7LockoutConfValue -Lines $confLines -Key 'fail_interval'
	$denyRoot = Get-OS7LockoutConfValue -Lines $confLines -Key 'even_deny_root'
	$localOnly = Get-OS7LockoutConfValue -Lines $confLines -Key 'local_users_only'

	$installed = @($script:OS7LockoutProfiles | Where-Object {
			Test-Path -LiteralPath ([System.IO.Path]::Combine($script:OS7LockoutProfileDir, $_))
		})
	$eff = Get-OS7LockoutEffective
	$denyN = if ($deny) { [int]$deny } else { 10 }
	# $null means faillock could not be asked, and it must not reach a pipeline:
	# `@($null | Where-Object ...)` is a terminating error under
	# Set-StrictMode -Version Latest, which is BUILD-NOTES #112/#119 exactly.
	# Found by running this on a machine, not by reading it.
	$locked = Get-OS7LockedAccount -Deny $denyN
	# Same trap as Unlock-'s, and here it would have been SILENT: an empty
	# result from the `if` expression is $null, so a machine where nobody is
	# locked would report LockedAccounts as "could not tell".
	$lockedNames = $null
	if ($null -ne $locked) {
		$lockedNames = @($locked | Where-Object { $_.Locked } | ForEach-Object { $_.Name })
	}

	$enabled = ($eff.Preauth -eq $true -and $eff.AuthFail -eq $true)

	return [pscustomobject]@{
		PSTypeName      = 'OS7.AccountLockout'
		Enabled         = $enabled
		Attempts        = if ($deny) { [int]$deny } else { $null }
		LockoutMinutes  = if ($unlock) { [int]$unlock / 60 } else { $null }
		ResetMinutes    = if ($interval) { [int]$interval / 60 } else { $null }
		RootExempt      = (-not $denyRoot)
		LocalUsersOnly  = [bool]$localOnly
		ProfilesPresent = $installed
		Effective       = $eff.Preauth -and $eff.AuthFail
		OrderCorrect    = $eff.Order
		# A successful sign-in does NOT clear the counter (measured). Stated as
		# a field so a fleet reading this JSON does not have to know it.
		ClearsOnSuccess = $false
		LockedAccounts  = $lockedNames
		Failures        = $locked
		Detail          =
		if (-not $installed.Count) { 'the lockout profiles are not installed on this machine' }
		elseif (-not $enabled) { 'a wrong password costs nothing: no lockout is in the stack a login reads. Set-OS7AccountLockout turns it on' }
		elseif ($eff.Order -eq $false) { 'THE ORDER IS WRONG: the record must follow the authenticators and the check must precede them. Logins may be failing for everyone' }
		else { "after $denyN failures within $(if ($interval) { [int]$interval / 60 } else { '?' }) minutes an account is locked for $(if ($unlock) { [int]$unlock / 60 } else { '?' }) minutes — on EVERY way of signing in, ssh and the console included" }
	}
}

function Set-OS7AccountLockout {
	<#
	.SYNOPSIS
		Turn the account lockout on or off, and set what it costs.

	.DESCRIPTION
		THIS CHANGES HOW EVERY ACCOUNT ON THE MACHINE AUTHENTICATES, on every
		path — ssh, the text console, `sudo`, both login screens. It is the one
		cmdlet in this module that can make a machine refuse its own
		administrator, and it is built to fail safe:

		  * the numbers are written BEFORE the profiles are enabled, so the
		    stack is never live against a missing configuration;
		  * `pam-auth-update` regenerates `common-auth` and RECOMPUTES the jump
		    chain, which is the reason this is done through it rather than by
		    editing the file — a hand-placed `authfail` broke every login on a
		    service once (BUILD-NOTES #125);
		  * the result is READ BACK from the file a login actually reads, and
		    the ORDER is checked, not assumed;
		  * if the readback fails the change is REVERSED before throwing, so a
		    machine is never left with a half-applied auth stack.

		root is never locked: `even_deny_root` is not written, deliberately.

	.PARAMETER Attempts
		Failures before an account locks. Ten by default, which is Windows 11's
		own default.

	.PARAMETER LockoutMinutes
		How long it stays locked. Ten by default. The lock also clears with
		`Unlock-OS7Account`.

	.PARAMETER ResetMinutes
		How long a failure counts for. Ten by default. This is what clears the
		counter, because a successful login does not (measured).

	.PARAMETER Disable
		Take the lockout back out of the stack.

	.EXAMPLE
		Set-OS7AccountLockout

	.EXAMPLE
		Set-OS7AccountLockout -Attempts 5 -LockoutMinutes 15

	.EXAMPLE
		Set-OS7AccountLockout -Disable
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[ValidateRange(1, 100)][int]$Attempts = 10,
		[ValidateRange(1, 1440)][int]$LockoutMinutes = 10,
		[ValidateRange(1, 1440)][int]$ResetMinutes = 10,
		[switch]$Disable
	)

	$what = if ($Disable) { 'remove the account lockout from every login path' }
	else { "lock an account for $LockoutMinutes minutes after $Attempts failures, on EVERY login path including ssh and the console" }
	if (-not $PSCmdlet.ShouldProcess('common-auth', $what)) { return Get-OS7AccountLockout }

	# The profiles are OS/7's own and are written before they are named to
	# pam-auth-update, so enabling can never reference a file that is not there.
	foreach ($p in $script:OS7LockoutProfiles) {
		$path = [System.IO.Path]::Combine($script:OS7LockoutProfileDir, $p)
		[System.IO.File]::WriteAllLines($path, [string[]](Get-OS7LockoutProfileText -Name $p))
		if ($IsLinux) {
			[System.IO.File]::SetUnixFileMode($path,
				[System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead,OtherRead')
		}
	}

	if (-not $Disable) {
		$conf = @(
			'# OS/7 - the account lockout. Written by Set-OS7AccountLockout.',
			'#',
			'# It reaches EVERY way of signing in: ssh, the text console, sudo and',
			'# both login screens. The local and the remote login screen are one PAM',
			'# service on this image, so there is no scoping that separates them.',
			'#',
			'# A SUCCESSFUL LOGIN DOES NOT CLEAR THE COUNTER (measured) - fail_interval',
			'# does, which is what Windows calls "reset the counter after N minutes".',
			'#',
			'# even_deny_root is deliberately absent: the console is the last way in.',
			"deny = $Attempts",
			"unlock_time = $($LockoutMinutes * 60)",
			"fail_interval = $($ResetMinutes * 60)",
			'local_users_only',
			'audit'
		)
		[System.IO.File]::WriteAllLines($script:OS7LockoutConf, [string[]]$conf)
		if ($IsLinux) {
			[System.IO.File]::SetUnixFileMode($script:OS7LockoutConf,
				[System.IO.UnixFileMode]'UserRead,UserWrite,GroupRead,OtherRead')
		}
	}

	$verb = if ($Disable) { '--disable' } else { '--enable' }
	$argv = @('--package')
	foreach ($p in $script:OS7LockoutProfiles) { $argv += @($verb, $p) }
	$null = Invoke-OS7Native -Command 'pam-auth-update' -Arguments $argv

	# READ BACK FROM THE FILE A LOGIN READS, and check the ORDER (P5).
	$eff = Get-OS7LockoutEffective
	$want = -not $Disable
	$got = ($eff.Preauth -eq $true -and $eff.AuthFail -eq $true)
	$bad = ($got -ne $want) -or ($want -and $eff.Order -ne $true)

	if ($bad) {
		# Reverse it rather than leave a machine with a half-applied auth stack.
		$undo = @('--package')
		foreach ($p in $script:OS7LockoutProfiles) { $undo += @('--disable', $p) }
		try { $null = Invoke-OS7Native -Command 'pam-auth-update' -Arguments $undo }
		catch { Write-OS7Step "THE REVERSAL ALSO FAILED: $($_.Exception.Message)" }
		throw [System.InvalidOperationException]::new(
			"pam-auth-update ran and common-auth does not carry the lockout correctly " +
			"(preauth=$($eff.Preauth) authfail=$($eff.AuthFail) order=$($eff.Order)). " +
			'The change was reversed; this machine authenticates as it did before.')
	}

	if ($want) {
		Write-OS7Step "the account lockout is on for EVERY login path: $Attempts failures within $ResetMinutes minutes locks for $LockoutMinutes. root is exempt; Unlock-OS7Account clears one."
	}
	else { Write-OS7Step 'the account lockout is out of the stack; a wrong password costs nothing again' }
	return Get-OS7AccountLockout
}

function Unlock-OS7Account {
	<#
	.SYNOPSIS
		Clear an account's failed sign-in count, so it can be used again.

	.DESCRIPTION
		Windows' *Unlock account*. The lock also expires on its own after
		`LockoutMinutes`; this is for the case where somebody is waiting.

		IT NEEDS AN ADMINISTRATOR, AND THAT IS THE TRAP TO KNOW: if the only
		administrator locks themselves out, there is nobody left to run this,
		and the answer is to wait for the lock to expire or to use the physical
		console as root. That is why root is never locked and why the default
		lock is ten minutes rather than an hour.

	.PARAMETER Name
		The account to unlock.

	.EXAMPLE
		Unlock-OS7Account alice
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([Parameter(Mandatory, Position = 0)][string]$Name)

	if (-not $PSCmdlet.ShouldProcess($Name, 'clear the failed sign-in count')) {
		return Get-OS7AccountLockout
	}
	$null = Invoke-OS7Native -Command 'faillock' -Arguments @('--user', $Name, '--reset')

	# Asked of faillock afterwards, never of its exit code (P5).
	# ASSIGNED, NOT RETURNED FROM AN `if` EXPRESSION. `$x = if (...) { @() }`
	# yields NOTHING for the empty branch - the value goes through a pipeline,
	# which drops an empty collection - so `$x` is $null and `$x.Count` is a
	# terminating error under Set-StrictMode. BUILD-NOTES #92 wearing a third
	# face; this one threw on a successful unlock.
	$still = @()
	$after = Get-OS7LockedAccount
	if ($null -ne $after) {
		$still = @($after | Where-Object { $_.Name -eq $Name -and $_.ValidFailures -gt 0 })
	}
	if (@($still).Count) {
		throw [System.InvalidOperationException]::new(
			"faillock reported success and '$Name' still has $($still[0].ValidFailures) failures recorded.")
	}
	Write-OS7Step "$Name may sign in again"
	return Get-OS7AccountLockout
}
