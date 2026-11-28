# A plan challenge's rules, a jq module: load it with jq -L <the skills
# folder> and include "code-reviewer/scripts/lib/test-plan-challenge-report".
# Each challenge names a target that exists: an ID in the plan, plan, a code
# location or a path::helper in the tree, or a file the plan names. facts
# {plan: {ids, files}, files}, from reviewer-facts.sh. {} approves the plan.
include "code-reviewer/scripts/lib/reviewer-common";

def ch_asks: ["add", "change", "remove", "prove"];
def ch_id_pattern: "\\b[BTNC]-[0-9]+\\b";
def ch_says: {"target": "what it challenges", "ask": "add, change, remove or prove", "title": "the challenge, in one line", "why": "what the plan gets wrong"};

def ch_named($files): . as $path | any($files[]; . as $f | $path == $f or ($path | startswith(($f | rtrimstr("/")) + "/")));

def ch_rules:
	(.facts.plan.ids // []) as $ids
	| (.facts.plan.files // []) as $named
	| (.facts.files // []) as $files
	| (.report.challenges | if . == null or type == "array" then empty else "challenges must be a list" end),
	  (rc_entries("challenges") | .w as $w | .v
	   | if type != "object" then "\($w) must be an object"
	     else . as $c
		| ((($c | keys_unsorted) - ["target", "ask", "title", "why"])[] | "\($w) has unknown key \"\(.)\"; its keys are target, ask, title, why"),
		  ((["target", "ask", "title", "why"] - ($c | keys))[] | "\($w) needs \(.): \(ch_says[.])"),
		  (["target", "title", "why"][] as $k | $c | select(has($k)) | .[$k] | rc_text("\($w).\($k)")),
		  (if $c | has("ask") and ($c.ask | IN(ch_asks[]) | not) then "\($w).ask \($c.ask | tojson) is not \(rc_or(ch_asks))" else empty end),
		  (["title", "why"][] as $k | $c | select(has($k)) | .[$k] | strings | select(test(ch_id_pattern))
		   | "\($w).\($k) names \(capture("(?<id>" + ch_id_pattern + ")").id): say it in words, the target names the ID"),
		  (if ($c.target | type) != "string" then empty
		   else $c.target as $t
			| (($t | capture("^(?<file>[^:]+)(::.+|:[1-9][0-9]*(-[1-9][0-9]*)?)?$").file) // "") as $file
			| if $t == "plan" or ($t | IN($ids[])) or ($file | IN($files[])) or ($file | ch_named($named)) then empty
			  else "\($w).target \($t) is not an ID in the plan; name a plan ID, plan, a code location or a file the plan names" end
		   end)
	     end);

def challenge_report_problems: rc_top(["challenges", "noticed"]), ch_rules, rc_noticed, rc_tree;
