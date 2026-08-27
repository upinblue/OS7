#!/usr/bin/env python3
"""
The management plane's DECISIONS — Entra, Intune, Arc — in seconds, no VM.

    ./check-management-logic.py                     find an os7img:* image
    ./check-management-logic.py --image os7img:116

WHY IT EXISTS. `Get-OS7EntraStatus` says whether a machine can sign a user in
with Entra, and on an OS/7 image as built today the answer is NO — authd is
installed, PAM is wired to it, and `/etc/authd/brokers.d/` is empty, so there is
no broker to bridge to and a sign-in fails as though the password were wrong.
That is C8a measured on the artefact (BUILD-NOTES #93), and a cmdlet whose whole
job is to make it visible has to be shown to actually fire.

The states are constructed by moving REAL FILES on a REAL image: a broker
descriptor into `brokers.d`, a `common-auth` with and without `pam_authd_exec`.
The packages, the services and dpkg are the image's own — so what varies is what
this check controls, and nothing else is simulated.

WHAT IT DOES NOT CHECK. Whether a machine is ENROLLED in Intune.
`Get-OS7IntuneEnrollment` answers `$null` there on purpose and this check
asserts that it keeps doing so: `intune-agent` exposes no status interface
(measured — its options are `--interactive`, `--socket-path`, `--help`,
`--version`), and no enrolled machine has ever been available to learn the
on-disk state from. A guess about compliance is worse than a gap.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


def find_image(explicit):
    if explicit:
        return explicit
    try:
        out = subprocess.run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                             capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    for line in out.splitlines():
        if line.startswith("os7img:"):
            return line.strip()
    return None


# systemd runs as PID 1 so that the service states are real. authd.service being
# `active` is part of what `Ready` is made of, and a container without systemd
# would make every case answer $null for the same reason.
SCRIPT = r"""
set -e
LAB=/tmp/lab
mkdir -p $LAB/brokers-empty $LAB/brokers-one $LAB/staged-empty
cat > $LAB/brokers-one/msentraid.conf <<'CONF'
[authd]
name = msentraid
brand_icon = /usr/share/backgrounds/msentraid.png
dbus_name = com.ubuntu.authd.msentraid
dbus_object = /com/ubuntu/authd/msentraid
CONF
# A common-auth with the authd line, and one without it. Taken from the real
# file so that what changes is one line and not the whole stack.
cp /etc/pam.d/common-auth $LAB/pam-with
grep -v 'pam_authd_exec' /etc/pam.d/common-auth > $LAB/pam-without

pwsh -NoProfile -NonInteractive -Command '
Import-Module /work/powershell/OS7/OS7.psd1 -Force

function Use-State([string]$brokers, [string]$pam, [string]$staged) {
    & (Get-Module OS7) {
        param($b, $p, $s)
        $script:OS7AuthdBrokerDir  = $b
        $script:OS7PamCommonAuth   = $p
        $script:OS7StagedPackageDir = $s
    } $brokers $pam $staged
}

$out = @{}

Use-State "/tmp/lab/brokers-empty" "/tmp/lab/pam-with" "/var/cache/os7/packages"
$e = Get-OS7EntraStatus
$out.NoBroker = @{ Ready = $e.Ready; Registered = $e.BrokerRegistered
                   Pam = $e.PamConfigured; Svc = $e.ServiceState; Detail = $e.Detail }

Use-State "/tmp/lab/brokers-one" "/tmp/lab/pam-with" "/var/cache/os7/packages"
$e = Get-OS7EntraStatus
$out.WithBroker = @{ Ready = $e.Ready; Registered = $e.BrokerRegistered
                     Brokers = @($e.Brokers); Detail = $e.Detail }

Use-State "/tmp/lab/brokers-one" "/tmp/lab/pam-without" "/var/cache/os7/packages"
$e = Get-OS7EntraStatus
$out.NoPam = @{ Ready = $e.Ready; Pam = $e.PamConfigured; Detail = $e.Detail }

Use-State "/tmp/lab/brokers-one" "/tmp/lab/nonexistent-common-auth" "/var/cache/os7/packages"
$e = Get-OS7EntraStatus
$out.NoPamFile = @{ Ready = $e.Ready; Pam = $e.PamConfigured }

# BACK TO A KNOWN STATE FIRST. The case above deliberately points at a
# common-auth that does not exist, and Get-OS7IntuneEnrollment reads the same
# variable -- so leaving it there would test Intune against a missing file and
# call it a defect in Intune.
Use-State "/tmp/lab/brokers-one" "/tmp/lab/pam-with" "/var/cache/os7/packages"
$i = Get-OS7IntuneEnrollment
$out.Intune = @{ Installed = $i.Installed; Version = $i.Version; Pam = $i.PamConfigured
                 Enrolled = $i.Enrolled; Reason = $i.EnrolledReason }

Use-State "/tmp/lab/brokers-one" "/tmp/lab/pam-with" "/var/cache/os7/packages"
$a = Get-OS7ArcStatus
$out.ArcStaged = @{ Installed = $a.Installed; Staged = @($a.StagedPackage)
                    Connected = $a.Connected; Detail = $a.Detail }

Use-State "/tmp/lab/brokers-one" "/tmp/lab/pam-with" "/tmp/lab/staged-empty"
$a = Get-OS7ArcStatus
$out.ArcNothing = @{ Installed = $a.Installed; Staged = @($a.StagedPackage); Detail = $a.Detail }

Use-State "/tmp/lab/brokers-empty" "/tmp/lab/pam-with" "/var/cache/os7/packages"
$m = Get-OS7ManagementStatus -SkipNetwork
$out.Summary = $m.Summary

