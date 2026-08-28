#!/usr/bin/env python3
"""
The ZFS layer, checked against real ZFS — docs/ZFS-POWERSHELL-PLAN.md Z-2.

    ./run-zfs.py capture    build a small ZFS world in a VM and bring its
                            output home as test fixtures
    ./run-zfs.py test       run the module's own self-test against real ZFS
    ./run-zfs.py all        both, in one boot                    (default)
    ./run-zfs.py reset      throw the VM state away

WHY A VM AT ALL, when check-image.py can read the shipped image in seconds:
**the chroot has no ZFS kernel module.** Every `zfs` invocation there fails with
"The ZFS modules cannot be auto-loaded" before it parses its own options — so a
probe asking "is -j supported" scored a bogus option AND a bogus subcommand as
supported, ten times out of ten (ZFS-POWERSHELL-PLAN §12, M-Z1). A test of a ZFS
parser that runs where ZFS does not is a test of argument strings.

Nothing here touches a physical disk. The pools are files in the live session's
writable overlay, which is what makes this cheap enough to run often.
"""
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, run, to_plain_bash
from vmarch import VmArch

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TESTING = os.path.join(REPO, "installer", "testing")
MODULE = os.path.join(REPO, "powershell", "Zfs")
FIXTURES = os.path.join(MODULE, "tests", "fixtures")
VM = os.path.join(REPO, ".vm", "zfs")
ARCH = VmArch()
ISO = ARCH.iso_default()
VARS = os.path.join(VM, "edk2-vars.fd")
PAYLOAD = os.path.join(VM, "payload.iso")
ARCH.mount(VM, "/vm")
ARCH.mount(os.path.dirname(ISO), "/iso", ro=True)

MEM = "4096"
CPUS = "4"

# The live session is an overlay in RAM, so the vdev files are charged against
# MEM. Four 256 MB files is 1 GB — comfortably inside 4 GB, and ZFS's minimum
# vdev is 64 MB, so there is no reason to be more generous.
LABEL = "OS7ZFS"


def qemu_args():
    p = ARCH.path
    return ARCH.base_args() + [
        "-smp", CPUS, "-m", MEM,
    ] + ARCH.firmware_args(VARS) + [
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=payload,file={p(PAYLOAD)},format=raw,readonly=on",
        "-device", "virtio-blk-pci,drive=payload",
        "-cdrom", p(ISO), "-boot", "d",
    ]


