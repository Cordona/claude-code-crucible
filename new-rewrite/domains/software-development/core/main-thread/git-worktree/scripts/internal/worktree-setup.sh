#!/usr/bin/env sh
# Makes a fresh tree usable. First the plan, which reads only: it checks both
# folders, lib/worktree-setup.json and .worktreeinclude, refusing on any
# problem, then decides every item from the technologies the data file
# detects and the paths .worktreeinclude lists. Only a whole plan reaches the
# copy, which copies each item copy-on-write, repoints the launchers of each
# virtual env it copied, and prints one line per thing done.
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2310,SC2312 # each gw_ function exits on its own failure, and one in a condition is there for its status; a read inside a message only shortens the message
set -eu
umask 077

usage() {
	cat <<'EOF'
usage: sh worktree-setup.sh --from CHECKOUT --to TREE

Run by worktree-cut.sh; not for main to call.
Copies what git does not carry into a new tree: node_modules, vendor, Python
venvs, and what CHECKOUT/.worktreeinclude lists (root-relative paths, * within
one segment, a trailing / for a folder), but a listed .env, .env.*, auth.json,
.npmrc or local.properties only if git-ignored.

Options:
  --from CHECKOUT  main checkout's top folder, absolute; not a linked worktree
  --to TREE        the new tree's top folder, absolute
Requires:  TREE already added as a git worktree of CHECKOUT
Writes:    copies into TREE only, never overwriting, and points the copied
           venvs' bin/ launchers at TREE; CHECKOUT is untouched
Stdout:    one line per thing done (detected, method, copied, repointed, flag
           symlink, or skipped: exists|tracked|unignored), paths under TREE
Exit:
  0  done; a warning may be on stderr
  2  refused, nothing changed; the reason is on stderr
  4  git or jq missing or failed, or an item not copied or repointed: remove
     the tree
EOF
}

gw_prog='worktree-setup.sh'
readonly MODULE='worktree-setup'
readonly TAB='	'
# Bounds stderr so a list of problems stays readable.
readonly MAX_PROBLEMS=20
. "$(dirname -- "$0")/../lib/git-worktree.sh"

# shellcheck disable=SC2016 # the programs are single-quoted on purpose: their $ signs are jq's
readonly CHECK_JQ='include "worktree-setup";
[try fromjson] as $parsed
| if ($parsed | length) == 0 then "the data file is not valid JSON; expected one JSON object", setup_include_problems($worktree_include)
else $parsed[0] | setup_problems($worktree_include)
end'
readonly DETECT_JQ='include "worktree-setup"; fromjson | setup_detect_names'
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PLAN_JQ='include "worktree-setup"; fromjson | setup_plan($present | split("\n"); $worktree_include)'

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
# ("<technology>\t<path>") and prints one decision per kept candidate,
# "<decision>\t<technology>\t<path>": copy with the candidate's technology,
# tracked or bad with "-". A duplicate, a skipped path and a path inside
# another copied candidate are dropped; a folder holding a tracked file
# counts as tracked.
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
		if (owner[i] == "bad") print "bad\t-\t" path[i]
		else if (drop[i]) continue
		else if (refused[i]) print "tracked\t-\t" path[i]
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

usage_error() {
	printf '%s: %s\n' "${gw_prog}" "$1" >&2
	printf "Try 'sh %s --help'.\n" "${gw_prog}" >&2
	exit 2
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 VALUE"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	from='' to=''
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
			*)
				usage_error "unknown option: $(gw_printable "$1"); expected --from, --to or --help"
				;;
		esac
		shift 2
	done
	[ -n "${from}" ] || usage_error '--from missing; expected --from DIR'
	[ -n "${to}" ] || usage_error '--to missing; expected --to DIR'
}

# Adds problem $1 for the end, as this script reports every problem it finds
# before it stops.
add_problem() {
	printf '%s: %s\n' "${gw_prog}" "$1" >>"${gw_work}/problems"
}

