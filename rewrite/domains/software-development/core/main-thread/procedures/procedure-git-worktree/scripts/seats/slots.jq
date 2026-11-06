# The effort's seat list, slots.json: each slot a seat (dev-1, test-1,
# security-1) whose agent is replaceable. A module: load it with
# jq -L <this folder> and include "slots".
# slots_problems checks a parsed file and prints a list of
# "<where> <problem>; expected <x>" lines, empty when it fits the contract.
# slots_run checks the options, checks the file and applies one command;
# slots_checked refuses a changed file that no longer fits, so the shell
# never edits JSON. A key with nothing in it is left out, never null, [] or {}.

def slots_top_fields: ["effort", "slots"];
def slots_roles: ["developer", "tester", "reviewer"];
def slots_writer_modes: {"developer": "BUILD", "tester": "TEST"};
def slots_statuses: ["open", "working", "idle", "gave-up"];
# open is only ever set by add and handover, with the agent removed.
def slots_settable_statuses: ["working", "idle", "gave-up"];
def slots_writer_fields: ["slot", "role", "mode", "agent_id", "dispatch", "previous_agent_ids", "worktree", "repo", "base", "base_slots", "awaiting_round", "status"];
def slots_reviewer_fields: ["slot", "role", "lens", "agent_id", "dispatch", "previous_agent_ids", "status"];
# Present only when they hold something; status decides whether agent_id and
# dispatch must be.
def slots_optional_fields: ["agent_id", "dispatch", "previous_agent_ids", "base_slots", "awaiting_round"];
# The bound agent's keys: they come and go together.
def slots_agent_fields: ["agent_id", "dispatch"];
# The order a slot's fields are written in.
def slots_field_order: ["slot", "role", "mode", "lens", "agent_id", "dispatch", "previous_agent_ids", "worktree", "repo", "base", "base_slots", "awaiting_round", "status"];
# The largest round a JSON number holds exactly.
def slots_round_max: 9007199254740991;

def slots_list: join(", ");
def slots_role_fields: if . == "reviewer" then slots_reviewer_fields else slots_writer_fields end;
def slots_is_empty: . == null or . == [] or . == {};

def slots_pattern_problem($pattern; $what):
	if type != "string" then "is a JSON \(type); expected \($what)"
	elif test($pattern) | not then "\(tojson) is not allowed; expected \($what)"
	else empty
	end;

def slots_name_problem: slots_pattern_problem("^[a-z][a-z0-9]*-[1-9][0-9]*$"; "a slot name like dev-1: a lowercase word, a dash and a number of 1 or more");
def slots_lens_problem: slots_pattern_problem("^[a-z0-9-]+$"; "a lens name of lowercase letters, digits and dashes");
def slots_agent_problem: slots_pattern_problem("^[A-Za-z0-9_-]+$"; "an agent id of letters, digits, _ and -");
def slots_dispatch_problem: slots_pattern_problem("^[A-Za-z0-9_-]+$"; "a dispatch id of letters, digits, _ and -");
def slots_base_problem: slots_pattern_problem("^[0-9a-f]{40}$"; "a 40-character lowercase hex commit sha");

def slots_path_problem:
	if type != "string" then "is a JSON \(type); expected an absolute path"
	elif test("[[:cntrl:]]") then "holds a control character; expected a plain absolute path"
	elif startswith("/") | not then "\(tojson) is not absolute; expected an absolute path"
	else empty
	end;

def slots_enum_problem($values):
	if type == "string" and IN($values[]) then empty
	else "\(tojson) is not allowed; expected one of \($values | slots_list)"
	end;

def slots_round_problem:
	if type != "number" then "is a JSON \(type); expected a whole number of 1 or more"
	elif . != floor or . < 1 or . > slots_round_max then "\(.) is not allowed; expected a whole number of 1 or more"
	else empty
	end;

def slots_previous_problem:
	if type != "array" then "is a JSON \(type); expected an array of agent ids, oldest first"
	else
		(to_entries[] | .key as $index | .value | slots_agent_problem | "item \($index) \(.)"),
		(map(strings) | group_by(.) | map(select(length > 1) | .[0])[] | "holds \(tojson) more than once; expected each agent once")
	end;

def slots_base_slots_problem:
	if type != "array" then "is a JSON \(type); expected an array of the slots the seat was cut from"
	else
		(to_entries[] | .key as $index | .value | slots_name_problem | "item \($index) \(.)"),
		(map(strings) | group_by(.) | map(select(length > 1) | .[0])[] | "holds \(tojson) more than once; expected each slot once")
	end;

