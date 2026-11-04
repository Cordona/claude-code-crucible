#!/usr/bin/env sh
# Creates one agent's detached linked worktree of a main checkout at a base
# commit, then proves it is that commit, clean, and that the main checkout's
# refs and config did not change. It never picks the base, copies
# dependencies, sets config, or creates a branch or ref. It refuses before
# touching anything, and rolls back what it created when anything fails.
set -eu
umask 077

readonly PROG='worktree-create.sh'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
# The C locale keeps the shell and its pattern classes byte-wise.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR --base COMMIT --path DIR
       sh ${PROG} --help | -h

Creates a detached linked git worktree of a main checkout at one commit.
Runs no repository hook; creates no branch or ref; sets no config.

--repo DIR     absolute path of the main checkout's top folder; not a linked
               worktree and not a bare repository
--base COMMIT  any name git resolves to a commit (sha, short sha, branch,
               tag); not starting with -
--path DIR     absolute, normalized path of the new worktree; must not exist
               (not even as a broken link), its parent folder must, it must
               lie outside --repo's work tree, and it must not already be
               registered as a worktree of --repo (prune a stale entry
               yourself)

output on success, exactly two stdout lines:
  worktree <the new worktree's absolute physical path>
  base <the base commit's full sha>

exit codes:
  0  created and verified
  2  wrong command line: a missing, repeated or unknown option, or a missing value
  3  invalid input: --repo, --base or --path; each problem is one stderr line
     (at most ${MAX_PROBLEMS}); nothing was touched
  4  git is missing, or git failed reading --repo before anything was created
  6  creation or verification failed; the worktree was rolled back and each
     problem, then each rollback step, is one stderr line
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

problems=''
problem_count=0

# Keeps up to MAX_PROBLEMS problem lines and counts all of them.
add_problem() {
	problem_count=$((problem_count + 1))
	[ "${problem_count}" -gt "${MAX_PROBLEMS}" ] || problems="${problems}${PROG}: $1
"
}

print_problems() {
	if [ "${problem_count}" -le "${MAX_PROBLEMS}" ]; then
		printf '%s' "${problems}" >&2
	else
		printf '%s' "${problems}" | head -n "$((MAX_PROBLEMS - 1))" >&2
		warn "$((problem_count - MAX_PROBLEMS + 1)) more problems not shown; expected none"
	fi
}

# Prints the kept problems and exits with $1; returns when there is none.
exit_on_problems() {
	[ "${problem_count}" -gt 0 ] || return 0
	print_problems
	exit "$1"
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 VALUE"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	repo='' base='' path=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--repo)
				take_value "$1" "${repo}" "${2-}"
				repo=${option_value}
				;;
			--base)
				take_value "$1" "${base}" "${2-}"
				base=${option_value}
				;;
			--path)
				take_value "$1" "${path}" "${2-}"
				path=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --repo, --base, --path or --help"
				;;
		esac
		shift 2
	done
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
	[ -n "${base}" ] || usage_error '--base missing; expected --base COMMIT'
	[ -n "${path}" ] || usage_error '--path missing; expected --path DIR'
}

check_inputs() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.31+ on PATH'
	shown_repo=$(printable "${repo}")
	shown_base=$(printable "${base}")
	shown_path=$(printable "${path}")
	repo_root='' repo_common='' base_sha='' physical_path=''
	check_repo
	[ -z "${repo_root}" ] || check_base
	check_path
	[ -z "${repo_root}" ] || [ -z "${physical_path}" ] || check_not_registered
}

