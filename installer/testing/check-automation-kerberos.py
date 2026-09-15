#!/usr/bin/env python3
"""
M-AU7 on a real KDC, with nobody typing a password.

    ./installer/testing/check-automation-kerberos.py        ~2 min, needs docker

WHY THIS EXISTS. `docs/AUTOMATION-PLAN.md` AU7 says a job that needs a domain
identity gets its own ticket cache from a keytab, and M-AU7 asks for that to be
shown rather than asserted — *"AU7 is otherwise a sentence about Kerberos, and
this repository has learned what those are worth."*

It stayed a sentence for a day because measuring it seemed to need a keytab from
somebody: a domain join wants an administrator's password, and a `ktpass` export
wants somebody at a domain controller. **It needs neither.** `check-ad.py`
already stands up a REAL Samba AD DC in a container and provisions a realm, and
a DC can export a keytab for its own accounts with `samba-tool domain
exportkeytab` — run as root on the DC itself, with no prompt. So the whole of
M-AU7 is reachable by a harness, which is the only kind of evidence this
repository counts.

IT IMPORTS check-ad.py RATHER THAN COPYING IT. `build_images`, `start_dc` and
`stop_dc` are that file's, and a second copy of those docker invocations is
BUILD-NOTES #66 waiting to happen — the same reasoning `os7lab.py` gives for
calling `run-s5.py`'s `build_release_repo` with globals rebound instead of
reimplementing it. What is new here is a service account, a keytab, and four
questions about where a ticket lands.

WHAT IT ASSERTS, and the second one is AU7's whole reason for existing:

  * a keytab exported from a real DC is READ, not merely found — the three
    states `Get-DirectoryKeytabPrincipal` distinguishes, against a real file;
  * `New-OS7JobTicket` puts the ticket in the cache it was GIVEN;
  * and **the default cache stays empty**, because two jobs sharing one cache
    are two jobs sharing one identity and racing over its lifetime;
  * two jobs get two caches and neither can see the other's.

WHAT IT DOES NOT MEASURE, said plainly: **expiry.** M-AU7 asks for a ticket
"across expiry" and a Kerberos ticket's minimum lifetime on a Samba AD DC is
measured in minutes at best; a harness that slept that long would be a harness
nobody runs. Renewal before expiry is therefore still owed, and AU7 says so.
"""
import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# The service account this creates on the DC, and the cache paths it checks.
# A test realm's test account: the password below is in check-ad.py already and
# is a fixture, not a secret.
SVC = "svc-os7job"
SVC_PASSWORD = "Svc-Passw0rd-OS7-1!"
KEYTAB_IN_DC = "/tmp/svc-os7job.keytab"
KEYTAB_IN_CLIENT = "/probe/svc-os7job.keytab"

_ok = 0
_bad = 0
_failures = []


def check(cond, what, detail=""):
    global _ok, _bad
    if cond:
        _ok += 1
        print(f"      ok    {what}" + (f"   [{detail}]" if detail else ""))
    else:
        _bad += 1
        _failures.append(what)
        print(f"      FAIL  {what}" + (f"   [{detail}]" if detail else ""))
    return bool(cond)


