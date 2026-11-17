#!/usr/bin/env sh
# Writes a grill, the record of one interview of the human, so its JSON is
# never typed by hand, and prints what each change shows the human. An open
# grill is the draft <effort>/drafts/main-thread/grill-<n>.json, <n> its
# number in the effort; an ended one is a grill.ended event, written through
# the crucible skill's events.sh. The shell checks the command line's form and
# the --grill path; GRILL_JQ checks every value against the draft it changes
# and builds the new one; grill-validator.jq checks the draft read and the
# file about to be written. Only a new draft that passes replaces the old one,
# through a temp file beside it. end first copies the ended grill into the
# next context version's docs folder as grill-<n>.json, so that version
# carries every grill ended before it, then appends the event and removes
# the draft. grill.sh runs only in the main thread, so a draft takes no lock.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../engine/crucible/scripts/lib
set -eu
umask 077

readonly PROG='grill.sh'
readonly PROCEDURE='procedure-grill'
readonly VIEW_LIB='human-view'
readonly SHOW='scripts/show.sh'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly CRUCIBLE_SKILL='crucible'
readonly EFFORT_SKILL='procedure-effort'
# An open grill's draft is <effort>/DRAFTS_FOLDER/GRILL_PREFIX<n>.json; end's
# copy is <effort>/DOCS_FOLDER/GRILL_PREFIX<n>.json.
readonly DRAFTS_FOLDER='drafts/main-thread'
readonly DOCS_FOLDER='drafts/main-thread/context/docs'
readonly GRILL_PREFIX='grill-'
readonly ENDED_TYPE='grill.ended'
# A grill number's digits; far more grills than an effort holds, and far
# below the shell's arithmetic limit.
readonly MAX_NUMBER_DIGITS=9
readonly REQUIRED_TOOLS='date mkdir mktemp mv rm tr'
# The exit of an end refused because the events lock stayed held.
readonly LOCKED_EXIT=7
# The exit of a write refused because the grill's effort is not open.
readonly NOT_OPEN_EXIT=8
NL='
'
readonly NL
# Bounds stderr so a refusal stays readable; the rest is counted.
readonly MAX_PROBLEMS=20
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Parses the command's options ($ARGS.positional, option and value pairs),
# checks each value against the grill file read on stdin (null for new), and
# prints {problems, file, out, view}: the problem lines, the file to write,
# the machine lines for stdout and, for ask, answer and status, the data of
# the card a views/ template lays out.
# The file goes through crucible's prune, so a key with nothing in it is
# left out; a missing questions or answers is read as none.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly GRILL_JQ='include "grill-validator";
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
		{file: {claude_session_id: $session_id, topic: $topic, questions: []}, out: ""});

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
		 view: {round: $round,
			questions: [$file.questions[] | select(.id as $id | $ids | holds($id))
				| {number: (.id | grill_id_number), text, recommendation: .recommendation.text, reason: .recommendation.reason}]}});

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
		   view: {recorded: [$groups[] | select(has("--change-reason") | not) | {id: .["--id"], text: .["--text"]}],
			changed: [$changed[] | .["--id"] as $id
				| {id: $id, text: .["--text"], was: ($file | question_of($id)).answers[-1].text, reason: .["--change-reason"]}],
			reopened: $reopened}});

