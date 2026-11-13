#!/usr/bin/env sh
# Brings a commit into an idle developer seat's worker branch. A clean merge
# is made by tips-merge.sh as the effort's identity and the branch moves on
# to it, a fast-forward in the seat's clean worktree. A conflicting one is
# started in the worktree with git merge --no-commit, its markers left for
# the seat's developer to resolve; the stop hook then commits the merge.
set -eu
# The checkout writes the seat's files under the caller's own umask.
inherited_umask=$(umask)
umask 077

readonly PROG='catch-up.sh'
readonly EFFORT_TRAILER='Effort'
# The conflict line and the JSON name at most this many files, so a merge
# touching hundreds stays one readable line for the developer and the caller.
readonly MAX_NAMED=20
# From this folder to the effort settings' reader.
readonly SETTINGS='../../../procedure-git-setup/scripts/settings.sh'
readonly VIEW_LIB='human-view'
# The C locale keeps the shell byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside the seat's
# worktree.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

usage() {
	cat <<EOF
usage: sh ${PROG} --effort FOLDER --seat S --with REF [--label NAME]
       sh ${PROG} --help | -h

Brings commit REF into seat S's branch, as the identity settings.sh get
--effort FOLDER prints, signed with its key when it has one. When S's HEAD
already holds REF, nothing is written. A clean merge is one commit,
"crucible(sync): S takes <NAME or short sha>", trailer ${EFFORT_TRAILER} (the
effort's name) and no Agent-Seat, so iteration.sh does not count it; S's
branch moves on to it in S's worktree, and tips-merge.sh's UNSIGNED: line
passes through. A conflict is left as a merge under way in S's worktree,
its markers in the files; nothing is committed. No repository hook or
rerere runs. It writes only S's branch, S's worktree and git objects in S's
repository; exits 2, 3 and 5 change nothing, and no event is written.
Nothing else is left behind (a SIGKILL aside).

--effort FOLDER  the effort folder, absolute
--seat S         a developer seat, status idle (not chosen), whose worktree
                 has HEAD on a branch, no change and no merge, pick or
                 rebase under way
--with REF       a commit sha or a ref name of S's repository (a branch,
                 a remote-tracking branch such as origin/main, a tag),
                 resolved there with git rev-parse --verify 'REF^{commit}';
                 not starting with -; fetching a remote one is the caller's
--label NAME     what REF is for the human; one line; default REF when it
                 is a name, else its short sha

stdout, one JSON line:
  {"caught_up":false,"seat":S,"reason":"in_sync"}           nothing written
  {"caught_up":true,"seat":S,"commit":<sha>,"line":L}
  {"caught_up":false,"seat":S,"reason":"conflict","conflicts":[<path>...],
   "conflicts_not_shown":N,"message":M}
  L, for the human: the seat's name for the human and "caught up" as a
  bold title, then "now also holds NAME (abc1234), merged at <short sha>",
  or "now holds NAME (abc1234) as it is" when S had nothing of its own.
  conflicts: the first ${MAX_NAMED} conflicting files; N, how many more.
  M is the line to send S's developer: what S takes in, the files that
  conflict (at most ${MAX_NAMED} named), "resolve each file, remove every
  marker, and keep the rest of your work; the stop hook commits the merge."

exit codes:
  0  in sync, caught up, or a conflict left for S's developer; read the
     JSON line
  2  wrong command line, nothing changed; show the human stderr, and stop
  3  input does not fit, nothing changed; show the human stderr, and stop
  4  environment, git or a neighbour failed, S's branch possibly moved
     already; show the human stderr, and stop
  5  refused by S's state, nothing changed; show the human stderr, and stop

needs: POSIX sh, git 2.38+, jq 1.6+; tips-merge.sh, ../seats/seats.sh and
../worktree/uncommitted.jq from this script's folder; procedure-git-setup's
settings.sh beside procedure-git-worktree; ${VIEW_LIB}'s title.jq and
view.jq in ${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/${VIEW_LIB}
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
	effort='' seat='' with='' label=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				take_value "$1" "${effort}" "${2-}" FOLDER
				effort=${option_value}
				;;
			--seat)
				take_value "$1" "${seat}" "${2-}" S
				seat=${option_value}
				;;
			--with)
				take_value "$1" "${with}" "${2-}" REF
				with=${option_value}
				;;
			--label)
				take_value "$1" "${label}" "${2-}" NAME
				label=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --effort, --seat, --with, --label or --help"
				;;
		esac
		shift 2
	done
	[ -n "${effort}" ] || usage_error '--effort missing; expected --effort FOLDER'
	[ -n "${seat}" ] || usage_error '--seat missing; expected --seat S'
	[ -n "${with}" ] || usage_error '--with missing; expected --with REF'
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
	for neighbour in tips-merge.sh ../seats/seats.sh ../worktree/uncommitted.jq "${SETTINGS}"; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folders whole"
		}
	done
	view_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${VIEW_LIB}"
	for view_module in title.jq view.jq; do
		[ -f "${view_dir}/${view_module}" ] || {
			shown_view_dir=$(printable "${view_dir}")
			die 4 "${view_module} not found in ${shown_view_dir}; expected the ${VIEW_LIB} skill installed"
		}
	done
}

