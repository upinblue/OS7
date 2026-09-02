#!/bin/bash
# =============================================================================
# OS/7 — the two credentials a release needs, set up once, on the operator's
# machine and nowhere else.
#
#   scripts/setup-release-credentials.sh
#
# It creates, and then PROVES it created:
#
#   1. the release signing key            ~/.os7/gnupg-release      (secret half)
#      its public half exported to        $OS7_DIR/os7-release-key.pub
#   2. the Storage Box configuration      $OS7_DIR/storagebox.conf  (mode 0600)
#
# WHY A SCRIPT AND NOT A LIST OF COMMANDS. Both of these were attempted as
# one-liners and both failed for reasons that had nothing to do with GnuPG:
# PowerShell does not understand `VAR=value cmd`, has no `chmod`, and
# `GPG_TTY=$(tty)` expands to the three words "not a tty" when there is no
# terminal, which silently blanked GNUPGHOME and left gpg pointing at a
# directory nothing had created. A release credential is not the place to
# discover shell portability.
#
# WHAT THIS SCRIPT DOES NOT DO, deliberately:
#   * it never prints a passphrase or a password, and never puts one in a
#     command line, where it would reach the shell history and `ps`;
#   * it does not generate a key that already exists — two release keys made by
#     accident is a hazard of its own, because only one of them ends up in the
#     anchors and finding out which costs a release;
#   * it does not sign anything. Trusting a key and signing with it are separate
#     acts, and only the public half ever goes near a build (C7a).
#
# RUN IT FROM AN INTERACTIVE LINUX SHELL. On the Windows host that means:
# type `wsl`, wait for the prompt to change, then run it. pinentry needs a
# terminal and there is no way around that.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# Where the operator's OS/7 files live. OUTSIDE the repository, because this
# repository is public and a .gitignore is one `git add -f` away from a leak.
# On the Windows host the Windows-visible path is what the build can mount, so
# that is the default; override with OS7_DIR.
if [[ -d /mnt/c/Users && -z "${OS7_DIR:-}" ]]; then
	_win_user="$(ls /mnt/c/Users 2>/dev/null | grep -vixE 'public|default|default user|all users|desktop.ini' | head -1)"
	OS7_DIR="/mnt/c/Users/${_win_user}/.os7"
fi
OS7_DIR="${OS7_DIR:-${HOME}/.os7}"

# The GNUPGHOME is NOT under OS7_DIR, and that is BUILD-NOTES #97: gpg-agent
# must create a unix socket inside GNUPGHOME, and a Windows bind mount (drvfs,
# 9p) refuses to hold one — every gpg operation then dies before it starts, with
# an error that names the socket and not the filesystem.
GNUPGHOME_REL="${OS7_GNUPGHOME:-${HOME}/.os7/gnupg-release}"

KEY_UID="${OS7_RELEASE_KEY_UID:-OS/7 release signing key <release@os7.org>}"
KEY_MAIL="${OS7_RELEASE_KEY_MAIL:-release@os7.org}"
PUBKEY_OUT="${OS7_DIR}/os7-release-key.pub"
SB_CONF="${OS7_DIR}/storagebox.conf"

