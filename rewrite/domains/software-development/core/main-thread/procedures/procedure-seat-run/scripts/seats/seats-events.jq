# An effort's seat list as events: each seat.* event is one seats.sh command,
# and the seat list is the replay of those commands' changes through seats.jq,
# so a change and its fold are one. A stored event was checked when written
# (seats.sh, then seats-guard.jq under the events lock); the replay applies it
# as written, so a rule tightened since never drops it. A module: load it
# with jq -L <this folder> and include "seats-events".
include "seats";

# The seats.sh command an event records: {command, options, dir}, dir the
# effort folder choose puts the worktrees folder in; null for another type.
# seat.status-changed and seat.handed-over are the earlier names of
# seat.status.changed and seat.reseated, still read so older efforts fold.
def seats_event_command:
	.type as $type | .body as $body
	| if $type == "seat.chosen" then
		{command: "choose", options: ({seat: $body.seat, role: $body.role, repo: $body.repo, base: $body.base}
			+ (if $body.base_seats then {"base-seat": $body.base_seats} else {} end)),
		 dir: ($body.worktree | sub("/worktrees/[^/]+$"; ""))}
	  elif $type == "seat.joined" then {command: "join", options: {seat: $body.seat, "build-seat": $body.build_seat}}
	  elif $type == "seat.opened" then {command: "opened", options: {seat: $body.seat}}
	  elif $type == "seat.dropped" then {command: "drop", options: {seat: $body.seat}}
	  elif $type == "seat.bound" then {command: "bind", options: {seat: $body.seat, "agent-id": $body.agent_id, dispatch: $body.dispatch}}
	  elif $type | IN("seat.status.changed", "seat.status-changed") then {command: "status", options: {seat: $body.seat, status: $body.status}}
	  elif $type | IN("seat.reseated", "seat.handed-over") then {command: "handover", options: {seat: $body.seat}}
	  elif $type == "seat.moved" then {command: "move", options: {seat: $body.seat, base: $body.base}}
	  elif $type == "seat.tasked" then {command: "task", options: {seat: $body.seat}}
	  else null
	  end;

# The seat list, or null when it has no seat, as seats.jq takes an effort
# with none.
def seats_or_null: if (.seats | length) == 0 then null else . end;

# The result of command $c on the seat list $file (null for no seat).
def seats_command_on($file; $c; $effort):
	if $file == null then seats_on_missing($c.command; $c.options; $effort; $c.dir // "")
	else $file | seats_command($c.command; $c.options; $c.dir // "")
	end;

# The seat list after stored event $c's change: a choose of a seat already
# listed, or any other command on a seat not listed, changes nothing, as no
# list holds a seat twice or a change to a seat it lacks. choose takes the
# worktree its event recorded; join takes its build seat's, as it is then,
# and a join whose build seat is not listed changes nothing.
def seats_replay($event; $c):
	seats_index($c.options.seat) as $index
	| if $c.command == "choose" then
		if $index != null then . else seats_choose_change($c.options; $event.body.worktree) end
	  elif $c.command == "join" then
		seats_index($c.options["build-seat"]) as $build_index
		| if $index != null or $build_index == null then . else seats_join_change($c.options; .seats[$build_index]) end
	  elif $index == null then .
	  else seats_seat_change($c.command; $c.options; $index)
	  end
	| .seats |= map(seats_ordered | with_entries(select(.value | seats_is_empty | not)));

# The events that record a seat's result: each sets the seat idle again (the
# work is recorded, so the agent is free).
def seats_result_types: ["build.committed", "test-plan.made", "test.committed"];

# The seat list after event $event: its change applied, or, for one of the
# seat's result events, the seat idle again.
def seats_apply($event):
	if $event.type | IN(seats_result_types[]) then
		seats_index($event.seat) as $index
		| if $index != null and (.seats[$index].status | IN("working", "gave-up")) then .seats[$index].status = "idle" else . end
	else
		($event | seats_event_command) as $c
		| if $c == null then . else seats_replay($event; $c) end
	end;

# The seat list of an array of events, oldest first.
def seats_fold($effort): reduce .[] as $event ({effort: $effort, seats: []}; seats_apply($event));

# The event body a seats.sh change writes, from the command, its options and
# the seat list before the change.
def seats_event_body($command; $options; $before; $after):
	([$before.seats[] | select(.seat == $options.seat)][0]) as $was
	| if $command == "choose" then
		# mode is kept for audit: the replay derives it from role.
		[$after.seats[] | select(.seat == $options.seat)][0] | {seat, role, mode, worktree, repo, base, base_seats}
		| with_entries(select(.value != null))
	# role, mode, worktree, repo and base are kept for audit: the replay takes
	# them from the build seat.
	elif $command == "join" then
		[$after.seats[] | select(.seat == $options.seat)][0] | {seat, role, mode, build_seat, worktree, repo, base}
	elif $command == "bind" then {seat: $options.seat, agent_id: $options["agent-id"], dispatch: $options.dispatch}
	elif $command == "status" then {seat: $options.seat, status: $options.status}
	# agent_id is kept for audit, naming the agent handed over from; the
	# replay does not read it.
	elif $command == "handover" then {seat: $options.seat, agent_id: $was.agent_id}
	# branch and base are kept for the record; the replay does not read them.
	elif $command == "opened" then {seat: $options.seat, branch: $options.branch, base: $was.base}
	# follows and from are kept for the record: the replay reads only seat and
	# base; from.head names the work the move left out of the branch.
	elif $command == "move" then
		{seat: $options.seat, base: $options.base, follows: $options.follows, from: {base: $was.base, head: $options["from-head"]}}
		| with_entries(select(.value != null))
	# agent_id and task are kept for audit, naming the agent given the work
	# and the work; the replay does not read them.
	elif $command == "task" then {seat: $options.seat, agent_id: $was.agent_id, task: $options.task}
	else {seat: $options.seat}
	end;

def seats_event_types: {choose: "seat.chosen", join: "seat.joined", opened: "seat.opened", drop: "seat.dropped", bind: "seat.bound", status: "seat.status.changed",
	handover: "seat.reseated", move: "seat.moved", task: "seat.tasked"};
