#!/usr/bin/env python3
"""
Two PowerShell traps this repository has paid for, as a mechanism rather than a note.

    ./check-ps-traps.py            report, and fail if either got worse

Both are the same kind of defect: code that reads correctly, parses correctly,
and means something else. Neither produces a warning; both were found by a
machine doing the wrong thing.

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

BOTH BASELINES ARE 0 AND MAY NOT RISE. check-layering.py's reasoning applies
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
# 2026-08-27.
BASELINE = {"SHADOW": 0, "ARRAYPLUS": 0}

SCAN = r'''
$root = $env:OS7_SCAN_ROOT
$files = Get-ChildItem -LiteralPath $root -Recurse -Include *.psm1,*.ps1 |
    Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' }

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
    print("\n### two PowerShell traps, asked of the parser rather than of a regex")

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

    found = {"SHADOW": [], "ARRAYPLUS": [], "PARSE": []}
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

    bad = False
    print()
    for key, label in (("SHADOW", "#65"), ("ARRAYPLUS", "#91")):
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
    print("\nBoth traps held: no local shadows a parameter, and no array literal "
          "hides an append.")


if __name__ == "__main__":
    main()
