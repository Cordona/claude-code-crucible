#!/bin/sh
# Spike hook, PreToolUse on every tool, main and agents.
# - Nobody writes the events folder with Write or Edit.
# - A lab agent with no open job may not write at all.
# - A reviewing agent writes only its report; a builder or tester writes its tree and its report.
set -eu
LAB=$(cd "$(dirname "$0")" && pwd); . "$LAB/lib.sh"
in=$(cat); log_hook scope "$in"
tool=$(printf '%s' "$in" | jq -r .tool_name)
aid=$(printf '%s' "$in" | jq -r '.agent_id // ""')
atype=$(printf '%s' "$in" | jq -r '.agent_type // ""')
fp=$(printf '%s' "$in" | jq -r '.tool_input.file_path // ""')
case "$tool" in Write|Edit) case "$fp" in "$EFFORT"/events/*) deny_pre "events are written only by the lab scripts" ;; esac ;; esac
[ -n "$aid" ] || exit 0
case "$atype" in lab-*) ;; *) exit 0 ;; esac
case "$tool" in Write|Edit|Bash) ;; Read|Grep|Glob) [ -n "${SCOPE_GRANT:-}" ] || exit 0 ;; *) exit 0 ;; esac
# with SCOPE_GRANT set, what the job covers is allowed outright, so an
# unattended agent never waits on a permission prompt
grant() { [ -n "${SCOPE_GRANT:-}" ] && jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"covered by the job"}}'; exit 0; }
job=$(wait_job_of_agent "$aid")
[ -n "$job" ] || deny_pre "no open job for this agent: wait for your JOB line"
report=$(job_event "$job" | jq -r '.body.report')
if [ "$tool" = Read ] || [ "$tool" = Grep ] || [ "$tool" = Glob ]; then
	p=$(printf '%s' "$in" | jq -r '.tool_input.file_path // .tool_input.path // ""')
	tree=$(job_event "$job" | jq -r '.body.tree // ""')
	case "$p" in "$EFFORT"/*) grant ;; esac
	[ -z "$tree" ] || case "$p" in "$tree"/*|"$tree") grant ;; esac
	exit 0
fi
case "$atype" in
lab-reviewer|lab-challenger|lab-arbiter)
	# the one shell call a reviewing stand-in may make: the wait its act names
	if [ "$tool" = Bash ]; then
		w=$(job_event "$job" | jq -r '.body.act.wait // empty')
		c=$(printf '%s' "$in" | jq -r '.tool_input.command // ""')
		[ -n "$w" ] && [ "$c" = "perl -e 'select(undef,undef,undef,$w)'" ] && grant
		deny_pre "a reviewing agent has no shell"
	fi
	[ "$fp" = "$report" ] || deny_pre "you write only your report: $report"
	grant ;;
*)
	[ "$tool" = Bash ] && grant
	tree=$(job_event "$job" | jq -r '.body.tree // ""')
	[ "$fp" = "$report" ] && grant
	case "$fp" in "$tree"/*) grant ;; esac
	deny_pre "write only inside your tree $tree or your report $report" ;;
esac
exit 0
