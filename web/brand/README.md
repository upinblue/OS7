# Brand assets

Four files, all real. Nothing here is a placeholder any more.

| file | what it is |
|---|---|
| `os7-wordmark.svg` | the OS/7 wordmark. Drawn geometry, orange on transparent |
| `favicon.svg` | tab icon: the 7 from the wordmark, reversed out of an orange tile |
| `uib-logo.webp` | the up in blue acronym mark, from upinblue.com, 2026-08-27 |
| — | there is no light/dark pair of anything, and that is the point below |

## One file per mark, on purpose

Both marks sit on **transparent** ground, so the page shows through them: near
black on the dark theme, white on the light one. The OS/7 wordmark is orange
strokes with nothing behind them; the up in blue mark is a blue frame whose
middle is genuinely open, not filled white. Neither needs a second file and
neither needs a CSS swap — the pair of `.logo-light` / `.logo-dark` rules the
site used to carry is gone.

For the up in blue mark that is a property of the asset rather than a choice:
measured off the file, 1500x844 RGBA with alpha 0..255, and the blue is exactly
`#1289ff` — the value `css/site.css` carries as `--blue` and
[docs/DECISIONS.md](../../docs/DECISIONS.md) records as up in blue's colour. It
is served as WebP because that is what it is; Squarespace names the file `.png`
and sends WebP bytes.

## The wordmark is drawn, not set

`os7-wordmark.svg` contains no `<text>` and depends on no font. An ellipse ring,
a bezier spine, a parallelogram and a polygon, at cap height 48 with a weight of
6.4.

Two reasons it had to be that way, both written into the file itself:

- **A wordmark made of live text is not one mark but three.** The placeholder
  this replaces was `<text>` in the system sans, which is Segoe UI Light on
  Windows, Helvetica Neue Light on macOS and DejaVu Sans on a Linux desktop.
- **The obvious fix was not available.** Converting those Segoe UI Light glyphs
  to outlines would have matched the placeholder exactly and would have put
  Microsoft font outlines on a public website, which that font's licence does
  not allow.

Two of the four shapes are filled rather than stroked. A stroke's butt cap is
cut perpendicular to the stroke, and the slash and the diagonal of the 7 both
have to be cut **horizontally**; on strokes that steep the difference is about
twenty degrees, which is invisible in the source and obvious at 150px.

## Replacing any of it

Same filenames, and nothing else on the site changes. The header renders the
wordmark at 22px tall, the footer at 20px, and the up in blue mark at 18px, so
detail below roughly 2px of stroke disappears at those sizes. If a replacement
is a bitmap rather than SVG, the extension in the `<img src>` has to change with
it — seven HTML files, and the header and footer of four of them.
