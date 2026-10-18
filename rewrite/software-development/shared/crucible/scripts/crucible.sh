#!/usr/bin/env sh
# Hands out paths in the durable Crucible space, finds items through its
# day indexes, renders and opens them, and prunes old day folders.
set -eu
umask 077

readonly PROG='crucible.sh'
readonly KINDS='context, gates, reports'
readonly MAX_LABEL_CHARS=60
# A clash needs the same second, label and 4 random hex digits; a handful of
# fresh draws makes a repeat practically impossible.
readonly MAX_CREATE_ATTEMPTS=5
# Bounds the --older-than value so the date arithmetic stays well inside jq's range.
readonly MAX_PRUNE_DAYS_DIGITS=5
# An index append holds its lock for one write, so a lock this old was left
# by a holder that stopped; waiting longer than the wait bound gives up.
readonly INDEX_LOCK_STALE_SECONDS=5
readonly INDEX_LOCK_WAIT_SECONDS=10
readonly INDEX_LOCK_POLL_SECONDS=0.05
# Spins between two checks of the clock and of the lock's staleness.
readonly INDEX_LOCK_SPINS_PER_CHECK=20
readonly REPORT_RENDERER='skills/standard-code-development-report/scripts/report.sh'

# One index line is trusted only when every field has the shape `new` writes
# and its ID's date matches the day folder it sits in; anything else is skipped.
# The program is single-quoted on purpose: its $ signs are jq's.
# shellcheck disable=SC2016
readonly LOOKUP_JQ='
def kinds: ["context", "gates", "reports"];
def day_of_file: capture("/(?<y>[0-9]{4})/(?<m>[0-9]{2})/(?<d>[0-9]{2})/index\\.jsonl$") | .y + .m + .d;
def valid_entry($index):
	type == "object" and .v == 1
	and (.id | type) == "string" and (.id | test("^[0-9]{8}T[0-9]{6}-[0-9a-f]{4}$"))
	and (.kind | type) == "string" and (.kind as $kind | kinds | index([$kind]) != null)
	and (.label | type) == "string" and (.label | test("^[a-z0-9-]{1,60}$"))
	and .file == "\(.kind)/\(.id)-\(.label).json"
	and ($index | day_of_file? // "") == .id[0:8];
def wanted: if ($want | length) == 4 then .id | endswith("-" + $want) else .id == $want end;
[inputs | input_filename as $index | (fromjson? // empty)
	| select(valid_entry($index) and wanted)
	| {dir: ($index | rtrimstr("/index.jsonl")), id, file, kind, label}]
| unique_by([.id, .file])[]
| [.id, .dir + "/" + .file, .kind, .label] | @tsv
'

usage() {
	cat <<'EOF'
usage: crucible.sh new --kind KIND --label LABEL [--repo PATH] [--session ID]
       crucible.sh path ID
       crucible.sh open ID [--format md|html] [--editor CMD]
       crucible.sh prune --older-than Nd [--apply]
       crucible.sh --help

Hands out and finds the files of the durable Crucible space, where every
context file, gate record and agent report lives as one JSON file.

The space: ${CRUCIBLE_HOME:-$HOME/.crucible}, an absolute path. The space
and every folder in it is a real folder: a root, year, month, day or kind
folder that is a symbolic link is refused (exit 4 for new; skipped by path,
open and prune), so nothing is ever read, written or removed outside the
root. Folders the script creates are mode 700, files mode 600.

Layout (local time):
  <root>/YYYY/MM/DD/index.jsonl
  <root>/YYYY/MM/DD/<kind>/<YYYYMMDDTHHMMSS>-<hex>-<label>.json
  kind: context, gates or reports; hex: 4 random lowercase hex digits.
  The ID of an item is <YYYYMMDDTHHMMSS>-<hex>.

Index line, one per item, appended by new (built by jq, written whole
under the day's index lock):
  {"v":1,"id":"<ts>-<hex>","time":"<ts>","kind":"<kind>",
   "file":"<kind>/<name>","label":"<label>","repo":"<path>","session":"<id>"}
  file is relative to the day folder, so the tree can move as a whole.

Commands:
  new    creates an empty file (mode 600) for the caller to write, appends
         its index line and prints its absolute path. LABEL: lowercase a-z,
         0-9 and -, 1 to 60 characters. --repo (absolute) defaults to the git
         root of the current folder, or empty outside a repository; --session
         defaults to empty. The file is created without overwriting
         (noclobber) and its ID is claimed across the day's kind folders; a
         clash of either retries with fresh hex, up to 5 times. The index
         line is appended while new holds <day>/.index.lock, a folder only
         one new at a time can create, so a line of any length lands whole.
         A lock older than 5 seconds, or whose owner process is gone, is
         broken (stderr says so); after 10 seconds of waiting new exits 4
         and removes the file it created. The content is the caller's to
         write, as one JSON object in its writer's shape ("v": 1 is only in
         index lines and gate records).
  path   prints the absolute path of an item. ID: the full ID, which reads
         only the index of the day in its date; or its 4 hex digits, which
         searches the day folders newest first and stops at the first day
         holding an item with them: several items there sharing them is an
         error, and an item in an older day with the same hex is not seen,
         so it needs its full ID. Items are found through the index files
         only; an index line of the wrong shape is skipped.
  open   renders an item to a new temp folder in ${TMPDIR:-/tmp} (never
         inside the space; it is left for the editor and not removed) and
         opens it. A report is rendered by
         ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/standard-code-development-report/scripts/report.sh
         render --full when that script's --help names --full and the render
         succeeds; anything else gets a title line with the kind and label and
         the JSON pretty-printed in a json fence. It opens with the OS
         opener, open (macOS) or xdg-open (Linux), which hands the file to
         the desktop and never blocks; $VISUAL and $EDITOR are not consulted.
         --editor CMD opens it with CMD instead: CMD is run by sh with the
         file as its last argument, the way git runs $EDITOR. CMD must hand
         the file to a GUI app and return (e.g. code, idea); never a terminal
         editor or a waiting form such as 'code -w'. The opener's or
         editor's output goes to stderr. Prints exactly one line: opened
         <file>. --format html is not available yet.
  prune  lists the day folders whose date is more than N days before today
         (with 7d on the 18th, the 10th and earlier). Without --apply it
         prints "would remove <folder>" for each and changes nothing; with
         --apply it removes them, and any month or year folder left empty.
         A session may still write to a recent day, so these are never
         removed, in either mode, and print "kept <folder> (<reason>)":
         today, yesterday, and a day holding a file modified in the last
         24 hours (or one find cannot fully read). The closing count names
         the kept folders when there are any. Only folders matching
         <root>/YYYY/MM/DD are ever touched.

Exit codes:
  0  ok (prune: also when nothing is old enough)
  1  path or open: no indexed item has that ID, the ID's hex is shared by
     several items (stderr lists them), or the indexed file is gone
  2  usage error: unknown command or option, bad kind, bad label, a relative
     --repo or CRUCIBLE_HOME, a malformed ID or Nd, --format html
  4  the space cannot be created or written, a folder in it is a symlink,
     or new waited 10 seconds for a busy index lock
  5  install fault, its stderr line starting "crucible.sh: install:": a
     dependency below missing, too old or failing: jq, od or tr (no random
     source), date +%s, sleep, sort, grep, uname, the opener or the editor

Dependencies: POSIX sh; jq 1.6+; cat, cut, find, grep, mkdir, mktemp, mv,
od, rm, rmdir, sort, tr and uname; a date that knows +%s; a stat that knows
-c %Y (GNU) or -f %m (BSD); a sleep that takes fractions; git only to
default --repo; open (macOS) or xdg-open (Linux) only for open without
--editor.
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
		new | path | open | prune) ;;
		*) usage_error "unknown command: ${command}; expected new, path, open, prune or --help" ;;
	esac
	resolve_root
	check_jq
	case ${command} in
		new) run_new "$@" ;;
		path) run_path "$@" ;;
		open) run_open "$@" ;;
		*) run_prune "$@" ;;
	esac
}

