# =============================================================================
# OS/7 as an automation host — the primitives, and nothing above them
#
# docs/AUTOMATION-PLAN.md phase 1: AU2 (secrets), AU3 (the input channel),
# AU4 (the fence), AU5 (the job journal), AU6 (durable service state),
# AU7 (a ticket cache per job), AU8 (named locks), AU11 (notification).
#
# AU1 IS THE LINE AND IT IS DECIDABLE BY GREP: the operating system provides
# primitives, a product above provides policy. Not one function here contains
# the words *approval*, *target system*, *role*, *entitlement* or *connector*,
# and check-automation-logic.py holds that. What runs, and why, is not this
# machine's question — "a process ran as this identity, for this long, and
# exited 0" is.
#
# AU10 IS WHY THERE IS NO SECOND JOB RUNNER. The Software Update window had the
# same problem from the other end — an unprivileged caller that needs root work
# done — and solved it ON A MACHINE on 2026-09-14 (f9ca2b5, GUI-APPS-PLAN O-G6):
# a TEMPLATED systemd unit, started through Start-SystemdUnit, governed by
# polkit, with progress read out of the unit's journal. Start-OS7Job is that
# mechanism WIDENED, not a second one: same template shape, same starter, same
# polkit, same journal. What phase 1 adds is the credential, the input channel
# and the fence. Building a second starter beside a proven one is BUILD-NOTES
# #66 in its purest form, and this time one of the two routes has already run.
#
# -----------------------------------------------------------------------------
# WHAT WAS MEASURED BEFORE ANY OF THIS WAS WRITTEN
# -----------------------------------------------------------------------------
# On an installed 1.0.0.175 machine, 2026-09-14, amd64, under NON-ENFORCING
# firmware (the kernel says "secureboot: Secure boot disabled"), which is the
# control docs/AUTOMATION-PLAN.md M-AU1 asked for.
# docs/SESSION-AUTOMATION-PRIMITIVES.md has the transcripts.
#
#   M-AU1a  `systemd-creds encrypt --with-key=host+tpm2` binds to NO PCRs by
#           default. The man page says so — "binds the encryption key to no
#           PCRs at all (this is also the default if this option is not used)"
#           — and the machine agrees: PCR 7 was moved for real with
#           `tpm2_pcrextend`, the default blob still opened, and a blob sealed
#           with `--tpm2-pcrs=7` died with "TPM policy does not match current
#           system state" — BUILD-NOTES #69's own sentence. THE PLAN SAID THE
#           OPPOSITE and AUL2 was sized from it.
#
#   M-AU1b  BOTH host modes depend on /var/lib/systemd/credential.secret, and
#           `/var/lib` on an OS/7 machine is `rpool/ROOT/<be>/var/lib` — INSIDE
#           the boot environment. Moved aside, `host` and `host+tpm2` both fail
#           ("Failed to determine local credential key"); `tpm2` opens in the
#           same second. That is the whole argument for the default below, and
#           it is D10's rule catching a dependency nobody had looked for.
#
#   M-AU1c  `LoadCredentialEncrypted=` delivers to /run/credentials/<unit>: a
#           tmpfs, `ro,nosuid,nodev,noexec,nosymfollow,size=1024k,mode=700`, the
#           file `-r--------` root:root, and the directory GONE the moment the
#           unit stops. Every word of AU2's mechanism paragraph holds.
#
#   M-AU4   A transient systemd timer does NOT survive a reboot — expected, and
#           worth the reboot anyway for HOW it does not: `LoadState=not-found`,
#           nothing under /run/systemd/transient, and not one line in either
#           boot's journal saying it went. BUILD-NOTES #154.
#
# -----------------------------------------------------------------------------
# THE LAYERING (P2-automation, installer/testing/check-layering.py)
# -----------------------------------------------------------------------------
# Nothing in this file names systemctl, systemd-run, systemd-creds,
# systemd-analyze, journalctl, kinit, klist, zfs or zpool. The systemd work goes
# through powershell/Systemd, the Kerberos work through powershell/Directory and
# the ZFS work through powershell/Zfs — which is Z1, P2-systemd and
# P2-directory, and the reason this file could be written at all without
# learning what `systemd-creds` does to a securestring.
# =============================================================================

# -----------------------------------------------------------------------------
# Where everything lives. Script variables rather than literals, for the same
# reason $script:OS7AuthdBrokerDir is one: check-automation-logic.py points them
# at a scratch tree and drives the real decisions with no ZFS, no systemd and no
# root. A literal is a rule nothing can test.
# -----------------------------------------------------------------------------
$script:OS7AutomationPool = 'rpool'

# rpool/DATA/... and NEVER rpool/ROOT/... . AU6, and the reason is D10's: a
# secret or an audit record that rolls back with the release is a secret the
# other side has already rotated away from, and an audit record that un-says
# what the machine did. New-OS7ServiceDataset REFUSES to create anything under
# ROOT, and that refusal is a check.
$script:OS7ServiceDatasetParent = 'DATA/lib'

$script:OS7AutomationRoot = '/var/lib/os7-automation'

# /var/lib/os7 is the wrong place and it is the OBVIOUS one, so it is named
# here rather than left to be rediscovered: it is inside the boot environment
# deliberately, because C10's migration record has to keep rolling back with
# the release. This must not be a child of it.
$script:OS7AutomationForbiddenRoot = '/var/lib/os7'

# /run, so a lock does not survive a reboot. AU8 — a lock held by a process
# that no longer exists is a deadlock, and a reboot is the cheapest possible
# release. That is a decision and not an accident, which is why it is written
# down beside the path.
$script:OS7LockDirectory = '/run/os7/locks'

# The template unit, which SHIPS IN A PACKAGE (build/packages/os7-automation)
# and is not authored at run time. AU4's fence lives in it, where it can be
# read, rolled back with the release and checked by a grep; only the per-run
# parts are a drop-in.
$script:OS7JobUnitTemplate = 'os7-job@'

# Open question 4, answered here because the first line written decides it: the
# job journal's schema IS a contract, so every record carries its version. A
# product above that reads these records has to be able to tell a record it
# understands from one it does not, and a version field added later cannot
# describe the records written before it.
$script:OS7JobRecordSchema = 1

# The one piece of policy in this file that is a number: a job with no timeout
# of its own is killed after an hour. AU4 says restrictive by default and
# widened explicitly; unlimited is not a default, it is an absence.
$script:OS7JobDefaultTimeoutSec = 3600

function Get-OS7AutomationPath {
	<#
	.SYNOPSIS
		Internal. One of the machine contract's paths, derived from the root.

	.DESCRIPTION
		DERIVED, never written out a second time. AUTOMATION-PLAN §4 is the
		contract a product above may rely on, and a contract spelled in eight
		places is BUILD-NOTES #66's shape applied to strings — the netplan
		renderer is this repository paying for exactly that today.
	#>
	param(
		[Parameter(Mandatory)]
		[ValidateSet('Root', 'Secrets', 'Journal', 'Jobs', 'State', 'Sinks')]
		[string]$What
	)

	switch ($What) {
		'Root' { return $script:OS7AutomationRoot }
		'Secrets' { return (Join-Path $script:OS7AutomationRoot 'secrets') }
		'Journal' { return (Join-Path $script:OS7AutomationRoot 'journal') }
		'Jobs' { return (Join-Path $script:OS7AutomationRoot 'jobs') }
		'State' { return (Join-Path $script:OS7AutomationRoot 'state') }
		'Sinks' { return (Join-Path $script:OS7AutomationRoot 'notification-sinks.json') }
	}
}

function Test-OS7AutomationName {
	<#
	.SYNOPSIS
		Internal. Is this a name that may become a systemd instance, a
		filename and a credential name at once?

	.DESCRIPTION
		ALL THREE AT ONCE, which is stricter than any one of them. A job id is
		an instance of `os7-job@`, so systemd's escaping rules apply; it is
		also a directory under jobs/ and half of a unit name in a polkit rule.
		The intersection is short and there is no reason to be generous: a
		caller that wants a long human sentence puts it in Description.
	#>
	param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
	return ($Name -match '^[a-z0-9][a-z0-9._-]{0,63}$')
}

function Assert-OS7AutomationName {
	param(
		[Parameter(Mandatory)][AllowEmptyString()][string]$Name,
		[Parameter(Mandatory)][string]$What
	)
	if (-not (Test-OS7AutomationName -Name $Name)) {
		throw [System.ArgumentException]::new(
			"'$Name' is not a $What. It has to be a systemd instance name, a filename and a " +
			'credential name at the same time: lower-case letters, digits, dot, dash and ' +
			'underscore, starting with a letter or digit, at most 64 characters.')
	}
}

# =============================================================================
# AU6 — durable service state
#
# FIRST, because everything else here puts something somewhere. A secret store
# on a dataset that rolls back is a secret store that hands out a credential the
# other side rotated away from; an audit record on one is an audit record that
# un-says what the machine did.
# =============================================================================

