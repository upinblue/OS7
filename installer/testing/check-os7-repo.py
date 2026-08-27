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
import hashlib
import json
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
# The three versions this run built — the development release, the stable base,
# and the hotfix of it. Written by the harness beside the repository; the pool
# holds all three, so every install below PINS the version it means.
. /repo/check-versions.conf
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
# 2. Make it an OS/7 machine, in one apt operation. Pinned to the development
#    release: the pool also carries the stable base and the hotfix, and an
#    unpinned install would take the newest and test a different question.
#
#    A preferences pin, not only `=version` — MEASURED: apt's resolver
#    satisfies a strict `Depends (= old)` only from CANDIDATE versions, so
#    `apt-get install os7-server=<old>` alone reports os7-base "is not
#    selected for install" while the version sits in the pool. This is the
#    same fact Update-OS7 pays for with its own preferences.d pin during a
#    run, met here from the other side.
# ---------------------------------------------------------------------------
cat > /etc/apt/preferences.d/os7-check.pref <<PIN
Package: os7-*
Pin: version ${OS7_CHECK_DEV}
Pin-Priority: 1001
PIN
apt-get install -y -qq "os7-server=${OS7_CHECK_DEV}" > /tmp/install.log 2>&1
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
# 6b. THE FIRSTBOOT MIGRATION RUNNER (C10 §6'), exercised out of its package.
#     No systemd here — the SCRIPT is what decides everything the unit cannot,
#     so the script is what is driven: once (it runs and stamps), again (it
#     skips — CL8's rollback-then-re-update path, twice without harm), and
#     once with a pending entry outside the directory os7-release owns, which
#     must be a refusal — the pending file is an instruction to run code as
#     root. UL1's script takes its no-LUKS path in a container, which is
#     itself one of its honest exits.
# ---------------------------------------------------------------------------
MIG="$(ls /usr/lib/os7/migrations/ | grep -v README | head -1)"
say runner.unit "$([ -f /usr/lib/systemd/system/os7-migrations-firstboot.service ] && echo yes || echo no)"
say runner.wants "$(readlink /usr/lib/systemd/system/multi-user.target.wants/os7-migrations-firstboot.service 2>/dev/null)"
say runner.script "$([ -x /usr/libexec/os7-migrate-firstboot ] && echo yes || echo no)"
say runner.shipped "$(ls "/usr/lib/os7/migrations/${MIG}/firstboot/" 2>/dev/null)"
mkdir -p /var/lib/os7/migrations
printf '/usr/lib/os7/migrations/%s/firstboot/50-tpm2-reseal\n' "${MIG}" > /var/lib/os7/migrations/pending
sh /usr/libexec/os7-migrate-firstboot > /tmp/runner1.log 2>&1
say runner.first.rc "$?"
say runner.first.log "$(tail -4 /tmp/runner1.log)"
say runner.stamp "$([ -f "/var/lib/os7/migrations/${MIG}/50-tpm2-reseal" ] && echo yes || echo no)"
say runner.pending.gone "$([ -e /var/lib/os7/migrations/pending ] && echo no || echo yes)"
printf '/usr/lib/os7/migrations/%s/firstboot/50-tpm2-reseal\n' "${MIG}" > /var/lib/os7/migrations/pending
sh /usr/libexec/os7-migrate-firstboot > /tmp/runner2.log 2>&1
say runner.second.rc "$?"
say runner.second.log "$(tail -3 /tmp/runner2.log)"
printf '/tmp/not-a-migration\n' > /var/lib/os7/migrations/pending
sh /usr/libexec/os7-migrate-firstboot > /tmp/runner3.log 2>&1
say runner.refuse.rc "$?"
say runner.refuse.log "$(tail -2 /tmp/runner3.log)"
rm -f /var/lib/os7/migrations/pending

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
# 8b. THE HOTFIX PATH (§7), APPLIED. The machine goes onto the stable BASE by
#     exact version, and one `apt full-upgrade` then applies the hotfix: the
#     os7-* packages move on the Build field alone, and the ONE overlay
#     package — a snapshot package re-served newer from OS/7's own suite — is
#     what UL3 is about: a security fix reaching a frozen archive without
#     unfreezing it. Step 8 removed os7-release, so the source file it owned
#     went with it; the harness's own copy goes back first.
# ---------------------------------------------------------------------------
cat > /etc/apt/sources.list.d/os7.sources <<SRC
Types: deb
URIs: file:///repo
Suites: ${OS7_SUITE}
Components: main
Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg
SRC
apt-get update -qq > /dev/null 2>&1
cat > /etc/apt/preferences.d/os7-check.pref <<PIN
Package: os7-*
Pin: version ${OS7_CHECK_STABLE}
Pin-Priority: 1001
PIN
apt-get install -y -qq "os7-server=${OS7_CHECK_STABLE}" > /tmp/hotfix-base.log 2>&1
say hotfix.base.rc "$?"
say hotfix.mid "$(dpkg-query -W -f='${Version}' os7-base 2>/dev/null)"
# The pin comes out for the upgrade: from here the machine follows the suite,
# and the newest release in it is the hotfix.
rm -f /etc/apt/preferences.d/os7-check.pref
apt-get full-upgrade -y -qq > /tmp/hotfix-up.log 2>&1
say hotfix.upgrade.rc "$?"
say hotfix.final "$(dpkg-query -W -f='${Version}' os7-base 2>/dev/null)"
say hotfix.less "$(dpkg-query -W -f='${Version}' less 2>/dev/null)"
say hotfix.reljson "$(grep -o '"version": *"[^"]*"' /usr/lib/os7/release.json 2>/dev/null | head -1)"

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


# The hotfix overlay: one package out of the pinned snapshot, re-versioned so
# it sorts newer. Runs in the plain test image with the same trust-store and
# snapshot-source dance the probe does, because ubuntu:26.04 ships no CA
# certificates and no pinned sources.
HOTFIX_PREP = r"""
set -eu
export DEBIAN_FRONTEND=noninteractive
install -Dm644 /repo/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
cat > /etc/apt/apt.conf.d/99os7-check <<'CONF'
Acquire::https::CaInfo "/etc/ssl/certs/ca-certificates.crt";
CONF
. /repo/pin.conf
cat > /etc/apt/sources.list.d/ubuntu.sources <<SRC
Types: deb
URIs: ${OS7_ARCHIVE_BASE}/${OS7_ARCHIVE_SNAPSHOT}
Suites: ${OS7_DISTRIBUTION} ${OS7_DISTRIBUTION}-updates ${OS7_DISTRIBUTION}-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.list 2>/dev/null
apt-get update -qq > /dev/null 2>&1
cd /tmp
apt-get download less > /dev/null 2>&1
deb=$(ls less_*.deb)
dpkg-deb -R "$deb" d
sed -i 's/^Version: .*/&+os7hf1/' d/DEBIAN/control
mkdir -p /repo/.hotfix
rm -f /repo/.hotfix/*.deb
dpkg-deb -b --root-owner-group d "/repo/.hotfix/${deb%.deb}+os7hf1.deb" > /dev/null
dpkg-deb -f "/repo/.hotfix/${deb%.deb}+os7hf1.deb" Version
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


def hook_0050_carries_no_copy():
    """The PowerShell hand-off drop-in has ONE source since 2026-08-28: the
    os7-powershell package. Hook 0050 used to carry a second copy as a heredoc
    — how it reached an ISO before the ISO installed the packages — and this
    harness compared the two byte for byte to contain the drift. The seam is
    closed by deletion; what is asserted now is that it STAYS closed."""
    path = os.path.join(REPO, "build", "config", "hooks",
                        "0050-powershell-interactive-shell.hook.chroot")
    with open(path, encoding="utf-8") as fh:
        return "DROPIN" not in fh.read()


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

    # -- the second channel, and the hotfix of it (§7) -----------------------
    #
    # Three more builder runs against the SAME output directory, which is the
    # normal case for a repository — it accumulates. The stable base and the
    # hotfix are cut at Build+1 and Build+2: versions the tree does not have,
    # standing in for the next two builds, which is what a hotfix is. os7-setup
    # is left out of both (OS7_REPO_PACKAGES) because it is the NativeAOT
    # compile — the expensive half of this harness — and it is deliberately
    # not a member of os7-base, so nothing below resolves against it.
    v_stable = f"1.0.0.{int(build_no) + 1}"
    v_hotfix = f"1.0.0.{int(build_no) + 2}"
    with open(os.path.join(repo_dir, "check-versions.conf"), "w", newline="\n") as fh:
        fh.write(f'OS7_CHECK_DEV="{version}"\n'
                 f'OS7_CHECK_STABLE="{v_stable}"\n'
                 f'OS7_CHECK_HOTFIX="{v_hotfix}"\n')
    subset = ("os7-release os7-console os7-module os7-powershell os7-backup "
              "os7-base os7-server os7-desktop")

    # The overlay package: `less` out of the pinned snapshot — it is a Depends
    # of os7-powershell, so the probe machine HAS it, and full-upgrade taking
    # the overlay over the snapshot's version is exactly UL3's mechanism. The
    # version gains +os7hf1, which sorts newer; the .deb is otherwise
    # Canonical's bytes, which is C1's re-host degree.
    print("      preparing the hotfix overlay (less, re-versioned)")
    prep = run(["docker", "run", "--rm", "--platform", f"linux/{args.arch}",
                "-v", f"{repo_dir}:/repo", TEST_IMAGE, "bash", "-c", HOTFIX_PREP])
    hotfix_debs = [n for n in os.listdir(os.path.join(repo_dir, ".hotfix"))
                   if n.endswith(".deb")] if os.path.isdir(
                       os.path.join(repo_dir, ".hotfix")) else []
    if prep.returncode != 0 or len(hotfix_debs) != 1:
        print(prep.stdout[-2000:])
        print(prep.stderr[-1500:], file=sys.stderr)
        print("      FAIL  the hotfix overlay package could not be prepared")
        sys.exit(1)

    def build_more(ver, channel, extra_env=(), expect_fail=False, label=""):
        got = run(["docker", "run", "--rm", "--platform", f"linux/{args.arch}",
                   "-v", f"{REPO}:/work", "-v", f"{repo_dir}:/out",
                   *source_env,
                   "-e", f"OS7_VERSION={ver}", "-e", f"OS7_ARCH={args.arch}",
                   "-e", "OS7_REPO_URI=file:///repo", "-e", "OS7_REPO_ENABLED=yes",
                   "-e", f"OS7_CHANNEL={channel}",
                   "-e", f"OS7_REPO_PACKAGES={subset}",
                   *extra_env,
                   f"{BUILD_IMAGE}:{args.arch}", "bash", "-c",
                   "/work/build/lib/build-os7-repo.sh "
                   "/work/build/config/os7-release.conf /out"])
        if not expect_fail and got.returncode != 0:
            print(got.stdout[-3000:])
            print(got.stderr[-2000:], file=sys.stderr)
            print(f"      FAIL  {label or ver} did not build")
            sys.exit(1)
        return got

    print(f"      building the stable base — OS/7 {v_stable} (channel stable)")
    build_more(v_stable, "stable", label="the stable base")

    # The builder's own refusals, seen to fire before the real hotfix build:
    # a base this repository does not hold, and a version that moves more than
    # the Build field. Both are cheap — they refuse before any package builds.
    bad_base = build_more(v_hotfix, "stable", expect_fail=True,
                          extra_env=("-e", "OS7_HOTFIX_BASE=1.0.0.1"))
    bad_span = build_more("1.1.0.5", "stable", expect_fail=True,
                          extra_env=("-e", f"OS7_HOTFIX_BASE={v_stable}"))

    print(f"      building the hotfix — OS/7 {v_hotfix} on {v_stable}")
    build_more(v_hotfix, "stable", label="the hotfix",
               extra_env=("-e", f"OS7_HOTFIX_BASE={v_stable}",
                          "-e", f"OS7_HOTFIX_DEBS=/out/.hotfix/{hotfix_debs[0]}"))

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

    # -- the channels, read off the repository itself ------------------------
    print("\n  two channels, one repository")
    with open(os.path.join(repo_dir, "index", "development.json")) as fh:
        dev_idx = json.load(fh)
    with open(os.path.join(repo_dir, "index", "stable.json")) as fh:
        st_idx = json.load(fh)
    check(dev_idx.get("channel") == "development"
          and st_idx.get("channel") == "stable",
          "each index says the channel its filename claims")
    check(os.path.exists(os.path.join(repo_dir, "index", "development.json.asc"))
          and os.path.exists(os.path.join(repo_dir, "index", "stable.json.asc")),
          "and both are signed")
    dev_versions = [r.get("version") for r in dev_idx.get("releases", [])]
    st_versions = [r.get("version") for r in st_idx.get("releases", [])]
    check(version in dev_versions and version not in st_versions,
          f"the development channel offers {version} and stable does not")
    check(st_versions[:2] == [v_hotfix, v_stable],
          f"stable offers the hotfix over its base — {', '.join(st_versions)}")
    hf_entry = next((r for r in st_idx.get("releases", [])
                     if r.get("version") == v_hotfix), {})
    base_entry = next((r for r in st_idx.get("releases", [])
                       if r.get("version") == v_stable), {})
    check(hf_entry.get("hotfix_base") == v_stable
          and base_entry.get("hotfix_base") is None,
          "the index entry says what the hotfix sits on, and the base says nothing")
    check(hf_entry.get("supersedes") == v_stable, "and that it supersedes it")

    # -- the hotfix descriptor, and the overlay it binds ---------------------
    print("\n  the hotfix descriptor (§7)")
    with open(os.path.join(repo_dir, "releases", v_hotfix, "release.json")) as fh:
        hf_desc = json.load(fh)
    hf_block = hf_desc.get("hotfix") or {}
    overlay = hf_block.get("packages") or []
    check(hf_block.get("base") == v_stable,
          "the descriptor names its base", str(hf_block.get("base")))
    check(len(overlay) == 1 and overlay[0].get("package") == "less",
          "exactly one overlay package, and it is the one that was built",
          ", ".join(p.get("package", "?") for p in overlay))
    if overlay:
        pool_path = os.path.join(repo_dir, *overlay[0]["filename"].split("/"))
        with open(pool_path, "rb") as fh:
            got_sha = hashlib.sha256(fh.read()).hexdigest()
        check(got_sha == overlay[0].get("sha256"),
              "and the descriptor's hash is the pool file's",
              got_sha[:16] + "…")
    comp = {c.get("package"): c.get("degree") for c in hf_desc.get("components", [])}
    check(comp.get("less") == "re-host" and comp.get("os7-module") == "rebuild",
          "the components list carries the overlay at the re-host degree (C1)")

    # -- what the builder refuses --------------------------------------------
    print("\n  what the builder refuses")
    check(bad_base.returncode != 0 and "not in this repository" in
          (bad_base.stdout + bad_base.stderr),
          "a hotfix of a base this repository does not hold")
    check(bad_span.returncode != 0 and "Build field alone" in
          (bad_span.stdout + bad_span.stderr),
          "a hotfix that moves more than the Build field")

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

    # One source for the drop-in, and it stays that way. See
    # hook_0050_carries_no_copy().
    check(hook_0050_carries_no_copy(),
          "hook 0050 carries no second copy of the drop-in — the package is the source")

    # -- the installer ------------------------------------------------------
    print("\n  os7-setup, out of its package — not a member of os7-base")
    check(f.get("setup.installed") == version,
          "it installs on its own", f.get("setup.installed", "") or "(absent)")
    check(version in f.get("setup.version", ""),
          "os7-setup --version agrees with the release", f.get("setup.version", ""))
    check(f.get("setup.selftest.bad") == "0" and int(f.get("setup.selftest") or 0) > 20,
          "os7-setup --self-test is clean",
          f"{f.get('setup.selftest')} ok, {f.get('setup.selftest.bad')} failed")

    # -- the firstboot migration runner (C10 §6') ----------------------------
    print("\n  the firstboot migration runner")
    check(f.get("runner.unit") == "yes" and f.get("runner.script") == "yes",
          "the unit and the runner ship in os7-release")
    check("os7-migrations-firstboot.service" in f.get("runner.wants", ""),
          "enabled by shipped symlink, exactly as the backup units are",
          f.get("runner.wants", "") or "(no symlink)")
    check("50-tpm2-reseal" in f.get("runner.shipped", ""),
          "the release ships UL1 under its own version",
          f.get("runner.shipped", "") or "(nothing shipped)")
    check(f.get("runner.first.rc") == "0" and "ran " in f.get("runner.first.log", ""),
          "a pending firstboot migration runs",
          f.get("runner.first.log", "")[-120:])
    check(f.get("runner.stamp") == "yes" and f.get("runner.pending.gone") == "yes",
          "the run is stamped and the pending record is cleared")
    check(f.get("runner.second.rc") == "0" and "already ran" in f.get("runner.second.log", ""),
          "a second run skips it — twice, without harm (CL8)",
          f.get("runner.second.log", "")[-120:])
    check(f.get("runner.refuse.rc") not in ("0", None)
          and "REFUSED" in f.get("runner.refuse.log", ""),
          "a pending entry outside /usr/lib/os7/migrations is refused, not run",
          f.get("runner.refuse.log", "")[-120:])

    # -- the hotfix path, applied by apt -------------------------------------
    print("\n  the hotfix path, applied — one package on a frozen snapshot (UL3)")
    check(f.get("hotfix.base.rc") == "0",
          f"the stable base installs by exact version",
          f.get("hotfix.mid", ""))
    check(f.get("hotfix.mid", "") == v_stable,
          f"and the machine sits on {v_stable}", f.get("hotfix.mid", ""))
    check(f.get("hotfix.upgrade.rc") == "0", "one apt full-upgrade applies the hotfix")
    check(f.get("hotfix.final", "") == v_hotfix,
          f"os7-base moved to {v_hotfix} — the Build field alone",
          f.get("hotfix.final", ""))
    check(f.get("hotfix.less", "").endswith("+os7hf1"),
          "the overlay package took precedence over the frozen snapshot's",
          f.get("hotfix.less", ""))
    check(v_hotfix in f.get("hotfix.reljson", ""),
          "and the machine's release.json names the hotfix",
          f.get("hotfix.reljson", ""))

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
