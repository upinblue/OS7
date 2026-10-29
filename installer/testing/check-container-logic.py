#!/usr/bin/env python3
"""
The container DECISIONS (docs/CONTAINERS-PLAN.md CT6, CT8, P6, CT5), in
seconds, with no engine.

    ./check-container-logic.py           the cases, against a fake engine
    ./check-container-logic.py --prove   and then plant each defect the cases
                                         exist for, in a copy, and require RED

WHAT IT CHECKS. What OS/7's layer CONCLUDES about containers: which ones need
attention and which do not, who can reach a published port, what a container
was configured to do beside what it is doing, and how a read is refused when
the socket is root's. It says nothing about what the engine sends — that is
Test-DockerModule's, against recordings of two real engines.

THE CASES THAT MUST READ AS FINE ARE THE POINT. A container somebody stopped
on purpose exits 143 (SIGTERM) or 137 (SIGKILL after the stop's timeout), and
a rule that read those as failures would fill the attention view with every
stopped service — the failure check-service-logic.py paid for on systemd
units, where a field that cries wolf gets ignored and is then wrong about the
broken machine too. So the stopped cases are enumerated as carefully as the
broken ones, and one of the planted defects is exactly that rule.

THE ENGINE IS FAKED AT THE DOCKER MODULE'S OWN SEAM. Every case is the
RECORDED inspect object of a real container (engine-29.1.3.jsonl, the
archive's engine on an installed OS/7 machine) with its State, HostConfig and
NetworkSettings rewritten — so the shape is the engine's and only the
situation is constructed. The fake answers /version, the list, inspect and
the four lifecycle verbs, and keeps state across them.

WHERE THE CODE UNDER TEST LIVES. powershell/OS7/OS7.Container.ps1, which the
OS7 module already dot-sources. The harness dot-sources it AGAIN into the
module's scope, after the import, so that OS7_CONTAINER_MODULE can point at a
planted copy and that copy's functions are the ones the cmdlets resolve — which
is how --prove works. (It lived in powershell/OS7-pending/ for one afternoon,
while another session had the module's lists open.)
"""

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DOCKER = os.path.join(REPO, "powershell", "Docker", "Docker.psd1")
OS7 = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")
FIXTURE = os.path.join(REPO, "powershell", "Docker", "tests", "fixtures", "engine-29.1.3.jsonl")


def code_under_test():
    env = os.environ.get("OS7_CONTAINER_MODULE")
    if env:
        return env
    p = os.path.join(REPO, "powershell", "OS7", "OS7.Container.ps1")
    if not os.path.exists(p):
        sys.exit(f"no {p}")
    return p


FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


# ---------------------------------------------------------------------------
# The world. One recorded container, rewritten into each situation.
# ---------------------------------------------------------------------------
def recorded():
    with open(FIXTURE, encoding="utf-8") as f:
        lines = [json.loads(l) for l in f if l.strip()]
    version = next(x for x in lines[1:] if x["method"] == "GET" and x["path"] == "/version")
    for x in lines[1:]:
        if x["method"] == "GET" and x["path"].endswith("/json") and x["status"] == 200 \
                and x["path"].startswith("/containers/"):
            body = json.loads(x["text"])
            if body.get("State", {}).get("Running"):
                return json.loads(version["text"]), body
    sys.exit("the recording has no running container to build cases from")


def ports(*bindings):
    """{"80/tcp": [{"HostIp": .., "HostPort": ..}]} from (cport, ip, hport)."""
    out = {}
    for cport, ip, hport in bindings:
        out.setdefault(cport, []).append({"HostIp": ip, "HostPort": hport})
    return out


def case(base, name, status, *, running=None, exit_code=0, oom=False, error="",
         health=None, streak=0, policy="no", restarts=0, bound=None, configured=None,
         mode="bridge", mounts=None, labels=None):
    c = copy.deepcopy(base)
    c["Name"] = "/" + name
    c["Id"] = (name.encode().hex() + "0" * 64)[:64]
    st = c["State"]
    st.update({
        "Status": status,
        "Running": running if running is not None else status in ("running", "restarting", "paused"),
        "Paused": status == "paused",
        "Restarting": status == "restarting",
        "OOMKilled": oom,
        "Dead": status == "dead",
        "ExitCode": exit_code,
        "Error": error,
    })
    if health:
        st["Health"] = {"Status": health, "FailingStreak": streak, "Log": []}
    else:
        st.pop("Health", None)
    c["RestartCount"] = restarts
    c["HostConfig"]["RestartPolicy"] = {"Name": policy, "MaximumRetryCount": 0}
    c["HostConfig"]["NetworkMode"] = mode
    c["HostConfig"]["PortBindings"] = configured if configured is not None else (bound or {})
    c["NetworkSettings"]["Ports"] = bound or {}
    c["Mounts"] = mounts or []
    c["Config"]["Labels"] = labels or {}
    return c


