#!/usr/bin/env python3
"""
The storage-pressure DECISIONS, against a fake pool. No ZFS, no snapshots, no VM.

    ./check-storage-logic.py

WHY IT EXISTS. docs/VERSIONS-PLAN.md §5 and BACKUP-PLAN.md BL5. The Versions
feature makes free space depend on a machine's history and makes users value
that history, so "and then what happens when it fills up" needs an answer that
is a rule rather than a habit. The rule, decided by the owner 2026-09-14:

    70 %  say so, delete nothing
    80 %  tighten the retention policy and let sanoid prune under it
    90 %  tighten to the floor, refuse, say so loudly

and two things guard it, both of which this file is mostly about:

  * THE EFFECTIVENESS GATE. A snapshot holds only the blocks it ALONE still
    needs. A pool that is 80 % full of LIVE data does not get better by
    deleting history — measured on a bench, `usedbysnapshots` was 1.9 MiB
    against 2.8 MiB live. So relief is refused when it cannot reach the target,
    because destructive AND ineffective is the worst outcome available.

  * THE BOOT ENVIRONMENT BEFORE THE LAST UPDATE IS NEVER PRUNED. A machine that
    freed space by deleting its own way back cannot recover from the update it
    made room for. The first version of that rule returned a List where the
    caller expected strings, so `-notcontains` never matched and the RUNNING
    environment came back prunable — caught on a machine, and case 4 here is
    what stops it coming back.

AND SINCE V8 IT ALSO OWNS THE OTHER DIRECTION — the one snapshot OS/7 takes of
its own accord. §7 and §8 are the restore's safety snapshot: taken only where
something is actually overwritten, on the DESTINATION's dataset rather than the
version's, announced in the confirmation prompt before it is answered, pruned
by OS/7 because nothing else will, and never, ever matching one of sanoid's.
Those two sections run against REAL FILES in a temporary directory with a fake
ZFS around them, so "the bytes landed" and "nothing was written" are read off a
filesystem rather than off a mock's call log.

WHAT THIS IS NOT. It says nothing about what ZFS reports; Get-ZfsPool's shape
was measured from a real `zpool list -j` and Test-ZfsModule checks the parsing.
This checks what OS/7's layer CONCLUDES from it.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
STORAGE = os.path.join(REPO, "powershell", "OS7", "OS7.Storage.ps1")
RESTORE = os.path.join(REPO, "powershell", "OS7", "OS7.BackupRestore.ps1")

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)


PRELUDE = r"""
$ErrorActionPreference = 'Stop'
. '{storage}'
. '{restore}'

# ---------------------------------------------------------------------------
# The fakes. Defined AFTER the dot-source on purpose: PowerShell resolves a
# call at invocation, so these shadow whatever the real module would supply.
# ---------------------------------------------------------------------------
$script:FakePool = $null
$script:FakeSpace = @()
$script:FakeEnvironments = @()
$script:FakeRetention = $null
$script:AppliedRetention = $null
$script:RemovedEnvironments = [System.Collections.Generic.List[string]]::new()

function Get-ZfsPool {{ param([string[]]$Name) $script:FakePool }}
function Get-ZfsSpace {{ param([string]$Name, [switch]$Recurse) $script:FakeSpace }}
function Get-ZfsSnapshot {{ param([string]$Name, [switch]$NoRecurse) @() }}
function Get-OS7BootEnvironment {{ $script:FakeEnvironments }}
function Format-ZfsSize {{ param($Bytes) "$Bytes bytes" }}
function Assert-OS7Elevated {{ param($Cmdlet, $Because) }}
function New-OS7BackupRetention {{ [ordered]@{{ frequently=0; hourly=24; daily=14; weekly=4; monthly=3; yearly=0 }} }}

function Get-OS7BackupPolicy {{
	param([switch]$ConfigOnly)
	[pscustomobject]@{{ Sources = @([pscustomobject]@{{
		Dataset = 'rpool/USERDATA'
		Retention = $script:FakeRetention
	}}) }}
}}

function Set-OS7BackupPolicy {{
	param([string[]]$Dataset, [System.Collections.IDictionary]$Retention,
	      [nullable[bool]]$Enabled, [switch]$Force)
	$script:AppliedRetention = $Retention
}}

function Remove-OS7BootEnvironment {{
	param([string]$Name)
	$script:RemovedEnvironments.Add($Name)
}}

function New-Environment {{
	param([string]$Name, [datetime]$Created, $Running, [int64]$Used)
	[pscustomobject]@{{ Name = $Name; Created = $Created; Running = $Running; Used = $Used }}
}}

function New-Pool {{
	param([int]$Capacity, [int64]$Size, [int64]$Allocated)
	[pscustomobject]@{{
		Name = 'rpool'; State = 'ONLINE'; Health = 'ONLINE'
		Size = $Size; Allocated = $Allocated; Free = ($Size - $Allocated)
		Capacity = $Capacity; Fragmentation = 0
	}}
}}
"""


def run(body, cases):
    """Run a PowerShell body that emits one JSON object, and report it."""
    script = PRELUDE.format(storage=STORAGE.replace("\\", "/"),
                            restore=RESTORE.replace("\\", "/")) + "\n" + body

    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False,
                                     encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name

    try:
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", path],
            capture_output=True, encoding="utf-8", errors="replace")
    finally:
        os.unlink(path)

    if result.returncode != 0:
        check(False, cases, (result.stderr or result.stdout).strip()[:300])
        return None

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        check(False, cases, (result.stdout or result.stderr).strip()[:300])
        return None


def run_text(body, cases):
    """The same, for a body whose output is the operator's screen and not JSON.

    `-WhatIf` writes through the HOST, not through a stream: it cannot be
    caught by -InformationVariable and `6>` does not redirect it. That is
    awkward here and is exactly why it is worth checking — it is the sentence
    a person reads before answering a confirmation prompt.
    """
    script = PRELUDE.format(storage=STORAGE.replace("\\", "/"),
                            restore=RESTORE.replace("\\", "/")) + "\n" + body

    with tempfile.NamedTemporaryFile("w", suffix=".ps1", delete=False,
                                     encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name

    try:
        result = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", path],
            capture_output=True, encoding="utf-8", errors="replace")
    finally:
        os.unlink(path)

    if result.returncode != 0:
        check(False, cases, (result.stderr or result.stdout).strip()[:300])
        return None

    return result.stdout


GIB = 1024 ** 3


def levels():
    print("  1. The level is read off the pool, and each one is a different sentence")

    body = r"""
