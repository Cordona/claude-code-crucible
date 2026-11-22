#!/usr/bin/env sh
# Says whether a path may be in a context, by the context's path rule.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-path-check.sh PATH
       sh context-path-check.sh --help | -h

Checks PATH's text against the context's path rule: absolute, no quotes,
control characters or .. segments, no key, credential or secrets file, nothing
under .git or .ssh, no instruction file an agent may follow (CLAUDE.md,
SKILL.md, or the skills and agents in your Claude folder), and no personal
settings, which may hold secrets (settings.local.json anywhere, settings.json
in your Claude folder). A project's own .claude/settings.json is allowed.
Opens nothing.

Exit: 0 allowed, prints nothing; 2 not allowed, the reason on stderr
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
[ $# -eq 1 ] || { printf 'context-path-check.sh: expected one PATH; try --help\n' >&2; exit 2; }
. "$(dirname -- "$0")/lib/path-rule.sh"
problem=$(pr_problem "$1")
[ -z "${problem}" ] || { printf 'context-path-check.sh: %s %s\n' "$1" "${problem}" >&2; exit 2; }