function New-OS7ServiceDataset {
	<#
	.SYNOPSIS
		Creates a dataset for a service's durable state, OUTSIDE the boot
		environment, and asks ZFS back.

	.DESCRIPTION
		AU6. D10 gives the rule and `New-OS7Storage` gives the install-time
		layout; this is the verb a service uses at any other time — after an
		install, on a machine that has been running for a year, from a package's
		postinst.

		THREE THINGS IT DOES THAT `zfs create` DOES NOT.

		It REFUSES a dataset under ROOT. That is the whole point and it is a
		refusal rather than a default, because "outside the boot environment" is
		the one property of this dataset that cannot be added afterwards: a
		service that has been writing into the boot environment for six months
		has six months of state that a rollback will un-say, and moving it later
		is a migration rather than a `zfs rename`.

		It SETS `canmount` AND `mountpoint` EXPLICITLY. BUILD-NOTES #63: a clone
		carries neither of them, `canmount` does not inherit at all, and the
		failure is a dataset that exists, reports success, and is not mounted
		where anybody is writing.

		It ASKS ZFS BACK. Four commands that exited 0 are four exit codes; this
		re-reads name, mountpoint, canmount and mounted from the pool and
		refuses to report success on a disagreement. That is this repository's
		oldest rule and the reason the storage layer is where it is.

	.PARAMETER Name
		The service's name — `os7-automation`, `os7-someproduct`. It becomes
		both the last path component of the dataset and the directory under
		/var/lib.

	.PARAMETER MountPoint
		Where it mounts. Defaults to /var/lib/<Name>.

	.PARAMETER Pool
		Defaults to rpool.

	.PARAMETER Backup
		Add the dataset to this machine's backup policy. ON by default: a
		dataset created for durable state and left out of the snapshot policy
		is durable against a rollback and against nothing else.

	.EXAMPLE
		New-OS7ServiceDataset -Name os7-automation
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[string]$MountPoint,
		[string]$Pool = $script:OS7AutomationPool,
		[bool]$Backup = $true
	)

	Assert-OS7Elevated -Cmdlet 'New-OS7ServiceDataset' -Because (
		'creates a ZFS dataset and mounts it under /var/lib, both of which are the pool ' +
		"owner's and the mount namespace's")

	Assert-OS7AutomationName -Name $Name -What 'service dataset name'
	if (-not $MountPoint) { $MountPoint = "/var/lib/$Name" }

	if (-not $MountPoint.StartsWith('/')) {
		throw [System.ArgumentException]::new("'$MountPoint' is not an absolute path.")
	}
	# The obvious wrong answer, refused by name. /var/lib/os7 is inside the boot
	# environment on purpose (C10's migration record rolls back with the
	# release), so a service that put its state under it would be rolled back by
	# the very mechanism this dataset exists to escape.
	if ($MountPoint -eq $script:OS7AutomationForbiddenRoot -or
		$MountPoint.StartsWith("$($script:OS7AutomationForbiddenRoot)/")) {
		throw [System.ArgumentException]::new(
			"$MountPoint is under $($script:OS7AutomationForbiddenRoot), which is INSIDE the " +
			'boot environment — deliberately, because the update train keeps its migration ' +
			'record there and that record has to roll back with the release. Durable service ' +
			"state must not. Use /var/lib/$Name.")
	}

	$dataset = "$Pool/$($script:OS7ServiceDatasetParent)/$Name"
	# ROOT is refused here rather than trusted to the parent constant, because
	# -Pool is a parameter and a caller could spell one that ends in /ROOT.
	if ($dataset -match "(^|/)ROOT(/|$)") {
		throw [System.ArgumentException]::new(
			"$dataset is under ROOT, which IS the boot environment. AU6 exists to keep " +
			'durable state out of it.')
	}

	Import-OS7ZfsLayer

	$existing = @(Get-ZfsDataset -Name $dataset -Type Filesystem -ErrorAction SilentlyContinue)
	if ($existing.Count) {
		Write-OS7Step "$dataset already exists; checking rather than creating"
	}
	else {
		if (-not $PSCmdlet.ShouldProcess($dataset, "create, mounted at $MountPoint")) { return }
		New-ZfsDataset -Name $dataset -Parents -Property @{
			mountpoint = $MountPoint
			canmount   = 'on'
			# The same compression the rest of this pool uses. Named rather
			# than inherited for the #63 reason one line up: a property that
			# is inherited today is a property that is absent after a clone.
			compression = 'zstd'
		} -Confirm:$false | Out-Null
		Write-OS7Step "created $dataset"
	}

	# Set them again even on a dataset that already existed. An operator who
	# ran `zfs set canmount=off` is exactly the case this verb is asked about,
	# and "it already exists" is not "it is correct".
	Set-ZfsProperty -Name $dataset -Property @{
		mountpoint = $MountPoint
		canmount   = 'on'
	} -Confirm:$false | Out-Null

	# ASK ZFS BACK. Everything above this line is a claim.
	$after = Get-OS7ServiceDataset -Name $Name -Pool $Pool
	if (-not $after) {
		throw [System.InvalidOperationException]::new(
			"$dataset was created and ZFS does not list it.")
	}
	if ($after.MountPoint -ne $MountPoint) {
		throw [System.InvalidOperationException]::new(
			"$dataset was created with mountpoint=$MountPoint and ZFS reports " +
			"$($after.MountPoint).")
	}
	if ($after.CanMount -ne 'on') {
		throw [System.InvalidOperationException]::new(
			"$dataset reports canmount=$($after.CanMount) — BUILD-NOTES #63 is this exact " +
			'symptom.')
	}
	if (-not $after.Mounted) {
		# `zfs mount` is the Zfs module's, not this file's.
		Mount-ZfsDataset -Name $dataset -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
		$after = Get-OS7ServiceDataset -Name $Name -Pool $Pool
	}
	if (-not $after.Mounted) {
		throw [System.InvalidOperationException]::new(
			"$dataset exists with canmount=on and mountpoint=$MountPoint and is NOT mounted. " +
			'Something else is on that path.')
	}

	# THE CONTRACT'S DIRECTORIES, and this is here because a machine found it
	# missing on 2026-09-14 while every check in installer/testing/ was green.
	# The dataset was created, mounted and correct; the very next cmdlet said
	#
	#     no secret store at /var/lib/os7-automation/secrets.
	#     New-OS7ServiceDataset -Name os7-automation creates it.
	#
	# and it did not. That is BUILD-NOTES #148's family exactly — a message that
	# names a verb which does not do what the message says — and it is the shape
	# of defect only a machine finds, because a check that drove the cmdlets
	# against a scratch tree made the directories itself before it started.
	$after = New-OS7ServiceDatasetLayout -Name $Name -MountPoint $MountPoint -Result $after

	if ($Backup) {
		$after = Add-OS7ServiceDatasetToBackup -Dataset $dataset -Result $after
	}

	return $after
}

