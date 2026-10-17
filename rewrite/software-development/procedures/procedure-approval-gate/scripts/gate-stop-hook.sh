#!/usr/bin/env sh
# Claude Code Stop hook for approval gates. While this session's gate is
# pending, it checks that the turn-ending message relays gate.md word for word
# and ends with the marker line: a good relay marks the gate relayed and keeps
# Claude going with "now ask"; a bad one keeps it going with "relay again", at
# most twice, then marks the gate failed and lets the stop through.
# Claude continues through hookSpecificOutput.additionalContext, which Claude
# Code shows as "Stop hook feedback".
# It never early-returns on stop_hook_active, because several gates may open in
# one turn and each gate's tries cap ends its own loop: it always ends by
# letting the stop through. Claude Code's own continuation cap (env
# CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) also applies; its default is in the Claude
# Code hooks docs, https://code.claude.com/docs/en/hooks ("Stop input").
set -eu
# Every outcome exits 0: a hook fault must allow the stop, never keep Claude
# going (exit 2 would), so the EXIT trap turns any failure into 0.
trap 'exit 0' EXIT

readonly PROG='gate-stop-hook.sh'
readonly MARKER='_Crucible gate_'
# 30 min: long enough to read a plan, short enough that a gate left open by a
# crashed or abandoned turn soon stops denying questions.
readonly STALE_SECONDS=1800
readonly STALE_MINUTES=$((STALE_SECONDS / 60))
# 2 retries: one or two corrections fix a copy slip; a relay that still doesn't
# match won't, so the stop goes through instead of looping.
readonly MAX_RELAY_RETRIES=2
readonly ASK_REASON='procedure-approval-gate: the plan was relayed; its approval question is now allowed.'

# Prints "good" when the message relays the gate; "unverifiable" when
# last_assistant_message is missing or not a string; otherwise the cause:
# "text", "marker" or "both". Both texts are normalized (CR dropped, trailing
# spaces per line removed, blank-line runs collapsed to one, leading and
# trailing blank lines dropped) before the substring check; the last non-empty
# line, trimmed, must be the marker.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly RELAY_JQ='
def lines: gsub("\r"; "") | split("\n") | map(sub("[ \t]+$"; ""));
def norm: lines
	| reduce .[] as $line ([]; if $line == "" and length > 0 and .[-1] == "" then . else . + [$line] end)
	| until(length == 0 or .[0] != ""; .[1:])
	| until(length == 0 or .[-1] != ""; .[:-1])
	| join("\n");
if (.last_assistant_message | type) != "string" then "unverifiable"
else .last_assistant_message as $message
	| ($message | norm | contains($gate | norm)) as $has_text
	| ([$message | lines[] | sub("^[ \t]+"; "") | select(. != "")] | last == $marker) as $has_marker
	| if $has_text and $has_marker then "good"
	  elif $has_marker then "text"
	  elif $has_text then "marker"
	  else "both" end
end
'

usage() {
	cat <<EOF
Usage: sh ${PROG} < stop-hook-input.json

A Claude Code Stop hook. It reads session_id and last_assistant_message from
the hook JSON on stdin, and the gate state open-gate.sh wrote in
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session_id>/
  - no gate; a relayed, shown or failed gate; or a malformed gate or one
    older than ${STALE_SECONDS}s (removed with its folder, plan.json included):
    prints nothing, allows the stop
  - no gate state, and a plan.json there older than ${STALE_SECONDS}s: removes
    the folder, allows the stop
  - pending, good relay: state becomes relayed; prints the "now ask" context
  - pending, last_assistant_message missing or not a string (the relay can't
    be verified): state becomes relayed, no try is counted; prints the same
    "now ask" context, with a note on stderr
  - pending, bad relay: tries + 1; up to ${MAX_RELAY_RETRIES} tries prints the "relay again" context;
    above that the state becomes failed and the stop is allowed, no output
Output shape: {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"..."}}
  "now ask": ${ASK_REASON}
  "relay again": procedure-approval-gate: relay try <n> of ${MAX_RELAY_RETRIES} failed: <cause>.
             The gate is still pending, so its question stays denied until a
             turn's last message holds the full text open-gate.sh printed and
             ends with the line ${MARKER}.
  <cause> is one of: the gate text is missing from the last message | the
  last message's last non-empty line is not ${MARKER} | the gate text is
  missing and the last non-empty line is not ${MARKER}

Exit codes: always 0 (a hook fault allows the stop; a note goes to stderr).

