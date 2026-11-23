#!/usr/bin/env sh
# Writes a Crucible commit message file from one input JSON file.
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh commit-message.sh --input FILE --out FILE

Writes a Crucible commit message file, the --message-file for commit-tree.sh,
commits-merge.sh or commit-object.sh.

Options:
  --input FILE  one JSON object {kind, text, trailers?}: kind is lowercase
                words joined by dashes; text is one line, and the subject
                "crucible(<kind>): <text>" is at most 72 characters; trailers
                maps lowercase-dash keys to one-line strings or whole numbers.
                No effort key: those scripts add it from their --effort
  --out FILE    the message file, absolute when it goes to --message-file;
                its folder must exist; replaced if present
Writes:    the --out file: the subject, then a blank line and one "Key: value"
           line per trailer in input order (change-id becomes Change-Id)
Stdout:    nothing
Exit:
  0  written
  2  refused, nothing changed; the reason is on stderr
  4  --out could not be written (check its folder), or jq failed
USAGE
}

prog='commit-message.sh'
max_problems=20
LC_ALL=C
export LC_ALL

refuse() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 2
}

fail() {
	printf '%s: %s\n' "${prog}" "$1" >&2
	exit 4
}

# Reads the input raw and prints {problems, message}: at most $max problem
# lines, and the message, null when any problem holds.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
message_jq='include "commit-message";
[try fromjson] as $parsed
| (if ($parsed | length) == 0 then ["the input is not valid JSON; expected one JSON object"] else $parsed[0] | commit_problems end) as $problems
| {problems: ($problems | if length > $max then .[:$max - 1] + ["\(length - $max + 1) more problems not shown"] else . end),
	message: (if ($problems | length) == 0 then $parsed[0] | commit_message else null end)}'

input='' out=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--input | --out)
			[ $# -ge 2 ] && [ -n "$2" ] || refuse "$1 needs a value"
			case $1 in --input) input=$2 ;; --out) out=$2 ;; *) ;; esac
			shift 2 ;;
		*) refuse "unknown argument $1; try --help" ;;
	esac
done
[ -n "${input}" ] || refuse '--input missing'
[ -n "${out}" ] || refuse '--out missing'
command -v jq >/dev/null 2>&1 || refuse 'jq not found'
[ -f "${input}" ] && [ -r "${input}" ] || refuse "--input ${input} is not a readable file"

result=$(jq -Rsc -L "$(dirname -- "$0")/../lib" --argjson max "${max_problems}" "${message_jq}" <"${input}") ||
	fail 'jq failed; expected jq 1.6+ and commit-message.jq in scripts/lib/'
problems=$(printf '%s\n' "${result}" | jq -r '.problems[]')
if [ -n "${problems}" ]; then
	printf '%s\n' "${problems}" | sed "s/^/${prog}: /" >&2
	exit 2
fi

case ${out} in */*) out_dir=${out%/*} ;; *) out_dir=. ;; esac
[ -n "${out_dir}" ] || out_dir=/
[ -d "${out_dir}" ] || fail "--out folder ${out_dir} does not exist"
[ ! -d "${out}" ] || fail "--out ${out} is a folder; expected a file path"
temp_file=$(mktemp "${out_dir}/.${out##*/}.XXXXXX") || fail "mktemp could not make a temp file beside ${out}"
trap 'rm -f -- "${temp_file}"' EXIT
printf '%s\n' "${result}" | jq -j '.message' >"${temp_file}" || fail "could not write the temp file beside ${out}"
mv -f -- "${temp_file}" "${out}" || fail "could not move the temp file onto ${out}"
