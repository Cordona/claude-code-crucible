#!/usr/bin/env sh
# Counts the tokens an effort's Claude Code sessions spent, from their
# transcripts, into one metrics.harvested event per session, written through
# the crucible skill's events.sh, and prints a view of them. The sessions are
# those the effort's events name as claude_session_id, this script's own
# events aside; nothing in the effort is written but through events.sh.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='metrics.sh'
readonly CRUCIBLE_SKILL='crucible'
readonly HARVESTED_TYPE='metrics.harvested'
readonly EVENTS_FORMAT=1
readonly VIEW_SKILL='human-view'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly VIEW_NAME='token-use'
# The exit when the events lock stayed held past events.sh's wait.
readonly LOCKED_EXIT=6
# Unknown arguments are echoed back only up to this length, so a long or
# hostile value never floods a diagnostic.
readonly MAX_SHOWN_CHARS=40
# Bounds stderr so a broken file stays readable; the rest is counted.
readonly MAX_PROBLEMS=20
# The first Claude Code version that marks a done subagent with finished:
# true in its meta file; an older subagent without it is not running.
readonly FINISHED_FLAG_VERSION='2.1.301'
# A cheap fixed-string pre-filter: only transcript lines holding one of these
# can carry an API call's usage, and with it a tool call's input, or the id
# of a subagent an Agent call launched.
readonly USAGE_MARK='"usage":{'
readonly AGENT_ID_MARK='"agentId":"'
# A launched subagent whose transcript is still missing this long after its
# launch was removed, not yet written.
readonly AGENT_FILE_GRACE_SECONDS=300
readonly SESSION_ID_ERE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

# Turns each pre-filtered transcript line into events, one compact JSON array
# per line: ["E", "this"|"other", time] when a tool call's input mentions an
# effort folder (the first one it names; $scan only), ["M", agent id,
# message id, model, input, output, cache read, cache write, unfinished,
# time, version] for an API call, ["T", tool use id] for an Agent call and
# ["L", agent id, time] for the subagent its result names as launched ($scan
# only). A tool result's text never moves the effort: only the commands the
# main thread runs do, except one that runs metrics.sh ($prog). With
# $tagged, each line leads with "<path>/agent-<id>.jsonl:", as grep -H prints
# it, and the agent id is taken from it; else the agent id is "", the main
# thread. A line that is not JSON, holds forkedFrom, or is a synthetic or
# API-error message gives none.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly LINE_EVENTS_JQ='def count: if type == "number" and . >= 0 then floor else 0 end;
# A call that runs this script only reads the figures of an effort, so the effort
# it names never becomes current.
def mention_text: [.message.content[]? | select(type == "object" and .type == "tool_use") | .input | tostring
	| select(contains($prog) | not)] | join("\n");
def first_mention:
	. as $text
	| [($text | match("/efforts/([0-9]{8}T[0-9]{6}-[0-9a-f]{4}-[a-z0-9]+(?:-[a-z0-9]+)*)"; "g")
		| {at: .offset, effort: (if .captures[0].string == $base then "this" else "other" end)}),
	   (if $base != "" then empty else ($text | indices($path)[], indices($real)[]) | {at: ., effort: "this"} end)]
	| min_by(.at) | .effort // empty;