def status_result:
	. as $file
	| value_of("--id") as $id
	| value_of("--to") as $to
	| value_of("--reason") as $reason
	| result(ended_problems,
		($reason | text_problem("--reason"; grill_max_chars.status_reason)),
		(if ["dropped", "deferred", "open"] | holds($to) then empty else "--to is \($to | shown); expected dropped, deferred or open" end),
		($id | id_problem("--id"; $file)
			// (if ($file | question_of($id)).status == $to then "--id \($id) is \($to) already; expected a question that is not \($to)" else empty end));
		{file: ($file | .questions[($id | grill_id_number) - 1] |= (
			.status = $to
			| if grill_status_prefix | has($to) then .answers += [{revision: ((.answers | length) + 1), at: $at, claude_session_id: $session_id, text: "\(grill_status_prefix[$to])\($reason)"}] else . end)),
		 view: {id: $id, to: $to, reason: $reason}});

# The ended grill, the body of its grill.ended event: the event envelope
# holds the claude_session_id of the file, and the body holds the number.
def end_result:
	result(ended_problems;
		{file: (del(.claude_session_id) | .number = $number | .ended = $at),
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

# list: prints {problems, out} for the $count grills passed as $ARGS.named
# p<i> (the path), g<i> (its text), k<i> (draft or event) and n<i> (a
# draft's number, from its name): each one's problems after its path, else
# one GRILL line per grill, newest first. An event's grill is its body.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly LIST_JQ='include "grill-validator";
def open_count: [(.questions // [])[] | select(.status == "open")] | length;
$ARGS.named as $named
| [range(0; $count) as $i | $named["k\($i)"] as $kind
	| {path: $named["p\($i)"], kind: $kind,
	   file: [$named["g\($i)"] | try fromjson | if $kind == "draft" then . elif type == "object" then .body else null end],
	   number: (if $kind == "draft" then $named["n\($i)"] | tonumber else null end)}]
| map(if .kind == "event" then .number = (.file[0].number? // null) else . end)
| [.[] | select(.kind == "event") | .number] as $ended
| sort_by(.number // 0) | reverse
| [.[] | .path as $path
	| (if (.file | length) == 0 then "is not one JSON value; expected the draft or grill.ended event grill.sh writes" else .file[0] | grill_file_problems end),
	  (if .kind == "draft" and (.number as $number | $ended | index([$number])) then "is the draft of grill \(.number), which has ended; expected only open grills in drafts; remove it" else empty end)
	| "\($path): \(.)"] as $problems
| if ($problems | length) > 0 then {problems: $problems}
  else {problems: [],
	out: map(.file[0] as $file
		| "GRILL: \(.path) · \(if .kind == "event" then "ended" else "open" end) · open \($file | open_count) · \($file.topic)")
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

Writes a grill, the record of one interview of the human, and prints what
each change shows the human. An open grill is the draft
<effort>/${DRAFTS_FOLDER}/${GRILL_PREFIX}<n>.json, <n> its number in the effort
(1 + the highest of the open drafts and ${ENDED_TYPE} events); end turns it
into one ${ENDED_TYPE} event in <effort>/events/. A write replaces the draft
whole only when the new draft passes grill-validator.jq; otherwise it stays
as it was.
Once the grill has ended, every write is refused.

Commands (each page holds its options, output and exit codes):
  new     creates the draft, with its topic and no question
  add     appends questions, each open, under the next unused ids
  ask     prints a round of open questions for the human
  answer  records answers and prints the acknowledgement for the human
  status  drops, defers or reopens a question
  end     ends the grill: one ${ENDED_TYPE} event, and the draft goes
  list    prints the effort's grills, newest first; writes nothing

Ids: q1, q2, ... in the order added, never reused.
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

Creates the draft <effort>/${DRAFTS_FOLDER}/${GRILL_PREFIX}<n>.json, <n> the next grill
number in the effort.

Options:
  --effort FOLDER        the effort folder, as effort.sh start printed it
  --topic TEXT           what the grill is about: one line, at most ${cap_topic}
                         characters

stdout on exit 0: GRILL_FILE: <the draft, absolute>
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
			help_shared exits 'read stdout' write
			;;
		ask)
			print_page <<'EOF'

Prints the next round, numbered one more than the last round asked.

Options:
EOF
			help_shared grill
			print_page <<EOF
  --ids ID,ID,...        1 to ${cap_round} open questions, comma-separated, each once

stdout on exit 0: the round card, each question numbered by its id,
  printed by ${VIEW_LIB}'s show.sh, which records it as owed this session
EOF
			help_shared caps
			help_shared exits 'go on' card
			;;
		answer)
			print_page <<'EOF'

Records one answer per --id group, in order. An open or deferred question
becomes settled. A settled one changes only with --change-reason; its earlier
answers are kept, and its settled children (parent ID) not answered in the
same call go back to open.

Options:
EOF
			help_shared grill
			print_page <<EOF
  --id ID                starts a group: an open, deferred or settled question
  --text TEXT            its answer: one line, at most ${cap_answer} characters
  --change-reason TEXT   why a settled answer changes: one line, at most ${cap_change_reason}
                         characters; only for a settled question

stdout on exit 0: the acknowledgement card, printed by ${VIEW_LIB}'s
  show.sh, which records it as owed this session
EOF
			help_shared caps
			help_shared exits 'go on' card
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

stdout on exit 0: the acknowledgement card, printed by ${VIEW_LIB}'s
  show.sh, which records it as owed this session
EOF
			help_shared caps
			help_shared exits 'go on' card
			;;
		list)
			print_page <<EOF

Prints the effort's grills, newest first by number: the open ones' drafts
and the ended ones' ${ENDED_TYPE} events, each checked against
grill-validator.jq (an event's body).

Options:
  --effort FOLDER        the effort folder, as effort.sh start printed it

stdout on exit 0: one line per grill, none when the effort has none:
  GRILL: <the draft or event, absolute> · <open|ended> · open <n> · <topic>
  (open <n>: how many of its questions are open)
EOF
			help_shared exits 'read stdout' read
			;;
		*)
			print_page <<EOF

Ends the grill: copies the ended grill into the next context version's docs
folder, <effort>/${DOCS_FOLDER}/ (made if missing), as
${GRILL_PREFIX}<n>.json, replacing one there; appends one ${ENDED_TYPE} event,
whose body is the grill without its claude_session_id (the event's), with
its number; then removes the draft. A failed copy or append leaves the
grill not ended.

Options:
EOF
			help_shared grill
			print_page <<EOF

stdout on exit 0, in order:
  GRILL_ENDED: <the draft, absolute> · settled <n> · open <n> ·
    deferred <n> · dropped <n>
  DOCS_FILE: <the copy, absolute>
  EVENT: <the ${ENDED_TYPE} event, absolute>
EOF
			help_shared exits 'read stdout' end
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
# the draft: new (creates it), write (replaces it), card (replaces it and
# shows a card), end (turns it into an event) or read.
help_shared() {
	case $1 in
		grill)
			print_page <<'EOF'
  --grill PATH           the draft, as new printed it
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
  jq package); date, mkdir, mktemp, mv, rm, tr; in the skills: the
  ${CRUCIBLE_SKILL} skill's events.sh, scripts/lib/crucible-space.sh and
  scripts/lib/prune.jq, the ${EFFORT_SKILL} skill's effort.sh (but for
  list) and, for ask, answer and status, the ${VIEW_LIB} skill's
  ${SHOW} and ${RENDER_LIB}; grill-validator.jq beside this
  script and views/grill-round.jq, grill-answer.jq and grill-status.jq in
  this skill.
EOF
			;;
	esac
}

# Prints a command page's stderr lines and exit codes: exit 0's next step $1,
# and the lines kind $2 (new, write, card, end or read, as help_shared exits
# takes) adds.
help_exits() {
	print_page <<EOF

stderr on exit 2: one "${PROG}: <what>; expected <x>" line per problem, at
  most ${MAX_PROBLEMS}, then a count of the rest (a usage error adds a "Try" line)
stderr on exits 1, 3, 5: "${PROG}: install:"; tell the human what it names
  to install, and stop
EOF
	print_page <<EOF

Exit codes:
  0  done; $1
  1  jq missing
  2  refused input, nothing written; fix what stderr names and rerun once,
     else show the human stderr
EOF
	[ "$2" = read ] || print_page <<EOF
     "${PROG}: CLAUDE_CODE_SESSION_ID ...": unset, empty, not a lowercase
       UUID or naming no session transcript; show the human stderr, and stop
EOF
	if [ "$2" = card ]; then
		print_page <<EOF
  3  jq failed, nothing written; or ${VIEW_LIB}'s show.sh failed after the
     write landed (its stderr is above): show the human stderr, and stop
EOF
	else
		print_page <<'EOF'
  3  jq failed, nothing written
EOF
	fi
	if [ "$2" = read ]; then
		print_page <<'EOF'
  4  stdout closed before the output was written, nothing on stderr; stop
     and show the exit code
  5  an install fault: a tool or skill file missing or failing; stderr names
     which
  6  events.sh could not read the effort's events; show the human stderr,
     and stop
  129, 130, 143  stopped by HUP, INT or TERM; tell the human it was stopped,
     show the exit code, and stop
EOF
		return 0
	fi
	print_page <<'EOF'
  4  stdout closed before the output was written, nothing on stderr; the
     write landed; stop and show the exit code
  5  an install fault: a tool or skill file missing or failing; stderr names
     which
  6  the write failed, the draft as it was (new: none left); show the
     human stderr, and stop
EOF
	[ "$2" != end ] || print_page <<EOF
  ${LOCKED_EXIT}  the events lock stayed held; the grill not ended; rerun once, else
     show the human stderr, and stop
EOF
	print_page <<EOF
  ${NOT_OPEN_EXIT}  the grill's effort is not open, or its state is unknown; nothing
     written; show the human stderr, and stop
EOF
	print_page <<'EOF'
  129, 130, 143  stopped by HUP, INT or TERM, the draft whole, as it was
     or as written; tell the human it was stopped, show the exit code, and stop
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

# Sets own_dir, crucible_lib_dir (prune.jq), events_script and, for ask,
# answer and status, views_dir, card (the template's name) and show_script,
# and sources the space rules.
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
	case ${command} in
		ask | answer | status)
			card="grill-${command}"
			[ "${command}" != ask ] || card='grill-round'
			views_dir="${own_dir}/../views"
			render_lib="${skills_dir}/${VIEW_LIB}/${RENDER_LIB}"
			require_skill_file "${render_lib}" "${VIEW_LIB}" 'card printer lib'
			# shellcheck source=../../../../engine/human-view/scripts/lib/render.sh
			. "${render_lib}"
			# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
			hv_check_printer "${skills_dir}/${VIEW_LIB}/scripts" "${views_dir}" "${card}" || install_fault 5 "${hv_printer_problem}"
			show_script=${hv_show}
			;;
		*) ;;
	esac
	crucible_lib_dir="${skills_dir}/${CRUCIBLE_SKILL}/scripts/lib"
	require_skill_file "${crucible_lib_dir}/prune.jq" "${CRUCIBLE_SKILL}" 'prune module'
	events_script="${skills_dir}/${CRUCIBLE_SKILL}/scripts/events.sh"
	require_skill_file "${events_script}" "${CRUCIBLE_SKILL}" 'events.sh'
	space_lib="${crucible_lib_dir}/crucible-space.sh"
	require_skill_file "${space_lib}" "${CRUCIBLE_SKILL}" 'space rules'
	if [ "${command}" != list ]; then
		effort_script="${skills_dir}/${EFFORT_SKILL}/scripts/effort.sh"
		require_skill_file "${effort_script}" "${EFFORT_SKILL}" 'effort.sh'
	fi
	# shellcheck source=crucible-space.sh
	. "${space_lib}"
}

# Sets session_id from CLAUDE_CODE_SESSION_ID by the space rules, or exits 2
# before any file is made.
require_session() {
	# shellcheck disable=SC2310 # its status says whether the session is usable; the problem is read here
	crucible_check_session || exit_on_problems "${crucible_session_problem}"
	session_id=${crucible_session_id}
}

# Exits NOT_OPEN_EXIT unless effort folder $1 is open, as effort.sh state, the
# one owner of the state rule, reads it; a state it cannot read refuses too.
require_open_effort() {
	if effort_state_out=$(sh "${effort_script}" state --effort "$1" </dev/null); then
		effort_state_status=0
	else
		effort_state_status=$?
	fi
	effort_name=${1##*/}
	# shellcheck disable=SC2310 # the folder passed the space rules, so its name splits
	crucible_split_id "${effort_name}" && effort_name=${crucible_name_rest}
	case ${effort_state_status} in
		0) ;;
		5) install_fault 5 'effort.sh state names a missing dependency above; install it, then rerun' ;;
		*) die "${NOT_OPEN_EXIT}" "effort ${effort_name}'s state is unknown (effort.sh state exited ${effort_state_status}; its stderr is above); expected an open effort; ask the human to check the effort" ;;
	esac
	effort_state=${effort_state_out%%"${NL}"*}
	case ${effort_state} in
		'STATE: open') ;;
		'STATE: paused' | 'STATE: completed' | 'STATE: dropped')
			die "${NOT_OPEN_EXIT}" "effort ${effort_name} is ${effort_state#STATE: }; expected an open effort; ask the human to reopen it"
			;;
		*) die "${NOT_OPEN_EXIT}" "effort ${effort_name}'s state is unknown (effort.sh state printed no known state); expected an open effort; ask the human to check the effort" ;;
	esac
}

