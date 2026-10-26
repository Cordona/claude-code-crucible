#!/usr/bin/env sh
# Writes a grill's file, the record of one interview of the human, so its
# JSON is never typed by hand, and prints what each change shows the human.
# The shell checks the command line's form and the --grill path; GRILL_JQ
# checks every value against the file it changes and builds the new file;
# grill-validator.jq checks the file read and the file about to be written.
# Only a new file that passes replaces the old one, through a temp file beside it.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../engine/crucible/scripts/lib
set -eu
umask 077

readonly PROG='grill.sh'
readonly PROCEDURE='procedure-grill'
readonly RENDER_LIB='human-view'
readonly CRUCIBLE_SKILL='crucible'
readonly KIND='grills'
readonly REQUIRED_TOOLS='date mkdir mktemp mv rm rmdir tr'
# The exit of a write refused because another call holds the grill's lock.
readonly LOCKED_EXIT=7
# The label is the topic's words in the file name; 40 characters keep a
# topic recognisable in a listing, below the space's label cap.
readonly LABEL_MAX_CHARS=40
# Bounds stderr so a refusal stays readable; the rest is counted.
readonly MAX_PROBLEMS=20
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Parses the command's options ($ARGS.positional, option and value pairs),
# checks each value against the grill file read on stdin (null for new), and
# prints {problems, file, out}: the problem lines, the file to write and the
# stdout text. The round and acknowledgement views are built here with view.jq.
# The file goes through crucible's prune, so a key with nothing in it is
# left out; a missing questions or answers is read as none.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly GRILL_JQ='include "grill-validator";
include "view";
include "prune";

