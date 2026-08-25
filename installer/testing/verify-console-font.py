#!/usr/bin/env python3
"""
Does the INSTALLED console actually display Cascadia Mono? (D15, SETUP-PLAN §2.8)

    ./verify-console-font.py            boot the installed disk and check

Everything about D15 up to now is a claim about files: the .deb hashed, the TTF
hashed, the PSFs rasterised, `psf.py verify` green, the bytes inside the ISO
equal to the pin. None of that is a console displaying a glyph, and this repo's
rule is that a verifier is a diagnostic like any other.

WHY THIS BOOTS THE DISK AND NOT THE LIVE MEDIUM, which is the whole design:

D15 is a claim about the **installed** system. The live image also carries
`/etc/default/console-setup`, so a live boot would light up green — and would be
a correct measurement of the wrong moment, because on the installed system the
font is applied by `console-setup` from the INITRAMFS (§2.4, L20) and that is a
different path with a different chance of failing. Session os7-b1 lost a netplan
file to exactly this shape on the same day: every check correct, every check
taken before the medium was removed (L30).

So: no ISO attached, the firmware finds the bootloader itself, and the machine
under the camera is the one a user would have.

WHAT IS ASSERTED, in order, because each fails differently:

  1. the disk boots to a login prompt                  - install still works
  2. the PSF ON THE DISK hashes to the pinned value    - the right file arrived
  3. `setfont` is not needed: the console already      - console-setup ran from
     shows the font                                      the initramfs
  4. the glyphs on the FRAMEBUFFER match the PSF's     - THE DELIVERABLE
     own bitmaps, cell for cell
  5. a glyph Fixedsys lacks and Cascadia has renders   - it is THIS font and not
     as Cascadia draws it                                the other one

5 is the check nothing else can make. 4 alone would pass if the console were
showing Fixedsys, because both fonts are in the image and both draw `A` at 16×32
— so the test has to name a glyph the two do not share.
"""
import os
import sys
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import vmscreen                                                    # noqa: E402
from vmscreen import Qmp, load_font, verify_glyphs, hexc           # noqa: E402
from vmconsole import Console, qemu_prefix                         # noqa: E402

# The same VM run-phase3.py installs, deliberately: this is a check ON that
# machine, not a second install with its own opinions.
VM = "phase3"
PASSPHRASE = "os7-phase3-passphrase"
PASSWORD = "os7-phase3-password"
USERNAME = "os7admin"

FONT_GZ = "/usr/share/consolefonts/os7-console-16x32.psf.gz"
LICENCE = "/usr/share/doc/os7-console-font/LICENSE"

# Row 0 is the test line; it is written after the screen is cleared and after
# getty is stopped, so nothing else can be on it.
#
# THE CONTENT IS CHOSEN, NOT ARBITRARY. `Grüße` and `ÄÖÜ` are the German cover;
# the box and block runs are what the UI is built from; and `▲▼` are the two
# glyphs FIXEDSYS DOES NOT HAVE (SESSION-PHASE1-SETUP — it is why SelectionList
# draws ↑↓ instead). If the console were somehow showing Fixedsys, those two
# cells could not match Cascadia's bitmaps.
LINES = [
    "ABCDEFGHIJKLM abcdefghijklm 0123456789",
    "Gruesse: ÄÖÜ äöü ß — 'quoted' \"double\"",
    "┌──┬──┐ ╔══╦══╗ █▓▒░ ▀▄ • ↑↓ ▲▼",
]
DISTINCTIVE = "▲▼"          # present in Cascadia, absent from Fixedsys

FB_W, FB_H = vmscreen.FB_W, vmscreen.FB_H


def disk_and_camera(lab):
    """The installed disk, with nothing else attached — plus a framebuffer.

    `run-phase3.py`'s `disk_only_args()` with two additions and no subtractions:
    a virtio-gpu so there is something to photograph, and a QMP socket to
    photograph it through. Still NO `-kernel`/`-initrd` and still NO ISO: the
    firmware has to find the bootloader, and the initramfs on the disk has to be
    the one that applies the font. Removing either would answer a different
    question.
    """
    pre = qemu_prefix()
    code = os.path.join(pre, "share", "qemu", "edk2-aarch64-code.fd")
    if os.path.exists(lab.qmpsock):
        os.remove(lab.qmpsock)
    return [
        "qemu-system-aarch64",
        "-machine", "virt,accel=hvf", "-cpu", "host",
        "-smp", lab.CPUS, "-m", lab.MEM,
        "-drive", f"if=pflash,format=raw,file={code},readonly=on",
        "-drive", f"if=pflash,format=raw,file={lab.vars}",
        "-device", f"virtio-gpu-pci,xres={FB_W},yres={FB_H}",
        "-device", "qemu-xhci", "-device", "usb-kbd",
        "-display", "none", "-monitor", "none", "-serial", "stdio",
        "-qmp", f"unix:{lab.qmpsock},server,nowait",
        "-drive", f"if=none,id=target,file={lab.target},format=qcow2",
        "-device", "virtio-blk-pci,drive=target,serial=os7target",
    ]


