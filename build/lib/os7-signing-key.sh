# OS/7 — the signing key, resolved ONCE and shared. Sourced, not executed.
#
# Two builders need the same key: build-os7-repo.sh signs the suite and the
# release index with it, and build.sh needs its PUBLIC half because os7-release
# — which the ISO now installs — ships the trust anchor. If the two resolved
# keys independently, an ISO's keyring and the repository a machine is pointed
# at would only agree by accident, and Set-OS7UpdateChannel's first
# `apt update` would refuse a repository the same tree built minutes earlier.
# The Makefile therefore hands both targets the same OS7_REPO_GNUPGHOME.
#
# C7a — WHERE A RELEASE KEY LIVES — IS OPEN AND NOT ANSWERED HERE. The rules
# are build-os7-repo.sh's, moved rather than changed: use the key handed in
# (OS7_REPO_GNUPGHOME + OS7_REPO_KEY); generate a DEVELOPMENT key whose user
# ID says so in capitals when there is none; print the fingerprint every run.
# Nothing signed by a generated key may be published.
#
# os7_ensure_signing_key <default-gnupghome> <pubkey-out>
#   sets  OS7_SIGNING_KEY_ID, OS7_SIGNING_KEY_UID
#   exports GNUPGHOME, and the public key (binary, never armoured) to
#   <pubkey-out>.

os7_ensure_signing_key() {
	local default_home="$1" pubkey_out="$2"

	export GNUPGHOME="${OS7_REPO_GNUPGHOME:-${default_home}}"
	mkdir -p "${GNUPGHOME}"
	chmod 0700 "${GNUPGHOME}"

	# GNUPGHOME is a BIND MOUNT of a Windows directory when the Makefile hands
	# it in, and gpg-agent must create a unix socket inside it — which a 9p or
	# drvfs mount refuses, so every gpg operation dies before it starts.
	# MEASURED 2026-08-28: the first containerised key generation failed on
	# exactly this. GnuPG's own answer is the socket directory under
	# /run/user/<uid>, which it uses automatically WHEN IT EXISTS; a build
	# container has no logind to create it, so it is created here. /run is
	# container-local tmpfs, which is precisely what a socket wants.
	mkdir -p "/run/user/$(id -u)"
	chmod 0700 "/run/user/$(id -u)"
	gpgconf --create-socketdir 2>/dev/null || true

	local dev_uid="OS/7 DEVELOPMENT signing key — NOT FOR RELEASE <os7-dev@localhost>"
	OS7_SIGNING_KEY_ID="${OS7_REPO_KEY:-}"

	if [[ -z "${OS7_SIGNING_KEY_ID}" ]]; then
		if ! gpg --batch --list-secret-keys --with-colons 2>/dev/null | grep -q '^sec'; then
			echo "    no signing key in ${GNUPGHOME} — generating a DEVELOPMENT key"
			echo "    (CURATION-AND-DELIVERY-PLAN C7a is open; this is not a release key)"
			# --quick-generate-key with an empty passphrase: this is deliberately
			# a throwaway. A release key must not be reachable unattended by a
			# build script, which is the whole of C7a. NOT silenced: the first
			# containerised run failed inside a >/dev/null 2>&1 and the build
			# died with no line naming gpg at all.
			if ! gpg --batch --pinentry-mode loopback --passphrase '' \
				--quick-generate-key "${dev_uid}" ed25519 sign never; then
				echo "!!! gpg could not generate the development key in ${GNUPGHOME}" >&2
				return 1
			fi
		fi
		OS7_SIGNING_KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
	fi
	[[ -n "${OS7_SIGNING_KEY_ID}" ]] || { echo "!!! no signing key available" >&2; return 1; }

	OS7_SIGNING_KEY_UID="$(gpg --batch --list-keys --with-colons "${OS7_SIGNING_KEY_ID}" \
		| awk -F: '/^uid:/ {print $10; exit}')"
	echo "    signing key ${OS7_SIGNING_KEY_ID}"
	echo "    user id     ${OS7_SIGNING_KEY_UID}"
	case "${OS7_SIGNING_KEY_UID}" in
		*"NOT FOR RELEASE"*)
			echo "    *** DEVELOPMENT KEY. Nothing signed here may be published. ***" ;;
	esac

	# The trust anchor in the form `Signed-By:` wants: a binary keyring holding
	# the public key alone. Never the secret key, and never armoured — apt reads
	# either, but a directory holding an armoured file called .gpg is how a
	# keyring ends up unreadable with an error that names neither.
	install -d "$(dirname "${pubkey_out}")"
	gpg --batch --yes --export --output "${pubkey_out}" "${OS7_SIGNING_KEY_ID}"
	[[ -s "${pubkey_out}" ]] || { echo "!!! exporting the public key produced nothing" >&2; return 1; }
}