def pairs: $ARGS.positional | [range(0; length / 2) as $n | {option: .[$n * 2], value: .[$n * 2 + 1]}];
def value_of($option): [pairs[] | select(.option == $option) | .value][0];
# A value is quoted as JSON and cut, so a problem line stays one short line.
def shown: tojson | if length > 60 then .[:60] + "…" else . end;
def text_problem($where; $max): grill_text_problem($max) | "\($where) \(.)";
def question_of($id): .questions[($id | grill_id_number) - 1];
def holds($value): index([$value]) != null;
def count_of($status): [(.questions // [])[] | select(.status == $status)] | length;

# {problems} when problems yields any, else apply with its problems empty, so
# a value is only applied once it passed every check.
def result(problems; apply): [problems] as $problems | if ($problems | length) > 0 then {problems: $problems} else apply + {problems: []} end;

# The groups that option $start opens, each an object of its options and its
# number, and the problems of a member option outside a group or given twice in one.
def groups($start; $members):
	reduce (pairs[] | select(.option == $start or (.option as $option | $members | holds($option)))) as $pair
		({groups: [], problems: []};
		 if $pair.option == $start then .groups += [{($start): $pair.value}]
		 elif (.groups | length) == 0 then .problems += ["\($pair.option) comes before any \($start); expected each group to start with \($start)"]
		 elif .groups[(.groups | length) - 1] | has($pair.option) then .problems += ["\($pair.option) is given twice in group \(.groups | length); expected it once per \($start) group"]
		 else .groups[(.groups | length) - 1][$pair.option] = $pair.value end)
	| .groups |= (to_entries | map({group: (.key + 1)} + .value));

def ended_problems: if has("ended") then "--grill \($grill) ended at \(.ended); expected a grill that has not ended; start another with \($prog) new" else empty end;

# The problem of id . named by $where in file $file, or nothing.
def id_problem($where; $file):
	($file.questions | length) as $count
	| if test(grill_id_pattern) | not then "\($where) is \(shown); expected an id such as q1"
	  elif grill_id_number > $count then "\($where) is \(.), which the grill does not hold; expected \(if $count == 0 then "an id add printed" else "q1 to q\($count)" end)"
	  else empty end;

def new_result:
	value_of("--topic") as $topic
	| result($topic | text_problem("--topic"; grill_max_chars.topic);
		{file: {claude_session_id: $session_id, topic: $topic, questions: []},
		 label: ($topic | ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | .[:$label_max] | sub("-+$"; "") | if . == "" then "grill" else . end),
		 out: ""});

def parent_problem($where; $own):
	if test(grill_id_pattern) | not then "\($where) is \(shown); expected the id of an earlier question, such as q1"
	elif grill_id_number >= ($own | grill_id_number) then "\($where) is \(.); expected the id of a question before \($own)"
	else empty end;

def add_result:
	. as $file
	| groups("--question"; ["--recommendation", "--reason", "--parent"]) as $parsed
	| [$parsed.groups[] | . + {id: "q\(($file.questions | length) + .group)"}] as $groups
	| result(ended_problems, $parsed.problems[],
		(if ($groups | length) == 0 then "no --question given; expected at least one --question TEXT --recommendation TEXT --reason TEXT group" else empty end),
		($groups[] | . as $group | "in group \(.group)" as $in
			| (["--recommendation", "--reason"][] | select(. as $option | $group | has($option) | not) | "\(.) is missing \($in); expected \(.) TEXT in every --question group"),
			  (.["--question"] | text_problem("--question \($in)"; grill_max_chars.question)),
			  (.["--recommendation"] // empty | text_problem("--recommendation \($in)"; grill_max_chars.recommendation)),
			  (.["--reason"] // empty | text_problem("--reason \($in)"; grill_max_chars.reason)),
			  (.["--parent"] // empty | parent_problem("--parent \($in)"; $group.id)));
		{file: ($file | .questions += [$groups[]
			| {id, claude_session_id: $session_id, text: .["--question"]}
			  + (if has("--parent") then {parent: .["--parent"]} else {} end)
			  + {recommendation: {text: .["--recommendation"], reason: .["--reason"]}, status: "open", answers: []}]),
		 out: "GRILL_IDS: \($groups | map(.id) | join(","))"});

# One question of a round: its id number, then its recommendation and reason
# on lines indented under its text, after hard breaks.
def round_item($delimiter):
	"\(.id | grill_id_number)\($delimiter) " as $marker
	| (" " * ($marker | length)) as $indent
	| "\($marker)\(.text | plain_line)  \n\($indent)Recommendation: \(.recommendation.text)  \n\($indent)Reason: \(.recommendation.reason)";

# The round questions numbered by their ids. Markdown numbers a list from its
# first item on, so each run of consecutive ids is a list of its own: a blank
# line and the other delimiter (. or )) start the next, numbered from its id.
def round_list:
	sort_by(.id | grill_id_number)
	| reduce .[] as $question ([];
		if length > 0 and (.[length - 1][-1].id | grill_id_number) + 1 == ($question.id | grill_id_number)
		then .[length - 1] += [$question] else . + [[$question]] end)
	| to_entries
	| map((if .key % 2 == 0 then "." else ")" end) as $delimiter | .value | map(round_item($delimiter)) | join("\n"))
	| join("\n\n");

def ask_id_problem($position; $ids; $file):
	. as $id
	| id_problem("--ids entry \($position + 1)"; $file)
	  // (($file | question_of($id)).status as $status
		| if $ids[:$position] | holds($id) then "--ids names \($id) twice; expected each question once"
		  elif $status != "open" then "--ids names \($id), which is \($status); expected an open question"
		  else empty end);

def ask_result:
	. as $file
	| (value_of("--ids") | split(",")) as $ids
	| (([($file.questions // [])[].round // 0] | max // 0) + 1) as $round
	| result(ended_problems,
		(if ($ids | length) == 0 or ($ids | length) > grill_round_max then "--ids names \($ids | length) questions; expected 1 to \(grill_round_max) ids, comma-separated" else empty end),
		($ids | to_entries[] | .key as $position | .value | ask_id_problem($position; $ids; $file));
		{file: ($file | .questions |= (. // [] | map(if (.id as $id | $ids | holds($id)) then .round = $round else . end))),
		 out: ([status_line("decision"; "Grill · round \($round)"),
			([$file.questions[] | select(.id as $id | $ids | holds($id))] | round_list),
			(if $round == 1 then "Say \"end the grill\" at any point to stop." else "" end)] | blocks)});

def answer_group_problems($group; $earlier_ids; $file):
	"in group \($group.group)" as $in
	| $group["--id"] as $id
	| (if $group | has("--text") then $group["--text"] | text_problem("--text \($in)"; grill_max_chars.answer) else "--text is missing \($in); expected --text TEXT in every --id group" end),
	  ($group["--change-reason"] // empty | text_problem("--change-reason \($in)"; grill_max_chars.change_reason)),
	  ($id | id_problem("--id \($in)"; $file)
		// (($file | question_of($id)).status as $status
		    | if $earlier_ids | holds($id) then "--id \($id) \($in) is answered by an earlier group; expected each question once"
		      elif $status == "dropped" then "--id \($id) \($in) is dropped; expected an open, deferred or settled question; reopen it first with \($prog) status --to open"
		      elif $status == "settled" and ($group | has("--change-reason") | not) then "--id \($id) \($in) is settled; expected --change-reason TEXT with its new answer"
		      elif $status != "settled" and ($group | has("--change-reason")) then "--change-reason \($in) is given for \($id), which is \($status); expected it only to change a settled answer"
		      else empty end));

def recorded_view($recorded):
	if ($recorded | length) == 0 then ""
	elif ($recorded | length) == 1 then "\(status_line("done"; "Recorded:")) \($recorded[0]["--id"]): \($recorded[0]["--text"])"
	else "\(status_line("done"; "Recorded"))  \n" + ($recorded | map("\(.["--id"]): \(.["--text"])") | join("  \n")) end;

def changed_view($file):
	.["--id"] as $id
	| "\(status_line("done"; "Changed · \($id):")) \(.["--text"]) (was \(($file | question_of($id)).answers[-1].text): \(.["--change-reason"]))";

# The file with the answer of each group added as the next revision of its question.
def answered($groups):
	reduce $groups[] as $group (.;
		.questions[($group["--id"] | grill_id_number) - 1] |= (
			.answers += [{revision: ((.answers | length) + 1), at: $at, claude_session_id: $session_id}
				+ (if $group | has("--change-reason") then {change_reason: $group["--change-reason"]} else {} end)
				+ {text: $group["--text"]}]
			| .status = "settled"));

def answer_result:
	. as $file
	| groups("--id"; ["--text", "--change-reason"]) as $parsed
	| $parsed.groups as $groups
	| [$groups[]["--id"]] as $ids
	| result(ended_problems, $parsed.problems[],
		(if ($groups | length) == 0 then "no --id given; expected at least one --id ID --text TEXT group" else empty end),
		($groups[] | answer_group_problems(.; $ids[:.group - 1]; $file));
		[$groups[] | select(has("--change-reason"))] as $changed
		| [$changed[]["--id"]] as $changed_ids
		| ($file | answered($groups)) as $answered
		| [$answered.questions[] | select(.status == "settled" and (.parent as $parent | $changed_ids | holds($parent)) and (.id as $id | $ids | holds($id) | not)) | .id] as $reopened
		| {file: ($answered | .questions |= map(if (.id as $id | $reopened | holds($id)) then .status = "open" else . end)),
		   out: ([recorded_view([$groups[] | select(has("--change-reason") | not)]),
			($changed[] | changed_view($file)),
			(if ($reopened | length) > 0 then "Back to open: \($reopened | join(", "))" else "" end)] | blocks)});

def status_result:
	. as $file
	| value_of("--id") as $id
	| value_of("--to") as $to
	| value_of("--reason") as $reason
	| {dropped: "Dropped", deferred: "Deferred", open: "Reopened"} as $titles
	| result(ended_problems,
		($reason | text_problem("--reason"; grill_max_chars.status_reason)),
		(if $titles | has($to) then empty else "--to is \($to | shown); expected dropped, deferred or open" end),
		($id | id_problem("--id"; $file)
			// (if ($file | question_of($id)).status == $to then "--id \($id) is \($to) already; expected a question that is not \($to)" else empty end));
		{file: ($file | .questions[($id | grill_id_number) - 1] |= (
			.status = $to
			| if grill_status_prefix | has($to) then .answers += [{revision: ((.answers | length) + 1), at: $at, claude_session_id: $session_id, text: "\(grill_status_prefix[$to])\($reason)"}] else . end)),
		 out: "\(status_line("done"; "\($titles[$to]) · \($id):")) \($reason)"});

def end_result:
	result(ended_problems;
		{file: (.ended = $at),
		 out: "GRILL_ENDED: \($grill) · settled \(count_of("settled")) · open \(count_of("open")) · deferred \(count_of("deferred")) · dropped \(count_of("dropped"))"});

# Puts every object of the file in its field order.
def ordered_file:
	grill_ordered(grill_file_fields)
	| .questions |= (. // [] | map(grill_ordered(grill_question_fields) | .answers |= (. // [] | map(grill_ordered(grill_answer_fields)))));

if $command == "new" then new_result
elif $command == "add" then add_result
elif $command == "ask" then ask_result
elif $command == "answer" then answer_result
elif $command == "status" then status_result
else end_result end
| if has("file") then .file |= (ordered_file | prune) else . end
'

# Prints the problem lines of array .problems, at most $max, then a count of the rest.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PROBLEMS_JQ='.problems | .[:$max][], (if length > $max then "\(length - $max) more problems not shown (showing \($max) of \(length)); expected none" else empty end)'

# Prints the problem lines grill-validator.jq finds in the grill file read
# raw on stdin, each after $prefix, or one line when it is not one JSON value.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VALIDATE_JQ='include "grill-validator";
{problems: [[try fromjson]
	| if length == 0 then "is not one JSON value; expected the grill file grill.sh writes" else .[0] | grill_file_problems end
	| "\($prefix)\(.)"]}
| '"${PROBLEMS_JQ}"

# list: prints {problems, out} for the $count grill files passed as $ARGS.named
# pairs p<n> (the path) and g<n> (its text): each file's problems after its
# path, else one GRILL line per file, newest first (the ID leads each name).
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly LIST_JQ='include "grill-validator";
def open_count: [(.questions // [])[] | select(.status == "open")] | length;
$ARGS.named as $named
| [range(0; $count) | {path: $named["p\(.)"], file: [$named["g\(.)"] | try fromjson]}]
| sort_by(.path) | reverse
| [.[] | .path as $path
	| if (.file | length) == 0 then "is not one JSON value; expected the grill file grill.sh writes" else .file[0] | grill_file_problems end
	| "\($path): \(.)"] as $problems
| if ($problems | length) > 0 then {problems: $problems}
  else {problems: [],
	out: map(.file[0] as $file
		| "GRILL: \(.path) · \(if $file | has("ended") then "ended" else "open" end) · open \($file | open_count) · \($file.topic)")
	| join("\n")} end'

# Prints the caps the command pages name, read from grill-validator.jq, space-separated.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly CAPS_JQ='include "grill-validator";
grill_max_chars as $max
| [$max.topic, $max.question, $max.recommendation, $max.reason, $max.answer, $max.change_reason, $max.status_reason, grill_round_max]
| map(tostring) | join(" ")'

# The top --help page: every usage line, the commands and what no single
# command owns. Each command's own contract is its `<command> --help` page.
usage() {
	usage_prefix='usage: '
	usage_lines new add ask answer status end list
	usage_line "sh ${PROG} <command> --help"
	usage_line "sh ${PROG} --help | -h"
	print_page <<EOF

Writes a grill's file, the record of one interview of the human, in an
effort's ${KIND}/ folder, and prints what each change shows the human. A write
replaces the file whole only when the new file passes grill-validator.jq, or
leaves it as it was; once the grill has ended, every write is refused.
Nothing else is left behind (a SIGKILL aside: it can leave a temp file and
the lock beside the grill file). stdin is never read. One call at a time on
one grill; a held lock exits ${LOCKED_EXIT}.

Commands (each page holds its options, output and exit codes):
  new     creates the grill file, with its topic and no question
  add     appends questions, each open, under the next unused ids
  ask     prints a round of open questions for the human
  answer  records answers and prints the acknowledgement for the human
  status  drops, defers or reopens a question
  end     marks the grill ended
  list    prints the effort's grill files, newest first; writes nothing

Ids: q1, q2, ... in the order added, never reused. Shape: see
grill-validator.jq. claude_session_id names a session: the file's, set by
new and never changed; a question's, the session that added it; an
answer's, a status one included, the session that gave it.
EOF
	help_shared environment
	help_shared dependencies
}

# The `<command> --help` page of command $1. Its caps are read from
# grill_max_chars and grill_round_max in grill-validator.jq: the skill writes
# each text to them.
command_help() {
	load_caps
	usage_prefix='usage: '
	usage_lines "$1"
	case $1 in
		new)
			print_page <<EOF

Creates the grill file in the effort's ${KIND}/ folder, named after the topic.

Options:
  --effort FOLDER        the effort folder, as effort.sh start printed it
  --topic TEXT           what the grill is about: one line, at most ${cap_topic}
                         characters

stdout on exit 0: GRILL_FILE: <the grill file, absolute>
EOF
			help_shared caps
			help_shared exits 'read stdout' new
			;;
		add)
			print_page <<'EOF'

Appends one open question per --question group, in order.

Options:
EOF
			help_shared grill
			print_page <<EOF
  --question TEXT        starts a group: the question, one line, at most ${cap_question}
                         characters
  --recommendation TEXT  the answer recommended: one line, at most ${cap_recommendation}
  --reason TEXT          why: one line, at most ${cap_reason}
  --parent ID            the question it came from, added before it

stdout on exit 0: GRILL_IDS: <the new ids, in order, comma-separated>
EOF
			help_shared caps
			help_shared exits 'read stdout' lock
			;;
		ask)
			print_page <<'EOF'

Prints round N, N one more than the last round asked, and stores N on each
question asked as the round it was last asked in.

Options:
EOF
			help_shared grill
			print_page <<EOF
  --ids ID,ID,...        1 to ${cap_round} open questions, comma-separated, each once

stdout on exit 0: the round's Markdown, each question numbered by its id
EOF
			help_shared caps
			help_shared exits 'relay stdout word for word' lock
			;;
		answer)
			print_page <<'EOF'

Records one answer per --id group, in order. An open or deferred question
becomes settled; a settled one changes only with --change-reason, its earlier
answers kept, and its settled children (parent ID) not answered in the same
call go back to open.

Options:
EOF
			help_shared grill
			print_page <<EOF
  --id ID                starts a group: an open, deferred or settled question
  --text TEXT            its answer: one line, at most ${cap_answer} characters
  --change-reason TEXT   why a settled answer changes: one line, at most ${cap_change_reason}
                         characters; only for a settled question

stdout on exit 0: the acknowledgement's Markdown
EOF
			help_shared caps
			help_shared exits 'relay stdout word for word' lock
			;;
		status)
			print_page <<'EOF'

Sets a question's status. dropped and deferred add an answer revision
"Dropped: <reason>" or "Deferred: <reason>"; open adds none.

Options:
EOF
			help_shared grill
			print_page <<EOF
  --id ID                the question, not already in the status --to names
  --to STATUS            dropped, deferred or open
  --reason TEXT          why: one line, at most ${cap_status_reason} characters

stdout on exit 0: the acknowledgement's Markdown
EOF
			help_shared caps
			help_shared exits 'relay stdout word for word' lock
			;;
		list)
			print_page <<'EOF'

Prints the effort's grill files, newest first, each checked against
grill-validator.jq. It reads them only: no file is written, no lock taken.
A grills/ folder it cannot read exits 2, naming it.

Options:
  --effort FOLDER        the effort folder, as effort.sh start printed it

stdout on exit 0: one line per grill file, none when the effort has none:
  GRILL: <the grill file, absolute> · <open|ended> · open <n> · <topic>
  (open <n>: how many of its questions are open)
EOF
			help_shared exits 'read stdout' read
			;;
		*)
			print_page <<'EOF'

Marks the grill ended; no command writes the file again.

Options:
EOF
			help_shared grill
			print_page <<'EOF'

stdout on exit 0: GRILL_ENDED: <the grill file, absolute> · settled <n> ·
  open <n> · deferred <n> · dropped <n>
EOF
			help_shared exits 'read stdout' lock
			;;
	esac
	help_shared environment
	help_shared dependencies
}

# Sets the cap_ values a command page prints, from grill-validator.jq; when
# jq can't read them, sets each to <cap> and caps_named, so the page says
# where the caps are.
load_caps() {
	caps_named=''
	validator_dir=$(script_dir)
	caps=$(jq -n -r -L "${validator_dir}" "${CAPS_JQ}" </dev/null 2>/dev/null) || caps=''
	case ${caps} in
		*[!0-9' ']*) caps='' ;;
		*) ;;
	esac
	read -r cap_topic cap_question cap_recommendation cap_reason cap_answer cap_change_reason cap_status_reason cap_round caps_extra <<EOF
${caps}
EOF
	[ -z "${cap_round}" ] || [ -n "${caps_extra}" ] || return 0
	cap_topic='<cap>' cap_question='<cap>' cap_recommendation='<cap>' cap_reason='<cap>'
	cap_answer='<cap>' cap_change_reason='<cap>' cap_status_reason='<cap>' cap_round='<cap>'
	caps_named=yes
}

# Prints the usage lines of each command named, the first after usage_prefix.
usage_lines() {
	for usage_command in "$@"; do
		case ${usage_command} in
			new) usage_line "sh ${PROG} new --effort FOLDER --topic TEXT" ;;
			add) usage_line "sh ${PROG} add --grill PATH --question TEXT --recommendation TEXT --reason TEXT [--parent ID] [--question ...]..." ;;
			ask) usage_line "sh ${PROG} ask --grill PATH --ids ID,ID,..." ;;
			answer) usage_line "sh ${PROG} answer --grill PATH --id ID --text TEXT [--change-reason TEXT] [--id ...]..." ;;
			status) usage_line "sh ${PROG} status --grill PATH --id ID --to dropped|deferred|open --reason TEXT" ;;
			list) usage_line "sh ${PROG} list --effort FOLDER" ;;
			*) usage_line "sh ${PROG} end --grill PATH" ;;
		esac
	done
}

