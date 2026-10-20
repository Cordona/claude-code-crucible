#!/usr/bin/env sh
# Writes one agent context file from the main thread's choices, so the context
# JSON is never typed by hand. Every input is checked first and every problem
# reported, before any file is created: the JSON is built with stand-in
# Crucible paths and checked by agent-context-validator.jq and agent-context-file-checks.sh,
# each problem named by the option that produced its field. Only then is it
# written atomically into the file crucible.sh hands out, and checked again as
# prepare-agent-prompt.sh checks it.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='generate-agent-context.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly REQUIRED_TOOLS='cat mktemp mv rm tr wc'
# crucible.sh new's label cap (its MAX_LABEL_CHARS); change both together.
readonly MAX_LABEL_CHARS=60
readonly TEXT_LABEL_SUFFIX='-text'
# Stands for the parts of a Crucible path only crucible.sh new knows, so the
# JSON can be checked at its final length before any file exists.
readonly PLACEHOLDER_ITEM='0000/00/00/context/00000000T000000-0000'
TAB=$(printf '\t')
readonly TAB
NL='
'
readonly NL
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Builds the context JSON from the entries (mode "context"), or names each
# problem found in it by its option (mode "report": one stderr line each). The
# entries arrive as positional triples: kind (path, link, note or text), value,
# why ("" for a note). The problems are the validator's, as JSON lines, and the
# file checks', as "<entry index>\t<problem>" lines.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly CONTEXT_JQ='
def entries: $ARGS.positional | [range(0; length / 3) as $n
	| {index: $n, kind: .[$n * 3], value: .[$n * 3 + 1], why: .[$n * 3 + 2]}];
# The entries in the order of the context lists they fill.
def listed($entries): {
	paths: ([$entries[] | select(.kind == "path")] + [$entries[] | select(.kind == "text")]),
	links: [$entries[] | select(.kind == "link")],
	notes: [$entries[] | select(.kind == "note")]};
def or_null: if length == 0 then null else . end;
def context: listed(entries) as $listed | {
	paths: ($listed.paths | map({path: (if .kind == "text" then $text_path else .value end), why}) | or_null),
	links: ($listed.links | map({url: .value, why}) | or_null),
	notes: ($listed.notes | map(.value))};

# A long value keeps its start and end, where a path or URL differs most.
def max_shown_chars: 80;
def shown: tojson | gsub("[[:cntrl:]]"; "?") | if length > max_shown_chars then .[:40] + "…" + .[-39:] else . end;
def option: {path: "--path", link: "--link", note: "--note", text: "--text-file"}[.];
# Problems of the Crucible space sort after those of the entries.
def space_order: 1e9;
def problem_line($order; $option; $value; $problem): {order: $order, text: "\($prog): \($option) \($value | shown): \($problem)"};
def file_problems: [$file_problem_lines | split("\n")[] | select(. != "") | split("\t") | {index: (.[0] | tonumber), problem: .[1]}];
def validator_problems: [$validator_problem_lines | split("\n")[] | select(. != "") | fromjson];
# Names validator problem . by the option behind its field. A path field the
# file checks already refused is left out; the path of the text entry belongs
# to the Crucible space.
def validator_line($listed; $refused):
	.at as $at | .problem as $problem
	| (if ($at | type) == "array" and ($at | length) >= 2 then $listed[$at[0]][$at[1]] else null end) as $entry
	| if $entry == null then {order: -1, text: "\($prog): context file: \($at | tojson) \($problem)"}
	  elif $at[2] == "why" then problem_line($entry.index; "--why"; $entry.why; $problem)
	  elif $entry.kind == "text" then problem_line(space_order; "CRUCIBLE_HOME"; $space_root; $problem)
	  elif $at[0] == "paths" and ($refused | index([$entry.index])) != null then empty
	  else problem_line($entry.index; $entry.kind | option; $entry.value; $problem) end;
