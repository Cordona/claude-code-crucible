#!/usr/bin/env sh
#
# create-pr.sh — open a GitHub pull request via `gh`, with the artifact BODY
#                always supplied as a FILE (--body-file), never built in
#                shell.
#
# WHY --body-file only (no --body): same injection-safety rule as
# create-issue.sh — a PR body pulled from real repo content (a diff summary,
# commit messages, linked issue text) can contain a line that collides with
# a heredoc delimiter. This script never constructs the body in a
# string/heredoc/$(), never eval's anything, and only ever passes a
# caller-supplied file straight through to `gh --body-file`. The TITLE, by
# contrast, is a single argv token (`--title "$OPT_TITLE"`) — safe, because
# it is never built via a heredoc/string-interpolated shell construct.
#
# Purpose:
#   Wraps `gh pr create` with an idempotency pre-check `gh` itself does NOT
#   perform: opening a PR when one is already open for the same head branch
#   creates a confusing duplicate. This script checks FIRST and refuses to
#   create a duplicate, pointing the caller at update-pr.sh instead.
#
# Usage:
#   create-pr.sh --repo OWNER/REPO --head BRANCH --base BRANCH --title STR
#                --body-file PATH [--draft] [--reviewer LOGIN]...
#                [--label NAME]... [--assignee LOGIN]... [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --head BRANCH         The branch to merge FROM (required; plain branch
#                          name — see find-pr.sh's note on fork syntax).
#     --base BRANCH          The branch to merge INTO (required).
#     --title STR             PR title (required).
#     --body-file PATH        Path to a file containing the PR body
#                          (required). Must exist and be readable. There is
#                          deliberately NO --body passthrough.
#     --draft                 Open as a draft PR.
#     --reviewer LOGIN         A reviewer to request. Repeatable, and/or a
#                          comma-separated list in one occurrence.
#     --label NAME             A label to apply. Repeatable and/or
#                          comma-separated. NOT pre-checked for existence
#                          (unlike create-issue.sh) — an unknown label
#                          surfaces as a plain gh failure.
#     --assignee LOGIN         A login to assign. Repeatable and/or
#                          comma-separated.
#     -h, --help                Show this help.
#
# Output:
#   On success, stdout carries machine-parseable keys the caller can relay:
#     PM_PR_NUMBER=<n>
#     PM_PR_URL=<url>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  PR created
#   1  gh/awk absent / not authenticated / an open PR already exists for
#      this head / `gh pr create` itself failed
#   2  usage error (missing/invalid argument, unreadable body-file)
#
# NOT performed here (deliberately upstream): the GitHub-ACCOUNT confirmation
# gate (which login is active) — that is `procedure-git-auth`'s job, run by
# the calling agent BEFORE this script (see this skill's SKILL.md).
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
Usage: $PROG --repo OWNER/REPO --head BRANCH --base BRANCH --title STR
              --body-file PATH [--draft] [--reviewer LOGIN]...
              [--label NAME]... [--assignee LOGIN]... [-h|--help]

Open a GitHub PR via gh. The body is ALWAYS a file (--body-file) — there is
no --body passthrough. Refuses to create a duplicate: if an open PR already
exists for --head, this fails and points you at update-pr.sh instead.

Options:
  --repo OWNER/REPO   Target repository (required).
  --head BRANCH       The branch to merge FROM (required).
  --base BRANCH       The branch to merge INTO (required).
  --title STR         PR title (required).
  --body-file PATH    Path to the PR body (required; must exist/readable).
  --draft             Open as a draft PR.
  --reviewer LOGIN    A reviewer to request. Repeatable and/or comma-separated.
  --label NAME        A label to apply. Repeatable and/or comma-separated.
                       NOT pre-checked for existence.
  --assignee LOGIN    A login to assign. Repeatable and/or comma-separated.
  -h, --help          Show this help.

On success, prints:
  PM_PR_NUMBER=<n>
  PM_PR_URL=<url>

Exit codes:
  0  created
  1  gh/awk absent / not authenticated / a PR already exists for --head / gh failure
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
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
# the portable stand-in).
# ---------------------------------------------------------------------------
REVIEWERS=""
LABELS=""
ASSIGNEES=""

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

add_reviewer() {
	while IFS= read -r tok; do
		if [ -z "$REVIEWERS" ]; then REVIEWERS=$tok
		else REVIEWERS="$REVIEWERS
$tok"
		fi
	done <<EOF
$(split_csv_list "$1")
EOF
}

