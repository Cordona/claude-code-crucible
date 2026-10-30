#!/usr/bin/env sh
#
# test-plan-approve.sh — record the human's approval of a CHALLENGED
#                        flow-testing test plan: status → approved, approved_at
#                        stamped, approved_baseline removed. The plan's
#                        content is not changed.
#
# WHY challenged-only: approval follows the lens-test-quality-reviewer
# challenge (flow-testing §3). Refusing "draft" makes that order mechanical —
# no path reaches "approved" without test-plan-challenge.sh. Refusing
# "approved" keeps approval a single, deliberate act: a plan the human wants
# changed goes through test-plan-amend.sh, which returns it to "challenged" so
# the amended plan is rendered and shown before it is approved again.
#
# WHY --expect-sha256 and a private copy: the human approves the bytes
# render-md.sh showed them, but the plan file stays writable by whoever can
# reach its directory. This script reads the plan exactly ONCE, into a private
# temp file, refuses unless that copy's SHA-256 is the digest render-md.sh
# printed (TEST_PLAN_SHA256), and builds the approved plan only from the copy
# — so a plan swapped before, during, or after the check is never what gets
# approved. The digest of the published file is printed so the caller can
# confirm, before later dispatches, that the approved plan is still intact.
#
# WHY approval removes approved_baseline: the baseline is the plan as it was
# last approved, kept so an amended plan renders as a change to it
# (test-plan-amend.sh records it, render-md.sh shows the delta). Once the
# human approves the amended plan, that plan is the approved one and nothing
# is pending, so it must render as a plain plan; the next amend records a
# fresh baseline from it. Keeping the old one would show changes already
# approved as pending.
#
# WHY no lock (unlike the GTD inbox scripts): a test plan is a one-file-per-
# effort document with a single orchestrator writer. Replacement IS the
# intent here, so the publish is a same-directory mktemp + mv: atomic, never
# a truncated or half-approved plan. The published mode is 0666 masked by
# the CALLER'S OWN umask, never a forced mode.
#
# WHY an exclusion is judged before approval: nothing is set aside without
# the human seeing why. A plan whose not_tested holds an entry in a required
# test category (security, persisted-data, concurrency, authentication), or
# an unproven entry of any category, without waived_by_human is refused: the
# orchestrator asks the human, then records the waiver with
# test-plan-amend.sh --waive-not-tested, or the test is planned. A proven
# other entry needs no waiver. An entry without a category is not judged at
# all, so it is refused too, until an amend gives it one.
#
# Usage: see --help.
#
# Output:
#   The file at --json-file is replaced atomically. On success, stdout
#   carries the machine-parseable keys:
#     TEST_PLAN_JSON=<absolute path>
#     TEST_PLAN_SHA256=<SHA-256 of the published approved file>
#   Diagnostics go to stderr; each validation failure names its field path.
#
# Exit codes:
#   0  approved
#   1  jq absent / shared jq library unreadable / no SHA-256 tool (shasum,
#      sha256sum, openssl) / the plan's SHA-256 is not --expect-sha256 /
#      --json-file not valid JSON, not one document, failing validation, or
#      not named {id}.json / status is not "challenged" / a not_tested entry
#      in a required test category, or unproven, without the human waiver,
#      or without a category / write failure / internal assembly-validation
#      failure
#   2  usage error (missing/invalid/unknown argument; --json-file missing or
#      unreadable; --expect-sha256 missing or not 64 lowercase hex digits)
#
# Env:
#   TMPDIR — optional; selects the directory of the private plan copy
#   (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (basename, cat, chmod, date, dirname, mktemp, mv, rm) are
#   assumed present, plus one of shasum, sha256sum or openssl for the digest
#   (fails closed when none is). Reads its validator from
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
Usage: $PROG --json-file PATH --expect-sha256 HEX [-h|--help]

Approve a challenged test plan: set status to "approved", stamp today's
approved_at and remove approved_baseline — only if the plan's bytes still match the SHA-256 render-md.sh
printed for the plan the human approved. Refuses any other status — a draft
must be challenged first, and a change to an approved plan goes through
test-plan-amend.sh.

