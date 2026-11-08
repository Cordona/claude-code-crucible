#!/usr/bin/env sh
# Claude Code's SubagentStop hook for an effort's developers. It finds the
# stopping agent's working seat, checks the agent's report and, when the
# report fits, commits every change in the worktree but other seats' folders
# as the seat's next iteration and sets the seat idle. A report that does not fit blocks the stop with the checker's
# lines, MAX_BLOCKS times at most, and records why in the iteration's
# rejections file in the seat folder, which block-relay-hook.sh reads and
# which also holds the block count. A fault allows the stop and goes to the
# seat folder's faults log: a failing hook must never hold an agent. Only
# failures are written. Every child's stdout is captured, so stdout carries
# only the block decision.
set -eu
umask 077

readonly PROG='report-commit-hook.sh'
readonly MAX_BLOCKS=2
readonly SEATS_DIR='.crucible/seats'
readonly REJECTIONS='stop-hook-rejections.jsonl'
readonly FAULTS='stop-hook-faults.log'
readonly BLOCK_LEAD='Your stop is blocked: fix your report, then stop again.'
# From this folder to the report checker of the code-developer agent's skill.
readonly CHECKER_DIR='../../../../../agents/code-developer/skills/standard-code-development-report/scripts'
readonly CHECKER='dev-report-check.sh'
readonly PRUNER='dev-report-prune.sh'
# A fault line quotes at most this many bytes of a child's first stderr line.
readonly MAX_QUOTE_BYTES=200
readonly newline='
'
# The C locale keeps the shell byte-wise; jq reads the JSON as UTF-8.
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} [--efforts DIR]
       sh ${PROG} --help | -h

Claude Code's SubagentStop hook for effort developers. Reads the event JSON
on stdin and takes its agent_id; finds the agent's seat with seats.sh find
in each DIR/*/seats.json; for a developer seat, drops the empty keys
from this iteration's report (iteration.sh's REPORT path) with
${PRUNER}, then checks it with ${CHECKER}.

The seat folder is <worktree>/${SEATS_DIR}/<seat>/; iteration N's report
is its iterations/N/<build or test>-report.json.

A working seat's stop, whatever its iteration:
  report fits     commits with commit.sh --seat <seat>: every change in
                  the worktree but other seats' folders, so the report
                  and the iteration's rejections file too (the seat's own
                  folder even where a repo ignore rule covers it); a report with
                  no code change commits alone (the message from
                  commit-input.sh and commit-message.sh: the seat's next
                  build or test iteration); sets the seat idle; nothing
                  for git to commit: no commit, seat idle
  report misfits  blocks the stop with the checker's lines (a missing
                  report too: they name its path); the misfit after
                  ${MAX_BLOCKS} blocks of this agent on this report since its
                  last give-up sets the seat gave-up and commits nothing
Every other stop goes ahead; nothing is written but a fault line:
  idle or gave-up seat  (main sets a seat working before it wakes the agent)
  awaiting_round        a fix round, not handled yet
  no seat, not a developer seat, or any fault

--efforts DIR  absolute path of the efforts folder; default
               \${CRUCIBLE_HOME:-\$HOME/.crucible}/efforts

writes, failures only:
  iterations/N/${REJECTIONS} in the seat folder, for a block or a
    give-up, one JSON line {time, event, agent_id, report, outcome, block,
    reason}: UTC time, the event id, the agent, the report's file name,
    blocked or gave-up, the block number (the blocked lines of this report
    and agent since its last gave-up line, plus one) and the text the
    agent is sent; committed
    with the iteration
  ${FAULTS} in the seat folder, one line per fault: UTC time, agent_id,
    event id, fault: <what failed>; to stderr before the seat is known or
    when the file can't be written
Nothing is written through a symbolic link: a link at the file, or at a
folder from the worktree's .crucible down to it, is named on stderr and is a
fault; a block that can't be recorded lets the stop go ahead, and a report
with such a link is a fault before it is pruned or checked.
The event id is the cksum of the event JSON, the same for every hook
Claude Code gives that event.

stdout: {"decision":"block","reason":"<text>"} to block the stop; nothing
to let it go ahead.

exit codes:
  0  done, whatever the outcome
  1  wrong command line (never 2: Claude Code reads 2 as a block)

needs: POSIX sh, jq 1.6+, git 2.26+; ../seats/seats.sh, ../seats/iteration.sh,
../commit/commit-input.sh, ../commit/commit-message.sh and ../commit/commit.sh
from this script's folder,
${PRUNER} and ${CHECKER} at ${CHECKER_DIR}
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	usage_failed=yes
	exit 1
}

# Prints $1 with each control character as "?", so a value can't split a line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

parse_args() {
	efforts=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--efforts)
				[ -n "${2-}" ] || usage_error '--efforts needs a value; expected --efforts DIR'
				[ -z "${efforts}" ] || usage_error '--efforts given twice; expected one'
				efforts=$2
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --efforts or --help"
				;;
		esac
	done
	case ${efforts} in
		'' | /*) ;;
		*)
			shown_efforts=$(printable "${efforts}")
			usage_error "--efforts ${shown_efforts} is not absolute; expected an absolute path"
			;;
	esac
}

# Lets the stop go ahead.
allow() {
	exit 0
}

# Appends fault $1 to the seat folder's faults log; stderr while no seat
# folder is known or when the log can't be written.
log_fault() {
	if [ -z "${seat_dir}" ]; then
		warn "fault: $1"
		return 0
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || now='unknown-time'
	# shellcheck disable=SC2310 # its status is the answer; it checks each step itself
	if no_link_below "${worktree_root}" "${seat_dir}/${FAULTS}" &&
		{ mkdir -p -- "${seat_dir}" &&
			printf '%s %s %s fault: %s\n' "${now}" "${agent_id:--}" "${event_id:--}" "$1" >>"${seat_dir}/${FAULTS}"; } 2>/dev/null; then
		return 0
	fi
	warn "could not append to ${seat_dir}/${FAULTS}: fault: $1"
}

# Succeeds when neither file $2 nor a folder between worktree $1 and it is a
# symbolic link; else names the link on stderr. A missing level ends the
# walk: nothing below it exists. The hook runs outside the agent's permission
# prompts, so a link the agent planted must never carry a write out.
no_link_below() {
	case $2 in
		"$1"/*) ;;
		*) return 1 ;;
	esac
	level_path=$1
	levels_left=${2#"$1"/}
	while [ -n "${levels_left}" ]; do
		level=${levels_left%%/*}
		case ${levels_left} in
			*/*) levels_left=${levels_left#*/} ;;
			*) levels_left='' ;;
		esac
		case ${level} in
			'' | . | ..) return 1 ;;
			*) ;;
		esac
		level_path="${level_path}/${level}"
		if [ -L "${level_path}" ]; then
			shown_link=$(printable "${level_path}")
			warn "${shown_link} is a symbolic link; nothing is written through it"
			return 1
		fi
		[ -e "${level_path}" ] || return 0
	done
}

