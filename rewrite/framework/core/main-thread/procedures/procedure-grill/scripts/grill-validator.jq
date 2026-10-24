# The grill file's shape, the one definition grill.sh checks every file
# against before it writes it and after it reads it. A module: load it with
# jq -L <this folder> and include "grill-validator".
# grill_file_problems reads the parsed file and prints one
# "<field> <problem>; expected <x>" line per problem, nothing when it fits;
# positions in a field, such as questions[0], are counted from 0.

# Characters (Unicode code points) each one-line text may hold: a round shows
# a question, its recommendation and its reason as three short lines, and an
# acknowledgement shows an answer and its change reason on one.
def grill_max_chars: {topic: 120, question: 120, recommendation: 80, reason: 120, answer: 100, change_reason: 120, status_reason: 100};
# A round holds what the human can answer in one reply.
def grill_round_max: 3;
def grill_statuses: ["open", "settled", "dropped", "deferred"];
# The answer text grill.sh writes when a question is dropped or deferred, before its reason.
def grill_status_prefix: {dropped: "Dropped: ", deferred: "Deferred: "};
def grill_id_pattern: "^q[1-9][0-9]*$";
def grill_utc_pattern: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$";
# Each object's fields, in the order the file holds them.
def grill_file_fields: ["topic", "ended", "questions"];
def grill_question_fields: ["id", "text", "parent", "round", "recommendation", "status", "answers"];
def grill_recommendation_fields: ["text", "reason"];
# An answer's at and change_reason are kept for audit: when and why the human
# changed an answer.
def grill_answer_fields: ["revision", "at", "change_reason", "text"];

# The object with the fields of $fields it holds, in that order.
def grill_ordered($fields): . as $object | reduce ($fields[] | select(. as $field | $object | has($field))) as $field ({}; .[$field] = $object[$field]);
def grill_id_number: .[1:] | tonumber;

# The problem of a one-line text of at most $max characters, or nothing.
def grill_text_problem($max):
	if type != "string" then "is a JSON \(type); expected a string"
	elif test("[[:cntrl:]]") then "holds a control character (such as a line break); expected one line"
	elif test("^[[:space:]]*$") then "is empty; expected text"
	elif length > $max then "is \(length) characters; expected at most \($max)"
	else empty end;

# Problems of the fields of object . at $where: unknown, missing (of
# $required), or out of the order $fields sets.
def grill_field_problems($where; $fields; $required):
	. as $object
	| ((keys_unsorted - $fields)[] | "\($where).\(tojson) is an unknown field; expected only \($fields | join(", "))"),
	  (($required - keys_unsorted)[] | "\($where).\(.) is missing; expected the fields \($required | join(", "))"),
	  (if (keys_unsorted - ($object | grill_ordered($fields) | keys_unsorted)) == [] and keys_unsorted != ($object | grill_ordered($fields) | keys_unsorted)
	   then "\($where) holds its fields out of order; expected the order \($fields | join(", "))" else empty end);

def grill_utc_problem($where):
	if type == "string" and test(grill_utc_pattern) then empty
	else "\($where) is \(tojson); expected a UTC time YYYY-MM-DDTHH:MM:SSZ" end;

def grill_answer_problems($where; $index):
	if type != "object" then "\($where) is a JSON \(type); expected an object"
	else grill_field_problems($where; grill_answer_fields; ["revision", "at", "text"]),
		(if .revision == $index + 1 then empty else "\($where).revision is \(.revision | tojson); expected \($index + 1): revisions count from 1 in order" end),
		(.at | grill_utc_problem("\($where).at")),
		(if has("change_reason") | not then empty
		 elif $index == 0 then "\($where).change_reason is set on revision 1; expected it only from revision 2"
		 else .change_reason | grill_text_problem(grill_max_chars.change_reason) | "\($where).change_reason \(.)" end),
		(.text as $text
		 | [grill_status_prefix[] | select(. as $prefix | ($text | type) == "string" and ($text | startswith($prefix)))] as $prefixes
		 | if ($prefixes | length) > 0 then $text[($prefixes[0] | length):] | grill_text_problem(grill_max_chars.status_reason) | "\($where).text's reason \(.)"
		   else $text | grill_text_problem(grill_max_chars.answer) | "\($where).text \(.)" end)
	end;

