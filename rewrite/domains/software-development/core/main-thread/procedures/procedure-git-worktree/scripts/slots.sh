#!/usr/bin/env sh
# The only writer of an effort's slots.json, the seat list hooks and scripts
# route work by. One command per change, under a mkdir lock beside the file.
# The shell checks the command line and the path; slots.jq checks the options
# and the file, applies the change and checks the result, so the shell never
# edits JSON. Every written file goes through crucible's prune, so a key with
# nothing in it is left out. A change goes in place through a temp file beside
# it, so the file is whole or unchanged, and get, find and busy read it without
# the lock.
set -eu
umask 077

readonly PROG='slots.sh'
readonly MODULE='slots'
readonly CRUCIBLE_SKILL='crucible'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
readonly LOCK_WAIT_SECONDS=10
readonly LOCK_POLL_SECONDS=0.2
readonly COMMANDS='add bind status handover get find busy'
# The C locale keeps the shell byte-wise; jq writes the file as UTF-8.
LC_ALL=C
export LC_ALL

# Prints {exit, problems, file, out}: the exit code, the problem lines (at
# most $max), the new file (null when nothing is written) and the stdout text.
# The new file is pruned, then checked against the contract.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly RUN_JQ='include "slots";
include "prune";
{slot: $slot, role: $role, worktree: $worktree, repo: $repo, base: $base, lens: $lens,
	"agent-id": $agent_id, dispatch: $dispatch, status: $status, "awaiting-round": $awaiting_round} as $given
| slots_run($command; $given | with_entries(select(.value != "")); $effort; if $exists == "yes" then $current else null end)
| .file |= prune
| slots_checked
| .problems |= (if length > $max then .[:$max - 1] + ["\(length - $max + 1) more problems not shown; expected none"] else . end)'

usage() {
	cat <<EOF
usage: sh ${PROG} add --slots FILE --slot S --role developer|tester --worktree DIR --repo DIR --base SHA
       sh ${PROG} add --slots FILE --slot S --role reviewer --lens L
       sh ${PROG} bind --slots FILE --slot S --agent-id ID --dispatch ID
       sh ${PROG} status --slots FILE --slot S --status working|idle|gave-up [--awaiting-round N|none]
       sh ${PROG} handover --slots FILE --slot S
       sh ${PROG} get --slots FILE --slot S
       sh ${PROG} find --slots FILE --agent-id ID
       sh ${PROG} busy --slots FILE
       sh ${PROG} --help | -h

Keeps an effort's seat list. Each change runs under the lock FILE.lock,
waiting at most ${LOCK_WAIT_SECONDS}s, and is written only when the whole file fits the
contract; a file that already fails it is refused, never repaired. A key
with nothing in it is left out: no value is null, [] or {}.

--slots FILE  absolute path of slots.json; its folder must exist and its
              name is the effort id written when add creates the file

add       a new seat: status open, no agent; a developer or tester
          gets mode BUILD or TEST. A tester's --worktree may be a
          developer's; this only records the sharing: seat-open.sh does
          not open a tester seat yet.
bind      seats an agent and its dispatch on an open seat: status working;
          the same agent and dispatch again changes nothing; refused for
          an agent handed out of the seat
status    sets working, idle or gave-up on a bound seat, and awaiting_round
          when --awaiting-round is given (a developer or tester only; none
          removes it)
handover  frees a bound seat: the agent moves to the end of
          previous_agent_ids, agent_id and dispatch go, status open
get       prints the seat as one line of JSON
find      prints, like get, the seat whose agent_id is ID
busy      prints "slot<TAB>status<TAB>awaiting_round" per seat that is open,
          working or awaits a round (none when it awaits none)

the file: {"effort": string, "slots": [slot, ...]}, slot names unique
  every slot   slot (a lowercase word, a dash, a number of 1 or more, like
               dev-1), role, status (open, working, idle or gave-up),
               agent_id and dispatch (letters, digits, _ and -; absent when
               open, present otherwise), previous_agent_ids (optional: agent
               ids handed out of the seat, oldest first, no repeats)
  developer    mode BUILD, worktree, repo (absolute paths), base (40 hex),
  tester       mode TEST,  awaiting_round (optional, a whole number of 1 or more)
  reviewer     lens (lowercase letters, digits and dashes)

needs jq 1.6+ and prune.jq from the ${CRUCIBLE_SKILL} skill, in
${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib

exit codes:
  0  done; a change prints nothing
  2  wrong command line: a missing or unknown command or option, an option
     the command does not take, or a missing or repeated value
  3  invalid input or the file fails the contract; each problem is one stderr
     line (at most ${MAX_PROBLEMS})
  4  jq or prune.jq is missing, jq failed, or the file could not be written
  5  refused by the seat's state: the slot exists, another agent or
     dispatch holds it, the agent was handed out of it, or it is open
     (status, handover), or find found ID in more than one seat
  6  the slot is not in the file; find: no seat holds ID
  7  the lock is held by another run past ${LOCK_WAIT_SECONDS}s
  8  busy found work in flight
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

# Prints $1 with each control character as "?", so a path can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Prints the options command $1 takes.
command_options() {
	case $1 in
		add) printf -- '--slots --slot --role --worktree --repo --base --lens' ;;
		bind) printf -- '--slots --slot --agent-id --dispatch' ;;
		find) printf -- '--slots --agent-id' ;;
		status) printf -- '--slots --slot --status --awaiting-round' ;;
		busy) printf -- '--slots' ;;
		*) printf -- '--slots --slot' ;;
	esac
}

