#!/usr/bin/env python3
# =============================================================================
# OS/7 — take the screenshots the harness produced and make them usable on a page.
#
#   tools/prepare-images.py [--source ../out/screenshots]
#
# out/screenshots is gitignored, so web/img holds committed copies. This is the
# step that produces them, rather than a `cp` somebody has to remember.
#
# WHY ANY OF THEM ARE CROPPED. The desktop captures are full 1920x1080 frames of
# a VM, and three of them are mostly empty white: a terminal whose output fills
# the top-left quarter, a file manager saying "Folder is Empty", an Intune dialog
# in the middle of a blank browser. On a dark page an uncropped frame reads as a
# large white rectangle with something small in it. Cropping is the only editing
# done here - no scaling, no compositing, no retouching. What is inside the crop
# is exactly what the machine drew.
#
# The text-mode captures are NOT touched. They are 1280x800 framebuffer frames
# of an 8x16 bitmap font, and every one of them is full of content already.
# =============================================================================

import argparse
import shutil
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("!!! needs Pillow: python -m pip install pillow", file=sys.stderr)
    sys.exit(1)

WEB = Path(__file__).resolve().parent.parent
IMG = WEB / "img"

# destination name -> (source relative to the screenshots dir, crop box or None)
# crop boxes are (left, top, right, bottom) in the source's own pixels.
PLAN = {
    # os7-setup, 1280x800 framebuffer — full frames, never cropped
    "setup-welcome.png":  ("setup/01-welcome.png", None),
    "setup-disk.png":     ("setup/04-disk.png", None),
    "setup-layout.png":   ("setup/05-layout.png", None),
    "setup-confirm.png":  ("setup/06-confirm.png", None),
    "setup-account.png":  ("setup/07-account.png", None),
    "setup-mode.png":     ("setup/08-mode-desktop.png", None),
    "setup-network.png":  ("setup/09-network.png", None),
    "setup-execute.png":  ("setup/10-execute-1.png", None),
    "setup-complete.png": ("setup/12-complete.png", None),

    # the installed console, 1280x800 — also full frames
    "console-motd.png":    ("console/02-motd-and-powershell.png", None),
    "console-zfs.png":     ("console/05-zfs-cmdlets.png", None),

    # the desktop, 1920x1080 — cropped to the part that carries the content
    #
    # the terminal's output occupies the top-left; the rest of the frame is an
    # empty white terminal
    "desktop-powershell.png": ("desktop/02b-desktop-terminal-version.png", (0, 0, 700, 430)),
    # centred on the Intune dialog, keeping enough of the browser around it that
    # it still reads as a window on a desktop
    "desktop-intune.png":     ("desktop/05-desktop-intune.png", (560, 130, 1360, 950)),
    # the file manager window and the panel above it — this one is here for the
    # window chrome, which is the thing the section is about
    "desktop-files.png":      ("desktop/03-desktop-files.png", (20, 0, 990, 645)),

    # NOT carried over: desktop/04-desktop-edge.png. It is Microsoft Edge
    # displaying about:blank — an entirely white frame that says nothing about
    # the product. The organizations page makes the same point with the contents
    # of /etc/os-release instead, which is what an admin would want to see.
}


def main():
    ap = argparse.ArgumentParser(description="Copy and crop screenshots into web/img.")
    ap.add_argument("--source", type=Path, default=WEB.parent / "out" / "screenshots")
    args = ap.parse_args()

    if not args.source.is_dir():
        print(f"!!! no screenshots at {args.source} — they are produced by the VM harness "
              f"and out/ is gitignored, so this only runs on a machine that has taken them.",
              file=sys.stderr)
        sys.exit(1)

    IMG.mkdir(exist_ok=True)
    for dest, (rel, box) in PLAN.items():
        src = args.source / rel
        if not src.is_file():
            print(f"    MISSING {rel} — {dest} left as it is")
            continue
        out = IMG / dest
        if box is None:
            shutil.copyfile(src, out)
            with Image.open(out) as im:
                print(f"    {dest:26s} {im.width}x{im.height}  verbatim")
        else:
            with Image.open(src) as im:
                cropped = im.crop(box).convert("RGB")
                cropped.save(out, optimize=True)
                print(f"    {dest:26s} {cropped.width}x{cropped.height}  "
                      f"cropped from {im.width}x{im.height} at {box}")

    total = sum(p.stat().st_size for p in IMG.glob("*.png"))
    print(f"\n    {len(list(IMG.glob('*.png')))} files, {total / 1024:.0f} KB")


if __name__ == "__main__":
    main()
