#!/usr/bin/env python3
"""
The boot-environment cmdlets' DECISIONS, checked in seconds and without a VM.

    ./check-be-logic.py

WHAT THIS IS AND IS NOT. It runs the real `powershell/OS7` module against a
`zfs` and a handful of GRUB tools that are fakes, and checks the commands the
module issues and the files it writes. So it is a test of **OS/7's layer** — which
properties it sets on a clone, in what order it does an activation, what it
writes to the ESP — and it is **not** a test of ZFS, of GRUB, or of a machine.
`run-s5.py` is the test of the machine and nothing here replaces it.

WHY IT EXISTS. Two bugs were found by a VM run that costs 25 minutes to reach
the point where they show, and both would have been found here in three seconds:

  * `$from = $props[...]` collided with the `-From` PARAMETER — PowerShell
    variable names are case-insensitive, the parameter is typed [string], so the
    hashtable was coerced to "System.Collections.Hashtable" and the next line
    indexed a string. BUILD-NOTES #65.
  * `(Get-ZfsProperty … -Property mountpoint).Value` trusts that exactly one
    object comes back; when two do, `.Value` is an array and every comparison
    against it is quietly false.

THE FAKE'S LOAD-BEARING BEHAVIOURS are TWO, and each is measured on a real
machine rather than assumed. Both are listed here because the standing hazard
with any mock is that it models the bug it was written to catch, and the way to
keep that visible is to say out loud what it pretends to know:

  1. `zfs clone` does NOT carry the origin's local properties, and `canmount`
     does not inherit — so a clone created without `-o` comes out
     `canmount=on mountpoint=<inherited>`. BUILD-NOTES #63.

  2. `zfs destroy` REFUSES a dataset whose snapshot has a live clone OUTSIDE
     the subtree being destroyed, with the message that names `-R`.
     BUILD-NOTES #183, measured 2026-09-21 on a machine that had updated
     1.0.0.245 -> 246 and rolled back:

         cannot destroy 'bpool/BOOT/os7_1.0.0.246_202609211744': filesystem
         has dependent clones use '-R' to destroy the following datasets:
         bpool/BOOT/os7_1.0.0.245_202609211528

     The direction is the whole point and it is easy to get backwards: a clone
     INSIDE the subtree does not block, because a clone can always be destroyed
     and it is the ORIGIN that is pinned. A fake that refused for both would
     make an implementation that promoted the wrong dataset look correct.

`zfs promote` is modelled beside them and is deliberately NOT complete: it
reverses the origin between the promoted dataset and its former origin, and
moves sibling clones of THAT EXACT snapshot, which is what BUILD-NOTES #107
measured. Real promote also moves every earlier snapshot, and this fake has no
ordering to move them by. The simplification is safe for what is under test —
"is the dependency gone" is answered by the origin, and the origin is modelled —
and it is written down here so that the next reader does not read more out of a
green run than is in it.

ON WINDOWS IT RE-RUNS ITSELF IN A CONTAINER — the same one check-home-logic.py
builds. The fakes are POSIX programs on PATH (the zfs is python3, the GRUB
tools are /bin/sh), and the grub.d script under test is EXECUTED by the fake
update-grub, so a host that cannot start an extensionless script cannot run
this check natively. Running it there anyway is what found BUILD-NOTES #121:
pwsh finds the fake, cannot start it, and reads a $LASTEXITCODE nothing set.
On macOS and Linux nothing changes: the check runs on the host, as it always
has.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# WHERE THE MODULE UNDER TEST IS. Normally the repository's, and under
# --self-test a COPY with one rule cut out of it — because a check that has
# never been seen to fail is a check nobody has measured. OS7_BE_MODULE names
# the copy's powershell/ directory; the Zfs layer is taken from beside it, which
# is what Import-OS7ZfsLayer does too.
PSROOT = os.environ.get("OS7_BE_MODULE") or os.path.join(REPO, "powershell")
MODULE = os.path.join(PSROOT, "OS7", "OS7.psd1")
ZFS_MODULE = os.path.join(PSROOT, "Zfs", "Zfs.psd1")

# The container is check-home-logic.py's, shared deliberately: it holds exactly
# the three interpreters the fakes need — the PINNED pwsh, python3 and sh — and
# a second Dockerfile with the same contents would be a second pin that rots.
IMAGE = "os7-check-home"

# The layout New-OS7Storage creates, with the property SOURCES that matter:
# name: (canmount, mountpoint, canmount source, mountpoint source)
LAYOUT = {
    # The pool roots and one ordinary dataset beside the boot environments.
    # Get-OS7CloneDependent walks the whole POOL — a clone of a boot
    # environment's snapshot is not obliged to live under ROOT/ — so a pool
    # that consisted only of boot environments would never prove that the walk
    # leaves innocent datasets alone.
    "rpool":                         ("off",    "none",          "LOCAL",   "LOCAL"),
    "rpool/DATA":                    ("off",    "none",          "LOCAL",   "LOCAL"),
    "bpool":                         ("off",    "none",          "LOCAL",   "LOCAL"),
    "rpool/ROOT":                    ("off",    "none",          "LOCAL",   "LOCAL"),
    "rpool/ROOT/os7_a":              ("noauto", "/",             "LOCAL",   "LOCAL"),
    "rpool/ROOT/os7_a/var":          ("off",    "/var",          "LOCAL",   "INHERITED"),
    "rpool/ROOT/os7_a/var/lib":      ("off",    "/var/lib",      "LOCAL",   "INHERITED"),
    "rpool/ROOT/os7_a/var/lib/dpkg": ("on",     "/var/lib/dpkg", "DEFAULT", "INHERITED"),
    "rpool/ROOT/os7_a/var/lib/apt":  ("on",     "/var/lib/apt",  "DEFAULT", "INHERITED"),
    "rpool/ROOT/os7_a/var/cache":    ("on",     "/var/cache",    "DEFAULT", "INHERITED"),
    "bpool/BOOT":                    ("off",    "none",          "LOCAL",   "LOCAL"),
    "bpool/BOOT/os7_a":              ("on",     "/boot",         "DEFAULT", "LOCAL"),
}

FAKE_ZFS = r'''#!/usr/bin/env python3
import json, os, sys
LOG = os.environ["BE_LOG"]; STATE = os.environ["BE_STATE"]
ORIGSTATE = os.environ["BE_ORIGINS"]
open(LOG, "a").write("zfs " + " ".join(sys.argv[1:]) + "\n")
argv = sys.argv[1:]; sub = argv[0] if argv else ""
LAYOUT = json.load(open(os.environ["BE_LAYOUT"]))
try: CREATED = json.load(open(STATE))
except Exception: CREATED = {}
try: ORIGINS = json.load(open(ORIGSTATE))
except Exception: ORIGINS = {}
LAYOUT.update(CREATED)
# A DESTROYED dataset is a null in the state file rather than a missing key:
# LAYOUT is reloaded from the layout file on every call, so a deletion that was
# only an absence from CREATED would come straight back.
for gone in [k for k, v in LAYOUT.items() if v is None]: del LAYOUT[gone]

def save():
    json.dump(CREATED, open(STATE, "w")); json.dump(ORIGINS, open(ORIGSTATE, "w"))
def inside(name, root): return name == root or name.startswith(root + "/")
def prop(v, s): return {"value": v, "source": {"type": s, "data": "-"}}
def dataset(n):
    cm, mp, cms, mps = LAYOUT[n]
    return {"name": n, "type": "SNAPSHOT" if "@" in n else "FILESYSTEM",
            "pool": n.split("/")[0], "createtxg": 1,
            "properties": {"used": prop(1024, "NONE"), "available": prop(1024, "NONE"),
                           "referenced": prop(1024, "NONE"), "mountpoint": prop(mp, mps),
                           "creation": prop(1787676263, "NONE"),
                           "compression": prop("lz4", "LOCAL"), "quota": prop(0, "DEFAULT"),
                           "origin": prop(ORIGINS.get(n, "-"), "NONE"),
                           "mounted": prop("yes" if n == os.environ.get("BE_ACTIVE") else "no",
                                           "NONE"),
                           "canmount": prop(cm, cms)}}
def emit(names, only=None):
    out = {}
    for n in names:
        d = dataset(n)
        if only: d["properties"] = {k: v for k, v in d["properties"].items() if k in only}
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
        if n not in LAYOUT:
            sys.stderr.write("cannot open '%s': dataset does not exist\n" % n); sys.exit(1)
        out.append(n)
        if recurse:
            # -d N LIMITS the depth. A fake that ignores it hands the caller
            # grandchildren where it asked for children, and the caller then
            # looks buggy for treating rpool/ROOT/<be>/var/lib/apt as a boot
            # environment.
            for k in LAYOUT:
                if not k.startswith(n + "/"): continue
                if depth is not None and k[len(n) + 1:].count("/") + 1 > depth: continue
                out.append(k)
    def wanted(n):
        snap = "@" in n
        return ("snapshot" in types or "all" in types) if snap else \
               ("filesystem" in types or "all" in types)
    emit(sorted({n for n in out if wanted(n)}))
elif sub == "get":
    rest = names_after_flags(argv[1:], valued=("-o",))
    props, names = (rest[0].split(",") if rest else ["all"]), rest[1:]
    for n in names:
        if n not in LAYOUT:
            sys.stderr.write("cannot open '%s': dataset does not exist\n" % n); sys.exit(1)
    emit(names, only=None if "all" in props else props)
elif sub == "set":
    pairs = [a for a in argv[1:] if "=" in a]
    for n in [a for a in argv[1:] if "=" not in a]:
        cm, mp, cms, mps = LAYOUT[n]
        for p in pairs:
            k, _, v = p.partition("=")
            if k == "canmount": cm, cms = v, "LOCAL"
            elif k == "mountpoint": mp, mps = v, "LOCAL"
        CREATED[n] = [cm, mp, cms, mps]
    save()
elif sub == "snapshot":
    full = names_after_flags(argv[1:])[-1]
    base, _, snap = full.partition("@")
    targets = [base] + ([k for k in LAYOUT if k.startswith(base + "/")] if "-r" in argv else [])
    for t in targets:
        if "@" in t: continue
        CREATED[t + "@" + snap] = list(LAYOUT[t])
    save()
elif sub == "clone":
    props, it = {}, iter(argv[1:])
    for a in it:
        if a == "-o":
            k, _, v = next(it).partition("="); props[k] = v
    args = names_after_flags(argv[1:])
    src, dst = args[-2], args[-1]
    # THE BEHAVIOUR THIS FAKE EXISTS FOR (BUILD-NOTES #63): local properties are
    # NOT carried; canmount takes its default; mountpoint inherits from the new
    # parent. Only -o overrides that.
    parent = dst.rsplit("/", 1)[0]
    CREATED[dst] = [props.get("canmount", "on"),
                    props.get("mountpoint", LAYOUT.get(parent, ["", "none"])[1]),
                    "LOCAL" if "canmount" in props else "DEFAULT",
                    "LOCAL" if "mountpoint" in props else "INHERITED"]
    ORIGINS[dst] = src
    save()
elif sub == "promote":
    n = names_after_flags(argv[1:])[-1]
    o = ORIGINS.get(n)
    if not o:
        sys.stderr.write("cannot promote '%s': not a cloned filesystem\n" % n); sys.exit(1)
    # A PROMOTE THAT REPORTS SUCCESS AND CHANGES NOTHING. Not a hypothetical:
    # "a program reported success and the thing it was meant to change did not
    # change" is the shape of the expensive bugs in this repository, and the
    # refusal at the end of Remove-OS7BootEnvironment exists for exactly it.
    # Without this switch that refusal is unreachable, and an unreachable rule
    # is one nobody has ever seen work.
    if os.environ.get("BE_PROMOTE_NOOP"): sys.exit(0)
    src, _, snap = o.partition("@")
    # BUILD-NOTES #107, measured: after a promote the promoted dataset's origin
    # is '-', the FORMER ORIGIN points at the promoted one, and sibling clones
    # of the same snapshot follow it rather than staying behind. The header says
    # what this leaves out.
    for other, oo in list(ORIGINS.items()):
        if other != n and oo == o: ORIGINS[other] = n + "@" + snap
    del ORIGINS[n]
    ORIGINS[src] = n + "@" + snap
    # AND THE SNAPSHOT MOVES WITH IT, which is the half a pointer swap leaves
    # out and the half that decides whether a destroy is refused. `zfs promote`
    # TRANSFERS the shared history to the promoted dataset — that is why the
    # original becomes destroyable at all. The first version of this fake moved
    # only the origin string, and the planted-defect run then DESTROYED an
    # environment a machine refuses to destroy: the check was green against the
    # defect it was written for. Promote is per-dataset and not recursive, so
    # children keep their own origins, which is what produces the mixed topology
    # a rolled-back machine really has.
    if o in LAYOUT:
        CREATED[n + "@" + snap] = list(LAYOUT[o])
        CREATED[o] = None
    save()
elif sub == "destroy":
    n = names_after_flags(argv[1:])[-1]
    if n not in LAYOUT:
        sys.stderr.write("cannot open '%s': dataset does not exist\n" % n); sys.exit(1)
    doomed = [k for k in LAYOUT if inside(k.partition("@")[0], n)] if "-r" in argv else [n]
    # THE SECOND LOAD-BEARING BEHAVIOUR (BUILD-NOTES #183). A snapshot being
    # destroyed whose clone lives OUTSIDE the subtree is what ZFS refuses for,
    # and the message it prints is what an operator saw. A clone INSIDE is not a
    # problem and must not be treated as one.
    snaps = {k for k in doomed if "@" in k}
    blocked = sorted({c for c, o in ORIGINS.items()
                      if o in snaps and not inside(c, n)})
    if blocked:
        sys.stderr.write("cannot destroy '%s': filesystem has dependent clones\n"
                         "use '-R' to destroy the following datasets:\n%s\n"
                         % (n, "\n".join(blocked)))
        sys.exit(1)
    for k in doomed:
        CREATED[k] = None
        ORIGINS.pop(k, None)
    save()
else:
    sys.stderr.write("fake zfs: unhandled subcommand " + sub + "\n"); sys.exit(2)
'''

FAKE_TOOL = '''#!/bin/sh
echo "$(basename "$0") $*" >> "$BE_LOG"
exit 0
'''

# `update-grub` is not a no-op here: the guard in Set-OS7BootEnvironment reads
# the regenerated menu, so a fake that changed nothing would make the guard fire
# for a reason that has nothing to do with the code. This models the one
# behaviour under test — grub.cfg is the grub.d scripts, concatenated.
FAKE_UPDATE_GRUB = '''#!/bin/sh
echo "update-grub $*" >> "$BE_LOG"
{
    cat "$BE_STOCK_MENU"
    [ -x "$BE_GRUBD/09_os7-boot-environments" ] && "$BE_GRUBD/09_os7-boot-environments"
} > "$BE_GRUBCFG".new
mv "$BE_GRUBCFG".new "$BE_GRUBCFG"
exit 0
'''


def pin(name):
    """A value out of build/config/os7-release.conf — the one place a version
    may live. Passed into the container build so its PowerShell is the image's
    PowerShell rather than a second pin that rots quietly."""
    conf = os.path.join(REPO, "build", "config", "os7-release.conf")
    for line in open(conf):
        if line.startswith(name + "="):
            return line.split("=", 1)[1].strip().strip('"')
    sys.exit(f"{name} is not in {conf}")


# THE DEFECTS --self-test PLANTS, one per rule added for BUILD-NOTES #183.
# Each is a CUT between two markers in OS7.psm1 — the shape the rule had before
# it existed — and each names the checks it must turn red. A cut whose markers
# are no longer in the file is a failure of the self-test and not a pass: it
# means the rule moved and this plant stopped planting anything.
DEFECTS = [
    ("Remove-OS7BootEnvironment does not promote what depends on the environment",
     "\t\t# A PASS AT A TIME, AND RE-ASKED",
     "\t\tforeach ($ds in $halves) {",
     ["Remove-OS7BootEnvironment promoted BOTH halves",
      "and then removed the environment the machine rolled back FROM"]),
    ("Remove-OS7BootEnvironment lets `zfs destroy` do the refusing",
     "\t\t# AND IF IT DID NOT WORK, A SENTENCE",
     "\t\tforeach ($ds in $halves) {",
     ["and it names the command that fixes it, with the parameter",
      "and it says why -R is not the answer"]),
    ("Restore-OS7 does not promote what it rolls back to",
     "\t# AND THE ENVIRONMENT THIS MACHINE WILL RUN OWNS ITS OWN HISTORY",
     # NOT `$running = $all | Where-Object` alone, which is in
     # Set-OS7BootEnvironment as well: the marker carries the LINE AFTER it to
     # be this function's, and keeps the `$running =` assignment INSIDE what
     # survives — a cut that took it away would turn the check red because
     # $running was undefined, which is a broken plant and not a caught defect.
     "\t$running = $all | Where-Object { Test-OS7IsRunning $_ } | Select-Object -First 1\n"
     '\tWrite-OS7Step ("reboot to finish: this machine still runs "',
     ["Restore-OS7 promoted both halves of what it rolled back to"]),
]


def plant(where, opening, closing):
    """Copy powershell/ and cut one rule out of OS7.psm1. Returns the copy."""
    shutil.copytree(os.path.join(REPO, "powershell"), where)
    path = os.path.join(where, "OS7", "OS7.psm1")
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if text.count(opening) != 1 or text.count(closing) != 1:
        sys.exit(f"self-test: cannot plant — {opening.strip()!r} appears "
                 f"{text.count(opening)} time(s) and {closing.strip()!r} "
                 f"{text.count(closing)} time(s) in OS7.psm1. The rule moved; "
                 "fix the markers in DEFECTS rather than deleting this check.")
    head, _, rest = text.partition(opening)
    _, _, tail = rest.partition(closing)
    with open(path, "w", encoding="utf-8") as f:
        f.write(head + closing + tail)
    return where


def self_test():
    """Run this check against a module with each rule removed in turn, and
    require it to go RED — with the right checks red, not merely some."""
    fails = []
    for name, opening, closing, must_fail in DEFECTS:
        print(f"\n### planted: {name}\n")
        tmp = tempfile.mkdtemp(prefix="os7-be-plant-")
        try:
            where = plant(os.path.join(tmp, "powershell"), opening, closing)
            env = dict(os.environ)
            env["OS7_BE_MODULE"] = where
            env.pop("BE_KEEP", None)
            p = subprocess.run([sys.executable, os.path.abspath(__file__)],
                               env=env, capture_output=True, text=True)
            red = [l for l in p.stdout.splitlines() if l.strip().startswith("FAIL")]
            for wanted in must_fail:
                hit = any(wanted in l for l in red)
                print(f"  {'ok  ' if hit else 'FAIL'}  it is caught by: {wanted}")
                if not hit:
                    fails.append(f"{name}: {wanted}")
            if p.returncode == 0:
                print("  FAIL  and the run as a whole reported success")
                fails.append(f"{name}: exit 0")
            else:
                print("  ok    and the run as a whole FAILED")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    print()
    if fails:
        print(f"{len(fails)} planted defect(s) were NOT caught")
        return 1
    print("every planted defect was caught — the new rules fire")
    return 0


def relaunch():
    """Build the shared check container and run this file inside it."""
    if not shutil.which("docker"):
        sys.exit("docker is needed on Windows: the fakes are POSIX scripts. "
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
    # No --privileged and no unshare: unlike check-home-logic.py, nothing here
    # mounts anything — the fakes only write files.
    # ARGUMENTS ARE FORWARDED, and --self-test needs them to be: it copies the
    # module and cuts a rule out of the copy, which cannot happen on /repo (it
    # is mounted read-only, on purpose) and must therefore happen INSIDE the
    # container, in its own /tmp.
    return subprocess.run(
        ["docker", "run", "--rm",
         "-v", f"{REPO}:/repo:ro", IMAGE,
         "python3", "/repo/installer/testing/check-be-logic.py"] + sys.argv[1:]).returncode


def main():
    # The fakes are POSIX programs and the grub.d script under test is
    # EXECUTED — a Windows host cannot start either, so there the check runs
    # itself inside the container instead (header). Inside, os.name is
    # 'posix', so this cannot recurse.
    if os.name == "nt":
        sys.exit(relaunch())

    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())

    if not shutil.which("pwsh"):
        sys.exit("pwsh not found. This check runs the real module, so it needs "
                 "PowerShell 7 on the host: brew install --cask powershell")

    tmp = tempfile.mkdtemp(prefix="os7-be-")
    binp = os.path.join(tmp, "bin")
    os.makedirs(binp)
    log = os.path.join(tmp, "cmd.log")
    state = os.path.join(tmp, "state.json")
    origins = os.path.join(tmp, "origins.json")
    layout = os.path.join(tmp, "layout.json")
    json.dump({k: list(v) for k, v in LAYOUT.items()}, open(layout, "w"))

    with open(os.path.join(binp, "zfs"), "w") as f:
        f.write(FAKE_ZFS)
    os.chmod(os.path.join(binp, "zfs"), 0o755)
    # NOT chmod: the module makes the grub.d script executable and the fake
    # update-grub honours [ -x ], so stubbing chmod made the fragment invisible
    # for a reason that has nothing to do with the code under test.
    for t in ("grub-editenv", "mount", "umount"):
        with open(os.path.join(binp, t), "w") as f:
            f.write(FAKE_TOOL)
        os.chmod(os.path.join(binp, t), 0o755)
    with open(os.path.join(binp, "update-grub"), "w") as f:
        f.write(FAKE_UPDATE_GRUB)
    os.chmod(os.path.join(binp, "update-grub"), 0o755)

    env = dict(os.environ)
    env["PATH"] = binp + os.pathsep + env["PATH"]
    env["BE_LOG"] = log
    env["BE_STATE"] = state
    env["BE_ORIGINS"] = origins
    env["BE_LAYOUT"] = layout
    # Which environment is mounted at /. Get-OS7BootEnvironment reads `mounted`,
    # and an activation with nothing running has no template to build from.
    env["BE_ACTIVE"] = "rpool/ROOT/os7_a"

    # A machine's worth of files, so the activation path can run too. Every
    # absolute path the module uses is a $script: variable, which is what makes
    # this possible without touching the host.
    root = os.path.join(tmp, "root")
    for d in ("boot/grub", "boot/efi/EFI/BOOT", "boot/efi/EFI/OS7", "etc/grub.d",
              "etc/os7", "etc/default", "run/os7-be"):
        os.makedirs(os.path.join(root, d), exist_ok=True)
    # The kernel files an environment's /boot holds. `mount` is a no-op fake, so
    # the scratch directory is pre-populated: the module reads what a mount would
    # have put there.
    for d in ("boot", "run/os7-be"):
        for n in ("vmlinuz-7.0.0-30-generic", "initrd.img-7.0.0-30-generic"):
            open(os.path.join(root, d, n), "w").close()
    # A grub.cfg with the shape 10_linux_zfs really emits, taken from a measured
    # one (docs/SESSION-BOOT-ENVIRONMENTS.md §2). Kept aside as well, because the
    # fake update-grub rebuilds grub.cfg out of it plus the grub.d scripts.
    stock = os.path.join(tmp, "stock-menu.cfg")
    for path in (os.path.join(root, "boot/grub/grub.cfg"), stock):
      with open(path, "w") as f:
        f.write(
            "### BEGIN /etc/grub.d/10_linux_zfs ###\n"
            "menuentry 'OS/7 1.0.0.95' --class os_7 --class gnu-linux --class gnu --class os "
            "$menuentry_id_option 'gnulinux-rpool/ROOT/os7_a-7.0.0-30-generic' {\n"
            "\trecordfail\n"
            "\tinsmod zfs\n"
            "\tsearch --no-floppy --fs-uuid --set=root b27d79ae3ab198f8\n"
            '\tlinux\t"/BOOT/os7_a@/vmlinuz-7.0.0-30-generic" '
            'root=ZFS="rpool/ROOT/os7_a" ro boot=zfs\n'
            '\tinitrd\t"/BOOT/os7_a@/initrd.img-7.0.0-30-generic"\n'
            "}\n"
            "### END /etc/grub.d/10_linux_zfs ###\n")
    with open(os.path.join(root, "etc/default/grub"), "w") as f:
        f.write("GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\n")
    for stub in ("boot/efi/EFI/BOOT/grub.cfg", "boot/efi/EFI/OS7/grub.cfg"):
        with open(os.path.join(root, stub), "w") as f:
            f.write("search.fs_uuid b27d79ae3ab198f8 root\n"
                    "set prefix=($root)'/BOOT/os7_a@/grub'\n"
                    "configfile $prefix/grub.cfg\n")
    os.makedirs(os.path.join(root, "run/os7-be/grub"), exist_ok=True)
    open(os.path.join(root, "run/os7-be/grub/grubenv"), "w").close()

    env["BE_GRUBCFG"] = os.path.join(root, "boot/grub/grub.cfg")
    env["BE_GRUBD"] = os.path.join(root, "etc/grub.d")
    env["BE_STOCK_MENU"] = stock

    script = os.path.join(tmp, "drive.ps1")
    with open(script, "w") as f:
        f.write(f"""
