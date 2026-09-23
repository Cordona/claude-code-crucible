#!/usr/bin/env sh
#
# review-create.sh — create a NEW flow-review durable artifact (JSON) for one
#                     repo, at round 1. Refuses to overwrite an existing file.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §5c). The
# mkdir-lock dance capture.sh/process.sh need to protect a SHARED append-only
# log doesn't apply here. The only race this script actually guards is "does
# the target file already exist", and it guards it ATOMICALLY rather than by
# check-then-act: the early `[ -e ]` test is a fast, friendly diagnostic, but
# the authority is the O_EXCL claim on the destination (`set -C` noclobber)
# taken immediately before the publish. A concurrent creator that loses that
# claim gets a loud failure, never a silent overwrite.
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
# wrong. The published mode is therefore 0666 masked by the CALLER'S OWN
# umask (0644 under the usual 022, tighter under a tighter umask) — never a
# forced 644, which would silently widen a deliberately-restrictive umask.
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
#                                        Finding ids must be unique.
#                           The file must hold EXACTLY ONE JSON document.
#     -h, --help          Show this help.
#
# Output:
#   On success, stdout carries the machine-parseable key:
#     REVIEW_JSON=<absolute path>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  created
#   1  jq absent / mkdir or write failed / artifact already exists /
#      the output directory escapes --repo-root
#   2  usage error (missing/invalid argument, invalid --repo-root/--slug,
#      malformed or structurally invalid --fields-file)
#
# Env:
#   None — all paths are passed explicitly via flags.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (cat, chmod, date, mkdir, mktemp, mv, rm) are assumed present.
#   Reads its verdict arithmetic from lib/review-aggregates.jq, resolved
#   relative to this script (see the REVIEW_LIB_DIR preamble below); depends
#   on nothing else outside this scripts/ directory.
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

if [ ! -r "$REVIEW_AGGREGATES_JQ" ]; then
	error "cannot read the shared jq library: $REVIEW_AGGREGATES_JQ (invoke this script by its absolute path)"
	exit 1
fi

# ---------------------------------------------------------------------------
# --slug must match artifact-slug.schema.json's pattern. Travels via --arg,
# never concatenated into the program text. Anchored with \A…\z, not ^…$:
# jq's Oniguruma treats `$` as end-of-line, so `^…$` would accept a slug with
# a trailing newline — which then reaches a filename and the document's id.
# ---------------------------------------------------------------------------
if ! jq -n -e --arg s "$OPT_SLUG" '$s | test("\\A[a-z0-9]+(-[a-z0-9]+)*\\z")' >/dev/null 2>&1; then
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
# Reject a MULTI-DOCUMENT --fields-file before validating anything about its
# contents. `jq -e FILTER file` reports the exit status of the LAST value it
# produced, while the build step below reads the FIRST document (via
# --slurpfile + $fields_arr[0]) — so a file holding {invalid}{valid} would
# pass validation on the second document and then be BUILT from the first,
# unvalidated one. Asserting exactly one document closes that gap at the
# source, for every check that follows.
# ---------------------------------------------------------------------------
if ! jq -s -e 'length == 1' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file must hold exactly ONE JSON document: $OPT_FIELDS_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Value-domain checks — a SUBSET of review-add-round.sh's own defs (round 1
# has no status/tracked_status/date fields to check, since this script decides
# all three itself). Only the verdict arithmetic is shared between the
# siblings, via lib/review-aggregates.jq.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALUE_DEFS='
def is_severity: . as $v | ["CRITICAL","HIGH","MEDIUM","LOW"] | index($v) != null;
def is_nonempty_string: type == "string" and length > 0;
def is_finding_id: is_nonempty_string and test("\\A[A-Z]+-[0-9]{3,}\\z");
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
# Finding ids must be unique. A duplicate id persisted here is not a cosmetic
# problem: every sibling script keys on the id, so review-update-status.sh
# would refuse the finding outright ("not exactly one match") and
# review-add-round.sh would apply one update entry to both copies.
# ---------------------------------------------------------------------------
if ! jq -e '(.findings | map(.id) | unique | length) == (.findings | length)' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file has duplicate finding ids in findings[] — each id must appear at most once"
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

# A fast, friendly diagnostic only — NOT the exclusion guarantee. The
# authority is the atomic O_EXCL claim taken just before the publish below.
if [ -e "$OUTPUT_FILE" ]; then
	error "refusing to overwrite existing artifact: $OUTPUT_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# Containment, in TWO phases around the mkdir. `mkdir -p` follows a symlinked
# path component silently, so a repo that ships .crucible (or any segment
# under it) as a symlink could redirect this write — and the directory
# CREATION itself — anywhere on the filesystem.
#
#   Phase 1, BEFORE mkdir: resolve the deepest ancestor of the output
#     directory that ALREADY exists (the only part of the path whose physical
#     location can be known before anything is created) and refuse if it lies
#     outside the repo root. A refusal here leaves nothing behind, which is
#     the whole point: a post-mkdir check alone would already have created
#     directories at the redirected location by the time it fired.
#   Phase 2, AFTER mkdir: re-resolve the now-existing output directory and
#     refuse again. Phase 1 can only judge what existed when it ran, so this
#     is the check that is authoritative about the path actually written to
#     (including a component created, or swapped for a symlink, in between).
#
# Only the CHECKS use physical paths — the write itself stays on the logical
# path the caller asked for, so the reported REVIEW_JSON= path is the one they
# can find again.
# ---------------------------------------------------------------------------

