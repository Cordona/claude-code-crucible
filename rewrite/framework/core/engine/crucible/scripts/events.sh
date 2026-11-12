#!/usr/bin/env sh
# The only writer of an effort's events: appends one event under the effort's
# lock, runs a read-then-write under it, writes a fault without it, and reads
# the events back.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='events.sh'
# Stamped into effort.opened; an effort of another format is refused, so a
# change to the event layout bumps it rather than misreading older efforts.
readonly FORMAT=1
# Event types taken after effort.completed or effort.dropped: a reopen, work
# that lands late, and the final harvest.
readonly AFTER_END_TYPES='effort.reopened build.committed test.committed metrics.harvested'
# An append holds the lock for a few jq runs, well under a second, so a wait
# this long means a stuck holder, not a busy one.
readonly DEFAULT_WAIT_SECONDS=5
# Zero-padded so name order is seq order; the [0-9] globs below match 6.
readonly SEQ_DIGITS=6
# Keeps a --max value inside the shell's integer range.
readonly MAX_ENTRIES_DIGITS=9
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: events.sh append --effort FOLDER --type TYPE --by NAME --body-file FILE
       [--facts JSON] [--iteration SEAT:N] [--guard FILE] [--session ID]
       [--wait N] [--locked]
       events.sh fault --effort FOLDER --by NAME --body-file FILE
       [--iteration SEAT:N] [--session ID]
       events.sh with-lock --effort FOLDER [--wait N] -- CMD [ARG...]
       events.sh list --effort FOLDER [--type PATTERN] [--max N]
       events.sh latest --effort FOLDER --type PATTERN [--where JQ]
       events.sh slurp --effort FOLDER [--type PATTERN] [--faults] [--max N]
       events.sh find-agent --agent-id ID
       events.sh --help | -h

The only writer of an effort's events and faults; reads them too.
Events: <effort>/events/<seq>-<type>.json, one JSON object each, written
once. seq is ${SEQ_DIGITS} digits from 000001, no gaps.
Appends to an effort are serialised; a dead holder never blocks.
append and fault leave only their file and its folder, the lock only
while held; readers write nothing. A refused --type, --by, --body-file,
--facts, --iteration or event, or a lock timeout, writes only its fault, by
design (none for a bad --effort): body {"refused": PATH, "rule": RULE},
never the input, kept in <effort>/events/faults/ as the rejection log, for
audit, read by no script. Nothing else is left behind (a SIGKILL aside).

TYPE: subject[.qualifier].past-verb, parts of a-z, 0-9 and -. PATTERN: a sh
glob over TYPE.

append  writes {type, seq, at, by, claude_session_id, iteration?, <facts>,
  body}, refusing a first event but effort.opened with body.format ${FORMAT}, a
  second effort.opened, after effort.completed or effort.dropped any type but
  ${AFTER_END_TYPES}.
  stdout: its absolute path.
fault   writes a fault.raised event; a stuck lock never stops it.
  stdout: its absolute path.
with-lock  runs CMD holding the lock; exit: CMD's.
list    stdout: each event's absolute path, in seq order.
latest  stdout: the absolute path of the newest PATTERN event where JQ is
  true; nothing when none.
slurp   stdout: one JSON array of the events in seq order.
find-agent  stdout: "<effort folder><TAB><seat>" (folder absolute) of agent
  ID's newest seat.bound in any effort; nothing when none.

Options:
  --effort FOLDER   an effort folder directly in <root>/efforts/, absolute
  --type TYPE       append: the new event's type
  --type PATTERN    list, latest, slurp: the types (default all)
  --by NAME         the writing script's name
  --body-file FILE  a JSON object, the event's body
  --facts JSON      a JSON object of top-level keys beside body
  --iteration SEAT:N  stamps {"seat": SEAT, "number": N}
  --guard FILE      jq over {events: [every event], event: the new one};
                    each string it prints refuses
  --session ID      Claude Code's session (default CLAUDE_CODE_SESSION_ID)
  --wait N          lock wait in seconds (default ${DEFAULT_WAIT_SECONDS})
  --locked          inside with-lock: the lock is held
  --where JQ        a jq filter per event (default true)
  --faults          slurp: faults too, all ordered by at
  --max N           list, slurp: at most N (default 0, all); stderr notes a cut
  --agent-id ID     Claude Code's agent id
  CRUCIBLE_HOME     the space root <root> (default \$HOME/.crucible):
                    absolute, not / and not a symbolic link
  CLAUDE_CONFIG_DIR  holds the session transcript (default \$HOME/.claude)

