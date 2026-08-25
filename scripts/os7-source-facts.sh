#!/usr/bin/env bash
# =============================================================================
# OS/7 — the three SOURCE FACTS, asked of git on the HOST.
#
# Prints exactly three lines on stdout and nothing else:
#
#     OS7_VERSION_BUILD=<git rev-list --count HEAD>
#     OS7_GIT_COMMIT=<git rev-parse --short=12 HEAD>
#     OS7_GIT_DIRTY=<true|false>
#
# It does NOT compose a version number, and must never start.
# docs/RELEASE-AND-UPDATE-PLAN.md §3: build/config/os7-release.conf is the only
# place a version may be written down, and build/build.sh is the only place the
# four fields are joined into a string. This hands over the one field neither of
# them can know — the one that lives in git — and stops there.
#
# WHY IT IS ON THE HOST
#   Two build paths cannot ask git for themselves, for different reasons:
#
#     * The QEMU amd64 VM (scripts/build-amd64-vm.sh) copies the tree in with
#       `tar --exclude=.git`, so there is no repository in the VM at all.
#
#     * A git WORKTREE has a `.git` FILE, not a directory, holding one line:
#           gitdir: /Users/…/OS7/.git/worktrees/<name>
#       an absolute path OUTSIDE the tree that gets bind-mounted at /work. git
#       in the build container therefore answers, measured 2026-08-24:
#           fatal: not a git repository: /Users/…/.git/worktrees/<name>
#       and every ISO built from a worktree carried BUILD=0, commit "unknown"
#       and reproducible=false. (docs/BUILD-NOTES.md #43.)
#
#   The host has the whole repository in both cases. Ask there, hand the answers
#   in, and an ISO carries the same version whichever way it was built.
#
# Usage:
#     eval "$(scripts/os7-source-facts.sh)"                       # shell
#     $(addprefix -e ,$(shell ./scripts/os7-source-facts.sh))     # Makefile
#     scripts/os7-source-facts.sh [<repo>]                        # default: ..
#
# Exit 0 with three lines on stdout, or exit 1 with NOTHING on stdout and the
# reason on stderr. A caller that gets nothing must not invent the facts: an
# empty hand-in leaves build.sh to decide, which is where that decision lives.
# =============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$(cd "${HERE}/.." && pwd)}"

note() { printf '!!! os7-source-facts: %s\n' "$*" >&2; }

command -v git >/dev/null 2>&1 || { note "git is not on PATH"; exit 1; }

GIT=(git -C "${REPO}")

# Ask git whether it can read this tree, and keep what it says if it cannot -
# "not a git repository", "dubious ownership" and "no commits yet" need
# different fixes and the caller's message would have to guess between them.
if ! GIT_ERROR="$("${GIT[@]}" rev-parse --git-dir 2>&1 >/dev/null)"; then
	note "cannot read a repository at ${REPO}: ${GIT_ERROR}"
	exit 1
fi

# A SHALLOW clone answers `rev-list --count HEAD` with the number of commits it
# happens to hold, not the number that exist - `actions/checkout` fetches depth 1
# by default, which would make every CI build BUILD=1 while looking entirely
# healthy. The count is the one field that must be true across machines, so a
# shallow repository is refused rather than counted.
if [[ "$("${GIT[@]}" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]]; then
	note "${REPO} is a SHALLOW clone - 'rev-list --count HEAD' would undercount"
	note "fix: git fetch --unshallow   (in CI: actions/checkout with fetch-depth: 0)"
	exit 1
fi

COMMIT="$("${GIT[@]}" rev-parse --short=12 HEAD 2>/dev/null || true)"
COUNT="$("${GIT[@]}" rev-list --count HEAD 2>/dev/null || true)"
if [[ -n "$("${GIT[@]}" status --porcelain 2>/dev/null)" ]]; then
	DIRTY=true
else
	DIRTY=false
fi

# Check the answers before handing them on. build/build.sh interpolates BUILD
# into the version string and hook 0075 compares OS7_GIT_DIRTY against the
# literal "true" - so a value that is merely non-empty (an empty repository, a
# git that printed a warning onto stdout, "yes" instead of "true") would produce
# a version that looks well-formed and a manifest claiming reproducible=true.
# --short may return more than 12 characters when 12 would be ambiguous.
[[ "${COUNT}"  =~ ^[0-9]+$          ]] || { note "rev-list --count HEAD gave '${COUNT}'";        exit 1; }
[[ "${COMMIT}" =~ ^[0-9a-f]{7,40}$  ]] || { note "rev-parse --short=12 HEAD gave '${COMMIT}'";   exit 1; }
[[ "${DIRTY}"  =~ ^(true|false)$    ]] || { note "internal: dirty flag is '${DIRTY}'";           exit 1; }

printf 'OS7_VERSION_BUILD=%s\n' "${COUNT}"
printf 'OS7_GIT_COMMIT=%s\n'    "${COMMIT}"
printf 'OS7_GIT_DIRTY=%s\n'     "${DIRTY}"
