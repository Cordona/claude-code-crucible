#!/usr/bin/env sh
# Hands out paths and IDs in the effort folders of the durable Crucible space,
# finds drafts by ID, opens them and prunes efforts no file changed in for long.
# Its cards are human-view's show.sh's to print: views/opened.jq for open,
# views/prune.jq for prune and views/prune-stopped.jq before a failed
# --apply's exit 4, the prune cards sharing views/common.jq.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='crucible.sh'
# The one kind: main's drafts, kept in drafts/main-thread/ of an effort
# folder. Everything else of an effort is an event (events.sh).
readonly DRAFTS_KIND='drafts'
readonly DRAFTS_DIR='drafts/main-thread'
# Bounds the --older-than value handed to find -mtime, far past any real age.
readonly MAX_PRUNE_DAYS_DIGITS=5
# Keeps a --max value inside the shell's integer range.
readonly MAX_PATHS_DIGITS=9
readonly VIEW_SKILL='human-view'
readonly RENDER_LIB='scripts/lib/render.sh'
# The C locale keeps the shell's patterns and sort byte-wise on macOS and Linux.
LC_ALL=C
export LC_ALL

usage() {
	load_help_rules
	cat <<EOF
usage: crucible.sh new --kind KIND --effort FOLDER --label LABEL
       crucible.sh id --effort FOLDER
       crucible.sh path ID
       crucible.sh find --effort FOLDER --kind KIND [--label LABEL] [--max N]
       crucible.sh open ID [--editor CMD]
       crucible.sh prune --older-than Nd [--apply FOLDER...]
       crucible.sh root
       crucible.sh --help | -h

Hands out, finds and opens drafts by ID, and prunes effort folders of the
durable Crucible space.

Nothing outside the space is written or removed; folders made are mode 700,
files 600. Nothing else is left behind (a SIGKILL aside, which can leave a
pruned folder half removed). A symbolic link for efforts/, an effort or a
kind folder: new and find refuse it, the rest skip it.

Layout: <root>/efforts/<effort>/drafts/main-thread/<ID>-<label>.md
  ID      <YYYYMMDDTHHMMSS>-<4 lowercase hex digits>
  effort  named ${help_name_rule}
  kind    drafts: Markdown the main thread makes with new

Options:
  --kind KIND         new, find: a kind of the layout
  --effort FOLDER     new, id, find: an existing effort folder directly in
                      <root>/efforts/, absolute
  --label LABEL       new: the draft's label; find: only drafts with it.
                      ${help_label_rule}
  --max N             find: at most N (default 0, all); stderr notes a cut
  ID                  path, open (before its options): a full ID or its
                      4 hex digits
  --editor CMD        open: split on blanks (no quotes, no shell) and run
                      with the file as last argument, instead of open or
                      xdg-open, and waited for: it must hand the file to a
                      GUI app and return (code, idea; never 'code -w' or a
                      terminal editor)
  --older-than Nd     prune: the age N, in whole days
  --apply FOLDER...   prune: remove these folders of the dry run's list
  CRUCIBLE_HOME       the space root <root> (default \$HOME/.crucible):
                      absolute, not / and not a symbolic link
  CLAUDE_CONFIG_DIR   where skills are found (default \$HOME/.claude)

Commands:
  new    creates an empty file in --effort's KIND folder (made if missing),
         never overwriting, with an ID no other draft of the effort holds;
         stdout: its absolute path.
  id     stdout: a fresh ID no draft of --effort holds, for the caller
         (a dispatch ID). Read-only.
  path   stdout: the absolute path of the draft with ID.
  find   read-only; stdout: the absolute path of each KIND draft (with
         --label, of that label) in --effort's folder, one per line, newest
         first; nothing when none (or no KIND folder); an unreadable KIND
         folder exits 4.
  open   opens the draft. stdout: the card opened, its absolute path.
  prune  lists effort folders unchanged for N days (24 hours at least)
         and fully readable; --apply removes those FOLDERs, refusing any
         other (exit 2, nothing removed). Follows no symbolic link. stdout:
         its card, or the card prune-stopped before a failed --apply's exit 4.
  root   stdout: the space root, checked, not created.

Exit codes:
  0  done; go on
  1  path, open: no single draft has the ID; show the human stderr, and stop
  2  usage error; fix what stderr names and rerun once, else show the human
     stderr, and stop
  4  space fault, or stdout gone before a card; show the human stderr,
     and stop
  5  install fault; show the human stderr, and stop
  129, 130, 143  stopped by HUP, INT or TERM; show the human stderr, and stop
  other  unexpected; show the human the exit code and stderr, and stop

Dependencies:
  POSIX sh; lib/crucible-space.sh beside this script
  cat, date, find, mkdir, od, rm, sort, uname, /dev/urandom
  open, prune: jq 1.6+ (macOS: brew install jq; Linux: the distro's jq);
    the ${VIEW_SKILL} skill's show.sh and its lib/render.sh; this skill's views/
  open without --editor: open (macOS) or xdg-open (Linux)
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
		new | id | path | find | open | prune | root) ;;
		*) usage_error "unknown command: ${command}; expected new, id, path, find, open, prune, root or --help" ;;
	esac
	load_space_lib
	resolve_root
	case ${command} in
		new) run_new "$@" ;;
		id) run_id "$@" ;;
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
		*/*) own_dir=${0%/*} ;;
		*) own_dir=. ;;
	esac
	space_lib="${own_dir}/lib/crucible-space.sh"
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
	printf '%s\n' "${item_file}"
}

check_kind() {
	[ -n "${kind}" ] || usage_error "--kind missing; expected ${DRAFTS_KIND}"
	[ "${kind}" = "${DRAFTS_KIND}" ] || usage_error "unknown kind: ${kind}; expected ${DRAFTS_KIND}"
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

# Sets item_file to a new empty file in the effort's drafts folder.
create_item() {
	kind_dir="${effort}/${DRAFTS_DIR}"
	ensure_dir "${effort}/${DRAFTS_DIR%%/*}"
	ensure_dir "${kind_dir}"
	claim_item_file
	item_file="${kind_dir}/${name}"
}

# Creates one folder of the layout; an existing folder is reused unless it is a symlink.
ensure_dir() {
	[ ! -L "$1" ] || space_fault "$1 is a symbolic link; expected a real folder inside the space; try replacing the link with a real folder"
	mkdir "$1" 2>/dev/null || [ -d "$1" ] || space_fault "cannot create $1; expected a writable folder; try checking its permissions"
	[ ! -L "$1" ] || space_fault "$1 is a symbolic link; expected a real folder inside the space; try replacing the link with a real folder"
}

# Sets name for a file created in kind_dir whose ID no other item of the
# effort holds; exits 5 when no ID can be minted, 4 when no file can be made.
claim_item_file() {
	# shellcheck disable=SC2310 # its status says whether a file was made; the fault is read below
	if crucible_claim_item_file "${kind_dir}" "${label}" id_is_unique "${crucible_draft_extension}"; then
		name=${crucible_claimed_file##*/}
		return 0
	fi
	[ "${crucible_claim_fault}" != id ] || install_fault "${crucible_claim_problem}"
	space_fault "${crucible_claim_problem}"
}

