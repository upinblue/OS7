#!/bin/bash
# =============================================================================
# OS/7 — RELEASE-PROCESS.md §3 step 6: sign a cut repository with the RELEASE
# key, off the build, by the operator, and prove what was signed.
#
#   scripts/sign-release.sh <tree> <version> <channel>
#   scripts/sign-release.sh out/os7-repo 1.0.0.261 preview
#
# Run it in an INTERACTIVE Linux shell (on the Windows host: `wsl`, then cd to
# the repository on /mnt/c). gpg asks for the release key's passphrase on the
# terminal itself, ONCE, and gpg-agent keeps it for the signatures after the
# first; nothing here reads, stores or passes a passphrase.
#
# On the terminal itself means `--pinentry-mode loopback`, not pinentry-curses.
# In the desktop app's terminal panel the curses dialog twice ended with
# "signing failed: Timeout" about a minute after it was drawn, with nobody
# typing and nothing signed. In a plain pty the same dialog waited 150 s until
# its input closed, and a SIGWINCH did not end it, so what closed it in the
# panel is not known. Loopback was measured instead: one prompt, three gpg
# processes, three good signatures.
#
# WHY THIS IS A SCRIPT AND NOT THREE gpg LINES. Step 6 was written as "replace
# the three signatures", and that is not the whole of it. Every descriptor
# build-os7-repo.sh writes carries a `signing` block naming the key the CUT was
# made with, and Get-OS7Release decides `Development` from that block, not from
# the signature over the index (BUILD-NOTES #187). A cut is made with the
# development key, because the release key is never reachable unattended (C7a),
# so a release whose index and Release were re-signed by the release key and
# nothing else would still say, in a file the signed index vouches for, that it
# is a development build — and Update-OS7 would demand -AllowDevelopment for it
# for ever. Both published previews, 1.0.0.175 and 1.0.0.203, are in that state
# on the server, with the development key's signatures as well.
#
# So, for the ONE version being published, and nothing else:
#
#   1. the key: exactly one secret key in the GNUPGHOME, its user ID must not
#      say NOT FOR RELEASE, and its fingerprint must be the one in the public
#      half the media ship (os7-release-key.pub) — signing with a key no
#      machine trusts is a release nobody can install;
#   2. each releases/<version>/<arch>/release.json gets a signing block naming
#      THAT key, written the way the builder writes it (json, indent 2);
#   3. index/<channel>.json's entries for <version> get the new descriptors'
#      sha256, so Get-OS7Release's hash check still holds;
#   4. every dists/<suite>/Release is signed (Release.gpg and InRelease) and
#      the index is signed (.asc) — ALL suites, because the cut re-signed all
#      of them with the development key and one left behind is a published
#      development signature;
#   5. ASKED BACK: each signature is checked with gpgv against a keyring that
#      holds the release key's public half and nothing else, the VALIDSIG
#      fingerprint is required to be the release key's, every descriptor in the
#      index is required to hash to its entry, and every descriptor of
#      <version> is required to say development=false.
#
# WHAT IT DOES NOT DO: upload. Publishing is RELEASE-PROCESS §3 step 8, in its
# order — payload first, index last — and is a separate act.
# =============================================================================
set -uo pipefail

die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

