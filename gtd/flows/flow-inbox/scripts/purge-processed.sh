#!/usr/bin/env sh
#
# purge-processed.sh — delete processed inbox entries, under the shared
#                       lock, via an atomic same-directory rewrite.
#                       DRY-RUN BY DEFAULT — mutates nothing without
#                       --apply, and backs up what it removes before it
#                       ever touches the log.
#
# WHY dry-run by default + --project|--all required: this is the ONE
# destructive operation in the whole subsystem. A bare call (no scope) is
# refused outright — an accidental global delete must never be one flag
# away. Even a scoped call only PRINTS a match count + preview until the
# caller passes --apply.
#
# WHY the .purged backup is written BEFORE the rewrite: if the process dies
# between the backup write and the `mv`, the original inbox.jsonl is still
# untouched (mv hasn't happened) — the backup is a strict precondition of
# the delete, not a courtesy taken after.
#
# WHY the rewrite temp lives inside gtd/, not /tmp: see process.sh — `mv`
# is only atomic within one filesystem.
#
# Usage:
#   purge-processed.sh (--project NAME | --all) [--apply] [-h|--help]
#
#     --project NAME   Purge processed entries for this project only.
#                        Mutually exclusive with --all; exactly one of the
#                        two is required.
#     --all            Purge processed entries across every project.
#     --apply           Actually delete (and back up first). Without this,
#                        the run is a dry-run: prints the match count + a
#                        short preview and mutates nothing.
#     -h, --help        Show this help.
#
# Output:
#   Dry-run:  INBOX_PURGE_MATCHED=<n>  (+ a JSON preview array, up to 5)
#   --apply:  the same, followed by    INBOX_PURGED=<n>
#              and, ONLY when >=1 entry was actually purged (i.e. a backup
#              was actually written), followed by
#              INBOX_PURGE_BACKUP=<absolute path to the .purged backup>
#              — so a caller can tell the human where their recovery file
#              is. Never printed on a dry-run (no backup is written) and
#              never printed on an --apply with zero matches (nothing was
#              written/deleted, so there is no path to report).
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  dry-run report printed, or delete applied (including zero matches)
#   1  jq absent / lock timeout / inbox file unreadable
#   2  usage error (neither/both of --project|--all, missing argument)
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
Usage: $PROG (--project NAME | --all) [--apply] [-h|--help]

Delete PROCESSED inbox entries under the shared writer lock, via an atomic
same-directory rewrite. DRY-RUN BY DEFAULT.

Options:
  --project NAME   Purge processed entries for this project only.
                     Exactly one of --project/--all is required.
  --all            Purge processed entries across every project.
  --apply          Actually delete (backs up removed lines first).
                     Without this, nothing is mutated.
  -h, --help       Show this help.

Output:
  Dry-run:  INBOX_PURGE_MATCHED=<n>  + a JSON preview (up to 5 entries)
  --apply:  the same, followed by    INBOX_PURGED=<n>
             and, only when >=1 entry was purged, followed by
             INBOX_PURGE_BACKUP=<path to the .purged backup>

Exit codes:
  0  report printed, or delete applied
  1  jq absent / lock timeout / inbox file unreadable
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
# The backup file (once its content is fully written, before the mv) is a
# deliverable, not scratch — it is never removed by cleanup.
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
OPT_PROJECT=""
OPT_ALL=0
OPT_APPLY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--project) need_arg "$1" "${2:-}"; OPT_PROJECT=$2; shift ;;
		--all)     OPT_ALL=1 ;;
		--apply)   OPT_APPLY=1 ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        usage >&2; error "unknown option: $1"; exit 2 ;;
		*)         usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

if [ -n "$OPT_PROJECT" ] && [ "$OPT_ALL" -eq 1 ]; then
	usage >&2
	error "--project and --all are mutually exclusive"
	exit 2
fi
if [ -z "$OPT_PROJECT" ] && [ "$OPT_ALL" -eq 0 ]; then
	usage >&2
	error "one of --project NAME or --all is required (a bare call is refused — never a global delete by accident)"
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

# ---------------------------------------------------------------------------
# Absent/empty file — a clean, distinct no-op: zero matches, exit 0.
# ---------------------------------------------------------------------------
if [ ! -f "$INBOX_FILE" ] || [ ! -s "$INBOX_FILE" ]; then
	printf 'INBOX_PURGE_MATCHED=0\n'
	[ "$OPT_APPLY" -eq 0 ] || printf 'INBOX_PURGED=0\n'
	exit 0
fi

if [ ! -r "$INBOX_FILE" ]; then
	error "cannot read inbox file (permission denied): $INBOX_FILE"
	exit 1
fi

umask 077

acquire_lock

# ---------------------------------------------------------------------------
# Single pass, held under the lock: classify every line as MATCH (processed
# + in scope — collected for backup/preview, held out of the rewrite) or
# KEEP (everything else, well-formed or malformed, copied through
# unchanged, order preserved).
# ---------------------------------------------------------------------------
TMP_FILE=$(mktemp "$GTD_DIR/.inbox.XXXXXX")
chmod 600 "$TMP_FILE"

MATCHED_COUNT=0
MATCHED_LINES=""
while IFS= read -r line || [ -n "$line" ]; do
	[ -n "$line" ] || continue
	should_purge=0
	if is_valid_json_object "$line"; then
		is_proc=$(printf '%s' "$line" | jq -r '.is_processed == true')
		if [ "$is_proc" = "true" ]; then
			if [ "$OPT_ALL" -eq 1 ]; then
				should_purge=1
			else
				line_project=$(printf '%s' "$line" | jq -r '.project // empty')
				[ "$line_project" != "$OPT_PROJECT" ] || should_purge=1
			fi
		fi
	fi
	if [ "$should_purge" -eq 1 ]; then
		MATCHED_COUNT=$((MATCHED_COUNT + 1))
		if [ -z "$MATCHED_LINES" ]; then MATCHED_LINES=$line
		else MATCHED_LINES="$MATCHED_LINES
$line"
		fi
	else
		printf '%s\n' "$line" >>"$TMP_FILE"
	fi
done <"$INBOX_FILE"

printf 'INBOX_PURGE_MATCHED=%s\n' "$MATCHED_COUNT"
if [ "$MATCHED_COUNT" -gt 0 ]; then
	printf '%s\n' "$MATCHED_LINES" | jq -c -s '.[0:5]'
	if [ "$MATCHED_COUNT" -gt 5 ]; then
		warn "preview truncated: showing 5 of $MATCHED_COUNT matched entries"
	fi
fi

if [ "$OPT_APPLY" -eq 0 ]; then
	# Dry run: nothing mutated. The rewrite scratch file is discarded by the
	# EXIT trap; the real inbox.jsonl is never touched.
	exit 0
fi

if [ "$MATCHED_COUNT" -eq 0 ]; then
	printf 'INBOX_PURGED=0\n'
	exit 0
fi

# ---------------------------------------------------------------------------
# --apply: write the removed lines to a timestamped, 600-permission backup
# BEFORE the rewrite ever touches the real log, then atomically replace it.
# ---------------------------------------------------------------------------
BACKUP_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_FILE="$GTD_DIR/inbox-${BACKUP_STAMP}-$$.purged"
: >"$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"
printf '%s\n' "$MATCHED_LINES" >"$BACKUP_FILE"

mv "$TMP_FILE" "$INBOX_FILE"
TMP_FILE=""
chmod 600 "$INBOX_FILE"

printf 'INBOX_PURGED=%s\n' "$MATCHED_COUNT"
printf 'INBOX_PURGE_BACKUP=%s\n' "$BACKUP_FILE"
exit 0
