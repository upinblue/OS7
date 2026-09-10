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

function Get-OS7ADPrincipalGroupMembership {
	<#
	.SYNOPSIS
		The groups an account is in — the inverse of Get-OS7ADGroupMember.

	.DESCRIPTION
		"What can this person reach" is asked far more often than "who is in
		this group", and the two are not the same query: this one starts at the
		account.

		THE PRIMARY GROUP IS NOT IN memberOf, AND THAT IS AD, NOT A BUG HERE.
		Every account has a primary group — Domain Users for a person, Domain
		Computers for a machine — recorded as a RID in primaryGroupID and
		DELIBERATELY absent from memberOf. A membership list built from memberOf
		alone therefore omits the one group almost every account is in, which
		reads as "this user is in no groups" for a fresh account. So the primary
		group is resolved separately, from the account's own SID with the RID
		replaced, and included. -ExcludePrimaryGroup asks for the raw memberOf
		view instead.

		-Recursive uses the directory's matching rule 1.2.840.113556.1.4.1941 on
		`member`, which is the same rule Get-OS7ADGroupMember uses in the other
		direction: the domain controller walks the nesting, because it is the one
		that walks it when it decides access. The primary group is added to that
		result too, but its own nesting is not walked — a primary group is a
		direct membership by construction.

	.EXAMPLE
		Get-OS7ADPrincipalGroupMembership -Identity p-schmidt

	.EXAMPLE
		Get-OS7ADPrincipalGroupMembership -Identity p-schmidt -Recursive | Select-Object Name
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[switch]$Recursive,
		[switch]$ExcludePrimaryGroup,
		[string]$SearchBase,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session
	$base = Get-OS7AdSearchBase -Session $activeSession -SearchBase $SearchBase

	# A COMPUTER IS AN ACCOUNT TOO, and its groups are as ordinary a question as
	# a person's. Get-OS7ADUser's filter carries (objectCategory=person), so a
	# machine matches nothing there and has to be looked for as what it is.
	$found = @(Get-OS7ADUser -Identity $Identity -SearchBase $base -Session $activeSession)
	if ($found.Count -eq 0) {
		$found = @(Get-OS7ADComputer -Identity $Identity -SearchBase $base -Session $activeSession)
	}
	if ($found.Count -eq 0) { throw "No user or computer matched '$Identity'." }
	if ($found.Count -gt 1) {
		throw "'$Identity' matched $($found.Count) accounts. Name one by distinguished name."
	}
	$principalDn = $found[0].DistinguishedName

	# ASK THE DIRECTORY FOR THE ACCOUNT'S OWN ATTRIBUTES, and do not reach into
	# the object a converter produced. OS7.AD.Computer carries no MemberOf at all
	# — memberOf is not in $script:OS7AdComputerAttributes — so $principal.MemberOf
	# was a PowerShell property error for a machine account under Set-StrictMode:
	# an error about a property, in a cmdlet about groups. Measured 2026-09-07
	# against the test DC's own computer object. One read, three attributes, and
	# no assumption about which shape the account came back as.
	$row = Get-OS7ADObject -DistinguishedName $principalDn `
		-Property @('memberOf', 'primaryGroupID', 'objectSid') -Session $activeSession
	if (-not $row) {
		throw ("'$principalDn' was found and then could not be read back, so its group " +
			'memberships are unknown and this is not reporting an empty list for them.')
	}
	$memberOf = @(Get-DirectoryAttributeValues -Attributes $row.Attributes -Name 'memberOf')
	$primaryRid = ConvertTo-DirectoryInt64 -Value (
		Get-DirectoryAttributeScalar -Attributes $row.Attributes -Name 'primaryGroupID')
	$principalSid = ConvertFrom-DirectorySid -Bytes (
		Get-DirectoryAttributeScalar -Attributes $row.Attributes -Name 'objectSid')

	# Emit each group once. A recursive answer and a primary group can name the
	# same group, and a duplicate row in a membership list is a fact nobody
	# measured.
	$seen = [System.Collections.Generic.HashSet[string]]::new(
		[System.StringComparer]::InvariantCultureIgnoreCase)

	if ($Recursive) {
		$escapedDn = ConvertTo-DirectoryFilterValue -Value $principalDn
		$rows = @(Search-Directory -Session $activeSession.DirectorySession -SearchBase $base `
				-Filter "(&(objectClass=group)(member:1.2.840.113556.1.4.1941:=$escapedDn))" `
				-Property $script:OS7AdGroupAttributes)
		foreach ($groupRow in $rows) {
			if ($seen.Add($groupRow.Dn)) { ConvertTo-OS7AdGroup -Row $groupRow }
		}
	}
	else {
		# THE GROUP DN IS THE SEARCH BASE AND NOT PART OF A FILTER, so nothing
		# here is escaped — RFC 4515 escaping belongs to filter values, and a
		# base handed through it would be a DN the server does not have. Same
		# rule as Get-OS7ADGroupMember's direct branch.
		foreach ($groupDn in $memberOf) {
			$rows = @(Search-Directory -Session $activeSession.DirectorySession `
					-SearchBase $groupDn -Filter '(objectClass=group)' -Scope Base `
					-Property $script:OS7AdGroupAttributes)
			foreach ($groupRow in $rows) {
				if ($seen.Add($groupRow.Dn)) { ConvertTo-OS7AdGroup -Row $groupRow }
			}
		}
	}

	if ($ExcludePrimaryGroup) { return }

	# The primary group's SID is the account's own SID with the last RID swapped
	# for primaryGroupID. Read from the account rather than assumed to be 513:
	# it is settable, and on a machine account it is 515, not 513.
	if ($null -eq $primaryRid -or -not $principalSid) { return }

	$domainSid = $principalSid -replace '-\d+$', ''
	$primarySid = "$domainSid-$primaryRid"
	$escapedSid = ConvertTo-DirectoryFilterValue -Value $primarySid
	# AD accepts a SID in its string form in a filter, which is what makes this
	# one search rather than a decode of every group's objectSid.
	$primaryRows = @(Search-Directory -Session $activeSession.DirectorySession -SearchBase $base `
			-Filter "(&(objectClass=group)(objectSid=$escapedSid))" `
			-Property $script:OS7AdGroupAttributes)
	foreach ($primaryRow in $primaryRows) {
		if ($seen.Add($primaryRow.Dn)) { ConvertTo-OS7AdGroup -Row $primaryRow }
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

	# THE ACCOUNT IS CREATED DISABLED AND WITHOUT A PASSWORD, so a failure at the
	# password or enable step leaves a half-built account behind — and because the
	# read-back below never runs, the operator sees only the error and not the
	# stub. Measured 2026-09-06: a password the domain's policy refused left a
	# disabled, passwordless 't.os7created' on the DC. So the two steps that can
	# fail on server policy are wound back: either the account exists as asked, or
	# it does not exist. The error is re-thrown naming the step, over the now-
	# translated message from the Directory layer.
	try {
		if ($Password) {
			$null = Set-DirectoryPassword -Session $activeSession.DirectorySession `
				-DistinguishedName $targetDn -NewPassword $Password -Confirm:$false
		}
		if ($Enabled) {
			$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
				-DistinguishedName $targetDn -Name 'userAccountControl' -Value '512' -Confirm:$false
		}
	}
	catch {
		$reason = $_.Exception.Message
		# Name the step only when it is unambiguous. With both requested, an extra
		# read would be needed to tell which failed, and guessing would be the
		# kind of invented detail this repository does not ship.
		$step = if ($Password -and $Enabled) { 'setting the password or enabling the account' }
		elseif ($Password) { 'setting the password' }
		else { 'enabling the account' }
		# Wind back the stub. Remove-DirectoryEntry is best-effort: if even the
		# delete fails, say so rather than swallow it, so the operator knows a
		# disabled stub is there to clean up.
		$removed = $true
		try {
			$null = Remove-DirectoryEntry -Session $activeSession.DirectorySession `
				-DistinguishedName $targetDn -Confirm:$false
		}
		catch { $removed = $false }
		$tail = if ($removed) {
			'and the half-created account was removed'
		}
		else {
			"and the half-created, DISABLED account '$targetDn' could NOT be removed and remains"
		}
		throw "Creating '$Name' failed while $step ($reason) $tail."
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

function Set-OS7ADGroup {
	<#
	.SYNOPSIS
		Change a group's description, mail address or display name.

	.DESCRIPTION
		THE GROUP'S SCOPE AND TYPE ARE DELIBERATELY NOT HERE. groupType looks
		like an attribute this could set, and Active Directory enforces rules on
		which transitions are legal — a global group cannot become domain local
		in one step, and neither can change while it is a member of a group whose
		scope forbids it. AD refuses an illegal transition with an operational
		error that names none of that. Rather than offer a parameter that works
		for some groups and fails opaquely for others, this leaves groupType to
		Set-OS7ADObject, where the operator is plainly writing a raw attribute.

		-Attribute is the same escape hatch Set-OS7ADUser carries, for the
		attributes this does not name.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[string]$Description,
		[string]$Mail,
		[string]$DisplayName,
		[hashtable]$Attribute,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADGroup -Identity $Identity -Session $activeSession)
	if ($found.Count -eq 0) { throw "No group matched '$Identity'." }
	if ($found.Count -gt 1) {
		throw "'$Identity' matched $($found.Count) groups. Name one by distinguished name."
	}
	$targetDn = $found[0].DistinguishedName

	# ContainsKey and not truthiness: an empty string is how an attribute is
	# CLEARED, and `if ($Description)` would silently ignore that request.
	$changes = @{}
	if ($PSBoundParameters.ContainsKey('Description')) { $changes['description'] = $Description }
	if ($PSBoundParameters.ContainsKey('Mail')) { $changes['mail'] = $Mail }
	if ($PSBoundParameters.ContainsKey('DisplayName')) { $changes['displayName'] = $DisplayName }
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

	return (Get-OS7ADGroup -Identity $targetDn -Session $activeSession)
}

function New-OS7ADOrganizationalUnit {
	<#
	.SYNOPSIS
		Create an organisational unit.

	.DESCRIPTION
		AN OU'S RDN IS `OU=`, NOT `CN=`, and that is the whole reason this is a
		separate cmdlet rather than a note in New-OS7ADGroup's help: an
		organizationalUnit created with a CN= relative name is refused by the
		schema, and the error is about naming attributes rather than about the
		thing the operator got wrong.

		NOT PROTECTED FROM ACCIDENTAL DELETION, AND THAT DIFFERS FROM WINDOWS.
		Microsoft's New-ADOrganizationalUnit defaults -ProtectedFromAccidentalDeletion
		to $true, which is not an attribute but a DENY access-control entry on
		the OU's security descriptor. Writing one means composing and writing
		nTSecurityDescriptor over LDAP, which this surface does not do anywhere
		yet. So an OU created here is deletable, an administrator used to Windows
		will expect otherwise, and saying so is better than a parameter that
		accepts $true and does nothing.

	.EXAMPLE
		New-OS7ADOrganizationalUnit -Name Workstations -Path 'DC=corp,DC=example,DC=com'
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[Parameter(Mandatory)][string]$Path,
		[string]$Description,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$targetDn = 'OU=' + (ConvertTo-DirectoryDnValue -Value $Name) + ',' + $Path
	if (-not $PSCmdlet.ShouldProcess($targetDn, 'create organisational unit')) { return $null }

	$attributes = @{ ou = $Name }
	if ($Description) { $attributes['description'] = $Description }

	$null = New-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $targetDn -ObjectClass @('organizationalUnit') `
		-Attribute $attributes -Confirm:$false

	# READ IT BACK BY DISTINGUISHED NAME. By -Name would match every OU with
	# that name anywhere in the domain, which is legal and common — Workstations
	# under two different sites — so the read-back has to name the one created.
	return (Get-OS7ADOrganizationalUnit -Identity $targetDn -Session $activeSession)
}

function Set-OS7ADOrganizationalUnit {
	<#
	.SYNOPSIS
		Change an organisational unit's description.

	.DESCRIPTION
		Renaming an OU is Rename-OS7ADObject and moving one is Move-OS7ADObject,
		because both are ModifyDN operations and not attribute writes — the same
		split every other object type here has.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[string]$Description,
		[hashtable]$Attribute,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADOrganizationalUnit -Identity $Identity -Session $activeSession)
	if ($found.Count -eq 0) { throw "No organisational unit matched '$Identity'." }
	if ($found.Count -gt 1) {
		throw ("'$Identity' matched $($found.Count) organisational units. Name one by " +
			'distinguished name — the same name under two parents is legal.')
	}
	$targetDn = $found[0].DistinguishedName

	$changes = @{}
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

	return (Get-OS7ADOrganizationalUnit -Identity $targetDn -Session $activeSession)
}

