#!/usr/bin/env sh
# Writes an effort's context versions and diff files, so the context JSON is
# never typed by hand. new writes v1; extend writes the next version as a
# complete copy of the latest one, minus the entries it retires, plus the new
# ones; diff writes a local commit or range as a file; latest prints the
# absolute path and sha256 of the effort's latest version and writes nothing.
# Every input is checked first and every problem reported before any file is
# created: the JSON is built with stand-in paths and checked by
# agent-context-validator.jq and agent-context-file-checks.sh, each problem
# named by the option behind it.
# The approved spec's entry and a spec skip note this call adds must each match
# a gate record in the effort's cache/gates, as the human answered at the gate.
# Only then is each file written atomically into the file crucible.sh new
# --effort hands out, and checked again as prepare-agent-prompt.sh checks it.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../engine/crucible/scripts/lib
set -eu
umask 077

readonly PROG='context.sh'
readonly PROCEDURE='procedure-context'
readonly CRUCIBLE_SKILL='crucible'
readonly EFFORT_SKILL='procedure-effort'
# The exit of a write refused because the effort is not open.
readonly NOT_OPEN_EXIT=6
readonly REQUIRED_TOOLS='cat mktemp mv rm tr wc'
readonly TEXT_LABEL_SUFFIX='-text'
readonly DIFF_LABEL_PREFIX='diff-'
# The --text-file content and a diff are read by the agent with Read, never
# injected; the cap keeps either to what an agent can read in a few calls.
readonly TEXT_MAX_BYTES=1048576
# Stands for the part of an item's name only crucible.sh new knows, so the
# JSON can be checked at its final length before any file exists.
readonly PLACEHOLDER_ID='00000000T000000-0000'
# Stands for the effort folder when --from names none, so the entries are
# still checked.
readonly PLACEHOLDER_EFFORT='00000000T000000-0000-effort'
readonly EMPTY_BASE='{}'
# The spec's entries and the gate records that prove them: the approval gate
# records the draft's path and sha256, the offer gate its case. A record
# expires with the cache, so only the entries a call adds are checked.
readonly GATE_RECORD_KIND='cache/gates'
readonly SPEC_APPROVAL_LABEL='spec-approval'
readonly SPEC_OFFER_LABEL='spec-offer'
readonly APPROVED_SPEC_WHY='the approved spec'
readonly SPEC_APPROVED_PREFIX='Spec approved:'
readonly SPEC_SKIPPED_PREFIX='Spec skipped:'
# Leads a missing gate's problem, so a caller matches the token, never the
# sentence after it.
readonly NO_SPEC_GATE_TOKEN='NO-SPEC-GATE'
# A problem line shows a value whole up to 80 characters, enough to tell one
# path or URL from another by eye; a longer one keeps its first 40 and last 39
# around a "…", as a path or URL differs most at its start and end.
readonly SHOWN_MAX_CHARS=80
readonly SHOWN_HEAD_CHARS=$((SHOWN_MAX_CHARS / 2))
readonly SHOWN_TAIL_CHARS=$((SHOWN_MAX_CHARS - SHOWN_HEAD_CHARS - 1))
# Shows a value as a JSON string on one line, cut as above; every jq program
# here that names a value starts with it.
readonly SHOWN_JQ="def shown: tojson | gsub(\"[[:cntrl:]]\"; \"?\") | if length > ${SHOWN_MAX_CHARS} then .[:${SHOWN_HEAD_CHARS}] + \"…\" + .[-${SHOWN_TAIL_CHARS}:] else . end;"
TAB=$(printf '\t')
readonly TAB
NL='
'
readonly NL
# The C locale keeps the shell's pattern checks byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

# Builds the context JSON from the base ($base: the version extended, its
# retired entries left out, or an empty context for new) and the entries
# (mode "context"), or names each problem found in it by its option (mode
# "report": one stderr line each). The entries arrive as positional triples:
# kind (path, link, note, text or retire), value, why ("" for a note or a
# retire). The problems are the validator's, as JSON lines, and the file
# checks', as "<entry index>\t<problem>" lines. The context goes through
# crucible's prune, so a list with no entry is left out; run_context_jq
# puts the include before SHOWN_JQ, as jq takes an include only first.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly CONTEXT_JQ='
def entries: $ARGS.positional | [range(0; length / 3) as $n
	| {index: $n, kind: .[$n * 3], value: .[$n * 3 + 1], why: .[$n * 3 + 2]}];
