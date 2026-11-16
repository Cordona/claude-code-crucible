# The compact card of one builder report: its heading, task, counts, the
# gates that did not pass and where the report is. It keeps its own layout
# (a heading, dash bullets and icons on the gates), apart from human-view's
# layout rules, by the human's decision.
include "view";
include "title";

# A report value as one line: control characters and runs of spaces become
# one space.
def card_text: if type == "string" then . elif . == null then "" else tojson end
	| one_line | gsub(" +"; " ") | sub("^ "; "") | sub(" $"; "");
def card_items($key): .[$key] | if type == "array" then . else [] end;
def card_count($key): card_items($key) | length;
def card_dash_list: map("- " + .) | join("\n");

# The lines after the counts: one per fault, then the commit's git state.
def card_warning_lines($warnings):
	[($warnings.faults // [])[] | "⚠️ " + (. // "a fault" | tostring | one_line)]
	+ [$warnings.unsigned // false | select(.) | "⚠️ commit not signed"]
	+ [$warnings.not_pushed_to // null | strings | "⚠️ not pushed to \(.)"];

def card_count_lines($files):
	[card_count("security") | select(. > 0) | "⚠️ " + counted("security warning"; "security warnings")]
	+ [if $files == null then "no code change" else "\($files.total | counted("file"; "files")) changed, \($files.new) new" end]
	+ [card_count("blockers") | select(. > 0) | counted("blocker"; "blockers")]
	+ [card_count("deviations") | select(. > 0) | counted("deviation"; "deviations") + " to confirm"]
	+ [card_count("open") | select(. > 0) | counted("open item"; "open items")]
	+ [card_count("noticed") | select(. > 0) | "\(.) noticed outside the task"]
	+ [card_count("decisions") | select(. > 0) | counted("decision"; "decisions")];

# A gate that passed is left out; "" when every gate passed.
def card_gates:
	[card_items("verification")[] | objects | select(.result != "pass")
		| (.gate | card_text) as $gate
		| (.note | card_text) as $note
		| (if .result == "fail" then "❌ \($gate)" else "⚠️ \($gate), \(.result | card_text | gsub("_"; " "))" end)
		  + (if $note == "" then "" else ": \($note)" end)]
	| if . == [] then "" else "**Gates**\n" + card_dash_list end;

# Input: the parsed report. $labels: {language, frameworks} labels for title;
# $files: {total, new}, null for no commit; $commit: {seat, count ("build
# iteration 2"), short ("" for no commit), report_path, warnings: {faults
# (each fault's what), unsigned, not_pushed_to (the remote, or null)}}.
def card($labels; $files; $commit):
	(if card_count("blockers") > 0 then "blocked" else "done" end) as $state
	| ["### \($labels | seat_title("builder"; $commit.seat)) · \($commit.count) · \($state)",
	   "Task: \(.summary | card_text)",
	   (card_count_lines($files) + card_warning_lines($commit.warnings) | card_dash_list),
	   card_gates,
	   "**Builder report:** \(if $commit.short == "" then "" else "`\($commit.short)` in " end)\($commit.report_path | path_text)"]
	| blocks;

# Input: {report, labels, files, commit}, card's arguments beside the report.
def view: . as $card | .report | card($card.labels; $card.files; $card.commit);
