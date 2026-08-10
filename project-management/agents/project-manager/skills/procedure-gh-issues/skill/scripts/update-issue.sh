#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
#
# update-issue.sh — edit fields of an existing GitHub issue via
#                    `gh issue edit`, with the body (when changed at all)
#                    supplied ONLY as a FILE, never built in shell.
#
# CRITICAL — the body is touched ONLY if --body-file is given. When it is
# omitted, this script passes NOTHING body-related (no --body, no
# --body-file) to `gh issue edit` — `gh` then leaves the existing body
# completely untouched. There is no code path here that reads the CURRENT
# body to "preserve" it (unlike link-children.sh, which must splice into an
# existing body); non-clobber is achieved structurally, by simply never
# emitting a body flag unless the caller explicitly asked to replace the
# body. See the argv-building section below for the single guard that
# implements this.
#
# Purpose:
#   Wraps `gh issue edit` so the caller never hand-authors the invocation or
#   the body construction, and can never accidentally wipe an issue's body
#   by editing some OTHER field.
#
# Usage:
#   update-issue.sh --repo OWNER/REPO --issue N
#                    [--title STR] [--body-file PATH]
#                    [--add-label NAME]... [--remove-label NAME]...
#                    [--add-assignee LOGIN]... [--remove-assignee LOGIN]...
#                    [--milestone STR] [-h|--help]
#
#     --repo OWNER/REPO      Target repository (required).
#     --issue N                The issue number to edit (required, positive
#                              integer).
#     --title STR              Replace the title.
#     --body-file PATH          Replace the body from this file (must exist
#                              and be readable). Omit to leave the body
#                              UNCHANGED — see the CRITICAL note above.
#                              There is deliberately NO --body passthrough.
#     --add-label NAME          A label to add. Repeatable and/or
#                              comma-separated. MUST already exist in the
#                              repo — gh errors otherwise (this script does
#                              NOT auto-create one; run ensure-labels.sh
#                              first if the caller wants that).
#     --remove-label NAME       A label to remove. Repeatable and/or
#                              comma-separated.
#     --add-assignee LOGIN      A login to assign. Repeatable and/or
#                              comma-separated.
#     --remove-assignee LOGIN   A login to unassign. Repeatable and/or
#                              comma-separated.
#     --milestone STR           Replace the milestone (must already exist).
#     -h, --help                 Show this help.
#
#   At least ONE field flag is required — a bare --repo/--issue with nothing
#   to change is a usage error, not a silent no-op.
#
# Output:
#   PM_ISSUE_URL=<url>   printed on success.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  issue updated
#   1  gh absent / not authenticated / `gh issue edit` itself failed / it
#      reported success but returned no URL
#   2  usage error (missing/invalid argument, unreadable body-file, or no
#      field flag given at all)
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

for _pm_lib in pm-diag.sh pm-validate.sh pm-gh-preconditions.sh pm-lists.sh; do
	[ -r "$PM_LIB_DIR/$_pm_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_pm_lib" "$PM_LIB_DIR" >&2; exit 1; }
done
unset _pm_lib

# shellcheck source=../lib/pm-diag.sh
. "$PM_LIB_DIR/pm-diag.sh"
# shellcheck source=../lib/pm-validate.sh
. "$PM_LIB_DIR/pm-validate.sh"
# shellcheck source=../lib/pm-gh-preconditions.sh
. "$PM_LIB_DIR/pm-gh-preconditions.sh"
# shellcheck source=../lib/pm-lists.sh
. "$PM_LIB_DIR/pm-lists.sh"

