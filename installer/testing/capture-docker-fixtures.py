#!/usr/bin/env python3
"""
Record the Docker module's fixtures from a REAL engine.

    ./capture-docker-fixtures.py desktop              Docker Desktop on this host
    ./capture-docker-fixtures.py bench ctr            the archive's docker.io on a
                                                      running os7lab bench

Each run executes the module's own Invoke-DockerFixtureScenario — one container,
one volume, created, started twice, stopped twice, restarted, listed, logged and
removed — with OS7_DOCKER_RECORD set, and writes what the engine answered to

    powershell/Docker/tests/fixtures/engine-<version>.jsonl

Test-DockerModule replays every such file through the module's seam and holds
the module's API range to the oldest and newest of them (CONTAINERS-PLAN §3).
So adding an engine is: record it here, widen $script:DockerApiOldest/Newest in
Docker.psm1 if it lies outside, run the self-test. The scenario is ONE function
used by both sides, so the recording and the test cannot ask different things.

THE RECORDINGS ARE COMMITTED TO A PUBLIC REPOSITORY. The scenario filters every
list to its own probe, and this script refuses to write a file that contains
this host's user name or a Windows path, and names what it found.

Run it from PowerShell or cmd, not Git Bash: BUILD-NOTES #102 — Git Bash
rewrites `/var/run/docker.sock` in a `docker run -v` into a Windows path.
"""

import argparse
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MODULE = os.path.join(REPO, "powershell", "Docker")
FIXTURES = os.path.join(MODULE, "tests", "fixtures")
OS7LAB = os.path.join(HERE, "os7lab.py")

IMAGE = "alpine:3.20"


