#!/usr/bin/env sh
# Mounts idle developer seats' committed work into the main checkout, so the
# human can try it there: the diff from the start (HEAD, or the snapshot the
# seats were cut from) to the target (one seat's HEAD, or the merge of
# several) is applied to the working tree only, after every path it touches
# is proven to still hold the start's state, and the patch plus a record are
# kept in the checkout's git folder for unmount.sh. The index, refs and every
# other path stay untouched.
set -eu
# git apply writes the checkout's files under the human's own umask.
inherited_umask=$(umask)
umask 077

readonly PROG='mount.sh'
readonly EFFORT_TRAILER='Effort'
# The C locale keeps the shell, sed and awk byte-wise.
LC_ALL=C
export LC_ALL
# No git command here may refresh or write the checkout's or the seat's index.
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside the seat's
# folders; GIT_DIFF_OPTS would change the patch's context.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_DIFF_OPTS GIT_EXTERNAL_DIFF

usage() {
	cat <<EOF
usage: sh ${PROG} --effort DIR --slot S [--slot S]...
       sh ${PROG} --help | -h

Applies idle developer seats' committed work to their main checkout's
working tree: the diff from the start to the target, .crucible-effort left
out. The target is the one seat's HEAD, or ../merge/tips-merge.sh's merge
of every seat's HEAD; effort-commits.sh proves every commit from HEAD to
the target is the effort's (slots.json's effort) and gives the start: HEAD,
or the snapshot the seats were cut from. Never touches the index, a ref, a
seat's worktree or a path outside the patch. A success leaves
crucible/mount.json (version 2), crucible/mount.patch and crucible/before/
(raw copies of the files the patch replaced or deleted) in the checkout's
git folder; a refusal writes no file, index or ref (tips-merge.sh may
leave git objects); a failed check after applying reverses the patch.

--effort DIR  absolute path of the effort folder (it holds slots.json)
--slot S      a developer seat, status idle, clean worktree; repeatable,
              each once; every seat of one repo

A finished mount's record (HEAD moved and holds every mounted path, as
mount-status.sh says) is removed first, with one stderr line.

refused (exit 5, every problem listed) when: an unfinished mount is
recorded; a seat is not an idle developer, is dirty or has another repo;
the seats' HEADs conflict (tips-merge.sh's line); the checkout is not a
full main checkout at rest; the range holds other work (effort-commits.sh's
line); nothing to mount; a patch path differs in the checkout from the
start (ignored files count), is staged differently from both HEAD and the
start, is a submodule, or holds a newline or non-UTF-8 byte; or git apply
--check fails.

stdout, one JSON line:
  {"mounted":true,"seats":[{"slot":S,"seat_commit":<sha>}...],
   "target":<sha>,"paths":N,"left_alone":M,"line":L}
  M counts the checkout's other uncommitted paths (not ignored); L, for
  the human: "Mounted S + S in <repo>: N files; your other M changed
  files are untouched." (control characters as "?")

exit codes:
  0  mounted
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: a bad option value, slots.json or a seat does not fit
     (slots.sh's own lines first), or the record is unreadable
  4  environment: git, jq or a neighbour missing or failed, a write
     failed, or the applied paths did not verify (the patch was reversed)
  5  refused by state; no file, index or ref is written

needs: POSIX sh, git 2.38+, jq 1.6+; ../seats/slots.sh,
../merge/tips-merge.sh, effort-commits.sh and mount-lib.sh from this
script's folder
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

# Prints $1 with each control character as "?", so a value can't split a stderr line.
printable() {
	printf '%s' "$1" | tr '[:cntrl:]' '?'
}

# Sets $option_value from "$1 $2", refusing a repeat or a missing value.
take_value() {
	[ -n "$3" ] || usage_error "$1 needs a value; expected $1 $4"
	[ -z "$2" ] || usage_error "$1 given twice; expected one"
	option_value=$3
}

parse_args() {
	effort='' slot_given=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" DIR
				effort=${option_value}
				;;
			--slot)
				take_value "$1" '' "${2-}" S
				slot_given=true
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --slot or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort DIR'
	[ "${slot_given}" = true ] || usage_error '--slot missing; expected --slot S'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.38+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	for neighbour in ../seats/slots.sh ../merge/tips-merge.sh effort-commits.sh mount-lib.sh; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
		}
	done
	# shellcheck source=mount-lib.sh
	. "${own_dir}/mount-lib.sh"
}

