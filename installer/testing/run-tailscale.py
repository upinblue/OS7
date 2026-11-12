#!/usr/bin/env python3
"""
run-tailscale.py — the Tailscale role on a machine, end to end, against a
tailnet that exists only on this host.

docs/VENDOR-APPS-PLAN.md §7 step 8. check-tailscale-logic.py holds the role's
DECISIONS against recorded output with every side effect stubbed; this runs the
same cmdlets on an installed OS/7 machine with nothing stubbed, and asks three
witnesses that do not go through the role whether what it said is true:

  * THE CLIENT ITSELF — `tailscale status --json` and `tailscale debug prefs`,
    read raw here. The role reads the same JSON through powershell/Tailscale/;
    a harness that asked Get-OS7Tailscale whether Get-OS7Tailscale was right
    would be the diagnostic depending on what it diagnoses.
  * THE KERNEL'S MOUNT TABLE — `findmnt -T /var/lib/tailscale` says which
    filesystem holds the node's private key, which is the whole of VA9.
  * THE CONTROL SERVER — Headscale's own node list says whether a machine
    that claims to be "the same node" registered a second time.

THE BENCH. An os7lab.py bench (`ts` by default) at snapshot `p1-280`: what
Phase 1 left — 1.0.0.280, Tailscale installed from the registered source, its
state a directory of the boot environment, never logged in, a secret store.
The release under test is served from the bench's own repository
(`os7lab.py release ts`), and the phases walk it:

    lab        a new CA, a new Headscale, a peer — per run, on this host
    documented 280 logged in the vendor's documented way (identity in the BE)
    update     Update-OS7 280 -> TO with the source registered, reboot
    adopt      Install-OS7Tailscale refused, then -Adopt: the SAME node answers
               from rpool/DATA/lib/tailscale
    rollback   log in again (a new node key), Restore-OS7 to 280, reboot: which
               identity answers in the older environment
    timer      an older Tailscale, then os7-vendor-update.service brings it back
    ssh        Tailscale SSH and the client's updater switched on BY HAND, and
               the role's report and its way off
    uninstall  -KeepIdentity and a reinstall that is the same node; -RemoveState
    keylogin   a fresh install logged in from the secret store, a missing and a
               wrong secret refused, the key nowhere in the journal
    urllogin   a login URL approved in Headscale while Connect-OS7Tailscale waits
    va16       the container host refuses the tailnet's range

    ./run-tailscale.py all --to 1.0.0.282
    ./run-tailscale.py adopt rollback          # from the snapshots `all` took

`all` takes two snapshots on the way (tsrun-updated, tsrun-adopted), so a later
phase can be run again without paying for the update. A snapshot is only
meaningful with the Headscale it was taken against — the node's identity lives
in both — so each is recorded against the lab run that made it, and a phase
refuses to start from one that belongs to another run.

KEYS NEVER APPEAR. Headscale creates a key; it is read into this process's
memory and handed on over STANDARD INPUT only: to the peer's `tailscale up
--auth-key=file:/dev/stdin`, to the bench's `New-OS7Secret`, to the documented
login's `tailscale up`. Never printed, never an argument, never a file — the
rule the product follows, applied to the lab's own keys. `sudo -S` swallows
the rest of stdin (BUILD-NOTES #201), so the password line is read by bash and
fed to `sudo -v` through a here-string, and `sudo -n` then inherits a stdin
whose next line is the key.

NOT COVERED. arm64 (unrun — the lab's address is Docker Desktop's, and the
harness refuses a host that is not containerised); Tailscale's own control
plane (the owner's rule: never a real tailnet); the desktop.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import os7lab                                                         # noqa: E402

REPO = os7lab.REPO
LAB_SRC = os.path.join(HERE, "tailscale-lab")

# Pinned by digest: the measurements in docs/SESSION-TAILSCALE.md were taken
# against exactly this Headscale.
HS_IMAGE = ("headscale/headscale:0.29.6@sha256:"
            "cabe84f0699913dbca9320f0883dca7565dd08df3c5be29edfabbebeff763966")
PEER_TS_VERSION = "1.104.5"
PEER_IMAGE = "os7-tslab-peer:" + PEER_TS_VERSION
HS = "os7-tslab-headscale"
PEER = "os7-tslab-peer"
# The earlier, hand-built lab's peer. Removed with a note, because it would
# otherwise keep knocking at a control server that no longer knows it.
OLD_PEER = "os7-tslab-client"
LOGIN = "https://headscale.os7.test:8443"
# host.docker.internal on Docker Desktop: what the bench guest (slirp, inside a
# container) and the peer container both reach the host as.
LAB_ADDRESS = "192.168.65.254"
LAB_USER = "lab"
TAG = "tag:os7-bench"
SECRET = "tailscale-authkey"
BAD_SECRET = "tailscale-badkey"
HOSTNAME = "os7-tsrun"
STATE_DIR = "/var/lib/tailscale"
DATASET = "rpool/DATA/lib/tailscale"
START = "p1-280"
UPDATED = "tsrun-updated"
ADOPTED = "tsrun-adopted"

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
RESULTS = []
CURRENT = [""]


def phase(name, title):
    CURRENT[0] = name
    print("\n### %s — %s" % (name, title), flush=True)


def check(label, ok, detail=""):
    RESULTS.append((CURRENT[0], label, bool(ok)))
    line = "      %s  %s" % ("ok  " if ok else "FAIL", label)
    if detail and not ok:
        line += "\n            " + str(detail).replace("\n", "\n            ")
    print(line, flush=True)
    return bool(ok)


def say(label, value):
    """A measurement printed as it was read. Not a check: a number."""
    text = value if isinstance(value, str) else json.dumps(value, default=str)
    print("      =     %s: %s" % (label, text.replace("\n", "\n            ")), flush=True)


def note(text):
    print("      note  " + text.replace("\n", "\n            "), flush=True)


# ---------------------------------------------------------------------------
# The lab: Headscale, a peer, and a CA — new on every run
# ---------------------------------------------------------------------------
def docker(*args, input=None, check=True, timeout=900):
    p = subprocess.run(["docker", *args], input=input, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    if check and p.returncode != 0:
        raise SystemExit("docker %s failed (exit %d):\n%s" % (
            " ".join(args[:3]), p.returncode, ((p.stderr or "") + (p.stdout or "")).strip()[-1500:]))
    return p


def hs(*args, check=True):
    p = docker("exec", HS, "headscale", *args, "-o", "json", check=False)
    if p.returncode != 0:
        if check:
            raise SystemExit("headscale %s failed: %s" % (" ".join(args), (p.stderr or p.stdout).strip()))
        return None
    return json.loads(p.stdout) if p.stdout.strip() else None


def hs_user_id():
    for u in hs("users", "list") or []:
        if u.get("name") == LAB_USER:
            return u["id"]
    raise SystemExit("Headscale has no user %r -- run the lab phase" % LAB_USER)


def new_key(tags=None, reusable=True, expiration="24h"):
    """A pre-auth key, returned to the CALLER'S MEMORY. Never printed."""
    args = ["preauthkeys", "create", "--user", str(hs_user_id()), "--expiration", expiration]
    if reusable:
        args.append("--reusable")
    if tags:
        args += ["--tags", tags]
    return hs(*args)["key"]


def hs_nodes(name=None):
    nodes = hs("nodes", "list") or []
    if name:
        nodes = [n for n in nodes if n.get("given_name") == name or n.get("name") == name]
    return nodes


def node_expired(n):
    exp = (n.get("expiry") or {}).get("seconds")
    return bool(exp) and 0 < exp <= time.time()


