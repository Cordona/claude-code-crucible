#!/usr/bin/env sh
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
#   Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays parseable and this
# script can never block on a prompt.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

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

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_valid_gitlab_project_path VALUE — allow-list: letters, digits, '.', '_',
# '-' per segment, and ONE OR MORE '/'-separated segments, with no empty
# segment and no '.'/'..' path segment.
#
# WHY this is NOT procedure-gh-issues' is_valid_repo_slug: a GitHub slug is
# always exactly OWNER/REPO (that validator hard-rejects a second '/'), but
# GitLab supports nested groups, so a real project path can be
# "group/subgroup/project" or deeper. Rejecting the extra segments would make
# every subgroup project unreachable. A LONE segment with no '/' at all is
# still rejected: a bare project name is never a valid full path.
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
	error "awk is not installed (required to count and join results)"
	exit 1
fi

# The bare form checks only the current context's instance, so --all is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr).
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-glab-find-duplicate.err.XXXXXX")
# TWO traps, not one combined `EXIT INT TERM`: a Ctrl-C during a slow `glab`
# call would otherwise leak the temp file, but a combined handler would clean up
# and then RESUME the interrupted command's error path, which goes on to read the
# file it just unlinked. The INT/TERM handler therefore terminates the script
# itself (130 = SIGINT's conventional status). The EXIT trap still runs after it,
# and a second `rm -f` on an already-removed path is a no-op.
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

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
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# Normalize: strip a SURROUNDING PAIR of double quotes glab's --jq may apply to a
# string result and drop blank lines — byte-for-byte the same normalization
# create-issue.sh's list_all_labels and ensure-labels.sh apply to their own --jq
# rows. awk always exits 0, so this never trips `set -e` on a genuine result.
#
# A SURROUNDING PAIR only, never `gsub(/"/)`: that global form is the shape this
# skill's siblings were deliberately changed AWAY from, because it removed EVERY
# quote anywhere in the value and corrupted a legitimate one. A GitLab web_url
# cannot contain a quote, so the global form had no live defect HERE — but keeping
# it while claiming parity with those siblings was simply untrue, and the next
# reader copying this line into a value that CAN hold a quote would inherit the
# bug. Only the surrounding pair is glab's, so only the surrounding pair is
# removed — and only when BOTH ends carry one (`/^".*"$/` is checked FIRST):
# stripping the two ends independently would eat the closing quote of a value that
# ends with one without starting with one.
RESULT=$(printf '%s\n' "$RAW" | awk '{ if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") } if ($0 != "") print }')

if [ -n "$RESULT" ]; then
	# awk's END{print NR} counts RECORDS (lines), including a final line with no
	# trailing newline — unlike `wc -l`, which counts newline BYTES and so would
	# silently undercount if glab ever emitted an unterminated last line.
	COUNT=$(printf '%s\n' "$RESULT" | awk 'END { print NR }')
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
