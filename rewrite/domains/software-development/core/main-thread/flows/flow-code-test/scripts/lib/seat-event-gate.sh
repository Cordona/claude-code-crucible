# The plan file and event checks render-plan-gate.sh and render-test-next.sh
# share. A plan file {"seat", "title", "event"} names a tester seat, the
# title its TITLE: line printed, and the seat's newest event of type
# seg_type, as its source line (seg_source) names it; a newer one refuses
# the plan, so a gate never asks about a superseded draft or report. With no
# title, the title is the one the event's card shows: its plugins are the
# language and frameworks of the dispatch.made event the event names, each
# by its metadata.label, and "Generic test agent" when there is none. A
# plan's draft number is standard-code-test-report's plan-draft.jq count, the
# one its plan card shows. Sourced, so it sets no shell option; its names
# start with seg_. The sourcing script defines warn, install_fault (prints the install: line,
# exits 5) and refuse_problems (prints each problem line, exits 3 on any),
# and sets seg_type, seg_skills_dir and seg_plan_file before seg_load_plan.
# shellcheck shell=sh source-path=SCRIPTDIR
# shellcheck disable=SC2034 # its seg_ values are read by the sourcing scripts
# shellcheck disable=SC2154 # seg_type, seg_skills_dir and seg_plan_file are the sourcing script's

readonly SEG_TITLE_LIB='human-view'
readonly SEG_SEATS_LIB='procedure-seat-run/scripts/seats'
readonly SEG_CRUCIBLE='crucible/scripts'
readonly SEG_TESTS_TYPE='test.committed'
readonly SEG_PLAN_TYPE='test-plan.made'
readonly SEG_ANSWER_TYPE='gate.test-plan.answered'
# The plan card's draft count, shared so the gate names the same draft.
readonly SEG_DRAFT_LIB='standard-code-test-report/scripts'
readonly SEG_DRAFT_MODULE='plan-draft'
readonly SEG_DISPATCH_TYPE='dispatch.made'
readonly SEG_ROLE_WORD='test agent'
# A title is one TITLE: line; past this it is no title the dispatch printed.
readonly SEG_MAX_TITLE_CHARS=200
readonly SEG_NEWLINE='
'

# Prints one line per problem of the slurped plan file; nothing when it is one
# object holding a tester seat name, an event path string and, when given, a
# title naming the test agent.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly SEG_PLAN_CHECK_JQ='
include "seats";
def expected_plan: "expected one JSON object {\"seat\": SEAT[, \"title\": TITLE], \"event\": PATH}";
def string_problem($name; $what):
	if has($name) | not then "\($name) missing; expected \($what)"
	elif (.[$name] | type) != "string" then "\($name) is a JSON \(.[$name] | type); expected \($what)"
	elif .[$name] | test("^[[:space:]]*$") then "\($name) is empty; expected \($what)"
	elif .[$name] | test("[[:cntrl:]  ]") then "\($name) holds a control character or a line or paragraph separator; expected one line"
	else empty end;
def seat_problem:
	string_problem("seat"; "the tester seat") //
	(.seat | seats_name_problem | "seat \(.)") //
	(if .seat | startswith("\(seats_prefixes.tester)-") then empty
	 else "seat \(.seat | tojson) is no tester seat; expected \(seats_prefixes.tester)-<letter>" end);
def title_problem:
	if has("title") | not then empty
	else
		string_problem("title"; "the TITLE: line'\''s title, such as \"Kotlin \($role) with Spring\"") //
		(if (.title | length) > $max_title then "title is \(.title | length) characters; expected at most \($max_title), the TITLE: line as printed"
		 elif .title | contains($role) | not then "title \(.title | tojson) names no \($role); expected the tester seat'\''s TITLE: line"
		 else empty end)
	end;
if length != 1 then "the plan file holds \(length) JSON values; \(expected_plan)"
elif (.[0] | type) != "object" then "the plan file holds a JSON \(.[0] | type); \(expected_plan)"
else .[0]
	| ((keys - ["seat", "title", "event"])[] | "\(tojson) is an unknown field; expected only seat, title and event"),
	  seat_problem,
	  title_problem,
	  string_problem("event"; "the absolute path \($source) printed")
