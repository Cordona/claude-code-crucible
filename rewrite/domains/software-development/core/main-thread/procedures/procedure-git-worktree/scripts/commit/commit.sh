#!/usr/bin/env sh
# Commits one agent's work in its linked worktree, on the worktree's own
# branch: exactly the given paths, or every change git sees but other seats'
# folders, with a message file written beforehand, authored, committed and,
# with a key, signed by the effort's identity, then proves the commit is the
# one asked for. It never writes the message or pushes. It refuses a main
# checkout, a HEAD on any other branch and an index something else already
# staged, before it touches anything. A signing failure never loses the work:
# the commit is made again unsigned and says why. A seat's own folder is
# staged past the repo's ignore rules: they are written for the repo's code,
# and must not drop a seat's dispatch, report or logs.
set -eu
umask 077

readonly PROG='commit.sh'
# Bounds stderr so a refusal stays readable; the last line counts the rest.
readonly MAX_PROBLEMS=20
# A signer that waits on something (a pinentry, a card) is stopped after
# this many seconds, well inside the stop hook's own time limit.
readonly SIGN_TIMEOUT=10
# A worktree <effort>/worktrees/<letter> is on crucible/<effort>/<letter>.
readonly BRANCH_PREFIX='crucible'
readonly WORKTREES_FOLDER='worktrees'
# Each seat's own files live in one folder under this one.
readonly SEATS_DIR='.crucible/seats'
# other() is true for a path line under SEATS_DIR/<a folder other than own>/.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are awk's
readonly OTHER_SEAT_AWK='
	function other(  rest, cut) {
		if (index($0, seats) != 1) return 0
		rest = substr($0, length(seats) + 1)
		cut = index(rest, "/")
		return !(cut > 0 && substr(rest, 1, cut - 1) == own)
	}'
# The C locale keeps the shell and its pattern classes byte-wise.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
# Every path is matched as written: no glob and no ":(magic)" pathspec.
GIT_LITERAL_PATHSPECS=1
export GIT_TERMINAL_PROMPT GIT_LITERAL_PATHSPECS
# An inherited repository override would make git act outside --worktree;
# with no GPG_TTY a signer that wants a terminal fails instead of waiting.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GPG_TTY
# ssh-keygen asks an SSH key's passphrase only of this askpass, which fails,
# so it never reads the terminal; gpg's pinentry is left to its own window.
SSH_ASKPASS_REQUIRE=force
SSH_ASKPASS=/usr/bin/false
[ -x "${SSH_ASKPASS}" ] || SSH_ASKPASS=/bin/false
export SSH_ASKPASS_REQUIRE SSH_ASKPASS

