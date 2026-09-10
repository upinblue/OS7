#!/usr/bin/env python3
# =============================================================================
# OS/7 — assemble one release directory, from what the artefacts say about
# themselves.
#
#   scripts/make-release-dir.py 1.0.0.174 \
#       --measured-amd64 "check-image.py 105/105; run-s5.py install+boot" \
#       --measured-arm64 "check-image.py 93/93; NEVER BOOTED"
#
# Produces out/release/<version>/ holding README.txt, SHA256SUMS, both release
# descriptors and the screenshots, and prints the two rsync commands that put it
# and the ISOs on the Storage Box. It does NOT upload: publishing is a decision
# somebody makes, not a side effect of assembling (the same rule os7-web's
# publish-release.py already follows for the download page).
#
# WHAT IT REFUSES, AND WHY EACH REFUSAL EXISTS
#
#   * ONE MEDIUM ONLY -> refused. A release is both architectures or it is not a
#     release; a directory holding one is a trap for whoever finds it later.
#   * THE TWO MEDIA DISAGREE -> refused. This is RELEASE-PROCESS.md §1.3 made
#     executable. BUILD comes from `git rev-list --count HEAD` and SOURCE_FACTS
#     is expanded per `make` invocation, so a commit between the two builds
#     gives two different numbers -- which happened on 2026-09-02 to the person
#     who had written §1.3 a day earlier. A paragraph did not stop it; this does.
#   * NO EVIDENCE STATED -> refused. --measured-<arch> is mandatory and lands in
#     README.txt verbatim. The script cannot know which harnesses ran, and the
#     one thing it must never do is leave that blank or invent it: a release
#     directory that does not say what was measured invites the reader to assume
#     everything was.
#   * NO SCREENSHOTS -> refused unless --no-screenshots is passed deliberately.
#
# Sizes and hashes come off the bytes on disk. Nothing here is typed.
# =============================================================================

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "out"
STAGE = OUT / "release"
ARCHES = ("amd64", "arm64")


