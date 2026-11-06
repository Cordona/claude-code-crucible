#!/usr/bin/env sh
# Claude Code's SubagentStop hook for an effort's developers. It finds the
# stopping agent's working seat, checks the agent's report and, when the
# report fits, commits the worktree as the seat's next iteration and sets the
# seat idle. A report that does not fit blocks the stop with the checker's
# lines, MAX_BLOCKS times at most, and records why in the seat's own log in
# the worktree, which block-relay-hook.sh reads. A fault allows the stop and is
# logged: a failing hook must never hold an agent. Every child's stdout is captured, so stdout carries only the
# block decision.
set -eu
umask 077

readonly PROG='report-commit-hook.sh'
readonly MAX_BLOCKS=2
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
on stdin and takes its agent_id; finds the agent's seat with slots.sh find
in each DIR/*/slots.json; for a developer seat, drops the empty keys
from this iteration's report (iteration.sh's REPORT path) with
${PRUNER}, then checks it with ${CHECKER}.

A working seat's stop, whatever its iteration:
  report fits     commits the worktree with commit.sh --all, the report
                  with it (the message from commit-input.sh and
                  commit-message.sh: the seat's next build or test
                  iteration), restarts the block count, sets the seat
                  idle; nothing changed: no commit, seat idle, logged
                  no-change
  report misfits  blocks the stop with the checker's lines (a missing
                  report too: they name its path); the misfit
                  after ${MAX_BLOCKS} blocks sets the seat gave-up and commits nothing
Every other stop goes ahead:
  idle or gave-up seat  logged idle-stop or gave-up-stop, nothing committed
                        (main sets a seat working before it wakes the agent)
  awaiting_round        a fix round, not handled yet; logged
  no seat, not a developer seat, or any fault

--efforts DIR  absolute path of the efforts folder; default
               \${CRUCIBLE_HOME:-\$HOME/.crucible}/efforts

writes: DIR/<effort>/logs/report-commit.log, one line per outcome (UTC time,
slot, agent_id, event id, outcome, like committed <sha> build-iteration 2
or blocked 1: <the checker's lines joined by " / ">);
DIR/<effort>/blocks/<slot>, the block count; and, for a block or a give-up,
one JSON line in the worktree's .crucible-effort/logs/<slot>/report-commit.jsonl
({time, event, outcome, block, reason}, reason the text the agent is sent),
committed with the seat's next commit. The event id is the cksum of the
event JSON, the same for every hook Claude Code gives that event.

stdout: {"decision":"block","reason":"<text>"} to block the stop; nothing
to let it go ahead. Faults go to the log, or to stderr before a seat is found.

exit codes:
  0  done, whatever the outcome
  1  wrong command line (never 2: Claude Code reads 2 as a block)

needs: POSIX sh, jq 1.6+, git 2.26+; ../seats/slots.sh, ../seats/iteration.sh,
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

# Appends outcome $1 to the effort's log; stderr when no effort is known yet
# or the log can't be written.
log() {
	if [ -z "${effort_dir}" ]; then
		warn "$1"
		return 0
	fi
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || now='unknown-time'
	if ! { mkdir -p -- "${effort_dir}/logs" &&
		printf '%s %s %s %s %s\n' "${now}" "${slot:--}" "${agent_id:--}" "${event_id:--}" "$1" >>"${effort_dir}/logs/report-commit.log"; } 2>/dev/null; then
		warn "could not append to ${effort_dir}/logs/report-commit.log: $1"
	fi
}

# Logs fault $1 and lets the stop go ahead.
fault() {
	log "fault: $1"
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
	log "fault: $1 exit ${child_rc}: ${shown_line}"
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
			warn "agent_id ${shown_agent} is not an id slots.json holds; the stop goes ahead"
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

# Sets effort_dir, slots_file and seat_json from the first slots.json with a
# seat for agent_id; a slots.json slots.sh can't read is logged and skipped.
find_seat() {
	for candidate in "${efforts}"/*/slots.json; do
		[ -f "${candidate}" ] || continue
		candidate_dir=${candidate%/slots.json}
		[ ! -L "${candidate_dir}" ] || continue
		run sh "${own_dir}/../seats/slots.sh" find --slots "${candidate}" --agent-id "${agent_id}"
		case ${child_rc} in
			0)
				effort_dir=${candidate_dir} slots_file=${candidate} seat_json=${child_out}
				return 0
				;;
			6) ;;
			*)
				effort_dir=${candidate_dir}
				log_child_fault 'slots.sh find'
				effort_dir=''
				;;
		esac
	done
	allow
}

