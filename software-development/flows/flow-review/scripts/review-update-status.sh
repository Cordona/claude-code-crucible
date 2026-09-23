#!/usr/bin/env sh
#
# review-update-status.sh — flip ONE finding's status/tracked_status/
#                            addressed_in_round on an existing flow-review
#                            durable artifact, then recompute summary/verdict
#                            fresh. Atomic same-directory rewrite.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §5c). See
# review-create.sh's header for the full rationale.
#
# WHY assert exactly one match before writing anything: a typo'd --id must
# be a loud failure, never a silent success or a silent multi-flip. This
# mirrors process.sh's exact discipline: the match count is computed first,
# under no lock (none needed here — see above), and the real file is never
# touched unless the count is exactly 1.
#
# Usage:
#   review-update-status.sh --json-file PATH --id FINDING_ID \
#       [--status VALUE] [--tracked-status VALUE] [--addressed-in-round N] \
#       [--clear-addressed-in-round] [-h|--help]
#
#     --json-file PATH        Existing review-artifact JSON file (required).
#     --id FINDING_ID          The finding's id (required). Exactly one
#                                finding must match, or nothing is written.
#     --status VALUE           New finding-status: NEW|OPEN|RESOLVED|
#                                REGRESSED|ACK.
#     --tracked-status VALUE   New tracked-status: PENDING|IN_PROGRESS|
#                                APPROVED|APPROVED_WITH_FOLLOWUPS.
#     --addressed-in-round N   Which round (integer >= 1) the fix was
#                                verified in. Must not exceed the newest
#                                round recorded on the artifact — a finding
#                                cannot be addressed in a round that never
#                                ran.
#     --clear-addressed-in-round
#                              REMOVE addressed_in_round from the matched
#                                finding (for a finding that regressed back
#                                into the workflow). Mutually exclusive with
#                                --addressed-in-round.
#     -h, --help               Show this help.
#
#   At least one of --status/--tracked-status/--addressed-in-round/
#   --clear-addressed-in-round is required. Only the given field(s) are
#   applied; everything else on the matched finding is left untouched.
#
#   EXCEPT: --tracked-status PENDING or IN_PROGRESS also clears
#   addressed_in_round, because review-artifact.schema.json requires that key
#   to be OMITTED (never null) in those two states — persisting it would
#   produce a schema-invalid finding. Passing an explicit
#   --addressed-in-round alongside either state is therefore contradictory
#   and rejected rather than silently discarded.
#
# Output:
#   On success, stdout carries two machine-parseable keys:
#     REVIEW_UPDATED=<id>
#     REVIEW_MD=<path>         the SIBLING Markdown render, which this script
#                                does NOT write — it is now STALE and must be
#                                re-rendered via render-md.sh.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  updated
#   1  jq absent / --json-file missing, unreadable, or not a review artifact /
#      not exactly one match / write failed
#   2  usage error (missing/invalid argument, no field given, contradictory
#      options, invalid or out-of-range --status/--tracked-status/
#      --addressed-in-round value)
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
Usage: $PROG --json-file PATH --id FINDING_ID [--status VALUE]
           [--tracked-status VALUE] [--addressed-in-round N]
           [--clear-addressed-in-round] [-h|--help]

Flip one finding's status/tracked_status/addressed_in_round on an existing
review artifact and recompute summary/verdict fresh. Requires EXACTLY one
match, and at least one field option.

Options:
  --json-file PATH        Existing review-artifact JSON file (required).
  --id FINDING_ID          The finding's id (required).
  --status VALUE           NEW|OPEN|RESOLVED|REGRESSED|ACK.
  --tracked-status VALUE   PENDING|IN_PROGRESS|APPROVED|APPROVED_WITH_FOLLOWUPS.
                             PENDING/IN_PROGRESS also clear
                             addressed_in_round (schema-required).
  --addressed-in-round N   Integer >= 1, no newer than the newest recorded
                             round.
  --clear-addressed-in-round
                           Remove addressed_in_round from the finding.
  -h, --help               Show this help.

On success, prints:
  REVIEW_UPDATED=<id>
  REVIEW_MD=<path>        the sibling render, now stale — re-run render-md.sh

Exit codes:
  0  updated
  1  jq absent / --json-file missing or invalid / not exactly one match / write failed
  2  usage error (no field given, contradictory options, invalid or
     out-of-range status/tracked-status/round value)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_JSON_FILE=""