def fetch_font(lab):
    """The Cascadia PSF, taken OUT OF THE SHIPPED ISO.

    Not from `build/` — nothing there survives a build (`build.sh` stages into a
    temporary tree), and more importantly a font sitting in the source tree is
    not the one the machine was installed from. The disk got its copy by
    `unsquashfs` out of this image, so reading the screen through this file
    compares the console against the artefact rather than against an intention.

    Same shape as run-phase3.py's own `fetch_font`, which does this for Fixedsys.
    """
    out = os.path.join(lab.dir, "os7-console-16x32.psf")
    if os.path.exists(out):
        return out
    os.makedirs(lab.dir, exist_ok=True)
    subprocess.run(
        ["docker", "run", "--rm", "--privileged", "--platform", "linux/arm64",
         "-v", f"{os.path.dirname(lab.iso)}:/iso:ro", "-v", f"{lab.dir}:/out",
         "os7-build:arm64", "bash", "-c",
         f"set -e; mkdir -p /mnt/iso /mnt/sq; "
         f"mount -o loop,ro /iso/{os.path.basename(lab.iso)} /mnt/iso; "
         "mount -t squashfs -o loop,ro /mnt/iso/casper/filesystem.squashfs /mnt/sq; "
         "gunzip -c /mnt/sq/usr/share/consolefonts/os7-console-16x32.psf.gz "
         "> /out/os7-console-16x32.psf; "
         "umount /mnt/sq; umount /mnt/iso"],
        check=True, stdout=subprocess.DEVNULL)
    return out


def ask(c, command, marker, timeout=120):
    """Run a command in the guest and return its output.

    The marker is echoed by a SEPARATE command rather than appended to this one:
    BUILD-NOTES #16 — never expect a marker the typed command itself contains,
    or the shell's echo of the line reports success for a command that never ran.
    """
    c.send(command)
    c.send(f"echo {marker}")
    c.expect(marker, timeout, marker)
    return c.text()


