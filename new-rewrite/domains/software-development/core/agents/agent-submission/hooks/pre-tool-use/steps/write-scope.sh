#!/usr/bin/env sh
# A step of job-agent-tools.sh: lets a job agent write where its job may,
# and nowhere else.
# shellcheck disable=SC2312 # a read inside a message only shortens the message
set -eu
# A hook fault gives no decision: Claude Code's own permissions then apply,
# so a bug here asks the human, never lets a write through.
trap 'exit 0' EXIT

usage() {
	cat <<'USAGE'
usage: sh write-scope.sh < PRE_TOOL_USE_HOOK_JSON

Run by job-agent-tools.sh for a Write or Edit; not for main to call.
For a job agent with an open job, by its job's write scope, as jobs-track
finds it: tree, its tree and its report; report, its report only. Inside:
allowed; outside: denied, the reason naming where to write; real paths
compared. A missing scope is told to the human, with no decision; main,
other types and an idle agent get no decision either.
Reads need no hook: the installer makes the space a working directory.

Reads:     stdin: agent_id, agent_type, cwd, tool_name, tool_input.file_path
Writes:    nothing
Stdout:    nothing; or {hookSpecificOutput: {hookEventName: "PreToolUse",
           permissionDecision: "allow" or "deny", permissionDecisionReason}};
           or {"systemMessage"} naming the install fault
Exit:
  0  always
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac
prog='write-scope.sh'
command -v jq >/dev/null 2>&1 || { printf '%s: jq not found; no decision\n' "${prog}" >&2; exit 0; }

input=$(cat)
fields=$(printf '%s' "${input}" | jq -r '.tool_name // "", .agent_type // "", .agent_id // "", .cwd // "",
	(.tool_input.file_path // "")' 2>/dev/null) || exit 0
tool=$(printf '%s\n' "${fields}" | sed -n 1p)
agent_type=$(printf '%s\n' "${fields}" | sed -n 2p)
agent=$(printf '%s\n' "${fields}" | sed -n 3p)
cwd=$(printf '%s\n' "${fields}" | sed -n 4p)
target=$(printf '%s\n' "${fields}" | sed -n 5p)
case ${tool} in Write | Edit) ;; *) exit 0 ;; esac

# The cheap test first: only a job-taking type is looked up.
case ${agent_type} in '' | *[!a-z0-9-]*) exit 0 ;; *) ;; esac
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*/*}
. "${skills}/jobs-agent-init/scripts/lib/agent-type.sh"
# shellcheck disable=SC2310 # at_base is a test, called for its status
at_base "${agent_type}" "${skills}" >/dev/null || exit 0
case ${agent} in '' | *[!A-Za-z0-9._-]*) exit 0 ;; *) ;; esac
[ -n "${target}" ] || exit 0
case ${target} in /*) ;; *) case ${cwd} in /*) target="${cwd}/${target}" ;; *) exit 0 ;; esac ;; esac

# The agent's open job, through jobs-track's agent-job.sh. None: an idle
# agent, given no decision.
agent_job="${skills}/jobs-track/scripts/internal/agent-job.sh"
[ -f "${agent_job}" ] || exit 0
found=$(sh "${agent_job}" --agent "${agent}" 2>/dev/null) || exit 0
effort=$(printf '%s' "${found}" | jq -r '.effort')
job=$(printf '%s' "${found}" | jq -c '.job')
kind=$(printf '%s' "${job}" | jq -r '.kind')
named="job $(printf '%s' "${job}" | jq -r '.job') ($(printf '%s' "${job}" | jq -r '.name'))"

writes=$(printf '%s' "${found}" | jq -r '.write_scope // empty')
case ${writes} in
	tree | report) ;;
	*)
		printf '%s: kind %s names no write scope, tree or report; %s'"'"'s %s gets no decision\n' \
			"${prog}" "${kind}" "${named}" "${tool}" >&2
		jq -cn --arg m "crucible: kind ${kind} names no write scope (tree or report) in jobs-define/kinds/${kind}.json or ${agent_type}/submissions/${kind}.json, so ${named}'s writes aren't scoped; Claude Code asks instead" \
			'{systemMessage: $m}'
		exit 0 ;;
esac

# Prints the real path of $1, absolute: each part that exists resolved
# through its links, the rest kept, . and .. applied as it goes.
real_path() {
	rp_done=/
	rp_rest=${1#/}
	while [ -n "${rp_rest}" ]; do
		rp_part=${rp_rest%%/*}
		case ${rp_rest} in */*) rp_rest=${rp_rest#*/} ;; *) rp_rest='' ;; esac
		case ${rp_part} in
			'' | .) continue ;;
			..) rp_done=$(dirname -- "${rp_done}"); continue ;;
			*) ;;
		esac
		rp_next="${rp_done%/}/${rp_part}"
		if [ -d "${rp_next}" ]; then
			rp_done=$(cd -P -- "${rp_next}" && pwd -P) || return 1
		elif [ -L "${rp_next}" ]; then
			rp_link=$(readlink -- "${rp_next}") || return 1
			case ${rp_link} in /*) ;; *) rp_link="${rp_done%/}/${rp_link}" ;; esac
			# shellcheck disable=SC2310 # the link's own real path, its failure returned
			rp_done=$(real_path "${rp_link}") || return 1
		else
			rp_done=${rp_next}
		fi
	done
	printf '%s\n' "${rp_done}"
}
# Succeeds when real path $1 is folder $2 or inside it.
inside() { case $1 in "$2" | "$2"/*) return 0 ;; *) return 1 ;; esac; }
decide() { # decide allow|deny REASON
	jq -cn --arg d "$1" --arg r "$2" '{hookSpecificOutput: {hookEventName: "PreToolUse",
		permissionDecision: $d, permissionDecisionReason: $r}}'
	exit 0
}

tree=$(real_path "$(printf '%s' "${job}" | jq -r '.tree')")
report=$(real_path "${effort}/$(printf '%s' "${job}" | jq -r '.report')")
path=$(real_path "${target}")

[ "${path}" != "${report}" ] || decide allow "${named} writes its report"
if [ "${writes}" = tree ]; then
	# shellcheck disable=SC2310 # inside is a test, called for its status
	! inside "${path}" "${tree}" || decide allow "${named} writes in its tree"
	decide deny "Write only in ${tree} and to your report ${report}."
fi
decide deny "Write only your report ${report}."
