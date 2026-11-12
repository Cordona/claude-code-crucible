#!/usr/bin/env sh
# Lists the signing identities on this machine as the git setup card offers
# them: list-identities.sh's GPG and SSH identities, in its order, each with
# the key's comment dropped from its name, those with one option label
# merged, and only those settings.jq lets a writer save, at most its
# settings_max_identities. It ranks and recommends nothing and reads no
# repository: list-identities.sh and git run from /, so only the machine's
# own git config counts.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='identity-candidates.sh'
readonly MODULE='settings'
readonly COPY_NAME='git-setup-identities.json'
# The C locale keeps the shell byte-wise; jq reads and writes UTF-8.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT

# Prints the candidates array from $listing, list-identities.sh's stdout,
# whose IDENTITY_<n>_<FIELD>=<value> lines it reads in n order. An SSH
# identity has no name of its own; it, and any identity whose name is only
# a comment, takes git's user.name ($fallback_name).
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly CANDIDATES_JQ='include "settings";
{gpg: "openpgp", ssh: "ssh"} as $formats
| [$listing | split("\n")[] | capture("\\AIDENTITY_(?<n>[0-9]+)_(?<field>[A-Z_]+)=(?<value>.*)\\z")]
| group_by(.n | tonumber)
| map(reduce .[] as $line ({}; .[$line.field] = $line.value)
	| select($formats[.METHOD // ""] != null)
	| {name: ((.NAME // "") | sub("[[:space:]]*\\([^()]*\\)\\z"; "") | if . == "" then $fallback_name else . end),
	   email: (.EMAIL // ""),
	   signing: {format: $formats[.METHOD], key: (.SIGNING_KEY // "")},
	   fingerprint: (.FPR // "")}
	| select([settings_candidate_problems(settings_file_names)] | length == 0))
| reduce .[] as $candidate ([];
	if any(.[]; settings_identity_text == ($candidate | settings_identity_text)) then . else . + [$candidate] end)
| .[:settings_max_identities]'

usage() {
	cat <<EOF
usage: sh ${PROG} [--plan-out PATH --effort DIR]
       sh ${PROG} --help | -h

Lists this machine's GPG and SSH signing identities for the git setup card,
in list-identities.sh's order: each key's comment "(...)" dropped from its
name, an SSH identity named by git's user.name, one per option label, only
those ${MODULE}.jq lets settings.sh save, at most ${MODULE}.jq's
settings_max_identities. Reads no repository and ranks or recommends none.
Reads the GPG key ring of GNUPGHOME and the ssh agent of SSH_AUTH_SOCK, as
list-identities.sh does.

--plan-out PATH  also write the gate's plan, {"identities": <the array>}, to
                 PATH, the path open-gate.sh --plan-path printed: absolute,
                 not a folder or a symbolic link, in an existing folder;
                 with --effort
--effort DIR     the absolute effort folder: also keep the array, as the card
                 shows it, in DIR/drafts/main-thread/${COPY_NAME}, for
                 settings.sh write --pick; with --plan-out
Each file is replaced whole or left as it was; on exit 4 one may be written
and the other not. Nothing else is left behind (a SIGKILL aside).

stdout: one line, a JSON array of {"name", "email", "signing": {"format":
  "openpgp" or "ssh", "key": the key git's user.signingkey takes},
  "fingerprint": the key's fingerprint, "" when unknown}, in the card's
  option order; [] when the machine has no signing identity

exit codes:
  0  printed (and, with --plan-out, written); pass the plan path on
  2  wrong command line; fix the call
  3  refused: --effort is no effort folder; fix what stderr names
  4  list-identities.sh or jq missing or failed, or a file not written;
     show the human stderr, and stop

needs: POSIX sh, jq 1.6+; gpg, git, ssh-add and ssh-keygen as
list-identities.sh reads them (each optional); list-identities.sh and
${MODULE}.jq beside this script
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

parse_args() {
	plan_out='' effort='' seen_plan_out='' seen_effort=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--plan-out | --effort)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				if [ "$1" = --plan-out ]; then
					[ -z "${seen_plan_out}" ] || usage_error '--plan-out given twice; expected one'
					plan_out=$2 seen_plan_out=yes
				else
					[ -z "${seen_effort}" ] || usage_error '--effort given twice; expected one'
					effort=$2 seen_effort=yes
				fi
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --plan-out, --effort or --help"
				;;
		esac
	done
	[ "${seen_plan_out}" = "${seen_effort}" ] ||
		usage_error '--plan-out and --effort go together; expected both or neither'
	[ -z "${seen_plan_out}" ] || check_plan_out
}

check_plan_out() {
	shown_plan_out=$(printable "${plan_out}")
	case ${plan_out} in
		*[[:cntrl:]]*) usage_error '--plan-out holds a control character; expected one absolute path on one line' ;;
		/*) ;;
		*) usage_error "--plan-out ${shown_plan_out} is not absolute; expected the absolute path open-gate.sh --plan-path printed" ;;
	esac
	[ ! -L "${plan_out}" ] && [ ! -d "${plan_out}" ] ||
		usage_error "--plan-out ${shown_plan_out} is a folder or a symbolic link; expected a plain file path"
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets own_dir, absolute, since list-identities.sh runs from /.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 4 'jq not found; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) ||
		die 4 "this script's folder could not be entered; try running it by its absolute path"
	for neighbour in list-identities.sh "${MODULE}.jq"; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folder whole; try reinstalling procedure-git-setup"
		}
	done
}

# Sets copy_file in the physical effort folder's drafts/main-thread/, making
# it when it is missing; refuses a path that is no effort folder.
check_effort() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		*[[:cntrl:]]*) die 3 "--effort ${shown_effort} holds a control character; expected a plain path" ;;
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected the absolute effort folder" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder effort.sh start printed"
	cache_dir="${effort_dir}/drafts/main-thread"
	shown_cache=$(printable "${cache_dir}")
	if [ -L "${effort_dir}/drafts" ] || [ -L "${cache_dir}" ] || { [ -e "${cache_dir}" ] && [ ! -d "${cache_dir}" ]; }; then
		die 3 "${shown_cache} is a symbolic link or no folder; expected the effort's main-thread drafts folder"
	fi
	[ -d "${cache_dir}" ] || mkdir -p "${cache_dir}" ||
		die 4 "mkdir could not create ${shown_cache}; expected a writable effort folder; try ls -ld on it"
	copy_file="${cache_dir}/${COPY_NAME}"
	shown_copy=$(printable "${copy_file}")
	[ ! -L "${copy_file}" ] && [ ! -d "${copy_file}" ] ||
		die 3 "${shown_copy} is a folder or a symbolic link; expected a plain file path; try removing it"
}

# Sets listing to list-identities.sh's stdout: empty when it found no
# identity (its exit 1).
read_listing() {
	listing_status=0
	listing=$(cd / && sh "${own_dir}/list-identities.sh" 2>"${err_file}") || listing_status=$?
	case ${listing_status} in
		0) ;;
		1) listing='' ;;
		*)
			first_error=$(head -n 1 "${err_file}" | tr '[:cntrl:]' '?')
			die 4 "list-identities.sh failed (exit ${listing_status}): ${first_error}; try sh list-identities.sh by hand"
			;;
	esac
}

# Writes text $2 to file $1 (shown as $3) through a temp file beside it.
write_whole() {
	target_dir=${1%/*}
	temp_file=$(mktemp "${target_dir:-/}/.${1##*/}.XXXXXX" 2>/dev/null) ||
		die 4 "mktemp could not create a temp file beside $3; expected an existing writable folder; try ls -ld on it"
	printf '%s\n' "$2" >"${temp_file}" ||
		die 4 "could not write the temp file beside $3; expected free space; try df on it"
	mv -f "${temp_file}" "$1" ||
		die 4 "mv could not move the temp file onto $3; expected a writable folder; try ls -ld on it"
	temp_file=''
}

# Removes the temp files, when any are left.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${err_file}" ] || rm -f "${err_file}"
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
}

err_file='' temp_file=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp files go on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
load_dependencies
[ -z "${seen_effort}" ] || check_effort
err_file=$(mktemp "${TMPDIR:-/tmp}/identity-candidates.XXXXXX") ||
	die 4 'mktemp could not create a temp file; expected a writable TMPDIR; try TMPDIR=/tmp'
read_listing
fallback_name=''
if command -v git >/dev/null 2>&1; then
	fallback_name=$(cd / && git config user.name 2>/dev/null) || fallback_name=''
fi
candidates=$(jq -nc -L "${own_dir}" --arg listing "${listing}" --arg fallback_name "${fallback_name}" \
	"${CANDIDATES_JQ}") ||
	die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version"
if [ -n "${seen_plan_out}" ]; then
	plan=$(printf '%s\n' "${candidates}" | jq -c '{identities: .}') ||
		die 4 'jq failed building the plan; expected jq 1.6+; try jq --version'
	write_whole "${copy_file}" "${candidates}" "${shown_copy}"
	write_whole "${plan_out}" "${plan}" "${shown_plan_out}"
fi
printf '%s\n' "${candidates}"
