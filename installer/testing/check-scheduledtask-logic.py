#!/usr/bin/env python3
"""
The scheduled-task DECISIONS, in seconds, with no systemd.

    ./check-scheduledtask-logic.py

WHY IT EXISTS. BUILD-NOTES #113: the unattended update check — the mechanism
RELEASE-AND-UPDATE-PLAN §6 ships so that "on a managed fleet nobody types
Update-OS7" — is a TIMER, and the cmdlet surface could not see a timer at all.
The fix is a noun, and a noun is a set of decisions:

  * `Healthy` must be $false for a timer that is ENABLED AND NEVER STARTED —
    `systemctl enable` arms the next boot only, so that timer never fires and
    nothing on the machine says so (measured on systemd 259).
  * A DISABLED task must still be LISTED — systemd's own list-timers cannot
    see one (measured), which is #113's shape arriving a second time.
  * Running a task now means starting the SERVICE — starting the timer merely
    arms the schedule.
  * `Unregister` must refuse a package's timer BY NAME, before any systemd
    call — deleting a package's unit file leaves dpkg believing in a file
    that is gone.
  * A calendar spec is judged by the parser that will read it, BEFORE any
    file exists that carries the mistake.

The systemctl/list output the fake answers with is the RECORDED REAL output in
powershell/Systemd/tests/fixtures (captured 2026-08-29 from a container running
systemd 259), so the shapes are systemd's and not this file's.

WHAT THIS IS NOT. It says nothing about what systemctl emits — Test-SystemdModule
checks the parsing against the same recordings. This checks what OS/7's layer
CONCLUDES and what it REFUSES.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OS7 = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")
SYSTEMD = os.path.join(REPO, "powershell", "Systemd", "Systemd.psd1")
FIXTURES = os.path.join(REPO, "powershell", "Systemd", "tests", "fixtures")

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


# The driver runs as a FILE with parameters rather than a formatted -Command
# string: it carries too many scriptblocks for doubled-brace formatting to stay
# readable, and a brace that goes missing in a fake is a fake that lies.
DRIVER = r"""
param(
    [Parameter(Mandatory)][string]$SystemdManifest,
    [Parameter(Mandatory)][string]$OS7Manifest,
    [Parameter(Mandatory)][string]$FixtureDir,
    [Parameter(Mandatory)][string]$Lab
)
$ErrorActionPreference = 'Stop'
Import-Module $SystemdManifest -Force
Import-Module $OS7Manifest -Force