Exit codes:
  0  done; go on
  2  usage error; fix what stderr names, else show the human stderr, and stop
  3  refused; pass it on, else show the human stderr, and stop
  4  space fault; show the human stderr, and stop
  5  install fault; show the human stderr, and stop
  6  lock busy; pass it on, else show the human stderr, and stop
  129, 130, 143  stopped by HUP, INT or TERM; show the human stderr, and stop
  other  unexpected; show the human the exit code and stderr, and stop

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the
distro's jq), lib/crucible-space.sh beside it; cat, chmod, date,
kill, ln, mkdir, mv, od, readlink, rm, sed, sleep, tr, /dev/urandom.
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

refuse() {
	warn "refused: $1"
	exit 3
}

space_fault() {
	warn "space: $1"
	exit 4
}

install_fault() {
	warn "install: $1"
	exit 5
}

# Exits 2 for input field $1, which breaks rule $2, recording it as a fault;
# $3 is the message.
reject_field() {
	record_refusal "$1" "$2"
	usage_error "$3"
}

# Exits 3 for the event, refused at field $1 by rule $2, recording it as a
# fault; $3 is the message.
refuse_field() {
	record_refusal "$1" "$2"
	refuse "$3"
}

# Writes field $1 and rule $2 as a fault of the effort, never the input
# itself; does nothing until the effort and session are checked.
record_refusal() {
	[ -n "${faults_dir}" ] || return 0
	# The subshell keeps a failed fault write from replacing the refusal's
	# exit; each step of write_fault checks its own status.
	# shellcheck disable=SC2310 # set -e is not relied on inside write_fault
	jq -n --arg refused "$1" --arg rule "$2" '{refused: $refused, rule: $rule}' |
		(write_fault "${PROG}" null >/dev/null) || warn 'the refusal below was not written as a fault'
}

# Removes this run's temp file and lets go of the lock if this run holds it.
clean_up() {
	[ -z "${temp}" ] || rm -f "${temp}"
	[ -z "${lock}" ] || release_lock
}

main() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	command=$1
	shift
	case ${command} in
		--help | -h)
			usage
			exit 0
			;;
		append | fault | with-lock | list | latest | slurp | find-agent) ;;
		*) usage_error "unknown command: ${command}; expected append, fault, with-lock, list, latest, slurp, find-agent or --help" ;;
	esac
	load_space_lib
	check_jq
	# shellcheck disable=SC2310 # its status says whether the root is usable
	crucible_resolve_root || space_fault "${crucible_root_problem}"
	temp='' lock='' faults_dir=''
	trap 'clean_up' EXIT
	trap 'clean_up; exit 129' HUP
	trap 'clean_up; exit 130' INT
	trap 'clean_up; exit 143' TERM
	case ${command} in
		append) run_append "$@" ;;
		fault) run_fault "$@" ;;
		with-lock) run_with_lock "$@" ;;
		list) run_list "$@" ;;
		latest) run_latest "$@" ;;
		slurp) run_slurp "$@" ;;
		*) run_find_agent "$@" ;;
	esac
}

