#!/usr/bin/env python3
"""
The device manager's STATE RULE, in seconds, with no hardware.

    ./check-device-logic.py

WHY IT EXISTS. `Get-OS7Device` puts every device on the machine into one of
five states, and four of them are a judgement made from three sources that can
each be absent, wrong, or silent. The judgement has an ORDER, and the order is
the rule: a DKMS module that will not load after the next reboot outranks a
card that could have a better driver, and both outrank "no driver is bound".

The failure mode that kills a view like this is not being wrong about a broken
machine. It is being wrong about a WORKING one — the shape
installer/testing/check-service-logic.py was written for after eight of fifteen
OS/7 services read as unhealthy on a machine with nothing wrong with it. A
device manager that opens with four faults on every computer ever built (every
one of them has host bridges, and none of them has a driver bound) is a device
manager nobody reads, and then it is wrong about the broken machine too and
nobody notices.

So the cases below include the ones that MUST read as Working as carefully as
the ones that must not, and three of them exist only because a source can fail:

    ubuntu-drivers absent   -> must NOT read as "nothing better exists"
    no module index         -> must NOT read as "no driver exists"
    dkms absent             -> must read as an ordinary machine

WHAT THIS IS NOT. It says nothing about what dkms, ubuntu-drivers or sysfs
emit — `Test-HardwareModule` checks the parsers against recorded real output,
including a `dkms status` in which a module whose build FAILED reads `added`.
This checks what OS/7's layer CONCLUDES from them.
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
OS7 = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")
HARDWARE = os.path.join(REPO, "powershell", "Hardware", "Hardware.psd1")
FIXTURES = os.path.join(REPO, "powershell", "Hardware", "tests", "fixtures")

FAILS = []
PASSES = 0


def check(ok, what, detail=""):
    global PASSES
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if ok:
        PASSES += 1
    else:
        FAILS.append(what)
    return ok


RUNNING = "6.14.0-35-generic"
OLD = "6.14.0-32-generic"

# ---------------------------------------------------------------------------
# The state rule, one machine per case.
#
# device            what sysfs says
# dkms              what `dkms status` parsed to
# offers            what ubuntu-drivers said — None means IT WAS NOT INSTALLED,
#                   which is not the same as an empty list and must not behave
#                   like one
# installed         packages already on the machine
# claimed           what modprobe -R said: None = could not be asked,
#                   [] = asked and nothing claims it
# ---------------------------------------------------------------------------
def dev(**kw):
    d = {
        "Bus": "PCI", "Address": "0000:01:00.0", "Class": "03", "SubClass": "00",
        "ClassName": "VGA compatible controller", "Driver": None,
        "Modalias": "pci:v000010DEd00002504sv00001458sd0000403Ebc03sc00i00",
        "SysfsPath": "/sys/bus/pci/devices/0000:01:00.0",
        "VendorId": "10de", "ProductId": "2504", "Description": "NVIDIA GA106",
        "Vendor": "NVIDIA", "Product": "GA106", "Interfaces": [],
        "SubsystemVendorId": None, "SubsystemProductId": None, "DriverBoundTo": None,
    }
    d.update(kw)
    return d


def dkms(name, version, rows):
    """rows: list of (kernel, status)."""
    return {
        "Name": name, "Version": version,
        "Kernels": [{"Kernel": k, "Architecture": "x86_64", "Status": s} for k, s in rows],
        "InstalledFor": [k for k, s in rows if s == "installed"],
        "BuiltFor": [k for k, s in rows if s == "built"],
    }


def offer(modalias, drivers, path="/sys/devices/pci0000:00/0000:01:00.0"):
    """drivers: list of (package, recommended, builtin)."""
    return {
        "SysfsPath": path, "Modalias": modalias,
        "Vendor": "NVIDIA Corporation", "Model": "GA106",
        "Drivers": [{"Package": p, "Recommended": r, "Builtin": b,
                     "Flags": [], "Source": "distro", "Free": False}
                    for p, r, b in drivers],
    }


NV_ALIAS = "pci:v000010DEd00002504sv00001458sd0000403Ebc03sc00i00"

CASES = [
    # ---- the cases that MUST read as Working ------------------------------
    dict(why="a host bridge with no driver is not a fault — every machine has one",
         device=dev(Class="06", SubClass="00", ClassName="Host bridge", Driver=None,
                    Description="Intel Host bridge"),
         claimed=[], expect="Working"),
    dict(why="a device with a driver and nothing better on offer",
         device=dev(Driver="i915"), offers=[], expect="Working"),
    dict(why="a DKMS module that IS installed for the running kernel",
         device=dev(Driver="r8168"),
         dkmsmods=[dkms("r8168", "8.053.00", [(RUNNING, "installed")])],
         offers=[], expect="Working"),
    dict(why="a package ubuntu-drivers offers that is ALREADY INSTALLED",
         device=dev(Driver="nvidia"),
         offers=[offer(NV_ALIAS, [("nvidia-driver-570", True, False)])],
         installed=["nvidia-driver-570"], expect="Working"),
    dict(why="a `builtin` driver is already in the kernel and is not an offer",
         device=dev(Driver="nouveau"),
         offers=[offer(NV_ALIAS, [("xserver-xorg-video-nouveau", False, True)])],
         expect="Working"),

    # ---- NeedsRebuild: the reason this feature exists ----------------------
    dict(why="a DKMS module built for the OLD kernel and not the running one",
         device=dev(Driver="r8168"),
         dkmsmods=[dkms("r8168", "8.053.00", [(OLD, "installed")])],
         offers=[], expect="NeedsRebuild"),
    dict(why="a DKMS module registered and built for NOTHING — which is also "
             "what a FAILED build looks like, because dkms has no word for one",
         device=dev(Driver="r8168"),
         dkmsmods=[dkms("r8168", "8.053.00", [])],
         offers=[], expect="NeedsRebuild"),
    dict(why="`built` is NOT `installed`: it compiled and is not in /lib/modules",
         device=dev(Driver="r8168"),
         dkmsmods=[dkms("r8168", "8.053.00", [(RUNNING, "built")])],
         offers=[], expect="NeedsRebuild"),
    dict(why="and NeedsRebuild outranks a better driver being available",
         device=dev(Driver="nvidia"),
         dkmsmods=[dkms("nvidia", "570.86", [(OLD, "installed")])],
         offers=[offer(NV_ALIAS, [("nvidia-driver-575", True, False)])],
         expect="NeedsRebuild"),

    # ---- DriverAvailable ---------------------------------------------------
    dict(why="the classic: nouveau works, nvidia-driver-570 is recommended",
         device=dev(Driver="nouveau"),
         offers=[offer(NV_ALIAS, [("nvidia-driver-535", False, False),
                                  ("nvidia-driver-570", True, False),
                                  ("xserver-xorg-video-nouveau", False, True)])],
         expect="DriverAvailable", command="Install-OS7Driver -Package nvidia-driver-570"),
    dict(why="nothing bound at all, and a package exists for it",
         device=dev(Driver=None),
         offers=[offer(NV_ALIAS, [("nvidia-driver-570", True, False)])],
         claimed=[], expect="DriverAvailable"),
    dict(why="nothing bound, no package, but the KERNEL has a module and it is "
             "not loaded — a driver that exists and is not live",
         device=dev(Driver=None), offers=[], claimed=["nouveau"],
         expect="DriverAvailable", command="Repair-OS7Driver -Address 0000:01:00.0"),

    # ---- NotSupported ------------------------------------------------------
    dict(why="nothing bound, nothing on offer, nothing in the kernel claims it",
         device=dev(Driver=None, VendorId="0e8d", ProductId="0616", Bus="USB",
                    Address="3-10", Class="e0", SubClass="01",
                    Modalias="usb:v0E8Dp0616d0100dcE0dsc01dp01icE0isc01ip01in00",
                    Description="MediaTek Wireless_Device"),
         offers=[], claimed=[], expect="NotSupported",
         command="Send-OS7HardwareProbe"),

    # ---- Unknown: the three sources that can fail --------------------------
    dict(why="THE ONE THAT WOULD BE DROPPED FIRST — no module index for this "
             "kernel means the question could not be asked, and folding that "
             "into NotSupported reports a working machine as having no drivers",
         device=dev(Driver=None), offers=[], claimed=None, expect="Unknown"),
    dict(why="ubuntu-drivers ABSENT must not read as 'nothing better exists': "
             "the device is Working, not DriverAvailable and not a lie",
         device=dev(Driver="nouveau"), offers=None, expect="Working"),
    dict(why="and dkms absent is an ordinary machine, not a broken one",
         device=dev(Driver="i915"), dkmsmods=[], offers=[], expect="Working"),

    # ---- the joins ---------------------------------------------------------
    dict(why="an offer for a DIFFERENT device's modalias is not this device's",
         device=dev(Driver="nouveau"),
         offers=[offer("pci:v00008086d00000A16sv0000sd0000bc03sc00i00",
                       [("some-other-driver", True, False)],
                       path="/sys/devices/pci0000:00/0000:00:02.0")],
         expect="Working"),
    # THE CASE THE FIRST VERSION OF THIS TEST ACCIDENTALLY WROTE, and which
    # turned out to be a real defect: the device HAS a modalias, no offer
    # matches it, and a weaker path join must not then overrule the answer the
    # stronger one already gave.
    dict(why="a modalias that matches nothing IS an answer — a path join must "
             "not overrule it",
         device=dev(Driver="nouveau"),
         offers=[offer("pci:v00008086d00000A16sv0000sd0000bc03sc00i00",
                       [("some-other-driver", True, False)])],
         expect="Working"),
    # And the case the fallback does exist for: a device sysfs gave no
    # modalias, matched to the offer by its slot.
    dict(why="a device with NO modalias is joined to its offer by sysfs path",
         device=dev(Driver="nouveau", Modalias=None),
         offers=[offer(NV_ALIAS, [("nvidia-driver-570", True, False)])],
         expect="DriverAvailable"),
    dict(why="a DKMS module with a different name is not this device's driver",
         device=dev(Driver="nouveau"),
         dkmsmods=[dkms("virtualbox", "7.0.14", [])], offers=[],
         expect="Working"),
]

DRIVER = r"""
$ErrorActionPreference = 'Stop'
Import-Module '{hardware}' -Force
Import-Module '{os7}' -Force

