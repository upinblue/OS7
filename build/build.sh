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

for sub in package-lists hooks includes.chroot; do
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
for sub in package-lists hooks includes.chroot; do
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
OS7_BUILT="${OS7_BUILT}"
OS7_BUILD_ARCH="${ARCH}"
OS7_GIT_COMMIT="${OS7_GIT_COMMIT}"
OS7_GIT_DIRTY=${OS7_GIT_DIRTY}
OS7_DOTNET_SDK="${OS7_DOTNET_SDK}"
BUILDCONF
chmod 0644 "${WORK}/config/includes.chroot/usr/lib/os7/build.conf"
echo "    staged the release pin -> /usr/lib/os7/{release,build}.conf"

# ---------------------------------------------------------------------------
# Stage the OS7 PowerShell module from its ONE source of truth (powershell/OS7)
# into the image, at a path already on PowerShell 7's default PSModulePath.
# Hook 0060 verifies it imports. Keeping a second copy checked in under
# includes.chroot - as the June-2026 tree did - just lets the two drift.
# ---------------------------------------------------------------------------
OS7_MODULE_SRC="${HERE}/../powershell/OS7"
OS7_MODULE_DST="${WORK}/config/includes.chroot/usr/local/share/powershell/Modules/OS7"
if [[ -d "${OS7_MODULE_SRC}" ]]; then
	mkdir -p "${OS7_MODULE_DST}"
	cp -a "${OS7_MODULE_SRC}/." "${OS7_MODULE_DST}/"

	# ModuleVersion becomes the product version (release plan §11), stamped into
	# the STAGED copy and never into the source. The module ships as part of the
	# release train - it is not separately versioned - so a hand-maintained
	# number in the .psd1 would be a second source of truth that drifts, and the
	# only way to notice would be a support case quoting two numbers.
	#
	# PowerShell parses ModuleVersion as System.Version, which takes exactly the
	# four numeric fields §3.3 defines. Asserted below rather than assumed: a
	# .psd1 whose ModuleVersion does not parse makes the module unimportable, and
	# BUILD-NOTES #14 means no hook can detect that by importing it BY NAME.
	sed -i -E "s/^([[:space:]]*ModuleVersion[[:space:]]*=[[:space:]]*).*$/\1'${OS7_VERSION}'/" \
		"${OS7_MODULE_DST}/OS7.psd1"
	if ! grep -q "ModuleVersion *= *'${OS7_VERSION}'" "${OS7_MODULE_DST}/OS7.psd1"; then
		echo "!!! could not stamp ModuleVersion = ${OS7_VERSION} into the staged OS7.psd1" >&2
		grep -n 'ModuleVersion' "${OS7_MODULE_DST}/OS7.psd1" >&2 || true
		exit 1
	fi
	echo "    staged OS7 PowerShell module -> ${OS7_MODULE_DST#${WORK}/}  (ModuleVersion ${OS7_VERSION})"
else
	echo "!!! OS7 module source missing: ${OS7_MODULE_SRC}" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Console font (SETUP-PLAN §2.5, decision D9).
#
# Fixedsys Excelsior ships as a TTF; the Linux console reads PSF. The conversion
# is a BUILD step so that otf2bdf and bdf2psf stay in the container and never
# reach the image - the image gets two .psf.gz files and nothing else.
#
# Not a hook, deliberately. A hook runs inside the chroot, where it would have
# to install the toolchain into the image and then remove it, and where a
# failure is easy to miss (trap #13). Here it is an ordinary step that either
# produces the files or stops the build.
#
# The fetch is cached in the container-local WORK tree, so a rebuild in the same
# container does not re-download and an offline rebuild works.
# ---------------------------------------------------------------------------
CONSOLEFONT_DST="${WORK}/config/includes.chroot/usr/share/consolefonts"
mkdir -p "${CONSOLEFONT_DST}"
"${HERE}/lib/build-console-font.sh" "${CONSOLEFONT_DST}" "${WORK}/cache/fonts"

for required in os7-fixedsys-8x16.psf.gz os7-fixedsys-16x32.psf.gz; do
	if [[ ! -s "${CONSOLEFONT_DST}/${required}" ]]; then
		echo "!!! console font step produced no ${required}" >&2
		exit 1
	fi
done

# ---------------------------------------------------------------------------
# Console palette (SETUP-PLAN §2.1, decision D5).
#
# Generated rather than checked in, because the same sixteen values are needed
# by the image, by the S1 harness and by anything that later wants the kernel
# form - and four hand-maintained copies of a decision drift.
#
# Staged to /usr/share/os7/ and NOT to /etc/vtrgb. The difference is D6, which is
# still open: Setup applies the palette itself when it starts (it has to, since
# the kernel command line is dead here - BUILD-NOTES #25), and whether the
# INSTALLED console keeps it afterwards is a separate decision. Symlinking
# /etc/vtrgb at these files is the one-line change that makes it so.
# ---------------------------------------------------------------------------
echo ">>> Console palette"
python3 "${HERE}/lib/palette.py" verify
python3 "${HERE}/lib/palette.py" write \
	"${WORK}/config/includes.chroot/usr/share/os7"

