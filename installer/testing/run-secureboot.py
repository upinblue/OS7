#!/usr/bin/env python3
"""
Secure Boot, end to end, on a machine.

    ./run-secureboot.py all           medium, install, disk, policy
    ./run-secureboot.py medium        the medium boots signed, and the machine says so
    ./run-secureboot.py install       install unattended FROM that medium
    ./run-secureboot.py disk          the installed machine, no medium, TPM unlock
    ./run-secureboot.py policy        Secure Boot OFF again: the passphrase MUST return

`medium` and `disk` also ask the product's own `Get-OS7SecureBoot` and require
it to AGREE with `mokutil` on the same machine — two independent readings of
one fact, which is what makes either of them worth printing. Its decision
table lives in installer/testing/check-secureboot-logic.py against fake roots;
here is the only place it meets real efivarfs.

WHAT THIS ANSWERS THAT NOTHING ELSE DOES. Since 1.0.0.192 the amd64 install
medium carries a Microsoft-signed shim and a Canonical-signed GRUB
(docs/SESSION-SECUREBOOT-MEDIUM.md), and `check-image.py` reads that off the
finished ISO without booting it. What no file can say is whether a machine
INSTALLED from such a medium comes up with Secure Boot on and unlocks itself
from the TPM — because the seal is against PCR 7, which measures the Secure
Boot POLICY, and every OS/7 machine that has ever existed was sealed against a
policy of "off".

THE VEHICLE IS THE NEW PART, and it is why this is a file rather than a phase
of run-s5.py. Every other harness here boots the medium by handing QEMU
`-kernel` and `-initrd` lifted out of the ISO, so the medium's own bootloader
never runs — which is exactly how an unsigned loader survived on it for months
(BUILD-NOTES #134). This one attaches the ISO with `-cdrom` and lets the
firmware find \\EFI\\BOOT\\BOOTX64.EFI by itself, the way a machine booting a
USB stick does.

That leaves the medium with no serial console — the product's menu puts none on
the kernel command line, and should not — so the harness types at GRUB's own
command line to add one:

    c
    search --no-floppy --set=root --file /.disk/info
    linux  /casper/vmlinuz-<abi> boot=casper fbcon=nodefer quiet console=ttyS0,115200
    initrd /casper/initrd.img-<abi>
    boot

GRUB reads the serial line under OVMF, measured 2026-09-08: `c` opens a
`grub>` prompt and a typed command is EXECUTED, not merely echoed (#16 is why
that distinction was checked). The file names are read off the medium and
exactly one of each is required, because two kernels on a medium would mean
the choice was being made silently.

Only ONE token of that command line is the harness's: `console=ttyS0,115200`.
The rest is what the medium's own entry carries. `os7.setup=1` is deliberately
absent — Setup is run BY HAND from the shell, exactly as run-s5.py runs it, so
that the install being measured is the same install.

WHAT IS REUSED, AND HOW IT IS KEPT HONEST. The install sequence, the plan, the
one-boot-of-the-disk machinery and the trick that gives an installed amd64
machine a serial console at all (#132) are run-s5.py's. They are reached by
REPOINTING run-s5's module-level `lab` at this harness's Secure Boot one —
which is a loud thing to do, so `patch_s5()` immediately asks run-s5 what
firmware it would now use and refuses to continue unless the answer is the
enforcing build. A silently un-repointed global would otherwise run this whole
file on Secure-Boot-off firmware and report a Secure Boot result.

REQUIREMENTS: the amd64 host (x64 Windows + Docker Desktop, /dev/kvm through
the container) and a built ISO. arm64 additionally needs the Secure Boot AAVMF
that vmarch.ensure_firmware() downloads and which has never been exercised.
"""
import importlib.util
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, to_plain_bash   # noqa: E402
from vmscreen import Lab                                   # noqa: E402
from vmarch import VmArch, SoftTpm, run                    # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def _load(name, filename):
    """Import a harness whose filename carries a dash."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


s5 = _load("run_s5", "run-s5.py")

# THE MACHINE. `arch=VmArch(secure_boot=True)` is the entire firmware change,
# and vmscreen.Lab already took an instance, so nothing in vmscreen or os7lab
# needed touching. iso_as_disk=False so the medium arrives as a CD-ROM the
# firmware boots from; medium-as-a-disk belongs to the harnesses that walk
# Setup's disk screen and need it enumerated as a device.
lab = Lab("sb", target_gb=24, iso_as_disk=False, nic=True,
          arch=VmArch(secure_boot=True))
TPMDIR = os.path.join(lab.dir, "tpm")

# The non-enforcing firmware's variable store, for `policy`. A SECOND file,
# because vmarch refuses to hand one store to both firmwares: they are the
# same size and differ only in content, so reusing one would report a Secure
# Boot result from firmware that enforces nothing. Its VmArch needs the same
# mount table Lab builds for its own — the container sees only what is mounted.
NOSB_ARCH = VmArch(lab.arch.arch, secure_boot=False)
NOSB_ARCH.mount(lab.dir, "/vm")
NOSB_ARCH.mount(os.path.dirname(os.path.abspath(lab.iso)), "/iso", ro=True)
NOSB_VARS = os.path.join(lab.dir, "edk2-vars-nosb.fd")

# A THIRD store, for `medium` alone, and it exists because this harness boots
# through the firmware instead of around it.
#
# grub-install writes an NVRAM boot entry during the install, and it lands in
# the variable store — so a `medium` run after an install has firmware that
# prefers \EFI\OS7\shimx64.efi on the DISK over the CD-ROM, and `-boot d` does
# not overrule it: OVMF honours its own BootOrder. Measured 2026-09-08 by the
# first `all` run, which sat at a passphrase prompt for a machine the phase
# was not about. Every other harness here is immune because it hands QEMU
# -kernel and the firmware's boot order never comes up.
MEDIUM_VARS = os.path.join(lab.dir, "edk2-vars-medium.fd")

# One token of the harness's own, named in the header.
LIVE_EXTRA = f"boot=casper fbcon=nodefer quiet console={lab.arch.serial_tty},115200"

_ok = 0
_bad = 0


def check(cond, what, detail="", onfail=""):
    """`detail` is printed either way; `onfail` replaces it when the check fails.

    The split exists because the first version printed one string for both, so
    a passing check about a refusal that did not happen announced itself as
    "ok  the firmware did not refuse the medium — Access Denied". A check whose
    output reads like its own opposite is worse than no output.
    """
    global _ok, _bad
    if cond:
        _ok += 1
        print(f"      ok    {what}" + (f" — {detail}" if detail else ""))
    else:
        _bad += 1
        d = onfail or detail
        print(f"      FAIL  {what}" + (f" — {d}" if d else ""))
    return bool(cond)


def patch_s5():
    """Point run-s5's machinery at THIS harness's machine, and prove it landed.

    run-s5 keeps its Lab and its TPM directory in module globals, and every
    function this file borrows reads them. Reassigning them is the cheapest
    correct way to reuse proven code — and the most dangerous, because a
    global this file does not know about would leave part of run-s5 building
    Secure-Boot-OFF firmware while everything printed says otherwise.

    So the repointing is not trusted, it is ASKED: the argv run-s5 would build
    for a disk boot has to name the enforcing firmware and this harness's
    disk. If run-s5 ever grows a third global, this is where it is noticed.
    """
    s5.lab = lab
    s5.TPMDIR = TPMDIR
    argv = s5.disk_only_args()
    want_fw = os.path.basename(lab.arch.firmware_code())
    fw = [a for a in argv if "pflash" in a and "readonly=on" in a]
    if not (fw and want_fw in fw[0]):
        raise SystemExit(
            f"run-s5's disk boot would use {fw or ['no firmware']} — expected "
            f"{want_fw}. A module global was missed; do not trust this run.")
    if not any(lab.arch.path(lab.target) in a for a in argv):
        raise SystemExit(f"run-s5's disk boot would not use {lab.target}.")
    return True


def Tpm(enabled=True):
    return SoftTpm(lab.arch, TPMDIR, enabled)


def fresh_vars(arch, path):
    """A variable store with no history: removed, then made again.

    prepare_vars() KEEPS an existing store on purpose — enrolment and enrolled
    keys live in it, so a machine's second boot has to see what its first one
    wrote. That is exactly wrong for a store whose job is to be a firmware
    that has never met this disk, so those are asked for explicitly here. The
    marker goes with it, or vmarch would refuse the rebuild.
    """
    for f in (path, arch.vars_marker(path)):
        if os.path.exists(f):
            os.remove(f)
    arch.prepare_vars(path)
    return path


def ask(c, command, label, timeout=240):
    """run-s5's, so both harnesses read a console the same way."""
    return s5.ask(c, command, label, timeout=timeout)