class Lab:
    """Where one run's lab lives: .vm/<bench>/tailnet/, gitignored, and wiped
    at the start of every `lab` phase. The containers mount from it, so they
    are removed first — a directory a running container mounts is not one to
    delete underneath it."""

    def __init__(self, bench):
        self.dir = os.path.join(bench.dir, "tailnet")
        self.ca = os.path.join(self.dir, "ca")
        self.etc = os.path.join(self.dir, "etc")
        self.data = os.path.join(self.dir, "data")
        self.runfile = os.path.join(self.dir, "run.json")
        self.statefile = os.path.join(self.dir, "state.json")

    def run(self):
        try:
            with open(self.runfile, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def state(self):
        try:
            with open(self.statefile, encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def remember(self, **kw):
        st = self.state()
        st.update(kw)
        with open(self.statefile, "w", encoding="utf-8") as f:
            json.dump(st, f, indent=1)

    def ca_pem(self):
        with open(os.path.join(self.ca, "ca.crt"), encoding="ascii") as f:
            return f.read()

    # A MACHINE SNAPSHOT IS HALF OF A PAIR. The node's identity is in the
    # machine AND in Headscale's database, and the database moves on: the first
    # time a later phase was run again from tsrun-updated, the node in it came
    # up NeedsLogin, because the rollback phase of the run before had logged
    # that identity OUT of Headscale in the meantime. So every snapshot of the
    # machine is taken with one of the database, and restored with it.
    def _paused(self, fn):
        docker("stop", HS)
        try:
            fn()
        finally:
            docker("start", HS)
            deadline = time.time() + 60
            while time.time() < deadline:
                if docker("exec", HS, "headscale", "users", "list", check=False).returncode == 0:
                    break
                time.sleep(1)

    def save_db(self, tag):
        dest = os.path.join(self.dir, "snapshots", tag)

        def copy():
            if os.path.isdir(dest):
                shutil.rmtree(dest)
            shutil.copytree(self.data, dest)
        self._paused(copy)

    def load_db(self, tag):
        src = os.path.join(self.dir, "snapshots", tag)
        if not os.path.isdir(src):
            raise SystemExit("no Headscale database saved with %s -- run `all`" % tag)

        # The CONTENTS are replaced, not the directory: it is the container's
        # bind mount, stopped or not.
        def copy():
            for name in os.listdir(self.data):
                p = os.path.join(self.data, name)
                shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
            for name in os.listdir(src):
                p = os.path.join(src, name)
                if os.path.isdir(p):
                    shutil.copytree(p, os.path.join(self.data, name))
                else:
                    shutil.copy2(p, os.path.join(self.data, name))
        self._paused(copy)


def lab_phase(lab):
    phase("lab", "a CA, a Headscale and a peer, made for this run")
    for c in (PEER, HS, OLD_PEER):
        p = docker("rm", "-f", c, check=False)
        if c == OLD_PEER and p.returncode == 0 and c in (p.stdout or ""):
            note("removed %s, the earlier hand-built lab's peer" % OLD_PEER)
    if os.path.isdir(lab.dir):
        shutil.rmtree(lab.dir)
    for d in (lab.ca, lab.etc, lab.data):
        os.makedirs(d)

    if docker("image", "inspect", PEER_IMAGE, check=False).returncode != 0:
        print("      building %s ..." % PEER_IMAGE, flush=True)
        docker("build", "-t", PEER_IMAGE, "--build-arg", "TS_VERSION=" + PEER_TS_VERSION,
               "-f", os.path.join(LAB_SRC, "peer.Dockerfile"), LAB_SRC, timeout=1800)

    # The CA, made by openssl inside the peer image: no openssl on the host,
    # and the same command on every host. Seven days, EC P-256, one run.
    script = (
        "set -e; cd /ca; "
        "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 7 "
        "-subj '/CN=os7-tslab CA (one run)' -keyout ca.key -out ca.crt 2>/dev/null; "
        "openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes "
        "-subj '/CN=headscale.os7.test' -keyout hs.key -out hs.csr 2>/dev/null; "
        "printf 'subjectAltName=DNS:headscale.os7.test,IP:%s\\nextendedKeyUsage=serverAuth\\n"
        "basicConstraints=CA:FALSE\\n' > ext.cnf; "
        "openssl x509 -req -in hs.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 7 "
        "-extfile ext.cnf -out hs.crt 2>/dev/null; "
        "openssl verify -CAfile ca.crt hs.crt" % LAB_ADDRESS)
    p = docker("run", "--rm", "-v", lab.ca + ":/ca", "--entrypoint", "sh", PEER_IMAGE, "-c", script)
    check("a CA for this run, and Headscale's certificate signed by it", "hs.crt: OK" in p.stdout, p.stdout)
    for f in ("hs.crt", "hs.key"):
        shutil.copy(os.path.join(lab.ca, f), os.path.join(lab.etc, f))
    shutil.copy(os.path.join(LAB_SRC, "headscale.yaml"), os.path.join(lab.etc, "config.yaml"))
    shutil.copy(os.path.join(LAB_SRC, "policy.hujson"), os.path.join(lab.etc, "policy.hujson"))

    docker("run", "-d", "--name", HS, "-v", lab.etc + ":/etc/headscale:ro",
           "-v", lab.data + ":/var/lib/headscale", "-p", "8443:8443", "-p", "3478:3478/udp",
           HS_IMAGE, "serve")
    deadline = time.time() + 90
    while time.time() < deadline:
        if docker("exec", HS, "headscale", "users", "list", check=False).returncode == 0:
            break
        time.sleep(2)
    else:
        raise SystemExit("Headscale did not answer:\n" + docker("logs", "--tail", "30", HS, check=False).stderr)
    hs("users", "create", LAB_USER)
    check("Headscale answers, with user %s@" % LAB_USER, hs_user_id())

    docker("run", "-d", "--name", PEER, "--hostname", "lab-peer",
           "--cap-add", "NET_ADMIN", "--cap-add", "NET_RAW", "--device", "/dev/net/tun",
           "--add-host", "headscale.os7.test:" + LAB_ADDRESS,
           "-v", os.path.join(lab.ca, "ca.crt") + ":/usr/local/share/ca-certificates/os7-tslab.crt:ro",
           PEER_IMAGE)
    deadline = time.time() + 60
    while time.time() < deadline:
        if "BackendState" in docker("exec", PEER, "tailscale", "status", "--json", check=False).stdout:
            break
        time.sleep(1)
    key = new_key(reusable=False, expiration="1h")
    p = docker("exec", "-i", PEER, "tailscale", "up", "--login-server", LOGIN,
               "--auth-key=file:/dev/stdin", "--hostname", "lab-peer", "--timeout=60s",
               input=key + "\n", check=False)
    del key
    st = json.loads(docker("exec", PEER, "tailscale", "status", "--json").stdout)
    peer_ip = (st.get("TailscaleIPs") or [""])[0]
    check("the peer is on the lab's tailnet (TLS to Headscale through the run's CA)",
          st.get("BackendState") == "Running" and peer_ip, (p.stderr or p.stdout)[-400:])

    fp = hashlib.sha256(lab.ca_pem().encode()).hexdigest()
    run = {"id": time.strftime("%Y%m%d-%H%M%S") + "-" + fp[:8], "ca_sha256": fp, "peer_ip": peer_ip}
    with open(lab.runfile, "w", encoding="utf-8") as f:
        json.dump(run, f, indent=1)
    lab.save_db("lab")
    say("lab run", run["id"])
    return True


# ---------------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------------
class Machine:
    def __init__(self, name, lab, overlay=(), to=None):
        self.b = os7lab.Bench(name)
        self.lab = lab
        self.overlay = list(overlay)
        self.to = to
        if not self.b.arch.containerised:
            raise SystemExit(
                "run-tailscale.py has run only where QEMU runs inside Docker Desktop (the x64 "
                "Windows host). The lab's relay is announced at %s, which is what both the guest "
                "and the peer container reach the host as THERE; on a host-process QEMU the guest "
                "reaches the host at 10.0.2.2 and the peer at another address, and one relay "
                "address cannot serve both. Unrun, so refused." % LAB_ADDRESS)

    def ns(self, **kw):
        return argparse.Namespace(name=self.b.name, **kw)

    # -- lifecycle ---------------------------------------------------------
    def down(self):
        if self.b.running():
            os7lab.cmd_down(self.ns(force=False, timeout=180))

    def up(self):
        os7lab.cmd_up(self.ns(iso=None, install=False, size=0, cmdline=None, no_tpm=False,
                              no_gui=True, keep_log=False, serve=self.b.repo,
                              serve_port=os7lab.SERVE_PORT))
        self.wait_ssh()
        self.settled()
        self.apply_overlay()
        self.tailnet_settled()

    def apply_overlay(self):
        """--overlay: repository files laid over the installed module, on the
        release under test only. FOR ITERATING ON A DEFECT, NOT FOR EVIDENCE —
        the machine is then not what any release installed (BUILD-NOTES #93),
        so it is said on every boot it happens, and the run's verdict is only
        worth reporting from a run without it."""
        if not self.overlay or self.version() != self.to:
            return
        for rel in self.overlay:
            parts = rel.replace("\\", "/").split("/")
            if len(parts) < 3 or parts[0] != "powershell":
                raise SystemExit("--overlay takes powershell/<Module>/<file>, not %r" % rel)
            dest = "/usr/local/share/powershell/Modules/" + "/".join(parts[1:])
            tmp = "/tmp/os7-overlay-" + parts[-1]
            subprocess.run(["scp", "-P", str(self.b.port("ssh")), "-i", self.b.key,
                            "-o", "StrictHostKeyChecking=no",
                            "-o", "UserKnownHostsFile=" + os.path.join(self.b.sshdir, "known_hosts"),
                            "-o", "LogLevel=ERROR", os.path.join(REPO, *parts),
                            os7lab.USER + "@127.0.0.1:" + tmp], check=True)
            rc, out, err = self.sh("test -f %s && install -m 0644 %s %s && rm -f %s" % (dest, tmp, dest, tmp))
            if rc != 0:
                raise SystemExit("--overlay: %s did not land at %s: %s" % (rel, dest, err or out))
        note("OVERLAY: %s laid over the installed module -- this machine is not what %s installed"
             % (", ".join(self.overlay), self.to))

    def restore(self, tag):
        self.down()
        os7lab.cmd_restore(self.ns(tag=tag))
        # START predates every lab: Headscale goes back to how the lab phase
        # left it, so a rerun of `documented` meets no node of an earlier one.
        self.lab.load_db("lab" if tag == START else tag)
        self.up()

    def snapshot(self, tag):
        self.down()
        os7lab.cmd_snapshot(self.ns(tag=tag, replace=True))
        self.lab.save_db(tag)
        tags = self.lab.state().get("snapshots", {})
        tags[tag] = self.lab.run().get("id")
        self.lab.remember(snapshots=tags)
        self.up()

    def wait_ssh(self, timeout=420):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os7lab.ssh_alive(self.b):
                return
            time.sleep(5)
        # Not up over ssh: the serial line says why, and types a passphrase if
        # that is what the machine is waiting for (a FINDING, which login prints).
        print("      ssh does not answer -- asking the serial line", flush=True)
        os7lab.cmd_login(self.ns(user=os7lab.USER, password=os7lab.PASSWORD, timeout=900,
                                 no_ssh=False))
        if not os7lab.ssh_alive(self.b):
            raise SystemExit("bench %s does not answer over ssh" % self.b.name)

    def reboot(self):
        self.sh("systemctl reboot", timeout=60)
        deadline = time.time() + 180
        while time.time() < deadline and os7lab.ssh_alive(self.b):
            time.sleep(3)
        time.sleep(10)
        self.wait_ssh(timeout=600)
        self.settled()
        self.apply_overlay()
        self.tailnet_settled()

    def tailnet_settled(self, timeout=90):
        """A booted machine's tailscaled is NoState or Starting until it has
        spoken to its control server, with a zero node key - so an identity
        read in that window compares a real key with nothing (measured: the
        timer phase's "before" was read there on this harness's first full
        run). Waits it out where Tailscale is installed at all."""
        if self.sh("command -v tailscale", sudo=False)[0] != 0:
            return
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.ts_status().get("BackendState") not in (None, "", "NoState", "Starting"):
                return
            time.sleep(2)
        note("tailscaled did not settle within %ds" % timeout)

    def settled(self):
        """The boot FINISHED, not merely sshd: a new environment's first boot
        runs its firstboot migrations (the TPM re-seal among them), and a
        question asked during them is asked of a machine still changing."""
        rc, out, _ = self.sh("timeout 600 systemctl is-system-running --wait", sudo=False, timeout=660)
        state = out.strip()
        if state not in ("running", "degraded"):
            note("the boot did not settle: %r" % state)
        elif state == "degraded":
            note("the system is degraded: " + self.out("systemctl --failed --no-legend --plain", sudo=False))

    # -- channels ----------------------------------------------------------
    def sh(self, script, sudo=True, timeout=600):
        try:
            return os7lab.run_remote(self.b, "export LC_ALL=C.UTF-8\n" + script,
                                     elevated=sudo, shell=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return 124, "", "timed out after %ds" % timeout

    def out(self, script, sudo=True, timeout=600):
        return self.sh(script, sudo, timeout)[1].strip()

    def ps(self, script, sudo=True, timeout=900):
        """PowerShell on the machine. Returns (value, error): value is the
        script's output as a LIST (JSON), error the exception's message if it
        threw. Anything printed on the way (steps, warnings, Write-Host) is
        before the marker and is returned as the third element."""
        wrapped = ("$ErrorActionPreference = 'Stop'\n$ProgressPreference = 'SilentlyContinue'\n"
                   "try {\n$__r = & {\n" + script + "\n}\n'@@JSON@@'\n"
                   "ConvertTo-Json -InputObject @($__r) -Depth 8 -Compress\n}\n"
                   "catch {\n'@@ERROR@@'\n$_.Exception.Message\n}\n")
        try:
            rc, out, err = os7lab.run_remote(self.b, wrapped, elevated=sudo, timeout=timeout)
        except subprocess.TimeoutExpired:
            return None, "timed out after %ds" % timeout, ""
        if "@@ERROR@@" in out:
            before, msg = out.split("@@ERROR@@", 1)
            return None, msg.strip(), before
        if "@@JSON@@" in out:
            before, js = out.split("@@JSON@@", 1)
            try:
                return json.loads(js.strip() or "[]"), None, before
            except ValueError as e:
                return None, "unparseable output: %s\n%s" % (e, js.strip()[:800]), before
        return None, "no answer (exit %d): %s" % (rc, (err or out).strip()[-800:]), out

    def ps1(self, script, sudo=True, timeout=900):
        v, e, before = self.ps(script, sudo, timeout)
        return (v[0] if v else None), e, before

    def with_secret(self, command, secret, timeout=300):
        """`command` run as root with `secret` as the first line of its stdin.
        The command must contain no single quote; a script goes through
        base64 (bash_b64)."""
        remote = ("bash -c 'IFS= read -r pw; sudo -S -p \"\" -v <<< \"$pw\" && unset pw && "
                  "sudo -n " + command + "'")
        p = subprocess.run(os7lab.ssh_base(self.b) + [remote],
                           input=os7lab.PASSWORD + "\n" + secret + "\n", capture_output=True,
                           text=True, encoding="utf-8", errors="replace", timeout=timeout)
        return p.returncode, p.stdout or "", p.stderr or ""

    # -- the three witnesses ----------------------------------------------
    def ts_status(self):
        rc, out, _ = self.sh("tailscale status --json")
        try:
            return json.loads(out)
        except ValueError:
            return {"_error": out.strip()[-300:], "_rc": rc}

    def ts_prefs(self):
        rc, out, _ = self.sh("tailscale debug prefs")
        try:
            return json.loads(out)
        except ValueError:
            return {"_error": out.strip()[-300:], "_rc": rc}

    def holder(self):
        """Which filesystem holds the node's state: the kernel's answer."""
        return self.out("findmnt -no SOURCE,FSTYPE -T %s" % STATE_DIR)

    def version(self):
        """IMAGE_VERSION from os-release: the build, written by hook 0075 from
        the pin, and asked here without going through the OS7 module."""
        return self.out(". /etc/os-release; echo $IMAGE_VERSION", sudo=False)


def bash_b64(script):
    return 'bash -c "$(echo %s | base64 -d)"' % base64.b64encode(script.encode()).decode()


def ps_b64(script):
    return "pwsh -NoProfile -NonInteractive -EncodedCommand " + \
        base64.b64encode(script.encode("utf-16-le")).decode()


def identity(st):
    s = st.get("Self") or {}
    return {"id": s.get("ID"), "key": s.get("PublicKey"), "state": st.get("BackendState"),
            "ips": st.get("TailscaleIPs") or []}


def seal(m, name, value):
    """New-OS7Secret, the value over stdin and nowhere else."""
    script = ("$k = [Console]::In.ReadLine()\n"
              "if (-not $k) { throw 'no value arrived on stdin' }\n"
              "$s = ConvertTo-SecureString $k -AsPlainText -Force; Remove-Variable k\n"
              "$null = New-OS7Secret -Name '%s' -Value $s -Force -Confirm:$false\n"
              "'sealed'\n" % name)
    rc, out, err = m.with_secret(ps_b64(script), value)
    return rc == 0 and "sealed" in out, (err or out).strip()[-600:]


def require_snapshot(m, tag):
    """A snapshot made against THIS lab run, or a refusal that says why."""
    taken = m.lab.state().get("snapshots", {}).get(tag)
    run = m.lab.run().get("id")
    if tag not in os7lab.snapshot_tags(m.b):
        raise SystemExit("bench %s has no snapshot %s -- run `all`" % (m.b.name, tag))
    if not taken or taken != run:
        raise SystemExit(
            "snapshot %s was taken against lab run %s and the lab is now run %s: the node's "
            "identity lives in both, so the snapshot means nothing to this Headscale. Run `all`."
            % (tag, taken or "(unknown)", run or "(none)"))
    m.restore(tag)


def peer_ping(m):
    ip = m.lab.run().get("peer_ip")
    rc, out, _ = m.sh("tailscale ping -c 5 --timeout 5s %s" % ip, timeout=90)
    return rc == 0 and "pong" in out, out.strip()[-300:]


def attention(g):
    return [a for a in (g or {}).get("Attention") or [] if a]


# ---------------------------------------------------------------------------
# The phases
# ---------------------------------------------------------------------------
def phase_documented(m, a):
    phase("documented", "1.0.0.280, logged in the vendor's documented way")
    m.restore(START)
    v = m.version()
    check("the machine runs 1.0.0.280", v == "1.0.0.280", v)

    # The lab's CA and name. Bench preparation, not product: SESSION-TAILSCALE §2.
    # AND tailscaled RESTARTED: Go reads the system's roots ONCE, at the first
    # TLS handshake, so a daemon that was running when the CA changed keeps the
    # old set for its whole life. Measured on the first run of this harness:
    # curl trusted the new CA in the same second tailscaled was logging
    # `x509: certificate signed by unknown authority` every few seconds, and
    # `tailscale up` timed out waiting for Running.
    pem_b64 = base64.b64encode(m.lab.ca_pem().encode()).decode()
    m.sh("echo %s | base64 -d > /usr/local/share/ca-certificates/os7-tslab.crt\n"
         "update-ca-certificates >/dev/null 2>&1\n"
         "grep -q 'headscale.os7.test' /etc/hosts || "
         "echo '%s headscale.os7.test   # OS/7 bench tailnet (lab only)' >> /etc/hosts\n"
         "systemctl restart tailscaled"
         % (pem_b64, LAB_ADDRESS))
    code = m.out("curl -sS -o /dev/null -w '%%{http_code}' %s/health" % LOGIN)
    check("the machine reaches this run's Headscale and trusts its certificate", code == "200", code)

    url = os7lab.Bench(m.b.name).arch.guest_host_url(os7lab.SERVE_PORT)
    _, e, _ = m.ps("Set-OS7UpdateChannel -Uri %s -Channel development -Confirm:$false" % url)
    check("the update channel points at the bench's repository", not e, e)

    key = new_key(tags=TAG, reusable=True, expiration="24h")
    ok, detail = seal(m, SECRET, key)
    del key
    check("an auth key for this tailnet is sealed in the secret store (over stdin)", ok, detail)

    st = identity(m.ts_status())
    say("before the login", st)
    key = new_key(tags=TAG, reusable=False, expiration="1h")
    rc, out, err = m.with_secret(
        "env LC_ALL=C.UTF-8 tailscale up --login-server=%s --auth-key=file:/dev/stdin "
        "--hostname=%s --timeout=60s" % (LOGIN, HOSTNAME), key, timeout=120)
    del key
    st = identity(m.ts_status())
    check("`tailscale up` with a key logged the machine in", st["state"] == "Running" and st["id"],
          (err or out).strip()[-400:] + " / " + json.dumps(st))
    holder = m.holder()
    check("its state is a directory of the boot environment (the documented layout)",
          holder.startswith("rpool/ROOT/"), holder)
    nodes = hs_nodes(HOSTNAME)
    check("Headscale lists exactly one node %s" % HOSTNAME, len(nodes) == 1,
          [n.get("given_name") for n in hs_nodes()])
    ok, detail = peer_ping(m)
    check("the peer answers over the tailnet", ok, detail)
    m.lab.remember(node_a=st)
    say("identity A", st)
    return True


def phase_update(m, a):
    phase("update", "Update-OS7 1.0.0.280 -> %s with the vendor source registered" % a.to)
    if a.isolated:
        raise SystemExit("update continues from documented (there is no snapshot between them): "
                         "run `documented update`")
    rel, e, _ = m.ps("@(Get-OS7Release | Where-Object { [string]$_.Version -eq '%s' } | "
                     "Select-Object @{n='Version';e={[string]$_.Version}}, Applicable)" % a.to)
    check("the bench's repository offers %s, applicable" % a.to,
          rel and rel[0].get("Applicable") is True, e or rel)
    r, e, before = m.ps1(
        "$w = @()\n"
        "$res = Update-OS7 -Version %s -AllowDevelopment -Confirm:$false -WarningVariable w "
        "-WarningAction SilentlyContinue\n"
        "[pscustomobject]@{ To = [string]$res.To; Activated = $res.Activated; "
        "BootEnvironment = [string]$res.BootEnvironment;\n"
        "  VendorPackages = @($res.VendorPackages | ForEach-Object { \"$($_.Package) $($_.From) -> $($_.To) "
        "[$($_.Class)] $($_.Source)\" });\n"
        "  Warnings = @($w | ForEach-Object { $_.Message }) }" % a.to, timeout=3600)
    if not check("Update-OS7 ran to %s and activated it" % a.to,
                 r and r.get("To") == a.to and r.get("Activated"), e or r):
        print(before[-3000:])
        return False
    say("boot environment", r.get("BootEnvironment"))
    say("VendorPackages", r.get("VendorPackages") or "(none moved)")
    for w in r.get("Warnings") or []:
        note("warning: " + w)
    m.reboot()
    v = m.version()
    check("the machine runs %s after the reboot" % a.to, v == a.to, v)
    st = identity(m.ts_status())
    node_a = m.lab.state().get("node_a") or {}
    check("the same node answers (identity copied into the new environment)",
          st["state"] == "Running" and st["key"] == node_a.get("key"), json.dumps(st))
    holder = m.holder()
    check("its state is still a directory of the (new) boot environment",
          holder.startswith("rpool/ROOT/") and r.get("BootEnvironment", "") in holder, holder)
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale reports layout InBootEnvironment", g and g.get("Layout") == "InBootEnvironment",
          e or g)
    check("... and says so as attention, naming -Adopt",
          any("inside the boot" in x and "-Adopt" in x for x in attention(g)), attention(g))
    check("... with the registered source verified", g and g.get("Source") == "tailscale"
          and g.get("SourceVerified") is True, e or (g and {k: g.get(k) for k in ("Source", "SourceVerified")}))
    m.snapshot(UPDATED)
    return True


def phase_adopt(m, a):
    phase("adopt", "Install-OS7Tailscale refused, then -Adopt: the same node, on a dataset")
    if a.isolated:
        require_snapshot(m, UPDATED)
    node_a = m.lab.state().get("node_a") or {}
    rc, _, _ = m.sh("zfs list -H %s" % DATASET)
    check("there is no %s yet" % DATASET, rc != 0)

    _, e, _ = m.ps1("Install-OS7Tailscale -Confirm:$false")
    check("Install-OS7Tailscale refuses, naming -Adopt", e and "refused and changed nothing" in e and "-Adopt" in e, e)
    rc, _, _ = m.sh("zfs list -H %s" % DATASET)
    st = identity(m.ts_status())
    check("... and changed nothing: no dataset, the same node running",
          rc != 0 and st["state"] == "Running" and st["key"] == node_a.get("key"), json.dumps(st))

    r, e, before = m.ps1("Install-OS7Tailscale -Adopt -Confirm:$false", timeout=1200)
    if not check("Install-OS7Tailscale -Adopt: Outcome Adopted, every check its own true",
                 r and r.get("Outcome") == "Adopted" and all(c.get("Ok") for c in r.get("Checks") or [{}]),
                 e or json.dumps(r and r.get("Checks"), indent=1)):
        print(before[-3000:])
        return False
    say("state files copied", r.get("StateCopied"))
    holder = m.holder()
    check("the kernel says %s holds %s" % (DATASET, STATE_DIR), holder.split() == [DATASET, "zfs"], holder)
    mode = m.out("stat -c '%%a %%U' %s/tailscaled.state" % STATE_DIR)
    check("tailscaled.state kept its mode on the dataset", mode == "600 root", mode)
    left = m.out("ls -d %s.os7-* 2>/dev/null" % STATE_DIR)
    check("nothing is left beside it (no .os7-adopt, no .os7-replaced-*)", left == "", left)
    under = m.out("set -e; d=$(mktemp -d); mount --bind / $d; ls -A $d%s; umount $d; rmdir $d" % STATE_DIR)
    check("the boot environment's copy is gone (an empty mount point under the dataset)",
          under == "", under)
    st = identity(m.ts_status())
    check("the SAME node answers: node key and id unchanged",
          st["state"] == "Running" and st["key"] == node_a.get("key") and st["id"] == node_a.get("id"),
          "before %s / after %s" % (json.dumps(node_a), json.dumps(st)))
    nodes = hs_nodes(HOSTNAME)
    check("Headscale still has exactly one node %s (no second registration)" % HOSTNAME, len(nodes) == 1,
          [n.get("given_name") for n in hs_nodes()])
    ok, detail = peer_ping(m)
    check("the peer answers", ok, detail)
    policy, e, _ = m.ps("@((Get-OS7BackupPolicy).Sources | ForEach-Object { [string]$_.Dataset })")
    say("backup policy datasets", policy or e)
    check("the dataset is not in the backup policy (a node key restored elsewhere is two machines)",
          policy is not None and DATASET not in policy, e or policy)
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale: layout OS7, nothing needs attention",
          g and g.get("Layout") == "OS7" and not attention(g), e or attention(g))
    check("... SSH off and the client's updater off (False, not merely unset)",
          g and g.get("TailscaleSsh") is False and g.get("TailscaleAutoUpdate") is False,
          e or (g and {k: g.get(k) for k in ("TailscaleSsh", "TailscaleAutoUpdate")}))
    prefs = m.ts_prefs()
    check("... and the client agrees (debug prefs)",
          prefs.get("RunSSH") is False and (prefs.get("AutoUpdate") or {}).get("Apply") is False,
          {"RunSSH": prefs.get("RunSSH"), "AutoUpdate": prefs.get("AutoUpdate")})
    d, e, _ = m.ps1("(Get-OS7Version -CheckDrift).Drift | Select-Object State, "
                    "@{n='Unexplained';e={@($_.Unexplained | ForEach-Object { \"$_\" })}}")
    say("drift after the adoption", d or e)
    r, e, _ = m.ps1("Install-OS7Tailscale -Confirm:$false")
    check("run again it changes nothing: AlreadyInstalled", r and r.get("Outcome") == "AlreadyInstalled", e or r)
    m.snapshot(ADOPTED)
    return True


def phase_rollback(m, a):
    phase("rollback", "a new node key in %s, then Restore-OS7 to 1.0.0.280" % a.to)
    if a.isolated:
        require_snapshot(m, ADOPTED)
    _, e, _ = m.ps1("Disconnect-OS7Tailscale -Logout -Confirm:$false")
    check("Disconnect-OS7Tailscale -Logout", not e, e)
    g, e, before = m.ps1("Connect-OS7Tailscale -AuthKeySecret %s -LoginServer %s -Hostname %s -Confirm:$false"
                         % (SECRET, LOGIN, HOSTNAME), timeout=900)
    check("Connect-OS7Tailscale from the secret store: Running", g and g.get("BackendState") == "Running",
          e or before[-1500:])
    node_a = m.lab.state().get("node_a") or {}
    node_b = identity(m.ts_status())
    check("a NEW node key (what a re-enrolment or a key expiry does)",
          node_b["state"] == "Running" and node_b["key"] and node_b["key"] != node_a.get("key"),
          json.dumps(node_b))
    say("identity B", node_b)
    # O-M4: an older tailscaled on a state file a newer one wrote. The release
    # under test moved Tailscale forward in its clone; the environment rolled
    # back to did not.
    ts_new = m.out("dpkg-query -W -f '${Version}' tailscale")
    say("tailscale that wrote identity B", ts_new)
    bes, e, _ = m.ps("@(Get-OS7BootEnvironment | ForEach-Object { \"$($_.Name) running=$($_.Running)\" })")
    say("boot environments", bes or e)
    r, e, before = m.ps1("Restore-OS7 -Confirm:$false | Select-Object * -ExcludeProperty PS*", timeout=900)
    if not check("Restore-OS7 activated an older environment", not e, e or before[-1500:]):
        return False
    say("Restore-OS7", r)
    m.reboot()
    v = m.version()
    check("the machine runs 1.0.0.280 again", v == "1.0.0.280", v)
    holder = m.holder()
    check("the kernel says %s holds %s in 1.0.0.280 too" % (DATASET, STATE_DIR),
          holder.split() == [DATASET, "zfs"], holder)
    st = identity(m.ts_status())
    ts_old = m.out("dpkg-query -W -f '${Version}' tailscale")
    say("tailscale reading it in 1.0.0.280", ts_old)
    check("identity B answers — the current one, not the environment's A",
          st["state"] == "Running" and st["key"] == node_b["key"], json.dumps(st))
    ok, detail = peer_ping(m)
    check("the peer answers", ok, detail)
    say("overlay on the dataset", m.out("zfs get -H -o value overlay %s" % DATASET))
    under = m.out("set -e; d=$(mktemp -d); mount --bind / $d; ls -la $d%s 2>&1; "
                  "stat -c '%%s bytes' $d%s/tailscaled.state 2>&1; umount $d; rmdir $d"
                  % (STATE_DIR, STATE_DIR))
    say("what 1.0.0.280's own %s holds under the mount" % STATE_DIR, under)
    note("1.0.0.280 was never adopted: its directory still holds identity A's private key, "
         "which is what VAL says an older environment keeps")
    return True


def madison(m):
    out = m.out("apt-cache madison tailscale")
    vs = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split("|")]
        if len(parts) >= 3 and parts[0] == "tailscale" and parts[1] not in vs:
            vs.append(parts[1])
    return vs


