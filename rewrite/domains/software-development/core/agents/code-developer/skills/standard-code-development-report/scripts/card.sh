#!/usr/bin/env sh
# Prints the human's compact card for one developer report the stop hook
# recorded. Everything comes from the seat's build.committed event: its type
# gives the kind, its iteration the count, its body the report's counts and
# gates, its dispatch (through the dispatch.made event) the plugins, and its
# commit's diff the files; the seat's fault.raised events since its last
# report, the commit's signature and the branch's upstream say what went
# wrong, as the effort's settings ask. views/card.jq lays it out and
# human-view's show.sh prints it. No git command here takes the index lock
# or writes it, and nothing is written to the effort.
set -eu
umask 077

readonly PROG='card.sh'
readonly MODULE='card'
readonly VIEW_LIB='human-view'
readonly SHOW='scripts/show.sh'
readonly RENDER_LIB='scripts/lib/render.sh'
# Its seats.jq holds the one seat-name check; seats.sh names the worktree.
readonly SEATS_LIB='procedure-git-worktree/scripts/seats'
readonly SETTINGS='procedure-git-setup/scripts/settings.sh'
readonly EVENTS='crucible/scripts/events.sh'
# The card shows this many characters of the commit's sha.
readonly SHORT_SHA_LENGTH=12
readonly newline='
'
# The C locale keeps the shell byte-wise; jq reads the report as UTF-8.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT

# The card's data for views/card.jq. Input: the report event.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly CARD_DATA_JQ='($labels | split("\n")) as $names
| {report: .body,
	labels: {language: $names[0], frameworks: $names[1:] | map(select(. != ""))},
	files: (if $total == "" then null else {total: ($total | tonumber), new: ($new | tonumber)} end),
	commit: {seat: $seat, count: $count, short: $short, report_path: $report_path,
		warnings: {faults: $faults, unsigned: ($unsigned == "yes"),
			not_pushed_to: (if $unpushed == "yes" then $remote else null end)}}}'

# The seat's report event: seq $seq, or the newest. Input: the seat's
# build.committed events, oldest first.
# shellcheck disable=SC2016
readonly EVENT_JQ='map(select(.seat == $seat and ($seq == "" or .seq == ($seq | tonumber)))) | last // empty'

