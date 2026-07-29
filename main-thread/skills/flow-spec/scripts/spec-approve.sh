#!/usr/bin/env sh
#
# spec-approve.sh — flip an existing flow-spec artifact's status from
#                   "draft" to "approved", stamping approved_by/approved_at.
#
# WHY no lock (unlike the GTD inbox scripts): a flow-spec artifact is a
# one-file-per-effort document, approved exactly once, by exactly one
# orchestrator turn — there is no concurrent writer to mutually exclude
# against. What IS kept is the same loud-failure discipline: approving
# anything but a "draft" spec is refused outright (never a silent
# re-approval), and the rewrite is still an atomic same-directory mktemp+mv
# so a crash mid-write never leaves a truncated or partially-approved
# document behind.
#
# Usage:
#   spec-approve.sh --json-file PATH --approved-by NAME [-h|--help]
#
#     --json-file PATH    The spec-document JSON to approve (required). Must
#                           exist, be readable, contain a single well-formed
#                           JSON object with status == "draft".
#     --approved-by NAME   Free text identifying who approved it (required).
#     -h, --help           Show this help.
#
#   "created" is NEVER changed. "status" becomes "approved"; "approved_by"
#   and "approved_at" (a fresh UTC instant) are added.
#
# Output:
#   The file at --json-file is rewritten in place (atomic same-directory
#   mktemp+mv). On success, stdout carries the machine-parseable key:
#     SPEC_JSON=<absolute path>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  approved
#   1  jq absent / --json-file not valid JSON or not an object / status is
#      not "draft" / write failure
#   2  usage error (missing/invalid argument; --json-file missing or
#      unreadable)
#
# Env:
#   None — the path is supplied via a required argument.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (date, mktemp, mv, pwd, dirname, basename) are assumed present.
#   Self-contained: sources nothing.
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
Usage: $PROG --json-file PATH --approved-by NAME [-h|--help]

Flip an existing flow-spec artifact's status from "draft" to "approved",
stamping approved_by and a fresh UTC approved_at. Refuses to act on
anything but a "draft" spec.

Options:
  --json-file PATH    The spec-document JSON to approve (required).
  --approved-by NAME   Who approved it (required).
  -h, --help           Show this help.

On success, prints:
  SPEC_JSON=<absolute path>

Exit codes:
  0  approved
  1  jq absent / invalid JSON or shape / status is not "draft" / write
     failure
  2  usage error (bad argument, --json-file missing or unreadable)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# to_abs_path PATH — see spec-create.sh for the full rationale (duplicated
# verbatim; self-contained scripts, no sourcing between siblings).
to_abs_path() {
	case "$1" in
		/*) printf '%s' "$1" ;;
		*)  printf '%s/%s' "$(pwd)" "$1" ;;
	esac
}

# ---------------------------------------------------------------------------
# Cleanup: remove the rewrite's own temp file on any exit path. No lock to
# release (see the WHY note above the header). INT/TERM trapped separately
# from EXIT so an interrupted run reports the conventional 130/143 rather
# than whatever the last command before the signal happened to return.
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
OPT_JSON_FILE=""
OPT_APPROVED_BY=""

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)     need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--approved-by)   need_arg "$1" "${2:-}"; OPT_APPROVED_BY=$2; shift ;;
		-h|--help)       usage; exit 0 ;;
		--)              shift; break ;;
		-*)              usage >&2; error "unknown option: $1"; exit 2 ;;
		*)               usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_JSON_FILE" ]    || { usage >&2; error "--json-file is required"; exit 2; }
[ -n "$OPT_APPROVED_BY" ]  || { usage >&2; error "--approved-by is required"; exit 2; }

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

if ! jq -e . "$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "--json-file is not valid JSON: $OPT_JSON_FILE"
	exit 1
fi

if [ "$(jq -r 'type' "$OPT_JSON_FILE")" != "object" ]; then
	error "--json-file must contain a single JSON object: $OPT_JSON_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# Assert status == "draft" BEFORE writing anything — never a silent
# re-approval of an already-approved or superseded spec.
# ---------------------------------------------------------------------------
CURRENT_STATUS=$(jq -r '.status // empty' "$OPT_JSON_FILE")
if [ "$CURRENT_STATUS" != "draft" ]; then
	error "refusing to approve: status is '${CURRENT_STATUS:-<missing>}', not 'draft': $OPT_JSON_FILE"
	exit 1
fi

APPROVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------------------
# Rewrite. approved_by/approved_at travel via --arg into a STATIC jq
# program; "created" is untouched (never assigned).
# ---------------------------------------------------------------------------
UPDATED_DOC=$(jq -c \
	--arg approved_by "$OPT_APPROVED_BY" \
	--arg approved_at "$APPROVED_AT" \
	'.status = "approved" | .approved_by = $approved_by | .approved_at = $approved_at' \
	"$OPT_JSON_FILE")

if ! printf '%s' "$UPDATED_DOC" | jq -e . >/dev/null 2>&1; then
	error "internal: updated spec JSON failed to validate (this should never happen)"
	exit 1
fi

JSON_DIR=$(dirname "$OPT_JSON_FILE")
JSON_BASE=$(basename "$OPT_JSON_FILE")

TMP_FILE=$(mktemp "$JSON_DIR/.$JSON_BASE.XXXXXX")
printf '%s\n' "$UPDATED_DOC" >"$TMP_FILE"
mv "$TMP_FILE" "$OPT_JSON_FILE"
TMP_FILE=""

printf 'SPEC_JSON=%s\n' "$(to_abs_path "$OPT_JSON_FILE")"
exit 0
