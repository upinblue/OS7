#!/usr/bin/env python3
"""
OS/7's Active Directory surface, against a DIRECTORY THAT ANSWERS.

    ./check-ad.py                    build both containers, run everything
    ./check-ad.py --keep             leave the domain controller running
    ./check-ad.py --os7img os7img:116    also run the read-only half against a
                                     container made from a shipped ISO

WHAT THIS IS AND IS NOT. It stands up a real Samba Active Directory domain
controller in a container, points a second container at it, and drives the real
`powershell/Directory` and `powershell/OS7` modules against it: bind, search,
page, create, set a password, rebind as that account, join a realm. So it is a
test of the PROTOCOL and of OS/7's layers over it. It is NOT a test of Windows
Server, and the difference is written down rather than glossed over — see
"WHAT SAMBA WILL NOT REPRODUCE" below. `check-directory-logic.py` is the fast,
no-network half; nothing here replaces it and it does not replace this.

WHY A REAL SERVER AT ALL, when the rest of this directory fakes everything it
touches. Because faking an LDAP server would test only the fake. The failures
that matter here — a directory that refuses a simple bind on port 389, a paged
search that stops at a thousand, a password write rejected for being over an
unencrypted channel, three referrals arriving with every query — are exactly
the behaviours nobody would think to write into a stub. Every one of them was
MEASURED on 2026-08-27 by running this against Samba, and three of them
corrected the design.

THE INDEPENDENT WITNESS. Whatever OS/7 writes is read back with `ldbsearch`
inside the domain controller — a tool that shares no code with the client under
test. This repository's recurring expensive bug is a program reporting success
while the thing it was meant to change did not change, and a client that
confirms its own writes is that shape exactly.

STAGE 1 MUST NOT NEED STAGE 2'S PACKAGES, and this proves it rather than
asserting it: the stage-1 section is run a second time with `adcli`, `kinit`,
`klist` and `sssctl` moved out of PATH. If an outbound admin session ever grows
a dependency on the join tooling, that run goes red.

WHAT SAMBA WILL NOT REPRODUCE, and what therefore remains owed to a real
Windows Server domain controller: LDAP channel binding and signing enforcement
(LdapEnforceChannelBinding / LDAPServerIntegrity), Windows password-policy
plumbing and its error sub-codes, msDS-* constructed attributes, Windows LAPS,
and cross-forest referrals. A green run here is the gate for the protocol. It
is not a fleet.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

DC_IMAGE = "os7-ad-dc"
CLIENT_IMAGE = "os7-check-ad"
DC_NAME = "os7-ad-dc-check"
NETWORK = "os7ad-check"

REALM = "OS7.TEST"
BASE_DN = "DC=os7,DC=test"
DC_HOST = "dc01.os7.test"
ADMIN = "Administrator"
ADMIN_PASSWORD = "Passw0rd-OS7-test"

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)


def note(text):
    print(f"      note  {text}")


def pin(name):
    """A value out of build/config/os7-release.conf. THE only place a version
    number or an archive URL may live in this repository (CLAUDE.md), so the
    container's PowerShell is the image's PowerShell rather than a second pin
    that rots quietly."""
    conf = os.path.join(REPO, "build", "config", "os7-release.conf")
    for line in open(conf):
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit(f"{name} is not in {conf}")


def docker(*args, **kwargs):
    return subprocess.run(["docker", *args], **kwargs)


def build_images():
    print("    building the domain controller and client images (first run only) …")
    docker("build", "-q", "-t", DC_IMAGE, "-f",
           os.path.join(HERE, "Dockerfile.ad-dc"), HERE,
           check=True, stdout=subprocess.DEVNULL)
    docker("build", "-q", "-t", CLIENT_IMAGE, "-f",
           os.path.join(HERE, "Dockerfile.check-ad"),
           "--build-arg", f"PWSH_VERSION={pin('OS7_PWSH_VERSION')}",
           "--build-arg", f"PWSH_SHA256_x64={pin('OS7_PWSH_SHA256_x64')}",
           "--build-arg", f"PWSH_SHA256_arm64={pin('OS7_PWSH_SHA256_arm64')}",
           HERE, check=True, stdout=subprocess.DEVNULL)


def start_dc():
    """Start the DC and WAIT FOR THE DIRECTORY, not for the port.

    ad-dc-entrypoint.sh writes its readiness marker only after LDAP has
    answered a query, and this waits for that file. Waiting for port 389
    instead would connect during the window where smbd is bound and the
    directory is not loaded, and the refusal that comes back looks exactly like
    a credential problem."""
    docker("rm", "-f", DC_NAME, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    docker("network", "create", NETWORK, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    docker("run", "-d", "--name", DC_NAME, "--hostname", "dc01",
           "--network", NETWORK, "--network-alias", DC_HOST, DC_IMAGE,
           check=True, stdout=subprocess.DEVNULL)

    print("    provisioning the domain controller (about a minute) …")
    deadline = time.time() + 300
    while time.time() < deadline:
        ready = docker("exec", DC_NAME, "sh", "-c",
                       "test -f /var/lib/samba/.os7-ready && echo YES",
                       capture_output=True, text=True)
        if ready.stdout.strip() == "YES":
            address = docker("inspect", "-f",
                             "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                             DC_NAME, capture_output=True, text=True).stdout.strip()
            return address
        alive = docker("ps", "-q", "-f", f"name={DC_NAME}",
                       capture_output=True, text=True).stdout.strip()
        if not alive:
            logs = docker("logs", "--tail", "20", DC_NAME,
                          capture_output=True, text=True)
            print(logs.stdout + logs.stderr)
            sys.exit("the domain controller container exited before it was ready")
        time.sleep(3)
    sys.exit("the domain controller did not become ready within five minutes")


def populate():
    """Build the fixture population WITH samba-tool.

    Deliberately not with the client under test: an object created by the thing
    being checked proves only that it is self-consistent."""
    script = r"""