def report: entries as $entries | file_problems as $files
	| [($files[] | .problem as $problem | $entries[.index] | problem_line(.index; .kind | option; .value; $problem)),
	   (validator_problems[] | validator_line(listed($entries); $files | map(.index))),
	   (if $space_problem == "" then empty else problem_line(space_order; "CRUCIBLE_HOME"; $space_root; $space_problem) end)]
	| reduce .[] as $line ([]; if any(.[]; .text == $line.text) then . else . + [$line] end)
	| sort_by(.order)[].text;

if $mode == "report" then report else context end
'

usage() {
	context_cap='the size cap of agent-context-file-checks.sh'
	# shellcheck disable=SC2310 # its status says whether the lib was found; errexit adds nothing
	if load_context_lib && [ -n "${context_max_bytes:-}" ]; then
		context_cap="${context_max_bytes} bytes"
	fi
	cat <<EOF
Usage: sh ${PROG} --label LABEL [--session ID] [--path ABS --why LINE]...
           [--link URL --why LINE]... [--text-file FILE --why LINE]
           [--note TEXT]...
       sh ${PROG} --help

Writes one agent context file, the file a dispatch's context.path names and
prepare-agent-prompt.sh sends the agent, into the Crucible space, and prints its path and
sha256. Every input is checked first; on any problem no file is created.

  --label LABEL   the context file's crucible.sh label: lowercase a-z, 0-9
                  and -, 1 to ${MAX_LABEL_CHARS} characters (with --text-file at most
                  $((MAX_LABEL_CHARS - ${#TEXT_LABEL_SUFFIX})), since that file's label is LABEL${TEXT_LABEL_SUFFIX}). Required.
  --session ID    passed to crucible.sh new --session for every file created.
  --path ABS      a file or folder the agent reads. It must be absolute and
                  hold no control character, no double quote and no ..
                  segment, must not name a sensitive file or folder in any
                  letter case (a basename .env*, *.pem, *.key or id_*, or a
                  .git component), must not be a symlink (its folders may
                  be), and must be an existing readable regular file or
                  folder. Trailing slashes are dropped.
  --link URL      http:// or https://, then a host of letters, digits, dots
                  and hyphens with an optional :port, then optionally a path,
                  query or fragment of letters, digits and
                  . _ ~ / ? # = % : + , @ - only (no space, quote, ; \$ \` ( ) & | < or >).
  --text-file FILE  a readable regular file (same path rules as --path, a
                  folder excluded) holding the human's long verbatim text, as
                  valid UTF-8. Its content is copied exactly into a second
                  file, made by crucible.sh new --kind context --label
                  LABEL${TEXT_LABEL_SUFFIX}, holding {"text": "<the content>"}, and that
                  file is the last entry of paths. At most one. Its content
                  is not checked for the texts below: the agent reads it with
                  Read, it is not injected.
  --why LINE      why the agent needs the entry before it: one non-empty line
                  without control characters. Exactly one right after each
                  --path, --link and --text-file, and nowhere else.
  --note TEXT     any text, kept in order. At least one is required: the
                  human's request or a note.
No value but a note may hold a control character.

The context file (at most ${context_cap}, checked by
agent-context-validator.jq as prepare-agent-prompt.sh checks it, before
and after it is written):
  {"paths": null | [{"path": str, "why": str}, ...],
   "links": null | [{"url": str, "why": str}, ...],
   "notes": [str, ...]}
paths and links in the order given (the --text-file entry last in paths),
null when there is none of that kind.

Files are made by \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/crucible/scripts/crucible.sh
new, in the space \${CRUCIBLE_HOME:-\$HOME/.crucible}; each is written to a temp
file in its folder, then moved onto the path crucible.sh printed.

Output (stdout, exactly two lines, on exit 0):
  CONTEXT_FILE: <absolute path of the context file>
  CONTEXT_SHA256: <64 lowercase hex sha256 of that file>
Problems (stderr, one line each; every problem of the inputs is listed):
  ${PROG}: <option> <value as a JSON string, its middle cut past 80 characters>: <problem>; expected <x>

Exit codes:
  0  the file written; its path and sha256 printed
  1  crucible.sh new failed (its stderr is printed), or writing or checking a
     file failed after crucible.sh created it; one stderr line names each
     file created
  2  usage error: an unknown option, an option without its value, a --why not
     right after an entry, an entry without its --why, a second --label,
     --session or --text-file, --label missing or bad, or no --note
  3  invalid input, one stderr line per problem; no file created
  5  a dependency missing, with the fix named: jq 1.6+, sha256sum or shasum,
     crucible.sh, agent-context-file-checks.sh or agent-context-validator.jq beside this
     script, or a base tool below
  129, 130, 143  stopped by HUP, INT or TERM; the temp file is removed

Dependencies: POSIX sh; jq 1.6+ (--args, \$ARGS, --rawfile); cat, mktemp, mv,
rm, tr, wc; sha256sum or shasum (macOS: shasum -a 256); crucible.sh;
agent-context-file-checks.sh and agent-context-validator.jq beside this script.
Reads only: the --text-file content; for --path, only whether it exists and
its type.
Runtime: about 0.16 s with a path, a text file and a note; measured on macOS
(average of 5 runs).
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
remove_temp_file() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
}

# Handles option $1 when no option value is awaited: sets awaited_option, or exits 2.
take_option() {
	case $1 in
		--help | -h)
			usage
			exit 0
			;;
		--why)
			[ -n "${entry_kind}" ] ||
				usage_error '--why without an entry before it; expected each --why right after a --path, --link or --text-file value'
			;;
		--label | --session | --path | --link | --text-file | --note)
			[ -z "${entry_kind}" ] || missing_why_error
			;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --label, --session, --path, --link, --text-file, --why, --note or --help"
			;;
	esac
	awaited_option=$1
}

# Exits 2 naming the pending entry, which has no --why.
missing_why_error() {
	case ${entry_kind} in
		text) entry_option='--text-file' ;;
		*) entry_option="--${entry_kind}" ;;
	esac
	shown_entry=$(printable "${entry_value}")
	usage_error "${entry_option} ${shown_entry} has no --why; expected --why LINE right after it"
}

