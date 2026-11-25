#!/bin/sh
# Scores step 4: score.sh [CELL...]. Reads only the raw evidence run.sh
# collect saved per cell in logs/: the effort's events, its report files, its
# trees' git log and status, the saved hook calls, and the cell agent's
# transcript (for the model it ran on and the prompt it got). The facts and
# the audit are the matrix's (evidence/stop-hook-matrix/score.sh), unchanged;
# the scenario checks are step 4's: the outcome, the pin and commit, the
# model, the prompt, no tracker call, and a builder's or tester's allowed
# gates reported run. Then the per-kind counts, the refusal
# lines and the flagged lines, into counts.md. Exits 1 on any FAIL.
set -eu
EV=$(cd "$(dirname "$0")" && pwd)
logs="${EV}/logs"
work=$(mktemp -d "${TMPDIR:-/tmp}/real-score.XXXXXX")
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
		mode == "log" && /^commit [0-9a-f]{40}$/ { if (sha != "") flush(); sha = $2; job = ""; files = ""; body = 1; next }
		mode == "log" && body && /^Job: / { job = $2; next }
		mode == "log" && body && /^\.$/ { body = 0; next }
		mode == "log" && !body && NF { files = files (files == "" ? "" : "\t") $0; next }
		mode == "status" && NF { printf "S\t%s\t%s\n", tree, $0 }
		function flush() { printf "C\t%s\t%s\t%s\t%s\n", tree, sha, job, files; sha = "" }
		END { if (sha != "") flush() }' "${d}/git.txt" >"${work}/git"
	jq -R -s 'split("\n") | map(select(length > 0) | split("\t"))
		| {commits: [.[] | select(.[0] == "C") | {tree: .[1], sha: .[2], job: (.[3] | tonumber? // null), files: .[4:]}],
		   status: [.[] | select(.[0] == "S") | {tree: .[1], line: .[2]}]}' "${work}/git" >"${work}/git.json"
	jq -R -s 'split("\n") | map(select(length > 0) | split(" ") | {tag: .[0], seq: (.[1] | tonumber), type: .[2]})' "${d}/jobs" >"${work}/jobs.json"
	ls "${d}"/hooks/*.json >/dev/null 2>&1 && jq -s '.' "${d}"/hooks/*.json >"${work}/hooks.json" || echo '[]' >"${work}/hooks.json"
	jq -n --arg cell "$1" --arg sc "$2" --arg kind "$3" --slurpfile events "${d}/events.json" \
		--slurpfile reports "${work}/reports" --slurpfile git "${work}/git.json" --slurpfile jobs "${work}/jobs.json" \
		--slurpfile hooks "${work}/hooks.json" \
		'{cell: $cell, sc: $sc, kind: $kind, events: $events[0], reports: $reports, git: $git[0], jobs: $jobs[0], hooks: $hooks[0]}'
}

# The step-4 facts beyond the matrix's: the models in the agent's transcript,
# whether its first user message is the prepared prompt, the session's stub
# log, and, after a submission, what is uncommitted in the tree.
facts_real() {
	d=$1
	b=$(cat "${d}/batch")
	cat "${d}"/transcripts/*.jsonl 2>/dev/null | jq -s '[.[] | select(.type == "assistant") | .message.model // empty] | unique' >"${work}/models.json" || echo '[]' >"${work}/models.json"
	[ -s "${work}/models.json" ] || echo '[]' >"${work}/models.json"
	first=$(cat "${d}"/transcripts/*.jsonl 2>/dev/null | jq -rs '[.[] | select(.type == "user" and (.isMeta | not))][0].message.content
		| if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | join("")) else "" end' 2>/dev/null) || first=''
	prompt_ok=false
	[ -n "${first}" ] && [ "${first}" = "$(cat "${d}/prompt.txt")" ] && prompt_ok=true
	# The agent's own tracker calls: its Bash commands naming gh or glab, from
	# its PreToolUse calls (an interactive client's own start-up call to gh
	# is not the agent's).
	a=$(cat "${d}/agent" 2>/dev/null)
	stub=$(find "${d}/hooks" -name 'PreToolUse-job-agent-tools-*.json' -type f -exec jq -r --arg a "${a}" 'select(.input.agent_id == $a and .input.tool_name == "Bash") | .input.tool_input.command' {} + 2>/dev/null | grep -c -E '(^|[^A-Za-z0-9_-])(gh|glab)( |$)') || true
	[ -n "${stub}" ] || stub=0
	unc=0; [ ! -s "${d}/tree-uncommitted.diff" ] || unc=1
	# R3: main's own SendMessage calls in the cell's session (one agent per
	# session, so any of them would be to this agent).
	sends=$(jq -s '[.[] | select(.type == "assistant" and .parent_tool_use_id == null) | .message.content[]? | select(.type == "tool_use" and .name == "SendMessage")] | length' "${logs}/_sessions/${b}/main.jsonl" 2>/dev/null) || sends=-1
	# The run's hashes, at setup and at collect: new-rewrite is the frozen
	# hash, and the installed copy is its source.
	suf=${b#"${cell}"} fw=true
	frozen=$(cat "${EV}/../framework-hash.txt")
	for w in setup collect; do
		h="${EV}/hashes/run${suf}-${w}.txt"
		[ -s "${h}" ] && [ "$(sed -n 's/^new-rewrite: *//p' "${h}")" = "${frozen}" ] \
			&& [ "$(sed -n 's/^installed: *//p' "${h}")" = "$(sed -n 's/^source of the installed files: *//p' "${h}")" ] \
			&& [ -n "$(sed -n 's/^installed: *//p' "${h}")" ] || fw=false
	done
	# The submission commit's files, and the commit's tests run at collect.
	awk -F'\t' 'NF == 3 { printf "{\"file\": \"%s\", \"added\": %s}\n", $3, ($1 == "-" ? 0 : $1) }' "${d}/commit-numstat.txt" 2>/dev/null | jq -s . >"${work}/numstat.json" || echo '[]' >"${work}/numstat.json"
	[ -s "${work}/numstat.json" ] || echo '[]' >"${work}/numstat.json"
	trun=null; [ ! -f "${d}/tests-run.txt" ] || trun=$(sed -n 's/^exit //p' "${d}/tests-run.txt" | tail -n 1)
	[ -n "${trun}" ] || trun=null
	if [ -f "${d}/chosen.json" ]; then cp "${d}/chosen.json" "${work}/chosen.json"; else echo '[]' >"${work}/chosen.json"; fi
	jq --slurpfile m "${work}/models.json" --argjson p "${prompt_ok}" --argjson stub "${stub}" --argjson unc "${unc}" \
		--argjson sends "${sends}" --argjson fw "${fw}" --slurpfile ns "${work}/numstat.json" --argjson trun "${trun}" --slurpfile chosen "${work}/chosen.json" \
		'. + {models: $m[0], prompt_ok: $p, stub_calls: $stub, uncommitted: ($unc == 1), main_sends: $sends, framework_same: $fw,
		      numstat: $ns[0], tests_run: $trun, chosen: $chosen[0]}'
}

# Step 4's checks, in jq: input the facts; output one {ok, what} per check,
# and one {outcome} line.
# shellcheck disable=SC2016 # jq's program
checks='
def submitted_types: ["build.submitted", "build-fix.submitted", "test-plan.submitted", "test-plan.updated", "test.submitted",
	"test-fix.submitted", "review.submitted", "test-plan.challenged", "external-review.submitted", "foreign-review.submitted"];
def commits: IN("build", "build-fix", "test", "test-fix");
def chk($ok; $what): {ok: ($ok == true), what: $what};
. as $f
| ($f.events) as $ev
| def of($seq): [$ev[] | select((.body.job // null) == $seq)];
  def refused($seq): [of($seq)[] | select(.type == "job.refused")];
  def subs($seq): [of($seq)[] | select(.type | IN(submitted_types[]))];
  def ended($seq): [of($seq)[] | select(.type == "job.ended")];
  def stalled($seq): [of($seq)[] | select(.type == "job.stalled")];
  def pin_ok($s): ($s.body.report) as $r | any($f.reports[]; .path == $r.path and .sha256 == $r.sha256 and .ro);
  def commit_ok($s; $seq): ($s.body.commit // null) as $c | $c != null and any($f.git.commits[]; .sha == $c and .job == $seq);
  ($f.jobs[0].seq) as $j | $f.kind as $k
  | refused($j) as $r | subs($j) as $s | ended($j) as $e
  | (if ($r | length) == 0 and ($s | length) == 1 and ($e | length) == 0 then "accepted"
     elif ($r | length) == 1 and ($s | length) == 1 and ($e | length) == 0 and $s[0].seq > $r[0].seq then "repaired"
     elif ($r | length) == 2 and ($e | length) == 1 and $e[0].body.reason == "gave-up" then "gave-up"
     else "other: \($r | length) refused, \($s | length) submitted, \([$e[] | .body.reason] | join(",")) ended, \(stalled($j) | length) stalled" end) as $out
  | {outcome: $out},
    (if ($f.cell | test("(^|-)parked-")) then
	chk(($r | length) == 1 and any($r[0].body.lines[]; test("^write your report as one JSON object to ")) and $out == "repaired"; "parked: one refusal, write your report, then the submission (got \($out))")
     else chk($out == "accepted" or $out == "repaired"; "outcome: accepted at the first stop or repaired after one refusal (got \($out))") end),
    chk((stalled($j) | length) == 0; "no job.stalled"),
    chk(($s | length) != 1 or pin_ok($s[0]); "the pin matches the report, read-only"),
    (if ($k | commits) then chk(($s | length) != 1 or commit_ok($s[0]; $j); "the working commit, with its Job trailer") else empty end),
    chk(($f.models | length) > 0 and all($f.models[]; test("^claude-opus")); "the job agent ran on Opus: \($f.models | join(", "))"),
    chk($f.prompt_ok; "the agent got exactly the prepared prompt"),
    chk($f.stub_calls == 0; "no gh or glab call by the agent (calls: \($f.stub_calls))"),
    chk(([$r[] | .body.lines[] | select(test("characters|shorten"; "i"))] | length) == 0; "no refusal line mentions a length"),
    # A gate whose command is on the allow-list (lint: shellcheck, typecheck:
    # sh -n, test: sh tests/run.sh) that the report gives as not_run fails:
    # it could have run. A plan reports only its test baseline.
    (if ($k | IN("build", "build-fix", "test", "test-fix", "test-plan", "test-plan-update")) then
	([$ev[] | select(.type == "job.dispatched" and .seq == $j) | .body.report] | first) as $rp
	| ([$f.reports[] | select(.path == $rp) | .json] | first) as $rep
	| (if ($k | startswith("test-plan")) then ["test"] else ["lint", "typecheck", "test"] end) as $want
	| (if ($k | startswith("test-plan")) then [$rep.baseline // empty] else ($rep.gates // []) end) as $gates
	| [$gates[] | objects | select((.gate | IN($want[])) and .result == "not_run") | .gate] as $unrun
	| chk($rep != null and ($unrun | length) == 0; "the allowed gates reported run, not not_run: \(if $rep == null then "no report" elif ($unrun | length) == 0 then "all run" else "not run: " + ($unrun | join(", ")) end)")
     else empty end),
    # R3: nothing from main to the agent between a refusal and the submission.
    (if ($r | length) > 0 and ($s | length) == 1 then
	chk($f.main_sends == 0; "no message from main to the agent between the refusal and the submission (R3; main SendMessage calls: \($f.main_sends))")
     else empty end),
    chk($f.framework_same; "new-rewrite is the frozen hash at setup and at collect, and the install is its source"),
    # R1, the planted facts.
    ([$ev[] | select(.type == "job.dispatched" and .seq == $j) | .body.report] | first) as $rp2
    | ([$f.reports[] | select(.path == $rp2) | .json] | first) as $rep2
    | def files_of: (if type == "array" then .[] else . end) | strings | sub("^-"; "") | sub(":[0-9].*$"; "");
      [$f.numstat[] | .file] as $touched
    | (if $k == "review" then
	chk(any(($rep2.findings // [])[]; .at | files_of | . == "bin/prune-backups.sh"); "planted: the review of the bugged build has a finding in bin/prune-backups.sh, the file holding the bug")
       elif $k == "external-review" then
	chk(any(($rep2.items // [])[]; .verdict == "valid" and (.finding.at | files_of | . == "bin/prune-backups.sh")); "planted: the real point of the outside review (dry-run deletes, in a reply) is a valid item with a finding in bin/prune-backups.sh")
       elif $k == "foreign-review" then
	chk(any(($rep2.findings // [])[]; .at | files_of | . == "bin/restore-backup.sh"); "planted: the foreign review has a finding in bin/restore-backup.sh, the file holding the bugs")
       else empty end),
      (if $k == "build-fix" or $k == "test-fix" then
	[($rep2.fixes // [])[] | select(.status == "done" or .status == "partly") | .id] as $did
	| [$f.chosen[] | select(.id | IN($did[])) | {id, files: [(.at | files_of), (.relates_to // empty | files_of)] | unique}] as $want
	| [$want[] | select(any(.files[]; IN($touched[])) | not) | .id] as $missed
	| chk(($s | length) == 1 and ($want | length) > 0 and ($missed | length) == 0; "planted: the fix commit touches the code its done or partly findings point at (\(if ($missed | length) == 0 then "\($want | length) findings, all touched" else "not touched: " + ($missed | join(", ")) end))")
       else empty end),
      (if $k == "test" or $k == "test-fix" then
	chk(($s | length) == 1 and any($f.numstat[]; (.file | test("^tests/test_[^/]*\\.sh$")) and .added > 0) and $f.tests_run == 0; "planted: the test commit adds tests to tests/test_*.sh, and they run and pass (tests/run.sh exit \($f.tests_run))")
       else empty end)
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
: >"${work}/refusals"
for d in "${logs}"/*/; do
	d=${d%/}; cell=${d##*/}
	case ${cell} in _*) continue ;; *) ;; esac
	[ -f "${d}/cell" ] || continue
	if [ $# -gt 0 ]; then keep=''; for w in "$@"; do [ "${w}" != "${cell}" ] || keep=1; done; [ -n "${keep}" ] || continue; fi
	facts "${d}" | facts_real "${d}" >"${work}/facts.json"
	jq -c "${checks}" "${work}/facts.json" >"${work}/all" 2>"${work}/cerr" || { echo "{\"ok\": false, \"what\": \"scorer error: $(head -n 1 "${work}/cerr" | tr '"' "'")\"}" >"${work}/all"; }
	jq -c 'select(has("ok"))' "${work}/all" >"${work}/c"
	outcome=$(jq -r 'select(has("outcome")) | .outcome' "${work}/all")
	jq -c "${audit}" "${work}/facts.json" >"${work}/a" 2>"${work}/aerr" || { echo "{\"ok\": false, \"what\": \"audit error: $(head -n 1 "${work}/aerr" | tr '"' "'")\"}" >"${work}/a"; }
	cf=$(jq -s '[.[] | select(.ok | not)] | length' "${work}/c")
	af=$(jq -s '[.[] | select(.ok | not)] | length' "${work}/a")
	cells=$((cells + 1))
	result=PASS; [ "${cf}" -eq 0 ] && [ "${af}" -eq 0 ] || { result=FAIL; red=$((red + 1)); }
	echo "== ${cell}: ${result} (${outcome:-no outcome})"
	cat "${work}/c" "${work}/a" | jq -r --arg c "${cell}" '"\(if .ok then "PASS" else "FAIL" end): \($c): \(.what)"'
	pass=$((pass + $(cat "${work}/c" "${work}/a" | jq -s '[.[] | select(.ok)] | length')))
	fail=$((fail + cf + af))
	kind=$(jq -r '.kind' "${work}/facts.json")
	models=$(jq -r '.models | join(",")' "${work}/facts.json")
	printf '%s\t%s\t%s\t%s\t%s\n' "${cell}" "${kind}" "${result}" "${outcome}" "${models}" >>"${work}/table"
	jq -r --arg c "${cell}" --arg k "${kind}" '.events as $ev | ($ev[] | select(.type == "job.refused") | .body as $b
		| $b.lines[] | [$k, $c, ($b.try | tostring), .] | @tsv)' "${work}/facts.json" >>"${work}/refusals"
done
echo
echo "== table (cell, kind, result, outcome, models)"
cat "${work}/table"
echo
echo "${pass} checks PASS, ${fail} FAIL; ${cells} cells, $((cells - red)) green, ${red} red"

# The hook cost: time in the hook per job-agent call, from the saved calls'
# start and end; one agent per session, so a single agent alone.
find "${logs}/_sessions" -path "${logs}/_sessions/*/hooks/*" -name 'PreToolUse-job-agent-tools-*.json' -type f -exec jq -c 'select(.input.agent_id != null) | {k: ("job-agent-tools " + (if .input.tool_name == "Bash" then "Bash" else "Write/Edit" end)), ms: ((.t_end - .t_start) * 1000)}' {} + 2>/dev/null >"${work}/cost" || true
find "${logs}/_sessions" -path "${logs}/_sessions/*/hooks/*" -name 'PreToolUse-guard-framework-*.json' -type f -exec jq -c 'select(.input.agent_id != null and .input.tool_name == "Read") | {k: "guard-framework Read", ms: ((.t_end - .t_start) * 1000)}' {} + 2>/dev/null >>"${work}/cost" || true
echo
echo "== hook cost (ms in the hook per job-agent call: n, median, max)"
jq -rs 'group_by(.k)[] | (map(.ms) | sort) as $v | "\(.[0].k): n \($v | length), median \($v[(($v | length) / 2 | floor)] | round), max \($v[-1] | round)"' "${work}/cost"

# The text lengths per field: every string in each live job's report (the
# submitted one, or the last written), list indexes made general.
for d in "${logs}"/*/; do
	d=${d%/}; c=${d##*/}
	case ${c} in _* | earlier | trial* | i-* | headless-* | first-* | p30-* | extra-* | *parked-* | long-*) continue ;; *) ;; esac
	[ -f "${d}/cell" ] || continue
	k=$(cut -d' ' -f3 "${d}/cell")
	rp=$(jq -r --argjson j "$(cat "${d}/live-seq")" '[.[] | select(.type == "job.dispatched" and .seq == $j) | .body.report] | first' "${d}/events.json")
	[ -f "${d}/${rp}" ] || continue
	jq -r --arg k "${k}" 'paths(type == "string") as $p | [$k, ($p | map(if type == "number" then "[]" else . end) | join(".") | gsub("\\.\\[\\]"; "[]")), (getpath($p) | length | tostring)] | @tsv' "${d}/${rp}" 2>/dev/null
done >"${work}/lengths"

# counts.md: per kind, the three counts, every refusal line, and each line
# (its numbers and paths made general) that refused that kind in two runs or
# more.
{
	echo "# Step 4: counts per kind"
	echo
	echo "Written by \`score.sh\` from \`logs/\`. A run is one cell, \`<kind>-<n>\`. Parked cells are in \`parked.md\`."
	echo
	echo "| Kind | Runs | Accepted at the first stop | Repaired after one refusal | Gave up | Other |"
	echo "|---|---|---|---|---|---|"
	awk -F'\t' '$1 !~ /parked-/ && $1 !~ /^(trial|i-|headless-|first-|p30-|long-|extra-)/ { k = $2; n[k]++; o = $4
		if (o == "accepted") a[k]++; else if (o == "repaired") r[k]++; else if (o == "gave-up") g[k]++; else x[k]++
		if (!(k in seen)) { seen[k] = 1; order[++m] = k } }
		END { for (i = 1; i <= m; i++) { k = order[i]; printf "| %s | %d | %d | %d | %d | %d |\n", k, n[k], a[k] + 0, r[k] + 0, g[k] + 0, x[k] + 0 } }' "${work}/table"
	echo
	echo "## Flagged: a line that refused the same kind in 2 runs of 3 or more"
	echo
	awk -F'\t' '$2 !~ /parked-/ && $2 !~ /^(trial|i-|headless-|first-|p30-|long-|extra-)/ { l = $4; gsub(/\/Users\/Shared\/[^ ]*/, "<path>", l); gsub(/[0-9]+/, "N", l); print $1 "\t" $2 "\t" l }' "${work}/refusals" | sort -u \
		| awk -F'\t' '{ c[$1 "\t" $3]++ } END { for (k in c) if (c[k] >= 2) { split(k, p, "\t"); printf "- **%s** (%d runs): `%s`\n", p[1], c[k], p[2] } }' | sort >"${work}/flagged"
	if [ -s "${work}/flagged" ]; then cat "${work}/flagged"; else echo "None."; fi
	echo
	echo "## Text lengths per field (live reports of the counted runs)"
	echo
	echo "| Kind | Field | n | min | median | p90 | max | over 200 |"
	echo "|---|---|---|---|---|---|---|---|"
	sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3n "${work}/lengths" | awk -F'\t' '
		function flush() { if (key == "") return; split(key, kf, SUBSEP)
			printf "| %s | `%s` | %d | %d | %d | %d | %d | %d |\n", kf[1], kf[2], n, v[1], v[int((n + 1) / 2)], v[int(n * 0.9 + 0.999)], v[n], over }
		{ k = $1 SUBSEP $2; if (k != key) { flush(); key = k; n = 0; over = 0 } v[++n] = $3; if ($3 > 200) over++ }
		END { flush() }'
	echo
	echo "## Every refusal line, per kind"
	for k in $(cut -f2 "${work}/table" | awk '!s[$0]++'); do
		echo
		echo "### ${k}"
		echo
		if awk -F'\t' -v k="${k}" '$1 == k && $2 !~ /parked-/ && $2 !~ /^(trial|i-|headless-|first-|p30-|long-|extra-)/' "${work}/refusals" | grep -q .; then
			awk -F'\t' -v k="${k}" '$1 == k && $2 !~ /parked-/ && $2 !~ /^(trial|i-|headless-|first-|p30-|long-|extra-)/ { gsub(/`/, "\x27", $4); printf "- %s, try %s: `%s`\n", $2, $3, $4 }' "${work}/refusals"
		else
			echo "No refusal."
		fi
	done
} >"${EV}/counts.md"
echo "counts written to ${EV}/counts.md"
[ "${fail}" -eq 0 ]
