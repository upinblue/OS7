# =============================================================================
# Directory — LDAP, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like powershell/Zfs,
# powershell/Net, powershell/Time and powershell/Systemd. It knows LDAP, X.500
# and the Active Directory schema, and nothing about OS/7. It would run against
# any LDAP server on any Ubuntu host.
#
# The line: this module owns the PROTOCOL — connecting, binding, controls,
# filter and DN escaping, paging, referral policy, attribute normalisation and
# what an LdapException MEANS. powershell/OS7/OS7.Directory*.ps1 owns the
# POLICY — which server, whether the clock is close enough for Kerberos, that
# an unencrypted password change is refused before the wire sees it, and every
# OS7-prefixed name. AD's schema is protocol vocabulary here, exactly as
# netplan's YAML is Net's and not OS7's.
#
# EIGHT THINGS MEASURED 2026-08-27 THAT DECIDE THE SHAPE OF THIS FILE. Seven
# came from the shipped amd64 image (os7img:116) and from a real Samba AD DC
# (installer/testing/Dockerfile.ad-dc, realm OS7.TEST); the eighth is the
# reason this file exists at all.
#
#   1. System.DirectoryServices.Protocols SHIPS INSIDE PowerShell 7.6.5 on
#      Linux, at /opt/microsoft/powershell/7/System.DirectoryServices.Protocols.dll,
#      and its types resolve as bare type literals with NO Add-Type — including
#      under `env -i PATH=... pwsh -NoProfile -NonInteractive`. So this module
#      NEVER calls Add-Type: that cmdlet is Microsoft.PowerShell.Utility, and
#      autoloading by name does not work inside live-build's chroot, which is
#      BUILD-NOTES #38/#82 and cost a day of ISO builds.
#
#   2. The P/Invoke reaches OpenLDAP. A bind to a dead port throws
#      LdapException "The LDAP server is unavailable.", NOT DllNotFoundException.
#      libldap.so.2 is guaranteed on both architectures because libldap2 is a
#      Depends of libcurl4t64 and `curl` is in os7-base.list.chroot.
#
#   3. SessionOptions.ProtocolVersion READS BACK 2. LDAPv2. Active Directory
#      refuses it, and the refusal presents as a credential failure. Every
#      connection here sets 3 and READS IT BACK — see BUILD-NOTES #94. Same
#      family as #25 and #62: a default is not the value you assumed, and
#      nothing says so.
#
#   4. SessionOptions.Sealing and .Signing THROW LdapException when set on
#      Linux, and their getters return empty. LDAP sign-and-seal is therefore
#      NOT AVAILABLE to this module. That is not a preference; it decides that
#      LDAPS on 636 is the default and port 389 is opt-in.
#
#   5. SessionOptions.VerifyServerCertificate THROWS on Linux. There is no
#      certificate callback. Trust is OpenLDAP's, from TLS_CACERT in
#      /etc/ldap/ldap.conf or the LDAPTLS_CACERT environment variable — and
#      only the environment variable can be scoped to one process.
#
#   6. SessionOptions.ReferralChasing DEFAULTS TO All. A referral makes
#      LdapConnection open a SECOND connection with no credentials. Every real
#      search against a domain root returns three of them (measured against
#      the Samba DC). This module sets None and reports referrals as data.
#
#   7. AuthType.Negotiate with an EXPLICITLY SUPPLIED credential returns LDAP
#      rc 92, LDAP_NOT_SUPPORTED. With an AMBIENT ticket it works — but only
#      when krb5's `rdns = false` AND OpenLDAP's `SASL_NOCANON on` are both
#      set. Fixing one and not the other leaves the error message identical.
#
#   8. SearchResultEntry, SearchResultEntryCollection and SearchResponse have
#      ZERO public constructors. A fake cannot produce what SendRequest
#      returns without reflecting into private constructors — a test that
#      breaks on a .NET servicing update and reports it as a client defect.
#      That is why the seam in this file sits ABOVE the .NET boundary rather
#      than below it, and why the un-fakeable region is one short function
#      that makes no decisions at all.
# =============================================================================

Set-StrictMode -Version 3.0

# ---------------------------------------------------------------------------
# The seams
#
# Two, not one, and the pair is the whole testing strategy of this module. The
# other four generic layers replace a COMMAND RUNNER, which puts invocation,
# exit codes and parsing all under test (Net.psm1's own note says why). LDAP
# cannot be faked that deep — measurement 8 above — so the boundary moves up by
# exactly two functions, and everything above it is the whole of this module's
# judgement while everything below it is a transcription.
# ---------------------------------------------------------------------------
$script:DirectoryConnectionFactory = $null
$script:DirectoryRequestOverride   = $null

# Attributes Active Directory returns as raw octets. Everything else is text.
# This list is short on purpose: an attribute treated as binary by mistake
# comes back as a byte array nobody can read, and one treated as text by
# mistake comes back as mojibake that looks like corruption.
$script:DirectoryBinaryAttributes = @(
	'objectGUID', 'objectSid', 'nTSecurityDescriptor', 'unicodePwd',
	'msDS-KeyCredentialLink', 'userCertificate', 'cACertificate',
	'msDS-AllowedToActOnBehalfOfOtherIdentity'
)

# ---------------------------------------------------------------------------
# The un-fakeable floor: two functions, no decisions
# ---------------------------------------------------------------------------

function New-DirectoryConnection {
	<#
	.SYNOPSIS
		Internal. Build and bind one LdapConnection. Decides nothing about
		what is asked of it afterwards.

	.DESCRIPTION
		ONE OF ONLY TWO FUNCTIONS IN THIS MODULE THAT TOUCHES
		System.DirectoryServices.Protocols.

		Three of the eight measurements in this file's header land here and
		each is a line of code rather than a comment elsewhere:

		  * ProtocolVersion is set to 3 and READ BACK. LDAPv2 is the default
		    and AD refuses it; the refusal looks like a bad password.
		  * ReferralChasing is set to None. The default opens a second,
		    unauthenticated connection behind the caller's back.
		  * Sealing and Signing are NOT set, because setting them throws on
		    this platform. There is no way to sign a bind here, which is why
		    TLS is the default rather than an option.
	#>
	param(
		[Parameter(Mandatory)][string]$Server,
		[int]$Port = 636,
		[switch]$UseTls,
		[pscredential]$Credential,
		[ValidateSet('Basic', 'Negotiate', 'Anonymous')][string]$AuthType = 'Basic',
		[int]$TimeoutSeconds = 30
	)

	if ($script:DirectoryConnectionFactory) {
		return & $script:DirectoryConnectionFactory $Server $Port $UseTls $Credential $AuthType
	}

	$identifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($Server, $Port)
	$connection = [System.DirectoryServices.Protocols.LdapConnection]::new($identifier)

	$connection.SessionOptions.ProtocolVersion = 3
	if ($connection.SessionOptions.ProtocolVersion -ne 3) {
		throw ("LDAP protocol version stayed at $($connection.SessionOptions.ProtocolVersion) " +
			'after being set to 3. Active Directory refuses LDAPv2 and reports it as a ' +
			'credential failure, so this is stopped here rather than at the bind.')
	}

	$connection.SessionOptions.ReferralChasing =
		[System.DirectoryServices.Protocols.ReferralChasingOptions]::None
	$connection.SessionOptions.SecureSocketLayer = [bool]$UseTls
	$connection.Timeout = [timespan]::FromSeconds($TimeoutSeconds)
	$connection.AuthType = [System.DirectoryServices.Protocols.AuthType]::$AuthType

	if ($AuthType -eq 'Basic') {
		if (-not $Credential) {
			throw 'A Basic bind needs a credential.'
		}
		$net = $Credential.GetNetworkCredential()
		$connection.Bind([System.Net.NetworkCredential]::new($net.UserName, $net.Password))
	}
	elseif ($AuthType -eq 'Negotiate') {
		# Measurement 7: an explicit credential here returns rc 92. The only
		# working Negotiate is the ambient one, so a credential is refused
		# rather than silently ignored.
		if ($Credential) {
			throw ('A Negotiate bind cannot take a credential on this platform: .NET on Linux ' +
				'answers LDAP rc 92, LDAP_NOT_SUPPORTED. Obtain a ticket first and bind ' +
				'without one.')
		}
		$connection.Bind()
	}
	else {
		$connection.Bind()
	}

	return $connection
}

function Invoke-DirectoryRequest {
	<#
	.SYNOPSIS
		Internal. Send one LDAP request and return its answer as plain rows,
		without judging it.

	.DESCRIPTION
		THE OTHER FUNCTION THAT TOUCHES System.DirectoryServices.Protocols,
		AND IT DECIDES NOTHING. It exists at exactly this size because
		SearchResultEntry has no public constructor (measured 2026-08-27), so
		the seam has to sit above the .NET boundary. That is only honest if
		everything above it is the whole of this module's judgement and
		everything below it is a transcription — which is what this is.

		Returns [pscustomobject]@{ Rows; Referrals; Cookie; ResponseValue },
		where each row is @{ Dn; Attributes } and Attributes maps a name to an
		object[] whose values are strings, except for the attributes named in
		$script:DirectoryBinaryAttributes, which are byte[]. Nothing here
		interprets either.

		ResponseValue IS HERE SO THAT Get-DirectoryWhoAmI CAN GO THROUGH THIS
		SEAM RATHER THAN ROUND IT. It is the raw octets of an ExtendedResponse
		and this function does not decode them — which keeps the promise above
		that everything below the seam is a transcription. A WhoAmI that called
		$Connection.SendRequest itself was a third function touching
		System.DirectoryServices.Protocols, and no fake connection could answer
		it, so the one call that proves WHO the server thinks a session is was
		the one call no test could reach.
	#>
	param(
		[Parameter(Mandatory)]$Connection,
		[Parameter(Mandatory)]$Request
	)

	if ($script:DirectoryRequestOverride) {
		return & $script:DirectoryRequestOverride $Connection $Request
	}

	$response = $Connection.SendRequest($Request)

	$rows = [System.Collections.Generic.List[object]]::new()
	$referrals = [System.Collections.Generic.List[string]]::new()
	$cookie = $null
	$responseValue = $null

	if ($response -is [System.DirectoryServices.Protocols.ExtendedResponse]) {
		$responseValue = $response.ResponseValue
	}

	if ($response -is [System.DirectoryServices.Protocols.SearchResponse]) {
		foreach ($entry in $response.Entries) {
			$attributes = [ordered]@{}
			foreach ($name in $entry.Attributes.AttributeNames) {
				$attribute = $entry.Attributes[$name]
				if ($script:DirectoryBinaryAttributes -contains $name) {
					$attributes[$name] = $attribute.GetValues([byte[]])
				}
				else {
					$attributes[$name] = $attribute.GetValues([string])
				}
			}
			$rows.Add([pscustomobject]@{ Dn = $entry.DistinguishedName; Attributes = $attributes })
		}
		foreach ($uri in $response.References) {
			foreach ($one in $uri.Reference) { $referrals.Add([string]$one) }
		}
		foreach ($control in $response.Controls) {
			if ($control -is [System.DirectoryServices.Protocols.PageResultResponseControl]) {
				$cookie = $control.Cookie
			}
		}
	}

	return [pscustomobject]@{
		Rows          = $rows
		Referrals     = $referrals
		Cookie        = $cookie
		ResponseValue = $responseValue
	}
}

# ---------------------------------------------------------------------------
# Escaping — the two RFCs, and the reason they are separate functions
# ---------------------------------------------------------------------------

function ConvertTo-DirectoryFilterValue {
	<#
	.SYNOPSIS
		Escape a value for use inside an LDAP search filter (RFC 4515).

	.DESCRIPTION
		The five characters that must go are ( ) * \ and NUL, and they become
		\28 \29 \2a \5c \00. The one that matters is the asterisk: a caller
		searching for a user whose name contains one has NOT asked for a
		wildcard, and a filter assembled by concatenation turns their input
		into a query for something else. This is the AD analogue of the YAML
		escaping in New-NetplanDocument, and it is a separate function from
		the DN escaping below because the two rules are genuinely different —
		a comma must be escaped in a DN and must not be in a filter.
	#>
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

	$builder = [System.Text.StringBuilder]::new()
	foreach ($character in $Value.ToCharArray()) {
		switch ($character) {
			'(' { [void]$builder.Append('\28') }
			')' { [void]$builder.Append('\29') }
			'*' { [void]$builder.Append('\2a') }
			'\' { [void]$builder.Append('\5c') }
			"`0" { [void]$builder.Append('\00') }
			default { [void]$builder.Append($character) }
		}
	}
	return $builder.ToString()
}

