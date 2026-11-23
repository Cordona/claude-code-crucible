#!/usr/bin/env sh
# Checks a context version before it goes to an agent: intact, and the newest.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-verify.sh --effort FOLDER --file EVENT

Checks that a context version is intact and the newest. Run it right before
a version goes to an agent; the effort need not be open.

Options:
  --effort FOLDER  the effort's folder, absolute
  --file EVENT     the context.cut event, exactly as the CONTEXT_FILE line of
                   context-cut.sh or context-status.sh printed it
Writes:    nothing
Stdout:    CONTEXT_FILE: <EVENT>, then CONTEXT_SHA256: <its sha256>
Exit:
  0  intact and the newest
  2  refused, nothing changed; the reason is on stderr
     STALE: a newer version exists: verify the newest instead
     CONTEXT-CHANGED: a sealed docs folder was altered: tell the human
USAGE
}

cx_prog='context-verify.sh'
. "$(dirname -- "$0")/../lib/context.sh"
. "$(dirname -- "$0")/../lib/path-rule.sh"
. "$(dirname -- "$0")/../lib/body.sh"
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
all=$(sh "${cx_reader}" --effort "${cx_effort}") || exit 2
problems=$(printf '%s\n' "${all}" \
	| jq --slurpfile e "${file}" '{event: $e[0], prior: [.[] | select(.seq < $e[0].seq)]}' \
	| jq -r -f "${cx_rules}/context.cut.jq")
if [ -n "${problems}" ]; then
	cx_refuse "SHAPE: $(printf '%s' "${problems}" | head -n 1)"
fi
changed=$(jq -r '.body.paths[] | select(has("sha256")) | "\(.sha256) \(.path)"' "${file}" | while read -r want folder; do
	[ "$(bd_digest "${folder}")" = "${want}" ] || { printf '%s\n' "${folder}"; break; }
done)
[ -z "${changed}" ] || cx_refuse "CONTEXT-CHANGED: ${changed} no longer gives its digest"
[ "$(cx_latest)" = "${file}" ] || cx_refuse "STALE: a newer version exists: $(cx_latest)"
printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "${file}" "$(sh_sha256 "${file}")"