def phase_timer(m, a):
    phase("timer", "an older Tailscale, then os7-vendor-update.service")
    if a.isolated:
        require_snapshot(m, ADOPTED)
    node = identity(m.ts_status())
    have = m.out("dpkg-query -W -f '${Version}' tailscale")
    vs = madison(m)
    older = [v for v in vs if v != have]
    newer_first = vs[:1]
    say("installed / offered", "%s / %s" % (have, ", ".join(vs[:4])))
    if not check("the vendor's repository offers an older version to go back to", older, vs):
        return False
    # The highest version below the installed one (madison lists newest
    # first): dpkg decides what "below" means, not a sort here.
    target = None
    for v in older:
        if m.sh("dpkg --compare-versions %s lt %s" % (v, have))[0] == 0:
            target = v
            break
    if not check("one of them is older than %s" % have, target, older):
        return False
    rc, out, err = m.sh("DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-downgrades "
                        "--no-install-recommends tailscale=%s" % target, timeout=900)
    now = m.out("dpkg-query -W -f '${Version}' tailscale")
    check("downgraded to %s by hand" % target, now == target, (err or out)[-600:])
    # ACTIVE AND SCHEDULED, not `is-enabled`: os7-release enables the timer by
    # a symlink in /usr/lib/systemd/system/timers.target.wants/, and
    # `is-enabled` looks only at /etc - it answers `disabled` for a timer that
    # is running with its next elapse scheduled (measured on this harness's
    # first full run, os7-update-check.timer the same).
    active = m.out("systemctl is-active os7-vendor-update.timer", sudo=False)
    nxt = m.out("systemctl show -p NextElapseUSecRealtime --value os7-vendor-update.timer", sudo=False)
    check("os7-vendor-update.timer is active, its next run scheduled", active == "active" and nxt,
          "%s / next %r" % (active, nxt))
    say("timer next elapse", nxt)
    t0 = time.time()
    rc, out, err = m.sh("systemctl start os7-vendor-update.service", timeout=1900)
    check("os7-vendor-update.service ran and exited 0", rc == 0,
          (err or out)[-600:] + m.out("journalctl -u os7-vendor-update.service -n 30 --no-pager"))
    say("took", "%.0fs" % (time.time() - t0))
    after = m.out("dpkg-query -W -f '${Version}' tailscale")
    check("it brought Tailscale forward to %s" % (newer_first[0] if newer_first else "?"),
          newer_first and after == newer_first[0], after)
    say("vendor-update.log", m.out("tail -6 /var/log/os7/vendor-update.log"))
    time.sleep(5)
    st = identity(m.ts_status())
    check("the same node is running after the package moved under it",
          st["state"] == "Running" and st["key"] == node["key"], json.dumps(st))
    holder = m.holder()
    check("its state is still on the dataset", holder.split() == [DATASET, "zfs"], holder)
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale: nothing needs attention", g and not attention(g), e or attention(g))
    return True