# Logs fault $1 and lets the stop go ahead.
fault() {
	log_fault "$1"
	allow
}

# Runs a command, its stdout in child_out, its stderr in a file, its exit
# code in child_rc; never stops the script.
run() {
	child_rc=0
	child_out=$("$@" 2>"${work_dir}/stderr") || child_rc=$?
}

# Logs "fault: <label $1> exit <code>: <first stderr line>" for the last run
# and lets the stop go ahead.
child_fault() {
	log_child_fault "$1"
	allow
}

log_child_fault() {
	first_line=$(head -n 1 "${work_dir}/stderr" | cut -c "1-${MAX_QUOTE_BYTES}") || first_line=''
	shown_line=$(printable "${first_line}")
	log_fault "$1 exit ${child_rc}: ${shown_line}"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets agent_id from the event on stdin; an event without a usable one is no
# effort agent's, so the stop goes ahead.
read_event() {
	command -v jq >/dev/null 2>&1 || {
		warn 'jq not found; expected jq 1.6+ on PATH; the stop goes ahead'
		allow
	}
	cat >"${work_dir}/event" || {
		warn 'stdin could not be read; the stop goes ahead'
		allow
	}
	event_id=$(cksum <"${work_dir}/event" | cut -d ' ' -f 1) || event_id=''
	agent_id=$(jq -r 'if type == "object" then .agent_id // empty | strings else empty end' "${work_dir}/event" 2>/dev/null) || {
		warn 'stdin is not one JSON object; expected the SubagentStop event; the stop goes ahead'
		allow
	}
	case ${agent_id} in
		'') allow ;;
		*[!A-Za-z0-9_-]*)
			shown_agent=$(printable "${agent_id}")
			warn "agent_id ${shown_agent} is not an id seats.json holds; the stop goes ahead"
			allow
			;;
		*) ;;
	esac
}

