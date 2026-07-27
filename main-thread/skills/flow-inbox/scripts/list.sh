#!/usr/bin/env sh
#
# list.sh — read-only, resilient listing of the GTD inbox log.
#
# WHY read-only needs no lock: process.sh/purge-processed.sh only ever
# replace the log via mktemp (same dir) + atomic `mv`, so a concurrent
# reader always sees either the whole old file or the whole new file, never
# a half-written one. list.sh never takes the shared writer lock.
#
# WHY resilient reads: a hand-edited or partially-written line must never
# abort the read (under `set -e`) or hide the rest of the log. Each line is
# parsed independently; a malformed line is warned about on stderr and
# skipped from the output — never counted as data, never fatal.
#
# Usage:
#   list.sh [--project NAME] [--session-id ID] [--active|--processed|--all]
#           [--format json|md] [-h|--help]
#   list.sh --id ID   [--format json|md]
#   list.sh --ids a,b,c [--format json|md]
#
#     --project NAME    Filter to entries whose "project" field equals NAME.
#     --session-id ID   Filter to entries whose "session_id" equals ID (the
#                       SAME flag name capture.sh records under, mirroring the
#                       --project record/filter parity). COMBINES with
#                       --project and the status flags (logical AND).
#     --active         Only entries with is_processed == false (DEFAULT).
#     --processed      Only entries with is_processed == true.
#     --all            No status filter.
#     --id ID          Look up the SINGLE entry whose "id" equals ID.
#                       Mutually exclusive with --ids/--project/--session-id/
#                       --active/--processed/--all (an id is globally unique,
#                       so a status/project/session filter is moot) — combining
#                       them is a usage error, not a silently-ignored one, so
#                       the caller never wonders which filter actually applied.
#     --ids a,b,c      Select every entry whose "id" is in the comma-separated
#                       set. A standalone selector with the SAME
#                       mutual-exclusion rule as --id. Returned in the CANONICAL
#                       order (see below) — NOT the order the ids were listed.
#     --format FMT     Output format: json (DEFAULT, unchanged for machine
#                       callers) or md. `md` pipes the resulting array through
#                       the sibling render-md.sh (--mode list) — the SOLE
#                       Markdown authority — and fails closed if it is missing.
#     -h, --help       Show this help.
#
# Output:
#   Default (--format json): a JSON array on stdout (one call, not
#   one-per-line): the matching entries in the CANONICAL order (project asc,
#   case-insensitive by display name, no-project last; then id asc — see the
#   sort block below), or `[]` when the log is absent,
#   empty, or has no match — this includes an `--id` lookup for an id that
#   doesn't exist: NOT FOUND is a successful empty result (exit 0), never a
#   usage error. With --format md the same result is rendered as Markdown by
#   render-md.sh (an empty result renders the no-items heading). Diagnostics
#   (including malformed-line warnings) go to stderr.
#
# Exit codes:
#   0  always, on a successful read (including the empty-result case)
#   1  jq absent / inbox file exists but is unreadable
#   2  usage error (bad/conflicting arguments)
#
# Env:
#   INBOX_FILE   Overrides the log path (default
#                $HOME/.claude/crucible/gtd/inbox.jsonl). Tests set this to a
#                temp path so no run ever touches the real log.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (date, mktemp, od/cksum, tr, awk, basename, dirname, mv,
#   chmod) are assumed present. Uses fractional `sleep 0.1` (GNU/BSD, not
#   strict POSIX) — fine on the macOS+Linux targets. Self-contained:
#   sources nothing.
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
Usage: $PROG [--project NAME] [--session-id ID] [--active|--processed|--all]
             [--format json|md] [-h|--help]
       $PROG --id ID [--format json|md]
       $PROG --ids a,b,c [--format json|md]

Read-only listing of the GTD inbox log. Prints a JSON array on stdout by
default; [] when the log is absent, empty, or nothing matches.

