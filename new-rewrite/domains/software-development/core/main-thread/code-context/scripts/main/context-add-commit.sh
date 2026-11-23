#!/usr/bin/env sh
# Writes a commit or range of a local git repository into the effort's
# context, as a patch in the draft's docs folder.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-add-commit.sh --effort FOLDER --repo ROOT --ref REF

Copies the diff of one commit, or of a range A..B, from a git work tree into
the effort's context draft as a patch, so the next context cut includes it.
Use it for committed work; files and folders go in with context-add.sh.

Options:
  --effort FOLDER  the effort's folder, absolute
  --repo ROOT      the git work-tree root, absolute; only read
  --ref REF        a commit, diffed against its parent, or a range A..B
Requires:  the effort is open
Writes:    <effort>/context/draft/docs/diff-<sha>.patch or diff-<A>..<B>.patch,
           replacing a same-named one; files the path rule refuses are left out
Stdout:    one path, absolute: the patch file
Exit:
  0  written
  2  refused, no patch written; the reason is on stderr
USAGE
}

refuse() { printf 'context-add-commit.sh: %s\n' "$1" >&2; exit 2; }
effort='' repo='' ref=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --repo | --ref)
			[ $# -ge 2 ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --repo) repo=$2 ;; --ref) ref=$2 ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
# Core is found as a neighbour skill of the installed layout: this script's
# skills folder, cut from its own path as text, so a skill link holds.
self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
core="${skills}/crucible-context/scripts/main"
[ -f "${core}/context-docs.sh" ] || refuse "core's context isn't beside this skill (expected ${skills}/crucible-context); install first"
case ${repo} in /*) ;; *) refuse '--repo must be an absolute folder' ;; esac
git -C "${repo}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || refuse "${repo} is not a git work tree"
printf '%s' "${ref}" | grep -Eq '^[0-9A-Za-z._/^~-]+(\.\.[0-9A-Za-z._/^~-]+)?$' || refuse "--ref ${ref} has characters a ref can't hold"
case ${ref} in -* | *..-*) refuse "--ref ${ref} starts with -" ;; esac

case ${ref} in
	*..*)
		from=$(git -C "${repo}" rev-parse --short "${ref%%..*}^{commit}" 2>/dev/null) || refuse "--ref ${ref%%..*} is not a commit"
		to=$(git -C "${repo}" rev-parse --short "${ref##*..}^{commit}" 2>/dev/null) || refuse "--ref ${ref##*..} is not a commit"
		name="diff-${from}..${to}.patch"; range="${from}..${to}" ;;
	*)
		sha=$(git -C "${repo}" rev-parse --short "${ref}^{commit}" 2>/dev/null) || refuse "--ref ${ref} is not a commit"
		name="diff-${sha}.patch"; range="${sha}^!" ;;
esac

docs=$(sh "${core}/context-docs.sh" --effort "${effort}") || exit 2
keep=$(mktemp)
trap 'rm -f -- "${keep}" "${docs}/.tmp.patch"' EXIT
git -C "${repo}" diff --name-only "${range}" | while IFS= read -r file; do
	if sh "${core}/context-path-check.sh" "${repo}/${file}" 2>/dev/null; then
		printf '%s\n' "${file}"
	else
		printf 'context-add-commit.sh: left out %s\n' "${file}" >&2
	fi
done >"${keep}"
[ -s "${keep}" ] || refuse "${ref} changes no file the context may hold"
# The kept files go to git as literal pathspecs, so none is read as a glob.
set --
while IFS= read -r file; do set -- "$@" ":(literal)${file}"; done <"${keep}"
git -C "${repo}" diff "${range}" -- "$@" >"${docs}/.tmp.patch" || refuse "git diff ${range} failed"
mv -f -- "${docs}/.tmp.patch" "${docs}/${name}"
printf '%s\n' "${docs}/${name}"
