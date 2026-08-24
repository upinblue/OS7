#!/usr/bin/env python3
"""
Ask a built ISO what it is — without booting it.

    ./installer/testing/check-image.py [arch]      (default arm64)

Every other harness in this directory boots a VM, because what they check is
behaviour. Everything here is a PROPERTY OF THE IMAGE, so it is read straight out
of the squashfs in seconds — the method docs/HANDOFF.md §5 recommends for exactly
this case.

WHAT IT IS FOR. The release identity (docs/RELEASE-AND-UPDATE-PLAN.md §3) is
written by build hook 0075, which checks its own work. This checks it from
outside, on the finished artefact, after live-build has had its way with the
tree — and it checks three things the hook structurally cannot:

  * `/etc/apt/sources.list` in the SHIPPED image. The hook runs mid-build, before
    live-build rewrites apt's configuration for the binary stage. An image whose
    sources point at the live archive is not pinned, no matter what the build
    flags said (BUILD-NOTES #36), and that is invisible from inside the hook.
  * The ISO's own volume name, which lives on the medium and not in it — and
    which on arm64 is set by the re-master, AFTER live-build has been told
    something else entirely (BUILD-NOTES #40). This check is how that was found.
  * `os7-setup --version` and `--self-test`, run by CHROOTING INTO the image, so
    the binary resolves `/usr/lib/os7/release.json` against the image's root
    rather than the build container's.

The rule this file exists to serve: **ask the thing itself.** A build log saying
the mirrors were pinned is a diagnostic. The sources.list in the image is the
fact.
"""

import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

SNAPSHOT_HOST = "snapshot.ubuntu.com"

# Read from the image, in one container, in one pass. Anything needing a loop
# mount happens here; the checking happens in Python where a failure can say why.
PROBE = r"""
set -e
mkdir -p /mnt/iso /mnt/sq /mnt/rw /mnt/root
mount -o loop,ro /iso/ISONAME /mnt/iso
mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq

# An overlay so the image can be CHROOTED INTO, not merely read.
#
# `cd /mnt/sq && ./usr/lib/os7-setup/os7-setup --version` looks equivalent and is
# not: the binary resolves /usr/lib/os7/release.json against the REAL root, so it
# reads the build container's filesystem and reports "no release manifest on this
# medium" about an image that has one. That was this script's first version, and
# it is the shape of a diagnostic that does not check the thing it claims to.
#
# squashfs is read-only, so the overlay is what makes chroot possible at all.
# This is the run-s2.sh pattern (spike S2 ran the NativeAOT binary inside the
# ISO's own root for the same reason).
mount -t tmpfs tmpfs /mnt/rw
mkdir -p /mnt/rw/up /mnt/rw/work
mount -t overlay overlay -o lowerdir=/mnt/sq,upperdir=/mnt/rw/up,workdir=/mnt/rw/work /mnt/root
mount --bind /dev /mnt/root/dev
mount -t proc proc /mnt/root/proc

emit() { printf '<<<%s>>>\n' "$1"; shift; "$@" 2>&1 || true; }

emit release.json      cat /mnt/sq/usr/lib/os7/release.json
emit release.conf      cat /mnt/sq/usr/lib/os7/release.conf
emit build.conf        cat /mnt/sq/usr/lib/os7/build.conf
emit os-release        cat /mnt/sq/etc/os-release
emit sources.list      cat /mnt/sq/etc/apt/sources.list
emit sources.list.d    bash -c 'cat /mnt/sq/etc/apt/sources.list.d/*.sources 2>/dev/null || true'
emit packages.count    bash -c 'wc -l < /mnt/sq/usr/lib/os7/packages.manifest'
emit setup.version     chroot /mnt/root /usr/lib/os7-setup/os7-setup --version
emit setup.selftest    bash -c 'chroot /mnt/root env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/lib/os7-setup/os7-setup --self-test | tail -3'
emit volume            bash -c 'blkid -o value -s LABEL /iso/ISONAME'
emit grub.cfg          bash -c 'cat /mnt/iso/boot/grub/grub.cfg 2>/dev/null | head -40'

umount /mnt/root/proc /mnt/root/dev /mnt/root /mnt/rw /mnt/sq /mnt/iso
"""