def load_check_ad():
    """check-ad.py as a module.

    It guards its own `main()` behind `if __name__ == "__main__"`, so importing
    it starts nothing — and its constants (REALM, DC_NAME, the image names) are
    the ones this file must agree with. Reading them rather than repeating them
    is the point.
    """
    path = os.path.join(HERE, "check-ad.py")
    spec = importlib.util.spec_from_file_location("check_ad", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def docker(*args, **kwargs):
    kwargs.setdefault("capture_output", True)
    kwargs.setdefault("text", True)
    kwargs.setdefault("encoding", "utf-8")
    kwargs.setdefault("errors", "replace")
    return subprocess.run(["docker", *args], **kwargs)


def make_service_account(ad, dc_name):
    """A service account on the DC, and a keytab for it — with no prompt.

    `samba-tool` runs as root on the domain controller and does not ask for a
    password to act on its own directory, which is the whole reason this
    measurement needs nobody: the keytab that was missing yesterday is two
    commands away from a DC this repository already knows how to start.
    """
    script = f"""
set -e
samba-tool user create {SVC} '{SVC_PASSWORD}' \\
    --given-name=Service --surname=Job >/dev/null 2>&1 || true
samba-tool spn add HOST/{SVC}.{ad.REALM.lower()} {SVC} >/dev/null 2>&1 || true
rm -f {KEYTAB_IN_DC}
samba-tool domain exportkeytab {KEYTAB_IN_DC} --principal={SVC}@{ad.REALM}
ls -l {KEYTAB_IN_DC}
klist -k {KEYTAB_IN_DC} 2>/dev/null || true
"""
    r = docker("exec", dc_name, "bash", "-c", script)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        sys.exit("could not create the service account or export a keytab")
    return r.stdout


DRIVER = r'''
$ErrorActionPreference = 'Stop'
Import-Module /modules/OS7/OS7.psd1 -Force
Import-Module /modules/Directory/Directory.psd1 -Force

function Row($tag, $value) { Write-Output ("{0}`t{1}" -f $tag, $value) }

$keytab = $env:OS7_KEYTAB
$principal = $env:OS7_PRINCIPAL
$cacheA = '/tmp/cc-job-a'
$cacheB = '/tmp/cc-job-b'

# --- the keytab, read rather than found -------------------------------------
$k = Get-DirectoryKeytabPrincipal -KeytabPath $keytab
Row 'KT_KNOWN'      $k.Known
Row 'KT_HAS_ENTRY'  (@($k.Principal).Count -gt 0)
Row 'KT_PRINCIPALS' (@($k.Principal) -join ' ')

# A keytab that exists and holds the WRONG principal must be refused by name,
# and the refusal must say what IS in it. This is the path the empty keytab of
# 2026-09-15 could not reach.
$wrong = $null
try {
    New-OS7JobTicket -Keytab $keytab -Principal 'nobody/nowhere@OS7.TEST' -CachePath /tmp/cc-nope | Out-Null
}
catch { $wrong = $_.Exception.Message }
Row 'KT_WRONG_PRINCIPAL_REFUSED' ([bool]$wrong)
Row 'KT_REFUSAL_LISTS_CONTENTS'  ([bool]($wrong -and $wrong -match [regex]::Escape($principal)))

# --- the ticket, and WHERE it lands -----------------------------------------
# The default cache is emptied first, so "it is not there afterwards" means
# something. kdestroy on an empty cache is not an error worth stopping for.
try { & kdestroy 2>$null } catch { }

$t = New-OS7JobTicket -Keytab $keytab -Principal $principal -CachePath $cacheA
Row 'TICKET_OBTAINED'    ([bool]($t -and $t.Principal))
Row 'TICKET_PRINCIPAL'   $t.Principal
Row 'CACHE_A_EXISTS'     (Test-Path $cacheA)

# AU7'S WHOLE POINT. If the ticket also landed in the process's default cache,
# every job on the machine would be sharing one identity and racing over its
# lifetime — which is the thing AU7 exists to prevent.
$default = Get-DirectoryTicket
Row 'DEFAULT_CACHE_EMPTY' ([bool]($default.Principal -eq $null -or $default.Reason -eq 'no credential cache'))
Row 'DEFAULT_CACHE_REASON' ($default.Reason ?? '(none)')

# And the named cache is where the ticket can be seen.
$named = Get-DirectoryTicket -CachePath $cacheA
Row 'NAMED_CACHE_SEES_IT' ([bool]($named.Principal -and $named.Principal -match [regex]::Escape($principal.Split('@')[0])))
Row 'NAMED_CACHE_PRINCIPAL' ($named.Principal ?? '(none)')

# --- two jobs, two caches ---------------------------------------------------
$t2 = New-OS7JobTicket -Keytab $keytab -Principal $principal -CachePath $cacheB
Row 'CACHE_B_EXISTS' (Test-Path $cacheB)
Row 'TWO_CACHES_DISTINCT' ((Get-FileHash $cacheA).Hash -ne (Get-FileHash $cacheB).Hash)

# Destroying one must not touch the other — the failure AU7 names, where the
# first job's kdestroy takes the second job's ticket with it.
Remove-DirectoryTicket -CachePath $cacheA -Confirm:$false | Out-Null
Row 'A_DESTROYED'   (-not (Get-DirectoryTicket -CachePath $cacheA).Principal)
Row 'B_SURVIVES'    ([bool](Get-DirectoryTicket -CachePath $cacheB).Principal)

Row 'DRIVER_DONE' 'yes'
'''

PROBES = [
    ("KT_KNOWN", "a keytab exported from a real DC is readable"),
    ("KT_HAS_ENTRY", "and it holds at least one principal"),
    ("KT_WRONG_PRINCIPAL_REFUSED",
     "AU7 — a keytab that does not hold the principal asked for is refused"),
    ("KT_REFUSAL_LISTS_CONTENTS",
     "AU7 — and the refusal says what IS in it, because kinit picks by name"),
    ("TICKET_OBTAINED", "M-AU7 — a ticket is obtained from the keytab, with no password"),
    ("CACHE_A_EXISTS", "M-AU7 — and it is written to the cache the caller named"),
    ("DEFAULT_CACHE_EMPTY",
     "M-AU7 — THE DEFAULT CACHE STAYS EMPTY: two jobs sharing one cache are "
     "two jobs sharing one identity"),
    ("NAMED_CACHE_SEES_IT", "M-AU7 — and the named cache is where the ticket can be read"),
    ("CACHE_B_EXISTS", "M-AU7 — a second job gets a second cache"),
    ("TWO_CACHES_DISTINCT", "M-AU7 — and the two are not the same file"),
    ("A_DESTROYED", "M-AU7 — destroying one cache empties it"),
    ("B_SURVIVES",
     "M-AU7 — and leaves the other alone, which is the race AU7 exists to prevent"),
]


def run_driver(ad, address, image):
    """The driver in the client container, on the DC's network."""
    path = os.path.join(HERE, "driver-automation-kerberos.ps1")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(DRIVER)
    try:
        r = docker(
            "run", "--rm", "--network", ad.NETWORK,
            "--add-host", f"{ad.DC_HOST}:{address}",
            "-v", f"{os.path.join(REPO, 'powershell')}:/modules:ro",
            "-v", f"{HERE}:/probe:ro",
            "-e", f"OS7_KEYTAB={KEYTAB_IN_CLIENT}",
            "-e", f"OS7_PRINCIPAL={SVC}@{ad.REALM}",
            "-e", f"KRB5_CONFIG=/probe/krb5-automation.conf",
            image, "pwsh", "-NoProfile", "-File",
            "/probe/driver-automation-kerberos.ps1")
        rows = {}
        for line in (r.stdout or "").splitlines():
            if "\t" in line:
                k, v = line.split("\t", 1)
                rows[k.strip()] = v.strip()
        return rows, r
    finally:
        os.unlink(path)


def write_krb5_conf(ad, address):
    """A krb5.conf the client can use, written rather than discovered.

    The client container is not joined and has no DNS for the realm, so realm
    discovery would fail with `Cannot find KDC for realm` — which is exactly
    the message that sent a person to DNS on 2026-09-15 when the real problem
    was elsewhere. Naming the KDC here keeps this check measuring AU7 rather
    than measuring SRV lookups.
    """
    path = os.path.join(HERE, "krb5-automation.conf")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"""[libdefaults]
    default_realm = {ad.REALM}
    dns_lookup_kdc = false
    dns_lookup_realm = false

[realms]
    {ad.REALM} = {{
        kdc = {address}
        admin_server = {address}
    }}
""")
    return path


