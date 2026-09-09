#!/usr/bin/env python3
"""
The OS7 module is one directory named in FOUR places. Do they agree?

    ./installer/testing/check-module-parts.py     seconds, no pwsh, no Docker

WHY THIS FILE EXISTS, in the words of the file it checks. `build/lib/build-os7-
packages.sh` says of its own required-path list:

    The two lists are asserted equal by nothing; they are just short enough to
    read side by side, and the OS7.psm1 foreach is the one to read.

That was true and it is the shape of every defect in this area. `OS7.psm1`
dot-sources a list of parts; hook 0060 requires each of them in the built
image; `build-os7-packages.sh` requires each of them in the .deb; and
`OS7.psd1` exports the functions they define. A part added to one list and not
the others produces:

  * missing from the .psm1 list — the file ships and nothing in it is defined.
    `. file.ps1` is never reached, so there is no error anywhere;
  * missing from the .deb list — the loop still copies it, so today it works,
    and the day something changes the copy the assertion is not there;
  * missing from hook 0060 — the image is not checked for it;
  * missing from the .psd1 — `Import-Module OS7` succeeds and the cmdlet is
    not there, which reads to an operator as a cmdlet that does not exist.

The comment above was written by the merge that had ALREADY lost four files
this way (OS7.Directory, OS7.DirectoryObject, OS7.Domain, OS7.Update: "each
branch added a file where the other was not looking"). This is that comment
turned into a check, on the day a fifth file was added by hand to all three
and the fourth list was noticed.

WHAT IT DOES NOT DO: it does not read PowerShell. Every list here is a literal
in a file, and the point is that the literals agree — so it is four greps and
a set comparison, and it needs neither pwsh nor an image.
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

PSM1 = os.path.join(REPO, "powershell", "OS7", "OS7.psm1")
PSD1 = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")
HOOK = os.path.join(REPO, "build", "config", "hooks", "0060-os7-module.hook.chroot")
PKGS = os.path.join(REPO, "build", "lib", "build-os7-packages.sh")
MODDIR = os.path.join(REPO, "powershell", "OS7")

_ok = 0
_bad = 0


def check(cond, what, detail=""):
    global _ok, _bad
    if cond:
        _ok += 1
        print(f"  ok    {what}" + (f" — {detail}" if detail else ""))
    else:
        _bad += 1
        print(f"  FAIL  {what}" + (f" — {detail}" if detail else ""))
    return bool(cond)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def psm1_parts(text):
    """The parts OS7.psm1 dot-sources, from its `foreach ($part in @(...))`."""
    m = re.search(r"foreach\s*\(\s*\$part\s+in\s+@\((.*?)\)\)\s*\{", text, re.S)
    if not m:
        sys.exit("could not find the dot-source foreach in OS7.psm1")
    return set(re.findall(r"'(OS7\.[A-Za-z.]+\.ps1)(?!xml)'", m.group(1)))


def hook_parts(text):
    """The parts hook 0060 requires, from its `for part in ...` list.

    The loop also names OS7.psd1, OS7.psm1, the format file and the endpoints
    JSON; only the dot-sourced .ps1 parts are compared, because those are the
    ones the .psm1 list is about.
    """
    m = re.search(r"for part in\s+(.*?);\s*do", text, re.S)
    if not m:
        sys.exit("could not find the `for part in` list in hook 0060")
    return {p for p in re.findall(r"(OS7\.[A-Za-z.]+\.ps1)(?!xml)", m.group(1))}


def pkg_parts(text):
    """The parts the .deb's required-path list names."""
    m = re.search(r"pkg_finish\s+os7-module\s+(.*?)\n\n", text, re.S)
    if not m:
        sys.exit("could not find pkg_finish os7-module in build-os7-packages.sh")
    return set(re.findall(r"Modules/OS7/(OS7\.[A-Za-z.]+\.ps1)(?!xml)", m.group(1)))


