#!/usr/bin/env sh
# Checks the reviewer's per-round report JSON and, on a pass with --dispatch,
# stamps the dispatch's lens on every finding and the dispatch keys at the top
# level. The jq validator below owns the report's shape (there is no schema
# file): the report standard's field table and --help document it, and the
# validator wins where they differ.
set -eu

readonly PROG='report.sh'
readonly DISPATCH_DIR='flow-agent-initialization/scripts/04-agent-dispatch'
# The lens a dispatch that loads no tech-* or standard-* plugin reviews through.
readonly NO_LENS='correctness'
# The one agent whose report this script checks and stamps.
readonly REVIEWER_AGENT='code-reviewer'

# The shape check: the count line, then one "<field>: <what>; expected <x>" line
# per problem. Every value taken from the report goes through `shown`, so a
# problem line never holds a newline. $prior_mode is "given" (a re-review, the
# prior IDs in $prior_text) or "none" (previous_findings is refused); $diff_text
# is the DIFF the reviewer was given.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly CHECK_JQ='
# One sentence or a path:line with context fits; more is copied text, not a report.
def max_text: 200;
# A deep repo path stays far below this; more is pasted text ending in ":N".
def max_path: 300;
# Plugin names are short slugs; more is copied text, not a name.
def max_name: 100;
# A finding ID is a short tag such as SHELL-001; more is not an ID.
def max_id: 40;
# Far above any real round, so they bound only a runaway report.
# previous_findings has no cap of its own: it holds the prior IDs.
def list_caps: {findings: 200, flags: 100, not_reviewed: 100, found: 100};
# One defect seldom spans more than a few places; more is a list, not a finding.
def max_locations: 20;
# Enough for every field of a full report; more lines would bury the fix.
def max_problems: 30;
def list_keys: ["findings", "previous_findings", "flags", "not_reviewed", "found"];
def never_written_keys: ["verdict", "count", "counts", "summary", "round", "date", "generated", "status", "ack", "waiver", "waived"];
def stamp_keys: ["tech", "plugins", "mode", "dispatch", "started", "finished"];
def severities: ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
def flag_severities: ["CRITICAL", "HIGH"];
def realisms: ["realistic", "edge-case", "hypothetical"];
def finding_required: ["severity", "realism", "locations", "trigger", "problem", "fix"];
def finding_optional: ["proof", "real_if", "security"];
def previous_keys: ["id", "status", "proof", "note", "severity", "realism", "real_if", "locations"];
def flag_keys: ["source", "location", "severity", "text"];
def flag_refused_keys: ["fix", "trigger", "proof"];
def not_reviewed_keys: ["text", "location", "plugin"];
def found_keys: ["kind", "location", "text"];
def location_keys: ["file", "line", "relates_to"];

def among($list): . as $value | any($list[]; . == $value);
def names: join(", ");
# A quoted value is cut at 60 characters so a problem line stays one readable line.
def shown: tojson | if length > 60 then .[:60] + "…" else . end;
def text_ok: type == "string" and test("[^[:space:]]");
def absolute: startswith("/") or startswith("~") or test("^[A-Za-z]:[\\\\/]");
def outside_repo: split("/") | any(. == "..");
def missing($loc; $field; $expected): "\($loc).\($field): missing; expected \($expected)";
def never_written_reason: "the review flow computes or stamps it, and only the human waives";

def one_line_expected: "one line of at most \(max_text) characters";
def one_line_problem:
	if type != "string" then "a JSON \(type)"
	elif text_ok | not then "empty"
	elif test("[\r\n]") then "more than one line"
	elif length > max_text then "\(length) characters"
	else empty end;
def name_problem($max):
	if type != "string" then "a JSON \(type)"
	elif text_ok | not then "empty"
	elif test("[[:cntrl:]]") then "holds a control character"
	elif length > $max then "\(length) characters"
	else empty end;
def enum_problem($values): if type == "string" and among($values) then empty else "\(shown) is not a known value" end;

def path_line_expected: "a repo-relative <path>:<N> or <path>:<N-M>, never absolute, the path at most \(max_path) characters and N, M of 1 to 9 digits";
# Nine digits hold any real line number and keep the text bounded.
def path_line_parts: [capture("\\A(?<path>.+):(?<from>[0-9]{1,9})(-(?<to>[0-9]{1,9}))?\\z")][0];
def path_line_problem:
	if type != "string" then "a JSON \(type)"
	elif test("[[:cntrl:]]") then "holds a control character"
	else path_line_parts as $parts
		| if $parts == null or ($parts.path | text_ok | not) then "\(shown) is not a path:line"
		  elif $parts.path | absolute then "an absolute path"
		  elif $parts.path | outside_repo then "outside the repo (a .. segment)"
		  elif ($parts.path | length) > max_path then "a path of \($parts.path | length) characters"
		  elif ($parts.from | tonumber) < 1 or ($parts.to != null and ($parts.to | tonumber) < ($parts.from | tonumber)) then "\(shown) is not a line N or a range N-M with 1 <= N <= M"
		  else empty end
	end;

def file_problem:
	name_problem(max_path) // (if absolute then "an absolute path" elif outside_repo then "outside the repo (a .. segment)" else empty end);
