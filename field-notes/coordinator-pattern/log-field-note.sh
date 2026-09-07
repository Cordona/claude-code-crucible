#!/usr/bin/env sh
#
# log-field-note.sh — append ONE field note to the coordinator-pattern JSONL log.
#
# WHY no lock (unlike the GTD inbox scripts): concurrent appends from several
# Claude Code sessions CAN interleave and corrupt a line here. That race was
# discussed and explicitly ACCEPTED for this experiment — a plain `>>` is the
# intended mechanism, so do not "fix" this by adding a lock file.
#
# WHY --body-file (never a --body string flag): per this repo's standing
# convention, arbitrary free-text always travels as a file. A string on argv
# is a shell- and jq-injection surface, is capped by the platform's argv
# limit, and cannot carry newlines verbatim; a file is none of those.
# --summary is exempt BY SHAPE, not by exception: it is a headline, so it is
# short, single-line, and safely fits argv.
#
# Usage:
#   log-field-note.sh --agent NAME --summary TEXT --body-file PATH [-h|--help]
#
#     --agent NAME       The calling session/agent identity, an arbitrary
#                          string (required). Recorded verbatim, never
#                          validated against any known-agent list.
#     --summary TEXT     Short headline for the note, like a commit subject
#                          line (required, non-empty).
#     --body-file PATH   File holding the VERBATIM body text (required; must
#                          exist and be readable).
#     -h, --help         Show this help.
#
# Output:
#   Appends one JSON object — {"ts","agent","summary","body"} — to
#   field-notes.jsonl, resolved next to THIS script (never relative to the
#   caller's cwd) and created on first use. Existing lines are never read,
#   rewritten, or truncated. The appended line is echoed to stdout;
#   diagnostics to stderr.
#
# Exit codes:
#   0  note appended
#   1  jq absent / append failed
#   2  usage error (missing/invalid argument, unreadable --body-file)
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland) and Linux (GNU coreutils). jq is the only non-ubiquitous
#   dependency and is guarded with `command -v`. Self-contained: sources
#   nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

error() { printf '%s: error: %s\n' "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --agent NAME --summary TEXT --body-file PATH [-h|--help]

Append one field note to field-notes.jsonl, located next to this script. The
body text is ALWAYS a file (--body-file) — there is no --body passthrough.

Options:
  --agent NAME       Calling session/agent identity, arbitrary (required).
  --summary TEXT     Short headline, like a commit subject line (required).
  --body-file PATH   Path to the verbatim body text (required; must exist
                       and be readable).
  -h, --help         Show this help.

On success, prints the appended JSON line.

Exit codes:
  0  appended
  1  jq absent / append failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_AGENT=""
OPT_SUMMARY=""
OPT_BODY_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--agent)     need_arg "$1" "${2:-}"; OPT_AGENT=$2; shift ;;
		--summary)   need_arg "$1" "${2:-}"; OPT_SUMMARY=$2; shift ;;
		--body-file) need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_AGENT" ]     || { usage >&2; error "--agent is required"; exit 2; }
[ -n "$OPT_SUMMARY" ]   || { usage >&2; error "--summary is required"; exit 2; }
[ -n "$OPT_BODY_FILE" ] || { usage >&2; error "--body-file is required"; exit 2; }

if [ ! -f "$OPT_BODY_FILE" ] || [ ! -r "$OPT_BODY_FILE" ]; then
	usage >&2
	error "--body-file does not exist or is not readable: $OPT_BODY_FILE"
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed (required to build JSON safely); install it from https://jqlang.org"
	exit 1
fi

# ---------------------------------------------------------------------------
# Locate the log beside this script, so the path is identical no matter which
# directory the calling session happens to be in. `cd`+`pwd` rather than
# `readlink -f`, whose flags diverge between GNU and BSD userland.
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) || {
	error "failed to resolve this script's own directory from: $0"
	exit 1
}
NOTES_FILE="$SCRIPT_DIR/field-notes.jsonl"

# ---------------------------------------------------------------------------
# Build the line. Every value travels via --arg/--rawfile into a STATIC jq
# program, never concatenated into the program text: the body is arbitrary
# caller-supplied bytes, and --rawfile (not `$(cat)`) carries them verbatim
# without stripping trailing newlines. jq owns all escaping, so quotes,
# backslashes, newlines, and control characters survive as valid JSON.
# ---------------------------------------------------------------------------
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LINE=$(jq -c -n \
	--arg ts "$TS" \
	--arg agent "$OPT_AGENT" \
	--arg summary "$OPT_SUMMARY" \
	--rawfile body "$OPT_BODY_FILE" \
	'{ts: $ts, agent: $agent, summary: $summary, body: $body}')

if ! printf '%s\n' "$LINE" >>"$NOTES_FILE"; then
	error "failed to append to: $NOTES_FILE"
	exit 1
fi

printf '%s\n' "$LINE"
exit 0
