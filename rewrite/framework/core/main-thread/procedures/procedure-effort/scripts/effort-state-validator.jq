# The state item's shape and the moves between states: the one definition
# effort.sh checks every item against before it writes it and after it reads
# it, and render-effort-state.sh checks every item it reads. A module: load it
# with jq -L <this folder> and include "effort-state-validator".
# effort_state_item_problems reads the parsed item and prints one
# "<field> <problem>; expected <x>" line per problem, nothing when it fits.

def effort_states: ["open", "paused", "completed", "dropped"];
# The states each state may change to; the move back to open is a reopen.
def effort_moves: {open: ["paused", "completed", "dropped"], paused: ["open", "completed", "dropped"], completed: ["open"], dropped: ["open"]};
def effort_item_fields: ["state", "from", "at", "session"];
def effort_required_fields: ["state", "at"];
def effort_utc_pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$";
def effort_session_pattern: "^[0-9a-f-]+$";

def effort_is_state: type == "string" and (. as $state | effort_states | index([$state]) != null);
def effort_move_ok($from; $to): ($from | effort_is_state) and (effort_moves[$from] | index([$to]) != null);

# A value from the item quoted as JSON and cut, so a problem stays one short line.
def effort_shown: tojson | if length > 60 then .[:60] + "…" else . end;

def effort_state_problem($field):
	if effort_is_state then empty
	else "\($field) is \(effort_shown); expected one of \(effort_states | join(", "))" end;

# The move rule: an item with from records a move effort_moves allows; the
# only item without from is the first, which effort.sh start writes open.
def effort_move_problem:
	if (.state | effort_is_state) | not then empty
	elif has("from") | not then
		if .state == "open" then empty
		else "from is missing on a \(.state) item; expected from on every item but the first, which is open" end
	elif (.from | effort_is_state) | not then empty
	elif effort_move_ok(.from; .state) then empty
	else "from \(.from) to state \(.state) is not a move; expected from \(.from) to \(effort_moves[.from] | join(" or "))" end;

def effort_session_problem:
	if type == "string" and test(effort_session_pattern) then empty
	else "session is \(effort_shown); expected a non-empty string of 0-9, a-f and -; leave the key out for none" end;

def effort_state_item_problems:
	if type != "object" then "the item is a JSON \(type); expected an object"
	else ((keys_unsorted - effort_item_fields)[] | "\(effort_shown) is an unknown field; expected only \(effort_item_fields | join(", "))"),
		((effort_required_fields - keys_unsorted)[] | "\(.) is missing; expected the fields \(effort_required_fields | join(" and ")), from on every item but the first"),
		(if has("state") then .state | effort_state_problem("state") else empty end),
		(if has("from") then .from | effort_state_problem("from") else empty end),
		(if has("state") then effort_move_problem else empty end),
		(if has("at") | not then empty
		 elif (.at | type) == "string" and (.at | test(effort_utc_pattern)) then empty
		 else "at is \(.at | effort_shown); expected a UTC time YYYY-MM-DDTHH:MM:SSZ" end),
		(if has("session") then .session | effort_session_problem else empty end)
	end;