def base_entries($list; $field): ($base[$list] // []) | map({index: -1, kind: "base", value: (if $field == "" then . else .[$field] end), why: (.why? // "")});
# The entries in the order of the context lists they fill: the base first.
def listed($entries): {
	paths: (base_entries("paths"; "path") + [$entries[] | select(.kind == "path")] + [$entries[] | select(.kind == "text")]),
	links: (base_entries("links"; "url") + [$entries[] | select(.kind == "link")]),
	notes: (base_entries("notes"; "") + [$entries[] | select(.kind == "note")])};
def context: listed(entries) as $listed | {
	claude_session_id: $session_id,
	paths: ($listed.paths | map({path: (if .kind == "text" then $text_path else .value end), why})),
	links: ($listed.links | map({url: .value, why})),
	notes: ($listed.notes | map(.value))}
	| prune;

def option: {path: "--path", link: "--link", note: "--note", text: "--text-file"}[.];
# Problems of the Crucible space sort after those of the entries.
def space_order: 1e9;
def problem_line($order; $option; $value; $problem): {order: $order, text: "\($prog): \($option) \($value | shown): \($problem)"};
def space_line($problem): problem_line(space_order; "CRUCIBLE_HOME"; $space_root; $problem + $space_source);
def file_problems: [$file_problem_lines | split("\n")[] | select(. != "") | split("\t") | {index: (.[0] | tonumber), problem: .[1]}];
def validator_problems: [$validator_problem_lines | split("\n")[] | select(. != "") | fromjson];
# Names validator problem . by the option behind its field. A path field the
# file checks already refused is left out; the path of the text entry belongs
# to the Crucible space; a base entry was checked when its version was written.
def validator_line($listed; $refused):
	.at as $at | .problem as $problem
	| (if ($at | type) == "array" and ($at | length) >= 2 then $listed[$at[0]][$at[1]] else null end) as $entry
	| if $entry == null or $entry.kind == "base" then {order: -1, text: "\($prog): context file: \($at | tojson) \($problem)"}
	  elif $at[2] == "why" then problem_line($entry.index; "--why"; $entry.why; $problem)
	  elif $entry.kind == "text" then space_line($problem)
	  elif $at[0] == "paths" and ($refused | index([$entry.index])) != null then empty
	  else problem_line($entry.index; $entry.kind | option; $entry.value; $problem) end;
def report: entries as $entries | file_problems as $files
	| [($files[] | .problem as $problem | $entries[.index] | problem_line(.index; .kind | option; .value; $problem)),
	   (validator_problems[] | validator_line(listed($entries); $files | map(.index))),
	   (if $space_problem == "" then empty else space_line($space_problem) end)]
	| reduce .[] as $line ([]; if any(.[]; .text == $line.text) then . else . + [$line] end)
	| sort_by(.order)[].text;

if $mode == "report" then report else context end
'

# Applies the --retire values ($ARGS.positional, in order) to the version
# read on stdin: prints the version without the retired entries as one JSON
# line, then one problem line per --retire that names no entry of it or names
# one twice, its value shown as SHOWN_JQ shows a value.
# shellcheck disable=SC2016
readonly RETIRE_JQ='
def target: (capture("^(?<list>paths|links|notes):(?<n>[1-9][0-9]{0,8})$") | .n |= tonumber) // null;
. as $version
| [$ARGS.positional | to_entries[] | {order: .key, value: .value, target: (.value | target)}] as $retires
| def gone($list): [$retires[].target | select(. != null and .list == $list) | .n - 1];
{problems: [$retires[] | . as $retire
	| (($version[.target.list // "notes"] // []) | length) as $count
	| if .target == null then {value, problem: "not <list>:<n>; expected paths:<n>, links:<n> or notes:<n>, n a position from 1 without a leading zero"}
	  elif $count < .target.n then {value, problem: "the version has \($count) \(.target.list) entr\(if $count == 1 then "y" else "ies" end); expected \(if $count == 0 then "no --retire of \(.target.list)" else "\(.target.list):1 to \(.target.list):\($count)" end)"}
	  elif any($retires[]; .order < $retire.order and .target == $retire.target) then {value, problem: "names the same entry as an earlier --retire; expected each entry retired once"}
	  else empty end],
 base: (reduce ("paths", "links", "notes") as $list ($version;
	gone($list) as $gone
	| if (.[$list] | type) == "array" then .[$list] |= [to_entries[] | select(.key as $key | $gone | any(. == $key) | not) | .value] else . end))}
| (.base | tojson), (.problems[] | "\($prog): --retire \(.value | shown): \(.problem)")
'

# The --help page: the caller's whole contract.
usage() {
	context_cap='the size cap of agent-context-file-checks.sh'
	sensitive_names='the list in agent-context-file-checks.sh'
	# shellcheck disable=SC2310 # its status says whether the lib was found; errexit adds nothing
	if load_context_lib; then
		[ -z "${context_max_bytes:-}" ] || context_cap="${context_max_bytes} bytes"
		[ -z "${context_sensitive_names_text:-}" ] || sensitive_names=${context_sensitive_names_text}
	fi
	# Mirrors context_path_problem in agent-context-file-checks.sh; procedure-context step 1 picks paths by this list.
	print_page <<EOF
usage: sh ${PROG} new --effort FOLDER [ENTRY]... --note TEXT [--note TEXT]...
       sh ${PROG} extend --from VERSION [ENTRY]... [--retire LIST:N]...
       sh ${PROG} diff --effort FOLDER --repo ROOT --ref REF
       sh ${PROG} latest --effort FOLDER
       sh ${PROG} --help | -h
  ENTRY: --path ABS --why LINE | --link URL --why LINE
         | --text-file FILE --why LINE | --note TEXT

Writes only into the effort's context/ (a SIGKILL aside).

Commands:
  new     writes v1, the effort's first version
  extend  writes v<N+1>: VERSION's entries minus the retired ones, then the
      new ones in order (the --text-file entry last in paths)
  diff    writes a commit or range of ROOT as a file for a --path; a rerun on
      the same diff prints the same file
  latest  prints the latest version's absolute path and sha256

Options (no value but a note may hold a control character):
  --effort FOLDER   the effort folder, as effort.sh start printed it
  --from VERSION    the effort's latest version, a CONTEXT_FILE path
  --retire LIST:N   drops entry N (from 1) of VERSION's paths, links or notes;
      needs a new --note saying why
  --path ABS        an existing readable file or folder, absolute, not a
      symlink, with no control character, quote or .. segment; in any letter
      case not a sensitive name (below), a .git or .ssh component,
      .docker/config.json, CLAUDE.md, SKILL.md, settings.local.json, or
      \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}'s settings.json, skills/ or agents/
      or anything under them
  --link URL        an http(s) URL; rules: agent-context-url.jq
  --text-file FILE  the human's long text: a file --path takes, UTF-8, at most
      ${TEXT_MAX_BYTES} bytes, one per call
  --why LINE        one line: why the agent needs the entry just before it;
      '${APPROVED_SPEC_WHY}' needs the effort's ${SPEC_APPROVAL_LABEL} gate record of
      that --path at its current sha256
  --note TEXT       any text; new needs one. '${SPEC_SKIPPED_PREFIX}' at its start needs a
      ${SPEC_OFFER_LABEL} gate record of case offer in the effort; '${SPEC_APPROVED_PREFIX}' needs
      the approved spec's --path entry in the same call
  --repo ROOT       the git work-tree root, absolute
  --ref REF         a commit or a range A..B of 0-9 A-Z a-z . _ / ^ ~ - only,
      no part starting with -; its diff non-empty, UTF-8, at most ${TEXT_MAX_BYTES} bytes
Sensitive names, basename globs:
  ${sensitive_names}

A version is at most ${context_cap}; shape: agent-context-validator.jq
(claude_session_id first).

stdout on exit 0 (none otherwise):
  new, extend, latest: CONTEXT_FILE: <absolute path>, then
  CONTEXT_SHA256: <its sha256>; diff: DIFF_FILE: <absolute path>
stderr on exit 3: one line per problem, either
  "${PROG}: <option> <value>: <problem>; expected <x>" or, for the version
  as a whole, "${PROG}: context file: <problem>"

Each file is written whole or not at all; a version never changes; a diff
leaves out what --path refuses; ROOT is only read. One run at a time per
effort.

Environment:
  CRUCIBLE_HOME     the space (default \$HOME/.crucible)
  CLAUDE_CODE_SESSION_ID  required but for latest; a lowercase UUID

Exit codes (1 on a failed write, 2, 4-6, a signal: show the human stderr; stop):
  0  done; read stdout
  1  latest: no version yet; run new. Else a write failed
  2  usage error, or CLAUDE_CODE_SESSION_ID bad or naming no session transcript
  3  invalid input, nothing written; fix what stderr names, rerun
     "--effort <folder>: its context already holds"  new: extend that version
     "--from <file>: is version ... not the latest"  extend the one named
     "${NO_SPEC_GATE_TOKEN}"  the spec's gate holds no record for the entry; open that gate
  4  the space is unusable
  5  install fault
  ${NOT_OPEN_EXIT}  the effort is not open or its state unknown; nothing written
  129, 130, 143  stopped by HUP, INT or TERM

Dependencies:
  POSIX sh; jq 1.6+ (macOS: brew install jq; Linux: the distro's jq); cat,
    mktemp, mv, rm, tr, wc; sha256sum or shasum (macOS: built in)
  the ${CRUCIBLE_SKILL} skill: crucible.sh (not for latest),
    scripts/lib/crucible-space.sh; new, extend: scripts/lib/prune.jq
  ${EFFORT_SKILL}: effort.sh (not for latest)
  diff: git (macOS: xcode-select --install; Linux: the distro's)
  beside this script: agent-context-file-checks.sh, agent-context-validator.jq,
    agent-context-url.jq, context-versions.sh
EOF
}

# Prints stdin with builtins only, so the page prints with cat missing.
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

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
# A usage error can reach it before the tool check, so it checks the tools first.
printable() {
	require_tools
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Removes the temp files; on a failing exit, a signal included, also the
# files this run made, so no partial context file is left behind.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	exit_status=$?
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ -z "${diff_temp}" ] || rm -f "${diff_temp}"
	[ "${exit_status}" -eq 0 ] || remove_created_files
}

# Removes and names the files this run made.
remove_created_files() {
	[ -n "${created_files}" ] || return 0
	while IFS= read -r created_file; do
		rm -f "${created_file}" && warn "removed ${created_file}, made by this run"
	done <<EOF
${created_files}
EOF
	created_files=''
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
		*)
			[ -z "${entry_kind}" ] || missing_why_error
			# shellcheck disable=SC2310 # a pure test; its status is the answer
			is_command_option "$1" || {
				shown_option=$(printable "$1")
				expected_options=$(command_options)
				usage_error "unknown option for ${command}: ${shown_option}; expected ${expected_options}"
			}
			;;
	esac
	awaited_option=$1
}

# Succeeds when option $1 is taken by the command (--why and --help aside).
is_command_option() {
	case ${command}:$1 in
		new:--effort | extend:--from | extend:--retire | diff:--effort | diff:--repo | diff:--ref | latest:--effort) return 0 ;;
		new:--path | new:--link | new:--text-file | new:--note) return 0 ;;
		extend:--path | extend:--link | extend:--text-file | extend:--note) return 0 ;;
		*) return 1 ;;
	esac
}

