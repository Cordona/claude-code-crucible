#!/usr/bin/env sh
# Gives the base a new developer seat starts at, as its caller chose it:
# independent (the checkout's HEAD, or a snapshot of it), or on the work of
# one or more idle seats (one seat's HEAD, or tips-merge.sh's merge of
# several). It never chooses; it writes no ref and no file, only git
# objects (the merge commit, or what a conflicting merge leaves).
set -eu
umask 077

readonly PROG='seat-base.sh'
readonly tab='	'
readonly EFFORT_TRAILER='Effort'
readonly SNAPSHOT_MESSAGE='crucible(snapshot): uncommitted changes'
readonly SNAPSHOT_AUTHOR='crucible'
readonly SNAPSHOT_EMAIL='crucible@crucible.invalid'
readonly VIEW_LIB='human-view'
# The line shows this many characters of the base's sha.
readonly SHORT_SHA_LENGTH=7
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --effort DIR --repo DIR --seat S --independent [--snapshot SHA]
       sh ${PROG} --effort DIR --repo DIR --seat S --on S [--on S]...
       sh ${PROG} --help | -h

Prints the base for ../seats/seats.sh choose's --base and --base-seat.

--effort DIR    absolute path of the effort folder (its seats.json may not
                exist yet)
--repo DIR      absolute path of the main checkout's top folder
--seat S        the seat this base is for, as ../seats/seat-name.sh named
                it; it need not be in seats.json yet and is no --on seat
--independent   base: --snapshot, else the checkout's HEAD; every idle
                developer seat of --repo whose HEAD is neither its base
                nor in the checkout's HEAD is listed in unmerged
--snapshot SHA  snapshot.sh's commit of the checkout (its subject
                "${SNAPSHOT_MESSAGE}", author ${SNAPSHOT_AUTHOR}
                <${SNAPSHOT_EMAIL}>, one parent: HEAD); --independent only
--on S          an idle developer seat of --repo; repeatable, each once.
                base: the one seat's HEAD, or ../merge/tips-merge.sh's
                merge of every seat's HEAD (message "crucible(merge): S +
                S", trailer ${EFFORT_TRAILER}: seats.json's effort)

stdout, one JSON line:
  {"base":<sha>,"base_seats":[S...],"unmerged":[S...],"line":L}
  base_seats: the --on seats in order ([] when independent); L, for the
  human, starts with --seat's name as the human sees it, like "Software
  developer Beta: ", then "Starts from your checkout (<short sha>).",
  with --snapshot "Starts from your checkout with your uncommitted
  changes (<short sha>).", or "Starts from Software developer Alpha +
  ... (<short sha>)."; a short sha is the first ${SHORT_SHA_LENGTH} characters

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, a missing
     value, --independent with --on or neither, or --snapshot with --on
  3  input: a bad option value, --seat also given as --on, an --on seat
     not in seats.json, seats.json does not fit (seats.sh's own lines
     first), or --snapshot is no snapshot of HEAD
  4  environment: git, jq, ${VIEW_LIB} or a neighbour missing or failed
  5  refused by state, no file or ref written: an --on seat is no developer,
     of another repo, chosen (no worktree yet) or not idle, or the HEADs
     conflict (tips-merge.sh's line)

needs: POSIX sh, git 2.38+, jq 1.6+; ../seats/seats.sh, ../seats/seats.jq and
../merge/tips-merge.sh from this script's folder; ${VIEW_LIB}'s title.jq in
${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${VIEW_LIB}
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
	effort='' repo='' seat='' snapshot='' independent=no on_seats=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--independent)
				[ "${independent}" = no ] || usage_error '--independent given twice; expected one'
				independent=yes
				shift
				continue
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" DIR
				effort=${option_value}
				;;
			--repo)
				take_value "$1" "${repo}" "${2-}" DIR
				repo=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--snapshot)
				take_value "$1" "${snapshot}" "${2-}" SHA
				snapshot=${option_value}
				;;
			--on)
				take_value "$1" '' "${2-}" S
				add_on_seat "${option_value}"
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --repo, --seat, --independent, --on, --snapshot or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort DIR'
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
	if [ "${independent}" = yes ]; then
		[ -z "${on_seats}" ] || usage_error '--independent given with --on; expected one of them'
	else
		[ -n "${on_seats}" ] || usage_error '--independent or --on missing; expected one of them'
		[ -z "${snapshot}" ] || usage_error '--snapshot given with --on; expected it with --independent only'
	fi
}

