#!/usr/bin/env python3
"""
OS/7's own package repository, checked by INSTALLING FROM IT.

    ./installer/testing/check-os7-repo.py [--arch amd64] [--keep]

WHAT THIS IS. CURATION-AND-DELIVERY-PLAN.md C7 turned the OS/7 half of the
product into .debs in a signed repository. This builds that repository and then
does the only thing that can say whether it works: it takes a plain Ubuntu
container, points apt at the repository, and asks apt to make it an OS/7
machine. Every claim below is read back off the resulting filesystem.

It needs no VM, no ISO and no ZFS, and it runs in about four minutes — most of
that being the PowerShell tarball and the NativeAOT compile.

THE NEGATIVE CHECK IS THE ONE THAT MAKES THE POSITIVE ONE MEAN ANYTHING. `apt
update` succeeding against a signed repository proves nothing on its own: apt
also succeeds against an unsigned one if `[trusted=yes]` ever leaks into the
sources file, and it succeeds against a repository signed by a key nobody
checked. So the run ends by swapping the keyring for a foreign key and requiring
apt to REFUSE. A signature check that cannot be seen to fail is not a signature
check — the standing rule in docs/BUILD-NOTES.md, and the reason spike after
spike in this repository is built around a case that must not pass.

WHAT IT DOES NOT COVER, said plainly:

  * It is not a test of a booted machine. The units are installed and their
    enablement symlinks are checked as FILES; nothing here starts systemd.
  * The ISO does not install these packages yet — build.sh still stages the
    same files through includes.chroot. So this checks that the packages are
    correct, not that the image uses them. That switch is its own change and
    its own check-image.py run.
  * The repository is signed by a DEVELOPMENT key that build-os7-repo.sh
    generates when there is no other. C7a — where a release key lives and who
    holds it — is open, and nothing here answers it.
"""

import argparse
import os
import shutil
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BUILD_IMAGE = "os7-build"
TEST_IMAGE = "ubuntu:26.04"

