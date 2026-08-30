#!/usr/bin/env python3
"""
os7lab — a machine that outlives the process that started it.

Every VM harness in this directory is a batch run: a Python process opens
QEMU's stdio, walks a fixed script, and the machine dies with the process. That
is right for a gate — `run-s5.py all` must be one sitting or it proves nothing —
and it is the wrong shape for the other half of testing, which is *sitting at a
machine and asking it things*. Under the batch shape, "what does
Get-OS7BackupStatus actually print on a real install" costs a boot, and if no
disk is lying around it costs the 25-minute install that produces one
(docs/SESSION-UPDATE-DELIVERY.md §103).

This is a workbench instead. The VM runs detached — a container on the x64
Windows host, a background process on the Mac — and every command here connects
to a machine that is already up:

    ./os7lab.py up manual              start .vm/manual's installed disk
    ./os7lab.py console manual --read  what the serial line has said so far
    ./os7lab.py login manual           get from a cold console to SSH
    ./os7lab.py exec manual 'Get-OS7Version | Format-List'
    ./os7lab.py shot manual desktop    a PNG of what is on the screen
    ./os7lab.py snapshot manual clean  freeze the machine (0.7 s, measured)
    ./os7lab.py restore manual clean   and go back to it
    ./os7lab.py down manual

THREE CHANNELS, AND THEY ARE NOT INTERCHANGEABLE. Each one presupposes more of
the machine than the last, so which one answers a question is part of the
answer:

  * THE SERIAL LINE presupposes a kernel. It is the only channel before the
    first login — the initramfs passphrase prompt, `os7-setup`, a machine with
    no network — and the only one that can see a boot fail. It is a text pipe:
    no exit code, no stderr, 80x24, and PSReadLine repainting over all of it.
  * SSH presupposes network, sshd, PAM and an account. In exchange it gives a
    real exit code, stdout and stderr apart, and no quoting limit at all
    (`-EncodedCommand`, so a command may contain any quote — unlike run-s5.py's
    ps(), which must refuse a single quote). A machine that answers over SSH
    has already proved four things; a machine that does NOT answer has proved
    nothing about any of them, which is why the serial line stays.
  * QMP presupposes only QEMU. Screendump and input, so the GUI — which on
    amd64 IS the product, and which docs/HANDOFF.md §6 records as never having
    been seen.

WHY THE SERIAL LINE IS A FILE AND A SOCKET AT ONCE. Detaching costs the
harness QEMU's stdio, and `-serial tcp:...,server,nowait` alone would throw
away everything printed before something connects — which is the whole boot.
So the chardev carries BOTH: `logfile=` records every byte from power-on
whether anyone is listening or not, and the socket is how bytes get IN. Reads
come from the file, writes go to the socket. A disconnect loses nothing.

WHAT THIS IS NOT. It is for LOOKING, and looking changes the machine — forty
typed commands later it is not the machine that came off the installer, which
is BUILD-NOTES #93 in a new place. Anything that is to count as evidence must
still be reproducible by a harness from a named snapshot. The bench makes
findings cheap to FIND; it does not make them true.

NOTHING HERE TOUCHES THE EXISTING HARNESSES. `check-vm-arch.py` holds their
arm64 command lines byte-identical to the pre-port construction, and no Mac is
available to re-measure them; so the bench builds its own command line beside
theirs, out of the same `vmarch.py` facts, and `run-s5.py`, `run-phase3.py` and
`shoot-manual.py` are not edited.
"""
import argparse
import base64
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import QUERY_RX, terminal_reply, CHAR_DELAY, LINE_PAUSE   # noqa: E402
from vmarch import VmArch, SoftTpm, VM_IMAGE                             # noqa: E402
from vmscreen import Qmp, read_ppm, write_png, FB_W, FB_H                # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VMDIR = os.path.join(REPO, ".vm")

# The account run-s5.py's installs carry. A bench opened on some other disk can
# be told otherwise through the environment; these are the defaults because
# they are what is on the disks this repository already has.
USER = os.environ.get("OS7LAB_USER", "os7admin")
PASSWORD = os.environ.get("OS7LAB_PASSWORD", "os7-s5-password")
PASSPHRASE = os.environ.get("OS7LAB_PASSPHRASE", "os7-s5-passphrase")

PROMPT = r"PS [^\r\n]*>"
BASH_PROMPT = r"bash-\d[\d.]*[#$]"


# ---------------------------------------------------------------------------
# The bench: where one machine's state lives, and which ports reach it.
# ---------------------------------------------------------------------------
class Bench:
    """One long-lived VM.

    The directory layout is `vmscreen.Lab`'s ON PURPOSE — target.qcow2,
    edk2-vars.fd, tpm/ — so a bench can be opened on a machine some other
    harness produced. `./os7lab.py up s5` runs the disk run-s5.py's gate
    installed, without copying five gigabytes anywhere.
    """

    CPUS = "4"

    def __init__(self, name, arch=None):
        self.name = name
        self.arch = arch if isinstance(arch, VmArch) else VmArch(arch)
        self.MEM = self.arch.default_mem
        self.dir = os.path.join(VMDIR, name)
        self.target = os.path.join(self.dir, "target.qcow2")
        self.vars = os.path.join(self.dir, "edk2-vars.fd")
        self.tpmdir = os.path.join(self.dir, "tpm")
        self.snapdir = os.path.join(self.dir, "snapshots")
        self.shots = os.path.join(self.dir, "shots")
        self.serial_log = os.path.join(self.dir, "bench.console.log")
        self.statefile = os.path.join(self.dir, "lab.json")
        self.qmpsock = os.path.join(self.dir, "qmp.sock")
        self.sshdir = os.path.join(self.dir, "ssh")
        self.key = os.path.join(self.sshdir, "id_ed25519")
        self.kernel = os.path.join(self.dir, "vmlinuz")
        self.initrd = os.path.join(self.dir, "initrd")
        self.arch.mount(self.dir, "/vm")
        self.container = "os7lab-" + name

    # -- ports ---------------------------------------------------------------
    # Deterministic per bench name, so every invocation of this script finds the
    # same machine without being told, and two benches do not collide. QMP uses
    # vmarch's own function so the endpoint helper there stays the authority.
    def port(self, kind):
        if kind == "qmp":
            return self.arch.qmp_port(self.name)
        base = {"serial": 5700, "ssh": 6700}[kind]
        return base + (zlib.crc32((self.name + kind).encode()) % 300)

    # -- state ---------------------------------------------------------------
    def state(self):
        if not os.path.exists(self.statefile):
            return None
        try:
            with open(self.statefile, encoding="utf-8") as f:
                return json.load(f)
        except (ValueError, OSError):
            return None

    def write_state(self, **kw):
        os.makedirs(self.dir, exist_ok=True)
        st = self.state() or {}
        st.update(kw)
        with open(self.statefile, "w", encoding="utf-8") as f:
            json.dump(st, f, indent=2)
        return st

    def clear_state(self):
        if os.path.exists(self.statefile):
            os.remove(self.statefile)

    # -- is it up? -----------------------------------------------------------
    def running(self):
        """Whether the VM is alive — ASKED OF THE VEHICLE, not of the state
        file. A state file says what was started; docker and the kernel say
        what is running, and those two disagree after a crash or a reboot."""
        if self.arch.containerised:
            p = subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}",
                                self.container], capture_output=True, text=True)
            return p.returncode == 0 and p.stdout.strip() == "true"
        st = self.state()
        pid = (st or {}).get("pid")
        if not pid:
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def require_running(self):
        if not self.running():
            raise SystemExit("bench " + self.name + " is not up -- "
                             "./os7lab.py up " + self.name)

    def require_down(self, what):
        if self.running():
            raise SystemExit("bench " + self.name + " is up; " + what +
                             " needs it stopped — ./os7lab.py down " + self.name)

    def qmp(self, timeout=60):
        return Qmp(self.arch.qmp_endpoint(self.qmpsock, self.name), timeout=timeout)


