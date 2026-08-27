#!/usr/bin/env python3
# =============================================================================
# OS/7 — assemble the whole site into ONE self-contained HTML file.
#
#   tools/build-preview.py [-o out.html]
#
# For showing the site to someone who cannot run a web server: every page, the
# real stylesheet, and every image inlined as a data: URI, in a single file that
# opens from disk or can be published anywhere.
#
# It is a VIEWER, not a second copy of the design. Nothing here restyles
# anything: the stylesheet is taken verbatim from css/site.css and only its
# SELECTORS are rewritten, so what this shows is what the deployed site is. Two
# rewrites, both forced by the file being a single page:
#
#   :root -> #site      the site's tokens and the site's <body> rules move onto
#   body  -> #site      a wrapper div, because there is only one <body> here and
#                       it belongs to the host page, not to the site.
#
#   :root[data-theme="light"] -> #site[data-site-theme="light"]
#                       and this one matters: a host that stamps data-theme on
#                       <html> - which artifact viewers do - would otherwise
#                       flip the site's theme from outside. The site's own
#                       switch drives an attribute nothing else writes.
#
# Regenerate it after any change to the site; it is a build output, not a source.
# =============================================================================

import argparse
import base64
import mimetypes
import re
import sys
from pathlib import Path

WEB = Path(__file__).resolve().parent.parent

# id, file, and the label used if a page is ever listed. Order is the order the
# sections appear in; the first one is what opens.
PAGES = [
    ("index", "index.html"),
    ("download", "download.html"),
    ("organizations", "organizations.html"),
    ("getting-started", "getting-started.html"),
    ("imprint", "imprint.html"),
    ("privacy", "privacy.html"),
]

# path -> page id, for rewiring the site's own links to in-page switching
ROUTES = {
    "/": "index",
    "/download": "download",
    "/organizations": "organizations",
    "/getting-started": "getting-started",
    "/imprint": "imprint",
    "/privacy": "privacy",
}

BODY_RE = re.compile(r"<body>(.*?)(?=<script)", re.S)
ASSET_RE = re.compile(r'src="(/(?:img|brand)/[^"]+)"')
EXTERNAL_RE = re.compile(r'<a href="(https?://[^"]+)"')


def die(msg):
    print(f"!!! {msg}", file=sys.stderr)
    sys.exit(1)


def data_uri(rel_path, cache):
    """Inline an asset. Cached so the same screenshot used on two pages is read
    once - it is still embedded twice, which is the price of one file."""
    if rel_path in cache:
        return cache[rel_path]
    path = WEB / rel_path.lstrip("/")
    if not path.is_file():
        die(f"asset referenced by a page does not exist: {rel_path}")
    mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
    uri = f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode("ascii")
    cache[rel_path] = uri
    return uri


def scoped_css():
    css = (WEB / "css" / "site.css").read_text(encoding="utf-8")
    # order matters: the more specific selector first, or ':root' eats it
    css = css.replace(':root[data-theme="light"]', '#site[data-site-theme="light"]')
    css = css.replace(":root", "#site")
    css = re.sub(r"(?m)^body \{", "#site {", css)
    css = re.sub(r"(?m)^html \{", "#site {", css)
    return css


def page_body(filename, cache):
    html = (WEB / filename).read_text(encoding="utf-8")
    m = BODY_RE.search(html)
    if not m:
        die(f"{filename}: could not find the body content")
    body = m.group(1)

    body = ASSET_RE.sub(lambda x: f'src="{data_uri(x.group(1), cache)}"', body)
    # every image is a data: URI here, so lazy loading buys nothing and costs
    # something: an unloaded image has no height, and a page whose height is
    # still growing cannot be scrolled to a known position
    body = body.replace(' loading="lazy"', "")
    # anything off-site opens in a new tab rather than replacing the preview
    body = EXTERNAL_RE.sub(r'<a target="_blank" rel="noopener" href="\1"', body)
    return body.strip()