load_space_lib() {
	case $0 in
		*/*) space_lib="${0%/*}/lib/crucible-space.sh" ;;
		*) space_lib='./lib/crucible-space.sh' ;;
	esac
	[ -f "${space_lib}" ] && [ -r "${space_lib}" ] ||
		install_fault "space rules missing; expected ${space_lib}; try reinstalling the crucible skill"
	# shellcheck source=lib/crucible-space.sh
	. "${space_lib}"
}

check_jq() {
	command -v jq >/dev/null 2>&1 || install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || install_fault 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) install_fault "jq is ${jq_version}; expected jq 1.6+; try upgrading jq" ;;
	esac
}

require_value() {
	[ "$2" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
}

# Sets effort and events_dir once --effort names a real effort folder.
check_effort() {
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort FOLDER, an effort folder of the space'
	# shellcheck disable=SC2310 # its status says whether the folder passed
	if ! crucible_check_effort_folder "${effort}"; then
		[ "${crucible_effort_fault}" = space ] || usage_error "${crucible_effort_refusal}"
		space_fault "${crucible_effort_refusal}"
	fi
	effort=${crucible_effort}
	events_dir="${effort}/events"
	lock="${effort}/.events.lock"
}

check_type() {
	[ -n "${type}" ] || reject_field type 'given' '--type missing; expected subject[.qualifier].past-verb'
	case ${type} in
		*[!abcdefghijklmnopqrstuvwxyz0123456789.-]* | .* | *. | *..* | -* | *.-* | *-.* | *-) reject_field type 'each part lowercase a-z, 0-9 and -' "bad --type: ${type}; expected subject[.qualifier].past-verb, each part lowercase a-z, 0-9 and -" ;;
		*.*.*.*) reject_field type 'at most three parts' "bad --type: ${type}; expected at most three parts" ;;
		*.*) ;;
		*) reject_field type 'at least subject.past-verb' "bad --type: ${type}; expected subject.past-verb" ;;
	esac
}

check_by() {
	case ${by} in
		'' | *[!abcdefghijklmnopqrstuvwxyz0123456789._-]*) reject_field by 'a script name of a-z, 0-9, ., _ and -' "bad --by: '${by}'; expected the writing script's name, e.g. seats.sh" ;;
		*) ;;
	esac
}

check_session() {
	if [ -n "${session}" ]; then
		# shellcheck disable=SC2310 # a pure test
		crucible_session_is_uuid "${session}" || usage_error 'bad --session: expected a lowercase UUID, the Claude Code session ID'
		return 0
	fi
	# shellcheck disable=SC2310 # its status says whether the session is real
	crucible_check_session || usage_error "${crucible_session_problem}"
	session=${crucible_session_id}
}

check_body() {
	[ -n "${body_file}" ] || reject_field body 'given' '--body-file missing; expected a file holding a JSON object'
	[ -f "${body_file}" ] && [ -r "${body_file}" ] ||
		reject_field body 'a readable file' "--body-file ${body_file}: not a readable file; expected a readable file holding one JSON object; try checking the path"
	jq -e 'type == "object"' "${body_file}" >/dev/null 2>&1 </dev/null ||
		reject_field body 'one JSON object' "--body-file ${body_file}: not one JSON object; expected one JSON object, the event's body"
}

check_facts() {
	[ -n "${facts}" ] || facts='{}'
	printf '%s' "${facts}" | jq -e 'type == "object"' >/dev/null 2>&1 ||
		reject_field facts 'one JSON object' '--facts: not a JSON object; expected one JSON object'
	envelope_key=$(printf '%s' "${facts}" | jq -r '[keys_unsorted[] | select(IN("type", "seq", "at", "by", "claude_session_id", "iteration", "body"))] | first // empty') ||
		reject_field facts 'one JSON object' '--facts: not a JSON object; expected one JSON object'
	# envelope_key is one of the fixed names above, never caller text.
	[ -z "${envelope_key}" ] ||
		reject_field "facts.${envelope_key}" 'no envelope key' "--facts: key ${envelope_key} is an envelope key; expected none of type, seq, at, by, claude_session_id, iteration, body"
}

# Sets iteration_json from --iteration SEAT:N.
check_iteration() {
	iteration_json=null
	[ -n "${iteration}" ] || return 0
	iteration_seat=${iteration%:*}
	iteration_number=${iteration##*:}
	case ${iteration_seat}:${iteration_number} in
		*[!abcdefghijklmnopqrstuvwxyz0123456789:-]* | :* | *:) reject_field iteration 'SEAT:N, SEAT of a-z, 0-9 and -' "bad --iteration: ${iteration}; expected SEAT:N" ;;
		*) ;;
	esac
	case ${iteration_number} in
		'' | *[!0123456789]* | 0*) reject_field iteration 'N a whole number from 1' "bad --iteration: ${iteration}; expected N a whole number from 1" ;;
		*) ;;
	esac
	iteration_json="{\"seat\":\"${iteration_seat}\",\"number\":${iteration_number}}"
}

check_wait() {
	case ${wait_seconds} in
		'' | *[!0123456789]*) usage_error "bad --wait: ${wait_seconds}; expected whole seconds" ;;
		*) ;;
	esac
}

now_utc() {
	date -u +%Y-%m-%dT%H:%M:%SZ
}

# 3 bytes, 6 hex digits: with the PID and the second, enough that two
# writers never pick one name.
random_hex() {
	od -An -N3 -tx1 /dev/urandom | tr -d ' \n'
}

run_append() {
	effort='' type='' by='' body_file='' facts='' iteration='' guard='' session='' wait_seconds=${DEFAULT_WAIT_SECONDS} locked=no
	while [ "$#" -gt 0 ]; do
		case $1 in
			--locked)
				locked=yes
				shift
				continue
				;;
			--effort | --type | --by | --body-file | --facts | --iteration | --guard | --session | --wait) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for append: $1; expected --effort, --type, --by, --body-file, --facts, --iteration, --guard, --session, --wait or --locked" ;;
		esac
		case $1 in
			--effort) effort=$2 ;;
			--type) type=$2 ;;
			--by) by=$2 ;;
			--body-file) body_file=$2 ;;
			--facts) facts=$2 ;;
			--iteration) iteration=$2 ;;
			--guard) guard=$2 ;;
			--session) session=$2 ;;
			*) wait_seconds=$2 ;;
		esac
		shift 2
	done
	check_effort
	check_session
	faults_dir="${events_dir}/faults"
	check_type
	check_by
	check_body
	check_facts
	check_iteration
	check_wait
	[ -z "${guard}" ] || [ -f "${guard}" ] || usage_error "--guard ${guard}: not a file; expected a jq program file; try checking the path"
	if [ "${locked}" = yes ]; then
		check_held_lock
		append_locked
	else
		take_lock
		append_locked
		release_lock
	fi
	printf '%s\n' "${event_file}"
}

# Writes the event; the lock is held. Sets event_file.
append_locked() {
	if [ ! -d "${events_dir}" ]; then
		[ "${type}" = effort.opened ] || refuse_field type 'effort.opened first' "${effort} has no events; expected effort.opened first; try effort.sh start"
		mkdir "${events_dir}" 2>/dev/null || [ -d "${events_dir}" ] || space_fault "cannot create ${events_dir}; expected a writable effort folder; try checking its permissions"
	fi
	[ ! -L "${events_dir}" ] || space_fault "${events_dir} is a symbolic link; expected a real folder; try replacing the link with a real folder"
	clean_dead_temps
	set_last_seq
	check_format_and_end
	seq=$((last_seq + 1))
	seq_name=$(printf "%0${SEQ_DIGITS}d" "${seq}")
	event_file="${events_dir}/${seq_name}-${type}.json"
	temp="${events_dir}/.tmp-$$-$(random_hex)"
	at=$(now_utc)
	jq -c --arg type "${type}" --argjson seq "${seq}" --arg at "${at}" --arg by "${by}" \
		--arg session "${session}" --argjson iteration "${iteration_json}" --argjson facts "${facts}" \
		'{type: $type, seq: $seq, at: $at, by: $by, claude_session_id: $session}
		+ (if $iteration == null then {} else {iteration: $iteration} end)
		+ $facts + {body: .}' "${body_file}" </dev/null >"${temp}" || {
		rm -f "${temp}"
		space_fault "cannot write ${temp}; expected a writable ${events_dir}; try checking its permissions"
	}
	run_guard
	chmod 0444 "${temp}" || {
		rm -f "${temp}"
		space_fault "cannot set ${temp} read-only; expected a file this run owns; try checking ${events_dir}"
	}
	# ln into an existing folder would link inside it.
	[ ! -e "${event_file}" ] && [ ! -L "${event_file}" ] || {
		rm -f "${temp}"
		space_fault "${event_file} exists but is no event file; expected a free name; try moving it out of ${events_dir}"
	}
	ln "${temp}" "${event_file}" 2>/dev/null || {
		rm -f "${temp}"
		space_fault "cannot link ${event_file}; expected a new name; try again"
	}
	rm -f "${temp}"
}

# Sets last_seq and first_file from the highest and lowest event names.
set_last_seq() {
	last_seq=0 first_file=''
	for named in "${events_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9]-*.json; do
		[ -f "${named}" ] || continue
		[ -n "${first_file}" ] || first_file=${named}
		last_name=${named##*/}
		last_name=${last_name%%-*}
		while [ "${last_name}" != "${last_name#0}" ] && [ "${#last_name}" -gt 1 ]; do last_name=${last_name#0}; done
		last_seq=${last_name}
	done
}

