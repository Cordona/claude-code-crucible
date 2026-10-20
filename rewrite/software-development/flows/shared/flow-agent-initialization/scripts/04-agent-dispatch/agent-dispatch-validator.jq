# The agent dispatch file's shape, the one definition generate-agent-dispatch.sh
# checks a dispatch with. Input: the dispatch slurped (jq -s), so an empty file
# or several values show as a count.
# Output: one "<where> <problem>; expected <x>" line per problem, nothing when
# the dispatch fits. With --arg format json: one {"at": <the field's path, []
# for the dispatch itself>, "problem": "<problem>; expected <x>"} per problem.
# A dispatch written before a change to this contract is refused
# (generate-agent-dispatch.sh's re-check, the hook, --direct); regenerate it at
# the flow's step 8.

include "dispatch-names" {search: "./"};

# The agents a dispatch file is written for, direct implementation among them;
# mode TEST is not dispatched through this file yet.
def dispatched_agents: listed_agents + [direct_agent];
def dispatched_modes: ["BUILD"];
def top_keys: ["id", "started", "agent", "mode", "tech", "plugins", "plan", "context", "task", "repo_root", "starting_points", "report"];

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

def keys_problems:
	((keys - top_keys)[] | problem([.]; ": "; "unknown field; expected only \(top_keys | join(", "))")),
	(top_keys[] as $key | select(has($key) | not) | problem([$key]; " "; "missing; expected every one of \(top_keys | join(", "))"));

def field_problems:
	(if (.id | type) == "string" and (.id | test("^[0-9]{8}T[0-9]{6}-[0-9a-f]{4}$")) then empty
	 else problem(["id"]; " "; "is not a Crucible ID; expected <YYYYMMDDTHHMMSS>-<4 lowercase hex>") end),
	(if (.started | type) == "string" and (.started | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}$")) then empty
	 else problem(["started"]; " "; "is not an ISO 8601 local time with offset; expected YYYY-MM-DDTHH:MM:SS+HH:MM") end),
	(if .agent | IN(dispatched_agents[]) then empty
	 else problem(["agent"]; " "; "\(.agent | tojson) is not dispatched through a dispatch file; expected one of \(dispatched_agents | map(tojson) | join(", "))") end),
	(if .mode | IN(dispatched_modes[]) then empty
	 else problem(["mode"]; " "; "\(.mode | tojson) is not dispatched through a dispatch file; expected \"BUILD\" (TEST dispatches are held in the flow)") end),
	(if .task | text_ok then empty else problem(["task"]; " "; "is not a non-empty string; expected the task text") end),
	(if .repo_root | absolute_path then empty else problem(["repo_root"]; " "; "is not an absolute path; expected the repository's git work-tree root") end);

def pinned_file_problems($key; $what):
	if (.[$key] | type) != "object" then problem([$key]; " "; "is not an object; expected {\"path\": absolute path, \"sha256\": 64 lowercase hex}")
	else .[$key]
		| ((keys - ["path", "sha256"])[] | problem([$key, .]; ": "; "unknown field; expected only path and sha256")),
		  (if .path | absolute_path then empty else problem([$key, "path"]; " "; "is not an absolute path; expected the \($what)'s path") end),
		  (if .sha256 | sha256_hex then empty else problem([$key, "sha256"]; " "; "is not 64 lowercase hex digits; expected the \($what)'s sha256") end)
	end;

def plugins_problems:
	if (.plugins | type) != "array" then problem(["plugins"]; " "; "is not an array; expected [{\"name\": str, \"paths\": [absolute path, ...]}, ...] ([] for none)")
	else (.plugins | to_entries[] | .key as $index | .value
		| if type != "object" then problem(["plugins", $index]; " "; "is a JSON \(type); expected {\"name\": str, \"paths\": [absolute path, ...]}")
		  else ((keys - ["name", "paths"])[] | problem(["plugins", $index, .]; ": "; "unknown field; expected only name and paths")),
			(if .name | text_ok then empty else problem(["plugins", $index, "name"]; " "; "is not a non-empty string; expected a plugin name") end),
			(if (.paths | type) == "array" and (.paths | length) > 0 then
				(.paths | to_entries[] | select(.value | absolute_path | not)
					| problem(["plugins", $index, "paths", .key]; " "; "is not an absolute path; expected a plugin file's path"))
			 else problem(["plugins", $index, "paths"]; " "; "is not a non-empty array; expected the plugin's files") end)
		  end),
	  ([.plugins[] | objects | .name | strings] | group_by(.)[] | select(length > 1)
		| problem(["plugins"]; " "; "names \(.[0] | tojson) more than once; expected each plugin once"))
	end;

def tech_problems:
	.tech as $tech
	| if .agent == direct_agent and $tech != "none" then
		problem(["tech"]; " "; "\($tech | tojson) for agent \(direct_agent | tojson); expected \"none\", as direct implementation loads no tech plugin")
	elif $tech == "none" then empty
	elif ($tech | type) == "string" and ($tech | startswith("tech-"))
		and ([.plugins[]? | objects | .name] | index([$tech]) != null) then empty
	else problem(["tech"]; " "; "\(.tech | tojson) is not a loaded tech plugin; expected the name of the tech-* plugin in plugins, or \"none\"") end;

def starting_points_problems:
	if (.starting_points | type) != "array" then problem(["starting_points"]; " "; "is not an array; expected [repo-relative path, ...] ([] for none)")
	else .starting_points | to_entries[] | select(.value | relative_path | not)
		| problem(["starting_points", .key]; " "; "is not a repo-relative path; expected a path inside the repository without a leading /, a .. segment or a control character")
	end;

def report_problems:
	.repo_root as $root | .report as $report
	| if $report | absolute_path | not then problem(["report"]; " "; "is not an absolute path; expected the report file crucible.sh new made")
	elif ($root | absolute_path) and ($report == $root or ($report | startswith(($root | rtrimstr("/")) + "/"))) then
		problem(["report"]; " "; "lies under repo_root \($root | tojson); expected a file in the Crucible space, outside the repository")
	else empty end;

(if length != 1 then problem([]; " "; "is \(length) JSON values; expected exactly one object")
 elif (.[0] | type) != "object" then problem([]; " "; "is a JSON \(.[0] | type); expected an object")
 else .[0] | keys_problems, field_problems, pinned_file_problems("plan"; "gate record"),
	pinned_file_problems("context"; "context file"), plugins_problems, tech_problems,
	starting_points_problems, report_problems
 end)
| if $ARGS.named.format == "json" then {at, problem} else .line end
