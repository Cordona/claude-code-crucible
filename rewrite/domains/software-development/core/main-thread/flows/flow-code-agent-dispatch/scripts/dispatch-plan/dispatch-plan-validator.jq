# The dispatch plan's shape and its rules against the installed plugins, the
# one definition generate-dispatch-plan.sh checks a plan with.
# Input: the plan slurped (jq -s), so an empty file or several values show as a
# count. --argjson installed: the installed plugins, installed-plugins.jq's
# {"<name>": {"kind": "language"|"framework"|"standard"|"procedure", "label":
# str}, ...}.
# The plan: {agent, tasks, plugins: {load: {language, frameworks, standards,
# procedures}, skip: {standards, procedures}}, replan, context_fingerprint};
# the session that wrote it is its event's;
# each plugin entry {"plugin": str}, plus "state": "invalid" or
# "uninstalled" under frameworks or skip for a step-10 re-plan's plugin
# list-plugins.sh no longer lists; a key holding nothing is left out, never
# null, [] or {}.
# Plugin rules: at most one language; a framework only with a language; skip
# holds standards and procedures only; every installed standard and procedure
# is in load or skip, once; a code-reviewer plan holds one lens: the language
# with its frameworks, or one standard, or neither, and holds no plugins when
# nothing is installed.
# A code-builder or code-tester plan always loads a language and at least one
# standard; a code-tester plan always loads standard-testing, any other plan
# never.
# Output: one "<where> <problem>; expected <x>" line per problem, nothing when
# the plan fits. With --arg format json: one {"at": <path>, "problem":
# "<problem>; expected <x>"} object per problem, at being the field's path in
# the plan ([] for the plan itself), or ["installed", <name>] for an installed
# plugin the plan leaves out.
# A plan written before a change to these rules is refused where it is checked
# again (generate-agent-dispatch.sh); regenerate it at the flow's step 7; plans
# are never migrated.

include "dispatch-names" {search: "../agent-dispatch"};

def testing_plugin: "standard-testing";
def lens_agent: "code-reviewer";
def tester_agent: "code-tester";
# The agent a plan names, as its rule texts call it.
def agent_word: if . == tester_agent then "a test agent" else "a build agent" end;
# A step-10 re-plan may list, under skip, a plugin list-plugins.sh no longer prints.
def plugin_states: "invalid", "uninstalled";
def top_keys: ["agent", "tasks", "plugins", "replan", "context_fingerprint"];
def plugins_keys: ["load", "skip"];
def load_keys: ["language", "frameworks", "standards", "procedures"];
def skip_keys: ["standards", "procedures"];
# The plugin kind each plugins.load or plugins.skip key holds, and back.
def list_key_kinds: {language: "language", frameworks: "framework", standards: "standard", procedures: "procedure"};
def kind_list_keys: {language: "language", framework: "frameworks", standard: "standards", procedure: "procedures"};
def plugin_item_shape: "{\"plugin\": str}";

def text_ok: type == "string" and (gsub("[[:cntrl:][:space:]]"; "") | length > 0);
# A field name from the plan is quoted as JSON and cut, so it prints on one line.
def quoted_name: tojson | if length > 60 then .[:60] + "…" else . end;
# A location such as tasks[1] or plugins.skip.standards[0].state; a key other than a plain name is quoted.
def location: reduce .[] as $step ("";
	if ($step | type) == "number" then . + "[\($step)]"
	elif ($step | test("^[a-z_][a-z0-9_]*$")) then . + (if . == "" then "" else "." end) + $step
	else . + (if . == "" then "" else "." end) + ($step | quoted_name) end);
def problem($at; $separator; $problem):
	{at: $at, problem: $problem, line: "\(if $at == [] then "the plan" else $at | location end)\($separator)\($problem)"};
def empty_problem($at): problem($at; " "; "is empty; expected the key left out when it holds nothing");

def field_problems:
	((keys - top_keys)[] | problem([.]; ": "; "unknown field; expected only \(top_keys | join(", "))")),
	(if .agent | text_ok | not then problem(["agent"]; " "; "missing or empty; expected a non-empty string")
	 elif .agent | IN(dispatched_agents[]) then empty
	 else problem(["agent"]; " "; "\(.agent | tojson) is not a dispatched agent; expected one of \(dispatched_agents | map(tojson) | join(", "))") end);

def tasks_problems:
	if (.tasks | type) != "array" or (.tasks | length) == 0 then problem(["tasks"]; " "; "missing or empty; expected an array of one or more strings")
	else .tasks | to_entries[] | select(.value | text_ok | not) | problem(["tasks", .key]; " "; "is not a non-empty string; expected the task text") end;