def body(text, fragment):
    return s5.body_of(text, fragment)


def num(text):
    """The single number a `grep -c` left on a line of its own, or None."""
    m = re.search(r"^\s*(\d+)\s*$", text, re.M)
    return int(m.group(1)) if m else None


def check_os7_secureboot(c, where):
    """`Get-OS7SecureBoot` on the machine, and it must agree with the firmware.

    The cmdlet exists because the Windows administrator this product is for
    types `Confirm-SecureBootUEFI`; what it is doing HERE is being checked
    against a second, independent reading of the same fact — `mokutil` above.
    `installer/testing/check-secureboot-logic.py` owns its decision table
    against fake roots; this is the only place it meets real efivarfs.

    Through run-s5's ps(), so PSReadLine never gets near the serial line
    (#16), and with no single quote in the script, which ps() refuses.
    """
    t = s5.ps(c, 'Import-Module OS7 -Force; $b = Get-OS7SecureBoot; '
                 '"OS7SB Supported=$($b.Supported) Enabled=$($b.Enabled) '
                 'SetupMode=$($b.SetupMode) Lockdown=$($b.Lockdown)"',
              f"Get-OS7SecureBoot on {where}")
    # THE ECHO OF THE COMMAND CONTAINS THE MARKER TOO — #16, and this nearly
    # shipped. The typed line has `Supported=$($b.Supported)` in it, so
    # matching on "Supported=" finds the ECHO first and reports the harness's
    # own text as the machine's answer. The line wanted is the one with the
    # substitution already DONE, so it is the one with no `$(` in it.
    line = ""
    for ln in body(t, "OS7SB").splitlines():
        if "Supported=" in ln and "$(" not in ln:
            line = ln.strip()
            break
    check("Supported=True" in line and "Enabled=True" in line,
          f"Get-OS7SecureBoot agrees with the firmware on {where}",
          line or "<the cmdlet printed nothing>")
    check("Lockdown=integrity" in line,
          "and it reports the lockdown Secure Boot brings with it",
          line or "<nothing>")
    return line


