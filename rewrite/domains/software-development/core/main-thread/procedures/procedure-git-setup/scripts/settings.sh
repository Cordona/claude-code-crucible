#!/usr/bin/env sh
# The only writer and reader of an effort's git settings: the identity its
# worker commits are authored and signed with, and whether they are pushed.
# Each write is one settings.set event, through the crucible skill's
# events.sh, and the newest is the settings. settings.jq owns the shape and
# checks every value, so the shell never edits JSON.
# shellcheck source-path=SCRIPTDIR
set -eu
umask 077

readonly PROG='settings.sh'
readonly MODULE='settings'
readonly EVENT_TYPE='settings.set'
readonly EVENTS_SCRIPT="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/crucible/scripts/events.sh"
readonly COMMANDS='write get'
readonly CANDIDATES='identity-candidates.sh'
readonly RESOLVER='resolve-identity.sh'
# Where identity-candidates.sh --effort keeps the identities the card showed.
readonly COPY_PATH='drafts/main-thread/git-setup-identities.json'
# get's exit code when the effort has no settings.set event yet.
readonly EXIT_NO_SETUP=5
# The C locale keeps the shell byte-wise; jq reads and writes UTF-8.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

# Prints {problems, file, saved} for the given options ($ARGS.named holds
# only those given, and the key's fingerprint, "" when unknown): the
# refusals, the settings to write and the saved line.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly WRITE_JQ='include "settings";
$ARGS.named as $given
| {identity: "the identity", name: "--name", email: "--email", signing: "the signing key",
   format: "--signing-format", key: "--signing-key", auto_push: "--auto-push", remote: "the remote"} as $names
| def given($fields): reduce $fields[] as $field ({}; if $given | has($field) then .[$field] = $given[$field] else . end);
(given(["format", "key"]) | if . == {} then null else . end) as $signing
| {identity: (given(["name", "email"]) + {signing: $signing}),
   auto_push: ($given.auto_push == "yes"), remote: settings_remote} as $file
| {problems: [$file | settings_problems($names)], file: $file,
   saved: "Git setup saved: \($file.identity + {fingerprint: $given.fingerprint} | settings_identity_text); auto-push \(if $file.auto_push then "on" else "off" end)."}'

# Prints the identity --pick or --pick-label names, {"pick": <identity or
# null>, "count": <identities>}, from $copy (the kept copy, slurped) and
# $fresh (a listing made now), by number $pick or, when $label is not null,
# by its option label; or one "PROBLEM <problem>" line when the copy is no
# array, the listing changed since it was kept, or no identity has $label.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PICK_JQ='include "settings";
($fresh | length) as $count
| if ($copy | length) != 1 or ($copy[0] | type) != "array"
then "PROBLEM \($at) is not one JSON array; expected the identities the card showed; try the gate again from its plan"
elif $copy[0] != $fresh then "PROBLEM the signing identities on this machine changed since the card was shown; expected the list it showed; try the gate again from its plan"
elif $label == null then {pick: $fresh[$pick - 1], count: $count}
else [$fresh[] | select(settings_identity_text == $label)][0] as $match
	| if $match == null and $count > 0
	then "PROBLEM no identity the card showed is labelled \($label | tojson); expected one of its option labels as it showed them; try the gate again from its plan"
	else {pick: $match, count: $count} end
end'

# Prints the get lines of the slurped file when its shape fits, otherwise
# one "PROBLEM <$at>: <problem>" line per problem.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly GET_JQ='include "settings";
if length != 1 then "PROBLEM \($at): \(length) JSON values; expected one settings object"
else .[0] | [settings_shape_problems(settings_file_names)] as $problems
	| if ($problems | length) > 0 then $problems[] | "PROBLEM \($at): \(.)" else settings_lines end
end'

