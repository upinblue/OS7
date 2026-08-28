# =============================================================================
# OS/7 — the domain join: making this machine a member of an Active Directory
#
# A DIFFERENT FEATURE FROM THE ONE NEXT DOOR, and the difference is worth
# stating before the first function. OS7.Directory.ps1 signs an ADMINISTRATOR
# in to a directory from this machine and needs nothing installed. This file
# gives the MACHINE an identity in the domain, so that domain accounts can log
# in to it, and it costs five packages, a machine account, a keytab and an
# interaction with boot environments that nothing else in this repository has.
#
# WHAT THIS BUYS AND WHAT IT DOES NOT. It buys: domain accounts logging in,
# `getent` resolving them, sudo rights granted by AD group membership, and
# Kerberos single sign-on from this host. It does NOT buy Group Policy — there
# is no GPO engine for Linux, and sssd's ad_gpo_access_control enforces logon
# rights only. It does not make the machine manageable by Intune either:
# Intune enrolment goes through Entra, and there is no hybrid join for Linux.
# An administrator who expects "joined, therefore managed like Windows" has to
# be told otherwise, and Get-OS7Domain says so in its Detail.
#
# THE ONE THAT WILL BITE, and it is OS/7-specific: /etc lives INSIDE the boot
# environment. An Active Directory machine account password rotates — thirty
# days by default — and /etc/krb5.keytab rotates with it. Roll a boot
# environment back and the keytab goes back with it while the domain controller
# does not, so the machine's own credential is stale and it authenticates
# nobody. Meanwhile sssd's cache under /var/lib/sss sits OUTSIDE the boot
# environment (D10) and does not roll back, so the two halves disagree.
# Repair-OS7Domain is the way out and Test-OS7Domain is what notices; the
# question of whether the layout itself should change is open, and
# docs/AD-PLAN.md holds it.
#
# NOTHING HERE NAMES adcli, kinit, klist, getent OR systemctl. Those are the
# generic layers' — powershell/Directory and powershell/Systemd — and
# installer/testing/check-layering.py's P2-directory and P2-systemd rules hold
# the line at a baseline that may fall and may not rise.
#
# Dot-sourced by OS7.psm1, after OS7.DirectoryObject.ps1.
# =============================================================================

$script:OS7DomainSudoersPath = '/etc/sudoers.d/60-os7-domain-admins'
$script:OS7DomainHomeRoot = '/var/lib/os7/domain-homes'

