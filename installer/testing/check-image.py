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
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import os7version

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
# The identity as a PERSON meets it (docs/IDENTITY-PLAN.md §6). None of these is
# derivable from os-release: the product line is OS/7's own file precisely so
# that no user-facing surface depends on a field Microsoft's agents also read
# (I1), and what is executable in update-motd.d is a property of the filesystem.
emit product           cat /mnt/sq/usr/lib/os7/product
emit issue             cat /mnt/sq/etc/issue
emit issue.net         cat /mnt/sq/etc/issue.net
emit motd.d            bash -c 'cd /mnt/sq/etc/update-motd.d 2>/dev/null && for f in *; do [ -f "$f" ] && printf "%s %s\n" "$f" "$(stat -c %A "$f")"; done || true'
emit motd-news         bash -c 'cat /mnt/sq/etc/default/motd-news 2>/dev/null || true'
emit sources.list      cat /mnt/sq/etc/apt/sources.list
emit sources.list.d    bash -c 'cat /mnt/sq/etc/apt/sources.list.d/*.sources 2>/dev/null || true'
emit packages.count    bash -c 'wc -l < /mnt/sq/usr/lib/os7/packages.manifest'
# The membership decisions, read out of the SHIPPED manifest. Two of them were
# made on a dependency graph and one of them was wrong about what installs the
# kernel (BUILD-NOTES #62), so they are asked of the artefact from now on.
emit packages.curated  bash -c "grep -E '^(dotnet|aspnetcore|linux-(generic|image-generic|headers|main-modules-zfs))' /mnt/sq/usr/lib/os7/packages.manifest | cut -f1 | sort || true"
emit setup.version     chroot /mnt/root /usr/lib/os7-setup/os7-setup --version
emit setup.selftest    bash -c 'chroot /mnt/root env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin /usr/lib/os7-setup/os7-setup --self-test | tail -3'

# THE BASH THE INSTALLER GENERATES, CHECKED AS BASH.
#
# os7-setup builds shell scripts and runs them in a chroot on the target. They
# are C# interpolated raw strings, so a brace in the shell collides with an
# interpolation hole and a '$' can be eaten by a quoting layer - both of which
# produce a script that COMPILES FINE and fails halfway through an install.
#
# One such bug shipped into an ISO on 2026-08-24: a /etc/shadow check whose '$'
# the shell consumed, inverting it into "the password field is empty". It would
# have failed every install, and it was found by reading the generated script.
#
# --dry-run writes every script it would run into the log, so this asks the
# SHIPPED binary for them and runs `bash -n` over each - against the image's own
# bash, which is the one that would have run them.
cat > /tmp/p.json <<'PLAN'
{"version":1,"intent":"Install","language":"en_US.UTF-8","keyboard":"us",
 "timezone":"UTC","mode":"Headless",
 "storage":{"disk":"/dev/disk/by-id/checkimage","layout":"single","efiMiB":512,
            "bpoolGiB":2,"encrypt":true,"swap":"zram"},
 "account":{"hostname":"checkimage","username":"checker","fullName":"Check"},
 "network":{"interface":"auto","kind":"Wired","method":"Static",
            "address":"10.0.2.99/24","gateway":"10.0.2.2",
            "nameservers":["10.0.2.3"],"search":["corp.example.com"]}}
PLAN
printf '%s' 'check-image-passphrase' > /tmp/p.pass
printf '%s' 'check-image-password'   > /tmp/p.pw
cp /tmp/p.json /tmp/p.pass /tmp/p.pw /mnt/root/tmp/ 2>/dev/null || true
chroot /mnt/root /usr/lib/os7-setup/os7-setup --unattend /tmp/p.json     --passphrase-file /tmp/p.pass --password-file /tmp/p.pw --dry-run     >/dev/null 2>&1 || true
emit setup.dryrun      bash -c 'cat /mnt/root/var/log/os7-setup/setup.log 2>/dev/null || true'