# Refuses a --with that git could read as an option and a --label that is
# not one line.
check_values() {
	shown_with=$(printable "${with}")
	case ${with} in
		-*) die 3 "--with ${shown_with} starts with -; expected a commit sha or ref name" ;;
		*) ;;
	esac
	case ${label} in
		*[[:cntrl:]]*) die 3 '--label holds a line break or control character; expected one line' ;;
		*) ;;
	esac
}

# Sets effort_dir (physical).
check_effort() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
}

# Sets role, status and worktree of the seat from seats.sh get; seats.sh's
# own lines say why it refused.
read_seat() {
	seat_rc=0
	seat_json=$(sh "${own_dir}/../seats/seats.sh" get --effort "${effort_dir}" --seat "${seat}") || seat_rc=$?
	shown_seat=$(printable "${seat}")
	case ${seat_rc} in
		0) ;;
		2 | 3 | 6) die 3 "seats.sh get refused seat ${shown_seat} (exit ${seat_rc}); expected a seat of --effort" ;;
		*) die 4 "seats.sh get failed (exit ${seat_rc}; its stderr is above); expected the seat's JSON line; fix what it names and rerun" ;;
	esac
	fields=$(printf '%s\n' "${seat_json}" | jq -r '.role // "", .status // "", .worktree // ""') ||
		die 4 'jq could not read the seat seats.sh get printed'
	role='' status='' worktree=''
	{
		IFS= read -r role || :
		IFS= read -r status || :
		IFS= read -r worktree || :
	} <<EOF
${fields}
EOF
}

# Refuses a seat that is no idle developer with a clean worktree on its
# branch and nothing under way; sets seat_worktree, seat_ref and seat_head.
check_seat() {
	read_seat
	[ "${role}" = developer ] || die 5 "seat ${shown_seat} is a ${role} seat; expected a developer seat"
	[ "${status}" != chosen ] || die 5 "seat ${shown_seat} is chosen: its worktree is not made yet; expected status idle"
	seat_worktree=${worktree}
	shown_worktree=$(printable "${seat_worktree}")
	[ -d "${seat_worktree}" ] || die 3 "seat ${shown_seat}'s worktree ${shown_worktree} is not a folder; expected its git worktree"
	seat_ref=$(git -C "${seat_worktree}" symbolic-ref -q HEAD 2>/dev/null) ||
		die 3 "seat ${shown_seat}'s worktree ${shown_worktree} has a detached HEAD; expected HEAD on its branch"
	seat_head=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) ||
		die 3 "seat ${shown_seat}'s worktree ${shown_worktree} has no HEAD commit; expected HEAD on its branch at a commit"
	problems=0
	case ${status} in
		idle) ;;
		working) refuse "seat ${shown_seat} is working: its developer is busy; expected status idle" ;;
		*) refuse "seat ${shown_seat} is ${status}; expected status idle" ;;
	esac
	check_no_operation
	list_uncommitted
	[ ! -s "${work_dir}/seat-dirty" ] ||
		refuse "seat ${shown_seat}'s worktree ${shown_worktree} has uncommitted changes; expected a clean worktree"
	[ "${problems}" -eq 0 ] || exit 5
}

