#!/usr/bin/env python3
"""
The Tailscale role's DECISIONS (docs/VENDOR-APPS-PLAN.md VA9-VA16), in
seconds, with no Tailscale, no apt, no ZFS and no root.

    ./check-tailscale-logic.py           the cases
    ./check-tailscale-logic.py --prove   and then plant each defect the cases
                                         exist for, in a copy, and require RED

WHAT IT CHECKS. What OS7.Tailscale.ps1 CONCLUDES and in which ORDER it acts:

  * what an administrator is told (Get-OS7TailscaleAttention), for sixteen
    situations a machine can be in — the healthy one as carefully as the
    broken ones, because an attention list that is never empty is one nobody
    reads;
  * what Install-OS7Tailscale will do on a fresh machine, a machine it made, a
    documented install with and without -Adopt, a reinstall that kept its
    identity, and a broken mount — and that the dataset always comes before
    the package and the daemon is stopped before its state is copied;
  * the login job's command, run for real against the generic module's
    replayed CLI: the key as a FILE PATH built from $CREDENTIALS_DIRECTORY,
    and a THROW when the login failed, because the job runner counts only a
    throw (M-TS7);
  * Connect-OS7Tailscale: the daemon's word is the result, not the job's, and
    the two preferences are set AFTER the login, because a login replaces
    what `up` has no flag for (O-M2, measured 2026-11-10);
  * Set-OS7Tailscale and the generic layer refusing to switch Tailscale SSH or
    the client's updater ON (VA7, VA14);
  * Uninstall-OS7Tailscale: never `purge` (M-TS12), the unit unmasked after
    `remove`, the dataset destroyed only when asked.

WHAT IT DOES NOT CHECK. What the CLI prints — that is Test-TailscaleModule's,
against recordings of tailscale 1.104.5 — and anything that needs the machine:
the adoption's file moves, ZFS, apt, systemd. Those are owed to a bench run
(docs/VENDOR-APPS-PLAN.md §7 step 8, docs/SESSION-TAILSCALE-ROLE.md §7), and
until it happens nothing here says the role works on a machine.

HOW. The generic Tailscale module is imported and its CLI seam replays the
recorded fixtures; the OS7 module is imported and OS7.Tailscale.ps1 is
dot-sourced AGAIN into its scope (OS7_TAILSCALE_ROLE points at a planted copy
for --prove); the side effects the role reaches for — Start-OS7Job, apt,
systemd, ZFS — are replaced in the module's scope by stubs that record the
call. Both root guards are stubbed too, so the check runs as any account on
any host with pwsh.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
TS = os.path.join(REPO, "powershell", "Tailscale", "Tailscale.psd1")
APT = os.path.join(REPO, "powershell", "Apt", "Apt.psd1")
OS7 = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")
FIX = os.path.join(REPO, "powershell", "Tailscale", "tests", "fixtures")

FAILS = []


def code_under_test():
    env = os.environ.get("OS7_TAILSCALE_ROLE")
    if env:
        return env
    p = os.path.join(REPO, "powershell", "OS7", "OS7.Tailscale.ps1")
    if not os.path.exists(p):
        sys.exit(f"no {p}")
    return p


HARNESS = r"""
param([string]$CodeFile, [string]$TsPsd, [string]$AptPsd, [string]$Os7Psd, [string]$Fixtures)
$ErrorActionPreference = 'Stop'
Import-Module $TsPsd -Force
Import-Module $AptPsd -Force
Import-Module $Os7Psd -Force 3>$null
$os7 = Get-Module OS7
$ts = Get-Module Tailscale
. $os7 { param($p) . $p } $CodeFile
# The login job imports Tailscale BY NAME, as it must on a machine, where the
# module is in /usr/local/share/powershell/Modules. Import-Module by name
# searches PSModulePath and does NOT take a module already loaded by path, so
# the repository's powershell/ goes on it here.
$env:PSModulePath = (Split-Path -Parent (Split-Path -Parent $TsPsd)) + [IO.Path]::PathSeparator + $env:PSModulePath

$results = [System.Collections.Generic.List[object]]::new()
function Check([string]$name, [bool]$ok, $detail = '') {
	$results.Add([ordered]@{ Name = $name; Ok = $ok; Detail = [string]$detail })
}
function Fx([string]$name) {
	$read = { param($ext) $p = Join-Path $Fixtures "$name.$ext"; if (Test-Path $p) { [IO.File]::ReadAllText($p) } else { '' } }
	[pscustomobject]@{ StdOut = (& $read 'out'); StdErr = (& $read 'err'); ExitCode = [int]((& $read 'rc').Trim()) }
}
function Edited([string]$name, [string]$pattern, [string]$replacement) {
	$f = Fx $name
	$f.StdOut = [regex]::Replace($f.StdOut, $pattern, $replacement)
	return $f
}
$ok0 = [pscustomobject]@{ StdOut = ''; StdErr = ''; ExitCode = 0 }

