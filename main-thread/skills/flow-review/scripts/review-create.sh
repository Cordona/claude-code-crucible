#!/usr/bin/env sh
#
# review-create.sh — create a NEW flow-review durable artifact (JSON) for one
#                     repo, at round 1. Refuses to overwrite an existing file.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §4c). The
# mkdir-lock dance capture.sh/process.sh need to protect a SHARED append-only
# log doesn't apply here. The only race this script actually guards is "does
# the target file already exist", checked explicitly, up front, before any
# directory or file is created — a loud failure, never a silent overwrite.
#
# WHY findings' status/tracked_status/first_seen are ALWAYS decided here,
# never trusted from the caller: round 1 findings are, by definition, brand
# new. Accepting a caller-supplied status/tracked_status/first_seen would let
# a fields-file silently fabricate history (e.g. claim a finding was already
# RESOLVED before round 1 ever ran). Every finding is reconstructed field by
# field from the validated input — never passed through verbatim — which
# also keeps additionalProperties:false honest regardless of what extra keys
# a caller's finding entry carried.
#
# WHY review artifacts get no chmod 600/700 (unlike the GTD inbox): the GTD
# log is a private, personal capture stream under $HOME; a review artifact is
# an ordinary versioned repo document meant to be read (and likely committed)
# like any other doc under .crucible/docs/ — treating it as a secret would be
# wrong, so only the default umask applies.
#
# Usage:
#   review-create.sh --repo-root PATH --slug SLUG --fields-file PATH [-h|--help]
#
#     --repo-root PATH    Repo root the artifact is written under, at
#                           {repo-root}/.crucible/docs/reviews/{YYYY}/{MM}/{DD}/{slug}.json
#                           (required; must exist).
#     --slug SLUG         The artifact id — must match artifact-slug.schema.json
#                           (lowercase, hyphen-separated). Becomes the
#                           filename (without extension) and the document's
#                           "id" (required).
#     --fields-file PATH  A JSON object describing round 1 (required):
#                           repo       (string, required)
#                           spec_ref   (string, optional)
#                           reviewers  (array of strings, required, non-empty
#                                        — round 1's dispatched reviewers)
#                           findings   (array, required, may be []) — each
#                                        entry gives id (^[A-Z]+-[0-9]{3,}$),
#                                        reviewer, severity, category,
#                                        locations (array), problem, fix.
#                                        Any status/tracked_status/first_seen/
#                                        addressed_in_round the caller
#                                        supplies is IGNORED — see WHY above.
#     -h, --help          Show this help.
#
# Output:
#   On success, stdout carries the machine-parseable key:
#     REVIEW_JSON=<absolute path>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  created
#   1  jq absent / mkdir or write failed / artifact already exists
#   2  usage error (missing/invalid argument, invalid --repo-root/--slug,
#      malformed or structurally invalid --fields-file)
#
# Env:
#   None — all paths are passed explicitly via flags.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (date, mktemp, mkdir, mv) are assumed present. Self-contained:
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
Usage: $PROG --repo-root PATH --slug SLUG --fields-file PATH [-h|--help]

Create a new flow-review durable artifact (round 1) for one repo. Refuses to
overwrite an existing artifact.

Options:
  --repo-root PATH    Repo root the artifact is written under (required).
  --slug SLUG         Artifact id; lowercase, hyphen-separated (required).
  --fields-file PATH  JSON object: repo, spec_ref (optional), reviewers
                        (non-empty array), findings (array, may be []).
  -h, --help          Show this help.

On success, prints:
  REVIEW_JSON=<absolute path>

Exit codes:
  0  created
  1  jq absent / write failed / artifact already exists
  2  usage error (invalid --repo-root/--slug, malformed --fields-file)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO_ROOT=""
OPT_SLUG=""
OPT_FIELDS_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo-root)   need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--slug)        need_arg "$1" "${2:-}"; OPT_SLUG=$2; shift ;;
		--fields-file) need_arg "$1" "${2:-}"; OPT_FIELDS_FILE=$2; shift ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		-*)            usage >&2; error "unknown option: $1"; exit 2 ;;
		*)             usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO_ROOT" ]   || { usage >&2; error "--repo-root is required"; exit 2; }
[ -n "$OPT_SLUG" ]        || { usage >&2; error "--slug is required"; exit 2; }
[ -n "$OPT_FIELDS_FILE" ] || { usage >&2; error "--fields-file is required"; exit 2; }

