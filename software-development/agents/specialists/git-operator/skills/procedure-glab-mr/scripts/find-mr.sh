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
#                             is_valid_gitlab_project_path below.
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
#   Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays deterministic and this
# non-interactive script can never block on a prompt:
#   GLAB_NO_PROMPT        — glab must never ask this script anything.
#   GLAB_CHECK_UPDATE     — suppresses the "new version available" notice and
#                           the network round-trip that produces it.
#   GLAB_SHOW_WHATS_NEW   — suppresses the one-time post-upgrade banner.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

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

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_valid_gitlab_project_path VALUE — allow-list: letters, digits, '.', '_',
# '-' per segment, and ONE OR MORE '/'-separated segments, with no empty
# segment and no '.'/'..' path segment.
#
# WHY this is NOT procedure-gh-pr's is_valid_repo_slug: a GitHub slug is always
# exactly OWNER/REPO (that validator hard-rejects a second '/'), but GitLab
# supports nested groups, so a real project path can be
# "group/subgroup/project" or deeper. Rejecting the extra segments would make
# every subgroup project unreachable. A LONE segment with no '/' at all is still
# rejected: a bare project name is never a valid full path.
#
# VALUE is interpolated into `glab` arguments, so this rejects both disallowed
# characters and dot-segment path traversal (e.g. "g/..", "../p") before that
# ever happens.
is_valid_gitlab_project_path() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;   # character allow-list
		*//*) return 1 ;;                 # empty segment
		/*|*/) return 1 ;;                # leading / trailing slash
		..|../*|*/..|*/../*) return 1 ;;  # parent-dir traversal segment
		.|./*|*/.|*/./*) return 1 ;;      # current-dir segment
		*/*) return 0 ;;                  # at least one separator: accept
		*) return 1 ;;                    # a single bare segment: reject
	esac
}

# is_valid_confirmed_host VALUE — allow-list for the host the ACCOUNT GATE
# confirmed, before it becomes this process's GITLAB_HOST: letters, digits, '.',
# '-', '_' and an optional ':port'. Rejects whitespace, shell metacharacters, a
# leading '-', and any empty label. Spelled the way `glab auth status` reports a
# host — and the way manage_glab_accounts.sh's own is_valid_hostname accepts one
# — so the gate's answer can be passed straight through.
#
# A SCHEME-QUALIFIED value ("https://gitlab.com") is rejected on purpose: glab
# accepts both spellings, so allowing them here would let two different strings
# name one host, and the whole point of this flag is a single unambiguous target
# the caller and this script agree on.
is_valid_confirmed_host() {
	case "$1" in
		'') return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
		-*) return 1 ;;
		.*|*.|*..*) return 1 ;;
		*) return 0 ;;
	esac
}

# normalize_mr_rows VALUE — print the `glab mr list --jq` result as clean
# "iid<TAB>web_url" lines, dropping empties.
#
# Two normalizations, both no-ops for the expected output and both cheap
# insurance against glab's --jq string rendering differing from `gh`'s: a
# JSON-encoded "\t" is turned back into a real tab, and any double quotes glab
# may have kept around the rendered string are removed. Neither an iid nor a
# GitLab web_url can legitimately contain a quote, so the stripping cannot
# corrupt a good value. awk always exits 0, so this never trips `set -e`.
normalize_mr_rows() {
	printf '%s\n' "$1" | awk '
		{
			gsub(/\\t/, "\t")
			gsub(/"/, "")
			if ($0 != "") print
		}
	'
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
if ! command -v glab >/dev/null 2>&1; then
	error "GitLab CLI (glab) is not installed"
	warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
	exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required to count results)"
	exit 1
fi

# A bare `glab auth status` only checks the instance of the CURRENT CONTEXT, so
# a caller working on a self-managed project from an unrelated cwd could fail it
# spuriously; `--all` covers every configured instance. Try the bare form first
# (it is the cheapest and works on any glab), then --all. Only both failing means
# glab is genuinely not authenticated anywhere.
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-find-mr.err.XXXXXX")
# Make the path ABSOLUTE: mktemp echoes back the template it was given, so a
# RELATIVE $TMPDIR yields a relative path. This script never changes directory
# (only create-mr.sh does), so the normalization is defensive here — it is
# applied in all three MR scripts so the siblings cannot drift.
case $TMP_ERR in
	/*) ;;
	*) TMP_ERR="$PWD/$TMP_ERR" ;;
esac
# INT/TERM as well as EXIT: a Ctrl-C during a slow `glab mr list` would otherwise
# leak the temp file.
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

if ! RAW=$(glab mr list --repo "$OPT_REPO" --source-branch "$OPT_SOURCE_BRANCH" \
	--output json --jq '.[] | "\(.iid)\t\(.web_url)"' 2>"$TMP_ERR"); then
	error "glab mr list failed"
	sed 's/^/  /' "$TMP_ERR" >&2
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