# Echoes the deepest ancestor of $2 that already exists, walking down from the
# root $1 one path segment at a time. Segments are derived from $2 rather than
# hardcoded, so the .crucible/docs/reviews/… layout is defined in exactly one
# place (OUTPUT_DIR, above).
deepest_existing_ancestor() {
	_ancestor=$1
	_remaining=${2#"$1"/}
	while [ -n "$_remaining" ]; do
		_segment=${_remaining%%/*}
		[ -d "$_ancestor/$_segment" ] || break
		_ancestor=$_ancestor/$_segment
		case "$_remaining" in
			*/*) _remaining=${_remaining#*/} ;;
			*)   _remaining="" ;;
		esac
	done
	printf '%s\n' "$_ancestor"
}

PHYSICAL_REPO_ROOT=$(cd "$ABS_REPO_ROOT" && pwd -P) || {
	error "cannot resolve --repo-root: $ABS_REPO_ROOT"
	exit 1
}

EXISTING_ANCESTOR=$(deepest_existing_ancestor "$ABS_REPO_ROOT" "$OUTPUT_DIR")
PHYSICAL_EXISTING_ANCESTOR=$(cd "$EXISTING_ANCESTOR" && pwd -P) || {
	error "cannot resolve the existing output-path ancestor: $EXISTING_ANCESTOR"
	exit 1
}

# Equality is accepted here, unlike phase 2: when nothing under .crucible
# exists yet, the deepest existing ancestor IS the repo root.
#
# Both phases open with the same "refusing to write outside the repo root"
# wording on purpose — it is the diagnostic substring callers and the harness
# already match on, and which of the two phases caught the escape is an
# implementation detail, not something a consumer should have to branch on.
case "$PHYSICAL_EXISTING_ANCESTOR" in
	"$PHYSICAL_REPO_ROOT"|"$PHYSICAL_REPO_ROOT"/*) : ;;
	*)
		error "refusing to write outside the repo root: $EXISTING_ANCESTOR resolves to $PHYSICAL_EXISTING_ANCESTOR, which is not under $PHYSICAL_REPO_ROOT (a symlinked path component?); no directories were created"
		exit 1
		;;
esac

if ! mkdir -p "$OUTPUT_DIR"; then
	error "failed to create output directory: $OUTPUT_DIR"
	exit 1
fi

PHYSICAL_OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd -P) || {
	error "cannot resolve the output directory: $OUTPUT_DIR"
	exit 1
}

case "$PHYSICAL_OUTPUT_DIR" in
	"$PHYSICAL_REPO_ROOT"/*) : ;;
	*)
		error "refusing to write outside the repo root: $OUTPUT_DIR resolves to $PHYSICAL_OUTPUT_DIR, which is not under $PHYSICAL_REPO_ROOT (a symlinked path component?); inspect $OUTPUT_DIR — directories may already have been created at the resolved location"
		exit 1
		;;
esac

# ---------------------------------------------------------------------------
# Cleanup: remove BOTH write-in-progress artefacts on any exit path — the
# staged temp file, and the empty placeholder left by the atomic filename
# claim below.
#
# CLAIMED_FILE exists because the claim and the publishing `mv` are two
# separate steps: a signal landing between them would otherwise leave a real,
# 0-byte file at OUTPUT_FILE, which the next run's "refuse to overwrite an
# existing artifact" guard would then honour as a genuine prior artifact —
# permanently blocking every retry. It is set the instant the claim succeeds
# and cleared the instant the mv succeeds, so it names a placeholder only
# while one actually exists.
# ---------------------------------------------------------------------------
TMP_FILE=""
CLAIMED_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$TMP_FILE" ]     || rm -f "$TMP_FILE" 2>/dev/null || true
	[ -z "$CLAIMED_FILE" ] || rm -f "$CLAIMED_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Build the document — see the header's WHY block on why the caller's
# status/tracked_status/first_seen never survive this reconstruction.
JQ_AGGREGATES=$(cat "$REVIEW_AGGREGATES_JQ")

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_BUILD="$JQ_AGGREGATES"'
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

# 0666 masked by the caller's own umask — see the header's WHY block on why
# this is neither 600 nor a forced 644.
FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$(umask) ))")

if ! chmod "$FILE_MODE" "$TMP_FILE"; then
	error "failed to set mode $FILE_MODE on the staged artifact: $TMP_FILE"
	exit 1
fi

# Claim the destination ATOMICALLY (noclobber => O_EXCL), in a subshell so
# `set -C` never leaks into the rest of the script. This — not the early
# [ -e ] test — is what makes "never overwrite" a guarantee instead of a
# check-then-act race. Claimed only now, after the document is fully built:
# claiming earlier would leave an empty file behind on a build failure and
# permanently block a retry.
if ! (set -C; : >"$OUTPUT_FILE") 2>/dev/null; then
	if [ -e "$OUTPUT_FILE" ]; then
		error "refusing to overwrite existing artifact: $OUTPUT_FILE"
	else
		error "failed to create the artifact file: $OUTPUT_FILE"
	fi
	exit 1
fi
CLAIMED_FILE=$OUTPUT_FILE

# Same-directory rename over our own placeholder: atomic content publish. On
# failure the placeholder is removed by cleanup(), which still holds it in
# CLAIMED_FILE — the same reason an interrupted run cannot strand one.
if ! mv "$TMP_FILE" "$OUTPUT_FILE"; then
	error "failed to publish the artifact to: $OUTPUT_FILE"
	exit 1
fi
TMP_FILE=""
CLAIMED_FILE=""

printf 'REVIEW_JSON=%s\n' "$OUTPUT_FILE"
exit 0
