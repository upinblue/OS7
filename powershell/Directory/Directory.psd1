# =============================================================================
# Directory — LDAP, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like powershell/Zfs,
# powershell/Net, powershell/Time and powershell/Systemd: it knows LDAP, X.500
# and the Active Directory schema, and knows nothing about OS/7.
#
# It exists because System.DirectoryServices.Protocols ships inside PowerShell
# 7.6.5 on Linux and works there — measured against a real domain controller on
# 2026-08-27 — while System.DirectoryServices (ADSI) loads and then throws
# "not supported on this platform". One of those two is a foundation and the
# other is a trap, and only a measurement tells them apart.
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf. The
# 0.0.0 here is the "nobody stamped this" value, deliberately implausible.
# =============================================================================
@{
	RootModule        = 'Directory.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = '99994c32-fe5e-48c3-afea-89130b9c241f'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'LDAP for PowerShell on Ubuntu: bound sessions, paged searches, RFC 4514/4515 escaping, Active Directory attribute decoding, and what an LdapException actually means.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# The connection. TLS is the default and not a preference: LDAP
		# sign-and-seal cannot be switched on from .NET on Linux (measured),
		# and a hardened AD refuses an unsigned simple bind outright.
		'Connect-DirectoryServer', 'Disconnect-DirectoryServer',
		# What the SERVER says, rather than what was typed in. A bind that
		# raises no exception is not proof of identity; RFC 4532 is.
		'Get-DirectoryWhoAmI', 'Get-DirectoryRootDse',
		# Reading and writing. Search-Directory follows the pages to the end,
		# because AD's MaxPageSize is 1000 and a laboratory domain never
		# reaches it — the failure is a short list and no error at all.
		'Search-Directory', 'New-DirectoryEntry', 'Set-DirectoryEntry',
		'Remove-DirectoryEntry', 'Move-DirectoryEntry',
		# The password path is its own function because it carries three traps
		# that all present as something else. See its help.
		'Set-DirectoryPassword',
		# The escaping and conversion rules. Exported deliberately: the OS7
		# layer builds filters and DNs, and a second implementation of either
		# is BUILD-NOTES #66 — one specification, two routes, nobody diffing.
		'ConvertTo-DirectoryFilterValue', 'ConvertTo-DirectoryDnValue',
		'ConvertTo-DirectoryDomainDn', 'Split-DirectoryDn',
		'Get-DirectoryAttributeValues', 'Get-DirectoryAttributeScalar',
		'ConvertTo-DirectoryInt64',
		'ConvertFrom-DirectoryFileTime', 'ConvertFrom-DirectoryGeneralizedTime',
		'ConvertFrom-DirectorySid', 'ConvertFrom-DirectoryGuid',
		'Get-DirectoryAccountControl', 'Get-DirectoryErrorMeaning',
		'Get-DirectoryLdapException',
		# Realm membership — the domain JOIN half. Everything here starts a
		# process (adcli, klist, getent) rather than opening a socket, which is
		# why it uses the command-runner seam and not the connection one.
		'Join-DirectoryRealm', 'Remove-DirectoryRealm', 'Update-DirectoryRealm',
		'Get-DirectoryRealmConfiguration', 'Get-DirectoryKeytabPrincipal',
		'New-DirectorySssdConfiguration', 'Get-DirectoryIdentityResolution',
		'Get-DirectoryTicket', 'New-DirectoryTicket', 'Remove-DirectoryTicket',
		'Test-DirectoryTool',
		# The self-test: everything above the seam, against LDIF captured from
		# a real Samba AD DC. Nothing below it — no socket is opened here.
		'Test-DirectoryModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('Directory', 'LDAP', 'ActiveDirectory', 'Kerberos', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: bound LDAP sessions over TLS, paged search, add/modify/delete/move, the unicodePwd path, and AD attribute decoding. Deliberately absent: SRV discovery of a domain controller, which is DNS and belongs to powershell/Net; the domain join, which is OS7 policy; and any Kerberos ticket handling, which needs krb5-user and a krb5.conf this image does not have.'
		}
	}
}