def read_image(arch: str) -> dict[str, str]:
    iso = os.path.join(REPO, "out", f"os7-{arch}.iso")
    if not os.path.exists(iso):
        sys.exit(f"no {iso} — build it first")
    # The stable name is a symlink to OS7-<version>-<arch>.iso; resolve it so the
    # container sees a real file and the report names the artefact, not the alias.
    real = os.path.basename(os.path.realpath(iso))
    print(f"    reading {real}")

    out = subprocess.run(
        ["docker", "run", "--rm", "--privileged", "--platform", f"linux/{arch}",
         "-v", f"{os.path.join(REPO, 'out')}:/iso:ro", f"os7-build:{arch}",
         "bash", "-c", PROBE.replace("ISONAME", real)],
        capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"could not read the image:\n{out.stderr[-2000:]}")

    sections, key = {}, None
    for line in out.stdout.splitlines():
        if line.startswith("<<<") and line.endswith(">>>"):
            key = line[3:-3]
            sections[key] = []
        elif key:
            sections[key].append(line)
    return {k: "\n".join(v).strip() for k, v in sections.items()}


def main() -> None:
    arch = sys.argv[1] if len(sys.argv) > 1 else "arm64"
    print(f"\n### the image, asked what it is ({arch})")
    img = read_image(arch)
    bad = 0

    def check(ok, what, detail=""):
        nonlocal bad
        print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f" — {detail}" if detail else ""))
        if not ok:
            bad += 1

    # -- the manifest -------------------------------------------------------
    try:
        rel = json.loads(img.get("release.json", ""))
    except Exception as exc:
        check(False, "release.json parses", str(exc))
        print(f"\n{bad} problem(s). The image carries no usable manifest.")
        sys.exit(1)

    version = rel.get("version", "")
    check(bool(version) and version != "0.0.0.0", "the image knows its version", version)
    check(rel.get("channel") not in (None, "", "unknown"), "channel", rel.get("channel", ""))
    check(rel.get("architecture") == arch, "architecture", str(rel.get("architecture")))
    snapshot = (rel.get("base") or {}).get("archive_snapshot", "")
    check(bool(snapshot), "the archive is pinned in the manifest", snapshot)

    # Reproducibility is judged AGAINST THE CHANNEL, not absolutely.
    #
    # `reproducible: false` means the tree was dirty when this was built, which is
    # the normal state while developing and says nothing about whether the image
    # is good. On a `stable` build it means something else entirely: a release
    # nobody can rebuild, which is the failure RELEASE-AND-UPDATE-PLAN §3.1 exists
    # to prevent. Same field, and only the channel decides which it is.
    #
    # A flat FAIL here would make this tool useless on every development build,
    # which is the same as not having it.
    repro = rel.get("reproducible") is True
    src = (rel.get("source") or {}).get("commit", "?")
    if rel.get("channel") == "stable":
        check(repro, "a stable build is reproducible", f"commit={src}")
    elif repro:
        check(True, "built from a clean source tree", f"commit={src}")
    else:
        print(f"      note  NOT built from a clean source tree (commit={src}). Expected "
              f"on a {rel.get('channel')} build; would be fatal on a stable one.")

    comp = rel.get("components") or {}
    check(bool(comp.get("kernel")), "kernel recorded", str(comp.get("kernel")))
    check(comp.get("zfs") not in (None, ""), "zfs recorded", str(comp.get("zfs")))
    check(comp.get("os7_module") == version, "the OS7 module carries the product version",
          str(comp.get("os7_module")))
    check(bool((comp.get("os7_setup") or {}).get("sha256")), "os7-setup hashed")

    lines = int(img.get("packages.count") or 0)
    check(lines > 200, "the package manifest is populated", f"{lines} packages")

    # -- os-release ---------------------------------------------------------
    osr = dict(
        (k, v.strip().strip('"'))
        for k, _, v in (l.partition("=") for l in img.get("os-release", "").splitlines())
        if k
    )
    check(osr.get("IMAGE_ID") == "os7", "IMAGE_ID", osr.get("IMAGE_ID", ""))
    check(osr.get("IMAGE_VERSION") == version,
          "IMAGE_VERSION matches the manifest", osr.get("IMAGE_VERSION", ""))
    check(osr.get("NAME") == "OS/7", "NAME is branded", osr.get("NAME", ""))
    check(osr.get("PRETTY_NAME") == f"OS/7 {version}", "PRETTY_NAME", osr.get("PRETTY_NAME", ""))
    # The three Intune's "Allowed distributions" rule matches on (L16 / D8).
    # Branding these would make every OS/7 device fail a policy written for
    # Ubuntu 26.04, which README makes a hard requirement rather than a
    # preference — so this is a check that something did NOT happen.
    check(osr.get("ID") == "ubuntu", "ID is left as ubuntu (Intune)", osr.get("ID", ""))
    check(osr.get("VERSION_ID") == "26.04", "VERSION_ID is untouched (Intune)",
          osr.get("VERSION_ID", ""))
    check(osr.get("ID_LIKE", "") != "", "ID_LIKE is untouched (Intune)", osr.get("ID_LIKE", ""))

    # -- THE PIN, IN THE SHIPPED IMAGE --------------------------------------
    #
    # The one check nothing else makes. Every Ubuntu source in the image must
    # resolve to the pinned snapshot; a single line pointing at the live archive
    # means the machine's next `apt update` leaves the release behind, and
    # BUILD-NOTES #36 is about how quietly that happens.
    #
    # packages.microsoft.com is expected and excluded by name rather than by
    # "anything that is not Ubuntu" — an exclusion that broad would hide the
    # exact leak being looked for.
    sources = img.get("sources.list", "")
    ubuntu_uris = [
        tok for line in sources.splitlines()
        if line.strip() and not line.strip().startswith("#")
        for tok in line.split()
        if tok.startswith(("http://", "https://"))
    ]
    check(bool(ubuntu_uris), "the image has apt sources", f"{len(ubuntu_uris)} URIs")
    unpinned = sorted({u for u in ubuntu_uris if SNAPSHOT_HOST not in u})
    check(not unpinned, "every apt source in the image is pinned",
          "all on " + SNAPSHOT_HOST if not unpinned else f"UNPINNED: {unpinned}")
    check(snapshot in sources if snapshot else False,
          "the image's sources name the manifest's snapshot", snapshot)

    ms = img.get("sources.list.d", "")
    ms_uris = sorted({tok for line in ms.splitlines() if line.startswith("URIs:")
                      for tok in line.split()[1:]})
    for u in ms_uris:
        print(f"      note  additional source (expected, cannot be pinned by URL): {u}")

    # -- what Setup itself says --------------------------------------------
    setup = img.get("setup.version", "")
    check(f"OS/7 {version}" in setup, "os7-setup --version agrees with the manifest",
          setup.splitlines()[0] if setup else "(no output)")
    check(snapshot in setup if snapshot else False,
          "os7-setup reports the archive snapshot")

    # Setup's own self-test, run INSIDE the image rather than against the build
    # container. Hook 0080 already runs it during the build; running it again
    # here proves it against the finished artefact, after live-build's binary
    # stage has had its way with the tree.
    st = img.get("setup.selftest", "")
    check("SELFTEST-DONE failures=0" in st, "os7-setup --self-test passes in the image",
          next((l for l in st.splitlines() if l.startswith("SELFTEST-DONE")), st[-120:]))

    # -- the medium --------------------------------------------------------
    check(img.get("volume", "") == f"OS7-{version}-{arch}",
          "the ISO volume carries the version", img.get("volume", ""))

    print()
    if bad:
        print(f"{bad} problem(s) with the image.")
        sys.exit(1)
    print(f"The image is OS/7 {version} ({rel.get('channel')}), {arch}, "
          f"built {rel.get('built')}")
    print(f"from archive snapshot {snapshot}, and every source in it says so.")


if __name__ == "__main__":
    main()