# Takes value $2 of option $1. Sets is_entry_complete=true when the value
# completes an entry (a --why or a --note), with entry_kind, entry_value and
# entry_why holding it.
take_value() {
	is_entry_complete=false
	case $1 in
		--label)
			[ -z "${label_given}" ] || usage_error '--label given twice; expected one --label'
			label_given=true
			label=$2
			;;
		--session)
			[ -z "${session_given}" ] || usage_error '--session given twice; expected at most one --session'
			[ -n "$2" ] || usage_error '--session is empty; expected --session ID'
			session_given=true
			session=$2
			;;
		--path)
			trimmed_path=$(without_trailing_slashes "$2")
			start_entry path "${trimmed_path}"
			;;
		--link) start_entry link "$2" ;;
		--text-file)
			[ "${text_file_count}" -eq 0 ] || usage_error '--text-file given twice; expected at most one --text-file'
			text_file_count=1
			start_entry text "$2"
			;;
		--note)
			note_count=$((note_count + 1))
			finish_entry note "$2" ''
			;;
		*) finish_entry "${entry_kind}" "${entry_value}" "$2" ;;
	esac
}

start_entry() {
	entry_kind=$1
	entry_value=$2
}

finish_entry() {
	entry_kind=$1
	entry_value=$2
	entry_why=$3
	is_entry_complete=true
}

# Prints path $1 without trailing slashes ("/" stays "/").
without_trailing_slashes() {
	trimmed=$1
	while [ "${trimmed}" != '/' ] && [ "${trimmed%/}" != "${trimmed}" ]; do
		trimmed=${trimmed%/}
	done
	printf '%s' "${trimmed}"
}