# Refuses an event the format stamp or the effort's end does not allow.
check_format_and_end() {
	if [ "${last_seq}" -eq 0 ]; then
		[ "${type}" = effort.opened ] || refuse_field type 'effort.opened first' "${effort} has no events; expected effort.opened first; try effort.sh start"
		jq -e --argjson format "${FORMAT}" '.format == $format' "${body_file}" >/dev/null 2>&1 </dev/null ||
			refuse_field body.format "format ${FORMAT}" "effort.opened lacks body.format ${FORMAT}; expected a body with \"format\": ${FORMAT}"
		return 0
	fi
	[ "${type}" != effort.opened ] || refuse_field type 'effort.opened only once' "${effort} is open already; expected effort.opened only once; try the effort's next event type, not effort.opened"
	jq -e --argjson format "${FORMAT}" '.type == "effort.opened" and .body.format == $format' "${first_file}" >/dev/null 2>&1 </dev/null ||
		refuse_field effort "format ${FORMAT}" "${effort} is not format ${FORMAT}; expected events this version of Crucible wrote; try starting a new effort"
	last_effort_type=''
	for named in "${events_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9]-effort.*.json; do
		[ -f "${named}" ] || continue
		last_effort_type=${named##*/}
		last_effort_type=${last_effort_type#*-}
		last_effort_type=${last_effort_type%.json}
	done
	case ${last_effort_type} in
		effort.completed | effort.dropped) ;;
		*) return 0 ;;
	esac
	for allowed in ${AFTER_END_TYPES}; do
		[ "${type}" != "${allowed}" ] || return 0
	done
	refuse_field type 'effort.reopened first' "${effort} has ended (${last_effort_type}); expected effort.reopened before ${type}"
}