$ErrorActionPreference = 'Stop'
# The Zfs layer by hand as well: Import-OS7ZfsLayer imports it into the OS7
# module's own session state, so Convert-ZfsClone and Get-ZfsDataset — which
# this script types directly, to model UL9 and to read origins back — would not
# resolve here without it.
Import-Module '{ZFS_MODULE}' -Force
Import-Module '{MODULE}' -Force
$m = Get-Module OS7
# Point every absolute path at the temporary machine.
& $m {{
    $script:OS7GrubCfg    = '{root}/boot/grub/grub.cfg'
    $script:OS7MenuFile   = '{root}/etc/os7/grub-boot-environments.cfg'
    $script:OS7MenuScript = '{root}/etc/grub.d/09_os7-boot-environments'
    $script:OS7BootDir    = '{root}/boot'
    $script:OS7GrubDefaults = '{root}/etc/default/grub'
    $script:OS7BeScratch  = '{root}/run/os7-be'
    $script:OS7EspStubs   = @('{root}/boot/efi/EFI/BOOT/grub.cfg',
                              '{root}/boot/efi/EFI/OS7/grub.cfg')
}}
$be = New-OS7BootEnvironment -Name os7_b -From os7_a -Confirm:$false
'RESULT ' + $be.Name + ' complete=' + $be.Complete
try {{
    Set-OS7BootEnvironment -Name os7_b -Confirm:$false | Out-Null
    'ACTIVATED'
}} catch {{
    'ACTIVATE-FAILED ' + $_.Exception.Message
}}
# AND BACK. The second activation is a different problem from the first: the
# running environment is now one OS/7 created, so the stock generator has no
# entry for it and the template lookup has to find OS/7's own. A check that
# activated once would have passed while a rollback could not run at all.
$env:BE_ACTIVE = 'rpool/ROOT/os7_b'   # the fake zfs reads this
try {{
    Set-OS7BootEnvironment -Name os7_a -Confirm:$false | Out-Null
    'ROLLED-BACK'
}} catch {{
    'ROLLBACK-FAILED ' + $_.Exception.Message
}}