# name, expected State, NeedsAttention, what Reachable must contain (or None
# for "nothing published"), why. EVERY ROW is one rule of CT6 or CT8.
EXPECT = [
    ("web", "Running", False, "all networks", "running, published on 0.0.0.0 and :: — ONE entry, not two"),
    ("db", "Running", False, "this machine only", "running, published on 127.0.0.1"),
    ("api-v6", "Running", False, "all networks", "published on :: alone is every address too"),
    ("api-noaddr", "Running", False, "all networks", "a binding with an EMPTY address is every address"),
    ("admin", "Running", False, "only on 10.0.0.5", "published on one address"),
    ("hostnet", "Running", False, "every port it opens", "host network: nothing published and EVERYTHING reachable"),
    ("app-starting", "Starting", False, None, "health check not decided yet is not a problem"),
    ("app-unhealthy", "Unhealthy", True, None, "running, and its own health check says unhealthy"),
    ("worker", "RestartLoop", True, None, "the engine says restarting"),
    ("batch", "Failed", True, None, "exited 2"),
    ("cache", "OutOfMemory", True, None, "OOMKilled with exit 137 — NOT a stop, though 137 is a stop's code"),
    ("proxy", "StartFailed", True, None, "the engine could not start it: port already allocated"),
    ("svc-term", "Stopped", False, None, "exited 143 with restart policy always: somebody stopped it"),
    ("svc-kill", "Stopped", False, None, "exited 137, not OOM: a stop that timed out"),
    ("svc-clean", "Stopped", False, None, "exited 0 under unless-stopped"),
    ("fresh", "Created", False, None, "created, never started"),
    ("frozen", "Paused", False, None, "paused is a deliberate act"),
    ("zombie", "Dead", True, None, "the engine's own dead"),
    ("future", "Unknown", True, None, "a status this OS/7 does not know is not one it may call fine"),
]


def build_world():
    version, base = recorded()
    allp = ports(("80/tcp", "0.0.0.0", "8080"), ("80/tcp", "::", "8080"))
    w = {
        "web": case(base, "web", "running", policy="always", bound=allp,
                    labels={"com.docker.compose.project": "shop"},
                    mounts=[{"Type": "volume", "Name": "web-data", "Destination": "/data"},
                            {"Type": "volume", "Name": "a" * 64, "Destination": "/cache"}]),
        "db": case(base, "db", "running", policy="unless-stopped",
                   bound=ports(("5432/tcp", "127.0.0.1", "5432"))),
        "api-v6": case(base, "api-v6", "running", bound=ports(("443/tcp", "::", "8443"))),
        "api-noaddr": case(base, "api-noaddr", "running", bound=ports(("443/tcp", "", "9443"))),
        "admin": case(base, "admin", "running", bound=ports(("8443/tcp", "10.0.0.5", "8443"))),
        "hostnet": case(base, "hostnet", "running", mode="host"),
        "app-starting": case(base, "app-starting", "running", health="starting"),
        "app-unhealthy": case(base, "app-unhealthy", "running", health="unhealthy", streak=5),
        "worker": case(base, "worker", "restarting", exit_code=1, restarts=14, policy="always"),
        "batch": case(base, "batch", "exited", exit_code=2),
        "cache": case(base, "cache", "exited", exit_code=137, oom=True, policy="always"),
        "proxy": case(base, "proxy", "exited", exit_code=128, policy="always",
                      error="driver failed programming external connectivity on endpoint proxy: "
                            "Bind for 0.0.0.0:80 failed: port is already allocated",
                      configured=ports(("80/tcp", "", "80"))),
        "svc-term": case(base, "svc-term", "exited", exit_code=143, policy="always",
                         configured=ports(("8080/tcp", "", "8081"))),
        "svc-kill": case(base, "svc-kill", "exited", exit_code=137),
        "svc-clean": case(base, "svc-clean", "exited", exit_code=0, policy="unless-stopped"),
        "fresh": case(base, "fresh", "created", running=False),
        "frozen": case(base, "frozen", "paused"),
        "zombie": case(base, "zombie", "dead", running=False, exit_code=255),
        "future": case(base, "future", "hibernating", running=False),
    }
    return version, w