Options:
  --project NAME    Filter to entries whose "project" equals NAME.
  --session-id ID   Filter to entries whose "session_id" equals ID (combines
                    with --project/status).
  --active         Only is_processed == false (DEFAULT).
  --processed      Only is_processed == true.
  --all            No status filter.
  --id ID          Look up the single entry with this id. Mutually exclusive
                    with --ids/--project/--session-id/--active/--processed/--all.
  --ids a,b,c      Select the entries whose id is in the comma-separated set,
                    in the canonical order (project, then id). Same standalone
                    rule as --id.
  --format FMT     json (DEFAULT) or md (rendered via render-md.sh).
  -h, --help       Show this help.

Exit codes:
  0  read succeeded (including an empty result, and including an
     --id lookup that found nothing)
  1  jq absent / inbox file unreadable / render-md.sh missing (--format md)
  2  usage error (bad/conflicting arguments, or --id/--ids combined with a
     project/session/status filter)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_valid_json_object LINE — see capture.sh for the full rationale
# (duplicated verbatim; each script is self-contained, mirrors
# create-issue.sh — no sourcing between sibling scripts).
is_valid_json_object() {
	printf '%s' "$1" | jq -e -s 'length==1 and (.[0]|type)=="object"' >/dev/null 2>&1
}

# emit_result JSON_ARRAY — the single output sink, honoring --format. Default
# (json) prints the array verbatim (the unchanged machine-caller contract);
# md pipes it through the sibling render-md.sh (--mode list), which is the
# SOLE Markdown authority — list.sh never formats Markdown itself. Invoked via
# `sh "$RENDER_MD"` (not sourced), the same subprocess handoff jira.sh uses for
# md-to-adf.sh. Presence of render-md.sh is verified once, up front (see the
# format gate), so this never silently swallows a missing renderer.
#
# The heading label is $STATUS for a status/project/session listing, but a
# neutral "all" for the --id/--ids selectors: those ignore the status filter
# (STATUS is just its "active" default there), so labelling a processed entry
# "1 active item" would be wrong. The selectors span both statuses, so "all"
# is the only truthful heading.
emit_result() {
	if [ "$OPT_FORMAT" != "md" ]; then
		printf '%s\n' "$1"
		return 0
	fi
	render_label=$STATUS
	if [ "$OPT_ID_SET" -eq 1 ] || [ "$OPT_IDS_SET" -eq 1 ]; then
		render_label="all"
	fi
	printf '%s\n' "$1" | sh "$RENDER_MD" --mode list --status-label "$render_label"
}

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
INBOX_FILE=${INBOX_FILE:-"$HOME/.claude/crucible/gtd/inbox.jsonl"}

# SCRIPT_DIR/RENDER_MD — the Markdown renderer is a SIBLING script in this same
# scripts/ dir, consumed BY PATH as a subprocess (never sourced, never
# inlined), mirroring how procedure-jira's jira.sh invokes md-to-adf.sh.
# Resolved relative to $0's own location (not a bare "scripts/render-md.sh",
# which would resolve against the CALLER's cwd) — correct both when deployed
# under $HOME/.claude/skills/flow-inbox/scripts/ and under this repo's own
# tests/../scripts/ during test runs.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
RENDER_MD="$SCRIPT_DIR/render-md.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_PROJECT=""
OPT_PROJECT_SET=0
OPT_SESSION_ID=""
OPT_SESSION_ID_SET=0
OPT_ID=""
OPT_ID_SET=0
OPT_IDS=""
OPT_IDS_SET=0
OPT_FORMAT="json"
STATUS="active"
STATUS_FLAGS_SEEN=0

