#!/usr/bin/env sh
# Makes a fresh linked worktree usable: copies, copy-on-write, the untracked
# dependency folders and local config the main checkout already holds. What
# to copy lives in the data file; worktree-setup.jq checks it and turns it
# into a plan, and this script finds the paths, refuses tracked ones, never
# overwrites, and reads no copied file but the launchers it repoints.
set -eu
umask 077

readonly PROG='worktree-setup.sh'
readonly MODULE='worktree-setup'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
readonly TAB='	'
# The C locale keeps the shell, tr and awk byte-wise.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git read another repository.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

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

usage() {
	cat <<EOF
usage: sh ${PROG} --from DIR --to DIR [--data FILE]
       sh ${PROG} --help | -h

Copies, copy-on-write, the untracked dependency folders and local config of
a main checkout into a fresh linked worktree. Installs nothing; runs no
build; never copies a tracked file, overwrites, or reads a config file.

--from DIR   absolute path of the main checkout's top folder
--to DIR     absolute path of the worktree's top folder; not --from
--data FILE  the data file; default ${MODULE}.json beside ${PROG}

data file: a JSON object, no other fields:
  always        {copy, skip}: copied in every repo, and folders never
                searched or copied
  technologies  an array of {name, detect, copy, copy-every-dir-named,
                copy-every-dir-containing, repoint}; name and detect required
  detect                     root-relative paths, no glob; the technology
                             applies when one exists under --from
  copy                       root-relative paths; * matches within one segment
  copy-every-dir-named       every folder with this name, at any depth
  copy-every-dir-containing  every folder holding a file of this name
  repoint                    subfolders of each found folder whose text
                             launchers get the --from path of the folder
                             (matched without case) replaced by its --to path
--from/.worktreeinclude adds one copy entry per line that is not blank or a
# comment; a trailing / means a folder; ! and ** lines are refused.

The search skips .git, the skip folders and the inside of a found folder.
A folder holding any tracked file is not copied.

output: one stdout line per event
  detected <name>          a technology that applies
  method <cp -c|reflink|plain>
  copied <path>
  exists <path>            skipped: already in --to
  tracked <path>           skipped: tracked in --from
  repointed <n> <folder>   n launchers rewritten in the copy
  flag symlink <path> -> <target>  an absolute link into --from, kept as is

exit codes:
  0  done
  2  wrong command line: a missing, repeated or unknown option, or a missing value
  3  invalid input: --from, --to, the data file or .worktreeinclude; each
     problem is one stderr line (at most ${MAX_PROBLEMS})
  4  a copy or repoint failed, or git or jq is missing or failed; each problem
     is one stderr line (at most ${MAX_PROBLEMS}); remove the worktree
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

# Prints $1 with each control character as "?", so a path can't split a line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Problems go to a file, so a loop's subshell can add one too.
add_problem() {
	printf '%s: %s\n' "${PROG}" "$1" >>"${problems_file}"
}

# Prints the kept problems, the last line counting any beyond the cap, and
# exits with $1; returns when there is none.
exit_on_problems() {
	[ -s "${problems_file}" ] || return 0
	problem_count=$(($(wc -l <"${problems_file}")))
	if [ "${problem_count}" -le "${MAX_PROBLEMS}" ]; then
		cat "${problems_file}" >&2
	else
		head -n "$((MAX_PROBLEMS - 1))" "${problems_file}" >&2
		warn "$((problem_count - MAX_PROBLEMS + 1)) more problems not shown; expected none"
	fi
	exit "$1"
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 VALUE"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	from='' to='' data=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--from)
				take_value "$1" "${from}" "${2-}"
				from=${option_value}
				;;
			--to)
				take_value "$1" "${to}" "${2-}"
				to=${option_value}
				;;
			--data)
				take_value "$1" "${data}" "${2-}"
				data=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --from, --to, --data or --help"
				;;
		esac
		shift 2
	done
	[ -n "${from}" ] || usage_error '--from missing; expected --from DIR'
	[ -n "${to}" ] || usage_error '--to missing; expected --to DIR'
	[ -n "${data}" ] || data="${own_dir}/${MODULE}.json"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

check_inputs() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	top_folder --from "${from}"
	from_root=${found_top}
	[ -z "${from_root}" ] || check_main_checkout
	top_folder --to "${to}"
	to_root=${found_top}
	if [ -n "${from_root}" ] && [ -n "${to_root}" ] &&
		{ [ "${from_root}" = "${to_root}" ] || [ "${from_root}" -ef "${to_root}" ]; }; then
		shown_to=$(printable "${to}")
		add_problem "--to ${shown_to} is the same folder as --from; expected the worktree"
	fi
	include_file=/dev/null
	[ -z "${from_root}" ] || check_include_file
	check_data
}

