# Main's proposed jobs made full, a jq module: load it with jq -L <the skills
# folder> and include "jobs-define/scripts/lib/job-resolve". Input: main's
# {jobs: [...]}; $kinds each kind's file by name; $all the effort's events.
# Output: {faults, jobs}: one line per fault, or the full jobs.
#
# A kind file's words, each read here, each a fact resolve must check:
#   agent, part        the agent that does the kind, and its plugins' part
#   input_refs.NAME    a ref: event (a type or list), and at most these:
#     required         the job can't go without it
#     list             every such event, not the latest one
#     named            main must name it; never filled from the log
#     via REF          the event REF's event names under NAME; never main's
#     same KEY         the latest such event whose own job named this job's
#                      KEY ref; never main's; none at the first
#   tree               the forms its tree may take: cut, use
#   range              tree (its tree's base..head, read by the script) or
#                      change (the change ref's base..head)
#   write_scope        tree or report: what its agent may write
#   known_failures     main may give the checks already failing
#   one_standard       one standard, the lens
#   one_of             at least one of these refs
include "jobs-define/scripts/lib/job-frame";

def jr_types($d): $d.event | if type == "array" then . else [.] end;
def jr_of_types($all; $types): [$all[] | select(.type as $t | $types | index([$t]) != null) | .seq];