function Get-OS7Domain {
	<#
	.SYNOPSIS
		Whether this machine is a member of a domain, as configured and as it
		actually stands.

	.DESCRIPTION
		TWO SETS OF FIELDS, NEVER MERGED — POWERSHELL-SURFACE-PLAN P6. The
		configured half is what the files on disk say. The effective half is
		what the machine can actually do: whether the keytab holds principals
		and whether the name service resolves a domain account. A machine where
		those disagree is precisely the machine somebody is trying to fix, and
		a single "Joined: true" would hide it.
	#>
	[CmdletBinding()]
	param([string]$ProbeAccount)

	Import-OS7DirectoryLayer

	$configuration = Get-DirectoryRealmConfiguration
	$keytab = Get-DirectoryKeytabPrincipal

	$resolved = $null
	if ($ProbeAccount) {
		$resolution = Get-DirectoryIdentityResolution -Name $ProbeAccount
		$resolved = $resolution.Resolved
	}

	$sssdRunning = $null
	try {
		Import-OS7SystemdLayer
		# `.service` SPELLED OUT. Get-SystemdUnit hands the name straight to
		# `systemctl list-units --all <pattern>`, which fnmatches the FULL unit
		# id, so the bare `sssd` matched nothing and SssdRunning was permanently
		# $null on a machine where sssd was running. The asymmetry is what hides
		# it: `Restart-SystemdUnit -Name 'sssd'` works, because systemctl mangles
		# a bare name into `sssd.service` for the commands that act on a unit and
		# never for the one that lists them.
		$unit = Get-SystemdUnit -Name 'sssd.service'
		if ($unit) { $sssdRunning = ($unit.ActiveState -eq 'active') }
	}
	catch { $sssdRunning = $null }

	$detail = [System.Collections.Generic.List[string]]::new()
	if (-not $configuration.SssdConfPresent) {
		$detail.Add('There is no /etc/sssd/sssd.conf, so this machine is not configured for any domain.')
	}
	if ($configuration.SssdConfPresent -and -not $keytab.Known) {
		$detail.Add('The keytab could not be read: ' + $keytab.Reason)
	}
	if ($configuration.SssdConfPresent -and $keytab.Known -and @($keytab.Principal).Count -eq 0) {
		$detail.Add(('This machine is configured for a domain and has no machine credential. ' +
				'A boot-environment rollback does exactly this, because /etc/krb5.keytab ' +
				'lives inside the boot environment and the domain controller does not roll ' +
				'back with it. Repair-OS7Domain renews it.'))
	}
	$detail.Add(('A domain join does not make this machine manageable by Intune: enrolment ' +
			'goes through Entra ID, and there is no hybrid join for Linux. Group Policy is ' +
			'not applied either.'))

	return [pscustomobject]@{
		PSTypeName          = 'OS7.AD.DomainMembership'
		ConfiguredDomains   = $configuration.Domains
		ConfigurationPresent = $configuration.SssdConfPresent
		KeytabPresent       = $configuration.KeytabPresent
		KeytabPrincipal     = $keytab.Principal
		Krb5ConfPresent     = $configuration.Krb5ConfPresent
		SssdRunning         = $sssdRunning
		ProbeAccount        = $ProbeAccount
		ProbeResolved       = $resolved
		Joined              = ($configuration.SssdConfPresent -and
			$keytab.Known -and @($keytab.Principal).Count -gt 0)
		Detail              = $detail.ToArray()
	}
}

function Join-OS7Domain {
	<#
	.SYNOPSIS
		Join this machine to an Active Directory domain.

	.DESCRIPTION
		ONE IMPLEMENTATION, TWO CALLERS. os7-setup's screen 9D shells out to
		this cmdlet the same way its storage step shells out to New-OS7Storage,
		so the installer and an administrator take the identical road. Writing
		the join a second time in C# would be BUILD-NOTES #66 exactly: a
		specification implemented twice, taking two routes, with nobody
		diffing them.

		-OneTimePassword is the road a fleet should take: somebody pre-creates
		the computer account and hands over a single-use password, so no domain
		administrator credential is ever typed into an installer.

		THE HOME DIRECTORY DECISION IS MADE HERE AND IT IS NOT sssd's DEFAULT.
		Domain users' homes go under /var/lib/os7/domain-homes, which is on a
		dataset outside the boot environment. sssd would otherwise let
		pam_mkhomedir create them inside it, where Restore-OS7 rolls them back
		with the operating system — BUILD-NOTES #74 in a second location, and
		this repository has already paid for that once.

		THE PROOF IS NOT adcli's EXIT CODE. This reads the keytab back, asks
		the name service to resolve an account, and reports both.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Domain,
		[string]$UserName,
		[securestring]$Password,
		[switch]$OneTimePassword,
		[string]$ComputerName,
		[string]$OrganizationalUnit,
		[string[]]$AllowGroup = @(),
		[string[]]$AdministratorGroup = @(),
		[string]$HomeDirectoryTemplate,
		[string]$TargetRoot,
		[switch]$SkipServiceRestart
	)

	Import-OS7DirectoryLayer

	if (-not $PSCmdlet.ShouldProcess($Domain, 'join this machine to the domain')) { return $null }

	$sssdPath = '/etc/sssd/sssd.conf'
	$keytabPath = '/etc/krb5.keytab'
	if ($TargetRoot) {
		$sssdPath = (Join-Path $TargetRoot 'etc/sssd/sssd.conf')
		$keytabPath = (Join-Path $TargetRoot 'etc/krb5.keytab')
	}

	$homeTemplate = $HomeDirectoryTemplate
	if (-not $homeTemplate) { $homeTemplate = (Join-Path $script:OS7DomainHomeRoot '%u') }

	Write-OS7Step "joining $Domain"
	$join = Join-DirectoryRealm -Domain $Domain -UserName $UserName -Password $Password `
		-OneTimePassword:$OneTimePassword -ComputerName $ComputerName `
		-OrganizationalUnit $OrganizationalUnit -KeytabPath $keytabPath `
		-SssdConfPath $sssdPath -AllowGroup $AllowGroup `
		-HomeDirectoryTemplate $homeTemplate -Confirm:$false

	if (@($AdministratorGroup).Count -gt 0) {
		$null = Set-OS7DomainLogonPolicy -AdministratorGroup $AdministratorGroup `
			-TargetRoot $TargetRoot -Confirm:$false
	}

	if (-not $SkipServiceRestart) {
		try {
			Import-OS7SystemdLayer
			$null = Restart-SystemdUnit -Name 'sssd' -Confirm:$false
			$null = Set-SystemdUnitStartup -Name 'sssd' -Enabled -Confirm:$false
		}
		catch {
			Write-OS7Step ('sssd could not be started here: ' +
				$_.Exception.Message.Split([char]10)[0])
		}
	}

	return $join
}

function Repair-OS7Domain {
	<#
	.SYNOPSIS
		Renew this machine's domain credential after it has gone stale.

	.DESCRIPTION
		THE FIX FOR THE ROLLBACK CASE, and the reason it needs no administrator
		credential: `adcli update` re-establishes the machine account using the
		account itself. The failure it repairs is invisible from the machine's
		own point of view — every file is present and correct, and the domain
		controller simply does not recognise the password any more.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param([string]$Domain)

	Import-OS7DirectoryLayer
	if (-not $PSCmdlet.ShouldProcess(($Domain ?? 'this machine'), 'renew the domain credential')) {
		return $null
	}
	return (Update-DirectoryRealm -Domain $Domain -Confirm:$false)
}

function Remove-OS7Domain {
	<#
	.SYNOPSIS
		Leave the domain: delete the computer account and remove the credential.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory)][string]$Domain,
		[string]$UserName,
		[securestring]$Password
	)

	Import-OS7DirectoryLayer
	if (-not $PSCmdlet.ShouldProcess($Domain, 'leave the domain')) { return $null }

	$result = Remove-DirectoryRealm -Domain $Domain -UserName $UserName -Password $Password `
		-Confirm:$false

	try {
		Import-OS7SystemdLayer
		$null = Restart-SystemdUnit -Name 'sssd' -Confirm:$false
	}
	catch { }

	return $result
}