OPT_ID=""
OPT_STATUS=""
OPT_TRACKED_STATUS=""
OPT_ADDRESSED_IN_ROUND=""
HAS_STATUS=false
HAS_TRACKED_STATUS=false
HAS_ADDRESSED_IN_ROUND=false
CLEAR_ADDRESSED_IN_ROUND=false

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)          need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--id)                 need_arg "$1" "${2:-}"; OPT_ID=$2; shift ;;
		--status)              need_arg "$1" "${2:-}"; OPT_STATUS=$2; HAS_STATUS=true; shift ;;
		--tracked-status)      need_arg "$1" "${2:-}"; OPT_TRACKED_STATUS=$2; HAS_TRACKED_STATUS=true; shift ;;
		--addressed-in-round)  need_arg "$1" "${2:-}"; OPT_ADDRESSED_IN_ROUND=$2; HAS_ADDRESSED_IN_ROUND=true; shift ;;
		--clear-addressed-in-round) CLEAR_ADDRESSED_IN_ROUND=true ;;
		-h|--help)             usage; exit 0 ;;
		--)                    shift; break ;;
		-*)                    usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                     usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_JSON_FILE" ] || { usage >&2; error "--json-file is required"; exit 2; }
[ -n "$OPT_ID" ]        || { usage >&2; error "--id is required"; exit 2; }

if [ "$HAS_STATUS" = false ] && [ "$HAS_TRACKED_STATUS" = false ] &&
	[ "$HAS_ADDRESSED_IN_ROUND" = false ] && [ "$CLEAR_ADDRESSED_IN_ROUND" = false ]; then
	usage >&2
	error "at least one of --status/--tracked-status/--addressed-in-round/--clear-addressed-in-round is required"
	exit 2
fi

if [ "$HAS_ADDRESSED_IN_ROUND" = true ] && [ "$CLEAR_ADDRESSED_IN_ROUND" = true ]; then
	usage >&2
	error "--addressed-in-round and --clear-addressed-in-round are mutually exclusive"
	exit 2
fi

if [ "$HAS_STATUS" = true ]; then
	case "$OPT_STATUS" in
		NEW|OPEN|RESOLVED|REGRESSED|ACK) : ;;
		*) usage >&2; error "invalid --status: $OPT_STATUS (expected NEW|OPEN|RESOLVED|REGRESSED|ACK)"; exit 2 ;;
	esac
fi

if [ "$HAS_TRACKED_STATUS" = true ]; then
	case "$OPT_TRACKED_STATUS" in
		PENDING|IN_PROGRESS|APPROVED|APPROVED_WITH_FOLLOWUPS) : ;;
		*) usage >&2; error "invalid --tracked-status: $OPT_TRACKED_STATUS (expected PENDING|IN_PROGRESS|APPROVED|APPROVED_WITH_FOLLOWUPS)"; exit 2 ;;
	esac

	# addressed_in_round must be OMITTED while the fix is PENDING or
	# IN_PROGRESS (review-artifact.schema.json), so moving into either state
	# clears it. A caller asserting both at once is contradicting itself —
	# reject rather than silently drop the value they supplied.
	case "$OPT_TRACKED_STATUS" in
		PENDING|IN_PROGRESS)
			if [ "$HAS_ADDRESSED_IN_ROUND" = true ]; then
				usage >&2
				error "--addressed-in-round cannot be combined with --tracked-status $OPT_TRACKED_STATUS (the schema requires addressed_in_round to be absent in that state)"
				exit 2
			fi
			CLEAR_ADDRESSED_IN_ROUND=true
			;;
	esac
fi

if [ "$HAS_ADDRESSED_IN_ROUND" = true ]; then
	case "$OPT_ADDRESSED_IN_ROUND" in
		''|*[!0-9]*|0*)
			usage >&2
			error "invalid --addressed-in-round: $OPT_ADDRESSED_IN_ROUND (expected an integer >= 1, no leading zeros)"
			exit 2
			;;
		*) : ;;
	esac
fi

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
	exit 1
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
# --json-file must already be a well-formed review artifact. Checked by TYPE,
# not merely for presence: a `findings` that is an object rather than an array
# would satisfy `!= null` and then break the `map` below. The rounds[] ENTRY
# assertion exists because the addressed_in_round bound below reads
# `[.rounds[].round] | max`: an entry with no (or a non-numeric) `.round`
# would make that max null or wrong and silently defeat the bound, so
# asserting it here is what lets the max be trusted with no `// 0` fallback.
# ---------------------------------------------------------------------------
if ! jq -e 'type == "object"
	and (.findings | type == "array")
	and (.rounds | type == "array") and ((.rounds | length) > 0)
	and (.rounds | all(.[]; .round | type == "number" and (floor == .) and . >= 1))
	and (.id | type == "string")' \
	"$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "not a valid review artifact JSON file: $OPT_JSON_FILE (expected an object with a string id, a findings[] array, and a non-empty rounds[] whose every entry carries an integer round >= 1)"
	exit 1
