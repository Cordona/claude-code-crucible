# Shared by the git-commit scripts: the refusal line, the neighbours found
# beside this skill, the repository check through dev-base, the effort's
# identity read through git-identity, the message with the effort's trailer,
# and git run as the identity, signed under dev-base's time limit. Sourced,
# so it sets no shell option; its names start with gc_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # gc_prog and gc_work are set by each sourcing script
# shellcheck disable=SC2034 # the gc_ values are read by the sourcing scripts

# A signer that waits on something (a pinentry, a card) is given up after
# this many seconds, and the commit is made unsigned.
GC_SIGN_TIMEOUT=10
# run-timed.sh's exit for a command it stopped at the limit.
GC_TIMED_OUT=124

# The C locale keeps the shell and its pattern classes byte-wise.
LC_ALL=C
GIT_TERMINAL_PROMPT=0
GIT_OPTIONAL_LOCKS=0
export LC_ALL GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS
# An inherited repository override would make git act elsewhere, and an
# inherited author or committer would win over the identity's -c flags.
# With no GPG_TTY a signer that wants a terminal fails instead of waiting.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX GPG_TTY \
	GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL
# ssh-keygen asks an SSH key's passphrase only of this askpass, which fails,
# so it never reads the terminal; gpg's pinentry is left to its own window.
SSH_ASKPASS_REQUIRE=force
SSH_ASKPASS=/usr/bin/false
[ -x "${SSH_ASKPASS}" ] || SSH_ASKPASS=/bin/false
export SSH_ASKPASS_REQUIRE SSH_ASKPASS

gc_refuse() {
	printf '%s: %s\n' "${gc_prog}" "$1" >&2
	exit 2
}

# Sets gc_identity_get to git-identity's identity-get.sh, and gc_repo_of and
# gc_run_timed to dev-base's scripts, in the skills folder holding this
# component, cut from the script's own path $1 as text, so a skill link
# holds. Refuses when one of them isn't beside this skill.
gc_find_neighbours() {
	gc_self=$1
	case ${gc_self} in /*) ;; *) gc_self="$(pwd)/${gc_self}" ;; esac
	gc_skills=${gc_self%/*/*/*/*}
	gc_identity_get="${gc_skills}/git-identity/scripts/main/identity-get.sh"
	[ -f "${gc_identity_get}" ] || gc_refuse "git-identity isn't beside this skill (expected ${gc_identity_get}); install first"
	gc_repo_of="${gc_skills}/dev-base/scripts/internal/repo-of.sh"
	gc_run_timed="${gc_skills}/dev-base/scripts/internal/run-timed.sh"
	for gc_need in "${gc_repo_of}" "${gc_run_timed}"; do
		[ -f "${gc_need}" ] || gc_refuse "dev-base isn't beside this skill (expected ${gc_need}); install first"
	done
}

# Refuses folder $1 unless dev-base's repo-of.sh finds it in a checkout or
# one of its worktrees; sets gc_repo_dir to $1, where git then runs.
gc_check_repo() {
	case $1 in /*) ;; *) gc_refuse '--repo must be an absolute folder' ;; esac
	gc_said=$(sh "${gc_repo_of}" --dir "$1" 2>&1) || gc_refuse "--repo ${gc_said#repo-of.sh: }"
	gc_repo_dir=$1
}

# git in gc_repo_dir, no fsmonitor.
gc_repo_git() {
	git -C "${gc_repo_dir}" -c core.fsmonitor=false "$@"
}

# Sets gc_effort_name to the folder name of effort $1, refusing a folder
# that is not absolute or not an effort.
gc_check_effort() {
	case $1 in /*) ;; *) gc_refuse '--effort must be an absolute folder' ;; esac
	[ -d "$1/events" ] || gc_refuse "$1 is not an effort folder"
	gc_effort_name=$(cd -- "$1" && pwd -P) || gc_refuse "$1 can't be read"
	gc_effort_name=${gc_effort_name##*/}
}

# Sets gc_name, gc_email, gc_format and gc_key to effort $1's identity for
# the repository folder $2 belongs to. Refuses when it has none.
gc_read_identity() {
	gc_rc=0
	gc_identity=$(sh "${gc_identity_get}" --effort "$1" --repo "$2" 2>"${gc_work}/identity-stderr") || gc_rc=$?
	case ${gc_rc} in
		0) ;;
		5) gc_refuse "the effort has no identity for the repository of $2; set the identity first (git-identity)" ;;
		*)
			gc_said=$(head -n 1 "${gc_work}/identity-stderr") || gc_said=''
			gc_refuse "identity-get.sh refused: ${gc_said}"
			;;
	esac
	gc_name=$(printf '%s' "${gc_identity}" | jq -r '.name')
	gc_email=$(printf '%s' "${gc_identity}" | jq -r '.email')
	gc_format=$(printf '%s' "${gc_identity}" | jq -r '.signing.format')
	gc_key=$(printf '%s' "${gc_identity}" | jq -r '.signing.key')
}