while [ $# -gt 0 ]; do
	case "$1" in
		--project)
			need_arg "$1" "${2:-}"
			OPT_PROJECT=$2
			OPT_PROJECT_SET=1
			shift ;;
		--session-id)
			need_arg "$1" "${2:-}"
			OPT_SESSION_ID=$2
			OPT_SESSION_ID_SET=1
			shift ;;
		--id)
			need_arg "$1" "${2:-}"
			OPT_ID=$2
			OPT_ID_SET=1
			shift ;;
		--ids)
			need_arg "$1" "${2:-}"
			OPT_IDS=$2
			OPT_IDS_SET=1
			shift ;;
		--format)
			need_arg "$1" "${2:-}"
			OPT_FORMAT=$2
			shift ;;
		--active)    STATUS="active";    STATUS_FLAGS_SEEN=$((STATUS_FLAGS_SEEN + 1)) ;;
		--processed) STATUS="processed"; STATUS_FLAGS_SEEN=$((STATUS_FLAGS_SEEN + 1)) ;;
		--all)       STATUS="all";       STATUS_FLAGS_SEEN=$((STATUS_FLAGS_SEEN + 1)) ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

case "$OPT_FORMAT" in
	json|md) : ;;
	*) usage >&2; error "invalid --format: $OPT_FORMAT (expected json|md)"; exit 2 ;;
esac

if [ "$STATUS_FLAGS_SEEN" -gt 1 ]; then
	usage >&2
	error "--active, --processed, and --all are mutually exclusive"
	exit 2
fi

# --id and --ids are the two STANDALONE selectors: an id (or a set of ids) is
# globally unique, so pairing either with a project/session/status filter — or
# with each other — is ambiguous about which selector actually applies. Reject
# the combination explicitly rather than silently ignoring one side
# (--session-id, by contrast, deliberately COMBINES with --project/status).
if [ "$OPT_ID_SET" -eq 1 ] && [ "$OPT_IDS_SET" -eq 1 ]; then
	usage >&2
	error "--id and --ids are mutually exclusive"
	exit 2
fi
if [ "$OPT_ID_SET" -eq 1 ] && { [ "$OPT_PROJECT_SET" -eq 1 ] || [ "$OPT_SESSION_ID_SET" -eq 1 ] || [ "$STATUS_FLAGS_SEEN" -gt 0 ]; }; then
	usage >&2
	error "--id is mutually exclusive with --ids/--project/--session-id/--active/--processed/--all"
	exit 2
fi
if [ "$OPT_IDS_SET" -eq 1 ] && { [ "$OPT_PROJECT_SET" -eq 1 ] || [ "$OPT_SESSION_ID_SET" -eq 1 ] || [ "$STATUS_FLAGS_SEEN" -gt 0 ]; }; then
	usage >&2
	error "--ids is mutually exclusive with --id/--project/--session-id/--active/--processed/--all"
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

# Format gate: with --format md, the sibling renderer MUST be present — fail
# closed (exit 1) with a clear diagnostic rather than emitting nothing or a
# raw shell error deep in emit_result.
if [ "$OPT_FORMAT" = "md" ] && { [ ! -f "$RENDER_MD" ] || [ ! -r "$RENDER_MD" ]; }; then
	error "internal: render-md.sh not found next to list.sh: $RENDER_MD"
	exit 1
fi

# ---------------------------------------------------------------------------
# Absent/empty file — clean, distinct no-op: print [] and exit 0.
# ---------------------------------------------------------------------------
if [ ! -f "$INBOX_FILE" ] || [ ! -s "$INBOX_FILE" ]; then
	emit_result '[]'
	exit 0
fi

if [ ! -r "$INBOX_FILE" ]; then
	error "cannot read inbox file (permission denied): $INBOX_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# Resilient read: classify every line independently. A malformed line is
# warned about and skipped — never fatal, never counted as data.
# ---------------------------------------------------------------------------
VALID_LINES=""
while IFS= read -r line || [ -n "$line" ]; do
	[ -n "$line" ] || continue
	if is_valid_json_object "$line"; then
		if [ -z "$VALID_LINES" ]; then VALID_LINES=$line
		else VALID_LINES="$VALID_LINES
$line"
		fi
	else
		warn "skipping malformed inbox line (not a well-formed JSON object)"
	fi
done <"$INBOX_FILE"

if [ -z "$VALID_LINES" ]; then
	emit_result '[]'
	exit 0
fi

