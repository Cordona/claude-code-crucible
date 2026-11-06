#!/usr/bin/env sh
# Prints the human's compact card for one developer commit the stop hook made
# in a worktree. Everything comes from the commit: the subject gives the kind,
# the trailers the count, the slot and the plugins, the committed report its counts and
# gates, and the commit's diff the files. card.jq lays it out with human-view.
# Read-only on the repo: no git command here takes the index lock or writes it.
set -eu
umask 077

readonly PROG='card.sh'
readonly MODULE='card'
readonly VIEW_LIB='human-view'
readonly REPORTS_DIR='.crucible-effort/reports'
# The card shows this many characters of the commit's sha.
readonly SHORT_SHA_LENGTH=12
readonly newline='
'
# The C locale keeps the shell byte-wise; jq reads the report as UTF-8.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
export GIT_OPTIONAL_LOCKS

# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly CARD_JQ='include "card";
($labels | split("\n")) as $names
| input
| card({language: $names[0], frameworks: $names[1:] | map(select(. != ""))};
	{total: $total, new: $new};
	{slot: $slot, count: "\($count_label) \($count)", short: $short, report_path: $report_path})'

# Prints a plugin SKILL.md's metadata.label by flow-agent-initialization's
# list-plugins.sh rules: the frontmatter opens on line 1 and is closed by
# ---; a "  label:" line under a "metadata:" line (a trailing comment
# allowed), the last one counting; a ` # comment` after an unquoted value
# dropped, one pair of quotes removed and tabs made spaces. Prints nothing
# when the frontmatter is not closed.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $0 is awk's
readonly PLUGIN_LABEL_AWK='
function clean(value) {
	sub(/^[ \t]+/, "", value)
	if (value !~ /^["\047]/) sub(/[ \t]+#.*$/, "", value)
	sub(/[ \t]+$/, "", value)
	if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
	sub(/^[ \t]+/, "", value)
	sub(/[ \t]+$/, "", value)
	gsub(/\t/, " ", value)
	return value
}
{ sub(/\r$/, "") }
NR == 1 { if ($0 != "---") exit; next }
$0 == "---" { closed = 1; exit }
/^[^ \t#]/ { in_metadata = ($0 ~ /^metadata:[ \t]*(#.*)?$/); next }
in_metadata && /^  label:/ { label = clean(substr($0, index($0, ":") + 1)) }
END { if (closed) print label }
'

usage() {
	cat <<EOF
usage: sh ${PROG} --worktree DIR --commit SHA [--skills-dir DIR]
       sh ${PROG} --help | -h

Prints the compact Markdown card of one developer commit. Reads the
commit only, never the working tree's report; writes nothing to the repo.

--worktree DIR    absolute path of the developer's git worktree
--commit SHA      4 to 64 hex digits: a crucible(dev), crucible(test) or
                  crucible(fix) commit
--skills-dir DIR  absolute; default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills;
                  holds ${VIEW_LIB} and each plugin, whose metadata.label
                  titles the card (the plugin name when it has none)

last line: **Developer report:** the short sha and the report's path: the
worktree's file when it still holds the committed report, else a new temp
file (mode 600, kept for the human) holding it.

exit codes:
  0  the card is printed
  2  wrong command line: a missing, repeated or unknown option, a path that
     is not absolute, or a --commit that is not hex; fix the call
  3  input: not a git worktree, the commit is missing, is no developer
     commit, has no single valid count or Agent-Slot trailer, or its report
     is missing or not one JSON object; one stderr line
  4  environment: git or jq missing or failed, ${MODULE}.jq not beside
     ${PROG}, ${VIEW_LIB} not in the skills dir, or the temp file failed

needs: POSIX sh, awk, git 2.26+, jq 1.6+
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
	printf "Try 'sh %s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 $4"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	worktree='' commit='' skills_dir=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--worktree)
				take_value "$1" "${worktree}" "${2-}" DIR
				worktree=${option_value}
				;;
			--commit)
				take_value "$1" "${commit}" "${2-}" SHA
				commit=${option_value}
				;;
			--skills-dir)
				take_value "$1" "${skills_dir}" "${2-}" DIR
				skills_dir=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --worktree, --commit, --skills-dir or --help"
				;;
		esac
		shift 2
	done
	[ -n "${worktree}" ] || usage_error '--worktree missing; expected --worktree DIR'
	[ -n "${commit}" ] || usage_error '--commit missing; expected --commit SHA'
	require_absolute --worktree "${worktree}"
	# Hex only, so the value can never reach git as an option or a revision expression.
	case ${commit} in
		*[!0-9a-fA-F]*)
			shown_commit=$(printable "${commit}")
			usage_error "--commit ${shown_commit} is not hex; expected 4 to 64 hex digits"
			;;
		????*) ;;
		*) usage_error "--commit ${commit} is too short; expected 4 to 64 hex digits" ;;
	esac
	[ "${#commit}" -le 64 ] || usage_error '--commit is longer than 64 digits; expected 4 to 64 hex digits'
	if [ -z "${skills_dir}" ]; then
		skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	fi
	require_absolute --skills-dir "${skills_dir}"
}

