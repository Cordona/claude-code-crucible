#!/usr/bin/env sh
# Checks that what an install needs is in place, and names what is missing.
# Reads only: it never changes settings or links.
set -eu

usage() {
	cat <<'USAGE'
usage: sh install-check.sh [--settings FILE]...

Run by the human, after installing, from the project folder; not for main
to call. Checks the install against what install-entries.sh says it needs,
and each component against the folder contract: SKILL.md or its agent
definition <name>.md, flow-step.json, and only the folders references/,
scripts/ (main/, internal/, lib/, and agent/ for scripts agents may run,
which none has yet), hooks/ (matchers.json, env.json, one folder per event,
steps/ beneath), events/, submissions/ and kinds/.

Options:
  --settings FILE  a settings file to read; repeatable; default
                   $CLAUDE_CONFIG_DIR/settings.json, ./.claude/settings*.json
Reads:     CLAUDE_CONFIG_DIR (default ~/.claude), CRUCIBLE_HOME (~/.crucible)
Writes:    nothing
Stdout:    "installed"; or one "missing: <what>" line per gap, and one
           "extra: <what>" line per registered hook step and per folder
           outside the contract; the human's own CLAUDE.md shows as missing
Exit:
  0  everything in place
  1  something missing or extra
  2  refused, nothing changed; the reason is on stderr
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
# The settings merged: hooks per event concatenated, the permission lists
# joined, env the later file's value.
while IFS= read -r file; do cat -- "${file}"; done <"${work}/files" | jq -s '{
	env: (map(.env // {}) | add // {}),
	hooks: (map(.hooks // {} | to_entries) | add // [] | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries),
	dirs: (map(.permissions.additionalDirectories // []) | add // []),
	deny: (map(.permissions.deny // []) | add // [])}' >"${work}/settings.json"

sh "${here}/install-entries.sh" --json >"${work}/needs.json" || refuse 'install-entries.sh failed; run it alone to see why'

# Settings: hooks, each with its timeout, the space, the deny rules, env.
jq -r --slurpfile s "${work}/settings.json" '$s[0] as $set
	| (.hooks[] as $h
		| ($set.hooks[$h.event] // []) as $groups
		| if any($groups[]; ((.matcher // null) as $m | $m == $h.matcher or ($h.matcher == null and $m == ""))
			and any(.hooks[]?; ((.command // "") | contains($h.command_path)) and ($h.timeout == null or .timeout == $h.timeout)))
		  then empty
		  else "missing: \($h.event) hook \(if $h.matcher then "[\($h.matcher)] " else "" end)\($h.command_path)\(if $h.timeout then " with timeout \($h.timeout)" else "" end)" end),
	(.env | to_entries[] as $v | if $set.env[$v.key] == $v.value then empty else "missing: env \($v.key)=\($v.value)" end),
	($set.hooks | to_entries[] | .key as $event | .value[]?.hooks[]? | (.command // "") | select(test("/hooks/[a-z-]+/steps/"))
		| "extra: \($event) hook step \(.) is registered; register only its wrapper"),
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

# The folder contract: what folders a component may hold.
jq -r '.skills[] | select(.plugin | not) | .path' "${work}/needs.json" | while IFS= read -r component; do
	for folder in "${component}"/*/ "${component}"/scripts/*/; do
		[ -d "${folder}" ] || continue
		folder=${folder%/}
		case ${folder#"${component}"/} in
			references | scripts | hooks | events | submissions | kinds) ;;
			scripts/main | scripts/internal | scripts/lib | scripts/agent) ;;
			*) printf 'extra: folder %s is outside the component contract\n' "${folder}" ;;
		esac
	done
done >>"${work}/missing"

if [ -s "${work}/missing" ]; then
	cat "${work}/missing"
	exit 1
fi
echo installed
