#!/bin/sh
# Probe hook: hook.sh EVENT. Logs its stdin JSON, with start and end
# timestamps, to one file per call under $S/logs/hooks/. For SubagentStop it
# applies the policy of the stopping agent's type, from $S/policy/<type>:
#   BLOCK_N  block the first N stops of each agent_id (default 0)
#   SLEEP    sleep this many seconds before answering the first stop (default 0)
#   BARRIER  wait (up to 40 s) until this many agents have reached the hook
#   LOCK     hold a shared mkdir lock this many seconds, then write a commit
# The block reason carries one line starting "TOKEN:" naming the agent_id.
ev=$1
S=$(cd "$(dirname "$0")/.." && pwd)
L="$S/logs/hooks"; mkdir -p "$L" "$S/state"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
t0=$(now)
in=$(cat)
f=$(mktemp "$L/$ev-$t0-XXXX")
note() { printf '%s %s\n' "$(now)" "$1" >>"$f.trace"; }
printf '%s\n' "$in" | jq -c --arg t "$t0" --arg ev "$ev" '{t_start: ($t|tonumber), event: $ev, input: .}' >"$f" 2>/dev/null \
	|| printf '{"t_start":%s,"event":"%s","raw":%s}\n' "$t0" "$ev" "$(printf '%s' "$in" | jq -Rs .)" >"$f"
# With $S/policy/dump-env present, record the hook's own BASH_ env vars.
[ ! -f "$S/policy/dump-env" ] || { env | grep BASH_ || echo "none"; } >"$f.env"
trap 'note "signal TERM"; exit 143' TERM
trap 'note "signal INT"; exit 130' INT
trap 'note "signal HUP"; exit 129' HUP
# PreToolUse: with $S/policy/pretool-deny-bg present, deny every Bash call
# that asks for run_in_background.
if [ "$ev" = PreToolUse ] && [ -f "$S/policy/pretool-deny-bg" ] &&
	printf '%s' "$in" | jq -e '.tool_name == "Bash" and .tool_input.run_in_background == true' >/dev/null; then
	note "deny background Bash for agent $(printf '%s' "$in" | jq -r '.agent_id // "main"')"
	jq -nc '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
		permissionDecisionReason: "TOKEN: background shells are refused for this agent; run the command in the foreground"}}'
	exit 0
fi
# PreToolUse: with $S/policy/pretool-add-timeout present, rewrite a
# sub-agent's Bash call that has no timeout to carry timeout 600000.
if [ "$ev" = PreToolUse ] && [ -f "$S/policy/pretool-add-timeout" ] &&
	printf '%s' "$in" | jq -e '.tool_name == "Bash" and .agent_id != null and .tool_input.timeout == null' >/dev/null; then
	note "add timeout for agent $(printf '%s' "$in" | jq -r '.agent_id')"
	# File content "nodecision": send updatedInput with no permissionDecision.
	printf '%s' "$in" | jq -c --arg m "$(cat "$S/policy/pretool-add-timeout")" '{hookSpecificOutput: ({hookEventName: "PreToolUse",
		updatedInput: (.tool_input + {timeout: 600000})} + (if $m == "nodecision" then {} else {permissionDecision: "allow"} end))}'
	exit 0
fi
# PreToolUse: with $S/policy/write-gate present (sets WG_ALLOW and WG_DENY,
# space-separated path prefixes), a sub-agent's Write, Edit or Read under a
# WG_ALLOW prefix is allowed, and its Write or Edit under a WG_DENY prefix is
# denied with WG_REASON. WG_TOOLS (default Write|Edit|Read) narrows the tools.
if [ "$ev" = PreToolUse ] && [ -f "$S/policy/write-gate" ] &&
	printf '%s' "$in" | jq -e '(.tool_name | test("^(Write|Edit|Read)$")) and .agent_id != null' >/dev/null; then
	WG_ALLOW='' WG_DENY='' WG_REASON='' WG_TOOLS='Write|Edit|Read'
	. "$S/policy/write-gate"
	printf '%s' "$in" | jq -e --arg t "^($WG_TOOLS)$" '.tool_name | test($t)' >/dev/null || exit 0
	fp=$(printf '%s' "$in" | jq -r '.tool_input.file_path')
	tn=$(printf '%s' "$in" | jq -r '.tool_name')
	for p in $WG_ALLOW; do case $fp in "$p"*)
		note "write-gate allow $tn $fp"
		jq -nc '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow"}}'; exit 0 ;; esac; done
	if [ "$tn" != Read ]; then for p in $WG_DENY; do case $fp in "$p"*)
		note "write-gate deny $tn $fp"
		jq -nc --arg r "$WG_REASON" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'; exit 0 ;; esac; done; fi
	note "write-gate no decision $tn $fp"
