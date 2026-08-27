# Brand assets

These four files are **placeholders**. Drop the real artwork in under exactly
these names and nothing else on the site has to change:

| file | what belongs here |
|---|---|
| `os7-wordmark-light.svg` | the OS/7 wordmark for **light** backgrounds — transparent background, orange `#ff6912` |
| `os7-wordmark-dark.svg`  | the OS/7 wordmark for **dark** backgrounds — transparent background |
| `uib-logo.svg`           | the up in blue mark, used in the footer |
| `favicon.svg`            | tab icon. 64x64 viewBox, must read at 16px |

SVG is preferred; PNG works if the extension in the `<img src>` is changed with
it. The header renders the wordmark at 22px tall, the footer at 20px and 15px,
so anything with fine detail below ~2px stroke will disappear.

Both wordmark files are currently identical: the mark is the same orange on
light and dark, only the surrounding page changes. They are wired separately so
that a version with a different treatment can be dropped into one of them.