# Sets path_problem to the problem of the --grill path, or to nothing when
# it names an open grill's draft in an effort of the space; then sets
# grill_effort to that effort and grill_number to the draft's number. The
# file itself is checked once the grill is known not to have ended.
check_grill_path() {
	path_problem=''
	case ${grill} in
		*[[:cntrl:]]*)
			path_problem='--grill holds a control character (such as a line break); expected one absolute path'
			return 0
			;;
		/*) ;;
		*)
			path_problem="--grill ${grill} is not absolute; expected the absolute path ${PROG} new printed"
			return 0
			;;
	esac
	# shellcheck disable=SC2310 # its status says whether the space is usable; the problem is read here
	if ! crucible_resolve_root; then
		path_problem="CRUCIBLE_HOME: ${crucible_root_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status says whether the path is an item's; the problem is read here
	if ! crucible_check_effort_item "${grill}" "${DRAFTS_FOLDER}"; then
		path_problem="--grill ${grill} is ${crucible_item_problem}"
		return 0
	fi
	grill_effort=${crucible_effort}
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	if ! number_of_draft_name "${grill##*/}"; then
		path_problem="--grill ${grill} is not named ${GRILL_PREFIX}<n>.json; expected the draft ${PROG} new printed"
		return 0
	fi
	grill_number=${name_number}
}

