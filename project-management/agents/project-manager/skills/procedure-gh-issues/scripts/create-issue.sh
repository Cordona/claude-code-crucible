#!/usr/bin/env sh
#
# create-issue.sh — create a GitHub issue via `gh`, with the artifact BODY
#                    always supplied as a FILE (--body-file), never built in
#                    shell.
#
# WHY --body-file only (no --body): an issue body pulled from real repo
# content can contain a line that collides with a heredoc delimiter — the
# classic `gh issue create --body "$(cat <<'EOF' ... EOF)"` injection sink.
# This script never constructs the body in a string/heredoc/$(), never
# eval's anything, and only ever passes a caller-supplied file straight
# through to `gh --body-file`.
#
# Purpose:
#   Wraps `gh issue create` with the preconditions gh itself does NOT check:
#   an unknown --label or --milestone makes `gh issue create` fail AFTER
#   validating everything else, creating nothing but wasting the round-trip
#   with a raw gh error. This script checks labels/milestone exist FIRST and
#   fails with a precise, actionable error naming what's missing. It never
#   auto-creates a label or milestone.
#
# Usage:
#   create-issue.sh --repo OWNER/REPO --title STR --body-file PATH
#                    [--label NAME]... [--milestone STR] [--assignee LOGIN]...
#                    [--project NAME]... [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --title STR         Issue title (required).
#     --body-file PATH    Path to a file containing the issue body (required).
#                          Must exist and be readable. There is deliberately
#                          NO --body passthrough — the body is always a file.
#     --label NAME         A label to apply. Repeatable, and/or a
#                          comma-separated list in one occurrence.
#     --milestone STR      An EXISTING milestone title.
#     --assignee LOGIN     A GitHub login to assign. Repeatable.
#     --project NAME        A (classic or v2) project to add the issue to.
#                          Repeatable. UNLIKE --label/--milestone, this has NO
#                          pre-check: project lookup is GraphQL (projects-v2),
#                          out of scope here — an unknown project surfaces as
#                          a plain `gh issue create` failure via the existing
#                          TMP_ERR path below, same as any other gh error.
#     -h, --help           Show this help.
#
# Output:
#   On success, stdout carries machine-parseable keys the caller can relay:
#     PM_ISSUE_NUMBER=<n>
#     PM_ISSUE_URL=<url>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  issue created
#   1  gh absent / not authenticated / an unknown label or milestone /
#      `gh issue create` itself failed
#   2  usage error (missing/invalid argument, unreadable body-file)
#
# NOT performed here (deliberately upstream): the GitHub-ACCOUNT confirmation
# gate (which login is active) — that is `procedure-github-auth`'s job, run by
# the calling agent BEFORE this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). Every external binary is
#   guarded with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo OWNER/REPO --title STR --body-file PATH
              [--label NAME]... [--milestone STR] [--assignee LOGIN]...
              [--project NAME]... [-h|--help]

Create a GitHub issue via gh. The body is ALWAYS a file (--body-file) —
there is no --body passthrough.

Options:
  --repo OWNER/REPO   Target repository (required).
  --title STR         Issue title (required).
  --body-file PATH    Path to the issue body (required; must exist/readable).
  --label NAME        A label to apply. Repeatable and/or comma-separated.
  --milestone STR     An existing milestone title.
  --assignee LOGIN    A login to assign. Repeatable.
  --project NAME      A project to add the issue to. Repeatable. NOT
                       pre-checked (see the script header) — an unknown
                       project surfaces as a plain gh failure.
  -h, --help          Show this help.

On success, prints:
  PM_ISSUE_NUMBER=<n>
  PM_ISSUE_URL=<url>

Exit codes:
  0  created
  1  gh absent / not authenticated / unknown label or milestone / gh failure
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_valid_repo_slug VALUE — allow-list: letters, digits, '.', '_', '-', and
# EXACTLY ONE '/' separating owner/repo, with NO ".." path segment. VALUE is
# interpolated directly into `gh api repos/VALUE/...` REST paths below, so
# this rejects both disallowed characters and dot-segment path traversal
# (e.g. "o/..", "../r") before that ever happens.
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
# the portable stand-in). Kept as plain globals — this script is a single
# short-lived process, not a library.
# ---------------------------------------------------------------------------
LABELS=""       # newline-separated
ASSIGNEES=""    # newline-separated
PROJECTS=""     # newline-separated

# add_label VALUE — split VALUE on commas (comma-list support) and append
# each non-empty, trimmed token as a new line onto $LABELS.
add_label() {
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
		if [ -z "$LABELS" ]; then LABELS=$tok
		else LABELS="$LABELS
$tok"
		fi
	done
}

add_assignee() {
	value=$1
	[ -n "$value" ] || return 0
	if [ -z "$ASSIGNEES" ]; then ASSIGNEES=$value
	else ASSIGNEES="$ASSIGNEES
$value"
	fi
}

