#!/usr/bin/env sh
# Claude Code's SubagentStop hook for an effort's developers. It finds the
# stopping agent's working seat, checks the agent's report draft and, when
# the report fits, commits the worktree's changes as the seat's next
# iteration, as the effort's identity, pushes the worktree's branch when the
# effort's settings ask for it, and records the report as one
# build.committed event, which also sets the seat idle. A commit that
# finishes a merge is also a seat.conflicts.resolved event.
# The draft is renamed to report.committing.json while it is committed, so a
# run that dies part way is finished or undone by the next one. A report
# that does not fit blocks the stop with the checker's lines, MAX_BLOCKS
# times at most, each block a stop.blocked event, which block-relay-hook.sh
# reads. A fault allows the stop and is a fault.raised event: a failing hook
# must never hold an agent. Every child's stdout is captured, so stdout
# carries only the block decision.
set -eu
umask 077

readonly PROG='report-commit-hook.sh'
# Two chances to fix a report: an agent that misfits a third time is not
# converging, and holding it longer only burns its turns.
readonly MAX_BLOCKS=2
readonly BLOCK_LEAD='Your stop is blocked: fix your report, then stop again.'
readonly MERGE_BLOCK_LEAD='Your stop is blocked: finish the merge, then stop again.'
readonly REPORT_FILE='report.json'
readonly COMMITTING_FILE='report.committing.json'
# From this folder to the report checker of the code-developer agent's skill.
readonly CHECKER_DIR='../../../../../agents/code-developer/skills/standard-code-development-report/scripts'
readonly CHECKER='dev-report-check.sh'
readonly PRUNER='dev-report-prune.sh'
# From this folder to the effort settings' reader.
readonly SETTINGS='../../../procedure-git-setup/scripts/settings.sh'
readonly CRUCIBLE_SKILL='crucible'
# A fault quotes at most this many bytes of a child's first stderr line.
readonly MAX_QUOTE_BYTES=200
# A block for files still holding conflict markers names at most this many.
readonly MAX_MARKED_NAMED=20
# Claude Code stops this hook after HOOK_LIMIT seconds (its settings.json
# timeout). The push gets what is left but PUSH_MARGIN, kept for recording
# the event; with less than MIN_PUSH_SECONDS left it could not finish. A
# wait for the events lock gets what is left but LOCK_MARGIN, at most
# MAX_LOCK_WAIT.
readonly HOOK_LIMIT=30
readonly PUSH_MARGIN=5
readonly MIN_PUSH_SECONDS=3
readonly LOCK_MARGIN=2
readonly MAX_LOCK_WAIT=5
readonly newline='
'
readonly tab='	'
# The C locale keeps the shell byte-wise; jq reads the JSON as UTF-8.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT

# The blocks of agent $agent since its seat's last build.committed or its
# own last stop.gave-up. Input: every event.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly BLOCKS_JQ='. as $all
| ([range(length) | select($all[.] as $e
	| $e.type == "build.committed" and $e.seat == $seat
	  or ($e.type == "stop.gave-up" and $e.body.agent_id == $agent))] | last) as $cut
| $all[(if $cut == null then 0 else $cut + 1 end):]
| map(select(.type == "stop.blocked" and .body.agent_id == $agent)) | length'

