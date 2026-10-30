#!/usr/bin/env sh
# Counts the tokens an effort's Claude Code sessions spent, from their
# transcripts, into one file per session in the effort's metrics/ folder, and
# prints a view of them. An effort is a folder whose JSON files may name the
# sessions that worked in it as claude_session_id; metrics/ is this script's
# own, and nothing else in the folder is written.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='metrics.sh'
readonly METRICS_FOLDER='metrics'
readonly REJECTIONS_LOG='.rejections.log'
readonly VIEW_SKILL='human-view'
# The exit when another harvest of the same effort holds the lock.
readonly LOCKED_EXIT=6
# A live lock is waited on this many times one second before giving up; a
# harvest of a normal effort ends well within it.
readonly LOCK_WAIT_SECONDS=5
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

# Prints the view from the $count session files passed as $ARGS.named pairs
# p<n> (the path) and f<n> (its text), and the ids of sessions expired before
# any harvest in $missing.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_JQ='include "view";
def tenths($unit): (. / $unit * 10 + 0.5 | floor) as $tenths | "\($tenths / 10 | floor).\($tenths % 10)";
def millions: if . >= 999950000 then "\(tenths(1000000000))B" else "\(tenths(1000000))M" end;
def thousands: if . >= 999950 then millions else "\(tenths(1000))k" end;
def rounded: if . >= 999500 then millions elif . >= 1000 then "\(. / 1000 + 0.5 | floor)k" else thousands end;
def sums: reduce .[] as $entry ({input: 0, output: 0, cache_read: 0, cache_write: 0};
	.input += $entry.input | .output += $entry.output | .cache_read += $entry.cache_read | .cache_write += $entry.cache_write);
def cells: "\(.input | thousands) | \(.output | thousands) | \(.cache_read | rounded) | \(.cache_write | rounded)";
def bold_cells: "**\(.input | thousands)** | **\(.output | thousands)** | **\(.cache_read | rounded)** | **\(.cache_write | rounded)**";
def marks: (if .running then " (running)" else "" end) + (if .unreliable then " (unreliable)" else "" end);
def harvest_time: "\(.[0:10]) \(.[11:16]) UTC";
# A file read back is checked for shape only, so an agent name in it may
# predate the name rule; no character of it may break the table.
def cell_text: gsub("[[:cntrl:]|`]"; "?");
# The rows of a session with a figure above zero; the first names the session.
def session_rows:
	. as $file
	| [{who: "main thread", unreliable: any($file.main_thread[]; .unreliable), sum: ($file.main_thread | sums)}]
	+ [$file.subagents | group_by(.agent)[]
		| {who: (.[0].agent | cell_text), running: any(.[]; .running), unreliable: any(.[]; .unreliable), sum: sums}]
	| map(select(.sum | [.input, .output, .cache_read, .cache_write] | any(. > 0)))
	| to_entries
	| map((if .key == 0 then "| `\($file.claude_session_id[0:8])`\(if $file.expired then " (expired)" else "" end) |" else "| |" end) as $session
		| .value | "\($session) \(.who)\(marks) | \(.sum | cells) |");
def table($rows; $mine):
	if ($rows | length) == 0 then "No session figures for this effort yet."
	else ["| Session | Who | Fresh input | Output | Cached reads | Cache writes |",
		"|---|---|---:|---:|---:|---:|"]
		+ $rows
		+ ["| **Total** | | \($mine | sums | bold_cells) |"]
		| join("\n")
	end;
