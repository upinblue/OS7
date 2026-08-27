#!/usr/bin/env python3
"""
The backup layer, checked against real ZFS and the real sanoid — BACKUP-PLAN §9.

    ./run-backup.py selftest   Test-OS7Backup -Live on a booted machine
    ./run-backup.py cycle      the whole thing: enable, snapshot, replicate to a
                               second pool, break a file, restore it
    ./run-backup.py all        both, in one boot                     (default)
    ./run-backup.py reset      throw the VM state away

*** NEVER RUN. Written 2026-08-25 alongside the feature; no result in this   ***
*** repository came from it. Every claim the backup feature makes today is a ***
*** claim about CODE, checked by Test-OS7Backup offline. This file is what   ***
*** turns it into a claim about a machine, and until somebody runs it the    ***
*** honest status is the one in docs/HANDOFF.md.                             ***

WHY A VM AND NOT A CHROOT. The same reason run-zfs.py gives, doubled. The chroot
has no ZFS kernel module, so every `zfs` call there fails before it parses its
own options — and a probe that ran there once answered ten questions confidently
and wrongly (ZFS-POWERSHELL-PLAN §12, M-Z1). On top of that, half of what this
feature does is systemd: a timer whose services carry conditions, a first-boot
unit, and a replication unit that must NOT fail when a drive is absent. None of
that exists in a chroot at all.

WHAT `cycle` PROVES THAT `selftest` CANNOT. The self-test checks the decisions
OS/7 makes — which datasets are refused, what the rendered sanoid.conf says,
which flags syncoid is given. It cannot check that sanoid then takes a snapshot,
that syncoid's stream arrives, or that a file comes back with its contents. Those
are the three things a backup is, and they are only true on a machine.

TWO POOLS, BOTH ON FILES. `rpool` is not touched: this builds `srcpool` and
`dstpool` on 256 MB files in the live session's writable overlay, so the run is
cheap, repeatable, and cannot damage anything. The cost is that it does NOT
exercise the layout an installed machine has — no rpool/USERDATA, no boot
environments — which is what `cycle` on an INSTALLED disk would add and what
this harness deliberately does not attempt first.
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
OS7_MODULE = os.path.join(REPO, "powershell", "OS7")
ZFS_MODULE = os.path.join(REPO, "powershell", "Zfs")
VM = os.path.join(REPO, ".vm", "backup")
ARCH = VmArch()
ISO = ARCH.iso_default()
VARS = os.path.join(VM, "edk2-vars.fd")
PAYLOAD = os.path.join(VM, "payload.iso")
ARCH.mount(VM, "/vm")
ARCH.mount(os.path.dirname(ISO), "/iso", ro=True)

MEM = "4096"
CPUS = "4"
LABEL = "OS7BACKUP"


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


# ---------------------------------------------------------------------------
# The guest script
# ---------------------------------------------------------------------------
#
# THE MODULES TRAVEL AS A TAR. BUILD-NOTES #61: `hdiutil makehybrid -iso -joliet`
# writes no Rock Ridge, Linux mounts the result nojoliet, and every name arrives
# LOWERCASED — `OS7/OS7.psd1` became `os7/os7.psd1` and a payload script reported
# a tidy skip for a module that was right there. A tar carries its own names, so
# the ISO's filename rules stop mattering.
#
# BOTH modules, because OS7 is Layer 3 and reaches ZFS only through Zfs (Z1). A
# run that staged only OS7 would fall back to whatever the image ships, which is
# a test of the last build rather than of this tree.

GUEST = r"""#!/bin/sh
echo BOOTSTRAP-OK
WHAT="$1"

PWSH=/opt/microsoft/powershell/7/pwsh
MOD=/run/os7-modules
rm -rf "$MOD"; mkdir -p "$MOD"
tar -xf /mnt/modules.tar -C "$MOD" 2>/dev/null

