# The dispatch plan's shape and its rules against the installed plugins, the
# one definition generate-dispatch-plan.sh checks a plan with.
# Input: the plan slurped (jq -s), so an empty file or several values show as a
# count. --argjson installed: the installed plugins, from list-plugins.sh's
# plugin lines, as {"<name>": {"kind": "tech"|"standard"|"procedure", "label":
# str}, ...}; the only kind rule is at most one tech plugin loaded, so a
# procedure plugin is loaded or skipped as a standard one is.
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
# A step-10 re-plan may list, under not_loaded, a plugin list-plugins.sh no longer prints.
def dropped_reasons: "invalid", "uninstalled after approval", "faulty files";
def top_keys: ["agent", "mode", "technology", "tasks", "loaded", "loaded_reason", "not_loaded", "replan", "context"];
def plugin_item_shape: "{\"plugin\": str, \"reason\": str}";

def text_ok: type == "string" and (gsub("[[:cntrl:][:space:]]"; "") | length > 0);
# A field name from the plan is quoted as JSON and cut, so it prints on one line.
def quoted_name: tojson | if length > 60 then .[:60] + "…" else . end;
# A location such as tasks[1] or loaded[0].reason; a key other than a plain name is quoted.
def location: reduce .[] as $step ("";
	if ($step | type) == "number" then . + "[\($step)]"
	elif ($step | test("^[a-z_][a-z0-9_]*$")) then . + (if . == "" then "" else "." end) + $step
	else . + (if . == "" then "" else "." end) + ($step | quoted_name) end);
def problem($at; $separator; $problem):
	{at: $at, problem: $problem, line: "\(if $at == [] then "the plan" else $at | location end)\($separator)\($problem)"};

def field_problems:
	((keys - top_keys)[] | problem([.]; ": "; "unknown field; expected only \(top_keys | join(", "))")),
	(if .agent | text_ok then empty else problem(["agent"]; " "; "missing or empty; expected a non-empty string") end),
	(if .mode == "BUILD" or .mode == "TEST" then empty else problem(["mode"]; " "; "missing or unknown; expected \"BUILD\" or \"TEST\"") end),
	(if .technology | text_ok then empty else problem(["technology"]; " "; "missing or empty; expected the tech plugin's label or \"none\"") end),
	(if .agent == direct_agent and (.mode != "BUILD" or .technology != "none") then
		problem(["agent"]; " "; "\(direct_agent | tojson) (direct implementation) with mode \(.mode | tojson) and technology \(.technology | tojson); expected mode \"BUILD\" and technology \"none\"")
	 else empty end);

def tasks_problems:
	if (.tasks | type) != "array" or (.tasks | length) == 0 then problem(["tasks"]; " "; "missing or empty; expected an array of one or more strings")
	else .tasks | to_entries[] | select(.value | text_ok | not) | problem(["tasks", .key]; " "; "is not a non-empty string; expected the task text") end;

def plugins_problems($key):
	if (.[$key] | type) != "array" then problem([$key]; " "; "missing or not an array; expected [\(plugin_item_shape), ...] ([] for none)")
	else .[$key] | to_entries[] | .key as $index | .value
		| if type != "object" then problem([$key, $index]; " "; "is a JSON \(type); expected \(plugin_item_shape)")
		  else ((keys - ["plugin", "reason"])[] | problem([$key, $index, .]; ": "; "unknown field; expected only plugin and reason")),
			(if .plugin | text_ok then empty else problem([$key, $index, "plugin"]; " "; "missing or empty; expected a plugin name") end),
			(if .reason | text_ok then empty else problem([$key, $index, "reason"]; " "; "missing or empty; expected a non-empty string") end)
		  end
	end;

