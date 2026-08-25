#!/usr/bin/env python3
"""
Driving a QEMU guest by its SCREEN — the other half of vmconsole.py.

vmconsole drives a guest over its serial line, which is enough for everything
whose result is a string. It is not enough for anything whose result is what a
person sees, and OS/7 has two of those: spike S1 (does the look work) and
os7-setup itself, whose entire deliverable is a screen.

So this adds three things, all over QMP:

  * `screendump` — QEMU keeps the scanout in memory even under `-display none`,
    so a headless run still has a framebuffer to photograph. PPM out (every QEMU
    build can write it, and it parses in five lines), PNG written here for
    looking at.
  * `send-key` — keypresses as qcodes into a USB keyboard, so they travel the
    real path: HID, the kernel keymap, the VT's XLATE translation. Writing
    escape sequences into a pipe would prove nothing about the two layers that
    actually differ between a VT and a serial line.
  * reading the screen back THROUGH THE CONSOLE FONT. A cell is cut out of the
    screendump, thresholded, and compared with the glyph the PSF holds for the
    character that was supposed to be there. That is the difference between
    "the screenshot looks right" and a measurement.

The VM shape is fixed and deliberate:

  virtio-gpu-pci   a display with no window. Its default 1280x800 with the 16x32
                   console font is exactly the 80x25 SETUP-PLAN §2.4 names as the
                   reference geometry, so screens are measured at the size they
                   were drawn for.
  qemu-xhci+usb-kbd  HID rather than virtio-input: it is in every kernel and every
                   initramfs, and a test must not fail because a driver was absent.
  -kernel/-initrd  taken out of the ISO, so each run can set its own command
                   line. Driving GRUB's editor over a serial console is exactly
                   what docs/HANDOFF.md §5 warns about.

No dependencies beyond the standard library.
"""
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from vmconsole import Console, live_login, qemu_prefix, run, to_plain_bash   # noqa: F401

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# virtio-gpu-pci's default mode. Named rather than assumed, because every pixel
# assertion is in these coordinates and firmware picking something else would
# otherwise fail as "wrong colour" instead of "wrong resolution".
FB_W, FB_H = 1280, 800


# ---------------------------------------------------------------------------
# QMP
# ---------------------------------------------------------------------------
class Qmp:
    def __init__(self, path, timeout=120):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(path)
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if time.time() > deadline:
                    raise SystemExit(f"QMP socket never appeared: {path}")
                time.sleep(0.2)
        self.f = self.sock.makefile("rwb", buffering=0)
        self._read()                        # the greeting
        self.cmd("qmp_capabilities")

    def _read(self):
        """The next reply, skipping asynchronous events."""
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP closed")
            msg = json.loads(line)
            if "event" in msg:
                continue
            return msg

    def cmd(self, name, **args):
        payload = {"execute": name}
        if args:
            payload["arguments"] = args
        self.f.write((json.dumps(payload) + "\n").encode())
        reply = self._read()
        if "error" in reply:
            raise SystemExit(f"QMP {name} failed: {reply['error']}")
        return reply.get("return")

    def screendump(self, path):
        if os.path.exists(path):
            os.remove(path)
        self.cmd("screendump", filename=path, format="ppm")
        for _ in range(100):                # the write is asynchronous to the reply
            if os.path.exists(path) and os.path.getsize(path) > 0:
                time.sleep(0.1)
                return
            time.sleep(0.1)
        raise SystemExit(f"screendump produced nothing at {path}")

    def send_key(self, qcode, hold_ms=20):
        """Press and release one key.

        HOLD TIME IS SET EXPLICITLY, and the default is the reason. QEMU holds a
        key for 100 ms unless told otherwise, so keys sent closer together than
        that OVERLAP — and a USB HID keyboard cannot report two independent
        presses at once, so all but one are lost. Typing a passphrase at 80 ms a
        key produced a field with one character in it and a Setup correctly
        complaining that it was too short.

        20 ms is longer than one USB frame and shorter than any sensible gap
        between two calls, so a caller that sleeps at all gets clean keystrokes.
        """
        self.cmd("send-key",
                 keys=[{"type": "qcode", "data": qcode}],
                 **{"hold-time": hold_ms})

    def close(self):
        try:
            self.f.close()
            self.sock.close()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path}: not a P6 PPM")
    fields, i = [], 2
    while len(fields) < 3:
        while i < len(data) and data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while j < len(data) and not data[j:j + 1].isspace():
            j += 1
        fields.append(int(data[i:j]))
        i = j
    i += 1                                  # exactly one whitespace byte follows
    w, h, maxval = fields
    if maxval != 255:
        raise SystemExit(f"{path}: maxval {maxval}, expected 255")
    return w, h, data[i:i + w * h * 3]