usage_line() {
	printf '%s%s\n' "${usage_prefix}" "$1"
	usage_prefix='       '
}

# The help text more than one page prints, item $1, so it is written once;
# exits takes exit 0's next step as $2 and, as $3, what the command does to
# the grill file: new (creates it), lock (writes it under the lock) or read.
help_shared() {
	case $1 in
		grill)
			print_page <<'EOF'
  --grill PATH           the grill file, as new printed it
EOF
			;;
		caps)
			[ -z "${caps_named}" ] || print_page <<'EOF'

<cap>: jq could not read the caps here; they are grill_max_chars and
  grill_round_max in grill-validator.jq beside this script.
EOF
			;;
		environment)
			print_page <<'EOF'

Environment:
  CRUCIBLE_HOME          the Crucible space (default $HOME/.crucible)
  CLAUDE_CODE_SESSION_ID every command but list: required, the session ID
                         Claude Code sets, a lowercase UUID
  CLAUDE_CONFIG_DIR      the skills are in
                         ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills
EOF
			;;
		exits) help_exits "$2" "$3" ;;
		*)
			print_page <<EOF

Dependencies: POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's
  jq package); date, mkdir, mktemp, mv, rm, rmdir, tr (every macOS and Linux
  base system); in the skills: the ${CRUCIBLE_SKILL} skill's crucible.sh,
  scripts/lib/crucible-space.sh and scripts/lib/prune.jq, the ${RENDER_LIB}
  skill's view.jq; grill-validator.jq beside this script.