# Runs --guard over every event and the new one; any line it prints refuses.
run_guard() {
	[ -n "${guard}" ] || return 0
	guard_dir=${guard%/*}
	[ "${guard_dir}" != "${guard}" ] || guard_dir=.
	# shellcheck disable=SC2310 # its status says whether the events were read
	guard_input=$(slurp_files) || {
		rm -f "${temp}"
		space_fault "cannot read the events in ${events_dir}; expected readable event files; try checking its permissions"
	}
	if ! refusals=$(printf '%s' "${guard_input}" | jq -r -L "${guard_dir}" -f "${guard}" 2>&1); then
		rm -f "${temp}"
		install_fault "the guard ${guard} failed: ${refusals%%
*}; expected a jq program that runs over {events, event}; try fixing the guard file"
	fi
	[ -n "${refusals}" ] || return 0
	rm -f "${temp}"
	record_refusal event "the guard ${guard##*/}"
	refuse "${refusals%%
*}"
}

# Prints {events: [...], event: <new>} for the guard; reads $temp.
slurp_files() {
	set -- "${events_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9]-*.json
	if [ -f "$1" ]; then
		jq -s --slurpfile new "${temp}" '{events: ., event: $new[0]}' "$@" </dev/null
	else
		jq -n --slurpfile new "${temp}" '{events: [], event: $new[0]}' </dev/null
	fi
}

