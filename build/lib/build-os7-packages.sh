#!/bin/bash
# =============================================================================
# OS/7 — build the OS/7 half of the product as .debs.
#
#   build-os7-packages.sh <release-conf> <output-dir> [name...]
#
# CURATION-AND-DELIVERY-PLAN.md C7. Until this existed, every OS/7-specific file
# on a running OS/7 system was unowned by dpkg — the PowerShell tarball, the OS7
# module, os7-setup, the release manifest, the console fonts and the os-release
# branding were all placed by hooks or by includes.chroot. §6.1 spells out the
# three consequences, and the first one is the one that matters here:
#
#     `Update-OS7` cannot update any of them. An apt-based update train reaches
#     the Ubuntu half of the product and nothing else. "The user installs OS/7
#     1.0.1 from PowerShell" would be true only of Ubuntu's packages.
#
# THE MECHANISM IS NOT NEW. `os7-desktop-theme` has been a real .deb with the
# release's version on it since 2026-08-26, built by build-desktop-theme.sh and
# installed by hook 0085 with `apt-get install <path>`. This generalises that
# shape to the rest of the product; build-desktop-theme.sh stays as it is and is
# built alongside these by build-os7-repo.sh.
#
# NOT config/packages.chroot, EVER. A non-empty packages.chroot makes
# lb_chroot_archives build a local apt repository in the chroot and sign it with
# gnupg 1.x code that gnupg 2.x cannot satisfy, and the build dies in gpg with a
# message naming none of this. BUILD-NOTES #71.
#
# ONE SOURCE PER FILE. Where content is generated — the console fonts, the
# palette, the PowerShell modules, the os-release identity — this calls the same
# generator build.sh calls. A package that carried its own copy of any of them
# would be the drift this whole exercise exists to remove.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
SRC="${REPO}/build/packages"

RELEASE_CONF="${1:-}"
OUT_DIR="${2:-}"
shift 2 2>/dev/null || true

if [[ -z "${RELEASE_CONF}" || -z "${OUT_DIR}" ]]; then
	echo "usage: build-os7-packages.sh <release-conf> <output-dir> [name...]" >&2
	exit 2
fi
[[ -r "${RELEASE_CONF}" ]] || { echo "!!! release pin not readable: ${RELEASE_CONF}" >&2; exit 1; }

# SOURCING THE PIN OVERWRITES THE ENVIRONMENT, SILENTLY, and that is not a
# hypothetical. `docker run -e OS7_REPO_URI=file:///repo` followed by
# `source os7-release.conf` leaves OS7_REPO_URI at the pin's value, because a
# plain assignment in a sourced file wins over an exported variable. The check
# then built a package pointing at a path that does not exist, apt lost the OS/7
# source the moment os7-release replaced the harness's sources file, and the
# symptom appeared two steps later as "Unable to locate package os7-setup".
#
# The three repository-facing values are the ones a caller legitimately
# overrides — a build for a test, a mirror, or an offline bundle — so they are
# captured here and restored after.
_env_repo_uri="${OS7_REPO_URI:-}"
_env_repo_enabled="${OS7_REPO_ENABLED:-}"
_env_suite="${OS7_SUITE:-}"

# shellcheck disable=SC1090
source "${RELEASE_CONF}"

[[ -n "${_env_repo_uri}"     ]] && OS7_REPO_URI="${_env_repo_uri}"
[[ -n "${_env_repo_enabled}" ]] && OS7_REPO_ENABLED="${_env_repo_enabled}"
[[ -n "${_env_suite}"        ]] && OS7_SUITE="${_env_suite}"
# shellcheck source=version-rule.sh
. "${HERE}/version-rule.sh"

# OS7_VERSION is computed by the caller (its BUILD field comes from git) and
# handed in. Refuse rather than invent one — trap #43's lesson, applied here.
# A package version nobody chose is worse than a failed build.
if [[ -z "${OS7_VERSION:-}" ]]; then
	echo "!!! OS7_VERSION is not set. The caller must export it." >&2
	exit 1
fi

# The architecture these packages are FOR. Two of them carry compiled code and
# the rest are Architecture: all; getting this wrong produces a package that
# installs and cannot execute.
OS7_ARCH="${OS7_ARCH:-$(dpkg --print-architecture)}"
case "${OS7_ARCH}" in
	amd64|arm64) ;;
	*) echo "!!! OS7_ARCH='${OS7_ARCH}' is not amd64 or arm64" >&2; exit 1 ;;
esac

OS7_VERSION_SHORT="$(os7_short "${OS7_VERSION}" "${OS7_CHANNEL}")"
OS7_PRODUCT="$(os7_product "${OS7_VERSION}" "${OS7_CHANNEL}")"
OS7_BUILT="${OS7_BUILT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

# VARIANT describes what an IMAGE can be, not what an installed machine chose.
# arm64 is server-only and permanently so (README); amd64 carries GNOME, and a
# headless install rewrites this on the target (SETUP-PLAN Phase 3).
if [[ "${OS7_ARCH}" == "arm64" ]]; then
	OS7_VARIANT="Server"; OS7_VARIANT_ID="server"
else
	OS7_VARIANT="GUI";    OS7_VARIANT_ID="gui"
fi

# Exported because the generators below are separate processes that are HANDED
# facts and derive none of their own — the same rule the hooks follow
# (IDENTITY-PLAN §5). OS7_GIT_* are optional: a build outside a repository still
# produces packages, and release.json records `reproducible: false` rather than
# claiming a provenance it does not have.
export OS7_VERSION OS7_VERSION_SHORT OS7_PRODUCT OS7_BUILT OS7_ARCH
export OS7_VARIANT OS7_VARIANT_ID
export OS7_CHANNEL OS7_UBUNTU_RELEASE OS7_DISTRIBUTION
export OS7_ARCHIVE_SNAPSHOT OS7_ARCHIVE_BASE OS7_SUITE
export OS7_GIT_COMMIT="${OS7_GIT_COMMIT:-}" OS7_GIT_DIRTY="${OS7_GIT_DIRTY:-}"

