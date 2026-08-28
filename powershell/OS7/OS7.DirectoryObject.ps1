# =============================================================================
# OS/7 — Active Directory objects: users, groups, computers, and the raw way out
#
# The verbs an administrator types. Everything here runs inside the session
# Enter-OS7AdminSession opened (OS7.Directory.ps1), which means every change is
# made as the operator's own account and the domain controller's audit trail
# names a person rather than a service.
#
# WHY THESE ARE NOT CALLED Get-ADUser. POWERSHELL-SURFACE-PLAN P1: the OS7
# prefix is canonical, and the second of its three reasons is exactly this
# group. Microsoft's ActiveDirectory module is Windows-only, has some 150
# cmdlets and parameter sets forty entries wide; a cmdlet here that took the
# same name and accepted a third of them would turn a script copied from a
# Windows admin's notes into one that half-works, which is worse than one that
# fails on its first line.
#
# WHAT IS DELIBERATELY NOT HERE, and it is not an oversight:
#
#   * Group Policy. There is no GPO authoring from Linux at all — GPMC is COM
#     and SYSVOL policy files are a Windows format. sssd can ENFORCE logon-right
#     GPOs on a joined machine, which is consumption and not administration.
#   * Anything over RPC or DCOM: repadmin, dcdiag, netdom, DNS server
#     management, DHCP, certificate enrolment. No cross-platform client exists.
#   * Anything through [ADSI]. System.DirectoryServices loads on Linux and then
#     throws "not supported on this platform" — measured 2026-08-27, and it is
#     the reason a script that works on Windows will not port by copying.
#
# THE ESCAPE HATCH IS PART OF THE DESIGN. Search-OS7AD and Get-/Set-OS7ADObject
# take raw filters, DNs and attribute names, so anything this file does not
# name is one call away rather than a dead end. A curated surface without a way
# past it is a surface that has to be complete, and no directory surface ever is.
#
# Dot-sourced by OS7.psm1, after OS7.Directory.ps1 — every function here calls
# Resolve-OS7AdminSession, which lives there.
# =============================================================================

# The attributes every object type is read with. Named explicitly and not '*'
# for two reasons: a directory returns hundreds of attributes per object and
# most of a fleet-wide query's cost is transferring them, and an object shape
# that changes because a schema was extended is an object shape nobody can
# write a script against.
$script:OS7AdUserAttributes = @(
	'distinguishedName', 'sAMAccountName', 'userPrincipalName', 'displayName',
	'givenName', 'sn', 'mail', 'telephoneNumber', 'title', 'department',
	'company', 'description', 'userAccountControl', 'lockoutTime',
	'pwdLastSet', 'accountExpires', 'lastLogonTimestamp', 'whenCreated',
	'whenChanged', 'memberOf', 'objectSid', 'objectGUID', 'primaryGroupID'
)

$script:OS7AdGroupAttributes = @(
	'distinguishedName', 'sAMAccountName', 'displayName', 'description',
	'groupType', 'member', 'memberOf', 'mail', 'whenCreated', 'whenChanged',
	'objectSid', 'objectGUID'
)

$script:OS7AdComputerAttributes = @(
	'distinguishedName', 'sAMAccountName', 'dNSHostName', 'operatingSystem',
	'operatingSystemVersion', 'description', 'userAccountControl',
	'lastLogonTimestamp', 'whenCreated', 'whenChanged', 'objectSid', 'objectGUID'
)

# A GROUP'S MEMBERS ARE NOT ALL USERS, so a membership is read with the union of
# the three sets above and objectClass — one round trip per member, with the row
# itself carrying the answer to which shape it should be rendered as. Reading a
# membership with the USER attributes alone is how a nested group came back as an
# OS7.AD.User with Enabled $null, which is indistinguishable from a user account
# whose flags were not among the attributes asked for.
#
# NOT `| Sort-Object -Unique`, and that is BUILD-NOTES #82 rather than a style
# preference. This statement runs at IMPORT. Hook 0060 imports the module inside
# the build chroot, and `Sort-Object` is Microsoft.PowerShell.Utility — autoloaded
# BY NAME, which is exactly what does not work there. It cost an ISO build on
# 2026-08-28, with the same sentence #82 records for `Join-Path`:
#
#     OS/7 hook 0060:   OS7: FAILED: The term 'Sort-Object' is not recognized
#
# and it was invisible because no ISO had been built since these files landed.
# .NET types are always present and are never looked up by name. The value is
# unchanged: 29 attributes, the same set in the same order.
$script:OS7AdMemberAttributes = $(
	$seen  = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::InvariantCultureIgnoreCase)
	$union = [System.Collections.Generic.List[string]]::new()
	foreach ($a in ($script:OS7AdUserAttributes + $script:OS7AdGroupAttributes +
			$script:OS7AdComputerAttributes + 'objectClass')) {
		if ($seen.Add($a)) { $union.Add($a) }
	}
	$union.Sort([System.StringComparer]::InvariantCultureIgnoreCase)
	, $union.ToArray()
)

