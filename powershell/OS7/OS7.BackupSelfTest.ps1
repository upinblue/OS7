# =============================================================================
# OS/7 Backup — the self-test (docs/BACKUP-PLAN.md §9)
#
# Dot-sourced by OS7.psm1.
#
# THE SAME TWO TIERS AS Test-ZfsModule (ZFS-POWERSHELL-PLAN Z10), for the same
# reason: there is no Pester in the image, adding one would mean a new pinned
# component for test code only, and a test only a developer can run is a test
# that stops being run.
#
#   tier 1  here. The decisions this feature makes, checked against recorded
#           facts and fabricated trees. Runs anywhere pwsh runs, in a second,
#           with no ZFS, no sanoid and no disks.
#   tier 2  installer/testing/run-backup.py — the cmdlets against real ZFS and
#           the real sanoid, on a booted VM. That is the gate; nothing here
#           replaces it, and this file says so rather than implying otherwise.
#
# WHAT TIER 1 CAN AND CANNOT SEE. It can see every rule this feature encodes
# about somebody else's program: which sections may be written, which datasets
# must be refused, which flags are passed to syncoid and which are deliberately
# not, and how a path is resolved to a dataset. It cannot see whether sanoid
# then behaves as measured. The measurements are in docs/BACKUP-PLAN.md §13
# with their cites, and this file is where the code is held to them.
# =============================================================================