$ARGS.named as $named
| [range(0; $count) | {path: $named["p\(.)"], file: ($named["f\(.)"] | fromjson)}] | sort_by(.file.claude_session_id) as $read
| [$read[].file] as $files
| ($missing | split(" ") | map(select(. != ""))) as $expired_unseen
| [$files[] | .main_thread[], .subagents[]] as $mine
| [$files[] | .outside[]] as $outside
| [$files[] | session_rows[]] as $rows
# Effort names are at most 40 characters and a whole effort folder name 61,
# so 80 passes every folder effort.sh makes and keeps the first line short.
| (if $name | test("\\A[A-Za-z0-9._-]{1,80}\\z") then $name else "effort" end) as $shown_name
| [status_line("done"; "Token use · `\($shown_name)`"),
   table($rows; $mine),
   section("Note"; "Notes"; [
	"Harvested \($at | harvest_time).",
	(if ($outside | length) > 0 then ($outside | sums) as $sum
		| "Outside this effort, same sessions\(if any($outside[]; .unreliable) then " (unreliable)" else "" end): \($sum.input | thousands) input, \($sum.output | thousands) output, \($sum.cache_read | rounded) cached reads, \($sum.cache_write | rounded) cache writes.",
		  "Split by effort from the tool calls that name its folder; calls before the first one count as outside." else empty end),
	(if any($mine[]; .running) then "(running): still running at harvest; the next ask completes it." else empty end),
	(if any($mine[], $outside[]; .unreliable) then "(unreliable): some output figures are placeholders Claude Code left unfinished; output counts low there." else empty end),
	($files[] | select(.expired) | "`\(.claude_session_id[0:8])` (expired): transcript gone; figures from its harvest of \(.harvested_at | harvest_time)."),
	(if ($expired_unseen | length) > 0 then "Expired before any harvest, no figures: \($expired_unseen | map("`\(.[0:8])`") | join(", "))." else empty end)
	] | map(plain_line)),
   data_section([$read[] | ["Metrics", .path]])]
| blocks'

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

Counts the tokens of every Claude Code session an effort folder names (each
distinct claude_session_id in its JSON files, metrics/ aside) from the
session transcripts, and writes one file per session:
FOLDER/metrics/<claude_session_id>.json, shape: metrics-validator.jq.
Not counted: compaction, title generation, prompt suggestions and /btw.

  harvest          rewrite the session files
  show             harvest, then print the view
  --effort FOLDER  the effort folder, absolute
  CLAUDE_CONFIG_DIR  holds projects/, the transcripts, and skills/;
                   default $HOME/.claude

stdout on exit 0: harvest nothing; show the view, Markdown, to relay.
stderr: "metrics.sh:" lines to show the human.

Session files are replaced atomically, mode 600, by one harvest of an
effort at a time; each problem of a file metrics-validator.jq rejects is
also appended to FOLDER/metrics/.rejections.log. Transcripts and
everything outside FOLDER/metrics/ are never written. Nothing else is left
behind (a SIGKILL aside).
A harvest rewrites FOLDER/metrics/, so Crucible's prune age check sees
the effort as recently active.

Exit codes:
  0  done; harvest: go on; show: relay stdout as printed
  2  refused call; nothing written; show the human stderr, and stop
  4  a file it reads or writes is unusable; show the human stderr, and stop
  5  install fault; show the human stderr, and stop
  6  another harvest of this effort is running; no session file written;
     rerun once, else show the human stderr, and stop
  129, 130, 143  stopped by a signal; show the human stderr, and stop