# Succeeds when file name $1 is a draft's, GRILL_PREFIX<n>.json with <n> a
# whole number from 1, and sets name_number to <n>.
number_of_draft_name() {
	name_number=${1#"${GRILL_PREFIX}"}
	name_number=${name_number%.json}
	[ "${GRILL_PREFIX}${name_number}.json" = "$1" ] || return 1
	case ${name_number} in
		'' | 0* | *[!0123456789]*) return 1 ;;
		*) ;;
	esac
	[ "${#name_number}" -le "${MAX_NUMBER_DIGITS}" ]
}

# Exits 2 when grill grill_number of grill_effort has a grill.ended event, or
# when its draft is no readable, writable regular file.
require_open_grill() {
	read_events slurp --effort "${grill_effort}" --type "${ENDED_TYPE}"
	ended_grills=${events_out}
	ended_seq=$(printf '%s\n' "${ended_grills}" | jq -r --argjson number "${grill_number}" '[.[] | select(.body.number == $number) | .seq][0] // empty') ||
		install_fault 3 'jq failed reading the ended grills; expected jq 1.6+; try jq --version, then rerun'
	[ -z "${ended_seq}" ] ||
		exit_on_problems "--grill ${grill}: grill ${grill_number} ended (its ${ENDED_TYPE} event is seq ${ended_seq}); expected a grill that has not ended; start another with ${PROG} new"
	[ -f "${grill}" ] && [ ! -L "${grill}" ] && [ -r "${grill}" ] && [ -w "${grill}" ] ||
		exit_on_problems "--grill ${grill} is not a readable, writable regular file, or is a symbolic link; expected the draft ${PROG} new printed"
}

