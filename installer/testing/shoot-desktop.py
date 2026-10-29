#!/usr/bin/env python3
"""The administrator manual's DESKTOP pictures, taken from a machine.

    python installer/testing/os7lab.py install gui --mode Gui   # once, ~25 min
    python installer/testing/os7lab.py up gui
    python installer/testing/shoot-desktop.py                   # signs in, shoots
    python installer/testing/place-manual-shots.py desktop

`shoot-manual.py` does this for the console: boot an installed disk, log in the
way a person does, and keep the screen. This is the same discipline for the half
of the product that is a desktop — and for OS/7's own two applications, which
chapter 13 could not describe because nothing had ever photographed them.

WHAT IT DOES NOT DO, deliberately:

* **It accepts nothing.** Microsoft Edge opens a first-run consent dialog with a
  diagnostic-data box already ticked, and the Intune agent opens a sign-in. Both
  are photographed AS THEY ARRIVE. Clicking through a consent dialog to get a
  tidier picture would be a decision taken on an operator's behalf, and the
  first screen is what a new machine actually shows anyway.
* **It does not install anything or change the machine**, apart from the ONE
  file it is given a history: `--file` writes a small text file in the account's
  home and takes snapshots of it, because the Versions window has nothing to
  draw on a machine that is twenty minutes old. See `history()`.
* **It does not judge the pictures.** `place-manual-shots.py` does that, and the
  rule that matters there was learned here: a GUI capture that failed looks
  exactly like one that worked. What this file DOES check is the three things
  that make every later picture worthless if they are wrong — that the greeter
  drew a password field, that logind then has a session of class `user`, and
  that the restore left the replaced file beside the restored one.

THE COORDINATES ARE THE FRAGILE PART, so there are as few of them as possible.
The panel and the start menu are fixed furniture and are aimed at; everything
that depends on where a WINDOW happened to land is done with the keyboard
instead — ALT+F4 to close, typing to narrow Files to the one file, SHIFT+F10 for
its context menu, UP for that menu's last entry. Those cannot miss, and the
three close-button coordinates they replaced were this file's worst bugs.

Every click is named, every one is followed by a settle, and after each step the
screen is SHOT — so a run that went wrong is diagnosable from the pictures
rather than from a traceback.
"""

import argparse
import importlib.util
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

spec = importlib.util.spec_from_file_location("os7lab", os.path.join(HERE, "os7lab.py"))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)

# The PNG reader is place-manual-shots.py's, imported rather than written a
# second time: both files need to look at a saved screendump and one decoder is
# enough (BUILD-NOTES #66).
_pms = importlib.util.spec_from_file_location(
    "place_manual_shots", os.path.join(HERE, "place-manual-shots.py"))
_pmsmod = importlib.util.module_from_spec(_pms)
_pms.loader.exec_module(_pmsmod)
read_png = _pmsmod.png_rgb

# The panel and menu geometry, measured on the `gui` bench at 1280x800,
# 2026-09-22. Named rather than repeated, so a GNOME that moves one of them is
# one line to fix.
PASSWORD_FIELD = (640, 486)          # exists only once an account is chosen
FIELD_RECT = (470, 472, 810, 500)    # the box it occupies, for field_drawn()
GREETER_BLUE = bytes((0x00, 0x57, 0xAD))   # the greeter's field colour
APPS_BUTTON = (111, 13)
FAVORITES = (42, 45)
SYSTEM_TOOLS = (55, 178)
MENU_ROW = [(x, y) for x, y in ((197, 55), (168, 93), (179, 131), (201, 169))]
EDGE, FILES, TERMINAL, INTUNE = MENU_ROW
SOFTWARE_UPDATE = (202, 54)          # first row under System Tools
VERSION_SECOND = (943, 243)          # the newest SNAPSHOT, under "Now"
RESTORE_BUTTON = (822, 718)
RESTORE_CONFIRM = (677, 480)
# NO CLOSE-BUTTON COORDINATES. There were three, one per window, and they were
# the single biggest source of wrongness in this file: a window's X is wherever
# that window landed, Files does not land in the same place twice, and
# `CLOSE_CLASSIC` was measured on the Versions window and then used on Software
# Update — which stayed open, on top of everything, for the rest of the run.
# ALT+F4 closes whatever has focus and cannot miss.