# THE SAME PLAN AGAIN, WITH mode=Gui.
#
# Until 2026-08-25 this file only ever ran the Headless branch, and nothing else
# reached the other one either: InstallPlan.Mode defaults to Headless and arm64
# forces it. So InstallModeStep's GUI script - the one that decides whether an
# amd64 desktop install actually comes up on a desktop - had never been parsed
# by any bash, on any host, ever. An unrun branch is not a working branch, and
# this is the cheapest place that can say so: no VM, no install, just the
# SHIPPED binary asked what it would do.
#
# The log is removed first because the second run appends to the same ring.
sed 's/"mode":"Headless"/"mode":"Gui"/' /tmp/p.json > /tmp/p.gui.json
cp /tmp/p.gui.json /mnt/root/tmp/ 2>/dev/null || true
rm -f /mnt/root/var/log/os7-setup/setup.log
chroot /mnt/root /usr/lib/os7-setup/os7-setup --unattend /tmp/p.gui.json --passphrase-file /tmp/p.pass --password-file /tmp/p.pw --dry-run >/dev/null 2>&1 || true
emit setup.dryrun.gui  bash -c 'cat /mnt/root/var/log/os7-setup/setup.log 2>/dev/null || true'
# THE Zfs MODULE'S SELF-TEST, run against the SHIPPED module and the recorded
# ZFS output shipped beside it (docs/ZFS-POWERSHELL-PLAN.md Z10).
#
# It cannot live in build hook 0060. A live-build hook may import a module by
# path and list its exports, but calling a function that needs a bundled cmdlet
# — Get-Content, ConvertFrom-Json — fails there, and BUILD-NOTES #38 is the
# measurement. This chroot is an overlay with /dev bound, which is the
# environment where #38 saw those cmdlets work.
#
# Because that environment is the one #38 says not to build on, the result is
# read in two parts: whether PowerShell got as far as producing a verdict at
# all, and what the verdict was. Only the second one can fail the image.
chroot /mnt/root env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /usr/bin/pwsh -NoProfile -NonInteractive -Command 'Import-Module /usr/local/share/powershell/Modules/Zfs/Zfs.psd1 -Force; Test-ZfsModule' >/tmp/zfs.txt 2>&1 && rc=0 || rc=$?
echo "EXIT=$rc" >> /tmp/zfs.txt
emit zfs.selftest      bash -c 'tail -30 /tmp/zfs.txt'

# THE BACKUP LAYER'S SELF-TEST, in the same chroot and read the same way
# (docs/BACKUP-PLAN.md §9). Offline: it exercises the guard that keeps a
# snapshot policy away from the boot environments, the sanoid.conf renderer, the
# path-to-dataset resolution and the syncoid command line — none of which needs
# ZFS, sanoid or a disk.
chroot /mnt/root env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /usr/bin/pwsh -NoProfile -NonInteractive -Command 'Import-Module /usr/local/share/powershell/Modules/OS7/OS7.psd1 -Force; Test-OS7Backup' >/tmp/backup.txt 2>&1 && rc=0 || rc=$?
echo "EXIT=$rc" >> /tmp/backup.txt
emit backup.selftest   bash -c 'tail -30 /tmp/backup.txt'

# The three facts about backups that are properties of the IMAGE rather than of
# any program: the two binaries are there, the defaults file OS/7 reads its
# legal-key list out of is there, and no policy has been baked in.
emit backup.files      bash -c 'for f in /mnt/root/usr/sbin/sanoid /mnt/root/usr/sbin/syncoid /mnt/root/usr/share/sanoid/sanoid.defaults.conf /mnt/root/usr/libexec/os7-backup-replicate /mnt/root/usr/libexec/os7-backup-firstboot /mnt/root/usr/lib/systemd/system/os7-backup-replicate.timer; do [ -s "$f" ] && echo "ok $f" || echo "MISSING $f"; done; for f in /mnt/root/etc/sanoid/sanoid.conf /mnt/root/etc/os7/backup.json; do [ -e "$f" ] && echo "BAKED-IN $f" || echo "absent $f"; done'