# Sets events_out to the stdout of the read events.sh "$@", or exits 5 on an
# install fault it names and 6 on any other failure.
read_events() {
	if events_out=$(sh "${events_script}" "$@" </dev/null); then
		events_status=0
	else
		events_status=$?
	fi
	case ${events_status} in
		0) ;;
		5) install_fault 5 "events.sh $1 names a missing dependency above; install it, then rerun" ;;
		*) die 6 "events.sh $1 failed (exit ${events_status}; its stderr is above); expected the effort's ${ENDED_TYPE} events; try the fix it names, then rerun" ;;
	esac
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
	jq -c -L "${own_dir}" -L "${crucible_lib_dir}" --arg command "${command}" --arg at "${at}" --arg grill "${grill}" \
		--arg session_id "${session_id}" --arg prog "${PROG}" --argjson number "${grill_number}" "${GRILL_JQ}" --args -- "$@"
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

# Removes the temp files and, on a failing exit, the draft and the docs copy
# this run made.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	exit_status=$?
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ -z "${docs_temp}" ] || rm -f "${docs_temp}"
	[ "${exit_status}" -ne 0 ] || return 0
	for made_file in "${created_file}" "${docs_made}"; do
		[ -n "${made_file}" ] || continue
		rm -f "${made_file}" && warn "removed ${made_file}, made by this run"
	done
}

