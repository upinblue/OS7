#!/usr/bin/env python3
"""
The OS/7 network layer's DECISIONS, in seconds, with no network and no VM.

    ./check-network-logic.py

WHAT THIS IS AND IS NOT. It runs the real `powershell/OS7` module against an
`ip` and a `netplan` that are fakes, and checks what OS/7's layer CONCLUDES from
what they say: which links count as adapters, which route becomes an adapter's
gateway, and — the one this exists for — when a configuration and a running
machine are reported as disagreeing.

It is NOT a test of `ip`, of netplan, or of a machine. `Test-NetModule` checks
the readers against RECORDED REAL `ip` output and the netplan half against the
REAL netplan through its own `--root-dir`; `run-phase3.py` is the test of a
machine. Nothing here replaces either.

WHY IT EXISTS. L28 is the most expensive thing Phase 3b learned: a netplan
document that matches no hardware brings nothing up and netplan ACCEPTS IT IN
SILENCE — no address, no route, no error, and on a headless machine a site
visit. `Get-OS7NetworkConfiguration` is the first code in this repository that
says that out loud, and a claim like that is worth nothing unless something
proves it fires. Case 2 below is that proof.

THE FAKE'S ONE LOAD-BEARING PROPERTY is that it replaces the COMMAND RUNNER,
not the parser — the same seam `Test-ZfsModule` uses. So what runs is the whole
path an operator's call takes: OS7 asks the Net module, the Net module builds an
argument vector, parses what comes back and types it, and OS7 draws a conclusion
from the objects. A fake that returned ready-made objects would check the
conclusion and skip everything that produces the objects it is drawn from.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OS7 = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")
NET = os.path.join(REPO, "powershell", "Net", "Net.psd1")

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


# ---------------------------------------------------------------------------
# The machines. Each is what `ip` and `netplan` would say, and nothing else.
#
# The `ip` payloads are trimmed from the RECORDED output in
# powershell/Net/tests/fixtures/ rather than invented, so the shapes here are
# the shapes the kernel emits.
# ---------------------------------------------------------------------------

def link(name, index, mac, kind="ether", up=True, carrier=True, addr=None):
    flags = ["BROADCAST", "MULTICAST"]
    if kind == "loopback":
        flags = ["LOOPBACK"]
    if up:
        flags.append("UP")
    if carrier:
        flags.append("LOWER_UP")
    o = {"ifindex": index, "ifname": name, "flags": flags, "mtu": 1500,
         "operstate": "UP" if up else "DOWN", "link_type": kind, "address": mac}
    if addr:
        o["addr_info"] = [{"family": "inet", "local": addr[0], "prefixlen": addr[1],
                           "scope": "global"}]
    return o


LO = link("lo", 1, "00:00:00:00:00:00", kind="loopback", addr=("127.0.0.1", 8))
ETH = link("eth0", 2, "52:54:00:12:34:56", addr=("10.0.2.99", 24))
ETH_NOADDR = link("eth0", 2, "52:54:00:12:34:56")
ENP = link("enp1s0", 2, "aa:bb:cc:dd:ee:ff", addr=("10.0.2.50", 24))

DEFAULT_ROUTE = [{"dst": "default", "gateway": "10.0.2.2", "dev": "eth0", "flags": []},
                 {"dst": "10.0.2.0/24", "dev": "eth0", "protocol": "kernel",
                  "scope": "link", "prefsrc": "10.0.2.99", "flags": []}]


def netplan_eth(iface_id, **keys):
    """The netplan answers for one ethernets block, as `netplan get` gives them."""
    out = {"ethernets": f"{iface_id}:\n  dhcp4: true\n", "wifis": "null"}
    for k, v in keys.items():
        out[f"ethernets.{iface_id}.{k.replace('__', '.')}"] = v
    return out


CASES = [
    {
        "name": "a healthy machine: configured by MAC, and that MAC has an address",
        "ip_addr": [[LO, ETH]],
        "ip_route": DEFAULT_ROUTE,
        "netplan": netplan_eth("os7net", match__macaddress='"52:54:00:12:34:56"',
                               dhcp4="true"),
    },
    {
        # L28, AND THE REASON THIS FILE EXISTS. The document names a MAC no port
        # on this machine has — which is what a netplan file written with the
        # install-time interface name, or copied from another machine, comes to.
        # netplan accepts it and says nothing.
        "name": "L28: a document matching a MAC no adapter has",
        "ip_addr": [[LO, ETH]],
        "ip_route": DEFAULT_ROUTE,
        "netplan": netplan_eth("os7net", match__macaddress='"de:ad:be:ef:00:01"',
                               dhcp4="true"),
    },
    {
        "name": "configured for an address, and the adapter has none",
        "ip_addr": [[LO, ETH_NOADDR]],
        "ip_route": [],
        "netplan": netplan_eth("os7net", match__macaddress='"52:54:00:12:34:56"',
                               dhcp4="true"),
    },
    {
        # L23. A machine deliberately kept off the network is not a machine with
        # a problem, and reporting one would train an operator to ignore this.
        "name": "L23: a block that asks for no address is not a disagreement",
        "ip_addr": [[LO, ETH_NOADDR]],
        "ip_route": [],
        "netplan": netplan_eth("os7net", match__macaddress='"52:54:00:12:34:56"',
                               dhcp4="false"),
    },
    {
        "name": "a match glob finds the adapter it globs",
        "ip_addr": [[LO, ENP]],
        "ip_route": [],
        "netplan": netplan_eth("os7net", match__name='"en*"', dhcp4="true"),
    },
    {
        # No `match:` at all — the netplan id IS the interface name. The oldest
        # shape, and still legal.
        "name": "with no match block the id is read as an interface name",
        "ip_addr": [[LO, ETH]],
        "ip_route": DEFAULT_ROUTE,
        "netplan": netplan_eth("eth0", dhcp4="true"),
    },
]

# The driver. It installs the fake INTO THE Net MODULE'S SCOPE, which is where
# the seam lives, and then calls the OS/7 cmdlets exactly as an operator would.
DRIVER = r"""
$ErrorActionPreference = 'Stop'