def line_problem:
	if type == "number" then (if . >= 1 and . <= 999999999 and . == floor then empty else "\(shown) is not a positive integer of 1 to 9 digits" end)
	elif type == "string" then
		[capture("\\A(?<from>[0-9]{1,9})-(?<to>[0-9]{1,9})\\z")][0] as $range
		| if $range == null then "\(shown) is not a range N-M"
		  elif ($range.from | tonumber) < 1 or ($range.to | tonumber) < ($range.from | tonumber) then "\(shown) is not a range with 1 <= N <= M"
		  else empty end
	else "a JSON \(type)" end;
def location_problems($loc):
	if type != "object" then "\($loc): a JSON \(type); expected {\"file\", \"line\"}, with an optional \"relates_to\""
	else ((keys - location_keys)[] | "\($loc).\(shown): unknown key; expected only \(location_keys | names)"),
		(if has("file") | not then missing($loc; "file"; "a repo-relative path")
		 else .file | file_problem | "\($loc).file: \(.); expected a repo-relative path of at most \(max_path) characters, never absolute, with no .. segment" end),
		(if has("line") | not then missing($loc; "line"; "a positive integer or a range \"N-M\"")
		 else .line | line_problem | "\($loc).line: \(.); expected a positive integer or a range \"N-M\" with N <= M, each of 1 to 9 digits" end),
		(select(has("relates_to")) | .relates_to | path_line_problem | "\($loc).relates_to: \(.); expected \(path_line_expected), naming the changed line")
	end;

# A quoted header path uses the C-style quoting git writes: \NNN octal bytes
# (every non-ASCII byte under the default core.quotePath) and \a \b \t \n \v
# \f \r \" \\. The bytes are read back as UTF-8; a path that does not decode
# stays as written, quotes and escapes included.
def utf8_bytes:
	explode | map(
		if . < 128 then [.]
		elif . < 2048 then [192 + (. / 64 | floor), 128 + . % 64]
		elif . < 65536 then [224 + (. / 4096 | floor), 128 + (. / 64 | floor) % 64, 128 + . % 64]
		else [240 + (. / 262144 | floor), 128 + (. / 4096 | floor) % 64, 128 + (. / 64 | floor) % 64, 128 + . % 64] end)
	| add // [];
def utf8_text:
	reduce .[] as $byte ({points: [], need: 0, point: 0};
		if .need > 0 then
			if $byte >= 128 and $byte < 192 then .point = .point * 64 + $byte - 128 | .need -= 1
				| if .need == 0 then .points += [.point] else . end
			else error("not UTF-8") end
		elif $byte < 128 then .points += [$byte]
		elif $byte >= 194 and $byte < 224 then .point = $byte - 192 | .need = 1
		elif $byte >= 224 and $byte < 240 then .point = $byte - 224 | .need = 2
		elif $byte >= 240 and $byte < 245 then .point = $byte - 240 | .need = 3
		else error("not UTF-8") end)
	| if .need > 0 then error("not UTF-8") else .points | implode end;
def c_escape_byte:
	if test("\\A[0-7]{3}\\z") then explode | map(. - 48) | .[0] * 64 + .[1] * 8 + .[2]
	else {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, "\"": 34, "\\": 92}[.] end;
def c_unquoted:
	if test("\\A\"(\\\\([0-7]{3}|[abtnvfr\"\\\\])|[^\\\\\"])*\"\\z") | not then error("not C-quoted")
	else .[1:-1] | [match("\\\\([0-7]{3}|.)|[^\\\\]+"; "g").string]
		| map(if startswith("\\") then [.[1:] | c_escape_byte] else utf8_bytes end)
		| add // [] | utf8_text end;

# The DIFF file list: the path of every "+++ b/<path>" header and, where that
# header is /dev/null (a deletion), of its "--- a/<path>" header. Headers are
# read only between a "diff " line (or the file start) and the first "@@" hunk,
# so a changed line starting with --- or +++ is never taken for one.
def header_path:
	sub("\t.*$"; "")
	| if startswith("\"") then (. as $quoted | try c_unquoted catch $quoted) else . end
	| if . == "/dev/null" then null
	  elif startswith("a/") or startswith("b/") then .[2:]
	  else . end;
def diff_files:
	$diff_text | split("\n") | map(sub("\r$"; ""))
	| reduce .[] as $line ({header: true, minus: null, files: []};
		if $line | startswith("diff ") then .header = true | .minus = null
		elif $line | startswith("@@") then .header = false
		elif .header and ($line | startswith("--- ")) then .minus = ($line[4:] | header_path)
		elif .header and ($line | startswith("+++ ")) then
			($line[4:] | header_path) as $plus
			| (if $plus != null then .files += [$plus] elif .minus != null then .files += [.minus] else . end)
			| .minus = null
		else . end)
	| .files | unique;