# Removes temp files of writers that are gone, faults' too; the lock is held.
clean_dead_temps() {
	for stale in "${events_dir}"/.tmp-* "${events_dir}"/faults/.tmp-*; do
		[ -f "${stale}" ] || continue
		stale_pid=${stale##*/.tmp-}
		stale_pid=${stale_pid%%-*}
		[ "${stale_pid}" != "$$" ] || continue
		kill -0 "${stale_pid}" 2>/dev/null || rm -f "${stale}"
	done
}

# Takes the lock within wait_seconds, breaking it when its holder is dead.
take_lock() {
	deadline=$(($(date +%s) + wait_seconds))
	while :; do
		ln -s "$$" "${lock}" 2>/dev/null && return 0
		holder=$(readlink "${lock}" 2>/dev/null) || holder=''
		if [ -n "${holder}" ] && ! kill -0 "${holder}" 2>/dev/null; then
			# Only one waiter's rename of the dead link succeeds.
			broken="${effort}/.events.lock.broken-$$-$(random_hex)"
			mv "${lock}" "${broken}" 2>/dev/null && rm -f "${broken}"
			continue
		fi
		now_seconds=$(date +%s)
		[ "${now_seconds}" -lt "${deadline}" ] || {
			record_lock_timeout
			warn "lock: ${lock} held by PID ${holder:-unknown} past ${wait_seconds}s; expected it free; try again once that holder has ended"
			exit 6
		}
		# A tenth of a second is short beside an append's hold; a POSIX sleep
		# that takes whole seconds only falls back to 1.
		sleep 0.1 2>/dev/null || sleep 1
	done
}

# Records the timed-out wait as a fault; write_fault takes no lock, so this
# cannot wait on the lock again.
record_lock_timeout() {
	faults_dir="${events_dir}/faults"
	# shellcheck disable=SC2310 # its status says whether a session is known
	if [ -z "${session}" ] && crucible_check_session; then
		session=${crucible_session_id}
	fi
	record_refusal lock 'held past --wait'
}

release_lock() {
	holder=$(readlink "${lock}" 2>/dev/null) || return 0
	[ "${holder}" != "$$" ] || rm -f "${lock}"
}

# Checks that the lock is held by the with-lock run above this one.
check_held_lock() {
	holder=$(readlink "${lock}" 2>/dev/null) || holder=''
	[ -n "${holder}" ] && [ "${holder}" = "${CRUCIBLE_EVENTS_LOCK_HOLDER:-}" ] ||
		usage_error "--locked outside with-lock for ${effort}; expected events.sh with-lock --effort ${effort} -- ..."
}

run_with_lock() {
	effort='' session='' wait_seconds=${DEFAULT_WAIT_SECONDS}
	while [ "$#" -gt 0 ]; do
		case $1 in
			--)
				shift
				break
				;;
			--effort | --wait) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for with-lock: $1; expected --effort, --wait, then -- CMD" ;;
		esac
		case $1 in
			--effort) effort=$2 ;;
			*) wait_seconds=$2 ;;
		esac
		shift 2
	done
	[ "$#" -gt 0 ] || usage_error 'with-lock needs a command after --; expected events.sh with-lock --effort FOLDER -- CMD [ARG...]'
	check_effort
	check_wait
	take_lock
	cmd_status=0
	CRUCIBLE_EVENTS_LOCK_HOLDER=$$ "$@" || cmd_status=$?
	release_lock
	exit "${cmd_status}"
}

