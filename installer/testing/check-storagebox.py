#!/usr/bin/env python3
# =============================================================================
# OS/7 — can apt actually read the repository off a Hetzner Storage Box?
#
#   ./installer/testing/check-storagebox.py            # everything
#   ./installer/testing/check-storagebox.py --probe    # reachability only, no
#                                                      # container, no upload
#
# This is RP2 in docs/RELEASE-PROCESS.md, and it exists because the whole
# delivery choice rests on an assumption nobody has tested: that a Storage Box's
# WebDAV endpoint, which requires HTTP Basic authentication and — on a read-only
# sub-account — answers "HTTP GET requests only", is enough for apt.
#
# THE CONTROL IS THE POINT. "apt update worked" is not evidence that the
# credential was used: it is equally consistent with a repository that answers
# anonymously, which would mean the read-only sub-account was never in the path
# and the whole access model is imaginary. So this asks THREE things and needs
# all three:
#
#   1. without credentials the endpoint REFUSES        (401)
#   2. with the read-only credential apt SUCCEEDS     (and sees os7-base)
#   3. with a WRONG credential apt FAILS              (so 2 proves something)
#
# Nothing here reads a password out of a shell argument or writes one to disk.
# The credential travels to the container on STDIN, inside the script the
# container runs, so it never appears in `ps`, in a bind mount, or in a layer.
#
# It talks to a real server over the network. That is deliberate: BUILD-NOTES is
# full of cases where the transport was the thing that differed, and a mock of a
# WebDAV server would be a mock of the assumption under test.
# =============================================================================

import argparse
import base64
import os
import re
import subprocess
import sys
from pathlib import Path

SUITE_DEFAULT = "os7-1.0"
KEYRING_IN_TREE = Path("out/os7-repo/keyring/os7-archive-keyring.gpg")
CONTAINER = "ubuntu:26.04"

ok_n = 0
fail_n = 0


def ok(name, detail=""):
    global ok_n
    ok_n += 1
    print(f"      ok    {name}" + (f" — {detail}" if detail else ""))


def bad(name, detail=""):
    global fail_n
    fail_n += 1
    print(f"      FAIL  {name}" + (f" — {detail}" if detail else ""))


def note(text):
    print(f"      note  {text}")


def die(msg):
    print(f"\n!!! {msg}", file=sys.stderr)
    sys.exit(1)


def find_conf():
    """The operator's config, OUTSIDE this repository — it holds a password and
    this repository is public. On the Windows host the file lives on the NTFS
    side (that is where a build can mount it from), so both are looked for."""
    cands = [Path.home() / ".os7" / "storagebox.conf"]
    users = Path("/mnt/c/Users")
    if users.is_dir():
        skip = {"public", "default", "default user", "all users"}
        for d in users.iterdir():
            if d.is_dir() and d.name.lower() not in skip:
                cands.append(d / ".os7" / "storagebox.conf")
    for c in cands:
        if c.is_file():
            return c
    die(
        "no storagebox.conf found. Looked in:\n  "
        + "\n  ".join(str(c) for c in cands)
        + "\nRun scripts/setup-release-credentials.sh to create it."
    )


def read_conf(path):
    """KEY=value, and NOTHING is printed from it. The password is returned and
    never logged; a config that parses to the wrong shape is a refusal here
    rather than a confusing 401 three steps later."""
    conf = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r'^([A-Z0-9_]+)=("?)(.*?)\2$', line)
        if m:
            conf[m.group(1)] = m.group(3)
    missing = [
        k
        for k in ("OS7_SB_HOST", "OS7_SB_REPO_USER", "OS7_SB_REPO_PASSWORD")
        if not conf.get(k)
    ]
    if missing:
        die(f"{path} names no {', '.join(missing)}.")
    return conf