usage() {
	cat <<EOF
usage: sh ${PROG}
       sh ${PROG} --help | -h

Claude Code's SubagentStop hook for effort developers. Reads the event JSON
on stdin (agent_id, session_id); finds the agent's seat with events.sh
find-agent and seats.sh get. Only a working developer seat that holds the
agent goes on; every other stop goes ahead.

The report draft D is <effort>/drafts/agents/<seat>/${REPORT_FILE}
(iteration.sh's REPORT); C is ${COMMITTING_FILE} beside it.
  1 recover  C left by a run that died: an event whose draft is C's
             sha256 exists: C goes; a crucible(build) commit of the
             seat on its branch that no event's commit holds: its event is
             written from C (step 6), C goes, and with no D the stop goes
             ahead; else C moves back to D (a D already there is kept)
  2 check    ${PRUNER} --apply, then ${CHECKER}, then,
             with a merge under way, that no change, unmerged paths
             included, holds a leftover conflict marker (a misfit naming
             them); a misfit appends
             stop.blocked {seat, agent_id, hook_event, block, reason} and
             blocks; the misfit after ${MAX_BLOCKS} blocks of this agent since its
             seat's last build.committed or its last stop.gave-up
             appends stop.gave-up and sets the seat gave-up
  3 rename   D to C
  4 stage    the worktree's changes, .gitignore applied; none and no
             merge under way: no commit
  5 commit   commit-input.sh --report C, commit-message.sh, commit.sh
             as settings.sh get's identity, signed with its key;
             with AUTO_PUSH=yes push.sh --effort --seat --session --timeout
             the seconds left of ${HOOK_LIMIT} but ${PUSH_MARGIN} (under ${MIN_PUSH_SECONDS}: no push, a fault)
  6 record   build.committed: body C's JSON, facts seat, dispatch
             (seats.sh get's), commit (sha or null), draft (C's sha256);
             iteration: the commit's Iteration with its Agent-Seat, else
             the seat's current one; then C goes; a commit with two
             parents then appends seat.conflicts.resolved {seat, with (the
             second parent), conflicts (the paths git merge-tree finds
             conflicting between the parents), commit}, same iteration

The hook_event is the cksum of the event JSON, the same for every hook
Claude Code gives that event. stop.* and the seat's faults carry the
seat's current iteration: iteration.sh's ITERATION less one, none when
that is 0. Every fault, a commit made
unsigned and a failed or skipped push included, is a fault.raised by
events.sh fault {seat, agent_id, hook_event, what}, on stderr before the
effort is known or when it can't be written. Nothing is read or moved
through a symbolic link at the draft or a folder from the effort to it.

stdout: {"decision":"block","reason":"<text>"} to block the stop; nothing
to let it go ahead.

exit codes:
  0  done, whatever the outcome
  1  wrong command line (never 2: Claude Code reads 2 as a block)

needs: POSIX sh, jq 1.6+, git 2.38+, cksum, sha256sum or shasum;
../seats/seats.sh and ../seats/iteration.sh from this script's folder;
procedure-git-worktree's commit/commit-input.sh, commit/commit-message.sh,
commit/commit.sh and push/push.sh and procedure-git-setup's settings.sh
beside procedure-seat-run; ${PRUNER} and ${CHECKER} at ${CHECKER_DIR};
the ${CRUCIBLE_SKILL} skill's events.sh
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
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --help"
				;;
		esac
	done
}

# Lets the stop go ahead.
allow() {
	exit 0
}

# Records fault $1 as a fault.raised event of the effort; stderr while no
# effort is known or when the event can't be written.
log_fault() {
	if [ -z "${effort}" ]; then
		warn "fault: $1"
		return 0
	fi
	fault_what=$1
	fault_body="${work_dir}/fault.json"
	set -- --effort "${effort}" --by "${PROG}" --body-file "${fault_body}"
	[ -z "${session_id}" ] || set -- "$@" --session "${session_id}"
	[ -z "${stamp}" ] || set -- "$@" --iteration "${stamp}"
	if jq -nc --arg seat "${seat}" --arg agent "${agent_id}" --arg event "${event_id}" --arg what "${fault_what}" \
		'{seat: $seat, agent_id: $agent, hook_event: $event, what: $what}' >"${fault_body}" 2>/dev/null &&
		sh "${events_script}" fault "$@" >/dev/null 2>&1 </dev/null; then
		return 0
	fi
	warn "could not record the fault in ${effort}: fault: ${fault_what}"
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
	child_out=$("$@" 2>"${work_dir}/stderr" </dev/null) || child_rc=$?
}

# Logs "<label $1> exit <code>: <first stderr line>" for the last run and
# lets the stop go ahead.
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

# Lets the stop go ahead, naming the first missing tool, when one is not on
# PATH: a hook part way through a commit must not find it missing then.
check_tools() {
	need_tool jq 'jq 1.6+'
	need_tool git 'git 2.38+'
	need_tool cksum cksum
	command -v sha256sum >/dev/null 2>&1 || need_tool shasum 'sha256sum or shasum'
}

# Lets the stop go ahead when command $1 is not on PATH, expecting $2.
need_tool() {
	command -v "$1" >/dev/null 2>&1 && return 0
	warn "$1 not found; expected $2 on PATH; the stop goes ahead"
	allow
}

# Sets agent_id, session_id and event_id from the event on stdin; an event
# without a usable agent id is no effort agent's, so the stop goes ahead.
read_event() {
	cat >"${work_dir}/event" || {
		warn 'stdin could not be read; the stop goes ahead'
		allow
	}
	event_id=$(cksum <"${work_dir}/event" | cut -d ' ' -f 1) || event_id=''
	fields=$(jq -r 'if type == "object" then ((.agent_id | strings) // ""), ((.session_id | strings) // "") else empty end' \
		"${work_dir}/event" 2>/dev/null) || {
		warn 'stdin is not one JSON object; expected the SubagentStop event; the stop goes ahead'
		allow
	}
	agent_id='' session_id=''
	{
		IFS= read -r agent_id || :
		IFS= read -r session_id || :
	} <<EOF
${fields}
EOF
	case ${agent_id} in
		'') allow ;;
		*[!a-z0-9_-]*)
			shown_agent=$(printable "${agent_id}")
			warn "agent_id ${shown_agent} is not an id a seat holds; the stop goes ahead"
			allow
			;;
		*) ;;
	esac
	# events.sh checks the session; one it would refuse falls back to its own.
	case ${session_id} in
		*[!0-9a-f-]*) session_id='' ;;
		*) ;;
	esac
}

