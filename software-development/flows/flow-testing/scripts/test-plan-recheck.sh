#!/usr/bin/env sh
#
# test-plan-recheck.sh — record the outcome of re-checking ONE not_tested entry
#                        of a flow-testing test plan, in the plan's SIDECAR
#                        (<id>.recheck.json beside <id>.json), never in the
#                        plan itself.
#
# WHY a sidecar: an exclusion is looked at again after the plan is written —
# often after it is approved — and recording that in the plan would change
# the bytes the human approved, reopening the plan (test-plan-amend.sh) and
# its approval digest. The sidecar leaves the plan bytes, and so its SHA-256,
# untouched; render-md.sh --recheck-file shows each re-check beside its
# entry. A plan never carries a re-check of its own.
#
# WHY once per entry: a re-check outcome — survived, cleared, or escalated to
# the human — is recorded once, so a second look cannot quietly replace the
# first. A pending re-check is no outcome: it marks the entry as being looked
# at again, and the entry's next re-check (pending or an outcome) replaces
# it, as review-update-status.sh does for a review item.
#
# WHY the human closes an escalated entry here: an escalation hands the
# entry to the human, who may keep it untested — --recheck dismissed
# --reason, in their own words — whatever its category. The dismissal is a
# second record after the escalated one, never a replacement, so both the
# escalation and the human's answer stay on record; it is accepted only
# while the entry's latest record is escalated.
#
# WHY a proof for survived and cleared, a reason for escalated, neither for
# pending: an outcome
# the re-check settled carries the evidence that settled it — a file:line
# that exists under --repo-root, with that line, or a test the plan holds —
# from the reviewer or the review-arbiter, who have no shell, so never a
# "ran ..." proof. An escalated one is unsettled: it carries the reason the
# re-check escalated it to the human (the verifier's or the adversary's
# unresolved disagreement), in plain words.
#
# WHY --expect-sha: the Not tested number N moves when an amendment adds or
# removes a test, a restored proposal or an entry, so N alone could land the
# outcome on a different entry than the one re-checked. --expect-sha names
# the entry by a prefix of its entry_sha256, read from --list-not-tested, and
# the record is refused when the entry at N has another digest.
#
# WHY each record holds the entry's digest: a record is matched to the
# entry it re-checked by entry_sha256, the SHA-256 of that entry as
# `jq -S -c` prints it with the waiver keys removed, so an amendment that
# renumbers not_tested, or changes the entry, can never move a re-check onto
# another entry (or onto the changed one) — the same rule carry_waivers keeps
# for a waiver. A waiver added later does not change the digest.
#
# WHY no lock (unlike the GTD inbox scripts): a test plan and its sidecar
# are one-file-per-effort documents with a single orchestrator writer. The
# sidecar is replaced by a same-directory mktemp + mv: atomic, never a
# truncated file. Its mode is 0666 masked by the CALLER'S OWN umask, never a
# forced mode.
#
# Usage: see --help.
#
# Output:
#   With --list-not-tested, stdout carries one line per not_tested entry:
#     N<TAB>sha12<TAB>category<TAB>what
#   N its Not tested number, sha12 the first 12 hex digits of its
#   entry_sha256, category "-" when it has none. Nothing is written.
#   Otherwise the sidecar <plan dir>/<id>.recheck.json is created or replaced
#   atomically: {schema_version, plan, rechecks: [{not_tested, what,
#   entry_sha256, status, [proof | reason], recorded}]} (a dismissed record
#   follows its entry's escalated one). On success, stdout
#   carries the machine-parseable key:
#     TEST_PLAN_RECHECK_JSON=<absolute path>
#   Diagnostics go to stderr; each validation failure names its field path.
#
# Exit codes:
#   0  recorded
#   1  jq absent / shared jq library unreadable / --json-file not valid JSON,
#      not one document, failing validation, or not named {id}.json / the
#      existing sidecar is invalid / no SHA-256 tool (shasum, sha256sum,
#      openssl) / write failure
#   2  usage error (missing/invalid argument; --json-file missing or
#      unreadable; --repo-root not a directory; a number naming no Not
#      tested entry; an --expect-sha the entry at that number does not
#      carry; an entry whose re-check outcome is already recorded; a
#      dismissal of an entry whose latest re-check is not escalated; an
#      invalid --recheck-proof, --recheck-reason or --reason, or a proof
#      naming no real file line or no test of the plan)
#
# Env:
#   TMPDIR — optional; selects the directory of the private entry copy the
#   digest is taken from (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (awk, basename, chmod, date, dirname, mktemp, mv, rm) are
#   assumed present, plus one of shasum, sha256sum or openssl for the entry
#   digest (fails closed when none is). Reads its validator from
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
Usage: $PROG --json-file PATH --not-tested N --expect-sha HEX
       --repo-root PATH --recheck survived|cleared --recheck-proof TEXT
       [-h|--help]
       $PROG --json-file PATH --not-tested N --expect-sha HEX
       --repo-root PATH --recheck escalated --recheck-reason TEXT
       $PROG --json-file PATH --not-tested N --expect-sha HEX
       --repo-root PATH --recheck pending
       $PROG --json-file PATH --not-tested N --expect-sha HEX
       --recheck dismissed --reason TEXT
       $PROG --json-file PATH --list-not-tested