command_options() {
	case ${command} in
		new) printf '%s' '--effort, --path, --link, --text-file, --why, --note or --help' ;;
		extend) printf '%s' '--from, --path, --link, --text-file, --why, --note, --retire or --help' ;;
		latest) printf '%s' '--effort or --help' ;;
		*) printf '%s' '--effort, --repo, --ref or --help' ;;
	esac
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
# completes an entry (a --why, a --note or a --retire), with entry_kind,
# entry_value and entry_why holding it.
take_value() {
	is_entry_complete=false
	case $1 in
		--effort | --from | --repo | --ref)
			mark_seen "$1"
			[ -n "$2" ] || usage_error "$1 is empty; expected $1 VALUE"
			case $1 in
				--effort) effort_dir=$(without_trailing_slashes "$2") ;;
				--from) version_path=$2 ;;
				--repo) repo_root=$(without_trailing_slashes "$2") ;;
				*) ref=$2 ;;
			esac
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
		--retire)
			[ "${retire_count}" -gt 0 ] || first_retire=$2
			retire_count=$((retire_count + 1))
			finish_entry retire "$2" ''
			;;
		*) finish_entry "${entry_kind}" "${entry_value}" "$2" ;;
	esac
}

# Records option $1 in seen_options, or exits 2 when it is there already.
mark_seen() {
	case " ${seen_options} " in
		*" $1 "*) usage_error "$1 given twice; expected at most one $1" ;;
		*) seen_options="${seen_options} $1" ;;
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

# Exits 2 on an option left without its value or its --why, or a required
# option missing.
finish_parse() {
	[ -z "${awaited_option}" ] || usage_error "${awaited_option} needs a value; expected ${awaited_option} VALUE"
	[ -z "${entry_kind}" ] || missing_why_error
	case ${command} in
		new)
			require_option --effort FOLDER
			[ "${note_count}" -gt 0 ] || usage_error '--note missing; expected at least one --note TEXT: the human'\''s request or a note'
			;;
		extend) require_option --from VERSION ;;
		latest) require_option --effort FOLDER ;;
		*)
			require_option --effort FOLDER
			require_option --repo ROOT
			require_option --ref REF
			;;
	esac
}

# Exits 2 unless option $1 (value name $2) was given.
require_option() {
	case " ${seen_options} " in
		*" $1 "*) ;;
		*) usage_error "$1 missing; expected $1 $2" ;;
	esac
}

# Exits 5 naming the first of REQUIRED_TOOLS missing from PATH; checks once.
require_tools() {
	[ -z "${tools_checked}" ] || return 0
	for tool in ${REQUIRED_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 ||
			die 5 "${tool} missing; expected it on PATH; install your base system's ${tool}"
	done
	tools_checked=true
}

# new, extend and diff: sets session_id from CLAUDE_CODE_SESSION_ID by the space
# rules, or exits 2 before any file is made.
require_session() {
	# shellcheck disable=SC2310 # its status says whether the session is usable; the problem is read here
	crucible_check_session || usage_error "${crucible_session_problem}"
	session_id=${crucible_session_id}
}

# Exits 5 unless jq, a sha256 tool, crucible.sh, agent-context-file-checks.sh
# beside this script, the read checks' files and, for new and extend,
# crucible's prune module are in place; sources the checks and sets
# crucible_script, validator and prune_lib_dir.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 5 'jq missing; expected jq 1.6+ on PATH; install it (macOS: brew install jq; Linux: the distro'\''s jq package)'
	# shellcheck disable=SC2310 # its status says whether the lib was found; errexit adds nothing
	load_context_lib ||
		die 5 "context path check missing; expected ${context_lib}; reinstall the ${PROCEDURE} skill"
	case ${context_max_bytes:-} in
		'' | *[!0-9]*) die 5 "context size cap unset or not a number in ${context_lib}; expected context_max_bytes as digits; reinstall the ${PROCEDURE} skill" ;;
		*) ;;
	esac
	[ -n "${context_sensitive_names:-}" ] ||
		die 5 "sensitive names unset in ${context_lib}; expected context_sensitive_names; reinstall the ${PROCEDURE} skill"
	own_scripts_dir=$(script_dir)
	# shellcheck disable=SC2310 # its status says whether the checks loaded; the problem is read here
	context_load_checks "${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills" "${own_scripts_dir}" || die 5 "${context_load_problem}"
	validator=${context_validator}
	if [ "${command}" != latest ]; then
		crucible_script="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/crucible.sh"
		[ -f "${crucible_script}" ] && [ -r "${crucible_script}" ] ||
			die 5 "crucible.sh missing; expected ${crucible_script}; install the ${CRUCIBLE_SKILL} skill"
		effort_script="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${EFFORT_SKILL}/scripts/effort.sh"
		[ -f "${effort_script}" ] && [ -r "${effort_script}" ] ||
			die 5 "effort.sh missing; expected ${effort_script}; install the ${EFFORT_SKILL} skill"
	fi
	case ${command} in
		new | extend)
			prune_lib_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/skills/${CRUCIBLE_SKILL}/scripts/lib"
			[ -f "${prune_lib_dir}/prune.jq" ] && [ -r "${prune_lib_dir}/prune.jq" ] ||
				die 5 "prune module missing; expected ${prune_lib_dir}/prune.jq; install the ${CRUCIBLE_SKILL} skill"
			;;
		*) ;;
	esac
	if [ "${command}" = diff ]; then
		command -v git >/dev/null 2>&1 ||
			die 5 "git missing; expected it on PATH; install it (macOS: xcode-select --install; Linux: the distro's git package)"
	fi
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

