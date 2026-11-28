#!/usr/bin/env sh
# Claude Code Stop hook for owed cards: at each stop of the main thread it
# checks every card show.sh recorded this session against the turn-ending
# message, its own input, and keeps Claude going, through
# hookSpecificOutput.additionalContext (shown as "Stop hook feedback"), while
# a card is missing or a gate's question may now be asked.
# It never early-returns on stop_hook_active: each card's tries cap ends its
# own loop, so it always ends by letting the stop through. Claude Code's own
# continuation cap (env CLAUDE_CODE_STOP_HOOK_BLOCK_CAP) also applies; its
# default is in the Claude Code hooks docs, https://code.claude.com/docs/en/hooks.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077
# Every outcome exits 0: a hook fault must allow the stop, never keep Claude
# going (exit 2 would), so the EXIT trap turns any failure into 0. It also
# removes the temp files, and a signal exits through it.
message_file='' cards_file=''
trap 'rm -f -- ${message_file:+"${message_file}"} ${cards_file:+"${cards_file}"}; exit 0' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

readonly PROG='show-stop-hook.sh'
readonly ASK_REASON='procedure-approval-gate: the plan was relayed; its approval question is now allowed.'

# The verdict on one record, as "<verdict> <kind> <tries> <name>": bad (not a
# record), stale, wait (a shown gate, waiting for its question), shown or
# missing. A card is shown when the message holds its text, a gate only when
# the message ends with its text and holds above it every owed card ($cards)
# and nothing else; all normalised.
# shellcheck disable=SC2016 # the $ names are jq's
readonly CHECK_JQ='include "owed";
def gate_shown($card; $texts):
	($message == $card and ($texts | length) == 0)
	or (($message | endswith("\n" + $card))
		and ($message[:($message | length) - ($card | length) - 1] | rtrimstr("\n")
			| . as $above | is_cards_only($texts) and all($texts[]; . as $text | $above | contains($text))));
if is_owed_record | not then "bad card 0 -"
else (if .kind == "gate" then .gate else .name end | gsub("[\u0000-\u001f\u007f]"; "?")) as $name
	| (.text | normalised) as $card
	| (if is_stale(now; $stale) then "stale"
		elif .status == "shown" then "wait"
		elif .kind == "gate" then (if gate_shown($card; $cards | map(.text)) then "shown" else "missing" end)
		elif card_shown_in($message) then "shown"
		else "missing" end) as $verdict
	| "\($verdict) \(.kind) \(.tries) \($name)"
end'

usage() {
	cat <<EOF
usage: sh ${PROG} < stop-hook-input.json
       sh ${PROG} --help | -h

A Claude Code Stop hook: checks that the main thread showed each card
show.sh recorded as owed this session in its turn-ending message, and has
Claude continue while one is missing or a shown gate's question may be asked.

Input: the Stop hook JSON on stdin; reads session_id, agent_id and
  last_assistant_message, and nothing else. A stop with a non-empty
  agent_id, a missing or unsafe session_id, or a missing or non-string
  last_assistant_message checks nothing.
Records (show.sh writes them, see show.sh --help):
  \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/human-view/<session_id>/owed/

A card is shown when last_assistant_message holds its text. A gate is
shown only when last_assistant_message ends with its text and holds above
it every owed card's text of this session and nothing else, in any order,
each starting on a line of its own; those cards are then shown too. While a
gate is sent back, no card counts as shown in that message: each stays
owed, its tries unchanged, to be relayed again with the gate; a missing
card's try is counted, its send-back folded into the gate's. All are compared
with CR dropped, trailing blanks cut from each line, blank-line runs
collapsed and leading and trailing blank lines dropped.

stdout, only when Claude is to continue:
  {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<lines>"}}
  one line per card, each one of:
  "${ASK_REASON}"
    a gate was shown; its question may now be asked
  "show: show the <name> card as printed, nothing changed, in this turn's
    last message: <record path>"
    a card is missing, and no gate is sent back
  "procedure-approval-gate: relay try <n> of ${hv_max_tries-} failed: relay again. The
    <label> gate is still pending; its question stays denied until a turn's
    last message is the gate text alone, as printed: <record path>"
    a gate is missing, followed by text, or below text that is no owed card;
    while a card is owed, the line ends instead "is each owed card, as
    printed, then the gate text, as printed, last, and nothing else; owed:
    <name>[ ×<n>], ...: <record path>", and is the reply's only line

Writes, in the session's owed folder:
  a shown card's record is removed, unless a gate is sent back; a shown
    gate's becomes status shown
  a missing card's tries + 1; past ${hv_max_tries-} tries the record is removed
  a malformed record, or one over ${hv_stale_minutes-} minutes old, is removed
Nothing else is left behind (a SIGKILL aside).

Exit codes:
  0  always, a fault included (stderr names it); the stop is allowed unless
     stdout holds a context

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
  jq package), cat, mktemp, mv, rm, rmdir; lib/owed.sh and lib/owed.jq
  beside it.

Environment:
  CLAUDE_CONFIG_DIR  the Claude Code config folder; default \$HOME/.claude
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Appends line $1 to the context Claude continues with.
add_context() {
	context="${context}${context:+
}$1"
}

