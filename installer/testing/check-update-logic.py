#!/usr/bin/env python3
"""
The update train's DECISIONS, checked without a VM, an ISO or real ZFS.

    ./check-update-logic.py

WHAT THIS IS AND IS NOT. It runs the real `powershell/OS7` module against a
`zfs`, an `apt-get`, a `chroot` and their neighbours that are fakes, and checks
the commands the module issues, the ORDER it issues them in, and what it
refuses. So it is a test of **OS/7's layer** — and it is not a test of ZFS, of
apt, of dpkg, or of a machine. `installer/testing/run-s5.py` on a booted machine
is the test of the machine and nothing here replaces it.

THREE THINGS ARE REAL, and each is real because faking it would test nothing:

  * THE MOUNTS. The fake `zfs`/`mount` performs a real `mount -t tmpfs`, so
    /proc/self/mountinfo genuinely reflects what was assembled and
    Assert-OS7UpdateRootAssembled reads the kernel rather than a file this
    script wrote. That check exists to catch a boot environment that is only
    partly assembled; a fake mount table would let the bug it guards against
    walk straight through it. Same argument as check-home-logic.py's tmpfs.

  * THE SIGNATURES. gpg and gpgv are the real ones. A stub `gpgv` returning 0
    would prove that the stub returned 0. So the check generates a key, signs an
    index with it, and then signs another with a DIFFERENT key and requires the
    refusal.

  * THE ORDER. Every fake appends its argv to one log, so the sequence
    RELEASE-AND-UPDATE-PLAN §4.2 specifies — and the three apt operations C10
    puts in a fixed order — are checked as an order and not as a set. Reversing
    `install` and `autoremove` removes the product, and both orders "work".

THE FAKE ZFS MODELS ONE THING ON PURPOSE, the same discipline check-be-logic.py
argues for: that a clone comes out inert. Everything else about it is a
convenience. A mock that models everything models the bugs too.

RUN IT ANYWHERE. It builds its own container (installer/testing/Dockerfile.check-update)
and runs itself inside it, because it needs Linux, root and mount(2).
"""

import argparse
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IMAGE = "os7-check-update:latest"

# ---------------------------------------------------------------------------
# The fakes
# ---------------------------------------------------------------------------

# Every fake logs argv, one line of JSON, to $OS7_LOG. The ORDER of that file is
# what half the checks below read.
LOG_PREAMBLE = r'''
import json, os, sys
def logcall():
    with open(os.environ["OS7_LOG"], "a") as fh:
        fh.write(json.dumps(sys.argv) + "\n")
def state():
    try:
        with open(os.environ["OS7_STATE"]) as fh: return json.load(fh)
    except Exception: return {}
def save(s):
    with open(os.environ["OS7_STATE"], "w") as fh: json.dump(s, fh)
'''

# The dataset layout of a machine New-OS7Storage built, with one boot
# environment. `mountpoint` and `canmount` are the two properties the boot
# environment code reads, and the SOURCE of each matters — mountpoint inherits
# and canmount does not (BUILD-NOTES #63).
LAYOUT = {
    "rpool":                              ("off",    "/",             "LOCAL", "LOCAL"),
    "rpool/ROOT":                         ("off",    "none",          "LOCAL", "LOCAL"),
    "rpool/ROOT/os7_a":                   ("noauto", "/",             "LOCAL", "LOCAL"),
    "rpool/ROOT/os7_a/var":               ("off",    "/var",          "LOCAL", "INHERITED"),
    "rpool/ROOT/os7_a/var/lib":           ("off",    "/var/lib",      "LOCAL", "INHERITED"),
    "rpool/ROOT/os7_a/var/lib/dpkg":      ("on",     "/var/lib/dpkg", "DEFAULT", "INHERITED"),
    "rpool/ROOT/os7_a/var/lib/apt":       ("on",     "/var/lib/apt",  "DEFAULT", "INHERITED"),
    "rpool/ROOT/os7_a/var/cache":         ("on",     "/var/cache",    "DEFAULT", "INHERITED"),
    "rpool/DATA":                         ("off",    "none",          "LOCAL", "LOCAL"),
    "rpool/DATA/log":                     ("on",     "/var/log",      "DEFAULT", "LOCAL"),
    "rpool/DATA/srv":                     ("on",     "/srv",          "DEFAULT", "LOCAL"),
    "bpool":                              ("off",    "none",          "LOCAL", "LOCAL"),
    "bpool/BOOT":                         ("off",    "none",          "LOCAL", "LOCAL"),
    "bpool/BOOT/os7_a":                   ("on",     "/boot",         "DEFAULT", "LOCAL"),
}

