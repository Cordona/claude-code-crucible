#!/usr/bin/env sh
# Checks that a remote a push could go to is configured and is not the
# repository itself. Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gp_ function exits on its own failure; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh push-remote.sh --repo FOLDER --remote NAME

Checks that NAME is a remote of the repository holding FOLDER and that none
of its push URLs is that repository. Use it to get a remote's push URLs for
the push card; push-tree.sh runs this check itself. Never contacts the remote.

Options:
  --repo FOLDER  any folder in the repository, absolute
  --remote NAME  the remote's name
Requires:  the remote is configured (git remote add)
Writes:    nothing
Stdout:    one JSON line {remote, urls: [push URL, ...]}, as git reports them
Exit:
  0  the remote exists and none of its push URLs is this repository
  2  refused, nothing changed; the reason is on stderr
  4  git or jq not found
USAGE
}

gp_prog='push-remote.sh'
. "$(dirname -- "$0")/../lib/git-push.sh"
repo='' remote=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--repo | --remote)
			[ $# -ge 2 ] || gp_refuse "$1 needs a value"
			case $1 in --repo) repo=$2 ;; --remote) remote=$2 ;; *) ;; esac
			shift 2 ;;
		*) gp_refuse "unknown argument $(gp_printable "$1"); try --help" ;;
	esac
done
gp_find_self "$0"
case ${repo} in /*) ;; *) gp_refuse '--repo must be an absolute folder' ;; esac
case ${remote} in
	'') gp_refuse '--remote needs a name' ;;
	-*) gp_refuse "--remote $(gp_printable "${remote}") starts with -; expected a remote name" ;;
	*[[:space:][:cntrl:]]*) gp_refuse '--remote holds a space or a control character; expected a remote name' ;;
	*) ;;
esac
own_common=$(cd -- "${repo}" 2>/dev/null && cd -P -- "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && pwd -P) \
	|| gp_refuse "--repo $(gp_printable "${repo}") is not in a git repository"
urls=$(git -C "${repo}" remote get-url --push --all -- "${remote}" 2>/dev/null) \
	|| gp_refuse "the repository has no remote $(gp_printable "${remote}"); add it first (git remote add)"

# A URL naming a folder on this machine is read as git reads it: file://
# stripped, a relative path taken from where the push runs (--repo). It is
# the repository itself when that folder is a repository (a checkout, a
# worktree or a git folder) whose git common directory is this one's.
while IFS= read -r url; do
	case ${url} in
		file://*) folder=${url#file://} ;;
		*://* | *::*) continue ;;
		[!/]*:*) case ${url%%:*} in */*) folder=${url} ;; *) continue ;; esac ;;
		*) folder=${url} ;;
	esac
	case ${folder} in /*) ;; *) folder="${repo}/${folder}" ;; esac
	[ -e "${folder}/.git" ] || [ -f "${folder}/HEAD" ] || continue
	their_common=$(cd -- "${folder}" 2>/dev/null && cd -P -- "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && pwd -P) || continue
	[ "${their_common}" != "${own_common}" ] \
		|| gp_refuse "remote $(gp_printable "${remote}") is the repository itself ($(gp_printable "${url}")); expected another repository"
done <<URLS
${urls}
URLS
printf '%s\n' "${urls}" | jq -Rnc --arg remote "${remote}" '{remote: $remote, urls: [inputs]}'
