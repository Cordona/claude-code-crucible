#!/usr/bin/env sh
# The door: checks that a defined job can start, and prints the one call
# main sends to start it, cold (an Agent call) or hot (a SendMessage).
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh job-assign.sh --effort FOLDER --job SEQ [--tree SEQ] [--hot AGENT]

Checks that job SEQ can start and prints the call to send: an Agent call
for a fresh agent, or with --hot a SendMessage to an agent that already
ran a job. Send it exactly as printed.

Options:
  --effort FOLDER  the effort's folder, absolute
  --job SEQ        the job's job.defined seq
  --tree SEQ       for a job that cuts its tree: the worktree.cut you made
  --hot AGENT      the agent to give the job to; it must stand in the tree
Requires:  the job's agent file (agent-files.sh), for a fresh agent
Reads:     CLAUDE_CODE_SESSION_ID, CLAUDE_CONFIG_DIR
Writes:    no event; a note for this session, which the start or the send
           is matched by
Stdout:    one line to read, then the call as one JSON line
Exit:
  0  printed
  2  refused, nothing printed; the reason is on stderr
USAGE
}

prog='job-assign.sh'
refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

effort='' job='' tree='' hot=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--effort | --job | --tree | --hot)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --effort) effort=$2 ;; --job) job=$2 ;; --tree) tree=$2 ;; --hot) hot=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
case ${effort} in /*) ;; *) refuse '--effort must be an absolute folder' ;; esac
[ -d "${effort}/events" ] || refuse "${effort} is not an effort folder"
printf '%s\n' "${job}" | grep -Eqx '[1-9][0-9]*' || refuse '--job must be a whole number from 1'
[ -z "${tree}" ] || printf '%s\n' "${tree}" | grep -Eqx '[1-9][0-9]*' || refuse '--tree must be a whole number from 1'
case ${hot} in *[!A-Za-z0-9._-]*) refuse '--hot must be an agent id: letters, digits, ., _ or -' ;; *) ;; esac
session=${CLAUDE_CODE_SESSION_ID:-}
case ${session} in '' | *[!A-Za-z0-9._-]*) refuse 'CLAUDE_CODE_SESSION_ID is unset or unsafe: run this from a Claude Code session' ;; *) ;; esac

self=$0
case ${self} in /*) ;; *) self="$(pwd)/${self}" ;; esac
skills=${self%/*/*/*/*}
reader="${skills}/crucible-events/scripts/internal/events-read.sh"
kinds="${skills}/jobs-define/kinds"
for need in "${reader}" "${kinds}" "${skills}/jobs-agent-init/scripts/lib/agent-name.jq"; do
	[ -e "${need}" ] || refuse "a neighbour isn't beside this skill (expected ${need}); install first"
done
config=${CLAUDE_CONFIG_DIR:-${HOME}/.claude}
notes="${config}/cache/jobs-assign/${session}"

work=$(mktemp -d "${TMPDIR:-/tmp}/job-assign.XXXXXX") || refuse 'mktemp could not make a work folder'
trap 'rm -rf -- "${work}"' EXIT
sh "${reader}" --effort "${effort}" >"${work}/events" || refuse 'the effort'"'"'s events could not be read'
for file in "${kinds}"/*.json; do
	kind=${file##*/}
	jq -c --arg k "${kind%.json}" '{($k): .}' "${file}"
done | jq -s 'add' >"${work}/kinds"