def write_png(path, w, h, rgb):
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def histogram(w, h, rgb, box=None):
    x0, y0, x1, y1 = box or (0, 0, w, h)
    counts = {}
    for y in range(max(0, y0), min(h, y1)):
        base = y * w * 3
        for x in range(max(0, x0), min(w, x1)):
            p = base + x * 3
            key = (rgb[p], rgb[p + 1], rgb[p + 2])
            counts[key] = counts.get(key, 0) + 1
    return sorted(counts.items(), key=lambda kv: -kv[1])


def hexc(c):
    return "#%02x%02x%02x" % c


# ---------------------------------------------------------------------------
# Reading the screen back through the console font
#
# A missing glyph gives a blank cell; a font that never loaded gives the
# kernel's TER16x32 shapes; a bad subset gives the wrong glyph at the right
# position. None of those match, and none of them is reliably visible by eye.
# The expected bitmap comes from the PSF on disk, so the check is independent of
# whatever drew the screen.
# ---------------------------------------------------------------------------
def load_font(path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "psf", os.path.join(REPO, "build", "lib", "psf.py"))
    psf = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(psf)
    if path.endswith(".gz"):
        import gzip
        raw = path[:-3]
        if not os.path.exists(raw):
            with gzip.open(path, "rb") as fin, open(raw, "wb") as fout:
                shutil.copyfileobj(fin, fout)
        path = raw
    return psf.Font(path)


def cell_bitmap(w, rgb, row, col, cw, ch, fg):
    """The cell as booleans: True where the pixel is the foreground colour."""
    out = []
    for y in range(ch):
        line = []
        for x in range(cw):
            p = ((row * ch + y) * w + col * cw + x) * 3
            line.append((rgb[p], rgb[p + 1], rgb[p + 2]) == fg)
        out.append(line)
    return out


def verify_glyphs(w, h, rgb, font, row, col, text, fg=(255, 255, 255)):
    """Compare a run of cells on screen with the font's own glyphs.

    Returns (wrong, missing): cells whose pixels differ, and characters the font
    has no glyph for at all.
    """
    cw, ch = font.width, font.height
    wrong, missing = [], []
    for i, rune in enumerate(text):
        if ord(rune) not in font.table:
            missing.append(rune)
            continue
        want = font.bitmap(font.table[ord(rune)])
        got = cell_bitmap(w, rgb, row, col + i, cw, ch, fg)
        if got != want:
            wrong.append((i, rune))
    return wrong, missing


def read_text(w, h, rgb, font, row, col, length, fg=(255, 255, 255)):
    """OCR through the font: what characters are in these cells?

    Every glyph in the PSF is compared against the cell and the one that matches
    exactly wins. It is not fuzzy and it is not clever - the screen was drawn
    from this font, so an exact match is the only correct answer, and 'no glyph
    matched' is a finding rather than a reason to guess.

    EIGHT BITMAPS IN THIS FONT BELONG TO MORE THAN ONE CODEPOINT, and one of
    them is the hyphen. U+002D, U+00AD, U+2010 and U+2212 are four separate
    glyphs in the subset drawing the identical picture, so a dash on the glass
    cannot be told apart from any of the others - it is the same pixels. The
    only question is which name to return, and the answer has to be the same
    every time.

    THE LOWEST CODEPOINT WINS. It is the ASCII one wherever there is an ASCII
    one, which is the character a program printing text actually used; the
    alternatives are in Latin-1 and General Punctuation. Before this, the winner
    was whichever came first in the PSF's unicode table - that is glyph order,
    an artefact of how the subset was built - and a plain `-` decoded as U+00AD
    SOFT HYPHEN. Nothing caught it because no assertion in this repository had
    ever put a hyphen in a needle. BUILD-NOTES #46.
    """
    cw, ch = font.width, font.height
    by_bits = {}
    for cp, glyph in font.table.items():
        key = tuple(tuple(r) for r in font.bitmap(glyph))
        if cp < by_bits.get(key, 0x110000):
            by_bits[key] = cp
    out = []
    for i in range(length):
        key = tuple(tuple(r) for r in cell_bitmap(w, rgb, row, col + i, cw, ch, fg))
        cp = by_bits.get(key)
        out.append(chr(cp) if cp is not None else "�")
    return "".join(out)