end
'

# The gate's facts from the seat's events. Input: the array of seg_type's
# events. Prints {problem} when the plan's event is not the seat's newest of
# its type, else {who: the seat's title with its letter after the role word,
# body: the event's body}.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly SEG_EVENT_JQ='
include "title";
def event_path: "\($effort)/events/\(("00000" + (.seq | tostring))[-6:])-\(.type).json";
def seat_who: split($role) as $parts | $parts[0] + $role + " " + ($seat | seat_letter) + ($parts[1:] | join($role));
sort_by(.seq) | map(select(.seat == $seat and .type == $type)) as $own
| (first($own[] | select(.seq == $seq)) // null) as $event
| if $event == null then {problem: "event \($path) is no \($type) event of seat \($seat); expected the event \($source) named for that seat"}
  elif ($own | last | .seq) != $seq then {problem: "a newer \($type) event of seat \($seat) exists: \($own | last | event_path); expected the seat'\''s newest, as \($source) names it; write the plan file again with it"}
  elif ($event.body | type) != "object" then {problem: "event \($path)'\''s body is a JSON \($event.body | type); expected the object the stop hook recorded"}
  else {who: ($title | seat_who), body: $event.body}
  end
'
# The plan's draft number by plan-draft.jq. Input: three arrays, the
# effort's test-plan.made, test.committed and test-plan gate answer events.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly SEG_DRAFT_JQ='include "plan-draft"; add | plan_draft($seat; $seq)'

# The language's plugin name, then each framework's, one per line, of the
# dispatch with id $id. Input: the dispatch.made events.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly SEG_PLUGINS_JQ='map(select(.body.id == $id)) | last // empty
| .body.plugins // {} | (.language.name // ""), (.frameworks // [] | .[] | .name // empty)'

# The title from the labels, one per line, the language's first. Input: none.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly SEG_TITLE_JQ='include "title";
($labels | split("\n")) as $names
| {language: $names[0], frameworks: ($names[1:] | map(select(. != "")))} | title($role)'

# Prints a plugin SKILL.md's metadata.label by flow-code-agent-dispatch's
# list-plugins.sh rules, as the card reads it: the frontmatter opens on line
# 1 and is closed by ---; a "  label:" line under a "metadata:" line (a
# trailing comment allowed), the last one counting; a ` # comment` after an
# unquoted value dropped, one pair of quotes removed and tabs made spaces.
# Prints nothing when the frontmatter is not closed.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $0 is awk's
readonly SEG_PLUGIN_LABEL_AWK='
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

# Exits 5 unless the files this lib reads are in the skills; sources the
# space rules.
seg_load_tools() {
	seg_seats_dir="${seg_skills_dir}/${SEG_SEATS_LIB}"
	seg_title_dir="${seg_skills_dir}/${SEG_TITLE_LIB}"
	seg_events_script="${seg_skills_dir}/${SEG_CRUCIBLE}/events.sh"
	seg_space_lib="${seg_skills_dir}/${SEG_CRUCIBLE}/lib/crucible-space.sh"
	seg_require "${seg_seats_dir}/seats.jq" procedure-seat-run 'seat name rules'
	seg_require "${seg_title_dir}/title.jq" "${SEG_TITLE_LIB}" 'title rules'
	seg_require "${seg_events_script}" crucible 'events.sh'
	seg_require "${seg_space_lib}" crucible 'space rules'
	seg_draft_dir="${seg_skills_dir}/${SEG_DRAFT_LIB}"
	[ "${seg_type}" != "${SEG_PLAN_TYPE}" ] ||
		seg_require "${seg_draft_dir}/${SEG_DRAFT_MODULE}.jq" "${SEG_DRAFT_LIB%%/*}" 'draft count'
	# shellcheck source=../../../../../../../../framework/core/engine/crucible/scripts/lib/crucible-space.sh
	. "${seg_space_lib}"
}

# Exits 5 unless file $1 is readable, naming skill $2 to install.
seg_require() {
	[ -f "$1" ] && [ -r "$1" ] || install_fault "$3 missing; expected $1; install the $2 skill"
}

# Sets seg_seat, seg_title, seg_event, seg_effort and seg_seq from the plan
# file, or exits 3 naming each problem.
seg_load_plan() {
	seg_set_source
	[ -f "${seg_plan_file}" ] && [ -r "${seg_plan_file}" ] ||
		refuse_problems "plan file not readable: ${seg_plan_file}; expected a readable JSON file"
	seg_slurped=$(jq -s '.' "${seg_plan_file}" </dev/null 2>/dev/null) ||
		refuse_problems 'the plan file is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
	seg_problems=$(printf '%s' "${seg_slurped}" | jq -r -L "${seg_seats_dir}" \
		--arg role "${SEG_ROLE_WORD}" --argjson max_title "${SEG_MAX_TITLE_CHARS}" --arg source "${seg_source}" \
		"${SEG_PLAN_CHECK_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	refuse_problems "${seg_problems}"
	seg_fields=$(printf '%s' "${seg_slurped}" | jq -r '.[0] | .seat, .title // "", .event') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	{
		IFS= read -r seg_seat || :
		IFS= read -r seg_title || :
		IFS= read -r seg_event || :
	} <<EOF
${seg_fields}
EOF
	seg_check_event
	refuse_problems "${seg_event_problem}"
}

# Sets seg_source to the output line main takes the event path from: the
# plan check's for a plan, the seat's paths' for a test report.
seg_set_source() {
	case ${seg_type} in
		test-plan.made) seg_source="plan-approval.sh's PLAN: line" ;;
		*) seg_source="iteration.sh's LAST_REPORT: line" ;;
	esac
}

