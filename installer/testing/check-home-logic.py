#!/usr/bin/env python3
"""
`Move-OS7Home`'s DECISIONS, checked in seconds and without ZFS.

    ./check-home-logic.py            build the container if needed, then run

WHAT THIS IS AND IS NOT. It runs the real `powershell/OS7` module against a
`zfs` that is a fake and a filesystem that is real, and checks the commands the
module issues, the ORDER it issues them in, and what is on the disk afterwards.
So it is a test of OS/7's layer — where the dataset is created, what is verified
before anything is renamed, what is undone when a step fails — and it is NOT a
test of ZFS or of a machine. `run-phase3.py` and `run-s5.py` are the tests of
the machine and nothing here replaces them.

WHY IT EXISTS. `Move-OS7Home` moves somebody's home directory, on a machine
that already has one, and docs/BACKUP-PLAN.md B-6 — a VM with real ZFS — has
never been run. A destructive cmdlet with no test at all is not shippable; a
destructive cmdlet whose decisions are checked in three seconds is the same
bargain `check-be-logic.py` struck for the boot environments, and it found two
bugs there that a 25-minute VM cycle would have found much later.

THE FAKE'S ONE LOAD-BEARING BEHAVIOUR is that a ZFS dataset IS A SEPARATE
FILESYSTEM. `zfs create -o mountpoint=X` mounts a tmpfs at X and `zfs set
mountpoint=Y` does `mount --move`, so st_dev really changes, `Get-OS7Home`'s
independent witness really answers, and the migrated files really travel with
the mount. A fake that modelled this with a directory rename would make the
module look correct while the one property the module exists to establish went
unchecked.

WHY A CONTAINER. Two things this needs are not on macOS: `find -printf`,
`stat -c` and `diff --no-dereference`, which are what the module verifies a copy
with, and mount(2), which is what makes a dataset a separate filesystem. So the
check re-runs itself inside `docker run --privileged` — the same move
`check-image.py` makes for loop mounts — in a private mount namespace, and the
PowerShell in that container is the version `build/config/os7-release.conf`
pins, hash and all.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
MODULE = "/repo/powershell/OS7/OS7.psd1"
IMAGE = "os7-check-home"
INSIDE = "OS7_CHECK_HOME_INSIDE"

USER = "os7admin"
UID = "1001"

# ---------------------------------------------------------------------------
# The fake zfs
#
# It keeps its state in one JSON file and its mounts in the real kernel. Only
# what the module actually calls is implemented; anything else exits 2 saying
# so, because a fake that silently succeeds at a command nobody modelled is how
# a mock reports that untested code works.
# ---------------------------------------------------------------------------
FAKE_ZFS = r'''#!/usr/bin/env python3
import json, os, subprocess, sys

LOG   = os.environ["HOME_LOG"]
STATE = os.environ["HOME_STATE"]
argv  = sys.argv[1:]
sub   = argv[0] if argv else ""
open(LOG, "a").write("zfs " + " ".join(argv) + "\n")

try:    DS = json.load(open(STATE))
except Exception: DS = {}
def save(): json.dump(DS, open(STATE, "w"))

def die(msg, code=1):
    sys.stderr.write(msg + "\n"); sys.exit(code)

def prop(v, src="LOCAL"):
    return {"value": v, "source": {"type": src, "data": "-"}}

def node(name):
    d = DS[name]
    mp = d.get("mountpoint") or "none"
    return {"name": name,
            "type": "SNAPSHOT" if "@" in name else "FILESYSTEM",
            "pool": name.split("/")[0], "createtxg": 1,
            "properties": {
                "used": prop(4096, "NONE"), "available": prop(64 * 1024 ** 3, "NONE"),
                "referenced": prop(4096, "NONE"),
                "mountpoint": prop(mp), "creation": prop(1787676263, "NONE"),
                "compression": prop("lz4"), "quota": prop(0, "DEFAULT"),
                "origin": prop("-", "NONE"),
                "mounted": prop("yes" if d.get("mounted") else "no", "NONE"),
                "canmount": prop(d.get("canmount", "on")),
                "usedbysnapshots": prop(0, "NONE"), "usedbydataset": prop(4096, "NONE"),
                "usedbyrefreservation": prop(0, "NONE"), "usedbychildren": prop(0, "NONE"),
            }}

def emit(names, only=None):
    out = {}
    for n in names:
        x = node(n)
        if only:
            x["properties"] = {k: v for k, v in x["properties"].items() if k in only}
        out[n] = x
    print(json.dumps({"output_version": {"command": "zfs " + sub,
                                         "vers_major": 0, "vers_minor": 1},
                      "datasets": out}))

def positional(rest, valued=("-o", "-d", "-t")):
    out, skip = [], False
    for a in rest:
        if skip: skip = False; continue
        if a in valued: skip = True; continue
        if a.startswith("-"): continue
        out.append(a)
    return out

def options(rest):
    props, it = {}, iter(rest)
    for a in it:
        if a == "-o":
            k, _, v = next(it).partition("="); props[k] = v
    return props

if sub == "list":
    # -o <cols> is consumed as a valued flag; for `list` the first positional
    # after it is a dataset name, never the column list.
    names = positional(argv[1:])
    types = "filesystem"
    for i, a in enumerate(argv):
        if a == "-t": types = argv[i + 1]
    recurse = "-r" in argv
    want = []
    for n in names:
        if n not in DS: die("cannot open '%s': dataset does not exist" % n)
        want.append(n)
        if recurse:
            want += [k for k in DS if k.startswith(n + "/") or k.startswith(n + "@")]
    if not names:
        want = list(DS)
    def keep(n):
        snap = "@" in n
        return ("snapshot" in types or "all" in types) if snap else \
               ("filesystem" in types or "all" in types)
    emit(sorted({n for n in want if keep(n)}))

elif sub == "get":
    rest = positional(argv[1:], valued=("-o",))
    props, names = (rest[0].split(",") if rest else ["all"]), rest[1:]
    for n in names:
        if n not in DS: die("cannot open '%s': dataset does not exist" % n)
    emit(names, only=None if "all" in props else props)

elif sub == "create":
    props = options(argv[1:])
    name = positional(argv[1:])[-1]
    if name in DS: die("cannot create '%s': dataset already exists" % name)
    parent = name.rsplit("/", 1)[0]
    if "/" in name and parent not in DS:
        die("cannot create '%s': parent does not exist" % name)
    mp = props.get("mountpoint")
    DS[name] = {"mountpoint": mp, "canmount": props.get("canmount", "on"),
                "mounted": False}
    # A DATASET IS A SEPARATE FILESYSTEM. This is the whole of the fake.
    if mp and mp != "none" and props.get("canmount", "on") != "off":
        os.makedirs(mp, exist_ok=True)
        subprocess.run(["mount", "-t", "tmpfs", "tmpfs", mp], check=True)
        DS[name]["mounted"] = True
    save()

elif sub == "set":
    pairs = [a for a in argv[1:] if "=" in a]
    for name in [a for a in argv[1:] if "=" not in a]:
        if name not in DS: die("cannot open '%s': dataset does not exist" % name)
        for p in pairs:
            k, _, v = p.partition("=")
            if k == "mountpoint":
                old = DS[name].get("mountpoint")
                if DS[name].get("mounted") and old and old != "none":
                    os.makedirs(v, exist_ok=True)
                    # --move, because that is what ZFS does: the filesystem and
                    # everything on it appears at the new path. A rename would
                    # model the wrong thing entirely.
                    subprocess.run(["mount", "--move", old, v], check=True)
                DS[name]["mountpoint"] = v
            else:
                DS[name][k] = v
    save()

elif sub == "snapshot":
    full = positional(argv[1:])[-1]
    base, _, snap = full.partition("@")
    if base not in DS: die("cannot open '%s': dataset does not exist" % base)
    DS[full] = {"mountpoint": None, "canmount": "on", "mounted": False}
    save()

elif sub == "destroy":
    name = positional(argv[1:])[-1]
    if name not in DS: die("cannot open '%s': dataset does not exist" % name)
    victims = [name] + ([k for k in DS if k.startswith(name + "/")
                         or k.startswith(name + "@")] if "-r" in argv else [])
    for v in victims:
        d = DS[v]
        if d.get("mounted") and d.get("mountpoint"):
            subprocess.run(["umount", d["mountpoint"]], check=False)
        del DS[v]
    save()

else:
    die("fake zfs: unmodelled subcommand '%s'" % sub, 2)
'''

# A shim that records the call and then does the real thing, so that the order
# of `mv` against `zfs set mountpoint` is visible in ONE log. That order is the
# difference between a migration and a home directory that vanishes.
SHIM = '''#!/bin/sh
echo "{name} $*" >> "$HOME_LOG"
exec {real} "$@"
'''

# `cp` that drops one file, for the case that matters most: a copy that lied.
BAD_CP = '''#!/bin/sh
echo "cp $*" >> "$HOME_LOG"
/usr/bin/cp "$@" || exit $?
find "$HOME_SABOTAGE" -name 'notes.txt' -delete
exit 0
'''


def sh(path, text, mode=0o755):
    with open(path, "w") as f:
        f.write(text)
    os.chmod(path, mode)


def pin(name):
    """A value out of build/config/os7-release.conf. THE only place a version
    number or an archive URL may live in this repository (CLAUDE.md), so the
    container's PowerShell is the image's PowerShell rather than a second pin
    that rots quietly."""
    conf = os.path.join(REPO, "build", "config", "os7-release.conf")
    for line in open(conf):
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit(f"{name} is not in {conf}")


def relaunch():
    """Build the container and run this file inside it."""
    if not shutil.which("docker"):
        sys.exit("docker is needed: this check wants Linux, root and mount(2). "
                 "See the header.")
    print("    building the check container (first run only) …")
    subprocess.run(
        ["docker", "build", "-q", "-t", IMAGE,
         "-f", os.path.join(HERE, "Dockerfile.check-home"),
         "--build-arg", f"PWSH_VERSION={pin('OS7_PWSH_VERSION')}",
         "--build-arg", f"PWSH_SHA256_x64={pin('OS7_PWSH_SHA256_x64')}",
         "--build-arg", f"PWSH_SHA256_arm64={pin('OS7_PWSH_SHA256_arm64')}",
         HERE],
        check=True, stdout=subprocess.DEVNULL)
    # --privileged for mount(2); `unshare --mount --propagation private` so that
    # `mount --move` is legal (it refuses on a shared mount) and so that nothing
    # created here can propagate out of the container. BUILD-NOTES #18 is the
    # same lesson from the installer's side.
    return subprocess.run(
        ["docker", "run", "--rm", "--privileged",
         "-e", f"{INSIDE}=1",
         "-v", f"{REPO}:/repo:ro", IMAGE,
         "unshare", "--mount", "--propagation", "private", "--",
         "python3", "/repo/installer/testing/check-home-logic.py"]).returncode


# ---------------------------------------------------------------------------
class Lab:
    """One temporary machine: a fake root, a fake account, a fake zfs."""

    def __init__(self):
        # Deliberately NOT under /tmp. The module compares the home's st_dev
        # against the boot environment's, and the check points the second of
        # those at this tree — so the tree has to be an ordinary directory on an
        # ordinary filesystem, which /tmp is not guaranteed to be.
        self.dir = tempfile.mkdtemp(prefix="os7-home-", dir="/")
        self.bin = os.path.join(self.dir, "bin")
        self.root = os.path.join(self.dir, "root")
        self.home = os.path.join(self.root, "home")
        self.user_home = os.path.join(self.home, USER)
        self.staging = os.path.join(self.root, "run", "os7-home-migrate")
        self.log = os.path.join(self.dir, "cmd.log")
        self.state = os.path.join(self.dir, "state.json")

        os.makedirs(self.bin)
        os.makedirs(self.user_home)
        os.makedirs(os.path.join(self.root, "run"))

        sh(os.path.join(self.bin, "zfs"), FAKE_ZFS)
        for name, real in (("mv", "/usr/bin/mv"), ("cp", "/usr/bin/cp")):
            sh(os.path.join(self.bin, name), SHIM.format(name=name, real=real))

        self.env = dict(os.environ)
        self.env["PATH"] = self.bin + os.pathsep + self.env["PATH"]
        self.env["HOME_LOG"] = self.log
        self.env["HOME_STATE"] = self.state

        # The machine's datasets, as New-OS7Storage would have left them on a
        # machine installed BEFORE the fix: a boot environment, and a stray
        # empty /home/os7 named after the old -UserName default.
        #
        # THE STRAY IS REALLY MOUNTED. Writing it into the state file alone made
        # `zfs list` say it was a dataset while st_dev said it was not — which
        # is precisely the disagreement Get-OS7Home exists to report, so the
        # first version of this file had the module correctly reporting a
        # broken machine and the check calling that a failure.
        self.stray = os.path.join(self.home, "os7")
        os.makedirs(self.stray)
        subprocess.run(["mount", "-t", "tmpfs", "tmpfs", self.stray], check=True)
        json.dump({
            "rpool": {"mountpoint": "none", "canmount": "off", "mounted": False},
            "rpool/ROOT": {"mountpoint": "none", "canmount": "off", "mounted": False},
            "rpool/ROOT/os7_a": {"mountpoint": self.root, "canmount": "noauto",
                                 "mounted": True},
            "rpool/USERDATA": {"mountpoint": "none", "canmount": "off",
                               "mounted": False},
            "rpool/USERDATA/os7_1111": {"mountpoint": self.stray, "canmount": "on",
                                        "mounted": True},
        }, open(self.state, "w"))

        self.account = f"{USER}:x:{UID}:{UID}:OS/7 admin:{self.user_home}:/bin/bash"
        self.set_account(self.account)
        self.set_sessions("")
        self.set_processes("")

    # -- the fakes that answer questions about the account -------------------
    def set_account(self, line):
        sh(os.path.join(self.bin, "getent"),
           f'#!/bin/sh\necho "{line}" >> "$HOME_LOG"\n'
           + (f'echo "{line}"\n' if line else "exit 2\n"))

    def set_sessions(self, text):
        sh(os.path.join(self.bin, "loginctl"),
           f'#!/bin/sh\nprintf "%s" "{text}"\n[ -n "{text}" ] && echo\nexit 0\n')

    def set_processes(self, text):
        sh(os.path.join(self.bin, "ps"),
           f'#!/bin/sh\n[ -n "{text}" ] || exit 1\necho "{text}"\n')

    # -- the home, as a machine that has been used would have it -------------
    def furnish(self):
        os.makedirs(os.path.join(self.user_home, "docs"), exist_ok=True)
        with open(os.path.join(self.user_home, ".bashrc"), "w") as f:
            f.write("# os7\n")
        with open(os.path.join(self.user_home, "docs", "notes.txt"), "w") as f:
            f.write("the thing a rollback must not un-say\n")
        os.symlink("docs/notes.txt", os.path.join(self.user_home, "latest"))
        os.chmod(os.path.join(self.user_home, "docs"), 0o700)
        os.chmod(self.user_home, 0o750)
        os.chown(self.user_home, int(UID), int(UID))
        for r, ds, fs in os.walk(self.user_home):
            for n in ds + fs:
                p = os.path.join(r, n)
                os.chown(p, int(UID), int(UID), follow_symlinks=False)

    def run(self, body, extra_env=None):
        script = os.path.join(self.dir, "drive.ps1")
        with open(script, "w") as f:
            f.write(f"""