add_project() {
	value=$1
	[ -n "$value" ] || return 0
	if [ -z "$PROJECTS" ]; then PROJECTS=$value
	else PROJECTS="$PROJECTS
$value"
	fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_TITLE=""
OPT_BODY_FILE=""
OPT_MILESTONE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)      need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--title)     need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--body-file) need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		--label)     need_arg "$1" "${2:-}"; add_label "$2"; shift ;;
		--milestone) need_arg "$1" "${2:-}"; OPT_MILESTONE=$2; shift ;;
		--assignee)  need_arg "$1" "${2:-}"; add_assignee "$2"; shift ;;
		--project)   need_arg "$1" "${2:-}"; add_project "$2"; shift ;;
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
[ -n "$OPT_REPO" ]      || { usage >&2; error "--repo is required"; exit 2; }
[ -n "$OPT_TITLE" ]     || { usage >&2; error "--title is required"; exit 2; }
[ -n "$OPT_BODY_FILE" ] || { usage >&2; error "--body-file is required"; exit 2; }

is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

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

# ---------------------------------------------------------------------------
# Temp files (mktemp, cleaned up on exit) — used only for gh's OWN stderr and
# for read-only precondition queries. NEVER used for the issue body, which
# only ever travels as the caller's own --body-file path.
# ---------------------------------------------------------------------------
TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-create-issue.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

# ---------------------------------------------------------------------------
# Precondition: every requested label must already exist. gh does not
# auto-create one, and fails the WHOLE create if any single label is unknown.
# ---------------------------------------------------------------------------
if [ -n "$LABELS" ]; then
	if ! EXISTING_LABELS=$(gh api "repos/${OPT_REPO}/labels" --paginate --jq '.[].name' 2>"$TMP_ERR"); then
		error "failed to look up labels for repo '$OPT_REPO'"
		sed 's/^/  /' "$TMP_ERR" >&2
		exit 1
	fi

	MISSING_LABELS=""
	while IFS= read -r want_label; do
		[ -n "$want_label" ] || continue
		if ! printf '%s\n' "$EXISTING_LABELS" | grep -Fxq -- "$want_label"; then
			if [ -z "$MISSING_LABELS" ]; then MISSING_LABELS=$want_label
			else MISSING_LABELS="$MISSING_LABELS, $want_label"
			fi
		fi
	done <<EOF
$LABELS
EOF

	if [ -n "$MISSING_LABELS" ]; then
		error "label(s) not found in repo '$OPT_REPO': $MISSING_LABELS"
		warn  "create them first (never done automatically), e.g.:"
		warn  "  gh label create \"<name>\" --repo \"$OPT_REPO\""
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# Precondition: an explicit milestone must already exist.
# ---------------------------------------------------------------------------
if [ -n "$OPT_MILESTONE" ]; then
	if ! EXISTING_MILESTONES=$(gh api "repos/${OPT_REPO}/milestones?state=all" --paginate --jq '.[].title' 2>"$TMP_ERR"); then
		error "failed to look up milestones for repo '$OPT_REPO'"
		sed 's/^/  /' "$TMP_ERR" >&2
		exit 1
	fi

	if ! printf '%s\n' "$EXISTING_MILESTONES" | grep -Fxq -- "$OPT_MILESTONE"; then
		error "milestone not found in repo '$OPT_REPO': $OPT_MILESTONE"
		warn  "create it first (never done automatically) via the repo's Issues > Milestones page"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# Build the `gh issue create` argv as POSITIONAL PARAMETERS — POSIX sh's
# array equivalent (see standard-shell-script: build commands as arrays,
# never as strings). The body is passed ONLY as a file path; it is never
# read into a shell variable or interpolated into a string here.
# ---------------------------------------------------------------------------
set -- gh issue create \
	--repo "$OPT_REPO" \
	--title "$OPT_TITLE" \
	--body-file "$OPT_BODY_FILE"

if [ -n "$LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --label "$lbl"
	done <<EOF
$LABELS
EOF
fi

[ -z "$OPT_MILESTONE" ] || set -- "$@" --milestone "$OPT_MILESTONE"

if [ -n "$ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --assignee "$asg"
	done <<EOF
$ASSIGNEES
EOF
fi

if [ -n "$PROJECTS" ]; then
	while IFS= read -r proj; do
		[ -n "$proj" ] || continue
		set -- "$@" --project "$proj"
	done <<EOF
$PROJECTS
EOF
fi

# ---------------------------------------------------------------------------
# Create.
# ---------------------------------------------------------------------------
if ! ISSUE_URL=$("$@" 2>"$TMP_ERR"); then
	error "gh issue create failed"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

if [ -z "$ISSUE_URL" ]; then
	error "gh issue create reported success but returned no URL"
	exit 1
fi

ISSUE_NUMBER=${ISSUE_URL##*/}
case "$ISSUE_NUMBER" in
	''|*[!0-9]*)
		warn "could not parse an issue number from: $ISSUE_URL"
		ISSUE_NUMBER=""
		;;
esac

printf 'PM_ISSUE_NUMBER=%s\n' "$ISSUE_NUMBER"
printf 'PM_ISSUE_URL=%s\n'    "$ISSUE_URL"
exit 0
