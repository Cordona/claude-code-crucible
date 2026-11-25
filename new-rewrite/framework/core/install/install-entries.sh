#!/usr/bin/env sh
# Prints what an install of the framework needs: the settings entries and the
# link commands, found by scanning the framework and its domains.
set -eu

usage() {
	cat <<'USAGE'
usage: sh install-entries.sh [--json]

Prints what an install of the framework it sits in needs, for the human to
apply. Use it to install or to see what an install needs; install-check.sh,
beside it, checks the result.

Options:
  --json   print one JSON object instead: {hooks:[{event, matcher, timeout,
           path, command_path}], skills:[{name, path}], claude_md, config,
           space, deny, env}; install-check.sh reads it
Finds:     components, the folders directly in a main-thread/ or an agents/
           folder, each linked by its folder name; hooks, from each
           component's hooks/matchers.json, whose keys start stop/,
           subagent-stop/, pre-tool-use/ or post-tool-use/, each value a
           matcher, null, or {matcher?, timeout?}, timeout in seconds; the
           settings env, from each component's hooks/env.json, {NAME:
           "value"}
Reads:     CLAUDE_CONFIG_DIR (default ~/.claude), where links and hook
           commands point; CRUCIBLE_HOME (default ~/.crucible), the space
Writes:    nothing
Stdout:    three sections, separated by blank lines:
           "# Settings entries: merge into your settings.json", then one
           JSON object {env, hooks, permissions:{additionalDirectories,
           deny}};
           "# Links: run these", then shell-quoted mkdir -p and ln -s lines;
           "# Needed on PATH: jq 1.6 or later"
Exit:
  0  printed
  2  refused, nothing printed; the reason is on stderr (a bad
     matchers.json or env.json, two components with one name, or two
     env.json giving one name different values)
USAGE
}

refuse() { printf 'install-entries.sh: %s\n' "$1" >&2; exit 2; }
json=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--json) json=1; shift ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq missing; expected jq 1.6 or later on PATH'

root=$(cd -- "$(dirname -- "$0")/../../.." && pwd)
config=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}
space=${CRUCIBLE_HOME:-${HOME}/.crucible}

# Every hook: {event, matcher, path}, from each component's matchers.json,
# each checked first, outside the pipe, so a bad one stops the script.
for file in $(find "${root}" -path '*/hooks/matchers.json' -type f); do
	jq -e 'type == "object" and all(to_entries[]; (.key | test("^(stop|subagent-stop|pre-tool-use|post-tool-use)/[^/]+\\.sh$"))
		and (.value == null or (.value | type) == "string"
			or ((.value | type) == "object" and ((.value | keys) - ["matcher", "timeout"]) == []
				and (.value.matcher == null or (.value.matcher | type) == "string")
				and (.value.timeout == null or ((.value.timeout | type) == "number" and .value.timeout >= 1)))))' "${file}" >/dev/null 2>&1 \
		|| refuse "${file} is not a valid matchers.json; expected {\"<event folder>/<hook>.sh\": <matcher, null, or {matcher?, timeout?}>}"
done
# path is the hook in the tree; command_path the same hook through its
# component's skill link, which the settings entry runs.
hooks=$(find "${root}" -path '*/hooks/matchers.json' -type f | LC_ALL=C sort | while IFS= read -r file; do
	component=${file%/hooks/matchers.json}
	jq -c --arg dir "${file%/matchers.json}" --arg link "${config}/skills/${component##*/}/hooks" 'to_entries[]
		| (if (.value | type) == "object" then .value else {matcher: .value} end) as $v | {
		event: ({"stop": "Stop", "subagent-stop": "SubagentStop", "pre-tool-use": "PreToolUse",
			"post-tool-use": "PostToolUse"}[.key | split("/")[0]]),
		matcher: $v.matcher, timeout: $v.timeout, path: ($dir + "/" + .key), command_path: ($link + "/" + .key)}' "${file}"
done | jq -s .)
# Every component: {name, path}, each folder directly in a main-thread or an
# agents folder; nothing inside a component is looked at.
skills=$(find "${root}" \( -path '*/main-thread/*' -o -path '*/agents/*' \) -prune \
	-o -type d \( -name main-thread -o -name agents \) -print | LC_ALL=C sort | while IFS= read -r parent; do
	for dir in "${parent}"/*/; do
		[ -d "${dir}" ] || continue
		dir=${dir%/}
		jq -cn --arg name "${dir##*/}" --arg path "${dir}" '{name: $name, path: $path}'
	done
