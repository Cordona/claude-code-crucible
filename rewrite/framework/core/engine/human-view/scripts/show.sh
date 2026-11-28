#!/usr/bin/env sh
# Prints one card for the human, rendered from its template, and records it as
# owed this session, so show-stop-hook.sh can check the main thread showed it.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='show.sh'
readonly REQUIRED_TOOLS='cat chmod cut date find ln mkdir mktemp mv od rm tr'
# A clash needs the same second and 4 random hex digits; a handful of fresh
# draws makes a repeat practically impossible.
readonly MAX_ID_ATTEMPTS=5
# The jq status the wrapper halts with when line.jq's field finds a field
# missing; jq's own statuses are 0 to 5.
readonly MISSING_FIELD_STATUS=6
# The C locale makes the shell's character classes byte-wise on every platform.
LC_ALL=C
export LC_ALL

usage() {
	cat <<EOF
usage: sh ${PROG} view --views DIR --name NAME [--effort FOLDER] [--gate LABEL] < data.json
       sh ${PROG} line --views DIR --name NAME [--arg FIELD VALUE]...
       sh ${PROG} render --views DIR --name NAME < data.json
       sh ${PROG} --help | -h

Prints one card for the human from its template and records it as owed this
session; show-stop-hook.sh checks that the main thread's last message shows
it (see show-stop-hook.sh --help).

Commands:
  view  renders DIR/NAME.jq, a jq module defining "def view:", over the one
        JSON value on stdin
  line  renders the def NAME of DIR/lines.jq over {FIELD: VALUE, ...}
  render
        renders DIR/NAME.jq as view does and records nothing: for a gate
        renderer, whose output open-gate.sh shows and records
A template may include human-view's modules (view, paths, title, gate, line)
and its skill's own, by name: include "common"; reads DIR/common.jq.
A template that reads a field through line's field("FIELD") is refused, exit
2, when that field is missing, null or "": stderr names the line or template
and the field, and nothing is printed or recorded.

Options:
  --views DIR       the views folder of the card's skill, <skill>/views; the
                    record names <skill>
  --name NAME       view, render: a-z, 0-9 and -; line: a-z, 0-9 and _, not
                    starting with a digit
  --effort FOLDER   view only: the absolute effort folder the card belongs to
  --gate LABEL      view only: the card is gate LABEL, shown when it ends the
                    message with only owed cards above it, its question held
                    until then
  --arg FIELD VALUE line only: one input field, FIELD a jq name; repeatable,
                    each FIELD once

Environment:
  CLAUDE_CODE_SESSION_ID  the session id Claude Code sets in the Bash tool;
                    unset or empty: the card is printed, nothing is recorded;
                    render never reads it
  CLAUDE_CONFIG_DIR  the Claude Code config folder; default \$HOME/.claude

stdout: the card, for the human (render: the rendered text)

Writes, under \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/human-view/ only:
  <session id>/owed/<id>.json, owner-only, one JSON object {id, kind (card
    or gate), name, skill, effort (FOLDER or null), gate (LABEL or null),
    text (the card as printed), status (owed), tries, created (UTC, ISO 8601)}
  it replaces the session's owed record of the same card, keeping its tries,
    and for a gate the session's earlier gate
  other sessions' folders unchanged for ${hv_stale_minutes-} minutes are removed; a
    symbolic link is never followed or removed
Nothing else is left behind (a SIGKILL aside). Exit 2 or 5 writes nothing;
render writes nothing.

Exit codes:
  0  done; show the card
  1  the template or the record failed; show the human stderr, and stop
  2  refused input; fix what stderr names and rerun once, else show the
     human stderr
  4  render only: stdout closed before the text was written, nothing on
     stderr; stop and show the exit code
  5  install fault; show the human stderr, which names what to install
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code

Dependencies (a missing one exits 5, named):
  POSIX sh; ${REQUIRED_TOOLS}
  jq 1.6+ (macOS: brew install jq; Linux: the distro's jq package)
  lib/owed.sh and lib/owed.jq beside it (install the human-view skill)
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

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${error_file}" ] || rm -f "${error_file}"
	[ -z "${record_temp}" ] || rm -f "${record_temp}"
}

# Sets views, name, effort, gate and, for line, input (the --arg fields as
# one JSON object), or exits 2.
parse_args() {
	views='' name='' effort='' gate='' seen='' input='{}'
	while [ "$#" -gt 0 ]; do
		case ${command}:$1 in
			*:--views | *:--name | view:--effort | view:--gate) ;;
			line:--arg)
				[ "$#" -ge 3 ] || usage_error '--arg needs a field and a value; expected --arg FIELD VALUE'
				add_field "$2" "$3"
				shift 3
				continue
				;;
			view:*) usage_error "unknown argument for view: $1; expected --views, --name, --effort or --gate" ;;
			render:*) usage_error "unknown argument for render: $1; expected --views or --name" ;;
			*) usage_error "unknown argument for line: $1; expected --views, --name or --arg" ;;
		esac
		case "${seen} " in
			*" $1 "*) usage_error "$1 given twice; expected it at most once" ;;
			*) seen="${seen} $1" ;;
		esac
		[ "$#" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
		case $1 in
			--views) views=$2 ;;
			--name) name=$2 ;;
			--effort) effort=$2 ;;
			*) gate=$2 ;;
		esac
		shift 2
	done
	check_views
	check_name
	case "${seen} " in
		*" --effort "*) check_effort ;;
		*) ;;
	esac
	case "${seen} " in
		*" --gate "*) check_gate ;;
		*) ;;
	esac
}

