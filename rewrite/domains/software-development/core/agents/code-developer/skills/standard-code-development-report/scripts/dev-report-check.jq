# The developer's BUILD report: its keys, each list's item keys, and the
# checks on a parsed report and the path:line locations it points at. A
# module: load it with jq -L <this folder> and include "dev-report-check".
# report_locations lists the relative paths of the report's well-formed
# path:line locations, for the shell to look up in the worktree;
# report_problems prints a list of "<field> <problem>; <how to fix>" lines,
# empty when the report fits. Each line is all the developer sees, so it
# names the field, the fault and the repair.

def report_keys: ["summary", "verification", "deviations", "decisions", "noticed", "security", "open", "blockers", "answers"];
# Keys another report or an earlier contract had, and why they are not written.
def report_derived_keys: {
	"files": "git gives the files",
	"toolchain": "the build files give it",
	"plugins": "the commit trailers give them",
	"mode": "the commit kind gives it",
	"round": "the commit subject gives it",
	"dispatch": "the dispatch gives it",
	"started": "the dispatch gives it",
	"finished": "the commit date gives it",
	"effort": "seats.json gives it",
	"seat": "seats.json gives it",
	"agent_id": "seats.json gives it",
	"agent-id": "seats.json gives it",
	"base": "seats.json gives it",
	"behavior": "dropped from the contract",
	"focus": "dropped from the contract",
	"review_responses": "a fix round answers in answers"
};
# Each list's item keys, those always required, and the shape a line shows.
def report_lists: {
	"verification": {keys: ["gate", "result", "command", "note"], required: ["gate", "result"], shape: "{gate, result, command, note}"},
	"deviations": {keys: ["from", "what", "why"], required: ["from", "what", "why"], shape: "{from, what, why}"},
	"decisions": {keys: ["choice", "why"], required: ["choice", "why"], shape: "{choice, why}"},
	"noticed": {keys: ["at", "text"], required: ["at", "text"], shape: "{at, text}"},
	"security": {keys: ["kind", "at", "text"], required: ["kind", "at", "text"], shape: "{kind, at, text}"},
	"open": {keys: ["text", "at", "ref"], required: ["text"], shape: "{text, at, ref}"},
	"blockers": {keys: ["kind", "location", "detail"], required: ["kind", "location", "detail"], shape: "{kind, location, detail}"},
	"answers": {keys: ["id", "status", "notes"], required: ["id", "status", "notes"], shape: "{id, status, notes}"}
};
# Item keys an earlier contract had, and what to do instead.
def report_dropped_item_keys: {
	"open.kind": "refusing part of the task is a deviation; an open item has no kind",
	"decisions.commit": "the commit records itself",
	"answers.note": "the key is notes"
};
def report_gates: ["format", "lint", "typecheck", "test", "build", "scan", "manual"];
def report_results: ["pass", "fail", "not_run", "narrowed"];
def report_blocker_kinds: ["gate_red", "request_unclear", "test_compile_broken"];
def report_security_kinds: ["secret", "instruction"];
def report_answer_statuses: ["fixed", "blocked"];
# Characters (Unicode code points): the summary is the commit subject's text,
# and 56 keeps "crucible(dev): " and "crucible(test): " plus the summary within 72, whole in git's one-line views.
def report_summary_max: 56;
def report_text_max: 200;
def report_open_max: 8;
# Bounds a value echoed in a problem line, so the line stays readable.
def report_echo_max: 60;

def report_list: join(", ");
def report_trim: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
def report_is_empty: . == null or . == [] or . == {};
def report_echo: tojson | if length > report_echo_max then .[:report_echo_max - 3] + "..." else . end;
# A plain name as it is, anything else quoted and escaped onto one line.
def report_name: if test("^[A-Za-z0-9_.:-]{1,60}$") then . else report_echo end;
def report_shown: if length > report_echo_max then .[:report_echo_max - 3] + "..." else . end;
# "is missing" for an absent key, "is null" (or [] or {}) for an empty one.
def report_absence($key): if has($key) then "is \(.[$key] | tojson)" else "is missing" end;

# The problem of a one-line text of at most $max characters, or nothing.
def report_text_problem($max):
	if type != "string" then "is a JSON \(type); write it as a one-line string"
	elif test("[\n\r  ]") then "holds a line break; write it as one line"
	elif test("[[:cntrl:]]") then "holds a control character; remove it"
	elif (report_trim | length) == 0 then "is blank; write one line of text"
	elif (report_trim | length) > $max then "has \(report_trim | length) characters; shorten it to at most \($max)"
	else empty
	end;

def report_text_fits: [report_text_problem(report_text_max)] == [];

def report_enum_problem($values; $what):
	if IN($values[]) then empty
	else "\(report_echo) is not a known \($what); use one of \($values | report_list)"
	end;

