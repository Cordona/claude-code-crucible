# The dispatch plan's shape and its rules against the installed plugins, the
# one definition generate-dispatch-plan.sh checks a plan with.
# Input: the plan slurped (jq -s), so an empty file or several values show as a
# count. --argjson installed: the installed plugins, installed-plugins.jq's
# {"<name>": {"kind": "language"|"framework"|"standard"|"procedure", "label":
# str}, ...}.
# The plan: {claude_session_id, agent, mode, tasks, plugins: {load: {language,
# frameworks, standards, procedures}, skip: {standards, procedures},
# load_reason}, replan, context}, claude_session_id the session that wrote it;
# each plugin entry {"plugin": str, "reason": str}; a key holding
# nothing is left out, never null, [] or {}.
# Plugin rules: at most one language; a framework only with a language; skip
# holds standards and procedures only; every installed standard and procedure
# is in load or skip, once; load_reason only when nothing is loaded; a
# code-reviewer plan holds one lens: the language with its frameworks, or one
# standard, or neither.
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
# A step-10 re-plan may list, under skip, a plugin list-plugins.sh no longer prints.
def dropped_reasons: "invalid", "uninstalled after approval", "faulty files";
def top_keys: ["claude_session_id", "agent", "mode", "tasks", "plugins", "replan", "context"];
def plugins_keys: ["load", "skip", "load_reason"];
def load_keys: ["language", "frameworks", "standards", "procedures"];
def skip_keys: ["standards", "procedures"];
# The plugin kind each plugins.load or plugins.skip key holds, and back.
def slot_kinds: {language: "language", frameworks: "framework", standards: "standard", procedures: "procedure"};
def kind_slots: {language: "language", framework: "frameworks", standard: "standards", procedure: "procedures"};
def plugin_item_shape: "{\"plugin\": str, \"reason\": str}";

def text_ok: type == "string" and (gsub("[[:cntrl:][:space:]]"; "") | length > 0);
# A field name from the plan is quoted as JSON and cut, so it prints on one line.
def quoted_name: tojson | if length > 60 then .[:60] + "…" else . end;
# A location such as tasks[1] or plugins.load.standards[0].reason; a key other than a plain name is quoted.
def location: reduce .[] as $step ("";
	if ($step | type) == "number" then . + "[\($step)]"
	elif ($step | test("^[a-z_][a-z0-9_]*$")) then . + (if . == "" then "" else "." end) + $step
	else . + (if . == "" then "" else "." end) + ($step | quoted_name) end);
def problem($at; $separator; $problem):
	{at: $at, problem: $problem, line: "\(if $at == [] then "the plan" else $at | location end)\($separator)\($problem)"};
def empty_problem($at): problem($at; " "; "is empty; expected the key left out when it holds nothing");

def field_problems:
	((keys - top_keys)[] | problem([.]; ": "; "unknown field; expected only \(top_keys | join(", "))")),
	(if (.claude_session_id | type) == "string" and (.claude_session_id | test(claude_session_id_pattern)) then empty
	 else problem(["claude_session_id"]; " "; "missing or not a session ID; expected a lowercase UUID, the session that wrote the plan") end),
	(if .agent | text_ok | not then problem(["agent"]; " "; "missing or empty; expected a non-empty string")
	 elif .agent | IN(dispatched_agents[]) then empty
	 else problem(["agent"]; " "; "\(.agent | tojson) is not a dispatched agent; expected one of \(dispatched_agents | map(tojson) | join(", "))") end),
	(if .mode == "BUILD" or .mode == "TEST" then empty else problem(["mode"]; " "; "missing or unknown; expected \"BUILD\" or \"TEST\"") end);

def tasks_problems:
	if (.tasks | type) != "array" or (.tasks | length) == 0 then problem(["tasks"]; " "; "missing or empty; expected an array of one or more strings")
	else .tasks | to_entries[] | select(.value | text_ok | not) | problem(["tasks", .key]; " "; "is not a non-empty string; expected the task text") end;

# Input: one plugin entry at $at.
def item_problems($at):
	if type != "object" then problem($at; " "; "is a JSON \(type); expected \(plugin_item_shape)")
	else ((keys - ["plugin", "reason"])[] | problem($at + [.]; ": "; "unknown field; expected only plugin and reason")),
		(if .plugin | text_ok then empty else problem($at + ["plugin"]; " "; "missing or empty; expected a plugin name") end),
		(if .reason | text_ok then empty else problem($at + ["reason"]; " "; "missing or empty; expected a non-empty string") end)
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

# Input: plugins.
def load_reason_problems:
	["plugins", "load_reason"] as $at
	| if has("load") then (if has("load_reason") then problem($at; " "; "given with plugins loaded; expected it only when nothing is loaded") else empty end)
	  elif has("load_reason") | not then problem($at; " "; "missing with nothing loaded; expected a non-empty string saying why no plugin is loaded")
	  elif .load_reason | text_ok | not then problem($at; " "; "is not a non-empty string; expected why no plugin is loaded")
	  else empty end;

def plugins_problems:
	if (.plugins | type) != "object" then problem(["plugins"]; " "; "missing or not an object; expected {\"load\": {...}, \"skip\": {...}}, with \"load_reason\" instead of \"load\" when nothing is loaded")
	else .plugins
		| ((keys - plugins_keys)[] | problem(["plugins", .]; ": "; "unknown field; expected only load, skip and load_reason")),
		  (select(has("load")) | .load | load_problems),
		  (select(has("skip")) | .skip | skip_problems),
		  load_reason_problems
	end;