# Adds field $1 with value $2 to input, or exits 2 unless $1 is a jq name
# not given before. The value is never checked: it reaches jq only as an
# --arg string.
add_field() {
	case $1 in
		'' | [0-9]* | *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*)
			usage_error "bad --arg field: $1; expected a jq name: letters, digits and _, not starting with a digit"
			;;
		*) ;;
	esac
	if printf '%s' "${input}" | jq -e --arg key "$1" 'has($key)' >/dev/null; then
		usage_error "--arg field $1 given twice; expected each field once"
	fi
	input=$(jq -cn --argjson fields "${input}" --arg key "$1" --arg value "$2" '$fields + {($key): $value}') ||
		die 1 'jq could not build the line'"'"'s fields; expected jq 1.6+'
}

# Sets views (absolute, without . or ..) and skill, or exits 2.
check_views() {
	[ -n "${views}" ] || usage_error '--views missing or empty; expected --views DIR, the views folder of the card'"'"'s skill'
	[ -d "${views}" ] || usage_error "--views ${views}: not a folder; expected the views folder of the card's skill"
	# The logical path, links kept as named, so the skill is the installed name.
	views=$(cd -- "${views}" && pwd) || usage_error "--views ${views}: cannot enter it; expected a folder your user can read"
	skill_dir=${views%/*}
	skill=${skill_dir##*/}
	[ -n "${skill}" ] || usage_error "--views ${views}: no skill folder above it; expected <skill>/views"
}

# Sets template_file from the checked name, or exits 2.
check_name() {
	[ -n "${name}" ] || usage_error '--name missing or empty; expected --name NAME, the card or line to print'
	if [ "${command}" != line ]; then
		case ${name} in
			*[!abcdefghijklmnopqrstuvwxyz0123456789-]* | -*) usage_error "bad --name: ${name}; expected a view name of a-z, 0-9 and -" ;;
			*) ;;
		esac
		template_file="${views}/${name}.jq"
	else
		case ${name} in
			[0-9]* | *[!abcdefghijklmnopqrstuvwxyz0123456789_]*) usage_error "bad --name: ${name}; expected a line name of a-z, 0-9 and _, not starting with a digit" ;;
			*) ;;
		esac
		template_file="${views}/lines.jq"
	fi
	[ -f "${template_file}" ] && [ -r "${template_file}" ] ||
		usage_error "template missing: ${template_file}; expected a readable jq module; try the skill's views folder and the card's name"
}