def phase_ssh(m, a):
    phase("ssh", "Tailscale SSH and the client's updater switched on by hand")
    if a.isolated:
        require_snapshot(m, ADOPTED)
    rc, out, err = m.sh("tailscale set --ssh=true")
    check("`tailscale set --ssh=true` (what an administrator can always type)", rc == 0, err or out)
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale reports TailscaleSsh true", g and g.get("TailscaleSsh") is True, e or g)
    check("... as attention, saying what it bypasses and how to switch it off",
          any("Tailscale SSH is ON" in x and "PAM" in x and "-TailscaleSsh $false" in x for x in attention(g)),
          attention(g))
    _, e, _ = m.ps1("Set-OS7Tailscale -TailscaleSsh $true -Confirm:$false")
    check("Set-OS7Tailscale -TailscaleSsh $true is refused", e and "does not switch Tailscale SSH on" in e, e)
    check("... and the client still says on (the refusal changed nothing)", m.ts_prefs().get("RunSSH") is True)
    g, e, _ = m.ps1("Set-OS7Tailscale -TailscaleSsh $false -Confirm:$false")
    check("Set-OS7Tailscale -TailscaleSsh $false: off", g and g.get("TailscaleSsh") is False, e or g)
    check("... the client agrees", m.ts_prefs().get("RunSSH") is False)

    rc, out, err = m.sh("tailscale set --auto-update=true")
    check("`tailscale set --auto-update=true`", rc == 0, err or out)
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale reports the client's updater on, as attention",
          g and g.get("TailscaleAutoUpdate") is True and any("updater is ON" in x for x in attention(g)),
          e or attention(g))
    _, e, _ = m.ps1("Set-OS7Tailscale -TailscaleAutoUpdate $true -Confirm:$false")
    check("Set-OS7Tailscale -TailscaleAutoUpdate $true is refused", e and "does not switch" in e, e)
    g, e, _ = m.ps1("Set-OS7Tailscale -TailscaleAutoUpdate $false -Confirm:$false")
    check("Set-OS7Tailscale -TailscaleAutoUpdate $false: off, nothing needs attention",
          g and g.get("TailscaleAutoUpdate") is False and not attention(g), e or (g and attention(g)))
    check("... the client agrees", (m.ts_prefs().get("AutoUpdate") or {}).get("Apply") is False)
    return True


