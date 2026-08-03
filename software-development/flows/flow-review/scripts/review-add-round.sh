#!/usr/bin/env sh
#
# review-add-round.sh — append a new review round onto an EXISTING flow-review
#                        durable artifact: merge in this round's findings
#                        (new + partial updates to existing ones), recompute
#                        summary/verdict fresh, atomic same-directory rewrite.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §4c). See
# review-create.sh's header for the full rationale (duplicated in spirit,
# not verbatim, since it's a one-line justification here too).
#
# WHY summary/overall_verdict are recomputed FRESH from the whole post-merge
# findings[] every time, never patched incrementally: an incremental patch
# can only drift further from the truth round over round; recomputing from
# scratch means the summary can never be wrong as long as findings[] is
# right.
#
# WHY a fields-file finding entry is resolved to "update" or "new" by looking
# it up by id in the artifact's CURRENT findings (not by any flag the caller
# sets): the caller already knows whether it's describing a finding that
# exists or one that doesn't — matching by id is the one mechanical, race-free
# way to make that same decision here, and it can never disagree with what's
# actually already on the document.
#
# Usage:
#   review-add-round.sh --json-file PATH --fields-file PATH [-h|--help]
#
#     --json-file PATH    Path to the existing review-artifact JSON file
#                            (required; must exist and be readable).
#     --fields-file PATH  A JSON object describing this round (required):
#                            round     (integer >= 1, required — must not
#                                        duplicate an existing rounds[].round)
#                            reviewers (array of strings, required,
#                                        non-empty — this round's dispatched
#                                        reviewers)
#                            findings  (array, required, may be []) — each
#                                        entry is EITHER a brand-new finding
#                                        (full shape: id matching
#                                        ^[A-Z]+-[0-9]{3,}$, reviewer,
#                                        tracked_status, severity, category,
#                                        locations, problem, fix — status
#                                        defaults "NEW" and first_seen
#                                        defaults to this round's date if
#                                        omitted) OR a partial update to an
#                                        EXISTING finding matched by id (only
#                                        the given keys are merged onto the
#                                        existing finding; its id and
#                                        first_seen are never touched — an
#                                        update can never change when a
#                                        finding was first seen, no matter
#                                        what value it supplies).
#     -h, --help          Show this help.
#
# Output:
#   On success, stdout carries the machine-parseable key:
#     REVIEW_JSON=<path>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  round appended
#   1  jq absent / --json-file missing, unreadable, or not a review artifact /
#      the round number already exists / write failed
#   2  usage error (missing/invalid argument, malformed or structurally
#      invalid --fields-file, an entry's shape invalid for its new/update
#      classification)
#
# Env:
#   None — all paths are passed explicitly via flags.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (date, mktemp, mv) are assumed present. Self-contained: sources
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
Usage: $PROG --json-file PATH --fields-file PATH [-h|--help]

Append a new round onto an existing flow-review durable artifact: merge in
this round's findings (new + partial updates to existing ones), recompute
summary/verdict fresh, atomic same-directory rewrite.

Options:
  --json-file PATH    Existing review-artifact JSON file (required).
  --fields-file PATH  JSON object: round (int, required, no duplicate),
                        reviewers (non-empty array), findings (array, may
                        be []; new-or-update entries, see -h for the shape).
  -h, --help          Show this help.

On success, prints:
  REVIEW_JSON=<path>

Exit codes:
  0  round appended
  1  jq absent / --json-file missing or invalid / duplicate round / write failed
  2  usage error (malformed --fields-file or a finding entry's shape)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_JSON_FILE=""
OPT_FIELDS_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)   need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--fields-file) need_arg "$1" "${2:-}"; OPT_FIELDS_FILE=$2; shift ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		-*)            usage >&2; error "unknown option: $1"; exit 2 ;;
		*)             usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_JSON_FILE" ]   || { usage >&2; error "--json-file is required"; exit 2; }
[ -n "$OPT_FIELDS_FILE" ] || { usage >&2; error "--fields-file is required"; exit 2; }

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
	exit 1
fi

if [ ! -f "$OPT_FIELDS_FILE" ] || [ ! -r "$OPT_FIELDS_FILE" ]; then
	usage >&2
	error "--fields-file does not exist or is not readable: $OPT_FIELDS_FILE"
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

