# Session — what an Avalonia application actually costs on an OS/7 image

**2026-09-14, x64 Windows host, `os7-build:amd64`.** The toolkit for OS/7's own GUI applications was
chosen ([GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) G1). This session measured the thing the choice is most
often wrong about — the size — and three facts that came out of the same run and change the plan.

Nothing here is a running application. A published output was inspected; no window was drawn. Every
claim about how one *looks* on this desktop is still owed (O-G1).

---

## 1. How it was measured

A minimal but real Avalonia application — a window class, `FluentTheme`, `UsePlatformDetect()` —
written by hand rather than from a template, so nothing arrives that an OS/7 application would not
have. **The package version was left floating (`Version="*"`)** so that the feed would say what
current is, rather than this repository asserting it. Published twice, framework-dependent and
self-contained, in the build container that already builds `os7-setup`.

```bash
docker run --rm -v "<scratch>:/scratch" os7-build:amd64 bash /scratch/measure-avalonia.sh
```

Build container: .NET SDK 10.0.111, `Microsoft.NETCore.App` 10.0.11.

---

## 2. What the feed resolved to

| Package | Version |
|---|---|
| `Avalonia` | **12.1.2** |
| `Avalonia.Desktop` | 12.1.2 |
| `SkiaSharp` | 3.119.4 |

Recorded here and **not** in any other file: a version number in this repository lives in
[`os7-release.conf`](../build/config/os7-release.conf) and nowhere else. This is a measurement of
what the feed offered on 2026-09-14, not a pin. Choosing the pin is C14's job.

---

## 3. The size

| Publish mode | Size | Per six applications |
|---|---|---|
| **Framework-dependent** (against the image's `dotnet-runtime-10.0`) | **22.1 MiB** | 132.6 MiB |
| Self-contained (control) | **100.8 MiB** | 604.8 MiB |

**G2 is vindicated with a number: 78.7 MiB per application, and 472 MiB across the family.** The
runtime C2 kept costs 105 MiB once (79 + 26); paying for it again in every application would exceed
that on the second application.

### 3a. And 13.3 MiB of the 22.1 is the same bytes in every application

| File | Size | Same in every app? |
|---|---|---|
| `libSkiaSharp.so` | 10.65 MiB | yes — `sha256 66c856ea…` |
| `libHarfBuzzSharp.so` | 2.68 MiB | yes — `sha256 1d5c3afe…` |
| everything managed | 8.8 MiB | mostly, but versioned with the app |

**This changes G9 and G11 from a design preference into an arithmetic one.** `os7-ui` was proposed
as the place the design tokens live so that five applications cannot drift into five different
greys. It is now also the place 13.3 MiB of native code lives so that six applications do not ship
it six times:

| Layout | Six applications |
|---|---|
| each app publishes everything | 132.6 MiB |
| `os7-ui` carries the native payload once | **66.1 MiB** (13.3 + 6 × 8.8) |

Whether that is done as a shared `.deb` the applications depend on, or by publishing the family as
one multi-entry-point package, is open — but "each application is its own package" (G11) must not be
read as "each application is its own copy".

### 3b. There is dead weight, and trimming is a real lever

On a `linux-x64` RID the publish still contains:

| Assembly | Size | What it is for |
|---|---|---|
| `Avalonia.Win32.dll` | 0.90 MiB | Windows |
| `Avalonia.Native.dll` | 0.33 MiB | macOS |
| `Avalonia.Win32.Automation.dll` | — | Windows accessibility |
| `Avalonia.MicroCom.dll` | 0.01 MiB | COM interop |

Not acted on. Recorded because "22.1 MiB" is an untrimmed number and the trimmed one will be smaller;
nobody should re-measure from scratch to discover that.

---

## 4. Three findings that change the plan

### 4a. Avalonia 12.1.2 has NO Wayland backend, and GNOME 50 is a Wayland session

The published output contains `Avalonia.X11.dll` and no Wayland assembly at all:

```
Avalonia.X11.dll        present
*wayland*               nothing
```

So on an OS/7 desktop these applications run **through XWayland**. That is not a defect and it does
work, but it is now a known property rather than an assumption, and it carries consequences that are
cheapest to find now: fractional scaling is XWayland's rather than the compositor's, screen capture
and global shortcuts behave differently, and anything that reasons about the display server will see
X11 on a Wayland machine.

**O-G2 is therefore no longer "measure whether"; it is "measure how badly".** GL4 is rewritten to
say so.

### 4b. Accessibility exists as a component — which sharpens the question rather than closing it

`Avalonia.FreeDesktop.AtSpi.dll` ships (0.54 MiB). So AT-SPI is not absent, as GL5 implied when it
was written from memory.

What this does **not** say is that a screen reader reads these windows usefully. It moves O-G4 from
"does the mechanism exist" to "does Orca read a list, a checkbox and a progress bar in one of these
windows" — which is a measurement somebody can actually make on the GUI bench, and should, before
the family grows past the first application.

### 4c. `libfontconfig.so.1` is a hard runtime dependency, and the build container does not have it

`ldd libSkiaSharp.so` in `os7-build:amd64`:

```
libfontconfig.so.1 => not found
```

The application still constructed its `AppBuilder` and exited 0, because nothing had asked Skia to
render text yet. **That is the failure shape this repository keeps paying for** — a program reports
success and the thing it was meant to do has not been attempted. A check that runs an Avalonia
application in the build container and concludes "it works" would be measuring nothing.

On an OS/7 **desktop** image the library is present — `libfontconfig.so.1.16.1` and `libX11.so.6.4.0`
are both there on `os7img:175` — so the dependency is satisfied where it matters. Two caveats, and
the first is the important one:

1. **`os7img:*` is not the ISO** (BUILD-NOTES #93). This is indicative, not authoritative;
   `check-image.py` against the shipped squashfs is what would settle it.
2. It is there **transitively**, behind `ubuntu-desktop-minimal`. An `os7-ui` package must declare
   `libfontconfig1` and the X11 libraries in its own `Depends:` rather than rely on that, or the
   first headless-plus-manual-install path produces a window that cannot draw a letter.

---

## 5. What this changes

| File | Change |
|---|---|
| [GUI-APPS-PLAN.md](GUI-APPS-PLAN.md) | §2a filled in; G2 now carries a number; G9/G11 gain the shared-native-payload argument; GL4 rewritten (XWayland is a fact, not a risk); GL5 rewritten (AT-SPI exists) |
| [CURATION-AND-DELIVERY-PLAN.md](CURATION-AND-DELIVERY-PLAN.md) | C14 has a size to argue from |

## 6. What is still owed

Unchanged from the plan's §10 except where noted: **O-G1** (a window on this desktop), **O-G2**
(*how* XWayland behaves — no longer *whether*), **O-G3** (decorations), **O-G4** (Orca against a real
window — no longer *whether AT-SPI exists*), **O-G5** (startup time), **O-G6** (the privileged
helper).

And one new one: **O-G7 — the trimmed size.** 22.1 MiB is untrimmed, and §3b names about 1.2 MiB
that is visibly for other operating systems.
