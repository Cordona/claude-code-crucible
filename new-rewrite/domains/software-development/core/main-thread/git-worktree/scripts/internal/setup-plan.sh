#!/usr/bin/env sh
# Decides what a fresh tree gets from its checkout: the dependency folders
# of each technology found, as lib/worktree-setup.json lists them, and what
# the repository's .worktreeinclude lists. lib/worktree-setup.jq
# checks the data file and turns it into records; this script finds the
# paths, drops the skipped and nested ones, and marks the tracked ones.
# Reads only.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'USAGE'
usage: sh setup-plan.sh --from CHECKOUT --to TREE

Run by worktree-setup.sh; not for main to call.
Plans what to copy from CHECKOUT into TREE: each detected technology's
dependency folders, fixed paths and the paths .worktreeinclude lists.

Options:
  --from CHECKOUT  main checkout's top folder, absolute; not a linked worktree
  --to TREE        an existing work tree's top folder, absolute; not --from
Writes:    nothing
Stdout:    one JSON line {from, from_given, to, detected: [technology...],
           items: [{do, path, technology?}...],
           repoint: {technology: [subfolder...]}}; path is relative to
           CHECKOUT; do is copy, tracked (git-tracked, not copied) or bad
           (unprintable name, not copied)
Exit:
  0  planned; a stderr warning means some places were not searched
  2  refused, nothing changed; the reason is on stderr
  4  git or jq missing or failed
USAGE
}

gw_prog='setup-plan.sh'
readonly MODULE='worktree-setup'
readonly TAB='	'
. "$(dirname -- "$0")/../lib/git-worktree.sh"

# shellcheck disable=SC2016 # the programs are single-quoted on purpose: their $ signs are jq's
readonly CHECK_JQ='include "worktree-setup";
[try fromjson] as $parsed
| if ($parsed | length) == 0 then "the data file is not valid JSON; expected one JSON object", setup_include_problems($include)
else $parsed[0] | setup_problems($include)
end'
readonly DETECT_JQ='include "worktree-setup"; fromjson | setup_detect_names'
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PLAN_JQ='include "worktree-setup"; fromjson | setup_plan($present | split("\n"); $include)'

