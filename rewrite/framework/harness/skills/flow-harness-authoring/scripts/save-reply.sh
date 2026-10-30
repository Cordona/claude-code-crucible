#!/usr/bin/env bash
set -Eeuo pipefail
#
# save-reply.sh — save a subagent's final report from its JSONL transcript
#                 into a run folder (flow-harness-authoring). Reads the
#                 transcript only; writes only --out.
#
# Modes (exactly one):
#   --end   every line of the transcript that parses as JSON is searched;
#           lines that do not parse are skipped. A candidate is any string
#           value, nested anywhere in the object, that contains the --end
#           line and, with --start, the --start prefix before the last --end.
#           The latest candidate wins: the one on the last matching line, and
#           within that line the last in document order. A subagent can send
#           its report more than once (a resend after a fix), so the earliest
#           copy is often stale. The report runs from the first --start (or
#           the string's start) to the end of the last --end; --strip-end
#           drops that end line. --require TEXT is checked against the cut
#           report, so text outside the report cannot select a stale copy.
#   --whole the last assistant message, whole. See JQ_WHOLE for what counts
#           as its text and when it counts as cut off.
#
# Both modes trim trailing newlines and write exactly one; an empty reply
# writes an empty file.
#
# Secret guard: the report is scanned before --out exists. A match writes
# nothing and names only the pattern and the report line, never the value.
#
# Contract (options, output, exit codes): see --help.
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
       ${PROG} --transcript FILE --whole --out FILE [--force]
       ${PROG} -h|--help

Save a subagent's reply from its JSONL transcript to --out. --end saves the
latest complete report holding the end line; --whole saves the last assistant
message whole. Give exactly one of the two. Lines that are not valid JSON are
skipped. Trailing newlines are trimmed and exactly one is written; an empty
reply writes an empty file. The reply is never printed.

Options:
  --transcript FILE  The subagent transcript (JSONL). Read only.
  --end LINE         The exact end line, e.g. '=== END OF 05 ==='. A candidate
                       is any JSON string holding it; the one on the last
                       matching transcript line wins, cut at its last end line.
  --whole            The last assistant message: its text blocks and its
                       SubagentHandback report, in order. A message that ends
                       in another tool call saves nothing (exit 1). Takes no
                       --start, --require or --strip-end.
  --out FILE         Where to write the reply. Its directory must exist.
  --start PREFIX     With --end: the report begins at the first PREFIX; a
                       string without PREFIX before the end line is no
                       candidate. Default: the start of the string.
  --require TEXT     With --end: the report must contain TEXT (picks a resend
                       that carries a fixed item); others are no candidate.
  --strip-end        With --end: leave the end line out of the saved report.
  --force            Overwrite an existing --out.

--out appears whole or not at all, and an existing --out is never replaced
without --force. Nothing else is left behind (a SIGKILL aside).

Refuses to write when the reply holds a likely secret (GitHub ghp_/gho_/
github_pat_ token, sk- key, AWS access key id, private key block); stderr
names the pattern and the reply line, never the value.

Output: one line, "saved: <out> lines=<n> from-line=<transcript line>".

Required tools: jq 1.6+ (https://jqlang.org), dirname, grep, ln, mktemp, mv,
rm, wc. A missing one exits 5 and is named on stderr.

Exit codes:
  0    saved; act on the saved file
  1    no reply saved; handle it as a cut-off reply
  2    usage error; show the human stderr, and stop
  3    likely secret, nothing written; mask it and write the masked reply to
       --out yourself, never unmasked, and do not re-dispatch the agent
  5    internal error or a missing tool; show the human stderr, and stop
  130  interrupted (INT); show the human stderr, and stop
  143  terminated (TERM); show the human stderr, and stop
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
OPT_WHOLE=0
OPT_FORCE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--transcript) need_arg "$1" "${2:-}"; OPT_TRANSCRIPT=$2; shift ;;
		--end)        need_arg "$1" "${2:-}"; OPT_END=$2; shift ;;
		--out)        need_arg "$1" "${2:-}"; OPT_OUT=$2; shift ;;
		--start)      need_arg "$1" "${2:-}"; OPT_START=$2; shift ;;
		--require)    need_arg "$1" "${2:-}"; OPT_REQUIRE=$2; shift ;;
		--strip-end)  OPT_STRIP_END=true ;;
		--whole)      OPT_WHOLE=1 ;;
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
if (( OPT_WHOLE )); then
	[[ -z "${OPT_END}" ]] || usage_error "--whole and --end are exclusive; expected exactly one; try --end alone for a reply with an end line"
	[[ -z "${OPT_START}" ]] || usage_error "--start needs --end; --whole has no end line to cut at"
	[[ -z "${OPT_REQUIRE}" ]] || usage_error "--require needs --end; --whole has no end line to cut at"
	[[ "${OPT_STRIP_END}" == false ]] || usage_error "--strip-end needs --end; --whole has no end line to cut at"
