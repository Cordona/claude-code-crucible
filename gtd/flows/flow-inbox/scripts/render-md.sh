#!/usr/bin/env sh
#
# render-md.sh — the SOLE deterministic Markdown renderer for GTD inbox
#                entries. Reads inbox JSON on stdin, writes structured
#                Markdown on stdout. No mutation, no network, no lock — a pure
#                transform, byte-identical on macOS and Linux.
#
# WHY a dedicated renderer (not inline agent prose): the capture/triage/
# processed confirmations the human sees must be built from what is ACTUALLY
# on the log, rendered the same way every time — not re-phrased per turn by an
# LLM. Centralizing the two display transforms (timestamp + sentence-case
# project) and the three templates here means one authority, one place to fix
# a rendering bug, and a golden-file test that pins the exact bytes.
#
# WHY the captured `text`/`note`/`project` are safe here: every field reaches
# the output ONLY as a jq string value inside a STATIC jq program (never
# concatenated into the program text, never handed to a shell). A `text`
# containing $(...), backticks, `|`, or a leading `>` is emitted as inert
# blockquote body — it can neither execute nor alter the document structure.
# Proven by a dedicated inertness test.
#
# WHY the timestamp transform never shells out to `date`: `date -d` (GNU) and
# `date -j` (BSD) take incompatible flags, so a `date` subprocess would
# diverge across macOS/Linux. The transform is pure jq
# (fromdateiso8601 | gmtime | strftime) with a fixed-position string-slice
# fallback for an unparseable ts — both deterministic and platform-identical.
#
# Usage:
#   render-md.sh --mode list [--status-label active|processed|all] [-h|--help]
#   render-md.sh --mode captured [-h|--help]
#   render-md.sh --mode processed [-h|--help]
#
#     --mode MODE          Which template to render (required):
#                            list      — an array of records -> an inbox
#                                        listing with a per-item block each.
#                            captured  — one record -> a capture confirmation.
#                            processed — one record -> a processed
#                                        confirmation.
#     --status-label LABEL  (list only) The heading qualifier — active
#                            (DEFAULT), processed, or all. Ignored by the
#                            single-record modes.
#     -h, --help            Show this help.
#
# Input (stdin):
#   list             a JSON array (as `list.sh` emits) — `[]` renders the
#                    empty-inbox heading with no item blocks.
#   captured/processed
#                    one record: either a bare JSON object, or a one-element
#                    JSON array (as `list.sh --id ID` emits) — the first
#                    element is used.
#
# Output (stdout):
#   Deterministic Markdown, emitted as LIVE text (never fenced) with a single
#   trailing newline and no trailing blank lines. Diagnostics go to stderr.
#
# Exit codes:
#   0  rendered
#   1  jq absent / stdin is not valid JSON / wrong shape for the mode
#      (list needs an array; captured/processed need at least one record)
#   2  usage error (missing/invalid --mode or --status-label)
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (mktemp, rm, cat) are assumed present. Self-contained: sources
#   nothing.
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
Usage: $PROG --mode list [--status-label active|processed|all] [-h|--help]
       $PROG --mode captured [-h|--help]
       $PROG --mode processed [-h|--help]

The sole deterministic Markdown renderer for GTD inbox entries. Reads inbox
JSON on stdin, writes structured Markdown on stdout.

Options:
  --mode MODE           list | captured | processed (required).
  --status-label LABEL   (list only) heading qualifier: active (default),
                          processed, or all.
  -h, --help             Show this help.

Exit codes:
  0  rendered
  1  jq absent / stdin not valid JSON / wrong shape for the mode
  2  usage error (missing/invalid --mode or --status-label)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_MODE=""
OPT_STATUS_LABEL="active"

while [ $# -gt 0 ]; do
	case "$1" in
		--mode)          need_arg "$1" "${2:-}"; OPT_MODE=$2; shift ;;
		--status-label)  need_arg "$1" "${2:-}"; OPT_STATUS_LABEL=$2; shift ;;
		-h|--help)       usage; exit 0 ;;
		--)              shift; break ;;
		-*)              usage >&2; error "unknown option: $1"; exit 2 ;;
		*)               usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

