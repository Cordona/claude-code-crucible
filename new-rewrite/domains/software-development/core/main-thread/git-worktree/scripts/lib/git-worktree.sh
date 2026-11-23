# Shared by the git-worktree scripts: the refusal and problem lines, core
# and the neighbour components found beside this skill, the repository
# through dev-base, the name and commit checks, the work folder, the event
# write, and thin calls to this component's own job scripts.
# Sourced, so it sets no shell option; its names start with gw_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # gw_prog is set by each sourcing script
# shellcheck disable=SC2034 # the gw_ values are read by the sourcing scripts
# shellcheck disable=SC2310,SC2312 # a read inside a message only shortens the message, and a function in a condition is there for its status

# The C locale keeps the shell and its pattern classes byte-wise. No git
# command here refreshes an index it only reads.
LC_ALL=C
GIT_TERMINAL_PROMPT=0
GIT_OPTIONAL_LOCKS=0
export LC_ALL GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS
# An inherited repository override would make git act elsewhere.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

# A tree's name: lowercase words joined by dashes.
GW_NAME_RULE='^[a-z][a-z0-9]*(-[a-z0-9]+)*$'
# Bounds stderr so a list of problems stays readable.
GW_MAX_PROBLEMS=20

gw_refuse() {
	printf '%s: %s\n' "${gw_prog}" "$1" >&2
	exit 2
}

gw_fail() {
	printf '%s: %s\n' "${gw_prog}" "$1" >&2
	exit 4
}

# Prints $1 with each control character as "?", so a value can't split a line.
gw_printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets gw_skills, the skills folder holding this component, from the
# script's own path $1 as text, so a skill link holds; gw_lib to this lib's
# folder; and gw_core_* to core's public scripts there. Refuses when core
# isn't beside this skill.
gw_find_core() {
	gw_self=$1
	case ${gw_self} in /*) ;; *) gw_self="$(pwd)/${gw_self}" ;; esac
	gw_scripts=${gw_self%/*/*}
	gw_lib="${gw_scripts}/lib"
	gw_skills=${gw_self%/*/*/*/*}
	gw_core_writer="${gw_skills}/crucible-events/scripts/internal/event-write.sh"
	gw_core_reader="${gw_skills}/crucible-events/scripts/internal/events-read.sh"
	gw_core_answer="${gw_skills}/crucible-gate/scripts/internal/gate-answer.sh"
	gw_core_state="${gw_skills}/crucible-effort/scripts/main/effort-state.sh"
	for gw_need in "${gw_core_writer}" "${gw_core_reader}" "${gw_core_answer}" "${gw_core_state}"; do
		[ -f "${gw_need}" ] || gw_refuse "core isn't beside this skill (expected ${gw_need}); install first"
	done
	command -v git >/dev/null 2>&1 || gw_fail 'git not found'
	command -v jq >/dev/null 2>&1 || gw_fail 'jq not found'
}

# Sets gw_commit_* to the neighbour skill git-commit's scripts. Refuses when
# git-commit isn't beside this skill.
gw_find_commit() {
	gw_commit_message="${gw_skills}/git-commit/scripts/main/commit-message.sh"
	gw_commit_object="${gw_skills}/git-commit/scripts/internal/commit-object.sh"
	gw_commits_merge="${gw_skills}/git-commit/scripts/internal/commits-merge.sh"
	for gw_need in "${gw_commit_message}" "${gw_commit_object}" "${gw_commits_merge}"; do
		[ -f "${gw_need}" ] || gw_refuse "git-commit isn't beside this skill (expected ${gw_need}); install first"
	done
}

# Sets gw_effort to effort folder $1, physical, and gw_effort_name to its
# folder name. Refuses a folder that is not absolute or not an effort.
gw_check_effort() {
	case $1 in /*) ;; *) gw_refuse '--effort must be an absolute folder' ;; esac
	[ -d "$1/events" ] || gw_refuse "$1 is not an effort folder"
	gw_effort_given=$1
	gw_effort=$(cd -- "$1" && pwd -P) || gw_refuse "$1 can't be read"
	gw_effort_name=${gw_effort##*/}
}

# Refuses unless the effort is open.
gw_require_open() {
	gw_state=$(sh "${gw_core_state}" --effort "${gw_effort_given}") || exit 2
	[ "${gw_state}" = open ] || gw_refuse "the effort is ${gw_state}; trees change only while it's open"
}

# Refuses a tree name that is not lowercase words joined by dashes.
gw_check_name() {
	printf '%s' "$1" | grep -Eq "${GW_NAME_RULE}" \
		|| gw_refuse "--name $(gw_printable "$1") must be lowercase words joined by dashes"
}