# /etc/default/console-setup names these files. If the include is missing the
# system still boots, with the wrong font and no sign that anything is wrong -
# so check the pair here rather than discovering it on a screenshot.
if [[ ! -f "${WORK}/config/includes.chroot/etc/default/console-setup" ]]; then
	echo "!!! consolefonts staged but /etc/default/console-setup is not -" >&2
	echo "!!! the installed console would silently keep the Debian default." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# os7-setup (SETUP-PLAN §6.1, §7, §11).
#
# Published as a NativeAOT binary for the TARGET architecture, which is this
# container's own - the build containers are architecture-matched (harvested
# fix 1), so this is a native compile and never a cross one. Spike S2 measured
# the result at 3.2-3.4 MB with no .NET runtime needed at run time, which is
# what makes it viable as the first thing that runs on a machine.
#
# The RID is derived rather than passed: getting it wrong produces a binary that
# builds cleanly and cannot execute, and the failure would surface as an empty
# tty1 on a booted image.
# ---------------------------------------------------------------------------
case "${ARCH}" in
	amd64) RID=linux-x64   ;;
	arm64) RID=linux-arm64 ;;
esac

SETUP_SRC="${HERE}/../installer/src/OS7.Setup"
SETUP_DST="${WORK}/config/includes.chroot/usr/lib/os7-setup"

echo ">>> os7-setup: publishing for ${RID}"
mkdir -p "${SETUP_DST}"
DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
	dotnet publish "${SETUP_SRC}" -c Release -r "${RID}" -p:PublishAot=true \
	-o "${SETUP_DST}" --nologo

if [[ ! -x "${SETUP_DST}/os7-setup" ]]; then
	echo "!!! dotnet publish produced no os7-setup binary" >&2
	exit 1
fi
echo "    ${SETUP_DST#${WORK}/}/os7-setup  ($(stat -c %s "${SETUP_DST}/os7-setup") bytes)"

# Publish leaves debugging symbols beside the binary. They are a third of the
# size of the thing itself and nothing on the image can read them.
rm -f "${SETUP_DST}"/*.dbg "${SETUP_DST}"/*.pdb

# The systemd unit, and the licence the Licence screen reads.
#
# The licence is a FILE rather than text compiled into the binary, on purpose:
# what a user agrees to has to be what the image ships, and root README open
# question 4 ("License - this README currently assumes MIT ... Confirm before
# the first public commit") is not settled. Baking it in would settle it by
# accident.
install -Dm644 "${HERE}/../installer/assets/os7-setup.service" \
	"${WORK}/config/includes.chroot/usr/lib/systemd/system/os7-setup.service"
install -Dm644 "${HERE}/../LICENSE" \
	"${WORK}/config/includes.chroot/usr/share/os7/LICENSE"
install -Dm644 "${HERE}/../installer/SETUP-PLAN.md" \
	"${WORK}/config/includes.chroot/usr/share/os7/SETUP-PLAN.md"

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

cd "${WORK}"

export OS7_ARCH="${ARCH}"        # read by auto/config
export OS7_VERSION               # ditto - it names the ISO volume
lb config

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

if [[ "${ARCH}" = "arm64" ]]; then
	# HARVESTED FIX 7: live-build emits NO arm64 bootloader (lb_binary_grub2 is
	# gated to "amd64 i386"), so the arm64 ISO it produces has no /EFI and an
	# empty El-Torito catalog - a complete live filesystem that cannot boot.
	# Re-master it.
	"${HERE}/lib/arm64-efi-remaster.sh" "${WORK}" "${DEST}"
else
	ISO="$(ls -1 "${WORK}"/*.iso 2>/dev/null | head -n1 || true)"
	if [[ -n "${ISO}" ]]; then
		cp -f "${ISO}" "${DEST}"
	else
		echo "!!! No ISO produced - see ${WORK}/build-${ARCH}.log (in container)" >&2
		tail -n 40 "${WORK}/build-${ARCH}.log" >&2 || true
		exit 1
	fi
fi

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
unsquashfs -q -n -f -d "${MANIFEST_DIR}" "${SQ}" \
	usr/lib/os7/release.json usr/lib/os7/packages.manifest >/dev/null 2>&1 || true

for want in release.json packages.manifest; do
	if [[ ! -s "${MANIFEST_DIR}/usr/lib/os7/${want}" ]]; then
		echo "!!! the image carries no /usr/lib/os7/${want}." >&2
		echo "!!! Hook 0075 did not run, or did not write it. The ISO exists and is" >&2
		echo "!!! unusable as a release: nothing on it knows which version it is," >&2
		echo "!!! and every boot environment it installs would be named 0.0.0.0." >&2
		rm -rf "${MANIFEST_DIR}"
		exit 1
	fi
done

mv "${MANIFEST_DIR}/usr/lib/os7/release.json" \
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
