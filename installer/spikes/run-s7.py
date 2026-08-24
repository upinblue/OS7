#!/usr/bin/env python3
"""
Host-side harness for spike S7 — is the version number true.

RELEASE-AND-UPDATE-PLAN §10 S7: "Build the same release twice from the same
snapshot; diff `dpkg --get-selections` and the manifest hash. Done when: byte-
identical selections. If not, the pinning model is incomplete and §3 needs
revisiting before anything is shipped."

    ./run-s7.py first  [arch]   build, and set the result aside as build A
    ./run-s7.py second [arch]   build again, and set it aside as build B
    ./run-s7.py diff   [arch]   compare A and B, and say what moved
    ./run-s7.py all    [arch]   all three, in order          (default, arm64)
    ./run-s7.py reset  [arch]   throw the saved builds away

WHAT THIS SPIKE IS ACTUALLY ASKING. Not "are two ISOs bit-identical" — they are
not, and cannot be: squashfs records timestamps, the manifest carries a build
time, and nothing in this project has claimed otherwise. The claim under test is
narrower and is the one the version number rests on:

    OS/7 1.0.0.32 names a SET OF PACKAGES AT SPECIFIC VERSIONS, and building it
    again from the same pin gives that same set.

If that fails, the number is decoration: two machines would report `1.0.0.32`
and hold different software, which §3.1 argues is worse than having no number
because a number gets trusted.

WHY THE MANIFEST AND NOT THE ISO. build/config/hooks/0075 writes
`/usr/lib/os7/packages.manifest` — every package, its version and its
architecture, sorted — and build.sh lifts it out of the squashfs beside the ISO.
So the comparison is a diff of two text files and takes milliseconds, and the
thing being diffed is the thing that was IN the image rather than a re-derivation
of it.

Note that the manifest carries VERSIONS, which `dpkg --get-selections` does not
(BUILD-NOTES #37). Selections alone would compare equal for two builds holding
different kernels, so this spike would pass without testing anything.

THE ONE THING TO GET RIGHT WHEN RUNNING THIS. Both builds must come from the
same commit with the same working tree, because the BUILD field of the version
is `git rev-list --count HEAD`. Commit between them and the two builds are
honestly different releases and the diff is meaningless. `first` records the
commit and `diff` refuses if it moved, so this cannot be got wrong quietly.
"""

import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "out"
STATE = REPO / ".vm" / "s7"


def step(msg: str) -> None:
    print(f"\n### {msg}", flush=True)


