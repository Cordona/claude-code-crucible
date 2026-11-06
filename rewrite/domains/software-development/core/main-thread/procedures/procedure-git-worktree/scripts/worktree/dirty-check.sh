#!/usr/bin/env sh
# Counts each main checkout's uncommitted work and, when any is dirty, prints
# the AskUserQuestion input that asks the human where its developers start.
# Read-only: status runs without optional locks and without fsmonitor, so the
# checkout's real index is never refreshed or written.
set -eu
umask 077

readonly PROG='dirty-check.sh'
# AskUserQuestion takes at most this many questions, and a header of at most
# this many characters.
readonly MAX_REPOS=4
readonly HEADER_MAX=12
readonly tab='	'
readonly newline='
'
# The C locale keeps the shell byte-wise; jq reads git's paths as UTF-8.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

# Prints "staged unstaged untracked" from `git status --porcelain=v1 -z`: a
# rename or copy entry is followed by its source path, which is skipped.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly COUNT_JQ='reduce (split("\u0000")[] | select(. != "")) as $entry ({staged: 0, unstaged: 0, untracked: 0, source_next: false};
	if .source_next then .source_next = false
	else ($entry[0:1]) as $index | ($entry[1:2]) as $worktree
	| if $index + $worktree == "??" then .untracked += 1
	  elif $index + $worktree == "!!" then .
	  else .staged += (if $index != " " then 1 else 0 end)
		| .unstaged += (if $worktree != " " then 1 else 0 end)
		| .source_next = ([$index, $worktree] | any(. == "R" or . == "C"))
	  end
	end)
| "\(.staged) \(.unstaged) \(.untracked)"'

# Prints the AskUserQuestion input from $dirty: one "name<TAB>staged<TAB>
# unstaged<TAB>untracked" line per dirty checkout.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly QUESTIONS_JQ='def counted($count; $what): if $count == "0" then empty else "\($count) \($what)" end;
# The name, its leading dash-separated words dropped until it fits, so repos
# sharing a prefix get telling headers; cut to the limit when no word fits.
def header_of($max): split("-") as $w
	| ([range(0; $w | length) | $w[.:] | join("-") | select(length <= $max)] | first) // .[:$max];
$dirty | rtrimstr("\n") | split("\n") | map(split("\t"))
| {questions: map(. as [$name, $staged, $unstaged, $untracked]
	| {question: "\($name) has uncommitted changes: \([counted($staged; "staged"), counted($unstaged; "unstaged"), counted($untracked; "untracked")] | join(", ")). Where should its developers start?",
	   header: ($name | header_of($header_max)),
	   options: [
		{label: "Include my changes (Recommended)", description: "They start from your last commit plus these changes, taken as a snapshot. Your checkout is not touched."},
		{label: "Last commit only", description: "They start from your last commit. Your uncommitted changes stay out of their worktrees."},
		{label: "Stop", description: "Nothing is dispatched for this repository."}],
	   multiSelect: false})}'

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR [--repo DIR]...
       sh ${PROG} --help | -h

Counts each checkout's staged, unstaged and untracked files (a file both
staged and unstaged counts in both; ignored files never). Read-only.

--repo DIR  absolute path of a main checkout's top folder; not a linked
            worktree, not bare, no repeat; at most ${MAX_REPOS}

output, in --repo order:
  CLEAN: <repo>   per clean checkout
  QUESTIONS:      when any is dirty; then one line of JSON for
                  AskUserQuestion: {"questions":[...]}, one question per
                  dirty checkout (Include my changes, Last commit only, Stop)

exit codes:
  0  printed
  2  wrong command line: a missing or unknown option, a missing value, or
     more than ${MAX_REPOS} repos
  3  a --repo is refused; one stderr line per problem
  4  git or jq is missing or failed
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

# Checks the command line's shape only; the main body then reads the
# "--repo DIR" pairs it allowed.
parse_args() {
	[ "$#" -gt 0 ] || usage_error '--repo missing; expected --repo DIR'
	repo_count=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--repo)
				[ -n "${2-}" ] || usage_error '--repo needs a value; expected --repo DIR'
				repo_count=$((repo_count + 1))
				[ "${repo_count}" -le "${MAX_REPOS}" ] ||
					usage_error "more than ${MAX_REPOS} --repo given; expected at most ${MAX_REPOS}, one question each"
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --repo or --help"
				;;
		esac
	done
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
}