# ONE LOG for everything, in call order: the CLI the generic layer runs, and
# the side effects the stubs below record.
$log = [System.Collections.Generic.List[string]]::new()
function Replay([hashtable]$map) {
	$log.Clear()
	. $ts {
		param($m, $l)
		$script:TailscaleCommandOverride = {
			param($a)
			$l.Add('ts: ' + ($a -join ' '))
			$r = $m[$a[0]]
			if ($null -eq $r) { [pscustomobject]@{ StdOut = ''; StdErr = "no replay for $($a[0])"; ExitCode = 1 } } else { $r }
		}.GetNewClosure()
	} $map $log
}
function Parsed([string]$verb, $fixture) {
	Replay @{ $verb = $fixture }
	if ($verb -eq 'status') { return (Get-TailscaleStatus) }
	return (Get-TailscalePreference)
}

# The stubs. Root guards first, so the check runs as anybody.
. $ts { function script:Assert-TailscaleElevated { param($Cmdlet, $Because) } }
. $os7 {
	param($l)
	$script:__log = $l
	$script:__facts = $null
	$script:__factsQueue = [System.Collections.Generic.Queue[object]]::new()
	$script:__secrets = @('tailscale-authkey')
	$script:__jobThrows = $false
	$script:__jobRecord = $null
	$script:__jobInput = $null
	function script:Assert-OS7Elevated { param($Cmdlet, $Because) }
	function script:Get-OS7TailscaleFacts { if ($script:__factsQueue.Count) { $script:__factsQueue.Dequeue() } else { $script:__facts } }
	function script:Get-OS7Secret { $script:__secrets | ForEach-Object { [pscustomobject]@{ Name = $_ } } }
	function script:Start-OS7Job {
		[CmdletBinding(SupportsShouldProcess)] param($Name, $Command, $InputObject, $Secret, $TimeoutSec)
		$script:__log.Add("job: $Name secret=$($Secret -join ',')")
		$script:__jobInput = $InputObject
		$script:__jobCommand = $Command
		if ($script:__jobThrows) { throw "job '$Name' (tailscale-login-x) could not be started: unit failed" }
		[pscustomobject]@{ Id = 'tailscale-login-x'; Unit = 'os7-job@tailscale-login-x.service' }
	}
	function script:Get-OS7Job { param($Id, $Days) $script:__jobRecord }
	function script:Get-OS7Tailscale { [pscustomobject]@{ PSTypeName = 'OS7.Tailscale'; Stub = $true } }
	function script:Remove-AptPackage { [CmdletBinding(SupportsShouldProcess)] param($Name, [switch]$Purge) $script:__log.Add("apt-remove: $Name purge=$([bool]$Purge)") }
	function script:Unregister-OS7PackageSource { [CmdletBinding(SupportsShouldProcess)] param($Name) $script:__log.Add("unregister: $Name") }
	function script:Remove-ZfsDataset { [CmdletBinding(SupportsShouldProcess)] param($Name, [switch]$Recurse) $script:__log.Add("zfs-destroy: $Name recurse=$([bool]$Recurse)") }
	function script:Import-OS7ZfsLayer { }
	function script:Save-OS7PackageBaseline { [CmdletBinding(SupportsShouldProcess)] param($Reason) $script:__log.Add("baseline: $Reason") }
	function script:Get-SystemdUnit { param($Name) [pscustomobject]@{ Name = $Name; LoadState = 'masked'; ActiveState = 'inactive'; SubState = 'dead'; StartupType = 'masked' } }
	function script:Set-SystemdUnitStartup { param($Name, $Startup) $script:__log.Add("startup: $Name $Startup") }
} $log

# =============================================================================
# The facts a healthy machine has; every case changes some of them.
# =============================================================================
$running = Parsed status (Fx 'status-running')
$prefsOff = Parsed debug (Fx 'prefs-local-choices')
function Facts([hashtable]$change = @{}) {
	$f = [ordered]@{
		Package        = [pscustomobject]@{ Package = 'tailscale'; Version = '1.104.5'; Installed = $true }
		Policy         = [pscustomobject]@{ Package = 'tailscale'; Installed = '1.104.5'; Candidate = '1.104.5'; InstalledOrigin = 'pkgs.tailscale.com' }
		Registered     = [pscustomobject]@{ Name = 'tailscale'; Verified = $true; Attention = @() }
		VendorHost     = 'pkgs.tailscale.com'
		OtherSources   = @()
		Dataset        = [pscustomobject]@{ Name = 'tailscale'; Dataset = 'rpool/DATA/lib/tailscale'; MountPoint = '/var/lib/tailscale'; CanMount = 'on'; Mounted = $true; InBootEnvironment = $false }
		StateDirectory = $true
		StateFile      = $true
		Unit           = [pscustomobject]@{ Name = 'tailscaled.service'; LoadState = 'loaded'; ActiveState = 'active'; SubState = 'running'; StartupType = 'enabled' }
		Version        = [pscustomobject]@{ Version = '1.104.5' }
		Status         = $running
		Preference     = $prefsOff
		Now            = [datetime]::Parse('2026-11-10T12:00:00Z').ToUniversalTime()
	}
	foreach ($k in $change.Keys) { $f[$k] = $change[$k] }
	return [pscustomobject]$f
}
function Attention([hashtable]$change = @{}) {
	$f = Facts $change
	return (& $os7 { param($x) Get-OS7TailscaleAttention -Facts $x } $f)
}
function Has($j, [string]$text) { [bool](@($j.Attention | Where-Object { $_ -like "*$text*" }).Count) }