def sh(*args):
    """Run os7lab as a subprocess, so its argument parsing stays the one truth."""
    cmd = [sys.executable, os.path.join(HERE, "os7lab.py")] + list(args)
    p = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if p.returncode != 0:
        print(p.stdout.rstrip())
        print(p.stderr.rstrip())
        raise SystemExit(f"os7lab {' '.join(args)} failed ({p.returncode})")
    return p.stdout.rstrip()


class Screen:
    def __init__(self, bench):
        self.b = lab.Bench(bench)
        self.b.require_running()
        self.name = bench
        os.makedirs(self.b.shots, exist_ok=True)

    def settle(self, seconds):
        """Wait, THROUGH THE GUEST.

        A sleep on the host measures the host's idea of time; a sleep in the
        guest also proves the machine is still answering, which is the thing a
        long click sequence most wants to know between steps.
        """
        sh("exec", self.name, f"Start-Sleep -Seconds {seconds}; 'ok'")

    def click(self, where, button="left"):
        x, y = where
        sh("click", self.name, str(x), str(y), "--button", button)

    def type(self, text):
        sh("type", self.name, text)

    def key(self, spec):
        sh("key", self.name, spec)

    def shot(self, name):
        """Take a screendump, and return ITS PATH.

        Not os7lab's printed line, which is the path plus `  (1280x800)` — the
        first version returned that and handed it to open(), so the run died on
        a FileNotFoundError naming a file whose name ended in the geometry.
        """
        print(f"      {sh('shot', self.name, name)}")
        return os.path.join(self.b.shots, name + ".png")


def field_drawn(png):
    """Whether the greeter has a password field on it.

    The one question in this file that only the pixels can answer — logind
    cannot be asked whether a widget exists. The field is a dark rounded box
    where the tile screen is plain greeter blue, so the test is: how much of
    that rectangle is NOT the background. On the tile screen it is nothing.
    """
    w, h, rgb = read_png(png)
    x0, y0, x1, y1 = FIELD_RECT
    total = other = 0
    for y in range(y0, min(y1, h)):
        for x in range(x0, min(x1, w), 2):
            p = (y * w + x) * 3
            total += 1
            if rgb[p:p + 3] != GREETER_BLUE:
                other += 1
    return total and other / total > 0.5


def changed_enough(before, after, fraction):
    """Whether enough of the screen changed between two shots.

    A menu, a dialog or a window opening covers a measurable share of the
    frame. This is a crude test and it is only ever used to answer "did
    ANYTHING happen", which is the question a click that missed answers wrongly
    by being silent.
    """
    w1, h1, a = read_png(before)
    w2, h2, b = read_png(after)
    if (w1, h1) != (w2, h2):
        return True
    n = len(a) // 3
    differ = sum(1 for i in range(0, len(a), 3 * 7) if a[i:i + 3] != b[i:i + 3])
    return differ / (n / 7) > fraction


def graphical_session(bench):
    """Whether a graphical session for a real account is open — ASKED OF LOGIND.

    NOT read off the screen, and the first two versions of this were. Comparing
    the frame before a password with the frame after looked decisive and is
    not: the greeter draws a clock, so two pictures of the same greeter one
    minute apart differ, and a byte comparison calls that "the screen changed".
    A whole run went through every click of this file against a greeter and
    reported nothing wrong, because every guard in it was a guard about pixels.

    logind knows, and it has a property for exactly this question: **Class**,
    which is `greeter` for the display manager's own session and `user` for a
    person's. Nothing else separates them reliably, and two weaker rules were
    tried first on this machine:

    * `user != "gdm"` — the greeter runs as **gdm-greeter**, so it passed;
    * `uid >= 1000` — Ubuntu gives that dynamic account **60578**, so it passed
      too.

    Both reported a signed-in desktop while the password field was still on the
    screen. The greeter's session is on seat0 and is wayland, exactly like a
    person's; asking what KIND of session it is, is the question.
    """
    out = sh("exec", bench,
             "loginctl list-sessions --no-legend --no-pager | "
             "ForEach-Object { $f = $_ -split '\\s+' | Where-Object { $_ }; "
             "if ($f.Count -ge 4) { "
             "$c = (loginctl show-session $f[0] -p Class --value); "
             "$t = (loginctl show-session $f[0] -p Type --value); "
             "\"$($f[0]) $($f[2]) $($f[3]) $c $t\" } }")
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 5:
            continue
        seat, klass, kind = parts[2], parts[3], parts[4]
        if seat == "seat0" and klass == "user" and kind in ("wayland", "x11"):
            return line.strip()
    return None