# Refuses option $1 whose path $2 is not absolute.
require_absolute() {
	case $2 in
		/*) ;;
		*)
			shown_path=$(printable "$2")
			usage_error "$1 ${shown_path} is not absolute; expected an absolute path"
			;;
	esac
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	[ -f "${own_dir}/${MODULE}.jq" ] || die 4 "${MODULE}.jq not found beside ${PROG}; expected both in one folder"
	view_dir="${skills_dir%/}/${VIEW_LIB}"
	for view_module in view title; do
		[ ! -f "${view_dir}/${view_module}.jq" ] || continue
		shown_module=$(printable "${view_dir}/${view_module}.jq")
		die 4 "${VIEW_LIB} module missing; expected ${shown_module}; install ${VIEW_LIB} or pass --skills-dir"
	done
}

# Sets worktree_root, the worktree's top folder as git names it, and enters it.
# Every git call here runs with GIT_OPTIONAL_LOCKS=0 and core.fsmonitor=false,
# so the index is neither refreshed nor written.
find_worktree() {
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || die 3 "--worktree ${shown_worktree} is not a folder; expected the developer's worktree"
	worktree_root=$(git -c core.fsmonitor=false -C "${worktree}" rev-parse --show-toplevel 2>/dev/null) ||
		die 3 "--worktree ${shown_worktree} is not a git worktree; expected the developer's worktree"
	[ -n "${worktree_root}" ] || die 3 "--worktree ${shown_worktree} has no working tree; expected the developer's worktree"
	cd -- "${worktree_root}" || die 3 "--worktree ${shown_worktree} can't be entered; expected a readable folder"
}

# Sets sha, count_label, count and slot, refusing a commit that is no
# developer commit.
read_commit() {
	sha=$(git -c core.fsmonitor=false rev-parse --verify --quiet "${commit}^{commit}") ||
		die 3 "commit ${commit} is not in the worktree's repository; expected a commit sha it holds"
	subject=$(git -c core.fsmonitor=false log -1 --format=%s "${sha}") || die 4 "git log failed on commit ${sha}"
	case ${subject} in
		'crucible(dev): '*) count_key='Build-Iteration' count_label='build iteration' ;;
		'crucible(test): '*) count_key='Test-Iteration' count_label='test iteration' ;;
		'crucible(fix): '*) count_key='Review-Round' count_label='review round' ;;
		*)
			shown_subject=$(printable "${subject}")
			die 3 "commit ${sha} is not a developer commit: its subject is ${shown_subject}; expected crucible(dev|test|fix): <summary>"
			;;
	esac
	count=$(trailer "${count_key}")
	case ${count} in
		'') die 3 "commit ${sha} has no ${count_key} trailer; expected the stop hook's commit" ;;
		*"${newline}"*) die 3 "commit ${sha} has more than one ${count_key} trailer; expected one" ;;
		0* | *[!0-9]*)
			shown_count=$(printable "${count}")
			die 3 "commit ${sha} has ${count_key} ${shown_count}; expected a whole number of 1 or more"
			;;
		*) ;;
	esac
	slot=$(trailer Agent-Slot)
	case ${slot} in
		'') die 3 "commit ${sha} has no Agent-Slot trailer; expected the stop hook's commit" ;;
		*"${newline}"*) die 3 "commit ${sha} has more than one Agent-Slot trailer; expected one" ;;
		*) ;;
	esac
	check_slot_name
}

# Refuses a slot that is no slot name: a lowercase word, a dash and a number
# of 1 or more, so it is safe as a file name.
check_slot_name() {
	slot_word=${slot%-*} slot_number=${slot##*-}
	case ${slot_word}/${slot_number} in
		/* | */ | *[!a-z]*/* | */0* | */*[!0-9]*)
			shown_slot=$(printable "${slot}")
			die 3 "commit ${sha} has Agent-Slot ${shown_slot}; expected a slot name like dev-1"
			;;
		*) ;;
	esac
}

# Prints the values of trailer $1 on the commit, one per line.
trailer() {
	git -c core.fsmonitor=false log -1 --format="%(trailers:key=$1,valueonly,unfold)" "${sha}" | sed '/^$/d'
}

# Sets report_text from the commit, refusing a missing or empty report. A dev
# or test commit holds its iteration's own report; a fix commit's report has
# no round in its name yet.
read_report() {
	case ${count_key} in
		Build-Iteration) report_entry="${REPORTS_DIR}/${slot}/build-iteration-${count}.json" ;;
		Test-Iteration) report_entry="${REPORTS_DIR}/${slot}/test-iteration-${count}.json" ;;
		*) report_entry="${REPORTS_DIR}/${slot}.json" ;;
	esac
	report_text=$(git -c core.fsmonitor=false cat-file blob "${sha}:${report_entry}" 2>/dev/null) ||
		die 3 "commit ${sha} holds no ${report_entry}; expected the report the stop hook committed"
	[ -n "${report_text}" ] || die 3 "commit ${sha} holds an empty ${report_entry}; expected one JSON object"
	printf '%s' "${report_text}" | jq -ne '[inputs] | length == 1 and (.[0] | type) == "object"' >/dev/null 2>&1 ||
		die 3 "commit ${sha}'s ${report_entry} is not one JSON object; expected the report the stop hook checked"
}

# Sets report_path: the worktree's report when it still holds the committed
# bytes, else a new temp file holding them.
place_report() {
	worktree_report="${worktree_root}/${report_entry}"
	committed_blob=$(git -c core.fsmonitor=false rev-parse --verify --quiet "${sha}:${report_entry}") || die 4 "git rev-parse failed on ${report_entry}"
	if [ -f "${worktree_report}" ] && [ ! -L "${worktree_report}" ]; then
		current_blob=$(git -c core.fsmonitor=false hash-object --no-filters -- "${worktree_report}" 2>/dev/null) || current_blob=''
		if [ "${current_blob}" = "${committed_blob}" ]; then
			report_path=${worktree_report}
			return 0
		fi
	fi
	temp_dir=${TMPDIR:-/tmp}
	count_name=$(printf '%s' "${count_label}" | tr ' ' '-')
	report_path=$(mktemp "${temp_dir%/}/crucible-card-${slot}-${count_name}${count}.XXXXXX") ||
		die 4 'mktemp could not create the temp report file; expected a writable TMPDIR'
	chmod 600 "${report_path}" || die 4 "could not set mode 600 on ${report_path}"
	git -c core.fsmonitor=false cat-file blob "${sha}:${report_entry}" >"${report_path}" ||
		die 4 "could not write the committed report to ${report_path}"
}

# Sets files_total and files_new: the commit's changed paths outside
# .crucible-effort, and those it added.
count_files() {
	counts=$(git -c core.fsmonitor=false diff-tree -r --root --no-commit-id --no-renames --name-status "${sha}" -- ':(exclude).crucible-effort' |
		awk '{ total++ } /^A/ { added++ } END { printf "%d %d", total, added }') ||
		die 4 "git diff-tree failed on commit ${sha}"
	files_total=${counts% *}
	files_new=${counts#* }
}

# Sets labels: the language's label, then each framework's, one per line.
read_labels() {
	language=$(trailer Language | head -n 1)
	frameworks=$(trailer Frameworks | head -n 1)
	labels=$(plugin_label "${language}")
	rest=${frameworks}
	while [ -n "${rest}" ]; do
		framework=${rest%%, *}
		case ${rest} in
			*', '*) rest=${rest#*, } ;;
			*) rest='' ;;
		esac
		labels="${labels}${newline}$(plugin_label "${framework}")"
	done
}

# Prints plugin $1's metadata.label, or $1 when it is not installed or has
# none; a name that is no skill name is never looked up as a path.
plugin_label() {
	label=''
	case $1 in
		'' | *[!a-z0-9-]* | -* | *-) ;;
		*)
			skill_file="${skills_dir%/}/$1/SKILL.md"
			[ ! -f "${skill_file}" ] || label=$(awk "${PLUGIN_LABEL_AWK}" "${skill_file}" 2>/dev/null) || label=''
			;;
	esac
	printf '%s' "${label:-$1}" | tr '[:cntrl:]' ' '
}

print_card() {
	short=$(printf '%s' "${sha}" | cut -c "1-${SHORT_SHA_LENGTH}")
	printf '%s' "${report_text}" | jq -nr -L "${own_dir}" -L "${view_dir}" \
		--arg labels "${labels}" --argjson total "${files_total}" --argjson new "${files_new}" \
		--arg slot "${slot}" --arg count_label "${count_label}" --arg count "${count}" \
		--arg short "${short}" --arg report_path "${report_path}" \
		"${CARD_JQ}" || die 4 "jq could not render the card; expected jq 1.6+, ${MODULE}.jq beside ${PROG} and ${VIEW_LIB} in the skills dir"
}

parse_args "$@"
load_dependencies
find_worktree
read_commit
read_report
count_files
read_labels
place_report
print_card
