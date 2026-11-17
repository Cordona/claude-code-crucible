# The agent dispatch's shape, the body of a dispatch.made event: the one
# definition generate-agent-dispatch.sh and the Agent hook check a dispatch
# with. Input: the dispatch slurped (jq -s), so an empty file or several
# values show as a count.
# Output: one "<where> <problem>; expected <x>" line per problem, nothing when
# the dispatch fits. With --arg format json: one {"at": <the field's path, []
# for the dispatch itself>, "problem": "<problem>; expected <x>"} per problem.
# A dispatch written before a change to this contract is refused
# (generate-agent-dispatch.sh's re-check, the hook); regenerate it at
# the flow's step 8.
# The shape, keys in this order; a key whose value would be null, [] or {} is
# left out, so entry_points and plugins, and each plugins kind, may be absent:
#   {"id", "agent", "seat", "task",
#    "entry_points": [repo-relative path, ...],
#    "context": {"seq", "path"}, "plan": {"seq"},
#    "plugins": {"language": {"name": "language-<n>", "paths": [...]},
#                "frameworks": [{"name": "framework-<n>", "paths": [...]}, ...],
#                "standards": [{"name": "standard-<n>", ...}, ...],
#                "procedures": [{"name": "procedure-<n>", ...}, ...]},
#    "reseat_of", "continue_from", "notes": [str, ...], "test_plan"}
# context is the context.cut event the dispatch pins, plan the plan.made
# event it was approved as, each by its seq. A re-seat holds reseat_of, the
# seq of the dispatch.made it repeats, and continue_from, the worktree's HEAD
# commit; notes are its lines for the agent (left out when none); test_plan,
# only on a code-tester re-seat that writes tests, is the seq of the
# test-plan.made it writes them from.
# seat names a seat of the effort; the seat holds the mode and the worktree.
# The plugin rules: frameworks need a language; a name starts with its kind's
# prefix and is listed once; a code-reviewer dispatch holds one lens: the
# language with its frameworks and no standard, or one standard and no
# language, or neither.

include "dispatch-names" {search: "./"};

# The agents are dispatch-names.jq's dispatched_agents.
def lens_agent: "code-reviewer";
def test_plan_agent: "code-tester";
def top_keys: ["id", "agent", "seat", "task", "entry_points", "context", "plan", "plugins", "reseat_of", "continue_from", "notes", "test_plan"];
# The keys left out when they hold nothing; every other key is required.
def optional_keys: ["entry_points", "plugins", "reseat_of", "continue_from", "notes", "test_plan"];
def plugin_kinds: ["language", "frameworks", "standards", "procedures"];
# The name prefix of each plugins kind.
def kind_prefixes: {language: "language-", frameworks: "framework-", standards: "standard-", procedures: "procedure-"};
def plugin_shape: "{\"name\": str, \"paths\": [absolute path, ...]}";

def text_ok: type == "string" and (gsub("[[:cntrl:][:space:]]"; "") | length > 0);
def has_control: test("[[:cntrl:]]");
def absolute_path: type == "string" and startswith("/") and (has_control | not);
def seq_number: type == "number" and . >= 1 and floor == .;
def commit_hex: type == "string" and test("\\A[0-9a-f]{40}\\z");
# A repo-relative path: not empty, not absolute, no .. segment, no control character.
def relative_path: type == "string" and length > 0 and (startswith("/") | not) and (has_control | not)
	and (split("/") | index([".."]) == null);
def quoted_name: tojson | if length > 60 then .[:60] + "…" else . end;
def location: reduce .[] as $step ("";
	if ($step | type) == "number" then . + "[\($step)]"
	elif ($step | test("^[a-z_][a-z0-9_]*$")) then . + (if . == "" then "" else "." end) + $step
	else . + (if . == "" then "" else "." end) + ($step | quoted_name) end);
def problem($at; $separator; $problem):
	{at: $at, problem: $problem, line: "\(if $at == [] then "the dispatch" else $at | location end)\($separator)\($problem)"};

def is_empty: . == null or . == [] or . == {};
def empty_problem($at): problem($at; " "; "is empty; expected the key left out when it holds nothing");
def required_keys: top_keys - optional_keys;

def keys_problems:
	((keys - top_keys)[] | problem([.]; ": "; "unknown field; expected only \(top_keys | join(", "))")),
	(required_keys[] as $key | select(has($key) | not) | problem([$key]; " "; "missing; expected every one of \(required_keys | join(", "))"));