# THE MENU AS IT STOOD AFTER THE ROLLBACK, kept aside. Everything below adds a
# THIRD environment and takes one away again, and the assertions about the
# fragment are about the two-environment machine they were written for — a check
# that read the final file instead would be a different check wearing the same
# words.
Copy-Item '{root}/etc/os7/grub-boot-environments.cfg' `
          '{root}/etc/os7/act2-fragment.cfg' -Force

# ---- BUILD-NOTES #183 -----------------------------------------------------
# UL9: Update-OS7 PROMOTES the environment it activates, and without that
# nothing can ever be removed. This check does not run the update train, so the
# step is issued here with the same cmdlet Update-OS7 calls — after which the
# machine is in the state that was MEASURED on 2026-09-21: the older
# environment, the one the rollback above went back to, is now the CLONE.
# EVERY COMMAND IS ATTRIBUTED TO THE ACT THAT ISSUED IT, and that is not
# bookkeeping: the first version of the check below asserted that
# `zfs promote rpool/ROOT/os7_a` appears in the log, and it appeared — issued by
# Restore-OS7, four acts later, on a module whose Remove-OS7BootEnvironment had
# the rule cut out of it. The check was green against the planted defect. A
# marker in the same file the fakes append to is what makes "who did this" a
# fact rather than an assumption.
function Mark([string]$name) {{ Add-Content -LiteralPath $env:BE_LOG -Value "--- $name" }}

Mark 'ul9'
foreach ($half in @('rpool/ROOT/os7_b', 'bpool/BOOT/os7_b')) {{
    Convert-ZfsClone -Name $half -Confirm:$false | Out-Null
}}
'INVERTED root=' + (Get-ZfsDataset -Name rpool/ROOT/os7_a).Origin +
    ' boot=' + (Get-ZfsDataset -Name bpool/BOOT/os7_a).Origin

# The reboot that finishes a rollback.
$env:BE_ACTIVE = 'rpool/ROOT/os7_a'
# AND THE REMOVAL THAT COULD NOT RUN. This is the machine an operator has after
# rolling back with a module from before this rule: the environment they most
# want gone is the one ZFS refuses to destroy.
Mark 'remove'
try {{
    Remove-OS7BootEnvironment -Name os7_b -Confirm:$false | Out-Null
    'REMOVED'
}} catch {{
    'REMOVE-FAILED ' + $_.Exception.Message
}}
'LEFT ' + ((Get-OS7BootEnvironment).Name -join ',')

# ---- and the rule that stops the state arising again ----------------------
# Restore-OS7 promotes what it rolls back to, symmetric to UL9. Driven through
# the verb an operator actually types, because the promote is the LAST thing it
# does and a check that called the helper directly would not notice it moving.
Mark 'stage-c'
$made = New-OS7BootEnvironment -Name os7_c -From os7_a -Confirm:$false
foreach ($half in @('rpool/ROOT/os7_c', 'bpool/BOOT/os7_c')) {{
    Convert-ZfsClone -Name $half -Confirm:$false | Out-Null   # UL9 again
}}
Set-OS7BootEnvironment -Name os7_c -Confirm:$false | Out-Null
$env:BE_ACTIVE = 'rpool/ROOT/os7_c'
Mark 'restore'
try {{
    Restore-OS7 -BootEnvironment os7_a -Confirm:$false | Out-Null
    'RESTORED root=' + ((Get-ZfsDataset -Name rpool/ROOT/os7_a).Origin ?? '-') +
        ' boot=' + ((Get-ZfsDataset -Name bpool/BOOT/os7_a).Origin ?? '-')
}} catch {{
    'RESTORE-FAILED ' + $_.Exception.Message
}}

# ---- and what it says when promoting DID NOT HELP -------------------------
# The belt on the belt, and it has to be reachable or it is a rule nobody has
# watched work. UL9 again, so that os7_a depends on os7_c; then a `zfs promote`
# that exits 0 and changes nothing, which is this repository's recurring failure
# shape. What must come back is a SENTENCE naming Convert-ZfsClone — not the
# .NET exception `zfs destroy` would raise, which is #148's shape.
Mark 'stage-refuse'
$env:BE_ACTIVE = 'rpool/ROOT/os7_a'   # the reboot that finishes the rollback
foreach ($half in @('rpool/ROOT/os7_c', 'bpool/BOOT/os7_c')) {{
    Convert-ZfsClone -Name $half -Confirm:$false | Out-Null
}}
$env:BE_PROMOTE_NOOP = '1'
Mark 'refuse'
try {{
    Remove-OS7BootEnvironment -Name os7_c -Confirm:$false | Out-Null
    'NOT-REFUSED'
}} catch {{
    'REFUSED ' + ($_.Exception.Message -replace "`n", ' ')
}}
""")
    p = subprocess.run(["pwsh", "-NoProfile", "-File", script], env=env,
                       capture_output=True, text=True)

    issued = [l for l in open(log).read().splitlines()] if os.path.exists(log) else []
    # SCOPED TO THE ENVIRONMENT UNDER TEST. The #183 sections below build a
    # third one, so a bare "every zfs clone ever issued" would count fourteen
    # where the rule is about seven — and the rule would then have to be
    # loosened to stay green, which is how a check stops meaning anything.
    clones = [l for l in issued
              if l.startswith("zfs clone") and "/os7_b" in l.rsplit(" ", 1)[-1]]

    fails = []

    def check(ok, what, detail=""):
        print(f"  {'ok  ' if ok else 'FAIL'}  {what}" + (f" — {detail}" if detail else ""))
        if not ok:
            fails.append(what)

    print("\n### the boot-environment cmdlets, against a fake zfs\n")
    check("RESULT os7_b complete=True" in p.stdout,
          "New-OS7BootEnvironment completes",
          (p.stdout + p.stderr).strip().splitlines()[-1] if (p.stdout + p.stderr).strip() else "")

    # Seven datasets: six in rpool, one in bpool. Not "some".
    check(len(clones) == 7, "seven datasets cloned — the pair and its children",
          f"{len(clones)}")

    want = {
        "rpool/ROOT/os7_b":              ["mountpoint=/", "canmount=noauto"],
        "rpool/ROOT/os7_b/var":          ["canmount=off"],
        "rpool/ROOT/os7_b/var/lib":      ["canmount=off"],
        "rpool/ROOT/os7_b/var/lib/dpkg": ["canmount=noauto"],
        "rpool/ROOT/os7_b/var/lib/apt":  ["canmount=noauto"],
        "rpool/ROOT/os7_b/var/cache":    ["canmount=noauto"],
        "bpool/BOOT/os7_b":              ["mountpoint=/boot", "canmount=noauto"],
    }
    for target, opts in want.items():
        line = next((c for c in clones if c.endswith(" " + target)), None)
        if not line:
            check(False, f"{target} was cloned")
            continue
        got = [o for o in line.split() if "=" in o]
        check(got == opts, f"{target}", " ".join(got) or "no -o at all")

    # THE RULE THE WHOLE THING EXISTS FOR.
    check(not any("canmount=on" in c for c in clones),
          "no dataset is created canmount=on (it would mount over the running root)")

    # ---- and the activation ------------------------------------------------
    print()
    check("ACTIVATED" in p.stdout, "Set-OS7BootEnvironment completes",
          next((l for l in p.stdout.splitlines() if l.startswith("ACTIVATE-FAILED")), ""))

    frag = os.path.join(root, "etc/os7/grub-boot-environments.cfg")
    act2 = os.path.join(root, "etc/os7/act2-fragment.cfg")
    text = open(act2).read() if os.path.exists(act2) else ""
    # ONE ENTRY PER ENVIRONMENT, which the stock generator cannot produce at all
    # on a machine without zsys — BUILD-NOTES #67.
    check(text.count("menuentry ") == 2,
          "the fragment carries one entry per boot environment",
          f"{text.count('menuentry ')}")
    check("os7-be-os7_b" in text and "os7-be-os7_a" in text,
          "both environments have an id of their own")
    check('root=ZFS="rpool/ROOT/os7_b"' in text,
          "the new entry names the new root dataset")
    check("/BOOT/os7_b@/vmlinuz-7.0.0-30-generic" in text,
          "the new entry loads the kernel from the new boot dataset")
    check('root=ZFS="rpool/ROOT/os7_a"' in text,
          "the OLD environment is still in the menu — the recovery path")
    # The template's own hard parts must survive the substitution.
    check(text.count("search --no-floppy --fs-uuid --set=root b27d79ae3ab198f8") == 2,
          "each entry keeps the template's search line")

    stub = open(os.path.join(root, "boot/efi/EFI/BOOT/grub.cfg")).read()
    check("/BOOT/os7_a@/grub" in stub,
          "the ESP stub was repointed again by the ROLLBACK",
          stub.strip().splitlines()[1] if len(stub.splitlines()) > 1 else stub)
    check("ROLLED-BACK" in p.stdout, "the second activation — the rollback — completes",
          next((l for l in p.stdout.splitlines() if l.startswith("ROLLBACK-FAILED")), ""))
    defaults = open(os.path.join(root, "etc/default/grub")).read()
    check("GRUB_DEFAULT=saved" in defaults,
          "GRUB_DEFAULT was repaired to `saved`, or saved_entry would be read by nothing")
    script_txt = open(os.path.join(root, "etc/grub.d/09_os7-boot-environments")).read() \
        if os.path.exists(os.path.join(root, "etc/grub.d/09_os7-boot-environments")) else ""
    check(script_txt.strip().endswith(frag), "the grub.d script emits the fragment")
    # AND the one that made the clone invisible to GRUB: without an explicit
    # mountpoint the clone inherits `none` from rpool/ROOT, and 10_linux_zfs
    # finds boot environments by looking for `/`.
    root_line = next((c for c in clones if c.endswith(" rpool/ROOT/os7_b")), "")
    check("-o mountpoint=/ " in root_line,
          "the boot environment's own mountpoint is set to / explicitly")

    # ---- and the clone topology a rollback leaves behind (#183) -------------
    print()
    inverted = next((l for l in p.stdout.splitlines() if l.startswith("INVERTED ")), "")
    # THE PRECONDITION, ASSERTED. Everything below is about a machine whose
    # RUNNING environment is a clone of the one above it, and if the fake ever
    # stopped producing that state the four checks after this would pass while
    # measuring nothing at all.
    check("root=rpool/ROOT/os7_b@" in inverted and "boot=bpool/BOOT/os7_b@" in inverted,
          "after UL9's promote the OLDER environment is the clone — the state a "
          "rollback leaves", inverted or "no INVERTED line")

    # WHAT THE CMDLET ITSELF ISSUED, and nothing the drive script issued around
    # it. See the Mark function in the drive script for why this is not
    # bookkeeping.
    acts, current = {}, "setup"
    for line in issued:
        if line.startswith("--- "):
            current = line[4:].strip()
        else:
            acts.setdefault(current, []).append(line)

    def promoted_in(act):
        return [l for l in acts.get(act, []) if l.startswith("zfs promote")]

    promotes = promoted_in("remove")
    check("zfs promote bpool/BOOT/os7_a" in promotes and
          "zfs promote rpool/ROOT/os7_a" in promotes,
          "Remove-OS7BootEnvironment promoted BOTH halves of the dependent — a "
          "half-promoted pair is the state nothing can read",
          " / ".join(promotes) or "no promote at all")
    check("REMOVED" in p.stdout,
          "and then removed the environment the machine rolled back FROM",
          next((l for l in p.stdout.splitlines() if l.startswith("REMOVE-FAILED")), ""))
    left = next((l for l in p.stdout.splitlines() if l.startswith("LEFT ")), "")
    check(left.strip() == "LEFT os7_a", "one environment is left, and it is the running one",
          left or "no LEFT line")
    # THE DIRECTION. rpool/ROOT/os7_b/var is a clone of os7_a's — INSIDE the
    # subtree being destroyed — and a clone can always be destroyed: it is the
    # ORIGIN that is pinned. An implementation that promoted by "is it a clone"
    # rather than "is something outside depending on this" would have promoted
    # os7_a/var here, and nothing else in this file would have noticed.
    check(not any(l.startswith("zfs promote rpool/ROOT/os7_a/") for l in promotes),
          "nothing INSIDE the doomed subtree was promoted — only what depends on "
          "it from outside",
          " / ".join(l for l in promotes if "/os7_a/" in l))

    # ---- Restore-OS7 promotes what it rolls back to, so it stops arising ----
    restored = next((l for l in p.stdout.splitlines()
                     if l.startswith("RESTORED ") or l.startswith("RESTORE-FAILED")), "")
    if "must run as root" in restored:
        # The module's own refusal, not a defect. On the Windows host this file
        # runs inside a container as root and this branch is never taken; on a
        # Linux host it is, and saying so is better than a check that quietly
        # was not made.
        print("  ....  Restore-OS7's promote NOT CHECKED — this process is not root, "
              "and the cmdlet refuses (#148). Run it on Windows (container) or as root.")
    else:
        check(restored.strip() == "RESTORED root=- boot=-",
              "Restore-OS7 promoted both halves of what it rolled back to — the "
              "running environment owns its own history",
              restored or "no RESTORED line")
        check(sorted(promoted_in("restore")) ==
              ["zfs promote bpool/BOOT/os7_a", "zfs promote rpool/ROOT/os7_a"],
              "and it promoted each half exactly once, and nothing else",
              " / ".join(promoted_in("restore")) or "no promote at all")

    # ---- and what it says when the promote did NOT help --------------------
    print()
    refused = next((l for l in p.stdout.splitlines()
                    if l.startswith("REFUSED ") or l == "NOT-REFUSED"), "")
    check(refused.startswith("REFUSED "),
          "a promote that exits 0 and changes nothing does NOT end in a destroy",
          refused or "no REFUSED line")
    # #148's lesson, in a second place: what comes back must be the sentence,
    # not `zfs destroy` reported through .NET. Three clauses, each asserted on
    # its own, because "the message mentions it somewhere" is how a message
    # degrades one edit at a time.
    check("Convert-ZfsClone -Name" in refused,
          "and it names the command that fixes it, with the parameter")
    check("rpool/ROOT/os7_a" in refused or "bpool/BOOT/os7_a" in refused,
          "and it names the dataset that is in the way")
    check("-R" in refused and "what this machine is running" in refused,
          "and it says why -R is not the answer")
    check(len(promoted_in("refuse")) >= 2,
          "and it tried before it refused",
          str(len(promoted_in("refuse"))))

    if os.environ.get("BE_KEEP"):
        print(f"\n(kept: {tmp})")
    else:
        shutil.rmtree(tmp, ignore_errors=True)
    print()
    if fails:
        print(f"{len(fails)} check(s) FAILED")
        sys.exit(1)
    print("all checks passed — the module's DECISIONS are right; run-s5.py decides the machine")


if __name__ == "__main__":
    main()