done | jq -s 'sort_by(.name)')
# One installed name is one link, so two components with one name are refused.
twins=$(printf '%s\n' "${skills}" | jq -r 'group_by(.name) | map(select(length > 1))
	| map("\(.[0].name) (\(map(.path) | join(", ")))") | join("; ")')
[ -z "${twins}" ] || refuse "two components share a name, so one link can't hold both: ${twins}"

# The settings env: what each component's hooks/env.json needs, each file
# checked first, outside the pipe; two values for one name are refused.
env_files=$(find "${root}" -path '*/hooks/env.json' -type f | LC_ALL=C sort)
while IFS= read -r file; do
	[ -n "${file}" ] || continue
	jq -e 'type == "object" and all(to_entries[]; (.key | test("^[A-Z][A-Z0-9_]*$")) and (.value | type) == "string")' \
		"${file}" >/dev/null 2>&1 || refuse "${file} is not a valid env.json; expected {\"NAME\": \"value\"}"
done <<ENV_FILES
${env_files}
ENV_FILES
env=$(printf '%s\n' "${env_files}" | while IFS= read -r file; do
	[ -z "${file}" ] || jq -c --arg file "${file}" 'to_entries[] | . + {file: $file}' "${file}"
done | jq -s '.')
clash=$(printf '%s\n' "${env}" | jq -r 'group_by(.key) | map(select((map(.value) | unique | length) > 1))
	| map("\(.[0].key) (\(map("\(.value) in \(.file)") | join(", ")))") | join("; ")')
[ -z "${clash}" ] || refuse "two env.json give one name different values: ${clash}"
needs=$(jq -n --argjson hooks "${hooks}" --argjson skills "${skills}" --argjson env "${env}" \
	--arg claude_md "${root}/framework/core/CLAUDE.md" --arg config "${config}" --arg space "${space}" '
	{hooks: $hooks, skills: $skills, claude_md: $claude_md, config: $config, space: $space,
	 deny: ["Edit(/\($space)/efforts/*/events/**)"], env: ($env | map({(.key): .value}) | add // {})}')

if [ -n "${json}" ]; then
	printf '%s\n' "${needs}"
	exit 0
fi

# A shell-quoting helper for the printed commands; the quote comes in as $sq.
quote_jq='def q: $sq + gsub($sq; $sq + "\\" + $sq + $sq) + $sq;'

echo '# Settings entries: merge into your settings.json'
printf '%s\n' "${needs}" | jq --arg sq "'" "${quote_jq}"' {
	env: .env,
	hooks: (.hooks | group_by(.event) | map({key: .[0].event, value: (group_by(.matcher) | map(
		(if .[0].matcher == null then {} else {matcher: .[0].matcher} end)
		+ {hooks: map({type: "command", command: ("sh " + (.command_path | q))}
			+ (if .timeout == null then {} else {timeout} end))}))}) | from_entries),
	permissions: {additionalDirectories: [.space], deny: .deny}}'
echo
echo '# Links: run these'
printf '%s\n' "${needs}" | jq -r --arg sq "'" "${quote_jq}"'
	"mkdir -p \(.config + "/skills" | q)",
	(.skills[] as $s | "ln -s \($s.path | q) \((.config + "/skills/" + $s.name) | q)"),
	"ln -s \(.claude_md | q) \((.config + "/CLAUDE.md") | q)"'
echo
echo '# Needed on PATH: jq 1.6 or later'