def phase_uninstall(m, a):
    phase("uninstall", "-KeepIdentity and a reinstall, then -RemoveState")
    if a.isolated:
        require_snapshot(m, ADOPTED)
    node = identity(m.ts_status())
    r, e, before = m.ps1("Uninstall-OS7Tailscale -KeepIdentity -Confirm:$false", timeout=900)
    check("Uninstall-OS7Tailscale -KeepIdentity: Removed", r and r.get("Outcome") == "Removed", e or before[-1500:])
    pkg = m.out("dpkg-query -W -f '${db:Status-Abbrev}' tailscale 2>/dev/null")
    check("the package is gone (removed, not purged)", not pkg.startswith("ii"), pkg)
    src = m.out("ls /etc/apt/sources.list.d/ | grep -i tailscale")
    check("its source is unregistered", src == "", src)
    unit = m.out("systemctl is-enabled tailscaled 2>&1", sudo=False)
    check("tailscaled is not left masked", "masked" not in unit, unit)
    size = m.out("stat -c %%s %s/tailscaled.state" % STATE_DIR)
    check("the dataset is kept, with the node's state in it",
          m.holder().split() == [DATASET, "zfs"] and size.isdigit() and int(size) > 2, size)
    nodes = hs_nodes(HOSTNAME)
    check("Headscale still lists the node, not logged out", len(nodes) == 1 and not node_expired(nodes[0]), nodes)
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale: not installed, the kept dataset a note and not attention",
          g and g.get("Installed") is False and not attention(g)
          and any(DATASET in x for x in g.get("Notes") or []), e or g)

    r, e, before = m.ps1("Install-OS7Tailscale -Confirm:$false", timeout=1200)
    check("Install-OS7Tailscale on the kept dataset: Installed, every check true",
          r and r.get("Outcome") == "Installed" and all(c.get("Ok") for c in r.get("Checks") or [{}]),
          e or before[-1500:])
    time.sleep(3)
    st = identity(m.ts_status())
    check("the SAME node is back with no login", st["state"] == "Running" and st["key"] == node["key"],
          "before %s / after %s" % (json.dumps(node), json.dumps(st)))
    check("Headscale still has exactly one node %s" % HOSTNAME, len(hs_nodes(HOSTNAME)) == 1, hs_nodes())

    since = m.out("date +%s", sudo=False)
    r, e, before = m.ps1("Uninstall-OS7Tailscale -RemoveState -Confirm:$false", timeout=900)
    check("Uninstall-OS7Tailscale -RemoveState: Removed", r and r.get("Outcome") == "Removed", e or before[-1500:])
    rc, _, _ = m.sh("zfs list -H %s" % DATASET)
    check("the dataset is destroyed", rc != 0)
    left = m.out("ls -la %s 2>&1" % STATE_DIR)
    check("and its mount point with it (zfs destroy leaves it behind)", "No such file" in left, left)
    # THE CLIENT'S LOGOUT IS OS/7'S; WHAT THE SERVER DOES WITH IT IS NOT. This
    # node is TAGGED, and Headscale does not expire a tagged node on logout
    # (measured: `Expired: no` after the client's own `client.Logout()`), so
    # the server's list is recorded here and the urllogin phase measures the
    # control - a user's node, which it does expire.
    n = m.out("journalctl -u tailscaled --since @%s --no-pager | grep -c 'client.Logout()'" % since)
    check("the client logged out before the package went (tailscaled: client.Logout())",
          n.isdigit() and int(n) >= 1, n)
    nodes = hs_nodes(HOSTNAME)
    say("Headscale on the tagged node afterwards",
        [{"expired": node_expired(x), "online": bool(x.get("online")), "tags": x.get("tags")} for x in nodes])
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale: not installed, layout None, nothing to say",
          g and g.get("Installed") is False and g.get("Layout") == "None" and not attention(g), e or g)
    return True


