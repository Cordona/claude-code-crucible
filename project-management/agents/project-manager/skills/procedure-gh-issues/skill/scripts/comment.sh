#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
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
#   with `command -v`. Sources this skill's own lib/ (see the
#   PM_LIB_DIR preamble below); depends on nothing outside this skill directory.
#
set -eu

# Locate this skill's lib/ RELATIVE TO THIS SCRIPT, using only parameter
# expansion. Never dirname/readlink/realpath/basename: the test harness runs
# every command under a minimal PATH toolbox that deliberately excludes all
# four, so any of them would break the whole suite. The `*)` branch is
# unreachable in practice (the harness and SKILL.md always invoke these scripts
# by an absolute path) but exists so `set -u` can never see an unset
# PM_LIB_DIR.
case "$0" in
	*/*) PM_LIB_DIR=${0%/*}/../lib ;;
	*)   PM_LIB_DIR=../lib ;;
esac

for _pm_lib in pm-diag.sh pm-validate.sh pm-gh-preconditions.sh; do
	[ -r "$PM_LIB_DIR/$_pm_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_pm_lib" "$PM_LIB_DIR" >&2; exit 1; }
done
unset _pm_lib

# shellcheck source=../lib/pm-diag.sh
. "$PM_LIB_DIR/pm-diag.sh"
# shellcheck source=../lib/pm-validate.sh
. "$PM_LIB_DIR/pm-validate.sh"
# shellcheck source=../lib/pm-gh-preconditions.sh
. "$PM_LIB_DIR/pm-gh-preconditions.sh"

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
require_gh_cli

require_gh_auth

init_tmp_err pm-comment

# ---------------------------------------------------------------------------
# Post the comment. The body is passed ONLY as a file path; it is never read
# into a shell variable or interpolated into a string here.
# ---------------------------------------------------------------------------
if ! COMMENT_URL=$(gh issue comment "$OPT_ISSUE" --repo "$OPT_REPO" --body-file "$OPT_BODY_FILE" 2>"$TMP_ERR"); then
	error "gh issue comment failed"
	emit_captured_stderr
	exit 1
fi

printf 'PM_COMMENT_URL=%s\n' "$COMMENT_URL"
exit 0
