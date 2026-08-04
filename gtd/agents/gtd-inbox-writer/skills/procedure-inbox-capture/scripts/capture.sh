#!/usr/bin/env sh
#
# capture.sh — append ONE line to the GTD inbox log under a shared lock.
#
# WHY the shared lock (see the sibling scripts for the same acquire/release
# code): a lock-free `>>` racing process.sh/purge-processed.sh's atomic
# rewrite can lose data — the rewrite reads the whole file, and an append
# that lands between that read and the rewrite's `mv` is silently discarded.
# capture.sh takes the SAME mkdir-based lock as the rewriters even though its
# own critical section is sub-millisecond, so there is no lock-free path.
#
# WHY --rawfile (never $(cat)): command substitution strips trailing
# newlines and cannot carry arbitrary bytes verbatim. --rawfile reads the
# file's exact bytes into the jq string, so "text" is byte-for-byte what the
# caller wrote — never executed, never reformatted.
#
# Usage:
#   capture.sh --text-file PATH [--project NAME] [--session-id ID] [-h|--help]
#
#     --text-file PATH   Path to a file holding the VERBATIM capture text
#                          (required). Must exist, be readable, non-empty.
#                          There is deliberately NO --text string flag — a
#                          string argument on argv is a jq-program-injection
#                          and shell-injection surface; a file is not.
#     --project NAME      Overrides the default project (basename of the
#                          capture cwd). Omitted entirely (not stored as ""
#                          or "/") when not given and not derivable.
#     --session-id ID    The Claude Code session id that captured this entry
#                          (a UUID the orchestrator derives from its own
#                          session/scratchpad path). OPTIONAL: when given, the
#                          "session_id" field is included (via --arg); when
#                          absent the key is OMITTED entirely (never written
#                          as null), so old records stay shape-identical.
#     -h, --help          Show this help.
#
# Output:
#   On success, stdout carries the machine-parseable key:
#     INBOX_ID=<id>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  entry appended
#   1  jq absent / lock could not be acquired / directory create failed
#   2  usage error (missing/invalid argument, unreadable or empty text-file)
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
Usage: $PROG --text-file PATH [--project NAME] [--session-id ID] [-h|--help]

Append one entry to the GTD inbox log under the shared writer lock. The
text is ALWAYS a file (--text-file) — there is no --text passthrough.

Options:
  --text-file PATH   Path to the verbatim capture text (required; must
                       exist, be readable, and non-empty).
  --project NAME      Overrides the default project (basename of the
                       capture cwd). Omitted when not derivable.
  --session-id ID    The capturing Claude Code session id (UUID). Optional;
                       included when given, omitted entirely when absent.
  -h, --help          Show this help.

On success, prints:
  INBOX_ID=<id>

Exit codes:
  0  appended
  1  jq absent / lock timeout / directory create failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
INBOX_FILE=${INBOX_FILE:-"$HOME/.claude/crucible/gtd/inbox.jsonl"}
GTD_DIR=$(dirname "$INBOX_FILE")
LOCK_DIR="$GTD_DIR/.inbox.lock"

# ---------------------------------------------------------------------------
# Cleanup: release the lock (and any temp file) on any exit path.
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

# acquire_lock — mkdir-based mutual exclusion (portable: no flock on macOS).
# Bounded-retry with a ~10s timeout. Stale-lock reclaim: the holder's PID is
# recorded inside the lock dir; if that PID is no longer alive, the lock is
# reclaimed rather than waited out forever.
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

# derive_project — basename of $PWD, with root/empty/unset guarded: prints
# nothing and returns 1 when no sane project name can be derived, so the
# caller OMITS the field entirely rather than store "/" or "".
derive_project() {
	cwd=${PWD-}
	[ -n "$cwd" ] || return 1
	[ "$cwd" != "/" ] || return 1
	base=$(basename "$cwd")
	[ -n "$base" ] || return 1
	[ "$base" != "/" ] || return 1
	printf '%s' "$base"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_TEXT_FILE=""
OPT_PROJECT=""
OPT_SESSION_ID=""

while [ $# -gt 0 ]; do
	case "$1" in
		--text-file)  need_arg "$1" "${2:-}"; OPT_TEXT_FILE=$2; shift ;;
		--project)    need_arg "$1" "${2:-}"; OPT_PROJECT=$2; shift ;;
		--session-id) need_arg "$1" "${2:-}"; OPT_SESSION_ID=$2; shift ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_TEXT_FILE" ] || { usage >&2; error "--text-file is required"; exit 2; }