usage() {
	cat <<EOF
usage: sh ${PROG} --worktree DIR --message-file FILE --identity-name NAME
                 --identity-email EMAIL [--signing-format F --signing-key K]
                 --paths-file FILE | --seat S
       sh ${PROG} --help | -h

Commits exactly the given paths, or every change but other seats' folders,
in a linked git worktree and prints the new commit's full sha. The identity
is author and committer. Runs no repository hook.

--worktree DIR         absolute path of the linked worktree's top folder,
                       <effort>/${WORKTREES_FOLDER}/<letter>; HEAD must be on
                       ${BRANCH_PREFIX}/<effort>/<letter> and the index must
                       stage nothing
--message-file FILE    the commit message, kept byte for byte; not empty
--identity-name NAME   one line; no < or >, not starting or ending with a
                       space or any of . , : ; " ' \\
--identity-email EMAIL one line with an @; the name's character rules
--signing-format F     openpgp or ssh (git's gpg.format), with
--signing-key K        git's user.signingkey: the commit is signed, stdin
                       closed, no GPG_TTY and SSH_ASKPASS_REQUIRE=force with
                       a failing askpass; if signing fails or takes
                       over ${SIGN_TIMEOUT} s it is made again unsigned and stderr
                       says UNSIGNED: <reason> ("signing timed out after
                       ${SIGN_TIMEOUT} s" for the second). Without them it is
                       unsigned and nothing is said
--paths-file FILE    repo-relative paths to stage (added, modified or deleted),
                     even where an ignore rule covers them,
                     one per line, matched literally (no globs); each path is
                     relative, has no empty, "." or ".." segment, is not
                     .git or under .git/, and holds no control character;
                     no empty line except the file's trailing newline
--seat S             instead of --paths-file: every change git sees (added,
                     modified or deleted; nothing git ignores but under
                     ${SEATS_DIR}/S/) except those under
                     ${SEATS_DIR}/<a seat other than S>/; S is one path
                     segment. A path holding a line break is refused (exit
                     3). After the commit the worktree must show no change
                     outside those other seats' folders

exit codes:
  0  committed; the new commit's full sha is the only stdout line
  2  wrong command line: a missing, repeated or unknown option, a missing
     value, or both or neither of --paths-file and --seat
  3  invalid input: options, paths, files or worktree checks, or with
     --seat a path holding a line break, which may come after the commit;
     each problem is one stderr line (at most ${MAX_PROBLEMS})
  5  nothing to commit: the paths (or the worktree) hold no change; the
     index is left clean
  6  git staging or the commit failed; the index is restored to clean
  7  a commit was made but does not match what was asked; each mismatch is one
     stderr line
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

problems=''
problem_count=0

# Keeps up to MAX_PROBLEMS problem lines and counts all of them.
add_problem() {
	problem_count=$((problem_count + 1))
	[ "${problem_count}" -gt "${MAX_PROBLEMS}" ] || problems="${problems}${PROG}: $1
"
}

# Prints the kept problems, the last line counting any beyond the cap, and
# exits with $1; returns when there is none.
exit_on_problems() {
	[ "${problem_count}" -gt 0 ] || return 0
	if [ "${problem_count}" -le "${MAX_PROBLEMS}" ]; then
		printf '%s' "${problems}" >&2
	else
		printf '%s' "${problems}" | head -n "$((MAX_PROBLEMS - 1))" >&2
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
	worktree='' message_file='' identity_name='' identity_email='' signing_format='' signing_key='' paths_file='' own_seat=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--seat)
				take_value "$1" "${own_seat}" "${2-}"
				own_seat=${option_value}
				;;
			--worktree)
				take_value "$1" "${worktree}" "${2-}"
				worktree=${option_value}
				;;
			--message-file)
				take_value "$1" "${message_file}" "${2-}"
				message_file=${option_value}
				;;
			--identity-name)
				take_value "$1" "${identity_name}" "${2-}"
				identity_name=${option_value}
				;;
			--identity-email)
				take_value "$1" "${identity_email}" "${2-}"
				identity_email=${option_value}
				;;
			--signing-format)
				take_value "$1" "${signing_format}" "${2-}"
				signing_format=${option_value}
				;;
			--signing-key)
				take_value "$1" "${signing_key}" "${2-}"
				signing_key=${option_value}
				;;
			--paths-file)
				take_value "$1" "${paths_file}" "${2-}"
				paths_file=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --worktree, --message-file, --identity-name, --identity-email, --signing-format, --signing-key, --paths-file, --seat or --help"
				;;
		esac
		shift 2
	done
	[ -n "${worktree}" ] || usage_error '--worktree missing; expected --worktree DIR'
	[ -n "${message_file}" ] || usage_error '--message-file missing; expected --message-file FILE'
	[ -n "${identity_name}" ] || usage_error '--identity-name missing; expected --identity-name NAME'
	[ -n "${identity_email}" ] || usage_error '--identity-email missing; expected --identity-email EMAIL'
	[ -z "${signing_format}" ] || [ -n "${signing_key}" ] || usage_error '--signing-format given alone; expected --signing-key K with it'
	[ -z "${signing_key}" ] || [ -n "${signing_format}" ] || usage_error '--signing-key given alone; expected --signing-format F with it'
	if [ -n "${own_seat}" ]; then
		[ -z "${paths_file}" ] || usage_error '--paths-file and --seat both given; expected one of them'
	else
		[ -n "${paths_file}" ] || usage_error '--paths-file and --seat both missing; expected --paths-file FILE or --seat S'
	fi
}

# Copies --message-file and --paths-file into the private work folder, so a
# later change to either can't slip between the checks and the commit.
copy_inputs() {
	message_copy="${work_dir}/message"
	paths_copy="${work_dir}/paths"
	copy_input --message-file "${message_file}" "${message_copy}"
	[ -n "${own_seat}" ] || copy_input --paths-file "${paths_file}" "${paths_copy}"
}