# Sets repo_root and repo_common when --repo is the top folder of a main
# checkout; adds a problem and leaves them empty otherwise.
check_repo() {
	case ${repo} in
		*[[:cntrl:]]*)
			add_problem "--repo ${shown_repo} holds a control character; expected a plain path"
			return 0
			;;
		/*) ;;
		*)
			add_problem "--repo ${shown_repo} is not absolute; expected an absolute path"
			return 0
			;;
	esac
	physical_repo=$(cd -P -- "${repo}" 2>/dev/null && pwd -P) || physical_repo=''
	if [ -z "${physical_repo}" ]; then
		add_problem "--repo ${shown_repo} is not a folder; expected an existing folder"
	elif [ "$(git -C "${repo}" rev-parse --is-bare-repository 2>/dev/null || :)" = true ]; then
		add_problem "--repo ${shown_repo} is a bare repository; expected a main checkout"
	elif [ "$(git -C "${repo}" rev-parse --is-inside-work-tree 2>/dev/null || :)" != true ]; then
		add_problem "--repo ${shown_repo} is not a git work tree; expected a main checkout"
	else
		check_repo_kind
	fi
}

check_repo_kind() {
	top_folder=$(git -C "${repo}" rev-parse --show-toplevel 2>/dev/null) || top_folder=''
	git_dir=$(git -C "${repo}" rev-parse --absolute-git-dir 2>/dev/null) || git_dir=''
	common_dir=$(git -C "${repo}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=''
	if [ -z "${top_folder}" ] || [ "${top_folder}" != "${physical_repo}" ]; then
		shown_top_folder=$(printable "${top_folder}")
		add_problem "--repo ${shown_repo} is not the work tree's top folder; expected ${shown_top_folder}"
	elif [ -z "${git_dir}" ] || [ -z "${common_dir}" ]; then
		add_problem "--repo ${shown_repo}: git could not name its git folders; expected git 2.31+"
	elif [ "${git_dir}" != "${common_dir}" ]; then
		add_problem "--repo ${shown_repo} is a linked worktree; expected the main checkout"
	else
		repo_root=${physical_repo}
		repo_common=${common_dir}
	fi
}

# Resolves --base once to its full sha, kept in base_sha.
check_base() {
	case ${base} in
		*[[:cntrl:]]*)
			add_problem "--base ${shown_base} holds a control character; expected a commit name"
			return 0
			;;
		-*)
			add_problem "--base ${shown_base} starts with -; expected a commit name"
			return 0
			;;
		*) ;;
	esac
	base_sha=$(git -C "${repo_root}" rev-parse --verify --quiet "${base}^{commit}" 2>/dev/null) || base_sha=''
	[ -n "${base_sha}" ] ||
		add_problem "--base ${shown_base} does not resolve to a commit in --repo; expected a commit name"
}

# Sets physical_path (the parent's physical path plus the name) when --path
# is a fresh, normalized absolute path whose parent exists; adds a problem
# and leaves it empty otherwise.
check_path() {
	case ${path} in
		*[[:cntrl:]]*)
			add_problem "--path ${shown_path} holds a control character; expected a plain path"
			return 0
			;;
		/*) ;;
		*)
			add_problem "--path ${shown_path} is not absolute; expected an absolute path"
			return 0
			;;
	esac
	case ${path}/ in
		*/./* | */../* | *//*)
			add_problem "--path ${shown_path} has an empty, \".\" or \"..\" segment or a trailing /; expected a normalized path"
			return 0
			;;
		*) ;;
	esac
	if [ -e "${path}" ] || [ -L "${path}" ]; then
		add_problem "--path ${shown_path} already exists; expected a path that does not exist"
		return 0
	fi
	parent=${path%/*}
	physical_parent=$(cd -P -- "${parent:-/}" 2>/dev/null && pwd -P) || physical_parent=''
	if [ -z "${physical_parent}" ]; then
		shown_parent=$(printable "${parent:-/}")
		add_problem "--path ${shown_path}: its parent ${shown_parent} is not a folder; expected an existing folder"
		return 0
	fi
	physical_path="${physical_parent%/}/${path##*/}"
	[ -z "${repo_root}" ] || check_outside_repo
}