Record the outcome of re-checking one not_tested entry in the plan's sidecar
(<id>.recheck.json beside the plan). The plan bytes, and so its SHA-256, are
never changed. Each entry's outcome is recorded once; a pending re-check is
replaced by the entry's next one; an escalated one is closed by your
dismissal.

Options:
  --json-file PATH       The stored test plan (required; any status).
  --list-not-tested      Print each not_tested entry's handle, one line
                           each: N<TAB>sha12<TAB>category<TAB>what (N its
                           Not tested number, sha12 the first 12 hex digits
                           of its entry_sha256, category "-" when it has
                           none), and write nothing. Takes only --json-file.
  --not-tested N         The entry's Not tested number, as render-md.sh shows
                           it: the list is numbered on after the tests and
                           the rejected proposals (required).
  --expect-sha HEX       The entry's handle (required with --not-tested):
                           12 to 64 lowercase hex digits, a prefix of its
                           entry_sha256 as --list-not-tested prints it. The
                           record is refused when the entry at N has another
                           digest (the numbers moved, or the entry changed).
  --repo-root PATH       The repository top level every file:line in the
                           proof resolves under (required, except with
                           --recheck dismissed).
  --recheck VALUE        pending|survived|cleared|escalated|dismissed
                           (required). pending takes neither
                           --recheck-proof nor --recheck-reason and is
                           shown as "Re-check: pending" until the entry's
                           next re-check replaces it. dismissed is your
                           closing of an entry whose latest re-check
                           escalated it to you, of any category: it takes
                           --reason, is recorded after the escalated
                           record, and is shown as "Kept untested by you —
                           <reason>".
  --recheck-proof TEXT   With survived or cleared: the evidence of the
                           outcome, one line of at most 100 characters naming
                           a file:line (src/a.rs:42, Makefile:3; the file has
                           an extension or a "/", or is Makefile, Dockerfile,
                           Justfile, Rakefile, Gemfile or Procfile) that
                           exists under --repo-root with that line, or a
                           test of the plan (Covered by test 3).
  --recheck-reason TEXT  With escalated: why the re-check escalated the
                           entry to the human (the verifier's or the
                           adversary's unresolved disagreement), in plain
                           words (one line of at most 200 characters).
  --reason TEXT          With dismissed: your reason for keeping the entry
                           untested, in your words (one line of at most 200
                           characters).
  -h, --help             Show this help.

On success, prints:
  TEST_PLAN_RECHECK_JSON=<absolute path>

Exit codes:
  0  recorded
  1  jq absent / invalid stored plan or sidecar / no SHA-256 tool / write
     failure
  2  usage error (bad argument, unreadable --json-file, no entry with the
     number, an --expect-sha the entry does not carry, an outcome already
     recorded, a dismissal of an entry not escalated, an invalid or unreal
     proof, an invalid reason)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

usage_error() {
	usage >&2
	error "$*"
	exit 2
}

# sha256_of FILE — print FILE's SHA-256 as 64 lowercase hex digits, using the
# first installed of shasum (macOS, most Linux), sha256sum (GNU/busybox) or
# openssl. Returns 1 when none is installed or the tool's output is not a
# digest — the caller fails closed. Duplicated verbatim in render-md.sh,
# test-plan-approve.sh and test-plan-verify.sh (self-contained scripts, no
# sourcing between siblings).
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

# report_validation_errors LABEL ERRORS — one stderr line per
# newline-separated field-path error.
report_validation_errors() {
	_label=$1
	printf '%s\n' "$2" | while IFS= read -r validation_error; do
		error "invalid $_label: $validation_error"
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
OPT_NOT_TESTED=""
OPT_REPO_ROOT=""
OPT_RECHECK=""
OPT_RECHECK_PROOF=""
OPT_RECHECK_REASON=""
OPT_EXPECT_SHA=""
OPT_REASON=""
HAS_RECHECK_PROOF=false
HAS_RECHECK_REASON=false
HAS_REASON=false
LIST_NOT_TESTED=false

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)      need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--not-tested)     need_arg "$1" "${2:-}"; OPT_NOT_TESTED=$2; shift ;;
		--repo-root)      need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--recheck)        need_arg "$1" "${2:-}"; OPT_RECHECK=$2; shift ;;
		--recheck-proof)  need_arg "$1" "${2:-}"; OPT_RECHECK_PROOF=$2; HAS_RECHECK_PROOF=true; shift ;;
		--recheck-reason) need_arg "$1" "${2:-}"; OPT_RECHECK_REASON=$2; HAS_RECHECK_REASON=true; shift ;;
		--expect-sha)     need_arg "$1" "${2:-}"; OPT_EXPECT_SHA=$2; shift ;;
		--reason)         need_arg "$1" "${2:-}"; OPT_REASON=$2; HAS_REASON=true; shift ;;
		--list-not-tested) LIST_NOT_TESTED=true ;;
		-h|--help)        usage; exit 0 ;;
		--)               shift; break ;;
		-*)               usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || usage_error "unexpected argument: $1"

