#!/usr/bin/env python3
"""
Five PowerShell traps this repository has paid for, as a mechanism rather than a note.

    ./check-ps-traps.py            report, and fail if any of them got worse

All five are the same kind of defect: code that reads correctly, parses
correctly, and means something else. None produces a warning; each was found by
a machine doing the wrong thing.

#65 — A LOCAL NAMED AFTER A PARAMETER IS THAT PARAMETER.
PowerShell variable names are case-insensitive, so inside a function declaring
`-From`, the statement `$from = $props[...]` assigns to the PARAMETER. It is
typed [string], so a hashtable becomes "System.Collections.Hashtable" and the
next line indexes a string. The error names no variable, no parameter and no
file. Written down 2026-08-25 after it cost a VM cycle; hit twice more on
2026-08-27, once live in `Update-OS7` (`-Source` vs `$source`) four lines below
a comment citing it, and once latent in `New-OS7BackupTarget` (`-PoolName` vs
`$poolName`) where it worked only by the order a switch evaluates its branches.

#91 — `@('a', $b, $c + $d)` IS FOUR ELEMENTS, NOT THREE.
The array literal binds first and the `+` then APPENDS to it: the expression is
`('a', $b, $c) + $d`. Measured, and the AST says so exactly — a BinaryExpression
with operator Plus whose left side is an ArrayLiteral. It produced

    mount --bind /srv /run/os7-update /srv

which mount rejected, loudly, by luck. One argument earlier and it would have
produced a VALID command against the wrong path. Parenthesise the concatenation.

#82 — A CMDLET CALLED AT IMPORT SCOPE IS NOT THERE IN THE CHROOT.
A command call outside every function definition runs when the module is
IMPORTED. Hook 0060 imports the module inside the build chroot, where a cmdlet
resolved BY NAME cannot be autoloaded — only Microsoft.PowerShell.Core is
already loaded. The note was written for `Join-Path` and `Test-Path`;
on 2026-08-28 it happened again, with `Sort-Object` one statement outside a
function in OS7.DirectoryObject.ps1, and it killed a 25-minute ISO build:

    OS/7 hook 0060:   OS7: FAILED: The term 'Sort-Object' is not recognized

It had been true on main since the Active Directory commit and was invisible
because no ISO was built in between — word for word what #82 already says
about itself. This scan finds it in seconds. Which module a name belongs to is
ASKED of Get-Command rather than kept in a list here, and names the tree itself
DEFINES are collected by the parser first, so neither can go stale.

#112/#119 — A PROPERTY READ OFF A PIPELINE THAT MAY BE EMPTY.
`(… | Select-Object -Last 1).Property` is `$null.Property` when nothing
matched, and both OS7.psm1 and Zfs.psm1 set `Set-StrictMode -Version Latest`,
under which that is a TERMINATING error rather than $null. The empty case is
not exotic: it is a machine with no replication target, no snapshot yet, no
release index — a fresh install. It shipped thirteen times, made
`Get-OS7BackupStatus` throw on every new machine, and put an exception into
the administrator manual's own screenshot of that cmdlet. #112 diagnosed it
correctly on 2026-08-29, recommended a two-step fix, and nothing changed until
2026-08-30 — which is the argument for this rule rather than a fourth
paragraph. The scan added it on the day of the fix and immediately found
THREE more sites than the grep that preceded it, in three different modules.

#121 — A BARE `$LASTEXITCODE` READ IS EITHER A CRASH OR AN EARLIER COMMAND'S CODE.
The engine rewrites it only when a native command COMPLETES through the
pipeline. A command that is found but cannot be started does not throw and does
not set it (measured 2026-09-01 against an extensionless file on PATH, and
2026-08-26 against a .cmd shim): in a fresh session the next read is a
terminating StrictMode error inside the function whose job was to report the
failure, and after any earlier native call it is THAT call's exit code — 0
included, so a verification step that never ran reports success. The idiom is
reset-then-guarded-read:

    $global:LASTEXITCODE = $null
    $out = & $exe @argv 2> $errFile
    $code = if (Test-Path Variable:LASTEXITCODE) { $LASTEXITCODE } else { $null }

Writes are the reset half and are allowed; a read under the Test-Path guard is
the read half; any other read is a hit.

ALL FIVE BASELINES ARE 0 AND MAY NOT RISE. check-layering.py's reasoning applies
word for word: "a rule that is only written down erodes."

It needs `pwsh` and nothing else — no container, no ZFS, no VM. The scan is
PowerShell's own parser, because a regex over source cannot tell an assignment
from a comparison, and a check that cries wolf is a check people delete.
"""
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Measured by running this, not counted by eye. #65 was 2 and #91 was 4 before
# 2026-08-27; #121 was 8 before 2026-09-01, when all eight were fixed together
# with the scan that counts them.
BASELINE = {"SHADOW": 0, "ARRAYPLUS": 0, "IMPORTSCOPE": 0, "STRICTPROP": 0,
            "BARELEC": 0}