# REAL `ip -j addr show <dev>` RETURNS ONLY THAT DEVICE, and the fake has to as
# well. Without this it answered every question with the whole list, so
# `Get-OS7NetworkAdapter -Name eth0` got `lo` — which always has an address, so
# a failed apply looked like a successful one. The fake was hiding the bug the
# case was written to find.
function Select-FakeLink($json, $argv) {{
    $last = $argv[-1]
    if ($last -in @('show', 'addr', 'link', 'route', '-j', '-6')) {{ return $json }}
    $kept = @(($json | ConvertFrom-Json) | Where-Object ifname -eq $last)
    # PIPED. `ConvertTo-Json $kept -AsArray` double-wraps an array, which a
    # one-element result survives by accident and a two-element one does not.
    return (@($kept) | ConvertTo-Json -Depth 8 -Compress -AsArray)
}}
Import-Module '{net}'  -Force
Import-Module '{os7}' -Force

$case = Get-Content -Raw -LiteralPath '{casefile}' | ConvertFrom-Json -AsHashtable

# Into the Net module's own scope: $script: there is the module's scope, and the
# seam is deliberately not exported. Import-OS7NetLayer returns early because
# Get-Module Net already answers, so nothing re-imports over this.
& (Get-Module Net) {{
    param($c)
    $script:__ipCall = 0
    $script:NetCommandOverride = {{
        param($cmd, $a)
        $joined = ($a -join ' ')
        $out = ''
        $exit = 0
        if ($cmd -eq 'ip') {{
            if ($joined -match '-6') {{ $out = '[]' }}
            elseif ($joined -match 'route') {{ $out = $c.ipRoute }}
            else {{
                # A SEQUENCE, not a value. Set-OS7NetworkAdapter asks `ip`
                # again after it applies and a THIRD time after it rolls back,
                # and a fake that answered the same thing every time could not
                # express "the new configuration did not work and the old one
                # did". The last entry repeats, so a one-entry sequence behaves
                # like a constant.
                $i = [Math]::Min($script:__ipCall, $c.ipAddr.Count - 1)
                $out = $c.ipAddr[$i]
                $script:__ipCall++
                $out = Select-FakeLink $out $a
            }}
        }}
        elseif ($cmd -eq 'rfkill') {{
            $out = $c.rfkillOut; $exit = $c.rfkillExit
        }}
        elseif ($cmd -eq 'netplan') {{
            # `netplan get <key>` - the key is the last argument.
            $key = $a[-1]
            $out = if ($c.netplan.ContainsKey($key)) {{ $c.netplan[$key] }} else {{ 'null' }}
        }}
        [pscustomobject]@{{ StdOut = $out; ExitCode = $exit; StdErr = '' }}
    }}.GetNewClosure()
}} $case

