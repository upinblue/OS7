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


def apt_probe(conf, suite, keyring_b64, password, expect_ok, label):
    """apt update in a CLEAN container against the real endpoint.

    Everything the container needs — the keyring bytes, the source, the
    credential — arrives on stdin inside the script it runs. No bind mount (a
    Windows bind mount is BUILD-NOTES #102 waiting to happen) and no argument
    carrying a secret.
    """
    script = f"""
set -u
export DEBIAN_FRONTEND=noninteractive
install -d /usr/share/keyrings /etc/apt/auth.conf.d /etc/apt/sources.list.d
echo '{keyring_b64}' | base64 -d > /usr/share/keyrings/os7-archive-keyring.gpg

# The credential, in the file apt reads it from — mode 0600 from the start.
umask 077
cat > /etc/apt/auth.conf.d/os7.conf <<'AUTHEOF'
machine {conf['OS7_SB_HOST']}
login {conf['OS7_SB_REPO_USER']}
password {password}
AUTHEOF
umask 022

cat > /etc/apt/sources.list.d/os7.sources <<'SRCEOF'
Types: deb
URIs: https://{conf['OS7_SB_HOST']}/repo
Suites: {suite}
Components: main
Signed-By: /usr/share/keyrings/os7-archive-keyring.gpg
Enabled: yes
SRCEOF

# ONLY the OS/7 source: Ubuntu's own would make `apt update` succeed on the
# strength of a mirror that has nothing to do with what is under test.
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

if apt-get update -o Acquire::Retries=1 2>&1; then echo "APT-UPDATE-OK"; else echo "APT-UPDATE-FAILED"; fi
apt-cache policy os7-base 2>/dev/null | sed -n '1,4p'
apt-cache show os7-base 2>/dev/null | sed -n 's/^Version: /VERSION /p' | head -1
"""
    r = subprocess.run(
        ["docker", "run", "--rm", "-i", CONTAINER, "bash", "-s"],
        input=script, capture_output=True, text=True, timeout=420,
    )
    out = (r.stdout or "") + (r.stderr or "")
    updated = "APT-UPDATE-OK" in out
    version = None
    m = re.search(r"^VERSION (\S+)", out, re.M)
    if m:
        version = m.group(1)

    if expect_ok:
        if updated:
            ok(f"{label}: apt update succeeded")
        else:
            bad(f"{label}: apt update FAILED", _first_apt_error(out))
        if version:
            ok(f"{label}: os7-base is visible", version)
        else:
            bad(f"{label}: os7-base not in the index",
                "the source was read and holds no OS/7 packages")
    else:
        if updated:
            bad(f"{label}: apt update SUCCEEDED and must not",
                "the repository answers without the right credential, so the "
                "successful run above proves nothing about authentication")
        else:
            ok(f"{label}: apt update refused, as it must")
    return updated


def _first_apt_error(out):
    for line in out.splitlines():
        if line.startswith(("E:", "W:")) or "401" in line or "Unauthorized" in line:
            return line.strip()[:160]
    return (out.strip().splitlines() or ["(no output)"])[-1][:160]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--probe", action="store_true",
                    help="reachability and the anonymous refusal only; no container")
    ap.add_argument("--suite", default=SUITE_DEFAULT)
    args = ap.parse_args()

    conf_path = find_conf()
    conf = read_conf(conf_path)
    host = conf["OS7_SB_HOST"]

    print("\n### the Storage Box as a transport for OS/7's repository (RP2)\n")
    note(f"config {conf_path} (contents not printed)")
    note(f"host   {host}")
    note(f"user   {conf['OS7_SB_REPO_USER']}  (read-only sub-account)")
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

    print("  3. the signed index is reachable by the path apt will use")
    rel = f"/repo/dists/{args.suite}/InRelease"
    code = curl_code(host, rel, conf["OS7_SB_REPO_USER"], conf["OS7_SB_REPO_PASSWORD"])
    if code == "200":
        ok(f"GET {rel}", "HTTP 200")
    elif code == "404":
        bad(f"GET {rel} is 404", "the repository has not been uploaded yet")
    else:
        bad(f"GET {rel}", f"HTTP {code}")

    if args.probe:
        _summary()
        return

    if not KEYRING_IN_TREE.is_file():
        die(f"{KEYRING_IN_TREE} is not here. Build the repository first:\n"
            "    make repo-amd64 && make repo-arm64")
    keyring_b64 = base64.b64encode(KEYRING_IN_TREE.read_bytes()).decode()

    print("  4. apt, in a clean container, with the right credential")
    apt_probe(conf, args.suite, keyring_b64,
              conf["OS7_SB_REPO_PASSWORD"], True, "correct credential")

    print("  5. THE CONTROL — apt with a wrong credential must fail")
    apt_probe(conf, args.suite, keyring_b64,
              conf["OS7_SB_REPO_PASSWORD"] + "-wrong", False, "wrong credential")

    _summary()


def _summary():
    print(f"\n  {ok_n} ok, {fail_n} failed\n")
    sys.exit(1 if fail_n else 0)


if __name__ == "__main__":
    main()