EOF
			;;
	esac
}

# Prints a command page's stderr lines and exit codes: exit 0's next step $1,
# and the lines kind $2 (new, lock or read, as help_shared exits takes) adds.
help_exits() {
	print_page <<EOF

stderr on exit 2: one "${PROG}: <what>; expected <x>" line per problem, at
  most ${MAX_PROBLEMS}, then a count of the rest (a usage error adds a "Try" line)
stderr on exits 1, 3, 5: "${PROG}: install:", a prefix no other exit
  prints; tell the human what it names to install, and stop
EOF
	[ "$2" != lock ] || print_page <<EOF

One call at a time on one grill; a held lock exits ${LOCKED_EXIT}.
EOF
	print_page <<EOF

Exit codes:
  0  done; $1
  1  jq missing
  2  refused input, nothing written; fix what stderr names and rerun once,
     else show the human stderr
EOF
	[ "$2" = read ] || print_page <<EOF
     "${PROG}: CLAUDE_CODE_SESSION_ID ...": unset, empty or not a lowercase
       UUID; show the human stderr, and stop
EOF
	print_page <<'EOF'
  3  jq failed, nothing written
EOF
	if [ "$2" = read ]; then
		print_page <<'EOF'
  4  stdout closed before the output was written, nothing on stderr; stop
     and show the exit code
  5  an install fault: a tool or skill file missing or failing; stderr names
     which
  129, 130, 143  stopped by HUP, INT or TERM; show the human stderr, and stop
EOF
		return 0
	fi
	print_page <<'EOF'
  4  stdout closed before the output was written, nothing on stderr; the
     write landed; stop and show the exit code
  5  an install fault: a tool or skill file missing or failing; stderr names
     which
  6  the write failed, the grill file as it was (new: none left); show the
     human stderr, and stop
EOF
	[ "$2" != lock ] || print_page <<EOF
  ${LOCKED_EXIT}  the grill is locked: another call is writing it, or a killed run left
     the lock; nothing written; stderr names the lock. Rerun once your other
     call has ended; if it is still held, show the human stderr, and stop
EOF
	print_page <<'EOF'
  129, 130, 143  stopped by HUP, INT or TERM, the grill file whole, as it was
     or as written; show the human stderr, and stop
EOF
}