# Sets efforts to the default when --efforts is not given; a space that can't
# be named, or holds no efforts folder, holds no effort agent.
resolve_efforts() {
	[ -z "${efforts}" ] || return 0
	if [ -n "${CRUCIBLE_HOME:-}" ]; then
		root=${CRUCIBLE_HOME}
	elif [ -n "${HOME:-}" ]; then
		root="${HOME}/.crucible"
	else
		warn 'neither CRUCIBLE_HOME nor HOME is set; expected one to name the space; the stop goes ahead'
		allow
	fi
	case ${root} in
		/*) ;;
		*)
			shown_root=$(printable "${root}")
			warn "the space ${shown_root} is not absolute; expected CRUCIBLE_HOME absolute; the stop goes ahead"
			allow
			;;
	esac
	while [ "${root}" != "${root%/}" ]; do root=${root%/}; done
	efforts="${root}/efforts"
}

# Sets seats_file and seat_json from the first seats.json with a seat for
# agent_id; a seats.json seats.sh can't read is a fault on stderr, skipped.
find_seat() {
	for candidate in "${efforts}"/*/seats.json; do
		[ -f "${candidate}" ] || continue
		candidate_dir=${candidate%/seats.json}
		[ ! -L "${candidate_dir}" ] || continue
		run sh "${own_dir}/../seats/seats.sh" find --seats "${candidate}" --agent-id "${agent_id}"
		case ${child_rc} in
			0)
				seats_file=${candidate} seat_json=${child_out}
				return 0
				;;
			6) ;;
			*) log_child_fault 'seats.sh find' ;;
		esac
	done
	allow
}

# Sets role, status, seat, worktree and awaiting_round from the seat.
read_seat() {
	fields=$(printf '%s\n' "${seat_json}" |
		jq -r '.role, .status, .seat, .worktree // "", (.awaiting_round // "" | tostring)') ||
		fault 'jq could not read the seat seats.sh find printed'
	# $( ) drops trailing empty lines, so a read past them finds the end: empty.
	role='' status='' seat='' worktree='' awaiting_round=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r seat || :
		IFS= read -r worktree || :
		IFS= read -r awaiting_round || :
	} <<EOF
${fields}
EOF
}

# Sets checker and pruner to their physical paths; the tree may be
# installed through a link.
find_checker() {
	checker_dir=$(cd -P -- "${own_dir}/${CHECKER_DIR}" 2>/dev/null && pwd -P) ||
		fault "the report checker's folder ${CHECKER_DIR} is not beside ${own_dir}; expected the software-development tree installed whole"
	checker="${checker_dir}/${CHECKER}"
	[ -f "${checker}" ] || fault "${checker} is missing; expected the code-developer agent's report skill"
	pruner="${checker_dir}/${PRUNER}"
	[ -f "${pruner}" ] || fault "${pruner} is missing; expected the code-developer agent's report skill"
}

# Sets worktree_root and seat_dir, where this hook's failures go, once the
# seat is known to be a developer's with a worktree folder.
set_seat_dir() {
	shown_worktree=$(printable "${worktree}")
	[ -n "${worktree}" ] && [ -d "${worktree}" ] || fault "seat ${seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	worktree_root=${worktree%/}
	seat_dir="${worktree_root}/${SEATS_DIR}/${seat}"
}

# Sets report, its file name report_name and the iteration's rejections
# file from iteration.sh.
find_report() {
	run sh "${own_dir}/../seats/iteration.sh" --seats "${seats_file}" --seat "${seat}"
	[ "${child_rc}" -eq 0 ] || child_fault 'iteration.sh'
	report=$(printf '%s\n' "${child_out}" | sed -n 's/^REPORT: //p')
	[ -n "${report}" ] || fault 'iteration.sh printed no REPORT line'
	report_name=${report##*/}
	rejections="${report%/*}/${REJECTIONS}"
}

# Drops the report's empty keys, so an empty list costs the agent no block.
prune_report() {
	# shellcheck disable=SC2310 # its status is the answer; it checks each step itself
	no_link_below "${worktree_root}" "${report}" || {
		shown_report=$(printable "${report}")
		fault "the report ${shown_report} or a folder above it is a symbolic link; expected real files in the seat folder"
	}
	run sh "${pruner}" --report "${report}"
	[ "${child_rc}" -eq 0 ] || child_fault "${PRUNER}"
}

check_report() {
	run sh "${checker}" --report "${report}" --worktree "${worktree}"
	case ${child_rc} in
		0) ;;
		3) block_or_give_up ;;
		*) child_fault "${CHECKER}" ;;
	esac
}

# Counts this misfit; blocks the stop up to MAX_BLOCKS times, then gives up.
# The count is a rejection line written, so a block that can't be recorded
# is a fault and the stop goes ahead: the agent is never held uncounted.
block_or_give_up() {
	count_blocks
	blocks=$((blocks + 1))
	[ "${blocks}" -le "${MAX_BLOCKS}" ] || give_up
	reason="${BLOCK_LEAD}${newline}$(checker_lines)"
	decision=$(jq -nc --arg reason "${reason}" '{decision: "block", reason: $reason}') ||
		fault 'jq could not build the block decision'
	reject blocked "${blocks}" "${reason}"
	[ "${rejected}" = yes ] || fault "could not append to ${rejections}; the stop goes ahead unblocked"
	printf '%s\n' "${decision}"
	exit 0
}

