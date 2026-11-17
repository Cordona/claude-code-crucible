#!/usr/bin/env sh
# Merges two or more commits into one commit object with git merge-tree, so
# seats' tips can be combined without a worktree, an index or a ref: only
# objects are written. A commit another given commit already holds is left
# out; when one commit holds all the others it is the answer and nothing is
# written.
set -eu
umask 077

readonly PROG='tips-merge.sh'
readonly IDENT_NAME='crucible'
readonly IDENT_EMAIL='crucible@crucible.invalid'
# A signer that waits on something (a pinentry, a card) is stopped after
# this many seconds.
readonly SIGN_TIMEOUT=10
# The C locale keeps the shell, sed and awk byte-wise.
LC_ALL=C
export LC_ALL
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo; with
# no GPG_TTY a signer that wants a terminal fails instead of waiting.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GIT_DIFF_OPTS GIT_EXTERNAL_DIFF GPG_TTY
# ssh-keygen asks an SSH key's passphrase only of this askpass, which fails,
# so it never reads the terminal; gpg's pinentry is left to its own window.
SSH_ASKPASS_REQUIRE=force
SSH_ASKPASS=/usr/bin/false
[ -x "${SSH_ASKPASS}" ] || SSH_ASKPASS=/bin/false
export SSH_ASKPASS_REQUIRE SSH_ASKPASS

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR --commit SHA --commit SHA [--commit SHA]...
          --message-file FILE [--identity-name N --identity-email E
          [--signing-format F --signing-key K]]
       sh ${PROG} --help | -h

Merges the given commits into one commit object. Repeats and every commit
another given one already holds are dropped first; when one commit is left
it is printed and nothing is written. Otherwise git merge-tree folds them
left (each step merges the last result, as a temporary commit, with the
next commit), and the result is one commit with every kept commit as a
parent, in the given order, its message from FILE. Writes only git objects:
no worktree, index or ref is touched; only the merge commit may be signed.

--repo DIR          absolute path of the repository folder
--commit SHA        a commit in DIR; at least two
--message-file FILE absolute path of the merge commit's message; not empty
--identity-name N   the merge commit's author and committer, given
--identity-email E  together; default ${IDENT_NAME} <${IDENT_EMAIL}>; one
                    line each, no < or >, not starting or ending with a
                    space or any of . , : ; " ' \\
--signing-format F  openpgp or ssh, with --signing-key (git's
--signing-key K     user.signingkey): the merge commit is signed, stdin
                    closed, SSH_ASKPASS_REQUIRE=force with a failing
                    askpass; if signing fails or takes over ${SIGN_TIMEOUT} s it is
                    written unsigned and stderr says UNSIGNED: <reason>
                    ("signing timed out after ${SIGN_TIMEOUT} s" for the second)
The fold steps are ${IDENT_NAME}'s, unsigned; dates are git's own.

stdout, one JSON line:
  {"merged":true,"commit":<sha>,"new":true|false}  new false: a given commit
  {"merged":false,"conflicts":[<path>...]}          a fold step conflicted
The paths in the JSON are raw; a conflict prints nothing on stderr.

exit codes:
  0  merged, or one commit holds the others
  2  wrong command line: a missing, repeated or unknown option, or a
     missing value
  3  input: fewer than two --commit, a value that is no commit in DIR, a
     path that is not absolute, a missing or empty message file, or a bad
     identity or signing option
  4  environment: git or jq missing or failed
  5  the commits conflict; no ref, index or worktree touched (the fold
     steps may leave git objects)

