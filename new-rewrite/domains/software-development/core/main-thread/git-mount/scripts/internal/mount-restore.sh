#!/usr/bin/env sh
# Puts back the exact bytes and mode the mount saved of each file it replaced
# or deleted.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh mount-restore.sh --repo FOLDER

Run by mount-undo.sh and mount-apply.sh; not for main to call.
After the mount's patch is taken out, puts back the exact bytes and mode the
mount saved of each file it replaced (e.g. line endings).

Options:
  --repo FOLDER  absolute; any folder of the repository, acts on its main
                 checkout
Requires:  the patch reversed, so every saved file holds its pre-mount content
Writes:    each saved file whose bytes differ, bytes and mode; the record stays
Stdout:    one JSON object {saved: N paths saved, restored: M rewritten}
Exit:
  0  every saved file holds its saved bytes
  2  refused, nothing changed; the reason is on stderr
  4  a write, the byte check or git failed; files put back stay: rerun
  5  nothing is mounted
USAGE
}

gm_prog='mount-restore.sh'
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
gm_set_repo "${repo_in}"
gm_make_work
temp=''
trap '[ -z "${temp}" ] || rm -f -- "${temp}"; gm_clean_up' EXIT
rc=0
sh "${gm_scripts}/internal/mount-record.sh" --repo "${gm_repo}" >"${gm_work}/record" || rc=$?
[ "${rc}" -eq 0 ] || exit "${rc}"
# "<n><TAB><before><TAB><path>" per saved path.
jq -r '.paths | to_entries[] | select(.value.saved == true) | "\(.key)\t\(.value.before)\t\(.value.path)"' \
	"${gm_work}/record" >"${gm_work}/saved"
cut -f 3- "${gm_work}/saved" >"${gm_work}/paths"
sh "${gm_scripts}/internal/mount-states.sh" --repo "${gm_repo}" --paths "${gm_work}/paths" >"${gm_work}/states" || exit $?
jq -r '.[].state' "${gm_work}/states" | paste - "${gm_work}/saved" >"${gm_work}/check"
while IFS='	' read -r now n before path; do
	[ -f "${gm_record_dir}/before/${n}" ] || gm_refuse "the saved copy before/${n} of $(gm_printable "${path}") is missing; nothing was touched"
	[ "${now}" = "${before}" ] \
		|| gm_refuse "$(gm_printable "${path}") does not hold its content from before the mount; nothing was touched"
done <"${gm_work}/check"

restored=0
while IFS='	' read -r n before path; do
	copy="${gm_record_dir}/before/${n}"
	file="${gm_repo}/${path}"
	! cmp -s -- "${copy}" "${file}" || continue
	temp=$(mktemp "${file%/*}/.crucible-restore.XXXXXX") || gm_fail "could not write beside $(gm_printable "${path}")"
	cp -p -- "${copy}" "${temp}" || gm_fail "could not copy the saved bytes of $(gm_printable "${path}")"
	mv -f -- "${temp}" "${file}" || gm_fail "could not put back $(gm_printable "${path}")"
	temp=''
	restored=$((restored + 1))
done <"${gm_work}/saved"
while IFS='	' read -r n before path; do
	cmp -s -- "${gm_record_dir}/before/${n}" "${gm_repo}/${path}" \
		|| gm_fail "$(gm_printable "${path}") does not hold its bytes from before the mount"
done <"${gm_work}/saved"
jq -nc --argjson saved "$(wc -l <"${gm_work}/saved" | tr -d ' ')" --argjson restored "${restored}" '{saved: $saved, restored: $restored}'