run_fault() {
	effort='' by='' body_file='' iteration='' session=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--effort | --by | --body-file | --iteration | --session) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for fault: $1; expected --effort, --by, --body-file, --iteration or --session" ;;
		esac
		case $1 in
			--effort) effort=$2 ;;
			--by) by=$2 ;;
			--body-file) body_file=$2 ;;
			--iteration) iteration=$2 ;;
			*) session=$2 ;;
		esac
		shift 2
	done
	check_effort
	check_session
	faults_dir="${events_dir}/faults"
	check_by
	check_body
	check_iteration
	write_fault "${by}" "${iteration_json}" <"${body_file}"
}

# Writes stdin's JSON object as the body of a fault.raised event in
# faults_dir, by $1 with iteration JSON $2, and prints its path; takes no lock.
write_fault() {
	mkdir -p "${faults_dir}" 2>/dev/null || space_fault "cannot create ${faults_dir}; expected a writable effort folder; try checking its permissions"
	at=$(now_utc)
	stamp=$(date -u +%Y%m%dT%H%M%SZ)
	fault_file="${faults_dir}/${stamp}-$$-$(random_hex).json"
	temp="${faults_dir}/.tmp-$$-$(random_hex)"
	jq -c --arg at "${at}" --arg by "$1" --arg session "${session}" --argjson iteration "$2" \
		'{type: "fault.raised", at: $at, by: $by, claude_session_id: $session}
		+ (if $iteration == null then {} else {iteration: $iteration} end) + {body: .}' >"${temp}" || {
		rm -f "${temp}"
		space_fault "cannot write ${temp}; expected a writable ${faults_dir}; try checking its permissions"
	}
	chmod 0444 "${temp}" || {
		rm -f "${temp}"
		space_fault "cannot set ${temp} read-only; expected a file this run owns; try checking ${faults_dir}"
	}
	ln "${temp}" "${fault_file}" 2>/dev/null || {
		rm -f "${temp}"
		space_fault "cannot link ${fault_file}; expected a new name; try again"
	}
	rm -f "${temp}"
	printf '%s\n' "${fault_file}"
}

# Parses --effort and --type for the readers.
parse_read_args() {
	effort='' type_pattern='*' where='true' with_faults=no max_entries=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			--faults)
				with_faults=yes
				shift
				continue
				;;
			--effort | --type | --where | --max) require_value "$1" "$#" ;;
			*) usage_error "unknown argument: $1; expected --effort, --type, --where, --faults or --max" ;;
		esac
		case $1 in
			--effort) effort=$2 ;;
			--type) type_pattern=$2 ;;
			--max) max_entries=$2 ;;
			*) where=$2 ;;
		esac
		shift 2
	done
	case ${max_entries} in
		0) ;;
		'' | *[!0123456789]* | 0*) usage_error "bad --max: ${max_entries}; expected a whole number, 0 for all" ;;
		*) ;;
	esac
	[ "${#max_entries}" -le "${MAX_ENTRIES_DIGITS}" ] ||
		usage_error "bad --max: ${max_entries}; expected at most ${MAX_ENTRIES_DIGITS} digits"
	check_effort
	[ -f "${events_dir}/000001-effort.opened.json" ] ||
		space_fault "${effort} has no events/000001-effort.opened.json; expected an effort this version of Crucible started; an effort from before events cannot be used; try starting a new effort with effort.sh start"
}

# Prints the path of each event of type_pattern, in seq order.
print_event_files() {
	for named in "${events_dir}"/[0-9][0-9][0-9][0-9][0-9][0-9]-*.json; do
		[ -f "${named}" ] || continue
		named_type=${named##*/}
		named_type=${named_type#*-}
		named_type=${named_type%.json}
		# shellcheck disable=SC2254 # the pattern is the caller's glob
		case ${named_type} in
			${type_pattern}) printf '%s\n' "${named}" ;;
			*) ;;
		esac
	done
}