fi
# PreToolUse: with $S/policy/pretool-agent-cwd present, add its content as a
# "cwd" key to every Agent call's input (allow).
if [ "$ev" = PreToolUse ] && [ -f "$S/policy/pretool-agent-cwd" ] &&
	printf '%s' "$in" | jq -e '.tool_name == "Agent"' >/dev/null; then
	note "add cwd to Agent input"
	printf '%s' "$in" | jq -c --arg d "$(cat "$S/policy/pretool-agent-cwd")" '{hookSpecificOutput: {hookEventName: "PreToolUse",
		permissionDecision: "allow", updatedInput: (.tool_input + {cwd: $d})}}'
	exit 0
fi
# PermissionRequest: with $S/policy/permreq-deny present (sets PR_MSG, and
# PR_SKIP, an ERE on the command left unanswered), answer a sub-agent's ask
# with deny and PR_MSG. Main's asks (no agent_id) get no answer.
if [ "$ev" = PermissionRequest ] && [ -f "$S/policy/permreq-deny" ]; then
	PR_MSG='' PR_SKIP='^$'
	. "$S/policy/permreq-deny"
	if ! printf '%s' "$in" | jq -e '.agent_id != null' >/dev/null; then note "permreq main: no answer"; exit 0; fi
	if printf '%s' "$in" | jq -e --arg r "$PR_SKIP" '(.tool_input.command // "") | test($r)' >/dev/null; then note "permreq skip: no answer"; exit 0; fi
	note "permreq deny"
	jq -nc --arg m "$PR_MSG" '{hookSpecificOutput: {hookEventName: "PermissionRequest", decision: {behavior: "deny", message: $m}}}'
	exit 0
fi
# Any event: $S/policy/out-<event> present is printed as the hook's output.
if [ -f "$S/policy/out-$ev" ]; then note "printed out-$ev"; cat "$S/policy/out-$ev"; exit 0; fi
# PostToolUse: $S/policy/post-<tool_name> may set POST_SLEEP seconds.
if [ "$ev" = PostToolUse ]; then
	tn=$(printf '%s' "$in" | jq -r '.tool_name')
	POST_SLEEP=0
	[ ! -f "$S/policy/post-$tn" ] || . "$S/policy/post-$tn"
	if [ "$POST_SLEEP" -gt 0 ]; then note "post sleep $POST_SLEEP"; sleep "$POST_SLEEP"; note "post slept"; fi
fi
[ "$ev" = SubagentStop ] || exit 0

aid=$(printf '%s' "$in" | jq -r '.agent_id // "none"')
typ=$(printf '%s' "$in" | jq -r '.agent_type // "none"')
BLOCK_N=0 SLEEP=0 BARRIER=0 LOCK=0
[ ! -f "$S/policy/$typ" ] || . "$S/policy/$typ"
n=$(($(cat "$S/state/$aid.count" 2>/dev/null || echo 0) + 1))
echo "$n" >"$S/state/$aid.count"
note "stop $n agent $aid type $typ"

if [ "$BARRIER" -gt 0 ] && [ "$n" -eq 1 ]; then
	: >"$S/state/barrier-$aid"
	i=0
	while [ "$(ls "$S/state" | grep -c '^barrier-')" -lt "$BARRIER" ] && [ $i -lt 200 ]; do sleep 0.2; i=$((i + 1)); done
	note "barrier passed with $(ls "$S/state" | grep -c '^barrier-')"
fi
if [ "$SLEEP" -gt 0 ] && [ "$n" -eq 1 ]; then note "sleep $SLEEP"; sleep "$SLEEP"; note "slept"; fi
if [ "$LOCK" -gt 0 ] && [ "$n" -eq 1 ]; then
	note "lock wait"
	until mkdir "$S/state/lock" 2>/dev/null; do sleep 0.1; done
	note "lock held"
	sleep "$LOCK"
	printf '%s %s\n' "$(now)" "$aid" >>"$S/state/commits"
	rmdir "$S/state/lock"
	note "lock released, committed"
fi
if [ "$n" -le "$BLOCK_N" ]; then
	reason="Your stop is held by a probe hook. TOKEN: block $n of $BLOCK_N for agent $aid (type $typ)"
	note "block $n"
	jq -nc --arg r "$reason" '{decision: "block", reason: $r}'
else
	note "allow"
fi
note "end"
exit 0