$adapters = @(Get-OS7NetworkAdapter)
$withLo   = @(Get-OS7NetworkAdapter -IncludeLoopback)
$cfg      = Get-OS7NetworkConfiguration

[pscustomobject]@{{
    Adapters      = @($adapters | ForEach-Object {{
        [pscustomobject]@{{
            Name = $_.Name; Kind = $_.Kind; Gateway = $_.Gateway
            IPv4 = @($_.IPv4Address); RadioBlocked = $_.RadioBlocked
        }} }})
    WithLoopback  = @($withLo | ForEach-Object {{ $_.Name }})
    Agrees        = $cfg.Agrees
    Disagreements = @($cfg.Disagreements | ForEach-Object {{
        [pscustomobject]@{{ Id = $_.Id; Adapter = $_.Adapter; Problem = $_.Problem }} }})
    Configured    = @($cfg.Configured | ForEach-Object {{
        [pscustomobject]@{{ Id = $_.Id; Method = $_.Method }} }})
}} | ConvertTo-Json -Depth 8 -Compress
"""


def pwsh():
    exe = shutil.which("pwsh")
    if not exe:
        sys.exit("pwsh not found; this check runs the real powershell/OS7 module.")
    return exe


# ---------------------------------------------------------------------------
# The WRITE path, and the rollback that is the whole reason it is a cmdlet
# rather than an editor.
#
# `netplan apply` returns 0 for a configuration that brings nothing up, so a
# mistyped address on a headless machine is a machine nobody can reach and
# therefore nobody can fix. The sequence under test is: write, apply, ASK `ip`,
# and if no address appears put the old document back and check THAT too.
#
# The document really is written — to a real directory, not /etc/netplan — so
# what is checked afterwards is the file on the disk rather than an intention.
# ---------------------------------------------------------------------------

WRITE_DRIVER = r"""
$ErrorActionPreference = 'Stop'

# REAL `ip -j addr show <dev>` RETURNS ONLY THAT DEVICE, and the fake has to as
# well. Without this it answered every question with the whole list, so
# `Get-OS7NetworkAdapter -Name eth0` got `lo` — which always has an address, so
# a failed apply looked like a successful one. The fake was hiding the bug the
# case was written to find.
function Select-FakeLink($json, $argv) {{
    $last = $argv[-1]
    if ($last -in @('show', 'addr', 'link', 'route', '-j', '-6')) {{ return $json }}
    $kept = @(($json | ConvertFrom-Json) | Where-Object ifname -eq $last)
    # PIPED. `ConvertTo-Json $kept -AsArray` double-wraps an array, which a
    # one-element result survives by accident and a two-element one does not.
    return (@($kept) | ConvertTo-Json -Depth 8 -Compress -AsArray)
}}
Import-Module '{net}'  -Force
Import-Module '{os7}' -Force

$case = Get-Content -Raw -LiteralPath '{casefile}' | ConvertFrom-Json -AsHashtable

& (Get-Module Net) {{
    param($c)
    $script:__ipCall = 0
    $script:NetCommandOverride = {{
        param($cmd, $a)
        $joined = ($a -join ' ')
        $out = ''; $exit = 0
        if ($cmd -eq 'ip') {{
            if ($joined -match '-6') {{ $out = '[]' }}
            elseif ($joined -match 'route') {{ $out = $c.ipRoute }}
            else {{
                $i = [Math]::Min($script:__ipCall, $c.ipAddr.Count - 1)
                $out = $c.ipAddr[$i]; $script:__ipCall++
                $out = Select-FakeLink $out $a
            }}
        }}
        elseif ($cmd -eq 'rfkill') {{ $out = '{{"rfkilldevices": []}}'; $exit = 1 }}
        elseif ($cmd -eq 'netplan') {{
            # `netplan apply` has no key; `netplan get <key>` does. Apply is
            # answered with exit 0 ON PURPOSE — that is the whole trap: it
            # succeeds for a configuration that brings nothing up.
            if ($a -contains 'apply') {{ $out = '' }}
            else {{
                $key = $a[-1]
                $out = if ($c.netplan.ContainsKey($key)) {{ $c.netplan[$key] }} else {{ 'null' }}
            }}
        }}
        [pscustomobject]@{{ StdOut = $out; ExitCode = $exit; StdErr = '' }}
    }}.GetNewClosure()
}} $case