# Sets effort_dir (physical) and slots_file.
check_effort() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	slots_file="${effort_dir}/slots.json"
}

# Refuses a --slot of the checked command line ("$@") that is no slot name
# or is given twice.
check_slots() {
	seen_slots=' '
	while [ "$#" -gt 0 ]; do
		[ "$1" != --slot ] || check_slot "$2"
		shift 2
	done
}

check_slot() {
	check_slot_name --slot "$1"
	case ${seen_slots} in
		*" $1 "*) die 3 "--slot $1 is given twice; expected each seat once" ;;
		*) seen_slots="${seen_slots}$1 " ;;
	esac
}

# Refuses option $1's value $2 when it is no lowercase word, a dash and a
# number of 1 or more.
check_slot_name() {
	case $2 in
		[a-z]*-[1-9]*)
			case ${2%-*}/${2##*-} in
				*[!a-z0-9]*/* | */*[!0-9]*) ;;
				*) return 0 ;;
			esac
			;;
		*) ;;
	esac
	shown_slot=$(printable "$2")
	die 3 "$1 ${shown_slot} is not allowed; expected a slot name like dev-1"
}

# Reads and checks each --slot of the checked command line ("$@"); writes
# work_dir/seats, "<slot><TAB><worktree><TAB><seat commit>" per developer
# seat, and sets repo to the first one's repo.
read_seats() {
	: >"${work_dir}/seats"
	repo='' shown_seats=''
	while [ "$#" -gt 0 ]; do
		if [ "$1" = --slot ]; then
			slot=$2
			shown_seats="${shown_seats:+${shown_seats} + }${slot}"
			read_seat
			check_seat_state
			check_seat_repo
			check_seat_clean
			[ "${role}" != developer ] ||
				printf '%s\t%s\t%s\n' "${slot}" "${worktree}" "${seat_commit}" >>"${work_dir}/seats"
		fi
		shift 2
	done
}

# Sets role, status, worktree and seat_repo from slots.sh get, and
# seat_commit; slots.sh's own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/slots.sh" get --slots "${slots_file}" --slot "${slot}") || seat_rc=$?
	shown_slot=$(printable "${slot}")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "slots.sh get refused seat ${shown_slot} (exit ${seat_rc}); expected a seat in --effort's slots.json" ;;
		*) die 4 "slots.sh get failed (exit ${seat_rc})" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .status // "", .worktree // "", .repo // ""') ||
		die 4 'jq could not read the seat slots.sh get printed'
	role='' status='' worktree='' seat_repo=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r worktree || :
		IFS= read -r seat_repo || :
	} <<EOF
${fields}
EOF
	[ "${role}" != developer ] || check_seat_worktree
}

# Refuses a developer seat whose worktree and repo git can't read as one
# repository; sets seat_commit.
check_seat_worktree() {
	shown_worktree=$(printable "${worktree}")
	[ -d "${worktree}" ] || die 3 "seat ${shown_slot}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	seat_commit=$(git -C "${worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		die 3 "seat ${shown_slot}'s worktree ${shown_worktree} has no HEAD commit; expected its git worktree"
	seat_common=$(git -C "${worktree}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || seat_common=''
	repo_common=$(git -C "${seat_repo}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || repo_common=''
	[ -n "${seat_common}" ] && [ "${seat_common}" = "${repo_common}" ] || {
		shown_repo=$(printable "${seat_repo}")
		die 3 "seat ${shown_slot}'s worktree ${shown_worktree} is not a worktree of its repo ${shown_repo}; expected one repository"
	}
}

refuse() {
	warn "$1"
	problems=$((problems + 1))
}

check_seat_state() {
	if [ "${role}" != developer ]; then
		refuse "seat ${shown_slot} is not a developer seat; expected a developer's seat"
		return 0
	fi
	case ${status} in
		idle) ;;
		working) refuse "seat ${shown_slot} is working: its developer is busy; expected status idle" ;;
		*) refuse "seat ${shown_slot} is ${status}: it has nothing finished; expected status idle" ;;
	esac
}

