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
Usage: sh ${PROG} --plan-file PATH | sh <skills>/procedure-approval-gate/scripts/open-gate.sh
       sh ${PROG} --help | -h

Reads the effort offer's reasons as one JSON object from PATH and prints the
offer's Markdown. PATH is required; stdin is not read. It prints no gate
marker; open-gate.sh adds it.

Input shape, no other field:
  {"reasons": [str, ...]}
1 to ${MAX_REASONS} reasons, each a string that is not blank, holds no control character
(no line break or tab) and no U+2028 or U+2029 line or paragraph separator,
and is at most ${MAX_REASON_CHARS} characters (Unicode code points, as written).

Layout:
  ## 🧭 This looks like a bigger piece of work
  (a blank line)
  - <reason>       one line per reason, in input order
The title is fixed. A reason prints as written, without its leading and
trailing spaces, so each one renders as exactly one bullet item: a reason that
starts like a Markdown block gets a backslash before that start, which shows
it as plain text:
  # to ######, then a space or the end   (heading)    -> \\#
  >                                      (quote)      -> \\>
  ---, ***, ___ (3 or more, spaces between allowed, nothing else)
                                         (rule)       -> \\-, \\*, \\_
  -, + or *, then a space or the end     (list item)  -> \\-, \\+, \\*
  1 to 9 digits, then . or ), then a space or the end
                                         (numbered)   -> 1\\. or 1\\)
  \`\`\` or ~~~                             (code fence) -> \\\`\`\` or \\~~~
Inline Markdown stays as written and renders as Markdown, so a \`name\` pair
shows as code.

Anything else is refused, nothing on stdout, exit 2, one stderr line per
problem, each "${PROG}: <what>; expected <x>", most with
"; try <y>": not exactly one JSON value, not an object, a field other than reasons (each
named), reasons missing, not an array, or with fewer than 1 or more than ${MAX_REASONS}
items, and per reason ("reasons[<index>]", from 0) its first fault: not a
string, empty or blank, a control character or U+2028/U+2029, more than
${MAX_REASON_CHARS} characters.
Every install fault (exits 1 and 3) prints one line starting
"${PROG}: install:"; no other line does.

Exit codes:
  0  the offer printed
  1  jq missing
  2  usage error (--plan-file missing or empty, or an unknown argument), an
     unreadable plan file, input that is not JSON, or input refused as above
  3  jq failed while checking or rendering valid JSON
  4  stdout closed or not writable (such as a reader that exits before
     reading); nothing on stderr, as with any closed pipe

Dependencies: POSIX sh, cat, jq 1.6+ (macOS: brew install jq; Linux: the
distro's jq package); jq reads and writes UTF-8 whatever the locale.
Runtime: about 20 ms an offer, --help about 8 ms; measured on macOS (mean of
20 runs).
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
