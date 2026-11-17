# An effort's states, the moves between them and the effort.* events that
# record them: the one definition effort.sh, its move guard and
# render-effort-state.sh read. A module: load it with jq -L <this folder> and
# include "effort-state-validator".

def effort_states: ["open", "paused", "completed", "dropped"];
# The states each state may change to; the move back to open is a reopen.
def effort_moves: {open: ["paused", "completed", "dropped"], paused: ["open", "completed", "dropped"], completed: ["open"], dropped: ["open"]};
# The state each effort.* event type records.
def effort_type_states: {"effort.opened": "open", "effort.reopened": "open", "effort.paused": "paused", "effort.completed": "completed", "effort.dropped": "dropped"};

def effort_is_state: type == "string" and (. as $state | effort_states | index([$state]) != null);
def effort_move_ok($from; $to): ($from | effort_is_state) and (effort_moves[$from] | index([$to]) != null);

# The effort's state after an array of events: the newest effort.* event's,
# "none" when there is none, which is no state, so every move but the first
# is refused.
def effort_state_of: [.[] | select(.type | startswith("effort."))] | if length == 0 then "none" else effort_type_states[.[-1].type] end;

# Why the move from $from to $to is refused, or nothing when it is allowed.
def effort_move_refusal($from; $to):
	{open: "reopen", paused: "pause", completed: "complete", dropped: "drop"} as $commands
	| if effort_move_ok($from; $to) then empty
	  elif $from == $to then "bad move: \($from) -> \($to); the effort is already \($to); try effort.sh state to confirm, and change nothing"
	  else "bad move: \($from) -> \($to); a \($from) effort can only move to \(effort_moves[$from] | map("\(.) (\($commands[.]))") | join(" or "))"
	  end;