function New-OS7ServiceDatasetLayout {
	<#
	.SYNOPSIS
		Internal. The directories AUTOMATION-PLAN §4 names, with their modes.

	.DESCRIPTION
		ONLY FOR THE AUTOMATION SERVICE. §4 is the contract a product above may
		rely on and it is about `os7-automation`; a dataset created for some
		other service gets its mount and `state/`, and what goes in it is that
		service's own shape. Inventing `secrets/` and `journal/` for every
		service would be this file deciding something a product above decides,
		which is AU1's line.
	#>
	param(
		[Parameter(Mandatory)][string]$Name,
		[Parameter(Mandatory)][string]$MountPoint,
		[Parameter(Mandatory)]$Result
	)

	$made = [System.Collections.Generic.List[string]]::new()

	# 0700 throughout: root-owned and root-readable. The journal's FILES are
	# 0640 root:adm so that an auditor in group adm can read them — but the
	# DIRECTORY is not, because listing the job ids is itself information and
	# Get-OS7JobRecord is the way to read the contents.
	$dirs = @([pscustomobject]@{ Path = $MountPoint; Mode = '0700' })
	if ($MountPoint -eq $script:OS7AutomationRoot) {
		foreach ($d in 'secrets', 'journal', 'jobs', 'state') {
			$dirs = $dirs + [pscustomobject]@{ Path = (Join-Path $MountPoint $d); Mode = '0700' }
		}
	}
	else {
		$dirs = $dirs + [pscustomobject]@{ Path = (Join-Path $MountPoint 'state'); Mode = '0700' }
	}

	foreach ($d in $dirs) {
		if (-not [System.IO.Directory]::Exists($d.Path)) {
			[System.IO.Directory]::CreateDirectory($d.Path) | Out-Null
			$made.Add($d.Path)
		}
		[System.IO.File]::SetUnixFileMode($d.Path,
			[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
			[System.IO.UnixFileMode]::UserExecute)
	}

	# ASK THE FILESYSTEM BACK, for the reason every other read-back in this file
	# exists: CreateDirectory on a path that is not where the dataset mounted
	# succeeds and puts the directory inside the boot environment.
	$missing = @($dirs | Where-Object { -not [System.IO.Directory]::Exists($_.Path) })
	if ($missing.Count) {
		throw [System.InvalidOperationException]::new(
			'these directories were created and are not there: ' +
			(($missing | ForEach-Object Path) -join ', '))
	}

	$Result | Add-Member -NotePropertyName Directories `
		-NotePropertyValue @($dirs | ForEach-Object Path) -Force
	$Result | Add-Member -NotePropertyName Created -NotePropertyValue @($made) -Force
	return $Result
}

function Add-OS7ServiceDatasetToBackup {
	<#
	.SYNOPSIS
		Internal. Adds a dataset to the backup policy if it is not covered.

	.DESCRIPTION
		AU6's last clause. A FAILURE HERE IS A WARNING AND NOT AN EXCEPTION,
		and that is a judgement worth stating: the dataset is created, mounted
		and correct, and throwing now would leave a caller believing nothing
		happened when the hard half did. What it must never do is stay quiet —
		a dataset silently outside the snapshot policy is the green status page
		over an uncovered home directory that Get-OS7BackupCoverage exists to
		prevent.
	#>
	param(
		[Parameter(Mandatory)][string]$Dataset,
		[Parameter(Mandatory)]$Result
	)

	try {
		$policy = Get-OS7BackupPolicy
		$sources = @($policy.Sources | ForEach-Object { [string]$_.Dataset })
		if ($sources -contains $Dataset) {
			$Result | Add-Member -NotePropertyName BackupPolicy -NotePropertyValue 'already listed' -Force
			return $Result
		}
		Set-OS7BackupPolicy -Dataset ($sources + $Dataset) -Confirm:$false | Out-Null
		Write-OS7Step "added $Dataset to the backup policy"
		$Result | Add-Member -NotePropertyName BackupPolicy -NotePropertyValue 'added' -Force
	}
	catch {
		Write-Warning ("$Dataset was created but could NOT be added to the backup policy: " +
			"$($_.Exception.Message). It is outside the boot environment and is therefore safe " +
			'from a rollback; it is not in any snapshot schedule. ' +
			"Set-OS7BackupPolicy -Dataset (…+'$Dataset') is the fix.")
		$Result | Add-Member -NotePropertyName BackupPolicy -NotePropertyValue 'FAILED' -Force
	}
	return $Result
}

function Get-OS7ServiceDataset {
	<#
	.SYNOPSIS
		The service datasets on this machine, and whether each one is really
		outside the boot environment.

	.DESCRIPTION
		`InBootEnvironment` is computed and not assumed. The whole value of AU6
		is a property of where the dataset IS, and a report that took the
		parent path on trust would agree with itself on a machine where
		somebody had moved it.

	.PARAMETER Name
		One service. All of them if not given.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Position = 0)][string]$Name,
		[string]$Pool = $script:OS7AutomationPool
	)

	Import-OS7ZfsLayer

	$parent = "$Pool/$($script:OS7ServiceDatasetParent)"
	$want = if ($Name) { "$parent/$Name" } else { $null }

	$sets = @(Get-ZfsDataset -Name ($want ?? $parent) -Recurse -Type Filesystem -ErrorAction SilentlyContinue |
		Where-Object { [string]$_.Name -ne $parent })
	if ($Name) { $sets = @($sets | Where-Object { [string]$_.Name -eq $want }) }

	$out = foreach ($d in $sets) {
		$dn = [string]$d.Name
		$mp = Get-OS7ZfsPropertyValue -Name $dn -Property 'mountpoint'
		$cm = Get-OS7ZfsPropertyValue -Name $dn -Property 'canmount'
		$mo = Get-OS7ZfsPropertyValue -Name $dn -Property 'mounted'
		[pscustomobject]@{
			PSTypeName        = 'OS7.Automation.ServiceDataset'
			Name              = $dn.Substring($dn.LastIndexOf('/') + 1)
			Dataset           = $dn
			MountPoint        = $mp
			CanMount          = $cm
			Mounted           = ($mo -eq 'yes')
			# The claim, checked. `ROOT` anywhere in the path means the boot
			# environment, and that is the one thing this dataset must not be
			# inside.
			InBootEnvironment = [bool]($dn -match '(^|/)ROOT(/|$)')
		}
	}
	return @($out)
}

# =============================================================================
# AU5 — the job journal
#
# NEEDS AU6, and is written BEFORE the action rather than after it.
#
# TWO RECORDS, NOT ONE. A product above records INTENT — who asked, who
# approved, which object. This machine records WHAT IT DID: at 14:02 a process
# ran as svc-prov for 1.3 s and exited 0. The second is what makes the first
# checkable, and the rule it serves is this repository's oldest: a diagnostic
# must not depend on the subsystem it is diagnosing. An audit trail attesting to
# its own writes is exactly that dependency.
#
# IT IS NOT journald, AND THAT IS NOT A CONTRADICTION OF THE APPLICATION WORK.
# The Software Update window reads PROGRESS out of a unit's journal and that is
# right — journald is the correct place for "what is this run doing right now".
# It is the wrong place for "what did this machine change, eight months ago, in
# a way an auditor will read": journald rotates, and it lives inside the boot
# environment's /var/log policy. Progress and evidence are two questions and
# only one of them has a retention requirement.
# =============================================================================

function Write-OS7JobRecord {
	<#
	.SYNOPSIS
		Appends one record to the machine's job journal, and flushes it to the
		disk before returning.

	.DESCRIPTION
		JSON Lines, one file per day, 0640 root:adm, on the AU6 dataset.

		FLUSHED TO THE DISK, not to the operating system. `FileStream.Flush()`
		with no argument pushes bytes into the page cache and returns;
		`Flush($true)` is fsync. The difference is invisible until the machine
		loses power in the middle of the thing this record is about, which is
		precisely the case an append-only evidence journal is kept for. Without
		it, "written before the action" is a statement about a buffer.

	.PARAMETER JobId
		What the record is about.

	.PARAMETER Phase
		`Intent` before the action, `Result` after it, `Note` for anything
		else. A run killed mid-step therefore leaves an Intent with no Result —
		which is exactly the state a product above must be able to detect in
		order to re-plan rather than re-run.

	.PARAMETER Record
		The fields, as a dictionary. Merged under the fixed ones; it cannot
		overwrite them.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory)][string]$JobId,
		[Parameter(Mandatory)][ValidateSet('Intent', 'Result', 'Note')][string]$Phase,
		[System.Collections.IDictionary]$Record
	)

	Assert-OS7Elevated -Cmdlet 'Write-OS7JobRecord' -Because (
		'appends to the machine job journal under /var/lib/os7-automation, which is ' +
		'root-owned and readable by group adm')

	$dir = Get-OS7AutomationPath -What 'Journal'
	if (-not [System.IO.Directory]::Exists($dir)) {
		throw [System.IO.DirectoryNotFoundException]::new(
			"no job journal at $dir. New-OS7ServiceDataset -Name os7-automation creates it; " +
			'AU6 is deliberately a separate verb, because a journal that silently created its ' +
			'own storage would create it wherever the caller happened to be — which on a ' +
			'machine with no dataset is inside the boot environment.')
	}

	$now = [datetime]::UtcNow
	$line = [ordered]@{
		schema = $script:OS7JobRecordSchema
		time   = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
		job    = $JobId
		phase  = $Phase
		host   = [System.Net.Dns]::GetHostName()
	}
	if ($Record) {
		foreach ($k in $Record.Keys) {
			# The fixed fields win. A caller that could overwrite `time` or
			# `phase` could write a record that reads as something it is not,
			# and this file is the evidence half of the pair.
			if ($line.Contains([string]$k)) { continue }
			$line[[string]$k] = $Record[$k]
		}
	}

	$path = Join-Path $dir ($now.ToString('yyyy-MM-dd') + '.jsonl')
	$text = (ConvertTo-Json -InputObject $line -Depth 8 -Compress) + "`n"

	if (-not $PSCmdlet.ShouldProcess($path, "append a $Phase record for $JobId")) { return }

	$bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
	$fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::Append,
		[System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
	try {
		$fs.Write($bytes, 0, $bytes.Length)
		$fs.Flush($true)
	}
	finally { $fs.Dispose() }

	# 0640 root:adm. The mode is .NET's; the group needs chown, which is not on
	# any layering rule's token list and is the same route OS7.RemoteDesktop.ps1
	# already takes for a private key's ownership.
	[System.IO.File]::SetUnixFileMode($path,
		[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
		[System.IO.UnixFileMode]::GroupRead)
	Invoke-OS7Native -Command 'chown' -Arguments @('root:adm', $path) -ErrorAction SilentlyContinue | Out-Null

	return [pscustomobject]@{
		PSTypeName = 'OS7.Automation.JobRecord'
		Job        = $JobId
		Phase      = $Phase
		Time       = $now
		Path       = $path
	}
}

function Get-OS7JobRecord {
	<#
	.SYNOPSIS
		Reads the machine's job journal.

	.DESCRIPTION
		A record whose `phase` is Intent with no matching Result is a run that
		did not finish — reported as `Complete = $false` rather than left to
		the reader, because that state is the one a product above re-plans on.

	.PARAMETER JobId
		One job. All of them if not given.

	.PARAMETER Days
		How far back to read. Files are one per day, so this is a file count.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Position = 0)][string]$JobId,
		[int]$Days = 7
	)

	$dir = Get-OS7AutomationPath -What 'Journal'
	if (-not [System.IO.Directory]::Exists($dir)) { return @() }

	$cutoff = [datetime]::UtcNow.Date.AddDays(-([Math]::Max(0, $Days - 1)))
	$files = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
		Sort-Object Name)

	$records = [System.Collections.Generic.List[object]]::new()
	foreach ($f in $files) {
		$stamp = [datetime]::MinValue
		if (-not [datetime]::TryParseExact($f.BaseName, 'yyyy-MM-dd',
				[cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None,
				[ref]$stamp)) {
			continue
		}
		if ($stamp -lt $cutoff) { continue }

		foreach ($line in [System.IO.File]::ReadAllLines($f.FullName)) {
			if (-not $line.Trim()) { continue }
			# A CORRUPT LINE IS REPORTED, NOT SKIPPED. This is the evidence
			# half; a reader that quietly dropped what it could not parse
			# would make a truncated journal look like a short one.
			$o = $null
			try { $o = $line | ConvertFrom-Json }
			catch {
				$records.Add([pscustomobject]@{
						PSTypeName = 'OS7.Automation.JobRecord'
						Job        = $null
						Phase      = 'UNREADABLE'
						Time       = $stamp
						Schema     = $null
						Path       = $f.FullName
						Raw        = $line
					})
				continue
			}
			$records.Add([pscustomobject]@{
					PSTypeName = 'OS7.Automation.JobRecord'
					Job        = $o.job
					Phase      = $o.phase
					Time       = [datetime]::Parse($o.time, [cultureinfo]::InvariantCulture,
						[System.Globalization.DateTimeStyles]::AdjustToUniversal)
					Schema     = $o.schema
					Path       = $f.FullName
					Record     = $o
				})
		}
	}

	$all = @($records)
	if ($JobId) { $all = @($all | Where-Object { $_.Job -eq $JobId }) }

	# Complete: does this job have a Result anywhere in what was read?
	$withResult = @{}
	foreach ($r in $records) { if ($r.Phase -eq 'Result' -and $r.Job) { $withResult[[string]$r.Job] = $true } }
	foreach ($r in $all) {
		$r | Add-Member -NotePropertyName Complete `
			-NotePropertyValue ([bool]($r.Job -and $withResult.ContainsKey([string]$r.Job))) -Force
	}
	return $all
}

# =============================================================================
# AU2 — the secret store
#
# `New-OS7Secret` seals; `Get-OS7Secret` returns METADATA ONLY, because a value
# that can be returned can reach ConvertTo-Json and P7 forbids that;
# `Unprotect-OS7Secret` is the deliberate exception and its use is a smell
# rather than a pattern. DELIVERY TO A JOB IS BY UNIT DIRECTIVE AND NOT BY
# CMDLET — Start-OS7Job arranges LoadCredentialEncrypted= and the job reads
# $env:CREDENTIALS_DIRECTORY.
#
# AUL8 IS STILL TRUE AND IS NOT SOFTENED HERE. Enter-OS7AdminSession uses a
# credential and FORGETS it, because a session that could re-authenticate is a
# password at rest. Unattended automation cannot forget, so this knowingly
# breaks a stated OS/7 rule. What it does not do is pretend otherwise.
# =============================================================================

function Get-OS7SecretPath {
	param([Parameter(Mandatory)][string]$Name)
	return (Join-Path (Get-OS7AutomationPath -What 'Secrets') "$Name.cred")
}

function Get-OS7SecretMetaPath {
	param([Parameter(Mandatory)][string]$Name)
	return (Join-Path (Get-OS7AutomationPath -What 'Secrets') "$Name.json")
}

function New-OS7Secret {
	<#
	.SYNOPSIS
		Seals a secret so that systemd can hand it to a job, and never returns
		it.

	.DESCRIPTION
		The plaintext goes to `systemd-creds` on STDIN and is never an
		argument, so it is never in `ps`, never in /proc/<pid>/cmdline and
		never in systemd's own tooling — measured, and the same rule
		Register-OS7ScheduledTask states in capitals.

		SEALED TO THE TPM ALONE BY DEFAULT, and that is a measurement rather
		than a preference. systemd's `host` key is a file at
		/var/lib/systemd/credential.secret; `/var/lib` on an OS/7 machine is
		`rpool/ROOT/<be>/var/lib`, which is INSIDE the boot environment. A
		secret sealed with `host` or `host+tpm2` and stored on the AU6 dataset
		would survive a rollback and its KEY would not — the dataset's whole
		purpose, defeated by a dependency in the other direction. Moved aside,
		both host modes fail and `tpm2` opens (2026-09-14).

		NO PCRs, also measured and also a correction: AUTOMATION-PLAN AU2 said
		`host+tpm2` "inherits #69/#100", and it does not, because
		`--tpm2-pcrs=` defaults to EMPTY. A blob sealed the default way survived
		PCR 7 being extended for real; one sealed with `-Pcrs 7` died with
		"TPM policy does not match current system state". -Pcrs exists so that
		a caller who wants that property can ask for it by name, and its help
		says what it costs.

		A MACHINE WITH NO TPM CANNOT USE THE DEFAULT, and is told so rather
		than silently downgraded. -SealTo host is the answer there, and the
		metadata records which mode was used, so an operator reading
		Get-OS7Secret can see which of their machines took which road.

	.PARAMETER Name
		The credential name. It is part of the encryption — a blob sealed under
		one name does not open under another — and it is what the job's
		`$CREDENTIALS_DIRECTORY/<name>` will be called.

	.PARAMETER Value
		A [securestring]. -Credential takes a [pscredential] instead and seals
		its password.

	.PARAMETER SealTo
		`tpm2` (default), `host` or `host+tpm2`. See the description.

	.PARAMETER Pcrs
		Bind to these PCRs. EMPTY BY DEFAULT. Binding to 7 means a shim or a
		`dbx` update makes this secret unopenable, and OS/7 has no escrow
		(DECISIONS open question 7) — so a machine that takes an update stops
		being able to do its automation, silently, which is what AUL2 is about.

	.PARAMETER Force
		Replace an existing secret of this name.

	.EXAMPLE
		New-OS7Secret -Name svc-provisioning -Value (Read-Host -AsSecureString)
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Value')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[Parameter(Mandatory, ParameterSetName = 'Value')][securestring]$Value,
		[Parameter(Mandatory, ParameterSetName = 'Credential')][pscredential]$Credential,
		[ValidateSet('tpm2', 'host', 'host+tpm2')][string]$SealTo = 'tpm2',
		[int[]]$Pcrs = @(),
		[switch]$Force
	)

	Assert-OS7Elevated -Cmdlet 'New-OS7Secret' -Because (
		'writes a sealed credential under /var/lib/os7-automation/secrets, which is ' +
		'root-owned, and seals it against this machine')

	Assert-OS7AutomationName -Name $Name -What 'secret name'
	Import-OS7SystemdLayer

	$dir = Get-OS7AutomationPath -What 'Secrets'
	if (-not [System.IO.Directory]::Exists($dir)) {
		throw [System.IO.DirectoryNotFoundException]::new(
			"no secret store at $dir. New-OS7ServiceDataset -Name os7-automation creates it.")
	}

	if ($SealTo -ne 'host') {
		$tpm = Test-SystemdTpm2
		if ($null -eq $tpm) {
			throw [System.InvalidOperationException]::new(
				'this machine could not be asked whether it has a TPM2 (systemd-analyze did ' +
				'not run), so sealing to one cannot be attempted. -SealTo host seals to a key ' +
				'file instead — read its help first: that file is inside the boot environment.')
		}
		if (-not $tpm) {
			throw [System.InvalidOperationException]::new(
				"this machine has no usable TPM2, so -SealTo $SealTo cannot work. " +
				'-SealTo host seals to /var/lib/systemd/credential.secret instead, which is ' +
				'INSIDE the boot environment: a rollback past the day this secret was created ' +
				'takes the key with it and the secret stops opening. That is a real trade and ' +
				'it has to be made on purpose.')
		}
	}

	$secret = if ($PSCmdlet.ParameterSetName -eq 'Credential') { $Credential.Password } else { $Value }
	$path = Get-OS7SecretPath -Name $Name
	$meta = Get-OS7SecretMetaPath -Name $Name

	if ([System.IO.File]::Exists($path) -and -not $Force) {
		throw [System.InvalidOperationException]::new(
			"a secret called '$Name' already exists. -Force replaces it.")
	}
	if (-not $PSCmdlet.ShouldProcess($Name, "seal a secret to $SealTo")) { return }

	# The Systemd layer does the sealing AND the read-back: `encrypt` exiting 0
	# says the program ran, not that the blob opens.
	$sealed = New-SystemdCredential -Name $Name -Value $secret -Path $path `
		-With $SealTo -Pcrs $Pcrs -Force:$Force -Confirm:$false

	[System.IO.File]::SetUnixFileMode($path,
		[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)

	$record = [ordered]@{
		schema   = $script:OS7JobRecordSchema
		name     = $Name
		created  = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
		sealedTo = $SealTo
		pcrs     = @($Pcrs)
		size     = $sealed.Size
		# NOT the value, and not a hash of it either: a hash of a secret is a
		# password-cracking target sitting beside the thing it describes.
		lastDelivered = $null
	}
	[System.IO.File]::WriteAllText($meta, (ConvertTo-Json -InputObject $record -Depth 5))
	[System.IO.File]::SetUnixFileMode($meta,
		[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)

	return (Get-OS7Secret -Name $Name)
}

function Get-OS7Secret {
	<#
	.SYNOPSIS
		The secrets on this machine — METADATA ONLY. It cannot return a value.

	.DESCRIPTION
		AU2, and the shape is the decision: this object has no field that could
		hold a secret, so it cannot leak one through `ConvertTo-Json`, a
		transcript, a `Format-List` in a support ticket or a pipeline somebody
		forgot to end. A cmdlet that returns a value SOMETIMES is a cmdlet whose
		output is unsafe to log ALWAYS.

		`Openable` is the field worth having and it costs a TPM operation: it
		asks whether the blob still decrypts. A secret store whose contents
		have quietly become unopenable — AUL2 — reports itself here instead of
		at 03:00 in a job that was supposed to run.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Position = 0)][string]$Name,
		# Off by default: it is a TPM operation per secret, and `Get-` should
		# be cheap enough to type without thinking.
		[switch]$TestOpen
	)

	$dir = Get-OS7AutomationPath -What 'Secrets'
	if (-not [System.IO.Directory]::Exists($dir)) { return @() }

	$files = @(Get-ChildItem -LiteralPath $dir -Filter '*.cred' -ErrorAction SilentlyContinue)
	if ($Name) { $files = @($files | Where-Object { $_.BaseName -eq $Name }) }

	$out = foreach ($f in ($files | Sort-Object Name)) {
		$meta = $null
		$metaPath = Get-OS7SecretMetaPath -Name $f.BaseName
		if ([System.IO.File]::Exists($metaPath)) {
			try { $meta = [System.IO.File]::ReadAllText($metaPath) | ConvertFrom-Json } catch { $meta = $null }
		}

		$openable = $null
		if ($TestOpen) {
			Import-OS7SystemdLayer
			try {
				Unprotect-SystemdCredential -Name $f.BaseName -Path $f.FullName | Out-Null
				$openable = $true
			}
			catch { $openable = $false }
		}

		[pscustomobject]@{
			PSTypeName    = 'OS7.Automation.Secret'
			Name          = $f.BaseName
			Path          = $f.FullName
			SealedTo      = if ($meta) { $meta.sealedTo } else { $null }
			Pcrs          = if ($meta -and $meta.PSObject.Properties['pcrs']) { @($meta.pcrs) } else { @() }
			Created       = if ($meta) { $meta.created } else { $null }
			LastDelivered = if ($meta -and $meta.PSObject.Properties['lastDelivered']) { $meta.lastDelivered } else { $null }
			Size          = $f.Length
			Openable      = $openable
		}
	}
	return @($out)
}

