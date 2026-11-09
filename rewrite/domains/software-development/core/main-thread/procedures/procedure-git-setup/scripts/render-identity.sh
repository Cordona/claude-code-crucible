#!/usr/bin/env sh
# Renders the answer to "what's this repo's identity?" as one line, so the
# main thread never hand-formats it: who the repo signs as, or why its
# identity can't sign. Reads resolve-identity.sh's IDENTITY_* lines on stdin,
# or runs it in --repo.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='render-identity.sh'
readonly MODULE='settings'
readonly RESOLVER='resolve-identity.sh'
readonly RENDER_LIB='human-view'
# The C locale keeps the shell byte-wise; jq reads the lines as UTF-8.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

# The line, from $lines (resolve-identity.sh's stdout) and $reason (its first
# error, "" when none). A reconciled identity signs; any other can't, for
# $reason, or for a key that doesn't carry the email.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly LINE_JQ='include "settings";
include "view";
def shown: gsub("[\u0000-\u001f\u007f\u2028\u2029]"; "?") | gsub("(?<mark>[\\\\*_`])"; "\\\(.mark)");
([$lines | split("\n")[] | capture("\\AIDENTITY_(?<field>[A-Z_]+)=(?<value>.*)\\z")]
	| map({key: .field, value: .value}) | from_entries) as $id
| if $id.STATUS == "reconciled" then
	({format: (if $id.SIGNING_METHOD == "ssh" then "ssh" else "openpgp" end),
	  key: (if ($id.SIGNING_KEY_ID // "") == "" then $id.SIGNING_KEY else $id.SIGNING_KEY_ID end)}
	 | settings_key_text($id.SIGNING_KEY_FPR // "")) as $key
	| status_line("done"; "This repo signs as \($id.NAME | shown) · \($id.COMMITTER_EMAIL | shown) · \($key | shown) ✅")
  else
	(if $reason != "" then $reason
	 else "its signing key does not carry \($id.COMMITTER_EMAIL // "the email")" end) as $why
	| status_line("attention"; "This repo'\''s identity can'\''t sign: \($why | shown)")
  end'

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR
       sh ${RESOLVER} [OPTIONS] | sh ${PROG}
       sh ${PROG} --help | -h

Prints the identity a repository signs its commits as, in one line for the
human: who it signs as and with which key, or why it can't sign. Reads
${RESOLVER}'s stdout on stdin, or with --repo runs ${RESOLVER} there,
which changes nothing. No file is written.

--repo DIR  the repository to ask, a git work tree; stdin is then not read
CLAUDE_CONFIG_DIR  holds the skills, in its skills/; default \$HOME/.claude

stdout on exit 0: the line, "This repo signs as <name> · <email> · GPG key
  <key> ✅" (or "SSH key <fingerprint>"), or "This repo's identity can't
  sign: <reason>"
stderr on exit 5: "${PROG}: install:", a prefix no other exit prints

exit codes:
  0  printed; relay the line
  2  wrong command line; fix the call
  3  refused: --repo, or stdin holds no IDENTITY_STATUS line; fix what
     stderr names and rerun once, else show the human stderr
  4  stdout closed before the line was written; show the human the exit
     code, and stop
  5  an install fault; show the human stderr, and stop

needs: POSIX sh, jq 1.6+, the ${RENDER_LIB} skill's view.jq in the skills;
${MODULE}.jq and origin-lib.sh beside this script; with --repo, git and
${RESOLVER} beside this script
EOF
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

die() {
	warn "$2"
	exit "$1"
}

# Prints an install fault (a missing or failing tool or file, never a problem
# of the input) with the "install:" prefix and exits 5.
install_fault() {
	warn "install: $1"
	exit 5
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

parse_args() {
	repo=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--repo)
				[ -z "${repo}" ] || usage_error '--repo given twice; expected one'
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error '--repo needs a value; expected --repo DIR'
				repo=$2
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --repo DIR or --help"
				;;
		esac
	done
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets own_dir and render_lib_dir and loads origin-lib.sh; exits 5 when a
# tool or file is missing.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) ||
		install_fault "this script's folder could not be entered; try running it by its absolute path"
	needed="${MODULE}.jq origin-lib.sh"
	[ -z "${repo}" ] || needed="${needed} ${RESOLVER}"
	for neighbour in ${needed}; do
		[ -f "${own_dir}/${neighbour}" ] && [ -r "${own_dir}/${neighbour}" ] ||
			install_fault "${neighbour} missing; expected it beside ${PROG}; reinstall the procedure-git-setup skill"
	done
	render_lib_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${RENDER_LIB}"
	[ -f "${render_lib_dir}/view.jq" ] && [ -r "${render_lib_dir}/view.jq" ] ||
		install_fault "layout module missing; expected ${render_lib_dir}/view.jq; install the ${RENDER_LIB} skill"
	[ -z "${repo}" ] || command -v git >/dev/null 2>&1 ||
		install_fault 'git missing; expected git on PATH; try installing it (macOS: xcode-select --install; Linux: the distro'\''s git package)'
	# shellcheck source=origin-lib.sh
	. "${own_dir}/origin-lib.sh"
}

# Sets lines and reason from resolve-identity.sh run in the repo: its stdout,
# and the reason of its first error line when it refused the identity.
resolve_in_repo() {
	check_repo "${repo}"
	err_file=$(mktemp "${TMPDIR:-/tmp}/render-identity.XXXXXX") ||
		install_fault 'mktemp could not create a temp file; expected a writable TMPDIR; try TMPDIR=/tmp'
	resolve_rc=0
	lines=$(cd "${repo}" && sh "${own_dir}/${RESOLVER}" </dev/null 2>"${err_file}") || resolve_rc=$?
	case ${resolve_rc} in
		0 | 1) ;;
		*)
			first_error=$(head -n 1 "${err_file}" | tr '[:cntrl:]' '?')
			install_fault "${RESOLVER} failed (exit ${resolve_rc}): ${first_error}; try running it by hand in the repo"
			;;
	esac
	reason=$(sed -n 's/^[^:]*: error: //p' "${err_file}" | head -n 1)
}

# Sets lines from stdin, refusing input with no IDENTITY_STATUS line.
read_stdin() {
	lines=$(cat)
	reason=''
	case ${lines} in
		IDENTITY_STATUS=* | *"
IDENTITY_STATUS="*) ;;
		*) die 3 "stdin holds no IDENTITY_STATUS line; expected ${RESOLVER}'s stdout; try --repo DIR instead" ;;
	esac
}

# Removes the temp file, when one is left.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${err_file}" ] || rm -f "${err_file}"
}

err_file=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp file goes on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
load_dependencies
if [ -n "${repo}" ]; then
	resolve_in_repo
else
	read_stdin
fi
output=$(jq -nr -L "${own_dir}" -L "${render_lib_dir}" --arg lines "${lines}" --arg reason "${reason}" "${LINE_JQ}") ||
	install_fault "jq failed; expected jq 1.6+, ${MODULE}.jq beside ${PROG} and ${render_lib_dir}/view.jq; try jq --version, then rerun"
# Ignoring SIGPIPE turns a closed reader into a failed write this script can
# tell apart from a jq fault, rather than a silent kill.
trap '' PIPE
printf '%s\n' "${output}" 2>/dev/null || exit 4