def repo_host(conf):
    """THE HOST FOR READING IS NOT THE HOST FOR PUBLISHING, and that cost an
    afternoon. MEASURED 2026-09-02: a Storage Box sub-account has its own
    virtual host — the main account's vhost answers a sub-account's credential
    with 401, indistinguishably from a wrong password, which is exactly how it
    looked. `u661569-sub2.your-storagebox.de` with the same credential answers
    200 on the first try.

    Derived from OS7_SB_HOST by replacing its first label rather than by
    hardcoding your-storagebox.de, so a box on another domain still works.
    OS7_SB_REPO_HOST in the config overrides it.
    """
    if conf.get("OS7_SB_REPO_HOST"):
        return conf["OS7_SB_REPO_HOST"]
    host, _, domain = conf["OS7_SB_HOST"].partition(".")
    return f"{conf['OS7_SB_REPO_USER']}.{domain}" if domain else conf["OS7_SB_HOST"]


def curl_code(host, path, user=None, password=None, timeout=25):
    """An HTTP status code, with the credential passed through curl's config on
    STDIN rather than in -u: an argument is visible in `ps` to every process on
    the machine, and this one ships in every installed OS/7 image."""
    cmd = [
        "curl", "-sS", "-o", os.devnull, "-w", "%{http_code}",
        "-m", str(timeout),
    ]
    stdin = ""
    if user is not None:
        cmd += ["-K", "-"]
        stdin = f'user = "{user}:{password}"\n'
    cmd.append(f"https://{host}{path}")
    try:
        r = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=timeout + 10)
    except subprocess.TimeoutExpired:
        return "timeout"
    return (r.stdout or "").strip() or "no-code"


