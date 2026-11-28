#!/usr/bin/env sh
# Brings a change's commits into a repository as objects only, and prints
# its merge base: no ref, no FETCH_HEAD, no checkout change.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh change-commits.sh --repo FOLDER --change FILE

Run by change-fetch.sh; not for main to call.

Options:
  --repo FOLDER  the repository the change belongs to, absolute
  --change FILE  change-read.sh's output
Requires:  a remote of FOLDER whose URL names the change's host and
           project, git's own credentials for it
Writes:    git objects in FOLDER, nothing else
Stdout:    one JSON line {remote, base, head}: base the merge base of the
           change's head and the base the host recorded, head the change's
           head
Exit:
  0  fetched
  1  the fetch failed or timed out (120 s), or the fetched head isn't the
     host's; the reason is on stderr
  2  refused, nothing fetched; the reason is on stderr
USAGE
}

readonly PROG='change-commits.sh'
# A large change on a slow link can take a while; a caller must not hang.
readonly FETCH_SECONDS=120
fail() {
	code=$1
	shift
	printf '%s: %s\n' "${PROG}" "$*" >&2
	exit "${code}"
}

repo='' change=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --change)
			[ $# -ge 2 ] && [ -n "$2" ] || fail 2 "$1 needs a value; try --help"
			case $1 in --repo) repo=$2 ;; *) change=$2 ;; esac
			shift 2 ;;
		*) fail 2 "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || fail 2 'jq missing; expected jq 1.6 or later on PATH'
command -v git >/dev/null 2>&1 || fail 2 'git missing'
case ${repo} in /*) ;; *) fail 2 '--repo must be an absolute folder' ;; esac
git -C "${repo}" rev-parse --git-dir >/dev/null 2>&1 || fail 2 "${repo} is not a git repository"
[ -f "${change}" ] || fail 2 '--change must be a file holding change-read.sh output'

host=$(jq -r '.host // empty' "${change}")
url=$(jq -r '.url // empty' "${change}")
project=$(jq -r '.project // empty' "${change}")
number=$(jq -r '.number // empty' "${change}")
head=$(jq -r '.head // empty' "${change}")
base_sha=$(jq -r '.base_sha // empty' "${change}")
printf '%s' "${head}" | grep -Eqx '[0-9a-f]{40}' || fail 2 'the change has no full head sha'
printf '%s' "${number}" | grep -Eqx '[1-9][0-9]*' || fail 2 'the change has no number'
printf '%s' "${base_sha}" | grep -Eqx '[0-9a-f]{40}' || fail 2 'the change has no full base sha'
case ${host} in
	github) ref="refs/pull/${number}/head" ;;
	gitlab) ref="refs/merge-requests/${number}/head" ;;
	*) fail 2 "the change's host is neither github nor gitlab" ;;
esac
authority=${url#https://}
authority=${authority%%/*}

# The remote whose URL names the same host and project, in any of git's
# URL forms: https://HOST/PROJECT(.git), git@HOST:PROJECT(.git),
# ssh://git@HOST(:PORT)/PROJECT(.git).
remote=''
for r in $(git -C "${repo}" remote); do
	# The URL as configured: an insteadOf rewrite only changes the transport.
	u=$(git -C "${repo}" config --get "remote.${r}.url") || continue
	p=$(printf '%s' "${u}" | sed -E 's#^[a-z+]+://([^@/]+@)?##; s#^[^@/]+@##; s#\.git/?$##; s#/$##')
	case ${p} in
		"${authority}/${project}" | "${authority}:${project}" | "${authority}":[0-9]*"/${project}") remote=${r}; break ;;
		*) ;;
	esac
done
[ -n "${remote}" ] || fail 2 "no remote of ${repo} names ${authority}/${project}; add one, or fetch from the repository the change belongs to"

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
run_timed="${self%/*/*/*/*}/dev-base/scripts/internal/run-timed.sh"
[ -f "${run_timed}" ] || fail 2 "dev-base isn't beside this skill (expected ${run_timed}); install first"
err=$(mktemp "${TMPDIR:-/tmp}/change-commits.XXXXXX") || fail 1 'mktemp failed'
trap 'rm -f -- "${err}"' EXIT
# The change's ref, or, once the host has dropped it (GitLab drops a merged
# request's), its head by sha; and the base the host recorded, by sha.
fetch() {
	status=0
	GIT_TERMINAL_PROMPT=0 sh "${run_timed}" --seconds "${FETCH_SECONDS}" -- \
		git -C "${repo}" fetch --quiet --no-tags --no-write-fetch-head --refmap= "${remote}" "$@" 2>"${err}" || status=$?
}
fetch "${ref}" "${base_sha}"
[ "${status}" -eq 0 ] || fetch "${head}" "${base_sha}"
[ "${status}" -eq 0 ] || fail 1 "git fetch from ${remote} failed (exit ${status}): $(tr -s '[:space:]' ' ' <"${err}" | cut -c 1-300)"
git -C "${repo}" cat-file -e "${head}^{commit}" 2>/dev/null \
	|| fail 1 "the host's head ${head} is not what ${ref} brought; the change moved since it was read: read it again"
base=$(git -C "${repo}" merge-base "${base_sha}" "${head}") || fail 1 "${head} and the base ${base_sha} share no history"
jq -cn --arg remote "${remote}" --arg base "${base}" --arg head "${head}" '{remote: $remote, base: $base, head: $head}'
