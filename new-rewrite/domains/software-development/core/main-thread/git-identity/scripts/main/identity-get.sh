#!/usr/bin/env sh
# Prints the effort's identity for one repository. Reads only.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh identity-get.sh --effort FOLDER --repo DIR

Prints the identity the effort signs commits as in DIR's repository; a
checkout and its worktrees are one repository, and the newest pick counts.
Use it before a commit, or before git-identity's pick flow.

Options:
  --effort FOLDER  the effort's folder, absolute
  --repo DIR       a folder in a non-bare checkout or worktree, absolute
Writes:    nothing
Stdout:    one JSON line {repo, name, email, signing: {format, key},
           fingerprint}; repo is the main checkout's top folder, physical;
           format is openpgp or ssh; fingerprint may be ""
Exit:
  0  printed
  2  refused, nothing changed; the reason is on stderr
  5  the effort has no identity for that repository: run git-identity's
     pick flow first
USAGE
}

gi_prog='identity-get.sh'
. "$(dirname -- "$0")/../lib/git-identity.sh"
effort='' repo_in=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --repo)
			[ $# -ge 2 ] || gi_refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --repo) repo_in=$2 ;; *) ;; esac
			shift 2 ;;
		*) gi_refuse "unknown argument $1; try --help" ;;
	esac
done
gi_find_core "$0"
command -v jq >/dev/null 2>&1 || gi_refuse 'jq not found'
case ${effort} in /*) ;; *) gi_refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || gi_refuse "${effort} is not an effort folder"
gi_set_repo "${repo_in}"
sets=$(sh "${gi_core_reader}" --effort "${effort}" --type identity.set) || exit 2
found=$(printf '%s\n' "${sets}" | jq -c --arg r "${gi_repo}" '[.[] | select(.body.repo == $r)] | last // empty | .body | del(.answer)')
[ -n "${found}" ] || { printf '%s: the effort has no identity for %s\n' "${gi_prog}" "${gi_repo}" >&2; exit 5; }
printf '%s\n' "${found}"