else
	[[ -n "${OPT_END}" ]] || usage_error "--end LINE or --whole is required; expected exactly one; try --whole for a reply with no end line"
fi
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
# Selection and cut: one jq pass. Emits [line, report] for the chosen reply,
# or nothing. The transcript is read whole with --rawfile and split on
# newlines inside jq: jq -R splits a multi-byte character that straddles its
# read buffer into U+FFFD replacement characters. split/join keeps every
# offset in code points, so multi-byte text is cut exactly.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # $names here are jq variables, not shell ones
JQ_COMMON='
def trim_newlines: until(endswith("\n") | not; .[:-1]);

def transcript_objects:
	$transcript | split("\n") | to_entries[]
	| (.key + 1) as $line
	| (.value | fromjson? | objects)
	| {line: $line, entry: .};
'

# shellcheck disable=SC2016  # $names here are jq variables, not shell ones
JQ_END='
def from_start:
	if $start == "" then .
	elif contains($start) then $start + (split($start) | .[1:] | join($start))
	else empty end;

def to_end:
	split($end) as $parts
	| select(($parts | length) > 1)
	| ($parts[:-1] | join($end)) + (if $strip_end then "" else $end end);

last(
	transcript_objects
	| .line as $line
	| .entry | .. | strings
	| select(contains($end))
	| from_start | to_end
	| select($require == "" or contains($require))
	| [$line, trim_newlines + "\n"]
)
'

# The reply of an assistant message is its text blocks plus the report a
# SubagentHandback tool call carries in input.message: a subagent that ends
# with that tool sends its whole report there, not as text. Other blocks
# (thinking, other tool calls) are no reply. Claude Code writes one content
# block per JSONL line, all sharing the message id, so the last message is
# every assistant line carrying the last assistant line's id. Each part loses
# its trailing newlines, empty parts are dropped, and the rest are joined by
# one blank line. A message whose last block is any other tool call was cut
# off mid-work; the third element flags it so nothing is saved.
# shellcheck disable=SC2016  # $names here are jq variables, not shell ones
JQ_WHOLE='
def is_assistant: .type == "assistant" and ((.message | objects | .role) == "assistant");

def is_handback: .type == "tool_use" and .name == "SubagentHandback";

def reply_parts:
	if type == "string" then .
	elif type == "array" then
		.[] | objects
		| if .type == "text" then .text
		  elif is_handback then (.input | objects | .message)
		  else empty end
	else empty end
	| strings;

