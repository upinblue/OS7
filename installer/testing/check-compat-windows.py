#!/usr/bin/env python3
"""
The Windows compatibility layer's CONTRACT and its DECISIONS, with no systemd.

    ./check-compat-windows.py                       seconds, needs only pwsh
    ./check-compat-windows.py --show-refusals       print the refusal table

WHY IT EXISTS. P1 in docs/POWERSHELL-SURFACE-PLAN.md deferred the Windows names
to a compatibility module and said of it: "Each entry needs a row in a table
that a test drives. An alias that is nearly right is the thing this decision
exists to avoid." This is that test. The revision on 2026-09-09 made the
entries FUNCTIONS with Windows' parameters rather than aliases, which raises the
stakes rather than lowering them: a function can accept a parameter and ignore
it, and a script that half-works is worse than one that stops on its first line.

SO THE CONTRACT IS CHECKED IN BOTH DIRECTIONS:

  * every parameter the REAL Windows cmdlet has is DECLARED here — otherwise a
    copied script fails on the parameter and never reaches the work;
  * every parameter declared here is either a Windows one or a named OS/7
    addition — otherwise this surface drifts into inventing Windows-looking
    parameters that Windows does not have;
  * every parameter that cannot be honoured is in the module's own refusal
    table, is reachable (the function declares it), is real (Windows has it),
    and ACTUALLY THROWS. A refusal that is only written down is the failure
    mode, not the fix.

WHERE THE WINDOWS SIDE COMES FROM. WINDOWS_PARAMETERS below was recorded on
2026-09-09 by asking a real Windows pwsh **7.6.5** — the same version OS/7
ships, so the two sides are comparable and a difference is a platform
difference rather than a version one:

    Get-Command <name> | ForEach-Object { $_.Parameters.Keys } # minus the
                                                               # common ones

Re-record it the same way when the pinned PowerShell moves.

AND THE DECISIONS, against a FAKE systemd — the `$script:SystemdCommandOverride`
seam the Systemd module carries for exactly this, and the one
check-scheduledtask-logic.py uses. The four that matter most:

  1. `Restart-Computer` asks for `systemctl reboot`. It must NOT reach
     `shutdown` with no arguments, which is what PowerShell's own cmdlet does
     and which powers the machine OFF (measured 2026-09-09 on a machine: the
     console said `Reached target poweroff.target`; upstream
     PowerShell/PowerShell#14684). This check is that defect's regression test
     and it is the reason this file exists at all.
  2. `Set-Service -StartupType Manual` on a MASKED unit unmasks BEFORE it
     disables. `systemctl disable` does not unmask, so without the first call
     the unit reports the new start type and still refuses to start, with
     nothing connecting the two.
  3. A FROZEN unit reports `Status = Paused` although systemd still reports
     `ActiveState=active` (measured on a machine). If Status came from the unit
     state, a paused service would read as running.
  4. `Rename-Computer` is REFUSED on a joined machine, before it touches
     anything: the keytab holds principals for the old name.

WHAT THIS IS NOT. It says nothing about what systemctl emits — Test-SystemdModule
checks the parsing against recorded real output. It checks what the
compatibility layer CONCLUDES, what it ASKS FOR, and what it REFUSES.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# OS7_MODULE_ROOT points this at a COPY of powershell/, so each rule can be
# proven to FIRE against a planted defect and not merely to stay quiet on a
# clean tree. The same seam check-ps-traps.py has as OS7_SCAN_ROOT and
# check-secureboot-logic.py as OS7_SB_MODULE -- and the same reason not to
# plant the defect in the working tree, which somebody may be editing while
# the check runs. The one worth planting first:
#
#   sed -i 's/Action = .Reboot./Action = "PowerOff"/' <copy>/OS7/OS7.Compat.Windows.ps1
#
# which is the upstream defect this file exists for, and must go RED.
MODULE_ROOT = os.environ.get("OS7_MODULE_ROOT") or os.path.join(REPO, "powershell")
OS7 = os.path.join(MODULE_ROOT, "OS7", "OS7.psd1")
SYSTEMD = os.path.join(MODULE_ROOT, "Systemd", "Systemd.psd1")

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


# Recorded from a real Windows pwsh 7.6.5 on 2026-09-09. Common parameters are
# excluded; -WhatIf and -Confirm come from SupportsShouldProcess on both sides.
WINDOWS_PARAMETERS = {
    "Get-Service": "DependentServices DisplayName Exclude Include InputObject Name RequiredServices",
    "Set-Service": "Credential Description DisplayName Force InputObject Name PassThru SecurityDescriptorSddl StartupType Status",
    "New-Service": "BinaryPathName Credential DependsOn Description DisplayName Name SecurityDescriptorSddl StartupType",
    "Remove-Service": "InputObject Name",
    "Start-Service": "DisplayName Exclude Include InputObject Name PassThru",
    "Stop-Service": "DisplayName Exclude Force Include InputObject Name NoWait PassThru",
    "Restart-Service": "DisplayName Exclude Force Include InputObject Name PassThru",
    "Suspend-Service": "DisplayName Exclude Include InputObject Name PassThru",
    "Resume-Service": "DisplayName Exclude Include InputObject Name PassThru",
    "Set-TimeZone": "Id InputObject Name PassThru",
    "Get-ComputerInfo": "Property",
    "Rename-Computer": "ComputerName DomainCredential Force LocalCredential NewName PassThru Restart WsmanAuthentication",
    "Restart-Computer": "ComputerName Credential Delay For Force Timeout Wait WsmanAuthentication",
    "Stop-Computer": "ComputerName Credential Force WsmanAuthentication",
}

# Parameters OS/7 adds. Each one is here BY NAME so that a new one cannot
# appear unnoticed and be mistaken for something Windows has.
#
# -Message is the wall message for a scheduled action. Windows has no equivalent
# because its -Delay means something else entirely (the poll interval while
# -Wait watches a remote machine come back), and a delayed local restart with no
# way to tell the signed-in users why is worse than no delay at all.
#
# -Delay on Stop-Computer is an addition too: Windows' Stop-Computer has no
# -Delay, and refusing to schedule a poweroff while scheduling a restart would
# be an asymmetry with no reason behind it.
OS7_ADDITIONS = {
    "Restart-Computer": {"Message"},
    "Stop-Computer": {"Delay", "Message"},
}

# Windows' own enumerations, so a mapping cannot produce a word Windows does not
# have. From System.ServiceProcess.ServiceControllerStatus and
# Microsoft.PowerShell.Commands.ServiceStartMode.
WINDOWS_STATUS = {
    "ContinuePending", "Paused", "PausePending", "Running", "StartPending",
    "StopPending", "Stopped",
}
WINDOWS_STARTMODE = {"Boot", "System", "Automatic", "Manual", "Disabled"}

# systemd's own words, so the maps can be checked for TOTALITY rather than for
# containing whatever somebody thought of. From `systemctl --state=help` and
# the unit-file states systemd 259 documents.
SYSTEMD_ACTIVE_STATES = {
    "active", "reloading", "inactive", "failed", "activating", "deactivating",
    "maintenance",
}
SYSTEMD_UNIT_FILE_STATES = {
    "enabled", "enabled-runtime", "linked", "linked-runtime", "alias", "masked",
    "masked-runtime", "static", "indirect", "disabled", "generated",
    "transient", "bad",
}

DRIVER = r"""
param(
    [Parameter(Mandatory)][string]$SystemdManifest,
    [Parameter(Mandatory)][string]$OS7Manifest
)
$ErrorActionPreference = 'Stop'
Import-Module $SystemdManifest -Force
Import-Module $OS7Manifest -Force