# Input: one plugin entry at $at; a state only under frameworks or skip.
def item_problems($at):
	($at[1] == "skip" or $at[2] == "frameworks") as $state_ok
	| if type != "object" then problem($at; " "; "is a JSON \(type); expected \(plugin_item_shape)")
	else ((keys - ["plugin", "state"])[] | problem($at + [.]; ": "; "unknown field; expected only plugin and state")),
		(if .plugin | text_ok then empty else problem($at + ["plugin"]; " "; "missing or empty; expected a plugin name") end),
		(if has("state") | not then empty
		 elif $state_ok | not then problem($at + ["state"]; " "; "is set here; expected a state only under plugins.load.frameworks or plugins.skip")
		 elif .state | IN(plugin_states) then empty
		 else problem($at + ["state"]; " "; "\(.state | tojson) is unknown; expected \"invalid\" or \"uninstalled\"") end)
	end;

# Input: the plugin list at $at.
def list_problems($at):
	if type != "array" then problem($at; " "; "is a JSON \(type); expected [\(plugin_item_shape), ...], left out for none")
	elif length == 0 then empty_problem($at)
	else to_entries[] | .key as $index | .value | item_problems($at + [$index]) end;

# Input: plugins.load.
def load_problems:
	["plugins", "load"] as $at
	| if type != "object" then problem($at; " "; "is a JSON \(type); expected {\"language\": \(plugin_item_shape), \"frameworks\": [...], \"standards\": [...], \"procedures\": [...]}, left out when nothing is loaded")
	  elif length == 0 then empty_problem($at)
	  else ((keys - load_keys)[] | problem($at + [.]; ": "; "unknown field; expected only language, frameworks, standards and procedures")),
		(select(has("language")) | .language
			| if type == "array" then problem($at + ["language"]; " "; "is an array; expected one \(plugin_item_shape): a plan loads at most one language")
			  else item_problems($at + ["language"]) end),
		(("frameworks", "standards", "procedures") as $key | select(has($key)) | .[$key] | list_problems($at + [$key]))
	  end;

# Input: plugins.skip.
def skip_problems:
	["plugins", "skip"] as $at
	| if type != "object" then problem($at; " "; "is a JSON \(type); expected {\"standards\": [...], \"procedures\": [...]}, left out when nothing is skipped")
	  elif length == 0 then empty_problem($at)
	  else ((keys - skip_keys)[]
			| if IN("language", "frameworks") then problem($at + [.]; ": "; "a language or framework is never skipped; expected only standards and procedures in skip, an unused language or framework left out")
			  else problem($at + [.]; ": "; "unknown field; expected only standards and procedures") end),
		(skip_keys[] as $key | select(has($key)) | .[$key] | list_problems($at + [$key]))
	  end;

# A code-reviewer plan with nothing installed holds no plugins object.
def plugins_problems:
	if .agent == lens_agent and (has("plugins") | not) then empty
	elif (.plugins | type) != "object" then problem(["plugins"]; " "; "missing or not an object; expected {\"load\": {...}, \"skip\": {...}}")
	else .plugins
		| ((keys - plugins_keys)[] | problem(["plugins", .]; ": "; "unknown field; expected only load and skip")),
		  (select(has("load")) | .load | load_problems),
		  (select(has("skip")) | .skip | skip_problems)
	end;

def replan_problems:
	if has("replan") | not then empty
	elif .replan == "invalid" or .replan == "stop-recommended" then empty
	else problem(["replan"]; " "; "unknown; expected \"invalid\" or \"stop-recommended\", or no replan field") end;

# The context the plan pins: the fingerprint procedure-context's context.sh
# freeze --dry-run printed for the effort's next context version.
def context_problems:
	if (.context_fingerprint | type) == "string" and (.context_fingerprint | test(sha256_pattern)) then empty
	else problem(["context_fingerprint"]; " "; "missing or not 64 lowercase hex digits; expected the fingerprint context.sh freeze --dry-run printed") end;

# Every plugin entry that names a plugin, in plan order: its path, its list
# (load or skip), its key in that list (list_key), plugin and state.
def named_items:
	[(.plugins | objects) as $plugins
	 | ("load", "skip") as $list
	 | ($plugins[$list] | objects) as $group
	 | ($group | keys_unsorted[]) as $list_key
	 | select(list_key_kinds | has($list_key))
	 | $group[$list_key] as $value
	 | if ($value | type) == "array" then $value | to_entries[] | {at: ["plugins", $list, $list_key, .key], item: .value}
	   else {at: ["plugins", $list, $list_key], item: $value} end
	 | select((.item | type) == "object" and (.item.plugin | text_ok))
	 | {at: (.at + ["plugin"]), list: $list, list_key: $list_key, plugin: .item.plugin, state: .item.state}];

