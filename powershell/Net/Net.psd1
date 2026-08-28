# =============================================================================
# Net — the network subsystem from PowerShell
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut the same way powershell/Zfs
# is cut by ZFS-POWERSHELL-PLAN Z1: this module knows netplan, iproute2,
# networkd, NetworkManager and resolved, and knows nothing about OS/7. The
# product knowledge — which renderer this machine takes, which endpoints have to
# be reachable, what an enrolled machine may not be renamed to — lives one layer
# up in powershell/OS7.
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf, the
# same way OS7.psd1 and Zfs.psd1 are. The 0.0.0 here is the "nobody stamped
# this" value, and it is deliberately implausible rather than plausible.
# =============================================================================
@{
	RootModule        = 'Net.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = 'b81c4d6a-5f27-4e93-9c10-3ad7e6f2b845'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'Network configuration for PowerShell on Ubuntu: netplan documents, links, addresses and resolver state, as typed objects.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# The netplan document generator. A PURE FUNCTION — no file, no
		# interface, no running system — which is what lets
		# installer/testing/check-netplan-rule.py check it against the C#
		# renderer without a VM. That check owns the cases; this module does
		# not restate them. docs/POWERSHELL-SURFACE-PLAN.md P3.
		'New-NetplanDocument',
		# Reading what the KERNEL has, which is a different question from what
		# the configuration says (P6) and is never merged with it. All three ask
		# `ip` or `rfkill` and none of them believes an exit code alone — P5,
		# and Get-NetRadio exists mainly to make that distinction sayable.
		'Get-NetLink', 'Get-NetRoute', 'Get-NetRadio',
		# Reading what is CONFIGURED. Asked of netplan rather than of a file,
		# because /etc/netplan is several documents merged key by key and the
		# one OS/7 writes is not the answer. Never returns a passphrase.
		'Get-NetplanConfiguration',
		# Writing, applying, and asking the KERNEL whether it worked. THREE
		# calls and not one, because `netplan apply` returns 0 for a
		# configuration that brings nothing up — so "apply" and "did it work"
		# must ask different subsystems, and the caller decides what a failure
		# means (P5).
		'Set-NetplanDocument', 'Remove-NetplanDocument', 'Invoke-NetplanApply',
		'Wait-NetLinkAddress',
		# Asking the RESOLVER, which is a THIRD question and is merged with
		# neither of the two above (P6). [System.Net.Dns] cannot query SRV and
		# `Resolve-DnsName` does not exist on Linux PowerShell, so this shells
		# out to `dig` — and says Known=$false when dig is not installed rather
		# than handing back an empty list that reads as "this domain has no
		# domain controllers". `_ldap._tcp.dc._msdcs.<domain>` is how every
		# Active Directory client finds one, and DNS is this module's subsystem.
		'Resolve-NetSrvRecord',
		# The self-test. Checks THIS MODULE's contract — escaping, refusals,
		# line endings, secret handling, and the readers against recorded real
		# `ip` output — and deliberately not the netplan specification, which
		# has one owner elsewhere.
		'Test-NetModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('Network', 'netplan', 'networkd', 'NetworkManager', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: the netplan document generator only. Link, address, wireless and resolver cmdlets follow; see docs/POWERSHELL-SURFACE-PLAN.md section 3.'
		}
	}
}
