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
usage: sh show-card.sh CARD_FILE
       sh show-card.sh --record NAME --effort FOLDER (--accept LABEL | --choice)
                       [--subject TEXT] CARD_FILE

Prints CARD_FILE as this session's owed card. Run it before every gate
question; end your turn with the card as printed; ask when told. --record logs
the answer for a script to act on; that script's --help names the values.

Options:
  CARD_FILE        a non-empty text file: the card
  --record NAME    the decision, lowercase words joined by dashes
  --effort FOLDER  absolute; effort (has events/) to log gate.answered in
  --accept LABEL   yes gate: the exact yes label, any (Recommended) included
  --choice         choice gate, in place of --accept: the pick is the answer
  --subject TEXT   what exactly is decided, e.g. a sha256; default empty
Requires:  with --record: ask one single-select question next, LABEL in it
Reads:     CLAUDE_CODE_SESSION_ID, CLAUDE_CONFIG_DIR
Writes:    this session's owed card, replacing any earlier one
Stdout:    the card text, verbatim
Exit:
  0  printed; recorded unless CLAUDE_CODE_SESSION_ID is unset
  2  refused, nothing recorded, reason on stderr; card printed if id unsafe
  3  jq not found; nothing printed
EOF
}

refuse() {
	printf 'show-card.sh: %s\n' "$1" >&2
	exit 2
}

record='' effort='' accept='' subject='' card='' choice=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--record | --effort | --accept | --subject)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in --record) record=$2 ;; --effort) effort=$2 ;; --accept) accept=$2 ;; --subject) subject=$2 ;; esac
			shift 2 ;;
		--choice) choice=1; shift ;;
		-*) refuse "unknown option $1; try --help" ;;
		*) [ -z "${card}" ] || refuse 'expected one CARD_FILE; try --help'; card=$1; shift ;;
	esac
done
[ -n "${card}" ] || refuse 'expected one CARD_FILE; try --help'
if [ -n "${record}${effort}${accept}${subject}${choice}" ]; then
	printf '%s' "${record}" | grep -Eq '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' || refuse '--record must be lowercase words joined by dashes'
	case ${effort} in /*) ;; *) refuse 'a recorded gate needs --effort, an absolute folder' ;; esac
	[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
	if [ -n "${choice}" ]; then
		[ -z "${accept}" ] || refuse '--accept and --choice go alone: a gate has a yes option or is a choice'
	else
		printf '%s' "${accept}" | grep -q '[^[:space:]]' || refuse 'a recorded gate needs --accept, the option that means yes, or --choice'
	fi
fi
[ -f "${card}" ] || refuse "${card} is not a file"
LC_ALL=C grep -Iq . "${card}" 2>/dev/null || refuse "${card} is empty or not text"
command -v jq >/dev/null 2>&1 || { printf 'show-card.sh: jq not found\n' >&2; exit 3; }

cat -- "${card}"

session=${CLAUDE_CODE_SESSION_ID-}
[ -n "${session}" ] || { printf 'show-card.sh: no CLAUDE_CODE_SESSION_ID; printed, not recorded\n' >&2; exit 0; }
. "$(dirname -- "$0")/../lib/owed.sh"
. "$(dirname -- "$0")/../../../crucible-events/scripts/lib/atomic-write.sh"
og_safe_id "${session}" || refuse 'CLAUDE_CODE_SESSION_ID is not a safe id; the card was printed, not recorded'
og_set_dir "${session}"
mkdir -p -- "${og_dir}"
for old in "${og_dir}"/*.json; do [ ! -f "${old}" ] || rm -f -- "${old}"; done
id="$(date +%s)-$$"
jq -n --rawfile text "${card}" --arg id "${id}" --arg record "${record}" --arg effort "${effort}" \
	--arg accept "${accept}" --arg subject "${subject}" --arg choice "${choice}" \
	'{id: $id, text: $text, status: "owed", tries: 0, at: now | floor}
	+ (if $record == "" then {} else {record: ({record: $record, effort: $effort, subject: $subject}
		+ (if $choice == "" then {accept: $accept} else {choice: true} end))} end)' \
	| aw_write "${og_dir}/${id}.json"