# Sets role, status, slot, worktree and awaiting_round from the seat.
read_seat() {
	fields=$(printf '%s\n' "${seat_json}" |
		jq -r '.role, .status, .slot, .worktree // "", (.awaiting_round // "" | tostring)') ||
		fault 'jq could not read the seat slots.sh find printed'
	# $( ) drops trailing empty lines, so a read past them finds the end: empty.
	role='' status='' slot='' worktree='' awaiting_round=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r slot || :
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

# Sets report to this iteration's report path from iteration.sh.
find_report() {
	run sh "${own_dir}/../seats/iteration.sh" --slots "${slots_file}" --slot "${slot}"
	[ "${child_rc}" -eq 0 ] || child_fault 'iteration.sh'
	report=$(printf '%s\n' "${child_out}" | sed -n 's/^REPORT: //p')
	[ -n "${report}" ] || fault 'iteration.sh printed no REPORT line'
}

# Drops the report's empty keys, so an empty list costs the agent no block.
prune_report() {
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
block_or_give_up() {
	counter="${effort_dir}/blocks/${slot}"
	blocks=''
	[ ! -f "${counter}" ] || blocks=$(head -n 1 "${counter}") || blocks=''
	# A count that is no small number restarts, so a damaged file can't hold the agent.
	case ${blocks} in
		'' | *[!0-9]* | ????*) blocks=0 ;;
		*) ;;
	esac
	blocks=$((blocks + 1))
	[ "${blocks}" -le "${MAX_BLOCKS}" ] || give_up
	if ! { mkdir -p -- "${effort_dir}/blocks" && printf '%s\n' "${blocks}" >"${counter}"; }; then
		fault "could not write the block count ${counter}"
	fi
	reason="${BLOCK_LEAD}${newline}$(checker_lines)"
	decision=$(jq -nc --arg reason "${reason}" '{decision: "block", reason: $reason}') ||
		fault 'jq could not build the block decision'
	seat_log blocked "${blocks}" "${reason}"
	log "blocked ${blocks}: $(checker_line)"
	printf '%s\n' "${decision}"
	exit 0
}

give_up() {
	rm -f -- "${counter}"
	run_lines=$(checker_lines)
	run sh "${own_dir}/../seats/slots.sh" status --slots "${slots_file}" --slot "${slot}" --status gave-up
	[ "${child_rc}" -eq 0 ] || child_fault 'slots.sh status gave-up'
	seat_log gave-up "${blocks}" "${run_lines}"
	log "gave-up: $(printf '%s' "${run_lines}" | flatten)"
	allow
}

# Prints the checker's lines from the last run.
checker_lines() {
	cat "${work_dir}/stderr" 2>/dev/null || :
}

# Prints the checker's lines as one log-safe line.
checker_line() {
	checker_lines | flatten
}

# Joins stdin's lines with " / " and masks control characters.
flatten() {
	awk 'NR > 1 { printf " / " } { printf "%s", $0 }' | tr '[:cntrl:]' '?'
}

# Appends outcome $1, block number $2 and reason $3 to the seat's own log in
# its worktree; a log that can't be written is logged, never a fault.
seat_log() {
	seat_log_dir="${worktree}/.crucible-effort/logs/${slot}"
	now=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || now='unknown-time'
	if ! { mkdir -p -- "${seat_log_dir}" &&
		jq -nc --arg time "${now}" --arg event "${event_id}" --arg outcome "$1" \
			--argjson block "$2" --arg reason "$3" \
			'{time: $time, event: $event, outcome: $outcome, block: $block, reason: $reason}' \
			>>"${seat_log_dir}/report-commit.jsonl"; } 2>/dev/null; then
		log "could not append to ${seat_log_dir}/report-commit.jsonl"
	fi
}

# Builds the commit-message input, writes the message, commits every change,
# restarts the seat's block count and sets the seat idle.
commit_work() {
	run sh "${own_dir}/../commit/commit-input.sh" --slots "${slots_file}" --slot "${slot}" --out "${work_dir}/message.json"
	[ "${child_rc}" -eq 0 ] || child_fault 'commit-input.sh'
	iteration=$(jq -r '.trailers | to_entries[] | select(.key | endswith("-iteration")) | "\(.key) \(.value)"' \
		"${work_dir}/message.json" 2>/dev/null) || iteration=''
	run sh "${own_dir}/../commit/commit-message.sh" --input "${work_dir}/message.json" --out "${work_dir}/message"
	[ "${child_rc}" -eq 0 ] || child_fault 'commit-message.sh'
	run sh "${own_dir}/../commit/commit.sh" --worktree "${worktree}" --message-file "${work_dir}/message" \
		--author-name "${slot}" --author-email "${slot}@crucible.invalid" --all
	case ${child_rc} in
		0) ;;
		5) set_idle 'no-change' ;;
		*) child_fault 'commit.sh' ;;
	esac
	rm -f -- "${effort_dir}/blocks/${slot}"
	log "committed ${child_out} ${iteration}"
	run sh "${own_dir}/../seats/slots.sh" status --slots "${slots_file}" --slot "${slot}" --status idle
	[ "${child_rc}" -eq 0 ] || child_fault 'slots.sh status idle'
}

# A fitting report with nothing for git to commit (each iteration's report
# is a new file, so only a report git ignores gets here): no commit; logs $1,
# restarts the block count and sets the seat idle, so a later wake starts
# clean.
set_idle() {
	rm -f -- "${effort_dir}/blocks/${slot}"
	log "$1"
	run sh "${own_dir}/../seats/slots.sh" status --slots "${slots_file}" --slot "${slot}" --status idle
	[ "${child_rc}" -eq 0 ] || child_fault 'slots.sh status idle'
	allow
}

# An unexpected failure lets the stop go ahead too, logged.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
	[ "${exit_status}" -ne 0 ] && [ "${usage_failed}" = no ] || return 0
	work_dir=''
	log "fault: unexpected exit ${exit_status}"
	exit 0
}

work_dir='' usage_failed=no effort_dir='' slot='' agent_id='' event_id=''
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
[ -z "${awaiting_round}" ] || {
	log 'ignored-fix-round: fix round not handled yet'
	allow
}
# Only a working seat's stop is checked; nobody woke an idle or gave-up seat.
[ "${status}" = working ] || {
	log "${status}-stop"
	allow
}
find_checker
find_report
prune_report
check_report
commit_work
