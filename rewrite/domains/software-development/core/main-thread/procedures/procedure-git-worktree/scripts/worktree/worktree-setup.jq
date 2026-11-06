# The worktree setup data: what to copy into a fresh linked worktree, per
# technology. A module: load it with jq -L <this folder> and
# include "worktree-setup".
# setup_problems checks the parsed data file and the .worktreeinclude text and
# prints one "<where> <problem>; expected <x>" line per problem, nothing when
# both fit. setup_detect_names and setup_plan read data that fits.

def setup_fields: ["always", "technologies"];
def setup_always_fields: ["copy", "skip"];
def setup_technology_fields: ["name", "detect", "copy", "copy-every-dir-named", "copy-every-dir-containing", "repoint"];
def setup_dir_fields: ["copy-every-dir-named", "copy-every-dir-containing"];
def setup_list: join(", ");

# The problem of one path, or nothing. $form is "glob" (a root-relative path
# with * inside a segment), "path" (no glob) or "name" (one segment, no glob).
# ? [ ] and \ are refused so the shell can match a pattern with case and
# find -name without escaping.
def setup_path_problem($form):
	if type != "string" then "is a JSON \(type); expected a string"
	elif length == 0 then "is empty; expected a path"
	elif test("[[:cntrl:]]") then "holds a control character; expected printable text"
	elif startswith("/") then "is absolute; expected a root-relative path"
	elif test("[?\\[\\]\\\\]") then "holds ? [ ] or \\; expected no glob character but *"
	elif contains("**") then "holds **; expected * within one segment"
	elif $form != "glob" and contains("*") then "holds *; expected a plain path"
	elif $form == "name" and contains("/") then "holds /; expected one name"
	elif split("/") | any(. == "" or . == "." or . == "..") then "has an empty, . or .. segment; expected a normalized path"
	elif split("/") | any(. == ".git") then "has a .git segment; expected a path outside .git"
	else empty
	end;

# The problems of an array of paths at $where.
def setup_paths_problems($where; $form):
	if type != "array" then "\($where) is a JSON \(type); expected an array of strings"
	else to_entries[] | .value as $value | "\($where)[\(.key)]" as $item
		| $value | setup_path_problem($form) | "\($item) \($value | tojson) \(.)"
	end;

def setup_unknown_fields($where; $fields):
	keys_unsorted[] | select(IN($fields[]) | not)
	| "\($where) field \(tojson) is not known; expected only \($fields | setup_list)";

def setup_optional_paths($where; $field; $form):
	if has($field) then .[$field] | setup_paths_problems("\($where).\($field)"; $form) else empty end;

def setup_always_problems:
	if type != "object" then "always is a JSON \(type); expected an object of copy and skip"
	else setup_unknown_fields("always"; setup_always_fields),
		setup_optional_paths("always"; "copy"; "glob"),
		setup_optional_paths("always"; "skip"; "path")
	end;

def setup_name_problem($where):
	if has("name") | not then "\($where).name is missing; expected a technology name"
	elif (.name | type) != "string" or (.name | test("^[a-z0-9][a-z0-9._-]*$") | not) then
		"\($where).name \(.name | tojson) is not allowed; expected lowercase letters, digits, . _ or -"
	else empty
	end;

def setup_detect_problems($where):
	if has("detect") | not then "\($where).detect is missing; expected an array of root-relative paths"
	elif .detect == [] then "\($where).detect is empty; expected at least one root-relative path"
	else .detect | setup_paths_problems("\($where).detect"; "path")
	end;

# repoint rewrites inside the folders the dir fields found, so it needs one.
def setup_repoint_problem($where):
	. as $technology | if has("repoint") and (any(setup_dir_fields[]; . as $field | $technology | has($field)) | not) then
		"\($where).repoint is given without \(setup_dir_fields | join(" or ")); expected one of them"
	else empty
	end;