def fail(msg: str) -> None:
    print(f"\nS7 FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(REPO), *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def source_state() -> dict:
    """The commit and cleanliness both builds have to share."""
    return {
        "commit": git("rev-parse", "HEAD"),
        "dirty": bool(git("status", "--porcelain")),
    }


def build(arch: str) -> None:
    subprocess.run(["make", f"build-{arch}"], cwd=REPO, check=True)


def artefacts(arch: str) -> tuple[Path, Path]:
    """The manifest and release.json build.sh left beside the ISO."""
    found = sorted(OUT.glob(f"OS7-*-{arch}.packages.manifest"))
    if not found:
        fail(f"no OS7-*-{arch}.packages.manifest in {OUT} — did the build run?")
    manifest = found[-1]
    release = manifest.with_name(manifest.name.replace(".packages.manifest", ".release.json"))
    if not release.exists():
        fail(f"{release} is missing next to {manifest}")
    return manifest, release


def capture(arch: str, which: str) -> None:
    """Set one build aside, with the source state it was built from."""
    manifest, release = artefacts(arch)
    dest = STATE / arch / which
    dest.mkdir(parents=True, exist_ok=True)
    shutil.copy2(manifest, dest / "packages.manifest")
    shutil.copy2(release, dest / "release.json")
    (dest / "source.json").write_text(json.dumps(source_state(), indent=2) + "\n")

    digest = hashlib.sha256((dest / "packages.manifest").read_bytes()).hexdigest()
    lines = (dest / "packages.manifest").read_text().count("\n")
    print(f"    {which}: {lines} packages, sha256 {digest[:16]}…")
    print(f"    saved to {dest}")


def phase_first(arch: str) -> None:
    step("first — build A")
    build(arch)
    capture(arch, "a")


def phase_second(arch: str) -> None:
    step("second — build B, from the same pin")
    build(arch)
    capture(arch, "b")


def phase_diff(arch: str) -> None:
    step("diff — is the version number true")
    a, b = STATE / arch / "a", STATE / arch / "b"
    for d in (a, b):
        if not (d / "packages.manifest").exists():
            fail(f"{d} has no packages.manifest — run `first` and `second` before `diff`")

    src_a = json.loads((a / "source.json").read_text())
    src_b = json.loads((b / "source.json").read_text())
    if src_a["commit"] != src_b["commit"]:
        fail("the two builds are from different commits "
             f"({src_a['commit'][:12]} vs {src_b['commit'][:12]}). "
             "They are different releases, and comparing them proves nothing.")
    if src_a["dirty"] or src_b["dirty"]:
        print("    NOTE: at least one build came from a dirty tree. The Ubuntu")
        print("    half of the comparison is still valid — that is what the pin")
        print("    covers — but the OS/7 half is not pinned by anything.")

    rel_a = json.loads((a / "release.json").read_text())
    rel_b = json.loads((b / "release.json").read_text())
    print(f"    A: {rel_a['version']}  built {rel_a['built']}")
    print(f"    B: {rel_b['version']}  built {rel_b['built']}")

    if rel_a["version"] != rel_b["version"]:
        fail(f"the two builds carry different versions "
             f"({rel_a['version']} vs {rel_b['version']}) from one commit")
    if rel_a["base"]["archive_snapshot"] != rel_b["base"]["archive_snapshot"]:
        fail("the two builds used different archive snapshots — the pin moved")

    # The measurement. Parsed into dicts rather than diffed as text, so the
    # report can say WHICH package moved and to what: "not identical" is a
    # verdict, and a verdict is not what makes a failing spike actionable.
    def load(path: Path) -> dict[str, str]:
        out = {}
        for line in path.read_text().splitlines():
            if not line.strip():
                continue
            name, version, *_ = line.split("\t")
            out[name] = version
        return out

    pa, pb = load(a / "packages.manifest"), load(b / "packages.manifest")

    only_a = sorted(set(pa) - set(pb))
    only_b = sorted(set(pb) - set(pa))
    moved = sorted(n for n in set(pa) & set(pb) if pa[n] != pb[n])

    print(f"    A holds {len(pa)} packages, B holds {len(pb)}")

    if not (only_a or only_b or moved):
        digest = hashlib.sha256((a / "packages.manifest").read_bytes()).hexdigest()
        print(f"\nS7 PASS: two builds from {rel_a['base']['archive_snapshot']} hold")
        print(f"         identical package sets — {len(pa)} packages, "
              f"manifest sha256 {digest[:16]}…")
        print(f"         {rel_a['version']} names a state, not a moment.")
        return

    print("\n    THE PIN DID NOT HOLD. What moved:")
    for n in only_a:
        print(f"      only in A   {n} {pa[n]}")
    for n in only_b:
        print(f"      only in B   {n} {pb[n]}")
    for n in moved:
        print(f"      changed     {n}: {pa[n]} -> {pb[n]}")
    fail(f"{len(only_a)} removed, {len(only_b)} added, {len(moved)} changed. "
         "The pinning model in RELEASE-AND-UPDATE-PLAN §3 is incomplete; "
         "do not ship a version number until this passes.")


def phase_reset(arch: str) -> None:
    step("reset")
    target = STATE / arch
    if target.exists():
        shutil.rmtree(target)
        print(f"    removed {target}")
    else:
        print(f"    nothing at {target}")


PHASES = {
    "first": phase_first,
    "second": phase_second,
    "diff": phase_diff,
    "reset": phase_reset,
}


def main() -> None:
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    arch = sys.argv[2] if len(sys.argv) > 2 else "arm64"
    if arch not in ("arm64", "amd64"):
        fail(f"unknown arch {arch}")

    if what == "all":
        for name in ("first", "second", "diff"):
            PHASES[name](arch)
        return
    if what not in PHASES:
        fail(f"unknown phase {what}; expected one of {', '.join(PHASES)} or all")
    PHASES[what](arch)


if __name__ == "__main__":
    main()
