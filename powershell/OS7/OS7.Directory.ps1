# =============================================================================
# OS/7 — the Active Directory admin context
#
# WHAT THIS IS FOR, in one sentence, because it decides everything below: an
# administrator with an AD admin account signs in to the directory FROM this
# machine, for a while, and works. The machine itself is not a member of the
# domain and does not need to be.
#
# THAT DISTINCTION IS THE WHOLE DESIGN. An outbound, credential-based session
# needs no machine account, no keytab, no sssd, no /etc/krb5.conf and no new
# package — measured, not assumed: System.DirectoryServices.Protocols ships
# inside pwsh 7.6.5 and reaches libldap, which is guaranteed on both
# architectures because libldap2 is a Depends of libcurl4t64 and curl is in
# os7-base.list.chroot. A DOMAIN JOIN is a different feature with a different
# cost, it lives in OS7.Domain.ps1, and nothing here requires it.
#
# THE POLICY THIS FILE OWNS, as against the protocol, which is
# powershell/Directory's:
#
#   * TLS, and no argument about it. Measured against a real DC: a simple bind
#     on port 389 is answered "Strong authentication is required for this
#     operation", and LDAP sign-and-seal CANNOT be switched on from .NET on
#     Linux — SessionOptions.Sealing throws. So 636 is the only credential path
#     this platform has, -AllowUnencrypted exists for a lab, and it says so.
#
#   * FIVE MINUTES. Kerberos refuses a ticket outside that skew, and a drifting
#     clock does not report a clock problem — it reports that the password is
#     wrong. OS7.Time.ps1 already carries this number for the Entra path; the
#     same number decides the same thing here, and Test-OS7Directory asks the
#     DOMAIN CONTROLLER what time it thinks it is rather than asking chrony
#     whether it is happy. A diagnostic must not depend on the subsystem it is
#     diagnosing, and "is my clock right" answered by my own clock is that.
#
#   * TRUST IS A MACHINE SETTING AND CANNOT BE FAKED PER CALL. Measured
#     2026-08-27: setting $env:LDAPTLS_CACERT from inside PowerShell does
#     nothing at all, because .NET on Unix keeps its own copy of the
#     environment and never calls setenv(3), so no native library sees it —
#     while [Environment]::GetEnvironmentVariable reads the value back
#     happily. Add-OS7DirectoryTrust therefore writes the certificate where the
#     machine keeps them and READS BACK that it took effect.
#
# THE CREDENTIAL IS NOT KEPT. Once the bind has happened the session holds a
# bound connection and an identity string, and the password is gone. Nothing
# here can reconnect by itself, which is the point: a session that could
# silently re-authenticate would be a password at rest.
#
# Dot-sourced by OS7.psm1.
# =============================================================================

$script:OS7AdminSession = $null
$script:OS7KerberosSkewSeconds = 300
$script:OS7DirectoryTrustDir = '/usr/local/share/ca-certificates'

function Import-OS7DirectoryLayer {
	<#
	.SYNOPSIS
		Internal. Make the Directory module available, lazily.

	.DESCRIPTION
		LAZILY, AND NEVER AT IMPORT TIME — the same rule, for the same reason,
		as Import-OS7ZfsLayer and Import-OS7NetLayer. A live-build hook imports
		this module by path and lists what it exports; anything that CALLS a
		bundled cmdlet during import fails inside live-build's chroot
		(BUILD-NOTES #38, and #82 is that rule being broken and costing a day
		of builds).
	#>
	if (Get-Module -Name Directory) { return }

	$candidates = @(
		# Beside this module in the repository, which is how a developer and
		# the VM harness see it...
		(Join-Path (Split-Path -Parent $PSScriptRoot) 'Directory/Directory.psd1'),
		# ...and where build.sh stages it on an installed system.
		'/usr/local/share/powershell/Modules/Directory/Directory.psd1'
	)
	foreach ($candidate in $candidates) {
		if (Test-Path $candidate) {
			Import-Module $candidate -Force -ErrorAction Stop
			Write-OS7Step "directory layer: $candidate"
			return
		}
	}
	# By name as the last resort. It works on a booted system and not in a
	# chroot (BUILD-NOTES #14), which is the right way round for this caller.
	Import-Module Directory -Force -ErrorAction Stop
}