# Sets root from CRUCIBLE_HOME or the home folder, without trailing slashes.
resolve_root() {
	if [ -n "${CRUCIBLE_HOME:-}" ]; then
		root=${CRUCIBLE_HOME}
	elif [ -n "${HOME:-}" ]; then
		root="${HOME}/.crucible"
	else
		space_fault 'neither CRUCIBLE_HOME nor HOME is set; expected one of them to name the space'
	fi
	case ${root} in
		/*) ;;
		*) usage_error "CRUCIBLE_HOME ${root} is not absolute; expected an absolute path" ;;
	esac
	while [ "${root}" != "${root%/}" ]; do root=${root%/}; done
	[ -n "${root}" ] || usage_error 'CRUCIBLE_HOME is /; expected a folder of its own'
	[ ! -L "${root}" ] || space_fault "${root} is a symbolic link; expected a real folder (point CRUCIBLE_HOME at the target instead)"
}

check_jq() {
	command -v jq >/dev/null 2>&1 || install_fault 'jq missing; expected jq 1.6+ on PATH; try brew install jq (macOS) or the distro jq package'
	jq_version=$(jq --version 2>/dev/null) || install_fault 'jq --version failed; expected jq 1.6+; try reinstalling jq'
	case ${jq_version} in
		jq-1.[6-9]* | jq-1.[1-9][0-9]* | jq-[2-9]*) ;;
		*) install_fault "jq is ${jq_version}; expected jq 1.6+; try upgrading jq" ;;
	esac
}

# Option values arrive as the next argument; an empty or missing one is a usage error.
require_value() {
	[ "$2" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
}

run_new() {
	kind='' label='' session='' repo='' repo_given=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--kind | --label | --repo | --session) require_value "$1" "$#" ;;
			*) usage_error "unknown argument for new: $1; expected --kind, --label, --repo or --session" ;;
		esac
		case $1 in
			--kind) kind=$2 ;;
			--label) label=$2 ;;
			--session) session=$2 ;;
			*) repo=$2 repo_given=true ;;
		esac
		shift 2
	done
	check_kind
	check_label
	if [ "${repo_given}" = true ]; then
		check_repo
	else
		repo=$(default_repo)
	fi
	create_item
}

check_kind() {
	case ${kind} in
		context | gates | reports) ;;
		'') usage_error "--kind missing; expected one of ${KINDS}" ;;
		*) usage_error "unknown kind: ${kind}; expected one of ${KINDS}" ;;
	esac
}

check_label() {
	case ${label} in
		'') usage_error '--label missing; expected lowercase a-z, 0-9 and -, 1 to 60 characters' ;;
		*[!abcdefghijklmnopqrstuvwxyz0123456789-]*)
			usage_error "bad label: ${label}; expected lowercase a-z, 0-9 and - only"
			;;
		*) ;;
	esac
	[ "${#label}" -le "${MAX_LABEL_CHARS}" ] ||
		usage_error "label is ${#label} characters; expected at most ${MAX_LABEL_CHARS}"
}

check_repo() {
	case ${repo} in
		'' | /*) ;;
		*) usage_error "--repo ${repo} is not absolute; expected the absolute path of the git root" ;;
	esac
}

# Prints the git root of the current folder, or nothing outside a repository.
default_repo() {
	command -v git >/dev/null 2>&1 || return 0
	git rev-parse --show-toplevel 2>/dev/null || true
}

create_item() {
	stamp=$(date +%Y%m%dT%H%M%S) || space_fault 'date failed; expected the local time'
	split_date "${stamp%T*}"
	day_dir="${root}/${year}/${month}/${day}"
	kind_dir="${day_dir}/${kind}"
	ensure_root
	ensure_dir "${root}/${year}"
	ensure_dir "${root}/${year}/${month}"
	ensure_dir "${day_dir}"
	ensure_dir "${kind_dir}"
	attempt=1
	while :; do
		hex=$(random_hex)
		name="${stamp}-${hex}-${label}.json"
		# shellcheck disable=SC2310 # its status is the create result; errexit adds nothing
		if create_exclusive "${kind_dir}/${name}"; then
			# shellcheck disable=SC2310 # its status is the count result; errexit adds nothing
			if id_is_unique "${stamp}-${hex}"; then break; fi
			rm -f "${kind_dir}/${name}"
		elif [ ! -L "${kind_dir}/${name}" ] && [ ! -e "${kind_dir}/${name}" ]; then
			space_fault "cannot create a file in ${kind_dir}; expected a writable folder"
		fi
		[ "${attempt}" -lt "${MAX_CREATE_ATTEMPTS}" ] ||
			space_fault "${MAX_CREATE_ATTEMPTS} tries in ${kind_dir} found the name or its ID taken; expected a free one, try again"
		attempt=$((attempt + 1))
	done
	item_file="${kind_dir}/${name}"
	index_line "${stamp}-${hex}" "${stamp}" "${kind}/${name}"
	# shellcheck disable=SC2310 # its status is the wait result; errexit adds nothing
	acquire_index_lock "${stamp}-${hex}" || {
		rm -f "${item_file}"
		space_fault "${index_lock} stayed busy for ${INDEX_LOCK_WAIT_SECONDS} seconds; expected it free, try again (the new file was removed)"
	}
	# shellcheck disable=SC2310 # every step in it returns on failure
	append_index || {
		release_index_lock
		rm -f "${item_file}"
		space_fault "cannot append to ${day_dir}/index.jsonl; expected a writable index (the new file was removed)"
	}
	release_index_lock
	printf '%s\n' "${item_file}"
}

# Sets year, month and day from a YYYYMMDD date.
split_date() {
	year=${1%????}
	month_and_day=${1#????}
	month=${month_and_day%??}
	day=${month_and_day#??}
}

ensure_root() {
	[ -d "${root}" ] || mkdir -p "${root}" 2>/dev/null || [ -d "${root}" ] ||
		space_fault "cannot create ${root}; expected a writable parent folder"
	[ ! -L "${root}" ] || space_fault "${root} is a symbolic link; expected a real folder"
}

# Creates one folder of the layout; an existing folder is reused unless it is a symlink.
ensure_dir() {
	[ ! -L "$1" ] || space_fault "$1 is a symbolic link; expected a real folder inside the space"
	mkdir "$1" 2>/dev/null || [ -d "$1" ] || space_fault "cannot create $1; expected a writable folder"
	[ ! -L "$1" ] || space_fault "$1 is a symbolic link; expected a real folder inside the space"
}

random_hex() {
	value=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') ||
		install_fault 'reading /dev/urandom failed; expected a random source'
	case ${value} in
		[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) printf '%s' "${value}" ;;
		*) install_fault "od printed '${value}' for 2 random bytes; expected 4 lowercase hex digits" ;;
	esac
}

# True when the file just created is the day's only one with this ID, in any
# kind folder. Each caller counts after its own create, so of two racing for
# one ID at most one sees itself alone.
id_is_unique() {
	holders=0
	for holder in "${day_dir}"/*/"$1"-*.json; do
		[ -e "${holder}" ] || [ -L "${holder}" ] || continue
		holders=$((holders + 1))
	done
	[ "${holders}" -eq 1 ]
}

