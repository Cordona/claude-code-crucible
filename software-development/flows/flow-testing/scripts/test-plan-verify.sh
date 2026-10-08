#!/usr/bin/env sh
#
# test-plan-verify.sh — confirm an APPROVED flow-testing test plan is still
#                       byte-for-byte the plan the human approved. Read-only.
#
# WHY not re-render (flow-testing §4a): render-md.sh validates against the
# CURRENT validator before printing a digest, so a validator tightened after
# approval (a shorter text cap, say) makes an unchanged, approved plan fail
# and print no digest. Integrity is a property of the bytes, not of today's
# rules: this script hashes the file and reads only its status — no schema
# validation — so an approved plan keeps verifying however the rules move.
#
# WHY the digest test-plan-approve.sh printed, not render-md.sh's: approval
# rewrites the file (status → approved, approved_at stamped), so the bytes the
# human was shown no longer exist once approved. test-plan-approve.sh binds
# the two: it refuses unless the shown bytes are intact, then prints the
# digest of the approved file it published. That is --expect-sha256 here.
#
# WHY one private copy: the digest and the status are read from the same
# bytes, so a plan swapped between the two reads can never verify.
#
# Usage: see --help.
#
# Output:
#   Nothing is written. On success, stdout carries the machine-parseable key:
#     TEST_PLAN_SHA256=<SHA-256 of the plan file's bytes>
#   Diagnostics go to stderr, one line per failure.
#
# Exit codes:
#   0  verified: the digest matches and status is "approved"
#   1  jq absent / no SHA-256 tool (shasum, sha256sum, openssl) / the plan's
#      SHA-256 is not --expect-sha256 / --json-file not valid JSON or not one
#      document / status is not "approved"
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
#   coreutils (cat, mktemp, rm) are assumed present, plus one of shasum,
#   sha256sum or openssl for the digest (fails closed when none is). Depends
#   on nothing outside this script — it deliberately does not read
#   lib/test-plan-validate.jq.
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
Usage: $PROG --json-file PATH --expect-sha256 HEX [-h|--help]

Verify an approved test plan is unchanged: its SHA-256 must equal the one
test-plan-approve.sh printed, and its status must be "approved". Reads the
plan only; never validates it against the current schema.

Options:
  --json-file PATH       The stored, approved test plan (required).
  --expect-sha256 HEX    test-plan-approve.sh's TEST_PLAN_SHA256 for that
                           plan (required).
  -h, --help             Show this help.

On success, prints:
  TEST_PLAN_SHA256=<SHA-256 of the plan file>

Exit codes:
  0  verified
  1  jq absent / no SHA-256 tool / digest mismatch / not one JSON document /
     status is not "approved"
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
[ -n "$OPT_EXPECT_SHA256" ] || { usage >&2; error "--expect-sha256 is required (the TEST_PLAN_SHA256 test-plan-approve.sh printed)"; exit 2; }

# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
if ! is_sha256_hex "$OPT_EXPECT_SHA256"; then
	usage >&2
	error "--expect-sha256 must be 64 lowercase hex digits, as test-plan-approve.sh prints it"
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

# ---------------------------------------------------------------------------
# Cleanup: remove the private plan copy on any exit path. Registered before
# mktemp runs. INT/TERM trapped separately from EXIT so an interrupted run
# reports 130/143.
# ---------------------------------------------------------------------------
PLAN_COPY=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$PLAN_COPY" ] || rm -f "$PLAN_COPY" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# The ONE read of the plan file, into a 0600 mktemp copy.
# ---------------------------------------------------------------------------
PLAN_COPY=$(mktemp "${TMPDIR:-/tmp}/test-plan-verify.XXXXXX")
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
	error "the plan changed since it was approved (expected SHA-256 $OPT_EXPECT_SHA256, found $PLAN_SHA256) — stop and tell the human: $OPT_JSON_FILE"
	exit 1
fi

if ! jq -s -e 'length == 1' "$PLAN_COPY" >/dev/null 2>&1; then
	error "--json-file is not exactly ONE JSON document: $OPT_JSON_FILE"
	exit 1
fi

# Only a known status is echoed back, so no byte of the file reaches stderr.
PLAN_STATUS=$(jq -r 'if type == "object" and (.status | IN("draft", "challenged", "approved")) then .status else "(unknown)" end' "$PLAN_COPY") || {
	error "failed to read the plan status: $OPT_JSON_FILE"
	exit 1
}
if [ "$PLAN_STATUS" != "approved" ]; then
	error "the plan is not approved (status '$PLAN_STATUS') — pass the TEST_PLAN_SHA256 test-plan-approve.sh printed, not render-md.sh's: $OPT_JSON_FILE"
	exit 1
fi

printf 'TEST_PLAN_SHA256=%s\n' "$PLAN_SHA256"
exit 0
