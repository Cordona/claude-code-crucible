# The tokens an effort's sessions spent: a table per session and agent, its
# notes and where the figures are.
include "view";

def tenths($unit): (. / $unit * 10 + 0.5 | floor) as $tenths | "\($tenths / 10 | floor).\($tenths % 10)";
def millions: if . >= 999950000 then "\(tenths(1000000000))B" else "\(tenths(1000000))M" end;
def thousands: if . >= 999950 then millions else "\(tenths(1000))k" end;
def rounded: if . >= 999500 then millions elif . >= 1000 then "\(. / 1000 + 0.5 | floor)k" else thousands end;
def sums: reduce .[] as $entry ({input: 0, output: 0, cache_read: 0, cache_write: 0};
	.input += $entry.input | .output += $entry.output | .cache_read += $entry.cache_read | .cache_write += $entry.cache_write);
def cells: "\(.input | thousands) | \(.output | thousands) | \(.cache_read | rounded) | \(.cache_write | rounded)";
def bold_cells: "**\(.input | thousands)** | **\(.output | thousands)** | **\(.cache_read | rounded)** | **\(.cache_write | rounded)**";
def marks: (if .running then " (running)" else "" end) + (if .unreliable then " (unreliable)" else "" end);
def harvest_time: "\(.[0:10]) \(.[11:16]) UTC";
# A file read back is checked for shape only, so an agent name in it may
# predate the name rule; no character of it may break the table.
def cell_text: shown | gsub("[|`]"; "?");
# The rows of session $session with a figure above zero; the first names the
# session.
def session_rows($session):
	. as $file
	| [{who: "main thread", unreliable: any($file.main_thread[]; .unreliable), sum: ($file.main_thread | sums)}]
	+ [$file.subagents | group_by(.agent)[]
		| {who: (.[0].agent | cell_text), running: any(.[]; .running), unreliable: any(.[]; .unreliable), sum: sums}]
	| map(select(.sum | [.input, .output, .cache_read, .cache_write] | any(. > 0)))
	| to_entries
	| map((if .key == 0 then "| `\($session[0:8])`\(if $file.expired then " (expired)" else "" end) |" else "| |" end) as $session
		| .value | "\($session) \(.who)\(marks) | \(.sum | cells) |");
def table($rows; $mine):
	if ($rows | length) == 0 then "No session figures for this effort yet."
	else ["| Session | Who | Fresh input | Output | Cached reads | Cache writes |",
		"|---|---|---:|---:|---:|---:|"]
		+ $rows
		+ ["| **Total** | | \($mine | sums | bold_cells) |"]
		| join("\n")
	end;

# view
#   input:  {name: the effort's NAME, harvested_at: the harvest's UTC time,
#           expired_unseen: [ids of sessions expired before any harvest],
#           figures: [{path: a metrics.harvested event, session: the session
#           it counts, body: its body}]}
#   output: the title, the table, the Notes and the Data section
def view:
	. as $card
	| ($card.figures | sort_by(.session)) as $read
	| [$read[].body] as $files
	| [$files[] | .main_thread[], .subagents[]] as $mine
	| [$files[] | .outside[]] as $outside
	| [$read[] | .session as $session | .body | session_rows($session)[]] as $rows
	# Effort names are at most 40 characters and a whole effort folder name 61,
	# so 80 passes every folder effort.sh makes and keeps the first line short.
	| (if $card.name | test("\\A[A-Za-z0-9._-]{1,80}\\z") then $card.name else "effort" end) as $shown_name
	| [status_line("done"; "Token use · `\($shown_name)`"),
	   table($rows; $mine),
	   section("Note"; "Notes"; [
		"Harvested \($card.harvested_at | harvest_time).",
		(if ($outside | length) > 0 then ($outside | sums) as $sum
			| "Outside this effort, same sessions\(if any($outside[]; .unreliable) then " (unreliable)" else "" end): \($sum.input | thousands) input, \($sum.output | thousands) output, \($sum.cache_read | rounded) cached reads, \($sum.cache_write | rounded) cache writes.",
			  "Split by effort from the tool calls that name its folder; calls before the first one count as outside." else empty end),
		(if any($mine[]; .running) then "(running): still running at harvest; the next ask completes it." else empty end),
		(if any($mine[], $outside[]; .unreliable) then "(unreliable): some output figures are placeholders Claude Code left unfinished; output counts low there." else empty end),
		($read[] | select(.body.expired) | "`\(.session[0:8])` (expired): transcript gone; figures from its harvest of \(.body.harvested_at | harvest_time)."),
		(if ($card.expired_unseen | length) > 0 then "Expired before any harvest, no figures: \($card.expired_unseen | map("`\(.[0:8])`") | join(", "))." else empty end)
		] | map(plain_line)),
	   data_section([$read[] | ["Metrics", .path]])]
	| blocks;
