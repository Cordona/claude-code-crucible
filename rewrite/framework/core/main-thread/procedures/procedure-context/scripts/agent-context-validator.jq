# The context version's shape, the one definition context.sh and every script
# that reads a context version check: the body of a context.cut event.
# Input: the body slurped (jq -s), so an empty input or several values show
# as a count.
# With --arg effort FOLDER, the version's effort: its docs folders must be in
# that effort's files/context/, none past its own version number.
# Output: one "<what>; expected <x>" line per problem, nothing when the body fits;
# positions in a line, such as paths[0].why, are counted (from 0).
# A spec problem leads with NO-SPEC, so a reader matches the token.

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
# A docs folder: <effort>/files/context/v<N>, N from 1 with no leading zero
# and at most 9 digits, as context-versions.sh numbers a version.
def docs_pattern: "^(?<parent>/.+/files/context)/v(?<n>[1-9][0-9]{0,8})$";
def docs_folder: if absolute_path then (capture(docs_pattern) // null) else null end;
def sha256_hex: type == "string" and test("^[0-9a-f]{64}$");
def version_ok: type == "number" and . == floor and . >= 1 and . <= 999999999;
# One problem's line: the field's location then the problem.
def problem($location; $separator; $problem): "\($location)\($separator)\($problem)";
def why_problem($location):
	if has("why") and (.why | one_line_text) then empty
	else problem("\($location).why"; " "; "missing or not one line of text; expected a non-empty string without control characters") end;

def path_problem($location):
	if has("path") and (.path | absolute_path) then empty
	else problem("\($location).path"; " "; "missing or not an absolute path; expected a string starting with /, without control characters") end;

# The version's own docs folder parent and number: --arg effort's
# files/context and .version, when both are known; null otherwise.
def own_version:
	($ARGS.named.effort // "") as $effort
	| if $effort == "" or (.version | version_ok | not) then null
	  else {files: "\($effort)/files/context", n: .version} end;

# Problems of one paths[] entry $entry at $index: {path, why} for an outside
# file or folder, {path, sha256} for a docs folder.
def path_entry_problems($index):
	"paths[\($index)]" as $location
	| if type != "object" then problem($location; " "; "is a JSON \(type); expected an object {\"path\": ..., \"why\": ...} or, for a docs folder, {\"path\": ..., \"sha256\": ...}")
	  elif has("sha256") then
		((keys - ["path", "sha256"])[] | problem("\($location).\(quoted_name)"; ": "; "unknown field; expected only path and sha256 for a docs folder")),
		path_problem($location),
		(if .sha256 | sha256_hex then empty
		 else problem("\($location).sha256"; " "; "is not 64 lowercase hex digits; expected the docs folder's digest") end),
		(if (.path | docs_folder) != null then empty
		 else problem("\($location).path"; " "; "has a sha256 but is not a docs folder; expected <effort>/files/context/v<N>, or no sha256 for an outside path") end)
	  else
		((keys - ["path", "why"])[] | problem("\($location).\(quoted_name)"; ": "; "unknown field; expected only path and why")),
		path_problem($location),
		(if (.path | docs_folder) != null then problem("\($location).sha256"; " "; "missing for a docs folder; expected the folder's digest, as context.sh freeze writes it")
		 else why_problem($location) end)
	  end;

# Problems of the docs folders together: one parent, in order, and, when the
# version's effort is known, in it and none past its number.
def docs_problems:
	[(.paths // []) | if type == "array" then to_entries[] else empty end
		| select((.value | type) == "object" and (.value | has("sha256")))
		| {index: .key, folder: (.value.path | docs_folder)} | select(.folder != null)] as $docs
	| own_version as $own
	| ($docs | to_entries[] | .key as $k | .value
		| (if $k > 0 and .folder.parent != $docs[0].folder.parent then problem("paths[\(.index)].path"; " "; "is in another docs folder parent than paths[\($docs[0].index)]; expected every docs folder in one effort's files/context/") else empty end),
		  (if $k > 0 and (.folder.n | tonumber) <= ($docs[$k - 1].folder.n | tonumber) then problem("paths[\(.index)].path"; " "; "is not after the docs folder before it; expected docs folders in order, each once") else empty end),
		  (if $own != null and .folder.parent != $own.files then problem("paths[\(.index)].path"; " "; "is not in this version's effort; expected \($own.files)/v<N>") else empty end),
		  (if $own != null and (.folder.n | tonumber) > $own.n then problem("paths[\(.index)].path"; " "; "is past this version (v\($own.n)); expected docs folders up to v\($own.n)") else empty end));

# The spec: the spec.md of one of the version's docs folders.
def spec_problems:
	[(.paths // []) | if type == "array" then .[] else empty end
		| select(type == "object" and has("sha256") and (.path | docs_folder) != null) | .path + "/spec.md"] as $specs
	| if (has("spec") | not) or .spec == null or .spec == "" then problem("spec"; " "; "NO-SPEC: missing, null or empty; expected the absolute path of the spec.md in one of the version's docs folders")
	  elif (.spec | type) != "string" then problem("spec"; " "; "NO-SPEC: is a JSON \(.spec | type); expected the absolute path of the spec.md in one of the version's docs folders")
	  elif (.spec as $spec | $specs | index([$spec])) == null then problem("spec"; " "; "NO-SPEC: is not the spec.md of one of the version's docs folders; expected <docs folder>/spec.md of a paths entry with a sha256")
	  else empty end;

def links_problems:
	if has("links") | not then empty
	elif (.links | type) != "array" then problem("links"; " "; "is a JSON \(.links | type); expected an array of {\"url\": ..., \"why\": ...} objects; leave the key out for none")
	else .links | to_entries[] | .key as $index | .value
		| if type != "object" then problem("links[\($index)]"; " "; "is a JSON \(type); expected an object {\"url\": ..., \"why\": ...}")
		  else ((keys - ["url", "why"])[] | problem("links[\($index)].\(quoted_name)"; ": "; "unknown field; expected only url and why")),
			(if has("url") and (.url | http_url) then empty
			 else problem("links[\($index)].url"; " "; "missing or not an http(s) URL; expected a string starting with http:// or https:// (in any letter case), then a host of letters, digits, dots and hyphens with an optional :port, then optionally a path, query or fragment of letters, digits and . _ ~ / ? # = % : + , @ - only") end),
			why_problem("links[\($index)]")
		  end
	end;

def paths_problems:
	if has("paths") | not then problem("paths"; " "; "missing; expected an array holding at least the docs folder of the spec")
	elif (.paths | type) != "array" then problem("paths"; " "; "is a JSON \(.paths | type); expected an array of path entries")
	else (.paths | to_entries[] | .key as $index | .value | path_entry_problems($index)), docs_problems end;

def version_problems:
	if has("version") and (.version | version_ok) then empty
	else problem("version"; " "; "missing or not a version number; expected a whole number from 1, the number of context.cut events up to this one") end;

def context_problems:
	if length != 1 then problem("the body"; " "; "holds \(length) JSON values; expected exactly one object")
	elif (.[0] | type) != "object" then problem("the body"; " "; "holds a JSON \(.[0] | type); expected an object")
	else .[0]
		| ((keys - ["version", "paths", "links", "spec"])[] | problem(quoted_name; ": "; "unknown field; expected only version, paths, links and spec")),
		  version_problems,
		  paths_problems,
		  links_problems,
		  spec_problems
	end;

[context_problems]
| .[:max_problems][],
  (if length > max_problems then "\(length - max_problems) more problems not shown (showing \(max_problems) of \(length)); expected none" else empty end)