# =============================================================================
# 1. What an administrator is told
# =============================================================================
$j = Attention
Check 'A1 healthy: nothing needs attention' ($j.Attention.Count -eq 0) ($j.Attention -join ' | ')
Check 'A1 healthy: the firewall note, apart from attention' ([bool](@($j.Notes | Where-Object { $_ -like '*firewall does not filter*' }).Count)) ($j.Notes -join ' | ')
Check 'A1 healthy: layout OS7' ($j.Layout -eq 'OS7') $j.Layout

$j = Attention @{ Preference = (Parsed debug (Fx 'prefs-running')) }
Check 'A2 updater on (the tailnet default after a login): reported' (Has $j 'own updater is ON') ($j.Attention -join ' | ')
Check 'A2 and the command that switches it off' (Has $j 'Set-OS7Tailscale -TailscaleAutoUpdate $false')

$j = Attention @{ Preference = (Parsed debug (Edited 'prefs-running' '"Apply":\s*true' '"Apply": null')) }
Check 'A3 updater NOT DECIDED while logged in: reported — $null is not off' (Has $j 'not decided on this machine') ($j.Attention -join ' | ')

$j = Attention @{ Status = (Parsed status (Fx 'status-loggedout')); Preference = (Parsed debug (Fx 'prefs-fresh')) }
Check 'A4 logged out: told to log in' (Has $j 'not logged in to a tailnet') ($j.Attention -join ' | ')
Check 'A4 logged out: an undecided updater is not nagged about' (-not (Has $j 'not decided'))
Check 'A4 logged out: no firewall note (not on a tailnet)' (-not @($j.Notes | Where-Object { $_ -like '*firewall*' }).Count)

$j = Attention @{ Preference = (Parsed debug (Fx 'prefs-ssh')) }
Check 'A5 Tailscale SSH on: reported, with PAM and AD named' ((Has $j 'Tailscale SSH is ON') -and (Has $j 'account checks') -and (Has $j 'Active Directory')) ($j.Attention -join ' | ')
Check 'A5 and the command that switches it off' (Has $j 'Set-OS7Tailscale -TailscaleSsh $false')

$j = Attention @{ Dataset = $null; StateDirectory = $true }
Check 'A6 state in the boot environment: InBootEnvironment, -Adopt named' ($j.Layout -eq 'InBootEnvironment' -and (Has $j 'Install-OS7Tailscale -Adopt')) "$($j.Layout) | $($j.Attention -join ' | ')"

$broken = [pscustomobject]@{ Name = 'tailscale'; Dataset = 'rpool/DATA/lib/tailscale'; MountPoint = '/var/lib/tailscale'; CanMount = 'on'; Mounted = $false; InBootEnvironment = $false }
$j = Attention @{ Dataset = $broken }
Check 'A7 dataset not mounted: Broken, and why it matters' ($j.Layout -eq 'Broken' -and (Has $j 'lands in the boot environment')) "$($j.Layout) | $($j.Attention -join ' | ')"

$doc = [pscustomobject]@{ File = '/etc/apt/sources.list.d/tailscale.list'; Class = 'Unregistered'; Hosts = @('pkgs.tailscale.com') }
$j = Attention @{ Registered = $null; OtherSources = @($doc) }
Check 'A8 unregistered source: the vendor''s file named' (Has $j '/etc/apt/sources.list.d/tailscale.list') ($j.Attention -join ' | ')

$down = [pscustomobject]@{ Name = 'tailscaled.service'; LoadState = 'loaded'; ActiveState = 'inactive'; SubState = 'dead'; StartupType = 'enabled' }
$j = Attention @{ Unit = $down; Status = (Parsed status (Fx 'status-nodaemon')); Preference = $null }
Check 'A9 daemon stopped: the state and Start-Service' ((Has $j 'tailscaled is inactive/dead') -and (Has $j 'Start-Service tailscaled')) ($j.Attention -join ' | ')
Check 'A9 and not also "does not answer"' (-not (Has $j 'does not answer'))

$j = Attention @{ Status = (Parsed status (Fx 'status-nodaemon')); Preference = $null }
Check 'A10 daemon active and not answering: said so, with the CLI''s sentence' (Has $j "running and does not answer: failed to connect") ($j.Attention -join ' | ')

$j = Attention @{ Status = (Parsed status (Fx 'status-stopped')) }
Check 'A11 `down`: enrolled and switched off' (Has $j 'switched off') ($j.Attention -join ' | ')

$j = Attention @{ Status = (Parsed status (Fx 'status-needslogin')); Preference = (Parsed debug (Fx 'prefs-fresh')) }
Check 'A12 a login waiting: the URL' (Has $j 'waiting for a person: https://headscale.os7.test:8443/register/') ($j.Attention -join ' | ')

$soon = Parsed status (Edited 'status-running' '"Self":\s*\{' '"Self": {"KeyExpiry": "2026-11-13T09:00:00Z",')
$late = Parsed status (Edited 'status-running' '"Self":\s*\{' '"Self": {"KeyExpiry": "2027-02-01T09:00:00Z",')
$j = Attention @{ Status = $soon }
Check 'A13 a key that expires in three days: said, with the date' (Has $j 'expires 2026-11-13') ($j.Attention -join ' | ')
$j = Attention @{ Status = $late }
Check 'A13 a key that expires in three months: not attention' (-not (Has $j 'expires'))