def build_payload(what):
    """A tiny ISO carrying whatever this run needs to execute in the guest.

    `what` is 'capture', 'test' or 'both'. The module is staged from its ONE
    source (powershell/Zfs) exactly as build.sh stages OS7 — a copy here that
    drifted from the built one would test something that never ships.
    """
    stage = os.path.join(VM, "payload")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)

    shutil.copy(os.path.join(TESTING, "zfs-fixtures.sh"), stage)

    # THE MODULE TRAVELS AS A TAR, NOT AS A DIRECTORY. Measured the hard way:
    # `hdiutil makehybrid -iso -joliet` writes no Rock Ridge, and Linux mounts
    # the result `nojoliet`, so every name arrives LOWERCASED. `Zfs/Zfs.psd1`
    # became `zfs/zfs.psd1`, `[ -f /mnt/Zfs/Zfs.psd1 ]` was false, and the
    # payload script reported a tidy "no module staged yet" skip for a module
    # that was right there. One whole VM cycle.
    #
    # Every previous payload (run-s3, run-s4) carried only lowercase names at
    # the top level, which is why this had never surfaced.
    #
    # A tar carries its own names, so the ISO's filename rules stop mattering
    # at all — the class of bug goes away rather than this instance of it.
    #
    # WITH the fixtures: they are ~20 KB, and carrying them means one boot
    # exercises BOTH halves of Z10 — the parsers against recorded output and
    # the cmdlets against real ZFS.
    if os.path.isdir(MODULE):
        run("tar", "-cf", os.path.join(stage, "module.tar"),
            "-C", os.path.dirname(MODULE), os.path.basename(MODULE))

    # b.sh is the one thing a typed command has to reach. It acknowledges
    # itself before doing anything, so a command that never landed is
    # distinguishable from one that landed and failed (BUILD-NOTES #16).
    with open(os.path.join(stage, "b.sh"), "w") as f:
        f.write(f"""#!/bin/sh
echo BOOTSTRAP-OK
WHAT="{what}"
case "$WHAT" in
  capture|both) sh /mnt/zfs-fixtures.sh ;;
esac
case "$WHAT" in
  test|both)
    # Unpack to a real filesystem. The names inside the tar are exact; the
    # names on the ISO are whatever ISO9660 and the mount options made of them.
    MOD=/run/zfs-module
    rm -rf "$MOD"; mkdir -p "$MOD"
    if [ -f /mnt/module.tar ]; then
      tar -xf /mnt/module.tar -C "$MOD"
    fi
    if [ ! -f "$MOD/Zfs/Zfs.psd1" ]; then
      # Say WHY, rather than skipping tidily. The previous version printed a
      # clean "no module staged yet" for a module that was on the medium under
      # a lowercased name, which read as "nothing to do" instead of "look here".
      echo "ZFS-SELFTEST-NOMODULE: /mnt holds:"
      ls -la /mnt
      echo "ZFS-SELFTEST-NOMODULE: $MOD holds:"
      ls -laR "$MOD" 2>&1 | head -20
    fi
    if [ -f "$MOD/Zfs/Zfs.psd1" ]; then
      # -Live needs pools to look at. In `both` the capture has just built
      # them; run on its own, this boots a live session with none at all and
      # the self-test would fail for having nothing to read rather than for
      # anything about the module. So make sure there is a pool either way.
      modprobe zfs 2>/dev/null
      if ! zpool list -H -o name 2>/dev/null | grep -q .; then
        echo "ZFS-SELFTEST-SETUP: no pools; creating one on a file"
        mkdir -p /var/tmp/zfstest
        truncate -s 256M /var/tmp/zfstest/a.img
        truncate -s 256M /var/tmp/zfstest/b.img
        zpool create -f -o ashift=12 tank mirror \\
              /var/tmp/zfstest/a.img /var/tmp/zfstest/b.img || \\
          echo "ZFS-SELFTEST-SETUP: FAILED to create a pool"
        zfs create tank/data 2>/dev/null
        zfs snapshot tank/data@t 2>/dev/null
      fi
      zpool list -H -o name,health

      echo "ZFS-SELFTEST-START"
      /opt/microsoft/powershell/7/pwsh -NoProfile -NonInteractive -Command \\
        "Import-Module $MOD/Zfs/Zfs.psd1 -Force; Test-ZfsModule -Live -LiveWrite -Pool tank" \\
        2>&1
      echo "ZFS-SELFTEST-EXIT=$?"
    else
      echo "ZFS-SELFTEST-EXIT=90"
    fi ;;
esac
echo ALL-DONE
""")

    ARCH.make_payload_iso(stage, PAYLOAD, LABEL)
    print(f"    payload  {PAYLOAD} ({what})")


def prepare():
    os.makedirs(VM, exist_ok=True)
    if not os.path.exists(ISO):
        raise SystemExit(f"ISO not found: {ISO}\nBuild it with: {ARCH.build_hint}")
    ARCH.prepare_vars(VARS)


# ---------------------------------------------------------------------------
# Cutting the captures back out of the serial log
# ---------------------------------------------------------------------------
BLOCK = re.compile(r"<<<([a-z0-9._]+)>>>\r?\n(.*?)<<<end>>>", re.S)


def extract(text):
    """Every <<<name>>> … <<<end>>> block in the console text.

    The serial line delivers exactly the bytes the guest wrote — a tty does not
    insert breaks at column 80 — but it does translate LF to CRLF, so the CRs
    come out here and not in the fixture files.
    """
    found = {}
    for m in BLOCK.finditer(text):
        found[m.group(1)] = m.group(2).replace("\r", "").strip()
    return found


def write_fixtures(blocks):
    os.makedirs(FIXTURES, exist_ok=True)
    written, empty = [], []
    for name, body in sorted(blocks.items()):
        # The capture names already carry .json where the payload is JSON, so
        # the extension is appended only for the rest. Names that already end
        # in .txt are left alone, or a second capture produces `foo.txt.txt`.
        if name.endswith(".json") or name.endswith(".txt"):
            path = os.path.join(FIXTURES, name)
        else:
            path = os.path.join(FIXTURES, f"{name}.txt")
        with open(path, "w") as f:
            f.write(body + "\n")
        (empty if not body else written).append(name)
    print(f"\n    wrote {len(written)} fixtures to "
          f"{os.path.relpath(FIXTURES, REPO)}")
    for n in written:
        size = len(blocks[n])
        print(f"      {n:<28} {size:>7} bytes")
    if empty:
        print(f"    EMPTY (captured nothing): {', '.join(empty)}")
    return written, empty


# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
def boot_and_run(what, marker, timeout):
    """Boot the live ISO, run b.sh, return the console text."""
    prepare()
    build_payload(what)
    log = os.path.join(VM, f"{what}.serial.log")
    print(f"    serial   {log}")
    c = Console(ARCH.command(qemu_args(), name="zfs"), log)
    try:
        live_login(c)
        print("    live session up")
        to_plain_bash(c)
        print("    plain bash reached")

        cmd = f"sudo sh -c 'mount -L {LABEL} /mnt; sh /mnt/b.sh'"
        for attempt in range(1, 4):
            c.drop()
            c.send(cmd)
            try:
                c.expect(r"BOOTSTRAP-OK", 60, "bootstrap acknowledgement")
                break
            except SystemExit:
                print(f"    bootstrap not acknowledged (attempt {attempt}) — retyping")
                c.send("")
        else:
            raise SystemExit("bootstrap never acknowledged over serial")

        print(f"    running in the guest (waiting for {marker})")
        c.expect(marker, timeout, marker)
        c.settle(quiet=3.0, timeout=120)
        text = c.text()
        c.send("sudo poweroff -f")
        time.sleep(5)
        return text
    finally:
        c.close()


def phase_capture():
    print("\n### capture — real ZFS output, from a VM where ZFS is loaded")
    text = boot_and_run("capture", r"ZFS-CAPTURE-DONE", 900)

    if "ZFS-CAPTURE-WORLD-OK" not in text:
        print(text[-3000:])
        raise SystemExit("the test pools were never created — nothing to capture")

    blocks = extract(text)
    if not blocks:
        print(text[-3000:])
        raise SystemExit("no <<<…>>> blocks in the console log")

    written, empty = write_fixtures(blocks)

    # The check on the capture itself: the five commands the plan says support
    # -j must have produced parseable JSON. If they did not, §4 of the plan is
    # wrong and the module must not be written against it.
    import json
    must = ["zpool.list.json", "zpool.status.json", "zpool.get.json",
            "zfs.list.json", "zfs.get.json"]
    bad = []
    for name in must:
        body = blocks.get(name, "")
        try:
            json.loads(body)
        except Exception as e:
            bad.append(f"{name}: {e}")
    if bad:
        print("\n    JSON THAT DID NOT PARSE:")
        for b in bad:
            print(f"      {b}")
        raise SystemExit("CAPTURE: FAIL — the -j surface is not what §4 claims")

    print("\n    all five -j captures parse as JSON")
    print("CAPTURE: PASS")


def phase_test():
    print("\n### test — the module's self-test, against real ZFS")
    if not os.path.exists(os.path.join(MODULE, "Zfs.psd1")):
        raise SystemExit(f"no module at {MODULE} yet — write it first")
    text = boot_and_run("test", r"ALL-DONE", 900)
    m = re.search(r"ZFS-SELFTEST-EXIT=(\d+)", text)
    tail = text[text.find("ZFS-SELFTEST-START"):] if "ZFS-SELFTEST-START" in text else text[-3000:]
    print(tail[-4000:])
    if not m:
        raise SystemExit("the self-test never reported an exit code")
    if m.group(1) != "0":
        raise SystemExit(f"SELF-TEST: FAIL (exit {m.group(1)})")
    print("TEST: PASS")


def phase_all():
    print("\n### capture + self-test, in one boot")
    text = boot_and_run("both", r"ALL-DONE", 1800)
    blocks = extract(text)
    if blocks:
        write_fixtures(blocks)
    m = re.search(r"ZFS-SELFTEST-EXIT=(\d+)", text)
    if m and m.group(1) != "0":
        raise SystemExit(f"SELF-TEST: FAIL (exit {m.group(1)})")
    print("ALL: PASS")


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        shutil.rmtree(VM, ignore_errors=True)
        print(f"    removed {VM}")
        return
    {"capture": phase_capture, "test": phase_test, "all": phase_all}.get(
        what, lambda: sys.exit(f"unknown phase: {what}"))()


if __name__ == "__main__":
    main()
