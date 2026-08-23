# Session S2 — NativeAOT in the OS/7 build container

Answers `installer/SETUP-PLAN.md` **§10 Phase 0 spike S2**: *does NativeAOT
build in the OS/7 container?* Done when there are "two static binaries that run
in the ISO".

The doubt behind it is **L11**: NativeAOT "restores
`Microsoft.DotNet.ILCompiler` from NuGet at publish time — unvalidated against
Canonical's `dotnet-sdk-10.0`", with a framework-dependent build as the fallback.

**Date:** 2026-08-23 · **Method:** `dotnet publish -c Release -r <rid>
-p:PublishAot=true` inside `os7-build:arm64` and `os7-build:amd64`, then the
arm64 binary run inside the ISO's own root over an overlay on the squashfs —
including with .NET deleted from that root.

- The project: [`installer/spikes/s2-nativeaot/`](../installer/spikes/s2-nativeaot)
- In-container build: [`installer/spikes/s2-nativeaot.sh`](../installer/spikes/s2-nativeaot.sh)
- Harness: [`installer/spikes/run-s2.sh`](../installer/spikes/run-s2.sh)

```bash
./installer/spikes/run-s2.sh all arm64
./installer/spikes/run-s2.sh build amd64
```

## Verdict

| Question | Answer |
|---|---|
| Does `PublishAot=true` work against Canonical's SDK? | **Yes.** SDK `10.0.111`, restore in ~9 s, **zero warnings**. |
| Two binaries? | **Yes** — `linux-arm64` (3.3 MB) and `linux-x64` (3.2 MB), both stripped PIE ELF. |
| Genuinely native, not framework-dependent? | **Yes.** No `.dll`, no `runtimeconfig.json`, no `libcoreclr.so`; `RuntimeFeature.IsDynamicCodeSupported` is `false`. |
| Does it run in the ISO? | **Yes**, and **with `/usr/lib/dotnet` deleted from the image** — including globalization. |
| **S2** | **PASS.** L11's fallback is not needed. |

What the binaries link against is the whole story:

```
$ ldd out/s2/arm64/os7-s2
	linux-vdso.so.1
	libm.so.6 => /usr/lib/aarch64-linux-gnu/libm.so.6
	libc.so.6 => /usr/lib/aarch64-linux-gnu/libc.so.6
	/lib/ld-linux-aarch64.so.1
```

libc and libm. Nothing else.

**§6.1's size estimate was pessimistic.** It says "~10–15 MB"; the measured
binaries are **3.2–3.4 MB**. This is a small program, so a real `os7-setup` will
be larger — but the order of magnitude is friendlier than assumed.

## The spike is not a hello-world, deliberately

A hello-world would have compiled cleanly and proved nothing. The program
exercises exactly the things §6.2 commits `os7-setup` to, each of which is a
known NativeAOT hazard:

| Check | Why it is in there |
|---|---|
| `LibraryImport` into libc — `getpid`, `write(2)`, `isatty`, `ioctl(TIOCGWINSZ)`, `tcgetattr`/`tcsetattr` | §6.2: raw terminal mode and one `write(2)` per frame |
| `System.Text.Json` with a **source-generated** context | §6.2 calls the InstallPlan model "source-generated, AOT-safe" |
| `Process.Start` + stdout capture | `sgdisk`, `zpool`, `unsquashfs`, `grub-install`, `pwsh` |
| `CultureInfo.GetCultureInfo("de-DE")` | L9/§2 want English **and German** |
| `RuntimeFeature.IsDynamicCodeSupported` is false | proves this is AOT and not a runtime-backed build |

All pass, on both arches, in the container and in the ISO:

```
    ok       native AOT  — no dynamic code support, as expected
    ok       P/Invoke getpid  — pid 22
    ok       P/Invoke write(2)  — 57 bytes straight to fd 1
    ok       System.Text.Json (source-gen)  — {"Release":"2026.08.1",…}
    ok       Process.Start  — /bin/uname -m -> aarch64
    ok       globalization  — de-DE -> German (Germany), Deutsch (Deutschland)
S2-BINARY: OK
```

