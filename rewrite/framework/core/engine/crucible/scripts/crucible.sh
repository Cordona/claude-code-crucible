#!/usr/bin/env sh
# Hands out paths in the effort folders of the durable Crucible space, finds
# items by ID or kind, opens them, expires an effort's cache and prunes
# efforts no file changed in for long.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='crucible.sh'
# Every kind is a folder of an effort folder; a nested kind is one folder per level.
readonly KIND_LIST='context dispatches baselines plans grills states reports/development reports/review cache/gates cache/denials'
readonly CACHE_KINDS='cache/gates cache/denials'
# A cache item is read in the session that wrote it; a week covers a session
# resumed days later. One fixed age until the hub has settings.
readonly CACHE_MAX_DAYS=7
# Bounds the --older-than value handed to find -mtime, far past any real age.
readonly MAX_PRUNE_DAYS_DIGITS=5
readonly RENDER_LIB='human-view'
# The C locale keeps the shell's patterns and sort byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

usage() {
	load_help_rules
	cat <<EOF
usage: crucible.sh new --kind KIND --effort FOLDER --label LABEL
       crucible.sh path ID
       crucible.sh find --effort FOLDER --kind KIND [--label LABEL]
       crucible.sh open ID [--editor CMD]
       crucible.sh prune --older-than Nd [--apply]
       crucible.sh root
       crucible.sh --help | -h

Hands out, finds, opens and prunes the files of the durable Crucible space.

The space: \${CRUCIBLE_HOME:-\$HOME/.crucible}, absolute, not / and not a
symbolic link. Nothing outside it is written or removed; folders made are
mode 700, files 600. A symbolic link for efforts/, an effort or a kind
folder: new and find refuse it, the rest skip it.

Layout: <root>/efforts/<effort>/<kind>/<ID>-<label>.<ext>
  ID      <YYYYMMDDTHHMMSS>-<hex>, hex 4 lowercase hex digits
  effort  named ${help_name_rule}
  kind    context, dispatches, baselines, plans, grills, states,
          reports/development, reports/review, cache/gates or cache/denials;
          the cache kinds expire after ${CACHE_MAX_DAYS} days
  ext     json

Options:
  --kind KIND         new, find: a kind of the layout
  --effort FOLDER     new, find: an existing effort folder directly in
                      <root>/efforts/, absolute (trailing slashes allowed)
  --label LABEL       new: the item's label; find: only items with it.
                      ${help_label_rule}
  ID                  path, open (before its options): a full ID or its
                      4 hex digits
  --editor CMD        open: run by sh with the file as last argument, instead
                      of open (macOS) or xdg-open (Linux), and waited for: it
                      must hand the file to a GUI app and return (code, idea;
                      never 'code -w' or a terminal editor)
  --older-than Nd     prune: the age N, in whole days
  --apply             prune: remove them; without it, nothing changes

Commands:
  new    creates an empty file in --effort's KIND folder (made if missing),
         never overwriting, with an ID no other item of the effort holds;
         stdout: its absolute path. Also expires the effort's cache.
  path   stdout: the absolute path of the item with ID.
  find   stdout: the absolute path of each KIND item (with --label, of that
         label) in --effort's folder, one per line, newest first; nothing
         when there is none (KIND folder missing included); a KIND folder
         it cannot read exits 4. Read-only.
  open   opens the item's own file. stdout: one line, "🟢 **Opened:** <its
         absolute path>".
  prune  lists effort folders unchanged for N days, or with --apply removes
         them, never one modified in the last 24 hours or not fully
         readable; touches nothing else and follows no symbolic link.
         stdout: a line per folder, then a summary line.
  root   stdout: the space root, checked, not created. Takes no argument.

Exit codes:
  0  done; go on
  1  path, open: no single item has the ID; report it with stderr
  2  usage error; show stderr
  4  space fault; show stderr
  5  install fault; show stderr
  129, 130, 143  stopped by HUP, INT or TERM; show stderr

Dependencies:
  POSIX sh; lib/crucible-space.sh beside this script
  cat, date, find, mkdir, od, rm, sort, uname, /dev/urandom (every
    macOS and Linux base system)
  open: jq 1.6+ (macOS: brew install jq; Linux: the distro's jq); the
    ${RENDER_LIB} skill's view.jq in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills;
    without --editor, open (macOS) or xdg-open (Linux)
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

not_found() {
	warn "$1"
	exit 1
}

space_fault() {
	warn "space: $1"
	exit 4
}

install_fault() {
	warn "install: $1"
	exit 5
}

main() {
	[ "$#" -gt 0 ] || {
		usage >&2
		exit 2
	}
	command=$1
	shift
	case ${command} in
		--help | -h)
			usage
			exit 0
			;;
		new | path | find | open | prune | root) ;;
		*) usage_error "unknown command: ${command}; expected new, path, find, open, prune, root or --help" ;;
	esac
	load_space_lib
	resolve_root
	case ${command} in
		new) run_new "$@" ;;
		path) run_path "$@" ;;
		find) run_find "$@" ;;
		open) run_open "$@" ;;
		prune) run_prune "$@" ;;
		*) run_root "$@" ;;
	esac
}

