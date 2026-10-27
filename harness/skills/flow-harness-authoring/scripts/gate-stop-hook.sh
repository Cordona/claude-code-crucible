#!/usr/bin/env sh
# Claude Code Stop hook for flow-harness-authoring gates. While this
# session's gate is pending, it checks that the turn-ending message is gate.md
# word for word and nothing else: a good relay marks the gate relayed and
# keeps Claude going with "now ask"; a bad one keeps it going with "relay
# again", at most twice, then marks the gate failed and lets the stop through.
# Claude continues through hookSpecificOutput.additionalContext.
# It never early-returns on stop_hook_active: several gates may open in one
# turn, and each gate's tries cap ends its own loop.
set -eu
# Every outcome exits 0: a hook fault must allow the stop, never keep Claude
# going (exit 2 would), so the EXIT trap turns any failure into 0.
trap 'exit 0' EXIT

readonly PROG='gate-stop-hook.sh'
readonly PREFIX='flow-harness-authoring:'
readonly MARKER='_Harness gate_'
# 30 min: long enough to read a view, short enough that a gate left open by a
# crashed or abandoned turn soon stops denying questions.
readonly STALE_SECONDS=1800
readonly STALE_MINUTES=$((STALE_SECONDS / 60))
# 2 retries: one or two corrections fix a copy slip; a relay that still
# doesn't match won't, so the stop goes through instead of looping.
readonly MAX_RELAY_RETRIES=2
readonly ASK_REASON="${PREFIX} the gate view was relayed; its question is now allowed."

# Prints "good" when the message relays the gate; "unverifiable" when
# last_assistant_message is missing or not a string; otherwise the cause:
# "extra" (the gate text with more above or below it), "text" or "both". Both
# texts are normalized (CR dropped, trailing spaces per line removed,
# blank-line runs collapsed to one, leading and trailing blank lines dropped);
# a good relay is equal to the gate text. "text" and "both" tell apart
# whether the last non-empty line, trimmed, is the marker.
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
	| ($message | norm) as $relayed
	| ($gate | norm) as $expected
	| ([$message | lines[] | sub("^[ \t]+"; "") | select(. != "")] | last == $marker) as $has_marker
	| if $relayed == $expected then "good"
	  elif $relayed | contains($expected) then "extra"
	  elif $has_marker then "text"
	  else "both" end
end
'

usage() {
	cat <<EOF
usage: sh ${PROG} < stop-hook-input.json
       sh ${PROG} --help | -h

A Claude Code Stop hook: while this session's gate is pending, it checks that
the turn's last message relays the gate text, then has Claude continue, to
ask or to relay again.

stdin: the Stop hook JSON; reads session_id, agent_id and
  last_assistant_message
Gate folder (open-gate.sh writes it):
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/harness-gate/<session_id>/

stdout (Claude Code reads it), only when Claude is to continue:
  {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<context>"}}
  "now ask" context: ${ASK_REASON}
  "relay again" context: ${PREFIX} relay try <n> of ${MAX_RELAY_RETRIES} failed:
    <cause>; relay the gate text again, alone, as the turn's last message.
stderr: notes starting "${PREFIX}" on a removed gate, an unverifiable
  relay, a missing jq or a write fault

Writes, in the gate folder only (the state replaced whole, by rename):
  - pending, good relay: state becomes relayed; prints "now ask"
  - pending, last_assistant_message missing or not a string: state becomes
    relayed, no try counted; prints "now ask", with a note on stderr
  - pending, bad relay: tries + 1; up to ${MAX_RELAY_RETRIES} tries prints "relay again",
    then the state becomes failed and nothing is printed
  - a malformed gate, one with no gate.md, a linked state or gate.md, or one
    opened over ${STALE_MINUTES} minutes ago: the folder is removed
  - no state, and nothing in the folder changed for ${STALE_MINUTES} minutes: the folder
    is removed
Never touched: a relayed or failed gate; a linked gate folder or its root;
  and the folder on a stop with a non-empty agent_id (a subagent's) or a
  missing, non-string or unsafe session_id.

Exit codes:
  0  always, a fault included (stderr names it); the stop is allowed unless
     stdout holds a context

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
  jq package), cat, date, find (with -mmin, as on macOS and Linux), mktemp,
  mv, rm.
EOF
}

warn() {
	printf '%s %s: %s\n' "${PREFIX}" "${PROG}" "$1" >&2
}

# Writes the state line "$1 $2 $3" whole, or warns and exits 0.
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
		extra) cause='the last message holds the gate text with more above or below it' ;;
		text) cause='the last message ends with the marker but its text differs from the gate text' ;;
		*) cause="the gate text is missing and the last non-empty line is not ${MARKER}" ;;
	esac
	printf '%s relay try %s of %s failed: %s; relay the gate text again, alone, as the turn'"'"'s last message.' \
		"${PREFIX}" "$1" "${MAX_RELAY_RETRIES}" "${cause}"
}

# Sets gate_dir, gate_status, tries and created from a live gate of session
# $1, or exits 0 when there is none: a linked root or folder (left as it is),
# no state (an idle folder is removed), or a malformed or stale gate, or one
# without gate.md (removed).
load_gate() {
	gate_root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/harness-gate"
	gate_dir="${gate_root}/$1"
	[ ! -L "${gate_root}" ] && [ ! -L "${gate_dir}" ] && [ -d "${gate_dir}" ] || exit 0
	[ ! -L "${gate_dir}/state" ] || remove_gate 'linked state'
	[ -f "${gate_dir}/state" ] || drop_idle_folder
	read -r gate_status tries created _ <"${gate_dir}/state" || true
	case ${gate_status-} in
		pending | relayed | failed) ;;
		*) remove_gate 'malformed state' ;;
	esac
	case ${tries-}:${created-} in
		:* | *: | *[!0-9:]* | *:*:* | 0?*:* | *:0?*) remove_gate 'malformed state' ;;
		*) ;;
	esac
	now=$(date +%s)
	[ $((now - created)) -le "${STALE_SECONDS}" ] || remove_gate 'stale gate'
	[ ! -L "${gate_dir}/gate.md" ] && [ -f "${gate_dir}/gate.md" ] || remove_gate 'gate without a plain gate.md'
}

# With no state, removes the folder when nothing in it (the folder included)
# changed within STALE_SECONDS; allows the stop either way.
drop_idle_folder() {
	recent=$(find "${gate_dir}" ! -mmin "+${STALE_MINUTES}" 2>/dev/null) || exit 0
	[ -n "${recent}" ] || remove_gate "gate folder with no state, unchanged for over ${STALE_MINUTES} minutes,"
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
# A stop with agent_id set is a subagent's, which carries the main thread's
# session_id; only the main thread's relay moves the gate.
session_id=$(printf '%s' "${hook_input}" | jq -r 'if (.agent_id // "") == "" then (.session_id // empty | strings) else empty end')
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