# The first developer seat's repo is the mount's; every other must match it.
check_seat_repo() {
	[ "${role}" = developer ] || return 0
	if [ -z "${repo}" ]; then
		repo=${seat_repo}
		return 0
	fi
	[ "${seat_repo}" != "${repo}" ] || return 0
	shown_seat_repo=$(printable "${seat_repo}")
	shown_repo=$(printable "${repo}")
	refuse "seat ${shown_slot}'s repo ${shown_seat_repo} is not the other seats' repo ${shown_repo}; expected seats of one repo"
}

# Lists at most MAX_LISTED of the seat worktree's uncommitted paths; a
# rename's source path is skipped.
check_seat_clean() {
	[ "${role}" = developer ] || return 0
	git -C "${worktree}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all >"${work_dir}/seat-status" 2>"${work_dir}/stderr" ||
		git_failed "git status in the seat's worktree"
	[ -s "${work_dir}/seat-status" ] || return 0
	jq -Rsr --argjson max "${MAX_LISTED}" '[split("\u0000")[] | select(. != "")]
		| reduce .[] as $entry ({paths: [], source_next: false};
			if .source_next then .source_next = false
			else .paths += [$entry[3:]] | .source_next = ($entry[0:2] | test("[RC]")) end)
		| .paths | (.[:$max][] | gsub("[\u0000-\u001f\u007f]"; "?")), (length - $max | select(. > 0) | "... and \(.) more")' \
		"${work_dir}/seat-status" >"${work_dir}/seat-dirty" 2>"${work_dir}/stderr" ||
		git_failed "jq reading the seat's status"
	refuse "seat ${shown_slot}'s worktree ${shown_worktree} has uncommitted changes: the last stop did not commit; expected a clean worktree"
	while IFS= read -r dirty_path; do
		warn "  ${dirty_path}"
	done <"${work_dir}/seat-dirty"
}

# Sets effort_id from slots.json's effort, the value of the seats' Effort
# trailer.
read_effort_id() {
	shown_slots=$(printable "${slots_file}")
	effort_id=$(jq -r '.effort | strings' "${slots_file}" 2>/dev/null) ||
		die 3 "${shown_slots} is not JSON; expected the effort's slots.json"
	[ -n "${effort_id}" ] || die 3 "${shown_slots} has no effort; expected a non-empty effort string"
}

check_no_record() {
	[ -z "${checkout_problem}" ] || return 0
	read_record
	[ "${record_present}" = true ] || return 0
	record_head=$(git -C "${checkout_dir}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		record_head=''
	checkout_states "${work_dir}/spec" "${work_dir}/record-states"
	check_finished "${work_dir}/record-states" "${record_head}"
	if [ "${finished}" = true ]; then
		remove_record
		warn "removed the finished mount of ${rec_slots} (target ${rec_target}): HEAD holds every mounted path"
		return 0
	fi
	shown_rec_effort=$(printable "${rec_effort}")
	refuse "a mount is already recorded in ${shown_record}: effort ${shown_rec_effort}, ${rec_slots}, target ${rec_target}; run unmount.sh first"
}

check_checkout() {
	[ -n "${repo}" ] || return 0
	if [ -n "${checkout_problem}" ]; then
		refuse "the seats' repo ${checkout_problem}"
		return 0
	fi
	problems_before=${problems}
	check_checkout_idle "the main checkout ${shown_checkout}"
	[ "${problems}" -ne "${problems_before}" ] || checkout_ok=true
}

# Sets target to the one seat's HEAD, or tips-merge.sh's merge of every
# seat's HEAD; its conflict line is the refusal.
find_target() {
	seat_count=$(wc -l <"${work_dir}/seats" | tr -d ' ') || die 4 'wc failed counting the seats'
	if [ "${seat_count}" -eq 1 ]; then
		IFS= read -r seat_line <"${work_dir}/seats" || die 4 'could not read the seats in the work folder'
		target=${seat_line##*"${tab}"}
		return 0
	fi
	merge_message="${work_dir}/merge-message"
	printf 'crucible(merge): %s\n\n%s: %s\n' "${shown_seats}" "${EFFORT_TRAILER}" "${effort_id}" >"${merge_message}" ||
		die 4 'could not write the merge message in the work folder'
	set -- --repo "${checkout_dir}" --message-file "${merge_message}"
	while IFS= read -r seat_line; do
		set -- "$@" --commit "${seat_line##*"${tab}"}"
	done <"${work_dir}/seats"
	run_step ../merge/tips-merge.sh "$@"
	case ${step_rc} in
		0) target=$(printf '%s\n' "${step_out}" | jq -r '.commit') || die 4 'jq could not read what tips-merge.sh printed' ;;
		5) problems=$((problems + 1)) ;;
		*) step_failed tips-merge.sh ;;
	esac
}