if [ ! -f "$MOD/OS7/OS7.psd1" ] || [ ! -f "$MOD/Zfs/Zfs.psd1" ]; then
  # Say WHY rather than skipping tidily — the failure this shape exists to
  # avoid is a clean "nothing staged" for something that is on the medium
  # under a name the mount changed.
  echo "BACKUP-NOMODULE: /mnt holds:"; ls -la /mnt
  echo "BACKUP-NOMODULE: $MOD holds:"; ls -laR "$MOD" 2>&1 | head -20
  echo "BACKUP-SELFTEST-EXIT=90"
  echo "BACKUP-CYCLE-EXIT=90"
  echo ALL-DONE
  exit 0
fi

# The Zfs module has to resolve BY NAME from inside OS7 (Import-OS7ZfsLayer's
# last resort), so it is put on PSModulePath rather than imported by path. That
# is also how an installed system finds it.
export PSModulePath="$MOD:$PSModulePath"

modprobe zfs 2>/dev/null

echo "BACKUP-SANOID: $(sanoid --version 2>&1 | head -1)"
echo "BACKUP-SYNCOID: $(syncoid --version 2>&1 | head -1)"

# --- the two pools ---------------------------------------------------------
# srcpool stands in for rpool and dstpool for a backup target. Files, not
# disks: the live session's overlay is RAM, 512 MB of it, well inside the 4 GB
# this VM has.
mkdir -p /var/tmp/backup
truncate -s 256M /var/tmp/backup/src.img
truncate -s 256M /var/tmp/backup/dst.img
zpool create -f -o ashift=12 -O compression=lz4 srcpool /var/tmp/backup/src.img \
  || echo "BACKUP-SETUP: FAILED to create srcpool"
zpool create -f -o ashift=12 -o cachefile=none -O compression=zstd \
  -O canmount=off -O mountpoint=none dstpool /var/tmp/backup/dst.img \
  || echo "BACKUP-SETUP: FAILED to create dstpool"

# The shape New-OS7Storage makes, in miniature: a container with the accounts
# under it. `process_children_only` in the rendered config is about exactly
# this, so the fixture has to have it.
zfs create -o canmount=off -o mountpoint=none srcpool/USERDATA
zfs create -o mountpoint=/srctest srcpool/USERDATA/alice
echo "the original contents" > /srctest/notes.txt
mkdir -p /srctest/docs
echo "a document" > /srctest/docs/doc.txt
sync
zpool list -H -o name,health
echo "BACKUP-SETUP-OK"

case "$WHAT" in
selftest|all)
  echo "BACKUP-SELFTEST-START"
  $PWSH -NoProfile -NonInteractive -Command \
    "Import-Module $MOD/OS7/OS7.psd1 -Force; Test-OS7Backup -Live" 2>&1
  echo "BACKUP-SELFTEST-EXIT=$?"
  ;;
esac

case "$WHAT" in
cycle|all)
  echo "BACKUP-CYCLE-START"
  $PWSH -NoProfile -NonInteractive -File /mnt/cycle.ps1 2>&1
  echo "BACKUP-CYCLE-EXIT=$?"
  ;;
esac

echo ALL-DONE
"""

# ---------------------------------------------------------------------------
# The cycle, in PowerShell, because that is the surface being tested
# ---------------------------------------------------------------------------
#
# EVERY ASSERTION ASKS ZFS OR THE FILESYSTEM. None of them reads a cmdlet's
# return value as evidence of anything but the cmdlet returning — which is the
# whole reason this feature exists in the shape it does. `sanoid` exits 0 with a
# failed `zfs snapshot`; `syncoid` exits 0 with its post-transfer work
# unfinished; a restore's rsync exits 0 for a path that resolved into an empty
# mountpoint. Each of those is a step below.

CYCLE = r"""
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module /run/os7-modules/OS7/OS7.psd1 -Force

$pass = 0
$fail = [System.Collections.Generic.List[string]]::new()
function ok($n, $c, $d = '') {
    if ($c) { Write-Host "  PASS  $n"; $script:pass++; return }
    Write-Host "  FAIL  $n $d"; $script:fail.Add($n)
}

# --- 1. a policy over the stand-in USERDATA -------------------------------
$policy = Set-OS7BackupPolicy -Dataset srcpool/USERDATA -Confirm:$false
ok 'the policy writes' ($policy.Configured)
ok '/etc/sanoid/sanoid.conf exists' (Test-Path /etc/sanoid/sanoid.conf)