case "$OPT_MODE" in
	list|captured|processed) : ;;
	'') usage >&2; error "--mode is required (list|captured|processed)"; exit 2 ;;
	*)  usage >&2; error "invalid --mode: $OPT_MODE (expected list|captured|processed)"; exit 2 ;;
esac

case "$OPT_STATUS_LABEL" in
	active|processed|all) : ;;
	*) usage >&2; error "invalid --status-label: $OPT_STATUS_LABEL (expected active|processed|all)"; exit 2 ;;
esac

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

# ---------------------------------------------------------------------------
# Slurp stdin to a temp file so the input can be validated before rendering
# and fed to jq from a stable path. mktemp (never a fixed name) + a cleanup
# trap on every exit path.
# ---------------------------------------------------------------------------
TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/render-md.XXXXXX")

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	ec=$?
	[ -z "$TMP_FILE" ] || rm -f "$TMP_FILE" 2>/dev/null || true
	exit "$ec"
}
trap cleanup EXIT INT TERM

cat >"$TMP_FILE"

if ! jq -e . "$TMP_FILE" >/dev/null 2>&1; then
	error "stdin is not valid JSON"
	exit 1
fi

# ---------------------------------------------------------------------------
# Shared jq prelude — the two display transforms defined ONCE, plus small
# helpers. Every value flows through as a jq VALUE; nothing is ever
# concatenated into the program text (that is what keeps untrusted text
# inert). Concatenated with a per-mode program below; jq itself sources
# nothing.
#
# ts_display: an ISO-8601 UTC instant -> "YYYY-MM-DD HH:MM UTC" (minute
#   precision). Parses via fromdateiso8601|gmtime|strftime when the stored ts
#   is well-formed (capture.sh writes `date -u +%Y-%m-%dT%H:%M:%SZ`); on a
#   parse error (a hand-edited/malformed ts) it falls back to a fixed-position
#   string slice — the catch branch references the bound $ts, NOT `.` (which
#   in a jq `catch` is the error, not the original value).
# sentence_case: `claude-code-foundry` -> `Claude code foundry` (downcase,
#   `-`/`_` -> space, capitalize first char). Acronyms are not special-cased.
# blockquote: prefixes each physical line with "> ". It trims exactly ONE
#   trailing newline first (rtrimstr) so a `text`/`note` that ends in "\n"
#   does not render a dangling "> " line after its last real line.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: $ts/$p/$r etc. below are jq syntax, not shell expansions
JQ_PRELUDE='
def ts_display($ts):
  (try ($ts | fromdateiso8601 | gmtime | strftime("%Y-%m-%d %H:%M UTC"))
   catch ($ts[0:10] + " " + $ts[11:16] + " UTC"));
def sentence_case($p):
  ($p | ascii_downcase | gsub("[-_]"; " ")) as $s
  | ($s[0:1] | ascii_upcase) + $s[1:];
def blockquote($t):
  ($t | rtrimstr("\n") | split("\n") | map("> " + .) | join("\n"));
def has_val($r; $k):
  ($r | has($k)) and ($r[$k] != null);
def record:
  if type == "array" then .[0] else . end;
'

# Per-mode programs. `list` consumes the whole array; `captured`/`processed`
# consume one record (bare object or first array element).
#
# `list` GROUPS BY PROJECT. Its input is the ALREADY-SORTED array list.sh
# emits (project asc, case-insensitive by display name, no-project last; then
# id asc) — render-md.sh never re-orders, it only groups the contiguous runs:
#   * A "### {Sentence-case project}" header is emitted whenever the project
#     changes between two consecutive items (same-project items are contiguous
#     BECAUSE the input is pre-sorted); an entry with no project field renders
#     under a literal "### (no project)" header (which the sort placed last).
#   * Ordinals are GLOBAL 1..N in the final grouped/sorted order (they do NOT
#     reset per group), rendered as bold "**{n}.**" — NOT a heading, so the
#     only "###" lines are the group headers.
#   * The per-item "- Project:" bullet is DROPPED here (it now lives in the
#     group header); "- Captured:" is always present, "- Session ID:" only when
#     the field is. This is the ONLY mode that groups — captured/processed keep
#     their single-record layout (and their "- Project:" bullet) untouched.
# shellcheck disable=SC2016  # single-quoted on purpose: $status_label/$r/$n etc. below are jq syntax, not shell expansions
JQ_LIST='
def bullets($r):
  ( ["- Captured: " + ts_display($r.ts)]
    + (if has_val($r; "session_id") then ["- Session ID: " + $r.session_id] else [] end)
  ) | join("\n");
