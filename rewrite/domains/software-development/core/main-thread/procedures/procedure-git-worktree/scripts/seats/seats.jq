# The effort's seat list, replayed from its seat.* events: each seat (like
# build-agent-alpha) a place whose agent is replaceable. A module: load it
# with jq -L <this folder> and include "seats".
# seats_problems checks a seat list and prints a list of
# "<where> <problem>; expected <x>" lines, empty when it fits the contract.
# seats_run checks the options, checks the list and applies one command;
# seats_checked refuses a changed list that no longer fits, so the shell
# never edits JSON. A key with nothing in it is left out, never null, [] or {}.
# seats_next_name gives the next free seat name of a role.

def seats_top_fields: ["effort", "seats"];
def seats_roles: ["developer"];
def seats_modes: {"developer": "BUILD"};
# The name a role's seats start with, before "-<letter>".
def seats_prefixes: {"developer": "build-agent"};
# The letter ending every seat name, in the order seat-name.sh hands them out;
# after omega the round goes on as alpha-2 ... omega-2, then alpha-3, with no limit.
def seats_letters: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda",
	"mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega"];
def seats_word_pattern: "[a-z][a-z0-9]*(-[a-z][a-z0-9]*)*";
# A letter and, from the second round on, "-<round>".
def seats_letter_pattern: "(\(seats_letters | join("|")))(-[2-9]|-[1-9][0-9]+)?";
# \A and \z, not ^ and $: jq's $ also matches before a final newline.
def seats_name_pattern: "\\A\(seats_word_pattern)-\(seats_letter_pattern)\\z";
def seats_statuses: ["chosen", "open", "working", "idle", "gave-up"];
# chosen is only ever set by choose; open only by opened (seat-open.sh, once
# the chosen seat's worktree exists) and handover, each with no agent.
def seats_settable_statuses: ["working", "idle", "gave-up"];
def seats_unbound_statuses: ["chosen", "open"];
# A seat's fields, in the order they are written.
def seats_fields: ["seat", "role", "mode", "agent_id", "dispatch", "previous_agent_ids", "worktree", "repo", "base", "base_seats", "status"];
# Present only when they hold something; status decides whether agent_id and
# dispatch must be.
def seats_optional_fields: ["agent_id", "dispatch", "previous_agent_ids", "base_seats"];
# The bound agent's keys: they come and go together.
def seats_agent_fields: ["agent_id", "dispatch"];

def seats_list: join(", ");
def seats_is_empty: . == null or . == [] or . == {};

def seats_pattern_problem($pattern; $what):
	if type != "string" then "is a JSON \(type); expected \($what)"
	elif test($pattern) | not then "\(tojson) is not allowed; expected \($what)"
	else empty
	end;

def seats_name_problem: seats_pattern_problem(seats_name_pattern;
	"a seat name like build-agent-alpha: lowercase words joined by dashes, ending in one of \(seats_letters[0]), \(seats_letters[1]) ... \(seats_letters[-1]), from the second round with -2, -3 ...");
def seats_agent_problem: seats_pattern_problem("^[A-Za-z0-9_-]+$"; "an agent id of letters, digits, _ and -");
def seats_dispatch_problem: seats_pattern_problem("^[A-Za-z0-9_-]+$"; "a dispatch id of letters, digits, _ and -");
def seats_base_problem: seats_pattern_problem("^[0-9a-f]{40}$"; "a 40-character lowercase hex commit sha");

def seats_path_problem:
	if type != "string" then "is a JSON \(type); expected an absolute path"
	elif test("[[:cntrl:]]") then "holds a control character; expected a plain absolute path"
	elif startswith("/") | not then "\(tojson) is not absolute; expected an absolute path"
	else empty
	end;

def seats_enum_problem($values):
	if type == "string" and IN($values[]) then empty
	else "\(tojson) is not allowed; expected one of \($values | seats_list)"
	end;

def seats_previous_problem:
	if type != "array" then "is a JSON \(type); expected an array of agent ids, oldest first"
	else
		(to_entries[] | .key as $index | .value | seats_agent_problem | "item \($index) \(.)"),
		(map(strings) | group_by(.) | map(select(length > 1) | .[0])[] | "holds \(tojson) more than once; expected each agent once")
	end;

