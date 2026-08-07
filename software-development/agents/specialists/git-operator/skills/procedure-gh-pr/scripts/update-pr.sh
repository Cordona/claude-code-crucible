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

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the number GitHub would echo back. Both used to slip through and
# surface as a confusing `gh` failure (exit 1) instead of the usage error
# (exit 2) they are. Kept byte-identical to procedure-glab-mr's update-mr.sh so
# the two siblings cannot drift apart.
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
# List accumulators (POSIX sh has no arrays; a newline-separated string is
# the portable stand-in). Four accumulators need IDENTICAL comma-split +
# trim behavior, so that parsing is factored into split_csv_list (prints one
# trimmed, non-empty token per line) and each accumulator gets its own tiny
# append function — not a single function keyed by a "which list" string
# argument, which would be a flag parameter switching behavior in disguise.
# ---------------------------------------------------------------------------
ADD_LABELS=""
REMOVE_LABELS=""
ADD_REVIEWERS=""
REMOVE_REVIEWERS=""

# split_csv_list VALUE — print each comma-separated, trimmed, non-empty
# token in VALUE on its own line (stdout). Read via a heredoc (never piped
# into a `while read`), so the caller's loop stays in the CURRENT shell and
# can mutate its own accumulator — piping into the loop would run it in a
# subshell and lose that mutation on exit.
split_csv_list() {
	value=$1
	old_ifs=$IFS
	IFS=','
	set -f
	# shellcheck disable=SC2086  # deliberate split of a comma-list on IFS=','; -f (above) blocks globbing
	set -- $value
	set +f
	IFS=$old_ifs
	for tok in "$@"; do
		tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$tok" ] || continue
		printf '%s\n' "$tok"
	done
}

add_add_label() {
	while IFS= read -r tok; do
		if [ -z "$ADD_LABELS" ]; then ADD_LABELS=$tok
		else ADD_LABELS="$ADD_LABELS
$tok"
		fi
	done <<EOF
$(split_csv_list "$1")
EOF
}

add_remove_label() {
	while IFS= read -r tok; do
		if [ -z "$REMOVE_LABELS" ]; then REMOVE_LABELS=$tok
		else REMOVE_LABELS="$REMOVE_LABELS
$tok"
		fi
	done <<EOF
$(split_csv_list "$1")
EOF
}

add_add_reviewer() {
	while IFS= read -r tok; do
		if [ -z "$ADD_REVIEWERS" ]; then ADD_REVIEWERS=$tok
		else ADD_REVIEWERS="$ADD_REVIEWERS
$tok"
		fi
	done <<EOF
$(split_csv_list "$1")
EOF
}

add_remove_reviewer() {
	while IFS= read -r tok; do
		if [ -z "$REMOVE_REVIEWERS" ]; then REMOVE_REVIEWERS=$tok
		else REMOVE_REVIEWERS="$REMOVE_REVIEWERS
$tok"
		fi
	done <<EOF
$(split_csv_list "$1")
EOF
}

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
		--add-label)          need_arg "$1" "${2:-}"; add_add_label "$2"; shift ;;
		--remove-label)       need_arg "$1" "${2:-}"; add_remove_label "$2"; shift ;;
		--add-reviewer)       need_arg "$1" "${2:-}"; add_add_reviewer "$2"; shift ;;
		--remove-reviewer)    need_arg "$1" "${2:-}"; add_remove_reviewer "$2"; shift ;;
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

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-update-pr.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

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
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

printf 'PM_PR_URL=%s\n' "$PR_URL"
exit 0
