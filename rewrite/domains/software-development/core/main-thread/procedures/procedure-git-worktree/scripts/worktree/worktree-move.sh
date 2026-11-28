#!/usr/bin/env sh
# Points a linked worktree's branch at another commit with git reset --keep,
# so the worktree starts over from that commit. It refuses before touching
# anything when HEAD is not on a branch or the worktree holds uncommitted
# changes; with --keep-as, the commits the branch held before stay reachable
# from a ref, so git gc never prunes them.
set -eu
umask 077

readonly PROG='worktree-move.sh'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --worktree DIR --to SHA [--keep-as REF]
       sh ${PROG} --help | -h

Points the branch checked out in a linked worktree at commit SHA (git reset
--keep, no repository hook), refusing before any change unless HEAD is on a
branch and the worktree is clean (no staged, unstaged or untracked file).
With --keep-as, when the branch holds a commit SHA lacks, the old HEAD is
first kept under REF in the worktree's repository; a failed reset deletes
REF again. Nothing else is changed; nothing else is left behind (a SIGKILL
aside).

--worktree DIR  absolute path of a linked worktree's top folder; not a
                main checkout
--to SHA        4 to 40 hex characters naming a commit of the worktree's
                repository
--keep-as REF   a new full ref name, such as refs/crucible/moved/<name>/1

stdout, line 1: "old-head <sha>": the full sha HEAD was on before
stdout, line 2, only when REF was written: "kept <REF>"

exit codes:
  0  moved, or HEAD was on SHA already; read stdout
  2  wrong command line; fix what stderr names
  3  refused input, nothing changed; show the human stderr, and stop
  4  git is missing or failed, nothing changed; show the human stderr, and
     stop
  5  refused by state, nothing changed; show the human stderr, and stop

needs: POSIX sh, git 2.31+
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
	worktree='' to='' keep_as=''
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
			--to)
				take_value "$1" "${to}" "${2-}" SHA
				to=${option_value}
				;;
			--keep-as)
				take_value "$1" "${keep_as}" "${2-}" REF
				keep_as=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --worktree, --to, --keep-as or --help"
				;;
		esac
		shift 2
	done
	[ -n "${worktree}" ] || usage_error '--worktree missing; expected --worktree DIR'
	[ -n "${to}" ] || usage_error '--to missing; expected --to SHA'
}