def last(text, n=1):
    """The last n lines a command actually printed — for DETAILS, not checks.

    body_of() splits at the first occurrence of the fragment, so what comes
    back still carries the rest of the typed line, ask()'s own marker and the
    next prompt. Harmless for a substring assertion and useless in a report,
    which is what this is for.
    """
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    lines = [ln for ln in lines
             if not re.fullmatch(r"OK\d+", ln)
             and "printf 'OK" not in ln
             and not ln.startswith("bash-")]
    return " | ".join(lines[-n:])[:90]


# ---------------------------------------------------------------------------
# The medium's own names, asked of the medium
# ---------------------------------------------------------------------------
def casper_names():
    """`/casper/vmlinuz-<abi>` and `/casper/initrd.img-<abi>`, off the ISO.

    GRUB's `linux` takes no wildcard, so the harness has to know the names —
    and they carry the kernel version, so they cannot be constants. Read
    through a container because macOS will not mount this hybrid image (the
    same reason vmscreen.extract_boot_files gives), and exactly one of each is
    required.
    """
    iso_dir = os.path.dirname(os.path.abspath(lab.iso))
    out = run("docker", "run", "--rm", "--privileged",
              "--platform", lab.arch.docker_platform,
              "-v", f"{iso_dir}:/iso:ro", lab.arch.build_image, "bash", "-c",
              "set -e; mkdir -p /mnt/i; "
              f"mount -o loop,ro /iso/{os.path.basename(lab.iso)} /mnt/i; "
              "ls /mnt/i/casper/vmlinuz* /mnt/i/casper/initrd*; umount /mnt/i",
              capture_output=True, text=True).stdout
    found = [ln.strip().replace("/mnt/i", "") for ln in out.split() if ln.strip()]
    kern = [f for f in found if "vmlinuz" in f]
    init = [f for f in found if "initrd" in f]
    if len(kern) != 1 or len(init) != 1:
        raise SystemExit(f"the medium carries {len(kern)} kernels and "
                         f"{len(init)} initrds: {found}")
    return kern[0], init[0]