# Fails when the name exists, as a file or a symlink: noclobber opens with O_EXCL.
create_exclusive() {
	(
		set -C
		: >"$1"
	) 2>/dev/null
}

# Sets line, built before the lock is taken so the lock is held for the write alone.
index_line() {
	line=$(jq -cn --arg id "$1" --arg time "$2" --arg kind "${kind}" --arg file "$3" \
		--arg label "${label}" --arg repo "${repo}" --arg session "${session}" \
		'{v: 1, id: $id, time: $time, kind: $kind, file: $file, label: $label, repo: $repo, session: $session}') ||
		install_fault 'jq failed to build the index line; expected jq 1.6+'
}

# Takes <day>/.index.lock, whose owner file names this process and the item.
# Fails when the lock stays busy past the wait bound.
acquire_index_lock() {
	index_lock="${day_dir}/.index.lock"
	lock_owner="$$ $1"
	index_lock_held=false
	trap release_index_lock EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	spins=0 deadline=''
	while :; do
		if mkdir "${index_lock}" 2>/dev/null; then
			# A breaker may move the folder away before the owner file lands; the
			# exclusive create then fails, and the lock is not this holder's.
			# shellcheck disable=SC2310 # its status is the create result; errexit adds nothing
			if write_lock_owner; then
				index_lock_held=true
				return 0
			fi
		fi
		if [ $((spins % INDEX_LOCK_SPINS_PER_CHECK)) -eq 0 ]; then
			# Called as a condition, so errexit is off here: a fault exits by hand.
			# shellcheck disable=SC2310 # its every fault exits through install_fault
			now=$(epoch_seconds) || exit "$?"
			[ -n "${deadline}" ] || deadline=$((now + INDEX_LOCK_WAIT_SECONDS))
			[ "${now}" -lt "${deadline}" ] || return 1
			break_stale_index_lock "${now}"
		fi
		spins=$((spins + 1))
		sleep "${INDEX_LOCK_POLL_SECONDS}" 2>/dev/null ||
			install_fault "sleep ${INDEX_LOCK_POLL_SECONDS} failed; expected a sleep that takes fractions of a second"
	done
}