usage() {
	cat <<EOF
usage: sh ${PROG} write --effort DIR --name N --email E [--signing-format F --signing-key K] [--auto-push yes|no] [--repo DIR]
       sh ${PROG} write --effort DIR --pick N [--auto-push yes|no] [--repo DIR]
       sh ${PROG} write --effort DIR --pick-label LABEL [--auto-push yes|no] [--repo DIR]
       sh ${PROG} get --effort DIR
       sh ${PROG} --help | -h

Keeps an effort's git settings as ${EVENT_TYPE} events, the newest one the
settings; their shape and value rules are in ${MODULE}.jq. write appends one
only when every value fits (needs CLAUDE_CODE_SESSION_ID); a refused write
appends none. get only reads the newest, and checks its shape, not write's
length caps.

--effort DIR          absolute path of the effort folder
--name N              the author and committer name
--email E             the author and committer email
--pick N              write identity N, counted from 1, of those the card
                      showed, kept in <effort>/${COPY_PATH};
                      refused when ${CANDIDATES} now lists others; not with
                      --pick-label, --name, --email or --signing-*
--pick-label LABEL    write the identity of those the card showed whose
                      option label, as render-git-setup.sh --question
                      labels it, is LABEL exactly; refused when none is,
                      and as --pick is; not with --pick, --name, --email or
                      --signing-*
--signing-format F    openpgp or ssh, as git's gpg.format; with --signing-key
--signing-key K       the key git's user.signingkey takes; with
                      --signing-format; checked by ${RESOLVER} with the
                      name and email; an SSH key needs git's
                      gpg.ssh.allowedSignersFile, the only source of its
                      email; both left out: commits are unsigned
--auto-push yes|no    whether the stop hook pushes each worker commit; needed
                      with --repo; without it, no
--repo DIR            the repository the session runs in, a git work tree;
                      --auto-push yes needs it and an origin remote in it;
                      ${RESOLVER} runs in it; left out: no repository

stdout, write: one line, "Git setup saved: ..."
stdout, get: these lines, in this order; a value holds no control character
  and runs to the end of its line (read up to the first "=", never eval):
  NAME=<name>
  EMAIL=<email>
  SIGNING_FORMAT=<openpgp, ssh or empty: unsigned>
  SIGNING_KEY=<the key, or empty: unsigned>
  AUTO_PUSH=<yes or no>
  REMOTE=origin

exit codes:
  0  done; relay write's line, read get's
  2  wrong command line; fix the call
  3  refused: a value, the effort folder, --repo, --pick, a typed key
     ${RESOLVER} refused or failed on, --pick-label, or (get) a file that breaks ${MODULE}.jq;
     stderr names each problem; show the human stderr, then (write) ask
     again from the gate, (get) stop
  4  jq, git or a script beside this one missing or failed, or the file
     could not be written; show the human stderr, and stop
  ${EXIT_NO_SETUP}  (get) no git setup for this effort yet; run the git setup
     gate

needs: POSIX sh, jq 1.6+, git (with --repo or --signing-key); the crucible
skill's events.sh; ${MODULE}.jq,
origin-lib.sh, ${CANDIDATES} (with --pick or --pick-label) and ${RESOLVER} (with
--signing-key) beside this script
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

# Refuses option $1 unless the command takes it, when given twice ($2 is
# "yes" once seen) or when no value follows it ($3 is how many arguments are
# left, the option included). An empty value is checked as a value.
check_option() {
	case " ${allowed} " in
		*" $1 "*) ;;
		*) usage_error "$1 is not an option of ${command}; expected ${allowed}" ;;
	esac
	[ "$2" != yes ] || usage_error "$1 given twice; expected one"
	[ "$3" -ge 2 ] || usage_error "$1 needs a value; expected $1 VALUE"
}

