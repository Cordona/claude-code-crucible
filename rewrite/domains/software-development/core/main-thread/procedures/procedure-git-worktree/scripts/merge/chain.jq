# The seats a seat was cut from, read from seats.json. A module: load it
# with jq -L <this folder> and include "chain".
# ancestors($seat) follows base_seats through every level, breadth first,
# each seat once (a cycle ends the walk), and prints one
# {seat, via, worktree} per seat: via is the seat of $seat's own base_seats
# it was reached through, worktree "" when it has none. A $seat not in the
# file is an error.

def ancestors($seat):
	(.seats | map({key: .seat, value: .}) | from_entries) as $seats
	| if $seats[$seat] == null then error("no seat \($seat)") else . end
	| {queue: [$seats[$seat].base_seats // [] | .[] | {seat: ., via: .}], seen: [$seat], found: []}
	| until(.queue == [];
		.queue[0] as $next | .queue |= .[1:]
		| if any(.seen[]; . == $next.seat) then .
		else .seen += [$next.seat] | .found += [$next]
			| .queue += [$seats[$next.seat].base_seats // [] | .[] | {seat: ., via: $next.via}] end)
	| .found[] | .worktree = ($seats[.seat].worktree // "");