FAKE_ZFS = LOG_PREAMBLE + r'''
logcall()
argv = sys.argv[1:]
sub = argv[0] if argv else ""
LAYOUT = json.load(open(os.environ["OS7_LAYOUT"]))
st = state()
LAYOUT.update(st.get("created", {}))
MOUNTED = st.get("mounted", {})

def prop(v, s): return {"value": v, "source": {"type": s, "data": "-"}}
def dataset(n):
    cm, mp, cms, mps = LAYOUT[n]
    return {"name": n, "type": "SNAPSHOT" if "@" in n else "FILESYSTEM",
            "pool": n.split("/")[0], "createtxg": 1,
            "properties": {"used": prop(1024, "NONE"), "available": prop(1024, "NONE"),
                           "referenced": prop(1024, "NONE"), "mountpoint": prop(mp, mps),
                           "creation": prop(1787676263 + len(n), "NONE"),
                           "compression": prop("lz4", "LOCAL"), "quota": prop(0, "DEFAULT"),
                           "origin": prop(st.get("origin", {}).get(n, "-"), "NONE"),
                           "mounted": prop("yes" if MOUNTED.get(n) else "no", "NONE"),
                           "canmount": prop(cm, cms)}}
def emit(names, only=None):
    out = {}
    for n in names:
        d = dataset(n)
        if only:
            d["properties"] = {k: v for k, v in d["properties"].items() if k in only}
        out[n] = d
    print(json.dumps({"output_version": {"command": "zfs " + sub, "vers_major": 0,
                                         "vers_minor": 1}, "datasets": out}))

def names_after_flags(rest, valued=("-o", "-d", "-t")):
    out, skip = [], False
    for a in rest:
        if skip: skip = False; continue
        if a in valued: skip = True; continue
        if a.startswith("-"): continue
        out.append(a)
    return out

if sub == "list":
    names = names_after_flags(argv[1:])
    types = "filesystem"
    for i, a in enumerate(argv):
        if a == "-t": types = argv[i + 1]
    depth = None
    for i, a in enumerate(argv):
        if a == "-d": depth = int(argv[i + 1])
    recurse = "-r" in argv or depth is not None
    out = []
    for n in names:
        if n not in LAYOUT and "@" not in n:
            sys.stderr.write("cannot open '%s': dataset does not exist\n" % n); sys.exit(1)
        if n in LAYOUT: out.append(n)
        if recurse:
            for k in LAYOUT:
                if not k.startswith(n + "/") and not k.startswith(n + "@"): continue
                if depth is not None and k[len(n) + 1:].count("/") + 1 > depth: continue
                out.append(k)
    want_snap = "snapshot" in types or "all" in types
    want_fs = "filesystem" in types or "all" in types
    out = [n for n in out if (("@" in n) and want_snap) or (("@" not in n) and want_fs)]
    only = None
    for i, a in enumerate(argv):
        if a == "-o": only = [x for x in argv[i + 1].split(",") if x not in ("name",)]
    emit(sorted(set(out)), only)
elif sub == "get":
    # valued=("-o",) ONLY, which is check-be-logic.py's proven parsing: `zfs get`
    # takes its property list as the first BARE argument, and a parser that also
    # skipped the value of -t or -d would eat it.
    rest = names_after_flags(argv[1:], valued=("-o",))
    props, names = (rest[0].split(",") if rest else ["all"]), rest[1:]
    for n in names:
        if n not in LAYOUT:
            sys.stderr.write("cannot open '%s': dataset does not exist\n" % n); sys.exit(1)
    emit(names, only=None if "all" in props else props)
elif sub == "snapshot":
    rec = "-r" in argv
    targets = names_after_flags(argv[1:])
    created = st.setdefault("created", {})
    for t in targets:
        base, snap = t.split("@", 1)
        roots = [base] + ([k for k in LAYOUT if k.startswith(base + "/")] if rec else [])
        for r in roots:
            created[r + "@" + snap] = LAYOUT[r]
    save(st)
elif sub == "clone":
    args = names_after_flags(argv[1:])
    src, dst = args[0], args[1]
    props = {}
    for i, a in enumerate(argv):
        if a == "-o":
            k, v = argv[i + 1].split("=", 1); props[k] = v
    origin_ds = src.split("@")[0]
    ocm, omp, ocms, omps = LAYOUT[origin_ds]
    # THE ONE THING THIS FAKE MODELS: a clone does NOT carry the origin's local
    # properties, and canmount does not inherit at all — so a clone created
    # without -o comes out canmount=on with an inherited mountpoint
    # (BUILD-NOTES #63, measured on a real machine).
    cm = props.get("canmount", "on")
    mp = props.get("mountpoint")
    if mp is None:
        # AN INHERITED MOUNTPOINT IS THE PARENT'S PLUS THE CHILD'S NAME, which
        # is the second thing this fake has to model exactly. Real ZFS computes
        # it that way, so rpool/ROOT/<be>/var/cache inheriting `/` from its
        # parent resolves to /var/cache — not to `/`.
        #
        # The first version of this fake returned the parent's value verbatim,
        # and the module then mounted three datasets on top of each other at
        # /run/os7-update/. It looked like a bug in Mount-OS7UpdateRoot and was
        # a bug in the mock: exactly the hazard check-be-logic.py's header
        # names, which is why a mock should model as little as possible and
        # model that little correctly.
        parent = dst.rsplit("/", 1)[0]
        leaf = dst.rsplit("/", 1)[1]
        pmp = LAYOUT.get(parent, ("off", "none", "LOCAL", "LOCAL"))[1]
        mp = "none" if pmp in ("none", "legacy") else (pmp.rstrip("/") + "/" + leaf)
        mps = "INHERITED"
    else:
        mps = "LOCAL"
    st.setdefault("created", {})[dst] = (cm, mp, "LOCAL" if "canmount" in props else "DEFAULT", mps)
    st.setdefault("origin", {})[dst] = src
    save(st)
elif sub in ("mount", "unmount", "umount"):
    pass
elif sub == "destroy":
    targets = names_after_flags(argv[1:])
    created = st.setdefault("created", {})
    for t in targets:
        for k in list(created):
            if k == t or k.startswith(t + "/") or k.startswith(t + "@"): del created[k]
    st["destroyed"] = st.get("destroyed", []) + targets
    save(st)
elif sub == "set":
    pairs = [a for a in argv[1:] if "=" in a]
    created = st.setdefault("created", {})
    for n in [a for a in argv[1:] if "=" not in a and not a.startswith("-")]:
        cur = list(created.get(n, LAYOUT.get(n, ("on", "none", "DEFAULT", "DEFAULT"))))
        for p in pairs:
            k, _, v = p.partition("=")
            if k == "canmount": cur[0] = v; cur[2] = "LOCAL"
            elif k == "mountpoint": cur[1] = v; cur[3] = "LOCAL"
        created[n] = cur
    save(st)
sys.exit(0)
'''

