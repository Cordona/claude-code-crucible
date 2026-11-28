# The grill's shape, in one home: an open grill's draft and an ended grill's
# grill.ended body. grill_problems prints one plain line per problem, nothing
# when the grill fits.
def one_line: type == "string" and test("\\S") and (test("[\\r\\n]") | not);
def grill_statuses: ["open", "settled", "dropped", "deferred"];

def question_problems($i; $earlier):
	"questions[\($i)]" as $at
	| if type != "object" then "\($at) must be an object"
	  else
		((keys - ["id", "parent", "text", "recommendation", "status", "answers"])[] | "\($at).\(.) is not a question field"),
		(if (.id | type) == "string" and (.id | test("^q[1-9][0-9]*$")) then empty else "\($at).id must be q<N>" end),
		(.id as $id | if ($earlier | index([$id])) then "\($at).id \($id) is used twice" else empty end),
		(if has("parent") and ((.parent as $p | $earlier | index([$p])) | not) then "\($at).parent must be an earlier question's id" else empty end),
		(if .text | one_line then empty else "\($at).text must be one line" end),
		(if (.recommendation | type) == "object" and (.recommendation.text | one_line) and (.recommendation.reason | one_line)
		   and ((.recommendation | keys) == ["reason", "text"]) then empty
		 else "\($at).recommendation must be {text, reason}, each one line" end),
		(.status as $s | if (grill_statuses | index([$s])) then empty else "\($at).status must be one of \(grill_statuses | join(", "))" end),
		(if (.answers | type) == "array" then
			(.answers | to_entries[] | .key as $j | .value
				| if type == "object" and (.text | one_line) and ((keys - ["text", "change_reason"]) == [])
				     and ((has("change_reason") | not) or (.change_reason | one_line)) then empty
				  else "\($at).answers[\($j)] must be {text, change_reason?}, each one line" end)
		 else "\($at).answers must be an array" end),
		(if .status == "settled" and ((.answers | length) == 0) then "\($at) is settled with no answer" else empty end)
	  end;

def grill_problems:
	if type != "object" then "the grill must be an object"
	else
		((keys - ["number", "topic", "questions"])[] | "\(.) is not a grill field"),
		(if (.number | type) == "number" and .number >= 1 and (.number | floor) == .number then empty else "number must be a whole number from 1" end),
		(if .topic | one_line then empty else "topic must be one line" end),
		(if (.questions | type) == "array" then
			(.questions as $q | range(0; $q | length) as $i
				| $q[$i] | question_problems($i; [$q[:$i][] | .id?]))
		 else "questions must be an array" end)
	end;
