#!/usr/bin/env sh
# The only writer of an effort's events: appends one event, written once,
# after the emitting component's rule for its type has accepted it.
set -eu
umask 077
# shellcheck disable=SC1091 # the shared lock, beside this script
. "$(dirname -- "$0")/lib/lock.sh"
. "$(dirname -- "$0")/lib/listing.sh"
. "$(dirname -- "$0")/lib/beside.sh"

usage() {
	cat <<'EOF'
usage: sh event-write.sh --effort FOLDER --type TYPE --by NAME --body-file FILE
       [--iteration N]
       sh event-write.sh --help | -h

Appends one event to FOLDER/events/ as <seq>-<TYPE>.json, written once and
read-only (mode 444):
  {type, seq, at, by, claude_session_id, iteration?, body}
seq counts from 1 with no gaps; concurrent writers are serialised.

  --effort FOLDER   the effort's folder (absolute); events/ is created
  --type TYPE       lowercase words joined by dots, as effort.opened
  --by NAME         the writing script's name, as effort-start.sh
  --body-file FILE  a JSON object, the event's body
  --iteration N     a whole number from 1, stamped when given

Each type has one rule, <component>/events/<TYPE>.jq, in one of the
components beside crucible-events (the folder holding it, as this script
was called: installed, the skills folder); it is found there, never passed in. A
type with no rule, or with more than one, is refused, naming them. A rule
gets {event, prior} (prior: the earlier events, in seq order) and prints one
plain reason per broken rule; printing nothing accepts.

Environment: CLAUDE_CODE_SESSION_ID (claude_session_id; null when unset)
stdout: the new event's absolute path
Exit: 0 written; 2 refused, nothing written, the reasons on stderr;
  3 jq missing; 6 the lock stayed held, nothing written, rerun
EOF
}

refuse() {
	printf 'event-write.sh: %s\n' "$1" >&2
	exit 2
}

effort='' type='' by='' body='' iteration=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --type | --by | --body-file | --iteration)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in
				--effort) effort=$2 ;; --type) type=$2 ;; --by) by=$2 ;;
				--body-file) body=$2 ;; --iteration) iteration=$2 ;;
			esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || { printf 'event-write.sh: jq not found\n' >&2; exit 3; }

case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}" ] && [ ! -L "${effort}" ] || refuse "${effort} is not a folder"
ls_is_type "${type}" \
	|| refuse "--type ${type} must be lowercase words joined by dots"
printf '%s' "${by}" | grep -Eq '^[A-Za-z0-9._-]+$' || refuse '--by must be a script name'
# The type's one rule, among the components beside this one.
components=$(bs_components "$0" 1) || refuse 'the components folder beside crucible-events is not there'
rule='' found=0 named=''
for candidate in "${components}"/*/events/"${type}.jq"; do
	[ -f "${candidate}" ] || continue
	found=$((found + 1)); rule=${candidate}
	named="${named:+${named}, }${candidate#"${components}"/}"
done
[ "${found}" -gt 0 ] || refuse "no rule for ${type}: expected one <component>/events/${type}.jq beside crucible-events"
[ "${found}" -eq 1 ] || refuse "${found} rules for ${type}: ${named}; expected exactly one"
if [ ! -f "${body}" ] || ! jq -e 'type == "object"' "${body}" >/dev/null 2>&1; then
	refuse '--body-file must hold one JSON object'
fi
[ -z "${iteration}" ] || printf '%s' "${iteration}" | grep -Eq '^[1-9][0-9]*$' \
	|| refuse '--iteration must be a whole number from 1'

events="${effort}/events"
mkdir -p -- "${events}"

lock="${events}/.lock"
lk_take "${lock}" || { printf 'event-write.sh: the events lock stayed held\n' >&2; exit 6; }
temp=''
trap 'lk_release "${lock}"; rm -f -- ${temp:+"${temp}"}' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

count=$(ls_events "${effort}" | wc -l | tr -d ' ')
seq=$((count + 1))
temp=$(mktemp "${events}/.tmp.XXXXXX")
# shellcheck disable=SC2016 # the $ names are jq's
jq -n --slurpfile body "${body}" --arg type "${type}" --argjson seq "${seq}" \
	--arg by "${by}" --arg session "${CLAUDE_CODE_SESSION_ID-}" --arg iteration "${iteration}" '
	{type: $type, seq: $seq, at: (now | todate), by: $by,
	 claude_session_id: (if $session == "" then null else $session end)}
	+ (if $iteration == "" then {} else {iteration: ($iteration | tonumber)} end)
	+ {body: $body[0]}' >"${temp}"

# The earlier events in seq order, read line by line so spaces in paths hold.
reasons=$(ls_events "${effort}" \
	| while IFS= read -r file; do cat -- "${file}"; done \
	| jq -s --slurpfile event "${temp}" '{event: $event[0], prior: .}' \
	| jq -r -f "${rule}") || refuse "the rule ${rule} failed to run"
[ -z "${reasons}" ] || refuse "${type} refused: $(printf '%s' "${reasons}" | paste -sd '|' - | sed 's/|/; /g')"

target="${events}/$(printf '%06d' "${seq}")-${type}.json"
[ ! -e "${target}" ] || refuse "${target} already exists"
# Written once, never edited: the file itself says so.
chmod 444 "${temp}" || refuse "could not make the event read-only"
mv -- "${temp}" "${target}"
temp=''
printf '%s\n' "${target}"