def sign_in(s, password):
    """The greeter, the way a person meets it — in TWO stages.

    THE GREETER STARTS ON THE USER TILE, not on a password field: the field does
    not exist until a user is chosen. ENTER chooses the only account, which is
    what a person does and what works from a cold greeter; clicking at the tile
    is what the second version did and it did not take.

    Then it WAITS FOR LOGIND rather than for a number of seconds, and fails with
    a sentence if no graphical session appears — because every picture taken
    after a failed sign-in is a picture of a greeter, and they all look fine.
    """
    print("\n  the greeter")
    s.shot("00-greeter")

    # CHOOSE THE ACCOUNT, AND CHECK THAT IT WAS CHOSEN. One ENTER is usually
    # enough and is sometimes not — a greeter that has been sitting at the tile
    # for a while swallowed the first one on this bench, and the run went on to
    # type a password at a screen with no field on it. There is nothing to ask
    # about this one: whether the field is drawn is a question about pixels, so
    # it is answered on the pixels, in the rectangle the field occupies.
    for attempt in range(4):
        if field_drawn(s.shot(f"00b-account-{attempt}")):
            print(f"      ok    the password field is drawn "
                  f"(after {attempt} ENTER)")
            break
        s.key("ret")
        s.settle(3)
    else:
        raise SystemExit(
            "      FAIL  four ENTERs and the greeter never drew a password "
            "field.\n            Look at the 00b-account-*.png shots: if the "
            "field is there, FIELD_RECT is wrong.")

    s.click(PASSWORD_FIELD)
    s.settle(2)
    s.type(password)
    s.settle(1)
    s.shot("01-password")
    s.key("ret")

    print("      signing in …")
    for _ in range(12):
        s.settle(5)
        session = graphical_session(s.name)
        if session:
            print(f"      ok    logind has a graphical session: {session}")
            s.settle(8)                  # let the shell finish drawing
            s.shot("02-session")
            return
    raise SystemExit(
        "      FAIL  60 seconds after the password, logind has no graphical "
        "session on seat0.\n            The sign-in did not happen. "
        f"{os.path.join(s.b.shots, '01-password.png')} is what the screen "
        "looked like\n            with the password supposedly typed into it — "
        "if it shows an empty field, PASSWORD_FIELD is wrong.")


def history(s, path, dataset):
    """Give one file a history, so the Versions window has something to draw.

    A machine this new has NO snapshots: sanoid's timer has not fired, and it
    would not take four in one hour anyway. So the LAST one is taken by the
    machine's own backup path — that is the one that proves the product takes
    them — and the earlier ones are taken with `zfs snapshot` under sanoid's
    naming, which is what the retention buckets in the window are read from.

    Said out loud rather than left for a reader of the picture to wonder about:
    the pictures show a real ZFS history of a real file, and three of its four
    snapshots were taken by this function.
    """
    print("\n  one file, given a history")
    script = os.path.join(HERE, "assets", "manual-file-history.ps1")
    if not os.path.exists(script):
        raise SystemExit(f"missing {script}")
    sh("push", s.name, script, "/tmp/manual-file-history.ps1")
    out = sh("exec", s.name,
             f"pwsh -NoProfile -File /tmp/manual-file-history.ps1 "
             f"-Path {path} -Dataset {dataset}", "--sudo")
    for line in out.splitlines():
        if line.strip() and "OS7-STEP" not in line and "gpgv" not in line:
            print(f"      {line.rstrip()}")


