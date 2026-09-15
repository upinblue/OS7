#!/usr/bin/env python3
"""
What OS/7's GUI applications are allowed to reach, and the decisions they make.
No VM, no machine, no display.

    ./check-gui-logic.py                            # the layer rules, seconds
    ./check-gui-logic.py --docker os7-build:amd64   # and each app's self-test
    ./check-gui-logic.py --self-test                # prove the rules FIRE

WHY IT EXISTS. docs/GUI-APPS-PLAN.md G3: an OS/7 application decides nothing a
cmdlet has not already decided. `Update-OS7` is RELEASE-AND-UPDATE-PLAN §4.2 as
C10 corrects it, and a C# re-implementation of any part of it would be a THIRD
language for one specification — BUILD-NOTES #66's shape, and the one P3 is
spending two steps deleting from the netplan renderer.

CAPABILITIES ARE DECLARED PER PROJECT, NOT FORBIDDEN GLOBALLY, and that is
docs/VERSIONS-PLAN.md V10. The first version of this file said no application
may touch the filesystem, which was right for Software Update and wrong the
moment Versions existed — a file-history window whose subject IS the filesystem.
A blanket rule with a quiet exception carved into it stops meaning anything, so
each project states what it may reach and WHY, the default is nothing, and the
grant is as narrow as the file list that needs it.

WHAT NO RULE HERE CHECKS: anything about how a window LOOKS. None is
constructed. O-G1 was answered by a machine and O-V1 by a machine, not by this.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SRC = os.environ.get("OS7_SCAN_ROOT", os.path.join(REPO, "src"))

# ---------------------------------------------------------------------------
# WHAT EACH PROJECT MAY REACH. The default is nothing; every grant names the
# files it applies to and the reason it exists.
# ---------------------------------------------------------------------------
CAPABILITIES = {
    "OS7.Shell": {
        "why": "the one way an application reaches the PowerShell surface (G4)",
        "start_process": ["PowerShellRunner.cs"],
        "open_files": [],
    },
    "OS7.Ui": {
        "why": "the design system: control themes and one drawing primitive",
        "start_process": [],
        "open_files": [],
    },
    "OS7.App.SoftwareUpdate": {
        "why": "a front-end over Get-OS7Release and a systemd unit; it has no "
               "business touching a file",
        "start_process": [],
        "open_files": [],
    },
    "OS7.App.Versions": {
        "why": "it shows a file's contents, and that means reading them "
               "(VERSIONS-PLAN V10). WHICH versions exist and which are worth "
               "showing is Get-OS7FileVersion's, not this application's — the "
               "grant shrank from four files to two when that moved",
        "start_process": [],
        "open_files": [
            "Services/TextPreview.cs",    # the contents of one old version
            "Views/MainWindow.axaml.cs",  # Copy to… writes the copy
        ],
    },
}

# Programs an OS/7 application must reach through the PowerShell surface rather
# than run itself. `pwsh` is deliberately absent: it IS the surface.
FORBIDDEN_PROGRAMS = (
    "systemctl", "journalctl", "zfs", "zpool", "apt-get", "apt ", "dpkg",
    "pkexec", "sudo", "chroot", "cryptsetup", "grub-", "update-initramfs",
)

FILE_ACCESS = re.compile(
    r"\b(File|Directory|FileStream|StreamReader|StreamWriter|FileInfo|DirectoryInfo)\s*\.")

PROCESS_START = re.compile(r"\bnew\s+Process\b|\bProcess\s*\.\s*Start\b")

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def strip_comments(path, text):
    """Blank out comments, keeping line numbers. See check-gui-tokens.py."""
    def blank(match):
        return re.sub(r"[^\n]", " ", match.group(0))

    if path.endswith(".axaml"):
        return re.sub(r"<!--.*?-->", blank, text, flags=re.S)

    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.S)
    text = re.sub(r"///[^\n]*", blank, text)
    return re.sub(r"//[^\n]*", blank, text)


def projects(scan_root):
    """Every project directory under the scan root, in order."""
    if not os.path.isdir(scan_root):
        return []
    return sorted(
        name for name in os.listdir(scan_root)
        if os.path.isdir(os.path.join(scan_root, name)))


def source_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("bin", "obj")]
        for name in sorted(filenames):
            if name.endswith((".cs", ".axaml")):
                yield os.path.join(dirpath, name)


def granted(project, capability, relative):
    """Whether this file holds this capability."""
    grants = CAPABILITIES.get(project)
    if grants is None:
        return False
    allowed = grants.get(capability, [])
    return any(relative.replace(os.sep, "/").endswith(a) for a in allowed)


def can_invoke(text):
    """
    Whether this file is able to run anything at all.

    The forbidden-program scan applies HERE and nowhere else, which is what
    makes the rule about the action rather than the word: ReleaseRow.cs contains
    `sudo pwsh -c 'Update-OS7 …'` because that is the sentence #148 requires a
    refusal to carry, and flagging it would mean the fix is to stop telling
    operators the command that works.
    """
    return ("RunAsync(" in text or "ProcessStartInfo" in text or "Process.Start" in text)


def layer_rules(scan_root):
    print("  1. Every project reaches only what it has declared")

    found = projects(scan_root)
    undeclared = [p for p in found if p not in CAPABILITIES]
    check(not undeclared,
          "every project under src/ declares its capabilities",
          ", ".join(undeclared) if undeclared else ", ".join(found))

    programs, files, processes = [], [], []

    for project in found:
        root = os.path.join(scan_root, project)

        for path in source_files(root):
            relative = os.path.relpath(path, root)
            text = strip_comments(path, read(path))

            if can_invoke(text):
                for program in FORBIDDEN_PROGRAMS:
                    if program in text:
                        programs.append(f"{project}/{relative} names {program.strip()}")

            for number, line in enumerate(text.splitlines(), start=1):
                if FILE_ACCESS.search(line) and not granted(project, "open_files", relative):
                    files.append(f"{project}/{relative}:{number}")

                if PROCESS_START.search(line) and not granted(project, "start_process", relative):
                    processes.append(f"{project}/{relative}:{number}")

    check(not programs,
          "nothing that can invoke anything names systemctl, zfs, apt or their kind",
          "; ".join(programs[:4]) if programs else "")

    check(not files,
          "no file is opened outside a project that declared it may",
          "; ".join(files[:4]) if files else "")

    check(not processes,
          "no process is started outside a project that declared it may",
          "; ".join(processes[:4]) if processes else "")

    # The grant is only as good as its narrowness: a project that declared
    # everything would pass the rules above and mean nothing.
    for project, grants in sorted(CAPABILITIES.items()):
        total = len(grants.get("open_files", [])) + len(grants.get("start_process", []))
        if total:
            check(total <= 6,
                  f"{project}'s grant is still narrow — {grants['why']}",
                  f"{total} file(s)")


def no_handwritten_initialize(scan_root):
    print()
    print("  2. No view hand-writes InitializeComponent")

    # BUILD-NOTES #152. Avalonia GENERATES InitializeComponent() for a partial
    # class with a matching .axaml, and the generated one loads the XAML AND
    # assigns every x:Name'd control to its field. A hand-written one compiles,
    # shadows it, does the first half, and leaves every field null — so the
    # window dies in its constructor and an operator sees a menu entry that does
    # nothing. Green build, green self-test, green layer rules.
    handwritten = []
    for path in source_files(scan_root):
        if not path.endswith(".cs") or not os.path.exists(path[: -len(".cs")]):
            continue
        text = strip_comments(path, read(path))
        for number, line in enumerate(text.splitlines(), start=1):
            if re.search(r"\bvoid\s+InitializeComponent\s*\(", line):
                handwritten.append(f"{os.path.relpath(path, scan_root)}:{number}")

    check(not handwritten,
          "InitializeComponent is left to the generator, which is what assigns the fields",
          "; ".join(handwritten) if handwritten else "")


def surface_rules(scan_root):
    print()
    print("  3. The surface they reach is the OS7, Zfs and Systemd modules")

    def at(*parts):
        return os.path.join(scan_root, *parts)

    shell = at("OS7.Shell", "PowerShellRunner.cs")
    if os.path.exists(shell):
        text = read(shell)
        check("-NonInteractive" in text and "-NoProfile" in text,
              "pwsh is invoked non-interactively and without a profile")
        check("ArgumentList" in text,
              "arguments are passed as a list, never as one command line")
        # The two things a machine taught, which a second copy would forget.
        check("PSStyle" in text and "PlainText" in text,
              "PowerShell is told to render plain text, so no ANSI reaches a window")
        check("x1B" in text or "1B" in text,
              "and the escapes are stripped anyway, for a pwsh that ignores it")
    else:
        check(False, "OS7.Shell/PowerShellRunner.cs is where it is expected", shell)

    cli = at("OS7.App.SoftwareUpdate", "Services", "Os7Cli.cs")
    if os.path.exists(cli):
        check("Get-OS7Release" in read(cli), "releases come from Get-OS7Release")
    else:
        check(False, "Os7Cli.cs is where it is expected", cli)

    runner = at("OS7.App.SoftwareUpdate", "Services", "UpdateRunner.cs")
    if os.path.exists(runner):
        text = read(runner)
        check("Start-SystemdUnit" in text,
              "the update is started through Start-SystemdUnit, so polkit is reached")
        check("Update-OS7" not in strip_comments(runner, text),
              "the application never invokes Update-OS7 itself; the unit does")
    else:
        check(False, "UpdateRunner.cs is where it is expected", runner)

    loader = at("OS7.App.Versions", "Services", "VersionLoader.cs")
    if os.path.exists(loader):
        text = read(loader)
        check("Get-OS7FileVersion" in text,
              "the versions come from Get-OS7FileVersion, not from the app's own walk")
        # The boundary the owner asked to keep, and the collapsing that stops
        # 45 snapshots being 45 rows. Both are the cmdlet's to decide.
        check("-IncludeAbsent" in text and "-DistinctOnly" in text,
              "and it asks for the boundary and the collapsing rather than doing them")
        check("@'" in text,
              "a path reaches PowerShell inside a here-string, never as syntax")
        # What must NOT be here any more.
        stripped = strip_comments(loader, text)
        check("mountinfo" not in stripped and "Get-ZfsSnapshot" not in stripped,
              "and it no longer resolves datasets or reads snapshot times itself")

    else:
        check(False, "VersionLoader.cs is where it is expected", loader)

    # V9/V19. The window gained its first destructive verb on 2026-09-15, and
    # the rule that matters is that it did NOT gain the work behind it: no
    # copy, no rename, no snapshot, no zfs.
    versions = "".join(
        read(f) for f in source_files(at("OS7.App.Versions"))
        if os.path.exists(f))
    check("Restore-OS7File" in versions,
          "restoring is the cmdlet's, so ssh and the window behave identically")
    check("-Confirm:$false" in versions and "-Force" in versions,
          "and the window supplies both switches itself, having already asked "
          "the operator in a dialog it could show them")
    for forbidden, why in [
        ("Move-Item", "the file moved aside is Restore-OS7File's decision (V19)"),
        ("New-ZfsSnapshot", "so is the snapshot in front of it (V8)"),
        ("File.Copy(version.Path", "and nothing here writes over a live file"),
    ]:
        check(forbidden not in versions,
              f"the window never does it itself — {why}")


def refusal_rules(scan_root):
    print()
    print("  4. What they REFUSE, they refuse the way the rest of the product does")

    row = os.path.join(scan_root, "OS7.App.SoftwareUpdate", "ViewModels", "ReleaseRow.cs")
    if os.path.exists(row):
        text = strip_comments(row, read(row))
        # BUILD-NOTES #148: a refusal names the command that would work.
        check("sudo pwsh -c" in text,
              "a development release is refused with the sudo pwsh -c form #148 requires")
        check("-AllowDevelopment" in text, "and the switch that would work is named")
    else:
        check(False, "ReleaseRow.cs is where it is expected", row)

    app = os.path.join(scan_root, "OS7.App.Versions", "App.axaml.cs")
    if os.path.exists(app):
        text = strip_comments(app, read(app))
        # V6: an empty list means "nothing changed" and no-history means
        # "nothing is being kept". Those are opposite facts, and the cmdlet
        # has a sentence for each — the window must pass it through rather
        # than collapse them into "no versions found".
        check("result.Error" in text and "model.Message" in text,
              "the cmdlet's own refusal reaches the window unaltered (V6)")
        check("NoHistory" in text,
              "and 'nothing is kept' stays a different state from 'it failed'")
    else:
        check(False, "App.axaml.cs is where it is expected", app)


def app_self_tests(image):
    print()
    print(f"  5. Each application's own decisions, in {image}")

    for project, binary in (
        ("OS7.App.SoftwareUpdate", "os7-software-update"),
        ("OS7.App.Versions", "os7-versions"),
    ):
        command = (
            f"cd /work/src/{project} && "
            "dotnet build -c Release -v quiet --nologo >/dev/null 2>&1 && "
            f"cd bin/Release/net10.0/linux-x64 && ./{binary} --self-test"
        )

        result = subprocess.run(
            ["docker", "run", "--rm", "-v", f"{REPO}:/work", image, "bash", "-c", command],
            capture_output=True, text=True)

        tail = [l for l in result.stderr.splitlines() if l.strip()][-1:]
        check(result.returncode == 0,
              f"{binary} --self-test passes",
              "; ".join(tail) if tail else f"exit {result.returncode}")


def self_test():
    """Plant defects and require the rules to catch each one."""
    print("OS/7 GUI logic — do the rules FIRE?")
    print()

    results = []
    work = tempfile.mkdtemp(prefix="os7-gui-logic-")
    try:
        planted = os.path.join(work, "src")
        shutil.copytree(os.path.join(REPO, "src"), planted,
                        ignore=shutil.ignore_patterns("bin", "obj"))

        def run_planted():
            return subprocess.run(
                [sys.executable, os.path.abspath(__file__)],
                env={**os.environ, "OS7_SCAN_ROOT": planted},
                capture_output=True, text=True).returncode

        def plant(path, needle, injected, what):
            target = os.path.join(planted, *path)
            original = read(target)
            assert needle in original, f"the planting anchor is gone: {needle}"
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(original.replace(needle, injected + "\n" + needle, 1))
            results.append((what, run_planted() != 0))
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(original)

        # A project WITHOUT the grant opening a file.
        plant(("OS7.App.SoftwareUpdate", "Services", "Os7Cli.cs"),
              "\t\tvar result = await _shell.RunAsync",
              '\t\tFile.ReadAllText("/etc/passwd");',
              "opening a file where it was not granted is caught")

        # A project WITHOUT the grant starting a process.
        plant(("OS7.App.Versions", "Services", "VersionLoader.cs"),
              "\t\tvar result = await _shell.RunAsync",
              '\t\tSystem.Diagnostics.Process.Start("zfs", "list");',
              "starting a process where it was not granted is caught")

        # BUILD-NOTES #152, planted where it actually happened.
        view = os.path.join(planted, "OS7.App.Versions", "Views", "MainWindow.axaml.cs")
        original = read(view)
        anchor = "\t\tInitializeComponent();"
        assert anchor in original, "the view's planting anchor is gone"
        with open(view, "w", encoding="utf-8") as handle:
            handle.write(original.replace(
                anchor,
                anchor + "\n\t}\n\n\tprivate void InitializeComponent() "
                         "=> AvaloniaXamlLoader.Load(this);\n\n\tprivate void Unused() {",
                1))
        results.append(("a hand-written InitializeComponent is caught (#152)", run_planted() != 0))
        with open(view, "w", encoding="utf-8") as handle:
            handle.write(original)

        # A project nobody declared.
        os.makedirs(os.path.join(planted, "OS7.App.Undeclared"))
        with open(os.path.join(planted, "OS7.App.Undeclared", "X.cs"), "w",
                  encoding="utf-8") as handle:
            handle.write("public class X { }\n")
        results.append(("a project with no declared capabilities is caught", run_planted() != 0))
        shutil.rmtree(os.path.join(planted, "OS7.App.Undeclared"))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    for what, ok in results:
        print(f"      {'ok  ' if ok else 'FAIL'}  {what}")

    bad = [what for what, ok in results if not ok]
    print()
    print(f"  {len(results) - len(bad)} ok, {len(bad)} failed")
    return 1 if bad else 0


def main():
    if "--self-test" in sys.argv:
        return self_test()

    image = None
    if "--docker" in sys.argv:
        image = sys.argv[sys.argv.index("--docker") + 1]

    print("OS/7 GUI applications — what they may reach, and what they decide")
    print()

    layer_rules(SRC)
    no_handwritten_initialize(SRC)
    surface_rules(SRC)
    refusal_rules(SRC)

    if image:
        app_self_tests(image)
    else:
        print()
        print("  5. The applications' own decisions: NOT CHECKED")
        print("     (pass --docker os7-build:amd64 — they need .NET)")

    print()
    if FAILS:
        print(f"  FAILED: {len(FAILS)}")
        for failure in FAILS:
            print(f"    {failure}")
        return 1

    print("  all ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