# ---------------------------------------------------------------------------
# The VM
# ---------------------------------------------------------------------------
class Lab:
    """One VM's worth of state: firmware vars, boot files, payload, screendumps."""

    MEM = "4096"
    CPUS = "4"

    def __init__(self, name, iso=None, target_gb=0, iso_as_disk=False):
        self.name = name
        self.target_gb = target_gb
        # How the live medium is attached. As a CD it is `type=rom` to lsblk and
        # an installer skips it without thinking; as a block device it is a
        # DISK, and refusing it is L12's actual requirement. Real installs are
        # from USB, so the block device is the faithful shape - and the only one
        # in which "the setup medium is listed and never selectable" can be
        # tested at all.
        self.iso_as_disk = iso_as_disk
        self.dir = os.path.join(REPO, ".vm", name)
        self.target = os.path.join(self.dir, "target.qcow2")
        self.shots = os.path.join(self.dir, "shots")
        self.iso = iso or os.path.join(REPO, "out", "os7-arm64.iso")
        self.kernel = os.path.join(self.dir, "vmlinuz")
        self.initrd = os.path.join(self.dir, "initrd")
        self.vars = os.path.join(self.dir, "edk2-vars.fd")
        self.payload = os.path.join(self.dir, "payload.iso")
        self.qmpsock = os.path.join(self.dir, "qmp.sock")

    # -- setup --------------------------------------------------------------
    def prepare(self, payload_dir=None):
        os.makedirs(self.dir, exist_ok=True)
        os.makedirs(self.shots, exist_ok=True)
        if not os.path.exists(self.iso):
            raise SystemExit(f"ISO not found: {self.iso}\nBuild it with: make build-arm64")
        if not os.path.exists(self.vars):
            pre = qemu_prefix()
            for c in ("edk2-arm-vars.fd", "edk2-aarch64-vars.fd"):
                src = os.path.join(pre, "share", "qemu", c)
                if os.path.exists(src):
                    shutil.copy(src, self.vars)
                    break
            else:
                raise SystemExit("no EDK2 vars template found")
        self.extract_boot_files()
        if self.target_gb:
            # A blank disk for the guest to install onto. Recreated from scratch
            # on every prepare(): a run that starts on a disk the previous run
            # left half-partitioned is not testing what it thinks it is.
            if os.path.exists(self.target):
                os.remove(self.target)
            run("qemu-img", "create", "-f", "qcow2", self.target, f"{self.target_gb}G",
                stdout=subprocess.DEVNULL)
            print(f"    target   {self.target} ({self.target_gb}G, blank)")
        if payload_dir is not None:
            self.build_payload(payload_dir)

    def extract_boot_files(self):
        """Pull the kernel and initrd out of the ISO, through a container.

        macOS will not mount this image: `hdiutil attach` reports "no mountable
        file systems" on the El Torito hybrid that build/lib/arm64-efi-remaster.sh
        produces. The container has loop mounts.

        The names carry the kernel version, so they are globbed rather than
        guessed - and exactly one of each is required, because two kernels on the
        medium would mean the choice was being made silently.

        RE-EXTRACTED WHENEVER THE ISO IS NEWER, and the mtime is the whole point
        rather than a nicety. casper matches the medium by UUID: the initrd
        carries /conf/uuid.conf and the medium carries .disk/casper-uuid-<kver>,
        and a build writes a fresh pair every time. Cached files from the
        PREVIOUS ISO therefore boot a kernel of the right version against a
        medium it will not accept, and casper says "Unable to find a medium
        containing a live file system" - which reads as a broken ISO and is not.
        Measured 2026-08-24: initrd 3dafea6c-…, medium 5c231671-…, fifteen
        minutes of a walk that was testing nothing.
        """
        fresh = (os.path.exists(self.kernel) and os.path.exists(self.initrd)
                 and os.path.getmtime(self.kernel) >= os.path.getmtime(self.iso)
                 and os.path.getmtime(self.initrd) >= os.path.getmtime(self.iso))
        if fresh:
            return
        if os.path.exists(self.kernel) or os.path.exists(self.initrd):
            print("    the ISO is newer than the extracted boot files; re-extracting")
            for f in (self.kernel, self.initrd):
                if os.path.exists(f):
                    os.chmod(f, 0o644)
                    os.remove(f)
        print("    extracting the kernel and initrd from the ISO …")
        run("docker", "run", "--rm", "--privileged", "--platform", "linux/arm64",
            "-v", f"{os.path.dirname(self.iso)}:/iso:ro", "-v", f"{self.dir}:/vm",
            "os7-build:arm64", "bash", "-c",
            f"set -e; mkdir -p /mnt/iso; mount -o loop,ro /iso/{os.path.basename(self.iso)} /mnt/iso; "
            "k=$(ls /mnt/iso/casper/vmlinuz*); i=$(ls /mnt/iso/casper/initrd*); "
            'test $(echo "$k" | wc -l) -eq 1 && test $(echo "$i" | wc -l) -eq 1; '
            'cp "$k" /vm/vmlinuz; cp "$i" /vm/initrd; '
            'echo "kernel=$(basename $k)"; umount /mnt/iso')
        for f in (self.kernel, self.initrd):
            if not os.path.exists(f):
                raise SystemExit(f"extraction did not produce {f}")

    def build_payload(self, stage):
        """An ISO9660 volume from a staged directory.

        KEEP FILENAMES TO ONE DOT. `hdiutil makehybrid` writes ISO9660 names with
        at most one, so `x.psf.gz` arrives in the guest as `xpsf.gz` and the error
        names the path you asked for. docs/BUILD-NOTES.md #28.
        """
        if os.path.exists(self.payload):
            os.remove(self.payload)
        run("hdiutil", "makehybrid", "-iso", "-joliet",
            "-default-volume-name", self.label, "-o", self.payload, stage,
            stdout=subprocess.DEVNULL)
        print(f"    payload  {self.payload}")

    @property
    def label(self):
        return f"OS7{self.name.upper()}"[:11]

    # -- running ------------------------------------------------------------
    def qemu_args(self, cmdline, payload=True):
        pre = qemu_prefix()
        code = os.path.join(pre, "share", "qemu", "edk2-aarch64-code.fd")
        if os.path.exists(self.qmpsock):
            os.remove(self.qmpsock)
        args = [
            "qemu-system-aarch64",
            "-machine", "virt,accel=hvf", "-cpu", "host",
            "-smp", self.CPUS, "-m", self.MEM,
            "-drive", f"if=pflash,format=raw,file={code},readonly=on",
            "-drive", f"if=pflash,format=raw,file={self.vars}",
            "-device", f"virtio-gpu-pci,xres={FB_W},yres={FB_H}",
            "-device", "qemu-xhci", "-device", "usb-kbd",
            "-display", "none", "-monitor", "none", "-serial", "stdio",
            "-qmp", f"unix:{self.qmpsock},server,nowait",
            "-kernel", self.kernel, "-initrd", self.initrd, "-append", cmdline,
        ]
        if self.iso_as_disk:
            # FIRST, so it enumerates before the target: the disk screen lists
            # in kernel-name order and the medium has to be the one the harness
            # lands on. casper finds /casper/filesystem.squashfs by scanning
            # block devices, so a raw ISO on virtio-blk boots exactly as a USB
            # stick does.
            args += ["-drive", f"if=none,id=live,file={self.iso},format=raw,readonly=on",
                     "-device", "virtio-blk-pci,drive=live,serial=os7live"]
        else:
            args += ["-cdrom", self.iso]
        if payload and os.path.exists(self.payload):
            args += ["-drive", f"if=none,id=payload,file={self.payload},format=raw,readonly=on",
                     "-device", "virtio-blk-pci,drive=payload"]
        if self.target_gb and os.path.exists(self.target):
            # serial= so the guest gets a /dev/disk/by-id/virtio-<serial> entry.
            # os7-setup stores a by-id path in the plan (§6.6, L12), and a target
            # with no stable name would exercise the fallback instead of the
            # thing being built.
            args += ["-drive", f"if=none,id=target,file={self.target},format=qcow2",
                     "-device", "virtio-blk-pci,drive=target,serial=os7target"]
        return args

    def boot(self, cmdline, label, login=True, payload=True):
        """Start the VM. Returns (Console, Qmp)."""
        print(f"    booting ({label}) …")
        c = Console(self.qemu_args(cmdline, payload),
                    os.path.join(self.dir, f"{label}.serial.log"))
        q = Qmp(self.qmpsock)
        if login:
            live_login(c)
            to_plain_bash(c)
        return c, q

    def mount_payload(self, c):
        """Mount the payload by LABEL, and prove it with a marker from a FILE.

        By label because device names come from PCI enumeration order. Under
        sudo because the live session is the `ubuntu` user. And the
        acknowledgement comes off the volume rather than from `&& echo OK`,
        because the shell echoes what was typed - docs/BUILD-NOTES.md #16, which
        an earlier version of this reported success for a mount that had failed
        with "must be superuser".
        """
        c.send(f"sudo mount -o ro -L {self.label} /mnt")
        c.settle()

    def shoot(self, q, name, keep_ppm=False):
        """Screendump, save a PNG, return the parsed pixels."""
        ppm = os.path.join(self.shots, f"{name}.ppm")
        png = os.path.join(self.shots, f"{name}.png")
        q.screendump(ppm)
        w, h, rgb = read_ppm(ppm)
        write_png(png, w, h, rgb)
        if not keep_ppm:
            os.remove(ppm)
        print(f"      {png}  ({w}x{h})")
        return w, h, rgb

    def reset(self):
        shutil.rmtree(self.dir, ignore_errors=True)
        print(f"    removed {self.dir}")


# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
def assert_uniform(hist, total, want, what, floor=0.99):
    """The region must be EXACTLY one colour, and that colour must be `want`."""
    dominant, n = hist[0]
    if dominant != want:
        print(f"      FAIL  {what}: {hexc(dominant)}, expected {hexc(want)}")
        return False
    if n < total * floor:
        print(f"      FAIL  {what}: only {100.0 * n / total:.1f}% of the region")
        return False
    print(f"      ok    {what}: exactly {hexc(want)}")
    return True


def assert_region(w, h, rgb, cell, box, allowed, want, what):
    """Every pixel in a CHARACTER-CELL rectangle must be one of `allowed`, and
    `want` must be the most common.

    Regional, and that is the point. Spike S1 shipped a progress bar in the
    wrong colour past three checks that all asked "is #1289ff present in the
    frame" — it was, in the title stripe, on every screen. Cell coordinates
    rather than pixels so the check survives a font-size change.
    """
    cw, ch = cell
    c0, r0, c1, r1 = box
    hist = histogram(w, h, rgb, box=(c0 * cw, r0 * ch, c1 * cw, r1 * ch))
    stray = [c for c, _ in hist if c not in allowed]
    if stray:
        print(f"      FAIL  {what}: unexpected {', '.join(hexc(c) for c in stray[:3])}")
        return False
    if hist[0][0] != want:
        print(f"      FAIL  {what}: {hexc(hist[0][0])} dominates, expected {hexc(want)}")
        return False
    print(f"      ok    {what}: {hexc(want)}")
    return True