parse_args() {
	case ${1-} in
		-h | --help)
			usage
			exit 0
			;;
		'') usage_error "command missing; expected one of ${COMMANDS}" ;;
		write) allowed='--effort --pick --pick-label --name --email --signing-format --signing-key --auto-push --repo' ;;
		get) allowed='--effort' ;;
		*)
			shown_command=$(printable "$1")
			usage_error "unknown command: ${shown_command}; expected one of ${COMMANDS}"
			;;
	esac
	command=$1
	shift
	effort='' pick='' pick_label='' name='' email='' format='' key='' auto_push='' repo=''
	seen_effort='' seen_pick='' seen_pick_label='' seen_name='' seen_email='' seen_format='' seen_key='' seen_auto_push='' seen_repo=''
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--effort)
				check_option "$1" "${seen_effort}" "$#"
				effort=$2 seen_effort=yes
				;;
			--pick)
				check_option "$1" "${seen_pick}" "$#"
				pick=$2 seen_pick=yes
				;;
			--pick-label)
				check_option "$1" "${seen_pick_label}" "$#"
				pick_label=$2 seen_pick_label=yes
				;;
			--name)
				check_option "$1" "${seen_name}" "$#"
				name=$2 seen_name=yes
				;;
			--email)
				check_option "$1" "${seen_email}" "$#"
				email=$2 seen_email=yes
				;;
			--signing-format)
				check_option "$1" "${seen_format}" "$#"
				format=$2 seen_format=yes
				;;
			--signing-key)
				check_option "$1" "${seen_key}" "$#"
				key=$2 seen_key=yes
				;;
			--auto-push)
				check_option "$1" "${seen_auto_push}" "$#"
				auto_push=$2 seen_auto_push=yes
				;;
			--repo)
				check_option "$1" "${seen_repo}" "$#"
				repo=$2 seen_repo=yes
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected ${allowed} or --help"
				;;
		esac
		shift 2
	done
	require_options
}

# Refuses a command missing an option it needs. The identity's own options
# are checked as values (exit 3), so every refused value is named together.
require_options() {
	[ -n "${seen_effort}" ] || usage_error '--effort missing; expected --effort DIR'
	[ "${command}" = write ] || return 0
	[ -z "${seen_pick}" ] || [ -z "${seen_pick_label}" ] ||
		usage_error '--pick and --pick-label given together; expected one of them'
	picked="${seen_pick}${seen_pick_label}"
	[ -z "${picked}" ] || [ -z "${seen_name}${seen_email}${seen_format}${seen_key}" ] ||
		usage_error '--pick and --pick-label take no --name, --email or --signing-*; expected --pick N, --pick-label LABEL or a typed identity'
	[ -z "${seen_repo}" ] || [ -n "${seen_auto_push}" ] ||
		usage_error '--repo needs --auto-push; expected --auto-push yes or --auto-push no'
	[ -n "${seen_auto_push}" ] || auto_push=no
	case ${auto_push} in
		yes) [ -n "${seen_repo}" ] || usage_error '--auto-push yes needs --repo DIR; expected the repository the session runs in' ;;
		no) ;;
		*)
			shown_value=$(printable "${auto_push}")
			die 3 "--auto-push is ${shown_value}; expected yes or no"
			;;
	esac
}

script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets own_dir, absolute, and loads origin-lib.sh when write has a repo.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		die 4 'jq not found; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	own_path=$(script_dir)
	own_dir=$(cd -P -- "${own_path}" && pwd -P) ||
		die 4 "this script's folder could not be entered; try running it by its absolute path"
	needed="${MODULE}.jq origin-lib.sh"
	[ -z "${picked}" ] || needed="${needed} ${CANDIDATES}"
	[ -z "${seen_key}" ] || needed="${needed} ${RESOLVER}"
	for neighbour in ${needed}; do
		[ -f "${own_dir}/${neighbour}" ] || {
			shown_neighbour=$(printable "${own_dir}/${neighbour}")
			die 4 "${shown_neighbour} not found; expected the procedure's scripts folder whole; try reinstalling procedure-git-setup"
		}
	done
	[ -n "${seen_repo}${seen_key}" ] || return 0
	command -v git >/dev/null 2>&1 ||
		die 4 'git not found; expected git on PATH; try installing it (macOS: xcode-select --install; Linux: the distro'\''s git package)'
	# shellcheck source=origin-lib.sh
	. "${own_dir}/origin-lib.sh"
}