function Resolve-OS7AdminSession {
	<#
	.SYNOPSIS
		Internal. The session a cmdlet should use: the one passed in, or the
		ambient one, or a refusal that says which.

	.DESCRIPTION
		THE AMBIENT SESSION IS A CONVENIENCE AND NOT A MECHANISM. Every cmdlet
		here takes -Session, and a script should pass it; the ambient one
		exists so that an operator at a prompt does not have to. The refusal
		below is deliberate and specific, because the alternative — an LDAP
		error about anonymous access — sends somebody to look at directory
		permissions for a problem that is "you are not signed in".
	#>
	param($Session)

	if ($Session) { return $Session }
	if ($script:OS7AdminSession) { return $script:OS7AdminSession }
	throw ('No directory session. Run Enter-OS7AdminSession to sign in to the directory with ' +
		'an administrative account, or pass one with -Session.')
}

function Enter-OS7AdminSession {
	<#
	.SYNOPSIS
		Sign in to Active Directory with an administrative account, for this
		shell.

	.DESCRIPTION
		Opens a bound, encrypted connection to a domain controller and keeps it
		for the rest of the session, so that the cmdlets in this module act as
		THAT account. Every change is made under the operator's own name, the
		domain controller's audit trail says who did it, and no credential is
		stored on this machine.

		THE MACHINE DOES NOT HAVE TO BE JOINED. This is an outbound connection
		with a supplied credential; it needs DNS that can find the domain
		controller, a clock within five minutes, and the controller's issuing
		CA trusted by this machine. Nothing else.

		WHY NOT KERBEROS BY DEFAULT: measured 2026-08-27, .NET on Linux answers
		LDAP rc 92 (not supported) to a Negotiate bind carrying an explicit
		credential. Kerberos works only from a ticket that already exists,
		which means kinit and a krb5.conf that an unjoined OS/7 machine does
		not have. -UseKerberos is there for a machine that does.

	.EXAMPLE
		Enter-OS7AdminSession -Domain corp.example.com
		Get-OS7ADUser -Identity p-schmidt | Format-List
		Exit-OS7AdminSession
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Domain,
		[pscredential]$Credential,
		[string]$Server,
		[switch]$UseKerberos,
		[switch]$AllowUnencrypted,
		[int]$TimeoutSeconds = 30
	)

	Import-OS7DirectoryLayer

	$targetServer = $Server
	if (-not $targetServer) {
		$located = Get-OS7ADDomainController -Domain $Domain -First
		if (-not $located) {
			throw ("Could not find a domain controller for '$Domain'. DNS is what answers that " +
				'question — check that this machine resolves against the domain''s own name ' +
				'servers, or name one with -Server.')
		}
		$targetServer = $located.HostName
	}

	if ($UseKerberos) {
		if ($Credential) {
			throw ('-UseKerberos uses a Kerberos ticket that already exists and cannot take a ' +
				'credential: .NET on Linux answers LDAP rc 92 to that. Obtain a ticket first.')
		}
		$authType = 'Negotiate'
	}
	else {
		$authType = 'Basic'
		if (-not $Credential) {
			$Credential = Get-Credential -Message "Sign in to $Domain" -UserName "@$Domain"
		}
		if (-not $Credential) { throw 'No credential was supplied.' }
	}

	if ($AllowUnencrypted -and -not $UseKerberos) {
		Write-OS7Step ('WARNING: -AllowUnencrypted sends this password over an unprotected ' +
			'connection. Active Directory refuses that by default, and where it does not, ' +
			'the password is on the wire in the clear.')
	}

	$session = Connect-DirectoryServer -Server $targetServer -Credential $Credential `
		-AuthType $authType -NoTls:$AllowUnencrypted -TimeoutSeconds $TimeoutSeconds

	# ASK THE SERVER WHO WE ARE. A bind that raised no exception is not proof of
	# identity; it is proof that no exception was raised. This is also what
	# catches a bind that silently fell back to anonymous.
	$who = Get-DirectoryWhoAmI -Session $session
	if (-not $who) {
		Disconnect-DirectoryServer -Session $session
		throw ("The bind to $targetServer returned without error and the server would not say " +
			'who it thinks we are. That is what an anonymous bind looks like; it is not a ' +
			'session an administrator should work in.')
	}

	# THE rootDSE CAN COME BACK EMPTY, and Get-DirectoryRootDse returns $null for
	# that rather than an object with empty fields. Reaching straight into it is
	# then a PowerShell property error under Set-StrictMode — a message about
	# DefaultNamingContext, in a session an operator has just signed in to, that
	# says nothing about the directory. A session with no naming context is still
	# usable with an explicit -SearchBase, so this records "not known" and says
	# so; Get-OS7AdSearchBase is what refuses later, in the directory's terms.
	$rootDse = Get-DirectoryRootDse -Session $session
	$namingContext = $null
	if ($rootDse) { $namingContext = $rootDse.DefaultNamingContext }
	else {
		Write-OS7Step ("$targetServer answered the bind and returned no rootDSE, so this " +
			'session has no default search base — pass -SearchBase.')
	}

	$adminSession = [pscustomobject]@{
		PSTypeName           = 'OS7.AD.Session'
		Domain               = $Domain
		Server               = $targetServer
		Port                 = $session.Port
		Encrypted            = $session.Tls
		Authentication       = $authType
		Identity             = $who
		DefaultNamingContext = $namingContext
		Opened               = [datetime]::Now
		DirectorySession     = $session
	}

	$script:OS7AdminSession = $adminSession
	Write-OS7Step "signed in to $Domain as $who via $targetServer"
	return $adminSession
}

function Get-OS7AdminSession {
	<#
	.SYNOPSIS
		The directory session this shell is signed in with, if any.

	.DESCRIPTION
		Reports the identity THE SERVER gave back, not the name that was typed
		in, and carries no credential — which the module's own self-test
		asserts with a canary rather than trusting.
	#>
	[CmdletBinding()]
	param()

	if (-not $script:OS7AdminSession) { return $null }
	return $script:OS7AdminSession
}

function Exit-OS7AdminSession {
	<#
	.SYNOPSIS
		Close the directory session and forget it.
	#>
	[CmdletBinding()]
	param($Session)

	$target = $Session
	if (-not $target) { $target = $script:OS7AdminSession }
	if (-not $target) { return }

	if ($target.PSObject.Properties['DirectorySession'] -and $target.DirectorySession) {
		Import-OS7DirectoryLayer
		Disconnect-DirectoryServer -Session $target.DirectorySession
	}
	if ($script:OS7AdminSession -and $target -eq $script:OS7AdminSession) {
		$script:OS7AdminSession = $null
	}
	Write-OS7Step 'directory session closed'
}

function Get-OS7ADDomainController {
	<#
	.SYNOPSIS
		The domain controllers a domain publishes in DNS.

	.DESCRIPTION
		_ldap._tcp.dc._msdcs.<domain> is how every Active Directory client
		finds a controller, and DNS is the subsystem that answers it — which is
		why the lookup itself is powershell/Net's and not this module's
		(POWERSHELL-SURFACE-PLAN P2).

		Returns an EMPTY LIST and a reason when the lookup could not be made,
		never an empty list that reads as "this domain has no controllers".
		Those are different answers and only one of them is about the domain.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Domain,
		[switch]$First
	)

	Import-OS7NetLayer

	# Resolve-NetSrvRecord returns ONE object carrying Known/Reason/Records —
	# the Get-NetRadio shape — and not a list of records. Treating it as a list
	# gives you a status object with no Target, and the error names a property
	# rather than the missing DNS tool. Measured the hard way on 2026-08-27.
	$lookup = Resolve-NetSrvRecord -Name "_ldap._tcp.dc._msdcs.$Domain"
	if ($lookup.Known -and @($lookup.Records).Count -eq 0) {
		# _msdcs is the Active Directory-specific name and the right one to ask
		# first; the plain _ldap record is the fallback for a directory that is
		# not AD, or a zone where the _msdcs delegation is broken.
		$lookup = Resolve-NetSrvRecord -Name "_ldap._tcp.$Domain"
	}

	if (-not $lookup.Known) {
		# NOT an empty list. "This domain publishes no controllers" and "this
		# machine cannot ask" are different answers, and only one of them is
		# about the domain. bind9-dnsutils is in os7-base.list.chroot for
		# exactly this reason, and a machine without it must say so.
		Write-OS7Step ("domain controllers could not be looked up: $($lookup.Reason)")
		if ($First) { return $null }
		return @()
	}

	$controllers = foreach ($record in @($lookup.Records)) {
		[pscustomobject]@{
			PSTypeName = 'OS7.AD.DomainController'
			Domain     = $Domain
			HostName   = $record.Target
			Port       = $record.Port
			Priority   = $record.Priority
			Weight     = $record.Weight
		}
	}

	$list = @($controllers)
	if ($First) {
		if ($list.Count -eq 0) { return $null }
		return $list[0]
	}
	return $list
}

function Get-OS7ADDomain {
	<#
	.SYNOPSIS
		What the domain controller says about the domain.
	#>
	[CmdletBinding()]
	param($Session)

	Import-OS7DirectoryLayer
	$active = Resolve-OS7AdminSession -Session $Session
	$rootDse = Get-DirectoryRootDse -Session $active.DirectorySession

	return [pscustomobject]@{
		PSTypeName            = 'OS7.AD.Domain'
		Domain                = $active.Domain
		DistinguishedName     = $rootDse.DefaultNamingContext
		Forest                = $rootDse.RootDomainNamingContext
		DomainController      = $rootDse.DnsHostName
		DomainFunctionalLevel = $rootDse.DomainFunctionality
		ForestFunctionalLevel = $rootDse.ForestFunctionality
		ConfigurationContext  = $rootDse.ConfigurationNamingContext
		SchemaContext         = $rootDse.SchemaNamingContext
		SaslMechanisms        = $rootDse.SupportedSaslMechanisms
	}
}

function Test-OS7Directory {
	<#
	.SYNOPSIS
		Whether this machine can reach and use a domain controller, and which
		part is broken when it cannot.

	.DESCRIPTION
		THE DIAGNOSTIC THAT RUNS BEFORE ANYBODY SIGNS IN, and every answer
		comes from the thing being asked about:

		  * DNS — does the domain publish controllers, and does this machine
		    see them. Not "is a DNS server configured".
		  * The port — does something answer LDAPS there.
		  * TRUST — an untrusted certificate is reported by OpenLDAP with the
		    same message as a server that is not running, so this separates
		    them and says which.
		  * THE CLOCK, against the DOMAIN CONTROLLER'S OWN TIME, read out of
		    its rootDSE. Five minutes is where Kerberos stops, and a machine
		    outside it does not report a clock problem — it reports that the
		    password is wrong. Asking chrony instead would be asking the
		    subsystem under suspicion whether it is well.

		Each field is $null when it could not be asked, which is not the same
		as $false. "Cannot tell" is not "clean".
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Domain,
		[string]$Server,
		[pscredential]$Credential,
		[switch]$AllowUnencrypted
	)

	Import-OS7DirectoryLayer
	Import-OS7NetLayer

	$controllers = @(Get-OS7ADDomainController -Domain $Domain)
	$targetServer = $Server
	if (-not $targetServer -and $controllers.Count -gt 0) {
		$targetServer = $controllers[0].HostName
	}

	$reachable = $null
	$encrypted = $null
	$trusted = $null
	$skewSeconds = $null
	$clockOk = $null
	$identity = $null
	$detail = [System.Collections.Generic.List[string]]::new()

	if (-not $targetServer) {
		$detail.Add("DNS published no domain controller for '$Domain'.")
	}
	else {
		$probeSession = $null
		try {
			$probeSession = Connect-DirectoryServer -Server $targetServer `
				-Credential $Credential `
				-AuthType $(if ($Credential) { 'Basic' } else { 'Anonymous' }) `
				-NoTls:$AllowUnencrypted -TimeoutSeconds 15
			$reachable = $true
			$encrypted = $probeSession.Tls
			# A CERTIFICATE WAS ONLY JUDGED IF ONE WAS PRESENTED. Trust is
			# OpenLDAP's decision and it is taken during the handshake, so a TLS
			# session that came up IS a certificate this machine accepted. A
			# PLAINTEXT probe is shown none at all — reading this off .Tls
			# reported CertificateTrusted $false there, which is an accusation
			# about a certificate nobody sent, and it took Ready down with
			# nothing in Detail to say why. $null is "not asked", which is the
			# rule every other field here follows.
			$trusted = $(if ($probeSession.Tls) { $true } else { $null })
		}
		catch {
			$reachable = $false
			$message = $_.Exception.Message
			if ($message -like '*certificate*' -or $message -like '*untrusted*') {
				$trusted = $false
				$detail.Add(("The domain controller's certificate is not trusted by this " +
						'machine, or it is not reachable at all — OpenLDAP reports both the ' +
						'same way. Add-OS7DirectoryTrust installs a certificate authority.'))
			}
			else {
				$detail.Add($message.Split([char]10)[0])
			}
		}

		if ($probeSession) {
			try {
				$rootDse = Get-DirectoryRootDse -Session $probeSession
				if ($rootDse -and $rootDse.CurrentTime) {
					$skewSeconds = [math]::Round(
						([datetime]::UtcNow - $rootDse.CurrentTime).TotalSeconds, 1)
					$clockOk = ([math]::Abs($skewSeconds) -lt $script:OS7KerberosSkewSeconds)
					if (-not $clockOk) {
						$detail.Add(("This machine's clock is $skewSeconds seconds from the " +
								'domain controller''s. Kerberos refuses a ticket beyond ' +
								"$($script:OS7KerberosSkewSeconds), and the symptom is not a " +
								'clock error — it is a sign-in that reports a wrong password.'))
					}
				}
				if ($Credential) { $identity = Get-DirectoryWhoAmI -Session $probeSession }
			}
			catch {
				$detail.Add('The server answered the bind but not the rootDSE: ' +
					$_.Exception.Message.Split([char]10)[0])
			}
			finally { Disconnect-DirectoryServer -Session $probeSession }
		}
	}

	# READY REQUIRES POSITIVE EVIDENCE FOR EVERY PART, and the first version of
	# this line did not. It read `($clockOk -ne $false)`, which is $true when
	# the clock could not be measured at all — so a machine whose skew was
	# never established reported Ready, with the one check that decides whether
	# Kerberos will work silently skipped. BUILD-NOTES #94 is how that came to
	# light: a parsing bug made every timestamp $null, and this line turned
	# "could not tell" into "fine" rather than into a question.
	#
	# "Cannot tell" is not "clean" — so an unmeasured clock is not ready, and
	# Detail says which of the two it is.
	if ($null -eq $clockOk -and $reachable -eq $true) {
		$detail.Add(('The domain controller did not report its own time, so the clock could ' +
				'not be compared with it. Kerberos refuses a ticket more than ' +
				"$($script:OS7KerberosSkewSeconds) seconds out and the symptom is a sign-in " +
				'that reports a wrong password, so this is reported as not ready rather ' +
				'than assumed to be fine.'))
	}
	$ready = ($reachable -eq $true) -and ($clockOk -eq $true) -and ($trusted -ne $false)

	return [pscustomobject]@{
		PSTypeName        = 'OS7.AD.DirectoryTest'
		Domain            = $Domain
		DomainControllers = $controllers
		Server            = $targetServer
		Reachable         = $reachable
		Encrypted         = $encrypted
		CertificateTrusted = $trusted
		ClockSkewSeconds  = $skewSeconds
		ClockWithinKerberosLimit = $clockOk
		Identity          = $identity
		Ready             = $ready
		Detail            = $detail.ToArray()
	}
}