def phase_keylogin(m, a):
    phase("keylogin", "a fresh install, logged in with a key from the secret store")
    if a.isolated:
        raise SystemExit("keylogin follows uninstall (it needs the machine without Tailscale): "
                         "run `uninstall keylogin`")
    r, e, before = m.ps1("Install-OS7Tailscale -Confirm:$false", timeout=1200)
    check("Install-OS7Tailscale on a machine without it: Installed, every check true",
          r and r.get("Outcome") == "Installed" and all(c.get("Ok") for c in r.get("Checks") or [{}]),
          e or before[-1500:])
    g, e, _ = m.ps1("Get-OS7Tailscale")
    check("Get-OS7Tailscale: NeedsLogin, saying how to log in",
          g and g.get("BackendState") == "NeedsLogin"
          and any("Connect-OS7Tailscale" in x for x in attention(g)), e or g)

    _, e, _ = m.ps1("Connect-OS7Tailscale -AuthKeySecret no-such-secret -LoginServer %s -Confirm:$false" % LOGIN)
    check("a secret that does not exist is refused by name", e and "no secret called 'no-such-secret'" in e, e)

    ok, detail = seal(m, BAD_SECRET, "hskey-auth-" + secrets.token_hex(16))
    check("a key Headscale never issued is sealed as %s" % BAD_SECRET, ok, detail)
    _, e, _ = m.ps1("Connect-OS7Tailscale -AuthKeySecret %s -LoginServer %s -Hostname %s -TimeoutSec 30 "
                    "-Confirm:$false" % (BAD_SECRET, LOGIN, HOSTNAME), timeout=600)
    say("the refusal", e or "(none)")
    check("... the login fails with the login job's own sentence, not systemctl's",
          e and "the login job" in e and "did not log in" in e, e)
    check("... and the machine is still not on the tailnet", identity(m.ts_status())["state"] != "Running")

    key = new_key(tags=TAG, reusable=False, expiration="1h")
    ok, detail = seal(m, SECRET, key)
    check("a fresh key is sealed as %s" % SECRET, ok, detail)
    g, e, before = m.ps1("Connect-OS7Tailscale -AuthKeySecret %s -LoginServer %s -Hostname %s -Confirm:$false"
                         % (SECRET, LOGIN, HOSTNAME), timeout=900)
    check("Connect-OS7Tailscale: Running, an address from the tailnet, tagged",
          g and g.get("BackendState") == "Running" and any(str(x).startswith("100.") for x in g.get("Addresses") or [])
          and TAG in (g.get("Tags") or []), e or before[-1500:])
    check("... the client's updater False after the login (M-TS17 on a machine), SSH off",
          g and g.get("TailscaleAutoUpdate") is False and g.get("TailscaleSsh") is False, g)
    prefs = m.ts_prefs()
    check("... and the client agrees", (prefs.get("AutoUpdate") or {}).get("Apply") is False
          and prefs.get("RunSSH") is False, {"RunSSH": prefs.get("RunSSH"), "AutoUpdate": prefs.get("AutoUpdate")})
    check("... nothing needs attention", g and not attention(g), g and attention(g))
    ok, detail = peer_ping(m)
    check("the peer answers", ok, detail)
    rc, out, err = m.with_secret(bash_b64(
        "IFS= read -r k\n"
        "j=$(journalctl -o cat --no-pager | grep -c -F -f <(printf '%s\\n' \"$k\"))\n"
        "f=$(grep -rIl -F -f <(printf '%s\\n' \"$k\") /var/lib/os7-automation /var/log /run 2>/dev/null | wc -l)\n"
        "unset k\necho \"journal=$j files=$f\"\n"), key)
    del key
    check("the key is nowhere in plain text: not in the journal, not in a file under "
          "/var/lib/os7-automation, /var/log or /run", out.strip() == "journal=0 files=0", (out + err).strip())
    m.lab.remember(node_key=identity(m.ts_status()))
    return True