[ -n "$OPT_JSON_FILE" ]  || usage_error "--json-file is required"

if [ "$LIST_NOT_TESTED" = true ]; then
	if [ -n "$OPT_NOT_TESTED" ] || [ -n "$OPT_REPO_ROOT" ] || [ -n "$OPT_RECHECK" ] || [ -n "$OPT_EXPECT_SHA" ] ||
		[ "$HAS_RECHECK_PROOF" = true ] || [ "$HAS_RECHECK_REASON" = true ] || [ "$HAS_REASON" = true ]; then
		usage_error "--list-not-tested takes only --json-file"
	fi
else
	[ -n "$OPT_NOT_TESTED" ] || usage_error "--not-tested is required"
	[ -n "$OPT_EXPECT_SHA" ] || usage_error "--expect-sha is required (the entry's handle, from --list-not-tested)"
	[ -n "$OPT_RECHECK" ]    || usage_error "--recheck is required"
	[ -n "$OPT_REPO_ROOT" ] || [ "$OPT_RECHECK" = dismissed ] ||
		usage_error "--repo-root is required (the repository top level a proof's file:line resolves under)"
fi

case "$OPT_NOT_TESTED" in
	*[!0-9]*|0*) usage_error "invalid --not-tested: $OPT_NOT_TESTED (expected the entry's Not tested number, an integer >= 1, no leading zeros)" ;;
	*) : ;;
esac

case "$OPT_EXPECT_SHA" in
	*[!0-9a-f]*) usage_error "invalid --expect-sha: $OPT_EXPECT_SHA (expected 12 to 64 lowercase hex digits, the handle --list-not-tested prints)" ;;
	*) : ;;
esac
if [ -n "$OPT_EXPECT_SHA" ] && { [ "${#OPT_EXPECT_SHA}" -lt 12 ] || [ "${#OPT_EXPECT_SHA}" -gt 64 ]; }; then
	usage_error "invalid --expect-sha: $OPT_EXPECT_SHA (expected 12 to 64 lowercase hex digits, the handle --list-not-tested prints)"
fi

# survived and cleared carry the proof of their outcome, escalated the
# reason the re-check escalated the entry to the human, dismissed the
# human's own reason (see the header WHY).
if [ "$HAS_REASON" = true ] && [ "$OPT_RECHECK" != dismissed ]; then
	usage_error "--reason is given only with --recheck dismissed (your reason, in your words)"