function Test-OS7Domain {
	<#
	.SYNOPSIS
		Whether the domain membership actually works, and which part does not.

	.DESCRIPTION
		FIVE ANSWERS FROM FIVE PLACES, none of them an exit code:

		  * the keytab, listed rather than stat-ed;
		  * sssd's state, from systemd;
		  * NAME RESOLUTION, which is the only question that proves the join
		    works — everything else can be right while the machine resolves
		    nobody;
		  * the clock against the domain controller, because five minutes is
		    where Kerberos stops and a drifting clock reports a wrong password
		    rather than a wrong clock;
		  * the controller's reachability.

		Every field is $null when it could not be asked. "Cannot tell" is not
		"clean", and a health verb that says "fine" because it could not look
		is worse than one that says nothing.
	#>
	[CmdletBinding()]
	param(
		[string]$Domain,
		[string]$ProbeAccount
	)

	Import-OS7DirectoryLayer

	$membership = Get-OS7Domain -ProbeAccount $ProbeAccount
	$targetDomain = $Domain
	if (-not $targetDomain -and @($membership.ConfiguredDomains).Count -gt 0) {
		$targetDomain = $membership.ConfiguredDomains[0]
	}

	$directory = $null
	$directoryReason = $null
	if ($targetDomain) {
		try { $directory = Test-OS7Directory -Domain $targetDomain }
		catch {
			$directory = $null
			$directoryReason = $_.Exception.Message.Split([char]10)[0]
		}
	}

	$problems = [System.Collections.Generic.List[string]]::new()
	foreach ($one in $membership.Detail) { $problems.Add($one) }
	if ($directory -and $directory.Detail) {
		foreach ($one in $directory.Detail) { $problems.Add($one) }
	}

	# HEALTHY REQUIRES POSITIVE EVIDENCE FOR EVERY PART, and this line did not
	# have it. `-ne $false` is TRUE for a field that is $null, so an sssd that
	# could not be asked, a probe nobody requested and a Test-OS7Directory that
	# THREW all scored healthy — in the function whose description above says
	# that "cannot tell" is not "clean". Test-OS7Directory's own $ready line
	# carried the same defect and now reads the same way this one does.
	#
	# So each thing that could not be established says so in Detail, and none of
	# them counts as evidence.
	if ($null -eq $membership.SssdRunning) {
		$problems.Add(('sssd''s state could not be read, so whether the service that answers ' +
				'for domain accounts is even running is unknown.'))
	}
	if ($null -eq $membership.ProbeResolved) {
		$problems.Add(('No -ProbeAccount was given, so name resolution was never asked — and ' +
				'it is the only question that proves the join works. Everything else here ' +
				'can be right while the machine resolves nobody.'))
	}
	if (-not $targetDomain) {
		$problems.Add(('No domain was named and none is configured, so no domain controller ' +
				'was asked anything at all.'))
	}
	elseif ($null -eq $directory) {
		$problems.Add(('The domain controller could not be tested: ' +
			($directoryReason ?? 'Test-OS7Directory returned nothing.')))
	}

	$healthy = ($membership.Joined -eq $true) -and
		($membership.SssdRunning -eq $true) -and
		($membership.ProbeResolved -eq $true) -and
		($null -ne $directory) -and ($directory.Ready -eq $true)

	return [pscustomobject]@{
		PSTypeName      = 'OS7.AD.DomainHealth'
		Domain          = $targetDomain
		Joined          = $membership.Joined
		KeytabPrincipal = $membership.KeytabPrincipal
		SssdRunning     = $membership.SssdRunning
		ProbeAccount    = $ProbeAccount
		ProbeResolved   = $membership.ProbeResolved
		ControllerReachable = $(if ($directory) { $directory.Reachable } else { $null })
		ClockSkewSeconds = $(if ($directory) { $directory.ClockSkewSeconds } else { $null })
		Healthy         = $healthy
		Detail          = $problems.ToArray()
	}
}