# Sets $option_value from "$1 $2", refusing an option command does not take,
# a repeat or a missing value.
take_value() {
	case " ${allowed} " in
		*" $1 "*) ;;
		*) usage_error "$1 is not an option of ${command}; expected ${allowed}" ;;
	esac
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 VALUE"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	case ${1-} in
		-h | --help)
			usage
			exit 0
			;;
		'') usage_error "command missing; expected one of ${COMMANDS}" ;;
		add | bind | status | handover | get | find | busy) command=$1 ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected one of ${COMMANDS}"
			;;
	esac
	shift
	allowed=$(command_options "${command}")
	slots_file='' slot='' role='' worktree='' repo='' base='' lens='' agent_id='' dispatch='' status='' awaiting_round=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--slots)
				take_value "$1" "${slots_file}" "${2-}"
				slots_file=${option_value}
				;;
			--slot)
				take_value "$1" "${slot}" "${2-}"
				slot=${option_value}
				;;
			--role)
				take_value "$1" "${role}" "${2-}"
				role=${option_value}
				;;
			--worktree)
				take_value "$1" "${worktree}" "${2-}"
				worktree=${option_value}
				;;
			--repo)
				take_value "$1" "${repo}" "${2-}"
				repo=${option_value}
				;;
			--base)
				take_value "$1" "${base}" "${2-}"
				base=${option_value}
				;;
			--lens)
				take_value "$1" "${lens}" "${2-}"
				lens=${option_value}
				;;
			--agent-id)
				take_value "$1" "${agent_id}" "${2-}"
				agent_id=${option_value}
				;;
			--dispatch)
				take_value "$1" "${dispatch}" "${2-}"
				dispatch=${option_value}
				;;
			--status)
				take_value "$1" "${status}" "${2-}"
				status=${option_value}
				;;
			--awaiting-round)
				take_value "$1" "${awaiting_round}" "${2-}"
				awaiting_round=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected ${allowed} or --help"
				;;
		esac
		shift 2
	done
	require_options
}

# Refuses a command missing an option it needs; add's needs follow --role.
require_options() {
	require --slots "${slots_file}" FILE
	case ${command} in
		busy | find) ;;
		*) require --slot "${slot}" S ;;
	esac
	case ${command} in
		add) require_add_options ;;
		bind)
			require --agent-id "${agent_id}" ID
			require --dispatch "${dispatch}" ID
			;;
		status) require --status "${status}" 'working|idle|gave-up' ;;
		find) require --agent-id "${agent_id}" ID ;;
		*) ;;
	esac
}

require_add_options() {
	require --role "${role}" 'developer|tester|reviewer'
	case ${role} in
		developer | tester)
			[ -z "${lens}" ] || usage_error "--lens is given for a ${role}; expected it only for a reviewer"
			require --worktree "${worktree}" DIR
			require --repo "${repo}" DIR
			require --base "${base}" SHA
			;;
		reviewer)
			[ -z "${worktree}${repo}${base}" ] ||
				usage_error '--worktree, --repo or --base is given for a reviewer; expected only --lens'
			require --lens "${lens}" L
			;;
		*) ;;
	esac
}

# Refuses option $1 when its value $2 is empty; $3 names the value.
require() {
	[ -n "$2" ] || usage_error "$1 missing; expected $1 $3"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets slots_dir and effort from --slots, refusing a path that can't be the file.
check_slots_path() {
	shown_slots=$(printable "${slots_file}")
	case ${slots_file} in
		*[[:cntrl:]]*) die 3 "--slots ${shown_slots} holds a control character; expected a plain path" ;;
		*/) die 3 "--slots ${shown_slots} names a folder; expected the slots.json path" ;;
		/*) ;;
		*) die 3 "--slots ${shown_slots} is not absolute; expected an absolute path" ;;
	esac
	slots_dir=${slots_file%/*}
	effort=${slots_dir##*/}
	[ -n "${slots_dir}" ] || slots_dir=/
	shown_dir=$(printable "${slots_dir}")
	[ -d "${slots_dir}" ] || die 3 "--slots folder ${shown_dir} does not exist; expected the effort folder"
	[ ! -d "${slots_file}" ] || die 3 "--slots ${shown_slots} is a folder; expected the slots.json path"
}