# ---------------------------------------------------------------------------
# The PowerShell half: the fake engine, and every question asked through the
# OS/7 cmdlets.
# ---------------------------------------------------------------------------
HARNESS = r"""
param([string]$WorldFile, [string]$CodeFile, [string]$DockerPsd, [string]$Os7Psd)
$ErrorActionPreference = 'Stop'
# BUILD-NOTES #146, on the pwsh side this time: with stdout redirected, pwsh on
# Windows writes in the console's code page, so the arrow in "8080 → 80/tcp"
# arrived as \x1a - a control character json.loads refuses - and the check died
# before asserting anything on the Windows host. Decoding as UTF-8 in Python is
# only half of it; the writer has to write UTF-8 too.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Import-Module $DockerPsd -Force
Import-Module $Os7Psd -Force
$os7 = Get-Module OS7
. $os7 { param($p) . $p } $CodeFile

# #148's guard, RECORDED rather than obeyed: every verb that changes the
# machine must call it with its own name, and the check must run the same as
# root or not, on Linux or not. Defined in the module's own scope, after the
# file, so it replaces the real one for this process only.
. $os7 {
    $script:__asserted = [System.Collections.Generic.List[string]]::new()
    function Assert-OS7Elevated { param([string]$Cmdlet, [string]$Because) $script:__asserted.Add($Cmdlet) }
}

$doc = Get-Content -Raw -LiteralPath $WorldFile | ConvertFrom-Json -AsHashtable
$state = @{ world = $doc.world; version = $doc.version; denied = $false }

$fake = {
    param($m, $target, $json)
    if ($state.denied) {
        throw [System.UnauthorizedAccessException]::new('/var/run/docker.sock refused the account (fake).')
    }
    $path = ($target -replace '^/v\d+\.\d+', '') -replace '\?.*$', ''
    $reply = { param($code, $obj)
        [pscustomobject]@{ StatusCode = $code; ContentType = 'application/json'; Bytes = $null
            Text = $(if ($null -ne $obj) { $obj | ConvertTo-Json -Depth 30 -Compress } else { '' }) } }
    $none = { param($n) & $reply 404 @{ message = "No such container: $n" } }
    if ($path -eq '/version') { return & $reply 200 $state.version }
    if ($m -eq 'GET' -and $path -eq '/containers/json') {
        return & $reply 200 @($state.world.Values | ForEach-Object {
            @{ Id = $_.Id; Names = @($_.Name); State = $_.State.Status } })
    }
    if ($path -match '^/containers/([^/]+)(/(\w+))?$') {
        $n = $Matches[1]; $verb = $Matches[3]
        $c = $state.world[$n]
        if ($null -eq $c) { return & $none $n }
        $s = $c.State
        if ($m -eq 'GET' -and $verb -eq 'json') { return & $reply 200 $c }
        if ($m -eq 'POST' -and $verb -eq 'start') {
            if ($s.Running) { return & $reply 304 $null }
            $s.Status = 'running'; $s.Running = $true; $s.ExitCode = 0; $s.Error = ''; $s.OOMKilled = $false
            return & $reply 204 $null
        }
        if ($m -eq 'POST' -and $verb -eq 'stop') {
            if (-not $s.Running) { return & $reply 304 $null }
            $s.Status = 'exited'; $s.Running = $false; $s.ExitCode = 143
            return & $reply 204 $null
        }
        if ($m -eq 'POST' -and $verb -eq 'restart') {
            $s.Status = 'running'; $s.Running = $true; $s.ExitCode = 0
            return & $reply 204 $null
        }
        if ($m -eq 'DELETE' -and -not $verb) {
            if ($s.Running -and $target -notmatch 'force=1') {
                return & $reply 409 @{ message = "cannot remove container ${n}: container is running: stop the container before removing or force remove" }
            }
            $state.world.Remove($n)
            return & $reply 204 $null
        }
    }
    throw "fake engine: nothing answers $m $target"
}.GetNewClosure()

$docker = Get-Module Docker
. $docker { param($sb) $script:DockerTransportOverride = $sb; $script:DockerNegotiated = @{} } $fake

$pick = { param($o) [ordered]@{
    Name = $o.Name; State = $o.State; NeedsAttention = $o.NeedsAttention; Reason = $o.Reason
    Command = $o.Command; Reachable = $o.Reachable; Ports = @($o.Ports | ForEach-Object Text)
    PortsConfigured = @($o.PortsConfigured | ForEach-Object Text); RestartPolicy = $o.RestartPolicy
    EngineStatus = $o.EngineStatus; Application = $o.Application } }

$out = [ordered]@{}
$out.all = @(& $os7 { Get-OS7Container -All } | ForEach-Object { & $pick $_ })
$out.attention = @(& $os7 { Get-OS7Container 6>$null } | ForEach-Object Name)
$out.one = & $pick (& $os7 { Get-OS7Container -Name 'proxy' })

# Every Command a verdict offers names a function that EXISTS, with
# parameters it HAS — #127's shape, pointed at the sentences this file writes.
$out.commands = @($out.all | Where-Object { $_.Command } | ForEach-Object {
    $cmd = $_.Command
    $ok = $true; $why = ''
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$null)
        foreach ($call in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $verb = $call.GetCommandName()
            $fn = & $os7 { param($v) Get-Command -Name $v -ErrorAction SilentlyContinue } $verb
            if (-not $fn) { $ok = $false; $why = "no command $verb"; continue }
            foreach ($el in $call.CommandElements) {
                if ($el -is [System.Management.Automation.Language.CommandParameterAst] -and
                    -not $fn.Parameters.ContainsKey($el.ParameterName)) {
                    $ok = $false; $why = "$verb has no -$($el.ParameterName)" }
            }
        }
    } catch { $ok = $false; $why = $_.Exception.Message }
    [ordered]@{ Name = $_.Name; Command = $cmd; Ok = $ok; Why = $why } })

$act = [ordered]@{}
$act.startFailed = & $os7 { Start-OS7Container -Name 'batch' -Confirm:$false }
$act.startRunning = & $os7 { Start-OS7Container -Name 'web' -Confirm:$false }
$act.stopStopped = & $os7 { Stop-OS7Container -Name 'svc-clean' -Confirm:$false }
$act.stopRunning = & $os7 { Stop-OS7Container -Name 'db' -Confirm:$false }
$act.restart = & $os7 { Restart-OS7Container -Name 'worker' -Confirm:$false }
$act.removeRunning = $null
try { $null = & $os7 { Remove-OS7Container -Name 'web' -Confirm:$false } } catch { $act.removeRunning = $_.Exception.Message }
$act.removeForced = & $os7 { Remove-OS7Container -Name 'web' -Force -Confirm:$false }
$act.goneAfter = $null
try { $null = & $os7 { Get-OS7Container -Name 'web' } } catch { $act.goneAfter = $_.Exception.GetType().Name }
$out.actions = $act
$out.asserted = @(& $os7 { $script:__asserted } | Sort-Object -Unique)

$state.denied = $true
$out.denied = $null
try { $null = & $os7 { Get-OS7Container -All } } catch { $out.denied = [ordered]@{ Type = $_.Exception.GetType().Name; Message = $_.Exception.Message } }

$out | ConvertTo-Json -Depth 8
"""