# ---------------------------------------------------------------------------
# The vehicle
# ---------------------------------------------------------------------------
def medium_args(tpm=None, vars_path=None, with_disk=True):
    """QEMU with the medium as a CD-ROM and NO -kernel.

    The bootloader is part of what is under test, so the firmware has to find
    it on the medium itself. Shaped like run-s5.disk_only_args() and for the
    same reason; one line differs, because there the ESP is on the disk and
    here it is the ISO's El Torito image.
    """
    p = lab.arch.path
    args = lab.arch.base_args() + [
        "-smp", lab.CPUS, "-m", lab.MEM,
    ] + lab.arch.firmware_args(vars_path or lab.vars) + [
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-cdrom", p(lab.iso), "-boot", "d",
    ]
    if with_disk and lab.target_gb and os.path.exists(lab.target):
        args += ["-drive", f"if=none,id=target,file={p(lab.target)},format=qcow2",
                 "-device", "virtio-blk-pci,drive=target,serial=os7target"]
    if tpm is not None and tpm.enabled:
        args += tpm.args()
    return args


def boot_medium(c, kern, init):
    """From a cold firmware to a shell on the live medium.

    Four claims are read off the console on the way, none of them inferred: the
    firmware did not refuse the medium (an unsigned one answers "Access Denied
    -- rejected probably by Secure Boot" and falls through to PXE, measured on
    1.0.0.175), it STARTED the loader, GRUB drew the product's menu, and the
    menu is the one the product wrote.
    """
    i = c.expect([r"GNU GRUB\s+version", r"Access Denied", r"Start PXE"],
                 240, "GRUB's menu, or a refusal")
    # TWO WAYS NOT TO GET A MENU, AND THEY ARE DIFFERENT FINDINGS. `Access
    # Denied` is the firmware refusing a signature; falling through to PXE is
    # the firmware finding nothing it wanted to boot — a stale NVRAM entry
    # pointing at a wiped disk reads `Not Found` and then goes to the network.
    # The first version of this check called both of them a signature refusal,
    # and spent a run blaming the loader for a boot order. Report what the
    # firmware said.
    if not check(i == 0, "the firmware booted a loader off the medium", "",
                 ("Access Denied — the loader on this medium is not signed for "
                  "these keys" if i == 1 else
                  "the firmware reached PXE: it never tried the medium. Look "
                  "for `Not Found` and a stale Boot#### entry in the log")):
        raise SystemExit("no loader ran off the medium; nothing below can run")

    # THE LAST ENTRY, NOT THE BANNER. The first version asserted on the buffer
    # as soon as the version line matched, and the menu entries had not been
    # drawn yet — two checks failed about a menu that was about to be correct.
    # `safe graphics` is the third entry, so its arrival means all of them are
    # in the buffer.
    c.expect([r"safe graphics"], 60, "the menu's last entry")
    # `c` with NO Enter: at the menu that opens the command line, and Enter
    # would boot the highlighted entry instead. Sent before the assertions
    # below because any key stops the ten-second countdown — after this the
    # harness has as long as it likes.
    c.send("c", enter=False)
    c.expect([r"grub>"], 60, "GRUB's command line")

    seen = c.text()
    check("starting Boot" in seen, "the firmware STARTED the loader on the medium")
    check("GNU GRUB" in seen and "Install OS/7" in seen,
          "GRUB drew the product's own menu")
    check("live session" in seen, "and the live entries with it")
    c.drop()
    for cmd in ("search --no-floppy --set=root --file /.disk/info",
                f"linux {kern} {LIVE_EXTRA}",
                f"initrd {init}",
                "boot"):
        c.send(cmd)
    live_login(c, user="ubuntu")
    to_plain_bash(c)

    # AND THE CONSOLE IS THE HARNESS'S ONLY ADDITION. Read back from the
    # machine, because a typo in the typed line would otherwise present as a
    # medium that behaves oddly rather than as a harness that boots something
    # else. `os7.setup=1` must NOT be there: Setup is run by hand below.
    t = ask(c, "cat /proc/cmdline", "the command line this medium booted")
    cl = body(t, "/proc/cmdline")
    check("boot=casper" in cl and "console=" in cl and "os7.setup=1" not in cl,
          "the live session booted the medium's entry plus a console",
          last(cl))


