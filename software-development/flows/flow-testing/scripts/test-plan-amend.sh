#!/usr/bin/env sh
#
# test-plan-amend.sh — record a change to a CHALLENGED or APPROVED flow-testing
#                      test plan (a human trim, or a plan change found while
#                      writing or reviewing tests): replace its body, append the
#                      changes to amendments, and return it to "challenged".
#                      Or, with --waive-not-tested, record the human's waiver
#                      of one not_tested entry.
#
# WHY a waiver is its own operation, in the human's words: an exclusion in a
# required test category (security, persisted-data, concurrency,
# authentication), and an unproven exclusion of any category, is the human's
# call, never a plan author's, so no fields-file may carry waived_by_human.
# A proven other exclusion needs no waiver to be approved, but the human may
# still waive it. The orchestrator runs --waive-not-tested only after the
# human answers, with the human's reason as --reason (plain words, no proof
# form); it sets waived_by_human and waiver_reason on that entry, appends a
# "waived" amendment whose reason is the human's, and returns the plan to
# "challenged" like any amendment. A later amend keeps the waiver on an
# entry it leaves unchanged and drops it from one it changes.
#
# WHY --expect-sha: the Not tested number N moves when an amendment adds or
# removes a test, a restored proposal or an entry, so N alone could land the
# waiver on a different entry than the one the human answered for.
# --expect-sha names the entry by a prefix of its entry_sha256
# (test-plan-recheck.sh --list-not-tested), and the waiver is refused when
# the entry at N has another digest.
#
# WHY an amend of an APPROVED plan records approved_baseline: the tests of an
# approved plan may already be written, and the amended plan is shown whole,
# so without a record of what was approved every test would read as
# proposed. The amendments cannot tell the delta — they also hold the
# changes made before approval, and one item can be added then changed — so
# the amend fingerprints the stored approved plan before replacing it: each
# test (without n), each reused, repair and delete entry, and each entry of
# the other sections the render shows (Files, Fixtures, builds_on,
# behaviors, not_tested), by name and the SHA-256 of the entry as `jq -S -c`
# prints it, a digest each of run, existing_tests, the reviewer lines and
# the rejected proposals, plus how many amendments it held
# (lib/test-plan-validate.jq, approved_baseline_after_amend), and
# render-md.sh compares the plan with it, shows only what changed, and
# lists only the later amendments. A second amend before re-approval keeps the baseline it finds, so the
# delta stays against what the human approved (a test added and then
# changed is still new); a challenged plan without one gets none. Approval
# removes it (test-plan-approve.sh). --waive-not-tested follows the same
# rule, and no fields-file may set it.
#
# WHY an amended plan returns to "challenged" (and loses approved_at): the
# human approves what render-md.sh showed them. An amendment changes that, so
# the orchestrator must render the amended plan and ask again before
# test-plan-approve.sh records approval (flow-testing §3d). An approval that
# silently survived an amendment would approve a plan nobody saw.
#
# WHY draft is refused: a draft has not been challenged yet; the reviewer's
# revised plan goes through test-plan-challenge.sh, which records the
# reviewer's verdict. Amending first would let a plan reach approval without
# that challenge.
#
# WHY amendments are APPENDED and reviewer is kept: together they are the
# plan's history — the reviewer's verdict, then every later change — and the
# rendered plan shows both. Neither can be rewritten from a fields-file:
# reviewer is rejected in an amend fields-file, and the stored amendments are
# never replaced.
#
# WHY the fields-file is judged against the stored plan: every changed body
# section and every changed approved test must be recorded by an amendment,
# and no_e2e_agreed follows the end-to-end tests (flow-testing §3d). An
# entry without a category is judged here like every other: the amend gives
# it a category and proof or unproven.
#
# WHY the MERGED plan is validated as the caller's input: reviewer coverage
# and the accepted rule depend on the stored reviewer and amendments, so they
# can only be judged once the new amendments sit next to them. A failure
# there is the fields-file's, so it exits 2 like any other invalid
# fields-file.
#
# WHY no lock (unlike the GTD inbox scripts): a test plan is a one-file-per-
# effort document with a single orchestrator writer. Replacement IS the
# intent here, so the publish is a same-directory mktemp + mv: atomic, never
# a truncated or half-amended plan. The published mode is 0666 masked by the
# CALLER'S OWN umask, never a forced mode.
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
#   0  amended
#   1  jq absent / shared jq library unreadable / --json-file not valid
#      JSON, not one document, failing validation, or not named {id}.json /
#      status is "draft" / no SHA-256 tool (shasum, sha256sum, openssl) for a
#      waiver's entry digest or an approved plan's baseline / write failure / internal assembly-validation
#      failure
#   2  usage error (missing/invalid argument; --json-file or --fields-file
#      missing or unreadable; --fields-file not valid JSON, not exactly one
#      JSON document, or failing validation — on its own, or merged with the
#      stored plan's reviewer and amendments; --diff-files missing,
#      unreadable, or empty; --repo-root missing or not a repository top
#      level; a plan path that runs through a symlink or resolves outside
#      --repo-root; a proof naming no real file line; a --waive-not-tested
#      number naming no entry, an --expect-sha the entry at that number does
#      not carry, or an entry already waived; an invalid --reason)
#
# Env:
#   TMPDIR — optional; selects the directory of the private copy of
#   --diff-files and of the entry copies the waiver and baseline digests are
#   taken from (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (awk, basename, cat, chmod, dirname, mktemp, mv, rm, sed) are
#   assumed present, plus one of shasum, sha256sum or openssl for a waiver's
#   entry digest and an approved plan's baseline digests (fails closed when
#   none is). Reads its validator from
#   lib/test-plan-validate.jq
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
       $PROG --json-file PATH --waive-not-tested N --expect-sha HEX
       --reason TEXT