copy_input() {
	shown_file=$(printable "$2")
	if [ ! -f "$2" ] || [ ! -r "$2" ]; then
		add_problem "$1 ${shown_file} is not a readable file; expected an existing file"
	elif ! cp -- "$2" "$3"; then
		add_problem "$1 ${shown_file} could not be copied; expected a readable file"
	elif [ ! -s "$3" ]; then
		add_problem "$1 ${shown_file} is empty; expected content"
	fi
}

check_message() {
	[ -s "${message_copy}" ] || return 0
	# git stores a message only up to its first NUL byte.
	nul_bytes=$(tr -cd '\000' <"${message_copy}" | wc -c)
	[ "${nul_bytes}" -eq 0 ] ||
		add_problem '--message-file holds a NUL byte; expected text'
}

# Checks one ident part ($1 the option, $2 the value) against what git keeps
# verbatim: git drops these leading and trailing characters and refuses < >.
check_ident() {
	case $2 in
		*[[:cntrl:]]*) add_problem "$1 holds a line break or control character; expected one line" ;;
		*[\<\>]*) add_problem "$1 holds < or >; expected neither" ;;
		[\ .,:\;\"\'\\]* | *[\ .,:\;\"\'\\]) add_problem "$1 starts or ends with a space or one of . , : ; \" ' \\; expected neither" ;;
		*) ;;
	esac
}

check_identity() {
	check_ident --identity-name "${identity_name}"
	check_ident --identity-email "${identity_email}"
	case ${identity_email} in
		*@*) ;;
		*) add_problem '--identity-email has no @; expected an email address' ;;
	esac
	check_signing
}

# The key reaches git only as a config value, never as an option.
check_signing() {
	[ -n "${signing_key}" ] || return 0
	case ${signing_format} in
		openpgp | ssh) ;;
		*)
			shown_format=$(printable "${signing_format}")
			add_problem "--signing-format ${shown_format} is not openpgp or ssh; expected one of them"
			;;
	esac
	case ${signing_key} in
		*[[:cntrl:]]*) add_problem '--signing-key holds a line break or control character; expected one line' ;;
		*) ;;
	esac
}

