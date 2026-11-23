# The Crucible commit message, a jq module: load it with jq -L <this folder>
# and include "commit-message". commit_problems lists what is wrong with a
# parsed input, empty when it fits; commit_message builds the message of an
# input that fits; commit_is_snapshot tells a snapshot's subject.

def commit_fields: ["kind", "text", "trailers"];
# Characters (Unicode code points): 72 keeps the subject whole in git's one-line views.
def commit_subject_max: 72;
def commit_trailer_max: 200;
def commit_kind_rule: "^[a-z][a-z0-9]*(-[a-z0-9]+)*$";
def commit_key_rule: "^[a-z][a-z0-9]*(-[a-z0-9]+)*$";

def commit_subject_prefix($kind): "crucible(\($kind)): ";
# A snapshot, a commit of a checkout's uncommitted work, is made with this kind.
def commit_snapshot_kind: "snapshot";
def commit_is_snapshot: startswith(commit_subject_prefix(commit_snapshot_kind));
def commit_trim: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");

# The problem of a one-line text of at most $max characters, or nothing.
def commit_line_problem($max):
	if type != "string" then "is a JSON \(type); expected a string"
	elif test("[\n\r  ]") then "holds a line break; expected one line"
	elif test("[[:cntrl:]]") then "holds a control character; expected printable text"
	elif (commit_trim | length) == 0 then "is empty; expected text"
	elif (commit_trim | length) > $max then "has \(commit_trim | length) characters; expected at most \($max)"
	else empty
	end;

def commit_value_problem:
	if type == "number" then (if . == floor and . >= 0 then empty else "is \(.); expected a whole number of 0 or more" end)
	else commit_line_problem(commit_trailer_max)
	end;

def commit_kind_problem:
	if has("kind") | not then "kind is missing; expected a lowercase word"
	elif (.kind | type) != "string" or (.kind | test(commit_kind_rule) | not) then "kind \(.kind | tojson) is not lowercase words joined by dashes"
	else empty
	end;

def commit_text_problem:
	if has("text") | not then "text is missing; expected the subject's text"
	else
		((.text | commit_line_problem(commit_subject_max) | "text \(.)")
		// (if (.kind | type) == "string" and ((commit_subject_prefix(.kind) + (.text | commit_trim)) | length) > commit_subject_max
			then "the subject \"\(commit_subject_prefix(.kind))<text>\" has more than \(commit_subject_max) characters"
			else empty end))
	end;

def commit_trailer_problems:
	(.trailers // {}) as $trailers
	| if ($trailers | type) != "object" then "trailers is a JSON \($trailers | type); expected an object"
	else $trailers | to_entries[]
		| if (.key | test(commit_key_rule) | not) then "trailers[\(.key | tojson)] is not lowercase words joined by dashes"
		else .key as $key | .value | commit_value_problem | "trailers[\($key | tojson)] \(.)"
		end
	end;

def commit_problems:
	if type != "object" then ["the input is a JSON \(type); expected an object of kind, text and trailers"]
	else [
		(keys_unsorted[] | select(IN(commit_fields[]) | not) | "\(tojson) is not a field; expected only kind, text and trailers"),
		commit_kind_problem,
		commit_text_problem,
		commit_trailer_problems
	]
	end;

# effort -> Effort, change-id -> Change-Id.
def commit_trailer_key: split("-") | map((.[:1] | ascii_upcase) + .[1:]) | join("-");

def commit_trailer_text: if type == "number" then tostring else commit_trim end;

def commit_message:
	commit_subject_prefix(.kind) + (.text | commit_trim) + "\n"
	+ ((.trailers // {}) | to_entries
		| if length == 0 then ""
		else "\n" + (map("\(.key | commit_trailer_key): \(.value | commit_trailer_text)\n") | join(""))
		end);
