#!/usr/bin/env sh
# Turns a main checkout's uncommitted work into one commit object, so seats
# can start from what the human sees without the checkout being touched: a
# temp index built from HEAD takes every change git sees, and the commit is
# made from its tree with no ref, no index and no checkout file written, by
# the effort's identity (given, or read with procedure-git-setup's
# settings.sh) and, with a key, signed. A fingerprint of the
# checkout taken before and after proves nothing moved but the refs working
# seats move meanwhile. A snapshot made unsigned is said by views/lines.jq's
# unsigned, printed through human-view's show.sh.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib
set -eu
umask 077

readonly PROG='snapshot.sh'
readonly MESSAGE='crucible(snapshot): uncommitted changes'
# From this folder to the effort settings' reader.
readonly SETTINGS='../../../procedure-git-setup/scripts/settings.sh'
# A signer that waits on something (a pinentry, a card) is stopped after
# this many seconds.
readonly SIGN_TIMEOUT=10
# Refs under these move while a snapshot is made, and are left out of its
# fingerprint: worktrees' own branches as their seats commit, and
# remote-tracking refs as they push.
readonly SEAT_BRANCHES='refs/heads/crucible/'
readonly REMOTE_REFS='refs/remotes/'
# The C locale keeps the shell and its pattern classes byte-wise.
LC_ALL=C
export LC_ALL
# No git command here may refresh or write the checkout's real index.
GIT_OPTIONAL_LOCKS=0
GIT_TERMINAL_PROMPT=0
export GIT_OPTIONAL_LOCKS GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo; with
# no GPG_TTY a signer that wants a terminal fails instead of waiting.
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
usage: sh ${PROG} --repo DIR --effort DIR
       sh ${PROG} --repo DIR --identity-name N --identity-email E
          [--signing-format F --signing-key K]
       sh ${PROG} --help | -h

Makes one commit object of a main checkout's uncommitted work (staged,
unstaged and untracked; nothing git ignores), parent HEAD, message
"${MESSAGE}",
the identity author and committer. Writes only git objects: no ref, no
index, no file of the checkout; runs no hook.

--repo DIR          absolute path of the main checkout's top folder; not a
                    linked worktree, not bare, not sparse, with a HEAD
                    commit and no merge, rebase, cherry-pick or revert
                    under way
--effort DIR        absolute path of the effort folder: the identity and
                    key are what settings.sh get --effort DIR prints; not
                    with --identity-* or --signing-*
--identity-name N   the effort's identity (settings.sh get's NAME and
--identity-email E  EMAIL); one line each, no < or >, not starting or
                    ending with a space or any of . , : ; " ' \\
--signing-format F  openpgp or ssh, with --signing-key (git's
--signing-key K     user.signingkey): the commit is signed, stdin closed,
                    no GPG_TTY, SSH_ASKPASS_REQUIRE=force with a failing
                    askpass; if signing fails or takes over ${SIGN_TIMEOUT} s it is
                    written unsigned

output, one stdout line:
  SNAPSHOT: <sha>   the new commit
  CLEAN: <sha>      nothing uncommitted: HEAD's sha, no object written
then, for a snapshot written unsigned, the line unsigned (views/lines.jq),
  its reason "signing timed out after ${SIGN_TIMEOUT} s" for the time limit,
  printed by human-view's show.sh and recorded as owed this session
  (CLAUDE_CODE_SESSION_ID) for --effort

exit codes:
  0  printed
  2  wrong command line: a missing, repeated or unknown option, a
     missing value, or --effort with an identity option
  3  --repo is not a main checkout fit for a snapshot, one stderr line per
     problem; a bad identity or signing option; or (--effort) no git
     setup for the effort, or settings.sh refused it (its stderr first)
  4  git is missing or failed; settings.sh missing or failed; or, with a
     signing key, show.sh missing, or failed after the SNAPSHOT: line
  5  the checkout changed during the run; no snapshot printed (run again).
     Refs under ${SEAT_BRANCHES} and ${REMOTE_REFS} may move meanwhile
     (worktrees commit and push); any other ref that changes counts
  129, 130, 143  stopped by HUP, INT or TERM