add_label() {
	while IFS= read -r tok; do
		if [ -z "$LABELS" ]; then LABELS=$tok
		else LABELS="$LABELS
$tok"
		fi
	done <<EOF
$(split_csv_list "$1")
EOF
}

add_assignee() {
	while IFS= read -r tok; do
		if [ -z "$ASSIGNEES" ]; then ASSIGNEES=$tok
		else ASSIGNEES="$ASSIGNEES
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
OPT_HEAD=""
OPT_BASE=""
OPT_TITLE=""
OPT_BODY_FILE=""
OPT_DRAFT=0

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)      need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--head)      need_arg "$1" "${2:-}"; OPT_HEAD=$2; shift ;;
		--base)      need_arg "$1" "${2:-}"; OPT_BASE=$2; shift ;;
		--title)     need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--body-file) need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		--draft)     OPT_DRAFT=1 ;;
		--reviewer)  need_arg "$1" "${2:-}"; add_reviewer "$2"; shift ;;
		--label)     need_arg "$1" "${2:-}"; add_label "$2"; shift ;;
		--assignee)  need_arg "$1" "${2:-}"; add_assignee "$2"; shift ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

# ---------------------------------------------------------------------------
# Required-argument validation
# ---------------------------------------------------------------------------
[ -n "$OPT_REPO" ]  || { usage >&2; error "--repo is required"; exit 2; }
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_HEAD" ]  || { usage >&2; error "--head is required"; exit 2; }
[ -n "$OPT_BASE" ]  || { usage >&2; error "--base is required"; exit 2; }
[ -n "$OPT_TITLE" ] || { usage >&2; error "--title is required"; exit 2; }

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

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required for the duplicate-PR pre-check)"
	exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
	error "gh is installed but not authenticated"
	warn  "authenticate with: gh auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-create-pr.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

# ---------------------------------------------------------------------------
# Idempotency pre-check: refuse to open a duplicate PR for this head.
# ---------------------------------------------------------------------------
if ! PRECHECK=$(gh pr list --repo "$OPT_REPO" --head "$OPT_HEAD" --state open \
	--json number,url --jq '.[] | "\(.number)\t\(.url)"' 2>"$TMP_ERR"); then
	error "failed to check for an existing PR on head '$OPT_HEAD'"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

if [ -n "$PRECHECK" ]; then
	EXISTING_URL=$(printf '%s\n' "$PRECHECK" | awk -F'\t' 'NR==1{print $2}')
	error "an open PR already exists for head '$OPT_HEAD': $EXISTING_URL"
	warn  "use update-pr.sh to modify it instead of creating a duplicate"
	exit 1
fi

# ---------------------------------------------------------------------------
# Build the `gh pr create` argv as POSITIONAL PARAMETERS — POSIX sh's array
# equivalent (see standard-shell-script: build commands as arrays, never as
# strings). The body is passed ONLY as a file path; the title is a single
# argv token — neither is ever built via a heredoc/string.
# ---------------------------------------------------------------------------
set -- gh pr create \
	--repo "$OPT_REPO" \
	--head "$OPT_HEAD" \
	--base "$OPT_BASE" \
	--title "$OPT_TITLE" \
	--body-file "$OPT_BODY_FILE"

[ "$OPT_DRAFT" -eq 0 ] || set -- "$@" --draft

if [ -n "$REVIEWERS" ]; then
	while IFS= read -r rev; do
		[ -n "$rev" ] || continue
		set -- "$@" --reviewer "$rev"
	done <<EOF
$REVIEWERS
EOF
fi

if [ -n "$LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --label "$lbl"
	done <<EOF
$LABELS
EOF
fi

if [ -n "$ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --assignee "$asg"
	done <<EOF
$ASSIGNEES
EOF
fi

# ---------------------------------------------------------------------------
# Create.
# ---------------------------------------------------------------------------
if ! PR_URL=$("$@" 2>"$TMP_ERR"); then
	error "gh pr create failed"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

if [ -z "$PR_URL" ]; then
	error "gh pr create reported success but returned no URL"
	exit 1
fi

PR_NUMBER=${PR_URL##*/}
case "$PR_NUMBER" in
	''|*[!0-9]*)
		warn "could not parse a PR number from: $PR_URL"
		PR_NUMBER=""
		;;
esac

printf 'PM_PR_NUMBER=%s\n' "$PR_NUMBER"
printf 'PM_PR_URL=%s\n'    "$PR_URL"
exit 0