# True when the file just created is the only one with this ID in the
# effort's drafts folder. Each caller counts after its own create, so of two
# racing for one ID at most one sees itself alone.
id_is_unique() {
	count_id_holders "$1"
	[ "${holders}" -eq 1 ]
}

# Sets holders to the number of files with ID $1 in the effort's drafts folder.
count_id_holders() {
	holders=0
	for holder in "${effort}/${DRAFTS_DIR}/$1"-*; do
		[ -e "${holder}" ] || [ -L "${holder}" ] || continue
		holders=$((holders + 1))
	done
}

run_id() {
	effort=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			--effort) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for id: $1; expected --effort" ;;
		esac
		effort=$2
		shift 2
	done
	check_effort
	mint_free_id
	printf '%s\n' "${crucible_id}"
}

# Sets crucible_id to a fresh ID no item of the effort holds; exits 5 when no
# ID can be minted, 4 when every try is taken.
mint_free_id() {
	id_try=1
	while :; do
		# shellcheck disable=SC2310 # its status says whether an ID was minted; the fault is named here
		crucible_mint_id || install_fault "${crucible_id_problem}"
		count_id_holders "${crucible_id}"
		[ "${holders}" -ne 0 ] || return 0
		[ "${id_try}" -lt "${crucible_max_create_attempts}" ] ||
			space_fault "${crucible_max_create_attempts} tries in ${effort} found the ID taken; expected a free one; try again"
		id_try=$((id_try + 1))
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
	editor='' editor_given=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--editor)
				require_value "$1" "$#"
				editor=$2 editor_given=true
				shift 2
				;;
			*) usage_error "unknown argument for open: $1; expected --editor CMD" ;;
		esac
	done
	[ "${editor_given}" = false ] || check_editor
	find_item "${wanted_id}"
	check_jq
	load_card_printer opened
	card_data=$(jq -nc --arg path "${item_path}" '{path: $path}' </dev/null) ||
		install_fault 'jq failed building the card data; expected jq 1.6+; try jq --version'
	open_in_editor
	show_card opened "${item_path%/"${DRAFTS_DIR}"/*}"
}

