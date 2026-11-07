# The effort's seat list, seats.json: each seat (software-developer-alpha,
# security-reviewer-alpha) a place whose agent is replaceable. A module: load
# it with jq -L <this folder> and include "seats".
# seats_problems checks a parsed file and prints a list of
# "<where> <problem>; expected <x>" lines, empty when it fits the contract.
# seats_run checks the options, checks the file and applies one command;
# seats_checked refuses a changed file that no longer fits, so the shell
# never edits JSON. A key with nothing in it is left out, never null, [] or {}.
# seats_next_name gives the next free seat name of a role.

def seats_top_fields: ["effort", "seats"];
def seats_roles: ["developer", "tester", "reviewer"];
def seats_writer_modes: {"developer": "BUILD", "tester": "TEST"};
# The name a writer role's seats start with; a reviewer's is "<lens>-reviewer".
def seats_writer_prefixes: {"developer": "software-developer", "tester": "software-tester"};
# The last word of every seat name, in the order seat-name.sh hands them out.
def seats_letters: ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota", "kappa", "lambda",
	"mu", "nu", "xi", "omicron", "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi", "omega"];
def seats_word_pattern: "[a-z][a-z0-9]*(-[a-z][a-z0-9]*)*";
# \A and \z, not ^ and $: jq's $ also matches before a final newline.
def seats_name_pattern: "\\A\(seats_word_pattern)-(\(seats_letters | join("|")))\\z";
def seats_statuses: ["chosen", "open", "working", "idle", "gave-up"];
# chosen is only ever set by choose, on a writer seat; open only by opened
# (seat-open.sh, once the chosen seat's worktree exists), add (a reviewer)
# and handover, each with no agent.
def seats_settable_statuses: ["working", "idle", "gave-up"];
def seats_unbound_statuses: ["chosen", "open"];
def seats_writer_fields: ["seat", "role", "mode", "agent_id", "dispatch", "previous_agent_ids", "worktree", "repo", "base", "base_seats", "awaiting_round", "status"];
def seats_reviewer_fields: ["seat", "role", "lens", "agent_id", "dispatch", "previous_agent_ids", "status"];
# Present only when they hold something; status decides whether agent_id and
# dispatch must be.
def seats_optional_fields: ["agent_id", "dispatch", "previous_agent_ids", "base_seats", "awaiting_round"];
# The bound agent's keys: they come and go together.
def seats_agent_fields: ["agent_id", "dispatch"];
# The order a seat's fields are written in.
def seats_field_order: ["seat", "role", "mode", "lens", "agent_id", "dispatch", "previous_agent_ids", "worktree", "repo", "base", "base_seats", "awaiting_round", "status"];
# The largest round a JSON number holds exactly.
def seats_round_max: 9007199254740991;

def seats_list: join(", ");
def seats_role_fields: if . == "reviewer" then seats_reviewer_fields else seats_writer_fields end;
def seats_is_empty: . == null or . == [] or . == {};

def seats_pattern_problem($pattern; $what):
	if type != "string" then "is a JSON \(type); expected \($what)"
	elif test($pattern) | not then "\(tojson) is not allowed; expected \($what)"
	else empty
	end;

def seats_name_problem: seats_pattern_problem(seats_name_pattern;
	"a seat name like software-developer-alpha: lowercase words joined by dashes, the last one of \(seats_letters[0]), \(seats_letters[1]) ... \(seats_letters[-1])");
# A lens of this shape always makes a valid "<lens>-reviewer-<letter>" name.
def seats_lens_problem: seats_pattern_problem("\\A\(seats_word_pattern)\\z"; "a lens name of lowercase words joined by dashes, like security");
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

def seats_round_problem:
	if type != "number" then "is a JSON \(type); expected a whole number of 1 or more"
	elif . != floor or . < 1 or . > seats_round_max then "\(.) is not allowed; expected a whole number of 1 or more"
	else empty
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

