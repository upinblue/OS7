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
# The second world (2026-10-30): what the window's v1 asks besides containers —
# applications, images, volumes, networks, a clean-up, the create dialog.
# Container shapes are still the recorded engine's; images, volumes, networks
# and the disk usage are written in the engine's list shapes.
# ---------------------------------------------------------------------------
def img_id(tag):
    return "sha256:" + (tag.encode().hex() + "0" * 64)[:64]


IMAGES = [
    # tag (or None), repo digest at pull (or None), what the registry says now
    ("nginx:1.27", "sha256:" + "a" * 64, "sha256:" + "a" * 64),        # current
    ("postgres:17", "sha256:" + "b" * 64, "sha256:" + "c" * 64),       # the tag moved on
    ("alpine:3.20", "sha256:" + "d" * 64, "error:dial tcp: lookup registry-1.docker.io: no such host"),
    (None, None, None),                                                 # dangling
    ("local/built:1", None, None),                                      # built here
    ("redis:7", "sha256:" + "e" * 64, "sha256:" + "e" * 64),           # unused
]


def build_world2(base):
    def net(name):
        return {name: copy.deepcopy(next(iter(base["NetworkSettings"]["Networks"].values())))}

    def vol(name, dest):
        return {"Type": "volume", "Name": name, "Destination": dest, "Source": f"/var/lib/docker/volumes/{name}/_data"}

    def mk(name, status, image, *, labels=None, mounts=None, network="bridge", bound=None, **kw):
        c = case(base, name, status, labels=labels, mounts=mounts, bound=bound, **kw)
        c["Image"] = img_id(image)
        c["Config"]["Image"] = image
        c["NetworkSettings"]["Networks"] = net(network)
        return c

    def compose(project, service, depends=""):
        l = {"com.docker.compose.project": project, "com.docker.compose.service": service,
             "com.docker.compose.project.working_dir": f"/srv/{project}"}
        if depends:
            l["com.docker.compose.depends_on"] = depends
        return l

    anon_used, anon_free = "c" * 64, "d" * 64
    w = {
        # shop: db <- web <- worker, and the worker is broken
        "shop-worker": mk("shop-worker", "exited", "nginx:1.27", exit_code=1, network="shop_default",
                          labels=compose("shop", "worker", "db:service_healthy:true,web:service_started:false")),
        "shop-web": mk("shop-web", "running", "nginx:1.27", network="shop_default",
                       labels=compose("shop", "web", "db:service_started:false"),
                       mounts=[vol("shop-static", "/usr/share/nginx/html")],
                       bound=ports(("80/tcp", "0.0.0.0", "8080"))),
        "shop-db": mk("shop-db", "running", "postgres:17", network="shop_default",
                      labels=compose("shop", "db"), mounts=[vol("shop-pg", "/var/lib/postgresql/data")]),
        "blog-app": mk("blog-app", "running", "nginx:1.27", labels=compose("blog", "app")),
        "half-a": mk("half-a", "running", "nginx:1.27", labels=compose("half", "a")),
        "half-b": mk("half-b", "exited", "nginx:1.27", exit_code=0, labels=compose("half", "b")),
        "idle-x": mk("idle-x", "exited", "nginx:1.27", exit_code=0, labels=compose("idle", "x")),
        "lone": mk("lone", "exited", "alpine:3.20", exit_code=143, mounts=[vol(anon_used, "/cache")]),
    }
    images = []
    for tag, digest, _ in IMAGES:
        iid = img_id(tag or "dangling")
        repo = tag.rsplit(":", 1)[0] if tag else None
        images.append({"Id": iid, "RepoTags": [tag] if tag else ["<none>:<none>"],
                       "RepoDigests": [f"{repo}@{digest}"] if digest else [],
                       "Size": 100_000_000, "Created": 1_790_000_000, "Containers": -1})
    registry = {tag: now for tag, _, now in IMAGES if tag}
    volumes = []
    for name in ("shop-static", "shop-pg", anon_used, anon_free, "old-data"):
        volumes.append({"Name": name, "Driver": "local", "Mountpoint": f"/var/lib/docker/volumes/{name}/_data",
                        "CreatedAt": "2026-10-30T09:00:00Z", "Labels": None, "Scope": "local"})
    # One volume whose data lives inside the boot environment (O-CT7's shape).
    volumes.append({"Name": "legacy", "Driver": "local", "Mountpoint": "/srv/legacy/_data",
                    "CreatedAt": "2026-10-30T09:00:00Z", "Labels": None, "Scope": "local"})
    networks = [{"Name": n, "Id": (n.encode().hex() + "0" * 64)[:64], "Driver": d, "Scope": "local",
                 "Internal": False, "Labels": {},
                 "IPAM": {"Config": [{"Subnet": s, "Gateway": g}] if s else []}}
                for n, d, s, g in (("bridge", "bridge", "10.213.0.0/24", "10.213.0.1"),
                                   ("host", "host", None, None), ("none", "null", None, None),
                                   ("shop_default", "bridge", "10.214.1.0/24", "10.214.1.1"),
                                   ("stale_net", "bridge", "10.214.2.0/24", "10.214.2.1"))]
    df = {"LayersSize": 600_000_000,
          "Images": [{"Id": i["Id"], "Size": 100_000_000, "SharedSize": 40_000_000, "Containers": -1} for i in images],
          "Containers": [{"Id": c["Id"], "SizeRw": 4096} for c in w.values()],
          "Volumes": [{"Name": v["Name"], "UsageData": {"Size": 2048, "RefCount": 0}} for v in volumes],
          "BuildCache": []}
    return {"world": w, "images": images, "registry": registry, "volumes": volumes,
            "networks": networks, "df": df, "template": copy.deepcopy(base)}