Dependencies:
  POSIX sh; awk, date, find, grep, sed, sort, mkdir, chmod, rmdir, mktemp,
    mv, rm, sleep (macOS and Linux base); jq 1.6+ (macOS: brew
    install jq; Linux: the distro's jq package)
  metrics-validator.jq beside this script
  show only: the human-view skill's view.jq, in CLAUDE_CONFIG_DIR's skills/
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
	open_metrics_folder
	take_lock
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
	for tool in awk date find grep sed sort mkdir chmod rmdir mktemp mv rm sleep; do
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

# Sets own_dir, the folder of this script and its validator, or exits 5.
load_dependencies() {
	case $0 in
		*/*) own_dir=${0%/*} ;;
		*) own_dir=. ;;
	esac
	[ -f "${own_dir}/metrics-validator.jq" ] && [ -r "${own_dir}/metrics-validator.jq" ] ||
		install_fault "session file shape missing; expected ${own_dir}/metrics-validator.jq; try reinstalling procedure-metrics"
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

# Sets view_dir, the human-view skill's folder the view is built with, or exits 5.
load_view_helpers() {
	view_dir="${config_dir}/skills/${VIEW_SKILL}"
	[ -f "${view_dir}/view.jq" ] && [ -r "${view_dir}/view.jq" ] ||
		install_fault "layout module missing; expected ${view_dir}/view.jq; try installing the ${VIEW_SKILL} skill"
}

# Creates the effort's metrics/ folder, mode 700, when it is missing.
open_metrics_folder() {
	metrics_dir="${effort}/${METRICS_FOLDER}"
	[ ! -L "${metrics_dir}" ] || folder_fault "${metrics_dir} is a symbolic link; expected a real folder; try moving it aside"
	if [ ! -d "${metrics_dir}" ]; then
		[ ! -e "${metrics_dir}" ] || folder_fault "${metrics_dir} exists and is not a folder; expected the metrics folder; try moving it aside"
		mkdir "${metrics_dir}" 2>/dev/null || [ -d "${metrics_dir}" ] ||
			folder_fault "cannot create ${metrics_dir}; expected a writable effort folder; try checking its permissions"
	fi
	[ ! -L "${metrics_dir}" ] || folder_fault "${metrics_dir} is a symbolic link; expected a real folder; try moving it aside"
	chmod 700 "${metrics_dir}" ||
		folder_fault "cannot set mode 700 on ${metrics_dir}; expected a folder it owns; try checking its owner"
}

# Takes metrics/.lock, a folder only one harvest can create, and writes its
# PID in it. A lock whose PID is gone is broken; a live one is waited on.
take_lock() {
	lock_path="${metrics_dir}/.lock"
	waited=0
	while :; do
		if mkdir "${lock_path}" 2>/dev/null; then
			lock_dir=${lock_path}
			printf '%s\n' "$$" >"${lock_dir}/pid" ||
				folder_fault "cannot write ${lock_dir}/pid; expected a writable metrics folder; try checking free space"
			return 0
		fi
		[ -d "${lock_path}" ] && [ ! -L "${lock_path}" ] ||
			folder_fault "cannot create the lock ${lock_path}; expected a writable metrics folder; try checking its permissions"
		read_lock_pid
		# shellcheck disable=SC2310 # its status says whether the holder is gone
		if [ -n "${lock_pid}" ] && ! pid_alive "${lock_pid}"; then
			break_lock
			continue
		fi
		[ "${waited}" -lt "${LOCK_WAIT_SECONDS}" ] || {
			warn "${metrics_dir} is locked by ${lock_path}${lock_pid:+ (PID ${lock_pid})}; expected one harvest at a time; try again once it has ended; if none is running, remove the lock with rm -rf '${lock_path}'"
			exit "${LOCKED_EXIT}"
		}
		sleep 1
		waited=$((waited + 1))
	done
}

# Sets lock_pid to the PID in the lock, empty when it holds none yet.
read_lock_pid() {
	lock_pid=''
	[ -f "${lock_path}/pid" ] || return 0
	IFS= read -r lock_pid <"${lock_path}/pid" 2>/dev/null || true
	case ${lock_pid} in
		'' | *[!0-9]*) lock_pid='' ;;
		*) ;;
	esac
}

pid_alive() {
	kill -0 "$1" 2>/dev/null
}

# Moves the dead harvest's lock aside under a name of its own, so a second
# breaker cannot remove a lock taken meanwhile, then removes it.
break_lock() {
	broken="${metrics_dir}/.lock.broken.$$"
	mv "${lock_path}" "${broken}" 2>/dev/null || return 0
	rm -f "${broken}/pid"
	rmdir "${broken}" 2>/dev/null || warn "could not remove the broken lock ${broken}; remove it by hand"
	warn "broke the lock of PID ${lock_pid}, which is no longer running"
}

harvest() {
	harvested_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || install_fault 'date failed; expected the UTC time; try date -u'
	collect_sessions
	new_temp_file events
	events_file=${made}
	new_temp_file results
	results_file=${made}
	new_temp_file status
	status_file=${made}
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
# JSON files, metrics/ aside, one per line, sorted.
collect_sessions() {
	key_pattern="\"claude_session_id\"[[:space:]]*:[[:space:]]*\"${SESSION_ID_ERE}\""
	found=$(cd -P -- "${effort}" && LC_ALL=C find . -path "./${METRICS_FOLDER}" -prune -o -type f -name '*.json' \
		-exec sh -c 'grep -hoE "$0" "$@" || [ "$?" -eq 1 ]' "${key_pattern}" {} +) ||
		folder_fault "cannot read the JSON files of ${effort}; expected readable files; try checking their permissions"
	sessions=$(printf '%s\n' "${found}" | LC_ALL=C sed -n -E "s/.*\"(${SESSION_ID_ERE})\"\$/\\1/p" | LC_ALL=C sort -u) ||
		install_fault 'sed or sort failed on the session ids; expected POSIX tools; try a POSIX sed and sort on PATH'
}

# Sets made to a new empty temp file in metrics/, $1 naming its use, and adds
# it to the temp files clean_up removes.
new_temp_file() {
	made=$(mktemp "${metrics_dir}/.$1.XXXXXX") ||
		folder_fault "cannot create a temp file in ${metrics_dir}; expected a writable folder; try checking its permissions and free space"
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
		folder_fault "cannot write ${events_file}; expected free space in ${metrics_dir}"
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

# Writes each session with a transcript from results_file. A session that
# launched a subagent whose transcript is gone is partly expired: its file
# keeps its figures, marked expired, since a new count would be lower; with
# no file yet, the partial figures are written, marked expired.
write_present_sessions() {
	while IFS= read -r session; do
		[ -n "${session}" ] || continue
		partly_expired=$(jq -r --arg session "${session}" '.[$session].partly_expired // false' "${results_file}") ||
			install_fault 'jq failed reading the counts; expected jq 1.6+; try jq --version'
		# shellcheck disable=SC2310 # its status says whether a file was there to keep
		if [ "${partly_expired}" = true ] && keep_expired_file "${session}"; then
			continue
		fi
		new_temp_file "${session}"
		temp_file=${made}
		jq --arg session "${session}" --arg at "${harvested_at}" \
			'{claude_session_id: $session, harvested_at: $at}
			+ (.[$session] // {main_thread: [], subagents: [], outside: []} | del(.partly_expired))
			+ (if .[$session].partly_expired then {expired: true} else {} end)' \
			"${results_file}" >"${temp_file}" ||
			folder_fault "cannot write the temp file ${temp_file}; expected free space in ${metrics_dir}"
		place_session_file "${session}" install
	done <<EOF
${present_sessions}
EOF
}

# Keeps the last figures of each session whose transcript is gone and marks
# them expired; a session with no file yet is only listed by the view.
mark_expired_sessions() {
	while IFS= read -r session; do
		[ -n "${session}" ] || continue
		# shellcheck disable=SC2310 # its status says whether a file was there to keep
		keep_expired_file "${session}" || expired_unseen="${expired_unseen} ${session}"
	done <<EOF
${expired_sessions}
EOF
}

# Marks session $1's file expired, its figures kept; fails when it has no file.
keep_expired_file() {
	session_file="${metrics_dir}/$1.json"
	[ -f "${session_file}" ] && [ ! -L "${session_file}" ] || return 1
	new_temp_file "$1"
	temp_file=${made}
	if ! jq '.expired = true' "${session_file}" >"${temp_file}" 2>/dev/null; then
		log_rejection "${session_file}: is not JSON; expected the session file metrics.sh writes"
		warn "${session_file} is left as it is"
		return 0
	fi
	place_session_file "$1" kept
}

# Moves temp_file onto session $1's file once it passes the validator. $2
# says what the file is: install (a file built here) must meet every rule,
# and a problem exits 5; kept (a file read back and marked expired) must
# keep its shape, and a problem leaves it as it is.
place_session_file() {
	session_file="${metrics_dir}/$1.json"
	case $2 in
		install) check='metrics_session_problems' ;;
		*) check='metrics_session_shape_problems' ;;
	esac
	problems=$(jq -r -L "${own_dir}" "include \"metrics-validator\"; ${check}" "${temp_file}" </dev/null) ||
		install_fault 'jq failed on a session file; expected jq 1.6+ and metrics-validator.jq; try jq --version'
	if [ -n "${problems}" ]; then
		report_problems "${session_file}" "${problems}"
		[ "$2" = kept ] || install_fault 'a session file built breaks metrics-validator.jq; expected matching metrics.sh and validator; try reinstalling procedure-metrics'
		warn "${session_file} is left as it is"
		return 0
	fi
	chmod 600 "${temp_file}" ||
		folder_fault "cannot set mode 600 on ${temp_file}; expected a file it owns"
	mv -f "${temp_file}" "${session_file}" ||
		folder_fault "cannot move ${temp_file} onto ${session_file}; expected a writable ${metrics_dir}"
}

# Reports the problems $2 of file $1, one line each, at most MAX_PROBLEMS.
report_problems() {
	reported=0
	while IFS= read -r problem; do
		reported=$((reported + 1))
		[ "${reported}" -gt "${MAX_PROBLEMS}" ] || log_rejection "$1: ${problem}"
	done <<EOF
$2
EOF
	[ "${reported}" -le "${MAX_PROBLEMS}" ] || log_rejection "$1: ${reported} problems, showing ${MAX_PROBLEMS}"
}

# Warns rejection line $1 and appends it, after the harvest time, to the
# rejection log, so the rules a file keeps breaking can be told apart.
log_rejection() {
	warn "$1"
	rejections_log="${metrics_dir}/${REJECTIONS_LOG}"
	printf '%s %s\n' "${harvested_at}" "$1" 2>/dev/null >>"${rejections_log}" ||
		warn "cannot append to ${rejections_log}; expected a writable metrics folder; try checking its permissions"
}

# Prints the view from the session files whose shape passes the validator.
show_view() {
	file_count=0
	set --
	while IFS= read -r session; do
		[ -n "${session}" ] || continue
		session_file="${metrics_dir}/${session}.json"
		[ -f "${session_file}" ] && [ ! -L "${session_file}" ] || continue
		problems=$(jq -r -L "${own_dir}" 'include "metrics-validator"; metrics_session_shape_problems' "${session_file}" </dev/null 2>/dev/null) ||
			problems='is not JSON; expected the session file metrics.sh writes'
		if [ -n "${problems}" ]; then
			report_problems "${session_file}" "${problems}"
			warn "${session_file} is left out of the view"
			continue
		fi
		set -- "$@" --arg "p${file_count}" "${session_file}" --rawfile "f${file_count}" "${session_file}"
		file_count=$((file_count + 1))
	done <<EOF
${sessions}
EOF
	jq -n -r -L "${view_dir}" --argjson count "${file_count}" --arg missing "${expired_unseen}" --arg name "${effort_name}" \
		--arg at "${harvested_at}" "$@" "${VIEW_JQ}" </dev/null ||
		install_fault "jq failed printing the view; expected jq 1.6+ and the ${VIEW_SKILL} skill's view.jq; try jq --version"
}

# Removes this run's temp files and, last, the lock it took.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	while IFS= read -r leftover; do
		[ -z "${leftover}" ] || rm -f "${leftover}"
	done <<EOF
${temp_files}
EOF
	if [ -n "${lock_dir}" ]; then
		rm -f "${lock_dir}/pid"
		rmdir "${lock_dir}" 2>/dev/null ||
			warn "could not remove the lock ${lock_dir}; expected it gone; try rm -rf '${lock_dir}'"
	fi
}

temp_files='' lock_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

main "$@"