# ---------------------------------------------------------------------------
# medium — the medium boots signed, and the machine says so
# ---------------------------------------------------------------------------
def phase_medium():
    print("\n### medium — booted through its own signed bootloader, then asked")
    # prepare() RECREATES the target disk, and this phase installs nothing —
    # so `medium` run on its own after an install would throw the machine away
    # for a phase that never touches it. target_gb=0 for the duration keeps
    # everything else prepare() does (the vars store, the directories, the
    # "is there an ISO at all" check) and leaves the disk alone.
    saved, lab.target_gb = lab.target_gb, 0
    try:
        lab.prepare()
    finally:
        lab.target_gb = saved
    fresh_vars(lab.arch, MEDIUM_VARS)
    kern, init = casper_names()
    print(f"    medium   {os.path.basename(os.path.realpath(lab.iso))}")
    print(f"    entry    linux {kern} / initrd {init}")

    # NO DISK AND ITS OWN FIRMWARE. The phase is about the medium: a disk in
    # the machine changes what the firmware chooses to boot, and an installed
    # one changes it decisively (see MEDIUM_VARS).
    c = Console(lab.arch.command(medium_args(vars_path=MEDIUM_VARS,
                                             with_disk=False), name=lab.name),
                os.path.join(lab.dir, "medium.serial.log"))
    try:
        boot_medium(c, kern, init)

        # THE ONE THAT MATTERS, and it is the machine's own word rather than
        # the host's. Everything in boot_medium says the firmware accepted the
        # loader; this says the firmware was ENFORCING while it did.
        t = ask(c, "mokutil --sb-state 2>&1", "Secure Boot, per the machine")
        check("SecureBoot enabled" in body(t, "2>&1"),
              "the live system reports SecureBoot enabled",
              last(body(t, "2>&1")))

        # The kernel's own statement, from a different source: mokutil reads
        # the EFI variable, the kernel logged what the firmware handed it.
        t = ask(c, "sudo dmesg | grep -i 'secure boot' | head -3",
            "the kernel's view")
        check("secure boot enabled" in body(t, "head -3").lower(),
              "and the kernel logged Secure Boot enabled",
              last(body(t, "head -3")))

        # LOCKDOWN IS THE CONSEQUENCE NOBODY ASKED ABOUT. Secure Boot puts an
        # Ubuntu kernel into integrity lockdown, after which an unsigned module
        # will not load — which is what makes the "never zfs-dkms" decision
        # (SETUP-PLAN §5) load-bearing rather than tidy. If this ever reads
        # `none`, everything below is measuring a machine that is not under the
        # constraint the product ships into.
        t = ask(c, "cat /sys/kernel/security/lockdown 2>&1", "kernel lockdown")
        lock = body(t, "2>&1")
        check("[integrity]" in lock or "[confidentiality]" in lock,
              "the kernel is in lockdown, as Secure Boot makes it",
              last(lock))

        # …and the module that has to load anyway. Asked of lsmod AFTER a
        # modprobe rather than of modprobe's exit code: a module that fails the
        # signature check leaves a machine with no pool and an installer that
        # dies at the storage step.
        t = ask(c, "sudo modprobe zfs >/dev/null 2>&1; lsmod | grep -c '^zfs '",
                "ZFS under lockdown")
        n = num(body(t, "'^zfs '"))
        check(n is not None and n >= 1,
              "and Canonical's prebuilt zfs.ko still loads under it",
              f"lsmod counted {n}")

        # AND THE PRODUCT'S OWN CMDLET, asked the same question. `mokutil`
        # above reads the EFI variable through a package's prose;
        # Get-OS7SecureBoot reads the variable's data byte itself. Two
        # independent routes to one fact, and requiring them to AGREE is what
        # makes either of them worth printing — a cmdlet that answered
        # differently from mokutil on the same machine would be a defect
        # nothing else here could see.
        check_os7_secureboot(c, "the live medium")

        # The loader, verified from INSIDE the running live system: casper
        # mounts the medium at /cdrom, so this is the shipped file asked about
        # by the shipped sbverify. check-image.py says the same from outside,
        # and the two agreeing is the point.
        t = ask(c, "sudo sbverify --list /cdrom/EFI/BOOT/BOOT*.EFI 2>&1 | "
                   "grep -c 'Microsoft Corporation UEFI CA 2011'",
                "the loader, from inside the medium")
        n = num(body(t, "grep -c"))
        check(n is not None and n >= 1,
              "and the medium's own loader names Microsoft's UEFI CA",
              f"sbverify matched {n}")
        return _bad == 0
    finally:
        c.close()