say()  { printf '%s\n' "$*"; }
step() { printf '\n>>> %s\n' "$*"; }
die()  { printf '\n!!! %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. The environment this needs, asked rather than assumed
# ---------------------------------------------------------------------------
step "checking where we are"

[[ "$(uname -s)" == "Linux" ]] || die "this must run in a Linux shell. On Windows: type 'wsl' first, wait for the prompt to change, then run it again."

if [[ ! -t 0 || ! -t 1 ]]; then
	die "no terminal on stdin/stdout. pinentry cannot ask for a passphrase without one — run this directly in an interactive shell, not through a pipe, and not through 'wsl -e ... < file'."
fi

command -v gpg >/dev/null || die "no gpg in PATH."
say "    gpg          $(gpg --version | head -1)"

case "${GNUPGHOME_REL}" in
	/mnt/*|/media/*|/cygdrive/*)
		die "GNUPGHOME would be ${GNUPGHOME_REL}, which is a Windows mount. gpg-agent cannot put its socket there (BUILD-NOTES #97). Set OS7_GNUPGHOME to a path on the Linux filesystem." ;;
esac

[[ -d "${OS7_DIR}" ]] || mkdir -p "${OS7_DIR}" || die "cannot create ${OS7_DIR}"
say "    OS7_DIR      ${OS7_DIR}"
say "    GNUPGHOME    ${GNUPGHOME_REL}"

# ---------------------------------------------------------------------------
# 1. The release signing key
# ---------------------------------------------------------------------------
step "the release signing key"

mkdir -p "${GNUPGHOME_REL}" || die "cannot create ${GNUPGHOME_REL}"
chmod 0700 "${GNUPGHOME_REL}"
export GNUPGHOME="${GNUPGHOME_REL}"

# The socket directory under /run/user, which gpg uses automatically when it
# exists and which nothing creates in a shell with no logind session.
mkdir -p "/run/user/$(id -u)" 2>/dev/null || true
chmod 0700 "/run/user/$(id -u)" 2>/dev/null || true
gpgconf --create-socketdir 2>/dev/null || true

# pinentry needs to know which terminal to draw on.
if tty -s; then export GPG_TTY; GPG_TTY="$(tty)"; fi

primary_fpr() {
	gpg --batch --list-keys --with-colons "$1" 2>/dev/null \
		| awk -F: '/^pub:/ {want=1} /^fpr:/ {if (want) {print $10; want=0}}' | head -1
}

EXISTING="$(primary_fpr "${KEY_MAIL}")"
if [[ -n "${EXISTING}" ]]; then
	say "    a key for ${KEY_MAIL} is already here — NOT generating a second one"
	say "    ${EXISTING}"
	FPR="${EXISTING}"
else
	say "    generating ed25519, sign-only, no expiry"
	say "    user id: ${KEY_UID}"
	say ""
	say "    pinentry will now ask for a PASSPHRASE, twice."
	say "    Put it in your password manager before you type it: without the"
	say "    passphrase this key is unusable, and once a release is signed with"
	say "    it, an unusable key means reinstalling every machine rather than"
	say "    updating it."
	say ""
	gpg --quick-generate-key "${KEY_UID}" ed25519 sign never \
		|| die "key generation failed. If pinentry could not draw, check that /usr/bin/pinentry-curses exists and that this is a real terminal."
	FPR="$(primary_fpr "${KEY_MAIL}")"
	[[ -n "${FPR}" ]] || die "gpg reported success and no key for ${KEY_MAIL} is here. Ask gpg --list-secret-keys what happened."
	say ""
	say "    created ${FPR}"
fi

# Refuse the accident that would be discovered a release too late.
SECRET_COUNT="$(gpg --batch --list-secret-keys --with-colons 2>/dev/null | grep -c '^sec:')"
if (( SECRET_COUNT > 1 )); then
	say ""
	say "    !!! ${SECRET_COUNT} secret keys in ${GNUPGHOME_REL}. Only ${FPR} will be"
	say "    !!! exported. If that is not the one you mean to release with, sort it"
	say "    !!! out now — the anchor on every ISO is decided here."
fi

# ---------------------------------------------------------------------------
# 2. The public half, where a build can mount it — and read back
# ---------------------------------------------------------------------------
step "exporting the public half"

gpg --batch --yes --armor --export --output "${PUBKEY_OUT}" "${FPR}" \
	|| die "exporting to ${PUBKEY_OUT} failed"
[[ -s "${PUBKEY_OUT}" ]] || die "${PUBKEY_OUT} is empty. gpg --export writes nothing and exits 0 when it finds no key."

# ASK THE FILE, do not trust the export. This is the same rule the trust anchor
# itself is read back under in build/lib/os7-signing-key.sh.
GOT="$(gpg --batch --show-keys --with-colons "${PUBKEY_OUT}" 2>/dev/null \
	| awk -F: '/^pub:/ {want=1} /^fpr:/ {if (want) {print $10; want=0}}')"
printf '%s\n' "${GOT}" | grep -qx "${FPR}" \
	|| die "${PUBKEY_OUT} does not contain ${FPR}. It holds: ${GOT:-nothing}"
if printf '%s\n' "$(cat "${PUBKEY_OUT}")" | grep -q 'PRIVATE KEY'; then
	rm -f "${PUBKEY_OUT}"
	die "the exported file contained a PRIVATE key block. Removed it. This must never leave the machine."
fi
say "    ${PUBKEY_OUT}"
say "    holds exactly ${FPR}, public only"

# ---------------------------------------------------------------------------
# 3. The Storage Box configuration
# ---------------------------------------------------------------------------
step "the Storage Box configuration"

if [[ -f "${SB_CONF}" ]]; then
	say "    ${SB_CONF} exists — leaving it alone"
	say "    it names:"
	grep -oE '^[A-Z0-9_]+' "${SB_CONF}" 2>/dev/null | sed 's/^/        /'
else
	say "    ${SB_CONF} does not exist yet."
	say "    The read-only sub-account's password goes in it. That password ends up"
	say "    in /etc/apt/auth.conf.d/ on every installed machine, so it must be the"
	say "    READ-ONLY sub-account and never the main account."
	say ""
	read -r -p "    Storage Box host          [u661569.your-storagebox.de] : " SB_HOST
	SB_HOST="${SB_HOST:-u661569.your-storagebox.de}"
	read -r -p "    publish sub-account (rw)  [u661569-sub1] : " SB_PUB
	SB_PUB="${SB_PUB:-u661569-sub1}"
	read -r -p "    repo sub-account (ro)     [u661569-sub2] : " SB_RO
	SB_RO="${SB_RO:-u661569-sub2}"
	# -s: never echoed, and never on a command line where ps could see it.
	read -r -s -p "    password of ${SB_RO}       : " SB_PW; echo
	read -r -s -p "    again                                 : " SB_PW2; echo
	[[ "${SB_PW}" == "${SB_PW2}" ]] || die "the two passwords differ. Nothing written."
	[[ -n "${SB_PW}" ]] || die "an empty password. Nothing written."

	# Written at 0600 from the start: creating it readable and fixing it after
	# leaves a window in which it is not.
	( umask 077; cat > "${SB_CONF}" <<-EOF
		# OS/7 — the Storage Box, for the release tooling.
		# Written by scripts/setup-release-credentials.sh. Mode 0600.
		# OUTSIDE the repository on purpose: this repository is public.
		OS7_SB_HOST=${SB_HOST}
		OS7_SB_PUBLISH_USER=${SB_PUB}
		OS7_SB_REPO_USER=${SB_RO}
		OS7_SB_REPO_PASSWORD=${SB_PW}
	EOF
	) || die "cannot write ${SB_CONF}"
	unset SB_PW SB_PW2
	chmod 0600 "${SB_CONF}" 2>/dev/null || true

	# ASK WHAT THE MODE ACTUALLY IS, because on a Windows mount it will not be
	# what was asked for and nothing says so. MEASURED 2026-09-02: drvfs carries
	# no POSIX modes, so `umask 077` does not apply and `chmod 0600` returns
	# success while changing nothing — the file came out 777. What protects it
	# there is the NTFS ACL of the profile directory (SYSTEM, Administrators and
	# the user, with no Users group), which is adequate. Claiming a mode that was
	# not achieved is not.
	SB_MODE="$(stat -c '%a' "${SB_CONF}" 2>/dev/null || echo '?')"
	if [[ "${SB_MODE}" == "600" ]]; then
		say "    mode 600"
	else
		say "    NOTE: the mode is ${SB_MODE}, not 600."
		case "${SB_CONF}" in
			/mnt/*|/media/*|/cygdrive/*)
				say "          ${SB_CONF} is on a Windows mount, which carries no POSIX"
				say "          modes: chmod succeeds and changes nothing. The file is"
				say "          protected by the NTFS ACL of your profile directory rather"
				say "          than by a mode. Confirm it in PowerShell with"
				# A PowerShell hint must carry a WINDOWS path: printing the
				# /mnt/c form into a PowerShell command is advice that cannot
				# be followed, which is worse than no advice.
				_winpath="${SB_CONF}"
				case "${_winpath}" in
					/mnt/?/*)
						_drive="${_winpath:5:1}"
						_winpath="${_drive^^}:${_winpath:6}"
						_winpath="${_winpath//\//\\}" ;;
				esac
				say "              (Get-Acl '${_winpath}').Access"
				say "          and expect SYSTEM, Administrators and you — nothing else." ;;
			*)
				say "          that is unexpected on a Linux filesystem, and this file"
				say "          holds a password. Fix it before anything reads it." ;;
		esac
	fi

	# Read it back for SHAPE, never for content: a file that was written is not
	# a file that parses, and the next thing to read it is a test that talks to
	# a server.
	# shellcheck disable=SC1090
	( set -a; . "${SB_CONF}"; set +a
	  [[ -n "${OS7_SB_HOST:-}" && -n "${OS7_SB_REPO_USER:-}" && -n "${OS7_SB_REPO_PASSWORD:-}" ]] ) \
		|| die "${SB_CONF} was written and does not parse into the four fields."
	say "    written and parses: ${SB_CONF}"
fi

# ---------------------------------------------------------------------------
# 4. What is still owed, said here so it is not discovered later
# ---------------------------------------------------------------------------
step "done — and one thing is still owed"

say ""
say "  Release key fingerprint:"
say "      ${FPR}"
say "  Public half (mount this into a build):"
say "      ${PUBKEY_OUT}"
say ""
say "  THE SECRET HALF IS ONLY IN ${GNUPGHOME_REL}, which lives in WSL's VHDX."
say "  A 'wsl --unregister', a reset or a disk fault destroys it. Before the"
say "  first release is signed with this key, put a backup somewhere that is"
say "  not this machine:"
say ""
say "      GNUPGHOME=${GNUPGHOME_REL} gpg --armor --export-secret-keys ${KEY_MAIL} > /path/on/a/stick/os7-release-key.SECRET.asc"
say ""
say "  It is passphrase-protected, and it still does not belong on a disk that"
say "  stays plugged in. Password manager or encrypted stick, then delete the"
say "  copy you made."
say ""
