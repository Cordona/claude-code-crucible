# The compact card of one developer commit: its heading, task, counts, the
# gates that did not pass and where the report is. A module: load it with
# jq -L <this folder> and -L human-view's folder, and include "card"; it
# includes human-view's view and title modules. The card keeps its own layout
# (a heading, dash bullets and icons on the gates), apart from human-view's
# layout rules, by the human's decision.
include "view";
include "title";

# A report value as one line: control characters become spaces.
def card_text: if type == "string" then . elif . == null then "" else tojson end
	| gsub("[[:cntrl:]\u0085  ]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
def card_items($key): .[$key] | if type == "array" then . else [] end;
def card_count($key): card_items($key) | length;
def card_counted($count; $one; $many): "\($count) \(if $count == 1 then $one else $many end)";
def card_dash_list: map("- " + .) | join("\n");

def card_count_lines($files):
	(card_items("answers") | map(objects | .status)) as $statuses
	| [card_count("security") | select(. > 0) | "⚠️ " + card_counted(.; "security warning"; "security warnings")]
	+ ["\(card_counted($files.total; "file"; "files")) changed, \($files.new) new"]
	+ (if $statuses == [] then [] else
		["\(card_counted($statuses | length; "concern"; "concerns")) answered: \([$statuses[] | select(. == "fixed")] | length) fixed, \([$statuses[] | select(. == "blocked")] | length) blocked"]
	  end)
	+ [card_count("blockers") | select(. > 0) | card_counted(.; "blocker"; "blockers")]
	+ [card_count("deviations") | select(. > 0) | card_counted(.; "deviation"; "deviations") + " to confirm"]
	+ [card_count("open") | select(. > 0) | card_counted(.; "open item"; "open items")]
	+ [card_count("noticed") | select(. > 0) | "\(.) noticed outside the task"]
	+ [card_count("decisions") | select(. > 0) | card_counted(.; "decision"; "decisions")];

# A gate that passed is left out; "" when every gate passed.
def card_gates:
	[card_items("verification")[] | objects | select(.result != "pass")
		| (.gate | card_text) as $gate
		| (.note | card_text) as $note
		| (if .result == "fail" then "❌ \($gate)" else "⚠️ \($gate), \(.result | card_text | gsub("_"; " "))" end)
		  + (if $note == "" then "" else ": \($note)" end)]
	| if . == [] then "" else "**Gates**\n" + card_dash_list end;

# Input: the parsed report. $labels: {language, frameworks} labels for title;
# $files: {total, new}; $commit: {seat, count ("build iteration 2"), short,
# report_path}.
def card($labels; $files; $commit):
	(if card_count("blockers") > 0 then "blocked" else "done" end) as $state
	| ["### \($labels | seat_title("developer"; $commit.seat)) · \($commit.count) · \($state)",
	   "Task: \(.summary | card_text)",
	   (card_count_lines($files) | card_dash_list),
	   card_gates,
	   "**Developer report:** `\($commit.short)` in \($commit.report_path | path_text)"]
	| blocks;