# Creates the owner file without overwriting one, in this shell, so holding
# the lock costs no extra process.
write_lock_owner() {
	set -C
	if { printf '%s\n' "${lock_owner}" >"${index_lock}/owner"; } 2>/dev/null; then
		set +C
		return 0
	fi
	set +C
	return 1
}

# Sets lock_file_owner from a lock folder's owner file, or empties it.
read_lock_owner() {
	lock_file_owner=''
	{ IFS= read -r lock_file_owner <"$1/owner"; } 2>/dev/null || true
}

epoch_seconds() {
	seconds=$(date +%s) || install_fault 'date +%s failed; expected the seconds since the epoch'
	case ${seconds} in
		'' | *[!0123456789]*) install_fault "date +%s printed '${seconds}'; expected the seconds since the epoch" ;;
		*) printf '%s' "${seconds}" ;;
	esac
}

# Moves a stale lock aside, then removes it. When the folder moved turns out
# to be a fresh lock another waiter took after breaking the same stale one,
# it is put back if the name is still free.
break_stale_index_lock() {
	read_lock_owner "${index_lock}"
	judged_owner=${lock_file_owner}
	# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
	index_lock_is_stale "${judged_owner}" "$1" || return 0
	aside="${index_lock}.stale.$$"
	rm -rf "${aside}"
	mv "${index_lock}" "${aside}" 2>/dev/null || return 0
	read_lock_owner "${aside}"
	if [ "${lock_file_owner}" != "${judged_owner}" ] && [ ! -e "${index_lock}" ] &&
		mv "${aside}" "${index_lock}" 2>/dev/null; then
		return 0
	fi
	rm -rf "${aside}"
	warn "broke the stale index lock ${index_lock} (owner: ${judged_owner:-none written})"
}