function Remove-OS7ADOrganizationalUnit {
	<#
	.SYNOPSIS
		Delete an organisational unit, refusing while anything is still in it.

	.DESCRIPTION
		LDAP WILL NOT DELETE A NON-LEAF OBJECT, and what it says about that is
		notAllowedOnNonLeaf (LDAP 66) — a sentence about the protocol, for an OU
		that has three computers in it. So this COUNTS the children first and
		refuses with the number, naming what has to happen before the delete can.

		THERE IS NO -Recursive HERE ON PURPOSE. Windows deletes a populated OU
		with the tree-delete control (1.2.840.113556.1.4.805), which the
		Directory layer does not send and which deletes a subtree with one
		request and no second thought. An operator who means that can empty the
		OU, or reach for Search-OS7AD and Remove-OS7ADObject and see each object
		go. A one-word switch that silently removes a hundred accounts is not a
		surface this repository wants to hand out.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADOrganizationalUnit -Identity $Identity -Session $activeSession)
	if ($found.Count -eq 0) { throw "No organisational unit matched '$Identity'." }
	if ($found.Count -gt 1) {
		throw ("'$Identity' matched $($found.Count) organisational units. Name one by " +
			'distinguished name.')
	}
	$targetDn = $found[0].DistinguishedName

	# OneLevel and not Subtree: the question is whether this OU is a leaf, which
	# is what LDAP refuses on. A Subtree search would also return the OU itself.
	$children = @(Search-Directory -Session $activeSession.DirectorySession `
			-SearchBase $targetDn -Filter '(objectClass=*)' -Scope OneLevel `
			-Property @('distinguishedName'))
	if ($children.Count -gt 0) {
		throw ("'$targetDn' still contains $($children.Count) object(s), and LDAP does not " +
			'delete an object that is not a leaf. Move or remove them first; ' +
			'Search-OS7AD -SearchBase that DN lists them.')
	}

	if (-not $PSCmdlet.ShouldProcess($targetDn, 'delete organisational unit')) { return $null }

	return (Remove-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $targetDn -Confirm:$false)
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

