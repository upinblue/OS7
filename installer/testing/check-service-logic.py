#!/usr/bin/env python3
"""
`Get-OS7Service`'s HEALTHY rule, in seconds, with no systemd.

    ./check-service-logic.py

WHY IT EXISTS. `Healthy` is one boolean with four branches, and the first
version of it was wrong in a way only real output showed: `zfs-mount.service`
is a `oneshot`, it had succeeded, it was `inactive/dead` because that is what a
finished oneshot looks like — and the field reported it as unhealthy on a
perfectly well machine. Eight of fifteen OS/7 services read as unhealthy on a
machine with nothing wrong with it.

That is the failure mode that kills a health field: not being wrong about a
broken machine, but being wrong about a working one. A field that cries wolf
gets ignored, and then it is wrong about the broken machine too and nobody
notices.

So the branches are enumerated here, as states rather than as prose, and the
cases include the ones that must read as HEALTHY as carefully as the ones that
must not.

WHAT THIS IS NOT. It says nothing about what systemctl emits — `Test-SystemdModule`
checks that against recorded real output, including a journal MESSAGE that is a
byte array. This checks what OS/7's layer CONCLUDES from it.
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

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


# ---------------------------------------------------------------------------
# The states. Each is what `systemctl` would say about one unit, and what
# `Healthy` must conclude from it.
#
# The names are the real units these states were taken from, on a machine
# running real systemd — so the "supposed to be dead" cases are not invented.
# ---------------------------------------------------------------------------
CASES = [
    # name, active, sub, result, startup, type, expected Healthy, why
    ("chrony.service", "active", "running", "success", "enabled", "notify", True,
     "a service that is up and enabled"),
    ("authd.service", "active", "running", "success", "static", "notify", True,
     "a static service that is up"),
    # THE ONE THAT WAS WRONG. A finished oneshot is inactive/dead BY DESIGN.
    ("zfs-mount.service", "inactive", "dead", "success", "enabled", "oneshot", True,
     "a oneshot that has run is inactive/dead and is SUPPOSED to be"),
    ("os7-backup-firstboot.service", "inactive", "dead", "success", "enabled", "oneshot", True,
     "and so is OS/7's own first-boot unit"),
    ("ssh.service", "inactive", "dead", "success", "disabled", "notify", True,
     "a service nobody asked to start is not unhealthy for being stopped"),
    ("intune-daemon.service", "inactive", "dead", "success", "indirect", "simple", True,
     "nor is a socket-activated one that has not been triggered"),
    # The genuinely bad states.
    ("tpm-udev.service", "failed", "failed", "start-limit-hit", "enabled", "oneshot", False,
     "a failed unit is not healthy, oneshot or not"),
    ("flapping.service", "active", "auto-restart", "success", "enabled", "simple", False,
     "auto-restart is a RESTART LOOP, and is-active calls it active"),
    ("crashed.service", "inactive", "dead", "exit-code", "enabled", "simple", False,
     "a unit that stopped with a non-success Result"),
    ("zfs-zed.service", "inactive", "dead", "success", "enabled", "simple", False,
     "enabled, long-running, and not running — the case that should fire"),
]

DRIVER = r"""
$ErrorActionPreference = 'Stop'
Import-Module '{systemd}' -Force
Import-Module '{os7}' -Force

$case = Get-Content -Raw -LiteralPath '{casefile}' | ConvertFrom-Json -AsHashtable