# A plugin no longer installed may stay in a re-plan: dropped to skip with its
# state, or, for a framework, kept in load with state "invalid" in a
# replan "invalid" plan, which is shown blocked and never dispatched.
def dropped_ok($plan):
	(.list == "skip" and (.state | IN(plugin_states)))
	or (.list == "load" and .list_key == "frameworks" and .state == "invalid" and $plan.replan == "invalid");

def not_installed_hint:
	if .list == "skip" then ", or for a dropped plugin the state \"invalid\" or \"uninstalled\""
	elif .list_key == "frameworks" then ", or for a framework dropped as invalid the state \"invalid\" in a replan \"invalid\" plan"
	else "" end;

def kind_hint($kind):
	if .list == "skip" and ($kind | IN("language", "framework")) then "; a language or framework not used is left out"
	else "; a \($kind) goes in plugins.\(.list).\(kind_list_keys[$kind])" end;

def item_installed_problems($plan):
	$installed[.plugin] as $plugin
	| if $plugin == null then
		select(dropped_ok($plan) | not)
		| problem(.at; " "; "\(.plugin | tojson) is not installed; expected a name list-plugins.sh prints\(not_installed_hint)")
	  elif $plugin.kind == list_key_kinds[.list_key] then empty
	  else problem(.at; " "; "\(.plugin | tojson) is a \($plugin.kind) plugin; expected a \(list_key_kinds[.list_key]) plugin here\(kind_hint($plugin.kind))") end;

def coverage_problems($plan; $items):
	if ($plan.plugins | type) != "object" then empty
	else ($items | map(.plugin)) as $named
		| $installed | to_entries[] | select(.value.kind | IN("standard", "procedure")) | .key
		| select(IN($named[]) | not)
		| problem(["installed", .]; " "; "is in neither load nor skip; expected every installed standard and procedure in one of them")
	end;

def has_language($plan): ($plan.plugins | objects | .load | objects | has("language")) // false;

def framework_problems($plan; $items):
	if has_language($plan) then empty
	else $items[] | select(.list == "load" and .list_key == "frameworks")
		| problem(.at; " "; "\(.plugin | tojson) has no language; expected the language the code is in, in plugins.load.language")
	end;

def lens_problems($plan; $items):
	if $plan.agent != lens_agent then empty
	else [$items[] | select(.list == "load" and .list_key == "standards")] as $standards
		| if has_language($plan) then
			($standards[] | problem(.at; " "; "\(.plugin | tojson) with a language loaded; expected one lens per \(lens_agent) seat: the language with its frameworks, or one standard"))
		  else
			($standards[1:][] | problem(.at; " "; "\(.plugin | tojson) is a second lens, after \($standards[0].plugin | tojson); expected one standard per \(lens_agent) seat"))
		  end
	end;

def builder_problems($plan; $items):
	if $plan.agent == lens_agent or ($plan.plugins | type) != "object" then empty
	else ($plan.agent | agent_word) as $word
		| (if has_language($plan) then empty
		 else problem(["plugins", "load", "language"]; " "; "missing; expected the language the code is in: \($word) always has one") end),
		(if any($items[]; .list == "load" and .list_key == "standards") then empty
		 else problem(["plugins", "load", "standards"]; " "; "missing; expected at least one standard: \($word) always builds to one") end)
	end;

def testing_problems($plan; $items):
	if ($plan.plugins | type) != "object" then empty
	elif $plan.agent == tester_agent then
		if any($items[]; .list == "load" and .list_key == "standards" and .plugin == testing_plugin) then empty
		else problem(["plugins", "load", "standards"]; " "; "lacks \(testing_plugin | tojson); expected it loaded: a \(tester_agent) plan always loads it") end
	else $items[] | select(.list == "load" and .plugin == testing_plugin)
		| problem(.at; " "; "\(testing_plugin | tojson) in a build plan; expected it under plugins.skip.standards: a build plan never loads it")
	end;

def installed_problems:
	. as $plan
	| named_items as $items
	| ($items[] | item_installed_problems($plan)),
	  ($items | group_by(.plugin)[] | .[1:][]
		| problem(.at; " "; "\(.plugin | tojson) listed more than once; expected each plugin once in the plan")),
	  coverage_problems($plan; $items),
	  framework_problems($plan; $items),
	  lens_problems($plan; $items),
	  builder_problems($plan; $items),
	  testing_problems($plan; $items);

(if length != 1 then problem([]; " "; "is \(length) JSON values; expected exactly one object")
 elif (.[0] | type) != "object" then problem([]; " "; "is a JSON \(.[0] | type); expected an object")
 else .[0] | field_problems, tasks_problems, plugins_problems, replan_problems, context_problems, installed_problems
 end)
| if $ARGS.named.format == "json" then {at, problem} else .line end