def desktop_shots(s):
    """The desktop, and what is on it."""
    print("\n  the desktop and the applications it ships")

    # THE START MENU, AND NOT AN EMPTY DESKTOP. The bare desktop is black by
    # design (the theme's own dconf defaults set primary-color='#000000' and
    # empty the wallpaper), so a picture of it is a panel on a void — which is
    # what the manual carried from 2026-08-29 to 2026-09-22 under the caption
    # "The OS/7 desktop in its classic appearance". The menu open shows the
    # theme, the categories and what is installed, in one frame.
    s.click(APPS_BUTTON)
    s.settle(2)
    s.click(FAVORITES)
    s.settle(2)
    s.shot("01-desktop-menu")

    s.click(FILES)
    s.settle(18)
    s.shot("03-files")

    s.key("alt-f4")
    s.settle(3)
    s.click(APPS_BUTTON)
    s.settle(2)
    s.click(TERMINAL)
    s.settle(14)
    s.click((640, 300))                  # into the terminal, before typing
    s.settle(1)
    s.type("Get-OS7Version | Format-List")
    s.key("ret")
    s.settle(8)
    s.shot("02-terminal-version")

    s.key("alt-f4")
    s.settle(3)
    s.click(APPS_BUTTON)
    s.settle(2)
    s.click(EDGE)
    print("      Microsoft Edge (its first-run dialog is NOT accepted) …")
    s.settle(40)
    s.shot("04-edge")

    s.key("alt-f4")
    s.settle(6)
    s.click(APPS_BUTTON)
    s.settle(2)
    s.click(INTUNE)
    print("      the Intune agent (NOT signed in) …")
    s.settle(35)
    s.shot("05-intune")
    s.key("alt-f4")
    s.settle(4)


def app_shots(s, path):
    """OS/7's own two applications."""
    # ASKED AGAIN, because a session that died half way through makes every
    # remaining picture a greeter and every remaining click a click at one.
    if not graphical_session(s.name):
        raise SystemExit(
            "      FAIL  the graphical session is gone. Everything from here "
            "would be a picture of the greeter.")
    print("\n  Software Update")
    s.click(APPS_BUTTON)
    s.settle(2)
    s.click(SYSTEM_TOOLS)
    s.settle(2)
    s.click(SOFTWARE_UPDATE)
    s.settle(18)
    s.shot("10-app-software-update")
    s.key("alt-f4")
    s.settle(3)

    print("\n  Versions, from the file manager's context menu")
    s.click(APPS_BUTTON)
    s.settle(2)
    s.click(FAVORITES)
    s.settle(2)
    s.click(FILES)
    s.settle(18)

    # THE KEYBOARD, not two clicks at a row. Files opens where it likes —
    # measured at x=193 one run and x=0 the next — so a row's pixel is not a
    # thing that exists across runs.
    #
    # TYPING IN GNOME FILES STARTS A SEARCH; it is not the type-ahead selection
    # this first assumed. That is fine and is actually better — it narrows the
    # view to one row — but it leaves the focus IN THE SEARCH ENTRY, so the
    # first version's context-menu key went to a text box and the shot was of a
    # search bar. DOWN moves the focus into the result list.
    before = s.shot("11a-before-menu")
    s.type(os.path.splitext(os.path.basename(path))[0])
    s.settle(3)
    s.key("down")
    s.settle(1)
    # SHIFT+F10 rather than the Menu key: it is the shortcut every GTK widget
    # honours, and a virtual keyboard is not guaranteed to carry a Menu key at
    # all.
    s.key("shift-f10")
    s.settle(3)
    menu = s.shot("11-app-versions-menu")
    if not changed_enough(before, menu, 0.04):
        raise SystemExit(
            "      FAIL  no context menu appeared over the file list. The next "
            "three clicks would land on Files.\n"
            f"            Compare {before} with {menu}.")

    # UP TWICE. Versions is the second entry from the bottom in the search
    # view — `Properties` is below it — and it was the LAST one in the plain
    # Home view, where the first version of this pressed UP once and opened
    # Properties. Counting from the bottom is still better than a pixel: the
    # menu is drawn wherever the row is, and the order of its entries is
    # Nautilus's and does not move with the window.
    s.key("up")
    s.settle(1)
    s.key("up")
    s.settle(1)
    s.key("ret")
    s.settle(20)

    # AND THE WINDOW IS REQUIRED TO HAVE OPENED. Picking the wrong menu entry
    # is silent — Properties opens a dialog that looks like a window opening —
    # and the three clicks after this are aimed at the Versions window's own
    # buttons, so they would land somewhere arbitrary. Measured against the
    # menu shot: a new window covers far more than a menu did.
    opened = s.shot("11b-after-versions")
    if not changed_enough(menu, opened, 0.15):
        raise SystemExit(
            "      FAIL  the Versions window did not open — the menu entry "
            "that was activated was not the right one.\n"
            f"            Count again from the bottom in {menu}.")
    # ARRIVES ON "Now", whose Restore is correctly disabled - you cannot restore
    # the live file over itself - and whose bucket reads "live". One row down is
    # a real snapshot, which is the picture the chapter wants.
    s.click(VERSION_SECOND)
    s.settle(3)
    s.shot("12-app-versions")

    s.click(RESTORE_BUTTON)
    s.settle(4)
    s.shot("13-app-versions-restore")

    # AND THEN IT IS ANSWERED. A picture of the question is worth less than a
    # question that was answered and a file that came back: this is the only
    # place in the repository where the window's restore runs at all.
    s.click(RESTORE_CONFIRM)
    s.settle(12)
    s.shot("14-app-versions-restored")
    out = sh("exec", s.name,
             f"Get-ChildItem (Split-Path {path}) -Filter "
             f"'{os.path.basename(path)}*' | "
             "Format-Table Name,Length -AutoSize | Out-String")
    for line in out.splitlines():
        if line.strip() and "OS7-STEP" not in line:
            print(f"      {line.rstrip()}")
    if ".os7-before-restore-" not in out:
        raise SystemExit(
            "      FAIL  the restore left no .os7-before-restore- file. V19 says "
            "an unprivileged restore RENAMES what it replaces; nothing beside "
            "the file means the bytes are gone.")
    print("      ok    the replaced file was renamed aside, not destroyed (V19)")


