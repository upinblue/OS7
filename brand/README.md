# The mark

This directory is the OS/7 mark. [docs/BRAND-PLAN.md](../docs/BRAND-PLAN.md) is
the authority for it (decisions BR1–BR8); this file says what the files are and
how they are regenerated.

| file | what it is | edited by |
|---|---|---|
| `os7-wordmark.svg` | **the mark.** Four shapes — a stroked O and S, a filled slash and 7 — in up in blue's orange `#ff6912` on transparent, drawn for a dark ground. No `<text>`, no font | a person, deliberately, together with `CANON` in `installer/testing/check-brand.py` |
| `os7-wordmark-white.svg` | the same geometry in white, for the Setup field `#0057ad` and any other ground where orange is below 4.5:1 | nobody — generated |
| `os7-tile.svg` | the 7 alone, on an orange tile with a 12-unit corner: the mark at icon size, and the website's favicon | nobody — generated |

## Regenerating

```bash
python3 build/lib/brand.py write     # derive everything from the master: the two files here,
                                     #   and the two copies the image consumes (below)
python3 build/lib/brand.py verify    # is each of them what the master makes, byte for byte
python3 build/lib/brand.py show      # the tokens, the contrast numbers BR4 rests on, the lockup's transform
./installer/testing/check-brand.py   # the whole rule, in seconds; --self-test is a control plus seven defects
```

`build/lib/brand.py` reads the master, refuses to derive anything from a file
that does not have the four shapes, and writes the derived files beside it. It
imports `palette.py` for the Setup field colour rather than spelling the number
again.

## What the image consumes

Two more files are this directory's output and live where the image needs
them. `write` writes them, `verify` and the check hold them, and `check-image.py`
compares them inside a built ISO (BR6). Neither is edited where it lies.

| file | what it is |
|---|---|
| `build/config/includes.chroot/usr/share/icons/hicolor/scalable/apps/os7.svg` | a byte copy of `os7-tile.svg`: the icon `LOGO=os7` names, and what hook 0035 rasterises into Plymouth's fallback until the boot splash has a theme of its own (BR8) |
| `build/packages/os7-desktop-theme/tree/usr/share/pixmaps/os7-logo-login.svg` | the login screen's lockup: the wordmark in white at scale 2.7 with its cap line's foot on y=180, a rule, and the vendor mark's 215 paths from `upinblue-logo.svg` beside it, white at 85 %. Natural size 216×98, which is what the greeter draws |
| `build/packages/os7-console/tree/usr/share/plymouth/themes/os7/*.png` | the boot splash's seven sprites (BR8): the four shapes, each on a 510×216 canvas so the script places them at one point, the progress frame, a block and a bullet. Rendered by `build/lib/brand_raster.py`, pure Python, and compared by their DECODED pixels — PNG bytes differ between zlib implementations, pixels must not. `os7.script` and `os7.plymouth` beside them are hand-written |

## The rules, in one paragraph each

**One mark (BR1).** The four shapes in `os7-wordmark.svg` are the brand.
Everything else that shows OS/7's name as a picture — in this repository, on the
image, on the website — is a copy of one of these three files or generated from
the master, and `check-brand.py` names every copy that is not.

**Drawn, not set (BR2).** No brand file contains `<text>` or names a font. A
wordmark set in live text is three marks, one per operating system's fallback
font; converting Microsoft's glyphs to outlines is not licensed; and the arm64
image has no Plymouth label plugin to render text with at boot anyway.

**Two inks (BR4).** Orange `#ff6912` on dark ground, white on the Setup field.
Measured, not remembered: orange is 6.75:1 on the website's `#0a0d12`, 7.28:1 on
black, and 2.45:1 on `#0057ad` — which is the whole reason the white file
exists. There is no third ink and no hand-recoloured copy.

**The tile (BR5).** At icon size the mark is the 7 on an orange tile, because
the wordmark is 2.4 times as wide as it is tall and a 16px favicon of it would
be six pixels of cap height.

**`<svg` inside the first 256 bytes (BR7).** GdkPixbuf sniffs a fixed prefix to
decide whether a file is an image, and a long comment above the `<svg>` tag
blanked a real login screen (BUILD-NOTES #111). Every file here keeps its prose
inside the element, so a byte-identical copy into any consumer is safe.

## Provenance

The wordmark was drawn for the website, `upinblue/os7-web`, in `site/brand/`,
and moved here on 2026-10-29 with its four shapes byte for byte; only the prose
moved from above the `<svg>` tag to below it. From here on the website copies
these files, not the other way round (BR3).