# The seat's own folder name must be one plain path segment.
check_seat() {
	[ -n "${own_seat}" ] || return 0
	case ${own_seat} in
		*[[:cntrl:]]*) add_problem '--seat holds a control character; expected a seat name' ;;
		*/* | . | ..)
			shown_seat=$(printable "${own_seat}")
			add_problem "--seat ${shown_seat} is not one path segment; expected a seat name"
			;;
		*) ;;
	esac
}

check_paths() {
	[ -z "${own_seat}" ] && [ -s "${paths_copy}" ] || return 0
	line_number=0
	while IFS= read -r path || [ -n "${path}" ]; do
		line_number=$((line_number + 1))
		check_path "${path}" "${line_number}"
	done <"${paths_copy}"
}

# Checks one path ($1) on paths line $2; the path is shown only when it is bad.
check_path() {
	reason=''
	case $1 in
		'') reason='is empty; expected a repo-relative path' ;;
		*[[:cntrl:]]*) reason='holds a control character; expected printable text' ;;
		/*) reason='is absolute; expected a repo-relative path' ;;
		.git | .git/*) reason='is git'\''s own .git entry; expected a path outside it' ;;
		*) ;;
	esac
	if [ -z "${reason}" ]; then
		case /$1/ in
			*/../*) reason='has a .. segment; expected none' ;;
			*/./* | *//*) reason='has an empty or "." segment; expected a normalized path' ;;
			*) return 0 ;;
		esac
	fi
	shown_path=$(printable "$1")
	add_problem "--paths-file line $2 (${shown_path}) ${reason}"
}

# Refuses anything but the top folder of a linked worktree with HEAD on its
# own branch, no merge or rebase under way, and nothing staged; records HEAD.
check_worktree() {
	shown_worktree=$(printable "${worktree}")
	case ${worktree} in
		/*) ;;
		*)
			add_problem "--worktree ${shown_worktree} is not absolute; expected an absolute path"
			return 0
			;;
	esac
	if [ ! -d "${worktree}" ]; then
		add_problem "--worktree ${shown_worktree} is not a folder; expected an existing folder"
		return 0
	fi
	command -v git >/dev/null 2>&1 || die 3 'git not found; expected git 2.26+ on PATH'
	if [ "$(git -C "${worktree}" rev-parse --is-inside-work-tree 2>/dev/null || :)" != true ]; then
		add_problem "--worktree ${shown_worktree} is not a git work tree; expected a linked worktree"
		return 0
	fi
	check_top_folder
	check_linked
	check_head
	check_no_operation
	check_index_clean
}

check_top_folder() {
	physical_worktree=$(cd -P -- "${worktree}" && pwd -P) || physical_worktree=''
	top_folder=$(git -C "${worktree}" rev-parse --show-toplevel 2>/dev/null) || top_folder=''
	shown_top_folder=$(printable "${top_folder}")
	[ -n "${top_folder}" ] && [ "${physical_worktree}" = "${top_folder}" ] ||
		add_problem "--worktree ${shown_worktree} is not the worktree's top folder; expected ${shown_top_folder}"
}

check_linked() {
	git_dir=$(git -C "${worktree}" rev-parse --absolute-git-dir 2>/dev/null) || git_dir=''
	common_dir=$(git -C "${worktree}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=''
	if [ -z "${git_dir}" ] || [ -z "${common_dir}" ]; then
		add_problem "--worktree ${shown_worktree}: git could not name its git folders; expected git 2.26+"
	elif [ "${git_dir}" = "${common_dir}" ]; then
		add_problem "--worktree ${shown_worktree} is a main checkout; expected a linked worktree"
	fi
}

check_head() {
	own_branch
	head_ref=$(git -C "${worktree}" symbolic-ref -q HEAD 2>/dev/null) || head_ref=''
	shown_branch=$(printable "${branch}")
	if [ -z "${branch}" ]; then
		add_problem "--worktree ${shown_worktree} is not <effort>/${WORKTREES_FOLDER}/<letter>; expected a worktree folder whose branch it names"
	elif [ -z "${head_ref}" ]; then
		add_problem "--worktree ${shown_worktree} has a detached HEAD; expected HEAD on ${shown_branch}"
	elif [ "${head_ref}" != "refs/heads/${branch}" ]; then
		shown_ref=$(printable "${head_ref#refs/heads/}")
		add_problem "--worktree ${shown_worktree} has HEAD on ${shown_ref}; expected HEAD on ${shown_branch}"
	fi
	old_head=$(git -C "${worktree}" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) || old_head=''
	[ -n "${old_head}" ] ||
		add_problem "--worktree ${shown_worktree} has no HEAD commit; expected HEAD on ${shown_branch} at a commit"
}

# Sets branch to the worktree's own branch from its physical path, or to
# nothing when the path is not <effort>/WORKTREES_FOLDER/<letter>.
own_branch() {
	branch=''
	worktrees_dir=${physical_worktree%/*}
	effort_dir=${worktrees_dir%/*}
	[ -n "${physical_worktree}" ] && [ "${worktrees_dir##*/}" = "${WORKTREES_FOLDER}" ] && [ -n "${effort_dir##*/}" ] || return 0
	branch="${BRANCH_PREFIX}/${effort_dir##*/}/${physical_worktree##*/}"
}

# A merge or pick under way would turn the commit into something else.
check_no_operation() {
	[ -n "${git_dir}" ] || return 0
	for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
		[ ! -e "${git_dir}/${state}" ] ||
			add_problem "--worktree ${shown_worktree} has ${state} under way; expected no merge, pick or rebase"
	done
}

check_index_clean() {
	[ -n "${old_head}" ] || return 0
	if ! git -C "${worktree}" -c core.fsmonitor=false diff --cached --quiet >/dev/null 2>&1; then
		add_problem "--worktree ${shown_worktree} already has staged changes; expected a clean index"
	fi
}

# Restores the index (clean before this script staged) and exits 6.
fail_restored() {
	git -C "${worktree}" -c core.fsmonitor=false reset -q >/dev/null 2>&1 || warn 'git reset failed; the index may still hold staged paths'
	die 6 "$1"
}