def field_problems:
	(if (.id | type) == "string" and (.id | test(crucible_id_pattern)) then empty
	 else problem(["id"]; " "; "is not a Crucible ID; expected <YYYYMMDDTHHMMSS>-<4 lowercase hex>") end),
	(if .agent | IN(dispatched_agents[]) then empty
	 else problem(["agent"]; " "; "\(.agent | tojson) is not dispatched through a dispatch file; expected one of \(dispatched_agents | map(tojson) | join(", "))") end),
	(if (.seat | type) == "string" and (.seat | test(seat_pattern)) then empty
	 else problem(["seat"]; " "; "is not a seat name; expected lowercase words joined by dashes, then one of alpha, beta ... omega and, from the second round, -2, -3 ..., like build-agent-alpha") end),
	(if .task | text_ok then empty else problem(["task"]; " "; "is not a non-empty string; expected the task text") end);

# The plan a dispatch came from: its plan.made event, by seq.
def plan_problems:
	if (.plan | type) != "object" then problem(["plan"]; " "; "is not an object; expected {\"seq\": a whole number from 1}")
	else .plan
		| ((keys - ["seq"])[] | problem(["plan", .]; ": "; "unknown field; expected only seq")),
		  (if .seq | seq_number then empty else problem(["plan", "seq"]; " "; "is not a whole number from 1; expected the seq of the plan.made event") end)
	end;

# The context version a dispatch pins: its context.cut event, by seq and path.
def context_problems:
	if (.context | type) != "object" then problem(["context"]; " "; "is not an object; expected {\"seq\": a whole number from 1, \"path\": absolute path}")
	else .context
		| ((keys - ["seq", "path"])[] | problem(["context", .]; ": "; "unknown field; expected only seq and path")),
		  (if .seq | seq_number then empty else problem(["context", "seq"]; " "; "is not a whole number from 1; expected the seq of the context.cut event") end),
		  (if .path | absolute_path then empty else problem(["context", "path"]; " "; "is not an absolute path; expected the context.cut event's path") end)
	end;

# A re-seat holds reseat_of and continue_from together; notes and test_plan
# only with them, test_plan only for test_plan_agent.
def reseat_problems:
	if has("reseat_of") or has("continue_from") or has("notes") or has("test_plan") then
		(if .reseat_of | seq_number then empty
		 else problem(["reseat_of"]; " "; "is missing or not a whole number from 1; expected the seq of the dispatch.made a re-seat repeats") end),
		(if .continue_from | commit_hex then empty
		 else problem(["continue_from"]; " "; "is missing or not 40 lowercase hex digits; expected the worktree's HEAD commit") end),
		(if has("notes") | not then empty
		 elif .notes | is_empty then empty_problem(["notes"])
		 elif (.notes | type) != "array" then problem(["notes"]; " "; "is not an array; expected [line, ...]")
		 else .notes | to_entries[] | select(.value | text_ok | not)
			| problem(["notes", .key]; " "; "is not a non-empty string; expected a line for the agent") end),
		(if has("test_plan") | not then empty
		 elif .test_plan | is_empty then empty_problem(["test_plan"])
		 elif .test_plan | seq_number | not then
			problem(["test_plan"]; " "; "is not a whole number from 1; expected the seq of the approved test-plan.made")
		 elif .agent != test_plan_agent then
			problem(["test_plan"]; " "; "is on a \(.agent | tostring) dispatch; expected it only on a \(test_plan_agent) re-seat")
		 else empty end)
	else empty end;

# The problems of plugin entry . at path $at, a $kind entry.
def plugin_problems($at; $kind):
	if type != "object" then problem($at; " "; "is a JSON \(type); expected \(plugin_shape)")
	else ((keys - ["name", "paths"])[] | problem($at + [.]; ": "; "unknown field; expected only name and paths")),
		(if .name | text_ok | not then problem($at + ["name"]; " "; "is not a non-empty string; expected a plugin name")
		 elif (.name | startswith(kind_prefixes[$kind])) and (.name | length) > (kind_prefixes[$kind] | length) then empty
		 else problem($at + ["name"]; " "; "\(.name | quoted_name) is not a \(kind_prefixes[$kind])* name; expected only \(kind_prefixes[$kind])<name> plugins under plugins.\($kind)") end),
		(if (.paths | type) == "array" and (.paths | length) > 0 then
			(.paths | to_entries[] | select(.value | absolute_path | not)
				| problem($at + ["paths", .key]; " "; "is not an absolute path; expected a plugin file's path"))
		 else problem($at + ["paths"]; " "; "is not a non-empty array; expected the plugin's files") end)
	end;