# Everything the fake needs lives INSIDE the Systemd module's scope: the
# override records calls into $script: state, and BUILD-NOTES #96 is what
# happens to a recording block that went through .GetNewClosure() — the fresh
# closure scope is where $script: stops resolving to the module.
& (Get-Module Systemd) {
    param($fixtures, $lab)
    $script:SystemdUnitDirectory = $lab
    $script:__stFx = $fixtures
    $script:__stMode = 'ok'
    $script:__stServiceResult = 'success'
    $script:__stCalls = @()
    $script:SystemdCommandOverride = {
        param($cmd, $a)
        $script:__stCalls += "$cmd $($a -join ' ')"
        if ($cmd -eq 'systemd-analyze') {
            if ($script:__stMode -eq 'badcal') {
                return [pscustomobject]@{ StdOut = ''; ExitCode = 1
                    StdErr = "Failed to parse calendar specification 'garbage': Invalid argument" }
            }
            return [pscustomobject]@{ StdOut = 'Normalized form: *-*-* 03:00:00'; ExitCode = 0; StdErr = '' }
        }
        $out = ''
        if ($a -contains 'list-unit-files' -or $a -contains 'list-timers') {
            # The real command honours a name argument (measured) - a fake
            # answering a named query with the whole list would staple one
            # timer's row to another's detail.
            $key = if ($a -contains 'list-unit-files') { 'unitfiles' } else { 'timers' }
            $all = $script:__stFx[$key] | ConvertFrom-Json
            $pat = @($a | Where-Object { $_ -notlike '-*' -and $_ -notin @('list-unit-files', 'list-timers') })
            $rows = if ($pat.Count) {
                if ($key -eq 'unitfiles') { @($all | Where-Object unit_file -like $pat[0]) }
                else { @($all | Where-Object unit -like $pat[0]) }
            }
            else { @($all) }
            # An EMPTY array piped into ConvertTo-Json yields nothing at all,
            # not '[]' - and the real systemctl answers '[]' (measured).
            $json = @($rows) | ConvertTo-Json -Depth 6 -Compress -AsArray
            $out = if ($json) { $json } else { '[]' }
        }
        elseif ($a -contains 'list-units') {
            # Mode 'svc-absent' is the measured reality for a service that
            # has never run: it is not in list-units at all.
            if ($script:__stMode -eq 'svc-absent') { $out = '[]' }
            else {
                $pat = @($a | Where-Object { $_ -notlike '-*' -and $_ -ne 'list-units' })
                $rows = foreach ($p in $pat) {
                    [pscustomobject]@{ unit = $p; load = 'loaded'; active = 'inactive'; sub = 'dead'; description = $p }
                }
                $json = @($rows) | ConvertTo-Json -Depth 5 -Compress -AsArray
                $out = if ($json) { $json } else { '[]' }
            }
        }
        elseif ($a -contains 'show') {
            $unit = $a[1]
            if ($a -contains 'TimersCalendar') {
                # A timer's detail. The probe fixture is the recorded
                # enabled-but-never-started state; everything else answers
                # with the recorded active/waiting timer. Mode 'inert' hands
                # the never-started state to a task Register just armed - the
                # ask-back failure that must throw, not return.
                $out = if ($unit -like 'os7-task-probe*' -or
                    ($script:__stMode -eq 'inert' -and $unit -like 'os7-task-*')) { $script:__stFx['inactive'] }
                else { $script:__stFx['timer'] }
            }
            elseif ($a -contains 'Type') {
                # A service's detail, as Get-SystemdUnit asks for it. The one
                # knob is Result - the last run's outcome.
                $out = (@(
                        "Id=$unit", "Description=$unit", 'LoadState=loaded',
                        'ActiveState=inactive', 'SubState=dead', 'UnitFileState=static',
                        "Result=$($script:__stServiceResult)", 'NRestarts=0', 'ExecMainPID=0',
                        'ActiveEnterTimestamp=', "FragmentPath=/usr/lib/systemd/system/$unit",
                        'Type=oneshot') -join "`n")
            }
            else {
                $out = if ($script:__stMode -in @('removed', 'absent')) { $script:__stFx['notfound'] }
                else { $script:__stFx['loaded'] }
            }
        }
        [pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
    }
} @{
    unitfiles = Get-Content -Raw -LiteralPath (Join-Path $FixtureDir 'systemctl-list-unit-files.json')
    timers    = Get-Content -Raw -LiteralPath (Join-Path $FixtureDir 'systemctl-list-timers.json')
    timer     = Get-Content -Raw -LiteralPath (Join-Path $FixtureDir 'systemctl-show-timer.txt')
    inactive  = Get-Content -Raw -LiteralPath (Join-Path $FixtureDir 'systemctl-show-timer-enabled-inactive.txt')
    loaded    = Get-Content -Raw -LiteralPath (Join-Path $FixtureDir 'systemctl-show-loadstate-loaded.txt')
    notfound  = Get-Content -Raw -LiteralPath (Join-Path $FixtureDir 'systemctl-show-loadstate-notfound.txt')
} $Lab

function Set-StMode([string]$m) { & (Get-Module Systemd) { param($v) $script:__stMode = $v } $m }
function Set-StServiceResult([string]$r) { & (Get-Module Systemd) { param($v) $script:__stServiceResult = $v } $r }
function Get-StCalls { @(& (Get-Module Systemd) { $script:__stCalls }) }
function Reset-StCalls { & (Get-Module Systemd) { $script:__stCalls = @() } }

$out = [ordered]@{}

# --- the listing ------------------------------------------------------------
$all = @(Get-OS7ScheduledTask)
$san = $all | Where-Object Name -eq 'sanoid.timer'
$out.All = @{
    Count               = $all.Count
    SanoidNextRunIsDate = ($san.NextRun -is [datetime])
    SanoidNextRunYear   = if ($san.NextRun) { $san.NextRun.Year } else { $null }
    SanoidLastRunIsDate = ($san.LastRun -is [datetime])
    SanoidHealthy       = $san.Healthy
    SanoidStartup       = $san.StartupType
    SanoidIsOS7         = $san.IsOS7
    FstrimNextRun       = ($all | Where-Object Name -eq 'fstrim.timer').NextRun
    DisabledListed      = [bool]($all | Where-Object Name -eq 'chrony-dnssrv@.timer')
}
$out.OS7Only = @(@(Get-OS7ScheduledTask -OS7Only).Name)

# --- one task, detailed -----------------------------------------------------
$d = @(Get-OS7ScheduledTask -Name sanoid.timer)[0]
$out.Sanoid = @{ Healthy = $d.Healthy; LastResult = $d.LastResult; Persistent = $d.Persistent
    Schedule = @($d.Schedule); Activates = $d.Activates
}

# --- a task whose last run failed --------------------------------------------
Set-StServiceResult 'exit-code'
$out.FailedRunHealthy = @(Get-OS7ScheduledTask -Name sanoid.timer)[0].Healthy
Set-StServiceResult 'success'

# --- THE TRAP: enabled and never started -------------------------------------
$t = @(Get-OS7ScheduledTask -Name os7-task-probe.timer)[0]
$out.Trap = @{ Healthy = $t.Healthy; Startup = $t.StartupType
    Active = $t.ActiveState; NextRunSet = ($null -ne $t.NextRun)
}

# --- run now = the SERVICE ---------------------------------------------------
Reset-StCalls
Start-OS7ScheduledTask -Name sanoid.timer | Out-Null
$out.StartCalls = Get-StCalls

# --- enable arms NOW as well as the next boot --------------------------------
Reset-StCalls
Enable-OS7ScheduledTask -Name os7-task-probe.timer | Out-Null
$out.EnableCalls = Get-StCalls
Reset-StCalls
Disable-OS7ScheduledTask -Name os7-task-probe.timer -Confirm:$false | Out-Null
$out.DisableCalls = Get-StCalls

# --- register ----------------------------------------------------------------
Reset-StCalls
$reg = Register-OS7ScheduledTask -Name demo -Daily -At 03:00 -Command 'Get-Date' `
    -Persistent -RandomizedDelay ([timespan]::FromMinutes(10))
$out.Register = @{
    Name = $reg.Name; Active = $reg.ActiveState; NextRunSet = ($null -ne $reg.NextRun)
    Calls = Get-StCalls
    TimerText = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-demo.timer'))
    ServiceText = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-demo.service'))
}
Register-OS7ScheduledTask -Name wk -Weekly -DayOfWeek Sunday -At 03:00 -Command 'Get-Date' | Out-Null
$out.WeeklyTimer = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-wk.timer'))
Register-OS7ScheduledTask -Name raw -OnCalendar 'Mon..Fri 06:30' -Command 'Get-Date' | Out-Null
$out.RawTimer = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-raw.timer'))
Register-OS7ScheduledTask -Name prog -Daily -At 06:00 -Execute /usr/bin/apt -Arguments update | Out-Null
$out.ProgService = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-prog.service'))

# What you type is what runs: systemd's own metacharacters, escaped on the way
# into the unit file.
Register-OS7ScheduledTask -Name pct -Daily -At 04:00 `
    -Command 'Get-Date -UFormat "%m" > /tmp/x$v' | Out-Null
$out.PctService = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-pct.service'))
Register-OS7ScheduledTask -Name sp -Daily -At 05:00 `
    -Execute '/opt/my app/run.sh' -Arguments go | Out-Null
$out.SpService = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-sp.service'))

# A name that is taken is refused; -Force is the deliberate way over it.
try { Register-OS7ScheduledTask -Name wk -Daily -At 09:00 -Command 'Get-Date' }
catch { $out.Duplicate = $_.Exception.Message }
Register-OS7ScheduledTask -Name wk -Daily -At 09:00 -Command 'Get-Date' -Force | Out-Null
$out.ForcedTimer = [System.IO.File]::ReadAllText((Join-Path $Lab 'os7-task-wk.timer'))

# THE ASK-BACK FAILURE: the timer was written, enabled and started, and
# systemd still reports it never firing - Register must throw, not return.
Set-StMode 'inert'
try { Register-OS7ScheduledTask -Name inert -Daily -At 07:00 -Command 'Get-Date' }
catch { $out.Inert = $_.Exception.Message }
Set-StMode 'ok'
$out.InertFilesLeft = [System.IO.File]::Exists((Join-Path $Lab 'os7-task-inert.timer'))

# A verb given a glob must refuse before touching anything - `systemctl stop`
# expands globs and `disable` refuses them, so half the operation would land.
Reset-StCalls
try { Enable-OS7ScheduledTask -Name 'sanoid*' }
catch { $out.Glob = $_.Exception.Message }
$out.GlobCallCount = (Get-StCalls).Count

# A task that does not exist: the listing is empty, the verb is loud.
Set-StMode 'absent'
$out.GhostRows = @(Get-OS7ScheduledTask -Name ghostly).Count
try { Start-OS7ScheduledTask -Name ghostly }
catch { $out.NoTask = $_.Exception.Message }
Set-StMode 'ok'

# A service that has never run is not in list-units at all (measured):
# LastResult is $null, and $null is not a failure.
Set-StMode 'svc-absent'
$noSvc = @(Get-OS7ScheduledTask -Name sanoid.timer)[0]
$out.NoSvc = @{ LastResult = $noSvc.LastResult; Healthy = $noSvc.Healthy }
Set-StMode 'ok'

# --- the refusals ------------------------------------------------------------
$out.Refusals = [ordered]@{}
try { Register-OS7ScheduledTask -Name x1 -Daily -Command 'Get-Date' }
catch { $out.Refusals.NoAt = $_.Exception.Message }
try { Register-OS7ScheduledTask -Name x2 -Daily -Weekly -DayOfWeek Monday -At 03:00 -Command 'Get-Date' }
catch { $out.Refusals.TwoTriggers = $_.Exception.Message }
try { Register-OS7ScheduledTask -Name x3 -Daily -At 03:00 -Command 'Get-Date' -Execute /usr/bin/apt }
catch { $out.Refusals.TwoActions = $_.Exception.Message }
try { Register-OS7ScheduledTask -Name x4 -Daily -At 03:00 -Execute apt }
catch { $out.Refusals.RelativeExecute = $_.Exception.Message }
try { Register-OS7ScheduledTask -Name x5 -Daily -At '25:00' -Command 'Get-Date' }
catch { $out.Refusals.BadAt = $_.Exception.Message }
try { Register-OS7ScheduledTask -Name x7 -OnCalendar daily -At 03:00 -Command 'Get-Date' }
catch { $out.Refusals.AtWithCalendar = $_.Exception.Message }
try { Register-OS7ScheduledTask -Name x8 -Daily -At 03:00 -DayOfWeek Monday -Command 'Get-Date' }
catch { $out.Refusals.StrayDayOfWeek = $_.Exception.Message }
try { Register-OS7ScheduledTask -Name x6 -Daily -At 03:00 -Command "Get-Date`nWhatever" }
catch { $out.Refusals.Newline = $_.Exception.Message }
Set-StMode 'badcal'
try { Register-OS7ScheduledTask -Name bad -OnCalendar garbage -Command 'Get-Date' }
catch { $out.Refusals.BadCalendar = $_.Exception.Message }
Set-StMode 'ok'
$out.BadFilesLeft = @([System.IO.Directory]::GetFiles($Lab, 'os7-task-bad.*')).Count
$out.XFilesLeft = @([System.IO.Directory]::GetFiles($Lab, 'os7-task-x*')).Count

# A package's timer is refused BY NAME, before any systemd call.
Reset-StCalls
try { Unregister-OS7ScheduledTask -Name sanoid.timer -Confirm:$false }
catch { $out.Refusals.Vendor = $_.Exception.Message }
$out.VendorCallCount = (Get-StCalls).Count

# An EXPLICIT unit name means that unit everywhere - the one verb that deletes
# must not read `raw.timer` as the short name of os7-task-raw.
try { Unregister-OS7ScheduledTask -Name raw.timer -Confirm:$false }
catch { $out.Refusals.ExplicitTimer = $_.Exception.Message }
$out.RawStillThere = [System.IO.File]::Exists((Join-Path $Lab 'os7-task-raw.timer'))

# --- unregister, by short name ------------------------------------------------
Set-StMode 'removed'
Reset-StCalls
Unregister-OS7ScheduledTask -Name demo -Confirm:$false
$out.Unregister = @{
    Calls       = Get-StCalls
    TimerGone   = -not [System.IO.File]::Exists((Join-Path $Lab 'os7-task-demo.timer'))
    ServiceGone = -not [System.IO.File]::Exists((Join-Path $Lab 'os7-task-demo.service'))
}
Set-StMode 'ok'

[pscustomobject]$out | ConvertTo-Json -Depth 8 -Compress
"""


def main():
    print("### the scheduled-task decisions — Get-/Register-/Unregister-OS7ScheduledTask")
    print("### recorded systemd 259 output, no systemd, no VM\n")

    exe = shutil.which("pwsh")
    if not exe:
        sys.exit("pwsh not found; this check runs the real powershell/OS7 module.")

    lab = tempfile.mkdtemp(prefix="os7-task-")
    try:
        driver = os.path.join(lab, "driver.ps1")
        with open(driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        p = subprocess.run(
            [exe, "-NoProfile", "-NonInteractive", "-File", driver,
             "-SystemdManifest", SYSTEMD, "-OS7Manifest", OS7,
             "-FixtureDir", FIXTURES, "-Lab", lab],
            capture_output=True, text=True)
        if p.returncode != 0:
            print(f"      FAIL  pwsh exited {p.returncode}")
            print("            " + (p.stderr.strip().replace("\n", "\n            ") or "(no stderr)"))
            return 1
        got = json.loads(p.stdout.strip().splitlines()[-1])

        print("  the listing — what runs on a schedule here")
        a = got["All"]
        check(a["Count"] >= 20, "the union of both systemd lists came back", str(a["Count"]))
        check(a["SanoidNextRunIsDate"] and a["SanoidNextRunYear"] == 2026,
              "NextRun is a [datetime] decoded from microseconds",
              f"year {a['SanoidNextRunYear']}")
        check(a["SanoidLastRunIsDate"] is True,
              "LastRun is a [datetime] once the schedule HAS fired")
        check(a["FstrimNextRun"] is None,
              "a timer systemd will not schedule has NextRun $null")
        check(a["DisabledListed"] is True,
              "a DISABLED timer is still listed — list-timers alone cannot see one")
        check(a["SanoidHealthy"] is None,
              "without -Detailed, Healthy is null and not true")
        check(a["SanoidStartup"] == "enabled",
              "StartupType comes from list-unit-files even in the summary")

        print("\n  which schedules are OS/7's")
        names = set(got["OS7Only"])
        check("sanoid.timer" in names,
              "the backup snapshot schedule is ours — it IS sanoid's own timer",
              "sanoid.timer")
        check("os7-backup-replicate.timer" in names, "and so is replication")
        check("os7-task-idle.timer" in names, "and an operator-registered task")
        check("apt-daily.timer" not in names, "Ubuntu's own schedules are not")
        check(a["SanoidIsOS7"] is True, "IsOS7 says so in the full listing too")

        print("\n  Healthy — right about working tasks as well as broken ones")
        s = got["Sanoid"]
        check(s["Healthy"] is True, "an active timer whose last run succeeded", str(s["Healthy"]))
        check(s["LastResult"] == "success", "LastResult is the SERVICE's outcome")
        check(s["Persistent"] is True, "Persistent=yes becomes $true")
        check("*-*-* *:00/15:00" in s["Schedule"], "the schedule spec, verbatim")
        check(got["FailedRunHealthy"] is False,
              "a task whose last run failed is not healthy")
        t = got["Trap"]
        check(t["Startup"] == "enabled" and t["Active"] == "inactive" and t["Healthy"] is False,
              "ENABLED AND NEVER STARTED is unhealthy — it never fires until reboot",
              f"{t['Startup']}/{t['Active']} -> {t['Healthy']}")
        check(t["NextRunSet"] is False, "and its NextRun says so")

        print("\n  the verbs act on the right unit")
        start = got["StartCalls"]
        check(any(c.startswith("systemctl start sanoid.service") for c in start),
              "run-now starts the SERVICE — starting the timer merely arms the schedule")
        check(not any(c.startswith("systemctl start sanoid.timer") for c in start),
              "and does not start the timer")
        en = got["EnableCalls"]
        check(any("enable os7-task-probe.timer" in c for c in en) and
              any(c.startswith("systemctl start os7-task-probe.timer") for c in en),
              "Enable- enables AND starts — enable alone arms only the next boot")
        di = got["DisableCalls"]
        check(any(c.startswith("systemctl stop os7-task-probe.timer") for c in di) and
              any("disable os7-task-probe.timer" in c for c in di),
              "Disable- stops AND disables")

        print("\n  register — what lands in the unit files")
        r = got["Register"]
        check(r["Name"] == "os7-task-demo.timer",
              "the task is named os7-task-<name>", r["Name"])
        check(r["Active"] == "active" and r["NextRunSet"] is True,
              "registered means systemd schedules it, not that four commands exited 0")
        check(any(c.startswith("systemd-analyze calendar -- ") for c in r["Calls"]),
              "the spec went past systemd-analyze first, behind --")
        check(any("daemon-reload" in c for c in r["Calls"]), "systemd was told to re-read")
        # The corruption class: registering without arming leaves a task that
        # never runs, and once left the whole suite stayed green.
        check(any("enable os7-task-demo.timer" in c for c in r["Calls"]),
              "register ENABLES the timer")
        check(any(c.startswith("systemctl start os7-task-demo.timer") for c in r["Calls"]),
              "and STARTS it - enable alone arms only the next boot")
        check("OnCalendar=*-*-* 03:00:00" in r["TimerText"], "-Daily -At becomes a calendar spec")
        check("RandomizedDelaySec=600" in r["TimerText"], "-RandomizedDelay in whole seconds")
        check("Persistent=true" in r["TimerText"], "-Persistent")
        check('ExecStart=/usr/bin/pwsh -NoProfile -NonInteractive -Command "Get-Date"'
              in r["ServiceText"],
              "-Command runs through pwsh, absolute path, no profile")
        check("OnCalendar=Sun *-*-* 03:00:00" in got["WeeklyTimer"],
              "-Weekly -DayOfWeek Sunday, in systemd's three-letter spelling")
        check("OnCalendar=Mon..Fri 06:30" in got["RawTimer"],
              "-OnCalendar passes a raw spec through verbatim — the escape hatch")
        check("ExecStart=/usr/bin/apt update" in got["ProgService"],
              "-Execute -Arguments for a task that is not PowerShell")
        check('\\"%%m\\"' in got["PctService"] and "/tmp/x$$v" in got["PctService"],
              "% and $ are escaped — systemd would expand them into a DIFFERENT command")
        check('ExecStart="/opt/my app/run.sh" go' in got["SpService"],
              "-Execute with a space is quoted — unquoted, systemd runs /opt/my")
        check("already exists" in got.get("Duplicate", ""),
              "a taken name is refused rather than silently overwritten")
        check("OnCalendar=*-*-* 09:00:00" in got["ForcedTimer"],
              "and -Force replaces it deliberately")

        print("\n  the ask-back — registered means systemd schedules it")
        check("does not schedule it" in got.get("Inert", ""),
              "a task systemd reports never firing makes Register- throw, not return")
        check(got["InertFilesLeft"] is True,
              "with the unit files left in place for inspection")

        print("\n  a name that means nothing, and a name that means too much")
        check(got["GhostRows"] == 0, "a task that does not exist is not listed")
        check("There is no scheduled task" in got.get("NoTask", ""),
              "and running it is refused by name")
        check("is a pattern" in got.get("Glob", ""),
              "a glob is refused — stop expands globs and disable refuses them")
        check(got["GlobCallCount"] == 0, "before any systemd call")
        check(got["NoSvc"]["LastResult"] is None and got["NoSvc"]["Healthy"] is True,
              "a service that has never run reads as 'no outcome yet', not as a failure")

        print("\n  the refusals")
        rf = got["Refusals"]
        check("-At" in rf.get("NoAt", ""), "-Daily without -At")
        check("exactly one trigger" in rf.get("TwoTriggers", ""), "two triggers")
        check("exactly one thing" in rf.get("TwoActions", ""), "-Command and -Execute together")
        check("absolute path" in rf.get("RelativeExecute", ""), "-Execute with a relative path")
        check("time of day" in rf.get("BadAt", ""), "-At 25:00")
        check("carries its own time of day" in rf.get("AtWithCalendar", ""),
              "-At beside -OnCalendar — accepted-then-ignored is a schedule the "
              "operator believes in and the machine does not have")
        check("belongs to -Weekly" in rf.get("StrayDayOfWeek", ""),
              "-DayOfWeek beside -Daily, same rule")
        check("line break" in rf.get("Newline", ""),
              "a newline in -Command — it would be the unit file's next directive")
        check("cannot parse the calendar spec" in rf.get("BadCalendar", ""),
              "a spec systemd cannot parse, refused with systemd's own words")
        check(got["BadFilesLeft"] == 0 and got["XFilesLeft"] == 0,
              "and every refusal happened BEFORE anything was written")

        print("\n  unregister — the line it holds")
        check("not an operator-registered task" in rf.get("Vendor", ""),
              "a package's timer is refused by name", "sanoid.timer")
        check(got["VendorCallCount"] == 0,
              "and the refusal happened before any systemd call")
        check("not an operator-registered task" in rf.get("ExplicitTimer", ""),
              "an explicit 'raw.timer' is NOT read as the short name of os7-task-raw")
        check(got["RawStillThere"] is True, "and os7-task-raw is untouched")
        u = got["Unregister"]
        check(u["TimerGone"] is True and u["ServiceGone"] is True,
              "unregister removes the pair Register wrote")
        check(any(c.startswith("systemctl stop os7-task-demo.timer") for c in u["Calls"]),
              "after stopping it")
        check(any("daemon-reload" in c for c in u["Calls"]), "and telling systemd")
    finally:
        shutil.rmtree(lab, ignore_errors=True)

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed — the surface can see every timer, names the trap, and "
          "refuses what it must.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