$cases = Get-Content -Raw -LiteralPath '{casefile}' | ConvertFrom-Json
$out = @()
foreach ($c in $cases) {{
    $dkms = @()
    foreach ($m in @($c.dkmsmods)) {{
        if ($null -eq $m) {{ continue }}
        $dkms += [pscustomobject]@{{
            Name = $m.Name; Version = $m.Version
            Kernels = @($m.Kernels)
            InstalledFor = @($m.InstalledFor); BuiltFor = @($m.BuiltFor)
        }}
    }}
    # $null MUST SURVIVE THE ROUND TRIP. ConvertFrom-Json gives $null for JSON
    # null; wrapping it in @() here would turn "ubuntu-drivers is not
    # installed" into "ubuntu-drivers found nothing", which is the exact
    # confusion two of these cases exist to catch.
    $offers = $c.offers
    if ($null -ne $offers) {{ $offers = @($offers) }}
    $claimed = $c.claimed
    if ($null -ne $claimed) {{ $claimed = @($claimed) }}

    $r = & (Get-Module OS7) {{
        param($d, $k, $dk, $of, $inst, $cl)
        Resolve-OS7DeviceState -Device $d -Kernel $k -DkmsModules $dk -Offers $of `
            -InstalledPackages $inst -ClaimedBy $cl
    }} $c.device '{running}' $dkms $offers @($c.installed) $claimed

    $out += [pscustomobject]@{{
        why = $c.why; State = $r.State; Action = $r.Action; Command = $r.Command
    }}
}}
$out | ConvertTo-Json -Depth 6 -Compress
"""


E2E = r"""
$ErrorActionPreference = 'Stop'
Import-Module '{hardware}' -Force
Import-Module '{os7}' -Force

# A sysfs tree, built from the fixture by the module's own materialiser.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("os7-dev-" + [guid]::NewGuid().ToString('N'))
& (Get-Module Hardware) {{
    param($f, $r) New-HardwareSysfsTree -FixtureFile $f -Root $r
}} (Join-Path '{fixtures}' 'sysfs-constructed.txt') $tmp

# /proc/modules, IN THE REAL FORMAT, so that "this module is loaded right now"
# is a fact read from a file rather than an assumption. r8168 is loaded AND is
# not built for the running kernel: the silent case, where everything works
# until the reboot.
$null = New-Item -ItemType Directory -Force -Path (Join-Path $tmp 'proc')
Set-Content -LiteralPath (Join-Path $tmp 'proc/modules') -Value @(
    'r8168 573440 0 - Live 0xffffffffc0a00000 (OE)'
    'zfs 4079616 12 zunicode,zzstd,zlua,icp Live 0xffffffffc0000000 (POE)'
) -Encoding utf8

# A machine, answered by a fake command layer. THE FAKE HONOURS THE COMMAND —
# one that returned the dkms answer to a modprobe question would make every
# check below pass for the wrong reason (BUILD-NOTES #16's shape).
# A HASHTABLE, NOT A $script: VARIABLE. `$script:` inside a closure resolves in
# the scope the closure RUNS in -- the Hardware module's -- not the one it was
# written in, so a counter declared here would be incremented somewhere else and
# read back as "never set". A hashtable is captured by reference by
# .GetNewClosure() and both sides see the same object.
$counter = @{{ probe = 0 }}
& (Get-Module Hardware) {{
    param($tmp, $counter)
    $script:HardwareCommandOverride = {{
        param($cmd, $a)
        switch ($cmd) {{
            'dkms' {{
                return [pscustomobject]@{{ ExitCode = 0; StdErr = ''; StdOut = @(
                    # r8168 is built for the OLD kernel: the regression.
                    'r8168/8.053.00, {old}, x86_64: installed'
                    # zfs is fine.
                    'zfs/2.3.4, {running}, x86_64: installed'
                    # vboxdrv is registered and built for nothing, and binds no
                    # device this machine can see. A device list would miss it.
                    'vboxdrv/7.0.14: added'
                ) -join "`n" }}
            }}
            'ubuntu-drivers' {{
                return [pscustomobject]@{{ ExitCode = 0; StdErr = ''
                    StdOut = (Get-Content -Raw -LiteralPath (Join-Path '{fixtures}' 'ubuntu-drivers-devices.txt')) }}
            }}
            'modprobe' {{
                # -R <modalias>. Nothing claims the Bluetooth dongle; the
                # unbound Intel NIC is claimed by a module that is not loaded.
                $alias = $a[-1]
                if ($alias -like 'pci:v00008086*') {{
                    return [pscustomobject]@{{ ExitCode = 0; StdOut = "e1000e`n"; StdErr = '' }}
                }}
                return [pscustomobject]@{{ ExitCode = 1; StdOut = ''
                    StdErr = "modprobe: FATAL: Module $alias not found.`n" }}
            }}
            'hw-probe' {{
                $counter.probe++
                return [pscustomobject]@{{ ExitCode = 127; StdOut = ''; StdErr = 'not found' }}
            }}
        }}
        return [pscustomobject]@{{ ExitCode = 127; StdOut = ''; StdErr = 'not found' }}
    }}.GetNewClosure()
}} $tmp $counter