[pscustomobject]$out | ConvertTo-Json -Depth 8 -Compress
' 2>/dev/null | tail -1
"""


def main():
    ap = argparse.ArgumentParser(description="the management plane's decisions")
    ap.add_argument("--image", help="an OS/7 container image, e.g. os7img:116")
    args = ap.parse_args()

    print("### the management plane's decisions — Entra, Intune, Arc")

    if not shutil.which("docker"):
        print("\n      NOTE  NOT CHECKED. docker is needed: this wants real dpkg and real systemd.")
        return 0
    image = find_image(args.image)
    if not image:
        print("\n      NOTE  NOT CHECKED. No OS/7 container image found.")
        print("      NOTE  This wants the real authd, intune and dpkg together, which exist")
        print("      NOTE  as an artefact and not as files in the tree. Pass --image <tag>.")
        return 0
    print(f"### against {image}, with systemd as PID 1\n")

    cid = subprocess.run(
        ["docker", "run", "-d", "--privileged", "--cgroupns=host",
         "-v", "/sys/fs/cgroup:/sys/fs/cgroup:rw", "-v", f"{REPO}:/work:ro",
         "--entrypoint", "", image, "/sbin/init"],
        capture_output=True, text=True).stdout.strip()
    if not cid:
        print("      NOTE  NOT CHECKED. Could not start a systemd container.")
        return 0

    try:
        subprocess.run(["docker", "exec", cid, "bash", "-c",
                        "for i in $(seq 30); do systemctl is-system-running >/dev/null 2>&1 && break; "
                        "systemctl is-system-running 2>/dev/null | grep -q degraded && break; sleep 1; done"],
                       capture_output=True)
        p = subprocess.run(["docker", "exec", cid, "bash", "-c", SCRIPT],
                           capture_output=True, text=True)
        if p.returncode != 0 or not p.stdout.strip():
            print(f"      FAIL  the probe exited {p.returncode}")
            print("            " + (p.stderr.strip().replace("\n", "\n            ")[:800] or "(no stderr)"))
            return 1
        got = json.loads(p.stdout.strip().splitlines()[-1])
    finally:
        subprocess.run(["docker", "rm", "-f", cid], capture_output=True)

    print("  Entra: the state every OS/7 image is actually in")
    nb = got["NoBroker"]
    check(nb["Registered"] is False, "an empty brokers.d is no broker registered")
    check(nb["Pam"] is True, "with PAM still wired to authd — the two are separate facts")
    check(nb["Svc"] == "active", "and authd.service running", nb["Svc"])
    # THE POINT. Everything looks installed and nothing works.
    check(nb["Ready"] is False, "Ready is FALSE even though authd is installed and running")
    # The detail names the directory it actually looked at — which under this
    # check is the override, not /etc/authd/brokers.d. Asserting the literal
    # production path would be asserting that the cmdlet ignores its own
    # configuration.
    check("is empty" in nb["Detail"] and "C8a" in nb["Detail"],
          "and the detail names the directory it looked at, and the open question",
          nb["Detail"][:60])

    print("\n  Entra: with a broker registered")
    wb = got["WithBroker"]
    check(wb["Registered"] is True, "a .conf in brokers.d is a registered broker")
    check("msentraid.conf" in wb["Brokers"], "and it is named", ", ".join(wb["Brokers"]))
    check(wb["Ready"] is True, "Ready becomes TRUE — so the FALSE above was caused by the broker")

    print("\n  Entra: the other ways it can be broken")
    np = got["NoPam"]
    check(np["Pam"] is False, "a common-auth without pam_authd_exec is not configured")
    check(np["Ready"] is False, "and Ready is false even with a broker registered")
    check("nothing uses it" in np["Detail"], "with a detail that says which half is missing",
          np["Detail"][:60])
    npf = got["NoPamFile"]
    # "cannot tell" is not "broken", and it is not "clean" either.
    check(npf["Pam"] is None, "no common-auth at all is null, not false")
    check(npf["Ready"] is None, "and Ready is null rather than a verdict")

    print("\n  Intune: what is answered and what is refused")
    i = got["Intune"]
    check(i["Installed"] is True, "intune-portal is installed on this image", i["Version"] or "")
    check(i["Pam"] is True, "and pam_intune.so is in the auth stack")
    # The field this cmdlet exists to NOT get wrong.
    check(i["Enrolled"] is None, "Enrolled is null — never false", repr(i["Enrolled"]))
    check("no status interface" in i["Reason"],
          "and it says why, rather than leaving a null to be read as a bug")

    print("\n  Arc: not installed, and that is deliberate")
    a = got["ArcStaged"]
    check(a["Installed"] is False, "azcmagent is not installed")
    check(any("azcmagent" in s for s in a["Staged"]),
          "the .deb is staged for the installer", ", ".join(a["Staged"]))
    check(a["Connected"] is None, "Connected is null: never connected is not disconnected")
    check("deliberate" in a["Detail"], "and the detail says the absence is on purpose")
    an = got["ArcNothing"]
    check(an["Staged"] == [], "with nothing staged, nothing is claimed")
    check("no package is staged" in an["Detail"], "and the detail changes accordingly",
          an["Detail"][:60])

    print("\n  the one line an operator reads first")
    check("is empty" in got["Summary"] and "C8a" in got["Summary"],
          "the summary names the blocking problem, not a colour", got["Summary"][:60])

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed — the management plane reports what is true, including "
          "the parts it cannot know.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
