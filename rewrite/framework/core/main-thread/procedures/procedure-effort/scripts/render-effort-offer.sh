#!/usr/bin/env sh
# Renders the effort offer, the gate that asks the human whether to start an
# effort, or with --case the state offer, which asks what should happen to the
# open effort when new work comes or suggests completing it, from a JSON file
# of reasons, so the main thread never hand-formats it. Pipe its stdout into
# procedure-approval-gate's open-gate.sh.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='render-effort-offer.sh'
readonly RENDER_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly DEFAULT_TITLE='start an effort for this?'
# The title shares the first line with "Decision needed · ", so
# it stays short enough for that line to fit one terminal line.
readonly MAX_TITLE_CHARS=60
# The offer stays a glance: a handful of one-line reasons, each short enough
# to fit one terminal line beside its list number.
readonly MAX_REASONS=5
readonly MAX_REASON_CHARS=100

# Prints one line per problem of the slurped input; nothing when it can be
# rendered. The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly CHECK_JQ='
def title_problems:
	$title
	| if test("^[[:space:]]*$") then "--title is blank; expected one line of text; try the question in a few words"
	  elif test("[[:cntrl:]\u2028\u2029]") then "--title holds a control character or a line or paragraph separator (such as a line break, tab or U+2028); expected one line of plain text; try joining it into one line"
	  elif length > $max_title_chars then "--title is \(length) characters; expected at most \($max_title_chars); try a shorter title"
	  else empty end;
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
title_problems,
(if length != 1 then "expected exactly one JSON object, got \(length) values; try {\"reasons\": [\"...\"]}"
elif (.[0] | type) != "object" then "input is a JSON \(.[0] | type); expected an object {\"reasons\": [...]}"
else .[0]
	| ((keys - ["reasons"])[] | "\(tojson) is an unknown field; expected only reasons"),
	  reasons_problems
end)
'

# Each reason is trimmed and its leading Markdown block mark escaped, so it
# renders as one plain line or list item. Without $case: the effort offer,
# with the efforts this session already works on ($open_efforts, one NAME per
# line, a repeat shown once) and the way out before the reasons when any are
# given, the way out left out when $way_out_shown is "true"; with it: the state
# offer, its two first lines fixed per case and the reasons as bullets,
# new-work ending with the way out. The program is single-quoted on purpose:
# its $ signs are jq's.
# shellcheck disable=SC2016
readonly RENDER_JQ='include "view";
include "paths";
def trimmed: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
def way_out: "A new session or /clear keeps each effort clean.";
(.[0].reasons | map(trimmed | plain_line)) as $reasons
| ($open_efforts | split("\n") | map(select(. != ""))
	| reduce .[] as $effort ([]; if any(.[]; . == $effort) then . else . + [$effort] end)) as $open
| if $case == "" then
	[status_line("decision"; "Decision needed · \($title | trimmed)"),
	 (if ($open | length) == 0 then "" else "**This session already works on:**\n\($open | map(code_span) | bullet_list)" end),
	 (if ($open | length) == 0 or $way_out_shown == "true" then "" else way_out end),
	 section("Why"; $reasons)]
  else
	{"new-work": {title: "It seems that you are planning something new.", suggestion: "What should happen to the open effort?", tail: way_out},
	 done: {title: "It looks like \($name | code_span) is done.", suggestion: "You should consider completing it:", tail: ""}}[$case] as $lines
	| [status_line("decision"; $lines.title), "\($lines.suggestion)\n\($reasons | bullet_list)", $lines.tail]
  end
| blocks
'

