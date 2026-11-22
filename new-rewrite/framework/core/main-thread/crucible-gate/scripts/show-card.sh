#!/usr/bin/env sh
# Shows a gate's card to the human: prints it for main to relay, and records
# it as owed this session, so the gate hooks hold the question until it is
# shown.
# A new card replaces any card still owed: main fixed it, or moved on.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'EOF'
usage: sh show-card.sh [--record NAME --effort FOLDER --accept LABEL [--subject TEXT]] CARD_FILE
       sh show-card.sh --help | -h

Prints CARD_FILE, a gate's card, for main to relay as its final message,
and records it as owed this session, replacing any card still owed. Until
main's final message holds the card, the Stop hook sends main back and the
question hook holds the question; once it does, main is told to ask.

  CARD_FILE    a text file: a card a script produced, or a short card
               main wrote

A recorded gate, whose answer a piece will act on, also names:
  --record NAME     what is decided, lowercase words joined by dashes
  --effort FOLDER   the effort whose log receives the answer, absolute
  --accept LABEL    the option label that means yes; the question must be
                    one single-select question offering it
  --subject TEXT    what exactly is decided on, such as a file's sha256
The human's answer is then written as a gate.answered event, accepted only
when they picked the --accept option.

Environment:
  CLAUDE_CODE_SESSION_ID  set by Claude Code; unset: the card is printed,
               nothing is recorded, and stderr says so
  CLAUDE_CONFIG_DIR  default $HOME/.claude

stdout: the card
Writes: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cache/crucible-gate/<session>/owed/<id>.json
Exit: 0 printed (and recorded, inside Claude Code); 2 refused, the reason
  on stderr; 3 jq missing
EOF
}

refuse() {
	printf 'show-card.sh: %s\n' "$1" >&2
	exit 2
}

record='' effort='' accept='' subject='' card=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--record | --effort | --accept | --subject)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in --record) record=$2 ;; --effort) effort=$2 ;; --accept) accept=$2 ;; --subject) subject=$2 ;; esac
			shift 2 ;;
		-*) refuse "unknown option $1; try --help" ;;
		*) [ -z "${card}" ] || refuse 'expected one CARD_FILE; try --help'; card=$1; shift ;;
	esac
done
[ -n "${card}" ] || refuse 'expected one CARD_FILE; try --help'
if [ -n "${record}${effort}${accept}${subject}" ]; then
	printf '%s' "${record}" | grep -Eq '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' || refuse '--record must be lowercase words joined by dashes'
	case ${effort} in /*) ;; *) refuse 'a recorded gate needs --effort, an absolute folder' ;; esac
	[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
	printf '%s' "${accept}" | grep -q '[^[:space:]]' || refuse 'a recorded gate needs --accept, the option that means yes'
fi
[ -f "${card}" ] || refuse "${card} is not a file"
LC_ALL=C grep -Iq . "${card}" 2>/dev/null || refuse "${card} is empty or not text"
command -v jq >/dev/null 2>&1 || { printf 'show-card.sh: jq not found\n' >&2; exit 3; }

cat -- "${card}"

session=${CLAUDE_CODE_SESSION_ID-}
[ -n "${session}" ] || { printf 'show-card.sh: no CLAUDE_CODE_SESSION_ID; printed, not recorded\n' >&2; exit 0; }
. "$(dirname -- "$0")/lib/owed.sh"
. "$(dirname -- "$0")/../../crucible-events/scripts/lib/atomic-write.sh"
og_safe_id "${session}" || refuse 'CLAUDE_CODE_SESSION_ID is not a safe id; the card was printed, not recorded'
og_set_dir "${session}"
mkdir -p -- "${og_dir}"
for old in "${og_dir}"/*.json; do [ ! -f "${old}" ] || rm -f -- "${old}"; done
id="$(date +%s)-$$"
jq -n --rawfile text "${card}" --arg id "${id}" --arg record "${record}" --arg effort "${effort}" \
	--arg accept "${accept}" --arg subject "${subject}" \
	'{id: $id, text: $text, status: "owed", tries: 0, at: now | floor}
	+ (if $record == "" then {} else {record: {record: $record, effort: $effort, accept: $accept, subject: $subject}} end)' \
	| aw_write "${og_dir}/${id}.json"