# ---------------------------------------------------------------------------
# The PowerShell half: the fake engine, and every question asked through the
# OS/7 cmdlets.
# ---------------------------------------------------------------------------
HARNESS = r"""
param([string]$WorldFile, [string]$CodeFile, [string]$DockerPsd, [string]$Os7Psd, [string]$TcpFile)
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
    $script:__rootDenied = $false
    function Assert-OS7Elevated {
        param([string]$Cmdlet, [string]$Because)
        $script:__asserted.Add($Cmdlet)
        if ($script:__rootDenied) {
            throw [System.InvalidOperationException]::new("$Cmdlet must run as root: it $Because. This process is uid 1000 (fake).")
        }
    }
}

$doc = Get-Content -Raw -LiteralPath $WorldFile | ConvertFrom-Json -AsHashtable
$state = @{ world = $doc.world; version = $doc.version; denied = $false; noengine = $false
    images = @(); volumes = @(); networks = @(); registry = @{}; df = $null; template = $null
    pulled = [System.Collections.Generic.List[string]]::new(); pullError = $false; created = $null }

$fake = {
    param($m, $target, $json)
    if ($state.noengine) {
        throw [System.IO.FileNotFoundException]::new('There is no Docker engine socket at /var/run/docker.sock (fake).')
    }
    if ($state.denied) {
        throw [System.UnauthorizedAccessException]::new('/var/run/docker.sock refused the account (fake).')
    }
    $path = ($target -replace '^/v\d+\.\d+', '') -replace '\?.*$', ''
    $q = @{}
    if ($target -match '\?(.*)$') {
        foreach ($kv in $Matches[1].Split('&')) {
            if (-not $kv) { continue }
            $two = $kv.Split('=', 2)
            $q[[uri]::UnescapeDataString($two[0])] = [uri]::UnescapeDataString($two[1])
        }
    }
    $reply = { param($code, $obj)
        [pscustomobject]@{ StatusCode = $code; ContentType = 'application/json'; Bytes = $null
            Text = $(if ($null -ne $obj) { ConvertTo-Json -InputObject $obj -Depth 30 -Compress } else { '' }) } }
    $none = { param($n) & $reply 404 @{ message = "No such container: $n" } }
    $say = { param($code, $text) & $reply $code @{ message = $text } }
    if ($path -eq '/version') { return & $reply 200 $state.version }
    if ($path -eq '/_ping') { return [pscustomobject]@{ StatusCode = 200; ContentType = 'text/plain'; Bytes = $null; Text = 'OK' } }
    if ($m -eq 'GET' -and $path -eq '/containers/json') {
        return & $reply 200 @($state.world.Values | ForEach-Object {
            $pp = @()
            $np = $_.NetworkSettings.Ports
            if ($np) {
                foreach ($k in @($np.Keys)) {
                    foreach ($b in @($np[$k])) {
                        if ($b) { $pp += @{ PrivatePort = [int]$k.Split('/')[0]; Type = $k.Split('/')[1]; PublicPort = [int]$b.HostPort; IP = $b.HostIp } }
                    }
                }
            }
            @{ Id = $_.Id; Names = @($_.Name); State = $_.State.Status; ImageID = $_.Image; Image = $_.Config.Image
                Mounts = @($_.Mounts); Labels = $_.Config.Labels; Ports = $pp
                NetworkSettings = @{ Networks = $_.NetworkSettings.Networks } } })
    }
    if ($m -eq 'POST' -and $path -eq '/containers/create') {
        $n = $q['name']
        if ($state.world.ContainsKey($n)) { return & $say 409 "Conflict. The container name `"/$n`" is already in use" }
        $b = $json | ConvertFrom-Json -AsHashtable
        $img = @($state.images | Where-Object { $_.RepoTags -contains $b.Image -or $_.Id -eq $b.Image }) | Select-Object -First 1
        if (-not $img) { return & $say 404 "No such image: $($b.Image)" }
        $c = $state.template | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $c.Name = "/$n"; $c.Id = ([System.Text.Encoding]::UTF8.GetBytes($n) | ForEach-Object { $_.ToString('x2') }) -join ''
        $c.Id = ($c.Id + ('0' * 64)).Substring(0, 64)
        $c.Image = $img.Id; $c.Config.Image = $b.Image
        $c.Config.Labels = if ($b.Labels) { $b.Labels } else { @{} }
        $c.HostConfig.PortBindings = if ($b.HostConfig.PortBindings) { $b.HostConfig.PortBindings } else { @{} }
        $c.HostConfig.RestartPolicy = $b.HostConfig.RestartPolicy
        $c.NetworkSettings.Ports = @{}
        $c.Mounts = @(@($b.HostConfig.Mounts) | Where-Object { $_ } | ForEach-Object { @{ Type = $_.Type; Name = $_.Source; Destination = $_.Target } })
        $c.State.Status = 'created'; $c.State.Running = $false; $c.State.ExitCode = 0; $c.State.Error = ''; $c.State.OOMKilled = $false
        $c.State.Remove('Health')
        $state.created = $b
        $state.world[$n] = $c
        return & $reply 201 @{ Id = $c.Id; Warnings = @() }
    }
    $findImage = { param($ref) @($state.images | Where-Object { $_.RepoTags -contains $ref -or $_.Id -eq $ref }) | Select-Object -First 1 }
    if ($m -eq 'GET' -and $path -eq '/images/json') { return & $reply 200 @($state.images) }
    if ($m -eq 'POST' -and $path -eq '/images/create') {
        $ref = "$($q['fromImage']):$($q['tag'])"
        $state.pulled.Add($ref)
        if ($state.pullError) {
            $text = '{"status":"Pulling from library/ghost"}' + "`r`n" +
                '{"errorDetail":{"message":"manifest for ghost:1 not found: manifest unknown"},"error":"manifest for ghost:1 not found: manifest unknown"}' + "`r`n"
        }
        else {
            $state.images += @{ Id = 'sha256:' + ('f' * 64); RepoTags = @($ref); RepoDigests = @("$($q['fromImage'])@sha256:$('f' * 64)")
                Size = 1; Created = 1790000000; Containers = -1 }
            $text = '{"status":"Pulling from library/x"}' + "`r`n" + '{"status":"Status: Downloaded newer image"}' + "`r`n"
        }
        return [pscustomobject]@{ StatusCode = 200; ContentType = 'application/json'; Bytes = $null; Text = $text }
    }
    if ($path -match '^/images/(.+)/json$' -and $m -eq 'GET') {
        $ref = [uri]::UnescapeDataString($Matches[1]); $i = & $findImage $ref
        if ($i) { return & $reply 200 $i } else { return & $say 404 "No such image: $ref" }
    }
    if ($path -match '^/images/(.+)$' -and $m -eq 'DELETE') {
        $ref = [uri]::UnescapeDataString($Matches[1]); $i = & $findImage $ref
        if (-not $i) { return & $say 404 "No such image: $ref" }
        $users = @($state.world.Values | Where-Object { $_.Image -eq $i.Id })
        if ($users.Count -and $q['force'] -ne '1') { return & $say 409 "conflict: unable to delete $ref (must be forced) - image is being used by container $($users[0].Name)" }
        if (@($users | Where-Object { $_.State.Running }).Count) { return & $say 409 "conflict: unable to delete $ref - image is being used by running container" }
        $state.images = @($state.images | Where-Object { $_.Id -ne $i.Id })
        return & $reply 200 @(@{ Untagged = $ref }, @{ Deleted = $i.Id })
    }
    if ($path -match '^/distribution/(.+)/json$') {
        $ref = [uri]::UnescapeDataString($Matches[1]); $ans = $state.registry[$ref]
        if (-not $ans) { return & $say 404 "manifest unknown: $ref" }
        if ($ans.StartsWith('error:')) { return & $say 500 $ans.Substring(6) }
        return & $reply 200 @{ Descriptor = @{ mediaType = 'application/vnd.oci.image.index.v1+json'; digest = $ans; size = 1 }
            Platforms = @(@{ os = 'linux'; architecture = 'amd64' }) }
    }
    $volUsers = { param($vn) @($state.world.Values | Where-Object { @($_.Mounts | Where-Object { $_.Name -eq $vn }).Count }) }
    if ($m -eq 'GET' -and $path -eq '/volumes') { return & $reply 200 @{ Volumes = @($state.volumes); Warnings = $null } }
    if ($path -match '^/volumes/([^/]+)$') {
        $vn = [uri]::UnescapeDataString($Matches[1]); $v = @($state.volumes | Where-Object { $_.Name -eq $vn }) | Select-Object -First 1
        if ($m -eq 'GET') { if ($v) { return & $reply 200 $v } else { return & $say 404 "get ${vn}: no such volume" } }
        if ($m -eq 'DELETE') {
            if (-not $v) { return & $say 404 "get ${vn}: no such volume" }
            $u = & $volUsers $vn
            if ($u.Count) { return & $say 409 "remove ${vn}: volume is in use - [$($u[0].Id)]" }
            $state.volumes = @($state.volumes | Where-Object { $_.Name -ne $vn })
            return & $reply 204 $null
        }
    }
    $netUsers = { param($nn) @($state.world.Values | Where-Object { $_.NetworkSettings.Networks -and $_.NetworkSettings.Networks.ContainsKey($nn) }) }
    if ($m -eq 'GET' -and $path -eq '/networks') { return & $reply 200 @($state.networks) }
    if ($path -match '^/networks/([^/]+)$') {
        $nn = [uri]::UnescapeDataString($Matches[1]); $n0 = @($state.networks | Where-Object { $_.Name -eq $nn -or $_.Id -eq $nn }) | Select-Object -First 1
        if ($m -eq 'GET') { if ($n0) { return & $reply 200 $n0 } else { return & $say 404 "network $nn not found" } }
        if ($m -eq 'DELETE') {
            if (-not $n0) { return & $say 404 "network $nn not found" }
            if ($n0.Name -in 'bridge', 'host', 'none') { return & $say 403 "$($n0.Name) is a pre-defined network and cannot be removed" }
            if ((& $netUsers $n0.Name).Count) { return & $say 403 "error while removing network: network $($n0.Name) has active endpoints" }
            $state.networks = @($state.networks | Where-Object { $_.Name -ne $n0.Name })
            return & $reply 204 $null
        }
    }
    if ($m -eq 'GET' -and $path -eq '/system/df') { return & $reply 200 $state.df }
    if ($path -match '^/containers/([^/]+)(/(\w+))?$') {
        $n = $Matches[1]; $verb = $Matches[3]
        $c = $state.world[$n]
        if ($null -eq $c) { return & $none $n }
        $s = $c.State
        if ($m -eq 'GET' -and $verb -eq 'json') { return & $reply 200 $c }
        if ($m -eq 'POST' -and $verb -eq 'start') {
            if ($s.Running) { return & $reply 304 $null }
            $s.Status = 'running'; $s.Running = $true; $s.ExitCode = 0; $s.Error = ''; $s.OOMKilled = $false
            $c.NetworkSettings.Ports = $c.HostConfig.PortBindings
            return & $reply 204 $null
        }
        if ($m -eq 'POST' -and $verb -eq 'stop') {
            if (-not $s.Running) { return & $reply 304 $null }
            $s.Status = 'exited'; $s.Running = $false; $s.ExitCode = 143
            $c.NetworkSettings.Ports = @{}
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

# ---------------------------------------------------------------------------
# The second world (2026-10-30): images, volumes, networks, applications, the
# clean-up, the create dialog, the verb table, the operator, the ranges.
# ---------------------------------------------------------------------------
$two = $doc.two
$state.denied = $false
$state.world = $two.world
$state.images = @($two.images); $state.registry = $two.registry; $state.volumes = @($two.volumes)
$state.networks = @($two.networks); $state.df = $two.df; $state.template = $two.template
. $os7 { $script:__asserted.Clear() }
# Where a volume's path lives and whether the backup reaches it, without ZFS:
# the engine's root on its own backed-up dataset, and /srv inside the boot
# environment (O-CT7's shape).
. $os7 {
    function Get-OS7ContainerBackupContext { [pscustomobject]@{ Datasets = @(); Covered = @('rpool/DATA/lib/docker') } }
    function Get-OS7PathDataset {
        param($Path, $Dataset)
        if ("$Path".StartsWith('/var/lib/docker')) { return [pscustomobject]@{ Dataset = 'rpool/DATA/lib/docker'; Mountpoint = '/var/lib/docker'; RelativePath = '' } }
        if ("$Path".StartsWith('/srv/')) { return [pscustomobject]@{ Dataset = 'rpool/ROOT/os7_1.0.0.264'; Mountpoint = '/'; RelativePath = '' } }
        return $null
    }
    function Get-OS7VersionStore { param([string[]]$Dataset) [pscustomobject]@{ Dataset = $Dataset[0]; Snapshots = 12; Oldest = '2026-10-01T00:00:00Z'; Newest = '2026-10-30T10:00:00Z' } }
}
$o2 = [ordered]@{}
$pickImg = { param($i) [ordered]@{ Name = $i.Name; Dangling = $i.Dangling; InUse = $i.InUse; UsedBy = @($i.UsedBy)
    Size = $i.Size; UpdateAvailable = $i.UpdateAvailable; UpdateCheck = $i.UpdateCheck } }
$o2.images = @(& $os7 { Get-OS7ContainerImage } | ForEach-Object { & $pickImg $_ })
$o2.imagesChecked = @(& $os7 { Get-OS7ContainerImage -CheckUpdate } | ForEach-Object { & $pickImg $_ })
$o2.volumes = @(& $os7 { Get-OS7ContainerVolume } | ForEach-Object { [ordered]@{ Name = $_.Name; Anonymous = $_.Anonymous
    InUse = $_.InUse; UsedBy = @($_.UsedBy); BackedUp = $_.BackedUp; InBootEnvironment = $_.InBootEnvironment
    LatestSnapshot = "$($_.LatestSnapshot)"; Reason = $_.Reason } })
$o2.networks = @(& $os7 { Get-OS7ContainerNetwork } | ForEach-Object { [ordered]@{ Name = $_.Name; Builtin = $_.Builtin
    InUse = $_.InUse; UsedBy = @($_.UsedBy); Subnet = @($_.Subnet) } })
$o2.apps = @(& $os7 { Get-OS7ContainerApplication } | ForEach-Object { [ordered]@{ Name = $_.Name; State = $_.State
    Running = $_.Running; Total = $_.Total; Services = @($_.Services) } })
$pickU = { param($u) [ordered]@{ Kind = $u.Kind; Name = $u.Name; Recommended = $u.Recommended } }
$o2.unused = @(& $os7 { Get-OS7ContainerUnused } | ForEach-Object { & $pickU $_ })
$o2.unusedNamed = @(& $os7 { Get-OS7ContainerUnused -IncludeNamedVolumes } | ForEach-Object { & $pickU $_ })

$plan = { param($h) $r = & $os7 { param($x) New-OS7Container @x -ValidateOnly } $h
    [ordered]@{ Validated = $r.Validated; Problems = @($r.Problems); Reachable = $r.Reachable; ImagePresent = $r.ImagePresent
        Volumes = @($r.Volumes); EnvironmentNames = @($r.EnvironmentNames); Json = ($r | ConvertTo-Json -Depth 6 -Compress) } }
$o2.vOk = & $plan @{ Name = 'newweb'; Image = 'nginx:1.27'; Port = @('8081:80'); Volume = @('site:/usr/share/nginx/html'); Environment = @{ SECRET = 'hunter2' } }
$o2.vLocal = & $plan @{ Name = 'newweb2'; Image = 'nginx:1.27'; Port = @('127.0.0.1:8082:80') }
$o2.vTaken = & $plan @{ Name = 'shop-web'; Image = 'nginx:1.27' }
$o2.vBind = & $plan @{ Name = 'x1'; Image = 'nginx:1.27'; Volume = @('/srv/data:/data') }
$o2.vClash = & $plan @{ Name = 'x2'; Image = 'nginx:1.27'; Port = @('8080:80') }
$o2.vEnv = & $plan @{ Name = 'x3'; Image = 'nginx:1.27'; Environment = @{ '1BAD' = 'x' } }
$o2.vPort = & $plan @{ Name = 'x4'; Image = 'nginx:1.27'; Port = @('80') }
$o2.vAbsent = & $plan @{ Name = 'x5'; Image = 'ghost:1' }

$made = & $os7 { New-OS7Container -Name newweb -Image nginx:1.27 -Port '127.0.0.1:8081:80' -Volume 'site:/usr/share/nginx/html' -Environment @{ SECRET = 'hunter2' } -Confirm:$false }
$o2.create = [ordered]@{ Outcome = $made.Outcome; State = $made.State; Reachable = $made.Reachable; Pulled = $made.Pulled
    Json = ($made | ConvertTo-Json -Depth 6 -Compress) }
$o2.createdBody = [ordered]@{ Env = @($state.created.Env); Bindings = $state.created.HostConfig.PortBindings; Mounts = @($state.created.HostConfig.Mounts) }
$state.pullError = $true
$o2.pullFail = $null
try { $null = & $os7 { New-OS7Container -Name ghostly -Image ghost:1 -Confirm:$false } } catch { $o2.pullFail = $_.Exception.Message }
$o2.ghostCreated = $state.world.ContainsKey('ghostly')
$state.pullError = $false

$o2.appStart = @(& $os7 { Start-OS7ContainerApplication -Name shop -Confirm:$false } | ForEach-Object { [ordered]@{ Name = $_.Name; Step = $_.Step; State = $_.State } })
$o2.appStop = @(& $os7 { Stop-OS7ContainerApplication -Name shop -Confirm:$false } | ForEach-Object { [ordered]@{ Name = $_.Name; Step = $_.Step; State = $_.State } })

$netId = { param($n) (@($state.networks | Where-Object { $_.Name -eq $n }) | Select-Object -First 1).Id }
$redis = @($state.images | Where-Object { $_.RepoTags -contains 'redis:7' }) | Select-Object -First 1
$items = @(
    [pscustomobject]@{ Kind = 'Image'; Name = 'redis:7'; Id = $redis.Id; Size = 1 },
    [pscustomobject]@{ Kind = 'Volume'; Name = ('d' * 64); Id = ('d' * 64); Size = 1 },
    [pscustomobject]@{ Kind = 'Network'; Name = 'stale_net'; Id = (& $netId 'stale_net'); Size = $null },
    [pscustomobject]@{ Kind = 'Volume'; Name = 'shop-pg'; Id = 'shop-pg'; Size = 1 }
)
$o2.cleanup = @(& $os7 { param($i) $i | Remove-OS7ContainerUnused -Confirm:$false } $items | ForEach-Object { [ordered]@{ Kind = $_.Kind; Name = $_.Name; Outcome = $_.Outcome } })
$o2.afterCleanup = [ordered]@{
    redis = [bool](@($state.images | Where-Object { $_.RepoTags -contains 'redis:7' }).Count)
    anon  = [bool](@($state.volumes | Where-Object { $_.Name -eq ('d' * 64) }).Count)
    stale = [bool](@($state.networks | Where-Object { $_.Name -eq 'stale_net' }).Count)
    pg    = [bool](@($state.volumes | Where-Object { $_.Name -eq 'shop-pg' }).Count)
}
$o2.asserted = @(& $os7 { $script:__asserted } | Sort-Object -Unique)

$o2.verbs = @(& $os7 { Get-OS7ContainerVerb } | ForEach-Object { [ordered]@{ Verb = $_.Verb; Class = $_.Class; Cmdlet = $_.Cmdlet
    Exists = [bool](& $os7 { param($c) Get-Command -Name $c -ErrorAction SilentlyContinue } $_.Cmdlet) } })
$o2.verbList = & $os7 { Invoke-OS7ContainerVerb -Verb list }
$o2.worldCount = $state.world.Count
$o2.verbWrongClass = $null
try { $null = & $os7 { Invoke-OS7ContainerVerb -Verb remove -Argument 'lone', 'force' -Class Read, Operate } }
catch { $o2.verbWrongClass = [ordered]@{ Type = $_.Exception.GetType().Name; Message = $_.Exception.Message } }
$o2.loneAfter = $state.world.ContainsKey('lone')
$o2.verbUnknown = $null
try { $null = & $os7 { Invoke-OS7ContainerVerb -Verb exec } } catch { $o2.verbUnknown = $_.Exception.GetType().Name }

. $os7 { $script:__rootDenied = $true }
$o2.operatorStart = (& $os7 { Start-OS7Container -Name 'half-b' -Confirm:$false }).Outcome
$state.denied = $true
$o2.operatorRefused = $null
try { $null = & $os7 { Stop-OS7Container -Name 'half-b' -Confirm:$false } } catch { $o2.operatorRefused = $_.Exception.Message }
$h = & $os7 { Get-OS7ContainerHost }
$o2.hostDenied = [ordered]@{ Access = $h.Access; Command = $h.Command; Reason = $h.Reason }
$state.denied = $false; $state.noengine = $true
$h = & $os7 { Get-OS7ContainerHost }
$o2.hostNone = [ordered]@{ Access = $h.Access; Layout = $h.Layout; Command = $h.Command }
$state.noengine = $false
. $os7 { $script:__rootDenied = $false }

$o2.storeUnread = & $os7 { (Get-OS7ContainerStoreDataset -Path '/var/lib/docker/volumes/x/_data' -Datasets @() -Covered $null).BackedUp }
$o2.storeRead = & $os7 { (Get-OS7ContainerStoreDataset -Path '/var/lib/docker/volumes/x/_data' -Datasets @() -Covered @('rpool/DATA/lib/docker')).BackedUp }
$o2.peers = @(& $os7 { param($t) Get-OS7SshPeer -Table $t } $TcpFile)
$rc = { param($h) @(& $os7 { param($x) Test-OS7ContainerRangeCollision @x } $h) }
$o2.rangeClean = @(& $rc @{ Range = @('10.213.0.1/24', '10.214.0.0/16'); Address = @('192.168.1.5/24'); Route = @('192.168.1.0/24'); Peer = @('172.17.0.4') })
$o2.rangeRoute = @(& $rc @{ Range = @('10.213.0.1/24', '10.214.0.0/16'); Route = @('10.214.5.0/24') })
$o2.rangePeer = @(& $rc @{ Range = @('172.17.0.1/16'); Peer = @('172.17.0.4') })
$o2.rangeAddr = @(& $rc @{ Range = @('10.213.0.1/24'); Address = @('10.213.0.50/16') })
$out.two = $o2

$out | ConvertTo-Json -Depth 8
"""