SCAN = r'''
$root = $env:OS7_SCAN_ROOT
$files = Get-ChildItem -LiteralPath $root -Recurse -Include *.psm1,*.ps1 |
    Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' }

# A PRE-PASS for #82: every function name the tree DEFINES. A call at import
# scope to one of these is ordinary - it is in the module being loaded, not
# looked up in the archive. Collected by the parser, so a rename cannot make
# this list stale the way a hand-written one would.
$defined = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::InvariantCultureIgnoreCase)
foreach ($file in $files) {
    $pre = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$null)
    foreach ($f in $pre.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        [void]$defined.Add($f.Name)
    }
}

foreach ($file in $files) {
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        Write-Output ("PARSE`t{0}`t{1}`t{2}" -f $file.Name, $errors.Count, $errors[0].Message)
        continue
    }

    # ---- #65 ----------------------------------------------------------
    $functions = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($f in $functions) {
        if (-not $f.Body.ParamBlock) { continue }
        $params = @($f.Body.ParamBlock.Parameters |
            ForEach-Object { $_.Name.VariablePath.UserPath })
        $assignments = $f.FindAll(
            { param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
        foreach ($a in $assignments) {
            if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $name = $a.Left.VariablePath.UserPath
            foreach ($p in $params) {
                # -ieq AND -cne together: the same name in a DIFFERENT case. The
                # same name in the same case is an assignment to the parameter,
                # which is ordinary — `if (-not $Channel) { $Channel = ... }`.
                if ($name -ieq $p -and $name -cne $p) {
                    Write-Output ("SHADOW`t{0}`t{1}`t{2}`t{3}`t{4}" -f `
                        $file.Name, $f.Name, $name, $p, $a.Extent.StartLineNumber)
                }
            }
        }
    }

    # ---- #91 ----------------------------------------------------------
    #
    # The signature is exact: `@('a', $b, $c + $d)` parses as a BinaryExpression
    # (Plus) whose LEFT is an ArrayLiteral. Nothing else produces that shape,
    # and a deliberate "append to this list" is written `$list + $x` with the
    # list in a variable — which is a VariableExpression on the left, not a
    # literal. So this cannot fire on correct code.
    $binaries = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] }, $true)
    foreach ($b in $binaries) {
        if ($b.Operator -ne 'Plus') { continue }
        if ($b.Left -isnot [System.Management.Automation.Language.ArrayLiteralAst]) { continue }
        $text = $b.Extent.Text -replace '\s+', ' '
        if ($text.Length -gt 70) { $text = $text.Substring(0, 70) + '...' }
        Write-Output ("ARRAYPLUS`t{0}`t{1}`t{2}" -f $file.Name, $b.Extent.StartLineNumber, $text)
    }

    # ---- #112 / #119 --------------------------------------------------
    #
    # `(… | Select-Object -Last 1).Property` is `$null.Property` when the
    # pipeline is empty, and OS7.psm1 sets Set-StrictMode -Version Latest,
    # under which that is a TERMINATING error rather than $null.
    #
    # THE SIGNATURE IS NARROW ON PURPOSE. It fires only on a member access
    # whose target is a parenthesised pipeline of two or more elements ENDING
    # IN Select-Object. `(Get-Foo).Bar` can fail the same way and is not
    # matched: it would fire on hundreds of correct lines and a check that
    # cries wolf is a check people delete. What IS matched is the exact idiom
    # this repository shipped thirteen times, twice into an administrator
    # manual's screenshots.
    #
    # The fix a hit asks for is two statements -- name the selection, then read
    # the property if there is one -- or, for the nine ZFS-property cases,
    # OS7.psm1's private Get-OS7ZfsPropertyValue.
    $members = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] }, $true)
    foreach ($m in $members) {
        $paren = $m.Expression
        if ($paren -isnot [System.Management.Automation.Language.ParenExpressionAst]) { continue }
        $pipe = $paren.Pipeline
        if ($pipe -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
        if ($pipe.PipelineElements.Count -lt 2) { continue }
        $last = $pipe.PipelineElements[-1]
        if ($last -isnot [System.Management.Automation.Language.CommandAst]) { continue }
        $name = $last.GetCommandName()
        if ($name -notin @('Select-Object', 'select')) { continue }
        $text = $m.Extent.Text -replace '\s+', ' '
        if ($text.Length -gt 70) { $text = $text.Substring(0, 70) + '...' }
        Write-Output ("STRICTPROP`t{0}`t{1}`t{2}" -f $file.Name, $m.Extent.StartLineNumber, $text)
    }

    # ---- #121 ---------------------------------------------------------
    #
    # $LASTEXITCODE is rewritten only when a native command COMPLETES through
    # the pipeline. Read bare, it is a StrictMode terminating error when no
    # native command has run yet, and an EARLIER command's code — 0 included —
    # when one has. The idiom is reset-then-guarded-read; a WRITE is the reset
    # half and a read under the Test-Path guard is the read half. Anything
    # else that reads the variable is a hit.
    $vars = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
    foreach ($v in $vars) {
        if ($v.VariablePath.UserPath -notmatch '(?i)^(global:)?LASTEXITCODE$') { continue }
        if ($v.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $v.Parent.Left -eq $v) { continue }
        $p = $v.Parent
        $guarded = $false
        while ($p) {
            if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
                foreach ($clause in $p.Clauses) {
                    if ($clause.Item1.Extent.Text -match '(?i)Test-Path\s+Variable:\\?LASTEXITCODE') {
                        $guarded = $true
                    }
                }
                if ($guarded) { break }
            }
            $p = $p.Parent
        }
        if ($guarded) { continue }
        $text = $v.Parent.Extent.Text -replace '\s+', ' '
        if ($text.Length -gt 70) { $text = $text.Substring(0, 70) + '...' }
        Write-Output ("BARELEC`t{0}`t{1}`t{2}" -f $file.Name, $v.Extent.StartLineNumber, $text)
    }

    # ---- #82 ----------------------------------------------------------
    #
    # A command call OUTSIDE every function definition runs at IMPORT, and hook
    # 0060 imports the module inside the build chroot, where a cmdlet resolved
    # BY NAME cannot be autoloaded. Only Microsoft.PowerShell.Core is already
    # there; anything else fails the BUILD with "The term '<name>' is not
    # recognized" and takes the whole ISO with it.
    #
    # The module a name belongs to is ASKED of Get-Command rather than kept in a
    # list here, because a list of "safe" cmdlets is exactly the kind of thing
    # that agrees with the code instead of checking it.
    $commands = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $commands) {
        $p = $c.Parent
        $inFunction = $false
        while ($p) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
                $inFunction = $true
                break
            }
            $p = $p.Parent
        }
        if ($inFunction) { continue }

        $name = $c.GetCommandName()
        if (-not $name) { continue }
        if ($defined.Contains($name)) { continue }

        $resolved = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        $module = if ($resolved) { $resolved.ModuleName } else { '' }
        if ($module -eq 'Microsoft.PowerShell.Core') { continue }
        if (-not $resolved) { $module = '(unresolved)' }

        Write-Output ("IMPORTSCOPE`t{0}`t{1}`t{2}`t{3}" -f `
            $file.Name, $c.Extent.StartLineNumber, $name, $module)
    }
}
Write-Output ("FILES`t{0}" -f $files.Count)
'''


