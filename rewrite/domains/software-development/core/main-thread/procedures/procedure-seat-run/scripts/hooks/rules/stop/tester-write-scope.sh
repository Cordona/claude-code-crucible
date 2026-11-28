#!/usr/bin/env sh
# A rule of report-commit-hook.sh: it names the files other than test files
# and test data a tester changed in its build seat's worktree, as
# write-scope.jq's in_scope("tester"; path) judges each path git status
# names, and tells the tester what to do instead, so a production file made
# or changed through the shell is caught before it is committed. While a
# merge is under way, a path whose content is what the merge brings is the
# merge's, not the tester's, and is left out; an untracked path is never the
# merge's.
set -eu

readonly PROG='tester-write-scope.sh'
readonly ROLE='tester'
# From this folder to write-scope.jq.
readonly SCOPE_DIR='../../../seats'
# The block text names at most this many paths.
readonly MAX_NAMED=20
readonly PUT_BACK='Production files are not yours to write: put each back (rm a new file, git restore a tracked one). A production bug is a red test plus a production_bug blocker; a change outside the tests goes in open.'
# Prints the block text naming the changed paths out of $role's scope,
# control characters as "?"; nothing when there is none. Input: git status
# --porcelain -z --no-renames; $merging: "yes" while a merge is under way;
# $differs: then the NUL-separated paths whose content is not the merge's
# result.
# shellcheck disable=SC2016 # the $ names are jq's
readonly OUT_OF_SCOPE_JQ='include "write-scope";
($differs | split("\u0000") | map(select(. != "") | {(.): true}) | add // {}) as $not_merged
| [split("\u0000")[]
	| select(length > 3)
	| .[0:2] as $status | .[3:] as $path
	| select($merging != "yes" or $status == "??" or $not_merged[$path])
	| select(in_scope($role; $path) | not)
	| $path
	| gsub("[[:cntrl:]]"; "?")]
| select(length > 0)
| "These production files changed: \(.[0:$max] | join(", ")). \($put_back)"'
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

usage() {
	cat <<EOF
usage: sh ${PROG} --worktree DIR
       sh ${PROG} --help | -h

A rule of report-commit-hook.sh. Runs git status --porcelain -z
--no-renames --untracked-files=all in the git worktree DIR and judges each
path it names, a deleted one included, by in_scope("${ROLE}"; path) of
${SCOPE_DIR}/write-scope.jq.
With MERGE_HEAD set, a tracked path is judged only when git diff
--name-only, against the tree git merge-tree --write-tree HEAD MERGE_HEAD
writes, names it: a path the merge brought unchanged is left out.

stdout: one line, "These production files changed: <paths>. " then
  "${PUT_BACK}"
  <paths> the changed paths out of scope, joined by ", ", at most
  ${MAX_NAMED}, control characters as "?"; nothing when there is none.
  Writes nothing.

exit codes:
  0  no changed path is out of scope
  1  wrong command line
  3  a changed path is out of scope; stdout names them
  4  could not check (stderr says why): jq or git missing, DIR not a git
     worktree, a git command or write-scope.jq failing

needs: POSIX sh, jq 1.6+, git 2.38+; write-scope.jq at ${SCOPE_DIR}
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Names fault $1 on stderr and exits 4.
fault() {
	warn "$1"
	exit 4
}

usage_error() {
	warn "$1"
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 1
}

parse_args() {
	worktree=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--worktree)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--worktree needs a value; expected --worktree DIR'
				[ -z "${worktree}" ] || usage_error '--worktree given twice; expected it once'
				worktree=$2
				shift 2
				;;
			*) usage_error 'unknown option; expected --worktree DIR or --help' ;;
		esac
	done
	[ -n "${worktree}" ] || usage_error '--worktree is missing; expected --worktree DIR'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

check_tools() {
	command -v jq >/dev/null 2>&1 || fault 'jq not found; expected jq 1.6+ on PATH'
	command -v git >/dev/null 2>&1 || fault 'git not found; expected git 2.38+ on PATH'
}

# Runs git in the worktree, its stdout into file $1, its exit code in
# git_rc; never stops the script.
git_into() {
	out_file=$1
	shift
	git_rc=0
	git -c core.fsmonitor=false -C "${worktree}" "$@" >"${out_file}" 2>"${work_dir}/stderr" </dev/null || git_rc=$?
}

# Names the failed git command $1 with its first stderr line, and exits 4.
git_fault() {
	first_line=$(head -n 1 "${work_dir}/stderr" | tr '[:cntrl:]' '?') || first_line=''
	fault "git $1 failed in the worktree: ${first_line}"
}

read_status() {
	git_into "${work_dir}/top" rev-parse --show-toplevel
	[ "${git_rc}" -eq 0 ] || git_fault 'rev-parse --show-toplevel'
	git_into "${work_dir}/status" status --porcelain -z --no-renames --untracked-files=all --ignore-submodules=none
	[ "${git_rc}" -eq 0 ] || git_fault status
}

# Sets merging to yes while a merge is under way, and writes to
# work_dir/differs the paths whose content is not the merge's result then.
read_merge() {
	merging=no
	: >"${work_dir}/differs"
	git -c core.fsmonitor=false -C "${worktree}" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1 </dev/null || return 0
	git_into "${work_dir}/merge-tree" merge-tree --write-tree --no-messages HEAD MERGE_HEAD
	[ "${git_rc}" -le 1 ] || git_fault 'merge-tree --write-tree HEAD MERGE_HEAD'
	merge_tree=$(head -n 1 "${work_dir}/merge-tree")
	case ${merge_tree} in
		'' | *[!0-9a-f]*) fault 'git merge-tree printed no tree id' ;;
		*) ;;
	esac
	git_into "${work_dir}/differs" diff --no-renames --name-only -z "${merge_tree}" --
	[ "${git_rc}" -eq 0 ] || git_fault "diff --name-only ${merge_tree}"
	merging=yes
}

judge() {
	scope_dir=$(cd -P -- "${own_dir}/${SCOPE_DIR}" 2>/dev/null && pwd -P) ||
		fault "the seats folder ${SCOPE_DIR} is not beside ${own_dir}; expected procedure-seat-run installed whole"
	[ -f "${scope_dir}/write-scope.jq" ] || fault "${scope_dir}/write-scope.jq is missing; expected procedure-seat-run installed whole"
	jq -Rrs -L "${scope_dir}" --arg role "${ROLE}" --arg merging "${merging}" \
		--argjson max "${MAX_NAMED}" --arg put_back "${PUT_BACK}" \
		--rawfile differs "${work_dir}/differs" "${OUT_OF_SCOPE_JQ}" \
		"${work_dir}/status" >"${work_dir}/out" 2>"${work_dir}/stderr" || {
		first_line=$(head -n 1 "${work_dir}/stderr" | tr '[:cntrl:]' '?') || first_line=''
		fault "write-scope.jq failed: ${first_line}"
	}
	[ -s "${work_dir}/out" ] || exit 0
	cat "${work_dir}/out"
	exit 3
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir=''
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
check_tools
[ -d "${worktree}" ] || fault "--worktree ${worktree} is not a folder; expected a git worktree"
own_path=$(script_dir)
own_dir=$(cd -P -- "${own_path}" && pwd -P) || fault 'this script'\''s folder could not be entered'
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-write-scope.XXXXXX") || {
	work_dir=''
	fault 'mktemp could not create a work folder; expected a writable TMPDIR'
}
read_status
read_merge
judge
