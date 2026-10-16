#!/usr/bin/env bash
set -Eeuo pipefail
#
# save-reply.sh — save a subagent's final report from its JSONL transcript
#                 into a run folder (flow-harness-authoring). Reads the
#                 transcript only; writes only --out.
#
# Selection: every line of the transcript that parses as JSON is searched;
# lines that do not parse are skipped. A candidate is any string value,
# nested anywhere in the object, that contains the --end line and, with
# --start, the --start prefix before the last --end. The latest candidate
# wins: the one on the last matching line, and within that line the last in
# document order. A subagent can send its report more than once (a resend
# after a fix), so the earliest copy is often stale.
#
# Cut: the report runs from the first --start (or the string's start) to the
# end of the last --end; --strip-end drops that end line. --require TEXT is
# checked against the cut report, so text outside the report cannot select
# a stale copy. Trailing newlines are trimmed and exactly one is written.
#
# Secret guard: the cut report is scanned before --out exists. A match
# writes nothing and names only the pattern and the report line, never the
# value.
#
# Usage: see --help.
#
# Output (stdout, one line): saved: <out> lines=<n> from-line=<transcript line>
#   Diagnostics go to stderr. The report is never printed.
#
# Exit codes:
#   0    saved
#   1    no candidate found
#   2    usage error (missing or unknown option, unreadable transcript,
#        --out exists without --force, --out is the transcript, the --out
#        directory missing or not writable)
#   3    secret guard: nothing written
#   5    internal error, or a required tool (jq) is missing
#   130  interrupted (INT)
#   143  terminated (TERM)
#
# Portability: Bash 3.2+ (macOS) and Linux. Needs jq 1.6+ (--rawfile) and POSIX
#   dirname, grep, ln, mktemp, mv, rm and wc, checked at start. LC_ALL=C for
#   grep so matching is byte-wise everywhere; jq matches by code point.
#

LC_ALL=C
export LC_ALL
unset CDPATH

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout carries only the saved: line)
# ---------------------------------------------------------------------------
error() { printf '%s: error: %s\n' "${PROG}" "$*" >&2; }

# shellcheck disable=SC2329  # invoked indirectly via the ERR trap
internal_error() {
	(( BASH_SUBSHELL == 0 )) || exit 5
	printf '%s: internal error at line %s: %s\n' "${PROG}" "$1" "$2" >&2
	printf '%s: expected that command to succeed; nothing was saved. Try: re-run with the same arguments and check free space in the --out directory; if it repeats, report the command above.\n' \
		"${PROG}" >&2
	exit 5
}
trap 'internal_error "${LINENO}" "${BASH_COMMAND}"' ERR

usage() {
	cat <<EOF
usage: ${PROG} --transcript FILE --end 'END LINE' --out FILE
                    [--start PREFIX] [--require TEXT] [--strip-end] [--force]
                    [-h|--help]

Save the latest complete report found in a subagent's JSONL transcript.
A candidate is any JSON string value containing the end line; the one on the
last matching transcript line wins. Lines that are not valid JSON are skipped.

Options:
  --transcript FILE  The subagent transcript (JSONL). Read only.
  --end LINE         The exact end line, e.g. '=== END OF 05 ==='. The report
                       ends at its last occurrence in the chosen string.
  --out FILE         Where to write the report (plus one trailing newline).
                       Written atomically; its directory must exist.
  --start PREFIX     The report begins at the first occurrence of PREFIX;
                       a string without PREFIX before the end line is no
                       candidate. Default: the start of the string.
  --require TEXT     The report must contain TEXT (picks a resend that
                       carries a fixed item); others are no candidate.
  --strip-end        Leave the end line out of the saved report.
  --force            Overwrite an existing --out.
  -h, --help         Show this help.

Refuses to write when the report matches a likely secret (GitHub ghp_/gho_/
github_pat_ token, sk- key, AWS access key id, private key block); prints
the pattern name and report line, never the value.

Output: one line, "saved: <out> lines=<n> from-line=<transcript line>".

Required tools: jq, dirname, grep, ln, mktemp, mv, rm, wc.

Exit codes:
  0    saved
  1    no candidate found
  2    usage error (missing or unknown option, unreadable transcript, --out
       exists without --force, --out is the transcript, --out directory
       missing or not writable)
  3    secret guard: likely secret in the report, nothing written
  5    internal error, or a required tool is missing
  130  interrupted (INT)
  143  terminated (TERM)
EOF
}