[[ $# -eq 3 ]] || die "usage: $0 <tree> <version> <channel>"
TREE="$(cd "$1" 2>/dev/null && pwd)" || die "no such tree: $1"
VERSION="$2"
CHANNEL="$3"

[[ "$(uname -s)" == Linux ]] || die "run this in a Linux shell (on Windows: wsl)."
[[ -t 0 && -t 1 ]] || die "no terminal: gpg has nowhere to ask for the passphrase."
for t in gpg gpgv python3 sha256sum; do command -v "$t" >/dev/null || die "no $t in PATH"; done

GNUPGHOME_REL="${OS7_GNUPGHOME:-${HOME}/.os7/gnupg-release}"
if [[ -z "${OS7_RELEASE_PUBKEY:-}" && -d /mnt/c/Users ]]; then
	for d in /mnt/c/Users/*/.os7/os7-release-key.pub; do [[ -s "$d" ]] && OS7_RELEASE_PUBKEY="$d" && break; done
fi
PUBKEY="${OS7_RELEASE_PUBKEY:-${HOME}/.os7/os7-release-key.pub}"
[[ -s "$PUBKEY" ]] || die "no release public key at $PUBKEY (set OS7_RELEASE_PUBKEY)"
INDEX="${TREE}/index/${CHANNEL}.json"
[[ -s "$INDEX" ]] || die "no index at $INDEX"
compgen -G "${TREE}/releases/${VERSION}/*/release.json" >/dev/null \
	|| die "no descriptor for ${VERSION} under ${TREE}/releases/"
compgen -G "${TREE}/dists/*/Release" >/dev/null || die "no dists/*/Release under ${TREE}"

# A terminal for pinentry. `$(tty)` prints "not a tty" when there is none, and
# that once silently blanked GNUPGHOME in setup-release-credentials.sh.
GPG_TTY="$(tty)" && export GPG_TTY || die "tty did not answer"

# --- 1. the key --------------------------------------------------------------
say ">>> the key"
# The fingerprint printed right after each `sec` line - the primary key's, not
# a subkey's.
mapfile -t SECS < <(gpg --homedir "$GNUPGHOME_REL" --batch --with-colons -K 2>/dev/null \
	| awk -F: '$1=="sec"{want=1; next} want && $1=="fpr"{print $10; want=0}')
[[ ${#SECS[@]} -eq 1 ]] || die "expected exactly one secret key in $GNUPGHOME_REL, found ${#SECS[@]}"
FPR="${SECS[0]}"
UID_="$(gpg --homedir "$GNUPGHOME_REL" --batch --with-colons -K "$FPR" | awk -F: '$1=="uid"{print $10; exit}')"
[[ "$UID_" != *"NOT FOR RELEASE"* ]] || die "the secret key says NOT FOR RELEASE: $UID_"
PUBFPR="$(gpg --batch --with-colons --show-keys "$PUBKEY" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
[[ "$PUBFPR" == "$FPR" ]] || die "the secret key ($FPR) is not the public half the media ship ($PUBFPR)"
say "    $FPR  $UID_"
say "    and it is the key in $PUBKEY, which the media's trust anchor carries"

# --- 2 and 3. the descriptors and the index ----------------------------------
say ">>> the descriptors of ${VERSION} name the key that signs them"
OS7_FPR="$FPR" OS7_UID="$UID_" python3 - "$TREE" "$VERSION" "$CHANNEL" <<'PY' || die "rewriting the descriptors failed"
import glob, hashlib, json, os, sys
tree, version, channel = sys.argv[1:4]
signing = {"key": os.environ["OS7_FPR"], "user_id": os.environ["OS7_UID"],
           "development": "NOT FOR RELEASE" in os.environ["OS7_UID"]}
shas = {}
for path in sorted(glob.glob(os.path.join(tree, "releases", version, "*", "release.json"))):
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
    before = d.get("signing")
    d["signing"] = signing
    # the builder's own form: json.dump(..., indent=2, sort_keys=False) + "\n"
    text = json.dumps(d, indent=2, sort_keys=False) + "\n"
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    arch = d["architecture"]
    shas[arch] = hashlib.sha256(text.encode("utf-8")).hexdigest()
    print(f"    releases/{version}/{arch}/release.json: was {before and before.get('user_id')!r}, "
          f"development={before and before.get('development')} -> development={signing['development']}")
ipath = os.path.join(tree, "index", channel + ".json")
with open(ipath, encoding="utf-8") as fh:
    index = json.load(fh)
hit = 0
for e in index["releases"]:
    if e.get("version") == version and e.get("architecture") in shas:
        e["manifest_sha256"] = shas[e["architecture"]]
        hit += 1
if hit != len(shas):
    sys.exit(f"index/{channel}.json names {hit} of the {len(shas)} descriptors of {version}")
with open(ipath, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(index, fh, indent=2)
    fh.write("\n")
print(f"    index/{channel}.json: {hit} entries carry the new descriptors' sha256")
PY

# --- 4. sign ------------------------------------------------------------------
say ">>> signing (gpg asks for the passphrase once)"
sign() { gpg --homedir "$GNUPGHOME_REL" --yes --pinentry-mode loopback --local-user "$FPR" --digest-algo SHA512 "$@"; }
for rel in "${TREE}"/dists/*/Release; do
	d="$(dirname "$rel")"
	rm -f "$d/Release.gpg" "$d/InRelease"
	sign --armor --detach-sign --output "$d/Release.gpg" "$rel" || die "signing $rel failed"
	sign --clearsign --output "$d/InRelease" "$rel" || die "clearsigning $rel failed"
	say "    ${d#"$TREE"/}: Release.gpg, InRelease"
done
rm -f "${INDEX}.asc"
sign --armor --detach-sign --output "${INDEX}.asc" "$INDEX" || die "signing the index failed"
say "    index/${CHANNEL}.json.asc"

# --- 5. ask it back -------------------------------------------------------------
say ">>> asked back, against the release key's public half ALONE"
KR="$(mktemp -d)"
trap 'rm -rf "$KR"' EXIT
gpg --homedir "$KR" --batch -q --import "$PUBKEY" 2>/dev/null
gpg --homedir "$KR" --batch --export > "$KR/release.gpg"
verify() {  # <what> <gpgv args...>
	local what="$1"; shift
	local st
	st="$(gpgv --status-fd 1 --keyring "$KR/release.gpg" "$@" 2>/dev/null)" || die "$what does NOT verify against the release key"
	# VALIDSIG's LAST field is the primary key's fingerprint whichever subkey
	# made the signature, so that is the one held to the release key.
	awk -v f="$FPR" '$2=="VALIDSIG" && $NF==f {ok=1} END {exit !ok}' <<<"$st" \
		|| die "$what verifies, but not by ${FPR}"
	[[ "$(grep -c '^\[GNUPG:\] NEWSIG' <<<"$st")" -eq 1 ]] || die "$what carries more than one signature"
	say "    ok  $what — one signature, ${FPR}"
}
for rel in "${TREE}"/dists/*/Release; do
	d="$(dirname "$rel")"
	verify "${d#"$TREE"/}/Release.gpg" "$d/Release.gpg" "$rel"
	verify "${d#"$TREE"/}/InRelease" "$d/InRelease"
done
verify "index/${CHANNEL}.json.asc" "${INDEX}.asc" "$INDEX"

python3 - "$TREE" "$VERSION" "$CHANNEL" <<'PY' || die "the index and the descriptors disagree"
import hashlib, json, os, sys
tree, version, channel = sys.argv[1:4]
index = json.load(open(os.path.join(tree, "index", channel + ".json"), encoding="utf-8"))
bad = 0
for e in index["releases"]:
    p = os.path.join(tree, e["manifest"])
    got = hashlib.sha256(open(p, "rb").read()).hexdigest()
    ok = got == e["manifest_sha256"]
    dev = json.load(open(p, encoding="utf-8")).get("signing", {}).get("development")
    if e["version"] == version and dev is not False:
        ok = False
    bad += not ok
    print(f"    {'ok  ' if ok else 'FAIL'} {e['version']} {e['architecture']}: descriptor hash "
          f"{'matches' if got == e['manifest_sha256'] else 'DIFFERS'}, development={dev}")
sys.exit(1 if bad else 0)
PY

say ""
say "SIGNED: ${VERSION} in index/${CHANNEL}.json, by ${FPR}."
say "Nothing is uploaded. RELEASE-PROCESS §3 step 8: pool/, dists/, releases/ first, the index LAST."
