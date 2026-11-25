#!/usr/bin/env sh
# Claude Code Stop hook: keeps main going until its final message shows every
# card show-card.sh recorded as owed this session, then tells it to ask the
# question the card is for.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077
# A hook fault must let the stop through, never trap the human in a loop.
input='' context=''
trap 'rm -f -- ${input:+"${input}"}; exit 0' EXIT

usage() {
	cat <<'EOF'
usage: sh require-card-shown.sh < STOP_HOOK_JSON

Run by Claude Code as the Stop hook; not for main to call.
Sends main back until its final message holds each card show-card.sh owes
this session, then tells it to ask.

Reads:     stdin, the Stop hook JSON {session_id, agent_id,
           last_assistant_message}; a non-empty agent_id passes untouched.
           Env CLAUDE_CONFIG_DIR, default ~/.claude
Writes:    owed records: marks found cards shown, removes one after 2 tries
Stdout:    nothing, or one JSON object {hookSpecificOutput: {hookEventName:
           "Stop", additionalContext}, systemMessage: a dropped-card notice},
           each key only when it applies
Exit:
  0  always, faults too; main continues only if additionalContext is printed
EOF
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || { printf 'require-card-shown.sh: jq not found\n' >&2; exit 0; }
. "$(dirname -- "$0")/../../scripts/lib/owed.sh"
. "$(dirname -- "$0")/../../../crucible-events/scripts/lib/atomic-write.sh"

input=$(mktemp)
cat >"${input}"
[ -z "$(jq -r '.agent_id // empty' "${input}")" ] || exit 0
session=$(jq -r '.session_id // empty' "${input}")
og_safe_id "${session}" || exit 0
og_set_dir "${session}"

# Whitespace-normalised, so trailing spaces and blank-line runs don't count.
norm='def norm: gsub("\r"; "") | split("\n") | map(sub("[ \t]+$"; ""))
	| map(select(. != "")) | join("\n");'
missing=false ask=false dropped=false
og_records >"${input}.records"
while IFS= read -r record; do
	# A record that can't be read is dropped, so it never holds a question.
	fields=$(jq -r --slurpfile in "${input}" "${norm}"'
		(($in[0].last_assistant_message // "") | norm) as $m
		| (.text | norm) as $c | [($m | contains($c)), .status, .tries] | @tsv' "${record}") \
		|| { rm -f -- "${record}"; continue; }
	IFS=$(printf '\t') read -r shown status tries <<EOF2
${fields}
EOF2
	if [ "${status}" = owed ] && [ "${shown}" = true ]; then
		jq '.status = "shown" | .tries = 0' "${record}" | aw_write "${record}"
		ask=true
	elif [ "${tries}" -ge "${og_max_tries}" ]; then
		rm -f -- "${record}"
		[ "${status}" != owed ] || dropped=true
	else
		jq '.tries += 1' "${record}" | aw_write "${record}"
		if [ "${status}" = owed ]; then missing=true; else ask=true; fi
	fi
done <"${input}.records"
rm -f -- "${input}.records"

if [ "${missing}" = true ]; then
	context='A card from show-card.sh is not in your final message. End your turn with the card exactly as show-card.sh printed it.'
elif [ "${ask}" = true ]; then
	context='The card is shown. Ask your question about it now.'
fi
# A card given up on is said to the human, never dropped silently.
notice=''
[ "${dropped}" = false ] || notice='A card was not shown to you after 2 tries and was dropped. Ask main to show it again before you decide.'
[ -z "${context}${notice}" ] || jq -cn --arg c "${context}" --arg n "${notice}" '
	(if $c != "" then {hookSpecificOutput: {hookEventName: "Stop", additionalContext: $c}} else {} end)
	+ (if $n != "" then {systemMessage: $n} else {} end)'
