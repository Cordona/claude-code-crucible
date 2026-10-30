# The context file's shape, the one definition context.sh and every script
# that reads a context file check. Input: the file slurped (jq -s), so an
# empty file or several values show as a count.
# Output: one "<what>; expected <x>" line per problem, nothing when the file fits;
# positions in a line, such as paths[0].why, are counted (from 0).
# With --arg format json: one {"at": <the field's path, such as ["paths", 2,
# "why"]; [] for the file>, "problem": "<problem>;
# expected <x>"} object per problem, every problem, none counted away.

include "agent-context-url" {search: "./"};

# Bounds the report so a deny reason stays short; the rest is counted.
def max_problems: 20;
# A field name from the file is quoted as JSON and cut, so it prints on one
# line; 60 characters show any real field name whole and keep a line naming an
# unknown one short.
def quoted_name: tojson | if length > 60 then .[:60] + "…" else . end;
def has_control: test("[[:cntrl:]]");
def one_line_text: type == "string" and (has_control | not) and test("[^[:space:]]");
def absolute_path: type == "string" and startswith("/") and (has_control | not);
# The session that wrote the file: CLAUDE_CODE_SESSION_ID, as context.sh
# takes it by the crucible skill's crucible_session_rule.
def session_id_ok: type == "string" and test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z");
def entry_shape($field): "{\"\($field)\": ..., \"why\": ...}";
# One problem: the field's path, and its line, the field's location then the problem.
def problem($at; $location; $separator; $problem): {at: $at, problem: $problem, line: "\($location)\($separator)\($problem)"};

# Problems of the list under key $list: missing or null (no entry), or an
# array of objects holding exactly $field (passing field_ok: $field_kind, as
# $field_expected) and why.
def list_problems($list; $field; field_ok; $field_kind; $field_expected):
	.[$list] as $value
	| if $value == null then empty
	  elif ($value | type) != "array" then problem([$list]; $list; " "; "is a JSON \($value | type); expected an array of \(entry_shape($field)) objects; leave the key out for none")
	  else $value | to_entries[] | .key as $index | .value
		| if type != "object" then problem([$list, $index]; "\($list)[\($index)]"; " "; "is a JSON \(type); expected an object \(entry_shape($field))")
		  else ((keys - [$field, "why"])[] | problem([$list, $index, .]; "\($list)[\($index)].\(quoted_name)"; ": "; "unknown field; expected only \($field) and why")),
			(if has($field) and (.[$field] | field_ok) then empty
			 else problem([$list, $index, $field]; "\($list)[\($index)].\($field)"; " "; "missing or not \($field_kind); expected \($field_expected)") end),
			(if has("why") and (.why | one_line_text) then empty
			 else problem([$list, $index, "why"]; "\($list)[\($index)].why"; " "; "missing or not one line of text; expected a non-empty string without control characters") end)
		  end
	  end;

def notes_problems:
	if has("notes") | not then empty
	elif (.notes | type) != "array" then problem(["notes"]; "notes"; " "; "is a JSON \(.notes | type); expected an array of strings; leave the key out for none")
	else .notes | to_entries[] | select(.value | type != "string") | problem(["notes", .key]; "notes[\(.key)]"; " "; "is a JSON \(.value | type); expected a string")
	end;

def session_problems:
	if has("claude_session_id") and (.claude_session_id | session_id_ok) then empty
	else problem(["claude_session_id"]; "claude_session_id"; " "; "missing or not a session ID; expected a lowercase UUID, the session that wrote the file") end;

def context_problems:
	if length != 1 then problem([]; "the file"; " "; "holds \(length) JSON values; expected exactly one object")
	elif (.[0] | type) != "object" then problem([]; "the file"; " "; "holds a JSON \(.[0] | type); expected an object")
	else .[0]
		| ((keys - ["claude_session_id", "paths", "links", "notes"])[] | problem([.]; quoted_name; ": "; "unknown field; expected only claude_session_id, paths, links and notes")),
		  session_problems,
		  list_problems("paths"; "path"; absolute_path; "an absolute path"; "a string starting with /, without control characters"),
		  list_problems("links"; "url"; http_url; "an http(s) URL"; "a string starting with http:// or https:// (in any letter case), then a host of letters, digits, dots and hyphens with an optional :port, then optionally a path, query or fragment of letters, digits and . _ ~ / ? # = % : + , @ - only"),
		  notes_problems
	end;

[context_problems]
| if $ARGS.named.format == "json" then .[] | {at, problem}
  else map(.line)
	| .[:max_problems][],
	  (if length > max_problems then "\(length - max_problems) more problems not shown (showing \(max_problems) of \(length)); expected none" else empty end)
  end