# Sets repo_ok when --repo $1 is a main checkout's top folder not given
# before, else warns its problem; seen_repos holds the physical paths so far.
check_repo() {
	repo_ok=false
	shown_repo=$(printable "$1")
	case $1 in
		*[[:cntrl:]]*)
			warn "--repo ${shown_repo} holds a control character; expected a path printable on one line"
			return 0
			;;
		/*) ;;
		*)
			warn "--repo ${shown_repo} is not absolute; expected an absolute path"
			return 0
			;;
	esac
	[ -d "$1" ] || {
		warn "--repo ${shown_repo} is not a folder; expected a main checkout's top folder"
		return 0
	}
	inside=$(git -C "$1" -c core.fsmonitor=false rev-parse --is-inside-work-tree 2>/dev/null) || inside=''
	[ "${inside}" = true ] || {
		warn "--repo ${shown_repo} is not a git work tree; expected a main checkout, not bare"
		return 0
	}
	physical_repo=$(cd -P -- "$1" && pwd -P) || physical_repo=''
	top_folder=$(git -C "$1" -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null) || top_folder=''
	[ -n "${top_folder}" ] && [ "${physical_repo}" = "${top_folder}" ] || {
		shown_top_folder=$(printable "${top_folder}")
		warn "--repo ${shown_repo} is not the checkout's top folder; expected ${shown_top_folder}"
		return 0
	}
	git_dir=$(git -C "$1" -c core.fsmonitor=false rev-parse --absolute-git-dir 2>/dev/null) || git_dir=''
	common_dir=$(git -C "$1" -c core.fsmonitor=false rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
		common_dir=''
	[ -n "${git_dir}" ] && [ -n "${common_dir}" ] ||
		die 4 "git could not name the git folders of ${shown_repo}; expected git 2.26+"
	[ "${git_dir}" = "${common_dir}" ] || {
		warn "--repo ${shown_repo} is a linked worktree; expected the main checkout"
		return 0
	}
	case ${seen_repos} in
		*"${newline}${physical_repo}${newline}"*)
			shown_physical=$(printable "${physical_repo}")
			warn "--repo ${shown_repo} repeats the checkout ${shown_physical}; expected each checkout once"
			return 0
			;;
		*) ;;
	esac
	seen_repos="${seen_repos}${physical_repo}${newline}"
	repo_ok=true
}

# Sets counts to "staged unstaged untracked" for --repo $1.
count_changes() {
	git -C "$1" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all \
		>"${work_dir}/status" 2>"${work_dir}/stderr" || step_failed "git status in $1"
	counts=$(jq -Rsr "${COUNT_JQ}" "${work_dir}/status" 2>"${work_dir}/stderr") ||
		step_failed "jq counting the status of $1"
}

# Exits 4 naming step $1 and its first stderr line.
step_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_step=$(printable "$1")
	shown_line=$(printable "${first_line}")
	die 4 "${shown_step} failed: ${shown_line}"
}

# Prints the folder name of path $1, trailing slashes dropped.
folder_name() {
	trimmed=$1
	while [ "${trimmed}" != / ] && [ "${trimmed%/}" != "${trimmed}" ]; do
		trimmed=${trimmed%/}
	done
	printf '%s' "${trimmed##*/}"
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
load_dependencies

# parse_args allowed only "--repo DIR" pairs; keep each DIR as a positional parameter.
is_value=false
for argument do
	shift
	if [ "${is_value}" = true ]; then
		set -- "$@" "${argument}"
		is_value=false
	else
		is_value=true
	fi
done

seen_repos=${newline} problems=0
for repo do
	check_repo "${repo}"
	[ "${repo_ok}" = true ] || problems=$((problems + 1))
done
[ "${problems}" -eq 0 ] || exit 3

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-dirty-check.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
clean_lines='' dirty_lines=''
for repo do
	count_changes "${repo}"
	if [ "${counts}" = '0 0 0' ]; then
		clean_lines="${clean_lines}CLEAN: ${repo}${newline}"
	else
		name=$(folder_name "${repo}")
		# counts holds three numbers split by single spaces.
		dirty_lines="${dirty_lines}${name}${tab}$(printf '%s' "${counts}" | tr ' ' "${tab}")${newline}"
	fi
done
[ -z "${dirty_lines}" ] || {
	questions=$(jq -nc --arg dirty "${dirty_lines}" --argjson header_max "${HEADER_MAX}" "${QUESTIONS_JQ}" 2>"${work_dir}/stderr") ||
		step_failed 'jq building the questions'
}
printf '%s' "${clean_lines}"
[ -z "${dirty_lines}" ] || printf 'QUESTIONS:\n%s\n' "${questions}"