# Writes result's file through a temp file beside path $1 and checks it
# against the validator; sets temp_file to it.
stage_file() {
	temp_file=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") ||
		die 6 "mktemp could not create a temp file beside $1; expected a writable ${1%/*}; try checking its permissions and free space, then rerun"
	printf '%s\n' "${result}" | jq '.file' >"${temp_file}" ||
		die 6 "could not write the temp file ${temp_file}; expected the grill written; try checking free space, then rerun"
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	written_problems=$(file_problems "${temp_file}" 'the file this call would write: ') ||
		install_fault 3 'jq failed on the grill validator; expected jq 1.6+; try jq --version, then rerun'
	exit_on_problems "${written_problems}"
}

# Writes result's file over path $1, once it passes the validator.
write_file() {
	stage_file "$1"
	mv -f "${temp_file}" "$1" ||
		die 6 "mv could not move the temp file onto $1; expected the draft in place; try checking the permissions and free space of ${1%/*}, then rerun"
	temp_file=''
}

# end: copies the ended grill into the docs folder, appends it as the
# grill.ended event, then removes the draft; sets docs_copy and event_file.
end_grill() {
	stage_file "${grill}"
	copy_into_docs "${temp_file}"
	append_ended_event
	docs_made=''
	rm -f "${grill}" ||
		die 6 "grill ${grill_number} ended (${event_file}), but rm could not remove its draft ${grill}; expected it gone; remove it by hand"
}

# end: copies file $1 into the next context version's docs folder, made if
# missing, as GRILL_PREFIX<n>.json, through a temp file in the drafts folder,
# so the docs folder never holds a part of it; sets docs_copy and docs_made.
copy_into_docs() {
	docs_dir="${grill_effort}/${DOCS_FOLDER}"
	mkdir -p "${docs_dir}" 2>/dev/null || [ -d "${docs_dir}" ] ||
		die 6 "mkdir could not create ${docs_dir}; expected a writable effort folder; the grill is not ended; try checking its permissions, then rerun"
	docs_copy="${docs_dir}/${GRILL_PREFIX}${grill_number}.json"
	# shellcheck disable=SC2310 # its status says whether the path is an item's; the problem is read here
	crucible_check_effort_item "${docs_copy}" "${DOCS_FOLDER}" ||
		die 6 "the docs copy ${docs_copy} is ${crucible_item_problem}; the grill is not ended; try moving the link aside, then rerun"
	docs_temp=$(mktemp "${grill%/*}/.${docs_copy##*/}.docs.XXXXXX") ||
		die 6 "mktemp could not create a temp file in ${grill%/*}; expected a writable folder; the grill is not ended; try checking its permissions, then rerun"
	jq '.' <"$1" >"${docs_temp}" ||
		die 6 "could not copy the grill into ${docs_temp}; expected the copy written; the grill is not ended; try checking free space, then rerun"
	mv -f "${docs_temp}" "${docs_copy}" ||
		die 6 "mv could not move the copy onto ${docs_copy}; expected the copy in place; the grill is not ended; try checking the folder's permissions, then rerun"
	docs_temp=''
	docs_made=${docs_copy}
}

# end: appends the staged ended grill as the grill.ended event through
# events.sh; sets event_file.
append_ended_event() {
	if event_file=$(sh "${events_script}" append --effort "${grill_effort}" --type "${ENDED_TYPE}" --by "${PROG}" \
		--body-file "${temp_file}" --session "${session_id}" </dev/null); then
		append_status=0
	else
		append_status=$?
	fi
	case ${append_status} in
		0) ;;
		3) die "${NOT_OPEN_EXIT}" "events.sh refused the ${ENDED_TYPE} event (its stderr is above); the grill is not ended; expected an open effort; ask the human to check the effort" ;;
		5) install_fault 5 'events.sh append names a missing dependency above; install it, then rerun' ;;
		6) die "${LOCKED_EXIT}" "the events lock of ${grill_effort} stayed held (events.sh stderr above); the grill is not ended; rerun once" ;;
		*) die 6 "events.sh append failed (exit ${append_status}; its stderr is above); the grill is not ended; try the fix it names, then rerun" ;;
	esac
}