def run_harness(code):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        sys.exit("pwsh is not on PATH")
    version, world = build_world()
    tmp = tempfile.mkdtemp(prefix="os7-container-logic-")
    try:
        wf = os.path.join(tmp, "world.json")
        with open(wf, "w", encoding="utf-8") as f:
            json.dump({"version": version, "world": world}, f)
        hf = os.path.join(tmp, "harness.ps1")
        with open(hf, "w", encoding="utf-8") as f:
            f.write(HARNESS)
        p = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", hf,
                            "-WorldFile", wf, "-CodeFile", code, "-DockerPsd", DOCKER, "-Os7Psd", OS7],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    out = p.stdout
    start = out.find("{")
    if p.returncode != 0 or start < 0:
        return None, (p.stdout + p.stderr)[-3000:]
    try:
        return json.loads(out[start:]), None
    except ValueError as e:
        return None, f"{e}\n{out[-2000:]}"


def evaluate(r):
    """Every assertion, against one harness run. Returns nothing; FAILS fills."""
    rows = {x["Name"]: x for x in r["all"]}

    print("  CT6 — the state of each container, and whether it needs attention")
    for name, state, attention, reach, why in EXPECT:
        x = rows.get(name)
        if not check(x is not None, f"{name}: listed by -All"):
            continue
        check(x["State"] == state and x["NeedsAttention"] == attention,
              f"{name}: {state}, attention={attention} — {why}",
              f"{x['State']}, attention={x['NeedsAttention']}")
        if attention:
            check(bool(x["Reason"]) and bool(x["Command"]), f"{name}: a sentence and a command",
                  f"{x['Reason']!r} / {x['Command']!r}")

    print("  the default view")
    want = sorted(n for n, _, a, _, _ in EXPECT if a)
    check(sorted(r["attention"]) == want, "without -All: exactly the containers that need attention",
          ", ".join(sorted(r["attention"])))

    print("  CT8 — who can reach a published port")
    for name, _, _, reach, why in EXPECT:
        x = rows.get(name)
        if x is None:
            continue
        if reach:
            check(reach in (x["Reachable"] or ""), f"{name}: '{reach}' — {why}", x["Reachable"])
        elif name not in ("proxy", "svc-term"):
            check(not x["Reachable"], f"{name}: nothing published, nothing claimed", x["Reachable"])
    check(len(rows["web"]["Ports"]) == 1, "web: 0.0.0.0 and :: of one port are ONE entry",
          "; ".join(rows["web"]["Ports"]))

    print("  P6 — configured beside effective, never merged")
    check(rows["svc-term"]["Ports"] == [] and len(rows["svc-term"]["PortsConfigured"]) == 1,
          "a stopped container: no port published NOW, one CONFIGURED", str(rows["svc-term"]["PortsConfigured"]))
    check(rows["svc-term"]["RestartPolicy"] == "always" and rows["svc-term"]["State"] == "Stopped",
          "restart policy always beside state Stopped — both shown, neither overriding the other")
    check("already allocated" in (r["one"]["Reason"] or ""),
          "StartFailed carries the engine's own reason", r["one"]["Reason"])
    check(rows["web"]["Application"] == "shop", "the Compose project is read off its label",
          str(rows["web"]["Application"]))

    print("  every command a verdict offers exists, with parameters it has (#127)")
    for c in r["commands"]:
        check(c["Ok"], f"{c['Name']}: {c['Command']}", c["Why"])

    print("  the lifecycle verbs, read back as OS/7 states")
    a = r["actions"]
    check(a["startFailed"]["Outcome"] == "Started" and a["startFailed"]["State"] == "Running",
          "start a failed container: Started, and now Running", f"{a['startFailed']['Outcome']}/{a['startFailed']['State']}")
    check(a["startRunning"]["Outcome"] == "AlreadyRunning",
          "start a running one: AlreadyRunning, from the engine's 304", a["startRunning"]["Outcome"])
    check(a["stopStopped"]["Outcome"] == "AlreadyStopped", "stop a stopped one: AlreadyStopped", a["stopStopped"]["Outcome"])
    check(a["stopRunning"]["Outcome"] == "Stopped" and a["stopRunning"]["State"] == "Stopped",
          "stop a running one: and the 143 it leaves reads as Stopped, not Failed",
          f"{a['stopRunning']['Outcome']}/{a['stopRunning']['State']}")
    check(a["restart"]["State"] == "Running", "restart the restart loop: Running afterwards", a["restart"]["State"])
    check(a["removeRunning"] is not None and "stop the container" in a["removeRunning"],
          "removing a running container is refused in the engine's words", str(a["removeRunning"])[:90])
    check(a["removeForced"]["State"] == "Removed" and a["removeForced"].get("KeptVolumes") == ["web-data", "a" * 64],
          "removed with -Force: and the volumes it kept are NAMED, anonymous ones included without -RemoveVolumes",
          str(a["removeForced"].get("KeptVolumes")))
    check(a["goneAfter"] == "ItemNotFoundException", "and asked for afterwards it is not found", str(a["goneAfter"]))
    verbs = ["Remove-OS7Container", "Restart-OS7Container", "Start-OS7Container", "Stop-OS7Container"]
    check(sorted(r["asserted"]) == verbs,
          "every verb that changes something calls #148's guard, by its own name", ", ".join(r["asserted"]))

    print("  CT5 — reading is root's, and the refusal says how to elevate an OS/7 verb")
    d = r["denied"] or {}
    m = d.get("Message", "")
    check(d.get("Type") == "InvalidOperationException" and "must run as root" in m
          and "sudo pwsh -NoProfile -c 'Get-OS7Container" in m and "DOES NOT WORK" in m,
          "a socket refusal reads as #148's sentence, with the sudo pwsh -c form", m.split("\n")[0][:100])