refuse() {
	warn "$1"
	problems=$((problems + 1))
}

# Refuses a worktree with a merge, pick, revert or rebase under way.
check_no_operation() {
	for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
		state_path=$(git -C "${seat_worktree}" rev-parse --path-format=absolute --git-path "${state}" 2>"${work_dir}/stderr") ||
			git_failed 'git rev-parse --git-path'
		[ ! -e "${state_path}" ] ||
			refuse "seat ${shown_seat}'s worktree ${shown_worktree} has ${state} under way; expected no merge, pick or rebase"
	done
}

# Writes to work_dir/seat-dirty the seat worktree's uncommitted paths, one
# per line, as uncommitted.jq gives them.
list_uncommitted() {
	git -C "${seat_worktree}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all \
		>"${work_dir}/seat-status" 2>"${work_dir}/stderr" || git_failed "git status in the seat's worktree"
	jq -Rsr -L "${own_dir}/../worktree" 'include "uncommitted"; uncommitted_paths' \
		"${work_dir}/seat-status" >"${work_dir}/seat-dirty" 2>"${work_dir}/stderr" ||
		git_failed "jq reading the seat's status"
}

# Sets with_commit to --with's full sha, label to --with when it named a ref
# and no --label was given, and taken to what the seat takes in, for the
# human: "NAME (short)" or the short sha. A --with that is a prefix of the
# sha it resolves to was a sha, not a name.
resolve_with() {
	with_commit=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet --end-of-options "${with}^{commit}" 2>/dev/null) ||
		die 3 "--with ${shown_with} is no commit or ref name in seat ${shown_seat}'s repository; expected one there (fetch a remote one first)"
	short_sha "${with_commit}"
	with_short=${short}
	case ${with_commit} in
		"${with}"*) ;;
		*) label=${label:-${with}} ;;
	esac
	taken=${with_short}
	[ -z "${label}" ] || taken="${label} (${with_short})"
}

# Sets effort_id from the seat list's effort, the value of the Effort
# trailer.
read_effort_id() {
	seat_list=$(sh "${own_dir}/../seats/seats.sh" list --effort "${effort_dir}") ||
		die 4 'seats.sh list failed (its stderr is above); expected the seat list'
	effort_id=$(printf '%s\n' "${seat_list}" | jq -r '.effort | strings') ||
		die 4 'jq could not read the seat list seats.sh list printed'
	[ -n "${effort_id}" ] || die 4 'seats.sh list printed no effort; expected a non-empty effort string'
}

# Sets the identity_* variables from settings.sh get for the effort; its
# own lines say why it refused.
read_identity() {
	run_step "${SETTINGS}" get --effort "${effort_dir}"
	case ${step_rc} in
		0) ;;
		3 | 5) die 3 "settings.sh get refused the effort (exit ${step_rc}); expected its git setup" ;;
		*) die 4 "settings.sh get failed (exit ${step_rc}; its stderr is above); expected the effort's identity; fix what it names and rerun" ;;
	esac
	identity_name='' identity_email='' signing_format='' signing_key=''
	while IFS= read -r setting; do
		case ${setting} in
			NAME=*) identity_name=${setting#NAME=} ;;
			EMAIL=*) identity_email=${setting#EMAIL=} ;;
			SIGNING_FORMAT=*) signing_format=${setting#SIGNING_FORMAT=} ;;
			SIGNING_KEY=*) signing_key=${setting#SIGNING_KEY=} ;;
			*) ;;
		esac
	done <<EOF
${step_out}
EOF
	[ -n "${identity_name}" ] && [ -n "${identity_email}" ] ||
		die 4 'settings.sh get printed no NAME or EMAIL line; expected both'
}