def run(argv, **kw):
    return subprocess.run(argv, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", **kw)


# Save-DockerFixture is internal, so it is called in the module's own scope.
# The values are single-quoted PowerShell literals and are ours: none of them
# may carry a single quote.
SAVE = ("Import-Module '{m}' -Force; "
        "$f = & (Get-Module Docker) {{ param($o, $w, $i) Save-DockerFixture -File $o -Where $w -Image $i {nd}}} "
        "'{o}' '{w}' '{i}'; 'saved ' + $f.FullName")


def leaks(text):
    """What in a recording would tell a reader about this host and its owner."""
    found = []
    user = getpass.getuser()
    for needle in {user, user.lower(), REPO, REPO.replace("\\", "/"), "C:\\\\", "C:/Users"}:
        if needle and needle in text:
            found.append(needle)
    if re.search(r"[A-Za-z]:\\\\Users", text):
        found.append("a Windows profile path")
    return sorted(set(found))


def keep(recording, label):
    with open(recording, encoding="utf-8") as f:
        text = f.read()
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        sys.exit(f"{label}: the recording is empty")
    meta = json.loads(lines[0])
    if meta.get("_meta") != "docker-fixture":
        sys.exit(f"{label}: the first line is not the recording's header")
    bad = leaks(text)
    if bad:
        sys.exit(f"{label}: REFUSED — the recording contains {bad}. It would be "
                 "committed to a public repository. Narrow the scenario's filters.")
    os.makedirs(FIXTURES, exist_ok=True)
    dest = os.path.join(FIXTURES, f"engine-{meta['engine']}.jsonl")
    shutil.copyfile(recording, dest)
    print(f"{label}: engine {meta['engine']}, API {meta['api']} (min {meta['minApi']}), "
          f"{len(lines) - 1} exchanges -> {os.path.relpath(dest, REPO)}")
    return dest


def desktop(a):
    """Docker Desktop's engine, asked by the product's pwsh inside a container
    with the socket mounted. The container is the CLIENT only; what is
    recorded is the engine's answers."""
    if run(["docker", "image", "inspect", IMAGE]).returncode != 0:
        p = run(["docker", "pull", IMAGE])
        if p.returncode != 0:
            sys.exit("could not pull " + IMAGE + ":\n" + p.stderr)
    tmp = tempfile.mkdtemp(prefix="os7-docker-capture-")
    try:
        where = f"Docker Desktop (x64 Windows host), client pwsh from {a.image}"
        cmd = SAVE.format(
            m="/m/Docker.psd1", o="/out/rec.jsonl", w=where, i=IMAGE, nd="-NoDiskUsage ")
        p = run(["docker", "run", "--rm",
                 "-v", MODULE + ":/m:ro",
                 "-v", tmp + ":/out",
                 "-v", "/var/run/docker.sock:/var/run/docker.sock",
                 "--entrypoint", "pwsh", a.image,
                 "-NoProfile", "-NonInteractive", "-Command", cmd])
        sys.stdout.write(p.stdout)
        if p.returncode != 0:
            sys.exit("capture failed:\n" + p.stderr)
        keep(os.path.join(tmp, "rec.jsonl"), "desktop")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def lab(*args, timeout=900):
    p = run([sys.executable, OS7LAB, *args], timeout=timeout)
    return p


def bench(a):
    """The engine OS/7 would ship — docker.io from the pinned archive — on a
    running bench. As root, because the socket is root's (CONTAINERS-PLAN
    CT5). Then the same module asked AS THE LOGIN ACCOUNT, which is the only
    way to see the real permission-denied path rather than a constructed one."""
    guest = "/tmp/os7-docker"
    p = lab("exec", a.name, "--shell", f"rm -rf {guest} && mkdir -p {guest}/fixtures")
    if p.returncode != 0:
        sys.exit("bench not reachable:\n" + p.stderr)
    for f in ("Docker.psd1", "Docker.psm1"):
        if lab("push", a.name, os.path.join(MODULE, f), f"{guest}/{f}").returncode != 0:
            sys.exit("push failed: " + f)

    where = f"os7lab bench {a.name}, OS/7 installed, docker.io from the pinned archive"
    cmd = SAVE.format(
        m=f"{guest}/Docker.psd1", o=f"{guest}/rec.jsonl", w=where, i=IMAGE, nd="")
    p = lab("exec", a.name, "--sudo", cmd + f"; chmod 644 {guest}/rec.jsonl", timeout=900)
    sys.stdout.write(p.stdout)
    if p.returncode != 0:
        sys.exit("capture failed:\n" + p.stdout + p.stderr)

    tmp = tempfile.mkdtemp(prefix="os7-docker-capture-")
    try:
        local = os.path.join(tmp, "rec.jsonl")
        if lab("pull", a.name, f"{guest}/rec.jsonl", local).returncode != 0:
            sys.exit("pull failed")
        keep(local, "bench")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # The socket, asked by the account the installer created. Measured, not
    # constructed: what Test-DockerModule's permission case is checked against.
    probe = (f"Import-Module '{guest}/Docker.psd1' -Force; "
             "try { $null = Get-DockerEngine; 'ANSWERED (the account can reach the socket)' } "
             "catch { $_.Exception.GetType().FullName; $_.Exception.Message }")
    p = lab("exec", a.name, probe)
    print("\nas the login account, not root:\n    " + (p.stdout + p.stderr).strip().replace("\n", "\n    "))

    # The self-test, live, on the machine: every fixture now in the tree plus
    # the read-only questions to the real engine.
    for f in sorted(os.listdir(FIXTURES)):
        if f.endswith(".jsonl"):
            lab("push", a.name, os.path.join(FIXTURES, f), f"{guest}/fixtures/{f}")
    p = lab("exec", a.name, "--sudo",
            f"Import-Module '{guest}/Docker.psd1' -Force; Test-DockerModule -Live -FixturePath '{guest}/fixtures'",
            timeout=600)
    print("\nTest-DockerModule -Live on the bench, as root:")
    sys.stdout.write(p.stdout + p.stderr)
    if p.returncode != 0:
        sys.exit("the live self-test FAILED on the bench")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("desktop", help="record Docker Desktop's engine")
    d.add_argument("--image", default="os7img:175",
                   help="an image carrying the pinned pwsh, used as the client")
    d.set_defaults(func=desktop)
    b = sub.add_parser("bench", help="record the engine on a running os7lab bench")
    b.add_argument("name")
    b.set_defaults(func=bench)
    a = ap.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