# One job's input_refs: those main named, checked against the kind's
# declared refs; the rest filled from the log (the latest event, or every
# one for a list), except a ref main must name; a ref with via is the one
# its via ref's event names under the same key, never main's. Emits
# {fault} or {refs}.
def jr_refs($n; $kind; $decl; $all):
	(.input_refs // {}) as $given
	| [($given | keys - ($decl | keys))[] | {fault: "job \($n): a \($kind) takes no \(.) ref; it takes \($decl | keys | join(", "))"}]
	+ [$decl | to_entries[] | .key as $k | .value as $d | jr_types($d) as $types | jr_of_types($all; $types) as $seqs
	   | ($types | join(" or ")) as $what
	   | if $d.same then
		(if $given | has($k) then {fault: "job \($n): \($k) is the last one of the same \($d.same); give no \($k) ref"} else empty end)
	     elif $d.via then
		(if $given | has($k) then {fault: "job \($n): \($k) comes from its \($d.via); give no \($k) ref"}
		 else ($given[$d.via] // null) as $src
			| (first($all[] | select(.seq == $src)) // null).body[$k] as $v
			| if $src == null then empty
			  elif ($v | type) == "number" and ($seqs | index([$v]) != null) then {refs: {($k): $v}}
			  else {fault: "job \($n): its \($d.via) names no \($what)"} end end)
	     elif $given | has($k) then
		($given[$k] | if $d.list then (if type == "array" then . else [.] end) else . end) as $v
		| if ($d.list | not) and ($v | type) == "array" then {fault: "job \($n): \($k) is one \($what), not a list"}
		  elif ([if ($v | type) == "array" then $v[] else $v end] | length > 0
			and all(.[]; . as $s | $seqs | index([$s]) != null)) then {refs: {($k): $v}}
		  else {fault: "job \($n): \($k) must be the seq of a \($what)\(if $d.list then ", or a list of them" else "" end)"} end
	     elif $d.named then
		(if $d.required then {fault: "job \($n): a \($kind) needs \($k): name the seq of its \($what)"} else empty end)
	     elif ($seqs | length) == 0 then
		(if $d.required then {fault: "job \($n): a \($kind) needs \($k): there is no \($what) yet"} else empty end)
	     elif $d.list then {refs: {($k): $seqs}}
	     else {refs: {($k): ($seqs | last)}} end];

# The refs with same: the latest event of the ref's type whose own job named
# the same value under that key as this job does, as an earlier judgement of
# the same change; none at the first. Emits {refs} or nothing.
def jr_same($decl; $refs; $all):
	($refs | map(.refs // empty) | add // {}) as $mine
	| $decl | to_entries[] | select(.value.same) | .key as $k | .value as $d
	| ($d.event | if type == "array" then . else [.] end) as $types
	| $mine[$d.same] as $v
	| select($v != null)
	| [$all[] | select(.type as $t | $types | index([$t]) != null) | . as $s
	   | select(first($all[] | select(.seq == $s.body.job and .type == "job.defined")).body.input_refs[$d.same] == $v) | .seq]
	| last | select(. != null) | {refs: {($k): .}};

# A kind whose range is its change's: the range is the change's base..head,
# from the remote-change.fetched the change ref names. On a kind that only
# cuts, main gives no work: the tree is cut from the change's head in its
# repository, so the tree and the range are the same commits. On a kind
# that uses a tree, main names the tree and the range is added. Emits
# {job: {work}} or {fault}, or {} for any other kind.
def jr_from_change($n; $k; $refs; $all):
	if $k.range != "change" then {}
	else ([$refs[] | .refs.change // empty] | first) as $c
		| (first($all[] | select(.seq == $c and .type == "remote-change.fetched")) // null) as $e
		| {base: $e.body.base, head: $e.body.head} as $range
		| if $k.tree == ["cut"] then
			(if has("work") then {fault: "job \($n): a \(.kind) takes no work: its tree and range come from its change"}
			 elif $e == null then {}
			 else {job: {work: {tree: {cut: {repo: $e.body.repo, from: "ref:\($e.body.head)"}}, range: $range}}} end)
		  elif $e == null or (.work.tree | type) != "object" then {}
		  else {job: {work: (.work + {range: $range})}} end
	end;

def jr_resolve($kinds; $all):
	(.jobs // null) as $jobs
	| if ($jobs | type) != "array" or ($jobs | length) == 0 then {faults: ["the file must be {jobs: [...]}, at least one job"], jobs: []}
	  else
		[$jobs | to_entries[] | (.key + 1) as $n | .value as $j
		 | if ($j | type) != "object" then {faults: ["job \($n) must be an object"]}
		   elif ($kinds | has($j.kind // "") | not) then
			{faults: ["job \($n): kind \($j.kind | tojson) is not a kind; kinds: \($kinds | keys | join(", "))"]}
		   else $kinds[$j.kind] as $k
			| ($j | jr_refs($n; $j.kind; $k.input_refs; $all)) as $refs0
			| ($refs0 + [jr_same($k.input_refs; $refs0; $all)]) as $refs
			| ($j | jr_from_change($n; $k; $refs; $all)) as $fill
			| ($j + ($fill.job // {})) as $j
			| ($j.work.tree // {} | keys | first // "") as $form
			| ((($j.work // {}) | keys) - ["tree"] - (if $k.known_failures then ["known_failures"] else [] end)
				- (if $k.range == "change" then ["range"] else [] end)) as $extra
			| {faults: (
				[($j | keys - ["kind", "plugins", "input_refs", "work"])[] | "job \($n): \(.) is not a job field"]
				+ [$j.plugins | jf_plugins_problems | "job \($n): \(.)"]
				+ (if $k.one_standard and (($j.plugins.standards // []) | length) > 1
				   then ["job \($n): a \($j.kind) reads through one standard, its lens: give one, a job per lens"] else [] end)
				+ [$extra[] | "job \($n): work.\(.) is not main's to give for a \($j.kind); resolve fills the rest"]
				+ (if ($j.work | has("known_failures") | not) or ($j.work.known_failures | jf_lines) then []
				   else ["job \($n): work.known_failures must be a list of one-line check names"] end)
				+ (if $j.work.tree == null then ["job \($n): work.tree missing: a \($j.kind)'s tree is \($k.tree | map("{\(.)}") | join(" or "))"]
				   elif ($k.tree | index([$form])) == null then ["job \($n): a \($j.kind)'s tree is \($k.tree | map("{\(.)}") | join(" or ")), not {\($form)}"]
				   else [$j.work.tree | jf_tree_problems($all) | "job \($n): \(.)"] end)
				+ [$refs[] | .fault // empty]
				+ [$fill.fault // empty]
				+ (if $k.one_of and ([$k.one_of[] as $r | $j.input_refs // {} | has($r)] | any | not)
				   then ["job \($n): a \($j.kind) needs \($k.one_of | join(" or ")): name one"] else [] end)),
			   job: {kind: $j.kind, plugins: $j.plugins, input_refs: ([$refs[] | .refs // empty] | add // {}),
				work: ({tree: $j.work.tree, loop: {iteration: ($j | jf_iteration($all))}}
					+ (if $j.work.range then {range: $j.work.range} else {} end)
					+ (if $k.known_failures then {known_failures: ($j.work.known_failures // [])} else {} end))}}
		   end] as $each
		| ([$jobs | to_entries[] | select(.value.work.tree.use != null and ($kinds[.value.kind].write_scope // "") == "tree")
		    | {n: (.key + 1), t: .value.work.tree.use}] | group_by(.t) | map(select(length > 1))
		   | map("jobs \(map(.n | tostring) | join(" and ")) write in tree \(.[0].t): one writing job per tree")) as $twice
		| {faults: ([$each[].faults[]] + $twice), jobs: [$each[] | .job // empty]}
	  end;