function Get-OS7AdIdentityFilter {
	<#
	.SYNOPSIS
		Internal. Turn "whatever the operator typed" into an LDAP filter.

	.DESCRIPTION
		An identity is a sAMAccountName, a userPrincipalName, a distinguished
		name or a GUID, and an administrator does not want to say which. Every
		branch escapes through the Directory module's RFC 4515 helper — a
		display name containing a parenthesis is ordinary, and an unescaped one
		does not fail, it queries for something else.

		The local is deliberately not $identity: BUILD-NOTES #65, a parameter
		name reused as a local, and this file has more candidates for it than
		anything else in the repository.
	#>
	param(
		[Parameter(Mandatory)][string]$Value,
		[Parameter(Mandatory)][string]$ObjectClass
	)

	$escaped = ConvertTo-DirectoryFilterValue -Value $Value
	if ($Value -match '^(CN|OU|DC)=') {
		return "(&(objectClass=$ObjectClass)(distinguishedName=$escaped))"
	}
	if ($Value.Contains('@')) {
		return "(&(objectClass=$ObjectClass)(userPrincipalName=$escaped))"
	}
	return "(&(objectClass=$ObjectClass)(|(sAMAccountName=$escaped)(cn=$escaped)))"
}

function ConvertTo-OS7AdUser {
	<#
	.SYNOPSIS
		Internal. One directory row as a user object.

	.DESCRIPTION
		LOCKEDOUT COMES FROM lockoutTime AND NOT FROM userAccountControl. AD
		does not maintain the 0x10 LOCKOUT bit; a surface that read it would
		tell an administrator that a locked-out account is fine, and they would
		go looking at the password. The authoritative attribute is lockoutTime,
		where 0 and absent both mean "not locked".
	#>
	param([Parameter(Mandatory)]$Row)

	$attributes = $Row.Attributes
	$control = Get-DirectoryAccountControl -Value (
		Get-DirectoryAttributeScalar -Attributes $attributes -Name 'userAccountControl')
	$lockoutTime = ConvertFrom-DirectoryFileTime -Value (
		Get-DirectoryAttributeScalar -Attributes $attributes -Name 'lockoutTime')

	return [pscustomobject]@{
		PSTypeName        = 'OS7.AD.User'
		Name              = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'sAMAccountName'
		DisplayName       = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'displayName'
		UserPrincipalName = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'userPrincipalName'
		GivenName         = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'givenName'
		Surname           = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'sn'
		Mail              = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'mail'
		Title             = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'title'
		Department        = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'department'
		Description       = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'description'
		Enabled           = $(if ($control) { $control.Enabled } else { $null })
		LockedOut         = ($null -ne $lockoutTime)
		LockedOutSince    = $lockoutTime
		PasswordLastSet   = ConvertFrom-DirectoryFileTime -Value (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'pwdLastSet')
		PasswordNeverExpires = $(if ($control) { $control.PasswordNeverExpires } else { $null })
		AccountExpires    = ConvertFrom-DirectoryFileTime -Value (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'accountExpires')
		LastLogon         = ConvertFrom-DirectoryFileTime -Value (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'lastLogonTimestamp')
		Created           = ConvertFrom-DirectoryGeneralizedTime -Value (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'whenCreated')
		MemberOf          = @(Get-DirectoryAttributeValues -Attributes $attributes -Name 'memberOf')
		Sid               = ConvertFrom-DirectorySid -Bytes (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'objectSid')
		Guid              = ConvertFrom-DirectoryGuid -Bytes (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'objectGUID')
		AccountControl    = $(if ($control) { $control.Flags } else { @() })
		DistinguishedName = $Row.Dn
	}
}

function ConvertTo-OS7AdGroup {
	<#
	.SYNOPSIS
		Internal. One directory row as a group object.
	#>
	param([Parameter(Mandatory)]$Row)

	$attributes = $Row.Attributes
	$groupType = ConvertTo-DirectoryInt64 -Value (
		Get-DirectoryAttributeScalar -Attributes $attributes -Name 'groupType')

	# The high bit is what makes a group a SECURITY group rather than a
	# distribution list, and it is set, so the value arrives negative.
	$security = $null
	if ($null -ne $groupType) { $security = (($groupType -band 0x80000000) -ne 0) }

	return [pscustomobject]@{
		PSTypeName        = 'OS7.AD.Group'
		Name              = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'sAMAccountName'
		DisplayName       = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'displayName'
		Description       = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'description'
		Mail              = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'mail'
		SecurityGroup     = $security
		MemberCount       = @(Get-DirectoryAttributeValues -Attributes $attributes -Name 'member').Count
		Member            = @(Get-DirectoryAttributeValues -Attributes $attributes -Name 'member')
		MemberOf          = @(Get-DirectoryAttributeValues -Attributes $attributes -Name 'memberOf')
		Created           = ConvertFrom-DirectoryGeneralizedTime -Value (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'whenCreated')
		Sid               = ConvertFrom-DirectorySid -Bytes (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'objectSid')
		Guid              = ConvertFrom-DirectoryGuid -Bytes (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'objectGUID')
		DistinguishedName = $Row.Dn
	}
}

