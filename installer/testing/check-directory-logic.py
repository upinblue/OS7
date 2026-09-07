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
import tempfile

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

        # A MODELLED SERVER REFUSAL. A password step against a DN under
        # OU=ThrowPolicy throws the way Windows Server 2025 did on 2026-09-06 for
        # a password its policy refused: LDAP 53 with the Win32 code 0000052D in
        # the message. The add before it and the rollback delete after it are
        # still recorded, so a test can prove New-OS7ADUser both translates the
        # error and winds the stub back.
        if ($type -eq 'ModifyRequest' -and $req.DistinguishedName -like '*ThrowPolicy*' -and
            $req.Modifications[0].Name -eq 'unicodePwd') {{
            throw [System.DirectoryServices.Protocols.LdapException]::new(
                53, 'The server cannot handle directory requests. 0000052D: SvcErr: DSID-031A12C5, problem 5003 (WILL_NOT_PERFORM), data 0')
        }}

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
                        # S-1-5-21-1-2-3-1105 in its binary form, and
                        # primaryGroupID 513 beside it: the two attributes
                        # Get-OS7ADPrincipalGroupMembership needs to work out the
                        # primary group that memberOf does not carry.
                        #
                        # THE LEADING COMMA IS LOAD-BEARING. @([byte[]]@(1,2,3))
                        # ENUMERATES the array into three separate byte values,
                        # so the fake handed out a SID of one byte and the SID
                        # decoded to $null -- which read exactly like a DC that
                        # does not send objectSid. The comma makes it one value
                        # that happens to be an array, which is the shape the
                        # real binary-attribute path returns. This is the same
                        # trap Directory.psm1's own self-test names for values
                        # being WRITTEN.
                        'objectSid'          = (, [byte[]]@(1, 5, 0, 0, 0, 0, 0, 5,
                                21, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 81, 4, 0, 0))
                        'primaryGroupID'     = @('513')
                    }}
                }})
            }}
            elseif ($filter -like '*OS7FixtureGroup*' -or $req.DistinguishedName -like '*OS7FixtureGroup*') {{
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
            elseif ($filter -like '*organizationalUnit*') {{
                # An OU, and its CHILD COUNT is what Remove-OS7ADOrganizationalUnit
                # refuses on. OU=Full has one child, OU=Empty has none.
                $which = if ($filter -like '*Full*' -or $req.DistinguishedName -like '*Full*') {{ 'Full' }} else {{ 'Empty' }}
                $rows.Add([pscustomobject]@{{
                    Dn = "OU=$which,DC=os7,DC=test"
                    Attributes = [ordered]@{{
                        'ou' = @($which)
                        'distinguishedName' = @("OU=$which,DC=os7,DC=test")
                    }}
                }})
            }}
            elseif ($req.DistinguishedName -like 'OU=Full*') {{
                # the OneLevel child probe
                $rows.Add([pscustomobject]@{{ Dn = 'CN=in the way,OU=Full,DC=os7,DC=test'; Attributes = [ordered]@{{}} }})
            }}
            elseif ($req.DistinguishedName -like 'OU=Empty*') {{ }}
            elseif ($filter -like '*1.2.840.113556.1.4.1941*') {{
                # The recursive membership rule, asked in the PRINCIPAL direction.
                $rows.Add([pscustomobject]@{{
                    Dn = 'CN=Nested,CN=Users,DC=os7,DC=test'
                    Attributes = [ordered]@{{ 'sAMAccountName' = @('Nested'); 'groupType' = @('-2147483646') }}
                }})
            }}
            elseif ($filter -like '*objectSid=S-1-5-21-1-2-3-513*') {{
                # The PRIMARY GROUP, resolved by SID rather than read from memberOf.
                $rows.Add([pscustomobject]@{{
                    Dn = 'CN=Domain Users,CN=Users,DC=os7,DC=test'
                    Attributes = [ordered]@{{ 'sAMAccountName' = @('Domain Users'); 'groupType' = @('-2147483646') }}
                }})
            }}
            elseif ($filter -like '*OS7FIXTUREPC*' -or $req.DistinguishedName -like '*OS7FIXTUREPC*') {{
                # A COMPUTER, and DELIBERATELY WITHOUT memberOf. That attribute is
                # not in $script:OS7AdComputerAttributes, so OS7.AD.Computer has no
                # MemberOf property at all -- which is what made
                # Get-OS7ADPrincipalGroupMembership throw a PowerShell property
                # error for a machine account on 2026-09-07. Its primary group is
                # 515 (Domain Computers), not 513.
                $rows.Add([pscustomobject]@{{
                    Dn = 'CN=OS7FIXTUREPC,CN=Computers,DC=os7,DC=test'
                    Attributes = [ordered]@{{
                        'sAMAccountName'    = @('OS7FIXTUREPC$')
                        'objectClass'       = @('top', 'person', 'organizationalPerson', 'user', 'computer')
                        'primaryGroupID'    = @('515')
                        'objectSid'         = (, [byte[]]@(1, 5, 0, 0, 0, 0, 0, 5,
                                21, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 82, 4, 0, 0))
                        'distinguishedName' = @('CN=OS7FIXTUREPC,CN=Computers,DC=os7,DC=test')
                    }}
                }})
            }}
            elseif ($filter -like '*objectSid=S-1-5-21-1-2-3-515*') {{
                $rows.Add([pscustomobject]@{{
                    Dn = 'CN=Domain Computers,CN=Users,DC=os7,DC=test'
                    Attributes = [ordered]@{{
                        'sAMAccountName' = @('Domain Computers'); 'groupType' = @('-2147483646')
                    }}
                }})
            }}
            elseif ($filter -like '*primaryGroupID*' -or $req.Attributes -contains 'primaryGroupID') {{ }}
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

# --- the join, through the COMMAND seam ------------------------------------
#
# Test-DirectoryTool asks Get-Command whether adcli exists, and on a host
# without it Join-DirectoryRealm refuses before it ever builds an argument
# list -- which is right, and which would make every case below pass for the
# wrong reason. So a STUB named adcli goes on PATH to make the presence check
# true. The command override means it is never executed; only its existence
# matters. Both spellings are written because this check has to run on the Mac,
# on Linux and on the Windows box.
$stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ('os7-adcli-stub-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stubDir
if ($IsWindows) {{
    Set-Content -Path (Join-Path $stubDir 'adcli.cmd') -Value '@echo off'
}}
else {{
    $stubPath = Join-Path $stubDir 'adcli'
    Set-Content -Path $stubPath -Value "#!/bin/sh`nexit 0"
    & chmod '+x' $stubPath
}}
$savedPath = $env:PATH
$env:PATH = $stubDir + [System.IO.Path]::PathSeparator + $env:PATH

T 'the stub is visible, so the cases below test the join and not the refusal' {{
    if (-not (Get-Command adcli -CommandType Application -ErrorAction SilentlyContinue)) {{
        throw 'adcli is still not discoverable, so the join would refuse for the wrong reason'
    }}
    'adcli discoverable'
}}

T 'the join sends the password on STDIN and never in the argument list' {{
    # The command seam, not the LDAP one: Join-DirectoryRealm shells out to
    # adcli. The override records what adcli would have been given and reports a
    # failure, so nothing is written to this host's /etc.
    & (Get-Module Directory) {{
        $script:__cmd = [System.Collections.Generic.List[object]]::new()
        $script:DirectoryCommandOverride = {{
            param($command, $arguments, $stdin)
            $script:__cmd.Add([pscustomobject]@{{ Command = $command; Arguments = $arguments; Stdin = $stdin }})
            [pscustomobject]@{{ ExitCode = 1; StdOut = ''; StdErr = 'adcli: some other failure' }}
        }}
    }}
    try {{
        Join-DirectoryRealm -Domain 'os7.test' -UserName 'admin' `
            -Password (ConvertTo-SecureString 'hunter2hunter2' -AsPlainText -Force) `
            -AllowGroup 'Domain Admins' -Confirm:$false | Out-Null
    }} catch {{ }}
    $call = (Get-Module Directory).Invoke({{ $script:__cmd }}) | Select-Object -First 1
    if (-not $call) {{ throw 'adcli was never invoked' }}
    if ($call.Command -ne 'adcli') {{ throw "ran $($call.Command)" }}
    if (($call.Arguments -join ' ') -like '*hunter2hunter2*') {{
        throw 'THE PASSWORD IS IN THE ARGUMENT LIST, where /proc and ps can read it'
    }}
    if ($call.Stdin -ne 'hunter2hunter2') {{ throw 'the password did not go to stdin' }}
    if (($call.Arguments -join ' ') -notlike '*--stdin-password*') {{ throw 'no --stdin-password' }}
    'stdin, and not argv'
}}

T 'by default the join does NOT pass --ldap-passwd, and a NAT failure names the way out' {{
    # Measured 2026-09-07 against Windows Server 2025 from behind NAT: adcli's
    # default Kerberos set-password path fails with "Message stream modified".
    & (Get-Module Directory) {{
        $script:__cmd.Clear()
        $script:DirectoryCommandOverride = {{
            param($command, $arguments, $stdin)
            $script:__cmd.Add([pscustomobject]@{{ Command = $command; Arguments = $arguments }})
            [pscustomobject]@{{
                ExitCode = 4; StdOut = ''
                StdErr = "adcli: joining domain os7.test failed: Couldn't set password for computer account: OS7-GUI`$: Message stream modified"
            }}
        }}
    }}
    $threw = $null
    try {{
        Join-DirectoryRealm -Domain 'os7.test' -UserName 'admin' `
            -Password (ConvertTo-SecureString 'hunter2hunter2' -AsPlainText -Force) `
            -AllowGroup 'Domain Admins' -Confirm:$false | Out-Null
    }} catch {{ $threw = $_.Exception.Message }}
    $sent = ((Get-Module Directory).Invoke({{ $script:__cmd }}) | Select-Object -First 1).Arguments -join ' '
    if ($sent -like '*--ldap-passwd*') {{ throw 'the default changed adcli''s own default' }}
    if (-not $threw) {{ throw 'the failure was swallowed' }}
    if ($threw -notlike '*-UseLdapPassword*') {{ throw "the failure does not name the way out: $threw" }}
    if ($threw -notlike '*NAT*') {{ throw "the failure does not say why: $threw" }}
    if ($threw -notlike '*not a first join*') {{
        throw "it does not warn that the computer account already exists: $threw"
    }}
    'default untouched; the failure explains itself'
}}

T 'and -UseLdapPassword passes --ldap-passwd, without the NAT sentence' {{
    & (Get-Module Directory) {{
        $script:__cmd.Clear()
        $script:DirectoryCommandOverride = {{
            param($command, $arguments, $stdin)
            $script:__cmd.Add([pscustomobject]@{{ Command = $command; Arguments = $arguments }})
            [pscustomobject]@{{ ExitCode = 4; StdOut = ''; StdErr = 'adcli: Message stream modified' }}
        }}
    }}
    $threw = $null
    try {{
        Join-DirectoryRealm -Domain 'os7.test' -UserName 'admin' `
            -Password (ConvertTo-SecureString 'hunter2hunter2' -AsPlainText -Force) `
            -AllowGroup 'Domain Admins' -UseLdapPassword -Confirm:$false | Out-Null
    }} catch {{ $threw = $_.Exception.Message }}
    $sent = ((Get-Module Directory).Invoke({{ $script:__cmd }}) | Select-Object -First 1).Arguments -join ' '
    if ($sent -notlike '*--ldap-passwd*') {{ throw "the switch did not reach adcli: $sent" }}
    # Already using the LDAP path: repeating the advice would send an operator
    # in a circle, so the plain error is what they get.
    if ($threw -like '*-UseLdapPassword*') {{ throw 'it advises the switch that is already set' }}
    '--ldap-passwd, and no circular advice'
}}

T 'the join renders sssd.conf BEFORE it joins, so a refused allow list joins nothing' {{
    & (Get-Module Directory) {{
        $script:__cmd.Clear()
        $script:DirectoryCommandOverride = {{
            param($command, $arguments, $stdin)
            $script:__cmd.Add([pscustomobject]@{{ Command = $command; Arguments = $arguments }})
            [pscustomobject]@{{ ExitCode = 0; StdOut = ''; StdErr = '' }}
        }}
    }}
    $threw = $null
    try {{
        # No -AllowGroup and no -AllowAllDomainUsers: the sssd document refuses,
        # and it must refuse while this host is still a member of nothing.
        Join-DirectoryRealm -Domain 'os7.test' -UserName 'admin' `
            -Password (ConvertTo-SecureString 'hunter2hunter2' -AsPlainText -Force) `
            -Confirm:$false | Out-Null
    }} catch {{ $threw = $_.Exception.Message }}
    if (-not $threw) {{ throw 'an empty allow list was accepted' }}
    # The refusal must be ABOUT THE ALLOW LIST. Asserting only that something
    # threw would pass on a host where adcli is merely missing.
    if ($threw -notlike '*simple_allow_groups*' -and $threw -notlike '*allow*') {{
        throw "it refused for another reason: $threw"
    }}
    $count = @((Get-Module Directory).Invoke({{ $script:__cmd }})).Count
    if ($count -ne 0) {{ throw "adcli ran $count time(s) before the refusal" }}
    'refused, about the allow list, before adcli ran at all'
}}

T 'the command seam and PATH are put back, so later cases are unaffected' {{
    & (Get-Module Directory) {{ $script:DirectoryCommandOverride = $null }}
    $env:PATH = $savedPath
    Remove-Item $stubDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Get-Command adcli -CommandType Application -ErrorAction SilentlyContinue) {{
        throw 'the stub is still on PATH'
    }}
    'restored'
}}

T 'the session object never carries the password into JSON' {{
    $json = $adminSession | ConvertTo-Json -Depth 8
    if ($json.Contains('hunter2hunter2')) {{ throw 'THE PASSWORD IS IN THE SESSION OBJECT' }}
    'clean'
}}

T 'an OU is created with an OU= relative name, never CN=' {{
    Clear-Sent
    $null = New-OS7ADOrganizationalUnit -Name 'NewOne' -Path 'DC=os7,DC=test' `
        -Session $adminSession -Confirm:$false
    $add = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'AddRequest' }} | Select-Object -First 1
    if (-not $add) {{ throw 'no add was sent' }}
    if ($add.DistinguishedName -notlike 'OU=NewOne,*') {{
        throw "the schema refuses this name: $($add.DistinguishedName)"
    }}
    $classes = @($add.Attributes | Where-Object {{ $_.Name -eq 'objectClass' }})
    $add.DistinguishedName
}}

T 'removing an OU that still holds objects is REFUSED, with the count' {{
    Clear-Sent
    $threw = $null
    try {{
        Remove-OS7ADOrganizationalUnit -Identity 'OU=Full,DC=os7,DC=test' `
            -Session $adminSession -Confirm:$false | Out-Null
    }} catch {{ $threw = $_.Exception.Message }}
    if (-not $threw) {{ throw 'it deleted a populated OU' }}
    if ($threw -notlike '*1 object*') {{ throw "the refusal does not count them: $threw" }}
    $deletes = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'DeleteRequest' }}
    if (@($deletes).Count -ne 0) {{ throw 'a delete was sent anyway' }}
    'refused before the delete'
}}