# Sets space_root by the space rules, and space_source, which a space problem
# line ends with: when the space comes from HOME, HOME is the part to fix, not
# CRUCIBLE_HOME. A space the rules refuse exits 4 with its CRUCIBLE_HOME line.
resolve_space_root() {
	space_source=''
	[ -n "${CRUCIBLE_HOME:-}" ] ||
		space_source="; CRUCIBLE_HOME is unset or empty, so this is \$HOME/.crucible: fix HOME, or set CRUCIBLE_HOME to a folder that passes"
	# shellcheck disable=SC2310 # its status says whether the root is usable; the problem is read below
	if ! crucible_resolve_root; then
		add_problem CRUCIBLE_HOME "${CRUCIBLE_HOME:-${HOME:-}/.crucible}" "${crucible_root_problem}${space_source}"
		exit_on_problems "${rule_problems}"
	fi
	space_root=${crucible_root}
}

# Appends a problem line for option $1, value $2 and problem $3 to rule_problems.
add_problem() {
	# shellcheck disable=SC2016 # the $ names after SHOWN_JQ are jq's
	problem_line=$(jq -nr --arg prog "${PROG}" --arg option "$1" --arg value "$2" --arg problem "$3" \
		"${SHOWN_JQ}"'"\($prog): \($option) \($value | shown): \($problem)"' </dev/null) ||
		die 5 'jq failed formatting a problem; expected jq 1.6+; try jq --version, then rerun'
	rule_problems="${rule_problems}${problem_line}${NL}"
}

# Prints the problem of effort folder $1 (no trailing slash), or nothing:
# the space rules' effort folder check, then a context/ that is a symlink.
effort_folder_problem() {
	# shellcheck disable=SC2310 # its status says whether the folder passed; the problem is printed
	if ! crucible_check_effort_folder "$1"; then
		printf '%s' "${crucible_effort_problem}"
		return 0
	fi
	[ ! -L "$1/context" ] || printf 'its context/ is a symlink; expected a real folder'
}

# Adds a problem when --effort is no effort folder, and then sets effort_dir
# to a stand-in in the space, so the entries are still checked.
check_effort_option() {
	found_problem=$(effort_folder_problem "${effort_dir}")
	[ -n "${found_problem}" ] || return 0
	add_problem --effort "${effort_dir}" "${found_problem}"
	effort_dir="${space_root}/efforts/${PLACEHOLDER_EFFORT}"
	return 1
}

# new: adds a problem when --effort is no effort folder, or its context/
# already holds a version.
check_new_effort() {
	# shellcheck disable=SC2310 # its status says whether to go on; it reports its own problem
	check_effort_option || return 0
	context_find_latest_version "${effort_dir}/context"
	[ -n "${context_version_latest}" ] || return 0
	add_problem --effort "${effort_dir}" "its context already holds v${context_version_latest_number} (${context_version_latest}); expected an effort with no context version; extend --from it instead"
}


# extend: checks VERSION; when it is the effort's latest valid version, sets
# effort_dir, next_number and base_json (VERSION's entries without the
# retired ones) and adds the --retire problems; else adds VERSION's problem
# and keeps the stand-ins. The entry triples are in "$@".
check_from_version() {
	base_json=${EMPTY_BASE}
	next_number=1
	effort_dir="${space_root}/efforts/${PLACEHOLDER_EFFORT}"
	found_problem=$(version_file_problem "${version_path}")
	if [ -n "${found_problem}" ]; then
		add_problem --from "${version_path}" "${found_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # version_file_problem passed, so the name is a version's
	context_version_of_name "${version_path##*/}" || true
	next_number=$((context_version_number + 1))
	effort_dir=${version_path%/*}
	effort_dir=${effort_dir%/*}
	retire_entries "$@"
}

# Prints the problem of version file $1 (--from, or the latest for latest)
# by the read checks, or nothing. The write rules are left out, so a version
# written before a write rule tightened stays readable: a new rule goes into
# the write rules, never into the validator, and holds for new entries only.
version_file_problem() {
	case $1 in
		*[[:cntrl:]]* | *\'* | *'"'*)
			printf 'path holds a control character or a quote; expected a version file context.sh wrote'
			return 0
			;;
		*) ;;
	esac
	version_dir=${1%/*}
	# shellcheck disable=SC2310 # its status says whether the name is a version's
	if ! context_version_of_name "${1##*/}" || [ "${version_dir##*/}" != context ]; then
		printf 'not <effort folder>/context/<YYYYMMDDTHHMMSS>-<hex>-v<N>.json; expected a version file context.sh wrote'
		return 0
	fi
	folder_problem=$(effort_folder_problem "${version_dir%/*}")
	if [ -n "${folder_problem}" ]; then
		printf 'its effort folder: %s' "${folder_problem}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "$1" ||
		die 5 'a tool failed reading the version (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	printf '%s' "${context_read_text}"
}

# Sets base_json to VERSION without the retired entries, and adds RETIRE_JQ's
# problem lines. The entry triples are in "$@"; their --retire values are
# passed to RETIRE_JQ in order.
retire_entries() {
	argument_count=$#
	position=0
	# "for" walks the triples given; the --retire values are appended after them.
	for argument do
		case $((position % 3)) in
			0) argument_kind=${argument} ;;
			1) [ "${argument_kind}" != retire ] || set -- "$@" "${argument}" ;;
			*) ;;
		esac
		position=$((position + 1))
	done
	shift "${argument_count}"
	retire_output=$(jq -r --arg prog "${PROG}" "${SHOWN_JQ}${RETIRE_JQ}" --args -- "$@" <"${version_path}") ||
		die 5 "jq failed applying the --retire values; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	{
		IFS= read -r base_json
		retire_problems=$(cat)
	} <<EOF