def find_pwsh():
    for name in ("pwsh", "pwsh.exe", "powershell.exe"):
        found = shutil.which(name)
        if found:
            return found
    return None


def main():
    print("\n### five PowerShell traps, asked of the parser rather than of a regex")

    pwsh = find_pwsh()
    if not pwsh:
        print("      no pwsh on PATH; this check needs one and nothing else.")
        sys.exit(2)

    env = dict(os.environ)
    env["OS7_SCAN_ROOT"] = os.path.join(REPO, "powershell")
    got = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", SCAN],
                         capture_output=True, text=True, env=env)
    if got.returncode != 0:
        print(got.stderr[-2000:], file=sys.stderr)
        sys.exit(1)

    found = {"SHADOW": [], "ARRAYPLUS": [], "IMPORTSCOPE": [], "STRICTPROP": [],
             "BARELEC": [], "PARSE": []}
    files = 0
    for line in got.stdout.splitlines():
        parts = line.strip().split("\t")
        if parts[0] in found:
            found[parts[0]].append(parts[1:])
        elif parts[0] == "FILES":
            files = int(parts[1])

    for name, n, message in found["PARSE"]:
        print("      FAIL  %s does not parse (%s error(s)): %s" % (name, n, message[:80]))

    print("\n  #65 — a local named after a parameter, in a different case")
    if found["SHADOW"]:
        for name, func, local, param, line in found["SHADOW"]:
            print("      $%s in %s (%s:%s) IS the -%s parameter" % (local, func, name, line, param))
    else:
        print("      (none)")

    print("\n  #91 — a concatenation inside an array literal, which appends instead")
    if found["ARRAYPLUS"]:
        for name, line, text in found["ARRAYPLUS"]:
            print("      %s:%s  %s" % (name, line, text))
    else:
        print("      (none)")

    print("\n  #82 - a cmdlet called at IMPORT scope, which the build chroot cannot autoload")
    if found["IMPORTSCOPE"]:
        for name, line, cmd, module in found["IMPORTSCOPE"]:
            print("      %s:%s  %s  (%s)" % (name, line, cmd, module))
    else:
        print("      (none)")

    print("\n  #112/#119 - a property read off a pipeline that may be empty")
    if found["STRICTPROP"]:
        for name, line, text in found["STRICTPROP"]:
            print("      %s:%s  %s" % (name, line, text))
    else:
        print("      (none)")

    print("\n  #121 - a bare $LASTEXITCODE read: a crash, or an earlier command's code")
    if found["BARELEC"]:
        for name, line, text in found["BARELEC"]:
            print("      %s:%s  %s" % (name, line, text))
    else:
        print("      (none)")

    bad = False
    print()
    for key, label in (("SHADOW", "#65"), ("ARRAYPLUS", "#91"), ("IMPORTSCOPE", "#82"),
                       ("STRICTPROP", "#112/#119"), ("BARELEC", "#121")):
        n = len(found[key])
        base = BASELINE[key]
        if n > base:
            print("      %s: WORSE — %d, baseline %d" % (label, n, base))
            bad = True
        elif n < base:
            print("      %s: BETTER than the baseline (%d < %d). Lower BASELINE to hold it."
                  % (label, n, base))
            bad = True
        else:
            print("      %s: held at %d" % (label, n))

    print("\n      %d file(s) scanned" % files)
    if found["PARSE"]:
        print("\nA file that does not parse cannot be scanned, which is not the same as clean.")
        sys.exit(1)
    if bad:
        sys.exit(1)
    print("\nAll five held: no local shadows a parameter, no array literal hides "
          "an append, nothing outside a function calls a cmdlet the build "
          "chroot cannot autoload, no property is read off a pipeline that "
          "may be empty, and no $LASTEXITCODE is read bare.")


if __name__ == "__main__":
    main()
