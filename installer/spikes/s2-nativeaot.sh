#!/bin/bash
# =============================================================================
# OS/7 — Phase 0 spike S2: does NativeAOT build in the OS/7 build container?
#
#   installer/SETUP-PLAN.md §10 S2, and the doubt behind it, L11:
#   "NativeAOT needs clang + zlib1g-dev and restores Microsoft.DotNet.ILCompiler
#    from NuGet at publish time — unvalidated against Canonical's dotnet-sdk-10.0."
#
# Runs INSIDE os7-build:<arch>. Installs what NativeAOT needs, publishes
# installer/spikes/s2-nativeaot, and leaves the binary in out/s2/<arch>/.
#
# The package list it installs IS the deliverable: whatever is here has to go
# into the Dockerfile before Phase 1, and nothing more.
# =============================================================================
set -euo pipefail

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    arm64) RID=linux-arm64 ;;
    amd64) RID=linux-x64   ;;
    *) echo "S2: unsupported architecture $ARCH" >&2; exit 1 ;;
esac

SRC=/work/installer/spikes/s2-nativeaot
OUT=/work/out/s2/$ARCH
# BUILD-NOTES #3: never build on the bind mount. Stage into a container-local
# directory and copy the one artefact back at the end.
WORK=/tmp/s2-build

say()  { printf '\n=== S2 %s ===\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\nS2-BUILD: FAILED — %s\n' "$*"; exit 1; }

trap 'S2_FAIL_LINE=$LINENO' ERR
trap 'rc=$?; [ $rc -eq 0 ] || printf "\nS2-BUILD: FAILED at line %s (exit %s)\n" "${S2_FAIL_LINE:-unknown}" "$rc"' EXIT

# -----------------------------------------------------------------------------
say "0  what the container needs"
# -----------------------------------------------------------------------------
# clang and zlib1g-dev are named in L11. The rest is what the ILCompiler's link
# step actually reaches for: a linker and the C runtime's static bits.
PKGS="dotnet-sdk-10.0 clang zlib1g-dev libc6-dev binutils file"
note "arch     $ARCH  ($RID)"
note "adding   $PKGS"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# shellcheck disable=SC2086
apt-get install --no-install-recommends -y $PKGS >/dev/null

note "sdk      $(dotnet --version 2>/dev/null || echo MISSING)"
note "clang    $(clang --version 2>/dev/null | head -1 || echo MISSING)"
command -v dotnet >/dev/null || die "dotnet-sdk-10.0 did not install"

note "SDKs Canonical actually shipped:"
dotnet --list-sdks | sed 's/^/        /'

# -----------------------------------------------------------------------------
say "1  publish with PublishAot=true"
# -----------------------------------------------------------------------------
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$SRC"/*.csproj "$SRC"/*.cs "$WORK"/
cd "$WORK"

# Telemetry off and a container-local NuGet home, so the publish is
# reproducible and never writes to the bind mount.
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
export NUGET_PACKAGES=/tmp/s2-nuget

# This is the step L11 doubts: it restores Microsoft.DotNet.ILCompiler from
# nuget.org and has to find a version matching Canonical's SDK.
set +e
dotnet publish -c Release -r "$RID" -p:PublishAot=true -o "$WORK/publish" \
    > "$WORK/publish.log" 2>&1
rc=$?
set -e
if [ $rc -ne 0 ]; then
    note "publish failed — the last 40 lines:"
    tail -40 "$WORK/publish.log" | sed 's/^/        /'
    note "ILCompiler resolution, if it got that far:"
    grep -iE "ILCompiler|NETSDK|NU1[0-9]+|error" "$WORK/publish.log" \
        | sed 's/^/        /' | head -20 || true
    die "dotnet publish -p:PublishAot=true failed (exit $rc)"
fi
grep -iE "ILCompiler" "$WORK/publish.log" | sed 's/^/        /' | head -5 || true
note "warnings, if any:"
grep -iE "warning" "$WORK/publish.log" | sed 's/^/        /' | head -10 || note "        (none)"

BIN="$WORK/publish/os7-s2"
[ -x "$BIN" ] || die "no binary at $BIN"

# -----------------------------------------------------------------------------
say "2  what came out"
# -----------------------------------------------------------------------------
note "size     $(du -h "$BIN" | cut -f1)"
note "file     $(file -b "$BIN")"
note "linked against:"
ldd "$BIN" 2>&1 | sed 's/^/        /'

# A NativeAOT binary is native code, not a host that loads a runtime. If any of
# these turn up next to it, something published framework-dependent instead.
for stray in os7-s2.dll os7-s2.runtimeconfig.json libcoreclr.so; do
    if [ -e "$WORK/publish/$stray" ]; then
        die "$stray is present — this is not a NativeAOT publish"
    fi
done
note "no .dll / runtimeconfig.json / libcoreclr.so beside it — genuinely native"

# -----------------------------------------------------------------------------
say "3  run it here"
# -----------------------------------------------------------------------------
# The build container is ubuntu:26.04, the same base as the image, so this is a
# close proxy. run-s2.sh runs the same binary inside the ISO's own root, which
# is the check that actually counts.
"$BIN" || die "the binary failed its own checks in the build container"

mkdir -p "$OUT"
cp "$BIN" "$OUT/"
cp "$WORK/publish.log" "$OUT/"

trap - EXIT
cat <<EOF2

S2-BUILD: COMPLETE
    binary   out/s2/$ARCH/os7-s2
    packages the Dockerfile needs for $ARCH:
             $PKGS
EOF2