def setup_technology_problems:
	to_entries[] | "technologies[\(.key)]" as $where | .value
	| if type != "object" then "\($where) is a JSON \(type); expected an object"
	else setup_unknown_fields($where; setup_technology_fields),
		setup_name_problem($where),
		setup_detect_problems($where),
		setup_optional_paths($where; "copy"; "glob"),
		setup_optional_paths($where; "copy-every-dir-named"; "name"),
		setup_optional_paths($where; "copy-every-dir-containing"; "name"),
		setup_optional_paths($where; "repoint"; "path"),
		setup_repoint_problem($where)
	end;

# A name listed twice, or found both as a folder and as a file inside one,
# would make the owner of a found folder ambiguous.
def setup_clash_problems:
	[.[] | objects | .name | strings] as $names
	| ($names | group_by(.)[] | select(length > 1)[0]
		| "technology name \(tojson) is listed more than once; expected each once"),
	([.[] | objects | ."copy-every-dir-named" | arrays[] | strings] as $named
		| [.[] | objects | ."copy-every-dir-containing" | arrays[] | strings][]
		| select(IN($named[]))
		| "\(tojson) is in both copy-every-dir-named and copy-every-dir-containing; expected one of them");

def setup_data_problems:
	if type != "object" then "the data file is a JSON \(type); expected an object of always and technologies"
	else setup_unknown_fields("the data file"; setup_fields),
		(if has("always") then .always | setup_always_problems else empty end),
		(if has("technologies") | not then empty
		elif (.technologies | type) != "array" then "technologies is a JSON \(.technologies | type); expected an array of objects"
		else .technologies | setup_technology_problems, setup_clash_problems
		end)
	end;

# Each .worktreeinclude line that is not blank or a # comment, trailing
# whitespace removed, with its line number.
def setup_include_lines($text):
	$text | split("\n") | to_entries[]
	| {number: (.key + 1), text: (.value | sub("[[:space:]]+$"; ""))}
	| select(.text != "" and (.text | startswith("#") | not));

# A line as a root-relative copy entry: a leading / only anchors the line at
# the root, which every entry already is; a trailing / means a folder.
def setup_include_entry:
	(.text | sub("^/"; "")) as $anchored
	| {number, text, dir: ($anchored | endswith("/")), pattern: ($anchored | sub("/$"; ""))};

def setup_include_problems($text):
	setup_include_lines($text) | setup_include_entry
	| ".worktreeinclude line \(.number) \(.text | tojson)" as $where
	| if .text | startswith("!") then "\($where) is a negation; expected only paths to copy"
	elif .text | contains("**") then "\($where) holds **; expected * within one segment"
	else .pattern | setup_path_problem("glob") | "\($where) \(.)"
	end;

def setup_problems($include):
	setup_data_problems, setup_include_problems($include);

def setup_detect_names:
	[.technologies // [] | .[].detect[]] | unique[];

# The plan, one tab-separated record per line; the path is the last field:
#   detected <name>               a technology that applies, in data order
#   copy <any|dir> <pattern>      a root-relative path or glob to copy
#   skip <path>                   a root-relative folder never searched or copied
#   named <technology> <name>     copy every folder with this name
#   containing <technology> <name>  copy every folder holding a file of this name
#   repoint <technology> <subdir> rewrite the launchers in this subfolder
# $present lists the detect paths that exist under the --from root.
def setup_plan($present; $include):
	(.always // {}) as $always
	| [.technologies // [] | .[] | select(any(.detect[]; IN($present[])))] as $applying
	| ($applying[] | "detected\t\(.name)"),
	($always.copy // [] | .[] | "copy\tany\t\(.)"),
	($applying[] | .copy // [] | .[] | "copy\tany\t\(.)"),
	(setup_include_lines($include) | setup_include_entry | "copy\t\(if .dir then "dir" else "any" end)\t\(.pattern)"),
	($always.skip // [] | .[] | "skip\t\(.)"),
	($applying[] | .name as $name
		| (."copy-every-dir-named" // [] | .[] | "named\t\($name)\t\(.)"),
		(."copy-every-dir-containing" // [] | .[] | "containing\t\($name)\t\(.)"),
		(.repoint // [] | .[] | "repoint\t\($name)\t\(.)"));