# Sources the space rules from lib/ beside this script, or exits 5.
load_space_lib() {
	# shellcheck disable=SC2310 # its status says whether the rules were found; the fault is named here
	source_space_lib || install_fault "space rules missing; expected ${space_lib}; try reinstalling the crucible skill"
}

# Sources lib/crucible-space.sh beside this script; fails, space_lib naming
# where it was looked for, when it is not a readable file.
source_space_lib() {
	case $0 in
		*/*) space_lib="${0%/*}/lib/crucible-space.sh" ;;
		*) space_lib='./lib/crucible-space.sh' ;;
	esac
	[ -f "${space_lib}" ] && [ -r "${space_lib}" ] || return 1
	# shellcheck source=lib/crucible-space.sh
	. "${space_lib}"
}

# Sets the rule texts the help prints from the space rules; when they are
# missing, --help still prints, naming where the rule lives instead.
load_help_rules() {
	help_name_rule='<YYYYMMDDTHHMMSS>-<4 lowercase hex>-<NAME>, NAME as lib/crucible-space.sh (missing) sets it'
	help_label_rule='as lib/crucible-space.sh (missing) sets it'
	# shellcheck disable=SC2310 # its status picks the fallback texts above; errexit adds nothing
	source_space_lib || return 0
	help_name_rule=${crucible_effort_name_rule}
	help_label_rule=${crucible_label_rule}
}

# Sets root from the space rules, or exits 2 or 4 with their problem.
resolve_root() {
	# shellcheck disable=SC2310 # its status says whether the root is usable; the fault is read below
	if ! crucible_resolve_root; then
		[ "${crucible_root_fault}" != usage ] || usage_error "${crucible_root_problem}"
		space_fault "${crucible_root_problem}"
	fi
	root=${crucible_root}
}

check_jq() {
	command -v jq >/dev/null 2>&1 || install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || install_fault 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) install_fault "jq is ${jq_version}; expected jq 1.6+; try upgrading jq" ;;
	esac
}

# Option values arrive as the next argument; a missing one is a usage error.
require_value() {
	[ "$2" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
}

run_root() {
	[ "$#" -eq 0 ] || usage_error "root takes no argument, not $1; expected crucible.sh root"
	printf '%s\n' "${root}"
}

run_new() {
	kind='' label='' effort=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--kind | --label | --effort) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for new: $1; expected --kind, --effort or --label" ;;
		esac
		case $1 in
			--kind) kind=$2 ;;
			--label) label=$2 ;;
			*) effort=$2 ;;
		esac
		shift 2
	done
	check_kind
	check_label
	check_effort
	create_item
	expire_cache
	printf '%s\n' "${item_file}"
}

check_kind() {
	set_kinds_text
	[ -n "${kind}" ] || usage_error "--kind missing; expected one of ${kinds_text}"
	for known_kind in ${KIND_LIST}; do
		[ "${kind}" != "${known_kind}" ] || return 0
	done
	usage_error "unknown kind: ${kind}; expected one of ${kinds_text}"
}

# Sets kinds_text to KIND_LIST as text: "a, b or c".
set_kinds_text() {
	kinds_text=''
	for known_kind in ${KIND_LIST}; do
		kinds_text="${kinds_text:+${kinds_text}, }${known_kind}"
	done
	kinds_text="${kinds_text%, *} or ${kinds_text##*, }"
}

check_label() {
	[ -n "${label}" ] || usage_error "--label missing; expected --label LABEL, ${crucible_label_rule}"
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_is_label "${label}" || usage_error "${crucible_label_refusal}"
}

# Sets effort to FOLDER without trailing slashes once it names a real effort
# folder of the space; exits 2 when FOLDER itself breaks the rule, 4 when the
# folder or efforts/ is missing or a symbolic link. The effort folder is
# effort.sh's to create, so it must already be there.
check_effort() {
	[ -n "${effort}" ] || usage_error "--effort missing; expected --effort FOLDER, an effort folder in ${root}/efforts/"
	# shellcheck disable=SC2310 # its status says whether the folder passed; the fault is read below
	if ! crucible_check_effort_folder "${effort}"; then
		[ "${crucible_effort_fault}" = space ] || usage_error "${crucible_effort_refusal}"
		space_fault "${crucible_effort_refusal}"
	fi
	effort=${crucible_effort}
}

# Sets item_file to a new empty file in effort/kind/.
create_item() {
	kind_dir="${effort}/${kind}"
	case ${kind} in
		*/*) ensure_dir "${effort}/${kind%%/*}" ;;
		*) ;;
	esac
	ensure_dir "${kind_dir}"
	claim_item_file
	item_file="${kind_dir}/${name}"
}