# The command with its quoted parts and backslash escapes removed, so only
# what the shell would act on is left.
def report_unquoted: gsub("'[^']*'|\"(\\\\.|[^\"\\\\])*\"|\\\\."; "");

def report_command_problem:
	if report_unquoted | test("&&|\\|\\||;") then
		"chains commands with &&, || or ; outside quotes; give each command its own verification item"
	else empty
	end;

def report_is_url: test("^[A-Za-z][A-Za-z0-9+.-]*://");
def report_is_location: (report_is_url | not) and test(":-?[0-9]+$");
def report_split_location: capture("^(?<path>.*):(?<line>-?[0-9]+)$") | .line |= tonumber;

# The problem of a split location's own form, before the worktree is asked.
def report_path_problem:
	if .path == "" then "has no path before the colon; write path:line relative to the worktree, e.g. src/App.kt:12"
	elif .path | startswith("/") then "is an absolute path; write it relative to the worktree root, e.g. src/App.kt:12"
	elif .path | split("/") | any(.[]; . == "..") then "leaves the worktree with ..; write the path from the worktree root without .."
	elif .line < 1 then "has line \(.line); lines count from 1"
	else empty
	end;

# $files: {path: {status, lines}} as the shell found each path in the worktree.
def report_file_problem($files):
	$files[.path] as $file
	| if $file == null then "could not be looked up in the worktree; point at a file inside it"
	elif $file.status == "missing" then "names no file in the worktree; give the path, from the worktree root, of a file that exists"
	elif $file.status == "folder" then "names a folder; point at a file in it"
	elif $file.status == "link" then "is a symbolic link; point at the file it links to"
	elif $file.status == "outside" then "resolves outside the worktree; point at a file inside it"
	elif $file.status == "special" then "is not a regular file; point at a source file"
	elif $file.status == "unreadable" then "names a file this check cannot read; point at a readable file"
	elif .line > $file.lines then "is past the end of the file (\($file.lines) lines); point at a line that exists"
	else empty
	end;

def report_location_problem($files): report_split_location | report_path_problem // report_file_problem($files);

# A noticed, security or open at: always path:line.
def report_at_problem($files):
	if report_is_location then report_location_problem($files)
	else "is not path:line; write the file's path from the worktree root and a line number, e.g. src/main/App.kt:42"
	end;

# A location that is a path:line when it looks like one, and free text otherwise.
def report_maybe_location_problem($files): if report_is_location then report_location_problem($files) else empty end;

# The well-formed relative paths of every path:line location, once each.
def report_locations:
	if type != "object" then empty
	else
		[((.noticed, .security, .open | arrays | .[] | objects | .at),
			(.deviations | arrays | .[] | objects | .from),
			(.blockers | arrays | .[] | objects | .location))
		| strings | select(report_text_fits and report_is_location)
		| report_split_location | select([report_path_problem] == []) | .path]
		| unique[]
	end;

# What to add for item key $key of list $list; $item gives a note its result.
def report_hint($list; $key; $item):
	{
		"verification.gate": "add the gate: one of \(report_gates | report_list)",
		"verification.result": "add the result: one of \(report_results | report_list)",
		"verification.command": "add the one command you ran, e.g. \"./gradlew test --offline\"",
		"verification.note": (if $item.result == "fail" then "add a note saying what failed, e.g. \"App.kt:12 unresolved reference\""
			elif $item.result == "narrowed" then "add a note quoting the task's words that told you to skip the gate"
			else "add a note saying why the gate was \($item.result), e.g. \"ktlint not installed\""
			end),
		"deviations.from": "add where you departed from: message: TASK, the context entry, or path:line",
		"deviations.what": "add what you did differently, in one line",
		"deviations.why": "add why, in one line",
		"decisions.choice": "add the choice you made, in one line",
		"decisions.why": "add why, in one line",
		"noticed.at": "add the path:line it is at, from the worktree root, e.g. src/App.kt:12",
		"noticed.text": "add what you noticed, in one line",
		"security.kind": "add the kind: one of \(report_security_kinds | report_list)",
		"security.at": "add the path:line it is at, from the worktree root, e.g. src/App.kt:12",
		"security.text": "add what it is, in one line, a secret masked, e.g. \"A live API key is hard-coded (sk-****)\"",
		"open.text": "add what you need, in one line",
		"blockers.kind": "add the kind: one of \(report_blocker_kinds | report_list)",
		"blockers.location": "add where: path:line from the worktree root, message: TASK, or a URL",
		"blockers.detail": "add what stops the work, in one line",
		"answers.id": "add the chosen concern id this answers",
		"answers.status": "add the status: fixed or blocked",
		"answers.notes": "add notes saying what you did or why not"
	}["\($list).\($key)"];