# Prints stdin with builtins only, so a help page prints with cat missing.
print_page() {
	while IFS= read -r page_line; do
		printf '%s\n' "${page_line}"
	done
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

# Prints an install or host fault (a missing or failing tool, never a problem
# of the input) with the "install:" prefix and exits $1.
install_fault() {
	warn "install: $2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s%s --help'.\n" "${PROG}" "${command:+ ${command}}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets command, effort and grill from the arguments; exits 2 on an unknown
# option, a missing value or a single option given twice. Every value is
# checked later, against the file.
parse_args() {
	command=''
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		new | add | ask | answer | status | end | list) command=$1 ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected new, add, ask, answer, status, end, list or --help"
			;;
	esac
	shift
	effort='' grill='' seen_options=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				command_help "${command}"
				exit 0
				;;
			*) ;;
		esac
		check_option "$1"
		[ "$#" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
		case $1 in
			--effort) effort=$2 ;;
			--grill) grill=$2 ;;
			*) ;;
		esac
		shift 2
	done
	require_options
}

# Exits 2 unless option $1 is taken by the command; records an option that
# may appear once, exiting 2 when it was given before.
check_option() {
	case ${command}:$1 in
		add:--question | add:--recommendation | add:--reason | add:--parent) return 0 ;;
		answer:--id | answer:--text | answer:--change-reason) return 0 ;;
		new:--effort | new:--topic | ask:--ids | status:--id | status:--to | status:--reason | list:--effort) ;;
		new:* | list:*) unknown_option "$1" ;;
		*:--grill) ;;
		*) unknown_option "$1" ;;
	esac
	case " ${seen_options} " in
		*" $1 "*) usage_error "$1 given twice; expected at most one $1" ;;
		*) seen_options="${seen_options} $1" ;;
	esac
}