# The status rule of question . at $where: settled needs an answer; dropped
# and deferred end with the text grill.sh writes for them.
def grill_status_problems($where):
	grill_status_prefix as $prefixes
	| .status as $status
	| if ($status | type) != "string" or (grill_statuses | index([$status]) | not) then "\($where).status is \($status | tojson); expected one of \(grill_statuses | join(", "))"
	  elif (.answers | type) != "array" then empty
	  elif $status == "settled" and (.answers | length) == 0 then "\($where).status is settled with no answer; expected an answer"
	  elif $prefixes | has($status) | not then empty
	  elif ((.answers[-1].text // null) | type) == "string" and (.answers[-1].text | startswith($prefixes[$status])) then empty
	  else "\($where).status is \($status) but its last answer is not \($prefixes[$status] | tojson) and a reason; expected the answer grill.sh status writes" end;

def grill_question_problems($index):
	"questions[\($index)]" as $where
	| "q\($index + 1)" as $id
	| if type != "object" then "\($where) is a JSON \(type); expected an object"
	  else grill_field_problems($where; grill_question_fields; ["id", "text", "recommendation", "status", "answers"]),
		(if .id == $id then empty else "\($where).id is \(.id | tojson); expected \($id | tojson): ids run q1, q2, ... in file order, never reused" end),
		(if has("text") then .text | grill_text_problem(grill_max_chars.question) | "\($where).text \(.)" else empty end),
		(if has("parent") | not then empty
		 elif (.parent | type) == "string" and (.parent | test(grill_id_pattern)) and (.parent | grill_id_number) <= $index then empty
		 else "\($where).parent is \(.parent | tojson); expected the id of an earlier question" end),
		(if has("round") | not then empty
		 elif (.round | type) == "number" and .round == (.round | floor) and .round >= 1 then empty
		 else "\($where).round is \(.round | tojson); expected a whole number from 1" end),
		(if has("recommendation") | not then empty
		 elif (.recommendation | type) != "object" then "\($where).recommendation is a JSON \(.recommendation | type); expected {\"text\": ..., \"reason\": ...}"
		 else .recommendation
			| grill_field_problems("\($where).recommendation"; grill_recommendation_fields; grill_recommendation_fields),
			  (if has("text") then .text | grill_text_problem(grill_max_chars.recommendation) | "\($where).recommendation.text \(.)" else empty end),
			  (if has("reason") then .reason | grill_text_problem(grill_max_chars.reason) | "\($where).recommendation.reason \(.)" else empty end)
		 end),
		(if has("status") then grill_status_problems($where) else empty end),
		(if has("answers") | not then empty
		 elif (.answers | type) != "array" then "\($where).answers is a JSON \(.answers | type); expected an array ([] for none)"
		 else .answers | to_entries[] | .key as $answer | .value | grill_answer_problems("\($where).answers[\($answer)]"; $answer) end)
	  end;

def grill_file_problems:
	if type != "object" then "the file is a JSON \(type); expected an object"
	else grill_field_problems("the file"; grill_file_fields; ["topic", "questions"]),
		(if has("topic") then .topic | grill_text_problem(grill_max_chars.topic) | "topic \(.)" else empty end),
		(if has("ended") then .ended | grill_utc_problem("ended") else empty end),
		(if has("questions") | not then empty
		 elif (.questions | type) != "array" then "questions is a JSON \(.questions | type); expected an array ([] for none)"
		 else .questions | to_entries[] | .key as $index | .value | grill_question_problems($index) end)
	end;