needs: POSIX sh, git 2.38+, jq 1.6+
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
	repo='' message_file='' identity_name='' identity_email='' signing_format='' signing_key=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--repo)
				take_value "$1" "${repo}" "${2-}" DIR
				repo=${option_value}
				;;
			--commit)
				take_value "$1" '' "${2-}" SHA
				;;
			--message-file)
				take_value "$1" "${message_file}" "${2-}" FILE
				message_file=${option_value}
				;;
			--identity-name)
				take_value "$1" "${identity_name}" "${2-}" N
				identity_name=${option_value}
				;;
			--identity-email)
				take_value "$1" "${identity_email}" "${2-}" E
				identity_email=${option_value}
				;;
			--signing-format)
				take_value "$1" "${signing_format}" "${2-}" F
				signing_format=${option_value}
				;;
			--signing-key)
				take_value "$1" "${signing_key}" "${2-}" K
				signing_key=${option_value}
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --repo, --commit, --message-file, --identity-name, --identity-email, --signing-format, --signing-key or --help"
				;;
		esac
		shift 2
	done
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
	[ -n "${message_file}" ] || usage_error '--message-file missing; expected --message-file FILE'
	[ -z "${identity_name}" ] || [ -n "${identity_email}" ] || usage_error '--identity-name given alone; expected --identity-email E with it'
	[ -z "${identity_email}" ] || [ -n "${identity_name}" ] || usage_error '--identity-email given alone; expected --identity-name N with it'
	[ -z "${signing_format}" ] || [ -n "${signing_key}" ] || usage_error '--signing-format given alone; expected --signing-key K with it'
	[ -z "${signing_key}" ] || [ -n "${signing_format}" ] || usage_error '--signing-key given alone; expected --signing-format F with it'
	[ -z "${signing_key}" ] || [ -n "${identity_name}" ] || usage_error '--signing-key given without --identity-name; expected the identity it signs for'
}

load_dependencies() {
	command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.38+ on PATH'
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
}