try {{
    $all = @(Get-OS7Device -All -Kernel '{running}' -Root $tmp)
    $def = @(Get-OS7Device -Kernel '{running}' -Root $tmp)
    $drv = @(Get-OS7Driver -Kernel '{running}' -Root $tmp)
    $st = Get-OS7DeviceStatus -Kernel '{running}' -Root $tmp
    $calls = $counter.probe

    [pscustomobject]@{{
        all = @($all | Select-Object Address, State, Class, Name, SupportUrl, Command)
        default = @($def | Select-Object Address, State)
        drivers = @($drv | Select-Object Name, Healthy, Devices, Action, Loaded)
        orphaned = @($st.OrphanedDrivers | Select-Object Name)
        probeCalls = [int]($calls ?? 0)
        hwprobeAvailable = $st.HwProbeAvailable
        driverOffersChecked = $st.DriverOffersChecked
    }} | ConvertTo-Json -Depth 6 -Compress
}}
finally {{
    & (Get-Module Hardware) {{ $script:HardwareCommandOverride = $null }}
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}}
"""


# ---------------------------------------------------------------------------
# The update gate. Four verdicts, and only ONE of them stops an update.
#
# The rule has to be exactly right in both directions. Too strict and a machine
# carrying somebody's abandoned webcam module can never be updated again, and
# the operator's only route is the switch that turns the check off — which is
# the same as not having the check. Too loose and a network card disappears at
# the next reboot with nothing in the log.
# ---------------------------------------------------------------------------
GATE = r"""
$ErrorActionPreference = 'Stop'
Import-Module '{hardware}' -Force
Import-Module '{os7}' -Force

