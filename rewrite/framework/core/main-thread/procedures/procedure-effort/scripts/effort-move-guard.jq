# events.sh's --guard for an effort.* event: refuses a move the effort's
# current state does not allow, read under the events lock, so two moves
# never race. Input: {events, event}; prints one refusal line, or nothing.
include "effort-state-validator";

(.events | effort_state_of) as $now
| .event as $event
| if $event.type == "effort.opened" then empty
  elif $now == "none" then "bad move: the effort has no effort.* event, so no state; expected its first event, events/000001-effort.opened.json, to be effort.opened; try another effort, or start a new one"
  elif $event.body.from != $now then "bad move: the effort is \($now) now, not \($event.body.from); another call changed it; rerun"
  else effort_move_refusal($now; effort_type_states[$event.type])
  end
