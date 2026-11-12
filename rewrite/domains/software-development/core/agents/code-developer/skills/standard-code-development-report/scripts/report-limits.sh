#!/usr/bin/env sh
# Prints the report's caps and allowed values from dev-report-check.jq's own
# constants, so the copy the developer reads in SKILL.md is never retyped,
# and places or compares that copy between SKILL.md's two marker lines.
set -eu

readonly PROG='report-limits.sh'
readonly MODULE='dev-report-check'
readonly SKILL='standard-code-development-report'
readonly START_MARKER='<!-- report-limits:start -->'
readonly END_MARKER='<!-- report-limits:end -->'
# The C locale keeps awk byte-wise over SKILL.md's UTF-8 text.
LC_ALL=C
export LC_ALL

# shellcheck disable=SC2016 # the backticks are Markdown code spans, not command substitution
readonly LIMITS_JQ='include "dev-report-check";
def code_spans: map("`\(.)`") | join(", ");
"- **Text cap:** \(report_text_max) characters per text.",
"- **Summary cap:** \(report_summary_max) characters.",
"- **Open cap:** \(report_open_max) items.",
"- **`verification` `result` values:** \(report_results | code_spans).",
"- **`security` `kind` values:** \(report_security_kinds | code_spans).",
"- **`blockers` `kind` values:** \(report_blocker_kinds | code_spans)."'

# Marker lines match with surrounding blanks and a CR ignored.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are awk's
readonly MARKERS_AWK='
function bare(text) { sub(/^[ \t]+/, "", text); sub(/[ \t\r]+$/, "", text); return text }
{ line = bare($0) }
line == start { starts++; if (!start_at) start_at = NR }
line == end { ends++; if (!end_at) end_at = NR }
END {
	if (starts != 1 || ends != 1) printf "holds %d start and %d end marker lines", starts, ends
	else if (end_at < start_at) printf "has its end marker (line %d) before its start marker (line %d)", end_at, start_at
}'

# Prints the file with the lines between the markers replaced by $LIMITS_BLOCK.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are awk's
readonly SPLICE_AWK='
function bare(text) { sub(/^[ \t]+/, "", text); sub(/[ \t\r]+$/, "", text); return text }
{ line = bare($0) }
line == end { inside = 0 }
!inside { print }
line == start { print ENVIRON["LIMITS_BLOCK"]; inside = 1 }'

usage() {
	cat <<EOF
usage: sh ${PROG} [--write FILE | --check FILE]
       sh ${PROG} --help | -h

Prints the BUILD report's caps (text, summary, open) and the allowed values
of verification[].result, security[].kind and blockers[].kind as Markdown
bullet lines, read from ${MODULE}.jq's constants: the block between the
lines ${START_MARKER} and ${END_MARKER}
in the ${SKILL} skill's SKILL.md.

(no option)   print the lines on stdout
--write FILE  replace the lines between FILE's markers with them; FILE is
              whole or unchanged, and left as it is when the block already
              matches. Nothing else is left behind (a SIGKILL aside).
--check FILE  compare FILE's block with them; reads only, prints nothing on
              stdout

stdout, with no option: the bullet lines, to relay or paste.

exit codes:
  0  printed, written, or --check found the block matching; done
  1  --check: the block differs; run sh ${PROG} --write FILE
  2  wrong command line; fix what stderr names and rerun
  3  FILE's markers are missing, repeated or out of order; nothing was
     written; fix the markers stderr names and rerun
  4  environment fault; show the human stderr, and stop

needs: POSIX sh, awk, jq 1.6+, ${MODULE}.jq beside ${PROG}
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

# Prints $1 with each control character as "?", so a path can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

parse_args() {
	mode=print file=''
	[ "$#" -gt 0 ] || return 0
	case $1 in
		-h | --help)
			usage
			exit 0
			;;
		--write | --check)
			[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 FILE"
			[ "$#" -eq 2 ] || usage_error "too many arguments; expected one of --write FILE or --check FILE"
			mode=${1#--} file=$2
			;;
		*)
			shown_option=$(printable "$1")
			usage_error "unknown option: ${shown_option}; expected --write, --check or --help"
			;;
	esac
}

check_file() {
	[ -n "${file}" ] || return 0
	shown_file=$(printable "${file}")
	[ ! -L "${file}" ] || usage_error "${shown_file} is a symbolic link; expected the file it links to"
	[ -f "${file}" ] && [ -r "${file}" ] ||
		usage_error "${shown_file} is not a readable file; expected the skill's SKILL.md"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH; install it and rerun'
	command -v awk >/dev/null 2>&1 || die 4 'awk not found; expected a POSIX awk on PATH'
	own_dir=$(script_dir)
	[ -f "${own_dir}/${MODULE}.jq" ] ||
		die 4 "${MODULE}.jq not found beside ${PROG}; expected the ${SKILL} skill installed whole"
}

# Sets LIMITS_BLOCK: the bullet lines.
read_limits() {
	LIMITS_BLOCK=$(jq -nr -L "${own_dir}" "${LIMITS_JQ}") ||
		die 4 "jq could not read ${MODULE}.jq's constants; expected jq 1.6+ and the skill's own ${MODULE}.jq"
	export LIMITS_BLOCK
}

check_markers() {
	problem=$(awk -v start="${START_MARKER}" -v end="${END_MARKER}" "${MARKERS_AWK}" "${file}") ||
		die 4 "awk could not read ${shown_file}; expected a readable text file"
	[ -z "${problem}" ] ||
		die 3 "${shown_file} ${problem}; expected one ${START_MARKER} line, then one ${END_MARKER} line; nothing written"
}

check_block() {
	spliced=$(awk -v start="${START_MARKER}" -v end="${END_MARKER}" "${SPLICE_AWK}" "${file}") || die 4 "awk could not read ${shown_file}; expected a readable text file"
	current=$(cat -- "${file}") || die 4 "could not read ${shown_file}; expected a readable text file"
	[ "${spliced}" = "${current}" ] && exit 0
	warn "${shown_file}'s limits block differs from ${MODULE}.jq; run sh ${PROG} --write FILE"
	exit 1
}

remove_temp() {
	[ -z "${temp}" ] || rm -f -- "${temp}"
}

write_block() {
	temp=''
	trap remove_temp EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	case ${file} in
		*/*) folder=${file%/*} ;;
		*) folder=. ;;
	esac
	name=${file##*/}
	# Copied first so the replacement keeps FILE's mode; then overwritten in place.
	temp=$(mktemp "${folder}/.${name}.XXXXXX") ||
		die 4 "could not make a temp file beside ${shown_file}; expected a writable folder; check its permissions and rerun"
	cp -p -- "${file}" "${temp}" ||
		die 4 "could not copy ${shown_file} beside itself; expected a writable folder; check its permissions and rerun"
	awk -v start="${START_MARKER}" -v end="${END_MARKER}" "${SPLICE_AWK}" "${file}" >"${temp}" || die 4 "could not write the temp file beside ${shown_file}; expected free space and a writable folder"
	if cmp -s -- "${temp}" "${file}"; then
		return 0
	fi
	mv -f -- "${temp}" "${file}" ||
		die 4 "could not replace ${shown_file}; expected a writable folder; check its permissions and rerun"
	temp=''
}

parse_args "$@"
check_file
load_dependencies
read_limits
case ${mode} in
	print) printf '%s\n' "${LIMITS_BLOCK}" ;;
	check)
		check_markers
		check_block
		;;
	write)
		check_markers
		write_block
		;;
	*) die 4 "unknown mode ${mode}; expected print, check or write" ;;
esac