# Prints the problems kept, at most MAX_PROBLEMS with a last line counting
# the rest, and exits with $1; returns when there is none.
exit_on_problems() {
	[ -s "${gw_work}/problems" ] || return 0
	problem_count=$(($(wc -l <"${gw_work}/problems")))
	if [ "${problem_count}" -le "${MAX_PROBLEMS}" ]; then
		cat "${gw_work}/problems" >&2
	else
		head -n "$((MAX_PROBLEMS - 1))" "${gw_work}/problems" >&2
		printf '%s: %s more problems not shown; expected none\n' "${gw_prog}" "$((problem_count - MAX_PROBLEMS + 1))" >&2
	fi
	exit "$1"
}

warn() {
	printf '%s: %s\n' "${gw_prog}" "$1" >&2
}

check_inputs() {
	top_folder --from "${from}"
	from_root=${found_top}
	[ -z "${from_root}" ] || check_main_checkout
	top_folder --to "${to}"
	to_root=${found_top}
	if [ -n "${from_root}" ] && [ -n "${to_root}" ] &&
		{ [ "${from_root}" = "${to_root}" ] || [ "${from_root}" -ef "${to_root}" ]; }; then
		shown_to=$(gw_printable "${to}")
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
	shown_dir=$(gw_printable "$2")
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
		shown_from=$(gw_printable "${from}")
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
	shown_data=$(gw_printable "${data}")
	if [ ! -f "${data}" ] || [ ! -r "${data}" ]; then
		add_problem "the data file ${shown_data} is not a readable file; expected the scripts' lib/${MODULE}.json"
		return 0
	fi
	jq -Rrs -L "${data_dir}" --rawfile worktree_include "${include_file}" "${CHECK_JQ}" <"${data}" >"${gw_work}/data-problems" ||
		gw_fail "jq failed; expected jq 1.6+ and the scripts' lib/${MODULE}.jq"
	while IFS= read -r problem; do
		add_problem "${problem}"
	done <"${gw_work}/data-problems"
}