${retire_output}
EOF
	[ -z "${retire_problems}" ] || rule_problems="${rule_problems}${retire_problems}${NL}"
}

# extend: adds a problem for a --retire without a new --note, and for a call
# with nothing to add or retire; the entry triples are in "$@".
check_extend_rules() {
	if [ "${retire_count}" -gt 0 ] && [ "${note_count}" -eq 0 ]; then
		add_problem --retire "${first_retire}" 'no new --note; expected at least one --note saying why the entry is retired'
	fi
	[ "$#" -eq 0 ] || return 0
	add_problem --from "${version_path}" 'nothing to add or retire; expected at least one --path, --link, --text-file, --note or --retire'
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
	# shellcheck disable=SC2310 # it prints the problem; its status only says whether there was one
	long_text_problem "$1" 'the human'\''s text' || true
}

# Prints the problem of long-text file $1, the agent's $2, against the cap and
# UTF-8, and succeeds; fails, printing nothing, when it fits.
long_text_problem() {
	text_bytes=$(wc -c <"$1") ||
		die 5 "wc could not count the bytes of $1; expected a byte count; try wc -c on it, then rerun"
	text_bytes=${text_bytes##* }
	if [ "${text_bytes}" -gt "${TEXT_MAX_BYTES}" ]; then
		printf '%s is %s bytes; expected at most %s bytes' "$2" "${text_bytes}" "${TEXT_MAX_BYTES}"
		return 0
	fi
	# shellcheck disable=SC2310 # its status is the check result; errexit adds nothing
	text_is_utf8 "$1" && return 1
	printf '%s is not valid UTF-8; expected %s as UTF-8' "$2" "$2"
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
	jq -nr -L "${prune_lib_dir}" --arg prog "${PROG}" --arg mode "${run_mode}" --arg text_path "${run_text_path}" \
		--argjson base "${base_json}" \
		--arg file_problem_lines "${file_problems}" --arg validator_problem_lines "${validator_problems}" \
		--arg space_root "${space_root}" --arg space_problem "${space_problem}" --arg space_source "${space_source}" \
		--arg session_id "${session_id}" \
		"include \"prune\";${SHOWN_JQ}${CONTEXT_JQ}" --args -- "$@" </dev/null
}

# Sets version_label, the placeholder paths of the files to write, and
# space_problem, the version placeholder's problem as
# agent-context-file-checks.sh finds it.
plan_space_paths() {
	version_label="v${next_number}"
	placeholder_context="${effort_dir}/context/${PLACEHOLDER_ID}-${version_label}.json"
	placeholder_text="${effort_dir}/context/${PLACEHOLDER_ID}-${version_label}${TEXT_LABEL_SUFFIX}.json"
	space_problem=$(context_path_problem "${placeholder_context}")
	[ -z "${space_problem}" ] || space_problem="${space_problem}; expected ${context_path_expected}"
}

# Exits 3, or 4 when one is the Crucible space's, after printing the rule
# problems and every problem the file checks, the validator and the size cap
# find in the context the base and the entries in "$@" make, built with the
# placeholder paths before any file exists.
report_input_problems() {
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	planned_json=$(run_context_jq context "${placeholder_text}" "$@") ||
		die 5 "jq failed building the context; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	validator_problems=$(printf '%s\n' "${planned_json}" |
		jq -cs --arg format json -f "${validator}") ||
		die 5 'jq failed on the context validator; expected jq 1.6+; try jq --version, then rerun'
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	problems=$(run_context_jq report '' "$@") ||
		die 5 "jq failed reporting the inputs' problems; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	# shellcheck disable=SC2310 # a failure has printed its cause; this passes its exit on
	size_problem=$(context_size_problem "${planned_json}") || exit "$?"
	[ -z "${size_problem}" ] || problems="${problems}${problems:+${NL}}${PROG}: context file: ${size_problem}"
	exit_on_problems "${rule_problems}${problems}"
}

# Prints the problem lines $1, if any, and exits 4 when one is the Crucible
# space's (no change to the inputs fixes it), else 3.
exit_on_problems() {
	[ -n "$1" ] || return 0
	printf '%s\n' "${1%"${NL}"}" >&2
	case ${NL}$1 in
		*"${NL}${PROG}: CRUCIBLE_HOME "*) exit 4 ;;
		*) exit 3 ;;
	esac
}

# Prints the size cap's problem of the context JSON $1, or nothing.
context_size_problem() {
	json_bytes=$(printf '%s\n' "$1" | wc -c) ||
		die 5 'wc could not count the context bytes; expected a byte count; try wc -c on a small file, then rerun'
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

# Exits NOT_OPEN_EXIT unless effort_dir is open, as effort.sh state, the one
# owner of the state rule, reads it; a state it cannot read refuses too.
require_open_effort() {
	if effort_state_out=$(sh "${effort_script}" state --effort "${effort_dir}" </dev/null); then
		effort_state_status=0
	else
		effort_state_status=$?
	fi
	effort_name=${effort_dir##*/}
	# shellcheck disable=SC2310 # the folder passed the space rules, so its name splits
	crucible_split_id "${effort_name}" && effort_name=${crucible_name_rest}
	case ${effort_state_status} in
		0) ;;
		5) die 5 "effort.sh state names a missing dependency above; expected the ${EFFORT_SKILL} skill working; install what it names, then rerun" ;;
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

# Sets created_path to a new empty file crucible.sh made in the effort's
# context/ with label $1, or fails the run.
create_item() {
	created_path=$(sh "${crucible_script}" new --kind context --label "$1" --effort "${effort_dir}" </dev/null) ||
		fail_run "crucible.sh new --label $1 failed; its stderr is above; expected a new empty file in ${effort_dir}/context/; try the fix crucible.sh names, then rerun"
	shown_path=$(printable "${created_path}")
	case ${created_path} in
		"${effort_dir}/context/"*) ;;
		*) fail_run "crucible.sh new printed ${shown_path}, which is not in ${effort_dir}/context/; expected a new file there; try reinstalling the crucible skill, then rerun" ;;
	esac
	created_files="${created_files}${created_files:+${NL}}${created_path}"
	[ -f "${created_path}" ] && [ ! -L "${created_path}" ] ||
		fail_run "crucible.sh new printed ${shown_path}, which is not a regular file; expected a new empty regular file; try reinstalling the crucible skill, then rerun"
}

