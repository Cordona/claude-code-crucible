#!/usr/bin/env sh
# Checks a context version before it goes to an agent: intact, and the newest.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-verify.sh --effort FOLDER --file EVENT
       sh context-verify.sh --help | -h

Checks that EVENT is one of the effort's context.cut events, a regular file
of at most 65536 bytes, of the right shape, with its spec in place, every
docs folder still giving its digest, and the newest version.

  --effort FOLDER   the effort's folder, absolute
  --file EVENT      the context.cut event, as context-cut.sh printed it

stdout: CONTEXT_FILE: <EVENT>, then CONTEXT_SHA256: <its sha256>
Exit: 0 usable; 2 not, the reason on stderr, led by a token:
  NOT-CONTEXT  not a context.cut event of this effort, or not a plain file
  SHAPE  the event breaks the context.cut rule; NO-SPEC  its spec is missing
  CONTEXT-CHANGED  a docs folder no longer gives its digest
  STALE  a newer version exists: use it
USAGE
}

cx_prog='context-verify.sh'
. "$(dirname -- "$0")/lib/context.sh"
. "$(dirname -- "$0")/lib/path-rule.sh"
. "$(dirname -- "$0")/lib/body.sh"
effort='' file=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --file)
			[ $# -ge 2 ] || cx_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --file) file=$2 ;; esac
			shift 2 ;;
		*) cx_refuse "unknown argument $1; try --help" ;;
	esac
done
cx_set "${effort}"
sh "${cx_reader}" --effort "${cx_effort}" --type context.cut --paths | grep -Fqx -- "${file}" \
	|| cx_refuse "NOT-CONTEXT: ${file} is not a context.cut event of this effort"
[ -f "${file}" ] && [ ! -L "${file}" ] || cx_refuse "NOT-CONTEXT: ${file} is not a plain file"
[ "$(wc -c <"${file}")" -le 65536 ] || cx_refuse "SHAPE: ${file} is over 65536 bytes"
jq -e 'type == "object" and .type == "context.cut"' "${file}" >/dev/null 2>&1 || cx_refuse "SHAPE: ${file} is not a context.cut event"

# The rule gets the events before this one, as when it was written.
problems=$(sh "${cx_reader}" --effort "${cx_effort}" \
	| jq --slurpfile e "${file}" '{event: $e[0], prior: [.[] | select(.seq < $e[0].seq)]}' \
	| jq -r -f "${cx_rules}/context.cut.jq")
if [ -n "${problems}" ]; then
	case ${problems} in NO-SPEC*) cx_refuse "$(printf '%s' "${problems}" | head -n 1)" ;; esac
	cx_refuse "SHAPE: $(printf '%s' "${problems}" | head -n 1)"
fi
spec=$(jq -r '.body.spec' "${file}")
[ -f "${spec}" ] || cx_refuse "NO-SPEC: ${spec} is missing"
changed=$(jq -r '.body.paths[] | select(has("sha256")) | "\(.sha256) \(.path)"' "${file}" | while read -r want folder; do
	[ "$(bd_digest "${folder}")" = "${want}" ] || { printf '%s\n' "${folder}"; break; }
done)
[ -z "${changed}" ] || cx_refuse "CONTEXT-CHANGED: ${changed} no longer gives its digest"
[ "$(cx_latest)" = "${file}" ] || cx_refuse "STALE: a newer version exists: $(cx_latest)"
printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "${file}" "$(sh_sha256 "${file}")"