mkdir -p "${OUT_DIR}"
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo ">>> OS/7 packages ${OS7_VERSION} (${OS7_CHANNEL}) for ${OS7_ARCH}"

# ---------------------------------------------------------------------------
# The shared half of every package build.
# ---------------------------------------------------------------------------

# Stage a package's checked-in tree and its DEBIAN directory.
#   pkg_begin <name>  ->  echoes the staging directory
pkg_begin() {
	local name="$1"
	local stage="${WORK}/${name}"
	rm -rf "${stage}"
	mkdir -p "${stage}/DEBIAN"
	if [[ -d "${SRC}/${name}/tree" ]]; then
		cp -a "${SRC}/${name}/tree/." "${stage}/"
	fi
	printf '%s' "${stage}"
}

# control.in -> DEBIAN/control, plus any maintainer scripts the package has.
#
# The substitution is CHECKED. A control file that still holds @OS7_VERSION@
# builds into a package apt will not compare, and dpkg-deb does not care.
#
# Extra NAME=VALUE pairs after the architecture become further @NAME@
# substitutions, for the one placeholder a package resolves for itself.
pkg_control() {
	local name="$1" stage="$2" arch="$3"; shift 3
	sed -e "s|@OS7_VERSION@|${OS7_VERSION}|g" \
	    -e "s|@OS7_ARCH@|${arch}|g" \
	    -e "s|@OS7_UBUNTU_RELEASE@|${OS7_UBUNTU_RELEASE}|g" \
	    "${SRC}/${name}/control.in" > "${stage}/DEBIAN/control"
	local pair
	for pair in "$@"; do
		sed -i "s|@${pair%%=*}@|${pair#*=}|g" "${stage}/DEBIAN/control"
	done
	if grep -q '@OS7_[A-Z_]*@' "${stage}/DEBIAN/control"; then
		echo "!!! ${name}: control still holds an unsubstituted placeholder:" >&2
		grep -n '@OS7_[A-Z_]*@' "${stage}/DEBIAN/control" >&2
		exit 1
	fi
	local script
	for script in preinst postinst prerm postrm triggers conffiles; do
		if [[ -f "${SRC}/${name}/${script}" ]]; then
			if [[ "${script}" == "triggers" || "${script}" == "conffiles" ]]; then
				install -m 0644 "${SRC}/${name}/${script}" "${stage}/DEBIAN/${script}"
			else
				install -m 0755 "${SRC}/${name}/${script}" "${stage}/DEBIAN/${script}"
			fi
		fi
	done
}

# Build it, then INTERROGATE THE ARTEFACT. `dpkg-deb --build` exiting 0 says an
# archive was written; it says nothing about what is inside it. Every required
# path is named by the caller and looked up in `dpkg-deb -c` output, and the
# version is read back off the built package rather than assumed.
#   pkg_finish <name> <stage> <arch> <required-path>...
pkg_finish() {
	local name="$1" stage="$2" arch="$3"; shift 3
	local must=( "$@" )

	# Ownership and modes are set here rather than left to whatever the host
	# filesystem happened to hold. --root-owner-group covers uid/gid; this
	# covers the bits, which a bind mount off a Windows host does not preserve.
	if [[ -d "${stage}/usr" || -d "${stage}/etc" ]]; then
		find "${stage}" -path "${stage}/DEBIAN" -prune -o -type d -exec chmod 0755 {} +
	fi

	local deb="${OUT_DIR}/${name}_${OS7_VERSION}_${arch}.deb"
	dpkg-deb --build --root-owner-group "${stage}" "${deb}" >/dev/null

	local contents missing=0 path
	contents="$(dpkg-deb -c "${deb}")"
	for path in "${must[@]}"; do
		if ! grep -qF " ${path}" <<< "${contents}"; then
			echo "!!! ${name}: built package is missing ${path}" >&2
			missing=1
		fi
	done
	(( missing == 0 )) || { echo "!!! refusing to ship an incomplete ${name}" >&2; exit 1; }

	local built
	built="$(dpkg-deb -f "${deb}" Version)"
	if [[ "${built}" != "${OS7_VERSION}" ]]; then
		echo "!!! ${name}: package says version ${built}, build says ${OS7_VERSION}" >&2
		exit 1
	fi

	echo "    ${deb##*/}  ($(stat -c%s "${deb}") bytes, ${#must[@]} required paths present)"
}

# The licence every OS/7 package carries. MIT, docs/DECISIONS.md question 5.
pkg_copyright() {
	local name="$1" stage="$2"
	install -d "${stage}/usr/share/doc/${name}"
	install -m 0644 "${REPO}/LICENSE" "${stage}/usr/share/doc/${name}/copyright"
}

