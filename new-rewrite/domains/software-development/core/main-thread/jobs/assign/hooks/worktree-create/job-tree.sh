#!/usr/bin/env sh
# WorktreeCreate: answers the tree of the job agent being started.
set -eu

usage() {
	cat <<'USAGE'
usage: sh job-tree.sh < WORKTREE_CREATE_HOOK_JSON

Run by Claude Code (WorktreeCreate); not for main to call.
Answers with the tree of the job whose start this session claimed, so the
agent works in its job's tree. Any other tree start gets what Claude Code
makes without this hook: a git worktree of cwd's repository at
.claude/worktrees/NAME, on a new branch worktree-NAME, from HEAD.

Reads:     stdin: session_id, cwd, name; CLAUDE_CONFIG_DIR
Writes:    for a start no job claimed, that worktree
Stdout:    the tree's path
Exit:
  0  answered
  1  the job's tree is gone, or the default tree can't be made; stderr says
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
prog='job-tree.sh'
command -v jq >/dev/null 2>&1 || { printf '%s: jq not found\n' "${prog}" >&2; exit 1; }
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
. "${self%/*/*/*}/scripts/lib/notes.sh"

input=$(cat)
session=$(printf '%s' "${input}" | jq -r '.session_id // empty' 2>/dev/null) || session=''
# shellcheck disable=SC2310 # nt_set_dir fails for an unsafe id
nt_set_dir "${session}" || nt_dir=''
for claimed in ${nt_dir:+"${nt_dir}"/claimed-*.json}; do
	[ -f "${claimed}" ] || continue
	path=$(jq -r '.path // empty' "${claimed}")
	[ -n "${path}" ] && [ -d "${path}" ] || { printf '%s: job %s has no tree at %s\n' "${prog}" "$(jq -r '.job' "${claimed}")" "${path}" >&2; exit 1; }
	printf '%s\n' "${path}"
	exit 0
done
# No job's start: step aside, as Claude Code would without this hook.
cwd=$(printf '%s' "${input}" | jq -r '.cwd // empty')
name=$(printf '%s' "${input}" | jq -r '.name // empty')
case ${name} in '' | *[!A-Za-z0-9._-]*) printf '%s: no usable worktree name in the hook input\n' "${prog}" >&2; exit 1 ;; *) ;; esac
top=$(git -C "${cwd:-.}" rev-parse --show-toplevel 2>/dev/null) || { printf '%s: %s is not in a git repository, so no worktree can be made\n' "${prog}" "${cwd}" >&2; exit 1; }
path="${top}/.claude/worktrees/${name}"
git -C "${top}" worktree add -q -b "worktree-${name}" "${path}" HEAD >&2 || { printf '%s: git could not make %s\n' "${prog}" "${path}" >&2; exit 1; }
printf '%s\n' "${path}"