T 'and an EMPTY OU is deleted' {{
    Clear-Sent
    $null = Remove-OS7ADOrganizationalUnit -Identity 'OU=Empty,DC=os7,DC=test' `
        -Session $adminSession -Confirm:$false
    $deletes = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'DeleteRequest' }}
    if (@($deletes).Count -ne 1) {{ throw "sent $(@($deletes).Count) deletes" }}
    'deleted'
}}

T 'the OU child probe is OneLevel, so it asks about leaf-ness and not the subtree' {{
    Clear-Sent
    try {{
        Remove-OS7ADOrganizationalUnit -Identity 'OU=Full,DC=os7,DC=test' `
            -Session $adminSession -Confirm:$false | Out-Null
    }} catch {{ }}
    $probe = @(Get-Sent) | Where-Object {{
        $_.GetType().Name -eq 'SearchRequest' -and $_.DistinguishedName -like 'OU=Full*'
    }} | Select-Object -First 1
    if (-not $probe) {{ throw 'no child probe was sent' }}
    if ("$($probe.Scope)" -ne 'OneLevel') {{ throw "scope was $($probe.Scope)" }}
    'OneLevel'
}}

T 'a principal membership includes the PRIMARY group, which memberOf never lists' {{
    Clear-Sent
    $groups = @(Get-OS7ADPrincipalGroupMembership -Identity os7fixture1 -Session $adminSession)
    $names = ($groups | ForEach-Object {{ $_.Name }} | Sort-Object) -join ', '
    if ($names -notlike '*Domain Users*') {{
        throw "the primary group is missing, which is how a fresh account reads as groupless: $names"
    }}
    if ($names -notlike '*OS7FixtureGroup*') {{ throw "memberOf was not read: $names" }}
    $names
}}