(if $tagged then (capture("\\A(?<head>.*?/agent-(?<agent>[^/]*)\\.jsonl):") // empty) as $tag
	| {agent: $tag.agent, raw: .[($tag.head | length) + 1:]}
 else {agent: "", raw: .} end) as $line
| $line.agent as $agent
| $line.raw as $raw
| ($raw | fromjson? // empty)
| select(type == "object" and (has("forkedFrom") | not))
| ((.timestamp | strings) // "") as $time
| (if $scan and .type == "assistant" and ($raw | contains("/efforts/") or contains($path) or contains($real)) then (mention_text | first_mention) as $effort | ["E", $effort, $time] else empty end),
  (if .type == "assistant" and (.message | type) == "object" and (.message.usage | type) == "object"
	and (.message.id | type) == "string" and .message.model != "<synthetic>" and .isApiErrorMessage != true then
	.message as $message | $message.usage as $usage
	| ["M", $agent, $message.id, (($message.model | strings) // "unknown"), ($usage.input_tokens | count), ($usage.output_tokens | count),
		($usage.cache_read_input_tokens | count), ($usage.cache_creation_input_tokens | count),
		($message.stop_reason == null), $time, ((.version | strings) // "")]
   else empty end),
  (if $scan and .type == "assistant" then .message.content[]? | select(type == "object" and .type == "tool_use" and (.name == "Agent" or .name == "Task"))
	| ["T", (.id | strings)] else empty end),
  (if $scan and .type == "user" and (.toolUseResult | type) == "object" and (.toolUseResult.agentId | type) == "string" then
	["L", .toolUseResult.agentId, $time] else empty end)'

# Prints ["I", agent id, agent type, tool use id, parent agent id, finished]
# for each "<path>\t<line>" line of the agent-<id>.meta.json files; JSON
# escapes a tab inside a line, so the first tab ends the path. A line that is
# not a JSON object gives none, and a subagent without one stays unknown.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly AGENT_INFO_JQ='split("\t") as $parts
| select(($parts | length) > 1)
| ($parts[0] | sub("\\A.*/agent-"; "") | sub("[.]meta[.]json\\z"; "")) as $agent
| $parts[1:] | join("\t") | fromjson? // empty
| select(type == "object")
| ["I", $agent, ((.agentType | strings) // "unknown"), ((.toolUseId | strings) // ""),
	((.parentAgentId | strings) // ""), (.finished == true)]'

# Prints ["P", agent id] for each subagent transcript path, one per line, so
# a launched subagent whose file is gone can be told apart.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly AGENT_FILE_JQ='select(test("/agent-[^/]*[.]jsonl\\z")) | ["P", (sub("\\A.*/agent-"; "") | sub("[.]jsonl\\z"; ""))]'

# Prints ["F", agent id, time of its first line] for each "<path>\t<line>"
# line, the first line of each subagent transcript, split as AGENT_INFO_JQ.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly FIRST_LINE_JQ='split("\t") as $parts
| select(($parts | length) > 1)
| ($parts[0] | sub("\\A.*/agent-"; "") | sub("[.]jsonl\\z"; "")) as $agent
| ($parts[1:] | join("\t") | fromjson? // {}) as $first
| ["F", $agent, ((if ($first | type) == "object" then $first.timestamp else null end | strings) // "")]'

# Reads the events of every session in order (["S", session id] opens each,
# its main thread's events follow, then its subagents')
# and prints {<session id>: {main_thread, subagents, outside}}. The last line
# of a message id in a transcript counts; a message id already counted from
# another transcript is skipped. The main thread is this effort's from a
# mention of it until a mention of another effort, "outside" before any
# mention, and left out while in another effort; a mention is a tool call
# input naming an effort folder, <any>/efforts/<YYYYMMDDTHHMMSS>-<4 hex>-<name>.
# A subagent belongs where its parent does, else where its Agent call was,
# else where the main thread was at its first line.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly AGGREGATE_JQ='include "metrics-validator";
def version_number: split(".") | map(tonumber? // 0);
def safe_name: if metrics_is_name then . else "unknown" end;
def new_agent($session): {session: $session, name: "unknown", tool: "", parent: "", finished: false, time: "", version: [0]};
# The 8-hop bound is a loop guard, not a measured nesting depth: it ends a
# parent cycle in damaged meta files, and a chain past it falls back to the
# Agent call or the first line.
def agent_owner($state; $key; $hops):
	$state.agents[$key] as $agent
	| "\($agent.session)/\($agent.parent)" as $parent_key
	| if $agent.parent != "" and $hops < 8 and $state.agents[$parent_key] != null then agent_owner($state; $parent_key; $hops + 1)
	  elif $agent.tool != "" and ($state.sessions[$agent.session].tools | has($agent.tool)) then $state.sessions[$agent.session].tools[$agent.tool]
	  else ([$state.sessions[$agent.session].switches[] | select($agent.time != "" and .[0] <= $agent.time)] | last | .[1]?) // "outside" end;
# A launch time Claude Code wrote, ISO 8601 UTC with or without fractions,
# at least the grace period ago; an unreadable time counts as old.
def launched_before_grace($time):
	(try ($time | sub("[.][0-9]+Z\\z"; "Z") | fromdateiso8601) catch 0) as $launched
	| $launched + ($grace_seconds | tonumber) <= now;
def kind_sums: reduce .[] as $message ([0, 0, 0, 0]; [range(0; 4) as $i | .[$i] + $message.kinds[$i]]);
def kind_fields: {input: .[0], output: .[1], cache_read: .[2], cache_write: .[3]};
def unreliable_flag: if any(.[]; .unfinished) then {unreliable: true} else {} end;
def model_entries:
	group_by(.model) | map({model: .[0].model} + unreliable_flag + (kind_sums | kind_fields));
def agent_entries($running):
	group_by([.name, .model])
	| map({agent: .[0].name, model: .[0].model}
		+ (if any(.[]; $running[.context]) then {running: true} else {} end)
		+ unreliable_flag + (kind_sums | kind_fields));
($finished_since | version_number) as $finished_number
| reduce inputs as $event ({session: "", current: "outside", sessions: {}, agents: {}, messages: {}};
	if $event[0] == "S" then .session = $event[1] | .current = "outside" | .sessions[$event[1]] = {switches: [], tools: {}, launched: {}, files: {}}
	elif $event[0] == "E" then .current = $event[1] | .sessions[.session].switches += [[$event[2], $event[1]]]
	elif $event[0] == "T" then .sessions[.session].tools[$event[1]] = .current
	elif $event[0] == "L" then .sessions[.session].launched[$event[1]] = $event[2]
	elif $event[0] == "P" then .sessions[.session].files[$event[1]] = true
	elif $event[0] == "I" then "\(.session)/\($event[1])" as $key
		| .agents[$key] = (new_agent(.session) + (.agents[$key] // {}) + {name: $event[2], tool: $event[3], parent: $event[4], finished: $event[5]})
	elif $event[0] == "F" then "\(.session)/\($event[1])" as $key
		| .agents[$key] = (new_agent(.session) + (.agents[$key] // {}) + {time: $event[2]})
	elif $event[0] == "M" then "\(.session)/\($event[1])" as $context
		| if .messages[$event[2]] != null and .messages[$event[2]].context != $context then .
		  else .messages[$event[2]] = {context: $context, session: .session, agent: $event[1],
				owner: (if $event[1] == "" then .current else "agent" end),
				model: $event[3], kinds: $event[4:8], unfinished: $event[8]}
			| if $event[1] == "" then .
			  else .agents[$context] = (new_agent(.session) + (.agents[$context] // {}))
				| .agents[$context].version = ([.agents[$context].version, ($event[10] | version_number)] | max) end
		  end
	else . end)
| . as $state
| (reduce ($state.agents | keys[]) as $key ({}; .[$key] = agent_owner($state; $key; 0))) as $owners
| ($state.agents | map_values(.finished != true and .version >= $finished_number)) as $running
| [$state.messages[] | .owner = (if .owner == "agent" then $owners[.context] else .owner end) | select(.owner != "other")
	| .model |= safe_name | .name = (if .agent == "" then "" else $state.agents[.context].name | safe_name end)] as $counted
| reduce ($state.sessions | keys[]) as $session ({};
	[$counted[] | select(.session == $session)] as $mine
	| .[$session] = {
		main_thread: [$mine[] | select(.agent == "" and .owner == "this")] | model_entries,
		subagents: [$mine[] | select(.agent != "" and .owner == "this")] | agent_entries($running),
		outside: [$mine[] | select(.owner == "outside")] | model_entries}
	| $state.sessions[$session] as $read
	| if any($read.launched | to_entries[]; .key as $id | ($read.files | has($id) | not) and launched_before_grace(.value))
	  then .[$session].partly_expired = true else . end)'

# Prints the view's data from the $count session figures passed as
# $ARGS.named pairs p<n> (the metrics.harvested event's path) and f<n> (its
# body's text), and the ids of sessions expired before any harvest in $missing.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_DATA_JQ='$ARGS.named as $named
| {name: $name, harvested_at: $at,
   expired_unseen: ($missing | split(" ") | map(select(. != ""))),
   figures: [range(0; $count) | {path: $named["p\(.)"], body: ($named["f\(.)"] | fromjson)}]}'

usage() {
	print_block <<'EOF'
usage: metrics.sh harvest --effort FOLDER
       metrics.sh show --effort FOLDER
       metrics.sh --help | -h
EOF
}

help_text() {
	usage
	print_block <<'EOF'

Counts the tokens of every Claude Code session an effort names (each
distinct claude_session_id in FOLDER/events/, metrics.sh's own events
aside) from the session transcripts, and appends one metrics.harvested
event per session through the crucible skill's events.sh, also after
the effort ended. Its body, shape metrics-validator.jq, holds the counted
session's claude_session_id; the newest per session is its figure.
Not counted: compaction, title generation, prompt suggestions and /btw.

  harvest          append the session figures
  show             harvest, then print the view from the newest figures,
                   through the human-view skill's show.sh view, recorded
                   as owed this session
  --effort FOLDER  an effort folder of the space, absolute
  CRUCIBLE_HOME    the space; default $HOME/.crucible
  CLAUDE_CONFIG_DIR  holds projects/, the transcripts, and skills/;
                   default $HOME/.claude
  CLAUDE_CODE_SESSION_ID  show: the session the view is recorded in;
                   unset: the view is printed, nothing is recorded

stdout on exit 0: harvest nothing; show the view, from views/token-use.jq.
stderr: "metrics.sh:" lines to show the human.

A session whose transcript is gone keeps its newest figures, marked
expired: true, appended again only when not marked yet. A body
metrics-validator.jq rejects becomes one fault.raised event, {what: its
problem lines}. Two harvests at once are harmless: the newest wins.
Transcripts are never written; temp files go in mktemp's default place.
Each harvest adds to FOLDER/events/, so Crucible's prune age check sees
the effort as recently active.

Exit codes:
  0  done; go on
  2  refused call; nothing written; show the human stderr, and stop
  4  the effort or a file it reads is unusable, or the effort has no
     format 1 events/000001-effort.opened.json; or show's reader was
     gone before the view was written; show the human stderr and the
     exit code, and stop
  5  install fault; show the human stderr, and stop
  6  the events lock stayed held; a figure is not written; rerun once,
     else show the human stderr, and stop
  129, 130, 143  stopped by a signal; tell the human it was stopped, show
                 the exit code, and stop

Dependencies:
  POSIX sh; awk, date, find, grep, sed, sort, mktemp, rm; jq 1.6+
    (macOS: brew install jq; Linux: the distro's jq package)
  metrics-validator.jq beside this script
  the crucible skill's events.sh and lib/crucible-space.sh
  show only: the human-view skill's scripts/show.sh and
    scripts/lib/render.sh, in CLAUDE_CONFIG_DIR's skills/;
    views/token-use.jq in this skill
EOF
}

# Copies stdin to stdout with the shell alone, so --help needs no tool.
print_block() {
	while IFS= read -r line; do
		printf '%s\n' "${line}"
	done
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	usage >&2
	exit 2
}

bad_value() {
	warn "$1"
	exit 2
}

folder_fault() {
	warn "$1"
	exit 4
}

install_fault() {
	warn "install: $1"
	exit 5
}

main() {
	[ "$#" -gt 0 ] || usage_error 'a command is missing; expected harvest, show or --help'
	command=$1
	shift
	case ${command} in
		--help | -h)
			[ "$#" -eq 0 ] || usage_error "${command} takes no arguments; expected ${command} alone"
			help_text
			exit 0
			;;
		harvest | show) ;;
		*)
			show_safely "${command}"
			usage_error "unknown command: ${shown}; expected harvest, show or --help"
			;;
	esac
	check_tools
	load_dependencies
	parse_effort_option "$@"
	resolve_projects
	[ "${command}" = harvest ] || load_view_helpers
	check_space_effort
	harvest
	[ "${command}" = harvest ] || show_view
}

# Sets shown to a value fit to echo in a diagnostic: the value itself when it
# is short and plain, else a description, so no control character reaches a log.
show_safely() {
	case $1 in
		'') shown="''" ;;
		*[![:alnum:]._=-]*) shown='(a value with other characters)' ;;
		*)
			if [ "${#1}" -le "${MAX_SHOWN_CHARS}" ]; then
				shown="'$1'"
			else
				shown="(a value of ${#1} characters)"
			fi
			;;
	esac
}

check_tools() {
	for tool in awk date find grep sed sort mktemp rm; do
		command -v "${tool}" >/dev/null 2>&1 ||
			install_fault "${tool} missing; expected it on PATH; try installing the base-system tools (coreutils on Linux)"
	done
	command -v jq >/dev/null 2>&1 ||
		install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || install_fault 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) install_fault "jq is ${jq_version}; expected jq 1.6+; try upgrading jq" ;;
	esac
}

# Sources the crucible skill's space rules and sets own_dir, the folder of
# this script and its validator, and events_script, or exits 5.
load_dependencies() {
	case $0 in
		*/*) own_dir=${0%/*} ;;
		*) own_dir=. ;;
	esac
	require_file "${own_dir}/metrics-validator.jq" 'session figures shape' 'try reinstalling procedure-metrics'
	crucible_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts"
	space_lib="${crucible_dir}/lib/crucible-space.sh"
	events_script="${crucible_dir}/events.sh"
	require_file "${space_lib}" 'space rules' "try installing the ${CRUCIBLE_SKILL} skill"
	require_file "${events_script}" 'events.sh' "try installing the ${CRUCIBLE_SKILL} skill"
	# shellcheck source=../../../../engine/crucible/scripts/lib/crucible-space.sh
	. "${space_lib}"
}

# Exits 5 unless file $1, named $2, is readable; $3 is the fix.
require_file() {
	[ -f "$1" ] && [ -r "$1" ] || install_fault "$2 missing; expected $1; $3"
}

# Sets effort (no trailing slash), effort_real (its physical path),
# effort_base and effort_name from the one --effort FOLDER option, and
# effort_id_name to the folder's name when it is shaped like an effort's.
parse_effort_option() {
	effort='' effort_given=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--effort)
				[ "${effort_given}" = false ] || usage_error "--effort given twice; expected it once; try ${command} --effort FOLDER"
				[ "$#" -ge 2 ] || usage_error "--effort needs a value; expected ${command} --effort FOLDER"
				effort=$2 effort_given=true
				shift 2
				;;
			*)
				show_safely "$1"
				usage_error "unknown argument for ${command}: ${shown}; expected --effort FOLDER"
				;;
		esac
	done
	[ "${effort_given}" = true ] || usage_error "--effort missing; expected ${command} --effort FOLDER"
	case ${effort} in
		*[[:cntrl:]]*) bad_value '--effort holds a control character; expected the effort folder effort.sh printed' ;;
		/*) ;;
		*) bad_value '--effort is not absolute; expected the effort folder effort.sh printed, starting with /' ;;
	esac
	while :; do
		case ${effort} in
			?*/) effort=${effort%/} ;;
			*) break ;;
		esac
	done
	[ -d "${effort}" ] || bad_value "--effort ${effort} is not a folder; expected an existing effort folder; try effort.sh path NAME"
	[ ! -L "${effort}" ] || bad_value "--effort ${effort} is a symbolic link; expected the effort folder itself"
	effort_real=$(cd -P -- "${effort}" && pwd -P) ||
		folder_fault "cannot enter ${effort}; expected a readable effort folder; try checking its permissions"
	effort_base=${effort##*/}
	effort_parent=${effort%/*}
	effort_id_name=''
	effort_name=${effort_base}
	case ${effort_parent##*/}/${effort_base} in
		efforts/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]-?*)
			case ${effort_base#*-*-} in
				*[!abcdefghijklmnopqrstuvwxyz0123456789-]* | -* | *- | *--*) ;;
				*)
					effort_id_name=${effort_base}
					effort_name=${effort_base#*-*-}
					;;
			esac
			;;
		*) ;;
	esac
}

# Sets projects_dir, where Claude Code keeps the session transcripts.
resolve_projects() {
	config_dir=${CLAUDE_CONFIG_DIR:-}
	if [ -z "${config_dir}" ]; then
		[ -n "${HOME:-}" ] || bad_value 'HOME and CLAUDE_CONFIG_DIR are unset; expected one to find the transcripts'
		config_dir="${HOME}/.claude"
	fi
	projects_dir="${config_dir}/projects"
}

# Sets views_dir and show_script and sources human-view's card printer lib,
# or exits 5.
load_view_helpers() {
	views_dir="${own_dir}/../views"
	view_skill_dir="${config_dir}/skills/${VIEW_SKILL}"
	render_lib="${view_skill_dir}/${RENDER_LIB}"
	require_file "${render_lib}" 'card printer lib' "try installing the ${VIEW_SKILL} skill"
	# shellcheck source=../../../../engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${view_skill_dir}/scripts" "${views_dir}" "${VIEW_NAME}" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
}

# Exits unless effort is an effort folder of the space whose first event is
# a known format's effort.opened, so an older or newer effort is never
# misread; sets events_dir.
check_space_effort() {
	# shellcheck disable=SC2310 # its status says whether the root is usable; the fault is read below
	if ! crucible_resolve_root; then
		[ "${crucible_root_fault}" != usage ] || usage_error "${crucible_root_problem}"
		folder_fault "${crucible_root_problem}"
	fi
	# shellcheck disable=SC2310 # its status says whether the folder passed; the fault is read below
	if ! crucible_check_effort_folder "${effort}"; then
		[ "${crucible_effort_fault}" = space ] || bad_value "${crucible_effort_refusal}"
		folder_fault "${crucible_effort_refusal}"
	fi
	events_dir="${effort}/events"
	jq -e --argjson format "${EVENTS_FORMAT}" '.type == "effort.opened" and .body.format == $format' \
		"${events_dir}/000001-effort.opened.json" >/dev/null 2>&1 </dev/null ||
		folder_fault "${effort} has no format ${EVENTS_FORMAT} events/000001-effort.opened.json; expected an effort this version of Crucible started; an older or newer effort cannot be counted"
}

harvest() {
	harvested_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || install_fault 'date failed; expected the UTC time; try date -u'
	collect_sessions
	new_temp_file
	events_file=${made}
	new_temp_file
	results_file=${made}
	new_temp_file
	status_file=${made}
	read_newest_figures
	expired_unseen=''
	present_sessions=''
	expired_sessions=''
	while IFS= read -r session; do
		[ -n "${session}" ] || continue
		find_transcript "${session}"
		if [ -z "${transcript}" ]; then
			expired_sessions="${expired_sessions}${session}
"
			continue
		fi
		present_sessions="${present_sessions}${session}
"
		session_events "${session}"
	done <<EOF
${sessions}
EOF
	jq -n -c -L "${own_dir}" --arg finished_since "${FINISHED_FLAG_VERSION}" --arg grace_seconds "${AGENT_FILE_GRACE_SECONDS}" \
		"${AGGREGATE_JQ}" "${events_file}" >"${results_file}" ||
		install_fault 'jq failed counting the transcripts; expected jq 1.6+ and metrics-validator.jq; try jq --version'
	write_present_sessions
	mark_expired_sessions
}

# Sets sessions to every distinct claude_session_id value in the effort's
# events and faults, one per line, sorted. This script's own events name the
# session that ran it, which did not work in the effort for that, so they
# are left out.
collect_sessions() {
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	found=$(LC_ALL=C find "${events_dir}" -type f -name '*.json' ! -name '.*' -exec jq -r --arg prog "${PROG}" \
		'select(.by != $prog) | .. | objects | .claude_session_id? | strings' {} + </dev/null) ||
		folder_fault "cannot read the events of ${effort}; expected readable JSON files in ${events_dir}; try checking their permissions"
	sessions=$(printf '%s\n' "${found}" | LC_ALL=C sed -n -E "/^${SESSION_ID_ERE}\$/p" | LC_ALL=C sort -u) ||
		install_fault 'sed or sort failed on the session ids; expected POSIX tools; try a POSIX sed and sort on PATH'
}

# Sets newest_file to a temp file of {<session id>: {path, body}}, each
# session's newest metrics.harvested event, as events.sh lists them now.
read_newest_figures() {
	harvested_list=$(sh "${events_script}" list --effort "${effort}" --type "${HARVESTED_TYPE}" </dev/null) ||
		folder_fault "events.sh could not list the ${HARVESTED_TYPE} events of ${effort} (its stderr is above); expected readable events"
	set --
	while IFS= read -r listed; do
		[ -z "${listed}" ] || set -- "$@" "${listed}"
	done <<EOF
${harvested_list}
EOF
	new_temp_file
	newest_file=${made}
	jq -n 'reduce inputs as $event ({};
		if ($event.body | type) == "object" and ($event.body.claude_session_id | type) == "string"
		then .[$event.body.claude_session_id] = {path: input_filename, body: $event.body} else . end)' \
		"$@" </dev/null >"${newest_file}" ||
		folder_fault "cannot read the ${HARVESTED_TYPE} events of ${effort}; expected JSON files events.sh wrote"
}

# Sets made to a new empty temp file and adds it to the temp files clean_up
# removes.
new_temp_file() {
	made=$(mktemp) || install_fault 'mktemp failed; expected a temp file in its default place; try checking TMPDIR'
	temp_files="${temp_files}${made}
"
}

# Sets transcript to session $1's main transcript, empty when none is left.
find_transcript() {
	transcript=''
	for candidate in "${projects_dir}"/*/"$1.jsonl"; do
		[ -f "${candidate}" ] && [ ! -L "${candidate}" ] || continue
		transcript=${candidate}
		return 0
	done
}

# Appends session $1's events to events_file: its main transcript's, then
# its subagents' meta files, first lines and API calls, each read in one
# batch however many subagents there are.
session_events() {
	printf '["S","%s"]\n' "$1" >>"${events_file}" ||
		install_fault "cannot write ${events_file}; expected free space in its folder"
	produce grep_lines -e "${USAGE_MARK}" -e "${AGENT_ID_MARK}" -- "${transcript}" | line_events false true
	check_produced "${transcript}"
	subagents_dir="${transcript%.jsonl}/subagents"
	[ -d "${subagents_dir}" ] && [ ! -L "${subagents_dir}" ] || return 0
	produce find "${subagents_dir}" -type f -name 'agent-*.jsonl' | tagged_events "${AGENT_FILE_JQ}"
	check_produced "${subagents_dir}"
	# shellcheck disable=SC2016 # awk's program: its $0 is awk's
	produce find "${subagents_dir}" -type f -name 'agent-*.meta.json' \
		-exec awk '{ printf "%s\t%s\n", FILENAME, $0 }' {} + |
		tagged_events "${AGENT_INFO_JQ}"
	check_produced "${subagents_dir}"
	# shellcheck disable=SC2016 # awk's program: its $0 is awk's
	produce find "${subagents_dir}" -type f -name 'agent-*.jsonl' \
		-exec awk 'FNR == 1 { printf "%s\t%s\n", FILENAME, $0; nextfile }' {} + |
		tagged_events "${FIRST_LINE_JQ}"
	check_produced "${subagents_dir}"
	# shellcheck disable=SC2016 # the inline script's $0 and $@ are its own arguments
	produce find "${subagents_dir}" -type f -name 'agent-*.jsonl' \
		-exec sh -c 'LC_ALL=C grep -F -H -e "$0" -- "$@" || [ "$?" -eq 1 ]' "${USAGE_MARK}" {} + |
		line_events true false
	check_produced "${subagents_dir}"
}

# Runs the command given, recording its exit status in status_file when it
# fails, since a pipeline's status is only its last command's.
produce() {
	"$@" || printf '%s\n' "$?" >"${status_file}"
}

# Exits 4 when the command produce ran last failed; $1 names what it read.
check_produced() {
	produced_status=''
	IFS= read -r produced_status <"${status_file}" 2>/dev/null || true
	[ -z "${produced_status}" ] ||
		folder_fault "cannot read $1; expected readable transcripts; try checking their permissions"
}

# grep -F that takes no match as success: a transcript may hold none.
grep_lines() {
	LC_ALL=C grep -F "$@" || [ "$?" -eq 1 ]
}

# Appends the events jq program $1 makes of the "<path>\t<line>" lines on
# stdin, which awk prints per file, so a file without a final newline stays
# apart from the next.
tagged_events() {
	jq -R -c "$1" >>"${events_file}" ||
		install_fault 'jq failed reading the subagent files; expected jq 1.6+; try jq --version'
}

# Appends the events of the transcript lines on stdin; $1 true when each
# leads with its file name (grep -H), $2 true to also scan for effort
# mentions and Agent calls. jq reads them a line at a time.
line_events() {
	jq -R -c --argjson tagged "$1" --argjson scan "$2" --arg prog "${PROG}" --arg base "${effort_id_name}" --arg path "${effort}" \
		--arg real "${effort_real}" "${LINE_EVENTS_JQ}" >>"${events_file}" ||
		install_fault 'jq failed reading a transcript; expected jq 1.6+; try jq --version'
}

# Appends the figures of each session with a transcript from results_file. A
# session that launched a subagent whose transcript is gone is partly
# expired: its newest figures are kept, marked expired, since a new count
# would be lower; with none yet, the partial figures are appended, marked
# expired.
write_present_sessions() {
	while IFS= read -r session; do
		[ -n "${session}" ] || continue
		partly_expired=$(jq -r --arg session "${session}" '.[$session].partly_expired // false' "${results_file}") ||
			install_fault 'jq failed reading the counts; expected jq 1.6+; try jq --version'
		# shellcheck disable=SC2310 # its status says whether figures were there to keep
		if [ "${partly_expired}" = true ] && keep_expired_figures "${session}"; then
			continue
		fi
		new_temp_file
		body_file=${made}
		jq --arg session "${session}" --arg at "${harvested_at}" \
			'{claude_session_id: $session, harvested_at: $at}
			+ (.[$session] // {main_thread: [], subagents: [], outside: []} | del(.partly_expired))
			+ (if .[$session].partly_expired then {expired: true} else {} end)' \
			"${results_file}" >"${body_file}" ||
			install_fault "cannot write the temp file ${body_file}; expected free space in its folder"
		record_figures "${session}" install "the ${HARVESTED_TYPE} body built for session ${session}"
	done <<EOF
${present_sessions}
EOF
}

# Keeps the newest figures of each session whose transcript is gone and
# marks them expired; a session with none yet is only listed by the view.
mark_expired_sessions() {
	while IFS= read -r session; do
		[ -n "${session}" ] || continue
		# shellcheck disable=SC2310 # its status says whether figures were there to keep
		keep_expired_figures "${session}" || expired_unseen="${expired_unseen} ${session}"
	done <<EOF
${expired_sessions}
EOF
}

# Marks session $1's newest figures expired and appends them again, unless
# they are marked already; fails when the session has none.
keep_expired_figures() {
	newest_figures "$1"
	[ -n "${newest_path}" ] || return 1
	marked=$(jq -r '.expired == true' "${body_file}" </dev/null) ||
		install_fault 'jq failed on a figures body; expected jq 1.6+; try jq --version'
	[ "${marked}" != true ] || return 0
	new_temp_file
	jq '.expired = true' "${body_file}" </dev/null >"${made}" ||
		install_fault "cannot write the temp file ${made}; expected free space in its folder"
	body_file=${made}
	record_figures "$1" kept "${newest_path}"
}

# Sets newest_path to session $1's newest metrics.harvested event, empty when
# it has none, and body_file to a temp file of its body.
newest_figures() {
	newest_path=$(jq -r --arg session "$1" '.[$session].path // empty' "${newest_file}" </dev/null) ||
		install_fault 'jq failed reading the newest figures; expected jq 1.6+; try jq --version'
	[ -n "${newest_path}" ] || return 0
	new_temp_file
	body_file=${made}
	jq --arg session "$1" '.[$session].body' "${newest_file}" </dev/null >"${body_file}" ||
		install_fault "cannot write the temp file ${body_file}; expected free space in its folder"
}

# Appends body_file as session $1's metrics.harvested event once it passes the
# validator; $3 names it in a rejection. $2 says what the body is: install
# (built here) must meet every rule, and a problem exits 5; kept (read back
# and marked expired) must keep its shape, and a problem appends nothing.
record_figures() {
	case $2 in
		install) check='metrics_session_problems' ;;
		*) check='metrics_session_shape_problems' ;;
	esac
	problems=$(jq -r -L "${own_dir}" "include \"metrics-validator\"; ${check}" "${body_file}" </dev/null) ||
		install_fault 'jq failed on a figures body; expected jq 1.6+ and metrics-validator.jq; try jq --version'
	if [ -n "${problems}" ]; then
		report_problems "$3" "${problems}"
		[ "$2" = kept ] || install_fault "a ${HARVESTED_TYPE} body built breaks metrics-validator.jq; expected matching metrics.sh and validator; try reinstalling procedure-metrics"
		warn "session $1's figures are left as they are"
		return 0
	fi
	append_figures "$1"
}

# Appends body_file as a metrics.harvested event of counted session $1.
append_figures() {
	if sh "${events_script}" append --effort "${effort}" --type "${HARVESTED_TYPE}" --by "${PROG}" \
		--body-file "${body_file}" --session "$1" </dev/null >/dev/null; then
		return 0
	else
		append_status=$?
	fi
	case ${append_status} in
		6) exit "${LOCKED_EXIT}" ;;
		3 | 4) folder_fault "events.sh could not write session $1's figures (its stderr is above); expected a writable ${events_dir}" ;;
		*) install_fault "events.sh exited ${append_status} (its stderr is above); expected exit 0; try reinstalling the ${CRUCIBLE_SKILL} skill" ;;
	esac
}

# Warns the problems $2 of what $1 names, one line each, at most
# MAX_PROBLEMS, and records them as one fault.raised event.
report_problems() {
	reported=0 rejection=''
	while IFS= read -r problem; do
		reported=$((reported + 1))
		[ "${reported}" -le "${MAX_PROBLEMS}" ] || continue
		warn "$1: ${problem}"
		rejection="${rejection}${rejection:+
}$1: ${problem}"
	done <<EOF
$2
EOF
	if [ "${reported}" -gt "${MAX_PROBLEMS}" ]; then
		warn "$1: ${reported} problems, showing ${MAX_PROBLEMS}"
		rejection="${rejection}
$1: ${reported} problems, showing ${MAX_PROBLEMS}"
	fi
	raise_fault "${rejection}"
}

# Records rejection text $1 as a fault.raised event {what: $1}; a fault that
# cannot be written is warned, since the rejection itself is warned already.
raise_fault() {
	new_temp_file
	fault_body=${made}
	jq -n --arg what "$1" '{what: $what}' </dev/null >"${fault_body}" ||
		install_fault "cannot write the temp file ${fault_body}; expected free space in its folder"
	sh "${events_script}" fault --effort "${effort}" --by "${PROG}" --body-file "${fault_body}" </dev/null >/dev/null ||
		warn "events.sh could not record the rejection as a fault (its stderr is above)"
}

# Prints the view from each session's newest figures whose shape passes the
# validator, as events.sh lists them after this harvest, through show.sh
# view, recorded as owed for the effort.
show_view() {
	read_newest_figures
	file_count=0
	set --
	while IFS= read -r session; do
		[ -n "${session}" ] || continue
		newest_figures "${session}"
		[ -n "${newest_path}" ] || continue
		problems=$(jq -r -L "${own_dir}" 'include "metrics-validator"; metrics_session_shape_problems' "${body_file}" </dev/null 2>/dev/null) ||
			problems='is not JSON; expected the body metrics.sh writes'
		if [ -n "${problems}" ]; then
			report_problems "${newest_path}" "${problems}"
			warn "${newest_path} is left out of the view"
			continue
		fi
		set -- "$@" --arg "p${file_count}" "${newest_path}" --rawfile "f${file_count}" "${body_file}"
		file_count=$((file_count + 1))
	done <<EOF
${sessions}
EOF
	view_data=$(jq -n -c --argjson count "${file_count}" --arg missing "${expired_unseen}" --arg name "${effort_name}" \
		--arg at "${harvested_at}" "$@" "${VIEW_DATA_JQ}" </dev/null) ||
		install_fault 'jq failed building the view data; expected jq 1.6+; try jq --version'
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${show_script}" "${views_dir}" "${VIEW_NAME}" "${effort}" "${view_data}" && return 0
	install_fault "${hv_render_problem}; expected the view shown from views/${VIEW_NAME}.jq; try reinstalling procedure-metrics and the ${VIEW_SKILL} skill"
}

# Removes this run's temp files.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	while IFS= read -r leftover; do
		[ -z "${leftover}" ] || rm -f "${leftover}"
	done <<EOF
${temp_files}
EOF
}

temp_files=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
