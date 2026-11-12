# =============================================================================
# Tailscale — the tailnet client, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Apt, Docker and
# Hardware: it knows the `tailscale` CLI and its JSON, and nothing about OS/7.
# Where the daemon's state lives, which source the package comes from and what
# needs an administrator's attention are decided one layer up, in
# powershell/OS7/OS7.Tailscale.ps1 (docs/VENDOR-APPS-PLAN.md VA10-VA15).
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf. The
# 0.0.0 here is the "nobody stamped this" value, deliberately implausible.
# =============================================================================
@{
	RootModule        = 'Tailscale.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = '70a727c2-f8a6-4009-98aa-22dd0fd667dd'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'Tailscale for PowerShell: the client''s status and preferences as objects, a login by auth-key FILE or by URL, disconnect and log out, and the preferences set and read back. Speaks the CLI''s JSON, never the LocalAPI socket, and never takes an auth key as a value.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# What the client is, what it is connected to, and how it is set.
		'Get-TailscaleVersion', 'Get-TailscaleStatus', 'Get-TailscalePreference',
		# Joining and leaving. The key arrives as a FILE (`--auth-key=file:`):
		# a key on a command line is readable through /proc by every account.
		'Connect-Tailscale', 'Disconnect-Tailscale',
		# `tailscale set`, read back. Tailscale SSH and the client's own updater
		# can be switched OFF here and not on (VENDOR-APPS-PLAN VA7, VA14).
		'Set-TailscalePreference',
		# The self-test: recorded real output, no tailscale, no root.
		'Test-TailscaleModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('tailscale', 'tailnet', 'wireguard', 'vpn', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: status, preferences, version, up (auth-key file or login URL), down, logout and set. No exit nodes, subnet routes, Funnel, Serve or Taildrop: those are not this layer''s yet.'
		}
	}
}