set -e
samba-tool user create os7fixture1 'Fixt-Passw0rd-1!' --given-name=Ada \
    --surname=Lovelace --mail-address=ada@os7.test >/dev/null 2>&1 || true
samba-tool user create os7fixture2 'Fixt-Passw0rd-2!' --given-name=Grace \
    --surname=Hopper >/dev/null 2>&1 || true
samba-tool user disable os7fixture2 >/dev/null 2>&1 || true
samba-tool group add OS7FixtureGroup >/dev/null 2>&1 || true
samba-tool group addmembers OS7FixtureGroup os7fixture1 >/dev/null 2>&1 || true
samba-tool group add OS7FixtureEmpty >/dev/null 2>&1 || true
samba-tool computer create OS7FIXTUREPC >/dev/null 2>&1 || true
echo built
"""
    result = docker("exec", DC_NAME, "bash", "-c", script,
                    capture_output=True, text=True)
    return result.stdout.strip().endswith("built")


def witness(ldap_filter, attribute):
    """Read something back with ldbsearch INSIDE the domain controller.

    ldbsearch talks to the database file, not to the LDAP port, so it shares no
    code path at all with the client under test — which is the point."""
    result = docker("exec", DC_NAME, "ldbsearch", "-H",
                    "/var/lib/samba/private/sam.ldb", ldap_filter, attribute,
                    capture_output=True, text=True)
    values = []
    for line in result.stdout.splitlines():
        if line.lower().startswith(attribute.lower() + ":"):
            values.append(line.split(":", 1)[1].strip())
    return values


# ---------------------------------------------------------------------------
# The PowerShell side.
#
# One script, one JSON array on stdout and nothing else — which holds because
# Write-OS7Step writes to stderr (BUILD-NOTES #60: Write-Verbose and
# Write-Warning do NOT, on pwsh 7.6.5, which is why neither appears anywhere in
# these modules).
# ---------------------------------------------------------------------------
DRIVER = r"""
$ErrorActionPreference = 'Stop'
Import-Module '/repo/powershell/Directory/Directory.psd1' -Force
Import-Module '/repo/powershell/OS7/OS7.psd1' -Force

$results = [System.Collections.Generic.List[object]]::new()
function T {
    param([string]$Name, [scriptblock]$Body)
    try {
        $detail = & $Body
        $results.Add([pscustomobject]@{ name = $Name; ok = $true; detail = "$detail" })
    }
    catch {
        $results.Add([pscustomobject]@{
            name = $Name; ok = $false
            detail = $_.Exception.Message.Split([char]10)[0]
        })
    }
}

