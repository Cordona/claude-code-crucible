# events.sh's --guard for a seat.* event: replays the seat list under the
# events lock and refuses the event when its command no longer applies, so
# two changes to one seat never race. Input: {events, event}; prints one
# refusal line, or nothing.
include "seats-events";

(.events | seats_fold("guard")) as $now
| .event as $event
| ($event | seats_event_command) as $c
| if $c == null then empty
  else seats_command_on($now | seats_or_null; $c; "guard") as $result
	| if $result.exit != 0 then $result.problems[0]
	  elif $result.file == null and ($result.remove != true) then "seat \($event.body.seat) already holds this change; another call made it"
	  else empty
	  end
  end