run_find() {
	kind='' label='' effort='' max_paths=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			--kind | --label | --effort | --max) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for find: $1; expected --effort, --kind, --label or --max" ;;
		esac
		case $1 in
			--kind) kind=$2 ;;
			--label) label=$2 ;;
			--max) max_paths=$2 ;;
			*) effort=$2 ;;
		esac
		shift 2
	done
	check_max
	check_kind
	[ -z "${label}" ] || check_label
	check_effort
	kind_dir="${effort}/${DRAFTS_DIR}"
	[ ! -L "${effort}/${DRAFTS_DIR%%/*}" ] && [ ! -L "${kind_dir}" ] ||
		space_fault "${kind_dir} or a folder above it in the effort is a symbolic link; expected real folders; try replacing the link with a real folder"
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
	sorted_names=$(printf '%s' "${found_names}" | sort -r) || install_fault 'sort failed; expected a POSIX sort; try installing one'
	shown=0 total=0
	while IFS= read -r found_name; do
		total=$((total + 1))
		[ "${max_paths}" -eq 0 ] || [ "${total}" -le "${max_paths}" ] || continue
		printf '%s/%s\n' "${kind_dir}" "${found_name}"
		shown=${total}
	done <<EOF
${sorted_names}
EOF
	warn_cut "${shown}" "${total}"
}

check_max() {
	case ${max_paths} in
		0) ;;
		'' | *[!0123456789]* | 0*) usage_error "bad --max: ${max_paths}; expected a whole number, 0 for all" ;;
		*) ;;
	esac
	[ "${#max_paths}" -le "${MAX_PATHS_DIGITS}" ] ||
		usage_error "bad --max: ${max_paths}; expected at most ${MAX_PATHS_DIGITS} digits"
}

# Says on stderr that --max cut the output: $1 shown of $2.
warn_cut() {
	[ "$1" -eq "$2" ] || warn "showing $1 of $2"
}

# Sets parsed_id and parsed_label when file name $1 is an item name of the
# draft, as crucible_name_item names one; fails otherwise.
parse_item_name() {
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	crucible_split_id "$1" || return 1
	parsed_id=${crucible_name_id}
	parsed_label=${crucible_name_rest%".${crucible_draft_extension}"}
	[ "${parsed_label}" != "${crucible_name_rest}" ] || return 1
	crucible_is_label "${parsed_label}"
}

# Sets item_id and item_path for the one item an ID names.
find_item() {
	# shellcheck disable=SC2310 # pure tests; their status is the answer
	crucible_is_id "$1" || crucible_is_id_hex "$1" ||
		usage_error "bad ID: $1; expected <YYYYMMDDTHHMMSS>-<hex> or the 4 lowercase hex digits"
	collect_matches "$1"
	[ "${match_count}" -gt 0 ] || not_found "no draft with ID $1 in ${root}/efforts; expected an ID crucible.sh new printed; try crucible.sh find --effort FOLDER --kind drafts"
	if [ "${match_count}" -gt 1 ]; then
		warn "ID $1 is shared by ${match_count} drafts; expected a unique ID; use the full one:"
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
		match_in_kind "${effort_dir}" "$1"
	done
}