$j = Attention @{ Package = $null; Status = $null; Preference = $null; Unit = $null }
Check 'A14 removed with its identity kept: nothing to do, the dataset noted' ($j.Attention.Count -eq 0 -and [bool](@($j.Notes | Where-Object { $_ -like '*is kept*' }).Count)) "$($j.Attention -join ' | ') / $($j.Notes -join ' | ')"

$unver = [pscustomobject]@{ Name = 'tailscale'; Verified = $false; Attention = @('its index has not verified since 2026-11-01: NO_PUBKEY 458CA832957F5868') }
$j = Attention @{ Registered = $unver }
Check 'A15 source not verifying: carried into the role''s report' (Has $j 'Its package source: its index has not verified') ($j.Attention -join ' | ')

$sick = Parsed status (Edited 'status-running' '"Health":\s*\[\s*\]' '"Health": ["could not connect to the control server"]')
$j = Attention @{ Status = $sick }
Check 'A16 a health message while running: carried' (Has $j 'Tailscale reports: could not connect to the control server') ($j.Attention -join ' | ')

# =============================================================================
# 2. What Install-OS7Tailscale will do
# =============================================================================
function Plan([hashtable]$change, [switch]$Adopt) {
	$f = Facts $change
	return (& $os7 { param($x, $a) Get-OS7TailscaleInstallPlan -Facts $x -Adopt:$a } $f ([bool]$Adopt))
}
function Before($steps, [string]$a, [string]$b) {
	$ia = [array]::IndexOf([string[]]$steps, $a); $ib = [array]::IndexOf([string[]]$steps, $b)
	return ($ia -ge 0 -and $ib -ge 0 -and $ia -lt $ib)
}
$fresh = @{ Package = $null; Registered = $null; Dataset = $null; StateDirectory = $false; StateFile = $false; Unit = $null; Version = $null; Status = $null; Preference = $null; Policy = $null }

$p = Plan $fresh
$want = 'dataset-at-state-directory register-source unmask-unit install-package start-daemon preferences-off baseline'
Check 'P1 fresh machine: dataset, source, package, daemon, preferences, baseline — in that order' (($p.Steps -join ' ') -eq $want) ($p.Steps -join ' ')
Check 'P1 fresh: Installed' ($p.Outcome -eq 'Installed') $p.Outcome

$documented = @{ Registered = $null; Dataset = $null; StateDirectory = $true; OtherSources = @($doc) }
$p = Plan $documented
Check 'P2 documented install without -Adopt: refused, the boot environment named' ([bool]$p.Refusal -and $p.Refusal -like '*boot environment*' -and $p.Refusal -like '*-Adopt*') $p.Refusal
Check 'P2 and nothing planned' ($p.Steps.Count -eq 0)

$p = Plan $documented -Adopt
$s = $p.Steps
Check 'P3 -Adopt: the daemon stopped before its state is copied' (Before $s 'stop-daemon' 'copy-state') ($s -join ' ')
Check 'P3 -Adopt: the dataset exists before the copy, the old directory moves before the dataset takes its place' ((Before $s 'dataset-at-temporary-mount' 'copy-state') -and (Before $s 'copy-state' 'set-old-state-aside') -and (Before $s 'set-old-state-aside' 'dataset-at-state-directory'))
Check 'P3 -Adopt: the vendor''s source removed before the release''s is registered' (Before $s 'remove-source:/etc/apt/sources.list.d/tailscale.list' 'register-source')
Check 'P3 -Adopt: the installed package is kept, not reinstalled' (-not ($s -contains 'install-package'))
Check 'P3 -Adopt: the old copy goes only after the daemon runs from the dataset' (Before $s 'start-daemon' 'remove-old-state')
Check 'P3 -Adopt: Adopted' ($p.Outcome -eq 'Adopted') $p.Outcome

$p = Plan @{}
Check 'P4 a machine OS/7 made: only the daemon, the preferences and the baseline, AlreadyInstalled' ((($p.Steps -join ' ') -eq 'start-daemon preferences-off baseline') -and $p.Outcome -eq 'AlreadyInstalled') "$($p.Steps -join ' ') $($p.Outcome)"

$p = Plan @{ Package = $null; Registered = $null; Dataset = $null; StateDirectory = $false; OtherSources = @($doc) }
Check 'P5 the vendor''s source file and no package: refused without -Adopt, the file named' ([bool]$p.Refusal -and $p.Refusal -like '*tailscale.list*') $p.Refusal

$p = Plan @{ Package = $null; Registered = $null; Unit = $null; Status = $null; Preference = $null }
Check 'P6 reinstall that kept its identity: the dataset reused, not made again' ((($p.Steps -join ' ') -eq 'register-source unmask-unit install-package start-daemon preferences-off baseline') -and $p.Outcome -eq 'Installed') "$($p.Steps -join ' ') $($p.Outcome)"

$p = Plan @{ Dataset = $null; StateDirectory = $true }
Check 'P7 registered, but the state in the boot environment: refused without -Adopt' ([bool]$p.Refusal -and $p.Refusal -like '*boot environment*') $p.Refusal

$p = Plan @{ Dataset = $broken }
Check 'P8 dataset not mounted: repaired by mounting it, not refused' (-not $p.Refusal -and $p.Steps[0] -eq 'dataset-at-state-directory') "$($p.Refusal) $($p.Steps -join ' ')"