def seats_base_seats_problem:
	if type != "array" then "is a JSON \(type); expected an array of the seats the seat was cut from"
	else
		(to_entries[] | .key as $index | .value | seats_name_problem | "item \($index) \(.)"),
		(map(strings) | group_by(.) | map(select(length > 1) | .[0])[] | "holds \(tojson) more than once; expected each seat once")
	end;

# Each base seat of each seat must name another seat of the list that is not
# chosen: a chosen seat has no work to be cut from.
def seats_base_link_problems:
	(reduce (.seats[] | objects | select(.seat | type == "string")) as $seat ({}; .[$seat.seat] = $seat.status)) as $statuses
	| .seats | to_entries[] | .key as $index | .value
	| select(type == "object" and (.base_seats | type) == "array") | .seat as $own
	| .base_seats[] | strings | select([seats_name_problem] == [])
	| "seats[\($index)].base_seats \(tojson) "
		+ (if . == $own then "is the seat itself; expected another seat"
		elif (. as $name | $statuses | has($name) | not) then "is not in the seat list; expected an existing seat"
		elif $statuses[.] == "chosen" then "is a chosen seat; expected a seat with a worktree: a chosen seat has no work yet"
		else empty
		end);

# The seats $from reaches through the base_seats links $links, each once.
def seats_base_reach($links; $from):
	{queue: ($links[$from] // []), seen: []}
	| until(.queue == [];
		.queue[0] as $next | .queue |= .[1:]
		| if any(.seen[]; . == $next) then . else .seen += [$next] | .queue += ($links[$next] // []) end)
	| .seen;

# A seat may not be cut, through any number of base_seats, from itself;
# each cycle is named once, by its seats in order. A seat naming itself is
# seats_base_link_problems' to report.
def seats_base_cycle_problems:
	(reduce (.seats[] | objects | select((.seat | type) == "string" and (.base_seats | type) == "array")) as $seat ({};
		.[$seat.seat] = [$seat.base_seats[] | strings | select(. != $seat.seat)])) as $links
	| ($links | keys[]) as $name
	| seats_base_reach($links; $name) as $reach
	| select(any($reach[]; . == $name))
	| ([$name] + [$reach[] | . as $other | select(any(seats_base_reach($links; $other)[]; . == $name))] | unique) as $cycle
	| select($cycle[0] == $name)
	| "base_seats of \($cycle | seats_list) form a cycle; expected no seat cut from itself through other seats";

# The problems of the values of a seat whose role is valid; $fields are its
# role's. An empty value is reported once, by seats_empty_problems.
def seats_value_problems($where; $fields):
	. as $seat
	| to_entries[] | select((.key | IN($fields[])) and (.value | seats_is_empty | not)) | .key as $field | .value
	| (if $field == "seat" then seats_name_problem
	elif $field == "mode" then
		seats_modes[$seat.role] as $mode
		| if . == $mode then empty else "\(tojson) is not allowed; expected \($mode) for a \($seat.role)" end
	elif $field == "agent_id" then seats_agent_problem
	elif $field == "dispatch" then seats_dispatch_problem
	elif $field == "previous_agent_ids" then seats_previous_problem
	elif $field == "worktree" or $field == "repo" then seats_path_problem
	elif $field == "base" then seats_base_problem
	elif $field == "base_seats" then seats_base_seats_problem
	elif $field == "status" then seats_enum_problem(seats_statuses)
	else empty
	end)
	| "\($where).\($field) \(.)";

# A chosen or open seat has no agent and no dispatch; every other status has
# both. A chosen seat never had an agent.
def seats_pairing_problems($where):
	. as $seat
	| if (.status | IN(seats_statuses[]) | not) then empty
	else
		(seats_agent_fields[] as $field
			| if ($seat.status | IN(seats_unbound_statuses[])) and ($seat | has($field)) then
				"\($where).\($field) is given on a \($seat.status) seat; expected no \($field) while \($seat.status)"
			elif ($seat.status | IN(seats_unbound_statuses[]) | not) and ($seat | has($field) | not) then
				"\($where).\($field) is missing; expected one while \($seat.status)"
			else empty
			end),
		(if $seat.status == "chosen" and ($seat | has("previous_agent_ids")) then
			"\($where).previous_agent_ids is given on a chosen seat; expected none: a chosen seat never had an agent"
		else empty
		end)
	end;

def seats_seat_problems($where):
	if type != "object" then "\($where) is a JSON \(type); expected a seat object"
	elif has("role") | not then "\($where).role is missing; expected one of \(seats_roles | seats_list)"
	elif (.role | type) != "string" or (.role | IN(seats_roles[]) | not) then "\($where).role \(.role | seats_enum_problem(seats_roles))"
	else
		. as $seat
		| seats_fields as $fields
		| (keys_unsorted[] | select(IN($fields[]) | not)
			| "\($where) field \(tojson) is not a field of a \($seat.role); expected only \($fields | seats_list)"),
		($fields[] | select(IN(seats_optional_fields[]) | not) | select(. as $field | $seat | has($field) | not)
			| "\($where).\(.) is missing; expected it for a \($seat.role)"),
		seats_value_problems($where; $fields),
		seats_pairing_problems($where)
	end;

# Every null, [] or {} anywhere in the seat list, by its path.
def seats_empty_problems:
	paths(seats_is_empty) as $path
	| "\($path | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | ltrimstr(".")) is \(getpath($path) | tojson); expected the key left out when empty";

def seats_problems:
	if type != "object" then ["the seat list is a JSON \(type); expected an object of effort and seats"]
	else [
		seats_empty_problems,
		(keys_unsorted[] | select(IN(seats_top_fields[]) | not) | "field \(tojson) is not a field; expected only \(seats_top_fields | seats_list)"),
		(if has("effort") | not then "effort is missing; expected the effort id"
		elif (.effort | type) != "string" or .effort == "" then "effort \(.effort | tojson) is not allowed; expected a non-empty string"
		else empty
		end),
		(if has("seats") | not then "seats is missing; expected an array of seats"
		elif (.seats | type) != "array" then "seats is a JSON \(.seats | type); expected an array of seats"
		else
			(.seats | to_entries[] | .key as $index | .value | seats_seat_problems("seats[\($index)]")),
			seats_base_link_problems,
			seats_base_cycle_problems,
			([.seats[] | objects | .seat | strings] | group_by(.) | map(select(length > 1) | .[0])[]
				| "seat \(tojson) appears more than once; expected unique seat names")
		end)
	]
	end;

# The problems of the given options ({name: value}, an absent option left out).
def seats_option_problems:
	to_entries[] | .key as $name | .value
	| (if $name == "seat" then seats_name_problem
	elif $name == "role" then seats_enum_problem(seats_roles)
	elif $name == "repo" then seats_path_problem
	elif $name == "base" then seats_base_problem
	elif $name == "base-seat" then to_entries[] | .key as $index | .value | seats_name_problem | "item \($index) \(.)"
	elif $name == "agent-id" then seats_agent_problem
	elif $name == "dispatch" then seats_dispatch_problem
	elif $name == "status" then
		if . == "chosen" then "\"chosen\" is set by choose; expected one of \(seats_settable_statuses | seats_list)"
		elif . == "open" then "\"open\" is set by opened and handover; expected one of \(seats_settable_statuses | seats_list)"
		else seats_enum_problem(seats_settable_statuses)
		end
	else empty
	end)
	| "--\($name) \(.)";

def seats_result($exit; $problems; $file; $out): {exit: $exit, problems: $problems, file: $file, out: $out};
def seats_refused($exit; $problem): seats_result($exit; [$problem]; null; "");
def seats_unchanged: seats_result(0; []; null; "");
def seats_ordered: . as $seat | reduce (seats_fields[] | select(. as $field | $seat | has($field))) as $field ({}; .[$field] = $seat[$field]);
def seats_changed: .seats |= map(seats_ordered) | seats_result(0; []; .; "");

def seats_index($name): [.seats | to_entries[] | select(.value.seat == $name) | .key] | first;

def seats_taken($name): "seat \($name | tojson) already exists; expected a new seat name";

# The seat's letter: its name after "<prefix>-", like alpha or alpha-2.
def seats_letter($options): $options.seat | ltrimstr("\(seats_prefixes[$options.role])-");

# The problem of a --seat whose name does not fit its role, or nothing.
def seats_prefix_problem($options):
	if seats_letter($options) | test("\\A\(seats_letter_pattern)\\z") then empty
	else "--seat \($options.seat | tojson) does not fit --role \($options.role); expected \(seats_prefixes[$options.role])-<letter>, as seat-name.sh names it"
	end;

# A seat whose worktree is not made yet: <$worktrees_dir>/<letter> is where
# seat-open.sh makes it, so its letter names the worktree alone.
def seats_choose($options; $worktrees_dir):
	if [seats_prefix_problem($options)] != [] then seats_refused(3; seats_prefix_problem($options))
	elif seats_index($options.seat) != null then seats_refused(5; seats_taken($options.seat))
	else
		.seats += [{seat: $options.seat, role: $options.role, mode: seats_modes[$options.role],
			worktree: "\($worktrees_dir)/\(seats_letter($options))", repo: $options.repo, base: $options.base, base_seats: $options["base-seat"],
			status: "chosen"}]
		| seats_changed
	end;

def seats_not_chosen($seat): seats_refused(5; "seat \($seat.seat | tojson) is \($seat.status); expected a chosen seat");

# Dropping the last seat appends its event and leaves the replayed list
# empty, the list of an effort with no seat.
def seats_drop($index):
	.seats[$index] as $seat
	| if $seat.status != "chosen" then seats_not_chosen($seat)
	elif (.seats | length) == 1 then seats_unchanged + {remove: true}
	else del(.seats[$index]) | seats_changed
	end;

def seats_opened($index):
	.seats[$index] as $seat
	| if $seat.status != "chosen" then seats_not_chosen($seat)
	else .seats[$index].status = "open" | seats_changed
	end;

def seats_bind($options; $index):
	.seats[$index] as $seat
	| $options["agent-id"] as $agent
	| if $seat.status == "chosen" then
		seats_refused(5; "seat \($seat.seat | tojson) is chosen: its worktree is not made yet; expected an open seat (seat-open.sh opens it)")
	elif $seat.agent_id == $agent and $seat.dispatch == $options.dispatch then seats_unchanged
	elif $seat.agent_id == $agent then
		seats_refused(5; "agent \($agent | tojson) holds seat \($seat.seat | tojson) under dispatch \($seat.dispatch | tojson); expected that dispatch again or a handover first")
	elif $seat.previous_agent_ids // [] | any(.[]; . == $agent) then
		seats_refused(5; "agent \($agent | tojson) was handed out of seat \($seat.seat | tojson); expected a fresh agent")
	elif $seat.status != "open" then
		seats_refused(5; "seat \($seat.seat | tojson) is held by agent \($seat.agent_id | tojson); expected an open seat")
	else .seats[$index] |= (.agent_id = $agent | .dispatch = $options.dispatch | .status = "working") | seats_changed
	end;

def seats_set_status($options; $index):
	.seats[$index] as $seat
	| if $seat.status | IN(seats_unbound_statuses[]) then
		seats_refused(5; "seat \($seat.seat | tojson) is \($seat.status); expected an agent bound before its status changes")
	else .seats[$index].status = $options.status | seats_changed
	end;

def seats_handover($index):
	.seats[$index] as $seat
	| if $seat.status | IN(seats_unbound_statuses[]) then
		seats_refused(5; "seat \($seat.seat | tojson) is \($seat.status); expected a bound seat to hand over")
	else .seats[$index] |= (.previous_agent_ids = (.previous_agent_ids // []) + [.agent_id] | del(.agent_id, .dispatch) | .status = "open") | seats_changed
	end;

# One "seat<TAB>status" line per seat with open work: working or gave-up.
def seats_busy:
	[.seats[] | select(.status == "working" or .status == "gave-up") | "\(.seat)\t\(.status)"] as $lines
	| seats_result(if $lines == [] then 0 else 8 end; []; null; $lines | join("\n"));

# The seat whose agent_id is the given agent; handed-out agents match none.
def seats_find($agent):
	[.seats[] | select(.agent_id == $agent)] as $seats
	| if $seats == [] then seats_refused(6; "no seat holds agent \($agent | tojson); expected an agent bound to a seat")
	elif ($seats | length) > 1 then
		seats_refused(5; "agent \($agent | tojson) holds seats \($seats | map(.seat) | seats_list); expected one seat")
	else seats_result(0; []; null; $seats[0] | tojson)
	end;

# Applies a command that names an existing seat.
def seats_on_seat($command; $options):
	seats_index($options.seat) as $index
	| if $index == null then
		seats_refused(6; "seat \($options.seat | tojson) is not in the seat list; expected one of \([.seats[].seat] | if . == [] then "no seat yet" else seats_list end)")
	elif $command == "bind" then seats_bind($options; $index)
	elif $command == "status" then seats_set_status($options; $index)
	elif $command == "handover" then seats_handover($index)
	elif $command == "drop" then seats_drop($index)
	elif $command == "opened" then seats_opened($index)
	else seats_result(0; []; null; .seats[$index] | tojson)
	end;

# $seats_dir is the effort folder, symlinks resolved, which holds worktrees/.
def seats_command($command; $options; $seats_dir):
	if $command == "choose" then seats_choose($options; "\($seats_dir | rtrimstr("/"))/worktrees")
	elif $command == "busy" then seats_busy
	elif $command == "find" then seats_find($options["agent-id"])
	else seats_on_seat($command; $options)
	end;

# An effort with no seat yet: choose starts the list, busy finds nothing, the
# rest find no seat.
def seats_on_missing($command; $options; $effort; $seats_dir):
	if $command == "choose" then {effort: $effort, seats: []} | seats_command($command; $options; $seats_dir)
	elif $command == "busy" then seats_result(0; []; null; "")
	elif $command == "find" then seats_refused(6; "no seat holds agent \($options["agent-id"] | tojson); expected an agent bound to a seat (the effort has none yet)")
	else seats_refused(6; "seat \($options.seat | tojson) is not in the seat list; expected a seat of the effort (it has none yet)")
	end;

# Checks the seat list $list, then applies apply to it; exit 3 when it is no
# valid seat list.
def seats_on_list($list; apply):
	($list | seats_problems) as $problems
	| if $problems != [] then seats_result(3; $problems | map("the seat list: \(.)"); null; "")
	else $list | apply
	end;

# $list is the seat list, or null when the effort has no seat.
def seats_run($command; $options; $effort; $seats_dir; $list):
	[$options | seats_option_problems] as $option_problems
	| if $option_problems != [] then seats_result(3; $option_problems; null; "")
	elif $list == null then seats_on_missing($command; $options; $effort; $seats_dir)
	else seats_on_list($list; seats_command($command; $options; $seats_dir))
	end;

# A change is written only when its result, pruned, fits the contract too.
def seats_checked:
	if .file == null then .
	else (.file | seats_problems) as $problems
		| if $problems == [] then . else seats_result(3; $problems | map("the change would leave \(.)"); null; "") end
	end;

# The next free name for $prefix: the first "<prefix>-<letter>" no seat of
# the list uses, round by round; a round past the last taken one is all free,
# so the search ends.
def seats_next_name($prefix):
	[.seats[].seat] as $taken
	| first(range(1; ($taken | length) + 2) as $round
		| seats_letters[] | "\($prefix)-\(.)\(if $round == 1 then "" else "-\($round)" end)"
		| select(IN($taken[]) | not))
	| seats_result(0; []; null; .);

# The next free name of $role in the seat list $list, null when the effort
# has no seat; the role is checked first.
def seats_name_run($role; $list):
	if $role | IN(seats_roles[]) | not then seats_refused(3; "--role \($role | seats_enum_problem(seats_roles))")
	elif $list == null then {seats: []} | seats_next_name(seats_prefixes[$role])
	else seats_on_list($list; seats_next_name(seats_prefixes[$role]))
	end;