# Each base seat of each seat must name another developer seat of the file
# that is not chosen: a chosen seat has no work to be cut from.
def seats_base_link_problems:
	(reduce (.seats[] | objects | select(.seat | type == "string")) as $seat ({}; .[$seat.seat] = $seat.role)) as $roles
	| (reduce (.seats[] | objects | select(.seat | type == "string")) as $seat ({}; .[$seat.seat] = $seat.status)) as $statuses
	| .seats | to_entries[] | .key as $index | .value
	| select(type == "object" and (.base_seats | type) == "array") | .seat as $own
	| .base_seats[] | strings | select([seats_name_problem] == [])
	| "seats[\($index)].base_seats \(tojson) "
		+ (if . == $own then "is the seat itself; expected another seat"
		elif $roles[.] == null then "is not in the file; expected an existing seat"
		elif $roles[.] != "developer" then "is a \($roles[.]) seat; expected a developer seat"
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
		seats_writer_modes[$seat.role] as $mode
		| if . == $mode then empty else "\(tojson) is not allowed; expected \($mode) for a \($seat.role)" end
	elif $field == "lens" then seats_lens_problem
	elif $field == "agent_id" then seats_agent_problem
	elif $field == "dispatch" then seats_dispatch_problem
	elif $field == "previous_agent_ids" then seats_previous_problem
	elif $field == "worktree" or $field == "repo" then seats_path_problem
	elif $field == "base" then seats_base_problem
	elif $field == "base_seats" then seats_base_seats_problem
	elif $field == "awaiting_round" then seats_round_problem
	elif $field == "status" then seats_enum_problem(seats_statuses)
	else empty
	end)
	| "\($where).\($field) \(.)";

# A chosen or open seat has no agent and no dispatch; every other status has
# both. A chosen seat is a writer's and never had an agent.
def seats_pairing_problems($where):
	. as $seat
	| if (.status | IN(seats_statuses[]) | not) then empty
	elif .status == "chosen" and .role == "reviewer" then
		"\($where).status \"chosen\" is given on a reviewer seat; expected open or later: only a writer seat is chosen"
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
		| (.role | seats_role_fields) as $fields
		| (keys_unsorted[] | select(IN($fields[]) | not)
			| "\($where) field \(tojson) is not a field of a \($seat.role); expected only \($fields | seats_list)"),
		($fields[] | select(IN(seats_optional_fields[]) | not) | select(. as $field | $seat | has($field) | not)
			| "\($where).\(.) is missing; expected it for a \($seat.role)"),
		seats_value_problems($where; $fields),
		seats_pairing_problems($where)
	end;

# Every null, [] or {} anywhere in the file, by its path.
def seats_empty_problems:
	paths(seats_is_empty) as $path
	| "\($path | map(if type == "number" then "[\(.)]" else ".\(.)" end) | join("") | ltrimstr(".")) is \(getpath($path) | tojson); expected the key left out when empty";

def seats_problems:
	if type != "object" then ["the file is a JSON \(type); expected an object of effort and seats"]
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
	elif $name == "lens" then seats_lens_problem
	elif $name == "agent-id" then seats_agent_problem
	elif $name == "dispatch" then seats_dispatch_problem
	elif $name == "status" then
		if . == "chosen" then "\"chosen\" is set by choose; expected one of \(seats_settable_statuses | seats_list)"
		elif . == "open" then "\"open\" is set by opened, add and handover; expected one of \(seats_settable_statuses | seats_list)"
		else seats_enum_problem(seats_settable_statuses)
		end
	elif $name == "awaiting-round" then
		if . == "none" or test("^[1-9][0-9]{0,14}$") then empty
		else "\(tojson) is not allowed; expected none or a whole number of 1 or more"
		end
	else empty
	end)
	| "--\($name) \(.)";

def seats_result($exit; $problems; $file; $out): {exit: $exit, problems: $problems, file: $file, out: $out};
def seats_refused($exit; $problem): seats_result($exit; [$problem]; null; "");
def seats_unchanged: seats_result(0; []; null; "");
def seats_ordered: . as $seat | reduce (seats_field_order[] | select(. as $field | $seat | has($field))) as $field ({}; .[$field] = $seat[$field]);
def seats_changed: .seats |= map(seats_ordered) | seats_result(0; []; .; "");