run_list() {
	parse_read_args "$@"
	listed=0 total=0 candidates=$(print_event_files)
	while IFS= read -r named; do
		[ -n "${named}" ] || continue
		total=$((total + 1))
		if [ "${max_entries}" -eq 0 ] || [ "${total}" -le "${max_entries}" ]; then
			printf '%s\n' "${named}"
			listed=${total}
		fi
	done <<EOF
${candidates}
EOF
	warn_cut "${listed}" "${total}"
}

# Says on stderr that --max cut the output: $1 shown of $2.
warn_cut() {
	[ "$1" -eq "$2" ] || warn "showing $1 of $2"
}

run_latest() {
	parse_read_args "$@"
	[ "${type_pattern}" != '*' ] || usage_error "latest needs --type PATTERN; expected a sh glob over TYPE, e.g. 'seat.*'"
	check_where
	found='' candidates=$(print_event_files)
	while IFS= read -r candidate; do
		[ -n "${candidate}" ] || continue
		where_status=0
		jq -e "${where}" "${candidate}" >/dev/null 2>&1 </dev/null || where_status=$?
		# jq -e exits 1 on false and 4 on null or no output: no match.
		case ${where_status} in
			0) found=${candidate} ;;
			1 | 4) ;;
			*) space_fault "cannot read ${candidate}; expected one JSON event; try checking that file, then rerun" ;;
		esac
	done <<EOF
${candidates}
EOF
	[ -z "${found}" ] || printf '%s\n' "${found}"
}

# A --where jq cannot compile is the caller's error, caught before any event.
check_where() {
	where_status=0
	jq -n "${where}" >/dev/null 2>&1 </dev/null || where_status=$?
	[ "${where_status}" -ne 3 ] ||
		usage_error "bad --where: ${where}; expected a jq filter, e.g. '.body.seat == \"x\"'"
}

run_slurp() {
	parse_read_args "$@"
	files=$(print_event_files)
	fault_files=''
	if [ "${with_faults}" = yes ] && [ -d "${events_dir}/faults" ]; then
		fault_files=$(for f in "${events_dir}"/faults/*.json; do [ -f "${f}" ] && printf '%s\n' "${f}"; done)
	fi
	all=$(printf '%s\n%s\n' "${files}" "${fault_files}" | sed '/^$/d')
	if [ -z "${all}" ]; then
		printf '[]\n'
		return 0
	fi
	set --
	while IFS= read -r slurped; do
		[ -z "${slurped}" ] || set -- "$@" "${slurped}"
	done <<EOF
${all}
EOF
	order='.'
	[ "${with_faults}" = no ] || order='sort_by(.at, (.seq // 0))'
	shown=$#
	[ "${max_entries}" -eq 0 ] || [ "$#" -le "${max_entries}" ] || shown=${max_entries}
	jq -cs --argjson shown "${shown}" "${order} | .[:\$shown]" "$@" </dev/null
	warn_cut "${shown}" "$#"
}

run_find_agent() {
	agent_id=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--agent-id) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for find-agent: $1; expected --agent-id ID" ;;
		esac
		agent_id=$2
		shift 2
	done
	case ${agent_id} in
		'' | *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) usage_error 'bad --agent-id; expected the agent id Claude Code gave' ;;
		*) ;;
	esac
	found_effort='' found_seat=''
	for bound in "${crucible_root}"/efforts/*/events/[0-9][0-9][0-9][0-9][0-9][0-9]-seat.bound.json; do
		[ -f "${bound}" ] || continue
		line=$(jq -r --arg id "${agent_id}" 'select(.body.agent_id == $id) | "\(.at)\t\(.body.seat)"' "${bound}" </dev/null 2>/dev/null) ||
			space_fault "cannot read ${bound}; expected one JSON event; try checking that file, then rerun"
		[ -n "${line}" ] || continue
		# An agent id is bound in one effort; a later bind of it there is newer.
		found_seat=${line#*"	"}
		found_effort=${bound%/events/*}
	done
	[ -z "${found_effort}" ] || printf '%s\t%s\n' "${found_effort}" "${found_seat}"
}

main "$@"
