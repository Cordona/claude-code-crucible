#!/usr/bin/env sh
# Says whether a path may be in a context, by the context's path rule.
# shellcheck source-path=SCRIPTDIR
set -eu

usage() {
	cat <<'USAGE'
usage: sh context-path-check.sh PATH

Says whether PATH, absolute, may go in a context, judging its text only, so
PATH need not exist. Use it before context-add.sh --path, or to filter files.

Reads:     CLAUDE_CONFIG_DIR, the Claude folder; default ~/.claude
Writes:    nothing
Stdout:    nothing
Exit:
  0  allowed
  2  not allowed, or not exactly one PATH; the reason is on stderr
USAGE
}

case ${1-} in -h | --help) usage; exit 0 ;; esac
[ $# -eq 1 ] || { printf 'context-path-check.sh: expected one PATH; try --help\n' >&2; exit 2; }
. "$(dirname -- "$0")/../lib/path-rule.sh"
problem=$(pr_problem "$1")
[ -z "${problem}" ] || { printf 'context-path-check.sh: %s %s\n' "$1" "${problem}" >&2; exit 2; }