def loaded_reason_problems:
	if (.loaded | type) != "array" then empty
	elif (.loaded | length) == 0 then
		(if has("loaded_reason") | not then problem(["loaded_reason"]; " "; "missing; expected a non-empty string saying why loaded is []")
		 elif .loaded_reason | text_ok | not then problem(["loaded_reason"]; " "; "is not a non-empty string; expected why loaded is []")
		 else empty end)
	elif has("loaded_reason") then problem(["loaded_reason"]; " "; "given with plugins loaded; expected it only when loaded is []")
	else empty end;

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

def named_items:
	[("loaded", "not_loaded") as $key
	 | .[$key] | select(type == "array") | to_entries[]
	 | select((.value | type) == "object" and (.value.plugin | text_ok))
	 | {at: [$key, .key, "plugin"], list: $key, plugin: .value.plugin, reason: .value.reason}];

def tech_problems($plan; $items):
	# A plugin listed twice is reported once, as listed more than once.
	(reduce ($items[] | select(.list == "loaded" and $installed[.plugin].kind == "tech")) as $item ([];
		if any(.[]; .plugin == $item.plugin) then . else . + [$item] end)) as $tech
	| ($tech[1:][] | problem(.at; " "; "\(.plugin | tojson) is a second tech plugin, after \($tech[0].plugin | tojson); expected at most one tech plugin loaded")),
	  (if ($tech | length) > 1 or ($plan.technology | text_ok | not) then empty
	   elif ($tech | length) == 1 then
		$installed[$tech[0].plugin].label as $tech_label
		| if $plan.technology == $tech_label then empty
		  else problem(["technology"]; " "; "\($plan.technology | tojson) is not the label of \($tech[0].plugin); expected \($tech_label | tojson)") end
	   elif $plan.technology == "none" then empty
	   else problem(["technology"]; " "; "\($plan.technology | tojson) with no tech plugin loaded; expected \"none\"") end);

def testing_problems($plan; $items):
	if ($plan.loaded | type) != "array" then empty
	else [$items[] | select(.list == "loaded" and .plugin == testing_plugin)] as $testing
		| if $plan.mode == "TEST" and ($testing | length) == 0 then
			problem(["mode"]; " "; "\"TEST\" without \(testing_plugin) loaded; expected \(testing_plugin) in loaded")
		  elif $plan.mode == "BUILD" then
			($testing[] | problem(.at; " "; "\(testing_plugin | tojson) in a mode \"BUILD\" plan; expected it only in a TEST plan, under not_loaded here"))
		  else empty end
	end;

def installed_problems:
	. as $plan
	| named_items as $items
	| ($items[] | select(.plugin as $name | $installed | has($name) | not)
		| select(.list == "loaded" or (.reason | IN(dropped_reasons) | not))
		| problem(.at; " "; "\(.plugin | tojson) is not installed; expected a name list-plugins.sh prints"
			+ (if .list == "not_loaded" then ", or for a dropped plugin a reason of exactly \"invalid\", \"uninstalled after approval\" or \"faulty files\"" else "" end))),
	  ($items | group_by(.plugin)[] | .[1:][]
		| problem(.at; " "; "\(.plugin | tojson) listed more than once; expected each plugin once, in loaded or not_loaded")),
	  (if ($plan.loaded | type) == "array" and ($plan.not_loaded | type) == "array" then
		($items | map(.plugin)) as $named
		| $installed | keys[] | select(IN($named[]) | not)
		| problem(["installed", .]; " "; "is in neither loaded nor not_loaded; expected every installed plugin in one of them")
	   else empty end),
	  tech_problems($plan; $items),
	  testing_problems($plan; $items);

(if length != 1 then problem([]; " "; "is \(length) JSON values; expected exactly one object")
 elif (.[0] | type) != "object" then problem([]; " "; "is a JSON \(.[0] | type); expected an object")
 else .[0] | field_problems, tasks_problems, plugins_problems("loaded"), plugins_problems("not_loaded"),
	loaded_reason_problems, replan_problems, context_problems, installed_problems
 end)
| if $ARGS.named.format == "json" then {at, problem} else .line end