# Sets start (HEAD, or the snapshot the seats were cut from) and
# start_is_snapshot from effort-commits.sh; its line is the refusal.
check_range() {
	run_step effort-commits.sh --repo "${checkout_dir}" --effort-id "${effort_id}" --from "${head}" --to "${target}"
	case ${step_rc} in
		0) start=$(printf '%s\n' "${step_out}" | jq -r '.start') || die 4 'jq could not read what effort-commits.sh printed' ;;
		5) problems=$((problems + 1)) ;;
		*) step_failed effort-commits.sh ;;
	esac
	start_is_snapshot=false
	[ -z "${start}" ] || [ "${start}" = "${head}" ] || start_is_snapshot=true
}

# Runs neighbour $1, a path from this script's folder, with the rest as
# arguments; its stdout in step_out, its exit code in step_rc; its stderr
# passes through.
run_step() {
	step_rc=0
	step_script=$1
	shift
	step_out=$(sh "${own_dir}/${step_script}" "$@") || step_rc=$?
}

# Exits naming failed neighbour $1: 3 when it refused its input, else 4.
step_failed() {
	case ${step_rc} in
		3) die 3 "$1 refused its input (exit 3); expected the seats' commits in the main checkout's repository" ;;
		*) die 4 "$1 failed (exit ${step_rc})" ;;
	esac
}

# Builds the patch and the spec file (start state, target state, path) from
# the same range and pathspec; sets patch_ok.
build_patch() {
	patch_ok=false
	if [ "${target}" = "${start}" ]; then
		refuse "the work of ${shown_seats} is the start ${start}: nothing to mount"
		return 0
	fi
	# Plumbing diff-tree reads no diff config (prefixes, context, textconv,
	# external drivers), so the patch is the same for every human's setup.
	git -C "${checkout_dir}" -c core.fsmonitor=false diff-tree -r -z --no-renames --no-abbrev "${start}" "${target}" \
		-- . ':(exclude).crucible-effort' >"${work_dir}/raw" 2>"${work_dir}/stderr" ||
		git_failed 'git diff-tree --raw of the seats'
	git -C "${checkout_dir}" -c core.fsmonitor=false diff-tree -r -p --binary --full-index --no-renames "${start}" "${target}" \
		-- . ':(exclude).crucible-effort' >"${work_dir}/patch" 2>"${work_dir}/stderr" ||
		git_failed 'git diff-tree --binary of the seats'
	if [ ! -s "${work_dir}/patch" ] || [ ! -s "${work_dir}/raw" ]; then
		refuse "the commits of ${shown_seats} change nothing outside .crucible-effort since the start ${start}: nothing to mount"
		return 0
	fi
	newlines=$(tr -cd '\n' <"${work_dir}/raw" | wc -c | tr -d ' ') || die 4 'tr or wc failed reading the seats diff'
	[ "${newlines}" -eq 0 ] || {
		refuse "the diff of ${shown_seats} has a path holding a newline; expected paths without one"
		return 0
	}
	# Each raw entry is ":<mode> <mode> <sha> <sha> <status>" then its path.
	tr '\000' '\n' <"${work_dir}/raw" | awk '
		NR % 2 == 1 {
			split(substr($0, 2), f, " ")
			before = (f[1] == "000000" ? "absent" : f[1] " " f[3])
			after = (f[2] == "000000" ? "absent" : f[2] " " f[4])
			next
		}
		{ print before "\t" after "\t" $0 }' >"${work_dir}/spec" || die 4 'tr or awk failed reading the seats diff'
	jq -Rr . "${work_dir}/spec" 2>/dev/null | cmp -s - "${work_dir}/spec" || {
		refuse "the diff of ${shown_seats} has a path that is not valid UTF-8; expected paths the record can hold"
		return 0
	}
	patch_ok=true
}

