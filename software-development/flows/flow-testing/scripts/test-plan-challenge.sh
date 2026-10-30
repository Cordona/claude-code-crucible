#!/usr/bin/env sh
#
# test-plan-challenge.sh — record lens-test-quality-reviewer's challenge on a
#                          DRAFT flow-testing test plan: replace its body with
#                          the revised one, record the reviewer's verdict,
#                          and move status draft → challenged.
#
# WHY draft-only: the reviewer challenge happens exactly once, between the
# draft and human approval (flow-testing §3c). Re-challenging a challenged or
# approved plan would silently overwrite the reviewer verdict the human
# approved against, so it is refused outright; later plan changes go through
# test-plan-amend.sh.
#
# WHY every body section the revision changes (other than tests) needs a
# reviewer.changes entry naming it in field: so no change reaches the human
# unannounced (flow-testing §3c).
#
# WHY the fields-file carries the WHOLE revised plan rather than a patch:
# numbering, coverage, the redundancy rule and path listing all span
# sections, so only a complete plan can be validated as a unit. The reviewer
# drafts that plan and the orchestrator writes it unchanged (flow-testing
# §3c).
#
# WHY no lock (unlike the GTD inbox scripts): a test plan is a one-file-per-
# effort document with a single orchestrator writer. Replacement IS the
# intent here (unlike create), so the publish is a same-directory mktemp + mv:
# atomic, never a truncated or half-written plan. The published mode is 0666
# masked by the CALLER'S OWN umask, never a forced mode.
#
# WHY --diff-files is required: a plan tests the diff and nothing else.
# Every change.files path must be in the list diff-scope.sh wrote, and every
# files.existing and files.new path must be in it or be a test or test-data
# file (lib/test-plan-validate.jq, diff_scope_errors). The list is recorded
# as the plan's diff_files — as {path, sha} objects when given
# diff-files.tsv, so a later pass can tell which files are unchanged since
# this plan.
#
# WHY --repo-root is required: an approved plan authorizes test writes to
# the paths it names, and a symlink would let a path that passes the diff
# scope (in the diff, or a test path) land on whatever file the link points
# at. Every change.files, files.existing and files.new path is walked under
# --repo-root, and one that runs through a symlink (leaf or any existing
# parent) or resolves outside the repo is rejected. Every file:line a
# not_tested proof names is resolved there too: a regular file, with that
# line.
#
# Usage: see --help.
#
# Output:
#   The file at --json-file is replaced atomically. On success, stdout
#   carries the machine-parseable key:
#     TEST_PLAN_JSON=<absolute path>
#   Diagnostics go to stderr; each validation failure names its field path.
#
# Exit codes:
#   0  challenged
#   1  jq absent / shared jq library unreadable / --json-file not valid
#      JSON, not one document, failing validation, or not named {id}.json /
#      status is not "draft" / write failure / internal assembly-validation
#      failure
#   2  usage error (missing/invalid argument; --json-file or --fields-file
#      missing or unreadable; --fields-file not valid JSON, not exactly one
#      JSON document, or failing validation — including the diff scope;
#      --diff-files missing, unreadable, or empty; --repo-root missing or not
#      a repository top level; a plan path that runs through a symlink or
#      resolves outside --repo-root; a proof naming no real file line)
#
# Env:
#   TMPDIR — optional; selects the directory of the private copy of
#   --diff-files (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (awk, basename, cat, chmod, dirname, mktemp, mv, rm, sed) are
#   assumed present. Reads its validator from lib/test-plan-validate.jq
#   (with security-terms.jq and review-categories.json from the sibling
#   flow-review skill's scripts/lib), resolved relative to this script
#   (see the TEST_PLAN_LIB_DIR preamble below); depends on nothing else
#   outside this scripts/ directory and that one.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

TAB=$(printf '\t')

