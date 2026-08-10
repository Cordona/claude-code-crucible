#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
#
# find-duplicate.sh — READ-ONLY idempotency check before creating a backlog
#                      artifact: does an issue with this title/query already
#                      exist? Never writes anything.
#
# Purpose:
#   Wraps `gh issue list --search "<query> in:title" --state all` so a
#   caller (the project-manager) can check for a likely duplicate BEFORE
#   creating a new issue, without hand-authoring the search query itself.
#
# Usage:
#   find-duplicate.sh --repo OWNER/REPO (--title STR | --search QUERY) [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --title STR         Match issues whose title CONTAINS this text (GitHub
#                          search is tokenized/fuzzy, NOT an exact match —
#                          mutually exclusive with --search).
#     --search QUERY      A free-form search query, appended with `in:title`
#                          (mutually exclusive with --title).
#     -h, --help           Show this help.
#
# Output:
#   PM_DUPLICATE_COUNT=<n>
#   PM_DUPLICATE_URLS=<url[,url...]>   (empty when count is 0)
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  query ran cleanly (count may be 0 — that is NOT a failure)
#   1  gh/awk absent / not authenticated / the gh query itself failed
#   2  usage error
#
# Portability: POSIX sh only (no bashisms). Read-only: never writes to the
#   tracker. Every external binary is guarded with `command -v`.
#   Sources this skill's own lib/ (see the
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
Usage: $PROG --repo OWNER/REPO (--title STR | --search QUERY) [-h|--help]

Read-only duplicate check: does an issue matching this title/query already
exist? Never creates or modifies anything.

Options:
  --repo OWNER/REPO   Target repository (required).
  --title STR         Match issues whose title CONTAINS this text (a GitHub
                       search is tokenized/fuzzy, not exact; mutually
                       exclusive with --search).
  --search QUERY      A free-form query, appended with "in:title" (mutually
                       exclusive with --title).
  -h, --help          Show this help.

Prints:
  PM_DUPLICATE_COUNT=<n>
  PM_DUPLICATE_URLS=<url[,url...]>

Exit codes:
  0  ran cleanly (count may be 0)
  1  gh/awk absent / not authenticated / query failed
  2  usage error
EOF
}

OPT_REPO=""
OPT_TITLE=""
OPT_SEARCH=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)   need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--title)  need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--search) need_arg "$1" "${2:-}"; OPT_SEARCH=$2; shift ;;
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

if [ -n "$OPT_TITLE" ] && [ -n "$OPT_SEARCH" ]; then
	usage >&2; error "--title and --search are mutually exclusive"; exit 2
fi
if [ -z "$OPT_TITLE" ] && [ -z "$OPT_SEARCH" ]; then
	usage >&2; error "one of --title or --search is required"; exit 2
fi

QUERY_TEXT=${OPT_TITLE:-$OPT_SEARCH}

# ---------------------------------------------------------------------------
# gh preconditions
# ---------------------------------------------------------------------------
require_gh_cli

require_awk "count results"

require_gh_auth

init_tmp_err pm-find-duplicate

if ! RESULT=$(gh issue list --repo "$OPT_REPO" --search "$QUERY_TEXT in:title" --state all --json url --jq '.[].url' 2>"$TMP_ERR"); then
	error "gh issue list failed"
	emit_captured_stderr
	exit 1
fi

if [ -n "$RESULT" ]; then
	# awk's END{print NR} counts RECORDS (lines), including a final line with
	# no trailing newline — unlike `wc -l`, which counts newline BYTES and so
	# would silently undercount if gh ever emitted an unterminated last line.
	# It also always exits 0, so it never trips `set -e` on a genuine result.
	COUNT=$(printf '%s\n' "$RESULT" | awk 'END { print NR }')
	URLS=$(printf '%s\n' "$RESULT" | paste -s -d, -)
else
	COUNT=0
	URLS=""
fi

printf 'PM_DUPLICATE_COUNT=%s\n' "$COUNT"
printf 'PM_DUPLICATE_URLS=%s\n'  "$URLS"
exit 0