# Creates one folder of the layout; an existing folder is reused unless it is a symlink.
ensure_dir() {
	[ ! -L "$1" ] || space_fault "$1 is a symbolic link; expected a real folder inside the space"
	mkdir "$1" 2>/dev/null || [ -d "$1" ] || space_fault "cannot create $1; expected a writable folder"
	[ ! -L "$1" ] || space_fault "$1 is a symbolic link; expected a real folder inside the space"
}

# Sets name for a file created in kind_dir whose ID no other item of the
# effort holds; exits 5 when no ID can be minted, 4 when no file can be made.
claim_item_file() {
	# shellcheck disable=SC2310 # its status says whether a file was made; the fault is read below
	if crucible_claim_item_file "${kind_dir}" "${label}" id_is_unique; then
		name=${crucible_claimed_file##*/}
		return 0
	fi
	[ "${crucible_claim_fault}" != id ] || install_fault "${crucible_claim_problem}"
	space_fault "${crucible_claim_problem}"
}

# True when the file just created is the only one with this ID in any kind
# folder of the effort, one or two levels down. Each caller counts after its
# own create, so of two racing for one ID at most one sees itself alone.
id_is_unique() {
	holders=0
	for holder in "${effort}"/*/"$1"-* "${effort}"/*/*/"$1"-*; do
		[ -e "${holder}" ] || [ -L "${holder}" ] || continue
		holders=$((holders + 1))
	done
	[ "${holders}" -eq 1 ]
}

# Removes the regular files directly in the effort's cache kind folders last
# modified CACHE_MAX_DAYS or more days ago. find -mtime +N counts whole days
# of age, so +(days - 1) is an age of at least that many days. Each folder is
# entered with cd -P and checked to be the effort's own, so a folder swapped
# for a link is never cleaned; find never follows a link or enters a folder.
expire_cache() {
	physical_effort=$(cd -P "${effort}" 2>/dev/null && pwd -P) || {
		warn "cache not expired: cannot enter ${effort}"
		return 0
	}
	for cache_kind in ${CACHE_KINDS}; do
		cache_dir="${effort}/${cache_kind}"
		[ ! -L "${effort}/cache" ] && [ ! -L "${cache_dir}" ] && [ -d "${cache_dir}" ] || continue
		(
			cd -P "${cache_dir}" 2>/dev/null || exit 1
			entered=$(pwd -P) || exit 1
			[ "${entered}" = "${physical_effort}/${cache_kind}" ] || exit 1
			find . ! -name . -prune -type f -mtime "+$((CACHE_MAX_DAYS - 1))" -exec rm -f -- {} +
		) || warn "cache not fully expired in ${cache_dir}; expected its old files removed; the next new tries again"
	done
}

run_path() {
	[ "$#" -eq 1 ] || usage_error 'path takes exactly one ID; expected crucible.sh path ID'
	find_item "$1"
	printf '%s\n' "${item_path}"
}

run_open() {
	[ "$#" -gt 0 ] || usage_error 'open needs an ID; expected crucible.sh open ID [--editor CMD]'
	case $1 in
		-*) usage_error "open needs an ID first, before $1; expected crucible.sh open ID [--editor CMD]" ;;
		*) ;;
	esac
	wanted_id=$1
	shift
	editor=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--editor)
				require_value "$1" "$#"
				editor=$2
				shift 2
				;;
			*) usage_error "unknown argument for open: $1; expected --editor CMD" ;;
		esac
	done
	find_item "${wanted_id}"
	check_jq
	opened_line=$(render_opened_line)
	open_in_editor
	printf '%s\n' "${opened_line}"
}

