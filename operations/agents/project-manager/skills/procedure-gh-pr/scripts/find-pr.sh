#!/usr/bin/env sh
#
# find-pr.sh — READ-ONLY idempotency check before opening a pull request:
#              is there already an open PR for this head branch? Never
#              writes anything.
#
# Purpose:
#   Wraps `gh pr list --head ... --state open` so a caller (the
#   project-manager, or create-pr.sh's own pre-check) can check for an
#   existing PR BEFORE opening a new one, without hand-authoring the query.
#
# Usage:
#   find-pr.sh --repo OWNER/REPO --head BRANCH [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --head BRANCH         The head branch to check (required). NOTE: `gh
#                          pr list --head` takes a PLAIN branch name — it
#                          does NOT support `owner:branch` fork syntax.
#     -h, --help             Show this help.
#
# Output:
#   PM_PR_COUNT=<n>         always printed.
#   PM_PR_NUMBER=<n>        printed ONLY when exactly one open PR was found.
#   PM_PR_URL=<url>         printed ONLY when exactly one open PR was found.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  query ran cleanly (count may be 0 — that is NOT a failure)
#   1  gh/awk absent / not authenticated / the gh query itself failed
#   2  usage error
#
# Portability: POSIX sh only (no bashisms). Read-only: never writes to the
#   tracker. Every external binary is guarded with `command -v`.
#   Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo OWNER/REPO --head BRANCH [-h|--help]

Read-only duplicate check: is there already an open PR for this head branch?
Never creates or modifies anything.

Options:
  --repo OWNER/REPO   Target repository (required).
  --head BRANCH       The head branch to check (required; plain branch name,
                       NOT owner:branch fork syntax — gh pr list --head
                       doesn't support that).
  -h, --help          Show this help.

Prints:
  PM_PR_COUNT=<n>
  PM_PR_NUMBER=<n>   (only when count is exactly 1)
  PM_PR_URL=<url>    (only when count is exactly 1)

Exit codes:
  0  ran cleanly (count may be 0)
  1  gh/awk absent / not authenticated / query failed
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

OPT_REPO=""
OPT_HEAD=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo) need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--head) need_arg "$1" "${2:-}"; OPT_HEAD=$2; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_HEAD" ] || { usage >&2; error "--head is required"; exit 2; }

# ---------------------------------------------------------------------------
# gh preconditions
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
	error "GitHub CLI (gh) is not installed"
	warn  "install it from https://cli.github.com/ then re-run"
	exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required to count results)"
	exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
	error "gh is installed but not authenticated"
	warn  "authenticate with: gh auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-find-pr.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

if ! RESULT=$(gh pr list --repo "$OPT_REPO" --head "$OPT_HEAD" --state open \
	--json number,url --jq '.[] | "\(.number)\t\(.url)"' 2>"$TMP_ERR"); then
	error "gh pr list failed"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

if [ -n "$RESULT" ]; then
	# awk's END{print NR} counts RECORDS (lines), including a final line with
	# no trailing newline — unlike `wc -l`, which counts newline BYTES. It
	# also always exits 0, so it never trips `set -e` on a genuine result.
	COUNT=$(printf '%s\n' "$RESULT" | awk 'END { print NR }')
else
	COUNT=0
fi

printf 'PM_PR_COUNT=%s\n' "$COUNT"

if [ "$COUNT" -eq 1 ]; then
	printf '%s\n' "$RESULT" | awk -F'\t' '{ printf "PM_PR_NUMBER=%s\nPM_PR_URL=%s\n", $1, $2 }'
fi

exit 0
