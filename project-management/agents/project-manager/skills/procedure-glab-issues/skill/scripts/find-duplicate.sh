#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
#
# find-duplicate.sh — READ-ONLY idempotency check before creating a backlog
#                      artifact: does an issue with this title/query already
#                      exist? Never writes anything.
#
# Purpose:
#   Wraps `glab issue list --search "<query>" --in title --all` so a caller
#   (the project-manager) can check for a likely duplicate BEFORE creating a
#   new issue, without hand-authoring the search query itself.
#
# THE GITLAB DIVERGENCE FROM THE GITHUB SIBLING: `gh issue list` takes the
#   scope INSIDE the query string (`--search "<text> in:title" --state all`),
#   whereas glab has dedicated flags — `--in title` scopes the search to titles
#   (its default is `title,description`) and `--all` widens the state filter
#   (glab lists only OPEN issues by default; there is no `--state all`). So the
#   caller's text is passed to `--search` VERBATIM, with nothing appended to it.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any tracker operation, but that confirmation used to bind to NOTHING
#   here: this script let `glab` resolve the target instance from ambient state
#   (the cwd's git remotes, an inherited $GITLAB_HOST, glab's own config). On a
#   machine with two configured instances — the very case the gate exists to
#   disambiguate — the gate could confirm host A while this query silently ran
#   against host B, whenever the same --repo project path resolves on both. This
#   script writes nothing, but its answer GATES a write: a "no duplicate" verdict
#   read off the wrong instance is exactly how a duplicate gets created.
#
#   The fix: the caller passes the ALREADY-CONFIRMED host, and this script
#   exports it as GITLAB_HOST for its OWN process before invoking glab. That is
#   glab's documented per-invocation host selector — glab's README: "you can
#   declare one for the current command with the GITLAB_HOST environment
#   variable"; `glab auth status --help`: the instance is "determined by your
#   current context (git remote, GITLAB_HOST environment variable, or
#   configuration)". Pinning it takes ambient config and glab's gitlab.com
#   default out of the decision, and when the cwd happens to be a checkout of a
#   DIFFERENT instance glab refuses outright ("none of the git remotes …
#   correspond to the GITLAB_HOST environment variable") instead of answering
#   from the wrong place — fail closed either way.
#
#   This script does NOT re-implement the account-confirmation UX; that stays
#   `procedure-gitlab-auth`'s job, upstream. The flag only ENFORCES that the
#   query targets the host already confirmed.
#
# Usage:
#   find-duplicate.sh --repo PATH (--title STR | --search QUERY)
#                      --confirmed-host HOST [-h|--help]
#
#     --repo PATH      Target project path (required). One or more
#                      '/'-separated segments — GitLab subgroups are supported.
#     --confirmed-host HOST
#                      The GitLab host the account gate already CONFIRMED
#                      (required) — e.g. gitlab.com or a self-managed hostname,
#                      spelled the way `glab auth status` reports it (bare host,
#                      optional ':port', no scheme). See "HOST PINNING" above.
#     --title STR      Match issues whose title CONTAINS this text (a GitLab
#                      search is tokenized/fuzzy, NOT an exact match — mutually
#                      exclusive with --search).
#     --search QUERY   A free-form search query, also scoped to titles
#                      (mutually exclusive with --title).
#     -h, --help       Show this help.
#
# Output:
#   PM_DUPLICATE_COUNT=<n>          printed on exit 0 (a clean query, count may
#                                   be 0); NOT printed on exit 1 (glab/awk
#                                   absent, unauthenticated, or query failed).
#   PM_DUPLICATE_URLS=<url[,url...]>   (empty when count is 0)
#   Diagnostics go to stderr.
#
#   The count is a FLOOR, not necessarily a total: the query reads ONE page of
#   SEARCH_PER_PAGE results (see below), so a count equal to that page size is
#   warned about on stderr rather than silently presented as complete.
#
# Exit codes:
#   0  query ran cleanly (count may be 0 — that is NOT a failure)
#   1  glab/awk absent / not authenticated / the glab query itself failed
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

for _pm_lib in pm-diag.sh pm-glab-env.sh pm-validate.sh pm-glab-preconditions.sh; do
	[ -r "$PM_LIB_DIR/$_pm_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_pm_lib" "$PM_LIB_DIR" >&2; exit 1; }
done
unset _pm_lib

# shellcheck source=../lib/pm-diag.sh
. "$PM_LIB_DIR/pm-diag.sh"
# shellcheck source=../lib/pm-glab-env.sh
. "$PM_LIB_DIR/pm-glab-env.sh"
# shellcheck source=../lib/pm-validate.sh
. "$PM_LIB_DIR/pm-validate.sh"
# shellcheck source=../lib/pm-glab-preconditions.sh
. "$PM_LIB_DIR/pm-glab-preconditions.sh"

