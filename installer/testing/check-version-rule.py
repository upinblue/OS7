#!/usr/bin/env python3
"""
The version DISPLAY RULE, checked in both languages, in seconds and without a VM.

    ./check-version-rule.py                     PowerShell half only
    ./check-version-rule.py --setup <os7-setup> both halves

WHY IT EXISTS. docs/IDENTITY-PLAN.md §5 says a person is shown three fields and
a machine four, and that rule is implemented TWICE: in C# by
`installer/src/OS7.Setup/Model/Release.cs` (`Short`/`Full`), and in PowerShell by
`Get-OS7Version`. Two implementations of one specification, in two languages,
each maintained by whoever is editing that side — and nothing else in this
repository can make them disagree loudly. The failure they would produce is the
worst kind: a title row and a cmdlet quoting different numbers for one machine,
both of them plausible, neither of them wrong-looking.

So the CASES BELOW ARE THE SPECIFICATION, they live here and nowhere else, and
both implementations are checked against them rather than against each other.
Checking the two against each other would pass the day they drift together.

WHAT IT IS NOT. It says nothing about what is on a screen — `run-phase1.py`
reads the title row off a framebuffer through the console font, and nothing here
replaces it. It says nothing about an installed machine either.

THE C# HALF NEEDS A RUNNABLE `os7-setup`, which is a Linux binary: on macOS and
Windows there is nothing to run, so that half is REPORTED AS NOT CHECKED rather
than quietly skipped or counted as a pass. "Cannot tell" is not "clean" — the
rule this repository keeps re-learning, most recently as BUILD-NOTES #80. Build
one with the container one-liner in CLAUDE.md and pass --setup.

    docker run --rm --platform linux/arm64 -v "$PWD":/work os7-build:arm64 bash -c \\
      'cd /work/installer/src/OS7.Setup && dotnet publish -c Release -r linux-arm64 \\
       -p:PublishAot=true -o /tmp/pub && cp /tmp/pub/os7-setup /work/out/'
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

import os7version

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MODULE = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")

# ---------------------------------------------------------------------------
# THE SPECIFICATION. docs/IDENTITY-PLAN.md §5.1.
#
#   short  three fields, plus the channel in brackets unless it is `stable`
#   full   all four, same channel rule
#
# The odd ones are not padding. A version with fewer than four fields comes back
# unchanged rather than padded, and one with MORE than four keeps only the first
# three in the friendly form — because a display rule reads a file, and a file
# can hold anything.
# ---------------------------------------------------------------------------
CASES = [
    # version,        channel,        short,                   full
    ("1.0.0.95",      "development",  "1.0.0 (development)",   "1.0.0.95 (development)"),
    ("1.0.0.95",      "stable",       "1.0.0",                 "1.0.0.95"),
    ("2.1.4.1207",    "preview",      "2.1.4 (preview)",       "2.1.4.1207 (preview)"),
    ("1.0.0.0",       "unknown",      "1.0.0 (unknown)",       "1.0.0.0 (unknown)"),
    ("10.20.30.40",   "development",  "10.20.30 (development)","10.20.30.40 (development)"),
    # fewer than four fields — unchanged, not padded
    ("1.0",           "stable",       "1.0",                   "1.0"),
    ("1.0.0",         "stable",       "1.0.0",                 "1.0.0"),
    # more than four — the friendly form is still the first three
    ("1.2.3.4.5",     "stable",       "1.2.3",                 "1.2.3.4.5"),
]

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)
    return ok


def pwsh():
    exe = shutil.which("pwsh")
    if not exe:
        sys.exit("pwsh not found; this check runs the real powershell/OS7 module.")
    return exe


def run_pwsh(script, env=None):
    """One pwsh, -NoProfile, output as text. Raises on a non-zero exit."""
    p = subprocess.run([pwsh(), "-NoProfile", "-NonInteractive", "-Command", script],
                       capture_output=True, text=True, env=env)
    if p.returncode != 0:
        raise SystemExit(f"pwsh exited {p.returncode}:\n{p.stdout}\n{p.stderr}")
    return p.stdout


# ---------------------------------------------------------------------------
# 1. The rule, in PowerShell — through the PUBLIC cmdlet
#
# Driven by writing one manifest per case and calling `Get-OS7Version -Path`,
# not by reaching into the module for its internal formatter. The formatter
# being right is not the claim; the claim is that what an operator gets is
# right, and between the two sits the manifest reader, the friendly-version
# derivation and the object construction.
# ---------------------------------------------------------------------------
def powershell_rule(lab):
    print("\n  the display rule — PowerShell, through Get-OS7Version")

    for i, (version, channel, _, _) in enumerate(CASES):
        with open(os.path.join(lab, f"{i}.json"), "w", encoding="utf-8") as fh:
            json.dump({"version": version, "channel": channel,
                       "reproducible": True,
                       "base": {"release": "26.04"}}, fh)

    script = f"""
        Import-Module '{MODULE.replace("'", "''")}' -Force
        for ($i = 0; $i -lt {len(CASES)}; $i++) {{
            $v = Get-OS7Version -Path (Join-Path '{lab.replace("'", "''")}' "$i.json")
            [Console]::Out.Write("$($v.Short)`t$($v.Full)`n")
        }}
    """
    got = [line.split("\t") for line in run_pwsh(script).replace("\r", "").strip("\n").split("\n")]

    if not check(len(got) == len(CASES), "every case produced a line",
                 f"{len(got)} of {len(CASES)}"):
        return
    for (version, channel, short, full), (gs, gf) in zip(CASES, got):
        check(gs == short, f"{version} ({channel}) -> short", gs)
        check(gf == full, f"{version} ({channel}) -> full", gf)


# ---------------------------------------------------------------------------
# 1b. The rule, in Python — os7version.py
#
# The harnesses' implementation: `run-phase1.py` composes the string it expects
# to find on a framebuffer with it, and `check-image.py` the string it expects
# in an image. Checked FIRST, because if it is wrong every other harness is
# quietly wrong in the same direction and would still pass.
# ---------------------------------------------------------------------------
def python_rule():
    print("\n  the display rule — Python, os7version.py")

    for version, channel, want_short, want_full in CASES:
        check(os7version.short(version, channel) == want_short,
              f"{version} ({channel}) -> short", os7version.short(version, channel))
        check(os7version.full(version, channel) == want_full,
              f"{version} ({channel}) -> full", os7version.full(version, channel))

    check(os7version.product("1.0.0.95", "development") == "OS/7 1.0.0 (development)",
          "the product line is the friendly form with OS/7 in front",
          os7version.product("1.0.0.95", "development"))
    check(os7version.short("", "stable") == "unknown" and os7version.full("", "") == "unknown",
          "no version reads as 'unknown', not as an empty string")


# ---------------------------------------------------------------------------
# 1c. The rule, in shell — build/lib/version-rule.sh
#
# This is the one the IMAGE gets: build.sh applies it and hands the rendered
# strings to hook 0075 through build.conf, which is what becomes PRETTY_NAME,
# /etc/issue and /usr/lib/os7/product. A drift here is a drift on every
# installed machine's login banner.
# ---------------------------------------------------------------------------
def shell_rule(lab):
    print("\n  the display rule — shell, build/lib/version-rule.sh")

    sh = shutil.which("sh") or shutil.which("bash")
    if not sh:
        print("      NOTE  NOT CHECKED: no POSIX shell on this host.")
        return False

    lib = os.path.join(REPO, "build", "lib", "version-rule.sh")
    if not os.path.isfile(lib):
        check(False, "build/lib/version-rule.sh exists", lib)
        return True
    library = open(lib, encoding="utf-8").read()

    # THE LIBRARY AND THE DRIVER BOTH GO IN ON STDIN (`sh -s`). Nothing but the
    # version strings crosses the process boundary, and none of those contains a
    # quote, a backslash or a path.
    #
    # That is not fastidiousness. Three different ways of handing this to a
    # shell were tried on 2026-08-26 and all three broke on Windows, each with
    # an error that named the wrong thing:
    #
    #   `sh -c <program>`   Python quotes the program for the Windows command
    #                       line, the MSYS shell re-parses it with different
    #                       backslash rules, and the `\t` in printf's format
    #                       shifted the quoting until `$1` arrived EMPTY.
    #                       Symptom: `os7_short: command not found` — reads like
    #                       a broken library, was a broken argument.
    #   a script file       the temp path came back as `C:/Users/BASTIA~1/…` and
    #                       the shell could not open an 8.3 short name.
    #   the path as `$1`    depends on WHICH shell got picked. `/usr/bin/sh`
    #                       opens `C:/…` happily; the `bin/bash.exe` wrapper
    #                       that a PowerShell PATH finds instead does not, and
    #                       says "No such file or directory" about a file that
    #                       is plainly there.
    #
    # Reading the library here loses one thing and it is worth naming: this no
    # longer proves the file can be SOURCED, only that the rule inside it is
    # right. build.sh sources it on Linux with a POSIX path, and a build that
    # could not source it would not produce an ISO at all.
    driver = (
        "while [ $# -gt 0 ]; do\n"
        "\tprintf '%s\\t%s\\t%s\\n' \\\n"
        '\t\t"$(os7_short "$1" "$2")" \\\n'
        '\t\t"$(os7_full "$1" "$2")" \\\n'
        '\t\t"$(os7_product "$1" "$2")"\n'
        "\tshift 2\n"
        "done\n"
    )
    program = library + "\n" + driver

    argv = [sh, "-s"]
    for version, channel, _, _ in CASES:
        argv += [version, channel]

    # BYTES, not text=True. Python's text mode wraps the pipe in a TextIOWrapper
    # with newline=None, which translates '\n' to os.linesep ON WRITE — so on
    # Windows the shell received the program with CRLF, `. "$1"` became
    # `. "$1"\r`, and the path it could not open was the library path with a
    # carriage return glued to it. The error names the file and looks like a
    # missing file. Third Windows papercut in this one function; encoding by
    # hand is the end of them.
    p = subprocess.run(argv, input=program.encode("utf-8"), capture_output=True)
    stdout = p.stdout.decode("utf-8", "replace")
    stderr = p.stderr.decode("utf-8", "replace")
    if p.returncode != 0:
        check(False, "version-rule.sh sourced and ran", f"{p.returncode}: {stderr.strip()}")
        return True

    got = [line.split("\t") for line in stdout.replace("\r", "").strip("\n").split("\n")]
    if not check(len(got) == len(CASES), "every case produced a line",
                 f"{len(got)} of {len(CASES)}"):
        return True
    for (version, channel, want_short, want_full), row in zip(CASES, got):
        if not check(len(row) == 3, f"{version}: three fields on the line", "\t".join(row)):
            continue
        check(row[0] == want_short, f"{version} ({channel}) -> short", row[0])
        check(row[1] == want_full, f"{version} ({channel}) -> full", row[1])
        # os7_product is what becomes PRETTY_NAME, /etc/issue and the MOTD line,
        # so it is checked as itself rather than assumed to follow os7_short.
        check(row[2] == f"OS/7 {want_short}",
              f"{version} ({channel}) -> product line", row[2])
    return True


# ---------------------------------------------------------------------------
# 2. The rule, in C# — through `os7-setup --version-rule`
# ---------------------------------------------------------------------------
def csharp_rule(argv):
    """Returns whether it actually RAN. The caller needs to know: the line this
    script ends with is a claim about both halves of the rule, and it must not
    be printed when only one of them was exercised."""
    print("\n  the display rule — C#, through os7-setup --version-rule")

    args = list(argv) + ["--version-rule"] + [f"{v}:{c}" for v, c, _, _ in CASES]
    try:
        p = subprocess.run(args, capture_output=True, text=True)
    except OSError as e:
        # A Linux ELF on a Windows or macOS host is not a failure of the rule,
        # and a red check here would be a wrong answer about a correct program.
        print(f"      NOTE  NOT CHECKED: {e}")
        print("      NOTE  os7-setup is a Linux binary. --docker <image> runs it in a container.")
        return False
    if p.returncode != 0:
        check(False, "os7-setup --version-rule exited 0", f"{p.returncode}: {p.stderr.strip()}")
        return True

    got = [line.split("\t") for line in p.stdout.replace("\r", "").strip("\n").split("\n")]
    if not check(len(got) == len(CASES), "every case produced a line",
                 f"{len(got)} of {len(CASES)}"):
        return True
    for (version, channel, short, full), row in zip(CASES, got):
        if not check(len(row) == 4, f"{version}: four fields on the line", "\t".join(row)):
            continue
        check(row[0] == version and row[1] == channel,
              f"{version} ({channel}) came back as itself", f"{row[0]} / {row[1]}")
        check(row[2] == short, f"{version} ({channel}) -> short", row[2])
        check(row[3] == full, f"{version} ({channel}) -> full", row[3])
    return True


# ---------------------------------------------------------------------------
# 3. The object Get-OS7Version returns
#
# The types are the point of the object. A version an operator cannot compare
# without a string parse is a version reported as prose, and the whole reason
# these are [version] rather than [string] is that `-ge` has to work.
#
# The [version] VOCABULARY COLLISION is checked explicitly, because it is the
# one thing here that silently gives a wrong answer rather than an error:
# [version] calls its third field Build and its fourth Revision, so a caller
# reaching for `.Build` on FullVersion gets OS/7's PATCH.
# ---------------------------------------------------------------------------
def object_shape(lab):
    print("\n  the object")

    manifest = os.path.join(lab, "shape.json")
    with open(manifest, "w", encoding="utf-8") as fh:
        json.dump({"version": "1.0.0.95", "channel": "development",
                   "architecture": "arm64", "reproducible": False,
                   "built": "2026-08-25T19:35:22Z",
                   "source": {"commit": "11dd6765983b", "dirty": True},
                   "base": {"release": "26.04", "codename": "resolute",
                            "archive_snapshot": "20260824T000000Z"},
                   "components": {"kernel": "7.0.0-30-generic"},
                   "packages_manifest": "sha256:deadbeef"}, fh)

    script = f"""
        Import-Module '{MODULE.replace("'", "''")}' -Force
        $v = Get-OS7Version -Path '{manifest.replace("'", "''")}'
        $u = Get-OS7Version -Path '/nonexistent/os7/release.json'
        $d = Get-OS7Version -Path '{manifest.replace("'", "''")}' -Detailed
        @{{
            versionType   = $v.Version.GetType().FullName
            fullType      = $v.FullVersion.GetType().FullName
            version       = [string]$v.Version
            full          = [string]$v.FullVersion
            build         = $v.Build
            buildType     = $v.Build.GetType().FullName
            revision      = $v.FullVersion.Revision
            versionBuild  = $v.FullVersion.Build
            comparesUp    = ($v.Version -ge [version]'1.0.0')
            comparesDown  = ($v.Version -lt [version]'1.1.0')
            builtType     = $v.Built.GetType().FullName
            reproducible  = $v.Reproducible
            known         = $v.Known
            driftIsNull   = ($null -eq $v.Drift)
            typeName      = $v.PSObject.TypeNames[0]
            detailedType  = $d.PSObject.TypeNames[0]
            snapshot      = $d.ArchiveSnapshot
            kernel        = $d.Components.kernel
            plainHasNoSnapshot = ($v.PSObject.Properties.Name -notcontains 'ArchiveSnapshot')
            unknownKnown  = $u.Known
            unknownShort  = $u.Short
            unknownFull   = $u.Full
            unknownVersion= ($null -eq $u.Version)
            unknownDisplay= $u.Display
        }} | ConvertTo-Json -Compress
    """
    o = json.loads(run_pwsh(script).strip())

    check(o["versionType"] == "System.Version", "Version is [version], not a string",
          o["versionType"])
    check(o["fullType"] == "System.Version", "FullVersion is [version]", o["fullType"])
    check(o["version"] == "1.0.0", "Version is the friendly three fields", o["version"])
    check(o["full"] == "1.0.0.95", "FullVersion is all four", o["full"])
    check(o["buildType"] == "System.Int32" and o["build"] == 95,
          "Build is an [int] holding OS/7's fourth field", str(o["build"]))
    check(o["comparesUp"] and o["comparesDown"],
          "Version compares against a [version] without a parse")

    # The collision, asserted rather than described.
    check(o["revision"] == 95,
          "FullVersion.Revision is OS/7's BUILD", str(o["revision"]))
    check(o["versionBuild"] == 0,
          "FullVersion.Build is OS/7's PATCH — the vocabulary collision is real",
          str(o["versionBuild"]))

    check(o["builtType"] == "System.DateTime", "Built is a [datetime]", o["builtType"])
    check(o["reproducible"] is False, "a dirty build says so")
    check(o["known"] is True, "a readable manifest is Known")
    check(o["driftIsNull"], "Drift is null until -CheckDrift, never False")
    check(o["typeName"] == "OS7.Version", "the type name the format file selects on",
          o["typeName"])

    check(o["detailedType"] == "OS7.Version.Detailed",
          "-Detailed stamps a second type so the view changes with it",
          o["detailedType"])
    check(o["snapshot"] == "20260824T000000Z", "-Detailed carries the archive snapshot")
    check(o["kernel"] == "7.0.0-30-generic", "-Detailed carries the bill of materials")
    check(o["plainHasNoSnapshot"], "the plain object does not carry the detail")

    # No manifest must produce an object that SAYS so, not a plausible number.
    check(o["unknownKnown"] is False, "a missing manifest is not Known")
    check(o["unknownVersion"], "a missing manifest has no Version at all — not 0.0.0.0")
    check(o["unknownShort"] == "unknown" and o["unknownFull"] == "unknown",
          "both forms read 'unknown'", f'{o["unknownShort"]} / {o["unknownFull"]}')
    check("no release manifest" in o["unknownDisplay"],
          "and the display line says where it looked", o["unknownDisplay"])


# ---------------------------------------------------------------------------
# 4. Drift
#
# The package list is HANDED IN rather than produced by a fake dpkg-query on
# PATH. Two reasons, and the second is the better one:
#
#   * a fake binary is a per-platform shim — a shell script here, a .cmd there —
#     and the .cmd route does not work: PowerShell runs it, its output reaches
#     the console instead of the pipeline, and $LASTEXITCODE is left unset
#     (measured 2026-08-26). That is a Windows quirk this check has no business
#     modelling, and chasing it would have tested cmd.exe rather than OS/7.
#   * the seam that matters is not the invocation. `dpkg-query -W -f=…` is one
#     line and a real machine exercises it. What can be SILENTLY wrong is
#     everything after it, and all of that is on this side of the seam.
#
# The two ways the comparison can be silently wrong are both in the reader:
#
#   * THE SORT. hook 0075 uses `LC_ALL=C sort`, which is BYTE order.
#     Sort-Object is culture-aware even with -CaseSensitive, so a culture that
#     files 'a' before 'B' produces a different file, a different hash, and a
#     drift report caused entirely by the reader. The list below is handed over
#     SHUFFLED and contains a capitalised name, so a culture-aware sort gives a
#     different answer from a byte sort and this notices.
#   * THE TRAILING NEWLINE. `sort` writes one after the last line; a join that
#     does not add it hashes differently from an identical package set.
#
# The expected hash is computed HERE, from the specification, rather than taken
# from the module — a module agreeing with itself is not evidence.
# ---------------------------------------------------------------------------
PACKAGES = [
    ("Zzz-capital", "1.0", "all"),      # sorts BEFORE lowercase in byte order
    ("apt", "2.9.30", "arm64"),
    ("bash", "5.2.37-1", "arm64"),
    ("linux-image-generic", "7.0.0.30.31", "arm64"),
    ("zfsutils-linux", "2.4.1-1ubuntu5", "arm64"),
]


def manifest_text(packages):
    """What hook 0075 writes: package<TAB>version<TAB>arch, byte-sorted, and a
    newline after the last line. Python's sort is by code point, which is the
    same order `LC_ALL=C sort` produces for this ASCII."""
    return "\n".join(sorted(f"{n}\t{v}\t{a}" for n, v, a in packages)) + "\n"


def ps_list(packages):
    """The lines in DELIBERATELY WRONG ORDER — reversed — so that a module which
    forgot to sort, or sorted the wrong way, cannot match the hash by luck."""
    lines = list(reversed([f"{n}\t{v}\t{a}" for n, v, a in packages]))
    return "@(" + ",".join("'" + line.replace("'", "''") + "'" for line in lines) + ")"


def drift(lab):
    print("\n  drift")

    root = os.path.join(lab, "drift")
    os.makedirs(root, exist_ok=True)

    recorded = manifest_text(PACKAGES)
    digest = "sha256:" + hashlib.sha256(recorded.encode("utf-8")).hexdigest()

    shipped = os.path.join(root, "packages.manifest")
    with open(shipped, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(recorded)

    def ask(packages_manifest, installed=PACKAGES):
        script = f"""
            Import-Module '{MODULE.replace("'", "''")}' -Force
            $d = & (Get-Module OS7) {{
                Get-OS7PackageDrift -Recorded '{packages_manifest}' `
                    -ManifestPath '{shipped.replace("'", "''")}' `
                    -Installed {ps_list(installed)}
            }}
            $d | Select-Object State, Packages, Differences, Added, Removed, Changed,
                                Installed, Recorded, Note |
                ConvertTo-Json -Compress -Depth 4
        """
        return json.loads(run_pwsh(script).strip())

    # A machine that holds exactly what the release recorded.
    d = ask(digest)
    check(d["State"] == "Clean", "an unchanged machine is Clean", d["State"])
    check(d["Packages"] == len(PACKAGES), "every package was counted", str(d["Packages"]))
    check(d["Installed"] == digest,
          "the hash matches one computed independently, from a shuffled list",
          d["Installed"] or "")
    check(d["Differences"] == 0, "and nothing differs")

    # One package moved. This is the case §5 exists for and the case
    # `dpkg --get-selections` structurally cannot see (BUILD-NOTES #37).
    moved = [(n, "7.0.0.31.32" if n == "linux-image-generic" else v, a)
             for n, v, a in PACKAGES]
    d = ask(digest, installed=moved)
    check(d["State"] == "Drifted", "a moved package version is Drifted", d["State"])
    check(d["Differences"] == 1, "exactly one difference", str(d["Differences"]))
    changed = d["Changed"] if isinstance(d["Changed"], list) else [d["Changed"]]
    check(any("linux-image-generic" in str(c) and "7.0.0.31.32" in str(c) for c in changed),
          "and it names the package and both versions", "; ".join(map(str, changed)))

    # A package that is there and was not. An installed machine really is in
    # this state — Phase 3 adds azcmagent after the image was measured — so
    # "Drifted" has to be reportable as a LIST and not only as a verdict.
    d = ask(digest, installed=PACKAGES + [("azcmagent", "1.62", "arm64")])
    added_list = d["Added"] if isinstance(d["Added"], list) else [d["Added"]]
    check(d["State"] == "Drifted" and "azcmagent" in added_list,
          "an extra package is named as Added", "; ".join(map(str, added_list)))

    # A package that was there and is not.
    d = ask(digest, installed=[p for p in PACKAGES if p[0] != "bash"])
    removed_list = d["Removed"] if isinstance(d["Removed"], list) else [d["Removed"]]
    check(d["State"] == "Drifted" and "bash" in removed_list,
          "a missing package is named as Removed", "; ".join(map(str, removed_list)))

    # THE THIRD OUTCOME. No recorded hash is not a clean machine.
    d = ask("")
    check(d["State"] == "Unknown",
          "no recorded hash reads as Unknown, never Clean", d["State"])
    check(bool(d["Note"]), "and it says why", d["Note"] or "")


def find_setup(explicit):
    for candidate in (explicit, os.environ.get("OS7_SETUP"),
                      os.path.join(REPO, "out", "os7-setup")):
        if candidate and os.path.isfile(candidate):
            return candidate
    return None


def setup_argv(setup, image):
    """How to invoke os7-setup: directly, or through a container.

    The container route is not a convenience. os7-setup is a Linux binary and
    this repository is developed from a Mac and a Windows box, so without it the
    C# half of the rule is unrunnable on the machine where the rule is usually
    being edited — and an unrunnable check is one that reports NOT CHECKED
    forever, which is how a specification quietly becomes two.
    """
    if not image:
        return [setup]
    rel = os.path.relpath(os.path.abspath(setup), REPO).replace(os.sep, "/")
    if rel.startswith(".."):
        sys.exit(f"--docker needs an os7-setup inside the repository; {setup} is not.")
    argv = ["docker", "run", "--rm"]
    # Only when the tag says so. Passing --platform unconditionally would force
    # emulation on a host that already matches the image.
    tag = image.rsplit(":", 1)[-1]
    if tag in ("amd64", "arm64"):
        argv += ["--platform", f"linux/{tag}"]
    return argv + ["-v", f"{REPO}:/work", image, f"/work/{rel}"]


def main():
    ap = argparse.ArgumentParser(description="the version display rule, both languages")
    ap.add_argument("--setup", help="a runnable os7-setup, for the C# half")
    ap.add_argument("--docker", metavar="IMAGE",
                    help="run os7-setup in this image (e.g. os7-build:arm64), for a "
                         "host that cannot execute a Linux binary")
    args = ap.parse_args()

    print("### the version display rule (docs/IDENTITY-PLAN.md §5)")
    lab = tempfile.mkdtemp(prefix="os7-version-rule-")
    ran = []
    try:
        python_rule();            ran.append("Python")
        powershell_rule(lab);     ran.append("PowerShell")
        object_shape(lab)
        drift(lab)
        if shell_rule(lab):
            ran.append("shell")

        setup = find_setup(args.setup)
        if setup:
            if csharp_rule(setup_argv(setup, args.docker)):
                ran.append("C#")
        else:
            print("\n  the display rule — C#")
            print("      NOTE  NOT CHECKED. No os7-setup was found.")
            print("      NOTE  Pass --setup <path>, or set OS7_SETUP, or drop one in out/.")
        if "C#" not in ran:
            print("      NOTE  Build one with the container one-liner in CLAUDE.md, then either")
            print("      NOTE  run this on Linux or add --docker os7-build:<arch>.")
            print("      NOTE  `os7-setup --self-test` checks the C# side on its own, and runs")
            print("      NOTE  in the chroot during every ISO build (hook 0080) — so it is")
            print("      NOTE  never unchecked, only unCOMPARED.")
    finally:
        if os.environ.get("VERSION_RULE_KEEP"):
            print(f"\n(kept: {lab})")
        else:
            shutil.rmtree(lab, ignore_errors=True)

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    # Name what actually ran. "All four agree" and "the two that could run agree"
    # are different claims, and only one of them is ever earned in a given run.
    missing = [n for n in ("Python", "PowerShell", "shell", "C#") if n not in ran]
    print(f"all checks passed — {', '.join(ran)} produce the same strings for the same cases.")
    if missing:
        print(f"NOT COMPARED IN THIS RUN: {', '.join(missing)}. The rule has "
              f"{len(ran) + len(missing)} implementations and this run exercised {len(ran)}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
