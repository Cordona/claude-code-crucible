# Shared by the git-mount scripts: the refusal lines, core found beside this
# skill, the repository through dev-base and where its mount record lives,
# and the work folder. Sourced, so it sets no shell option; its names start with gm_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # gm_prog is set by each sourcing script
# shellcheck disable=SC2034 # the gm_ values are read by the sourcing scripts
# shellcheck disable=SC2312 # a read inside a message only shortens the message

# The C locale keeps the shell, sed and awk byte-wise. No git command here
# refreshes or writes an index.
LC_ALL=C
GIT_TERMINAL_PROMPT=0
GIT_OPTIONAL_LOCKS=0
export LC_ALL GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS
# An inherited repository override would make git act elsewhere;
# GIT_DIFF_OPTS would change a patch's context.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_DIFF_OPTS GIT_EXTERNAL_DIFF

# The mount record's version; a record of any other is refused, never read.
GM_RECORD_VERSION=3

gm_refuse() {
	printf '%s: %s\n' "${gm_prog}" "$1" >&2
	exit 2
}

gm_fail() {
	printf '%s: %s\n' "${gm_prog}" "$1" >&2
	exit 4
}

gm_warn() {
	printf '%s: %s\n' "${gm_prog}" "$1" >&2
}

# Prints $1 with each control character as "?", so a value can't split a line.
gm_printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets gm_scripts to this component's scripts folder and gm_skills to the
# skills folder holding it, cut from the script's own path $1 as text, so a
# skill link holds; checks git and jq.
gm_find_self() {
	gm_self=$1
	case ${gm_self} in /*) ;; *) gm_self="$(pwd)/${gm_self}" ;; esac
	gm_scripts=${gm_self%/*/*}
	gm_skills=${gm_self%/*/*/*/*}
	command -v git >/dev/null 2>&1 || gm_fail 'git not found'
	command -v jq >/dev/null 2>&1 || gm_fail 'jq not found'
}

# Sets gm_core_* to core's public scripts beside this skill; refuses when
# core isn't there.
gm_find_core() {
	gm_core_writer="${gm_skills}/crucible-events/scripts/internal/event-write.sh"
	gm_core_reader="${gm_skills}/crucible-events/scripts/internal/events-read.sh"
	gm_core_state="${gm_skills}/crucible-effort/scripts/main/effort-state.sh"
	for gm_need in "${gm_core_writer}" "${gm_core_reader}" "${gm_core_state}"; do
		[ -f "${gm_need}" ] || gm_refuse "core isn't beside this skill (expected ${gm_need}); install first"
	done
}

# Refuses unless every path given is a file; a neighbour component missing.
gm_require_files() {
	for gm_need in "$@"; do
		[ -f "${gm_need}" ] || gm_refuse "a neighbour isn't beside this skill (expected ${gm_need}); install first"
	done
}

# Sets gm_effort to effort folder $1, physical, and gm_effort_name to its
# folder name. Refuses a folder that is not absolute or not an effort.
gm_check_effort() {
	case $1 in /*) ;; *) gm_refuse '--effort must be an absolute folder' ;; esac
	[ -d "$1/events" ] || gm_refuse "$1 is not an effort folder"
	gm_effort_given=$1
	gm_effort=$(cd -- "$1" && pwd -P) || gm_refuse "$1 can't be read"
	gm_effort_name=${gm_effort##*/}
}

# Sets gm_repo to the repository folder $1 belongs to, the main checkout a
# mount goes into, and gm_git_dir to its .git folder, as dev-base's
# repo-of.sh names them; gm_record_dir to the mount record's folder.
# Refuses a folder in no git repository, or in a bare one.
gm_set_repo() {
	case $1 in /*) ;; *) gm_refuse '--repo must be an absolute folder' ;; esac
	gm_repo_of="${gm_skills}/dev-base/scripts/internal/repo-of.sh"
	gm_require_files "${gm_repo_of}"
	gm_repo_rc=0
	gm_said=$(sh "${gm_repo_of}" --dir "$1" 2>&1) || gm_repo_rc=$?
	case ${gm_repo_rc} in
		0) ;;
		3 | 5) gm_refuse "--repo ${gm_said#repo-of.sh: }" ;;
		*) gm_fail "repo-of.sh failed (exit ${gm_repo_rc}): ${gm_said#repo-of.sh: }" ;;
	esac
	gm_repo=$(printf '%s' "${gm_said}" | jq -r '.repo')
	gm_git_dir=$(printf '%s' "${gm_said}" | jq -r '.git_dir')
	gm_record_dir="${gm_git_dir}/crucible"
}

# Makes the private work folder gm_work, physical, removed on exit.
gm_make_work() {
	gm_work=''
	trap gm_clean_up EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	gm_work=$(mktemp -d "${TMPDIR:-/tmp}/git-mount.XXXXXX") || gm_fail 'mktemp could not make a work folder'
	gm_work=$(cd -P -- "${gm_work}" && pwd -P) || gm_fail 'the work folder could not be entered'
}

gm_clean_up() {
	[ -z "${gm_work-}" ] || rm -rf -- "${gm_work}"
}

# Exits 4 naming step $1 and the first line of gm_work/stderr.
gm_git_failed() {
	gm_fail "$1 failed: $(gm_printable "$(head -n 1 "${gm_work}/stderr" 2>/dev/null || :)")"
}