foreach ($case in @(@{ n = 'fresh'; c = $fresh; a = $false }, @{ n = 'adopt'; c = $documented; a = $true }, @{ n = 'reinstall'; c = @{ Package = $null; Registered = $null } ; a = $false })) {
	$pp = Plan $case.c -Adopt:$case.a
	$s = [string[]]$pp.Steps
	$ds = [array]::IndexOf($s, 'dataset-at-state-directory'); $inst = [array]::IndexOf($s, 'install-package'); $reg = [array]::IndexOf($s, 'register-source')
	$ok = ($inst -lt 0 -or (($ds -lt 0 -or $ds -lt $inst) -and ($reg -lt 0 -or $reg -lt $inst))) -and (Before $s 'start-daemon' 'preferences-off')
	Check "P9 $($case.n): never a package before its dataset or its source; preferences after the daemon" $ok ($s -join ' ')
}

# =============================================================================
# 3. The login job's command, run against the replayed CLI
# =============================================================================
$cmd = & $os7 { $script:OS7TailscaleLoginCommand }
Check 'J0 the command is a constant: it reads $OS7JobInput and $env:CREDENTIALS_DIRECTORY, unexpanded' ($cmd -like '*$OS7JobInput*' -and $cmd -like '*$env:CREDENTIALS_DIRECTORY*')
$sb = [scriptblock]::Create($cmd)
$env:CREDENTIALS_DIRECTORY = '/run/credentials/os7-job@t.service'
$OS7JobInput = [pscustomobject]@{ secret = 'tailscale-authkey'; loginServer = 'https://headscale.os7.test:8443'; hostname = 'web01'; tags = @('tag:os7-bench'); acceptDns = $false; timeoutSec = 60 }
Replay @{ up = (Fx 'up-badkey') }
$threw = $null
try { $null = & $sb 2>$null } catch { $threw = $_.Exception.Message }
$up = [string](@($log | Where-Object { $_ -like 'ts: up *' }) | Select-Object -First 1)
Check 'J1 a refused key: the job THROWS, with Tailscale''s sentence (the runner counts only a throw)' ($threw -like '*invalid pre auth key*') $threw
Check 'J1 the key is a FILE under $CREDENTIALS_DIRECTORY' ($up -like '* --auth-key=file:/run/credentials/os7-job@t.service/tailscale-authkey *') $up
Check 'J1 and the input document''s values, as flags' ($up -like '*--login-server=https://headscale.os7.test:8443*' -and $up -like '*--hostname=web01*' -and $up -like '*--advertise-tags=tag:os7-bench*' -and $up -like '*--accept-dns=false*') $up
Replay @{ up = $ok0 }
$threw = $null
try { $out = & $sb 2>$null } catch { $threw = $_.Exception.Message }
Check 'J2 a login that worked: no throw' ($null -eq $threw) $threw
$OS7JobInput = [pscustomobject]@{ secret = 'tailscale-authkey'; loginServer = $null; hostname = $null; tags = @(); acceptDns = $null; timeoutSec = 60 }
Replay @{ up = $ok0 }
try { $null = & $sb 2>$null } catch { }
$up = [string](@($log | Where-Object { $_ -like 'ts: up *' }) | Select-Object -First 1)
Check 'J3 nothing given, nothing passed: no login server, tags or DNS flag' ($up -notlike '*--login-server*' -and $up -notlike '*--advertise-tags*' -and $up -notlike '*--accept-dns*') $up
Remove-Item Env:CREDENTIALS_DIRECTORY

# =============================================================================
# 4. Connect-OS7Tailscale
#
# EVERY CMDLET IS CALLED INSIDE THE MODULE'S SCOPE. A call from here resolves
# to the function the module EXPORTED at import, not to the one the planted
# copy re-defined, so a defect planted in a cmdlet's body would never run —
# measured: five plants came back MISS until this helper existed.
# =============================================================================
function Call([string]$verb, [hashtable]$params = @{}) {
	& $os7 {
		param($v, $p)
		$e = $null; $iv = $null
		try { $null = & $v @p -Confirm:$false -InformationVariable iv 6>$null 2>$null 3>$null }
		catch { $e = $_.Exception.Message }
		[pscustomobject]@{ Err = $e; Info = ((@($iv) | ForEach-Object { [string]$_.MessageData }) -join ' ') }
	} $verb $params
}
function SetFacts($f) { . $os7 { param($x) $script:__facts = $x; $script:__factsQueue.Clear() } $f }
function SetJob([bool]$throws, $record) { . $os7 { param($t, $r) $script:__jobThrows = $t; $script:__jobRecord = $r } $throws $record }
$loggedOut = Parsed status (Fx 'status-loggedout')
$jobOk = [pscustomobject]@{ Id = 'tailscale-login-x'; Name = 'tailscale-login'; Result = 0; Error = $null }