fi
case "$OPT_RECHECK" in
	pending)
		[ "$HAS_RECHECK_PROOF" = false ] && [ "$HAS_RECHECK_REASON" = false ] ||
			usage_error "--recheck pending takes no --recheck-proof or --recheck-reason (a pending re-check has no outcome yet)"
		;;
	survived|cleared)
		[ "$HAS_RECHECK_PROOF" = true ] ||
			usage_error "--recheck $OPT_RECHECK requires --recheck-proof (the file:line or test that shows the outcome)"
		[ "$HAS_RECHECK_REASON" = false ] ||
			usage_error "--recheck-reason is given only with --recheck escalated"
		;;
	escalated)
		[ "$HAS_RECHECK_REASON" = true ] ||
			usage_error "--recheck escalated requires --recheck-reason (why the re-check escalated it to the human: the verifier's or the adversary's unresolved disagreement, in plain words)"
		[ "$HAS_RECHECK_PROOF" = false ] ||
			usage_error "--recheck escalated takes --recheck-reason, not --recheck-proof"
		;;
	dismissed)
		[ "$HAS_REASON" = true ] ||
			usage_error "--recheck dismissed requires --reason (your reason for keeping the entry untested, in your words)"
		[ "$HAS_RECHECK_PROOF" = false ] && [ "$HAS_RECHECK_REASON" = false ] ||
			usage_error "--recheck dismissed takes --reason (your words), not --recheck-proof or --recheck-reason"
		;;
	'') : ;;
	*) usage_error "invalid --recheck: $OPT_RECHECK (expected pending|survived|cleared|escalated|dismissed)" ;;
esac

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	usage_error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
fi

PHYSICAL_REPO_ROOT=""
if [ -n "$OPT_REPO_ROOT" ]; then
	[ -d "$OPT_REPO_ROOT" ] || usage_error "--repo-root does not exist or is not a directory: $OPT_REPO_ROOT"
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

# The proof or reason: plan text, the proof in a plan proof form. The value
# travels via --arg and is never echoed back.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
OUTCOME_ERRORS=$(jq -n -r --argjson has_proof "$HAS_RECHECK_PROOF" --arg proof "$OPT_RECHECK_PROOF" \
	--argjson has_reason "$HAS_RECHECK_REASON" --arg reason "$OPT_RECHECK_REASON" \
	--argjson has_human_reason "$HAS_REASON" --arg human_reason "$OPT_REASON" "$JQ_VALIDATE"'
	if $has_proof then $proof | proof_errors("--recheck-proof"; plan_proof_forms)[]
	elif $has_reason then $reason | reason_errors("--recheck-reason")[]
	elif $has_human_reason then $human_reason | reason_errors("--reason")[]
	else empty end') || {
	error "failed to run the plan validator"
	exit 1
}
if [ -n "$OUTCOME_ERRORS" ]; then
	usage >&2
	printf '%s\n' "$OUTCOME_ERRORS" | while IFS= read -r outcome_error; do
		error "invalid $outcome_error"
	done
	exit 2
fi

# ---------------------------------------------------------------------------
# The stored plan: one valid document, named {id}.json. Every failure here is
# the artifact's state, not the caller's arguments — exit 1.
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
SIDECAR_FILE=$PLAN_DIR/$PLAN_ID.recheck.json

# ---------------------------------------------------------------------------
# Cleanup: remove the entry copy and the staged sidecar on any exit path.
# ---------------------------------------------------------------------------
ENTRY_FILE=""
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$ENTRY_FILE" ] || rm -f "$ENTRY_FILE" 2>/dev/null || true
	[ -z "$TMP_FILE" ]   || rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

ENTRY_FILE=$(mktemp "${TMPDIR:-/tmp}/test-plan-recheck.entry.XXXXXX")

# entry_sha256_at INDEX — print the entry_sha256 of not_tested[INDEX]
# (0-based): the SHA-256 of the entry as `jq -S -c` prints it, waiver keys
# removed (see the WHY block above).
entry_sha256_at() {
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	jq -S -c --argjson index "$1" "$JQ_VALIDATE"' .not_tested[$index] | not_tested_digest_input' \
		"$OPT_JSON_FILE" >"$ENTRY_FILE" || return 1
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	sha256_of "$ENTRY_FILE"
}