# Sets seg_effort and seg_seq from the event path, or seg_event_problem to
# why it names no events/<seq>-<seg_type>.json file of an effort of the
# space, with no folder of it a symbolic link.
seg_check_event() {
	seg_event_problem='' seg_effort='' seg_seq=''
	case ${seg_event} in
		/*) ;;
		*)
			seg_event_problem="event is not absolute: ${seg_event}; expected the absolute path ${seg_source} printed"
			return 0
			;;
	esac
	# shellcheck disable=SC2310 # its status says whether the space is usable; the problem is kept
	if ! crucible_resolve_root; then
		seg_event_problem="CRUCIBLE_HOME: ${crucible_root_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status says whether the path is an effort's event
	if ! crucible_check_effort_item "${seg_event}" events; then
		seg_event_problem="event ${seg_event}: ${crucible_item_problem}"
		return 0
	fi
	seg_name=${seg_event##*/}
	case ${seg_name} in
		[0-9][0-9][0-9][0-9][0-9][0-9]-"${seg_type}".json) ;;
		*)
			seg_event_problem="event is not named as a ${seg_type} event: ${seg_name}; expected <6-digit seq>-${seg_type}.json"
			return 0
			;;
	esac
	if [ ! -f "${seg_event}" ] || [ -L "${seg_event}" ]; then
		seg_event_problem="event is not a regular file, or is a symbolic link: ${seg_event}; expected the event events.sh wrote"
		return 0
	fi
	seg_seq=${seg_name%%-*}
	while [ "${seg_seq}" != "${seg_seq#0}" ]; do seg_seq=${seg_seq#0}; done
	[ -n "${seg_seq}" ] || seg_event_problem="event ${seg_name} has seq 0; expected a seq from 000001, as events.sh writes"
	seg_effort=${crucible_effort}
}

# Sets seg_facts to the gate's facts (SEG_EVENT_JQ) from the effort's events,
# with a plan's draft number, or exits 3 when the plan's event is not the
# seat's newest of its type.
seg_load_event() {
	[ -n "${seg_title}" ] || seg_derive_title
	seg_slurp "${seg_type}"
	seg_events=${seg_slurped_events}
	seg_facts=$(printf '%s\n' "${seg_events}" | jq -c -L "${seg_title_dir}" \
		--arg seat "${seg_seat}" --arg title "${seg_title}" --arg role "${SEG_ROLE_WORD}" \
		--arg type "${seg_type}" --argjson seq "${seg_seq}" \
		--arg path "${seg_event}" --arg effort "${seg_effort}" --arg source "${seg_source}" "${SEG_EVENT_JQ}") ||
		install_fault 'jq failed on the events events.sh slurp printed; expected jq 1.6+; try jq --version, then rerun'
	seg_problems=$(printf '%s' "${seg_facts}" | jq -r '.problem // empty') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	refuse_problems "${seg_problems}"
	[ "${seg_type}" != "${SEG_PLAN_TYPE}" ] || seg_add_draft
}