unknown_option() {
	shown_option=$(printable "$1")
	case ${command} in
		new) expected_options='--effort, --topic' ;;
		add) expected_options='--grill, --question, --recommendation, --reason, --parent' ;;
		ask) expected_options='--grill, --ids' ;;
		answer) expected_options='--grill, --id, --text, --change-reason' ;;
		status) expected_options='--grill, --id, --to, --reason' ;;
		list) expected_options='--effort' ;;
		*) expected_options='--grill' ;;
	esac
	usage_error "unknown option for ${command}: ${shown_option}; expected ${expected_options} or --help"
}

# Exits 2 when a single option the command needs is missing; a group's
# options are checked with the file.
require_options() {
	case ${command} in
		new) set -- --effort FOLDER --topic TEXT ;;
		ask) set -- --grill PATH --ids ID,ID,... ;;
		status) set -- --grill PATH --id ID --to STATUS --reason TEXT ;;
		list) set -- --effort FOLDER ;;
		*) set -- --grill PATH ;;
	esac
	while [ "$#" -gt 0 ]; do
		case " ${seen_options} " in
			*" $1 "*) ;;
			*) usage_error "$1 missing; expected $1 $2" ;;
		esac
		shift 2
	done
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Exits 5 unless file $1 is readable, naming what it is ($3) and the skill ($2) to install.
require_skill_file() {
	[ -f "$1" ] && [ -r "$1" ] ||
		install_fault 5 "$3 missing; expected $1; install the $2 skill"
}

# Sets own_dir, render_lib_dir (view.jq), crucible_lib_dir (prune.jq) and
# crucible_script, and sources the space rules.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 1 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	for tool in ${REQUIRED_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 ||
			install_fault 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
	done
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	own_dir=$(script_dir)
	require_skill_file "${own_dir}/grill-validator.jq" "${PROCEDURE}" 'grill file shape'
	render_lib_dir="${skills_dir}/${RENDER_LIB}"
	require_skill_file "${render_lib_dir}/view.jq" "${RENDER_LIB}" 'layout module'
	crucible_lib_dir="${skills_dir}/${CRUCIBLE_SKILL}/scripts/lib"
	require_skill_file "${crucible_lib_dir}/prune.jq" "${CRUCIBLE_SKILL}" 'prune module'
	crucible_script="${skills_dir}/${CRUCIBLE_SKILL}/scripts/crucible.sh"
	require_skill_file "${crucible_script}" "${CRUCIBLE_SKILL}" 'crucible.sh'
	space_lib="${crucible_lib_dir}/crucible-space.sh"
	require_skill_file "${space_lib}" "${CRUCIBLE_SKILL}" 'space rules'
	# shellcheck source=crucible-space.sh
	. "${space_lib}"
}

# Sets session_id from CLAUDE_CODE_SESSION_ID by the space rules, or exits 2
# before the lock is taken or any file made.
require_session() {
	# shellcheck disable=SC2310 # its status says whether the session is usable; the problem is read here
	crucible_check_session || exit_on_problems "${crucible_session_problem}"
	session_id=${crucible_session_id}
}

# Prints the problem of the --grill path, or nothing when it names a grill
# file of an effort of the space.
grill_path_problem() {
	case ${grill} in
		*[[:cntrl:]]*)
			printf '%s' '--grill holds a control character (such as a line break); expected one absolute path'
			return 0
			;;
		/*) ;;
		*)
			printf '%s' "--grill ${grill} is not absolute; expected the absolute path ${PROG} new printed"
			return 0
			;;
	esac
	# shellcheck disable=SC2310 # its status says whether the space is usable; the problem is printed
	if ! crucible_resolve_root; then
		printf '%s' "CRUCIBLE_HOME: ${crucible_root_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status says whether the path is an item's; the problem is printed
	if ! crucible_check_effort_item "${grill}" "${KIND}"; then
		printf '%s' "--grill ${grill} is ${crucible_item_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	if ! is_grill_name "${grill##*/}"; then
		printf '%s' "--grill ${grill} is not named <ID>-<label>.json; expected the grill file ${PROG} new printed"
		return 0
	fi
	[ -f "${grill}" ] && [ ! -L "${grill}" ] && [ -r "${grill}" ] && [ -w "${grill}" ] ||
		printf '%s' "--grill ${grill} is not a readable, writable regular file, or is a symbolic link; expected the grill file ${PROG} new printed"
}

