#!/usr/bin/env python3
"""
Phase 3 — os7-setup installs a system, and the system boots.

SETUP-PLAN §10 Phase 3's deliverable is one sentence: *a machine installed by
Setup boots into OS/7.* Everything before it could be checked by reading the
disk; this one cannot. The only evidence that counts is a machine starting from
that disk with nothing else attached.

    ./run-phase3.py install    install unattended from the live medium
    ./run-phase3.py boot       BOOT THE DISK ALONE and log in as the account
    ./run-phase3.py all        install, boot        (default)
    ./run-phase3.py reset      discard the VM state

`install` and `boot` are separate phases on purpose, and the separation is the
whole design: `boot` attaches NO ISO. A VM that still has the setup medium in it
can boot from the medium and look exactly like a successful install — which is
how an installer ships a bootloader that has never been exercised. Spike S3 made
the same split for the same reason and it is the only reason S3 counts as
evidence.

WHAT IS ASSERTED, in order, because each one fails differently:

  1. the LUKS passphrase prompt appears        - GRUB, kernel and initramfs work
  2. it is not `(initramfs)` or a kernel panic - the failure signature, watched
                                                 for explicitly so a dead boot
                                                 costs seconds not the timeout
  3. a login prompt                            - the pool imported and / mounted
  4. the account Setup created accepts its password
  5. `/` is served from rpool/ROOT/os7_<version>_<stamp>
  6. the version on the disk is the version on the medium
  7. /etc/os-release says OS/7, and still says ID=ubuntu for Intune
  8. the hostname is the one that was typed

7 is the check nothing else can make: os-release on the INSTALLED system, after
`unsquashfs` copied it and ReleaseIdentityStep rewrote VARIANT.
"""

import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, to_plain_bash            # noqa: E402
from vmscreen import Lab, run                                      # noqa: E402

PASSPHRASE = "os7-phase3-passphrase"
PASSWORD = "os7-phase3-password"
HOSTNAME = "os7-phase3"
USERNAME = "os7admin"

# 24 GB: the §4.4 layout needs 16 as a floor, and the copied system needs room.
lab = Lab("phase3", target_gb=24, iso_as_disk=True)

CMDLINE = ("boot=casper os7.setup=1 systemd.wants=os7-setup.service "
           "fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 "
           "console=ttyAMA0,115200")
LIVE_CMDLINE = "boot=casper fbcon=nodefer quiet console=ttyAMA0,115200"

# The target is the SECOND disk. The first is the live medium, attached as a
# block device rather than a CD so that it is a `disk` to lsblk - BUILD-NOTES
# #35, and the only shape in which "the medium is refused" can be tested at all.
TARGET = "/dev/disk/by-id/virtio-os7target"

_mark = 0