# Every path must hold its start state in the checkout.
check_paths_unchanged() {
	checkout_states "${work_dir}/spec" "${work_dir}/before-states"
	list_mismatches "${work_dir}/spec" "${work_dir}/before-states" 1 'an untracked file present' "${work_dir}/changed"
	[ -s "${work_dir}/changed" ] || return 0
	problems=$((problems + 1))
	warn_mismatches "${work_dir}/changed" 'the main checkout differs from the start at ' '; expected it as the start holds it'
}

# A staged entry for a path must equal HEAD's or the start's entry.
check_index() {
	git -C "${checkout_dir}" -c core.fsmonitor=false diff-index --cached -z --no-renames --no-abbrev HEAD -- \
		>"${work_dir}/staged" 2>"${work_dir}/stderr" || git_failed 'git diff-index --cached in the main checkout'
	[ -s "${work_dir}/staged" ] || return 0
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rsr --rawfile spec "${work_dir}/spec" '
		($spec | rtrimstr("\n") | split("\n") | map(split("\t") | {key: (.[2:] | join("\t")), value: .[0]}) | from_entries) as $start
		| split("\u0000") as $f
		| range(0; ($f | length) - 1; 2) | {meta: $f[.], path: $f[. + 1]}
		| select($start[.path] != null)
		| (.meta | ltrimstr(":") | split(" ")) as [$head_mode, $index_mode, $head_sha, $index_sha, $change]
		| select($change == "U" or (if $index_mode == "000000" then "absent" else "\($index_mode) \($index_sha)" end) != $start[.path])
		| .path' "${work_dir}/staged" >"${work_dir}/staged-conflicts" 2>"${work_dir}/stderr" ||
		git_failed 'jq reading the staged changes'
	[ -s "${work_dir}/staged-conflicts" ] || return 0
	while IFS= read -r staged_path; do
		shown_path=$(printable "${staged_path}")
		refuse "the main checkout's ${shown_path} is staged differently from both HEAD and the start; expected its staged entry to match one"
	done <"${work_dir}/staged-conflicts"
}

check_no_submodule() {
	while IFS= read -r spec_line; do
		spec_rest=${spec_line#*"${tab}"}
		case ${spec_line%%"${tab}"*}/${spec_rest%%"${tab}"*} in
			160000*/* | */160000*)
				shown_path=$(printable "${spec_rest#*"${tab}"}")
				refuse "the diff of ${shown_seats} changes the submodule ${shown_path}; expected no submodule"
				;;
			*) ;;
		esac
	done <"${work_dir}/spec"
}

check_apply() {
	git -C "${checkout_dir}" -c core.fsmonitor=false apply --check --binary --whitespace=nowarn -- "${work_dir}/patch" \
		>/dev/null 2>"${work_dir}/stderr" || {
		refuse 'git apply --check refused the patch in the main checkout:'
		while IFS= read -r apply_line; do
			shown_line=$(printable "${apply_line}")
			warn "  ${shown_line}"
		done <"${work_dir}/stderr"
	}
}