# Removes the files this run made, names them, and exits 1 with $1.
fail_run() {
	remove_created_files
	die 1 "$1"
}

# Sets temp_file to a new temp file beside path $1, or fails the run.
make_temp_beside() {
	temp_file=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") ||
		fail_run "mktemp could not create a temp file beside $1; expected a writable ${1%/*}; try checking its permissions and free space, then rerun"
}

# Moves temp_file onto path $1, or fails the run.
commit_temp() {
	mv -f "${temp_file}" "$1" ||
		fail_run "mv could not move the temp file onto $1; expected the file in place; try checking the permissions and free space of ${1%/*}, then rerun"
	temp_file=''
}

# Writes {"text": <the content of file $2>} into a new crucible file labelled
# $1; sets written_path.
write_text_item() {
	create_item "$1"
	written_path=${created_path}
	make_temp_beside "${written_path}"
	jq -n --rawfile text "$2" '{text: $text}' </dev/null >"${temp_file}" ||
		fail_run "jq could not write the content of $2 into ${written_path}; expected {\"text\": <the content>} written; try checking free space and jq --version, then rerun"
	commit_temp "${written_path}"
}

# Writes the context JSON into a new crucible file, checked before and after; sets context_path.
write_context_file() {
	create_item "${version_label}"
	context_path=${created_path}
	path_problem=$(context_path_problem "${context_path}")
	[ -z "${path_problem}" ] ||
		fail_run "context file ${context_path}: ${path_problem}; expected ${context_path_expected}; try setting CRUCIBLE_HOME to a folder that passes, then rerun"
	# shellcheck disable=SC2310 # its status is jq's; a failure exits
	context_json=$(run_context_jq context "${text_path}" "$@") ||
		fail_run "jq failed building the context; expected jq 1.6+ (--args, \$ARGS); try jq --version, then rerun"
	# shellcheck disable=SC2310 # a failure has printed its cause; this passes its exit on
	final_problems=$(context_json_problems "${context_json}" "${context_path}") || exit "$?"
	[ -z "${final_problems}" ] || fail_validation "not written, it would fail the validator" "${final_problems}"
	make_temp_beside "${context_path}"
	printf '%s\n' "${context_json}" >"${temp_file}" ||
		fail_run "could not write the temp file ${temp_file}; expected the context JSON written; try checking free space, then rerun"
	commit_temp "${context_path}"
	# shellcheck disable=SC2310 # a failure has printed its cause; this passes its exit on
	written_problems=$(written_file_problems "${context_path}") || exit "$?"
	[ -z "${written_problems}" ] || fail_validation "fails the validator as written" "${written_problems}"
}

# Fails the run for the context file, with what $1 says and the problem lines $2 joined.
fail_validation() {
	joined_problems=$(join_lines "$2")
	fail_run "context file ${context_path} $1: ${joined_problems}; expected a context that passes the checks it passed before writing; try rerunning, and on a second failure reinstall the ${PROCEDURE} skill"
}

# Prints the problem of the context file $1 just written, checked by the read
# checks every reader applies (context_read_problem), the size cap included.
written_file_problems() {
	# shellcheck disable=SC2310 # its status is a tool's; a failure has printed its cause
	context_read_problem "$1" ||
		die 5 'a tool failed reading the written version (its stderr is above); expected jq 1.6+ and wc; try jq --version, then rerun'
	printf '%s' "${context_read_text}"
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

# Checks every input of new or extend, then writes the text file (when one
# is given) and the version, and prints its path and sha256. The entry
# triples are in "$@".
write_version() {
	collect_file_problems "$@"
	check_spec_entries "$@"
	plan_space_paths
	report_input_problems "$@"
	require_open_effort
	text_file=$(text_file_of "$@")
	text_path=''
	if [ -n "${text_file}" ]; then
		write_text_item "${version_label}${TEXT_LABEL_SUFFIX}" "${text_file}"
		text_path=${written_path}
	fi
	write_context_file "$@"
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${context_path}" ||
		fail_run "${context_digest_tool} could not hash ${context_path}; expected its sha256; try ${context_digest_tool} on it, then rerun"
	printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "${context_path}" "${context_digest}"
}

# Adds a problem for each spec entry the call adds, the entry triples in "$@",
# that no gate record of the effort proves: the approved spec's --path, a
# skip note, and an approval note with no approved spec beside it. A stand-in
# effort has its own problem already, so its records are not looked up.
check_spec_entries() {
	has_approved_spec=false has_approval_note=false has_skip_note=false
	is_real_effort=true
	[ "${effort_dir##*/}" != "${PLACEHOLDER_EFFORT}" ] || is_real_effort=false
	while [ "$#" -gt 0 ]; do
		case $1:$3 in
			"path:${APPROVED_SPEC_WHY}")
				has_approved_spec=true
				[ "${is_real_effort}" = false ] || check_approved_spec "$2"
				;;
			note:*)
				case $2 in
					"${SPEC_APPROVED_PREFIX}"*) has_approval_note=true ;;
					"${SPEC_SKIPPED_PREFIX}"*) has_skip_note=true ;;
					*) ;;
				esac
				;;
			*) ;;
		esac
		shift 3
	done
	if [ "${has_approval_note}" = true ] && [ "${has_approved_spec}" = false ]; then
		rule_problems="${rule_problems}${PROG}: --note: an approval note needs the approved spec's --path entry in the same call${NL}"
	fi
	[ "${has_skip_note}" = true ] && [ "${is_real_effort}" = true ] || return 0
	# shellcheck disable=SC2310 # its status says whether a record matched
	find_gate_record "${SPEC_OFFER_LABEL}" '.case == "offer"' && return 0
	rule_problems="${rule_problems}${PROG}: --note: ${NO_SPEC_GATE_TOKEN}: no spec offer gate record in this effort; expected the skip chosen at the spec offer gate${NL}"
}

# Adds a problem unless a spec approval record of the effort names draft $1
# at its current sha256.
check_approved_spec() {
	spec_digest=''
	if [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ]; then
		# shellcheck disable=SC2310 # its status is the tool's; a failure exits
		compute_context_digest "$1" ||
			die 5 "${context_digest_tool} could not hash $1; expected its sha256; try ${context_digest_tool} on it, then rerun"
		spec_digest=${context_digest}
	fi
	# shellcheck disable=SC2016,SC2310 # $spec and $sha256 are jq's; its status says whether a record matched
	if [ -n "${spec_digest}" ] &&
		find_gate_record "${SPEC_APPROVAL_LABEL}" '.case == "approval" and .spec == $spec and .sha256 == $sha256' "$1" "${spec_digest}"; then
		return 0
	fi
	shown_spec=$(printable "$1")
	rule_problems="${rule_problems}${PROG}: --path ${shown_spec}: ${NO_SPEC_GATE_TOKEN}: no approval gate record for this draft as it is now; expected the spec approved at its gate (procedure-context references/spec.md)${NL}"
}