find_events_script() {
	events_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/events.sh"
	[ -f "${events_script}" ] || {
		warn "events.sh not found at ${events_script}; expected the ${CRUCIBLE_SKILL} skill installed; the stop goes ahead"
		allow
	}
}

# Sets effort and seat from events.sh find-agent; no seat holds the agent:
# the stop goes ahead.
find_seat() {
	run sh "${events_script}" find-agent --agent-id "${agent_id}"
	[ "${child_rc}" -eq 0 ] || {
		first_line=$(head -n 1 "${work_dir}/stderr" | cut -c "1-${MAX_QUOTE_BYTES}") || first_line=''
		shown_line=$(printable "${first_line}")
		warn "fault: events.sh find-agent exit ${child_rc}: ${shown_line}"
		allow
	}
	[ -n "${child_out}" ] || allow
	case ${child_out} in
		*"${tab}"*) ;;
		*) fault 'events.sh find-agent printed no effort and seat' ;;
	esac
	found_seat=${child_out#*"${tab}"}
	effort=${child_out%%"${tab}"*}
	case ${found_seat} in
		'' | *[!a-z0-9-]*)
			shown_seat=$(printable "${found_seat}")
			fault "events.sh find-agent printed seat ${shown_seat}; expected a seat name"
			;;
		*) seat=${found_seat} ;;
	esac
}