def replan_problems:
	if has("replan") | not then empty
	elif .replan == "invalid" or .replan == "stop-recommended" then empty
	else problem(["replan"]; " "; "unknown; expected \"invalid\" or \"stop-recommended\", or no replan field") end;

def context_problems:
	if (.context | type) != "object" then problem(["context"]; " "; "missing or not an object; expected {\"path\": absolute path, \"sha256\": 64 lowercase hex}")
	else .context
		| ((keys - ["path", "sha256"])[] | problem(["context", .]; ": "; "unknown field; expected only path and sha256")),
		  (if (.path | type) == "string" and (.path | startswith("/")) and (.path | test("[[:cntrl:]]") | not) then empty
		   else problem(["context", "path"]; " "; "missing or not an absolute path; expected the context file's absolute path") end),
		  (if (.sha256 | type) == "string" and (.sha256 | test(sha256_pattern)) then empty
		   else problem(["context", "sha256"]; " "; "missing or not 64 lowercase hex digits; expected the context file's sha256") end)
	end;

# Every plugin entry that names a plugin, in plan order: its path, its list
# (load or skip), its key in that list (slot), plugin and reason.
def named_items:
	[(.plugins | objects) as $plugins
	 | ("load", "skip") as $list
	 | ($plugins[$list] | objects) as $group
	 | ($group | keys_unsorted[]) as $slot
	 | select(slot_kinds | has($slot))
	 | $group[$slot] as $value
	 | if ($value | type) == "array" then $value | to_entries[] | {at: ["plugins", $list, $slot, .key], item: .value}
	   else {at: ["plugins", $list, $slot], item: $value} end
	 | select((.item | type) == "object" and (.item.plugin | text_ok))
	 | {at: (.at + ["plugin"]), list: $list, slot: $slot, plugin: .item.plugin, reason: .item.reason}];

# A plugin no longer installed may stay in a re-plan: dropped to skip with its
# drop reason, or, for a framework, kept in load with reason "invalid" in a
# replan "invalid" plan, which is shown blocked and never dispatched.
def dropped_ok($plan):
	(.list == "skip" and (.reason | IN(dropped_reasons)))
	or (.list == "load" and .slot == "frameworks" and .reason == "invalid" and $plan.replan == "invalid");

def not_installed_hint:
	if .list == "skip" then ", or for a dropped plugin a reason of exactly \"invalid\", \"uninstalled after approval\" or \"faulty files\""
	elif .slot == "frameworks" then ", or for a framework dropped as invalid the reason \"invalid\" in a replan \"invalid\" plan"
	else "" end;

def kind_hint($kind):
	if .list == "skip" and ($kind | IN("language", "framework")) then "; a language or framework not used is left out"
	else "; a \($kind) goes in plugins.\(.list).\(kind_slots[$kind])" end;

def item_installed_problems($plan):
	$installed[.plugin] as $plugin
	| if $plugin == null then
		select(dropped_ok($plan) | not)
		| problem(.at; " "; "\(.plugin | tojson) is not installed; expected a name list-plugins.sh prints\(not_installed_hint)")
	  elif $plugin.kind == slot_kinds[.slot] then empty
	  else problem(.at; " "; "\(.plugin | tojson) is a \($plugin.kind) plugin; expected a \(slot_kinds[.slot]) plugin here\(kind_hint($plugin.kind))") end;

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
	else $items[] | select(.list == "load" and .slot == "frameworks")
		| problem(.at; " "; "\(.plugin | tojson) has no language; expected the language the code is in, in plugins.load.language")
	end;

def lens_problems($plan; $items):
	if $plan.agent != lens_agent then empty
	else [$items[] | select(.list == "load" and .slot == "standards")] as $standards
		| if has_language($plan) then
			($standards[] | problem(.at; " "; "\(.plugin | tojson) with a language loaded; expected one lens per \(lens_agent) seat: the language with its frameworks, or one standard"))
		  else
			($standards[1:][] | problem(.at; " "; "\(.plugin | tojson) is a second lens, after \($standards[0].plugin | tojson); expected one standard per \(lens_agent) seat"))
		  end
	end;

def testing_problems($plan; $items):
	if ($plan.plugins | type) != "object" then empty
	else [$items[] | select(.list == "load" and .plugin == testing_plugin)] as $testing
		| if $plan.mode == "TEST" and ($testing | length) == 0 then
			problem(["mode"]; " "; "\"TEST\" without \(testing_plugin) loaded; expected \(testing_plugin) in plugins.load.standards")
		  elif $plan.mode == "BUILD" then
			($testing[] | problem(.at; " "; "\(testing_plugin | tojson) in a mode \"BUILD\" plan; expected it only in a TEST plan, under plugins.skip.standards here"))
		  else empty end
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
	  testing_problems($plan; $items);

(if length != 1 then problem([]; " "; "is \(length) JSON values; expected exactly one object")
 elif (.[0] | type) != "object" then problem([]; " "; "is a JSON \(.[0] | type); expected an object")
 else .[0] | field_problems, tasks_problems, plugins_problems, replan_problems, context_problems, installed_problems
 end)
| if $ARGS.named.format == "json" then {at, problem} else .line end