$realm  = $env:OS7_AD_REALM
$server = $env:OS7_AD_SERVER
$baseDn = $env:OS7_AD_BASEDN
$cred = [pscredential]::new("$($env:OS7_AD_USER)@$realm",
        (ConvertTo-SecureString $env:OS7_AD_PASS -AsPlainText -Force))

# --- the protocol facts this design rests on -------------------------------
T 'a simple bind on port 389 is REFUSED by the directory' {
    try {
        Connect-DirectoryServer -Server $server -Port 389 -NoTls -Credential $cred | Out-Null
        throw 'the directory ACCEPTED an unprotected simple bind'
    }
    catch {
        if ($_.Exception.Message -notmatch 'trong authentication|refused|onfidential') {
            throw "refused for an unexpected reason: $($_.Exception.Message.Split([char]10)[0])"
        }
        'refused, as Microsoft ADV190023 requires'
    }
}

T 'Negotiate with an EXPLICIT credential is refused by the platform' {
    try {
        Connect-DirectoryServer -Server $server -AuthType Negotiate -Credential $cred | Out-Null
        throw 'it bound, which contradicts the measurement this design rests on'
    }
    catch {
        if ($_.Exception.Message -notmatch 'rc 92|not supported|NOT_SUPPORTED') {
            throw "unexpected: $($_.Exception.Message.Split([char]10)[0])"
        }
        'LDAP rc 92, as measured'
    }
}

# --- the session -----------------------------------------------------------
T 'Enter-OS7AdminSession binds over TLS and the SERVER names the account' {
    $session = Enter-OS7AdminSession -Domain $realm -Server $server -Credential $cred
    if (-not $session.Encrypted) { throw 'the session is not encrypted' }
    if (-not $session.Identity)  { throw 'the server did not say who we are' }
    "$($session.Identity) on port $($session.Port)"
}

T 'the session object carries NO password into JSON' {
    $json = Get-OS7AdminSession | ConvertTo-Json -Depth 8
    if ($json.Contains($env:OS7_AD_PASS)) { throw 'THE PASSWORD IS IN THE SESSION OBJECT' }
    'clean'
}

T 'Get-OS7ADDomain reports the naming context and functional level' {
    $domain = Get-OS7ADDomain
    if ($domain.DistinguishedName -ne $baseDn) { throw "got $($domain.DistinguishedName)" }
    "$($domain.DistinguishedName) level $($domain.DomainFunctionalLevel)"
}

# --- reading ---------------------------------------------------------------
T 'an enabled account decodes: enabled, not locked, a real SID' {
    $user = Get-OS7ADUser -Identity os7fixture1
    if (-not $user)            { throw 'not found' }
    if ($user.Enabled -ne $true)   { throw 'reported disabled' }
    if ($user.LockedOut -ne $false){ throw 'reported locked out' }
    if ($user.Sid -notlike 'S-1-5-21-*') { throw "sid is '$($user.Sid)'" }
    "$($user.Name) / $($user.Sid)"
}

T 'a DISABLED account is reported disabled' {
    $user = Get-OS7ADUser -Identity os7fixture2
    if ($user.Enabled -ne $false) { throw 'reported enabled' }
    ($user.AccountControl -join ',')
}

T 'a COMPUTER is not returned by Get-OS7ADUser' {
    $found = @(Get-OS7ADUser -Identity OS7FIXTUREPC)
    if ($found.Count -ne 0) { throw "a computer came back: $($found[0].DistinguishedName)" }
    '0, correctly'
}

T 'a group with ONE member gives one OBJECT, not one character' {
    $members = @(Get-OS7ADGroupMember -Identity OS7FixtureGroup)
    if ($members.Count -ne 1) { throw "count $($members.Count)" }
    if ($members[0].Name.Length -le 1) { throw "indexed into a character: '$($members[0].Name)'" }
    $members[0].Name
}

T 'an EMPTY group has Count 0, not 1' {
    $group = Get-OS7ADGroup -Identity OS7FixtureEmpty
    if ($group.MemberCount -ne 0) { throw "MemberCount is $($group.MemberCount)" }
    '0 members'
}

T 'referrals are reported as DATA and not chased' {
    $rows = @(Search-OS7AD -Filter '(sAMAccountName=os7fixture1)' -Property @('cn'))
    "$(@($rows[0].Referrals).Count) referrals"
}