function ConvertTo-OS7AdComputer {
	<#
	.SYNOPSIS
		Internal. One directory row as a computer object.
	#>
	param([Parameter(Mandatory)]$Row)

	$attributes = $Row.Attributes
	$control = Get-DirectoryAccountControl -Value (
		Get-DirectoryAttributeScalar -Attributes $attributes -Name 'userAccountControl')

	return [pscustomobject]@{
		PSTypeName        = 'OS7.AD.Computer'
		Name              = (Get-DirectoryAttributeScalar -Attributes $attributes -Name 'sAMAccountName') -replace '\$$', ''
		DnsHostName       = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'dNSHostName'
		OperatingSystem   = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'operatingSystem'
		OperatingSystemVersion = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'operatingSystemVersion'
		Description       = Get-DirectoryAttributeScalar -Attributes $attributes -Name 'description'
		Enabled           = $(if ($control) { $control.Enabled } else { $null })
		LastLogon         = ConvertFrom-DirectoryFileTime -Value (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'lastLogonTimestamp')
		Created           = ConvertFrom-DirectoryGeneralizedTime -Value (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'whenCreated')
		Sid               = ConvertFrom-DirectorySid -Bytes (
			Get-DirectoryAttributeScalar -Attributes $attributes -Name 'objectSid')
		DistinguishedName = $Row.Dn
	}
}

function ConvertTo-OS7AdMember {
	<#
	.SYNOPSIS
		Internal. One directory row as whatever KIND of object it actually is.

	.DESCRIPTION
		objectClass IS THE ONLY THING THAT DECIDES, and it has to be asked for:
		a group's membership holds nested groups and computer accounts as
		routinely as it holds users, and rendering one of those through
		ConvertTo-OS7AdUser produces an OS7.AD.User whose Enabled is $null —
		which is what a user read with the wrong attribute list looks like, so
		the caller cannot tell either.

		THE MOST SPECIFIC CLASS WINS AND THAT IS WHY THE ORDER IS THIS WAY. A
		computer object IS a user in the AD schema and carries both classes;
		asking about `user` first would render every domain-joined machine as an
		account with no host name. Get-OS7ADUser's own filter carries
		(objectCategory=person) for the same reason.

		Anything that is none of the three is returned as what it is rather than
		forced into one of them. A contact or a foreignSecurityPrincipal in a
		group is ordinary, and inventing an Enabled for it would be a fact
		nobody measured.
	#>
	param([Parameter(Mandatory)]$Row)

	$classes = @(Get-DirectoryAttributeValues -Attributes $Row.Attributes -Name 'objectClass')
	if ($classes -contains 'computer') { return (ConvertTo-OS7AdComputer -Row $Row) }
	if ($classes -contains 'group') { return (ConvertTo-OS7AdGroup -Row $Row) }
	if ($classes -contains 'user') { return (ConvertTo-OS7AdUser -Row $Row) }

	return [pscustomobject]@{
		PSTypeName        = 'OS7.AD.Object'
		Name              = Get-DirectoryAttributeScalar -Attributes $Row.Attributes -Name 'sAMAccountName'
		Description       = Get-DirectoryAttributeScalar -Attributes $Row.Attributes -Name 'description'
		ObjectClass       = $classes
		DistinguishedName = $Row.Dn
	}
}

function Get-OS7AdSearchBase {
	<#
	.SYNOPSIS
		Internal. The search base to use: the one given, or the domain's own.
	#>
	param($Session, [string]$SearchBase)

	if ($SearchBase) { return $SearchBase }
	if ($Session.PSObject.Properties['DefaultNamingContext'] -and $Session.DefaultNamingContext) {
		return $Session.DefaultNamingContext
	}
	throw 'No search base, and the session does not know the domain''s naming context.'
}

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

