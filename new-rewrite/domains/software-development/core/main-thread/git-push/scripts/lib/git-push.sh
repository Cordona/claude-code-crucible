# Shared by the git-push scripts: the refusal lines, core, git-worktree and
# dev-base found beside this skill, the effort check, the work folder, and a
# command run under dev-base's time limit. Sourced, so it sets no shell
# option; its names start with gp_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # gp_prog is set by each sourcing script
# shellcheck disable=SC2034 # the gp_ values are read by the sourcing scripts
# shellcheck disable=SC2312 # a read inside a message only shortens the message

# The C locale keeps the shell byte-wise. No git command here refreshes an
# index, and none may ask anyone anything: no terminal prompt, no askpass
# program (an empty GIT_ASKPASS also hides core.askPass), no credential
# manager window, no ssh passphrase or host question.
LC_ALL=C
GIT_TERMINAL_PROMPT=0
GIT_OPTIONAL_LOCKS=0
GIT_ASKPASS=''
SSH_ASKPASS=''
SSH_ASKPASS_REQUIRE=never
GCM_INTERACTIVE=never
export LC_ALL GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS GIT_ASKPASS SSH_ASKPASS SSH_ASKPASS_REQUIRE GCM_INTERACTIVE
# An inherited repository override would make git act elsewhere.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

# run-timed.sh's exit for a command it stopped at the limit.
GP_TIMED_OUT=124

gp_refuse() {
	printf '%s: %s\n' "${gp_prog}" "$1" >&2
	exit 2
}

gp_fail() {
	printf '%s: %s\n' "${gp_prog}" "$1" >&2
	exit 4
}

# Prints $1 with each control character as "?", so a value can't split a line.
gp_printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets gp_scripts to this component's scripts folder and gp_skills to the
# skills folder holding it, cut from the script's own path $1 as text, so a
# skill link holds; checks git and jq.
gp_find_self() {
	gp_self=$1
	case ${gp_self} in /*) ;; *) gp_self="$(pwd)/${gp_self}" ;; esac
	gp_scripts=${gp_self%/*/*}
	gp_skills=${gp_self%/*/*/*/*}
	command -v git >/dev/null 2>&1 || gp_fail 'git not found'
	command -v jq >/dev/null 2>&1 || gp_fail 'jq not found'
}

# Sets gp_core_* to core's public scripts, gp_trees to git-worktree's tree
# list and gp_run_timed to dev-base's time limit beside this skill; refuses
# when one isn't there.
gp_find_neighbours() {
	gp_core_writer="${gp_skills}/crucible-events/scripts/internal/event-write.sh"
	gp_core_reader="${gp_skills}/crucible-events/scripts/internal/events-read.sh"
	gp_core_answer="${gp_skills}/crucible-gate/scripts/internal/gate-answer.sh"
	gp_trees="${gp_skills}/git-worktree/scripts/internal/worktree-trees.sh"
	gp_run_timed="${gp_skills}/dev-base/scripts/internal/run-timed.sh"
	for gp_need in "${gp_core_writer}" "${gp_core_reader}" "${gp_core_answer}" "${gp_trees}" "${gp_run_timed}"; do
		[ -f "${gp_need}" ] || gp_refuse "a neighbour isn't beside this skill (expected ${gp_need}); install first"
	done
}

# Sets gp_effort to effort folder $1 as given. Refuses a folder that is not
# absolute or not an effort.
gp_check_effort() {
	case $1 in /*) ;; *) gp_refuse '--effort must be an absolute folder' ;; esac
	[ -d "$1/events" ] || gp_refuse "$(gp_printable "$1") is not an effort folder"
	gp_effort=$1
}

# Makes the private work folder gp_work, removed on exit with any command
# still running under gp_run_timed.
gp_make_work() {
	gp_work='' gp_pid=''
	trap gp_clean_up EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	gp_work=$(mktemp -d "${TMPDIR:-/tmp}/git-push.XXXXXX") || gp_fail 'mktemp could not make a work folder'
}

# Stopping dev-base's run-timed.sh stops the command it runs, with
# everything that command started.
gp_clean_up() {
	[ -z "${gp_pid-}" ] || kill "${gp_pid}" 2>/dev/null || :
	[ -z "${gp_work-}" ] || rm -rf -- "${gp_work}"
}

# Runs the command after $1 through dev-base's run-timed.sh, with stdin
# closed, stdout to nowhere and stderr to gp_work/stderr; it is stopped with
# everything it started after $1 seconds. Sets gp_rc to its exit and
# gp_timed_out to yes or no.
gp_run_timed() {
	gp_limit=$1
	shift
	sh "${gp_run_timed}" --seconds "${gp_limit}" -- "$@" </dev/null >/dev/null 2>"${gp_work}/stderr" &
	gp_pid=$!
	gp_rc=0
	wait "${gp_pid}" || gp_rc=$?
	gp_pid=''
	gp_timed_out=no
	[ "${gp_rc}" -ne "${GP_TIMED_OUT}" ] || gp_timed_out=yes
}
