#!/usr/bin/env sh
# Renders the effort offer, the gate that asks the human whether to start an
# effort, from a JSON file of reasons, so the main thread never hand-formats
# it. The title is fixed; the reasons are the only input. Pipe its stdout into
# procedure-approval-gate's open-gate.sh.
set -eu

readonly PROG='render-effort-offer.sh'
# The offer stays a glance: a handful of one-line reasons, each short enough
# to fit one terminal line beside its bullet.
readonly MAX_REASONS=5
readonly MAX_REASON_CHARS=100

# Prints one line per problem of the slurped input; nothing when it can be
# rendered. The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly CHECK_JQ='
def expected_reasons: "expected an array of 1 to \($max_reasons) strings";
def reason_problem:
	"reasons[\(.key)]" as $at
	| .value
	| if type != "string" then "\($at) is a JSON \(type); expected a string"
	  elif test("^[[:space:]]*$") then "\($at) is empty; expected one line of text; try saying why in a few words"
	  elif test("[[:cntrl:]\u2028\u2029]") then "\($at) holds a control character or a line or paragraph separator (such as a line break, tab or U+2028); expected one line of plain text; try joining it into one line"
	  elif length > $max_chars then "\($at) is \(length) characters; expected at most \($max_chars); try a shorter reason"
	  else empty end;
def reasons_problems:
	if has("reasons") | not then "reasons missing; \(expected_reasons)"
	elif (.reasons | type) != "array" then "reasons is a JSON \(.reasons | type); \(expected_reasons)"
	elif (.reasons | length) < 1 or (.reasons | length) > $max_reasons then "reasons holds \(.reasons | length) items; \(expected_reasons)"
	else .reasons | to_entries[] | reason_problem end;
if length != 1 then "expected exactly one JSON object, got \(length) values; try {\"reasons\": [\"...\"]}"
elif (.[0] | type) != "object" then "input is a JSON \(.[0] | type); expected an object {\"reasons\": [...]}"
else .[0]
	| ((keys - ["reasons"])[] | "\(tojson) is an unknown field; expected only reasons"),
	  reasons_problems
end
'

# A reason that starts like a Markdown block (a heading, a quote, a rule, a
# list item or a code fence) gets that start backslash-escaped, so every reason
# renders as one plain bullet; inline Markdown stays as written.
# shellcheck disable=SC2016
readonly RENDER_JQ='
def block_start: "^(#{1,6}( |$)|>|(?<rule>[-*_])( *\\k<rule>){2,} *$|[-+*]( |$)|```|~~~)";
def ordered_start: "^[0-9]{1,9}[.)]( |$)";
def one_bullet:
	if test(block_start) then "\\" + .
	elif test(ordered_start) then sub("^(?<number>[0-9]{1,9})"; "\(.number)\\")
	else . end;
"## 🧭 This looks like a bigger piece of work\n\n"
	+ (.[0].reasons | map("- " + (sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | one_bullet)) | join("\n"))
'

usage() {
	cat <<EOF
usage: sh ${PROG} --plan-file PATH | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label effort-offer
       sh ${PROG} --help | -h

Prints the effort offer, the gate asking the human whether to start an effort,
as Markdown from a JSON file of reasons. stdin is never read; no file is
written.

Options:
  --plan-file PATH  one JSON object, {"reasons": [str, ...]}, no other field:
                    1 to ${MAX_REASONS} reasons, each not blank, with no control character
                    (line break, tab) or U+2028/U+2029, at most ${MAX_REASON_CHARS} characters
                    (code points, as written); inline Markdown in a reason
                    renders, a leading block mark (#, >, -, 1.) shows as text

stdout on exit 0 only: the offer's Markdown, a fixed title and one bullet per
  reason in input order, with no gate marker
stderr on exit 2: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem (a usage error adds a "Try" line); a reason is named
  reasons[<i>], from 0, with its first fault only
stderr on exits 1, 3: "${PROG}: install:", a prefix no other exit
  prints; tell the human to install jq 1.6+, and stop

Exit codes:
  0  the offer printed; go on
  1  jq missing
  2  refused input; fix what stderr names and rerun once, else show the human stderr
  3  jq failed on valid JSON
  4  stdout closed before the offer was written, nothing on stderr; stop and
     show the exit code

Dependencies: POSIX sh, cat, jq 1.6+ (macOS: brew install jq; Linux: the
  distro's jq package); the plan file is read as UTF-8 whatever the locale.
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Prints an install or host fault (a missing or failing tool, never a problem
# of the input) with the "install:" prefix and exits $1.
install_fault() {
	warn "install: $2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Sets plan_file from the arguments.
parse_args() {
	plan_file=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--plan-file)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--plan-file needs a value; expected --plan-file PATH'
				plan_file=$2
				shift 2
				;;
			*) usage_error 'unknown argument; expected --plan-file PATH or --help' ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
}

# Prints the plan file slurped into one array, or exits 2 when it is
# unreadable or not JSON.
read_input() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		usage_error "plan file not readable: ${plan_file}; expected a readable JSON file"
	jq -s '.' "${plan_file}" </dev/null 2>/dev/null && return 0
	warn 'input is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
	exit 2
}

# Runs jq program $1 over the slurped input; a jq failure exits 3.
run_jq() {
	printf '%s' "${slurped}" | jq -r --argjson max_reasons "${MAX_REASONS}" --argjson max_chars "${MAX_REASON_CHARS}" "$1" || {
		install_fault 3 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	}
}

parse_args "$@"
command -v jq >/dev/null 2>&1 ||
	install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'

# One slurped value so an empty file and several values are caught as one problem.
slurped=$(read_input)
problems=$(run_jq "${CHECK_JQ}")
if [ -n "${problems}" ]; then
	printf '%s\n' "${problems}" | while IFS= read -r problem; do warn "${problem}"; done
	exit 2
fi
offer=$(run_jq "${RENDER_JQ}")
# Ignoring SIGPIPE turns a closed reader into a failed write this script can
# tell apart from a jq fault, rather than a silent kill.
trap '' PIPE
printf '%s\n' "${offer}" 2>/dev/null || exit 4