def die(msg):
    print(f"\n!!! {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_of(path):
    """In 8 MiB blocks, with progress — the amd64 ISO is over 3 GB and a silent
    three-minute pause reads as a hang."""
    h = hashlib.sha256()
    total = path.stat().st_size
    done = 0
    with path.open("rb") as f:
        while chunk := f.read(8 << 20):
            h.update(chunk)
            done += len(chunk)
            pct = done * 100 // total if total else 100
            print(f"\r    {path.name}  {pct:3d}%", end="", flush=True)
    print(f"\r    {path.name}  sha256 {h.hexdigest()[:16]}…  "
          f"{total:,} bytes")
    return h.hexdigest(), total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("version", help="e.g. 1.0.0.174")
    ap.add_argument("--measured-amd64", required=True,
                    help="what was actually run against the amd64 medium")
    ap.add_argument("--measured-arm64", required=True,
                    help="what was actually run against the arm64 medium")
    ap.add_argument("--screenshots", default="docs/manual/images",
                    help="directory of PNGs to include")
    ap.add_argument("--no-screenshots", action="store_true")
    args = ap.parse_args()

    v = args.version
    print(f"\n>>> release directory for {v}\n")

    # ---- the media, and they must agree ------------------------------------
    isos = {}
    for arch in ARCHES:
        p = OUT / f"OS7-{v}-{arch}.iso"
        if not p.is_file():
            die(f"{p} is not here. A release is both architectures; build the "
                f"missing one from the same commit before assembling.")
        isos[arch] = p

    print("  hashing the media")
    facts = {}
    for arch, p in isos.items():
        digest, size = sha256_of(p)
        facts[arch] = {"file": p.name, "sha256": digest, "size": size}

    # ---- the descriptors, and §1.3 as a refusal ----------------------------
    print("\n  what the media say about themselves")
    desc = {}
    for arch in ARCHES:
        d = OUT / f"OS7-{v}-{arch}.release.json"
        if not d.is_file():
            die(f"{d} is missing. build.sh writes it beside the ISO; without it "
                f"this directory would describe the media from memory.")
        desc[arch] = json.loads(d.read_text(encoding="utf-8"))
        facts[arch]["descriptor"] = d.name

    def field(arch, *names):
        """DOTTED LOOKUP, because the descriptor is nested and a flat get() is
        wrong in the worst way: `source.commit` and `base.archive_snapshot` both
        come back None from a top-level get, and None printed into a README reads
        as a fact about the release rather than as a bug in the reader. Measured
        2026-09-02, when the first run of this tool put "snapshot None" on
        screen."""
        for n in names:
            cur = desc[arch]
            for part in n.split("."):
                if isinstance(cur, dict) and part in cur:
                    cur = cur[part]
                else:
                    cur = None
                    break
            if cur is not None:
                return cur
        return None

    for key, label in (("version", "version"),
                       ("base.archive_snapshot", "snapshot"),
                       ("channel", "channel"),
                       ("source.commit", "commit")):
        vals = {a: field(a, key) for a in ARCHES}
        if vals["amd64"] != vals["arm64"]:
            die(f"the two media disagree on {label}: "
                f"amd64={vals['amd64']!r} arm64={vals['arm64']!r}.\n"
                f"RELEASE-PROCESS.md §1.3: both media must come from ONE commit. "
                f"Rebuild them without committing in between.")
        print(f"    {label:<10} {vals['amd64']}")

    channel = field("amd64", "channel") or "unknown"
    commit = field("amd64", "source.commit", "git_commit") or "unknown"
    snapshot = field("amd64", "base.archive_snapshot", "archive_snapshot") or "unknown"
    kernel = field("amd64", "components.kernel") or "unknown"
    # Whether the source tree was clean. This is not a footnote: an installed
    # machine PRINTS the consequence at Get-OS7Version — "This release was not
    # built from a clean source tree, so this number does not identify the
    # source it came from" — so a release directory that did not say it would be
    # quieter than the product it describes.
    reproducible = bool(field("amd64", "reproducible"))
    dirty = bool(field("amd64", "source.dirty"))

    # ---- the directory -----------------------------------------------------
    dest = STAGE / v
    if dest.exists():
        shutil.rmtree(dest)
    (dest / "screenshots").mkdir(parents=True)

    for arch in ARCHES:
        shutil.copy2(OUT / facts[arch]["descriptor"], dest / f"release-{arch}.json")

    shots = []
    if not args.no_screenshots:
        src = REPO / args.screenshots
        if not src.is_dir():
            die(f"{src} is not a directory. Take the pictures from a machine of "
                f"THIS build (shoot-manual.py), or pass --no-screenshots and say "
                f"in --measured-* that there are none.")
        found = sorted(src.glob("*.png"))
        if not found:
            die(f"{src} holds no PNGs.")

        # A PICTURE OF THIS BUILD CANNOT PREDATE THIS BUILD. The directory that
        # holds the shots accumulates: on 2026-09-02 it held 48 taken from the
        # 1.0.0.174 machine and 26 desktop and Setup screens from 1.0.0.163,
        # and copying all 74 would have put another release's pictures in this
        # release's folder under a name that says otherwise. BUILD-NOTES #93 is
        # the same shape — one measurement in seven contaminated by an artefact
        # that had been touched after the thing it claimed to describe.
        #
        # An mtime is not proof of provenance, and this is not treated as proof:
        # it is a NECESSARY condition, and it is enough to catch the case that
        # actually happens. Refused rather than skipped, because a picture
        # silently dropped is as misleading as one silently included.
        built = field("amd64", "built", "built_at", "date")
        cutoff = None
        if built:
            try:
                cutoff = datetime.fromisoformat(built.replace("Z", "+00:00")).timestamp()
            except ValueError:
                cutoff = None
        if cutoff is None:
            die("the descriptor names no build time, so the screenshots cannot "
                "be checked against it. Pass --no-screenshots and say so, or fix "
                "the descriptor.")

        older = [s for s in found if s.stat().st_mtime < cutoff - 60]
        if older:
            die(f"{len(older)} of {len(found)} PNGs in {args.screenshots} are "
                f"older than the medium they would describe "
                f"({built}):\n    "
                + "\n    ".join(s.name for s in older[:10])
                + (f"\n    … and {len(older) - 10} more" if len(older) > 10 else "")
                + "\n  A picture of this build cannot predate it. Move them out, or "
                  "point --screenshots at a directory holding only this build's.")

        shots = found
        for s in shots:
            shutil.copy2(s, dest / "screenshots" / s.name)
        print(f"\n  {len(shots)} screenshot(s) from {args.screenshots}, "
              f"all newer than the medium ({built})")

    # ---- SHA256SUMS, in the format sha256sum -c reads -----------------------
    sums = dest / "SHA256SUMS"
    sums.write_text(
        "".join(f"{facts[a]['sha256']}  {facts[a]['file']}\n" for a in ARCHES),
        encoding="utf-8")

    # ---- README.txt, from the measurements ---------------------------------
    banner = ""
    if channel != "stable":
        banner = (
            "\n"
            "  ####################################################################\n"
            f"  ##   THIS IS A {channel.upper()} RELEASE OF OS/7 — NOT A FINISHED PRODUCT.\n"
            "  ##   The machine says so too: a person sees\n"
            f"  ##       OS/7 {'.'.join(v.split('.')[:3])} ({channel})\n"
            "  ##   in PRETTY_NAME, /etc/issue, the MOTD and every Setup screen.\n"
            "  ####################################################################\n")

    lines = [
        f"OS/7 {v}",
        "=" * (5 + len(v)),
        banner,
        f"  channel           {channel}",
        f"  version           {v}   (a person is shown "
        f"{'.'.join(v.split('.')[:3])} ({channel}); machines read {v})",
        f"  source commit     {commit}",
        f"  ubuntu archive    {snapshot}   (pinned: this release is the archive "
        f"as it stood at that instant)",
        f"  kernel            {kernel}",
        f"  reproducible      {str(reproducible).lower()}"
        + ("" if reproducible else "   <-- read the paragraph below"),
        f"  assembled         {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        "",
        "  MEDIA",
    ]
    for arch in ARCHES:
        f = facts[arch]
        lines += [
            f"    {f['file']}",
            f"      {f['size']:,} bytes",
            f"      sha256 {f['sha256']}",
        ]
    if not reproducible:
        lines += [
            "",
            "  THIS BUILD DOES NOT IDENTIFY ITS SOURCE",
            "",
            f"  The source tree was not clean when these media were built"
            + (" (uncommitted or untracked files were present)" if dirty else "")
            + f", so the commit named above — {commit} — is where the build",
            "  started and not a complete description of what went into it. An",
            "  installed machine says so itself, unprompted, at Get-OS7Version:",
            "",
            "      This release was not built from a clean source tree,",
            "      so this number does not identify the source it came from.",
            "",
            "  Two builds from this version number are therefore not guaranteed to",
            "  hold the same bits, which is the property RELEASE-AND-UPDATE-PLAN",
            "  §3.1 exists to protect. It is disclosed rather than hidden, and it",
            "  is why this is a " + channel + " and could not be a stable release.",
        ]
    lines += [
        "",
        "  WHAT WAS MEASURED, AND WHAT WAS NOT",
        "",
        "  Read this before trusting the version number. OS/7's rule is that a",
        "  number may not claim more evidence than was gathered, and the two",
        "  architectures of this product do NOT carry the same evidence.",
        "",
        f"    amd64   {args.measured_amd64}",
        f"    arm64   {args.measured_arm64}",
        "",
        "  UPDATES",
        "",
        "  This release is delivered as an apt repository beside these media, and",
        "  an installed machine reaches it with:",
        "",
        "      Set-OS7UpdateChannel -Channel " + channel + " -Uri <the repository>",
        "      Get-OS7Release",
        "      Update-OS7",
        "",
        "  Update-OS7 does not touch the running system: it applies the release",
        "  into a clone of the boot environment, and the machine keeps running the",
        "  old one until it is rebooted. Restore-OS7 goes back.",
        "",
        "  SIGNING",
        "",
        "  The repository and its release index are signed, and the trust anchor",
        "  ships in os7-release. Which key signed THIS release is in",
        "  release-<arch>.json under \"signing\" — including whether it says",
        "  development: true, which is the honest answer while OS/7's production",
        "  key custody (CURATION-AND-DELIVERY-PLAN C7a) is still open. A release",
        "  marked development requires -AllowDevelopment on the machine, and that",
        "  is deliberate: it makes the machine say out loud that it is taking",
        "  something unpublished.",
        "",
    ]
    if shots:
        lines += [
            "  SCREENSHOTS",
            "",
            f"  screenshots/ holds {len(shots)} picture(s) taken from a machine of",
            "  THIS build — booted with no medium attached, logged into the way a",
            "  person does, and rendered with the console font the image itself",
            "  ships. Every character came off the machine's serial line.",
            "",
        ]
    (dest / "README.txt").write_text("\n".join(lines), encoding="utf-8")

    # ---- what to do with it ------------------------------------------------
    print(f"\n>>> {dest}")
    for p in sorted(dest.rglob("*")):
        if p.is_file():
            print(f"    {p.relative_to(dest)}  ({p.stat().st_size:,} bytes)")

    print("\n>>> to publish it (payload first; the repository index goes LAST,")
    print("    separately, because that is what makes a release visible):\n")
    rsh = "ssh -p23 -i ~/.ssh/os7-storagebox"
    print(f"    rsync -rlt --omit-dir-times --no-perms -e '{rsh}' \\")
    print(f"      {dest}/ out/OS7-{v}-amd64.iso out/OS7-{v}-arm64.iso \\")
    print(f"      <publish-user>@<host>:./releases/{v}/\n")


if __name__ == "__main__":
    main()