run_find() {
	kind='' label='' effort=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--kind | --label | --effort) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for find: $1; expected --effort, --kind or --label" ;;
		esac
		case $1 in
			--kind) kind=$2 ;;
			--label) label=$2 ;;
			*) effort=$2 ;;
		esac
		shift 2
	done
	check_kind
	[ -z "${label}" ] || check_label
	check_effort
	kind_dir="${effort}/${kind}"
	[ ! -L "${effort}/${kind%%/*}" ] && [ ! -L "${kind_dir}" ] ||
		space_fault "${kind_dir} or a folder above it in the effort is a symbolic link; expected real folders"
	[ -d "${kind_dir}" ] || return 0
	# An unreadable folder globs to nothing, which would read as no items.
	[ -r "${kind_dir}" ] && [ -x "${kind_dir}" ] ||
		space_fault "cannot read ${kind_dir}; expected a readable folder; try checking its permissions"
	found_names=''
	for found_item in "${kind_dir}"/*; do
		[ -f "${found_item}" ] && [ ! -L "${found_item}" ] || continue
		# shellcheck disable=SC2310 # its status says whether the name is an item's
		parse_item_name "${found_item##*/}" || continue
		[ -z "${label}" ] || [ "${parsed_label}" = "${label}" ] || continue
		found_names="${found_names}${found_item##*/}
"
	done
	[ -n "${found_names}" ] || return 0
	# Item names lead with their ID and hold no newline, so a byte-order sort,
	# reversed, is newest first.
	sorted_names=$(printf '%s' "${found_names}" | sort -r) || install_fault 'sort failed; expected a POSIX sort'
	while IFS= read -r found_name; do
		printf '%s/%s\n' "${kind_dir}" "${found_name}"
	done <<EOF
${sorted_names}
EOF
}

# Sets parsed_id and parsed_label when file name $1 is an item name, as
# crucible_name_item names one; fails otherwise.
parse_item_name() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_split_id "$1" || return 1
	parsed_id=${crucible_name_id}
	parsed_label=${crucible_name_rest%".${crucible_item_extension}"}
	[ "${parsed_label}" != "${crucible_name_rest}" ] || return 1
	crucible_is_label "${parsed_label}"
}