# Adds seat $1 to on_seats, one per line, refusing a repeat; check_names
# checks the name.
add_on_seat() {
	case "
${on_seats}
" in
		*"
$1
"*)
			shown_seat=$(printable "$1")
			die 3 "--on ${shown_seat} is given twice; expected each seat once"
			;;
		*) on_seats="${on_seats:+${on_seats}
}$1" ;;
	esac
}

# Refuses a --seat or --on value that is no seat name by seats.jq, and a
# --seat given as --on too.
check_names() {
	check_seat_name --seat "${seat}"
	[ -n "${on_seats}" ] || return 0
	while IFS= read -r on_seat; do
		check_seat_name --on "${on_seat}"
		[ "${on_seat}" != "${seat}" ] || die 3 "--seat ${on_seat} is also given as --on; expected a seat cut from other seats"
	done <<EOF
${on_seats}
EOF
}

# Refuses option $1's value $2 with seats.jq's own problem line.
check_seat_name() {
	name_problem=$(jq -nr -L "${own_dir}/../seats" --arg name "$2" 'include "seats"; $name | seats_name_problem' </dev/null) ||
		die 4 'jq failed checking a seat name; expected jq 1.6+ and ../seats/seats.jq'
	[ -n "${name_problem}" ] || return 0
	shown_problem=$(printable "${name_problem}")
	die 3 "$1 ${shown_problem}"
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
	for neighbour in ../seats/seats.sh ../seats/seats.jq ../merge/tips-merge.sh; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
		}
	done
	view_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${VIEW_LIB}"
	[ -f "${view_dir}/title.jq" ] || {
		shown_view_dir=$(printable "${view_dir}")
		die 4 "title.jq not found in ${shown_view_dir}; expected the ${VIEW_LIB} skill installed"
	}
}