def in_diff($files): ltrimstr("./") as $path | any($files[]; . == $path);
def diff_problems($loc; $files):
	select(type == "object" and ([.file | file_problem] | length) == 0)
	| if .file | in_diff($files) then empty
	  elif (.relates_to | type) == "string" and ((.relates_to | path_line_parts.path // null) as $path | $path != null and ($path | in_diff($files))) then empty
	  elif has("relates_to") and ([.relates_to | path_line_problem] | length) > 0 then empty
	  elif has("relates_to") then "\($loc).relates_to: \(.relates_to | shown) names no file the DIFF changes; expected the path:line of a changed line that relies on or exposes the problem"
	  else "\($loc).file: \(.file | shown) is not a file the DIFF changes; expected a DIFF file, or relates_to naming the changed line that relies on or exposes the problem" end;
def locations_problems($loc; $files):
	if has("locations") | not then empty
	elif (.locations | type) != "array" or (.locations | length) == 0 then
		"\($loc).locations: \(if (.locations | type) == "array" then "empty" else "a JSON \(.locations | type)" end); expected a non-empty array of {file, line} locations"
	elif (.locations | length) > max_locations then
		"\($loc).locations: \(.locations | length) items; expected at most \(max_locations) locations"
	else .locations | to_entries[] | .key as $index | .value
		| location_problems("\($loc).locations[\($index)]"),
		  (if $files == null then empty else diff_problems("\($loc).locations[\($index)]"; $files) end)
	end;

# The values a finding and an OPEN entry share, each checked when present.
def graded_value_problems($loc):
	(select(has("severity")) | .severity | enum_problem(severities) | "\($loc).severity: \(.); expected one of \(severities | names)"),
	(select(has("realism")) | .realism | enum_problem(realisms) | "\($loc).realism: \(.); expected one of \(realisms | names)"),
	(select(has("proof")) | .proof | path_line_problem | "\($loc).proof: \(.); expected \(path_line_expected)"),
	(select(has("real_if")) | .real_if | one_line_problem | "\($loc).real_if: \(.); expected what would make it real, \(one_line_expected)");
def realism_problems($loc):
	if .realism == "edge-case" and (has("proof") | not) then "\($loc).proof: missing on realism edge-case; expected the path:line that shows the trigger is rare"
	elif .realism == "hypothetical" and (has("real_if") | not) then "\($loc).real_if: missing on realism hypothetical; expected what would make it real"
	elif .realism == "realistic" then
		("proof", "real_if") as $key | select(has($key))
		| "\($loc).\($key): given on realism realistic; expected it left out: a realistic finding carries neither proof nor real_if"
	else empty end;

def finding_problems($loc; $files):
	if type != "object" then "\($loc): a JSON \(type); expected an object with \(finding_required | names)"
	else . as $finding
		| ((keys - finding_required - finding_optional)[] as $key
			| if $key == "id" then "\($loc).id: written into the report; expected it left out: the review record stamps it"
			  elif $key == "plugin" then "\($loc).plugin: written into the report; expected it left out: report.sh check --dispatch stamps the lens"
			  elif $key | among(never_written_keys) then "\($loc).\($key): written into the report; expected it left out: \(never_written_reason)"
			  else "\($loc).\($key | shown): unknown key; expected only \(finding_required + finding_optional | names)" end),
		  (finding_required[] as $key | select($finding | has($key) | not)
			| missing($loc; $key; if $key == "severity" then "one of \(severities | names)"
				elif $key == "realism" then "one of \(realisms | names)"
				elif $key == "locations" then "a non-empty array of {file, line} locations"
				else one_line_expected end)),
		  graded_value_problems($loc),
		  (("trigger", "problem", "fix") as $key | select($finding | has($key))
			| $finding[$key] | one_line_problem | "\($loc).\($key): \(.); expected \(one_line_expected)"),
		  (select(has("security") and .security != true)
			| "\($loc).security: \(.security | shown) is not true; expected true, or the key left out"),
		  realism_problems($loc),
		  (select(.security == true and .realism == "hypothetical" and (has("proof") | not))
			| "\($loc).proof: missing on a security: true hypothetical finding; expected the path:line that proves it harmless, or realism realistic"),
		  locations_problems($loc; $files)
	end;

def prior_ids:
	$prior_text | split("\n") | map(sub("\r$"; "") | sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "") | select(length > 0))
	| reduce .[] as $id ([]; if any(.[]; . == $id) then . else . + [$id] end);
def previous_item_problems($loc; $files):
	if type != "object" then "\($loc): a JSON \(type); expected an object with id and status"
	else . as $entry
		| ((keys - previous_keys)[] | "\($loc).\(shown): unknown key; expected only \(previous_keys | names)"),
		  (if has("id") | not then missing($loc; "id"; "a prior finding ID")
		   else .id | name_problem(max_id) | "\($loc).id: \(.); expected a prior finding ID of at most \(max_id) characters" end),
		  (if has("status") | not then missing($loc; "status"; "RESOLVED or OPEN")
		   else .status | enum_problem(["RESOLVED", "OPEN"]) | "\($loc).status: \(.); expected RESOLVED or OPEN" end),
		  graded_value_problems($loc),
		  (select(has("note")) | .note | one_line_problem | "\($loc).note: \(.); expected what is still wrong, \(one_line_expected)"),
		  locations_problems($loc; if .status == "OPEN" then $files else null end),
		  (if .status == "RESOLVED" then
			(if has("proof") then empty else "\($loc).proof: missing on RESOLVED; expected the path:line that shows the fix" end),
			(("severity", "realism", "real_if", "locations") as $key | select($entry | has($key))
				| "\($loc).\($key): given on RESOLVED; expected it left out: only an OPEN entry carries a changed \($key)")
		   elif .status == "OPEN" then
			(if has("note") then empty else "\($loc).note: missing on OPEN; expected what is still wrong" end),
			(select(has("realism")) | realism_problems($loc))
		   else empty end)
	end;
def previous_set_problems:
	if $prior_mode == "none" then
		(if has("previous_findings") then "previous_findings: given on a first round; expected it left out: only a re-review, checked with --prior, takes it" else empty end)
	else prior_ids as $ids
		| if has("previous_findings") | not then
			$ids[] | "previous_findings: \(shown) missing; expected each prior ID exactly once"
		  elif (.previous_findings | type) != "array" then empty
		  else [.previous_findings[] | objects | .id | strings] as $given
			| ($ids[] as $id | [$given[] | select(. == $id)] | length
				| if . == 0 then "previous_findings: \($id | shown) missing; expected each prior ID exactly once"
				  elif . > 1 then "previous_findings: \($id | shown) given \(.) times; expected it exactly once"
				  else empty end),
			  ($given | unique[] | select(among($ids) | not)
				| "previous_findings: \(shown) is not a prior ID; expected only \($ids | map(shown) | names)")
		  end
	end;

def flag_problems($loc):
	if type != "object" then "\($loc): a JSON \(type); expected an object with \(flag_keys | names)"
	else . as $flag
		| ((keys - flag_keys)[] as $key
			| if $key | among(flag_refused_keys) then "\($loc).\($key): given on a flag; expected it left out: a flag carries no fix, trigger or proof, it tells the human and never gates"
			  else "\($loc).\($key | shown): unknown key; expected only \(flag_keys | names)" end),
		  (flag_keys[] as $key | select($flag | has($key) | not)
			| missing($loc; $key; if $key == "source" then "code or non-code"
				elif $key == "severity" then "CRITICAL or HIGH"
				elif $key == "location" then "a {file, line} location"
				else one_line_expected end)),
		  (select(has("source")) | .source | enum_problem(["code", "non-code"]) | "\($loc).source: \(.); expected code or non-code"),
		  (select(has("severity")) | .severity | enum_problem(flag_severities)
			| "\($loc).severity: \(.); expected CRITICAL or HIGH: a lesser concern outside the change is not flagged"),
		  (select(has("text")) | .text | one_line_problem | "\($loc).text: \(.); expected \(one_line_expected)"),
		  (select(has("location")) | .location | location_problems("\($loc).location"))
	end;

def not_reviewed_problems($loc):
	if type != "object" then "\($loc): a JSON \(type); expected an object with text"
	else ((keys - not_reviewed_keys)[] | "\($loc).\(shown): unknown key; expected only \(not_reviewed_keys | names)"),
		(if has("text") | not then missing($loc; "text"; "what was not reviewed, \(one_line_expected)")
		 else .text | one_line_problem | "\($loc).text: \(.); expected \(one_line_expected)" end),
		(select(has("location")) | .location | location_problems("\($loc).location")),
		(select(has("plugin")) | .plugin | name_problem(max_name) | "\($loc).plugin: \(.); expected the name of the lens plugin that owns it, at most \(max_name) characters")
	end;

def found_location_expected:
	"a repo-relative path:line, message: <FIELD>, a plugin name and file, a context entry (paths[<n>], links[<n>] or its URL), a URL, or commit <sha>, \(one_line_expected)";
def found_problems($loc):
	if type != "object" then "\($loc): a JSON \(type); expected an object with \(found_keys | names)"
	else . as $item
		| ((keys - found_keys)[] | "\($loc).\(shown): unknown key; expected only \(found_keys | names)"),
		  (found_keys[] as $key | select($item | has($key) | not)
			| missing($loc; $key; if $key == "kind" then "instruction or secret"
				elif $key == "location" then found_location_expected
				else one_line_expected end)),
		  (select(has("kind")) | .kind | enum_problem(["instruction", "secret"]) | "\($loc).kind: \(.); expected instruction or secret"),
		  (select(has("location")) | .location | one_line_problem | "\($loc).location: \(.); expected \(found_location_expected)"),
		  (select(has("text")) | .text | one_line_problem | "\($loc).text: \(.); expected what the text says, or the kind of secret with a masked preview, \(one_line_expected)")
	end;

def key_problems:
	(keys - list_keys)[] as $key
	| if $key | among(stamp_keys) then "\($key): written into the report; expected it left out: report.sh check --dispatch stamps \(stamp_keys | names) on a pass, and a stamped report is never checked again"
	  elif $key | among(never_written_keys) then "\($key): written into the report; expected it left out: \(never_written_reason)"
	  else "\($key | shown): unknown key; expected only \(list_keys | names)" end;
def item_problems($key; $loc; $files):
	if $key == "findings" then finding_problems($loc; $files)
	elif $key == "previous_findings" then previous_item_problems($loc; $files)
	elif $key == "flags" then flag_problems($loc)
	elif $key == "not_reviewed" then not_reviewed_problems($loc)
	else found_problems($loc) end;
def list_problems($key; $files):
	select(has($key))
	| if (.[$key] | type) != "array" then "\($key): a JSON \(.[$key] | type); expected an array of objects"
	  elif $key == "previous_findings" and $prior_mode == "none" then empty
	  elif (list_caps[$key] // null) != null and (.[$key] | length) > list_caps[$key] then
		"\($key): \(.[$key] | length) items; expected at most \(list_caps[$key]) items"
	  else .[$key] | to_entries[] | .key as $index | .value | item_problems($key; "\($key)[\($index)]"; $files) end;

def objects_of($key): .[$key] | if type == "array" then map(select(type == "object")) else [] end;
def found_of($kind): [objects_of("found")[] | select(.kind == $kind)] | length;
def count_line:
	"findings=\(objects_of("findings") | length) previous_findings=\(objects_of("previous_findings") | length) flags=\(objects_of("flags") | length) not_reviewed=\(objects_of("not_reviewed") | length) instruction_found=\(found_of("instruction")) secret_found=\(found_of("secret"))";

def all_problems:
	diff_files as $files
	| [key_problems, (list_keys[] as $key | list_problems($key; $files)), previous_set_problems];
def problems:
	all_problems
	| .[:max_problems] + (if length > max_problems then ["report: \(length - max_problems) more problems not shown (showing \(max_problems) of \(length)); expected none"] else [] end);

$report[0] | count_line, problems[]
'

# The stamps, on a passing check --dispatch: the lens on every finding, then the
# dispatch keys and finished at the top level. dispatch-names.jq (-L its folder)
# holds the stamp shapes; a stamp of another shape stops the write.
# shellcheck disable=SC2016
readonly STAMP_JQ='
include "dispatch-names";
if ($stamps.dispatch | test(crucible_id_pattern)) and ($stamps.started | test(local_time_pattern)) and ($finished | test(local_time_pattern))
then (if has("findings") then .findings |= map(. + {plugin: $lens}) else . end) + $stamps + {finished: $finished}
else error("a stamp has the wrong shape: dispatch \($stamps.dispatch | tojson), started \($stamps.started | tojson), finished \($finished | tojson)") end
'

usage() {
	cat <<'EOF'
usage: report.sh check --dispatch FILE --diff FILE [--report PATH] [--prior FILE] [--skills-dir DIR]
       report.sh check --report PATH --diff FILE [--prior FILE] [--skills-dir DIR]
       report.sh --help | -h
No arguments: this usage on stderr, exit 2.

Checks the reviewer's report for one review round, one JSON object in the
file PATH, and on a pass with --dispatch stamps the lens and the dispatch
keys into it. stdin is never read. The validator in this script owns the
shape; there is no schema file. This --help and the report standard's field
table document it, and the validator wins where they differ. It renders
nothing, stamps no ID or round and computes no verdict.

Options (every path absolute):
  --dispatch FILE  the dispatch file generate-agent-dispatch.sh wrote for
                   agent code-reviewer: a regular file, not a symlink,
                   passing DIR/flow-agent-initialization/scripts/04-agent-
                   dispatch/agent-dispatch-validator.jq; another agent's
                   dispatch is a dispatch fault. It supplies --report (its
                   report): leave --report out, or give the same text.
  --report PATH    the report file.
  --diff FILE      the DIFF the reviewer was given, unified git diff output;
                   required, since the dispatch does not carry it yet. Its
                   file list: the path of every "+++ b/<path>" header and,
                   for a deletion, of its "--- a/<path>" header, a/ and b/
                   stripped, /dev/null ignored. A quoted path, such as
                   "b/a b.sh" or "b/caf\303\251.sh", is decoded from git's
                   C-style quoting (\NNN octal bytes read as UTF-8, \a \b
                   \t \n \v \f \r \" \\); one that does not decode is
                   listed as written, quotes and escapes included. Headers
                   count only at the file start or after a "diff " line, up
                   to the first "@@", as git writes them, so a diff without
                   "diff " lines gives only its first file. A pure rename, a mode-only change
                   and a binary change have no +++ header, so their files
                   are not in the list: a location on one needs relates_to.
                   A leading ./ on a location's file is ignored.
  --prior FILE     a re-review's prior finding IDs, one per line, each
                   trimmed of surrounding spaces, blank lines ignored, a
                   repeated ID counted once. Without it, previous_findings
                   is refused. An argument, like --diff, since the dispatch
                   does not carry the prior IDs yet.
  --skills-dir DIR defaults to ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills;
                   read and held to absolute (the default included) only
                   with --dispatch, ignored without it.

The lens: the one plugin of the dispatch whose name starts tech- or
standard-; procedure-* plugins are not lenses. None: the lens is
correctness. More than one: a dispatch fault (one lens per dispatch).

Rules the validator enforces (a value shown in a problem is cut at 60
characters):
  - top-level keys only findings, previous_findings, flags, not_reviewed and
    found, each an array; verdict, count, counts, summary, round, date,
    generated, status, ack, waiver and waived are refused by name, here and
    on a finding. The stamp keys tech, plugins, mode, dispatch, started and
    finished are refused by name here (a stamped report is never checked
    again); on a finding they are refused as unknown keys
  - findings: severity (CRITICAL, HIGH, MEDIUM or LOW), realism (realistic,
    edge-case or hypothetical), locations (non-empty), trigger, problem and
    fix required; proof, real_if and security optional; id and plugin refused
    by name. edge-case needs proof, hypothetical needs real_if, realistic
    takes neither. security is true when present; a security: true
    hypothetical finding needs proof
  - a location (findings, previous_findings, flags, not_reviewed) is
    {file, line, relates_to?}: file with a non-space character and no
    control character, repo-relative, never absolute (/, ~ or a drive
    letter), no .. segment, at most 300 characters; line a positive
    integer or "N-M" with 1 <= N <= M; relates_to a path:line. Each location's
    file on a finding or an OPEN entry is in the DIFF file list, or its
    relates_to path is
  - one line (no newline or carriage return), a non-space character, at
    most 200 characters: trigger, problem, fix, real_if, a flag's text, a
    not_reviewed text, a previous_findings note, a found text and a found
    location. proof and relates_to: <path>:<N> or <path>:<N-M>, repo-relative,
    the path at most 300 characters
  - with --prior: previous_findings holds each prior ID exactly once and no
    other ID, an id non-empty, with no control character, at most 40
    characters; keys id, status, proof, note, severity, realism, real_if and
    locations; status RESOLVED (needs proof; refuses severity, realism,
    real_if and locations) or OPEN (needs note; a realism given pairs with
    proof or real_if as on a finding)
  - flags: exactly source (code or non-code), location, severity (CRITICAL
    or HIGH) and text; fix, trigger and proof refused by name
  - not_reviewed: text required, location and plugin (a non-empty name
    with no control character, at most 100 characters) optional
  - found: exactly kind (instruction or secret), location and text; the
    location's form is not checked: a repo-relative path:line, message:
    <FIELD>, a plugin name and file, a context entry (paths[<n>], links[<n>]
    or its URL), a URL, or commit <sha>
  - at most 200 findings, 100 flags, 100 not_reviewed and 100 found items,
    and 20 locations on a finding or an OPEN entry; previous_findings is
    bounded by the prior IDs; an empty list is accepted. A list over its
    cap, a locations list included, gets one problem line, and its items
    are not checked. Every line number, in line (an integer or N-M), proof
    or relates_to, has 1 to 9 digits

Stamping, on a passing check --dispatch only: each finding gets plugin, the
lens; the top level gets tech, plugins (the dispatch's plugin names), mode,
dispatch (its id), started, and finished (the local time the check passed);
times are YYYY-MM-DDTHH:MM:SS+HH:MM. The report as checked is read once into
a temp file, stamped, written to a temp file beside PATH (its permissions
copied) and moved onto PATH. Any other exit leaves the file byte for byte as
it was.

stdout, one line, on exits 0, 3 and 6:
  findings=<n> previous_findings=<n> flags=<n> not_reviewed=<n> instruction_found=<n> secret_found=<n>
stderr, by exit (nothing on 0):
  2  the usage, on no arguments; else "report.sh: <what>; expected <x>"
     then "Try 'report.sh --help'."; a
     dispatch fault is one "report.sh: dispatch: <what>" line, after one
     "report.sh: dispatch: <problem>" line per dispatch validator problem
  3  one line per problem, "<field>: <what>; expected <x>", at most 30,
     then "report: <n> more problems not shown (showing 30 of <m>);
     expected none"
  4  "report.sh: not a report: <what>; expected <x>"
  5  "report.sh: install: <what>; expected <x>"
  6  "report.sh: stamps not written, the report unchanged: <what>; expected
     <x>"
A failing tool (mktemp, cp, mv, jq or date) may print its own line first.

Writes: on a passing check --dispatch, the stamped report onto PATH through
a temp file beside it, and nothing else; a temp folder under TMPDIR
(default /tmp), removed on every exit, as is the temp file when it was not
moved onto PATH.

Exit codes:
  0  valid (stamped, with --dispatch)
  2  usage error: no arguments, an unknown command or argument, a missing
     value, a path not absolute (DIR only with --dispatch), neither
     --report nor --dispatch given, --diff not given, a --diff or --prior
     that is not a readable regular file, a --prior holding no ID, a
     --report that differs from the dispatch's; or a dispatch fault, stderr
     starting "report.sh: dispatch:": the file missing, a symlink, not
     JSON, failing the dispatch validator (each problem named), for an
     agent other than code-reviewer, or loading more than one lens
  3  invalid (stderr names each problem); nothing written
  4  not a report: PATH missing, unreadable, not JSON or not one object;
     with --dispatch also a symlink
  5  install fault, stderr starting "report.sh: install:": jq missing,
     failing --version, older than 1.6 or failing to run the check, a base
     tool missing, no temp folder made under TMPDIR (default /tmp), or, for
     --dispatch, the dispatch validator or dispatch-names.jq missing or the
     validator failing to run
  6  valid, but the stamps could not be written; the report is unchanged
     and stderr names the step that failed
  129, 130, 143  stopped by HUP, INT or TERM; temp files are removed

Dependencies: POSIX sh, jq 1.6+ (macOS: brew install jq; Linux: the distro's
jq), the base tools cat, cp, date (+%z), grep, mktemp, mv, rm and sed (in every
macOS and Linux base system); for --dispatch, the flow-agent-
initialization skill's agent-dispatch-validator.jq and dispatch-names.jq
under DIR. Checked after the arguments parse; a missing one exits 5 and
names it.
Runtime: about 50 ms for check and 90 ms for check --dispatch on a small
report, and about 70 ms for check on a report at every list cap, measured
on macOS (average of 5 runs).
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

dispatch_fault() {
	warn "dispatch: $1"
	exit 2
}

not_a_report() {
	warn "not a report: $1"
	exit 4
}

install_fault() {
	warn "install: $1"
	exit 5
}

stamp_fault() {
	warn "stamps not written, the report unchanged: $1"
	exit 6
}

# Sets the option values from the arguments; exits 0 on --help, 2 on a usage
# error.
parse_args() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		check) ;;
		*) usage_error "unknown command: $1; expected check or --help" ;;
	esac
	shift
	report='' dispatch_file='' diff_file='' prior_file=''
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills"
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--report | --dispatch | --diff | --prior | --skills-dir)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				set_option "$1" "$2"
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected --dispatch, --report, --diff, --prior or --skills-dir" ;;
		esac
	done
}

set_option() {
	case $1 in
		--report) report=$2 ;;
		--dispatch) dispatch_file=$2 ;;
		--diff) diff_file=$2 ;;
		--prior) prior_file=$2 ;;
		*) skills_dir=$2 ;;
	esac
}