# Sets item_id and item_path for the one item an ID names.
find_item() {
	# shellcheck disable=SC2310 # pure tests; their status is the answer
	crucible_is_id "$1" || crucible_is_id_hex "$1" ||
		usage_error "bad ID: $1; expected <YYYYMMDDTHHMMSS>-<hex> or the 4 lowercase hex digits"
	collect_matches "$1"
	[ "${match_count}" -gt 0 ] || not_found "no item with ID $1 in ${root}/efforts"
	if [ "${match_count}" -gt 1 ]; then
		warn "ID $1 is shared by ${match_count} items; expected a unique ID; use the full one:"
		printf '%s' "${matches}" >&2
		exit 1
	fi
}

# Sets matches to one "<id> <path>" line per item whose ID is $1 (a full ID
# or its 4 hex), match_count to their number, and the item_* values of the
# last one. Skips anything under a symbolic link.
collect_matches() {
	matches='' match_count=0
	efforts_dir="${root}/efforts"
	[ -d "${efforts_dir}" ] && [ ! -L "${efforts_dir}" ] || return 0
	for effort_dir in "${efforts_dir}"/*; do
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		crucible_is_effort_name "${effort_dir##*/}" || continue
		[ -d "${effort_dir}" ] && [ ! -L "${effort_dir}" ] || continue
		for kind in ${KIND_LIST}; do
			match_in_kind "${effort_dir}" "$1"
		done
	done
}

# Adds the items of kind folder kind of effort folder $1 whose ID, or the
# ID's hex, is $2.
match_in_kind() {
	kind_dir="$1/${kind}"
	[ ! -L "$1/${kind%%/*}" ] && [ ! -L "${kind_dir}" ] && [ -d "${kind_dir}" ] || return 0
	wanted=$2
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	if crucible_is_id_hex "${wanted}"; then
		set -- "${kind_dir}"/*-"${wanted}"-*
	else
		set -- "${kind_dir}/${wanted}"-*
	fi
	for candidate do
		[ -f "${candidate}" ] && [ ! -L "${candidate}" ] || continue
		# shellcheck disable=SC2310 # its status says whether the name is an item's
		parse_item_name "${candidate##*/}" || continue
		[ "${parsed_id}" = "${wanted}" ] || [ "${parsed_id##*-}" = "${wanted}" ] || continue
		item_id=${parsed_id} item_path=${candidate}
		matches="${matches}${item_id} ${item_path}
"
		match_count=$((match_count + 1))
	done
}

# Prints the line open reports, built from human-view's layout module; exits 5
# when the module is missing or jq fails on it.
render_opened_line() {
	render_lib_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${RENDER_LIB}"
	[ -f "${render_lib_dir}/view.jq" ] && [ -r "${render_lib_dir}/view.jq" ] ||
		install_fault "layout module missing; expected ${render_lib_dir}/view.jq; install the ${RENDER_LIB} skill"
	# shellcheck disable=SC2016 # the $ signs are jq's
	jq -nr -L "${render_lib_dir}" --arg path "${item_path}" \
		'include "view"; "\("done" | traffic_light) **Opened:** \($path | path_text)"' </dev/null ||
		install_fault "jq failed on ${render_lib_dir}/view.jq; expected jq 1.6+ and the ${RENDER_LIB} skill's module; try reinstalling it"
}

open_in_editor() {
	if [ -n "${editor}" ]; then
		# The editor string is the human's own choice, split by sh as git does;
		# the file path reaches it only as a separate argument.
		sh -c "${editor} \"\$@\"" "${editor}" "${item_path}" >&2 ||
			install_fault "the editor '${editor}' failed on ${item_path}; expected it to open the file"
		return 0
	fi
	os=$(uname -s) || install_fault 'uname failed; expected the OS name to pick an opener'
	if [ "${os}" = Darwin ]; then
		opener=open
	else
		opener=xdg-open
	fi
	command -v "${opener}" >/dev/null 2>&1 ||
		install_fault "${opener} missing; expected it on PATH, or --editor CMD"
	"${opener}" "${item_path}" >&2 ||
		install_fault "${opener} failed on ${item_path}; expected it to open the file"
}