# `mount` and `umount`, REAL underneath. A `mount -t zfs -o zfsutil <ds> <path>`
# becomes a real tmpfs at <path>; a --bind is a real bind. So the kernel's
# mountinfo is the truth and Assert-OS7UpdateRootAssembled reads it.
FAKE_MOUNT = LOG_PREAMBLE + r'''
import subprocess
logcall()
a = sys.argv[1:]
if "-t" in a and a[a.index("-t") + 1] == "zfs":
    target = a[-1]
    os.makedirs(target, exist_ok=True)
    rc = subprocess.call(["/bin/mount", "-t", "tmpfs", "os7fake", target])
    # A FRESHLY MOUNTED BOOT ENVIRONMENT IS NOT EMPTY. The tmpfs standing in for
    # the clone's root dataset has to look like a root: /etc is INSIDE the boot
    # environment (RELEASE-AND-UPDATE-PLAN §4.4) and so is /usr, and a check
    # that assembled an empty one would be testing the module against a machine
    # that could never have booted. Two kernels, because an update is exactly
    # what leaves two there.
    if rc == 0 and target == os.environ.get("OS7_UPDATE_ROOT"):
        for d in ("etc/apt/sources.list.d", "boot", "usr/lib/os7", "var/lib"):
            os.makedirs(os.path.join(target, d), exist_ok=True)
        with open(os.path.join(target, "etc/os-release"), "w") as fh:
            fh.write('NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="26.04"\n'
                     'IMAGE_ID="os7"\nVARIANT_ID="server"\n')
        # An environment that USES the TPM2 handler, when the check asks for
        # one. Assert-OS7Initramfs is conditional on this file existing, so
        # without it only the skip path is ever exercised — and the skip path
        # is not the one that has to fail.
        if os.environ.get("OS7_FAKE_TPM") == "1":
            d = os.path.join(target, "etc/initramfs-tools/scripts/local-top")
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, "os7-tpm2"), "w").close()
    # THE KERNELS BELONG TO THE bpool HALF, not to the root's /boot. A boot
    # environment is two datasets in two pools (§4.3), and the bpool one IS
    # /boot — so seeding the root's /boot and then mounting bpool over it hides
    # them, which is exactly what a real machine would do too. Two kernels,
    # because an update is what leaves two there (BUILD-NOTES #89).
    if rc == 0 and a[-2].startswith("bpool/BOOT/"):
        for k in ("7.0.0-9-generic", "7.0.0-31-generic"):
            open(os.path.join(target, "vmlinuz-" + k), "w").close()
    sys.exit(rc)
sys.exit(subprocess.call(["/bin/mount"] + a))
'''

# chroot, without the chroot. The command is run in place with OS7_FAKE_ROOT
# pointing at what would have been the new root, so the apt and dpkg fakes can
# answer about that tree — and so the check can read what they wrote.
#
# THAT IS A REAL LIMITATION AND IT IS NAMED: this check cannot see whether a
# maintainer script would have acted on the running system instead of on the
# environment. Only run-s5.py can.
FAKE_CHROOT = LOG_PREAMBLE + r'''
import subprocess
logcall()
root, rest = sys.argv[1], sys.argv[2:]
env = dict(os.environ, OS7_FAKE_ROOT=root)
while rest and rest[0] == "env":
    rest = rest[1:]
    while rest and "=" in rest[0] and not rest[0].startswith("/"):
        k, v = rest[0].split("=", 1); env[k] = v; rest = rest[1:]
sys.exit(subprocess.call(rest, env=env))
'''