# ---------------------------------------------------------------------------
# install — from THAT medium, unattended, with a TPM attached
# ---------------------------------------------------------------------------
def phase_install():
    print("\n### install — unattended, from a medium the firmware verified")
    lab.prepare()
    # A BLANK DISK IS A NEW MACHINE, so its firmware starts blank too.
    #
    # Without this the store still holds the previous install's NVRAM entry,
    # `Boot0008 "OS/7"` pointing at \EFI\OS7\shimx64.efi on a disk prepare()
    # has just wiped — so the firmware reports `Not Found`, moves on, and
    # reaches PXE without ever trying the CD-ROM. Measured 2026-09-08 on the
    # second `all` run, which read as "Access Denied" only because the
    # harness's own message said so; the firmware's word was `Not Found`.
    #
    # What the install then writes INTO this store is what the `disk` phase
    # boots from, which is the part that models a real machine.
    fresh_vars(lab.arch, lab.vars)
    kern, init = casper_names()

    with Tpm() as tpm:
        c = Console(lab.arch.command(medium_args(tpm), name=lab.name, tpm=tpm),
                    os.path.join(lab.dir, "install.serial.log"))
        try:
            boot_medium(c, kern, init)

            # THE FIXTURE BEFORE THE TEST, run-s5's rule: every Phase 3 run
            # before 2026-08-25 believed it was exercising TpmEnrolStep and was
            # not, because the step looks for /sys/class/tpm/tpm0 and quietly
            # takes the other path.
            t = ask(c, "ls -d /sys/class/tpm/tpm0 2>&1", "the guest's TPM")
            if not check("/sys/class/tpm/tpm0" in body(t, "2>&1"),
                         "the guest can see a TPM"):
                return False

            # run-s5's plan, deliberately: same hostname, same account, same
            # passphrase, so the machine this harness installs IS the machine
            # run-s5 installs and the two runs are comparable.
            s5.write_plan(c)
            t = ask(c, "sudo os7-setup --unattend /tmp/plan.json "
                       "--passphrase-file /tmp/pass --password-file /tmp/pw",
                    "unattended install", timeout=2400)
            for line in t.splitlines():
                s = line.strip()
                if "OS7-SETUP" in s or ">>>" in s or "!!!" in s:
                    print("        " + s)
            if not check("OS7-SETUP-DONE install" in t, "Setup finished the install"):
                for line in t.replace("\r", "").splitlines()[-25:]:
                    if line.strip():
                        print("        " + line.strip())
                return False
            check("no TPM on this machine" not in t,
                  "and it did not take the no-TPM path")

            t = ask(c, "zpool list -H -o name || true", "imported pools")
            check(not re.search(r"\b[rb]pool\b", body(t, "|| true")),
                  "the installer exported both pools")

            # #132: an installed amd64 machine carries no console= of its own,
            # so every later phase would drive a line the machine never speaks
            # on. run-s5's fix, called with this harness's console.
            if lab.arch.serial_tty != "ttyAMA0":
                if not check(s5.give_serial_console(c),
                             "the machine was given a serial console"):
                    return False
            return _bad == 0
        finally:
            c.close()