# Succeeds when a gate record of the effort labelled $1 passes jq test $2,
# with $spec and $sha256 bound to $3 and $4; crucible.sh find lists the
# records, and one it cannot read as JSON matches nothing. Its space fault
# (exit 4) stays this script's space exit; any other failure is an install
# fault.
find_gate_record() {
	if gate_records=$(sh "${crucible_script}" find --effort "${effort_dir}" --kind "${GATE_RECORD_KIND}" --label "$1" </dev/null); then
		find_status=0
	else
		find_status=$?
	fi
	case ${find_status} in
		0) ;;
		4) die 4 "crucible.sh find could not read the effort's gate records; its stderr is above; expected a readable ${GATE_RECORD_KIND} folder; fix what it names, then rerun" ;;
		*) die 5 "crucible.sh find failed on the effort's gate records (exit ${find_status}); its stderr is above; fix what it names, then rerun" ;;
	esac
	while IFS= read -r gate_record; do
		[ -n "${gate_record}" ] || continue
		jq -e --arg spec "${3:-}" --arg sha256 "${4:-}" "$2" "${gate_record}" </dev/null >/dev/null 2>&1 && return 0
	done <<EOF
${gate_records}
EOF
	return 1
}

# Runs git read-only in repo_root with the arguments given. Pathspec magic
# stays on whatever the caller's environment says, so the excludes below hold.
run_git() {
	GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 GIT_CONFIG_NOSYSTEM=1 GIT_LITERAL_PATHSPECS=0 \
		git --no-pager -c core.fsmonitor=false -C "${repo_root}" "$@" </dev/null
}

# Runs git as run_git does, leaving out every file context_path_problem
# refuses as sensitive or as a Claude settings file, so a diff can't carry
# what --path may not.
git_without_sensitive_files() {
	# shellcheck disable=SC2310 # its status is the lib's; a failure fails the git run
	excluded_pathspecs=$(context_excluded_pathspecs) || return 1
	set -- "$@" -- .
	while IFS= read -r excluded_pathspec; do
		[ -z "${excluded_pathspec}" ] || set -- "$@" "${excluded_pathspec}"
	done <<EOF
${excluded_pathspecs}
EOF
	find_config_settings_exclude
	[ -z "${config_settings_exclude}" ] || set -- "$@" "${config_settings_exclude}"
	run_git "$@"
}

# Sets config_settings_exclude to the pathspec leaving out the Claude config
# dir's settings.json when that dir is repo_root or, as text, a folder under
# it, the way context_config_path_problem compares it; to empty otherwise.
# literal keeps a * or [ in a folder name from matching other paths.
find_config_settings_exclude() {
	config_settings_exclude=''
	config_dir=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
	while [ "${config_dir}" != "${config_dir%/}" ]; do
		config_dir=${config_dir%/}
	done
	config_folder=${config_dir}/
	case ${config_folder} in
		"${repo_root}"/*)
			config_settings_exclude=":(exclude,icase,literal)${config_folder#"${repo_root}"/}settings.json"
			;;
		*) ;;
	esac
}

# diff: adds a problem when --repo is not an absolute, existing git
# work-tree root; sets repo_ok=true when it is.
check_repo_root() {
	repo_ok=false
	case ${repo_root} in
		/*) ;;
		*)
			add_problem --repo "${repo_root}" 'not an absolute path; expected the repository'\''s git work-tree root'
			return 0
			;;
	esac
	if [ ! -d "${repo_root}" ]; then
		add_problem --repo "${repo_root}" 'not an existing folder; expected the repository'\''s git work-tree root'
		return 0
	fi
	# shellcheck disable=SC2310 # its status is git's answer; a failure is reported
	if ! git_root=$(run_git rev-parse --show-toplevel 2>/dev/null); then
		add_problem --repo "${repo_root}" 'not in a git work tree; expected the repository'\''s git work-tree root'
		return 0
	fi
	if [ "${git_root}" != "${repo_root}" ]; then
		add_problem --repo "${repo_root}" "not the git work-tree root; expected ${git_root}"
		return 0
	fi
	repo_ok=true
}

# diff: adds a problem when --ref breaks its rule or a part does not resolve
# to a commit; sets from_sha (empty for a single commit), to_sha and short_sha.
check_ref() {
	from_sha='' to_sha='' short_sha=''
	ref_problem=$(ref_syntax_problem)
	if [ -n "${ref_problem}" ]; then
		add_problem --ref "${ref}" "${ref_problem}"
		return 0
	fi
	[ "${repo_ok}" = true ] || return 0
	case ${ref} in
		*..*)
			# shellcheck disable=SC2310 # its status says whether it resolved; a failure is reported
			resolve_commit "${ref%%..*}" || return 0
			from_sha=${resolved_sha}
			# shellcheck disable=SC2310 # its status says whether it resolved; a failure is reported
			resolve_commit "${ref#*..}" || return 0
			;;
		*)
			# shellcheck disable=SC2310 # its status says whether it resolved; a failure is reported
			resolve_commit "${ref}" || return 0
			;;
	esac
	to_sha=${resolved_sha}
	# shellcheck disable=SC2310 # its status is git's; a failure exits
	short_sha=$(run_git rev-parse --short "${to_sha}") ||
		die 5 "git rev-parse --short failed in ${repo_root}; expected a short sha; try git --version, then rerun"
}

# Prints why --ref breaks its rule, or nothing.
ref_syntax_problem() {
	ref_rule='a commit or a range A..B of 0-9 A-Z a-z . _ / ^ ~ - only, no part starting with -'
	case ${ref} in
		*[!0-9A-Za-z._/^~-]*) printf 'holds a character outside the allowed set; expected %s' "${ref_rule}" ;;
		*...*) printf 'holds ...; expected %s' "${ref_rule}" ;;
		*..*..*) printf 'holds .. more than once; expected %s' "${ref_rule}" ;;
		..* | *..) printf 'is a range with an empty end; expected %s' "${ref_rule}" ;;
		-* | *..-*) printf 'has a part starting with -; expected %s' "${ref_rule}" ;;
		*) ;;
	esac
}

# Sets resolved_sha to the full sha of commit $1 in repo_root, or adds a
# problem and fails.
resolve_commit() {
	# shellcheck disable=SC2310 # its status is git's answer; a failure is reported
	if resolved_sha=$(run_git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null); then
		case ${resolved_sha} in
			'' | *[!0-9a-f]*) ;;
			*) return 0 ;;
		esac
	fi
	add_problem --ref "${ref}" "$1 does not resolve to a commit in ${repo_root}; expected a commit of that repository"
	return 1
}

# diff: checks the inputs, writes the diff git prints into a temp file,
# checks it, then writes it into the effort's context/ and prints its path.
run_diff() {
	# shellcheck disable=SC2310 # its status says whether the folder passed; it reports its own problem
	check_effort_option || true
	check_repo_root
	check_ref
	placeholder_diff="${effort_dir}/context/${PLACEHOLDER_ID}-${DIFF_LABEL_PREFIX}${short_sha:-0000000}.json"
	space_problem=$(context_path_problem "${placeholder_diff}")
	[ -z "${space_problem}" ] ||
		add_problem CRUCIBLE_HOME "${space_root}" "${space_problem}; expected ${context_path_expected}${space_source}"
	exit_on_problems "${rule_problems}"
	require_open_effort
	diff_temp=$(mktemp "${TMPDIR:-/tmp}/${PROG}.XXXXXX") ||
		die 1 "mktemp could not create a temp file in \${TMPDIR:-/tmp}; no file was created; expected a writable temp folder; try setting TMPDIR to one, then rerun"
	# shellcheck disable=SC2310 # their status is git's; a failure exits
	if [ -n "${from_sha}" ]; then
		git_without_sensitive_files diff --no-color --no-ext-diff --no-textconv "${from_sha}..${to_sha}" >"${diff_temp}" ||
			die 1 "git diff failed in ${repo_root}; its stderr is above; no file was created; expected the range's diff; try the fix git names, then rerun"
	else
		# shellcheck disable=SC2310 # its status is git's; a failure exits
		git_without_sensitive_files show --no-color --no-ext-diff --no-textconv --no-show-signature "${to_sha}" >"${diff_temp}" ||
			die 1 "git show failed in ${repo_root}; its stderr is above; no file was created; expected the commit's diff; try the fix git names, then rerun"
	fi
	check_diff_text
	find_same_diff
	if [ -n "${same_diff}" ]; then
		printf 'DIFF_FILE: %s\n' "${same_diff}"
		return 0
	fi
	write_text_item "${DIFF_LABEL_PREFIX}${short_sha}" "${diff_temp}"
	printf 'DIFF_FILE: %s\n' "${written_path}"
}

# Sets same_diff to the effort's diff file of the same short sha whose text is
# exactly the diff in diff_temp, or to empty, so a rerun writes no second file.
find_same_diff() {
	same_diff=''
	diff_name_rest="${DIFF_LABEL_PREFIX}${short_sha}.json"
	for diff_candidate in "${effort_dir}/context/"*-"${diff_name_rest}"; do
		[ -f "${diff_candidate}" ] && [ ! -L "${diff_candidate}" ] || continue
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		crucible_split_id "${diff_candidate##*/}" && [ "${crucible_name_rest}" = "${diff_name_rest}" ] || continue
		# shellcheck disable=SC2016 # $text is jq's
		jq -e --rawfile text "${diff_temp}" '.text == $text' "${diff_candidate}" </dev/null >/dev/null 2>&1 || continue
		same_diff=${diff_candidate}
		return 0
	done
}

