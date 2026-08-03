#!/usr/bin/env sh
#
# process.sh — flip ONE inbox entry's is_processed under the shared lock,
#              optionally recording a note. Same-fs atomic rewrite.
#
# WHY assert exactly one match before writing anything: a typo'd
# --id must be a loud failure, never a silent success. This script counts
# matches across the WHOLE file, under the lock, and only replaces the log
# if the count is exactly 1 — on 0 or >1 matches it exits non-zero and the
# real inbox.jsonl is never touched (the scratch rewrite lives only in a
# temp file that gets discarded).
#
# WHY the rewrite temp lives inside gtd/, not /tmp: `mv` is only atomic
# within one filesystem. A cross-fs mv degrades to copy+unlink, which is
# NOT atomic and can leave a corrupted or truncated log if interrupted
# mid-copy. mktemp is created in the SAME directory as INBOX_FILE.
#
# WHY malformed lines are preserved verbatim on rewrite: a resilient reader
# skips them, but a WRITER must never silently drop user data it doesn't
# understand — every line that isn't the matched entry (well-formed or not)
# is copied through unchanged.
#
# Usage:
#   process.sh --id ID [--note-file PATH] [--unprocess] [-h|--help]
#
#     --id ID          The entry's id (required). Exactly one entry must
#                        match, or nothing is written.
#     --note-file PATH  Verbatim note text to attach (--rawfile, never a
#                        --note string flag — see capture.sh for why a file
#                        is required instead of an argv string).
#     --unprocess       Flip is_processed to false instead of true
#                        (naturally reversible triage). Also REMOVES the
#                        processed_ts stamp (a re-flip re-stamps it fresh).
#     -h, --help        Show this help.
#
#   When flipping TO processed, the entry gets a processed_ts field — the UTC
#   ISO-8601 instant of the flip (write-time; deterministic to store). It is
#   removed on --unprocess so the field is present iff the entry is processed.
#
# Output:
#   On success, stdout carries the machine-parseable key:
#     INBOX_PROCESSED=<id>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  flipped
#   1  jq absent / lock timeout / inbox file absent / not exactly one match
#   2  usage error (missing/invalid argument, unreadable note-file)
#
# Env:
#   INBOX_FILE   Overrides the log path (default
#                $HOME/.claude/crucible/gtd/inbox.jsonl). Tests set this to a
#                temp path so no run ever touches the real log.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (date, mktemp, od/cksum, tr, awk, basename, dirname, mv,
#   chmod) are assumed present. Uses fractional `sleep 0.1` (GNU/BSD, not
#   strict POSIX) — fine on the macOS+Linux targets. Self-contained:
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
Usage: $PROG --id ID [--note-file PATH] [--unprocess] [-h|--help]

Flip exactly one inbox entry's is_processed field under the shared writer
lock, via an atomic same-directory rewrite. Requires EXACTLY one match.

Options:
  --id ID           The entry's id (required).
  --note-file PATH   Verbatim note text (--rawfile; must exist/readable).
  --unprocess        Flip to false instead of true.
  -h, --help         Show this help.

On success, prints:
  INBOX_PROCESSED=<id>

Exit codes:
  0  flipped
  1  jq absent / lock timeout / inbox absent / not exactly one match
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_valid_json_object LINE — see capture.sh for the full rationale
# (duplicated verbatim; each script is self-contained, mirrors
# create-issue.sh — no sourcing between sibling scripts).
is_valid_json_object() {
	printf '%s' "$1" | jq -e -s 'length==1 and (.[0]|type)=="object"' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
INBOX_FILE=${INBOX_FILE:-"$HOME/.claude/crucible/gtd/inbox.jsonl"}
GTD_DIR=$(dirname "$INBOX_FILE")
LOCK_DIR="$GTD_DIR/.inbox.lock"

# ---------------------------------------------------------------------------
# Cleanup: release the lock and any rewrite temp file on any exit path.
# ---------------------------------------------------------------------------
LOCK_ACQUIRED=0
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	ec=$?
	[ -z "$TMP_FILE" ] || rm -f "$TMP_FILE" 2>/dev/null || true
	if [ "$LOCK_ACQUIRED" -eq 1 ]; then
		rm -rf "$LOCK_DIR" 2>/dev/null || true
		LOCK_ACQUIRED=0
	fi
	exit "$ec"
}
trap cleanup EXIT INT TERM

# acquire_lock — see capture.sh for the full rationale (duplicated verbatim).
acquire_lock() {
	attempt=0
	max_attempts=100
	holder_pid=""
	while :; do
		if mkdir "$LOCK_DIR" 2>/dev/null; then
			printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
			LOCK_ACQUIRED=1
			return 0
		fi
		if [ -f "$LOCK_DIR/pid" ]; then
			holder_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || printf '')
			case "$holder_pid" in
				''|*[!0-9]*) holder_pid='' ;;
			esac
			if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
				warn "reclaiming stale inbox lock held by dead pid $holder_pid"
				if mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null; then
					rm -rf "$LOCK_DIR.stale.$$" 2>/dev/null || true
				fi
				continue
			fi
		fi
		attempt=$((attempt + 1))
		if [ "$attempt" -ge "$max_attempts" ]; then
			error "could not acquire inbox lock after $attempt attempts (held by pid ${holder_pid:-unknown})"
			exit 1
		fi
		sleep 0.1
	done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_ID=""