$new = '{running}'
$old = '{old}'

# `dkms status` AS IT WOULD READ INSIDE THE ASSEMBLED CLONE. Every one of these
# lines is in a shape recorded from real dkms 3.2.2 output.
& (Get-Module Hardware) {{
    param($new, $old)
    $script:HardwareCommandOverride = {{
        param($cmd, $a)
        if ($cmd -ne 'dkms') {{ return [pscustomobject]@{{ ExitCode = 127; StdOut = ''; StdErr = '' }} }}
        return [pscustomobject]@{{ ExitCode = 0; StdErr = ''; StdOut = @(
            # worked before, did not build for the new kernel -> REGRESSION
            "r8168/8.053.00, $old, x86_64: installed"
            # broken before and broken now -> warn only
            'oldcam/1.2: added'
            # built for both -> fine
            "zfs/2.3.4, $old, x86_64: installed"
            "zfs/2.3.4, $new, x86_64: installed"
            # was broken, now builds -> fixed
            "vboxdrv/7.0.14, $new, x86_64: installed"
            # NEW in this release, and it built. Not a regression: there is
            # nothing it used to do.
            "brandnew/1.0, $new, x86_64: installed"
            # NEW in this release and it did NOT build. Still not a regression,
            # because the machine never had it working.
            'brandbroken/1.0: added'
            # BUILT AND NOT INSTALLED for the new kernel. Reads like good news
            # in dkms's own words and is not: it is not in /lib/modules.
            "halfbaked/3.0, $old, x86_64: installed"
            "halfbaked/3.0, $new, x86_64: built"
        ) -join "`n" }}
    }}.GetNewClosure()
}} $new $old