usage() {
	cat <<EOF
usage: sh ${PROG} --plan-file PATH [--title TEXT] [--open-effort NAME]... [--after-state-offer] | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label effort-offer
       sh ${PROG} --plan-file PATH --case new-work|done --name NAME | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label effort-state-offer
       sh ${PROG} --help | -h

Prints the effort offer, the gate asking the human whether to start an effort,
or with --case the state offer, which asks what should happen to the open
effort NAME when new work comes (new-work) or suggests completing it (done),
as Markdown from a JSON file of reasons. stdin is never read; no file is
written.

Options:
  --plan-file PATH  one JSON object, {"reasons": [str, ...]}, no other field:
                    1 to ${MAX_REASONS} reasons, each not blank, with no control character
                    (line break, tab) or U+2028/U+2029, at most ${MAX_REASON_CHARS} characters
                    (code points, as written); inline Markdown in a reason
                    renders, a leading block mark (#, >, -, 1.) shows as text
  --title TEXT      the text after "Decision needed · " on the first line,
                    default "${DEFAULT_TITLE}": not blank, one line with no
                    control character or U+2028/U+2029, at most ${MAX_TITLE_CHARS}
                    characters (code points, as written); inline Markdown
                    renders; not with --case
  --open-effort NAME  the effort offer: an effort this session already works
                    on, shown before the reasons with the way out; once per
                    effort, a repeat shown once; with --case, checked and not
                    shown, since the state offer carries its own way out
  --after-state-offer  the effort offer right after a new-work state offer,
                    which already showed the way out: the way out is not
                    shown again; not with --case
  --case CASE       the state offer: new-work or done; needs --name
  --name NAME       with --case: the effort's NAME
  NAME              as the crucible skill's lib/crucible-space.sh sets it
  CLAUDE_CONFIG_DIR  holds the skills, in its skills/; default \$HOME/.claude

stdout on exit 0 only: the offer's Markdown, the reasons in input order,
  with no gate marker
stderr on exit 2: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem (a usage error adds a "Try" line); a reason is named
  reasons[<i>], from 0, and the title --title, each with its first fault only
stderr on exits 1, 3, 5: "${PROG}: install:", a prefix no other exit
  prints: an install fault, never a problem of the input; do not rerun; stop

Exit codes:
  0  the offer printed; go on
  1  jq missing
  2  refused input; fix what stderr names and rerun once, else show the human stderr
  3  jq failed on valid JSON
  4  stdout closed before the offer was written, nothing on stderr; stop and
     show the exit code
  5  the ${RENDER_LIB} skill's view.jq or paths.jq, or with --case or
     --open-effort the ${CRUCIBLE_SKILL} skill's lib/crucible-space.sh, missing

Dependencies: POSIX sh, cat, jq 1.6+ (macOS: brew install jq; Linux: the
  distro's jq package), the ${RENDER_LIB} skill's view.jq and paths.jq in the
  skills, and with --case or --open-effort the ${CRUCIBLE_SKILL} skill's
  scripts/lib/crucible-space.sh; the plan file is read as UTF-8 whatever the
  locale.
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

# Sets plan_file, title, offer_case, name, open_efforts and way_out_shown from
# the arguments.
parse_args() {
	plan_file='' title_given=false offer_case='' name='' open_efforts='' way_out_shown=false
	title=${DEFAULT_TITLE}
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
			--title)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--title needs a value; expected --title TEXT'
				title=$2 title_given=true
				shift 2
				;;
			--case)
				[ "$#" -ge 2 ] || usage_error '--case needs a value; expected --case new-work or --case done'
				case $2 in
					new-work | done) offer_case=$2 ;;
					*) usage_error 'bad --case; expected new-work or done' ;;
				esac
				shift 2
				;;
			--name)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--name needs a value; expected --name NAME'
				name=$2
				shift 2
				;;
			--open-effort)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--open-effort needs a value; expected --open-effort NAME'
				# Kept one per line, so a line break inside one is refused here;
				# check_names checks each against the NAME rule.
				case $2 in
					*[[:cntrl:]]*) usage_error 'bad --open-effort: it holds a control character; expected the effort NAME' ;;
					*) ;;
				esac
				open_efforts="${open_efforts}$2
"
				shift 2
				;;
			--after-state-offer)
				way_out_shown=true
				shift
				;;
			*) usage_error 'unknown argument; expected --plan-file PATH, --title TEXT, --open-effort NAME, --after-state-offer, --case CASE, --name NAME or --help' ;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
	if [ -n "${offer_case}" ]; then
		[ "${title_given}" = false ] || usage_error '--title and --case given together; expected --title for the effort offer or --case for the state offer'
		[ -n "${name}" ] || usage_error '--name missing; expected --case CASE --name NAME'
		[ "${way_out_shown}" = false ] || usage_error '--after-state-offer and --case given together; expected --after-state-offer for the effort offer only'
	else
		[ -z "${name}" ] || usage_error '--name given without --case; expected --case new-work|done --name NAME'
	fi
}

# With --case or --open-effort: exits 5 when the space rules are missing, 2
# when a NAME breaks the effort NAME rule.
check_names() {
	[ -n "${offer_case}" ] || [ -n "${open_efforts}" ] || return 0
	space_lib="${skills_dir}/${CRUCIBLE_SKILL}/scripts/lib/crucible-space.sh"
	[ -f "${space_lib}" ] && [ -r "${space_lib}" ] ||
		install_fault 5 "space rules missing; expected ${space_lib}; install the ${CRUCIBLE_SKILL} skill"
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${space_lib}"
	name_rule=${crucible_effort_name_rule#*-<NAME>, NAME }
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	[ -z "${offer_case}" ] || crucible_is_effort_words "${name}" ||
		usage_error "bad --name; expected the effort NAME, ${name_rule}"
	while IFS= read -r open_effort; do
		[ -n "${open_effort}" ] || continue
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		crucible_is_effort_words "${open_effort}" ||
			usage_error "bad --open-effort; expected the effort NAME, ${name_rule}"
	done <<EOF
${open_efforts}
EOF
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
	printf '%s' "${slurped}" | jq -r -L "${render_lib_dir}" --argjson max_reasons "${MAX_REASONS}" --argjson max_chars "${MAX_REASON_CHARS}" \
		--arg title "${title}" --argjson max_title_chars "${MAX_TITLE_CHARS}" --arg case "${offer_case}" --arg name "${name}" \
		--arg open_efforts "${open_efforts}" --arg way_out_shown "${way_out_shown}" "$1" || {
		install_fault 3 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	}
}

parse_args "$@"
command -v jq >/dev/null 2>&1 ||
	install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'

skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
render_lib_dir="${skills_dir}/${RENDER_LIB}"
for module in view.jq paths.jq; do
	[ -f "${render_lib_dir}/${module}" ] && [ -r "${render_lib_dir}/${module}" ] ||
		install_fault 5 "layout module missing; expected ${render_lib_dir}/${module}; install the ${RENDER_LIB} skill"
done
check_names

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