# ---------------------------------------------------------------------------
# The fake systemd. It RECORDS every call and answers in systemd's shapes --
# the same seam check-scheduledtask-logic.py uses, and for the same reason:
# what this file checks is what OS/7 ASKS FOR, and the only way to see that is
# to be the thing being asked.
# ---------------------------------------------------------------------------
& (Get-Module Systemd) {
    $script:__cwCalls = @()
    $script:__cwFrozen = @()
    $script:__cwFileState = @{}
    $script:__cwActive = @{}
    $script:SystemdCommandOverride = {
        param($cmd, $a)
        $script:__cwCalls += "$cmd $($a -join ' ')"

        if ($cmd -ne 'systemctl') {
            return [pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
        }

        # The freezer, asked one unit at a time with --value.
        if ($a -contains '--property=FreezerState') {
            $unit = $a[1]
            $v = if ($script:__cwFrozen -contains $unit) { 'frozen' } else { 'running' }
            return [pscustomobject]@{ StdOut = $v; ExitCode = 0; StdErr = '' }
        }

        if ($a -contains 'list-units') {
            $pat = @($a | Where-Object {
                    $_ -notlike '-*' -and $_ -notin @('list-units', 'systemctl') })
            $known = @(
                @{ unit = 'ssh.service'; description = 'OpenBSD Secure Shell server' },
                @{ unit = 'chrony.service'; description = 'chrony, an NTP client/server' },
                @{ unit = 'cups.service'; description = 'CUPS Scheduler' },
                @{ unit = 'zfs-mount.service'; description = 'Mount ZFS filesystems' }
            )
            $rows = foreach ($k in $known) {
                if ($pat.Count -and -not @($pat | Where-Object { $k.unit -like $_ }).Count) { continue }
                [pscustomobject]@{
                    unit        = $k.unit
                    load        = 'loaded'
                    active      = $(if ($script:__cwActive.ContainsKey($k.unit)) { $script:__cwActive[$k.unit] } else { 'active' })
                    sub         = 'running'
                    description = $k.description
                }
            }
            # An EMPTY array piped into ConvertTo-Json yields nothing at all,
            # and the real systemctl answers '[]' (measured).
            $json = @($rows) | ConvertTo-Json -Depth 5 -Compress -AsArray
            return [pscustomobject]@{
                StdOut = $(if ($json) { $json } else { '[]' }); ExitCode = 0; StdErr = ''
            }
        }

        if ($a -contains 'show') {
            $unit = $a[1]
            $fs = if ($script:__cwFileState.ContainsKey($unit)) { $script:__cwFileState[$unit] }
            else { 'enabled' }
            $as = if ($script:__cwActive.ContainsKey($unit)) { $script:__cwActive[$unit] } else { 'active' }
            $out = (@(
                    "Id=$unit", "Description=$unit", 'LoadState=loaded',
                    "ActiveState=$as", 'SubState=running', "UnitFileState=$fs",
                    'Result=success', 'NRestarts=0', 'ExecMainPID=101',
                    'ActiveEnterTimestamp=@1787839867',
                    "FragmentPath=/usr/lib/systemd/system/$unit",
                    'Type=simple') -join "`n")
            return [pscustomobject]@{ StdOut = $out; ExitCode = 0; StdErr = '' }
        }

        # enable / disable / mask / unmask / start / stop / restart / freeze /
        # thaw / reboot / poweroff / daemon-reload -- all accepted, so that what
        # is checked is WHICH ONE WAS ASKED FOR.
        return [pscustomobject]@{ StdOut = ''; ExitCode = 0; StdErr = '' }
    }
}

function Get-CwCalls { @(& (Get-Module Systemd) { $script:__cwCalls }) }
function Reset-CwCalls { & (Get-Module Systemd) { $script:__cwCalls = @() } }
function Set-CwFrozen([string[]]$u) { & (Get-Module Systemd) { param($v) $script:__cwFrozen = $v } $u }
function Set-CwFileState([hashtable]$h) { & (Get-Module Systemd) { param($v) $script:__cwFileState = $v } $h }
function Set-CwActive([hashtable]$h) { & (Get-Module Systemd) { param($v) $script:__cwActive = $v } $h }

# The two OS/7 neighbours this layer calls that are not systemd. Replaced
# INSIDE the OS7 module's scope, which is where its own functions resolve.
& (Get-Module OS7) {
    $script:__cwTimeZone = $null
    Set-Item -Path function:script:Set-OS7TimeZone -Value {
        [CmdletBinding(SupportsShouldProcess)]
        param([Parameter(Mandatory)][string]$Id)
        $script:__cwTimeZone = $Id
    }
    $script:__cwJoined = $false
    Set-Item -Path function:script:Get-OS7Domain -Value {
        [CmdletBinding()]
        param()
        [pscustomobject]@{
            Joined            = $script:__cwJoined
            ConfiguredDomains = @('os7test.local')
        }
    }
}
function Get-CwTimeZone { & (Get-Module OS7) { $script:__cwTimeZone } }
function Set-CwJoined([bool]$v) { & (Get-Module OS7) { param($b) $script:__cwJoined = $b } $v }

$out = [ordered]@{}
$common = [System.Management.Automation.PSCmdlet]::CommonParameters +
    [System.Management.Automation.PSCmdlet]::OptionalCommonParameters

# --- the surface -----------------------------------------------------------
$out.Surface = [ordered]@{}
foreach ($n in @('Get-Service', 'Set-Service', 'New-Service', 'Remove-Service',
        'Start-Service', 'Stop-Service', 'Restart-Service', 'Suspend-Service',
        'Resume-Service', 'Set-TimeZone', 'Get-ComputerInfo', 'Rename-Computer',
        'Restart-Computer', 'Stop-Computer')) {
    $c = @(Get-Command -Name $n -Module OS7 -ErrorAction SilentlyContinue)
    if (-not $c.Count) { $out.Surface[$n] = $null; continue }
    $out.Surface[$n] = @{
        Type       = [string]$c[0].CommandType
        Parameters = @($c[0].Parameters.Keys | Where-Object { $_ -notin $common } | Sort-Object)
    }
}

# --- the module's own tables, read from its scope ---------------------------
$out.Tables = & (Get-Module OS7) {
    @{
        Unsupported = $script:OS7CompatUnsupported
        StartType   = $script:OS7CompatStartTypeFromUnitFile
        Startup     = $script:OS7CompatStartupToSystemd
        Status      = $script:OS7CompatStatusFromActiveState
        Names       = $script:OS7CompatWindowsNames
    }
}

# --- do the refusals actually throw? ---------------------------------------
# Every row in the table, invoked, with -WhatIf so that a row which does NOT
# throw cannot change the machine either.
$out.Refusals = [ordered]@{}
foreach ($key in @((& (Get-Module OS7) { $script:OS7CompatUnsupported }).Keys)) {
    $parts = $key -split ':', 2
    $cmdlet = $parts[0]
    $param = $parts[1]
    # A value OF THE RIGHT TYPE, so that what is measured is the REFUSAL and
    # not a binding error dressed up as one. The first version of this check
    # sent the string 'x' to every parameter and reported
    # ParameterBindingArgumentTransformationException for every switch, int and
    # credential in the table -- fourteen failures that were the check's own.
    $cmd = Get-Command $cmdlet -Module OS7
    $pt = $(if ($cmd.Parameters.ContainsKey($param)) { $cmd.Parameters[$param].ParameterType } else { $null })
    $value =
    if ($null -eq $pt) { 'x' }
    elseif ($pt -eq [System.Management.Automation.SwitchParameter]) { [switch]$true }
    elseif ($pt -eq [System.Management.Automation.PSCredential]) {
        [pscredential]::new('u', (ConvertTo-SecureString 'p' -AsPlainText -Force))
    }
    elseif ($pt -eq [int]) { 1 }
    elseif ($pt -eq [string[]]) { @('x') }
    else { 'x' }

    $splat = @{ $param = $value }
    # The MANDATORY parameters each cmdlet needs before it can get as far as
    # the refusal. Without them PowerShell tries to prompt, cannot in a
    # -NonInteractive session, and throws a ParameterBindingException that
    # looks like a refusal and is not one.
    switch ($cmdlet) {
        'Rename-Computer' { $splat.NewName = 'newname' }
        'Set-Service' { $splat.Name = 'ssh' }
        'New-Service' { $splat.Name = 'probe'; $splat.BinaryPathName = '/bin/true' }
    }
    # -WhatIf ONLY where the cmdlet has it. Get-Service reads and changes
    # nothing, so it carries no ShouldProcess and -WhatIf does not bind --
    # which threw a ParameterBindingException that read as a refusal and was
    # the check mis-calling the thing it was checking.
    if ($cmd.Parameters.ContainsKey('WhatIf')) { $splat.WhatIf = $true }
    try {
        & $cmdlet @splat -ErrorAction Stop | Out-Null
        $out.Refusals[$key] = @{ Threw = $false; Type = $null; Message = $null }
    }
    catch {
        $out.Refusals[$key] = @{
            Threw   = $true
            Type    = $_.Exception.GetType().Name
            Message = $_.Exception.Message
        }
    }
}

# --- Get-Service, over the fake --------------------------------------------
Set-CwFileState @{ 'cups.service' = 'masked'; 'zfs-mount.service' = 'disabled' }
Set-CwFrozen @('chrony.service')

$svc = @(Get-Service ssh)
$out.GetService = @{
    Count       = $svc.Count
    Name        = if ($svc.Count) { $svc[0].Name } else { $null }
    Unit        = if ($svc.Count) { $svc[0].Unit } else { $null }
    Status      = if ($svc.Count) { [string]$svc[0].Status } else { $null }
    StartType   = if ($svc.Count) { [string]$svc[0].StartType } else { $null }
    DisplayName = if ($svc.Count) { $svc[0].DisplayName } else { $null }
    TypeName    = if ($svc.Count) { $svc[0].PSObject.TypeNames[0] } else { $null }
    SystemdKept = if ($svc.Count) {
        @($svc[0].PSObject.Properties.Name | Where-Object { $_ -like 'Systemd*' } | Sort-Object)
    }
    else { @() }
}

# The suffix is optional on the way in, and both spellings find the same unit.
$out.SuffixAccepted = @(Get-Service 'ssh.service').Count

# A frozen unit: ActiveState is still `active` and Status must say Paused.
$frozen = @(Get-Service chrony)
$out.Frozen = @{
    Status      = if ($frozen.Count) { [string]$frozen[0].Status } else { $null }
    ActiveState = if ($frozen.Count) { $frozen[0].SystemdActiveState } else { $null }
    Freezer     = if ($frozen.Count) { $frozen[0].SystemdFreezerState } else { $null }
}

# A masked unit is Windows' Disabled; a systemd-disabled one is Windows' Manual.
$masked = @(Get-Service cups)
$disabled = @(Get-Service zfs-mount)
$out.StartTypeMapping = @{
    Masked   = if ($masked.Count) { [string]$masked[0].StartType } else { $null }
    Disabled = if ($disabled.Count) { [string]$disabled[0].StartType } else { $null }
}

# A name that matches nothing is a NON-terminating error, as on Windows: the
# other names still come back.
$err = @()
$both = @(Get-Service -Name 'ssh', 'nosuchthing' -ErrorAction SilentlyContinue -ErrorVariable +err)
$out.MissingName = @{ Returned = $both.Count; Errors = $err.Count }

# --- the power verbs, and the whole point of this file ---------------------
Reset-CwCalls
Restart-Computer -Confirm:$false
$out.RestartComputer = @{ Calls = @(Get-CwCalls) }

Reset-CwCalls
Stop-Computer -Confirm:$false
$out.StopComputer = @{ Calls = @(Get-CwCalls) }

# --- Set-Service: the mask, and the unmask that must come first ------------
Reset-CwCalls
Set-Service -Name ssh -StartupType Disabled -Confirm:$false -WarningAction SilentlyContinue
$out.SetDisabled = @{ Calls = @(Get-CwCalls) }

Set-CwFileState @{ 'ssh.service' = 'masked' }
Reset-CwCalls
Set-Service -Name ssh -StartupType Manual -Confirm:$false
$out.SetManualFromMasked = @{ Calls = @(Get-CwCalls) }

Set-CwFileState @{}
Reset-CwCalls
Set-Service -Name ssh -StartupType Manual -Confirm:$false
$out.SetManualFromEnabled = @{ Calls = @(Get-CwCalls) }

# --- Set-Service -Status, and the freezer ---------------------------------
# The fake has to report ssh FROZEN here, because Suspend-SystemdUnit reads the
# freezer back and throws when it disagrees with what it just asked for. That
# read-back is the point of it, so the fake plays along rather than being
# worked around.
Set-CwFrozen @('ssh.service')
Reset-CwCalls
Set-Service -Name ssh -Status Paused -Confirm:$false
$out.SetPaused = @{ Calls = @(Get-CwCalls) }

# --- Suspend/Resume ask for freeze/thaw -----------------------------------
Reset-CwCalls
Suspend-Service -Name ssh -Confirm:$false
$out.Suspend = @{ Calls = @(Get-CwCalls) }

Set-CwFrozen @()
Reset-CwCalls
Resume-Service -Name ssh -Confirm:$false
$out.Resume = @{ Calls = @(Get-CwCalls) }

# --- Set-TimeZone converts a WINDOWS id ------------------------------------
Set-TimeZone -Id 'W. Europe Standard Time' -Confirm:$false
$out.TimeZoneFromWindowsId = Get-CwTimeZone
Set-TimeZone -Id 'Europe/Berlin' -Confirm:$false
$out.TimeZoneFromIanaId = Get-CwTimeZone

# --- Rename-Computer refuses a joined machine ------------------------------
Set-CwJoined $true
Reset-CwCalls
try {
    Rename-Computer -NewName 'renamed' -Confirm:$false -ErrorAction Stop
    $out.RenameJoined = @{ Threw = $false; Message = $null; Calls = @(Get-CwCalls) }
}
catch {
    $out.RenameJoined = @{
        Threw = $true; Message = $_.Exception.Message; Calls = @(Get-CwCalls)
    }
}

# --- the shadow notice, which is P1's objection made audible ---------------
# It must fire exactly where PowerShell really has a cmdlet of that name --
# which is TRUE on a Windows host and FALSE on an OS/7 machine today -- and it
# must fire once per session and not on every call.
& (Get-Module OS7) { $script:OS7CompatShadowNoticed = @() }
$w1 = @()
Get-Service ssh -WarningVariable +w1 -WarningAction SilentlyContinue | Out-Null
$w2 = @()
Get-Service ssh -WarningVariable +w2 -WarningAction SilentlyContinue | Out-Null
$out.ShadowNotice = @{
    CmdletExistsHere = (@(Get-Command Get-Service -CommandType Cmdlet -ErrorAction SilentlyContinue).Count -gt 0)
    Warned           = ($w1.Count -gt 0)
    WarnedTwice      = ($w2.Count -gt 0)
    Text             = $(if ($w1.Count) { [string]$w1[0] } else { $null })
}

# --- Get-ComputerInfo answers with Windows' property names -----------------
# On a non-Linux host most values are $null; what is checked here is the SHAPE
# and the -Property filter, which is what a copied script depends on.
$ci = Get-ComputerInfo
$out.ComputerInfo = @{
    Properties = @($ci.PSObject.Properties.Name | Sort-Object)
    Filtered   = @((Get-ComputerInfo -Property 'Cs*').PSObject.Properties.Name |
        Where-Object { $_ -notlike 'Cs*' })
}

$out | ConvertTo-Json -Depth 8 -Compress
"""


def run_driver():
    if not shutil.which("pwsh"):
        sys.exit("pwsh is not on this host; this check needs it and nothing else")
    import tempfile
    fd, path = tempfile.mkstemp(suffix=".ps1")
    os.close(fd)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(DRIVER)
    try:
        p = subprocess.run(
            ["pwsh", "-NoProfile", "-NonInteractive", "-File", path,
             "-SystemdManifest", SYSTEMD, "-OS7Manifest", OS7],
            capture_output=True, encoding="utf-8", errors="replace")
    finally:
        os.unlink(path)
    lines = [l for l in (p.stdout or "").splitlines() if l.strip().startswith("{")]
    if not lines:
        sys.exit("the driver produced no JSON:\n"
                 + (p.stdout or "")[-3000:] + "\n" + (p.stderr or "")[-3000:])
    return json.loads(lines[-1])


def main():
    if "--show-refusals" in sys.argv:
        for k in sorted(WINDOWS_PARAMETERS):
            print(k)
        return 0

    print("\n### the Windows compatibility layer\n")
    d = run_driver()

    # --- the surface ------------------------------------------------------
    print("  the fourteen names, and their parameter sets against Windows'\n")
    for name, wp in sorted(WINDOWS_PARAMETERS.items()):
        got = d["Surface"].get(name)
        if not check(got is not None, f"{name} exists in the OS7 module"):
            continue
        check(got["Type"] == "Function", f"{name} is a function", got["Type"])

        want = set(wp.split())
        have = set(got["Parameters"])
        missing = sorted(want - have)
        check(not missing,
              f"{name} declares every parameter Windows has",
              "missing: " + ", ".join(missing) if missing else "")
        extra = sorted(have - want - OS7_ADDITIONS.get(name, set()))
        check(not extra,
              f"{name} declares nothing Windows does not have, beyond its named additions",
              "extra: " + ", ".join(extra) if extra else "")

    # --- the refusal table ------------------------------------------------
    print("\n  the refusal table: reachable, real, and it throws\n")
    tables = d["Tables"]
    unsupported = tables["Unsupported"]
    check(len(unsupported) > 0, "the module carries a refusal table",
          f"{len(unsupported)} rows")

    for key in sorted(unsupported):
        cmdlet, param = key.split(":", 1)
        declared = d["Surface"].get(cmdlet)
        check(declared is not None and param in declared["Parameters"],
              f"{key} is reachable — {cmdlet} declares -{param}")
        check(param in set(WINDOWS_PARAMETERS.get(cmdlet, "").split()),
              f"{key} is real — Windows' {cmdlet} has -{param}")
        r = d["Refusals"].get(key, {})
        check(r.get("Threw") is True, f"{key} throws when passed",
              r.get("Type") or "returned quietly")
        check(r.get("Threw") and r.get("Type") == "NotSupportedException",
              f"{key} throws NotSupportedException", r.get("Type"))
        # The reason has to say something. A refusal with an empty explanation
        # is the same dead end as no refusal at all.
        check(len(unsupported[key]) > 40,
              f"{key} carries a reason worth reading",
              f"{len(unsupported[key])} chars")

    # --- the mapping tables ----------------------------------------------
    print("\n  the mappings: total, and only in Windows' words\n")
    st = tables["StartType"]
    check(set(st.values()) <= WINDOWS_STARTMODE,
          "every StartType produced is one of Windows' five",
          ", ".join(sorted(set(st.values()) - WINDOWS_STARTMODE)))
    uncovered = sorted(SYSTEMD_UNIT_FILE_STATES - set(st))
    check(not uncovered,
          "every systemd unit-file state has a StartType",
          "uncovered: " + ", ".join(uncovered) if uncovered else "")

    status = tables["Status"]
    check(set(status.values()) <= WINDOWS_STATUS,
          "every Status produced is one of Windows' seven",
          ", ".join(sorted(set(status.values()) - WINDOWS_STATUS)))
    uncovered = sorted(SYSTEMD_ACTIVE_STATES - set(status))
    check(not uncovered,
          "every systemd active state has a Status",
          "uncovered: " + ", ".join(uncovered) if uncovered else "")

    startup = tables["Startup"]
    check(startup.get("Automatic") == "Enabled",
          "Automatic means enable", startup.get("Automatic"))
    check(startup.get("Manual") == "Disabled",
          "Manual means disable — not at boot, still startable by hand",
          startup.get("Manual"))
    check(startup.get("Disabled") == "Masked",
          "Disabled means MASK — which is what 'cannot be started' means here",
          startup.get("Disabled"))
    check(len(tables["Names"]) == 14,
          "the module names its own fourteen", str(len(tables["Names"])))

    # --- Get-Service ------------------------------------------------------
    print("\n  Get-Service, over a fake systemd\n")
    gs = d["GetService"]
    check(gs["Count"] == 1, "Get-Service ssh returns one service", str(gs["Count"]))
    check(gs["Name"] == "ssh",
          "Name is the bare Windows-style name", gs["Name"])
    check(gs["Unit"] == "ssh.service",
          "and the unit name is kept beside it as Unit", gs["Unit"])
    check(gs["Status"] == "Running", "an active unit is Running", gs["Status"])
    check(gs["StartType"] == "Automatic",
          "an enabled unit is Automatic", gs["StartType"])
    check(gs["DisplayName"] == "ssh.service" or bool(gs["DisplayName"]),
          "DisplayName carries the unit's description", gs["DisplayName"])
    check(gs["TypeName"] == "OS7.Compat.Windows.ServiceController",
          "the object carries the type name the format file selects on",
          gs["TypeName"])
    for kept in ("SystemdActiveState", "SystemdSubState", "SystemdFreezerState",
                 "SystemdUnitFileState"):
        check(kept in gs["SystemdKept"],
              f"systemd's own words survive the translation — {kept}")
    check(d["SuffixAccepted"] == 1,
          "'ssh.service' finds the same unit as 'ssh'", str(d["SuffixAccepted"]))

    fr = d["Frozen"]
    check(fr["Status"] == "Paused",
          "A FROZEN UNIT IS Paused — the whole reason Status does not come from "
          "the unit state", fr["Status"])
    check(fr["ActiveState"] == "active",
          "...while systemd still calls it active (measured on a machine)",
          fr["ActiveState"])
    check(fr["Freezer"] == "frozen", "...and the freezer is reported as itself",
          fr["Freezer"])

    stm = d["StartTypeMapping"]
    check(stm["Masked"] == "Disabled",
          "a masked unit is Windows' Disabled", stm["Masked"])
    check(stm["Disabled"] == "Manual",
          "a systemd-disabled unit is Windows' Manual, because it still starts "
          "by hand", stm["Disabled"])

    mn = d["MissingName"]
    check(mn["Returned"] == 1 and mn["Errors"] >= 1,
          "a name that matches nothing is a NON-terminating error and the other "
          "names still come back", f"returned {mn['Returned']}, errors {mn['Errors']}")

    # --- the power verbs --------------------------------------------------
    print("\n  the power verbs — the defect this file exists for\n")
    rc = " ; ".join(d["RestartComputer"]["Calls"])
    check("systemctl reboot" in rc,
          "Restart-Computer asks for `systemctl reboot`", rc)
    check("shutdown" not in rc,
          "...and NEVER reaches `shutdown`, whose flagless action is poweroff", rc)
    check("poweroff" not in rc,
          "...and never asks for poweroff", rc)
    sc = " ; ".join(d["StopComputer"]["Calls"])
    check("systemctl poweroff" in sc,
          "Stop-Computer asks for `systemctl poweroff`, explicitly", sc)

    # --- Set-Service ------------------------------------------------------
    print("\n  Set-Service: the mask, and the unmask that has to come first\n")
    sd = d["SetDisabled"]["Calls"]
    check(any("mask" in c and "unmask" not in c for c in sd),
          "-StartupType Disabled masks the unit", " ; ".join(sd))
    sm = d["SetManualFromMasked"]["Calls"]
    unmask_at = next((i for i, c in enumerate(sm) if "unmask" in c), None)
    disable_at = next((i for i, c in enumerate(sm) if "disable" in c), None)
    check(unmask_at is not None,
          "-StartupType Manual on a MASKED unit unmasks it", " ; ".join(sm))
    check(unmask_at is not None and disable_at is not None and unmask_at < disable_at,
          "...and unmasks BEFORE disabling — `disable` does not unmask",
          " ; ".join(sm))
    se = d["SetManualFromEnabled"]["Calls"]
    check(not any("unmask" in c for c in se),
          "...and does not unmask a unit that was not masked", " ; ".join(se))
    sp = d["SetPaused"]["Calls"]
    check(any("freeze" in c for c in sp),
          "-Status Paused freezes", " ; ".join(sp))

    su = d["Suspend"]["Calls"]
    check(any("freeze" in c for c in su), "Suspend-Service freezes", " ; ".join(su))
    rs = d["Resume"]["Calls"]
    check(any("thaw" in c for c in rs), "Resume-Service thaws", " ; ".join(rs))

    # --- Set-TimeZone -----------------------------------------------------
    print("\n  Set-TimeZone: a Windows zone id is converted, an IANA one is not\n")
    check(d["TimeZoneFromWindowsId"] == "Europe/Berlin",
          "'W. Europe Standard Time' reaches the time layer as 'Europe/Berlin'",
          str(d["TimeZoneFromWindowsId"]))
    check(d["TimeZoneFromIanaId"] == "Europe/Berlin",
          "'Europe/Berlin' passes through unchanged",
          str(d["TimeZoneFromIanaId"]))

    # --- Rename-Computer --------------------------------------------------
    print("\n  Rename-Computer on a joined machine\n")
    rj = d["RenameJoined"]
    check(rj["Threw"] is True,
          "a joined machine is REFUSED — the keytab holds the old name")
    check(rj["Threw"] and "Remove-OS7Domain" in (rj["Message"] or ""),
          "...and the refusal names the way through", rj.get("Message"))
    check(not rj["Calls"],
          "...before anything was asked of the machine",
          " ; ".join(rj["Calls"]))

    # --- the shadow notice ------------------------------------------------
    print("\n  the shadow notice — P1's objection, made audible\n")
    sn = d["ShadowNotice"]
    check(sn["Warned"] == sn["CmdletExistsHere"],
          "it warns exactly when PowerShell really has a cmdlet of that name",
          f"cmdlet here: {sn['CmdletExistsHere']}, warned: {sn['Warned']}")
    check(sn["WarnedTwice"] is False,
          "...once per session, and not on every call")
    if sn["CmdletExistsHere"]:
        check("Microsoft.PowerShell.Management" in (sn["Text"] or ""),
              "...and it says where the real one is", sn.get("Text"))

    # --- Get-ComputerInfo -------------------------------------------------
    print("\n  Get-ComputerInfo\n")
    ci = d["ComputerInfo"]
    for p in ("CsName", "CsTotalPhysicalMemory", "OsName", "OsUptime",
              "BiosFirmwareType", "CsNumberOfLogicalProcessors"):
        check(p in ci["Properties"], f"it answers under Windows' name {p}")
    check(not ci["Filtered"],
          "-Property 'Cs*' returns only the Cs properties",
          ", ".join(ci["Filtered"]))

    total = len(FAILS)
    print(f"\n  {'RED' if total else 'GREEN'}: {total} failed\n")
    if total:
        for f in FAILS:
            print(f"    FAIL  {f}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