def on_disk():
    """What the module directory actually contains.

    OS7.psm1 is excluded because it is the file doing the dot-sourcing, not a
    part of the list.
    """
    return {f for f in os.listdir(MODDIR)
            if re.fullmatch(r"OS7\.[A-Za-z.]+\.ps1", f) and f != "OS7.psm1"}


def exported(text):
    """Every function name the manifest exports.

    DELIMITED BY THE NEXT SIBLING KEY, not by a closing paren. This manifest's
    array closes on the same line as the entry that follows it, so a
    `@\\((.*?)\\)` search matches nothing at all and a greedy one swallows the
    rest of the file — the first version of this function did the former and
    said "could not find FunctionsToExport" about a manifest that has one. The
    keys sit at one tab; that is the structure to lean on.
    """
    start = text.find("FunctionsToExport")
    if start < 0:
        sys.exit("could not find FunctionsToExport in OS7.psd1")
    rest = text[start:]
    nxt = re.search(r"\n\t(?=[A-Za-z])", rest[20:])
    seg = rest[:20 + nxt.start()] if nxt else rest
    return set(re.findall(r"'([A-Za-z]+-[A-Za-z0-9]+)'", seg))


def defined(paths):
    """Every function the parts define, by name."""
    names = set()
    for p in paths:
        for m in re.finditer(r"^function\s+([A-Za-z]+-[A-Za-z0-9]+)\s*\{?",
                             read(p), re.M):
            names.add(m.group(1))
    return names


def main():
    print("\n### the OS7 module's parts, in the four places that name them")

    psm1, psd1 = read(PSM1), read(PSD1)
    lists = {
        "OS7.psm1 dot-sources": psm1_parts(psm1),
        "hook 0060 requires": hook_parts(read(HOOK)),
        "the .deb requires": pkg_parts(read(PKGS)),
        "the directory holds": on_disk(),
    }
    for name, parts in lists.items():
        print(f"    {name}: {len(parts)}")

    ref = lists["the directory holds"]
    for name, parts in lists.items():
        if name == "the directory holds":
            continue
        missing = sorted(ref - parts)
        extra = sorted(parts - ref)
        check(not missing and not extra,
              f"{name} names exactly the {len(ref)} parts on disk",
              ("missing " + ", ".join(missing) if missing else "")
              + ("; " if missing and extra else "")
              + ("names absent files: " + ", ".join(extra) if extra else ""))

    # AND THE EXPORTS, which is the fourth list and the one an operator meets.
    # A part can be copied, required and dot-sourced, and its cmdlet still not
    # exist as far as `Import-Module OS7` is concerned — hook 0060 says so
    # about itself: "Naming those cmdlets in the export list above is the
    # second half of this guard and is still owed."
    #
    # Private helpers are excluded by NAME rather than by guessing: everything
    # a part defines is compared, minus the ones deliberately internal.
    paths = [os.path.join(MODDIR, f) for f in sorted(ref)]
    internal = {n for n in defined(paths)
                if n.startswith(("Import-OS7", "Resolve-OS7", "Invoke-OS7",
                                 "Assert-OS7", "Format-OS7", "ConvertTo-OS7",
                                 "ConvertFrom-OS7", "Read-OS7", "Write-OS7",
                                 "Join-OS7", "Test-OS7Service", "New-OS7Temp"))}
    public = defined(paths) - internal
    exports = exported(psd1)
    unexported = sorted(public - exports)
    # NOT an error by itself: a part may define something the surface plan
    # deliberately keeps internal under a name this file cannot recognise. It
    # is REPORTED, so that a cmdlet nobody can call is visible rather than
    # silent, and so the "still owed" note above stops being invisible.
    if unexported:
        print(f"      note  {len(unexported)} function(s) defined by a part and not "
              f"exported: {', '.join(unexported[:8])}"
              + (" …" if len(unexported) > 8 else ""))
    else:
        check(True, "every public function a part defines is exported")

    # The other direction IS an error: a manifest that promises a function
    # nothing defines makes `Import-Module` fail on a machine, or worse,
    # succeed and hand an operator a name that resolves to nothing.
    psm1_defined = {m.group(1) for m in
                    re.finditer(r"^function\s+([A-Za-z]+-OS7[A-Za-z]*)\s*\{?", psm1, re.M)}
    phantom = sorted(exports - public - internal - psm1_defined)
    check(not phantom,
          f"every one of the {len(exports)} exported names is defined somewhere",
          ", ".join(phantom) if phantom else "")

    check_manifests_deliver()
    check_reference_counts()

    print(f"\n  {_ok} ok, {_bad} failed")
    print("check-module-parts:", "GREEN" if _bad == 0 else "RED")
    sys.exit(1 if _bad else 0)