usage() {
	cat <<EOF
Usage: $PROG --repo PATH (--title STR | --search QUERY) --confirmed-host HOST
             [-h|--help]

Read-only duplicate check: does an issue matching this title/query already
exist? Never creates or modifies anything.

Example:
  $PROG --repo group/subgroup/project --title "Export to CSV" \\
        --confirmed-host gitlab.com

Options:
  --repo PATH      Target project path (required; subgroups allowed).
  --confirmed-host HOST
                   The GitLab host the account gate already confirmed
                    (required; bare hostname, optional ':port', no scheme).
                    Pins glab to that instance.
  --title STR      Match issues whose title CONTAINS this text (a GitLab
                    search is tokenized/fuzzy, not exact; mutually exclusive
                    with --search).
  --search QUERY   A free-form query, also scoped to titles (mutually
                    exclusive with --title).
  -h, --help       Show this help.

Prints:
  PM_DUPLICATE_COUNT=<n>
  PM_DUPLICATE_URLS=<url[,url...]>

Exit codes:
  0  ran cleanly (count may be 0)
  1  glab/awk absent / not authenticated / query failed
  2  usage error
EOF
}

OPT_REPO=""
OPT_CONFIRMED_HOST=""
OPT_TITLE=""
OPT_SEARCH=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)    need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--confirmed-host) need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		--title)   need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--search)  need_arg "$1" "${2:-}"; OPT_SEARCH=$2; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

if [ -n "$OPT_TITLE" ] && [ -n "$OPT_SEARCH" ]; then
	usage >&2; error "--title and --search are mutually exclusive"; exit 2
fi
if [ -z "$OPT_TITLE" ] && [ -z "$OPT_SEARCH" ]; then
	usage >&2; error "one of --title or --search is required"; exit 2
fi

QUERY_TEXT=${OPT_TITLE:-$OPT_SEARCH}

[ -n "$OPT_CONFIRMED_HOST" ] || { usage >&2; error "--confirmed-host is required (the host procedure-gitlab-auth's account gate confirmed)"; exit 2; }
is_valid_confirmed_host "$OPT_CONFIRMED_HOST" || { usage >&2; error "--confirmed-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_CONFIRMED_HOST"; exit 2; }

# Pin glab's target instance to the CONFIRMED host. Exported so every `glab`
# child of THIS process inherits it; nothing outside this process is touched.
# This must happen before the auth precondition below, so even that check asks
# about the host the caller confirmed. See "HOST PINNING" in this file's header.
pm_pin_gitlab_host "$OPT_CONFIRMED_HOST"

# ---------------------------------------------------------------------------
# glab preconditions
# ---------------------------------------------------------------------------
require_glab_cli

require_awk "count and join results"

require_glab_auth

init_tmp_err pm-glab-find-duplicate

# `glab issue list`'s own default page size is only 30, and it has NO
# `--paginate` equivalent — so the bare call read just the first page and MISSED a
# real duplicate past the 30th match, reporting "no duplicate" for an issue that
# exists. A single larger page (the API's maximum) is the right fix here rather
# than the full page WALK create-issue.sh/ensure-labels.sh do for labels: this is
# a title-scoped search whose result set is a handful of matches, not a project's
# entire label inventory, and the count is advisory input to a human's
# duplicate decision, never a correctness gate.
SEARCH_PER_PAGE=100

if ! RAW=$(glab issue list --repo "$OPT_REPO" --search "$QUERY_TEXT" --in title --all \
	--per-page "$SEARCH_PER_PAGE" \
	--output json --jq '.[].web_url' 2>"$TMP_ERR"); then
	error "glab issue list failed"
	emit_captured_stderr
	exit 1
fi

# Normalize glab's --jq rows — the SAME helper (lib/pm-diag.sh) the label and
# milestone lookups use, so all three agree on what a quoted row means. See its
# own header for why only a SURROUNDING PAIR of quotes is stripped and never
# `gsub(/"/)`. A GitLab web_url cannot contain a quote, so the difference has no
# live effect HERE, but sharing the helper is what keeps that true of the next
# value someone routes through this line.
RESULT=$(pm_strip_jq_quotes "$RAW")

if [ -n "$RESULT" ]; then
	COUNT=$(count_lines "$RESULT")
	URLS=$(printf '%s\n' "$RESULT" | awk 'NR > 1 { printf "," } { printf "%s", $0 }')
else
	COUNT=0
	URLS=""
fi

# A count that lands EXACTLY on the page size means the page was filled, so there
# may be more matches this single-page query never saw — the count is a FLOOR, not
# a total. Say so, the same way the label lookups in this skill warn when they hit
# their own page cap; a caller that treats a truncated set as complete can decide
# "not a duplicate" on incomplete evidence.
if [ "$COUNT" -ge "$SEARCH_PER_PAGE" ]; then
	warn "result set hit the $SEARCH_PER_PAGE-match page limit — this count is a floor, not a total; narrow the query before treating it as complete"
fi

printf 'PM_DUPLICATE_COUNT=%s\n' "$COUNT"
printf 'PM_DUPLICATE_URLS=%s\n'  "$URLS"
exit 0
