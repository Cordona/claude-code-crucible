#!/usr/bin/env sh
# Pushes one worker worktree's branch to a remote: never a protected branch,
# never prompting, and never for longer than its time limit, so a hook can
# run it and always go on. The first push sets the branch's upstream. A
# non-fast-forward rejection is named, never fixed; given its effort and
# seat, it records the push, and replaces what the seat last pushed, by
# lease, only after the seat moved.
set -eu
umask 077

readonly PROG='push.sh'
readonly BRANCH_PREFIX='crucible/'
# The whole push, connection included, unless --timeout says otherwise; the
# stop hook that runs it has 30 s.
readonly DEFAULT_TIMEOUT=15
# A push given longer than this is waiting on something that won't answer.
readonly MAX_TIMEOUT=600
# ssh gives up on an unreachable host after this many seconds, inside the
# default limit, so the push fails with ssh's own reason, not a bare timeout.
readonly SSH_CONNECT_TIMEOUT=10
readonly CRUCIBLE_SKILL='crucible'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --worktree DIR --remote NAME [--timeout SECONDS]
          [--effort FOLDER --seat S [--session ID]]
       sh ${PROG} --help | -h

Pushes the branch the worktree has checked out to the remote, as the
remote's branch of the same name, setting the upstream on the first push.
Refuses main, master, develop and release/*, and any branch not under
${BRANCH_PREFIX}. Runs no repository hook; never prompts
(GIT_TERMINAL_PROMPT=0, ssh BatchMode=yes and ConnectTimeout=${SSH_CONNECT_TIMEOUT},
stdin closed); stops the push after --timeout seconds.
Without --effort and --seat it never forces and records nothing. With them
(S's worktree must be DIR) it forces only when S has a seat.moved newer
than its last seat.pushed and the branch no longer holds that push's
commit C: --force-with-lease=refs/heads/<branch>:C, so the remote branch
is replaced only while it still is at C; then, after a push, it appends
seat.pushed {seat, remote, branch, commit, forced}. An append that fails
is a fault.raised, said on stderr; the exit is still 0. Nothing else is
left behind (a SIGKILL aside).

--worktree DIR  absolute path of a git worktree's top folder, HEAD on a
                ${BRANCH_PREFIX}... branch
--remote NAME   a remote configured in the repository; not starting with -
--timeout SECONDS
                the whole push's limit, connection included: a whole
                number from 1 to ${MAX_TIMEOUT}; default ${DEFAULT_TIMEOUT}
--effort FOLDER the effort folder, absolute; with --seat
--seat S        the developer seat whose branch this is; with --effort
--session ID    Claude Code's session for the event (default
                CLAUDE_CODE_SESSION_ID)

stdout on success, one line: PUSHED: <remote>/<branch> (also when the
remote already held it)

exit codes:
  0  pushed
  2  wrong command line, nothing pushed; give stderr, and skip this push
  3  input does not fit, nothing pushed; give stderr, and skip this push
  4  environment or a neighbour failed, nothing pushed; give stderr, and
     skip this push
  5  the push failed, was rejected or timed out, nothing forced; give
     stderr, and skip this push

needs: POSIX sh, git 2.26+; with --effort: jq 1.6+, ../seats/seats.sh from
this script's folder and the ${CRUCIBLE_SKILL} skill's events.sh
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
	worktree='' remote='' timeout='' effort='' seat='' session=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--worktree)
				take_value "$1" "${worktree}" "${2-}" DIR
				worktree=${option_value}
				;;
			--remote)
				take_value "$1" "${remote}" "${2-}" NAME
				remote=${option_value}
				;;
			--timeout)
				take_value "$1" "${timeout}" "${2-}" SECONDS
				timeout=${option_value}
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" FOLDER
				effort=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--session)
				take_value "$1" "${session}" "${2-}" ID
				session=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --worktree, --remote, --timeout, --effort, --seat, --session or --help"
				;;
		esac
		shift 2
	done
	[ -n "${worktree}" ] || usage_error '--worktree missing; expected --worktree DIR'
	[ -n "${remote}" ] || usage_error '--remote missing; expected --remote NAME'
	[ -z "${effort}" ] || [ -n "${seat}" ] || usage_error '--effort given alone; expected --seat S with it'
	[ -z "${seat}" ] || [ -n "${effort}" ] || usage_error '--seat given alone; expected --effort FOLDER with it'
	[ -z "${session}" ] || [ -n "${effort}" ] || usage_error '--session given without --effort and --seat; expected them with it'
	timeout=${timeout:-${DEFAULT_TIMEOUT}}
}

# A whole number with no leading zero, so the shell never reads it as octal.
check_timeout() {
	shown_timeout=$(printable "${timeout}")
	case ${timeout} in
		'' | 0* | *[!0-9]* | ????*) die 3 "--timeout ${shown_timeout} is not a whole number from 1 to ${MAX_TIMEOUT}; expected seconds" ;;
		*) ;;
	esac
	[ "${timeout}" -le "${MAX_TIMEOUT}" ] ||
		die 3 "--timeout ${shown_timeout} is over ${MAX_TIMEOUT}; expected seconds from 1 to ${MAX_TIMEOUT}"
}

# Sets branch from the worktree's HEAD, refusing anything but a crucible
# branch; the remote must not read as an option and must be configured.
check_inputs() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	shown_worktree=$(printable "${worktree}")
	case ${worktree} in
		/*) ;;
		*) die 3 "--worktree ${shown_worktree} is not absolute; expected an absolute path" ;;
	esac
	top_folder=$(git -C "${worktree}" rev-parse --show-toplevel 2>/dev/null) ||
		die 3 "--worktree ${shown_worktree} is not a git worktree; expected a worker worktree"
	physical_worktree=$(cd -P -- "${worktree}" && pwd -P) || physical_worktree=''
	shown_top_folder=$(printable "${top_folder}")
	[ "${top_folder}" = "${physical_worktree}" ] ||
		die 3 "--worktree ${shown_worktree} is not the worktree's top folder; expected ${shown_top_folder}"
	head_ref=$(git -C "${worktree}" symbolic-ref -q HEAD 2>/dev/null) ||
		die 3 "--worktree ${shown_worktree} has a detached HEAD; expected HEAD on a ${BRANCH_PREFIX}... branch"
	branch=${head_ref#refs/heads/}
	shown_branch=$(printable "${branch}")
	# Main, master, develop and release/* only move through a reviewed merge.
	case ${branch} in
		main | master | develop | release/*)
			die 3 "refusing to push the protected branch ${shown_branch}; main, master, develop and release/* only move through a reviewed merge"
			;;
		*) ;;
	esac
	case ${branch} in
		"${BRANCH_PREFIX}"?*) ;;
		*) die 3 "--worktree ${shown_worktree} is on ${shown_branch}; expected a ${BRANCH_PREFIX}... branch" ;;
	esac
	shown_remote=$(printable "${remote}")
	case ${remote} in
		-*) die 3 "--remote ${shown_remote} starts with -; expected a remote name" ;;
		*) ;;
	esac
	git -C "${worktree}" remote get-url -- "${remote}" >/dev/null 2>&1 ||
		die 3 "--remote ${shown_remote} is no remote of the repository; expected a configured remote"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Checks that --seat is a seat of --effort whose worktree is --worktree,
# and finds events.sh.
check_seat() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	[ -f "${own_dir}/../seats/seats.sh" ] || die 4 "${own_dir}/../seats/seats.sh not found; expected the procedure's scripts folders whole"
	events_script="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/events.sh"
	[ -f "${events_script}" ] || die 4 "events.sh not found at ${events_script}; expected the ${CRUCIBLE_SKILL} skill installed"
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	shown_seat=$(printable "${seat}")
	case ${seat} in
		*[!a-z0-9-]*) die 3 "--seat ${shown_seat} is not a seat name; expected lowercase words joined by -" ;;
		*) ;;
	esac
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --effort "${effort}" --seat "${seat}" </dev/null) || seat_rc=$?
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat of --effort" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc}; its stderr is above); expected the seat's JSON line; fix what it names and rerun" ;;
	esac
	seat_worktree=$(printf '%s\n' "${seat_json}" | jq -r '.worktree // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	physical_seat_worktree=$(cd -P -- "${seat_worktree}" 2>/dev/null && pwd -P) || physical_seat_worktree=''
	shown_seat_worktree=$(printable "${seat_worktree}")
	[ "${physical_seat_worktree}" = "${physical_worktree}" ] ||
		die 3 "--worktree ${shown_worktree} is not seat ${shown_seat}'s worktree; expected ${shown_seat_worktree}"
}

# Sets lease to the commit of the seat's last seat.pushed when a seat.moved
# came after it and the branch no longer holds that commit; else empty.
find_lease() {
	lease=''
	last_pushed=$(newest_event seat.pushed)
	[ -n "${last_pushed}" ] || return 0
	last_moved=$(newest_event seat.moved)
	[ -n "${last_moved}" ] || return 0
	moved_later=$(jq -rn --slurpfile pushed "${last_pushed}" --slurpfile moved "${last_moved}" \
		'$moved[0].seq > $pushed[0].seq') || die 4 'jq could not read the seat.pushed and seat.moved events'
	[ "${moved_later}" = true ] || return 0
	pushed_commit=$(jq -r '.body.commit // ""' "${last_pushed}") || die 4 'jq could not read the seat.pushed event'
	case ${pushed_commit} in
		'' | *[!0-9a-f]*) die 4 "seat ${shown_seat}'s last seat.pushed holds no commit sha; expected one" ;;
		*) ;;
	esac
	git -C "${worktree}" merge-base --is-ancestor "${pushed_commit}" "refs/heads/${branch}" >/dev/null 2>&1 && return 0
	lease=${pushed_commit}
}

# Prints the path of the seat's newest event of type $1; empty when none.
newest_event() {
	sh "${events_script}" latest --effort "${effort}" --type "$1" --where ".body.seat == \"${seat}\"" </dev/null ||
		die 4 "events.sh latest --type $1 failed (its stderr is above); expected an event path or nothing; fix what it names and rerun"
}

# Builds the push command in the positional parameters; --set-upstream only
# when the branch has none yet. The refspec names the branch in full, so no
# tag of the same name can stand in for it.
build_push() {
	set_upstream=yes
	git -C "${worktree}" rev-parse --abbrev-ref --symbolic-full-name "${branch}@{upstream}" >/dev/null 2>&1 &&
		set_upstream=no
	ssh_command=${GIT_SSH_COMMAND:-$(git -C "${worktree}" config core.sshCommand 2>/dev/null || :)}
	GIT_SSH_COMMAND="${ssh_command:-ssh} -o BatchMode=yes -o ConnectTimeout=${SSH_CONNECT_TIMEOUT}"
	export GIT_SSH_COMMAND
}

# Runs the push in the background and stops it after timeout seconds; sets
# push_rc, and timed_out from the watcher's marker. The watcher's own output
# goes nowhere, so a caller reading this script's output never waits on it.
run_push() {
	timeout_marker="${work_dir}/timed-out"
	if [ "${set_upstream}" = yes ]; then
		set -- --set-upstream
	else
		set --
	fi
	[ -z "${lease}" ] || set -- "$@" "--force-with-lease=refs/heads/${branch}:${lease}"
	git -C "${worktree}" -c core.hooksPath=/dev/null push --quiet "$@" -- "${remote}" \
		"refs/heads/${branch}:refs/heads/${branch}" </dev/null >/dev/null 2>"${work_dir}/stderr" &
	push_pid=$!
	watch_push "${push_pid}" </dev/null >/dev/null 2>&1 &
	watcher_pid=$!
	push_rc=0
	wait "${push_pid}" || push_rc=$?
	push_pid=''
	kill "${watcher_pid}" 2>/dev/null || :
	wait "${watcher_pid}" 2>/dev/null || :
	watcher_pid=''
	timed_out=no
	[ ! -e "${timeout_marker}" ] || timed_out=yes
}

# Sleeps timeout seconds, then writes the timeout marker and stops push $1;
# a kill of the watcher itself stops its sleep too.
watch_push() {
	sleep "${timeout}" &
	sleep_pid=$!
	trap 'kill "${sleep_pid}" 2>/dev/null; exit 0' TERM
	wait "${sleep_pid}" || exit 0
	: >"${timeout_marker}" || :
	kill "$1" 2>/dev/null || :
}

# Exits 5 with one line saying why the push failed.
push_failed() {
	if [ "${timed_out}" = yes ]; then
		die 5 "git push of ${shown_branch} to ${shown_remote} timed out after ${timeout} s; nothing was forced"
	fi
	if [ -n "${lease}" ] && grep -q -- 'stale info' "${work_dir}/stderr"; then
		die 5 "git push of ${shown_branch} to ${shown_remote} was rejected: the remote branch is no longer at ${lease}, the seat's last push; someone else pushed; nothing was forced"
	fi
	if grep -Eq -- 'non-fast-forward|fetch first|tip of your current branch is behind' "${work_dir}/stderr"; then
		die 5 "git push of ${shown_branch} to ${shown_remote} was rejected: non-fast-forward, the remote branch moved; nothing was forced"
	fi
	first_line=$(sed '/^[[:space:]]*$/d' "${work_dir}/stderr" | head -n 1) || first_line=''
	shown_line=$(printable "${first_line:-no message}")
	die 5 "git push of ${shown_branch} to ${shown_remote} failed (exit ${push_rc}): ${shown_line}"
}

# Appends seat.pushed for the pushed commit; a failed append is a fault and
# said on stderr, never a failed push.
record_push() {
	push_body="${work_dir}/pushed.json"
	forced=false
	[ -z "${lease}" ] || forced=true
	set -- --effort "${effort}" --by "${PROG}"
	[ -z "${session}" ] || set -- "$@" --session "${session}"
	if jq -nc --arg seat "${seat}" --arg remote "${remote}" --arg branch "${branch}" --arg commit "${pushed_commit_now}" \
		--argjson forced "${forced}" '{seat: $seat, remote: $remote, branch: $branch, commit: $commit, forced: $forced}' \
		>"${push_body}" 2>/dev/null &&
		sh "${events_script}" append "$@" --type seat.pushed --body-file "${push_body}" >/dev/null 2>"${work_dir}/stderr" </dev/null; then
		return 0
	fi
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line:-jq failed}")
	what="seat.pushed for ${branch} at ${pushed_commit_now} not recorded: ${shown_line}"
	fault_body="${work_dir}/fault.json"
	if jq -nc --arg seat "${seat}" --arg what "${what}" '{seat: $seat, what: $what}' >"${fault_body}" 2>/dev/null &&
		sh "${events_script}" fault "$@" --body-file "${fault_body}" >/dev/null 2>&1 </dev/null; then
		warn "pushed, but ${what}; recorded as a fault"
	else
		warn "pushed, but ${what}; the fault could not be recorded either"
	fi
}

# Stops a push and its watcher still running when a signal ends the script.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${watcher_pid}" ] || kill "${watcher_pid}" 2>/dev/null || :
	[ -z "${push_pid}" ] || kill "${push_pid}" 2>/dev/null || :
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir='' push_pid='' watcher_pid=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_timeout
check_inputs
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-push.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
lease=''
if [ -n "${effort}" ]; then
	check_seat
	find_lease
fi
pushed_commit_now=$(git -C "${worktree}" rev-parse --verify -q "refs/heads/${branch}^{commit}" 2>/dev/null) ||
	die 3 "--worktree ${shown_worktree}'s branch ${shown_branch} has no commit; expected one to push"
build_push
run_push
[ "${push_rc}" -eq 0 ] || push_failed
printf 'PUSHED: %s/%s\n' "${remote}" "${branch}"
[ -z "${effort}" ] || record_push