SetFacts (Facts @{ Status = $loggedOut; Preference = (Parsed debug (Fx 'prefs-fresh')) })
SetJob $false $jobOk
Replay @{ status = (Fx 'status-running'); set = $ok0; debug = (Fx 'prefs-local-choices') }
$err = (Call 'Connect-OS7Tailscale' @{ AuthKeySecret = 'tailscale-authkey'; LoginServer = 'https://headscale.os7.test:8443' }).Err
$order = [string[]]@($log)
$iJob = -1
for ($i = 0; $i -lt $order.Count; $i++) { if ($iJob -lt 0 -and $order[$i] -like 'job: tailscale-login*') { $iJob = $i } }
$iSet = @(for ($i = 0; $i -lt $order.Count; $i++) { if ($order[$i] -like 'ts: set *') { $i } })
Check 'C1 a key from the store: the login runs as a JOB with the secret' ($null -eq $err -and $iJob -ge 0 -and $order[$iJob] -like '*secret=tailscale-authkey*') "$err | $($order -join ' / ')"
Check 'C1 no `up` in the caller''s process — the key never reaches it' (-not @($order | Where-Object { $_ -like 'ts: up *' }).Count)
Check 'C1 the preferences set only AFTER the login (a login resets them, O-M2)' ($iJob -ge 0 -and $iSet.Count -ge 1 -and @($iSet | Where-Object { $_ -lt $iJob }).Count -eq 0 -and $order[$iSet[-1]] -eq 'ts: set --ssh=false --auto-update=false') ($order -join ' / ')
$ji = & $os7 { $script:__jobInput }
$jt = ($ji | ConvertTo-Json -Compress)
Check 'C1 the job''s input names the secret and carries no key' ($null -ne $ji -and $ji['secret'] -eq 'tailscale-authkey' -and $jt -notmatch 'tskey|hskey') $jt
Check 'C1 the job''s command is the constant, not text built from parameters' ((& $os7 { $script:__jobCommand }) -ceq (& $os7 { $script:OS7TailscaleLoginCommand }))

SetFacts (Facts @{ Status = $loggedOut; Preference = (Parsed debug (Fx 'prefs-fresh')) })
SetJob $false $jobOk
Replay @{ status = (Fx 'status-loggedout'); set = $ok0; debug = (Fx 'prefs-fresh') }
$err = (Call 'Connect-OS7Tailscale' @{ AuthKeySecret = 'tailscale-authkey' }).Err
Check 'C2 the job ran and the daemon says NeedsLogin: a refusal — the daemon''s word, not the job''s' ($err -like '*not on the tailnet*NeedsLogin*') $err

SetFacts (Facts @{ Status = $loggedOut; Preference = (Parsed debug (Fx 'prefs-fresh')) })
SetJob $true ([pscustomobject]@{ Id = 'tailscale-login-x'; Name = 'tailscale-login'; Result = 1; Error = 'tailscale up did not log in: backend error: invalid pre auth key' })
Replay @{ status = (Fx 'status-loggedout') }
$err = (Call 'Connect-OS7Tailscale' @{ AuthKeySecret = 'tailscale-authkey' }).Err
Check 'C3 a failed job: Tailscale''s sentence from the runner''s record, not systemctl''s' ($err -like '*invalid pre auth key*') $err

SetFacts (Facts @{ Dataset = $null; StateDirectory = $true; Status = $loggedOut })
SetJob $false $null
Replay @{}
$err = (Call 'Connect-OS7Tailscale' @{ AuthKeySecret = 'tailscale-authkey' }).Err
Check 'C4 state in the boot environment: refused before any login' ($err -like '*-Adopt*' -and -not @($log | Where-Object { $_ -like 'job:*' }).Count) $err

SetFacts (Facts @{ Status = $loggedOut })
. $os7 { $script:__secrets = @() }
$err = (Call 'Connect-OS7Tailscale' @{ AuthKeySecret = 'tailscale-authkey' }).Err
Check 'C5 no such secret: refused, New-OS7Secret named' ($err -like '*New-OS7Secret*' -and -not @($log | Where-Object { $_ -like 'job:*' }).Count) $err
. $os7 { $script:__secrets = @('tailscale-authkey') }

SetFacts (Facts @{ Status = $loggedOut; Preference = (Parsed debug (Fx 'prefs-fresh')) })
Replay @{ up = (Fx 'up-json-needslogin'); status = (Fx 'status-running'); set = $ok0; debug = (Fx 'prefs-local-choices') }
$c = Call 'Connect-OS7Tailscale' @{ LoginServer = 'https://headscale.os7.test:8443'; TimeoutSec = 10 }
Check 'C6 by URL: the URL is shown to the person' ($null -eq $c.Err -and $c.Info -like '*https://headscale.os7.test:8443/register/*') "$($c.Err) | $($c.Info)"
Check 'C6 by URL: `up --json`, then the daemon asked, then the preferences' ((@($log | ForEach-Object { ($_ -split ' ')[1] }) -join ' ') -like 'up status* set debug*') ($log -join ' / ')

SetFacts (Facts @{ Status = $loggedOut; Preference = (Parsed debug (Fx 'prefs-fresh')) })
Replay @{ up = (Fx 'up-json-needslogin'); status = (Fx 'status-needslogin') }
$c = Call 'Connect-OS7Tailscale' @{ NoWait = $true }
Check 'C7 -NoWait: back at once with the URL, and no preference set before a login happened' ($null -eq $c.Err -and $c.Info -like '*/register/*' -and -not @($log | Where-Object { $_ -like 'ts: set*' }).Count) "$($c.Err) | $($log -join ' / ')"