FAKE_APT_GET = LOG_PREAMBLE + r'''
logcall()
st = state()
# `-o` TAKES A VALUE, and the value does not start with a dash:
# `-o Dpkg::Options::=--force-confold`. Filtering only on the leading dash made
# that value the verb, so `install` never ran and the failure surfaced two steps
# later as "dpkg-query: no packages found matching os7-server".
a, skip = [], False
for x in sys.argv[1:]:
    if skip: skip = False; continue
    if x in ("-o", "-t", "--option"): skip = True; continue
    if x.startswith("-"): continue
    a.append(x)
verb = a[0] if a else ""
root = os.environ.get("OS7_FAKE_ROOT", "")
if verb == "install":
    pkg = a[1] if len(a) > 1 else ""
    if "=" in pkg:
        name, ver = pkg.split("=", 1)
        st.setdefault("dpkg", {})[name] = os.environ.get("OS7_FAKE_INSTALLS_AS", ver)
        save(st)
print("done")
sys.exit(0)
'''

FAKE_APT_CACHE = LOG_PREAMBLE + r'''
logcall()
a = sys.argv[1:]
if a and a[0] == "policy":
    pkg = a[1]
    print("%s:" % pkg)
    print("  Installed: %s" % state().get("dpkg", {}).get(pkg, "(none)"))
    print("  Candidate: %s" % os.environ.get("OS7_FAKE_CANDIDATE", "0.0.0.0"))
    print("  Version table:")
    print("     %s 500" % os.environ.get("OS7_FAKE_CANDIDATE", "0.0.0.0"))
sys.exit(0)
'''

FAKE_DPKG_QUERY = LOG_PREAMBLE + r'''
logcall()
a = sys.argv[1:]
fmt = ""
names = []
i = 0
while i < len(a):
    if a[i] == "-W": pass
    elif a[i].startswith("-f="): fmt = a[i][3:]
    elif not a[i].startswith("-"): names.append(a[i])
    i += 1
st = state()
installed = st.get("dpkg", {})
for n in names:
    if n not in installed:
        sys.stderr.write("dpkg-query: no packages found matching %s\n" % n)
        sys.exit(1)
    out = fmt.replace("${Version}", installed[n])
    out = out.replace("${db:Status-Status}", "installed")
    out = out.replace("${binary:Package}", n)
    out = out.replace("${Architecture}", "amd64")
    out = out.replace("\\t", "\t").replace("\\n", "\n")
    sys.stdout.write(out if out else installed[n])
sys.exit(0)
'''

FAKE_DPKG = LOG_PREAMBLE + r'''
logcall()
if "--print-architecture" in sys.argv: print("amd64")
sys.exit(0)
'''

FAKE_UPDATE_INITRAMFS = LOG_PREAMBLE + r'''
logcall()
root = os.environ.get("OS7_FAKE_ROOT", "")
boot = os.path.join(root, "boot") if root else "/boot"
for f in os.listdir(boot) if os.path.isdir(boot) else []:
    if f.startswith("vmlinuz-"):
        rel = f[len("vmlinuz-"):]
        with open(os.path.join(boot, "initrd.img-" + rel), "w") as fh:
            fh.write("initramfs for " + rel + "\n")
sys.exit(0)
'''

FAKE_LSINITRAMFS = LOG_PREAMBLE + r'''
logcall()
# Whatever the environment was configured to carry. The check sets this so it
# can drive both the present and the ABSENT case, which is the one that has to
# fail.
for line in os.environ.get("OS7_FAKE_INITRD_CONTENTS", "").split(","):
    if line: print(line)
sys.exit(0)
'''

FAKE_TRUE = LOG_PREAMBLE + r'''
logcall()
sys.exit(0)
'''

FAKES = {
    "zfs": FAKE_ZFS,
    "mount": FAKE_MOUNT,
    "chroot": FAKE_CHROOT,
    "apt-get": FAKE_APT_GET,
    "apt-cache": FAKE_APT_CACHE,
    "dpkg-query": FAKE_DPKG_QUERY,
    "dpkg": FAKE_DPKG,
    "update-initramfs": FAKE_UPDATE_INITRAMFS,
    "lsinitramfs": FAKE_LSINITRAMFS,
    "update-grub": FAKE_TRUE,
    "unmkinitramfs": FAKE_TRUE,
    "dpkg-reconfigure": FAKE_TRUE,
    "systemctl": FAKE_TRUE,
    "zpool": FAKE_TRUE,
}


