#!/bin/sh
# Spike hook, PreToolUse on Read, Grep, Glob and Bash (main only). The lab's
# stand-in for the framework's deny-internals-read.sh: the same rule and the
# same deny reason, mapped onto the lab's flat layout. Main may read and run
# the scripts it is given (the real scripts/main/ and SKILL.md); everything
# else in the lab (hooks, libraries, jq rules, the real copies' internals,
# the agents, the runner) is internal and refused.
set -eu
trap 'exit 0' EXIT
LAB=$(cd "$(dirname "$0")" && pwd -P)
in=$(cat)
MAIN_FACING='choose.sh next.sh gate.sh import.sh job-dispatch.sh loop-end.sh merge.sh remote.sh round.sh'
fields=$(printf '%s' "$in" | jq -r '(.tool_name // "") as $tool
	| $tool, (.agent_id // "" | tostring), .cwd // "",
	(.tool_input // {} | if $tool == "Read" then .file_path // empty
		elif $tool == "Grep" then .path // empty
		elif $tool == "Glob" then (.path // empty), (.pattern // "" | select(startswith("/")))
		elif $tool == "Bash" then .command // "" | splits("[\\s;&|()<>`]+")
			| gsub("[\"'"'"'\\\\]"; "") | sub("^[^/]*="; "")
		else empty end | strings)' 2>/dev/null) || exit 0
tool=$(printf '%s\n' "$fields" | sed -n 1p)
agent=$(printf '%s\n' "$fields" | sed -n 2p)
cwd=$(printf '%s\n' "$fields" | sed -n 3p)
case $tool in Read | Grep | Glob | Bash) ;; *) exit 0 ;; esac
[ -z "$agent" ] || exit 0
internal=''
while IFS= read -r t; do
	[ -n "$t" ] || continue
	case $t in /*) p=$t ;; *) p=$cwd/$t ;; esac
	d=$(dirname "$p"); r=$(cd -P "$d" 2>/dev/null && pwd -P)/$(basename "$p") || r=$p
	case $r/ in "$LAB"/) continue ;; "$LAB"/*) ;; *) continue ;; esac
	rel=${r#"$LAB"/}
	case $rel in
		real/crucible-gate/scripts/main/* | real/crucible-gate/SKILL.md) continue ;;
		*/*) internal=1; break ;;
	esac
	case " $MAIN_FACING " in *" $rel "*) continue ;; esac
	internal=1; break
done <<EOF
$(printf '%s\n' "$fields" | sed 1,3d)
EOF
[ -n "$internal" ] || exit 0
jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
	permissionDecisionReason: "crucible: internal to the Crucible framework; use the skill'"'"'s scripts/main/ and each script'"'"'s --help. If a script misbehaves, tell the human its name and its message."}}'