# True when the lock's owner process is gone while the lock still names it,
# or the lock folder is older than the stale bound (this also covers a holder
# that never wrote its owner).
index_lock_is_stale() {
	owner_pid=${1%% *}
	case ${owner_pid} in
		'' | *[!0123456789]*) ;;
		*)
			if ! kill -0 "${owner_pid}" 2>/dev/null; then
				# The holder may have released and exited since its owner was read.
				read_lock_owner "${index_lock}"
				[ "${lock_file_owner}" = "$1" ]
				return
			fi
			;;
	esac
	modified=$(stat -c %Y "${index_lock}" 2>/dev/null) ||
		modified=$(stat -f %m "${index_lock}" 2>/dev/null) || return 1
	case ${modified} in
		'' | *[!0123456789]*) return 1 ;;
		*) ;;
	esac
	[ $(($2 - modified)) -gt "${INDEX_LOCK_STALE_SECONDS}" ]
}

# Removes the lock only while its owner file still names this holder.
release_index_lock() {
	[ "${index_lock_held:-false}" = true ] || return 0
	index_lock_held=false
	read_lock_owner "${index_lock}"
	[ "${lock_file_owner}" = "${lock_owner}" ] || return 0
	rm -rf "${index_lock}" || warn "cannot remove ${index_lock}; the next new breaks it as stale"
}

append_index() {
	index="${day_dir}/index.jsonl"
	[ ! -L "${index}" ] || return 1
	{ printf '%s\n' "${line}" >>"${index}"; } 2>/dev/null
}

