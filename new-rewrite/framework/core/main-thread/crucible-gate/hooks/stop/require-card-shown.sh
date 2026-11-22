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
usage: sh require-card-shown.sh < stop-hook-input.json
       sh require-card-shown.sh --help | -h

A Claude Code Stop hook. For each card owed this session:
  not in the final message: main is sent back to show it exactly as
    printed, at most 2 times; then the card is dropped and the human is
    told so
  in the final message: the card is marked shown and main is told to ask
  shown, question not asked yet: main is told again to ask, at most 2 times

stdin: the Stop hook JSON; reads session_id, agent_id, last_assistant_message
  A subagent's stop (non-empty agent_id) passes untouched.
stdout, only when main is to continue or the human is told of a drop:
  {"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"<text>"},
   "systemMessage":"<notice>"}, each part only when it applies
Exit: always 0
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