# Exits 2 on an option left without its value or its --why, or a missing or bad label or note.
finish_parse() {
	[ -z "${awaited_option}" ] || usage_error "${awaited_option} needs a value; expected ${awaited_option} VALUE"
	[ -z "${entry_kind}" ] || missing_why_error
	[ -n "${label_given}" ] || usage_error '--label missing; expected --label LABEL'
	max_label_chars=${MAX_LABEL_CHARS}
	[ "${text_file_count}" -eq 0 ] || max_label_chars=$((MAX_LABEL_CHARS - ${#TEXT_LABEL_SUFFIX}))
	label_rule="lowercase a-z, 0-9 and -, 1 to ${max_label_chars} characters"
	[ "${text_file_count}" -eq 0 ] || label_rule="${label_rule} (the text file's label adds ${TEXT_LABEL_SUFFIX})"
	case ${label} in
		'' | *[!a-z0-9-]*) usage_error "--label is not ${label_rule}; expected --label LABEL" ;;
		*) ;;
	esac
	[ "${#label}" -le "${max_label_chars}" ] || usage_error "--label is longer than ${max_label_chars} characters; expected ${label_rule}"
	[ "${note_count}" -gt 0 ] || usage_error '--note missing; expected at least one --note TEXT: the human'\''s request or a note'
}

# Exits 5 unless jq, a sha256 tool, crucible.sh and both libs are in place;
# sources agent-context-file-checks.sh and sets crucible_script and validator.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 5 'jq missing; expected jq 1.6+ on PATH; install it (macOS: brew install jq; Linux: the distro'\''s jq package)'
	validator=$(script_dir)/agent-context-validator.jq
	# shellcheck disable=SC2310 # its status says whether the lib was found; errexit adds nothing
	load_context_lib ||
		die 5 "context path check missing; expected ${context_lib}; reinstall the ${PROCEDURE} skill"
	case ${context_max_bytes:-} in
		'' | *[!0-9]*) die 5 "context size cap unset or not a number in ${context_lib}; expected context_max_bytes as digits; reinstall the ${PROCEDURE} skill" ;;
		*) ;;
	esac
	[ -f "${validator}" ] && [ -r "${validator}" ] ||
		die 5 "context validator missing; expected ${validator}; reinstall the ${PROCEDURE} skill"
	# shellcheck disable=SC2310 # its status is the lookup result; errexit adds nothing
	find_context_digest_tool ||
		die 5 'sha256sum and shasum missing; expected one of them on PATH; install coreutils (Linux) or use the system shasum (macOS)'
	crucible_script="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/crucible/scripts/crucible.sh"
	[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
		die 5 "crucible.sh missing; expected ${crucible_script}; install the crucible skill"
}

# Sets context_lib and sources it when it is a readable file; fails otherwise.
load_context_lib() {
	context_lib=$(script_dir)/agent-context-file-checks.sh
	[ -f "${context_lib}" ] && [ -r "${context_lib}" ] || return 1
	# shellcheck source=agent-context-file-checks.sh
	. "${context_lib}"
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets file_problems to one "<entry index>\t<problem>" line per --path or
# --text-file entry that fails a file check; the entries are the triples in "$@".
collect_file_problems() {
	file_problems=''
	entry_index=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			path) found_problem=$(path_entry_problem "$2") ;;
			text) found_problem=$(text_file_problem "$2") ;;
			*) found_problem='' ;;
		esac
		[ -z "${found_problem}" ] || file_problems="${file_problems}${entry_index}${TAB}${found_problem}${NL}"
		entry_index=$((entry_index + 1))
		shift 3
	done
}