# THE CHECK THAT ONLY THE REAL PROGRAM CAN MAKE: sanoid reads what OS/7 wrote.
# An unrecognised key is a FATAL die, so this is the difference between a timer
# that works and one that stops without saying so.
& /usr/sbin/sanoid --readonly --take-snapshots --quiet 2>&1 | Out-Null
ok 'sanoid parses the shipped config' ($LASTEXITCODE -eq 0) "(exit $LASTEXITCODE)"

# --- 2. snapshots, counted from ZFS ---------------------------------------
$before = @(Get-ZfsSnapshot -Name srcpool/USERDATA).Count
Start-OS7Backup -Confirm:$false | Out-Null
$after = @(Get-ZfsSnapshot -Name srcpool/USERDATA |
    Where-Object { $_.SnapshotName -like 'autosnap_*' })
ok 'ZFS reports at least one autosnap snapshot' ($after.Count -ge 1) "(had $before)"
ok 'the container itself was not snapshotted' (
    @($after | Where-Object { $_.Dataset -eq 'srcpool/USERDATA' }).Count -eq 0)

# THE INVARIANT THE GUARD IS THE SECOND HALF OF. Nothing sanoid took may sit
# under a boot environment, and on this machine rpool is the live medium's — so
# the check is that no autosnap snapshot exists anywhere outside the configured
# tree.
$stray = @(Get-ZfsDataset -Type Snapshot -Recurse |
    Where-Object { $_.SnapshotName -like 'autosnap_*' -and
                   $_.Dataset -notlike 'srcpool/USERDATA*' })
ok 'no autosnap snapshot escaped the configured datasets' ($stray.Count -eq 0) `
    "($($stray.Name -join ', '))"

# --- 3. replication to the second pool ------------------------------------
New-OS7BackupTarget -Name lab -Pool dstpool -Dataset dstpool/os7 -Confirm:$false | Out-Null
$rep = @(Start-OS7BackupReplication -Confirm:$false)
ok 'replication reports a result for the target' ($rep.Count -eq 1)
ok 'replication verified against the target' ($rep[0].Verified) "($($rep[0].Problems -join '; '))"

# ASKED OF THE TARGET, not of syncoid. The snapshot on dstpool was written by
# `zfs receive`, so its existence is the receiving pool's statement.
$there = @(Get-ZfsSnapshot -Name dstpool/os7)
ok 'the target pool holds snapshots' ($there.Count -ge 1)

# --- 4. a file, lost and restored -----------------------------------------
'the original contents' | Out-File -NoNewline /srctest/notes.txt
Start-OS7Backup -Confirm:$false | Out-Null
Start-Sleep -Seconds 2
'RUINED' | Out-File -NoNewline /srctest/notes.txt

$versions = @(Get-OS7FileVersion /srctest/notes.txt)
ok 'the file has at least one version in a snapshot' ($versions.Count -ge 1)

$r = Restore-OS7File /srctest/notes.txt -Destination /srctest/notes.restored.txt -Confirm:$false
$back = Get-Content -Raw /srctest/notes.restored.txt
ok 'the restored file holds the ORIGINAL bytes' ($back.Trim() -eq 'the original contents') `
    "(got '$($back.Trim())')"
ok 'the live file was not touched' ((Get-Content -Raw /srctest/notes.txt).Trim() -eq 'RUINED')

# A folder, which is the other half of the promise.
$rd = Restore-OS7File /srctest/docs -Destination /srctest/docs-restored -Confirm:$false
ok 'a folder restores' (Test-Path /srctest/docs-restored/doc.txt)

# --- 5. the guard, on a machine ------------------------------------------
$threw = $false
try { Set-OS7BackupPolicy -Dataset rpool/ROOT -Confirm:$false } catch { $threw = $true }
ok 'the guard refuses rpool/ROOT here too' $threw

# --- 6. status, and coverage ---------------------------------------------
$status = Get-OS7BackupStatus
ok 'status reports a local snapshot age' ($null -ne $status.MinutesSinceLocalSnapshot)
ok 'status reports a replication age' ($null -ne $status.HoursSinceReplication)