`InvariantGlobalization` is left **off** on purpose. Turning it on shrinks the
binary and looks like a free win, and would quietly make German impossible.
The check above is there so that stays visible.

## What the build container needs

The deliverable, and the one thing `os7-build` is missing today:

```
dotnet-sdk-10.0  clang  zlib1g-dev  libc6-dev  binutils  file
```

`clang` and `zlib1g-dev` are the two L11 named; `libc6-dev` and `binutils` are
what the ILCompiler's link step reaches for; `file` is only for the spike's own
reporting.

**The Dockerfile is deliberately left unchanged.** Nothing in the repo builds
C# yet, and adding a .NET SDK would make every ISO build heavier for no current
benefit. `s2-nativeaot.sh` installs the list itself, which is why a run takes
minutes rather than seconds. **Phase 1 should move it into the Dockerfile** —
at which point S2 becomes fast and repeatable, and the NuGet restore is the
only per-build cost left.

## Two findings worth carrying

### `LibraryImport` will not marshal a `byte[]` — `termios` must be blittable

The first build failed on OS/7's own code, not on the toolchain:

```
SYSLIB1051: The type 'Termios' is not supported by source-generated P/Invokes.
SYSLIB1062: LibraryImportAttribute requires unsafe code.
```

`struct termios` carries `cc_t c_cc[NCCS]`. Written the obvious way — a
`byte[]` with `[MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)]` — the
`LibraryImport` source generator rejects it outright, because it only handles
blittable types. It has to be a `fixed byte Cc[32]` in an `unsafe struct`, and
the project needs `<AllowUnsafeBlocks>true</AllowUnsafeBlocks>`.

This lands directly on `Native/Termios.cs` in §6.5's layout. The older
`[DllImport]` would have accepted the array form — and given up the
AOT-friendly generated marshalling that is the reason to use `LibraryImport`.

### amd64 builds fine under emulation — the ISO blocker does not apply

`make build-amd64` cannot run on Apple Silicon: Docker's amd64 emulation lacks a
syscall GNU tar needs, and debootstrap dies with `ENOSYS` (HANDOFF §3,
BUILD-NOTES #12). It would be reasonable to assume anything amd64 is blocked
here. **It is not.** `dotnet publish -r linux-x64 -p:PublishAot=true` in
`os7-build:amd64` produced a working x86-64 binary on this Apple Silicon Mac,
with the same zero warnings.

So `os7-setup` for amd64 can be built and iterated on locally long before an
amd64 ISO exists. That decouples Phase 1 from HANDOFF §3 entirely.

## What this does NOT prove

| Not covered | Why it matters |
|---|---|
| The amd64 binary running in an amd64 ISO | No amd64 ISO exists (HANDOFF §3). The binary was run in the amd64 **build container** only — same base, but not the image. |
| Anything at 80×25 on a real console | The spike's terminal checks report "not a tty" under Docker. `tcgetattr`/`ioctl` entry points resolve; their behaviour on a VT is **S1's** job. |
| A realistic binary size | 3.3 MB is a few hundred lines. A renderer, screens and a plan model will grow it. |
| Trimming warnings from real dependencies | Nothing here references anything outside the BCL. `Microsoft.PowerShell.SDK` is rejected in §6.3 precisely because AOT cannot take it — untested, and it should stay that way. |
| Build time | It varies by an order of magnitude between runs, because the spike reinstalls the SDK and re-restores NuGet each time. Bake the SDK into the Dockerfile before drawing conclusions. |

## How the ISO check works

No VM. `run-s2.sh iso` mounts the ISO, mounts the squashfs read-only, puts a
**tmpfs overlay** on top and chroots into that — so the binary meets the image's
real glibc (2.43) and real ICU in seconds, and the image itself cannot be
modified.

The interesting half is the second run. The ISO **does** ship `dotnet-sdk-10.0`
— it is in the base package list — so simply running there proves nothing about
runtime independence. The harness therefore deletes `/usr/lib/dotnet` and
`/usr/bin/dotnet` from the overlay, confirms `dotnet` is gone from `PATH`, and
runs the binary again. It behaves identically, globalization included, because
ICU comes from the image's `libicu` rather than from .NET.