Amend a challenged or approved test plan: replace its body with the
fields-file, append its amendments, and set status back to "challenged" (the
amended plan must be rendered and approved again). Refuses a draft plan.
id, created, schema_version, snapshot and reviewer are kept from the stored
plan (reviewer.no_e2e_agreed per flow-testing §3d); approved_at is removed.
Amending an approved plan records its fingerprint as approved_baseline, so
render-md.sh shows what changed since approval; a challenged plan keeps the
approved_baseline it holds.

Options:
  --json-file PATH     The stored test plan (required; status must be
                         challenged or approved).
  --fields-file PATH   ONE JSON object: the full revised body (as for
                         test-plan-create.sh) plus a non-empty amendments
                         array, appended to the stored ones; optionally
                         no_e2e_agreed (flow-testing §3d). A stored waiver
                         stays on a not_tested entry the body leaves
                         unchanged. Every not_tested entry gives a category
                         and proof or unproven, an entry stored without a
                         category included, and one naming security a
                         security or authentication category (as for
                         test-plan-create.sh). Never carries
                         approved_baseline or any other stamped key.
  --diff-files PATH    diff-scope.sh's diff-files.tsv or diff-files.txt
                         (required): change.files must be in it;
                         files.existing and files.new must be in it or be
                         test or test-data files. Recorded as diff_files.
  --repo-root PATH     The repository top level (required; holds .git):
                         plan paths resolve under it with no symlink on the
                         way, and every file:line a not_tested proof names
                         is a regular file there with that line.
  --waive-not-tested N Record the human's waiver of Not tested entry N (its
                         number in the render, which continues after the
                         tests and the rejected proposals; any entry not yet
                         waived) instead of a body change. Takes only
                         --json-file, --expect-sha and --reason. Run only
                         after the human answers.
  --expect-sha HEX     With --waive-not-tested (required): the entry's
                         handle, 12 to 64 lowercase hex digits, a prefix of
                         its entry_sha256 as test-plan-recheck.sh
                         --json-file PATH --list-not-tested prints it. The
                         waiver is refused when the entry at N has another
                         digest (the numbers moved, or the entry changed).
  --reason TEXT        With --waive-not-tested: the human's reason, in
                         their words (one line of at most 200 characters),
                         stored as waiver_reason.
  -h, --help           Show this help.

On success, prints:
  TEST_PLAN_JSON=<absolute path>

Exit codes:
  0  amended
  1  jq absent / invalid stored plan / status is "draft" / no SHA-256 tool
     for a waiver or an approved plan's baseline / write failure
  2  usage error (bad argument, unreadable file, invalid --fields-file content
     or a path outside the diff, empty --diff-files, bad --repo-root, a plan
     path through a symlink or outside the repo, a proof naming no real file
     line, a waiver refused or its --expect-sha not the entry's, an invalid
     --reason)
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