run_path() {
	[ "$#" -eq 1 ] || usage_error 'path takes exactly one ID; expected crucible.sh path ID'
	find_item "$1"
	printf '%s\n' "${item_path}"
}

run_open() {
	[ "$#" -gt 0 ] || usage_error 'open needs an ID; expected crucible.sh open ID [--format md|html] [--editor CMD]'
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
	render_to_temp
	open_in_editor
	printf 'opened %s\n' "${rendered}"
}

# Sets item_id, item_path, item_kind and item_label for the one item an ID names.
find_item() {
	case $1 in
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]-[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) ;;
		[0123456789abcdef][0123456789abcdef][0123456789abcdef][0123456789abcdef]) ;;
		*) usage_error "bad ID: $1; expected <YYYYMMDDTHHMMSS>-<hex> or the 4 lowercase hex digits" ;;
	esac
	matches=$(lookup "$1")
	[ -n "${matches}" ] || not_found "no item with ID $1 in ${root}"
	tab=$(printf '\t')
	newline='
'
	case ${matches} in
		*"${newline}"*)
			warn "ID $1 is shared by several items; expected a unique ID; use the full one:"
			printf '%s\n' "${matches}" | cut -f1,2 | tr '\t' ' ' >&2
			exit 1
			;;
		*) ;;
	esac
	IFS=${tab} read -r item_id item_path item_kind item_label <<EOF
${matches}
EOF
	[ -f "${item_path}" ] && [ ! -L "${item_path}" ] ||
		not_found "item ${item_id} is indexed but ${item_path} is missing or not a regular file"
}

# Prints one tab-separated line (id, path, kind, label) per indexed item matching the ID.
lookup() {
	want=$1
	case ${want} in
		????) lookup_hex ;;
		*) lookup_full_id ;;
	esac
}

# A full ID carries its date, so only that day's index is read.
lookup_full_id() {
	split_date "${want%T*}"
	day_folder="${root}/${year}/${month}/${day}"
	# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
	is_real_day "${day_folder}" || return 0
	read_index "${day_folder}/index.jsonl"
}

# Reads the days newest first and stops at the first one with a match. The
# days are searched in batches of 1, 2, 4, ... so a recent item costs one
# small read and an old one at most twice the data before it.
lookup_hex() {
	newline='
'
	days=''
	for day_folder in "${root}"/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]; do
		# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
		is_real_day "${day_folder}" || continue
		index="${day_folder}/index.jsonl"
		[ -f "${index}" ] && [ ! -L "${index}" ] || continue
		days="${days}${index#"${root}/"}${newline}"
	done
	[ -n "${days}" ] || return 0
	# Paths relative to the root are digits and slashes, so they split safely by line.
	newest_first=$(printf '%s' "${days}" | sort -r) || install_fault 'sort failed; expected a POSIX sort'
	batch_size=1
	set --
	while IFS= read -r day_index; do
		set -- "$@" "${day_index}"
		[ "$#" -ge "${batch_size}" ] || continue
		# shellcheck disable=SC2310 # its status is the match result; its faults exit
		search_days "$@" && return 0
		set --
		batch_size=$((batch_size * 2))
	done <<EOF
${newest_first}
EOF
	# shellcheck disable=SC2310 # its status is the match result; its faults exit
	[ "$#" -eq 0 ] || search_days "$@" || true
}

# Prints the matches of the first of the given days (newest first) that has any.
# grep only narrows the days to read; jq still judges every line of them.
search_days() {
	candidates=$(cd "${root}" && grep -lF -e "-${want}\"" "$@" 2>/dev/null) || [ "$?" -eq 1 ] ||
		install_fault 'grep failed reading the index files; expected readable index files'
	while IFS= read -r candidate; do
		[ -n "${candidate}" ] || continue
		# Called as a condition, so errexit is off here: a fault exits by hand.
		# shellcheck disable=SC2310 # its every fault exits through install_fault
		found=$(read_index "${root}/${candidate}") || exit "$?"
		[ -z "${found}" ] || {
			printf '%s\n' "${found}"
			return 0
		}
	done <<EOF
${candidates}
EOF
	return 1
}