# ---------------------------------------------------------------------------
# --json-file must already be a well-formed review artifact — a precondition
# on existing state, not a usage error about caller-supplied input.
# ---------------------------------------------------------------------------
if ! jq -e 'type == "object" and (.findings != null) and (.rounds != null) and (.id != null)' \
	"$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "not a valid review artifact JSON file: $OPT_JSON_FILE"
	exit 1
fi

if ! jq -e . "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file is not valid JSON: $OPT_FIELDS_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Shared value-domain checks (duplicated verbatim in review-create.sh — each
# script is self-contained, no sourcing between siblings).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALUE_DEFS='
def is_severity: . as $v | ["CRITICAL","HIGH","MEDIUM","LOW"] | index($v) != null;
def is_tracked_status: . as $v | ["PENDING","IN_PROGRESS","APPROVED","APPROVED_WITH_FOLLOWUPS"] | index($v) != null;
def is_finding_status: . as $v | ["NEW","OPEN","RESOLVED","REGRESSED","ACK"] | index($v) != null;
def is_nonempty_string: type == "string" and length > 0;
def is_finding_id: is_nonempty_string and test("^[A-Z]+-[0-9]{3,}$");
def is_nonempty_string_array: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
def is_addressed_in_round: type == "number" and (floor == .) and . >= 1;
def is_iso_date: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
'

# ---------------------------------------------------------------------------
# Basic fields-file shape: round/reviewers/findings.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE_SHAPE="$JQ_VALUE_DEFS"'
type == "object"
and (.round != null and (.round | type == "number") and ((.round | floor) == .round) and .round >= 1)
and (.reviewers != null and (.reviewers | is_nonempty_string_array))
and (.findings != null and (.findings | type == "array"))
'

if ! jq -e "$JQ_VALIDATE_SHAPE" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file failed validation (round/reviewers/findings shape) — see $PROG --help"
	exit 2
fi

ROUND=$(jq -r '.round' "$OPT_FIELDS_FILE")

if jq -e --argjson round "$ROUND" '(.rounds | map(.round) | index($round)) != null' "$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "round $ROUND already exists in $OPT_JSON_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# Per-entry validation: an entry is a NEW finding (full shape, only
# status/first_seen defaultable) or an UPDATE to an existing finding (id
# must match; any subset of the other fields, but each given value must be
# well-formed if present). Classification is by id membership in the
# artifact's CURRENT findings — never a caller-set flag.
# ---------------------------------------------------------------------------
EXISTING_IDS=$(jq -c '[.findings[].id]' "$OPT_JSON_FILE")

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE_ENTRIES="$JQ_VALUE_DEFS"'
# optional_ok: an update-branch field is well-formed if the KEY IS ABSENT
# ("not given" — left untouched by the merge) OR its value passes `ok`.
# Deliberately keyed on has($key), never on ($e[$key] == null): an entry
# that explicitly sets a key to null (e.g. "fix": null) still HAS that key,
# so it must still pass `ok` — otherwise an explicit null slips through
# validation and pick_known() merges the literal null onto the persisted
# finding.
def optional_ok($e; $key; ok):
  ($e | has($key) | not) or ($e[$key] | ok);

.findings | all(.[];
  . as $e
  | ($existing_ids | index($e.id)) as $match
  | if $match != null then
      # first_seen is deliberately NOT validated here: an update entry can
      # never change the first_seen already on an existing finding
      # (pick_known_update below excludes the key from the merge entirely),
      # so any value the caller supplies is inert and there is nothing to
      # validate.
      ($e.id != null and ($e.id | is_nonempty_string))
      and optional_ok($e; "status"; is_finding_status)
      and optional_ok($e; "tracked_status"; is_tracked_status)
      and optional_ok($e; "severity"; is_severity)
      and optional_ok($e; "locations"; is_nonempty_string_array)
      and optional_ok($e; "reviewer"; is_nonempty_string)
      and optional_ok($e; "category"; is_nonempty_string)
      and optional_ok($e; "problem"; is_nonempty_string)
      and optional_ok($e; "fix"; is_nonempty_string)
      and optional_ok($e; "addressed_in_round"; is_addressed_in_round)
    else
      ($e.id != null and ($e.id | is_finding_id))
      and ($e.reviewer != null and ($e.reviewer | is_nonempty_string))
      and ($e.tracked_status != null and ($e.tracked_status | is_tracked_status))
      and ($e.severity != null and ($e.severity | is_severity))
      and ($e.category != null and ($e.category | is_nonempty_string))
      and ($e.locations != null and ($e.locations | is_nonempty_string_array))
      and ($e.problem != null and ($e.problem | is_nonempty_string))
      and ($e.fix != null and ($e.fix | is_nonempty_string))
      and optional_ok($e; "status"; is_finding_status)
      and optional_ok($e; "first_seen"; is_iso_date)
      and optional_ok($e; "addressed_in_round"; is_addressed_in_round)
    end
)
'

