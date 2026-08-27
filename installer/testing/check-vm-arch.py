#!/usr/bin/env python3
"""
Does vmarch.py build the SAME arm64 command lines the harnesses built before
it existed — and honest amd64 ones? No QEMU, no Docker, runs on both hosts.

    ./check-vm-arch.py            both architectures, ~2 seconds

WHY THIS FILE CARRIES THE OLD CODE. The port that introduced vmarch.py
(docs/SESSION-VM-HARNESS-PORT.md) was written on the x64 Windows host, which
cannot execute the arm64/HVF branch at all — no Mac was available to run
`run-s5.py` and see nothing changed. So the pre-port construction of every
harness's QEMU argv is REPRODUCED HERE, literal for literal, from commit
8700095, and the refactored harnesses are required to produce byte-identical
argv. That is the strongest statement a machine without HVF can make: not
"the arm64 branch probably still works" but "the arm64 branch emits exactly
the bytes that were proven on the Mac". If a later change to vmarch.py moves
one flag, this fails and names it.

The amd64 half is asserted by property, not by golden — it had no prior shape
to preserve: q35 + KVM + OVMF, serial on ttyS0, TPM frontend tpm-tis, QEMU
wrapped in `docker run --device /dev/kvm`, QMP on published TCP, and NO host
path leaking into the container's argv (the failure mode of a missed
translation is QEMU reporting "no such file" for a file that exists).

Both halves run through the REAL harness modules — run-s5, run-phase3,
run-phase3b-network, run-backup, run-zfs, verify-console-font, vmscreen.Lab —
imported with OS7_VM_ARCH forced, so what is checked is what runs, not a copy.

OS7_VMARCH_CHECK=1 keeps vmarch away from docker (no image build, no container
cleanup) while the command lines are built; nothing else changes shape.
"""
import importlib.util
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

# A prefix that exists on no host, deliberately: every path built from it is
# recognisable in the output, and the check cannot accidentally depend on a
# real QEMU installation.
FAKE_PREFIX = "/check-vm-arch/qemu-prefix"

_ok = 0
_bad = 0


def check(cond, what, detail=""):
    global _ok, _bad
    if cond:
        _ok += 1
        print(f"  ok    {what}")
    else:
        _bad += 1
        print(f"  FAIL  {what}")
        if detail:
            print(f"        {detail}")


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, filename))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def diff_argv(got, want):
    """The first differing position, printable."""
    for i in range(max(len(got), len(want))):
        g = got[i] if i < len(got) else "<absent>"
        w = want[i] if i < len(want) else "<absent>"
        if g != w:
            return f"argv[{i}]: got {g!r}, want {w!r}"
    return ""


