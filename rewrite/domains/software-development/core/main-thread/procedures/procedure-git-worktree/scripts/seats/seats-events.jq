# An effort's seat list as events: each seat.* event is one seats.sh command,
# and the seat list is the replay of those commands through seats.jq, so the
# rules that refuse a change and the rules that fold it are one. A module:
# load it with jq -L <this folder> and include "seats-events".
include "seats";

# The seats.sh command an event records: {command, options, dir}, dir the
# effort folder choose puts the worktrees folder in; null for another type.
def seats_event_command:
	.type as $type | .body as $body
	| if $type == "seat.chosen" then
		{command: "choose", options: ({seat: $body.seat, role: $body.role, repo: $body.repo, base: $body.base}
			+ (if $body.base_seats then {"base-seat": $body.base_seats} else {} end)),
		 dir: ($body.worktree | sub("/worktrees/[^/]+$"; ""))}
	  elif $type == "seat.opened" then {command: "opened", options: {seat: $body.seat}}
	  elif $type == "seat.dropped" then {command: "drop", options: {seat: $body.seat}}
	  elif $type == "seat.bound" then {command: "bind", options: {seat: $body.seat, "agent-id": $body.agent_id, dispatch: $body.dispatch}}
	  elif $type == "seat.status-changed" then {command: "status", options: {seat: $body.seat, status: $body.status}}
	  elif $type == "seat.handed-over" then {command: "handover", options: {seat: $body.seat}}
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

# The seat list after event $event: its command applied, or, for the seat's
# build.committed, the seat idle again (the work is recorded, so the agent is
# free).
def seats_apply($event; $effort):
	if $event.type == "build.committed" then
		seats_index($event.seat) as $index
		| if $index != null and (.seats[$index].status | IN("working", "gave-up")) then .seats[$index].status = "idle" else . end
	else
		($event | seats_event_command) as $c
		| if $c == null then .
		  else seats_command_on(seats_or_null; $c; $effort) as $result
			| if $result.exit != 0 then .
			  elif $result.remove == true then .seats = []
			  elif $result.file == null then .
			  else $result.file | .seats |= map(with_entries(select(.value | seats_is_empty | not)))
			  end
		  end
	end;

# The seat list of an array of events, oldest first.
def seats_fold($effort): reduce .[] as $event ({effort: $effort, seats: []}; seats_apply($event; $effort));

# The event body a seats.sh change writes, from the command, its options and
# the seat list before the change.
def seats_event_body($command; $options; $before; $after):
	if $command == "choose" then
		# mode is kept for audit: the replay derives it from role.
		[$after.seats[] | select(.seat == $options.seat)][0] | {seat, role, mode, worktree, repo, base, base_seats}
		| with_entries(select(.value != null))
	elif $command == "bind" then {seat: $options.seat, agent_id: $options["agent-id"], dispatch: $options.dispatch}
	elif $command == "status" then {seat: $options.seat, status: $options.status}
	# agent_id is kept for audit, naming the agent handed over from; the
	# replay does not read it.
	elif $command == "handover" then {seat: $options.seat, agent_id: ([$before.seats[] | select(.seat == $options.seat)][0].agent_id)}
	else {seat: $options.seat}
	end;

def seats_event_types: {choose: "seat.chosen", opened: "seat.opened", drop: "seat.dropped", bind: "seat.bound", status: "seat.status-changed", handover: "seat.handed-over"};