def phase_urllogin(m, a):
    phase("urllogin", "a login URL, approved in Headscale while Connect-OS7Tailscale waits")
    if a.isolated:
        raise SystemExit("urllogin follows keylogin: run `uninstall keylogin urllogin`")
    g, e, _ = m.ps1("Disconnect-OS7Tailscale -Logout -Confirm:$false")
    check("Disconnect-OS7Tailscale -Logout: NeedsLogin, the updater stated off again",
          g and g.get("BackendState") == "NeedsLogin" and g.get("TailscaleAutoUpdate") is False, e or g)

    box = {}

    def connect():
        box["r"] = m.ps1("Connect-OS7Tailscale -LoginServer %s -Hostname %s-url -TimeoutSec 240 -Confirm:$false"
                         % (LOGIN, HOSTNAME), timeout=600)
    t = threading.Thread(target=connect, daemon=True)
    t.start()
    url = ""
    deadline = time.time() + 120
    while time.time() < deadline and not url:
        time.sleep(3)
        url = m.ts_status().get("AuthURL") or ""
    check("the daemon holds a login URL on this tailnet's server", url.startswith(LOGIN + "/register/"),
          url or "(none)")
    # A PERSON APPROVES AFTER THEY HAVE SEEN THE URL, and Connect-OS7Tailscale
    # shows it once `tailscale up --json --timeout=10s` has given up waiting.
    # Approved at once - this harness reads the URL off the daemon - the login
    # finished inside those ten seconds, the cmdlet never printed the URL and
    # never entered its wait: the path a person takes was not the one measured
    # (this harness's first run of the phase). So it waits as a person must.
    time.sleep(15)
    if url:
        auth_id = url.rsplit("/", 1)[-1]
        p = docker("exec", HS, "headscale", "auth", "register", "--auth-id", auth_id, "--user", LAB_USER,
                   check=False)
        check("Headscale approves it (headscale auth register)", p.returncode == 0, p.stderr or p.stdout)
    t.join(timeout=420)
    g, e, before = box.get("r", (None, "Connect-OS7Tailscale did not return", ""))
    check("Connect-OS7Tailscale returned Running once the person approved",
          g and g.get("BackendState") == "Running", e or before[-1500:])
    check("... the URL went to the operator on the way", url and url in (before or ""), (before or "")[-600:])
    check("... the updater False after this login too, SSH off, nothing needs attention",
          g and g.get("TailscaleAutoUpdate") is False and g.get("TailscaleSsh") is False and not attention(g),
          g and {k: g.get(k) for k in ("TailscaleAutoUpdate", "TailscaleSsh", "Attention")})
    nodes = hs_nodes(HOSTNAME + "-url")
    check("Headscale lists the node as %s@'s, untagged" % LAB_USER,
          len(nodes) == 1 and (nodes[0].get("user") or {}).get("name") == LAB_USER and not nodes[0].get("tags"),
          nodes)
    # The control for uninstall's logout: the same client verb against a node
    # Headscale DOES expire, so "the tagged node stayed unexpired" is shown to
    # be the server's policy and not a logout that never arrived.
    g, e, _ = m.ps1("Disconnect-OS7Tailscale -Logout -Confirm:$false")
    check("Disconnect-OS7Tailscale -Logout on the user's node", g and g.get("BackendState") == "NeedsLogin", e or g)
    time.sleep(3)
    nodes = hs_nodes(HOSTNAME + "-url")
    check("... Headscale expires a user's node on logout (the control: it does not expire a tagged one)",
          len(nodes) == 1 and node_expired(nodes[0]), nodes)
    return True