function Set-OS7ADAccountExpiration {
	<#
	.SYNOPSIS
		Set or clear the date an account stops working.

	.DESCRIPTION
		The counterpart to Get-OS7ADUser's AccountExpires, which this surface
		could read and not write. What it is for is the account that should stop
		working on its own: a contractor, a temporary, an intern.

		"NEVER" IS TWO DIFFERENT VALUES AND NEITHER OF THEM IS A DATE. AD writes
		accountExpires as a FILETIME, and treats BOTH 0 and 0x7FFFFFFFFFFFFFFF as
		"does not expire" — ConvertFrom-DirectoryFileTime already returns $null
		for both, which is why the read side never showed a date in 1601.
		-Never writes 0, the value the Windows tools write.

		THE INSTANT IS WRITTEN AS GIVEN, and Active Directory expires the account
		AT it, not at the end of that day. Microsoft's own console adds a day
		behind the operator's back, so "expires 31 March" set there and read here
		is 1 April. This does not do that: a DateTime means that moment. A
		DateTime with no zone is taken as local time and converted, because
		FILETIME is UTC and a naive cast would move the expiry by the offset.

	.EXAMPLE
		Set-OS7ADAccountExpiration -Identity t-mueller -DateTime '2026-12-31 18:00'

	.EXAMPLE
		Set-OS7ADAccountExpiration -Identity t-mueller -Never
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'At')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		[Parameter(Mandatory, ParameterSetName = 'At', Position = 1)][datetime]$DateTime,
		[Parameter(Mandatory, ParameterSetName = 'Never')][switch]$Never,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADUser -Identity $Identity -Session $activeSession)
	if ($found.Count -eq 0) {
		$found = @(Get-OS7ADComputer -Identity $Identity -Session $activeSession)
	}
	if ($found.Count -eq 0) { throw "No user or computer matched '$Identity'." }
	if ($found.Count -gt 1) {
		throw "'$Identity' matched $($found.Count) accounts. Name one by distinguished name."
	}
	$targetDn = $found[0].DistinguishedName

	$value = '0'
	$what = 'clear the expiry date'
	if (-not $Never) {
		# ToFileTimeUtc on an Unspecified DateTime treats it as LOCAL, which is
		# what an operator typing a date means; ToUniversalTime first would
		# double-convert a value that is already Utc. Kind decides, explicitly.
		$instant = $DateTime
		if ($instant.Kind -eq [System.DateTimeKind]::Unspecified) {
			$instant = [datetime]::SpecifyKind($instant, [System.DateTimeKind]::Local)
		}
		$value = [string]$instant.ToFileTimeUtc()
		$what = "expire at $($instant.ToUniversalTime().ToString('u'))"
	}

	if (-not $PSCmdlet.ShouldProcess($targetDn, $what)) { return $found[0] }

	$null = Set-DirectoryEntry -Session $activeSession.DirectorySession `
		-DistinguishedName $targetDn -Name 'accountExpires' -Value $value `
		-Operation Replace -Confirm:$false

	# READ BACK THE KIND OF OBJECT THAT WAS FOUND — the #74-shaped trap
	# Set-OS7AdAccountDisabledBit records: a computer read back through
	# Get-OS7ADUser matches nothing, and the cmdlet would return nothing after
	# the write had gone through.
	if ($found[0].PSTypeNames -contains 'OS7.AD.Computer') {
		$escapedDn = ConvertTo-DirectoryFilterValue -Value $targetDn
		return (Get-OS7ADComputer -Filter "(&(objectClass=computer)(distinguishedName=$escapedDn))" `
				-Session $activeSession)
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

function Resolve-OS7AdDeletionTarget {
	<#
	.SYNOPSIS
		Internal. The one distinguished name an identity names, or a refusal.

	.DESCRIPTION
		DELETION IS THE OPERATION THAT MUST NOT GUESS. Remove-OS7ADObject takes a
		distinguished name because a DN is unambiguous; the by-identity cmdlets
		that call this take what an operator types, which is not. A name that
		matches two accounts is refused with both DNs, rather than the first one
		being deleted — a Windows admin's habit of typing a bare name is exactly
		how the wrong object goes.
	#>
	param(
		[Parameter(Mandatory)]$Found,
		[Parameter(Mandatory)][string]$Identity,
		[Parameter(Mandatory)][string]$Kind
	)

	# NOT $matches: that is an automatic variable PowerShell fills from -match,
	# and reusing an automatic name is BUILD-NOTES #65's class of defect.
	$candidates = @($Found)
	if ($candidates.Count -eq 0) { throw "No $Kind matched '$Identity'." }
	if ($candidates.Count -gt 1) {
		$names = ($candidates | ForEach-Object { $_.DistinguishedName }) -join '; '
		throw ("'$Identity' matched $($candidates.Count) ${Kind}s and nothing was deleted. " +
			"Name one by distinguished name: $names")
	}
	return $candidates[0].DistinguishedName
}

function Remove-OS7ADUser {
	<#
	.SYNOPSIS
		Delete a user account, named the way an operator names one.

	.DESCRIPTION
		Remove-OS7ADObject needs a distinguished name. This takes a
		sAMAccountName, a userPrincipalName or a DN, resolves it to exactly one
		account, and refuses when it is more than one.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$targetDn = Resolve-OS7AdDeletionTarget -Identity $Identity -Kind 'user' `
		-Found @(Get-OS7ADUser -Identity $Identity -Session $activeSession)

	if (-not $PSCmdlet.ShouldProcess($targetDn, 'delete user')) { return $null }

	return (Remove-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $targetDn -Confirm:$false)
}

function Remove-OS7ADGroup {
	<#
	.SYNOPSIS
		Delete a group, named the way an operator names one.

	.DESCRIPTION
		THE MEMBERS ARE NOT DELETED AND THEIR ACCESS IS. Deleting a group removes
		the membership from every account in it, which is a change to what those
		people can reach and is invisible in the accounts themselves. The member
		count is reported in the confirmation for that reason.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Identity,
		$Session
	)

	Import-OS7DirectoryLayer
	$activeSession = Resolve-OS7AdminSession -Session $Session

	$found = @(Get-OS7ADGroup -Identity $Identity -Session $activeSession)
	$targetDn = Resolve-OS7AdDeletionTarget -Identity $Identity -Kind 'group' -Found $found

	$count = $found[0].MemberCount
	if (-not $PSCmdlet.ShouldProcess($targetDn, "delete group and the membership of its $count member(s)")) {
		return $null
	}

	return (Remove-DirectoryEntry -Session $activeSession.DirectorySession `
			-DistinguishedName $targetDn -Confirm:$false)
}
