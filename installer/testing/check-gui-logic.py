#!/usr/bin/env python3
"""
The Software Update application's DECISIONS, and the layer it is not allowed to
reach through. No VM, no machine, no display.

    ./check-gui-logic.py                      # the layer rule alone, seconds
    ./check-gui-logic.py --docker os7-build:amd64   # and the app's own self-test
    ./check-gui-logic.py --self-test          # prove the layer rule FIRES

WHY IT EXISTS. docs/GUI-APPS-PLAN.md G3: an OS/7 application decides nothing a
cmdlet has not already decided. `Update-OS7` is RELEASE-AND-UPDATE-PLAN §4.2 as
C10 corrects it - the clone, both repositories, the metapackage, the migrations,
the initramfs, the menu, the driver gate, the activation, the pruning - and a
C# re-implementation of any part of it would be a THIRD language for one
specification. That is BUILD-NOTES #66's shape, and P3 is currently spending two
steps deleting its second occurrence.

TWO HALVES, AND THEY ARE DIFFERENT KINDS OF CHECK.

  The LAYER rule, here: the application may start no process but `pwsh`, may
  touch no file, and may not name `systemctl`, `zfs`, `apt` or their kind. It is
  checked on the SOURCE and needs nothing installed. Note what it is NOT: it
  does not forbid MENTIONING a path in a sentence an operator reads -
  "/var/log/os7/update.log has the whole run" is the most useful half of an
  error message. It forbids OPENING one. The rule is about the action.

  The DECISIONS, in the application's own `--self-test`, the way
  `os7-setup --self-test` works: which sentence a blocked release gets, that
  Development is not part of Applicable, that versions sort as versions, that
  the button counts what it will do. That half needs .NET and therefore Docker.
  It found a real defect the first time it ran - .NET's `$` matches before a
  trailing newline, so a version could have carried one into a systemd unit
  name (BUILD-NOTES #151).

WHAT NEITHER HALF CHECKS: anything about how the window LOOKS. No window is
constructed by either. O-G1 is owed and nothing here narrows it.
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

# The one file allowed to start a process, because it is the surface (G4).
CLI_FILE = os.path.join("OS7.App.SoftwareUpdate", "Services", "Os7Cli.cs")

# Programs an OS/7 application must reach through the PowerShell surface rather
# than run itself. `pwsh` is deliberately absent: it IS the surface.
FORBIDDEN_PROGRAMS = (
    "systemctl", "journalctl", "zfs", "zpool", "apt-get", "apt ", "dpkg",
    "pkexec", "sudo", "chroot", "cryptsetup", "grub-", "update-initramfs",
)

# Reaching the filesystem at all. The application has no business doing it.
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


def source_files(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("bin", "obj")]
        for name in sorted(filenames):
            if name.endswith((".cs", ".axaml")):
                yield os.path.join(dirpath, name)


def can_invoke(path, text):
    """
    Whether this file is able to run anything at all.

    The forbidden-program scan applies HERE and nowhere else, and that is not a
    loophole - it is what makes the rule about the action rather than the word.
    ReleaseRow.cs contains the string `sudo pwsh -c 'Update-OS7 ...'` because
    that is the sentence an operator reads when a release is not signed for
    production, and it is the same form BUILD-NOTES #148 requires every refusal
    to carry. Flagging it would mean the fix is to stop telling operators how to
    do the thing, which makes the product worse to satisfy a grep.

    Soundness comes from the OTHER rule: only Os7Cli.cs may start a process. So
    the set of files that can invoke anything is small, computed rather than
    listed, and grows only when somebody adds a call - at which point this scan
    reaches the new file automatically.
    """
    return ("RunScriptAsync(" in text
            or "ProcessStartInfo" in text
            or "Process.Start" in text)


def layer_rule(scan_root):
    print("  1. The application reaches the machine only through PowerShell")

    programs = []
    files = []
    processes = []
    invokers = []

    for path in source_files(scan_root):
        relative = os.path.relpath(path, scan_root)
        text = strip_comments(path, read(path))
        invoking = can_invoke(path, text)

        if invoking:
            invokers.append(relative)

        for number, line in enumerate(text.splitlines(), start=1):
            if invoking:
                for program in FORBIDDEN_PROGRAMS:
                    if program in line:
                        programs.append(f"{relative}:{number} {program.strip()}")

            if FILE_ACCESS.search(line):
                files.append(f"{relative}:{number} {FILE_ACCESS.search(line).group(0)}")

            if PROCESS_START.search(line) and relative != CLI_FILE:
                processes.append(f"{relative}:{number}")

    check(not programs,
          "no file that can invoke anything names systemctl, zfs, apt or their kind",
          "; ".join(programs[:4]) if programs else "")

    check(len(invokers) <= 2,
          "the set of files that can invoke anything is still small",
          ", ".join(sorted(invokers)))

    check(not files,
          "no application file opens a file",
          "; ".join(files[:4]) if files else "")

    check(not processes,
          f"only {CLI_FILE} starts a process",
          "; ".join(processes[:4]) if processes else "")

    print()
    print("  2. No view hand-writes InitializeComponent")

    # BUILD-NOTES #152. Avalonia GENERATES InitializeComponent() for a partial
    # class with a matching .axaml, and that generated method does two things:
    # loads the XAML and assigns every x:Name'd control to its field. A
    # hand-written
    #
    #     private void InitializeComponent() => AvaloniaXamlLoader.Load(this);
    #
    # compiles, shadows it, does the first half and not the second. The fields
    # stay null, the constructor throws NullReferenceException, and the
    # application dies before a window exists — with a green build, a green
    # self-test, and nothing visible to an operator but a menu entry that does
    # nothing. It cost a machine run to find; it costs a grep to prevent.
    handwritten = []
    for path in source_files(scan_root):
        if not path.endswith(".cs"):
            continue
        # Only files that ARE a XAML code-behind: App.axaml.cs legitimately
        # overrides Initialize(), which is a different method entirely.
        if not os.path.exists(path[: -len(".cs")]):
            continue
        text = strip_comments(path, read(path))
        for number, line in enumerate(text.splitlines(), start=1):
            if re.search(r"\bvoid\s+InitializeComponent\s*\(", line):
                handwritten.append(f"{os.path.relpath(path, scan_root)}:{number}")

    check(not handwritten,
          "InitializeComponent is left to the generator, which is what assigns the fields",
          "; ".join(handwritten) if handwritten else "")

    print()
    print("  3. The surface it does reach is the OS7 and Systemd modules")

    cli = os.path.join(scan_root, CLI_FILE)
    runner = os.path.join(scan_root, "OS7.App.SoftwareUpdate", "Services", "UpdateRunner.cs")

    if os.path.exists(cli):
        text = read(cli)
        check("Get-OS7Release" in text, "releases come from Get-OS7Release")
        check("-NonInteractive" in text and "-NoProfile" in text,
              "pwsh is invoked non-interactively and without a profile")
        check("ArgumentList" in text,
              "arguments are passed as a list, never as one command line")
    else:
        check(False, "Os7Cli.cs is where it is expected", cli)

    if os.path.exists(runner):
        text = read(runner)
        check("Start-SystemdUnit" in text,
              "the update is started through Start-SystemdUnit, so polkit is reached")
        check("Update-OS7" not in strip_comments(runner, text),
              "the application never invokes Update-OS7 itself; the unit does")
    else:
        check(False, "UpdateRunner.cs is where it is expected", runner)

    print()
    print("  4. What it REFUSES, it refuses the way the rest of the product does")

    row = os.path.join(scan_root, "OS7.App.SoftwareUpdate", "ViewModels", "ReleaseRow.cs")
    if os.path.exists(row):
        text = strip_comments(row, read(row))
        # BUILD-NOTES #148: a refusal names the command that would work. The
        # window has no -AllowDevelopment of its own on purpose - the switch
        # exists so an operator says out loud that they are installing
        # something of unknown provenance, and a checkbox is not that sentence.
        check("sudo pwsh -c" in text,
              "a development release is refused with the sudo pwsh -c form #148 requires")
        check("-AllowDevelopment" in text,
              "and the switch that would work is named")
    else:
        check(False, "ReleaseRow.cs is where it is expected", row)


def app_self_test(image):
    print()
    print(f"  5. The application's own decisions, in {image}")

    command = (
        "cd /work/src/OS7.App.SoftwareUpdate && "
        "dotnet build -c Release -v quiet --nologo >/dev/null 2>&1 && "
        "cd bin/Release/net10.0/linux-x64 && ./os7-software-update --self-test"
    )

    result = subprocess.run(
        ["docker", "run", "--rm", "-v", f"{REPO}:/work", image, "bash", "-c", command],
        capture_output=True, text=True)

    # The application prints its own PASS/FAIL lines to stderr; they are this
    # check's output too, indented under it rather than summarised away.
    for line in result.stderr.splitlines():
        if line.strip():
            print(f"    {line}")

    check(result.returncode == 0,
          "os7-software-update --self-test passes",
          f"exit {result.returncode}")


def self_test():
    """Plant defects and require the layer rule to catch each one."""
    print("OS/7 GUI logic — does the layer rule FIRE?")
    print()

    plants = [
        ("a direct systemctl call is caught",
         ("await _cli.RunScriptAsync(script, ct)",
          'System.Diagnostics.Process.Start("systemctl", "start x");')),
        ("opening a file is caught",
         ("await _cli.RunScriptAsync(script, ct)",
          'File.ReadAllText("/var/log/os7/update.log");')),
    ]

    results = []
    work = tempfile.mkdtemp(prefix="os7-gui-logic-")
    try:
        planted = os.path.join(work, "src")
        shutil.copytree(os.path.join(REPO, "src"), planted,
                        ignore=shutil.ignore_patterns("bin", "obj"))

        target = os.path.join(planted, "OS7.App.SoftwareUpdate", "Services", "UpdateRunner.cs")
        original = read(target)

        for what, (needle, injected) in plants:
            assert needle in original, f"the planting anchor is gone: {needle}"
            with open(target, "w", encoding="utf-8") as handle:
                handle.write(original.replace(needle, injected + " " + needle, 1))

            code = subprocess.run(
                [sys.executable, os.path.abspath(__file__)],
                env={**os.environ, "OS7_SCAN_ROOT": planted},
                capture_output=True, text=True).returncode
            results.append((what, code != 0))

        with open(target, "w", encoding="utf-8") as handle:
            handle.write(original)

        # BUILD-NOTES #152, planted where it actually happened: a view writing
        # its own InitializeComponent. This is the defect that cost a machine
        # run, so the rule that replaces that machine run has to be shown to
        # catch it.
        view = os.path.join(planted, "OS7.App.SoftwareUpdate", "Views", "MainWindow.axaml.cs")
        view_original = read(view)
        anchor = "\t\tInitializeComponent();"
        assert anchor in view_original, "the view's planting anchor is gone"

        with open(view, "w", encoding="utf-8") as handle:
            handle.write(view_original.replace(
                anchor,
                anchor + "\n\t}\n\n\tprivate void InitializeComponent() "
                         "=> AvaloniaXamlLoader.Load(this);\n\n\tprivate void Unused() {",
                1))

        code = subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            env={**os.environ, "OS7_SCAN_ROOT": planted},
            capture_output=True, text=True).returncode
        results.append(("a hand-written InitializeComponent is caught (#152)", code != 0))

        with open(view, "w", encoding="utf-8") as handle:
            handle.write(view_original)
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

    print("OS/7 Software Update — the decisions and the layer")
    print()

    layer_rule(SRC)

    if image:
        app_self_test(image)
    else:
        print()
        print("  5. The application's own decisions: NOT CHECKED")
        print("     (pass --docker os7-build:amd64 — it needs .NET)")

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
