#!/usr/bin/env sh
# Prints the effort's mounts still in place, one line each: the open-work
# contract.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh open-work.sh --effort FOLDER

Run by crucible-effort's effort-close.sh; not for main to call.
Lists the mounts this effort made that are still open: not undone and not
finished by the human.

Options:
  --effort FOLDER  the effort's folder, absolute
Writes:    nothing
Stdout:    one line per open mount, `mount <repo> <tree names>`, tree names
           space-separated; nothing when none is open
Exit:
  0  checked
  2  refused, nothing changed; the reason is on stderr
  4  the events, a mount record or git could not be read, or git/jq missing
USAGE
}

gm_prog='open-work.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort) [ $# -ge 2 ] || gm_refuse '--effort needs a value'; effort=$2; shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
gm_find_self "$0"
gm_find_core
gm_check_effort "${effort}"
gm_make_work
# The repositories this effort mounted into; whether a mount is there is
# each checkout's record's to say.
sh "${gm_core_reader}" --effort "${gm_effort_given}" --type mount.made >"${gm_work}/made" || gm_fail 'events-read.sh failed reading the effort'
jq -r '[.[].body.repo] | unique[]' "${gm_work}/made" >"${gm_work}/repos"
while IFS= read -r repo; do
	[ -d "${repo}/.git" ] || continue
	rc=0
	sh "${gm_scripts}/internal/mount-record.sh" --repo "${repo}" >"${gm_work}/record" 2>"${gm_work}/stderr" || rc=$?
	case ${rc} in
		0) ;;
		5) continue ;;
		*) cat "${gm_work}/stderr" >&2; gm_fail "the mount record of ${repo} could not be read" ;;
	esac
	[ "$(jq -r '.effort' "${gm_work}/record")" = "${gm_effort}" ] || continue
	sh "${gm_scripts}/internal/mount-paths.sh" --repo "${repo}" >"${gm_work}/now" || gm_fail "mount-paths.sh failed for ${repo}"
	[ "$(jq -r '.finished' "${gm_work}/now")" = false ] || continue
	printf 'mount %s %s\n' "${repo}" "$(jq -r '[.trees[].name] | join(" ")' "${gm_work}/record")"
done <"${gm_work}/repos"
