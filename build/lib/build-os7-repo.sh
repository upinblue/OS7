#!/bin/bash
# =============================================================================
# OS/7 — build and SIGN OS/7's own package repository.
#
#   build-os7-repo.sh <release-conf> <output-dir>
#
# CURATION-AND-DELIVERY-PLAN.md C7 and §6.3-6.4. It produces, under <output-dir>:
#
#   keyring/os7-archive-keyring.gpg   the trust anchor, shipped by os7-release
#   pool/main/o/<pkg>/<pkg>_<v>_<a>.deb        shared by every suite and arch
#   dists/<suite>/main/binary-<arch>/Packages{,.gz}   one per architecture
#   dists/<suite>/Release, Release.gpg, InRelease     naming EVERY architecture
#   releases/<version>/<arch>/release.json    the release DESCRIPTOR (C9)
#   index/<channel>.json{,.asc}       the release INDEX (§6.4)
#
# ONE TREE CARRIES BOTH ARCHITECTURES (RELEASE-PROCESS.md §7.3): run this once
# per architecture INTO THE SAME OUTPUT DIRECTORY and the second run merges —
# every binary-* index is regenerated from the shared pool (arch:all packages
# are rebuilt under one filename by either run, so the other architecture's
# Packages would otherwise record hashes of files this run just replaced), the
# Release names the union of architectures, the descriptor lands under its own
# arch, and the index holds one entry per (version, architecture).
#
# WHY BOTH A DESCRIPTOR AND AN INDEX, and why both are signed. §6.3: "A signed
# package set with an unsigned index of WHICH set is current lets an attacker
# serve an older, still-validly-signed release." Authenticity and freshness are
# different properties. apt's own defence for the package set is Valid-Until in
# the Release file; the index gets a detached signature and carries the same
# expiry, because nothing else would notice a replayed index.
#
# ---------------------------------------------------------------------------
# C7a — WHERE THE PRODUCTION KEY LIVES — IS OPEN AND IS NOT ANSWERED HERE.
#
# The plan is explicit that this is "not a technical question, and not one to
# answer by accident on the day the first repo is published". So this script
# will use a key handed to it (OS7_REPO_GNUPGHOME + OS7_REPO_KEY), and if there
# is none it GENERATES A DEVELOPMENT KEY whose user ID says so in capitals and
# whose fingerprint is printed on every run. Nothing signed by that key should
# ever leave this machine, and a machine that trusts it is a development
# machine. The rotation path is the one §6.3 asks for and the one hook 0010
# already carries for Microsoft's two keys: a second key is trusted before the
# first is retired, so os7-archive-keyring.gpg can hold both during a changeover.
# ---------------------------------------------------------------------------
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

RELEASE_CONF="${1:-}"
OUT_DIR="${2:-}"

if [[ -z "${RELEASE_CONF}" || -z "${OUT_DIR}" ]]; then
	echo "usage: build-os7-repo.sh <release-conf> <output-dir>" >&2
	exit 2
fi
[[ -r "${RELEASE_CONF}" ]] || { echo "!!! release pin not readable: ${RELEASE_CONF}" >&2; exit 1; }

# The same hazard build-os7-packages.sh documents: a plain assignment in a
# sourced file wins over an exported variable, so sourcing the pin discards a
# caller's override without saying so.
#
# OS7_CHANNEL is in this list since 2026-08-28: one repository can carry MORE
# THAN ONE channel index (§6.4 — one signed static file per channel), and the
# pin can only ever name the channel of THIS source tree. Cutting a release
# into another channel is the caller saying so, and until this line the pin
# silently overrode the caller — which is why index/development.json was the
# only index this script had ever produced.
_env_repo_uri="${OS7_REPO_URI:-}"
_env_repo_enabled="${OS7_REPO_ENABLED:-}"
_env_suite="${OS7_SUITE:-}"
_env_channel="${OS7_CHANNEL:-}"

# shellcheck disable=SC1090
source "${RELEASE_CONF}"

[[ -n "${_env_repo_uri}"     ]] && OS7_REPO_URI="${_env_repo_uri}"
[[ -n "${_env_repo_enabled}" ]] && OS7_REPO_ENABLED="${_env_repo_enabled}"
[[ -n "${_env_suite}"        ]] && OS7_SUITE="${_env_suite}"
[[ -n "${_env_channel}"      ]] && OS7_CHANNEL="${_env_channel}"
export OS7_REPO_URI OS7_REPO_ENABLED OS7_SUITE OS7_CHANNEL