# ---------------------------------------------------------------------------
# The world the module runs in
# ---------------------------------------------------------------------------

MACHINE_VERSION = "1.0.0.100"
NEXT_VERSION = "1.0.1.0"
SUITE = "os7-1.0"


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def build_world(work):
    """Everything the module reads at a fixed path. The container is disposable,
    so these are written where they really live rather than behind a parameter
    the production code would then have to carry for the test's sake."""
    bindir = os.path.join(work, "bin")
    os.makedirs(bindir, exist_ok=True)
    for name, body in FAKES.items():
        p = os.path.join(bindir, name)
        with open(p, "w", newline="\n") as fh:
            fh.write("#!/usr/bin/env python3\n" + body)
        os.chmod(p, 0o755)

    os.makedirs("/usr/lib/os7", exist_ok=True)
    with open("/usr/lib/os7/release.conf", "w", newline="\n") as fh:
        fh.write(
            "# fabricated by check-update-logic.py\n"
            'OS7_SUITE="%s"\n'
            'OS7_REPO_URI="file://%s/repo"\n'
            'OS7_REPO_ENABLED="no"\n'
            'OS7_DISTRIBUTION="resolute"\n'
            'OS7_UBUNTU_RELEASE="26.04"\n'
            'OS7_ARCHIVE_BASE="https://snapshot.ubuntu.com/ubuntu"\n'
            'OS7_ARCHIVE_SNAPSHOT="20260824T000000Z"\n' % (SUITE, work))
    with open("/usr/lib/os7/release.json", "w", newline="\n") as fh:
        json.dump({
            "version": MACHINE_VERSION, "channel": "development",
            "built": "2026-08-27T00:00:00Z", "architecture": "amd64",
            "reproducible": True,
            "base": {"distribution": "ubuntu", "release": "26.04",
                     "codename": "resolute",
                     "archive_snapshot": "20260824T000000Z",
                     "archive_base": "https://snapshot.ubuntu.com/ubuntu"},
        }, fh)

    with open("/etc/os-release", "w", newline="\n") as fh:
        fh.write('NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="26.04"\n'
                 'PRETTY_NAME="OS/7 1.0.0 (development)"\nIMAGE_ID="os7"\n'
                 'IMAGE_VERSION="%s"\nVARIANT_ID="server"\n' % MACHINE_VERSION)

    # The running environment's /boot, with TWO kernels — the case that turns a
    # string sort into a machine booting the older one (BUILD-NOTES #89).
    os.makedirs("/boot", exist_ok=True)
    for k in ("7.0.0-9-generic", "7.0.0-31-generic"):
        for prefix in ("vmlinuz-", "initrd.img-"):
            open("/boot/" + prefix + k, "w").close()
    return bindir


def build_repo(work, *, version=NEXT_VERSION, development=True, sign_with="os7",
               valid_days=30, extra=()):
    """A real, really-signed repository. gpg and gpgv are not faked."""
    repo = os.path.join(work, "repo")
    for d in ("index", os.path.join("releases", version)):
        os.makedirs(os.path.join(repo, d), exist_ok=True)

    entries = []
    for v, dev in [(version, development)] + list(extra):
        rdir = os.path.join(repo, "releases", v)
        os.makedirs(rdir, exist_ok=True)
        descriptor = {
            "version": v, "channel": "development",
            "released": "2026-08-27T00:00:00Z", "architecture": "amd64",
            "base": {"release": "26.04", "distribution": "resolute",
                     "archive_snapshot": "20260901T000000Z",
                     "archive_base": "https://snapshot.ubuntu.com/ubuntu"},
            "os7_suite": SUITE,
            "metapackage": {"os7-server": v, "os7-desktop": v},
            "components": [], "migrations": [],
            "signing": {"key": "DEADBEEF", "user_id": "test", "development": dev},
        }
        path = os.path.join(rdir, "release.json")
        with open(path, "w", newline="\n") as fh:
            json.dump(descriptor, fh)
        digest = sh(["sha256sum", path]).stdout.split()[0]
        entries.append({
            "version": v, "released": "2026-08-27T00:00:00Z",
            "architecture": "amd64", "archive_snapshot": "20260901T000000Z",
            "os7_suite": SUITE,
            "metapackage": {"os7-server": v, "os7-desktop": v},
            "manifest": "releases/%s/release.json" % v,
            "manifest_sha256": digest, "migrations": [], "supersedes": None,
        })

    entries.sort(key=lambda e: [int(x) for x in e["version"].split(".")], reverse=True)
    valid_until = sh(["date", "-u", "-d", "+%d days" % valid_days, "+%a, %d %b %Y %H:%M:%S UTC"]).stdout.strip()
    index = {"channel": "development", "releases": entries, "valid_until": valid_until}
    ipath = os.path.join(repo, "index", "development.json")
    with open(ipath, "w", newline="\n") as fh:
        json.dump(index, fh)

    # Two keyrings: the one the machine trusts, and a foreign one. Signing the
    # index with the second is the negative case — without it, "the signature
    # verified" is a sentence about a code path nobody has seen fail.
    gnupg = os.path.join(work, "gnupg-" + sign_with)
    os.makedirs(gnupg, exist_ok=True)
    os.chmod(gnupg, 0o700)
    env = dict(os.environ, GNUPGHOME=gnupg)
    if not os.path.exists(os.path.join(gnupg, "pubring.kbx")):
        sh(["gpg", "--batch", "--pinentry-mode", "loopback", "--passphrase", "",
            "--quick-generate-key", "OS7 check %s <c@localhost>" % sign_with,
            "ed25519", "sign", "never"], env=env)
    sh(["rm", "-f", ipath + ".asc"])
    sh(["gpg", "--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase", "",
        "--armor", "--detach-sign", "--output", ipath + ".asc", ipath], env=env)

    if sign_with == "os7":
        os.makedirs("/usr/share/keyrings", exist_ok=True)
        sh(["gpg", "--batch", "--yes", "--export", "--output",
            "/usr/share/keyrings/os7-archive-keyring.gpg"], env=env)
    return repo


