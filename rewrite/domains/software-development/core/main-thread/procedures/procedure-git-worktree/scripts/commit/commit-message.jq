# The Crucible commit message: each kind's count and trailers, the checks on
# the input and the subject. A module: load it with
# jq -L <this folder> and include "commit-message".
# commit_problems reads the parsed input and prints a list of
# "<field> <problem>; expected <x>" lines, empty when it fits; commit_message
# builds the message of an input that fits.

# Each kind: its count trailer and its other trailers in the order the
# message lists them after the count; every trailer is required.
def commit_kinds: {
	"build": {count: "iteration", trailers: ["effort", "agent-seat"]}
};
def commit_count_trailers: ["iteration"];
def commit_fields: ["kind", "text", "trailers"];
# Characters (Unicode code points): 72 keeps the subject whole in git's one-line views.
def commit_subject_max: 72;
def commit_trailer_max: 200;
# The largest count a JSON number holds exactly.
def commit_count_max: 9007199254740991;

def commit_subject_prefix($kind): "crucible(\($kind)): ";
def commit_kind_trailers($rule): [$rule.count] + $rule.trailers;
def commit_trim: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
def commit_list: if length == 0 then "none" else join(", ") end;

# The problem of a one-line text of at most $max characters, or nothing.
def commit_line_problem($max):
	if type != "string" then "is a JSON \(type); expected a string"
	elif test("[\n\r  ]") then "holds a line break; expected one line"
	elif test("[[:cntrl:]]") then "holds a control character; expected printable text"
	elif (commit_trim | length) == 0 then "is empty; expected text"
	elif (commit_trim | length) > $max then "has \(commit_trim | length) characters; expected at most \($max)"
	else empty
	end;

def commit_count_problem:
	if type != "number" then "is a JSON \(type); expected a whole number of 1 or more"
	elif . != floor or . < 1 or . > commit_count_max then "\(.) is not allowed; expected a whole number of 1 or more"
	else empty
	end;

# The problem of a text whose subject, kind $kind's prefix and the text,
# passes commit_subject_max; nothing when the kind is not known.
def commit_subject_problem($kind; $rule):
	if $rule == null or (.text | type) != "string" then empty
	else (commit_subject_prefix($kind) + (.text | commit_trim)) as $subject
		| ($subject | length) as $length
		| if $length <= commit_subject_max then empty
		else "text makes the subject \($length) characters; expected at most \(commit_subject_max), so a text of at most \(commit_subject_max - (commit_subject_prefix($kind) | length)) for kind \($kind | tojson)"
		end
	end;

def commit_trailer_value_problems($key; $name):
	if IN($key; commit_count_trailers[]) then commit_count_problem | "\($name) \(.)"
	else commit_line_problem(commit_trailer_max) | "\($name) \(.)"
	end;

def commit_trailer_problems($kind; $rule):
	(if has("trailers") then .trailers else {} end) as $trailers
	| if ($trailers | type) != "object" then "trailers is a JSON \($trailers | type); expected an object of trailers"
	else
		($trailers | to_entries[] | .key as $key | .value
			| commit_trailer_value_problems($key; "trailers[\($key | @json)]")),
		($rule // empty
			| commit_kind_trailers($rule) as $allowed
			| ($trailers | keys_unsorted[] | select(IN($allowed[]) | not)
				| "trailers[\(@json)] is not a trailer of kind \($kind); expected \($allowed | commit_list)"),
			($allowed[] | select(. as $key | $trailers | has($key) | not)
				| "trailers[\(@json)] is missing; expected it for kind \($kind)"))
	end;

def commit_problems:
	if type != "object" then ["the input is a JSON \(type); expected an object of kind, text and trailers"]
	else
		(if (.kind | type) == "string" then commit_kinds[.kind] else null end) as $rule
		| (.kind | tojson) as $kind
		| [
			(keys_unsorted[] | select(IN(commit_fields[]) | not) | "\(@json) is not a field; expected only \(commit_fields | commit_list)"),
			(if has("kind") | not then "kind is missing; expected one of \(commit_kinds | keys_unsorted | commit_list)"
			elif $rule == null then "kind \($kind) is not known; expected one of \(commit_kinds | keys_unsorted | commit_list)"
			else empty
			end),
			(if has("text") | not then "text is missing; expected the subject's text"
			else (.text | commit_line_problem(commit_trailer_max) | "text \(.)") // commit_subject_problem(.kind; $rule)
			end),
			commit_trailer_problems($kind; $rule)
		]
	end;

# agent-seat -> Agent-Seat.
def commit_trailer_key: split("-") | map((.[:1] | ascii_upcase) + .[1:]) | join("-");

def commit_trailer_text:
	if type == "number" then floor | tostring else commit_trim end;

def commit_message:
	commit_kinds[.kind] as $rule
	| .trailers as $trailers
	| commit_subject_prefix(.kind) + (.text | commit_trim) + "\n\n"
	+ (commit_kind_trailers($rule) | map(select(. as $key | $trailers | has($key)) | "\(commit_trailer_key): \($trailers[.] | commit_trailer_text)\n") | join(""));
