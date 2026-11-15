# Layout building blocks for human-facing views. A def returning "" stands for
# "nothing to show"; `blocks` drops it. Values arrive as display text; `shown`
# and `one_line` clean a value taken from outside.
# jq resolves a def only after its definition, so each helper precedes its callers.

# numbered_list
#   input:  array of strings
#   output: one `N. item` line per item, joined by newlines
def numbered_list: to_entries | map("\(.key + 1). \(.value)") | join("\n");

# bullet_list
#   input:  array of strings
#   output: one `* item` line per item, joined by newlines
def bullet_list: map("* \(.)") | join("\n");

# shown
#   input:  text taken from a repository, a record or the human
#   output: the text with each control character and each line or paragraph
#           separator (U+2028, U+2029) as "?"
def shown: gsub("[[:cntrl:]\u2028\u2029]"; "?");

# one_line
#   input:  text taken from a repository, a record or the human
#   output: the text with each run of control characters and line or paragraph
#           separators as one space
def one_line: gsub("[[:cntrl:]\u2028\u2029]+"; " ");

# counted($one; $many)
#   input:  a count
#   output: `<count> <one>` for 1, else `<count> <many>`
def counted($one; $many): "\(.) \(if . == 1 then $one else $many end)";

# plain_line
#   input:  one line of text
#   output: the line with a leading Markdown block mark (a heading, a quote, a
#           rule, a list item or a code fence) backslash-escaped, so it renders
#           as plain text at the start of a line or list item; inline Markdown
#           stays as written
def plain_line:
	if test("^(#{1,6}( |$)|>|(?<rule>[-*_])( *\\k<rule>){2,} *$|[-+*]( |$)|```|~~~)") then "\\" + .
	elif test("^[0-9]{1,9}[.)]( |$)") then sub("^(?<number>[0-9]{1,9})"; "\(.number)\\")
	else . end;

# path_text
#   input:  absolute path
#   output: the path whole, as plain text: no `~`, no cut, no backticks, so the
#           terminal sees one unbroken absolute path it can open
def path_text: .;

# status_line($status; $title; $tail), status_line($status; $title)
#   input:  ignored
#   $status: decision, done, attention or blocked; not shown, the title's own
#            words carry it
#   output: `**<title>**`, then ` · <tail>` when $tail is neither "" nor null
def status_line($status; $title; $tail):
	"**\($title)**"
	+ (if ($tail // "") == "" then "" else " · \($tail)" end);
def status_line($status; $title): status_line($status; $title; "");

# section($name; $plural; $items), section($name; $items)
#   input:  ignored
#   output: "" for no items; `**<name>:** <item>` for one; `**<plural>**` and a
#           numbered list for two or more ($plural defaults to $name)
def section($name; $plural; $items):
	if ($items | length) == 0 then ""
	elif ($items | length) == 1 then "**\($name):** \($items[0])"
	else "**\($plural)**\n" + ($items | numbered_list)
	end;
def section($name; $items): section($name; $name; $items);

# bullet_section($name; $items)
#   input:  ignored
#   output: "" for no items; else `**<name>:**` and a bullet list under it, for
#           an offer's or a hint's list that completes its heading
def bullet_section($name; $items):
	if ($items | length) == 0 then ""
	else "**\($name):**\n" + ($items | bullet_list)
	end;

# numbered_section($name; $items)
#   input:  ignored
#   output: "" for no items; else `**<name>**` and a numbered list, even for
#           one item
def numbered_section($name; $items):
	if ($items | length) == 0 then ""
	else "**\($name)**\n" + ($items | numbered_list)
	end;

# field_lines($pairs)
#   input:  ignored
#   $pairs: array of [name, count] or [name, count, tail]
#   output: one `<name>: <count>` line per non-zero count, with ` · <tail>` when
#           given, joined by a two-space hard break; "" when every count is zero
def field_lines($pairs):
	$pairs
	| map(select(.[1] != 0)
		| "\(.[0]): \(.[1])" + (if (.[2] // "") == "" then "" else " · \(.[2])" end))
	| join("  \n");

# data_section($pairs)
#   input:  ignored
#   $pairs: array of [kind, path]
#   output: "" for no pairs; `**Data · <kind>:** <path>` for one; `**Data**` and a
#           numbered list of `<kind>: <path>` for two or more; paths via path_text
def data_section($pairs):
	if ($pairs | length) == 0 then ""
	elif ($pairs | length) == 1 then "**Data · \($pairs[0][0]):** \($pairs[0][1] | path_text)"
	else "**Data**\n" + ($pairs | map("\(.[0]): \(.[1] | path_text)") | numbered_list)
	end;

# blocks
#   input:  array of blocks (strings), "" or null for a block with nothing to show
#   output: the non-empty blocks joined by one blank line
def blocks: map(select(. != null and . != "")) | join("\n\n");