# ---------------------------------------------------------------------------
# What runs inside the test container.
#
# One pass, emitting `key<TAB>value` lines on stdout prefixed with `::`. The
# checking happens in Python, where a failure can say why; the container only
# collects facts. Anything that must be allowed to fail is run with `|| true`
# and its exit status is recorded as a fact of its own.
# ---------------------------------------------------------------------------
PROBE = r"""
set -u
say() { printf '::%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\n' '~')"; }

export DEBIAN_FRONTEND=noninteractive

# ubuntu:26.04 SHIPS NO CA CERTIFICATES — measured, `ca-certificates` is `un`
# and /etc/ssl/certs/ca-certificates.crt does not exist. So every https fetch
# from the pinned snapshot fails with "SSL connection failed", apt reports it as
# a WARNING and exits 0, and the only visible symptom is that a dependency from
# `universe` is suddenly "not installable". The harness therefore hands the
# container a trust store, copied out of the build image.
#
# It is a fact about the base image and not about OS/7's packages, which is why
# it is fixed here and not in a package: an OS/7 machine has ca-certificates
# because the package list installs it.
install -Dm644 /repo/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
cat > /etc/apt/apt.conf.d/99os7-check <<'CONF'
Acquire::https::CaInfo "/etc/ssl/certs/ca-certificates.crt";
CONF

# The machine takes its Ubuntu half from the PINNED SNAPSHOT, not from the live
# archive. A container resolving os7-backup's `sanoid` out of today's archive
# would be testing a machine OS/7 does not build.
. /repo/pin.conf
cat > /etc/apt/sources.list.d/ubuntu.sources <<SRC
Types: deb
URIs: ${OS7_ARCHIVE_BASE}/${OS7_ARCHIVE_SNAPSHOT}
Suites: ${OS7_DISTRIBUTION} ${OS7_DISTRIBUTION}-updates ${OS7_DISTRIBUTION}-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.list 2>/dev/null

# ---------------------------------------------------------------------------
# 1. Trust. The keyring is delivered out of band, because a machine has to
#    trust the repository BEFORE it can install the package that carries the
#    keyring. On the ISO that is the build hook; here it is a copy.
# ---------------------------------------------------------------------------
install -Dm644 /repo/keyring/os7-archive-keyring.gpg \
	/usr/share/keyrings/os7-archive-keyring.gpg
cat > /etc/apt/sources.list.d/os7.sources <<SRC
Types: deb
URIs: file:///repo
Suites: ${OS7_SUITE}
Components: main
Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg
SRC

apt-get update -qq > /tmp/update.log 2>&1
say update.rc "$?"
say update.log "$(tail -4 /tmp/update.log)"

# What apt itself thinks it found. `apt-cache policy` naming the suite is the
# fact; the exit code of `apt-get update` is a diagnostic.
say policy "$(apt-cache policy os7-base 2>/dev/null | tr -s ' ')"

# ---------------------------------------------------------------------------
# 2. Make it an OS/7 machine, in one apt operation.
# ---------------------------------------------------------------------------
apt-get install -y -qq os7-server > /tmp/install.log 2>&1
say install.rc "$?"
say install.log "$(tail -12 /tmp/install.log)"

say installed "$(dpkg-query -W -f='${binary:Package}=${Version} ' 'os7-*' 2>/dev/null)"

# THE PACKAGE'S OWN apt SOURCE, which replaced the harness's at the same path
# when os7-release was unpacked. From here on apt is reading OS/7's file, not
# the one this script wrote — which is the file that has to be right on a real
# machine.
say sources.owner "$(dpkg -S /etc/apt/sources.list.d/os7.sources 2>&1 | head -1)"
say sources.body "$(tr -s ' \n' ' ' < /etc/apt/sources.list.d/os7.sources 2>/dev/null)"

# ---------------------------------------------------------------------------
# 3. The identity. os7-release diverts /usr/lib/os-release away from base-files
#    and derives the branded file from the diverted original.
# ---------------------------------------------------------------------------
say divert "$(dpkg-divert --list '/usr/lib/os-release' 2>/dev/null)"
say distrib "$([ -s /usr/lib/os-release.distrib ] && echo yes || echo no)"
say osrel "$(. /etc/os-release 2>/dev/null; \
   printf 'NAME=%s ID=%s VERSION_ID=%s PRETTY_NAME=%s IMAGE_ID=%s IMAGE_VERSION=%s' \
   "${NAME-}" "${ID-}" "${VERSION_ID-}" "${PRETTY_NAME-}" "${IMAGE_ID-}" "${IMAGE_VERSION-}")"
say reljson "$(cat /usr/lib/os7/release.json 2>/dev/null | tr -d ' \n')"

# ---------------------------------------------------------------------------
# 4. The console. os7-console diverts /etc/default/console-setup.
# ---------------------------------------------------------------------------
say console.link "$(readlink -f /etc/default/console-setup 2>/dev/null)"
say console.font "$(grep -c 'os7' /etc/default/console-setup 2>/dev/null)"
say psfs "$(ls /usr/share/consolefonts/ 2>/dev/null | grep -c '^os7-')"
say vtrgb "$(ls /usr/share/os7/palette-*.vtrgb 2>/dev/null | wc -l)"

# ---------------------------------------------------------------------------
# 5. The shell and the modules, RUN rather than listed.
# ---------------------------------------------------------------------------
say pwsh.link "$(readlink -f /usr/bin/pwsh 2>/dev/null)"
say pwsh.version "$(/usr/bin/pwsh --version 2>&1 | head -1)"
say pwsh.dropin "$([ -r /etc/profile.d/95-os7-powershell.sh ] && echo yes || echo no)"

# Import BY NAME, which is what a booted machine does — and which is the thing
# a chroot cannot answer (BUILD-NOTES #38). A container is not a chroot.
say module.import "$(/usr/bin/pwsh -NoLogo -NonInteractive -c \
  'Import-Module OS7 -Force; Import-Module Zfs -Force;
   "{0}|{1}" -f (Get-Module OS7).Version, (Get-Module Zfs).Version' 2>&1 | tail -1)"
# `FullVersion`, because `Version` is the THREE-field form (IDENTITY-PLAN §7) —
# and `.ToString()`, because both are [version] OBJECTS.
#
# MEASURED: `pwsh -c '(Get-OS7Version).FullVersion'` does not print 1.0.0.119.
# PowerShell formats a [version] as a TABLE, so what comes back down a pipe is
#
#     Major  Minor  Build  Revision
#     -----  -----  -----  --------
#     1      0      0      119
#
# in ANSI colour. The type is deliberate — it makes `-ge [version]'1.1.0'` work
# without a parse — and the cost is that every shell caller must ask for the
# string. This is the same [version] trap IDENTITY-PLAN §7 names, in its other
# guise: not a comparison that misreads, a value that will not print.
say module.version "$(/usr/bin/pwsh -NoLogo -NonInteractive -c \
  'Import-Module OS7 -Force; (Get-OS7Version).FullVersion.ToString()' 2>&1 | tail -1)"
say module.manifest "$(/usr/bin/pwsh -NoLogo -NonInteractive -c \
  'Import-Module OS7 -Force; (Get-OS7Version).ManifestPath' 2>&1 | tail -1)"

# The interactive hand-off, driven rather than asserted: a login bash must end
# up in PowerShell, and OS7_NO_PWSH must still give bash. BUILD-NOTES #86 is
# what happens when only the file is checked.
#
# HOOK 0050's RECIPE, to the letter, and both details in it are load-bearing.
# `TERM=dumb` — without it PowerShell emits the cursor-key application-mode
# sequence and the reply comes back as `PS /> [?1h`, which contains no version
# and looks like a failure of the hand-off rather than of the probe. And the
# trailing `exit`, because an interactive shell reading a pipe with no `exit`
# waits. The first version of this check had neither and reported FAIL about a
# machine where the hand-off worked.
CLEAN="env -i HOME=/root TERM=dumb PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
say handoff "$(printf '$PSVersionTable.PSVersion.ToString()\nexit\n' \
   | ${CLEAN} bash --login -i 2>/dev/null | tr -d '\r')"
say handoff.optout "$(printf 'echo OS7_BASH=$BASH_VERSION\nexit\n' \
   | ${CLEAN} OS7_NO_PWSH=1 bash --login -i 2>/dev/null | tr -d '\r')"

# ---------------------------------------------------------------------------
# 6. os7-setup, out of its package, asked what it is.
#
# INSTALLED SEPARATELY, because it is NOT a member of os7-base. The installer
# belongs to the setup medium: an installed machine has already been installed,
# and shipping the program that partitions disks onto every one of them is a
# larger attack surface for a feature nobody uses twice. The ISO installs it;
# SETUP-PLAN's R=Repair runs from a medium too.
# ---------------------------------------------------------------------------
apt-get install -y -qq os7-setup > /tmp/setup-install.log 2>&1
say setup.rc "$?"
say setup.installed "$(dpkg-query -W -f='${Version}' os7-setup 2>/dev/null)"
say setup.version "$(/usr/sbin/os7-setup --version 2>&1 | head -1)"
say setup.selftest "$(/usr/sbin/os7-setup --self-test 2>&1 | grep -c '^SELFTEST ok')"
say setup.selftest.bad "$(/usr/sbin/os7-setup --self-test 2>&1 | grep -c '^SELFTEST FAIL')"

# ---------------------------------------------------------------------------
# 7. UL10, measured. base-files owns /usr/lib/os-release as a conffile, and
#    before the divert every apt run that touched it could revert the branding.
#    Reinstall it and ask the file what it says.
# ---------------------------------------------------------------------------
apt-get install -y -qq --reinstall base-files > /tmp/basefiles.log 2>&1
say basefiles.rc "$?"
say osrel.after "$(. /etc/os-release 2>/dev/null; \
   printf 'NAME=%s ID=%s PRETTY_NAME=%s IMAGE_VERSION=%s' \
   "${NAME-}" "${ID-}" "${PRETTY_NAME-}" "${IMAGE_VERSION-}")"

# ---------------------------------------------------------------------------
# 8. And it is REVERSIBLE. A divert that cannot be given back is a machine that
#    can never stop being OS/7.
# ---------------------------------------------------------------------------
apt-get remove -y -qq os7-release > /tmp/remove.log 2>&1
say remove.rc "$?"
say divert.after "$(dpkg-divert --list '/usr/lib/os-release' 2>/dev/null)"
say osrel.removed "$(. /etc/os-release 2>/dev/null; \
   printf 'NAME=%s ID=%s PRETTY_NAME=%s IMAGE_VERSION=%s' \
   "${NAME-}" "${ID-}" "${PRETTY_NAME-}" "${IMAGE_VERSION-}")"

# ---------------------------------------------------------------------------
# 9. THE NEGATIVE CHECK. Swap the trust anchor for a key that did not sign this
#    repository. apt must refuse. Without this, everything above is compatible
#    with a repository nobody verified.
# ---------------------------------------------------------------------------
apt-get install -y -qq gnupg > /dev/null 2>&1

# os7-release OWNS /etc/apt/sources.list.d/os7.sources, so removing it in step 8
# took the file with it. Put the harness's own back — this check is about the
# signature, and it needs a source to point at.
cat > /etc/apt/sources.list.d/os7.sources <<SRC
Types: deb
URIs: file:///repo
Suites: ${OS7_SUITE}
Components: main
Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg
SRC

export GNUPGHOME=/tmp/foreign
mkdir -p "${GNUPGHOME}"; chmod 700 "${GNUPGHOME}"
gpg --batch --pinentry-mode loopback --passphrase '' \
	--quick-generate-key 'Not the OS/7 key <nobody@localhost>' ed25519 sign never \
	> /tmp/foreignkey.log 2>&1
say foreignkey.rc "$?"
gpg --batch --yes --export --output /tmp/foreign.gpg 'Not the OS/7 key' >> /tmp/foreignkey.log 2>&1
say foreignkey.size "$(stat -c%s /tmp/foreign.gpg 2>/dev/null || echo 0)"
cp -f /tmp/foreign.gpg /usr/share/keyrings/os7-archive-keyring.gpg

# ONLY the OS/7 source, so nothing else's warnings can stand in for the answer.
# The first version of this check greped a log that also held an SSL warning
# from the Ubuntu source and would have reported "and says why" about it.
rm -rf /var/lib/apt/lists/*
apt-get update \
	-o Dir::Etc::sourcelist=/etc/apt/sources.list.d/os7.sources \
	-o Dir::Etc::sourceparts=/dev/null \
	> /tmp/update-bad.log 2>&1
say badkey.rc "$?"
say badkey.log "$(grep -E '^(E|W):' /tmp/update-bad.log | head -3)"

# And the same isolated update WITH the right key must still succeed, so that
# "it refused" cannot be an artefact of the isolation.
cp -f /repo/keyring/os7-archive-keyring.gpg /usr/share/keyrings/os7-archive-keyring.gpg
rm -rf /var/lib/apt/lists/*
apt-get update \
	-o Dir::Etc::sourcelist=/etc/apt/sources.list.d/os7.sources \
	-o Dir::Etc::sourceparts=/dev/null \
	> /tmp/update-good.log 2>&1
say goodkey.rc "$?"
"""


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def source_facts():
    """The three source facts, asked of git ON THE HOST — through the one script
    that composes them (scripts/os7-source-facts.sh, BUILD-NOTES #43).

    THE SHELL HAS TO BE FOUND RATHER THAN NAMED, and both ways of getting that
    wrong were hit on this host on 2026-08-26:

      * `bash C:\\path\\to\\script.sh` reaches bash as `C:pathtoscript.sh`. The
        shell removes the backslashes as escapes before anything opens the file,
        and the error names a path nobody typed.
      * With forward slashes it opens the right file — under Git Bash. On a
        Windows box with WSL installed, `bash` on PATH is **WSL's**
        (C:\\Windows\\System32\\bash.exe), which cannot see `C:/...` at all: it
        wants /mnt/c/... So the obvious spelling picks the wrong interpreter and
        reports the same "No such file or directory".

    Both failures produced BUILD=0, which is exactly the value #43 is about — so
    the version guard in build-os7-repo.sh refuses it outright rather than
    building a repository nobody could tell apart from another.

    Candidates are tried in order and the first that answers with three lines
    wins; nothing here re-derives a fact for itself.
    """
    script = os.path.join(REPO, "scripts", "os7-source-facts.sh")
    candidates = []

    # Git for Windows puts git.exe at <install>/cmd/ OR <install>/mingw64/bin/,
    # and bash.exe at <install>/bin/ AND <install>/usr/bin/. Which of the two
    # git.exe `which` finds depends on PATH order and differs between a terminal
    # and a spawned process on this very host — so walk up rather than assume a
    # depth. Guessing one produced a candidate that silently did not exist and a
    # fallback to the wrong interpreter.
    git = shutil.which("git")
    if git:
        parent = os.path.dirname(git)
        for _ in range(4):
            parent = os.path.dirname(parent)
            if not parent:
                break
            candidates += [os.path.join(parent, "bin", "bash.exe"),
                           os.path.join(parent, "usr", "bin", "bash.exe")]

    on_path = shutil.which("bash")
    if on_path:
        candidates.append(on_path)
    candidates += ["/bin/bash", "bash"]

    tried, seen = [], set()
    for sh in candidates:
        if sh in seen:
            continue
        seen.add(sh)
        # A candidate that does not exist is REPORTED, not skipped in silence.
        # The first version skipped them, so the one real Git Bash on this host
        # was missing from the list of things that had been tried and the error
        # blamed the two interpreters that were never going to work.
        if os.sep in sh and not os.path.isfile(sh):
            tried.append(f"{sh}: not present")
            continue
        try:
            got = run([sh, script.replace("\\", "/"), REPO.replace("\\", "/")])
        except OSError as exc:
            tried.append(f"{sh}: {exc}")
            continue
        if got.returncode == 0 and "OS7_VERSION_BUILD=" in got.stdout:
            return got
        why = (got.stderr or got.stdout).strip().splitlines()
        tried.append(f"{sh}: {why[0] if why else f'exit {got.returncode}'}")

    print("      FAIL  could not ask git for the source facts through "
          "scripts/os7-source-facts.sh")
    for line in tried:
        print(f"            {line}")
    return None


