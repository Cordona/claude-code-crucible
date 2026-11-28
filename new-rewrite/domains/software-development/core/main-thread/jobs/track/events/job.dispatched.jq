# job.dispatched: a job's start, written by job-dispatch.sh. It holds what
# is true of every job: {kind, agent_type, tree, report, known_failures,
# iteration, setup}, setup {language, frameworks?, standards, model?}: one
# language, any frameworks, at least one standard. The event's seq is the
# job's key, so report is reports/<kind>/<seq>.json; the folder is for a
# human reading the effort, and no script reads the kind from the path.
#
# A build opens the next iteration on its tree; every other job takes the
# tree's current one. A fix is a job that carries the findings the human
# chose: it also carries the next round of its loop, counted per kind
# (scripts/lib/iteration.jq). A tree is known by its path, so a
# moved tree counts again from 1.
#
# A job on a tree with no build (a foreign MR's tree) has no iteration.
#
# A job may carry what its agent's own report check reads: plan, the seq of
# an earlier event; challenges, entries each with an id; words, the human's;
# lens; base and head, the commits it reads between; cover, the paths it
# covers; earlier, entries each with an id, the findings it judges again,
# and then also the fix_round its loop gives it;
# threads, the path of a fetched threads file; foreign, the MR it reads.
# Only their shapes are checked here: which job needs which of them, and
# what a job must wait for, is the dispatch's to decide.
include "jobs-track/scripts/lib/iteration";
def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);
def lines: type == "array" and all(.[]; one_line);
def finding_id: type == "string" and test("^[A-Z][A-Z0-9]*(-[A-Z0-9]+)*-[0-9]+$");
# A list of entries, each an object with its own one-line id; what else an
# entry holds is the reading agent's to check.
def entries_with_ids: type == "array" and length > 0 and all(.[]; type == "object" and (.id | one_line))
	and ([.[].id] | unique | length) == length;
def word: type == "string" and test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$");
def sha: type == "string" and test("^[0-9a-f]{40}([0-9a-f]{24})?$");
def path_in_tree: type == "string" and test("^[^/\\s]") and (test("(^|/)\\.\\.(/|$)") | not);
.event as $e | $e.body as $b | .prior as $all
| (if $e.by == "job-dispatch.sh" then empty else "job.dispatched is written only by job-dispatch.sh" end),
  ((($b | keys) - ["kind", "agent_type", "tree", "report", "findings", "sent_back", "plan", "challenges", "words",
	"lens", "base", "head", "cover", "earlier", "threads", "foreign",
	"known_failures", "iteration", "fix_round", "setup"])[] | "\(.) is not a job.dispatched field"),
  (if ($b.kind | type) == "string" and ($b.kind | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then empty
   else "kind must be lowercase words joined by dashes" end),
  (if ($b.agent_type | type) == "string" and ($b.agent_type | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$")) then empty
   else "agent_type must be the agent's name, lowercase words joined by dashes" end),
  (if ($b.tree | type) == "string" and ($b.tree | startswith("/")) then empty else "tree must be an absolute folder" end),
  (if $b.report == "reports/\($b.kind)/\($e.seq).json" then empty
   else "report must be reports/\($b.kind)/\($e.seq).json, after the job's kind and seq" end),
  (if $b.known_failures | lines then empty else "known_failures must be a list of one-line names" end),
  (if ($b.setup | type) != "object" then "setup must be {language, frameworks?, standards, model?}"
   else
	((($b.setup | keys) - ["language", "frameworks", "standards", "model"])[] | "setup.\(.) is not a setup field"),
	(if $b.setup.language | one_line then empty else "setup.language must be one language, one line" end),
	(if ($b.setup | has("frameworks") | not) or ($b.setup.frameworks | lines) then empty
	 else "setup.frameworks must be a list of one-line names, or left out" end),
	(if ($b.setup.standards | lines) and ($b.setup.standards | length) > 0 then empty
	 else "setup.standards must be a list of one-line names, at least one" end),
	(if ($b.setup | has("model")) and ($b.setup.model | one_line | not) then "setup.model must be one line" else empty end)
   end),
  (if ($b | has("plan") | not) or (($b.plan | type) == "number" and $b.plan == ($b.plan | floor) and $b.plan >= 1 and $b.plan < $e.seq)
   then empty else "plan must be the seq of an earlier event" end),
  (if ($b | has("challenges") | not) then empty
   elif $b.challenges | entries_with_ids then empty
   else "challenges must be a list of entries, each with its id, at least one, each id once" end),
  (if ($b | has("words") | not) or (($b.words | type) == "string" and ($b.words | test("\\S"))) then empty
   else "words must be the human's words, as text" end),
  (if ($b | has("lens") | not) or ($b.lens | word) then empty else "lens must be lowercase words joined by dashes" end),
  (["base", "head"][] as $k | if ($b | has($k) | not) or ($b[$k] | sha) then empty else "\($k) must be a full commit sha" end),
  (if ($b | has("cover") | not) or (($b.cover | type) == "array" and ($b.cover | length) > 0 and all($b.cover[]; path_in_tree))
   then empty else "cover must be a list of paths in the tree, at least one" end),
  (if ($b | has("earlier") | not) then empty
   elif $b.earlier | entries_with_ids then empty
   else "earlier must be a list of entries, each with its id, at least one, each id once" end),
  (if ($b | has("threads") | not) or (($b.threads | type) == "string" and ($b.threads | startswith("/"))) then empty
   else "threads must be the absolute path of the fetched threads file" end),
  (if ($b | has("foreign") | not) or ($b.foreign | one_line) then empty else "foreign must name the MR, in one line" end),
  (if $b | it_is_fix then empty
   elif $b | has("sent_back") then "sent_back belongs to a fix, a job that carries findings"
   elif ($b | has("fix_round")) and ($b | has("earlier") | not) then "fix_round belongs to a fix, or to a job that judges earlier findings"
   elif ($b | has("fix_round")) and (($b.fix_round | type) != "number" or $b.fix_round != ($b.fix_round | floor) or $b.fix_round < 1)
   then "fix_round must be a whole number from 1"
   else empty end),
  (if $b.kind == "build" and ($b | it_is_fix) then "a build opens an iteration; it carries no findings" else empty end),
  (if $b.kind == "build" then
	(($all | next_iteration($b.tree)) as $next
	 | if $b.iteration == $next then empty else "iteration must be \($next), the next on \($b.tree)" end)
   else
	(($all | current_iteration($b.tree)) as $now
	 | if $now == null and ($b | it_is_fix) then "a fix needs a build on \($b.tree) first"
	   elif $now == null then (if $b | has("iteration") then "a job on a tree with no build has no iteration" else empty end)
	   elif $b.iteration != $now then "iteration must be \($now), the build's on \($b.tree)"
	   elif $b | it_is_fix then
		(if ($b.findings | type) == "array" and ($b.findings | length) > 0 and all($b.findings[]; finding_id)
			and ($b.findings | unique | length) == ($b.findings | length)
		 then empty else "findings must be the chosen findings' ids, at least one, each once" end),
		(if ($b | has("sent_back") | not) then empty
		 elif ($b.sent_back | type) == "array" and ($b.sent_back | length) > 0 and all($b.sent_back[]; finding_id)
			and (($b.sent_back - ($b.findings // [])) | length) == 0
		 then empty else "sent_back must list chosen findings the human sent back, at least one" end),
		(($all | next_fix_round($b.tree; $now; $b.kind; ($b | has("sent_back")))) as $round
		 | if $b.fix_round == $round then empty else "fix_round must be \($round), the next in its loop" end)
	   else empty end)
   end)