# Prints the first problem of --path value $1, or nothing.
path_entry_problem() {
	# shellcheck disable=SC2310 # its status says whether it printed a problem
	shared_path_problem "$1" && return 0
	if [ -d "$1" ]; then
		[ -r "$1" ] && [ -x "$1" ] || printf 'folder is unreadable; expected a folder the agent can list'
	elif [ -f "$1" ]; then
		[ -r "$1" ] || printf 'file is unreadable; expected a file the agent can read'
	elif [ -e "$1" ]; then
		printf 'path is not a regular file or a folder; expected an existing file or folder'
	else
		printf 'path does not exist; expected an existing file or folder'
	fi
}

# Prints the first problem of --text-file value $1, or nothing.
text_file_problem() {
	# shellcheck disable=SC2310 # its status says whether it printed a problem
	shared_path_problem "$1" && return 0
	[ -f "$1" ] && [ -r "$1" ] || {
		printf 'file is missing, unreadable or not a regular file; expected a readable regular file'
		return 0
	}
	# shellcheck disable=SC2310 # its status is the check result; errexit adds nothing
	text_is_utf8 "$1" || printf 'file is not valid UTF-8 text; expected the human'\''s text as UTF-8'
}

# Prints the problem of path $1 that agent-context-file-checks.sh or a symlink check
# finds and succeeds, or prints nothing and fails.
shared_path_problem() {
	shared_problem=$(context_path_problem "$1")
	if [ -n "${shared_problem}" ]; then
		printf '%s; expected %s' "${shared_problem}" "${context_path_expected}"
		return 0
	fi
	[ -L "$1" ] || return 1
	printf 'path is a symlink; expected the real file or folder it points to'
}

# Succeeds when file $1 reads back unchanged through jq --rawfile, which turns
# invalid UTF-8 into U+FFFD, so the bytes it would write are the file's bytes.
text_is_utf8() {
	# shellcheck disable=SC2310 # the caller reports a failure; errexit adds nothing
	file_digest=$(digest_stdin <"$1") || return 1
	# shellcheck disable=SC2310 # the caller reports a failure; errexit adds nothing
	text_digest=$(jq -nj --rawfile text "$1" '$text' </dev/null | digest_stdin) || return 1
	[ "${file_digest%% *}" = "${text_digest%% *}" ]
}

digest_stdin() {
	if [ "${context_digest_tool}" = shasum ]; then
		shasum -a 256
	else
		sha256sum
	fi
}

# Runs CONTEXT_JQ in mode $1 with text path $2 over the entry triples after them.
run_context_jq() {
	run_mode=$1
	run_text_path=$2
	shift 2
	jq -nr --arg prog "${PROG}" --arg mode "${run_mode}" --arg text_path "${run_text_path}" \
		--arg file_problem_lines "${file_problems}" --arg validator_problem_lines "${validator_problems}" \
		--arg space_root "${space_root}" --arg space_problem "${space_problem}" \
		"${CONTEXT_JQ}" --args -- "$@" </dev/null
}

# Sets space_root, the placeholder paths and space_problem, the main
# placeholder path's problem as agent-context-file-checks.sh finds it.
plan_space_paths() {
	if [ -n "${CRUCIBLE_HOME:-}" ]; then
		space_root=$(without_trailing_slashes "${CRUCIBLE_HOME}")
	else
		space_root="${HOME:-}/.crucible"
	fi
	placeholder_context="${space_root}/${PLACEHOLDER_ITEM}-${label}.json"
	placeholder_text="${space_root}/${PLACEHOLDER_ITEM}-${label}${TEXT_LABEL_SUFFIX}.json"
	space_problem=$(context_path_problem "${placeholder_context}")
	[ -z "${space_problem}" ] || space_problem="${space_problem}; expected ${context_path_expected}"
}

