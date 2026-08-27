#!/bin/bash
# =============================================================================
# OS/7 — build and SIGN OS/7's own package repository.
#
#   build-os7-repo.sh <release-conf> <output-dir>
#
# CURATION-AND-DELIVERY-PLAN.md C7 and §6.3-6.4. It produces, under <output-dir>:
#
#   keyring/os7-archive-keyring.gpg   the trust anchor, shipped by os7-release
#   pool/main/o/<pkg>/<pkg>_<v>_<a>.deb
#   dists/<suite>/main/binary-<arch>/Packages{,.gz}
#   dists/<suite>/Release, Release.gpg, InRelease
#   releases/<version>/release.json   the release DESCRIPTOR (C9)
#   index/<channel>.json{,.asc}       the release INDEX (§6.4)
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
_env_repo_uri="${OS7_REPO_URI:-}"
_env_repo_enabled="${OS7_REPO_ENABLED:-}"
_env_suite="${OS7_SUITE:-}"

# shellcheck disable=SC1090
source "${RELEASE_CONF}"

[[ -n "${_env_repo_uri}"     ]] && OS7_REPO_URI="${_env_repo_uri}"
[[ -n "${_env_repo_enabled}" ]] && OS7_REPO_ENABLED="${_env_repo_enabled}"
[[ -n "${_env_suite}"        ]] && OS7_SUITE="${_env_suite}"
export OS7_REPO_URI OS7_REPO_ENABLED OS7_SUITE

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

for tool in apt-ftparchive gpg dpkg-deb sha256sum python3; do
	command -v "${tool}" >/dev/null || { echo "!!! ${tool} is not installed" >&2; exit 1; }
done

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"
POOL="${OUT_DIR}/pool/main/o"
DISTS="${OUT_DIR}/dists/${OS7_SUITE}"
KEYRING_DIR="${OUT_DIR}/keyring"
mkdir -p "${POOL}" "${DISTS}/main/binary-${OS7_ARCH}" "${KEYRING_DIR}" \
         "${OUT_DIR}/releases/${OS7_VERSION}" "${OUT_DIR}/index"

echo ">>> OS/7 repository ${OS7_SUITE} — ${OS7_VERSION} (${OS7_CHANNEL}) / ${OS7_ARCH}"

# ---------------------------------------------------------------------------
# 1. The key.
# ---------------------------------------------------------------------------
export GNUPGHOME="${OS7_REPO_GNUPGHOME:-${OUT_DIR}/.gnupg}"
mkdir -p "${GNUPGHOME}"
chmod 0700 "${GNUPGHOME}"

DEV_UID="OS/7 DEVELOPMENT signing key — NOT FOR RELEASE <os7-dev@localhost>"
KEY_ID="${OS7_REPO_KEY:-}"

if [[ -z "${KEY_ID}" ]]; then
	if ! gpg --batch --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
		echo "    no signing key in ${GNUPGHOME} — generating a DEVELOPMENT key"
		echo "    (CURATION-AND-DELIVERY-PLAN C7a is open; this is not a release key)"
		# --quick-generate-key with an empty passphrase: this is deliberately a
		# throwaway. A release key must not be reachable unattended by a build
		# script, which is the whole of C7a.
		gpg --batch --pinentry-mode loopback --passphrase '' \
			--quick-generate-key "${DEV_UID}" ed25519 sign never >/dev/null 2>&1
	fi
	KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
fi
[[ -n "${KEY_ID}" ]] || { echo "!!! no signing key available" >&2; exit 1; }

KEY_UID="$(gpg --batch --list-keys --with-colons "${KEY_ID}" | awk -F: '/^uid:/ {print $10; exit}')"
echo "    signing key ${KEY_ID}"
echo "    user id     ${KEY_UID}"
case "${KEY_UID}" in
	*"NOT FOR RELEASE"*)
		echo "    *** DEVELOPMENT KEY. Nothing signed here may be published. ***" ;;
esac

# The trust anchor in the form `Signed-By:` wants: a binary keyring holding the
# public key alone. Never the secret key, and never armoured — apt reads either,
# but a directory holding an armoured file called .gpg is how a keyring ends up
# unreadable with an error that names neither.
PUBKEY="${KEYRING_DIR}/os7-archive-keyring.gpg"
gpg --batch --yes --export --output "${PUBKEY}" "${KEY_ID}"
[[ -s "${PUBKEY}" ]] || { echo "!!! exporting the public key produced nothing" >&2; exit 1; }

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