# The keys an item must hold: verification's command and note follow its result.
def report_required_keys($list; $rule):
	$rule.required + (if $list != "verification" then []
		elif .result == "pass" then ["command"]
		elif .result == "fail" then ["command", "note"]
		elif .result == "not_run" or .result == "narrowed" then ["note"]
		else []
		end);

# The problems of a text that fits: enums, the command, and locations, which
# show their value (one line, by then) ahead of the fault.
def report_value_problems($list; $key; $files):
	(if $list == "open" then ", or drop at" else "" end) as $or_drop
	| if $key == "gate" then report_enum_problem(report_gates; "gate")
	elif $key == "result" then report_enum_problem(report_results; "result")
	elif $key == "kind" and $list == "security" then report_enum_problem(report_security_kinds; "security kind")
	elif $key == "kind" then report_enum_problem(report_blocker_kinds; "blocker kind")
	elif $key == "status" then report_enum_problem(report_answer_statuses; "status")
	elif $key == "command" then report_command_problem
	elif $key == "at" then
		(if report_is_location then report_shown else report_echo end) as $shown
		| report_at_problem($files) | "\($shown) \(.)\($or_drop)"
	elif $key == "from" or $key == "location" then
		report_shown as $shown | report_maybe_location_problem($files) | "\($shown) \(.)"
	else empty
	end;

def report_value_line($where; $list; $key; $files):
	[report_text_problem(report_text_max)] as $text
	| if $text != [] then "\($where) \($text[0])"
	else report_value_problems($list; $key; $files) | "\($where) \(.)"
	end;

def report_unknown_item_key($list; $where; $rule):
	report_dropped_item_keys["\($list).\(.)"] as $why
	| "\($where).\(report_name) is not a key of \($list) items; remove it\(if $why == null then "" else " (\($why))" end). Allowed: \($rule.keys | report_list)";

# . is {key: index, value: item}.
def report_item_problems($list; $rule; $files):
	.key as $index
	| .value as $item
	| "\($list)[\($index)]" as $where
	| if ($item | type) != "object" then
		"\($where) is \(if $item == null then "null" else "a JSON \($item | type)" end); write it as an object \($rule.shape)"
	else
		($item | report_required_keys($list; $rule)) as $required
		| ($item | keys_unsorted[] | select(IN($rule.keys[]) | not) | report_unknown_item_key($list; $where; $rule)),
		($required[] | select(. as $key | $item[$key] | report_is_empty)
			| . as $key | "\($where).\($key) \($item | report_absence($key)); \(report_hint($list; $key; $item))"),
		($item | to_entries[] | select(.key | IN($rule.keys[])) | .key as $key | .value
			| if report_is_empty then
				(if $key | IN($required[]) then empty
				else "\($where).\($key) is \(tojson); leave the key out when there is nothing to say"
				end)
			else report_value_line("\($where).\($key)"; $list; $key; $files)
			end)
	end;

def report_answer_shape($id): "{\"id\": \($id | tojson), \"status\": \"fixed\" or \"blocked\", \"notes\": \"<what you did or why not>\"}";

# A gate that did not run is still listed, so no made-up gate stands in for it.
def report_verification_fix:
	"add one item per gate, e.g. {\"gate\": \"test\", \"result\": \"pass\", \"command\": \"<the command>\"}; if none ran, add each that applies as {\"gate\": \"typecheck\", \"result\": \"not_run\", \"note\": \"the task said not to run commands\"}";

def report_chosen_list: report_list | if length > 100 then .[:97] + "..." else . end;

# The list $key as a whole: absent, empty, wrong type or round-refused, else each item.
def report_list_problems($key; $chosen; $files):
	report_lists[$key] as $rule
	| if has($key) | not then
		(if $key == "verification" then
			"verification is missing; \(report_verification_fix)"
		elif $key == "answers" and $chosen != null then
			"answers is missing; this is a fix round: add one \(report_answer_shape("<id>")) per chosen id: \($chosen | map(report_name) | report_chosen_list)"
		else empty
		end)
	elif $key == "answers" and $chosen == null then "answers belong only to a fix round; remove it"
	elif .[$key] | report_is_empty then
		(if $key == "verification" then
			"verification is \(.[$key] | tojson); \(report_verification_fix)"
		elif $key == "answers" then
			"answers is \(.[$key] | tojson); add one \(report_answer_shape("<id>")) per chosen id: \($chosen | map(report_name) | report_chosen_list)"
		else "\($key) is \(.[$key] | tojson); leave the key out when there is nothing to say"
		end)
	elif (.[$key] | type) != "array" then "\($key) is a JSON \(.[$key] | type); write it as a list of \($rule.shape) objects"
	else .[$key] | to_entries[] | report_item_problems($key; $rule; $files)
	end;