def seats_index($name): [.seats | to_entries[] | select(.value.seat == $name) | .key] | first;

def seats_taken($name): "seat \($name | tojson) already exists; expected a new seat name";

# The name a role's seats start with, before "-<letter>".
def seats_prefix($role; $lens): if $role == "reviewer" then "\($lens)-reviewer" else seats_writer_prefixes[$role] end;

# The problem of a --seat whose name does not fit its role, or nothing.
def seats_prefix_problem($options):
	seats_prefix($options.role; $options.lens) as $prefix
	| if $options.seat | ltrimstr("\($prefix)-") | IN(seats_letters[]) then empty
	else "--seat \($options.seat | tojson) does not fit --role \($options.role)\(if $options.role == "reviewer" then " --lens \($options.lens)" else "" end); expected \($prefix)-<letter>, as seat-name.sh names it"
	end;

# A reviewer seat: open from the start, since it has no worktree to open.
def seats_add($options):
	if $options.role != "reviewer" then
		seats_refused(3; "--role \($options.role) is not added; expected reviewer: a writer seat is chosen with choose and opened by seat-open.sh")
	elif [seats_prefix_problem($options)] != [] then seats_refused(3; seats_prefix_problem($options))
	elif seats_index($options.seat) != null then seats_refused(5; seats_taken($options.seat))
	else .seats += [{seat: $options.seat, role: "reviewer", lens: $options.lens, status: "open"}] | seats_changed
	end;

# A writer seat whose worktree is not made yet: $worktree is where
# seat-open.sh makes it.
def seats_choose($options; $worktree):
	if $options.role == "reviewer" then
		seats_refused(3; "--role reviewer is not chosen; expected developer: a reviewer seat is added with add")
	elif $options.role == "tester" then
		seats_refused(3; "--role tester is not yet supported: a tester shares a developer's worktree, which seat-open.sh does not open yet; expected developer")
	elif [seats_prefix_problem($options)] != [] then seats_refused(3; seats_prefix_problem($options))
	elif seats_index($options.seat) != null then seats_refused(5; seats_taken($options.seat))
	else
		.seats += [{seat: $options.seat, role: $options.role, mode: seats_writer_modes[$options.role],
			worktree: $worktree, repo: $options.repo, base: $options.base, base_seats: $options["base-seat"],
			status: "chosen"}]
		| seats_changed
	end;

def seats_not_chosen($seat): seats_refused(5; "seat \($seat.seat | tojson) is \($seat.status); expected a chosen seat");

# Dropping the last seat removes the file: a seat list is never empty, and
# no file already means no seat.
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
	elif ($options | has("awaiting-round")) and $seat.role == "reviewer" then
		seats_refused(3; "--awaiting-round is given for reviewer seat \($seat.seat | tojson); expected it only for a developer or tester")
	else
		.seats[$index] |= (.status = $options.status
			| if ($options | has("awaiting-round")) | not then .
			elif $options["awaiting-round"] == "none" then del(.awaiting_round)
			else .awaiting_round = ($options["awaiting-round"] | tonumber)
			end)
		| seats_changed
	end;

