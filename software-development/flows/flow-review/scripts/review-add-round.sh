#!/usr/bin/env sh
#
# review-add-round.sh — append a new review round onto an EXISTING flow-review
#                        durable artifact: merge in this round's findings
#                        (new + partial updates to existing ones), recompute
#                        summary/verdict fresh, atomic same-directory rewrite.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §5c). See
# review-create.sh's header for the full rationale.
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
# WHY every carried-over finding still marked NEW is flipped to OPEN before
# this round's updates are applied: `status: NEW` means "first reported THIS
# round" (review-artifact.schema.json / finding-status.schema.json). Once a
# further round exists, a finding from an earlier one is no longer new — left
# alone it would claim NEW forever and inflate summary.new. The flip happens
# BEFORE the caller's own entries merge on top, so an entry that deliberately
# re-asserts "status": "NEW" still wins.
#
# Usage:
#   review-add-round.sh --json-file PATH --fields-file PATH [-h|--help]
#
#     --json-file PATH    Path to the existing review-artifact JSON file
#                            (required; must exist and be readable).
#     --fields-file PATH  A JSON object describing this round (required; the
#                            file must hold EXACTLY ONE JSON document):
#                            round     (integer >= 1, required — must be
#                                        strictly GREATER than the newest
#                                        recorded rounds[].round, so history
#                                        can only ever grow forward)
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
#                                        An addressed_in_round on any entry
#                                        must not exceed this round's number.
#                                        An entry may carry only the finding
#                                        fields named here (any other key is
#                                        rejected), and each id may appear in
#                                        at most one entry.
#     -h, --help          Show this help.
#
# Output:
#   On success, stdout carries two machine-parseable keys:
#     REVIEW_JSON=<path>
#     REVIEW_MD=<path>     the SIBLING Markdown render, which this script does
#                            NOT write — it is now STALE and must be
#                            re-rendered via render-md.sh.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  round appended
#   1  jq absent / --json-file missing, unreadable, or not a review artifact /
#      the round number already exists or is not newer than the newest
#      recorded round / write failed
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
#   coreutils (basename, cat, chmod, date, dirname, mktemp, mv, rm) are
#   assumed present. Reads its verdict arithmetic from
#   lib/review-aggregates.jq, resolved relative to this script (see the
#   REVIEW_LIB_DIR preamble below); depends on nothing else outside this
#   scripts/ directory.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# Locate the shared jq library RELATIVE TO THIS SCRIPT with parameter
# expansion alone: `${0%/*}` costs no subprocess and needs neither
# `readlink -f` nor `realpath` (non-POSIX, and absent from the test harness's
# minimal PATH toolbox). A symlinked $0 is consequently NOT resolved — the
# library must sit beside the path this script was invoked as. The `*)` branch
# is unreachable in practice (SKILL.md and the harness always invoke by
# absolute path) but exists so `set -u` can never see an unset REVIEW_LIB_DIR.
case "$0" in
	*/*) REVIEW_LIB_DIR=${0%/*}/lib ;;
	*)   REVIEW_LIB_DIR=lib ;;
esac
REVIEW_AGGREGATES_JQ=$REVIEW_LIB_DIR/review-aggregates.jq

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
  --fields-file PATH  One JSON object (exactly one document), all required:
                        round      integer >= 1, newer than every
                                   recorded round
                        reviewers  non-empty array of non-empty strings
                        findings   array of entries (shape below), may
                                   be []
  -h, --help          Show this help.

Findings entries:
  Each entry is classified by its id. An id NOT yet in the artifact's
  findings makes the entry NEW; an id already there makes it an UPDATE.
  An update-shaped entry whose id is not yet in the artifact is therefore
  NEW and must carry the full NEW shape. Each id may appear in at most
  one entry per fields file.

  NEW     required: id (uppercase letters, a hyphen, 3+ digits, e.g.
          SEC-001), reviewer, tracked_status, severity, category,
          locations (non-empty array of non-empty strings), problem, fix.
          optional: status (default NEW), first_seen (YYYY-MM-DD,
          default today in UTC), addressed_in_round.
  UPDATE  required: id. Any subset of the other fields, each well-formed
          if given. first_seen is ignored.

  An entry may carry only the fields named here; any other key (e.g. a
  misspelled field name) is rejected.

  reviewer, category, problem and fix are non-empty strings. A field set
  to an explicit null counts as given and is rejected, except an UPDATE's
  first_seen, which is ignored whatever its value.
    severity            CRITICAL | HIGH | MEDIUM | LOW
    tracked_status      PENDING | IN_PROGRESS | APPROVED |
                        APPROVED_WITH_FOLLOWUPS
    status              NEW | OPEN | RESOLVED | REGRESSED | ACK
    addressed_in_round  integer from 1 to this round's number; omit it
                        when the same entry sets tracked_status to
                        PENDING or IN_PROGRESS

  Merge semantics (NEW-to-OPEN carry-over, summary and verdict recompute)
  are described in the header comment at the top of $PROG.

On success, prints:
  REVIEW_JSON=<path>
  REVIEW_MD=<path>    the sibling render, now stale — re-run render-md.sh

Exit codes:
  0  round appended
  1  jq absent / --json-file missing or invalid / duplicate or out-of-order
     round / write failed
  2  usage error (malformed --fields-file or a finding entry's shape)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# report_fields_file_rejection HEADLINE JQ_ARG... — explain a --fields-file a
# validation predicate has ALREADY rejected, by running the given diagnostic
# jq program over it. The detail is best-effort: if that pass fails or prints
# nothing, HEADLINE alone is printed, so a rejection is never silent.
report_fields_file_rejection() {
	rejection_headline=$1
	shift
	if rejection_details=$(jq -r "$@" "$OPT_FIELDS_FILE" 2>/dev/null) \
		&& [ -n "$rejection_details" ]; then
		error "$rejection_headline:"
		printf '%s\n' "$rejection_details" >&2
	else
		error "$rejection_headline"
	fi
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

if [ ! -r "$REVIEW_AGGREGATES_JQ" ]; then
	error "cannot read the shared jq library: $REVIEW_AGGREGATES_JQ (invoke this script by its absolute path)"
	exit 1
fi

# ---------------------------------------------------------------------------
# --json-file must already be a well-formed review artifact — a precondition
# on existing state, not a usage error about caller-supplied input. Checked by
# TYPE, not merely for presence: a `findings` that is an object rather than an
# array would satisfy `!= null` and then break every `map`/`reduce` below.
#
# Two of these assertions exist because a guard further down is VACUOUS
# without them, so they belong here rather than at their point of use:
#
#   rounds[] ENTRY types — the monotonicity check below reads
#     `[.rounds[].round] | max`. An entry with no (or a non-numeric) `.round`
#     makes that max null or wrong, silently defeating the check; asserting
#     every entry carries an integer round >= 1 is what lets the max be
#     trusted with no `// 0` fallback papering over it.
#   findings[] id UNIQUENESS — review-create.sh refuses duplicate ids at
#     creation, but this script MUTATES an artifact it did not create (a
#     hand-edited one, or one written by an older build). `upsert_finding`
#     below merges by id via `map(if .id == $e.id …)`, so a duplicate would
#     apply one caller entry to BOTH copies. review-update-status.sh already
#     refuses this case via its exactly-one-match assertion; this matches it.
# ---------------------------------------------------------------------------
if ! jq -e 'type == "object"
	and (.findings | type == "array")
	and ((.findings | map(.id) | unique | length) == (.findings | length))
	and (.rounds | type == "array") and ((.rounds | length) > 0)
	and (.rounds | all(.[]; .round | type == "number" and (floor == .) and . >= 1))
	and (.id | type == "string")' \
	"$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "not a valid review artifact JSON file: $OPT_JSON_FILE (expected an object with a string id, a non-empty rounds[] whose every entry carries an integer round >= 1, and a findings[] array with no duplicate ids)"
	exit 1
fi

if ! jq -e . "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file is not valid JSON: $OPT_FIELDS_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Reject a MULTI-DOCUMENT --fields-file before validating anything about its
# contents. `jq -e FILTER file` reports the exit status of the LAST value it
# produced, while the merge below reads the FIRST document (via --slurpfile +
# $fields_arr[0]) — so a file holding {invalid}{valid} would pass validation
# on the second document and then be MERGED from the first, unvalidated one.
# Asserting exactly one document closes that gap for every check that follows.
# ---------------------------------------------------------------------------
if ! jq -s -e 'length == 1' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file must hold exactly ONE JSON document: $OPT_FIELDS_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Value-domain checks. review-create.sh carries a SUBSET of these (round 1
# has no status/tracked_status/date fields to check); only the verdict
# arithmetic is genuinely shared, via lib/review-aggregates.jq.
#
# The id/date patterns are anchored with \A…\z, not ^…$: jq's Oniguruma
# treats `$` as end-of-line, so `^…$` would accept a finding id with a
# trailing newline — which then reaches the merged document.
#
# The enum checks require a STRING before testing membership: jq's
# `index($v)` treats an ARRAY $v as a subsequence to search for, so without
# the type guard ["HIGH"] would pass as a severity and persist as an array.
# ---------------------------------------------------------------------------
# field_keys is the ONE list of keys a findings entry may carry. The per-entry
# validator rejects any other key and the merge's pick_known_* allow-lists are
# derived from it, so both read this single definition and cannot drift.
JQ_FIELD_KEYS_DEF='
def field_keys:
  ["id","reviewer","status","tracked_status","severity","category","locations","first_seen","problem","fix","addressed_in_round"];
'

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALUE_DEFS="$JQ_FIELD_KEYS_DEF"'
def severity_values: ["CRITICAL","HIGH","MEDIUM","LOW"];
def tracked_status_values: ["PENDING","IN_PROGRESS","APPROVED","APPROVED_WITH_FOLLOWUPS"];
def finding_status_values: ["NEW","OPEN","RESOLVED","REGRESSED","ACK"];
def is_severity: type == "string" and (. as $v | severity_values | index($v) != null);
def is_tracked_status: type == "string" and (. as $v | tracked_status_values | index($v) != null);
def is_finding_status: type == "string" and (. as $v | finding_status_values | index($v) != null);
def is_nonempty_string: type == "string" and length > 0;
def is_finding_id: is_nonempty_string and test("\\A[A-Z]+-[0-9]{3,}\\z");
def is_nonempty_string_array: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
def is_addressed_in_round: type == "number" and (floor == .) and . >= 1;
def is_iso_date: type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z");
'

# ---------------------------------------------------------------------------
# Rejection explainers, used ONLY after a validation predicate below has
# already said no. They describe a rejection; they never make one.
#
# `shown` is the one way a caller-supplied value reaches a message: tojson
# quotes it and escapes C0 controls and DEL, and the C1 range (U+0080-U+009F,
# which includes the 8-bit CSI terminal escape) is escaped on top because
# tojson leaves it raw. Long strings are cut so one value cannot flood stderr.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_EXPLAIN_DEFS='
def hex2: "0123456789abcdef" as $h | (. / 16 | floor) as $hi | (. % 16) as $lo
  | $h[$hi:$hi + 1] + $h[$lo:$lo + 1];
def escape_c1: [explode[] | if . >= 128 and . < 160 then ("\\u00" + hex2 | explode[]) else . end] | implode;
def shown:
  if type == "string" then
    (if length > 80 then (.[:80] | tojson | escape_c1) + " (truncated)" else tojson | escape_c1 end)
  elif type == "array" then (if length == 0 then "an empty array" else "a JSON array" end)
  elif type == "object" then "a JSON object"
  else tojson end;
def got: " (got \(shown))";
def presence_problem($object; $key):
  if ($object | has($key)) | not then "missing required field \"\($key)\""
  else "\($key) is null (an explicit null is rejected)" end;
def string_array_problems($key):
  if type != "array" or length == 0 then "\($key) must be a non-empty array of non-empty strings\(got)"
  else to_entries[] | select(.value | is_nonempty_string | not)
    | "\($key)[\(.key)] must be a non-empty string (got \(.value | shown))"
  end;
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

# One line per failing conjunct of JQ_VALIDATE_SHAPE, each mirroring it.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_SHAPE="$JQ_VALUE_DEFS$JQ_EXPLAIN_DEFS"'
if type != "object" then "the top level must be a JSON object\(got)"
else
  . as $fields
  | (if .round == null then presence_problem($fields; "round")
     elif (.round | type == "number" and floor == . and . >= 1) | not
       then "round must be an integer >= 1 (got \(.round | shown))"
     else empty end),
    (if .reviewers == null then presence_problem($fields; "reviewers")
     else .reviewers | select(is_nonempty_string_array | not) | string_array_problems("reviewers") end),
    (if .findings == null then presence_problem($fields; "findings")
     elif (.findings | type) != "array" then "findings must be an array, may be [] (got \(.findings | shown))"
     else empty end)
end
| "  " + .
'

if ! jq -e "$JQ_VALIDATE_SHAPE" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	report_fields_file_rejection \
		"--fields-file failed validation (round/reviewers/findings shape) — see $PROG --help" \
		"$JQ_DIAGNOSE_SHAPE"
	exit 2
fi

ROUND=$(jq -r '.round' "$OPT_FIELDS_FILE") || {
	error "failed to read the round number from --fields-file: $OPT_FIELDS_FILE"
	exit 1
}

# ---------------------------------------------------------------------------
# Round history may only grow FORWARD: no duplicate, and nothing older than
# what is already recorded (appending round 2 after round 7 would make
# rounds[] disagree with its own documented ordering, and any
# addressed_in_round pointing at the newest round would then outrun it).
#
# Both checks CAPTURE jq's answer into a variable and branch on the value.
# `if jq -e …; then error; fi` would be fail-OPEN: a jq failure (bad argument,
# non-array .rounds, runtime error) is indistinguishable from "not a
# duplicate", and the script would append anyway. Capturing makes a jq failure
# a reported failure instead.
#
# Both COMPARISONS also happen inside jq, never with shell `[ … -le … ]`: a
# round number that clears the schema (1e30, a 20-digit integer) is not
# guaranteed to fit a machine int, and POSIX `test` ERRORS on such an operand
# — which the enclosing `if` then reads as a passed check, failing open. jq
# compares JSON numbers natively. MAX_ROUND is read separately for the
# diagnostic only; the DECISION is jq's.
# ---------------------------------------------------------------------------
ROUND_IS_DUPLICATE=$(jq -r --argjson round "$ROUND" '([.rounds[].round] | index($round)) != null' "$OPT_JSON_FILE") || {
	error "failed to read the recorded round numbers from $OPT_JSON_FILE"
	exit 1
}

if [ "$ROUND_IS_DUPLICATE" = "true" ]; then
	error "round $ROUND already exists in $OPT_JSON_FILE"
	exit 1
fi

# The precondition above proved rounds[] non-empty with an integer round on
# every entry, so this max is always a number — no `// 0` fallback, which
# would have turned an unreadable max into a silently permissive 0.
MAX_ROUND=$(jq -r '[.rounds[].round] | max' "$OPT_JSON_FILE") || {
	error "failed to read the newest recorded round number from $OPT_JSON_FILE"
	exit 1
}

# Asserted POSITIVELY ("must be affirmatively newer") so any answer other
# than jq's own literal `true` — including one this script did not anticipate
# — stops the append rather than permitting it.
ROUND_IS_NEWER=$(jq -r --argjson round "$ROUND" '$round > ([.rounds[].round] | max)' "$OPT_JSON_FILE") || {
	error "failed to compare round $ROUND against the newest recorded round in $OPT_JSON_FILE"
	exit 1
}

if [ "$ROUND_IS_NEWER" != "true" ]; then
	error "round $ROUND is not newer than the newest recorded round ($MAX_ROUND) in $OPT_JSON_FILE; rounds must be appended in ascending order"
	exit 1
fi

# ---------------------------------------------------------------------------
# One entry per finding per round: a string id may appear in at most one
# findings entry, NEW or UPDATE alike — the same rule review-create.sh
# enforces. Classification below looks an id up only in the artifact's
# CURRENT findings, so two entries sharing a not-yet-recorded id would BOTH
# pass as NEW and the merge would then apply the second onto the first (a HIGH
# finding silently replaced by a LOW one); two UPDATEs to one id would apply
# in order, the last silently winning.
#
# A cross-entry rule, so it cannot live in the per-entry predicate below,
# which judges each entry alone. It runs FIRST because a repeated id makes the
# per-entry classification of the later entries wrong, so their diagnostics
# would mislead. Non-string ids are left to the per-entry check.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_STRING_ID_DEFS='
def string_id_entries:
  [.findings | to_entries[]
   | select((.value | type) == "object" and (.value.id | type) == "string")
   | {index: .key, id: .value.id}];
'

JQ_VALIDATE_UNIQUE_IDS="$JQ_STRING_ID_DEFS"'
string_id_entries | map(.id) | (unique | length) == length
'

# One line per repeated id, naming every entry that carries it.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_DUPLICATE_IDS="$JQ_VALUE_DEFS$JQ_EXPLAIN_DEFS$JQ_STRING_ID_DEFS"'
string_id_entries
| group_by(.id)[]
| select(length > 1)
| (map(.index) | sort | map("findings[\(.)]")) as $refs
| "  \($refs[:-1] | join(", ")) and \($refs[-1]) share id \(.[0].id | shown) — each id may appear at most once per fields file"
'

if ! jq -e "$JQ_VALIDATE_UNIQUE_IDS" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	report_fields_file_rejection \
		"--fields-file repeats a finding id — one entry per finding per round (see $PROG --help)" \
		"$JQ_DIAGNOSE_DUPLICATE_IDS"
	exit 2
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
JQ_ENTRY_DEFS='
# optional_ok: an update-branch field is well-formed if the KEY IS ABSENT
# ("not given" — left untouched by the merge) OR its value passes `ok`.
# Deliberately keyed on has($key), never on ($e[$key] == null): an entry
# that explicitly sets a key to null (e.g. "fix": null) still HAS that key,
# so it must still pass `ok` — otherwise an explicit null slips through
# validation and pick_known() merges the literal null onto the persisted
# finding.
def optional_ok($e; $key; ok):
  ($e | has($key) | not) or ($e[$key] | ok);

# An entry is an UPDATE only when its id is a STRING already in the artifact.
# The type guard matters because `index` treats an ARRAY id as a subsequence
# to search for, so ["SEC-001"] would otherwise be "found".
def is_update_entry($e):
  ($e.id | type == "string") and ($existing_ids | index($e.id)) != null;

# Keys outside field_keys, in the order the entry lists them. The merge would strip
# them, so a misspelled key ("Status", "tracked-status") would turn the
# intended change into a silent no-op reported as success. A non-object entry
# has none; the NEW/UPDATE branches already reject it.
def unknown_keys($e):
  if ($e | type) == "object" then ($e | keys_unsorted) - field_keys else [] end;

# An addressed_in_round may cite THIS round (the fix was verified by the
# round being appended right now) but never a round that has not run — the
# bound is $round, which the monotonicity check above already proved to be
# the newest round in existence.
def is_round_that_has_run: is_addressed_in_round and . <= $round;

# addressed_in_round must be OMITTED while tracked_status is PENDING or
# IN_PROGRESS (review-artifact.schema.json). A caller asserting both at once
# in the SAME entry is contradicting itself — reject rather than silently
# drop the value they supplied, mirroring the reject-both-set behavior
# review-update-status.sh already has for the identical combination.
def contradicts_addressed_in_round($e):
  ($e.tracked_status // null) as $ts
  | ($ts == "PENDING" or $ts == "IN_PROGRESS") and ($e | has("addressed_in_round"));
'

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE_ENTRIES="$JQ_VALUE_DEFS$JQ_ENTRY_DEFS"'
.findings | all(.[];
  . as $e
  | if is_update_entry($e) then
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
      and optional_ok($e; "addressed_in_round"; is_round_that_has_run)
      and (contradicts_addressed_in_round($e) | not)
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
      and optional_ok($e; "addressed_in_round"; is_round_that_has_run)
      and (contradicts_addressed_in_round($e) | not)
    end
  and (unknown_keys($e) == [])
)
'

# Which entries to report is decided by re-running JQ_VALIDATE_ENTRIES itself
# on each entry alone (exact: the predicate is an all() over entries), so
# every rejected entry is named and no accepted one is. The field checks
# below only supply the reasons; an entry they cannot explain still gets a
# line.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_ENTRIES="$JQ_VALUE_DEFS$JQ_ENTRY_DEFS$JQ_EXPLAIN_DEFS"'
def entry_passes: {findings: [.]} | (
'"$JQ_VALIDATE_ENTRIES"'
);

def field_ok($key; $is_update):
  if $key == "id" then (if $is_update then is_nonempty_string else is_finding_id end)
  elif $key == "severity" then is_severity
  elif $key == "tracked_status" then is_tracked_status
  elif $key == "status" then is_finding_status
  elif $key == "locations" then is_nonempty_string_array
  elif $key == "first_seen" then is_iso_date
  elif $key == "addressed_in_round" then is_round_that_has_run
  else is_nonempty_string end;

def not_one_of($key; $allowed): "\($key) \(shown) is not one of \($allowed | join(" | "))";

def addressed_in_round_problem:
  if (type == "number" and floor == .) | not then "addressed_in_round must be an integer\(got)"
  elif . < 1 then "addressed_in_round \(.) is below the minimum of 1"
  else "addressed_in_round \(.) is above the maximum of \($round) (the round being appended)" end;

def field_problem($key; $is_update):
  if $key == "id" and $is_update then "id must be a non-empty string\(got)"
  elif $key == "id" then "id \(shown) does not match the id format (uppercase letters, a hyphen, 3+ digits, e.g. SEC-001)"
  elif $key == "severity" then not_one_of($key; severity_values)
  elif $key == "tracked_status" then not_one_of($key; tracked_status_values)
  elif $key == "status" then not_one_of($key; finding_status_values)
  elif $key == "locations" then string_array_problems($key)
  elif $key == "first_seen" then "first_seen must be a YYYY-MM-DD date string\(got)"
  elif $key == "addressed_in_round" then addressed_in_round_problem
  else "\($key) must be a non-empty string\(got)" end;

# Mirrors the NEW / UPDATE branches of JQ_VALIDATE_ENTRIES: NEW requires the
# first eight keys; UPDATE requires only id and ignores first_seen.
def entry_problems($e; $is_update):
  (unknown_keys($e)[] | "unknown field \(shown) (known fields: \(field_keys | join(", ")))"),
  (["id","reviewer","tracked_status","severity","category","locations","problem","fix",
    "status","first_seen","addressed_in_round"][] as $key
   | select(($is_update and $key == "first_seen") | not)
   | (if $is_update then $key == "id"
      else (["status","first_seen","addressed_in_round"] | index($key)) == null end) as $required
   | if $e[$key] == null then
       (if $required or ($e | has($key)) then presence_problem($e; $key) else empty end)
     else $e[$key] | select(field_ok($key; $is_update) | not) | field_problem($key; $is_update)
     end),
  (select(contradicts_addressed_in_round($e))
   | "addressed_in_round must be omitted while tracked_status is \($e.tracked_status | shown)");

def classification($e; $is_update):
  if ($e | has("id")) | not then "NEW (no id given)"
  elif ($e.id | type) != "string" then "NEW (id is not a string)"
  elif $is_update then "UPDATE (id already in artifact)"
  else "NEW (id not in artifact)" end;

.findings
| to_entries[]
| .key as $index
| .value as $e
| select((try ($e | entry_passes) catch false) | not)
| if ($e | type) != "object" then "findings[\($index)] is not a JSON object (got \($e | shown))"
  else
    is_update_entry($e) as $is_update
    | (if $e | has("id") then "id \($e.id | shown)" else "(no id)" end) as $label
    | [entry_problems($e; $is_update)] as $problems
    | (if $problems == [] then ["failed validation (no specific reason identified)"] else $problems end)[]
    | "findings[\($index)] \($label) — \(classification($e; $is_update)): \(.)"
  end
| "  " + .
'

if ! jq -e --argjson existing_ids "$EXISTING_IDS" --argjson round "$ROUND" \
	"$JQ_VALIDATE_ENTRIES" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	report_fields_file_rejection \
		"--fields-file has an invalid finding entry (see $PROG --help for the new-vs-update shape)" \
		--argjson existing_ids "$EXISTING_IDS" --argjson round "$ROUND" "$JQ_DIAGNOSE_ENTRIES"
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
# restricts an entry to an explicit key allow-list — defense in depth behind
# the validator's unknown-key rejection, so a stray key can never leak into
# the artifact. Two allow-lists, both DERIVED from the shared `field_keys`
# (JQ_FIELD_KEYS_DEF, also read by the validator) so a future schema field can
# never be added to one and silently stripped by the other:
#
#   pick_known_new()    — a brand-new finding: first_seen IS a legal key
#                          (caller-settable, defaulted below if absent).
#   pick_known_update() — an update to an EXISTING finding: field_keys MINUS
#                          first_seen, full stop. first_seen is "frozen at
#                          creation" per software-development/contracts/review-artifact.schema.json
#                          — an update entry must never be able to overwrite
#                          it, regardless of what value it supplies. This
#                          mirrors review-create.sh's own precedent of never
#                          trusting a caller for a field that is fixed at a
#                          specific lifecycle point.
# ---------------------------------------------------------------------------
JQ_AGGREGATES=$(cat "$REVIEW_AGGREGATES_JQ")

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_MERGE="$JQ_AGGREGATES$JQ_FIELD_KEYS_DEF"'
def pick_known_by_keys($e; $keys):
  $e
  | to_entries
  | map(select(.key as $k | ($keys | index($k)) != null))
  | from_entries;
def pick_known_new($e):
  pick_known_by_keys($e; field_keys);
def pick_known_update($e):
  pick_known_by_keys($e; field_keys - ["first_seen"]);

# Input: the findings array. Output: that array with $e either merged onto the
# finding sharing its id, or appended as a brand-new finding.
def upsert_finding($e):
  (if any(.[]; .id == $e.id)
   then map(if .id == $e.id then . + pick_known_update($e) else . end)
   else . + [ (pick_known_new($e)
               | .status = (.status // "NEW")
               | .first_seen = (.first_seen // $today)) ]
   end)
  # addressed_in_round must be OMITTED while tracked_status is PENDING or
  # IN_PROGRESS (review-artifact.schema.json). The validation above rejects
  # an entry that sets both explicitly in the SAME call; this normalizes the
  # other route to the same invalid state — an update that moves
  # tracked_status to PENDING/IN_PROGRESS without touching addressed_in_round,
  # leaving a stale value from an earlier round sitting alongside it.
  | map(if (.tracked_status // null) as $ts | ($ts == "PENDING" or $ts == "IN_PROGRESS")
        then del(.addressed_in_round)
        else . end);

# A finding carried over from an earlier round is no longer "first reported
# this round" — see the header WHY block on the NEW -> OPEN flip.
def carried_over: if .status == "NEW" then .status = "OPEN" else . end;
$fields_arr[0] as $fields
| (reduce $fields.findings[] as $e
     ((.findings | map(carried_over)); upsert_finding($e))
  ) as $merged_findings
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

# Advisory-only, never fatal: warn when an entry explicitly supplied
# addressed_in_round but upsert_finding's post-merge normalization (above)
# silently cleared it because that finding's resulting tracked_status is
# PENDING/IN_PROGRESS. The SAME-call combination is rejected loudly by the
# validation above; this is the OTHER route to the same invalid state — the
# finding was already PENDING/IN_PROGRESS before this call, so the caller's
# freshly-supplied value is discarded rather than rejected. The artifact
# stays schema-valid either way; this just tells the caller their value
# didn't stick.
DROPPED_ADDRESSED_IDS=$(jq -nr --slurpfile fields_arr "$OPT_FIELDS_FILE" --slurpfile merged "$TMP_FILE" '
  ($fields_arr[0].findings // []) as $entries
  | ($merged[0].findings // []) as $mf
  | [$entries[] | select(has("addressed_in_round")) | .id] as $claimed
  | [$mf[] | select(has("addressed_in_round") | not) | .id] as $missing
  | (($claimed - ($claimed - $missing)) | unique)[]
') || DROPPED_ADDRESSED_IDS=""

if [ -n "$DROPPED_ADDRESSED_IDS" ]; then
	printf '%s\n' "$DROPPED_ADDRESSED_IDS" | while IFS= read -r dropped_id; do
		[ -n "$dropped_id" ] || continue
		warn "addressed_in_round supplied for $dropped_id was dropped — tracked_status is PENDING/IN_PROGRESS on that finding (review-artifact.schema.json forbids the combination)"
	done
fi

# 0666 masked by the caller's own umask — never a forced 644, which would
# silently widen a deliberately-restrictive umask (see review-create.sh's
# header WHY block for why a review artifact is not treated as a secret).
FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$(umask) ))")

if ! chmod "$FILE_MODE" "$TMP_FILE"; then
	error "failed to set mode $FILE_MODE on the staged artifact: $TMP_FILE"
	exit 1
fi

if ! mv "$TMP_FILE" "$OPT_JSON_FILE"; then
	error "failed to publish the updated artifact to: $OPT_JSON_FILE"
	exit 1
fi
TMP_FILE=""

# The sibling render is now stale: this script writes JSON only. Naming the
# path is what stops a caller from forgetting to re-render it.
printf 'REVIEW_JSON=%s\n' "$OPT_JSON_FILE"
printf 'REVIEW_MD=%s\n' "${OPT_JSON_FILE%.json}.md"
exit 0
