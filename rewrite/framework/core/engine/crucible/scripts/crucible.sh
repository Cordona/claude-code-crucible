#!/usr/bin/env sh
# Hands out paths in the effort folders of the durable Crucible space, finds
# items by ID or kind, renders and opens them, expires an effort's cache and
# prunes efforts no file changed in for long.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='crucible.sh'
# Every kind is a folder of an effort folder; a nested kind is one folder per level.
readonly KIND_LIST='context dispatches baselines reports/development reports/review cache/gates cache/prompts'
readonly CACHE_KINDS='cache/gates cache/prompts'
# A cache item is read in the session that wrote it; a week covers a session
# resumed days later. One fixed age until the hub has settings.
readonly CACHE_MAX_DAYS=7
# Bounds the --older-than value handed to find -mtime, far past any real age.
readonly MAX_PRUNE_DAYS_DIGITS=5
readonly REPORT_RENDERER='skills/standard-code-development-report/scripts/report.sh'
readonly RENDERED_REPORT_KIND='reports/development'
# The C locale keeps the shell's patterns and sort byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

usage() {
	load_help_rules
	cat <<EOF
usage: crucible.sh new --kind KIND --effort FOLDER --label LABEL
       crucible.sh path ID
       crucible.sh find --effort FOLDER --kind KIND [--label LABEL]
       crucible.sh open ID [--format md|html] [--editor CMD]
       crucible.sh prune --older-than Nd [--apply]
       crucible.sh root
       crucible.sh --help | -h

Hands out and finds the files of the durable Crucible space. Every file
lives in an effort folder: a context file, a dispatch, a dispatch baseline
(the repository's git status when the dispatch was sent), an agent report
and a gate record are one JSON file each, a prompt (the Markdown message the
main thread reads) one .md file.

The space: \${CRUCIBLE_HOME:-\$HOME/.crucible}, an absolute path, trailing
slashes dropped. Its rules (where it is, the effort folder name, the ID,
the item label and name) are lib/crucible-space.sh beside this script, which
the other Crucible scripts source too. A root that is a symbolic link is refused by every command but
--help (exit 4). efforts/, an effort folder and every kind folder level must
be real folders, not symbolic links: new and find refuse one (exit 4); path,
open and prune skip it. Nothing outside the root is written or removed,
except open's temp folder (below). Folders the script creates are mode 700,
files mode 600.

Layout (local time):
  <root>/efforts/<effort>/<kind>/<YYYYMMDDTHHMMSS>-<hex>-<label>.<ext>
  effort: the effort folder effort.sh start made,
    ${help_name_rule}
  kind, the folder under the effort (durable unless marked cache):
    context               the effort's context versions and their text files
    dispatches            agent dispatch files
    baselines             dispatch baselines
    reports/development   development reports
    reports/review        review reports
    cache/gates           gate records; expire after ${CACHE_MAX_DAYS} days
    cache/prompts         the main thread's prompts; expire after ${CACHE_MAX_DAYS} days
  hex: 4 random lowercase hex digits; ext: md for cache/prompts, json for
  every other kind. The ID of an item is <YYYYMMDDTHHMMSS>-<hex>.
Day folders (<root>/YYYY/MM/DD/) of earlier versions are no longer read,
written or removed.

Commands:
  new    creates an empty file (mode 600) for the caller to write in
         FOLDER/KIND/ and prints its absolute path. FOLDER: an absolute
         path (trailing slashes allowed) to an effort folder directly in
         <root>/efforts/; it must exist (new never creates it). KIND's
         folders are created when missing. LABEL: ${help_label_rule}.
         A repeated option keeps its last value. The file is created
         without overwriting (noclobber) and its ID is claimed across
         FOLDER's kind folders; a clash of either retries with a fresh ID,
         up to ${help_create_attempts} tries. The content is the caller's to
         write, as one JSON object in its writer's shape, or Markdown for
         cache/prompts.
         Every new also expires FOLDER's cache: it removes each regular
         file directly in FOLDER/cache/gates/ and FOLDER/cache/prompts/
         last modified ${CACHE_MAX_DAYS} or more days ago, never following a symbolic link
         and never entering a subfolder. An expiry that fails puts a note
         on stderr and new goes on.
  path   prints the absolute path of an item. ID: the full ID, or its 4 hex
         digits, searched in every kind folder of every effort folder. An
         item is a regular file, not a symbolic link, named as the layout
         sets; anything else is skipped. Several items with the ID is an
         error (stderr lists them): give the full ID.
  find   prints the absolute path of every item of KIND in FOLDER (FOLDER
         as new takes it) and, with --label, with that label, one per line,
         newest ID first; nothing when there is none (exit 0), FOLDER/KIND/
         missing included. Read-only.
  open   renders an item to a new temp folder in \${TMPDIR:-/tmp} (never
         inside the space: a TMPDIR inside the space is replaced by /tmp; the
         folder is left for the editor and not removed, unless open fails
         or is stopped, which removes it) and opens it. The ID
         comes first. A reports/development item is rendered by
         \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/standard-code-development-report/scripts/report.sh
         render --full when that script's --help names --full and the render
         succeeds. Anything else gets a title line "# <kind>: <label>", then:
         a prompt its Markdown as stored; JSON pretty-printed in a json
         fence; an empty file "Empty: nothing has been written to this
         item."; a file that is not valid JSON "Not valid JSON; the file as
         stored:" and the file in a text fence. It opens with the OS
         opener, open (macOS) or xdg-open (Linux), which hands the file to
         the desktop and never blocks; \$VISUAL and \$EDITOR are not consulted.
         --editor CMD opens it with CMD instead: CMD is run by sh with the
         file as its last argument, the way git runs \$EDITOR. CMD must hand
         the file to a GUI app and return (e.g. code, idea); never a terminal
         editor or a waiting form such as 'code -w': open waits for CMD to
         exit, so a CMD that waits for a terminal or for the file to close
         hangs a caller with no terminal, such as the Bash tool. The opener's or
         editor's output goes to stderr. Prints exactly one line: opened
         <file>. --format html is not available yet.
  prune  lists the effort folders in which nothing (the folder itself, a
         subfolder or a file) was modified in the last N days. Without
         --apply it prints "would remove <folder>" for each and changes
         nothing; with --apply it removes each whole effort folder and
         prints "removed <folder>". A session may still write to an effort,
         so one holding anything modified in the last 24 hours (or one find
         cannot fully read) is never removed, in either mode, and prints
         "kept <folder> (<reason>)". It closes with one line:
           would remove <N> effort folders unchanged for N days[ (kept <K>,
           listed above)]; nothing changed, add --apply to remove them
         or, with --apply:
           removed <N> effort folders unchanged for N days[ (kept <K>,
           listed above)]
         Only real folders directly in <root>/efforts/ named as an effort
         folder are ever touched; rm -rf never follows a symbolic link in
         them.
  root   prints the space root, resolved and checked as above, without
         creating it. Takes no argument.
  --help, -h
         prints this contract on stdout; any argument after it is ignored.

Exit codes:
  0  ok (prune: also when nothing is old enough)
  1  path or open: no item has that ID, or the ID's hex is shared by
     several items (stderr lists them)
  2  usage error: no command (this help is printed on stderr), unknown
     command or option, a missing option value, bad kind, bad label, a
     CRUCIBLE_HOME that is relative or /, a relative HOME when CRUCIBLE_HOME
     is unset or empty, a malformed ID or Nd, open with an option before
     the ID, --format html, root with an argument, new or find without
     --kind or --effort, or a FOLDER that is relative, not directly inside
     <root>/efforts/ or not named <id>-<name>. Its stderr is one
     "crucible.sh: <what failed>; expected <x>" line, then "Try
     'crucible.sh --help'."
  4  space fault, its stderr line starting "crucible.sh: space:": neither
     CRUCIBLE_HOME nor HOME set; the root a symbolic link; efforts/,
     FOLDER or a kind folder level missing (new, find: FOLDER and
     efforts/), not a folder or a symbolic link; a folder or the file new
     cannot create; new's ${help_create_attempts} tries all found the name or its ID taken;
     prune --apply unable to remove an effort folder; or open's mktemp -d
     failing in its temp base
  5  install fault, its stderr line starting "crucible.sh: install:": a
     dependency below missing or failing: lib/crucible-space.sh beside this
     script (every command but --help); date, od or the random source
     (new); jq (open); find (prune); uname, the opener or the editor
     (open). Each is checked when the command first needs it.

Dependencies: POSIX sh; lib/crucible-space.sh beside this script; cat, find,
mkdir, mktemp, od (with /dev/urandom), rm, sort and uname, in every macOS and
Linux base system; a date that knows +%Y%m%dT%H%M%S; jq 1.6+ only for open
(macOS: brew install jq; Linux: the distro's jq package); open (macOS) or
xdg-open (Linux) only for open without --editor.

Runtime: new about 0.03 s; path by full ID or hex and find about 0.01 s,
prune about 0.04 s, over 10 efforts; open with the JSON fallback render
about 0.03 s; root and --help about 0.01 s (mean wall time of 20 runs, sh
startup included; macOS 26.7 on an Apple M1 Max). path and prune grow with
the number of efforts; open adds the report renderer's and the opener's own
time.
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
	help_create_attempts='N (lib/crucible-space.sh, missing, sets it)'
	# shellcheck disable=SC2310 # its status picks the fallback texts above; errexit adds nothing
	source_space_lib || return 0
	help_name_rule=${crucible_effort_name_rule}
	help_label_rule=${crucible_label_rule}
	help_create_attempts=${crucible_max_create_attempts}
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
	if crucible_claim_item_file "${kind_dir}" "${label}" "${kind}" id_is_unique; then
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
	[ "$#" -gt 0 ] || usage_error 'open needs an ID; expected crucible.sh open ID [--format md|html] [--editor CMD]'
	case $1 in
		-*) usage_error "open needs an ID first, before $1; expected crucible.sh open ID [--format md|html] [--editor CMD]" ;;
		*) ;;
	esac
	wanted_id=$1
	shift
	format=md editor=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--format | --editor) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for open: $1; expected --format or --editor" ;;
		esac
		case $1 in
			--format) format=$2 ;;
			*) editor=$2 ;;
		esac
		shift 2
	done
	case ${format} in
		md) ;;
		html) usage_error 'html not available yet; expected --format md' ;;
		*) usage_error "unknown format: ${format}; expected md or html" ;;
	esac
	find_item "${wanted_id}"
	check_jq
	render_to_temp
	open_in_editor
	printf 'opened %s\n' "${rendered}"
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
	found_names=''
	for found_item in "${kind_dir}"/*; do
		[ -f "${found_item}" ] && [ ! -L "${found_item}" ] || continue
		# shellcheck disable=SC2310 # its status says whether the name is an item's
		parse_item_name "${found_item##*/}" "${kind}" || continue
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

