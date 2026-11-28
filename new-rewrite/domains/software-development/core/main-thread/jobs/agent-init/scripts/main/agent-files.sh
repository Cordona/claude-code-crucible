#!/usr/bin/env sh
# Writes the agent file each job of a proposal starts from: its base agent
# with the job's plugins as preloaded skills.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh agent-files.sh --proposal FILE

Writes, for each job in a proposal job-resolve.sh wrote, the agent file its
agent starts from: the kind's base agent, named for its plugin set, its
skills the base's own plus the job's plugins. A file already there is kept.
Run it when the jobs' card is shown: Claude Code sees a new agent file only
from the next turn, so the files are ready by the time the jobs start.

Options:
  --proposal FILE  a proposal file job-resolve.sh wrote
Requires:  jobs-define's kinds and each base agent beside this skill; each
           plugin installed as a skill the model may load
Reads:     CLAUDE_CONFIG_DIR, default ~/.claude
Writes:    CLAUDE_CONFIG_DIR/agents/NAME.md, one per base and plugin set
Stdout:    one line per agent file: "NAME written" or "NAME already there"
Exit:
  0  every file written or there
  2  refused, nothing written; the reason is on stderr
USAGE
}

prog='agent-files.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

proposal=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--proposal)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			proposal=$2
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
[ -f "${proposal}" ] || refuse "--proposal ${proposal} is not a file"
jq -e '(.jobs | type) == "array"' "${proposal}" >/dev/null 2>&1 || refuse "${proposal} is not a proposal: {jobs: [...]}"

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
kinds="${skills}/jobs-define/kinds"
[ -d "${kinds}" ] || refuse "jobs-define isn't beside this skill (expected ${kinds}); install first"
config=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}

work=$(mktemp -d "${TMPDIR:-/tmp}/agent-files.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT

# Each job's agent: {name, base, plugins}, once per name.
jq -s . "${kinds}"/*.json >/dev/null 2>&1 || refuse "a kind file in ${kinds} is not JSON"
for file in "${kinds}"/*.json; do
	kind=${file##*/}
	jq -c --arg k "${kind%.json}" '{($k): {agent, part}}' "${file}"
done | jq -s 'add' >"${work}/kinds"
# The plugin skills installed, by name: a part skill is used where it is.
installed=$(for f in "${config}"/skills/*/SKILL.md; do [ -f "${f}" ] || continue; d=${f%/SKILL.md}; printf '%s\n' "${d##*/}"; done | jq -R . | jq -sc .)
jq -c -L "${skills}" --slurpfile k "${work}/kinds" --argjson installed "${installed}" 'include "jobs-agent-init/scripts/lib/agent-name";
	[.jobs[] | $k[0][.kind] as $kd
	 | if $kd == null then error("kind \(.kind) is not a kind") else
	   {name: an_name($kd.agent; .plugins), base: $kd.agent, plugins: an_skills($kd.part; .plugins; $installed)} end]
	| unique_by(.name)[]' "${proposal}" >"${work}/agents" 2>"${work}/said" || refuse "$(cat "${work}/said")"

# Everything checked before the first file is written.
# shellcheck disable=SC2094 # the loop reads one file and writes others
while IFS= read -r agent; do
	base=$(printf '%s' "${agent}" | jq -r '.base')
	def="${skills}/${base}/${base}.md"
	[ -f "${def}" ] || refuse "base agent ${base} isn't installed beside this skill (expected ${def})"
	for skill in $(printf '%s' "${agent}" | jq -r '.plugins[]'); do
		file="${config}/skills/${skill}/SKILL.md"
		[ -f "${file}" ] || refuse "no skill ${skill} (expected ${file}): install its plugin"
		! awk 'NR == 1 && /^---$/ {fm = 1; next} fm && /^---$/ {exit} fm' "${file}" | grep -q '^disable-model-invocation: *true' \
			|| refuse "skill ${skill} is hidden from the model (disable-model-invocation), so an agent can't preload it"
	done
done <"${work}/agents"

mkdir -p "${config}/agents" || refuse "could not make ${config}/agents"
while IFS= read -r agent; do
	name=$(printf '%s' "${agent}" | jq -r '.name')
	out="${config}/agents/${name}.md"
	if [ -f "${out}" ]; then printf '%s already there\n' "${name}"; continue; fi
	base=$(printf '%s' "${agent}" | jq -r '.base')
	def="${skills}/${base}/${base}.md"
	# The base's definition, its name replaced and the plugins added to its
	# skills; everything else, its body included, as the base has it.
	awk -v name="${name}" -v plugins="$(printf '%s' "${agent}" | jq -r '.plugins | join(" ")')" '
		NR == 1 && /^---$/ { fm = 1; print; next }
		fm && /^---$/ { if (inskills) { n = split(plugins, p, " "); for (i = 1; i <= n; i++) print "  - " p[i] } fm = 0; inskills = 0; print; next }
		fm && /^name:/ { print "name: " name; next }
		fm && /^skills:/ { inskills = 1; print; next }
		fm && inskills && !/^  - / { n = split(plugins, p, " "); for (i = 1; i <= n; i++) print "  - " p[i]; inskills = 0 }
		{ print }' "${def}" >"${out}.tmp" && mv -f -- "${out}.tmp" "${out}" || refuse "could not write ${out}"
	printf '%s written\n' "${name}"
done <"${work}/agents"