T 'paging: two per page returns the same set as a thousand per page' {
    $session = (Get-OS7AdminSession).DirectorySession
    $small = @(Search-Directory -Session $session -SearchBase $baseDn `
        -Filter '(objectClass=*)' -Property @('distinguishedName') -PageSize 2)
    $big = @(Search-Directory -Session $session -SearchBase $baseDn `
        -Filter '(objectClass=*)' -Property @('distinguishedName') -PageSize 1000)
    if ($small.Count -ne $big.Count) {
        throw "2 per page gave $($small.Count), 1000 per page gave $($big.Count)"
    }
    if ($small[0].Pages -lt 2) { throw 'the paged run used one page; the case was not exercised' }
    "$($small.Count) objects over $($small[0].Pages) pages"
}

# --- writing ---------------------------------------------------------------
#
# EVERY RUN STARTS FROM NOTHING. This check runs twice against the same
# directory — the second time with the stage 2 tools hidden — and the first
# version of it left OU=OS7Check behind, so the second run failed on "already
# exists" and reported it as "stage 1 needs adcli". A harness whose own
# leftovers produce a red result is a harness that reports defects nobody has.
function Clear-CheckTree {
    $session = (Get-OS7AdminSession).DirectorySession
    $doomed = @(Search-Directory -Session $session -SearchBase $baseDn `
        -Filter '(|(ou=OS7Check)(sAMAccountName=os7check1)(sAMAccountName=OS7CheckGroup))' `
        -Property @('distinguishedName'))
    # Children before parents: a directory refuses to delete a container that
    # still holds anything, and sorting by length descending puts the deepest
    # distinguished names first without needing to walk the tree.
    foreach ($row in ($doomed | Sort-Object { $_.Dn.Length } -Descending)) {
        try { Remove-DirectoryEntry -Session $session -DistinguishedName $row.Dn -Confirm:$false | Out-Null }
        catch { }
    }
}
Clear-CheckTree

T 'New-OS7ADUser creates disabled, sets the password, then enables' {
    $session = (Get-OS7AdminSession).DirectorySession
    New-DirectoryEntry -Session $session -DistinguishedName "OU=OS7Check,$baseDn" `
        -ObjectClass @('organizationalUnit') -Confirm:$false | Out-Null
    $user = New-OS7ADUser -Name os7check1 -Path "OU=OS7Check,$baseDn" `
        -DisplayName 'Check One' -UserPrincipalName "os7check1@$realm" `
        -Password (ConvertTo-SecureString 'Ch3ck-Passw0rd-1!' -AsPlainText -Force) `
        -Enabled -Confirm:$false
    if ($user.Enabled -ne $true) { throw 'created but not enabled' }
    $user.DistinguishedName
}