[ transcript_objects | select(.entry | is_assistant)
  | {line, id: (.entry.message.id // null), content: .entry.message.content} ]
| select(length > 0)
| last as $tail
| (if $tail.id == null then [$tail] else map(select(.id == $tail.id)) end) as $message
| ([$message[].content | arrays | .[] | objects] | last) as $final_block
| ($final_block != null and $final_block.type == "tool_use" and ($final_block | is_handback | not)) as $cut_off
| [$message[].content | reply_parts | trim_newlines | select(. != "")] | join("\n\n")
| [$tail.line, (if . == "" then "" else . + "\n" end), $cut_off]
'

if (( OPT_WHOLE )); then
	jq_program=${JQ_COMMON}${JQ_WHOLE}
else
	jq_program=${JQ_COMMON}${JQ_END}
fi

jq_status=0
jq -c -n \
	--rawfile transcript "${OPT_TRANSCRIPT}" \
	--arg end "${OPT_END}" \
	--arg start "${OPT_START}" \
	--arg require "${OPT_REQUIRE}" \
	--argjson strip_end "${OPT_STRIP_END}" \
	"${jq_program}" >"${PICK_FILE}" || jq_status=$?
if (( jq_status != 0 )); then
	error "internal error: jq exited ${jq_status} while reading the transcript; expected 0. Try: read jq's message above; check the jq version (1.6+ needed): $(jq --version 2>&1 || true)"
	exit 5
fi

if [[ ! -s "${PICK_FILE}" ]]; then
	if (( OPT_WHOLE )); then
		error "no reply in ${OPT_TRANSCRIPT}: no line is an assistant message, so the agent was cut off before replying; expected a subagent JSONL transcript; check the path, else handle it as a cut-off reply"
		exit 1
	fi
	criteria="the end line '${OPT_END}'"
	[[ -z "${OPT_START}" ]] || criteria+=" after the start '${OPT_START}'"
	[[ -z "${OPT_REQUIRE}" ]] || criteria+=" with '${OPT_REQUIRE}'"
	error "no candidate in ${OPT_TRANSCRIPT}: no JSON string holds ${criteria}; check --end, --start and --require against the report the subagent sent"
	exit 1
fi

FROM_LINE=$(jq -r '.[0]' <"${PICK_FILE}")
CUT_OFF=$(jq -r '.[2] // false' <"${PICK_FILE}")
if [[ "${CUT_OFF}" == true ]]; then
	error "no reply in ${OPT_TRANSCRIPT}: the last assistant message (transcript line ${FROM_LINE}) ends in a tool call other than SubagentHandback, so the agent was cut off mid-work; nothing was saved; handle it as a cut-off reply"
	exit 1
fi
jq -j '.[1]' <"${PICK_FILE}" >"${REPORT_TMP}"

# ---------------------------------------------------------------------------
# Secret guard: name, then ERE. Only grep's line numbers are kept.
# ---------------------------------------------------------------------------
SECRET_PATTERNS=(
	# GitHub's classic token format: the prefix and exactly 36 characters.
	"github-token" 'gh[po]_[A-Za-z0-9]{36}'
	# GitHub's fine-grained token format: the prefix, a 22-character segment,
	# then more; 22 is the shortest real token's floor.
	"github-pat" 'github_pat_[A-Za-z0-9_]{22,}'
	# sk- keys have no single documented length; 20 is a lower bound chosen to
	# skip short sk- words in prose while every real key is far longer.
	"sk-key" '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}'
	# AWS's access key id format: AKIA and exactly 16 characters.
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
		error "internal error: grep exited ${grep_status} on the secret pattern ${name}; nothing was saved; expected grep exit 0 or 1; try re-running, and check the --out directory's free space and grep's message above"
		exit 5
	fi
	if [[ -n "${hits}" ]]; then
		error "secret guard: likely ${name} at report line(s) ${hits% }"
		found_secret=1
	fi
done
if (( found_secret )); then
	error "secret guard: nothing written to ${OPT_OUT}; mask the secret (e.g. ghp_****) and write the masked reply to ${OPT_OUT} yourself; never save it unmasked; do not re-dispatch the agent"
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
		error "internal error: could not create ${OPT_OUT}; expected a hard link in the same directory to succeed; nothing was saved; try re-running, and check the --out directory's free space and whether its filesystem allows hard links"
		exit 5
	fi
	rm -f -- "${REPORT_TMP}"
fi
REPORT_TMP=""

LINE_COUNT=$(wc -l <"${OPT_OUT}")
LINE_COUNT=${LINE_COUNT//[[:space:]]/}
printf 'saved: %s lines=%s from-line=%s\n' "${OPT_OUT}" "${LINE_COUNT}" "${FROM_LINE}"