# The document goes to a real directory of the test's own, so that what is
# asserted afterwards is a file rather than a promise.
& (Get-Module OS7) {{ param($p) $script:OS7NetplanPath = $p }} '{netplanfile}'

$splat = @{{ Name = $case.adapter; TimeoutSeconds = 0 }}
if ($case.ContainsKey('address')) {{ $splat.Address = $case.address }}
else {{ $splat.Dhcp = $true }}
if ($case.ContainsKey('force')) {{ $splat.Force = $true }}

$r = Set-OS7NetworkAdapter @splat -Confirm:$false

[pscustomobject]@{{
    Applied        = $r.Applied
    Verified       = $r.Verified
    RolledBack     = $r.RolledBack
    RollbackFailed = $r.RollbackFailed
    Detail         = $r.Detail
    Renderer       = $r.Renderer
    FileExists     = [System.IO.File]::Exists('{netplanfile}')
    FileContent    = $(if ([System.IO.File]::Exists('{netplanfile}')) {{
        [System.IO.File]::ReadAllText('{netplanfile}') }} else {{ '' }})
}} | ConvertTo-Json -Depth 6 -Compress
"""


def run_write(case, lab, previous=None):
    netplanfile = os.path.join(lab, "01-os7-network.yaml")
    if os.path.exists(netplanfile):
        os.remove(netplanfile)
    if previous is not None:
        with open(netplanfile, "w", encoding="utf-8", newline="") as f:
            f.write(previous)

    payload = dict(case)
    payload["ipAddr"] = [json.dumps(s) for s in case["ip_addr"]]
    payload["ipRoute"] = json.dumps(case.get("ip_route", []))
    payload.pop("ip_addr", None)
    payload.pop("ip_route", None)
    payload.pop("name", None)

    casefile = os.path.join(lab, "wcase.json")
    with open(casefile, "w", encoding="utf-8") as f:
        json.dump(payload, f)

    script = WRITE_DRIVER.format(net=NET.replace("'", "''"), os7=OS7.replace("'", "''"),
                                 casefile=casefile.replace("'", "''"),
                                 netplanfile=netplanfile.replace("'", "''"))
    p = subprocess.run([pwsh(), "-NoProfile", "-NonInteractive", "-Command", script],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f"      FAIL  {case['name']}: pwsh exited {p.returncode}")
        print("            " + (p.stderr.strip().replace("\n", "\n            ") or "(no stderr)"))
        FAILS.append(case["name"])
        return None
    return json.loads(p.stdout.strip())


def run(case, lab):
    payload = {
        # A LIST of `ip addr` snapshots, consumed in order. Most cases give one.
        "ipAddr": [json.dumps(s) for s in case["ip_addr"]],
        "ipRoute": json.dumps(case["ip_route"]),
        # rfkill CANNOT BE ASKED in every case here, which is deliberate: it is
        # the state a machine with no /dev/rfkill is in, it exits 1 while
        # printing a valid empty list, and the OS/7 layer must turn that into
        # $null rather than $false.
        "rfkillOut": '{"rfkilldevices": []}',
        "rfkillExit": 1,
        "netplan": case["netplan"],
    }
    casefile = os.path.join(lab, "case.json")
    with open(casefile, "w", encoding="utf-8") as f:
        json.dump(payload, f)

    script = DRIVER.format(net=NET.replace("'", "''"), os7=OS7.replace("'", "''"),
                           casefile=casefile.replace("'", "''"))
    p = subprocess.run([pwsh(), "-NoProfile", "-NonInteractive", "-Command", script],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print(f"      FAIL  {case['name']}: pwsh exited {p.returncode}")
        print("            " + (p.stderr.strip().replace("\n", "\n            ") or "(no stderr)"))
        FAILS.append(case["name"])
        return None
    # OS7-STEP lines go to stderr, so stdout is the JSON and nothing else.
    return json.loads(p.stdout.strip())


def main():
    import tempfile
    print("### the OS/7 network layer's decisions")
    print(f"### {len(CASES)} machines read and 5 written, no network, no VM")
    lab = tempfile.mkdtemp(prefix="os7-netlogic-")
    try:
        print("\n  what counts as an adapter")
        r = run(CASES[0], lab)
        if r:
            check([a["Name"] for a in r["Adapters"]] == ["eth0"],
                  "loopback is not an adapter", ",".join(a["Name"] for a in r["Adapters"]))
            check(r["WithLoopback"] == ["lo", "eth0"],
                  "-IncludeLoopback brings it back", ",".join(r["WithLoopback"]))
            check(r["Adapters"][0]["Gateway"] == "10.0.2.2",
                  "the default route becomes the adapter's gateway")
            check(r["Adapters"][0]["IPv4"] == ["10.0.2.99/24"], "the address, with its prefix")
            # A check that did not run must never read as a clean result — the
            # same rule Get-OS7Version's Drift follows. rfkill exited 1 here.
            check(r["Adapters"][0]["RadioBlocked"] is None,
                  "RadioBlocked is null, not false, when rfkill could not be asked",
                  repr(r["Adapters"][0]["RadioBlocked"]))
            check(r["Agrees"] is True, "a healthy machine agrees with its configuration")
            check(r["Disagreements"] == [], "and reports nothing")

        print("\n  when the configuration and the machine disagree")
        r = run(CASES[1], lab)
        if r:
            check(r["Agrees"] is False, "L28: a MAC no adapter has does not agree")
            check(len(r["Disagreements"]) == 1 and
                  "matches no adapter" in r["Disagreements"][0]["Problem"],
                  "L28: and it says the document matches no adapter",
                  r["Disagreements"][0]["Problem"] if r["Disagreements"] else "(none)")
            check(r["Disagreements"] and r["Disagreements"][0]["Adapter"] is None,
                  "L28: with no adapter named, because there is none")

        r = run(CASES[2], lab)
        if r:
            check(r["Agrees"] is False, "an adapter that asked for an address and has none")
            check(r["Disagreements"] and
                  "has none" in r["Disagreements"][0]["Problem"],
                  "and it says so",
                  r["Disagreements"][0]["Problem"] if r["Disagreements"] else "(none)")
            check(r["Disagreements"] and r["Disagreements"][0]["Adapter"] == "eth0",
                  "naming the adapter it matched, which it did match")

        print("\n  what is deliberately not a problem")
        r = run(CASES[3], lab)
        if r:
            check(r["Configured"] and r["Configured"][0]["Method"] == "None",
                  "L23: no dhcp4 and no addresses reads as Method None",
                  r["Configured"][0]["Method"] if r["Configured"] else "(none)")
            check(r["Agrees"] is True, "L23: a machine deliberately off the network agrees")

        print("\n  matching a block to a port")
        r = run(CASES[4], lab)
        if r:
            check(r["Agrees"] is True, "a glob matches the adapter it globs")
        r = run(CASES[5], lab)
        if r:
            check(r["Agrees"] is True, "with no match block, the id is the interface name")

        print("\n  writing: it worked")
        w = run_write({
            "name": "an apply that produces an address",
            "adapter": "eth0",
            # One snapshot: eth0 already has an address and keeps it.
            "ip_addr": [[LO, ETH]],
            "ip_route": DEFAULT_ROUTE,
            "netplan": {"ethernets": "null", "wifis": "null"},
        }, lab)
        if w:
            check(w["Verified"] is True, "an address after the apply is a pass")
            check(w["RolledBack"] is False, "and nothing is rolled back")
            check(w["FileExists"], "the document is on the disk")
            # L28 again, from the writing side: the document OS/7 writes must
            # match on the MAC, because the interface NAME does not survive a
            # reboot. This is the check that the write path did not quietly
            # fall back to naming the port.
            check("macaddress: \"52:54:00:12:34:56\"" in w["FileContent"],
                  "and it matches on the MAC, not the interface name (L28)")
            check("os7net:" in w["FileContent"],
                  "so the block is labelled os7net rather than eth0")

        print("\n  writing: it did not work")
        previous = "network:\n  version: 2\n  renderer: networkd\n  ethernets:\n    old:\n      dhcp4: true\n"
        w = run_write({
            "name": "an apply that produces nothing, with a document to go back to",
            "adapter": "eth0",
            # THE SEQUENCE THAT MATTERS. First look: the adapter as it is now.
            # Second (after the apply): no address — the failure netplan does
            # not report. Third (after the rollback): an address again.
            "ip_addr": [[LO, ETH], [LO, ETH_NOADDR], [LO, ETH]],
            "ip_route": DEFAULT_ROUTE,
            "netplan": {"ethernets": "null", "wifis": "null"},
            "address": "10.9.9.9/24",
        }, lab, previous=previous)
        if w:
            check(w["Verified"] is False, "no address after the apply is a failure")
            check(w["RolledBack"] is True, "and the previous document is put back")
            check(w["RollbackFailed"] is False, "and the rollback itself is checked")
            check("old:" in w["FileContent"],
                  "the file on the disk is the OLD one, byte for byte",
                  w["FileContent"].strip().splitlines()[-1] if w["FileContent"] else "(empty)")

        w = run_write({
            "name": "an apply that produces nothing, with NO document to go back to",
            "adapter": "eth0",
            "ip_addr": [[LO, ETH], [LO, ETH_NOADDR], [LO, ETH]],
            "ip_route": DEFAULT_ROUTE,
            "netplan": {"ethernets": "null", "wifis": "null"},
            "address": "10.9.9.9/24",
        }, lab, previous=None)
        if w:
            # "Nothing was there" is a state a document cannot express, so the
            # undo is a DELETION. A rollback that wrote an empty file would
            # leave netplan a document that configures nothing, which is not
            # the same machine as one with no OS/7 document at all.
            check(w["RolledBack"] is True, "with no previous document, the new one is deleted")
            check(w["FileExists"] is False, "and the path is gone, not left empty")

        w = run_write({
            "name": "an apply that produces nothing AND a rollback that does not either",
            "adapter": "eth0",
            # The worst outcome there is: the new configuration did not work and
            # the old one did not come back, so this machine is on neither. It
            # must not be reported as a tidy failure — an operator reading
            # "rolled back" would stop looking.
            "ip_addr": [[LO, ETH], [LO, ETH_NOADDR], [LO, ETH_NOADDR]],
            "ip_route": DEFAULT_ROUTE,
            "netplan": {"ethernets": "null", "wifis": "null"},
            "address": "10.9.9.9/24",
        }, lab, previous=previous)
        if w:
            check(w["RolledBack"] is False, "a rollback that did not come up is not RolledBack")
            check(w["RollbackFailed"] is True, "it is RollbackFailed, and that field exists for this")
            check("may be unreachable" in w["Detail"],
                  "and the detail says the machine may be unreachable", w["Detail"])

        print("\n  writing: -Force")
        w = run_write({
            "name": "-Force skips the check and therefore the rollback",
            "adapter": "eth0",
            "ip_addr": [[LO, ETH], [LO, ETH_NOADDR]],
            "ip_route": DEFAULT_ROUTE,
            "netplan": {"ethernets": "null", "wifis": "null"},
            "address": "10.9.9.9/24",
            "force": True,
        }, lab, previous=previous)
        if w:
            # $null, not $false: -Force did not check, and a check that did not
            # run must never read as one that failed OR passed.
            check(w["Verified"] is None,
                  "-Force leaves Verified null, not false", repr(w["Verified"]))
            check(w["RolledBack"] is False, "-Force does not roll back")
            check("10.9.9.9/24" in w["FileContent"],
                  "and the new document stays on the disk")
    finally:
        shutil.rmtree(lab, ignore_errors=True)

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed — the OS/7 layer draws the right conclusion from what "
          "ip and netplan say.")
    print("NOT CHECKED HERE: what ip and netplan actually say. Test-NetModule "
          "checks the readers against recorded real output and the netplan half "
          "against real netplan; run-phase3.py checks a machine.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