# Sets blocks to the blocked lines of this report and this agent after its
# last gave-up line, so a cold agent on the same seat starts at 0 and a
# re-woken one gets its blocks again; an unreadable line counts for none.
count_blocks() {
	blocks=0
	[ -f "${rejections}" ] || return 0
	blocks=$(jq -nR --arg report "${report_name}" --arg agent "${agent_id}" '
		[inputs | fromjson? | objects | select(.report == $report and .agent_id == $agent) | .outcome]
		| (map(. == "gave-up") | rindex(true)) as $last_give_up
		| .[(if $last_give_up == null then 0 else $last_give_up + 1 end):]
		| map(select(. == "blocked")) | length' \
		"${rejections}" 2>/dev/null) || fault "jq could not read ${rejections}"
}

# Writes the gave-up line before the seat leaves working: block-relay-hook.sh
# ends its wait once the seat is not working, and must find the line then.
give_up() {
	run_lines=$(checker_lines)
	reject gave-up "${blocks}" "${run_lines}"
	run sh "${own_dir}/../seats/seats.sh" status --seats "${seats_file}" --seat "${seat}" --status gave-up
	[ "${child_rc}" -eq 0 ] || child_fault 'seats.sh status gave-up'
	[ "${rejected}" = yes ] || log_fault "could not append to ${rejections}; the seat gave up"
	allow
}

# Prints the checker's lines from the last run.
checker_lines() {
	cat "${work_dir}/stderr" 2>/dev/null || :
}

# Appends outcome $1, block number $2 and reason $3 to the iteration's
# rejections file; rejected says whether it was written.
reject() {
	rejected=no
	# shellcheck disable=SC2310 # its status is the answer; it checks each step itself
	no_link_below "${worktree_root}" "${rejections}" || return 0
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || now='unknown-time'
	{ mkdir -p -- "${rejections%/*}" &&
		jq -nc --arg time "${now}" --arg event "${event_id}" --arg agent "${agent_id}" \
			--arg report "${report_name}" --arg outcome "$1" --argjson block "$2" --arg reason "$3" \
			'{time: $time, event: $event, agent_id: $agent, report: $report, outcome: $outcome, block: $block, reason: $reason}' \
			>>"${rejections}"; } 2>/dev/null || return 0
	rejected=yes
}

# Builds the commit-message input, writes the message, commits every change
# but other seats' folders and sets the seat idle; commit.sh's exit 5,
# nothing staged, leaves no commit and the seat goes idle too.
commit_work() {
	run sh "${own_dir}/../commit/commit-input.sh" --seats "${seats_file}" --seat "${seat}" --out "${work_dir}/message.json"
	[ "${child_rc}" -eq 0 ] || child_fault 'commit-input.sh'
	run sh "${own_dir}/../commit/commit-message.sh" --input "${work_dir}/message.json" --out "${work_dir}/message"
	[ "${child_rc}" -eq 0 ] || child_fault 'commit-message.sh'
	run sh "${own_dir}/../commit/commit.sh" --worktree "${worktree}" --message-file "${work_dir}/message" \
		--author-name "${seat}" --author-email "${seat}@crucible.invalid" --seat "${seat}"
	case ${child_rc} in
		0 | 5) ;;
		*) child_fault 'commit.sh' ;;
	esac
	run sh "${own_dir}/../seats/seats.sh" status --seats "${seats_file}" --seat "${seat}" --status idle
	[ "${child_rc}" -eq 0 ] || child_fault 'seats.sh status idle'
}

# An unexpected failure lets the stop go ahead too, logged.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
	[ "${exit_status}" -ne 0 ] && [ "${usage_failed}" = no ] || return 0
	work_dir=''
	log_fault "unexpected exit ${exit_status}"
	exit 0
}

work_dir='' usage_failed=no worktree_root='' seat_dir='' seat='' agent_id='' event_id=''
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
own_path=$(script_dir)
own_dir=$(cd -P -- "${own_path}" && pwd -P) || {
	warn 'this script'\''s folder could not be entered; the stop goes ahead'
	allow
}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-report-commit.XXXXXX") || {
	warn 'mktemp could not create a work folder; expected a writable TMPDIR; the stop goes ahead'
	work_dir=''
	allow
}
read_event
resolve_efforts
find_seat
read_seat
[ "${role}" = developer ] || allow
# A fix round is not handled yet.
[ -z "${awaiting_round}" ] || allow
# Only a working seat's stop is checked; nobody woke an idle or gave-up seat.
[ "${status}" = working ] || allow
set_seat_dir
find_checker
find_report
prune_report
check_report
commit_work
