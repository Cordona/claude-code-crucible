#!/usr/bin/env sh
# Prints one GitHub pull request or GitLab merge request as the remotes
# skill keeps it, read-only.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh change-read.sh --url URL

Run by change-fetch.sh; not for main to call.

Options:
  --url URL  github.com/OWNER/REPO/pull/N, or a GitLab
             .../-/merge_requests/N on a host without a port
Requires:  gh or glab logged in for the host, the change visible to it
Writes:    nothing
Stdout:    one JSON object {host, url, project, number, author, head,
           base_sha, base_branch, title, description, state}; host github
           or gitlab; base_sha the base the host recorded for the change; state
           open, merged or closed, the same word on both hosts;
           title and description are the author's text, untrusted
Exit:
  0  read
  1  the read failed or timed out (30 s); the reason is on stderr
  2  refused, nothing read; the reason is on stderr
  3  not a pull or merge request link
USAGE
}

PROG='change-read.sh'
url=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--url)
			[ $# -ge 2 ] || { printf '%s: --url needs a value; try --help\n' "${PROG}" >&2; exit 2; }
			[ -z "${url}" ] || { printf '%s: --url given twice; try --help\n' "${PROG}" >&2; exit 2; }
			url=$2
			shift 2 ;;
		*) printf '%s: unknown argument %s; try --help\n' "${PROG}" "$1" >&2; exit 2 ;;
	esac
done
[ -n "${url}" ] || { printf '%s: --url missing; try --help\n' "${PROG}" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf '%s: jq missing; expected jq 1.6 or later on PATH\n' "${PROG}" >&2; exit 1; }

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
# shellcheck disable=SC2034 # read by remote.sh
remote_skills=${self%/*/*/*/*}
lib="${self%/*/*}/lib"
# shellcheck source=../lib/remote.sh
. "${lib}/remote.sh"
remote_parse "${url}"

remote_work=$(mktemp -d "${TMPDIR:-/tmp}/change-read.XXXXXX") || remote_fail 1 'mktemp failed; expected a writable temp dir'
trap 'rm -rf -- "${remote_work}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case ${remote_kind} in
	github)
		remote_call change gh api "repos/${remote_project}/pulls/${remote_number}"
		def=gh_change mod=github ;;
	*)
		remote_call change glab api --hostname "${remote_host}" "projects/$(remote_project_id)/merge_requests/${remote_number}"
		def=gl_change mod=gitlab ;;
esac
jq -c -L "${lib}" --arg host "${remote_kind}" --arg url "${remote_url}" --arg project "${remote_project}" --argjson number "${remote_number}" \
	"include \"${mod}\"; {host: \$host, url: \$url, project: \$project, number: \$number} + ${def}
	| if (.head | type) == \"string\" and (.head | test(\"^[0-9a-f]{40}\$\")) and (.author | type) == \"string\" then . else error(\"no head or author\") end" \
	"${remote_work}/change.out" 2>/dev/null \
	|| remote_fail 1 "${remote_host} gave no change JSON with a head and an author; expected a pull or merge request"