# Writes gc_work/message: the message file $1 with the trailer
# "Effort: <gc_effort_name>", added by git interpret-trailers in repository
# $2 when the message has none. Refuses an empty message, one holding a NUL
# byte (git keeps a message only up to it), or one whose Effort trailer
# names another effort.
gc_effort_message() {
	case $1 in /*) ;; *) gc_refuse '--message-file must be an absolute path' ;; esac
	[ -f "$1" ] && [ -r "$1" ] || gc_refuse "--message-file $1 is not a readable file"
	cp -- "$1" "${gc_work}/given-message" || gc_refuse "--message-file $1 could not be copied"
	[ -s "${gc_work}/given-message" ] || gc_refuse "--message-file $1 is empty"
	gc_nuls=$(tr -cd '\000' <"${gc_work}/given-message" | wc -c)
	[ "${gc_nuls}" -eq 0 ] || gc_refuse "--message-file $1 holds a NUL byte"
	gc_claimed=$(git -C "$2" interpret-trailers --parse <"${gc_work}/given-message" | sed -n 's/^Effort: //p' | sort -u)
	case ${gc_claimed} in
		'')
			git -C "$2" interpret-trailers --where end --trailer "Effort: ${gc_effort_name}" \
				<"${gc_work}/given-message" >"${gc_work}/message" || gc_refuse 'git interpret-trailers could not add the Effort trailer'
			;;
		"${gc_effort_name}") cp -- "${gc_work}/given-message" "${gc_work}/message" ;;
		*) gc_refuse "--message-file names another effort in its Effort trailer; expected Effort: ${gc_effort_name} or none" ;;
	esac
}

# Runs git in folder $1 as the effort's identity, never signing by config;
# the rest of "$@" is the git command, -c flags first.
gc_identity_git() {
	gc_in=$1
	shift
	git -C "${gc_in}" -c core.fsmonitor=false -c "user.name=${gc_name}" -c "user.email=${gc_email}" \
		-c commit.gpgSign=false "$@"
}

# Runs gc_identity_git's command for folder $1 with the identity's signing
# key, through dev-base's run-timed.sh, stopped with everything it started
# after GC_SIGN_TIMEOUT seconds; stdin closed, stdout to gc_work/signed-out,
# stderr to gc_work/sign-stderr. Sets gc_sign_rc, and gc_sign_reason when it
# failed: the time limit, or the signer's first line.
gc_run_signed() {
	gc_in=$1
	shift
	sh "${gc_run_timed}" --seconds "${GC_SIGN_TIMEOUT}" -- \
		git -C "${gc_in}" -c core.fsmonitor=false -c "user.name=${gc_name}" -c "user.email=${gc_email}" \
		-c commit.gpgSign=false -c "gpg.format=${gc_format}" -c "user.signingkey=${gc_key}" "$@" \
		</dev/null >"${gc_work}/signed-out" 2>"${gc_work}/sign-stderr" &
	gc_signer_pid=$!
	gc_sign_rc=0
	wait "${gc_signer_pid}" || gc_sign_rc=$?
	gc_signer_pid=''
	gc_sign_reason=''
	case ${gc_sign_rc} in
		0) ;;
		"${GC_TIMED_OUT}") gc_sign_reason="signing timed out after ${GC_SIGN_TIMEOUT} s" ;;
		*)
			gc_sign_reason=$(sed -e '/^\[GNUPG:\]/d' -e '/^error: gpg failed to sign the data/d' -e '/^[[:space:]]*$/d' \
				"${gc_work}/sign-stderr" | head -n 1)
			gc_sign_reason=$(printf '%s' "${gc_sign_reason:-signing failed}" | tr '[:cntrl:]' '?')
			;;
	esac
}

# Says on stderr why a commit was made unsigned.
gc_say_unsigned() {
	printf '%s: unsigned: %s\n' "${gc_prog}" "${gc_sign_reason}" >&2
}

# Prints true when commit $2 in repository $1 carries a signature, else false.
gc_carries_signature() {
	if git -C "$1" cat-file commit "$2" | sed '/^$/q' | grep -q '^gpgsig'; then
		printf 'true'
	else
		printf 'false'
	fi
}

# Stops a signer still running, with everything it started, and removes the
# work folder.
gc_clean_up() {
	[ -z "${gc_signer_pid-}" ] || kill "${gc_signer_pid}" 2>/dev/null || :
	[ -z "${gc_work-}" ] || rm -rf -- "${gc_work}"
}

# Makes the private work folder gc_work, removed on exit.
gc_make_work() {
	gc_work=''
	trap gc_clean_up EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	gc_work=$(mktemp -d "${TMPDIR:-/tmp}/git-commit.XXXXXX") || gc_refuse 'mktemp could not make a work folder'
}