REFERENCE = os.path.join(REPO, "docs", "POWERSHELL-REFERENCE.md")
MODULES = ("Zfs", "Net", "Time", "Systemd", "Directory", "OS7")

# OS7_MODULE_ROOT points the manifest rule at another copy of powershell/,
# which is how it is proven to FIRE rather than only to stay quiet: copy the
# tree aside, take a name out of a .psm1's Export-ModuleMember while leaving
# it in the .psd1, point this at the copy, and require RED. Same argument as
# check-ps-traps.py's OS7_SCAN_ROOT and check-secureboot-logic.py's
# OS7_SB_MODULE — and the same reason not to plant the defect in the working
# tree, which somebody may be editing while the check runs.
MODULE_ROOT = os.environ.get("OS7_MODULE_ROOT") or os.path.join(REPO, "powershell")


def module_psd1(name):
    return os.path.join(MODULE_ROOT, name, name + ".psd1")


def check_manifests_deliver():
    """Does every module DELIVER what its manifest promises, and nothing else?

    A .psd1's `FunctionsToExport` and a .psm1's `Export-ModuleMember` are two
    lists that have to agree, and PowerShell takes the INTERSECTION — so a name
    in the manifest and not in the module is not exported, `Import-Module`
    still succeeds, and an operator who types it is told the cmdlet does not
    exist. Nothing says a word.

    THIS RULE EXISTS BECAUSE IT HAPPENED, one day after this file was written
    and in a module this file does not read the parts of. `Systemd.psd1` grew
    eight names — Invoke-SystemdShutdown, the freezer pair, the service pair,
    the host-name pair — the .psm1 grew all eight functions, `Test-SystemdModule`
    grew to 95 checks over them, and `Export-ModuleMember` was left at
    thirteen. `Get-Command -Module Systemd` returned 13 while the manifest
    promised 21.

    So it asks the MODULE rather than parsing either list: what the manifest
    says, against what `Import-Module` actually hands over. That is the only
    comparison an operator's experience depends on, and it catches every
    direction at once — a name missing from Export-ModuleMember, a function
    that was never written, and a typo in either place.
    """
    if not shutil.which("pwsh"):
        print("      note  pwsh is not on this host; the manifests' promises "
              "were not checked")
        return
    script = "; ".join(
        f"Import-Module {module_psd1(m)} -Force"
        for m in MODULES)
    # The manifest's own list, read by PowerShell rather than by a regex, and
    # what the module hands over. Two lines per module, one prefix each.
    script += "; " + "; ".join(
        f"'PROMISED {m}=' + (((Import-PowerShellDataFile "
        f"{module_psd1(m)}).FunctionsToExport "
        f"| Sort-Object) -join ','); "
        f"'DELIVERED {m}=' + (((Get-Command -Module {m} -CommandType Function)"
        f".Name | Sort-Object) -join ',')"
        for m in MODULES)
    out = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", script],
                         capture_output=True, text=True)
    if out.returncode != 0:
        check(False, "every module could be asked what it exports",
              (out.stderr or out.stdout).strip()[-200:])
        return
    text = out.stdout.replace("\r", "")
    got = {}
    for kind in ("PROMISED", "DELIVERED"):
        for m in MODULES:
            mt = re.search(rf"^{kind} {m}=(.*)$", text, re.M)
            got[(kind, m)] = set(filter(None, (mt.group(1) if mt else "").split(",")))

    for m in MODULES:
        promised, delivered = got[("PROMISED", m)], got[("DELIVERED", m)]
        missing = sorted(promised - delivered)
        extra = sorted(delivered - promised)
        check(not missing and not extra,
              f"{m} delivers the {len(promised)} functions its manifest promises",
              ("PROMISED BUT NOT EXPORTED: " + ", ".join(missing) if missing else "")
              + ("; " if missing and extra else "")
              + ("exported but not promised: " + ", ".join(extra) if extra else ""))