# Sets own_dir (slots.jq) and crucible_lib_dir (prune.jq, from the installed
# crucible skill).
load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_dir=$(script_dir)
	crucible_lib_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib"
	shown_lib_dir=$(printable "${crucible_lib_dir}")
	[ -f "${crucible_lib_dir}/prune.jq" ] && [ -r "${crucible_lib_dir}/prune.jq" ] ||
		die 4 "prune.jq not found in ${shown_lib_dir}; expected the ${CRUCIBLE_SKILL} skill installed"
}

# Waits for the lock folder at most LOCK_WAIT_SECONDS; mkdir is atomic, so
# one run holds it at a time.
take_lock() {
	lock_dir="${slots_file}.lock"
	shown_lock=$(printable "${lock_dir}")
	deadline=$(($(date +%s) + LOCK_WAIT_SECONDS))
	until mkdir -- "${lock_dir}" 2>/dev/null; do
		[ -d "${lock_dir}" ] || die 4 "mkdir could not create the lock ${shown_lock}; expected a writable effort folder"
		now=$(date +%s)
		[ "${now}" -lt "${deadline}" ] ||
			die 7 "the lock ${shown_lock} is still held after ${LOCK_WAIT_SECONDS}s; expected it free (remove it by hand only when no ${PROG} runs)"
		# A fractional sleep is not POSIX; where it fails, wait a whole second.
		sleep "${LOCK_POLL_SECONDS}" 2>/dev/null || sleep 1
	done
	lock_held=yes
}

# Sets result to RUN_JQ's output over the file as it is now.
run_command() {
	if [ -e "${slots_file}" ]; then
		[ -f "${slots_file}" ] && [ -r "${slots_file}" ] ||
			die 3 "--slots ${shown_slots} is not a readable file; expected the slots JSON file"
		exists=yes current_file=${slots_file}
	else
		exists=no current_file=/dev/null
	fi
	result=$(jq -nc -L "${own_dir}" -L "${crucible_lib_dir}" --rawfile current "${current_file}" --arg exists "${exists}" \
		--arg command "${command}" --arg effort "${effort}" --argjson max "${MAX_PROBLEMS}" \
		--arg slot "${slot}" --arg role "${role}" --arg worktree "${worktree}" --arg repo "${repo}" \
		--arg base "${base}" --arg lens "${lens}" --arg agent_id "${agent_id}" --arg dispatch "${dispatch}" \
		--arg status "${status}" --arg awaiting_round "${awaiting_round}" "${RUN_JQ}") ||
		die 4 "jq failed; expected jq 1.6+, ${MODULE}.jq beside ${PROG} and prune.jq in ${shown_lib_dir}"
}

# Prints the problems and the output, writes the new file when there is one,
# and exits with the command's code.
finish() {
	outcome=$(printf '%s\n' "${result}" | jq -r '"\(.exit) \(.file != null)"') ||
		die 4 'jq failed reading the result; expected jq 1.6+'
	[ "${outcome#* }" = false ] || write_file
	problems=$(printf '%s\n' "${result}" | jq -r '.problems[]') ||
		die 4 'jq failed reading the problems; expected jq 1.6+'
	if [ -n "${problems}" ]; then
		while IFS= read -r problem; do
			warn "${problem}"
		done <<EOF
${problems}
EOF
	fi
	output=$(printf '%s\n' "${result}" | jq -r '.out') || die 4 'jq failed reading the output; expected jq 1.6+'
	[ -z "${output}" ] || printf '%s\n' "${output}"
	exit "${outcome% *}"
}

# Writes the new file over --slots through a temp file in the same folder.
write_file() {
	temp_file=$(mktemp "${slots_dir}/.${slots_file##*/}.XXXXXX") ||
		die 4 "mktemp could not create a temp file beside ${shown_slots}; expected a writable folder"
	printf '%s\n' "${result}" | jq '.file' >"${temp_file}" ||
		die 4 "could not write the temp file beside ${shown_slots}; expected free space"
	mv -f "${temp_file}" "${slots_file}" ||
		die 4 "mv could not move the temp file onto ${shown_slots}; expected a writable folder"
	temp_file=''
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ "${lock_held}" != yes ] || rmdir "${lock_dir}" 2>/dev/null || true
}

temp_file='' lock_held=no lock_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_slots_path
load_dependencies
case ${command} in
	get | find | busy) ;;
	*) take_lock ;;
esac
run_command
finish