def hook_dropin():
    """The PowerShell hand-off drop-in as hook 0050 writes it.

    THE SAME FILE EXISTS TWICE UNTIL THE ISO SWITCHES OVER: as a heredoc inside
    build/config/hooks/0050-powershell-interactive-shell.hook.chroot, which is
    how it reaches an ISO today, and as
    build/packages/os7-powershell/95-os7-powershell.sh, which is how it reaches
    a machine through the package. Two copies of five guards, each of which
    exists to avoid breaking something specific, is exactly the drift C7 was
    written to end — so until one of them goes, they are compared here and a
    difference is a failure rather than a surprise on some machine.
    """
    path = os.path.join(REPO, "build", "config", "hooks",
                        "0050-powershell-interactive-shell.hook.chroot")
    out, inside = [], False
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not inside:
                if "<<'DROPIN'" in line:
                    inside = True
                continue
            if line.rstrip("\n") == "DROPIN":
                break
            out.append(line)
    return "".join(out)


def parse(stdout):
    facts = {}
    for line in stdout.splitlines():
        if line.startswith("::") and "\t" in line:
            key, value = line[2:].split("\t", 1)
            facts[key] = value.replace("~", "\n").strip()
    return facts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", default="amd64", choices=("amd64", "arm64"))
    ap.add_argument("--keep", action="store_true",
                    help="leave the built repository in out/os7-repo")
    args = ap.parse_args()

    print(f"\n### OS/7's own repository, checked by installing from it ({args.arch})")

    repo_dir = os.path.join(REPO, "out", "os7-repo")
    if not args.keep and os.path.isdir(repo_dir):
        shutil.rmtree(repo_dir, ignore_errors=True)
    os.makedirs(repo_dir, exist_ok=True)

    # Through `bash` rather than executed directly: this is the one harness in
    # this directory that has to run on the x64 Windows host as well as on the
    # Mac, and Windows cannot exec a shell script. The facts still come from the
    # one script that composes them (BUILD-NOTES #43) — nothing is re-derived
    # here.
    facts_src = source_facts()
    if facts_src is None:
        sys.exit(1)
    source_env = []
    for line in facts_src.stdout.splitlines():
        if "=" in line:
            source_env += ["-e", line.strip()]
    build_no = next((l.split("=", 1)[1] for l in facts_src.stdout.splitlines()
                     if l.startswith("OS7_VERSION_BUILD=")), "0")
    version = f"1.0.0.{build_no}"

    print(f"      building the repository — OS/7 {version}")
    built = run(["docker", "run", "--rm", "--platform", f"linux/{args.arch}",
                 "-v", f"{REPO}:/work", "-v", f"{repo_dir}:/out",
                 *source_env,
                 "-e", f"OS7_VERSION={version}", "-e", f"OS7_ARCH={args.arch}",
                 # The URI the PACKAGE's own sources file will carry. Set to
                 # where the probe mounts the repository, so that what apt reads
                 # after os7-release is unpacked is OS/7's file and not the
                 # harness's — the file that has to be right on a real machine.
                 "-e", "OS7_REPO_URI=file:///repo",
                 # And switched ON, which the pin's default is not: nothing is
                 # published, so a shipped machine gets the source declared and
                 # disabled. This run is the case where there IS somewhere to
                 # point it.
                 "-e", "OS7_REPO_ENABLED=yes",
                 f"{BUILD_IMAGE}:{args.arch}", "bash", "-c",
                 "/work/build/lib/build-os7-repo.sh "
                 "/work/build/config/os7-release.conf /out"])
    for line in built.stdout.splitlines():
        if line.startswith("    ") or line.startswith(">>>"):
            print(f"      {line.strip()}")
    if built.returncode != 0:
        print(built.stdout[-3000:])
        print(built.stderr[-3000:], file=sys.stderr)
        print("\nThe repository could not be built. Nothing else was run.")
        sys.exit(1)

    # The pin, beside the repository, so the probe can point apt at the same
    # snapshot the release names without reaching into the source tree.
    shutil.copyfile(os.path.join(REPO, "build", "config", "os7-release.conf"),
                    os.path.join(repo_dir, "pin.conf"))

    # And a trust store, because ubuntu:26.04 has none — see the probe's note.
    ca = run(["docker", "run", "--rm", "--platform", f"linux/{args.arch}",
              f"{BUILD_IMAGE}:{args.arch}",
              "cat", "/etc/ssl/certs/ca-certificates.crt"])
    if ca.returncode != 0 or len(ca.stdout) < 1000:
        print("      FAIL  could not take a CA bundle out of the build image")
        sys.exit(1)
    with open(os.path.join(repo_dir, "ca-certificates.crt"), "w", newline="\n") as fh:
        fh.write(ca.stdout)

    print(f"      installing from it in a clean {TEST_IMAGE}")
    got = run(["docker", "run", "--rm", "--platform", f"linux/{args.arch}",
               "-v", f"{repo_dir}:/repo:ro", TEST_IMAGE, "bash", "-c", PROBE])
    f = parse(got.stdout)
    if not f:
        print(got.stdout[-3000:])
        print(got.stderr[-3000:], file=sys.stderr)
        print("\nThe probe produced no facts at all.")
        sys.exit(1)

    bad = 0

    def check(ok, what, detail=""):
        nonlocal bad
        print(f"      {'ok  ' if ok else 'FAIL'}  {what}" + (f" — {detail}" if detail else ""))
        if not ok:
            bad += 1

    # -- trust --------------------------------------------------------------
    print("\n  the repository")
    check(f.get("update.rc") == "0", "apt verifies the signed repository",
          f.get("update.log", "")[:120])
    check("os7-1.0" in f.get("policy", ""), "apt resolves os7-base from the OS/7 suite",
          " ".join(f.get("policy", "").split())[:100])

    # -- the product --------------------------------------------------------
    print("\n  one apt operation makes it an OS/7 machine")
    check(f.get("install.rc") == "0", "apt install os7-server succeeds",
          f.get("install.log", "").replace("\n", " ")[-160:])
    installed = f.get("installed", "")
    for pkg in ("os7-release", "os7-console", "os7-powershell", "os7-module",
                "os7-backup", "os7-base", "os7-server"):
        check(f"{pkg}={version}" in installed, f"{pkg} is installed at {version}")
    check("os7-release" in f.get("sources.owner", ""),
          "the apt source is os7-release's own file, not the harness's",
          f.get("sources.owner", "")[:70])
    # The file the PACKAGE ships, read back, because everything after this point
    # is apt reading it. This run built it with OS7_REPO_URI and
    # OS7_REPO_ENABLED overridden; a shipped machine gets the pin's defaults.
    check("file:///repo" in f.get("sources.body", ""),
          "and it carries the URI this run asked for",
          f.get("sources.body", "")[:110])
    with open(os.path.join(REPO, "build", "config", "os7-release.conf")) as fh:
        pin = fh.read()
    check('OS7_REPO_ENABLED="no"' in pin,
          "while the pin's own default leaves it disabled — nothing is published")
    check("Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg"
          in f.get("sources.body", "").replace(" Signed-By", "\nSigned-By").replace("\n", " ")
          or "os7-archive-keyring.gpg" in f.get("sources.body", ""),
          "and it names the keyring rather than trusting everything",
          f.get("sources.body", "")[:110])

    # -- the identity -------------------------------------------------------
    print("\n  the identity, and who owns the file it lives in")
    check("os7-release" in f.get("divert", ""),
          "os7-release owns /usr/lib/os-release by diversion", f.get("divert", "")[:100])
    check(f.get("distrib") == "yes", "base-files' own copy is at .distrib")
    osrel = f.get("osrel", "")
    check("PRETTY_NAME=OS/7" in osrel, "PRETTY_NAME is branded", osrel[:60])
    check(f"IMAGE_VERSION={version}" in osrel, "IMAGE_VERSION identifies this release")
    check("NAME=Ubuntu" in osrel, "NAME is still Ubuntu — Azure Arc reads it (#80)")
    check("ID=ubuntu" in osrel and "VERSION_ID=26.04" in osrel,
          "ID and VERSION_ID are untouched — Intune reads them")
    check(f'"version":"{version}"' in f.get("reljson", ""),
          "the package's release.json names this release")

    # -- UL10 ---------------------------------------------------------------
    print("\n  UL10 — a base-files upgrade can no longer revert the branding")
    check(f.get("basefiles.rc") == "0", "base-files reinstalls cleanly over the divert")
    after = f.get("osrel.after", "")
    check("PRETTY_NAME=OS/7" in after and f"IMAGE_VERSION={version}" in after,
          "the branding survived it", after[:70])
    check("NAME=Ubuntu" in after and "ID=ubuntu" in after,
          "and base-files' own fields came back untouched")

    # -- reversibility ------------------------------------------------------
    print("\n  and it can be given back")
    check(f.get("remove.rc") == "0", "os7-release removes cleanly")
    check("os7-release" not in f.get("divert.after", ""),
          "the diversion is gone", f.get("divert.after", "")[:80] or "(none)")
    removed = f.get("osrel.removed", "")
    check("PRETTY_NAME=OS/7" not in removed and "NAME=Ubuntu" in removed,
          "the machine is a plain Ubuntu again", removed[:70])

    # -- the console --------------------------------------------------------
    print("\n  the console")
    check(f.get("console.link", "").endswith("/usr/share/os7/console-setup"),
          "/etc/default/console-setup resolves to OS/7's",
          f.get("console.link", "") or "(unresolved)")
    check(f.get("psfs") == "4", "four console fonts, and no uncompressed leftovers",
          f"{f.get('psfs')} found")
    check(f.get("vtrgb") == "2", "both palettes", f"{f.get('vtrgb')} found")

    # -- the shell ----------------------------------------------------------
    print("\n  the shell and the modules, run rather than listed")
    check("/opt/microsoft/powershell/7/pwsh" in f.get("pwsh.link", ""),
          "/usr/bin/pwsh points at the 7 directory, not a 7.6.5 one",
          f.get("pwsh.link", ""))
    pin_pwsh = ""
    with open(os.path.join(REPO, "build", "config", "os7-release.conf")) as fh:
        for line in fh:
            if line.startswith("OS7_PWSH_VERSION="):
                pin_pwsh = line.split("=", 1)[1].strip().strip('"')
    check(pin_pwsh and pin_pwsh in f.get("pwsh.version", ""),
          f"PowerShell is the pinned {pin_pwsh}", f.get("pwsh.version", ""))
    check(f"{version}|{version}" == f.get("module.import", ""),
          "both modules import BY NAME at the release version",
          f.get("module.import", ""))
    check(f.get("module.version", "") == version,
          "Get-OS7Version reports the release", f.get("module.version", ""))
    check(f.get("module.manifest", "") == "/usr/lib/os7/release.json",
          "and it read it out of os7-release's own manifest",
          f.get("module.manifest", ""))
    check(pin_pwsh and pin_pwsh in f.get("handoff", ""),
          "a login shell lands in PowerShell", f.get("handoff", "")[:60])
    check("OS7_BASH=" in f.get("handoff.optout", ""),
          "and OS7_NO_PWSH still gives bash", f.get("handoff.optout", "")[:60])

    # The two copies of the drop-in, while there are two. See hook_dropin().
    with open(os.path.join(REPO, "build", "packages", "os7-powershell",
                           "95-os7-powershell.sh"), encoding="utf-8") as fh:
        packaged = fh.read()
    hooked = hook_dropin()
    check(bool(hooked) and packaged.strip() == hooked.strip(),
          "the packaged drop-in is byte-identical to hook 0050's",
          "identical" if packaged.strip() == hooked.strip()
          else f"packaged {len(packaged)}B vs hook {len(hooked)}B")

    # -- the installer ------------------------------------------------------
    print("\n  os7-setup, out of its package — not a member of os7-base")
    check(f.get("setup.installed") == version,
          "it installs on its own", f.get("setup.installed", "") or "(absent)")
    check(version in f.get("setup.version", ""),
          "os7-setup --version agrees with the release", f.get("setup.version", ""))
    check(f.get("setup.selftest.bad") == "0" and int(f.get("setup.selftest") or 0) > 20,
          "os7-setup --self-test is clean",
          f"{f.get('setup.selftest')} ok, {f.get('setup.selftest.bad')} failed")

    # -- the negative check -------------------------------------------------
    print("\n  and a repository it cannot verify is REFUSED")
    check(int(f.get("foreignkey.size") or 0) > 100,
          "the foreign key was actually generated and exported",
          f"{f.get('foreignkey.size')} bytes")
    check(f.get("badkey.rc") not in ("0", None),
          "apt update fails against a foreign signing key",
          f"exit {f.get('badkey.rc')}")
    check("NO_PUBKEY" in f.get("badkey.log", "")
          or "not signed" in f.get("badkey.log", "")
          or "BADSIG" in f.get("badkey.log", ""),
          "and says it is the signature",
          f.get("badkey.log", "").replace("\n", " ")[:150] or "(no reason given)")
    check(f.get("goodkey.rc") == "0",
          "while the same isolated update with the right key still succeeds",
          f"exit {f.get('goodkey.rc')}")

    print()
    if bad:
        print(f"{bad} problem(s).")
        sys.exit(1)
    print(f"OS/7 {version} installs from its own signed repository, and a plain")
    print("Ubuntu container became an OS/7 machine in one apt operation.")
    if not args.keep:
        shutil.rmtree(repo_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
