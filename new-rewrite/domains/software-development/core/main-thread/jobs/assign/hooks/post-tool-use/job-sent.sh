#!/usr/bin/env sh
# PostToolUse, SendMessage: a hot job sent as the door printed it:
# job.assigned.
set -eu
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh job-sent.sh < POST_TOOL_USE_HOOK_JSON

Run by Claude Code (PostToolUse, SendMessage); not for main to call.
A message to an agent the door has a hot note for, with the door's exact
text, assigns that job to the agent: job.assigned. Any other message is
passed by.

Reads:     stdin: session_id, tool_name, tool_input.to, tool_input.message;
           CLAUDE_CONFIG_DIR
Writes:    job.assigned; a fault on stderr
Stdout:    nothing
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
prog='job-sent.sh'
command -v jq >/dev/null 2>&1 || exit 0
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
writer="${skills}/crucible-events/scripts/internal/event-write.sh"
. "${self%/*/*/*}/scripts/lib/notes.sh"

input=$(cat)
[ "$(printf '%s' "${input}" | jq -r '.tool_name // empty' 2>/dev/null)" = SendMessage ] || exit 0
to=$(printf '%s' "${input}" | jq -r '.tool_input.to // empty')
case ${to} in '' | *[!A-Za-z0-9._-]*) exit 0 ;; *) ;; esac
# shellcheck disable=SC2310 # nt_set_dir fails for an unsafe id
nt_set_dir "$(printf '%s' "${input}" | jq -r '.session_id // empty')" || exit 0
message=$(printf '%s' "${input}" | jq -r '.tool_input.message // empty')

for note in "${nt_dir}"/hot-"${to}"-*.json; do
	[ -f "${note}" ] || continue
	[ "$(jq -r '.message' "${note}")" = "${message}" ] || continue
	work=$(mktemp -d "${TMPDIR:-/tmp}/job-sent.XXXXXX") || exit 0
	jq '{job, agent, tree}' "${note}" >"${work}/assigned"
	sh "${writer}" --effort "$(jq -r '.effort' "${note}")" --type job.assigned --by "${prog}" --body-file "${work}/assigned" >/dev/null 2>"${work}/said" \
		|| printf '%s: agent %s, job %s: job.assigned not written: %s\n' "${prog}" "${to}" "$(jq -r '.job' "${note}")" "$(cat "${work}/said")" >&2
	rm -rf -- "${work}" "${note}"
	exit 0
done