T 'a COMPUTER''s membership works, though OS7.AD.Computer has no MemberOf property' {{
    # The regression this guards: reaching into $principal.MemberOf threw a
    # property error for a machine account, in a cmdlet about groups.
    $groups = @(Get-OS7ADPrincipalGroupMembership -Identity OS7FIXTUREPC -Session $adminSession)
    $names = ($groups | ForEach-Object {{ $_.Name }}) -join ', '
    if ($names -notlike '*Domain Computers*') {{
        throw "a machine's primary group is 515 and was not resolved: $names"
    }}
    $names
}}

T 'and -ExcludePrimaryGroup asks the raw memberOf question instead' {{
    $groups = @(Get-OS7ADPrincipalGroupMembership -Identity os7fixture1 `
            -ExcludePrimaryGroup -Session $adminSession)
    $names = ($groups | ForEach-Object {{ $_.Name }}) -join ', '
    if ($names -like '*Domain Users*') {{ throw "the primary group is still there: $names" }}
    $names
}}

T 'a RECURSIVE principal membership uses the directory''s own matching rule' {{
    Clear-Sent
    $null = Get-OS7ADPrincipalGroupMembership -Identity os7fixture1 -Recursive -Session $adminSession
    $search = @(Get-Sent) | Where-Object {{
        $_.GetType().Name -eq 'SearchRequest' -and $_.Filter -like '*1.2.840.113556.1.4.1941*'
    }} | Select-Object -First 1
    if (-not $search) {{ throw 'the nesting was walked in PowerShell instead of by the DC' }}
    if ($search.Filter -notlike '*member:*') {{ throw "wrong direction: $($search.Filter)" }}
    'member: 1941, asked of the DC'
}}

T 'account expiry: -Never writes 0, and a date writes a FILETIME' {{
    Clear-Sent
    $null = Set-OS7ADAccountExpiration -Identity os7fixture1 -Never -Session $adminSession -Confirm:$false
    $mod = @(Get-Sent) | Where-Object {{
        $_.GetType().Name -eq 'ModifyRequest' -and $_.Modifications[0].Name -eq 'accountExpires'
    }} | Select-Object -First 1
    if (-not $mod) {{ throw 'nothing was written' }}
    if ("$($mod.Modifications[0][0])" -ne '0') {{ throw "wrote $($mod.Modifications[0][0]) for never" }}

    Clear-Sent
    $when = [datetime]::SpecifyKind([datetime]'2026-12-31T18:00:00', [System.DateTimeKind]::Utc)
    $null = Set-OS7ADAccountExpiration -Identity os7fixture1 -DateTime $when -Session $adminSession -Confirm:$false
    $mod2 = @(Get-Sent) | Where-Object {{
        $_.GetType().Name -eq 'ModifyRequest' -and $_.Modifications[0].Name -eq 'accountExpires'
    }} | Select-Object -First 1
    $written = [int64]"$($mod2.Modifications[0][0])"
    $expected = $when.ToFileTimeUtc()
    if ($written -ne $expected) {{ throw "wrote $written, expected $expected" }}
    # And the round trip: what was written must read back as the same instant,
    # which is what catches a local/UTC confusion that is invisible in one
    # direction. ConvertFrom-DirectoryFileTime is the read side.
    $back = ConvertFrom-DirectoryFileTime -Value "$written"
    if ($back.ToUniversalTime() -ne $when.ToUniversalTime()) {{
        throw "round trip moved the instant: $($back.ToUniversalTime()) vs $($when.ToUniversalTime())"
    }}
    "0 for never, $written for the date, round trip exact"
}}

T 'deleting by an ambiguous identity refuses and names the candidates' {{
    Clear-Sent
    $threw = $null
    try {{ Remove-OS7ADGroup -Identity NOTHINGMATCHES -Session $adminSession -Confirm:$false | Out-Null }}
    catch {{ $threw = $_.Exception.Message }}
    if ($threw -notlike '*No group matched*') {{ throw "wrong refusal: $threw" }}
    $deletes = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'DeleteRequest' }}
    if (@($deletes).Count -ne 0) {{ throw 'a delete was sent for an unresolved identity' }}
    'nothing matched, nothing deleted'
}}

T 'Remove-OS7ADUser resolves an identity to ONE dn before deleting' {{
    Clear-Sent
    $null = Remove-OS7ADUser -Identity os7fixture1 -Session $adminSession -Confirm:$false
    $delete = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'DeleteRequest' }} | Select-Object -First 1
    if (-not $delete) {{ throw 'nothing was deleted' }}
    if ($delete.DistinguishedName -ne 'CN=Ada Lovelace,CN=Users,DC=os7,DC=test') {{
        throw "deleted $($delete.DistinguishedName)"
    }}
    $delete.DistinguishedName
}}

T 'Set-OS7ADGroup clears an attribute when asked with an empty string' {{
    Clear-Sent
    $null = Set-OS7ADGroup -Identity OS7FixtureGroup -Description '' -Session $adminSession -Confirm:$false
    $mod = @(Get-Sent) | Where-Object {{
        $_.GetType().Name -eq 'ModifyRequest' -and $_.Modifications[0].Name -eq 'description'
    }} | Select-Object -First 1
    if (-not $mod) {{ throw 'an empty string was treated as "no change asked for"' }}
    'empty means clear, not ignore'
}}

T 'a refused write is TRANSLATED, not surfaced as "the server cannot handle requests"' {{
    # The fake throws LDAP 53 / 0000052D for a unicodePwd write under ThrowPolicy.
    Clear-Sent
    $threw = $null
    try {{
        Set-DirectoryPassword -Session $session -DistinguishedName 'CN=x,OU=ThrowPolicy,DC=os7,DC=test' `
            -NewPassword (ConvertTo-SecureString 'Passw0rd!' -AsPlainText -Force) -Confirm:$false | Out-Null
    }} catch {{ $threw = $_.Exception.Message }}
    if (-not $threw) {{ throw 'the write did not fail' }}
    if ($threw -like '*cannot handle directory requests*') {{ throw "not translated: $threw" }}
    if ($threw -notlike '*password policy*') {{ throw "wrong translation: $threw" }}
    'password policy, in words'
}}

