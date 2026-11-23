#!/usr/bin/env sh
# Repoints the launchers of a virtual env copied into a fresh tree: each
# text file in the named subfolders that names the checkout's copy of the
# folder is rewritten, in the tree only, to name the tree's.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh setup-repoint.sh --from CHECKOUT --to TREE --folder PATH
         --subfolder SUB [--subfolder SUB]...

Run by worktree-setup.sh; not for main to call.

Options:
  --from CHECKOUT   the checkout PATH was copied from, absolute
  --to TREE         the tree PATH was copied into, absolute
  --folder PATH     the copied folder, relative to TREE
  --subfolder SUB   a launcher folder in PATH; repeatable; skipped if missing
Writes:    text files directly in TREE/PATH/SUB: CHECKOUT/PATH becomes TREE/PATH
Stdout:    one JSON object {folder, repointed}; repointed = files rewritten
Exit:
  0  done
  2  refused, nothing changed; the reason is on stderr
  4  some or all files not repointed; the reasons are on stderr
USAGE
}

gw_prog='setup-repoint.sh'
. "$(dirname -- "$0")/../lib/git-worktree.sh"

# Rewrites one launcher: every occurrence of a SOURCES line, matched without
# case and ending at a path boundary, becomes TARGET. Writes the result to
# OUT and prints the number of occurrences replaced. The earliest match wins,
# the longest on a tie, so a source that ends inside another is never cut.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are awk's
readonly REPOINT_AWK='
function next_match(text, start,    k, at, from, after) {
	match_at = 0
	match_length = 0
	for (k = 1; k <= source_count; k++) {
		from = start
		while ((at = index(substr(text, from), source[k])) > 0) {
			at += from - 1
			after = substr(text, at + length(source[k]), 1)
			if (after !~ /[A-Za-z0-9._-]/) break
			from = at + 1
		}
		if (at > 0 && (match_at == 0 || at < match_at || (at == match_at && length(source[k]) > match_length))) {
			match_at = at
			match_length = length(source[k])
		}
	}
}
BEGIN {
	listed = split(ENVIRON["SOURCES"], lines, "\n")
	for (k = 1; k <= listed; k++) if (lines[k] != "") source[++source_count] = tolower(lines[k])
	target = ENVIRON["TARGET"]
	out = ENVIRON["OUT"]
}
{
	lowered = tolower($0)
	line = ""
	position = 1
	for (next_match(lowered, position); match_at > 0; next_match(lowered, position)) {
		line = line substr($0, position, match_at - position) target
		position = match_at + match_length
		replaced++
	}
	if (NR > 1) printf "\n" > out
	printf "%s", line substr($0, position) > out
}
END {
	if (NR > 0 && ENVIRON["FINAL_NEWLINE"] == "yes") printf "\n" > out
	print replaced + 0
}'

repoint_subfolder() {
	copy_folder="${to_root}/$1/$2"
	[ -d "${copy_folder}" ] && [ ! -L "${copy_folder}" ] || return 0
	physical_folder=$(cd -P -- "${copy_folder}" 2>/dev/null && pwd -P) || physical_folder=''
	physical_copy=$(cd -P -- "${to_root}/$1" 2>/dev/null && pwd -P) || physical_copy=''
	case ${physical_folder} in
		"${physical_copy}"/*) ;;
		*)
			gw_add_problem "$1/$2 was not repointed: it leads outside the copy; expected a folder inside it"
			return 0
			;;
	esac
	for launcher in "${copy_folder}"/* "${copy_folder}"/.[!.]* "${copy_folder}"/..?*; do
		[ -f "${launcher}" ] && [ ! -L "${launcher}" ] || continue
		repoint_launcher "${launcher}" "${from_root}/$1/$2/${launcher##*/}" "$1"
	done
}

# Rewrites launcher $1 (its source is $2) of copied folder $3 when it is text
# holding the folder's --from path; counts it in $changed.
repoint_launcher() {
	shown_launcher=$(gw_printable "${1#"${to_root}"/}")
	if [ "$1" -ef "$2" ]; then
		gw_add_problem "${shown_launcher} was not repointed: it is the source file itself; expected a separate copy"
		return 0
	fi
	nul_bytes=$(tr -cd '\000' <"$1" | wc -c) || nul_bytes=1
	[ "${nul_bytes}" -eq 0 ] || return 0
	final_newline=no
	last_byte=$(tail -c 1 "$1")
	[ -n "${last_byte}" ] || final_newline=yes
	rewritten="${gw_work}/rewritten"
	rm -f "${rewritten}"
	if ! replaced=$(SOURCES="${from_root}/$3
${from_given}/$3" TARGET="${to_root}/$3" OUT="${rewritten}" FINAL_NEWLINE="${final_newline}" awk "${REPOINT_AWK}" "$1"); then
		gw_add_problem "${shown_launcher} was not repointed: awk failed; expected a readable text file"
		return 0
	fi
	[ "${replaced}" -gt 0 ] || return 0
	if cat "${rewritten}" >"$1"; then
		changed=$((changed + 1))
	else
		gw_add_problem "${shown_launcher} was not repointed: it could not be written; expected a writable copy"
	fi
}

# Prints the physical path of absolute folder $2, given as option $1.
physical_folder() {
	case $2 in
		*[[:cntrl:]]*) gw_refuse "$1 holds a control character; expected a plain path" ;;
		/*) ;;
		*) gw_refuse "$1 $(gw_printable "$2") is not absolute" ;;
	esac
	(cd -P -- "$2" 2>/dev/null && pwd -P) || gw_refuse "$1 $(gw_printable "$2") is not a folder"
}

# Refuses relative path $2, given as option $1, unless it is plain.
check_relative() {
	case $2 in
		/* | *[[:cntrl:]]*) gw_refuse "$1 $(gw_printable "$2") is not a plain relative path" ;;
		*) ;;
	esac
}

from='' to='' folder='' subfolders=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--from | --to | --folder | --subfolder)
			[ $# -ge 2 ] && [ -n "$2" ] || gw_refuse "$1 needs a value"
			case $1 in
				--from) from=$2 ;;
				--to) to=$2 ;;
				--folder) check_relative "$1" "$2"; folder=$2 ;;
				--subfolder) check_relative "$1" "$2"; subfolders="${subfolders}$2
" ;;
				*) ;;
			esac
			shift 2 ;;
		*) gw_refuse "unknown argument $(gw_printable "$1"); try --help" ;;
	esac
done
for option in --from:"${from}" --to:"${to}" --folder:"${folder}" --subfolder:"${subfolders}"; do
	[ -n "${option#*:}" ] || gw_refuse "${option%%:*} needs a value"
done
from_root=$(physical_folder --from "${from}")
to_root=$(physical_folder --to "${to}")
copy_root=$(cd -P -- "${to_root}/${folder}" 2>/dev/null && pwd -P) || copy_root=''
case ${copy_root} in
	"${to_root}"/*) ;;
	*) gw_refuse "--folder $(gw_printable "${folder}") is not a folder inside --to" ;;
esac
command -v jq >/dev/null 2>&1 || gw_fail 'jq not found'
from_given=${from%"${from##*[!/]}"}
gw_make_work

changed=0
while IFS= read -r subfolder; do
	[ -z "${subfolder}" ] || repoint_subfolder "${folder}" "${subfolder}"
done <<SUBFOLDERS
${subfolders}
SUBFOLDERS
jq -nc --arg f "${folder}" --argjson n "${changed}" '{folder: $f, repointed: $n}'
gw_exit_on_problems 4