$out = [ordered]@{}
foreach ($c in @(12, 69, 70, 79, 80, 89, 90, 99)) {
	$script:FakePool = New-Pool -Capacity $c -Size 100GB -Allocated ([int64](100GB * $c / 100))
	$script:FakeSpace = @([pscustomobject]@{ Name='rpool'; UsedBySnapshots=[int64]1GB })
	$script:FakeEnvironments = @(New-Environment -Name 'a' -Created (Get-Date) -Running $true -Used 1GB)
	$p = Get-OS7StoragePressure
	$out["$c"] = @{ level = $p.Level; target = $p.Target; reason = $p.Reason }
}
$out | ConvertTo-Json -Depth 4
"""
    got = run(body, "the levels can be read")
    if got is None:
        return

    check(got["12"]["level"] == "Normal", "12% is Normal")
    check(got["69"]["level"] == "Normal", "69% is still Normal — the boundary is not off by one")
    check(got["70"]["level"] == "Warn", "70% is Warn")
    check(got["79"]["level"] == "Warn", "79% is still Warn")
    check(got["80"]["level"] == "Tighten", "80% is Tighten")
    check(got["89"]["level"] == "Tighten", "89% is still Tighten")
    check(got["90"]["level"] == "Refuse", "90% is Refuse")
    check(got["99"]["level"] == "Refuse", "and so is 99%")

    # The four states say four different things. A machine that said the same
    # sentence at 12% and at 90% would be telling nobody anything.
    reasons = {got[k]["reason"] for k in ("12", "70", "80", "90")}
    check(len(reasons) == 4, "each level has its own sentence", f"{len(reasons)} distinct")

    check("Nothing is deleted at this level" in got["70"]["reason"],
          "and 70% says out loud that it deletes nothing")

    # It aims one step down, not at zero.
    check(got["80"]["target"] == 70, "Tighten aims to get back under Warn")
    check(got["90"]["target"] == 80, "Refuse aims to get back under Tighten")


def gate():
    print()
    print("  2. Relief is refused when it could not work")

    body = r"""
# 85% of 100 GiB: 85 allocated, target 70 -> 15 GiB must go.
$script:FakePool = New-Pool -Capacity 85 -Size 100GB -Allocated ([int64](85GB))
$script:FakeEnvironments = @(New-Environment -Name 'a' -Created (Get-Date) -Running $true -Used 1GB)
$script:FakeRetention = New-OS7BackupRetention

$out = [ordered]@{}

# Snapshots hold 2 GiB. Deleting everything cannot reach the target.
$script:FakeSpace = @([pscustomobject]@{ Name='rpool'; UsedBySnapshots=[int64]2GB })
$p = Get-OS7StoragePressure
$out['thin'] = @{ wouldHelp = $p.WouldHelp; reclaimable = $p.Reclaimable
                  needed = $p.BytesToRelieve; reason = $p.Reason }
$script:AppliedRetention = $null
$r = Invoke-OS7StorageRelief -Confirm:$false
$out['thinAction'] = @{ action = $r.Action; applied = ($null -ne $script:AppliedRetention)
                        removed = $script:RemovedEnvironments.Count }

# Snapshots hold 40 GiB. Now it can.
$script:FakeSpace = @([pscustomobject]@{ Name='rpool'; UsedBySnapshots=[int64]40GB })
$p2 = Get-OS7StoragePressure
$out['fat'] = @{ wouldHelp = $p2.WouldHelp }
$script:AppliedRetention = $null
$r2 = Invoke-OS7StorageRelief -Confirm:$false
$out['fatAction'] = @{ action = $r2.Action; applied = ($null -ne $script:AppliedRetention) }

# -Force overrides the gate for an operator who has read why.
$script:FakeSpace = @([pscustomobject]@{ Name='rpool'; UsedBySnapshots=[int64]2GB })
$script:AppliedRetention = $null
$r3 = Invoke-OS7StorageRelief -Force -Confirm:$false
$out['forced'] = @{ action = $r3.Action; applied = ($null -ne $script:AppliedRetention) }

# At Refuse every byte counts, so it acts whether or not it suffices.
$script:FakePool = New-Pool -Capacity 95 -Size 100GB -Allocated ([int64](95GB))
$script:AppliedRetention = $null
$r4 = Invoke-OS7StorageRelief -Confirm:$false
$out['refuse'] = @{ action = $r4.Action; applied = ($null -ne $script:AppliedRetention)
                    wouldHelp = $r4.WouldHelp }