def run_harness(code):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        sys.exit("pwsh is not on PATH")
    version, world = build_world()
    _, base = recorded()
    tmp = tempfile.mkdtemp(prefix="os7-container-logic-")
    try:
        wf = os.path.join(tmp, "world.json")
        with open(wf, "w", encoding="utf-8") as f:
            json.dump({"version": version, "world": world, "two": build_world2(base)}, f)
        # A kernel connection table, as /proc/net/tcp writes it: an SSH
        # session from 172.17.0.4 (the bench's peer, M-CT10), one from
        # 10.0.2.2, and a LISTEN socket on 22 that must not count.
        tcp = os.path.join(tmp, "tcp")
        with open(tcp, "w", encoding="utf-8") as f:
            f.write("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
                    "   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1\n"
                    "   1: 0F02000A:0016 040011AC:D2B4 01 00000000:00000000 00:00000000 00000000     0        0 2\n"
                    "   2: 0F02000A:0016 0202000A:C001 01 00000000:00000000 00:00000000 00000000     0        0 3\n"
                    "   3: 0F02000A:1F90 050011AC:D2B5 01 00000000:00000000 00:00000000 00000000     0        0 4\n")
        hf = os.path.join(tmp, "harness.ps1")
        with open(hf, "w", encoding="utf-8") as f:
            f.write(HARNESS)
        p = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", hf,
                            "-WorldFile", wf, "-CodeFile", code, "-DockerPsd", DOCKER, "-Os7Psd", OS7,
                            "-TcpFile", tcp],
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

    evaluate_two(r["two"])