def phase_va16(m, a):
    phase("va16", "the container host on a tailnet node")
    if a.isolated:
        require_snapshot(m, ADOPTED)
    link = m.out("ip -o link show tailscale0", sudo=False)
    check("tailscale0 is up on this machine", "tailscale0" in link, link)
    _, e, _ = m.ps1("Install-OS7ContainerHost -Bridge 100.70.0.1/24 -AddressPool 10.216.0.0/16 -WhatIf")
    check("Install-OS7ContainerHost refuses a bridge inside 100.64.0.0/10, naming the tailnet",
          e and "refused before writing anything" in e and "tailnet" in e, e)
    _, e, _ = m.ps1("Install-OS7ContainerHost -Bridge 10.215.0.1/24 -AddressPool 10.216.0.0/16 -WhatIf")
    check("the control: ranges outside it pass the check (-WhatIf, nothing installed)", not e, e)
    rc, _, _ = m.sh("zfs list -H rpool/DATA/lib/docker")
    pkg = m.out("dpkg-query -W -f '${db:Status-Abbrev}' docker.io 2>/dev/null")
    check("nothing was written: no engine dataset, no engine package", rc != 0 and not pkg.startswith("ii"), pkg)
    return True


PHASES = [
    ("lab", None), ("documented", phase_documented), ("update", phase_update), ("adopt", phase_adopt),
    ("rollback", phase_rollback), ("timer", phase_timer), ("ssh", phase_ssh), ("uninstall", phase_uninstall),
    ("keylogin", phase_keylogin), ("urllogin", phase_urllogin), ("va16", phase_va16),
]


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("phases", nargs="+", help="all, or any of: " + ", ".join(n for n, _ in PHASES))
    ap.add_argument("--bench", default="ts")
    ap.add_argument("--to", help="the release to update to (default: the newest in the bench's repository)")
    ap.add_argument("--overlay", action="append", default=[], metavar="powershell/<Module>/<file>",
                    help="lay this repository file over the installed module after every boot of the "
                         "release under test. For iterating on a defect; a run with it is not evidence")
    a = ap.parse_args()

    names = [n for n, _ in PHASES]
    wanted = names if a.phases == ["all"] else a.phases
    for w in wanted:
        if w not in names:
            raise SystemExit("no phase %r -- %s" % (w, ", ".join(names)))
    b = os7lab.Bench(a.bench)
    lab = Lab(b)
    if not a.to:
        rels = sorted(os.listdir(os.path.join(b.repo, "releases")),
                      key=lambda v: [int(x) for x in v.split(".")])
        a.to = rels[-1]
    m = Machine(a.bench, lab, overlay=a.overlay, to=a.to)
    if a.overlay:
        print("    OVERLAY %s -- iterating, not evidence (BUILD-NOTES #93)" % ", ".join(a.overlay))
    print("run-tailscale.py — bench %s, release %s, phases %s" % (a.bench, a.to, " ".join(wanted)))
    head = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True,
                          text=True).stdout.strip()
    print("    tree at %s; the release under test is whatever the bench's repository serves" % head)

    t0 = time.time()
    for i, (name, fn) in enumerate(PHASES):
        if name not in wanted:
            continue
        if name == "lab":
            lab_phase(lab)
            continue
        if not lab.run():
            raise SystemExit("no lab for this bench -- run the lab phase first (or `all`)")
        # A phase run on its own starts from the snapshot it needs; one that
        # follows its predecessor in this invocation continues on the machine.
        prev = names[i - 1]
        # rollback leaves the machine on 1.0.0.280, so what follows it starts
        # again from tsrun-adopted, exactly as if it had been run on its own.
        a.isolated = prev not in wanted or prev == "rollback"
        try:
            fn(m, a)
        except SystemExit:
            raise
        except Exception as ex:                                      # noqa: BLE001
            check("phase %s ran to its end" % name, False, "%s: %s" % (type(ex).__name__, ex))
        # THE PHASES BUILD ON EACH OTHER: a later one run on the machine a
        # failed one left is a measurement of that failure, not of itself.
        if any(ph == name and not ok for ph, _, ok in RESULTS):
            later = [n for n in names[i + 1:] if n in wanted]
            if later:
                print("\n      stopping: %s failed, and %s build on it" % (name, ", ".join(later)))
            break

    bad = [r for r in RESULTS if not r[2]]
    print("\n%d checks, %d FAIL, %.0f min" % (len(RESULTS), len(bad), (time.time() - t0) / 60))
    for ph, label, _ in bad:
        print("    FAIL  [%s] %s" % (ph, label))
    print("    bench %s left up: ./os7lab.py exec %s 'Get-OS7Tailscale' --sudo" % (a.bench, a.bench))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