# --list-not-tested: each entry's handle, numbered as render-md.sh shows it.
if [ "$LIST_NOT_TESTED" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	NOT_TESTED_ROWS=$(jq -r "$JQ_VALIDATE"'
		not_tested_number_offset as $offset
		| .not_tested | to_entries[]
		| "\(.key)\t\($offset + .key + 1)\t\(.value.category // "-")\t\(.value.what)"' "$OPT_JSON_FILE") || {
		error "failed to read not_tested in $OPT_JSON_FILE"
		exit 1
	}
	[ -n "$NOT_TESTED_ROWS" ] || exit 0
	printf '%s\n' "$NOT_TESTED_ROWS" | while IFS="$TAB" read -r row_index row_number row_category row_what; do
		# shellcheck disable=SC2310  # entry_sha256_at returns an explicit status at every step; set -e is not relied on inside it
		row_sha256=$(entry_sha256_at "$row_index") || {
			error "cannot compute a not_tested entry's SHA-256 (install shasum, sha256sum, or openssl)"
			exit 1
		}
		printf '%s\t%.12s\t%s\t%s\n' "$row_number" "$row_sha256" "$row_category" "$row_what"
	done
	exit 0
fi

# The proof points at something real: each test number a test of the plan,
# each file:line a real line under --repo-root.
if [ "$HAS_RECHECK_PROOF" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	PROOF_TEST_PROBLEMS=$(jq -r --arg proof "$OPT_RECHECK_PROOF" "$JQ_VALIDATE"'
		(.tests | length) as $test_count | $proof | proof_test_errors("--recheck-proof"; $test_count)[]' "$OPT_JSON_FILE") || {
		error "failed to read the proof"
		exit 1
	}
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	PROOF_LOCATORS=$(jq -n -r --arg proof "$OPT_RECHECK_PROOF" "$JQ_VALIDATE"'
		$proof | proof_locators[] | "--recheck-proof\t\(.file)\t\(.start)\t\(.end)"') || {
		error "failed to read the proof"
		exit 1
	}
	PROOF_PROBLEMS=$(
		printf '%s\n' "$PROOF_TEST_PROBLEMS"
		printf '%s\n' "$PROOF_LOCATORS" | sed '/^$/d' | proof_locator_problems
	)
	PROOF_PROBLEMS=$(printf '%s\n' "$PROOF_PROBLEMS" | sed '/^$/d')
	if [ -n "$PROOF_PROBLEMS" ]; then
		usage >&2
		printf '%s\n' "$PROOF_PROBLEMS" | while IFS= read -r proof_problem; do
			error "invalid $proof_problem"
		done
		exit 2
	fi
fi

# ---------------------------------------------------------------------------
# The existing sidecar, when there is one, must be valid for this plan; the
# new re-check is judged against it.
# ---------------------------------------------------------------------------
if [ -e "$SIDECAR_FILE" ]; then
	SIDECAR_ERRORS=$(jq -r --arg plan_id "$PLAN_ID" \
		"$JQ_VALIDATE"' recheck_sidecar_errors($plan_id)[]' "$SIDECAR_FILE" 2>/dev/null) || SIDECAR_ERRORS="(root): not valid JSON"
	if [ -n "$SIDECAR_ERRORS" ]; then
		report_validation_errors "$SIDECAR_FILE" "$SIDECAR_ERRORS"
		exit 1
	fi
	SIDECAR_ARG=$SIDECAR_FILE
else
	SIDECAR_ARG=/dev/null
fi

# The Not tested number to the entry's index (render-md.sh numbers the list
# on after the tests and the rejected proposals); compared inside jq, so a
# number too large for shell arithmetic fails closed.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
ENTRY_INDEX=$(jq -r --argjson number "$OPT_NOT_TESTED" "$JQ_VALIDATE"'
	not_tested_number_offset as $offset
	| if $number <= $offset or $number > $offset + (.not_tested | length) then "none" else $number - $offset - 1 end' "$OPT_JSON_FILE") || {
	error "failed to read not_tested in $OPT_JSON_FILE"
	exit 1
}
[ "$ENTRY_INDEX" != none ] || usage_error "invalid --not-tested $OPT_NOT_TESTED: it names no Not tested entry (see the number render-md.sh shows); no changes made"

# The entry digest the record is matched by (see the WHY block above), and
# the handle the caller read must still name the entry at that number.
# shellcheck disable=SC2310  # entry_sha256_at returns an explicit status at every step; set -e is not relied on inside it
ENTRY_SHA256=$(entry_sha256_at "$ENTRY_INDEX") || {
	error "cannot compute the entry's SHA-256 (install shasum, sha256sum, or openssl)"
	exit 1
}
case "$ENTRY_SHA256" in
	"$OPT_EXPECT_SHA"*) : ;;
	*)
		ENTRY_WHAT=$(jq -r --argjson index "$ENTRY_INDEX" '.not_tested[$index].what | tojson' "$OPT_JSON_FILE") || ENTRY_WHAT="(unreadable)"
		usage_error "invalid --expect-sha $OPT_EXPECT_SHA: Not tested $OPT_NOT_TESTED is now $(printf '%.12s' "$ENTRY_SHA256") ($ENTRY_WHAT), not the entry the handle names (re-read the handles with --list-not-tested); no changes made"
		;;