# Sets found_top to the physical path of git work tree top folder $2
# (option $1), or to empty after adding a problem.
top_folder() {
	found_top=''
	shown_dir=$(printable "$2")
	case $2 in
		*[[:cntrl:]]*) add_problem "$1 ${shown_dir} holds a control character; expected a plain path" ;;
		/*)
			physical_dir=$(cd -P -- "$2" 2>/dev/null && pwd -P) || physical_dir=''
			git_top=''
			[ -z "${physical_dir}" ] || git_top=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null) || git_top=''
			if [ -z "${physical_dir}" ]; then
				add_problem "$1 ${shown_dir} is not a folder; expected an existing folder"
			elif [ -z "${git_top}" ] || [ "${git_top}" != "${physical_dir}" ]; then
				add_problem "$1 ${shown_dir} is not the top folder of a git work tree; expected one"
			else
				found_top=${physical_dir}
			fi
			;;
		*) add_problem "$1 ${shown_dir} is not absolute; expected an absolute path" ;;
	esac
}

check_main_checkout() {
	git_dir=$(git -C "${from_root}" rev-parse --absolute-git-dir 2>/dev/null) || git_dir=''
	common_dir=$(git -C "${from_root}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=''
	if [ -z "${git_dir}" ] || [ "${git_dir}" != "${common_dir}" ]; then
		shown_from=$(printable "${from}")
		add_problem "--from ${shown_from} is a linked worktree; expected the main checkout"
		from_root=''
	fi
}

check_include_file() {
	[ -e "${from_root}/.worktreeinclude" ] || return 0
	if [ -f "${from_root}/.worktreeinclude" ] && [ -r "${from_root}/.worktreeinclude" ]; then
		include_file="${from_root}/.worktreeinclude"
	else
		add_problem '--from/.worktreeinclude is not a readable file; expected a file of paths'
	fi
}

check_data() {
	shown_data=$(printable "${data}")
	if [ ! -f "${data}" ] || [ ! -r "${data}" ]; then
		add_problem "--data ${shown_data} is not a readable file; expected the data JSON file"
		return 0
	fi
	jq -Rrs -L "${own_dir}" --rawfile include "${include_file}" "${CHECK_JQ}" <"${data}" >"${work_dir}/data-problems" ||
		die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}"
	while IFS= read -r problem; do
		add_problem "${problem}"
	done <"${work_dir}/data-problems"
}

# Writes the plan to $plan_file and prints a detected line per technology.
make_plan() {
	present=''
	detect_names=$(jq -Rrs -L "${own_dir}" "${DETECT_JQ}" <"${data}") ||
		die 4 'jq failed listing the detect names; expected jq 1.6+'
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		if [ -e "${from_root}/${name}" ] || [ -L "${from_root}/${name}" ]; then
			present="${present}${name}
"
		fi
	done <<EOF
${detect_names}
EOF
	jq -Rrs -L "${own_dir}" --arg present "${present}" --rawfile include "${include_file}" "${PLAN_JQ}" \
		<"${data}" >"${plan_file}" || die 4 'jq failed building the plan; expected jq 1.6+'
	plan_records detected | while IFS= read -r name; do
		printf 'detected %s\n' "${name}"
	done
}

# Prints the fields after the kind of every plan record of kind $1.
plan_records() {
	awk -F '\t' -v kind="$1" '$1 == kind { print substr($0, length(kind) + 2) }' "${plan_file}"
}

choose_method() {
	probe="${work_dir}/probe"
	: >"${probe}"
	system=$(uname -s)
	if [ "${system}" = Darwin ] && cp -c -- "${probe}" "${probe}.clone" 2>/dev/null; then
		method='cp -c'
	elif cp --reflink=auto -- "${probe}" "${probe}.reflink" 2>/dev/null; then
		method=reflink
	else
		method=plain
	fi
	printf 'method %s\n' "${method}"
}

# Lists every candidate as "<technology>\t<path>" ("-" for a copy entry):
# the copy entries first, then the folders the search finds.
collect_candidates() {
	: >"${candidates_file}"
	plan_records copy >"${work_dir}/copy"
	while IFS="${TAB}" read -r kind pattern; do
		expand_pattern "${kind}" "${pattern}"
	done <"${work_dir}/copy"
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

# Prints each entry of folder $1 (relative, "." the root) matching segment $2.
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
				shown_name=$(printable "${prefix}${name}")
				add_problem "${shown_name} was not copied: its name holds a control character; expected printable names"
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
	plan_records named >"${work_dir}/named"
	plan_records containing >"${work_dir}/containing"
	[ -s "${work_dir}/named" ] || [ -s "${work_dir}/containing" ] || return 0
	set -- . '(' -name .git
	while IFS= read -r skip_pattern; do
		set -- "$@" -o -path "./${skip_pattern}"
	done <"${skip_patterns_file}"
	set -- "$@" ')' -prune
	for list in named containing; do
		[ -s "${work_dir}/${list}" ] || continue
		if [ "${list}" = named ]; then set -- "$@" -o -type d '('; else set -- "$@" -o -type f '('; fi
		first_name=yes
		while IFS="${TAB}" read -r _ name; do
			[ "${first_name}" = yes ] || set -- "$@" -o
			set -- "$@" -name "${name}"
			first_name=no
		done <"${work_dir}/${list}"
		set -- "$@" ')' -print0
		[ "${list}" != named ] || set -- "$@" -prune
	done
	if ! (cd -- "${from_root}" && find "$@") >"${work_dir}/found0" 2>"${work_dir}/find-errors"; then
		unread=$(wc -l <"${work_dir}/find-errors")
		warn "find could not read $((unread)) places under --from; folders inside them were not searched"
	fi
	tr '\n\000' '\001\n' <"${work_dir}/found0" | awk -F '\t' "${CLASSIFY_AWK}" "${plan_file}" - >>"${candidates_file}"
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
	git -C "${from_root}" ls-files -z >"${work_dir}/tracked0" ||
		die 4 'git ls-files failed listing the tracked files of --from; expected a readable repository'
	tr '\n\000' '\001\n' <"${work_dir}/tracked0" >"${work_dir}/tracked"
	awk "${DECIDE_AWK}" "${work_dir}/tracked" "${skip_file}" "${candidates_file}" >"${decisions_file}"
}

apply_decisions() {
	while IFS="${TAB}" read -r decision first rest; do
		case ${decision} in
			tracked) printf 'tracked %s\n' "${first}" ;;
			copy) copy_item "${first}" "${rest}" ;;
			*) add_problem "${first} was not copied: its name holds a control character; expected printable names" ;;
		esac
	done <"${decisions_file}"
}

# Copies path $2 found for technology $1 ("-" for a copy entry), then flags
# its absolute links into --from and repoints its launchers.
copy_item() {
	check_parent "$2"
	if [ "${parent_inside_to}" = no ]; then
		add_problem "$2 was not copied: its folder in --to is not a folder inside --to; expected one"
		return 0
	fi
	target="${to_root}/$2"
	if [ -e "${target}" ] || [ -L "${target}" ]; then
		printf 'exists %s\n' "$2"
		return 0
	fi
	case $2 in
		*/*) mkdir -p -- "${to_root}/${2%/*}" || {
			add_problem "$2 was not copied: mkdir could not create its folder in --to; expected a writable --to"
			return 0
		} ;;
		*) ;;
	esac
	copy_path "${from_root}/$2" "${target}"
	if [ "${copy_failed}" = yes ]; then
		add_problem "$2 was not copied: cp (${method}) failed; expected a readable source and free space"
		return 0
	fi
	printf 'copied %s\n' "$2"
	flag_links "$2"
	[ "$1" = - ] || repoint_folder "$1" "$2"
}