# ---------------------------------------------------------------------------
# The serial line: read from the log file, write to the socket.
# ---------------------------------------------------------------------------
class Serial:
    """The console of a machine nobody is holding open.

    `vmconsole.Console` owns a subprocess and reads its stdout. This one owns
    nothing: it tails the chardev's logfile for what the machine has said —
    including everything it said before this process existed — and opens the
    chardev's socket only to type. Both halves are of the SAME chardev, so what
    is typed appears in the log like everything else.

    The terminal-query answering is vmconsole's table, imported rather than
    copied: an unanswered DSR kills PowerShell within a second of the prompt
    appearing (BUILD-NOTES #16), and there must be exactly one copy of those
    replies in this repository.
    """

    def __init__(self, bench, connect=True):
        self.bench = bench
        self.path = bench.serial_log
        self.sock = None
        self.scan = bytearray()
        self.answering = False
        self._qpos = None          # how far answer_queries has scanned
        self._thread = None
        self._stop = False
        if connect:
            self.connect()

    # -- answering, and WHY IT IS A THREAD -----------------------------------
    # A terminal query has to be answered in milliseconds or the answer is not
    # an answer, it is a keystroke somewhere else. The first version of this
    # answered from expect()'s poll loop, so a `ESC[6n` that agetty emitted
    # while the user name was being typed got its reply AFTER the name had been
    # submitted -- straight into the password field. login failed, agetty
    # respawned, and the log showed a clean user name followed by six cursor
    # reports and a fresh prompt. `vmconsole.Console` has a reader thread for
    # exactly this reason; a bench that reads a file instead of a stream still
    # needs one.
    def start_answering(self):
        if self._thread is not None:
            return
        self.answering = True
        self._qpos = self.size()        # only what happens from NOW
        self._stop = False
        self._thread = threading.Thread(target=self._pump, daemon=True)
        self._thread.start()

    def _pump(self):
        while not self._stop:
            try:
                self.answer_queries()
            except Exception:           # noqa: BLE001 - a dead socket ends the run elsewhere
                pass
            time.sleep(0.05)

    def connect(self, timeout=30):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            try:
                s = socket.create_connection(("127.0.0.1", self.bench.port("serial")), 5)
                s.settimeout(1.0)
                self.sock = s
                return
            except OSError as e:
                last = e
                time.sleep(0.3)
        raise SystemExit("the serial socket never answered on port %d: %s"
                         % (self.bench.port("serial"), last))

    # -- reading -------------------------------------------------------------
    def size(self):
        try:
            return os.path.getsize(self.path)
        except OSError:
            return 0

    def read(self, since=0):
        """Every byte the machine has printed since offset `since`."""
        try:
            with open(self.path, "rb") as f:
                f.seek(since)
                return f.read()
        except OSError:
            return b""

    def text(self, since=0):
        return self.read(since).decode("utf-8", "replace")

    def answer_queries(self, since=None):
        """Reply to the terminal queries in everything NOT YET SCANNED.

        THE CURSOR IS THE WHOLE THING, and getting it wrong is not a slow
        answer, it is a flood. `vmconsole.Console` reads a stream and consumes
        it once; a log file is re-readable, so the first version of this
        re-scanned the same bytes on every poll and answered every query
        again — hundreds of `ESC[24;80R` typed into the login field, which
        agetty took as the user name. The run reached no password prompt, and
        the cause was six lines of cursor reports in a log full of them.

        So `_qpos` advances past what has been scanned, and it starts near the
        END of the file rather than at zero: replying now to a query the boot
        asked four minutes ago types into whatever is on the screen today.
        """
        if not self.answering:
            return
        if self._qpos is None:
            self._qpos = max(0, self.size() - 2048)
        data = self.read(self._qpos)
        if not data:
            return
        self._qpos += len(data)
        self.scan += data
        while True:
            m = QUERY_RX.search(self.scan)
            if not m:
                break
            reply = terminal_reply(m)
            if reply:
                self.write(reply)
            del self.scan[:m.end()]
        if len(self.scan) > 4096:
            del self.scan[:-64]

    def expect(self, patterns, timeout, label="", since=0):
        """Wait for any of `patterns` in the output past `since`."""
        if isinstance(patterns, str):
            patterns = [patterns]
        rx = [re.compile(p, re.I) for p in patterns]
        deadline = time.time() + timeout
        note = 0.0
        while time.time() < deadline:
            t = self.text(since)
            for i, r in enumerate(rx):
                if r.search(t):
                    return i
            now = time.time()
            if now - note > 30:
                note = now
                print("    ... still waiting for %s (%ds left)"
                      % (label or patterns[0], int(deadline - now)), flush=True)
            time.sleep(0.25)
        raise SystemExit("TIMEOUT waiting for %s\n--- last output ---\n%s"
                         % (label or patterns, self.text(since)[-1500:]))

    # -- writing -------------------------------------------------------------
    def write(self, data):
        if self.sock is None:
            self.connect()
        try:
            self.sock.sendall(data)
        except OSError as e:
            raise SystemExit("the serial socket went away: %s" % e)

    def send(self, text, enter=True):
        """One character at a time, CR for Enter — vmconsole's rules.

        Bytes sent faster than the console consumes them arrive corrupted
        (docs/HANDOFF.md §5), and LF is not the Enter key to a PSReadLine in
        raw mode: it accumulates a line that is never submitted, while the echo
        of it still matches whatever was expected (BUILD-NOTES #16).
        """
        data = (text + ("\r" if enter else "")).encode()
        for b in data:
            self.write(bytes([b]))
            time.sleep(CHAR_DELAY)
        time.sleep(LINE_PAUSE)

    def settle(self, quiet=2.0, timeout=60):
        deadline = time.time() + timeout
        last = -1
        since = time.time()
        while time.time() < deadline:
            n = self.size()
            if n != last:
                last = n
                since = time.time()
            elif time.time() - since >= quiet:
                return
            time.sleep(0.2)

    def close(self):
        self._stop = True
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None


# ---------------------------------------------------------------------------
# The command line, and the two ways of putting it on a host.
# ---------------------------------------------------------------------------
def qemu_args(b, iso=None, cmdline=None, tpm=None, gui=True, medium_as_disk=True):
    """The bench's QEMU arguments.

    Written here rather than taken from `vmscreen.Lab.qemu_args`, and the
    difference is not cosmetic: that one is `-serial stdio` with no network
    forward and no pointing device, which is exactly what a batch harness
    wants and none of what a bench does. Both are built out of the same
    `vmarch.py` facts, which is where the arch-dependent part lives.
    """
    p = b.arch.path
    args = b.arch.base_args() + ["-smp", b.CPUS, "-m", b.MEM]
    args += b.arch.firmware_args(b.vars)
    args += ["-display", "none", "-monitor", "none"]

    # BOTH HALVES OF THE SERIAL LINE ARE ONE CHARDEV. logfile= is what makes a
    # detached VM readable at all: it records from power-on whether anything is
    # connected or not, so the boot is still there to read when a later command
    # opens the socket. wait=off so QEMU does not block waiting for a listener.
    args += ["-chardev",
             "socket,id=os7ser,host=0.0.0.0,port=%d,server=on,wait=off,logfile=%s"
             % (b.port("serial"), p(b.serial_log)),
             "-serial", "chardev:os7ser"]
    args += b.arch.qmp_args(b.qmpsock, b.name)

    if gui:
        # -vga none FIRST, AND IT IS THE DIFFERENCE BETWEEN SEEING THE DESKTOP
        # AND NOT. Without it q35 keeps its default VGA adapter and the virtio
        # GPU is a SECOND card: the guest gets /dev/dri/card0 and card1, mutter
        # picks one, QMP's screendump reads the other, and a running GNOME
        # session photographs as "Guest has not initialized the display (yet)."
        # Measured on the first desktop machine this bench installed —
        # gnome-shell was up and logging about both cards while the picture was
        # black.
        #
        # usb-tablet, not usb-mouse: a tablet reports ABSOLUTE coordinates, so
        # a click can be aimed at a pixel on a screendump. A relative mouse
        # would need the guest's own pointer position, which nothing here can
        # see, and every click would be aimed by dead reckoning.
        args += ["-vga", "none",
                 "-device", "virtio-gpu-pci,xres=%d,yres=%d" % (FB_W, FB_H),
                 "-device", "qemu-xhci", "-device", "usb-kbd",
                 "-device", "usb-tablet"]

    # hostfwd is the SSH channel. Slirp is deterministic (the guest is
    # 10.0.2.15, the gateway 10.0.2.2), so the forward can be declared before
    # the machine exists.
    args += ["-device", "virtio-net-pci,netdev=n0",
             "-netdev", "user,id=n0,hostfwd=tcp:0.0.0.0:%d-:22" % b.port("ssh")]

    if iso:
        if medium_as_disk:
            # First, so it enumerates before the target: Setup lists disks in
            # kernel-name order, and L12 is about the medium being listed and
            # never selectable. A raw ISO on virtio-blk boots as a USB stick.
            args += ["-drive", "if=none,id=live,file=%s,format=raw,readonly=on" % p(iso),
                     "-device", "virtio-blk-pci,drive=live,serial=os7live"]
        else:
            args += ["-cdrom", p(iso)]

    if os.path.exists(b.target):
        args += ["-drive", "if=none,id=target,file=%s,format=qcow2" % p(b.target),
                 "-device", "virtio-blk-pci,drive=target,serial=os7target"]

    if cmdline:
        args += ["-kernel", p(b.kernel), "-initrd", p(b.initrd), "-append", cmdline]

    if tpm is not None and tpm.enabled:
        args += tpm.args()
    return args