def main():
    if not subprocess.run(["docker", "version"], capture_output=True).returncode == 0:
        sys.exit("docker is needed: this check stands up a real KDC.")

    ad = load_check_ad()
    print("check-automation-kerberos — M-AU7 against a real KDC, no password typed")
    print(f"    realm {ad.REALM}, DC container {ad.DC_NAME}")

    print("    building the images (first run only) …")
    ad.build_images()

    address = ad.start_dc()
    conf = None
    try:
        print("\n### the keytab, exported by the DC itself\n")
        out = make_service_account(ad, ad.DC_NAME)
        for line in out.splitlines():
            print(f"      {line}")
        # The keytab has to reach the client. A docker cp out and in, rather
        # than a shared volume: the DC's /tmp is the DC's.
        local = os.path.join(HERE, os.path.basename(KEYTAB_IN_CLIENT))
        docker("cp", f"{ad.DC_NAME}:{KEYTAB_IN_DC}", local, check=True)
        size = os.path.getsize(local)
        check(size > 0, "the exported keytab is not empty",
              f"{size} bytes — the one offered by hand on 2026-09-15 was 0")

        conf = write_krb5_conf(ad, address)

        print("\n### the ticket, and where it lands\n")
        rows, r = run_driver(ad, address, ad.CLIENT_IMAGE)
        if "DRIVER_DONE" not in rows:
            print((r.stdout or "")[-1500:])
            print((r.stderr or "")[-1500:])
            check(False, "the driver ran to the end", "see the output above")
        else:
            for tag, what in PROBES:
                if tag not in rows:
                    check(False, what, f"the driver never reported {tag}")
                else:
                    check(rows[tag] in ("True", "true"), what, rows.get(tag, ""))
            for tag in ("KT_PRINCIPALS", "TICKET_PRINCIPAL", "NAMED_CACHE_PRINCIPAL",
                        "DEFAULT_CACHE_REASON"):
                if tag in rows:
                    print(f"      note  {tag} = {rows[tag]}")

        print("\n      note  EXPIRY IS NOT MEASURED HERE. M-AU7 asks for a ticket across "
              "expiry;")
        print("            the shortest lifetime a DC will issue is minutes, and a harness "
              "that")
        print("            slept for it is a harness nobody runs. Renewal is still owed.")
    finally:
        try:
            if conf and os.path.exists(conf):
                os.unlink(conf)
            local = os.path.join(HERE, os.path.basename(KEYTAB_IN_CLIENT))
            if os.path.exists(local):
                os.unlink(local)
        finally:
            ad.stop_dc()

    print(f"\n  {_ok} ok, {_bad} failed")
    if _bad:
        for f in _failures:
            print(f"    - {f}")
        print("\ncheck-automation-kerberos: RED")
        sys.exit(1)
    print("\ncheck-automation-kerberos: GREEN — M-AU7's ticket half is measured.")


if __name__ == "__main__":
    main()