def disk_only_args():
    """QEMU with THE TARGET DISK AND NOTHING ELSE.

    Written here rather than taken from `Lab.qemu_args`, because that one is
    built for the other direction and every difference matters:

      * NO `-kernel` / `-initrd`. Every other harness in this directory boots the
        kernel directly, which is the right call when what is under test is
        userspace and driving GRUB over a serial line is what HANDOFF §5 warns
        about. Here the BOOTLOADER IS THE THING UNDER TEST - `grub-install` and
        the generated menu are Phase 3 deliverables - so the firmware has to find
        it on the ESP by itself.
      * NO ISO. A VM that still has the setup medium attached can boot from the
        medium and look exactly like a successful install. That is how an
        installer ships a bootloader nobody has ever exercised.
      * THE SAME VARIABLE STORE the install ran with, so an NVRAM entry written
        by `grub-install` is there to be used - and if it is not, the removable
        EFI/BOOT path has to stand in, which is the case that matters on
        hardware with a cleared CMOS.

    Spike S3 made exactly this split and it is the only reason S3 counts as
    evidence rather than as a log.
    """
    from vmconsole import qemu_prefix
    pre = qemu_prefix()
    code = os.path.join(pre, "share", "qemu", "edk2-aarch64-code.fd")
    return [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", lab.CPUS, "-m", lab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={lab.vars}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={lab.target},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]


def ask(c, command, label, timeout=180):
    """Run something in the guest and return everything it printed.

    THE MARKER IS BUILT BY THE SHELL, NOT TYPED (BUILD-NOTES #16). `…; echo DONE`
    and then waiting for "DONE" matches the shell's ECHO of the command being
    typed, so `expect` returns before the command has run.
    """
    global _mark
    _mark += 1
    n = _mark
    c.drop()
    c.send(f"{command}; printf 'OK%s\\n' {n}")
    c.expect(f"OK{n}", timeout, label)
    return c.text()


def medium_release():
    """The version on the SETUP MEDIUM, taken out of the ISO.

    What the installed system must turn out to be. Read from the image rather
    than written into this file, for the same reason run-phase1 does it: a
    harness carrying the expected version passes until somebody forgets to edit
    it.
    """
    out = os.path.join(lab.dir, "medium-release.json")
    os.makedirs(lab.dir, exist_ok=True)
    if os.path.exists(out):
        os.remove(out)
    run("docker", "run", "--rm", "--privileged", "--platform", "linux/arm64",
        "-v", f"{os.path.dirname(lab.iso)}:/iso:ro", "-v", f"{lab.dir}:/out",
        "os7-build:arm64", "bash", "-c",
        f"set -e; mkdir -p /mnt/iso /mnt/sq; "
        f"mount -o loop,ro /iso/{os.path.basename(lab.iso)} /mnt/iso; "
        "mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq; "
        "cp /mnt/sq/usr/lib/os7/release.json /out/medium-release.json; "
        "umount /mnt/sq; umount /mnt/iso", stdout=subprocess.DEVNULL)
    return json.load(open(out))


def write_plan(c):
    """A complete plan, plus the two secrets as separate files.

    §6.6: the passphrase is not in the plan and neither is the account password.
    They are different secrets with different consequences, so they are two
    files - a fleet that rotates one should not have to rewrite the other.
    """
    plan = ('{"version":1,"intent":"Install","language":"de_DE.UTF-8",'
            '"keyboard":"de","timezone":"Europe/Berlin","mode":"Headless",'
            f'"storage":{{"disk":"{TARGET}","layout":"single","efiMiB":512,'
            '"bpoolGiB":2,"encrypt":true,"swap":"zram"},'
            f'"account":{{"hostname":"{HOSTNAME}","username":"{USERNAME}",'
            '"fullName":"OS/7 Phase 3"}}')
    c.drop()
    c.send(f"printf '%s' '{plan}' > /tmp/plan.json")
    c.send(f"printf '%s' '{PASSPHRASE}' > /tmp/pass")
    c.send(f"printf '%s' '{PASSWORD}' > /tmp/pw")
    ask(c, "wc -c /tmp/plan.json /tmp/pass /tmp/pw", "plan files")


def phase_install():
    print("\n  install — the whole thing, unattended")
    lab.prepare()
    c, q = lab.boot(LIVE_CMDLINE, "install")
    try:
        write_plan(c)
        # Twenty minutes: unsquashfs of a 2 GB image onto ZFS-on-LUKS in a VM is
        # minutes, update-initramfs is minutes, and a timeout that fires during
        # a working install is a harness that reports a bug it created.
        text = ask(c, "sudo os7-setup --unattend /tmp/plan.json "
                      "--passphrase-file /tmp/pass --password-file /tmp/pw",
                   "unattended install", timeout=1800)
        for line in text.splitlines():
            if "OS7-SETUP" in line or ">>>" in line or "!!!" in line:
                print("        " + line.strip())
        if "OS7-SETUP-DONE install" not in text:
            print("      FAIL  the install did not finish")
            # SHOW WHAT IT SAID. The first version of this printed the verdict
            # and nothing else, and the actual cause - an ISO carrying an
            # os7-setup that predated the option being passed to it - was
            # visible only by reading the serial log by hand afterwards.
            print("      --- the last of what the guest printed ---")
            for line in text.replace("\r", "").splitlines()[-25:]:
                if line.strip():
                    print("        " + line.strip())
            print("      ---")
            if "unknown option" in text or "Usage: os7-setup" in text:
                print("      NOTE: the ISO's os7-setup does not understand an option this")
                print("      NOTE: harness passed. The binary is baked in at BUILD time -")
                print("      NOTE: rebuild the ISO (make build-arm64) after changing Setup.")
            return False
        print("      ok    Setup reported a finished install")

        # ASK WHETHER THE POOLS ARE STILL IMPORTED, do not export them here.
        # TeardownStep is the last thing the installer runs and exporting is its
        # job; a harness that exports as well would pass whether or not the
        # installer did it, and the next boot is where that difference shows.
        text = ask(c, "zpool list -H -o name || true", "imported pools")
        body = text.split("zpool list -H -o name || true", 1)[-1]
        if "rpool" in body or "bpool" in body:
            print("      FAIL  a pool is still imported after the install finished")
            print("            " + body.replace("\r", "").strip()[:200])
            return False
        print("      ok    the installer exported both pools")
        return True
    finally:
        q.close()
        c.close()


def phase_boot():
    """THE DELIVERABLE. No ISO attached — the disk boots or it does not."""
    print("\n  boot — the installed disk, with nothing else attached")

    # `boot` on its own, with no install behind it, would start a VM with a
    # blank disk and a missing variable store and report "does not boot" —
    # true, and about a machine nothing ever installed.
    for need, what in ((lab.target, "an installed disk"),
                       (lab.vars, "a firmware variable store")):
        if not os.path.exists(need):
            print(f"      FAIL  no {what} at {need}. Run `./run-phase3.py install` first.")
            return False

    rel = medium_release()
    version = rel["version"]

    log = os.path.join(lab.dir, "boot.serial.log")
    print(f"    serial   {log}")
    c = Console(disk_only_args(), log)
    ok = True
    try:
        # The failure signatures are watched for BESIDE the success one. Dropping
        # to (initramfs) is the exact shape of "LUKS never opened" or "the pool
        # never imported", and waiting out a 7-minute timeout for it wastes a
        # cycle and says less than the word does.
        i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                      r"\(initramfs\)", r"Kernel panic", r"No bootable"],
                     600, "the passphrase prompt")
        if i >= 3:
            print(c.text()[-3000:])
            print("      FAIL  the machine never got as far as asking for the passphrase")
            return False
        print("      ok    1/8 GRUB, the kernel and the initramfs all ran")
        c.send(PASSPHRASE)

        j = c.expect([r"\blogin:", r"\(initramfs\)", r"Kernel panic",
                      r"No key available", r"Failed to import pool"],
                     900, "a login prompt")
        if j >= 1:
            print(c.text()[-3000:])
            print("      FAIL  unlocked, but never reached a login prompt")
            return False
        print("      ok    2/8 the pool imported and / was mounted")
        print("      ok    3/8 a login prompt")

        # 4: THE ACCOUNT SETUP CREATED, with the password Setup hashed.
        # This is the check BUILD-NOTES #17 exists for: `chpasswd` cannot work in
        # the chroot, so AccountStep writes the hash instead - and the only proof
        # that the hash is right is a login.
        live_login(c, user=USERNAME, password=PASSWORD)
        to_plain_bash(c)
        print(f"      ok    4/8 {USERNAME} logged in with the password Setup set")

        body = ask(c, "echo P3-"'"BEGIN"'"; "
                      "findmnt -no SOURCE,FSTYPE /; "
                      "cat /etc/os-release; "
                      "hostname; "
                      "cat /proc/cmdline; "
                      "echo P3-"'"END"',
                   "verification", timeout=180)
        body = body.split("P3-BEGIN", 1)[-1].split("P3-END", 1)[0]
        print("\n--- what the installed system says ---")
        print(body.strip())
        print("--- ")

        # 5: / is served from a boot environment, not from anything else.
        if f"rpool/ROOT/os7_{version}_" in body and "zfs" in body:
            print(f"      ok    5/8 / is rpool/ROOT/os7_{version}_…")
        else:
            print(f"      FAIL  / is not a boot environment named for {version}")
            ok = False

        # 6/7: the identity, on the INSTALLED system.
        if f'IMAGE_VERSION="{version}"' in body or f"IMAGE_VERSION={version}" in body:
            print(f"      ok    6/8 IMAGE_VERSION is {version}")
        else:
            print(f"      FAIL  IMAGE_VERSION on the disk is not {version}")
            ok = False
        if "ID=ubuntu" in body and 'VERSION_ID="26.04"' in body:
            print("      ok    7/8 ID and VERSION_ID are untouched (Intune, L16)")
        else:
            print("      FAIL  the Intune-matched os-release fields were changed")
            ok = False
        if 'VARIANT_ID="server"' in body:
            print("      ok         VARIANT_ID=server (the headless install)")
        else:
            print("      note       VARIANT_ID is not 'server'")

        # 8: the name that was typed.
        if HOSTNAME in body:
            print(f"      ok    8/8 the computer is called {HOSTNAME}")
        else:
            print(f"      FAIL  the hostname is not {HOSTNAME}")
            ok = False

        # And the one that decides everything else, BUILD-NOTES #15.
        if "boot=zfs" in body:
            print("      ok         boot=zfs is on the kernel command line")
        else:
            print("      FAIL  boot=zfs is missing - this boot was luck")
            ok = False
        return ok
    finally:
        c.close()


PHASES = {"install": phase_install, "boot": phase_boot}


def main():
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what == "reset":
        lab.reset()
        return 0

    print("### os7-setup Phase 3 — the disk becomes a system")
    results = {}
    if what in ("all", "install"):
        results["install"] = phase_install()
        # No point booting a disk the install did not finish on: the failure
        # would be reported as "does not boot", which is true and useless.
        if what == "all" and not results["install"]:
            print("\n### Phase 3 result\n    install   FAIL (boot not attempted)")
            return 1
    if what in ("all", "boot"):
        results["boot"] = phase_boot()
    if not results:
        raise SystemExit(__doc__)

    print("\n### Phase 3 result")
    for name, good in results.items():
        print(f"    {name:<9} {'PASS' if good else 'FAIL'}")
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