def evaluate_two(t):
    """The second world: what the window's v1 asks besides containers."""
    img = {x["Name"]: x for x in t["images"]}
    chk = {x["Name"]: x for x in t["imagesChecked"]}
    dangling = next((x for x in t["images"] if x["Name"].startswith("<none>")), None)

    print("  images — used by, size, and whether the registry moved the tag on")
    check("shop-web" in img["nginx:1.27"]["UsedBy"] and img["nginx:1.27"]["InUse"],
          "an image a container uses says which", ", ".join(img["nginx:1.27"]["UsedBy"]))
    check(img["redis:7"]["InUse"] is False and img["redis:7"]["UsedBy"] == [], "an unused one says nobody")
    check(dangling is not None and dangling["Dangling"] is True, "an image with no tag is dangling, and named by its id",
          dangling["Name"] if dangling else "")
    check(img["nginx:1.27"]["Size"] == 60_000_000,
          "Size is what removing it frees: the engine's size less what it shares", str(img["nginx:1.27"]["Size"]))
    check(all(x["UpdateAvailable"] is None and "Not asked" in (x["UpdateCheck"] or "") for x in t["images"]),
          "without -CheckUpdate nothing is claimed about updates — $null, and says it was not asked")
    check(chk["nginx:1.27"]["UpdateAvailable"] is False, "nginx:1.27: the registry names the image this machine has",
          str(chk["nginx:1.27"]["UpdateCheck"]))
    check(chk["postgres:17"]["UpdateAvailable"] is True, "postgres:17: the registry moved the tag on — an update",
          str(chk["postgres:17"]["UpdateCheck"]))
    check(chk["alpine:3.20"]["UpdateAvailable"] is None and "no such host" in (chk["alpine:3.20"]["UpdateCheck"] or ""),
          "alpine:3.20: the registry did not answer — $null, never $false, in the engine's words",
          str(chk["alpine:3.20"]["UpdateCheck"])[:90])
    d2 = next((x for x in t["imagesChecked"] if x["Name"].startswith("<none>")), {})
    check(d2.get("UpdateAvailable") is None and "no tag" in (d2.get("UpdateCheck") or ""),
          "a dangling image: $null, because there is no tag to ask about")
    check(chk["local/built:1"]["UpdateAvailable"] is None and "not pulled" in (chk["local/built:1"]["UpdateCheck"] or ""),
          "an image built here: $null, because no registry knows it", str(chk["local/built:1"]["UpdateCheck"]))

    print("  volumes — what uses them, and whether the backup reaches them")
    vol = {x["Name"]: x for x in t["volumes"]}
    check(vol["shop-pg"]["UsedBy"] == ["shop-db"] and vol["shop-pg"]["BackedUp"] is True,
          "shop-pg: used by shop-db, on a dataset the backup policy covers", f"{vol['shop-pg']['UsedBy']} {vol['shop-pg']['BackedUp']}")
    check(vol["shop-pg"]["LatestSnapshot"] != "", "and the newest snapshot holding it is named", vol["shop-pg"]["LatestSnapshot"])
    check(vol["c" * 64]["Anonymous"] is True and vol["c" * 64]["UsedBy"] == ["lone"],
          "an anonymous volume is recognised as one, and still says who uses it")
    check(vol["legacy"]["InBootEnvironment"] is True and vol["legacy"]["BackedUp"] is False
          and "boot environment" in (vol["legacy"]["Reason"] or ""),
          "a volume whose data is inside the boot environment says so, and is not called backed up", str(vol["legacy"]["Reason"])[:80])

    check(t["storeUnread"] is None and t["storeRead"] is True,
          "a backup policy this account cannot read makes BackedUp $null, not $false — seen on a machine",
          f"{t['storeUnread']} / {t['storeRead']}")

    print("  networks")
    net = {x["Name"]: x for x in t["networks"]}
    check(net["bridge"]["Builtin"] and net["host"]["Builtin"] and net["none"]["Builtin"]
          and not net["stale_net"]["Builtin"], "the engine's own three are marked built in, and only they")
    check(sorted(net["shop_default"]["UsedBy"]) == ["shop-db", "shop-web", "shop-worker"],
          "a network says which containers are on it", ", ".join(net["shop_default"]["UsedBy"]))
    check(net["stale_net"]["InUse"] is False, "and one nobody is on says nobody")

    print("  applications — one word for the whole project")
    app = {x["Name"]: x for x in t["apps"]}
    check(app["shop"]["State"] == "NeedsAttention", "shop: one container failed, so the application needs attention",
          app["shop"]["State"])
    check(app["blog"]["State"] == "Running", "blog: every container running", app["blog"]["State"])
    check(app["half"]["State"] == "Partial", "half: one running, one not", app["half"]["State"])
    check(app["idle"]["State"] == "Stopped", "idle: none running", app["idle"]["State"])
    check(app["shop"]["Services"] == ["db", "web", "worker"], "and its services, read off the labels",
          ", ".join(app["shop"]["Services"]))
    check([x["Name"] for x in t["appStart"]] == ["shop-db", "shop-web", "shop-worker"],
          "start order: what a service depends on starts first (db, then web, then the worker on both)",
          ", ".join(x["Name"] for x in t["appStart"]))
    check([x["Name"] for x in t["appStop"]] == ["shop-worker", "shop-web", "shop-db"],
          "stop order: the other way round", ", ".join(x["Name"] for x in t["appStop"]))
    check(all(x["State"] == "Stopped" for x in t["appStop"]), "and each says what it is afterwards")

    print("  clean-up — the preview, and OS/7's judgement of what is safe")
    want = {
        ("Container", "shop-worker", False), ("Container", "half-b", False), ("Container", "idle-x", False),
        ("Container", "lone", False),
        ("Image", dangling["Name"] if dangling else "?", True), ("Image", "local/built:1", True), ("Image", "redis:7", True),
        ("Volume", "d" * 64, True), ("Network", "stale_net", True),
    }
    got = {(x["Kind"], x["Name"], x["Recommended"]) for x in t["unused"]}
    check(got == want, "exactly what is unused, each marked safe or not",
          "; ".join(f"{k} {n[:14]} {r}" for k, n, r in sorted(got ^ want)) or "as expected")
    check(("Container", "lone", False) in got, "a stopped container is offered and NOT recommended: it is somebody's configuration")
    check(not any(n == "old-data" for _, n, _ in got), "named volumes are not offered unless asked for")
    gotn = {(x["Kind"], x["Name"], x["Recommended"]) for x in t["unusedNamed"]}
    check(("Volume", "old-data", False) in gotn and ("Volume", "legacy", False) in gotn,
          "with -IncludeNamedVolumes they are, and never recommended")
    cu = {x["Name"]: x["Outcome"] for x in t["cleanup"]}
    check(cu.get("redis:7") == "Removed" and cu.get("d" * 64) == "Removed" and cu.get("stale_net") == "Removed",
          "the clean-up removes exactly the items it was given", str(cu))
    check(cu.get("shop-pg") == "NoLongerUnused" and t["afterCleanup"]["pg"] is True,
          "shop-pg: NoLongerUnused — an item that is in use is left alone, not handed to the engine", str(cu.get("shop-pg")))
    a = t["afterCleanup"]
    check(not a["redis"] and not a["anon"] and not a["stale"], "and asked afterwards, the engine no longer has the three")

    print("  the create dialog's cmdlet — what it would do, before it does it")
    ok = t["vOk"]
    check(ok["Validated"] and ok["Problems"] == [], "a good description validates", "; ".join(ok["Problems"]))
    check("all networks" in (ok["Reachable"] or ""), "a port with no address is open on ALL networks, and the plan says so",
          ok["Reachable"])
    check("this machine only" in (t["vLocal"]["Reachable"] or ""), "127.0.0.1:8082:80 is this machine only", t["vLocal"]["Reachable"])
    check(ok["ImagePresent"] is True and any("new volume" in v for v in ok["Volumes"]),
          "it says the image is here and the volume will be new", "; ".join(ok["Volumes"]))
    check(ok["EnvironmentNames"] == ["SECRET"] and "hunter2" not in ok["Json"],
          "the plan names the environment and never echoes a value")
    check(any("already exists" in x for x in t["vTaken"]["Problems"]), "a name in use is a problem", "; ".join(t["vTaken"]["Problems"]))
    check(any("path of this machine" in x for x in t["vBind"]["Problems"]),
          "a host path is refused, because OS/7 gives a container named volumes only", "; ".join(t["vBind"]["Problems"])[:90])
    check(any("already published by container 'shop-web'" in x for x in t["vClash"]["Problems"]),
          "a host port another container publishes is a problem, naming it", "; ".join(t["vClash"]["Problems"]))
    check(any("not an environment variable name" in x for x in t["vEnv"]["Problems"]), "a bad environment name is a problem")
    check(any("hostport:containerport" in x for x in t["vPort"]["Problems"]), "a port that is not one says the shape",
          "; ".join(t["vPort"]["Problems"])[:90])
    check(t["vAbsent"]["Validated"] and t["vAbsent"]["ImagePresent"] is False,
          "an image this machine does not have is not a problem: it will be pulled")
    c = t["create"]
    check(c["Outcome"] == "Started" and c["State"] == "Running" and c["Pulled"] == "AlreadyPresent",
          "created and started, asked back as Running", f"{c['Outcome']}/{c['State']}/{c['Pulled']}")
    check("this machine only" in (c["Reachable"] or ""), "and its port reads as this machine only", c["Reachable"])
    b = t["createdBody"]
    bind = (b["Bindings"] or {}).get("80/tcp", [{}])[0]
    check("SECRET=hunter2" in b["Env"] and bind.get("HostIp") == "127.0.0.1" and bind.get("HostPort") == "8081",
          "what reached the engine: the environment, and the port where it was asked to be", str(bind))
    check(b["Mounts"] and b["Mounts"][0].get("Type") == "volume" and b["Mounts"][0].get("Source") == "site",
          "and the volume as a named volume", str(b["Mounts"]))
    check("hunter2" not in c["Json"], "the result does not echo the environment either")
    check(t["pullFail"] is not None and "answered 200 and then said" in t["pullFail"] and "manifest unknown" in t["pullFail"]
          and t["ghostCreated"] is False,
          "a pull the engine answered 200 and then failed is a refusal, and nothing is created",
          str(t["pullFail"])[:100])

    print("  the guard, on every verb that changes something")
    for v in ("New-OS7Container", "Remove-OS7ContainerUnused", "Start-OS7ContainerApplication", "Stop-OS7ContainerApplication"):
        check(v in t["asserted"], f"{v} calls the guard by its own name")

    print("  the verb table — one table, two channels (CT5)")
    verbs = {x["Verb"]: x for x in t["verbs"]}
    check(all(x["Exists"] for x in t["verbs"]), "every verb names a cmdlet that exists",
          ", ".join(x["Verb"] for x in t["verbs"] if not x["Exists"]))
    destroy = sorted(k for k, v in verbs.items() if v["Class"] == "Destroy")
    operate = sorted(k for k, v in verbs.items() if v["Class"] == "Operate")
    check(destroy == ["cleanup", "image-remove", "network-remove", "remove", "volume-remove"],
          "every verb that deletes is Destroy, and nothing else is", ", ".join(destroy))
    check(operate == ["app-start", "app-stop", "create", "restart", "start", "stop"], "the operating verbs are Operate",
          ", ".join(operate))
    install = sorted(k for k, v in verbs.items() if v["Class"] == "Install")
    check(install == ["install-host"] and verbs["install-host"]["Cmdlet"] == "Install-OS7ContainerHost",
          "installing the engine is its own class, and the only verb in it", ", ".join(install))
    try:
        listed = json.loads(t["verbList"])
    except (TypeError, ValueError):
        listed = None
    check(isinstance(listed, list) and len(listed) == t["worldCount"],
          "a verb's answer is a JSON ARRAY, one per container", f"{type(listed).__name__} {len(listed) if listed else ''}")
    w = t["verbWrongClass"] or {}
    check(w.get("Type") == "UnauthorizedAccessException" and "Destroy verb" in w.get("Message", "") and t["loneAfter"],
          "a Destroy verb sent to the operate channel is refused BY NAME, and nothing is removed", w.get("Message", "")[:90])
    check(t["verbUnknown"] == "ArgumentException", "an unknown verb is refused", str(t["verbUnknown"]))

    print("  the operator — root-equivalent by choice (O-CT3)")
    check(t["operatorStart"] == "Started", "not root, but holding the socket: the verb runs", str(t["operatorStart"]))
    m = t["operatorRefused"] or ""
    check("sudo pwsh" in m and "Add-OS7ContainerOperator" in m and "ROOT-EQUIVALENT" in m,
          "neither: the refusal names sudo pwsh -c AND the operator route, as root-equivalent", m.split("\n")[0][:90])
    check(t["hostDenied"]["Access"] == "Denied" and t["hostDenied"]["Command"],
          "Get-OS7ContainerHost answers a user it refuses — Denied, not an exception", str(t["hostDenied"]))
    check(t["hostNone"]["Access"] == "NoEngine"
          and t["hostNone"]["Command"] == "sudo pwsh -NoProfile -c 'Install-OS7ContainerHost'",
          "and a machine with no engine: NoEngine, and the verb that installs one in #148's elevated form",
          str(t["hostNone"]))

    print("  CT7 — the ranges, against what this machine reaches")
    check(t["peers"] == ["172.17.0.4", "10.0.2.2"],
          "the SSH peers, out of the kernel's table: ESTABLISHED on port 22 only", ", ".join(t["peers"]))
    check(t["rangeClean"] == [], "OS/7's ranges beside a 192.168 LAN and the bench's 172.17 peer: no collision",
          "; ".join(t["rangeClean"]))
    check(len(t["rangeRoute"]) == 1 and "a route" in t["rangeRoute"][0], "a route inside the pool collides", "; ".join(t["rangeRoute"]))
    check(len(t["rangePeer"]) == 1 and "SSH session" in t["rangePeer"][0],
          "Docker's own default against the bench's peer collides — M-CT10, replayed", "; ".join(t["rangePeer"]))
    check(len(t["rangeAddr"]) == 1 and "an address" in t["rangeAddr"][0], "an address of this machine inside the bridge collides")


