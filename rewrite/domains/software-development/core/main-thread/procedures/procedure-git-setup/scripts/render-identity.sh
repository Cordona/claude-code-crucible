#!/usr/bin/env sh
# Renders the answer to "what's this repo's identity?" as one card, so the
# main thread never hand-formats it: who the repo signs as, or why its
# identity can't sign. Reads resolve-identity.sh's IDENTITY_* lines on stdin,
# or runs it in --repo; views/identity.jq lays the card out and human-view's
# show.sh prints it.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../framework/core/engine/human-view/scripts/lib
set -eu

readonly PROG='render-identity.sh'
readonly MODULE='settings'
readonly RESOLVER='resolve-identity.sh'
readonly VIEW_LIB='human-view'
readonly SHOW='scripts/show.sh'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly VIEW_NAME='identity'
# The C locale keeps the shell byte-wise; jq reads the lines as UTF-8.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

# The card's data for views/identity.jq, from $lines (resolve-identity.sh's
# stdout) and $reason (its first error, "" when none). A reconciled identity
# signs, named by its label; any other can't, for $reason, or for a key that
# doesn't carry the email.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_DATA_JQ='include "settings";
([$lines | split("\n")[] | capture("\\AIDENTITY_(?<field>[A-Z_]+)=(?<value>.*)\\z")]
	| map({key: .field, value: .value}) | from_entries) as $id
| if $id.STATUS == "reconciled" then
	{signs: true,
	 identity: ({name: $id.NAME, email: $id.COMMITTER_EMAIL,
		signing: {format: (if $id.SIGNING_METHOD == "ssh" then "ssh" else "openpgp" end),
			key: (if ($id.SIGNING_KEY_ID // "") == "" then $id.SIGNING_KEY else $id.SIGNING_KEY_ID end)},
		fingerprint: ($id.SIGNING_KEY_FPR // "")} | settings_identity_text)}
  else {signs: false, reason: $reason, email: $id.COMMITTER_EMAIL}
  end'

usage() {
	cat <<EOF
usage: sh ${PROG} --repo DIR
       sh ${RESOLVER} [OPTIONS] | sh ${PROG}
       sh ${PROG} --help | -h

Prints the identity a repository signs its commits as, in one card for the
human: who it signs as and with which key, or why it can't sign. Reads
${RESOLVER}'s stdout on stdin, or with --repo runs ${RESOLVER} there,
which changes nothing. The card is printed by ${VIEW_LIB}'s show.sh from
views/${VIEW_NAME}.jq and recorded as owed this session (see show.sh --help).

--repo DIR  the repository to ask, a git work tree; stdin is then not read
CLAUDE_CONFIG_DIR  holds the skills, in its skills/; default \$HOME/.claude
CLAUDE_CODE_SESSION_ID  the session the card is owed in; unset: printed only

stdout on exit 0: the card identity (views/identity.jq), one line: who the
  repo signs as, or why it can't sign
stderr on exit 5: "${PROG}: install:", a prefix no other exit prints

exit codes:
  0  printed; go on
  2  wrong command line; fix the call
  3  refused: --repo, or stdin holds no IDENTITY_STATUS line; fix what
     stderr names and rerun once, else show the human stderr
  4  stdout closed before the card was written; show the human the exit
     code, and stop
  5  an install fault, or show.sh failed; show the human stderr, and stop
  129, 130, 143  stopped by HUP, INT or TERM; show the human the exit code

needs: POSIX sh, jq 1.6+, the ${VIEW_LIB} skill's ${SHOW} and
${RENDER_LIB} in the skills; views/${VIEW_NAME}.jq in this skill;
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

# Sets own_dir, views_dir and show_script, loads origin-lib.sh and sources
# human-view's card printer lib; exits 5 when a tool or file is missing.
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
	views_dir="${own_path}/../views"
	view_skill_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${VIEW_LIB}"
	render_lib="${view_skill_dir}/${RENDER_LIB}"
	require_file "${render_lib}" 'card printer lib' "install the ${VIEW_LIB} skill"
	# shellcheck source=render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${view_skill_dir}/scripts" "${views_dir}" "${VIEW_NAME}" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
	[ -z "${repo}" ] || command -v git >/dev/null 2>&1 ||
		install_fault 'git missing; expected git on PATH; try installing it (macOS: xcode-select --install; Linux: the distro'\''s git package)'
	# shellcheck source=origin-lib.sh
	. "${own_dir}/origin-lib.sh"
}

# Exits 5 unless file $1, the $2, is readable; $3 says how to get it.
require_file() {
	[ -f "$1" ] && [ -r "$1" ] || {
		shown_file=$(printable "$1")
		install_fault "$2 missing; expected ${shown_file}; $3"
	}
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
view_data=$(jq -nc -L "${own_dir}" --arg lines "${lines}" --arg reason "${reason}" "${VIEW_DATA_JQ}") ||
	install_fault "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version, then rerun"
# A closed stdout exits 4 before show.sh records a card nobody can see.
{ true 3>&1; } 2>/dev/null || exit 4
# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
hv_show_card "${show_script}" "${views_dir}" "${VIEW_NAME}" '' "${view_data}" ||
	install_fault "${hv_render_problem}; expected the card shown from views/${VIEW_NAME}.jq; try reinstalling procedure-git-setup and the ${VIEW_LIB} skill"
