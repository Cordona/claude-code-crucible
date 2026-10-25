# The agent dispatch file's shape, the one definition generate-agent-dispatch.sh
# checks a dispatch with. Input: the dispatch slurped (jq -s), so an empty file
# or several values show as a count.
# Output: one "<where> <problem>; expected <x>" line per problem, nothing when
# the dispatch fits. With --arg format json: one {"at": <the field's path, []
# for the dispatch itself>, "problem": "<problem>; expected <x>"} per problem.
# A dispatch written before a change to this contract is refused
# (generate-agent-dispatch.sh's re-check, the hook); regenerate it at
# the flow's step 8.
# The shape, keys in this order; a key whose value would be null, [] or {} is
# left out, so entry_points and plugins, and each plugins kind, may be absent:
#   {"id", "started", "agent", "mode", "task", "repo_root",
#    "entry_points": [repo-relative path, ...],
#    "plugins": {"language": {"name": "language-<n>", "paths": [...]},
#                "frameworks": [{"name": "framework-<n>", "paths": [...]}, ...],
#                "standards": [{"name": "standard-<n>", ...}, ...],
#                "procedures": [{"name": "procedure-<n>", ...}, ...]},
#    "context": {"path", "sha256"}, "plan": {"sha256"}, "report", "baseline"}
# The plugin rules: frameworks need a language; a name starts with its kind's
# prefix and is listed once; a code-reviewer dispatch holds one lens: the
# language with its frameworks and no standard, or one standard and no
# language, or neither.

include "dispatch-names" {search: "./"};

# The agents are dispatch-names.jq's dispatched_agents, each with a report
# kind; mode TEST is not dispatched through this file yet.
def dispatched_modes: ["BUILD"];
def lens_agent: "code-reviewer";
def top_keys: ["id", "started", "agent", "mode", "task", "repo_root", "entry_points", "plugins", "context", "plan", "report", "baseline"];
# The keys left out when they hold nothing; every other key is required.
def optional_keys: ["entry_points", "plugins"];
def plugin_kinds: ["language", "frameworks", "standards", "procedures"];
# The name prefix of each plugins kind.
def kind_prefixes: {language: "language-", frameworks: "framework-", standards: "standard-", procedures: "procedure-"};
def plugin_shape: "{\"name\": str, \"paths\": [absolute path, ...]}";

def text_ok: type == "string" and (gsub("[[:cntrl:][:space:]]"; "") | length > 0);
def has_control: test("[[:cntrl:]]");
def absolute_path: type == "string" and startswith("/") and (has_control | not);
def sha256_hex: type == "string" and test(sha256_pattern);
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
	(if (.started | type) == "string" and (.started | test(local_time_pattern)) then empty
	 else problem(["started"]; " "; "is not an ISO 8601 local time with offset; expected YYYY-MM-DDTHH:MM:SS+HH:MM") end),
	(if .agent | IN(dispatched_agents[]) then empty
	 else problem(["agent"]; " "; "\(.agent | tojson) is not dispatched through a dispatch file; expected one of \(dispatched_agents | map(tojson) | join(", "))") end),
	(if .mode | IN(dispatched_modes[]) then empty
	 else problem(["mode"]; " "; "\(.mode | tojson) is not dispatched through a dispatch file; expected \"BUILD\" (TEST dispatches are held in the flow)") end),
	(if .task | text_ok then empty else problem(["task"]; " "; "is not a non-empty string; expected the task text") end),
	(if .repo_root | absolute_path then empty else problem(["repo_root"]; " "; "is not an absolute path; expected the repository's git work-tree root") end);

# The plan a dispatch came from, by its digest alone: its gate record expires,
# so the dispatch keeps no path to it.
def plan_problems:
	if (.plan | type) != "object" then problem(["plan"]; " "; "is not an object; expected {\"sha256\": 64 lowercase hex}")
	else .plan
		| ((keys - ["sha256"])[] | problem(["plan", .]; ": "; "unknown field; expected only sha256")),
		  (if .sha256 | sha256_hex then empty else problem(["plan", "sha256"]; " "; "is not 64 lowercase hex digits; expected the plan's PLAN_SHA256") end)
	end;

def pinned_file_problems($key; $what):
	if (.[$key] | type) != "object" then problem([$key]; " "; "is not an object; expected {\"path\": absolute path, \"sha256\": 64 lowercase hex}")
	else .[$key]
		| ((keys - ["path", "sha256"])[] | problem([$key, .]; ": "; "unknown field; expected only path and sha256")),
		  (if .path | absolute_path then empty else problem([$key, "path"]; " "; "is not an absolute path; expected the \($what)'s path") end),
		  (if .sha256 | sha256_hex then empty else problem([$key, "sha256"]; " "; "is not 64 lowercase hex digits; expected the \($what)'s sha256") end)
	end;

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

# The report and the baseline: files crucible.sh new made in the Crucible
# space, outside the repository, and not the same file.
def space_file_problems($key; $what):
	.repo_root as $root | .[$key] as $file
	| if $file | absolute_path | not then problem([$key]; " "; "is not an absolute path; expected the \($what) crucible.sh new made")
	elif ($root | absolute_path) and ($file == $root or ($file | startswith(($root | rtrimstr("/")) + "/"))) then
		problem([$key]; " "; "lies under repo_root \($root | tojson); expected a file in the Crucible space, outside the repository")
	else empty end;
def baseline_path_problems:
	space_file_problems("baseline"; "baseline file"),
	(if (.baseline | absolute_path) and .baseline == .report then problem(["baseline"]; " "; "is the report file; expected its own file of kind \(baseline_kind)") else empty end);

(if length != 1 then problem([]; " "; "is \(length) JSON values; expected exactly one object")
 elif (.[0] | type) != "object" then problem([]; " "; "is a JSON \(.[0] | type); expected an object")
 else .[0] | keys_problems, field_problems, plan_problems,
	pinned_file_problems("context"; "context file"), plugins_problems,
	entry_points_problems, space_file_problems("report"; "report file"), baseline_path_problems
 end)
| if $ARGS.named.format == "json" then {at, problem} else .line end