# Sets parent_inside_to to yes when the nearest existing folder above path
# $1 in --to is physically inside --to, so a tracked link can't send a copy
# elsewhere; to no otherwise.
check_parent() {
	parent_inside_to=yes
	parent=$1
	while :; do
		case ${parent} in
			*/*) parent=${parent%/*} ;;
			*) return 0 ;;
		esac
		[ ! -e "${to_root}/${parent}" ] && [ ! -L "${to_root}/${parent}" ] || break
	done
	physical_parent=$(cd -P -- "${to_root}/${parent}" 2>/dev/null && pwd -P) || physical_parent=''
	case ${physical_parent} in
		"${to_root}" | "${to_root}"/*) ;;
		*) parent_inside_to=no ;;
	esac
}

# Copies keeping links as links (-P) and modes and times (-p), so build
# tools judging freshness by time see the copy as current; sets copy_failed.
copy_path() {
	copy_failed=no
	case ${method} in
		'cp -c') cp -c -R -P -p -- "$1" "$2" || copy_failed=yes ;;
		reflink) cp -R -P -p --reflink=auto -- "$1" "$2" || copy_failed=yes ;;
		*) cp -R -P -p -- "$1" "$2" || copy_failed=yes ;;
	esac
}

# Prints a flag line per absolute link inside copied path $1 pointing into --from.
flag_links() {
	find "${to_root}/$1" -type l -lname '/*' -print0 >"${work_dir}/links0" 2>/dev/null ||
		warn "find could not list every link in $1; some absolute links into --from may be unflagged"
	tr '\n\000' '\001\n' <"${work_dir}/links0" >"${work_dir}/links"
	while IFS= read -r link; do
		link_target=$(readlink -- "${link}" 2>/dev/null) || link_target=''
		# Matched without case, as macOS file systems do.
		lowered=$(printf '%s' "${link_target}" | tr '[:upper:]' '[:lower:]')
		case ${lowered} in
			"${from_root_lower}" | "${from_root_lower}"/* | "${from_given_lower}" | "${from_given_lower}"/*) ;;
			*) continue ;;
		esac
		shown_link=$(printable "${link#"${to_root}"/}")
		shown_target=$(printable "${link_target}")
		printf 'flag symlink %s -> %s\n' "${shown_link}" "${shown_target}"
	done <"${work_dir}/links"
}

# Rewrites the launchers of each repoint subfolder of folder $2 found for
# technology $1, in the copy only, and prints the count of files changed.
repoint_folder() {
	repoint_subfolders=$(plan_records repoint | awk -F '\t' -v owner="$1" '$1 == owner { print $2 }')
	[ -n "${repoint_subfolders}" ] || return 0
	changed=0
	while IFS= read -r subfolder; do
		repoint_subfolder "$2" "${subfolder}"
	done <<EOF
${repoint_subfolders}
EOF
	printf 'repointed %s %s\n' "${changed}" "$2"
}

repoint_subfolder() {
	copy_folder="${to_root}/$1/$2"
	[ -d "${copy_folder}" ] && [ ! -L "${copy_folder}" ] || return 0
	physical_folder=$(cd -P -- "${copy_folder}" 2>/dev/null && pwd -P) || physical_folder=''
	physical_copy=$(cd -P -- "${to_root}/$1" 2>/dev/null && pwd -P) || physical_copy=''
	case ${physical_folder} in
		"${physical_copy}"/*) ;;
		*)
			add_problem "$1/$2 was not repointed: it leads outside the copy; expected a folder inside it"
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
	shown_launcher=$(printable "${1#"${to_root}"/}")
	if [ "$1" -ef "$2" ]; then
		add_problem "${shown_launcher} was not repointed: it is the source file itself; expected a separate copy"
		return 0
	fi
	nul_bytes=$(tr -cd '\000' <"$1" | wc -c) || nul_bytes=1
	[ "${nul_bytes}" -eq 0 ] || return 0
	final_newline=no
	last_byte=$(tail -c 1 "$1")
	[ -n "${last_byte}" ] || final_newline=yes
	rewritten="${work_dir}/rewritten"
	rm -f "${rewritten}"
	if ! replaced=$(SOURCES="${from_root}/$3
${from_given}/$3" TARGET="${to_root}/$3" OUT="${rewritten}" FINAL_NEWLINE="${final_newline}" awk "${REPOINT_AWK}" "$1"); then
		add_problem "${shown_launcher} was not repointed: awk failed; expected a readable text file"
		return 0
	fi
	[ "${replaced}" -gt 0 ] || return 0
	if cat "${rewritten}" >"$1"; then
		changed=$((changed + 1))
	else
		add_problem "${shown_launcher} was not repointed: it could not be written; expected a writable copy"
	fi
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

own_dir=$(script_dir)
parse_args "$@"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-worktree-setup.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
problems_file="${work_dir}/problems"
plan_file="${work_dir}/plan"
skip_file="${work_dir}/skip"
skip_patterns_file="${work_dir}/skip-patterns"
candidates_file="${work_dir}/candidates"
decisions_file="${work_dir}/decisions"
level_file="${work_dir}/level"
next_level_file="${work_dir}/next-level"
check_inputs
exit_on_problems 3
from_given=${from%"${from##*[!/]}"}
from_root_lower=$(printf '%s' "${from_root}" | tr '[:upper:]' '[:lower:]')
from_given_lower=$(printf '%s' "${from_given}" | tr '[:upper:]' '[:lower:]')
make_plan
choose_method
write_skip_files
collect_candidates
decide
apply_decisions
exit_on_problems 4