# Sets role, status, worktree, base, dispatch and bound_agent from seats.sh
# get.
read_seat() {
	run sh "${own_dir}/../seats/seats.sh" get --effort "${effort}" --seat "${seat}"
	[ "${child_rc}" -eq 0 ] || child_fault 'seats.sh get'
	fields=$(printf '%s\n' "${child_out}" |
		jq -r '.role // "", .status // "", .worktree // "", .base // "", .dispatch // "", .agent_id // ""') ||
		fault 'jq could not read the seat seats.sh get printed'
	# $( ) drops trailing empty lines, so a read past them finds the end: empty.
	role='' status='' worktree='' base='' dispatch='' bound_agent=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r worktree || :
		IFS= read -r base || :
		IFS= read -r dispatch || :
		IFS= read -r bound_agent || :
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

# Sets report, committing and iteration from iteration.sh, and stamp, the
# seat's current iteration.
read_iteration() {
	shown_worktree=$(printable "${worktree}")
	[ -n "${worktree}" ] && [ -d "${worktree}" ] || fault "seat ${seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	run sh "${own_dir}/../seats/iteration.sh" --effort "${effort}" --seat "${seat}"
	[ "${child_rc}" -eq 0 ] || child_fault 'iteration.sh'
	report=$(printf '%s\n' "${child_out}" | sed -n 's/^REPORT: //p')
	iteration=$(printf '%s\n' "${child_out}" | sed -n 's/^ITERATION: //p')
	[ -n "${report}" ] || fault 'iteration.sh printed no REPORT line'
	case ${iteration} in
		'' | *[!0-9]*)
			shown_iteration=$(printable "${iteration}")
			fault "iteration.sh printed ITERATION ${shown_iteration}; expected a whole number"
			;;
		*) ;;
	esac
	committing="${report%/*}/${COMMITTING_FILE}"
	current=$((iteration - 1))
	[ "${current}" -lt 1 ] || stamp="${seat}:${current}"
	shown_report=$(printable "${report}")
	# shellcheck disable=SC2310 # its status is the answer; it checks each step itself
	no_link_below "${effort}" "${report}" ||
		fault "the report draft ${shown_report} or a folder above it is a symbolic link; expected real files in the effort's drafts"
	# shellcheck disable=SC2310 # its status is the answer; it checks each step itself
	no_link_below "${effort}" "${committing}" ||
		fault "${shown_report%/*}/${COMMITTING_FILE} is a symbolic link; expected a real file or none"
}

# Succeeds when neither file $2 nor a folder between folder $1 and it is a
# symbolic link; else names the link on stderr. A missing level ends the
# walk: nothing below it exists. The hook runs outside the agent's permission
# prompts, so a link the agent planted must never carry a read or a move out.
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
			warn "${shown_link} is a symbolic link; nothing is read or moved through it"
			return 1
		fi
		[ -e "${level_path}" ] || return 0
	done
}

# Sets draft to the sha256 of the committing file.
hash_committing() {
	if command -v sha256sum >/dev/null 2>&1; then
		draft=$(sha256sum <"${committing}" 2>/dev/null | cut -d ' ' -f 1) || draft=''
	else
		draft=$(shasum -a 256 <"${committing}" 2>/dev/null | cut -d ' ' -f 1) || draft=''
	fi
	case ${draft} in
		*[!0-9a-f]* | '') fault "could not hash ${committing}; expected sha256sum or shasum on PATH" ;;
		*) ;;
	esac
	[ "${#draft}" -eq 64 ] || fault "the sha256 of ${committing} is not 64 hex digits"
}

# Sets events_json to every event of the effort, oldest first.
slurp_events() {
	run sh "${events_script}" slurp --effort "${effort}"
	[ "${child_rc}" -eq 0 ] || child_fault 'events.sh slurp'
	events_json=${child_out}
}

# Step 1: finishes or undoes what a run that died left in the committing file.
recover() {
	[ -f "${committing}" ] || return 0
	hash_committing
	slurp_events
	recorded=$(printf '%s\n' "${events_json}" | jq -r --arg draft "${draft}" \
		'[.[] | select(.type == "build.committed" and .draft == $draft)] | length') ||
		fault 'jq could not read the events events.sh slurp printed'
	if [ "${recorded}" -gt 0 ]; then
		rm -f -- "${committing}" || fault "could not remove ${committing}"
		return 0
	fi
	find_unrecorded_commit
	if [ -n "${unrecorded_commit}" ]; then
		record "${unrecorded_commit}"
		[ -f "${report}" ] || allow
		return 0
	fi
	if [ -f "${report}" ]; then
		rm -f -- "${committing}" || fault "could not remove ${committing}"
	else
		mv -f -- "${committing}" "${report}" || fault "could not move ${committing} back to ${report}"
	fi
}

