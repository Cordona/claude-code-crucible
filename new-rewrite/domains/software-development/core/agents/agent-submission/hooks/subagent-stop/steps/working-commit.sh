#!/usr/bin/env sh
# A step of submit-agent-work.sh: makes the job's working commit.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh working-commit.sh --effort FOLDER --job FILE

Run by submit-agent-work.sh and recover-submission.sh; not for main to call.
Commits the job's tree, unsigned, through git-commit's commit-message.sh and
commit-tree.sh: subject "crucible(<kind>): <the report's summary>", cut at
a word to fit with "…"; the whole summary as the body; then the trailers
Effort, Job (seq and name), Iteration, Fix-Round (a fix only) and the job's
setup. Nothing is committed when the tree didn't change.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job FILE       the job, as jobs-track's job-of.sh prints it, assigned
Requires:  the report pinned; the effort's identity for the tree's
           repository (git-identity), whose name and email the commit carries
Writes:    the commit, on the tree's branch
Stdout:    one line, the commit's full sha; nothing when the tree didn't change
Exit:
  0  committed, or nothing to commit
  2  refused, nothing changed; the reason is on stderr
  4  the commit failed; git-commit's reason is on stderr
USAGE
}

prog='working-commit.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' job=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --job)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) job=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
[ -n "${job}" ] && [ -f "${job}" ] || refuse '--job must be a file holding job-of.sh output'
name=$(jq -r '.name // empty' "${job}") || refuse 'the job could not be read'
[ -n "${name}" ] || refuse 'the job has no agent assigned, so no name for its Job trailer'

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
git_commit="${self%/*/*/*/*/*}/git-commit/scripts/main"
[ -f "${git_commit}/commit-tree.sh" ] || refuse "git-commit isn't beside this skill (expected ${git_commit}); install first"
. "$(dirname -- "$0")/../../../scripts/lib/trailers.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/working-commit.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
tree=$(jq -r '.tree' "${job}")
report=$(jq -r '.report' "${job}")
effort_name=$(cd -- "${effort}" && pwd -P) || refuse "${effort} can't be read"
# shellcheck disable=SC2310 # tr_message_input is one jq call, whose failure is refused here
tr_message_input "${job}" "${effort}/${report}" "${effort_name##*/}" >"${work}/input" \
	|| refuse 'the report or the job could not be read for the message'
sh "${git_commit}/commit-message.sh" --input "${work}/input" --out "${work}/message" || exit 4
rc=0
sh "${git_commit}/commit-tree.sh" --worktree "${tree}" --message-file "${work}/message" --effort "${effort}" --unsigned \
	>"${work}/made" 2>"${work}/said" || rc=$?
case ${rc} in
	0) jq -r '.commit' "${work}/made" ;;
	3) ;;
	*) sed "s/^/${prog}: /" "${work}/said" >&2; exit 4 ;;
esac
