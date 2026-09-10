#!/usr/bin/env python3
"""
Which machine a harness VM is — the ONE place that decides it.

Until 2026-08-27 every VM harness in this directory hardcoded
`qemu-system-aarch64 -machine virt,accel=hvf` with AAVMF out of Homebrew's
QEMU, which is a description of exactly one host: the Apple Silicon Mac. The
x64 Windows box could run KVM all along (CLAUDE.md — `docker run --device
/dev/kvm` passes it through, measured 2026-08-26 and again 2026-08-27), and
what stood between it and the harnesses was never virtualisation, it was that
the machine type, the accelerator and the firmware were written into eight
files as string literals.

This module owns those three facts, per target architecture, plus the two that
follow from them:

    arch    binary                machine          firmware   serial   TPM device
    arm64   qemu-system-aarch64   virt,accel=hvf   AAVMF      ttyAMA0  tpm-tis-device
    amd64   qemu-system-x86_64    q35,accel=kvm    OVMF       ttyS0    tpm-tis

and, since 2026-09-07, a SECOND firmware column — `VmArch(secure_boot=True)`
picks the enforcing build and the Microsoft-keyed variable store:

    arch    firmware, Secure Boot OFF (default)  firmware, Secure Boot ON
    arm64   edk2-aarch64-code.fd + edk2-*-vars   AAVMF_CODE.secboot.fd + AAVMF_VARS.ms.fd
            (Homebrew's QEMU)                    (fetched from ubuntu:26.04, as spike S4 does)
    amd64   OVMF_CODE_4M.fd + OVMF_VARS_4M.fd    OVMF_CODE_4M.secboot.fd + OVMF_VARS_4M.ms.fd
            (both out of os7-vm:amd64's ovmf package)

Nothing else differs, so every existing harness produces exactly the argv it
produced before. `vmscreen.Lab` and `os7lab` already accept a VmArch INSTANCE,
so a harness that wants Secure Boot needs no change in either of them:

    Lab("sbtest", arch=VmArch(secure_boot=True))

and the EXECUTION VEHICLE, which is the part that is genuinely different
rather than renamed. On the Mac, QEMU is a host process and the harness owns
its stdio. On the Windows box there is no host QEMU and no host KVM — both
live inside Docker Desktop's WSL2 VM — so the amd64 path runs QEMU inside the
`os7-vm:amd64` container (Dockerfile.vmhost, built here on demand) and the
harness drives the docker client's stdio instead. The Console class cannot
tell the difference, which is the point: `-serial stdio` through `docker run
-i` is the same pipe.

Three consequences of the container, each handled here so no harness has to
know:

  * PATHS. QEMU sees the container's filesystem, so every file argument is
    translated through a registered mount table (`mount()` / `path()`). A path
    under no mount is an error, not a guess — the failure mode of a guess is
    QEMU reporting "no such file" for a file that exists.
  * SOCKETS. Docker Desktop's Windows file sharing refuses bind(2) on a
    mounted path, so neither the QMP socket nor swtpm's control socket can
    live in `.vm/` as they do on the Mac. QMP moves to TCP on a published
    localhost port; swtpm runs INSIDE the container (vmhost-entry.sh) with its
    socket on the container's own filesystem and only its STATE on the mount.
  * LIFETIME. Killing the docker CLIENT does not kill the container, and
    Console.close() kills the client. Every container gets a deterministic
    name, a `docker rm -f` preflight clears a stale one, and an atexit handler
    clears the live one on abnormal exit. On the normal path QEMU exits, the
    container exits with it (`--rm`), and both cleanups are no-ops.

WHAT WAS MEASURED, AND WHERE (docs/SESSION-VM-HARNESS-PORT.md): the amd64
branch ran on the x64 Windows host. The arm64 branch was NOT executed by the
session that wrote this — it is held byte-identical to the pre-port
construction by `check-vm-arch.py`, which rebuilds every harness's old command
line from the old literals and requires the new code to produce the same argv.
That check needs neither QEMU nor Docker and runs on both hosts.

`OS7_VM_ARCH=arm64|amd64` overrides the host default (Apple Silicon → arm64,
x86_64 → amd64), which is how one host builds the other's command lines for
the self-test.
"""
import atexit
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import qemu_prefix, run   # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TESTING = os.path.dirname(os.path.abspath(__file__))

