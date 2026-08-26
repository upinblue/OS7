# shellcheck shell=sh
# =============================================================================
# OS/7 — the version DISPLAY RULE, in shell.
#
# docs/IDENTITY-PLAN.md §5.1. There is ONE version number — MAJOR.MINOR.PATCH.BUILD
# — and two ways of showing it, chosen by one question:
#
#     does this number IDENTIFY a thing, or DESCRIBE one?
#
# Describe -> three fields. Identify -> four. A channel that is not `stable`
# names itself in brackets, in both forms.
#
# WHY THIS IS A FILE AND NOT THREE LINES INSIDE build.sh. The same rule is
# implemented in C# (installer/src/OS7.Setup/Model/Release.cs), in PowerShell
# (Get-OS7Version) and in Python (installer/testing/os7version.py). Four
# implementations of one specification is a standing invitation to drift, and
# the only defence is that every one of them is reachable by
# installer/testing/check-version-rule.py, which owns the case table and drives
# all four over it. A rule buried inside a 700-line build script is not
# reachable, so it would be the one that drifted.
#
# POSIX sh, not bash: the checker sources it with `sh -c`, and hook scripts and
# the build container should both be able to.
# =============================================================================

# The first three fields. "1.0.0.95" -> "1.0.0".
#
# DERIVED, never stored. Fewer than four fields comes back unchanged rather than
# padded, and more than four keeps the first three — nothing should produce
# either, but a version is read out of a file and a file can hold anything.
os7_friendly() {
	case "$1" in
		*.*.*.*) printf '%s' "$1" | cut -d. -f1-3 ;;
		*)       printf '%s' "$1" ;;
	esac
}

# version, channel -> "1.0.0 (development)" / "1.0.0" on stable.
os7_short() {
	_os7_format "$(os7_friendly "$1")" "$2"
}

# version, channel -> "1.0.0.95 (development)" / "1.0.0.95" on stable.
os7_full() {
	_os7_format "$1" "$2"
}

# The product line: "OS/7 1.0.0 (development)". What PRETTY_NAME, /etc/issue and
# the MOTD header all carry, composed once so they cannot disagree.
os7_product() {
	printf 'OS/7 %s' "$(os7_short "$1" "$2")"
}

# Internal. An empty version is "unknown" rather than a plausible-looking
# number, matching Model/Release.cs's Release.Unknown and Get-OS7Version's
# not-Known object; an empty channel is "unknown" rather than silently stable,
# because a preview build mistaken for a released one is the whole reason the
# channel field exists.
_os7_format() {
	if [ -z "$1" ]; then printf 'unknown'; return; fi
	if [ -z "$2" ] || [ "$2" = unknown ]; then printf '%s (unknown)' "$1"; return; fi
	if [ "$2" = stable ]; then printf '%s' "$1"; else printf '%s (%s)' "$1" "$2"; fi
}