def run_update(work, bindir, args, *, env_extra=None):
    """One Update-OS7 run, with a fresh call log. Returns (rc, stdout, stderr, log)."""
    log = os.path.join(work, "calls.log")
    state = os.path.join(work, "state.json")
    if os.path.exists(log):
        os.remove(log)
    # THE RUNNING ENVIRONMENT IS MOUNTED, and the fake has to say so. `Active`
    # on a boot environment is ZFS's `mounted` property, and Update-OS7 clones
    # from the environment that is active — so a fake that reports nothing
    # mounted is a machine with no running system, which is not the case under
    # test.
    with open(state, "w", newline="\n") as fh:
        json.dump({"mounted": {"rpool/ROOT/os7_a": True, "bpool/BOOT/os7_a": True}}, fh)
    layout = os.path.join(work, "layout.json")
    with open(layout, "w", newline="\n") as fh:
        json.dump(LAYOUT, fh)

    env = dict(os.environ)
    env["PATH"] = bindir + os.pathsep + env["PATH"]
    env["OS7_LOG"] = log
    env["OS7_STATE"] = state
    env["OS7_LAYOUT"] = layout
    env.setdefault("OS7_FAKE_CANDIDATE", NEXT_VERSION)
    env.setdefault("OS7_FAKE_INITRD_CONTENTS", "")
    # Where the module assembles. The fake mount seeds the root it standS for.
    env["OS7_UPDATE_ROOT"] = "/run/os7-update"
    if env_extra:
        env.update(env_extra)

    script = ("Import-Module /work/powershell/OS7/OS7.psd1 -Force; "
              "try { $r = Update-OS7 %s -Confirm:$false; "
              "  $r | ConvertTo-Json -Depth 4 -Compress } "
              "catch { [Console]::Error.WriteLine('THREW: ' + $_.Exception.Message); exit 3 }"
              % args)
    got = sh(["pwsh", "-NoProfile", "-NonInteractive", "-c", script], env=env)
    calls = []
    if os.path.exists(log):
        with open(log) as fh:
            for line in fh:
                try:
                    calls.append(json.loads(line))
                except ValueError:
                    pass
    return got.returncode, got.stdout, got.stderr, calls