# Reads the plan, then find's output (one "./path" per line), and prints
# "<technology>\t<folder>" per found folder, or "bad\t<shown path>" for a path
# holding a control character (a newline in a name arrives as \001).
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are awk's
readonly CLASSIFY_AWK='
FNR == 1 { part++ }
part == 1 {
	if ($1 == "named" && !($3 in named)) named[$3] = $2
	if ($1 == "containing" && !($3 in containing)) containing[$3] = $2
	next
}
{
	path = substr($0, 3)
	if (path ~ /[[:cntrl:]]/) { gsub(/[[:cntrl:]]/, "?", path); print "bad\t" path; next }
	name = path
	sub(/.*\//, "", name)
	if (name in named) { print named[name] "\t" path; next }
	folder = path
	if ((name in containing) && sub(/\/[^\/]*$/, "", folder)) print containing[name] "\t" folder
}'

# Reads the tracked paths, the skipped folders, then the candidates
# ("<technology>\t<path>") and prints one decision per kept candidate:
# "tracked\t<path>", "copy\t<technology>\t<path>" or "bad\t<path>". A
# duplicate, a skipped path and a path inside another copied candidate are
# dropped; a folder holding a tracked file counts as tracked.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are awk's
readonly DECIDE_AWK='
function inside(path, set,    cut) {
	for (cut = length(path); cut > 0; cut--)
		if (substr(path, cut, 1) == "/" && (substr(path, 1, cut - 1) in set)) return 1
	return 0
}
FNR == 1 { part++ }
part == 1 {
	tracked[$0] = 1
	for (cut = length($0); cut > 0; cut--)
		if (substr($0, cut, 1) == "/") tracked[substr($0, 1, cut - 1)] = 1
	next
}
part == 2 { skipped[$0] = 1; next }
{ count++; owner[count] = $1; path[count] = substr($0, length($1) + 2) }
END {
	for (i = 1; i <= count; i++) {
		if (owner[i] == "bad") continue
		if (path[i] in seen) { drop[i] = 1; continue }
		seen[path[i]] = 1
		if ((path[i] in skipped) || inside(path[i], skipped)) drop[i] = 1
		else if (path[i] in tracked) refused[i] = 1
		else copying[path[i]] = 1
	}
	for (i = 1; i <= count; i++) {
		if (owner[i] == "bad") print "bad\t" path[i]
		else if (drop[i]) continue
		else if (refused[i]) print "tracked\t" path[i]
		else if (!inside(path[i], copying)) print "copy\t" owner[i] "\t" path[i]
	}
}'

check_inputs() {
	command -v git >/dev/null 2>&1 || gw_fail 'git not found; expected git 2.31+ on PATH'
	command -v jq >/dev/null 2>&1 || gw_fail 'jq not found; expected jq 1.6+ on PATH'
	top_folder --from "${from}"
	from_root=${found_top}
	[ -z "${from_root}" ] || check_main_checkout
	top_folder --to "${to}"
	to_root=${found_top}
	if [ -n "${from_root}" ] && [ -n "${to_root}" ] &&
		{ [ "${from_root}" = "${to_root}" ] || [ "${from_root}" -ef "${to_root}" ]; }; then
		shown_to=$(gw_printable "${to}")
		gw_add_problem "--to ${shown_to} is the same folder as --from; expected the worktree"
	fi
	include_file=/dev/null
	[ -z "${from_root}" ] || check_include_file
	check_data
}
# Sets found_top to the physical path of git work tree top folder $2
# (option $1), or to empty after adding a problem.
top_folder() {
	found_top=''
	shown_dir=$(gw_printable "$2")
	case $2 in
		*[[:cntrl:]]*) gw_add_problem "$1 ${shown_dir} holds a control character; expected a plain path" ;;
		/*)
			physical_dir=$(cd -P -- "$2" 2>/dev/null && pwd -P) || physical_dir=''
			git_top=''
			[ -z "${physical_dir}" ] || git_top=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null) || git_top=''
			if [ -z "${physical_dir}" ]; then
				gw_add_problem "$1 ${shown_dir} is not a folder; expected an existing folder"
			elif [ -z "${git_top}" ] || [ "${git_top}" != "${physical_dir}" ]; then
				gw_add_problem "$1 ${shown_dir} is not the top folder of a git work tree; expected one"
			else
				found_top=${physical_dir}
			fi
			;;
		*) gw_add_problem "$1 ${shown_dir} is not absolute; expected an absolute path" ;;
	esac
}
check_main_checkout() {
	git_dir=$(git -C "${from_root}" rev-parse --absolute-git-dir 2>/dev/null) || git_dir=''
	common_dir=$(git -C "${from_root}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=''
	if [ -z "${git_dir}" ] || [ "${git_dir}" != "${common_dir}" ]; then
		shown_from=$(gw_printable "${from}")
		gw_add_problem "--from ${shown_from} is a linked worktree; expected the main checkout"
		from_root=''
	fi
}
check_include_file() {
	[ -e "${from_root}/.worktreeinclude" ] || return 0
	if [ -f "${from_root}/.worktreeinclude" ] && [ -r "${from_root}/.worktreeinclude" ]; then
		include_file="${from_root}/.worktreeinclude"
	else
		gw_add_problem '--from/.worktreeinclude is not a readable file; expected a file of paths'
	fi
}
check_data() {
	shown_data=$(gw_printable "${data}")
	if [ ! -f "${data}" ] || [ ! -r "${data}" ]; then
		gw_add_problem "the data file ${shown_data} is not a readable file; expected the scripts' lib/${MODULE}.json"
		return 0
	fi
	jq -Rrs -L "${data_dir}" --rawfile include "${include_file}" "${CHECK_JQ}" <"${data}" >"${gw_work}/data-problems" ||
		gw_fail "jq failed; expected jq 1.6+ and the scripts' lib/${MODULE}.jq"
	while IFS= read -r problem; do
		gw_add_problem "${problem}"
	done <"${gw_work}/data-problems"
}
# Writes the plan to $plan_file.
make_plan() {
	present=''
	detect_names=$(jq -Rrs -L "${data_dir}" "${DETECT_JQ}" <"${data}") ||
		gw_fail 'jq failed listing the detect names; expected jq 1.6+'
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		if [ -e "${from_root}/${name}" ] || [ -L "${from_root}/${name}" ]; then
			present="${present}${name}
"
		fi
	done <<EOF
${detect_names}
EOF
	jq -Rrs -L "${data_dir}" --arg present "${present}" --rawfile include "${include_file}" "${PLAN_JQ}" \
		<"${data}" >"${plan_file}" || gw_fail 'jq failed building the plan; expected jq 1.6+'
}
# Prints the fields after the kind of every plan record of kind $1.
plan_records() {
	awk -F '\t' -v kind="$1" '$1 == kind { print substr($0, length(kind) + 2) }' "${plan_file}"
}
# Lists every candidate as "<technology>\t<path>" ("-" for a copy entry):
# the copy entries first, then the folders the search finds.
collect_candidates() {
	: >"${candidates_file}"
	plan_records copy >"${gw_work}/copy"
	while IFS="${TAB}" read -r kind pattern; do
		expand_pattern "${kind}" "${pattern}"
	done <"${gw_work}/copy"
	search_folders
}
# Appends "-\t<path>" for each path under --from matching pattern $2, one
# segment at a time; $1 "dir" keeps folders only. A folder walked through is
# a real folder, never a link, so a copy can't come from outside --from.
expand_pattern() {
	[ -n "$2" ] || return 0
	printf '.\n' >"${level_file}"
	remaining=$2
	while [ -n "${remaining}" ] && [ -s "${level_file}" ]; do
		segment=${remaining%%/*}
		case ${remaining} in
			*/*) remaining=${remaining#*/} ;;
			*) remaining='' ;;
		esac
		while IFS= read -r base; do
			match_segment "${base}" "${segment}"
		done <"${level_file}" >"${next_level_file}"
		mv -f "${next_level_file}" "${level_file}"
	done
	while IFS= read -r path; do
		[ "$1" != dir ] || [ -d "${from_root}/${path}" ] || continue
		printf -- '-\t%s\n' "${path}"
	done <"${level_file}" >>"${candidates_file}"
}
# Prints each entry of folder $1 (relative, "." the root) matching segment
# $2; an entry whose name holds a control character becomes a bad candidate.
match_segment() {
	if [ "$1" = . ]; then
		folder=${from_root} prefix=''
	else
		folder="${from_root}/$1" prefix="$1/"
		[ -d "${folder}" ] && [ ! -L "${folder}" ] || return 0
	fi
	case $2 in
		*\**) ;;
		*)
			[ ! -e "${folder}/$2" ] && [ ! -L "${folder}/$2" ] || printf '%s%s\n' "${prefix}" "$2"
			return 0
			;;
	esac
	for entry in "${folder}"/* "${folder}"/.[!.]* "${folder}"/..?*; do
		[ -e "${entry}" ] || [ -L "${entry}" ] || continue
		name=${entry##*/}
		[ "${name}" != .git ] || continue
		# shellcheck disable=SC2254 # $2 is unquoted on purpose: its * is the pattern
		case ${name} in
			*[[:cntrl:]]*)
				shown_name=$(gw_printable "${prefix}${name}")
				printf 'bad\t%s\n' "${shown_name}" >>"${candidates_file}"
				;;
			$2) printf '%s%s\n' "${prefix}" "${name}" ;;
			*) ;;
		esac
	done
}
# One find over --from for every named folder and every folder holding a
# named file; .git, the skip folders and --to are pruned, and so is a found
# folder, so a node_modules is never walked.
search_folders() {
	plan_records named >"${gw_work}/named"
	plan_records containing >"${gw_work}/containing"
	[ -s "${gw_work}/named" ] || [ -s "${gw_work}/containing" ] || return 0
	set -- . '(' -name .git
	while IFS= read -r skip_pattern; do
		set -- "$@" -o -path "./${skip_pattern}"
	done <"${skip_patterns_file}"
	set -- "$@" ')' -prune
	for list in named containing; do
		[ -s "${gw_work}/${list}" ] || continue
		if [ "${list}" = named ]; then set -- "$@" -o -type d '('; else set -- "$@" -o -type f '('; fi
		first_name=yes
		while IFS="${TAB}" read -r _ name; do
			[ "${first_name}" = yes ] || set -- "$@" -o
			set -- "$@" -name "${name}"
			first_name=no
		done <"${gw_work}/${list}"
		set -- "$@" ')' -print0
		[ "${list}" != named ] || set -- "$@" -prune
	done
	if ! (cd -- "${from_root}" && find "$@") >"${gw_work}/found0" 2>"${gw_work}/find-errors"; then
		unread=$(wc -l <"${gw_work}/find-errors")
		warn "find could not read $((unread)) places under --from; folders inside them were not searched"
	fi
	tr '\n\000' '\001\n' <"${gw_work}/found0" | awk -F '\t' "${CLASSIFY_AWK}" "${plan_file}" - >>"${candidates_file}"
}
# The skip folders, plus --to when it lies inside --from; find gets them with
# glob characters escaped, as -path reads a pattern.
write_skip_files() {
	plan_records skip >"${skip_file}"
	case ${to_root} in
		"${from_root}"/*) printf '%s\n' "${to_root#"${from_root}"/}" >>"${skip_file}" ;;
		*) ;;
	esac
	sed 's/[][*?\\]/\\&/g' "${skip_file}" >"${skip_patterns_file}"
}
decide() {
	git -C "${from_root}" ls-files -z >"${gw_work}/tracked0" ||
		gw_fail 'git ls-files failed listing the tracked files of --from; expected a readable repository'
	tr '\n\000' '\001\n' <"${gw_work}/tracked0" >"${gw_work}/tracked"
	awk "${DECIDE_AWK}" "${gw_work}/tracked" "${skip_file}" "${candidates_file}" >"${decisions_file}"
}

warn() {
	printf '%s: %s\n' "${gw_prog}" "$1" >&2
}

# Prints the plan as JSON from the plan records and the decisions.
print_plan() {
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rnc --arg from "${from_root}" --arg from_given "${from_given}" --arg to "${to_root}" --rawfile plan "${plan_file}" '
		($plan | split("\n") | map(select(. != "") | split("\t"))) as $records
		| {from: $from, from_given: $from_given, to: $to,
		   detected: [$records[] | select(.[0] == "detected") | .[1]],
		   items: [inputs | split("\t")
			| if .[0] == "copy" then {do: "copy", path: (.[2:] | join("\t"))} + (if .[1] == "-" then {} else {technology: .[1]} end)
			else {do: .[0], path: (.[1:] | join("\t"))} end],
		   repoint: (reduce ($records[] | select(.[0] == "repoint")) as $r ({}; .[$r[1]] += [$r[2:] | join("\t")]))}' \
		"${decisions_file}" || gw_fail 'jq failed printing the plan; expected jq 1.6+'
}

from='' to=''
while [ $# -gt 0 ]; do
	case $1 in
		-h | --help) usage; exit 0 ;;
		--from | --to)
			[ $# -ge 2 ] && [ -n "$2" ] || gw_refuse "$1 needs a value"
			case $1 in --from) from=$2 ;; --to) to=$2 ;; *) ;; esac
			shift 2 ;;
		*) gw_refuse "unknown argument $(gw_printable "$1"); try --help" ;;
	esac
done
[ -n "${from}" ] || gw_refuse '--from needs a value: the main checkout'
[ -n "${to}" ] || gw_refuse '--to needs a value: the new tree'
data_dir="$(dirname -- "$0")/../lib"
data="${data_dir}/${MODULE}.json"
gw_make_work
plan_file="${gw_work}/plan"
skip_file="${gw_work}/skip"
skip_patterns_file="${gw_work}/skip-patterns"
candidates_file="${gw_work}/candidates"
decisions_file="${gw_work}/decisions"
level_file="${gw_work}/level"
next_level_file="${gw_work}/next-level"
check_inputs
gw_exit_on_problems 2
from_given=${from%"${from##*[!/]}"}
make_plan
write_skip_files
collect_candidates
decide
print_plan
