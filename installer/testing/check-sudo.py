#!/usr/bin/env python3
"""
P13: what `sudo <arguments>` means in an OS/7 PowerShell session.

    ./installer/testing/check-sudo.py              seconds, needs only pwsh, both hosts
    ./installer/testing/check-sudo.py --self-test  and plants three defects

WHAT IT IS FOR. POWERSHELL-SURFACE-PLAN P13 (owner's decision 2026-10-29) gives
the interactive session a `sudo` FUNCTION, from $PSHOME/profile.ps1, so that
`sudo Update-OS7` runs Update-OS7 elevated instead of answering "command not
found" (#148). It shadows a system command, and P1a's rule for that is the one
check-compat-windows.py holds: what reaches the real program must be exactly
what was typed, and a PowerShell command must be elevated rather than lost.

The decision lives in ConvertTo-OS7SudoCommand, which starts no process, so it
is asked here directly, case by case, with the profile dot-sourced from the
TREE (build/packages/os7-powershell/profile.ps1) - the file the package ships.
`sudo` itself, which only executes the decision, is exercised on a machine
(SESSION-QOL-SURVEY §8).

Run under de-DE on purpose: a number rendered with the current culture becomes
`1,5`, which an elevated PowerShell reads as an ARRAY of 1 and 5.

PROVEN TO FIRE (--self-test): a copy of the profile with alias resolution
removed, with numbers rendered in the current culture, and with quote escaping
removed - each must turn this check red. OS7_PROFILE points the check at any
other copy.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PROFILE = os.path.join(REPO, "build", "packages", "os7-powershell", "profile.ps1")

# (description, PowerShell expression for the argument array, expected Kind,
#  expected Command or a substring of the Reason)
CASES = [
    ("no arguments go to sudo", "@()", "Passthrough", None),
    ("sudo's own option (-i) goes to sudo", "@('-i')", "Passthrough", None),
    ("a program goes to sudo untouched", "@('pwsh', '-c', 'x')", "Passthrough", None),
    ("an unknown name goes to sudo, which says so as before",
     "@('no-such-command-os7')", "Passthrough", None),
    ("a cmdlet is elevated, its arguments quoted",
     "@('Get-ChildItem', '-Path', '/x y')", "PowerShell",
     "& 'Get-ChildItem' -Path '/x y'"),
    ("a function in this session is elevated",
     "@('Update-OS7Fake', '-AllowDevelopment')", "PowerShell",
     "& 'Update-OS7Fake' -AllowDevelopment"),
    ("an alias is resolved and elevated", "@('gci')", "PowerShell", "& 'gci'"),
    ("-Name:value keeps the colon form",
     "@('Get-ChildItem', '-Force:', $false)", "PowerShell",
     "& 'Get-ChildItem' -Force:$false"),
    ("a quote inside a value survives", "@('Get-ChildItem', \"it's\")", "PowerShell",
     "& 'Get-ChildItem' 'it''s'"),
    ("numbers are invariant, never 1,5", "@('Get-ChildItem', 42, 1.5)", "PowerShell",
     "& 'Get-ChildItem' 42 1.5"),
    ("booleans and null", "@('Get-ChildItem', $true, $null)", "PowerShell",
     "& 'Get-ChildItem' $true $null"),
    ("a list becomes @(...)", "@('Get-ChildItem', @(1, 'a'))", "PowerShell",
     "& 'Get-ChildItem' @(1, 'a')"),
    ("an object that cannot cross a process is refused, with the way that works",
     "@('Get-ChildItem', @{ a = 1 })", "Refused", "sudo pwsh -c"),
]


def run(profile: str) -> tuple[int, int, list[str]]:
    script = [
        "$ErrorActionPreference = 'Stop'",
        "[System.Threading.Thread]::CurrentThread.CurrentCulture = 'de-DE'",
        f". '{profile}'",
        "function Update-OS7Fake { param([switch]$AllowDevelopment) }",
        "$out = @()",
    ]
    for i, (_, expr, _, _) in enumerate(CASES):
        script.append(
            f"$r = ConvertTo-OS7SudoCommand -ArgumentList ({expr}); "
            f"$out += [pscustomobject]@{{ I = {i}; Kind = $r.Kind; "
            f"Command = $r.Command; Reason = $r.Reason }}")
    script.append("$out | ConvertTo-Json -Compress -Depth 3")
    p = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", "\n".join(script)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0 or not p.stdout.strip():
        return 0, 1, ["pwsh did not answer: " + (p.stderr.strip().splitlines() or ["?"])[-1]]
    got = {r["I"]: r for r in json.loads(p.stdout)}
    ok, bad, lines = 0, 0, []
    for i, (what, _, kind, want) in enumerate(CASES):
        r = got.get(i, {})
        if kind == "Refused":
            good = r.get("Kind") == kind and want in (r.get("Reason") or "")
        elif want is None:
            good = r.get("Kind") == kind
        else:
            good = r.get("Kind") == kind and r.get("Command") == want
        detail = "" if good else f" — got {r.get('Kind')}: {r.get('Command') or r.get('Reason')}"
        lines.append(f"      {'ok  ' if good else 'FAIL'}  {what}{detail}")
        ok, bad = (ok + 1, bad) if good else (ok, bad + 1)
    return ok, bad, lines


def plant(src: str, old: str, new: str, tmp: str, name: str) -> str:
    text = open(src, encoding="utf-8").read()
    if old not in text:
        sys.exit(f"--self-test: the profile no longer contains the line to break ({name})")
    path = os.path.join(tmp, f"profile-{name}.ps1")
    open(path, "w", encoding="utf-8", newline="\n").write(text.replace(old, new, 1))
    return path


def main() -> int:
    if not shutil.which("pwsh"):
        sys.exit("pwsh not found - this check runs the shipped profile in PowerShell")
    profile = os.environ.get("OS7_PROFILE") or PROFILE
    print(f"\n### P13 — sudo, decided by {os.path.relpath(profile, REPO)}\n")
    ok, bad, lines = run(profile)
    print("\n".join(lines))
    print(f"\n{ok + bad} checks, {bad} failed")
    if "--self-test" not in sys.argv[1:]:
        return 1 if bad else 0

    print("\n### --self-test: three planted defects, each must turn this red\n")
    tmp = tempfile.mkdtemp(prefix="os7-sudo-")
    planted = {
        "alias-not-resolved": (
            "if ($found -and $found.CommandType -eq 'Alias') { $found = $found.ResolvedCommand }",
            ""),
        "culture-numbers": (
            "return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)",
            "return $Value.ToString()"),
        "no-quote-escaping": (
            "return \"'\" + $Value.Replace(\"'\", \"''\") + \"'\"",
            "return \"'\" + $Value + \"'\""),
    }
    fired = 0
    for name, (old, new) in planted.items():
        _, b, _ = run(plant(profile, old, new, tmp, name))
        print(f"      {'ok  ' if b else 'FAIL'}  {name}: {b} check(s) red")
        fired += 1 if b else 0
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{fired} of {len(planted)} planted defects caught")
    return 1 if bad or fired != len(planted) else 0


if __name__ == "__main__":
    sys.exit(main())
