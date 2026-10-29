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
python3 build/lib/brand.py write     # derive the white variant and the tile from the master
python3 build/lib/brand.py verify    # are the derived files what the master makes, byte for byte
python3 build/lib/brand.py show      # the tokens, and the contrast numbers BR4 rests on
./installer/testing/check-brand.py   # the whole rule, in seconds; --self-test plants seven defects
```

`build/lib/brand.py` reads the master, refuses to derive anything from a file
that does not have the four shapes, and writes the derived files beside it. It
imports `palette.py` for the Setup field colour rather than spelling the number
again.

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