$ErrorActionPreference = 'Stop'
Import-Module '{MODULE}' -Force
$m = Get-Module OS7
& $m {{
    $script:OS7HomeRoot        = '{self.home}'
    $script:OS7RootPath        = '{self.root}'
    $script:OS7HomeStagingRoot = '{self.staging}'
}}
{body}
""")
        env = dict(self.env)
        if extra_env:
            env.update(extra_env)
        return subprocess.run(["pwsh", "-NoProfile", "-File", script],
                              env=env, capture_output=True, text=True)

    def commands(self, since=0):
        if not os.path.exists(self.log):
            return []
        return open(self.log).read().splitlines()[since:]

    def mark(self):
        return len(self.commands())

    def clean(self):
        # Only what really is a mount point. The fake's state file says the boot
        # environment is "mounted" — it is a plain directory, on purpose, and
        # umounting it printed a warning on every run for no reason.
        for path in sorted((d.get("mountpoint") for d in
                            json.load(open(self.state)).values() if d.get("mountpoint")),
                           key=len, reverse=True):
            if subprocess.run(["mountpoint", "-q", path], check=False).returncode == 0:
                subprocess.run(["umount", "-l", path], check=False)
        shutil.rmtree(self.dir, ignore_errors=True)


# ---------------------------------------------------------------------------
FAILS = []

# PowerShell colours its error output, and an escape sequence in a one-line
# detail turns the report into unreadable noise. This is a report, not a
# terminal.
ANSI = __import__("re").compile(r"\x1b\[[0-9;]*[A-Za-z]")


def plain(text, limit=110):
    """The LAST meaningful line, not the first.

    stderr here begins with the module's own progress lines and ends with what
    went wrong, so a detail taken from the front reports "ZFS layer: …" for
    every failure in the file.
    """
    text = ANSI.sub("", str(text or "")).replace("\r", "")
    keep = []
    for raw in text.splitlines():
        l = raw.strip()
        # The module's progress lines, and PowerShell's error CARET block — the
        # "Line |", "  42 |  throw …", "     | ~~~~" frame it draws around the
        # offending source. None of that is the message.
        if not l or l.startswith(("OS7-STEP", "ZFS-STEP", "Line |", "|", "+")):
            continue
        if __import__("re").match(r"^\d+ \||^~+$", l):
            continue
        keep.append(l)
    return (keep[-1] if keep else "")[:limit]


def check(ok, what, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {what}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAILS.append(what)


def zfs_writes(lines):
    return [l for l in lines
            if l.startswith(("zfs create", "zfs set", "zfs snapshot", "zfs destroy"))]


def scenario_reads(lab):
    print("\n### what Get-OS7Home sees on a machine that has BUILD-NOTES #74\n")
    p = lab.run("Get-OS7Home | ConvertTo-Json -Compress -Depth 4")
    if p.returncode != 0:
        check(False, "Get-OS7Home runs", plain(p.stderr or p.stdout))
        return
    homes = json.loads(p.stdout)
    if isinstance(homes, dict):
        homes = [homes]
    by = {h["Path"]: h for h in homes}

    me = by.get(lab.user_home)
    check(me is not None, f"{USER}'s home is listed", ", ".join(sorted(by)))
    if me:
        check(me["OwnDataset"] is False and me["OwnFilesystem"] is False,
              "it is reported as NOT on a dataset of its own",
              f"OwnDataset={me['OwnDataset']} OwnFilesystem={me['OwnFilesystem']}")
        check(me["Agrees"] is True, "ZFS and stat(2) agree about that")
        check("Restore-OS7 would roll this home back" in (me["Note"] or ""),
              "and the note says what that costs", (me["Note"] or "")[:70])
        check(me["Dataset"] == "rpool/ROOT/os7_a",
              "it names the boot environment the home is inside", str(me["Dataset"]))

    stray = by.get(lab.stray)
    check(stray is not None and stray["Account"] is None and stray["OwnDataset"],
          "the empty /home/os7 dataset is reported, with no account behind it")
    check(stray is not None and "BUILD-NOTES #74" in (stray["Note"] or ""),
          "and named as what #74's old default left behind",
          plain(stray["Note"] if stray else "not listed"))


def scenario_whatif(lab):
    print("\n### -WhatIf\n")
    at = lab.mark()
    out = os.path.join(lab.dir, "whatif.json")
    # TO A FILE, not to stdout. PowerShell writes its own "What if:" line to the
    # HOST, and the host's output IS stdout (BUILD-NOTES #60) — so a dry run's
    # stdout is prose plus an object, and the check reads the object from where
    # the object actually is.
    p = lab.run(f"Move-OS7Home -UserName {USER} -WhatIf | "
                f"ConvertTo-Json -Compress | Set-Content '{out}'")
    check(p.returncode == 0, "it runs", plain(p.stderr))
    wrote = zfs_writes(lab.commands(at))
    # THE ONE THAT MATTERS. A dry run that creates a dataset is not a dry run.
    check(not wrote, "NOTHING was created, set, snapshotted or destroyed",
          "; ".join(wrote))
    check("would rename" in p.stderr and "would set" in p.stderr,
          "every step is described, on stderr where the progress lines go")
    if os.path.exists(out):
        r = json.load(open(out))
        check(r["DryRun"] is True and r["Migrated"] is False,
              "and the result says DryRun, Migrated=False", r["Reason"])
    else:
        check(False, "and the result says DryRun, Migrated=False", "no result written")


def scenario_busy(lab):
    print("\n### it refuses while the account is in use\n")
    lab.set_sessions("3 1001 os7admin seat0 tty1")
    at = lab.mark()
    p = lab.run(f"Move-OS7Home -UserName {USER} -Confirm:$false")
    check(p.returncode != 0, "it fails")
    check("still using" in p.stderr and "terminate-user" in p.stderr,
          "and says who, and how to fix it", plain(p.stderr))
    check(not zfs_writes(lab.commands(at)),
          "nothing was created before the refusal")
    lab.set_sessions("")


def scenario_not_checked(lab):
    print("\n### a probe that cannot answer says so\n")
    p = lab.run(f"Move-OS7Home -UserName {USER} -WhatIf")
    check("NOT CHECKED: open files" in p.stderr,
          "fuser is absent, so the open-files probe reports NOT CHECKED",
          "psmisc is deliberately not in the container")
    check("idle check, loginctl: nothing" in p.stderr
          and "idle check, processes: nothing" in p.stderr,
          "the two probes that COULD answer are named individually")


def scenario_bad_copy(lab):
    print("\n### a copy that lied\n")
    sh(os.path.join(lab.bin, "cp"), BAD_CP)
    at = lab.mark()
    p = lab.run(f"Move-OS7Home -UserName {USER} -Confirm:$false",
                extra_env={"HOME_SABOTAGE": lab.staging})
    check(p.returncode != 0, "the migration fails")
    check("does not match" in p.stderr or "differ" in p.stderr,
          "because the verification caught the missing file",
          plain(p.stderr))
    issued = lab.commands(at)
    check(any(l.startswith("zfs destroy") for l in issued),
          "the half-built dataset was destroyed")
    check(not any(l.startswith("mv ") for l in issued),
          "and the original home was never renamed")
    check(os.path.exists(os.path.join(lab.user_home, "docs", "notes.txt")),
          "the file is still in the original home")
    sh(os.path.join(lab.bin, "cp"), SHIM.format(name="cp", real="/usr/bin/cp"))


def scenario_migrate(lab):
    print("\n### the migration\n")
    at = lab.mark()
    p = lab.run(f"Move-OS7Home -UserName {USER} -Confirm:$false | "
                "ConvertTo-Json -Compress")
    if p.returncode != 0:
        check(False, "Move-OS7Home completes", plain(p.stderr or p.stdout))
        return None
    result = json.loads(p.stdout)
    check(result["Migrated"] is True, "Move-OS7Home reports a migration",
          result["Reason"])

    issued = lab.commands(at)
    order = [l.split()[0] + " " + l.split()[1] if l.startswith("zfs") else l.split()[0]
             for l in issued if l.startswith(("zfs ", "mv ", "cp "))]

    # -- THE ORDER IS THE DESIGN --------------------------------------------
    def first(pred):
        for i, l in enumerate(issued):
            if pred(l):
                return i
        return -1

    i_snap = first(lambda l: l.startswith("zfs snapshot"))
    # `zfs create` puts the -o options FIRST and the dataset name last, so the
    # name is not a prefix of the line. The first version of this matched on
    # startswith and reported "create at -1" against a create that had happened.
    i_create = first(lambda l: l.startswith("zfs create") and "/USERDATA/os7admin_" in l)
    i_cp = first(lambda l: l.startswith("cp "))
    i_mv = first(lambda l: l.startswith("mv "))
    i_set = first(lambda l: l.startswith("zfs set") and "mountpoint=" in l)

    check(i_snap >= 0, "the boot environment was snapshotted")
    check(0 <= i_snap < i_create, "BEFORE the dataset was created",
          f"snapshot at {i_snap}, create at {i_create}")
    check(0 <= i_create < i_cp < i_mv, "created and filled before anything was renamed",
          f"create {i_create}, cp {i_cp}, mv {i_mv}")
    check(0 <= i_mv < i_set,
          "the original was renamed BEFORE the mountpoint moved onto the home",
          f"mv {i_mv}, set {i_set}")

    # -- THE TRAP THIS CMDLET WAS WRITTEN AROUND ----------------------------
    creates = [l for l in issued if l.startswith("zfs create")]
    check(not any(f"mountpoint={lab.user_home} " in l + " " for l in creates),
          "NO dataset was created directly at the home "
          "(overlay=on would have hidden the files)",
          "; ".join(creates)[:120])
    check(any(f"mountpoint={lab.staging}/" in l for l in creates),
          "it was created on a staging path under /run instead")

    # -- and what is on the disk --------------------------------------------
    q = lab.run(f"Get-OS7Home -UserName {USER} | ConvertTo-Json -Compress -Depth 4")
    after = json.loads(q.stdout)
    check(after["OwnDataset"] is True, "ZFS says the home is now its own dataset")
    check(after["OwnFilesystem"] is True,
          "and stat(2) says it is a different filesystem from the boot environment",
          f"dev {after['DeviceId']}")
    check(after["Dataset"] == result["Dataset"],
          "the dataset is the one the migration made", str(after["Dataset"]))
    check(after["Dataset"].startswith("rpool/USERDATA/"),
          "under USERDATA, a sibling of ROOT (SETUP-PLAN §4.4)")

    notes = os.path.join(lab.user_home, "docs", "notes.txt")
    check(os.path.exists(notes) and "un-say" in open(notes).read(),
          "the user's file is there, with its contents")
    st = os.stat(lab.user_home)
    check(st.st_uid == int(UID) and st.st_gid == int(UID),
          "the home is still owned by the account", f"uid {st.st_uid}")
    check(oct(st.st_mode & 0o777) == "0o750",
          "with the mode it had before", oct(st.st_mode & 0o777))
    link = os.path.join(lab.user_home, "latest")
    check(os.path.islink(link) and os.readlink(link) == "docs/notes.txt",
          "the symlink came across as a symlink")

    check(result["Original"] and os.path.isdir(result["Original"]),
          "the original was left aside, not deleted", str(result["Original"]))
    check(result["Snapshot"] and result["Snapshot"].startswith("rpool/ROOT/os7_a@"),
          "and the snapshot names the boot environment", str(result["Snapshot"]))
    return result


def scenario_idempotent(lab):
    print("\n### running it twice\n")
    at = lab.mark()
    p = lab.run(f"Move-OS7Home -UserName {USER} -Confirm:$false | ConvertTo-Json -Compress")
    check(p.returncode == 0, "the second run succeeds", plain(p.stderr))
    if p.returncode == 0:
        again = json.loads(p.stdout)
        check(again["Migrated"] is False and "already" in again["Reason"],
              "and reports that there was nothing to do", again["Reason"])
    check(not zfs_writes(lab.commands(at)), "having changed nothing")


def scenario_unknown_account(lab):
    print("\n### an account that does not exist\n")
    lab.set_account("")
    at = lab.mark()
    p = lab.run("Move-OS7Home -UserName nobodyhere -Confirm:$false")
    check(p.returncode != 0, "it fails")
    check("getent knows no account" in p.stderr,
          "naming getent rather than /etc/passwd — authd accounts are not in the file")
    check(not zfs_writes(lab.commands(at)), "and changed nothing")
    lab.set_account(lab.account)


def scenario_remove_original(lab):
    print("\n### -RemoveOriginal\n")
    p = lab.run(f"Move-OS7Home -UserName {USER} -RemoveOriginal -Confirm:$false | "
                "ConvertTo-Json -Compress")
    if p.returncode != 0:
        check(False, "it completes", plain(p.stderr or p.stdout))
        return
    r = json.loads(p.stdout)
    check(r["Migrated"] is True, "it completes", r["Reason"])
    check(r["Original"] is None, "no set-aside copy is left behind")
    leftovers = [n for n in os.listdir(lab.home) if "os7-premigration" in n]
    check(not leftovers, "and there is nothing premigration-shaped in /home",
          ", ".join(leftovers))
    check(r["Snapshot"] is not None,
          "the snapshot still holds the original", str(r["Snapshot"]))
    notes = os.path.join(lab.user_home, "docs", "notes.txt")
    check(os.path.exists(notes) and "un-say" in open(notes).read(),
          "and the user's file is on the dataset")


def main():
    if os.environ.get(INSIDE) != "1":
        if sys.platform != "linux" or os.geteuid() != 0:
            raise SystemExit(relaunch())

    if not shutil.which("pwsh"):
        sys.exit("pwsh not found; this check runs the real module.")

    print("### Move-OS7Home's decisions, against a fake zfs and a real filesystem")

    # TWO MACHINES. -RemoveOriginal needs a home that has not been migrated yet,
    # and the cmdlet is idempotent by design, so it cannot be tested on the
    # machine the first scenarios finished with.
    for build in (lambda lab: (scenario_reads(lab), scenario_whatif(lab),
                               scenario_not_checked(lab), scenario_busy(lab),
                               scenario_unknown_account(lab), scenario_bad_copy(lab),
                               scenario_migrate(lab), scenario_idempotent(lab)),
                  scenario_remove_original):
        lab = Lab()
        try:
            lab.furnish()
            build(lab)
        finally:
            if os.environ.get("HOME_KEEP"):
                print(f"\n(kept: {lab.dir})")
            else:
                lab.clean()

    print()
    if FAILS:
        print(f"{len(FAILS)} check(s) FAILED")
        return 1
    print("all checks passed — the DECISIONS are right. A machine with real ZFS is")
    print("still the only thing that can say the migration works: BACKUP-PLAN B-6.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