# Sets unrecorded_commit to the newest crucible(build) commit of the seat on
# its branch that no event holds.
find_unrecorded_commit() {
	unrecorded_commit=''
	held=$(printf '%s\n' "${events_json}" |
		jq -r '.[] | select(.type == "build.committed") | .commit | strings') ||
		fault 'jq could not read the events events.sh slurp printed'
	range=HEAD
	[ -z "${base}" ] || range="${base}..HEAD"
	run git -c core.fsmonitor=false -C "${worktree}" log --topo-order \
		--format='%H%x09%s%x09%(trailers:key=Agent-Seat,valueonly,separator=%x2C)' "${range}"
	[ "${child_rc}" -eq 0 ] || child_fault 'git log'
	while IFS="${tab}" read -r commit_sha subject commit_seat; do
		[ "${commit_seat}" = "${seat}" ] || continue
		case ${subject} in
			'crucible(build): '*) ;;
			*) continue ;;
		esac
		case "${newline}${held}${newline}" in
			*"${newline}${commit_sha}${newline}"*) continue ;;
			*) ;;
		esac
		unrecorded_commit=${commit_sha}
		return 0
	done <<EOF
${child_out}
EOF
}

# Step 2: drops the report's empty keys, so an empty list costs the agent no
# block, then checks it.
check_report() {
	run sh "${pruner}" --report "${report}" --apply
	[ "${child_rc}" -eq 0 ] || child_fault "${PRUNER}"
	run sh "${checker}" --report "${report}" --worktree "${worktree}"
	case ${child_rc} in
		0) ;;
		3)
			checker_text=$(cat "${work_dir}/stderr" 2>/dev/null) || checker_text=''
			block_or_give_up "${BLOCK_LEAD}"
			;;
		*) child_fault "${CHECKER}" ;;
	esac
}

# Blocks while a change of a merge under way, an unmerged path included,
# still holds a leftover conflict marker: commit.sh would refuse it, and only
# the developer can resolve it. An unmerged path without one is resolved;
# commit.sh stages it.
check_merge_resolved() {
	run git -c core.fsmonitor=false -C "${worktree}" rev-parse --verify -q MERGE_HEAD
	[ "${child_rc}" -eq 0 ] || return 0
	# git diff --check exits 2 for any finding, whitespace included.
	run git -c core.fsmonitor=false -C "${worktree}" diff HEAD --check
	[ "${child_rc}" -le 2 ] || child_fault 'git diff --check'
	marked=$(printf '%s\n' "${child_out}" | sed -n 's/^\(.*\):[0-9][0-9]*: leftover conflict marker$/\1/p' | sort -u)
	[ -n "${marked}" ] || return 0
	joined=$(printf '%s\n' "${marked}" | head -n "${MAX_MARKED_NAMED}" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
	shown_paths=$(printable "${joined}")
	checker_text="These files still hold conflict markers: ${shown_paths}. Resolve each file, remove every marker, and keep the rest of your work; the stop hook commits the merge."
	block_or_give_up "${MERGE_BLOCK_LEAD}"
}

# Counts this misfit, checker_text saying what is wrong after lead $1;
# blocks the stop up to MAX_BLOCKS times, then gives up. The count is the stop.blocked events,
# so a block that can't be recorded is a fault and the stop goes ahead: the
# agent is never held uncounted.
block_or_give_up() {
	slurp_events
	blocks=$(printf '%s\n' "${events_json}" | jq -r --arg seat "${seat}" --arg agent "${agent_id}" "${BLOCKS_JQ}") ||
		fault 'jq could not count the blocks in the events events.sh slurp printed'
	blocks=$((blocks + 1))
	[ "${blocks}" -le "${MAX_BLOCKS}" ] || give_up
	reason="$1${newline}${checker_text}"
	decision=$(jq -nc --arg reason "${reason}" '{decision: "block", reason: $reason}') ||
		fault 'jq could not build the block decision'
	# shellcheck disable=SC2310 # its status is the answer; a failure is logged inside
	append_stop stop.blocked "${reason}" || fault 'could not record the stop.blocked event; the stop goes ahead unblocked'
	printf '%s\n' "${decision}"
	exit 0
}

# Records stop.gave-up before the seat leaves working: block-relay-hook.sh
# ends its wait once the seat is not working, and must find the event then.
give_up() {
	# shellcheck disable=SC2310 # its status is the answer; a failure is logged below
	append_stop stop.gave-up "${checker_text}" || log_fault 'could not record the stop.gave-up event; the seat gives up'
	run sh "${own_dir}/../seats/seats.sh" status --effort "${effort}" --seat "${seat}" --status gave-up
	[ "${child_rc}" -eq 0 ] || child_fault 'seats.sh status gave-up'
	allow
}

# Appends a stop event of type $1 with reason $2; fails when it is not written.
append_stop() {
	stop_body="${work_dir}/stop.json"
	jq -nc --arg seat "${seat}" --arg agent "${agent_id}" --arg event "${event_id}" \
		--argjson block "${blocks}" --arg reason "$2" \
		'{seat: $seat, agent_id: $agent, hook_event: $event, block: $block, reason: $reason}' >"${stop_body}" || return 1
	set -- --type "$1" --body-file "${stop_body}"
	[ -z "${stamp}" ] || set -- "$@" --iteration "${stamp}"
	append "$@"
	[ "${child_rc}" -eq 0 ] || {
		log_child_fault 'events.sh append'
		return 1
	}
}

# Runs events.sh append for the effort with "$@", waiting for the lock what
# is left of the hook's time but LOCK_MARGIN, at most MAX_LOCK_WAIT.
append() {
	elapsed
	lock_wait=$((HOOK_LIMIT - elapsed_seconds - LOCK_MARGIN))
	[ "${lock_wait}" -le "${MAX_LOCK_WAIT}" ] || lock_wait=${MAX_LOCK_WAIT}
	[ "${lock_wait}" -ge 1 ] || lock_wait=1
	set -- --effort "${effort}" --by "${PROG}" --wait "${lock_wait}" "$@"
	[ -z "${session_id}" ] || set -- "$@" --session "${session_id}"
	run sh "${events_script}" append "$@"
}

# Sets elapsed_seconds since the hook started; HOOK_LIMIT when the clock
# can't be read.
elapsed() {
	elapsed_seconds=${HOOK_LIMIT}
	now_seconds=$(date '+%s' 2>/dev/null) || now_seconds=''
	case ${started_seconds}:${now_seconds} in
		*[!0-9:]* | :* | *:) return 0 ;;
		*) ;;
	esac
	elapsed_seconds=$((now_seconds - started_seconds))
}

