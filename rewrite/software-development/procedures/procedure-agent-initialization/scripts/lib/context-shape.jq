# The context file's shape, the one definition inject-plugins.sh and
# render-dispatch-plan.sh both check. Input: the file slurped (jq -s), so an
# empty file or several values show as a count; the file's path as
# --arg context_path, when given, is checked for the forbidden texts too.
# Output: one "<what>; expected <x>" line per problem, nothing when the file fits.

# Bounds the report so a deny reason stays short; the rest is counted.
def max_problems: 20;
# A field name from the file is quoted as JSON and cut, so it prints on one line.
def quoted_name: tojson | if length > 60 then .[:60] + "…" else . end;
def has_control: test("[[:cntrl:]]");
def one_line_text: type == "string" and (has_control | not) and test("[^[:space:]]");
def absolute_path: type == "string" and startswith("/") and (has_control | not);
# The whole link can go into a shell command line: a host of letters, digits,
# dots and hyphens with an optional port, then a path, query and fragment of
# only these characters, none of which quotes, substitutes, redirects, splits
# or chains in a shell (any other character goes in percent-encoded).
def http_url: type == "string" and test("^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?([/?#][A-Za-z0-9._~/?#=%:+,@-]*)?$"; "i");
def entry_shape($field): "{\"\($field)\": ..., \"why\": ...}";

# Texts the injected block can't carry, matched in any letter case: the context
# block's own tags would end or fake it, the untrusted-data fence tags would
# open or close a fence around what follows, and the brief's closing line
# (inject-plugins.sh's BRIEF_CLOSING_LINE; change both together) would move the
# end of the brief past the blocks.
def forbidden_texts: ["<crucible-context", "</crucible-context", "<untrusted-data", "</untrusted-data", "A marked gap beats a papered-over one:"];
def forbidden_expected: "expected text without the <crucible-context> or <untrusted-data> tags or the brief's closing line";
def first_forbidden: ascii_downcase as $text | first(forbidden_texts[] | select(. as $forbidden | $text | contains($forbidden | ascii_downcase)));
# A location such as notes[2] or paths[0].why; a key other than a plain name is quoted.
def location: reduce .[] as $step ("";
	if ($step | type) == "number" then . + "[\($step)]"
	elif ($step | test("^[a-z]+$")) then . + (if . == "" then "" else "." end) + $step
	else . + (if . == "" then "" else "." end) + ($step | quoted_name) end);
def forbidden_problems:
	. as $file
	| paths(type == "string") as $path
	| ($file | getpath($path) | first_forbidden) as $forbidden
	| "\($path | location) holds \($forbidden | tojson); \(forbidden_expected)";
def path_problems:
	$ARGS.named.context_path // empty | first_forbidden
	| "the path holds \(tojson); \(forbidden_expected)";

# Problems of the list under key $list: null, or an array of objects holding
# exactly $field (passing field_ok: $field_kind, as $field_expected) and why.
def list_problems($list; $field; field_ok; $field_kind; $field_expected):
	.[$list] as $value
	| if $value == null then empty
	  elif ($value | type) != "array" then "\($list) is a JSON \($value | type); expected null or an array of \(entry_shape($field)) objects"
	  else $value | to_entries[] | .key as $index | .value
		| if type != "object" then "\($list)[\($index)] is a JSON \(type); expected an object \(entry_shape($field))"
		  else ((keys - [$field, "why"])[] | "\($list)[\($index)].\(quoted_name): unknown field; expected only \($field) and why"),
			(if has($field) and (.[$field] | field_ok) then empty
			 else "\($list)[\($index)].\($field) missing or not \($field_kind); expected \($field_expected)" end),
			(if has("why") and (.why | one_line_text) then empty
			 else "\($list)[\($index)].why missing or not one line of text; expected a non-empty string without control characters" end)
		  end
	  end;

def notes_problems:
	if has("notes") | not then empty
	elif (.notes | type) != "array" then "notes is a JSON \(.notes | type); expected an array of strings ([] for none)"
	else .notes | to_entries[] | select(.value | type != "string") | "notes[\(.key)] is a JSON \(.value | type); expected a string"
	end;

def context_problems:
	if length != 1 then "the file holds \(length) JSON values; expected exactly one object"
	elif (.[0] | type) != "object" then "the file holds a JSON \(.[0] | type); expected an object"
	else .[0]
		| ((keys - ["paths", "links", "notes"])[] | "\(quoted_name): unknown field; expected only paths, links and notes"),
		  (["paths", "links", "notes"][] as $key | select(has($key) | not) | "\($key) missing; expected the keys paths, links and notes"),
		  list_problems("paths"; "path"; absolute_path; "an absolute path"; "a string starting with /, without control characters"),
		  list_problems("links"; "url"; http_url; "an http(s) URL"; "a string starting with http:// or https://, then a host of letters, digits, dots and hyphens with an optional :port, then optionally a path, query or fragment of letters, digits and . _ ~ / ? # = % : + , @ - only"),
		  notes_problems,
		  forbidden_problems
	end;

[path_problems, context_problems]
| .[:max_problems][],
  (if length > max_problems then "\(length - max_problems) more problems not shown (showing \(max_problems) of \(length)); expected none" else empty end)
