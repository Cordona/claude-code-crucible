#!/usr/bin/env sh
# Claude Code Stop hook for approval gates. While this session's gate is
# pending, it checks that the turn-ending message is gate.md word for word and
# nothing else, so its last line is the marker: a good relay marks the gate
# relayed and keeps Claude going with "now ask"; a bad one keeps it going with
# "relay again", at most twice, then marks the gate failed and lets the stop
# through.
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
# "extra" (the gate text with more above or below it), "text" or "both". Both
# texts are normalized (CR dropped, trailing spaces per line removed, blank-line
# runs collapsed to one, leading and trailing blank lines dropped); a good relay
# is equal to the gate text. Otherwise "text" and "both" tell apart whether the
# last non-empty line, trimmed, is the marker.
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

A Claude Code Stop hook: while this session's approval gate is pending, it
checks that the turn's last message relays the gate text, then has Claude
continue, to ask or to relay again.

Input: the Stop hook JSON on stdin; reads session_id, agent_id and
  last_assistant_message.
Gate folder (open-gate.sh writes it):
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/approval-gate/<session_id>/

stdout (Claude Code reads it):
  {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<context>"}}
  "now ask" context: ${ASK_REASON}
  "relay again" context: procedure-approval-gate: relay try <n> of ${MAX_RELAY_RETRIES} failed:
    <cause and what to relay>

Writes, in the gate folder (its state replaced atomically):
  - pending, good relay: state becomes relayed; prints "now ask"
  - pending, last_assistant_message missing or not a string: state becomes
    relayed, no try counted; prints "now ask", with a note on stderr
  - pending, bad relay: tries + 1; up to ${MAX_RELAY_RETRIES} tries prints "relay again", then
    the state becomes failed and nothing is printed
  - a malformed gate, one with no gate.md, or one older than ${STALE_MINUTES} minutes: the
    folder is removed; a plan.json changed in the last ${STALE_MINUTES} minutes is kept,
    with only gate.md and the state removed
  - no gate state, and nothing in the folder changed in the last ${STALE_MINUTES} minutes:
    the folder is removed
Never touched: any other relayed, shown or failed gate, and the folder on a
  stop with a non-empty agent_id or a missing, non-string or unsafe session_id.

Exit codes:
  0  always, a fault included (stderr names it); the stop is allowed unless
     stdout holds a context

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
  jq package), cat, date, find (with -mmin, as on macOS and Linux), mktemp,
  mv, rm.
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
		extra) cause='the last message must be the gate text alone, with nothing above or below it' ;;
		text) cause='the gate text is missing from the last message' ;;
		*) cause="the gate text is missing and the last non-empty line is not ${MARKER}" ;;
	esac
	printf 'procedure-approval-gate: relay try %s of %s failed: %s. The gate is still pending, so its question stays denied until a turn'"'"'s last message is the full text open-gate.sh printed and nothing else, its last line %s.' \
		"$1" "${MAX_RELAY_RETRIES}" "${cause}" "${MARKER}"
}

# Sets gate_dir (absolute, so the paths stderr names are whole) and
# gate_status, tries and created from a live gate, or exits 0 when there
# is none: no state (an idle folder is removed), a malformed or stale one, or
# no gate.md (each removed as remove_gate sets).
load_gate() {
	gate_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/cache/approval-gate/$1"
	case ${gate_dir} in
		/*) ;;
		*) gate_dir="$(pwd)/${gate_dir}" ;;
	esac
	[ -f "${gate_dir}/state" ] || drop_idle_folder
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

# With no gate state, removes the folder when nothing in it (the folder
# included) changed within STALE_SECONDS; allows the stop either way.
drop_idle_folder() {
	recent=$(find "${gate_dir}" ! -mmin "+${STALE_MINUTES}" 2>/dev/null) || exit 0
	[ -n "${recent}" ] || remove_gate 'gate folder with no gate state, unchanged for over '"${STALE_SECONDS}"'s,'
	exit 0
}

# Removes the gate (reason $1 goes to stderr) and allows the stop: the whole
# folder, or only gate.md and the state when plan.json changed within
# STALE_SECONDS, since that is the session's next plan, written before its gate
# opens.
remove_gate() {
	fresh_plan=$(find "${gate_dir}/plan.json" -prune -type f ! -mmin "+${STALE_MINUTES}" 2>/dev/null) || fresh_plan=''
	if [ -n "${fresh_plan}" ]; then
		warn "$1 removed, plan.json kept: ${gate_dir}"
		rm -f "${gate_dir}/state" "${gate_dir}/gate.md"
	else
		warn "$1 removed: ${gate_dir}"
		rm -rf "${gate_dir}"
	fi
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
# A stop with agent_id set is a subagent's or side agent's, which carries the
# main thread's session_id; only the main thread's relay moves the gate.
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