def report_unknown_key:
	report_derived_keys[.] as $why
	| "\(report_name) is not a report key; remove it\(if $why == null then "" else " (\($why))" end). Allowed keys: \(report_keys | report_list)";

# The commit message puts its own "crucible(dev): " in front of the summary,
# so a summary starting "word:" or "word(word):" would read as a second prefix.
def report_prefix_problem:
	(report_trim | capture("^(?<prefix>[A-Za-z][A-Za-z0-9_-]*(\\([^()]*\\))?!?:)").prefix) as $prefix
	| "starts with \($prefix | report_echo); drop the prefix and say what happened in plain words, as the commit adds its own";

def report_summary_problems:
	if (has("summary") | not) or (.summary | report_is_empty) then
		"summary \(report_absence("summary")); add one line of at most \(report_summary_max) characters saying what happened (it becomes the commit subject)"
	else .summary | (report_text_problem(report_summary_max) // report_prefix_problem) | "summary \(.)"
	end;

def report_open_cap_problems:
	if (.open | type) == "array" and (.open | length) > report_open_max then
		"open has \(.open | length) items; keep at most \(report_open_max): merge related items or drop the least important, never a secret or instruction"
	else empty
	end;

# Any fail needs a gate_red blocker, and a gate_red blocker needs a fail.
def report_gate_pairing_problems:
	[.verification | arrays | to_entries[] | select((.value | objects | .result) == "fail") | .key] as $fails
	| [.blockers | arrays | to_entries[] | select((.value | objects | .kind) == "gate_red") | .key] as $reds
	| if $fails != [] and $reds == [] then
		"verification[\($fails[0])].result is fail but blockers has no gate_red item; add {\"kind\": \"gate_red\", \"location\": \"<path:line or message: TASK>\", \"detail\": \"<what stays red>\"}, or fix the gate and rerun it"
	elif $reds != [] and $fails == [] then
		$reds[] | "blockers[\(.)].kind is gate_red but no verification result is fail; add the red gate to verification with result fail, or remove this blocker"
	else empty
	end;

# A fix round's answers hold each chosen id exactly once and nothing else.
def report_answer_id_problems($chosen):
	if $chosen == null or (.answers | type) != "array" or (.answers | length) == 0 then empty
	else
		[.answers | to_entries[] | select(.value | type == "object")
			| {index: .key, id: (.value.id | strings | select(report_text_fits) | report_trim)}] as $given
		| ($given | map(.id)) as $ids
		| ($chosen[] | select(IN($ids[]) | not) | "answers lacks \(report_name); add \(report_answer_shape(.))"),
		($given[] | select(.id | IN($chosen[]) | not)
			| "answers[\(.index)].id \(.id | report_echo) was not chosen for this seat; remove that answer, and if you changed code for it, report that change in deviations with from \"message: FINDINGS\""),
		($ids | group_by(.) | map(select(length > 1))[] | "answers holds \(.[0] | report_name) \(length) times; keep one answer per id")
	end;

# $chosen: the fix round's chosen ids, or null on an iteration. $hint: where
# and in what shape the report is written, for a report that is no object.
def report_problems($chosen; $files; $hint):
	if type != "object" then ["the report is a JSON \(type); \($hint)"]
	else [
		(keys_unsorted[] | select(IN(report_keys[]) | not) | report_unknown_key),
		report_summary_problems,
		(report_keys[1:][] as $key | report_list_problems($key; $chosen; $files)),
		report_open_cap_problems,
		report_gate_pairing_problems,
		report_answer_id_problems($chosen)
	]
	end;

# $chosen_text: the --chosen file's text, one id per line; empty on an iteration.
def report_chosen($round; $chosen_text):
	if $round != "fix" then null
	else $chosen_text | split("\n") | map(report_trim | select(length > 0))
		| reduce .[] as $id ([]; if any(.[]; . == $id) then . else . + [$id] end)
	end;

# $files_text: one "status<TAB>lines<TAB>path" line per looked-up path.
def report_files($files_text):
	$files_text | split("\n") | map(select(length > 0) | split("\t")
		| {key: (.[2:] | join("\t")), value: {status: .[0], lines: (.[1] | tonumber)}})
	| from_entries;

# The problem lines of the raw report text, at most $max and a count of the rest.
def report_check($text; $round; $chosen_text; $files_text; $hint; $max):
	[$text | try fromjson] as $parsed
	| (if $parsed == [] then
		[if ($text | test("^[[:space:]]*$")) then "the report is empty; \($hint)"
		else "the report is not one valid JSON value; \($hint)"
		end]
	else $parsed[0] | report_problems(report_chosen($round; $chosen_text); report_files($files_text); $hint)
	end)
	| if length > $max then .[:$max] + ["\(length - $max) more problems not shown; fix the ones above and the check lists the rest"] else . end;