stage_changes() {
	paths_nul="${work_dir}/paths.nul"
	if [ -n "${own_seat}" ]; then
		list_own_changes "${paths_nul}"
		if [ -s "${paths_nul}" ]; then
			git -C "${worktree}" -c core.fsmonitor=false add -A --pathspec-from-file="${paths_nul}" --pathspec-file-nul >&2 ||
				fail_restored 'git add failed; expected every changed file readable'
		fi
		stage_own_folder
		git -C "${worktree}" -c core.fsmonitor=false diff --cached --quiet && die 5 "nothing to commit; expected a change outside other seats' folders"
		return 0
	fi
	tr '\n' '\000' <"${paths_copy}" >"${paths_nul}"
	git -C "${worktree}" -c core.fsmonitor=false add -A -f --pathspec-from-file="${paths_nul}" --pathspec-file-nul >&2 ||
		fail_restored 'git add failed; expected every path to exist or be tracked'
	git -C "${worktree}" -c core.fsmonitor=false diff --cached --quiet && die 5 'nothing to commit; expected a change in the given paths'
	return 0
}

# Writes to $1, NUL-separated, every changed path git sees but those under
# another seat's folder.
list_own_changes() {
	git -C "${worktree}" -c core.fsmonitor=false status --porcelain -z --no-renames \
		--untracked-files=all --ignore-submodules=none >"${work_dir}/status" ||
		die 6 'git status could not list the worktree; expected a readable worktree'
	refuse_line_breaks "${work_dir}/status" 'the worktree holds'
	tr '\000' '\n' <"${work_dir}/status" | sed 's/^...//' | own_paths | tr '\n' '\000' >"$1"
}

# Exits 3 when the NUL-separated list in file $1 holds a line break: the
# lists are read one path per line, so such a path would be read as two.
# $2 says where the list came from.
refuse_line_breaks() {
	line_breaks=$(tr -cd '\n' <"$1" | wc -c)
	[ "${line_breaks}" -eq 0 ] ||
		die 3 "$2 a path with a line break; expected none, since --seat reads its paths one per line"
}

# Stages the seat's own folder whole, past the repo's ignore rules.
stage_own_folder() {
	own_folder="${SEATS_DIR}/${own_seat}"
	[ -d "${worktree}/${own_folder}" ] && [ ! -L "${worktree}/${own_folder}" ] || return 0
	git -C "${worktree}" -c core.fsmonitor=false add -A -f -- "${own_folder}" >&2 ||
		fail_restored "git add failed on ${own_folder}; expected every file in it readable"
}

# Passes each path line through but those under another seat's folder.
own_paths() {
	awk -v seats="${SEATS_DIR}/" -v own="${own_seat}" "${OTHER_SEAT_AWK}"'
		!other() { print }'
}

# Passes only the path lines under another seat's folder.
other_seat_paths() {
	awk -v seats="${SEATS_DIR}/" -v own="${own_seat}" "${OTHER_SEAT_AWK}"'
		other() { print }'
}

# Commits signed when a key is given; a signed commit that fails or times
# out with HEAD unmoved is made again unsigned, with the reason on stderr.
commit_staged() {
	signed=no
	if [ -n "${signing_key}" ]; then
		run_signed_commit
		if [ "${sign_rc}" -eq 0 ]; then
			signed=yes
			return 0
		fi
		head_unmoved_or_die
	fi
	# shellcheck disable=SC2310 # its status is the answer: the subshell is one git command
	if (exec_commit commit --no-gpg-sign) >&2; then
		[ -z "${signing_key}" ] || say_unsigned
		return 0
	fi
	head_unmoved_or_die
	fail_restored 'git commit failed; expected a committable index'
}

# Runs the signed commit in the background and stops it after SIGN_TIMEOUT
# seconds; sets sign_rc, and sign_timed_out from the watcher's marker. The
# watcher's own output goes nowhere, so a caller reading this script's
# output never waits on it.
run_signed_commit() {
	timeout_marker="${work_dir}/sign-timed-out"
	exec_commit -c "gpg.format=${signing_format}" -c "user.signingkey=${signing_key}" commit -S \
		>&2 2>"${work_dir}/sign-stderr" &
	commit_pid=$!
	watch_signing "${commit_pid}" </dev/null >/dev/null 2>&1 &
	watcher_pid=$!
	sign_rc=0
	wait "${commit_pid}" || sign_rc=$?
	kill "${watcher_pid}" 2>/dev/null || :
	wait "${watcher_pid}" 2>/dev/null || :
	sign_timed_out=no
	[ ! -e "${timeout_marker}" ] || sign_timed_out=yes
}

