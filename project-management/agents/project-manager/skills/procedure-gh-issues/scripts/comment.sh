#!/usr/bin/env sh
#
# comment.sh — add a comment to an existing GitHub issue, with the comment
#              BODY always supplied as a FILE (--body-file), never built in
#              shell.
#
# WHY --body-file only (no --body): same injection-safety rule as
# create-issue.sh — a comment body pulled from real repo content can contain
# a line that collides with a heredoc delimiter. This script never
# constructs the body in a string/heredoc/$(), never eval's anything, and
# only ever passes a caller-supplied file straight through to `gh
# --body-file`.
#
# Purpose:
#   Wraps `gh issue comment` so the caller never hand-authors the invocation
#   or the body construction.
#
# Usage:
#   comment.sh --repo OWNER/REPO --issue N --body-file PATH [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --issue N            The issue number to comment on (required,
#                          positive integer).
#     --body-file PATH      Path to a file containing the comment body
#                          (required). Must exist and be readable. There is
#                          deliberately NO --body passthrough.
#     -h, --help             Show this help.
#
# Output:
#   PM_COMMENT_URL=<url>   printed IF gh returns one; a successful comment
#                          post that returns no URL still exits 0 with this
#                          key EMPTY — the URL is a courtesy, not the proof
#                          of success (gh's own exit code is that proof).
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  comment posted
#   1  gh absent / not authenticated / `gh issue comment` itself failed
#   2  usage error (missing/invalid argument, unreadable body-file)
#
# NOT performed here (deliberately upstream): the GitHub-ACCOUNT confirmation
# gate — that is `procedure-github-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo OWNER/REPO --issue N --body-file PATH [-h|--help]

Add a comment to a GitHub issue via gh. The body is ALWAYS a file
(--body-file) — there is no --body passthrough.

Options:
  --repo OWNER/REPO   Target repository (required).
  --issue N           The issue number to comment on (required).
  --body-file PATH    Path to the comment body (required; must exist/readable).
  -h, --help          Show this help.

Prints (may be empty even on success):
  PM_COMMENT_URL=<url>

Exit codes:
  0  posted
  1  gh absent / not authenticated / gh failure
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the number GitHub would echo back. Both used to slip through and
# surface as a confusing `gh` failure (exit 1) instead of the usage error (exit 2)
# this script's own header documents. Kept byte-identical to the GitLab siblings'
# (procedure-glab-issues) so the two families cannot diverge again.
is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;   # empty or a non-digit
		0*) return 1 ;;            # a bare '0', and any leading-zero form
		*) return 0 ;;
	esac
}

# is_valid_repo_slug VALUE — allow-list: letters, digits, '.', '_', '-', and
# EXACTLY ONE '/' separating owner/repo, with NO ".." path segment. VALUE is
# interpolated into `gh` arguments, so this rejects both disallowed
# characters and dot-segment path traversal (e.g. "o/..", "../r") before
# that ever happens.
is_valid_repo_slug() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;
		..|../*|*/..|*/../*) return 1 ;;
		*/*/*) return 1 ;;
		*/*) return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_ISSUE=""
OPT_BODY_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)      need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--issue)     need_arg "$1" "${2:-}"; OPT_ISSUE=$2; shift ;;
		--body-file) need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ]      || { usage >&2; error "--repo is required"; exit 2; }
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_ISSUE" ] || { usage >&2; error "--issue is required"; exit 2; }
is_positive_int "$OPT_ISSUE" || { usage >&2; error "--issue must be a positive integer, got: $OPT_ISSUE"; exit 2; }

[ -n "$OPT_BODY_FILE" ] || { usage >&2; error "--body-file is required"; exit 2; }
if [ ! -f "$OPT_BODY_FILE" ] || [ ! -r "$OPT_BODY_FILE" ]; then
	usage >&2
	error "--body-file does not exist or is not readable: $OPT_BODY_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# gh preconditions
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
	error "GitHub CLI (gh) is not installed"
	warn  "install it from https://cli.github.com/ then re-run"
	exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
	error "gh is installed but not authenticated"
	warn  "authenticate with: gh auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-comment.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

# ---------------------------------------------------------------------------
# Post the comment. The body is passed ONLY as a file path; it is never read
# into a shell variable or interpolated into a string here.
# ---------------------------------------------------------------------------
if ! COMMENT_URL=$(gh issue comment "$OPT_ISSUE" --repo "$OPT_REPO" --body-file "$OPT_BODY_FILE" 2>"$TMP_ERR"); then
	error "gh issue comment failed"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

printf 'PM_COMMENT_URL=%s\n' "$COMMENT_URL"
exit 0