read_index() {
	[ -f "$1" ] && [ ! -L "$1" ] || return 0
	jq -nrR --arg want "${want}" "${LOOKUP_JQ}" "$1" ||
		install_fault 'jq failed reading the index files; expected jq 1.6+'
}

# True for a day folder whose day, month and year levels are real folders, not symlinks.
is_real_day() {
	month_dir=${1%/*}
	[ -d "$1" ] && [ ! -L "$1" ] && [ ! -L "${month_dir}" ] && [ ! -L "${month_dir%/*}" ]
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
	rendered="${temp_dir}/${item_id}-${item_label}.md"
	# shellcheck disable=SC2310 # every step in it is checked; a failure falls back to the generic render
	if [ "${item_kind}" = reports ] && render_full_report >"${rendered}"; then return 0; fi
	render_generic >"${rendered}"
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
	if [ ! -s "${item_path}" ]; then
		printf 'Empty: nothing has been written to this item.\n'
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
	today=$(date +%Y%m%d) || space_fault 'date failed; expected the local time'
	# shellcheck disable=SC2310 # its status is its jq's; a failure exits
	cutoff=$(days_before "${count}") || install_fault 'jq failed on the date arithmetic; expected jq 1.6+'
	# shellcheck disable=SC2310 # its status is its jq's; a failure exits
	yesterday=$(days_before 1) || install_fault 'jq failed on the date arithmetic; expected jq 1.6+'
	removed=0 kept=0
	for day_folder in "${root}"/[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]; do
		# shellcheck disable=SC2310 # its status is the test result; errexit adds nothing
		is_real_day "${day_folder}" || continue
		day_date=$(date_of_day "${day_folder}")
		[ "${day_date}" -lt "${cutoff}" ] || continue
		judge_keep "${day_folder}" "${day_date}"
		if [ -n "${keep_reason}" ]; then
			printf 'kept %s (%s)\n' "${day_folder}" "${keep_reason}"
			kept=$((kept + 1))
			continue
		fi
		prune_day "${day_folder}"
		removed=$((removed + 1))
	done
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
}

# Prints YYYYMMDD for today minus N days, by calendar date in local time.
days_before() {
	jq -nr --arg today "${today}" --arg count "$1" \
		'$today | strptime("%Y%m%d") | mktime - (($count | tonumber) * 86400) | strftime("%Y%m%d")'
}

# Sets keep_reason when a session may still write to the day folder, else empties it.
judge_keep() {
	keep_reason=''
	if [ "$2" -ge "${yesterday}" ]; then
		keep_reason='today or yesterday'
		return 0
	fi
	recent=$(find "$1" -type f -mtime -1 -print 2>/dev/null) || {
		keep_reason='find cannot read all of it'
		return 0
	}
	[ -z "${recent}" ] || keep_reason='a file in it was modified in the last 24 hours'
}

date_of_day() {
	day_part=${1##*/}
	month_dir=${1%/*}
	month_part=${month_dir##*/}
	year_dir=${month_dir%/*}
	printf '%s%s%s' "${year_dir##*/}" "${month_part}" "${day_part}"
}

prune_day() {
	if [ "${apply}" = false ]; then
		printf 'would remove %s\n' "$1"
		return 0
	fi
	rm -rf "$1" || space_fault "cannot remove $1; expected a writable folder"
	month_dir=${1%/*}
	if rmdir "${month_dir}" 2>/dev/null; then rmdir "${month_dir%/*}" 2>/dev/null || true; fi
	printf 'removed %s\n' "$1"
}

report_prune() {
	split_date "${cutoff}"
	shown_cutoff="${year}-${month}-${day}"
	kept_note=''
	[ "${kept}" -eq 0 ] || kept_note=" (kept ${kept}, listed above)"
	if [ "${apply}" = true ]; then
		printf 'removed %s day folders dated before %s%s\n' "${removed}" "${shown_cutoff}" "${kept_note}"
	else
		printf 'would remove %s day folders dated before %s%s; nothing changed, add --apply to remove them\n' "${removed}" "${shown_cutoff}" "${kept_note}"
	fi
}

main "$@"