# Exits 2 unless path $2, given to option $1, is absolute.
require_absolute() {
	case $2 in
		/*) ;;
		*) usage_error "$1 $2 is not absolute; expected an absolute path" ;;
	esac
}

check_paths() {
	[ -z "${dispatch_file}" ] || require_absolute --dispatch "${dispatch_file}"
	[ -z "${report}" ] || require_absolute --report "${report}"
	[ -z "${prior_file}" ] || require_absolute --prior "${prior_file}"
	# Only --dispatch reads DIR, so only it holds DIR (default included) to absolute.
	[ -z "${dispatch_file}" ] || require_absolute --skills-dir "${skills_dir}"
	[ -n "${report}" ] || [ -n "${dispatch_file}" ] ||
		usage_error '--report PATH missing; expected the absolute path of the report file, or --dispatch FILE'
	[ -n "${diff_file}" ] ||
		usage_error '--diff FILE missing; expected the DIFF the reviewer was given (the dispatch does not carry it yet)'
	require_absolute --diff "${diff_file}"
	[ -f "${diff_file}" ] && [ -r "${diff_file}" ] ||
		usage_error "--diff file not readable: ${diff_file}; expected the unified diff the reviewer was given, a regular file"
	[ -z "${prior_file}" ] || check_prior_file
}

check_prior_file() {
	[ -f "${prior_file}" ] && [ -r "${prior_file}" ] ||
		usage_error "--prior file not readable: ${prior_file}; expected a file with one prior finding ID per line"
	grep -q '[^[:space:]]' "${prior_file}" ||
		usage_error "--prior file holds no ID: ${prior_file}; expected one prior finding ID per line, or --prior left out on a first round"
}

check_jq() {
	command -v jq >/dev/null 2>&1 || install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || install_fault 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) install_fault "jq is ${jq_version}; expected jq 1.6+ (--rawfile, \$ARGS); try upgrading jq" ;;
	esac
}

check_base_tools() {
	for tool in cat cp date grep mktemp mv rm sed; do
		command -v "${tool}" >/dev/null 2>&1 && continue
		case ${tool} in
			grep | sed) package=${tool} ;;
			*) package=coreutils ;;
		esac
		install_fault "${tool} missing; expected ${tool} on PATH, part of every macOS and Linux base system; try restoring PATH (macOS: /usr/bin) or installing the distro ${package} package"
	done
}

# Sets names_dir to the folder of the dispatch validator and dispatch-names.jq;
# exits 5 when either is missing.
locate_dispatch_modules() {
	names_dir="${skills_dir}/${DISPATCH_DIR}"
	validator="${names_dir}/agent-dispatch-validator.jq"
	[ -f "${validator}" ] && [ -r "${validator}" ] ||
		install_fault "dispatch validator missing; expected ${validator}; install the flow-agent-initialization skill in ${skills_dir}"
	[ -f "${names_dir}/dispatch-names.jq" ] && [ -r "${names_dir}/dispatch-names.jq" ] ||
		install_fault "the shared dispatch names are missing; expected ${names_dir}/dispatch-names.jq; install the flow-agent-initialization skill in ${skills_dir}"
}

# Checks the --dispatch file, takes --report from it and sets lens and stamps
# (the five stamps it supplies; finished comes at the pass). Exits 2 on a bad
# file, another agent's dispatch or a conflicting --report, 5 when the
# validator fails to run.
read_dispatch() {
	dispatch_expected='expected the dispatch file generate-agent-dispatch.sh wrote'
	[ ! -L "${dispatch_file}" ] || dispatch_fault "${dispatch_file} is a symlink; ${dispatch_expected}, not a link to it"
	[ -f "${dispatch_file}" ] && [ -r "${dispatch_file}" ] ||
		dispatch_fault "${dispatch_file} is missing, unreadable or not a regular file; ${dispatch_expected}"
	jq -s 'length' "${dispatch_file}" </dev/null >/dev/null 2>&1 ||
		dispatch_fault "${dispatch_file} is not JSON; ${dispatch_expected}"
	dispatch_problems=$(jq -rs -f "${validator}" "${dispatch_file}" </dev/null) ||
		install_fault "the dispatch validator failed to run: ${validator}; expected jq 1.6+ and dispatch-names.jq beside it; try reinstalling flow-agent-initialization"
	if [ -n "${dispatch_problems}" ]; then
		printf '%s\n' "${dispatch_problems}" | sed "s/^/${PROG}: dispatch: /" >&2
		dispatch_fault "${dispatch_file} fails the dispatch validator, each problem above; ${dispatch_expected}, unchanged since"
	fi
	# The validator holds agent to a known agent name, so it prints on one line.
	dispatch_agent=$(jq -r '.agent' "${dispatch_file}" </dev/null) ||
		dispatch_fault "${dispatch_file} cannot be read; ${dispatch_expected}"
	[ "${dispatch_agent}" = "${REVIEWER_AGENT}" ] ||
		dispatch_fault "${dispatch_file} is a dispatch of agent ${dispatch_agent}; expected a ${REVIEWER_AGENT} dispatch, whose report this checks; try the ${dispatch_agent}'s own report.sh"
	# The validator holds report to an absolute path without a control character.
	dispatch_report=$(jq -r '.report' "${dispatch_file}" </dev/null) ||
		dispatch_fault "${dispatch_file} cannot be read; ${dispatch_expected}"
	[ -z "${report}" ] || [ "${report}" = "${dispatch_report}" ] ||
		usage_error "--report ${report} differs from the dispatch's report ${dispatch_report}; expected --report left out, or the same text"
	report=${dispatch_report}
	read_lens
	stamps=$(jq -c '{tech, plugins: [.plugins[].name], mode, dispatch: .id, started}' "${dispatch_file}" </dev/null) ||
		dispatch_fault "${dispatch_file} cannot be read; ${dispatch_expected}"
}

# Sets lens to the dispatch's one tech-* or standard-* plugin, or to NO_LENS
# when it loads none; exits 2 when it loads more than one.
read_lens() {
	lens_names=$(jq -r '[.plugins[].name | select(startswith("tech-") or startswith("standard-"))]
		| if length > 1 then "many \(map(tojson) | join(", "))" elif length == 1 then "one \(.[0])" else "none" end' \
		"${dispatch_file}" </dev/null) ||
		dispatch_fault "${dispatch_file} cannot be read; ${dispatch_expected}"
	case ${lens_names} in
		none) lens=${NO_LENS} ;;
		one\ *) lens=${lens_names#one } ;;
		*) dispatch_fault "${dispatch_file} loads more than one lens, ${lens_names#many }; expected one tech-* or standard-* plugin per review dispatch, or none for the correctness seat" ;;
	esac
}

# Makes the temp folder the run uses, removed on exit with any stamp temp file.
make_work_dir() {
	stamp_tmp=''
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/report-sh.XXXXXX") || install_fault 'mktemp -d failed; expected a writable TMPDIR'
	trap 'rm -rf "${work_dir}"; [ -z "${stamp_tmp}" ] || rm -f "${stamp_tmp}"' EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

# Copies the report file once to report_copy, which the check and the stamps
# both read, so what is stamped is what was checked. Exits 4 unless it holds
# exactly one JSON object (or, with --dispatch, when it is a symlink).
check_report() {
	report_expected='expected the file the first message'"'"'s REPORT names'
	[ -z "${dispatch_file}" ] || [ ! -L "${report}" ] ||
		not_a_report "${report} is a symlink; expected the report file itself, which check --dispatch stamps"
	[ -f "${report}" ] && [ -r "${report}" ] ||
		not_a_report "${report} is missing, unreadable or not a regular file; ${report_expected}"
	report_copy="${work_dir}/report"
	cat "${report}" >"${report_copy}" || not_a_report "${report} cannot be read; ${report_expected}"
	shape=$(jq -rs 'if length == 1 and (.[0] | type) == "object" then "object" elif length == 1 then "a JSON \(.[0] | type)" else "\(length) values" end' "${report_copy}" </dev/null 2>/dev/null) ||
		not_a_report "${report} is not valid JSON; expected one JSON object and nothing around it; try checking for prose, quotes, commas and brackets"
	[ "${shape}" = object ] || not_a_report "${report} holds ${shape}; expected exactly one JSON object"
}

# Prints the count line on stdout and the problems on stderr; exits 3 on a
# problem, else stamps when --dispatch was given.
run_check() {
	if [ -n "${prior_file}" ]; then
		set -- --rawfile prior_text "${prior_file}" --arg prior_mode given
	else
		set -- --arg prior_text '' --arg prior_mode none
	fi
	output=$(jq -nr --slurpfile report "${report_copy}" --rawfile diff_text "${diff_file}" "$@" "${CHECK_JQ}" </dev/null) ||
		install_fault 'jq failed on a valid JSON report; expected jq 1.6+; try jq --version'
	count_line=$(printf '%s\n' "${output}" | sed -n '1p')
	problems=$(printf '%s\n' "${output}" | sed '1d')
	printf '%s\n' "${count_line}"
	if [ -n "${problems}" ]; then
		printf '%s\n' "${problems}" >&2
		exit 3
	fi
	[ -z "${dispatch_file}" ] || write_stamps
}

# Writes report_copy plus the stamps onto the report file through a temp file
# beside it. Exits 6 when a step fails, the report unchanged.
write_stamps() {
	date_expected='expected date +%Y-%m-%dT%H:%M:%S%z to print the local time; try it by hand'
	raw_time=$(date +%Y-%m-%dT%H:%M:%S%z) || stamp_fault "date failed; ${date_expected}"
	case ${raw_time} in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]) ;;
		*) stamp_fault "date printed ${raw_time}; ${date_expected}" ;;
	esac
	# The dispatch's started form: the offset as +HH:MM.
	finished="${raw_time%??}:${raw_time#"${raw_time%??}"}"
	report_dir=${report%/*}
	stamp_tmp=$(mktemp "${report_dir:-/}/.report-stamps.XXXXXX") ||
		stamp_fault "mktemp failed in ${report_dir:-/}; expected the report's folder writable"
	cp -p "${report}" "${stamp_tmp}" || stamp_fault "cp -p ${report} failed; expected the report's permissions copied to ${stamp_tmp}"
	jq -L "${names_dir}" --argjson stamps "${stamps}" --arg lens "${lens}" --arg finished "${finished}" "${STAMP_JQ}" "${report_copy}" </dev/null >"${stamp_tmp}" ||
		stamp_fault "jq failed writing ${stamp_tmp}; expected the stamped report written; try jq --version"
	mv -f "${stamp_tmp}" "${report}" || stamp_fault "mv onto ${report} failed; expected the stamped report moved into place"
	stamp_tmp=''
}

parse_args "$@"
check_jq
check_base_tools
check_paths
if [ -n "${dispatch_file}" ]; then
	locate_dispatch_modules
	read_dispatch
fi
make_work_dir
check_report
run_check
