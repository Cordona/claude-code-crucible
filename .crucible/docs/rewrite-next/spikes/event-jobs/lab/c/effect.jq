# Judges each of main's tool calls inside a loop by what it does.
# Input: [{t, tool, command, query, path}]; $w the loop windows, $lab, $effort.
# Output: {unnamed: [...], events_read: [...], reads: [...]}
def main_facing: "(choose|next|gate|import|job-dispatch|loop-end|merge|remote|round)";
def named_script: test("^(sh )?" + $lab + "/" + main_facing + "\\.sh( |$)")
	or test("^(sh )?" + $lab + "/real/crucible-gate/scripts/main/[a-z-]+\\.sh( |$)");
def internal: ($effort + "/(events|cards|stops)") as $i | test($i) or test("(^|[ /])events/");
def read_cmd: test("^(cat|ls|head|tail|grep|wc|sed -n|git (log|status|diff|show|ls-files)|jq)( |$)") and (test("(^| )-i( |$)") | not);
# one part of a Bash line: nothing, named, read, events or other
def part_kind:
	if test("^[A-Za-z_]+=[^ $`(]*$") then "nothing"
	elif test("^echo( |$)") and (gsub("\\$\\?"; "") | test("[$`]") | not) then "nothing"
	elif test("^cd [^;&|]+$") then "nothing"
	elif test(">") then "other"
	elif named_script then "named"
	elif internal then "events"
	elif test($lab) then "other"
	elif read_cmd then "read"
	else "other" end;
def bash_kinds:
	(.command | [splits("\\s*(;|&&|\\|\\||\\|)\\s*")] | map(select(length > 0))) as $parts
	| ($parts | map(select(test("^[A-Za-z_]+=[^ $`(]*$")) | capture("^(?<k>[A-Za-z_]+)=(?<v>.*)$")) | map({key: .k, value: .v}) | from_entries) as $vars
	| [$parts[] | reduce ($vars | to_entries[]) as $e (.; gsub("\\$\\{?" + $e.key + "\\}?"; $e.value)) | part_kind];
def kind:
	if (.tool | IN("Agent", "Task", "SendMessage", "AskUserQuestion")) then "named"
	elif .tool == "ToolSearch" then "toolsearch"
	elif (.tool | IN("Read", "Grep", "Glob")) then (if (.path | internal) then "events" elif (.path | test($lab)) then "other" else "read" end)
	elif .tool == "Bash" then (bash_kinds as $k
		| if any($k[]; . == "events") or (.command | internal) then "events" elif any($k[]; . == "other") then "other"
		  elif any($k[]; . == "read") then "read" else "named" end)
	else "other" end;
. as $all
| [.[] as $x | $w[] | select($x.t > .from and $x.t < .to) | $x] | unique_by([.t, .tool, .command, .path, .query])
| map(. as $c | . + {k: (if .tool == "ToolSearch" then
		(if (.query | test("^select:(Agent|Task|SendMessage|AskUserQuestion)$")) and any($all[]; .tool == ($c.query | ltrimstr("select:")) and .t >= $c.t and .t <= $c.t + 15) then "named" else "other" end)
	else kind end)})
| map(. + {line: "\(.tool) \(if .tool == "ToolSearch" then .query elif .tool == "Bash" then .command else .path end)"})
| {unnamed: [.[] | select(.k == "other") | .line], events_read: [.[] | select(.k == "events") | .line], reads: [.[] | select(.k == "read") | .line]}