def layering(code):
    """P2-docker and the other rules, asked of the file's own directory."""
    env = dict(os.environ, OS7_LAYER3=os.path.dirname(code))
    p = subprocess.run([sys.executable, os.path.join(HERE, "check-layering.py")], env=env,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    held = "P2-docker: HELD" in p.stdout
    check(p.returncode == 0 and held, "the file reaches the engine only through powershell/Docker (P2-docker)",
          "held" if held else p.stdout[-300:])


# Each planted defect, the text it replaces, and the case that must go red.
PLANTS = [
    ("OOM read after the signal rule — 137 means a stop",
     "\tif ($oom) {\n\t\treturn & $verdict 'OutOfMemory'",
     "\tif ($false -and $oom) {\n\t\treturn & $verdict 'OutOfMemory'", "cache: OutOfMemory"),
    ("a stop's exit code read as a failure — the attention view cries wolf",
     "$script:OS7ContainerSignalExits = @(130, 137, 143)",
     "$script:OS7ContainerSignalExits = @()", "svc-term: Stopped"),
    ("'::' read as one address",
     "-or $HostIp -eq '0.0.0.0' -or $HostIp -eq '::')",
     "-or $HostIp -eq '0.0.0.0')", "api-v6: 'all networks'"),
    ("the default view shows everything",
     "if ($set -eq 'Attention' -and -not $o.NeedsAttention) { continue }",
     "", "without -All: exactly the containers that need attention"),
    ("an unknown status called fine",
     "return & $verdict 'Unknown' $true",
     "return & $verdict 'Unknown' $false", "future: Unknown"),
    ("the start-failure rule removed — an always container that cannot start reads as Failed",
     "if (-not [string]::IsNullOrWhiteSpace($err)) {",
     "if ($false) {", "proxy: StartFailed"),
    ("the read refusal without the elevation form",
     "\"      sudo pwsh -NoProfile -c '$Cmdlet <parameters>'`n\" +",
     "\"`n\" +", "a socket refusal reads as #148's sentence"),
]


def prove(code):
    print("\n--prove: each defect planted in a copy, each required to turn the check RED")
    with open(code, encoding="utf-8") as f:
        src = f.read()
    bad = []
    for what, old, new, must in PLANTS:
        if src.count(old) != 1:
            bad.append(f"{what}: the text to replace occurs {src.count(old)} times")
            continue
        tmp = tempfile.mkdtemp(prefix="os7-container-plant-")
        try:
            planted = os.path.join(tmp, "OS7.Container.ps1")
            with open(planted, "w", encoding="utf-8", newline="\n") as f:
                f.write(src.replace(old, new))
            saved = list(FAILS)
            r, err = run_harness(planted)
            if r is None:
                fired = [f"the harness died: {err[-200:]}"]
            else:
                FAILS.clear()
                import io, contextlib
                with contextlib.redirect_stdout(io.StringIO()):
                    evaluate(r)
                fired = list(FAILS)
            FAILS[:] = saved
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        hit = any(must in f for f in fired)
        print(f"      {'RED ' if hit else 'MISS'}  {what}   [{len(fired)} red: {'; '.join(fired)[:110]}]")
        if not hit:
            bad.append(what)
    for b in bad:
        FAILS.append("--prove: " + b)


def main():
    # And #146 on the Python side: the expected strings carry the same arrow, and
    # printing them to a redirected stdout on Windows (cp1252) is a traceback.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    code = code_under_test()
    print(f"container decisions: {os.path.relpath(code, REPO)}, against a fake engine "
          f"built from {os.path.relpath(FIXTURE, REPO)}\n")
    r, err = run_harness(code)
    if r is None:
        print(err)
        sys.exit("the harness did not run to the end")
    evaluate(r)
    layering(code)
    if "--prove" in sys.argv:
        prove(code)
    print(f"\n{len(FAILS)} failed" if FAILS else "\ncheck-container-logic: GREEN")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
