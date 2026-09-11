#!/usr/bin/env python3
"""
The documented first run, typed by the account the installer created.

    ./run-firstrun.py [--bench s5] [--keep-up]

WHY THIS EXISTS. BUILD-NOTES #148 was reported by an operator an hour after
1.0.0.203 was published, doing the ordinary thing: they typed the command the
manual and the release notes both lead with.

    PS /home/basti> Update-OS7
         | cannot take the update lock at /run/os7-update.lock: … "Access to
         | the path '/run/os7-update.lock' is denied."
    PS /home/basti> sudo Update-OS7
    sudo: 'Update-OS7': command not found

That release had gone through 141 artefact checks per architecture, five
machine phases, 35 Secure Boot checks and two full rebuilds. None of them could
have caught it, and the reason is structural rather than an oversight: **every
harness in this directory runs as root.** `run-s5.py` reaches `Update-OS7`
through `sudo -S -p '' pwsh`; `os7lab.py exec --sudo` does the same;
`check-*.py` runs in a container whose only account is root. The one thing
nobody had was a run that behaves like a person on their first morning.

WHAT IT ASSERTS, and it is one rule in two halves:

  * a command the manual gives as READING must SUCCEED as the ordinary user;
  * a command that changes the machine must FAIL with a message that says what
    to do about it — name root, and show the form that works.

The second half is #148 exactly, and #149 is the same defect one layer down. A
message is actionable here only if it mentions root AND carries the
`sudo pwsh -c` form, and is NOT a bare .NET wrapper: `Exception calling "…"` is
the signature of both defects and is refused by name.

WHERE THE LIST COMES FROM. Not from me: every command below is quoted from a
page of `docs/manual/en/`, and the run REFUSES to start if the manual no longer
contains it. So the check follows the documentation in both directions — a
manual that starts telling operators to type something unactionable goes red,
and a manual that stops saying it goes red too, rather than leaving this file
asserting things about a product nobody documents that way any more.

WHAT IT IS NOT. It is not a test of whether the cmdlets do their work — that is
`run-s5.py`'s and `run-surface.py`'s. It never elevates, so nothing here
changes the machine; the privileged commands are expected to refuse, and a
bench that ends up modified means one of them did not.

It needs a bench with an INSTALLED machine on it. `.vm/s5` is the one
`run-s5.py` leaves behind, and its account is the one Setup created.
"""
import argparse
import importlib.util
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MANUAL = os.path.join(REPO, "docs", "manual", "en")

# Quoted from the manual, with the page each comes from. `page` is checked
# against the file before anything boots: a command this harness asserts about
# and the manual no longer gives is a harness talking to itself.
#
# `needs_root` is the EXPECTATION, not a description — it is what the product
# is supposed to do, and the run is what decides whether it does.
READ, ROOT = "read", "root"

COMMANDS = [
    # --- chapter 2, "the first five minutes". A new operator types these and
    #     every one of them must work without elevation.
    ("02-getting-started.md", "Get-OS7Version", READ),
    ("02-getting-started.md", "Get-OS7Version | Format-List *", READ),
    ("02-getting-started.md", "Get-OS7BootEnvironment", READ),
    ("02-getting-started.md", "Test-OS7Network", READ),
    ("02-getting-started.md", "Get-OS7ManagementStatus", READ),
    ("02-getting-started.md", "Get-Module -ListAvailable OS7,Zfs,Net,Time,Systemd", READ),
    ("02-getting-started.md", "Get-Command -Module OS7 -Noun OS7BootEnvironment", READ),

    # --- chapter 6, the update sequence. These change the machine, so as this
    #     account they must refuse — and #148 is what an unactionable refusal
    #     costs.
    ("06-updates.md", "Update-OS7", ROOT),
    ("06-updates.md", "Restore-OS7", ROOT),
]

# The shape both #148 and #149 wear: a .NET method signature handed to a person.
DOTNET = re.compile(r'Exception calling "')


