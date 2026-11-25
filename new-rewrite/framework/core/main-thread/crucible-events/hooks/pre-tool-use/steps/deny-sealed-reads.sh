#!/usr/bin/env sh
# A step of guard-framework.sh, for Read, Grep, Glob and Bash: denies main
# and agents a path into a component's sealed folders, by mistake, from
# another project.
set -eu
# A hook fault allows the call: it sits on every Read, Grep, Glob and Bash
# call, and a bug here must never block the human.
trap 'exit 0' EXIT

usage() {
	cat <<'EOF'
usage: sh deny-sealed-reads.sh < HOOK_JSON

Run by guard-framework.sh for a Read, Grep, Glob or Bash call; not for main
to call. Denies a path the call names whose real path is in a sealed
folder: scripts/internal/, scripts/lib/, hooks/, events/, submissions/, and
for an agent also scripts/main/. Everything else stays readable. Stands
aside for a session in the framework's own repository. It stops a mistake,
a model wandering into the internals; it is not a wall against a command
built to get round it.

Reads:     stdin: tool_name, agent_id, cwd, tool_input.file_path, .path,
           .pattern, .command
Writes:    nothing
Stdout:    nothing; or {hookSpecificOutput: {hookEventName: "PreToolUse",
           permissionDecision: "deny", permissionDecisionReason}}
Exit:
  0  always; on a fault (jq or realpath missing, input not JSON) no answer,
     a note on stderr
EOF
}

case ${1-} in -h | --help) usage; exit 0 ;; *) ;; esac

allow_unchecked() {
	printf 'deny-sealed-reads.sh: %s; the call is allowed unchecked\n' "$1" >&2
	exit 0
}

input=$(cat)
command -v jq >/dev/null 2>&1 || allow_unchecked 'jq missing'
command -v realpath >/dev/null 2>&1 || allow_unchecked 'realpath missing'

# One line each: the tool, the agent id, the working folder, then one target
# per line. A Bash command's targets are its words that name a covered folder,
# quotes dropped and any NAME= or --option= prefix cut.
fields=$(printf '%s' "${input}" | jq -r '(.tool_name // "") as $tool
	| $tool, (.agent_id // "" | tostring), .cwd // "",
	(.tool_input // {} | if $tool == "Read" then .file_path // empty
		elif $tool == "Grep" then .path // empty
		elif $tool == "Glob" then (.path // empty), (.pattern // "" | select(startswith("/")))
		elif $tool == "Bash" then .command // "" | splits("[\\s;&|()<>`]+")
			| gsub("[\"'"'"'\\\\]"; "") | sub("^[^/]*="; "")
			| select(test("scripts/internal|scripts/lib|scripts/main|hooks|events|submissions"))
		else empty end | strings)' 2>/dev/null) \
	|| allow_unchecked 'the hook input is not JSON'

tool=$(printf '%s\n' "${fields}" | sed -n 1p)
agent=$(printf '%s\n' "${fields}" | sed -n 2p)
cwd=$(printf '%s\n' "${fields}" | sed -n 3p)
case ${tool} in Read | Grep | Glob | Bash) ;; *) exit 0 ;; esac
targets=$(printf '%s\n' "${fields}" | sed 1,3d)

# The framework root, from this hook's real place: the folder that holds
# framework/. The installed skills link into it.
root=$(cd -P -- "$(dirname -- "$0")/../../../../../../.." && pwd -P)

# The git repository that holds the framework, or the root itself outside one.
repo=${root}
while [ ! -e "${repo}/.git" ]; do
	case ${repo} in */*/*) repo=${repo%/*} ;; *) repo=${root}; break ;; esac
done

# A session working in that repository reads and edits anything.
if [ -n "${cwd}" ]; then
	here=$(cd -P -- "${cwd}" 2>/dev/null && pwd -P) || here=${cwd}
	case ${here}/ in "${repo}"/*) exit 0 ;; *) ;; esac
fi

# Prints the real path of $1: its deepest existing part resolved, the rest
# appended as written. A relative path is taken from the working folder.
resolve() {
	path=$1
	# shellcheck disable=SC2088,SC2016 # matched as written in the command text
	case ${path} in
		'~') path=${HOME} ;;
		'~/'* | '$HOME/'* | '${HOME}/'*) path=${HOME}/${path#*/} ;;
		/*) ;;
		*) [ -n "${cwd}" ] || return 0; path=${cwd}/${path} ;;
	esac
	head=${path} rest=''
	while [ ! -e "${head}" ] && [ ! -L "${head}" ]; do
		rest=/${head##*/}${rest}
		head=${head%/*}
		[ -n "${head}" ] || { head=/; break; }
	done
	real=$(realpath -- "${head}" 2>/dev/null) || real=${head}
	printf '%s%s\n' "${real%/}" "${rest}"
}

# Succeeds when real path $1 is in a folder sealed to main and agents, or,
# for an agent's call, in scripts/main/ too.
sealed() {
	case $1/ in
		"${root}"/*/scripts/internal/* | "${root}"/*/scripts/lib/* | "${root}"/*/hooks/* \
			| "${root}"/*/events/* | "${root}"/*/submissions/*)
			return 0 ;;
		"${root}"/*/scripts/main/*) [ -n "${agent}" ] ;;
		*) return 1 ;;
	esac
}

hit=''
while IFS= read -r target; do
	[ -n "${target}" ] || continue
	real=$(resolve "${target}")
	# shellcheck disable=SC2310 # sealed is a test, called for its status
	if sealed "${real}"; then hit=1; break; fi
done <<EOF
${targets}
EOF

[ -n "${hit}" ] || exit 0
if [ -n "${agent}" ]; then
	reason="crucible: sealed in the Crucible framework; an agent works in its tree and writes its report, and needs none of the framework's scripts."
else
	reason="crucible: internal to the Crucible framework; use the skill's scripts/main/ and each script's --help. If a script misbehaves, tell the human its name and its message."
fi
jq -n --arg r "${reason}" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
