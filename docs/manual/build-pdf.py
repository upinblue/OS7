#!/usr/bin/env python3
"""
docs/manual/{de,en}/*.md  ->  one A4 PDF per language.

Markdown is the source and the PDF is a rendering of it, so there is exactly
one place a sentence lives. The chain is:

    chapter files, in filename order
      -> python-markdown (tables, fenced code, attribute lists, footnotes)
      -> one HTML document with a title page and a generated contents
      -> Microsoft Edge, driven by Playwright, printing to A4

EDGE RATHER THAN A LATEX TOOLCHAIN, and Playwright rather than
`msedge --print-to-pdf`: the CLI flag cannot set a header or a footer, so a
document printed that way has no page numbers. Playwright reaches the same
browser through the DevTools protocol, where `headerTemplate` and
`footerTemplate` exist. `channel="msedge"` uses the Edge that is already
installed — nothing is downloaded.

    python docs/manual/build-pdf.py            both languages
    python docs/manual/build-pdf.py de         one
    python docs/manual/build-pdf.py --html     stop at the HTML, no browser

Requires:  python -m pip install markdown playwright
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))

LANGS = {
    "de": {
        "title": "OS/7",
        "subtitle": "Administratorhandbuch",
        "toc": "Inhalt",
        "footer_left": "OS/7 Administratorhandbuch",
        "pdf": "OS7-Administratorhandbuch-de.pdf",
        "locale": "de",
    },
    "en": {
        "title": "OS/7",
        "subtitle": "Administrator Manual",
        "toc": "Contents",
        "footer_left": "OS/7 Administrator Manual",
        "pdf": "OS7-Administrator-Manual-en.pdf",
        "locale": "en",
    },
}

CSS = r"""
@page {
  size: A4;
  margin: 22mm 20mm 20mm 20mm;
}
* { box-sizing: border-box; }
html { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
body {
  font-family: "Segoe UI", "Calibri", system-ui, sans-serif;
  font-size: 10.5pt;
  line-height: 1.5;
  color: #14181d;
  margin: 0;
  hyphens: auto;
}

/* --- the title page ---------------------------------------------------- */
.titlepage {
  page-break-after: always;
  height: 247mm;
  display: flex;
  flex-direction: column;
  justify-content: center;
  border-top: 6mm solid #0057ad;
  padding-top: 14mm;
}
.titlepage .brand {
  font-size: 54pt; font-weight: 700; letter-spacing: -0.02em;
  color: #0057ad; line-height: 1;
}
.titlepage .sub { font-size: 22pt; margin-top: 6mm; color: #14181d; font-weight: 300; }
.titlepage .rule { width: 40mm; height: 2mm; background: #1289ff; margin: 10mm 0; }
.titlepage .meta { font-size: 10pt; color: #4a5560; line-height: 1.9; }
.titlepage .meta b { color: #14181d; font-weight: 600; }

/* --- contents ---------------------------------------------------------- */
.toc { page-break-after: always; }
.toc h1 { border: 0; margin-bottom: 8mm; }
.toc ol { list-style: none; padding: 0; margin: 0; counter-reset: c; }
.toc li { margin: 0; padding: 1.2mm 0; }
.toc li.l1 {
  font-weight: 600; border-bottom: 0.3pt solid #d8dde3;
  margin-top: 3mm; font-size: 11pt;
}
.toc li.l2 { padding-left: 8mm; font-size: 9.5pt; color: #3d4750; }
.toc a { color: inherit; text-decoration: none; }

/* --- headings ---------------------------------------------------------- */
h1 {
  font-size: 21pt; font-weight: 600; color: #0057ad;
  page-break-before: always; page-break-after: avoid;
  margin: 0 0 6mm 0; padding-bottom: 2mm;
  border-bottom: 1pt solid #0057ad;
}
h1.nobreak { page-break-before: avoid; }
h2 {
  font-size: 14pt; font-weight: 600; margin: 8mm 0 2mm 0;
  page-break-after: avoid; color: #14181d;
}
h3 {
  font-size: 11.5pt; font-weight: 600; margin: 6mm 0 1.5mm 0;
  page-break-after: avoid; color: #2b3138;
}
h4 { font-size: 10.5pt; font-weight: 600; margin: 4mm 0 1mm 0; page-break-after: avoid; }
p { margin: 0 0 3mm 0; orphans: 3; widows: 3; }

/* --- code -------------------------------------------------------------- */
code, kbd {
  font-family: "Cascadia Mono", "Consolas", monospace;
  font-size: 9pt;
  background: #eef1f5; padding: 0.3mm 1mm; border-radius: 1mm;
}
pre {
  background: #f5f7fa; border: 0.3pt solid #d8dde3; border-left: 1.2mm solid #0057ad;
  padding: 3mm 4mm; margin: 3mm 0; border-radius: 0 1mm 1mm 0;
  font-size: 8.5pt; line-height: 1.42; overflow: hidden;
  page-break-inside: avoid; white-space: pre-wrap; word-break: break-word;
}
pre code { background: none; padding: 0; font-size: inherit; }
pre.long { page-break-inside: auto; }

/* --- tables ------------------------------------------------------------ */
table {
  border-collapse: collapse; width: 100%; margin: 3mm 0;
  font-size: 9pt; page-break-inside: avoid;
}
thead { display: table-header-group; }
th {
  background: #0057ad; color: #fff; text-align: left; font-weight: 600;
  padding: 1.6mm 2.5mm; border: 0.3pt solid #0057ad;
}
td { padding: 1.4mm 2.5mm; border: 0.3pt solid #d8dde3; vertical-align: top; }
tbody tr:nth-child(even) td { background: #f5f7fa; }
table.wide { font-size: 8pt; }

/* --- figures ----------------------------------------------------------- */
figure {
  margin: 4mm 0; page-break-inside: avoid; text-align: center;
}
figure img {
  max-width: 100%; border: 0.3pt solid #c4ccd4; border-radius: 1mm;
}
figure.diagram img { border: 0; }
figcaption {
  font-size: 8.5pt; color: #4a5560; margin-top: 1.5mm; text-align: left;
  border-left: 1mm solid #1289ff; padding-left: 2.5mm;
}

/* --- call-outs --------------------------------------------------------- */
blockquote {
  margin: 3mm 0; padding: 2.5mm 4mm; background: #eaf3fd;
  border-left: 1.2mm solid #1289ff; page-break-inside: avoid;
}
blockquote p:last-child { margin-bottom: 0; }
blockquote p strong:first-child { color: #0057ad; }

hr { border: 0; border-top: 0.3pt solid #d8dde3; margin: 6mm 0; }
ul, ol { margin: 0 0 3mm 0; padding-left: 6mm; }
li { margin: 0.8mm 0; }
a { color: #0057ad; text-decoration: none; }
strong { font-weight: 600; }
"""


def read_chapters(lang):
    d = os.path.join(HERE, lang)
    if not os.path.isdir(d):
        raise SystemExit("no chapter directory at " + d)
    files = sorted(f for f in os.listdir(d) if f.endswith(".md"))
    if not files:
        raise SystemExit("no .md chapters in " + d)
    return [(f, open(os.path.join(d, f), encoding="utf-8").read()) for f in files]


def slug(text, seen):
    s = re.sub(r"[^\w\s-]", "", text.lower()).strip()
    s = re.sub(r"[\s_-]+", "-", s)
    n, base = 1, s
    while s in seen:
        n += 1
        s = base + "-" + str(n)
    seen.add(s)
    return s


def build_html(lang, meta):
    import markdown

    body_parts = []
    toc = []
    seen = set()
    for _, text in read_chapters(lang):
        body_parts.append(text)
    md = "\n\n".join(body_parts)

    conv = markdown.Markdown(extensions=["tables", "fenced_code", "attr_list",
                                         "footnotes", "sane_lists", "md_in_html"])
    body = conv.convert(md)

    # Anchors and the contents, from the rendered headings — so the contents
    # cannot list a section the document does not have.
    def anchor(m):
        level, attrs, text = m.group(1), m.group(2) or "", m.group(3)
        plain = re.sub(r"<[^>]+>", "", text)
        sid = slug(plain, seen)
        if level in ("1", "2"):
            toc.append((level, plain, sid))
        return '<h{0} id="{1}"{2}>{3}</h{0}>'.format(level, sid, attrs, text)

    body = re.sub(r"<h([12345])([^>]*)>(.*?)</h\1>", anchor, body, flags=re.S)

    # An image is a figure: the caption is the alt text, and a figure never
    # splits across a page.
    #
    # THE ATTRIBUTE ORDER IS NOT src-then-alt. python-markdown emits
    # `<img alt="..." src="..." />`, and the first version of this pattern
    # assumed the other order — it matched nothing, every caption was silently
    # dropped, and the document still built. Attributes are pulled out by name.
    def figure(m):
        tag = m.group(1)
        src = re.search(r'src="([^"]*)"', tag)
        alt = re.search(r'alt="([^"]*)"', tag)
        src = src.group(1) if src else ""
        alt = html.unescape(alt.group(1)) if alt else ""
        cls = "diagram" if "/diagram-" in src else "shot"
        cap = ("<figcaption>" + html.escape(alt) + "</figcaption>") if alt else ""
        return ('<figure class="' + cls + '"><img src="' + src + '" alt="'
                + html.escape(alt) + '">' + cap + "</figure>")

    # A pipe inside a table cell has to be written `\|` or the table parser
    # splits the row on it. Outside a code span markdown then unescapes it;
    # INSIDE one — which is where every pipe in this manual is, because they
    # are all PowerShell — it does not, and the reader gets `Get-Service \|
    # Where …`. Undone here, once, on the rendered HTML.
    body = body.replace("\\|", "|")

    body, n = re.subn(r"<p>(<img\b[^>]*>)</p>", figure, body)
    if n == 0:
        raise SystemExit("no images were turned into figures — the <img> pattern "
                         "no longer matches what markdown emits")
    # Images resolve against this file's directory when the browser loads a
    # file:// document written to the same place, so nothing else is needed.

    toc_html = ['<div class="toc"><h1 class="nobreak">' + meta["toc"] + "</h1><ol>"]
    for level, text, sid in toc:
        toc_html.append('<li class="l{0}"><a href="#{1}">{2}</a></li>'
                        .format(level, sid, html.escape(text)))
    toc_html.append("</ol></div>")

    release = release_facts()
    title = (
        '<div class="titlepage">'
        '<div class="brand">OS/7</div>'
        '<div class="sub">' + meta["subtitle"] + "</div>"
        '<div class="rule"></div>'
        '<div class="meta">' + release + "</div>"
        "</div>"
    )

    return (
        '<!doctype html><html lang="' + meta["locale"] + '"><head>'
        '<meta charset="utf-8"><title>' + meta["title"] + " " + meta["subtitle"]
        + "</title><style>" + CSS + "</style></head><body>"
        + title + "".join(toc_html) + body + "</body></html>"
    )


def release_facts():
    """The version on the title page comes from the pin, never from a person.

    build/config/os7-release.conf is the one place a version number may live
    (CLAUDE.md), so the manual reads it rather than carrying a second copy.
    """
    conf = os.path.join(REPO, "build", "config", "os7-release.conf")
    fields = {}
    if os.path.exists(conf):
        for line in open(conf, encoding="utf-8"):
            m = re.match(r"^\s*([A-Z0-9_]+)=\"?([^\"#\n]*)\"?", line)
            if m:
                fields[m.group(1)] = m.group(2).strip()
    version = ".".join(fields.get(k, "?") for k in
                       ("OS7_VERSION_MAJOR", "OS7_VERSION_MINOR", "OS7_VERSION_PATCH"))
    rows = [("Version", version + " (" + fields.get("OS7_CHANNEL", "?") + ")"),
            ("Ubuntu", fields.get("OS7_UBUNTU_RELEASE", "?") + " "
             + fields.get("OS7_DISTRIBUTION", "")),
            ("Snapshot", fields.get("OS7_ARCHIVE_SNAPSHOT", "?")),
            ("PowerShell", fields.get("OS7_PWSH_VERSION", "?"))]
    out = ["<b>" + label + "</b> &nbsp; " + html.escape(value) + "<br>"
           for label, value in rows]
    out.append('<span style="font-size:8.5pt">'
               "build/config/os7-release.conf</span>")
    return "".join(out)


def to_pdf(html_path, pdf_path, meta):
    from playwright.sync_api import sync_playwright

    footer = (
        '<div style="font-size:7.5pt;color:#4a5560;width:100%;padding:0 20mm;'
        'display:flex;justify-content:space-between;font-family:Segoe UI,sans-serif">'
        "<span>" + html.escape(meta["footer_left"]) + "</span>"
        '<span class="pageNumber"></span></div>'
    )
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="msedge")
        page = browser.new_page()
        page.goto("file:///" + html_path.replace("\\", "/"), wait_until="load")
        page.emulate_media(media="print")
        page.pdf(path=pdf_path, format="A4", print_background=True,
                 display_header_footer=True,
                 header_template='<div style="font-size:1pt"></div>',
                 footer_template=footer,
                 margin={"top": "22mm", "bottom": "18mm",
                         "left": "20mm", "right": "20mm"})
        browser.close()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    html_only = "--html" in sys.argv
    langs = args or list(LANGS)
    for lang in langs:
        meta = LANGS[lang]
        doc = build_html(lang, meta)
        html_path = os.path.join(HERE, "manual-" + lang + ".html")
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(doc)
        print("    html  " + html_path + "  (" + str(len(doc)) + " bytes)")
        if html_only:
            continue
        pdf_path = os.path.join(HERE, meta["pdf"])
        to_pdf(html_path, pdf_path, meta)
        print("    PDF   " + pdf_path + "  ("
              + str(os.path.getsize(pdf_path) // 1024) + " KiB)")


if __name__ == "__main__":
    main()
