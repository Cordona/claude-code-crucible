#!/usr/bin/env sh
#
# update-pr.sh — edit fields of an existing GitHub pull request via
#                `gh pr edit`, with the body (when changed at all) supplied
#                ONLY as a FILE, never built in shell.
#
# CRITICAL — the body is touched ONLY if --body-file is given. When it is
# omitted, this script passes NOTHING body-related (no --body, no
# --body-file) to `gh pr edit` — `gh` then leaves the existing body
# completely untouched. There is no code path here that reads the CURRENT
# body to "preserve" it; non-clobber is achieved structurally, by simply
# never emitting a body flag unless the caller explicitly asked to replace
# the body. This mirrors update-issue.sh's non-clobber mechanism exactly.
#
# Purpose:
#   Wraps `gh pr edit` so the caller never hand-authors the invocation or
#   the body construction, and can never accidentally wipe a PR's body by
#   editing some OTHER field.
#
# Usage:
#   update-pr.sh --repo OWNER/REPO --pr N
#                [--title STR] [--body-file PATH] [--base BRANCH]
#                [--add-label NAME]... [--remove-label NAME]...
#                [--add-reviewer LOGIN]... [--remove-reviewer LOGIN]...
#                [-h|--help]
#
#     --repo OWNER/REPO      Target repository (required).
#     --pr N                   The PR number to edit (required, positive
#                              integer).
#     --title STR               Replace the title.
#     --body-file PATH           Replace the body from this file (must exist
#                              and be readable). Omit to leave the body
#                              UNCHANGED — see the CRITICAL note above.
#                              There is deliberately NO --body passthrough.
#     --base BRANCH               Change the PR's base branch.
#     --add-label NAME             A label to add. Repeatable and/or
#                              comma-separated. NOT pre-checked for
#                              existence — gh errors on an unknown one.
#     --remove-label NAME           A label to remove. Repeatable and/or
#                              comma-separated.
#     --add-reviewer LOGIN           A reviewer to request. Repeatable
#                              and/or comma-separated.
#     --remove-reviewer LOGIN         A requested reviewer to remove.
#                              Repeatable and/or comma-separated.
#     -h, --help                       Show this help.
#
#   At least ONE field flag is required — a bare --repo/--pr with nothing to
#   change is a usage error, not a silent no-op.
#
# Output:
#   PM_PR_URL=<url>   printed IF gh returns one; a successful edit that
#                     returns no URL still exits 0 with this key EMPTY — the
#                     URL is a courtesy, not the proof of success (gh's own
#                     exit code is that proof). Same contract as comment.sh.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  PR updated
#   1  gh absent / not authenticated / `gh pr edit` itself failed
#   2  usage error (missing/invalid argument, unreadable body-file, or no
#      field flag given at all)
#
# NOT performed here (deliberately upstream): the GitHub-ACCOUNT confirmation
# gate — that is `procedure-github-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`.
#
# Sources `lib/gh-pr-common.sh` from the sibling lib/ directory (resolved from
#   $0 by parameter expansion — see the preamble below). That file holds the
#   diagnostics, argument validators, `gh` preconditions and comma-list parsing
#   shared by all three scripts here; usage() and the `gh` argv builder stay in
#   THIS file. The lib is skill-local: nothing outside this skill is ever
#   sourced, so this skill still deploys and runs on its own.
#
set -eu

# Resolve the sibling lib/ from THIS script's own location — see find-pr.sh for
# why this uses parameter expansion instead of dirname/readlink/realpath.
case $0 in
	*/*) PR_LIB_DIR=${0%/*}/../lib ;;
	*)   PR_LIB_DIR=../lib ;;
esac
# GUARD THE SOURCE: a `.` on an unreadable file aborts with a raw `.: not found`
# that names neither this script nor the path it tried — worst of all via the
# `*)` bare-name arm above, which resolves against an arbitrary cwd. warn() and
# error() live in the lib and do not exist yet, so this is the ONE diagnostic in
# this file that formats itself; everything after this line uses the lib's.
[ -r "$PR_LIB_DIR/gh-pr-common.sh" ] || { printf '%s: error: cannot locate gh-pr-common.sh at %s (invoke this script by its absolute path)\n' "${0##*/}" "$PR_LIB_DIR" >&2; exit 1; }
# shellcheck source=SCRIPTDIR/../lib/gh-pr-common.sh
. "$PR_LIB_DIR/gh-pr-common.sh"

