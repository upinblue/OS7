# =============================================================================
# Time — the clock, the zone and the discipline
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like powershell/Zfs and
# powershell/Net: it knows chrony, /etc/localtime and /etc/adjtime, and knows
# nothing about OS/7.
#
# P2's own example said the time zone was too thin a subsystem to warrant a
# module. The zone is; what is behind it is not — this image runs chrony 4.8
# rather than systemd-timesyncd, with its own vocabulary, its own CSV format
# and a configuration mechanism that is not the file everybody assumes. The
# plan was corrected rather than the measurement.
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf. The
# 0.0.0 here is the "nobody stamped this" value, deliberately implausible.
# =============================================================================
@{
	RootModule        = 'Time.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = 'e4f7a219-63bd-4c58-9a1e-72d0c5b8fa36'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'Time for PowerShell on Ubuntu: chrony tracking and sources as typed objects, the time zone, and whether the hardware clock is kept in local time.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# chrony. `Get-ChronyTracking` is the one that matters: `timedatectl`
		# reports "System clock synchronized" out of a kernel flag and cannot
		# say against WHOM, by how much, or with what dispersion.
		'Get-ChronyTracking', 'Get-ChronySource',
		# Where NTP servers actually live — /etc/chrony/sources.d/*.sources,
		# NOT chrony.conf, which a package upgrade owns and which needs a
		# restart to take effect. Measured, and chrony's own README agrees.
		'Get-ChronySourceFile', 'Set-ChronySource',
		# Stepping the clock. Returns the exit code without believing it:
		# makestep returns 0 for "I have been asked", not for "the clock moved".
		'Sync-ChronyClock',
		# The zone and the hardware clock. Files, not daemons, so these answer
		# on a machine whose dbus is not running — which is exactly the machine
		# somebody is trying to repair.
		'Get-SystemTimeZone', 'Set-SystemTimeZone', 'Get-SystemClock',
		# The self-test: recorded real chrony output plus a zone tree it builds.
		'Test-TimeModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('Time', 'NTP', 'chrony', 'timezone', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: chrony read and source configuration, the zone, and the RTC-in-local-time question. Stepping the clock is not here; that is Set-OS7Time.'
		}
	}
}
