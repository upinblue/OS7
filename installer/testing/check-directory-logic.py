#!/usr/bin/env python3
"""
The AD surface's DECISIONS, in seconds, with no domain controller and no VM.

    ./check-directory-logic.py

WHAT THIS IS AND IS NOT. It runs the real `powershell/Directory` and
`powershell/OS7` modules with the LDAP connection replaced by a fake, and
checks what the cmdlets DECIDE: which filter they build, which modification
operation they send, whether they read a value before changing one bit of it,
what bytes a password becomes, and what they refuse. It never opens a socket.
`check-ad.py` is the test against a directory that answers, and nothing here
replaces it — this catches the class of defect that a lab domain hides, and
that one catches the class a fake hides.

WHY THE SEAM IS WHERE IT IS. The other four generic modules replace a COMMAND
RUNNER, which puts invocation, exit codes and parsing all under test. LDAP
cannot be faked that deep: `SearchResultEntry`, `SearchResultEntryCollection`
and `SearchResponse` have zero public constructors (measured 2026-08-27), so a
fake would have to reflect into private ones — a test that breaks on a .NET
servicing update and reports it as a client defect. So `Directory.psm1` is
shaped with the un-fakeable region reduced to two short functions that decide
nothing, and this replaces those two.

THE FAKE'S TWO LOAD-BEARING BEHAVIOURS.

  1. IT HONOURS THE REQUEST. It answers from a table keyed by what was asked,
     and throws on a request nobody modelled. A fake that returns the same
     object for every question staples one account's state onto another's, and
     a fake that silently succeeds at an unmodelled call is how a mock reports
     that untested code works.

  2. IT RECORDS WHAT IT WAS SENT, in a [List[object]] and never a counter.
     BUILD-NOTES #76: a counter captured by value increments a copy, every call
     sees 1, and the fake reports a defect the cmdlet does not have.

AND IT USES NO .GetNewClosure(), WHICH IS THE OPPOSITE OF WHAT THE OTHER CHECKS
DO. Measured on 2026-08-27, because the first version of this file followed
their example and eleven cases failed identically with "You cannot call a method
on a null-valued expression":

    with    .GetNewClosure()  ->  the fake's $script:__sent is $null
    without .GetNewClosure()  ->  the fake records, and the module sees it

The two seams are not the same mechanism. check-network-logic.py's fake replaces
a COMMAND RUNNER and must carry LOCAL values from the defining scope into the
block, which is exactly what GetNewClosure is for. This fake must instead reach
MODULE state — the recorded requests live in the Directory module's own session
state, because that is the only scope both the fake and the module can see — and
GetNewClosure rebinds the block to a fresh closure scope where `$script:` no
longer resolves there. Right in one place, wrong in the other, and only running
it says which.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DIRECTORY_MODULE = os.path.join(REPO, "powershell", "Directory", "Directory.psd1")
OS7_MODULE = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)


# ---------------------------------------------------------------------------
# The driver.
#
# Every literal PowerShell brace is doubled because this is a Python format
# template. The last statement is one JSON object and nothing else, which holds
# because Write-OS7Step writes to stderr — BUILD-NOTES #60: Write-Verbose and
# Write-Warning do NOT, on pwsh 7.6.5, which is why neither appears in these
# modules at all.
# ---------------------------------------------------------------------------
DRIVER = r"""
$ErrorActionPreference = 'Stop'
Import-Module '{directory}' -Force
Import-Module '{os7}' -Force

$results = [System.Collections.Generic.List[object]]::new()
function T {{
    param([string]$Name, [scriptblock]$Body)
    try {{
        $detail = & $Body
        $results.Add([pscustomobject]@{{ name = $Name; ok = $true; detail = "$detail" }})
    }}
    catch {{
        $results.Add([pscustomobject]@{{
            name = $Name; ok = $false
            detail = $_.Exception.Message.Split([char]10)[0]
        }})
    }}
}}

