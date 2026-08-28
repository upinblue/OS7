#!/usr/bin/env python3
"""
Does `os7-setup` call OS/7 cmdlets that EXIST, with parameters they HAVE?

    ./check-installer-cmdlets.py

WHY THIS EXISTS, and it is a defect this repository nearly shipped. The
installer shells out to PowerShell for the work the modules own — storage, and
since 2026-08-28 the domain join — because one implementation with two callers
is the only way to avoid BUILD-NOTES #66, a specification written twice taking
two routes. Nothing checked that the two halves agreed on the SPELLING.

`Steps/DomainSteps.cs` built:

    Join-OS7Domain -Root '<target>' ... -PasswordFile '/run/os7-setup-domain.key'

while `powershell/OS7/OS7.Domain.ps1` declares `-TargetRoot` and `-Password`.
There is no `-Root` and no `-PasswordFile`. Every domain join from the
installer would have failed at parameter binding, before adcli was ever
started, with `A parameter cannot be found that matches parameter name 'Root'`
— and it compiled, `--self-test` was clean, every module self-test was green,
and `check-ad.py` was green against a real domain controller, because none of
them ever looks at the installer's command lines.

TWO INDEPENDENT SOURCES OF TRUTH, COMPARED. The C# sources say what will be
typed; PowerShell says what will bind. This asks both and requires them to
agree — the same shape as `check-netplan-rule.py`, which holds two renderers of
one document byte for byte.

THIS FILE'S OWN FIRST VERSION REPORTED THE BROKEN CALL AS `ok`, and that is
worth leaving written down. It took the string literal the cmdlet name appears
in, and `DomainSteps.cs` builds the command by concatenating ONE LITERAL PER
PARAMETER, so the cmdlet's own literal contained no parameters at all. It
printed `Join-OS7Domain (0 parameter(s))  ok` three times. A diagnostic must be
checked against the thing it claims to check, and the way to do that is to run
it against the known defect BEFORE fixing the defect.

WHAT IT CANNOT SEE, stated so nobody reads a green run as more than it is:

  * It reads SOURCE TEXT. A parameter name assembled at run time from a
    variable is invisible to it, and so is a cmdlet invoked through one.
  * It checks that a parameter EXISTS, not that its value has the right type,
    not that a mandatory parameter was supplied, and not that the parameter set
    is satisfiable. `Join-OS7Domain -Domain x -ComputerName y` binds and does
    the wrong thing; that is `check-ad.py`'s business and `run-phase3.py`'s.
  * It says nothing about whether the cmdlet then works.

It needs `pwsh` and the modules; no VM, no ISO, no network, no domain. Seconds.
"""
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SOURCE = os.path.join(REPO, "installer", "src", "OS7.Setup")
MODULES = [
    os.path.join(REPO, "powershell", "OS7", "OS7.psd1"),
    os.path.join(REPO, "powershell", "Directory", "Directory.psd1"),
    os.path.join(REPO, "powershell", "Zfs", "Zfs.psd1"),
]

NEWLINE = "\n"
FAILS = []

# The cmdlets the installer may call, as a PATTERN rather than an enumeration:
# a new one added to a chroot script is covered without editing this file,
# which is the difference between a check that stays true and one that quietly
# stops covering the thing it was written for.
CMDLET = re.compile(
    r"\b((?:Get|Set|New|Remove|Test|Join|Update|Restore|Enable|Disable|Start|Stop|"
    r"Restart|Move|Add|Repair|Reset|Search|Enter|Exit|Unlock|Connect|Disconnect|"
    r"Import|Export|Mount|Dismount|Convert|Split|Clear|Rename|Wait|Resolve|Invoke|"
    r"Format|Sync)-(?:OS7|Directory|Zfs|Zpool)[A-Za-z0-9]*)\b")

# A parameter as it appears on a generated command line. No space is allowed
# between the hyphen and the name, so C# subtraction cannot match.
PARAMETER = re.compile(r"(?<![\w:])-([A-Z][A-Za-z0-9]*)\b")

# Words that follow a hyphen here and are not parameters of the cmdlet itself.
# Every advanced function has the common ones, so they can never be wrong.
NOT_A_PARAMETER = {
    "NoProfile", "NonInteractive", "Command", "File", "Confirm", "WhatIf",
    "Verbose", "Debug", "ErrorAction", "WarningAction", "InformationAction",
    "ErrorVariable", "WarningVariable", "InformationVariable", "OutVariable",
    "OutBuffer", "PipelineVariable", "ProgressAction", "Force", "Module",
}


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)


def note(text):
    print(f"      note  {text}")


def powershell_surface():
    """Ask PowerShell what every cmdlet in the modules accepts.

    Imported by PATH and not by name: a machine that happens to have an older
    OS7 module installed would otherwise answer for the wrong code, which is
    why every other check here does the same."""
    imports = "".join(
        "Import-Module '%s' -Force;" % m.replace("\\", "/").replace("'", "''")
        for m in MODULES)
    script = ("$ErrorActionPreference='Stop';" + imports + "$o=@{};"
              "foreach ($c in Get-Command -Module OS7,Directory,Zfs) {"
              "  $o[$c.Name] = @($c.Parameters.Keys) };"
              "$o | ConvertTo-Json -Depth 4 -Compress")
    result = subprocess.run(["pwsh", "-NoProfile", "-Command", script],
                            capture_output=True, text=True)
    text = result.stdout.strip()
    start = text.find("{")
    if start < 0:
        print(result.stderr[-2000:])
        sys.exit("pwsh did not return the cmdlet surface")
    return json.loads(text[start:])