$out | ConvertTo-Json -Depth 4
"""
    got = run(body, "the effectiveness gate can be read")
    if got is None:
        return

    check(got["thin"]["wouldHelp"] is False,
          "2 GiB of snapshots cannot relieve a 15 GiB shortfall",
          f"reclaimable {got['thin']['reclaimable']} vs needed {got['thin']['needed']}")

    check(got["thinAction"]["action"] == "Reported",
          "so the action is to REPORT, not to delete")
    check(got["thinAction"]["applied"] is False,
          "and the retention policy is not touched")
    check(got["thinAction"]["removed"] == 0,
          "and no boot environment is removed")
    check("live data is what is full" in got["thin"]["reason"],
          "and the reason names the actual problem")

    check(got["fat"]["wouldHelp"] is True,
          "40 GiB of snapshots CAN relieve it")
    check(got["fatAction"]["action"] == "Tightened",
          "so the policy is tightened")
    check(got["fatAction"]["applied"] is True,
          "and sanoid is the one that will do the deleting")

    check(got["forced"]["action"] == "Tightened" and got["forced"]["applied"] is True,
          "-Force acts anyway, for an operator who has read why it will not be enough")

    check(got["refuse"]["action"] == "Emergency" and got["refuse"]["applied"] is True,
          "at Refuse it acts whether or not it suffices — every byte counts there")


def tightening():
    print()
    print("  3. Tightening only ever tightens, and never below the floor")

    body = r"""
$script:FakePool = New-Pool -Capacity 85 -Size 100GB -Allocated ([int64](85GB))
$script:FakeSpace = @([pscustomobject]@{ Name='rpool'; UsedBySnapshots=[int64]40GB })
$script:FakeEnvironments = @(New-Environment -Name 'a' -Created (Get-Date) -Running $true -Used 1GB)

$out = [ordered]@{}

# From the shipped defaults.
$script:FakeRetention = New-OS7BackupRetention
$script:AppliedRetention = $null
Invoke-OS7StorageRelief -Confirm:$false | Out-Null
$out['fromDefaults'] = $script:AppliedRetention

# An operator who already keeps less must KEEP less.
$script:FakeRetention = [ordered]@{ frequently=0; hourly=6; daily=3; weekly=1; monthly=0; yearly=0 }
$script:AppliedRetention = $null
Invoke-OS7StorageRelief -Confirm:$false | Out-Null
$out['fromStricter'] = $script:AppliedRetention

# Twice in a row changes nothing the second time.
$script:FakeRetention = New-OS7BackupRetention
$script:AppliedRetention = $null
Invoke-OS7StorageRelief -Confirm:$false | Out-Null
$first = $script:AppliedRetention
$script:FakeRetention = $first
$script:AppliedRetention = $null
Invoke-OS7StorageRelief -Confirm:$false | Out-Null
$out['idempotent'] = @{ first = $first; second = $script:AppliedRetention }

# At Refuse it goes to the floor.
$script:FakePool = New-Pool -Capacity 95 -Size 100GB -Allocated ([int64](95GB))
$script:FakeRetention = New-OS7BackupRetention
$script:AppliedRetention = $null
Invoke-OS7StorageRelief -Confirm:$false | Out-Null
$out['floor'] = $script:AppliedRetention

$out['thresholds'] = Get-OS7StorageThreshold | Select-Object Warn, Tighten, Refuse
$out | ConvertTo-Json -Depth 4
"""
    got = run(body, "the tightened retention can be read")
    if got is None:
        return

    d = got["fromDefaults"]
    check(d["hourly"] == 24, "a day by the hour survives tightening")
    check(d["daily"] == 7, "a week by the day survives")
    check(d["weekly"] == 2 and d["monthly"] == 1,
          "the coarse buckets are what shrink", f"weekly={d['weekly']} monthly={d['monthly']}")

    s = got["fromStricter"]
    check(s["hourly"] == 6 and s["daily"] == 3 and s["weekly"] == 1,
          "an operator who keeps LESS is not quietly given more back")

    check(got["idempotent"]["first"] == got["idempotent"]["second"],
          "running it twice changes nothing the second time — it is a target, not a step")

    f = got["floor"]
    check(f["hourly"] == 24 and f["daily"] == 7,
          "even the floor keeps a day by the hour and a week by the day")
    check(f["weekly"] == 0 and f["monthly"] == 0,
          "and drops the coarse buckets entirely")


def protection():
    print()
    print("  4. The way back is never pruned")

    body = r"""
$now = Get-Date
$script:FakePool = New-Pool -Capacity 95 -Size 100GB -Allocated ([int64](95GB))
$script:FakeSpace = @([pscustomobject]@{ Name='rpool'; UsedBySnapshots=[int64]1GB })
$script:FakeRetention = New-OS7BackupRetention

$out = [ordered]@{}

# Four environments; the newest is running. Protected: it and its predecessor.
$script:FakeEnvironments = @(
	New-Environment -Name 'be4' -Created $now.AddDays(-1) -Running $true  -Used 4GB
	New-Environment -Name 'be3' -Created $now.AddDays(-9) -Running $false -Used 3GB
	New-Environment -Name 'be2' -Created $now.AddDays(-20) -Running $false -Used 2GB
	New-Environment -Name 'be1' -Created $now.AddDays(-40) -Running $false -Used 1GB
)
$p = Get-OS7StoragePressure
$out['four'] = @{ protected = @($p.ProtectedEnvironments)
                  prunable  = @($p.PrunableEnvironments)
                  beBytes   = $p.BootEnvironmentBytes }

$script:RemovedEnvironments.Clear()
Invoke-OS7StorageRelief -Confirm:$false | Out-Null
$out['removed'] = @($script:RemovedEnvironments)