OPT_NOTE_FILE=""
OPT_UNPROCESS=0

while [ $# -gt 0 ]; do
	case "$1" in
		--id)         need_arg "$1" "${2:-}"; OPT_ID=$2; shift ;;
		--note-file)  need_arg "$1" "${2:-}"; OPT_NOTE_FILE=$2; shift ;;
		--unprocess)  OPT_UNPROCESS=1 ;;
		-h|--help)    usage; exit 0 ;;
		--)           shift; break ;;
		-*)           usage >&2; error "unknown option: $1"; exit 2 ;;
		*)            usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_ID" ] || { usage >&2; error "--id is required"; exit 2; }

if [ -n "$OPT_NOTE_FILE" ]; then
	if [ ! -f "$OPT_NOTE_FILE" ] || [ ! -r "$OPT_NOTE_FILE" ]; then
		usage >&2
		error "--note-file does not exist or is not readable: $OPT_NOTE_FILE"
		exit 2
	fi
fi

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

IS_PROCESSED_VALUE="true"
[ "$OPT_UNPROCESS" -eq 0 ] || IS_PROCESSED_VALUE="false"

# processed_ts — a WRITE-time UTC instant, stamped when flipping TO processed
# and removed on --unprocess. Same `date -u` ISO-8601 format capture.sh writes
# for `ts`, so render-md.sh parses both identically. Read ONCE here (a single
# flip touches exactly one entry), never inside the per-line loop.
PROCESSED_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ---------------------------------------------------------------------------
# Absent/empty file — a clean, specific diagnostic (never a raw filesystem
# or jq error), still a failure: a requested id cannot match nothing.
# ---------------------------------------------------------------------------
if [ ! -f "$INBOX_FILE" ] || [ ! -s "$INBOX_FILE" ]; then
	error "no such inbox entry (the inbox is empty or does not exist): $OPT_ID"
	exit 1
fi

if [ ! -r "$INBOX_FILE" ]; then
	error "cannot read inbox file (permission denied): $INBOX_FILE"
	exit 1
fi

umask 077

acquire_lock

# ---------------------------------------------------------------------------
# Single pass, HELD under the lock so no concurrent writer can change the
# match count between the read and the rewrite: every line is either the
# matched target (transformed), or copied through byte-for-byte unchanged
# (whether a well-formed non-matching entry or a malformed line).
# ---------------------------------------------------------------------------
TMP_FILE=$(mktemp "$GTD_DIR/.inbox.XXXXXX")
chmod 600 "$TMP_FILE"

MATCHED_COUNT=0
while IFS= read -r line || [ -n "$line" ]; do
	[ -n "$line" ] || continue
	if is_valid_json_object "$line"; then
		this_id=$(printf '%s' "$line" | jq -r '.id // empty')
		if [ "$this_id" = "$OPT_ID" ]; then
			MATCHED_COUNT=$((MATCHED_COUNT + 1))
			# processed_ts is stamped when flipping TO processed and
			# removed on --unprocess — a static conditional inside the
			# program, branching on the $is_processed VALUE; $processed_ts
			# only ever travels as an --arg value.
			if [ -n "$OPT_NOTE_FILE" ]; then
				new_line=$(printf '%s' "$line" | jq -c \
					--argjson is_processed "$IS_PROCESSED_VALUE" \
					--arg processed_ts "$PROCESSED_TS" \
					--rawfile note "$OPT_NOTE_FILE" \
					'.is_processed = $is_processed
					 | (if $is_processed then .processed_ts = $processed_ts else del(.processed_ts) end)
					 | .note = $note')
			else
				new_line=$(printf '%s' "$line" | jq -c \
					--argjson is_processed "$IS_PROCESSED_VALUE" \
					--arg processed_ts "$PROCESSED_TS" \
					'.is_processed = $is_processed
					 | (if $is_processed then .processed_ts = $processed_ts else del(.processed_ts) end)')
			fi
			printf '%s\n' "$new_line" >>"$TMP_FILE"
		else
			printf '%s\n' "$line" >>"$TMP_FILE"
		fi
	else
		warn "preserving malformed inbox line unchanged"
		printf '%s\n' "$line" >>"$TMP_FILE"
	fi
done <"$INBOX_FILE"

if [ "$MATCHED_COUNT" -ne 1 ]; then
	error "expected exactly one inbox entry with id '$OPT_ID', found $MATCHED_COUNT; no changes made"
	exit 1
fi

mv "$TMP_FILE" "$INBOX_FILE"
TMP_FILE=""
chmod 600 "$INBOX_FILE"

printf 'INBOX_PROCESSED=%s\n' "$OPT_ID"
exit 0