# sha256_of FILE — print FILE's SHA-256 as 64 lowercase hex digits, using the
# first installed of shasum (macOS, most Linux), sha256sum (GNU/busybox) or
# openssl. Returns 1 when none is installed or the tool's output is not a
# digest — the caller fails closed. The same copy is in every flow-testing
# script that takes a digest (self-contained scripts, no sourcing between
# siblings).
sha256_of() {
	if command -v shasum >/dev/null 2>&1; then
		_digest_line=$(shasum -a 256 <"$1") || return 1
		_digest=${_digest_line%% *}
	elif command -v sha256sum >/dev/null 2>&1; then
		_digest_line=$(sha256sum <"$1") || return 1
		_digest=${_digest_line%% *}
	elif command -v openssl >/dev/null 2>&1; then
		_digest_line=$(openssl dgst -sha256 <"$1") || return 1
		_digest=${_digest_line##* }
	else
		return 1
	fi
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	is_sha256_hex "$_digest" || return 1
	printf '%s\n' "$_digest"
}

# is_sha256_hex VALUE — true when VALUE is exactly 64 lowercase hex digits.
is_sha256_hex() {
	case "$1" in
		*[!0-9a-f]*) return 1 ;;
		*) : ;;
	esac
	[ "${#1}" -eq 64 ]
}

# digest_lines_json PROGRAM FILE — the SHA-256 of each line `jq -S -c`
# prints for the library program PROGRAM over FILE (one value per line), as
# a JSON array in order. The lines are staged in ENTRIES_FILE, each copied
# with its trailing newline to its own file in ENTRY_DIR, and all are hashed
# by one run of the hasher (sha256_each), so a plan's hundred-odd entries
# cost one process, not one each. Returns 1 when jq, the split or the hash
# fails, or the digests do not match the lines one for one — the caller
# fails closed. The same copy is in render-md.sh.
digest_lines_json() {
	jq -S -c "$JQ_VALIDATE$1" "$2" >"$ENTRIES_FILE" || return 1
	rm -f "$ENTRY_DIR"/line.* || return 1
	# The directory reaches awk through ENVIRON: -v would expand backslash
	# escapes in it.
	ENTRY_DIR=$ENTRY_DIR awk '{ path = sprintf("%s/line.%08d", ENVIRON["ENTRY_DIR"], NR); print > path; close(path) }' \
		"$ENTRIES_FILE" || return 1
	_line_count=$(awk 'END { print NR }' "$ENTRIES_FILE") || return 1
	if [ "$_line_count" -eq 0 ]; then
		printf '[]\n'
		return 0
	fi
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	_entry_digests=$(sha256_each "$ENTRY_DIR"/line.*) || return 1
	_digests="["
	_digest_count=0
	while IFS= read -r _entry_digest; do
		[ "$_digests" = "[" ] || _digests="$_digests,"
		_digests="$_digests\"$_entry_digest\""
		_digest_count=$((_digest_count + 1))
	done <<EOF
$_entry_digests
EOF
	[ "$_digest_count" -eq "$_line_count" ] || return 1
	printf '%s]\n' "$_digests"
}

# sha256_each FILE... — print each FILE's SHA-256, one per line in argument
# order, from one run of the first installed of shasum, sha256sum or openssl
# (as sha256_of picks). Returns 1 when none is installed or a line is not a
# digest. shasum and sha256sum print "<digest>  <name>", prefixed with "\"
# when the name holds a backslash; openssl prints "...(<name>)= <digest>".
sha256_each() {
	if command -v shasum >/dev/null 2>&1; then
		_hash_lines=$(shasum -a 256 "$@") || return 1
		_digest_at=start
	elif command -v sha256sum >/dev/null 2>&1; then
		_hash_lines=$(sha256sum "$@") || return 1
		_digest_at=start
	elif command -v openssl >/dev/null 2>&1; then
		_hash_lines=$(openssl dgst -sha256 "$@") || return 1
		_digest_at=end
	else
		return 1
	fi
	while IFS= read -r _hash_line; do
		if [ "$_digest_at" = start ]; then
			_hash_line=${_hash_line#\\}
			_digest=${_hash_line%% *}
		else
			_digest=${_hash_line##* }
		fi
		# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
		is_sha256_hex "$_digest" || return 1
		printf '%s\n' "$_digest"
	done <<EOF
$_hash_lines
EOF
}

# publish_staged_plan — give the staged plan at TMP_FILE the caller's
# umask-masked mode (never a forced one), move it over --json-file, and print
# its path.
publish_staged_plan() {
	CALLER_UMASK=$(umask)
	FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$CALLER_UMASK ))")
	if ! chmod "$FILE_MODE" "$TMP_FILE"; then
		error "failed to set mode $FILE_MODE on the staged plan: $TMP_FILE"
		exit 1
	fi

	if ! mv "$TMP_FILE" "$OPT_JSON_FILE"; then
		error "failed to publish the amended test plan to: $OPT_JSON_FILE"
		exit 1
	fi
	TMP_FILE=""

	printf 'TEST_PLAN_JSON=%s\n' "$ABS_PLAN_DIR/$PLAN_BASE"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_JSON_FILE=""
OPT_FIELDS_FILE=""
OPT_DIFF_FILES=""
OPT_REPO_ROOT=""
OPT_WAIVE_NUMBER=""
OPT_REASON=""
OPT_EXPECT_SHA=""
HAS_WAIVE=false
HAS_REASON=false

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)   need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--fields-file) need_arg "$1" "${2:-}"; OPT_FIELDS_FILE=$2; shift ;;
		--diff-files)  need_arg "$1" "${2:-}"; OPT_DIFF_FILES=$2; shift ;;
		--repo-root)   need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--waive-not-tested) need_arg "$1" "${2:-}"; OPT_WAIVE_NUMBER=$2; HAS_WAIVE=true; shift ;;
		--reason)      need_arg "$1" "${2:-}"; OPT_REASON=$2; HAS_REASON=true; shift ;;
		--expect-sha)  need_arg "$1" "${2:-}"; OPT_EXPECT_SHA=$2; shift ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		-*)            usage >&2; error "unknown option: $1"; exit 2 ;;
		*)             usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_JSON_FILE" ]     || { usage >&2; error "--json-file is required"; exit 2; }