# ---------------------------------------------------------------------------
# disk — the installed machine, Secure Boot on, no medium at all
# ---------------------------------------------------------------------------
def phase_disk():
    print("\n### disk — the installed machine, Secure Boot on, no medium")
    if not os.path.exists(lab.target):
        raise SystemExit(f"no installed disk at {lab.target}. Run `install` first.")
    patch_s5()

    # TWO BOOTS, AND #69 IS WHY. TpmEnrolStep seals at install time against
    # the LIVE session's PCR 7, and the installed machine boots through shim,
    # which extends PCR 7 differently — so the first boot asks for the
    # passphrase. That is the product's known state (the first-boot migration
    # UL1 is unshipped), not a finding of this harness, and run-s5 measured it
    # on amd64 first. The recovery is S6's one systemd-cryptenroll against the
    # PCR 7 the real boot path produces, and THE VERDICT IS THE SECOND BOOT.
    #
    # What is new here is which PCR 7 that is: every re-enrolment before this
    # one happened under firmware that enforced nothing. This one is bound to
    # Secure Boot on, with Microsoft's keys — which is the policy a customer
    # machine actually has.
    with s5.Machine("sbdisk1", expect_unlock=False) as m:
        c = m.c
        check("Access Denied" not in c.text(),
              "the firmware accepted shim on the machine's own ESP")
        if m.unlocked_by_tpm:
            print("      note  the first boot already unlocked from the TPM — the "
                  "install-time seal matched this boot path")
        else:
            print("      note  the first boot asked for the passphrase (#69); "
                  "re-enrolling against the boot path's own PCR 7")
            t = ask(c, f"PASSWORD='{s5.PASSPHRASE}' systemd-cryptenroll "
                       "--wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7 "
                       "/dev/disk/by-partlabel/os7-luks 2>&1 | tail -3",
                    "re-enrol under THIS policy", timeout=300)
            if not check("enrolled" in body(t, "tail -3"),
                         "re-enrolled against a Secure-Boot-on PCR 7",
                         body(t, "tail -3").strip()[:120]):
                return False
        m.power_off()

    with s5.Machine("sbdisk2", expect_unlock=True) as m:
        c = m.c
        if not check(m.unlocked_by_tpm,
                     "THE TPM UNLOCKED THE DISK — no passphrase was typed", "",
                     "the initramfs asked again: the seal does not match the "
                     "policy it was made under"):
            return False

        t = ask(c, "mokutil --sb-state 2>&1", "Secure Boot, per the machine")
        check("SecureBoot enabled" in body(t, "2>&1"),
              "and the installed system reports SecureBoot enabled",
              last(body(t, "2>&1")))

        # THE PRODUCT'S OWN ANSWER, on the installed machine. This is the one
        # an operator will actually type, and it is the reason the cmdlet
        # exists: `mokutil` above is a package, this is OS/7.
        check_os7_secureboot(c, "the installed machine")

        t = ask(c, "findmnt -no SOURCE,FSTYPE / 2>&1", "the root filesystem")
        check("rpool/ROOT/os7_" in body(t, "2>&1") and "zfs" in body(t, "2>&1"),
              "its root is a boot environment on ZFS",
              last(body(t, "2>&1")))

        # The token, read off the LUKS header rather than inferred from nothing
        # having asked: a machine that unlocked from a keyfile somebody left on
        # the ESP would look identical from the outside.
        t = ask(c, "cryptsetup luksDump /dev/disk/by-partlabel/os7-luks 2>&1 "
                   "| grep -c systemd-tpm2", "the TPM2 token")
        n = num(body(t, "grep -c"))
        check(n is not None and n >= 1,
              "and the LUKS header carries a systemd-tpm2 token",
              f"luksDump listed {n}")
        m.power_off()
    return _bad == 0


# ---------------------------------------------------------------------------
# policy — the negative control, and U8's question in one command
# ---------------------------------------------------------------------------
def disk_args_nosb(tpm=None):
    """The installed disk under the NON-enforcing firmware.

    Its own variable store, so the marker vmarch writes keeps the two apart —
    and with a fresh store there is no NVRAM entry either, so the firmware
    falls back to \\EFI\\BOOT\\BOOTX64.EFI, which is the path that has to work
    on a machine whose CMOS was cleared.
    """
    p = NOSB_ARCH.path
    args = NOSB_ARCH.base_args() + [
        "-smp", lab.CPUS, "-m", lab.MEM,
    ] + NOSB_ARCH.firmware_args(NOSB_VARS) + [
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={p(lab.target)},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]
    if tpm is not None and tpm.enabled:
        args += tpm.args()
    return args