def strip_comments(text):
    """Remove C# comments, keeping string contents and line numbering intact.

    The comments MUST go. The block above the broken call listed the parameter
    names it was about to get wrong, so a scanner that read comments would
    report a correct call as broken whenever a comment above it named an older
    spelling — a check that fails for a reason that is not a defect is a check
    people learn to ignore."""
    out = []
    index = 0
    end = len(text)
    while index < end:
        char = text[index]
        if char == '"':
            if text[index:index + 3] == '"""':
                stop = text.find('"""', index + 3)
                stop = end if stop < 0 else stop + 3
            else:
                stop = index + 1
                while stop < end and text[stop] != '"':
                    stop += 2 if text[stop] == "\\" else 1
                stop = min(stop + 1, end)
            out.append(text[index:stop])
            index = stop
        elif text[index:index + 2] == "//":
            stop = text.find(NEWLINE, index)
            stop = end if stop < 0 else stop
            out.append(" " * (stop - index))
            index = stop
        elif text[index:index + 2] == "/*":
            stop = text.find("*/", index + 2)
            stop = end if stop < 0 else stop + 2
            out.append("".join(c if c == NEWLINE else " " for c in text[index:stop]))
            index = stop
        else:
            out.append(char)
            index += 1
    return "".join(out)


def invocations(path):
    """Every cmdlet call in one C# file, with the parameters spelled for it.

    THE CALL IS NEITHER ON ONE LINE NOR IN ONE LITERAL. DomainSteps.cs builds
    it by concatenating one literal per parameter, so the window has to be the
    C# STATEMENT: from the cmdlet name to the first semicolon that is not
    inside a string, capped so a missing semicolon cannot swallow the file."""
    text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
    found = []
    for match in CMDLET.finditer(text):
        start = match.start()
        line = text[:start].count(NEWLINE) + 1
        index, end, depth = match.end(), len(text), 0
        while index < end:
            char = text[index]
            if char == '"':
                if text[index:index + 3] == '"""':
                    stop = text.find('"""', index + 3)
                    index = end if stop < 0 else stop + 3
                    continue
                index += 1
                while index < end and text[index] != '"':
                    index += 2 if text[index] == "\\" else 1
                index += 1
                continue
            if char == ";" and depth == 0:
                break
            if char in "({[":
                depth += 1
            elif char in ")}]":
                depth = max(0, depth - 1)
            index += 1
        window = text[start:index]
        if window.count(NEWLINE) > 60:
            window = NEWLINE.join(window.splitlines()[:60])
        found.append((line, match.group(1), narrow(window)))
    return found


def narrow(window):
    """Cut a C# statement down to the ONE PowerShell command it starts with.

    The C# statement is not the unit that matters; the PowerShell command is.
    DomainSteps.cs wraps the join in `try { Join-OS7Domain … } finally {
    Remove-Item -LiteralPath … }`, all in one C# expression, and without this
    the scanner attributed `Remove-Item`'s `-LiteralPath` to `Join-OS7Domain`
    and reported a defect that was not there. A check that cries wolf is a
    check people learn to skip, which is worse than not having it.

    The interpolation holes have to go first and have to keep their length, or
    the `}` that closes `{_t.Root}` ends the command two parameters early — and
    the index into the original window stops meaning anything."""
    flat = re.sub(r"\{\{|\}\}", "__", window)
    flat = re.sub(r"\{[^{}]*\}", lambda m: "_" * len(m.group(0)), flat)
    stops = [p for p in (flat.find(";"), flat.find("}"), flat.find("|")) if p >= 0]
    return window[:min(stops)] if stops else window


def main():
    print("### does os7-setup call cmdlets that exist, with parameters they have")
    print()

    if not shutil.which("pwsh"):
        note("NOT CHECKED. pwsh is not on PATH, and this asks the real modules "
             "what they accept.")
        return 0

    surface = powershell_surface()
    print(f"    {len(surface)} cmdlets across OS7, Directory and Zfs")
    print()

    calls = 0
    for root, _, names in os.walk(SOURCE):
        if os.sep + "obj" in root or os.sep + "bin" in root:
            continue
        for name in sorted(names):
            if not name.endswith(".cs"):
                continue
            path = os.path.join(root, name)
            relative = os.path.relpath(path, REPO).replace("\\", "/")
            for line, cmdlet, window in invocations(path):
                calls += 1
                if cmdlet not in surface:
                    check(False, f"{relative}:{line} calls {cmdlet}",
                          "no such cmdlet in OS7, Directory or Zfs")
                    continue
                accepted = set(surface[cmdlet])
                used = {m.group(1) for m in PARAMETER.finditer(window)}
                unknown = sorted(used - accepted - NOT_A_PARAMETER)
                if unknown:
                    near = {}
                    for one in unknown:
                        close = [a for a in accepted
                                 if one.lower() in a.lower() or a.lower() in one.lower()]
                        if close:
                            near[one] = close[0]
                    hint = ", ".join(f"-{k} -> -{v}" for k, v in near.items())
                    check(False,
                          f"{relative}:{line} calls {cmdlet} with "
                          + ", ".join("-" + u for u in unknown),
                          hint or "no similarly named parameter exists")
                else:
                    check(True, f"{relative}:{line} {cmdlet} "
                                f"({len(used - NOT_A_PARAMETER)} parameter(s))")

    if calls == 0:
        check(False, "the scanner found no cmdlet call at all",
              "if the installer stopped shelling out to PowerShell this file is "
              "dead and should be deleted rather than left passing")

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        print("A parameter that does not exist fails at BINDING, before the cmdlet runs,")
        print("and the installer's best-effort handling turns that into one log line.")
        return 1
    print("all checks passed — every cmdlet the installer names exists, and every")
    print("parameter it spells is one that cmdlet accepts. Whether the call then does")
    print("the right thing is check-ad.py's question, and run-phase3.py's.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
