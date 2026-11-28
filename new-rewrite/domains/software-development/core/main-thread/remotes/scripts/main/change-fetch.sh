#!/usr/bin/env sh
# Reads one pull or merge request from its host, brings its commits into the
# repository and records it as remote-change.fetched, its author's text pinned.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh change-fetch.sh --effort FOLDER --repo FOLDER --url URL

Use when the human points to a pull or merge request to review, or one an
outside review was made on. Read-only on the host; no gate needed.

Options:
  --effort FOLDER  the effort's folder, absolute
  --repo FOLDER    the repository the change belongs to, absolute
  --url URL        github.com/OWNER/REPO/pull/N, or a GitLab
                   .../-/merge_requests/N on a host without a port
Requires:  gh or glab logged in for the host; a remote of the repository
           naming the change's host and project, git's credentials for it
Writes:    git objects in the repository (no ref, no FETCH_HEAD);
           reports/remote-change/SEQ.json (title, description, base
           branch, state); the event remote-change.fetched
Stdout:    "remote-change.fetched SEQ: URL, BASE..HEAD"
Exit:
  0  fetched and recorded
  1  a read or the fetch failed or timed out; the reason is on stderr
  2  refused, nothing recorded; the reason is on stderr
  3  not a pull or merge request link
USAGE
}

PROG='change-fetch.sh'
say() { printf '%s: %s\n' "${PROG}" "$1" >&2; exit "$2"; }
effort='' repo='' url=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --repo | --url)
			[ $# -ge 2 ] && [ -n "$2" ] || say "$1 needs a value; try --help" 2
			case $1 in --effort) effort=$2 ;; --repo) repo=$2 ;; *) url=$2 ;; esac
			shift 2 ;;
		*) say "unknown argument $1; try --help" 2 ;;
	esac
done
[ -n "${url}" ] || say '--url missing; try --help' 2
command -v jq >/dev/null 2>&1 || say 'jq missing; expected jq 1.6 or later on PATH' 2
case ${effort} in /*) ;; *) say '--effort must be an absolute folder' 2 ;; esac
[ -d "${effort}/events" ] || say "${effort} is not an effort folder" 2
case ${repo} in /*) ;; *) say '--repo must be an absolute folder' 2 ;; esac

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
# shellcheck disable=SC2034 # read by pin.sh
remote_skills=${self%/*/*/*/*}
here=${self%/*/*}
# shellcheck source=../lib/remote.sh
. "${here}/lib/remote.sh"
# shellcheck source=../lib/pin.sh
. "${here}/lib/pin.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/change-fetch.XXXXXX") || remote_fail 1 'mktemp failed; expected a writable temp dir'
trap 'rm -rf -- "${work}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sh "${here}/internal/change-read.sh" --url "${url}" >"${work}/change.json" || exit $?
sh "${here}/internal/change-commits.sh" --repo "${repo}" --change "${work}/change.json" >"${work}/commits.json" || exit $?

jq '{title, description, base_branch, state}' "${work}/change.json" >"${work}/pinned.json"
jq --arg repo "${repo}" --slurpfile k "${work}/commits.json" \
	'{host, url, repo: $repo, number, base: $k[0].base, head: $k[0].head, author}' "${work}/change.json" >"${work}/body.json"
seq=$(pin_write "${effort}" remote-change.fetched remote-change "${work}/pinned.json" "${work}/body.json")
jq -r --argjson s "${seq}" '"remote-change.fetched \($s): \(.url), \(.base[0:12])..\(.head[0:12])"' "${work}/body.json"