needs: POSIX sh, git 2.26+; with --effort, procedure-git-setup's settings.sh
beside procedure-git-worktree (and its jq); with a signing key, jq 1.6+,
../cards/cards-lib.sh from this script's folder, this skill's views/ and
human-view's scripts/show.sh and scripts/lib/render.sh in
${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills/human-view
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

# Prints $1 with each control character as "?", so a path can't split a stderr line.
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
	repo='' effort_dir='' identity_name='' identity_email='' signing_format='' signing_key=''
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
			--effort)
				take_value "$1" "${effort_dir}" "${2-}" DIR
				effort_dir=${option_value}
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
				usage_error "unknown option: ${shown_option}; expected --repo, --effort, --identity-name, --identity-email, --signing-format, --signing-key or --help"
				;;
		esac
		shift 2
	done
	[ -n "${repo}" ] || usage_error '--repo missing; expected --repo DIR'
	if [ -n "${effort_dir}" ]; then
		[ -z "${identity_name}${identity_email}${signing_format}${signing_key}" ] ||
			usage_error '--effort given with an identity option; expected --effort alone or the identity options'
		return 0
	fi
	[ -n "${identity_name}" ] || usage_error '--effort and --identity-name missing; expected --effort DIR or --identity-name N'
	[ -n "${identity_email}" ] || usage_error '--identity-email missing; expected --identity-email E'
	[ -z "${signing_format}" ] || [ -n "${signing_key}" ] || usage_error '--signing-format given alone; expected --signing-key K with it'
	[ -z "${signing_key}" ] || [ -n "${signing_format}" ] || usage_error '--signing-key given alone; expected --signing-format F with it'
}

# Sets the identity_* and signing_* variables from settings.sh get for
# --effort; its own lines say why it refused.
read_effort_identity() {
	settings_script="$(script_dir)/${SETTINGS}"
	[ -f "${settings_script}" ] || {
		shown_settings=$(printable "${settings_script}")
		die 4 "${shown_settings} not found; expected procedure-git-setup beside procedure-git-worktree"
	}
	settings_rc=0
	settings=$(sh "${settings_script}" get --effort "${effort_dir}" </dev/null) || settings_rc=$?
	case ${settings_rc} in
		0) ;;
		3 | 5) die 3 "settings.sh get refused the effort (exit ${settings_rc}); expected its git setup; no snapshot made" ;;
		*) die 4 "settings.sh get failed (exit ${settings_rc}); no snapshot made" ;;
	esac
	while IFS= read -r setting; do
		case ${setting} in
			NAME=*) identity_name=${setting#NAME=} ;;
			EMAIL=*) identity_email=${setting#EMAIL=} ;;
			SIGNING_FORMAT=*) signing_format=${setting#SIGNING_FORMAT=} ;;
			SIGNING_KEY=*) signing_key=${setting#SIGNING_KEY=} ;;
			*) ;;
		esac
	done <<EOF
${settings}
EOF
	[ -n "${identity_name}" ] && [ -n "${identity_email}" ] ||
		die 4 'settings.sh get printed no NAME or EMAIL line; expected both'
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

