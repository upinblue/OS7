#!/usr/bin/env bash
# =============================================================================
# OS/7 — live-build orchestration.
#
#   Usage: build.sh <amd64|arm64|clean>
#
#   *** The OS/7 content this is supposed to build does not exist yet. ***
#
# The two things this script is careful about are HARVESTED FROM A PRIOR BUILD
# SESSION (2026-06-24). Both were discovered the hard way; neither is obvious
# from live-build's documentation. See docs/BUILD-NOTES.md.
#
# Runs inside the os7-build container (see Dockerfile / Makefile).
# =============================================================================

set -euo pipefail

ARCH="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_CONFIG="${HERE}/config"   # authored live-build config, on the bind mount
WORK="/os7-build"             # container-local build root (overlayfs)
# /work/out is the bind-mounted repo inside the build container. The QEMU
# amd64 VM path (scripts/build-amd64-vm.sh) has no such mount and overrides this.
OUT_DIR="${OS7_OUT_DIR:-/work/out}"

usage() { echo "Usage: $0 <amd64|arm64|clean>" >&2; exit 2; }

clean() {
	rm -rf "${WORK}"
	# Clear host-side litter from any older in-place build.
	rm -rf "${SRC_CONFIG}/chroot" "${SRC_CONFIG}/cache" "${SRC_CONFIG}/config" \
	       "${SRC_CONFIG}/.build" "${SRC_CONFIG}/local" "${SRC_CONFIG}/binary" \
	       "${SRC_CONFIG}"/*.log "${SRC_CONFIG}"/*.iso
}

case "${ARCH}" in
	clean)       clean; exit 0 ;;
	amd64|arm64) ;;
	*)           usage ;;
esac

# ---------------------------------------------------------------------------
# The release pin, and the version this build carries.
#
# docs/RELEASE-AND-UPDATE-PLAN.md §3. One file defines the release; this script
# turns it into a version STRING and hands that string to everything downstream.
# Nothing else in the repo may compose a version number.
# ---------------------------------------------------------------------------
RELEASE_CONF="${SRC_CONFIG}/os7-release.conf"
[[ -r "${RELEASE_CONF}" ]] || {
	echo "!!! release pin missing: ${RELEASE_CONF}" >&2
	echo "!!! refusing to build against an unpinned archive." >&2
	exit 1
}
# shellcheck source=config/os7-release.conf
source "${RELEASE_CONF}"

REPO="$(cd "${HERE}/.." && pwd)"

# BUILD = commit count (release plan §3.3), and there are two ways to learn it.
#
#   HANDED IN by the caller, in OS7_VERSION_BUILD / OS7_GIT_COMMIT /
#     OS7_GIT_DIRTY. This is the NORMAL path: the Makefile and
#     scripts/build-amd64-vm.sh both run scripts/os7-source-facts.sh on the HOST
#     and pass the answers, because neither this container nor that VM can ask
#     git for itself - the VM has no .git (it is excluded from the copy) and a
#     bind-mounted git WORKTREE has a .git FILE pointing outside the mount.
#
#   ASKED HERE, when nothing was handed in and /work is a repository this
#     container can actually read - a plain checkout, built by hand.
#
# `git rev-list` needs the repo marked safe: /work is a bind mount owned by the
# host user and git refuses to read a repository it thinks belongs to somebody
# else, with an error that looks like corruption.
GIT="git -c safe.directory=${REPO} -C ${REPO}"
if [[ -n "${OS7_VERSION_BUILD:-}" || -n "${OS7_GIT_COMMIT:-}" ]]; then
	# Half a hand-in is a caller bug, and a silent one: with only the commit,
	# BUILD falls back to 0 and the ISO still gets a well-formed name. Say it.
	if [[ -z "${OS7_VERSION_BUILD:-}" || -z "${OS7_GIT_COMMIT:-}" ]]; then
		echo "!!! only half the source facts were handed in:" >&2
		echo "!!!   OS7_VERSION_BUILD='${OS7_VERSION_BUILD:-}'  OS7_GIT_COMMIT='${OS7_GIT_COMMIT:-}'" >&2
		echo "!!! set both, or neither. scripts/os7-source-facts.sh prints all three." >&2
		exit 1
	fi
	OS7_GIT_DIRTY="${OS7_GIT_DIRTY:-true}"

	# Check what was handed in before building a version out of it. BUILD is
	# interpolated into the version string and into the ISO filename, and hook
	# 0075 compares OS7_GIT_DIRTY against the literal "true" - so "yes" would
	# read as CLEAN and the manifest would claim reproducible=true. A value that
	# is merely non-empty is not a value that is right.
	if [[ ! "${OS7_VERSION_BUILD}" =~ ^[0-9]+$ ]]; then
		echo "!!! OS7_VERSION_BUILD='${OS7_VERSION_BUILD}' is not a number" >&2; exit 1
	fi
	if [[ ! "${OS7_GIT_COMMIT}" =~ ^[0-9a-f]{7,40}$ ]]; then
		echo "!!! OS7_GIT_COMMIT='${OS7_GIT_COMMIT}' is not a commit hash" >&2; exit 1
	fi
	if [[ ! "${OS7_GIT_DIRTY}" =~ ^(true|false)$ ]]; then
		echo "!!! OS7_GIT_DIRTY='${OS7_GIT_DIRTY}' is neither true nor false" >&2; exit 1
	fi
	echo "    source facts supplied by the caller"
elif OS7_GIT_COMMIT="$(${GIT} rev-parse --short=12 HEAD 2>/dev/null)"; then
	OS7_VERSION_BUILD="$(${GIT} rev-list --count HEAD)"
	if [[ -n "$(${GIT} status --porcelain 2>/dev/null)" ]]; then
		OS7_GIT_DIRTY=true
	else
		OS7_GIT_DIRTY=false
	fi
elif [[ -e "${REPO}/.git" ]]; then
	# There IS a repository here and git cannot read it. That is not the same as
	# there being no repository, and it must not produce an ISO.
	#
	# The known cause is a git WORKTREE: ${REPO}/.git is a FILE holding
	#     gitdir: /Users/…/OS7/.git/worktrees/<name>
	# an absolute HOST path that is not inside the bind mount, so git in here
	# reports "not a git repository" about a directory that exists perfectly well
	# outside. Falling through to BUILD=0 is what this script used to do, and the
	# result was an ISO called OS7-<major>.<minor>.<patch>.0-<arch>.iso: a name
	# that identifies no source, collides with every other build made the same
	# way, and takes over the out/os7-<arch>.iso symlink the harnesses open.
	# (docs/BUILD-NOTES.md #43.)
	#
	# Print what GIT said, not what this script guesses: "not a git repository"
	# (the worktree case), "dubious ownership" and "does not have any commits yet"
	# need three different fixes, and a message that picked one would send the
	# next person after the wrong one.
	GIT_WHY="$(${GIT} rev-parse --git-dir 2>&1 >/dev/null || true)"
	[[ -n "${GIT_WHY}" ]] || GIT_WHY="$(${GIT} rev-parse HEAD 2>&1 >/dev/null || true)"
	[[ -n "${GIT_WHY}" ]] || GIT_WHY="git gave no reason"
	echo "!!! ${REPO}/.git exists, but git here cannot answer for the source:" >&2
	echo "!!!   ${GIT_WHY}" >&2
	if [[ -f "${REPO}/.git" ]]; then
		echo "!!! ${REPO}/.git is a FILE - this is a git worktree, and it says:" >&2
		echo "!!!   $(head -n1 "${REPO}/.git")" >&2
		echo "!!! that path is outside this container. Build through the Makefile," >&2
		echo "!!! which asks git on the HOST and hands the answers in:" >&2
		echo "!!!   make build-${ARCH}" >&2
	else
		echo "!!! build through the Makefile, which asks git on the HOST:" >&2
		echo "!!!   make build-${ARCH}" >&2
	fi
	echo "!!! or set OS7_VERSION_BUILD, OS7_GIT_COMMIT and OS7_GIT_DIRTY yourself" >&2
	echo "!!!   eval \"\$(scripts/os7-source-facts.sh)\"" >&2
	echo "!!! refusing to build an ISO whose version identifies nothing." >&2
	exit 1
else
	# No repository at all, and nothing handed in: an exported tarball, which is a
	# legitimate thing to build from. Say so in the manifest rather than inventing
	# a number - a build that cannot identify its source must not claim to, and
	# `reproducible: false` is how it says so where somebody will read it.
	echo "    NOTE: ${REPO} is not a git repository and no source facts were handed in"
	echo "    NOTE: BUILD field is 0 and the manifest will record reproducible=false"
	OS7_VERSION_BUILD=0
	OS7_GIT_COMMIT="unknown"
	OS7_GIT_DIRTY=true
fi

OS7_VERSION="${OS7_VERSION_MAJOR}.${OS7_VERSION_MINOR}.${OS7_VERSION_PATCH}.${OS7_VERSION_BUILD}"
OS7_BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The display rule (docs/IDENTITY-PLAN.md §5), applied ONCE, here. Hook 0075
# consumes the result rather than re-deriving it: a fifth implementation of the
# rule inside a hook would be the one nothing can reach to check.
# shellcheck source=lib/version-rule.sh
. "${HERE}/lib/version-rule.sh"
OS7_VERSION_SHORT="$(os7_short "${OS7_VERSION}" "${OS7_CHANNEL}")"
OS7_PRODUCT="$(os7_product "${OS7_VERSION}" "${OS7_CHANNEL}")"

echo ">>> Building OS/7 ${OS7_VERSION} (${OS7_CHANNEL}) for ${ARCH}"
echo "    archive pin  ${OS7_ARCHIVE_BASE}/${OS7_ARCHIVE_SNAPSHOT}/"
echo "    source       ${OS7_GIT_COMMIT}$( [[ "${OS7_GIT_DIRTY}" = true ]] && echo ' (DIRTY)' )"

# A dirty tree means two builds can carry one version and different bits, which
# is exactly what the pin exists to prevent (release plan §3.1). It is not made
# fatal - a dirty tree is the normal state while developing - but it is said out
# loud here and recorded as "reproducible": false in the manifest, so the number
# never quietly claims more than it knows.
if [[ "${OS7_GIT_DIRTY}" = true ]]; then
	echo "    WARNING: the source tree is dirty. ${OS7_VERSION} does not identify it."
	echo "    WARNING: the manifest will record reproducible=false."
fi

# ---------------------------------------------------------------------------
# HARVESTED FIX 3: build in a CONTAINER-LOCAL directory, never under /work.
#
# On Docker Desktop for Mac the repo is bind-mounted over VirtioFS, and a Linux
# root filesystem cannot be faithfully extracted onto it (device nodes,
# ownership, hardlinks). debootstrap fails there with "tar failed" / a missing
# /usr/bin/env. The container's own overlayfs handles it correctly. Only the
# finished ISO is copied back to /work/out.
# ---------------------------------------------------------------------------
rm -rf "${WORK}"
mkdir -p "${WORK}/config"

# ---------------------------------------------------------------------------
# HARVESTED FIX 6: assemble the STANDARD live-build tree.
#
# live-build reads, relative to the build root:
#     auto/config
#     config/package-lists/  config/hooks/  config/includes.chroot/
#
# This repo authors them under build/config/ (per README "Repository layout"),
# so they must be re-mapped while staging. Get this wrong and live-build
# SILENTLY IGNORES all of them — the build "succeeds" and produces a bare
# Ubuntu image with no OS/7 content in it.
# ---------------------------------------------------------------------------
cp -a "${SRC_CONFIG}/auto" "${WORK}/auto"

# The archive half of the pin, for auto/config. The chroot half is staged after
# the includes.chroot copy below - doing it here would make `cp -a` nest the
# authored tree inside the directory this created.
install -Dm644 "${RELEASE_CONF}" "${WORK}/auto/os7-release.conf"

for sub in package-lists hooks includes.chroot packages.chroot; do
	if [[ -d "${SRC_CONFIG}/${sub}" ]]; then
		cp -a "${SRC_CONFIG}/${sub}" "${WORK}/config/${sub}"
	else
		echo "    (no ${sub}/ authored yet - skipping)"
	fi
done

# ---------------------------------------------------------------------------
# Architecture-scoped config: <sub>-<arch>/ is merged over <sub>/ for that
# architecture only.
#
# This exists because the two architectures are NOT the same product:
#   amd64 - GUI or headless, chosen at install time. Ships GNOME.
#   arm64 - SERVER ONLY, no GUI target. Ships no desktop at all.
#
# README's "one shared package base" is per-architecture, so this is consistent
# with it. Done explicitly here rather than via live-build's package-list
# preprocessing: the staging is visible, greppable, and does not depend on
# undocumented behaviour.
# ---------------------------------------------------------------------------
for sub in package-lists hooks includes.chroot packages.chroot; do
	ARCH_SUB="${SRC_CONFIG}/${sub}-${ARCH}"
	if [[ -d "${ARCH_SUB}" ]]; then
		mkdir -p "${WORK}/config/${sub}"
		cp -a "${ARCH_SUB}/." "${WORK}/config/${sub}/"
		echo "    merged ${sub}-${ARCH}/ -> config/${sub}/"
	fi
done

# ---------------------------------------------------------------------------
# The chroot half of the pin. Two files, and the difference between them is the
# point:
#
#   /usr/lib/os7/release.conf   the pin the HOOKS read - versions, hashes, the
#                               archive snapshot. A verbatim copy of the file in
#                               the repository.
#   /usr/lib/os7/build.conf     what the pin file cannot know, because it is not
#                               a git repository and does not know when it ran.
#
# Both ship in the image. A hook that reads its pins from a file which then
# disappears leaves the image unable to answer "where did this come from".
# `release.json` (hook 0075) carries the same facts in machine-readable form and
# adds what can only be MEASURED after the packages are in; these two are the
# INPUTS. If the inputs and the manifest ever disagree, that is visible instead
# of invisible.
# ---------------------------------------------------------------------------
install -Dm644 "${RELEASE_CONF}" \
	"${WORK}/config/includes.chroot/usr/lib/os7/release.conf"

# The .NET SDK is recorded here and NOT measured by the hook, because it is not
# in the image to measure: os7-setup is NativeAOT (S2) and the image ships no
# runtime. It is a property of the build container, so this is the only place
# that can honestly report it.
OS7_DOTNET_SDK="$(DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet --version 2>/dev/null || echo unknown)"

cat > "${WORK}/config/includes.chroot/usr/lib/os7/build.conf" <<BUILDCONF
# OS/7 — generated by build/build.sh. Do not edit; edit build/config/os7-release.conf.
OS7_VERSION="${OS7_VERSION}"
# The display rule already applied (docs/IDENTITY-PLAN.md §5). SHORT is the
# three-field form and PRODUCT is what PRETTY_NAME, /etc/issue and the MOTD
# header carry. Handed in rather than re-derived in the hook, so there is one
# shell implementation of the rule and check-version-rule.py can reach it.
OS7_VERSION_SHORT="${OS7_VERSION_SHORT}"
OS7_PRODUCT="${OS7_PRODUCT}"
OS7_BUILT="${OS7_BUILT}"
OS7_BUILD_ARCH="${ARCH}"
OS7_GIT_COMMIT="${OS7_GIT_COMMIT}"
OS7_GIT_DIRTY=${OS7_GIT_DIRTY}
OS7_DOTNET_SDK="${OS7_DOTNET_SDK}"
BUILDCONF
chmod 0644 "${WORK}/config/includes.chroot/usr/lib/os7/build.conf"
echo "    staged the release pin -> /usr/lib/os7/{release,build}.conf"

# ---------------------------------------------------------------------------
# The PowerShell modules come from the os7-module PACKAGE since 2026-08-28
# (C7's second half — the ISO installs the packages, hook 0022). What is still
# staged here is the modules' tests/fixtures ALONE: recorded real subsystem
# output, a few KB per module, which is what lets the self-tests run inside
# the chroot at build time and lets check-image.py run them against the
# finished artefact — where ZFS, chrony and systemd cannot run at all. The
# .deb deliberately does not carry them (an installed machine runs nothing
# that reads them — build-os7-packages.sh says so at the rm), so the ISO
# overlays them beside the package's files: dpkg does not remove unowned
# files, so package content and fixtures end up side by side.
#
# The module CODE has exactly one route into the image — the package — so the
# staging that could drift from it is gone.
# ---------------------------------------------------------------------------
stage_ps_fixtures() {
	local name="$1"
	local src="${HERE}/../powershell/${name}/tests"
	local dst="${WORK}/config/includes.chroot/usr/local/share/powershell/Modules/${name}/tests"
	[[ -d "${src}" ]] || return 0
	mkdir -p "${dst}"
	cp -a "${src}/." "${dst}/"
	echo "    staged ${name} test fixtures -> ${dst#${WORK}/}"
}
# Directory is the fifth generic layer and its fixtures travel with the other
# four, but ONE THING ABOUT THEM IS DIFFERENT enough to say here:
# Test-DirectoryModule does not read them. The other four fake their subsystem
# by replacing the command runner and replaying recorded output; LDAP cannot be
# faked that deep, because System.DirectoryServices.Protocols'
# SearchResultEntry has no public constructor (measured 2026-08-27) and no fake
# can produce the object SendRequest returns. So the self-test's evidence is
# transcribed INTO the module and the .ldif/.json pairs beside it are the
# PROVENANCE for it. An image that shipped without them would still self-test
# green — which is why there is no fixture-count line for Directory in hook
# 0060 beside the Zfs and Net ones, and why this loop is the only thing that
# puts them on the image.
#
# DIRECTORY IS IN THIS LIST BECAUSE THE MERGE PUT IT THERE, not because the
# loop grew a module. It is the same list build-os7-packages.sh's os7-module
# loop carries, and the two were written on different branches: this one said
# `Zfs Net Time Systemd OS7` while the other said `Zfs Net Time Systemd
# Directory OS7`, and nothing but reading them side by side would have said so.
for _mod in Zfs Net Time Systemd Directory OS7; do
	if [[ ! -d "${HERE}/../powershell/${_mod}" ]]; then
		echo "!!! ${_mod} module source missing: ${HERE}/../powershell/${_mod}" >&2
		exit 1
	fi
	stage_ps_fixtures "${_mod}"
done

# ---------------------------------------------------------------------------
# The console fonts, the palettes and their licence come from the os7-console
# PACKAGE (hook 0022) — build_os7_console runs the same two font builders and
# palette.py this file used to run, with the same assertions, and the .deb is
# what check-os7-repo.py already proves installable. What this file keeps is
# the /etc/default/console-setup existence check below: the checked-in include
# is BOTH the file the package's divert renames aside on install AND the
# source build_os7_console copies to /usr/share/os7/console-setup, so an image
# without it would select the Debian default font in the window before the
# packages land.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Installed console font (SETUP-PLAN §2.8, decision D15).
#
# A SECOND font and a SECOND route, both deliberate. Fixedsys above is what
# os7-setup is drawn in; Cascadia Mono here is what the installed system's
# console uses. The routes differ because the fonts do: Fixedsys's em is the
# console cell so otf2bdf lands on 8x16 exactly, and Cascadia's is not, so that
# route can only reach 8x15 or 9x16 (BUILD-NOTES #52).
#
# Both fonts ship. /etc/default/console-setup selects between them, and Setup
# calls setfont with the Fixedsys PSF itself before it paints (§2.4).
# /etc/default/console-setup: see the note above the fixtures staging.
if [[ ! -f "${WORK}/config/includes.chroot/etc/default/console-setup" ]]; then
	echo "!!! /etc/default/console-setup is not staged -" >&2
	echo "!!! the installed console would silently keep the Debian default." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# THE OS/7 PACKAGES — C7's second half, 2026-08-28. The nine .debs (and the
# desktop theme on amd64) are built here from the SAME sources the update
# train's repository is built from, staged as FILES into the image, and
# installed by hook 0022 with apt — the exact mechanism hook 0085 proved for
# the theme, generalised. Everything this file used to stage into
# includes.chroot piece by piece — PowerShell, the modules, os7-setup and its
# unit, the fonts, the palettes, the plans — now reaches the image through
# dpkg, which is what lets an update replace it (C7 §6.1: "Every OS/7-specific
# file on a running OS/7 system is unowned by dpkg" was the gap).
#
# NOT config/packages.chroot. BUILD-NOTES #71: a non-empty packages.chroot
# makes lb_chroot_archives build a local apt repository in the chroot and sign
# it with gnupg-1.x-era code that dies under gnupg 2.x ("signing failed: No
# secret key"), and there is no earlier stage to intervene from. The guard
# below still refuses anything that lands there.
#
# THE SIGNING KEY IS SHARED with build-os7-repo.sh (os7-signing-key.sh):
# os7-release ships the trust anchor, and an ISO whose keyring differs from
# the key that signs the repository would refuse every update the same tree
# built. The Makefile mounts one OS7_REPO_GNUPGHOME into both targets.
# ---------------------------------------------------------------------------
echo ">>> The OS/7 packages"
# shellcheck source=lib/os7-signing-key.sh
source "${HERE}/lib/os7-signing-key.sh"
os7_ensure_signing_key "${WORK}/gnupg" "${WORK}/os7-archive-keyring.gpg"

PKG_DST="${WORK}/config/includes.chroot/usr/lib/os7/packages"
mkdir -p "${PKG_DST}"
OS7_REPO_PUBKEY="${WORK}/os7-archive-keyring.gpg" \
OS7_VERSION="${OS7_VERSION}" OS7_ARCH="${ARCH}" OS7_BUILT="${OS7_BUILT}" \
OS7_GIT_COMMIT="${OS7_GIT_COMMIT}" OS7_GIT_DIRTY="${OS7_GIT_DIRTY}" \
	"${HERE}/lib/build-os7-packages.sh" "${RELEASE_CONF}" "${PKG_DST}"

if [[ "${ARCH}" == "amd64" ]]; then
	# The theme is amd64's - arm64 is server-only and has no desktop to theme.
	OS7_VERSION="${OS7_VERSION}" "${HERE}/lib/build-desktop-theme.sh" \
		"${RELEASE_CONF}" "${PKG_DST}"
else
	echo ">>> Desktop theme: skipped (${ARCH} is server-only, no GUI target)"
fi

shopt -s nullglob
STAGED_DEBS=( "${PKG_DST}"/*.deb )
shopt -u nullglob
echo "    ${#STAGED_DEBS[@]} package(s) staged for hook 0022"
if (( ${#STAGED_DEBS[@]} < 9 )); then
	echo "!!! expected at least nine OS/7 packages, found ${#STAGED_DEBS[@]}" >&2
	exit 1
fi

# GUARD: nothing may reach config/packages.chroot. If a later change puts a .deb
# back there, live-build resurrects the local repository and the build dies in
# gnupg with a message that names neither this file nor the theme (#71).
shopt -s nullglob
STRAY_LOCAL_PKGS=( "${WORK}"/config/packages.chroot/* "${WORK}"/config/packages/* )
shopt -u nullglob
if (( ${#STRAY_LOCAL_PKGS[@]} > 0 )); then
	echo "!!! ${#STRAY_LOCAL_PKGS[@]} file(s) staged into config/packages.chroot:" >&2
	for _p in "${STRAY_LOCAL_PKGS[@]}"; do echo "!!!   ${_p}" >&2; done
	echo "!!! live-build would build and SIGN a local apt repo, and its signing" >&2
	echo "!!! code cannot work with gnupg 2.x. BUILD-NOTES #71." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# GUARD: live-build 3.0 globs hooks at config/hooks/*.chroot - FLAT. The older
# Debian live-build layout (config/hooks/normal/) does NOT match, and when it
# does not match live-build prints "Begin executing hooks..." and silently runs
# nothing, exit 0. The build then "succeeds" and hands you an ISO with none of
# the hook content in it. That cost a full build cycle on 2026-08-22.
#
# Fail loudly instead: if the repo has hooks but none landed where live-build
# will look, stop.
# ---------------------------------------------------------------------------
shopt -s nullglob
AUTHORED_HOOKS=( "${SRC_CONFIG}"/hooks/*.chroot "${SRC_CONFIG}/hooks-${ARCH}"/*.chroot )
STAGED_HOOKS=( "${WORK}"/config/hooks/*.chroot )
shopt -u nullglob

if (( ${#AUTHORED_HOOKS[@]} > 0 )) && (( ${#STAGED_HOOKS[@]} == 0 )); then
	echo "!!! ${#AUTHORED_HOOKS[@]} hook(s) authored, but none staged at config/hooks/*.chroot" >&2
	echo "!!! live-build would skip them SILENTLY. Check the hook filenames/layout." >&2
	exit 1
fi
echo "    staged ${#STAGED_HOOKS[@]} hook(s) at config/hooks/*.chroot"

# ---------------------------------------------------------------------------
# THE PERMISSIONS OF includes.chroot ARE SET HERE, NOT INHERITED FROM THE HOST.
#
# BUILD-NOTES #117. live-build copies config/includes.chroot/ into the image
# verbatim, `cp -a` above copies the authored tree with its modes, and on the
# x64 Windows host those modes are a lie: Docker Desktop presents every bind
# mounted file and directory as 0777. Measured in the build container itself —
#
#     stat -c %a /work/build/config/includes.chroot/etc   ->  777
#
# — so every path this tree touches shipped world-writable in the ISO, and
# `find -perm -0002` on the 1.0.0.159 squashfs returned 27 of them: `/`, /etc,
# /usr, /etc/ssh/sshd_config.d/60-os7-powershell.conf, and
# /usr/lib/systemd/system plus /usr/lib/systemd/system-generators — two
# directories a local user could drop a unit or a generator into, each of
# which systemd runs as root on the next boot.
#
# The Mac never showed it because a native mount carries real modes, and amd64
# ISOs have only been built on Windows since 2026-08-28. That is exactly why
# the modes are DECLARED here instead of inherited: a build must not depend on
# what the host filesystem is willing to say, and the two hosts must produce
# the same image.
#
# 0644/0755 by default, and the executables named. The list is short because
# git says it is short — `git ls-files -s build/config/includes.chroot*` has
# exactly one 100755 entry — and check-image.py asks git the same question
# about the SHIPPED squashfs, so a new executable that is not named here fails
# the image check rather than silently arriving non-executable.
# ---------------------------------------------------------------------------
INCLUDES="${WORK}/config/includes.chroot"
if [[ -d "${INCLUDES}" ]]; then
	find "${INCLUDES}" -type d -exec chmod 0755 {} +
	find "${INCLUDES}" -type f -exec chmod 0644 {} +
	for exe in usr/lib/systemd/system-generators/os7-setup-quiesce; do
		if [[ -f "${INCLUDES}/${exe}" ]]; then
			chmod 0755 "${INCLUDES}/${exe}"
		else
			echo "!!! includes.chroot executable ${exe} is missing" >&2
			exit 1
		fi
	done
	# Asked of the tree, not assumed of the chmod: a `find` that matched
	# nothing and a chmod that silently did nothing look identical from here.
	LEFT="$(find "${INCLUDES}" -perm -0002 | wc -l | tr -d ' ')"
	if [[ "${LEFT}" != "0" ]]; then
		echo "!!! ${LEFT} world-writable path(s) remain under includes.chroot" >&2
		find "${INCLUDES}" -perm -0002 >&2
		exit 1
	fi
	echo "    includes.chroot: modes normalised, 0 world-writable paths"
fi

cd "${WORK}"

export OS7_ARCH="${ARCH}"        # read by auto/config
export OS7_VERSION               # ditto - it names the ISO volume
lb config

# ---------------------------------------------------------------------------
# GUARD: did gnupg actually reach the base system?
#
# auto/config exports LB_BOOTSTRAP_INCLUDE=gnupg (BUILD-NOTES #71, and see the
# comment there for why it is kept now that hook 0085 has replaced the local
# package repository). The export is not a `lb config` flag - there is none - so
# nothing on the command line proves it took, and lb_config SOURCES an existing
# config/bootstrap (Read_conffiles) before writing a new one, which lets a stale
# empty value win over the environment without a word.
#
# A setting that can be silently dropped is worth one grep. Ask the file
# debootstrap will actually read, not the variable we think we exported.
# ---------------------------------------------------------------------------
if ! grep -qE '^LB_BOOTSTRAP_INCLUDE="[^"]*gnupg' config/bootstrap; then
	echo "!!! LB_BOOTSTRAP_INCLUDE did not survive into config/bootstrap:" >&2
	grep '^LB_BOOTSTRAP_INCLUDE=' config/bootstrap >&2 || echo "!!!   (no such line at all)" >&2
	echo "!!! see auto/config and BUILD-NOTES #71." >&2
	exit 1
fi
echo "    base system includes gnupg (config/bootstrap) - BUILD-NOTES #71"

echo ">>> Running live-build (needs network access to the Ubuntu archives)"
lb build 2>&1 | tee "${WORK}/build-${ARCH}.log"

mkdir -p "${OUT_DIR}"

# ---------------------------------------------------------------------------
# The ISO carries its version in its NAME, and a stable name points at the
# newest one.
#
#   out/OS7-1.0.0.32-arm64.iso   the artefact. Two of these side by side are
#                                distinguishable without mounting either, which
#                                is the whole reason spike S7 can compare builds.
#   out/os7-arm64.iso            a symlink to it.
#
# The symlink is not decoration. Every harness in installer/testing/ and
# installer/spikes/ opens out/os7-<arch>.iso by that exact name, and the Makefile
# and CLAUDE.md both promise it. Versioning the artefact without keeping the
# stable name would have broken six scripts to gain a filename.
# ---------------------------------------------------------------------------
DEST="${OUT_DIR}/OS7-${OS7_VERSION}-${ARCH}.iso"
STABLE="${OUT_DIR}/os7-${ARCH}.iso"

# BOTH ARCHITECTURES ARE RE-MASTERED, and since 2026-08-25 for the same reason
# rather than two.
#
#   arm64 - HARVESTED FIX 7: live-build emits NO arm64 bootloader (lb_binary_grub2
#           is gated to "amd64 i386"), so the ISO it produces has no /EFI and an
#           empty El-Torito catalog - a complete live filesystem that cannot boot.
#   amd64 - live-build's default IS a bootloader and it is syslinux, which is BIOS,
#           while OS/7 boots UEFI. That stage also cannot run against a 2026
#           archive at all (BUILD-NOTES #47), so auto/config sets --bootloader
#           none and amd64 arrives here in the state arm64 was always in.
#
# live-build's own ISO is therefore discarded on both. Nothing here reads it.
"${HERE}/lib/efi-remaster.sh" "${ARCH}" "${WORK}" "${DEST}"

ln -sfn "$(basename "${DEST}")" "${STABLE}"

# The manifest the image carries, lifted out beside the ISO. S7 diffs two of
# these without booting anything, and a support case can read one without a
# loop mount. Extracted from the squashfs rather than re-derived here: the file
# beside the ISO must be the file IN it, or it is a second source of truth.
SQ="${WORK}/binary/casper/filesystem.squashfs"
[[ -f "${SQ}" ]] || { echo "!!! no squashfs at ${SQ}" >&2; exit 1; }

MANIFEST_DIR="${WORK}/manifest-extract"
rm -rf "${MANIFEST_DIR}"

# ASK FOR THE FILES, THEN LOOK FOR THEM. Do not read unsquashfs's exit code as
# an answer: measured 2026-08-24, `unsquashfs -d out image.squashfs a/path/that/
# does/not/exist` extracts nothing and EXITS 0. So the one failure this check
# exists to catch - hook 0075 never ran, trap #13's shape exactly - is the one
# the exit code cannot report.
# image.json, not release.json, since the ISO installs os7-release
# (2026-08-28): /usr/lib/os7/release.json is now the PACKAGE's declared
# release facts, and hook 0075's measurement — the component versions and the
# package manifest hash read out of the finished image — moved to
# /usr/lib/os7/image.json. The sidecar beside the ISO stays the MEASURED file
# under its established name: it is what S7 diffs and what publish-release.py
# reads, and both want what the image turned out to contain.
unsquashfs -q -n -f -d "${MANIFEST_DIR}" "${SQ}" \
	usr/lib/os7/image.json usr/lib/os7/packages.manifest >/dev/null 2>&1 || true

for want in image.json packages.manifest; do
	if [[ ! -s "${MANIFEST_DIR}/usr/lib/os7/${want}" ]]; then
		echo "!!! the image carries no /usr/lib/os7/${want}." >&2
		echo "!!! Hook 0075 did not run, or did not write it. The ISO exists and is" >&2
		echo "!!! unusable as a release: nothing on it knows which version it is," >&2
		echo "!!! and every boot environment it installs would be named 0.0.0.0." >&2
		rm -rf "${MANIFEST_DIR}"
		exit 1
	fi
done

mv "${MANIFEST_DIR}/usr/lib/os7/image.json" \
   "${OUT_DIR}/OS7-${OS7_VERSION}-${ARCH}.release.json"
mv "${MANIFEST_DIR}/usr/lib/os7/packages.manifest" \
   "${OUT_DIR}/OS7-${OS7_VERSION}-${ARCH}.packages.manifest"
rm -rf "${MANIFEST_DIR}"

# The manifest that just came OUT of the image has to agree with the version
# this build thinks it made. They can only differ if the staging and the hook
# disagreed about the pin, and that is worth catching here rather than in a
# support case.
LIFTED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
	"${OUT_DIR}/OS7-${OS7_VERSION}-${ARCH}.release.json" 2>/dev/null || echo "")"
if [[ "${LIFTED}" != "${OS7_VERSION}" ]]; then
	echo "!!! the image says version '${LIFTED}', this build is ${OS7_VERSION}" >&2
	exit 1
fi
echo "    manifest -> ${OUT_DIR}/OS7-${OS7_VERSION}-${ARCH}.release.json"

echo ">>> Done: ${DEST}"
echo "    OS/7 ${OS7_VERSION} (${OS7_CHANNEL}), ${ARCH}, archive ${OS7_ARCHIVE_SNAPSHOT}"
echo "    ${STABLE} -> $(basename "${DEST}")"
