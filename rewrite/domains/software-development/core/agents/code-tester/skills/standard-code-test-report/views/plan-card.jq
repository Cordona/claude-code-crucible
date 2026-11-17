# The compact card of one test plan draft: its heading, what it blocks on
# or why no test is needed, the failing tests it repairs, what will be
# guarded, the test changes counted, what needs the human's answer and where
# the plan is. Every item is named in words, never by its plan id. It keeps
# the build card's own layout (a heading and dash bullets), apart from
# human-view's layout rules.
include "view";
include "title";

# A plan value as one line: control characters and runs of spaces become
# one space.
def plan_text: if type == "string" then . elif . == null then "" else tojson end
	| one_line | gsub(" +"; " ") | sub("^ "; "") | sub(" $"; "");
def plan_items($key): .[$key] | if type == "array" then map(objects) else [] end;
def plan_dash_list: map("- " + .) | join("\n");
# "" for no items, else **<name>** and its dash list.
def plan_block($name; $items): if $items == [] then "" else "**\($name)**\n" + ($items | plan_dash_list) end;
# Kind words, as "request unclear" for request_unclear.
def plan_words: plan_text | gsub("_"; " ");

def plan_blocker:
	.blocker | if type == "object" then "**Blocker:** \(.kind | plan_words): \(.detail | plan_text)" else "" end;

def plan_no_tests:
	.no_tests | if type == "string" and (plan_text != "") then "**No tests needed:** \(plan_text)" else "" end;

# A failing baseline with no blocker: the plan repairs as many tests as its
# modify and remove entries name.
def plan_repair:
	if (.blocker | type) != "object" and (.baseline | type) == "object" and .baseline.result == "fail" then
		"**Existing tests:** fail; this plan repairs \(plan_items("modify") + plan_items("remove") | length)"
	else "" end;

def plan_behaviours: plan_block("Will be tested after this:"; [plan_items("behaviours")[] | .text | plan_text]);

# The add line names its new tests and its new rows apart when rows are added.
def plan_add_line:
	plan_items("add") as $add
	| ($add | map(select(.kind == "new_rows")) | length) as $rows
	| ($add | length - $rows) as $tests
	| select(($add | length) > 0)
	| "\($add | length | counted("test"; "tests")) to add"
	+ (if $rows == 0 then ""
		else " (" + ([($tests | select(. > 0) | counted("new test"; "new tests")),
			(if $rows == 1 then "1 existing test gets new rows" else "\($rows) existing tests get new rows" end)] | join(", ")) + ")"
		end);

def plan_changes:
	plan_block("Changes to the tests:"; [plan_add_line,
		(plan_items("modify") | length | select(. > 0) | "\(counted("test"; "tests")) to modify"),
		(plan_items("remove") | length | select(. > 0) | "\(counted("test"; "tests")) to remove")]);

def plan_recommended: if . == "waive" then "leave it untested" else "test it" end;

def plan_answers:
	plan_block("Needs your answer:"; [plan_items("untested")[]
		| "\(.case | plan_text) would stay untested\(.category | plan_text | if . == "" then "" else " (\(.))" end). Recommended: \(.recommend | plan_recommended)"]);

# Input: the parsed plan. $labels: {language, frameworks} labels for title;
# $card: {seat, draft (its number), plan_path (the plan event's path)}.
def plan_card($labels; $card):
	["### \($labels | seat_title("test agent"; $card.seat)) · test plan · draft \($card.draft)",
	 plan_blocker,
	 plan_no_tests,
	 plan_repair,
	 plan_behaviours,
	 plan_changes,
	 plan_answers,
	 "**Test plan:** \($card.plan_path | path_text)"]
	| blocks;

# Input: {plan, labels, card}, plan_card's arguments beside the plan.
def view: . as $data | .plan | plan_card($data.labels; $data.card);