def phase_policy():
    print("\n### policy — Secure Boot OFF again: the passphrase MUST come back")
    if not os.path.exists(lab.target):
        raise SystemExit(f"no installed disk at {lab.target}. Run `install` first.")

    # THIS IS WHAT MAKES `disk` MEAN ANYTHING. A seal that opens whatever the
    # firmware policy is would be a seal bound to nothing, and from the outside
    # it would look exactly like a working one. PCR 7 measures the Secure Boot
    # policy, so the same disk under the non-enforcing firmware must NOT
    # unseal. Spike S6 measured this from the other direction — by swapping the
    # variable store — and called the passphrase here the correct behaviour.
    #
    # It is also U8 (docs/DECISIONS.md, open question 7) in one command: on a
    # managed fleet a shim or dbx update moves PCR 7, and what the operator
    # meets that morning is this prompt.
    NOSB_ARCH.prepare_vars(NOSB_VARS)
    tpm = SoftTpm(NOSB_ARCH, TPMDIR, True)
    with tpm:
        c = Console(NOSB_ARCH.command(disk_args_nosb(tpm),
                                      name=lab.name + "p", tpm=tpm),
                    os.path.join(lab.dir, "policy.serial.log"))
        try:
            i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                          r"\blogin:", r"Kernel panic", r"No bootable"],
                         900, "the passphrase prompt")
            if i >= 4:
                print(c.text()[-2000:])
                return check(False, "the machine started at all")
            if not check(i <= 2,
                         "the TPM refused to unseal under a changed policy", "",
                         "it booted straight to a login: the seal is bound to "
                         "nothing PCR 7 measures"):
                return False

            # AND THE MACHINE IS STILL RECOVERABLE. The passphrase keyslot is
            # kept by design (S4), and a fleet that cannot be recovered by hand
            # after a firmware update is the failure U8 is about.
            #
            # drop() FIRST, and it is not tidiness: expect() matches against
            # the ACCUMULATED buffer, which still holds the prompt that was
            # just waited for. Without this the second expect matches "unlock
            # disk" out of the old text the instant it is called and reports a
            # rejected passphrase that was never typed. Measured on the first
            # run of this phase, which failed exactly that way.
            c.drop()
            c.answering = True
            c.send(s5.PASSPHRASE)
            i = c.expect([r"\blogin:", r"unlock disk", r"No key available"], 600,
                         "a login after the passphrase")
            if not check(i == 0, "and the passphrase still unlocks it", "",
                         "the machine asked again — the kept keyslot did not open"):
                return False

            live_login(c, user=s5.USERNAME, password=s5.PASSWORD)
            to_plain_bash(c)
            # AND THE CONTROL IS A CONTROL, asked of the machine. The answer
            # here is not "SecureBoot disabled" but "This system doesn't
            # support Secure Boot" — measured 2026-09-08 — because
            # OVMF_CODE_4M.fd is built WITHOUT Secure Boot support at all
            # rather than merely shipping no keys. That is a stronger control
            # than a disabled one, and it is also the reason vmarch pairs a
            # firmware CODE build with its variable store instead of letting a
            # caller mix them: the enforcing build with a key-less store would
            # answer "disabled", and this one cannot be made to enforce at all.
            t = ask(c, "mokutil --sb-state 2>&1", "Secure Boot, per the machine")
            sb = body(t, "2>&1").lower()
            check("secureboot disabled" in sb or "support secure boot" in sb,
                  "and this really was the non-enforcing firmware",
                  last(body(t, "2>&1")))
            return _bad == 0
        finally:
            c.close()


PHASES = {"medium": phase_medium, "install": phase_install,
          "disk": phase_disk, "policy": phase_policy}
ORDER = ("medium", "install", "disk", "policy")


def main():
    which = sys.argv[1:] or ["all"]
    if which == ["all"]:
        which = list(ORDER)
    for w in which:
        if w not in PHASES:
            raise SystemExit(f"unknown phase {w!r} — one of {', '.join(ORDER)}, or all")
    print(f"\n=== Secure Boot on a machine ({lab.arch.arch}, firmware "
          f"{os.path.basename(lab.arch.firmware_code())})")
    for w in which:
        if not PHASES[w]():
            print(f"\n  {_ok} ok, {_bad} failed — stopped in `{w}`")
            sys.exit(1)
    print(f"\n  {_ok} ok, {_bad} failed")
    print("run-secureboot:", "GREEN" if _bad == 0 else "RED")
    sys.exit(1 if _bad else 0)


if __name__ == "__main__":
    main()