# Merges the seat's HEAD with the commit; sets merge_rc (0 merged, 5
# conflict), merge_commit and merge_new.
merge_with() {
	merge_message="${work_dir}/sync-message"
	printf 'crucible(sync): %s takes %s\n\n%s: %s\n' "${seat}" "${label:-${with_short}}" \
		"${EFFORT_TRAILER}" "${effort_id}" >"${merge_message}" ||
		die 4 'could not write the merge message in the work folder'
	set -- --repo "${seat_worktree}" --commit "${seat_head}" --commit "${with_commit}" \
		--identity-name "${identity_name}" --identity-email "${identity_email}"
	[ -z "${signing_key}" ] || set -- "$@" --signing-format "${signing_format}" --signing-key "${signing_key}"
	run_step tips-merge.sh "$@" --message-file "${merge_message}" 2>"${work_dir}/tips-stderr"
	merge_rc=${step_rc}
	# Its conflict line says nothing was changed; the merge in the worktree
	# comes next, so only its other lines pass through.
	[ "${step_rc}" -eq 5 ] || cat "${work_dir}/tips-stderr" >&2
	case ${step_rc} in
		0) ;;
		5) return 0 ;;
		*) step_failed tips-merge.sh ;;
	esac
	merge_commit=$(printf '%s\n' "${step_out}" | jq -r '.commit') || die 4 'jq could not read what tips-merge.sh printed'
	merge_new=$(printf '%s\n' "${step_out}" | jq -r '.new') || die 4 'jq could not read what tips-merge.sh printed'
}

# Sets short to the abbreviated sha of commit $1.
short_sha() {
	short=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --short "$1" 2>"${work_dir}/stderr") ||
		git_failed 'git rev-parse --short'
}

# Fast-forwards the seat's branch to the merge in its worktree, then proves
# HEAD is still on that branch, at the merge, and the worktree clean.
move_branch() {
	(umask "${inherited_umask}" && exec git -C "${seat_worktree}" -c core.hooksPath=/dev/null -c core.fsmonitor=false \
		merge --ff-only --quiet --no-verify-signatures --no-autostash "${merge_commit}" </dev/null) \
		>/dev/null 2>"${work_dir}/stderr" ||
		git_failed "the fast-forward of the seat's branch to the merge"
	check_on_branch 'the fast-forward'
	now_head=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || now_head=''
	[ "${now_head}" = "${merge_commit}" ] ||
		die 4 "seat ${seat}'s branch is at ${now_head:-none} after the fast-forward, not the merge ${merge_commit}"
	list_uncommitted
	[ ! -s "${work_dir}/seat-dirty" ] ||
		die 4 "seat ${seat}'s worktree is not clean after the fast-forward to the merge ${merge_commit}"
}

# Dies when the worktree's HEAD left the seat's branch during step $1.
check_on_branch() {
	now_ref=$(git -C "${seat_worktree}" symbolic-ref -q HEAD 2>/dev/null) || now_ref=''
	[ "${now_ref}" = "${seat_ref}" ] ||
		die 4 "seat ${seat}'s worktree HEAD left its branch ${seat_ref#refs/heads/} during $1"
}

print_caught_up() {
	short_sha "${merge_commit}"
	jq -nc -L "${view_dir}" --arg seat "${seat}" --arg commit "${merge_commit}" --arg taken "${taken}" \
		--arg short "${short}" --argjson new "${merge_new}" \
		'include "title";
		include "view";
		{caught_up: true, seat: $seat, commit: $commit,
		 line: status_line("done"; "\($seat | seat_display) caught up";
			if $new then "now also holds \($taken), merged at \($short)" else "now holds \($taken) as it is" end)}' ||
		die 4 "jq could not print the result; expected jq 1.6+ and ${VIEW_LIB}'s title.jq and view.jq"
}