# The body.what of each of the seat's faults after its report before this
# one, up to this one's time, as a JSON array. Input: every event and fault
# by time.
# shellcheck disable=SC2016
readonly FAULTS_JQ='($event | fromjson) as $this
| ([.[] | select(.type == "build.committed" and .seat == $this.seat and .seq < $this.seq)]
	| last | .at // "") as $since
| [.[] | select(.type == "fault.raised" and .body.seat == $this.seat and .at > $since and .at <= $this.at)
	| .body.what]'

# The language's plugin name, then each framework's, one per line, of the
# dispatch with id $id. Input: the dispatch.made events.
# shellcheck disable=SC2016
readonly PLUGINS_JQ='map(select(.body.id == $id)) | last // empty
| .body.plugins // {} | (.language.name // ""), (.frameworks // [] | .[] | .name // empty)'

# Prints a plugin SKILL.md's metadata.label by flow-code-agent-dispatch's
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
usage: sh ${PROG} --effort FOLDER --seat S [--seq N] [--skills-dir DIR]
       sh ${PROG} --help | -h

Prints the compact Markdown card of one developer report: seat S's newest
build.committed event, or the one with seq N. ${VIEW_LIB}'s show.sh prints
it from views/${MODULE}.jq and records it as owed this session (see its
--help); nothing is written to the effort.

--effort FOLDER   absolute path of the effort folder
--seat S          the seat, a seat name by seats.jq
--seq N           a whole number: that report event of the seat
--skills-dir DIR  absolute; default \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills;
                  holds ${VIEW_LIB} (its ${SHOW} and
                  ${RENDER_LIB}), ${EVENTS%%/*} (its events.sh),
                  procedure-git-worktree (its seats.jq and seats.sh),
                  ${SETTINGS%%/*} (its settings.sh) and each plugin, whose
                  metadata.label titles the card (the plugin name when it
                  has none)

The title's plugins are the language and frameworks of the dispatch.made
event whose body.id is the event's dispatch; none when there is no such
event. The files line counts the event's commit's changed and added paths
in the seat's worktree; with commit null it says no code change.

Warning lines, only when needed: one per fault.raised of the seat after
its report event before this one, up to this one's time; and, from git
for a commit, "commit not signed" when settings.sh get --effort FOLDER
names a signing key and the commit has no signature, "not pushed to
<remote>" when it says AUTO_PUSH=yes and the branch's upstream lacks the
commit. Without the effort's settings the git two don't show and stderr
says why.

last line: the commit's short sha and the event's path, which holds the
report in its body.

stdout: the card, for the human

environment:
  CLAUDE_CODE_SESSION_ID  set by the Bash tool; unset or empty: the card is
                    printed, nothing is recorded
  CLAUDE_CONFIG_DIR  the Claude Code config folder; default \$HOME/.claude

exit codes:
  0  the card is printed
  2  wrong command line: a missing, repeated or unknown option, a path that
     is not absolute, a --seq that is no number; fix the call
  3  input: S is no seat name, the seat has no such report event, its
     commit is no hex sha or not in its worktree, or its body is no JSON
     object; one stderr line
  4  environment: git or jq missing or failed, views/${MODULE}.jq not in
     this skill, or ${VIEW_LIB}/${SHOW},
     ${VIEW_LIB}/${RENDER_LIB}, ${EVENTS},
     ${SEATS_LIB}/seats.jq,
     ${SEATS_LIB}/seats.sh or
     ${SETTINGS} not in the skills
     dir; or show.sh failed (its stderr names why) or the reader was gone
  129, 130, 143  show.sh stopped by HUP, INT or TERM

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
	effort='' seat='' seq='' skills_dir=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" FOLDER
				effort=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--seq)
				take_value "$1" "${seq}" "${2-}" N
				seq=${option_value}
				;;
			--skills-dir)
				take_value "$1" "${skills_dir}" "${2-}" DIR
				skills_dir=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat, --seq, --skills-dir or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort FOLDER'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
	require_absolute --effort "${effort}"
	while [ "${effort}" != "${effort%/}" ]; do effort=${effort%/}; done
	case ${seq} in
		*[!0-9]* | 0*)
			shown_seq=$(printable "${seq}")
			usage_error "--seq ${shown_seq} is not a whole number from 1; expected an event's seq"
			;;
		*) ;;
	esac
	if [ -z "${skills_dir}" ]; then
		skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	fi
	require_absolute --skills-dir "${skills_dir}"
	skills_dir=${skills_dir%/}
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
	# The logical path, links kept as named: show.sh names the card's skill after it.
	views_dir=$(cd -- "${own_path}/../views" && pwd) || die 4 "this skill's views folder could not be entered; expected views/ beside scripts/"
	view_dir="${skills_dir}/${VIEW_LIB}"
	seats_dir="${skills_dir}/${SEATS_LIB}"
	events_script="${skills_dir}/${EVENTS}"
	settings_script="${skills_dir}/${SETTINGS}"
	render_lib="${view_dir}/${RENDER_LIB}"
	for needed in "${render_lib}" "${seats_dir}/seats.jq" \
		"${seats_dir}/seats.sh" "${events_script}" "${settings_script}"; do
		[ ! -f "${needed}" ] || continue
		shown_needed=$(printable "${needed}")
		die 4 "${shown_needed} not found; install its skill or pass --skills-dir"
	done
	# shellcheck source=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${view_dir}/scripts" "${views_dir}" "${MODULE}" || die 4 "${hv_printer_problem}"
	show_script=${hv_show}
}

# Refuses a seat that is no seat name by seats.jq, so it is safe in a path.
check_seat_name() {
	name_problem=$(jq -nr -L "${seats_dir}" --arg name "${seat}" 'include "seats"; $name | seats_name_problem' </dev/null) ||
		die 4 "jq failed checking the seat name; expected jq 1.6+ and ${SEATS_LIB}/seats.jq"
	[ -n "${name_problem}" ] || return 0
	shown_problem=$(printable "${name_problem}")
	die 3 "--seat ${shown_problem}"
}

# Prints events.sh slurp's output for "$@".
slurp() {
	sh "${events_script}" slurp --effort "${effort}" "$@" </dev/null ||
		die 4 'events.sh slurp failed (its stderr is above)'
}

# Sets event, the report event, and from it kind_label, count, commit,
# dispatch and event_path.
read_event() {
	committed=$(slurp --type build.committed)
	event=$(printf '%s\n' "${committed}" |
		jq -c --arg seat "${seat}" --arg seq "${seq}" "${EVENT_JQ}") ||
		die 4 'jq could not read the events events.sh slurp printed'
	[ -n "${event}" ] || die 3 "seat ${seat} has no build.committed event${seq:+ with seq ${seq}}; expected a report the stop hook recorded"
	fields=$(printf '%s\n' "${event}" |
		jq -r '.type, .seq, (.iteration.number // "" | tostring), (.commit // ""), (.dispatch // "" | tostring),
			(.body | type)') || die 4 'jq could not read the report event'
	type='' event_seq='' count='' commit='' dispatch='' body_type=''
	{
		IFS= read -r type || :
		IFS= read -r event_seq || :
		IFS= read -r count || :
		IFS= read -r commit || :
		IFS= read -r dispatch || :
		IFS= read -r body_type || :
	} <<EOF
${fields}
EOF
	[ "${body_type}" = object ] || die 3 "event ${event_seq}'s body is a JSON ${body_type}; expected the report the stop hook checked"
	kind_label="${type%.committed} iteration"
	if [ -n "${count}" ]; then
		count="${kind_label} ${count}"
	else
		count='no iteration'
	fi
	event_path=$(printf '%s/events/%06d-%s.json' "${effort}" "${event_seq}" "${type}")
	[ -f "${event_path}" ] || die 4 "event ${event_seq} is not at ${event_path}; expected events.sh's file name"
}

# Sets files_total, files_new, short, unsigned and unpushed, entering the
# seat's worktree; for no commit, none of them.
read_commit() {
	files_total='' files_new='' short='' unsigned=no unpushed=no remote=''
	[ -n "${commit}" ] || return 0
	# Hex only, so the value can never reach git as an option or a revision expression.
	case ${commit} in
		*[!0-9a-f]* | '')
			shown_commit=$(printable "${commit}")
			die 3 "event ${event_seq}'s commit ${shown_commit} is not a hex sha; expected the stop hook's commit"
			;;
		*) ;;
	esac
	find_worktree
	sha=$(git -c core.fsmonitor=false rev-parse --verify --quiet "${commit}^{commit}") ||
		die 3 "commit ${commit} is not in seat ${seat}'s worktree; expected the commit the event names"
	counts=$(git -c core.fsmonitor=false diff-tree -r --root --no-commit-id --no-renames --name-status "${sha}" |
		awk '{ total++ } /^A/ { added++ } END { printf "%d %d", total, added }') ||
		die 4 "git diff-tree failed on commit ${sha}"
	files_total=${counts% *}
	files_new=${counts#* }
	short=$(printf '%s' "${sha}" | cut -c "1-${SHORT_SHA_LENGTH}")
	read_git_state
}

# Enters the seat's worktree, as seats.sh get names it.
find_worktree() {
	worktree=$(sh "${seats_dir}/seats.sh" get --effort "${effort}" --seat "${seat}" </dev/null | jq -r '.worktree // empty') ||
		die 4 "seats.sh get failed for seat ${seat} (its stderr is above)"
	[ -n "${worktree}" ] && [ -d "${worktree}" ] || die 3 "seat ${seat} has no worktree folder; expected the seat's git worktree"
	cd -- "${worktree}" || die 3 "seat ${seat}'s worktree can't be entered; expected a readable folder"
}

# Sets unsigned and unpushed to yes for each thing gone wrong that the
# effort's settings ask about, read from git; neither, with a stderr line,
# when the settings can't be read.
read_git_state() {
	read_settings
	[ "${settings_found}" = yes ] || return 0
	# The commit's own signature header, not %G?: that says N for an ssh
	# signature whenever no allowed-signers file is configured.
	if [ -n "${signing_key}" ]; then
		signature_lines=$(git -c core.fsmonitor=false cat-file commit "${sha}" | sed -n '1,/^$/p' | grep -c '^gpgsig' || :)
		[ "${signature_lines}" -gt 0 ] || unsigned=yes
	fi
	[ "${auto_push}" = yes ] || return 0
	upstream=$(git -c core.fsmonitor=false rev-parse --verify --quiet '@{upstream}' 2>/dev/null) || upstream=''
	if [ -z "${upstream}" ] || ! git -c core.fsmonitor=false merge-base --is-ancestor "${sha}" "${upstream}" 2>/dev/null; then
		unpushed=yes
	fi
}

# Sets signing_key, auto_push and remote from settings.sh get for the
# effort, and settings_found; says why on stderr when there are none.
read_settings() {
	settings_found=no
	settings=$(sh "${settings_script}" get --effort "${effort}" 2>/dev/null </dev/null) || {
		warn "settings.sh get found no git setup for the effort; the card does not say whether the commit is signed or pushed"
		return 0
	}
	settings_found=yes
	signing_key='' auto_push='' remote=''
	while IFS= read -r setting; do
		case ${setting} in
			SIGNING_KEY=*) signing_key=${setting#SIGNING_KEY=} ;;
			AUTO_PUSH=*) auto_push=${setting#AUTO_PUSH=} ;;
			REMOTE=*) remote=$(printable "${setting#REMOTE=}") ;;
			*) ;;
		esac
	done <<EOF
${settings}
EOF
}

# Sets faults, the what of each of the seat's faults since its last report.
read_faults() {
	everything=$(slurp --faults)
	faults=$(printf '%s\n' "${everything}" | jq -c --arg event "${event}" "${FAULTS_JQ}") ||
		die 4 'jq could not read the faults events.sh slurp printed'
}

# Sets labels: the language's label, then each framework's, one per line,
# from the event's dispatch; none without its dispatch.made event.
read_labels() {
	labels=''
	[ -n "${dispatch}" ] || return 0
	dispatches=$(slurp --type dispatch.made)
	names=$(printf '%s\n' "${dispatches}" | jq -r --arg id "${dispatch}" "${PLUGINS_JQ}") ||
		die 4 'jq could not read the dispatch.made events'
	[ -n "${names}" ] || return 0
	first=yes
	while IFS= read -r name; do
		label=$(plugin_label "${name}")
		if [ "${first}" = yes ]; then
			labels=${label} first=no
		else
			labels="${labels}${newline}${label}"
		fi
	done <<EOF
${names}
EOF
}

# Prints plugin $1's metadata.label, or $1 when it is not installed or has
# none; a name that is no skill name is never looked up as a path.
plugin_label() {
	label=''
	case $1 in
		'' | *[!a-z0-9-]* | -* | *-) ;;
		*)
			skill_file="${skills_dir}/$1/SKILL.md"
			[ ! -f "${skill_file}" ] || label=$(awk "${PLUGIN_LABEL_AWK}" "${skill_file}" 2>/dev/null) || label=''
			;;
	esac
	printf '%s' "${label:-$1}" | tr '[:cntrl:]' ' '
}

print_card() {
	card_data=$(printf '%s\n' "${event}" | jq -c \
		--arg labels "${labels}" --arg total "${files_total}" --arg new "${files_new}" \
		--arg seat "${seat}" --arg count "${count}" --arg short "${short}" \
		--arg report_path "${event_path}" --argjson faults "${faults}" \
		--arg unsigned "${unsigned}" --arg unpushed "${unpushed}" --arg remote "${remote}" \
		"${CARD_DATA_JQ}") ||
		die 4 "jq could not build the card's data; expected jq 1.6+"
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${show_script}" "${views_dir}" "${MODULE}" "${effort}" "${card_data}" ||
		die 4 "show.sh could not print the card (its stderr is above)"
}

parse_args "$@"
load_dependencies
check_seat_name
read_event
read_labels
read_faults
read_commit
print_card