Dependencies: POSIX sh, jq 1.6+, cat, date, find (with -mmin, as on macOS and
Linux), mktemp, mv, rm.
Runtime: about 12 ms with no gate, 31 ms checking a relay; measured on macOS (average of 5 runs).
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Writes the state line "$1 $2 $3" atomically, or warns and exits 0.
write_state() {
	state_temp=$(mktemp "${gate_dir}/state.XXXXXX") || {
		warn "cannot create a temp file in ${gate_dir}; expected a writable gate folder; stop allowed; check the folder's owner and free space"
		exit 0
	}
	if printf '%s %s %s\n' "$1" "$2" "$3" >"${state_temp}" && mv -f "${state_temp}" "${gate_dir}/state"; then
		return 0
	fi
	rm -f "${state_temp}"
	warn "cannot write ${gate_dir}/state; expected a writable gate folder; stop allowed; check the folder's owner and free space"
	exit 0
}

# Prints Stop-hook additionalContext $1, which makes Claude continue.
continue_with() {
	jq -cn --arg context "$1" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $context}}'
}

# Prints the relay context for try $1 and cause code $2.
relay_reason() {
	case $2 in
		text) cause='the gate text is missing from the last message' ;;
		marker) cause="the last message's last non-empty line is not ${MARKER}" ;;
		*) cause="the gate text is missing and the last non-empty line is not ${MARKER}" ;;
	esac
	printf 'procedure-approval-gate: relay try %s of %s failed: %s. The gate is still pending, so its question stays denied until a turn'"'"'s last message holds the full text open-gate.sh printed and ends with the line %s.' \
		"$1" "${MAX_RELAY_RETRIES}" "${cause}" "${MARKER}"
}

# Sets gate_status, tries and created from a live gate, or exits 0 when there
# is none: no state (a stale plan.json alone is removed), a malformed or stale
# one (both removed), or no gate.md.
load_gate() {
	gate_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate/$1"
	[ -f "${gate_dir}/state" ] || drop_stale_plan
	read -r gate_status tries created _ <"${gate_dir}/state" || true
	case ${gate_status-}:${tries-}:${created-} in
		pending:*:* | relayed:*:* | shown:*:* | failed:*:*) ;;
		*) remove_gate 'malformed state' ;;
	esac
	case ${tries-}:${created-} in
		:* | *: | *[!0-9:]* | *:*:*) remove_gate 'malformed state' ;;
		*) ;;
	esac
	now=$(date +%s)
	[ $((now - created)) -le "${STALE_SECONDS}" ] || remove_gate 'stale gate'
	[ -f "${gate_dir}/gate.md" ] || remove_gate 'gate.md missing'
}

# With no gate state, removes the folder when its plan.json is older than
# STALE_SECONDS; allows the stop either way.
drop_stale_plan() {
	old_plan=$(find "${gate_dir}/plan.json" -prune -type f -mmin "+${STALE_MINUTES}" 2>/dev/null) || exit 0
	[ -z "${old_plan}" ] || remove_gate 'stale plan.json with no gate state'
	exit 0
}

# Removes the gate folder (reason $1 goes to stderr) and allows the stop.
remove_gate() {
	warn "$1 removed: ${gate_dir}"
	rm -rf "${gate_dir}"
	exit 0
}

case ${1-} in
	--help | -h)
		usage
		exit 0
		;;
	*) ;;
esac

command -v jq >/dev/null 2>&1 || {
	warn 'jq missing; expected jq 1.6+ on PATH; stop allowed; check that jq is installed on the PATH Claude Code runs hooks with'
	exit 0
}
hook_input=$(cat)
session_id=$(printf '%s' "${hook_input}" | jq -r '.session_id // empty | strings')
case ${session_id} in
	'' | . | .. | *[!A-Za-z0-9._-]*) exit 0 ;;
	*) ;;
esac
load_gate "${session_id}"
[ "${gate_status}" = pending ] || exit 0

relay=$(printf '%s' "${hook_input}" | jq -r --rawfile gate "${gate_dir}/gate.md" --arg marker "${MARKER}" "${RELAY_JQ}")
case ${relay} in
	good)
		write_state relayed "${tries}" "${created}"
		continue_with "${ASK_REASON}"
		exit 0
		;;
	unverifiable)
		warn 'last_assistant_message missing or not a string; relay not verifiable, gate marked relayed'
		write_state relayed "${tries}" "${created}"
		continue_with "${ASK_REASON}"
		exit 0
		;;
	*) ;;
esac
tries=$((tries + 1))
if [ "${tries}" -gt "${MAX_RELAY_RETRIES}" ]; then
	write_state failed "${tries}" "${created}"
	exit 0
fi
write_state pending "${tries}" "${created}"
reason=$(relay_reason "${tries}" "${relay}")
continue_with "${reason}"