# THE GENERATOR THAT QUIETENS THE SETUP MEDIUM, run out of the SHIPPED image.
#
# Hook 0070 checks all of this during the build. This checks it again on the
# artefact, and the two are not the same question: includes.chroot files have
# been dropped between the chroot and the binary stage before, and a generator
# without its executable bit is skipped by systemd in complete silence.
# BUILD-NOTES #79, and the same argument as the pin check above.
#
# The gate is exercised rather than read - against a copy with /proc/cmdline
# substituted for a file, and the substitution is counted, so the thing under
# test cannot quietly be a different program (BUILD-NOTES #66).
cat > /tmp/quiesce.sh <<'QSH'
G=/mnt/sq/usr/lib/systemd/system-generators/os7-setup-quiesce
[ -s "$G" ] || { echo "MISSING $G"; exit 0; }
echo "mode $(stat -c %a "$G")"
echo "units $(sed -n '/^UNITS="/,/^"$/p' "$G" | grep -cE '[A-Za-z0-9@._-]+\.(service|socket|timer|path)$')"
if sh -n "$G" 2>/dev/null; then echo "parses"; else echo "PARSE-ERROR"; fi
W=$(mktemp -d)
sed "s#/proc/cmdline#$W/cmdline#g" "$G" > "$W/gen"
chmod 0755 "$W/gen"
echo "substituted $(diff "$G" "$W/gen" | grep -c '^>')"
gate() {
    rm -rf "$W/early"; mkdir -p "$W/early"
    printf '%s\n' "$2" > "$W/cmdline"
    "$W/gen" "$W/n" "$W/early" "$W/l" >/dev/null 2>&1 || true
    echo "gate.$1 $(find "$W/early" -maxdepth 1 -type l | wc -l) $(readlink "$W/early/unattended-upgrades.service" 2>/dev/null || echo none)"
}
gate install "BOOT_IMAGE=/casper/vmlinuz boot=casper os7.setup=1 quiet"
gate live    "BOOT_IMAGE=/casper/vmlinuz boot=casper quiet splash"
gate trap    "BOOT_IMAGE=/casper/vmlinuz noos7.setup=10 quiet"
QSH
emit quiesce           bash /tmp/quiesce.sh

# WHAT THE IMAGE WOULD DO TO THE CONSOLE LOGLEVEL. `loglevel=0` on the Install
# entry is undone by this file, which is the second half of BUILD-NOTES #79 and
# the reason os7-setup takes console_loglevel itself. Read here so that a future
# image which stops shipping it is noticed rather than assumed.
emit printk.sysctl     bash -c 'grep -rh "kernel.printk" /mnt/sq/usr/lib/sysctl.d/ /mnt/sq/etc/sysctl.d/ 2>/dev/null || echo "(none)"'

# THE ZFS ARC's CEILING AS THE IMAGE LEAVES IT. No modprobe.d options at all is
# the measured state and is exactly why InstallerEnvironmentStep exists; if a
# later image starts shipping one, the step and the file have to be reconciled.
emit zfs.modprobe      bash -c 'grep -rh "zfs" /mnt/sq/etc/modprobe.d/ /mnt/sq/usr/lib/modprobe.d/ 2>/dev/null || echo "(none)"'

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


def bash_syntax(text: str) -> str:
    """`bash -n` over a script, returning "" when it parses or the first error.

    ON STDIN, NOT IN A FILE. `bash -n <path>` needs a path bash can open, and
    on Windows `tempfile` produces one it cannot — every generated script came
    back "No such file or directory", which reads as seven broken scripts and
    is one broken harness. Nothing here needs a file: the text is in hand.
    """
    # BYTES, NOT text=True. On Windows, Python opens the pipe in text mode and
    # turns every newline into CR-LF on the way out, so bash receives a script
    # whose every line ends in a carriage return and reports a syntax error
    # near an unexpected token, about seven scripts that are all fine. Same
    # family as BUILD-NOTES #70, arriving through a different door: the
    # encoding here is the only place that can decide it.
    rc = subprocess.run(["bash", "-n"], input=text.encode("utf-8"),
                        capture_output=True)
    if rc.returncode == 0:
        return ""
    err = rc.stderr.decode("utf-8", "replace").strip().splitlines()
    return err[0] if err else f"bash -n exited {rc.returncode}"