if [ "$HAS_WAIVE" = true ]; then
	if [ -n "$OPT_FIELDS_FILE" ] || [ -n "$OPT_DIFF_FILES" ] || [ -n "$OPT_REPO_ROOT" ]; then
		usage >&2
		error "--waive-not-tested takes only --json-file, --expect-sha and --reason"
		exit 2
	fi
	[ "$HAS_REASON" = true ] || { usage >&2; error "--waive-not-tested requires --reason (the human's reason, in their words)"; exit 2; }
	[ -n "$OPT_EXPECT_SHA" ] || { usage >&2; error "--waive-not-tested requires --expect-sha (the entry's handle, from test-plan-recheck.sh --list-not-tested)"; exit 2; }
	case "$OPT_EXPECT_SHA" in
		*[!0-9a-f]*) expect_sha_is_hex=false ;;
		*)           expect_sha_is_hex=true ;;
	esac
	if [ "$expect_sha_is_hex" = false ] || [ "${#OPT_EXPECT_SHA}" -lt 12 ] || [ "${#OPT_EXPECT_SHA}" -gt 64 ]; then
		usage >&2
		error "invalid --expect-sha: $OPT_EXPECT_SHA (expected 12 to 64 lowercase hex digits, the handle test-plan-recheck.sh --list-not-tested prints)"
		exit 2
	fi
	case "$OPT_WAIVE_NUMBER" in
		''|*[!0-9]*|0*)
			usage >&2
			error "invalid --waive-not-tested: $OPT_WAIVE_NUMBER (expected the entry's Not tested number, an integer >= 1, no leading zeros)"
			exit 2
			;;
		*) : ;;
	esac
elif [ "$HAS_REASON" = true ] || [ -n "$OPT_EXPECT_SHA" ]; then
	usage >&2
	error "--reason and --expect-sha are given only with --waive-not-tested"
	exit 2
fi

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	usage >&2
	error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
	exit 2
fi

# The body-change arguments, checked only when the call changes the body.
if [ "$HAS_WAIVE" = false ]; then
	[ -n "$OPT_FIELDS_FILE" ] || { usage >&2; error "--fields-file is required"; exit 2; }
	[ -n "$OPT_DIFF_FILES" ]  || { usage >&2; error "--diff-files is required (diff-scope.sh's diff-files.tsv or diff-files.txt)"; exit 2; }
	[ -n "$OPT_REPO_ROOT" ]   || { usage >&2; error "--repo-root is required (the repository top level the plan paths resolve under)"; exit 2; }

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
fi

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
ENTRIES_FILE=""
ENTRY_FILE=""
ENTRY_DIR=""
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$DIFF_FILES_JSON" ] || rm -f "$DIFF_FILES_JSON" 2>/dev/null || true
	[ -z "$ENTRIES_FILE" ]    || rm -f "$ENTRIES_FILE" 2>/dev/null || true
	[ -z "$ENTRY_FILE" ]      || rm -f "$ENTRY_FILE" 2>/dev/null || true
	[ -z "$ENTRY_DIR" ]       || rm -rf "$ENTRY_DIR" 2>/dev/null || true
	[ -z "$TMP_FILE" ]        || rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# --diff-files, read ONCE into a private JSON copy (mktemp creates it 0600)
