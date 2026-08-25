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

THE FAKE'S ONE LOAD-BEARING BEHAVIOUR is that `zfs clone` does NOT carry the
origin's local properties, and that `canmount` does not inherit — so a clone
created without `-o` comes out `canmount=on mountpoint=<inherited>`. That is
measured, on a real machine, and written down as BUILD-NOTES #63. A fake that
got this wrong would make the module look correct while it shipped the bug the
fake was written to model, which is the standing hazard with any mock and the
reason this one models exactly one thing.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODULE = os.path.join(REPO, "powershell", "OS7", "OS7.psd1")

# The layout New-OS7Storage creates, with the property SOURCES that matter:
# name: (canmount, mountpoint, canmount source, mountpoint source)
LAYOUT = {
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
open(LOG, "a").write("zfs " + " ".join(sys.argv[1:]) + "\n")
argv = sys.argv[1:]; sub = argv[0] if argv else ""
LAYOUT = json.load(open(os.environ["BE_LAYOUT"]))
try: CREATED = json.load(open(STATE))
except Exception: CREATED = {}
LAYOUT.update(CREATED)

def prop(v, s): return {"value": v, "source": {"type": s, "data": "-"}}
def dataset(n):
    cm, mp, cms, mps = LAYOUT[n]
    return {"name": n, "type": "SNAPSHOT" if "@" in n else "FILESYSTEM",
            "pool": n.split("/")[0], "createtxg": 1,
            "properties": {"used": prop(1024, "NONE"), "available": prop(1024, "NONE"),
                           "referenced": prop(1024, "NONE"), "mountpoint": prop(mp, mps),
                           "creation": prop(1787676263, "NONE"),
                           "compression": prop("lz4", "LOCAL"), "quota": prop(0, "DEFAULT"),
                           "origin": prop("-", "NONE"),
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
    json.dump(CREATED, open(STATE, "w"))
elif sub == "snapshot":
    full = names_after_flags(argv[1:])[-1]
    base, _, snap = full.partition("@")
    targets = [base] + ([k for k in LAYOUT if k.startswith(base + "/")] if "-r" in argv else [])
    for t in targets:
        if "@" in t: continue
        CREATED[t + "@" + snap] = list(LAYOUT[t])
    json.dump(CREATED, open(STATE, "w"))
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
    json.dump(CREATED, open(STATE, "w"))
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


def main():
    if not shutil.which("pwsh"):
        sys.exit("pwsh not found. This check runs the real module, so it needs "
                 "PowerShell 7 on the host: brew install --cask powershell")

    tmp = tempfile.mkdtemp(prefix="os7-be-")
    binp = os.path.join(tmp, "bin")
    os.makedirs(binp)
    log = os.path.join(tmp, "cmd.log")
    state = os.path.join(tmp, "state.json")
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
""")
    p = subprocess.run(["pwsh", "-NoProfile", "-File", script], env=env,
                       capture_output=True, text=True)

    issued = [l for l in open(log).read().splitlines()] if os.path.exists(log) else []
    clones = [l for l in issued if l.startswith("zfs clone")]

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
    text = open(frag).read() if os.path.exists(frag) else ""
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
