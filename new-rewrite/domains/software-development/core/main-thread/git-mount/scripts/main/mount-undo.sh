#!/usr/bin/env sh
# Takes the mount in place out of the human's checkout byte for byte, or
# forgets it once the human committed it.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
# git apply writes the checkout's files under the human's own umask.
caller_umask=$(umask)
umask 077

usage() {
	cat <<'USAGE'
usage: sh mount-undo.sh --repo DIR

Takes the mount out of the main checkout, putting back every byte it
replaced; when the human committed it, only forgets it (mount-status.sh
says which).

Options:
  --repo DIR  any folder of the repository, absolute
Requires:  a mount in place; HEAD unmoved and every mounted path as mounted,
           or HEAD moved and every mounted path committed
Writes:    the checkout's files, unless forgetting; mount.undone {repo,
           forgotten} to the effort that made it, if it still exists
Stdout:    {event, forgotten, names, paths}: event a path or null
Exit:
  0  undone or forgotten
  2  refused, nothing changed, the reason on stderr; or the mount is out and
     only its event was refused
  4  git or jq failed, or the bytes did not verify; checkout maybe partial
  5  nothing is mounted
  6  the events lock stayed held; the mount is out, mount.undone unwritten
USAGE
}

gm_prog='mount-undo.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
repo_in=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo) [ $# -ge 2 ] || gm_refuse '--repo needs a value'; repo_in=$2; shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
gm_find_self "$0"
gm_find_core
gm_set_repo "${repo_in}"
gm_make_work
rc=0
sh "${gm_scripts}/internal/mount-record.sh" --repo "${gm_repo}" >"${gm_work}/record" || rc=$?
[ "${rc}" -eq 0 ] || exit "${rc}"
sh "${gm_scripts}/internal/mount-paths.sh" --repo "${gm_repo}" >"${gm_work}/now" || exit $?

# Lists, at most 20, the paths whose now is not $1, as "$2<path>: <now>",
# and refuses with $3.
refuse_paths() {
	jq -r --arg want "$1" --arg say "$2" '.paths[] | select(.now != $want) | "\($say)\(.path): \(.now)"' "${gm_work}/now" \
		| head -n 20 | while IFS= read -r line; do gm_warn "$(gm_printable "${line}")"; done
	gm_refuse "$3"
}

# Takes the patch out, puts the saved bytes back, and checks every path
# holds what it held before the mount.
reverse() {
	git -C "${gm_repo}" -c core.fsmonitor=false apply -R --check --binary --whitespace=nowarn -- "${gm_record_dir}/mount.patch" \
		>/dev/null 2>"${gm_work}/stderr" \
		|| gm_refuse "git apply -R --check refused the saved patch: $(gm_printable "$(head -n 1 "${gm_work}/stderr")"); nothing touched"
	(umask "${caller_umask}" && exec git -C "${gm_repo}" -c core.fsmonitor=false apply -R --binary --whitespace=nowarn \
		-- "${gm_record_dir}/mount.patch") 2>"${gm_work}/stderr" || gm_git_failed 'git apply -R in the checkout (the record is kept)'
	sh "${gm_scripts}/internal/mount-restore.sh" --repo "${gm_repo}" >/dev/null || gm_fail 'mount-restore.sh could not put the bytes back; the record is kept'
	jq -r '.paths[].path' "${gm_work}/record" >"${gm_work}/paths"
	sh "${gm_scripts}/internal/mount-states.sh" --repo "${gm_repo}" --paths "${gm_work}/paths" >"${gm_work}/states" || exit $?
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	unverified=$(jq -r --slurpfile states "${gm_work}/states" '[.paths, $states[0]] | transpose[]
		| select(.[0].before != .[1].state) | .[0].path' "${gm_work}/record" | head -n 1)
	[ -z "${unverified}" ] || gm_fail "after reversing, $(gm_printable "${unverified}") does not hold what it held before the mount; the record is kept"
	remove_empty_folders
}

# Removes each now-empty folder above a path the mount added, deepest first;
# rmdir leaves any folder that still holds something.
remove_empty_folders() {
	jq -r '.paths[] | select(.before == "absent") | .path' "${gm_work}/record" >"${gm_work}/added"
	while IFS= read -r added; do
		while :; do
			case ${added} in */*) added=${added%/*} ;; *) break ;; esac
			[ -d "${gm_repo}/${added}" ] && [ ! -L "${gm_repo}/${added}" ] || continue
			rmdir -- "${gm_repo}/${added}" 2>/dev/null || break
		done
	done <"${gm_work}/added"
}

forgotten=false
if [ "$(jq -r '.finished' "${gm_work}/now")" = true ]; then
	forgotten=true
elif [ "$(jq -r '.head_moved' "${gm_work}/now")" = true ]; then
	refuse_paths committed 'not committed: ' 'HEAD moved since the mount and these paths are not committed; commit them, or move HEAD back, then undo again'
else
	! jq -e '.paths | any(.now != "mounted")' "${gm_work}/now" >/dev/null \
		|| refuse_paths mounted 'changed since the mount: ' 'nothing touched: put these paths back as mounted, or commit them, then undo again'
	reverse
fi
rm -f -- "${gm_record_dir}/mount.json" || gm_fail "the record ${gm_record_dir}/mount.json could not be removed"
rm -rf -- "${gm_record_dir}/mount.patch" "${gm_record_dir}/before" || gm_warn "could not remove the patch or the saved copies in ${gm_record_dir}"
rmdir -- "${gm_record_dir}" 2>/dev/null || :

effort=$(jq -r '.effort' "${gm_work}/record")
event=''
if [ -d "${effort}/events" ]; then
	jq -n --arg repo "${gm_repo}" --argjson forgotten "${forgotten}" '{repo: $repo, forgotten: $forgotten}' >"${gm_work}/body"
	rc=0
	event=$(sh "${gm_core_writer}" --effort "${effort}" --type mount.undone --by "${gm_prog}" --body-file "${gm_work}/body") || rc=$?
	[ "${rc}" -eq 0 ] || { gm_warn 'the mount is undone; mount.undone was not written'; exit "${rc}"; }
else
	gm_warn "the effort ${effort} that made the mount is gone; no mount.undone written"
fi
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -c --arg event "${event}" --argjson forgotten "${forgotten}" \
	'{event: (if $event == "" then null else $event end), forgotten: $forgotten, names: [.trees[].name], paths: (.paths | length)}' \
	"${gm_work}/record"