# that every later step reads, so the list checked is the list recorded.
# ---------------------------------------------------------------------------
if [ "$HAS_WAIVE" = false ]; then
	DIFF_FILES_JSON=$(mktemp "${TMPDIR:-/tmp}/test-plan-amend.diff-files.XXXXXX")
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
fi

# ---------------------------------------------------------------------------
# The stored plan: one valid document, named {id}.json, status challenged or
# approved. Every failure here is the artifact's state, not the caller's
# arguments — exit 1.
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
case "$CURRENT_STATUS" in
	challenged|approved) : ;;
	*)
		error "refusing to amend: status is '$CURRENT_STATUS' — a draft goes through the reviewer challenge (test-plan-challenge.sh) first: $OPT_JSON_FILE"
		exit 1
		;;
esac

# ---------------------------------------------------------------------------
# The approved baseline: amending an approved plan records its fingerprint
# (approved_baseline_after_amend), so the amended plan renders as a change
# to what was approved. The digests are taken only then; a challenged plan
# keeps the baseline it holds, or gets none.
# ---------------------------------------------------------------------------
ENTRY_FILE=$(mktemp "${TMPDIR:-/tmp}/test-plan-amend.entry.XXXXXX")
BASELINE_DIGESTS="[]"
if [ "$CURRENT_STATUS" = approved ]; then
	ENTRIES_FILE=$(mktemp "${TMPDIR:-/tmp}/test-plan-amend.entries.XXXXXX")
	ENTRY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-plan-amend.entry-lines.XXXXXX")
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	BASELINE_DIGESTS=$(digest_lines_json ' baseline_digest_inputs' "$OPT_JSON_FILE") || {
		error "cannot compute the approved plan's test digests (install shasum, sha256sum, or openssl)"
		exit 1
	}
fi