def build():
    cache = {}
    sections = []
    for page_id, filename in PAGES:
        hidden = "" if page_id == PAGES[0][0] else " hidden"
        sections.append(
            f'<div class="pv-page" data-page="{page_id}"{hidden}>\n{page_body(filename, cache)}\n</div>'
        )

    favicon = data_uri("/brand/favicon.svg", cache)
    routes_js = ", ".join(f'"{k}": "{v}"' for k, v in ROUTES.items())

    return f"""<title>os7.org</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<link rel="icon" href="{favicon}" type="image/svg+xml">
<style>
/* --- host page: paint an explicit ground so the site never borrows one ---- */
html, body {{ margin: 0; padding: 0; background: #0a0d12; }}
#site {{ min-height: 100vh; }}
.pv-page[hidden] {{ display: none; }}

/* the only thing added to the site: a quiet reminder that this is not live */
.pv-badge {{
	position: fixed; right: 14px; bottom: 14px; z-index: 999;
	font: 500 12px/1 system-ui, -apple-system, "Segoe UI", sans-serif;
	letter-spacing: .02em;
	padding: 8px 12px; border-radius: 999px;
	background: rgba(10, 13, 18, .82); color: #98a4b4;
	border: 1px solid #2c3542; backdrop-filter: blur(8px);
	pointer-events: none;
}}
#site[data-site-theme="light"] ~ .pv-badge {{
	background: rgba(255, 255, 255, .86); color: #59636f; border-color: #c6cdd6;
}}

/* --- the site's own stylesheet, selectors rescoped, nothing else changed -- */
{scoped_css()}
</style>

<div id="site">
{chr(10).join(sections)}
</div>
<div class="pv-badge">Preview &middot; nothing is deployed</div>

<script>
(function () {{
	var routes = {{{routes_js}}};
	var site = document.getElementById('site');
	var pages = site.querySelectorAll('.pv-page');

	function show(id, anchor) {{
		var found = false;
		pages.forEach(function (p) {{
			var match = p.dataset.page === id;
			p.hidden = !match;
			if (match) found = true;
		}});
		if (!found) return;
		if (anchor) {{
			var target = site.querySelector('.pv-page[data-page="' + id + '"] #' + anchor);
			if (target) {{ target.scrollIntoView(); return; }}
		}}
		window.scrollTo(0, 0);
	}}

	// The site's own navigation drives the preview — no extra chrome to learn.
	document.addEventListener('click', function (e) {{
		var a = e.target.closest && e.target.closest('a[href^="/"], a[href^="#"]');
		if (!a) return;
		var href = a.getAttribute('href');
		if (href.charAt(0) === '#') {{
			e.preventDefault();
			var el = site.querySelector('.pv-page:not([hidden]) ' + href);
			if (el) el.scrollIntoView({{ behavior: 'smooth' }});
			return;
		}}
		var parts = href.split('#');
		if (!(parts[0] in routes)) return;
		e.preventDefault();
		show(routes[parts[0]], parts[1]);
	}});

	// Dark is the design; the switch is an override, and it drives an attribute
	// the host cannot write.
	site.querySelectorAll('.theme-toggle').forEach(function (btn) {{
		btn.addEventListener('click', function () {{
			var light = site.getAttribute('data-site-theme') === 'light';
			site.setAttribute('data-site-theme', light ? 'dark' : 'light');
		}});
	}});

	// ?page=download&y=1200&theme=light — so a headless renderer can be pointed
	// at one page at one scroll position. Review only; nothing links to it.
	var q = new URLSearchParams(location.search);
	if (q.get('theme') === 'light') site.setAttribute('data-site-theme', 'light');
	if (q.get('page')) show(q.get('page'));
	// shifted with a negative margin rather than scrolled: a headless renderer
	// screenshots the compositor, and content that was scrolled to but never
	// painted comes out blank
	if (q.get('y')) site.style.marginTop = '-' + (parseInt(q.get('y'), 10) || 0) + 'px';
}})();
</script>
"""


def main():
    ap = argparse.ArgumentParser(description="Assemble os7.org into one self-contained file.")
    ap.add_argument("-o", "--out", type=Path, default=WEB / "preview.html")
    args = ap.parse_args()

    html = build()
    args.out.write_text(html, encoding="utf-8")
    print(f"wrote {args.out}  ({len(html.encode('utf-8')) / 1024:.0f} KB, {len(PAGES)} pages)")


if __name__ == "__main__":
    main()
