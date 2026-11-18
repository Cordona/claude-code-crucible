# The session file's shape: the one definition metrics.sh checks every file
# against. A module: load it with jq -L <this folder> and include
# "metrics-validator". Each check reads the parsed file and prints one
# "<field> <problem>; expected <x>" line per problem, nothing when it fits.
# metrics_session_problems holds every rule, for a file about to be written.
# metrics_session_shape_problems holds only the shape the view and an expired
# file's re-mark rely on, for a file read back: a file written under looser
# rules stays readable when a write-only rule tightens, since an expired
# session's file cannot be rebuilt.
# The file holds a UTC time, names, numbers and true flags only, never a null and
# never text copied from a transcript beyond an agent name.

# harvested_at: the view shows an expired file's own harvest time; every other
# file it reads was written by the same run.
# expired: the transcript, or a launched subagent's, is gone, so the figures
# are those of the file's last harvest.
def metrics_fields: ["harvested_at", "expired", "main_thread", "subagents", "outside"];
def metrics_required_fields: ["harvested_at", "main_thread", "subagents", "outside"];
def metrics_kinds: ["input", "output", "cache_read", "cache_write"];
# unreliable: an output figure is a placeholder Claude Code left unfinished.
def metrics_sum_fields: ["unreliable"] + metrics_kinds;
# running: the subagent was unfinished at harvest.
def metrics_agent_fields: ["agent", "running", "unreliable"] + metrics_kinds;
# Each list of the file: its field, its entries' fields and the name fields
# among them.
def metrics_lists: [["main_thread", metrics_sum_fields, []], ["subagents", metrics_agent_fields, ["agent"]],
	["outside", metrics_sum_fields, []]];
def metrics_utc_pattern: "\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z";
# An agent name: a short word of letters, digits and . _ : @ / -,
# so no free text from a transcript reaches the file.
def metrics_name_pattern: "\\A[A-Za-z0-9][A-Za-z0-9._:@/-]{0,79}\\z";

def metrics_is_name: type == "string" and test(metrics_name_pattern);

# A value from the file quoted as JSON and cut, so a problem stays one short line.
def metrics_shown: tojson | if length > 60 then .[:60] + "…" else . end;

# Each entry of the file's lists, as {where, fields, names, entry}.
def metrics_entries:
	. as $file
	| metrics_lists[] as [$field, $fields, $names]
	| $file[$field] | select(type == "array") | to_entries[]
	| {where: "\($field)[\(.key)]", fields: $fields, names: $names, entry: .value};

def metrics_count_problem($where; $kind):
	if type == "number" and . >= 0 and . == floor then empty
	else "\($where).\($kind) is \(metrics_shown); expected a whole number of tokens, 0 or more" end;

# A flag on a file read back may be true or false; false is a write-only ban.
def metrics_flag_shape_problem($where; $flag):
	if has($flag) and (.[$flag] | type) != "boolean" then "\($where + $flag) is \(.[$flag] | metrics_shown); expected true, or no \($flag) field"
	else empty end;

def metrics_flag_write_problem($where; $flag):
	if has($flag) and .[$flag] == false then "\($where + $flag) is false; expected true, or no \($flag) field" else empty end;

def metrics_entry_shape_problems:
	.where as $where | .names as $names | .fields as $fields
	| .entry
	| if type != "object" then "\($where) is a JSON \(type); expected an object"
	  else (($names + metrics_kinds - keys_unsorted)[] | "\($where).\(.) is missing; expected \($names + metrics_kinds | join(", "))"),
		(. as $entry | $names[] as $name | select($entry | has($name)) | $entry[$name]
			| if type == "string" then empty else "\($where).\($name) is \(metrics_shown); expected a name" end),
		(. as $entry | metrics_kinds[] as $kind | select($entry | has($kind)) | $entry[$kind] | metrics_count_problem($where; $kind)),
		(($fields - $names - metrics_kinds)[] as $flag | metrics_flag_shape_problem("\($where)."; $flag))
	  end;

def metrics_entry_write_problems:
	.where as $where | .names as $names | .fields as $fields
	| .entry
	| select(type == "object")
	| ((keys_unsorted - $fields)[] | "\($where): \(metrics_shown) is an unknown field; expected only \($fields | join(", "))"),
		(. as $entry | $names[] as $name | $entry[$name] | strings
			| if metrics_is_name then empty
			  else "\($where).\($name) is \(metrics_shown); expected a name of letters, digits and . _ : @ / -, up to 80 characters" end),
		(($fields - $names - metrics_kinds)[] as $flag | metrics_flag_write_problem("\($where)."; $flag));

# The harvest time is the file's format, not a cap, so a file read back must
# still match it.
def metrics_session_shape_problems:
	if type != "object" then "the file is a JSON \(type); expected an object"
	else ((metrics_required_fields - keys_unsorted)[] | "\(.) is missing; expected the fields \(metrics_required_fields | join(", "))"),
		(if has("harvested_at") | not then empty
		 elif (.harvested_at | type) == "string" and (.harvested_at | test(metrics_utc_pattern)) then empty
		 else "harvested_at is \(.harvested_at | metrics_shown); expected a UTC time YYYY-MM-DDTHH:MM:SSZ" end),
		metrics_flag_shape_problem(""; "expired"),
		(. as $file | metrics_lists[][0] as $field | select($file | has($field)) | $file[$field]
			| if type == "array" then empty else "\($field) is \(metrics_shown); expected an array" end),
		(metrics_entries | metrics_entry_shape_problems)
	end;

def metrics_session_write_problems:
	select(type == "object")
	| ((keys_unsorted - metrics_fields)[] | "\(metrics_shown) is an unknown field; expected only \(metrics_fields | join(", "))"),
		metrics_flag_write_problem(""; "expired"),
		(metrics_entries | metrics_entry_write_problems);

def metrics_session_problems: metrics_session_shape_problems, metrics_session_write_problems;