# Succeeds when file name $1 is a grill file's: <ID>-<label>.json.
is_grill_name() {
	# shellcheck disable=SC2310 # pure tests; their status is the answer
	crucible_split_id "$1" && [ "${crucible_name_rest%.json}" != "${crucible_name_rest}" ] &&
		crucible_is_label "${crucible_name_rest%.json}"
}

# Takes the grill's lock, a folder beside the grill file that only one call
# can create, so one call at a time reads, checks and replaces the file; a
# held lock exits LOCKED_EXIT. clean_up removes it; a killed run leaves it,
# and the refusal says how to remove it.
take_lock() {
	lock_path="${grill%/*}/.${grill##*/}.lock"
	if mkdir "${lock_path}" 2>/dev/null; then
		lock_dir=${lock_path}
		return 0
	fi
	[ -d "${lock_path}" ] ||
		die 6 "mkdir could not create the lock ${lock_path}; expected a writable ${grill%/*}; try checking its permissions, then rerun"
	die "${LOCKED_EXIT}" "--grill ${grill} is locked by ${lock_path}; expected one call at a time; try again once the other call has ended; if none is running, a killed run left the lock: remove it with rmdir '${lock_path}', then rerun"
}

# Prints each line of $1 as a problem and exits 2, when $1 holds any.
exit_on_problems() {
	[ -n "$1" ] || return 0
	while IFS= read -r problem; do
		warn "${problem}"
	done <<EOF
$1
EOF
	exit 2
}

# Prints the problem lines grill-validator.jq finds in file $1, at most
# MAX_PROBLEMS, each after $2.
file_problems() {
	jq -Rsr -L "${own_dir}" --arg prefix "$2" --argjson max "${MAX_PROBLEMS}" "${VALIDATE_JQ}" <"$1"
}

# Sets result to GRILL_JQ's output over the command's arguments ("$@") and
# the grill file (null for new).
run_grill_jq() {
	at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || install_fault 5 'date failed; expected the UTC time; try date -u, then rerun'
	if [ "${command}" = new ]; then
		# shellcheck disable=SC2310 # its status is jq's; a failure exits
		result=$(printf 'null\n' | grill_jq "$@") || install_fault 3 'jq failed; expected jq 1.6+; try jq --version, then rerun'
	else
		# shellcheck disable=SC2310 # its status is jq's; a failure exits
		result=$(grill_jq "$@" <"${grill}") || install_fault 3 'jq failed; expected jq 1.6+; try jq --version, then rerun'
	fi
}

grill_jq() {
	jq -c -L "${own_dir}" -L "${render_lib_dir}" -L "${crucible_lib_dir}" --arg command "${command}" --arg at "${at}" --arg grill "${grill}" \
		--arg session_id "${session_id}" --arg prog "${PROG}" --argjson label_max "${LABEL_MAX_CHARS}" "${GRILL_JQ}" --args -- "$@"
}

# Exits 2 when setup problems $1 or the problems in result hold any.
exit_on_result_problems() {
	input_problems=$(printf '%s\n' "${result}" | jq -r --argjson max "${MAX_PROBLEMS}" "${PROBLEMS_JQ}") ||
		install_fault 3 'jq failed reading the problems; expected jq 1.6+; try jq --version, then rerun'
	exit_on_problems "$1${1:+${input_problems:+
}}${input_problems}"
}

# new and list: prints the problem of --effort, or nothing when it names an
# effort folder of the space.
effort_problem() {
	# shellcheck disable=SC2310 # its status says whether the space is usable; the problem is printed
	if ! crucible_resolve_root; then
		printf '%s' "CRUCIBLE_HOME: ${crucible_root_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status says whether the folder passed; the problem is printed
	crucible_check_effort_folder "${effort}" || printf '%s' "${crucible_effort_refusal}"
}

# Sets effort_dir to --effort without its trailing slashes.
set_effort_dir() {
	effort_dir=${effort}
	while [ "${effort_dir}" != "${effort_dir%/}" ]; do effort_dir=${effort_dir%/}; done
}

# Removes the temp file, on a failing exit the grill file this run created,
# and last the lock this run took.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	exit_status=$?
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	if [ "${exit_status}" -ne 0 ] && [ -n "${created_file}" ]; then
		rm -f "${created_file}" && warn "removed ${created_file}, made by this run"
	fi
	if [ -n "${lock_dir}" ]; then
		rmdir "${lock_dir}" 2>/dev/null ||
			warn "could not remove the lock ${lock_dir}; expected it gone; try rmdir '${lock_dir}'"
	fi
}

# Writes result's file over path $1 through a temp file beside it, once the
# temp file passes the validator.
write_file() {
	temp_file=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") ||
		die 6 "mktemp could not create a temp file beside $1; expected a writable ${1%/*}; try checking its permissions and free space, then rerun"
	printf '%s\n' "${result}" | jq '.file' >"${temp_file}" ||
		die 6 "could not write the temp file ${temp_file}; expected the grill file written; try checking free space, then rerun"
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	written_problems=$(file_problems "${temp_file}" 'the file this call would write: ') ||
		install_fault 3 'jq failed on the grill validator; expected jq 1.6+; try jq --version, then rerun'
	exit_on_problems "${written_problems}"
	mv -f "${temp_file}" "$1" ||
		die 6 "mv could not move the temp file onto $1; expected the grill file in place; try checking the permissions and free space of ${1%/*}, then rerun"
	temp_file=''
}

