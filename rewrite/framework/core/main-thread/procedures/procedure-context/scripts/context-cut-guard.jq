# events.sh append's --guard for a context.cut event: run under the events
# lock, so a version number is taken once even though context.sh reads it
# before the lock. Input {events: [every event], event: the new one}; prints
# one refusal line when the new event's version is not the next one.
([(.events // [])[] | select(.type == "context.cut")] | length + 1) as $next
| if .event.type != "context.cut" or .event.body.version == $next then empty
  else "context.cut v\(.event.body.version) is not the next version (v\($next)); expected one cut per version number" end
