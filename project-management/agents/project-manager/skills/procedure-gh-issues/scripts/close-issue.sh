#!/usr/bin/env sh
#
# close-issue.sh — close a GitHub issue, with an optional closing comment
#                  supplied ONLY as a FILE, never built in shell.
#
# Mechanism (deliberate choice — see the skill's SKILL.md): a closing
# comment is posted as a SEPARATE `gh issue comment --body-file` call BEFORE
# `gh issue close` runs — never via a `gh issue close --comment` STRING
# flag. Two reasons: (1) this skill's rule is that comment/body content is
# ALWAYS a file, full stop — reading a file into a shell variable just to
# hand it to `--comment "$VALUE"` still means untrusted content passed
# through a shell variable, which the rule forbids regardless of whether
# that particular sink is technically injection-safe; (2) it reuses the
# already-proven-safe comment.sh mechanism instead of a `gh issue close`
# comment flag whose exact name/behavior could not be verified against a
# real `gh` in this environment (no live gh, no network — see Constraints).
# This is a documented choice, not an oversight — same category of judgment
# as link-children.sh's task-list mechanism.
#
# Purpose:
#   Wraps `gh issue close` (plus an optional preceding comment post) so the
#   caller never hand-authors the invocation or the comment construction.
#
# Usage:
#   close-issue.sh --repo OWNER/REPO --issue N
#                   [--reason completed|not_planned] [--comment-file PATH]
#                   [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --issue N             The issue number to close (required, positive
#                          integer).
#     --reason STR           One of: completed, not_planned (optional; gh
#                          defaults to "completed" when omitted).
#     --comment-file PATH    Path to a file containing an optional closing
#                          comment, posted BEFORE the close (must exist and
#                          be readable if given). There is deliberately NO
#                          inline --comment passthrough.
#     -h, --help             Show this help.
#
# Output: none on success beyond the exit code (diagnostics go to stderr).
#
# Exit codes:
#   0  issue closed (and the closing comment, if any, was posted first)
#   1  gh absent / not authenticated / the comment post failed / `gh issue
#      close` itself failed
#   2  usage error (missing/invalid argument, unreadable comment-file, or an
#      invalid --reason)
#
# NOT performed here (deliberately upstream): the GitHub-ACCOUNT confirmation
# gate — that is `procedure-git-auth`'s job, run by the calling agent BEFORE
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
Usage: $PROG --repo OWNER/REPO --issue N
              [--reason completed|not_planned] [--comment-file PATH]
              [-h|--help]

Close a GitHub issue via gh. An optional closing comment is ALWAYS a file
(--comment-file), posted before the close — there is no inline --comment.

Options:
  --repo OWNER/REPO   Target repository (required).
  --issue N           The issue number to close (required).
  --reason STR        One of: completed, not_planned (optional).
  --comment-file PATH An optional closing comment, posted before the close
                       (must exist/readable if given).
  -h, --help          Show this help.

Exit codes:
  0  closed
  1  gh absent / not authenticated / comment post failed / close failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
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

is_valid_reason() {
	case "$1" in
		completed|not_planned) return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_ISSUE=""
OPT_REASON=""
OPT_COMMENT_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)          need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--issue)         need_arg "$1" "${2:-}"; OPT_ISSUE=$2; shift ;;
		--reason)        need_arg "$1" "${2:-}"; OPT_REASON=$2; shift ;;
		--comment-file)  need_arg "$1" "${2:-}"; OPT_COMMENT_FILE=$2; shift ;;
		-h|--help)       usage; exit 0 ;;
		--)              shift; break ;;
		-*)              usage >&2; error "unknown option: $1"; exit 2 ;;
		*)               usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_ISSUE" ] || { usage >&2; error "--issue is required"; exit 2; }
is_positive_int "$OPT_ISSUE" || { usage >&2; error "--issue must be a positive integer, got: $OPT_ISSUE"; exit 2; }

if [ -n "$OPT_REASON" ]; then
	is_valid_reason "$OPT_REASON" || { usage >&2; error "--reason must be 'completed' or 'not_planned', got: $OPT_REASON"; exit 2; }
fi

if [ -n "$OPT_COMMENT_FILE" ] && { [ ! -f "$OPT_COMMENT_FILE" ] || [ ! -r "$OPT_COMMENT_FILE" ]; }; then
	usage >&2
	error "--comment-file does not exist or is not readable: $OPT_COMMENT_FILE"
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

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-close-issue.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

# ---------------------------------------------------------------------------
# 1. Post the closing comment FIRST, if requested — via --body-file only,
#    same mechanism as comment.sh. Never read into a shell variable.
# ---------------------------------------------------------------------------
COMMENT_POSTED=0
if [ -n "$OPT_COMMENT_FILE" ]; then
	if ! gh issue comment "$OPT_ISSUE" --repo "$OPT_REPO" --body-file "$OPT_COMMENT_FILE" >/dev/null 2>"$TMP_ERR"; then
		error "failed to post closing comment on issue #$OPT_ISSUE"
		sed 's/^/  /' "$TMP_ERR" >&2
		exit 1
	fi
	COMMENT_POSTED=1
fi

# ---------------------------------------------------------------------------
# 2. Close.
# ---------------------------------------------------------------------------
set -- gh issue close "$OPT_ISSUE" --repo "$OPT_REPO"
# `gh issue close --reason` expects "completed" or "not planned" (a SPACE, not an
# underscore). We accept the underscore form (the GitHub-API / caller convention)
# and translate it to gh's spelling here — passing "not_planned" straight through
# makes gh reject it, and (since the comment posts first) leaves the issue OPEN
# with a closing comment on it.
if [ -n "$OPT_REASON" ]; then
	case "$OPT_REASON" in
		not_planned) set -- "$@" --reason "not planned" ;;
		*)           set -- "$@" --reason "$OPT_REASON" ;;
	esac
fi

if ! "$@" >/dev/null 2>"$TMP_ERR"; then
	error "gh issue close failed for issue #$OPT_ISSUE"
	# If the comment already posted, a bare retry would post it AGAIN —
	# say so explicitly so the caller retries without --comment-file.
	if [ "$COMMENT_POSTED" -eq 1 ]; then
		warn "the closing comment was ALREADY POSTED — retry WITHOUT --comment-file to avoid posting it twice"
	fi
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

exit 0