# latest: checks --effort and the effort's latest version, then prints its
# path and sha256; exits 1 when the effort has no version yet.
print_latest_version() {
	# shellcheck disable=SC2310 # its status says whether the folder passed; it reports its own problem
	check_effort_option || exit_on_problems "${rule_problems}"
	context_find_latest_version "${effort_dir}/context"
	if [ -z "${context_version_latest}" ]; then
		add_problem --effort "${effort_dir}" "no context version yet; expected v1 from ${PROG} new first"
		printf '%s' "${rule_problems}" >&2
		exit 1
	fi
	latest_path=${context_version_latest}
	latest_problem=$(version_file_problem "${latest_path}")
	if [ -n "${latest_problem}" ]; then
		shown_latest=$(printable "${latest_path}")
		add_problem --effort "${effort_dir}" "its latest version v${context_version_latest_number} (${shown_latest}) ${latest_problem}"
		exit_on_problems "${rule_problems}"
	fi
	# shellcheck disable=SC2310 # its status is the tool's; a failure exits
	compute_context_digest "${latest_path}" ||
		die 5 "${context_digest_tool} could not hash ${latest_path}; expected its sha256; try ${context_digest_tool} on it, then rerun"
	printf 'CONTEXT_FILE: %s\nCONTEXT_SHA256: %s\n' "${latest_path}" "${context_digest}"
}

# Exits 3 when the diff in diff_temp is empty, over the cap or not UTF-8.
check_diff_text() {
	if [ ! -s "${diff_temp}" ]; then
		add_problem --ref "${ref}" 'the diff is empty; expected a commit or range that changes something'
	else
		diff_status=0
		# shellcheck disable=SC2310 # its status: 0 a problem printed, 1 none, else a fault that has printed its cause
		diff_problem=$(long_text_problem "${diff_temp}" 'the diff') || diff_status=$?
		case ${diff_status} in
			0) add_problem --ref "${ref}" "${diff_problem}" ;;
			1) ;;
			*) exit "${diff_status}" ;;
		esac
	fi
	exit_on_problems "${rule_problems}"
}

temp_file='' diff_temp='' created_files='' tools_checked='' session_id=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp files and the files this
# run made go on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ "$#" -gt 0 ] || {
	usage >&2
	exit 2
}
case $1 in
	--help | -h)
		usage
		exit 0
		;;
	new | extend | diff | latest) command=$1 ;;
	*)
		shown_command=$(printable "$1")
		usage_error "unknown command: ${shown_command}; expected new, extend, diff, latest or --help"
		;;
esac
shift
effort_dir='' version_path='' repo_root='' ref='' seen_options='' rule_problems='' validator_problems=''
awaited_option='' entry_kind='' entry_value='' entry_why='' first_retire=''
note_count=0 text_file_count=0 retire_count=0
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

require_tools
load_dependencies
[ "${command}" = latest ] || require_session
resolve_space_root
case ${command} in
	new)
		check_new_effort
		next_number=1
		base_json=${EMPTY_BASE}
		write_version "$@"
		;;
	extend)
		check_from_version "$@"
		check_extend_rules "$@"
		write_version "$@"
		;;
	latest) print_latest_version ;;
	*) run_diff ;;
esac