# Sleeps SIGN_TIMEOUT seconds, then writes the timeout marker and stops git
# $1; a kill of the watcher itself stops its sleep too.
watch_signing() {
	sleep "${SIGN_TIMEOUT}" &
	sleep_pid=$!
	trap 'kill "${sleep_pid}" 2>/dev/null; exit 0' TERM
	wait "${sleep_pid}" || exit 0
	: >"${timeout_marker}" || :
	kill "$1" 2>/dev/null || :
}

# Prints UNSIGNED: and why: the time limit, or the signer's own first line,
# no gpg status line and not git's "gpg failed to sign" lead-in.
say_unsigned() {
	if [ "${sign_timed_out}" = yes ]; then
		printf 'UNSIGNED: signing timed out after %s s\n' "${SIGN_TIMEOUT}" >&2
		return 0
	fi
	sign_reason=$(sed -e '/^\[GNUPG:\]/d' -e '/^error: gpg failed to sign the data/d' -e '/^[[:space:]]*$/d' \
		"${work_dir}/sign-stderr" | head -n 1) || sign_reason=''
	shown_reason=$(printable "${sign_reason:-git commit -S failed}")
	printf 'UNSIGNED: %s\n' "${shown_reason}" >&2
}

# Replaces the calling (sub)shell with git, the options in "$@" (config
# first, then the command), as the identity, with stdin closed and no hook;
# so a background call's PID is git's own.
exec_commit() {
	exec env GIT_AUTHOR_NAME="${identity_name}" GIT_AUTHOR_EMAIL="${identity_email}" \
		GIT_COMMITTER_NAME="${identity_name}" GIT_COMMITTER_EMAIL="${identity_email}" \
		git -C "${worktree}" -c core.fsmonitor=false -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@" \
		-q --no-verify --cleanup=verbatim -F "${message_copy}" </dev/null
}

# A failed commit that still moved HEAD made something nobody asked for.
head_unmoved_or_die() {
	head_after=$(git -C "${worktree}" rev-parse --verify -q HEAD 2>/dev/null) || head_after=''
	[ "${head_after}" = "${old_head}" ] || die 7 'git commit failed but HEAD moved; expected one clean commit'
}

# Checks the new commit against every input; exits 7 naming each mismatch.
verify_commit() {
	new_head=$(git -C "${worktree}" rev-parse --verify -q HEAD) || new_head=''
	[ -n "${new_head}" ] && [ "${new_head}" != "${old_head}" ] ||
		die 7 'HEAD did not change; expected a new commit'
	verify_object
	verify_idents
	verify_branch
	if [ -n "${own_seat}" ]; then
		verify_own_changes
	else
		verify_paths
	fi
	git -C "${worktree}" -c core.fsmonitor=false diff --cached --quiet >/dev/null 2>&1 ||
		add_problem 'the index is not clean after the commit; expected nothing staged'
	exit_on_problems 7
	printf '%s\n' "${new_head}"
}

# The raw commit object is its header lines, one blank line, then the message.
verify_object() {
	object="${work_dir}/object"
	git -C "${worktree}" cat-file commit "${new_head}" >"${object}" ||
		die 7 'git cat-file could not read the new commit; expected a readable object'
	header_bytes=$(sed -n '1,/^$/p' "${object}" | wc -c)
	tail -c "+$((header_bytes + 1))" "${object}" | cmp -s - "${message_copy}" ||
		add_problem 'the commit message differs from --message-file; expected it byte for byte'
	parent_count=$(sed -n '1,/^$/p' "${object}" | grep -c '^parent ' || :)
	signature_count=$(sed -n '1,/^$/p' "${object}" | grep -c '^gpgsig' || :)
	if [ "${signed}" = yes ] && [ "${signature_count}" -eq 0 ]; then
		add_problem 'the commit carries no signature; expected one signed with --signing-key'
	elif [ "${signed}" = no ] && [ "${signature_count}" -gt 0 ]; then
		add_problem 'the commit carries a signature; expected it unsigned'
	fi
	parent=$(git -C "${worktree}" rev-parse --verify -q "${new_head}^" 2>/dev/null) || parent=''
	[ "${parent_count}" -eq 1 ] && [ "${parent}" = "${old_head}" ] ||
		add_problem "the commit's parent is not ${old_head} alone; expected the HEAD before the commit"
}