# ---------------------------------------------------------------------------
# arm64 — the golden half. Every literal below is the PRE-PORT construction.
# ---------------------------------------------------------------------------
def run_arm64():
    print("\n-- arm64: byte-identical to the pre-port construction (commit 8700095)")
    vmscreen = load("vmscreen", "vmscreen.py")
    run_s5 = load("run_s5", "run-s5.py")
    run_phase3 = load("run_phase3", "run-phase3.py")
    run_phase3b = load("run_phase3b", "run-phase3b-network.py")
    run_backup = load("run_backup", "run-backup.py")
    run_zfs = load("run_zfs", "run-zfs.py")
    vcf = load("verify_console_font", "verify-console-font.py")

    pre = FAKE_PREFIX
    code = os.path.join(pre, "share", "qemu", "edk2-aarch64-code.fd")

    # ---- vmscreen.Lab.qemu_args, all optional branches ON -------------------
    lab = vmscreen.Lab("vmarchck", target_gb=24, iso_as_disk=True, nic=True)
    os.makedirs(lab.dir, exist_ok=True)
    for f in (lab.target, lab.payload):
        open(f, "ab").close()
    try:
        cmdline = "boot=casper fbcon=nodefer quiet console=ttyAMA0,115200"
        got = lab.qemu_args(cmdline, payload=True)
        want = [
            "qemu-system-aarch64",
            "-machine", "virt,accel=hvf", "-cpu", "host",
            "-smp", lab.CPUS, "-m", lab.MEM,
            "-drive", f"if=pflash,format=raw,file={code},readonly=on",
            "-drive", f"if=pflash,format=raw,file={lab.vars}",
            "-device", f"virtio-gpu-pci,xres={vmscreen.FB_W},yres={vmscreen.FB_H}",
            "-device", "qemu-xhci", "-device", "usb-kbd",
            "-display", "none", "-monitor", "none", "-serial", "stdio",
            "-qmp", f"unix:{lab.qmpsock},server,nowait",
            "-kernel", lab.kernel, "-initrd", lab.initrd, "-append", cmdline,
            "-drive", f"if=none,id=live,file={lab.iso},format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=live,serial=os7live",
            "-drive", f"if=none,id=payload,file={lab.payload},format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=payload",
            "-drive", f"if=none,id=target,file={lab.target},format=qcow2",
            "-device", "virtio-blk-pci,drive=target,serial=os7target",
            "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        ]
        check(got == want, "Lab.qemu_args", diff_argv(got, want))
        check(lab.MEM == "4096", "arm64 guest memory is the proven 4096", lab.MEM)
        check(lab.arch.command(got, name=lab.name) == got,
              "command() is the identity on the host-process path")
        check(lab.arch.qmp_endpoint(lab.qmpsock, lab.name) == lab.qmpsock,
              "the QMP endpoint is the unix socket")
        check(lab.iso == os.path.join(REPO, "out", "os7-arm64.iso"),
              "the default medium is out/os7-arm64.iso")
    finally:
        shutil.rmtree(lab.dir, ignore_errors=True)

    # ---- run-s5 -------------------------------------------------------------
    got = run_s5.disk_only_args()
    s5lab = run_s5.lab
    want = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", s5lab.CPUS, "-m", s5lab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={s5lab.vars}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={s5lab.target},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]
    check(got == want, "run-s5 disk_only_args", diff_argv(got, want))
    check(run_s5.LIVE_CMDLINE == "boot=casper fbcon=nodefer quiet console=ttyAMA0,115200",
          "run-s5 LIVE_CMDLINE", run_s5.LIVE_CMDLINE)
    tpm = run_s5.Tpm()
    got = tpm.args()
    sock = os.path.join(run_s5.TPMDIR, "swtpm-sock")
    want = ["-chardev", f"socket,id=chrtpm,path={sock}",
            "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
            "-device", "tpm-tis-device,tpmdev=tpm0"]
    check(got == want, "run-s5 TPM args (sysbus tpm-tis-device)", diff_argv(got, want))
    check(run_s5.Tpm(False).args() == [], "a disabled TPM contributes nothing")

    # ---- run-phase3 ---------------------------------------------------------
    got = run_phase3.disk_only_args()
    p3lab = run_phase3.lab
    want = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", p3lab.CPUS, "-m", p3lab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={p3lab.vars}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
        "-drive", f"if=none,id=target,file={p3lab.target},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]
    check(got == want, "run-phase3 disk_only_args", diff_argv(got, want))
    check(run_phase3.CMDLINE == (
        "boot=casper os7.setup=1 systemd.wants=os7-setup.service systemd.unit=multi-user.target "
        "fbcon=font:TER16x32 fbcon=nodefer plymouth.enable=0 quiet loglevel=0 "
        "console=ttyAMA0,115200"), "run-phase3 CMDLINE", run_phase3.CMDLINE)
    check(run_phase3.LIVE_CMDLINE == "boot=casper fbcon=nodefer quiet console=ttyAMA0,115200",
          "run-phase3 LIVE_CMDLINE", run_phase3.LIVE_CMDLINE)

    # ---- run-phase3b-network ------------------------------------------------
    vmdir = os.path.join(REPO, ".vm", "m1")
    got = run_phase3b.disk_only_args(vmdir, nic=True)
    want = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", run_phase3b.lab.CPUS, "-m", run_phase3b.lab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={os.path.join(vmdir, 'edk2-vars.fd')}",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-drive", f"if=none,id=target,file={os.path.join(vmdir, 'target.qcow2')},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
        "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
    ]
    check(got == want, "run-phase3b disk_only_args (foreign vmdir)", diff_argv(got, want))
    check(run_phase3b.disk_only_args(vmdir, nic=False) == want[:-4],
          "run-phase3b disk_only_args without the NIC")

    # ---- run-backup / run-zfs ----------------------------------------------
    for mod, label in ((run_backup, "run-backup"), (run_zfs, "run-zfs")):
        got = mod.qemu_args()
        want = [
            "qemu-system-aarch64",
            "-machine", "virt,accel=hvf", "-cpu", "host",
            "-smp", mod.CPUS, "-m", mod.MEM,
            "-drive", f"if=pflash,format=raw,file={code},readonly=on",
            "-drive", f"if=pflash,format=raw,file={mod.VARS}",
            "-display", "none", "-monitor", "none", "-serial", "stdio",
            "-device", "virtio-net-pci,netdev=n0", "-netdev", "user,id=n0",
            "-drive", f"if=none,id=payload,file={mod.PAYLOAD},format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=payload",
            "-cdrom", mod.ISO, "-boot", "d",
        ]
        check(got == want, f"{label} qemu_args", diff_argv(got, want))
        check(mod.ISO == os.path.join(REPO, "out", "os7-arm64.iso"),
              f"{label} medium is out/os7-arm64.iso")

    # ---- verify-console-font ------------------------------------------------
    vlab = vmscreen.Lab("phase3")
    got = vcf.disk_and_camera(vlab)
    want = [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", vlab.CPUS, "-m", vlab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={vlab.vars}",
        "-device", f"virtio-gpu-pci,xres={vmscreen.FB_W},yres={vmscreen.FB_H}",
        "-device", "qemu-xhci", "-device", "usb-kbd",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-qmp", f"unix:{vlab.qmpsock},server,nowait",
        "-drive", f"if=none,id=target,file={vlab.target},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]
    check(got == want, "verify-console-font disk_and_camera", diff_argv(got, want))


# ---------------------------------------------------------------------------
# amd64 — asserted by property; there was no prior shape to preserve.
# ---------------------------------------------------------------------------
def run_amd64():
    print("\n-- amd64: q35 + KVM + OVMF, containerised, no host path leaks")
    vmarch = load("vmarch", "vmarch.py")
    vmscreen = load("vmscreen", "vmscreen.py")
    run_s5 = load("run_s5", "run-s5.py")

    lab = vmscreen.Lab("vmarchck", target_gb=24, iso_as_disk=True, nic=True)
    os.makedirs(lab.dir, exist_ok=True)
    for f in (lab.target, lab.payload):
        open(f, "ab").close()
    try:
        cmdline = run_s5.LIVE_CMDLINE
        check("console=ttyS0,115200" in cmdline,
              "the serial console is ttyS0", cmdline)
        args = lab.qemu_args(cmdline, payload=True)
        check(args[0] == "qemu-system-x86_64", "the binary is qemu-system-x86_64", args[0])
        check(lab.MEM == "8192",
              "amd64 guest memory is 8192 — the GUI product installs beside "
              "a live desktop (#79)", lab.MEM)
        check(args[args.index("-machine") + 1] == "q35,accel=kvm",
              "the machine is q35 with KVM", args[args.index("-machine") + 1])
        code = args[args.index("-drive") + 1]
        check(code == "if=pflash,format=raw,file=/usr/share/OVMF/OVMF_CODE_4M.fd,readonly=on",
              "the firmware is OVMF (non-Secure-Boot build)", code)
        qmp = args[args.index("-qmp") + 1]
        check(qmp.startswith("tcp:0.0.0.0:") and qmp.endswith(",server,nowait"),
              "QMP is served on TCP", qmp)
        ep = lab.arch.qmp_endpoint(lab.qmpsock, lab.name)
        check(isinstance(ep, tuple) and ep[0] == "tcp" and ep[1] == "127.0.0.1",
              "and the harness connects to localhost TCP", repr(ep))

        # No argument may carry a host path: a missed translation is QEMU
        # reporting "no such file" for a file that exists on the host.
        leaks = [a for a in args if REPO.replace("\\", "/") in a.replace("\\", "/")]
        check(not leaks, "no host path leaks into the container argv",
              "; ".join(leaks[:3]))

        tpm = vmarch.SoftTpm(lab.arch, os.path.join(lab.dir, "tpm"))
        targs = tpm.args()
        check("path=/run/swtpm.sock" in targs[1],
              "the TPM control socket is container-local", targs[1])
        check(targs[-1] == "tpm-tis,tpmdev=tpm0",
              "the TPM frontend is q35's tpm-tis", targs[-1])

        argv = lab.arch.command(args + targs, name=lab.name, tpm=tpm)
        check(argv[:3] == ["docker", "run", "--rm"],
              "QEMU is wrapped in docker run", " ".join(argv[:6]))
        check("--device" in argv and argv[argv.index("--device") + 1] == "/dev/kvm",
              "KVM is passed through")
        check("-i" in argv[:argv.index(vmarch.VM_IMAGE)],
              "the container is interactive — serial rides the client's stdio")
        check(f"os7vm-{lab.name}" in argv, "the container has a deterministic name")
        port = qmp.split(":")[2].split(",")[0]
        check(f"127.0.0.1:{port}:{port}" in argv, "the QMP port is published")
        check("OS7_SWTPM=1" in argv, "the container is told to start swtpm")
        mounts = [argv[i + 1] for i, a in enumerate(argv) if a == "-v"]
        check(any(m.endswith(":/tpmstate") for m in mounts),
              "the TPM state directory is a mount", "; ".join(mounts))
        check(any(":/iso:ro" in m for m in mounts), "the medium mount is read-only",
              "; ".join(mounts))
        qemu_half = argv[argv.index(vmarch.VM_IMAGE) + 1:]
        leaks = [a for a in qemu_half if REPO.replace("\\", "/") in a.replace("\\", "/")]
        check(not leaks, "no host path leaks past the image name", "; ".join(leaks[:3]))

        check(lab.iso == os.path.join(REPO, "out", "os7-amd64.iso"),
              "the default medium is out/os7-amd64.iso")
        check(lab.arch.build_hint == "make build-amd64", "the build hint follows")
        try:
            lab.arch.path(os.path.join(REPO, "somewhere-else", "x"))
            check(False, "a path under no mount is refused")
        except SystemExit:
            check(True, "a path under no mount is refused")
    finally:
        shutil.rmtree(lab.dir, ignore_errors=True)


def main():
    if len(sys.argv) > 1 and sys.argv[1] in ("arm64", "amd64"):
        os.environ["OS7_VM_ARCH"] = sys.argv[1]
        os.environ["OS7_QEMU_PREFIX"] = FAKE_PREFIX
        os.environ["OS7_VMARCH_CHECK"] = "1"
        (run_arm64 if sys.argv[1] == "arm64" else run_amd64)()
        print(f"\n  {_ok} ok, {_bad} failed")
        sys.exit(1 if _bad else 0)

    # The two halves run in separate interpreters because the harness modules
    # bind their architecture at import.
    rc = 0
    for arch in ("arm64", "amd64"):
        r = subprocess.run([sys.executable, os.path.abspath(__file__), arch])
        rc |= r.returncode
    print("\ncheck-vm-arch:", "GREEN" if rc == 0 else "RED")
    sys.exit(rc)


if __name__ == "__main__":
    main()
