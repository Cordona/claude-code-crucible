#!/usr/bin/env sh
# Prints the human's compact card for one test plan draft the stop hook
# recorded. Everything comes from the seat's test-plan.made event: its body
# is the plan, its place among the seat's test-plan.made events since its
# last test.committed or closed plan the draft number, and its dispatch
# (through the dispatch.made event) the plugins. views/plan-card.jq lays it
# out and human-view's show.sh prints it. Nothing is written to the effort.
set -eu
umask 077

readonly PROG='plan-card.sh'
readonly MODULE='plan-card'
readonly VIEW_LIB='human-view'
readonly SHOW='scripts/show.sh'
readonly RENDER_LIB='scripts/lib/render.sh'
# Its seats.jq holds the one seat-name check.
readonly SEATS_LIB='procedure-seat-run/scripts/seats'
readonly EVENTS='crucible/scripts/events.sh'
readonly PLAN_TYPE='test-plan.made'
readonly TESTS_TYPE='test.committed'
readonly ANSWER_TYPE='gate.test-plan.answered'
readonly DRAFT_MODULE='plan-draft'
readonly newline='
'
# The C locale keeps the shell byte-wise; jq reads the plan as UTF-8.
LC_ALL=C
export LC_ALL

# The card's data for views/plan-card.jq. Input: the plan event.
# shellcheck disable=SC2016 # the programs are single-quoted on purpose: their $ signs are jq's
readonly CARD_DATA_JQ='($labels | split("\n")) as $names
| {plan: .body,
	labels: {language: $names[0], frameworks: $names[1:] | map(select(. != ""))},
	card: {seat: $seat, draft: ($draft | tonumber), plan_path: $plan_path}}'

# The seat's plan event, seq $seq or the newest, and its draft number by
# plan-draft.jq. Input: three arrays, the effort's test-plan.made,
# test.committed and test-plan gate answer events.
# shellcheck disable=SC2016
readonly EVENT_JQ='include "plan-draft";
add | sort_by(.seq) as $events
| ($events | map(select(.seat == $seat and .type == $plan_type and ($seq == "" or .seq == ($seq | tonumber)))) | last) as $plan
| select($plan != null)
| {event: $plan, draft: ($events | plan_draft($seat; $plan.seq))}'

# The language's plugin name, then each framework's, one per line, of the
# dispatch.made event of seq $id. Input: the dispatch.made events.
# shellcheck disable=SC2016
readonly PLUGINS_JQ='map(select((.seq | tostring) == $id)) | last // empty
| .body.plugins // {} | (.language.name // ""), (.frameworks // [] | .[] | .name // empty)'