# Starts the merge in the seat's worktree and leaves its conflicts there;
# writes work_dir/conflicts, the unmerged paths NUL-separated.
start_conflicted_merge() {
	merge_start_rc=0
	(umask "${inherited_umask}" && exec env GIT_AUTHOR_NAME="${identity_name}" GIT_AUTHOR_EMAIL="${identity_email}" \
		GIT_COMMITTER_NAME="${identity_name}" GIT_COMMITTER_EMAIL="${identity_email}" \
		git -C "${seat_worktree}" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c rerere.enabled=false \
		merge --no-ff --no-commit --no-verify-signatures --no-autostash --quiet "${with_commit}" </dev/null) \
		>/dev/null 2>"${work_dir}/stderr" || merge_start_rc=$?
	check_on_branch 'the merge'
	merge_head=$(git -C "${seat_worktree}" -c core.fsmonitor=false rev-parse --verify --quiet MERGE_HEAD 2>/dev/null) || merge_head=''
	[ "${merge_head}" = "${with_commit}" ] ||
		git_failed "git merge --no-commit (exit ${merge_start_rc}) left no merge of ${with_short} under way"
	git -C "${seat_worktree}" -c core.fsmonitor=false diff --name-only --diff-filter=U -z \
		>"${work_dir}/conflicts" 2>"${work_dir}/stderr" || git_failed 'git diff --diff-filter=U'
	[ -s "${work_dir}/conflicts" ] || abort_merge
}

# tips-merge.sh saw a conflict that git merge did not: the merge is undone,
# so nothing is left half-done for the developer.
abort_merge() {
	git -C "${seat_worktree}" -c core.hooksPath=/dev/null -c core.fsmonitor=false merge --abort </dev/null \
		>/dev/null 2>&1 || warn "git merge --abort failed; seat ${seat}'s worktree may still hold the merge of ${with_short}"
	die 4 "git merge of ${with_short} left no conflicted file though tips-merge.sh found a conflict; the merge is aborted"
}

print_conflict() {
	jq -Rsc --arg seat "${seat}" --arg taken "${taken}" --argjson max "${MAX_NAMED}" \
		'split("\u0000") | map(select(. != "")) as $paths
		| ($paths[:$max] | join(", ")) as $named
		| (if ($paths | length) > $max then "\($named) and \(($paths | length) - $max) more" else $named end) as $files
		| {caught_up: false, seat: $seat, reason: "conflict", conflicts: $paths[:$max],
		   conflicts_not_shown: ([($paths | length) - $max, 0] | max),
		   message: "Your seat \($seat) takes in \($taken), and these files conflict: \($files). Resolve each file, remove every marker, and keep the rest of your work; the stop hook commits the merge."}' \
		"${work_dir}/conflicts" || die 4 'jq could not print the result; expected jq 1.6+'
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
		3) die 3 "$1 refused its input (exit 3; its stderr is above); expected seat ${seat} and --with to fit; fix what it names and rerun" ;;
		*) die 4 "$1 failed (exit ${step_rc}; its stderr is above); expected the merge's JSON line; fix what it names and rerun" ;;
	esac
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
check_values
check_effort
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-catch-up.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
# tips-merge.sh takes only an absolute message file.
physical_work_dir=$(cd -P -- "${work_dir}" && pwd -P) || die 4 'the work folder could not be entered'
work_dir=${physical_work_dir}

check_seat
resolve_with
holds_rc=0
git -C "${seat_worktree}" -c core.fsmonitor=false merge-base --is-ancestor "${with_commit}" "${seat_head}" \
	2>"${work_dir}/stderr" || holds_rc=$?
[ "${holds_rc}" -le 1 ] || git_failed 'git merge-base --is-ancestor'
if [ "${holds_rc}" -eq 0 ]; then
	jq -nc --arg seat "${seat}" '{caught_up: false, seat: $seat, reason: "in_sync"}' || die 4 'jq could not print the result'
	exit 0
fi
read_effort_id
read_identity
merge_with
if [ "${merge_rc}" -eq 0 ]; then
	move_branch
	print_caught_up
	exit 0
fi
start_conflicted_merge
print_conflict