def provenance(s, out):
    """What machine these came from, written beside them.

    THE WHOLE POINT OF TAKING THEM FROM A MACHINE. A desktop picture cannot be
    read back through a console font, so this file is the only thing that ties
    the set to a build; `place-manual-shots.py` refuses a desktop set without
    one.
    """
    ver = sh("exec", s.name,
             "$v = Get-OS7Version; "
             "'{0} {1} ({2}) {3}' -f $v.ProductName, $v.FullVersion, "
             "$v.Channel, $v.Architecture")
    ver = [ln for ln in ver.splitlines()
           if ln.strip() and "OS7-STEP" not in ln][-1].strip()
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write(f"taken from a machine: {ver}\n")
        f.write(f"by: installer/testing/shoot-desktop.py\n")
        f.write(f"at: {time.strftime('%Y-%m-%dT%H:%M:%S%z')}\n")
        f.write("Edge's first-run consent dialog was NOT accepted and the Intune "
                "agent was NOT signed in;\nboth are photographed as a new machine "
                "presents them.\n")
    print(f"\n  provenance: {ver}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", default="gui")
    ap.add_argument("--password", default=lab.PASSWORD)
    ap.add_argument("--file", default="/home/os7admin/quote.txt")
    ap.add_argument("--dataset", default=None,
                    help="the dataset the file's home is on (default: asked)")
    ap.add_argument("--skip-signin", action="store_true",
                    help="a session is already open on the bench")
    ap.add_argument("--only", choices=("all", "desktop", "apps"), default="all",
                    help="which half to shoot; the app half is the one that "
                         "needs iterating and the desktop half costs 3 minutes")
    a = ap.parse_args()

    print(f"### the manual's desktop pictures, from bench {a.bench}")
    s = Screen(a.bench)

    dataset = a.dataset
    if dataset is None:
        # WITHOUT --sudo, deliberately. `id -un` under sudo is root, and the
        # first version of this line asked for root's home dataset and got
        # `rpool/USERDATA/root_…` — a real dataset, a plausible answer, and the
        # wrong file's history.
        out = sh("exec", a.bench, "(Get-OS7Home -UserName (id -un)).Dataset")
        dataset = [ln for ln in out.splitlines()
                   if ln.strip() and "OS7-STEP" not in ln][-1].strip()
        print(f"    home dataset: {dataset}")
        if "/root_" in dataset or not dataset.startswith("rpool/USERDATA/"):
            raise SystemExit(
                f"      FAIL  {dataset} is not the signed-in account's home "
                "dataset. Pass --dataset.")

    if not a.skip_signin:
        sign_in(s, a.password)
    if a.only in ("all", "apps"):
        history(s, a.file, dataset)
    if a.only in ("all", "desktop"):
        desktop_shots(s)
    if a.only in ("all", "apps"):
        app_shots(s, a.file)
    if a.only == "all":
        provenance(s, os.path.join(s.b.shots, "provenance.txt"))
    else:
        print("\n  provenance NOT written — a partial run is not a set")

    print(f"\n### done — {s.b.shots}")
    print("    place them:  python installer/testing/place-manual-shots.py desktop")
    return 0


if __name__ == "__main__":
    sys.exit(main())
