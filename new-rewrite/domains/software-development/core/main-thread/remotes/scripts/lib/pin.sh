# Writes one event that pins a file at reports/<kind>/<its own seq>.json.
# Sourced; the caller sets PROG and remote_skills. The seq is the next one
# when the file is placed; if another event takes it first, the rule refuses
# the path and the file moves to the next seq, a few times at most.
# shellcheck shell=sh disable=SC2034,SC2154 # the variables are shared with the caller

# Usage: pin_write EFFORT TYPE KIND FILE BODY. FILE is the content to pin;
# BODY the event's body without report. Prints the event's seq.
pin_write() {
	pw_effort=$1 pw_type=$2 pw_kind=$3 pw_file=$4 pw_body=$5
	pw_events="${remote_skills}/crucible-events/scripts/internal"
	[ -f "${pw_events}/event-write.sh" ] || remote_fail 2 "crucible-events isn't beside this skill (expected ${pw_events}/event-write.sh); install first"
	. "${remote_skills}/crucible-events/scripts/lib/sha256.sh"
	mkdir -p "${pw_effort}/reports/${pw_kind}" || remote_fail 1 "could not make ${pw_effort}/reports/${pw_kind}"
	pw_try=0
	while [ "${pw_try}" -lt 3 ]; do
		pw_try=$((pw_try + 1))
		pw_seq=$(($(sh "${pw_events}/events-read.sh" --effort "${pw_effort}" --paths | awk 'END { print NR }') + 1))
		pw_rel="reports/${pw_kind}/${pw_seq}.json"
		pw_target="${pw_effort}/${pw_rel}"
		[ ! -e "${pw_target}" ] || remote_fail 2 "${pw_rel} is already there; a human must look"
		cp -- "${pw_file}" "${pw_target}" && chmod 444 "${pw_target}" || remote_fail 1 "could not write ${pw_rel}"
		jq --arg path "${pw_rel}" --arg sha "$(sh_sha256 "${pw_target}")" '. + {report: {path: $path, sha256: $sha}}' \
			"${pw_body}" >"${pw_body}.pinned" || remote_fail 1 'could not make the event body'
		pw_err=$(sh "${pw_events}/event-write.sh" --effort "${pw_effort}" --type "${pw_type}" --by "${PROG}" \
			--body-file "${pw_body}.pinned" 2>&1 >/dev/null) && { printf '%s\n' "${pw_seq}"; return 0; }
		rm -f -- "${pw_target}"
		# Only a seq taken meanwhile is worth another try.
		printf '%s' "${pw_err}" | grep -q "report must be {path: \"${pw_rel}\"" && continue
		remote_fail 2 "the event was refused: ${pw_err}"
	done
	remote_fail 2 "other events kept taking the next seq; run again"
}