function Get-OS7DomainLogonPolicy {
	<#
	.SYNOPSIS
		Which domain groups may sign in to this machine, and which administer it.

	.DESCRIPTION
		TWO DIFFERENT MECHANISMS AND THEY ARE OFTEN CONFUSED. Signing in is
		sssd's simple_allow_groups; administering is sudo, in
		/etc/sudoers.d. A group in the second and not the first can be granted
		root and still not be able to log in, which presents as a broken
		password.
	#>
	[CmdletBinding()]
	param([string]$SudoersPath)

	Import-OS7DirectoryLayer

	$path = $SudoersPath
	if (-not $path) { $path = $script:OS7DomainSudoersPath }

	$allowGroups = @()
	$sssdConf = '/etc/sssd/sssd.conf'
	if ([System.IO.File]::Exists($sssdConf)) {
		foreach ($line in [System.IO.File]::ReadAllLines($sssdConf)) {
			$match = [regex]::Match($line, '^\s*simple_allow_groups\s*=\s*(.+)$')
			if ($match.Success) {
				$allowGroups = @($match.Groups[1].Value.Split(',') |
					ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
			}
		}
	}

	$adminGroups = @()
	if ([System.IO.File]::Exists($path)) {
		foreach ($line in [System.IO.File]::ReadAllLines($path)) {
			$match = [regex]::Match($line, '^\s*%(\S+(?:\\ \S+)*)\s+ALL=')
			if ($match.Success) { $adminGroups += ($match.Groups[1].Value -replace '\\ ', ' ') }
		}
	}

	return [pscustomobject]@{
		PSTypeName         = 'OS7.AD.DomainLogonPolicy'
		LogonGroup         = $allowGroups
		AdministratorGroup = $adminGroups
		SudoersPath        = $path
	}
}

function Set-OS7DomainLogonPolicy {
	<#
	.SYNOPSIS
		Grant a domain group the right to administer this machine.

	.DESCRIPTION
		A SPACE IN A GROUP NAME IS THE TRAP HERE. "Domain Admins" written into
		sudoers unescaped is a syntax error, and a syntax error anywhere in
		/etc/sudoers.d makes sudo refuse EVERY rule in the file — including the
		one that lets the local break-glass account become root. So the file is
		written to a temporary path, checked with visudo, and only then moved
		into place. A machine that has locked its own administrator out is not
		a machine anybody can log in to and fix.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string[]]$AdministratorGroup,
		[string]$TargetRoot,
		[string]$SudoersPath
	)

	$path = $SudoersPath
	if (-not $path) { $path = $script:OS7DomainSudoersPath }
	if ($TargetRoot) { $path = (Join-Path $TargetRoot ($path -replace '^/', '')) }

	if (-not $PSCmdlet.ShouldProcess($path, "grant sudo to $($AdministratorGroup -join ', ')")) {
		return $null
	}

	$lines = [System.Collections.Generic.List[string]]::new()
	$lines.Add('# Written by Set-OS7DomainLogonPolicy. Domain groups that administer this machine.')
	$lines.Add('#')
	$lines.Add('# A space in a group name must be escaped or sudo refuses the whole file,')
	$lines.Add('# which would take the local break-glass account down with it.')
	foreach ($group in $AdministratorGroup) {
		$lines.Add('%' + ($group -replace ' ', '\ ') + ' ALL=(ALL:ALL) ALL')
	}
	$text = (($lines -join "`n") + "`n")

	$directory = [System.IO.Path]::GetDirectoryName($path)
	if (-not [System.IO.Directory]::Exists($directory)) {
		[void][System.IO.Directory]::CreateDirectory($directory)
	}

	$staging = $path + '.os7-new'
	Set-Content -LiteralPath $staging -Value $text -NoNewline
	& chmod 0440 $staging

	# CHECK IT BEFORE IT COUNTS. visudo -c on the staged file is the only
	# thing between a typo and a machine nobody can administer.
	$checked = $false
	try {
		$null = Invoke-OS7Native -Command 'visudo' -Arguments @('-c', '-f', $staging)
		$checked = $true
	}
	catch {
		Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
		throw ('The sudoers rule was rejected by visudo and has NOT been installed. ' +
			'Nothing on this machine changed: ' + $_.Exception.Message.Split([char]10)[0])
	}

	Move-Item -LiteralPath $staging -Destination $path -Force

	return (Get-OS7DomainLogonPolicy -SudoersPath $path)
}