# Walks up from the parent's physical path; -ef also catches a folder that
# matches --repo only without case, as macOS file systems do.
check_outside_repo() {
	folder=${physical_parent}
	while :; do
		if [ "${folder}" = "${repo_root}" ] || [ "${folder}" -ef "${repo_root}" ]; then
			add_problem "--path ${shown_path} lies inside --repo's work tree; expected a path outside it"
			physical_path=''
			return 0
		fi
		case ${folder} in
			/) return 0 ;;
			/*/*) folder=${folder%/*} ;;
			*) folder=/ ;;
		esac
	done
}

check_not_registered() {
	worktree_list=$(git -C "${repo_root}" worktree list --porcelain 2>/dev/null) ||
		die 4 'git worktree list failed reading --repo; expected a readable repository'
	while IFS= read -r line; do
		case ${line} in
			"worktree ${path}" | "worktree ${physical_path}")
				add_problem "--path ${shown_path} is already registered as a worktree of --repo (a stale entry); expected an unregistered path; run git worktree prune yourself if it is stale"
				return 0
				;;
			*) ;;
		esac
	done <<EOF
${worktree_list}
EOF
}

# Sets main_refs, main_config and main_head from the main checkout, and
# snapshot_ok to no when git could not read them.
snapshot_main() {
	snapshot_ok=yes
	main_refs=$(git -C "${repo_root}" for-each-ref 2>/dev/null) || snapshot_ok=no
	main_config=$(git -C "${repo_root}" config --local --list 2>/dev/null) || snapshot_ok=no
	main_head="$(git -C "${repo_root}" symbolic-ref -q HEAD 2>/dev/null || :) $(git -C "${repo_root}" rev-parse -q --verify HEAD 2>/dev/null || :)"
}

record_main_before() {
	snapshot_main
	[ "${snapshot_ok}" = yes ] || die 4 'git failed reading the refs or config of --repo; expected a readable repository'
	refs_before=${main_refs}
	config_before=${main_config}
	head_before=${main_head}
}

# Runs git worktree add with the repository's hooks and fsmonitor off; git's
# own output goes to stderr so stdout stays the two result lines.
create_worktree() {
	add_started=yes
	git -C "${repo_root}" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
		worktree add --detach --quiet "${path}" "${base_sha}" >&2 ||
		fail_rolled_back 'git worktree add failed; expected a new detached worktree'
}

verify_worktree() {
	created_path=$(cd -P -- "${path}" 2>/dev/null && pwd -P) || created_path=''
	if [ -z "${created_path}" ]; then
		add_problem "--path ${shown_path} is not a folder after git worktree add; expected the new worktree"
		return 0
	fi
	created_top=$(git -C "${path}" rev-parse --show-toplevel 2>/dev/null) || created_top=''
	[ "${created_top}" = "${created_path}" ] ||
		add_problem "--path ${shown_path} is not the top folder of a git work tree; expected the new worktree's top folder"
	verify_head
	verify_linked
	verify_clean
}

verify_head() {
	if git -C "${path}" symbolic-ref -q HEAD >/dev/null 2>&1; then
		add_problem 'the new worktree has HEAD on a branch; expected a detached HEAD'
	fi
	created_head=$(git -C "${path}" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) || created_head=''
	[ "${created_head}" = "${base_sha}" ] ||
		add_problem "the new worktree's HEAD is not ${base_sha}; expected the base commit"
}

verify_linked() {
	created_git_dir=$(git -C "${path}" rev-parse --absolute-git-dir 2>/dev/null) || created_git_dir=''
	created_common=$(git -C "${path}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || created_common=''
	if [ -z "${created_common}" ] ||
		{ [ "${created_common}" != "${repo_common}" ] && [ ! "${created_common}" -ef "${repo_common}" ]; }; then
		add_problem "the new worktree's common git folder is not --repo's; expected a linked worktree of --repo"
	elif [ -z "${created_git_dir}" ] || [ "${created_git_dir}" = "${created_common}" ]; then
		add_problem 'the new worktree has no git folder of its own; expected a linked worktree'
	fi
}

verify_clean() {
	if ! created_status=$(git -C "${path}" -c core.fsmonitor=false status --porcelain --untracked-files=all 2>/dev/null); then
		add_problem 'git status failed in the new worktree; expected a readable worktree'
	elif [ -n "${created_status}" ]; then
		changed_count=$(printf '%s\n' "${created_status}" | wc -l)
		add_problem "git status lists $((changed_count)) changed or untracked paths in the new worktree; expected a clean checkout"
	fi
}

verify_main_unchanged() {
	snapshot_main
	if [ "${snapshot_ok}" = no ]; then
		add_problem 'git failed reading the refs or config of --repo after creation; expected a readable repository'
		return 0
	fi
	[ "${main_refs}" = "${refs_before}" ] ||
		add_problem "--repo's refs changed during creation; expected no new branch or ref"
	[ "${main_config}" = "${config_before}" ] ||
		add_problem "--repo's local config changed during creation; expected it untouched"
	[ "${main_head}" = "${head_before}" ] ||
		add_problem "--repo's HEAD changed during creation; expected it untouched"
}

# Adds problem $1, rolls back, prints every problem and exits 6.
fail_rolled_back() {
	add_problem "$1"
	roll_back
	print_problems
	exit 6
}

# Removes what this run created: the path did not exist and was not
# registered before, so a folder or worktree entry there is this run's.
roll_back() {
	[ "${rolled_back}" = no ] || return 0
	rolled_back=yes
	if git -C "${repo_root}" worktree remove --force "${path}" >/dev/null 2>&1; then
		add_problem "rollback: git worktree remove deleted ${shown_path} and its worktree entry"
	else
		remove_leftovers
	fi
	check_rolled_back
}

# Used when git worktree remove fails. git worktree prune would also drop
# other stale entries of --repo, so only this run's own entry is deleted.
remove_leftovers() {
	removed_any=no
	if [ -d "${path}" ] && [ ! -L "${path}" ]; then
		removed_any=yes
		if rm -rf -- "${path}"; then
			add_problem "rollback: git worktree remove failed; deleted the folder ${shown_path} this run created"
		else
			add_problem "rollback: could not delete the folder ${shown_path}; remove it by hand"
		fi
	elif [ -e "${path}" ] || [ -L "${path}" ]; then
		removed_any=yes
		add_problem "rollback: ${shown_path} is not a folder this run created; left it in place"
	fi
	remove_own_entry
	[ "${removed_any}" = yes ] || add_problem 'rollback: nothing was left to remove'
}

remove_own_entry() {
	for gitdir_file in "${repo_common}"/worktrees/*/gitdir; do
		[ -f "${gitdir_file}" ] || continue
		recorded=""
		IFS= read -r recorded <"${gitdir_file}" || [ -n "${recorded}" ] || continue
		[ "${recorded}" = "${path}/.git" ] || [ "${recorded}" = "${physical_path}/.git" ] || continue
		entry=${gitdir_file%/gitdir}
		removed_any=yes
		if rm -rf -- "${entry}"; then
			add_problem "rollback: deleted this run's worktree entry ${entry##*/} from --repo's records"
		else
			add_problem "rollback: could not delete the worktree entry ${entry##*/}; run git worktree prune in --repo"
		fi
	done
}

check_rolled_back() {
	if [ -e "${path}" ] || [ -L "${path}" ]; then
		add_problem "rollback incomplete: ${shown_path} still exists"
	fi
	registered_after=$(git -C "${repo_root}" worktree list --porcelain 2>/dev/null) || registered_after=''
	case "
${registered_after}
" in
		*"
worktree ${path}
"* | *"
worktree ${physical_path}
"*) add_problem "rollback incomplete: ${shown_path} is still registered as a worktree of --repo" ;;
		*) ;;
	esac
}

# Rolls back a creation cut short by a signal or an unexpected exit.
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	[ "${add_started}" = yes ] && [ "${finished}" = no ] && [ "${rolled_back}" = no ] || return 0
	add_problem 'creation was interrupted; expected it to finish'
	roll_back
	print_problems
}

add_started=no
finished=no
rolled_back=no
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_inputs
exit_on_problems 3
record_main_before
create_worktree
verify_worktree
verify_main_unchanged
[ "${problem_count}" -eq 0 ] || fail_rolled_back 'the new worktree failed verification; expected it to match the request'
finished=yes
printf 'worktree %s\nbase %s\n' "${created_path}" "${base_sha}"