def detach(b, args, tpm=None):
    """Start the VM so that it survives this process.

    On the container path that is `docker run -d` with the three ports
    published; on the Mac it is a QEMU in its own session. Either way what is
    recorded is enough for a LATER process to find the machine again — which is
    the whole point of the bench and the one thing vmarch.command() cannot do,
    because it builds a foreground `docker run -i` whose stdio is the console.
    """
    if not b.arch.containerised:
        os.makedirs(b.dir, exist_ok=True)
        errlog = open(os.path.join(b.dir, "qemu.stderr.log"), "wb")
        proc = subprocess.Popen(args, stdout=errlog, stderr=subprocess.STDOUT,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        return {"pid": proc.pid, "container": None}

    b.arch.ensure_image()
    subprocess.run(["docker", "rm", "-f", b.container],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    argv = ["docker", "run", "-d", "--name", b.container, "--device", "/dev/kvm"]
    for h, c, ro in b.arch._mounts:
        argv += ["-v", h + ":" + c + (":ro" if ro else "")]
    if tpm is not None and tpm.enabled:
        os.makedirs(tpm.state_dir, exist_ok=True)
        argv += ["-e", "OS7_SWTPM=1", "-v", tpm.state_dir + ":/tpmstate"]
    for kind in ("qmp", "serial", "ssh"):
        pn = b.port(kind)
        argv += ["-p", "127.0.0.1:%d:%d" % (pn, pn)]
    argv += [VM_IMAGE] + args
    p = subprocess.run(argv, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("docker run failed:\n" + p.stderr.strip())
    return {"pid": None, "container": b.container, "cid": p.stdout.strip()[:12]}


# ---------------------------------------------------------------------------
# up / down / status
# ---------------------------------------------------------------------------
def extract_boot_files(b, iso):
    """Kernel and initrd out of the ISO — vmscreen.Lab's method, reached
    through vmscreen.Lab rather than reimplemented (BUILD-NOTES #66). It knows
    the casper UUID trap: cached files from the previous ISO boot a kernel that
    the medium then refuses, and it reads as a broken image."""
    from vmscreen import Lab
    lab = Lab(b.name, iso=iso, arch=b.arch)
    lab.extract_boot_files()


def cmd_up(a):
    b = Bench(a.name)
    if b.running():
        print("bench %s is already up (%s)" % (b.name, describe_ports(b)))
        return 0
    os.makedirs(b.dir, exist_ok=True)
    os.makedirs(b.shots, exist_ok=True)

    iso = a.iso
    if a.install and not iso:
        iso = b.arch.iso_default()
    if iso:
        iso = os.path.abspath(iso)
        if not os.path.exists(iso):
            raise SystemExit("no ISO at " + iso + " -- build it with " + b.arch.build_hint)
        b.arch.mount(os.path.dirname(iso), "/iso", ro=True)

    if a.size and not os.path.exists(b.target):
        b.arch.create_disk(b.target, a.size)
        print("    target   %s (%dG, blank)" % (b.target, a.size))
    if not os.path.exists(b.target) and not iso:
        raise SystemExit("no disk at %s and no --iso. Either point --iso at a "
                         "medium, or run a bench that has an installed disk." % b.target)

    b.arch.prepare_vars(b.vars)

    cmdline = None
    if iso:
        extract_boot_files(b, iso)
        cmdline = a.cmdline or (
            "boot=casper os7.setup=1 systemd.wants=os7-setup.service "
            "fbcon=nodefer quiet console=%s,115200" % b.arch.serial_tty)

    # The log is truncated on every `up`, because QEMU truncates it anyway when
    # it opens it. Keeping the previous boot is what `--keep-log` is for.
    if os.path.exists(b.serial_log) and a.keep_log:
        shutil.copy(b.serial_log, b.serial_log + ".prev")

    tpm = SoftTpm(b.arch, b.tpmdir, not a.no_tpm)
    if not b.arch.containerised:
        tpm.__enter__()
    args = qemu_args(b, iso=iso, cmdline=cmdline, tpm=tpm, gui=not a.no_gui)
    info = detach(b, args, tpm)
    b.write_state(name=b.name, arch=b.arch.arch, ports={k: b.port(k) for k in
                  ("qmp", "serial", "ssh")}, iso=iso, tpm=(not a.no_tpm),
                  gui=(not a.no_gui), started=time.strftime("%Y-%m-%d %H:%M:%S"),
                  **info)

    # A VM that started is not a VM that is running: docker returns as soon as
    # the container exists, and QEMU may still die on its first argument. QMP
    # answering is the acknowledgement, and Qmp() already knows that the
    # published port answers before QEMU does (vmscreen, measured 2026-08-28).
    try:
        q = b.qmp(timeout=90)
        status = q.cmd("query-status")
        q.close()
    except SystemExit:
        tail = ""
        if b.arch.containerised:
            p = subprocess.run(["docker", "logs", "--tail", "20", b.container],
                               capture_output=True, text=True)
            tail = (p.stdout or "") + (p.stderr or "")
        raise SystemExit("the VM did not come up.\n" + tail.strip())
    print("bench %s is up -- %s, %s" % (b.name, status.get("status"), describe_ports(b)))
    if iso:
        print("    medium   " + iso)
    print("    console  ./os7lab.py console %s --read" % b.name)
    return 0


def describe_ports(b):
    return "serial %d, ssh %d, qmp %d" % (b.port("serial"), b.port("ssh"), b.port("qmp"))


def cmd_down(a):
    b = Bench(a.name)
    if not b.running():
        print("bench %s is not up" % b.name)
        b.clear_state()
        return 0
    if not a.force:
        # ACPI first, and WAIT. A ZFS root that is killed rather than shut down
        # survives, but the next boot is no longer testing what the run was
        # about — run-s5.py's power_off() is where that was learned.
        try:
            q = b.qmp(timeout=20)
            q.cmd("system_powerdown")
            q.close()
        except SystemExit:
            pass
        deadline = time.time() + a.timeout
        while time.time() < deadline:
            if not b.running():
                print("bench %s powered off cleanly" % b.name)
                b.clear_state()
                return 0
            time.sleep(1.0)
        print("    note  no clean shutdown within %ds; taking it down" % a.timeout)
    if b.arch.containerised:
        subprocess.run(["docker", "rm", "-f", b.container],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        st = b.state() or {}
        if st.get("pid"):
            try:
                os.kill(st["pid"], 15)
            except OSError:
                pass
    print("bench %s is down" % b.name)
    b.clear_state()
    return 0


def cmd_ls(a):
    if not os.path.isdir(VMDIR):
        print("no .vm directory yet")
        return 0
    rows = []
    for name in sorted(os.listdir(VMDIR)):
        d = os.path.join(VMDIR, name)
        if not os.path.isdir(d):
            continue
        b = Bench(name)
        disk = "disk" if os.path.exists(b.target) else "—"
        up = "UP" if b.running() else "down"
        snaps = snapshot_tags(b) if os.path.exists(b.target) else []
        rows.append((name, up, disk, ",".join(snaps) or "—"))
    if not rows:
        print("no benches")
        return 0
    print("%-14s %-6s %-6s %s" % ("bench", "state", "disk", "snapshots"))
    for r in rows:
        print("%-14s %-6s %-6s %s" % r)
    return 0


def cmd_status(a):
    b = Bench(a.name)
    st = b.state() or {}
    print("bench     " + b.name)
    print("arch      " + b.arch.arch + ("  (container)" if b.arch.containerised else "  (host)"))
    print("state     " + ("UP" if b.running() else "down"))
    print("ports     " + describe_ports(b))
    if st.get("started"):
        print("started   " + st["started"])
    if st.get("iso"):
        print("medium    " + str(st["iso"]))
    print("disk      " + (b.target if os.path.exists(b.target) else "-- none --"))
    tags = snapshot_tags(b) if os.path.exists(b.target) else []
    print("snapshots " + (", ".join(tags) or "--"))
    print("console   %s (%d bytes)" % (b.serial_log, os.path.getsize(b.serial_log)
                                       if os.path.exists(b.serial_log) else 0))
    if b.running():
        try:
            q = b.qmp(timeout=15)
            print("qemu      " + json.dumps(q.cmd("query-status")))
            q.close()
        except SystemExit as e:
            print("qemu      unreachable: " + str(e))
        print("ssh       " + ("reachable" if ssh_alive(b) else "not answering"))
    return 0


# ---------------------------------------------------------------------------
# The serial channel
# ---------------------------------------------------------------------------
def cmd_console(a):
    b = Bench(a.name)
    if a.read:
        # Reading needs no VM at all — the log file is the machine's whole
        # utterance and it is still there after the machine is gone. That is
        # the one thing this channel can do that vmconsole.Console cannot.
        text = Serial(b, connect=False).text()
        if not a.raw:
            text = strip_escapes(text)
        if a.tail:
            text = "\n".join(text.splitlines()[-a.tail:]) + "\n"
        sys.stdout.write(text)
        return 0
    b.require_running()
    s = Serial(b)
    s.start_answering()
    try:
        if a.expect and not a.text:
            since = 0 if a.since is None else a.since
            s.expect([a.expect], a.timeout, a.expect, since=since)
            print("matched: " + a.expect)
            return 0
        if a.text is None:
            raise SystemExit("nothing to do -- pass text to type, --read, or --expect")
        since = s.size()
        s.send(a.text, enter=not a.no_enter)
        if a.expect:
            s.expect([a.expect], a.timeout, a.expect, since=since)
        else:
            s.settle(quiet=a.quiet, timeout=a.timeout)
        out = s.text(since)
        sys.stdout.write(out if a.raw else strip_escapes(out))
    finally:
        s.close()
    return 0


def strip_escapes(text):
    """The bytes with the terminal sequences taken out — run-s5.py's body_of()
    rule, and its reason: `\\x1b[?2004l1.0.0.133` has no word boundary before
    the version, so a \\b-anchored match silently finds nothing. CR goes too,
    or a `$`-anchored regex under re.MULTILINE matches nothing and the check
    does not fail, it passes."""
    text = re.sub(r"\x1b\][0-9;]*[^\x07\x1b]*(\x07|\x1b\\)", "", text)
    text = re.sub(r"\x1b[\[\]][0-9;?]*[A-Za-z]", "", text)
    text = re.sub(r"\x1b[=>]", "", text)
    return text.replace("\r", "")


# ---------------------------------------------------------------------------
# From a cold console to a channel that has exit codes
# ---------------------------------------------------------------------------
def cmd_login(a):
    """Walk the boot to a shell, then put this bench's public key on the
    machine so every later command can be an ssh one.

    THE PASSPHRASE IS THE MEASUREMENT, NOT AN OBSTACLE. A machine that asks for
    one when a TPM is attached has failed the thing run-s5.py's `boot` phase
    exists to prove, so it is reported as a finding and then typed — the point
    of a bench is that the session continues.
    """
    b = Bench(a.name)
    b.require_running()
    s = Serial(b)
    s.start_answering()
    try:
        print("    waiting for the machine to reach a prompt ...", flush=True)
        # WHAT THE MACHINE IS DOING IS ASKED, NOT READ OUT OF THE LOG. The log
        # holds every boot this bench has had, so searching it -- even only its
        # last few kilobytes -- finds a `login:` from an hour ago and types a
        # user name into a bash that has been sitting there since. A bare Enter
        # makes whatever is on the other end reprint ITS prompt, and the answer
        # to that is about now. The same rule as everywhere else here: ask the
        # thing itself, an old log line is not an answer.
        state = probe_state(s, a.timeout)
        if state == "dead":
            raise SystemExit("the machine did not start:\n" + s.text()[-2500:])
        if state == "passphrase":
            print("    FINDING  the machine asked for a passphrase. With a TPM "
                  "attached that is\n             run-s5.py boot's assertion "
                  "failing; typing it so the session goes on.")
            mark = s.size()
            s.send(PASSPHRASE)
            s.expect([r"\blogin:"], a.timeout, "a login prompt", since=mark)
            state = "login"
        elif state == "login":
            # NOT "the TPM unlocked it" ON THE STRENGTH OF A LOGIN PROMPT.
            # A bench attaches to a machine that may have been up for an hour,
            # and an earlier session may have typed the passphrase; finding a
            # login prompt says only that something got past the initramfs.
            # The log is truncated at every `up`, so what CAN be asked is
            # whether THIS boot ever printed a passphrase prompt -- and when
            # the answer is that it did, this says nothing at all rather than
            # something flattering. An unmeasured claim in a diagnostic is the
            # failure mode this whole repository is organised against.
            if re.search(r"unlock disk|Enter passphrase|passphrase for",
                         s.text(0), re.I):
                print("    note     a passphrase was typed earlier in this boot; "
                      "the TPM claim is\n             not measurable from here "
                      "-- run-s5.py boot is where it is measured")
            else:
                print("    ok       this boot reached a login prompt with no "
                      "passphrase typed")

        if state == "login":
            s.settle(quiet=1.5, timeout=30)
            mark = s.size()
            s.send(a.user)
            j = s.expect([r"[Pp]assword:", PROMPT], 90, "a password prompt", since=mark)
            if j == 0:
                s.send(a.password)
                s.expect([PROMPT], 180, "the PowerShell prompt a login lands on",
                         since=mark)
            state = "pwsh"
        print("    ok       the session is at a %s prompt"
              % ("PowerShell" if state == "pwsh" else state))

        if a.no_ssh:
            return 0

        pub = ensure_key(b)
        # bash, not PowerShell: the quoting of one long key line has to be got
        # exactly right on a serial line, and bash is the shell every other
        # harness in this directory drops to for the same reason.
        #
        # SETTLE FIRST, AND RETRY. Typing into a shell that is still painting
        # its prompt loses the leading characters, and the loss is invisible
        # until the command never runs -- vmconsole.to_plain_bash carries the
        # same settle and the same three attempts, for the same reason.
        if state != "bash":
            s.settle(quiet=2.0, timeout=60)
            for _ in range(3):
                mark = s.size()
                s.send("bash --norc")
                try:
                    s.expect([BASH_PROMPT], 45, "a plain bash prompt", since=mark)
                    break
                except SystemExit:
                    print("    note     no bash prompt yet -- retrying")
            else:
                raise SystemExit("could not reach a plain bash prompt")
        # ONE printf WITH ITS OWN \n, not a second call carrying a literal
        # newline: a newline sent down the serial line IS Enter, so the second
        # form submits half a command and appends nothing (BUILD-NOTES #16).
        # This is run-s5.py send_script's shape.
        for line in ("mkdir -p ~/.ssh",
                     "chmod 700 ~/.ssh",
                     "printf '%s\\n' " + shell_quote(pub) + " >> ~/.ssh/authorized_keys",
                     "chmod 600 ~/.ssh/authorized_keys"):
            mark = s.size()
            s.send(line)
            s.settle(quiet=0.8, timeout=30)
        mark = s.size()
        # Asked of the FILE, not of the exit codes above: every one of those
        # commands could report success while the key landed nowhere useful.
        s.send("grep -c ssh-ed25519 ~/.ssh/authorized_keys; systemctl is-active ssh")
        s.settle(quiet=1.5, timeout=60)
        body = strip_escapes(s.text(mark)).split()
        print("    key      authorized_keys / sshd: " +
              (" ".join(body[-2:]) if body else "no answer"))
    finally:
        s.close()

    for _ in range(int(a.timeout / 3)):
        if ssh_alive(b):
            print("    ok       ssh answers on port %d" % b.port("ssh"))
            print("    try      ./os7lab.py exec %s 'Get-OS7Version'" % b.name)
            return 0
        time.sleep(3)
    print("    FAIL     ssh does not answer on port %d" % b.port("ssh"))
    return 1


def probe_state(s, timeout):
    """What is on the other end of the serial line, right now.

    A bare Enter, and then whoever is there reprints their prompt: agetty a
    `login:`, cryptsetup its passphrase question, bash `bash-5.x$`, PowerShell
    `PS ...>`. A machine that is still booting prints nothing yet, so the wait
    simply continues until it reaches one of them -- which is the same wait a
    cold start needs, with no separate code path.

    The Enter is harmless everywhere it can land: an empty passphrase makes
    cryptsetup ask again, an empty user name makes agetty ask again, and an
    empty command line is a no-op in both shells.
    """
    mark = s.size()
    s.send("")
    i = s.expect([r"\blogin:",
                  r"unlock disk", r"Enter passphrase", r"passphrase for",
                  BASH_PROMPT, PROMPT,
                  r"\(initramfs\)", r"Kernel panic", r"No bootable"],
                 timeout, "a prompt of any kind", since=mark)
    return ("login", "passphrase", "passphrase", "passphrase",
            "bash", "pwsh", "dead", "dead", "dead")[i]


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------------------
# install — the bench's own machine, from a medium
# ---------------------------------------------------------------------------
_mark = [0]


def ask(s, command, label, timeout=240):
    """Run one thing in the guest and return everything it printed.

    THE MARKER IS BUILT BY THE SHELL, NOT TYPED. `…; echo DONE` matches the
    shell's ECHO of the command as it is typed, so expect() returns before the
    command has run -- BUILD-NOTES #16, and run-s5.py's ask() carries the same
    `printf 'OK%s'` construction for the same reason.
    """
    _mark[0] += 1
    n = _mark[0]
    start = s.size()
    s.send(command + "; printf 'OK%s\\n' " + str(n))
    s.expect(["OK" + str(n)], timeout, label, since=start + len(command))
    return strip_escapes(s.text(start))


def live_shell(s, timeout=900):
    """From a cold live medium to a plain bash prompt.

    Not vmconsole.live_login/to_plain_bash: those take a Console and call
    .drop(), and a bench reads a FILE that cannot be dropped -- an expect()
    with no `since` on this class would search every boot the bench ever had.
    The steps are theirs; the anchoring is this class's.
    """
    s.start_answering()
    s.expect([r"\blogin:", r"PS [^\r\n]*>", r"bash-\d"], timeout, "the live console")
    s.settle(quiet=1.5, timeout=60)
    mark = s.size()
    s.send("ubuntu")
    i = s.expect([r"Password:", PROMPT, r"\$ $", r"# $", r"bash-\d"], 120,
                 "a password prompt or a shell", since=mark)
    if i == 0:
        s.send("")
        s.expect([PROMPT, r"\$ $", r"# $", r"bash-\d"], 120, "a shell", since=mark)
    s.settle(quiet=2.0, timeout=60)
    for _ in range(3):
        mark = s.size()
        s.send("bash --norc")
        try:
            s.expect([BASH_PROMPT], 45, "a plain bash prompt", since=mark)
            return
        except SystemExit:
            print("    note     no bash prompt yet -- retrying")
    raise SystemExit("could not reach a plain bash prompt on the live medium")


def write_file(s, path, text):
    """One printf per line into a guest file. Not a heredoc: expect() would
    have to match a terminator the typed text itself contains (#16)."""
    s.send(": > " + path)
    for line in text.strip().splitlines():
        s.send("printf '%s\\n' " + shell_quote(line) + " >> " + path)
    return ask(s, "wc -l " + path, "wrote " + path)


def run_s5_scripts():
    """SERIAL_INNER and SERIAL_CONSOLE, taken FROM run-s5.py.

    An amd64 machine installed by os7-setup is SILENT on the serial line: x86
    has no device tree to name a console, so the kernel takes tty0 and the
    passphrase prompt, the boot and the login all happen on a display nothing
    is attached to. run-s5.py solves that by giving the installed machine a
    serial console, and those two scripts are the solution -- imported rather
    than paraphrased, because BUILD-NOTES #66 is about exactly this: code
    written from the same notes as a working script takes a different route.

    The import runs run-s5.py's module level, which builds a Lab object and
    registers mounts on ITS OWN VmArch. It starts nothing and writes nothing.
    """
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "run-s5.py")
    spec = importlib.util.spec_from_file_location("run_s5_scripts", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.SERIAL_INNER, mod.SERIAL_CONSOLE


def plan_json(a):
    """os7-setup's unattended plan. run-s5.py's write_plan(), with the fields
    it hardcodes turned into parameters -- `mode` above all, because Headless
    is what every installed disk in this repository is and Desktop is what the
    amd64 product actually ships."""
    return json.dumps({
        "version": 1, "intent": "Install", "language": a.language,
        "keyboard": a.keyboard, "timezone": a.timezone, "mode": a.mode,
        "storage": {"disk": "/dev/disk/by-id/virtio-os7target", "layout": "single",
                    "efiMiB": 512, "bpoolGiB": 2, "encrypt": True, "swap": "zram"},
        "account": {"hostname": a.hostname, "username": a.user,
                    "fullName": "OS/7 bench"},
        "network": {"interface": "auto", "kind": "Wired", "method": "Dhcp"},
    }, separators=(",", ":"))


def cmd_install(a):
    b = Bench(a.name)
    if b.running():
        raise SystemExit("bench %s is up; install needs it stopped" % b.name)
    iso = os.path.abspath(a.iso) if a.iso else b.arch.iso_default()
    if not os.path.exists(iso):
        raise SystemExit("no ISO at " + iso + " -- " + b.arch.build_hint)
    if not a.size:
        a.size = 24 if a.mode == "Headless" else 40

    # A blank disk, every time. An install onto a disk a previous run left
    # half-partitioned is not testing what it looks like it is testing.
    os.makedirs(b.dir, exist_ok=True)
    if os.path.exists(b.target):
        if not a.keep_disk:
            os.remove(b.target)
    if not os.path.exists(b.target):
        b.arch.create_disk(b.target, a.size)
        print("    target   %s (%dG, blank)" % (b.target, a.size))
    # known_hosts GOES WITH THE DISK. A reinstalled bench has new host keys,
    # and ssh then prints REMOTE HOST IDENTIFICATION HAS CHANGED over every
    # single command -- fourteen lines of warning around two lines of answer.
    # StrictHostKeyChecking=no accepts an UNKNOWN host, not a CHANGED one; the
    # honest fix is to admit the old machine is gone.
    kh = os.path.join(b.sshdir, "known_hosts")
    if os.path.exists(kh) and not a.keep_disk:
        os.remove(kh)
    if os.path.isdir(b.tpmdir) and not a.keep_disk:
        shutil.rmtree(b.tpmdir)
    if os.path.exists(b.vars) and not a.keep_disk:
        os.remove(b.vars)

    print("### install -- unattended, mode %s, with a TPM attached" % a.mode)
    # NO os7.setup=1 AND NO systemd.wants=os7-setup.service. cmd_up's default
    # command line is the one that makes the medium start Setup by itself --
    # right for walking the installer, wrong here, because this phase runs
    # `os7-setup --unattend` from a shell and the two would fight for the
    # console. run-s5.py's LIVE_CMDLINE is this line, for this reason.
    live_cmdline = ("boot=casper fbcon=nodefer quiet console=%s,115200"
                    % b.arch.serial_tty)
    up = argparse.Namespace(name=a.name, iso=iso, install=False, size=0,
                            cmdline=live_cmdline, no_tpm=False, no_gui=False,
                            keep_log=False)
    if cmd_up(up) != 0:
        return 1

    s = Serial(b)
    try:
        print("    waiting for the live medium ...", flush=True)
        live_shell(s, timeout=a.timeout)
        print("    ok       the live session is at a bash prompt")

        # THE FIXTURE IS CHECKED BEFORE THE THING IT IS FOR. Every Phase 3 run
        # believed it exercised TpmEnrolStep and did not, because that step
        # looks for /sys/class/tpm/tpm0 and quietly takes the other path
        # (run-s5.py phase_install carries this check for the same reason).
        if "/sys/class/tpm/tpm0" not in ask(s, "ls -d /sys/class/tpm/tpm0 2>&1",
                                            "the guest's TPM"):
            print("    FAIL     the guest has no TPM -- swtpm is not reaching it")
            return 1
        print("    ok       the guest can see a TPM")

        write_file(s, "/tmp/plan.json", plan_json(a))
        s.send("printf '%s' " + shell_quote(a.passphrase) + " > /tmp/pass")
        s.send("printf '%s' " + shell_quote(a.password) + " > /tmp/pw")
        ask(s, "wc -c /tmp/plan.json /tmp/pass /tmp/pw", "the plan files")

        print("    installing (this takes about 25 minutes) ...", flush=True)
        text = ask(s, "sudo os7-setup --unattend /tmp/plan.json "
                      "--passphrase-file /tmp/pass --password-file /tmp/pw",
                   "the unattended install", timeout=a.install_timeout)
        for line in text.splitlines():
            t = line.strip()
            if "OS7-SETUP" in t or ">>>" in t or "!!!" in t:
                print("      " + t)
        if "OS7-SETUP-DONE install" not in text:
            print("    FAIL     the install did not finish")
            for line in text.splitlines()[-20:]:
                if line.strip():
                    print("      " + line.strip())
            return 1
        print("    ok       Setup reported a finished install")

        if re.search(r"\b[rb]pool\b", ask(s, "zpool list -H -o name || true",
                                          "imported pools")):
            print("    FAIL     a pool is still imported after the install")
            return 1
        print("    ok       the installer exported both pools")

        # amd64 only, and it is the HARNESS's doing rather than the product's:
        # see run-s5.py's SERIAL_CONSOLE header. Without it every later bench
        # command talks to a machine that says nothing.
        if b.arch.serial_tty != "ttyAMA0":
            inner, outer = run_s5_scripts()
            write_file(s, "/tmp/serialize-inner.sh", inner)
            write_file(s, "/tmp/serialize.sh", outer)
            out = ask(s, "sudo bash /tmp/serialize.sh 2>&1 | tail -8",
                      "giving the machine a serial console", timeout=900)
            m = re.search(r"SERIAL-LINES=(\d+)", out)
            if "SERIAL-CONSOLE-OK" not in out or not m or int(m.group(1)) < 1:
                print("    FAIL     the machine could not be given a serial console")
                print(out.strip()[-1000:])
                return 1
            print("    ok       the machine has a serial console (%s menu lines)"
                  % m.group(1))
    finally:
        s.close()

    print("    shutting the medium down ...", flush=True)
    cmd_down(argparse.Namespace(name=a.name, force=False, timeout=240))
    cmd_snapshot(argparse.Namespace(name=a.name, tag="installed", replace=True))
    print("\n    ./os7lab.py up %s && ./os7lab.py login %s" % (a.name, a.name))
    return 0


def ensure_key(b):
    """This bench's key pair. Per bench, so removing .vm/<name> removes the
    credential with it."""
    os.makedirs(b.sshdir, exist_ok=True)
    if not os.path.exists(b.key):
        subprocess.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-q",
                        "-C", "os7lab-" + b.name, "-f", b.key], check=True)
    with open(b.key + ".pub", encoding="utf-8") as f:
        return f.read().strip()


def ssh_base(b):
    return ["ssh", "-p", str(b.port("ssh")), "-i", b.key,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=" + os.path.join(b.sshdir, "known_hosts"),
            "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=8",
            "-o", "BatchMode=yes",
            USER + "@127.0.0.1"]


def ssh_alive(b):
    if not os.path.exists(b.key):
        return False
    p = subprocess.run(ssh_base(b) + ["true"], capture_output=True, text=True)
    return p.returncode == 0


# ---------------------------------------------------------------------------
# exec — the channel with an exit code
# ---------------------------------------------------------------------------
def cmd_exec(a):
    b = Bench(a.name)
    b.require_running()
    if not os.path.exists(b.key):
        raise SystemExit("this bench has no key yet -- ./os7lab.py login " + b.name)
    script = a.script
    if a.file:
        with open(a.file, encoding="utf-8") as f:
            script = f.read()
    if not script:
        raise SystemExit("nothing to run")
    if a.json:
        script = "$__r = @(" + script + "); $__r | ConvertTo-Json -Depth 5"
    rc, out, err = run_remote(b, script, elevated=a.sudo, shell=a.shell,
                              timeout=a.timeout)
    if out:
        sys.stdout.write(out if out.endswith("\n") else out + "\n")
    if err:
        sys.stderr.write(err if err.endswith("\n") else err + "\n")
    if a.rc:
        print("exit " + str(rc))
    return rc


def run_remote(b, script, elevated=False, shell=False, timeout=600):
    """Run one thing on the machine and come back with a real exit code.

    NOT quoted into a command line. `-EncodedCommand` takes UTF-16LE base64, so
    the script may contain any quote, any dollar and any newline — which is the
    difference from run-s5.py's ps(), whose contract has to REFUSE a single
    quote because it interpolates into a single-quoted bash word.

    sudo takes the password on STDIN rather than through a sudoers change: the
    bench must not quietly become a machine with passwordless root, because the
    next thing it does is get snapshotted and photographed (BUILD-NOTES #93).
    """
    if shell:
        remote = script
    else:
        enc = base64.b64encode(script.encode("utf-16-le")).decode()
        remote = "pwsh -NoProfile -NonInteractive -EncodedCommand " + enc
    stdin = None
    if elevated:
        remote = "sudo -S -p '' " + remote
        stdin = PASSWORD + "\n"
    # encoding= AND errors=, BOTH REQUIRED, and this is not a nicety.
    #
    # `text=True` alone decodes with the HOST's locale encoding, which is
    # cp1252 on Windows. A Linux machine answers in UTF-8, so the first journal
    # entry containing an em dash killed subprocess's reader thread outright:
    #
    #     Exception in thread Thread-3 (_readerthread):
    #       File "encodings/cp1252.py", line 23, in decode
    #
    # and `p.stdout` then came back None. That is worse than a crash, because
    # the caller sees a returncode of 0 and no output: `run-surface.py` recorded
    # `Get-SystemdJournal` as `empty` in a published matrix, on a machine where
    # `(Get-SystemdJournal).Count` is 100. A tool that relays what a machine
    # said must not let the host's code page decide what it is allowed to say —
    # the same rule main() applies to stdout.
    p = subprocess.run(ssh_base(b) + [remote], input=stdin, capture_output=True,
                       text=True, encoding="utf-8", errors="replace",
                       timeout=timeout)
    return p.returncode, p.stdout or "", p.stderr or ""


def guest_path(p, what):
    """A path INSIDE the guest, checked for BUILD-NOTES #102 on the way past.

    Git Bash rewrites an argument that looks like a Unix path into a Windows
    one before the process ever sees it, so `push … /tmp/x` arrives here as
    `C:/Users/…/Temp/x`. scp then fails with a message naming a Windows path
    on a Linux machine, which reads as anything but a shell quirk. It is
    cheaper to refuse it here and say which shell did it.
    """
    if re.match(r"^[A-Za-z]:[\\/]", p):
        raise SystemExit(
            "%s %r is a WINDOWS path -- Git Bash rewrote it on the way in "
            "(BUILD-NOTES #102).\nRun this from PowerShell, or set "
            "MSYS_NO_PATHCONV=1 for the call." % (what, p))
    return p


def cmd_push(a):
    b = Bench(a.name)
    b.require_running()
    dest = USER + "@127.0.0.1:" + guest_path(a.dest, "destination")
    p = subprocess.run(["scp", "-P", str(b.port("ssh")), "-i", b.key,
                        "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=" + os.path.join(b.sshdir, "known_hosts"),
                        "-o", "LogLevel=ERROR", a.src, dest])
    return p.returncode


def cmd_pull(a):
    b = Bench(a.name)
    b.require_running()
    src = USER + "@127.0.0.1:" + guest_path(a.src, "source")
    p = subprocess.run(["scp", "-P", str(b.port("ssh")), "-i", b.key,
                        "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=" + os.path.join(b.sshdir, "known_hosts"),
                        "-o", "LogLevel=ERROR", src, a.dest])
    return p.returncode


# ---------------------------------------------------------------------------
# The screen, and the two things that can be aimed at it
# ---------------------------------------------------------------------------
# QEMU qcodes for the characters `type` sends. run-phase3.py carries five of
# these for the strings it types; the GUI needs the rest, so the table is here
# in full and that one stays where it is — a bench importing a five-entry table
# and silently sending a wrong key for the sixth character is the kind of quiet
# wrongness this repository keeps paying for.
QCODE = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left",
    "]": "bracket_right", ";": "semicolon", "'": "apostrophe", "`": "grave_accent",
    "\\": "backslash", ",": "comma", ".": "dot", "/": "slash", "\n": "ret",
    "\t": "tab",
    "!": "shift-1", "@": "shift-2", "#": "shift-3", "$": "shift-4",
    "%": "shift-5", "^": "shift-6", "&": "shift-7", "*": "shift-8",
    "(": "shift-9", ")": "shift-0", "_": "shift-minus", "+": "shift-equal",
    "{": "shift-bracket_left", "}": "shift-bracket_right", ":": "shift-semicolon",
    "\"": "shift-apostrophe", "~": "shift-grave_accent", "|": "shift-backslash",
    "<": "shift-comma", ">": "shift-dot", "?": "shift-slash",
}
for _d, _n in zip("0123456789", ("0", "1", "2", "3", "4", "5", "6", "7", "8", "9")):
    QCODE[_d] = _n


# A QCODE IS A KEY POSITION, NOT A CHARACTER, and the guest's keymap decides
# what the position produces. Measured on this bench, 2026-08-30: typing
# `os7lab-hid-test` at the console of a machine installed with `keyboard: de`
# put `os7labßhidßtest` on the screen. The keystrokes were perfect; `minus` is
# simply where `ß` lives on a German keyboard.
#
# So a layout is a translation from character to POSITION, and the table below
# is the difference from US for the layout OS/7 installs by default in this
# repository's plans. It is verified against the machine rather than copied
# from a keymap file — `os7lab.py type <bench> --verify` types the printable
# set and reads it back off a screendump.
#
# Anything not listed falls through to the US position, which is right for
# every unshifted letter and digit on both layouts.
LAYOUTS = {
    "us": {},
    "de": {
        # the three swapped/moved keys a shell command hits first
        "-": "slash", "_": "shift-slash",
        "y": "z", "z": "y", "Y": "shift-z", "Z": "shift-y",
        # the punctuation US puts where German puts umlauts
        "ß": "minus", "ü": "bracket_left", "Ü": "shift-bracket_left",
        "ö": "semicolon", "Ö": "shift-semicolon",
        "ä": "apostrophe", "Ä": "shift-apostrophe",
        "+": "bracket_right", "*": "shift-bracket_right",
        "#": "backslash", "'": "shift-backslash",
        "/": "shift-7", "(": "shift-8", ")": "shift-9", "=": "shift-0",
        "&": "shift-6", "%": "shift-5", "$": "shift-4", "\"": "shift-2",
        "!": "shift-1", "?": "shift-minus", ";": "shift-comma",
        ":": "shift-dot",
    },
}


def qcodes_for(ch, layout="us"):
    table = LAYOUTS.get(layout)
    if table is None:
        raise SystemExit("unknown keyboard layout %r -- have: %s"
                         % (layout, ", ".join(sorted(LAYOUTS))))
    if ch in table:
        return table[ch]
    if ch in QCODE:
        return QCODE[ch]
    if ch.isalpha() and ch.isascii():
        return ("shift-" + ch.lower()) if ch.isupper() else ch.lower()
    raise SystemExit("no qcode for character %r on layout %r -- send it over "
                     "the serial line instead, or add it to LAYOUTS" % (ch, layout))


def send_keys(q, spec, gap=0.05):
    """One key, possibly with modifiers written as `shift-a` or `ctrl-alt-f2`.

    THE GAP IS NOT POLITENESS (BUILD-NOTES #34, and vmscreen.send_key's own
    note): QEMU holds a key for a fixed time and a USB HID keyboard cannot
    report two independent presses at once, so keys sent closer together than
    the hold OVERLAP and all but one vanish.
    """
    parts = spec.split("-")
    keys = [{"type": "qcode", "data": p} for p in parts]
    q.cmd("send-key", keys=keys, **{"hold-time": 20})
    time.sleep(gap)


def cmd_shot(a):
    b = Bench(a.name)
    b.require_running()
    os.makedirs(b.shots, exist_ok=True)
    name = a.shot or time.strftime("shot-%H%M%S")
    ppm = os.path.join(b.shots, name + ".ppm")
    png = a.out or os.path.join(b.shots, name + ".png")
    q = b.qmp()
    try:
        q.screendump(ppm, guest_path=b.arch.path(ppm))
        w, h, rgb = read_ppm(ppm)
        write_png(png, w, h, rgb)
    finally:
        q.close()
        if os.path.exists(ppm):
            os.remove(ppm)
    print("%s  (%dx%d)" % (png, w, h))
    return 0


def cmd_key(a):
    b = Bench(a.name)
    b.require_running()
    q = b.qmp()
    try:
        for spec in a.keys:
            for _ in range(a.repeat):
                send_keys(q, spec, gap=a.gap)
    finally:
        q.close()
    return 0


def cmd_type(a):
    b = Bench(a.name)
    b.require_running()
    q = b.qmp()
    try:
        for ch in a.text:
            send_keys(q, qcodes_for(ch, a.layout), gap=a.gap)
        if a.enter:
            send_keys(q, "ret", gap=a.gap)
    finally:
        q.close()
    return 0


def cmd_click(a):
    """A click at a pixel of the LAST SCREENDUMP.

    The tablet reports on a fixed 0..32767 axis regardless of the guest's
    resolution, so a pixel has to be scaled into it. The screen is FB_W x FB_H
    because that is what -device virtio-gpu-pci was given; a guest that has
    changed its own mode would need --width/--height to say so.
    """
    b = Bench(a.name)
    b.require_running()
    w, h = a.width, a.height
    events = [
        {"type": "abs", "data": {"axis": "x", "value": int(a.x * 32767 / max(w - 1, 1))}},
        {"type": "abs", "data": {"axis": "y", "value": int(a.y * 32767 / max(h - 1, 1))}},
    ]
    q = b.qmp()
    try:
        q.cmd("input-send-event", events=events)
        time.sleep(0.15)
        if not a.move_only:
            q.cmd("input-send-event", events=[
                {"type": "btn", "data": {"button": a.button, "down": True}}])
            time.sleep(0.08)
            q.cmd("input-send-event", events=[
                {"type": "btn", "data": {"button": a.button, "down": False}}])
    finally:
        q.close()
    return 0


# ---------------------------------------------------------------------------
# Snapshots — the reason a bench is cheap
# ---------------------------------------------------------------------------
# A SNAPSHOT IS THREE THINGS, NOT ONE, and the evidence for that is already in
# this repository: shoot-manual.py copies .vm/s5's disk, firmware variables and
# TPM state into .vm/manual, and the machine then asks for its passphrase.
# Whatever the cause, a "snapshot" that captures only the disk cannot restore a
# machine that unlocks itself — so all three are taken together, with the VM
# stopped, and `restore` puts all three back.
def qemu_img(b, *args):
    if not b.arch.containerised:
        p = subprocess.run(["qemu-img"] + list(args), capture_output=True, text=True)
    else:
        b.arch.ensure_image()
        argv = ["docker", "run", "--rm"]
        for h, c, ro in b.arch._mounts:
            argv += ["-v", h + ":" + c + (":ro" if ro else "")]
        argv += ["--entrypoint", "qemu-img", VM_IMAGE] + list(args)
        p = subprocess.run(argv, capture_output=True, text=True)
    if p.returncode != 0:
        raise SystemExit("qemu-img " + " ".join(args) + " failed:\n" + p.stderr.strip())
    return p.stdout


def snapshot_tags(b):
    if not os.path.exists(b.target):
        return []
    # -U because listing must work while the machine is UP: qemu-img wants a
    # shared write lock it cannot have, and `status` is exactly the command a
    # person types about a running bench. Taking and applying snapshots keeps
    # require_down() -- that is where the lock means something.
    out = qemu_img(b, "snapshot", "-l", "-U", b.arch.path(b.target))
    tags = []
    for line in out.splitlines():
        m = re.match(r"^\s*(\d+)\s+(\S+)", line)
        if m and m.group(2) != "TAG":
            tags.append(m.group(2))
    return tags


def side_files(b, tag):
    return (os.path.join(b.snapdir, tag + ".vars.fd"),
            os.path.join(b.snapdir, tag + ".tpm"))


def cmd_snapshot(a):
    b = Bench(a.name)
    b.require_down("taking a snapshot")
    if not os.path.exists(b.target):
        raise SystemExit("no disk at " + b.target)
    os.makedirs(b.snapdir, exist_ok=True)
    if a.tag in snapshot_tags(b):
        if not a.replace:
            raise SystemExit("snapshot " + a.tag + " exists -- pass --replace")
        qemu_img(b, "snapshot", "-d", a.tag, b.arch.path(b.target))
    t0 = time.time()
    qemu_img(b, "snapshot", "-c", a.tag, b.arch.path(b.target))
    varsf, tpmf = side_files(b, a.tag)
    if os.path.exists(b.vars):
        shutil.copy(b.vars, varsf)
    if os.path.isdir(b.tpmdir):
        if os.path.isdir(tpmf):
            shutil.rmtree(tpmf)
        shutil.copytree(b.tpmdir, tpmf)
    print("snapshot %s: disk + firmware vars + TPM state, %.1fs"
          % (a.tag, time.time() - t0))
    return 0


def cmd_restore(a):
    b = Bench(a.name)
    b.require_down("restoring a snapshot")
    if a.tag not in snapshot_tags(b):
        raise SystemExit("no snapshot " + a.tag + " -- have: " +
                         (", ".join(snapshot_tags(b)) or "none"))
    t0 = time.time()
    # Same reasoning as install: the snapshot may predate the host keys the
    # bench has been talking to, and a stale known_hosts turns every later
    # command into a wall of warning.
    kh = os.path.join(b.sshdir, "known_hosts")
    if os.path.exists(kh):
        os.remove(kh)
    qemu_img(b, "snapshot", "-a", a.tag, b.arch.path(b.target))
    varsf, tpmf = side_files(b, a.tag)
    restored = ["disk"]
    if os.path.exists(varsf):
        shutil.copy(varsf, b.vars)
        restored.append("firmware vars")
    if os.path.isdir(tpmf):
        if os.path.isdir(b.tpmdir):
            shutil.rmtree(b.tpmdir)
        shutil.copytree(tpmf, b.tpmdir)
        restored.append("TPM state")
    print("restored %s: %s, %.1fs" % (a.tag, " + ".join(restored), time.time() - t0))
    if len(restored) < 3:
        print("    note  this snapshot has no " +
              " and no ".join(x for x in ("firmware vars", "TPM state")
                              if x not in restored) +
              " — the machine may not unlock itself")
    return 0


def cmd_snapshots(a):
    b = Bench(a.name)
    if not os.path.exists(b.target):
        raise SystemExit("no disk at " + b.target)
    tags = snapshot_tags(b)
    if not tags:
        print("no snapshots")
        return 0
    print("%-20s %-6s %-6s" % ("tag", "vars", "tpm"))
    for t in tags:
        varsf, tpmf = side_files(b, t)
        print("%-20s %-6s %-6s" % (t, "yes" if os.path.exists(varsf) else "NO",
                                   "yes" if os.path.isdir(tpmf) else "NO"))
    return 0


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(
        prog="os7lab.py",
        description="A long-lived OS/7 VM: serial line, ssh, screen, snapshots.")
    sub = p.add_subparsers(dest="cmd", required=True)

    def bench_arg(sp):
        sp.add_argument("name", help="bench name — the directory under .vm/")
        return sp

    sp = bench_arg(sub.add_parser("up", help="start the VM, detached"))
    sp.add_argument("--iso", help="attach a medium (implies a Setup boot)")
    sp.add_argument("--install", action="store_true",
                    help="attach the architecture default ISO from out/")
    sp.add_argument("--size", type=int, default=0,
                    help="create a blank target disk of N GiB if none exists")
    sp.add_argument("--cmdline", help="override the kernel command line")
    sp.add_argument("--no-tpm", action="store_true", help="no software TPM")
    sp.add_argument("--no-gui", action="store_true",
                    help="no GPU, keyboard or tablet — serial and ssh only")
    sp.add_argument("--keep-log", action="store_true",
                    help="copy the previous console log to .prev first")
    sp.set_defaults(func=cmd_up)

    sp = bench_arg(sub.add_parser("install", help="install OS/7 onto this bench, unattended"))
    sp.add_argument("--iso", help="the medium (default: out/os7-<arch>.iso)")
    sp.add_argument("--mode", default="Headless", choices=("Headless", "Gui"),
                    help="what os7-setup installs. Gui is the amd64 product -- "
                         "and it is spelt Gui because InstallPlan.cs says "
                         "`enum InstallMode { Gui, Headless }`, which is not "
                         "the word the plans and the docs use for it")
    sp.add_argument("--size", type=int, default=0,
                    help="target disk, GiB. Default 24 for Headless (run-s5.py's "
                         "proven value) and 40 for Gui, which installs GNOME, "
                         "Edge and the rest of the desktop product. qcow2 is "
                         "thin, so the larger figure costs nothing it does not use")
    sp.add_argument("--hostname", default="os7-bench")
    sp.add_argument("--user", default=USER)
    sp.add_argument("--password", default=PASSWORD)
    sp.add_argument("--passphrase", default=PASSPHRASE)
    sp.add_argument("--language", default="de_DE.UTF-8")
    sp.add_argument("--keyboard", default="de")
    sp.add_argument("--timezone", default="Europe/Berlin")
    sp.add_argument("--timeout", type=int, default=900, help="to reach the live shell")
    sp.add_argument("--install-timeout", type=int, default=3600)
    sp.add_argument("--keep-disk", action="store_true",
                    help="do not wipe the disk, firmware vars and TPM state first")
    sp.set_defaults(func=cmd_install)

    sp = bench_arg(sub.add_parser("down", help="shut the VM down"))
    sp.add_argument("--force", action="store_true", help="no ACPI, just stop it")
    sp.add_argument("--timeout", type=int, default=120)
    sp.set_defaults(func=cmd_down)

    sp = sub.add_parser("ls", help="every bench under .vm/")
    sp.set_defaults(func=cmd_ls)

    sp = bench_arg(sub.add_parser("status", help="what this bench is"))
    sp.set_defaults(func=cmd_status)

    sp = bench_arg(sub.add_parser("console", help="the serial line"))
    sp.add_argument("text", nargs="?", help="type this and wait")
    sp.add_argument("--read", action="store_true",
                    help="print what the machine has said (needs no running VM)")
    sp.add_argument("--tail", type=int, default=0, help="only the last N lines")
    sp.add_argument("--expect", help="wait for this regex instead of for quiet")
    sp.add_argument("--since", type=int, help="read from this byte offset")
    sp.add_argument("--timeout", type=int, default=300)
    sp.add_argument("--quiet", type=float, default=2.0,
                    help="seconds of silence that count as done")
    sp.add_argument("--no-enter", action="store_true", help="do not press Enter")
    sp.add_argument("--raw", action="store_true", help="keep the escape sequences")
    sp.set_defaults(func=cmd_console)

    sp = bench_arg(sub.add_parser("login", help="boot to a shell and install the ssh key"))
    sp.add_argument("--user", default=USER)
    sp.add_argument("--password", default=PASSWORD)
    sp.add_argument("--timeout", type=int, default=900)
    sp.add_argument("--no-ssh", action="store_true", help="stop at the prompt")
    sp.set_defaults(func=cmd_login)

    sp = bench_arg(sub.add_parser("exec", help="run PowerShell over ssh"))
    sp.add_argument("script", nargs="?", default="")
    sp.add_argument("--file", help="read the script from a file instead")
    sp.add_argument("--sudo", action="store_true", help="elevate")
    sp.add_argument("--json", action="store_true", help="wrap in ConvertTo-Json")
    sp.add_argument("--shell", action="store_true", help="plain bash, not pwsh")
    sp.add_argument("--rc", action="store_true", help="print the exit code too")
    sp.add_argument("--timeout", type=int, default=600)
    sp.set_defaults(func=cmd_exec)

    sp = bench_arg(sub.add_parser("push", help="copy a file to the machine"))
    sp.add_argument("src")
    sp.add_argument("dest")
    sp.set_defaults(func=cmd_push)

    sp = bench_arg(sub.add_parser("pull", help="copy a file back"))
    sp.add_argument("src")
    sp.add_argument("dest")
    sp.set_defaults(func=cmd_pull)

    sp = bench_arg(sub.add_parser("shot", help="a PNG of the screen"))
    sp.add_argument("shot", nargs="?", help="name for the file")
    sp.add_argument("--out", help="write the PNG here instead")
    sp.set_defaults(func=cmd_shot)

    sp = bench_arg(sub.add_parser("key", help="press keys (qcodes, e.g. ret ctrl-alt-f2)"))
    sp.add_argument("keys", nargs="+")
    sp.add_argument("--repeat", type=int, default=1)
    sp.add_argument("--gap", type=float, default=0.05)
    sp.set_defaults(func=cmd_key)

    sp = bench_arg(sub.add_parser("type", help="type text through the HID keyboard"))
    sp.add_argument("text")
    sp.add_argument("--enter", action="store_true")
    sp.add_argument("--gap", type=float, default=0.05)
    sp.add_argument("--layout", default=os.environ.get("OS7LAB_LAYOUT", "de"),
                    choices=sorted(LAYOUTS),
                    help="the GUEST keyboard layout. Default de, because that "
                         "is what this repository's install plans set -- and a "
                         "qcode is a key POSITION, so the wrong layout types "
                         "the wrong characters and nothing reports it")
    sp.set_defaults(func=cmd_type)

    sp = bench_arg(sub.add_parser("click", help="click at a pixel of the screendump"))
    sp.add_argument("x", type=int)
    sp.add_argument("y", type=int)
    sp.add_argument("--button", default="left", choices=("left", "right", "middle"))
    sp.add_argument("--move-only", action="store_true")
    sp.add_argument("--width", type=int, default=FB_W)
    sp.add_argument("--height", type=int, default=FB_H)
    sp.set_defaults(func=cmd_click)

    sp = bench_arg(sub.add_parser("snapshot", help="freeze disk + firmware + TPM"))
    sp.add_argument("tag")
    sp.add_argument("--replace", action="store_true")
    sp.set_defaults(func=cmd_snapshot)

    sp = bench_arg(sub.add_parser("restore", help="go back to a snapshot"))
    sp.add_argument("tag")
    sp.set_defaults(func=cmd_restore)

    sp = bench_arg(sub.add_parser("snapshots", help="what has been frozen"))
    sp.set_defaults(func=cmd_snapshots)

    # THE HOST'S CONSOLE MUST NOT DECIDE WHAT THE GUEST MAY SAY. On Windows
    # stdout defaults to cp1252, and the first `systemctl status` this bench
    # ever ran died on systemd's own U+25CB -- a traceback about an encoding
    # table, from a tool whose entire job is to relay what a Linux machine
    # printed. Replacement characters are a bad rendering; a traceback is a
    # lost measurement.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    a = p.parse_args()
    return a.func(a) or 0


if __name__ == "__main__":
    sys.exit(main())
