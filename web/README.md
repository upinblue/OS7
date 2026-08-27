# os7.org

The public site. Plain HTML and CSS, **no build step**: what is in this
directory is what is served. `infra/` creates the Azure resources it runs on,
`tools/publish-release.py` puts a build on the download page.

```
index.html            the landing page
download.html         the images, checksums, requirements — the cards are GENERATED
organizations.html    the page for people deciding, not installing
getting-started.html  ISO to booted machine, screen by screen
imprint.html          section 5 DDG. INCOMPLETE — see "Before it goes live"
privacy.html          GDPR notice. INCOMPLETE — same
404.html
css/site.css          the whole design system, one file
js/theme-init.js      applies a stored theme before first paint (head, blocking)
js/theme.js           wires the toggle (deferred)
brand/                the two marks and the favicon — see brand/README.md
img/                  screenshots, copied from out/screenshots (which is gitignored)
releases.json         what the download page offers
staticwebapp.config.json  routes, security headers, and the ISO redirects
```

Preview it the way it will be served — any static server will do:

```bash
cd web && python -m http.server 8777
```

Extensionless URLs (`/download`) are rewrites configured in
`staticwebapp.config.json`; locally they are `/download.html`.

---

## Why it is built this way

**No build step, no dependencies.** This repository is bash, C#, PowerShell and
Python. A six-page marketing site does not justify adding a Node toolchain that
then has to be kept patched, and a site that deploys by copying files can be
served from anything if Azure ever stops being the answer.

**No third-party requests at all.** No Google Fonts, no CDN, no analytics, no
embedded anything. Fonts are the system stack — which on Windows means Segoe UI
for text and, pleasingly, Cascadia Mono for code, the same face OS/7 installs on
its own console. Two consequences: nothing about a visitor reaches a third party,
so the privacy notice has no international-transfer chapter to write; and the
Content Security Policy in `staticwebapp.config.json` can be `default-src 'self'`.

**`style-src` allows `'unsafe-inline'` and `script-src` does not.** There are a
handful of inline `style=` attributes; there is no inline script at all, which is
why `js/theme-init.js` is a file rather than three lines in each `<head>`. The
directive that matters is strict.

**The framebuffer screenshots are not `image-rendering: pixelated`.** They are
1280×800 captures of an 8×16 bitmap font. At any non-integer scale, nearest
neighbour drops a one-pixel stem and the text goes ragged; smooth downscale is
the honest one.

---

## Hosting, and what it costs

Measured against Microsoft's own documentation on 2026-08-27, not remembered.
Sources at the bottom.

| | |
|---|---|
| **Site** | Azure Static Web Apps, **Free** plan |
| Included bandwidth | **100 GB/month**, on Free and Standard alike |
| Overage | **Unavailable on Free** — past 100 GB the site is cut off, not billed. The bill cannot run away here |
| Size limits | 250 MB per environment, 15 000 files. This site is under 1 MB |
| Custom domains | 2 on Free — enough for `os7.org` and `www.os7.org` |
| Certificates | free, and renew themselves |
| Apex domain | supported, through an Azure DNS zone (ALIAS + TXT, written by the portal). Up to **72 hours** to propagate |

| | |
|---|---|
| **Downloads** | Azure Blob Storage, StorageV2, Hot, LRS, container `iso`, anonymous access level **Blob** |
| Storage | about **0.20 USD/month** for four images |
| Egress, first 100 GB/month | **free** |
| Egress after that | **0.087 USD/GB** (Europe/North America, first 10 TB) |
| One amd64 ISO | 3.11 GiB → roughly **30 downloads a month are free**, and about **0.29 USD** each after that |
| 100 downloads/month | ≈ 20 USD |

**Blob storage has no bandwidth cap**, which is the whole risk. `main.bicep`
creates a monthly budget alert; the alert alerts, it does not stop anything. The
actual kill switch is one command:

```bash
az storage container set-permission --name iso --account-name <account> \
    --public-access off --auth-mode login
```

