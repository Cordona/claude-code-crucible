#!/usr/bin/env sh
#
# create-tag.sh — cut a signed, annotated release tag, refusing outright to
#                 re-tag or move an already-published version.
#
# WHY --message-file only (no -m "$msg"): same injection-safety rule as
# commit.sh — a tag message can be derived from a changelog/release-notes
# body and can contain backticks/$(). This script never constructs the
# message in a string/heredoc/$(), and only ever passes a caller-supplied
# file straight through to `git tag -F`.
#
# REFUSE RE-TAG/MOVE: if the tag name already exists, this script FAILS
# outright — it never deletes, moves, or re-signs an existing tag. A
# released version is immutable (standard-git-tag); re-cutting one is
# always the wrong operation, never something to retry past.
#
# FAIL-CLOSED ON SIGNING: after creating the tag, this script verifies it
# with `git tag -v`. If verification fails, this is reported as a failure —
# the tag object already exists locally but is NOT treated as good, and this
# script does not delete it automatically (same reporting-not-reverting
# posture as commit.sh, for the same reason: undoing is a mutating decision
# outside this script's narrow scope).
#
# WHAT THIS SCRIPT DOES NOT DO: it does not decide WHAT to release or run
# the release-prep build (standard-git-tag: that runs once, at the release
# boundary, before this script is even called) — it only cuts and verifies
# the tag object once the caller has already decided the version and SHA.
#
# Purpose:
#   Wraps `git tag -s` with the two checks a direct git invocation would
#   skip: refusing to move an already-published version, and verifying the
#   freshly created tag is actually, verifiably signed.
#
# Usage:
#   create-tag.sh --repo PATH --version VER --sha SHA --message-file PATH
#                 [-h|--help]
#
#     --repo PATH             The git repo to act in (required); this
#                             script cd's into it.
#     --version VER             SemVer, `vX.Y.Z` or `X.Y.Z` (required).
#     --sha SHA                   The commit to tag (required); must
#                             resolve to a real commit.
#     --message-file PATH           Path to the tag message (required).
#                             Must exist and be readable. There is
#                             deliberately NO -m/--message passthrough.
#     -h, --help                       Show this help.
#
# Output:
#   GITOP_TAG=<version>   printed on success (tag created AND verified).
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  tag created and verified signed
#   1  the tag already exists / --sha does not resolve to a commit / `git
#      tag` itself failed / signature verification failed
#   2  usage error (missing/invalid argument, unreadable message-file, or
#      --version is not SemVer-shaped)
#
# NOT performed here (deliberately upstream): deciding what to release, the
# release-prep build (standard-git-tag), and identity/signing confirmation
# (procedure-git-identity) — see this skill's SKILL.md.
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

error() { printf '%s: error: %s\n' "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --version VER --sha SHA --message-file PATH
              [-h|--help]

Cut a signed, annotated release tag. The message is ALWAYS a file
(--message-file) — there is no -m/--message passthrough. Refuses outright
to re-tag/move an already-published version. Fails closed unless the tag
verifies.

Options:
  --repo PATH           The git repo to act in (required).
  --version VER         SemVer: vX.Y.Z or X.Y.Z (required).
  --sha SHA             The commit to tag (required).
  --message-file PATH   Path to the tag message (required; must exist/readable).
  -h, --help            Show this help.

Prints:
  GITOP_TAG=<version>

Exit codes:
  0  created and verified
  1  tag already exists / sha not found / git tag failed / verify failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_semver VALUE — vX.Y.Z or X.Y.Z, each component all-digits. This
# validates the CORE SemVer shape (standard-git-tag's own examples, e.g.
# "v2.4.1") — prerelease/build-metadata suffixes are deliberately out of
# scope for this check (YAGNI: not asked for, and the core shape is what
# every caller of this script actually produces).
is_semver() {
	value=${1#v}
	case "$value" in
		*[!0-9.]*) return 1 ;;
		*.*.*)
			old_ifs=$IFS
			IFS='.'
			# shellcheck disable=SC2086  # deliberate split on IFS='.' to count components
			set -- $value
			IFS=$old_ifs
			[ $# -eq 3 ] || return 1
			for part in "$@"; do
				[ -n "$part" ] || return 1
			done
			return 0
			;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_VERSION=""
OPT_SHA=""
OPT_MESSAGE_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)         need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--version)      need_arg "$1" "${2:-}"; OPT_VERSION=$2; shift ;;
		--sha)          need_arg "$1" "${2:-}"; OPT_SHA=$2; shift ;;
		--message-file) need_arg "$1" "${2:-}"; OPT_MESSAGE_FILE=$2; shift ;;
		-h|--help)      usage; exit 0 ;;
		--)             shift; break ;;
		-*)             usage >&2; error "unknown option: $1"; exit 2 ;;
		*)              usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ]    || { usage >&2; error "--repo is required"; exit 2; }
[ -n "$OPT_VERSION" ] || { usage >&2; error "--version is required"; exit 2; }
[ -n "$OPT_SHA" ]     || { usage >&2; error "--sha is required"; exit 2; }

is_semver "$OPT_VERSION" || { usage >&2; error "--version must be SemVer (vX.Y.Z or X.Y.Z), got: $OPT_VERSION"; exit 2; }

[ -n "$OPT_MESSAGE_FILE" ] || { usage >&2; error "--message-file is required"; exit 2; }
if [ ! -f "$OPT_MESSAGE_FILE" ] || [ ! -r "$OPT_MESSAGE_FILE" ]; then
	usage >&2
	error "--message-file does not exist or is not readable: $OPT_MESSAGE_FILE"
	exit 2
fi

if ! command -v git >/dev/null 2>&1; then
	error "git is not installed"
	exit 1
fi

cd "$OPT_REPO" 2>/dev/null || { error "--repo does not exist or is not accessible: $OPT_REPO"; exit 1; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	error "not a git work tree: $OPT_REPO"
	exit 1
fi

# ---------------------------------------------------------------------------
# Refuse re-tag/move: a released version is immutable.
# ---------------------------------------------------------------------------
if git rev-parse --verify --quiet "refs/tags/$OPT_VERSION" >/dev/null 2>&1; then
	error "tag '$OPT_VERSION' already exists — refusing to re-tag/move a published version"
	exit 1
fi

# ---------------------------------------------------------------------------
# --sha must resolve to a real commit.
# ---------------------------------------------------------------------------
if ! git rev-parse --verify --quiet "$OPT_SHA^{commit}" >/dev/null 2>&1; then
	error "--sha does not resolve to a commit: $OPT_SHA"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/gitop-create-tag.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

# ---------------------------------------------------------------------------
# Create the signed, annotated tag. The message is passed ONLY as a file
# path; it is never read into a shell variable or interpolated here.
# ---------------------------------------------------------------------------
if ! git tag -s "$OPT_VERSION" "$OPT_SHA" -F "$OPT_MESSAGE_FILE" 2>"$TMP_ERR"; then
	error "git tag failed (signing failure or another git error)"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Fail-closed verification. The tag object above already exists; this never
# deletes or retries it, it only reports.
# ---------------------------------------------------------------------------
if ! git tag -v "$OPT_VERSION" >/dev/null 2>"$TMP_ERR"; then
	error "tag '$OPT_VERSION' was created but FAILED verification — it was NOT deleted automatically; inspect/remove it before proceeding"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

printf 'GITOP_TAG=%s\n' "$OPT_VERSION"
exit 0
