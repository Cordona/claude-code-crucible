#!/usr/bin/env sh
# Checks that what an install needs is in place, and names what is missing.
# Reads only: it never changes settings or links.
set -eu

usage() {
	cat <<'USAGE'
usage: sh install-check.sh [--settings FILE]...
       sh install-check.sh --help | -h

Compares what is installed with what install-entries.sh (beside this script)
says an install needs, and prints one line per thing missing:
  missing: jq 1.6 or later on PATH
  missing: <event> hook [<matcher>] <script>
  missing: hook script <script> (named in the settings, but not there)
  missing: skill link <skills folder>/<name> -> <folder>
  missing: CLAUDE.md link -> <core CLAUDE.md>
  missing: additional directory <space>
  missing: deny rule <rule>
A hook counts when an entry for its event and matcher runs a command naming
its script through its component's link in the skills folder. A link counts
when it resolves to the framework's file or folder; CLAUDE.md may be linked in the Claude folder or
as ./CLAUDE.md. A Claude folder whose CLAUDE.md is the human's own file
reads as missing until they move over: that is expected, not a fault. Nothing is changed: the human installs, using
install-entries.sh's output.

  --settings FILE   a settings file to read; repeatable. Default: the
                    Claude folder's settings.json, and ./.claude/settings.json
                    and ./.claude/settings.local.json, each when present.
                    Their entries count together, as Claude Code merges them.

Environment: CLAUDE_CONFIG_DIR (default ~/.claude), CRUCIBLE_HOME (default
  ~/.crucible)
stdout: the missing lines, or "installed" when nothing is
Exit: 0 everything in place; 1 something missing; 2 a usage error
USAGE
}

refuse() { printf 'install-check.sh: %s\n' "$1" >&2; exit 2; }
here=$(cd -- "$(dirname -- "$0")" && pwd)
config=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}
work=$(mktemp -d "${TMPDIR:-/tmp}/install-check.XXXXXX") || refuse 'mktemp failed'
trap 'rm -rf -- "${work}"' EXIT
: >"${work}/files"
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--settings)
			[ $# -ge 2 ] || refuse '--settings needs a value'
			[ -f "$2" ] && [ -r "$2" ] || refuse "--settings $2 is not a readable file"
			printf '%s\n' "$2" >>"${work}/files"
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done

# jq first: every check below needs it, and so does every hook.
jq_version=$(jq --version 2>/dev/null || true)
case ${jq_version} in
	jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
	*) echo 'missing: jq 1.6 or later on PATH'; exit 1 ;;
esac

if [ ! -s "${work}/files" ]; then
	for file in "${config}/settings.json" ./.claude/settings.json ./.claude/settings.local.json; do
		[ -f "${file}" ] && printf '%s\n' "${file}" >>"${work}/files"
	done
fi
# Each file checked first, outside the pipe, so a bad one stops the script.
while IFS= read -r file; do
	jq -e 'type == "object"' "${file}" >/dev/null 2>&1 || refuse "${file} is not a JSON object"
done <"${work}/files"
# The settings merged: hooks per event concatenated, the permission lists joined.
while IFS= read -r file; do cat -- "${file}"; done <"${work}/files" | jq -s '{
	hooks: (map(.hooks // {} | to_entries) | add // [] | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries),
	dirs: (map(.permissions.additionalDirectories // []) | add // []),
	deny: (map(.permissions.deny // []) | add // [])}' >"${work}/settings.json"

sh "${here}/install-entries.sh" --json >"${work}/needs.json" || refuse 'install-entries.sh failed; run it alone to see why'

# Settings: hooks, the space, the deny rules.
jq -r --slurpfile s "${work}/settings.json" '$s[0] as $set
	| (.hooks[] as $h
		| ($set.hooks[$h.event] // []) as $groups
		| if any($groups[]; ((.matcher // null) as $m | $m == $h.matcher or ($h.matcher == null and $m == ""))
			and any(.hooks[]?; (.command // "") | contains($h.command_path)))
		  then empty
		  else "missing: \($h.event) hook \(if $h.matcher then "[\($h.matcher)] " else "" end)\($h.command_path)" end),
	(.space as $space | if any($set.dirs[]; . == $space) then empty else "missing: additional directory \($space)" end),
	(.deny[] as $rule | if any($set.deny[]; . == $rule) then empty else "missing: deny rule \($rule)" end)' \
	"${work}/needs.json" >"${work}/missing"

# The hook scripts themselves.
jq -r '.hooks[].path' "${work}/needs.json" | while IFS= read -r path; do
	[ -f "${path}" ] || printf 'missing: hook script %s\n' "${path}"
done >>"${work}/missing"

# Links: each skill folder, and CLAUDE.md.
resolves_to() { [ -e "$1" ] && [ "$(realpath "$1" 2>/dev/null)" = "$(realpath "$2" 2>/dev/null)" ]; }
jq -r '.skills[] | "\(.name)\t\(.path)"' "${work}/needs.json" | while IFS="$(printf '\t')" read -r name path; do
	resolves_to "${config}/skills/${name}" "${path}" || printf 'missing: skill link %s -> %s\n' "${config}/skills/${name}" "${path}"
done >>"${work}/missing"
claude_md=$(jq -r '.claude_md' "${work}/needs.json")
resolves_to "${config}/CLAUDE.md" "${claude_md}" || resolves_to ./CLAUDE.md "${claude_md}" \
	|| printf 'missing: CLAUDE.md link -> %s\n' "${claude_md}" >>"${work}/missing"

if [ -s "${work}/missing" ]; then
	cat "${work}/missing"
	exit 1
fi
echo installed