def load_os7lab():
    """os7lab.py as a module — the same importlib route it uses for run-s5.py.

    Its top level builds no VM and starts nothing; `Bench` and `run_remote` are
    what this needs, and reimplementing either would be BUILD-NOTES #66 in a
    new place.
    """
    path = os.path.join(HERE, "os7lab.py")
    spec = importlib.util.spec_from_file_location("os7lab_module", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def manual_says(page, command):
    """Is this command still in the manual, on that page?

    Compared with whitespace collapsed: the manual wraps and this file does
    not, and a check that failed on a line break would be one nobody trusts.
    """
    path = os.path.join(MANUAL, page)
    if not os.path.exists(path):
        return False
    with open(path, encoding="utf-8") as fh:
        text = " ".join(fh.read().split())
    return " ".join(command.split()) in text


def wrap(command):
    """The command, with its error brought back as TEXT rather than as CLIXML.

    A non-interactive pwsh reached over ssh serialises its error stream as
    CLIXML — `#< CLIXML <Objs Version="1.1.0.1"…`, with the escapes encoded as
    `_x001B_` — so anything reading stderr sees the TRANSPORT'S encoding and
    not the sentence the machine wrote. The first run of this harness called
    two refusals "not actionable" on exactly that ground and could not have
    told a good message from a bad one.

    So the error is caught INSIDE PowerShell and written to stdout as the
    formatted text a person at the console would read, with the non-zero exit
    kept by hand. What this check then judges is the same string the operator
    sees, which is the only string it is entitled to judge.
    """
    nl = chr(10)
    return nl.join([
        "$ErrorActionPreference = 'Stop'",
        "try {",
        "    " + command + " | Out-String -Width 200",
        "} catch {",
        "    ($_ | Out-String -Width 200)",
        "    exit 1",
        "}",
    ]) + nl



def actionable(text):
    """Does this refusal tell the operator what to do?

    Three requirements, each earned: it must name root, it must carry the form
    that WORKS (`sudo pwsh`, because `sudo <cmdlet>` cannot — every cmdlet here
    is a function and sudo resolves executables), and it must not be a bare
    .NET wrapper, which is what both #148 and #149 hand over today.
    """
    low = text.lower()
    return ("root" in low and "sudo pwsh" in low and not DOTNET.search(text))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", default="s5",
                    help="the bench to run on; default s5, the machine run-s5.py leaves")
    ap.add_argument("--keep-up", action="store_true",
                    help="leave the VM running afterwards")
    a = ap.parse_args()

    print("\n### the documented first run, as the account the installer created")

    # ---- the manual is checked BEFORE anything boots ------------------------
    print("\n  every command below is quoted from the manual")
    missing = [(p, c) for p, c, _ in COMMANDS if not manual_says(p, c)]
    for page, cmd in missing:
        print(f"      FAIL  docs/manual/en/{page} no longer contains: {cmd}")
    if missing:
        print(f"\n{len(missing)} command(s) this harness asserts about are not in the")
        print("manual any more. Update one or the other — a harness quoting a")
        print("document that has moved on is a harness talking to itself.")
        sys.exit(1)
    print(f"      ok    all {len(COMMANDS)} still there, on the pages named")

    lab = load_os7lab()
    bench = lab.Bench(a.bench)
    if not os.path.exists(bench.target):
        print(f"\n      no installed disk at {bench.target}.")
        print("      Run run-s5.py install, or os7lab.py install <name>, first.")
        sys.exit(2)

    print(f"\n  bringing up {a.bench} and logging in as {lab.USER}")
    for step in ("up", "login"):
        got = subprocess.run([sys.executable, os.path.join(HERE, "os7lab.py"),
                              step, a.bench], cwd=REPO)
        if got.returncode != 0:
            print(f"      FAIL  os7lab.py {step} {a.bench} exited {got.returncode}")
            sys.exit(1)

    bad = 0
    results = []
    try:
        print(f"\n  typing them as {lab.USER} — NOTHING here elevates")
        for page, cmd, expect in COMMANDS:
            rc, out, err = lab.run_remote(bench, wrap(cmd), elevated=False,
                                          timeout=300)
            both = (out or "") + (err or "")
            one = " ".join(both.split())[:150]
            if expect == READ:
                ok = rc == 0
                why = "" if ok else f"exit {rc}: {one}"
            else:
                # It MUST refuse — a privileged verb that succeeds for this
                # account is a finding of its own and a worse one.
                if rc == 0:
                    ok, why = False, "IT SUCCEEDED as an ordinary user"
                else:
                    ok = actionable(both)
                    why = "" if ok else f"refused, but not actionably: {one}"
            results.append((cmd, expect, ok, why))
            if not ok:
                bad += 1
    finally:
        if not a.keep_up:
            subprocess.run([sys.executable, os.path.join(HERE, "os7lab.py"),
                            "down", a.bench], cwd=REPO)

    print()
    for cmd, expect, ok, why in results:
        mark = "ok  " if ok else "FAIL"
        label = "must work" if expect == READ else "must refuse, actionably"
        print(f"      {mark}  {cmd:<52} {label}")
        if why:
            print(f"            {why}")

    print()
    if bad:
        print(f"{bad} of {len(COMMANDS)} documented first-run command(s) behave")
        print("differently from what the manual promises an operator.")
        print()
        print("A refusal is actionable when it names root AND shows the form that")
        print("works — `sudo pwsh -NoProfile -c '<cmdlet> …'` — and is not a bare")
        print('.NET `Exception calling "…"`, which is what BUILD-NOTES #148 and')
        print("#149 hand over.")
        sys.exit(1)

    print("Every documented first-run command does what the manual says: the")
    print("reading ones work as the account Setup created, and the ones that")
    print("change the machine refuse in a sentence that names the way through.")


if __name__ == "__main__":
    main()