def group_header($r):
  if ($r.project | type == "string" and . != "")
  then "### " + sentence_case($r.project)
  else "### (no project)" end;
def item($ord; $r):
  "**" + ($ord | tostring) + ".**\n"
  + blockquote($r.text) + "\n\n"
  + bullets($r);
(if $status_label == "active" then "active "
 elif $status_label == "processed" then "processed "
 else "" end) as $lw
| length as $n
| (if $n == 0 then "no " + $lw + "items"
   elif $n == 1 then "1 " + $lw + "item"
   else ($n | tostring) + " " + $lw + "items" end) as $count
| ("## Inbox — " + $count) as $heading
| if $n == 0 then $heading
  else
    . as $arr
    | ( [ range(0; $n) as $i
          | $arr[$i] as $r
          | group_header($r) as $hdr
          | (if $i == 0 or (group_header($arr[$i - 1]) != $hdr)
             then $hdr + "\n\n" else "" end)
            + item($i + 1; $r)
        ] | join("\n\n") ) as $body
    | $heading + "\n\n" + $body
  end
'

# shellcheck disable=SC2016  # single-quoted on purpose: $r/$bullets below are jq syntax, not shell expansions
JQ_CAPTURED='
record as $r
| ( ["- Captured: " + ts_display($r.ts)]
    + (if has_val($r; "project")    then ["- Project: " + sentence_case($r.project)] else [] end)
    + (if has_val($r; "session_id") then ["- Session ID: " + $r.session_id] else [] end)
  ) as $bullets
| "Captured to inbox.\n\n" + blockquote($r.text) + "\n\n" + ($bullets | join("\n"))
'

# shellcheck disable=SC2016  # single-quoted on purpose: $r/$bullets below are jq syntax, not shell expansions
JQ_PROCESSED='
record as $r
| ( ["- Captured: " + ts_display($r.ts)]
    + (if has_val($r; "processed_ts") then ["- Processed: " + ts_display($r.processed_ts)] else [] end)
    + (if has_val($r; "project")      then ["- Project: " + sentence_case($r.project)] else [] end)
    + (if has_val($r; "session_id")   then ["- Session ID: " + $r.session_id] else [] end)
    + (if has_val($r; "note")         then ["- Outcome: " + $r.note] else [] end)
  ) as $bullets
| "Processed inbox item.\n\n" + blockquote($r.text) + "\n\n" + ($bullets | join("\n"))
'

# ---------------------------------------------------------------------------
# Render. `list` requires an array; the single-record modes require at least
# one record (a bare object counts as one). Shape mismatches are a clean
# exit-1 diagnostic, never a raw jq abort.
# ---------------------------------------------------------------------------
case "$OPT_MODE" in
	list)
		if [ "$(jq -r 'type' "$TMP_FILE")" != "array" ]; then
			error "--mode list expects a JSON array on stdin"
			exit 1
		fi
		jq -r --arg status_label "$OPT_STATUS_LABEL" "$JQ_PRELUDE $JQ_LIST" "$TMP_FILE"
		;;
	captured|processed)
		# The record must be a JSON object, or a non-empty array whose first
		# element is an object — assert that BEFORE templating, so a scalar or
		# empty stdin fails with a clean exit 1 instead of letting `.ts`/`.text`
		# raw-abort jq with exit 5 (which the header promises never happens).
		REC_TYPE=$(jq -r 'if type == "array" then (if length >= 1 then (.[0] | type) else "empty" end) else type end' "$TMP_FILE")
		if [ "$REC_TYPE" != "object" ]; then
			error "--mode $OPT_MODE expects one record on stdin (a JSON object or a non-empty array of objects); got: $REC_TYPE"
			exit 1
		fi
		if [ "$OPT_MODE" = "captured" ]; then
			jq -r "$JQ_PRELUDE $JQ_CAPTURED" "$TMP_FILE"
		else
			jq -r "$JQ_PRELUDE $JQ_PROCESSED" "$TMP_FILE"
		fi
		;;
esac

exit 0