Options:
  --json-file PATH       The stored test plan (required; status must be
                           challenged).
  --expect-sha256 HEX    render-md.sh's TEST_PLAN_SHA256 for that plan
                           (required).
  -h, --help             Show this help.

On success, prints:
  TEST_PLAN_JSON=<absolute path>
  TEST_PLAN_SHA256=<SHA-256 of the published approved file>

Exit codes:
  0  approved
  1  jq absent / no SHA-256 tool / digest mismatch / invalid stored plan /
     status is not "challenged" / write failure
  2  usage error (bad argument, --json-file missing or unreadable,
     --expect-sha256 missing or malformed)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# sha256_of FILE — print FILE's SHA-256 as 64 lowercase hex digits, using the
# first installed of shasum (macOS, most Linux), sha256sum (GNU/busybox) or
# openssl. Returns 1 when none is installed or the tool's output is not a
# digest — the caller fails closed. Duplicated verbatim from render-md.sh
# (self-contained scripts, no sourcing between siblings).
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

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_JSON_FILE=""
OPT_EXPECT_SHA256=""

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)     need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--expect-sha256) need_arg "$1" "${2:-}"; OPT_EXPECT_SHA256=$2; shift ;;
		-h|--help)       usage; exit 0 ;;
		--)              shift; break ;;
		-*)              usage >&2; error "unknown option: $1"; exit 2 ;;
		*)               usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_JSON_FILE" ]     || { usage >&2; error "--json-file is required"; exit 2; }
[ -n "$OPT_EXPECT_SHA256" ] || { usage >&2; error "--expect-sha256 is required (the TEST_PLAN_SHA256 render-md.sh printed)"; exit 2; }

# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
if ! is_sha256_hex "$OPT_EXPECT_SHA256"; then
	usage >&2
	error "--expect-sha256 must be 64 lowercase hex digits, as render-md.sh prints it"
	exit 2
fi

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	usage >&2
	error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
	exit 2
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

PLAN_DIR=$(dirname "$OPT_JSON_FILE")
PLAN_BASE=$(basename "$OPT_JSON_FILE")
ABS_PLAN_DIR=$(cd "$PLAN_DIR" && pwd) || {
	error "cannot resolve the --json-file directory: $PLAN_DIR"
	exit 1
}

# ---------------------------------------------------------------------------
# Cleanup: remove the private plan copy and the staged temp file on any exit
# path. Registered before either mktemp runs. INT/TERM trapped separately
# from EXIT so an interrupted run reports 130/143.
# ---------------------------------------------------------------------------
PLAN_COPY=""
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$PLAN_COPY" ] || rm -f "$PLAN_COPY" 2>/dev/null || true
	[ -z "$TMP_FILE" ]  || rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# The ONE read of the plan file. mktemp creates the copy 0600, so nothing
# else can change it; every check and the build below read only the copy.
# ---------------------------------------------------------------------------
PLAN_COPY=$(mktemp "${TMPDIR:-/tmp}/test-plan-approve.XXXXXX")
if ! cat "$OPT_JSON_FILE" >"$PLAN_COPY"; then
	error "failed to read --json-file: $OPT_JSON_FILE"
	exit 1
fi

# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
PLAN_SHA256=$(sha256_of "$PLAN_COPY") || {
	error "cannot compute the plan's SHA-256 (install shasum, sha256sum, or openssl)"
	exit 1
}
if [ "$PLAN_SHA256" != "$OPT_EXPECT_SHA256" ]; then
	error "refusing to approve: the plan changed since it was rendered (expected SHA-256 $OPT_EXPECT_SHA256, found $PLAN_SHA256) — re-render it and ask the human again: $OPT_JSON_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# The stored plan: one valid document, named {id}.json, status challenged.
# Every failure here is the artifact's state, not the caller's arguments —
# exit 1.
# ---------------------------------------------------------------------------
if ! jq -e . "$PLAN_COPY" >/dev/null 2>&1; then
	error "--json-file is not valid JSON: $OPT_JSON_FILE"
	exit 1
fi

if ! jq -s -e 'length == 1' "$PLAN_COPY" >/dev/null 2>&1; then
	error "--json-file must hold exactly ONE JSON document: $OPT_JSON_FILE"
	exit 1