function Get-OS7ADUser {
	<#
	.SYNOPSIS
		Find users in Active Directory.

	.DESCRIPTION
		-Identity takes a sAMAccountName, a userPrincipalName or a
		distinguished name and works out which. -Filter takes a raw LDAP filter
		for everything else.

		Enabled and LockedOut are separate answers because they come from
		separate places, and the second one is the trap: Active Directory does
		not maintain the LOCKOUT bit in userAccountControl, so LockedOut is
		read from lockoutTime instead. A surface that read the flag would
		report a locked-out account as fine.

	.EXAMPLE
		Get-OS7ADUser -Identity p-schmidt

	.EXAMPLE
		Get-OS7ADUser -Filter '(&(objectClass=user)(department=IT))' | Where-Object { -not $_.Enabled }
	#>
	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	param(
		[Parameter(ParameterSetName = 'Identity', Position = 0)][string]$Identity,
		[Parameter(ParameterSetName = 'Filter')][string]$Filter,
		[string]$SearchBase,
		[string[]]$Property,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$computedFilter = $Filter
	if (-not $computedFilter) {
		if (-not $Identity) {
			# A user query with no identity and no filter is "every user", and
			# that is a legitimate thing to ask for. The category filter keeps
			# computers out, which (objectClass=user) alone does not: a
			# computer object IS a user in the AD schema.
			$computedFilter = '(&(objectCategory=person)(objectClass=user))'
		}
		else {
			$computedFilter = Get-OS7AdIdentityFilter -Value $Identity -ObjectClass 'user'
			$computedFilter = $computedFilter -replace '\(objectClass=user\)',
			'(&(objectCategory=person)(objectClass=user))'
		}
	}

	$attributes = $script:OS7AdUserAttributes
	if ($Property) { $attributes = $Property }

	$rows = @(Search-Directory -Session $activeSession.DirectorySession `
			-SearchBase (Get-OS7AdSearchBase -Session $activeSession -SearchBase $SearchBase) `
			-Filter $computedFilter -Property $attributes)

	foreach ($row in $rows) { ConvertTo-OS7AdUser -Row $row }
}

function Get-OS7ADGroup {
	<#
	.SYNOPSIS
		Find groups in Active Directory.
	#>
	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	param(
		[Parameter(ParameterSetName = 'Identity', Position = 0)][string]$Identity,
		[Parameter(ParameterSetName = 'Filter')][string]$Filter,
		[string]$SearchBase,
		[string[]]$Property,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$computedFilter = $Filter
	if (-not $computedFilter) {
		$computedFilter = if ($Identity) {
			Get-OS7AdIdentityFilter -Value $Identity -ObjectClass 'group'
		}
		else { '(objectClass=group)' }
	}

	$attributes = $script:OS7AdGroupAttributes
	if ($Property) { $attributes = $Property }

	$rows = @(Search-Directory -Session $activeSession.DirectorySession `
			-SearchBase (Get-OS7AdSearchBase -Session $activeSession -SearchBase $SearchBase) `
			-Filter $computedFilter -Property $attributes)

	foreach ($row in $rows) { ConvertTo-OS7AdGroup -Row $row }
}

function Get-OS7ADGroupMember {
	<#
	.SYNOPSIS
		The members of a group.

	.DESCRIPTION
		-Recursive uses the directory's own matching rule (1.2.840.113556.1.4.1941)
		rather than walking the tree here. Walking it in PowerShell would be
		slower, would loop on a circular nesting, and would ask a different
		question from the one the domain controller answers when it decides
		access.

		EACH MEMBER COMES BACK AS WHAT IT IS — a user, a group, a computer, or an
		object that names its own classes. A membership rendered as users alone
		gives a nested group an Enabled of $null, which is exactly what a user
		read sparsely looks like.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[switch]$Recursive,
		[string]$SearchBase,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session
	$base = Get-OS7AdSearchBase -Session $activeSession -SearchBase $SearchBase

	$group = @(Get-OS7ADGroup -Identity $Identity -SearchBase $base -Session $activeSession)
	if ($group.Count -eq 0) { throw "No group matched '$Identity'." }
	$groupDn = $group[0].DistinguishedName

	if ($Recursive) {
		$escapedDn = ConvertTo-DirectoryFilterValue -Value $groupDn
		$memberFilter = "(memberOf:1.2.840.113556.1.4.1941:=$escapedDn)"
		$rows = @(Search-Directory -Session $activeSession.DirectorySession -SearchBase $base `
				-Filter $memberFilter -Property $script:OS7AdMemberAttributes)
		foreach ($row in $rows) { ConvertTo-OS7AdMember -Row $row }
		return
	}

	# THE MEMBER DN IS THE SEARCH BASE AND NOT PART OF A FILTER, so nothing here
	# is escaped: RFC 4515 escaping belongs to filter values, and a base handed
	# through it would be a DN the server does not have. An escaped copy was
	# computed here and never used, which reads as escaping being applied where
	# it is not.
	foreach ($memberDn in $group[0].Member) {
		$rows = @(Search-Directory -Session $activeSession.DirectorySession `
				-SearchBase $memberDn -Filter '(objectClass=*)' -Scope Base `
				-Property $script:OS7AdMemberAttributes)
		foreach ($row in $rows) { ConvertTo-OS7AdMember -Row $row }
	}
}

function Get-OS7ADComputer {
	<#
	.SYNOPSIS
		Find computer accounts in Active Directory.
	#>
	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	param(
		[Parameter(ParameterSetName = 'Identity', Position = 0)][string]$Identity,
		[Parameter(ParameterSetName = 'Filter')][string]$Filter,
		[string]$SearchBase,
		[string[]]$Property,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$computedFilter = $Filter
	if (-not $computedFilter) {
		if ($Identity) {
			# A computer's sAMAccountName ends in $ and nobody types that.
			$name = $Identity.TrimEnd('$')
			$escaped = ConvertTo-DirectoryFilterValue -Value $name
			$escapedDollar = ConvertTo-DirectoryFilterValue -Value ($name + '$')
			$computedFilter = "(&(objectClass=computer)(|(sAMAccountName=$escapedDollar)" +
			"(cn=$escaped)(dNSHostName=$escaped)))"
		}
		else { $computedFilter = '(objectClass=computer)' }
	}

	$attributes = $script:OS7AdComputerAttributes
	if ($Property) { $attributes = $Property }

	$rows = @(Search-Directory -Session $activeSession.DirectorySession `
			-SearchBase (Get-OS7AdSearchBase -Session $activeSession -SearchBase $SearchBase) `
			-Filter $computedFilter -Property $attributes)

	foreach ($row in $rows) { ConvertTo-OS7AdComputer -Row $row }
}

function Get-OS7ADOrganizationalUnit {
	<#
	.SYNOPSIS
		Find organisational units.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Position = 0)][string]$Identity,
		[string]$SearchBase,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$computedFilter = '(objectClass=organizationalUnit)'
	if ($Identity) {
		$escaped = ConvertTo-DirectoryFilterValue -Value $Identity
		$computedFilter = "(&(objectClass=organizationalUnit)(|(ou=$escaped)(distinguishedName=$escaped)))"
	}

	$rows = @(Search-Directory -Session $activeSession.DirectorySession `
			-SearchBase (Get-OS7AdSearchBase -Session $activeSession -SearchBase $SearchBase) `
			-Filter $computedFilter -Property @('distinguishedName', 'ou', 'description', 'whenCreated'))

	foreach ($row in $rows) {
		[pscustomobject]@{
			PSTypeName        = 'OS7.AD.OrganizationalUnit'
			Name              = Get-DirectoryAttributeScalar -Attributes $row.Attributes -Name 'ou'
			Description       = Get-DirectoryAttributeScalar -Attributes $row.Attributes -Name 'description'
			Created           = ConvertFrom-DirectoryGeneralizedTime -Value (
				Get-DirectoryAttributeScalar -Attributes $row.Attributes -Name 'whenCreated')
			DistinguishedName = $row.Dn
		}
	}
}

function Search-OS7AD {
	<#
	.SYNOPSIS
		Run a raw LDAP filter and get the rows back undecorated.

	.DESCRIPTION
		THE HONEST WAY OUT. Everything this file does not name is reachable
		here, which is what keeps a curated surface from being a cage. The
		rows are the Directory module's own shape — Dn plus an attribute map —
		because inventing a third object shape for "anything at all" would
		mean deciding, for every attribute in the schema, how to render it.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Filter,
		[string]$SearchBase,
		[ValidateSet('Base', 'OneLevel', 'Subtree')][string]$Scope = 'Subtree',
		[string[]]$Property = @(),
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	return @(Search-Directory -Session $activeSession.DirectorySession `
			-SearchBase (Get-OS7AdSearchBase -Session $activeSession -SearchBase $SearchBase) `
			-Filter $Filter -Scope $Scope -Property $Property)
}

function Get-OS7ADObject {
	<#
	.SYNOPSIS
		One object by distinguished name, with every attribute it carries.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0)][string]$DistinguishedName,
		[string[]]$Property = @(),
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$rows = @(Search-Directory -Session $activeSession.DirectorySession `
			-SearchBase $DistinguishedName -Filter '(objectClass=*)' -Scope Base -Property $Property)
	if ($rows.Count -eq 0) { return $null }
	return $rows[0]
}

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

function New-OS7ADUser {
	<#
	.SYNOPSIS
		Create a user account.

	.DESCRIPTION
		THE ORDER HERE IS NOT ARBITRARY AND CANNOT BE CHANGED. Active
		Directory will not enable an account that has no password, and it will
		not accept a password over an unencrypted connection. So: create
		disabled, set the password, then enable. A version that tried to enable
		first would fail with a message about the account, not about the
		password, which is the wrong place to send somebody.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[Parameter(Mandatory)][string]$Path,
		[securestring]$Password,
		[string]$DisplayName,
		[string]$GivenName,
		[string]$Surname,
		[string]$UserPrincipalName,
		[string]$Mail,
		[string]$Description,
		[switch]$Enabled,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$commonName = $DisplayName
	if (-not $commonName) { $commonName = $Name }
	$targetDn = 'CN=' + (ConvertTo-DirectoryDnValue -Value $commonName) + ',' + $Path

	if ($Enabled -and -not $Password) {
		throw ('An account cannot be created enabled without a password: Active Directory ' +
			'refuses to clear ACCOUNTDISABLE on an account that has none.')
	}

	if (-not $PSCmdlet.ShouldProcess($targetDn, 'create user')) { return $null }

	$attributes = @{
		sAMAccountName     = $Name
		userAccountControl = '514'
	}
	if ($DisplayName) { $attributes['displayName'] = $DisplayName }
	if ($GivenName) { $attributes['givenName'] = $GivenName }
	if ($Surname) { $attributes['sn'] = $Surname }
	if ($Mail) { $attributes['mail'] = $Mail }
	if ($Description) { $attributes['description'] = $Description }
	if ($UserPrincipalName) { $attributes['userPrincipalName'] = $UserPrincipalName }

	$null = New-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $targetDn -ObjectClass @('user') -Attribute $attributes -Confirm:$false

	if ($Password) {
		$null = Set-DirectoryPassword -Session $activeSession.DirectorySession `
			-DistinguishedName $targetDn -NewPassword $Password -Confirm:$false
	}
	if ($Enabled) {
		$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $targetDn -Name 'userAccountControl' -Value '512' -Confirm:$false
	}

	# READ IT BACK. The point is not that the server accepted three requests;
	# it is that the account now exists in the state that was asked for.
	return (Get-OS7ADUser -Identity $Name -Session $activeSession)
}

function Set-OS7ADUser {
	<#
	.SYNOPSIS
		Change attributes of a user account.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[string]$DisplayName,
		[string]$GivenName,
		[string]$Surname,
		[string]$Mail,
		[string]$Title,
		[string]$Department,
		[string]$Description,
		[hashtable]$Attribute,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADUser -Identity $Identity -Session $activeSession)
	if ($found.Count -eq 0) { throw "No user matched '$Identity'." }
	if ($found.Count -gt 1) {
		throw "'$Identity' matched $($found.Count) users. Name one by distinguished name."
	}
	$targetDn = $found[0].DistinguishedName

	$changes = @{}
	if ($PSBoundParameters.ContainsKey('DisplayName')) { $changes['displayName'] = $DisplayName }
	if ($PSBoundParameters.ContainsKey('GivenName')) { $changes['givenName'] = $GivenName }
	if ($PSBoundParameters.ContainsKey('Surname')) { $changes['sn'] = $Surname }
	if ($PSBoundParameters.ContainsKey('Mail')) { $changes['mail'] = $Mail }
	if ($PSBoundParameters.ContainsKey('Title')) { $changes['title'] = $Title }
	if ($PSBoundParameters.ContainsKey('Department')) { $changes['department'] = $Department }
	if ($PSBoundParameters.ContainsKey('Description')) { $changes['description'] = $Description }
	if ($Attribute) { foreach ($key in $Attribute.Keys) { $changes[$key] = $Attribute[$key] } }

	if ($changes.Count -eq 0) { return $found[0] }
	if (-not $PSCmdlet.ShouldProcess($targetDn, "set $($changes.Keys -join ', ')")) {
		return $found[0]
	}

	foreach ($key in $changes.Keys) {
		$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $targetDn -Name $key -Value $changes[$key] `
			-Operation Replace -Confirm:$false
	}

	return (Get-OS7ADUser -Identity $targetDn -Session $activeSession)
}

function New-OS7ADGroup {
	<#
	.SYNOPSIS
		Create a group.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[Parameter(Mandatory)][string]$Path,
		[ValidateSet('Global', 'DomainLocal', 'Universal')][string]$Scope = 'Global',
		[switch]$DistributionList,
		[string]$Description,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	# groupType is a bitfield: 2 global, 4 domain local, 8 universal, and the
	# high bit says "security" rather than "distribution list". Spelled out
	# because the constant that usually appears in scripts, -2147483646, is
	# unreadable and is only one of the six valid combinations.
	$scopeBit = switch ($Scope) { 'Global' { 2 } 'DomainLocal' { 4 } 'Universal' { 8 } }
	$groupType = $scopeBit
	if (-not $DistributionList) { $groupType = $scopeBit - 2147483648 }

	$targetDn = 'CN=' + (ConvertTo-DirectoryDnValue -Value $Name) + ',' + $Path
	if (-not $PSCmdlet.ShouldProcess($targetDn, 'create group')) { return $null }

	$attributes = @{ sAMAccountName = $Name; groupType = [string]$groupType }
	if ($Description) { $attributes['description'] = $Description }

	$null = New-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $targetDn -ObjectClass @('group') -Attribute $attributes -Confirm:$false

	return (Get-OS7ADGroup -Identity $Name -Session $activeSession)
}

function Add-OS7ADGroupMember {
	<#
	.SYNOPSIS
		Add one or more members to a group.

	.DESCRIPTION
		Add, never Replace. Replacing a multi-valued attribute discards every
		value that was not sent, so "add one member" written the obvious way
		empties the group and the server reports success.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[Parameter(Mandatory, Position = 1)][string[]]$Member,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$group = @(Get-OS7ADGroup -Identity $Identity -Session $activeSession)
	if ($group.Count -eq 0) { throw "No group matched '$Identity'." }
	$groupDn = $group[0].DistinguishedName

	# BOTH KINDS ARE ASKED, ALWAYS, AND THEN THE ANSWERS ARE COUNTED. Taking
	# $found[0] resolved an ambiguous name to whatever came back first: a name
	# borne by two objects, or by a user AND a group of the same name, put the
	# wrong principal in the group and the server reported success — which is
	# this repository's most expensive shape, a write that worked on something
	# nobody chose. Set-OS7ADUser already refuses this for a user; the same rule
	# holds here, where the ambiguity can span two object kinds.
	$memberDns = foreach ($one in $Member) {
		if ($one -match '^(CN|OU)=') { $one }
		else {
			$found = @(Get-OS7ADUser -Identity $one -Session $activeSession) +
			@(Get-OS7ADGroup -Identity $one -Session $activeSession)
			if ($found.Count -eq 0) { throw "No user or group matched '$one'." }
			if ($found.Count -gt 1) {
				throw ("'$one' matched $($found.Count) objects, so which one to add is a " +
					'guess. Name it by distinguished name.')
			}
			$found[0].DistinguishedName
		}
	}

	if (-not $PSCmdlet.ShouldProcess($groupDn, "add $(@($memberDns).Count) member(s)")) {
		return $group[0]
	}

	$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $groupDn -Name 'member' -Value @($memberDns) `
		-Operation Add -Confirm:$false

	return (Get-OS7ADGroup -Identity $groupDn -Session $activeSession)
}

function Remove-OS7ADGroupMember {
	<#
	.SYNOPSIS
		Remove one or more members from a group.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[Parameter(Mandatory, Position = 1)][string[]]$Member,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$group = @(Get-OS7ADGroup -Identity $Identity -Session $activeSession)
	if ($group.Count -eq 0) { throw "No group matched '$Identity'." }
	$groupDn = $group[0].DistinguishedName

	# Add-OS7ADGroupMember's rule, for the same reason and with more at stake:
	# removing the wrong principal takes an access away, and the account that
	# stops working is not the one anybody was looking at.
	$memberDns = foreach ($one in $Member) {
		if ($one -match '^(CN|OU)=') { $one }
		else {
			$found = @(Get-OS7ADUser -Identity $one -Session $activeSession) +
			@(Get-OS7ADGroup -Identity $one -Session $activeSession)
			if ($found.Count -eq 0) { throw "No user or group matched '$one'." }
			if ($found.Count -gt 1) {
				throw ("'$one' matched $($found.Count) objects, so which one to remove is a " +
					'guess. Name it by distinguished name.')
			}
			$found[0].DistinguishedName
		}
	}

	if (-not $PSCmdlet.ShouldProcess($groupDn, "remove $(@($memberDns).Count) member(s)")) {
		return $group[0]
	}

	$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $groupDn -Name 'member' -Value @($memberDns) `
		-Operation Delete -Confirm:$false

	return (Get-OS7ADGroup -Identity $groupDn -Session $activeSession)
}

function Enable-OS7ADAccount {
	<#
	.SYNOPSIS
		Enable a user or computer account.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		$Session
	)
	# THE GUARD IS HERE BECAUSE THE WRITE IS DELEGATED. Set-OS7AdAccountDisabledBit
	# is a plain function with no [CmdletBinding()] of its own and it writes with
	# -Confirm:$false, so a SupportsShouldProcess declared up here and never
	# called is a claim about a prompt that cannot happen. The target is the
	# identity as typed rather than the resolved DN: the lookup is the delegate's
	# and asking before it runs is the whole point.
	if (-not $PSCmdlet.ShouldProcess($Identity, 'enable account')) { return $null }
	return (Set-OS7AdAccountDisabledBit -Identity $Identity -Disabled:$false -Session $Session)
}

function Disable-OS7ADAccount {
	<#
	.SYNOPSIS
		Disable a user or computer account.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		$Session
	)
	# ConfirmImpact = 'High' ASKS FOR A PROMPT AND ONLY A ShouldProcess CALL
	# PRODUCES ONE. Without this line the declaration above was decoration: the
	# delegate below carries -Confirm:$false to the directory, so disabling an
	# account — which locks a person out of every machine in the domain — went
	# through with no question asked and the cmdlet's own help implying one.
	if (-not $PSCmdlet.ShouldProcess($Identity, 'disable account')) { return $null }
	return (Set-OS7AdAccountDisabledBit -Identity $Identity -Disabled:$true -Session $Session)
}

function Set-OS7AdAccountDisabledBit {
	<#
	.SYNOPSIS
		Internal. Flip ACCOUNTDISABLE, preserving every other flag.

	.DESCRIPTION
		READ, MODIFY THE ONE BIT, WRITE. Writing 512 or 514 outright — which is
		what almost every example on the internet does — silently discards
		DONT_EXPIRE_PASSWORD, SMARTCARD_REQUIRED, TRUSTED_FOR_DELEGATION and
		everything else the account had. The server reports success, and what
		was lost is invisible until something that depended on it stops
		working.
	#>
	param(
		[Parameter(Mandatory)][string]$Identity,
		[switch]$Disabled,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADUser -Identity $Identity -Session $activeSession)
	$isComputer = $false
	if ($found.Count -eq 0) {
		$found = @(Get-OS7ADComputer -Identity $Identity -Session $activeSession)
		$isComputer = ($found.Count -gt 0)
	}
	if ($found.Count -eq 0) { throw "No account matched '$Identity'." }
	$targetDn = $found[0].DistinguishedName

	$row = Get-OS7ADObject -DistinguishedName $targetDn -Property @('userAccountControl') `
		-Session $activeSession
	if (-not $row) {
		# Get-OS7ADObject returns $null for an empty result, and reaching into
		# that is a PowerShell property error under Set-StrictMode rather than
		# anything about the directory. The refusal comes BEFORE the write, so
		# an account whose flags could not be read is left exactly as it was.
		throw ("'$targetDn' was found and then could not be read back, so its flags are " +
			'unknown and nothing was changed.')
	}
	$current = ConvertTo-DirectoryInt64 -Value (
		Get-DirectoryAttributeScalar -Attributes $row.Attributes -Name 'userAccountControl')
	if ($null -eq $current) {
		throw "'$targetDn' has no userAccountControl, so this is not an account that can be enabled."
	}

	$updated = if ($Disabled) { $current -bor 0x2 } else { $current -band (-bnot 0x2) }
	if ($updated -eq $current) { return $found[0] }

	$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $targetDn -Name 'userAccountControl' -Value ([string]$updated) `
		-Operation Replace -Confirm:$false

	# READ BACK THE KIND OF OBJECT THAT WAS FOUND. Get-OS7ADUser's filter carries
	# (objectCategory=person), which no computer account matches, so a computer
	# read back through it matched zero rows and the cmdlet returned NOTHING
	# after the write had already gone through — the one shape this repository
	# keeps paying for, where the operator sees no result and the machine
	# changed anyway. By distinguished name, because Get-OS7ADComputer's
	# -Identity branch asks sAMAccountName, cn and dNSHostName only and a DN
	# handed to it matches nothing either.
	if ($isComputer) {
		$escapedDn = ConvertTo-DirectoryFilterValue -Value $targetDn
		return (Get-OS7ADComputer -Filter "(&(objectClass=computer)(distinguishedName=$escapedDn))" `
				-Session $activeSession)
	}
	return (Get-OS7ADUser -Identity $targetDn -Session $activeSession)
}

function Unlock-OS7ADAccount {
	<#
	.SYNOPSIS
		Unlock an account that lockout policy has locked.

	.DESCRIPTION
		Writing 0 to lockoutTime is what unlocks an account. It is NOT the same
		as enabling one, and the two get confused constantly: a locked account
		is enabled, and a disabled account cannot be unlocked into usefulness.
		Get-OS7ADUser reports both, separately, for that reason.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADUser -Identity $Identity -Session $activeSession)
	if ($found.Count -eq 0) { throw "No user matched '$Identity'." }
	$targetDn = $found[0].DistinguishedName

	if (-not $PSCmdlet.ShouldProcess($targetDn, 'unlock account')) { return $found[0] }

	$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $targetDn -Name 'lockoutTime' -Value '0' `
		-Operation Replace -Confirm:$false

	return (Get-OS7ADUser -Identity $targetDn -Session $activeSession)
}

function Reset-OS7ADAccountPassword {
	<#
	.SYNOPSIS
		Set a user's password.

	.DESCRIPTION
		Refuses over an unencrypted connection BEFORE the password reaches a
		socket — Active Directory would refuse too, but only after it had
		crossed the network.

		-Current changes a password as its owner rather than setting it as an
		administrator. They are different directory operations with different
		rights, and an administrator who has been delegated "reset password"
		but not "change password" can do exactly one of them.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[Parameter(Mandatory)][securestring]$NewPassword,
		[securestring]$CurrentPassword,
		[switch]$MustChangeAtNextLogon,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADUser -Identity $Identity -Session $activeSession)
	if ($found.Count -eq 0) { throw "No user matched '$Identity'." }
	$targetDn = $found[0].DistinguishedName

	if (-not $PSCmdlet.ShouldProcess($targetDn, 'set password')) { return $found[0] }

	$null = Set-DirectoryPassword -Session $activeSession.DirectorySession `
		-DistinguishedName $targetDn -NewPassword $NewPassword `
		-CurrentPassword $CurrentPassword -Confirm:$false

	if ($MustChangeAtNextLogon) {
		# pwdLastSet = 0 is how AD expresses "must change", and it is the one
		# case where zero does not mean "never".
		$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $targetDn -Name 'pwdLastSet' -Value '0' `
			-Operation Replace -Confirm:$false
	}

	return (Get-OS7ADUser -Identity $targetDn -Session $activeSession)
}

function Move-OS7ADObject {
	<#
	.SYNOPSIS
		Move an object to another container.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$DistinguishedName,
		[Parameter(Mandatory, Position = 1)][string]$TargetPath,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, "move to $TargetPath")) { return $null }

	return (Move-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $DistinguishedName `
			-NewParentDistinguishedName $TargetPath -Confirm:$false)
}

function Rename-OS7ADObject {
	<#
	.SYNOPSIS
		Rename an object, leaving it where it is.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$DistinguishedName,
		[Parameter(Mandatory, Position = 1)][string]$NewName,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$components = @(Split-DirectoryDn -DistinguishedName $DistinguishedName)
	if ($components.Count -lt 2) { throw "'$DistinguishedName' has no parent to stay under." }
	$parentDn = ($components[1..($components.Count - 1)] -join ',')

	# THE RDN ATTRIBUTE IS THE OBJECT'S OWN AND IT IS NOT ALWAYS cn. An
	# organisational unit is named by ou= and a container by cn=, and the schema
	# decides which — renaming an OU to CN=<name> is refused by Active Directory
	# with a message about the naming attribute that says nothing about this
	# cmdlet having chosen it. So it is taken from the name being renamed rather
	# than assumed. Split-DirectoryDn has already split on unescaped commas, so
	# everything before the first '=' is the attribute type.
	$rdnMatch = [regex]::Match($components[0], '^\s*([^=]+?)\s*=')
	if (-not $rdnMatch.Success) {
		throw "'$DistinguishedName' does not begin with an attribute=value and cannot be renamed."
	}
	$newRdn = $rdnMatch.Groups[1].Value + '=' + (ConvertTo-DirectoryDnValue -Value $NewName)

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, "rename to $NewName")) { return $null }

	return (Move-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $DistinguishedName -NewParentDistinguishedName $parentDn `
			-NewName $newRdn -Confirm:$false)
}

function Set-OS7ADObject {
	<#
	.SYNOPSIS
		Set any attribute on any object.

	.DESCRIPTION
		The escape hatch's writing half. -Operation is Replace, Add or Delete,
		and on a multi-valued attribute Replace discards everything not sent.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$DistinguishedName,
		[Parameter(Mandatory, Position = 1)][string]$Name,
		[Parameter(Mandatory, Position = 2)][AllowEmptyCollection()]$Value,
		[ValidateSet('Replace', 'Add', 'Delete')][string]$Operation = 'Replace',
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, "$Operation $Name")) { return $null }

	$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $DistinguishedName -Name $Name -Value $Value `
		-Operation $Operation -Confirm:$false

	return (Get-OS7ADObject -DistinguishedName $DistinguishedName -Property @($Name) `
			-Session $activeSession)
}

function Remove-OS7ADObject {
	<#
	.SYNOPSIS
		Delete an object.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$DistinguishedName,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	if (-not $PSCmdlet.ShouldProcess($DistinguishedName, 'delete directory object')) { return $null }

	return (Remove-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $DistinguishedName -Confirm:$false)
}