# Writes the normalised turn-ending message to message_file, or exits 0
# when there is none to check.
write_message() {
	message_file=$(mktemp "${hv_session_dir}/.message.XXXXXX") || {
		warn "cannot create a temp file in ${hv_session_dir}; nothing checked; stop allowed; check the folder's owner and free space"
		exit 0
	}
	printf '%s' "${hook_input}" | jq -j -L "${lib_dir}" \
		'include "owed"; .last_assistant_message | if type == "string" then normalised else error("none") end' \
		>"${message_file}" 2>/dev/null || {
		warn 'last_assistant_message missing or not a string; nothing checked; stop allowed'
		exit 0
	}
}

# Writes each fresh, well-formed owed card of the session to cards_file, one
# {name, text} per line, the text normalised: what a gate needs above it. Sets
# owed_card_names to their names, each once, with a count when repeated.
write_cards() {
	cards_file=$(mktemp "${hv_session_dir}/.cards.XXXXXX") || {
		warn "cannot create a temp file in ${hv_session_dir}; nothing checked; stop allowed; check the folder's owner and free space"
		exit 0
	}
	for card_record in "${hv_owed_dir}"/*.json; do
		[ -f "${card_record}" ] && [ ! -L "${card_record}" ] || continue
		jq -c -L "${lib_dir}" --argjson stale "${hv_stale_seconds}" \
			'include "owed"; select(is_owed_record and .kind == "card" and (is_stale(now; $stale) | not))
			| {name: (.name | gsub("[\u0000-\u001f\u007f]"; "?")), text: (.text | normalised)}' \
			"${card_record}" >>"${cards_file}" 2>/dev/null || true
	done
	owed_card_names=$(jq -rs 'map(.name) | group_by(.) | map(if length > 1 then "\(.[0]) ×\(length)" else .[0] end) | join(", ")' \
		"${cards_file}" 2>/dev/null) || owed_card_names=''
}

# Checks record $1 and acts on its verdict.
check_record() {
	verdict_line=$(jq -r -L "${lib_dir}" --rawfile message "${message_file}" --slurpfile cards "${cards_file}" \
		--argjson stale "${hv_stale_seconds}" "${CHECK_JQ}" "$1" 2>/dev/null) || verdict_line='bad card 0 -'
	read -r verdict kind tries name <<EOF
${verdict_line}
EOF
	case ${verdict} in
		bad)
			warn "malformed record removed: $1"
			rm -f "$1"
			;;
		stale) rm -f "$1" ;;
		wait) ;;
		shown)
			if [ "${kind}" = gate ]; then
				update_record "$1" '.status = "shown"' 0
				add_context "${ASK_REASON}"
			else
				shown_cards="${shown_cards}$1
"
			fi
			;;
		*) send_back "$1" ;;
	esac
}

# Counts a try for missing record $1: keeps Claude going to show it, or past
# the cap removes it.
send_back() {
	tries=$((tries + 1))
	if [ "${tries}" -gt "${hv_max_tries}" ]; then
		rm -f "$1"
		return 0
	fi
	# shellcheck disable=SC2016 # $tries is jq's
	update_record "$1" '.tries = $tries' "${tries}"
	if [ "${kind}" = gate ]; then
		gate_sent_back=1
		add_relay_again "$1"
	else
		card_context="${card_context}${card_context:+
}show: show the ${name} card as printed, nothing changed, in this turn's last message: $1"
	fi
}

# Removes the records of the cards this message showed, unless a gate was
# sent back: the message is then relayed again, cards and gate together, so
# none of it counts as shown and the cards stay owed, their tries unchanged.
settle_shown_cards() {
	[ "${gate_sent_back}" -eq 0 ] || return 0
	while IFS= read -r shown_card; do
		[ -z "${shown_card}" ] || rm -f "${shown_card}"
	done <<EOF
${shown_cards}
EOF
}

# Adds the send-back for missing gate record $1, naming the owed cards it
# needs above it: the approval gate's readers act only on a message that
# starts procedure-approval-gate: and says relay again.
add_relay_again() {
	if [ -n "${owed_card_names}" ]; then
		shape="each owed card, as printed, then the gate text, as printed, last, and nothing else; owed: ${owed_card_names}"
	else
		shape='the gate text alone, as printed'
	fi
	add_context "procedure-approval-gate: relay try ${tries} of ${hv_max_tries} failed: relay again. The ${name} gate is still pending; its question stays denied until a turn's last message is ${shape}: $1"
}

# Adds the missing cards' send-backs, unless a gate was sent back: its
# send-back names them, so they come back above the gate, not on their own.
add_card_context() {
	[ "${gate_sent_back}" -eq 0 ] && [ -n "${card_context}" ] || return 0
	add_context "${card_context}"
}

# Replaces record $1 by jq filter $2, given $tries $3, or warns.
update_record() {
	updated=$(jq -c --argjson tries "$3" "$2" "$1" 2>/dev/null) || {
		warn "cannot read $1; left as it was"
		return 0
	}
	# shellcheck disable=SC2310 # its status says whether the write held; set -e is not relied on inside
	hv_replace_file "$1" <<EOF || warn "cannot write $1; expected a writable owed folder; left as it was; check its owner and free space"
${updated}
EOF
}

case $0 in
	*/*) lib_dir="${0%/*}/lib" ;;
	*) lib_dir='./lib' ;;