# Prints a plugin SKILL.md's metadata.label by flow-code-agent-dispatch's
# list-plugins.sh rules, as the build card reads it: the frontmatter opens
# on line 1 and is closed by ---; a "  label:" line under a "metadata:" line
# (a trailing comment allowed), the last one counting; a ` # comment` after
# an unquoted value dropped, one pair of quotes removed and tabs made
# spaces. Prints nothing when the frontmatter is not closed.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $0 is awk's
readonly PLUGIN_LABEL_AWK='
function clean(value) {
	sub(/^[ \t]+/, "", value)
	if (value !~ /^["\047]/) sub(/[ \t]+#.*$/, "", value)
	sub(/[ \t]+$/, "", value)
	if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
	sub(/^[ \t]+/, "", value)
	sub(/[ \t]+$/, "", value)
	gsub(/\t/, " ", value)
	return value
}
{ sub(/\r$/, "") }
NR == 1 { if ($0 != "---") exit; next }
$0 == "---" { closed = 1; exit }
/^[^ \t#]/ { in_metadata = ($0 ~ /^metadata:[ \t]*(#.*)?$/); next }
in_metadata && /^  label:/ { label = clean(substr($0, index($0, ":") + 1)) }
END { if (closed) print label }
'

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --seat S [--seq N] [--skills-dir DIR]
       sh ${PROG} --help | -h

Prints the compact Markdown card of one test plan draft: tester seat S's
newest ${PLAN_TYPE} event, or the one with seq N. ${VIEW_LIB}'s show.sh
prints it from views/${MODULE}.jq and records it as owed this session (see
its --help); nothing is written to the effort.

--effort FOLDER   absolute path of the effort folder
--seat S          the tester seat, a seat name by seats.jq
--seq N           a whole number: that ${PLAN_TYPE} event of the seat
--skills-dir DIR  absolute; default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills;
                  holds ${VIEW_LIB} (its ${SHOW} and
                  ${RENDER_LIB}), ${EVENTS%%/*} (its events.sh),
                  ${SEATS_LIB%%/*} (its seats.jq) and each plugin,
                  whose metadata.label titles the card (the plugin name
                  when it has none)

Title: "<language> test agent <letter> · test plan · draft <N>", the
plugins those of the dispatch.made event whose seq is the event's
dispatch (none without one); N counts the seat's ${PLAN_TYPE} events up
to this one after the later of its last ${TESTS_TYPE} and its last closed
plan before this one: a ${ANSWER_TYPE} event whose view names S and
whose answer is Stop or Agree, no tests, with or without " (Recommended)".
Then, each only when the plan has it: the blocker, why no tests are
needed, a failing baseline with no blocker (the tests it repairs), what
will be tested after this (each behaviour's text), the tests to add,
modify and remove counted, and each untested case with its
recommendation. No plan id is shown.

last line: the event's path, which holds the plan in its body.

stdout: the card, for the human

environment:
  CLAUDE_CODE_SESSION_ID  set by the Bash tool; unset or empty: the card is
                    printed, nothing is recorded
  CLAUDE_CONFIG_DIR  the Claude Code config folder; default \$HOME/.claude

exit codes:
  0  the card is printed
  2  wrong command line: a missing, repeated or unknown option, a path that
     is not absolute, a --seq that is no number; fix the call
  3  input: S is no seat name, the seat has no such ${PLAN_TYPE} event,
     or its body is no JSON object; one stderr line
  4  environment: jq missing or failed, views/${MODULE}.jq or
     scripts/${DRAFT_MODULE}.jq not in this skill, or ${VIEW_LIB}/${SHOW},
     ${VIEW_LIB}/${RENDER_LIB}, ${EVENTS} or
     ${SEATS_LIB}/seats.jq not in the skills dir;
     or show.sh failed (its stderr names why) or the reader was gone
  129, 130, 143  show.sh stopped by HUP, INT or TERM

needs: POSIX sh, awk, jq 1.6+
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 $4"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	effort='' seat='' seq='' skills_dir=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" FOLDER
				effort=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--seq)
				take_value "$1" "${seq}" "${2-}" N
				seq=${option_value}
				;;
			--skills-dir)
				take_value "$1" "${skills_dir}" "${2-}" DIR
				skills_dir=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat, --seq, --skills-dir or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort FOLDER'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
	require_absolute --effort "${effort}"
	while [ "${effort}" != "${effort%/}" ]; do effort=${effort%/}; done
	case ${seq} in
		*[!0-9]* | 0*)
			shown_seq=$(printable "${seq}")
			usage_error "--seq ${shown_seq} is not a whole number from 1; expected an event's seq"
			;;
		*) ;;
	esac
	if [ -z "${skills_dir}" ]; then
		skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	fi
	require_absolute --skills-dir "${skills_dir}"
	skills_dir=${skills_dir%/}
}

# Refuses option $1 whose path $2 is not absolute.
require_absolute() {
	case $2 in
		/*) ;;
		*)
			shown_path=$(printable "$2")
			usage_error "$1 ${shown_path} is not absolute; expected an absolute path"
			;;
	esac
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	# The logical path, links kept as named: show.sh names the card's skill after it.
	views_dir=$(cd -- "${own_path}/../views" && pwd) || die 4 "this skill's views folder could not be entered; expected views/ beside scripts/"
	[ -f "${own_path}/${DRAFT_MODULE}.jq" ] || die 4 "${DRAFT_MODULE}.jq not found beside ${PROG}; expected both in one folder"
	view_dir="${skills_dir}/${VIEW_LIB}"
	seats_dir="${skills_dir}/${SEATS_LIB}"
	events_script="${skills_dir}/${EVENTS}"
	render_lib="${view_dir}/${RENDER_LIB}"
	for needed in "${render_lib}" "${seats_dir}/seats.jq" "${events_script}"; do
		[ ! -f "${needed}" ] || continue
		shown_needed=$(printable "${needed}")
		die 4 "${shown_needed} not found; install its skill or pass --skills-dir"
	done
	# shellcheck source=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${view_dir}/scripts" "${views_dir}" "${MODULE}" || die 4 "${hv_printer_problem}"
	show_script=${hv_show}
}

# Refuses a seat that is no seat name by seats.jq, so it is safe in a path.
check_seat_name() {
	name_problem=$(jq -nr -L "${seats_dir}" --arg name "${seat}" 'include "seats"; $name | seats_name_problem' </dev/null) ||
		die 4 "jq failed checking the seat name; expected jq 1.6+ and ${SEATS_LIB}/seats.jq"
	[ -n "${name_problem}" ] || return 0
	shown_problem=$(printable "${name_problem}")
	die 3 "--seat ${shown_problem}"
}

# Prints events.sh slurp's output for "$@".
slurp() {
	sh "${events_script}" slurp --effort "${effort}" "$@" </dev/null ||
		die 4 'events.sh slurp failed (its stderr is above)'
}

# Sets event, the plan event, and from it draft, dispatch and plan_path.
read_event() {
	plans=$(slurp --type "${PLAN_TYPE}")
	tests=$(slurp --type "${TESTS_TYPE}")
	answers=$(slurp --type "${ANSWER_TYPE}")
	found=$(printf '%s\n%s\n%s\n' "${plans}" "${tests}" "${answers}" |
		jq -cs -L "${own_path}" --arg seat "${seat}" --arg seq "${seq}" --arg plan_type "${PLAN_TYPE}" "${EVENT_JQ}") ||
		die 4 'jq could not read the events events.sh slurp printed'
	[ -n "${found}" ] || die 3 "seat ${seat} has no ${PLAN_TYPE} event${seq:+ with seq ${seq}}; expected a plan the stop hook recorded"
	fields=$(printf '%s\n' "${found}" |
		jq -r '.draft, .event.seq, (.event.dispatch // "" | tostring), (.event.body | type)') ||
		die 4 'jq could not read the plan event'
	draft='' event_seq='' dispatch='' body_type=''
	{
		IFS= read -r draft || :
		IFS= read -r event_seq || :
		IFS= read -r dispatch || :
		IFS= read -r body_type || :
	} <<EOF
${fields}
EOF
	[ "${body_type}" = object ] || die 3 "event ${event_seq}'s body is a JSON ${body_type}; expected the plan the stop hook checked"
	event=$(printf '%s\n' "${found}" | jq -c '.event') || die 4 'jq could not read the plan event'
	plan_path=$(printf '%s/events/%06d-%s.json' "${effort}" "${event_seq}" "${PLAN_TYPE}")
	[ -f "${plan_path}" ] || die 4 "event ${event_seq} is not at ${plan_path}; expected events.sh's file name"
}

# Sets labels: the language's label, then each framework's, one per line,
# from the event's dispatch; none without its dispatch.made event.
read_labels() {
	labels=''
	[ -n "${dispatch}" ] || return 0
	dispatches=$(slurp --type dispatch.made)
	names=$(printf '%s\n' "${dispatches}" | jq -r --arg id "${dispatch}" "${PLUGINS_JQ}") ||
		die 4 'jq could not read the dispatch.made events'
	[ -n "${names}" ] || return 0
	first=yes
	while IFS= read -r name; do
		label=$(plugin_label "${name}")
		if [ "${first}" = yes ]; then
			labels=${label} first=no
		else
			labels="${labels}${newline}${label}"
		fi
	done <<EOF
${names}
EOF
}

# Prints plugin $1's metadata.label, or $1 when it is not installed or has
# none; a name that is no skill name is never looked up as a path.
plugin_label() {
	label=''
	case $1 in
		'' | *[!a-z0-9-]* | -* | *-) ;;
		*)
			skill_file="${skills_dir}/$1/SKILL.md"
			[ ! -f "${skill_file}" ] || label=$(awk "${PLUGIN_LABEL_AWK}" "${skill_file}" 2>/dev/null) || label=''
			;;
	esac
	printf '%s' "${label:-$1}" | tr '[:cntrl:]' ' '
}

print_card() {
	card_data=$(printf '%s\n' "${event}" | jq -c \
		--arg labels "${labels}" --arg seat "${seat}" --arg draft "${draft}" \
		--arg plan_path "${plan_path}" "${CARD_DATA_JQ}") ||
		die 4 "jq could not build the card's data; expected jq 1.6+"
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${show_script}" "${views_dir}" "${MODULE}" "${effort}" "${card_data}" ||
		die 4 "show.sh could not print the card (its stderr is above)"
}

parse_args "$@"
load_dependencies
check_seat_name
read_event
read_labels
print_card