def apt_probe(conf, suite, keyring_b64, password, base_path):
    """apt update in a CLEAN container against the real endpoint, and a VERDICT
    naming what actually happened rather than a boolean.

    `apt-get update` EXITS 0 WHEN A SOURCE COULD NOT BE FETCHED AT ALL.
    Measured 2026-09-02 in ubuntu:26.04, which ships no ca-certificates:

        Err:1 https://…/repo os7-1.0 InRelease
          SSL connection failed: certificate verify failed
        W: Some index files failed to download. They have been ignored…
        rc=0

    So the exit code says nothing, and the first version of this function read
    that nothing as success — with the right credential AND with a deliberately
    wrong one, which is how a control that cannot fail looks. What matters is
    which of `Get:`/`Hit:`/`Err:`/`Ign:` apt printed for the OS/7 InRelease, and
    whether the failure was an authentication failure or a failure to arrive.
    "Refused as it should be" and "never reached it" are different outcomes and
    only one of them is evidence.

    Everything the container needs — the keyring bytes, the source, the
    credential — arrives on stdin inside the script it runs. No bind mount (a
    Windows bind mount is BUILD-NOTES #102 waiting to happen) and no argument
    carrying a secret.

    Returns (verdict, version, detail) where verdict is one of:
        fetched       the index was downloaded and verified
        unauthorized  the server answered 401
        tls           TLS verification failed — the test could not reach it
        notfound      404: the path is wrong for this account's root
        unfetched     something else stopped it; detail says what
    """
    uri = f"https://{repo_host(conf)}{base_path}"
    script = f"""
set -u
export DEBIAN_FRONTEND=noninteractive

# ca-certificates FIRST, from Ubuntu's own archive, because this image has
# none and without it apt cannot complete a TLS handshake with anything. Only
# then is Ubuntu's source removed — leaving it in place would let `apt update`
# succeed on the strength of a mirror that has nothing to do with the test.
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends ca-certificates >/dev/null 2>&1
if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then echo "NO-CA-BUNDLE"; fi
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
rm -rf /var/lib/apt/lists/* 2>/dev/null || true

install -d /usr/share/keyrings /etc/apt/auth.conf.d /etc/apt/sources.list.d
echo '{keyring_b64}' | base64 -d > /usr/share/keyrings/os7-archive-keyring.gpg

# The credential, in the file apt reads it from — mode 0600 from the start.
umask 077
cat > /etc/apt/auth.conf.d/os7.conf <<'AUTHEOF'
machine {repo_host(conf)}
login {conf['OS7_SB_REPO_USER']}
password {password}
AUTHEOF
umask 022

cat > /etc/apt/sources.list.d/os7.sources <<'SRCEOF'
Types: deb
URIs: {uri}
Suites: {suite}
Components: main
Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg
Enabled: yes
SRCEOF

echo "=== APT-UPDATE-BEGIN"
apt-get update -o Acquire::Retries=1 2>&1
echo "=== APT-UPDATE-END rc=$?"
apt-cache show os7-base 2>/dev/null | sed -n 's/^Version: /VERSION /p' | head -1
apt-cache policy 2>/dev/null | sed -n 's/^ *release /ORIGIN /p' | head -4
"""
    try:
        r = subprocess.run(
            ["docker", "run", "--rm", "-i", CONTAINER, "bash", "-s"],
            input=script, capture_output=True, text=True, timeout=600,
        )
    except subprocess.TimeoutExpired:
        return "unfetched", None, "the container timed out"
    out = (r.stdout or "") + (r.stderr or "")

    if "NO-CA-BUNDLE" in out:
        return "tls", None, "ca-certificates could not be installed in the container"

    version = None
    m = re.search(r"^VERSION (\S+)", out, re.M)
    if m:
        version = m.group(1)

    # WHICH LINE apt printed for OUR source. Get:/Hit: mean it arrived;
    # Err:/Ign: mean it did not, whatever the exit code was.
    arrived = bool(re.search(r"^(Get|Hit):\d+\s+" + re.escape(uri), out, re.M))
    errored = bool(re.search(r"^(Err|Ign):\d+\s+" + re.escape(uri), out, re.M))

    detail = ""
    for line in out.splitlines():
        s = line.strip()
        if s.startswith(("E:", "W:", "Err:")) or "401" in s or "Unauthorized" in s \
                or "certificate verify failed" in s:
            detail = s[:170]
            break

    if "401" in out or "Unauthorized" in out:
        return "unauthorized", version, detail
    if "certificate verify failed" in out or "SSL connection failed" in out:
        return "tls", version, detail
    if "404" in out and errored:
        return "notfound", version, detail
    if arrived and not errored:
        return "fetched", version, detail
    return "unfetched", version, detail or "apt printed neither Get: nor Err: for the source"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true",
                    help="reachability and the anonymous refusal only; no container")
    ap.add_argument("--suite", default=SUITE_DEFAULT)
    args = ap.parse_args()

    conf_path = find_conf()
    conf = read_conf(conf_path)
    host = repo_host(conf)

    print("\n### the Storage Box as a transport for OS/7's repository (RP2)\n")
    note(f"config {conf_path} (contents not printed)")
    note(f"publish host {conf['OS7_SB_HOST']}")
    note(f"read host    {host}   (a sub-account has its OWN vhost)")
    note(f"read user    {conf['OS7_SB_REPO_USER']}  (read-only sub-account)")
    print()

    print("  1. the endpoint requires authentication")
    code = curl_code(host, "/")
    if code == "401":
        ok("anonymous GET / is refused", "HTTP 401")
    elif code == "timeout":
        bad("anonymous GET / timed out",
            "WebDAV or External Reachability may be off in the Hetzner console")
    else:
        bad("anonymous GET / was not 401", f"HTTP {code} — a repository that "
            "answers anonymously makes every later success meaningless")

    print("  2. the read-only credential is accepted")
    code = curl_code(host, "/", conf["OS7_SB_REPO_USER"], conf["OS7_SB_REPO_PASSWORD"])
    if code in ("200", "207", "301", "302"):
        ok("authenticated GET / answers", f"HTTP {code}")
    elif code == "401":
        bad("authenticated GET / is still 401",
            "the sub-account may not exist yet, the password may differ, or "
            "WebDAV may not be enabled for it")
    else:
        note(f"authenticated GET / -> HTTP {code}")

    print("  3. the signed index is reachable, at one of the two possible roots")
    # A sub-account's directory IS its root, so the repository is either under
    # /repo (an account rooted at os7/) or at / (one rooted at os7/repo). Both
    # are tried rather than assumed; a 404 on one is information, not a failure.
    found = None
    for base in ("", "/repo"):
        rel = f"{base}/dists/{args.suite}/InRelease"
        code = curl_code(host, rel, conf["OS7_SB_REPO_USER"], conf["OS7_SB_REPO_PASSWORD"])
        if code == "200":
            ok(f"GET {rel}", "HTTP 200")
            found = base
            break
        note(f"GET {rel} -> HTTP {code}")
    if found is None:
        bad("the signed index is not readable at either root",
            "401 means the credential; 404 at both means the tree is not "
            "where this account can see it")

    if args.probe:
        _summary()
        return

    if not KEYRING_IN_TREE.is_file():
        die(f"{KEYRING_IN_TREE} is not here. Build the repository first:\n"
            "    make repo-amd64 && make repo-arm64")
    keyring_b64 = base64.b64encode(KEYRING_IN_TREE.read_bytes()).decode()

    # WHICH URI. A sub-account is restricted to a directory and that directory
    # is its ROOT, so the path depends on which account reads: the publishing
    # account is rooted at os7/ and sees repo/, while an account restricted to
    # os7/repo sees the repository AT its root and must not carry /repo in the
    # URI at all. Measured, not chosen — sub1's own `ls` showed its root is
    # os7/, and the read account's root is whatever the console was told.
    print("  4. apt, in a clean container, with the right credential")
    working_uri = None
    for base in ("", "/repo"):
        shown = base or "/"
        verdict, version, detail = apt_probe(
            conf, args.suite, keyring_b64, conf["OS7_SB_REPO_PASSWORD"], base)
        if verdict == "fetched" and version:
            ok(f"URI https://{host}{shown} — index fetched, "
               f"verified, os7-base {version}")
            working_uri = base
            break
        if verdict == "fetched":
            bad(f"URI {shown}: index fetched but os7-base is not in it",
                "the suite was read and holds no OS/7 packages")
            working_uri = base
            break
        if verdict == "unauthorized":
            bad(f"URI {shown}: 401 from the server", detail)
        elif verdict == "tls":
            bad(f"URI {shown}: TLS failed, so nothing was measured", detail)
        elif verdict == "notfound":
            note(f"URI {shown}: 404 — not this account's root, trying the next")
        else:
            bad(f"URI {shown}: not fetched", detail)

    print("  5. THE CONTROL — a wrong credential must be REFUSED, not merely fail")
    if working_uri is None:
        bad("the control cannot run", "no URI fetched above, so a failure here "
            "would prove nothing about authentication")
    else:
        verdict, _, detail = apt_probe(
            conf, args.suite, keyring_b64,
            conf["OS7_SB_REPO_PASSWORD"] + "-deliberately-wrong", working_uri)
        if verdict == "unauthorized":
            ok("wrong credential: the server answered 401", detail or "")
        elif verdict == "fetched":
            bad("wrong credential: the index was fetched ANYWAY",
                "the repository answers without the right credential, so check 4 "
                "proves nothing about authentication")
        else:
            bad(f"wrong credential: {verdict}, which is not a refusal", detail)

    if working_uri is not None:
        print()
        note("the apt source for a machine is:")
        note(f"    URIs: https://{host}{working_uri}")
        note(f"    Suites: {args.suite}")

    _summary()


def _summary():
    print(f"\n  {ok_n} ok, {fail_n} failed\n")
    sys.exit(1 if fail_n else 0)


if __name__ == "__main__":
    main()