check_effort() {
	case ${effort} in
		/*) ;;
		*) usage_error "--effort ${effort}: not an absolute path; expected the absolute effort folder" ;;
	esac
	case ${effort} in
		*[[:cntrl:]]*) usage_error '--effort holds a control character; expected the absolute effort folder' ;;
		*) ;;
	esac
	[ -d "${effort}" ] || usage_error "--effort ${effort}: not a folder; expected the absolute effort folder"
}

check_gate() {
	case ${gate} in
		'' | *[[:cntrl:]]*) usage_error '--gate is empty or holds a control character; expected --gate LABEL, the label the gate'"'"'s procedure sets' ;;
		*) ;;
	esac
}

# Exits 5 unless every tool, jq 1.6+ and the store's rules are installed;
# the rules are sourced on start, so --help can print their values.
check_install() {
	for tool in ${REQUIRED_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 ||
			die 5 "${tool} missing; expected it on PATH; try installing your base system's ${tool}"
	done
	command -v jq >/dev/null 2>&1 || die 5 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || die 5 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) die 5 "jq is ${jq_version}; expected jq 1.6+; try upgrading jq" ;;
	esac
	for lib_file in "${lib_dir}/owed.sh" "${lib_dir}/owed.jq"; do
		[ -f "${lib_file}" ] && [ -r "${lib_file}" ] ||
			die 5 "${lib_file} missing; expected it beside ${PROG}; try reinstalling the human-view skill"
	done
}

# Sets input to the one JSON value on stdin, the card's data, or exits 2.
read_view_input() {
	input=$(cat) || die 1 'cannot read stdin; expected the card'"'"'s data as one JSON value'
	printf '%s\n' "${input}" | jq -en '[inputs] | length == 1' >/dev/null 2>&1 ||
		usage_error 'stdin is not one JSON value; expected the card'"'"'s data as one JSON value'
}

# Sets card to the template's text over input, or exits 1 naming jq's error,
# or 2 when line.jq's field finds a field missing.
render() {
	if [ "${command}" = line ]; then entry=${name}; else entry=view; fi
	template=$(cat "${template_file}") || die 1 "cannot read ${template_file}; expected a readable jq module"
	program="${template}
[try ${entry} catch (. as \$error
	| if (\$error | type) == \"object\" and ((\$error.missing_field | type) == \"string\")
	then \$error.missing_field | halt_error(${MISSING_FIELD_STATUS}) else error(\$error) end)]
| if length == 1 and (.[0] | type) == \"string\" then .[0]
else error(\"the template gave \\(length) values, expected one string\") end"
	error_file=$(mktemp "${TMPDIR:-/tmp}/show.XXXXXX") || die 1 'cannot create a temp file; expected a writable TMPDIR'
	jq_status=0
	card=$(printf '%s\n' "${input}" | jq -r -L "${hv_dir}" -L "${views}" "${program}" 2>"${error_file}") ||
		jq_status=$?
	if [ "${jq_status}" -ne 0 ]; then
		jq_error=$(tr -d '\001-\037\177' <"${error_file}" | cut -c1-300) || jq_error=''
		[ "${jq_status}" -ne "${MISSING_FIELD_STATUS}" ] || refuse_missing_field "${jq_error}"
		die 1 "${template_file} (${entry}) failed: ${jq_error}; expected a jq module whose ${entry} gives one string; try fixing the template"
	fi
	case ${card} in
		*[![:space:]]*) ;;
		*) die 1 "${template_file} (${entry}) rendered nothing; expected a card to show; try fixing the template or its data" ;;
	esac
}

# Exits 2 naming the line, or the template, and the field $1 it needs.
refuse_missing_field() {
	[ "${command}" != line ] ||
		usage_error "line ${name} needs field $1, missing or empty; expected --arg $1 VALUE"
	usage_error "${template_file} needs field $1 in its data, missing, null or empty; expected stdin's data to carry it"
}

# Records the card as owed in this session's store, or exits 1.
record_card() {
	# shellcheck disable=SC2310 # its status says whether the paths are usable; the problem is read below
	hv_set_paths "${session_id}" || die 1 "${hv_path_problem}, then rerun"
	write_fix="expected a writable ${hv_owed_dir}; try checking its owner and free space, then rerun"
	mkdir -p "${hv_owed_dir}" || die 1 "cannot create ${hv_owed_dir}; ${write_fix}"
	chmod 700 "${hv_session_dir}" "${hv_owed_dir}" || die 1 "cannot set mode 700 on ${hv_owed_dir}; ${write_fix}"
	# shellcheck disable=SC2310 # its status says whether every idle folder went; the folder is read below
	hv_sweep_idle "${hv_root}" "${session_id}" ||
		warn "cannot remove the idle folder ${hv_sweep_problem}; left in place; check its owner"
	stamp=$(date -u +%Y%m%dT%H%M%SZ) || die 1 'date -u failed; expected a POSIX date on PATH'
	kind=card
	[ -z "${gate}" ] || kind=gate
	candidate=$(jq -cn --arg kind "${kind}" --arg name "${name}" --arg skill "${skill}" \
		--arg effort "${effort}" --arg gate "${gate}" --arg text "${card}" --arg stamp "${stamp}" \
		'{kind: $kind, name: $name, skill: $skill,
		effort: (if $effort == "" then null else $effort end),
		gate: (if $gate == "" then null else $gate end),
		text: $text, status: "owed", tries: 0,
		created: "\($stamp[0:4])-\($stamp[4:6])-\($stamp[6:8])T\($stamp[9:11]):\($stamp[11:13]):\($stamp[13:15])Z"}') ||
		die 1 'jq could not build the record; expected jq 1.6+'
	find_replaced
	write_record
	remove_replaced
}

# The verdict on an earlier record: "replace <tries>" for this card still
# owed (its tries carried) or any earlier gate when this card is a gate,
# "drop" for a stale or malformed one, else "keep".
# shellcheck disable=SC2016 # the $ names are jq's
readonly VERDICT_JQ='include "owed";
def same_card: [.kind, .name, .skill, .effort, .gate, .text]
	== [$new.kind, $new.name, $new.skill, $new.effort, $new.gate, $new.text];
if is_owed_record | not then "drop"
elif is_stale(now; $stale) then "drop"
elif .status == "owed" and same_card then "replace \(.tries)"
elif .kind == "gate" and $new.kind == "gate" then "replace 0"
else "keep" end'

# Sets replaced to the paths of the records this one replaces or drops, one
# per line, and carried to the most tries among the replaced.
find_replaced() {
	replaced='' carried=0
	for existing in "${hv_owed_dir}"/*.json; do
		[ -f "${existing}" ] && [ ! -L "${existing}" ] || continue
		verdict=$(jq -r -L "${lib_dir}" --argjson new "${candidate}" --argjson stale "${hv_stale_seconds}" \
			"${VERDICT_JQ}" "${existing}" 2>/dev/null) || verdict=drop
		case ${verdict} in
			keep) continue ;;
			'replace '*)
				verdict_tries=${verdict#replace }
				[ "${verdict_tries}" -le "${carried}" ] || carried=${verdict_tries}
				;;
			*) ;;
		esac
		replaced="${replaced}${existing}
"
	done
}

# Writes the record under a fresh id, never over another record, and sets
# record_file.
write_record() {
	attempt=1
	while :; do
		hex=$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n') || die 1 'cannot read /dev/urandom; expected od and /dev/urandom'
		record_id="${stamp}-${hex}"
		record_file="${hv_owed_dir}/${record_id}.json"
		record_temp=$(mktemp "${hv_owed_dir}/.tmp.XXXXXX") || die 1 "cannot create a temp file in ${hv_owed_dir}; ${write_fix}"
		jq -cn --argjson record "${candidate}" --arg id "${record_id}" --argjson tries "${carried}" \
			'{id: $id} + $record + {tries: $tries}' >"${record_temp}" ||
			die 1 "cannot write ${record_temp}; ${write_fix}"
		if ln "${record_temp}" "${record_file}" 2>/dev/null; then
			rm -f "${record_temp}"
			record_temp=''
			return 0
		fi
		rm -f "${record_temp}"
		record_temp=''
		[ "${attempt}" -lt "${MAX_ID_ATTEMPTS}" ] || die 1 "cannot write a new record in ${hv_owed_dir}; ${write_fix}"
		attempt=$((attempt + 1))
	done
}

remove_replaced() {
	while IFS= read -r old_record; do
		[ -n "${old_record}" ] || continue
		rm -f "${old_record}" || warn "cannot remove the replaced record ${old_record}; check its owner"
	done <<EOF
${replaced}
EOF
}

case $0 in
	*/*) script_dir=${0%/*} ;;
	*) script_dir=. ;;
esac
hv_dir="${script_dir}/.."
lib_dir="${script_dir}/lib"
if [ -f "${lib_dir}/owed.sh" ] && [ -r "${lib_dir}/owed.sh" ]; then
	# shellcheck source=lib/owed.sh
	. "${lib_dir}/owed.sh"
fi
[ "$#" -gt 0 ] || usage_error 'missing command; expected view, line, render or --help'
command=$1
shift
case ${command} in
	--help | -h)
		usage
		exit 0
		;;
	view | line | render) ;;
	*) usage_error "unknown command: ${command}; expected view, line, render or --help" ;;
esac
check_install
parse_args "$@"
session_id=''
[ "${command}" = render ] || session_id="${CLAUDE_CODE_SESSION_ID-}"
if [ -n "${session_id}" ]; then
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	hv_is_safe_id "${session_id}" ||
		usage_error 'CLAUDE_CODE_SESSION_ID holds characters a folder name cannot safely carry; expected only letters, digits, ".", "_" and "-"; try running this from the Bash tool, which sets it'
fi
error_file='' record_temp=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
[ "${command}" = line ] || read_view_input
render
if [ "${command}" = render ]; then
	# Ignoring SIGPIPE turns a gone reader into a failed write, exit 4, rather
	# than a silent kill.
	trap '' PIPE
	printf '%s\n' "${card}" 2>/dev/null || exit 4
	exit 0
fi
[ -z "${session_id}" ] || record_card
printf '%s\n' "${card}"