# new: creates the empty draft of the effort's next grill number, never
# overwriting one, and sets grill and grill_number to it.
create_draft() {
	drafts_dir="${effort_dir}/${DRAFTS_FOLDER}"
	mkdir -p "${drafts_dir}" 2>/dev/null || [ -d "${drafts_dir}" ] ||
		die 6 "mkdir could not create ${drafts_dir}; expected a writable effort folder; try checking its permissions, then rerun"
	read_events slurp --effort "${effort_dir}" --type "${ENDED_TYPE}"
	next_grill_number "${events_out}"
	grill="${drafts_dir}/${GRILL_PREFIX}${grill_number}.json"
	# effort_problem resolved the root in a subshell; this sets crucible_root here.
	# shellcheck disable=SC2310 # its status says whether the space is usable; the problem is read here
	crucible_resolve_root || exit_on_problems "CRUCIBLE_HOME: ${crucible_root_problem}"
	# shellcheck disable=SC2310 # its status says whether the path is an item's; the problem is read here
	crucible_check_effort_item "${grill}" "${DRAFTS_FOLDER}" ||
		die 6 "the draft ${grill} is ${crucible_item_problem}; try moving the link aside, then rerun"
	if (
		set -C
		: >"${grill}"
	) 2>/dev/null; then
		created_file=${grill}
		return 0
	fi
	die 6 "could not create the draft ${grill}, or it exists; expected a new file; try checking the permissions of ${drafts_dir}, then rerun"
}

# Sets grill_number to 1 + the highest number of the open drafts in
# drafts_dir and of the grill.ended events in JSON array $1.
next_grill_number() {
	highest=$(printf '%s\n' "$1" | jq -r '[.[].body.number | numbers] | max // 0 | tostring') ||
		install_fault 3 'jq failed reading the ended grills; expected jq 1.6+; try jq --version, then rerun'
	case ${highest} in
		'' | *[!0123456789]*) die 6 "a ${ENDED_TYPE} event of ${effort_dir} holds the number ${highest}; expected a whole number; ask the human to check the effort's events" ;;
		*) ;;
	esac
	[ "${#highest}" -le "${MAX_NUMBER_DIGITS}" ] ||
		die 6 "a ${ENDED_TYPE} event of ${effort_dir} holds a number of over ${MAX_NUMBER_DIGITS} digits; expected a grill number; ask the human to check the effort's events"
	for draft in "${drafts_dir}/${GRILL_PREFIX}"*.json; do
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		number_of_draft_name "${draft##*/}" || continue
		[ "${name_number}" -le "${highest}" ] || highest=${name_number}
	done
	grill_number=$((highest + 1))
}