function Get-OS7KerberosTicket {
	<#
	.SYNOPSIS
		The Kerberos tickets this session holds.
	#>
	[CmdletBinding()]
	param()

	Import-OS7DirectoryLayer
	return (Get-DirectoryTicket)
}

function New-OS7KerberosTicket {
	<#
	.SYNOPSIS
		Obtain a Kerberos ticket for a principal.

	.DESCRIPTION
		A TICKET IS PER-USER AND sudo DOES NOT CARRY IT. sssd's default
		credential cache is in the kernel keyring, which is scoped to a uid, so
		an elevated shell cannot see the ticket the unelevated one holds and
		`sudo -E` does not change that. Directory administration therefore runs
		UNELEVATED, and machine operations — a join, a repair — run elevated.
		Two contexts in one session, and the surface has to say so rather than
		let an operator discover it as an access-denied from the directory.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Principal,
		[pscredential]$Credential
	)

	Import-OS7DirectoryLayer

	$secret = $null
	if ($Credential) { $secret = $Credential.Password }
	else {
		$prompted = Get-Credential -Message "Kerberos password for $Principal" -UserName $Principal
		if (-not $prompted) { throw 'No credential was supplied.' }
		$secret = $prompted.Password
	}

	return (New-DirectoryTicket -Principal $Principal -Password $secret)
}

function Remove-OS7KerberosTicket {
	<#
	.SYNOPSIS
		Destroy this session's Kerberos tickets.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param()

	Import-OS7DirectoryLayer
	if (-not $PSCmdlet.ShouldProcess('the Kerberos credential cache', 'destroy')) { return $null }
	return (Remove-DirectoryTicket -Confirm:$false)
}
