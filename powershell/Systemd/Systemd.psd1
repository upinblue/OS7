# =============================================================================
# Systemd — units and the journal, as objects
#
# Layer 2 of docs/POWERSHELL-SURFACE-PLAN.md P2, cut like Zfs, Net and Time: it
# knows systemctl and journalctl, and nothing about OS/7.
#
# It is the module that makes the case for the product. `journalctl | grep` is
# a text pipeline over a log that is already structured; `Get-SystemdJournal
# -Priority Error | Group-Object Unit` is a question about objects. That only
# holds if the objects are really typed, and journalctl's JSON is not typed at
# all — every value in it is a string, including a timestamp in microseconds.
#
# ModuleVersion is stamped by build.sh from build/config/os7-release.conf. The
# 0.0.0 here is the "nobody stamped this" value, deliberately implausible.
# =============================================================================
@{
	RootModule        = 'Systemd.psm1'
	ModuleVersion     = '0.0.0'
	GUID              = 'f2a86c31-47d9-4e05-b6c8-91e3d40a7b52'
	Author            = 'up in blue GmbH'
	CompanyName       = 'up in blue GmbH'
	Copyright         = '(c) 2026 up in blue GmbH. MIT licensed.'
	Description       = 'systemd units and the journal for PowerShell: typed objects over systemctl and journalctl, with the timestamps, priorities and process ids that journalctl emits as strings turned into the types they are.'

	PowerShellVersion = '7.0'

	FunctionsToExport = @(
		# Units. Four fields about state and not one: `is-active` says `active`
		# for a unit in a restart loop, and SubState, Result and RestartCount
		# are what tell a healthy service from one failing every ten seconds.
		# The detail fields are $null until -Detailed, never 0 and never $false.
		'Get-SystemdUnit',
		# Writing. Each re-reads the unit afterwards, because `systemctl start`
		# returns 0 when the JOB was accepted — a service that then dies leaves
		# a successful job and a failed unit.
		'Start-SystemdUnit', 'Stop-SystemdUnit', 'Restart-SystemdUnit',
		'Set-SystemdUnitStartup',
		# systemctl reload - the SERVICE re-reads its own configuration. NOT
		# daemon-reload, which makes systemd re-read unit files; confusing them
		# applies a change to systemd and not to the program it configures.
		'Update-SystemdUnit',
		# The journal, typed. Timestamp is a [datetime] decoded from
		# MICROSECONDS, Priority is a number and a name, and Unit comes from
		# `_SYSTEMD_UNIT` — the field journald adds and a sender cannot forge —
		# never from `UNIT`, which the sender supplies.
		'Get-SystemdJournal',
		# The self-test: recorded real systemctl and journalctl output,
		# including a MESSAGE that is a byte array rather than a string.
		'Test-SystemdModule'
	)
	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()

	PrivateData = @{
		PSData = @{
			Tags         = @('systemd', 'systemctl', 'journalctl', 'Linux', 'OS7')
			LicenseUri   = 'https://github.com/upinblue/os7/blob/main/LICENSE'
			ProjectUri   = 'https://github.com/upinblue/os7'
			ReleaseNotes = 'v0: units and the journal, read and write. Timers, sockets and unit-file authoring are not here.'
		}
	}
}