# --- install the fake, INSIDE the module's own scope -----------------------
#
# The seam variables are module-scoped and not exported, so the only way to
# reach them is to run a scriptblock in the module's session state. This is the
# same move check-network-logic.py and check-service-logic.py make.
& (Get-Module Directory) {{
    $script:__sent = [System.Collections.Generic.List[object]]::new()
    $script:__page = 0

    $script:DirectoryConnectionFactory = {{
        param($server, $port, $tls, $cred, $auth)
        # A fake CONNECTION, not a fake protocol: it carries the properties the
        # module reads back, so the ProtocolVersion assertion still means
        # something.
        [pscustomobject]@{{
            Server = $server; Port = $port; Tls = [bool]$tls; AuthType = $auth
            SessionOptions = [pscustomobject]@{{ ProtocolVersion = 3 }}
        }}
    }}

    $script:DirectoryRequestOverride = {{
        param($conn, $req)
        $script:__sent.Add($req)

        $type = $req.GetType().Name
        if ($type -eq 'SearchRequest') {{
            $filter = $req.Filter
            $rows = [System.Collections.Generic.List[object]]::new()
            $cookie = $null

            # THE DN FORM IS HERE BECAUSE THE CMDLETS READ BACK WHAT THEY WROTE.
            # Set-/Disable-/Reset- all finish with Get-OS7ADUser against the
            # distinguished name, not the account name, and the first version of
            # this fake modelled only the name — so the fake threw, which is the
            # behaviour it is supposed to have, and the check told me what was
            # missing instead of quietly passing.
            if ($filter -like '*os7fixture1*' -or $filter -like '*Ada Lovelace*' -or
                $req.DistinguishedName -like '*Ada*') {{
                $rows.Add([pscustomobject]@{{
                    Dn = 'CN=Ada Lovelace,CN=Users,DC=os7,DC=test'
                    Attributes = [ordered]@{{
                        'sAMAccountName'     = @('os7fixture1')
                        'displayName'        = @('Ada Lovelace')
                        'userAccountControl' = @('66048')
                        'memberOf'           = @('CN=OS7FixtureGroup,CN=Users,DC=os7,DC=test')
                        'distinguishedName'  = @('CN=Ada Lovelace,CN=Users,DC=os7,DC=test')
                    }}
                }})
            }}
            elseif ($filter -like '*OS7FixtureGroup*') {{
                $rows.Add([pscustomobject]@{{
                    Dn = 'CN=OS7FixtureGroup,CN=Users,DC=os7,DC=test'
                    Attributes = [ordered]@{{
                        'sAMAccountName' = @('OS7FixtureGroup')
                        'member'         = @('CN=Ada Lovelace,CN=Users,DC=os7,DC=test')
                        'groupType'      = @('-2147483646')
                    }}
                }})
            }}
            elseif ($filter -like '*PAGEME*') {{
                # TWO PAGES AND A COOKIE. A one-page fake makes the paging code
                # look correct while the loop that unions the pages has never
                # run — BUILD-NOTES #89's shape.
                $script:__page++
                if ($script:__page -eq 1) {{
                    $rows.Add([pscustomobject]@{{ Dn = 'CN=one,DC=x'; Attributes = [ordered]@{{}} }})
                    $cookie = [byte[]]@(1, 2, 3)
                }}
                else {{
                    $rows.Add([pscustomobject]@{{ Dn = 'CN=two,DC=x'; Attributes = [ordered]@{{}} }})
                    $cookie = [byte[]]@()
                }}
            }}
            elseif ($filter -like '*NOTHINGMATCHES*') {{ }}
            else {{
                throw "the fake was asked something nobody modelled: $filter"
            }}

            return [pscustomobject]@{{
                Rows = $rows
                Referrals = @('ldaps://os7.test/CN=Configuration,DC=os7,DC=test')
                Cookie = $cookie
            }}
        }}

        # Add / Modify / Delete / ModifyDN: recorded, and answered with nothing.
        return [pscustomobject]@{{ Rows = @(); Referrals = @(); Cookie = $null }}
    }}
}}

function Get-Sent {{ (Get-Module Directory).Invoke({{ $script:__sent }}) }}
function Clear-Sent {{ (Get-Module Directory).Invoke({{ $script:__sent.Clear(); $script:__page = 0 }}) }}