# Step 3: the checked report becomes the one being committed.
rename_report() {
	mv -f -- "${report}" "${committing}" || fault "could not rename ${report} to ${committing}"
	hash_committing
}

# Steps 4 and 5: commits the worktree's changes, pushes the commit when the
# effort asks for it; sets new_commit, empty when there was nothing to commit.
commit_work() {
	new_commit=''
	run git -c core.fsmonitor=false -C "${worktree}" status --porcelain --untracked-files=all --ignore-submodules=none
	[ "${child_rc}" -eq 0 ] || child_fault 'git status'
	if [ -z "${child_out}" ]; then
		run git -c core.fsmonitor=false -C "${worktree}" rev-parse --verify -q MERGE_HEAD
		[ "${child_rc}" -eq 0 ] || return 0
	fi
	read_settings
	run sh "${own_dir}/../../../procedure-git-worktree/scripts/commit/commit-input.sh" --effort "${effort}" --seat "${seat}" --report "${committing}" \
		--out "${work_dir}/message.json"
	[ "${child_rc}" -eq 0 ] || child_fault 'commit-input.sh'
	run sh "${own_dir}/../../../procedure-git-worktree/scripts/commit/commit-message.sh" --input "${work_dir}/message.json" --out "${work_dir}/message"
	[ "${child_rc}" -eq 0 ] || child_fault 'commit-message.sh'
	set -- --identity-name "${identity_name}" --identity-email "${identity_email}"
	[ -z "${signing_key}" ] || set -- "$@" --signing-format "${signing_format}" --signing-key "${signing_key}"
	run sh "${own_dir}/../../../procedure-git-worktree/scripts/commit/commit.sh" --worktree "${worktree}" --message-file "${work_dir}/message" "$@"
	case ${child_rc} in
		0)
			new_commit=$(printf '%s\n' "${child_out}" | tail -n 1)
			# The commit opened its iteration: what follows belongs to it.
			commit_stamp "${new_commit}"
			stamp=${event_stamp}
			log_unsigned
			[ "${auto_push}" != yes ] || push_branch
			;;
		5) ;;
		*) child_fault 'commit.sh' ;;
	esac
}

