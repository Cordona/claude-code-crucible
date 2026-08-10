#!/usr/bin/env sh
#
# find-mr.sh — READ-ONLY idempotency check before opening a merge request:
#              is there already an open MR for this source branch? Never
#              writes anything.
#
# Purpose:
#   Wraps `glab mr list --source-branch ...` so a caller (the git-operator, or
#   create-mr.sh's own pre-check) can check for an existing MR BEFORE opening a
#   new one, without hand-authoring the query.
#
#   NOTE on open-only filtering: `glab mr list` "Defaults to open merge
#   requests" (its own --help), so no state flag is passed. This differs from
#   `gh pr list`, which needs `--state open` spelled out. glab offers no
#   explicit "open" flag to be more emphatic with — only --all/--closed/--merged
#   to widen the set, none of which is used here.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any tracker operation, but that confirmation used to bind to NOTHING
#   here: this script let `glab` resolve the target instance from ambient state
#   (the cwd's git remotes, an inherited $GITLAB_HOST, glab's own config). On a
#   machine with two configured instances — the very case the gate exists to
#   disambiguate — the gate could confirm host A while this query silently ran
#   against host B, whenever the same --repo project path resolves on both.
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
#   find-mr.sh --repo PATH --source-branch BRANCH --confirmed-host HOST
#              [-h|--help]
#
#     --repo PATH             Target project path (required). GitLab paths may
#                             have MORE than two segments — see
#                             is_valid_gitlab_project_path in
#                             lib/glab-mr-common.sh.
#     --source-branch BRANCH  The source branch to check (required). GitLab's
#                             equivalent of a GitHub PR's "head".
#     --confirmed-host HOST   The GitLab host the account gate already CONFIRMED
#                             (required) — e.g. gitlab.com or a self-managed
#                             hostname, spelled the way `glab auth status`
#                             reports it (bare host, optional ':port', no
#                             scheme). See "HOST PINNING" above.
#     -h, --help              Show this help.
#
# Output:
#   PM_MR_COUNT=<n>          printed on exit 0 (a clean query, count may be 0).
#                            NOT printed on exit 1 (glab/awk/git absent,
#                            unauthenticated, or the query itself failed) — those
#                            paths return before any PM_* key is built.
#   PM_MR_NUMBER=<iid>       printed ONLY when exactly one open MR was found.
#   PM_MR_URL=<url>          printed ONLY when exactly one open MR was found.
#   Diagnostics go to stderr.
#
#   When the count is 2 or more, every matching "iid<TAB>web_url" row is listed
#   on stderr alongside the warning. GitLab genuinely allows several concurrent
#   open MRs from ONE source branch to DIFFERENT targets (a legitimate backport
#   pattern — unlike GitHub, which permits one open PR per head branch), so this
#   state is reachable in normal use and the caller needs the rows to pick an
#   iid, not just a bare count.
#
#   PM_MR_NUMBER is GitLab's **iid** — the per-project number a human sees in
#   `!123` and in the MR's URL — NOT the globally unique `id` field, which is
#   useless to a caller and is never emitted here.
#
# Exit codes:
#   0  query ran cleanly (count may be 0 — that is NOT a failure)
#   1  glab/awk absent / not authenticated / the glab query itself failed
#   2  usage error
#
# Portability: POSIX sh only (no bashisms). Read-only: never writes to the
#   tracker. Every external binary is guarded with `command -v`.
#
# Sources `lib/glab-mr-common.sh` + `lib/glab-mr-output.sh` from the sibling
#   lib/ directory (resolved from $0 by parameter expansion — see the preamble
#   below). The first holds diagnostics, glab's chattiness pins, argument
#   validators, `glab` preconditions and comma-list parsing; the second holds
#   the helpers that read glab's untrusted output. usage() and the `glab` argv
#   builder stay in THIS file. The libs are skill-local: nothing outside this
#   skill is ever sourced, so this skill still deploys and runs on its own.
#
set -eu