usage() {
	cat <<EOF
Usage: $PROG --repo OWNER/REPO --pr N
              [--title STR] [--body-file PATH] [--base BRANCH]
              [--add-label NAME]... [--remove-label NAME]...
              [--add-reviewer LOGIN]... [--remove-reviewer LOGIN]...
              [-h|--help]

Edit fields of an existing GitHub PR via gh. The body is changed ONLY if
--body-file is given (no flag at all leaves it untouched) — there is no
--body passthrough. At least one field flag is required.

Options:
  --repo OWNER/REPO       Target repository (required).
  --pr N                  The PR number to edit (required).
  --title STR             Replace the title.
  --body-file PATH        Replace the body from this file. Omit to leave the
                           body UNCHANGED.
  --base BRANCH           Change the PR's base branch.
  --add-label NAME        A label to add. Repeatable and/or comma-separated.
  --remove-label NAME     A label to remove. Repeatable and/or comma-separated.
  --add-reviewer LOGIN    A reviewer to request. Repeatable and/or comma-separated.
  --remove-reviewer LOGIN A requested reviewer to remove. Repeatable and/or
                           comma-separated.
  -h, --help              Show this help.

Prints (may be empty even on success):
  PM_PR_URL=<url>

Exit codes:
  0  updated
  1  gh absent / not authenticated / gh failure
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# List accumulators (POSIX sh has no arrays; a newline-separated string is the
# portable stand-in). The comma-split + trim + append behavior they all share
# lives in the lib's split_csv_list + accumulate; each list keeps its own
# variable at the call site below, so no `eval` and no name-keyed dispatcher is
# ever needed.
# ---------------------------------------------------------------------------
ADD_LABELS=""
REMOVE_LABELS=""
ADD_REVIEWERS=""
REMOVE_REVIEWERS=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_PR=""
OPT_TITLE=""
OPT_BODY_FILE=""
OPT_BASE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)             need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--pr)                need_arg "$1" "${2:-}"; OPT_PR=$2; shift ;;
		--title)             need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--body-file)          need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		--base)               need_arg "$1" "${2:-}"; OPT_BASE=$2; shift ;;
		--add-label)          need_arg "$1" "${2:-}"; ADD_LABELS=$(accumulate "$ADD_LABELS" "$2"); shift ;;
		--remove-label)       need_arg "$1" "${2:-}"; REMOVE_LABELS=$(accumulate "$REMOVE_LABELS" "$2"); shift ;;
		--add-reviewer)       need_arg "$1" "${2:-}"; ADD_REVIEWERS=$(accumulate "$ADD_REVIEWERS" "$2"); shift ;;
		--remove-reviewer)    need_arg "$1" "${2:-}"; REMOVE_REVIEWERS=$(accumulate "$REMOVE_REVIEWERS" "$2"); shift ;;
		-h|--help)            usage; exit 0 ;;
		--)                   shift; break ;;
		-*)                   usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                    usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_PR" ] || { usage >&2; error "--pr is required"; exit 2; }
is_positive_int "$OPT_PR" || { usage >&2; error "--pr must be a positive integer, got: $OPT_PR"; exit 2; }

if [ -n "$OPT_BODY_FILE" ] && { [ ! -f "$OPT_BODY_FILE" ] || [ ! -r "$OPT_BODY_FILE" ]; }; then
	usage >&2
	error "--body-file does not exist or is not readable: $OPT_BODY_FILE"
	exit 2
fi

# At least one field must actually be requested — a bare --repo/--pr is a
# usage error, not a silent no-op that just prints the URL back.
if [ -z "$OPT_TITLE" ] && [ -z "$OPT_BODY_FILE" ] && [ -z "$OPT_BASE" ] && \
   [ -z "$ADD_LABELS" ] && [ -z "$REMOVE_LABELS" ] && \
   [ -z "$ADD_REVIEWERS" ] && [ -z "$REMOVE_REVIEWERS" ]; then
	usage >&2
	error "at least one field to change is required (--title, --body-file, --base, --add-label, --remove-label, --add-reviewer, or --remove-reviewer)"
	exit 2
fi

# ---------------------------------------------------------------------------
# gh preconditions
# ---------------------------------------------------------------------------
require_gh

require_gh_auth

init_tmp_err pm-update-pr

# ---------------------------------------------------------------------------
# Build the `gh pr edit` argv as POSITIONAL PARAMETERS — POSIX sh's array
# equivalent. THE non-clobber guard: --body-file is appended to argv ONLY
# when OPT_BODY_FILE is non-empty — if the caller never gave --body-file, NO
# body-related flag is ever added here, so `gh pr edit` leaves the existing
# body exactly as it was.
# ---------------------------------------------------------------------------
set -- gh pr edit "$OPT_PR" --repo "$OPT_REPO"

[ -z "$OPT_TITLE" ]     || set -- "$@" --title "$OPT_TITLE"
[ -z "$OPT_BODY_FILE" ] || set -- "$@" --body-file "$OPT_BODY_FILE"
[ -z "$OPT_BASE" ]      || set -- "$@" --base "$OPT_BASE"

if [ -n "$ADD_LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --add-label "$lbl"
	done <<EOF
$ADD_LABELS
EOF
fi

if [ -n "$REMOVE_LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --remove-label "$lbl"
	done <<EOF
$REMOVE_LABELS
EOF
fi

if [ -n "$ADD_REVIEWERS" ]; then
	while IFS= read -r rev; do
		[ -n "$rev" ] || continue
		set -- "$@" --add-reviewer "$rev"
	done <<EOF
$ADD_REVIEWERS
EOF
fi

if [ -n "$REMOVE_REVIEWERS" ]; then
	while IFS= read -r rev; do
		[ -n "$rev" ] || continue
		set -- "$@" --remove-reviewer "$rev"
	done <<EOF
$REMOVE_REVIEWERS
EOF
fi

# ---------------------------------------------------------------------------
# Edit.
# ---------------------------------------------------------------------------
if ! PR_URL=$("$@" 2>"$TMP_ERR"); then
	error "gh pr edit failed for PR #$OPT_PR"
	emit_captured_stderr
	exit 1
fi

printf 'PM_PR_URL=%s\n' "$PR_URL"
exit 0