fi

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PLAN_ERRORS=$(jq -r "$JQ_VALIDATE"' plan_document_errors[]' "$PLAN_COPY") || {
	error "failed to run the plan validator"
	exit 1
}
if [ -n "$PLAN_ERRORS" ]; then
	report_validation_errors "--json-file" "$PLAN_ERRORS"
	exit 1
fi

PLAN_ID=$(jq -r '.id' "$PLAN_COPY")
if [ "$PLAN_BASE" != "$PLAN_ID.json" ]; then
	error "--json-file name '$PLAN_BASE' does not match its id '$PLAN_ID' (expected $PLAN_ID.json)"
	exit 1
fi

CURRENT_STATUS=$(jq -r '.status' "$PLAN_COPY")
case "$CURRENT_STATUS" in
	challenged) : ;;
	draft)
		error "refusing to approve: status is 'draft' — the reviewer challenge (test-plan-challenge.sh) must happen first: $OPT_JSON_FILE"
		exit 1
		;;
	*)
		error "refusing to approve: status is '$CURRENT_STATUS', not 'challenged' (change an approved plan with test-plan-amend.sh, then approve it again): $OPT_JSON_FILE"
		exit 1
		;;
esac

# Every exclusion is judged and, where it needs one, waived (see the header
# WHY).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
WAIVER_ERRORS=$(jq -r "$JQ_VALIDATE"' unwaived_category_errors[]' "$PLAN_COPY") || {
	error "failed to run the plan validator"
	exit 1
}
if [ -n "$WAIVER_ERRORS" ]; then
	report_validation_errors "--json-file" "$WAIVER_ERRORS"
	error "refusing to approve: an exclusion that needs the human waiver (a required test category, or unproven) has none, or an exclusion has no category: $OPT_JSON_FILE"
	exit 1
fi

APPROVED_AT=$(date -u +%Y-%m-%d)

# ---------------------------------------------------------------------------
# Rewrite from the verified copy: every stored field kept, in schema order;
# status → approved, approved_at fresh, approved_baseline not rebuilt (see
# the header WHY). diff_files and amendments are carried only when the plan
# has them.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_APPROVE="$JQ_VALIDATE"'
{ schema_version, id, status: "approved", created, approved_at: $approved_at }
+ (if has("diff_files") then { diff_files } else {} end)
+ (if has("snapshot") then { snapshot } else {} end)
+ plan_body(.)
+ { reviewer }
+ (if has("amendments") then { amendments } else {} end)
'

TMP_FILE=$(mktemp "$PLAN_DIR/.tmp.$PLAN_BASE.XXXXXX")

if ! jq --arg approved_at "$APPROVED_AT" "$JQ_APPROVE" "$PLAN_COPY" >"$TMP_FILE"; then
	error "failed to build the approved test plan"
	exit 1
fi

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
ASSEMBLED_ERRORS=$(jq -r "$JQ_VALIDATE"' plan_document_errors[]' "$TMP_FILE") || ASSEMBLED_ERRORS="validator failed to run"
if [ -n "$ASSEMBLED_ERRORS" ]; then
	error "internal: approved test plan failed validation (this should never happen): $ASSEMBLED_ERRORS"
	exit 1
fi

# Digest the staged bytes, not the published path: after the rename the path
# is writable again, and the digest must describe what this script wrote.
# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
APPROVED_SHA256=$(sha256_of "$TMP_FILE") || {
	error "cannot compute the approved plan's SHA-256"
	exit 1
}

CALLER_UMASK=$(umask)
FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$CALLER_UMASK ))")
if ! chmod "$FILE_MODE" "$TMP_FILE"; then
	error "failed to set mode $FILE_MODE on the staged plan: $TMP_FILE"
	exit 1
fi

if ! mv "$TMP_FILE" "$OPT_JSON_FILE"; then
	error "failed to publish the approved test plan to: $OPT_JSON_FILE"
	exit 1
fi
TMP_FILE=""

printf 'TEST_PLAN_JSON=%s\n' "$ABS_PLAN_DIR/$PLAN_BASE"
printf 'TEST_PLAN_SHA256=%s\n' "$APPROVED_SHA256"
exit 0
