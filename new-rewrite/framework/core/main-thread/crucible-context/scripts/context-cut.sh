#!/usr/bin/env sh
# Cuts a sealed context version, once the human said the context is done:
# their newest answer at the context-done gate for this fingerprint.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-cut.sh --effort FOLDER
       sh context-cut.sh --help | -h

Cuts the context's draft into a sealed version once the human said it is
done. The gate must have recorded the decision as context-done, with the
draft's fingerprint (context-fingerprint.sh) as its subject, and the
human's newest answer to it must be the option named as yes. A draft
changed since that answer has another fingerprint, so the human is asked
again. The cut moves the draft's docs to <effort>/context/v<N>/ with their
files read-only, writes the context.cut event and clears the pending
entries. An empty context is cut as a version with no paths. With nothing
new since the latest version, it prints that version and writes nothing.

  --effort FOLDER   the effort's folder, absolute; the effort must be open

stdout: CONTEXT_FILE: <the context.cut event, absolute>, then
  CONTEXT_SHA256: <its sha256>
Exit: 0 cut, or nothing new; 1 NOT-CONFIRMED: the human's newest answer
  for this fingerprint is not a yes, or there is none; 2 refused, nothing
  written, the reason on stderr, led by a token: DOCS-NAME, DOCS-SIZE
USAGE
}

cx_prog='context-cut.sh'
. "$(dirname -- "$0")/lib/context.sh"
. "$(dirname -- "$0")/lib/path-rule.sh"
. "$(dirname -- "$0")/lib/body.sh"
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
if ! reason=$(sh "${cx_gate_answer}" --effort "${cx_effort}" --record context-done --subject "${fingerprint}" 2>&1 >/dev/null); then
	printf '%s: NOT-CONFIRMED: the human has not said yes to this context (fingerprint %s): %s; ask at a context-done gate\n' \
		"${cx_prog}" "${fingerprint}" "$(printf '%s' "${reason}" | head -n 1 | sed 's/^[^:]*: //')" >&2
	exit 1
fi

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
if ! event=$(sh "${cx_writer}" --effort "${cx_effort}" --type context.cut --by "${cx_prog}" \
	--body-file "${bodyfile}"); then
	rm -f -- "${bodyfile}"
	if [ "${moved}" = true ]; then chmod -R u+w "${target}"; mv -- "${target}" "${cx_docs}"; fi
	exit 2
fi
rm -f -- "${bodyfile}" "${cx_entries}"
show "${event}"