if [ ! -f "$OPT_TEXT_FILE" ] || [ ! -r "$OPT_TEXT_FILE" ]; then
	usage >&2
	error "--text-file does not exist or is not readable: $OPT_TEXT_FILE"
	exit 2
fi

if [ ! -s "$OPT_TEXT_FILE" ]; then
	usage >&2
	error "--text-file is empty: $OPT_TEXT_FILE"
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

# ---------------------------------------------------------------------------
# project (default derived, overridable, omitted when not derivable)
# ---------------------------------------------------------------------------
PROJECT=""
if [ -n "$OPT_PROJECT" ]; then
	PROJECT=$OPT_PROJECT
elif derived=$(derive_project); then
	PROJECT=$derived
fi

# ---------------------------------------------------------------------------
# id + ts — ONE `date -u` call feeds BOTH, so they can never straddle a
# second boundary. id = <8-digit-date>T<6-digit-time>Z-<8 lowercase hex>.
# ---------------------------------------------------------------------------
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ID_PREFIX=$(printf '%s' "$TS" | tr -d ':-')

if [ -r /dev/urandom ]; then
	RAND_HEX=$(od -An -N4 -tx1 /dev/urandom | tr -dc '0-9a-f')
else
	warn "/dev/urandom not readable; falling back to a weaker id-suffix source"
	seed="$$-$TS-$(date -u +%s 2>/dev/null || printf '0')"
	crc=$(printf '%s' "$seed" | cksum | awk '{print $1}')
	RAND_HEX=$(printf '%08x' "$crc")
fi

case "$RAND_HEX" in
	????????) : ;;
	*) error "internal: failed to generate an 8-hex-digit id suffix"; exit 1 ;;
esac

ID="${ID_PREFIX}-${RAND_HEX}"

# ---------------------------------------------------------------------------
# Build the JSONL line. Every value travels via --arg/--argjson/--rawfile
# into a STATIC jq program — never concatenated into the program text. Two
# hardcoded program variants (with/without "project") rather than one
# program that sometimes emits a null/empty project, per the contract:
# "project" is OMITTED entirely when not derivable, never stored as "".
#
# "session_id" follows the SAME omit-when-absent discipline, but via a static
# conditional MERGE inside the program (the `+ (if $has_session ...)` tail)
# rather than a further doubling of hardcoded variants: $session_id still
# travels only as an --arg VALUE, and $has_session (an --argjson boolean) is
# what the STATIC program branches on — so an absent session id yields no key
# at all (never a null), and old records stay shape-identical.
# ---------------------------------------------------------------------------
HAS_SESSION=false
[ -z "$OPT_SESSION_ID" ] || HAS_SESSION=true

if [ -n "$PROJECT" ]; then
	LINE=$(jq -c -n \
		--arg id "$ID" \
		--arg ts "$TS" \
		--rawfile text "$OPT_TEXT_FILE" \
		--arg project "$PROJECT" \
		--arg session_id "$OPT_SESSION_ID" \
		--argjson has_session "$HAS_SESSION" \
		--argjson is_processed false \
		'{schema_version:"1.0", id:$id, ts:$ts, text:$text, project:$project, is_processed:$is_processed, note:null}
		 + (if $has_session then {session_id:$session_id} else {} end)')
else
	LINE=$(jq -c -n \
		--arg id "$ID" \
		--arg ts "$TS" \
		--rawfile text "$OPT_TEXT_FILE" \
		--arg session_id "$OPT_SESSION_ID" \
		--argjson has_session "$HAS_SESSION" \
		--argjson is_processed false \
		'{schema_version:"1.0", id:$id, ts:$ts, text:$text, is_processed:$is_processed, note:null}
		 + (if $has_session then {session_id:$session_id} else {} end)')
fi

# ---------------------------------------------------------------------------
# Create gtd/ (700) if needed, acquire the shared lock, ensure the log file
# exists at 600, append, done. umask scopes perms for everything this
# script creates from here on; explicit chmods are defense-in-depth.
# ---------------------------------------------------------------------------
umask 077

if ! mkdir -p "$GTD_DIR"; then
	error "failed to create inbox directory: $GTD_DIR"
	exit 1
fi
chmod 700 "$GTD_DIR"

acquire_lock

if [ ! -f "$INBOX_FILE" ]; then
	: >"$INBOX_FILE"
fi
chmod 600 "$INBOX_FILE"

printf '%s\n' "$LINE" >>"$INBOX_FILE"

printf 'INBOX_ID=%s\n' "$ID"
exit 0