# Locate the shared jq library RELATIVE TO THIS SCRIPT — see render-md.sh for
# the rationale (duplicated verbatim; no sourcing between siblings).
case "$0" in
	*/*) TEST_PLAN_SCRIPTS_DIR=${0%/*} ;;
	*)   TEST_PLAN_SCRIPTS_DIR=. ;;
esac
TEST_PLAN_LIB_DIR=$TEST_PLAN_SCRIPTS_DIR/lib
REVIEW_LIB_DIR=$TEST_PLAN_SCRIPTS_DIR/../../flow-review/scripts/lib
TEST_PLAN_VALIDATE_JQ=$TEST_PLAN_LIB_DIR/test-plan-validate.jq
TEST_PLAN_SECURITY_TERMS_JQ=$REVIEW_LIB_DIR/security-terms.jq
TEST_PLAN_CATEGORIES_JSON=$REVIEW_LIB_DIR/review-categories.json

# Every jq program that includes the library names it with a search path
# pinned to the library's absolute directory (JQ_VALIDATE, below), and the
# library reaches flow-review's by a path relative to its own directory: the
# libraries travel as modules, never as program text, so no argument grows
# with them, and an unpinned lookup would search the process's working
# directory first, where the repository under test could plant a same-named
# module.

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --json-file PATH --fields-file PATH --diff-files PATH
       --repo-root PATH [-h|--help]

Record the reviewer's challenge on a draft test plan: replace its body with
the fields-file, record the reviewer's verdict, and set status to
"challenged". Refuses any plan whose status is not "draft". id, created,
schema_version and snapshot are kept from the stored plan.

Options:
  --json-file PATH     The stored test plan (required; status must be draft).
  --fields-file PATH   ONE JSON object: the full revised body (as for
                         test-plan-create.sh) plus reviewer: approved,
                         rejected and changes (arrays), and no_e2e_agreed
                         when no test is end-to-end (required). Every test in
                         the body is in reviewer.approved, every changed
                         section and test is named by a reviewer.changes
                         entry, and every dropped draft test is rejected or
                         recorded there. Never carries schema_version, id,
                         status, created, approved_at, approved_baseline or
                         amendments.
  --diff-files PATH    diff-scope.sh's diff-files.tsv or diff-files.txt
                         (required): change.files must be in it;
                         files.existing and files.new must be in it or be
                         test or test-data files. Recorded as diff_files.
  --repo-root PATH     The repository top level (required; holds .git):
                         plan paths resolve under it with no symlink on the
                         way, and every file:line a not_tested proof names
                         is a regular file there with that line.
  -h, --help           Show this help.

On success, prints:
  TEST_PLAN_JSON=<absolute path>

Exit codes:
  0  challenged
  1  jq absent / invalid stored plan / status is not "draft" / write failure
  2  usage error (bad argument, unreadable file, invalid --fields-file content
     or a path outside the diff, empty --diff-files, bad --repo-root, a plan
     path through a symlink or outside the repo, a proof naming no real file
     line)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# report_validation_errors LABEL ERRORS — one stderr line per
# newline-separated field-path error.
report_validation_errors() {
	_label=$1
	printf '%s\n' "$2" | while IFS= read -r validation_error; do
		error "invalid $_label: $validation_error"
	done
}

# plan_path_repo_problems — read "<field path><TAB><plan path>" lines on stdin
# and print one line per plan path that runs through a symlink or resolves
# outside --repo-root. Each component is tested from the repo root down to
# the first one that does not exist yet (a file the plan will create); a
# symlink anywhere on that walk, the leaf included, could aim a test write
# at a file outside the repo or outside the diff.
plan_path_repo_problems() {
	while IFS="$TAB" read -r field_path plan_path; do
		walked_path=$PHYSICAL_REPO_ROOT
		existing_directory=$PHYSICAL_REPO_ROOT
		remaining_path=$plan_path
		symlink_path=""
		while [ -n "$remaining_path" ]; do
			walked_path=$walked_path/${remaining_path%%/*}
			case "$remaining_path" in
				*/*) remaining_path=${remaining_path#*/} ;;
				*)   remaining_path="" ;;
			esac
			if [ -L "$walked_path" ]; then
				symlink_path=${walked_path#"$PHYSICAL_REPO_ROOT"/}
				break
			fi
			[ -e "$walked_path" ] || break
			[ ! -d "$walked_path" ] || existing_directory=$walked_path
		done
		if [ -n "$symlink_path" ]; then
			printf '%s: %s runs through the symlink %s; a plan names only real files and directories inside the repo (--repo-root)\n' \
				"$field_path" "$plan_path" "$symlink_path"
			continue
		fi
		physical_directory=$(cd -P "$existing_directory" 2>/dev/null && pwd -P) || physical_directory=""
		case "$physical_directory" in
			"$PHYSICAL_REPO_ROOT"|"$PHYSICAL_REPO_ROOT"/*) : ;;
			*) printf '%s: %s resolves outside the repo (--repo-root)\n' "$field_path" "$plan_path" ;;
		esac
	done
}

# proof_locator_problems — read "<field><TAB><file><TAB><start><TAB><end>"
# lines on stdin (lib/test-plan-validate.jq, proof_locators) and print one
# line per locator that does not point at a real line: its file is not a
# regular file inside --repo-root (a symlink is not followed), or its line is
# 0, runs backwards, or is past the file's end. The same copy is in every
# flow-testing writer that records a proof.
proof_locator_problems() {
	while IFS="$TAB" read -r locator_field locator_file locator_start locator_end; do
		locator=$locator_file:$locator_start
		[ "$locator_start" = "$locator_end" ] || locator=$locator-$locator_end
		case "/$locator_file/" in
			//*|*/../*|*/./*)
				printf '%s: %s does not name a repo-relative file (--repo-root)\n' "$locator_field" "$locator"
				continue
				;;
			*) : ;;
		esac
		case "$locator_file" in
			*/*) locator_directory=$PHYSICAL_REPO_ROOT/${locator_file%/*} ;;
			*)   locator_directory=$PHYSICAL_REPO_ROOT ;;
		esac
		physical_locator_directory=$(cd -P "$locator_directory" 2>/dev/null && pwd -P) || physical_locator_directory=""
		locator_path=$physical_locator_directory/${locator_file##*/}
		case "$physical_locator_directory" in
			"$PHYSICAL_REPO_ROOT"|"$PHYSICAL_REPO_ROOT"/*) : ;;
			*) locator_path="" ;;
		esac
		if [ -z "$locator_path" ] || [ -L "$locator_path" ] || [ ! -f "$locator_path" ]; then
			printf '%s: %s names no regular file in the repo (--repo-root)\n' "$locator_field" "$locator"
			continue
		fi
		if [ "${#locator_start}" -gt 9 ] || [ "${#locator_end}" -gt 9 ]; then
			printf '%s: %s names a line past the end of %s\n' "$locator_field" "$locator" "$locator_file"
			continue
		fi
		line_count=$(awk 'END { print NR }' "$locator_path") || line_count=0
		if [ "$locator_start" -lt 1 ] || [ "$locator_end" -lt "$locator_start" ]; then
			printf '%s: %s names line 0 or a range that runs backwards\n' "$locator_field" "$locator"
		elif [ "$locator_end" -gt "$line_count" ]; then
			printf '%s: %s names a line past the end of %s (%s lines)\n' "$locator_field" "$locator" "$locator_file" "$line_count"
		fi
	done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_JSON_FILE=""
OPT_FIELDS_FILE=""
OPT_DIFF_FILES=""
OPT_REPO_ROOT=""

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)   need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--fields-file) need_arg "$1" "${2:-}"; OPT_FIELDS_FILE=$2; shift ;;
		--diff-files)  need_arg "$1" "${2:-}"; OPT_DIFF_FILES=$2; shift ;;
		--repo-root)   need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		-*)            usage >&2; error "unknown option: $1"; exit 2 ;;
		*)             usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_JSON_FILE" ]     || { usage >&2; error "--json-file is required"; exit 2; }
[ -n "$OPT_FIELDS_FILE" ] || { usage >&2; error "--fields-file is required"; exit 2; }
[ -n "$OPT_DIFF_FILES" ]  || { usage >&2; error "--diff-files is required (diff-scope.sh's diff-files.tsv or diff-files.txt)"; exit 2; }
[ -n "$OPT_REPO_ROOT" ]   || { usage >&2; error "--repo-root is required (the repository top level the plan paths resolve under)"; exit 2; }

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	usage >&2
	error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
	exit 2
fi

if [ ! -f "$OPT_FIELDS_FILE" ] || [ ! -r "$OPT_FIELDS_FILE" ]; then
	usage >&2
	error "--fields-file does not exist or is not readable: $OPT_FIELDS_FILE"
	exit 2
fi

if [ ! -f "$OPT_DIFF_FILES" ] || [ ! -r "$OPT_DIFF_FILES" ]; then
	usage >&2
	error "--diff-files does not exist or is not readable: $OPT_DIFF_FILES"
	exit 2
fi

if [ ! -d "$OPT_REPO_ROOT" ] || [ ! -e "$OPT_REPO_ROOT/.git" ]; then
	usage >&2
	error "--repo-root is not a repository top level (a directory holding .git): $OPT_REPO_ROOT"
	exit 2
fi
PHYSICAL_REPO_ROOT=$(cd -P "$OPT_REPO_ROOT" && pwd -P) || {
	error "cannot resolve --repo-root: $OPT_REPO_ROOT"
	exit 1
}

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

if [ ! -r "$TEST_PLAN_VALIDATE_JQ" ] || [ ! -r "$TEST_PLAN_SECURITY_TERMS_JQ" ] || [ ! -r "$TEST_PLAN_CATEGORIES_JSON" ]; then
	error "cannot read the shared jq library: $TEST_PLAN_VALIDATE_JQ, $TEST_PLAN_SECURITY_TERMS_JQ and $TEST_PLAN_CATEGORIES_JSON (the last two are the flow-review skill's, which must be installed beside flow-testing; invoke this script by its absolute path)"
	exit 1
fi

TEST_PLAN_LIB_DIR_ABS=$(CDPATH='' cd -P -- "$TEST_PLAN_LIB_DIR" && pwd -P) || {
	error "cannot resolve the jq library directory: $TEST_PLAN_LIB_DIR"
	exit 1
}
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE=$(jq -n -r --arg lib_dir "$TEST_PLAN_LIB_DIR_ABS" \
	'"include \"test-plan-validate\" {search: \($lib_dir | tojson)};"') || {
	error "failed to build the jq library include"
	exit 1
}
JQ_VALIDATE="$JQ_VALIDATE
"

# lenient_lines(LINES): the lines LINES yields from a fields-file not yet
# known to be valid, up to the first value it cannot read, each a single
# line. A path the checks below walk is only ever looked at, never written.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_LENIENT_LINES='
def lenient_lines(lines): [try lines catch empty][] | strings | select(test("[\\n\\r]") | not);
'

# ---------------------------------------------------------------------------
# Cleanup: remove the private copy of --diff-files and the staged temp file
# on any exit path. INT/TERM trapped separately from EXIT so an interrupted
# run reports 130/143.
# ---------------------------------------------------------------------------
DIFF_FILES_JSON=""
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$DIFF_FILES_JSON" ] || rm -f "$DIFF_FILES_JSON" 2>/dev/null || true
	[ -z "$TMP_FILE" ]        || rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# --diff-files, read ONCE into a private JSON copy (mktemp creates it 0600)
# that every later step reads, so the list checked is the list recorded.
# ---------------------------------------------------------------------------
DIFF_FILES_JSON=$(mktemp "${TMPDIR:-/tmp}/test-plan-challenge.diff-files.XXXXXX")
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
if ! jq -R -s "$JQ_VALIDATE"' diff_file_list' "$OPT_DIFF_FILES" >"$DIFF_FILES_JSON"; then
	error "failed to read --diff-files: $OPT_DIFF_FILES"
	exit 1
fi
if ! jq -e 'length > 0' "$DIFF_FILES_JSON" >/dev/null 2>&1; then
	usage >&2
	error "--diff-files lists no paths: $OPT_DIFF_FILES (nothing in the diff to test)"
	exit 2
fi

# ---------------------------------------------------------------------------
# The stored plan: one valid document, named {id}.json, status draft. Every
# failure here is the artifact's state, not the caller's arguments — exit 1.
# ---------------------------------------------------------------------------
if ! jq -e . "$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "--json-file is not valid JSON: $OPT_JSON_FILE"
	exit 1
fi

if ! jq -s -e 'length == 1' "$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "--json-file must hold exactly ONE JSON document: $OPT_JSON_FILE"
	exit 1
fi

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PLAN_ERRORS=$(jq -r "$JQ_VALIDATE"' plan_document_errors[]' "$OPT_JSON_FILE") || {
	error "failed to run the plan validator"
	exit 1
}
if [ -n "$PLAN_ERRORS" ]; then
	report_validation_errors "--json-file" "$PLAN_ERRORS"
	exit 1
fi

PLAN_DIR=$(dirname "$OPT_JSON_FILE")
PLAN_BASE=$(basename "$OPT_JSON_FILE")
ABS_PLAN_DIR=$(cd "$PLAN_DIR" && pwd) || {
	error "cannot resolve the --json-file directory: $PLAN_DIR"
	exit 1
}
PLAN_ID=$(jq -r '.id' "$OPT_JSON_FILE")
if [ "$PLAN_BASE" != "$PLAN_ID.json" ]; then
	error "--json-file name '$PLAN_BASE' does not match its id '$PLAN_ID' (expected $PLAN_ID.json)"
	exit 1
fi

CURRENT_STATUS=$(jq -r '.status' "$OPT_JSON_FILE")
if [ "$CURRENT_STATUS" != "draft" ]; then
	error "refusing to challenge: status is '$CURRENT_STATUS', not 'draft' (the reviewer challenge happens exactly once): $OPT_JSON_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# The fields-file: caller-supplied input — a malformed one is a usage error.
# Exactly one document, for the same reason as test-plan-create.sh: the merge
# reads only the first (--slurpfile + $fields_arr[0]).
# ---------------------------------------------------------------------------
if ! jq -e . "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file is not valid JSON: $OPT_FIELDS_FILE"
	exit 2
fi

if ! jq -s -e 'length == 1' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file must hold exactly ONE JSON document: $OPT_FIELDS_FILE"
	exit 2
fi

# Three rejection classes — the fields-file itself, its paths under
# --repo-root, and the file:line lines its not_tested proofs name — are all
# checked before the fields-file is refused, so one run names every problem.
# The path and proof lines are read leniently (JQ_LENIENT_LINES): whatever
# the fields-file check already rejected is skipped, never a reason to stop.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
FIELDS_ERRORS=$(jq -r --slurpfile stored_arr "$OPT_JSON_FILE" --slurpfile diff_files_arr "$DIFF_FILES_JSON" \
	"$JQ_VALIDATE"' challenge_input_errors($stored_arr[0]; $diff_files_arr[0])[]' "$OPT_FIELDS_FILE") || {
	error "failed to run the plan validator"
	exit 1
}

# Every plan path resolved under --repo-root (plan_path_repo_problems).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PLAN_REPO_PATHS=$(jq -r "$JQ_VALIDATE$JQ_LENIENT_LINES"' lenient_lines(plan_repo_path_lines)' "$OPT_FIELDS_FILE") || {
	error "failed to list the plan paths"
	exit 1
}
REPO_PATH_ERRORS=$(printf '%s\n' "$PLAN_REPO_PATHS" | sed '/^$/d' | plan_path_repo_problems)

# Every file:line a not_tested proof names is a real line under --repo-root.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PROOF_LOCATORS=$(jq -r "$JQ_VALIDATE$JQ_LENIENT_LINES"' lenient_lines(not_tested_proof_locator_lines)' "$OPT_FIELDS_FILE") || {
	error "failed to list the not_tested proofs"
	exit 1
}
PROOF_PROBLEMS=$(printf '%s\n' "$PROOF_LOCATORS" | sed '/^$/d' | proof_locator_problems)

ALL_ERRORS=$(printf '%s\n%s\n%s\n' "$FIELDS_ERRORS" "$REPO_PATH_ERRORS" "$PROOF_PROBLEMS" | sed '/^$/d')
if [ -n "$ALL_ERRORS" ]; then
	usage >&2
	report_validation_errors "--fields-file" "$ALL_ERRORS"
	exit 2
fi

# ---------------------------------------------------------------------------
# Merge: stamped keys kept from the stored plan, diff_files from
# --diff-files, the body rebuilt by the lib's shared plan_body, reviewer
# taken from the validated fields-file, status → challenged.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_MERGE="$JQ_VALIDATE"'
$fields_arr[0] as $fields
| { schema_version, id, status: "challenged", created, diff_files: $diff_files_arr[0] }
  + (if has("snapshot") then { snapshot } else {} end)
  + plan_body($fields)
  + { reviewer: $fields.reviewer }
'

TMP_FILE=$(mktemp "$PLAN_DIR/.tmp.$PLAN_BASE.XXXXXX")

if ! jq --slurpfile fields_arr "$OPT_FIELDS_FILE" --slurpfile diff_files_arr "$DIFF_FILES_JSON" \
	"$JQ_MERGE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to build the challenged test plan"
	exit 1
fi

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
ASSEMBLED_ERRORS=$(jq -r "$JQ_VALIDATE"' plan_document_errors[]' "$TMP_FILE") || ASSEMBLED_ERRORS="validator failed to run"
if [ -n "$ASSEMBLED_ERRORS" ]; then
	error "internal: challenged test plan failed validation (this should never happen): $ASSEMBLED_ERRORS"
	exit 1
fi

CALLER_UMASK=$(umask)
FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$CALLER_UMASK ))")
if ! chmod "$FILE_MODE" "$TMP_FILE"; then
	error "failed to set mode $FILE_MODE on the staged plan: $TMP_FILE"
	exit 1
fi

if ! mv "$TMP_FILE" "$OPT_JSON_FILE"; then
	error "failed to publish the challenged test plan to: $OPT_JSON_FILE"
	exit 1
fi
TMP_FILE=""

printf 'TEST_PLAN_JSON=%s\n' "$ABS_PLAN_DIR/$PLAN_BASE"
exit 0