# Each base slot of each seat must name another developer seat of the file.
def slots_base_link_problems:
	(reduce (.slots[] | objects | select(.slot | type == "string")) as $seat ({}; .[$seat.slot] = $seat.role)) as $roles
	| .slots | to_entries[] | .key as $index | .value
	| select(type == "object" and (.base_slots | type) == "array") | .slot as $own
	| .base_slots[] | strings | select([slots_name_problem] == [])
	| "slots[\($index)].base_slots \(tojson) "
		+ (if . == $own then "is the seat itself; expected another seat"
		elif $roles[.] == null then "is not in the file; expected an existing seat"
		elif $roles[.] != "developer" then "is a \($roles[.]) seat; expected a developer seat"
		else empty
		end);

# The seats $from reaches through the base_slots links $links, each once.
def slots_base_reach($links; $from):
	{queue: ($links[$from] // []), seen: []}
	| until(.queue == [];
		.queue[0] as $next | .queue |= .[1:]
		| if any(.seen[]; . == $next) then . else .seen += [$next] | .queue += ($links[$next] // []) end)
	| .seen;

# A seat may not be cut, through any number of base_slots, from itself;
# each cycle is named once, by its seats in order. A seat naming itself is
# slots_base_link_problems' to report.
def slots_base_cycle_problems:
	(reduce (.slots[] | objects | select((.slot | type) == "string" and (.base_slots | type) == "array")) as $seat ({};
		.[$seat.slot] = [$seat.base_slots[] | strings | select(. != $seat.slot)])) as $links
	| ($links | keys[]) as $slot
	| slots_base_reach($links; $slot) as $reach
	| select(any($reach[]; . == $slot))
	| ([$slot] + [$reach[] | . as $other | select(any(slots_base_reach($links; $other)[]; . == $slot))] | unique) as $cycle
	| select($cycle[0] == $slot)
	| "base_slots of \($cycle | slots_list) form a cycle; expected no seat cut from itself through other seats";

# The problems of the values of a slot whose role is valid; $fields are its
# role's. An empty value is reported once, by slots_empty_problems.
def slots_value_problems($where; $fields):
	. as $slot
	| to_entries[] | select((.key | IN($fields[])) and (.value | slots_is_empty | not)) | .key as $field | .value
	| (if $field == "slot" then slots_name_problem
	elif $field == "mode" then
		slots_writer_modes[$slot.role] as $mode
		| if . == $mode then empty else "\(tojson) is not allowed; expected \($mode) for a \($slot.role)" end
	elif $field == "lens" then slots_lens_problem
	elif $field == "agent_id" then slots_agent_problem
	elif $field == "dispatch" then slots_dispatch_problem
	elif $field == "previous_agent_ids" then slots_previous_problem
	elif $field == "worktree" or $field == "repo" then slots_path_problem
	elif $field == "base" then slots_base_problem
	elif $field == "base_slots" then slots_base_slots_problem
	elif $field == "awaiting_round" then slots_round_problem
	elif $field == "status" then slots_enum_problem(slots_statuses)
	else empty
	end)
	| "\($where).\($field) \(.)";

# An open seat has no agent and no dispatch; every other status has both.
def slots_pairing_problems($where):
	. as $slot
	| if (.status | IN(slots_statuses[]) | not) then empty
	else slots_agent_fields[] as $field
		| if $slot.status == "open" and ($slot | has($field)) then "\($where).\($field) is given on an open seat; expected no \($field) while open"
		elif $slot.status != "open" and ($slot | has($field) | not) then "\($where).\($field) is missing; expected one while \($slot.status)"
		else empty
		end
	end;

def slots_slot_problems($where):
	if type != "object" then "\($where) is a JSON \(type); expected a slot object"
	elif has("role") | not then "\($where).role is missing; expected one of \(slots_roles | slots_list)"
	elif (.role | type) != "string" or (.role | IN(slots_roles[]) | not) then "\($where).role \(.role | slots_enum_problem(slots_roles))"
	else
		. as $slot
		| (.role | slots_role_fields) as $fields
		| (keys_unsorted[] | select(IN($fields[]) | not)
			| "\($where) field \(tojson) is not a field of a \($slot.role); expected only \($fields | slots_list)"),
		($fields[] | select(IN(slots_optional_fields[]) | not) | select(. as $field | $slot | has($field) | not)
			| "\($where).\(.) is missing; expected it for a \($slot.role)"),
		slots_value_problems($where; $fields),
		slots_pairing_problems($where)
	end;

# Every null, [] or {} anywhere in the file, by its path.
def slots_empty_problems:
	paths(slots_is_empty) as $path
	| "\($path | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | ltrimstr(".")) is \(getpath($path) | tojson); expected the key left out when empty";

def slots_problems:
	if type != "object" then ["the file is a JSON \(type); expected an object of effort and slots"]
	else [
		slots_empty_problems,
		(keys_unsorted[] | select(IN(slots_top_fields[]) | not) | "field \(tojson) is not a field; expected only \(slots_top_fields | slots_list)"),
		(if has("effort") | not then "effort is missing; expected the effort id"
		elif (.effort | type) != "string" or .effort == "" then "effort \(.effort | tojson) is not allowed; expected a non-empty string"
		else empty
		end),
		(if has("slots") | not then "slots is missing; expected an array of slots"
		elif (.slots | type) != "array" then "slots is a JSON \(.slots | type); expected an array of slots"
		else
			(.slots | to_entries[] | .key as $index | .value | slots_slot_problems("slots[\($index)]")),
			slots_base_link_problems,
			slots_base_cycle_problems,
			([.slots[] | objects | .slot | strings] | group_by(.) | map(select(length > 1) | .[0])[]
				| "slot \(tojson) appears more than once; expected unique slot names")
		end)
	]
	end;

# The problems of the given options ({name: value}, an absent option left out).
def slots_option_problems:
	to_entries[] | .key as $name | .value
	| (if $name == "slot" then slots_name_problem
	elif $name == "role" then slots_enum_problem(slots_roles)
	elif $name == "worktree" or $name == "repo" then slots_path_problem
	elif $name == "base" then slots_base_problem
	elif $name == "base-slot" then to_entries[] | .key as $index | .value | slots_name_problem | "item \($index) \(.)"
	elif $name == "lens" then slots_lens_problem
	elif $name == "agent-id" then slots_agent_problem
	elif $name == "dispatch" then slots_dispatch_problem
	elif $name == "status" then
		if . == "open" then "\"open\" is set by add and handover; expected one of \(slots_settable_statuses | slots_list)"
		else slots_enum_problem(slots_settable_statuses)
		end
	elif $name == "awaiting-round" then
		if . == "none" or test("^[1-9][0-9]{0,14}$") then empty
		else "\(tojson) is not allowed; expected none or a whole number of 1 or more"
		end
	else empty
	end)
	| "--\($name) \(.)";

def slots_result($exit; $problems; $file; $out): {exit: $exit, problems: $problems, file: $file, out: $out};
def slots_refused($exit; $problem): slots_result($exit; [$problem]; null; "");
def slots_unchanged: slots_result(0; []; null; "");
def slots_ordered: . as $slot | reduce (slots_field_order[] | select(. as $field | $slot | has($field))) as $field ({}; .[$field] = $slot[$field]);
def slots_changed: .slots |= map(slots_ordered) | slots_result(0; []; .; "");

def slots_index($name): [.slots | to_entries[] | select(.value.slot == $name) | .key] | first;

def slots_new($options):
	if $options.role == "reviewer" then
		{slot: $options.slot, role: "reviewer", lens: $options.lens, status: "open"}
	else
		{slot: $options.slot, role: $options.role, mode: slots_writer_modes[$options.role],
			worktree: $options.worktree, repo: $options.repo, base: $options.base, base_slots: $options["base-slot"],
			status: "open"}
	end;

def slots_add($options):
	if slots_index($options.slot) != null then slots_refused(5; "slot \($options.slot | tojson) already exists; expected a new slot name")
	else .slots += [slots_new($options)] | slots_changed
	end;

def slots_bind($options; $index):
	.slots[$index] as $slot
	| $options["agent-id"] as $agent
	| if $slot.agent_id == $agent and $slot.dispatch == $options.dispatch then slots_unchanged
	elif $slot.agent_id == $agent then
		slots_refused(5; "agent \($agent | tojson) holds slot \($slot.slot | tojson) under dispatch \($slot.dispatch | tojson); expected that dispatch again or a handover first")
	elif $slot.previous_agent_ids // [] | any(.[]; . == $agent) then
		slots_refused(5; "agent \($agent | tojson) was handed out of slot \($slot.slot | tojson); expected a fresh agent")
	elif $slot.status != "open" then
		slots_refused(5; "slot \($slot.slot | tojson) is held by agent \($slot.agent_id | tojson); expected an open slot")
	else .slots[$index] |= (.agent_id = $agent | .dispatch = $options.dispatch | .status = "working") | slots_changed
	end;

def slots_set_status($options; $index):
	.slots[$index] as $slot
	| if $slot.status == "open" then
		slots_refused(5; "slot \($slot.slot | tojson) is open; expected an agent bound before its status changes")
	elif ($options | has("awaiting-round")) and $slot.role == "reviewer" then
		slots_refused(3; "--awaiting-round is given for reviewer slot \($slot.slot | tojson); expected it only for a developer or tester")
	else
		.slots[$index] |= (.status = $options.status
			| if ($options | has("awaiting-round")) | not then .
			elif $options["awaiting-round"] == "none" then del(.awaiting_round)
			else .awaiting_round = ($options["awaiting-round"] | tonumber)
			end)
		| slots_changed
	end;

def slots_handover($index):
	.slots[$index] as $slot
	| if $slot.status == "open" then
		slots_refused(5; "slot \($slot.slot | tojson) is open; expected a bound slot to hand over")
	else .slots[$index] |= (.previous_agent_ids = (.previous_agent_ids // []) + [.agent_id] | del(.agent_id, .dispatch) | .status = "open") | slots_changed
	end;

# One "slot<TAB>status<TAB>awaiting_round" line per seat that is open,
# working, or awaits a round.
def slots_busy:
	[.slots[] | select(.status == "open" or .status == "working" or has("awaiting_round"))
		| "\(.slot)\t\(.status)\t\(.awaiting_round // "none")"] as $lines
	| slots_result(if $lines == [] then 0 else 8 end; []; null; $lines | join("\n"));

# The seat whose agent_id is the given agent; handed-out agents match none.
def slots_find($agent):
	[.slots[] | select(.agent_id == $agent)] as $seats
	| if $seats == [] then slots_refused(6; "no slot holds agent \($agent | tojson); expected an agent bound to a seat")
	elif ($seats | length) > 1 then
		slots_refused(5; "agent \($agent | tojson) holds slots \($seats | map(.slot) | slots_list); expected one seat")
	else slots_result(0; []; null; $seats[0] | tojson)
	end;

# Applies a command that names an existing slot.
def slots_on_slot($command; $options):
	slots_index($options.slot) as $index
	| if $index == null then
		slots_refused(6; "slot \($options.slot | tojson) is not in the file; expected one of \([.slots[].slot] | if . == [] then "no slot yet" else slots_list end)")
	elif $command == "bind" then slots_bind($options; $index)
	elif $command == "status" then slots_set_status($options; $index)
	elif $command == "handover" then slots_handover($index)
	else slots_result(0; []; null; .slots[$index] | tojson)
	end;

def slots_command($command; $options):
	if $command == "add" then slots_add($options)
	elif $command == "busy" then slots_busy
	elif $command == "find" then slots_find($options["agent-id"])
	else slots_on_slot($command; $options)
	end;

# A missing file: add starts it, busy finds nothing, the rest find no slot.
def slots_on_missing($command; $options; $effort):
	if $command == "add" then {effort: $effort, slots: []} | slots_add($options)
	elif $command == "busy" then slots_result(0; []; null; "")
	elif $command == "find" then slots_refused(6; "no slot holds agent \($options["agent-id"] | tojson); expected an existing file (it does not exist yet)")
	else slots_refused(6; "slot \($options.slot | tojson) is not in the file; expected an existing file (it does not exist yet)")
	end;

# $text is the file's raw text, or null when there is no file.
def slots_run($command; $options; $effort; $text):
	[$options | slots_option_problems] as $option_problems
	| if $option_problems != [] then slots_result(3; $option_problems; null; "")
	elif $text == null then slots_on_missing($command; $options; $effort)
	else
		[$text | try fromjson] as $parsed
		| if $parsed == [] then slots_refused(3; "the file is not valid JSON; expected the slots object, fixed by hand")
		else
			($parsed[0] | slots_problems) as $problems
			| if $problems != [] then slots_result(3; $problems | map("the file: \(.)"); null; "")
			else $parsed[0] | slots_command($command; $options)
			end
		end
	end;

# A change is written only when its result, pruned, fits the contract too.
def slots_checked:
	if .file == null then .
	else (.file | slots_problems) as $problems
		| if $problems == [] then . else slots_result(3; $problems | map("the change would leave \(.)"); null; "") end
	end;