# ---------------------------------------------------------------------------
# --waive-not-tested: the human's waiver of one exclusion, recorded by the
# lib's waive_not_tested and published like any amendment. The plan is
# rebuilt in schema order from the stored one, so diff_files and the body
# are kept as they are; status → challenged and approved_at dropped.
# ---------------------------------------------------------------------------
if [ "$HAS_WAIVE" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	REASON_ERRORS=$(jq -n -r --arg reason "$OPT_REASON" "$JQ_VALIDATE"' $reason | reason_errors("--reason")[]') || {
		error "failed to run the plan validator"
		exit 1
	}
	if [ -n "$REASON_ERRORS" ]; then
		usage >&2
		printf '%s\n' "$REASON_ERRORS" | while IFS= read -r reason_error; do
			error "invalid $reason_error"
		done
		exit 2
	fi
	# The Not tested number, as render-md.sh shows it, to the entry's index;
	# compared inside jq, so a number too large for shell arithmetic fails
	# closed.
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	WAIVE_INDEX=$(jq -r --argjson number "$OPT_WAIVE_NUMBER" "$JQ_VALIDATE"'
		not_tested_number_offset as $offset
		| if $number <= $offset or $number > $offset + (.not_tested | length) then "none" else $number - $offset - 1 end' "$OPT_JSON_FILE") || {
		error "failed to read not_tested in $OPT_JSON_FILE"
		exit 1
	}
	if [ "$WAIVE_INDEX" = none ]; then
		usage >&2
		error "invalid --waive-not-tested $OPT_WAIVE_NUMBER: it names no Not tested entry (see the number render-md.sh shows); no changes made"
		exit 2
	fi
	# The handle the caller read must still name the entry at that number: the
	# entry_sha256 test-plan-recheck.sh takes, the entry as `jq -S -c` prints
	# it with the waiver keys removed.
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	if ! jq -S -c --argjson index "$WAIVE_INDEX" "$JQ_VALIDATE"' .not_tested[$index] | not_tested_digest_input' \
		"$OPT_JSON_FILE" >"$ENTRY_FILE"; then
		error "failed to read not_tested in $OPT_JSON_FILE"
		exit 1
	fi
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	ENTRY_SHA256=$(sha256_of "$ENTRY_FILE") || {
		error "cannot compute the entry's SHA-256 (install shasum, sha256sum, or openssl)"
		exit 1
	}
	case "$ENTRY_SHA256" in
		"$OPT_EXPECT_SHA"*) : ;;
		*)
			ENTRY_WHAT=$(jq -r --argjson index "$WAIVE_INDEX" '.not_tested[$index].what | tojson' "$OPT_JSON_FILE") || ENTRY_WHAT="(unreadable)"
			usage >&2
			error "invalid --expect-sha $OPT_EXPECT_SHA: Not tested $OPT_WAIVE_NUMBER is now $(printf '%.12s' "$ENTRY_SHA256") ($ENTRY_WHAT), not the entry the handle names (re-read the handles with test-plan-recheck.sh --list-not-tested); no changes made"
			exit 2
			;;
	esac

	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	WAIVE_REFUSAL=$(jq -r --argjson index "$WAIVE_INDEX" "$JQ_VALIDATE"'
		if .not_tested[$index].waived_by_human == true then "names an entry already waived (a waiver is recorded once)"
		else empty end' "$OPT_JSON_FILE") || {
		error "failed to read not_tested in $OPT_JSON_FILE"
		exit 1
	}
	if [ -n "$WAIVE_REFUSAL" ]; then
		usage >&2
		error "invalid --waive-not-tested $OPT_WAIVE_NUMBER: it $WAIVE_REFUSAL; no changes made"
		exit 2
	fi

	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	JQ_WAIVE="$JQ_VALIDATE"'
	approved_baseline_after_amend($baseline_digests) as $baseline
	| waive_not_tested($index; $reason)
	| { schema_version, id, status: "challenged", created }
	  + (if has("diff_files") then { diff_files } else {} end)
	  + (if has("snapshot") then { snapshot } else {} end)
	  + plan_body(.)
	  + { reviewer, amendments }
	  + $baseline
	'
	TMP_FILE=$(mktemp "$PLAN_DIR/.tmp.$PLAN_BASE.XXXXXX")
	if ! jq --argjson index "$WAIVE_INDEX" --arg reason "$OPT_REASON" --argjson baseline_digests "$BASELINE_DIGESTS" \
		"$JQ_WAIVE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
		error "failed to build the waived test plan"
		exit 1
	fi
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	WAIVED_ERRORS=$(jq -r "$JQ_VALIDATE"' plan_document_errors[]' "$TMP_FILE") || {
		error "failed to run the plan validator"
		exit 1
	}
	if [ -n "$WAIVED_ERRORS" ]; then
		error "internal: the waived test plan failed validation: $WAIVED_ERRORS"
		exit 1
	fi
	publish_staged_plan
	exit 0
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
	"$JQ_VALIDATE"' amend_input_errors($stored_arr[0]; $diff_files_arr[0])[]' "$OPT_FIELDS_FILE") || {
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
# Merge: stamped keys and snapshot kept from the stored plan, diff_files from
# --diff-files, the body rebuilt by the lib's shared plan_body with each
# stored waiver kept on an unchanged entry, the reviewer by
# amended_reviewer, amendments appended, status → challenged, and
# approved_at dropped by simply not being rebuilt.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_MERGE="$JQ_VALIDATE"'
$fields_arr[0] as $fields
| .not_tested as $stored_not_tested
| { schema_version, id, status: "challenged", created, diff_files: $diff_files_arr[0] }
  + (if has("snapshot") then { snapshot } else {} end)
  + (plan_body($fields) | carry_waivers($stored_not_tested))
  + { reviewer: amended_reviewer($fields),
      amendments: ((.amendments // []) + $fields.amendments) }
  + approved_baseline_after_amend($baseline_digests)
'

TMP_FILE=$(mktemp "$PLAN_DIR/.tmp.$PLAN_BASE.XXXXXX")

if ! jq --slurpfile fields_arr "$OPT_FIELDS_FILE" --slurpfile diff_files_arr "$DIFF_FILES_JSON" \
	--argjson baseline_digests "$BASELINE_DIGESTS" "$JQ_MERGE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to build the amended test plan"
	exit 1
fi

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
MERGED_ERRORS=$(jq -r "$JQ_VALIDATE"' plan_document_errors[]' "$TMP_FILE") || {
	error "failed to run the plan validator"
	exit 1
}
if [ -n "$MERGED_ERRORS" ]; then
	usage >&2
	report_validation_errors "--fields-file (merged with the stored plan)" "$MERGED_ERRORS"
	exit 2
fi

publish_staged_plan
exit 0