# Sets gw_repo to the repository folder $1 belongs to, its main checkout,
# as dev-base's repo-of.sh names it. Refuses a folder in no git repository,
# or in a bare one.
gw_set_repo() {
	case $1 in /*) ;; *) gw_refuse '--repo must be an absolute folder' ;; esac
	gw_repo_of="${gw_skills}/dev-base/scripts/internal/repo-of.sh"
	[ -f "${gw_repo_of}" ] || gw_refuse "dev-base isn't beside this skill (expected ${gw_repo_of}); install first"
	gw_repo_rc=0
	gw_said=$(sh "${gw_repo_of}" --dir "$1" 2>&1) || gw_repo_rc=$?
	case ${gw_repo_rc} in
		0) gw_repo=$(printf '%s' "${gw_said}" | jq -r '.repo') ;;
		3 | 5) gw_refuse "--repo ${gw_said#repo-of.sh: }" ;;
		*) gw_fail "repo-of.sh failed (exit ${gw_repo_rc}): ${gw_said#repo-of.sh: }" ;;
	esac
}

# Makes the private work folder gw_work, removed on exit.
gw_make_work() {
	gw_work=''
	trap gw_clean_up EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	gw_work=$(mktemp -d "${TMPDIR:-/tmp}/git-worktree.XXXXXX") || gw_fail 'mktemp could not make a work folder'
}

gw_clean_up() {
	[ -z "${gw_work-}" ] || rm -rf -- "${gw_work}"
}

# Writes the effort's worktree.* events, one JSON array, to gw_work/events.
gw_read_events() {
	sh "${gw_core_reader}" --effort "${gw_effort_given}" --type 'worktree.*' >"${gw_work}/events" \
		|| gw_fail 'events-read.sh failed reading the effort'
}

# Sets the gw_tree_* values from tree $1, as worktree-trees.sh gives it:
# path, branch, repo, the cut's base, and base, the base its work is read
# from. Refuses a name that is no live tree of the effort.
gw_load_tree() {
	gw_tree=$(sh "${gw_scripts}/internal/worktree-trees.sh" --effort "${gw_effort_given}" --name "$1") || exit $?
	gw_tree=$(printf '%s' "${gw_tree}" | jq -c 'first // empty')
	[ -n "${gw_tree}" ] || gw_refuse "the effort has no live tree named $(gw_printable "$1")"
	gw_tree_name=$1
	gw_tree_path=$(printf '%s' "${gw_tree}" | jq -r '.path')
	gw_tree_branch=$(printf '%s' "${gw_tree}" | jq -r '.branch')
	gw_tree_repo=$(printf '%s' "${gw_tree}" | jq -r '.repo')
	gw_tree_cut_base=$(printf '%s' "${gw_tree}" | jq -r '.cut_base')
	gw_tree_base=$(printf '%s' "${gw_tree}" | jq -r '.base')
}

# Prints the full sha the tree's branch points at, or nothing when the
# branch is gone.
gw_branch_tip() {
	git -C "${gw_tree_repo}" rev-parse --verify --quiet "refs/heads/${gw_tree_branch}^{commit}" 2>/dev/null || :
}

# Refuses unless the tree's folder is there, is its worktree's top folder,
# and has HEAD on its branch. Sets gw_head to the tree's HEAD.
gw_require_present() {
	[ -d "${gw_tree_path}" ] || gw_refuse "tree ${gw_tree_name}'s folder ${gw_tree_path} is not there"
	gw_top=$(git -C "${gw_tree_path}" rev-parse --show-toplevel 2>/dev/null) || gw_top=''
	[ "${gw_top}" = "${gw_tree_path}" ] || gw_refuse "${gw_tree_path} is not tree ${gw_tree_name}'s git worktree"
	gw_on=$(git -C "${gw_tree_path}" symbolic-ref -q HEAD 2>/dev/null) || gw_on=''
	[ "${gw_on}" = "refs/heads/${gw_tree_branch}" ] \
		|| gw_refuse "tree ${gw_tree_name}'s HEAD is not on its branch ${gw_tree_branch}"
	gw_head=$(git -C "${gw_tree_path}" rev-parse --verify --quiet 'HEAD^{commit}') \
		|| gw_refuse "tree ${gw_tree_name} has no HEAD commit"
}

# Prints the name of the first merge, pick, revert or rebase under way in
# worktree folder $1, or nothing.
gw_under_way() {
	for gw_state_file in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
		gw_state_path=$(git -C "$1" rev-parse --path-format=absolute --git-path "${gw_state_file}") \
			|| gw_fail "git rev-parse --git-path failed in $1"
		if [ -e "${gw_state_path}" ]; then
			printf '%s' "${gw_state_file}"
			return 0
		fi
	done
}

# Prints worktree-uncommitted.sh's count for worktree folder $1.
gw_uncommitted() {
	gw_said=$(sh "${gw_scripts}/internal/worktree-uncommitted.sh" --dir "$1") || exit $?
	printf '%s' "${gw_said}" | jq -r '.uncommitted'
}

# Refuses when worktree-busy.sh finds tree $1 busy, naming its lines.
gw_require_idle() {
	gw_busy_rc=0
	gw_said=$(sh "${gw_scripts}/internal/worktree-busy.sh" --effort "${gw_effort_given}" --name "$1") || gw_busy_rc=$?
	case ${gw_busy_rc} in
		0) ;;
		5) gw_refuse "tree $1 is busy: $(printf '%s' "${gw_said}" | jq -r '.busy | join("; ")')" ;;
		*) gw_fail "worktree-busy.sh failed (exit ${gw_busy_rc})" ;;
	esac
}

# Writes message file gw_work/message for kind $1 and text $2 through
# git-commit's commit-message.sh, with the trailer "Worktree: <name>" when
# $3 is given.
gw_message() {
	jq -n --arg kind "$1" --arg text "$2" --arg tree "${3-}" \
		'{kind: $kind, text: $text} + (if $tree == "" then {} else {trailers: {worktree: $tree}} end)' \
		>"${gw_work}/message-input"
	sh "${gw_commit_message}" --input "${gw_work}/message-input" --out "${gw_work}/message" \
		|| gw_fail 'commit-message.sh could not write the message'
}

# Sets gw_changes and gw_head_tree from worktree-changes.sh for worktree
# folder $1 and HEAD $2.
gw_changes_tree() {
	gw_said=$(sh "${gw_scripts}/internal/worktree-changes.sh" --dir "$1" --head "$2") || exit $?
	gw_changes=$(printf '%s' "${gw_said}" | jq -r '.tree')
	gw_head_tree=$(printf '%s' "${gw_said}" | jq -r '.head_tree')
}

# Adds problem $1 to gw_work/problems, for a script that reports every
# problem it finds before it stops.
gw_add_problem() {
	printf '%s: %s\n' "${gw_prog}" "$1" >>"${gw_work}/problems"
}

# Prints the problems kept, at most GW_MAX_PROBLEMS with a last line
# counting the rest, and exits with $1; returns when there is none.
gw_exit_on_problems() {
	[ -s "${gw_work}/problems" ] || return 0
	gw_problem_count=$(($(wc -l <"${gw_work}/problems")))
	if [ "${gw_problem_count}" -le "${GW_MAX_PROBLEMS}" ]; then
		cat "${gw_work}/problems" >&2
	else
		head -n "$((GW_MAX_PROBLEMS - 1))" "${gw_work}/problems" >&2
		printf '%s: %s more problems not shown; expected none\n' "${gw_prog}" "$((gw_problem_count - GW_MAX_PROBLEMS + 1))" >&2
	fi
	exit "$1"
}

# Writes event type $1 with body file $2 through core's writer, as this
# script; prints the event's path. Its refusal passes on with its code.
gw_write() {
	sh "${gw_core_writer}" --effort "${gw_effort_given}" --type "$1" --by "${gw_prog}" --body-file "$2"
}

# Writes event type $1 with body file $2 as gw_write does, once
# worktree-trees.sh still lists tree gw_tree_name: a tree dropped while this
# script ran gets no event. Refuses, writing nothing, when it is gone.
gw_write_live() {
	gw_still=$(sh "${gw_scripts}/internal/worktree-trees.sh" --effort "${gw_effort_given}" --name "${gw_tree_name}") || exit $?
	[ "$(printf '%s' "${gw_still}" | jq 'length')" -eq 1 ] \
		|| gw_refuse "tree ${gw_tree_name} was dropped while ${gw_prog} ran; no $1 was written"
	gw_write "$1" "$2"
}

# Writes event type $1 with body file $2 as gw_write_live does and sets
# gw_event to its path. When the write fails, runs function $3 to undo the
# script's change, then exits with the write's code; an undo that fails
# exits 4 instead.
gw_write_or_undo() {
	gw_write_rc=0
	gw_event=$(gw_write_live "$1" "$2") || gw_write_rc=$?
	[ "${gw_write_rc}" -ne 0 ] || return 0
	"$3"
	exit "${gw_write_rc}"
}

# Returns 0 when tree gw_tree_name's folder is still there; otherwise says
# on stderr that a drop removed it, so there is nothing to put back.
gw_tree_still_there() {
	[ ! -d "${gw_tree_path}" ] || return 0
	printf '%s: nothing put back: tree %s was dropped, its folder and branch with it\n' "${gw_prog}" "${gw_tree_name}" >&2
	return 1
}

# Deletes kept ref $1 when it still points at commit $2.
gw_delete_kept() {
	[ -n "$(git -C "${gw_tree_repo}" rev-parse --verify --quiet "$1" 2>/dev/null || :)" ] || return 0
	git -C "${gw_tree_repo}" update-ref -d "$1" "$2" || gw_fail "could not delete the kept ref $1; delete it with git update-ref -d"
}

# Resolves name $1, given as option $3, to a commit of repository folder $2
# and prints its full sha; refuses a name that could be read as an option,
# holds a control character, or names no commit there.
gw_resolve_commit() {
	case $1 in
		'') gw_refuse "$3 needs a commit" ;;
		-*) gw_refuse "$3 $(gw_printable "$1") starts with -; expected a commit name" ;;
		*[[:cntrl:]]*) gw_refuse "$3 holds a control character; expected a commit name" ;;
		*) ;;
	esac
	git -C "$2" rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null \
		|| gw_refuse "$3 $1 is no commit of $2"
}