# ---------------------------------------------------------------------------
# Canonical order — appended to EVERY result program below (default, --project,
# --session-id, status, --id, --ids), so the ONE array this run produces is the
# same whether it leaves as JSON (a machine caller) or is piped to render-md.sh
# as Markdown. That single order is what lets render-md.sh's 1..N ordinals and
# the parallel JSON never disagree — ordinal N always maps to json[N-1].
#
#   Primary key: project, ascending, case-insensitive by the sentence-cased
#     DISPLAY name (downcased, `-`/`_` → space — the same normalization
#     render-md.sh's sentence_case applies before capitalizing). Entries with
#     NO project field sort LAST — partitioned EXPLICITLY (named vs no-project),
#     never by relying on empty-string byte order.
#   Secondary key: id, ascending — ids are time-prefixed, so this is
#     chronological within a project.
#
# An entry is "named" ONLY when its project is a NON-EMPTY STRING. A missing,
# null, empty-string, OR non-string (e.g. hand-edited `"project":5`) project all
# fall to the no-project bucket — so a schema-violating-but-well-formed line
# survives the resilient read without aborting the sort, and project_key only
# ever sees a non-empty string.
#
# A STATIC jq program: the only values it reads are jq internals (.project,
# .id), so there is nothing tainted to splice into the program text. Under the
# exported LC_ALL=C jq sorts by Unicode codepoint, byte-identical on macOS+Linux.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: $named/$noproj are jq bindings, not shell vars
JQ_SORT='
| def is_named: (.project | type == "string" and . != "");
  def project_key: (.project | ascii_downcase | gsub("[-_]"; " "));
  (map(select(is_named)))        as $named
| (map(select(is_named | not)))  as $noproj
| ($named | sort_by(project_key, .id)) + ($noproj | sort_by(.id))
'

# ---------------------------------------------------------------------------
# Static jq filter program; every filter value travels via --arg/--argjson —
# never concatenated into the program text (closes the jq-program-injection
# sink a crafted --project/--session-id/--id/--ids value would otherwise open).
# --id and --ids are distinct, static, single-purpose programs — not folded
# into the project/session/status one — since they ignore those filters
# entirely (enforced above) and a match by id is all they ever select. Every
# branch then pipes its match set through $JQ_SORT (the canonical order above),
# so --ids returns the canonical order — NOT the log's order and NOT the order
# ids were listed on the command line.
#
# The result is captured, then handed to emit_result (which honors --format);
# an assignment via `$(…)` still aborts under `set -e` if jq fails.
# ---------------------------------------------------------------------------
if [ "$OPT_ID_SET" -eq 1 ]; then
	RESULT=$(printf '%s\n' "$VALID_LINES" | jq -c -s \
		--arg id "$OPT_ID" \
		'map(select(.id == $id))'"$JQ_SORT")
elif [ "$OPT_IDS_SET" -eq 1 ]; then
	# The comma-separated set is turned into a JSON array by jq itself (jq -R
	# reads the raw string), so it reaches the filter as an --argjson VALUE —
	# never spliced into the program text.
	IDS_JSON=$(printf '%s' "$OPT_IDS" | jq -R 'split(",")')
	RESULT=$(printf '%s\n' "$VALID_LINES" | jq -c -s \
		--argjson ids "$IDS_JSON" \
		'map(select(.id as $i | ($ids | index($i)) != null))'"$JQ_SORT")
else
	RESULT=$(printf '%s\n' "$VALID_LINES" | jq -c -s \
		--arg project "$OPT_PROJECT" \
		--arg has_project "$OPT_PROJECT_SET" \
		--arg session "$OPT_SESSION_ID" \
		--arg has_session "$OPT_SESSION_ID_SET" \
		--arg status "$STATUS" \
		'map(
			select(($has_project != "1") or (.project == $project))
			| select(($has_session != "1") or (.session_id == $session))
			| select(
				($status == "all")
				or ($status == "active" and .is_processed == false)
				or ($status == "processed" and .is_processed == true)
			)
		)'"$JQ_SORT")
fi

emit_result "$RESULT"
exit 0