def main():
    lab = vmscreen.Lab(VM)
    for need, what in ((lab.target, "an installed disk"),
                       (lab.vars, "a firmware variable store")):
        if not os.path.exists(need):
            print(f"      FAIL  no {what} at {need}.")
            print("            Run `./run-phase3.py install` first.")
            return 1
    os.makedirs(lab.shots, exist_ok=True)

    pin = {}
    with open(os.path.join(REPO, "build", "config", "os7-release.conf")) as f:
        for line in f:
            if line.startswith("OS7_CASCADIA_"):
                k, _, v = line.partition("=")
                pin[k.strip()] = v.strip().strip('"')

    # Before the VM, not after: extracting this needs Docker and a loop mount,
    # and finding that out at the end costs a five-minute boot to learn it.
    font = load_font(fetch_font(lab))
    print(f"    font     {font.width}x{font.height}, {len(font.table)} codepoints, out of the ISO")

    log = os.path.join(lab.dir, "font.serial.log")
    print("  verify-console-font — the installed disk, no ISO attached")
    print(f"    serial   {log}")
    c = Console(disk_and_camera(lab), log)
    ok = True
    try:
        i = c.expect([r"unlock disk", r"Enter passphrase", r"passphrase for",
                      r"\(initramfs\)", r"Kernel panic", r"No bootable"],
                     600, "the passphrase prompt")
        if i >= 3:
            print(c.text()[-2000:])
            print("      FAIL  never reached the passphrase prompt")
            return 1
        c.send(PASSPHRASE)

        j = c.expect([r"\blogin:", r"\(initramfs\)", r"Kernel panic"],
                     900, "a login prompt")
        if j >= 1:
            print(c.text()[-2000:])
            print("      FAIL  unlocked, but never reached a login prompt")
            return 1
        print("      ok    1/5 the installed disk booted to a login prompt")

        from vmconsole import live_login, to_plain_bash
        live_login(c, user=USERNAME, password=PASSWORD)
        to_plain_bash(c)

        # 2. THE FILE ON THE DISK. unsquashfs copied it out of the image; this
        #    asks whether what landed is what was pinned, on the machine itself
        #    rather than in the ISO.
        out = ask(c, f"sha256sum {FONT_GZ} | cut -c1-64 | tr -d '\\n' | "
                     f"sed 's/^/DISKHASH=/' && echo", "HASH-DONE")
        got = ""
        for line in out.splitlines():
            if line.startswith("DISKHASH=") and len(line) > 20:
                got = line[len("DISKHASH="):].strip()
        # The pin is over the UNCOMPRESSED psf, so compare gunzipped.
        out2 = ask(c, f"gunzip -c {FONT_GZ} | sha256sum | cut -c1-64 | "
                      f"sed 's/^/RAWHASH=/'", "RAW-DONE")
        raw = ""
        for line in out2.splitlines():
            if line.startswith("RAWHASH=") and len(line) > 20:
                raw = line[len("RAWHASH="):].strip()
        want = pin.get("OS7_CASCADIA_PSF_SHA256_16x32", "")
        if raw != want:
            print(f"      FAIL  2/5 the PSF on the disk is not the pinned one")
            print(f"            pinned {want}")
            print(f"            disk   {raw}")
            ok = False
        else:
            print(f"      ok    2/5 the PSF on the disk hashes to the pin — {raw[:16]}…")

        lic = ask(c, f"test -s {LICENCE} && echo LIC-PRESENT || echo LIC-MISSING",
                  "LIC-DONE")
        if "LIC-PRESENT" not in lic:
            print("      FAIL  the OFL licence is not on the installed system (L29)")
            ok = False
        else:
            print("      ok    2b/5 the OFL licence is on the installed system")

        # 3+4. THE SCREEN. getty is stopped first so nothing writes over the
        #      test line, and the screen is cleared and homed so row 0 col 0 is
        #      known. `setfont` is deliberately NOT called: if the console is
        #      showing Cascadia, console-setup already did it from the initramfs,
        #      and calling setfont here would prove only that the file loads.
        c.send("sudo systemctl stop getty@tty1.service")
        c.send("sleep 1")
        c.send(r"printf '\033[H\033[2J' | sudo tee /dev/tty1 >/dev/null")
        for n, text in enumerate(LINES):
            c.send(f"printf '%s\\n' {shq(text)} | sudo tee /dev/tty1 >/dev/null")
        ask(c, "sync", "PAINT-DONE")

        q = Qmp(lab.qmpsock)
        ppm = os.path.join(lab.shots, "installed-console.ppm")
        q.screendump(ppm)
        w, h, rgb = vmscreen.read_ppm(ppm)
        png = os.path.join(lab.shots, "installed-console.png")
        vmscreen.write_png(png, w, h, rgb)
        print(f"      screen   {png}")


        # The foreground colour is MEASURED, not assumed: the installed console
        # carries OS/7's palette (D6), where the default attribute is index 7 =
        # #C0C0C0 and not white. Guessing (255,255,255) would report every cell
        # as wrong and look like a font failure.
        fg = dominant_ink(w, h, rgb, font.height)
        print(f"      ink      {hexc(fg)}")

        total_wrong, total_missing = [], []
        for n, text in enumerate(LINES):
            wrong, missing = verify_glyphs(w, h, rgb, font, n, 0, text, fg=fg)
            total_wrong += [(n, i, r) for i, r in wrong]
            total_missing += missing
        cells = sum(len(t) for t in LINES)
        if total_wrong or total_missing:
            print(f"      FAIL  4/5 {len(total_wrong)} of {cells} cells differ "
                  f"from the font's own bitmaps")
            for n, i, r in total_wrong[:12]:
                print(f"            row {n} col {i}: {r!r} (U+{ord(r):04X})")
            if total_missing:
                print(f"            font has no glyph for: {''.join(total_missing)}")
            ok = False
        else:
            print(f"      ok    3/5 console-setup applied it — no setfont was called")
            print(f"      ok    4/5 all {cells} cells match the PSF bitmap for bitmap")

        # 5. IS IT THIS FONT? Both PSFs are in the image. ▲▼ are in Cascadia and
        #    NOT in Fixedsys, so these two cells can only match if the console is
        #    showing the font this test is about.
        row, col = 2, LINES[2].index(DISTINCTIVE[0])
        wrong, missing = verify_glyphs(w, h, rgb, font, row, col, DISTINCTIVE, fg=fg)
        if wrong or missing:
            print(f"      FAIL  5/5 {DISTINCTIVE} does not match — the console may "
                  f"be showing a different font")
            ok = False
        else:
            print(f"      ok    5/5 {DISTINCTIVE} renders as Cascadia draws it — "
                  f"glyphs Fixedsys does not have")
        q.close()
    finally:
        c.close()

    print("\n  PASS — the installed console displays Cascadia Mono" if ok else
          "\n  FAIL")
    return 0 if ok else 1


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def dominant_ink(w, h, rgb, cell_h):
    """The most common non-background colour in the top three text rows.

    Background is whatever fills the most pixels; ink is the runner-up. Both are
    read off the screen rather than assumed, because the installed console runs
    OS/7's palette and its default foreground is #C0C0C0, not white.
    """
    from collections import Counter
    counts = Counter()
    for y in range(min(h, cell_h * 3)):
        for x in range(0, w, 2):
            p = (y * w + x) * 3
            counts[(rgb[p], rgb[p + 1], rgb[p + 2])] += 1
    ranked = counts.most_common(2)
    return ranked[1][0] if len(ranked) > 1 else ranked[0][0]


if __name__ == "__main__":
    sys.exit(main())