# Adds the drafts of effort folder $1 whose ID, or the ID's hex, is $2.
match_in_kind() {
	kind_dir="$1/${DRAFTS_DIR}"
	[ ! -L "$1/${DRAFTS_DIR%%/*}" ] && [ ! -L "${kind_dir}" ] && [ -d "${kind_dir}" ] || return 0
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

# A blank --editor would leave the draft's own path as the command to run.
check_editor() {
	set -f
	# shellcheck disable=SC2086 # counts the words open_in_editor splits it into
	set -- ${editor}
	set +f
	[ "$#" -gt 0 ] || usage_error "--editor is blank; expected a command, e.g. --editor code"
}

# Sets views_dir and show_script and sources human-view's card printer lib,
# which checks that show.sh and each of the templates $@ (views/<name>.jq)
# are there; exits 5 when one of them is missing.
load_card_printer() {
	views_dir="${own_dir}/../views"
	view_skill_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${VIEW_SKILL}"
	render_lib="${view_skill_dir}/${RENDER_LIB}"
	require_file "${render_lib}" 'card printer lib' "install the ${VIEW_SKILL} skill"
	# shellcheck source=../../human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${view_skill_dir}/scripts" "${views_dir}" "$@" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
}

# Exits 5, naming file $1 as $2 and the fix $3, unless $1 is a readable file.
require_file() {
	[ -f "$1" ] && [ -r "$1" ] || install_fault "$2 missing; expected $1; $3"
}

# Prints card_data as card $1 of views/, owed for effort folder $2 (none when
# empty); exits 5 when show.sh fails, 4 when stdout is gone before the card.
show_card() {
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${show_script}" "${views_dir}" "$1" "$2" "${card_data}" && return 0
	install_fault "${hv_render_problem}; expected the card shown from views/$1.jq; try reinstalling the crucible and ${VIEW_SKILL} skills"
}

open_in_editor() {
	if [ -n "${editor}" ]; then
		# Split on blanks only, globbing off: the editor string is never parsed
		# by a shell, and the file path reaches it as one separate argument.
		set -f
		# shellcheck disable=SC2086 # splitting the editor into its words is the point
		set -- ${editor} "${item_path}"
		set +f
		"$@" >&2 ||
			install_fault "the editor '${editor}' failed on ${item_path}; expected it to open the file; try another --editor CMD"
		return 0
	fi
	os=$(uname -s) || install_fault 'uname failed; expected the OS name to pick an opener; try --editor CMD'
	if [ "${os}" = Darwin ]; then
		opener=open
	else
		opener=xdg-open
	fi
	command -v "${opener}" >/dev/null 2>&1 ||
		install_fault "${opener} missing; expected it on PATH, or --editor CMD"
	"${opener}" "${item_path}" >&2 ||
		install_fault "${opener} failed on ${item_path}; expected it to open the file; try --editor CMD"
}

run_prune() {
	days='' apply=false apply_folders=''
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
				while [ "$#" -gt 0 ]; do
					case $1 in
						-*) break ;;
						*) add_apply_folder "$1" ;;
					esac
					shift
				done
				;;
			*) usage_error "unknown argument for prune: $1; expected --older-than Nd or --apply FOLDER..." ;;
		esac
	done
	check_days
	[ "${apply}" = false ] || [ -n "${apply_folders}" ] ||
		usage_error '--apply needs folders; expected --apply FOLDER..., folders the dry run listed'
	command -v find >/dev/null 2>&1 || install_fault 'find missing; expected find on PATH to see recent files; try installing find (POSIX)'
	check_jq
	load_card_printer common prune prune-stopped
	removed_items='' kept_items=''
	if [ "${apply}" = true ]; then
		apply_prune
	else
		list_prunable
	fi
	show_prune prune
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

# The folders travel newline-separated, so one holding a newline is refused here.
add_apply_folder() {
	case $1 in
		*"
"*) usage_error '--apply: a folder holds a newline; expected folders the dry run listed' ;;
		*) apply_folders="${apply_folders}$1
" ;;
	esac
}

# Sets removed_items and kept_items to the dry run's lists.
list_prunable() {
	efforts_dir="${root}/efforts"
	[ -d "${efforts_dir}" ] && [ ! -L "${efforts_dir}" ] || return 0
	for effort_dir in "${efforts_dir}"/*; do
		# shellcheck disable=SC2310 # a pure test; its status is the answer
		crucible_is_effort_name "${effort_dir##*/}" || continue
		[ -d "${effort_dir}" ] && [ ! -L "${effort_dir}" ] || continue
		check_prunable "${effort_dir}"
		case ${keep_reason} in
			'') removed_items="${removed_items}${effort_dir}