# ---------------------------------------------------------------------------
# os7-release — the identity and the pin.
#
# The package CURATION-AND-DELIVERY-PLAN §6.2 is about. It carries the release
# pin, the trust anchor for OS/7's own repository, the apt source that points at
# it, and the generator that brands /usr/lib/os-release — which it diverts away
# from base-files, so that an `apt` run can no longer revert the branding at
# all. That is what closes UL10: a mechanism instead of a step in the update
# sequence that has to be remembered forever.
#
# IT DOES NOT SHIP /usr/lib/os-release ITSELF, and that is deliberate. The file
# has to carry base-files' OWN values for ID, NAME, VERSION_ID and the rest —
# fields that are somebody else's (IDENTITY-PLAN I4) and that OS/7 must never
# invent. So the divert makes base-files' copy visible at .distrib, and the
# postinst derives ours from it. A trigger on the path re-derives it when
# base-files is upgraded.
# ---------------------------------------------------------------------------
build_os7_release() {
	local stage; stage="$(pkg_begin os7-release)"

	install -Dm644 "${RELEASE_CONF}" "${stage}/usr/lib/os7/release.conf"

	# What the pin file cannot know, because it is not a git repository and does
	# not know when it ran. Same two files, same split, as build.sh stages into
	# includes.chroot today — see its comment on why both ship.
	install -d "${stage}/usr/lib/os7"
	# The git fields ride along since 2026-08-28: the ISO installs this package
	# (hook 0022), dpkg then owns /usr/lib/os7/build.conf and REPLACES the copy
	# build.sh staged — so every field a consumer reads from either copy has to
	# be in this one. Hook 0075's measured image.json reads the git fields; the
	# postinst's brand() reads the variant fields. Empty when the caller could
	# not ask git, which the version guard upstream already refuses.
	cat > "${stage}/usr/lib/os7/build.conf" <<-BUILDCONF
		# OS/7 — generated by build/lib/build-os7-packages.sh.
		# Do not edit; edit build/config/os7-release.conf.
		OS7_VERSION="${OS7_VERSION}"
		OS7_VERSION_SHORT="${OS7_VERSION_SHORT}"
		OS7_PRODUCT="${OS7_PRODUCT}"
		OS7_BUILT="${OS7_BUILT}"
		OS7_BUILD_ARCH="${OS7_ARCH}"
		OS7_VARIANT="${OS7_VARIANT}"
		OS7_VARIANT_ID="${OS7_VARIANT_ID}"
		OS7_GIT_COMMIT="${OS7_GIT_COMMIT:-}"
		OS7_GIT_DIRTY=${OS7_GIT_DIRTY:-false}
		OS7_DOTNET_SDK="${OS7_DOTNET_SDK:-$(DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet --version 2>/dev/null || echo unknown)}"
	BUILDCONF
	chmod 0644 "${stage}/usr/lib/os7/build.conf"

	# The generator, shipped rather than duplicated. hook 0075 runs the same
	# file at build time; this is the copy an installed machine re-runs.
	install -Dm755 "${HERE}/os-release-identity.py" \
		"${stage}/usr/lib/os7/os-release-identity.py"

	# THE RELEASE FACTS, in the shape Model/Release.cs and Get-OS7Version read.
	#
	# C9: "the release descriptor is the product, and the ISO is one way of
	# materialising it." So the machine-readable answer to "which OS/7 is this"
	# is a file OS/7's own package ships, not something measured out of an image
	# afterwards. The boot-environment name, the GRUB menu title and Setup's
	# title bar are all derived from this file.
	#
	# WHAT IS NOT HERE: the component list with its hashes. That is the
	# repository's description of what this release CONTAINS, it cannot be in a
	# package whose own hash is part of it, and it lives at
	# releases/<version>/release.json with its sha256 recorded in the signed
	# index. THE SEAM: hook 0075 still writes a MEASURED release.json into the
	# image, and the day the ISO installs this package instead, one of the two
	# has to move. docs/SESSION-OS7-REPOSITORY.md names it.
	python3 - "${stage}/usr/lib/os7/release.json" <<-'RELJSON'
		import json, os, sys
		env = os.environ
		dirty = env.get("OS7_GIT_DIRTY", "") == "true"
		doc = {
		    "version":      env["OS7_VERSION"],
		    "channel":      env["OS7_CHANNEL"],
		    "built":        env["OS7_BUILT"],
		    "architecture": env["OS7_ARCH"],
		    # False when the source tree was dirty: the archive is pinned, but
		    # the OS/7 half then came from a state no commit names. Recorded
		    # rather than warned about once, because a warning scrolls past.
		    "reproducible": not dirty and bool(env.get("OS7_GIT_COMMIT")),
		    "source": {"commit": env.get("OS7_GIT_COMMIT") or "unknown",
		               "dirty": dirty},
		    "base": {
		        "distribution":     "ubuntu",
		        "release":          env["OS7_UBUNTU_RELEASE"],
		        "codename":         env["OS7_DISTRIBUTION"],
		        "archive_snapshot": env["OS7_ARCHIVE_SNAPSHOT"],
		        "archive_base":     env["OS7_ARCHIVE_BASE"],
		    },
		    # Which suite this machine takes updates from, and what its
		    # membership is (C6/C11). Update-OS7 reads both.
		    "os7_suite": env["OS7_SUITE"],
		    "metapackage": {"os7-server": env["OS7_VERSION"],
		                    "os7-desktop": env["OS7_VERSION"]},
		}
		with open(sys.argv[1], "w", encoding="utf-8") as fh:
		    json.dump(doc, fh, indent=2, sort_keys=False)
		    fh.write("\n")
	RELJSON
	chmod 0644 "${stage}/usr/lib/os7/release.json"

	# Read it back. Everything downstream derives a name from this one field,
	# and a manifest that parses and holds the wrong version puts a wrong number
	# in all of them without failing anything.
	local got
	got="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
		"${stage}/usr/lib/os7/release.json")"
	if [[ "${got}" != "${OS7_VERSION}" ]]; then
		echo "!!! os7-release: release.json says ${got}, build says ${OS7_VERSION}" >&2
		exit 1
	fi

	# The trust anchor, shipped in the image and owned by this package so that
	# it updates with the system (§6.3). Generated by build-os7-repo.sh; a
	# package built without one is refused rather than shipped keyless.
	if [[ -s "${OS7_REPO_PUBKEY:-}" ]]; then
		install -Dm644 "${OS7_REPO_PUBKEY}" \
			"${stage}/usr/share/keyrings/os7-archive-keyring.gpg"
	else
		echo "!!! os7-release: OS7_REPO_PUBKEY is unset or empty." >&2
		echo "!!! The package carries the trust anchor for OS/7's own repository" >&2
		echo "!!! (CURATION-AND-DELIVERY-PLAN §6.3). Shipping it without one would" >&2
		echo "!!! leave every machine unable to verify an update, and apt would say" >&2
		echo "!!! so only at the next 'apt update'. Run build-os7-repo.sh." >&2
		exit 1
	fi

	# deb822, and `Signed-By` naming the keyring rather than a trusted.gpg.d
	# drop-in: a key in trusted.gpg.d signs for EVERY suite on the machine,
	# including Ubuntu's. This one signs for OS/7's suite and nothing else.
	#
	# AND `Enabled` COMES FROM THE PIN. Nothing is published yet, so the pin says
	# `no` and the file ships switched off. A source pointing at a URI that does
	# not resolve is not harmless: `apt update` on every OS/7 machine would print
	#
	#     E: The repository 'file:/usr/lib/os7/repo os7-1.0 Release' does not
	#        have a Release file.
	#
	# measured, on a container that had just installed os7-release. An
	# administrator who sees that on a fresh machine has no way to tell it from a
	# broken mirror. Declared-and-off says the truth: OS/7 has a repository and
	# this machine has not been told where it is.
	# A CONFFILE (build/packages/os7-release/conffiles), since 2026-08-28 and
	# because of what an upgrade would otherwise do: Set-OS7UpdateChannel
	# rewrites this file to point the machine at its repository, os7-release
	# ships it declared-and-off, and a plain file is REPLACED by dpkg on every
	# upgrade of this package — so the first update a machine ever took would
	# have reverted the channel that delivered it, and the timer's next check
	# would have said "no channel configured". A conffile with --force-confold
	# (which Update-OS7's apt runs already pass) keeps the operator's version.
	install -d "${stage}/etc/apt/sources.list.d"
	cat > "${stage}/etc/apt/sources.list.d/os7.sources" <<-SOURCES
		# OS/7's own repository. CURATION-AND-DELIVERY-PLAN.md C7.
		# Owned by os7-release; edit the release pin, not this file.
		Types: deb
		URIs: ${OS7_REPO_URI}
		Suites: ${OS7_SUITE}
		Components: main
		Architectures: ${OS7_ARCH}
		Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg
		Enabled: ${OS7_REPO_ENABLED}
	SOURCES
	chmod 0644 "${stage}/etc/apt/sources.list.d/os7.sources"

	# The firstboot migration runner — C10 §6'. The unit and the script come in
	# from tree/; what is decided here is their MODES (a bind-mounted source
	# tree on the Windows host reports whatever the mount feels like, so modes
	# are asserted at build rather than inherited) and the enablement, which is
	# a shipped symlink exactly as os7-backup's units do it: `systemctl enable`
	# needs a running systemd and a chroot has none.
	chmod 0644 "${stage}/usr/lib/systemd/system/os7-migrations-firstboot.service"
	chmod 0755 "${stage}/usr/libexec/os7-migrate-firstboot"
	install -d "${stage}/usr/lib/systemd/system/multi-user.target.wants"
	ln -sfn ../os7-migrations-firstboot.service \
		"${stage}/usr/lib/systemd/system/multi-user.target.wants/os7-migrations-firstboot.service"

	# The unattended check (§6): timer, service, and the pwsh -File script —
	# 0644 and no shebang, the os7-backup convention. The TIMER SHIPS ENABLED,
	# by symlink like everything else here, and that is a decision with a
	# reason: checking is a signed-index fetch and staging builds an INERT
	# environment — the machine never activates and never reboots itself — so
	# enabled-by-default is §6's "on a managed fleet nobody types Update-OS7"
	# made true, at zero risk to anybody's uptime. On a machine with no channel
	# configured (the shipped state) the check says so and exits 0.
	chmod 0644 "${stage}/usr/lib/systemd/system/os7-update-check.service" \
	           "${stage}/usr/lib/systemd/system/os7-update-check.timer" \
	           "${stage}/usr/libexec/os7-update-check"
	if head -c 2 "${stage}/usr/libexec/os7-update-check" | grep -q '#!'; then
		echo "!!! os7-release: os7-update-check has a shebang; it is pwsh -File, never executed" >&2
		exit 1
	fi
	install -d "${stage}/usr/lib/systemd/system/timers.target.wants"
	ln -sfn ../os7-update-check.timer \
		"${stage}/usr/lib/systemd/system/timers.target.wants/os7-update-check.timer"

	# The journal-flush ordering drop-in (BUILD-NOTES #109): /var/log is a ZFS
	# dataset with no mount unit, so without this the flush writes the journal
	# onto the boot environment's root dataset and zfs-mount then buries it.
	# Comes in from tree/; the mode is asserted here like every tree file.
	chmod 0644 "${stage}/usr/lib/systemd/system/systemd-journal-flush.service.d/os7.conf"

	# THE MIGRATIONS THE RELEASE BEING CUT INTRODUCES, staged under ITS version.
	#
	# The contract keys a migration by the release that introduced it
	# (README), and a static directory in the tree cannot know the version a
	# build will be given — the Build field comes from git at build time. So
	# migrations are AUTHORED in migrations.d/<context>/NN-name and shipped
	# under <this build's version>. The consequence is deliberate and the
	# README says it out loud: until a migration is retired to a static
	# version directory, every release re-introduces it under its own version,
	# and it therefore runs at each release's first boot — which is exactly
	# right for the one migration that exists (UL1 asks "does the seal open
	# against THIS boot" and is a no-op when it does), and is why idempotence
	# is the contract's requirement rather than a courtesy.
	local mig_src="${SRC}/os7-release/migrations.d"
	if [[ -d "${mig_src}" ]]; then
		local ctx
		for ctx in chroot firstboot; do
			[[ -d "${mig_src}/${ctx}" ]] || continue
			install -d "${stage}/usr/lib/os7/migrations/${OS7_VERSION}/${ctx}"
			cp "${mig_src}/${ctx}/"* \
				"${stage}/usr/lib/os7/migrations/${OS7_VERSION}/${ctx}/"
			chmod 0644 "${stage}/usr/lib/os7/migrations/${OS7_VERSION}/${ctx}/"*
		done
	fi

	pkg_copyright os7-release "${stage}"
	pkg_control  os7-release "${stage}" all
	pkg_finish   os7-release "${stage}" all \
		./usr/lib/os7/release.conf \
		./usr/lib/os7/build.conf \
		./usr/lib/os7/release.json \
		./usr/lib/os7/os-release-identity.py \
		./usr/lib/os7/migrations/README \
		"./usr/lib/os7/migrations/${OS7_VERSION}/firstboot/50-tpm2-reseal" \
		./usr/lib/systemd/system/os7-migrations-firstboot.service \
		./usr/lib/systemd/system/multi-user.target.wants/os7-migrations-firstboot.service \
		./usr/libexec/os7-migrate-firstboot \
		./usr/lib/systemd/system/os7-update-check.timer \
		./usr/lib/systemd/system/timers.target.wants/os7-update-check.timer \
		./usr/libexec/os7-update-check \
		./usr/share/keyrings/os7-archive-keyring.gpg \
		./etc/apt/sources.list.d/os7.sources
}

