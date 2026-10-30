# =============================================================================
# Docker — the container engine, from PowerShell, over its own API
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like powershell/Zfs and
# powershell/Hardware: it knows the Docker Engine API and nothing about OS/7.
# docs/CONTAINERS-PLAN.md CT4 is the decision it implements.
#
# SHIPPED IN THE os7-module .deb since 2026-10-29, because the OS7 module's
# container cmdlets import it. The ENGINE it talks to is not on any image yet
# (CONTAINERS-PLAN §6 step 5): until then every request says there is no
# Docker engine socket, which is true.
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf. The
# 0.0.0 here is the "nobody stamped this" value, deliberately implausible.
# =============================================================================
@{
	RootModule        = 'Docker.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = '3b9c6e41-8d27-4f0a-b5e3-1c7a92d4f608'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'Docker Engine for PowerShell on Linux: the Engine API over its Unix socket, with the version negotiated and every "nothing happened" reported as such.'

	# 7.6 because 7.6.5 — the pin — is where `Invoke-WebRequest -UnixSocket`
	# was measured (M-CT3). Older releases may have it; none was asked.
	PowerShellVersion = '7.6'

	FunctionsToExport = @(
		# What engine this is, which API was negotiated, and which storage it
		# actually chose — asked of /version and /info, not assumed.
		'Get-DockerEngine',
		# Containers. The lifecycle verbs read the container back after the
		# engine answers, and say AlreadyRunning / AlreadyStopped when the
		# engine said 304 — the distinction the CLI throws away (M-CT4).
		'Get-DockerContainer', 'Start-DockerContainer', 'Stop-DockerContainer',
		'Restart-DockerContainer', 'Remove-DockerContainer', 'Get-DockerContainerLog',
		# The rest of what the engine holds.
		'Get-DockerImage', 'Get-DockerVolume', 'Get-DockerNetwork', 'Get-DockerDiskUsage',
		# Creating, pulling, asking a registry, removing (2026-10-30). Each asks
		# the engine back; a pull is read for the error the engine sends AFTER
		# its 200.
		'New-DockerContainer', 'Receive-DockerImage', 'Get-DockerDistribution',
		'Remove-DockerImage', 'Remove-DockerVolume', 'Remove-DockerNetwork',
		# An image reference as repository, tag and digest — with the registry
		# port that a last-colon split gets wrong, and `latest` said out loud.
		'Split-DockerReference',
		# The engine on this host: whether this process can open the socket
		# (asked of the socket), who is in its group, daemon.json, and the
		# package — installed from the machine's own sources, enabled, and
		# waited for until /_ping answers.
		'Test-DockerSocketAccess', 'Get-DockerSocketMember', 'Add-DockerSocketMember', 'Remove-DockerSocketMember',
		'Get-DockerDaemonConfiguration', 'Set-DockerDaemonConfiguration',
		'Get-DockerPackage', 'Install-DockerEngine', 'Restart-DockerEngine',
		# The self-test: RECORDED engine responses, one set per engine version.
		'Test-DockerModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('Docker', 'Containers', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: engine, containers (read, create, start, stop, restart, remove, logs), images (list, inspect, pull, remove, registry digest), volumes and networks (list, remove) and disk usage. No exec, no build — CONTAINERS-PLAN CT12.'
		}
	}
}