# An older environment is running: the way back is the newest one OLDER than it.
$script:FakeEnvironments = @(
	New-Environment -Name 'newer' -Created $now.AddDays(-1) -Running $false -Used 4GB
	New-Environment -Name 'running' -Created $now.AddDays(-9) -Running $true -Used 3GB
	New-Environment -Name 'older' -Created $now.AddDays(-20) -Running $false -Used 2GB
)
$p2 = Get-OS7StoragePressure
$out['rolledBack'] = @{ protected = @($p2.ProtectedEnvironments)
                        prunable  = @($p2.PrunableEnvironments) }

# Nothing says it is running: protect EVERYTHING rather than choose.
$script:FakeEnvironments = @(
	New-Environment -Name 'x' -Created $now.AddDays(-1) -Running $null -Used 1GB
	New-Environment -Name 'y' -Created $now.AddDays(-9) -Running $null -Used 1GB
)
$p3 = Get-OS7StoragePressure
$out['unknown'] = @{ protected = @($p3.ProtectedEnvironments)
                     prunable  = @($p3.PrunableEnvironments) }

# One environment, which is the ordinary case on a fresh machine.
$script:FakeEnvironments = @(
	New-Environment -Name 'only' -Created $now -Running $true -Used 1GB
)
$p4 = Get-OS7StoragePressure
$out['single'] = @{ protected = @($p4.ProtectedEnvironments)
                    prunable  = @($p4.PrunableEnvironments)
                    beBytes   = $p4.BootEnvironmentBytes }

$out | ConvertTo-Json -Depth 4
"""
    got = run(body, "the protection rule can be read")
    if got is None:
        return

    four = got["four"]
    check(set(four["protected"]) == {"be4", "be3"},
          "the running environment and the one before it are protected",
          ", ".join(four["protected"]))
    check(set(four["prunable"]) == {"be2", "be1"},
          "and only the older spares are prunable", ", ".join(four["prunable"]))

    # THE ONE THAT COST A MACHINE RUN.
    check(not set(four["protected"]) & set(four["prunable"]),
          "nothing is BOTH protected and prunable")
    check("be4" not in four["prunable"],
          "and the RUNNING environment is never prunable")

    check(four["beBytes"] == 3 * 1024 ** 3,
          "only the prunable ones count as reclaimable space",
          f"{four['beBytes']}")

    removed = got["removed"]
    check("be4" not in removed and "be3" not in removed,
          "relief removes neither the running environment nor the way back",
          ", ".join(removed))
    check(set(removed) == {"be2", "be1"},
          "and does remove the spares", ", ".join(removed))

    rolled = got["rolledBack"]
    check(set(rolled["protected"]) == {"running", "older"},
          "after a rollback the way back is the newest one OLDER than the running one",
          ", ".join(rolled["protected"]))
    check(rolled["prunable"] == ["newer"],
          "and the environment it was rolled back FROM becomes prunable")

    unknown = got["unknown"]
    check(len(unknown["prunable"]) == 0,
          "when nothing says it is running, everything is protected")
    check(set(unknown["protected"]) == {"x", "y"},
          "because refusing to prune what cannot be reasoned about is the safe direction")

    single = got["single"]
    check(single["prunable"] == [] and single["beBytes"] == 0,
          "one environment on a fresh machine is protected and prunes to nothing")



def ownership():
    print()
    print("  5. A path is owned by what is actually MOUNTED there")

    # MEASURED ON A MACHINE, 2026-09-14: Get-OS7FileVersion /proc/cpuinfo
    # returned zero versions in silence, because / is a ZFS boot environment
    # and every pseudo-filesystem is "under" it by path. The refusal it should
    # have given is written and correct and was simply unreachable. A guard
    # that cannot fire is not a guard.
    body = r"""
$info = [System.IO.Path]::GetTempFileName()
@(
	'1 0 0:1 / / rw - zfs rpool/ROOT/os7 rw'
	'2 1 0:2 / /proc rw - proc proc rw'
	'3 1 0:3 / /dev rw - devtmpfs udev rw'
	'4 1 0:4 / /home/os7admin rw shared:1 master:2 - zfs rpool/USERDATA/os7admin_a1 rw'
	'5 1 0:5 / /home/os7admin/media rw - vfat /dev/sdb1 rw'
	'6 1 0:6 / /home/a\040b rw - zfs rpool/USERDATA/spaced rw'
) | Set-Content -Path $info -Encoding utf8