# ---------------------------------------------------------------------------
# os7-console — what the console looks like before anything logs in.
#
# Two fonts by two routes (D9 and D15, BUILD-NOTES #52) and the palette (D5),
# all GENERATED by the same three scripts build.sh calls. /etc/default/
# console-setup belongs to the console-setup package, so it is diverted rather
# than overwritten — the difference between owning a file and standing on it.
# ---------------------------------------------------------------------------
build_os7_console() {
	local stage; stage="$(pkg_begin os7-console)"

	local fonts="${stage}/usr/share/consolefonts"
	mkdir -p "${fonts}"
	"${REPO}/build/lib/build-console-font.sh"           "${fonts}" "${WORK}/cache/fonts"
	"${REPO}/build/lib/build-installed-console-font.sh" "${fonts}" "${WORK}/cache/fonts"

	local required
	for required in os7-fixedsys-8x16 os7-fixedsys-16x32 os7-console-8x16 os7-console-16x32; do
		if [[ ! -s "${fonts}/${required}.psf.gz" ]]; then
			echo "!!! os7-console: the font step produced no ${required}.psf.gz" >&2
			exit 1
		fi
	done

	# BOTH BUILDERS LEAVE THEIR UNCOMPRESSED 8x16 INTERMEDIATE BEHIND —
	# os7-fixedsys-8x16.psf and os7-console-8x16.psf, beside the .psf.gz they
	# were compressed into. Nothing reads them: /etc/default/console-setup names
	# a .psf.gz, os7-setup names a .psf.gz, and both builders' own checks only
	# ever look for the compressed name. So they are a second copy of two fonts,
	# shipped for nobody.
	#
	# The same two files are in the ISO today, because build.sh stages this same
	# directory into includes.chroot — small, and worth removing there in the
	# change that switches the image over to these packages.
	rm -f "${fonts}"/*.psf

	# OFL 1.1 §2: the licence travels with the font. build-installed-console-
	# font.sh writes it into <dst>/../doc/os7-console-font/, which is inside the
	# stage. An image missing it boots, looks right, and is out of compliance —
	# so it is checked here the same way the PSFs are (SETUP-PLAN L29).
	if [[ ! -s "${stage}/usr/share/doc/os7-console-font/LICENSE" ]]; then
		echo "!!! os7-console: the Cascadia PSFs are staged and their licence is not." >&2
		exit 1
	fi

	python3 "${REPO}/build/lib/palette.py" verify
	python3 "${REPO}/build/lib/palette.py" write "${stage}/usr/share/os7"

	# The console-setup defaults, as OS/7's own file at OS/7's own path. The
	# postinst diverts /etc/default/console-setup and points it here.
	install -Dm644 "${REPO}/build/config/includes.chroot/etc/default/console-setup" \
		"${stage}/usr/share/os7/console-setup"

	pkg_copyright os7-console "${stage}"
	pkg_control  os7-console "${stage}" all
	pkg_finish   os7-console "${stage}" all \
		./usr/share/consolefonts/os7-fixedsys-16x32.psf.gz \
		./usr/share/consolefonts/os7-console-16x32.psf.gz \
		./usr/share/os7/palette-default.vtrgb \
		./usr/share/os7/palette-contrast.vtrgb \
		./usr/share/os7/console-setup \
		./usr/share/doc/os7-console-font/LICENSE
}

# ---------------------------------------------------------------------------
# os7-module — the six PowerShell modules, from their one source each.
#
# Zfs, Net, Time, Systemd and Directory are the generic layers and OS7 is the
# product layer on top of them (ZFS-POWERSHELL-PLAN Z1, POWERSHELL-SURFACE-PLAN
# P2 and P2-time). They travel in one package because those rules are only true
# if all of them are present: an OS7 module on a machine without the layer
# beneath it is a module that cannot do anything, and check-layering.py holds
# the line between them in the source tree rather than in the archive.
#
# THIS LOOP SAID `Zfs OS7` UNTIL 2026-08-27, AND THAT WAS A DEFECT rather than a
# staging that had not caught up. build.sh has staged Net, Time and Systemd into
# the ISO since each was written, so an ISO-installed machine has all of them and
# every check in installer/testing/ was run against one. A machine installed from
# OS/7's own apt repository had two.
#
# The symptom is not a missing file, which is why nothing noticed. OS7's lazy
# loaders — Import-OS7NetLayer, Import-OS7TimeLayer, Import-OS7SystemdLayer —
# try the module beside them, then /usr/local/share/powershell/Modules, and then
# fall through to `Import-Module <Name> -Force -ErrorAction Stop` BY NAME. On a
# machine where the .deb put nothing there, all three candidates are the same
# absent path, and the first network, clock or service cmdlet an operator runs
# throws (measured with pwsh 7.6.5, 2026-08-27):
#
#     The specified module 'Net' was not loaded because no valid module file was
#     found in any module directory.
#
# — a module the operator never asked for, named in an error from a cmdlet that
# has nothing to do with modules.
#
# Nothing looked, in the two places that could have: check-os7-repo.py asserts
# that os7-module is INSTALLED AT THE VERSION and never what is inside it, and
# pkg_finish's required-path list named only OS7 and Zfs files — so the .deb was
# checked against a list that agreed with the bug. That is trap #13's shape
# exactly: a step reported success for something it never did, and its check was
# written from the same wrong assumption. The list below now names one manifest
# and one .psm1 per module, so the loop and the check cannot drift together.
#
# THE .psd1 IS STAMPED with the release version, exactly as build.sh does when
# it stages into includes.chroot, so `Get-Module OS7` and the package agree.
# ---------------------------------------------------------------------------
build_os7_module() {
	local stage; stage="$(pkg_begin os7-module)"
	local root="${stage}/usr/local/share/powershell/Modules"
	local name

	# The generic layers first and OS7 last, in the order hook 0060 checks them
	# and for the same reason: OS7 sits on top of all five.
	for name in Zfs Net Time Systemd Directory OS7; do
		local src="${REPO}/powershell/${name}" dst="${root}/${name}"
		[[ -d "${src}" ]] || { echo "!!! os7-module: ${src} is missing" >&2; exit 1; }
		mkdir -p "${dst}"
		cp -a "${src}/." "${dst}/"
		# Modules ship no tests. powershell/<name>/tests/ is the module's own
		# fixture tree and belongs in the repository, not on a machine.
		#
		# THE ISO AND THE .deb DIFFER HERE ON PURPOSE, and the difference is not
		# drift: build.sh overlays the fixtures into includes.chroot so the
		# chroot self-tests at build time and check-image.py over the finished
		# artefact can run at all — the subsystems being parsed cannot run in
		# either place. dpkg does not remove unowned files, so the package's
		# content and the fixtures end up side by side. Nothing runs a
		# self-test as part of INSTALLING this package, so here they are weight.
		rm -rf "${dst}/tests"

		local manifest="${dst}/${name}.psd1"
		[[ -f "${manifest}" ]] || { echo "!!! os7-module: ${manifest} is missing" >&2; exit 1; }
		sed -i -E "s/^([[:space:]]*ModuleVersion[[:space:]]*=[[:space:]]*)'[^']*'/\\1'${OS7_VERSION}'/" \
			"${manifest}"
		if ! grep -qE "ModuleVersion[[:space:]]*=[[:space:]]*'${OS7_VERSION}'" "${manifest}"; then
			echo "!!! os7-module: could not stamp ModuleVersion = ${OS7_VERSION} into ${name}.psd1" >&2
			exit 1
		fi
	done

	find "${root}" -type f -exec chmod 0644 {} +

	pkg_copyright os7-module "${stage}"
	pkg_control  os7-module "${stage}" all
	# ONE MANIFEST AND ONE .psm1 PER MODULE, not a sample. This list is the only
	# thing that reads the built .deb back, and while it named Zfs and OS7 alone
	# it agreed with the `Zfs OS7` loop above rather than checking it - so four
	# missing modules produced a green build for as long as both were wrong
	# together. A required-path list that only names what the loop already
	# copies is decoration; one file per module is what makes it an assertion.
	pkg_finish   os7-module "${stage}" all \
		./usr/local/share/powershell/Modules/OS7/OS7.psd1 \
		./usr/local/share/powershell/Modules/OS7/OS7.psm1 \
		./usr/local/share/powershell/Modules/OS7/OS7.Backup.ps1 \
		./usr/local/share/powershell/Modules/OS7/OS7.Home.ps1 \
		./usr/local/share/powershell/Modules/OS7/OS7.Update.ps1 \
		./usr/local/share/powershell/Modules/Zfs/Zfs.psd1 \
		./usr/local/share/powershell/Modules/Zfs/Zfs.psm1 \
		./usr/local/share/powershell/Modules/Net/Net.psd1 \
		./usr/local/share/powershell/Modules/Net/Net.psm1 \
		./usr/local/share/powershell/Modules/Time/Time.psd1 \
		./usr/local/share/powershell/Modules/Time/Time.psm1 \
		./usr/local/share/powershell/Modules/Systemd/Systemd.psd1 \
		./usr/local/share/powershell/Modules/Systemd/Systemd.psm1 \
		./usr/local/share/powershell/Modules/Directory/Directory.psd1 \
		./usr/local/share/powershell/Modules/Directory/Directory.psm1
}

# ---------------------------------------------------------------------------
# os7-backup — the units and the two scripts they run.
#
# The programs are sanoid and syncoid, from the archive; what is OS/7's here is
# which datasets, which targets, and the verification neither tool provides
# (BACKUP-PLAN, BUILD-NOTES #73). The design document ships too, because both
# units carry Documentation=file:///usr/share/os7/BACKUP-PLAN.md and a
# Documentation= naming a file the machine does not have is worse than none.
# ---------------------------------------------------------------------------
build_os7_backup() {
	local stage; stage="$(pkg_begin os7-backup)"
	local inc="${REPO}/build/config/includes.chroot"
	local unit

	for unit in os7-backup-firstboot.service os7-backup-replicate.service \
	            os7-backup-replicate.timer; do
		install -Dm644 "${inc}/usr/lib/systemd/system/${unit}" \
			"${stage}/usr/lib/systemd/system/${unit}"
	done
	# 0644, NOT 0755: these are `pwsh -NoProfile -NonInteractive -File`
	# scripts, never executed — hook 0090 refuses a shebang on them for the
	# same reason, and until 2026-08-28 the package shipped them 0755 while
	# the hook enforced 0644, a disagreement the switch to packages surfaced.
	for unit in os7-backup-firstboot os7-backup-replicate; do
		install -Dm644 "${inc}/usr/libexec/${unit}" "${stage}/usr/libexec/${unit}"
	done

	install -Dm644 "${REPO}/docs/BACKUP-PLAN.md" "${stage}/usr/share/os7/BACKUP-PLAN.md"

	# Pre-enable by shipping the symlinks rather than by calling `systemctl
	# enable` from postinst — the same reasoning as os7-desktop-theme's user
	# unit: in a chroot systemctl can fail for reasons that have nothing to do
	# with this package, and a postinst that swallows that failure leaves a
	# package reporting success having enabled nothing. A symlink is a file.
	install -d "${stage}/usr/lib/systemd/system/multi-user.target.wants"
	ln -sfn ../os7-backup-firstboot.service \
		"${stage}/usr/lib/systemd/system/multi-user.target.wants/os7-backup-firstboot.service"
	install -d "${stage}/usr/lib/systemd/system/timers.target.wants"
	ln -sfn ../os7-backup-replicate.timer \
		"${stage}/usr/lib/systemd/system/timers.target.wants/os7-backup-replicate.timer"

	pkg_copyright os7-backup "${stage}"
	pkg_control  os7-backup "${stage}" all
	pkg_finish   os7-backup "${stage}" all \
		./usr/lib/systemd/system/os7-backup-replicate.timer \
		./usr/lib/systemd/system/timers.target.wants/os7-backup-replicate.timer \
		./usr/libexec/os7-backup-replicate \
		./usr/share/os7/BACKUP-PLAN.md
}

# ---------------------------------------------------------------------------
# os7-setup — the installer binary, for this architecture.
#
# NativeAOT (SETUP-PLAN §6.1, spike S2): 3.2-3.4 MB, no .NET runtime at run
# time, which is what makes it viable as the first thing that runs on a machine.
# The RID is DERIVED from the architecture rather than passed, because getting
# it wrong produces a binary that builds cleanly and cannot execute, and the
# failure would surface as an empty tty1 on a booted image.
# ---------------------------------------------------------------------------
build_os7_setup() {
	local stage; stage="$(pkg_begin os7-setup)"
	local rid
	case "${OS7_ARCH}" in
		amd64) rid=linux-x64   ;;
		arm64) rid=linux-arm64 ;;
	esac

	local dst="${stage}/usr/lib/os7-setup"
	mkdir -p "${dst}"
	echo "    os7-setup: publishing for ${rid}"
	DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
		dotnet publish "${REPO}/installer/src/OS7.Setup" -c Release -r "${rid}" \
		-p:PublishAot=true -o "${dst}" --nologo
	[[ -x "${dst}/os7-setup" ]] || { echo "!!! dotnet publish produced no binary" >&2; exit 1; }
	# Publish leaves debugging symbols beside the binary. They are a third of
	# the size of the thing itself and nothing on the image can read them.
	rm -f "${dst}"/*.dbg "${dst}"/*.pdb

	install -Dm644 "${REPO}/installer/assets/os7-setup.service" \
		"${stage}/usr/lib/systemd/system/os7-setup.service"
	install -Dm755 \
		"${REPO}/build/config/includes.chroot/usr/lib/systemd/system-generators/os7-setup-quiesce" \
		"${stage}/usr/lib/systemd/system-generators/os7-setup-quiesce"

	# The licence is a FILE and not text compiled into the binary, on purpose:
	# what a user agrees to has to be what the medium ships (build.sh's note).
	install -Dm644 "${REPO}/LICENSE"                  "${stage}/usr/share/os7/LICENSE"
	install -Dm644 "${REPO}/installer/SETUP-PLAN.md"  "${stage}/usr/share/os7/SETUP-PLAN.md"

	# On PATH, because the difference between debugging os7-setup and not is
	# whether it can be typed at the shell the F3 key drops to.
	install -d "${stage}/usr/sbin"
	ln -sfn ../lib/os7-setup/os7-setup "${stage}/usr/sbin/os7-setup"

	# os7-setup is built with InvariantGlobalization=false and does not start
	# without ICU. Hook 0080 checks for it in the image; the package says it.
	local icu
	icu="$(apt-cache search --names-only '^libicu[0-9]+$' 2>/dev/null \
	       | awk '{print $1}' | sort -V | tail -n1)"
	[[ -n "${icu}" ]] || { echo "!!! os7-setup: no libicu in the archive" >&2; exit 1; }

	pkg_copyright os7-setup "${stage}"
	pkg_control  os7-setup "${stage}" "${OS7_ARCH}" "OS7_ICU=${icu}"
	pkg_finish   os7-setup "${stage}" "${OS7_ARCH}" \
		./usr/lib/os7-setup/os7-setup \
		./usr/lib/systemd/system/os7-setup.service \
		./usr/lib/systemd/system-generators/os7-setup-quiesce \
		./usr/sbin/os7-setup \
		./usr/share/os7/LICENSE
}

# ---------------------------------------------------------------------------
# os7-powershell — the shell, repacked from the pinned upstream tarball.
#
# The single largest unowned thing on an OS/7 machine until now: hook 0020
# untars 66 MB into /opt/microsoft/powershell/7 and symlinks /usr/bin/pwsh, and
# dpkg has never known any of it existed. That is C7 §6.1's first row, and it is
# why `Update-OS7` could not have moved the interactive shell the product is
# named for.
#
# PINNED BY VERSION AND HASH, and verified before anything is unpacked. A silent
# swap here ships a compromised interactive shell to every OS/7 user, so the
# check is not a formality and its failure is fatal rather than a warning.
#
# THE SYMLINK POINTS AT THE 7 DIRECTORY, NOT AT A 7.6.5 ONE. "the installed
# PowerShell version" then stays true across an upgrade with nothing here to
# edit — a version-specific link would be correct today and stale in silence
# (SESSION-DESKTOP-DEBRAND §6a).
# ---------------------------------------------------------------------------
build_os7_powershell() {
	local stage; stage="$(pkg_begin os7-powershell)"
	local pwsh_arch pwsh_sha
	case "${OS7_ARCH}" in
		amd64) pwsh_arch="x64";   pwsh_sha="${OS7_PWSH_SHA256_x64}"   ;;
		arm64) pwsh_arch="arm64"; pwsh_sha="${OS7_PWSH_SHA256_arm64}" ;;
	esac

	local tarball="powershell-${OS7_PWSH_VERSION}-linux-${pwsh_arch}.tar.gz"
	local url="https://github.com/PowerShell/PowerShell/releases/download/v${OS7_PWSH_VERSION}/${tarball}"
	local cache="${WORK}/cache/pwsh"
	mkdir -p "${cache}"

	if [[ ! -s "${cache}/${tarball}" ]]; then
		echo "    os7-powershell: fetching ${tarball}"
		# Retry: a 66 MB fetch from GitHub is the most failure-prone step in
		# this build. A 2026-08-22 run died mid-transfer on an SSL_read EOF.
		curl -fsSL --retry 5 --retry-delay 3 --retry-connrefused --retry-all-errors \
			-o "${cache}/${tarball}" "${url}"
	fi
	echo "${pwsh_sha}  ${cache}/${tarball}" | sha256sum -c - >/dev/null \
		|| { echo "!!! os7-powershell: SHA256 MISMATCH for ${tarball}" >&2
		     echo "!!! Refusing to package it. Either the release was replaced or" >&2
		     echo "!!! the download was tampered with." >&2; exit 1; }
	echo "    os7-powershell: sha256 ok"

	local dest="${stage}/opt/microsoft/powershell/7"
	install -d -m 0755 "${dest}"
	tar -xzf "${cache}/${tarball}" -C "${dest}"
	chmod +x "${dest}/pwsh"

	install -d "${stage}/usr/bin"
	ln -sfn /opt/microsoft/powershell/7/pwsh "${stage}/usr/bin/pwsh"

	# The interactive-shell hand-off, from its one source. Every guard in it
	# exists to avoid breaking something specific — see the file's own header
	# and BUILD-NOTES #86 for the half that had never fired.
	install -Dm644 "${SRC}/os7-powershell/95-os7-powershell.sh" \
		"${stage}/etc/profile.d/95-os7-powershell.sh"

	# ICU, resolved rather than hardcoded: the soname version changes between
	# Ubuntu releases and a stale pin fails as an unhelpful "package not found".
	# PowerShell is a .NET application and aborts at startup without it, with a
	# message about an ICU package rather than about PowerShell.
	local icu
	icu="$(apt-cache search --names-only '^libicu[0-9]+$' 2>/dev/null \
	       | awk '{print $1}' | sort -V | tail -n1)"
	if [[ -z "${icu}" ]]; then
		echo "!!! os7-powershell: no libicu package in the archive — PowerShell cannot run" >&2
		exit 1
	fi
	echo "    os7-powershell: ICU dependency resolves to ${icu}"

	pkg_copyright os7-powershell "${stage}"
	# The upstream licence travels with the binaries.
	if [[ -s "${dest}/LICENSE.txt" ]]; then
		install -m 0644 "${dest}/LICENSE.txt" \
			"${stage}/usr/share/doc/os7-powershell/copyright.powershell"
	fi

	pkg_control os7-powershell "${stage}" "${OS7_ARCH}" "OS7_ICU=${icu}"
	pkg_finish  os7-powershell "${stage}" "${OS7_ARCH}" \
		./opt/microsoft/powershell/7/pwsh \
		./usr/bin/pwsh \
		./etc/profile.d/95-os7-powershell.sh
}

# ---------------------------------------------------------------------------
# The metapackages (C6).
#
# THIS IS WHAT MAKES MEMBERSHIP EXECUTABLE. §5: the package contract is the
# metapackage, and `apt-mark auto` plus `autoremove` do the convergence. It is
# also what step 5 of the update sequence installs by version
# (`apt install os7-<mode>=<version>`), which is how a release moves a machine's
# whole membership rather than only the versions of what it already has.
#
# They carry no files at all. A metapackage with files is a package doing two
# jobs, and the second one cannot be removed without the first.
# ---------------------------------------------------------------------------
build_metapackage() {
	local name="$1"
	local stage; stage="$(pkg_begin "${name}")"
	pkg_copyright "${name}" "${stage}"
	pkg_control  "${name}" "${stage}" all
	pkg_finish   "${name}" "${stage}" all "./usr/share/doc/${name}/copyright"
}

# ---------------------------------------------------------------------------
ALL=(os7-release os7-console os7-module os7-powershell os7-backup os7-setup
     os7-base os7-server os7-desktop)

WANT=( "$@" )
if (( ${#WANT[@]} == 0 )); then WANT=( "${ALL[@]}" ); fi

for pkg in "${WANT[@]}"; do
	case "${pkg}" in
		os7-release) build_os7_release ;;
		os7-console) build_os7_console ;;
		os7-module)  build_os7_module  ;;
		os7-powershell) build_os7_powershell ;;
		os7-backup)  build_os7_backup  ;;
		os7-setup)   build_os7_setup   ;;
		os7-base|os7-server|os7-desktop) build_metapackage "${pkg}" ;;
		*) echo "!!! unknown package '${pkg}'. Known: ${ALL[*]}" >&2; exit 1 ;;
	esac
done

echo "    ${#WANT[@]} package(s) in ${OUT_DIR}"