SetFacts (Facts @{})
Replay @{ status = (Fx 'status-running'); set = $ok0; debug = (Fx 'prefs-local-choices') }
$c = Call 'Connect-OS7Tailscale'
Check 'C8 already connected: no login, the preferences stated again' ($null -eq $c.Err -and -not @($log | Where-Object { $_ -like 'ts: up*' -or $_ -like 'job:*' }).Count -and @($log | Where-Object { $_ -like 'ts: set*' }).Count -eq 1) "$($c.Err) | $($log -join ' / ')"

# =============================================================================
# 5. Switching on is refused, at both layers
# =============================================================================
SetFacts (Facts @{})
Replay @{ set = $ok0; debug = (Fx 'prefs-local-choices') }
$err = (Call 'Set-OS7Tailscale' @{ TailscaleSsh = $true }).Err
Check 'S1 Set-OS7Tailscale -TailscaleSsh $true: refused in OS/7''s words, nothing run' ($err -like '*does not switch Tailscale SSH on*VA14*' -and $log.Count -eq 0) $err
$err = (Call 'Set-OS7Tailscale' @{ TailscaleAutoUpdate = $true }).Err
Check 'S2 Set-OS7Tailscale -TailscaleAutoUpdate $true: refused, nothing run' ($err -like '*does not switch Tailscale''s own updater on*' -and $log.Count -eq 0) $err
$err = (Call 'Set-OS7Tailscale' @{ TailscaleSsh = $false }).Err
Check 'S3 -TailscaleSsh $false: `set --ssh=false`, then the daemon asked back' ($null -eq $err -and ($log -join ' / ') -eq 'ts: set --ssh=false / ts: debug prefs') "$err | $($log -join ' / ')"
$err = $null
try { Set-TailscalePreference -Ssh $true -Confirm:$false 2>$null | Out-Null } catch { $err = $_.Exception.Message }
Check 'S4 and the generic layer refuses it too — no OS/7 verb reaches `set --ssh`' ($err -like '*does not switch Tailscale SSH on*') $err

# =============================================================================
# 6. Uninstall-OS7Tailscale
# =============================================================================
$gone = Facts @{ Package = $null; Registered = $null; Status = $null; Preference = $null; Unit = $null }
function Uninstall([hashtable]$p, $after = $gone) {
	. $os7 { param($b, $a) $script:__factsQueue.Clear(); $script:__factsQueue.Enqueue($b); $script:__factsQueue.Enqueue($a) } (Facts @{}) $after
	Replay @{ logout = $ok0 }
	return (Call 'Uninstall-OS7Tailscale' $p).Err
}
$err = Uninstall @{}
Check 'U1 uninstall: logs out, removes, unmasks, unregisters, records the baseline' ($null -eq $err -and (($log -join ' / ') -eq 'ts: logout / apt-remove: tailscale purge=False / startup: tailscaled.service Unmasked / unregister: tailscale / baseline: Uninstall-OS7Tailscale')) "$err | $($log -join ' / ')"
Check 'U1 never `purge` — the vendor''s postrm empties the dataset (M-TS12)' (-not @($log | Where-Object { $_ -like '*purge=True*' }).Count) ($log -join ' / ')
Check 'U1 the dataset is not touched without -RemoveState' (-not @($log | Where-Object { $_ -like 'zfs-destroy*' }).Count)
$err = Uninstall @{ RemoveState = $true } (Facts @{ Package = $null; Registered = $null; Status = $null; Preference = $null; Unit = $null; Dataset = $null })
Check 'U2 -RemoveState: the dataset destroyed with its snapshots' ($null -eq $err -and @($log | Where-Object { $_ -eq 'zfs-destroy: rpool/DATA/lib/tailscale recurse=True' }).Count -eq 1) "$err | $($log -join ' / ')"
$err = Uninstall @{ RemoveState = $true }
Check 'U2 and a dataset still there afterwards is a refusal, not a success' ($err -like '*still exists*') $err
$err = Uninstall @{ KeepIdentity = $true }
Check 'U3 -KeepIdentity: no logout' ($null -eq $err -and -not @($log | Where-Object { $_ -like 'ts: logout*' }).Count) "$err | $($log -join ' / ')"
$err = (Call 'Uninstall-OS7Tailscale' @{ KeepIdentity = $true; RemoveState = $true }).Err
Check 'U4 -KeepIdentity with -RemoveState: refused as a contradiction' ($err -like '*Choose one*') $err