def index_of(calls, predicate):
    for i, c in enumerate(calls):
        if predicate(c):
            return i
    return -1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in-container", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if not args.in_container:
        pin = {}
        with open(os.path.join(REPO, "build", "config", "os7-release.conf")) as fh:
            for line in fh:
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.split("=", 1)
                    pin[k.strip()] = v.strip().strip('"').strip("'")
        print("\n### the update train's decisions, against fakes")
        print("      building the container")
        built = sh(["docker", "build", "--provenance=false", "-q",
                    "-f", os.path.join(REPO, "installer", "testing", "Dockerfile.check-update"),
                    "-t", IMAGE,
                    "--build-arg", "PWSH_VERSION=" + pin.get("OS7_PWSH_VERSION", ""),
                    "--build-arg", "PWSH_SHA256_x64=" + pin.get("OS7_PWSH_SHA256_x64", ""),
                    "--build-arg", "PWSH_SHA256_arm64=" + pin.get("OS7_PWSH_SHA256_arm64", ""),
                    os.path.join(REPO, "installer", "testing")])
        if built.returncode != 0:
            print(built.stderr[-2000:], file=sys.stderr)
            sys.exit(1)
        # --privileged for mount(2): the assembly check reads the KERNEL's
        # mount table, so the mounts have to be real.
        inner = sh(["docker", "run", "--rm", "--privileged",
                    "-v", REPO + ":/work", IMAGE,
                    "python3", "/work/installer/testing/check-update-logic.py",
                    "--in-container"])
        sys.stdout.write(inner.stdout)
        sys.stderr.write(inner.stderr)
        sys.exit(inner.returncode)

    # ---- inside the container ------------------------------------------
    work = "/tmp/os7-update-check"
    os.makedirs(work, exist_ok=True)
    bindir = build_world(work)
    build_repo(work)

    bad = 0

    def check(ok, what, detail=""):
        nonlocal bad
        print("      %s  %s%s" % ("ok  " if ok else "FAIL", what,
                                  (" — " + detail) if detail else ""))
        if not ok:
            bad += 1

    # -- tier 1, run here so one command answers for both --------------------
    print("\n  the module's own self-test")
    st = sh(["pwsh", "-NoProfile", "-NonInteractive", "-c",
             "Import-Module /work/powershell/OS7/OS7.psd1 -Force; "
             "if (-not (Test-OS7Update)) { exit 1 }"])
    passed = st.stderr.count("  PASS  ")
    check(st.returncode == 0, "Test-OS7Update passes", "%d checks" % passed)

    # -- -WhatIf changes nothing --------------------------------------------
    print("\n  -WhatIf reports and does not write")
    rc, out, err, calls = run_update(work, bindir, "-WhatIf -AllowDevelopment")
    check(rc == 0, "it succeeds", err.strip().splitlines()[-1] if err.strip() else "")
    check(index_of(calls, lambda c: c[0].endswith("zfs") and "snapshot" in c) < 0,
          "no snapshot was taken")
    check(index_of(calls, lambda c: c[0].endswith("zfs") and "clone" in c) < 0,
          "nothing was cloned")
    # THE LAST LINE, not the whole of stdout. Under -WhatIf every `2>` file
    # redirection in the module — Get-OS7OsReleaseField has one, and so does
    # Invoke-OS7Native — emits PowerShell's own "What if: Performing the
    # operation Output to File" onto stdout, because a redirection is Out-File
    # underneath and Out-File honours $WhatIfPreference. It is noise from the
    # host rather than from this cmdlet, and the contract OS7.psm1's header
    # states — one JSON object on stdout — is what the last line carries.
    last = (out.strip().splitlines() or [""])[-1]
    check(NEXT_VERSION in last, "and it names the release it would apply", last[:90])

    # -- the full sequence ---------------------------------------------------
    print("\n  the sequence, staged")
    rc, out, err, calls = run_update(work, bindir, "-Stage -AllowDevelopment")
    check(rc == 0, "Update-OS7 -Stage succeeds",
          (err.strip().splitlines() or [""])[-1][:120])

    plan = {}
    try:
        plan = json.loads(out.strip().splitlines()[-1]) if out.strip() else {}
    except ValueError:
        pass
    check(plan.get("Applied") is True, "it reports the release applied")
    check(plan.get("Staged") is True and plan.get("Activated") is False,
          "-Stage stopped before activation")
    check(plan.get("From") == MACHINE_VERSION and plan.get("To") == NEXT_VERSION,
          "from and to are the versions asked for",
          "%s -> %s" % (plan.get("From"), plan.get("To")))

    # THE ORDER, which is the half a set of assertions cannot see.
    def at(pred):
        return index_of(calls, pred)

    i_datasnap = at(lambda c: c[0].endswith("zfs") and "snapshot" in c and
                    any("rpool/DATA@" in x for x in c))
    i_clone = at(lambda c: c[0].endswith("zfs") and "clone" in c)
    i_install = at(lambda c: c[0].endswith("apt-get") and "install" in c)
    i_upgrade = at(lambda c: c[0].endswith("apt-get") and "full-upgrade" in c)
    i_autorm = at(lambda c: c[0].endswith("apt-get") and "autoremove" in c)
    i_initrd = at(lambda c: c[0].endswith("update-initramfs"))
    i_grub = at(lambda c: c[0].endswith("update-grub"))

    check(i_datasnap >= 0, "the rpool/DATA rollback net was snapshotted",
          "§4.2 step 1 covers three things and the BE primitive does two")
    check(i_datasnap >= 0 and i_clone > i_datasnap,
          "the net was taken BEFORE the clone")
    check(i_install >= 0 and i_upgrade > i_install,
          "apt install came before full-upgrade")
    check(i_autorm > i_upgrade,
          "and autoremove came LAST",
          "reversing install and autoremove removes the product (C10)")
    check(i_initrd > i_autorm, "the initramfs was rebuilt after the packages moved")
    check(i_grub > i_initrd, "and the menu after the initramfs")

    # -- nothing is left mounted --------------------------------------------
    #
    # AFTER A RUN THAT FAILED, which is the only run that can leak. A successful
    # -Stage reaches its own teardown; the question is what happens when a step
    # between the assembly and the teardown throws. The first version of this
    # check asked only after the successful run and would have passed while
    # every failure left the tree mounted — and a mounted clone is a second
    # environment reporting Active, which is the state the module's own header
    # calls the second of the three things it is most likely to get wrong.
    print("\n  the clone is taken down — including when a step throws")
    rc, out, err, _ = run_update(work, bindir, "-Stage -AllowDevelopment",
                                 env_extra={"OS7_FAKE_INSTALLS_AS": "9.9.9.9"})
    check(rc != 0, "the induced failure really failed", "exit %s" % rc)
    left = [l for l in open("/proc/self/mountinfo") if "/run/os7-update" in l]
    check(len(left) == 0,
          "and nothing is still mounted under /run/os7-update",
          "%d mount(s) left" % len(left) if left else "")
    check("Remove-OS7BootEnvironment" in err,
          "and the environment it left behind is named, with the command that clears it",
          (err.strip().splitlines() or [""])[-1][:110])

    rc, out, err, _ = run_update(work, bindir, "-Stage -AllowDevelopment")
    left = [l for l in open("/proc/self/mountinfo") if "/run/os7-update" in l]
    check(rc == 0 and len(left) == 0,
          "a successful run leaves nothing mounted either",
          "%d mount(s) left" % len(left) if left else "")

    # -- the refusals --------------------------------------------------------
    print("\n  what it refuses")
    rc, out, err, _ = run_update(work, bindir, "-Stage")
    check(rc != 0 and "DEVELOPMENT" in err,
          "a release signed by a development key, without -AllowDevelopment",
          (err.strip().splitlines() or [""])[-1][:100])

    build_repo(work, sign_with="foreign")
    rc, out, err, _ = run_update(work, bindir, "-Stage -AllowDevelopment")
    check(rc != 0 and "trust" in err.lower(),
          "an index signed by a key it does not trust",
          (err.strip().splitlines() or [""])[-1][:100])
    build_repo(work)  # back to the trusted key

    # NAMED EXPLICITLY, because a 2.x release is not `Applicable` and so would
    # never be CHOSEN — the refusal under test is the one an operator provokes
    # by asking for it by name.
    build_repo(work, version="2.0.0.0")
    rc, out, err, _ = run_update(work, bindir,
                                 "-Version 2.0.0.0 -Stage -AllowDevelopment",
                                 env_extra={"OS7_FAKE_CANDIDATE": "2.0.0.0"})
    check(rc != 0 and "generation" in err,
          "a target in another OS/7 generation (C12)",
          (err.strip().splitlines() or [""])[-1][:100])
    build_repo(work)

    rc, out, err, _ = run_update(work, bindir, "-Stage -AllowDevelopment",
                                 env_extra={"OS7_FAKE_INSTALLS_AS": "9.9.9.9"})
    check(rc != 0 and "not " + NEXT_VERSION in err,
          "apt exiting 0 having installed a different version",
          (err.strip().splitlines() or [""])[-1][:110])

    # -- the initramfs assertion ---------------------------------------------
    print("\n  the initramfs carries the TPM2 handler forward, or it says so")

    # A machine that does NOT use the handler must still update. Requiring one
    # here would fail every update on hardware without a TPM.
    rc, out, err, _ = run_update(work, bindir, "-Stage -AllowDevelopment",
                                 env_extra={"OS7_FAKE_INITRD_CONTENTS": "bin/sh"})
    check(rc == 0, "an environment with no TPM handler is not required to have one",
          (err.strip().splitlines() or [""])[-1][:100])

    # AND THE CASE THAT HAS TO FAIL. The environment configures the handler and
    # the rebuilt image does not contain it — BUILD-NOTES #64's shape exactly: a
    # handler that is present, gives up silently at every boot, and has three
    # checks reporting it installed. `update-initramfs` exits 0 either way.
    rc, out, err, _ = run_update(
        work, bindir, "-Stage -AllowDevelopment",
        env_extra={"OS7_FAKE_TPM": "1", "OS7_FAKE_INITRD_CONTENTS": "bin/sh,conf/conf.d"})
    check(rc != 0 and "os7-tpm2" in err,
          "an initrd that DROPPED the handler is refused",
          (err.strip().splitlines() or [""])[-1][:120])

    # And accepted when it is there, so the refusal above is about the handler
    # rather than about the check being unable to pass at all.
    rc, out, err, _ = run_update(
        work, bindir, "-Stage -AllowDevelopment",
        env_extra={"OS7_FAKE_TPM": "1",
                   "OS7_FAKE_INITRD_CONTENTS": "bin/sh,scripts/local-top/os7-tpm2"})
    check(rc == 0, "and an initrd that carries it is accepted",
          (err.strip().splitlines() or [""])[-1][:100])

    print()
    if bad:
        print("%d problem(s)." % bad)
        sys.exit(1)
    print("The update train's decisions hold: the order is §4.2's as C10 corrects it,")
    print("and every refusal it is supposed to make was seen to happen.")
    print("run-s5.py on a booted machine is still the gate.")


if __name__ == "__main__":
    main()