esac

# The status of the entry's latest record, "none" without one.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
LATEST_STATUS=$(jq -n -r --arg entry_sha256 "$ENTRY_SHA256" --slurpfile sidecar_arr "$SIDECAR_ARG" '
	[($sidecar_arr[0].rechecks // [])[] | select(.entry_sha256 == $entry_sha256) | .status] | last // "none"') || {
	error "failed to read the re-check sidecar"
	exit 1
}
if [ "$OPT_RECHECK" = dismissed ]; then
	[ "$LATEST_STATUS" = escalated ] ||
		usage_error "invalid --recheck dismissed: Not tested $OPT_NOT_TESTED has no escalated re-check to close (its latest re-check is $LATEST_STATUS); only an entry whose re-check escalated it to you is dismissed; no changes made"
else
	case "$LATEST_STATUS" in
		none|pending) : ;;
		*) usage_error "invalid --not-tested $OPT_NOT_TESTED: it names an entry whose re-check outcome is already recorded in the sidecar (an outcome is recorded once); no changes made" ;;
	esac
fi

TODAY=$(date -u +%Y-%m-%d)

# The entry's pending record, when there is one, gives way to this one; a
# dismissal follows the escalated record it closes.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_SIDECAR='
.not_tested[$index].what as $what
| ($sidecar_arr[0] // {schema_version: "1.0", plan: .id, rechecks: []})
| (if $status == "dismissed" then . else .rechecks |= map(select(.entry_sha256 != $entry_sha256)) end)
| .rechecks += [{not_tested: $number, what: $what, entry_sha256: $entry_sha256, status: $status}
                + (if $has_proof then {proof: $proof}
                   elif $has_reason then {reason: $reason}
                   elif $status == "dismissed" then {reason: $human_reason}
                   else {} end)
                + {recorded: $today}]
'

TMP_FILE=$(mktemp "$PLAN_DIR/.tmp.$PLAN_ID.recheck.json.XXXXXX")
if ! jq --argjson index "$ENTRY_INDEX" --argjson number "$OPT_NOT_TESTED" --arg entry_sha256 "$ENTRY_SHA256" \
	--slurpfile sidecar_arr "$SIDECAR_ARG" --arg status "$OPT_RECHECK" \
	--argjson has_proof "$HAS_RECHECK_PROOF" --arg proof "$OPT_RECHECK_PROOF" \
	--argjson has_reason "$HAS_RECHECK_REASON" --arg reason "$OPT_RECHECK_REASON" \
	--arg human_reason "$OPT_REASON" \
	--arg today "$TODAY" "$JQ_SIDECAR" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to build the re-check sidecar"
	exit 1
fi

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
STAGED_ERRORS=$(jq -r --arg plan_id "$PLAN_ID" "$JQ_VALIDATE"' recheck_sidecar_errors($plan_id)[]' "$TMP_FILE") || {
	error "failed to run the plan validator"
	exit 1
}
if [ -n "$STAGED_ERRORS" ]; then
	error "internal: the staged re-check sidecar failed validation: $STAGED_ERRORS"
	exit 1
fi

CALLER_UMASK=$(umask)
FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$CALLER_UMASK ))")
if ! chmod "$FILE_MODE" "$TMP_FILE"; then
	error "failed to set mode $FILE_MODE on the staged sidecar: $TMP_FILE"
	exit 1
fi

if ! mv "$TMP_FILE" "$SIDECAR_FILE"; then
	error "failed to publish the re-check sidecar to: $SIDECAR_FILE"
	exit 1
fi
TMP_FILE=""

printf 'TEST_PLAN_RECHECK_JSON=%s\n' "$ABS_PLAN_DIR/$PLAN_ID.recheck.json"
exit 0