usage_error() {
	usage >&2
	error "$*"
	exit 2
}

need_arg() {
	[[ -n "${2:-}" ]] || usage_error "option $1 requires an argument"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_TRANSCRIPT=""
OPT_END=""
OPT_OUT=""
OPT_START=""
OPT_REQUIRE=""
OPT_STRIP_END=false
OPT_FORCE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--transcript) need_arg "$1" "${2:-}"; OPT_TRANSCRIPT=$2; shift ;;
		--end)        need_arg "$1" "${2:-}"; OPT_END=$2; shift ;;
		--out)        need_arg "$1" "${2:-}"; OPT_OUT=$2; shift ;;
		--start)      need_arg "$1" "${2:-}"; OPT_START=$2; shift ;;
		--require)    need_arg "$1" "${2:-}"; OPT_REQUIRE=$2; shift ;;
		--strip-end)  OPT_STRIP_END=true ;;
		--force)      OPT_FORCE=1 ;;
		-h|--help)    usage; exit 0 ;;
		*)            usage_error "unknown option or argument: $1" ;;
	esac
	shift
done

for tool in jq dirname grep ln mktemp mv rm wc; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		error "required tool missing: ${tool}; expected it on PATH; try installing it (jq: https://jqlang.org) or fixing PATH"
		exit 5
	fi
done

[[ -n "${OPT_TRANSCRIPT}" ]] || usage_error "--transcript FILE is required"
[[ -n "${OPT_END}" ]] || usage_error "--end LINE is required"
[[ -n "${OPT_OUT}" ]] || usage_error "--out FILE is required"

[[ -f "${OPT_TRANSCRIPT}" && -r "${OPT_TRANSCRIPT}" ]] ||
	usage_error "transcript does not exist or is not readable: ${OPT_TRANSCRIPT}"

OUT_DIR=$(dirname -- "${OPT_OUT}")
[[ -d "${OUT_DIR}" ]] || usage_error "--out directory does not exist: ${OUT_DIR}"
[[ -w "${OUT_DIR}" ]] || usage_error "--out directory is not writable: ${OUT_DIR}"
[[ ! -d "${OPT_OUT}" ]] || usage_error "--out is a directory: ${OPT_OUT}"
if [[ -e "${OPT_OUT}" || -L "${OPT_OUT}" ]]; then
	[[ ! "${OPT_OUT}" -ef "${OPT_TRANSCRIPT}" ]] || usage_error "--out is the transcript itself: ${OPT_OUT}"
	(( OPT_FORCE )) || usage_error "--out already exists (use --force to overwrite): ${OPT_OUT}"
fi

# ---------------------------------------------------------------------------
# Cleanup: the private temp files live in the --out directory so the final
# rename stays on one filesystem. INT/TERM trapped separately from EXIT so an
# interrupted run reports 130/143.
# ---------------------------------------------------------------------------
PICK_FILE=""
REPORT_TMP=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[[ -z "${PICK_FILE}" ]] || rm -f -- "${PICK_FILE}" 2>/dev/null || true
	[[ -z "${REPORT_TMP}" ]] || rm -f -- "${REPORT_TMP}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

PICK_FILE=$(mktemp "${OUT_DIR}/.save-reply.pick.XXXXXX")
REPORT_TMP=$(mktemp "${OUT_DIR}/.save-reply.out.XXXXXX")

# ---------------------------------------------------------------------------
# Selection and cut: one jq pass. Emits [line, report] for the latest
# candidate, or nothing. The transcript is read whole with --rawfile and split
# on newlines inside jq: jq -R splits a multi-byte character that straddles
# its read buffer into U+FFFD replacement characters. split/join keeps every
# offset in code points, so multi-byte text is cut exactly.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # $names here are jq variables, not shell ones
JQ_PROGRAM='
def from_start:
	if $start == "" then .
	elif contains($start) then $start + (split($start) | .[1:] | join($start))
	else empty end;

def to_end:
	split($end) as $parts
	| select(($parts | length) > 1)
	| ($parts[:-1] | join($end)) + (if $strip_end then "" else $end end);