check_identity() {
	check_ident --identity-name "${identity_name}"
	check_ident --identity-email "${identity_email}"
	check_signing
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

# Refuses anything but a main checkout's top folder in a state a snapshot fits;
# sets git_dir and head.
check_repo() {
	shown_repo=$(printable "${repo}")
	case ${repo} in
		/*) ;;
		*) die 3 "--repo ${shown_repo} is not absolute; expected an absolute path" ;;
	esac
	[ -d "${repo}" ] || die 3 "--repo ${shown_repo} is not a folder; expected the main checkout's top folder"
	inside=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --is-inside-work-tree 2>/dev/null) || inside=''
	[ "${inside}" = true ] || die 3 "--repo ${shown_repo} is not a git work tree; expected a main checkout, not bare"
	physical_repo=$(cd -P -- "${repo}" && pwd -P) || physical_repo=''
	top_folder=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --show-toplevel 2>/dev/null) || top_folder=''
	shown_top_folder=$(printable "${top_folder}")
	[ -n "${top_folder}" ] && [ "${physical_repo}" = "${top_folder}" ] ||
		die 3 "--repo ${shown_repo} is not the checkout's top folder; expected ${shown_top_folder}"
	git_dir=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --absolute-git-dir 2>/dev/null) || git_dir=''
	common_dir=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=''
	[ -n "${git_dir}" ] && [ -n "${common_dir}" ] || die 4 "git could not name the git folders of ${shown_repo}; expected git 2.26+"
	[ "${git_dir}" = "${common_dir}" ] || die 3 "--repo ${shown_repo} is a linked worktree; expected the main checkout"
	check_state
}

check_state() {
	problems=0
	for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
		[ ! -e "${git_dir}/${state}" ] || {
			warn "--repo ${shown_repo} has ${state} under way; expected no merge, rebase, cherry-pick or revert"
			problems=$((problems + 1))
		}
	done
	sparse=$(git -C "${repo}" -c core.fsmonitor=false config --type=bool core.sparseCheckout 2>/dev/null) || sparse=false
	[ "${sparse}" != true ] || {
		warn "--repo ${shown_repo} is a sparse checkout; expected a full checkout, as files outside it would read as deleted"
		problems=$((problems + 1))
	}
	head=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet 'HEAD^{commit}' 2>/dev/null) || head=''
	[ -n "${head}" ] || {
		warn "--repo ${shown_repo} has no HEAD commit; expected a branch or detached HEAD on a commit"
		problems=$((problems + 1))
	}
	[ "${problems}" -eq 0 ] || exit 3
}

# Sets fp to the checkout's state the snapshot must not move, and fp_head;
# exits 4 when git can't read a part. Every git call here reads only.
fingerprint() {
	fp_head=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet HEAD) || fingerprint_failed
	fp_branch=$(git -C "${repo}" -c core.fsmonitor=false symbolic-ref -q HEAD) || fp_branch=detached
	index_file=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --path-format=absolute --git-path index) ||
		fingerprint_failed
	fp_index=none
	[ ! -f "${index_file}" ] || fp_index=$(cksum <"${index_file}") || fingerprint_failed
	git -C "${repo}" -c core.fsmonitor=false status --porcelain=v1 -z --untracked-files=all >"${work_dir}/status" ||
		fingerprint_failed
	git -C "${repo}" -c core.fsmonitor=false for-each-ref --format='%(objectname)%09%(refname)' >"${work_dir}/all-refs" ||
		fingerprint_failed
	awk -F '\t' -v seats="${SEAT_BRANCHES}" -v remotes="${REMOTE_REFS}" \
		'index($2, seats) != 1 && index($2, remotes) != 1' "${work_dir}/all-refs" >"${work_dir}/refs" ||
		fingerprint_failed
	git -C "${repo}" -c core.fsmonitor=false stash list --format=%H >"${work_dir}/stash" || fingerprint_failed
	fp_status=$(cksum <"${work_dir}/status") || fingerprint_failed
	fp_refs=$(cksum <"${work_dir}/refs") || fingerprint_failed
	fp_stash=$(cksum <"${work_dir}/stash") || fingerprint_failed
	fp="head ${fp_head} branch ${fp_branch} index ${fp_index} status ${fp_status} refs ${fp_refs} stash ${fp_stash}"
}

fingerprint_failed() {
	die 4 "git could not read the state of ${shown_repo}"
}

# Sets tree: the tree of HEAD with every change git sees, built in a temp index.
build_tree() {
	temp_index="${work_dir}/index"
	GIT_INDEX_FILE=${temp_index} git -C "${repo}" -c core.fsmonitor=false read-tree "${head}" 2>"${work_dir}/stderr" ||
		git_failed "git read-tree ${head}"
	GIT_INDEX_FILE=${temp_index} git -C "${repo}" -c core.fsmonitor=false -c advice.addEmbeddedRepo=false \
		add -A >/dev/null 2>"${work_dir}/stderr" ||
		git_failed 'git add -A into the temp index'
	tree=$(GIT_INDEX_FILE=${temp_index} git -C "${repo}" -c core.fsmonitor=false write-tree 2>"${work_dir}/stderr") ||
		git_failed 'git write-tree'
	head_tree=$(git -C "${repo}" -c core.fsmonitor=false rev-parse --verify --quiet "${head}^{tree}") ||
		git_failed "git rev-parse ${head}^{tree}"
}

# Sets snapshot: the commit of tree on HEAD by the identity; signed when a
# key is given, else or when signing fails unsigned.
make_snapshot() {
	if [ -n "${signing_key}" ]; then
		run_signed_snapshot
		if [ "${sign_rc}" -eq 0 ] && IFS= read -r snapshot <"${work_dir}/signed" && [ -n "${snapshot}" ]; then
			return 0
		fi
		make_unsigned
		say_unsigned
		return 0
	fi
	make_unsigned
}

make_unsigned() {
	# shellcheck disable=SC2310 # its status is the answer: commit_tree is one git command
	snapshot=$(commit_tree -c commit.gpgSign=false commit-tree --no-gpg-sign "${tree}" -p "${head}" -m "${MESSAGE}" \
		2>"${work_dir}/stderr") || git_failed 'git commit-tree'
}

# Replaces the calling (sub)shell with git, config and command "$@", as the
# identity, stdin closed and no hook; so a background call's PID is git's
# own.
commit_tree() {
	exec env GIT_AUTHOR_NAME="${identity_name}" GIT_AUTHOR_EMAIL="${identity_email}" \
		GIT_COMMITTER_NAME="${identity_name}" GIT_COMMITTER_EMAIL="${identity_email}" \
		git -C "${repo}" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@" </dev/null
}

# Writes the signed snapshot's sha to work_dir/signed in the background and
# stops it after SIGN_TIMEOUT seconds; sets sign_rc, and sign_timed_out from
# the watcher's marker. The watcher's own output goes nowhere, so a caller
# reading this script's output never waits on it.
run_signed_snapshot() {
	timeout_marker="${work_dir}/sign-timed-out"
	commit_tree -c "gpg.format=${signing_format}" -c "user.signingkey=${signing_key}" \
		commit-tree -S "${tree}" -p "${head}" -m "${MESSAGE}" >"${work_dir}/signed" 2>"${work_dir}/sign-stderr" &
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

# Sets card_unsigned to why the snapshot is unsigned: the time limit, or the
# signer's own first line, no gpg status line and not git's "gpg failed to
# sign" lead-in.
say_unsigned() {
	if [ "${sign_timed_out}" = yes ] && [ "${sign_rc}" -ne 0 ]; then
		card_unsigned="signing timed out after ${SIGN_TIMEOUT} s"
		return 0
	fi
	sign_reason=$(sed -e '/^\[GNUPG:\]/d' -e '/^error: gpg failed to sign the data/d' -e '/^[[:space:]]*$/d' \
		"${work_dir}/sign-stderr" | head -n 1) || sign_reason=''
	card_unsigned=$(printable "${sign_reason:-git commit-tree -S failed}")
}

# Sources the card printer, before a signed snapshot is tried, so a missing
# one makes nothing.
load_card_printer() {
	command -v jq >/dev/null 2>&1 || die 4 'jq not found; expected jq 1.6+ on PATH'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) || die 4 "this script's folder could not be entered"
	[ -f "${own_dir}/../cards/cards-lib.sh" ] || {
		shown_lib=$(printable "${own_dir}/../cards/cards-lib.sh")
		die 4 "${shown_lib} not found; expected the procedure's scripts folders whole"
	}
	# shellcheck source=../cards/cards-lib.sh
	. "${own_dir}/../cards/cards-lib.sh"
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	card_load_printer lines || die 4 "${card_problem}"
}

# Exits 4 naming step $1 and git's first stderr line.
git_failed() {
	first_line=$(head -n 1 "${work_dir}/stderr" 2>/dev/null) || first_line=''
	shown_line=$(printable "${first_line}")
	die 4 "$1 failed: ${shown_line}"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${work_dir}" ] || rm -rf -- "${work_dir}"
}

work_dir='' card_unsigned=''
trap clean_up EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

parse_args "$@"
command -v git >/dev/null 2>&1 || die 4 'git not found; expected git 2.26+ on PATH'
[ -z "${effort_dir}" ] || read_effort_identity
check_identity
[ -z "${signing_key}" ] || load_card_printer
check_repo
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/crucible-snapshot.XXXXXX") ||
	die 4 'mktemp could not create a work folder; expected a writable TMPDIR'
fingerprint
# The snapshot's parent is the HEAD the fingerprint saw, so a HEAD moved
# since check_repo can't slip past the comparison.
before=${fp} head=${fp_head}
build_tree
if [ "${tree}" = "${head_tree}" ]; then
	result="CLEAN: ${head}"
else
	make_snapshot
	result="SNAPSHOT: ${snapshot}"
fi
fingerprint
[ "${before}" = "${fp}" ] ||
	die 5 "the checkout ${shown_repo} changed during the run; expected it untouched (no snapshot printed)"
printf '%s\n' "${result}"
# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
[ -z "${card_unsigned}" ] || card_show_unsigned "${effort_dir}" ||
	die 4 "${hv_render_problem}; the snapshot is made unsigned, its line not shown"