# Copies the patch into the record folder; sets record_patch.
publish_patch() {
	shown_record_dir=$(printable "${record_dir}")
	mkdir -p -- "${record_dir}" || die 4 "could not create the record folder ${shown_record_dir}"
	patch_temp=$(mktemp "${record_dir}/mount.patch.XXXXXX") || die 4 "could not write in ${shown_record_dir}"
	cp -- "${work_dir}/patch" "${patch_temp}" || die 4 "could not write the patch into ${shown_record_dir}"
	mv -f -- "${patch_temp}" "${record_dir}/mount.patch" || die 4 "could not write the patch into ${shown_record_dir}"
	patch_temp=''
	record_patch="${record_dir}/mount.patch"
}

apply_patch() {
	(umask "${inherited_umask}" && exec git -C "${checkout_dir}" -c core.fsmonitor=false apply --binary --whitespace=nowarn \
		-- "${record_patch}") 2>"${work_dir}/stderr" ||
		git_failed 'git apply in the main checkout'
	applied=true
}

verify_applied() {
	checkout_states "${work_dir}/spec" "${work_dir}/after-states"
	list_mismatches "${work_dir}/spec" "${work_dir}/after-states" 2 'present where the seats have none' "${work_dir}/unverified"
	[ -s "${work_dir}/unverified" ] || return 0
	warn_mismatches "${work_dir}/unverified" 'after applying, the main checkout differs from the target at ' ''
	reverse_patch
	die 4 "the applied paths did not verify; the patch was reversed and nothing is mounted"
}

write_record() {
	mounted_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || die 4 'date could not give the time'
	branch=$(git -C "${checkout_dir}" -c core.fsmonitor=false symbolic-ref -q --short HEAD 2>/dev/null) || branch=''
	record_temp=$(mktemp "${record_dir}/mount.json.XXXXXX") || record_failed
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -nc --arg effort "${effort_dir}" --arg repo "${checkout_dir}" --rawfile seats "${work_dir}/seats" \
		--arg start "${start}" --argjson start_is_snapshot "${start_is_snapshot}" --arg target "${target}" \
		--arg head "${head}" --arg branch "${branch}" --arg mounted_at "${mounted_at}" --rawfile spec "${work_dir}/spec" \
		'{version: 2, effort: $effort, repo: $repo,
		  seats: ($seats | rtrimstr("\n") | split("\n") | map(split("\t") | {slot: .[0], worktree: .[1], seat_commit: .[2]})),
		  start: $start, start_is_snapshot: $start_is_snapshot, target: $target, head: $head,
		  branch: (if $branch == "" then null else $branch end), mounted_at: $mounted_at,
		  paths: ($spec | rtrimstr("\n") | split("\n")
			| map(split("\t") | {path: (.[2:] | join("\t")), before: .[0], after: .[1]}
				| if .before | test("^100(644|755) ") then .saved = true else . end))}' \
		>"${record_temp}" 2>/dev/null || record_failed
	mv -f -- "${record_temp}" "${record_dir}/mount.json" || record_failed
	record_temp='' applied=false
}

record_failed() {
	reverse_patch
	die 4 "could not write the record into ${shown_record_dir}; the patch was reversed and nothing is mounted"
}

# Takes the applied patch out again and drops the saved patch; on failure the
# saved patch stays for the human to reverse by hand.
reverse_patch() {
	[ "${applied}" = true ] || return 0
	applied=false
	if (umask "${inherited_umask}" && exec git -C "${checkout_dir}" -c core.fsmonitor=false apply -R --binary \
		--whitespace=nowarn -- "${record_patch}") 2>"${work_dir}/stderr"; then
		restore_saved_bytes "the raw copies stay in ${shown_record_dir}/before"
		drop_patch
	else
		first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
		shown_patch=$(printable "${record_patch}")
		shown_line=$(printable "${first_line}")
		warn "git apply -R could not reverse the patch: ${shown_line}; reverse it by hand with git apply -R ${shown_patch}"
	fi
}

drop_patch() {
	rm -rf -- "${record_patch}" "${record_dir}/before"
	rmdir -- "${record_dir}" 2>/dev/null || :
}