**Why the download links go through os7.org.** Azure Storage does not support
root domains for custom domains at all, and HTTPS on a storage custom domain
requires Azure Front Door or CDN — a base fee of roughly 30 USD a month, more
than the bandwidth it would be fronting at this scale. So the published link is
`https://os7.org/download/OS7-<version>-amd64.iso` and Static Web Apps 302s it
to the blob. Static Web Apps cannot carry a captured path into a redirect
target, so it is one route per file — written by `tools/publish-release.py`,
which is also why nobody has to maintain them.

**If tenant policy forbids anonymous blob access.** `allowBlobPublicAccess` is
off by default on new accounts and some tenants enforce that with policy. The
fallback is the static-website container: Microsoft documents that disallowing
anonymous access for an account *does not* affect it — "The `$web` container is
always publicly accessible." The cost is the kill switch above, which then means
disabling static website hosting instead of flipping one container.

**The neighbour to plan for.** `build/lib/build-os7-repo.sh` produces a signed
apt suite plus a release index, and that is a static tree too. `main.bicep`
creates a second container, `repo`, on the same account for it. This matters
more than it looks: `OS7_REPO_URI` in
[build/config/os7-release.conf](../build/config/os7-release.conf) gets baked into
every image, so the storage account name is chosen once and is painful to change.

---

## Publishing a build

The tool measures the files it is given and writes four things from what it
measured. Nothing about a size or a hash is ever typed.

```bash
python web/tools/publish-release.py \
    out/OS7-1.0.0.116-amd64.iso out/OS7-1.0.0.116-arm64.iso \
    --storage-base https://<account>.blob.core.windows.net/iso --print-upload
```

It writes `releases.json`, `SHA256SUMS`, the cards in `download.html` and the
redirects in `staticwebapp.config.json`, then prints the `az storage blob upload`
commands. **It does not upload** — that stays a decision. Run them, then commit
and push; the workflow publishes the site.

Two things it refuses, both on purpose:

- **two different versions in one publish.** A download page offering
  `1.0.0.116` for x86-64 and `1.0.0.109` for arm64 under one heading is a page
  that has to be read carefully to be understood correctly.
- **keeping a hash for an image that was not passed in.** An architecture left
  out of a publish goes back to "not published yet" rather than keeping the hash
  of the release before it.

`--dry-run` measures and reports without writing anything.

---

## Before it goes live

1. **`imprint.html`** — every `{{PLACEHOLDER}}`, and remove the yellow notice.
   A German business site that is *reachable* needs a complete provider
   identification; being unfinished is not an exemption.
2. **`privacy.html`** — same, and it should be read by whoever handles data
   protection. It describes the site exactly as built: if a form, an analytics
   tag or an embedded video is ever added, this page stops being true and is the
   thing that has to change first.
3. **Neither legal page has been reviewed by a lawyer.** They are drafts written
   from what the site actually does.
4. `info@upinblue.com` is used as the contact address throughout. If that mailbox
   does not exist, it needs to — or the address needs changing in six files.

---

## Sources

Fetched 2026-08-27:

- [Static Web Apps quotas](https://learn.microsoft.com/en-us/azure/static-web-apps/quotas) — 100 GB/month, overage unavailable on Free, 250 MB, 15 000 files, 2 custom domains
- [Static Web Apps plans](https://learn.microsoft.com/en-us/azure/static-web-apps/plans) — free managed certificates, staging environments
- [Apex domain with Azure DNS](https://learn.microsoft.com/en-us/azure/static-web-apps/apex-domain-azure-dns) — ALIAS + TXT, 72 hours
- [Map a custom domain to a blob endpoint](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-custom-domain-name) — "Root domains aren't supported"; HTTPS needs Front Door or CDN
- [Configure anonymous read access](https://learn.microsoft.com/en-us/azure/storage/blobs/anonymous-read-access-configure) — off by default; `$web` is always publicly accessible
- [Bandwidth pricing](https://azure.microsoft.com/en-us/pricing/details/bandwidth/) — first 100 GB/month free, then 0.087 USD/GB

Two figures were **not** verified and are order-of-magnitude only: the Azure DNS
public zone fee (~0.50 USD/zone/month plus queries) and the Front Door Standard
base fee (~30 USD/month). Neither changes the conclusion.