# Sets worktree_dir, the physical top folder of a linked worktree.
check_worktree() {
	shown_worktree=$(printable "${worktree}")
	case ${worktree} in
		/*) ;;
		*) die 3 "--worktree ${shown_worktree} is not absolute; expected an absolute path" ;;
	esac
	worktree_dir=$(cd -P -- "${worktree}" 2>/dev/null && pwd -P) ||
		die 3 "--worktree ${shown_worktree} is not a folder; expected a linked worktree's top folder"
	top=$(git -C "${worktree_dir}" -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null) || top=''
	[ "${top}" = "${worktree_dir}" ] ||
		die 3 "--worktree ${shown_worktree} is not a worktree's top folder; expected a linked worktree's top folder"
	git_dir=$(git -C "${worktree_dir}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-dir 2>/dev/null) ||
		die 4 "git rev-parse --git-dir failed in ${shown_worktree}"
	common_dir=$(git -C "${worktree_dir}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
		die 4 "git rev-parse --git-common-dir failed in ${shown_worktree}"
	[ "${git_dir}" != "${common_dir}" ] ||
		die 3 "--worktree ${shown_worktree} is a main checkout; expected a linked worktree"
}

# Sets to_sha, the full sha of --to.
check_target() {
	shown_to=$(printable "${to}")
	case ${to} in
		*[!0123456789abcdef]*) die 3 "--to ${shown_to} is not lowercase hex; expected 4 to 40 hex characters" ;;
		*) ;;
	esac
	[ "${#to}" -ge 4 ] && [ "${#to}" -le 40 ] ||
		die 3 "--to ${shown_to} has ${#to} characters; expected 4 to 40 hex characters"
	to_sha=$(git -C "${worktree_dir}" -c core.fsmonitor=false rev-parse --verify --quiet --end-of-options "${to}^{commit}" 2>/dev/null) ||
		die 3 "--to ${shown_to} is not a commit of ${shown_worktree}'s repository; expected one (fetch it first)"
}

# Refuses a --keep-as that is no full ref name git takes, or one that exists.
check_keep_as() {
	[ -n "${keep_as}" ] || return 0
	shown_keep_as=$(printable "${keep_as}")
	case ${keep_as} in
		refs/*) ;;
		*) die 3 "--keep-as ${shown_keep_as} does not start with refs/; expected a full ref name" ;;
	esac
	git check-ref-format "${keep_as}" 2>/dev/null ||
		die 3 "--keep-as ${shown_keep_as} is no ref name git takes; expected one like refs/crucible/moved/<name>/1"
	if git -C "${worktree_dir}" show-ref --verify --quiet "${keep_as}" 2>/dev/null; then
		die 5 "--keep-as ${shown_keep_as} exists already; expected a new ref: nothing was moved"
	fi
}

# Sets old_head, refusing a detached HEAD or uncommitted changes.
check_state() {
	git -C "${worktree_dir}" symbolic-ref --quiet HEAD >/dev/null 2>&1 ||
		die 5 "${shown_worktree} has no branch checked out (HEAD is detached); expected HEAD on the worker branch"
	old_head=$(git -C "${worktree_dir}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		die 5 "${shown_worktree} has no HEAD commit; expected its branch on a commit"
	changes=$(git -C "${worktree_dir}" -c core.fsmonitor=false status --porcelain=v1 --untracked-files=normal 2>/dev/null) ||
		die 4 "git status failed in ${shown_worktree}"
	[ -z "${changes}" ] ||
		die 5 "${shown_worktree} has uncommitted changes; expected a clean worktree: nothing was moved"
}

# Sets kept to the ref written, or empty when --keep-as is not given or
# every commit of the branch is in to_sha, so the reset leaves none out.
keep_old_head() {
	kept=''
	[ -n "${keep_as}" ] || return 0
	ancestor_rc=0
	git -C "${worktree_dir}" merge-base --is-ancestor "${old_head}" "${to_sha}" 2>/dev/null || ancestor_rc=$?
	case ${ancestor_rc} in
		0) return 0 ;;
		1) ;;
		*) die 4 "git merge-base --is-ancestor failed in ${shown_worktree} (exit ${ancestor_rc}); expected it to compare ${old_head} with ${to_sha}: nothing was moved" ;;
	esac
	# The empty old value makes git refuse a ref another run wrote meanwhile.
	git -C "${worktree_dir}" -c core.hooksPath=/dev/null update-ref -m "${PROG}: kept before moving to ${to_sha}" "${keep_as}" "${old_head}" '' 2>/dev/null ||
		die 5 "--keep-as ${shown_keep_as} could not be written (another run may have written it); expected a new ref: nothing was moved"
	kept=${keep_as}
}

# Deletes the ref this run kept, after a failed reset.
drop_kept() {
	[ -n "${kept}" ] || return 0
	git -C "${worktree_dir}" -c core.hooksPath=/dev/null update-ref -d "${kept}" "${old_head}" 2>/dev/null ||
		warn "could not delete ${shown_keep_as}; delete it with git update-ref -d ${shown_keep_as}"
}

parse_args "$@"
command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.31+ on PATH'
check_worktree
check_target
check_keep_as
check_state
keep_old_head
reset_error=$(git -C "${worktree_dir}" -c core.fsmonitor=false -c core.hooksPath=/dev/null reset --quiet --keep "${to_sha}" 2>&1 >/dev/null) || {
	drop_kept
	first_line=$(printf '%s\n' "${reset_error}" | head -n 1)
	shown_line=$(printable "${first_line}")
	die 4 "git reset --keep ${to_sha} failed in ${shown_worktree}: ${shown_line}; fix what it names and rerun"
}
printf 'old-head %s\n' "${old_head}"
[ -z "${kept}" ] || printf 'kept %s\n' "${kept}"