VM_IMAGE = "os7-vm:amd64"

ARCHES = ("arm64", "amd64")


def pick_arch():
    """The target architecture: the override, else the host's own.

    The host default is right because the two accelerators only virtualise
    their own architecture — HVF runs arm64 guests on Apple Silicon, KVM in
    the WSL2 VM runs x86_64 guests on the x64 box. Emulating the other arch
    is possible and useless: a TCG boot of this image takes longer than the
    answer is worth, and no harness here is calibrated for it.
    """
    a = os.environ.get("OS7_VM_ARCH")
    if a:
        if a not in ARCHES:
            raise SystemExit(f"OS7_VM_ARCH={a!r} — must be one of {'/'.join(ARCHES)}")
        return a
    m = platform.machine().lower()
    if m in ("arm64", "aarch64"):
        return "arm64"
    if m in ("x86_64", "amd64"):
        return "amd64"
    raise SystemExit(f"cannot derive a VM architecture from host machine {m!r}; "
                     f"set OS7_VM_ARCH to one of {'/'.join(ARCHES)}")


_cleanup_containers = set()

# check-vm-arch.py sets this: it builds command lines for BOTH architectures on
# whatever host it runs on and must not talk to docker while doing it. Nothing
# else may set it — a VM started this way would miss its image check and its
# stale-container cleanup.
CHECK_MODE = os.environ.get("OS7_VMARCH_CHECK") == "1"