run_prune() {
	days='' apply=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--older-than)
				require_value "$1" "$#"
				days=$2
				shift 2
				;;
			--apply)
				apply=true
				shift
				;;
			*) usage_error "unknown argument for prune: $1; expected --older-than Nd or --apply" ;;
		esac
	done
	check_days
	command -v find >/dev/null 2>&1 || install_fault 'find missing; expected find on PATH to see recent files'
	removed=0 kept=0
	efforts_dir="${root}/efforts"
	if [ -d "${efforts_dir}" ] && [ ! -L "${efforts_dir}" ]; then
		for effort_dir in "${efforts_dir}"/*; do
			# shellcheck disable=SC2310 # a pure test; its status is the answer
			crucible_is_effort_name "${effort_dir##*/}" || continue
			[ -d "${effort_dir}" ] && [ ! -L "${effort_dir}" ] || continue
			prune_effort "${effort_dir}"
		done
	fi
	report_prune
}

check_days() {
	count=${days%d}
	case ${days} in
		'') usage_error '--older-than missing; expected --older-than Nd, N a whole number of days' ;;
		*d) ;;
		*) usage_error "bad --older-than: ${days}; expected Nd, e.g. 30d" ;;
	esac
	case ${count} in
		'' | *[!0123456789]*) usage_error "bad --older-than: ${days}; expected Nd, N a whole number of days" ;;
		*) ;;
	esac
	[ "${#count}" -le "${MAX_PRUNE_DAYS_DIGITS}" ] ||
		usage_error "bad --older-than: ${days}; expected at most ${MAX_PRUNE_DAYS_DIGITS} digits"
	# A leading zero would read as octal in the shell's arithmetic.
	while [ "${count}" != "${count#0}" ] && [ "${#count}" -gt 1 ]; do count=${count#0}; done
}

# Lists, keeps or removes effort folder $1 by the age of the newest thing in it.
# A session may still write to an effort, so one touched in the last 24 hours
# stays whatever N is.
prune_effort() {
	# shellcheck disable=SC2310 # its status is the answer; a failure to read keeps the folder
	recent_in "$1" "${count}" || {
		print_kept "$1" 'find cannot read all of it'
		return 0
	}
	[ -z "${recent}" ] || return 0
	# shellcheck disable=SC2310 # its status is the answer; a failure to read keeps the folder
	recent_in "$1" 1 || {
		print_kept "$1" 'find cannot read all of it'
		return 0
	}
	if [ -n "${recent}" ]; then
		print_kept "$1" 'something in it was modified in the last 24 hours'
		return 0
	fi
	if [ "${apply}" = false ]; then
		printf 'would remove %s\n' "$1"
	else
		rm -rf "$1" || space_fault "cannot remove $1; expected a writable folder"
		printf 'removed %s\n' "$1"
	fi
	removed=$((removed + 1))
}

# Sets recent to what in folder $1 (the folder included) was modified less
# than $2 days ago; fails when find cannot read all of it.
recent_in() {
	recent=$(find "$1" -mtime "-$2" -print 2>/dev/null)
}

print_kept() {
	printf 'kept %s (%s)\n' "$1" "$2"
	kept=$((kept + 1))
}

report_prune() {
	kept_note=''
	[ "${kept}" -eq 0 ] || kept_note=" (kept ${kept}, listed above)"
	if [ "${apply}" = true ]; then
		printf 'removed %s effort folders unchanged for %s days%s\n' "${removed}" "${count}" "${kept_note}"
	else
		printf 'would remove %s effort folders unchanged for %s days%s; nothing changed, add --apply to remove them\n' "${removed}" "${count}" "${kept_note}"
	fi
}

main "$@"
