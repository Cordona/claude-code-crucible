#!/bin/sh
# Scores the matrix: score.sh real | control [CELL...]. Reads only the raw
# evidence run.sh collect saved per cell in logs/ (logs/control/ for the
# control run): the effort's events, its report files, its trees' git log
# and status, and the saved hook calls (input and output, one file each).
# Per cell, the scenario's expected events and the human's messages; then the
# audit. Prints one line per check, a table per cell, and exits 1 on any FAIL.
set -eu
EV=$(cd "$(dirname "$0")" && pwd)
mode=${1:-real}
logs="${EV}/logs"; [ "${mode}" = real ] || logs="${EV}/logs/control"
shift || true
work=$(mktemp -d "${TMPDIR:-/tmp}/matrix-score.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT

# facts CELL_DIR: one JSON object of everything the checks read.
facts() {
	d=$1
	set -- $(cat "${d}/cell")
	: >"${work}/reports"
	if [ -d "${d}/reports" ]; then
		find "${d}/reports" -type f | sort | while read -r f; do
			ro=false; [ -z "$(find "${f}" -prune -perm -200)" ] && ro=true
			j=$(jq -c . "${f}" 2>/dev/null) || j=null
			jq -n --arg p "${f#"${d}"/}" --arg s "$(shasum -a 256 "${f}" | cut -d' ' -f1)" --argjson ro "${ro}" --argjson j "${j:-null}" '{path: $p, sha256: $s, ro: $ro, json: $j}'
		done >"${work}/reports"
	fi
	# The trees' git: each commit with its Job trailer and files; each
	# tree's uncommitted status lines.
	awk '
		/^== tree / { if (sha != "") flush(); tree = substr($0, 9); mode = "log"; next }
		/^== status$/ { if (sha != "") flush(); mode = "status"; next }
		/^== repo / { if (sha != "") flush(); mode = "repo"; next }
		mode == "repo" && NF { printf "R\t-\t%s\n", $0; next }
		mode == "log" && /^commit [0-9a-f]{40}$/ { if (sha != "") flush(); sha = $2; job = ""; files = ""; body = 1; next }
		mode == "log" && body && /^Job: / { job = $2; next }
		mode == "log" && body && /^\.$/ { body = 0; next }
		mode == "log" && !body && NF { files = files (files == "" ? "" : "\t") $0; next }
		mode == "status" && NF { printf "S\t%s\t%s\n", tree, $0 }
		function flush() { printf "C\t%s\t%s\t%s\t%s\n", tree, sha, job, files; sha = "" }
		END { if (sha != "") flush() }' "${d}/git.txt" >"${work}/git"
	jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
		| {commits: [.[] | select(.[0] == "C") | {tree: .[1], sha: .[2], job: (.[3] | tonumber? // null), files: .[4:]}],
		   status: [.[] | select(.[0] == "S") | {tree: .[1], line: .[2]}],
		   repo: [.[] | select(.[0] == "R") | .[2]]}' "${work}/git" >"${work}/git.json"
	jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {tag: .[0], seq: (.[1] | tonumber), type: .[2]})' "${d}/jobs" >"${work}/jobs.json"
	ls "${d}"/hooks/*.json >/dev/null 2>&1 && jq -s '.' "${d}"/hooks/*.json >"${work}/hooks.json" || echo '[]' >"${work}/hooks.json"
	jq -n --arg cell "$1" --arg sc "$2" --arg kind "$3" --slurpfile events "${d}/events.json" \
		--slurpfile reports "${work}/reports" --slurpfile git "${work}/git.json" --slurpfile jobs "${work}/jobs.json" \
		--slurpfile hooks "${work}/hooks.json" \
		'{cell: $cell, sc: $sc, kind: $kind, events: $events[0], reports: $reports, git: $git[0], jobs: $jobs[0], hooks: $hooks[0]}'
}

# The checks, in jq: input the facts; output one {ok, what} per check.
# shellcheck disable=SC2016 # jq's program
checks='
def submitted_types: ["build.submitted", "build-fix.submitted", "test-plan.submitted", "test-plan.updated", "test.submitted",
	"test-fix.submitted", "review.submitted", "test-plan.challenged", "external-review.submitted", "foreign-review.submitted"];
def kind_of: if . == "review-hot" or . == "re-review" then "review" else . end;
def commits: IN("build", "build-fix", "test", "test-fix");
def s2_line:
	{"build": "summary starts with \"feat:\": drop the prefix", "build-fix": "list SHELL-02 in fixes",
	 "test-plan": "names B-1: say it in words", "test-plan-update": "answer C-1: applied or cannot",
	 "test": "list the mutation gate", "test-fix": "list TEST-01 in fixes", "review": "is an edge-case: add proof",
	 "review-hot": "is an edge-case: add proof", "re-review": "give SHELL-02 a status",
	 "test-plan-challenge": "target B-9 is not an ID in the plan", "external-review": "judge thread description",
	 "foreign-review": "is an edge-case: add proof"}[.];
def epoch: sub("Z$"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime;
def chk($ok; $what): {ok: ($ok == true), what: $what};
. as $f
| ($f.events) as $ev
| def of($seq): [$ev[] | select((.body.job // null) == $seq)];
  def refused($seq): [of($seq)[] | select(.type == "job.refused")];
  def subs($seq): [of($seq)[] | select(.type | IN(submitted_types[]))];
  def ended($seq): [of($seq)[] | select(.type == "job.ended")];
  def stalled($seq): [of($seq)[] | select(.type == "job.stalled")];
  def agent($seq): ([of($seq)[] | select(.type == "job.assigned") | .body.agent] | last);
  def assigned_at($seq): ([of($seq)[] | select(.type == "job.assigned") | .at] | last);
  def dispatched($seq): ([$ev[] | select(.type == "job.dispatched" and .seq == $seq)] | first);
  def report_file($seq): dispatched($seq).body.report;
  def pin_ok($s): ($s.body.report) as $r | any($f.reports[]; .path == $r.path and .sha256 == $r.sha256 and .ro);
  def commit_ok($s; $seq): ($s.body.commit // null) as $c | $c != null and any($f.git.commits[]; .sha == $c and .job == $seq);
  def no_commit($seq): ([$f.git.commits[] | select(.job == $seq)] | length) == 0;
  def hooks_of($a; $tag): [$f.hooks[] | select(.tag == $tag and .input.agent_id == $a)];
  def told($a; $re): any(hooks_of($a; "SubagentStop-submit-agent-work")[]; (.stdout | type) == "object" and ((.stdout.systemMessage // "") | test($re)));
  def lines_have($r; $re): any($r.body.lines[]; test($re));
  def after($a; $b): $a.seq > $b.seq;
  # One submission after one refusal with lines matching $re; pinned, and
  # committed when the kind commits.
  # R3: nothing from main to the agent (a SendMessage to it) between the
  # first refusal of the job and its submission.
  def main_silent($seq):
	agent($seq) as $a | refused($seq) as $r | subs($seq) as $s
	| ($r | length) > 0 and ($s | length) == 1
	  and ([$f.hooks[] | select(.tag == "PreToolUse-assign-job" and .input.tool_name == "SendMessage"
		and (.input.tool_input.to // .input.tool_input.recipient) == $a
		and .t_start >= ($r[0].at | epoch) and .t_start <= (($s[0].at | epoch) + 1))] | length) == 0;
  def refused_once_then_sub($seq; $re; $k; $label):
	refused($seq) as $r | subs($seq) as $s
	| chk(main_silent($seq); "\($label): no message from main to the agent between the refusal and the submission (R3)"),
	  chk(($r | length) == 1 and $r[0].body.try == 1 and lines_have($r[0]; $re); "\($label): job.refused try 1 with a line matching /\($re)/"),
	  chk(($s | length) == 1 and (ended($seq) | length) == 0 and ($r | length) == 1 and after($s[0]; $r[0]); "\($label): then the submission, no job.ended"),
	  chk(($s | length) == 1 and pin_ok($s[0]); "\($label): the pin matches the report, read-only"),
	  (if ($k | commits) then chk(($s | length) == 1 and commit_ok($s[0]; $seq); "\($label): the working commit, with its Job trailer") else empty end);
  def accepted_first($seq; $k; $label):
	subs($seq) as $s
	| chk((refused($seq) | length) == 0 and ($s | length) == 1 and (ended($seq) | length) == 0 and (stalled($seq) | length) == 0; "\($label): the submission, no refusal, no ending"),
	  chk(($s | length) == 1 and pin_ok($s[0]); "\($label): the pin matches the report, read-only"),
	  (if ($k | commits) then chk(($s | length) == 1 and commit_ok($s[0]; $seq); "\($label): the working commit, with its Job trailer") else empty end);
  def gave_up($seq; $re; $k; $label):
	refused($seq) as $r | ended($seq) as $e
	| chk(($r | length) == 2 and $r[0].body.try == 1 and $r[1].body.try == 2 and lines_have($r[0]; $re) and lines_have($r[1]; $re); "\($label): job.refused try 1 and try 2, lines matching /\($re)/"),
	  chk(($e | length) == 1 and $e[0].body.reason == "gave-up" and ($r | length) == 2 and after($e[0]; $r[1]); "\($label): job.ended gave-up after the second refusal"),
	  chk(told(agent($seq); "gave up: its report was refused twice"); "\($label): the human told it gave up"),
	  chk((subs($seq) | length) == 0 and ([$f.reports[] | select(.path == report_file($seq) and .ro)] | length) == 0; "\($label): nothing pinned"),
	  (if ($k | commits) then chk(no_commit($seq); "\($label): nothing committed") else empty end);
  $f.kind as $k | $f.sc as $sc
  | ($f.jobs | map({(.tag): .seq}) | add // {}) as $tags
  | if $sc == "S1" and $k == "review-hot" then
	accepted_first($tags.j1; "review"; "cold job"),
	accepted_first($tags.j2; "review"; "hot job"),
	chk(agent($tags.j1) != null and agent($tags.j1) == agent($tags.j2); "hot job: the same agent, assigned at SendMessage")
  elif $sc == "S4" and $k == "review-hot" then
	accepted_first($tags.j1; "review"; "cold job"),
	gave_up($tags.j2; ("review-hot" | s2_line); "review"; "hot job"),
	chk(agent($tags.j1) != null and agent($tags.j1) == agent($tags.j2); "hot job: the same agent, assigned at SendMessage")
  elif $sc == "S1" then accepted_first($tags.j1; $k; "job")
  elif $sc == "S2" then refused_once_then_sub($tags.j1; ($k | s2_line); $k; "job")
  elif $sc == "S3" then refused_once_then_sub($tags.j1; "^write your report as one JSON object to /.*/" + report_file($tags.j1) + "$"; $k; "job")
  elif $sc == "S4" then gave_up($tags.j1; ($k | s2_line); $k; "job")
  elif $sc == "S6" then refused_once_then_sub($tags.j1; "is past the end of the file \\([0-9]+ lines\\); write it as a file and line, such as `bin/x\\.sh:42`, or a JSON array of them"
		+ (if $k == "test-plan-challenge" then ", or leave `at` out when it isn.t in a file$" else "$" end); $k; "job")
  elif $sc == "S7" then
	refused_once_then_sub($tags.j1; if $k == "test" then "you changed src/upload/Client.kt, which isn.t in the approved plan: undo it" elif $k == "review" then "you changed files: undo your changes" else "undo the change to a.sh" end; $k; "job"),
	chk(([$f.git.status[]] | length) == 0 and ([$f.git.commits[] | select(.job == $tags.j1) | .files[] | select(. == "src/upload/Client.kt" or . == "a.sh")] | length) == 0; "job: the stray edit undone, nothing of it committed")
  elif $sc == "S8" then refused_once_then_sub($tags.j1; "^write your report as one JSON object to "; $k; "job")
  elif $sc == "S5a" then
	ended($tags.j1) as $e
	| chk(($e | length) == 1 and $e[0].body.reason == "fault" and $e[0].body.step == "check" and $e[0].by == "fault-ended.sh"; "job: job.ended fault, step check"),
	  chk(told(agent($tags.j1); "the job ends, nothing handed in"); "job: the human told of the fault"),
	  chk((subs($tags.j1) | length) == 0 and (refused($tags.j1) | length) == 0; "job: no refusal, no submission")
  elif $sc == "S5b" then
	stalled($tags.j1) as $st | subs($tags.j1) as $s | ended($tags.j1) as $e
	| chk(($st | length) == 1 and $st[0].body.step == "commit" and $st[0].by == "fault-stalled.sh"; "job: job.stalled, step commit"),
	  chk(told(agent($tags.j1); "its report is kept: .*recover-submission.sh"); "job: the human told, with the recover command"),
	  chk(([$f.reports[] | select(.path == report_file($tags.j1) and .ro)] | length) == 1; "job: the report pinned and kept"),
	  (if ($f.cell | test("giveup$")) then
		chk(($e | length) == 1 and $e[0].body.reason == "fault" and $e[0].body.step == "commit" and $e[0].by == "recover-submission.sh" and ($s | length) == 0; "--give-up: job.ended fault, step commit, by recover-submission.sh"),
		chk(no_commit($tags.j1); "--give-up: nothing committed")
	   else
		chk(($s | length) == 1 and $s[0].by == "recover-submission.sh" and ($e | length) == 0 and ($st | length) == 1 and after($s[0]; $st[0]); "--finish: the submission, by recover-submission.sh"),
		chk(($s | length) == 1 and pin_ok($s[0]) and commit_ok($s[0]; $tags.j1); "--finish: the pin matches; the working commit with its Job trailer")
	   end)
  elif $sc == "S9" then
	($f.jobs | map(.seq)) as $all
	| chk(($all | length) == 12; "twelve review jobs"),
	  chk(all($all[]; (refused(.) | length) == 1 and refused(.)[0].body.try == 1 and lines_have(refused(.)[0]; "is an edge-case: add proof")); "each refused once, try 1, its own repair line"),
	  chk(all($all[]; . as $j | refused($j)[0].body.agent == agent($j)
		and any(hooks_of(agent($j); "SubagentStop-submit-agent-work")[]; (.stdout | type) == "object" and .stdout.decision == "block" and (.stdout.reason | contains(report_file($j))))); "each block reached its own agent, naming its own report"),
	  chk(([$all[] | agent(.)] | unique | length) == 12; "twelve distinct agents"),
	  chk(all($all[]; main_silent(.)); "no message from main to any of them between its refusal and its submission (R3)"),
	  chk(all($all[]; . as $j | (subs($j) | length) == 1 and after(subs($j)[0]; refused($j)[0]) and pin_ok(subs($j)[0])); "twelve submissions, each pinned"),
	  ([$all[] | report_file(.) as $p | $f.reports[] | select(.path == $p) | .json.findings // [] | .[] | .id] ) as $ids
	  | chk(($ids | length) == 24 and ($ids | unique | length) == 24; "unique stamped IDs: \($ids | unique | length) of \($ids | length) across the twelve reports")
  elif $sc == "S10" then
	([$f.hooks[] | select(.tag == "PostToolUse-assign-job") | .input.tool_response.agentId // empty] | first) as $a
	| chk($a != null; "the agent started, with no job"),
	  chk(told($a; "no effort has a job assigned to it"); "the human told: a job-taking agent with no job (A0)"),
	  chk(([$ev[] | select(.type | startswith("job."))] | length) == 0; "no job event")
  elif $sc == "S11" then
	refused_once_then_sub($tags.j1; "^write your report as one JSON object to "; $k; "job"),
	chk(any(hooks_of(agent($tags.j1); "PreToolUse-job-agent-tools")[]; ((.input.tool_input.command // "") | test("tests/slow.sh 45")) and .input.tool_input.timeout == 10000 and .stdout.hookSpecificOutput.updatedInput.timeout == 30000); "the agent asked for timeout 10000 and the Bash hook forced 30000; the 45 s sleep outlived it and parked")
  elif $sc == "S12" then
	agent($tags.a) as $A | agent($tags.b) as $B | agent($tags.c1) as $C
	| chk((ended($tags.a) | length) == 1 and ended($tags.a)[0].body.reason == "no-stop" and ended($tags.a)[0].by == "end-gone-jobs.sh" and (subs($tags.a) | length) == 0; "the killed agent: job.ended no-stop, by end-gone-jobs.sh"),
	  chk(any($f.hooks[]; .tag == "Stop-end-gone-jobs" and ((.input.background_tasks // []) | any(.id == $B)) and ((.input.background_tasks // []) | any(.id == $A) | not)); "a turn end with the running agent listed and the killed one gone"),
	  chk((ended($tags.b) | length) == 0 and (subs($tags.b) | length) == 1; "the running agent: untouched, then its submission"),
	  chk((subs($tags.c1) | length) == 1 and $C != null and agent($tags.c2) == $C; "the hot agent: first job submitted, second assigned to it at SendMessage"),
	  chk(assigned_at($tags.c2) != null and any($f.hooks[]; .tag == "Stop-end-gone-jobs" and ((.input.background_tasks // []) | any(.id == $C)) and (.t_start + 1) >= (assigned_at($tags.c2) | epoch)); "a turn end while the hot agent ran its second job"),
	  chk((ended($tags.c2) | length) == 0 and (subs($tags.c2) | length) == 1; "the hot agent: untouched, then its submission")
  elif $sc == "S13" then
	chk(any(hooks_of(agent($tags.j1); "PreToolUse-job-agent-tools")[]; .input.tool_input.run_in_background == true and .stdout.hookSpecificOutput.permissionDecision == "deny"); "run_in_background denied by the Bash hook"),
	chk(any($f.hooks[]; .tag == "PreToolUse-job-agent-tools" and .input.agent_id == agent($tags.j1) and ((.input.tool_input.command // "") | test("tests/run.sh")) and (.input.tool_input.run_in_background != true)); "the command run again in the foreground"),
	accepted_first($tags.j1; $k; "job")
  elif $sc == "S14" then
	chk(any(hooks_of(agent($tags.j1); "PreToolUse-job-agent-tools")[]; .input.tool_name == "Write" and (.input.tool_input.file_path | endswith("/notes.txt"))
		and ((.input.tool_input.file_path | contains("/worktrees/")) | not) and .stdout.hookSpecificOutput.permissionDecision == "deny"
		and (.stdout.hookSpecificOutput.permissionDecisionReason | test("^Write only in .*/worktrees/"))); "the Write into the repo refused by write-scope, the reason naming the tree"),
	  chk(any($f.git.commits[]; .job == $tags.j1 and any(.files[]; . == "notes.txt")); "the file written in the tree instead, in the working commit"),
	  chk(($f.git.repo | length) == 0; "the repo stays clean"),
	  accepted_first($tags.j1; $k; "job")
  elif $sc == "S15" then
	chk(any(hooks_of(agent($tags.j1); "PermissionRequest-deny-compound-commands")[]; ((.input.tool_input.command // "") | test("^cd .* && git status$"))
		and .stdout.hookSpecificOutput.decision.behavior == "deny"
		and .stdout.hookSpecificOutput.decision.message == "Run it as plain single commands, one per call. Your other commands still run."); "cd before git: the PermissionRequest hook denies it, with its message"),
	  chk(any(hooks_of(agent($tags.j1); "PreToolUse-job-agent-tools")[]; ((.input.tool_input.command // "") | test("^git -C .*/worktrees/j status$"))
		and ((.stdout | type) != "object" or .stdout.hookSpecificOutput.permissionDecision != "deny"))
	    and ([hooks_of(agent($tags.j1); "PermissionRequest-deny-compound-commands")[] | select((.input.tool_input.command // "") | test("^git -C"))] | length) == 0; "rerun as git -C <tree> status, with no ask"),
	  accepted_first($tags.j1; $k; "job")
  else chk(false; "no expectation for \($sc)") end
'

# The audit, over one cell's events, reports and git.
# shellcheck disable=SC2016 # jq's program
audit='
def submitted_types: ["build.submitted", "build-fix.submitted", "test-plan.submitted", "test-plan.updated", "test.submitted",
	"test-fix.submitted", "review.submitted", "test-plan.challenged", "external-review.submitted", "foreign-review.submitted"];
def chk($ok; $what): {ok: ($ok == true), what: $what};
. as $f | $f.events as $ev
| [$ev[] | select(.type == "job.dispatched") | .seq] as $jobs
| def of($seq): [$ev[] | select((.body.job // null) == $seq)];
  chk(all($jobs[]; of(.) | any(.[]; .type | IN(submitted_types[]) or . == "job.ended")); "audit: every job ended or submitted"),
  chk(($f.sc == "S5b") or ([$ev[] | select(.type == "job.stalled")] | length) == 0; "audit: stalled only where the scenario expects it"),
  chk(all($ev[] | select(.type | IN(submitted_types[])); .body.report as $r | any($f.reports[]; .path == $r.path and .sha256 == $r.sha256)); "audit: every pinned report matches its hash"),
  chk(all($f.git.commits[] | select(.job != null); .sha as $c | any($ev[]; (.type | IN(submitted_types[])) and .body.commit == $c)); "audit: every working commit has its event"),
  chk(all($ev[] | select(.type == "job.refused"); . as $r | any(of($r.body.job)[]; .seq > $r.seq and ((.type | IN(submitted_types[])) or .type == "job.ended"))); "audit: every refusal followed by a submission or an end"),
  chk(all($jobs[]; ([of(.)[] | select(.type == "job.refused")] | length) <= 2); "audit: no job with more than two refusals")
'

pass=0 fail=0 red=0 cells=0
: >"${work}/table"
for d in "${logs}"/S*/; do
	d=${d%/}; cell=${d##*/}
	if [ $# -gt 0 ]; then keep=''; for w in "$@"; do [ "${w}" != "${cell}" ] || keep=1; done; [ -n "${keep}" ] || continue; fi
	facts "${d}" >"${work}/facts.json"
	jq -c "${checks}" "${work}/facts.json" >"${work}/c" 2>"${work}/cerr" || { echo "{\"ok\": false, \"what\": \"scorer error: $(head -n 1 "${work}/cerr" | tr '"' "'")\"}" >"${work}/c"; }
	jq -c "${audit}" "${work}/facts.json" >"${work}/a" 2>"${work}/aerr" || { echo "{\"ok\": false, \"what\": \"audit error: $(head -n 1 "${work}/aerr" | tr '"' "'")\"}" >"${work}/a"; }
	cf=$(jq -s '[.[] | select(.ok | not)] | length' "${work}/c")
	af=$(jq -s '[.[] | select(.ok | not)] | length' "${work}/a")
	cells=$((cells + 1))
	result=PASS; [ "${cf}" -eq 0 ] && [ "${af}" -eq 0 ] || { result=FAIL; red=$((red + 1)); }
	echo "== ${cell}: ${result}"
	cat "${work}/c" "${work}/a" | jq -r --arg c "${cell}" '"\(if .ok then "PASS" else "FAIL" end): \($c): \(.what)"'
	pass=$((pass + $(cat "${work}/c" "${work}/a" | jq -s '[.[] | select(.ok)] | length')))
	fail=$((fail + cf + af))
	# Scenario-level red for the control: the scenario's own checks.
	printf '%s %s %s\n' "${cell}" "${result}" "${cf}" >>"${work}/table"
	# In the control, the cell must be red on the check its scenario is
	# about: the reason the cell names.
	if [ "${mode}" = control ]; then
		case $(awk '{ print $2 "-" $3 }' "${d}/cell") in
			S1-review-hot) key='hot job: the submission' ;; S4-review-hot) key='hot job: job.refused try 1 and try 2' ;;
			S1-*) key='the submission, no refusal' ;; S2-* | S3-* | S6-* | S7-* | S8-* | S11-*) key='job.refused try 1 with a line' ;;
			S4-*) key='job.refused try 1 and try 2' ;; S5a-*) key='job.ended fault, step check' ;; S5b-*) key='job.stalled, step commit' ;;
			S9-*) key='each refused once' ;; S10-*) key='the human told: a job-taking agent with no job' ;;
			S12-*) key='job.ended no-stop' ;; S13-*) key='run_in_background denied' ;; S14-*) key='refused by write-scope' ;;
			S15-*) key='the PermissionRequest hook denies it' ;; *) key='no key' ;;
		esac
		why=$(jq -r --arg k "${key}" 'select((.ok | not) and (.what | contains($k))) | .what' "${work}/c" | head -n 1)
		if [ -n "${why}" ]; then echo "RED for its reason: ${cell}: ${why}"; printf '%s\n' "${cell}" >>"${work}/reasoned"
		else echo "NOT RED for its reason: ${cell} (its key check \"${key}\" did not fail)"; fi
	fi
done
echo
echo "== table (cell, result, failed scenario checks)"
cat "${work}/table"
# The hashes: new-rewrite the frozen one at setup and at collect, and the
# installed files the same as their source files, both times.
fw=ok
for when in setup collect; do
	h="${logs}/hashes-${when}.txt"
	if [ -f "${h}" ] && [ "$(sed -n 's/^frozen: *//p' "${h}")" = "$(sed -n 's/^new-rewrite: *//p' "${h}")" ] \
		&& [ "$(sed -n 's/^installed: *//p' "${h}")" = "$(sed -n 's/^source of the installed files: *//p' "${h}")" ] \
		&& [ -n "$(sed -n 's/^installed: *//p' "${h}")" ]; then
		echo "PASS: at ${when}, new-rewrite is the frozen $(sed -n 's/^frozen: *//p' "${h}" | cut -c1-12)…, and the installed files hash as their source ($(sed -n 's/^installed: *//p' "${h}" | cut -c1-12)…)"
	else
		fw=changed; fail=$((fail + 1)); echo "FAIL: at ${when}, a hash differs or is missing: see ${h}"
	fi
done
echo
echo "${pass} checks PASS, ${fail} FAIL; ${cells} cells, $((cells - red)) green, ${red} red"
# The hook cost: how long a job agent's Bash call spends in the PreToolUse
# wrapper job-agent-tools.sh, from the saved calls' start and end times.
# shellcheck disable=SC2016 # jq's program
find "${logs}/_sessions" -name 'PreToolUse-job-agent-tools-*.json' -type f -exec jq -c 'select(.input.agent_id != null) | {tool: .input.tool_name, ms: ((.t_end - .t_start) * 1000)}' {} + 2>/dev/null >"${work}/cost" || true
find "${logs}/_sessions" -name 'PreToolUse-guard-framework-*.json' -type f -exec jq -c 'select(.input.agent_id != null) | {tool: ("guard " + .input.tool_name), ms: ((.t_end - .t_start) * 1000)}' {} + 2>/dev/null >>"${work}/cost" || true
find "${logs}/_sessions" -name 'PermissionRequest-deny-compound-commands-*.json' -type f -exec jq -c 'select(.input.agent_id != null) | {tool: ("permission-request " + .input.tool_name), ms: ((.t_end - .t_start) * 1000)}' {} + 2>/dev/null >>"${work}/cost" || true
echo
echo "== hook cost (ms in the hook, per job-agent call, from the saved calls)"
jq -s -r 'group_by(.tool)[] | (map(.ms) | sort) as $m | ($m | length) as $n
	| "\(.[0].tool): n=\($n) median=\($m[($n / 2 | floor)] | round) p90=\($m[($n * 0.9 | floor)] | round) max=\($m[-1] | round)"' "${work}/cost"
if [ "${mode}" = control ]; then
	green=$(awk '$3 == 0' "${work}/table" | wc -l | tr -d ' ')
	reasoned=$(cat "${work}/reasoned" 2>/dev/null | wc -l | tr -d ' ')
	echo "control: cells whose own scenario checks all pass without the hooks: ${green} (must be 0)"
	echo "control: cells red for the reason their scenario names: ${reasoned} of ${cells}"
	[ "${green}" -eq 0 ] && [ "${reasoned}" -eq "${cells}" ] && [ "${fw}" = ok ]
else
	[ "${fail}" -eq 0 ] && [ "${fw}" = ok ]
fi
