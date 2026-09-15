#!/usr/bin/env pwsh
<#
.SYNOPSIS
	What os7-job@<id>.service runs. Internal.

.DESCRIPTION
	docs/AUTOMATION-PLAN.md AU3, AU4, AU5 and AU7.

	THIS FILE EXISTS SO THE UNIT DOES NOT HAVE TO QUOTE, which is the same
	reason os7-update-run.ps1 exists and says so at length: a job's command
	crossing systemd's `%i` substitution and then PowerShell's parsing is three
	layers of escaping for a value that arrives from outside. A -File invocation
	binds the ID as a PARAMETER instead, and everything else is read out of a
	JSON file that no shell has touched.

	IT DOES NOT TRUST ITS CALLER. `systemctl start os7-job@anything.service` is
	a command an administrator can type, and an instance name is attacker-shaped
	input the moment a product above is generating them. So the id is validated
	here as well as in Start-OS7Job.

	`\z`, NOT `$`. In .NET — and therefore in PowerShell — `$` matches at the
	end of the string AND immediately before a trailing newline, so `^[a-z0-9-]+$`
	accepts "reconcile-ab12`n". BUILD-NOTES #151 is that mistake found by a
	self-test on its first run, in the application that established this pattern.

	WHAT IT DOES NOT DO IS DECIDE ANYTHING. It reads the spec Start-OS7Job
	wrote, gets a ticket if one was asked for, runs the command, and writes the
	result record. Every judgement about whether the job SHOULD run was made
	before the unit was started — which is AU1's line, seen from the inside.
#>
[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidatePattern('^[a-z0-9][a-z0-9._-]{0,63}\z')]
	[string]$JobId
)

$ErrorActionPreference = 'Stop'

Import-Module OS7

$jobDir = "/var/lib/os7-automation/jobs/$JobId"
$specPath = Join-Path $jobDir 'job.json'
if (-not (Test-Path -LiteralPath $specPath)) {
	throw "no job spec at $specPath — this unit was started for an id that Start-OS7Job did not write."
}
$spec = Get-Content -Raw -LiteralPath $specPath | ConvertFrom-Json

# AU3: the input document arrives on STDIN, put there by the unit's
# StandardInput=file:. Read it whole and close it — a job that leaves stdin open
# is a job that can block on a terminal that is not there.
$inputJson = [Console]::In.ReadToEnd()
if (-not $inputJson.Trim()) { $inputJson = '{}' }

# AU7: a ticket in THIS job's cache. KRB5CCNAME is already in the environment,
# put there by the drop-in; the ticket is obtained here because obtaining it in
# Start-OS7Job would put it in the CALLER's cache, which is the sharing AU7
# exists to prevent.
$ticket = $null
if ($spec.keytab) {
	$ticket = New-OS7JobTicket -Keytab $spec.keytab -Principal $spec.principal `
		-CachePath ($env:KRB5CCNAME -replace '^FILE:', '')
}

$started = [datetime]::UtcNow
$exit = 0
$err = $null
$out = $null
try {
	# $OS7JobInput is what a job's script reads. A NAME rather than a
	# parameter, because a job may be a command, a script file or (later) a
	# runbook from a package, and all three want the same document.
	$OS7JobInput = $inputJson | ConvertFrom-Json

	if ($spec.scriptPath) {
		$out = & $spec.scriptPath
	}
	else {
		$sb = [scriptblock]::Create($spec.command)
		$out = & $sb
	}
}
catch {
	$exit = 1
	$err = $_.Exception.Message
}

# AU5: the RESULT half. The intent was written and fsynced by Start-OS7Job
# before this unit was started, so a machine that died in the middle of the try
# block above leaves an intent with no result — which is exactly the state a
# product above re-plans on rather than re-runs.
$record = @{
	name        = $spec.name
	ranBy       = 'os7-job-run'
	durationSec = [Math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 3)
	exitCode    = $exit
	error       = $err
	# The job's own output is NOT put in the journal record. It is unbounded,
	# it is the one thing most likely to carry a secret the job just read, and
	# the journald stream already has it for anybody watching.
	outputLines = @($out).Count
	ticket      = if ($ticket) { $ticket.Principal } else { $null }
	credentials = @(if ($env:CREDENTIALS_DIRECTORY -and (Test-Path $env:CREDENTIALS_DIRECTORY)) {
			(Get-ChildItem -LiteralPath $env:CREDENTIALS_DIRECTORY -ErrorAction SilentlyContinue).Name
		})
}
Write-OS7JobRecord -JobId $JobId -Phase 'Result' -Record $record -Confirm:$false | Out-Null

if ($out) { $out | Out-String | Write-Output }
if ($exit -ne 0) {
	Write-Error $err
	exit 1
}
