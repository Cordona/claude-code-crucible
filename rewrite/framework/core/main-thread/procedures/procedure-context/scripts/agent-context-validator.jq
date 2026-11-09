# The context version's shape, the one definition context.sh and every script
# that reads a context version check. Input: the file slurped (jq -s), so an
# empty file or several values show as a count.
# With --arg context_path PATH, the version's own path: its docs folders must
# be in its effort's context/docs/, none past its own version number.
# Output: one "<what>; expected <x>" line per problem, nothing when the file fits;
# positions in a line, such as paths[0].why, are counted (from 0).
# With --arg format json: one {"at": <the field's path, such as ["paths", 2,
# "why"]; [] for the file>, "problem": "<problem>;
# expected <x>"} object per problem, every problem, none counted away.
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
# A docs folder: <effort>/context/docs/v<N>, N from 1 with no leading zero and
# at most 9 digits, as context-versions.sh numbers a version.
def docs_pattern: "^(?<parent>/.+/context/docs)/v(?<n>[1-9][0-9]{0,8})$";
def docs_folder: if absolute_path then (capture(docs_pattern) // null) else null end;
def sha256_hex: type == "string" and test("^[0-9a-f]{64}$");
# The session that wrote the file: CLAUDE_CODE_SESSION_ID, as context.sh
# takes it by the crucible skill's crucible_session_rule.
def session_id_ok: type == "string" and test("\\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\z");
# One problem: the field's path, and its line, the field's location then the problem.
def problem($at; $location; $separator; $problem): {at: $at, problem: $problem, line: "\($location)\($separator)\($problem)"};
def why_problem($at; $location):
	if has("why") and (.why | one_line_text) then empty
	else problem($at + ["why"]; "\($location).why"; " "; "missing or not one line of text; expected a non-empty string without control characters") end;

# The version's own context/ folder and number, from --arg context_path when
# it names a version file; null otherwise.
def own_version:
	($ARGS.named.context_path // "")
	| capture("^(?<context>/.+/context)/[^/]+-v(?<n>[1-9][0-9]{0,8})\\.json$") // null
	| if . == null then null else .n |= tonumber end;

# Problems of one paths[] entry $entry at $index: {path, why} for an outside
# file or folder, {path, sha256, why} for a docs folder.
def path_entry_problems($index):
	"paths[\($index)]" as $location
	| if type != "object" then problem(["paths", $index]; $location; " "; "is a JSON \(type); expected an object {\"path\": ..., \"why\": ...} or, for a docs folder, {\"path\": ..., \"sha256\": ..., \"why\": ...}")
	  else
		((keys - ["path", "sha256", "why"])[] | problem(["paths", $index, .]; "\($location).\(quoted_name)"; ": "; "unknown field; expected only path, sha256 and why")),
		(if has("path") and (.path | absolute_path) then empty
		 else problem(["paths", $index, "path"]; "\($location).path"; " "; "missing or not an absolute path; expected a string starting with /, without control characters") end),
		(if has("sha256") then
			(if .sha256 | sha256_hex then empty
			 else problem(["paths", $index, "sha256"]; "\($location).sha256"; " "; "is not 64 lowercase hex digits; expected the docs folder's digest") end),
			(if (.path | docs_folder) != null then empty
			 else problem(["paths", $index, "path"]; "\($location).path"; " "; "has a sha256 but is not a docs folder; expected <effort>/context/docs/v<N>, or no sha256 for an outside path") end)
		 elif (.path | docs_folder) != null then problem(["paths", $index, "sha256"]; "\($location).sha256"; " "; "missing for a docs folder; expected the folder's digest, as context.sh freeze writes it")
		 else empty end),
		why_problem(["paths", $index]; $location)
	  end;

# Problems of the docs folders together: one parent, in order, and, when the
# version's own path is known, in its effort and none past its number.
def docs_problems:
	[(.paths // []) | if type == "array" then to_entries[] else empty end
		| select((.value | type) == "object" and (.value | has("sha256")))
		| {index: .key, folder: (.value.path | docs_folder)} | select(.folder != null)] as $docs
	| own_version as $own
	| ($docs | to_entries[] | .key as $k | .value
		| (if $k > 0 and .folder.parent != $docs[0].folder.parent then problem(["paths", .index, "path"]; "paths[\(.index)].path"; " "; "is in another docs folder parent than paths[\($docs[0].index)]; expected every docs folder in one effort's context/docs/") else empty end),
		  (if $k > 0 and (.folder.n | tonumber) <= ($docs[$k - 1].folder.n | tonumber) then problem(["paths", .index, "path"]; "paths[\(.index)].path"; " "; "is not after the docs folder before it; expected docs folders in order, each once") else empty end),
		  (if $own != null and .folder.parent != "\($own.context)/docs" then problem(["paths", .index, "path"]; "paths[\(.index)].path"; " "; "is not in this version's effort; expected \($own.context)/docs/v<N>") else empty end),
		  (if $own != null and (.folder.n | tonumber) > $own.n then problem(["paths", .index, "path"]; "paths[\(.index)].path"; " "; "is past this version (v\($own.n)); expected docs folders up to v\($own.n)") else empty end));

# The spec: the spec.md of one of the version's docs folders.
def spec_problems:
	[(.paths // []) | if type == "array" then .[] else empty end
		| select(type == "object" and has("sha256") and (.path | docs_folder) != null) | .path + "/spec.md"] as $specs
	| if (has("spec") | not) or .spec == null or .spec == "" then problem(["spec"]; "spec"; " "; "NO-SPEC: missing, null or empty; expected the absolute path of the spec.md in one of the version's docs folders")
	  elif (.spec | type) != "string" then problem(["spec"]; "spec"; " "; "NO-SPEC: is a JSON \(.spec | type); expected the absolute path of the spec.md in one of the version's docs folders")
	  elif (.spec as $spec | $specs | index([$spec])) == null then problem(["spec"]; "spec"; " "; "NO-SPEC: is not the spec.md of one of the version's docs folders; expected <docs folder>/spec.md of a paths entry with a sha256")
	  else empty end;

def links_problems:
	if has("links") | not then empty
	elif (.links | type) != "array" then problem(["links"]; "links"; " "; "is a JSON \(.links | type); expected an array of {\"url\": ..., \"why\": ...} objects; leave the key out for none")
	else .links | to_entries[] | .key as $index | .value
		| if type != "object" then problem(["links", $index]; "links[\($index)]"; " "; "is a JSON \(type); expected an object {\"url\": ..., \"why\": ...}")
		  else ((keys - ["url", "why"])[] | problem(["links", $index, .]; "links[\($index)].\(quoted_name)"; ": "; "unknown field; expected only url and why")),
			(if has("url") and (.url | http_url) then empty
			 else problem(["links", $index, "url"]; "links[\($index)].url"; " "; "missing or not an http(s) URL; expected a string starting with http:// or https:// (in any letter case), then a host of letters, digits, dots and hyphens with an optional :port, then optionally a path, query or fragment of letters, digits and . _ ~ / ? # = % : + , @ - only") end),
			why_problem(["links", $index]; "links[\($index)]")
		  end
	end;

def paths_problems:
	if has("paths") | not then problem(["paths"]; "paths"; " "; "missing; expected an array holding at least the docs folder of the spec")
	elif (.paths | type) != "array" then problem(["paths"]; "paths"; " "; "is a JSON \(.paths | type); expected an array of path entries")
	else (.paths | to_entries[] | .key as $index | .value | path_entry_problems($index)), docs_problems end;

def session_problems:
	if has("claude_session_id") and (.claude_session_id | session_id_ok) then empty
	else problem(["claude_session_id"]; "claude_session_id"; " "; "missing or not a session ID; expected a lowercase UUID, the session that wrote the file") end;

def context_problems:
	if length != 1 then problem([]; "the file"; " "; "holds \(length) JSON values; expected exactly one object")
	elif (.[0] | type) != "object" then problem([]; "the file"; " "; "holds a JSON \(.[0] | type); expected an object")
	else .[0]
		| ((keys - ["claude_session_id", "paths", "links", "spec"])[] | problem([.]; quoted_name; ": "; "unknown field; expected only claude_session_id, paths, links and spec")),
		  session_problems,
		  paths_problems,
		  links_problems,
		  spec_problems
	end;

[context_problems]
| if $ARGS.named.format == "json" then .[] | {at, problem}
  else map(.line)
	| .[:max_problems][],
	  (if length > max_problems then "\(length - max_problems) more problems not shown (showing \(max_problems) of \(length)); expected none" else empty end)
  end