def check_reference_counts():
    """Do the numbers in docs/POWERSHELL-REFERENCE.md match the modules?

    CLAUDE.md makes this argument about itself: "a count in prose has nothing
    checking it, which is the argument for the reference file being GENERATED
    rather than maintained." The reference is generated by hand-editing after
    a generation, so its counts go stale silently — and they had: on
    2026-09-08 the file said 202 functions in six modules and the modules
    reported 221, eighteen of them from two commits that were nothing to do
    with the file. Now the prose has something checking it.

    pwsh is asked, not the source parsed: what the file claims is how many
    functions an operator can CALL, which is `Get-Command -Module`, not how
    many `function` keywords are in a directory.
    """
    if not shutil.which("pwsh"):
        print("      note  pwsh is not on this host; the reference's counts were "
              "not checked")
        return
    script = "; ".join(
        f"Import-Module {os.path.join(REPO, 'powershell', m, m + '.psd1')} -Force"
        for m in MODULES)
    script += "; " + "; ".join(
        f"'{m}=' + (Get-Command -Module {m} -CommandType Function).Count"
        for m in MODULES)
    out = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-Command", script],
                         capture_output=True, text=True)
    if out.returncode != 0:
        check(False, "the modules could load so their functions could be counted",
              (out.stderr or out.stdout).strip()[-200:])
        return
    # CARRIAGE RETURNS STRIPPED FIRST. pwsh on Windows ends every line with
    # CR LF, and `$` under re.MULTILINE matches before the LF — so `26\r` does
    # not end at `$` and every count silently fails to parse. run-s5.py's
    # body_of() strips CRs "once, for everything" for exactly this reason, and
    # this file paid the same toll to learn it.
    # [A-Za-z0-9]+ AND NOT [A-Za-z]+: the product's module is called OS7, so
    # the one name this whole file is about is the one a letters-only pattern
    # cannot match. The first version parsed five modules out of six and
    # reported that "every module answered with a count" had failed — about
    # output that was correct.
    #
    # Carriage returns are stripped first for the usual reason: pwsh on
    # Windows ends lines with CR LF and `$` under re.MULTILINE matches before
    # the LF, so `26\r` does not end at `$`.
    counts = dict(re.findall(r"^([A-Za-z0-9]+)=(\d+)$",
                             out.stdout.replace("\r", ""), re.M))
    if len(counts) != len(MODULES):
        check(False, "every module answered with a count", out.stdout.strip()[:200])
        return
    counts = {k: int(v) for k, v in counts.items()}
    total = sum(counts.values())

    text = read(REFERENCE)
    m = re.search(r"\*\*(\d+) functions in six modules\.\*\*", text)
    check(bool(m) and int(m.group(1)) == total,
          f"POWERSHELL-REFERENCE.md's headline says {total}",
          f"it says {m.group(1) if m else '<no count found>'}")

    for mod in MODULES:
        row = re.search(rf"powershell/{mod}/\)[^|]*\|[^|]*\|\s*(\d+)\s*\|", text)
        check(bool(row) and int(row.group(1)) == counts[mod],
              f"and its {mod} row says {counts[mod]}",
              f"it says {row.group(1) if row else '<no row>'}")


if __name__ == "__main__":
    main()