function Remove-OS7Secret {
	<#
	.SYNOPSIS
		Deletes a sealed secret and its metadata.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param([Parameter(Mandatory, Position = 0)][string]$Name)

	Assert-OS7Elevated -Cmdlet 'Remove-OS7Secret' -Because (
		'deletes a file under /var/lib/os7-automation/secrets, which is root-owned')

	Assert-OS7AutomationName -Name $Name -What 'secret name'
	$path = Get-OS7SecretPath -Name $Name
	if (-not [System.IO.File]::Exists($path)) {
		throw [System.IO.FileNotFoundException]::new("no secret called '$Name'.")
	}
	if (-not $PSCmdlet.ShouldProcess($Name, 'delete the sealed secret')) { return }

	[System.IO.File]::Delete($path)
	$meta = Get-OS7SecretMetaPath -Name $Name
	if ([System.IO.File]::Exists($meta)) { [System.IO.File]::Delete($meta) }
	return (-not [System.IO.File]::Exists($path))
}

function Unprotect-OS7Secret {
	<#
	.SYNOPSIS
		Opens a sealed secret and returns a [securestring]. THE DELIBERATE
		EXCEPTION.

	.DESCRIPTION
		AU2: this exists for the cases the unit mechanism cannot reach, and its
		use is a smell rather than a pattern. A job does NOT call this — it
		reads `$env:CREDENTIALS_DIRECTORY/<name>`, which systemd fills from a
		tmpfs that is unmounted when the unit stops.

		It returns a [securestring] and not a string, so the value cannot reach
		ConvertTo-Json or a transcript by accident (P7).

		EVERY CALL IS RECORDED. Opening a secret outside the unit mechanism is
		the event an auditor most wants to see, and this is the only place it
		can be seen from.
	#>
	[CmdletBinding()]
	param([Parameter(Mandatory, Position = 0)][string]$Name)

	Assert-OS7Elevated -Cmdlet 'Unprotect-OS7Secret' -Because (
		'reads a root-owned sealed credential and asks the TPM to unseal it')

	Assert-OS7AutomationName -Name $Name -What 'secret name'
	Import-OS7SystemdLayer

	$path = Get-OS7SecretPath -Name $Name
	if (-not [System.IO.File]::Exists($path)) {
		throw [System.IO.FileNotFoundException]::new("no secret called '$Name'.")
	}

	$value = Unprotect-SystemdCredential -Name $Name -Path $path

	try {
		Write-OS7JobRecord -JobId "secret:$Name" -Phase 'Note' -Confirm:$false -Record @{
			action = 'unprotect'
			secret = $Name
			by     = ($env:SUDO_USER ?? $env:USER ?? 'unknown')
		} | Out-Null
	}
	catch {
		Write-Warning ("the secret was opened and the journal entry could NOT be written: " +
			"$($_.Exception.Message)")
	}
	return $value
}

# =============================================================================
# AU4 / AU3 / AU7 / AU10 — the job contract
#
# The fence is in the PACKAGED template unit (build/packages/os7-automation),
# where it can be read, rolled back with the release and checked by a grep. Only
# the per-run parts — the timeout, the limits, the credential, the identity, the
# ticket cache — are a drop-in under /run, which has a run's lifetime.
# =============================================================================

