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

AND SINCE 2026-09-14 THE SAME RULE FOR PACKAGES, which cost a full ISO build to
learn. `build/config/hooks/0022-install-os7-packages.hook.chroot` installs an
explicit list of .deb FILES — not a repository — so apt can satisfy a
dependency only from what it is handed plus the archive. A package that is
built, staged into `/usr/lib/os7/packages/` and simply not NAMED in that list
produces

    os7-desktop : Depends: os7-automation (= 1.0.0.220) but it is not
    installable ... [no choices]

with the file sitting right there, twenty minutes into a build. `os7-backup` had
always been in that list for exactly this reason and nothing said so. So: every
`os7-*` a metapackage Depends on must be named in hook 0022.

AND SINCE 2026-09-14 THE LINE ENDINGS, which is the same species one level
down: `.gitattributes` says every text file here is LF in the working tree and
BUILD-NOTES #70 says what a CR does to a shebang, but that defends the CHECKOUT.
A writer that emits CRLF is invisible to `git status`, and eighteen files were
rewritten that way twice in one afternoon. Asked of `git ls-files --eol`, so the
exemptions are `.gitattributes`' own — the manual's serial transcripts are
`-text` and their CRs are the measurement (#16).

WHAT IT DOES NOT DO: it does not read PowerShell. Every list here is a literal
in a file, and the point is that the literals agree — so it is greps and set
comparisons, and it needs neither pwsh nor an image.
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
PKGDIR = os.path.join(REPO, "build", "packages")
HOOK0022 = os.path.join(
    REPO, "build", "config", "hooks",
    "0022-install-os7-packages.hook.chroot")

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




def metapackage_depends():
    """Every os7-* a metapackage Depends on, per metapackage.

    Read out of control.in, which is the file dpkg is handed. A Depends line
    wraps onto continuation lines beginning with a space, so this joins them
    before splitting — a parser that read only the first line would report
    os7-desktop as depending on os7-base alone, which is the half-right answer
    that is hardest to notice.
    """
    out = {}
    for meta in ("os7-base", "os7-server", "os7-desktop"):
        ctl = os.path.join(PKGDIR, meta, "control.in")
        if not os.path.exists(ctl):
            continue
        text, collecting, buf = read(ctl), False, []
        for line in text.split("\n"):
            if line.startswith("Depends:"):
                collecting = True
                buf.append(line[len("Depends:"):])
                continue
            if collecting:
                if line.startswith(" ") or line.startswith("\t"):
                    buf.append(line)
                    continue
                break
        names = set()
        for part in " ".join(buf).split(","):
            name = part.strip().split(" ")[0].strip()
            if name.startswith("os7-"):
                names.add(name)
        out[meta] = names
    return out


def hook0022_set():
    """The packages hook 0022 hands to apt as FILES, both arches' branches.

    `pick` AS WELL AS `SET`, and that is not tidiness: `os7-release` is
    installed on its own line, in its own transaction, BEFORE the set — because
    its postinst is what brands the identity and the hook verifies that before
    it installs anything else. A rule that read only SET reported os7-base as
    depending on a package nobody hands over, which is the check crying wolf
    about the one arrangement the hook is careful about.
    """
    text = read(HOOK0022)
    names = set()
    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        for pat in (r"SET=\(([^)]*)\)", r"SET\+=\(([^)]*)\)"):
            m = re.search(pat, stripped)
            if m:
                names |= {w for w in m.group(1).split() if w.startswith("os7-")}
        for m in re.finditer(r"pick\s+(os7-[A-Za-z0-9.+-]+)", stripped):
            names.add(m.group(1))
    return names


def check_packages():
    print("\n### the packages, in the places that name them")

    deps = metapackage_depends()
    handed = hook0022_set()
    print(f"    hook 0022 hands apt: {len(handed)} package file(s)")

    for meta, needs in sorted(deps.items()):
        if meta not in handed:
            # A metapackage nobody installs is not this rule's business — only
            # os7-base and the two products are handed over, and which of the
            # two depends on the architecture.
            continue
        missing = sorted(n for n in needs if n not in handed)
        check(not missing,
              f"every os7-* {meta} depends on is named in hook 0022",
              ("hook 0022 never names " + ", ".join(missing) +
               " — apt cannot satisfy that from a file it was not handed"
               if missing else f"{len(needs)} dependency(ies)"))

    # And the other direction: a package named in hook 0022 that nothing builds
    # is a `pick` that fails at build time with a shell error rather than an
    # apt one.
    built = set()
    for entry in sorted(os.listdir(PKGDIR)):
        if os.path.exists(os.path.join(PKGDIR, entry, "control.in")):
            built.add(entry)
    unbuilt = sorted(n for n in handed if n not in built)
    check(not unbuilt,
          "every package hook 0022 names has a control.in under build/packages",
          ", ".join(unbuilt) if unbuilt else f"{len(handed)} named, all built")

    # And that build-os7-packages.sh knows how to build each of them. ALL= is
    # what a bare invocation builds, and a package missing from it is one that
    # exists in the tree and never reaches /usr/lib/os7/packages.
    allline = re.search(r"ALL=\(([^)]*)\)", read(PKGS), re.S)
    allnames = set(allline.group(1).split()) if allline else set()
    # os7-desktop-theme has its own builder and always has —
    # build/lib/build-desktop-theme.sh, which rasterises icons and composes a
    # GTK stylesheet rather than copying a tree. Named here rather than allowed
    # by a pattern, so that the NEXT package with its own script has to be added
    # deliberately: "some packages are built somewhere else" is how a list stops
    # being a list.
    ELSEWHERE = {"os7-desktop-theme": "build/lib/build-desktop-theme.sh"}
    notbuilt = sorted(n for n in handed if n not in allnames and n not in ELSEWHERE)
    check(bool(allline) and not notbuilt,
          "and each is built — by build-os7-packages.sh's ALL= or by a named script",
          ", ".join(notbuilt) if notbuilt
          else f"{len(allnames)} in ALL=, plus " +
               ", ".join(f"{k} ({v})" for k, v in sorted(ELSEWHERE.items())))



def check_continuations():
    """A literal two-character `\\n` is not a line continuation.

    TWO BUILDS LOST TO IT, 2026-09-14, and the second one is the reason this
    function reads whole FILES rather than one block in one of them.

    An edit wrote `\\n` — backslash, letter n — where a real newline belongs, in
    a list of module files. Bash reads that outside quotes as the single
    character `n`, so:

        build-os7-packages.sh   !!! os7-module: built package is missing n
        hook 0060               /usr/local/share/powershell/Modules/OS7/n is
                                missing or empty

    Neither message names anything an operator can find, and every list check
    above stayed GREEN throughout both, because they read the files with a
    regex over PATHS — and a regex does not care what bash would make of the
    line. The lists agreed; the files were unreadable.

    THE FIRST VERSION OF THIS RULE ONLY LOOKED AT `pkg_finish` BLOCKS IN
    build-os7-packages.sh. It went green, the build was started, and twenty
    minutes later hook 0060 died of the identical defect three files away. A
    rule scoped to where the bug was found is a rule that catches that bug
    once. So: every shell file this repository owns, every line, and the rule
    is about SHAPE — a backslash inside a line, before a letter, is an escape
    bash will act on, and none of these files has a reason to contain one.
    """
    import glob
    files = []
    for pat in ("build/lib/*.sh", "build/build.sh", "build/config/hooks/*.chroot",
                "build/config/hooks/*/*.chroot"):
        files += sorted(glob.glob(os.path.join(REPO, pat)))

    bad = []
    for path in files:
        try:
            text = read(path)
        except (OSError, UnicodeDecodeError):
            continue
        for n, line in enumerate(text.split("\n"), 1):
            if line.lstrip().startswith("#"):
                continue
            # A backslash at END of line is the real thing and is fine. One
            # followed by a letter, anywhere, is an escape — and `\\n`, `\\t`
            # and `\\r` inside a quoted printf are legitimate, so quoted
            # stretches are blanked first.
            probe = re.sub(r"'[^']*'", "''", line)
            probe = re.sub(r'"[^"]*"', '""', probe)
            if re.search(r"\\[A-Za-z]", probe):
                bad.append((os.path.relpath(path, REPO), n, line.strip()[:70]))

    for rel, n, line in bad:
        print(f"    {rel}:{n}  {line}")
    check(not bad,
          "no shell file carries a literal backslash-escape where a "
          "continuation belongs",
          f"{len(bad)} line(s) bash would read as an extra argument"
          if bad else f"{len(files)} shell file(s), every continuation a real one")



def check_line_endings():
    """Every file git calls TEXT is LF in the working tree. Baseline 0.

    BUILD-NOTES #70 and #157. `.gitattributes` declares `* text=auto eol=lf`
    and says why at length: OS/7 is a Linux, every executable text file here is
    read by one, and a CR before the newline is part of the interpreter's name.
    A shell script that gains CRLF dies with

        /bin/bash^M: bad interpreter: No such file or directory

    **But .gitattributes defends the CHECKOUT.** Nothing in this repository
    defends against a WRITER that emits CRLF — an editor, a tool, a script that
    opened a file in text mode on Windows — and `git status` shows none of it,
    because the content is unchanged in git's eyes once the filter has run. On
    2026-09-14 eighteen files were rewritten that way by tooling in this
    worktree, twice, and the second time was after they had already been
    normalised once. That is the whole argument for a check rather than a
    paragraph: the paragraph is `.gitattributes`, it is excellent, and it
    cannot see this.

    IT ASKS GIT, NOT A LIST OF PATHS. `git ls-files --eol` reports, per file,
    the index ending, the WORKING TREE ending, and the attributes that decide
    both:

        i/lf    w/lf    attr/text=auto eol=lf   powershell/OS7/OS7.psm1
        i/crlf  w/crlf  attr/-text              docs/manual/transcripts/50-services.raw

    So the exemptions come from `.gitattributes` itself and cannot drift out of
    step with it — which matters here more than usual, because the exempt files
    are EVIDENCE. The 47 `-text` transcripts above are serial-console captures
    and their CRs are the measurement (BUILD-NOTES #16); a rule with its own
    hardcoded skip list would eventually edit one.

    `w/none` is a file with no line endings at all — a single line, no trailing
    newline — and is not a violation.
    """
    if not shutil.which("git"):
        # A check that cannot look must say so rather than pass. This one needs
        # git and nothing else, so it is not conditional on much.
        check(False, "line endings: git is on PATH to be asked",
              "NOT CHECKED — without git this rule cannot distinguish evidence "
              "from damage, and guessing is how a transcript gets edited")
        return

    out = subprocess.run(["git", "ls-files", "--eol"], cwd=REPO,
                         capture_output=True, text=True, encoding="utf-8",
                         errors="replace")
    if out.returncode != 0:
        check(False, "line endings: git could answer",
              (out.stderr or "").strip()[:200] or "git ls-files --eol failed")
        return

    bad, seen = [], 0
    for line in out.stdout.splitlines():
        if "\t" not in line:
            continue
        fields, path = line.split("\t", 1)
        # "i/lf    w/crlf  attr/text=auto eol=lf"
        parts = fields.split()
        if len(parts) < 3:
            continue
        work = parts[1]
        attr = " ".join(parts[2:])
        if "-text" in attr:
            continue          # git is told to leave it alone; so is this rule
        # WHAT THE WORKING-TREE FIELD CAN SAY, and three of the four are fine:
        #
        #   w/lf     what this repository wants
        #   w/none   no line endings at all — one line, no trailing newline
        #   w/-text  GIT DETECTED BINARY CONTENT and left the file alone. This
        #            is not an attribute; it is a finding about the bytes. The
        #            first version of this rule treated it as a violation and
        #            went red on the manual's two PDFs, which are not named in
        #            .gitattributes' binary block and so ride on `text=auto`.
        #            A rule that reports a PDF for its line endings is a rule
        #            somebody switches off.
        #   w/crlf   the violation
        #   w/mixed  the violation, and worse — half a file converted
        if work in ("w/lf", "w/none", "w/-text"):
            if work != "w/-text":
                seen += 1
            continue
        seen += 1
        bad.append((path.strip(), work))

    for path, work in bad:
        print(f"    {path}  ({work})")
    check(not bad,
          "every file git calls text is LF in the working tree (#70)",
          (f"{len(bad)} file(s) carry CRLF — .gitattributes defends the checkout "
           "and cannot defend against a writer") if bad
          else f"{seen} text file(s), all LF")


def main():
    print("\n### the OS7 module's parts, in the four places that name them")

    check_packages()
    check_continuations()
    check_line_endings()

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

    promised = check_manifests_deliver()
    check_hook_requires_real_functions(promised)
    check_reference_counts()

    print(f"\n  {_ok} ok, {_bad} failed")
    print("check-module-parts:", "GREEN" if _bad == 0 else "RED")
    sys.exit(1 if _bad else 0)


REFERENCE = os.path.join(REPO, "docs", "POWERSHELL-REFERENCE.md")
MODULES = ("Zfs", "Net", "Time", "Systemd", "Directory", "Hardware", "OS7")

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


def hook_required_functions(text):
    """What hook 0060 requires each module to EXPORT, per `check_module` line.

    Returns {module: {name, ...}}. The lines continue with backslashes and the
    first word after the module name is a function, so the whole logical line
    is joined before it is split.
    """
    out = {}
    joined = re.sub(r"\\\s*\n\s*", " ", text)
    for m in re.finditer(r"^check_module\s+([A-Za-z0-9]+)\s+(.*)$", joined, re.M):
        name, rest = m.group(1), m.group(2)
        out[name] = set(re.findall(r"\b([A-Z][A-Za-z]*-[A-Za-z0-9]+)\b", rest))
    return out


def check_hook_requires_real_functions(promised):
    """Every function hook 0060 requires must be one the module PROMISES.

    The hook runs inside the chroot during the ISO build and fails it when a
    named function is not exported. That is the right behaviour and a slow way
    to learn about a typo: the build has already spent twenty minutes by the
    time it gets there. This is the same question asked in a second.

    IT IS DELIBERATELY NOT "the hook names everything". Those lists are curated
    — Zfs names nine of twenty-six, and its own comment says which name is the
    reason each line exists. A rule demanding completeness would be arguing
    with the file's design; a rule demanding that what it DOES name is real is
    the part that can only be wrong by accident.

    The coverage question is reported instead, so that a list which has fallen
    behind its module is visible rather than silent — which is exactly what
    happened to `check_module Systemd`: thirteen named, twenty-one promised,
    for one day.
    """
    text = read(HOOK)
    required = hook_required_functions(text)
    if not required:
        check(False, "hook 0060's check_module lines could be read")
        return
    for mod in MODULES:
        want = required.get(mod, set())
        if not want:
            check(False, f"hook 0060 has a check_module line for {mod}")
            continue
        unreal = sorted(want - promised.get(mod, set()))
        check(not unreal,
              f"the {len(want)} functions hook 0060 requires of {mod} are all real",
              "NOT PROMISED BY THE MANIFEST: " + ", ".join(unreal) if unreal else "")
    # The note, not a rule: how much of each surface the image is held to.
    short = [f"{m} {len(required.get(m, set()))}/{len(promised.get(m, set()))}"
             for m in MODULES
             if len(required.get(m, set())) < len(promised.get(m, set()))]
    if short:
        print("      note  hook 0060 holds the image to part of the surface: "
              + ", ".join(short) + " — curated by design, but a list that has "
              "fallen behind its module is invisible from inside the build")


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
        return {}
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
        return {}
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

    # Handed on rather than measured twice: the hook rule needs the same
    # promises and a second pwsh start costs more than every check here.
    return {m: got[("PROMISED", m)] for m in MODULES}


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
    # THE MODULE COUNT IS NOT HARDCODED HERE, and it was: this regex read
    # "in six modules" and stopped matching the moment a seventh landed,
    # reporting "<no count found>" — which reads as a missing headline
    # rather than as a check that had gone stale. A check that breaks when
    # the thing it measures grows is a check that gets deleted.
    m = re.search(r"\*\*(\d+) functions in (\w+) modules\.\*\*", text)
    check(bool(m) and int(m.group(1)) == total,
          f"POWERSHELL-REFERENCE.md's headline says {total}",
          f"it says {m.group(1) if m else '<no count found>'}")
    # And the WORD beside it, because "266 functions in six modules" is
    # half right in the way that is hardest to notice.
    words = {1: "one", 2: "two", 3: "three", 4: "four", 5: "five",
             6: "six", 7: "seven", 8: "eight", 9: "nine", 10: "ten"}
    check(bool(m) and m.group(2) == words.get(len(MODULES), str(len(MODULES))),
          f"and that it says {words.get(len(MODULES))} modules",
          f"it says {m.group(2) if m else '<nothing>'}")

    for mod in MODULES:
        row = re.search(rf"powershell/{mod}/\)[^|]*\|[^|]*\|\s*(\d+)\s*\|", text)
        check(bool(row) and int(row.group(1)) == counts[mod],
              f"and its {mod} row says {counts[mod]}",
              f"it says {row.group(1) if row else '<no row>'}")


if __name__ == "__main__":
    main()