function ConvertTo-DirectoryDnValue {
	<#
	.SYNOPSIS
		Escape one RDN value for use in a distinguished name (RFC 4514).

	.DESCRIPTION
		A comma, plus, quote, backslash, angle bracket, semicolon or equals
		sign inside a value; a space or hash at the start; a space at the end.
		The case this exists for is a person called "Lovelace, Ada" — an
		unescaped comma does not fail, it silently addresses a different
		object, one level up.
	#>
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

	$builder = [System.Text.StringBuilder]::new()
	$characters = $Value.ToCharArray()
	for ($index = 0; $index -lt $characters.Length; $index++) {
		$character = $characters[$index]
		$isFirst = ($index -eq 0)
		$isLast = ($index -eq $characters.Length - 1)
		if ($character -in ',', '+', '"', '\', '<', '>', ';', '=') {
			[void]$builder.Append('\').Append($character)
		}
		elseif ($isFirst -and ($character -eq ' ' -or $character -eq '#')) {
			[void]$builder.Append('\').Append($character)
		}
		elseif ($isLast -and $character -eq ' ') {
			[void]$builder.Append('\ ')
		}
		elseif ($character -eq "`0") {
			[void]$builder.Append('\00')
		}
		else {
			[void]$builder.Append($character)
		}
	}
	return $builder.ToString()
}

function Split-DirectoryDn {
	<#
	.SYNOPSIS
		Split a distinguished name into its components, honouring escapes.

	.DESCRIPTION
		A naive `-split ','` is wrong for exactly the name ConvertTo-DirectoryDnValue
		exists to produce: `CN=Lovelace\, Ada,OU=People,DC=os7,DC=test` has
		four components, not five. Returns the components as written, escapes
		intact, because a caller reassembling a DN must not have them removed.
	#>
	param([Parameter(Mandatory)][string]$DistinguishedName)

	$parts = [System.Collections.Generic.List[string]]::new()
	$current = [System.Text.StringBuilder]::new()
	$escaped = $false
	foreach ($character in $DistinguishedName.ToCharArray()) {
		if ($escaped) {
			[void]$current.Append($character)
			$escaped = $false
			continue
		}
		if ($character -eq '\') {
			[void]$current.Append($character)
			$escaped = $true
			continue
		}
		if ($character -eq ',') {
			$parts.Add($current.ToString())
			[void]$current.Clear()
			continue
		}
		[void]$current.Append($character)
	}
	if ($current.Length -gt 0) { $parts.Add($current.ToString()) }
	return $parts.ToArray()
}

function ConvertTo-DirectoryDomainDn {
	<#
	.SYNOPSIS
		A DNS domain name as a distinguished name: os7.test -> DC=os7,DC=test.
	#>
	param([Parameter(Mandatory)][string]$DnsDomain)

	$labels = $DnsDomain.Trim('.').Split('.') | Where-Object { $_ -ne '' }
	if (@($labels).Count -eq 0) {
		throw "'$DnsDomain' has no labels and cannot become a distinguished name."
	}
	$components = foreach ($label in $labels) { 'DC=' + (ConvertTo-DirectoryDnValue -Value $label) }
	return (@($components) -join ',')
}

# ---------------------------------------------------------------------------
# Attribute reading — the #92 guards
#
# Two functions and not one, for the reason Net.psm1 gives about the same
# class of bug: `return @($rows)` unwraps a one-element array on the way out,
# the caller gets a [string], and [0] indexes into a character. A group with
# one member is the case that finds it, and a lab domain always has one.
# ---------------------------------------------------------------------------

function Get-DirectoryAttributeValues {
	<#
	.SYNOPSIS
		Every value of one attribute, ALWAYS as an array — empty when absent.

	.DESCRIPTION
		"ALWAYS AS AN ARRAY" IS A CONTRACT WITH THE CALL SITE, NOT WITH THE
		RETURN STATEMENT, AND THAT IS NOT A DODGE — IT IS THE ONLY VERSION OF
		THIS THAT IS TRUE. PowerShell unrolls an array on the way OUT of a
		function, so `$v = Get-DirectoryAttributeValues …` on a single-valued
		attribute hands back a [string] and $v[0] is a character: BUILD-NOTES
		#92, in the function written to guard against it. `return , $array`
		fixes exactly that — and BREAKS every caller here, all of which write
		@(Get-DirectoryAttributeValues …). Measured on pwsh 7.6.5, 2026-08-28:

		    return @($v)  ->  $x = f is String;      @(f) is the values      OK
		    return ,$v    ->  $x = f is Object[];    @(f) is ONE nested array

		so with the comma, @(…).Count is 1 for a group of three, which is what
		powershell/OS7/OS7.DirectoryObject.ps1 publishes as MemberCount. The two
		spellings cannot both be had, and swapping them is a migration of every
		call site in one commit, not a one-line fix here: the five in
		OS7.DirectoryObject.ps1 and the three in this file would each have to
		drop their @(…). Until somebody does both halves, this stays the half
		every caller is written against.

		THE CASES BELOW ARE WHAT STOPS HALF OF THAT MIGRATION LANDING. Adding
		the comma without touching the callers fails 'a group with ONE member is
		a one-element list' and 'a missing attribute has Count 0' — which is how
		this note came to be written rather than the comma.
	#>
	param(
		[Parameter(Mandatory)]$Attributes,
		[Parameter(Mandatory)][string]$Name
	)

	if ($null -eq $Attributes) { return @() }
	if (-not $Attributes.Contains($Name)) { return @() }
	$value = $Attributes[$Name]
	if ($null -eq $value) { return @() }
	return @($value)
}

function Get-DirectoryAttributeScalar {
	<#
	.SYNOPSIS
		The first value of one attribute, or $null. Never a character.
	#>
	param(
		[Parameter(Mandatory)]$Attributes,
		[Parameter(Mandatory)][string]$Name
	)

	$values = @(Get-DirectoryAttributeValues -Attributes $Attributes -Name $Name)
	if ($values.Count -eq 0) { return $null }
	return $values[0]
}

# ---------------------------------------------------------------------------
# Conversions — every one returns $null on failure rather than throwing or
# guessing, and every numeric parse is INVARIANT (Time.psm1's rule: a machine
# whose decimal separator is a comma is every German desktop this is aimed at)
# ---------------------------------------------------------------------------

function ConvertTo-DirectoryInt64 {
	<#
	.SYNOPSIS
		Internal. An LDAP integer string, parsed invariantly. $null on failure.
	#>
	param([AllowNull()][AllowEmptyString()]$Value)

	if ($null -eq $Value) { return $null }
	$text = [string]$Value
	if ($text.Trim() -eq '') { return $null }
	$parsed = [int64]0
	if ([int64]::TryParse($text, [System.Globalization.NumberStyles]::Integer,
			[System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
		return $parsed
	}
	return $null
}

function ConvertFrom-DirectoryFileTime {
	<#
	.SYNOPSIS
		An AD FILETIME (100-ns ticks since 1601) as a DateTime, or $null.

	.DESCRIPTION
		BOTH 0 AND 0x7FFFFFFFFFFFFFFF MEAN "NEVER", and neither means 1601.
		accountExpires uses the maximum, pwdLastSet uses zero for "must change
		at next logon", and a cast would render both as a date in the
		seventeenth century that an operator would read as a real answer.
		That is why this is a function and not [datetime]::FromFileTimeUtc.
	#>
	param([AllowNull()]$Value)

	$ticks = ConvertTo-DirectoryInt64 -Value $Value
	if ($null -eq $ticks) { return $null }
	if ($ticks -le 0 -or $ticks -ge 9223372036854775807) { return $null }
	try { return [datetime]::FromFileTimeUtc($ticks) } catch { return $null }
}

function ConvertFrom-DirectoryGeneralizedTime {
	<#
	.SYNOPSIS
		An LDAP generalized time (20260827190803.0Z) as a DateTime, or $null.
	#>
	param([AllowNull()][AllowEmptyString()]$Value)

	if ($null -eq $Value) { return $null }
	$text = ([string]$Value).Trim()
	if ($text -eq '') { return $null }
	# [string[]] IS LOAD-BEARING AND WAS FOUND BY THIS MODULE'S OWN SELF-TEST.
	# TryParseExact is overloaded on (string, string, ...) and (string,
	# string[], ...). Handed a plain PowerShell @(...) — which is object[] —
	# the binder prefers the SINGLE-format overload and converts the array to
	# one string by joining it with spaces, so the format becomes the literal
	# 'yyyyMMddHHmmss.fZ yyyyMMddHHmmssZ ...' and nothing on earth matches it.
	# There is no type error and no exception: every timestamp simply comes
	# back $null, which reads as "this DC does not send whenCreated".
	# Measured 2026-08-27: object[] -> False, [string[]] -> True, same input.
	[string[]]$formats = @('yyyyMMddHHmmss.fZ', 'yyyyMMddHHmmss.ffZ', 'yyyyMMddHHmmss.fffZ',
		'yyyyMMddHHmmssZ', 'yyyyMMddHHmmss.f\Z')
	$parsed = [datetime]::MinValue
	if ([datetime]::TryParseExact($text, $formats,
			[System.Globalization.CultureInfo]::InvariantCulture,
			[System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
			[System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
		return $parsed
	}
	return $null
}

function ConvertFrom-DirectorySid {
	<#
	.SYNOPSIS
		An objectSid byte array as S-1-5-21-... , or $null.

	.DESCRIPTION
		Byte 0 is the revision, byte 1 the sub-authority count, bytes 2..7 the
		identifier authority BIG-endian, and every sub-authority after that
		LITTLE-endian. The two endiannesses in one structure are the whole
		reason this is written out rather than done with a cast.
	#>
	param([AllowNull()]$Bytes)

	if ($null -eq $Bytes) { return $null }
	$raw = [byte[]]$Bytes
	if ($raw.Length -lt 8) { return $null }

	$revision = $raw[0]
	$subCount = $raw[1]
	if ($raw.Length -lt (8 + 4 * $subCount)) { return $null }

	$authority = [int64]0
	for ($index = 2; $index -le 7; $index++) {
		$authority = ($authority -shl 8) -bor $raw[$index]
	}

	$builder = [System.Text.StringBuilder]::new()
	[void]$builder.Append('S-').Append($revision).Append('-').Append($authority)
	for ($sub = 0; $sub -lt $subCount; $sub++) {
		$offset = 8 + 4 * $sub
		$value = [uint32]$raw[$offset] -bor
		([uint32]$raw[$offset + 1] -shl 8) -bor
		([uint32]$raw[$offset + 2] -shl 16) -bor
		([uint32]$raw[$offset + 3] -shl 24)
		[void]$builder.Append('-').Append($value)
	}
	return $builder.ToString()
}

function ConvertFrom-DirectoryGuid {
	<#
	.SYNOPSIS
		An objectGUID byte array as a GUID string, or $null.
	#>
	param([AllowNull()]$Bytes)

	if ($null -eq $Bytes) { return $null }
	$raw = [byte[]]$Bytes
	if ($raw.Length -ne 16) { return $null }
	try { return ([guid]::new($raw)).ToString() } catch { return $null }
}

# ---------------------------------------------------------------------------
# userAccountControl, and the bit that lies
# ---------------------------------------------------------------------------

$script:DirectoryAccountControlFlags = [ordered]@{
	'SCRIPT'                         = 0x00000001
	'ACCOUNTDISABLE'                 = 0x00000002
	'HOMEDIR_REQUIRED'               = 0x00000008
	'LOCKOUT'                        = 0x00000010
	'PASSWD_NOTREQD'                 = 0x00000020
	'PASSWD_CANT_CHANGE'             = 0x00000040
	'ENCRYPTED_TEXT_PWD_ALLOWED'     = 0x00000080
	'TEMP_DUPLICATE_ACCOUNT'         = 0x00000100
	'NORMAL_ACCOUNT'                 = 0x00000200
	'INTERDOMAIN_TRUST_ACCOUNT'      = 0x00000800
	'WORKSTATION_TRUST_ACCOUNT'      = 0x00001000
	'SERVER_TRUST_ACCOUNT'           = 0x00002000
	'DONT_EXPIRE_PASSWORD'           = 0x00010000
	'MNS_LOGON_ACCOUNT'              = 0x00020000
	'SMARTCARD_REQUIRED'             = 0x00040000
	'TRUSTED_FOR_DELEGATION'         = 0x00080000
	'NOT_DELEGATED'                  = 0x00100000
	'USE_DES_KEY_ONLY'               = 0x00200000
	'DONT_REQ_PREAUTH'               = 0x00400000
	'PASSWORD_EXPIRED'               = 0x00800000
	'TRUSTED_TO_AUTH_FOR_DELEGATION' = 0x01000000
}

function Get-DirectoryAccountControl {
	<#
	.SYNOPSIS
		Decode userAccountControl into named flags and the two answers an
		operator actually asks for.

	.DESCRIPTION
		THE LOCKOUT BIT IN userAccountControl DOES NOT REPORT A LOCKED
		ACCOUNT. Active Directory does not maintain 0x10; the authoritative
		answer is the lockoutTime attribute, which is why Enabled comes from
		this function and Locked does not. A surface that read the flag would
		tell an operator their locked-out user is fine — the #85 shape, where
		every declaration is satisfied and the thing they were about is
		decided somewhere else.

		Returns $null when the attribute was absent, which is not the same as
		zero and must not be rendered as "everything is off".
	#>
	param([AllowNull()]$Value)

	$numeric = ConvertTo-DirectoryInt64 -Value $Value
	if ($null -eq $numeric) { return $null }

	$flags = [System.Collections.Generic.List[string]]::new()
	foreach ($name in $script:DirectoryAccountControlFlags.Keys) {
		if (($numeric -band $script:DirectoryAccountControlFlags[$name]) -ne 0) {
			$flags.Add($name)
		}
	}

	return [pscustomobject]@{
		Value              = $numeric
		Flags              = $flags.ToArray()
		Enabled            = (($numeric -band 0x00000002) -eq 0)
		PasswordNeverExpires = (($numeric -band 0x00010000) -ne 0)
		SmartcardRequired  = (($numeric -band 0x00040000) -ne 0)
		PasswordNotRequired = (($numeric -band 0x00000020) -ne 0)
	}
}

# ---------------------------------------------------------------------------
# What an LdapException MEANS
# ---------------------------------------------------------------------------

$script:DirectoryBindSubCodes = @{
	'525' = 'the account does not exist'
	'52e' = 'the password is wrong'
	'530' = 'the account may not sign in at this time of day'
	'531' = 'the account may not sign in from this workstation'
	'532' = 'the password has expired'
	'533' = 'the account is disabled'
	'701' = 'the account has expired'
	'773' = 'the password must be changed before the account can be used'
	'775' = 'the account is locked out'
}

function Get-DirectoryLdapException {
	<#
	.SYNOPSIS
		Internal. Dig the LdapException out of whatever PowerShell wrapped it in.

	.DESCRIPTION
		A TRAP WORTH THE FUNCTION. `catch [System.DirectoryServices.Protocols.LdapException]`
		DOES match when a .NET method call threw one — PowerShell looks
		through the wrapper to decide — but inside that catch block
		$_.Exception is still the MethodInvocationException. Reading
		$_.Exception.ErrorCode therefore throws "The property 'ErrorCode'
		cannot be found on this object" under Set-StrictMode, INSIDE the
		handler that was supposed to explain the failure. The operator then
		sees a PowerShell property error where a password message belonged.

		Measured 2026-08-27 against a real DC with a deliberately wrong
		password, which is how this was found.
	#>
	param([AllowNull()]$Exception)

	$current = $Exception
	for ($depth = 0; $depth -lt 8 -and $null -ne $current; $depth++) {
		if ($current -is [System.DirectoryServices.Protocols.LdapException]) { return $current }
		# Set-StrictMode makes a missing property an ERROR, not $null, and
		# callers pass synthetic objects that have no InnerException at all.
		if (-not $current.PSObject.Properties['InnerException']) { break }
		$current = $current.InnerException
	}
	return $Exception
}

function Get-DirectoryErrorMeaning {
	<#
	.SYNOPSIS
		Turn an LdapException into a sentence about what is wrong.

	.DESCRIPTION
		ACTIVE DIRECTORY RETURNS 49 FOR NINE DIFFERENT THINGS, and the only
		thing that distinguishes "wrong password" from "locked out" is a
		three-hex-digit sub-code buried in the server's message:

		    80090308: LdapErr=DSID-0C0903A9, comment: AcceptSecurityContext
		    error, data 775, v4563

		An operator told "invalid credentials" for a locked account will reset
		a password that was never wrong. Returns @{ Code; SubCode; Meaning },
		with Meaning $null when the code is not one this knows — "cannot tell"
		is not "clean", so it must not invent a sentence.
	#>
	param([Parameter(Mandatory)]$Exception)

	$ldap = Get-DirectoryLdapException -Exception $Exception

	$code = $null
	$message = ''
	if ($ldap.PSObject.Properties['ErrorCode']) { $code = $ldap.ErrorCode }
	if ($ldap.PSObject.Properties['Message']) { $message = [string]$ldap.Message }
	if ($ldap.PSObject.Properties['ServerErrorMessage'] -and $ldap.ServerErrorMessage) {
		$message = $message + ' ' + [string]$ldap.ServerErrorMessage
	}

	$subCode = $null
	$match = [regex]::Match($message, 'data\s+([0-9a-fA-F]{3,4})')
	if ($match.Success) { $subCode = $match.Groups[1].Value.ToLowerInvariant() }

	$meaning = $null
	if ($subCode -and $script:DirectoryBindSubCodes.ContainsKey($subCode)) {
		$meaning = $script:DirectoryBindSubCodes[$subCode]
	}
	elseif ($code -eq 49) {
		$meaning = 'the credential was refused, and the server did not say why'
	}
	elseif ($code -eq 8) {
		$meaning = 'the server requires a stronger authentication than this connection offers'
	}
	elseif ($code -eq 10) {
		$meaning = 'the server referred the request elsewhere'
	}
	elseif ($code -eq 50) {
		$meaning = 'the account that is signed in may not do this'
	}
	elseif ($code -eq 53) {
		$meaning = 'the server refused: an unencrypted channel, or a policy violation'
	}
	elseif ($code -eq 68) {
		$meaning = 'an object with that name already exists'
	}
	elseif ($code -eq 32) {
		$meaning = 'no such object'
	}
	elseif ($code -eq 92) {
		$meaning = 'this platform does not support that authentication method'
	}

	return [pscustomobject]@{
		Code    = $code
		SubCode = $subCode
		Meaning = $meaning
	}
}

# ---------------------------------------------------------------------------
# The public surface
# ---------------------------------------------------------------------------

function Connect-DirectoryServer {
	<#
	.SYNOPSIS
		Open a bound connection to an LDAP server and return a session object.

	.DESCRIPTION
		TLS IS THE DEFAULT AND IT IS NOT A PREFERENCE. Measurement 4 in this
		file's header: sign-and-seal cannot be switched on from .NET on Linux,
		and a hardened Active Directory (LDAPServerIntegrity = 2, which is
		Microsoft's own ADV190023 guidance) refuses an unsigned simple bind on
		port 389 outright. So 636 with TLS is what this does unless the caller
		asks for otherwise in as many words.

		CERTIFICATE TRUST IS NOT DECIDED HERE, AND IT CANNOT BE SCOPED TO ONE
		CALL. Three measurements, 2026-08-27, against a real DC:

		  * SessionOptions.VerifyServerCertificate throws on this platform, so
		    there is no callback to accept or reject a chain.
		  * Trust is therefore OpenLDAP's, and it reads it from TLS_CACERT in
		    /etc/ldap/ldap.conf, from the system CA store, or from the
		    LDAPTLS_CACERT environment variable. All three were measured to
		    work when set before the process started.
		  * SETTING THAT VARIABLE FROM INSIDE POWERSHELL DOES NOTHING. .NET on
		    Unix keeps its own copy of the environment and does not call
		    setenv(3), so no native library ever sees it — while
		    [Environment]::GetEnvironmentVariable cheerfully reads the value
		    back. A real setenv(3) does work, but only before the first LDAP
		    call in the process, because OpenLDAP reads its environment once
		    in ldap_int_initialize().

		So trust is a MACHINE operation, not a parameter, and the OS7 layer
		above owns it. What this function does instead is refuse to let the
		resulting failure lie: OpenLDAP reports an untrusted certificate as
		"The LDAP server is unavailable.", which sends an operator to look at
		firewalls and routes for a problem that is a missing CA.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Server,
		[pscredential]$Credential,
		[int]$Port = 0,
		[ValidateSet('Basic', 'Negotiate', 'Anonymous')][string]$AuthType = 'Basic',
		[switch]$NoTls,
		[int]$TimeoutSeconds = 30
	)

	$useTls = -not $NoTls
	$effectivePort = $Port
	if ($effectivePort -eq 0) { $effectivePort = $(if ($useTls) { 636 } else { 389 }) }

	try {
		$connection = New-DirectoryConnection -Server $Server -Port $effectivePort `
			-UseTls:$useTls -Credential $Credential -AuthType $AuthType `
			-TimeoutSeconds $TimeoutSeconds
	}
	catch [System.DirectoryServices.Protocols.LdapException] {
		# $_.Exception is the WRAPPER here, not the LdapException — see
		# Get-DirectoryLdapException. Reading .ErrorCode off it throws.
		$ldapError = Get-DirectoryLdapException -Exception $_.Exception
		$meaning = Get-DirectoryErrorMeaning -Exception $ldapError
		if ($useTls -and $meaning.Code -eq 81) {
			throw ("Could not open a TLS connection to '$Server' on port $effectivePort. " +
				'OpenLDAP reports an untrusted or unverifiable server certificate with the ' +
				'same message it uses for a server that is not there, so this may be either. ' +
				"Check that the domain controller's issuing CA is trusted by this machine — " +
				'that is a machine-wide setting, and it cannot be supplied per call on this ' +
				"platform. Underlying error: $($ldapError.Message)")
		}
		if ($meaning.Meaning) {
			throw ("The directory refused the connection: $($meaning.Meaning) " +
				"(LDAP $($meaning.Code)$(if ($meaning.SubCode) { ", data $($meaning.SubCode)" })).")
		}
		throw
	}

	$identity = $null
	if ($Credential) { $identity = $Credential.UserName }

	return [pscustomobject]@{
		PSTypeName = 'Directory.Session'
		Server     = $Server
		Port       = $effectivePort
		Tls        = $useTls
		AuthType   = $AuthType
		Identity   = $identity
		Connection = $connection
		Opened     = [datetime]::UtcNow
	}
}

function Disconnect-DirectoryServer {
	<#
	.SYNOPSIS
		Close a session's connection. Safe to call twice.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory, ValueFromPipeline)]$Session)

	process {
		if ($null -eq $Session) { return }
		$connection = $null
		if ($Session.PSObject.Properties['Connection']) { $connection = $Session.Connection }
		if ($connection -and $connection -is [System.IDisposable]) {
			try { $connection.Dispose() } catch { }
		}
	}
}

function Get-DirectoryWhoAmI {
	<#
	.SYNOPSIS
		Ask the SERVER who it thinks this connection is (RFC 4532).

	.DESCRIPTION
		A bind that returns without an exception is not proof of identity — it
		is proof that no exception was raised. This is the server's own answer,
		and it is what a session check should print rather than the name that
		was typed in.

		IT GOES THROUGH Invoke-DirectoryRequest LIKE EVERYTHING ELSE. Calling
		$Session.Connection.SendRequest here made this a third function touching
		System.DirectoryServices.Protocols where the file header promises two,
		and it put the one question that distinguishes a real bind from a
		silent fall-back to anonymous beyond the reach of every fake connection.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory)]$Session)

	$request = [System.DirectoryServices.Protocols.ExtendedRequest]::new('1.3.6.1.4.1.4203.1.11.3')
	$answer = Invoke-DirectoryRequest -Connection $Session.Connection -Request $request

	# A SEAM THAT DOES NOT CARRY ResponseValue CANNOT ANSWER THIS, AND $null
	# WOULD READ AS "the server said nothing" — which callers treat as an
	# anonymous bind and refuse the session over. Set-StrictMode makes the
	# missing property an error rather than $null, so the distinction is made
	# here, in words, instead of surfacing as a property name.
	if (-not $answer.PSObject.Properties['ResponseValue']) {
		throw ('The request seam answered without a ResponseValue field, so this is a fake ' +
			'that does not model an extended request. RFC 4532 is the only thing that says ' +
			'who the server thinks this connection is, and returning $null here would be ' +
			'indistinguishable from an anonymous bind.')
	}
	if ($null -eq $answer.ResponseValue) { return $null }
	return [System.Text.Encoding]::UTF8.GetString($answer.ResponseValue)
}

function Get-DirectoryRootDse {
	<#
	.SYNOPSIS
		The server's own description of itself: naming contexts, functional
		levels, the DC's name.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory)]$Session)

	$rows = @(Search-Directory -Session $Session -SearchBase '' -Filter '(objectClass=*)' `
			-Scope Base -Property @('defaultNamingContext', 'configurationNamingContext',
			'schemaNamingContext', 'rootDomainNamingContext', 'dnsHostName',
			'serverName', 'domainFunctionality', 'forestFunctionality',
			'domainControllerFunctionality', 'supportedSASLMechanisms',
			'supportedLDAPVersion', 'currentTime'))

	if ($rows.Count -eq 0) { return $null }
	$attributes = $rows[0].Attributes

	return [pscustomobject]@{
		PSTypeName                = 'Directory.RootDse'
		DefaultNamingContext      = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'defaultNamingContext'
		ConfigurationNamingContext = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'configurationNamingContext'
		SchemaNamingContext       = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'schemaNamingContext'
		RootDomainNamingContext   = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'rootDomainNamingContext'
		DnsHostName               = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'dnsHostName'
		ServerName                = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'serverName'
		DomainFunctionality       = ConvertTo-DirectoryInt64 (Get-DirectoryAttributeScalar -Attributes $attributes -Name 'domainFunctionality')
		ForestFunctionality       = ConvertTo-DirectoryInt64 (Get-DirectoryAttributeScalar -Attributes $attributes -Name 'forestFunctionality')
		SupportedSaslMechanisms   = @(Get-DirectoryAttributeValues -Attributes $attributes -Name 'supportedSASLMechanisms')
		SupportedLdapVersion      = @(Get-DirectoryAttributeValues -Attributes $attributes -Name 'supportedLDAPVersion')
		CurrentTime               = ConvertFrom-DirectoryGeneralizedTime (Get-DirectoryAttributeScalar -Attributes $attributes -Name 'currentTime')
	}
}

function Search-Directory {
	<#
	.SYNOPSIS
		Run one LDAP search, following the pages to the end.

	.DESCRIPTION
		PAGING IS NOT OPTIONAL AND A LABORATORY WILL HIDE THAT. Active
		Directory's MaxPageSize defaults to 1000: a search that works
		perfectly against a test domain of twenty objects silently returns the
		first thousand of a real one — no error, no exception, a short list.
		This is BUILD-NOTES #89's shape, where code that has only ever seen
		one page has not been tested.

		REFERRALS ARE RETURNED AS DATA, NEVER FOLLOWED. Chasing them is the
		platform default (measurement 6) and it opens a second, unauthenticated
		connection behind the caller's back. Every search against a domain
		root gets three of them.

		-SizeLimit IS ENFORCED IN THIS PROCESS AND NOT BY THE SERVER, which is
		a decision and not an oversight. SearchRequest.SizeLimit makes the
		DIRECTORY stop, and a directory that stops answers sizeLimitExceeded —
		LDAP 4 — which S.DS.Protocols raises as an exception, so "give me the
		first ten" would come back as a failed search rather than as ten rows.
		That behaviour has NOT been measured against a domain controller from
		here, so the bound is applied where the behaviour is certain: the pages
		are asked no larger than the limit, and the rows are cut to it before
		they are returned. Setting it alone was not enough — it used to break
		out of the paging loop and hand back the whole first page.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)]$Session,
		[Parameter(Mandatory)][AllowEmptyString()][string]$SearchBase,
		[Parameter(Mandatory)][string]$Filter,
		[ValidateSet('Base', 'OneLevel', 'Subtree')][string]$Scope = 'Subtree',
		[string[]]$Property = @(),
		[int]$PageSize = 500,
		[int]$SizeLimit = 0
	)

	if ($null -eq $Session) { throw 'A search needs a session.' }
	if ($null -eq $SearchBase) { throw 'A search needs a base, even an empty one for the rootDSE.' }

	$request = [System.DirectoryServices.Protocols.SearchRequest]::new(
		$SearchBase, $Filter,
		[System.DirectoryServices.Protocols.SearchScope]::$Scope, $Property)

	$effectivePageSize = $PageSize
	if ($SizeLimit -gt 0 -and $SizeLimit -lt $effectivePageSize) { $effectivePageSize = $SizeLimit }

	$pageControl = $null
	if ($Scope -ne 'Base') {
		$pageControl = [System.DirectoryServices.Protocols.PageResultRequestControl]::new($effectivePageSize)
		[void]$request.Controls.Add($pageControl)
	}

	$collected = [System.Collections.Generic.List[object]]::new()
	$referrals = [System.Collections.Generic.List[string]]::new()
	$pages = 0

	while ($true) {
		$answer = Invoke-DirectoryRequest -Connection $Session.Connection -Request $request
		$pages++
		foreach ($row in $answer.Rows) { $collected.Add($row) }
		foreach ($referral in $answer.Referrals) { $referrals.Add($referral) }

		if ($SizeLimit -gt 0 -and $collected.Count -ge $SizeLimit) { break }
		if ($null -eq $pageControl) { break }
		if ($null -eq $answer.Cookie -or $answer.Cookie.Length -eq 0) { break }
		$pageControl.Cookie = $answer.Cookie
	}

	# THE CUT, and it is what makes the parameter mean anything: a page is
	# whatever the directory chose to send, so stopping the loop bounds the
	# number of ROUND TRIPS and not the number of rows.
	if ($SizeLimit -gt 0 -and $collected.Count -gt $SizeLimit) {
		$collected.RemoveRange($SizeLimit, $collected.Count - $SizeLimit)
	}

	foreach ($row in $collected) {
		$row | Add-Member -NotePropertyName 'Referrals' -NotePropertyValue $referrals.ToArray() -Force
		$row | Add-Member -NotePropertyName 'Pages' -NotePropertyValue $pages -Force
	}

	return $collected.ToArray()
}

function Get-DirectoryWritableValue {
	<#
	.SYNOPSIS
		Internal. One attribute value or many, as a list — with a byte[] kept
		WHOLE.

	.DESCRIPTION
		`foreach ($one in @($Value))` UNROLLS A BYTE ARRAY INTO ITS BYTES.
		Measured on pwsh 7.6.5: @([byte[]]@(1,2,3)).Count is 3. A binary
		attribute — a certificate, an objectSid, msDS-KeyCredentialLink — would
		therefore be written one value per byte, and the server's complaint
		would be about the attribute's syntax rather than about the client that
		took it apart. The same list is in $script:DirectoryBinaryAttributes,
		which is what Invoke-DirectoryRequest reads BACK as byte[].

		One rule, two callers, one spelling: New-DirectoryEntry and
		Set-DirectoryEntry both go through here, because a rule written twice
		taking two routes is BUILD-NOTES #66.
	#>
	param([AllowNull()]$Value)

	if ($null -eq $Value) { return , ([object[]]@()) }
	if ($Value -is [byte[]]) { return , ([object[]]@(, $Value)) }
	return , ([object[]]@($Value))
}

function New-DirectoryEntry {
	<#
	.SYNOPSIS
		Create one object.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)]$Session,
		[Parameter(Mandatory)][string]$DistinguishedName,
		[Parameter(Mandatory)][string[]]$ObjectClass,
		[hashtable]$Attribute = @{}
	)

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, 'create directory object')) {
		return $null
	}

	$request = [System.DirectoryServices.Protocols.AddRequest]::new($DistinguishedName, $ObjectClass)
	foreach ($name in $Attribute.Keys) {
		$values = Get-DirectoryWritableValue -Value $Attribute[$name]
		$attributeObject = [System.DirectoryServices.Protocols.DirectoryAttribute]::new()
		$attributeObject.Name = $name
		foreach ($value in $values) { [void]$attributeObject.Add($value) }
		[void]$request.Attributes.Add($attributeObject)
	}

	$null = Invoke-DirectoryRequest -Connection $Session.Connection -Request $request
	return $DistinguishedName
}

function Set-DirectoryEntry {
	<#
	.SYNOPSIS
		Modify attributes of one object.

	.DESCRIPTION
		-Operation is Replace, Add or Delete and it is not cosmetic: Replace on
		a multi-valued attribute discards every value the caller did not send.
		Adding one member to a group with Replace removes the rest, and the
		server reports success.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)]$Session,
		[Parameter(Mandatory)][string]$DistinguishedName,
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][AllowEmptyCollection()]$Value,
		[ValidateSet('Replace', 'Add', 'Delete')][string]$Operation = 'Replace'
	)

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, "$Operation $Name")) {
		return $null
	}

	$modification = [System.DirectoryServices.Protocols.DirectoryAttributeModification]::new()
	$modification.Name = $Name
	$modification.Operation = [System.DirectoryServices.Protocols.DirectoryAttributeOperation]::$Operation
	foreach ($one in (Get-DirectoryWritableValue -Value $Value)) {
		if ($null -ne $one) { [void]$modification.Add($one) }
	}

	$request = [System.DirectoryServices.Protocols.ModifyRequest]::new($DistinguishedName, $modification)
	$null = Invoke-DirectoryRequest -Connection $Session.Connection -Request $request
	return $DistinguishedName
}

function Remove-DirectoryEntry {
	<#
	.SYNOPSIS
		Delete one object.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory)]$Session,
		[Parameter(Mandatory)][string]$DistinguishedName
	)

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, 'delete directory object')) {
		return $null
	}

	$request = [System.DirectoryServices.Protocols.DeleteRequest]::new($DistinguishedName)
	$null = Invoke-DirectoryRequest -Connection $Session.Connection -Request $request
	return $DistinguishedName
}

function Move-DirectoryEntry {
	<#
	.SYNOPSIS
		Move or rename one object.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)]$Session,
		[Parameter(Mandatory)][string]$DistinguishedName,
		[Parameter(Mandatory)][string]$NewParentDistinguishedName,
		[string]$NewName
	)

	$components = @(Split-DirectoryDn -DistinguishedName $DistinguishedName)
	if ($components.Count -eq 0) { throw "'$DistinguishedName' is not a distinguished name." }
	$relativeName = $NewName
	if (-not $relativeName) { $relativeName = $components[0] }

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, "move to $NewParentDistinguishedName")) {
		return $null
	}

	$request = [System.DirectoryServices.Protocols.ModifyDNRequest]::new(
		$DistinguishedName, $NewParentDistinguishedName, $relativeName)
	$null = Invoke-DirectoryRequest -Connection $Session.Connection -Request $request
	return ($relativeName + ',' + $NewParentDistinguishedName)
}

function Set-DirectoryPassword {
	<#
	.SYNOPSIS
		Set an account's password through unicodePwd.

	.DESCRIPTION
		THREE TRAPS IN ONE OPERATION, and all three present as something else:

		  1. unicodePwd is a byte[] attribute — UTF-16LE, wrapped in literal
		     ASCII double quotes, no BOM, no terminator. Handing it a [string]
		     produces the wrong bytes and the server answers unwillingToPerform,
		     which reads as a permissions problem.
		  2. It requires a confidential channel. Over cleartext the server
		     refuses, and this refuses FIRST, so that the password is never
		     written to a socket that is not encrypted. That check is the
		     reason this function exists rather than a Set-DirectoryEntry call.
		  3. Setting a password as an administrator (Replace) and changing
		     one's own (Delete the old, Add the new) are different operations
		     with different rights. -Current selects the second.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)]$Session,
		[Parameter(Mandatory)][string]$DistinguishedName,
		[Parameter(Mandatory)][securestring]$NewPassword,
		[securestring]$CurrentPassword
	)

	if (-not $Session.Tls) {
		throw ('Refusing to send a password over an unencrypted connection. Active Directory ' +
			'would refuse it too, but only after it had crossed the network. Connect with ' +
			'TLS, which is the default.')
	}

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, 'set password')) {
		return $null
	}

	$newQuoted = '"' + ([System.Net.NetworkCredential]::new('', $NewPassword).Password) + '"'
	$newBytes = [System.Text.Encoding]::Unicode.GetBytes($newQuoted)

	if ($CurrentPassword) {
		$oldQuoted = '"' + ([System.Net.NetworkCredential]::new('', $CurrentPassword).Password) + '"'
		$oldBytes = [System.Text.Encoding]::Unicode.GetBytes($oldQuoted)

		$deletion = [System.DirectoryServices.Protocols.DirectoryAttributeModification]::new()
		$deletion.Name = 'unicodePwd'
		$deletion.Operation = [System.DirectoryServices.Protocols.DirectoryAttributeOperation]::Delete
		[void]$deletion.Add($oldBytes)

		$addition = [System.DirectoryServices.Protocols.DirectoryAttributeModification]::new()
		$addition.Name = 'unicodePwd'
		$addition.Operation = [System.DirectoryServices.Protocols.DirectoryAttributeOperation]::Add
		[void]$addition.Add($newBytes)

		$request = [System.DirectoryServices.Protocols.ModifyRequest]::new(
			$DistinguishedName, @($deletion, $addition))
	}
	else {
		$replacement = [System.DirectoryServices.Protocols.DirectoryAttributeModification]::new()
		$replacement.Name = 'unicodePwd'
		$replacement.Operation = [System.DirectoryServices.Protocols.DirectoryAttributeOperation]::Replace
		[void]$replacement.Add($newBytes)

		$request = [System.DirectoryServices.Protocols.ModifyRequest]::new(
			$DistinguishedName, $replacement)
	}

	$null = Invoke-DirectoryRequest -Connection $Session.Connection -Request $request
	return $DistinguishedName
}

# ---------------------------------------------------------------------------
# Realm membership: joining, the keytab, and Kerberos tickets
#
# A SECOND SEAM, AND A DIFFERENT KIND OF ONE. Everything above this line speaks
# LDAP over a socket. Everything below it starts a process — adcli, kinit,
# klist, getent — and so it uses the command-runner seam the other four generic
# modules use, for the reason Net.psm1 gives: replacing the runner rather than
# the parser puts invocation, exit codes and parsing all under test.
#
# WHY THIS IS IN THE GENERIC MODULE AND NOT IN OS7. Joining a host to a
# Kerberos realm with adcli and configuring sssd is ordinary Ubuntu; it would
# work on any host and knows nothing about OS/7. What is OS/7 policy — which
# domain, which organisational unit, which groups may sign in, and what a
# domain join does to a boot environment — lives in powershell/OS7/OS7.Domain.ps1.
# installer/testing/check-layering.py holds that line with the P2-directory
# rule, which forbids powershell/OS7 from naming any of these programs.
#
# ADCLI AND NOT REALMD, deliberately. realmd is a D-Bus service that wants to
# configure a running system and is awkward to drive against a chroot; adcli is
# a one-shot program that performs the join and writes a keytab, which is
# exactly the piece that cannot be written by hand. sssd.conf is written here
# rather than by realmd because its contents are policy — see Join-DirectoryRealm.
# ---------------------------------------------------------------------------

$script:DirectoryCommandOverride = $null

function Invoke-DirectoryCommand {
	<#
	.SYNOPSIS
		Internal. Run a program and return its stdout, stderr and exit code,
		without judging the exit code.
	#>
	param(
		[Parameter(Mandatory)][string]$Command,
		[string[]]$Arguments = @(),
		[string]$StandardInput
	)

	if ($script:DirectoryCommandOverride) {
		return & $script:DirectoryCommandOverride $Command $Arguments $StandardInput
	}

	$errFile = [System.IO.Path]::GetTempFileName()
	try {
		# Reset, then read guarded: $LASTEXITCODE is rewritten only when the
		# command COMPLETES through the pipeline (BUILD-NOTES #121). ExitCode
		# comes back $null — not a stale earlier code — when it never did,
		# and $null compares unequal to 0, so callers treat it as a failure.
		$global:LASTEXITCODE = $null
		if ($PSBoundParameters.ContainsKey('StandardInput')) {
			$out = ($StandardInput | & $Command @Arguments 2> $errFile)
		}
		else {
			$out = & $Command @Arguments 2> $errFile
		}
		return [pscustomobject]@{
			StdOut   = ($out -join "`n")
			ExitCode = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }
			StdErr   = ((Get-Content -Raw -ErrorAction SilentlyContinue $errFile) ?? '')
		}
	}
	finally {
		Remove-Item -Force -ErrorAction SilentlyContinue $errFile
	}
}

function Test-DirectoryTool {
	<#
	.SYNOPSIS
		Whether a program this module needs is present. Never throws.

	.DESCRIPTION
		adcli, kinit and sssd are NOT on every OS/7 image — they are the three
		packages a domain join adds, and an image without them is the normal
		case rather than a broken one. So the answer is data, and the caller
		reports "cannot tell" rather than a crash.
	#>
	param([Parameter(Mandatory)][string]$Name)

	return [bool](Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-DirectoryRealmConfiguration {
	<#
	.SYNOPSIS
		What this host is configured to believe about a realm, read off disk.

	.DESCRIPTION
		CONFIGURED, NOT EFFECTIVE — POWERSHELL-SURFACE-PLAN P6. This reads
		files; it does not ask a domain controller anything and does not
		report whether the join still works. Get-DirectoryRealmState is the
		other half, and the interesting machine is the one where the two
		disagree.
	#>
	param(
		[string]$SssdConfPath = '/etc/sssd/sssd.conf',
		[string]$KeytabPath = '/etc/krb5.keytab',
		[string]$Krb5ConfPath = '/etc/krb5.conf'
	)

	$domains = @()
	$sssdPresent = [System.IO.File]::Exists($SssdConfPath)
	if ($sssdPresent) {
		foreach ($line in [System.IO.File]::ReadAllLines($SssdConfPath)) {
			$match = [regex]::Match($line, '^\s*domains\s*=\s*(.+)$')
			if ($match.Success) {
				$domains = @($match.Groups[1].Value.Split(',') |
					ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
			}
		}
	}

	return [pscustomobject]@{
		PSTypeName      = 'Directory.RealmConfiguration'
		SssdConfPresent = $sssdPresent
		Domains         = $domains
		KeytabPresent   = [System.IO.File]::Exists($KeytabPath)
		KeytabPath      = $KeytabPath
		Krb5ConfPresent = [System.IO.File]::Exists($Krb5ConfPath)
	}
}

function Get-DirectoryKeytabPrincipal {
	<#
	.SYNOPSIS
		The principals in a keytab, read with klist -k.

	.DESCRIPTION
		THE KEYTAB IS THE MACHINE'S PASSWORD AND ITS EXISTENCE PROVES NOTHING.
		A file of the right name can be empty, can be left over from a previous
		join, or can hold a key version the domain controller has since rotated
		past. This lists what is actually in it; whether the controller still
		accepts it is Test-DirectoryRealmTicket's question, and they are
		different questions.
	#>
	param([string]$KeytabPath = '/etc/krb5.keytab')

	if (-not (Test-DirectoryTool -Name 'klist')) {
		return [pscustomobject]@{ Known = $false; Reason = 'klist is not installed'; Principal = @() }
	}
	if (-not [System.IO.File]::Exists($KeytabPath)) {
		return [pscustomobject]@{ Known = $true; Reason = 'no keytab'; Principal = @() }
	}

	$result = Invoke-DirectoryCommand -Command 'klist' -Arguments @('-k', $KeytabPath)
	if ($result.ExitCode -ne 0) {
		return [pscustomobject]@{
			Known     = $false
			Reason    = ("klist exited $($result.ExitCode): " + $result.StdErr.Trim())
			Principal = @()
		}
	}

	$principals = [System.Collections.Generic.List[string]]::new()
	foreach ($line in $result.StdOut.Split("`n")) {
		$match = [regex]::Match($line.Trim(), '^\s*(\d+)\s+(\S+@\S+)\s*$')
		if ($match.Success) { $principals.Add($match.Groups[2].Value) }
	}

	return [pscustomobject]@{
		Known     = $true
		Reason    = $null
		Principal = @($principals | Sort-Object -Unique)
	}
}

function Join-DirectoryRealm {
	<#
	.SYNOPSIS
		Join this host to a Kerberos realm with adcli, and write sssd's
		configuration for it.

	.DESCRIPTION
		THE PASSWORD NEVER APPEARS IN AN ARGUMENT LIST. adcli reads it from
		standard input with --stdin-password, so it is never in /proc, never in
		a process listing and never in a shell history.

		THE CHECK IS NOT adcli's EXIT CODE. After the join this reads the
		keytab back and lists its principals, because "adcli exited 0" and
		"this machine now has a usable machine account" are different claims,
		and every expensive bug in this repository is the gap between two such
		claims.

		-OneTimePassword is the path that needs no domain administrator at all:
		somebody pre-creates the computer account on the domain side and hands
		over a single-use password. It is the better road for a fleet and it is
		the one a text-mode installer should take.

		WHO MAY SIGN IN IS DECIDED BEFORE ANYTHING IS JOINED. The sssd document
		is rendered first, so New-DirectorySssdConfiguration's refusal — see its
		help — happens while this host is still not a member of anything. The
		other order performs the join, writes the machine credential, and then
		throws over the access rule, leaving a machine that is in the domain and
		configured by nothing.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$Domain,
		[string]$UserName,
		[securestring]$Password,
		[switch]$OneTimePassword,
		[string]$ComputerName,
		[string]$OrganizationalUnit,
		[string]$KeytabPath = '/etc/krb5.keytab',
		[string]$SssdConfPath = '/etc/sssd/sssd.conf',
		[string[]]$AllowGroup = @(),
		[switch]$AllowAllDomainUsers,
		[string]$HomeDirectoryTemplate,
		[string]$LoginShell = '/bin/bash'
	)

	if (-not (Test-DirectoryTool -Name 'adcli')) {
		throw ('adcli is not installed, so this host cannot join a realm. It is one of the ' +
			'packages a domain join adds; an image without it is not broken.')
	}

	if (-not $PSCmdlet.ShouldProcess($Domain, 'join realm')) { return $null }

	$sssdText = New-DirectorySssdConfiguration -Domain $Domain -AllowGroup $AllowGroup `
		-AllowAllDomainUsers:$AllowAllDomainUsers `
		-HomeDirectoryTemplate $HomeDirectoryTemplate -LoginShell $LoginShell

	$arguments = [System.Collections.Generic.List[string]]::new()
	$arguments.Add('join')
	$arguments.Add($Domain)
	$arguments.Add('--stdin-password')
	# --host-keytab OR adcli WRITES /etc/krb5.keytab NO MATTER WHAT -KeytabPath
	# SAYS. The parameter was only ever used to read the result back, so an
	# installer joining a target root wrote the machine credential onto the LIVE
	# machine, looked for it under the target, found nothing, and reported
	# Joined=$false for a join that had worked — while the running system
	# silently acquired a computer account it was never meant to have.
	if ($KeytabPath) { $arguments.Add('--host-keytab'); $arguments.Add($KeytabPath) }
	if ($ComputerName) { $arguments.Add('--computer-name'); $arguments.Add($ComputerName) }
	if ($OrganizationalUnit) { $arguments.Add('--domain-ou'); $arguments.Add($OrganizationalUnit) }
	if ($OneTimePassword) { $arguments.Add('--one-time-password') }
	elseif ($UserName) { $arguments.Add('--login-user'); $arguments.Add($UserName) }

	$plain = ''
	if ($Password) { $plain = [System.Net.NetworkCredential]::new('', $Password).Password }

	$result = Invoke-DirectoryCommand -Command 'adcli' -Arguments $arguments.ToArray() `
		-StandardInput $plain
	$plain = $null

	if ($result.ExitCode -ne 0) {
		throw ("adcli could not join '$Domain' (exit $($result.ExitCode)): " +
			$result.StdErr.Trim())
	}

	# 0600 BEFORE the content, never after: sssd refuses to start on a
	# world-readable configuration, and a file that is briefly readable is a
	# file that was readable.
	$directory = [System.IO.Path]::GetDirectoryName($SssdConfPath)
	if (-not [System.IO.Directory]::Exists($directory)) {
		[void][System.IO.Directory]::CreateDirectory($directory)
	}
	Set-Content -LiteralPath $SssdConfPath -Value '' -NoNewline
	& chmod 0600 $SssdConfPath
	Set-Content -LiteralPath $SssdConfPath -Value $sssdText

	# READ THE KEYTAB BACK. This is the whole point of the function's shape.
	$keytab = Get-DirectoryKeytabPrincipal -KeytabPath $KeytabPath

	return [pscustomobject]@{
		PSTypeName    = 'Directory.RealmJoin'
		Domain        = $Domain
		ComputerName  = $ComputerName
		KeytabPath    = $KeytabPath
		KeytabKnown   = $keytab.Known
		Principal     = $keytab.Principal
		SssdConfPath  = $SssdConfPath
		Joined        = ($keytab.Known -and @($keytab.Principal).Count -gt 0)
	}
}

function New-DirectorySssdConfiguration {
	<#
	.SYNOPSIS
		The text of an sssd.conf for a realm. A pure function, so it can be
		checked without a domain.

	.DESCRIPTION
		PURE ON PURPOSE, the same way New-NetplanDocument is: the document is
		the deliverable, the failure is a machine that configures with nothing
		and complains about nothing, and a pure function can be asserted
		character for character with no daemon anywhere.

		fallback_homedir is the line that matters most on OS/7 and it is not
		sssd's default. A domain user's home would otherwise be created by
		pam_mkhomedir INSIDE the boot environment, where Restore-OS7 rolls it
		back with the system — the exact outcome the dataset layout exists to
		prevent, arriving by a road nothing checks (BUILD-NOTES #74's shape).

		AN EMPTY ALLOW LIST IS NOT A CLOSED DOOR, AND THAT IS WHY THIS REFUSES.
		`access_provider = simple` with no simple_allow_groups grants a login to
		EVERY account in the directory. That is not read off documentation:
		measured on 2026-08-28 out of the shipped libsss_simple.so in
		installer/testing/Dockerfile.check-ad, which carries the sentence

		    No rules supplied for simple access provider.
		    Access will be granted for all users.

		So the caller says which groups, or says -AllowAllDomainUsers in as many
		words; there is no spelling of this call that opens the machine to the
		whole directory by leaving a parameter out. The failure this prevents is
		silent in both directions — nothing on the machine reports it, and the
		person who notices is whoever signs in who should not have been able to.
	#>
	param(
		[Parameter(Mandatory)][string]$Domain,
		[string[]]$AllowGroup = @(),
		[switch]$AllowAllDomainUsers,
		[string]$HomeDirectoryTemplate,
		[string]$LoginShell = '/bin/bash'
	)

	$groups = @($AllowGroup | Where-Object { $null -ne $_ -and $_.Trim() -ne '' })

	# A GROUP NAME WITH A COMMA IN IT BECOMES TWO GROUPS NOBODY HAS, and every
	# member of the real one is refused. simple_allow_groups is a comma list on
	# one line, so "Berlin, Sales" is read as two names; libsss_simple.so
	# answers that with "The group %s does not exist. Possible typo in
	# simple_allow_groups." in a debug log nobody has turned on, and the login
	# just fails. A line break is refused beside it because it would end the key
	# and turn the rest of the name into an sssd setting of its own.
	foreach ($group in $groups) {
		if ($group -match '[,\r\n]') {
			throw ("The group name '$group' contains a comma or a line break, and " +
				'simple_allow_groups is a comma-separated list on a single line. Written out ' +
				'it would become names no directory has, and every member of the real group ' +
				'would be refused a login with nothing on the machine saying why.')
		}
	}

	if ($groups.Count -eq 0 -and -not $AllowAllDomainUsers) {
		throw ('Refusing to write an sssd.conf that lets EVERY account in the directory sign ' +
			'in to this machine. access_provider = simple with no allow list is not a closed ' +
			'door — the shipped libsss_simple.so says "No rules supplied for simple access ' +
			'provider. Access will be granted for all users." Name the groups with ' +
			'-AllowGroup, or ask for -AllowAllDomainUsers in as many words.')
	}

	$homeTemplate = $HomeDirectoryTemplate
	if (-not $homeTemplate) { $homeTemplate = '/var/lib/os7/domain-homes/%u' }

	$lines = [System.Collections.Generic.List[string]]::new()
	$lines.Add('[sssd]')
	$lines.Add("domains = $Domain")
	$lines.Add('config_file_version = 2')
	$lines.Add('services = nss, pam')
	$lines.Add('')
	$lines.Add("[domain/$Domain]")
	$lines.Add('id_provider = ad')
	$lines.Add('auth_provider = ad')
	if ($groups.Count -eq 0) {
		# THE DECISION IS WRITTEN INTO THE DOCUMENT, not only into the call that
		# produced it. An operator reading a file with an access provider and no
		# rule under it cannot tell a deliberate choice from a rule that went
		# missing, and this is the one setting here where guessing wrong leaves
		# the machine open.
		$lines.Add('# -AllowAllDomainUsers: every account in the directory may sign in here.')
		$lines.Add('# sssd grants access when no allow list is set, so this is that, said out loud.')
	}
	$lines.Add('access_provider = simple')
	$lines.Add("default_shell = $LoginShell")
	$lines.Add("fallback_homedir = $homeTemplate")
	$lines.Add('use_fully_qualified_names = False')
	$lines.Add('ldap_id_mapping = True')
	$lines.Add('cache_credentials = True')
	$lines.Add('krb5_store_password_if_offline = True')
	if ($groups.Count -gt 0) {
		$lines.Add('simple_allow_groups = ' + ($groups -join ', '))
	}

	return (($lines -join "`n") + "`n")
}

function Remove-DirectoryRealm {
	<#
	.SYNOPSIS
		Leave a realm: delete the computer account and remove the keytab.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory)][string]$Domain,
		[string]$UserName,
		[securestring]$Password,
		[string]$KeytabPath = '/etc/krb5.keytab',
		[string]$SssdConfPath = '/etc/sssd/sssd.conf'
	)

	if (-not (Test-DirectoryTool -Name 'adcli')) { throw 'adcli is not installed.' }
	if (-not $PSCmdlet.ShouldProcess($Domain, 'leave realm')) { return $null }

	$arguments = @('delete-computer', '--domain', $Domain, '--stdin-password')
	if ($UserName) { $arguments += @('--login-user', $UserName) }

	$plain = ''
	if ($Password) { $plain = [System.Net.NetworkCredential]::new('', $Password).Password }
	$result = Invoke-DirectoryCommand -Command 'adcli' -Arguments $arguments -StandardInput $plain
	$plain = $null

	foreach ($path in @($KeytabPath, $SssdConfPath)) {
		if ([System.IO.File]::Exists($path)) { Remove-Item -LiteralPath $path -Force }
	}

	return [pscustomobject]@{
		PSTypeName        = 'Directory.RealmLeave'
		Domain            = $Domain
		ComputerAccountRemoved = ($result.ExitCode -eq 0)
		Detail            = $result.StdErr.Trim()
		KeytabRemoved     = (-not [System.IO.File]::Exists($KeytabPath))
	}
}

function Update-DirectoryRealm {
	<#
	.SYNOPSIS
		Renew this host's machine account password and keytab.

	.DESCRIPTION
		THE REPAIR FOR THE ONE FAILURE A ZFS ROLLBACK CAUSES. /etc lives inside
		the boot environment, so rolling back to an older one restores an older
		/etc/krb5.keytab — while the domain controller has since rotated the
		machine account password past it. The machine then authenticates
		nobody, and nothing on it says why. `adcli update` re-establishes the
		account using the account itself, with no administrator credential.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[string]$Domain,
		[string]$KeytabPath = '/etc/krb5.keytab'
	)

	if (-not (Test-DirectoryTool -Name 'adcli')) { throw 'adcli is not installed.' }
	if (-not $PSCmdlet.ShouldProcess(($Domain ?? 'this host''s realm'), 'renew machine account')) {
		return $null
	}

	$arguments = @('update')
	if ($Domain) { $arguments += @('--domain', $Domain) }
	# The same trap as the join: without --host-keytab, adcli renews the
	# credential in /etc/krb5.keytab while this function reads -KeytabPath back
	# and reports on a file adcli never touched.
	if ($KeytabPath) { $arguments += @('--host-keytab', $KeytabPath) }
	$result = Invoke-DirectoryCommand -Command 'adcli' -Arguments $arguments

	$keytab = Get-DirectoryKeytabPrincipal -KeytabPath $KeytabPath
	return [pscustomobject]@{
		PSTypeName = 'Directory.RealmUpdate'
		Domain     = $Domain
		ExitCode   = $result.ExitCode
		Renewed    = ($result.ExitCode -eq 0)
		Principal  = $keytab.Principal
		Detail     = $result.StdErr.Trim()
	}
}

function Get-DirectoryTicket {
	<#
	.SYNOPSIS
		The Kerberos tickets in the current credential cache.

	.DESCRIPTION
		ALL THREE ANSWERS HAVE THE SAME FOUR FIELDS. The "klist is not
		installed" object used to have no Principal at all, so a caller reading
		.Principal got a Set-StrictMode property error on exactly the machine
		that branch exists for — an image without krb5-user, which is the normal
		OS/7 image rather than a broken one. A shape that changes with the
		answer makes every caller of it conditional on something it cannot see.
	#>
	param()

	if (-not (Test-DirectoryTool -Name 'klist')) {
		return [pscustomobject]@{
			Known     = $false
			Reason    = 'klist is not installed'
			Principal = $null
			Ticket    = @()
		}
	}

	$result = Invoke-DirectoryCommand -Command 'klist' -Arguments @()
	if ($result.ExitCode -ne 0) {
		# klist exits non-zero when there is simply no cache, which is an
		# answer and not a failure.
		return [pscustomobject]@{
			Known     = $true
			Reason    = 'no credential cache'
			Principal = $null
			Ticket    = @()
		}
	}

	$principal = $null
	$tickets = [System.Collections.Generic.List[object]]::new()
	foreach ($line in $result.StdOut.Split("`n")) {
		$principalMatch = [regex]::Match($line, '^Default principal:\s*(\S+)')
		if ($principalMatch.Success) { $principal = $principalMatch.Groups[1].Value; continue }
		$ticketMatch = [regex]::Match($line, '^\s*(\S+\s+\S+)\s+(\S+\s+\S+)\s+(\S+)\s*$')
		if ($ticketMatch.Success -and $ticketMatch.Groups[3].Value -match '/') {
			$tickets.Add([pscustomobject]@{
					Starts  = $ticketMatch.Groups[1].Value
					Expires = $ticketMatch.Groups[2].Value
					Service = $ticketMatch.Groups[3].Value
				})
		}
	}

	return [pscustomobject]@{
		Known     = $true
		Reason    = $null
		Principal = $principal
		Ticket    = $tickets.ToArray()
	}
}

function New-DirectoryTicket {
	<#
	.SYNOPSIS
		Obtain a Kerberos ticket for a principal.

	.DESCRIPTION
		The password goes to kinit on standard input, never in an argument.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Principal,
		[Parameter(Mandatory)][securestring]$Password
	)

	if (-not (Test-DirectoryTool -Name 'kinit')) {
		throw ('kinit is not installed. It comes with krb5-user, which is one of the packages ' +
			'a domain join adds; an outbound LDAPS session needs none of it.')
	}

	$plain = [System.Net.NetworkCredential]::new('', $Password).Password
	$result = Invoke-DirectoryCommand -Command 'kinit' -Arguments @($Principal) -StandardInput $plain
	$plain = $null

	if ($result.ExitCode -ne 0) {
		throw ("kinit could not obtain a ticket for '$Principal': " + $result.StdErr.Trim())
	}
	return (Get-DirectoryTicket)
}

function Remove-DirectoryTicket {
	<#
	.SYNOPSIS
		Destroy the credential cache.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param()

	if (-not (Test-DirectoryTool -Name 'kdestroy')) {
		throw 'kdestroy is not installed.'
	}
	if (-not $PSCmdlet.ShouldProcess('the Kerberos credential cache', 'destroy')) { return $null }
	$null = Invoke-DirectoryCommand -Command 'kdestroy' -Arguments @()
	return (Get-DirectoryTicket)
}

function Get-DirectoryIdentityResolution {
	<#
	.SYNOPSIS
		Whether the name service can resolve a directory account on this host.

	.DESCRIPTION
		THE ONLY QUESTION THAT PROVES A JOIN WORKS. sssd can be running, the
		keytab can be present and the configuration can be valid while the
		machine still resolves nobody — and every one of those three reports
		success on its own. `getent passwd <name>` asks the name service the
		question a login actually asks.
	#>
	param([Parameter(Mandatory)][string]$Name)

	$result = Invoke-DirectoryCommand -Command 'getent' -Arguments @('passwd', $Name)
	return [pscustomobject]@{
		Name     = $Name
		Resolved = ($result.ExitCode -eq 0 -and $result.StdOut.Trim() -ne '')
		Entry    = $result.StdOut.Trim()
	}
}

# ---------------------------------------------------------------------------
# The self-test
# ---------------------------------------------------------------------------

function Test-DirectoryModule {
	<#
	.SYNOPSIS
		Check this module against recorded output from a real directory.

	.DESCRIPTION
		WHAT THIS PROVES AND WHAT IT CANNOT. Everything above the seam — the
		escaping, the conversions, the flag decoding, the paging arithmetic,
		the error meanings — is checked here against LDIF captured from a real
		Samba AD DC. Nothing below the seam is: no socket is opened, no bind
		is attempted, no TLS is negotiated. installer/testing/check-ad.py is
		the test against a directory that answers, and nothing here replaces
		it.

		IT WRITES TO STDERR AND IT THROWS, WHICH IS Test-ZfsModule's CONTRACT
		AND NOT A STYLE. This function used to report with Write-Output and
		`return ($failed -eq 0)`: the return value was then the whole array of
		printed lines with $false on the end — truthy — and
		`pwsh -Command '…; Test-DirectoryModule'` exited 0 with cases failing.
		installer/testing/check-image.py gates on EXIT=0, so a broken LDAP layer
		would have shipped a green ISO. That is BUILD-NOTES #13's shape exactly:
		a step that did nothing and exited 0, and every reader downstream
		concluding from the exit code that it had worked.
	#>
	[CmdletBinding()]
	param([switch]$Quiet)

	$passed = 0
	$failed = 0
	$failures = [System.Collections.Generic.List[string]]::new()

	function Assert-DirectoryCase {
		param([string]$What, [bool]$Ok, [string]$Detail = '')
		if ($Ok) {
			$script:__dirPassed++
			if (-not $Quiet) { [Console]::Error.WriteLine("  ok    " + $What) }
		}
		else {
			$script:__dirFailed++
			$script:__dirFailures.Add($What + $(if ($Detail) { "  [$Detail]" } else { '' }))
			[Console]::Error.WriteLine("  FAIL  " + $What + $(if ($Detail) { "  [$Detail]" } else { '' }))
		}
	}

	$script:__dirPassed = 0
	$script:__dirFailed = 0
	$script:__dirFailures = $failures

	# --- RFC 4515, the filter ---
	Assert-DirectoryCase 'filter: an asterisk in a value is not a wildcard' `
		((ConvertTo-DirectoryFilterValue -Value 'a*b') -eq 'a\2ab')
	Assert-DirectoryCase 'filter: parentheses and backslash are escaped' `
		((ConvertTo-DirectoryFilterValue -Value '(x)\') -eq '\28x\29\5c')
	Assert-DirectoryCase 'filter: a comma is NOT escaped (that is the DN rule)' `
		((ConvertTo-DirectoryFilterValue -Value 'a,b') -eq 'a,b')
	Assert-DirectoryCase 'filter: an empty value survives' `
		((ConvertTo-DirectoryFilterValue -Value '') -eq '')

	# --- RFC 4514, the DN ---
	Assert-DirectoryCase 'dn: a comma inside a value is escaped' `
		((ConvertTo-DirectoryDnValue -Value 'Lovelace, Ada') -eq 'Lovelace\, Ada')
	Assert-DirectoryCase 'dn: a leading space is escaped' `
		((ConvertTo-DirectoryDnValue -Value ' x') -eq '\ x')
	Assert-DirectoryCase 'dn: an asterisk is NOT escaped (that is the filter rule)' `
		((ConvertTo-DirectoryDnValue -Value 'a*b') -eq 'a*b')

	$splitDn = @(Split-DirectoryDn -DistinguishedName 'CN=Lovelace\, Ada,OU=People,DC=os7,DC=test')
	Assert-DirectoryCase 'dn: an escaped comma does not split the name into five parts' `
		($splitDn.Count -eq 4) "got $($splitDn.Count)"
	Assert-DirectoryCase 'dn: os7.test becomes DC=os7,DC=test' `
		((ConvertTo-DirectoryDomainDn -DnsDomain 'os7.test') -eq 'DC=os7,DC=test')

	# --- userAccountControl ---
	$uacNormal = Get-DirectoryAccountControl -Value '512'
	Assert-DirectoryCase 'uac: 512 is an enabled NORMAL_ACCOUNT' `
		($uacNormal.Enabled -and ($uacNormal.Flags -contains 'NORMAL_ACCOUNT'))
	$uacDisabled = Get-DirectoryAccountControl -Value '514'
	Assert-DirectoryCase 'uac: 514 is a DISABLED normal account, not an unknown flag' `
		((-not $uacDisabled.Enabled) -and ($uacDisabled.Flags -contains 'ACCOUNTDISABLE'))
	$uacNeverExpires = Get-DirectoryAccountControl -Value '66048'
	Assert-DirectoryCase 'uac: 66048 is enabled with DONT_EXPIRE_PASSWORD' `
		($uacNeverExpires.Enabled -and $uacNeverExpires.PasswordNeverExpires)
	Assert-DirectoryCase 'uac: an absent attribute is $null, which is not zero' `
		($null -eq (Get-DirectoryAccountControl -Value $null))
	Assert-DirectoryCase 'uac: 0x40000 is SMARTCARD_REQUIRED' `
		((Get-DirectoryAccountControl -Value '262656').SmartcardRequired)

	# --- FILETIME ---
	Assert-DirectoryCase 'filetime: 0 means never, not 1601' `
		($null -eq (ConvertFrom-DirectoryFileTime -Value '0'))
	Assert-DirectoryCase 'filetime: Int64.MaxValue means never, not year 30828' `
		($null -eq (ConvertFrom-DirectoryFileTime -Value '9223372036854775807'))
	$pwdLastSet = ConvertFrom-DirectoryFileTime -Value '134323312830803749'
	Assert-DirectoryCase 'filetime: a real pwdLastSet becomes a DateTime in 2026' `
		($null -ne $pwdLastSet -and $pwdLastSet.Year -eq 2026) "got $pwdLastSet"
	Assert-DirectoryCase 'filetime: rubbish is $null, never an exception' `
		($null -eq (ConvertFrom-DirectoryFileTime -Value 'not-a-number'))

	# --- generalized time ---
	$whenCreated = ConvertFrom-DirectoryGeneralizedTime -Value '20260827190803.0Z'
	Assert-DirectoryCase 'generalized time: 20260827190803.0Z parses to 2026-08-27 19:08:03' `
		($null -ne $whenCreated -and $whenCreated.Year -eq 2026 -and $whenCreated.Month -eq 8 `
			-and $whenCreated.Day -eq 27 -and $whenCreated.Hour -eq 19) "got $whenCreated"
	Assert-DirectoryCase 'generalized time: rubbish is $null' `
		($null -eq (ConvertFrom-DirectoryGeneralizedTime -Value 'yesterday'))

	# --- SID and GUID, from the bytes a real DC sent ---
	$sidBytes = [System.Convert]::FromBase64String('AQUAAAAAAAUVAAAA2gnSpGzEwv3Oe1RWUQQAAA==')
	$sid = ConvertFrom-DirectorySid -Bytes $sidBytes
	Assert-DirectoryCase 'sid: a real objectSid decodes to S-1-5-21-...-1105' `
		($sid -like 'S-1-5-21-*-1105') "got $sid"
	Assert-DirectoryCase 'sid: a short array is $null, not a partial answer' `
		($null -eq (ConvertFrom-DirectorySid -Bytes ([byte[]]@(1, 2, 3))))
	$guidBytes = [System.Convert]::FromBase64String('rpQk1G9/CkmbWRd8CESguA==')
	$guid = ConvertFrom-DirectoryGuid -Bytes $guidBytes
	Assert-DirectoryCase 'guid: a real objectGUID decodes to 36 characters' `
		($null -ne $guid -and $guid.Length -eq 36) "got $guid"

	# --- the #92 guards ---
	$oneMember = [ordered]@{ 'member' = @('CN=Ada,DC=os7,DC=test') }
	$members = @(Get-DirectoryAttributeValues -Attributes $oneMember -Name 'member')
	Assert-DirectoryCase 'a group with ONE member is a one-element list, not a string' `
		($members.Count -eq 1 -and $members[0] -is [string] -and $members[0].Length -gt 1) `
		"count $($members.Count)"
	$absent = @(Get-DirectoryAttributeValues -Attributes $oneMember -Name 'nothingHere')
	Assert-DirectoryCase 'a missing attribute has Count 0, not 1' ($absent.Count -eq 0)
	Assert-DirectoryCase 'a missing scalar is $null' `
		($null -eq (Get-DirectoryAttributeScalar -Attributes $oneMember -Name 'nothingHere'))

	# THE THREE CASES ABOVE ARE ALSO WHAT STOPS A HALF-DONE #92 MIGRATION.
	# `return , $array` inside Get-DirectoryAttributeValues fixes the bare
	# assignment nobody here writes and turns every @(…) call site into a
	# ONE-ELEMENT NESTED ARRAY — measured, and it fails the first two of them
	# rather than shipping a MemberCount of 1 for every group. See that
	# function's help for the migration that would have to happen in one commit.
	# This case is the multi-valued half of the same guard: with the comma it
	# reads 1.
	$twoMembers = [ordered]@{ 'member' = @('CN=Ada,DC=os7,DC=test', 'CN=Grace,DC=os7,DC=test') }
	Assert-DirectoryCase 'a group with TWO members has Count 2, not one array with two in it' `
		((@(Get-DirectoryAttributeValues -Attributes $twoMembers -Name 'member')).Count -eq 2)

	# --- and the same unrolling, going the other way: values being WRITTEN ---
	$binaryValue = Get-DirectoryWritableValue -Value ([byte[]]@(1, 2, 3))
	Assert-DirectoryCase 'a byte[] is ONE attribute value, not one value per byte' `
		(@($binaryValue).Count -eq 1 -and $binaryValue[0] -is [byte[]]) `
		"got $(@($binaryValue).Count)"
	$twoValues = Get-DirectoryWritableValue -Value @('one', 'two')
	Assert-DirectoryCase 'and two strings are still two values' (@($twoValues).Count -eq 2)

	# --- error meanings ---
	$lockedOut = Get-DirectoryErrorMeaning -Exception ([pscustomobject]@{
			ErrorCode = 49
			Message   = '80090308: LdapErr=DSID-0C0903A9, comment: AcceptSecurityContext error, data 775, v4563'
		})
	Assert-DirectoryCase 'ldap 49 data 775 is LOCKED OUT, not "invalid credentials"' `
		($lockedOut.SubCode -eq '775' -and $lockedOut.Meaning -like '*locked out*') `
		"got $($lockedOut.SubCode)"
	$badPassword = Get-DirectoryErrorMeaning -Exception ([pscustomobject]@{
			ErrorCode = 49
			Message   = 'comment: AcceptSecurityContext error, data 52e, v4563'
		})
	Assert-DirectoryCase 'ldap 49 data 52e is a wrong password' `
		($badPassword.Meaning -like '*password is wrong*')
	$unknown = Get-DirectoryErrorMeaning -Exception ([pscustomobject]@{ ErrorCode = 4711; Message = '' })
	Assert-DirectoryCase 'an unknown code gets NO invented sentence' ($null -eq $unknown.Meaning)
	$notSupported = Get-DirectoryErrorMeaning -Exception ([pscustomobject]@{ ErrorCode = 92; Message = '' })
	Assert-DirectoryCase 'ldap 92 names the platform, which is what rc 92 means here' `
		($notSupported.Meaning -like '*platform*')

	# The wrapper case, which is how a real catch block receives it. Found by
	# a real DC and a deliberately wrong password: the handler that was meant
	# to explain the failure threw a property error instead.
	$wrapped = [System.Management.Automation.MethodInvocationException]::new(
		'Exception calling "Bind"',
		[System.DirectoryServices.Protocols.LdapException]::new(49))
	$unwrapped = Get-DirectoryLdapException -Exception $wrapped
	Assert-DirectoryCase 'an LdapException is found inside the wrapper PowerShell adds' `
		($unwrapped -is [System.DirectoryServices.Protocols.LdapException]) `
		"got $($unwrapped.GetType().Name)"
	Assert-DirectoryCase 'and reading its meaning through the wrapper does not throw' `
		((Get-DirectoryErrorMeaning -Exception $wrapped).Code -eq 49)

	# --- the refusals, caught by TYPE ---
	$refusedCleartextPassword = $false
	try {
		$fakeSession = [pscustomobject]@{ Tls = $false; Connection = $null }
		Set-DirectoryPassword -Session $fakeSession -DistinguishedName 'CN=x,DC=y' `
			-NewPassword (ConvertTo-SecureString 'hunter2hunter2' -AsPlainText -Force) `
			-Confirm:$false | Out-Null
	}
	catch { $refusedCleartextPassword = ($_.Exception.Message -like '*unencrypted*') }
	Assert-DirectoryCase 'a password change over cleartext is refused BEFORE the wire' `
		$refusedCleartextPassword

	$refusedNegotiateCredential = $false
	try {
		$credential = [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
		New-DirectoryConnection -Server 'nowhere.invalid' -AuthType 'Negotiate' `
			-Credential $credential | Out-Null
	}
	catch { $refusedNegotiateCredential = ($_.Exception.Message -like '*rc 92*') }
	Assert-DirectoryCase 'Negotiate with a credential is refused, not silently ignored' `
		$refusedNegotiateCredential

	# --- the sssd document, which is a pure function for exactly this reason ---
	$sssdText = New-DirectorySssdConfiguration -Domain 'corp.example.com' `
		-AllowGroup @('Domain Admins', 'Linux Admins')
	Assert-DirectoryCase 'sssd.conf names the domain in both places it must' `
		($sssdText -match '(?m)^domains = corp\.example\.com$' -and
		$sssdText -match '(?m)^\[domain/corp\.example\.com\]$')
	Assert-DirectoryCase 'sssd.conf puts domain homes OUTSIDE the boot environment' `
		($sssdText -match '(?m)^fallback_homedir = /var/lib/os7/domain-homes/%u$') `
		'this is the #74 shape: a rollback would otherwise take them'
	Assert-DirectoryCase 'sssd.conf writes allowed groups as a comma list, not one per line' `
		($sssdText -match '(?m)^simple_allow_groups = Domain Admins, Linux Admins$')

	# THE FAIL-OPEN CASE. `access_provider = simple` with no allow list grants a
	# login to EVERY account in the directory — the shipped libsss_simple.so's
	# own words, "No rules supplied for simple access provider. Access will be
	# granted for all users." So the document that used to be written when
	# nobody named a group was the most permissive one this function can
	# produce, and it was the one produced by leaving a parameter out.
	$sssdRefusedOpen = $false
	try { New-DirectorySssdConfiguration -Domain 'x.test' | Out-Null }
	catch { $sssdRefusedOpen = ($_.Exception.Message -like '*EVERY account*') }
	Assert-DirectoryCase 'with no group named, the sssd document is REFUSED rather than opened' `
		$sssdRefusedOpen

	$sssdAllUsers = New-DirectorySssdConfiguration -Domain 'x.test' -AllowAllDomainUsers
	Assert-DirectoryCase 'asked for in as many words, it is written — and says so in the file' `
		(($sssdAllUsers -notmatch 'simple_allow_groups') -and
		($sssdAllUsers -match '(?m)^# -AllowAllDomainUsers'))

	# A comma inside ONE name is two groups nobody has, and the only symptom is
	# that the people in the real group cannot sign in.
	$sssdRefusedComma = $false
	try {
		New-DirectorySssdConfiguration -Domain 'x.test' -AllowGroup @('Berlin, Sales') | Out-Null
	}
	catch { $sssdRefusedComma = ($_.Exception.Message -like '*comma*') }
	Assert-DirectoryCase 'a group name containing a comma is refused, not silently split in two' `
		$sssdRefusedComma

	# --- THE SEAM, REPLACED: the two things a pure function cannot be asked ---
	#
	# Everything above this line is a function handed a value. These two are
	# about a REQUEST going through Invoke-DirectoryRequest, which is the only
	# reason the seam sits where it does, and neither could be asked of the code
	# that stood here before: Get-DirectoryWhoAmI called SendRequest on the
	# connection itself, so no fake could reach the one question that tells a
	# real bind from a silent fall-back to anonymous; and -SizeLimit set nothing
	# on the request and cut nothing from the answer, so it bounded the number
	# of round trips and not the number of rows.
	#
	# No .GetNewClosure() here, deliberately: the block reads nothing from this
	# scope, and closing it would rebind $script: away from the module's own
	# state — measured in installer/testing/check-directory-logic.py, where the
	# opposite rule applies to the command-runner seam.
	$savedRequestOverride = $script:DirectoryRequestOverride
	try {
		$script:DirectoryRequestOverride = {
			param($connection, $request)
			if ($request -is [System.DirectoryServices.Protocols.ExtendedRequest]) {
				return [pscustomobject]@{
					Rows          = @()
					Referrals     = @()
					Cookie        = $null
					ResponseValue = [System.Text.Encoding]::UTF8.GetBytes('u:OS7\Administrator')
				}
			}
			$fakeRows = [System.Collections.Generic.List[object]]::new()
			foreach ($number in 1..5) {
				$fakeRows.Add([pscustomobject]@{
						Dn         = "CN=$number,DC=os7,DC=test"
						Attributes = [ordered]@{}
					})
			}
			return [pscustomobject]@{
				Rows = $fakeRows; Referrals = @(); Cookie = $null; ResponseValue = $null
			}
		}
		$seamSession = [pscustomobject]@{ Connection = 'a fake, and it never has to be more' }

		$whoAmI = Get-DirectoryWhoAmI -Session $seamSession
		Assert-DirectoryCase 'whoami goes through the request seam, so a fake can answer it' `
			($whoAmI -eq 'u:OS7\Administrator') "got $whoAmI"

		$limited = @(Search-Directory -Session $seamSession -SearchBase 'DC=os7,DC=test' `
				-Filter '(objectClass=*)' -SizeLimit 2)
		Assert-DirectoryCase '-SizeLimit 2 returns TWO rows out of a page of five' `
			($limited.Count -eq 2) "got $($limited.Count)"

		$unlimited = @(Search-Directory -Session $seamSession -SearchBase 'DC=os7,DC=test' `
				-Filter '(objectClass=*)')
		Assert-DirectoryCase 'and with no limit asked for, nothing is cut' `
			($unlimited.Count -eq 5) "got $($unlimited.Count)"
	}
	finally {
		$script:DirectoryRequestOverride = $savedRequestOverride
	}

	# --- a tool that is not installed is an ANSWER, not a crash ---
	$absentTool = Test-DirectoryTool -Name 'os7-no-such-program-anywhere'
	Assert-DirectoryCase 'a missing program is reported false, never thrown' `
		($absentTool -eq $false)

	# ONE SHAPE FOR ALL THREE ANSWERS, and this holds on both kinds of machine:
	# where klist is absent — every OS/7 image that has not joined a domain —
	# and where it is present with no cache. A caller reading .Principal used to
	# get a Set-StrictMode property error on the first of those, which is
	# precisely the machine the branch was written for.
	$ticketAnswer = Get-DirectoryTicket
	Assert-DirectoryCase 'a ticket answer carries Principal whichever branch produced it' `
		($null -ne $ticketAnswer.PSObject.Properties['Principal'] -and
		$null -ne $ticketAnswer.PSObject.Properties['Ticket'] -and
		$null -ne $ticketAnswer.PSObject.Properties['Known']) `
		"reason: $($ticketAnswer.Reason)"

	# --- TWO EXPORT FILTERS, AND THEY MUST AGREE ---
	#
	# Export-ModuleMember at the bottom of this file is one filter and
	# FunctionsToExport in the .psd1 is another, and the manifest wins. Adding
	# a function to one and not the other produces a module that loads
	# cleanly, passes every other check, and is missing eleven cmdlets — which
	# is exactly what happened here on 2026-08-27: the whole realm-membership
	# half was unreachable, and the symptom would have been Join-OS7Domain
	# failing at run time with "the term 'Join-DirectoryRealm' is not
	# recognized", on a machine, during an install. Nothing else in this
	# repository compares the two.
	$manifestPath = [System.IO.Path]::Combine($PSScriptRoot, 'Directory.psd1')
	if ([System.IO.File]::Exists($manifestPath)) {
		$manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
		$exported = @((Get-Module Directory).ExportedFunctions.Keys)
		$declared = @($manifest.FunctionsToExport)
		$missing = @($declared | Where-Object { $_ -notin $exported })
		Assert-DirectoryCase 'the manifest and the module export the same names' `
			($missing.Count -eq 0) ($missing -join ', ')
		Assert-DirectoryCase 'the realm half is reachable through the manifest' `
			($declared -contains 'Join-DirectoryRealm')
	}

	# --- the canary: a session must never carry a password into JSON ---
	$canarySession = [pscustomobject]@{
		PSTypeName = 'Directory.Session'
		Server     = 'dc01.os7.test'
		Identity   = 'Administrator@OS7.TEST'
		Connection = $null
	}
	$serialised = ($canarySession | ConvertTo-Json -Depth 8)
	Assert-DirectoryCase 'a session object carries no password into JSON' `
		(-not $serialised.Contains('hunter2hunter2'))

	$passed = $script:__dirPassed
	$failed = $script:__dirFailed

	[Console]::Error.WriteLine('')
	[Console]::Error.WriteLine("Directory self-test: $passed passed, $failed failed")
	if ($failed -gt 0) {
		foreach ($one in $failures) { [Console]::Error.WriteLine("  - " + $one) }
		throw "Directory self-test failed: $failed check(s)"
	}
	[Console]::Error.WriteLine('Directory self-test: PASS')
}

Export-ModuleMember -Function @(
	# The connection and what the server says about itself
	'Connect-DirectoryServer', 'Disconnect-DirectoryServer',
	'Get-DirectoryWhoAmI', 'Get-DirectoryRootDse',
	# Reading and writing objects
	'Search-Directory', 'New-DirectoryEntry', 'Set-DirectoryEntry',
	'Remove-DirectoryEntry', 'Move-DirectoryEntry', 'Set-DirectoryPassword',
	# The escaping and conversion rules, exported because the OS7 layer above
	# builds filters and DNs and must not write a second implementation of
	# either — BUILD-NOTES #66 is a rule written twice taking two routes
	'ConvertTo-DirectoryFilterValue', 'ConvertTo-DirectoryDnValue',
	'ConvertTo-DirectoryDomainDn', 'Split-DirectoryDn',
	'Get-DirectoryAttributeValues', 'Get-DirectoryAttributeScalar',
	'ConvertTo-DirectoryInt64',
	'ConvertFrom-DirectoryFileTime', 'ConvertFrom-DirectoryGeneralizedTime',
	'ConvertFrom-DirectorySid', 'ConvertFrom-DirectoryGuid',
	'Get-DirectoryAccountControl', 'Get-DirectoryErrorMeaning',
	# Exported because the OS7 layer catches the same exceptions and must not
	# reach for .ErrorCode on the wrapper PowerShell hands it
	'Get-DirectoryLdapException',
	# Realm membership. Everything here starts a process, which is why it is
	# in this module and not in OS7: check-layering.py's P2-directory rule
	# forbids powershell/OS7 from naming adcli, kinit, klist or getent at all
	'Join-DirectoryRealm', 'Remove-DirectoryRealm', 'Update-DirectoryRealm',
	'Get-DirectoryRealmConfiguration', 'Get-DirectoryKeytabPrincipal',
	'New-DirectorySssdConfiguration', 'Get-DirectoryIdentityResolution',
	'Get-DirectoryTicket', 'New-DirectoryTicket', 'Remove-DirectoryTicket',
	'Test-DirectoryTool',
	# The self-test
	'Test-DirectoryModule'
)