# Every check on the log, in one pass: the job, its tree, the tree's open
# writer, and for a hot job the agent.
installed=$(for f in "${config}"/skills/*/SKILL.md; do [ -f "${f}" ] || continue; d=${f%/SKILL.md}; printf '%s\n' "${d##*/}"; done | jq -R . | jq -sc .)
jq -c -L "${skills}" --argjson installed "${installed}" --argjson j "${job}" --arg tree "${tree}" --arg hot "${hot}" --slurpfile k "${work}/kinds" \
	--arg effort "${effort}" '
	include "jobs-agent-init/scripts/lib/agent-name";
	. as $all
	| def finished($x): any($all[]; (.type == "job.ended" or (.body.report | type) == "object") and .body.job == $x);
	  def defined($x): first($all[] | select(.type == "job.defined" and .seq == $x)) // null;
	  def event($x): first($all[] | select(.seq == $x)) // null;
	  defined($j) as $d
	| if $d == null then {err: "job \($j) is not defined"} else
	  $d.body as $b | $k[0][$b.kind] as $kd
	| (if $b.work.tree.use then $b.work.tree.use elif $tree != "" then ($tree | tonumber) else null end) as $t
	| event($t) as $cut
	| [$all[] | select(.type == "job.assigned" and .body.tree == $t) | .body.job | select(finished(.) | not)
	   | defined(.) as $o | select($o != null and $k[0][$o.body.kind].write_scope == "tree") | {job: ., kind: $o.body.kind}] as $writers
	| {kind: $b.kind, base: $kd.agent, type: an_name($kd.agent; $b.plugins), plugins: an_skills($kd.part; $b.plugins; $installed),
	   tree: $t, path: $cut.body.path, writes: ($kd.write_scope == "tree"), writer: ($writers | first),
	   refs: [$b.input_refs | to_entries[] | .key as $key | [.value] | flatten[] | event(.) as $ev
		| {key: $key, path: (if $ev.type == "spec.approved" then $ev.body.path
			elif $ev.type == "context.cut" then "\($effort)/context/v\($ev.body.version)"
			elif ($ev.body.report | type) == "object" then "\($effort)/\($ev.body.report.path)"
			else "\($effort)/events/\($ev.seq | tostring | ("000000" + .)[-6:])-\($ev.type).json" end)}],
	   range: $b.work.range, known_failures: ($b.work.known_failures // []),
	   err: (if $kd == null then "job \($j)'"'"'s kind \($b.kind) is not a kind"
		elif any($all[]; .type == "job.assigned" and .body.job == $j) then "job \($j) is already assigned"
		elif finished($j) then "job \($j) has ended"
		elif $b.work.tree.use and $tree != "" then "job \($j) uses tree \($b.work.tree.use); give no --tree"
		elif $b.work.tree.cut and $tree == "" then "job \($j) cuts its tree: cut it with git-worktree'"'"'s worktree-cut.sh (repo \($b.work.tree.cut.repo), from \($b.work.tree.cut.from)), then run this again with --tree, its worktree.cut seq"
		elif $cut == null or $cut.type != "worktree.cut" then "\($t) is not a worktree.cut"
		elif $b.work.tree.cut and $cut.body.repo != $b.work.tree.cut.repo then "worktree.cut \($t) is of \($cut.body.repo); job \($j) cuts in \($b.work.tree.cut.repo)"
		elif $b.work.tree.cut and $cut.body.from != $b.work.tree.cut.from then "worktree.cut \($t) is from \($cut.body.from | tojson); job \($j) asks \($b.work.tree.cut.from | tojson)"
		elif $b.work.tree.cut and (any($all[]; .type == "job.assigned" and .body.tree == $t)
			or any($all[]; .type == "job.defined" and .seq != $j and .body.work.tree.use == $t))
		then "worktree.cut \($t) is already another job'"'"'s tree; job \($j) cuts a fresh one"
		elif $kd.write_scope == "tree" and ($writers | length) > 0
		then "tree \($t) has an open \($writers[0].kind), job \($writers[0].job): one open writing job per tree"
		else null end)}
	  end
	| . + (if .err == null and $hot != "" then
		(first($all[] | select(.type == "agent.initialized" and .body.agent == $hot)) // null) as $i
		| ([$all[] | select(.type == "job.assigned" and .body.agent == $hot) | .body] | last) as $last
		| {err: (if $i == null then "agent \($hot) never started a job: start a fresh agent"
			elif $i.body.base != .base then "agent \($hot) is a \($i.body.base); job \($j) needs a \(.base)"
			elif (.plugins - $i.body.plugins | length) > 0 then "agent \($hot) lacks \(.plugins - $i.body.plugins | join(", ")): start a fresh agent"
			elif $last != null and (finished($last.job) | not) then "agent \($hot) still works on job \($last.job): one open job per agent"
			elif $last.tree != .tree then "agent \($hot) stands in tree \($last.tree), not \(.tree): start a fresh agent"
			else null end)}
	  else {} end)' "${work}/events" >"${work}/info" 2>"${work}/said" || refuse "the log could not be read: $(head -n 1 "${work}/said")"
err=$(jq -r '.err // empty' "${work}/info")
[ -z "${err}" ] || refuse "${err}"

type=$(jq -r '.type' "${work}/info")
if [ -z "${hot}" ] && [ ! -f "${config}/agents/${type}.md" ]; then
	refuse "no agent file ${type} (expected ${config}/agents/${type}.md): run jobs-agent-init's agent-files.sh on the proposal, then start it from the next turn"
fi

# The job, as its agent reads it: where it works, where it reports, what
# to read first.
# A ref names a file only when it is there: an empty context cut has none.
jq -c '.refs' "${work}/info" | jq -c '.[]' | while IFS= read -r ref; do
	path=$(printf '%s' "${ref}" | jq -r '.path')
	if [ -e "${path}" ]; then printf '%s' "${ref}" | jq -c '. + {exists: true}'; else printf '%s' "${ref}" | jq -c '. + {exists: false}'; fi
done | jq -s '.' >"${work}/refs"
jq --slurpfile r "${work}/refs" '.refs = $r[0]' "${work}/info" >"${work}/info.next" && mv -f -- "${work}/info.next" "${work}/info"
prompt=$(jq -r --argjson j "${job}" --arg effort "${effort}" '
	"Job \($j), a \(.kind).",
	"Tree: \(.path)",
	"Report: \($effort)/reports/\(.kind)/\($j).json",
	(.refs[] | select(.exists) | "\(.key | ascii_upcase[:1] + .[1:]): \(.path)"),
	(if .range then "Range: \(.range.base)..\(.range.head)" else empty end),
	(if (.known_failures | length) > 0 then "Known failures: \(.known_failures | join(", "))" else empty end)' "${work}/info")
mkdir -p "${notes}" "${effort}/reports/$(jq -r '.kind' "${work}/info")" || refuse "could not make ${notes}"
# A reader on a tree with an open writer may start; main is told.
jq -r 'if .writer != null then "tree \(.tree) has an open \(.writer.kind), job \(.writer.job)" else empty end' "${work}/info" >&2

if [ -n "${hot}" ]; then
	jq -c --argjson j "${job}" --arg effort "${effort}" --arg agent "${hot}" --arg m "${prompt}" \
		'{job: $j, effort: $effort, agent: $agent, message: $m, tree: .tree}' "${work}/info" >"${notes}/hot-${hot}-${job}.json"
	echo 'Send it as printed.'
	jq -cn --arg to "${hot}" --arg m "${prompt}" '{tool: "SendMessage", to: $to, message: $m}'
else
	jq -c --argjson j "${job}" --arg effort "${effort}" --arg m "${prompt}" \
		'{job: $j, effort: $effort, subagent_type: .type, description: "job-\($j)", prompt: $m, isolation: "worktree",
		  tree: .tree, path: .path, base: .base, plugins: .plugins}' "${work}/info" >"${notes}/cold-${job}.json"
	echo 'Send one per message; send the next as soon as this one returns, in the same turn.'
	jq -cn --arg t "${type}" --argjson j "${job}" --arg m "${prompt}" \
		'{tool: "Agent", subagent_type: $t, description: "job-\($j)", prompt: $m, isolation: "worktree"}'
fi
