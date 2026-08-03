#!/usr/bin/env sh
#
# spec-create.sh — draft a NEW flow-spec artifact from a fields-file and
#                  stamp it into `.crucible/docs/specs/{YYYY}/{MM}/{DD}/`.
#
# WHY no lock (unlike the GTD inbox scripts): a flow-spec artifact is a
# one-file-per-effort document written exactly once, by exactly one
# orchestrator turn, never concurrently by multiple writers — there is no
# rewriter racing an appender the way process.sh races capture.sh. The
# mkdir-based mutual-exclusion dance those scripts need has no counterpart
# here. What IS kept is the same loud-failure discipline: every precondition
# (fields-file shape, required fields, target-not-already-present) is
# asserted BEFORE anything is written, and the write itself is an atomic
# same-directory mktemp + exclusive `ln` (never a plain `mv`, which would
# silently overwrite an existing target under a concurrent same-slug
# invocation) so a crash mid-write never leaves a truncated or partial spec
# document behind, and a same-slug race is a loud EEXIST, never a silent
# overwrite.
#
# Usage:
#   spec-create.sh --repo-root PATH --slug SLUG --fields-file PATH [-h|--help]
#
#     --repo-root PATH    Root of the target repo; the artifact is written
#                           under PATH/.crucible/docs/specs/... (required).
#                           Must exist and be a directory.
#     --slug SLUG          The effort slug — must match
#                           artifact-slug.schema.json's pattern
#                           ^[a-z0-9]+(-[a-z0-9]+)*$ (required). Becomes both
#                           the "id" field and the filename.
#     --fields-file PATH   A JSON object holding the draft content (required):
#                             title              (string, required)
#                             repos_in_scope      (non-empty array of
#                                                  {repo, tech} — both
#                                                  non-empty strings —
#                                                  required)
#                             goal                (string, required)
#                             interface_contracts (non-empty array of
#                                                  {repo, exposes, consumes} —
#                                                  repo a non-empty string,
#                                                  exposes/consumes arrays —
#                                                  required)
#                             non_goals           (array of non-empty
#                                                  strings, optional)
#                             constraints         (array of non-empty
#                                                  strings, optional)
#                             decision_log        (array of {fork, decision,
#                                                  why} — all non-empty
#                                                  strings — optional; see
#                                                  below)
#                             open_questions      (array of non-empty
#                                                  strings, optional)
#                           Do NOT include schema_version/id/status/created/
#                           approved_by/approved_at — this script stamps
#                           those itself. Every optional field, when present,
#                           is validated to be an array; every
#                           repos_in_scope[]/interface_contracts[]/
#                           decision_log[] entry is validated for the item
#                           shape above, and every non_goals[]/constraints[]/
#                           open_questions[] element is validated to be a
#                           non-empty string — a malformed value is a usage
#                           error, never silently persisted.
#     -h, --help           Show this help.
#
#   decision_log is ALWAYS written as an array in the output: passed through
#   verbatim when given, defaulted to [] when absent (per the schema's own
#   description, it is "never omitted" so a reader can tell "no fork existed"
#   apart from "the field wasn't filled in"). non_goals/constraints/
#   open_questions are NOT required by the schema: passed through only when
#   present in --fields-file, the key OMITTED entirely (never defaulted to
#   []) when absent.
#
# Output:
#   Written to:
#     {repo-root}/.crucible/docs/specs/{YYYY}/{MM}/{DD}/{slug}.json
#   (YYYY/MM/DD derived from the stamped "created" date.) The parent
#   directory is created (mkdir -p); an already-existing target file is a
#   loud failure — this script never overwrites a spec.
#
#   On success, stdout carries the machine-parseable key:
#     SPEC_JSON=<absolute path>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  spec created
#   1  jq absent / directory-create or write failure / target file already
#      exists / internal JSON-assembly validation failure
#   2  usage error (missing/invalid argument; invalid --slug; --repo-root
#      missing or not a directory; --fields-file missing, unreadable, not
#      valid JSON, not a JSON object, missing a required field, or a
#      required/optional field or nested item with the wrong shape)
#
# Env:
#   None — every path is supplied via a required argument.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (date, mktemp, mkdir, mv, pwd, basename, dirname) are assumed
#   present. Self-contained: sources nothing.
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