def trim_newlines: until(endswith("\n") | not; .[:-1]);

last(
	$transcript | split("\n") | to_entries[]
	| (.key + 1) as $line
	| (.value | fromjson?)
	| .. | strings
	| select(contains($end))
	| from_start | to_end
	| select($require == "" or contains($require))
	| [$line, trim_newlines + "\n"]
)
'

jq_status=0
jq -c -n \
	--rawfile transcript "${OPT_TRANSCRIPT}" \
	--arg end "${OPT_END}" \
	--arg start "${OPT_START}" \
	--arg require "${OPT_REQUIRE}" \
	--argjson strip_end "${OPT_STRIP_END}" \
	"${JQ_PROGRAM}" >"${PICK_FILE}" || jq_status=$?
if (( jq_status != 0 )); then
	error "internal error: jq exited ${jq_status} while reading the transcript; expected 0. Try: read jq's message above; check the jq version (1.6+ needed): $(jq --version 2>&1 || true)"
	exit 5
fi

if [[ ! -s "${PICK_FILE}" ]]; then
	criteria="the end line '${OPT_END}'"
	[[ -z "${OPT_START}" ]] || criteria+=" after the start '${OPT_START}'"
	[[ -z "${OPT_REQUIRE}" ]] || criteria+=" with '${OPT_REQUIRE}'"
	error "no candidate in ${OPT_TRANSCRIPT}: no JSON string holds ${criteria}; check --end, --start and --require against the report the subagent sent"
	exit 1
fi

FROM_LINE=$(jq -r '.[0]' <"${PICK_FILE}")
jq -j '.[1]' <"${PICK_FILE}" >"${REPORT_TMP}"

# ---------------------------------------------------------------------------
# Secret guard: name, then ERE. Only grep's line numbers are kept.
# ---------------------------------------------------------------------------
SECRET_PATTERNS=(
	"github-token" 'gh[po]_[A-Za-z0-9]{36}'
	"github-pat" 'github_pat_[A-Za-z0-9_]{22,}'
	"sk-key" '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}'
	"aws-access-key-id" 'AKIA[0-9A-Z]{16}'
	"private-key" '-----BEGIN .*PRIVATE KEY-----'
)

found_secret=0
i=0
while (( i < ${#SECRET_PATTERNS[@]} )); do
	name=${SECRET_PATTERNS[i]}
	pattern=${SECRET_PATTERNS[i + 1]}
	i=$((i + 2))
	grep_status=0
	hits=$(grep -n -E -e "${pattern}" -- "${REPORT_TMP}" | while IFS=: read -r number _; do printf '%s ' "${number}"; done) || grep_status=$?
	if (( grep_status > 1 )); then
		error "internal error: grep exited ${grep_status} on the secret pattern ${name}; nothing was saved"
		exit 5
	fi
	if [[ -n "${hits}" ]]; then
		error "secret guard: likely ${name} at report line(s) ${hits% }"
		found_secret=1
	fi
done
if (( found_secret )); then
	error "secret guard: nothing written to ${OPT_OUT}; remove the secret from the subagent's report and re-dispatch it"
	exit 3
fi

# ---------------------------------------------------------------------------
# Atomic write: without --force, ln refuses an existing --out, so a file that
# appeared after the start-up check is never clobbered.
# ---------------------------------------------------------------------------
if (( OPT_FORCE )); then
	mv -f -- "${REPORT_TMP}" "${OPT_OUT}"
else
	if ! ln -- "${REPORT_TMP}" "${OPT_OUT}" 2>/dev/null; then
		[[ ! -e "${OPT_OUT}" ]] || usage_error "--out already exists (use --force to overwrite): ${OPT_OUT}"
		error "internal error: could not create ${OPT_OUT}; expected a hard link in the same directory to succeed; nothing was saved"
		exit 5
	fi
	rm -f -- "${REPORT_TMP}"
fi
REPORT_TMP=""

LINE_COUNT=$(wc -l <"${OPT_OUT}")
LINE_COUNT=${LINE_COUNT//[[:space:]]/}
printf 'saved: %s lines=%s from-line=%s\n' "${OPT_OUT}" "${LINE_COUNT}" "${FROM_LINE}"