Write-Host ""
Write-Host "cycle: $pass passed, $($fail.Count) failed"
if ($fail.Count) { Write-Host ('FAILED: ' + ($fail -join '; ')); exit 1 }
exit 0
"""


def build_payload():
    stage = os.path.join(VM, "payload")
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)

    tar = os.path.join(stage, "modules.tar")
    run("tar", "-cf", tar, "-C", os.path.dirname(OS7_MODULE),
        os.path.basename(OS7_MODULE), os.path.basename(ZFS_MODULE))

    with open(os.path.join(stage, "cycle.ps1"), "w", newline="\n") as f:
        f.write(CYCLE)

    # b.sh acknowledges itself BEFORE doing anything, so a command that never
    # landed on the serial line is distinguishable from one that landed and
    # failed (BUILD-NOTES #16).
    with open(os.path.join(stage, "b.sh"), "w", newline="\n") as f:
        f.write(GUEST)

    ARCH.make_payload_iso(stage, PAYLOAD, LABEL)
    print(f"    payload  {PAYLOAD}")


def prepare():
    os.makedirs(VM, exist_ok=True)
    if not os.path.exists(ISO):
        raise SystemExit(f"ISO not found: {ISO}\nBuild it with: {ARCH.build_hint}")
    ARCH.prepare_vars(VARS)


def boot_and_run(what, timeout=1800):
    prepare()
    build_payload()
    log = os.path.join(VM, f"{what}.serial.log")
    print(f"    serial   {log}")
    c = Console(ARCH.command(qemu_args(), name="backup"), log)
    try:
        live_login(c)
        print("    live session up")
        to_plain_bash(c)
        print("    plain bash reached")

        cmd = f"sudo sh -c 'mount -L {LABEL} /mnt; sh /mnt/b.sh {what}'"
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

        print("    running in the guest (waiting for ALL-DONE)")
        c.expect(r"ALL-DONE", timeout, "ALL-DONE")
        c.settle(quiet=3.0, timeout=120)
        text = c.text()
        c.send("sudo poweroff -f")
        time.sleep(5)
        return text
    finally:
        c.close()


def report(text, marker, name):
    """Read one EXIT= out of the console text, and say what it was."""
    m = re.search(rf"{marker}-EXIT=(\d+)", text)
    start = text.find(f"{marker}-START")
    tail = text[start:] if start >= 0 else text[-4000:]
    print(tail[-5000:])
    if not m:
        raise SystemExit(f"{name}: the guest never reported an exit code")
    if m.group(1) == "90":
        raise SystemExit(f"{name}: the modules never reached the guest — see above")
    if m.group(1) != "0":
        raise SystemExit(f"{name}: FAIL (exit {m.group(1)})")
    print(f"{name}: PASS")


def phase_selftest():
    print("\n### selftest — Test-OS7Backup -Live, against real ZFS and real sanoid")
    text = boot_and_run("selftest", 900)
    if "BACKUP-SETUP-OK" not in text:
        print(text[-3000:])
        raise SystemExit("the test pools were never created — nothing was checked")
    report(text, "BACKUP-SELFTEST", "SELFTEST")


def phase_cycle():
    print("\n### cycle — enable, snapshot, replicate, break a file, restore it")
    text = boot_and_run("cycle", 1800)
    if "BACKUP-SETUP-OK" not in text:
        print(text[-3000:])
        raise SystemExit("the test pools were never created — nothing was checked")
    report(text, "BACKUP-CYCLE", "CYCLE")


def phase_all():
    print("\n### selftest + cycle, in one boot")
    text = boot_and_run("all", 2400)
    if "BACKUP-SETUP-OK" not in text:
        print(text[-3000:])
        raise SystemExit("the test pools were never created — nothing was checked")
    report(text, "BACKUP-SELFTEST", "SELFTEST")
    report(text, "BACKUP-CYCLE", "CYCLE")
    print("ALL: PASS")


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        shutil.rmtree(VM, ignore_errors=True)
        print(f"    removed {VM}")
        return
    {"selftest": phase_selftest, "cycle": phase_cycle, "all": phase_all}.get(
        what, lambda: sys.exit(f"unknown phase: {what}"))()


if __name__ == "__main__":
    main()
