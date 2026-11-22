#!/usr/bin/env sh
# Writes a commit or range of a local git repository into the effort's
# context, as a patch in the draft's docs folder.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh context-add-commit.sh --effort FOLDER --repo ROOT --ref REF
       sh context-add-commit.sh --help | -h

Writes REF's diff into the context's draft docs folder as
diff-<sha>.patch (a range: diff-<sha>..<sha>.patch), replacing one of the
same name. Files the context's path rule refuses (secrets, instruction
files) are left out and named on stderr. ROOT is only read.

  --effort FOLDER   the effort's folder, absolute; the effort must be open
  --repo ROOT       the git work-tree root, absolute
  --ref REF         a commit, or a range A..B

stdout: the patch file, absolute
Runs installed only: core's crucible-context must be a neighbour skill in
the same skills folder.

Exit: 0 written; 2 refused, nothing written, the reason on stderr
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
skills=${self%/*/*/*}
core="${skills}/crucible-context/scripts"
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