" ;;
			young) ;;
			*) print_kept "${effort_dir}" "${keep_reason}" ;;
		esac
	done
}

# Removes the --apply folders once every one is still prunable; refuses them
# all, exit 2, when any is not.
apply_prune() {
	prune_list='' refused=0
	while IFS= read -r wanted_folder; do
		[ -n "${wanted_folder}" ] || continue
		refusal=''
		# shellcheck disable=SC2310 # its status says whether the folder passed; the refusal is read below
		if ! crucible_effort_check "${wanted_folder}"; then
			refusal=${crucible_effort_problem}
		else
			case ${prune_list} in
				*"${crucible_effort}
"*) refusal='listed twice' ;;
				*) set_refusal_by_age "${crucible_effort}" ;;
			esac
		fi
		if [ -n "${refusal}" ]; then
			warn "refused: ${wanted_folder}: ${refusal}"
			refused=$((refused + 1))
		else
			prune_list="${prune_list}${crucible_effort}
"
		fi
	done <<EOF
${apply_folders}
EOF
	[ "${refused}" -eq 0 ] ||
		usage_error "${refused} folder(s) refused, nothing removed; expected folders still prunable; try a new dry run"
	while IFS= read -r prune_folder; do
		[ -n "${prune_folder}" ] || continue
		remove_effort "${prune_folder}"
		removed_items="${removed_items}${prune_folder}
"
	done <<EOF
${prune_list}
EOF
}

# Sets refusal to why effort folder $1 may not go by its age; empty when it may.
set_refusal_by_age() {
	check_prunable "$1"
	case ${keep_reason} in
		young) refusal="modified in the last ${count} days" ;;
		*) refusal=${keep_reason} ;;
	esac
}

# Sets keep_reason for effort folder $1 by the age of the newest thing in it:
# empty when it may go, young when modified in the last N days, else why it
# stays. A session may still write to an effort, so one touched in the last
# 24 hours stays whatever N is.
check_prunable() {
	keep_reason='find cannot read all of it'
	# shellcheck disable=SC2310 # its status is the answer; a failure to read keeps the folder
	recent_in "$1" "${count}" || return 0
	keep_reason=young
	[ -z "${recent}" ] || return 0
	keep_reason='find cannot read all of it'
	# shellcheck disable=SC2310 # its status is the answer; a failure to read keeps the folder
	recent_in "$1" 1 || return 0
	keep_reason='something in it was modified in the last 24 hours'
	[ -z "${recent}" ] || return 0
	keep_reason=''
}

# Removes effort folder $1 and checks it is gone; on a failure, shows what was
# removed before it, then exits 4.
remove_effort() {
	{ rm -rf "$1" && [ ! -e "$1" ] && [ ! -L "$1" ]; } || {
		show_prune prune-stopped
		space_fault "cannot remove $1; expected it gone; try checking its permissions"
	}
}

# Sets recent to what in folder $1 (the folder included) was modified less
# than $2 days ago; fails when find cannot read all of it.
recent_in() {
	recent=$(find "$1" -mtime "-$2" -print 2>/dev/null)
}

# Adds effort folder $1, kept for reason $2, as two lines of kept_items.
print_kept() {
	kept_items="${kept_items}$1
$2
"
}

# Prints prune card $1 (prune or prune-stopped) from the lists so far. Effort
# folder names and reasons hold no newline, so the lists travel
# newline-separated.
show_prune() {
	# shellcheck disable=SC2016 # the $ signs are jq's
	card_data=$(jq -nc --argjson applied "${apply}" --argjson days "${count}" \
		--arg removed "${removed_items}" --arg kept "${kept_items}" '
		def lines: split("\n") | map(select(. != ""));
		($kept | lines) as $kept_lines
		| {applied: $applied, days: $days, removed: ($removed | lines),
			kept: [range(0; $kept_lines | length; 2) | {folder: $kept_lines[.], reason: $kept_lines[. + 1]}]}' </dev/null) ||
		install_fault 'jq failed building the card data; expected jq 1.6+; try jq --version'
	show_card "$1" ''
}

main "$@"