# Resolve the sibling lib/ from THIS script's own location, using only shell
# parameter expansion: `dirname`/`readlink`/`realpath`/`basename` are all
# deliberately absent from the test harness's isolated PATH toolbox, so any of
# them here would break the suite (and any minimal deployment) outright. The
# `*)` arm covers an invocation with no '/' at all (`sh find-mr.sh` from inside
# scripts/), where $0 is a bare name and the sibling lib is at ../lib.
case $0 in
	*/*) MR_LIB_DIR=${0%/*}/../lib ;;
	*)   MR_LIB_DIR=../lib ;;
esac
# GUARD THE SOURCES: a `.` on an unreadable file aborts with a raw `.: not found`
# that names neither this script nor the path it tried — worst of all via the
# `*)` bare-name arm above, which resolves against an arbitrary cwd. warn() and
# error() live in the lib and do not exist yet, so this is the ONE diagnostic in
# this file that formats itself; everything after this line uses the lib's.
# The loop variable is PREFIXED and unset immediately after: this script and the
# libs it sources share ONE flat POSIX namespace, so a bare, never-unset `lib`
# would silently collide with any same-named variable a lib introduces later.
# Same shape as the PM families' `_pm_lib`.
for _mr_lib in glab-mr-common.sh glab-mr-output.sh; do
	[ -r "$MR_LIB_DIR/$_mr_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_mr_lib" "$MR_LIB_DIR" >&2; exit 1; }
done
unset _mr_lib
# shellcheck source=SCRIPTDIR/../lib/glab-mr-common.sh
. "$MR_LIB_DIR/glab-mr-common.sh"
# normalize_mr_rows lives in the output lib — this script reads `glab mr list`'s
# rendered rows, so it needs that file even though it never parses an MR URL.
# shellcheck source=SCRIPTDIR/../lib/glab-mr-output.sh
. "$MR_LIB_DIR/glab-mr-output.sh"

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --source-branch BRANCH --confirmed-host HOST
             [-h|--help]

Read-only duplicate check: is there already an open MR for this source branch?
Never creates or modifies anything.

Example:
  $PROG --repo group/subgroup/project --source-branch feat/export \\
        --confirmed-host gitlab.com

Options:
  --repo PATH             Target project path (required). One or more
                          '/'-separated segments — GitLab subgroups are
                          supported (e.g. group/subgroup/project).
  --source-branch BRANCH  The source branch to check (required).
  --confirmed-host HOST   The GitLab host the account gate already confirmed
                          (required; bare hostname, optional ':port', no
                          scheme). Pins glab to that instance.
  -h, --help              Show this help.

Prints:
  PM_MR_COUNT=<n>
  PM_MR_NUMBER=<iid>   (only when count is exactly 1)
  PM_MR_URL=<url>      (only when count is exactly 1)

Exit codes:
  0  ran cleanly (count may be 0)
  1  glab/awk absent / not authenticated / query failed
  2  usage error
EOF
}

OPT_REPO=""
OPT_SOURCE_BRANCH=""
OPT_CONFIRMED_HOST=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)           need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--source-branch)  need_arg "$1" "${2:-}"; OPT_SOURCE_BRANCH=$2; shift ;;
		--confirmed-host) need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		-h|--help)       usage; exit 0 ;;
		--)              shift; break ;;
		-*)              usage >&2; error "unknown option: $1"; exit 2 ;;
		*)               usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_SOURCE_BRANCH" ] || { usage >&2; error "--source-branch is required"; exit 2; }

[ -n "$OPT_CONFIRMED_HOST" ] || { usage >&2; error "--confirmed-host is required (the host procedure-gitlab-auth's account gate confirmed)"; exit 2; }
is_valid_confirmed_host "$OPT_CONFIRMED_HOST" || { usage >&2; error "--confirmed-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_CONFIRMED_HOST"; exit 2; }

# Pin glab's target instance to the CONFIRMED host. Exported so every `glab`
# child of THIS process inherits it; nothing outside this process is touched.
# This must happen before the auth precondition below, so even that check asks
# about the host the caller confirmed. See "HOST PINNING" in this file's header.
GITLAB_HOST=$OPT_CONFIRMED_HOST
export GITLAB_HOST

# ---------------------------------------------------------------------------
# glab preconditions
# ---------------------------------------------------------------------------
require_glab

require_awk "required to count results"

require_glab_auth

init_tmp_err pm-find-mr

if ! RAW=$(glab mr list --repo "$OPT_REPO" --source-branch "$OPT_SOURCE_BRANCH" \
	--output json --jq '.[] | "\(.iid)\t\(.web_url)"' 2>"$TMP_ERR"); then
	error "glab mr list failed"
	emit_captured_stderr
	exit 1
fi

RESULT=$(normalize_mr_rows "$RAW")

if [ -n "$RESULT" ]; then
	# awk's END{print NR} counts RECORDS (lines), including a final line with
	# no trailing newline — unlike `wc -l`, which counts newline BYTES. It
	# also always exits 0, so it never trips `set -e` on a genuine result.
	COUNT=$(printf '%s\n' "$RESULT" | awk 'END { print NR }')
else
	COUNT=0
fi

printf 'PM_MR_COUNT=%s\n' "$COUNT"

if [ "$COUNT" -eq 1 ]; then
	printf '%s\n' "$RESULT" | awk -F'\t' '{ printf "PM_MR_NUMBER=%s\nPM_MR_URL=%s\n", $1, $2 }'
elif [ "$COUNT" -gt 1 ]; then
	# A bare PM_MR_COUNT=2 leaves the caller with nothing to act on, and this is
	# NOT a corner case on GitLab: several open MRs can share one source branch as
	# long as their TARGET branches differ (a backport fanning out to release
	# branches is the ordinary example), where GitHub allows only one open PR per
	# head branch. So every matching row is listed — the caller's next step is to
	# name one of these iids explicitly instead of relying on a single-match answer
	# this query cannot give.
	warn "$COUNT open MRs share source branch '$OPT_SOURCE_BRANCH' in project '$OPT_REPO'; PM_MR_NUMBER/PM_MR_URL are deliberately NOT emitted — pick one of these iids explicitly:"
	printf '%s\n' "$RESULT" | awk -F'\t' '{ printf "  !%s  %s\n", $1, $2 }' >&2
fi

exit 0