# Every plugin entry as {at, kind, entry}, in the dispatch's order.
def plugin_entries:
	.plugins | objects | to_entries[] | select(.key | IN(plugin_kinds[])) | .key as $kind
	| if $kind == "language" then .value | objects | {at: ["plugins", "language"], kind: $kind, entry: .}
	  elif (.value | type) == "array" then .value | to_entries[] | {at: ["plugins", $kind, .key], kind: $kind, entry: .value}
	  else empty end;

def kind_problems:
	.plugins | to_entries[] | .key as $kind | .value
	| if ($kind | IN(plugin_kinds[]) | not) then problem(["plugins", $kind]; ": "; "unknown field; expected only \(plugin_kinds | join(", "))")
	  elif is_empty then empty_problem(["plugins", $kind])
	  elif $kind == "language" then (if type == "object" then empty
		else problem(["plugins", "language"]; " "; "is a JSON \(type); expected one \(plugin_shape): a dispatch loads at most one language") end)
	  elif type != "array" then problem(["plugins", $kind]; " "; "is a JSON \(type); expected [\(plugin_shape), ...]")
	  else empty end;

def repeat_problems:
	[plugin_entries | .entry | objects | .name | strings] | group_by(.)[] | select(length > 1)
	| problem(["plugins"]; " "; "names \(.[0] | tojson) more than once; expected each plugin once");

def framework_problems:
	if .plugins | has("frameworks") and (has("language") | not) then
		problem(["plugins", "frameworks"]; " "; "without a language; expected the language the code is in, in plugins.language")
	else empty end;

def lens_problems:
	if .agent != lens_agent then empty
	elif .plugins | has("language") and has("standards") then
		problem(["plugins", "standards"]; " "; "with a language; expected one lens per \(lens_agent) dispatch: the language with its frameworks, or one standard")
	elif (.plugins.standards | type) == "array" and (.plugins.standards | length) > 1 then
		problem(["plugins", "standards"]; " "; "holds \(.plugins.standards | length) standards; expected one lens per \(lens_agent) dispatch: one standard")
	else empty end;

def plugins_problems:
	if has("plugins") | not then empty
	elif .plugins | is_empty then empty_problem(["plugins"])
	elif (.plugins | type) != "object" then problem(["plugins"]; " "; "is a JSON \(.plugins | type); expected {\"language\": \(plugin_shape), \"frameworks\": [...], \"standards\": [...], \"procedures\": [...]}")
	else kind_problems,
		(plugin_entries | .entry as $entry | .kind as $kind | .at as $at | $entry | plugin_problems($at; $kind)),
		repeat_problems, framework_problems, lens_problems
	end;

def entry_points_problems:
	if has("entry_points") | not then empty
	elif .entry_points | is_empty then empty_problem(["entry_points"])
	elif (.entry_points | type) != "array" then problem(["entry_points"]; " "; "is not an array; expected [repo-relative path, ...], left out when none")
	else .entry_points | to_entries[] | select(.value | relative_path | not)
		| problem(["entry_points", .key]; " "; "is not a repo-relative path; expected a path inside the repository without a leading /, a .. segment or a control character")
	end;

# Every path the agent's message prints in a code span: a backtick would end
# the span, so a path holding one is refused rather than printed altered.
def is_printed_path: . == ["context", "path"] or . == ["continue_from"]
	or .[0] == "entry_points" or (.[0] == "plugins" and index(["paths"]) != null);
def backtick_problems:
	paths(type == "string") as $at | select($at | is_printed_path) | select(getpath($at) | contains("`"))
	| problem($at; " "; "holds a backtick; expected a path without one, so the agent's message prints it unchanged");

(if length != 1 then problem([]; " "; "is \(length) JSON values; expected exactly one object")
 elif (.[0] | type) != "object" then problem([]; " "; "is a JSON \(.[0] | type); expected an object")
 else .[0] | keys_problems, field_problems, plan_problems,
	context_problems, plugins_problems,
	entry_points_problems, reseat_problems, backtick_problems
 end)
| if $ARGS.named.format == "json" then {at, problem} else .line end