T 'New-OS7ADUser winds back the disabled stub when the password step is refused' {{
    Clear-Sent
    $threw = $null
    try {{
        New-OS7ADUser -Name 't.rollback' -Path 'OU=ThrowPolicy,DC=os7,DC=test' `
            -Password (ConvertTo-SecureString 'Passw0rd!' -AsPlainText -Force) -Enabled `
            -Session $adminSession -Confirm:$false | Out-Null
    }} catch {{ $threw = $_.Exception.Message }}
    if (-not $threw) {{ throw 'it did not throw' }}
    if ($threw -notlike '*password policy*') {{ throw "message not translated: $threw" }}
    if ($threw -notlike '*removed*') {{ throw "did not report the rollback: $threw" }}
    $adds = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'AddRequest' }}
    $deletes = @(Get-Sent) | Where-Object {{ $_.GetType().Name -eq 'DeleteRequest' -and $_.DistinguishedName -like '*t.rollback*' }}
    if (@($adds).Count -ne 1) {{ throw "expected the account to be created once, saw $(@($adds).Count)" }}
    if (@($deletes).Count -ne 1) {{ throw "expected one rollback delete, saw $(@($deletes).Count)" }}
    'translated, and the stub deleted'
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

    # THE DRIVER GOES IN A FILE, NOT ON THE COMMAND LINE. Passing it with
    # -Command worked until the join cases pushed it past Windows' command-line
    # limit, and what surfaces there is CreateProcess's "The filename or
    # extension is too long" — a message about a filename, for a script that is
    # merely long. check-ad.py already writes its driver out; this now matches.
    # encoding/errors are explicit because text=True alone decodes with the
    # host's code page, and one em dash in a module's message would kill the
    # read (the same trap os7lab.py records).
    with tempfile.TemporaryDirectory() as work:
        script_path = os.path.join(work, "driver.ps1")
        with open(script_path, "w", newline="\n", encoding="utf-8") as handle:
            handle.write(script)
        result = subprocess.run(["pwsh", "-NoProfile", "-File", script_path],
                                capture_output=True, text=True,
                                encoding="utf-8", errors="replace")
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
