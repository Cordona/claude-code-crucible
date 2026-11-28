#!/usr/bin/env sh
# Cuts a sealed context version, once the human said the context is done:
# their newest answer at the context-done gate for this fingerprint.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-cut.sh --effort FOLDER

Seals the effort's context draft as its next version, context/v<N>/. Run it
right after the human's yes at the context-done gate.

Options:
  --effort FOLDER  the effort's folder, absolute
Requires:  the effort open; the human's newest answer yes at a recorded yes
           gate, record context-done, subject the FINGERPRINT
           context-fingerprint.sh prints now; ask again after any change
Writes:    the draft's docs as v<N>, read-only; a context.cut event; the
           pending entries cleared; nothing when nothing is new
Stdout:    CONTEXT_FILE: <the context.cut event, absolute; the latest one
           when nothing is new>, then CONTEXT_SHA256: <its sha256>
Exit:
  0  cut, or nothing new
  1  NOT-CONFIRMED, nothing written: ask at a context-done gate
  2  refused, nothing changed; the reason is on stderr
  6  the events lock stayed held, nothing changed: rerun
USAGE
}

cx_prog='context-cut.sh'
. "$(dirname -- "$0")/../lib/context.sh"
. "$(dirname -- "$0")/../lib/path-rule.sh"
. "$(dirname -- "$0")/../lib/body.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || cx_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) cx_refuse "unknown argument $1; try --help" ;;
	esac
done
cx_set "${effort}"
cx_require_open
cx_lock
body=$(bd_build)
# The human's yes on exactly this would-be version.
fingerprint=$(bd_fingerprint "${body}")
answered=0
reason=$(sh "${cx_gate_answer}" --effort "${cx_effort}" --record context-done --subject "${fingerprint}" 2>&1 >/dev/null) \
	|| answered=$?
if [ "${answered}" -eq 1 ]; then
	printf '%s: NOT-CONFIRMED: the human has not said yes to this context (fingerprint %s): %s; ask at a context-done gate\n' \
		"${cx_prog}" "${fingerprint}" "$(printf '%s' "${reason}" | head -n 1 | sed 's/^[^:]*: //')" >&2
	exit 1
fi
[ "${answered}" -eq 0 ] || { printf '%s\n' "${reason}" >&2; exit 2; }

latest=$(cx_latest)
show() { printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "$1" "$(sh_sha256 "$1")"; }
if [ -n "${latest}" ] && [ "$(jq '.body.version' "${latest}")" = "$(printf '%s' "${body}" | jq '.version')" ]; then
	show "${latest}"
	exit 0
fi

version=$(printf '%s' "${body}" | jq -r '.version')
target="${cx_dir}/v${version}"
moved=false
if printf '%s' "${body}" | jq -e --arg t "${target}" 'any(.paths[]; .path == $t)' >/dev/null; then
	[ ! -e "${target}" ] || cx_refuse "${target} already exists"
	mv -- "${cx_docs}" "${target}"
	moved=true
	find "${target}" -type f -exec chmod 0444 {} +
fi
bodyfile=$(mktemp)
printf '%s' "${body}" >"${bodyfile}"
write_rc=0
event=$(sh "${cx_writer}" --effort "${cx_effort}" --type context.cut --by "${cx_prog}" \
	--body-file "${bodyfile}") || write_rc=$?
if [ "${write_rc}" -ne 0 ]; then
	rm -f -- "${bodyfile}"
	if [ "${moved}" = true ]; then chmod -R u+w "${target}"; mv -- "${target}" "${cx_docs}"; fi
	exit "${write_rc}"
fi
rm -f -- "${bodyfile}" "${cx_entries}"
show "${event}"
