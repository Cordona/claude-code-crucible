#!/usr/bin/env sh
# SubagentStart: a fresh job agent took its job: agent.initialized and
# job.assigned, from the door's claimed note.
set -eu
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh job-assigned.sh < SUBAGENT_START_HOOK_JSON

Run by Claude Code (SubagentStart); not for main to call.
For a job agent this session started from the door's call: writes
agent.initialized (its base, type and plugins) and job.assigned (its job
and tree) to the job's effort, then clears the claim. A resumed agent, and
any other agent, is passed by.

Reads:     stdin: session_id, agent_id, agent_type; CLAUDE_CONFIG_DIR
Writes:    agent.initialized and job.assigned; a fault on stderr
Stdout:    nothing
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
prog='job-assigned.sh'
command -v jq >/dev/null 2>&1 || exit 0
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
writer="${skills}/crucible-events/scripts/internal/event-write.sh"
. "${self%/*/*/*}/scripts/lib/notes.sh"
. "${skills}/jobs-agent-init/scripts/lib/agent-type.sh"

input=$(cat)
type=$(printf '%s' "${input}" | jq -r '.agent_type // empty' 2>/dev/null) || exit 0
# shellcheck disable=SC2310 # at_base is a test, called for its status
at_base "${type}" "${skills}" >/dev/null || exit 0
agent=$(printf '%s' "${input}" | jq -r '.agent_id // empty')
case ${agent} in '' | *[!A-Za-z0-9._-]*) exit 0 ;; *) ;; esac
# shellcheck disable=SC2310 # nt_set_dir fails for an unsafe id
nt_set_dir "$(printf '%s' "${input}" | jq -r '.session_id // empty')" || exit 0

for claimed in "${nt_dir}"/claimed-*.json; do
	[ -f "${claimed}" ] || continue
	[ "$(jq -r '.subagent_type' "${claimed}")" = "${type}" ] || continue
	effort=$(jq -r '.effort' "${claimed}")
	work=$(mktemp -d "${TMPDIR:-/tmp}/job-assigned.XXXXXX") || exit 0
	jq --arg a "${agent}" '{agent: $a, base, type: .subagent_type, plugins}' "${claimed}" >"${work}/init"
	jq --arg a "${agent}" '{job, agent: $a, tree}' "${claimed}" >"${work}/assigned"
	for step in "agent.initialized init" "job.assigned assigned"; do
		# shellcheck disable=SC2086 # the step is two words, split on purpose
		set -- ${step}
		sh "${writer}" --effort "${effort}" --type "$1" --by "${prog}" --body-file "${work}/$2" >/dev/null 2>"${work}/said" \
			|| printf '%s: agent %s, job %s: %s not written: %s\n' "${prog}" "${agent}" "$(jq -r '.job' "${claimed}")" "$1" "$(cat "${work}/said")" >&2
	done
	rm -rf -- "${work}" "${claimed}"
	exit 0
done