$out = [ordered]@{}
foreach ($p in @('/etc/hostname', '/proc/cpuinfo', '/dev/null',
                 '/home/os7admin/notes.txt', '/home/os7admin/media/x.jpg',
                 '/home/os7admin2/secret.txt', '/home/a b/c.txt', '/nowhere/at/all')) {
	$m = Get-OS7PathMount -Path $p -MountInfo $info
	$out[$p] = if ($null -eq $m) { $null } else { @{ point = $m.MountPoint; type = $m.FsType } }
}
Remove-Item $info -Force
$out | ConvertTo-Json -Depth 4
"""
    got = run(body, "the mount table can be read")
    if got is None:
        return

    check(got["/etc/hostname"]["type"] == "zfs" and got["/etc/hostname"]["point"] == "/",
          "a file on the root dataset is owned by /")

    # The two that were silently wrong.
    check(got["/proc/cpuinfo"]["type"] == "proc",
          "/proc/cpuinfo is on procfs, not on the boot environment")
    check(got["/dev/null"]["type"] == "devtmpfs",
          "/dev/null is on devtmpfs, not on the boot environment")

    check(got["/home/os7admin/notes.txt"]["point"] == "/home/os7admin",
          "the LONGEST mount wins, not the first")
    check(got["/home/os7admin/media/x.jpg"]["type"] == "vfat",
          "a USB stick mounted inside a home is not part of that home")

    # /home/os7admin2 starts with /home/os7admin and is another account.
    check(got["/home/os7admin2/secret.txt"]["point"] == "/",
          "a longer NAME is not a deeper PATH")

    # Optional fields between the mount point and the separator, and an octal
    # escape: both are formats the kernel writes and a split would get wrong.
    check(got["/home/a b/c.txt"]["point"] == "/home/a b",
          "an octal-escaped space in a mount point is decoded")

    check(got["/nowhere/at/all"]["point"] == "/",
          "a path that exists nowhere still resolves to the root mount")


def boundary():
    print()
    print("  6. A run collapses to the version NEAREST the change")

    # Owner's decision 2026-09-14: the "did not exist" boundary stays, because
    # "when did this appear" is a question a Time-Machine window is opened to
    # answer. Which member of an absent run to keep is then the whole design:
    # the NEWEST one brackets the creation to an hour, the oldest to three
    # months.
    body = r"""
function V { param([string]$n, $exists, $len, $mod)
	[pscustomobject]@{ SnapshotName = $n; Exists = $exists; Length = $len; Modified = $mod } }

$out = [ordered]@{}

# Oldest first, as Get-OS7FileVersion builds them. Thirty absent, then three
# contents, then a run of the newest repeated.
$v = @(
	V 'a1' $false $null $null
	V 'a2' $false $null $null
	V 'a3' $false $null $null
	V 'p1' $true  24 '2026-09-14T20:39:02'
	V 'p2' $true  50 '2026-09-14T20:39:03'
	V 'p3' $true  77 '2026-09-14T20:39:05'
	V 'p4' $true  77 '2026-09-14T20:39:05'
	V 'p5' $true  77 '2026-09-14T20:39:05'
)
$out['mixed'] = @(Select-OS7DistinctVersion -Version $v | ForEach-Object { $_.SnapshotName })

# A file that changes and changes BACK: both runs are real.
$there = @(
	V 'b1' $true 10 'm1'
	V 'b2' $true 20 'm2'
	V 'b3' $true 10 'm1'
)
$out['thereAndBack'] = @(Select-OS7DistinctVersion -Version $there |
	ForEach-Object { $_.SnapshotName })

# Deleted at the end: the absent run is newest, and its newest member is the
# last snapshot of all.
$deleted = @(
	V 'c1' $true 10 'm1'
	V 'c2' $false $null $null
	V 'c3' $false $null $null
)
$out['deleted'] = @(Select-OS7DistinctVersion -Version $deleted |
	ForEach-Object { $_.SnapshotName })

$out['empty'] = @(Select-OS7DistinctVersion -Version @()).Count
$out['one'] = @(Select-OS7DistinctVersion -Version @(V 'only' $true 1 'm')).Count

$out | ConvertTo-Json -Depth 4
"""
    got = run(body, "the collapsing rule can be read")
    if got is None:
        return

    mixed = got["mixed"]
    check(mixed == ["a3", "p1", "p2", "p3"],
          "an absent run keeps its NEWEST and a present run its OLDEST",
          ", ".join(mixed))
    check(mixed[0] == "a3",
          "so the boundary brackets the creation as tightly as the snapshots allow")
    check("a1" not in mixed,
          "and not the beginning of history, which would be true and useless")
    check(mixed[-1] == "p3",
          "the newest content is reported at the snapshot where it first appeared")

    check(got["thereAndBack"] == ["b1", "b2", "b3"],
          "a file that changes and changes BACK is three versions, not two",
          ", ".join(got["thereAndBack"]))

    check(got["deleted"] == ["c1", "c3"],
          "a file deleted at the end keeps the last snapshot as the boundary",
          ", ".join(got["deleted"]))

    check(got["empty"] == 0, "no versions collapse to no rows")
    check(got["one"] == 1, "one version collapses to itself")

SAFETY_FAKES = r"""
function N { param([string]$p) $p -replace '\\', '/' }

$script:Snapshots = [System.Collections.Generic.List[object]]::new()
$script:Created   = [System.Collections.Generic.List[string]]::new()
$script:Removed   = [System.Collections.Generic.List[string]]::new()
$script:DatasetFor = @{}
$script:SnapshotVanishes = $false
$script:SnapshotDenied = $false
$script:OldFile = $null

function New-Snap {
	param([string]$Dataset, [string]$Name, [datetime]$Created)
	[pscustomobject]@{
		Name = "$Dataset@$Name"; Dataset = $Dataset
		SnapshotName = $Name; Creation = $Created }
}

# The mount table, as a prefix map. Longest wins, the way the real one does.
function Get-OS7PathDataset {
	param([string]$Path, [object[]]$Dataset)
	$p = N $Path
	foreach ($prefix in ($script:DatasetFor.Keys | Sort-Object { $_.Length } -Descending)) {
		if ($p -eq $prefix -or $p.StartsWith($prefix + '/')) {
			return [pscustomobject]@{
				Dataset = $script:DatasetFor[$prefix]
				Mountpoint = $prefix
				RelativePath = $p.Substring($prefix.Length).TrimStart('/')
			}
		}
	}
	$null
}

function Get-ZfsSnapshot {
	param([string]$Name, [switch]$NoRecurse)
	@($script:Snapshots | Where-Object { $_.Dataset -eq $Name })
}