STREAMS = r"""
param([string]$CodeFile, [string]$DockerPsd, [string]$Os7Psd)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Import-Module $DockerPsd -Force
Import-Module $Os7Psd -Force
$os7 = Get-Module OS7
. $os7 { param($p) . $p } $CodeFile
# A cmdlet that says something on every side stream, the way
# Get-OS7StoragePressure warned on a machine that the ESP is root's.
. $os7 {
    function Get-OS7ContainerHost {
        Write-Warning 'cannot read /boot/efi/EFI/OS7/grub.cfg as this account'
        Write-Verbose 'verbose line' -Verbose
        Write-Information 'information line' -InformationAction Continue
        [pscustomobject]@{ Access = 'Root' }
    }
}
& $os7 { Invoke-OS7ContainerVerb -Verb host }
"""


def stream_boundary(code):
    """
    BUILD-NOTES #60, AT THE BOUNDARY A MACHINE FOUND OPEN (2026-10-30). With
    stdout redirected, pwsh writes the warning, verbose and information
    streams to stdout. The window's first run as a user read "'W' is an
    invalid start of a value", because Get-OS7StoragePressure had warned. This
    runs a REAL pwsh with stdout captured — the in-process harness above
    cannot see the defect at all, since there the streams stay streams.
    """
    pwsh = shutil.which("pwsh")
    tmp = tempfile.mkdtemp(prefix="os7-container-streams-")
    try:
        sf = os.path.join(tmp, "streams.ps1")
        with open(sf, "w", encoding="utf-8") as f:
            f.write(STREAMS)
        p = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", sf,
                            "-CodeFile", code, "-DockerPsd", DOCKER, "-Os7Psd", OS7],
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    out = p.stdout.strip()
    try:
        parsed = json.loads(out)
    except ValueError:
        parsed = None
    check(isinstance(parsed, list) and parsed and parsed[0].get("Access") == "Root",
          "a verb's stdout is the JSON and nothing else, while the cmdlet warns, informs and is verbose (#60)",
          out.splitlines()[0][:90] if out else f"no stdout; {p.stderr.strip()[:90]}")


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
    ("a stopped container recommended for clean-up — somebody's configuration, deleted by default",
     "{ $u.ContainerSize[$id] } else { $null }) $false `",
     "{ $u.ContainerSize[$id] } else { $null }) $true `", "a stopped container is offered and NOT recommended"),
    ("the update check believes every image is current",
     "if ($local -contains [string]$d.Digest) {",
     "if ($true) {", "postgres:17: the registry moved"),
    ("a Destroy verb runs under the operate channel's polkit action",
     "if ($Class -and $Class -notcontains $v.Class) {",
     "if ($false) {", "a Destroy verb sent to the operate channel is refused"),
    ("an application stops in START order",
     "if ($Action -eq 'Stop') { [array]::Reverse($order) }",
     "", "stop order"),
    ("a named volume offered for clean-up without being asked",
     "if (-not $anon -and -not $named) { continue }",
     "", "named volumes are not offered"),
    ("overlapping ranges read as apart",
     "$overlaps = { param($a, $b) $a.First -le $b.Last -and $b.First -le $a.Last }",
     "$overlaps = { param($a, $b) $false }", "against the bench's peer collides"),
    ("the clean-up acts on a stale preview",
     "if (-not ($now | Where-Object Id -EQ $id)) {",
     "if ($false) {", "shop-pg: NoLongerUnused"),
    ("a host path accepted as a volume",
     "if ($name.StartsWith('/') -or $name.StartsWith('.') -or $name.StartsWith('~')) {",
     "if ($false) {", "a host path is refused"),
    ("the plan echoes the environment's values",
     "EnvironmentNames = $envNames",
     "EnvironmentNames = @(if ($Environment) { $Environment.GetEnumerator() | ForEach-Object { \"$($_.Key)=$($_.Value)\" } })",
     "never echoes a value"),
    ("the verb boundary lets the side streams reach stdout (#60, found by a machine)",
     "$out = @(& $v.Run @($Argument) $InputJson 3>$null 4>$null 5>$null 6>$null)",
     "$out = @(& $v.Run @($Argument) $InputJson)",
     "a verb's stdout is the JSON and nothing else"),
    ("an unreadable backup policy read as 'not backed up' (found by a machine)",
     "BackedUp          = if ($null -eq $Covered) { $null } else { [bool]($ds -and $Covered -contains $ds) }",
     "BackedUp          = [bool]($ds -and $Covered -contains $ds)",
     "makes BackedUp $null, not $false"),
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
                    stream_boundary(planted)
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
    stream_boundary(code)
    layering(code)
    if "--prove" in sys.argv:
        prove(code)
    print(f"\n{len(FAILS)} failed" if FAILS else "\ncheck-container-logic: GREEN")
    sys.exit(1 if FAILS else 0)


if __name__ == "__main__":
    main()