function New-OS7JobId {
	param([Parameter(Mandatory)][string]$Name)
	$suffix = -join ((1..8) | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
	return "$Name-$suffix"
}

function Start-OS7Job {
	<#
	.SYNOPSIS
		Runs a job under the OS/7 job contract: a slice, limits, a timeout,
		isolation, an input document on stdin, a sealed secret and a private
		Kerberos cache — and a journal record written BEFORE it starts.

	.DESCRIPTION
		AU10, AND IT IS THE SAME MECHANISM THE SOFTWARE UPDATE WINDOW ALREADY
		PROVED ON A MACHINE, not a second one. `os7-job@<id>.service` is a
		templated unit started through `Start-SystemdUnit`, governed by polkit,
		with progress in the unit's journal — which is what `os7-update@<version>`
		is, pointed at a different kind of work. No D-Bus library, no local
		service, no new IPC.

		WHAT ARRIVES HOW, and each one is a decision:

		  input     ONE JSON DOCUMENT ON STDIN (AU3). Not the environment:
		            /proc/<pid>/environ is readable by the same user and by
		            root, and a job's input routinely carries an identity, a
		            department and a manager's address. Not the command line: it
		            is world-readable in `ps`. systemd's own
		            `StandardInput=file:` in the template does the delivery, so
		            the document never passes through a shell.

		  secrets   `LoadCredentialEncrypted=` (AU2). The job reads
		            $env:CREDENTIALS_DIRECTORY/<name>, a tmpfs at 0400 that is
		            unmounted when the unit stops. Measured, not assumed.

		  identity  ROOT unless -Identity or -DynamicUser says otherwise, and
		            the record says which. This answers AUTOMATION-PLAN open
		            question 3 and the answer is uncomfortable enough to state
		            plainly: a job that must write its own state, hold a keytab
		            and append to the machine journal cannot be a DynamicUser
		            (AUL4 — a dynamic user's state directory is owned by an id
		            that changes), and a job run as the CALLER would make the
		            fence depend on who typed the command. So the default is
		            root INSIDE the fence, the fence is the packaged template,
		            and every run records which identity it had so an auditor
		            can see it without reading a unit file.

		  ticket    -Keytab gets a ticket in a cache PRIVATE to this job (AU7),
		            never the machine's default cache: two jobs sharing one
		            cache are two jobs sharing one identity and racing over its
		            lifetime.

		THE INTENT RECORD IS WRITTEN AND FSYNCED BEFORE THE UNIT IS STARTED.
		A run killed mid-step therefore leaves an intent with no result, which
		is the state a product above re-plans on rather than re-runs.

	.PARAMETER Name
		What this job is. It becomes part of the unit instance name.

	.PARAMETER Command
		A PowerShell command, or -ScriptPath for a file. The template runs it
		through /usr/libexec/os7-job-run.ps1, which binds it as a PARAMETER —
		the reason os7-update-run.ps1 exists, and the same three layers of
		quoting avoided.

	.PARAMETER InputObject
		Serialised to JSON and delivered on the job's stdin.

	.PARAMETER Secret
		Names of secrets from New-OS7Secret to deliver.

	.PARAMETER Unconfined
		Give up the fence. It names what it gives up here, and it APPEARS IN
		THE JOB RECORD, so an auditor can see which jobs ran without one.

	.PARAMETER NoWait
		Return when systemd has accepted the job rather than when it has
		finished.

	.EXAMPLE
		Start-OS7Job -Name reconcile -Command 'Get-Date' -InputObject @{ scope = 'all' }
	#>
	[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Command')]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[Parameter(Mandatory, ParameterSetName = 'Command')][string]$Command,
		[Parameter(Mandatory, ParameterSetName = 'Script')][string]$ScriptPath,
		$InputObject,
		[string[]]$Secret = @(),
		[string]$Identity,
		[switch]$DynamicUser,
		[string]$Keytab,
		[string]$Principal,
		[int]$TimeoutSec = $script:OS7JobDefaultTimeoutSec,
		[string]$MemoryMax,
		[string]$CpuQuota,
		[int]$TasksMax,
		[switch]$Unconfined,
		[switch]$NoWait
	)

	Assert-OS7Elevated -Cmdlet 'Start-OS7Job' -Because (
		'writes a job under /var/lib/os7-automation and asks systemd to start a system unit')

	Assert-OS7AutomationName -Name $Name -What 'job name'
	if ($Identity -and $DynamicUser) {
		throw [System.ArgumentException]::new(
			'-Identity and -DynamicUser are two answers to one question. A dynamic user has no ' +
			'name to give.')
	}
	if ($Keytab -and -not $Principal) {
		throw [System.ArgumentException]::new(
			'-Keytab needs -Principal: a keytab can hold several, and kinit picks by name.')
	}
	if ($DynamicUser) {
		# AUL4, MEASURED ON A MACHINE 2026-09-15 RATHER THAN PREDICTED, and the
		# reason this is a refusal instead of a feature: the switch produced a
		# job that could not run, and a parameter that does that is worse than
		# no parameter (#148's family).
		#
		# Three walls, in the order a job hits them, each one the fence and the
		# journal doing exactly what they are for:
		#
		#   1. its own SPEC — 0600 root:root, and a dynamic uid did not exist
		#      when it was written. That one is FIXED anyway: the spec now
		#      arrives by `LoadCredential=`, which PID 1 reads as root and puts
		#      in a tmpfs owned by the unit's user. (`StandardInput=file:` never
		#      had the problem — systemd opens it as root and passes a
		#      descriptor, which is why AU3's channel needed no change.)
		#
		#   2. /var/lib/os7-automation/state — 0700 root. `Access to the path
		#      ... is denied` out of New-Item, before the job's own work starts.
		#
		#   3. Write-OS7JobRecord — "must run as root: it appends to the machine
		#      job journal ... This process is uid 62375". So the run would leave
		#      an intent with NO result, which AU5 reserves for a machine that
		#      died. A job indistinguishable from a crash is not one anybody can
		#      audit.
		#
		# Making it work is a design decision and not a patch: it needs
		# `StateDirectory=` for (2) and a different answer to (3) — the starter
		# writing the Result by watching the unit, or a privileged helper — and
		# that changes AU5's two-writer contract. AUTOMATION-PLAN AUL4 records
		# it. Open question 3 already answered "root, inside the fence, recorded
		# per run"; this is what the alternative costs.
		throw [System.NotImplementedException]::new(
			'-DynamicUser is not usable yet, and this refuses rather than producing a job ' +
			'that cannot run. Measured 2026-09-15: a dynamic user cannot write the AU6 ' +
			'state directory (0700 root) and cannot append to the machine job journal ' +
			'(Write-OS7JobRecord needs root), so the run would leave an intent with no ' +
			"result — which AU5 reserves for a machine that died.`n" +
			"`n" +
			'  -Identity <account> is the way to run a job as a non-root named identity, ' +
			'and it WORKS — the record is written by Start-OS7Job when the job cannot write ' +
			'it itself. What -Identity does not give you is a per-run identity, which is ' +
			"the only thing -DynamicUser was for.`n" +
			"`n" +
			'  docs/AUTOMATION-PLAN.md AUL4 says what building this properly costs.')
	}
	foreach ($s in $Secret) { Assert-OS7AutomationName -Name $s -What 'secret name' }

	Import-OS7SystemdLayer

	$jobsDir = Get-OS7AutomationPath -What 'Jobs'
	if (-not [System.IO.Directory]::Exists($jobsDir)) {
		throw [System.IO.DirectoryNotFoundException]::new(
			"no job directory at $jobsDir. New-OS7ServiceDataset -Name os7-automation creates it.")
	}

	$id = New-OS7JobId -Name $Name
	$unit = "$($script:OS7JobUnitTemplate)$id.service"
	$dir = Join-Path $jobsDir $id

	$missing = @($Secret | Where-Object { -not [System.IO.File]::Exists((Get-OS7SecretPath -Name $_)) })
	if ($missing.Count) {
		# BEFORE anything is written. A job that starts and then fails to find
		# its credential has already appeared in the journal as an intent.
		throw [System.InvalidOperationException]::new(
			"no such secret: $($missing -join ', '). Get-OS7Secret lists what is sealed.")
	}

	if (-not $PSCmdlet.ShouldProcess($unit, "start job '$Name'")) { return }

	[System.IO.Directory]::CreateDirectory($dir) | Out-Null
	[System.IO.File]::SetUnixFileMode($dir,
		[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
		[System.IO.UnixFileMode]::UserExecute)

	# AU3: one JSON document, on stdin, closed. `{}` and not an empty file when
	# there is no input, because "the job parses it or fails" has to be true of
	# every run — a job that has to handle both a document and nothing is a job
	# with two input formats.
	$inputPath = Join-Path $dir 'input.json'
	$doc = if ($null -ne $InputObject) { ConvertTo-Json -InputObject $InputObject -Depth 16 } else { '{}' }
	[System.IO.File]::WriteAllText($inputPath, $doc)
	[System.IO.File]::SetUnixFileMode($inputPath,
		[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)

	$spec = [ordered]@{
		schema     = $script:OS7JobRecordSchema
		id         = $id
		name       = $Name
		command    = if ($PSCmdlet.ParameterSetName -eq 'Script') { $null } else { $Command }
		scriptPath = if ($PSCmdlet.ParameterSetName -eq 'Script') { $ScriptPath } else { $null }
		keytab     = $Keytab
		principal  = $Principal
	}
	$specPath = Join-Path $dir 'job.json'
	[System.IO.File]::WriteAllText($specPath, (ConvertTo-Json -InputObject $spec -Depth 6))
	[System.IO.File]::SetUnixFileMode($specPath,
		[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)

	$dropIn = New-OS7JobDropInText -Id $id -Name $Name -Secret $Secret -Identity $Identity `
		-DynamicUser:$DynamicUser -Keytab $Keytab -TimeoutSec $TimeoutSec `
		-MemoryMax $MemoryMax -CpuQuota $CpuQuota -TasksMax $TasksMax -Unconfined:$Unconfined

	$intent = [ordered]@{
		name       = $Name
		unit       = $unit
		identity   = if ($DynamicUser) { '(dynamic)' } elseif ($Identity) { $Identity } else { 'root' }
		unconfined = [bool]$Unconfined
		timeoutSec = $TimeoutSec
		secrets    = @($Secret)
		keytab     = $Keytab
		principal  = $Principal
		startedBy  = ($env:SUDO_USER ?? $env:USER ?? 'unknown')
		inputBytes = $doc.Length
	}

	# WRITTEN AND FSYNCED BEFORE THE ACTION. If the machine dies between this
	# line and the next, the journal holds an intent with no result — which is
	# the point, and is what M-AU2 proves by killing rather than by reading.
	Write-OS7JobRecord -JobId $id -Phase 'Intent' -Record $intent -Confirm:$false | Out-Null

	New-SystemdUnitDropIn -Unit $unit -Name '50-os7-job' -Content $dropIn -Confirm:$false | Out-Null

	$started = [datetime]::UtcNow
	$result = $null
	$failure = $null
	try {
		$u = @(Start-SystemdUnit -Name $unit -NoBlock:$NoWait -Confirm:$false)
		$result = $u | Select-Object -First 1
	}
	catch { $failure = $_.Exception.Message }

	$record = [ordered]@{
		name        = $Name
		unit        = $unit
		durationSec = [Math]::Round(([datetime]::UtcNow - $started).TotalSeconds, 3)
		# A FINISHED ONESHOT MAY ALREADY BE GONE. systemd garbage-collects a
		# unit with no [Install], no RemainAfterExit and nothing referring to
		# it, so `Get-SystemdUnit` right after a synchronous start routinely
		# answers nothing at all — measured on a machine 2026-09-14, where
		# every field here came back null on a job that had plainly run. That
		# is not a failure and must not read as one, so it is SAID:
		unitGone    = ($null -eq $result)
		activeState = if ($result -and $result.PSObject.Properties['ActiveState']) { $result.ActiveState } else { $null }
		subState    = if ($result -and $result.PSObject.Properties['SubState']) { $result.SubState } else { $null }
		result      = if ($result -and $result.PSObject.Properties['Result']) { $result.Result } else { $null }
		error       = $failure
		waited      = (-not $NoWait)
	}

	# WHO WRITES THE RESULT, and it is exactly one of the two. The RUNNER does
	# — /usr/libexec/os7-job-run.ps1, inside the unit, which is the only party
	# that knows the command's exit code and how long the work took. What this
	# function knows is what systemd said about the JOB, which is a different
	# fact and is written as a Note.
	#
	# The exception is a unit that could not be started at all: the runner never
	# ran, so nothing else will ever write a Result, and leaving an intent with
	# no result would make it indistinguishable from a machine that died
	# mid-step — the one state AU5 exists to make detectable.
	$phase = if ($failure) { 'Result' } else { 'Note' }
	if (-not $failure) { $record['startedOk'] = $true }

	# AND A RESULT IF THE RUNNER COULD NOT WRITE ONE. Measured 2026-09-15: a job
	# started with -Identity runs as that account, and the journal is root-owned
	# — so `Write-OS7JobRecord` inside the unit refused and the run left an
	# intent with no result, which AU5 reserves for a machine that died. AU4's
	# named identity was therefore unusable, and open question 3's "root by
	# default" was really "root or nothing".
	#
	# The journal stays root-owned: an evidence file the job itself could
	# rewrite is not evidence. What changes is who writes the last line — this
	# function, which Assert-OS7Elevated has already established is root.
	#
	# ASKED, NOT ASSUMED. The journal is read back, so a root job's richer
	# record from the runner is never duplicated or overwritten.
	if (-not $failure -and -not $NoWait) {
		$already = @(Get-OS7JobRecord -JobId $id -Days 1 | Where-Object Phase -eq 'Result')
		if (-not $already.Count) {
			$record['writtenBy'] = 'starter: the job could not write its own record'
			$record['identity'] = $intent.identity
			$phase = 'Result'
		}
	}
	Write-OS7JobRecord -JobId $id -Phase $phase -Record $record -Confirm:$false | Out-Null

	if ($failure) {
		throw [System.InvalidOperationException]::new(
			"job '$Name' ($id) could not be started: $failure")
	}

	return [pscustomobject]@{
		PSTypeName  = 'OS7.Automation.Job'
		Id          = $id
		Name        = $Name
		Unit        = $unit
		Identity    = $intent.identity
		Unconfined  = [bool]$Unconfined
		Secrets     = @($Secret)
		TimeoutSec  = $TimeoutSec
		Directory   = $dir
		ActiveState = $record.activeState
		SubState    = $record.subState
		Result      = $record.result
		DurationSec = $record.durationSec
	}
}

function New-OS7JobDropInText {
	<#
	.SYNOPSIS
		Internal. The per-run half of a job's unit, as text.

	.DESCRIPTION
		A SEPARATE FUNCTION SO THAT THE CHECK CAN READ IT WITHOUT A MACHINE.
		check-automation-logic.py asks this for the text and asserts the
		directives — which is the only way AU4's "the defaults are restrictive"
		can be a rule rather than a sentence. It is the same reason
		New-NetplanDocument is a function and not eight lines inside a Set-
		verb.

		WHAT IS NOT HERE IS THE POINT. The fence — Slice=, ProtectSystem=,
		ProtectHome=, PrivateTmp=, NoNewPrivileges=, the input channel — lives
		in the PACKAGED template, so it cannot be varied per run by a caller
		and it rolls back with the release. Only -Unconfined reaches into it,
		and it does so by naming each directive it switches off, one per line,
		where an auditor reading the drop-in can see them.
	#>
	param(
		[Parameter(Mandatory)][string]$Id,
		[Parameter(Mandatory)][string]$Name,
		[string[]]$Secret = @(),
		[string]$Identity,
		[switch]$DynamicUser,
		[string]$Keytab,
		[int]$TimeoutSec = $script:OS7JobDefaultTimeoutSec,
		[string]$MemoryMax,
		[string]$CpuQuota,
		[int]$TasksMax,
		[switch]$Unconfined
	)

	$lines = [System.Collections.Generic.List[string]]::new()
	$lines.Add('# Written by Start-OS7Job. Per-run only — the fence is in')
	$lines.Add('# /usr/lib/systemd/system/os7-job@.service, which ships in a package.')
	$lines.Add('[Unit]')
	$lines.Add("Description=OS/7 job $Name ($Id)")
	$lines.Add('')
	$lines.Add('[Service]')

	# The kill for a job that will not end. ALWAYS written: a job with no
	# timeout is a job that can hold the slice until somebody notices.
	#
	# TimeoutStartSec= and NOT RuntimeMaxSec=, which is what this said until a
	# machine printed the correction into its own journal (BUILD-NOTES #155):
	# `RuntimeMaxSec= has no effect in combination with Type=oneshot. Ignoring.`
	# The unit still loaded, the job still ran, and `systemctl show -p
	# RuntimeMaxSec` came back EMPTY. A oneshot is `activating` for its whole
	# life, so the bound that applies is the one on starting.
	$lines.Add("TimeoutStartSec=$TimeoutSec")

	if ($MemoryMax) { $lines.Add("MemoryMax=$MemoryMax") }
	if ($CpuQuota) { $lines.Add("CPUQuota=$CpuQuota") }
	if ($TasksMax) { $lines.Add("TasksMax=$TasksMax") }

	if ($DynamicUser) { $lines.Add('DynamicUser=yes') }
	elseif ($Identity) { $lines.Add("User=$Identity") }

	foreach ($s in $Secret) {
		# The path is spelled out rather than left to %i: a credential is the
		# one directive where an operator reading the drop-in should see
		# exactly which file is being opened.
		$lines.Add("LoadCredentialEncrypted=$s`:$((Get-OS7SecretPath -Name $s))")
	}

	if ($Keytab) {
		# AU7: a cache of this job's own, under the unit's RuntimeDirectory,
		# which systemd removes when the unit stops. %t is /run.
		$lines.Add("Environment=KRB5CCNAME=FILE:%t/os7-job/$Id/krb5cc")
	}

	if ($Unconfined) {
		$lines.Add('')
		$lines.Add('# -Unconfined. Each of these is switched off by name rather than')
		$lines.Add('# by a blanket, so this drop-in is readable as a list of what was')
		$lines.Add('# given up. It is recorded in the job journal as well.')
		$lines.Add('ProtectSystem=no')
		$lines.Add('ProtectHome=no')
		$lines.Add('PrivateTmp=no')
		$lines.Add('NoNewPrivileges=no')
	}

	return (($lines -join "`n") + "`n")
}

function Get-OS7RecordField {
	<#
	.SYNOPSIS
		Internal. One field out of a journal record, or $null.

	.DESCRIPTION
		BUILD-NOTES #112/#119, met on a machine on 2026-09-14 in this file's own
		`Get-OS7Job`, the first time anything ran a real job.

		THE JOURNAL IS WRITTEN BY TWO PARTIES AND THEIR RECORDS DO NOT HAVE THE
		SAME FIELDS, which is the whole reason this helper exists rather than a
		dot. `Start-OS7Job` writes the Intent and — only when the unit could not
		be started — a Result; the RUNNER inside the unit writes the ordinary
		Result, and it knows things the starter does not (`exitCode`,
		`credentials`, `ticket`) while the starter knows things the runner does
		not (`activeState`). Reading `.result` off the runner's record is a
		property that is not there, and under `Set-StrictMode -Version Latest`
		that is a TERMINATING error rather than a $null — so `Get-OS7Job` did
		not return a job with a missing field, it returned nothing at all and
		threw.

		A schema with a version (open question 4) makes this survivable rather
		than unnecessary: a reader still has to cope with the fields a given
		writer emits.
	#>
	param($Record, [Parameter(Mandatory)][string]$Name)

	if ($null -eq $Record) { return $null }
	if (-not $Record.PSObject.Properties[$Name]) { return $null }
	return $Record.$Name
}

function Get-OS7Job {
	<#
	.SYNOPSIS
		The jobs this machine has run, from the journal, with the unit's state
		beside each.

	.DESCRIPTION
		The JOURNAL is the authority for what happened and systemd is the
		authority for what is happening — and they are different questions, so
		both are asked. A job whose intent has no result AND whose unit is gone
		is a run that was interrupted; that is the one state worth a field, and
		it is computed rather than left to the reader.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Position = 0)][string]$Id,
		[int]$Days = 7
	)

	Import-OS7SystemdLayer
	$records = @(Get-OS7JobRecord -JobId $Id -Days $Days)
	$byJob = $records | Group-Object Job

	$out = foreach ($g in $byJob) {
		if (-not $g.Name) { continue }
		if ($g.Name -like 'secret:*') { continue }
		$intent = @($g.Group | Where-Object Phase -eq 'Intent' | Select-Object -First 1)
		$result = @($g.Group | Where-Object Phase -eq 'Result' | Select-Object -First 1)
		if (-not $intent.Count) { continue }

		$ir = if ($intent[0].PSObject.Properties['Record']) { $intent[0].Record } else { $null }
		$rr = if ($result.Count -and $result[0].PSObject.Properties['Record']) { $result[0].Record } else { $null }

		$unit = [string](Get-OS7RecordField -Record $ir -Name 'unit')
		$live = $null
		try { $live = @(Get-SystemdUnit -Name $unit) | Select-Object -First 1 } catch { $live = $null }

		# THE RUNNER'S WORD FIRST, THE STARTER'S SECOND, and the order is the
		# answer to a question rather than a preference: `exitCode` is what the
		# job's own command returned, which is what an operator is asking about;
		# `result` is systemd's word for the unit, and it is all there is when
		# the unit could not be started at all and the runner never ran.
		$code = Get-OS7RecordField -Record $rr -Name 'exitCode'
		if ($null -eq $code) { $code = Get-OS7RecordField -Record $rr -Name 'result' }

		[pscustomobject]@{
			PSTypeName  = 'OS7.Automation.Job'
			Id          = $g.Name
			Name        = (Get-OS7RecordField -Record $ir -Name 'name')
			Unit        = $unit
			Started     = $intent[0].Time
			Identity    = (Get-OS7RecordField -Record $ir -Name 'identity')
			Unconfined  = [bool](Get-OS7RecordField -Record $ir -Name 'unconfined')
			Secrets     = @(Get-OS7RecordField -Record $ir -Name 'secrets')
			Complete    = [bool]$result.Count
			# An intent with no result and no unit: the machine stopped in the
			# middle. AU5's whole reason for writing ahead.
			Interrupted = ((-not $result.Count) -and ($null -eq $live -or $live.LoadState -ne 'loaded'))
			DurationSec = (Get-OS7RecordField -Record $rr -Name 'durationSec')
			Result      = $code
			Error       = (Get-OS7RecordField -Record $rr -Name 'error')
			ActiveState = if ($live) { $live.ActiveState } else { $null }
		}
	}
	return @($out | Sort-Object Started -Descending)
}

function New-OS7JobTicket {
	<#
	.SYNOPSIS
		A Kerberos ticket for a job, from a keytab, in a cache of the job's
		own. AU7.

	.DESCRIPTION
		CALLED FROM INSIDE THE UNIT, by /usr/libexec/os7-job-run.ps1, and that
		is the decision rather than an implementation detail. Obtaining the
		ticket in `Start-OS7Job` would put it in the CALLER's credential cache
		— the machine's default one — which is precisely the sharing AU7 exists
		to prevent: two jobs in one cache are two jobs with one identity,
		racing over its lifetime, and the first one's `kdestroy` takes the
		second one's ticket.

		THE CACHE IS UNDER THE UNIT'S RuntimeDirectory, so systemd removes it
		when the unit stops. "Destroyed with the unit" is then a property of
		the system rather than of this script remembering to do it — which
		matters most in the case where it did not get the chance, because the
		job was killed.

		The Kerberos work itself is the Directory layer's (P2-directory): this
		function decides WHICH cache and WHICH keytab, and `kinit` is spelled
		nowhere in powershell/OS7.

	.PARAMETER CachePath
		Where the ticket goes. The runner passes the path out of KRB5CCNAME,
		which the job's drop-in set.
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory)][string]$Keytab,
		[Parameter(Mandatory)][string]$Principal,
		[Parameter(Mandatory)][string]$CachePath
	)

	Import-OS7DirectoryLayer

	if (-not [System.IO.File]::Exists($Keytab)) {
		throw [System.IO.FileNotFoundException]::new(
			"no keytab at '$Keytab'. A job with -Keytab needs one that exists at the moment " +
			'the unit starts, not at the moment the job was registered.')
	}

	$dir = [System.IO.Path]::GetDirectoryName($CachePath)
	if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
		[System.IO.Directory]::CreateDirectory($dir) | Out-Null
	}

	return (New-DirectoryTicket -Principal $Principal -Keytab $Keytab -CachePath $CachePath)
}