if [ ! -d "$OPT_REPO_ROOT" ]; then
	usage >&2
	error "--repo-root does not exist or is not a directory: $OPT_REPO_ROOT"
	exit 2
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
# --slug must match artifact-slug.schema.json's pattern. Travels via --arg,
# never concatenated into the program text.
# ---------------------------------------------------------------------------
if ! jq -n -e --arg s "$OPT_SLUG" '$s | test("^[a-z0-9]+(-[a-z0-9]+)*$")' >/dev/null 2>&1; then
	usage >&2
	error "invalid --slug: $OPT_SLUG (expected lowercase, hyphen-separated, e.g. service-api)"
	exit 2
fi

if ! jq -e . "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file is not valid JSON: $OPT_FIELDS_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Shared value-domain checks (duplicated verbatim in review-add-round.sh —
# each script is self-contained, no sourcing between siblings).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALUE_DEFS='
def is_severity: . as $v | ["CRITICAL","HIGH","MEDIUM","LOW"] | index($v) != null;
def is_nonempty_string: type == "string" and length > 0;
def is_finding_id: is_nonempty_string and test("^[A-Z]+-[0-9]{3,}$");
def is_nonempty_string_array: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
'

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE_FIELDS="$JQ_VALUE_DEFS"'
type == "object"
and (.repo != null and (.repo | is_nonempty_string))
and (.spec_ref == null or (.spec_ref | is_nonempty_string))
and (.reviewers != null and (.reviewers | is_nonempty_string_array))
and (.findings != null and (.findings | type == "array"))
and (.findings | all(.[];
      . as $e
      | ($e.id != null and ($e.id | is_finding_id))
      and ($e.reviewer != null and ($e.reviewer | is_nonempty_string))
      and ($e.severity != null and ($e.severity | is_severity))
      and ($e.category != null and ($e.category | is_nonempty_string))
      and ($e.locations != null and ($e.locations | is_nonempty_string_array))
      and ($e.problem != null and ($e.problem | is_nonempty_string))
      and ($e.fix != null and ($e.fix | is_nonempty_string))
    ))
'

if ! jq -e "$JQ_VALIDATE_FIELDS" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file failed validation (repo/reviewers/findings shape) — see $PROG --help"
	exit 2
fi

# ---------------------------------------------------------------------------
# created = last_updated = today's UTC date; ONE date call so every derived
# field (output path segments, round.generated, every finding's first_seen)
# agrees.
# ---------------------------------------------------------------------------
CREATED=$(date -u +%Y-%m-%d)
YEAR=${CREATED%%-*}
REST=${CREATED#*-}
MONTH=${REST%%-*}
DAY=${REST#*-}

ABS_REPO_ROOT=$(cd "$OPT_REPO_ROOT" && pwd) || {
	error "cannot resolve --repo-root: $OPT_REPO_ROOT"
	exit 1
}

OUTPUT_DIR="$ABS_REPO_ROOT/.crucible/docs/reviews/$YEAR/$MONTH/$DAY"
OUTPUT_FILE="$OUTPUT_DIR/$OPT_SLUG.json"

if [ -e "$OUTPUT_FILE" ]; then
	error "refusing to overwrite existing artifact: $OUTPUT_FILE"
	exit 1
fi

if ! mkdir -p "$OUTPUT_DIR"; then
	error "failed to create output directory: $OUTPUT_DIR"
	exit 1
fi

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
# Build the document. Every finding is constructed EXPLICITLY with only the
# schema-legal keys (see the top WHY block) and status/tracked_status/
# first_seen are always this script's own values, never the caller's.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_BUILD='
def finding($created):
  { id: .id,
    reviewer: .reviewer,
    status: "NEW",
    tracked_status: "PENDING",
    severity: .severity,
    category: .category,
    locations: .locations,
    first_seen: $created,
    problem: .problem,
    fix: .fix
  };
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
$fields_arr[0] as $doc
| ($doc.findings | map(finding($created))) as $findings
| summary($findings) as $sum
| { schema_version: "1.0", id: $slug, repo: $doc.repo }
  + (if ($doc.spec_ref != null) then { spec_ref: $doc.spec_ref } else {} end)
  + { created: $created,
      last_updated: $created,
      rounds: [ { round: 1, generated: $created, reviewers: $doc.reviewers } ],
      overall_verdict: verdict($sum),
      summary: $sum,
      findings: $findings
    }
'

TMP_FILE=$(mktemp "$OUTPUT_DIR/.tmp.$OPT_SLUG.XXXXXX")

if ! jq -n --arg slug "$OPT_SLUG" --arg created "$CREATED" --slurpfile fields_arr "$OPT_FIELDS_FILE" \
	"$JQ_BUILD" >"$TMP_FILE"; then
	error "failed to build the review artifact document"
	exit 1
fi

chmod 644 "$TMP_FILE"
mv "$TMP_FILE" "$OUTPUT_FILE"
TMP_FILE=""

printf 'REVIEW_JSON=%s\n' "$OUTPUT_FILE"
exit 0