# shellcheck source=version-rule.sh
. "${HERE}/version-rule.sh"

# The version, from the same three fields build.sh uses and the same BUILD
# number git gives the host (scripts/os7-source-facts.sh, BUILD-NOTES #43).
#
# COMPOSED HERE ONLY WHEN IT WAS NOT HANDED IN. build.sh is the place that turns
# git's answer into a number for an ISO; when the Makefile drives this target it
# hands the same facts here instead, and the two must agree or a machine could
# be offered a release its medium never carried. Refuse rather than invent — a
# repository whose packages carry a version nobody chose is worse than none.
if [[ -z "${OS7_VERSION:-}" ]]; then
	if [[ -n "${OS7_VERSION_BUILD:-}" ]]; then
		OS7_VERSION="${OS7_VERSION_MAJOR}.${OS7_VERSION_MINOR}.${OS7_VERSION_PATCH}.${OS7_VERSION_BUILD}"
	else
		echo "!!! Neither OS7_VERSION nor OS7_VERSION_BUILD is set." >&2
		echo "!!! Run this through 'make repo-<arch>', which asks git on the host" >&2
		echo "!!! (the container cannot: in a git worktree .git is a file pointing" >&2
		echo "!!! outside the bind mount — BUILD-NOTES #43)." >&2
		exit 1
	fi
