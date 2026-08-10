#!/usr/bin/env sh
#
# find-pr.sh — READ-ONLY idempotency check before opening a pull request:
#              is there already an open PR for this head branch? Never
#              writes anything.
#
# Purpose:
#   Wraps `gh pr list --head ... --state open` so a caller (the
#   git-operator, or create-pr.sh's own pre-check) can check for an
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
#
# Sources `lib/gh-pr-common.sh` from the sibling lib/ directory (resolved from
#   $0 by parameter expansion — see the preamble below). That file holds the
#   diagnostics, argument validators, `gh` preconditions and comma-list parsing
#   shared by all three scripts here; usage() and the `gh` argv builder stay in
#   THIS file. The lib is skill-local: nothing outside this skill is ever
#   sourced, so this skill still deploys and runs on its own.
#
set -eu

# Resolve the sibling lib/ from THIS script's own location, using only shell
# parameter expansion: `dirname`/`readlink`/`realpath`/`basename` are all
# deliberately absent from the test harness's isolated PATH toolbox, so any of
# them here would break the suite (and any minimal deployment) outright. The
# `*)` arm covers an invocation with no '/' at all (`sh find-pr.sh` from inside
# scripts/), where $0 is a bare name and the sibling lib is at ../lib.
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
require_gh

require_awk "required to count results"

require_gh_auth

init_tmp_err pm-find-pr

if ! RESULT=$(gh pr list --repo "$OPT_REPO" --head "$OPT_HEAD" --state open \
	--json number,url --jq '.[] | "\(.number)\t\(.url)"' 2>"$TMP_ERR"); then
	error "gh pr list failed"
	emit_captured_stderr
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