# Exits 3 after printing every problem the file checks, the validator and the
# size cap find in the context the entries in "$@" make, built with the
# placeholder paths before any file exists.
report_input_problems() {
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	planned_json=$(run_context_jq context "${placeholder_text}" "$@") ||
		die 5 "jq failed building the context; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	validator_problems=$(printf '%s\n' "${planned_json}" |
		jq -cs --arg format json --arg context_path "${placeholder_context}" -f "${validator}") ||
		die 5 'jq failed on the context validator; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	problems=$(run_context_jq report '' "$@") ||
		die 5 "jq failed reporting the inputs' problems; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	# shellcheck disable=SC2310 # a failure has printed its cause; this passes its exit on
	size_problem=$(context_size_problem "${planned_json}") || exit "$?"
	[ -z "${size_problem}" ] || problems="${problems}${problems:+${NL}}${PROG}: context file: ${size_problem}"
	[ -n "${problems}" ] || return 0
	printf '%s\n' "${problems}" >&2
	exit 3
}

# Prints the size cap's problem of the context JSON $1, or nothing.
context_size_problem() {
	json_bytes=$(printf '%s\n' "$1" | wc -c) || die 5 'wc could not count the context bytes; check wc, then rerun'
	json_bytes=${json_bytes##* }
	[ "${json_bytes}" -le "${context_max_bytes}" ] ||
		printf 'the context JSON is %s bytes; expected at most %s bytes: references and short notes, long text in --text-file\n' "${json_bytes}" "${context_max_bytes}"
}

# Prints the problems the size cap and the validator find in the context JSON
# $1 when it sits at path $2; prints nothing when it fits.
context_json_problems() {
	# shellcheck disable=SC2310 # a failure has printed its cause; this passes its exit on
	context_size_problem "$1" || exit "$?"
	printf '%s\n' "$1" | jq -rs --arg context_path "$2" -f "${validator}" ||
		die 5 'jq failed on the context validator; expected jq 1.6+; try jq --version, then rerun'
}

# Sets created_path to a new empty file crucible.sh made with label $1, or exits 1.
create_item() {
	if [ -n "${session}" ]; then
		created_path=$(sh "${crucible_script}" new --kind context --label "$1" --session "${session}") ||
			write_failed "crucible.sh new --label $1 failed; its stderr is above"
	else
		created_path=$(sh "${crucible_script}" new --kind context --label "$1") ||
			write_failed "crucible.sh new --label $1 failed; its stderr is above"
	fi
	created_files="${created_files}${created_files:+, }${created_path}"
	case ${created_path} in
		/*) ;;
		*)
			shown_path=$(printable "${created_path}")
			write_failed "crucible.sh new printed a path that is not absolute: ${shown_path}"
			;;
	esac
	[ -f "${created_path}" ] && [ ! -L "${created_path}" ] ||
		write_failed "crucible.sh new printed ${created_path}, which is not a regular file"
}

# Exits 1 with $1 and the files created so far, which are left in place.
write_failed() {
	if [ -n "${created_files}" ]; then
		die 1 "$1; created and not completed: ${created_files}"
	fi
	die 1 "$1; no file was created"
}

# Sets temp_file to a new temp file beside path $1, or exits 1.
make_temp_beside() {
	temp_file=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") ||
		write_failed "mktemp could not create a temp file beside $1"
}

# Moves temp_file onto path $1, or exits 1.
commit_temp() {
	mv -f "${temp_file}" "$1" || write_failed "mv could not move the temp file onto $1"
	temp_file=''
}

# Writes {"text": <the --text-file content>} into a new crucible file; sets text_path.
write_text_file() {
	create_item "${label}${TEXT_LABEL_SUFFIX}"
	text_path=${created_path}
	make_temp_beside "${text_path}"
	jq -n --rawfile text "$1" '{text: $text}' </dev/null >"${temp_file}" ||
		write_failed "jq could not write the --text-file content into ${text_path}"
	commit_temp "${text_path}"
}

# Writes the context JSON into a new crucible file, checked before and after; sets context_path.
write_context_file() {
	create_item "${label}"
	context_path=${created_path}
	path_problem=$(context_path_problem "${context_path}")
	[ -z "${path_problem}" ] || write_failed "context file ${context_path}: ${path_problem}"
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	context_json=$(run_context_jq context "${text_path}" "$@") || write_failed 'jq failed building the context'
	# shellcheck disable=SC2310 # a failure has printed its cause; this passes its exit on
	final_problems=$(context_json_problems "${context_json}" "${context_path}") || exit "$?"
	[ -z "${final_problems}" ] || fail_validation "not written, it would fail the validator" "${final_problems}"
	make_temp_beside "${context_path}"
	printf '%s\n' "${context_json}" >"${temp_file}" || write_failed "could not write the temp file ${temp_file}"
	commit_temp "${context_path}"
	# shellcheck disable=SC2310 # a failure has printed its cause; this passes its exit on
	written_problems=$(written_file_problems "${context_path}") || exit "$?"
	[ -z "${written_problems}" ] || fail_validation "fails the validator as written" "${written_problems}"
}

# Exits 1 for the context file, with what $1 says and the problem lines $2 joined.
fail_validation() {
	joined_problems=$(join_lines "$2")
	write_failed "context file ${context_path} $1: ${joined_problems}"
}

# Prints the problems of the written context file $1, checked as prepare-agent-prompt.sh checks it.
written_file_problems() {
	[ ! -L "$1" ] && [ -f "$1" ] && [ -r "$1" ] || {
		printf 'file is missing, unreadable, a symlink or not a regular file\n'
		return 0
	}
	written_bytes=$(wc -c <"$1") || die 5 'wc could not count the context bytes; check wc, then rerun'
	written_bytes=${written_bytes##* }
	[ "${written_bytes}" -le "${context_max_bytes}" ] ||
		printf 'file is larger than %s bytes\n' "${context_max_bytes}"
	jq empty "$1" </dev/null >/dev/null 2>&1 || {
		printf 'file is not valid JSON\n'
		return 0
	}
	jq -rs --arg context_path "$1" -f "${validator}" "$1" </dev/null ||
		die 5 'jq failed on the context validator; expected jq 1.6+; try jq --version, then rerun'
}

# Prints the lines of $1 joined by "; ".
join_lines() {
	joined=''
	while IFS= read -r line; do
		joined="${joined}${joined:+; }${line}"
	done <<EOF
$1
EOF
	printf '%s' "${joined}"
}

# Prints the text file of the entries in "$@", or nothing.
text_file_of() {
	while [ "$#" -gt 0 ]; do
		[ "$1" != text ] || printf '%s' "$2"
		shift 3
	done
}

for tool in ${REQUIRED_TOOLS}; do
	command -v "${tool}" >/dev/null 2>&1 ||
		die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
done

temp_file=''
created_files=''
trap remove_temp_file EXIT
# A signal exits through the EXIT trap, so the temp file goes on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$#" -gt 0 ] || {
	usage >&2
	exit 2
}
label='' label_given='' session='' session_given='' validator_problems=''
awaited_option='' entry_kind='' entry_value='' entry_why=''
note_count=0 text_file_count=0
# Each completed entry is appended to the positional parameters as a triple
# (kind, value, why); "for" walks the original arguments only, which are
# shifted away after the loop.
argument_count=$#
for argument do
	if [ -z "${awaited_option}" ]; then
		take_option "${argument}"
		continue
	fi
	take_value "${awaited_option}" "${argument}"
	awaited_option=''
	[ "${is_entry_complete}" = true ] || continue
	set -- "$@" "${entry_kind}" "${entry_value}" "${entry_why}"
	entry_kind='' entry_value='' entry_why=''
done
finish_parse
shift "${argument_count}"

load_dependencies
collect_file_problems "$@"
plan_space_paths
report_input_problems "$@"

text_file=$(text_file_of "$@")
text_path=''
[ -z "${text_file}" ] || write_text_file "${text_file}"
write_context_file "$@"
# shellcheck disable=SC2310 # its status is the tool's; a failure exits
compute_context_digest "${context_path}" ||
	write_failed "${context_digest_tool} could not hash ${context_path}"
printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "${context_path}" "${context_digest}"