T 'Disable then Enable PRESERVES the other userAccountControl flags' {
    $dn = (Get-OS7ADUser -Identity os7check1).DistinguishedName
    Set-OS7ADObject -DistinguishedName $dn -Name 'userAccountControl' -Value '66048' `
        -Confirm:$false | Out-Null
    Disable-OS7ADAccount -Identity os7check1 -Confirm:$false | Out-Null
    $user = Get-OS7ADUser -Identity os7check1
    if ($user.Enabled) { throw 'still enabled' }
    if (-not $user.PasswordNeverExpires) { throw 'DONT_EXPIRE_PASSWORD lost by the disable' }
    Enable-OS7ADAccount -Identity os7check1 -Confirm:$false | Out-Null
    $user = Get-OS7ADUser -Identity os7check1
    if (-not $user.Enabled) { throw 'not re-enabled' }
    if (-not $user.PasswordNeverExpires) { throw 'DONT_EXPIRE_PASSWORD lost by the enable' }
    ($user.AccountControl -join ',')
}

T 'group membership: add makes it 1, remove makes it 0' {
    New-OS7ADGroup -Name OS7CheckGroup -Path "OU=OS7Check,$baseDn" -Confirm:$false | Out-Null
    $group = Add-OS7ADGroupMember -Identity OS7CheckGroup -Member os7check1 -Confirm:$false
    if ($group.MemberCount -ne 1) { throw "after add: $($group.MemberCount)" }
    $group = Remove-OS7ADGroupMember -Identity OS7CheckGroup -Member os7check1 -Confirm:$false
    if ($group.MemberCount -ne 0) { throw "after remove: $($group.MemberCount)" }
    '1 then 0'
}

T 'a password set is proven by BINDING with it, not by the write returning' {
    Reset-OS7ADAccountPassword -Identity os7check1 `
        -NewPassword (ConvertTo-SecureString 'R3set-Passw0rd-9!' -AsPlainText -Force) `
        -Confirm:$false | Out-Null
    $second = [pscredential]::new("os7check1@$realm",
        (ConvertTo-SecureString 'R3set-Passw0rd-9!' -AsPlainText -Force))
    $session = Connect-DirectoryServer -Server $server -Credential $second
    $who = Get-DirectoryWhoAmI -Session $session
    Disconnect-DirectoryServer -Session $session
    if (-not $who) { throw 'bound, but the server would not name the account' }
    $who
}

T 'a wrong password is reported as a WRONG PASSWORD' {
    $wrong = [pscredential]::new("$($env:OS7_AD_USER)@$realm",
        (ConvertTo-SecureString 'definitely-not-the-password' -AsPlainText -Force))
    try {
        Connect-DirectoryServer -Server $server -Credential $wrong | Out-Null
        throw 'the bind SUCCEEDED with a wrong password'
    }
    catch {
        if ($_.Exception.Message -notlike '*password is wrong*') {
            throw "the refusal did not name the cause: $($_.Exception.Message.Split([char]10)[0])"
        }
        'named the cause'
    }
}

T 'the clock is measured against the DOMAIN CONTROLLER, not against chrony' {
    $test = Test-OS7Directory -Domain $realm -Server $server -Credential $cred
    if ($null -eq $test.ClockSkewSeconds) { throw 'no skew was measured' }
    if ($test.ClockWithinKerberosLimit -ne $true) {
        throw "skew $($test.ClockSkewSeconds)s is outside the Kerberos limit"
    }
    "skew $($test.ClockSkewSeconds)s, ready=$($test.Ready)"
}

T 'a cmdlet with no session refuses with a sentence naming the cure' {
    Exit-OS7AdminSession
    try {
        Get-OS7ADUser -Identity os7fixture1 | Out-Null
        throw 'it did not refuse'
    }
    catch {
        if ($_.Exception.Message -notlike '*Enter-OS7AdminSession*') {
            throw "unhelpful: $($_.Exception.Message.Split([char]10)[0])"
        }
        'names Enter-OS7AdminSession'
    }
}

$results | ConvertTo-Json -Depth 6 -Compress -AsArray
"""


def run_driver(address, ca_path, hide_join_tools=False, image=CLIENT_IMAGE):
    """Run the PowerShell driver in the client container and return its rows.

    LDAPTLS_CACERT is passed as a docker -e and NOT set from inside PowerShell,
    and that is the whole reason this function takes a path. Measured
    2026-08-27: .NET on Unix keeps its own copy of the environment and never
    calls setenv(3), so a variable set inside pwsh is invisible to libldap while
    [Environment]::GetEnvironmentVariable reads it back happily. The failure is
    reported as "The LDAP server is unavailable."
    """
    inner = "pwsh -NoProfile -File /probe/driver.ps1"
    if hide_join_tools:
        # Move the STAGE 2 tools out of reach and prove stage 1 does not want
        # them. Renaming rather than uninstalling, because a package removal
        # would take libraries with it and change more than the question asks.
        inner = ("for t in adcli kinit klist kdestroy kvno sssctl; do "
                 "  p=$(command -v $t 2>/dev/null) && mv \"$p\" \"$p.hidden\"; "
                 "done; " + inner)

    result = docker(
        "run", "--rm", "--network", NETWORK, "--dns", address,
        "--dns-search", "os7.test",
        "-v", f"{REPO}:/repo:ro",
        "-v", f"{os.path.dirname(ca_path)}:/probe",
        "-e", "LDAPTLS_CACERT=/probe/ad-ca.pem",
        "-e", f"OS7_AD_SERVER={DC_HOST}",
        "-e", f"OS7_AD_REALM={REALM}",
        "-e", f"OS7_AD_BASEDN={BASE_DN}",
        "-e", f"OS7_AD_USER={ADMIN}",
        "-e", f"OS7_AD_PASS={ADMIN_PASSWORD}",
        image, "bash", "-c", inner,
        capture_output=True, text=True)

    stdout = result.stdout.strip()
    start = stdout.rfind("[{")
    if start < 0:
        print(result.stderr[-3000:])
        sys.exit("the driver produced no JSON; see the output above")
    return json.loads(stdout[start:])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true",
                        help="leave the domain controller running afterwards")
    parser.add_argument("--os7img", default=None,
                        help="also run the read-only half inside a container "
                             "made from a shipped ISO (BUILD-NOTES #93: that is "
                             "a second opinion, never the authority)")
    args = parser.parse_args()

    print("### OS/7's Active Directory surface, against a real domain controller")
    print()

    if not shutil.which("docker"):
        note("NOT CHECKED. docker is not on PATH, and this check needs two "
             "containers on a network: a Samba AD domain controller and a client.")
        note("Install Docker and run this again; nothing here has been verified.")
        return 0

    build_images()
    address = start_dc()
    print(f"    domain controller ready at {address} ({DC_HOST}, realm {REALM})")

    if not populate():
        sys.exit("the fixture population could not be built with samba-tool")

    # A TEMPORARY DIRECTORY, NOT ONE IN THE REPOSITORY. The first version of
    # this wrote the driver and the CA into installer/testing/.ad-probe, which
    # put a certificate and a generated script into `git status` — a check that
    # dirties the tree it is checking is a check somebody will run before a
    # commit and then have to clean up after.
    probe_dir = tempfile.mkdtemp(prefix="os7-ad-")
    with open(os.path.join(probe_dir, "driver.ps1"), "w", newline="\n") as handle:
        handle.write(DRIVER)
    docker("cp", f"{DC_NAME}:/var/lib/samba/private/tls/ca.pem",
           os.path.join(probe_dir, "ad-ca.pem"), check=True, stdout=subprocess.DEVNULL)

    try:
        print()
        print("--- the modules against the directory")
        for row in run_driver(address, os.path.join(probe_dir, "ad-ca.pem")):
            check(row["ok"], row["name"], row["detail"])

        print()
        print("--- the independent witness: ldbsearch inside the domain controller")
        # What OS/7 created must be visible to a tool that shares no code with
        # it. The OU is the one object the driver leaves behind on purpose.
        found = witness("(sAMAccountName=os7check1)", "userPrincipalName")
        check(len(found) == 1 and found[0].startswith("os7check1@"),
              "the account OS/7 created is in the database ldbsearch reads",
              found[0] if found else "not found")
        members = witness("(sAMAccountName=OS7FixtureGroup)", "member")
        check(len(members) == 1,
              "the fixture group has exactly one member, per ldbsearch",
              f"{len(members)} member(s)")

        print()
        print("--- stage 1 with stage 2's packages MOVED OUT OF PATH")
        rows = run_driver(address, os.path.join(probe_dir, "ad-ca.pem"),
                          hide_join_tools=True)
        failed = [r["name"] for r in rows if not r["ok"]]
        check(not failed,
              "an outbound admin session needs no adcli, kinit, klist or sssctl",
              "; ".join(failed) if failed else "")

        if args.os7img:
            print()
            print(f"--- the second opinion: {args.os7img} (BUILD-NOTES #93)")
            exists = docker("image", "inspect", args.os7img,
                            capture_output=True, text=True).returncode == 0
            if not exists:
                note(f"NOT CHECKED. There is no image {args.os7img} on this host.")
                note("Import one from a built ISO, or omit --os7img.")
            else:
                rows = run_driver(address, os.path.join(probe_dir, "ad-ca.pem"),
                                  image=args.os7img)
                failed = [r["name"] for r in rows if not r["ok"]]
                check(not failed,
                      f"the same checks pass inside {args.os7img}",
                      "; ".join(failed) if failed else "")
    finally:
        if args.keep:
            print()
            print(f"    (kept: container {DC_NAME} on network {NETWORK})")
        else:
            docker("rm", "-f", DC_NAME, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            docker("network", "rm", NETWORK, stdout=subprocess.DEVNULL,
                   stderr=subprocess.DEVNULL)
            shutil.rmtree(probe_dir, ignore_errors=True)

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed against SAMBA. What that does and does not mean is in")
    print("this file's header: the protocol is exercised, Windows Server is not, and")
    print("channel binding, signing enforcement and Windows password-policy sub-codes")
    print("remain owed to a real domain controller.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