if ! jq -e --argjson existing_ids "$EXISTING_IDS" "$JQ_VALIDATE_ENTRIES" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file has an invalid finding entry (see $PROG --help for the new-vs-update shape)"
	exit 2
fi

TODAY=$(date -u +%Y-%m-%d)

# ---------------------------------------------------------------------------
# Cleanup: remove the write-in-progress temp file on any exit path.
# ---------------------------------------------------------------------------
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$TMP_FILE" ] || rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# Merge + recompute, all in one static jq program. `pick_known_by_keys`
# restricts an entry to an explicit key allow-list so a caller's stray extra
# key can never leak into the artifact. Two distinct allow-lists, not one:
#
#   pick_known_new()    — a brand-new finding: first_seen IS a legal key
#                          (caller-settable, defaulted below if absent).
#   pick_known_update() — an update to an EXISTING finding: first_seen is
#                          EXCLUDED, full stop. first_seen is "frozen at
#                          creation" per contracts/review-artifact.schema.json
#                          — an update entry must never be able to overwrite
#                          it, regardless of what value it supplies. This
#                          mirrors review-create.sh's own precedent of never
#                          trusting a caller for a field that is fixed at a
#                          specific lifecycle point.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_MERGE='
def pick_known_by_keys($e; $keys):
  $e
  | to_entries
  | map(select(.key as $k | ($keys | index($k)) != null))
  | from_entries;
def pick_known_new($e):
  pick_known_by_keys($e;
    ["id","reviewer","status","tracked_status","severity","category","locations","first_seen","problem","fix","addressed_in_round"]);
def pick_known_update($e):
  pick_known_by_keys($e;
    ["id","reviewer","status","tracked_status","severity","category","locations","problem","fix","addressed_in_round"]);
def open_counts(findings):
  reduce (findings[] | select(.status == "NEW" or .status == "OPEN" or .status == "REGRESSED")) as $f
    ({critical:0, high:0, medium:0, low:0}; .[$f.severity | ascii_downcase] += 1);
def summary(findings):
  { open: open_counts(findings),
    resolved: ([findings[] | select(.status == "RESOLVED")] | length),
    new: ([findings[] | select(.status == "NEW")] | length),
    ack: ([findings[] | select(.status == "ACK")] | length)
  };
def verdict($s):
  if ($s.open.critical > 0 or $s.open.high > 0) then "CHANGES_REQUIRED"
  elif ($s.open.medium > 0 or $s.open.low > 0) then "APPROVED_WITH_FOLLOWUPS"
  else "APPROVED" end;
$fields_arr[0] as $fields
| (reduce $fields.findings[] as $e (
     .findings;
     if any(.[]; .id == $e.id)
     then map(if .id == $e.id then . + pick_known_update($e) else . end)
     else . + [ (pick_known_new($e)
                 | .status = (.status // "NEW")
                 | .first_seen = (.first_seen // $today)) ]
     end
   )) as $merged_findings
| .findings = $merged_findings
| .rounds += [ { round: $fields.round, generated: $today, reviewers: $fields.reviewers } ]
| .last_updated = $today
| (summary(.findings)) as $sum
| .summary = $sum
| .overall_verdict = verdict($sum)
'

TARGET_DIR=$(dirname "$OPT_JSON_FILE")
TMP_FILE=$(mktemp "$TARGET_DIR/.tmp.$(basename "$OPT_JSON_FILE").XXXXXX")

if ! jq --arg today "$TODAY" --slurpfile fields_arr "$OPT_FIELDS_FILE" \
	"$JQ_MERGE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to merge the new round into the review artifact"
	exit 1
fi

chmod 644 "$TMP_FILE"
mv "$TMP_FILE" "$OPT_JSON_FILE"
TMP_FILE=""

printf 'REVIEW_JSON=%s\n' "$OPT_JSON_FILE"
exit 0
