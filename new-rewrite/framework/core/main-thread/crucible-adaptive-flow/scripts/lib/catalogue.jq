# The step catalogue's shape, in one home: used by catalogue.sh, which every
# flow script reads the catalogue through.
# Input: [{component, file, entries}] where entries is a file's parsed JSON,
# or {component, file, invalid: true} for a file that isn't JSON.
# $rules: {"<event type>": <number of rule files for it>}; $skills: the
# installed skill names.

def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);
def a_name: type == "string" and test("^[a-z0-9]+(-[a-z0-9]+)*$");
def a_type: type == "string" and test("^[a-z][a-z-]*(\\.[a-z][a-z-]*)+$");

# Problems of one entry, one line each.
def entry_problems($rules; $skills):
	if type != "object" then "an entry must be an object"
	else
		((keys - ["name", "does", "skills", "ends_with", "stage", "propose_when"])[] | "\(.) is not an entry field"),
		(if .name | a_name then empty else "name must be lowercase letters, digits and -" end),
		(if .does | one_line then empty else "does must be one line" end),
		(if .propose_when | one_line then empty else "propose_when must be one line" end),
		(if (.skills | type) == "array" and (.skills | length) > 0 and all(.skills[]; type == "string") then
			(.skills[] | select(. as $n | $skills | index([$n]) | not) | "skills: \(.) is not an installed skill beside this component")
		 else "skills must list the skills main loads for the step, one or more" end),
		(if (.stage | type) == "array" and (.stage | length) > 0 then
			(if all(.stage[]; a_name) then empty else "each stage must be lowercase letters, digits and -" end),
			(if (.stage | unique | length) != (.stage | length) then "stage names a stage twice" else empty end)
		 else "stage must list one stage or more" end),
		(.ends_with as $dw
		 | if ($dw | type) != "object" then "ends_with must be an object"
		   else
			((($dw | keys) - ["event", "match"])[] | "ends_with.\(.) is not an ends_with field: a step ends in an event"),
			(if ($dw | has("match")) and (($dw.match | type) != "object") then "ends_with.match must be an object" else empty end),
			(if ($dw.event | a_type) | not then "ends_with.event must be an event type, such as context.cut"
			 elif $dw.event == "gate.answered" then "ends_with.event can't be gate.answered: a step ends in its own piece's event"
			 elif ($rules[$dw.event] // 0) == 0 then "ends_with.event \($dw.event) has no rule"
			 elif $rules[$dw.event] > 1 then "ends_with.event \($dw.event) has \($rules[$dw.event]) rules"
			 else empty end)
		   end)
	end;

# The catalogue: {entries: [{key, component, name, stage, does,
# propose_when, ends_with, skills}], rejected: [{key?, file, problem}]},
# entries sorted by key. $skills: the names of the components beside that
# hold a SKILL.md.
def catalogue($rules; $skills):
	[.[] | . as $f
	 | if $f.invalid then {rejected: [{file: $f.file, problem: "not JSON"}]}
	   elif ($f.entries | type) != "array" or ($f.entries | length) == 0 then
		{rejected: [{file: $f.file, problem: "must be a non-empty JSON array of entries"}]}
	   else
		([$f.entries[] | select(type == "object") | .name] | group_by(.) | map(select(length > 1) | .[0])) as $twice
		| reduce ($f.entries | to_entries[]) as $e ({entries: [], rejected: []};
			($e.value | if type == "object" and (.name | a_name) then "\($f.component)/\(.name)" else null end) as $key
			| [$e.value | entry_problems($rules; $skills)]
			  + (if $key != null and ($twice | index([$e.value.name])) then ["name \($e.value.name) is used twice in the file"] else [] end) as $p
			| if $p == [] then .entries += [$e.value + {key: $key, component: $f.component}]
			  else .rejected += [$p[] | {file: $f.file, problem: .} + (if $key then {key: $key} else {entry: $e.key} end)] end)
	   end]
	| {entries: (map(.entries // []) | add // [] | sort_by(.key)),
	   rejected: (map(.rejected) | add // [])};