# Sets the identity_* variables, auto_push and remote from settings.sh get
# for the effort; no git setup is a fault.
read_settings() {
	run sh "${own_dir}/${SETTINGS}" get --effort "${effort}"
	[ "${child_rc}" -eq 0 ] || child_fault 'settings.sh get'
	identity_name='' identity_email='' signing_format='' signing_key='' auto_push='' remote=''
	while IFS= read -r setting; do
		case ${setting} in
			NAME=*) identity_name=${setting#NAME=} ;;
			EMAIL=*) identity_email=${setting#EMAIL=} ;;
			SIGNING_FORMAT=*) signing_format=${setting#SIGNING_FORMAT=} ;;
			SIGNING_KEY=*) signing_key=${setting#SIGNING_KEY=} ;;
			AUTO_PUSH=*) auto_push=${setting#AUTO_PUSH=} ;;
			REMOTE=*) remote=${setting#REMOTE=} ;;
			*) ;;
		esac
	done <<EOF
${child_out}
EOF
	[ -n "${identity_name}" ] && [ -n "${identity_email}" ] ||
		fault 'settings.sh get printed no NAME or EMAIL line; expected both'
}

# Logs commit.sh's UNSIGNED: line, when it made the commit unsigned.
log_unsigned() {
	unsigned_reason=$(sed -n 's/^UNSIGNED: //p' "${work_dir}/stderr" | head -n 1 | cut -c "1-${MAX_QUOTE_BYTES}") || unsigned_reason=''
	[ -z "${unsigned_reason}" ] || log_fault "commit.sh committed unsigned: ${unsigned_reason}"
}

# A failed or skipped push is logged and never blocks the stop; the next one
# carries this commit along.
push_branch() {
	elapsed
	push_seconds=$((HOOK_LIMIT - elapsed_seconds - PUSH_MARGIN))
	[ "${push_seconds}" -ge 0 ] || push_seconds=0
	if [ "${push_seconds}" -lt "${MIN_PUSH_SECONDS}" ]; then
		log_fault "push.sh skipped: ${push_seconds} s left of the hook's ${HOOK_LIMIT} s after a ${PUSH_MARGIN} s margin; expected at least ${MIN_PUSH_SECONDS} s"
		return 0
	fi
	set -- --worktree "${worktree}" --remote "${remote}" --effort "${effort}" --seat "${seat}" --timeout "${push_seconds}"
	[ -z "${session_id}" ] || set -- "$@" --session "${session_id}"
	run sh "${own_dir}/../../../procedure-git-worktree/scripts/push/push.sh" "$@"
	[ "${child_rc}" -eq 0 ] || log_child_fault 'push.sh'
}

# Step 6: records the committing file as the build.committed event of commit
# $1 (empty: none), then removes the file. A record that fails keeps the
# file, so the next run's recovery writes it.
record() {
	recorded_commit=$1
	[ -n "${draft}" ] || hash_committing
	event_stamp=${stamp}
	[ -z "${recorded_commit}" ] || commit_stamp "${recorded_commit}"
	facts=$(jq -nc --arg seat "${seat}" --arg dispatch "${dispatch}" --arg commit "${recorded_commit}" --arg draft "${draft}" \
		'{seat: $seat, dispatch: $dispatch, commit: (if $commit == "" then null else $commit end), draft: $draft}') ||
		fault 'jq could not build the event facts'
	set -- --type build.committed --body-file "${committing}" --facts "${facts}"
	[ -z "${event_stamp}" ] || set -- "$@" --iteration "${event_stamp}"
	append "$@"
	[ "${child_rc}" -eq 0 ] || child_fault 'events.sh append'
	rm -f -- "${committing}" || fault "could not remove ${committing} after recording it"
	[ -z "${recorded_commit}" ] || record_resolution "${recorded_commit}"
}

