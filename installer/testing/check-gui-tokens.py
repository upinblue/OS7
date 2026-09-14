#!/usr/bin/env python3
"""
The GUI design system's palette, held against the desktop theme's. No VM, no
Docker, no .NET — seconds.

    ./check-gui-tokens.py

WHY IT EXISTS. docs/GUI-APPS-PLAN.md G9 says every OS/7 application takes its
colours from one source and defines none of its own. There are now two files
carrying the Windows 2000 palette, and there have to be, because Avalonia cannot
read GTK CSS:

    build/packages/os7-desktop-theme/.../gtk-3.0/gtk.css      @define-color os7_*
    src/OS7.Ui/Theme/Tokens.axaml                             <Color x:Key="os7_*">

That is the shape this repository has paid for twice — the installer's TPM step
paraphrasing a spike (BUILD-NOTES #66), and the netplan document generated in
two languages, which P3 is spending two steps deleting. The failure it makes
here is not a crash. It is five applications that are almost the same grey, and
nothing that ever says so.

So: the two files must agree, name for name and value for value, and no colour
may be written anywhere else under src/.

WHAT THIS IS NOT. It says nothing about whether the palette is RIGHT — the theme
package's own README and the rendered-pixel measurements behind it answer that.
This checks that there is one palette rather than two.

PROVEN TO FIRE. OS7_SCAN_ROOT points the source scan at another tree, and
--self-test plants each defect in a copy and requires this file to go red on it.
A rule that has never failed is a rule nobody has tested.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

THEME_CSS = os.path.join(
    REPO, "build", "packages", "os7-desktop-theme", "tree", "usr", "share",
    "themes", "OS7-Classic", "gtk-3.0", "gtk.css")

TOKENS = os.path.join(REPO, "src", "OS7.Ui", "Theme", "Tokens.axaml")
SRC = os.environ.get("OS7_SCAN_ROOT", os.path.join(REPO, "src"))

# `Transparent` is the absence of a colour, not a colour. Every other named
# brush is a value, and a value belongs in Tokens.axaml.
ALLOWED_NAMES = {"Transparent"}

CSS_TOKEN = re.compile(r"@define-color\s+(os7_\w+)\s+(#[0-9a-fA-F]{3,8})\s*;")
AXAML_TOKEN = re.compile(r'<Color\s+x:Key="(os7_\w+)"\s*>\s*(#[0-9a-fA-F]{3,8})\s*</Color>')
HEX_LITERAL = re.compile(r"#[0-9a-fA-F]{3,8}\b")

FAILS = []


def check(ok, what, detail=""):
    print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f"   [{detail}]" if detail else ""))
    if not ok:
        FAILS.append(what)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def parse_css(text):
    return {name: value.lower() for name, value in CSS_TOKEN.findall(text)}


def parse_axaml(text):
    return {name: value.lower() for name, value in AXAML_TOKEN.findall(text)}


def strip_comments(path, text):
    """
    Blank out comments, keeping line numbers.

    NOT cosmetic. This repository writes its reasoning into the code, and that
    prose contains things that look exactly like colours: `BUILD-NOTES #151` is
    a trap number, and Os7Theme.axaml explains in a comment that GRAYTEXT is the
    same #808080 as 3DSHADOW. Both were reported as violations on this check's
    first run. A colour NAMED in prose is not a colour USED, and a rule that
    cannot tell them apart is one somebody will switch off.

    Replacing comment characters with spaces rather than deleting them keeps
    every offender's line number true.
    """
    def blank(match):
        return re.sub(r"[^\n]", " ", match.group(0))

    if path.endswith(".axaml"):
        return re.sub(r"<!--.*?-->", blank, text, flags=re.S)

    text = re.sub(r"/\*.*?\*/", blank, text, flags=re.S)
    return re.sub(r"//[^\n]*", blank, text)


def source_files(root):
    """Every .cs and .axaml under root, except the token file itself."""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("bin", "obj")]
        for name in sorted(filenames):
            if not name.endswith((".cs", ".axaml")):
                continue
            path = os.path.join(dirpath, name)
            if os.path.basename(path) == "Tokens.axaml":
                continue
            yield path


def run(scan_root):
    """The whole rule. Returns the failure list."""
    del FAILS[:]

    print("OS/7 GUI — the palette has one source")
    print()

    # ---------------------------------------------------------------- 1
    print("  1. Both files exist and parse")

    if not os.path.exists(THEME_CSS):
        check(False, "the desktop theme's gtk.css is where it is expected", THEME_CSS)
        return FAILS
    if not os.path.exists(TOKENS):
        check(False, "OS7.Ui's Tokens.axaml is where it is expected", TOKENS)
        return FAILS

    css = parse_css(read(THEME_CSS))
    axaml = parse_axaml(read(TOKENS))

    check(len(css) > 0, f"gtk.css defines os7_* colours", f"{len(css)} found")
    check(len(axaml) > 0, f"Tokens.axaml defines os7_* colours", f"{len(axaml)} found")

    # ---------------------------------------------------------------- 2
    print()
    print("  2. Every colour the theme defines, the design system has")

    missing = sorted(set(css) - set(axaml))
    check(not missing,
          "no theme colour is missing from Tokens.axaml",
          ", ".join(missing) if missing else "")

    # ---------------------------------------------------------------- 3
    print()
    print("  3. Nothing is invented on the Avalonia side")

    extra = sorted(set(axaml) - set(css))
    check(not extra,
          "Tokens.axaml defines no colour the theme does not",
          ", ".join(extra) if extra else "")

    # ---------------------------------------------------------------- 4
    print()
    print("  4. The values are the same values")

    for name in sorted(set(css) & set(axaml)):
        check(css[name] == axaml[name],
              f"{name} agrees",
              f"gtk.css {css[name]} vs Tokens.axaml {axaml[name]}")

    # ---------------------------------------------------------------- 5
    print()
    print("  5. No colour is written anywhere else under src/")

    offenders = []
    for path in source_files(scan_root):
        text = strip_comments(path, read(path))
        for line_number, line in enumerate(text.splitlines(), start=1):
            for literal in HEX_LITERAL.findall(line):
                # An XML character entity is not a colour.
                if re.search(r"&#x?[0-9A-Fa-f]+;", line):
                    continue
                offenders.append(
                    f"{os.path.relpath(path, REPO)}:{line_number} {literal}")

    check(not offenders,
          "no hex colour literal outside Tokens.axaml",
          "; ".join(offenders[:5]) if offenders else "")

    named = []
    for path in source_files(scan_root):
        text = strip_comments(path, read(path))
        for line_number, line in enumerate(text.splitlines(), start=1):
            for match in re.finditer(
                    r'(?:Background|Foreground|Stroke|Fill|BorderBrush|Color)\s*=\s*"(\w+)"',
                    line):
                value = match.group(1)
                if value in ALLOWED_NAMES:
                    continue
                # A binding or resource reference is not a literal.
                if value.startswith(("Binding", "StaticResource", "DynamicResource",
                                     "TemplateBinding")):
                    continue
                named.append(
                    f"{os.path.relpath(path, REPO)}:{line_number} {match.group(0)}")

    check(not named,
          "no named colour outside Tokens.axaml",
          "; ".join(named[:5]) if named else "")

    return FAILS


def self_test():
    """
    Plant each defect in a copy and require this file to catch it. A rule that
    has never gone red is a rule nobody has tested.
    """
    print("OS/7 GUI tokens — does the rule FIRE?")
    print()

    results = []
    work = tempfile.mkdtemp(prefix="os7-gui-tokens-")
    try:
        planted = os.path.join(work, "src")
        shutil.copytree(os.path.join(REPO, "src"), planted,
                        ignore=shutil.ignore_patterns("bin", "obj"))

        # Defect 1: a hex colour written straight into a view.
        view = os.path.join(planted, "OS7.App.SoftwareUpdate", "Views", "MainWindow.axaml")
        with open(view, encoding="utf-8") as handle:
            original = handle.read()
        with open(view, "w", encoding="utf-8") as handle:
            handle.write(original.replace(
                '<Grid Grid.Row="5"', '<Grid Background="#ff00ff" Grid.Row="5"', 1))

        code = subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            env={**os.environ, "OS7_SCAN_ROOT": planted},
            capture_output=True, text=True).returncode
        results.append(("a hex colour planted in a view is caught", code != 0))

        # Defect 2: a named colour on a brush property.
        with open(view, "w", encoding="utf-8") as handle:
            handle.write(original.replace(
                '<Grid Grid.Row="5"', '<Grid Background="Red" Grid.Row="5"', 1))

        code = subprocess.run(
            [sys.executable, os.path.abspath(__file__)],
            env={**os.environ, "OS7_SCAN_ROOT": planted},
            capture_output=True, text=True).returncode
        results.append(("a named colour planted in a view is caught", code != 0))

        # Defect 3: a token whose value drifts from the theme's.
        with open(view, "w", encoding="utf-8") as handle:
            handle.write(original)

        tokens = os.path.join(planted, "OS7.Ui", "Theme", "Tokens.axaml")
        with open(tokens, encoding="utf-8") as handle:
            token_text = handle.read()
        drifted = token_text.replace(
            '<Color x:Key="os7_face">#d4d0c8</Color>',
            '<Color x:Key="os7_face">#d4d0c9</Color>')
        assert drifted != token_text, "the planting did not take"

        # The value check reads the REAL Tokens.axaml, so this defect is
        # planted there and restored afterwards - the one case OS7_SCAN_ROOT
        # cannot reach.
        real = TOKENS
        with open(real, encoding="utf-8") as handle:
            real_text = handle.read()
        try:
            with open(real, "w", encoding="utf-8") as handle:
                handle.write(drifted)
            code = subprocess.run(
                [sys.executable, os.path.abspath(__file__)],
                capture_output=True, text=True).returncode
            results.append(("a token drifting from the theme's value is caught", code != 0))
        finally:
            with open(real, "w", encoding="utf-8") as handle:
                handle.write(real_text)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    for what, ok in results:
        print(f"      {'ok  ' if ok else 'FAIL'}  {what}")

    bad = [what for what, ok in results if not ok]
    print()
    print(f"  {len(results) - len(bad)} ok, {len(bad)} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())

    failures = run(SRC)
    print()
    if failures:
        print(f"  FAILED: {len(failures)}")
        for failure in failures:
            print(f"    {failure}")
        sys.exit(1)
    print("  all ok")
    sys.exit(0)