# ---------------------------------------------------------------------------
# 3. The indices apt reads.
# ---------------------------------------------------------------------------
BINDIR="${DISTS}/main/binary-${OS7_ARCH}"
mkdir -p "${BINDIR}"
( cd "${OUT_DIR}" && apt-ftparchive packages pool > "${BINDIR}/Packages" )
gzip -9nkf "${BINDIR}/Packages"

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
(( missing == 0 )) || { echo "!!! apt-ftparchive did not find the pool" >&2; exit 1; }
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
( cd "${OUT_DIR}" && apt-ftparchive \
	-o "APT::FTPArchive::Release::Origin=${OS7_REPO_ORIGIN}" \
	-o "APT::FTPArchive::Release::Label=${OS7_REPO_LABEL}" \
	-o "APT::FTPArchive::Release::Suite=${OS7_SUITE}" \
	-o "APT::FTPArchive::Release::Codename=${OS7_SUITE}" \
	-o "APT::FTPArchive::Release::Version=${OS7_VERSION}" \
	-o "APT::FTPArchive::Release::Architectures=${OS7_ARCH}" \
	-o "APT::FTPArchive::Release::Components=main" \
	-o "APT::FTPArchive::Release::Description=OS/7 ${OS7_VERSION} (${OS7_CHANNEL})" \
	-o "APT::FTPArchive::Release::ValidTime=${VALID_SECONDS}" \
	release "dists/${OS7_SUITE}" > "${DISTS}/Release" )

# READ IT BACK, and not because the option might be mistyped — because the
# option ABOVE was, in its obvious spelling, and apt-ftparchive said nothing.
# An unexpiring Release is the replay §6.3 names.
for want in '^Valid-Until:' "^Origin: ${OS7_REPO_ORIGIN}\$" "^Suite: ${OS7_SUITE}\$"; do
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
DESCRIPTOR="${OUT_DIR}/releases/${OS7_VERSION}/release.json"

# Everything the two generators below read, exported once. They are handed
# facts and compose no version string of their own — the same rule the hooks
# follow (IDENTITY-PLAN §5).
export OS7_REPO_OUT="${OUT_DIR}"
export OS7_REPO_KEY_ID="${KEY_ID}"
export OS7_REPO_KEY_UID="${KEY_UID}"
# Where the migrations os7-release ships live in the source tree. The descriptor
# is generated from this directory so that declared and shipped cannot diverge.
export OS7_MIGRATION_SRC="${REPO}/build/packages/os7-release/tree/usr/lib/os7/migrations"
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
pool  = os.path.join(out, "pool", "main", "o")

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def field(deb, name):
    return subprocess.run(["dpkg-deb", "-f", deb, name],
                          capture_output=True, text=True, check=True).stdout.strip()

components = []
for root, _dirs, files in os.walk(pool):
    for f in sorted(files):
        if not f.endswith(".deb"):
            continue
        path = os.path.join(root, f)
        components.append({
            "package":  field(path, "Package"),
            "version":  field(path, "Version"),
            "arch":     field(path, "Architecture"),
            # C1: the degree of curation, per package. Everything OS/7 builds
            # from its own sources is "rebuild"; os7-powershell repacks an
            # upstream artefact pinned by hash, which is "re-host".
            "degree":   "re-host" if field(path, "Package") == "os7-powershell" else "rebuild",
            "filename": os.path.relpath(path, out).replace(os.sep, "/"),
            "size":     os.path.getsize(path),
            "sha256":   sha256(path),
        })

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
    "migrations": sorted(
        d for d in os.listdir(os.environ["OS7_MIGRATION_SRC"])
        if os.path.isdir(os.path.join(os.environ["OS7_MIGRATION_SRC"], d))
    ) if os.path.isdir(os.environ.get("OS7_MIGRATION_SRC", "")) else [],
    "signing": {
        "key":     os.environ["OS7_REPO_KEY_ID"],
        "user_id": os.environ["OS7_REPO_KEY_UID"],
        # Said in the descriptor itself so that a machine can refuse it without
        # having to recognise a fingerprint. C7a is open; this is how a
        # development release admits to being one.
        "development": "NOT FOR RELEASE" in os.environ["OS7_REPO_KEY_UID"],
    },
}
json.dump(descriptor, sys.stdout, indent=2, sort_keys=False)
sys.stdout.write("\n")
PY

DESCRIPTOR_SHA="$(sha256sum "${DESCRIPTOR}" | cut -d' ' -f1)"
echo "    descriptor: releases/${OS7_VERSION}/release.json  sha256 ${DESCRIPTOR_SHA:0:16}…"

INDEX="${OUT_DIR}/index/${OS7_CHANNEL}.json"
NEW_INDEX="${INDEX}.new"
export OS7_INDEX_PATH="${INDEX}"
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

entry = {
    "version":          version,
    "released":         os.environ["OS7_BUILT"],
    "architecture":     os.environ["OS7_ARCH"],
    "archive_snapshot": os.environ["OS7_ARCHIVE_SNAPSHOT"],
    "os7_suite":        os.environ["OS7_SUITE"],
    "metapackage":      {"os7-server": version, "os7-desktop": version},
    "manifest":         "releases/%s/release.json" % version,
    "manifest_sha256":  os.environ["OS7_DESCRIPTOR_SHA"],
    "migrations":       [],
    "supersedes":       None,
}

releases = [r for r in index.get("releases", []) if r.get("version") != version]
if releases:
    entry["supersedes"] = releases[0].get("version")
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