esac
if [ -f "${lib_dir}/owed.sh" ] && [ -r "${lib_dir}/owed.sh" ] && [ -f "${lib_dir}/owed.jq" ]; then
	# shellcheck source=lib/owed.sh
	. "${lib_dir}/owed.sh"
	lib_problem=''
else
	lib_problem="lib/owed.sh or lib/owed.jq missing in ${lib_dir}"
fi

case ${1-} in
	--help | -h)
		usage
		exit 0
		;;
	*) ;;
esac

[ -z "${lib_problem}" ] || {
	warn "${lib_problem}; nothing checked; stop allowed; reinstall the human-view skill"
	exit 0
}
command -v jq >/dev/null 2>&1 || {
	warn 'jq missing; expected jq 1.6+ on PATH; stop allowed; check that jq is installed on the PATH Claude Code runs hooks with'
	exit 0
}
hook_input=$(cat)
# A stop with agent_id set is a subagent's or side agent's, which carries the
# main thread's session_id; only the main thread shows the human a card.
session_id=$(printf '%s' "${hook_input}" | jq -r 'if (.agent_id // "") == "" then (.session_id // empty | strings) else empty end' 2>/dev/null) || exit 0
# shellcheck disable=SC2310 # a pure test; its status is the answer
hv_is_safe_id "${session_id}" || exit 0
# shellcheck disable=SC2310 # its status says whether the paths are usable; the problem is read below
hv_set_paths "${session_id}" || {
	warn "${hv_path_problem}; nothing checked; stop allowed"
	exit 0
}
[ -d "${hv_owed_dir}" ] || exit 0
write_message
write_cards
context='' card_context='' shown_cards='' gate_sent_back=0
for owed_record in "${hv_owed_dir}"/*.json; do
	[ -f "${owed_record}" ] && [ ! -L "${owed_record}" ] || continue
	check_record "${owed_record}"
done
settle_shown_cards
add_card_context
rm -f "${message_file}" "${cards_file}"
message_file='' cards_file=''
rmdir "${hv_owed_dir}" "${hv_session_dir}" 2>/dev/null || true
[ -n "${context}" ] || exit 0
jq -cn --arg context "${context}" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $context}}'