# =============================================================================
# AU8 — named locks
#
# `Update-OS7` already has /run/os7-update.lock; this is the general form. The
# question an operator actually has is not "is it locked" but "WHO HAS IT and
# should I be worried", so a lock that does not say is not a lock this product
# ships.
# =============================================================================

function Get-OS7LockPath {
	param([Parameter(Mandatory)][string]$Name)
	return (Join-Path $script:OS7LockDirectory $Name)
}

function Lock-OS7Resource {
	<#
	.SYNOPSIS
		Takes a named lock, recording who holds it and since when.

	.DESCRIPTION
		ATOMIC, by `FileMode.CreateNew` — O_EXCL in the kernel. A
		test-then-create would have a window between the two in which both
		callers see no lock, which is the only failure mode a lock has.

		LOCKS LIVE IN /run AND DO NOT SURVIVE A REBOOT. That is correct and is
		written down rather than discovered: a lock held by a process that no
		longer exists is a deadlock, and a reboot is the cheapest possible
		release.

		A STALE LOCK IS REPORTED, NOT BROKEN. If the recorded holder's pid is
		gone, this says so in the exception and -Force is how a person decides.
		Breaking it automatically would make the lock advisory in exactly the
		case it was taken for — a job that is still running under a pid that
		was reused is indistinguishable from a dead one without asking more
		than a lock file can answer.

	.PARAMETER Name
		The resource. `Get-OS7Lock` lists them.

	.PARAMETER Holder
		What to record as the holder. Defaults to this process.

	.PARAMETER Force
		Take a lock whose holder is gone.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[string]$Holder,
		[switch]$Force
	)

	Assert-OS7Elevated -Cmdlet 'Lock-OS7Resource' -Because (
		'creates a lock file under /run/os7/locks, which is root-owned')

	Assert-OS7AutomationName -Name $Name -What 'lock name'
	if (-not $Holder) { $Holder = "pid $PID ($([System.Diagnostics.Process]::GetCurrentProcess().ProcessName))" }

	[System.IO.Directory]::CreateDirectory($script:OS7LockDirectory) | Out-Null
	$path = Get-OS7LockPath -Name $Name

	$existing = Get-OS7Lock -Name $Name
	if ($existing) {
		if (-not ($Force -and $existing.Stale)) {
			$age = if ($existing.Since) {
				" for $([Math]::Round(([datetime]::UtcNow - $existing.Since).TotalMinutes, 1)) minutes"
			} else { '' }
			$stale = if ($existing.Stale) {
				" Its holder's process is GONE, so this is very probably a lock nobody is using; " +
				'-Force takes it.'
			} else { '' }
			throw [System.InvalidOperationException]::new(
				"'$Name' is held by $($existing.Holder)$age.$stale")
		}
		if (-not $PSCmdlet.ShouldProcess($Name, "break a stale lock held by $($existing.Holder)")) { return }
		[System.IO.File]::Delete($path)
	}

	if (-not $PSCmdlet.ShouldProcess($Name, 'take the lock')) { return }

	$now = [datetime]::UtcNow
	$body = ConvertTo-Json -Depth 4 -InputObject ([ordered]@{
			schema   = $script:OS7JobRecordSchema
			name     = $Name
			holder   = $Holder
			pid      = $PID
			acquired = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
			by       = ($env:SUDO_USER ?? $env:USER ?? 'unknown')
		})

	try {
		# CreateNew: the create IS the test. FileShare::None so a second
		# caller cannot read a half-written lock and decide it is malformed.
		$fs = [System.IO.FileStream]::new($path, [System.IO.FileMode]::CreateNew,
			[System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
		try {
			$b = [System.Text.Encoding]::UTF8.GetBytes($body)
			$fs.Write($b, 0, $b.Length)
			$fs.Flush($true)
		}
		finally { $fs.Dispose() }
	}
	catch [System.IO.IOException] {
		# Somebody else won the race between Get-OS7Lock and here. That is the
		# window the atomic create exists to close, and this is what closing it
		# looks like from the losing side.
		$now2 = Get-OS7Lock -Name $Name
		throw [System.InvalidOperationException]::new(
			"'$Name' was taken while this call was preparing to take it" +
			($now2 ? " — it is held by $($now2.Holder)." : '.'))
	}

	return (Get-OS7Lock -Name $Name)
}

function Unlock-OS7Resource {
	<#
	.SYNOPSIS
		Releases a named lock.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		# Release a lock this process does not hold. Without it, releasing
		# somebody else's lock is refused — the failure that turns a lock into
		# decoration is a cleanup path that releases everything it finds.
		[switch]$Force
	)

	Assert-OS7Elevated -Cmdlet 'Unlock-OS7Resource' -Because (
		'deletes a lock file under /run/os7/locks, which is root-owned')

	Assert-OS7AutomationName -Name $Name -What 'lock name'
	$lock = Get-OS7Lock -Name $Name
	if (-not $lock) { return $false }

	if ($lock.ProcessId -ne $PID -and -not $Force -and -not $lock.Stale) {
		throw [System.InvalidOperationException]::new(
			"'$Name' is held by $($lock.Holder), not by this process (pid $PID). -Force " +
			'releases it anyway.')
	}
	if (-not $PSCmdlet.ShouldProcess($Name, 'release the lock')) { return $false }

	[System.IO.File]::Delete((Get-OS7LockPath -Name $Name))
	return (-not (Get-OS7Lock -Name $Name))
}