function New-ZfsSnapshot {
	[CmdletBinding(SupportsShouldProcess)]
	param([string]$Name, [string]$SnapshotName, [switch]$Recurse,
		[System.Collections.IDictionary]$Property)
	$script:Created.Add("$Name@$SnapshotName")
	# What an unprivileged owner gets on a real machine, word for word (M-V20).
	if ($script:SnapshotDenied) {
		throw [System.InvalidOperationException]::new(
			"zfs snapshot $Name@$SnapshotName`nexited 1`ncannot create snapshots : permission denied")
	}
	# SnapshotVanishes is `zfs snapshot` exiting 0 having done nothing — the
	# failure shape docs/BUILD-NOTES.md keeps finding. The restore must not
	# write a byte on the strength of an exit code.
	if (-not $script:SnapshotVanishes) {
		$script:Snapshots.Add((New-Snap $Name $SnapshotName (Get-Date)))
	}
}

function Remove-ZfsSnapshot {
	[CmdletBinding(SupportsShouldProcess)]
	param([string]$Name, [switch]$Recurse)
	$script:Removed.Add($Name)
	$keep = @($script:Snapshots | Where-Object { $_.Name -ne $Name })
	$script:Snapshots.Clear()
	foreach ($k in $keep) { $script:Snapshots.Add($k) }
}

function Write-OS7Step { param([string]$Message) }

# rsync, doing the one thing the restore relies on it for: the bytes land.
function Invoke-OS7Native {
	param([string]$Command, [string[]]$Arguments)
	Copy-Item -LiteralPath $Arguments[-2] -Destination $Arguments[-1] -Recurse -Force
}

function Get-OS7FileVersion {
	param([string]$Path, [string]$Snapshot, [switch]$IncludeCurrent,
		[switch]$IncludeAbsent, [switch]$DistinctOnly, [switch]$AsArray)
	# ONE version, and it comes out of the SOURCE's dataset — which is
	# deliberately not the dataset every destination below is on.
	@([pscustomobject]@{
		Path = $Path
		SnapshotName = 'autosnap_2026-09-14_18:00:02_hourly'
		Snapshot = 'rpool/USERDATA/alice@autosnap_2026-09-14_18:00:02_hourly'
		Created = [datetime]'2026-09-14T18:00:02'
		Length = 9
		IsFolder = $false
		Exists = $true
		SnapshotPath = $script:OldFile
	})
}

$script:Root = N (Join-Path ([System.IO.Path]::GetTempPath()) ("os7v8-" + [guid]::NewGuid().ToString('N')))
$script:SnapDir = "$script:Root/snap"
$script:LiveDir = "$script:Root/live"
$script:OtherDir = "$script:Root/other"
New-Item -ItemType Directory -Force -Path $script:SnapDir, $script:LiveDir, $script:OtherDir | Out-Null

# Nine bytes: 'yesterday'. The length matters — Restore-OS7File stats the
# result and compares it with the version's, so a copy that did not happen is
# a failure here rather than a green check.
$script:OldFile = "$script:SnapDir/notes.txt"
Set-Content -LiteralPath $script:OldFile -Value 'yesterday' -NoNewline
$script:Live = "$script:LiveDir/notes.txt"
"""


def safety():
    print()
    print("  7. A restore that overwrites something is itself undoable")

    # docs/VERSIONS-PLAN.md V8. The snapshot is what stops the feature whose
    # whole purpose is "you can go back" from containing a one-way door.
    body = SAFETY_FAKES + r"""
$out = [ordered]@{}
$script:DatasetFor = @{ $script:LiveDir = 'rpool/USERDATA/alice' }

# --- A: a destination that is not there yet takes nothing away -------------
$fresh = "$script:LiveDir/fresh.txt"
$r = Restore-OS7File -Path $script:Live -Destination $fresh
$out['freshSnapshot'] = $r.SafetySnapshot
$out['freshCreated'] = @($script:Created).Count
$out['freshBytes'] = Get-Content -LiteralPath $fresh -Raw

# --- B: in place, over work that exists ------------------------------------
$script:Created.Clear()
Set-Content -LiteralPath $script:Live -Value 'today, which is work' -NoNewline
$r = Restore-OS7File -Path $script:Live -Force
$out['inPlaceSnapshot'] = $r.SafetySnapshot
$out['inPlaceCreated'] = @($script:Created)
$out['inPlaceBytes'] = Get-Content -LiteralPath $script:Live -Raw

# --- C: the DESTINATION's dataset, not the source's ------------------------
$script:DatasetFor = @{
	$script:LiveDir = 'rpool/USERDATA/alice'
	$script:OtherDir = 'rpool/DATA/shared'
}
$victim = "$script:OtherDir/notes.txt"
Set-Content -LiteralPath $victim -Value 'somebody elses work' -NoNewline
$script:Created.Clear()
$r = Restore-OS7File -Path $script:Live -Destination $victim -Force
$out['crossSnapshot'] = $r.SafetySnapshot

# --- D: the named way to give it up ----------------------------------------
$script:Created.Clear()
Set-Content -LiteralPath $script:Live -Value 'work again' -NoNewline
$r = Restore-OS7File -Path $script:Live -Force -NoSafetySnapshot
$out['optedOutSnapshot'] = $r.SafetySnapshot
$out['optedOutCreated'] = @($script:Created).Count
$out['optedOutBytes'] = Get-Content -LiteralPath $script:Live -Raw