check_inputs() {
	shown_repo=$(printable "${repo}")
	case ${repo} in
		/*) ;;
		*) die 3 "--repo ${shown_repo} is not absolute; expected an absolute path" ;;
	esac
	git -C "${repo}" -c core.fsmonitor=false rev-parse --git-dir >/dev/null 2>&1 ||
		die 3 "--repo ${shown_repo} is not a git repository folder; expected one"
	shown_message=$(printable "${message_file}")
	case ${message_file} in
		/*) ;;
		*) die 3 "--message-file ${shown_message} is not absolute; expected an absolute path" ;;
	esac
	[ -f "${message_file}" ] && [ -r "${message_file}" ] ||
		die 3 "--message-file ${shown_message} is not a readable file; expected the merge commit's message"
	[ -s "${message_file}" ] || die 3 "--message-file ${shown_message} is empty; expected the merge commit's message"
	identity_name=${identity_name:-${IDENT_NAME}}
	identity_email=${identity_email:-${IDENT_EMAIL}}
	check_ident --identity-name "${identity_name}"
	check_ident --identity-email "${identity_email}"
	check_signing
}

# The key reaches git only as a config value, never as an option.
check_signing() {
	[ -n "${signing_key}" ] || return 0
	case ${signing_format} in
		openpgp | ssh) ;;
		*)
			shown_format=$(printable "${signing_format}")
			die 3 "--signing-format ${shown_format} is not openpgp or ssh; expected one of them"
			;;
	esac
	case ${signing_key} in
		*[[:cntrl:]]*) die 3 '--signing-key holds a control character; expected one line' ;;
		*) ;;
	esac
}

# Refuses ident part $2 of option $1 that git would reject or rewrite: git
# drops these leading and trailing characters and refuses < >.
check_ident() {
	shown_ident=$(printable "$2")
	case $2 in
		*[[:cntrl:]]* | *[\<\>]*)
			die 3 "$1 ${shown_ident} holds a control character, < or >; expected a plain value"
			;;
		[\ .,:\;\"\'\\]* | *[\ .,:\;\"\'\\])
			die 3 "$1 ${shown_ident} starts or ends with a space or one of . , : ; \" ' \\; expected neither"
			;;
		*) ;;
	esac
}

# Writes work_dir/given, one full sha per --commit of the checked command
# line ("$@"), in order.
resolve_commits() {
	: >"${work_dir}/given"
	while [ "$#" -gt 0 ]; do
		[ "$1" != --commit ] || resolve_commit "$2"
		shift 2
	done
	given_count=$(wc -l <"${work_dir}/given" | tr -d ' ') || die 4 'wc failed counting the commits'
	[ "${given_count}" -ge 2 ] || die 3 "--commit given ${given_count} time(s); expected at least two commits"
}

resolve_commit() {
	full_sha=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet --end-of-options "$1^{commit}" 2>/dev/null) || {
		shown_commit=$(printable "$1")
		die 3 "--commit ${shown_commit} is not a commit in ${shown_repo}; expected a commit sha"
	}
	printf '%s\n' "${full_sha}" >>"${work_dir}/given"
}

# Writes work_dir/kept: the given commits, repeats dropped, without any that
# another given commit holds, in the given order.
keep_tips() {
	awk '!seen[$0]++' "${work_dir}/given" >"${work_dir}/distinct" || die 4 'awk failed dropping repeated commits'
	: >"${work_dir}/kept"
	while IFS= read -r candidate; do
		held=false
		while IFS= read -r other; do
			[ "${other}" != "${candidate}" ] || continue
			is_ancestor "${candidate}" "${other}"
			[ "${ancestor}" = false ] || {
				held=true
				break
			}
		done <"${work_dir}/distinct"
		[ "${held}" = true ] || printf '%s\n' "${candidate}" >>"${work_dir}/kept"
	done <"${work_dir}/distinct"
}

# Sets ancestor to whether commit $1 is an ancestor of commit $2.
is_ancestor() {
	ancestor_rc=0
	git -C "${repo}" -c core.fsmonitor=false merge-base --is-ancestor "$1" "$2" 2>"${work_dir}/stderr" || ancestor_rc=$?
	case ${ancestor_rc} in
		0) ancestor=true ;;
		1) ancestor=false ;;
		*) git_failed 'git merge-base --is-ancestor' ;;
	esac
}

# Folds the kept commits left; sets merged_tree, or exits 5 naming the
# conflicted paths of the failing step.
fold_tips() {
	previous=''
	while IFS= read -r tip; do
		if [ -z "${previous}" ]; then
			previous=${tip} last_tip=''
			continue
		fi
		if [ -n "${last_tip}" ]; then
			make_commit "${merged_tree}" -p "${previous}" -p "${last_tip}" -m 'crucible(merge): fold step'
			previous=${made_commit}
		fi
		merge_step "${previous}" "${tip}"
		last_tip=${tip}
	done <"${work_dir}/kept"
}

# Merges commits $1 and $2 into merged_tree.
merge_step() {
	step_rc=0
	git -C "${repo}" -c core.fsmonitor=false merge-tree --write-tree -z --name-only --no-messages "$1" "$2" \
		>"${work_dir}/step" 2>"${work_dir}/stderr" || step_rc=$?
	[ "${step_rc}" -le 1 ] || git_failed 'git merge-tree'
	# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
	jq -Rsc 'split("\u0000") | map(select(. != "")) as $records
		| if ($records[0] // "") | test("^([0-9a-f]{40}|[0-9a-f]{64})$") then {tree: $records[0], conflicts: $records[1:]}
		else {tree: null, conflicts: []} end' "${work_dir}/step" >"${work_dir}/step.json" 2>/dev/null ||
		die 4 'jq could not read the git merge-tree output'
	merged_tree=$(jq -r '.tree // ""' "${work_dir}/step.json") || die 4 'jq could not read the merge step'
	conflict_count=$(jq -r '.conflicts | length' "${work_dir}/step.json") || die 4 'jq could not read the merge step'
	if [ "${step_rc}" -eq 0 ] && [ -n "${merged_tree}" ]; then
		return 0
	fi
	[ "${step_rc}" -eq 1 ] && [ -n "${merged_tree}" ] && [ "${conflict_count}" -gt 0 ] || git_failed 'git merge-tree'
	refuse_conflict
}

refuse_conflict() {
	jq -c '{merged: false, conflicts: .conflicts}' "${work_dir}/step.json" || die 4 'jq could not print the result'
	exit 5
}

# Sets made_commit to a new unsigned commit of tree $1 with the rest as
# commit-tree's parent and message options, by commit_name and commit_email,
# crucible's when they are empty.
make_commit() {
	tree=$1
	shift
	# shellcheck disable=SC2310 # its status is the answer: commit_tree is one git command
	made_commit=$(commit_tree -c commit.gpgSign=false commit-tree --no-gpg-sign "${tree}" "$@" 2>"${work_dir}/stderr") ||
		git_failed 'git commit-tree'
}

# Replaces the calling (sub)shell with git, config and command "$@", as
# commit_name <commit_email>, stdin closed; so a background call's PID is
# git's own.
commit_tree() {
	exec env GIT_AUTHOR_NAME="${commit_name:-${IDENT_NAME}}" GIT_AUTHOR_EMAIL="${commit_email:-${IDENT_EMAIL}}" \
		GIT_COMMITTER_NAME="${commit_name:-${IDENT_NAME}}" GIT_COMMITTER_EMAIL="${commit_email:-${IDENT_EMAIL}}" \
		git -C "${repo}" -c core.fsmonitor=false "$@" </dev/null
}

# Makes the merge commit of merged_tree with every kept commit as a parent,
# by the identity; signed when a key is given, else or when signing fails
# unsigned.
write_merge() {
	set --
	while IFS= read -r tip; do
		set -- "$@" -p "${tip}"
	done <"${work_dir}/kept"
	commit_name=${identity_name} commit_email=${identity_email}
	if [ -n "${signing_key}" ]; then
		run_signed_merge "$@"
		if [ "${sign_rc}" -eq 0 ] && IFS= read -r made_commit <"${work_dir}/signed" && [ -n "${made_commit}" ]; then
			return 0
		fi
		make_commit "${merged_tree}" "$@" -F "${message_file}"
		say_unsigned
		return 0
	fi
	make_commit "${merged_tree}" "$@" -F "${message_file}"
}

# Writes the signed merge commit's sha to work_dir/signed in the background
# and stops it after SIGN_TIMEOUT seconds; "$@" are its parent options. Sets
# sign_rc, and sign_timed_out from the watcher's marker. The watcher's own
# output goes nowhere, so a caller reading this script's output never waits
# on it.
run_signed_merge() {
	timeout_marker="${work_dir}/sign-timed-out"
	commit_tree -c "gpg.format=${signing_format}" -c "user.signingkey=${signing_key}" \
		commit-tree -S "${merged_tree}" "$@" -F "${message_file}" >"${work_dir}/signed" 2>"${work_dir}/sign-stderr" &
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
	if [ "${sign_timed_out}" = yes ] && [ "${sign_rc}" -ne 0 ]; then
		printf 'UNSIGNED: signing timed out after %s s\n' "${SIGN_TIMEOUT}" >&2
		return 0
	fi
	sign_reason=$(sed -e '/^\[GNUPG:\]/d' -e '/^error: gpg failed to sign the data/d' -e '/^[[:space:]]*$/d' \
		"${work_dir}/sign-stderr" | head -n 1) || sign_reason=''
	shown_reason=$(printable "${sign_reason:-git commit-tree -S failed}")
	printf 'UNSIGNED: %s\n' "${shown_reason}" >&2
}

git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
}

print_result() {
	jq -nc --arg commit "$1" --argjson new "$2" '{merged: true, commit: $commit, new: $new}' ||
		die 4 'jq could not print the result'
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir='' commit_name='' commit_email=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
load_dependencies
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-tips-merge.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
check_inputs
resolve_commits "$@"
keep_tips
kept_count=$(wc -l <"${work_dir}/kept" | tr -d ' ') || die 4 'wc failed counting the kept commits'
if [ "${kept_count}" -eq 1 ]; then
	IFS= read -r only_tip <"${work_dir}/kept" || die 4 'could not read the kept commit'
	print_result "${only_tip}" false
	exit 0
fi
fold_tips
write_merge
print_result "${made_commit}" true
