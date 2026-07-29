#!/usr/bin/env sh
#
# review-update-status.sh — flip ONE finding's status/tracked_status/
#                            addressed_in_round on an existing flow-review
#                            durable artifact, then recompute summary/verdict
#                            fresh. Atomic same-directory rewrite.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §4c). See
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
#       [-h|--help]
#
#     --json-file PATH        Existing review-artifact JSON file (required).
#     --id FINDING_ID          The finding's id (required). Exactly one
#                                finding must match, or nothing is written.
#     --status VALUE           New finding-status: NEW|OPEN|RESOLVED|
#                                REGRESSED|ACK.
#     --tracked-status VALUE   New tracked-status: PENDING|IN_PROGRESS|
#                                APPROVED|APPROVED_WITH_FOLLOWUPS.
#     --addressed-in-round N   Which round (integer >= 1) the fix was
#                                verified in.
#     -h, --help               Show this help.
#
#   At least one of --status/--tracked-status/--addressed-in-round is
#   required. Only the given field(s) are applied; everything else on the
#   matched finding is left untouched.
#
# Output:
#   On success, stdout carries the machine-parseable key:
#     REVIEW_UPDATED=<id>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  updated
#   1  jq absent / --json-file missing, unreadable, or not a review artifact /
#      not exactly one match / write failed
#   2  usage error (missing/invalid argument, no field given, invalid
#      --status/--tracked-status/--addressed-in-round value)
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
Usage: $PROG --json-file PATH --id FINDING_ID [--status VALUE]
           [--tracked-status VALUE] [--addressed-in-round N] [-h|--help]

Flip one finding's status/tracked_status/addressed_in_round on an existing
review artifact and recompute summary/verdict fresh. Requires EXACTLY one
match, and at least one of --status/--tracked-status/--addressed-in-round.

Options:
  --json-file PATH        Existing review-artifact JSON file (required).
  --id FINDING_ID          The finding's id (required).
  --status VALUE           NEW|OPEN|RESOLVED|REGRESSED|ACK.
  --tracked-status VALUE   PENDING|IN_PROGRESS|APPROVED|APPROVED_WITH_FOLLOWUPS.
  --addressed-in-round N   Integer >= 1.
  -h, --help               Show this help.

On success, prints:
  REVIEW_UPDATED=<id>

Exit codes:
  0  updated
  1  jq absent / --json-file missing or invalid / not exactly one match / write failed
  2  usage error (no field given, invalid status/tracked-status/round value)
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

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)          need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--id)                 need_arg "$1" "${2:-}"; OPT_ID=$2; shift ;;
		--status)              need_arg "$1" "${2:-}"; OPT_STATUS=$2; HAS_STATUS=true; shift ;;
		--tracked-status)      need_arg "$1" "${2:-}"; OPT_TRACKED_STATUS=$2; HAS_TRACKED_STATUS=true; shift ;;
		--addressed-in-round)  need_arg "$1" "${2:-}"; OPT_ADDRESSED_IN_ROUND=$2; HAS_ADDRESSED_IN_ROUND=true; shift ;;
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

if [ "$HAS_STATUS" = false ] && [ "$HAS_TRACKED_STATUS" = false ] && [ "$HAS_ADDRESSED_IN_ROUND" = false ]; then
	usage >&2
	error "at least one of --status/--tracked-status/--addressed-in-round is required"
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

# ---------------------------------------------------------------------------
# --json-file must already be a well-formed review artifact.
# ---------------------------------------------------------------------------
if ! jq -e 'type == "object" and (.findings != null) and (.rounds != null) and (.id != null)' \
	"$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "not a valid review artifact JSON file: $OPT_JSON_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# Assert EXACTLY ONE match — computed before any temp file/write, mirroring
# process.sh's "expected exactly one … found N; no changes made" discipline.
# ---------------------------------------------------------------------------
MATCH_COUNT=$(jq --arg id "$OPT_ID" '[.findings[] | select(.id == $id)] | length' "$OPT_JSON_FILE")

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
# conditional-merge idiom capture.sh uses for its optional session_id.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_UPDATE='
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
.findings |= map(
    if .id == $id then
      . + (if $has_status then {status: $status} else {} end)
        + (if $has_tracked_status then {tracked_status: $tracked_status} else {} end)
        + (if $has_addressed_in_round then {addressed_in_round: $addressed_in_round} else {} end)
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
	"$JQ_UPDATE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to apply the status update"
	exit 1
fi

chmod 644 "$TMP_FILE"
mv "$TMP_FILE" "$OPT_JSON_FILE"
TMP_FILE=""

printf 'REVIEW_UPDATED=%s\n' "$OPT_ID"
exit 0