# Appends seat.conflicts.resolved when commit $1 is a merge of two parents;
# the conflicts are what git merge-tree finds between them. A failure is a
# fault: the build is recorded already.
record_resolution() {
	run git -c core.fsmonitor=false -C "${worktree}" show -s --no-show-signature --format='%P' "$1"
	[ "${child_rc}" -eq 0 ] || {
		log_child_fault 'git show'
		return 0
	}
	first_parent=${child_out%% *}
	second_parent=${child_out#* }
	case ${second_parent} in
		"${child_out}" | *' '*) return 0 ;;
		*) ;;
	esac
	merge_tree_rc=0
	git -c core.fsmonitor=false -C "${worktree}" merge-tree --write-tree --name-only --no-messages -z \
		"${first_parent}" "${second_parent}" >"${work_dir}/merge-tree" 2>"${work_dir}/stderr" </dev/null || merge_tree_rc=$?
	[ "${merge_tree_rc}" -le 1 ] || {
		child_rc=${merge_tree_rc}
		log_child_fault 'git merge-tree'
		return 0
	}
	resolution_body="${work_dir}/resolution.json"
	jq -Rs --arg seat "${seat}" --arg with "${second_parent}" --arg commit "$1" \
		'{seat: $seat, with: $with, conflicts: (split("\u0000")[1:] | map(select(. != ""))), commit: $commit}' \
		"${work_dir}/merge-tree" >"${resolution_body}" 2>/dev/null || {
		log_fault 'jq could not build the seat.conflicts.resolved body'
		return 0
	}
	set -- --type seat.conflicts.resolved --body-file "${resolution_body}"
	[ -z "${event_stamp}" ] || set -- "$@" --iteration "${event_stamp}"
	append "$@"
	[ "${child_rc}" -eq 0 ] || log_child_fault 'events.sh append seat.conflicts.resolved'
}

# Sets event_stamp from commit $1's Iteration and Agent-Seat trailers.
commit_stamp() {
	run git -c core.fsmonitor=false -C "${worktree}" log -1 \
		--format='%(trailers:key=Iteration,valueonly,separator=%x2C)%x09%(trailers:key=Agent-Seat,valueonly,separator=%x2C)' "$1"
	[ "${child_rc}" -eq 0 ] || child_fault 'git log'
	commit_iteration=${child_out%%"${tab}"*}
	commit_seat=${child_out#*"${tab}"}
	event_stamp="${commit_seat}:${commit_iteration}"
	case ${commit_iteration} in
		'' | 0* | *[!0-9]*) event_stamp='' ;;
		*) ;;
	esac
	case ${commit_seat} in
		'' | *[!a-z0-9-]*) event_stamp='' ;;
		*) ;;
	esac
	[ -z "${event_stamp}" ] || return 0
	shown_iteration=$(printable "${commit_iteration}")
	shown_seat=$(printable "${commit_seat}")
	log_fault "commit $1 has Iteration ${shown_iteration} and Agent-Seat ${shown_seat}; expected a number from 1 and a seat; the event has no iteration"
}

# An unexpected failure lets the stop go ahead too, logged.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	exit_status=$?
	if [ "${exit_status}" -ne 0 ] && [ "${usage_failed}" = no ] && [ -n "${work_dir}" ]; then
		log_fault "unexpected exit ${exit_status}"
	fi
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
	[ "${exit_status}" -ne 0 ] && [ "${usage_failed}" = no ] || return 0
	exit 0
}

started_seconds=$(date '+%s' 2>/dev/null) || started_seconds=''
work_dir='' usage_failed=no effort='' seat='' agent_id='' session_id='' event_id='' stamp='' draft=''
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_tools
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
find_events_script
find_seat
read_seat
[ "${role}" = developer ] || allow
[ "${bound_agent}" = "${agent_id}" ] || allow
# Only a working seat's stop is checked; nobody woke an idle or gave-up seat.
[ "${status}" = working ] || allow
find_checker
read_iteration
recover
check_report
check_merge_resolved
rename_report
commit_work
record "${new_commit}"