# Sets effort_dir (physical), seats_file, repo_dir (physical) and head.
check_inputs() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	seats_file="${effort_dir}/seats.json"
	shown_seats=$(printable "${seats_file}")
	shown_repo=$(printable "${repo}")
	case ${repo} in
		/*) ;;
		*) die 3 "--repo ${shown_repo} is not absolute; expected an absolute path" ;;
	esac
	repo_dir=$(cd -P -- "${repo}" 2>/dev/null && pwd -P) ||
		die 3 "--repo ${shown_repo} is not a folder; expected the main checkout's top folder"
	head=$(git -C "${repo_dir}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		die 3 "--repo ${shown_repo} has no HEAD commit; expected a main checkout on a commit"
}

# Refuses a --snapshot that is not snapshot.sh's commit on HEAD; sets base.
check_snapshot() {
	shown_snapshot=$(printable "${snapshot}")
	base=$(git -C "${repo_dir}" -c core.fsmonitor=false rev-parse --verify --quiet --end-of-options "${snapshot}^{commit}" 2>/dev/null) ||
		die 3 "--snapshot ${shown_snapshot} is not a commit in ${shown_repo}; expected snapshot.sh's sha"
	snapshot_info=$(git -C "${repo_dir}" -c core.fsmonitor=false log -1 --no-show-signature --format='%an%n%ae%n%P%n%s' "${base}" -- \
		2>"${work_dir}/stderr") || git_failed "git log of the snapshot ${base}"
	snapshot_name='' snapshot_email='' snapshot_parents='' snapshot_subject=''
	{
		IFS= read -r snapshot_name || :
		IFS= read -r snapshot_email || :
		IFS= read -r snapshot_parents || :
		IFS= read -r snapshot_subject || :
	} <<EOF
${snapshot_info}
EOF
	[ "${snapshot_subject}" = "${SNAPSHOT_MESSAGE}" ] && [ "${snapshot_name}" = "${SNAPSHOT_AUTHOR}" ] &&
		[ "${snapshot_email}" = "${SNAPSHOT_EMAIL}" ] && [ "${snapshot_parents}" = "${head}" ] ||
		die 3 "--snapshot ${base} is not a snapshot of HEAD ${head}; expected snapshot.sh's sha for --repo"
}

# Writes work_dir/unmerged, one seat per idle developer seat of the repo
# whose HEAD is neither its base nor in the checkout's HEAD.
list_unmerged() {
	: >"${work_dir}/unmerged"
	[ -e "${seats_file}" ] || return 0
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -r '.seats[] | select(.role == "developer" and .status == "idle")
		| [.seat, .worktree, .repo, .base] | map(strings) | select(length == 4) | join("\t")' "${seats_file}" \
		>"${work_dir}/idle" 2>/dev/null || die 3 "${shown_seats} is not the effort's seats.json; expected its seats"
	while IFS= read -r idle_line; do
		idle_seat=${idle_line%%"${tab}"*}
		idle_rest=${idle_line#*"${tab}"}
		idle_worktree=${idle_rest%%"${tab}"*}
		idle_rest=${idle_rest#*"${tab}"}
		idle_base=${idle_rest#*"${tab}"}
		same_repo "${idle_rest%%"${tab}"*}"
		[ "${is_same_repo}" = true ] || continue
		[ -d "${idle_worktree}" ] || continue
		idle_head=$(git -C "${idle_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
			continue
		[ "${idle_head}" != "${idle_base}" ] || continue
		is_ancestor "${idle_head}" "${head}"
		[ "${ancestor}" = true ] || printf '%s\n' "${idle_seat}" >>"${work_dir}/unmerged"
	done <"${work_dir}/idle"
}

# Sets is_same_repo to whether folder $1 is --repo's folder.
same_repo() {
	is_same_repo=false
	seat_repo_dir=$(cd -P -- "$1" 2>/dev/null && pwd -P) || return 0
	[ "${seat_repo_dir}" != "${repo_dir}" ] || is_same_repo=true
}

# Sets ancestor to whether commit $1 is an ancestor of commit $2.
is_ancestor() {
	ancestor_rc=0
	git -C "${repo_dir}" -c core.fsmonitor=false merge-base --is-ancestor "$1" "$2" 2>"${work_dir}/stderr" || ancestor_rc=$?
	case ${ancestor_rc} in
		0) ancestor=true ;;
		1) ancestor=false ;;
		*) git_failed 'git merge-base --is-ancestor' ;;
	esac
}

refuse() {
	warn "$1"
	problems=$((problems + 1))
}

# Writes work_dir/on-heads, one HEAD per --on seat that fits, in order;
# refuses each that does not.
read_on_seats() {
	: >"${work_dir}/on-heads"
	while IFS= read -r on_seat; do
		read_on_seat "${on_seat}"
	done <<EOF
${on_seats}
EOF
}

read_on_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --seats "${seats_file}" --seat "$1" 2>"${work_dir}/get-stderr") || seat_rc=$?
	case ${seat_rc} in
		0) ;;
		6) die 3 "--on $1 is not in ${shown_seats}; expected an existing developer seat" ;;
		*)
			cat -- "${work_dir}/get-stderr" >&2 || :
			case ${seat_rc} in
				2 | 3) die 3 "seats.sh get refused seat $1 (exit ${seat_rc}); expected a seat in --effort's seats.json" ;;
				*) die 4 "seats.sh get failed (exit ${seat_rc})" ;;
			esac
			;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .status // "", .worktree // "", .repo // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	role='' status='' worktree='' seat_repo=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r worktree || :
		IFS= read -r seat_repo || :
	} <<EOF
${fields}
EOF
	check_on_seat "$1"
}

# Refuses seat $1 when it is no idle developer of --repo with a HEAD;
# otherwise adds its HEAD to work_dir/on-heads.
check_on_seat() {
	if [ "${role}" != developer ]; then
		refuse "seat $1 is a ${role} seat; expected a developer seat"
		return 0
	fi
	same_repo "${seat_repo}"
	if [ "${is_same_repo}" = false ]; then
		shown_seat_repo=$(printable "${seat_repo}")
		refuse "seat $1's repo ${shown_seat_repo} is not --repo ${shown_repo}; expected a seat of --repo"
		return 0
	fi
	case ${status} in
		idle) ;;
		chosen)
			refuse "seat $1 is chosen: its worktree is not made yet; expected status idle"
			return 0
			;;
		working) refuse "seat $1 is working: its developer is busy; expected status idle" ;;
		*) refuse "seat $1 is ${status}: it has nothing finished; expected status idle" ;;
	esac
	shown_worktree=$(printable "${worktree}")
	seat_head=''
	[ ! -d "${worktree}" ] ||
		seat_head=$(git -C "${worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		seat_head=''
	if [ -z "${seat_head}" ]; then
		refuse "seat $1's worktree ${shown_worktree} has no HEAD commit; expected its git worktree"
		return 0
	fi
	printf '%s\n' "${seat_head}" >>"${work_dir}/on-heads"
}

# Sets base to the one --on seat's HEAD, or tips-merge.sh's merge of all.
merge_on_seats() {
	set --
	while IFS= read -r on_head; do
		set -- "$@" --commit "${on_head}"
	done <"${work_dir}/on-heads"
	if [ "$#" -eq 2 ]; then
		base=$2
		return 0
	fi
	read_effort_id
	joined_seats=''
	while IFS= read -r on_seat; do
		joined_seats="${joined_seats:+${joined_seats} + }${on_seat}"
	done <<EOF
${on_seats}
EOF
	merge_message="${work_dir}/merge-message"
	printf 'crucible(merge): %s\n\n%s: %s\n' "${joined_seats}" "${EFFORT_TRAILER}" "${effort_id}" >"${merge_message}" ||
		die 4 'could not write the merge message in the work folder'
	step_rc=0
	step_out=$(sh "${own_dir}/../merge/tips-merge.sh" --repo "${repo_dir}" "$@" --message-file "${merge_message}") || step_rc=$?
	case ${step_rc} in
		0) ;;
		3) die 3 'tips-merge.sh refused its input (exit 3); expected the seats'\'' commits in --repo' ;;
		5) exit 5 ;;
		*) die 4 "tips-merge.sh failed (exit ${step_rc})" ;;
	esac
	base=$(printf '%s\n' "${step_out}" | jq -r '.commit') || die 4 'jq could not read what tips-merge.sh printed'
}

# Sets effort_id from seats.json's effort, the value of the seats' Effort
# trailer.
read_effort_id() {
	effort_id=$(jq -r '.effort | strings' "${seats_file}" 2>/dev/null) ||
		die 3 "${shown_seats} is not JSON; expected the effort's seats.json"
	[ -n "${effort_id}" ] || die 3 "${shown_seats} has no effort; expected a non-empty effort string"
}

# Exits 4 naming step $1 and the first line of work_dir/stderr.
git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
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

parse_args "$@"
load_dependencies
check_names
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-seat-base.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
# tips-merge.sh takes only an absolute message file.
physical_work_dir=$(cd -P -- "${work_dir}" && pwd -P) || die 4 'the work folder could not be entered'
work_dir=${physical_work_dir}
check_inputs

if [ "${independent}" = yes ]; then
	base=${head}
	[ -z "${snapshot}" ] || check_snapshot
	list_unmerged
	: >"${work_dir}/base-seats"
else
	problems=0
	read_on_seats
	[ "${problems}" -eq 0 ] || exit 5
	merge_on_seats
	: >"${work_dir}/unmerged"
	printf '%s\n' "${on_seats}" >"${work_dir}/base-seats" || die 4 'could not write the base seats in the work folder'
fi
jq -nc -L "${view_dir}" --arg base "${base}" --arg snapshot "${snapshot}" --arg seat "${seat}" \
	--argjson short_length "${SHORT_SHA_LENGTH}" --rawfile base_seats "${work_dir}/base-seats" --rawfile unmerged "${work_dir}/unmerged" '
	include "title";
	def lines: rtrimstr("\n") | if . == "" then [] else split("\n") end;
	{base: $base, base_seats: ($base_seats | lines), unmerged: ($unmerged | lines)}
	| .line = "\($seat | seat_display): Starts from \(if .base_seats != [] then .base_seats | map(seat_display) | join(" + ")
		elif $snapshot != "" then "your checkout with your uncommitted changes" else "your checkout" end) (\($base[:$short_length]))."' ||
	die 4 "jq could not print the result; expected jq 1.6+ and ${VIEW_LIB}'s title.jq"