verify_idents() {
	idents=$(git -C "${worktree}" show -s --no-show-signature --format='%an%n%ae%n%cn%n%ce' "${new_head}") || idents=''
	expected_idents="${identity_name}
${identity_email}
${identity_name}
${identity_email}"
	[ "${idents}" = "${expected_idents}" ] ||
		add_problem "the commit's author or committer differs; expected ${identity_name} <${identity_email}> as both"
}

verify_branch() {
	branch_head=$(git -C "${worktree}" rev-parse --verify -q "refs/heads/${branch}" 2>/dev/null) || branch_head=''
	[ "${branch_head}" = "${new_head}" ] ||
		add_problem "the branch ${shown_branch} is not at the new commit; expected the commit on the worktree's own branch"
}

# Each changed path must be a given path or lie under one given as a folder.
verify_paths() {
	changed="${work_dir}/changed"
	git -C "${worktree}" diff-tree --no-commit-id --name-only -r -z "${new_head}" >"${changed}" ||
		die 7 'git diff-tree could not list the commit'\''s paths; expected a readable commit'
	outside=$(tr '\000' '\n' <"${changed}" | awk -v given_file="${paths_copy}" '
		BEGIN { while ((getline line < given_file) > 0) given[line] = 1 }
		{
			covered = ($0 in given)
			for (cut = length($0); !covered && cut > 0; cut--)
				if (substr($0, cut, 1) == "/" && (substr($0, 1, cut - 1) in given)) covered = 1
			if (!covered) print
		}') || die 7 'awk failed comparing the commit'\''s paths; expected a POSIX awk'
	[ -n "${outside}" ] || return 0
	while IFS= read -r path; do
		shown_path=$(printable "${path}")
		add_problem "the commit changes ${shown_path}, which is not a given path; expected only given paths"
	done <<EOF
${outside}
EOF
}

# With --seat, the commit holds no path of another seat's folder, and the
# worktree shows no change outside those folders.
verify_own_changes() {
	git -C "${worktree}" diff-tree --no-commit-id --name-only -r -z "${new_head}" >"${work_dir}/changed" ||
		die 7 'git diff-tree could not list the commit'\''s paths; expected a readable commit'
	refuse_line_breaks "${work_dir}/changed" "the new commit ${new_head} holds"
	tr '\000' '\n' <"${work_dir}/changed" | other_seat_paths >"${work_dir}/changed.other"
	while IFS= read -r path; do
		shown_path=$(printable "${path}")
		add_problem "the commit changes ${shown_path}, in another seat's folder; expected only ${SEATS_DIR}/${own_seat}/ and paths outside ${SEATS_DIR}/"
	done <"${work_dir}/changed.other"
	git -C "${worktree}" -c core.fsmonitor=false status --porcelain -z --no-renames \
		--untracked-files=all --ignore-submodules=none >"${work_dir}/left" ||
		die 7 'git status could not list the worktree after the commit; expected a readable worktree'
	refuse_line_breaks "${work_dir}/left" "after the new commit ${new_head}, the worktree holds"
	tr '\000' '\n' <"${work_dir}/left" | sed 's/^...//' | own_paths >"${work_dir}/left.own"
	while IFS= read -r path; do
		shown_path=$(printable "${path}")
		add_problem "the worktree still shows a change at ${shown_path}; expected the commit to hold every change outside other seats' folders"
	done <"${work_dir}/left.own"
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
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-commit.XXXXXX") ||
	die 3 'mktemp could not create a work folder; expected a writable TMPDIR'
copy_inputs
check_message
check_identity
check_seat
check_paths
check_worktree
exit_on_problems 3
stage_changes
commit_staged
verify_commit
