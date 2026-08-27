#!/usr/bin/env python3
# =============================================================================
# OS/7 — put a build on the download page.
#
#   tools/publish-release.py out/OS7-1.0.0.116-amd64.iso out/OS7-1.0.0.116-arm64.iso
#
# It measures the files it is given and writes four things from what it measured:
#
#   web/releases.json               the record: version, file, size, sha256
#   web/SHA256SUMS                  to be uploaded beside the ISOs
#   web/download.html               the two download cards, between the markers
#   web/staticwebapp.config.json    /download/<file> -> the blob URL, 302
#
# WHY A TOOL AND NOT A HAND EDIT. A download page carries two numbers a human
# cannot check by looking: the size and the hash. Typing either one is a way of
# publishing a claim about a file nobody verified. Everything here comes off the
# bytes on disk, and a file that was not passed in stays "not published yet"
# rather than keeping a stale hash from the release before it.
#
# It does NOT upload. Uploading is the operator's, deliberately: the ISOs are the
# only part of this site that costs real money to serve, and the moment they go
# public should be a decision somebody made rather than a side effect of running
# a script. --print-upload writes out the az commands to copy.
# =============================================================================

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

WEB = Path(__file__).resolve().parent.parent

RELEASES = WEB / "releases.json"
DOWNLOAD = WEB / "download.html"
SWA_CONF = WEB / "staticwebapp.config.json"
SUMS = WEB / "SHA256SUMS"

BEGIN = "<!-- BEGIN GENERATED: downloads"
END = "<!-- END GENERATED: downloads -->"

# OS7-<version>-<arch>.iso, the name build.sh gives it.
NAME_RE = re.compile(r"^OS7-(?P<version>\d+\.\d+\.\d+\.\d+)-(?P<arch>amd64|arm64)\.iso$")