# The fake answers as systemctl would: JSON for list-units, KEY=VALUE for show,
# and it honours the unit name -- a fake that returned the whole list for a
# named query staples one unit's state to another's detail, which is an object
# describing a machine that cannot exist.
& (Get-Module Systemd) {{
    param($c)
    $script:SystemdCommandOverride = {{
        param($cmd, $a)
        if ($a -contains 'show') {{
            $name = $a[1]
            $u = $c.units | Where-Object {{ $_.name -eq $name }}
            $lines = @(
                "Id=$($u.name)", "Description=$($u.name)",
                "LoadState=loaded", "ActiveState=$($u.active)", "SubState=$($u.sub)",
                "UnitFileState=$($u.startup)", "Result=$($u.result)",
                "NRestarts=0", "ExecMainPID=0", "ActiveEnterTimestamp=",
                "FragmentPath=/usr/lib/systemd/system/$($u.name)", "Type=$($u.type)")
            return [pscustomobject]@{{ StdOut = ($lines -join "`n"); ExitCode = 0; StdErr = '' }}
        }}
        $wanted = $a | Where-Object {{ $_ -like '*.service' }}
        $list = foreach ($u in $c.units) {{
            if ($wanted -and $u.name -ne $wanted) {{ continue }}
            [pscustomobject]@{{
                unit = $u.name; load = 'loaded'; active = $u.active
                sub = $u.sub; description = $u.name
            }}
        }}
        [pscustomobject]@{{
            # PIPED, not passed positionally. Passing an array positionally
            # with -AsArray wraps it in a SECOND array, which a one-element
            # case survives through member enumeration and which hands the
            # cmdlet an ARRAY of names as soon as there are two.
            StdOut = (@($list) | ConvertTo-Json -Depth 5 -Compress -AsArray)
            ExitCode = 0; StdErr = ''
        }}
    }}.GetNewClosure()
}} $case

$out = foreach ($u in $case.units) {{
    $s = @(Get-OS7Service -Name $u.name)[0]
    [pscustomobject]@{{ Name = $s.Name; Healthy = $s.Healthy; IsOS7 = $s.IsOS7 }}
}}
# And one call with no -Detailed, to check the $null rule.
$plain = @(Get-OS7Service)[0]

[pscustomobject]@{{
    Services       = @($out)
    PlainHealthy   = $plain.Healthy
    PlainName      = $plain.Name
}} | ConvertTo-Json -Depth 6 -Compress
"""


def main():
    print("### Get-OS7Service's HEALTHY rule")
    print(f"### {len(CASES)} unit states, no systemd, no VM\n")

    exe = shutil.which("pwsh")
    if not exe:
        sys.exit("pwsh not found; this check runs the real powershell/OS7 module.")

    lab = tempfile.mkdtemp(prefix="os7-svc-")
    try:
        payload = {"units": [
            {"name": n, "active": a, "sub": s, "result": r, "startup": st, "type": t}
            for (n, a, s, r, st, t, _, _) in CASES]}
        casefile = os.path.join(lab, "case.json")
        with open(casefile, "w", encoding="utf-8") as f:
            json.dump(payload, f)

        script = DRIVER.format(systemd=SYSTEMD.replace("'", "''"),
                               os7=OS7.replace("'", "''"),
                               casefile=casefile.replace("'", "''"))
        p = subprocess.run([exe, "-NoProfile", "-NonInteractive", "-Command", script],
                           capture_output=True, text=True)
        if p.returncode != 0:
            print(f"      FAIL  pwsh exited {p.returncode}")
            print("            " + (p.stderr.strip().replace("\n", "\n            ") or "(no stderr)"))
            return 1
        got = json.loads(p.stdout.strip())
        by_name = {s["Name"]: s for s in got["Services"]}

        print("  states that must read as HEALTHY")
        for (n, _a, _s, _r, _st, _t, want, why) in CASES:
            if not want:
                continue
            check(by_name.get(n, {}).get("Healthy") is True, why,
                  f"{n} -> {by_name.get(n, {}).get('Healthy')}")

        print("\n  states that must NOT")
        for (n, _a, _s, _r, _st, _t, want, why) in CASES:
            if want:
                continue
            check(by_name.get(n, {}).get("Healthy") is False, why,
                  f"{n} -> {by_name.get(n, {}).get('Healthy')}")

        print("\n  the rule that outranks all of them")
        # A check that did not run must never read as one that passed — the same
        # rule Get-OS7Version's Drift follows.
        check(got["PlainHealthy"] is None,
              "without -Detailed, Healthy is null and not true",
              f"{got['PlainName']} -> {got['PlainHealthy']}")

        print("\n  which services are OS/7's")
        check(by_name.get("os7-backup-firstboot.service", {}).get("IsOS7") is True,
              "an os7-* unit is one of ours")
        check(by_name.get("zfs-mount.service", {}).get("IsOS7") is True,
              "and so is a zfs one — a machine that cannot mount its pool is ours to care about")
        check(by_name.get("flapping.service", {}).get("IsOS7") is False,
              "an unrelated unit is not")
    finally:
        shutil.rmtree(lab, ignore_errors=True)

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed — Healthy is right about working machines as well as "
          "broken ones.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