usage() {
	cat <<EOF
Usage: $PROG --repo OWNER/REPO --issue N
              [--title STR] [--body-file PATH]
              [--add-label NAME]... [--remove-label NAME]...
              [--add-assignee LOGIN]... [--remove-assignee LOGIN]...
              [--milestone STR] [-h|--help]

Edit fields of an existing GitHub issue via gh. The body is changed ONLY if
--body-file is given (no flag at all leaves it untouched) — there is no
--body passthrough. At least one field flag is required.

Options:
  --repo OWNER/REPO      Target repository (required).
  --issue N              The issue number to edit (required).
  --title STR            Replace the title.
  --body-file PATH       Replace the body from this file. Omit to leave the
                          body UNCHANGED.
  --add-label NAME       A label to add. Repeatable and/or comma-separated.
                          Must already exist (run ensure-labels.sh first if
                          it doesn't).
  --remove-label NAME    A label to remove. Repeatable and/or comma-separated.
  --add-assignee LOGIN   A login to assign. Repeatable and/or comma-separated.
  --remove-assignee LOGIN  A login to unassign. Repeatable and/or
                          comma-separated.
  --milestone STR        Replace the milestone (must already exist).
  -h, --help             Show this help.

Prints:
  PM_ISSUE_URL=<url>

Exit codes:
  0  updated
  1  gh absent / not authenticated / gh failure / no URL returned
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# List accumulators (POSIX sh has no arrays; a newline-separated string is
# the portable stand-in). All four need IDENTICAL comma-split + trim + append
# behavior, so all four route through the SAME pair in lib/pm-lists.sh —
# split_csv_list (tokenize) and csv_accumulate (append, VALUE-RETURNING) —
# rather than four byte-identical-except-for-the-variable-name append functions.
#
# csv_accumulate RETURNS the new list on stdout instead of mutating a global
# chosen by a name argument: `ADD_LABELS=$(csv_accumulate "$ADD_LABELS" "$2")`
# keeps the target variable at the call site, where the reader can see it, and
# needs no `eval` and no string-keyed dispatcher — the pattern this codebase's
# own conventions reject.
# ---------------------------------------------------------------------------
ADD_LABELS=""
REMOVE_LABELS=""
ADD_ASSIGNEES=""
REMOVE_ASSIGNEES=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_ISSUE=""
OPT_TITLE=""
OPT_BODY_FILE=""
OPT_MILESTONE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)             need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--issue)            need_arg "$1" "${2:-}"; OPT_ISSUE=$2; shift ;;
		--title)            need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--body-file)        need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		--add-label)        need_arg "$1" "${2:-}"; ADD_LABELS=$(csv_accumulate "$ADD_LABELS" "$2"); shift ;;
		--remove-label)     need_arg "$1" "${2:-}"; REMOVE_LABELS=$(csv_accumulate "$REMOVE_LABELS" "$2"); shift ;;
		--add-assignee)     need_arg "$1" "${2:-}"; ADD_ASSIGNEES=$(csv_accumulate "$ADD_ASSIGNEES" "$2"); shift ;;
		--remove-assignee)  need_arg "$1" "${2:-}"; REMOVE_ASSIGNEES=$(csv_accumulate "$REMOVE_ASSIGNEES" "$2"); shift ;;
		--milestone)        need_arg "$1" "${2:-}"; OPT_MILESTONE=$2; shift ;;
		-h|--help)          usage; exit 0 ;;
		--)                 shift; break ;;
		-*)                 usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_ISSUE" ] || { usage >&2; error "--issue is required"; exit 2; }
is_positive_int "$OPT_ISSUE" || { usage >&2; error "--issue must be a positive integer, got: $OPT_ISSUE"; exit 2; }

if [ -n "$OPT_BODY_FILE" ] && { [ ! -f "$OPT_BODY_FILE" ] || [ ! -r "$OPT_BODY_FILE" ]; }; then
	usage >&2
	error "--body-file does not exist or is not readable: $OPT_BODY_FILE"
	exit 2
fi

# At least one field must actually be requested — a bare --repo/--issue is a
# usage error, not a silent no-op that just prints the URL back.
if [ -z "$OPT_TITLE" ] && [ -z "$OPT_BODY_FILE" ] && [ -z "$ADD_LABELS" ] && \
   [ -z "$REMOVE_LABELS" ] && [ -z "$ADD_ASSIGNEES" ] && [ -z "$REMOVE_ASSIGNEES" ] && \
   [ -z "$OPT_MILESTONE" ]; then
	usage >&2
	error "at least one field to change is required (--title, --body-file, --add-label, --remove-label, --add-assignee, --remove-assignee, or --milestone)"
	exit 2
fi

# ---------------------------------------------------------------------------
# gh preconditions
# ---------------------------------------------------------------------------
require_gh_cli

require_gh_auth

init_tmp_err pm-update-issue

# ---------------------------------------------------------------------------
# Build the `gh issue edit` argv as POSITIONAL PARAMETERS — POSIX sh's array
# equivalent. THE non-clobber guard: --body-file is appended to argv ONLY
# when OPT_BODY_FILE is non-empty — if the caller never gave --body-file,
# NO body-related flag is ever added here, so `gh issue edit` leaves the
# existing body exactly as it was.
# ---------------------------------------------------------------------------
set -- gh issue edit "$OPT_ISSUE" --repo "$OPT_REPO"

[ -z "$OPT_TITLE" ]     || set -- "$@" --title "$OPT_TITLE"
[ -z "$OPT_BODY_FILE" ] || set -- "$@" --body-file "$OPT_BODY_FILE"
[ -z "$OPT_MILESTONE" ] || set -- "$@" --milestone "$OPT_MILESTONE"

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

if [ -n "$ADD_ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --add-assignee "$asg"
	done <<EOF
$ADD_ASSIGNEES
EOF
fi

if [ -n "$REMOVE_ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --remove-assignee "$asg"
	done <<EOF
$REMOVE_ASSIGNEES
EOF
fi

# ---------------------------------------------------------------------------
# Edit.
# ---------------------------------------------------------------------------
if ! ISSUE_URL=$("$@" 2>"$TMP_ERR"); then
	error "gh issue edit failed for issue #$OPT_ISSUE"
	emit_captured_stderr
	exit 1
fi

if [ -z "$ISSUE_URL" ]; then
	error "gh issue edit reported success but returned no URL"
	exit 1
fi

printf 'PM_ISSUE_URL=%s\n' "$ISSUE_URL"
exit 0