# new: creates the grill file through crucible.sh and sets grill to it.
create_grill_file() {
	label=$(printf '%s\n' "${result}" | jq -r '.label') ||
		install_fault 3 'jq failed reading the label; expected jq 1.6+; try jq --version, then rerun'
	if created=$(sh "${crucible_script}" new --kind "${KIND}" --effort "${effort}" --label "${label}" </dev/null); then
		crucible_status=0
	else
		crucible_status=$?
	fi
	case ${crucible_status} in
		0) ;;
		5) install_fault 5 'crucible.sh new names a missing dependency above; install it, then rerun' ;;
		*) die 6 "crucible.sh new failed (its stderr is above); expected a new empty file in ${effort}/${KIND}/; try the fix it names, then rerun" ;;
	esac
	created_file=${created}
	set_effort_dir
	case ${created} in
		"${effort_dir}/${KIND}/"*.json) ;;
		*)
			shown_created=$(printable "${created}")
			die 6 "crucible.sh new printed ${shown_created}, which is not in ${effort_dir}/${KIND}/; expected a new file there; try reinstalling the crucible skill, then rerun"
			;;
	esac
	grill=${created}
}

# list: sets result to LIST_JQ's output over the effort's grill files, or
# exits 2 on a file in its grills/ folder that is not one.
list_grills() {
	set_effort_dir
	case ${effort_dir} in
		*[[:cntrl:]]*) exit_on_problems '--effort holds a control character (such as a line break); expected one absolute path' ;;
		*) ;;
	esac
	grills_dir="${effort_dir}/${KIND}"
	if [ -L "${grills_dir}" ] || { [ -e "${grills_dir}" ] && [ ! -d "${grills_dir}" ]; }; then
		exit_on_problems "--effort ${effort}: ${KIND}/ is a symbolic link or not a folder; expected the real folder ${PROG} new creates"
	fi
	# An unreadable folder globs to nothing, which would read as no grills.
	if [ -d "${grills_dir}" ] && { [ ! -r "${grills_dir}" ] || [ ! -x "${grills_dir}" ]; }; then
		exit_on_problems "--effort ${effort}: cannot read ${grills_dir}; expected a readable folder; try checking its permissions"
	fi
	set --
	listed_count=0 listed_problems=''
	if [ -d "${grills_dir}" ]; then
		for listed_file in "${grills_dir}"/*.json; do
			[ -e "${listed_file}" ] || [ -L "${listed_file}" ] || continue
			# shellcheck disable=SC2310 # a pure test; its status is the answer
			if is_grill_name "${listed_file##*/}" && [ -f "${listed_file}" ] && [ ! -L "${listed_file}" ] && [ -r "${listed_file}" ]; then
				set -- "$@" --arg "p${listed_count}" "${listed_file}" --rawfile "g${listed_count}" "${listed_file}"
				listed_count=$((listed_count + 1))
			else
				listed_problems="${listed_problems:+${listed_problems}
}${listed_file}: is not a readable regular file named <ID>-<label>.json, or is a symbolic link; expected only the grill files ${PROG} new writes"
			fi
		done
	fi
	exit_on_problems "${listed_problems}"
	result=$(jq -n -c -L "${own_dir}" --argjson count "${listed_count}" "$@" "${LIST_JQ}" </dev/null) ||
		install_fault 3 'jq failed on the grill files; expected jq 1.6+; try jq --version, then rerun'
}

# Prints $1 and a newline, or exits 4 when stdout is closed.
print_out() {
	# Ignoring SIGPIPE turns a closed reader into a failed write this script
	# can tell apart from a jq fault, rather than a silent kill.
	trap '' PIPE
	printf '%s\n' "$1" 2>/dev/null || exit 4
}

# Prints result's output, nothing when it is empty.
print_result_out() {
	out=$(printf '%s\n' "${result}" | jq -r '.out') ||
		install_fault 3 'jq failed reading the output; expected jq 1.6+; try jq --version, then rerun'
	[ -z "${out}" ] || print_out "${out}"
}

# list: prints a line per grill file of the effort; reads only.
list_command() {
	setup_problems=$(effort_problem)
	exit_on_problems "${setup_problems}"
	list_grills
	exit_on_result_problems ''
	print_result_out
}

# Every other command: checks its input against the grill file it reads
# (none for new) under the grill's lock, writes the new file and prints its output.
write_command() {
	require_session
	if [ "${command}" = new ]; then
		setup_problems=$(effort_problem)
	else
		path_problem=$(grill_path_problem)
		exit_on_problems "${path_problem}"
		take_lock
		# shellcheck disable=SC2310 # its status is jq's; a failure exits
		read_problems=$(file_problems "${grill}" "--grill ${grill}: ") ||
			install_fault 3 'jq failed on the grill validator; expected jq 1.6+; try jq --version, then rerun'
		exit_on_problems "${read_problems}"
		setup_problems=''
	fi
	run_grill_jq "$@"
	exit_on_result_problems "${setup_problems}"
	[ "${command}" != new ] || create_grill_file
	write_file "${grill}"
	created_file=''
	case ${command} in
		new) print_out "GRILL_FILE: ${grill}" ;;
		*) print_result_out ;;
	esac
}

temp_file='' created_file='' lock_dir='' session_id=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
shift
load_dependencies
if [ "${command}" = list ]; then
	list_command
else
	write_command "$@"
fi
