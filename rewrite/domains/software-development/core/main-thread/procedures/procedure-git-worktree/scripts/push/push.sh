#!/usr/bin/env sh
# Pushes one worker worktree's branch to a remote: never a protected branch,
# never forced, never prompting, and never for longer than its time limit,
# so a hook can run it and always go on. The first push sets the
# branch's upstream. A non-fast-forward rejection is named, never fixed.
set -eu
umask 077

readonly PROG='push.sh'
readonly BRANCH_PREFIX='crucible/'
# The whole push, connection included, unless --timeout says otherwise; the
# stop hook that runs it has 30 s.
readonly DEFAULT_TIMEOUT=15
# A push given longer than this is waiting on something that won't answer.
readonly MAX_TIMEOUT=600
readonly SSH_CONNECT_TIMEOUT=10
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
       sh ${PROG} --help | -h

Pushes the branch the worktree has checked out to the remote, as the
remote's branch of the same name, setting the upstream on the first push.
Refuses main, master, develop and release/*, and any branch not under
${BRANCH_PREFIX}. Never forces; runs no repository hook; never prompts
(GIT_TERMINAL_PROMPT=0, ssh BatchMode=yes and ConnectTimeout=${SSH_CONNECT_TIMEOUT},
stdin closed); stops the push after --timeout seconds.

--worktree DIR  absolute path of a git worktree's top folder, HEAD on a
                ${BRANCH_PREFIX}... branch
--remote NAME   a remote configured in the repository; not starting with -
--timeout SECONDS
                the whole push's limit, connection included: a whole
                number from 1 to ${MAX_TIMEOUT}; default ${DEFAULT_TIMEOUT}

stdout on success, one line: PUSHED: <remote>/<branch> (also when the
remote already held it)

exit codes:
  0  pushed
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: the worktree, its branch, the remote or --timeout does not
     fit; one stderr line
  4  environment: git missing, or a temp file failed
  5  the push failed, was rejected or timed out; one stderr line says why
     (a non-fast-forward is named); nothing was forced

needs: POSIX sh, git 2.26+
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
	worktree='' remote='' timeout=''
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
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --worktree, --remote, --timeout or --help"
				;;
		esac
		shift 2
	done
	[ -n "${worktree}" ] || usage_error '--worktree missing; expected --worktree DIR'
	[ -n "${remote}" ] || usage_error '--remote missing; expected --remote NAME'
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
	git -C "${worktree}" -c core.hooksPath=/dev/null push --quiet "$@" -- "${remote}" \
		"refs/heads/${branch}:refs/heads/${branch}" </dev/null >/dev/null 2>"${work_dir}/stderr" &
	push_pid=$!
	watch_push "${push_pid}" </dev/null >/dev/null 2>&1 &
	watcher_pid=$!
	push_rc=0
	wait "${push_pid}" || push_rc=$?
	kill "${watcher_pid}" 2>/dev/null || :
	wait "${watcher_pid}" 2>/dev/null || :
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
	if grep -Eq -- 'non-fast-forward|fetch first|tip of your current branch is behind' "${work_dir}/stderr"; then
		die 5 "git push of ${shown_branch} to ${shown_remote} was rejected: non-fast-forward, the remote branch moved; nothing was forced"
	fi
	first_line=$(sed '/^[[:space:]]*$/d' "${work_dir}/stderr" | head -n 1) || first_line=''
	shown_line=$(printable "${first_line:-no message}")
	die 5 "git push of ${shown_branch} to ${shown_remote} failed (exit ${push_rc}): ${shown_line}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_timeout
check_inputs
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-push.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
build_push
run_push
[ "${push_rc}" -eq 0 ] || push_failed
printf 'PUSHED: %s/%s\n' "${remote}" "${branch}"