function Test-OS7Backup {
	<#
	.SYNOPSIS
		Check the backup layer's decisions, offline or against this machine.

	.PARAMETER Live
		Also exercise the read paths against the ZFS and the sanoid on this
		machine. Read-only throughout: it takes no snapshot, writes no config
		and contacts no target.

	.EXAMPLE
		Test-OS7Backup

	.EXAMPLE
		pwsh -c 'Import-Module ./powershell/OS7/OS7.psd1 -Force; Test-OS7Backup'
	#>
	[CmdletBinding()]
	param([switch]$Live)

	$pass = 0
	$fail = [System.Collections.Generic.List[string]]::new()

	function ok($name, $cond, $detail = '') {
		if ($cond) { [Console]::Error.WriteLine("  PASS  $name"); return $true }
		[Console]::Error.WriteLine("  FAIL  $name $detail")
		return $false
	}

	[Console]::Error.WriteLine('OS/7 Backup self-test')

	# -----------------------------------------------------------------------
	# 1. The guard. This is the one that matters most: everything else here
	#    fails visibly, and this one fails by destroying a boot environment.
	# -----------------------------------------------------------------------
	$refuse = @(
		'rpool', 'bpool',
		'rpool/ROOT', 'rpool/ROOT/os7_1.0.0.95_202608252230',
		'rpool/ROOT/os7_1.0.0.95_202608252230/var/lib/dpkg',
		'bpool/BOOT', 'bpool/BOOT/os7_1.0.0.95_202608252230'
	)
	foreach ($d in $refuse) {
		$threw = $false
		try { Assert-OS7DatasetSafe -Name $d } catch { $threw = $true }
		if (ok "the guard refuses $d" $threw) { $pass++ } else { $fail.Add("guard let $d through") }
	}

	$allow = @('rpool/USERDATA', 'rpool/USERDATA/os7_1a2b3c4d', 'rpool/DATA/srv', 'tank/data')
	foreach ($d in $allow) {
		$threw = $false
		try { Assert-OS7DatasetSafe -Name $d } catch { $threw = $true }
		if (ok "the guard allows $d" (-not $threw)) { $pass++ } else { $fail.Add("guard refused $d") }
	}

	# THE INVARIANT FROM THE OTHER SIDE. The guard above is OS/7 refusing to
	# point sanoid at the update train. This is the check that sanoid could not
	# touch it even if the guard were wrong: sanoid destroys only snapshots
	# whose name begins `autosnap` AND ends in `ly`, so an OS/7 boot-environment
	# snapshot has to fail at least one of those tests — and it must keep
	# failing them when somebody changes New-OS7BootEnvironmentName.
	$beName = New-OS7BootEnvironmentName -Release '1.0.0.95' -When ([datetime]'2026-08-25T22:30:00')
	foreach ($t in @(
			@{ n = 'a boot-environment snapshot name does not begin `autosnap`'
			   c = (-not $beName.StartsWith('autosnap')) }
			@{ n = 'a boot-environment snapshot name does not end in `ly`'
			   c = (-not $beName.EndsWith('ly')) }
		)) { if (ok $t.n $t.c "(name was '$beName')") { $pass++ } else { $fail.Add($t.n) } }

	# -----------------------------------------------------------------------
	# 2. The rendered sanoid.conf
	# -----------------------------------------------------------------------
	$sources = @(
		[pscustomobject]@{
			Dataset = 'rpool/USERDATA'; Recursive = $true; ChildrenOnly = $true
			Retention = (New-OS7BackupRetention)
		}
		[pscustomobject]@{
			Dataset = 'rpool/DATA/srv'; Recursive = $true; ChildrenOnly = $false
			Retention = (New-OS7BackupRetention)
		}
	)
	$conf = ConvertTo-OS7SanoidConf -Source $sources -Stamp '2026-08-25T22:30:00Z'
	$lines = $conf -split "`n"

	foreach ($t in @(
			# The FATAL ones. An unrecognised setting anywhere in this file makes
			# sanoid die rather than warn, which stops the timer without stopping
			# anything that reports on the timer.
			@{ n = 'no [version] stanza — `version` is not a legal setting here'
			   c = ($conf -notmatch '(?m)^\[version\]') }
			@{ n = 'every section header is a dataset path'
			   c = (@($lines | Where-Object { $_ -match '^\[' }) -join ',') -eq
			        '[rpool/USERDATA],[rpool/DATA/srv]' }
			@{ n = 'no key is emitted that is not a sanoid setting'
			   c = (@($lines |
			          Where-Object { $_ -match '^\s+([A-Za-z0-9_]+)\s*=' } |
			          ForEach-Object { ($_ -split '=')[0].Trim() } |
			          Select-Object -Unique |
			          Where-Object { $_ -notin @('use_template', 'recursive',
			                'process_children_only', 'autosnap', 'autoprune',
			                'frequently', 'hourly', 'daily', 'weekly', 'monthly', 'yearly') }
			        ).Count -eq 0) }

			# `recursive = zfs` runs `zfs snapshot -r`, which snapshots the whole
			# subtree at the ZFS level including datasets sanoid has no section
			# for. Near rpool/ROOT that is the catastrophe the guard exists to
			# prevent, arriving by a route the guard cannot see.
			@{ n = 'recursion is `yes`, never `zfs`'
			   c = ($conf -match '(?m)^\s+recursive = yes' -and $conf -notmatch 'recursive = zfs') }

			# All six, always. Anything omitted inherits sanoid's own defaults —
			# hourly=48, daily=90, monthly=6 — so an omission is not "unset".
			# $key, not $_ — a nested Where-Object rebinds $_ to the INNER
			# collection, so the pattern would be built from the line it is
			# being matched against and every test would pass.
			@{ n = 'all six retention counts are stated for every section'
			   c = (@(@('frequently', 'hourly', 'daily', 'weekly', 'monthly', 'yearly') |
			          Where-Object { $key = $_; @($lines | Where-Object { $_ -match "^\s+$key = " }).Count -ne 2 }
			        ).Count -eq 0) }
			@{ n = 'the container is process_children_only'
			   c = ($conf -match '(?m)^\[rpool/USERDATA\][\s\S]*?process_children_only = yes') }
			@{ n = 'the leaf dataset is NOT process_children_only'
			   c = (($conf -split '\[rpool/DATA/srv\]')[1] -notmatch 'process_children_only') }
			@{ n = 'the file says it is generated and where the truth lives'
			   c = ($conf -match 'Generated by OS/7' -and $conf -match '/etc/os7/backup.json') }
		)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

	# OS/7's retention, not sanoid's. The shipped defaults are 48/90/6 and the
	# floor OS/7 installs on is a 16 GB disk with no quota on any dataset.
	$r = New-OS7BackupRetention
	foreach ($t in @(
			@{ n = 'the default retention is OS/7s, not sanoid shipped 48/90/6'
			   c = ($r.hourly -eq 24 -and $r.daily -eq 14 -and $r.weekly -eq 4 -and $r.monthly -eq 3) }
			@{ n = 'the default keeps fewer than 50 snapshots per dataset'
			   c = ((($r.Values | Measure-Object -Sum).Sum) -lt 50) }
		)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

	# -- Set-OS7BackupPolicy, against a scratch /etc ------------------------
	#
	# The paths are script-scope variables and this function runs in module
	# scope, so they can be pointed somewhere harmless and the REAL cmdlet run
	# against them — which tests the write, the JSON round trip and the read-back
	# rather than a projection of them.
	#
	# NOT -WhatIf, and the reason is measured: ShouldProcess writes "What if:" to
	# the HOST, the host's output is stdout, and it cannot be redirected from
	# inside the script — `*>$null` on the call does not catch it. That is
	# docs/BUILD-NOTES.md #60, and it is the same fact that makes New-OS7Storage
	# carry a separate dry-run branch instead of passing -WhatIf downwards.
	#
	# The regression this exists for: a local `$retention` IS the `-Retention`
	# parameter, because PowerShell names are case-insensitive. Assigning the
	# defaults to it overwrote what the caller passed and then enumerated the
	# dictionary it was writing to — "Collection was modified", naming no
	# variable and no parameter. #65, second sighting.
	$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("os7-backup-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
	$saved = @{
		cfg = $script:OS7BackupConfig
		dir = $script:OS7SanoidConfDir
		snd = $script:OS7SanoidConf
	}
	try {
		New-Item -ItemType Directory -Force -Path $scratch | Out-Null
		$script:OS7BackupConfig = Join-Path $scratch 'backup.json'
		$script:OS7SanoidConfDir = $scratch
		$script:OS7SanoidConf = Join-Path $scratch 'sanoid.conf'

		# The re-read at the end of Set-OS7BackupPolicy asks ZFS, which is not
		# here — so the exception is expected and the FILES are the evidence. If
		# the shadowing bug were back, it would throw before writing either.
		try { Set-OS7BackupPolicy -Dataset rpool/USERDATA -Retention @{ hourly = 48 } -Confirm:$false | Out-Null }
		catch { }

		$wroteJson = Test-Path -LiteralPath $script:OS7BackupConfig
		$doc = if ($wroteJson) { Get-Content -Raw -LiteralPath $script:OS7BackupConfig | ConvertFrom-Json } else { $null }
		$wroteConf = Test-Path -LiteralPath $script:OS7SanoidConf
		$confText = if ($wroteConf) { Get-Content -Raw -LiteralPath $script:OS7SanoidConf } else { '' }

		foreach ($t in @(
				@{ n = 'Set-OS7BackupPolicy writes the OS/7 policy'; c = $wroteJson }
				@{ n = 'Set-OS7BackupPolicy writes the sanoid config'; c = $wroteConf }
				@{ n = 'the policy it wrote parses as JSON'; c = ($null -ne $doc) }
				@{ n = '-Retention reached the file (the parameter is not shadowed)'
				   c = ($doc -and [int]$doc.sources[0].retention.hourly -eq 48) }
				@{ n = 'the untouched counts kept OS/7 defaults, not sanoid'
				   c = ($doc -and [int]$doc.sources[0].retention.daily -eq 14) }
				@{ n = 'the rendered config carries the same number'
				   c = ($confText -match '(?m)^\s+hourly = 48') }
				@{ n = 'the targets key survives a policy-only edit'
				   c = ($doc -and $doc.PSObject.Properties.Name -contains 'targets') }
			)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

		$threw = $null
		try { Set-OS7BackupPolicy -Retention @{ fortnightly = 2 } -Confirm:$false | Out-Null }
		catch { $threw = $_.Exception.Message }
		if (ok 'an unknown retention name is refused, and the message lists the real ones' (
				$threw -and $threw -like '*frequently, hourly, daily, weekly, monthly, yearly*')) { $pass++ }
		else { $fail.Add('unknown retention key not refused') }

		$threw = $null
		try { Set-OS7BackupPolicy -Dataset rpool/ROOT -Confirm:$false | Out-Null }
		catch { $threw = $_.Exception.Message }
		if (ok 'the guard runs BEFORE anything is written' ($threw -like '*update train*')) { $pass++ }
		else { $fail.Add('guard not reached from Set-OS7BackupPolicy') }
	}
	finally {
		$script:OS7BackupConfig = $saved.cfg
		$script:OS7SanoidConfDir = $saved.dir
		$script:OS7SanoidConf = $saved.snd
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $scratch
	}

	# -----------------------------------------------------------------------
	# 3. Resolving a path to the dataset that owns it
	# -----------------------------------------------------------------------
	#
	# The fabricated layout is OS/7's own, plus the two shapes that break a
	# naive matcher: an account whose name is a string prefix of another, and a
	# repair install's second USERDATA dataset carrying the same mountpoint
	# while unmounted.
	$fake = @(
		[pscustomobject]@{ Name = 'rpool/ROOT/os7_a'; Mountpoint = '/'; Mounted = $true }
		[pscustomobject]@{ Name = 'rpool/DATA/log'; Mountpoint = '/var/log'; Mounted = $true }
		[pscustomobject]@{ Name = 'rpool/USERDATA/os7_1111'; Mountpoint = '/home/os7'; Mounted = $true }
		[pscustomobject]@{ Name = 'rpool/USERDATA/os7admin_2222'; Mountpoint = '/home/os7admin'; Mounted = $true }
		[pscustomobject]@{ Name = 'rpool/USERDATA/os7_old9999'; Mountpoint = '/home/os7'; Mounted = $false }
		[pscustomobject]@{ Name = 'rpool/DATA/legacy'; Mountpoint = 'legacy'; Mounted = $true }
	)
	$cases = @(
		@{ p = '/home/os7/notes.txt'; ds = 'rpool/USERDATA/os7_1111'; rel = 'notes.txt' }
		@{ p = '/home/os7admin/notes.txt'; ds = 'rpool/USERDATA/os7admin_2222'; rel = 'notes.txt' }
		@{ p = '/var/log/syslog'; ds = 'rpool/DATA/log'; rel = 'syslog' }
		@{ p = '/etc/hostname'; ds = 'rpool/ROOT/os7_a'; rel = 'etc/hostname' }
		@{ p = '/home/os7/a/b/c.txt'; ds = 'rpool/USERDATA/os7_1111'; rel = 'a/b/c.txt' }
	)
	foreach ($c in $cases) {
		$got = Get-OS7PathDataset -Path $c.p -Dataset $fake
		$good = $got -and $got.Dataset -eq $c.ds -and $got.RelativePath -eq $c.rel
		if (ok "$($c.p) belongs to $($c.ds)" $good "(got $($got.Dataset) rel '$($got.RelativePath)')") { $pass++ }
		else { $fail.Add("path resolution: $($c.p)") }
	}

	foreach ($t in @(
			# findoid resolves this one wrong: `$path =~ /^$mountpoint/` is an
			# unanchored prefix match, so /home/os7admin matches /home/os7 and
			# every version of the file is looked for in the wrong dataset.
			@{ n = 'a name that is a string prefix of another does not steal the path'
			   c = ((Get-OS7PathDataset -Path '/home/os7admin/x' -Dataset $fake).Dataset -eq
			         'rpool/USERDATA/os7admin_2222') }
			# The mountpoint `/` is where findoid's regex splice fails and
			# produces a doubled slash that cannot be stat-ed.
			@{ n = 'a dataset mounted at / splices without a doubled slash'
			   c = ((Get-OS7PathDataset -Path '/etc/hostname' -Dataset $fake).RelativePath -eq
			         'etc/hostname') }
			# Two datasets, one mountpoint: a repair install. The mounted one
			# wins, and the unmounted one is still visible to the caller rather
			# than filtered away before it can be reported.
			@{ n = 'a repair installs unmounted twin does not win the mountpoint'
			   c = ((Get-OS7PathDataset -Path '/home/os7/x' -Dataset $fake).Dataset -eq
			         'rpool/USERDATA/os7_1111') }
			@{ n = 'a legacy mountpoint is not treated as a path'
			   c = ($null -eq (Get-OS7PathDataset -Path 'legacy/x' -Dataset $fake)) }
			@{ n = 'a path outside every dataset resolves to nothing'
			   c = ($null -eq (Get-OS7PathDataset -Path '/boot/efi/EFI/BOOT' -Dataset @(
			         [pscustomobject]@{ Name = 'x'; Mountpoint = '/srv'; Mounted = $true }))) }
		)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

	# -----------------------------------------------------------------------
	# 4. The disk guard, against a fabricated /sys
	# -----------------------------------------------------------------------
	#
	# /sys/class/block is a directory of symlinks and a couple of files, so the
	# tree walk that decides "which disks is this pool on" can be checked
	# against a fake one. That is what makes the guard testable at all: the
	# alternative is a machine with a spare disk in it.
	$sys = Join-Path ([System.IO.Path]::GetTempPath()) ("os7-sys-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
	try {
		# sda: a system disk, sda1..sda3, with sda3 carrying LUKS -> dm-0
		# sdb: a bare spare disk
		# NO SYMLINKS. Creating one needs a privilege Windows does not grant by
		# default, and a test that only runs on the developer's machine is a
		# test that stops being run. The walk was written to answer from the
		# containment relationship as well as from the link, precisely so that
		# this tree can be plain directories — and the containment relationship
		# is true of the real /sys too.
		foreach ($d in @('sda', 'sdb')) { New-Item -ItemType Directory -Force -Path (Join-Path $sys $d) | Out-Null }
		foreach ($p in @('sda1', 'sda2', 'sda3')) {
			foreach ($dir in @((Join-Path (Join-Path $sys 'sda') $p), (Join-Path $sys $p))) {
				New-Item -ItemType Directory -Force -Path $dir | Out-Null
				Set-Content -LiteralPath (Join-Path $dir 'partition') -Value '1'
			}
		}
		$dm = Join-Path $sys 'dm-0'
		New-Item -ItemType Directory -Force -Path (Join-Path $dm 'slaves/sda3') | Out-Null

		foreach ($t in @(
				@{ n = 'a whole disk resolves to itself'
				   c = (@(Get-OS7BaseDisk -Device 'sdb' -SysRoot $sys) -join ',') -eq 'sdb' }
				@{ n = 'a partition resolves to its disk'
				   c = (@(Get-OS7BaseDisk -Device 'sda2' -SysRoot $sys) -join ',') -eq 'sda' }
				@{ n = 'a LUKS mapper node resolves through its slave to the disk'
				   c = (@(Get-OS7BaseDisk -Device 'dm-0' -SysRoot $sys) -join ',') -eq 'sda' }
				@{ n = 'a full device path resolves the same as a bare kernel name'
				   c = (@(Get-OS7BaseDisk -Device '/dev/sda3' -SysRoot $sys) -join ',') -eq 'sda' }
				@{ n = 'a device that is not in /sys resolves to nothing'
				   c = (@(Get-OS7BaseDisk -Device 'sdz' -SysRoot $sys).Count -eq 0) }
			)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }
	}
	catch {
		[Console]::Error.WriteLine("  FAIL  the /sys walk threw: $($_.Exception.Message.Split("`n")[0])")
		$fail.Add('the /sys walk threw')
	}
	finally {
		Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $sys
	}

	# -----------------------------------------------------------------------
	# 5. The syncoid command line
	# -----------------------------------------------------------------------
	#
	# What a fixture CAN check about a replication is the command line, and on
	# this program the command line IS most of the risk: the difference between
	# a safe run and one that mounts a copy of /home over the live one is two
	# flags, and the difference between a resumable increment and a full send is
	# one more.
	$argsLocal = Get-OS7SyncoidArgument -TargetKind 'LocalPool' -TargetName 'usb' -ChildrenOnly $true
	$argsRemote = Get-OS7SyncoidArgument -TargetKind 'Remote' -TargetName 'nas' -ChildrenOnly $false -SshKey '/etc/os7/id'
	$joinL = $argsLocal -join ' '
	$joinR = $argsRemote -join ' '

	foreach ($t in @(
			@{ n = 'syncoid is told not to mount what it receives'
			   c = ($joinL -like '*--recvoptions=u*') }
			@{ n = 'a container is sent without its parent'
			   c = ($joinL -like '*--skip-parent*') }
			@{ n = 'a leaf dataset keeps its parent'
			   c = ($joinR -notlike '*--skip-parent*') }
			@{ n = 'the target name becomes the syncoid identifier'
			   c = ($joinL -like '*--identifier=usb*') }
			@{ n = 'a remote target gets BatchMode - a prompt in a oneshot is a hang'
			   c = ($joinR -like '*BatchMode=yes*') }
			@{ n = 'a remote target gets a connect timeout'
			   c = ($joinR -like '*ConnectTimeout=10*') }
			@{ n = 'a remote target checks the host key'
			   c = ($joinR -like '*StrictHostKeyChecking=yes*') }
			@{ n = 'the ssh key is passed when there is one'
			   c = ($joinR -like '*--sshkey=/etc/os7/id*') }
			@{ n = 'a local target does not get ssh options'
			   c = ($joinL -notlike '*BatchMode*') }
			@{ n = 'a local target skips the compressor probe'
			   c = ($joinL -like '*--compress=none*') }

			# The four that are deliberately absent, each with a reason in
			# Start-OS7BackupReplication. A future edit that adds one of these
			# should have to delete a test that says why not.
			@{ n = 'NOT --quiet: it silences the warnings that carry partial failure'
			   c = ($joinL -notlike '*--quiet*' -and $joinR -notlike '*--quiet*') }
			@{ n = 'NOT --no-sync-snap: the sync snapshot is the base retention cannot prune'
			   c = ($joinL -notlike '*--no-sync-snap*') }
			@{ n = 'NOT --use-hold: a forgotten target would leave an undestroyable snapshot'
			   c = ($joinL -notlike '*--use-hold*') }
			@{ n = 'NOT --preserve-properties: it would push mountpoint onto the target'
			   c = ($joinL -notlike '*--preserve-properties*') }
			@{ n = 'NOT --force-delete: destroying the target is an operator decision'
			   c = ($joinL -notlike '*--force-delete*' -and $joinR -notlike '*--force-delete*') }
			@{ n = 'NOT --no-stream: the default -I is what keeps every snapshot in between'
			   c = ($joinL -notlike '*--no-stream*') }
		)) { if (ok $t.n $t.c) { $pass++ } else { $fail.Add($t.n) } }

	# -----------------------------------------------------------------------
	# 6. Against this machine
	# -----------------------------------------------------------------------
	if ($Live) {
		[Console]::Error.WriteLine('  --- live ---')

		$sanoid = Test-Path -LiteralPath $script:OS7SanoidBin
		if (ok 'live: sanoid is installed' $sanoid) { $pass++ } else { $fail.Add('sanoid missing') }
		if (ok 'live: syncoid is installed' (Test-Path -LiteralPath $script:OS7SyncoidBin)) { $pass++ }
		else { $fail.Add('syncoid missing') }

		if ($sanoid) {
			# The legal-key list read from the file sanoid itself uses as its
			# list of allowable settings. If this is empty on a machine that has
			# sanoid, the defaults file moved and Assert-OS7SanoidKeys has
			# quietly stopped checking anything.
			$keys = @(Get-OS7SanoidKey)
			if (ok "live: $($keys.Count) settings read from sanoid's own defaults" ($keys.Count -ge 40)) { $pass++ }
			else { $fail.Add('sanoid defaults unreadable') }

			foreach ($k in @('hourly', 'daily', 'autoprune', 'recursive', 'process_children_only')) {
				if (ok "live: '$k' is a setting sanoid accepts" ($k -in $keys)) { $pass++ }
				else { $fail.Add("sanoid does not list $k") }
			}
			if (ok "live: 'version' is NOT a section setting (writing it is fatal)" (
					'version' -notin $keys)) { $pass++ }
			else { $fail.Add('version is listed as a setting') }

			# THE REAL CHECK: sanoid parses what OS/7 renders. Not a regex over
			# the file — the program that has to read it.
			if (ok 'live: sanoid parses the configuration OS/7 renders' (
					Test-OS7SanoidConf -Content $conf)) { $pass++ }
			else { $fail.Add('sanoid refused the rendered config') }
		}

		try {
			Import-OS7ZfsLayer
			$policy = Get-OS7BackupPolicy
			if (ok "live: the policy reads back ($($policy.Sources.Count) source(s))" (
					$policy.Sources.Count -ge 1)) { $pass++ }
			else { $fail.Add('live policy') }

			$status = Get-OS7BackupStatus -SkipTargets
			if (ok 'live: status answers without contacting a target' ($null -ne $status)) { $pass++ }
			else { $fail.Add('live status') }

			# Reported, not asserted. On a machine installed by os7-setup today
			# this is expected to find an uncovered home, and a self-test that
			# FAILED on it would be failing the machine for a bug in the
			# installer. docs/BACKUP-PLAN.md B-Q1 is where that is tracked.
			foreach ($u in @($status.Uncovered)) {
				[Console]::Error.WriteLine("  NOTE  $($u.Path): $($u.Reason)")
			}
		}
		catch {
			[Console]::Error.WriteLine("  FAIL  live: $($_.Exception.Message)")
			$fail.Add('live threw')
		}
	}

	[Console]::Error.WriteLine("`nOS/7 Backup self-test: $pass passed, $($fail.Count) failed")
	if ($fail.Count) {
		[Console]::Error.WriteLine('FAILED: ' + ($fail -join '; '))
		throw "OS/7 Backup self-test failed: $($fail.Count) check(s)"
	}
	[Console]::Error.WriteLine('OS/7 Backup self-test: PASS')
}