Draft a new flow-spec artifact (JSON) from --fields-file, stamping
schema_version/id/status/created, and write it to
{repo-root}/.crucible/docs/specs/{YYYY}/{MM}/{DD}/{slug}.json. Refuses to
overwrite an existing artifact.

Options:
  --repo-root PATH    Root of the target repo (required; must be a directory).
  --slug SLUG          Effort slug, ^[a-z0-9]+(-[a-z0-9]+)*\$ (required).
  --fields-file PATH   JSON object with title/repos_in_scope/goal/
                        interface_contracts (required) and optionally
                        non_goals/constraints/decision_log/open_questions.
  -h, --help           Show this help.

On success, prints:
  SPEC_JSON=<absolute path>

Exit codes:
  0  created
  1  jq absent / write failure / target already exists / internal
     assembly-validation failure
  2  usage error (bad argument, invalid slug, invalid/missing fields-file
     content)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# to_abs_path PATH — prefix a relative path with the current working
# directory; a path already starting with "/" is returned unchanged. Not a
# realpath/symlink-resolving canonicalization — just enough to satisfy the
# "print an absolute path" contract without pulling in a GNU/BSD-divergent
# `readlink -f`.
to_abs_path() {
	case "$1" in
		/*) printf '%s' "$1" ;;
		*)  printf '%s/%s' "$(pwd)" "$1" ;;
	esac
}

# slug_is_valid SLUG — matches artifact-slug.schema.json's
# ^[a-z0-9]+(-[a-z0-9]+)*$ using plain case-pattern matching (no grep/regex
# dependency): lowercase alnum segments only, no leading/trailing hyphen, no
# consecutive hyphens, non-empty.
slug_is_valid() {
	case "$1" in
		'')             return 1 ;;
		*[!a-z0-9-]*)   return 1 ;;
		-*)             return 1 ;;
		*-)             return 1 ;;
		*--*)           return 1 ;;
		*)              return 0 ;;
	esac
}

# require_nonempty FIELDS_FILE FIELD TYPE_NAME — exit 2 naming FIELD if
# absent, not of jq type TYPE_NAME ("string"/"array"), or empty (zero-length
# string/array).
require_nonempty() {
	fields_file=$1
	field=$2
	type_name=$3
	if ! jq -e --arg f "$field" --arg t "$type_name" \
		'has($f) and (.[$f] | type == $t) and (.[$f] | length > 0)' \
		"$fields_file" >/dev/null 2>&1
	then
		usage >&2
		error "--fields-file missing required field '$field' (expected a non-empty $type_name)"
		exit 2
	fi
}

# require_optional_type FIELDS_FILE FIELD TYPE_NAME — a no-op when FIELD is
# absent (these fields are optional); when present, exit 2 naming FIELD if it
# is not of jq type TYPE_NAME. Guards the shape of an optional field WHEN
# supplied, so a malformed value fails loudly here instead of silently
# persisting or crashing render-md.sh downstream.
require_optional_type() {
	fields_file=$1
	field=$2
	type_name=$3
	if ! jq -e --arg f "$field" --arg t "$type_name" \
		'(has($f) | not) or (.[$f] | type == $t)' \
		"$fields_file" >/dev/null 2>&1
	then
		usage >&2
		error "--fields-file field '$field' has the wrong shape (expected $type_name when present)"
		exit 2
	fi
}

# require_repos_in_scope_shape FIELDS_FILE — exit 2 unless every
# repos_in_scope[] entry is an object with a non-empty string "repo" and
# "tech". `and` short-circuits in jq, so a non-object entry never reaches the
# field-indexing operators.
require_repos_in_scope_shape() {
	fields_file=$1
	if ! jq -e \
		'[.repos_in_scope[] | (
			type == "object"
			and (.repo | type == "string") and (.repo | length > 0)
			and (.tech | type == "string") and (.tech | length > 0)
		)] | all' \
		"$fields_file" >/dev/null 2>&1
	then
		usage >&2
		error "--fields-file: every repos_in_scope[] entry must be an object with a non-empty string 'repo' and 'tech'"
		exit 2
	fi
}

# require_interface_contracts_shape FIELDS_FILE — exit 2 unless every
# interface_contracts[] entry is an object with a non-empty string "repo" and
# array "exposes"/"consumes".
require_interface_contracts_shape() {
	fields_file=$1
	if ! jq -e \
		'[.interface_contracts[] | (
			type == "object"
			and (.repo | type == "string") and (.repo | length > 0)
			and (.exposes | type == "array")
			and (.consumes | type == "array")
		)] | all' \
		"$fields_file" >/dev/null 2>&1
	then
		usage >&2
		error "--fields-file: every interface_contracts[] entry must be an object with a non-empty string 'repo' and array 'exposes'/'consumes'"
		exit 2
	fi
}

# require_decision_log_shape FIELDS_FILE — a no-op when decision_log is
# absent; when present, exit 2 unless every entry is an object with a
# non-empty string "fork"/"decision"/"why" (spec-document.schema.json's
# decision_entry). Runs after require_optional_type has already confirmed
# decision_log, when present, is an array.
require_decision_log_shape() {
	fields_file=$1
	if ! jq -e \
		'(has("decision_log") | not) or
		 ([.decision_log[] | (
			type == "object"
			and (.fork | type == "string") and (.fork | length > 0)
			and (.decision | type == "string") and (.decision | length > 0)
			and (.why | type == "string") and (.why | length > 0)
		 )] | all)' \
		"$fields_file" >/dev/null 2>&1
	then
		usage >&2
		error "--fields-file: every decision_log[] entry must be an object with a non-empty string 'fork', 'decision', and 'why'"
		exit 2
	fi
}

# require_string_array_item_shape FIELDS_FILE FIELD — a no-op when FIELD is
# absent; when present, exit 2 naming FIELD unless every element is a
# non-empty string. Used for non_goals/constraints/open_questions, whose
# outer array-ness is already confirmed by require_optional_type.
require_string_array_item_shape() {
	fields_file=$1
	field=$2
	if ! jq -e --arg f "$field" \
		'(has($f) | not) or ([.[$f][] | (type == "string" and length > 0)] | all)' \
		"$fields_file" >/dev/null 2>&1
	then
		usage >&2
		error "--fields-file: every '$field'[] entry must be a non-empty string"
		exit 2
	fi
}

# ---------------------------------------------------------------------------
# Cleanup: remove the write's own rewrite temp file on any exit path. No lock
# to release (see the WHY note above the header) — this trap covers only the
# mktemp used for the atomic write. INT/TERM trapped separately from EXIT so
# an interrupted run reports the conventional 130/143 rather than whatever
# the last command before the signal happened to return.
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
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO_ROOT=""
OPT_SLUG=""
OPT_FIELDS_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo-root)    need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--slug)         need_arg "$1" "${2:-}"; OPT_SLUG=$2; shift ;;
		--fields-file)  need_arg "$1" "${2:-}"; OPT_FIELDS_FILE=$2; shift ;;
		-h|--help)      usage; exit 0 ;;
		--)             shift; break ;;
		-*)             usage >&2; error "unknown option: $1"; exit 2 ;;
		*)              usage >&2; error "unexpected argument: $1"; exit 2 ;;
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

if ! slug_is_valid "$OPT_SLUG"; then
	usage >&2
	error "--slug does not match ^[a-z0-9]+(-[a-z0-9]+)*\$: $OPT_SLUG"
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

if ! jq -e . "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file is not valid JSON: $OPT_FIELDS_FILE"
	exit 2
fi

FIELDS_TYPE=$(jq -r 'type' "$OPT_FIELDS_FILE")
if [ "$FIELDS_TYPE" != "object" ]; then
	usage >&2
	error "--fields-file must contain a single JSON object, got: $FIELDS_TYPE"
	exit 2
fi

require_nonempty "$OPT_FIELDS_FILE" title string
require_nonempty "$OPT_FIELDS_FILE" repos_in_scope array
require_nonempty "$OPT_FIELDS_FILE" goal string
require_nonempty "$OPT_FIELDS_FILE" interface_contracts array

require_repos_in_scope_shape      "$OPT_FIELDS_FILE"
require_interface_contracts_shape "$OPT_FIELDS_FILE"

require_optional_type "$OPT_FIELDS_FILE" non_goals array
require_optional_type "$OPT_FIELDS_FILE" constraints array
require_optional_type "$OPT_FIELDS_FILE" decision_log array
require_optional_type "$OPT_FIELDS_FILE" open_questions array

require_decision_log_shape         "$OPT_FIELDS_FILE"
require_string_array_item_shape    "$OPT_FIELDS_FILE" non_goals
require_string_array_item_shape    "$OPT_FIELDS_FILE" constraints
require_string_array_item_shape    "$OPT_FIELDS_FILE" open_questions

ABS_REPO_ROOT=$(to_abs_path "$OPT_REPO_ROOT")

# ---------------------------------------------------------------------------
# Stamp: schema_version, id, status, created — ONE `date -u` call feeds the
# stamp AND the YYYY/MM/DD path split below, so they can never straddle a
# day boundary the way two separate `date` calls could.
# ---------------------------------------------------------------------------
CREATED=$(date -u +%Y-%m-%d)
YEAR=${CREATED%%-*}
_month_day=${CREATED#*-}
MONTH=${_month_day%%-*}
DAY=${_month_day#*-}

# ---------------------------------------------------------------------------
# Assemble the document. Every dynamic value travels via --arg into this
# STATIC jq program; the fields-file's own content is read as jq's normal
# input document (never spliced into the program text). Property order
# mirrors the schema's own declaration order for readability.
# ---------------------------------------------------------------------------
SPEC_DOC=$(jq -c \
	--arg slug "$OPT_SLUG" \
	--arg created "$CREATED" \
	'def optional_field($k): if has($k) then {($k): .[$k]} else {} end;
	{
		schema_version: "1.0",
		id: $slug,
		title: .title,
		status: "draft",
		created: $created,
		repos_in_scope: .repos_in_scope,
		goal: .goal
	}
	+ optional_field("non_goals")
	+ {interface_contracts: .interface_contracts}
	+ optional_field("constraints")
	+ {decision_log: (.decision_log // [])}
	+ optional_field("open_questions")' \
	"$OPT_FIELDS_FILE")

# Defense in depth: re-parse the assembled document before writing anything.
if ! printf '%s' "$SPEC_DOC" | jq -e . >/dev/null 2>&1; then
	error "internal: assembled spec JSON failed to validate (this should never happen)"
	exit 1
fi

SPEC_DIR="$ABS_REPO_ROOT/.crucible/docs/specs/$YEAR/$MONTH/$DAY"
SPEC_JSON="$SPEC_DIR/$OPT_SLUG.json"

if ! mkdir -p "$SPEC_DIR"; then
	error "failed to create spec directory: $SPEC_DIR"
	exit 1
fi

# ---------------------------------------------------------------------------
# Refuse to overwrite an existing spec. The upfront `-e` check is a fast-fail
# UX nicety only — the actual guarantee is the `ln` below: a hard link into
# an existing path fails with EEXIST atomically, so a concurrent same-slug
# invocation can never win a check-then-write race the way a check-then-mv
# gap could. `ln` (not `mv`) is what makes "never overwrite" true even under
# concurrency; mktemp writes into the SAME directory as SPEC_JSON so the link
# stays on one filesystem.
# ---------------------------------------------------------------------------
if [ -e "$SPEC_JSON" ]; then
	error "spec artifact already exists, refusing to overwrite: $SPEC_JSON"
	exit 1
fi

TMP_FILE=$(mktemp "$SPEC_DIR/.$OPT_SLUG.XXXXXX")
printf '%s\n' "$SPEC_DOC" >"$TMP_FILE"

if ! ln "$TMP_FILE" "$SPEC_JSON" 2>/dev/null; then
	error "spec artifact already exists, refusing to overwrite: $SPEC_JSON"
	exit 1
fi
rm -f "$TMP_FILE"
TMP_FILE=""

printf 'SPEC_JSON=%s\n' "$SPEC_JSON"
exit 0