def _remove_container(name):
    if CHECK_MODE:
        return
    try:
        subprocess.run(["docker", "rm", "-f", name],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        pass


def _cleanup_all():
    for name in list(_cleanup_containers):
        _remove_container(name)


atexit.register(_cleanup_all)


class VmArch:
    """Everything about a VM that depends on the target architecture.

    `secure_boot` picks the OTHER firmware pair (2026-09-07). It is a
    constructor argument and not an environment variable on purpose: whether a
    run enforced Secure Boot has to be visible in the code that started the
    run, because six months later "was that measured with Secure Boot on?" is
    a question no environment answers. `OS7_VM_ARCH` exists because one host
    must be able to build the other's command lines; nothing needs to flip
    this from outside.

    Nothing else changes with it — machine, accelerator, serial, TPM and
    vehicle are identical — so every existing harness keeps producing exactly
    the argv `check-vm-arch.py` holds it to.
    """

    # Shared with installer/spikes/run-s4.py, which downloads the same AAVMF
    # into the same directory. Two copies of a 4 MB firmware would be harmless
    # and two DIFFERENT copies would not.
    FIRMWARE_CACHE = os.path.join(REPO, ".vm", "firmware")

    def __init__(self, arch=None, secure_boot=False):
        self.arch = arch or pick_arch()
        self.secure_boot = bool(secure_boot)
        if self.arch == "arm64":
            self.qemu_binary = "qemu-system-aarch64"
            self.machine = "virt,accel=hvf"
            self.serial_tty = "ttyAMA0"
            self.tpm_device = "tpm-tis-device"
            self.containerised = False
            self.docker_platform = "linux/arm64"
            self.build_image = "os7-build:arm64"
        elif self.arch == "amd64":
            self.qemu_binary = "qemu-system-x86_64"
            self.machine = "q35,accel=kvm"
            self.serial_tty = "ttyS0"
            # tpm-tis, not tpm-tis-device: the arm `virt` machine attaches the
            # TPM to the sysbus, q35 attaches it to the LPC bus, and QEMU names
            # the two frontends differently. Same swtpm behind both.
            self.tpm_device = "tpm-tis"
            self.containerised = True
            self.docker_platform = "linux/amd64"
            self.build_image = "os7-build:amd64"
        else:
            raise SystemExit(f"unknown VM architecture {self.arch!r}")
        self._mounts = []          # (host_abs, container_dir, ro)
        self._image_ready = False
        self._http = None          # (host_dir, port) once serve_http() is called
        self._http_proc = None

    # -- what the harness prints and tests ----------------------------------
    @property
    def build_hint(self):
        return f"make build-{self.arch}"

    @property
    def default_mem(self):
        """Guest memory in MiB, as a string for -m.

        4096 on arm64 is the proven value and stays. 8192 on amd64 because the
        amd64 medium is the GUI product — a live GNOME session runs beside the
        install, which is #79's territory — and this harness exists to test
        the update train, not to find the memory floor. Finding the floor is a
        measurement of its own; do not lower this in passing.
        """
        return "4096" if self.arch == "arm64" else "8192"

    def iso_default(self):
        return os.path.join(REPO, "out", f"os7-{self.arch}.iso")

    # -- the mount table ------------------------------------------------------
    def mount(self, host_dir, container_dir=None, ro=False):
        """Declare that `host_dir` is visible in the container at
        `container_dir` (derived from the host path when not given). On the
        host-process path this is bookkeeping only — path() stays the identity
        — but it is recorded on both paths so the self-test can check the
        table itself."""
        host_abs = os.path.abspath(host_dir)
        for h, c, _ in self._mounts:
            if h == host_abs:
                return
        if container_dir is None:
            container_dir = "/m%08x" % (zlib.crc32(host_abs.encode()) & 0xFFFFFFFF)
        self._mounts.append((host_abs, container_dir, ro))

    def path(self, p):
        """The path QEMU must be handed for the host file `p`.

        Identity on the host-process path. In the container, `p` must be under
        a registered mount — a path that is not gets an error HERE, where the
        message can name the file, rather than from QEMU as "no such file or
        directory" about a path that plainly exists on the host.
        """
        if not self.containerised:
            return p
        ap = os.path.abspath(p)
        for h, c, _ in self._mounts:
            if ap == h:
                return c
            if ap.startswith(h + os.sep):
                rel = os.path.relpath(ap, h).replace(os.sep, "/")
                return f"{c}/{rel}"
        raise SystemExit(f"vmarch: {p} is under no registered VM mount — "
                         f"mounts: {[(h, c) for h, c, _ in self._mounts]}")

    # -- the command line -----------------------------------------------------
    def base_args(self):
        return [self.qemu_binary, "-machine", self.machine, "-cpu", "host"]

    # SECURE BOOT IS A PROPERTY OF THE PAIR, NOT OF EITHER FILE.
    #
    # The enforcing OVMF build with the KEY-LESS variable store leaves
    # SecureBoot at 0 — no PK, so nothing to enforce against — and the
    # non-enforcing build with the MS-keyed store enforces nothing either. Only
    # both together are Secure Boot on, which is why `firmware_code()` and
    # `prepare_vars()` read the same flag off the same object instead of taking
    # an argument each: a caller cannot get one of them and not the other.
    #
    # And on amd64 the code file is LITERALLY the same file both ways round:
    # /usr/share/OVMF/OVMF_CODE_4M.ms.fd is a symlink to
    # OVMF_CODE_4M.secboot.fd (measured 2026-09-07 in os7-vm:amd64), so the
    # ".ms" name says nothing about the code and everything about the vars it
    # is meant to be paired with. The enforcing build is named by what it is.
    def firmware_code(self):
        if self.arch == "arm64":
            if self.secure_boot:
                return os.path.join(self.FIRMWARE_CACHE, "AAVMF_CODE.secboot.fd")
            return os.path.join(qemu_prefix(), "share", "qemu", "edk2-aarch64-code.fd")
        if self.secure_boot:
            return "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"
        # The non-Secure-Boot build stays the default. It was chosen when the
        # OS/7 medium's GRUB was unsigned and the MS-keyed firmware refused to
        # boot the thing under test; since 1.0.0.192 the amd64 medium boots
        # signed (docs/SESSION-SECUREBOOT-MEDIUM.md §7), so this is no longer
        # a necessity — but it is still what every existing harness ran on and
        # what check-vm-arch.py holds them to. Flipping it would silently
        # re-measure the whole suite on different firmware.
        return "/usr/share/OVMF/OVMF_CODE_4M.fd"

    def firmware_args(self, vars_path):
        return [
            "-drive", f"if=pflash,format=raw,file={self.firmware_code()},readonly=on",
            "-drive", f"if=pflash,format=raw,file={self.path(vars_path)}",
        ]

    def ensure_firmware(self):
        """Fetch the Secure Boot AAVMF, once. arm64 + secure_boot only.

        Homebrew's QEMU ships no Secure Boot aarch64 firmware — `edk2-aarch64-
        code.fd` carries no keys and does not enforce — so it comes out of
        ubuntu:26.04's `qemu-efi-aarch64`, which is where spike S4 got it and
        how S4 booted under the Microsoft keys in the first place. amd64 needs
        nothing: the `ovmf` package inside os7-vm:amd64 has both pairs.
        """
        if self.arch != "arm64" or not self.secure_boot or CHECK_MODE:
            return
        code, vars_tpl = self.firmware_code(), self._vars_template()
        if os.path.exists(code) and os.path.exists(vars_tpl):
            return
        os.makedirs(self.FIRMWARE_CACHE, exist_ok=True)
        print("    fetching qemu-efi-aarch64 (Secure Boot firmware) …")
        run("docker", "run", "--rm", "--platform", "linux/arm64",
            "-v", f"{self.FIRMWARE_CACHE}:/fw", "ubuntu:26.04", "bash", "-c",
            "set -e; apt-get update -qq >/dev/null 2>&1; "
            "apt-get download qemu-efi-aarch64 >/dev/null 2>&1; "
            "dpkg-deb -x qemu-efi-aarch64_*.deb /x; cp /x/usr/share/AAVMF/* /fw/",
            stdout=subprocess.DEVNULL)
        for f in (code, vars_tpl):
            if not os.path.exists(f):
                raise SystemExit(f"firmware extraction did not produce {f}")

    def _vars_template(self):
        """Where a fresh variable store is copied FROM.

        arm64 non-Secure-Boot returns whichever of the two EDK2 names this
        QEMU ships; the others are single files. amd64's are container paths.
        """
        if self.arch == "arm64":
            if self.secure_boot:
                return os.path.join(self.FIRMWARE_CACHE, "AAVMF_VARS.ms.fd")
            pre = qemu_prefix()
            for c in ("edk2-arm-vars.fd", "edk2-aarch64-vars.fd"):
                src = os.path.join(pre, "share", "qemu", c)
                if os.path.exists(src):
                    return src
            raise SystemExit("no EDK2 vars template found")
        return ("/usr/share/OVMF/OVMF_VARS_4M.ms.fd" if self.secure_boot
                else "/usr/share/OVMF/OVMF_VARS_4M.fd")

    def vars_marker(self, vars_path):
        """The file recording which firmware a variable store belongs to."""
        return os.path.abspath(vars_path) + ".firmware"

    def prepare_vars(self, vars_path):
        """Put a writable firmware variable store at `vars_path`.

        AN EXISTING STORE IS KEPT, and that is load-bearing: TPM enrolment and
        any enrolled key live in it, so a bench that boots twice must boot the
        second time with what the first one wrote. Which is also the trap this
        method now refuses to walk into.

        The two variable stores are the same SIZE (540 672 bytes both) and
        differ only in content, so reusing a key-less store for a Secure Boot
        run gives a machine that boots happily with SecureBoot=0 while the
        harness reports having tested Secure Boot. Nothing would fail. The
        marker beside the store is what makes that mismatch loud; its absence
        means `plain`, because that is the only mode that existed before
        2026-09-07 and every bench under .vm/ predates it.
        """
        want = "secureboot" if self.secure_boot else "plain"
        marker = self.vars_marker(vars_path)
        if os.path.exists(vars_path):
            got = "plain"
            if os.path.exists(marker):
                got = (open(marker).read().strip() or "plain")
            if got != want:
                raise SystemExit(
                    f"{vars_path} is a {got!r} firmware variable store and this "
                    f"run wants {want!r}.\nThe two are the same size and differ "
                    f"only in content, so reusing one would report a Secure Boot "
                    f"result from firmware that enforces nothing.\nDelete "
                    f"{vars_path} (and {marker}) to start that bench's firmware "
                    f"again, or use a different bench.")
            return

        self.ensure_firmware()
        tpl = self._vars_template()
        d = os.path.dirname(os.path.abspath(vars_path))
        os.makedirs(d, exist_ok=True)
        if self.arch == "arm64":
            shutil.copy(tpl, vars_path)
        else:
            self.ensure_image()
            run("docker", "run", "--rm", "-v", f"{d}:/vmdir", VM_IMAGE,
                "cp", tpl, f"/vmdir/{os.path.basename(vars_path)}")
        if not os.path.exists(vars_path):
            raise SystemExit(f"the {want} vars template did not arrive at {vars_path}")
        with open(marker, "w") as fh:
            fh.write(want + "\n")

    def qmp_args(self, qmpsock, name):
        """The -qmp server argument. Unix socket on the host path; TCP in the
        container, because the socket cannot live on the mount (see header)."""
        if not self.containerised:
            return ["-qmp", f"unix:{qmpsock},server,nowait"]
        port = self.qmp_port(name)
        return ["-qmp", f"tcp:0.0.0.0:{port},server,nowait"]

    def qmp_endpoint(self, qmpsock, name):
        """What Qmp() connects to for the server qmp_args() declared."""
        if not self.containerised:
            return qmpsock
        return ("tcp", "127.0.0.1", self.qmp_port(name))

    def qmp_port(self, name):
        # Deterministic per lab name so a harness can be re-run against a VM
        # that is already up, and so two labs do not collide with each other.
        # Locally unique is all this has to be.
        return 4640 + (zlib.crc32(name.encode()) % 300)

    def serve_http(self, host_dir, port):
        """Serve `host_dir` to the GUEST at http://10.0.2.2:<port>/ — the
        local repository transport for the end-to-end update test.

        The guest's 10.0.2.2 is slirp's host side, which is wherever QEMU's
        network stack lives: the Mac itself on the host-process path, the
        os7-vm CONTAINER on the containerised one. So on the host path a
        python http.server is started here as a sibling process, and on the
        container path the server is started by vmhost-entry.sh inside the
        SAME container as QEMU — command() carries the port and the read-only
        mount in. Registered once; every subsequent boot serves it."""
        self._http = (os.path.abspath(host_dir), int(port))
        if not self.containerised and self._http_proc is None:
            self._http_proc = subprocess.Popen(
                [sys.executable, "-m", "http.server", str(port),
                 "--directory", self._http[0], "--bind", "127.0.0.1"],
                stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
            atexit.register(self._http_proc.terminate)

    def guest_host_url(self, port):
        """What the GUEST calls the machine QEMU runs on."""
        return f"http://10.0.2.2:{port}"

    def command(self, args, name, tpm=None):
        """The argv Console gets: the QEMU args themselves on the host path,
        or the `docker run` that carries them on the container path."""
        if not self.containerised:
            return args
        self.ensure_image()
        cname = f"os7vm-{name}"
        _remove_container(cname)               # a stale one, from an abort
        _cleanup_containers.add(cname)
        argv = ["docker", "run", "--rm", "-i", "--name", cname,
                "--device", "/dev/kvm"]
        for h, c, ro in self._mounts:
            argv += ["-v", f"{h}:{c}" + (":ro" if ro else "")]
        if tpm is not None and tpm.enabled:
            os.makedirs(tpm.state_dir, exist_ok=True)
            argv += ["-e", "OS7_SWTPM=1", "-v", f"{tpm.state_dir}:/tpmstate"]
        if self._http is not None:
            argv += ["-e", f"OS7_HTTP_PORT={self._http[1]}",
                     "-e", "OS7_HTTP_DIR=/os7http",
                     "-v", f"{self._http[0]}:/os7http:ro"]
        for a in args:
            m = re.match(r"tcp:0\.0\.0\.0:(\d+),server", a)
            if m:
                argv += ["-p", f"127.0.0.1:{m.group(1)}:{m.group(1)}"]
        argv += [VM_IMAGE] + args
        return argv

    # -- utilities that need QEMU's toolbox ----------------------------------
    def _docker_util(self, cmd, extra_mounts=()):
        self.ensure_image()
        argv = ["docker", "run", "--rm"]
        for h, c, ro in self._mounts:
            argv += ["-v", f"{h}:{c}" + (":ro" if ro else "")]
        for h, c, ro in extra_mounts:
            argv += ["-v", f"{h}:{c}" + (":ro" if ro else "")]
        run(*argv, VM_IMAGE, *cmd)

    def create_disk(self, path, gb):
        if not self.containerised:
            run("qemu-img", "create", "-f", "qcow2", path, f"{gb}G",
                stdout=subprocess.DEVNULL)
            return
        self._docker_util(["qemu-img", "create", "-q", "-f", "qcow2",
                           self.path(path), f"{gb}G"])
        if not os.path.exists(path):
            raise SystemExit(f"qemu-img did not produce {path}")

    def make_payload_iso(self, stage_dir, out_path, label):
        """An ISO9660 volume from a staged directory.

        hdiutil on the Mac (BUILD-NOTES #28: at most ONE dot per filename
        survives), xorriso in the container. xorriso's Joliet names do not
        share that quirk, but every payload in this repository already keeps
        to one dot, and staying within the stricter rule is what keeps a
        payload that works on one host working on the other.
        """
        if os.path.exists(out_path):
            os.remove(out_path)
        if not self.containerised:
            run("hdiutil", "makehybrid", "-iso", "-joliet",
                "-default-volume-name", label, "-o", out_path, stage_dir,
                stdout=subprocess.DEVNULL)
            return
        outdir = os.path.dirname(os.path.abspath(out_path))
        self._docker_util(
            ["xorriso", "-as", "mkisofs", "-quiet", "-iso-level", "3", "-J",
             "-V", label, "-o", f"/payloadout/{os.path.basename(out_path)}",
             "/payloadstage"],
            extra_mounts=[(os.path.abspath(stage_dir), "/payloadstage", True),
                          (outdir, "/payloadout", False)])
        if not os.path.exists(out_path):
            raise SystemExit(f"xorriso did not produce {out_path}")

    def ensure_image(self):
        """Build os7-vm:amd64. Once per process; the layer cache makes an
        up-to-date rebuild a one-second no-op, and always building is what
        keeps a harness run from using yesterday's image after
        Dockerfile.vmhost changed."""
        if not self.containerised or self._image_ready or CHECK_MODE:
            return
        run("docker", "build", "-q", "-t", VM_IMAGE,
            "-f", os.path.join(TESTING, "Dockerfile.vmhost"), TESTING,
            stdout=subprocess.DEVNULL)
        self._image_ready = True


class SoftTpm:
    """A software TPM 2.0, or nothing at all when `enabled` is false.

    Lifted from installer/spikes/run-s4.py, which is where the two non-obvious
    flags were made to work, and then split by execution vehicle: on the host
    path swtpm is a sibling process sharing a unix socket under `.vm/`; on the
    container path it runs inside the SAME container as QEMU (vmhost-entry.sh)
    because the control socket cannot cross Docker Desktop's file sharing —
    only the state directory does, so enrolment survives across boots exactly
    as it does on the Mac.
    """

    def __init__(self, arch, state_dir, enabled=True):
        self.arch = arch
        self.state_dir = state_dir
        self.enabled = enabled
        self.proc = None
        self.sock = os.path.join(state_dir, "swtpm-sock")

    def __enter__(self):
        if not self.enabled:
            return self
        os.makedirs(self.state_dir, exist_ok=True)
        if self.arch.containerised:
            # vmhost-entry.sh starts swtpm when command() sets OS7_SWTPM=1;
            # there is nothing to start here and nothing to wait for.
            return self
        if not shutil.which("swtpm"):
            raise SystemExit("swtpm not found — brew install swtpm")
        if os.path.exists(self.sock):
            os.remove(self.sock)
        # not-need-init,startup-clear: AAVMF on arm64 does not reliably send
        # TPM2_Startup, and an un-started TPM answers every command with
        # TPM_RC_INITIALIZE. run-s4.py found this; it is not guesswork.
        self.proc = subprocess.Popen(
            ["swtpm", "socket", "--tpm2",
             "--tpmstate", f"dir={self.state_dir}",
             "--ctrl", f"type=unixio,path={self.sock}",
             "--flags", "not-need-init,startup-clear"],
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        for _ in range(100):
            if os.path.exists(self.sock):
                break
            time.sleep(0.05)
        else:
            raise SystemExit("swtpm never created its control socket")
        return self

    def __exit__(self, *exc):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except Exception:
                self.proc.kill()

    def args(self):
        if not self.enabled:
            return []
        sock = "/run/swtpm.sock" if self.arch.containerised else self.sock
        return ["-chardev", f"socket,id=chrtpm,path={sock}",
                "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", f"{self.arch.tpm_device},tpmdev=tpm0"]