$results | ConvertTo-Json -Depth 4
"""


def run_harness(code):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        sys.exit("pwsh is not on PATH")
    tmp = tempfile.mkdtemp(prefix="os7-tailscale-logic-")
    try:
        hf = os.path.join(tmp, "harness.ps1")
        with open(hf, "w", encoding="utf-8") as f:
            f.write(HARNESS)
        p = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", hf,
                            "-CodeFile", code, "-TsPsd", TS, "-AptPsd", APT, "-Os7Psd", OS7,
                            "-Fixtures", FIX],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    out = p.stdout
    start = out.find("[")
    if p.returncode != 0 or start < 0:
        return None, (p.stdout + p.stderr)[-3000:]
    try:
        # strict=False: a Detail may carry a refusal's own line breaks.
        return json.loads(out[start:], strict=False), None
    except ValueError as e:
        return None, f"{e}\n{out[-2000:]}"


def evaluate(rows, quiet=False):
    fails = []
    for r in rows:
        if not quiet:
            line = f"      {'ok  ' if r['Ok'] else 'FAIL'}  {r['Name']}"
            if not r["Ok"] and r["Detail"]:
                line += f"   [{r['Detail'][:300]}]"
            print(line)
        if not r["Ok"]:
            fails.append(r["Name"])
    return fails


def layering(code, quiet=False):
    env = dict(os.environ, OS7_LAYER3=os.path.dirname(code), PYTHONIOENCODING="utf-8")
    p = subprocess.run([sys.executable, os.path.join(HERE, "check-layering.py")], env=env,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    ok = p.returncode == 0
    if not quiet:
        print(f"      {'ok  ' if ok else 'FAIL'}  P2-tailscale and P2-apt hold on the role (check-layering.py)")
    return [] if ok else ["layering"]


PLANTS = [
    ("the package installed before its dataset",
     "\t$moving = ($layout -eq 'InBootEnvironment' -and $Facts.StateDirectory)\n",
     "\t$moving = ($layout -eq 'InBootEnvironment' -and $Facts.StateDirectory)\n"
     "\tif (-not $installed) { $steps.Add('install-package') }\n",
     "P9 fresh"),
    ("a documented install installed over, its identity left in the boot environment",
     "\tif ($layout -eq 'InBootEnvironment' -and -not $Adopt) {",
     "\tif ($false) {",
     "P7 registered"),
    ("the state copied while the daemon is still writing it",
     "\t\t$steps.Add('stop-daemon')\n",
     "",
     "P3 -Adopt: the daemon stopped"),
    ("the login job does not throw when the login failed (M-TS7)",
     "if (-not $r.Succeeded) { throw \"tailscale up did not log in: $($r.Error)\" }",
     "",
     "J1 a refused key"),
    ("the preferences set before the login, where `up` resets them (O-M2)",
     "\t$already = $s.Running -and",
     "\t$null = Set-TailscalePreference -Ssh $false -AutoUpdate $false -Confirm:$false\n\t$already = $s.Running -and",
     "C1 the preferences set only AFTER"),
    ("the job's exit taken for the login",
     "\tif (-not $st.Running) {",
     "\tif ($false) {",
     "C2 the job ran"),
    ("an undecided updater called fine",
     "\t\telseif ($null -eq $p.AutoUpdateApply -and -not $p.LoggedOut) {",
     "\t\telseif ($false) {",
     "A3 updater NOT DECIDED"),
    ("Tailscale SSH on, and nothing said",
     "\t\tif ($p.RunSsh) {",
     "\t\tif ($false) {",
     "A5 Tailscale SSH on"),
    ("Set-OS7Tailscale takes -TailscaleSsh $true",
     "\tif ($TailscaleSsh -eq $true) {",
     "\tif ($false) {",
     "S1 Set-OS7Tailscale -TailscaleSsh $true"),
    ("the uninstall purges (M-TS12)",
     "\t\t$null = Remove-AptPackage -Name $script:OS7TailscalePackage -Confirm:$false\n",
     "\t\t$null = Remove-AptPackage -Name $script:OS7TailscalePackage -Purge -Confirm:$false\n",
     "U1 never `purge`"),
    ("a key about to expire not mentioned",
     "if ($s.KeyExpiry -and $s.KeyExpiry -lt $Facts.Now.AddDays(",
     "if ($false -and $s.KeyExpiry -lt $Facts.Now.AddDays(",
     "A13 a key that expires in three days"),
    ("the runner's record ignored when the job fails",
     "$jobError = if ($record -and $record.Error) { [string]$record.Error } else { $startError }",
     "$jobError = $startError",
     "C3 a failed job"),
]


def prove(code):
    print("\n--prove: each defect planted in a copy, each required to turn the check RED")
    with open(code, encoding="utf-8") as f:
        src = f.read()
    bad = []
    for what, old, new, must in PLANTS:
        if src.count(old) != 1:
            bad.append(f"{what}: the text to replace occurs {src.count(old)} times")
            print(f"      MISS  {what}   [the text to replace occurs {src.count(old)} times]")
            continue
        tmp = tempfile.mkdtemp(prefix="os7-tailscale-plant-")
        try:
            planted = os.path.join(tmp, "OS7.Tailscale.ps1")
            with open(planted, "w", encoding="utf-8", newline="\n") as f:
                f.write(src.replace(old, new))
            rows, err = run_harness(planted)
            fired = [f"the harness died: {err[-200:]}"] if rows is None else evaluate(rows, quiet=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        hit = any(must in f for f in fired)
        print(f"      {'RED ' if hit else 'MISS'}  {what}   [{len(fired)} red: {'; '.join(fired)[:120]}]")
        if not hit:
            bad.append(what)
    return ["--prove: " + b for b in bad]


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    code = code_under_test()
    shown = code
    try:
        shown = os.path.relpath(code, REPO)
    except ValueError:
        pass
    print(f"Tailscale role decisions: {shown}, against recorded tailscale 1.104.5 output\n")
    rows, err = run_harness(code)
    if rows is None:
        print(err)
        sys.exit("the harness did not run to the end")
    fails = evaluate(rows)
    fails += layering(code)
    print(f"\n  {len(rows) + 1 - len(fails)} ok, {len(fails)} failed")
    if "--prove" in sys.argv:
        fails += prove(code)
    print(f"\n{len(fails)} failed" if fails else "\ncheck-tailscale-logic: GREEN")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