function Add-OS7DirectoryTrust {
	<#
	.SYNOPSIS
		Trust a domain controller's issuing certificate authority, machine-wide.

	.DESCRIPTION
		THIS HAS TO BE MACHINE-WIDE AND THAT IS NOT A DESIGN CHOICE. Measured
		2026-08-27: .NET's LdapConnection on Linux has no certificate callback
		(SessionOptions.VerifyServerCertificate throws), so trust is decided by
		OpenLDAP; and the one mechanism that could have been scoped to a single
		process — the LDAPTLS_CACERT environment variable — cannot be set from
		inside PowerShell at all, because .NET on Unix keeps its own copy of
		the environment and never calls setenv(3). The variable reads back
		correctly and has no effect whatsoever.

		So the certificate goes where the machine keeps certificates, and this
		READS BACK that it took effect rather than trusting the exit code of
		update-ca-certificates — which reports success for a file it did not
		manage to hash.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Path,
		[string]$Name = 'os7-directory-ca'
	)

	if (-not (Test-Path $Path)) { throw "The certificate '$Path' does not exist." }

	$target = Join-Path $script:OS7DirectoryTrustDir "$Name.crt"
	if (-not $PSCmdlet.ShouldProcess($target, 'install a certificate authority')) { return $null }

	Copy-Item -LiteralPath $Path -Destination $target -Force
	$null = Invoke-OS7Native -Command 'update-ca-certificates' -Arguments @()

	$subject = $null
	$fingerprint = $null
	try {
		$subject = (Invoke-OS7Native -Command 'openssl' -Arguments @(
				'x509', '-noout', '-subject', '-in', $target)).Trim()
		$fingerprint = (Invoke-OS7Native -Command 'openssl' -Arguments @(
				'x509', '-noout', '-fingerprint', '-sha256', '-in', $target)).Trim()
	}
	catch {
		throw ("'$Path' was copied to $target but openssl cannot read it as a certificate. " +
			'update-ca-certificates will have skipped it and exited 0 regardless: ' +
			$_.Exception.Message.Split([char]10)[0])
	}

	# ASK THE STORE, NOT THE TOOL. update-ca-certificates exits 0 having
	# skipped a file it could not parse, so its exit code says nothing about
	# whether this machine now trusts anything. `openssl verify` against the
	# assembled bundle is the store's own answer, and a self-signed root that
	# is genuinely in it verifies.
	$installed = $false
	try {
		$verified = Invoke-OS7Native -Command 'openssl' -Arguments @(
			'verify', '-CAfile', '/etc/ssl/certs/ca-certificates.crt', $target)
		$installed = ($verified -match ': *OK')
	}
	catch { $installed = $false }

	return [pscustomobject]@{
		PSTypeName  = 'OS7.AD.DirectoryTrust'
		Path        = $target
		Subject     = $subject
		Fingerprint = $fingerprint
		Installed   = $installed
	}
}