def generated_scripts(log: str) -> dict[str, list[str]]:
    """Pull each chroot script out of a --dry-run log.

    TargetRoot.Chroot logs "would chroot into <root> for: <what>" and then every
    line of the script prefixed with "    | ". Parsed rather than regenerated,
    so what is checked is what the SHIPPED binary would run.
    """
    scripts: dict[str, list[str]] = {}
    name: str | None = None
    cur: list[str] = []
    for line in log.splitlines():
        m = re.search(r"would chroot into \S+ for: (.+)$", line)
        if m:
            if name:
                scripts[name] = cur
            name, cur = m.group(1), []
            continue
        m = re.match(r"^.*INFO      \|(.*)$", line)
        if m and name is not None:
            cur.append(m.group(1))
        elif name is not None and " INFO " in line:
            scripts[name] = cur
            name, cur = None, []
    if name:
        scripts[name] = cur
    return scripts


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

    # The BUILD field, checked SEPARATELY — because "1.0.0.0" passes the line
    # above while meaning the build could not read the repository at all. Every
    # ISO built from a git WORKTREE carried exactly that until 2026-08-24, and
    # this tool looked straight at one and reported that the image knew its
    # version (BUILD-NOTES #43).
    #
    # BUILD is `git rev-list --count HEAD` (§3.3), which is at least 1 for any
    # repository that has a commit — so 0 is the "could not tell" value and can
    # never be a release. The commit is checked alongside it because build.sh
    # sets the two together: one without the other means they came from two
    # different places.
    build_field = version.split(".")[-1] if version.count(".") == 3 else ""
    commit = (rel.get("source") or {}).get("commit", "")
    check(build_field not in ("", "0") and commit not in ("", "unknown"),
          "the image knows what source it was built from",
          f"BUILD={build_field or '?'} commit={commit or '?'}")
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
    src = commit or "?"
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

    # -- what the image is CURATED to contain, and not to ---------------------
    #
    # CURATION-AND-DELIVERY-PLAN C2 (the .NET SDK leaves, the runtime stays) and
    # §4.2 (kernel headers leave, the prebuilt ZFS module must not). Both were
    # decided on the pinned archive's dependency graph, and §4.2's first attempt
    # changed nothing at all because live-build installs a kernel of its own
    # beside the package list — BUILD-NOTES #62. A graph is a prediction; this is
    # the artefact.
    curated = set((img.get("packages.curated") or "").split())
    check(not any(p.startswith("dotnet-sdk") for p in curated),
          "no .NET SDK in the image (C2)",
          " ".join(sorted(p for p in curated if p.startswith("dotnet-sdk"))) or "none")
    check({"dotnet-runtime-10.0", "aspnetcore-runtime-10.0"} <= curated,
          "the .NET runtime is in the image (C2)")
    check(not any(p.startswith("linux-headers") for p in curated),
          "no kernel headers in the image (§4.2)",
          " ".join(sorted(p for p in curated if p.startswith("linux-headers"))) or "none")
    check("linux-generic" not in curated,
          "linux-generic is gone, so nothing pulls the headers back (#62)")
    check("linux-image-generic" in curated, "linux-image-generic is the kernel")
    # THE ONE THAT COULD HAVE MADE THE MACHINE UNBOOTABLE. The prebuilt ZFS
    # module hangs off linux-image-generic, not off linux-generic — asserted
    # here rather than believed.
    check(any(p.startswith("linux-main-modules-zfs") for p in curated),
          "the prebuilt ZFS module survived the kernel swap (§4.2)",
          " ".join(sorted(p for p in curated if p.startswith("linux-main-modules-zfs"))))

    # -- os-release ---------------------------------------------------------
    osr = dict(
        (k, v.strip().strip('"'))
        for k, _, v in (l.partition("=") for l in img.get("os-release", "").splitlines())
        if k
    )
    product = os7version.product(version, rel.get("channel", ""))

    check(osr.get("IMAGE_ID") == "os7", "IMAGE_ID", osr.get("IMAGE_ID", ""))
    # FOUR FIELDS here and THREE in PRETTY_NAME below — this identifies, that
    # describes (docs/IDENTITY-PLAN.md §5.2). Checking both against the same
    # manifest is what makes the pair meaningful rather than two loose strings.
    check(osr.get("IMAGE_VERSION") == version,
          "IMAGE_VERSION is the manifest's four-field version",
          osr.get("IMAGE_VERSION", ""))
    check(osr.get("PRETTY_NAME") == product,
          "PRETTY_NAME is the friendly form", osr.get("PRETTY_NAME", ""))
    # And the invariant the two forms exist to keep: one names the other's
    # release. If this ever fails, the machine is quoting two different builds.
    check(version.startswith(os7version.friendly(version) or "")
          and os7version.friendly(version) in osr.get("PRETTY_NAME", ""),
          "the two forms name the same release",
          f'{osr.get("PRETTY_NAME", "")} / {osr.get("IMAGE_VERSION", "")}')

    # THE FIELDS THAT MUST NOT BE BRANDED. Checks that something did NOT happen.
    #
    # NAME IS ON THIS LIST SINCE 2026-08-26 AND USED TO BE ON THE OTHER ONE.
    # BUILD-NOTES #80: Microsoft's Azure Arc onboarding script reads NAME,
    # matches it against `*buntu*` and exits 133 otherwise — it never reads ID.
    # The glob is asserted rather than the literal "Ubuntu", because the glob is
    # the actual contract and a literal check would be checking the wrong thing.
    check("buntu" in osr.get("NAME", ""),
          "NAME still matches Arc's *buntu* glob (BUILD-NOTES #80)", osr.get("NAME", ""))
    check(osr.get("ID") == "ubuntu", "ID is left as ubuntu (Intune)", osr.get("ID", ""))
    check(osr.get("VERSION_ID") == "26.04", "VERSION_ID is untouched (Intune)",
          osr.get("VERSION_ID", ""))
    check(osr.get("ID_LIKE", "") != "", "ID_LIKE is untouched (Intune)", osr.get("ID_LIKE", ""))
    check("26.04" in osr.get("VERSION", ""), "VERSION is untouched", osr.get("VERSION", ""))
    check(osr.get("VERSION_CODENAME", "") == "resolute", "VERSION_CODENAME is untouched",
          osr.get("VERSION_CODENAME", ""))

    # The branded extras. SUPPORT_URL and BUG_REPORT_URL matter more than they
    # look: leaving Ubuntu's is worse than leaving them unset, because it sends
    # OS/7's bug reports to Canonical.
    for field in ("HOME_URL", "SUPPORT_URL", "BUG_REPORT_URL", "DOCUMENTATION_URL"):
        check("upinblue" in osr.get(field, ""), f"{field} points at OS/7",
              osr.get(field, "(unset)"))
    check(osr.get("LOGO", "") == "os7", "LOGO", osr.get("LOGO", ""))
    check(osr.get("PRIVACY_POLICY_URL", "") == "",
          "PRIVACY_POLICY_URL is gone — Ubuntu's does not describe this system",
          osr.get("PRIVACY_POLICY_URL", ""))

    # -- the banners (IDENTITY-PLAN §6.1, §6.2) ------------------------------
    check(img.get("product", "").strip() == product,
          "/usr/lib/os7/product carries the product line", img.get("product", "").strip())

    issue = img.get("issue", "")
    check(issue.startswith(product), "/etc/issue names the product", issue.splitlines()[:1])
    # agetty's escapes, and they must be LITERAL backslashes in the file. A
    # console that greets you with a stray "OS/7 1.0.0 (development) n l" is
    # what a printf that expanded them looks like.
    check("\\n" in issue and "\\l" in issue,
          "/etc/issue keeps agetty's \\n and \\l unexpanded", repr(issue))

    net = img.get("issue.net", "").strip()
    check(net == "OS/7",
          "/etc/issue.net names the product and NOTHING else — it is shown "
          "before authentication", net)

    # -- the MOTD (IDENTITY-PLAN §6.1, I9) -----------------------------------
    #
    # Read off the artefact because the hook cannot know what it will find:
    # which drop-ins Ubuntu ships in this image has never been measured (IL10),
    # so the hook enumerates and this checks the result.
    motd = [l.split() for l in img.get("motd.d", "").splitlines() if l.strip()]
    executable = sorted(name for name, mode in motd if "x" in mode)
    check(executable == ["00-os7-header"] or executable == ["00-os7-header", "98-reboot-required"],
          "only OS/7's header and the reboot notice run at login",
          " ".join(executable) or "(none)")
    check(any(name == "00-os7-header" and "x" in mode for name, mode in motd),
          "00-os7-header is executable")
    # The one that makes a network request at login.
    news = img.get("motd-news", "")
    check("ENABLED=1" not in news, "motd-news does not fetch at login",
          news.strip() or "(no /etc/default/motd-news)")

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

    # -- the bash the installer generates -----------------------------------
    scripts = generated_scripts(img.get("setup.dryrun", ""))
    if not scripts:
        check(False, "the installer's generated scripts could be read",
              "--dry-run produced no chroot scripts")
    else:
        bad_scripts = []
        for name, body in scripts.items():
            err = bash_syntax("#!/bin/bash\nset -euo pipefail\n" + "\n".join(body) + "\n")
            if err:
                bad_scripts.append(f"{name}: {err}")
        check(not bad_scripts,
              f"all {len(scripts)} generated chroot scripts are valid bash",
              "; ".join(bad_scripts) if bad_scripts else ", ".join(scripts))

        # -- the GUI branch of screen 8, which nothing used to reach ---------
        #
        # InstallModeStep has two branches and only the headless one was ever
        # generated here, so the branch that has to hold for "install WITH a
        # desktop" went unparsed and unchecked. It is asked of the SHIPPED
        # binary in a second --dry-run and checked for the two things it owes:
        # that it is valid bash, and that it PROVES its result instead of
        # assuming it. amd64 only - arm64 is server-only and never offers it.
        if arch == "amd64":
            gui = generated_scripts(img.get("setup.dryrun.gui", ""))
            gui_body = "\n".join(gui.get("graphical target", []))
            check(bool(gui_body), "the GUI branch of the mode step is generated",
                  ", ".join(gui) if gui else "no 'graphical target' script in the GUI dry-run")
            if gui_body:
                err = bash_syntax("#!/bin/bash\nset -euo pipefail\n" + gui_body + "\n")
                check(not err, "the GUI mode script is valid bash", err or "bash -n")
                proves = ("systemctl get-default" in gui_body
                          and "display-manager.service" in gui_body
                          and "exit 1" in gui_body)
                check(proves, "the GUI mode script proves its own result",
                      "reads back the default target and the display manager, "
                      "and fails the install on either")

        # Phase 3b. Both halves of L23's mitigation have to be in the SHIPPED
        # binary's own output: netplan is useless on this image unless something
        # also enables systemd-networkd, and the only thing that does is
        # NetworkStep.
        for want in ("netplan", "networkd"):
            check(want in scripts, f"the installer generates a '{want}' step",
                  ", ".join(scripts))

    # -- the netplan file's MODE, from the shipped binary --------------------
    #
    # L25: the file holds the Wi-Fi passphrase or the 802.1X password in
    # plaintext, because that is netplan's design. 0600 is the whole mitigation,
    # so it is asserted against what os7-setup says it would write rather than
    # against the source. A chmod that quietly stopped happening has no symptom
    # until somebody reads a passphrase off a running machine.
    dry = img.get("setup.dryrun", "")
    netplan_write = next(
        (l for l in dry.splitlines() if "etc/netplan/01-os7-network.yaml" in l), "")
    check("mode 0600" in netplan_write,
          "the netplan file would be written 0600 (L25)",
          netplan_write.split("would write ", 1)[-1] if netplan_write else "not written")

    # -- the Zfs module, asked to check itself ------------------------------
    #
    # Two questions, and only the second may fail an image. "PowerShell never
    # produced a verdict" is a property of this chroot (BUILD-NOTES #38), not of
    # the image; "the verdict was FAIL" is a property of the image. Hook 0075
    # already draws this line and #38 records what it saved.
    zt = img.get("zfs.selftest", "")
    ran = "Zfs self-test:" in zt
    exit0 = "EXIT=0" in zt
    if not ran:
        print("      note  the Zfs self-test produced no verdict in this chroot "
              "(BUILD-NOTES #38). Run ./installer/testing/run-zfs.py test — a "
              "booted VM is where this is authoritative.")
    else:
        summary = next((l.strip() for l in zt.splitlines()
                        if l.strip().startswith("Zfs self-test:")
                        and "passed" in l), "")
        detail = summary or next(
            (l.strip() for l in zt.splitlines() if "FAILED:" in l), "")
        check(exit0, "the Zfs module parses the ZFS output it ships with", detail)

    # -- the backup layer ---------------------------------------------------
    #
    # Read exactly like the Zfs one above, and for the same reason: "PowerShell
    # said nothing in this chroot" is a property of the chroot, and only "the
    # verdict was FAIL" may fail an image.
    bt = img.get("backup.selftest", "")
    bran = "OS/7 Backup self-test:" in bt
    if not bran:
        print("      note  the backup self-test produced no verdict in this chroot "
              "(BUILD-NOTES #38). Run ./installer/testing/run-backup.py test.")
    else:
        bsummary = next((l.strip() for l in bt.splitlines()
                         if l.strip().startswith("OS/7 Backup self-test:")
                         and "passed" in l), "")
        bdetail = bsummary or next(
            (l.strip() for l in bt.splitlines() if "FAILED:" in l), "")
        check("EXIT=0" in bt,
              "the backup layer's guards and renderer behave as designed", bdetail)

    # The image's own share of the backup feature, which no self-test can see:
    # what is on the medium. THE ABSENCES MATTER AS MUCH AS THE PRESENCES — a
    # sanoid.conf baked into the image would start snapshotting on the live
    # medium, against datasets only an installed machine has.
    bf = img.get("backup.files", "")
    missing = [l.split(None, 1)[1] for l in bf.splitlines() if l.startswith("MISSING ")]
    baked = [l.split(None, 1)[1] for l in bf.splitlines() if l.startswith("BAKED-IN ")]
    check(not missing, "sanoid, syncoid and the OS/7 backup units are in the image",
          "; ".join(missing))
    check(not baked, "no backup policy is baked into the image (it is written on first boot)",
          "; ".join(baked))

    # -- the setup medium's quiesce generator (BUILD-NOTES #79) -------------
    #
    # The install this exists for died because the medium was running a
    # desktop's background workload while ZFS was being handed a disk. Three
    # things have to be true of the artefact, and the third is the one that
    # cannot be read off a source tree: the gate must actually gate.
    q = img.get("quiesce", "")
    qline = dict(
        (parts[0], parts[1:])
        for parts in (l.split() for l in q.splitlines()) if parts
    )
    check("MISSING" not in q and qline.get("mode", [""])[0] == "755",
          "the quiesce generator is in the image and executable",
          f"mode {qline.get('mode', ['absent'])[0]}")
    check("parses" in q, "the quiesce generator parses as sh")
    n_units = int((qline.get("units") or ["0"])[0])
    check(n_units >= 40, "the quiesce generator names a real unit list",
          f"{n_units} units")
    check((qline.get("substituted") or ["0"])[0] == "1",
          "the copy under test is the generator plus one path (#66)")

    def gate(name: str) -> tuple[int, str]:
        v = qline.get(f"gate.{name}")
        return (int(v[0]), v[1]) if v and len(v) > 1 else (-1, "?")

    masked, target = gate("install")
    check(masked == n_units and target == "/dev/null",
          "os7.setup=1 masks the whole list, to /dev/null",
          f"{masked} of {n_units} -> {target}")
    check(gate("live")[0] == 0,
          "the LIVE entry is untouched (L14: try before you install)",
          f"{gate('live')[0]} masked")
    # `grep os7.setup=1` matches "noos7.setup=10". Taking cron and snapd away
    # from a session nobody asked to install from is the failure that would
    # never be looked for.
    check(gate("trap")[0] == 0,
          "a command line that merely CONTAINS the token masks nothing",
          f"{gate('trap')[0]} masked")

    # The two image facts the fix is built on, recorded rather than assumed.
    # Neither fails an image: they are what a later image would have to change
    # for the reasoning in #79 to stop holding.
    pk = img.get("printk.sysctl", "")
    print(f"      note  the image sets the console loglevel: "
          f"{pk.splitlines()[0] if pk else '(nothing)'} — os7-setup overrides it "
          f"while it owns the console (#79)")
    zm = img.get("zfs.modprobe", "").strip()
    if zm and zm != "(none)":
        print(f"      note  ZFS module options shipped in the image: {zm}")
    else:
        print("      note  the image ships no ZFS module options, so zfs_arc_max is "
              "the default half of memory — InstallerEnvironmentStep caps it at "
              "install time (#79)")

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