fi

# A finding cannot have been addressed in a round that never ran.
#
# The COMPARISON happens inside jq, never with shell `[ … -gt … ]`: --addressed-in-round
# is only validated as digits-with-no-leading-zero, so a 20-digit value reaches
# here, and POSIX `test` ERRORS on an operand that large — which the enclosing
# `if` then reads as a passed check, failing open. Asserted POSITIVELY ("must
# be affirmatively within the bound") so any answer other than jq's own literal
# `true` rejects rather than permits. MAX_ROUND is read separately for the
# diagnostic only; the DECISION is jq's.
if [ "$HAS_ADDRESSED_IN_ROUND" = true ]; then
	MAX_ROUND=$(jq -r '[.rounds[].round] | max' "$OPT_JSON_FILE") || {
		error "failed to read the newest recorded round number from $OPT_JSON_FILE"
		exit 1
	}
	ADDRESSED_ROUND_HAS_RUN=$(jq -r --argjson round "$OPT_ADDRESSED_IN_ROUND" \
		'$round <= ([.rounds[].round] | max)' "$OPT_JSON_FILE") || {
		error "failed to compare --addressed-in-round $OPT_ADDRESSED_IN_ROUND against the newest recorded round in $OPT_JSON_FILE"
		exit 1
	}
	if [ "$ADDRESSED_ROUND_HAS_RUN" != "true" ]; then
		usage >&2
		error "invalid --addressed-in-round: $OPT_ADDRESSED_IN_ROUND exceeds the newest recorded round ($MAX_ROUND) in $OPT_JSON_FILE"
		exit 2
	fi
fi

# Assert EXACTLY ONE match before anything is written — see the header's WHY
# block.
MATCH_COUNT=$(jq --arg id "$OPT_ID" '[.findings[] | select(.id == $id)] | length' "$OPT_JSON_FILE") || {
	error "failed to count findings with id '$OPT_ID' in $OPT_JSON_FILE"
	exit 1
}

if [ "$MATCH_COUNT" -ne 1 ]; then
	error "expected exactly one finding with id '$OPT_ID' in $OPT_JSON_FILE, found $MATCH_COUNT; no changes made"
	exit 1
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
# Apply only the given field(s) to the one matched finding, then recompute
# summary/overall_verdict fresh from the WHOLE post-flip findings[]. The
# has_* booleans gate which fields actually apply — same static-program/
# conditional-merge idiom capture.sh uses for its optional session_id. The
# clear step runs LAST so it wins over anything already on the finding.
# ---------------------------------------------------------------------------
JQ_AGGREGATES=$(cat "$REVIEW_AGGREGATES_JQ")

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_UPDATE="$JQ_AGGREGATES"'
.findings |= map(
    if .id == $id then
      . + (if $has_status then {status: $status} else {} end)
        + (if $has_tracked_status then {tracked_status: $tracked_status} else {} end)
        + (if $has_addressed_in_round then {addressed_in_round: $addressed_in_round} else {} end)
      | (if $clear_addressed_in_round then del(.addressed_in_round) else . end)
    else . end
  )
| .last_updated = $today
| (summary(.findings)) as $sum
| .summary = $sum
| .overall_verdict = verdict($sum)
'

TARGET_DIR=$(dirname "$OPT_JSON_FILE")
TMP_FILE=$(mktemp "$TARGET_DIR/.tmp.$(basename "$OPT_JSON_FILE").XXXXXX")

if ! jq --arg id "$OPT_ID" --arg today "$TODAY" \
	--argjson has_status "$HAS_STATUS" --arg status "$OPT_STATUS" \
	--argjson has_tracked_status "$HAS_TRACKED_STATUS" --arg tracked_status "$OPT_TRACKED_STATUS" \
	--argjson has_addressed_in_round "$HAS_ADDRESSED_IN_ROUND" --argjson addressed_in_round "${OPT_ADDRESSED_IN_ROUND:-0}" \
	--argjson clear_addressed_in_round "$CLEAR_ADDRESSED_IN_ROUND" \
	"$JQ_UPDATE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to apply the status update"
	exit 1
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
printf 'REVIEW_UPDATED=%s\n' "$OPT_ID"
printf 'REVIEW_MD=%s\n' "${OPT_JSON_FILE%.json}.md"
exit 0