$session = Connect-DirectoryServer -Server 'dc01.os7.test' `
    -Credential ([pscredential]::new('a@b', (ConvertTo-SecureString 'hunter2hunter2' -AsPlainText -Force)))

$adminSession = [pscustomobject]@{{
    PSTypeName = 'OS7.AD.Session'
    Domain = 'os7.test'; Server = 'dc01.os7.test'; Port = 636; Encrypted = $true
    Authentication = 'Basic'; Identity = 'u:OS7\Administrator'
    DefaultNamingContext = 'DC=os7,DC=test'
    DirectorySession = $session
}}

# --- the protocol layer's decisions ----------------------------------------

T 'the connection reads its protocol version BACK after setting it' {{
    if ($session.Connection.SessionOptions.ProtocolVersion -ne 3) {{ throw 'not 3' }}
    'LDAPv3'
}}

T 'a search follows the cookie and returns the UNION of the pages' {{
    Clear-Sent
    $rows = @(Search-Directory -Session $session -SearchBase 'DC=x' -Filter '(cn=PAGEME)')
    if ($rows.Count -ne 2) {{ throw "got $($rows.Count) rows, so only one page was read" }}
    $sent = @(Get-Sent)
    if ($sent.Count -ne 2) {{ throw "sent $($sent.Count) requests" }}
    'two pages, two requests, two rows'
}}

T 'the SECOND request carries the cookie the first one came back with' {{
    Clear-Sent
    $null = Search-Directory -Session $session -SearchBase 'DC=x' -Filter '(cn=PAGEME)'
    $second = @(Get-Sent)[1]
    $control = $second.Controls | Where-Object {{
        $_ -is [System.DirectoryServices.Protocols.PageResultRequestControl]
    }}
    if (-not $control) {{ throw 'the second request had no paging control' }}
    if ($control.Cookie.Length -eq 0) {{ throw 'the cookie was not carried' }}
    "cookie of $($control.Cookie.Length) bytes"
}}

T 'referrals are attached to the rows rather than followed' {{
    $rows = @(Search-Directory -Session $session -SearchBase 'DC=x' -Filter '(cn=os7fixture1)')
    if (@($rows[0].Referrals).Count -ne 1) {{ throw 'referral not reported' }}
    'reported as data'
}}

T 'a search that matches nothing returns an empty ARRAY, not $null' {{
    $rows = @(Search-Directory -Session $session -SearchBase 'DC=x' -Filter '(cn=NOTHINGMATCHES)')
    if ($null -eq $rows) {{ throw 'null' }}
    if ($rows.Count -ne 0) {{ throw "count $($rows.Count)" }}
    'Count 0'
}}

# --- the OS7 layer's decisions ---------------------------------------------

T 'Get-OS7ADUser excludes COMPUTERS from a user query' {{
    Clear-Sent
    $null = Get-OS7ADUser -Identity os7fixture1 -Session $adminSession
    $filter = @(Get-Sent)[0].Filter
    if ($filter -notlike '*objectCategory=person*') {{
        throw "the filter does not exclude computers: $filter"
    }}
    $filter
}}

T 'an identity containing an ASTERISK is escaped, not treated as a wildcard' {{
    Clear-Sent
    try {{ $null = Get-OS7ADUser -Identity 'os7fixture1*' -Session $adminSession }} catch {{ }}
    $filter = @(Get-Sent)[0].Filter
    if ($filter -notlike '*\2a*') {{ throw "unescaped: $filter" }}
    'escaped as \2a'
}}

T 'an identity with an @ is looked up as a userPrincipalName' {{
    Clear-Sent
    try {{ $null = Get-OS7ADUser -Identity 'os7fixture1@os7.test' -Session $adminSession }} catch {{ }}
    $filter = @(Get-Sent)[0].Filter
    if ($filter -notlike '*userPrincipalName=*') {{ throw $filter }}
    'userPrincipalName'
}}

T 'Add-OS7ADGroupMember sends Add and NEVER Replace' {{
    Clear-Sent
    $null = Add-OS7ADGroupMember -Identity OS7FixtureGroup -Member 'CN=Ada Lovelace,CN=Users,DC=os7,DC=test' `
        -Session $adminSession -Confirm:$false
    $modify = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'ModifyRequest' }} | Select-Object -First 1
    if (-not $modify) {{ throw 'no modification was sent' }}
    $operation = $modify.Modifications[0].Operation
    if ("$operation" -ne 'Add') {{
        throw "sent $operation, which would discard every other member"
    }}
    'Add'
}}