# Writes the plan records to $plan_file.
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
	jq -Rrs -L "${data_dir}" --arg present "${present}" --rawfile worktree_include "${include_file}" "${PLAN_JQ}" \
		<"${data}" >"${plan_file}" || gw_fail 'jq failed building the plan; expected jq 1.6+'
}
# Prints the fields after the kind of every plan record of kind $1.
plan_records() {
	awk -F '\t' -v kind="$1" '$1 == kind { print substr($0, length(kind) + 2) }' "${plan_file}"
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
# Writes one decision per kept candidate to $decisions_file.
decide() {
	git -C "${from_root}" ls-files -z >"${gw_work}/tracked0" ||
		gw_fail 'git ls-files failed listing the tracked files of --from; expected a readable repository'
	tr '\n\000' '\001\n' <"${gw_work}/tracked0" >"${gw_work}/tracked"
	awk "${DECIDE_AWK}" "${gw_work}/tracked" "${skip_file}" "${candidates_file}" >"${decisions_file}"
}

# Carries out each decision, printing what it did; an item that fails is a
# problem, and the rest still go.
apply_decisions() {
	choose_method
	printf 'method %s\n' "${method}"
	while IFS="${TAB}" read -r decision technology path; do
		case ${decision} in
			tracked) printf 'tracked %s\n' "${path}" ;;
			bad) add_problem "${path} was not copied: its name holds a control character; expected printable names" ;;
			*)
				check_secret "${path}"
				if [ "${secret_unignored}" = yes ]; then
					printf 'unignored %s\n' "${path}"
				else
					copy_item "${technology}" "${path}"
				fi
				;;
		esac
	done <"${decisions_file}"
}
# Sets method to the fastest copy this system makes: a clone, a reflink, or
# a plain copy.
choose_method() {
	probe="${gw_work}/probe"
	: >"${probe}"
	system=$(uname -s)
	if [ "${system}" = Darwin ] && cp -c -- "${probe}" "${probe}.clone" 2>/dev/null; then
		method='cp -c'
	elif cp --reflink=auto -- "${probe}" "${probe}.reflink" 2>/dev/null; then
		method=reflink
	else
		method=plain
	fi
}
# Sets secret_unignored to yes when path $1 is secret-shaped and git does not
# confirm the tree ignores it: a commit of the tree stages every file git sees.
check_secret() {
	secret_unignored=no
	case ${1##*/} in
		.env | .env.* | auth.json | .npmrc | local.properties) ;;
		*) return 0 ;;
	esac
	git -C "${to_root}" check-ignore -q -- "$1" 2>/dev/null || secret_unignored=yes
}
# Copies path $2 found for technology $1 ("-" for none), repoints it when its
# technology names launcher subfolders, then flags its absolute links into
# the checkout.
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
	[ "$1" = - ] || repoint "$1" "$2"
	flag_links "$2"
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
# Repoints the launcher subfolders the plan names for technology $1 in copied
# folder $2, when there are any, and prints how many launchers changed.
repoint() {
	plan_records repoint | awk -F '\t' -v technology="$1" \
		'$1 == technology { print substr($0, length(technology) + 2) }' >"${gw_work}/subfolders"
	[ -s "${gw_work}/subfolders" ] || return 0
	changed=0
	while IFS= read -r subfolder; do
		repoint_subfolder "$2" "${subfolder}"
	done <"${gw_work}/subfolders"
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
		repoint_launcher "${launcher}" "$1"
	done
}
# Rewrites launcher $1 of copied folder $2 when it is text holding the
# folder's --from path; counts it in $changed.
repoint_launcher() {
	shown_launcher=$(gw_printable "${1#"${to_root}"/}")
	nul_bytes=$(tr -cd '\000' <"$1" | wc -c) || nul_bytes=1
	[ "${nul_bytes}" -eq 0 ] || return 0
	final_newline=no
	last_byte=$(tail -c 1 "$1")
	[ -n "${last_byte}" ] || final_newline=yes
	rewritten="${gw_work}/rewritten"
	rm -f "${rewritten}"
	if ! replaced=$(SOURCES="${from_root}/$2
${from_given}/$2" TARGET="${to_root}/$2" OUT="${rewritten}" FINAL_NEWLINE="${final_newline}" awk "${REPOINT_AWK}" "$1"); then
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
# Prints a flag line per absolute link inside copied path $1 pointing into
# the checkout.
flag_links() {
	find "${to_root}/$1" -type l -lname '/*' -print0 >"${gw_work}/links0" 2>/dev/null ||
		warn "find could not list every link in $1; some absolute links into --from may be unflagged"
	tr '\n\000' '\001\n' <"${gw_work}/links0" >"${gw_work}/links"
	while IFS= read -r link; do
		link_target=$(readlink -- "${link}" 2>/dev/null) || link_target=''
		# Matched without case, as macOS file systems do.
		lowered=$(printf '%s' "${link_target}" | tr '[:upper:]' '[:lower:]')
		case ${lowered} in
			"${from_root_lower}" | "${from_root_lower}"/* | "${from_given_lower}" | "${from_given_lower}"/*) ;;
			*) continue ;;
		esac
		printf 'flag symlink %s -> %s\n' "$(gw_printable "${link#"${to_root}"/}")" "$(gw_printable "${link_target}")"
	done <"${gw_work}/links"
}

parse_args "$@"
command -v git >/dev/null 2>&1 || gw_fail 'git not found; expected git 2.31+ on PATH'
command -v jq >/dev/null 2>&1 || gw_fail 'jq not found; expected jq 1.6+ on PATH'
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
exit_on_problems 2
from_given=${from%"${from##*[!/]}"}
from_root_lower=$(printf '%s' "${from_root}" | tr '[:upper:]' '[:lower:]')
from_given_lower=$(printf '%s' "${from_given}" | tr '[:upper:]' '[:lower:]')
make_plan
write_skip_files
collect_candidates
decide
plan_records detected | sed 's/^/detected /'

apply_decisions
exit_on_problems 4
