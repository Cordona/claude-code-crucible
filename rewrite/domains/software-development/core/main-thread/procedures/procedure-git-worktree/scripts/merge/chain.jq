# The seats a seat was cut from, read from slots.json. A module: load it
# with jq -L <this folder> and include "chain".
# ancestors($slot) follows base_slots through every level, breadth first,
# each seat once (a cycle ends the walk), and prints one
# {slot, via, worktree} per seat: via is the seat of $slot's own base_slots
# it was reached through, worktree "" when it has none. A $slot not in the
# file is an error.

def ancestors($slot):
	(.slots | map({key: .slot, value: .}) | from_entries) as $seats
	| if $seats[$slot] == null then error("no seat \($slot)") else . end
	| {queue: [$seats[$slot].base_slots // [] | .[] | {slot: ., via: .}], seen: [$slot], found: []}
	| until(.queue == [];
		.queue[0] as $next | .queue |= .[1:]
		| if any(.seen[]; . == $next.slot) then .
		else .seen += [$next.slot] | .found += [$next]
			| .queue += [$seats[$next.slot].base_slots // [] | .[] | {slot: ., via: $next.via}] end)
	| .found[] | .worktree = ($seats[.slot].worktree // "");