# Adds the plan's draft number to seg_facts, counted as the plan card counts it.
seg_add_draft() {
	seg_slurp "${SEG_TESTS_TYPE}"
	seg_tests=${seg_slurped_events}
	seg_slurp "${SEG_ANSWER_TYPE}"
	seg_draft=$(printf '%s\n%s\n%s\n' "${seg_events}" "${seg_tests}" "${seg_slurped_events}" |
		jq -s -L "${seg_draft_dir}" --arg seat "${seg_seat}" --argjson seq "${seg_seq}" "${SEG_DRAFT_JQ}") ||
		install_fault "jq failed counting the draft; expected jq 1.6+ and ${SEG_DRAFT_LIB}/${SEG_DRAFT_MODULE}.jq"
	seg_facts=$(printf '%s' "${seg_facts}" | jq -c --argjson draft "${seg_draft}" '.draft = $draft') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
}

# Sets seg_slurped_events to the effort's events of type $1, one JSON array.
seg_slurp() {
	seg_slurped_events=$(sh "${seg_events_script}" slurp --effort "${seg_effort}" --type "$1" </dev/null) ||
		install_fault "events.sh slurp failed (its stderr is above); expected the ${SEG_CRUCIBLE%%/*} skill's events.sh to read ${seg_effort}"
}

# Sets seg_title to the title the event's card shows, from the plugins of
# the dispatch the event names.
seg_derive_title() {
	seg_dispatch=$(jq -r '.dispatch // "" | tostring' "${seg_event}" </dev/null) ||
		install_fault "jq could not read the event ${seg_event}; expected the JSON events.sh wrote"
	seg_labels=''
	if [ -n "${seg_dispatch}" ]; then
		seg_slurp "${SEG_DISPATCH_TYPE}"
		seg_names=$(printf '%s\n' "${seg_slurped_events}" | jq -r --arg id "${seg_dispatch}" "${SEG_PLUGINS_JQ}") ||
			install_fault 'jq could not read the dispatch.made events events.sh slurp printed'
		seg_read_labels
	fi
	seg_title=$(jq -nr -L "${seg_title_dir}" --arg labels "${seg_labels}" --arg role "${SEG_ROLE_WORD}" "${SEG_TITLE_JQ}") ||
		install_fault 'jq failed building the title; expected jq 1.6+ and human-view'\''s title.jq'
}

# Sets seg_labels: the label of each plugin name of seg_names, one per line.
seg_read_labels() {
	[ -n "${seg_names}" ] || return 0
	seg_first=yes
	while IFS= read -r seg_name; do
		seg_label=$(seg_plugin_label "${seg_name}")
		if [ "${seg_first}" = yes ]; then
			seg_labels=${seg_label} seg_first=no
		else
			seg_labels="${seg_labels}${SEG_NEWLINE}${seg_label}"
		fi
	done <<EOF
${seg_names}
EOF
}

# Prints plugin $1's metadata.label, or $1 when it is not installed or has
# none; a name that is no skill name is never looked up as a path.
seg_plugin_label() {
	seg_found=''
	case $1 in
		'' | *[!a-z0-9-]* | -* | *-) ;;
		*)
			seg_skill_file="${seg_skills_dir}/$1/SKILL.md"
			[ ! -f "${seg_skill_file}" ] || seg_found=$(awk "${SEG_PLUGIN_LABEL_AWK}" "${seg_skill_file}" 2>/dev/null) || seg_found=''
			;;
	esac
	printf '%s' "${seg_found:-$1}" | tr '[:cntrl:]' ' '
}