try {{
    # What the RUNNING machine looked like before the update.
    $before = @(
        [pscustomobject]@{{ Name = 'r8168';     Version = '8.053.00'; Healthy = $true }}
        [pscustomobject]@{{ Name = 'oldcam';    Version = '1.2';      Healthy = $false }}
        [pscustomobject]@{{ Name = 'zfs';       Version = '2.3.4';    Healthy = $true }}
        [pscustomobject]@{{ Name = 'vboxdrv';   Version = '7.0.14';   Healthy = $false }}
        [pscustomobject]@{{ Name = 'halfbaked'; Version = '3.0';      Healthy = $true }}
    )
    $r = @(Get-OS7DriverRegression -Root '/run/os7-update' -Kernel $new -Before $before)
    @($r | Select-Object Module, Verdict, IsInstalled, WasInstalled, LogFile, Action) |
        ConvertTo-Json -Depth 4 -Compress
}}
finally {{
    & (Get-Module Hardware) {{ $script:HardwareCommandOverride = $null }}
}}
"""


def run_powershell(script):
    r = subprocess.run(["pwsh", "-NoProfile", "-Command", script],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr, file=sys.stderr)
        raise SystemExit(f"pwsh exited {r.returncode}")
    return r.stdout.strip(), r.stderr


def main():
    print("\ncheck-device-logic — the state rule, no hardware, no dkms, no network")

    if not os.path.exists(HARDWARE):
        raise SystemExit(f"the Hardware module is not at {HARDWARE}")

    # ---- part 1: the state rule, case by case --------------------------
    print("\n  the state rule")
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump([{**c,
                    "dkmsmods": c.get("dkmsmods", []),
                    "offers": c.get("offers", None),
                    "installed": c.get("installed", []),
                    "claimed": c.get("claimed", None)} for c in CASES], fh)
        casefile = fh.name
    try:
        out, _ = run_powershell(DRIVER.format(
            hardware=HARDWARE, os7=OS7, casefile=casefile, running=RUNNING))
        got = json.loads(out)
        if isinstance(got, dict):
            got = [got]
        for want, have in zip(CASES, got):
            check(have["State"] == want["expect"], want["why"],
                  f"{have['State']}, wanted {want['expect']}")
            if "command" in want:
                check(have["Command"] == want["command"],
                      "    and the command it offers", str(have["Command"]))
            # A device that needs attention with nothing to say about it is
            # half a device manager.
            if have["State"] != "Working":
                check(bool(have["Action"]), "    and it says what is wrong")
    finally:
        os.unlink(casefile)

    # ---- part 2: the cmdlet, end to end, over a real sysfs tree --------
    print("\n  Get-OS7Device, over a sysfs tree built from the fixture")
    out, _ = run_powershell(E2E.format(
        hardware=HARDWARE, os7=OS7, fixtures=FIXTURES, running=RUNNING, old=OLD))
    e2e = json.loads(out)

    by_addr = {d["Address"]: d for d in e2e["all"]}
    # FIVE, not six: the fixture has six entries and one of them is a USB
    # INTERFACE, which is never a device of its own.
    check(len(e2e["all"]) == 5, "every device in the tree came back, and the "
          "USB interface is not one of them", str(len(e2e["all"])))
    check(by_addr["0000:00:00.0"]["State"] == "Working",
          "the host bridge is Working, not a fault",
          by_addr["0000:00:00.0"]["State"])
    check(by_addr["0000:01:00.0"]["State"] == "DriverAvailable",
          "the NVIDIA card on nouveau offers nvidia-driver-570",
          by_addr["0000:01:00.0"]["State"])
    check(by_addr["0000:02:00.0"]["State"] == "NeedsRebuild",
          "the r8168 DKMS module is not built for the running kernel",
          by_addr["0000:02:00.0"]["State"])
    check(by_addr["3-10"]["State"] == "NotSupported",
          "the Bluetooth dongle has no driver anywhere",
          by_addr["3-10"]["State"])

    # THE DEFAULT VIEW IS THE FEATURE.
    check(len(e2e["default"]) == 4,
          "the DEFAULT view drops the working devices", str(len(e2e["default"])))
    check(all(d["State"] != "Working" for d in e2e["default"]),
          "and not one of them is Working")
    check(e2e["default"][0]["State"] == "NeedsRebuild",
          "worst first: NeedsRebuild is at the top, not sorted alphabetically",
          e2e["default"][0]["State"])

    # The friendly class, which is the whole reason a Windows admin can read it.
    check(by_addr["0000:01:00.0"]["Class"] == "Display", "a GPU is Display",
          by_addr["0000:01:00.0"]["Class"])
    check(by_addr["3-10"]["Class"] == "Bluetooth",
          "USB class e0 SUBCLASS 01 is Bluetooth, not merely Wireless",
          by_addr["3-10"]["Class"])
    check(by_addr["0000:02:00.0"]["Class"] == "Network", "a NIC is Network",
          by_addr["0000:02:00.0"]["Class"])

    # Only the unsupported device gets a database link, and nothing was fetched.
    check(by_addr["3-10"]["SupportUrl"] and "linux-hardware.org" in by_addr["3-10"]["SupportUrl"],
          "NotSupported carries a linux-hardware.org URL, computed and not fetched")
    check(by_addr["0000:01:00.0"]["SupportUrl"] is None,
          "and a device that is merely improvable does not")

    # ---- part 3: the drivers, including the one with no device ---------
    print("\n  Get-OS7Driver")
    names = {d["Name"]: d for d in e2e["drivers"]}
    check("r8168" in names, "the DKMS module bound to a device")
    check(names["r8168"]["Healthy"] is False, "and it is not healthy")
    check(names["r8168"]["Devices"], "and it names the device that will stop working",
          str(names["r8168"]["Devices"]))
    # THE ONE A DEVICE LIST WOULD MISS.
    check("vboxdrv" in names, "a DKMS module bound to NO visible device is still listed")
    check(names["vboxdrv"]["Devices"] == [] or names["vboxdrv"]["Devices"] is None,
          "and it has no device")
    check(len(e2e["orphaned"]) == 1,
          "the status report calls it out separately", str(len(e2e["orphaned"])))
    check("zfs" in names and names["zfs"]["Healthy"] is True,
          "a DKMS module that IS installed for the running kernel is healthy")

    # The sentence that describes the silent case.
    check("not come back after the next reboot" in (names["r8168"]["Action"] or ""),
          "a loaded-but-not-built module says it will be gone after the reboot",
          names["r8168"]["Action"])

    # ---- part 4: nothing here contacts anything -------------------------
    print("\n  the boundary")
    check(e2e["probeCalls"] == 0,
          "NOTHING in a status run invokes hw-probe — not once")
    check(e2e["hwprobeAvailable"] is False,
          "and the report says the tool is not there rather than staying silent")
    check(e2e["driverOffersChecked"] is True,
          "and it says whether the better-driver question could be asked at all")

    # ---- part 5: the update gate ---------------------------------------
    print("\n  the update gate — Update-OS7 step 6''")
    out, _ = run_powershell(GATE.format(
        hardware=HARDWARE, os7=OS7, running=RUNNING, old=OLD))
    gate = {d["Module"]: d for d in json.loads(out)}

    check(gate["r8168"]["Verdict"] == "Regression",
          "a driver that works NOW and did not build is a Regression — it BLOCKS",
          gate["r8168"]["Verdict"])
    check(gate["oldcam"]["Verdict"] == "StillBroken",
          "a driver that was ALREADY broken only warns — otherwise a machine "
          "carrying one could never be updated again",
          gate["oldcam"]["Verdict"])
    check(gate["zfs"]["Verdict"] == "Fine", "a driver built for both", gate["zfs"]["Verdict"])
    check(gate["vboxdrv"]["Verdict"] == "Fixed",
          "a driver the update repaired", gate["vboxdrv"]["Verdict"])
    check(gate["brandnew"]["Verdict"] == "Fine",
          "a driver NEW in this release that built is fine", gate["brandnew"]["Verdict"])
    check(gate["brandbroken"]["Verdict"] == "StillBroken",
          "a driver NEW in this release that did NOT build is not a regression: "
          "there is nothing it used to do", gate["brandbroken"]["Verdict"])
    # THE ONE THAT READS LIKE GOOD NEWS IN dkms's OWN WORDS.
    check(gate["halfbaked"]["Verdict"] == "Regression",
          "`built` for the new kernel is NOT installed, is not in /lib/modules, "
          "and is a regression however healthy the word sounds",
          gate["halfbaked"]["Verdict"])

    blocking = [m for m, d in gate.items() if d["Verdict"] == "Regression"]
    check(sorted(blocking) == ["halfbaked", "r8168"],
          "and exactly two of the eight block the update", str(sorted(blocking)))

    # A refusal with nowhere to look is half a refusal.
    check(gate["r8168"]["LogFile"] == "/var/lib/dkms/r8168/8.053.00/build/make.log",
          "a blocked driver names the compiler log, which is the ONLY place the "
          "reason exists", str(gate["r8168"]["LogFile"]))
    check(gate["zfs"]["LogFile"] is None, "and a healthy one does not")

    print(f"\n  {PASSES} passed, {len(FAILS)} failed")
    for f in FAILS:
        print(f"    FAIL  {f}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
