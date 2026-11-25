# The reviewer's own shared ground for its reports: the keys, the text
# rules, the findings and the tree check (the plumbing checks every at;
# relates_to and the cover are the reviewer's own); a jq module: load
# it with jq -L <the skills folder> and include
# "code-reviewer/scripts/lib/reviewer-common". This agent's report rules
# build on it; no other agent includes it. Input {report, job, tree, facts},
# as agent-submission's report-check.sh gives it: tree {changed, lines},
# lines each at's file mapped to its line count, -1 when it names no file
# (a file read at the job's base keyed -<path>); facts from
# reviewer-facts.sh. Each problem is the one line the reviewer repairs it by.

# Filled in by a script, never by the reviewer.
def rc_stamped: ["id", "kind", "lens", "source", "job", "agent", "iteration", "fix_round", "effort", "report", "sha256", "seq", "commit"];
def rc_severities: ["critical", "high", "medium", "low"];
def rc_realisms: ["realistic", "edge-case", "hypothetical"];

def rc_or($words): if ($words | length) < 2 then $words[0] else ($words[:-1] | join(", ")) + " or " + $words[-1] end;

# The problem of one-line text at $where, or nothing.
def rc_text($where):
	if type != "string" then "\($where) must be text"
	elif test("^\\s*$") then "\($where) is blank; write it, or drop the entry"
	elif test("[\\r\\n]") then "\($where) is more than one line; write it on one"
	else empty end;

# The problem of long text at $where: several lines allowed.
def rc_long($where):
	if type != "string" then "\($where) must be text"
	elif test("^\\s*$") then "\($where) is blank; write it, or drop the entry"
	else empty end;

# The entries of the list at $path in the report, each {i, v, w}.
def rc_entries_at($path; $name):
	getpath($path) | if type == "array" then to_entries[] | {i: .key, v: .value, w: "\($name)[\(.key)]"} else empty end;
def rc_entries($name): rc_entries_at(["report", $name]; $name);

# The shape of one object $v named $w: only $fields, each of $required
# there, $texts one line of text, $longs long text.
def rc_object($v; $w; $fields; $required; $texts; $longs):
	if ($v | type) != "object" then "\($w) must be an object"
	else
		((($v | keys_unsorted) - $fields)[] | "\($w) has unknown key \"\(.)\"; its keys are \($fields | join(", "))"),
		(($required - ($v | keys))[] | if . == "at" then "\($w) needs at: the file and line" else "\($w) needs \(.)" end),
		($texts[] as $k | $v | select(has($k)) | .[$k] | rc_text("\($w).\($k)")),
		($longs[] as $k | $v | select(has($k)) | .[$k] | rc_long("\($w).\($k)"))
	end;

def rc_list($name; $fields; $required; $texts; $longs):
	(.report[$name] | if . == null or type == "array" then empty else "\($name) must be a list" end),
	(rc_entries($name) | .w as $w | rc_object(.v; $w; $fields; $required; $texts; $longs));

def rc_top($keys):
	(.report | keys_unsorted[]) as $k
	| if rc_stamped | index([$k]) then "remove \"\($k)\": this is filled in for you"
	  elif $keys | index([$k]) | not then "unknown key \"\($k)\"; the keys are \($keys | join(", "))"
	  else empty end;

# One location: {key, file, line, last}: key is how the plumbing looked the
# file up (-<path> at the base); null for @<where>:..., another repo's.
def rc_location:
	if type != "string" then {bad: true}
	elif startswith("@") then null
	else (capture("^(?<neg>-?)(?<file>[^:@\\s][^:]*)(:(?<a>[1-9][0-9]*)(-(?<b>[1-9][0-9]*))?)?$") // {bad: true})
		| if .bad then . else {key: (.neg + .file), file, neg: (.neg == "-"),
			line: ((.b // .a // "0") | tonumber), first: ((.a // "0") | tonumber)} end
	end;

def rc_ats_of: if type == "array" then .[] else . end;

# The rules of one finding $f named $w. Its id is stamped, never written.
def rc_finding($w; $f):
	.facts as $facts
	| (if ($f | type) == "object" and ($f | has("id")) then "remove \"id\": this is filled in for you" else empty end),
	  rc_object($f | if type == "object" then del(.id) else . end; $w; ["severity", "realism", "at", "claim", "suggestion", "relates_to", "proof", "real_if", "out_of_scope", "reopens"];
		["severity", "realism", "claim", "suggestion"]; ["claim", "relates_to", "real_if", "out_of_scope", "reopens"]; ["suggestion", "proof"]),
	(if ($f | type) != "object" then empty
	 else
		(if $f | has("severity") and ($f.severity | IN(rc_severities[]) | not)
		 then "\($w).severity \($f.severity | tojson) is not \(rc_or(rc_severities))" else empty end),
		(if $f | has("realism") and ($f.realism | IN(rc_realisms[]) | not)
		 then "\($w).realism \($f.realism | tojson) is not \(rc_or(rc_realisms))" else empty end),
		(if $f.realism == "edge-case" and ($f | has("proof") | not) then "\($w) is an edge-case: add proof, the line that makes it reachable" else empty end),
		(if $f.realism == "hypothetical" and ($f | has("real_if") | not) then "\($w) is hypothetical: add real_if, what would make it real" else empty end),
		(if ($facts.cover | type) == "array" and ($f | has("at")) and ($f | has("relates_to") | not) and ($f | has("out_of_scope") | not)
		 then $f.at | rc_ats_of | . as $one | rc_location
			| select(. != null and (.bad | not) and (.file | IN($facts.cover[]) | not))
			| "\($w).at \($one) is outside this change: add relates_to, the changed line it relates to, or out_of_scope with its proof"
		 else empty end),
		(if ($f | has("relates_to")) and ($facts.added | type) == "object"
		 then $f.relates_to | . as $one | rc_location
			| if . == null then empty
			  elif .bad or .first == 0 then "\($w).relates_to \($one | tostring) is not a line this change touches"
			  else . as $loc | ((if $loc.neg then $facts.removed else $facts.added end)[$loc.file] // []) as $touched
				| if [range($loc.first; $loc.line + 1)] | any(.[]; IN($touched[])) then empty
				  else "\($w).relates_to \($one) is not a line this change touches" end
			  end
		 else empty end)
	 end);

def rc_findings:
	(.report.findings | if . == null or type == "array" then empty else "findings must be a list" end),
	(. as $in | rc_entries("findings") | .w as $w | .v as $f | $in | rc_finding($w; $f));

def rc_noticed:
	rc_list("noticed"; ["at", "kind", "text", "for"]; ["text"]; ["text"]; []),
	(rc_entries("noticed") | select((.v | type) == "object") | .w as $w | .v
	 | (if has("kind") and (.kind | IN("secret", "instruction") | not) then "\($w).kind \(.kind | tojson) is not secret or instruction" else empty end),
	   (if has("for") and ((.for | type) != "string" or (.for | test("^[a-z][a-z0-9]*(-[a-z0-9]+)*$") | not))
	    then "\($w).for \(.for | tojson) must name a lens, lowercase words joined by dashes" else empty end));

def rc_notes: rc_list("notes"; ["text", "at"]; ["text"]; ["text"]; []);

# A reviewer changes nothing in the tree; the project's ignore rules apply.
def rc_tree:
	if .tree.changed then "you changed files: undo your changes; a reviewer changes nothing" else empty end;