# Sets parsed_id and parsed_label when file name $1 is an item name of kind
# $2, as crucible_name_item names one; fails otherwise.
parse_item_name() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_split_id "$1" || return 1
	crucible_kind_extension "$2"
	parsed_id=${crucible_name_id}
	parsed_label=${crucible_name_rest%".${crucible_extension}"}
	[ "${parsed_label}" != "${crucible_name_rest}" ] || return 1
	crucible_is_label "${parsed_label}"
}

# Sets item_id, item_path, item_kind and item_label for the one item an ID names.
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
		parse_item_name "${candidate##*/}" "${kind}" || continue
		[ "${parsed_id}" = "${wanted}" ] || [ "${parsed_id##*-}" = "${wanted}" ] || continue
		item_id=${parsed_id} item_path=${candidate} item_kind=${kind} item_label=${parsed_label}
		matches="${matches}${item_id} ${item_path}
"
		match_count=$((match_count + 1))
	done
}

# Writes the render of the found item to a new temp folder and sets rendered.
render_to_temp() {
	temp_base=${TMPDIR:-/tmp}
	temp_base=${temp_base%/}
	case ${temp_base} in
		"${root}" | "${root}"/*) temp_base=/tmp ;;
		*) ;;
	esac
	temp_dir=$(mktemp -d "${temp_base}/crucible-open.XXXXXX") ||
		space_fault "mktemp -d in ${temp_base} failed; expected a writable TMPDIR"
	trap remove_failed_render EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	rendered="${temp_dir}/${item_id}-${item_label}.md"
	# shellcheck disable=SC2310 # every step in it is checked; a failure falls back to the generic render
	if [ "${item_kind}" = "${RENDERED_REPORT_KIND}" ] && render_full_report >"${rendered}"; then return 0; fi
	render_generic >"${rendered}"
}

# Removes open's temp folder when open fails or is stopped; on success it is
# the editor's, so it stays.
# shellcheck disable=SC2329 # invoked by the EXIT trap
remove_failed_render() {
	exit_status=$?
	[ "${exit_status}" -eq 0 ] || rm -rf "${temp_dir}"
}

# Succeeds only when the report renderer supports --full and renders the item.
render_full_report() {
	renderer="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/${REPORT_RENDERER}"
	[ -f "${renderer}" ] || return 1
	sh "${renderer}" --help 2>/dev/null | grep -q -e '--full' || return 1
	sh "${renderer}" render --full --report "${item_path}" 2>/dev/null
}

render_generic() {
	printf '# %s: %s\n\n' "${item_kind}" "${item_label}"
	crucible_kind_extension "${item_kind}"
	if [ ! -s "${item_path}" ]; then
		printf 'Empty: nothing has been written to this item.\n'
	elif [ "${crucible_extension}" = md ]; then
		cat "${item_path}"
	elif jq -e . "${item_path}" >/dev/null 2>&1; then
		printf '```json\n'
		jq . "${item_path}"
		printf '```\n'
	else
		printf 'Not valid JSON; the file as stored:\n\n````text\n'
		cat "${item_path}"
		printf '\n````\n'
	fi
}

open_in_editor() {
	if [ -n "${editor}" ]; then
		# The editor string is the human's own choice, split by sh as git does;
		# the file path reaches it only as a separate argument.
		sh -c "${editor} \"\$@\"" "${editor}" "${rendered}" >&2 ||
			install_fault "the editor '${editor}' failed on ${rendered}; expected it to open the file"
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
	"${opener}" "${rendered}" >&2 ||
		install_fault "${opener} failed on ${rendered}; expected it to open the file"
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