function Get-OS7Lock {
	<#
	.SYNOPSIS
		The locks this machine holds, who holds each and since when.

	.DESCRIPTION
		`Stale` is asked of the kernel — /proc/<pid> — and not of the clock. A
		lock held for six hours by a process that is still running is not
		stale, it is slow, and those two send an operator to different places.
	#>
	[CmdletBinding()]
	param([Parameter(Position = 0)][string]$Name)

	if (-not [System.IO.Directory]::Exists($script:OS7LockDirectory)) { return @() }

	$files = @(Get-ChildItem -LiteralPath $script:OS7LockDirectory -File -ErrorAction SilentlyContinue)
	if ($Name) { $files = @($files | Where-Object { $_.Name -eq $Name }) }

	$out = foreach ($f in ($files | Sort-Object Name)) {
		$o = $null
		try { $o = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { $o = $null }

		$holderPid = if ($o -and $o.PSObject.Properties['pid']) { [int]$o.pid } else { 0 }
		# The kernel, not `ps`, and not a timeout. A pid directory that is not
		# there is a process that is not there.
		$alive = if ($holderPid -gt 0) { [System.IO.Directory]::Exists("/proc/$holderPid") } else { $false }

		$since = $null
		if ($o -and $o.PSObject.Properties['acquired']) {
			try {
				$since = [datetime]::Parse($o.acquired, [cultureinfo]::InvariantCulture,
					[System.Globalization.DateTimeStyles]::AdjustToUniversal)
			}
			catch { $since = $null }
		}

		[pscustomobject]@{
			PSTypeName = 'OS7.Automation.Lock'
			Name       = $f.Name
			Holder     = if ($o -and $o.PSObject.Properties['holder']) { $o.holder } else { '(unreadable)' }
			ProcessId  = $holderPid
			Since      = $since
			By         = if ($o -and $o.PSObject.Properties['by']) { $o.by } else { $null }
			Stale      = (-not $alive)
			Path       = $f.FullName
		}
	}
	$all = @($out)
	if ($Name) { return ($all | Select-Object -First 1) }
	return $all
}

# =============================================================================
# AU11 — notification
#
# A job that failed at 03:00 is otherwise known to nobody: `Healthy` is pull,
# not push.
#
# AND IT NEEDS NO MTA, which corrects the plan and is the reason this could be
# built at all in this pass. AUTOMATION-PLAN §1 recorded "no MTA is in any
# package list, so a machine that wants to send a mail today cannot", and §8 put
# AU11 last because installing one costs a build. It does not: SMTP submission
# to the organisation's relay is a TCP conversation, .NET has had a client for
# it since forever, and it ships inside pwsh. An MTA would add a spool, a queue,
# a second retry policy and a listening socket to a machine whose bad news is
# better delivered synchronously or not at all — so not installing one is now
# the decision rather than the obstacle.
# =============================================================================

function Get-OS7NotificationSink {
	<#
	.SYNOPSIS
		Where this machine sends its own bad news.

	.DESCRIPTION
		A DATA FILE, the shape `Get-OS7Endpoint` already uses — an
		organisation's relay is data, not code.

		ON THE AU6 DATASET AND NOT BESIDE THE MODULE, which is a correction to
		AU11 rather than an oversight: os7-endpoints.json ships in the package
		and is the same on every machine, while a sink is this machine's
		configuration. Beside the module it would be inside the boot
		environment and would roll back with the release — and the first thing
		a machine wants to say after a bad update is that the update was bad.
	#>
	[CmdletBinding()]
	param()

	$path = Get-OS7AutomationPath -What 'Sinks'
	if (-not [System.IO.File]::Exists($path)) { return @() }

	$doc = $null
	try { $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json }
	catch {
		throw [System.InvalidOperationException]::new(
			"$path is not readable as JSON: $($_.Exception.Message)")
	}
	if (-not $doc -or -not $doc.PSObject.Properties['sinks']) { return @() }

	return @($doc.sinks | ForEach-Object {
			[pscustomobject]@{
				PSTypeName = 'OS7.Automation.NotificationSink'
				Name       = $_.name
				Type       = $_.type
				Target     = $_.target
				From       = if ($_.PSObject.Properties['from']) { $_.from } else { $null }
				Enabled    = if ($_.PSObject.Properties['enabled']) { [bool]$_.enabled } else { $true }
			}
		})
}

function Set-OS7NotificationSink {
	<#
	.SYNOPSIS
		Adds or replaces one notification sink.

	.PARAMETER Type
		`smtp` — Target is host:port, From is the envelope sender.
		`webhook` — Target is a URL; the notification is POSTed as JSON.
		`command` — Target is an absolute path; the notification arrives on
		its stdin as JSON, for the sites whose alerting is a program.

	.PARAMETER Remove
		Delete this sink.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Name,
		[ValidateSet('smtp', 'webhook', 'command')][string]$Type,
		[string]$Target,
		[string]$From,
		[nullable[bool]]$Enabled,
		[switch]$Remove
	)

	Assert-OS7Elevated -Cmdlet 'Set-OS7NotificationSink' -Because (
		'writes the machine notification configuration under /var/lib/os7-automation')

	Assert-OS7AutomationName -Name $Name -What 'sink name'
	$path = Get-OS7AutomationPath -What 'Sinks'
	$dir = [System.IO.Path]::GetDirectoryName($path)
	if (-not [System.IO.Directory]::Exists($dir)) {
		throw [System.IO.DirectoryNotFoundException]::new(
			"no $dir. New-OS7ServiceDataset -Name os7-automation creates it.")
	}

	$sinks = [System.Collections.Generic.List[object]]::new()
	foreach ($s in (Get-OS7NotificationSink)) { if ($s.Name -ne $Name) { $sinks.Add($s) } }

	if (-not $Remove) {
		if (-not $Type -or -not $Target) {
			throw [System.ArgumentException]::new('a new sink needs -Type and -Target.')
		}
		if ($Type -eq 'command' -and -not $Target.StartsWith('/')) {
			throw [System.ArgumentException]::new(
				"a command sink's target must be an absolute path — PATH is not the same for " +
				'systemd as it is for a login shell.')
		}
		if ($Type -eq 'webhook' -and $Target -notmatch '^https?://') {
			throw [System.ArgumentException]::new("a webhook sink's target must be an http(s) URL.")
		}
		$sinks.Add([pscustomobject]@{
				Name    = $Name
				Type    = $Type
				Target  = $Target
				From    = $From
				Enabled = ($null -eq $Enabled) ? $true : [bool]$Enabled
			})
	}

	if (-not $PSCmdlet.ShouldProcess($Name, ($Remove ? 'remove the sink' : 'write the sink'))) { return }

	$doc = [ordered]@{
		schema = $script:OS7JobRecordSchema
		sinks  = @($sinks | ForEach-Object {
				[ordered]@{
					name    = $_.Name
					type    = $_.Type
					target  = $_.Target
					from    = $_.From
					enabled = $_.Enabled
				}
			})
	}
	[System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $doc -Depth 6))
	[System.IO.File]::SetUnixFileMode($path,
		[System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor
		[System.IO.UnixFileMode]::GroupRead)
	return (Get-OS7NotificationSink)
}