# --- E: it prunes its own, and only its own --------------------------------
$script:Snapshots.Clear(); $script:Created.Clear(); $script:Removed.Clear()
1..7 | ForEach-Object {
	$script:Snapshots.Add((New-Snap 'rpool/USERDATA/alice' `
		("os7-before-restore-2026090$_-120000") ([datetime]'2026-09-01').AddDays($_)))
}
# sanoid's, and OLDER than every one of ours.
$script:Snapshots.Add((New-Snap 'rpool/USERDATA/alice' `
	'autosnap_2026-08-01_00:00:00_monthly' ([datetime]'2026-08-01')))
$script:Snapshots.Add((New-Snap 'rpool/USERDATA/alice' `
	'autosnap_2026-08-02_00:00:00_daily' ([datetime]'2026-08-02')))
# and another dataset's safety snapshot, which is not this one's business.
$script:Snapshots.Add((New-Snap 'rpool/DATA/shared' `
	'os7-before-restore-20260101-000000' ([datetime]'2026-01-01')))

Set-Content -LiteralPath $script:Live -Value 'more work' -NoNewline
$r = Restore-OS7File -Path $script:Live -Force
$out['pruneRemoved'] = @($script:Removed)
$out['pruneLeftMine'] = @($script:Snapshots |
	Where-Object { $_.Dataset -eq 'rpool/USERDATA/alice' } |
	Sort-Object Creation | ForEach-Object { $_.SnapshotName })
$out['pruneLeftOther'] = @($script:Snapshots |
	Where-Object { $_.Dataset -eq 'rpool/DATA/shared' } |
	ForEach-Object { $_.SnapshotName })

# --- F: a destination ZFS does not own -------------------------------------
$script:DatasetFor = @{}
$script:Created.Clear()
Set-Content -LiteralPath $script:Live -Value 'on a usb stick' -NoNewline
$w = $null
$r = Restore-OS7File -Path $script:Live -Force -WarningVariable w -WarningAction SilentlyContinue
$out['noZfsSnapshot'] = $r.SafetySnapshot
$out['noZfsCreated'] = @($script:Created).Count
$out['noZfsWarning'] = (@($w | ForEach-Object { [string]$_ }) -join ' ')
$out['noZfsBytes'] = Get-Content -LiteralPath $script:Live -Raw

# --- G: asked for, and not there -------------------------------------------
$script:DatasetFor = @{ $script:LiveDir = 'rpool/USERDATA/alice' }
$script:SnapshotVanishes = $true
Set-Content -LiteralPath $script:Live -Value 'precious' -NoNewline
$out['vanishError'] = ''
try { Restore-OS7File -Path $script:Live -Force | Out-Null }
catch { $out['vanishError'] = $_.Exception.Message }
$out['vanishBytes'] = Get-Content -LiteralPath $script:Live -Raw
$script:SnapshotVanishes = $false

# --- H: many files, one invocation, ONE snapshot ---------------------------
$script:Snapshots.Clear(); $script:Created.Clear(); $script:Removed.Clear()
$a = "$script:LiveDir/a.txt"
$b = "$script:LiveDir/b.txt"
Set-Content -LiteralPath $a -Value 'work a' -NoNewline
Set-Content -LiteralPath $b -Value 'work b' -NoNewline
$rs = @(@([pscustomobject]@{ FullName = $a }, [pscustomobject]@{ FullName = $b }) |
	Restore-OS7File -Force)
$out['pipelineCreated'] = @($script:Created).Count
$out['pipelineSnapshots'] = @($rs | ForEach-Object { $_.SafetySnapshot })
$out['pipelineBytes'] = @((Get-Content -LiteralPath $a -Raw), (Get-Content -LiteralPath $b -Raw))

# --- I: the owner, without privilege ---------------------------------------
# Measured on a machine (M-V20): reading a version needs no privilege and
# `zfs snapshot` needs root, so this is the COMMON case, not a broken pool.
$script:SnapshotDenied = $true
Set-Content -LiteralPath $script:Live -Value 'the users own work' -NoNewline
$out['deniedError'] = ''
try { Restore-OS7File -Path $script:Live -Force | Out-Null }
catch { $out['deniedError'] = $_.Exception.Message }
$out['deniedBytes'] = Get-Content -LiteralPath $script:Live -Raw

$r = Restore-OS7File -Path $script:Live -Force -NoSafetySnapshot
$out['deniedOptOut'] = Get-Content -LiteralPath $script:Live -Raw
$script:SnapshotDenied = $false

Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
$out | ConvertTo-Json -Depth 4
"""
    got = run(body, "the safety snapshot can be exercised")
    if got is None:
        return

    check(got["freshSnapshot"] is None,
          "restoring to a path that does not exist takes no snapshot")
    check(got["freshCreated"] == 0,
          "and asks ZFS for nothing — a snapshot per restore would be a row in "
          "every later listing, for nothing")
    check(got["freshBytes"] == "yesterday", "the restore itself still happens")

    made = got["inPlaceCreated"]
    check(got["inPlaceSnapshot"] is not None and len(made) == 1,
          "restoring over a file that exists snapshots it first")
    check(str(got["inPlaceSnapshot"]).startswith("rpool/USERDATA/alice@os7-before-restore-"),
          "and the snapshot is named for what it is", str(got["inPlaceSnapshot"]))
    check(got["inPlaceBytes"] == "yesterday",
          "the overwrite happened — the snapshot is the way back, not a refusal")
    check(str(got["inPlaceSnapshot"]).split("@")[-1][len("os7-before-restore-"):]
          .replace("-", "").isdigit(),
          "and carries the moment it was taken, so it can be told from the next one")

    check(str(got["crossSnapshot"]).startswith("rpool/DATA/shared@"),
          "the DESTINATION's dataset is snapshotted, not the version's",
          str(got["crossSnapshot"]))

    check(got["optedOutSnapshot"] is None and got["optedOutCreated"] == 0,
          "-NoSafetySnapshot is the named way to give the way back up")
    check(got["optedOutBytes"] == "yesterday",
          "and it still restores")

    removed = got["pruneRemoved"]
    left = got["pruneLeftMine"]
    check(len(removed) == 3,
          "eight safety snapshots and a keep of five leaves three to remove",
          f"{len(removed)}: {', '.join(removed)}")
    check(all("os7-before-restore-2026090" in r for r in removed),
          "and the three removed are the OLDEST of ours", ", ".join(removed))
    check(not any("autosnap" in r for r in removed),
          "SANOID'S SNAPSHOTS ARE NEVER TOUCHED, however old — a prune that "
          "matched everything would be the data loss this feature exists to "
          "prevent")
    check(sum(1 for s in left if s.startswith("autosnap")) == 2,
          "both of sanoid's are still there afterwards")
    check(sum(1 for s in left if s.startswith("os7-before-restore-")) == 5,
          "and exactly five of ours, whatever the machine's history",
          str(sum(1 for s in left if s.startswith("os7-before-restore-"))))
    check(got["pruneLeftOther"] == ["os7-before-restore-20260101-000000"],
          "another dataset's safety snapshot is not this restore's business")

    check(got["noZfsSnapshot"] is None and got["noZfsCreated"] == 0,
          "a destination ZFS does not own cannot be snapshotted")
    check("ZFS" in got["noZfsWarning"] and "no way back" in got["noZfsWarning"],
          "and the operator is told that, rather than left to assume there is "
          "a way back", got["noZfsWarning"][:90])
    check(got["noZfsBytes"] == "yesterday",
          "restoring onto a USB stick is legitimate and is not refused")

    check("os7-before-restore-" in got["vanishError"],
          "a snapshot that was requested and is not there stops the restore",
          got["vanishError"][:90])
    check("-NoSafetySnapshot" in got["vanishError"],
          "and the message names the way past it")
    check(got["vanishBytes"] == "precious",
          "AND NOTHING WAS WRITTEN — `zfs snapshot` exiting 0 is a diagnostic, "
          "and the file is the evidence")

    snaps = got["pipelineSnapshots"]
    check(got["pipelineCreated"] == 1,
          "two files restored in one invocation take ONE snapshot of the dataset",
          str(got["pipelineCreated"]))
    check(len(snaps) == 2 and snaps[0] == snaps[1] and snaps[0] is not None,
          "and both are told the same way back, because that snapshot predates "
          "both writes", str(snaps))
    check(got["pipelineBytes"] == ["yesterday", "yesterday"],
          "and both files were actually restored")

    denied = got["deniedError"]
    check("sudo pwsh -NoProfile -c" in denied,
          "an owner who cannot snapshot is told to elevate, in #148's form",
          denied.splitlines()[0][:80] if denied else "(no error)")
    check("-NoSafetySnapshot" in denied,
          "and told the other road, which is to give the way back up on purpose")
    check("nothing is lost" in denied,
          "and told the file is still there — the sentence a person needs first")
    check("permission denied" in denied,
          "with ZFS's own words kept, because they say WHY")
    check(got["deniedBytes"] == "the users own work",
          "AND THE FILE IS UNTOUCHED: a restore that could not be made undoable "
          "is not performed")
    check(got["deniedOptOut"] == "yesterday",
          "-NoSafetySnapshot is the road, and it works")


def confirmation():
    print()
    print("  8. The prompt says whether this can be undone, BEFORE it is answered")

    # -WhatIf renders exactly the sentence a -Confirm prompt shows, and it goes
    # to the host rather than to a stream, which is why this case is read as
    # text instead of as JSON.
    body = SAFETY_FAKES + r"""
$script:DatasetFor = @{ $script:LiveDir = 'rpool/USERDATA/alice' }
Set-Content -LiteralPath $script:Live -Value 'today, which is work' -NoNewline

'--- overwriting ---'
Restore-OS7File -Path $script:Live -Force -WhatIf
'--- new path ---'
Restore-OS7File -Path $script:Live -Destination "$script:LiveDir/fresh.txt" -WhatIf
'--- created: ' + @($script:Created).Count
'--- bytes: ' + (Get-Content -LiteralPath $script:Live -Raw)
Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
"""
    text = run_text(body, "the confirmation text can be read")
    if text is None:
        return

    overwriting = text.split("--- overwriting ---")[-1].split("--- new path ---")[0]
    fresh = text.split("--- new path ---")[-1].split("--- created:")[0]

    check("snapshotting" in overwriting and "undone" in overwriting,
          "overwriting a file says a snapshot is taken first, in the prompt",
          overwriting.strip()[:110])
    check("snapshotting" not in fresh,
          "and a restore that overwrites nothing does not promise one",
          fresh.strip()[:110])
    check("--- created: 0" in text,
          "-WhatIf takes no snapshot either — ShouldProcess answers first")
    check("--- bytes: today, which is work" in text,
          "and writes nothing")


def main():
    print("OS/7 storage pressure — the decisions, with no ZFS")
    print()

    if not os.path.exists(STORAGE):
        print(f"!!! {STORAGE} is not there")
        return 1

    levels()
    gate()
    tightening()
    protection()
    ownership()
    boundary()
    safety()
    confirmation()

    print()
    if FAILS:
        print(f"  FAILED: {len(FAILS)}")
        for failure in FAILS:
            print(f"    {failure}")
        return 1

    print("  all ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