T 'Disable-OS7ADAccount READS the flags and changes one bit' {{
    Clear-Sent
    $null = Disable-OS7ADAccount -Identity os7fixture1 -Session $adminSession -Confirm:$false
    $modify = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'ModifyRequest' }} | Select-Object -First 1
    $written = $modify.Modifications[0][0]
    # 66048 is 512 + DONT_EXPIRE_PASSWORD. Disabling must give 66050, not 514.
    if ("$written" -eq '514') {{
        throw 'wrote 514 and discarded DONT_EXPIRE_PASSWORD'
    }}
    if ("$written" -ne '66050') {{ throw "wrote $written" }}
    "66048 -> $written, flags kept"
}}

T 'a password becomes QUOTED UTF-16LE bytes, not a string' {{
    Clear-Sent
    $null = Reset-OS7ADAccountPassword -Identity os7fixture1 `
        -NewPassword (ConvertTo-SecureString 'Passw0rd!' -AsPlainText -Force) `
        -Session $adminSession -Confirm:$false
    $modify = @(Get-Sent) | Where-Object {{
        $_.GetType().Name -eq 'ModifyRequest' -and $_.Modifications[0].Name -eq 'unicodePwd'
    }} | Select-Object -First 1
    if (-not $modify) {{ throw 'no unicodePwd modification was sent' }}
    $bytes = [byte[]]$modify.Modifications[0][0]
    $decoded = [System.Text.Encoding]::Unicode.GetString($bytes)
    if ($decoded -ne '"Passw0rd!"') {{ throw "the bytes decode to $decoded" }}
    if ($bytes[0] -ne 34 -or $bytes[1] -ne 0) {{ throw 'not UTF-16LE' }}
    'UTF-16LE, quoted, no BOM'
}}

T '-WhatIf sends NOTHING at all' {{
    Clear-Sent
    $null = Remove-OS7ADObject -DistinguishedName 'CN=Ada Lovelace,CN=Users,DC=os7,DC=test' `
        -Session $adminSession -WhatIf
    $deletes = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'DeleteRequest' }}
    if (@($deletes).Count -ne 0) {{ throw 'a delete was sent under -WhatIf' }}
    'nothing sent'
}}

T 'a computer identity is looked up with the dollar nobody types' {{
    Clear-Sent
    try {{ $null = Get-OS7ADComputer -Identity OS7FIXTUREPC -Session $adminSession }} catch {{ }}
    $filter = @(Get-Sent)[0].Filter
    if ($filter -notlike '*OS7FIXTUREPC$*') {{ throw $filter }}
    'sAMAccountName with $'
}}

T 'with no session at all, the refusal names the cmdlet that fixes it' {{
    try {{
        Get-OS7ADUser -Identity os7fixture1 | Out-Null
        throw 'it did not refuse'
    }}
    catch {{
        if ($_.Exception.Message -notlike '*Enter-OS7AdminSession*') {{
            throw "unhelpful: $($_.Exception.Message.Split([char]10)[0])"
        }}
        'names Enter-OS7AdminSession'
    }}
}}

T 'the session object never carries the password into JSON' {{
    $json = $adminSession | ConvertTo-Json -Depth 8
    if ($json.Contains('hunter2hunter2')) {{ throw 'THE PASSWORD IS IN THE SESSION OBJECT' }}
    'clean'
}}

$results | ConvertTo-Json -Depth 6 -Compress -AsArray
"""


def main():
    print("### the AD surface's decisions, against a fake connection")
    print()

    if not shutil.which("pwsh"):
        print("      note  NOT CHECKED. pwsh is not on PATH, and this runs the real modules.")
        return 0

    script = DRIVER.format(
        directory=DIRECTORY_MODULE.replace("\\", "/").replace("'", "''"),
        os7=OS7_MODULE.replace("\\", "/").replace("'", "''"))

    result = subprocess.run(["pwsh", "-NoProfile", "-Command", script],
                            capture_output=True, text=True)
    stdout = result.stdout.strip()
    start = stdout.rfind("[{")
    if start < 0:
        print(result.stderr[-3000:])
        print(stdout[-2000:])
        return 1

    print("--- the fake connection, and what the cmdlets decided")
    for row in json.loads(stdout[start:]):
        check(row["ok"], row["name"], row["detail"])

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed — the DECISIONS are right. A directory that answers is")
    print("still the only thing that can say the protocol works: check-ad.py.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