function Send-OS7Notification {
	<#
	.SYNOPSIS
		Sends the machine's own bad news to every enabled sink, and reports
		which ones took it.

	.DESCRIPTION
		AU11 is for the MACHINE's bad news — backup failed, update failed, a
		lock has been held for six hours. A product above sends its own
		business mail through its own templates.

		IT RETURNS ONE RESULT PER SINK AND NEVER ONE ANSWER. "The notification
		was sent" over three sinks of which one worked is the shape of every
		alerting system that quietly stops alerting, and this repository has a
		rule about exactly that: a program reported success and the thing it
		was meant to do did not happen. A sink that failed is named, with what
		it said.

		A FAILING SINK IS NOT A TERMINATING ERROR, for the same reason. This is
		usually called from a catch block; throwing here would replace the
		problem being reported with a problem reporting it.

	.PARAMETER Severity
		`Information`, `Warning` or `Error`. Carried to the sink, not
		interpreted here.
	#>
	[CmdletBinding(SupportsShouldProcess)]
	param(
		[Parameter(Mandatory, Position = 0)][string]$Subject,
		[Parameter(Position = 1)][string]$Body = '',
		[ValidateSet('Information', 'Warning', 'Error')][string]$Severity = 'Warning',
		[string]$To,
		[string[]]$Sink
	)

	$sinks = @(Get-OS7NotificationSink | Where-Object Enabled)
	if ($Sink) { $sinks = @($sinks | Where-Object { $Sink -contains $_.Name }) }
	if (-not $sinks.Count) {
		Write-Warning ('there is no enabled notification sink on this machine, so nothing was ' +
			'sent. Set-OS7NotificationSink configures one; without it a job that fails at ' +
			'03:00 is known to nobody.')
		return @()
	}

	$hostName = [System.Net.Dns]::GetHostName()
	$payload = [ordered]@{
		schema   = $script:OS7JobRecordSchema
		host     = $hostName
		time     = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
		severity = $Severity
		subject  = $Subject
		body     = $Body
	}
	$json = ConvertTo-Json -InputObject $payload -Depth 6

	$out = foreach ($s in $sinks) {
		if (-not $PSCmdlet.ShouldProcess($s.Name, "send '$Subject'")) { continue }
		$ok = $false
		$why = $null
		try {
			switch ($s.Type) {
				'smtp' { Send-OS7NotificationSmtp -Sink $s -Subject $Subject -Body $Body -Severity $Severity -To $To -HostName $hostName; $ok = $true }
				'webhook' { Send-OS7NotificationWebhook -Sink $s -Json $json; $ok = $true }
				'command' { Send-OS7NotificationCommand -Sink $s -Json $json; $ok = $true }
			}
		}
		catch { $why = $_.Exception.Message }

		[pscustomobject]@{
			PSTypeName = 'OS7.Automation.NotificationResult'
			Sink       = $s.Name
			Type       = $s.Type
			Target     = $s.Target
			Delivered  = $ok
			Error      = $why
		}
	}
	return @($out)
}

function Send-OS7NotificationSmtp {
	<#
	.SYNOPSIS
		Internal. SMTP submission to a relay — no MTA on this machine.

	.DESCRIPTION
		System.Net.Mail, which ships inside pwsh. No queue and no spool: a
		machine that cannot reach its relay says so in the return value rather
		than holding the message for a retry nobody will watch.
	#>
	param(
		[Parameter(Mandatory)]$Sink,
		[Parameter(Mandatory)][string]$Subject,
		[string]$Body,
		[string]$Severity,
		[string]$To,
		[Parameter(Mandatory)][string]$HostName
	)

	$target = [string]$Sink.Target
	$smtpHost = $target
	$port = 25
	if ($target -match '^(.+):([0-9]+)$') { $smtpHost = $Matches[1]; $port = [int]$Matches[2] }

	$recipient = $To
	if (-not $recipient) { $recipient = [string]$Sink.From }
	if (-not $recipient) {
		throw ('this sink has no recipient: give -To, or set -From on the sink so there is ' +
			'somewhere to send to.')
	}
	$from = if ($Sink.From) { [string]$Sink.From } else { "os7@$HostName" }

	$client = [System.Net.Mail.SmtpClient]::new($smtpHost, $port)
	try {
		$msg = [System.Net.Mail.MailMessage]::new($from, $recipient,
			"[OS/7 $Severity] $HostName`: $Subject", $Body)
		try { $client.Send($msg) } finally { $msg.Dispose() }
	}
	finally { $client.Dispose() }
}

function Send-OS7NotificationWebhook {
	param([Parameter(Mandatory)]$Sink, [Parameter(Mandatory)][string]$Json)
	Invoke-RestMethod -Method Post -Uri ([string]$Sink.Target) -ContentType 'application/json' `
		-Body $Json -TimeoutSec 30 | Out-Null
}

function Send-OS7NotificationCommand {
	param([Parameter(Mandatory)]$Sink, [Parameter(Mandatory)][string]$Json)
	$target = [string]$Sink.Target
	if (-not [System.IO.File]::Exists($target)) { throw "no such program: $target" }

	# The notification arrives on STDIN. Not as an argument — the same rule
	# AU3 gives for a job's input, and for the same reason: a subject line with
	# an operator's name in it is world-readable in `ps`.
	$psi = [System.Diagnostics.ProcessStartInfo]::new()
	$psi.FileName = $target
	$psi.RedirectStandardInput = $true
	$psi.RedirectStandardError = $true
	$psi.UseShellExecute = $false
	$p = [System.Diagnostics.Process]::Start($psi)
	$p.StandardInput.Write($Json)
	$p.StandardInput.Close()
	$err = $p.StandardError.ReadToEnd()
	$p.WaitForExit()
	if ($p.ExitCode -ne 0) { throw "$target exited $($p.ExitCode): $($err.Trim())" }
}