fi
if [[ ! "${OS7_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "!!! OS7_VERSION='${OS7_VERSION}' is not four dotted numbers" >&2
	exit 1
fi
if [[ "${OS7_VERSION##*.}" == "0" ]]; then
	echo "!!! OS7_VERSION='${OS7_VERSION}' has BUILD 0, which is the value that" >&2
	echo "!!! means git could not be asked at all. Every ISO built from a git" >&2
	echo "!!! worktree carried exactly that for a while (BUILD-NOTES #43)." >&2
	exit 1
fi

OS7_ARCH="${OS7_ARCH:-$(dpkg --print-architecture)}"
OS7_BUILT="${OS7_BUILT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# ---------------------------------------------------------------------------
# The hotfix form — §7 of the release plan, and UL3's mitigation.
#
# A hotfix is a release that moves ONLY the Build field and overlays a small
# number of packages — normally one — on the base release's FROZEN archive
# snapshot. Without this path, pinning delays security fixes relative to plain
# Ubuntu, and that is a regression a procurement review will find (UL3: "Non-
# optional"). With it, a CVE fix is applied to a KNOWN state and is one
# command from being rolled back.
#
#   OS7_HOTFIX_BASE=<x.y.z.N>   declares this build a hotfix of that release
#   OS7_HOTFIX_DEBS="<path>…"   the overlay .debs (whitespace-separated), each
#                               recorded in the descriptor with its hash
#
# Three refusals, each of which would otherwise surface as a wrong machine
# rather than a failed build:
#   * the version may differ from the base in Build ALONE — anything else is
#     a release, not a hotfix, and must roll the snapshot;
#   * the base release must already be IN this repository, because a hotfix
#     "overlays the current snapshot" and the current snapshot is the base
#     descriptor's, not whatever the pin says today;
#   * overlay packages without a declared base have no meaning.
# ---------------------------------------------------------------------------
OS7_HOTFIX_BASE="${OS7_HOTFIX_BASE:-}"
OS7_HOTFIX_DEBS="${OS7_HOTFIX_DEBS:-}"
if [[ -n "${OS7_HOTFIX_DEBS}" && -z "${OS7_HOTFIX_BASE}" ]]; then
	echo "!!! OS7_HOTFIX_DEBS is set and OS7_HOTFIX_BASE is not: an overlay" >&2
	echo "!!! without a base is not a hotfix, it is an unlabelled change." >&2
	exit 1
fi
if [[ -n "${OS7_HOTFIX_BASE}" ]]; then
	if [[ ! "${OS7_HOTFIX_BASE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "!!! OS7_HOTFIX_BASE='${OS7_HOTFIX_BASE}' is not four dotted numbers" >&2
		exit 1
	fi
	if [[ "${OS7_HOTFIX_BASE%.*}" != "${OS7_VERSION%.*}" ]]; then
		echo "!!! a hotfix moves the Build field alone (§7): ${OS7_HOTFIX_BASE} -> ${OS7_VERSION}" >&2
		echo "!!! changes more than Build. Cut a release instead." >&2
		exit 1
	fi
	if (( ${OS7_VERSION##*.} <= ${OS7_HOTFIX_BASE##*.} )); then
		echo "!!! the hotfix Build (${OS7_VERSION##*.}) must be greater than the" >&2
		echo "!!! base Build (${OS7_HOTFIX_BASE##*.})" >&2
		exit 1
	fi
fi

for tool in apt-ftparchive gpg dpkg-deb sha256sum python3; do
	command -v "${tool}" >/dev/null || { echo "!!! ${tool} is not installed" >&2; exit 1; }
done

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
POOL="${OUT_DIR}/pool/main/o"
DISTS="${OUT_DIR}/dists/${OS7_SUITE}"
KEYRING_DIR="${OUT_DIR}/keyring"
mkdir -p "${POOL}" "${DISTS}/main/binary-${OS7_ARCH}" "${KEYRING_DIR}" \
         "${OUT_DIR}/releases/${OS7_VERSION}/${OS7_ARCH}" "${OUT_DIR}/index"

echo ">>> OS/7 repository ${OS7_SUITE} — ${OS7_VERSION} (${OS7_CHANNEL}) / ${OS7_ARCH}"

# A hotfix overlays the BASE release's snapshot, so the base must be in this
# repository and its snapshot must be the one the pin hands this build. A
# mismatch here means somebody moved the pin between the base and the hotfix —
# which is a release's job, not a hotfix's — and the failure would otherwise
# appear as a machine whose packages come from a snapshot its version number
# does not name.
if [[ -n "${OS7_HOTFIX_BASE}" ]]; then
	BASE_DESCRIPTOR="${OUT_DIR}/releases/${OS7_HOTFIX_BASE}/${OS7_ARCH}/release.json"
	if [[ ! -r "${BASE_DESCRIPTOR}" ]]; then
		echo "!!! hotfix base ${OS7_HOTFIX_BASE} (${OS7_ARCH}) is not in this repository:" >&2
		echo "!!! ${BASE_DESCRIPTOR} does not exist" >&2
		exit 1
	fi
	base_snapshot="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["base"]["archive_snapshot"])' "${BASE_DESCRIPTOR}")"
	base_suite="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["os7_suite"])' "${BASE_DESCRIPTOR}")"
	if [[ "${base_snapshot}" != "${OS7_ARCHIVE_SNAPSHOT}" ]]; then
		echo "!!! the hotfix would be built against snapshot ${OS7_ARCHIVE_SNAPSHOT}," >&2
		echo "!!! but its base ${OS7_HOTFIX_BASE} was built against ${base_snapshot}." >&2
		echo "!!! A hotfix overlays the base's snapshot (§7); a new snapshot is a release." >&2
		exit 1
	fi
	if [[ "${base_suite}" != "${OS7_SUITE}" ]]; then
		echo "!!! the hotfix base is in suite ${base_suite}, this build is ${OS7_SUITE}" >&2
		exit 1
	fi
	echo "    HOTFIX of ${OS7_HOTFIX_BASE} — snapshot ${base_snapshot} unchanged"
fi

# ---------------------------------------------------------------------------
# 1. The key. Shared logic (os7-signing-key.sh), because build.sh needs the
# SAME key's public half for the os7-release package the ISO installs — an ISO
# keyring and a repository signature that disagree would make every
# Set-OS7UpdateChannel against a locally built repository fail verification.
# ---------------------------------------------------------------------------
# shellcheck source=os7-signing-key.sh
source "${HERE}/os7-signing-key.sh"
PUBKEY="${KEYRING_DIR}/os7-archive-keyring.gpg"
os7_ensure_signing_key "${OUT_DIR}/.gnupg" "${PUBKEY}"
KEY_ID="${OS7_SIGNING_KEY_ID}"
KEY_UID="${OS7_SIGNING_KEY_UID}"

# ---------------------------------------------------------------------------
# 2. The packages.
#
# os7-release needs the public key BEFORE it is built, because it is the package
# that carries it. Hence the ordering: key, then packages, then index.
# ---------------------------------------------------------------------------
STAGE="${OUT_DIR}/.incoming"
rm -rf "${STAGE}"; mkdir -p "${STAGE}"

OS7_REPO_PUBKEY="${PUBKEY}" \
OS7_VERSION="${OS7_VERSION}" OS7_ARCH="${OS7_ARCH}" OS7_BUILT="${OS7_BUILT}" \
	"${HERE}/build-os7-packages.sh" "${RELEASE_CONF}" "${STAGE}" ${OS7_REPO_PACKAGES:-}

# The desktop theme is amd64's and was a real .deb before any of this existed.
# It joins the repository rather than being rebuilt in a second way.
if [[ "${OS7_ARCH}" == "amd64" && -z "${OS7_REPO_PACKAGES:-}" ]]; then
	OS7_VERSION="${OS7_VERSION}" "${HERE}/build-desktop-theme.sh" "${RELEASE_CONF}" "${STAGE}"
fi

shopt -s nullglob
DEBS=( "${STAGE}"/*.deb )
shopt -u nullglob
(( ${#DEBS[@]} > 0 )) || { echo "!!! no packages were built" >&2; exit 1; }

# pool/main/o/<source>/ — the layout every Debian archive uses, and the one
# apt-ftparchive's Filename: field will record relative to the repository root.
BUILT_NAMES=()
for deb in "${DEBS[@]}"; do
	name="$(dpkg-deb -f "${deb}" Package)"
	mkdir -p "${POOL}/${name}"
	mv -f "${deb}" "${POOL}/${name}/"
	BUILT_NAMES+=( "$(basename "${deb}")" )
done
rmdir "${STAGE}" 2>/dev/null || true

# The hotfix overlay packages join the pool under their own first letter —
# they are somebody else's packages served from OS/7's repository (C1's
# re-host degree), and pool/main/o/ is os7-*'s letter, not theirs. Recorded
# relative to the repository root so the descriptor can name them.
OS7_HOTFIX_POOL_FILES=""
if [[ -n "${OS7_HOTFIX_DEBS}" ]]; then
	for deb in ${OS7_HOTFIX_DEBS}; do
		[[ -r "${deb}" ]] || { echo "!!! hotfix overlay ${deb} is not readable" >&2; exit 1; }
		name="$(dpkg-deb -f "${deb}" Package)"
		letter="${name:0:1}"
		mkdir -p "${OUT_DIR}/pool/main/${letter}/${name}"
		cp -f "${deb}" "${OUT_DIR}/pool/main/${letter}/${name}/"
		rel="pool/main/${letter}/${name}/$(basename "${deb}")"
		OS7_HOTFIX_POOL_FILES+="${rel}"$'\n'
		BUILT_NAMES+=( "$(basename "${deb}")" )
		echo "    hotfix overlay: ${rel}"
	done
fi
export OS7_HOTFIX_POOL_FILES OS7_HOTFIX_BASE

# ---------------------------------------------------------------------------
# 3. The indices apt reads.
#
# EVERY binary-* directory in the tree is regenerated, not only this run's.
# The pool is shared between the per-arch runs and eight of the ten packages
# are arch:all — rebuilt under ONE filename by either run — so after this run
# replaced them, the other architecture's Packages would record hashes of
# files that no longer exist. Regenerating both from the pool that is
# actually there is what keeps a two-run tree installable on both sides; on
# a single-arch tree the loop visits one directory and nothing changes.
#
# `--arch` keys on the FILENAME's `_<arch>.deb` segment, `_all.deb` included —
# measured 2026-09-01 against resolute's apt-ftparchive, both ways: one deb of
# each kind passes, and a package whose control says amd64 under a filename
# whose arch segment says something else is DROPPED without a word. So the
# scan restricts each index to its own architecture plus arch:all, and the
# read-back below is what stands between a misnamed pool file and an index
# that silently lost it. Without --arch, every index lists both architectures'
# packages and apt on each machine reports the other half as unavailable.
# ---------------------------------------------------------------------------
BINDIR="${DISTS}/main/binary-${OS7_ARCH}"
mkdir -p "${BINDIR}"
for bindir in "${DISTS}/main"/binary-*; do
	a="${bindir##*binary-}"
	( cd "${OUT_DIR}" && apt-ftparchive --arch "${a}" packages pool > "${bindir}/Packages" )
	gzip -9nkf "${bindir}/Packages"
done

# EVERY PACKAGE BUILT THIS RUN IS IN THE INDEX — not "the counts match".
#
# A repository legitimately holds more than one release: that is what lets a
# machine move to a version and back again, and the index appends rather than
# replaces. So the question is not how many packages are in the pool, it is
# whether apt-ftparchive found the ones just built. The first version of this
# check compared totals and failed on the second run against the same directory,
# which is the normal case and not a fault.
PKG_COUNT="$(grep -c '^Package: ' "${BINDIR}/Packages" || true)"
missing=0
for deb in "${BUILT_NAMES[@]}"; do
	if ! grep -qF "${deb}" "${BINDIR}/Packages"; then
		echo "!!! ${deb} was built and is not in the Packages index" >&2
		missing=1
	fi
done
(( missing == 0 )) || {
	echo "!!! apt-ftparchive did not index them. Two known ways: the pool path" >&2
	echo "!!! is wrong, or the FILENAME's _<arch>.deb segment does not say" >&2
	echo "!!! ${OS7_ARCH} or all — --arch filters on the name, not the control." >&2
	exit 1
}
echo "    Packages: ${PKG_COUNT} in the index, ${#BUILT_NAMES[@]} built this run"

# ValidTime, IN SECONDS, and NOT ValidUntil.
#
# MEASURED 2026-08-26 on apt-ftparchive from resolute: `-o APT::FTPArchive::
# Release::ValidUntil=<rfc1123 date>` and `...::Valid-Until=<same>` are both
# ACCEPTED, both IGNORED, and the Release comes out with a Date: and no
# Valid-Until at all. No warning, no non-zero exit. `ValidTime=<seconds>`
# produces the field. So the obvious spelling gives a repository whose index
# never expires — exactly the replay §6.3 is about — and says nothing.
# BUILD-NOTES #88. The check below is what would have caught it, and did.
VALID_SECONDS=$(( OS7_REPO_VALID_DAYS * 86400 ))
VALID_UNTIL="$(date -u -d "+${OS7_REPO_VALID_DAYS} days" +'%a, %d %b %Y %H:%M:%S UTC')"

# The UNION of architectures in this tree, read from the directories that
# exist rather than from this run's parameters — apt refuses to fetch for an
# architecture the Release does not name, so a two-run tree with a one-arch
# Release would break exactly the machine the second run was for.
ARCHES="$(cd "${DISTS}/main" && ls -d binary-* | sed 's/^binary-//' | LC_ALL=C sort | tr '\n' ' ')"
ARCHES="${ARCHES% }"

( cd "${OUT_DIR}" && apt-ftparchive \
	-o "APT::FTPArchive::Release::Origin=${OS7_REPO_ORIGIN}" \
	-o "APT::FTPArchive::Release::Label=${OS7_REPO_LABEL}" \
	-o "APT::FTPArchive::Release::Suite=${OS7_SUITE}" \
	-o "APT::FTPArchive::Release::Codename=${OS7_SUITE}" \
	-o "APT::FTPArchive::Release::Version=${OS7_VERSION}" \
	-o "APT::FTPArchive::Release::Architectures=${ARCHES}" \
	-o "APT::FTPArchive::Release::Components=main" \
	-o "APT::FTPArchive::Release::Description=OS/7 ${OS7_VERSION} (${OS7_CHANNEL})" \
	-o "APT::FTPArchive::Release::ValidTime=${VALID_SECONDS}" \
	release "dists/${OS7_SUITE}" > "${DISTS}/Release" )

# READ IT BACK, and not because the option might be mistyped — because the
# option ABOVE was, in its obvious spelling, and apt-ftparchive said nothing.
# An unexpiring Release is the replay §6.3 names.
for want in '^Valid-Until:' "^Origin: ${OS7_REPO_ORIGIN}\$" "^Suite: ${OS7_SUITE}\$" \
            "^Architectures: ${ARCHES}\$"; do
	if ! grep -qE "${want}" "${DISTS}/Release"; then
		echo "!!! the Release file does not match ${want}" >&2
		sed -n '1,12p' "${DISTS}/Release" >&2
		exit 1
	fi
done
VALID_UNTIL="$(sed -n 's/^Valid-Until: //p' "${DISTS}/Release")"

rm -f "${DISTS}/Release.gpg" "${DISTS}/InRelease"
gpg --batch --yes --pinentry-mode loopback --passphrase '' \
	--local-user "${KEY_ID}" --armor --detach-sign \
	--output "${DISTS}/Release.gpg" "${DISTS}/Release"
gpg --batch --yes --pinentry-mode loopback --passphrase '' \
	--local-user "${KEY_ID}" --clearsign \
	--output "${DISTS}/InRelease" "${DISTS}/Release"

# ASK GPG BACK. A detached signature file exists whether or not it verifies.
gpg --batch --verify "${DISTS}/Release.gpg" "${DISTS}/Release" 2>/dev/null \
	|| { echo "!!! Release.gpg does not verify against Release" >&2; exit 1; }
gpg --batch --verify "${DISTS}/InRelease" 2>/dev/null \
	|| { echo "!!! InRelease does not verify" >&2; exit 1; }
echo "    Release signed and verified, valid until ${VALID_UNTIL}"

# ---------------------------------------------------------------------------
# 4. The release descriptor (C9) and the index (§6.4).
#
# C9: "the release descriptor is the product, and the ISO is one way of
# materialising it." So this is authored from the pin plus the packages that
# were actually built — never from a running image, which is a materialisation
# and not the thing itself.
# ---------------------------------------------------------------------------
# THE ARCHITECTURE IS IN THE PATH (RELEASE-PROCESS §7.3): two architectures at
# one version are two descriptors, and the flat layout had them overwrite each
# other. Builder-side only — a machine reads the path out of the signed index
# entry and never composes it.
DESCRIPTOR="${OUT_DIR}/releases/${OS7_VERSION}/${OS7_ARCH}/release.json"

# Everything the two generators below read, exported once. They are handed
# facts and compose no version string of their own — the same rule the hooks
# follow (IDENTITY-PLAN §5).
export OS7_REPO_OUT="${OUT_DIR}"
export OS7_REPO_KEY_ID="${KEY_ID}"
export OS7_REPO_KEY_UID="${KEY_UID}"
# Where the migrations os7-release ships live in the source tree. The descriptor
# is generated from these directories so that declared and shipped cannot
# diverge. Two sources because the builder stages two: static version-named
# directories under tree/, and migrations.d/ — the migrations the release being
# cut introduces, which build-os7-packages.sh ships under THIS build's version
# (see its comment for why a tree directory cannot know that version).
export OS7_MIGRATION_SRC="${REPO}/build/packages/os7-release/tree/usr/lib/os7/migrations"
export OS7_MIGRATION_NEXT_SRC="${REPO}/build/packages/os7-release/migrations.d"
export OS7_VERSION OS7_CHANNEL OS7_ARCH OS7_BUILT OS7_SUITE
export OS7_UBUNTU_RELEASE OS7_DISTRIBUTION OS7_ARCHIVE_SNAPSHOT OS7_ARCHIVE_BASE

python3 - <<'PY' > "${DESCRIPTOR}"
import hashlib
import json
import os
import subprocess
import sys

out   = os.environ["OS7_REPO_OUT"]
arch  = os.environ["OS7_ARCH"]
# The WHOLE pool, not pool/main/o alone: a hotfix's overlay packages live
# under their own first letter, and a components list that missed them would
# describe a repository other than the one apt serves.
pool  = os.path.join(out, "pool", "main")

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def field(deb, name):
    return subprocess.run(["dpkg-deb", "-f", deb, name],
                          capture_output=True, text=True, check=True).stdout.strip()

def degree(package):
    # C1: the degree of curation, per package. Everything OS/7 builds from its
    # own sources is "rebuild"; os7-powershell repacks an upstream artefact
    # pinned by hash, and every non-os7 package in this pool is somebody
    # else's build served from OS/7's repository — both are "re-host".
    if package == "os7-powershell":
        return "re-host"
    return "rebuild" if package.startswith("os7-") else "re-host"

components = []
for root, _dirs, files in os.walk(pool):
    for f in sorted(files):
        if not f.endswith(".deb"):
            continue
        path = os.path.join(root, f)
        pkg = field(path, "Package")
        components.append({
            "package":  pkg,
            "version":  field(path, "Version"),
            "arch":     field(path, "Architecture"),
            "degree":   degree(pkg),
            "filename": os.path.relpath(path, out).replace(os.sep, "/"),
            "size":     os.path.getsize(path),
            "sha256":   sha256(path),
        })

# The hotfix block — what this release SITS ON, said by the release itself.
# Update-OS7 refuses a hotfix whose base is not the version the machine runs,
# and it can only do that if the descriptor names the base (§7).
hotfix = None
if os.environ.get("OS7_HOTFIX_BASE"):
    overlay = []
    for rel in os.environ.get("OS7_HOTFIX_POOL_FILES", "").splitlines():
        rel = rel.strip()
        if not rel:
            continue
        path = os.path.join(out, rel.replace("/", os.sep))
        overlay.append({
            "package":  field(path, "Package"),
            "version":  field(path, "Version"),
            "arch":     field(path, "Architecture"),
            "filename": rel,
            "sha256":   sha256(path),
        })
    hotfix = {
        "base":     os.environ["OS7_HOTFIX_BASE"],
        "packages": overlay,
    }

descriptor = {
    "version":          os.environ["OS7_VERSION"],
    "channel":          os.environ["OS7_CHANNEL"],
    "released":         os.environ["OS7_BUILT"],
    "architecture":     arch,
    # The Ubuntu half, fixed by one timestamp (U4).
    "base": {
        "release":          os.environ["OS7_UBUNTU_RELEASE"],
        "distribution":     os.environ["OS7_DISTRIBUTION"],
        "archive_snapshot": os.environ["OS7_ARCHIVE_SNAPSHOT"],
        "archive_base":     os.environ["OS7_ARCHIVE_BASE"],
    },
    # OS/7's half, and MEMBERSHIP (C6): which metapackage a machine holds is
    # what makes a release move a whole product rather than a set of versions.
    "os7_suite":   os.environ["OS7_SUITE"],
    "metapackage": {
        "os7-server":  os.environ["OS7_VERSION"],
        "os7-desktop": os.environ["OS7_VERSION"],
    },
    "components": components,
    # C10 step 6'. READ FROM THE PACKAGE that ships them rather than written
    # here, so a release cannot declare a migration it does not carry — or
    # carry one it does not declare, which is the direction that fails silently:
    # Update-OS7 reads the descriptor to decide which releases' migrations to
    # run, so an undeclared one would ship and never execute.
    #
    # The contract — <version>/<chroot|firstboot>/NN-name, and why the split
    # exists — is in build/packages/os7-release/tree/usr/lib/os7/migrations/README.
    "migrations": sorted(set(
        ([d for d in os.listdir(os.environ["OS7_MIGRATION_SRC"])
          if os.path.isdir(os.path.join(os.environ["OS7_MIGRATION_SRC"], d))]
         if os.path.isdir(os.environ.get("OS7_MIGRATION_SRC", "")) else [])
        # migrations.d/ ships under the version being cut — the same rule
        # build-os7-packages.sh applies when it stages the package, restated
        # here so the descriptor lists what the .deb actually carries.
        + ([os.environ["OS7_VERSION"]]
           if any(os.path.isdir(p) and os.listdir(p)
                  for p in (os.path.join(
                      os.environ.get("OS7_MIGRATION_NEXT_SRC", ""), c)
                      for c in ("chroot", "firstboot")))
           else []))),
    "signing": {
        "key":     os.environ["OS7_REPO_KEY_ID"],
        "user_id": os.environ["OS7_REPO_KEY_UID"],
        # Said in the descriptor itself so that a machine can refuse it without
        # having to recognise a fingerprint. C7a is open; this is how a
        # development release admits to being one — INCLUDING a release cut
        # into a channel named `stable`: the channel names an intention, the
        # signing block names a fact, and the fact wins.
        "development": "NOT FOR RELEASE" in os.environ["OS7_REPO_KEY_UID"],
    },
}
if hotfix is not None:
    descriptor["hotfix"] = hotfix
json.dump(descriptor, sys.stdout, indent=2, sort_keys=False)
sys.stdout.write("\n")
PY

DESCRIPTOR_SHA="$(sha256sum "${DESCRIPTOR}" | cut -d' ' -f1)"
echo "    descriptor: releases/${OS7_VERSION}/${OS7_ARCH}/release.json  sha256 ${DESCRIPTOR_SHA:0:16}…"

INDEX="${OUT_DIR}/index/${OS7_CHANNEL}.json"
NEW_INDEX="${INDEX}.new"
export OS7_INDEX_PATH="${INDEX}"
export OS7_DESCRIPTOR_PATH="${DESCRIPTOR}"
export OS7_DESCRIPTOR_SHA="${DESCRIPTOR_SHA}"
export OS7_VALID_UNTIL="${VALID_UNTIL}"

python3 - <<'PY' > "${NEW_INDEX}"
import json
import os
import sys

# ONE SIGNED STATIC FILE PER CHANNEL, with no service behind it (§6.4). It can
# be served from anything, mirrored into an air-gapped site by copying a
# directory, and it keeps "no cloud, no paid services" from becoming a product
# dependency.
#
# A release is APPENDED to whatever is already here, so a repository built twice
# holds both releases and `Get-OS7Release -Available` has a history to show. The
# newest entry is the one at the top.
path = os.environ["OS7_INDEX_PATH"]
version = os.environ["OS7_VERSION"]

try:
    with open(path, encoding="utf-8") as fh:
        index = json.load(fh)
except (OSError, ValueError):
    index = {"channel": os.environ["OS7_CHANNEL"], "releases": []}

# The entry restates the DESCRIPTOR, not the environment. The two used to be
# two authors of the same facts, and the divergence was already real when this
# changed: the descriptor derived `migrations` from the shipped tree while the
# entry hardcoded `[]`, so the first release ever to carry a migration would
# have declared it in the file a machine verifies and not in the file it lists.
with open(os.environ["OS7_DESCRIPTOR_PATH"], encoding="utf-8") as fh:
    descriptor = json.load(fh)

arch = descriptor["architecture"]
entry = {
    "version":          version,
    "released":         descriptor["released"],
    "architecture":     arch,
    "archive_snapshot": descriptor["base"]["archive_snapshot"],
    "os7_suite":        descriptor["os7_suite"],
    "metapackage":      descriptor["metapackage"],
    "manifest":         "releases/%s/%s/release.json" % (version, arch),
    "manifest_sha256":  os.environ["OS7_DESCRIPTOR_SHA"],
    "migrations":       descriptor["migrations"],
    # What this release sits on, when it is a hotfix (§7). In the ENTRY as
    # well as the descriptor because Applicable is decided from the listing —
    # a machine must be able to see "not for my base" without fetching every
    # descriptor in the channel.
    "hotfix_base":      (descriptor.get("hotfix") or {}).get("base"),
    "supersedes":       None,
}

# ONE ENTRY PER (version, architecture), not per version: the amd64 and arm64
# builds of one release are two entries or the second run would silently
# unlist the first architecture's (RELEASE-PROCESS §7.3). `supersedes` names
# the newest release OF THE SAME ARCHITECTURE — the other architecture's
# history is another machine's story.
releases = [r for r in index.get("releases", [])
            if not (r.get("version") == version and r.get("architecture") == arch)]
same_arch = [r for r in releases if r.get("architecture") == arch]
if same_arch:
    entry["supersedes"] = same_arch[0].get("version")
index["releases"] = [entry] + releases
index["channel"] = os.environ["OS7_CHANNEL"]
# The same expiry the Release file carries. An index that never goes stale is
# the replay §6.3 names, and apt does not police this one.
index["valid_until"] = os.environ["OS7_VALID_UNTIL"]

json.dump(index, sys.stdout, indent=2)
sys.stdout.write("\n")
PY

# Written beside and moved into place: the generator READS the index it is
# about to replace, so writing straight to it would truncate the history it is
# supposed to append to.
mv -f "${NEW_INDEX}" "${INDEX}"

rm -f "${INDEX}.asc"
gpg --batch --yes --pinentry-mode loopback --passphrase '' \
	--local-user "${KEY_ID}" --armor --detach-sign \
	--output "${INDEX}.asc" "${INDEX}"
gpg --batch --verify "${INDEX}.asc" "${INDEX}" 2>/dev/null \
	|| { echo "!!! the release index signature does not verify" >&2; exit 1; }
echo "    index: index/${OS7_CHANNEL}.json, signed and verified"

echo "    repository at ${OUT_DIR}"