# Sets effort_dir, the physical effort folder, and effort without trailing
# slashes, as events.sh takes it; refuses a path that is no effort folder.
check_effort() {
	shown_effort=$(printable "${effort}")
	case ${effort} in
		*[[:cntrl:]]*) die 3 "--effort ${shown_effort} holds a control character; expected a plain path" ;;
		/*) ;;
		*) die 3 "--effort ${shown_effort} is not absolute; expected an absolute path" ;;
	esac
	effort_dir=$(cd -P -- "${effort}" 2>/dev/null && pwd -P) ||
		die 3 "--effort ${shown_effort} is not a folder; expected the effort folder"
	while [ "${effort}" != "${effort%/}" ]; do effort=${effort%/}; done
	[ -f "${EVENTS_SCRIPT}" ] || die 4 "events.sh not found at ${EVENTS_SCRIPT}; expected the crucible skill installed"
}

# Prints problem lines $1, when any, to stderr and exits 3.
refuse_problems() {
	[ -n "$1" ] || return 0
	while IFS= read -r problem; do
		warn "${problem}"
	done <<EOF
$1
EOF
	exit 3
}

# Sets name, email, fingerprint and (when it signs) format and key to the
# identity of those the card showed that --pick numbers or --pick-label
# labels, refusing a number or label it has no entry for or a listing that
# changed since the card.
pick_identity() {
	if [ -n "${seen_pick}" ]; then
		shown_number=$(printable "${pick}")
		shown_pick="--pick ${shown_number}"
		case ${pick} in
			'' | *[!0-9]* | 0*) die 3 "--pick is ${shown_number}; expected a number from 1" ;;
			*) ;;
		esac
		set -- --argjson pick "${pick}" --argjson label null
	else
		shown_pick="--pick-label $(printable "${pick_label}")"
		set -- --argjson pick null --arg label "${pick_label}"
	fi
	copy_file="${effort_dir}/${COPY_PATH}"
	shown_copy=$(printable "${copy_file}")
	[ -f "${copy_file}" ] && [ ! -L "${copy_file}" ] ||
		die 3 "${shown_pick} refused: ${shown_copy} is missing; expected the identities the card showed; try the gate again from its plan"
	jq -s . "${copy_file}" >/dev/null 2>&1 ||
		die 3 "${shown_pick} refused: ${shown_copy} is not valid JSON; expected the identities the card showed; try the gate again from its plan"
	candidates_rc=0
	fresh=$(sh "${own_dir}/${CANDIDATES}") || candidates_rc=$?
	[ "${candidates_rc}" -eq 0 ] ||
		die 4 "${CANDIDATES} failed (exit ${candidates_rc}); its own lines above say why; try running it by hand"
	result=$(jq -nc -L "${own_dir}" --slurpfile copy "${copy_file}" --argjson fresh "${fresh}" "$@" \
		--arg at "${shown_copy}" "${PICK_JQ}") ||
		die 4 "jq could not compare ${shown_copy} with what ${CANDIDATES} printed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version"
	case ${result} in
		'"PROBLEM '*)
			problem=$(printf '%s\n' "${result}" | jq -r '.[8:]') ||
				die 4 "jq could not read the pick problem; expected jq 1.6+; try jq --version"
			die 3 "${shown_pick} refused: ${problem}"
			;;
		*) ;;
	esac
	count=$(picked_field '.count')
	[ "${count}" -gt 0 ] ||
		die 3 "${shown_pick} refused: the card showed no signing identity; expected --name and --email typed"
	signs=$(picked_field '.pick != null')
	[ "${signs}" = true ] ||
		die 3 "${shown_pick} is past the ${count} identities the card showed; expected a number from 1 to ${count}"
	name=$(picked_field '.pick.name') seen_name=yes
	email=$(picked_field '.pick.email') seen_email=yes
	fingerprint=$(picked_field '.pick.fingerprint')
	format=$(picked_field '.pick.signing.format') seen_format=yes
	key=$(picked_field '.pick.signing.key') seen_key=yes
}

# Prints jq filter $1 of the pick result, raw.
picked_field() {
	printf '%s\n' "${result}" | jq -r "$1" ||
		die 4 "jq could not read the picked identity; expected jq 1.6+; try jq --version"
}

# Runs resolve-identity.sh on the typed identity in --repo, or with none in
# an empty repository of its own, so only the machine's git config counts;
# refuses one it can't reconcile, naming its reasons, and sets fingerprint
# from its lines. An SSH key:: literal reaches it as a key file holding the
# key after key::, which it reads for every key type; an SSH key's email
# comes only from git's allowed-signers file.
check_typed_key() {
	temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/settings-resolve.XXXXXX") ||
		die 4 'mktemp could not create a temp folder; expected a writable TMPDIR; try TMPDIR=/tmp'
	resolve_dir=${repo}
	if [ -z "${seen_repo}" ]; then
		resolve_dir="${temp_dir}/repo"
		git init -q "${resolve_dir}" >/dev/null 2>&1 ||
			die 4 "git init failed in ${temp_dir}; expected git on PATH; try git --version"
	fi
	resolve_key=${key}
	if [ "${format}" = ssh ]; then
		check_allowed_signers
		write_literal_key_file
	fi
	resolve_rc=0
	(cd "${resolve_dir}" && sh "${own_dir}/${RESOLVER}" --name "${name}" --email "${email}" \
		--signingkey "${resolve_key}" --format "${format}") </dev/null >"${temp_dir}/out" 2>"${temp_dir}/err" ||
		resolve_rc=$?
	[ "${resolve_rc}" -eq 0 ] || refuse_typed_key
	fingerprint=$(sed -n 's/^IDENTITY_SIGNING_KEY_FPR=//p' "${temp_dir}/out" | tr -d '[:cntrl:]')
}

# Refuses a typed SSH key when git's allowed-signers file is not set where
# resolve-identity.sh reads it, or is no file it can read, as it is the only
# source of the key's email. A leading ~/ is read as resolve-identity.sh does.
check_allowed_signers() {
	allowed_signers=$(git -C "${resolve_dir}" config gpg.ssh.allowedSignersFile 2>/dev/null) || allowed_signers=''
	[ -n "${allowed_signers}" ] ||
		die 3 "the typed SSH key is refused: git's gpg.ssh.allowedSignersFile is not set, and a typed SSH key's email is checked only against that file; expected it set to a file listing this key for --email; try setting it, or the identity without a key"
	case ${allowed_signers} in
		\~/*) allowed_signers="${HOME}/${allowed_signers#\~/}" ;;
		*) ;;
	esac
	shown_signers=$(printable "${allowed_signers}")
	[ -f "${allowed_signers}" ] ||
		die 3 "the typed SSH key is refused: git's gpg.ssh.allowedSignersFile, ${shown_signers}, is not found or no plain file; expected a file listing this key for --email; try ls -l on it"
	[ -r "${allowed_signers}" ] ||
		die 3 "the typed SSH key is refused: git's gpg.ssh.allowedSignersFile, ${shown_signers}, is not readable; expected a file your user can read; try ls -l on it"
}

# Sets resolve_key to a key file in the temp folder holding a key:: literal's
# key, so resolve-identity.sh reads it as it reads any public key file;
# refuses a key:: with no key after it. Any other SSH key is left as typed.
write_literal_key_file() {
	case ${key} in
		key::*) ;;
		*) return 0 ;;
	esac
	literal_key=${key#key::}
	case ${literal_key} in
		*[![:space:]]*) ;;
		*) die 3 "the typed signing key is refused: --signing-key is key:: with no key after it; expected key::<type> <key>, such as key::ssh-ed25519 AAAA..." ;;
	esac
	resolve_key="${temp_dir}/literal-key.pub"
	printf '%s\n' "${literal_key}" >"${resolve_key}" ||
		die 4 "could not write the key file in ${temp_dir}; expected free space; try df on it"
}

# Refuses the typed key resolve-identity.sh exited non-zero on, exit 3, with
# its error lines as the reason, else its last stderr line that is not its
# usage text.
refuse_typed_key() {
	reasons=$(awk -v lead="${RESOLVER}: error: " 'index($0, lead) == 1 {
		joined = joined (joined == "" ? "" : "; ") substr($0, length(lead) + 1) } END { print joined }' \
		"${temp_dir}/err")
	if [ -z "${reasons}" ]; then
		sh "${own_dir}/${RESOLVER}" --help >"${temp_dir}/usage" 2>/dev/null || : >"${temp_dir}/usage"
		reasons=$(awk 'FNR == NR { usage[$0] = 1; next }
			NF > 0 && !($0 in usage) { last = $0 } END { print last }' "${temp_dir}/usage" "${temp_dir}/err")
	fi
	shown_reasons=$(printable "${reasons:-${RESOLVER} exited ${resolve_rc} and gave no reason}")
	die 3 "the typed signing key is refused: ${shown_reasons}; expected a key this machine signs with for --email; try another key, or the identity without one"
}

# Checks every value and writes the file, then prints the saved line.
run_write() {
	[ -z "${picked}" ] || pick_identity
	if [ -n "${seen_repo}" ]; then
		remote=$(jq -nr -L "${own_dir}" 'include "settings"; settings_remote') ||
			die 4 "jq failed reading the remote; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version"
		check_repo_origin "${repo}" "${remote}"
	fi
	[ "${auto_push}" != yes ] || [ "${repo_has_origin}" = yes ] ||
		die 3 "--auto-push yes refused: ${shown_repo} has no ${remote} remote; expected --auto-push no, or an ${remote} remote added first"
	set -- --arg auto_push "${auto_push}"
	[ -z "${seen_name}" ] || set -- "$@" --arg name "${name}"
	[ -z "${seen_email}" ] || set -- "$@" --arg email "${email}"
	[ -z "${seen_format}" ] || set -- "$@" --arg format "${format}"
	[ -z "${seen_key}" ] || set -- "$@" --arg key "${key}"
	result=$(jq -nc -L "${own_dir}" "$@" --arg fingerprint "${fingerprint}" "${WRITE_JQ}") ||
		die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version"
	problems=$(printf '%s\n' "${result}" | jq -r '.problems[]') ||
		die 4 'jq failed reading the problems; expected jq 1.6+; try jq --version'
	refuse_problems "${problems}"
	if [ -z "${picked}" ] && [ -n "${seen_key}" ]; then
		check_typed_key
		result=$(jq -nc -L "${own_dir}" "$@" --arg fingerprint "${fingerprint}" "${WRITE_JQ}") ||
			die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version"
	fi
	temp_file=$(mktemp) || die 4 'mktemp could not create a temp file; expected a writable TMPDIR'
	printf '%s\n' "${result}" | jq '.file' >"${temp_file}" ||
		die 4 'could not write the settings temp file; expected free space'
	sh "${EVENTS_SCRIPT}" append --effort "${effort}" --type "${EVENT_TYPE}" --by "${PROG}" --body-file "${temp_file}" >/dev/null </dev/null ||
		die 4 "events.sh append ${EVENT_TYPE} failed (its stderr is above); nothing was saved"
	printf '%s\n' "${result}" | jq -r '.saved' || die 4 'jq failed reading the saved line; expected jq 1.6+; try jq --version'
}

# Prints the get lines, or refuses a missing or broken file.
run_get() {
	settings_file=$(sh "${EVENTS_SCRIPT}" latest --effort "${effort}" --type "${EVENT_TYPE}" </dev/null) ||
		die 4 'events.sh latest failed (its stderr is above)'
	[ -n "${settings_file}" ] ||
		die "${EXIT_NO_SETUP}" "no git setup for this effort: no ${EVENT_TYPE} event; expected ${PROG} write to have saved it"
	shown_settings=$(printable "${settings_file}")
	slurped=$(jq -c '[.body]' "${settings_file}" 2>/dev/null) ||
		die 3 "${shown_settings} is not valid JSON; expected the event ${PROG} write appends; try the git setup gate again"
	lines=$(printf '%s\n' "${slurped}" | jq -r -L "${own_dir}" --arg at "${shown_settings}" "${GET_JQ}") ||
		die 4 "jq failed; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version"
	case ${lines} in
		'PROBLEM '*)
			while IFS= read -r problem; do
				warn "${problem#PROBLEM }"
			done <<EOF
${lines}
EOF
			exit 3
			;;
		*) printf '%s\n' "${lines}" ;;
	esac
}

# Removes write's temp files and folder, when any are left.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
	[ -z "${temp_dir}" ] || rm -rf "${temp_dir}"
}

temp_file='' temp_dir='' fingerprint='' picked='' repo_has_origin='' shown_repo='' remote=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp file goes on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
load_dependencies
check_effort
if [ "${command}" = write ]; then
	run_write
else
	run_get
fi