# Copies, bytes and mode, each checkout file the patch replaces or deletes to
# record_dir/before/<n> (n its spec line, from 0): git apply -R restores
# content, not the human's exact bytes (line endings under eol attributes).
save_before_copies() {
	rm -rf -- "${record_dir}/before"
	: >"${work_dir}/saved"
	mkdir -- "${record_dir}/before" || save_failed
	path_index=0
	while IFS= read -r spec_line; do
		case ${spec_line} in
			100644' '* | 100755' '*)
				saved_path=${spec_line#*"${tab}"}
				cp -p -- "${checkout_dir}/${saved_path#*"${tab}"}" "${record_dir}/before/${path_index}" || save_failed
				printf '%s\t%s\n' "${path_index}" "${saved_path#*"${tab}"}" >>"${work_dir}/saved" || save_failed
				;;
			*) ;;
		esac
		path_index=$((path_index + 1))
	done <"${work_dir}/spec"
}

save_failed() {
	drop_patch
	die 4 "could not save the checkout's files into ${shown_record_dir}/before; nothing was applied"
}

# Counts the checkout's uncommitted paths outside the patch; ignored ones not.
count_left_alone() {
	git -C "${checkout_dir}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all --no-renames \
		>"${work_dir}/checkout-status" 2>"${work_dir}/stderr" || git_failed 'git status in the main checkout (the mount is recorded)'
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	left_alone=$(jq -Rr --rawfile spec "${work_dir}/spec" -s '
		($spec | rtrimstr("\n") | split("\n") | map(split("\t") | {key: (.[2:] | join("\t")), value: true}) | from_entries) as $mounted
		| [split("\u0000")[] | select(length > 3) | .[3:] | select($mounted[.] | not)] | unique | length' \
		"${work_dir}/checkout-status" 2>"${work_dir}/stderr") || git_failed 'jq counting the main checkout status (the mount is recorded)'
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	reverse_patch
	[ -z "${patch_temp}" ] || rm -f -- "${patch_temp}"
	[ -z "${record_temp}" ] || rm -f -- "${record_temp}"
	[ -z "${restore_temp}" ] || rm -f -- "${restore_temp}"
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir='' patch_temp='' record_temp='' restore_temp='' applied=false
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
check_effort
check_slots "$@"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-mount.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
# tips-merge.sh takes only an absolute message file.
physical_work_dir=$(cd -P -- "${work_dir}" && pwd -P) || die 4 'the work folder could not be entered'
work_dir=${physical_work_dir}

# The refusals, in order; a check that needs an earlier one's result is
# skipped when that one failed, which already said why.
problems=0 checkout_ok=false target='' start=''
read_seats "$@"
read_effort_id
seats_ok=false
[ "${problems}" -ne 0 ] || seats_ok=true
locate_checkout "${repo}"
check_no_record
check_checkout
[ "${seats_ok}" = false ] || [ -z "${checkout_dir}" ] || find_target
if [ "${checkout_ok}" = true ] && [ -n "${target}" ]; then
	check_range
	if [ -n "${start}" ]; then
		build_patch
		if [ "${patch_ok}" = true ]; then
			check_paths_unchanged
			check_index
			check_no_submodule
			[ "${problems}" -ne 0 ] || check_apply
		fi
	fi
fi
[ "${problems}" -eq 0 ] || exit 5

publish_patch
save_before_copies
apply_patch
verify_applied
write_record
count_left_alone
paths=$(wc -l <"${work_dir}/spec" | tr -d ' ') || die 4 'wc failed counting the mounted paths'
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
jq -nc --rawfile seats "${work_dir}/seats" --arg target "${target}" --argjson paths "${paths}" --argjson left_alone "${left_alone}" \
	--arg repo "${checkout_dir}" \
	'{mounted: true, seats: ($seats | rtrimstr("\n") | split("\n") | map(split("\t") | {slot: .[0], seat_commit: .[2]})),
	  target: $target, paths: $paths, left_alone: $left_alone}
	| .line = "Mounted \(.seats | map(.slot) | join(" + ")) in \($repo | gsub("[\u0000-\u001f\u007f]"; "?")): \($paths) files;"
		+ " your other \($left_alone) changed files are untouched."' ||
	die 4 'jq could not print the result; the mount is recorded'