def seats_handover($index):
	.seats[$index] as $seat
	| if $seat.status | IN(seats_unbound_statuses[]) then
		seats_refused(5; "seat \($seat.seat | tojson) is \($seat.status); expected a bound seat to hand over")
	else .seats[$index] |= (.previous_agent_ids = (.previous_agent_ids // []) + [.agent_id] | del(.agent_id, .dispatch) | .status = "open") | seats_changed
	end;

# One "seat<TAB>status<TAB>awaiting_round" line per seat that is open,
# working, or awaits a round; a chosen seat is none of these.
def seats_busy:
	[.seats[] | select(.status == "open" or .status == "working" or has("awaiting_round"))
		| "\(.seat)\t\(.status)\t\(.awaiting_round // "none")"] as $lines
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
		seats_refused(6; "seat \($options.seat | tojson) is not in the file; expected one of \([.seats[].seat] | if . == [] then "no seat yet" else seats_list end)")
	elif $command == "bind" then seats_bind($options; $index)
	elif $command == "status" then seats_set_status($options; $index)
	elif $command == "handover" then seats_handover($index)
	elif $command == "drop" then seats_drop($index)
	elif $command == "opened" then seats_opened($index)
	else seats_result(0; []; null; .seats[$index] | tojson)
	end;

# $seats_dir is the folder of seats.json, which holds the worktrees folder.
def seats_command($command; $options; $seats_dir):
	if $command == "add" then seats_add($options)
	elif $command == "choose" then seats_choose($options; "\($seats_dir | rtrimstr("/"))/worktrees/\($options.seat)")
	elif $command == "busy" then seats_busy
	elif $command == "find" then seats_find($options["agent-id"])
	else seats_on_seat($command; $options)
	end;

# A missing file: add and choose start it, busy finds nothing, the rest find
# no seat.
def seats_on_missing($command; $options; $effort; $seats_dir):
	if $command == "add" or $command == "choose" then {effort: $effort, seats: []} | seats_command($command; $options; $seats_dir)
	elif $command == "busy" then seats_result(0; []; null; "")
	elif $command == "find" then seats_refused(6; "no seat holds agent \($options["agent-id"] | tojson); expected an existing file (it does not exist yet)")
	else seats_refused(6; "seat \($options.seat | tojson) is not in the file; expected an existing file (it does not exist yet)")
	end;

# Parses and checks $text, the file's raw text, then applies apply to it;
# exit 3 when it is no valid seat list.
def seats_parsed($text; apply):
	[$text | try fromjson] as $parsed
	| if $parsed == [] then seats_refused(3; "the file is not valid JSON; expected the seats object, fixed by hand")
	else
		($parsed[0] | seats_problems) as $problems
		| if $problems != [] then seats_result(3; $problems | map("the file: \(.)"); null; "")
		else $parsed[0] | apply
		end
	end;

# $text is the file's raw text, or null when there is no file.
def seats_run($command; $options; $effort; $seats_dir; $text):
	[$options | seats_option_problems] as $option_problems
	| if $option_problems != [] then seats_result(3; $option_problems; null; "")
	elif $text == null then seats_on_missing($command; $options; $effort; $seats_dir)
	else seats_parsed($text; seats_command($command; $options; $seats_dir))
	end;

# A change is written only when its result, pruned, fits the contract too.
def seats_checked:
	if .file == null then .
	else (.file | seats_problems) as $problems
		| if $problems == [] then . else seats_result(3; $problems | map("the change would leave \(.)"); null; "") end
	end;

# The next free name for $prefix: the first letter no seat of the file uses
# after "<prefix>-"; exit 3 once all of them are used.
def seats_next_name($prefix):
	[.seats[].seat] as $taken
	| [seats_letters[] | "\($prefix)-\(.)" | select(IN($taken[]) | not)] as $free
	| if $free == [] then
		seats_refused(3; "every seat name from \($prefix)-alpha to \($prefix)-\(seats_letters[-1]) is taken; expected at most \(seats_letters | length) seats named \($prefix)-<letter> in an effort")
	else seats_result(0; []; null; $free[0])
	end;

# The next free name of $role (and $lens for a reviewer) in $text, the file's
# raw text or null when there is no file; the options are checked first.
def seats_name_run($role; $lens; $text):
	seats_prefix($role; $lens) as $prefix
	| if $role | IN(seats_roles[]) | not then seats_refused(3; "--role \($role | seats_enum_problem(seats_roles))")
	elif $role == "reviewer" and ([$lens | seats_lens_problem] != []) then
		seats_refused(3; "--lens \($lens | seats_lens_problem)")
	elif $text == null then {seats: []} | seats_next_name($prefix)
	else seats_parsed($text; seats_next_name($prefix))
	end;