def die(msg):
    print(f"!!! {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_of(path):
    """Hash in 8 MiB blocks — the amd64 ISO is over 3 GB and does not belong in
    memory. Prints progress because a silent three-minute pause reads as a hang."""
    h = hashlib.sha256()
    total = path.stat().st_size
    done = 0
    # only when stderr is a terminal: piped or in CI, a carriage-return progress
    # line is not progress, it is several hundred lines of noise in the log
    live = sys.stderr.isatty()
    with path.open("rb") as fh:
        while True:
            block = fh.read(8 * 1024 * 1024)
            if not block:
                break
            h.update(block)
            done += len(block)
            if live:
                pct = done * 100 // total if total else 100
                print(f"\r    hashing {path.name}: {pct:3d}%", end="", file=sys.stderr)
    if live:
        print("\r" + " " * 60 + "\r", end="", file=sys.stderr)
    return h.hexdigest()


def gib(size):
    return f"{size / (1024 ** 3):.2f} GiB"


def load_releases():
    if not RELEASES.exists():
        die(f"missing {RELEASES}")
    return json.loads(RELEASES.read_text(encoding="utf-8"))


def esc(text):
    return (str(text).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def card_html(image, public_base):
    """One download card. An image without a hash renders as pending — the page
    never shows a button for a file this tool has not measured."""
    label = esc(image["label"])
    role = esc(image["role"])
    arch = esc(image["arch"])

    if not image.get("sha256"):
        body = (
            '\t\t\t\t\t<div class="dl-pending">Not published yet &mdash; the link goes live with the '
            "first preview build.</div>\n"
            '\t\t\t\t\t<div class="dl-facts">\n'
            f'\t\t\t\t\t\t<div><span class="k">Architecture</span><span class="v">{arch}</span></div>\n'
            '\t\t\t\t\t\t<div><span class="k">Base</span><span class="v">Ubuntu 26.04 LTS</span></div>\n'
            "\t\t\t\t\t</div>\n"
        )
    else:
        href = esc(f"{public_base}/{image['file']}")
        body = (
            f'\t\t\t\t\t<a class="btn btn-primary" href="{href}">\n'
            '\t\t\t\t\t\t<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
            'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 3v12m0 0l-4.5-4.5'
            'M12 15l4.5-4.5M4 18v2a1 1 0 001 1h14a1 1 0 001-1v-2"/></svg>\n'
            f"\t\t\t\t\t\tDownload {label}\n"
            "\t\t\t\t\t</a>\n"
            '\t\t\t\t\t<div class="dl-facts">\n'
            f'\t\t\t\t\t\t<div><span class="k">Version</span><span class="v">{esc(image["version"])}</span></div>\n'
            f'\t\t\t\t\t\t<div><span class="k">File</span><span class="v">{esc(image["file"])}</span></div>\n'
            f'\t\t\t\t\t\t<div><span class="k">Size</span><span class="v">{esc(gib(image["size"]))}</span></div>\n'
            f'\t\t\t\t\t\t<div><span class="k">Architecture</span><span class="v">{arch}</span></div>\n'
            "\t\t\t\t\t</div>\n"
            '\t\t\t\t\t<div>\n'
            '\t\t\t\t\t\t<p class="small muted" style="margin:0 0 6px">SHA-256</p>\n'
            f'\t\t\t\t\t\t<code class="hash">{esc(image["sha256"])}</code>\n'
            "\t\t\t\t\t</div>\n"
        )

    return (
        '\t\t\t<div class="dl-card">\n'
        '\t\t\t\t<div class="dl-card-head">\n'
        f'\t\t\t\t\t<p class="dl-arch">{label}</p>\n'
        f'\t\t\t\t\t<p class="dl-role">{role}</p>\n'
        "\t\t\t\t</div>\n"
        '\t\t\t\t<div class="dl-card-body">\n'
        f"{body}"
        "\t\t\t\t</div>\n"
        "\t\t\t</div>\n"
    )


def render_block(data):
    cards = "\n".join(card_html(i, data["public_base"]) for i in data["images"])
    return (
        f"{BEGIN} — written by tools/publish-release.py, do not hand-edit -->\n"
        '\t\t<div class="dl-grid">\n\n'
        f"{cards}\n"
        "\t\t</div>\n"
        f"\t\t{END}"
    )


def write_download_html(data):
    html = DOWNLOAD.read_text(encoding="utf-8")
    start = html.find(BEGIN)
    stop = html.find(END)
    if start < 0 or stop < 0:
        die(f"{DOWNLOAD.name} has lost its GENERATED markers — refusing to guess where the cards go")
    stop += len(END)
    return html[:start] + render_block(data) + html[stop:]


def write_routes(data):
    """Replace every /download/<file> route with the current set. Keyed on the
    path prefix, so a release that drops an architecture drops its route too
    rather than leaving a 302 to a blob that no longer exists."""
    conf = json.loads(SWA_CONF.read_text(encoding="utf-8"))
    kept = [r for r in conf.get("routes", []) if not r.get("route", "").startswith("/download/")]
    added = []
    for image in data["images"]:
        if not image.get("sha256"):
            continue
        added.append({
            "route": f"/download/{image['file']}",
            "redirect": f"{data['storage_base']}/{image['file']}",
            "statusCode": 302,
        })
    if any(i.get("sha256") for i in data["images"]):
        added.append({
            "route": "/download/SHA256SUMS",
            "redirect": f"{data['storage_base']}/SHA256SUMS",
            "statusCode": 302,
        })
    conf["routes"] = kept + added
    return json.dumps(conf, indent=2, ensure_ascii=False) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Publish OS/7 ISOs to the download page.")
    ap.add_argument("iso", nargs="+", type=Path, help="the ISO files, one per architecture")
    ap.add_argument("--storage-base", help="blob container URL the ISOs are uploaded to; "
                                           "stored in releases.json and used for the redirects")
    ap.add_argument("--dry-run", action="store_true", help="measure and report, write nothing")
    ap.add_argument("--print-upload", action="store_true", help="print the az commands to upload")
    args = ap.parse_args()

    data = load_releases()
    if args.storage_base:
        data["storage_base"] = args.storage_base.rstrip("/")
    if "REPLACE-ME" in data["storage_base"] and not args.dry_run:
        die("storage_base in releases.json is still the placeholder. Pass --storage-base "
            "https://<account>.blob.core.windows.net/iso once, and it is remembered.")

    measured = {}
    version = None
    for path in args.iso:
        if not path.is_file():
            die(f"not a file: {path}")
        m = NAME_RE.match(path.name)
        if not m:
            die(f"{path.name} is not named OS7-<version>-<arch>.iso — refusing to guess what it is")
        arch = m.group("arch")
        this_version = m.group("version")
        if version and this_version != version:
            die(f"two versions in one publish: {version} and {this_version}. A download page that "
                f"offers two builds under one release is the thing this check exists to prevent.")
        version = this_version
        size = path.stat().st_size
        digest = sha256_of(path)
        measured[arch] = {"file": path.name, "size": size, "sha256": digest, "version": this_version}
        print(f"    {path.name}  {gib(size)}  {digest}")

    for image in data["images"]:
        if image["arch"] in measured:
            image.update(measured[image["arch"]])
        else:
            # not passed in this time — say nothing rather than repeat last time
            image.update({"file": None, "size": None, "sha256": None, "version": None})
            print(f"    {image['arch']}: not given, will show as not published yet")

    data["version"] = version
    data["released"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    sums = "".join(f"{m['sha256']}  {m['file']}\n" for m in measured.values())
    html = write_download_html(data)
    conf = write_routes(data)

    if args.dry_run:
        print("\n--- dry run, nothing written ---")
        print(f"version      {version}")
        print(f"storage_base {data['storage_base']}")
        print("\nSHA256SUMS:")
        print(sums, end="")
        return

    RELEASES.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    SUMS.write_text(sums, encoding="utf-8")
    DOWNLOAD.write_text(html, encoding="utf-8")
    SWA_CONF.write_text(conf, encoding="utf-8")

    print(f"\nwrote  {RELEASES.name}, {SUMS.name}, {DOWNLOAD.name}, {SWA_CONF.name}")
    print(f"       version {version}, {len(measured)} image(s)")

    if args.print_upload:
        container = data["storage_base"].rstrip("/").rsplit("/", 1)[-1]
        account = data["storage_base"].split("//", 1)[-1].split(".", 1)[0]
        print("\n--- upload, then commit and push the four files above ---")
        for path in args.iso:
            print(f"az storage blob upload --account-name {account} --container-name {container} \\\n"
                  f"  --name {path.name} --file {path} --auth-mode login \\\n"
                  f"  --content-type application/x-iso9660-image --overwrite false")
        print(f"az storage blob upload --account-name {account} --container-name {container} \\\n"
              f"  --name SHA256SUMS --file {SUMS} --auth-mode login \\\n"
              f"  --content-type text/plain --overwrite true")


if __name__ == "__main__":
    main()
