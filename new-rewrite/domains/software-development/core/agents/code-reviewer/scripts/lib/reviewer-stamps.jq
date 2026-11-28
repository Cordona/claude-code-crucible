# The reviewer's stamps, filled in before the pin, a jq module: load it with
# jq -L <the skills folder> and include "code-reviewer/scripts/lib/reviewer-stamps".
# Input {report, job, facts}; each def prints the stamped report. Run by
# agent-submission's stamp step under the stop hook's lock, so facts.ids
# and facts.keys are every ID taken so far. A stamp it can't know stops with
# an error, never a guess: the human is told, and nothing is handed in.
# Stamping a stamped report changes nothing: an entry keeps the id it has,
# and a source already set is set to the same value.

def rs_two: tostring | if length < 2 then "0" + . else . end;

# The IDs <LENS>-NN for $n findings, after the highest of the lens's IDs
# among $used.
def rs_ids($lens; $used; $n):
	($lens | ascii_upcase) as $prefix
	| ([$used[] | strings | select(startswith($prefix + "-")) | ltrimstr($prefix + "-") | tonumber? // empty] | max // 0) as $top
	| [range(0; $n) | "\($prefix)-\(($top + . + 1) | rs_two)"];

def rs_lens:
	if (.job.lens | type) == "string" and (.job.lens | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then .job.lens
	else error("job \(.job.job) names no lens, so its findings can't be given IDs; the dispatch must name one") end;

def rs_findings($used):
	(if (.report.findings | type) == "array" and (.report.findings | length) > 0 then rs_lens else "" end) as $lens
	| .report
	| if (.findings | type) == "array" then
		rs_ids($lens; $used; .findings | length) as $ids
		| .findings |= [to_entries[] | {id: $ids[.key]} + .value]
	  else . end;

# A review's findings: unique in the iteration, numbered after its IDs so far.
def stamp_review: rs_findings(.facts.ids // []);

# A foreign review's findings: numbered per job, from 01.
def stamp_foreign: rs_findings([]);

# Each challenge's C-n, numbered across the effort.
def stamp_challenge:
	([(.facts.keys // [])[] | strings | ltrimstr("C-") | tonumber? // empty] | max // 0) as $top
	| .report
	| if (.challenges | type) == "array" then .challenges |= [to_entries[] | {id: "C-\($top + .key + 1)"} + .value] else . end;

# Each item's source from the fetched threads, over any the agent wrote; each valid finding's ID, from
# the job's lens and the iteration's IDs so far.
def stamp_external:
	(.facts.threads // []) as $threads
	| ([.report.items // [] | .[] | select(.verdict == "valid" and (.finding | type) == "object")] | length) as $valid
	| (if $valid > 0 then rs_lens else "" end) as $lens
	| rs_ids($lens; .facts.ids // []; $valid) as $ids
	| .report
	| if (.items | type) == "array" then
		.items |= (reduce to_entries[] as $e ({items: [], n: 0};
			($e.value | .thread) as $t
			| ([$threads[] | select(.id == $t) | .source] | first) as $source
			| if $source == "human" or $source == "bot" then .
			  else error("thread \($t) has no source, human or bot, in the job's threads file") end
			| ($e.value | del(.source) | to_entries | map(if .key == "verdict" then [{key: "source", value: $source}, .] else [.] end) | add | from_entries) as $item
			| if $item.verdict == "valid" and ($item.finding | type) == "object"
			  then .n as $n | .items += [$item | .finding = ({id: $ids[$n]} + .finding)] | .n += 1
			  else .items += [$item] end) | .items)
	  else . end;