# list: sets result to LIST_JQ's output over the effort's drafts and its
# grill.ended events, or exits 2 on a file in its drafts that is no draft.
list_grills() {
	set_effort_dir
	case ${effort_dir} in
		*[[:cntrl:]]*) exit_on_problems '--effort holds a control character (such as a line break); expected one absolute path' ;;
		*) ;;
	esac
	drafts_dir="${effort_dir}/${DRAFTS_FOLDER}"
	if [ -L "${drafts_dir}" ] || { [ -e "${drafts_dir}" ] && [ ! -d "${drafts_dir}" ]; }; then
		exit_on_problems "--effort ${effort}: ${DRAFTS_FOLDER}/ is a symbolic link or not a folder; expected the real folder ${PROG} new creates"
	fi
	# An unreadable folder globs to nothing, which would read as no grills.
	if [ -d "${drafts_dir}" ] && { [ ! -r "${drafts_dir}" ] || [ ! -x "${drafts_dir}" ]; }; then
		exit_on_problems "--effort ${effort}: cannot read ${drafts_dir}; expected a readable folder; try checking its permissions"
	fi
	set --
	listed_count=0 listed_problems=''
	if [ -d "${drafts_dir}" ]; then
		for listed_file in "${drafts_dir}/${GRILL_PREFIX}"*.json; do
			[ -e "${listed_file}" ] || [ -L "${listed_file}" ] || continue
			# shellcheck disable=SC2310 # a pure test; its status is the answer
			if number_of_draft_name "${listed_file##*/}" && [ -f "${listed_file}" ] && [ ! -L "${listed_file}" ] && [ -r "${listed_file}" ]; then
				set -- "$@" --arg "p${listed_count}" "${listed_file}" --rawfile "g${listed_count}" "${listed_file}" \
					--arg "k${listed_count}" draft --arg "n${listed_count}" "${name_number}"
				listed_count=$((listed_count + 1))
			else
				listed_problems="${listed_problems:+${listed_problems}
}${listed_file}: is not a readable regular file named ${GRILL_PREFIX}<n>.json, or is a symbolic link; expected only the drafts ${PROG} new writes"
			fi
		done
	fi
	exit_on_problems "${listed_problems}"
	read_events list --effort "${effort_dir}" --type "${ENDED_TYPE}"
	while IFS= read -r listed_file; do
		[ -n "${listed_file}" ] || continue
		set -- "$@" --arg "p${listed_count}" "${listed_file}" --rawfile "g${listed_count}" "${listed_file}" \
			--arg "k${listed_count}" event --arg "n${listed_count}" ''
		listed_count=$((listed_count + 1))
	done <<EOF
${events_out}
EOF
	result=$(jq -n -c -L "${own_dir}" --argjson count "${listed_count}" "$@" "${LIST_JQ}" </dev/null) ||
		install_fault 3 'jq failed on the grills; expected jq 1.6+; try jq --version, then rerun'
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

# ask, answer and status: prints result's card through show.sh view,
# recorded as owed for the grill's effort; a closed stdout exits 4 before
# anything is recorded.
show_card() {
	{ true 3>&1; } 2>/dev/null || exit 4
	view_data=$(printf '%s\n' "${result}" | jq -c '.view') ||
		install_fault 3 'jq failed reading the card'"'"'s data; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${show_script}" "${views_dir}" "${card}" "${grill_effort}" "${view_data}" && return 0
	[ "${hv_render_status}" != 5 ] || install_fault 5 "${hv_render_problem}; expected the ${VIEW_LIB} skill installed whole"
	install_fault 3 "${hv_render_problem}; expected the card shown from views/${card}.jq; try reinstalling ${PROCEDURE} and ${VIEW_LIB}"
}

# list: prints a line per grill file of the effort; reads only.
list_command() {
	setup_problems=$(effort_problem)
	exit_on_problems "${setup_problems}"
	list_grills
	exit_on_result_problems ''
	print_result_out
}

# Every other command: checks its input against the draft it reads (none
# for new), writes the new draft, or for end the grill.ended event, and
# prints its output.
write_command() {
	require_session
	if [ "${command}" = new ]; then
		setup_problems=$(effort_problem)
	else
		check_grill_path
		exit_on_problems "${path_problem}"
		require_open_effort "${grill_effort}"
		require_open_grill
		# shellcheck disable=SC2310 # its status is jq's; a failure exits
		read_problems=$(file_problems "${grill}" "--grill ${grill}: ") ||
			install_fault 3 'jq failed on the grill validator; expected jq 1.6+; try jq --version, then rerun'
		exit_on_problems "${read_problems}"
		setup_problems=''
	fi
	run_grill_jq "$@"
	exit_on_result_problems "${setup_problems}"
	if [ "${command}" = new ]; then
		set_effort_dir
		require_open_effort "${effort_dir}"
		create_draft
	fi
	if [ "${command}" = end ]; then
		end_grill
	else
		write_file "${grill}"
	fi
	created_file=''
	case ${command} in
		new) print_out "GRILL_FILE: ${grill}" ;;
		end)
			print_result_out
			print_out "DOCS_FILE: ${docs_copy}"
			print_out "EVENT: ${event_file}"
			;;
		add) print_result_out ;;
		*) show_card ;;
	esac
}

temp_file='' created_file='' session_id='' docs_temp='' docs_copy='' docs_made='' event_file='' grill_number=0
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
