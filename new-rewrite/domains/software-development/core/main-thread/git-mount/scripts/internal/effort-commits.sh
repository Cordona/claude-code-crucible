#!/usr/bin/env sh
# Proves a commit holds only an effort's own work on top of another. Reads
# only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gm_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh effort-commits.sh --repo FOLDER --from SHA --to SHA --effort FOLDER

Run by mount-apply.sh; not for main to call.
Proves every commit after --from up to --to has the trailer
"Effort: <effort folder name>". Gives the start: the newest snapshot whose
parent is --from, else --from.

Options:
  --repo FOLDER    a folder in the git checkout, absolute
  --from SHA       the commit the work builds on, an ancestor of --to
  --to SHA         the commit to prove
  --effort FOLDER  the effort's folder, absolute
Writes:    nothing
Stdout:    one JSON line: on 0 {ok: true, from, start, commits};
           on 5 {ok: false, reason, commit, subject}
Exit:
  0  proven
  2  refused, nothing changed; the reason is on stderr
  4  git or jq failed; the reason is on stderr
  5  not proven; the reason is on stderr
USAGE
}

gm_prog='effort-commits.sh'
. "$(dirname -- "$0")/../lib/mount.sh"
repo_in='' from='' to='' effort=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --from | --to | --effort)
			[ $# -ge 2 ] || gm_refuse "$1 needs a value"
			case $1 in --repo) repo_in=$2 ;; --from) from=$2 ;; --to) to=$2 ;; --effort) effort=$2 ;; *) ;; esac
			shift 2 ;;
		*) gm_refuse "unknown argument $1; try --help" ;;
	esac
done
gm_find_self "$0"
gm_check_effort "${effort}"
gm_set_repo "${repo_in}"
commit_snapshots="${gm_skills}/git-commit/scripts/internal/commit-snapshots.sh"
gm_require_files "${commit_snapshots}"

# Prints the full sha of commit $1, given as option $2.
resolve() {
	case $1 in
		'') gm_refuse "$2 needs a commit" ;;
		-*) gm_refuse "$2 $(gm_printable "$1") starts with -; expected a commit" ;;
		*[[:cntrl:]]*) gm_refuse "$2 holds a control character; expected a commit" ;;
		*) ;;
	esac
	git -C "${gm_repo}" rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null \
		|| gm_refuse "$2 $1 is no commit of ${gm_repo}"
}
from_sha=$(resolve "${from}" --from)
to_sha=$(resolve "${to}" --to)
gm_make_work

# Prints the refusal of reason $1 for commit $2 (subject $3, both may be
# empty) and exits 5 with stderr line $4.
not_proven() {
	jq -nc --arg reason "$1" --arg commit "$2" --arg subject "$3" \
		'{ok: false, reason: $reason, commit: (if $commit == "" then null else $commit end),
		  subject: (if $commit == "" then null else $subject end)}'
	gm_warn "$4"
	exit 5
}

rc=0
git -C "${gm_repo}" merge-base --is-ancestor "${from_sha}" "${to_sha}" 2>"${gm_work}/stderr" || rc=$?
case ${rc} in
	0) ;;
	1) not_proven not_ancestor '' '' "${from_sha} is not an ancestor of ${to_sha}; expected the effort's work built on it" ;;
	*) gm_git_failed 'git merge-base --is-ancestor' ;;
esac

git -C "${gm_repo}" log -z --no-show-signature \
	--format='%H%n%P%n%T%n%(trailers:key=Effort,valueonly,unfold,separator=%x1f)%n%s' \
	"${from_sha}..${to_sha}" -- >"${gm_work}/range" 2>"${gm_work}/stderr" || gm_git_failed 'git log of the range'

# Sets snapshots to the JSON array of the range's snapshots whose only
# parent is --from, as git-commit tells them.
find_snapshots() {
	snapshots='[]'
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rrs --arg from "${from_sha}" 'split("\u0000")[] | select(. != "") | split("\n") | select(.[1] == $from) | .[0]' \
		"${gm_work}/range" >"${gm_work}/on-from" || gm_fail 'jq could not read the range'
	[ -s "${gm_work}/on-from" ] || return 0
	set --
	while IFS= read -r commit; do set -- "$@" --commit "${commit}"; done <"${gm_work}/on-from"
	told_rc=0
	told=$(sh "${commit_snapshots}" --repo "${gm_repo}" "$@") || told_rc=$?
	[ "${told_rc}" -eq 0 ] || gm_fail "commit-snapshots.sh failed (exit ${told_rc})"
	snapshots=$(printf '%s' "${told}" | jq -c '.snapshots') || gm_fail 'jq could not read the snapshots'
}
find_snapshots
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
verdict=$(jq -Rsc --arg effort "${gm_effort_name}" --argjson snapshots "${snapshots}" '
	split("\u0000") | map(select(. != "") | split("\n")
		| {commit: .[0], parents: (.[1] | split(" ") | map(select(. != ""))), tree: .[2],
		   efforts: (.[3] | split("\u001f")), subject: (.[4:] | join("\n"))})
	| reduce .[] as $c ({commits: length, snapshot: null, refusal: null};
		if .refusal != null then .
		elif any($c.efforts[]; . == $effort) | not then .refusal = {reason: "foreign_commit", commit: $c}
		elif ($c.commit | IN($snapshots[]) | not) then .
		elif .snapshot == null then .snapshot = $c
		elif .snapshot.tree != $c.tree then .refusal = {reason: "snapshot_mismatch", commit: $c}
		else . end)' "${gm_work}/range") || gm_fail 'jq could not judge the range'

reason=$(printf '%s' "${verdict}" | jq -r '.refusal.reason // ""')
if [ -n "${reason}" ]; then
	commit=$(printf '%s' "${verdict}" | jq -r '.refusal.commit.commit')
	subject=$(printf '%s' "${verdict}" | jq -r '.refusal.commit.subject')
	case ${reason} in
		foreign_commit) line="commit ${commit} ($(gm_printable "${subject}")) carries no Effort: ${gm_effort_name} trailer; expected only this effort's work" ;;
		*) line="commit ${commit} is a snapshot holding other changes than the first one found; expected every snapshot to hold one tree" ;;
	esac
	not_proven "${reason}" "${commit}" "${subject}" "${line}"
fi
printf '%s' "${verdict}" | jq -c --arg from "${from_sha}" '{ok: true, from: $from, start: (.snapshot.commit // $from), commits: .commits}'
