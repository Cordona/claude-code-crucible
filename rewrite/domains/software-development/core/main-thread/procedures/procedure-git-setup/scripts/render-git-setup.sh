#!/usr/bin/env sh
# Renders the git setup gate, asked once per effort before its first plan,
# so the main thread never hand-formats it: the card, or with --question its
# AskUserQuestion input, two questions (Identity and Auto-push) answered in
# tabs. The identities are the plan identity-candidates.sh --plan-out wrote;
# the repo, when there is one, says whether auto-push can be offered.
# Pipe the card into procedure-approval-gate's open-gate.sh.
# shellcheck source-path=SCRIPTDIR
set -eu

readonly PROG='render-git-setup.sh'
readonly MODULE='settings'
readonly RENDER_LIB='human-view'
# The C locale keeps the shell byte-wise; jq reads the plan as UTF-8.
LC_ALL=C
export LC_ALL
GIT_TERMINAL_PROMPT=0
export GIT_TERMINAL_PROMPT
# An inherited repository override would make git act outside --repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
	GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX

# Prints one line per problem of the slurped plan; nothing when it is one
# object, {"identities": [...]}, of at most settings_max_identities
# candidates settings.jq accepts, their option labels unique.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly PLAN_CHECK_JQ='include "settings";
def expected_plan: "expected one JSON object {\"identities\": [...]} of at most \(settings_max_identities), as identity-candidates.sh --plan-out writes it";
def names($at): {identity: $at, name: "\($at).name", email: "\($at).email", signing: "\($at).signing",
	format: "\($at).signing.format", key: "\($at).signing.key"};
if length != 1 then "the plan file holds \(length) JSON values; \(expected_plan)"
elif (.[0] | type) != "object" then "the plan file holds a JSON \(.[0] | type); \(expected_plan)"
elif (.[0] | keys) != ["identities"] then "the plan holds the keys \(.[0] | keys | tojson); \(expected_plan)"
elif (.[0].identities | type) != "array" then "the plan'\''s identities are a JSON \(.[0].identities | type); \(expected_plan)"
elif (.[0].identities | length) > settings_max_identities then "the plan holds \(.[0].identities | length) identities; \(expected_plan)"
else .[0].identities
	| [to_entries[] | "identities[\(.key)]" as $at | .value | settings_candidate_problems(names($at))] as $problems
	| if ($problems | length) > 0 then $problems[]
	  else group_by(settings_identity_text)[] | select(length > 1)
		| "\(length) identities share the option label \(.[0] | settings_identity_text | tojson); expected each label once"
	  end
end'

# The card: its title and one line, plus a line when auto-push can't be offered.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly VIEW_JQ='include "view";
[status_line("decision"; "Decision needed · git setup for this effort'\''s agents"),
 (if (.[0].identities | length) > 0 then "Pick the identity that signs this effort'\''s agents'\'' commits."
  else "This machine has no GPG or SSH signing key." end),
 (if $has_origin == "yes" then ""
  elif $has_origin == "no" then "This repo has no origin remote, so auto-push stays off."
  else "No repository here, so auto-push stays off." end)]
| blocks'

# The AskUserQuestion input: Identity, one option per identity and a way to
# stop, or with none the two ways on; then Auto-push, left out when there is
# no repo or it has no origin.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly QUESTION_JQ='include "settings";
def option($label; $description): {label: $label, description: $description};
.[0].identities as $identities
| (if ($identities | length) == 0 then
	{header: "Identity", question: "How should this effort'\''s commits be authored?", multiSelect: false,
	 options: [option("Set up git first (Recommended)"; "Nothing is dispatched until you add a signing key and ask me to go on"),
		option("Type name and email"; "Commits are authored with it, unsigned")]}
   else
	{header: "Identity", question: "Which identity signs this effort'\''s commits?", multiSelect: false,
	 options: ($identities | map(option(settings_identity_text; "")))
		+ [option("No, set up git first"; "Nothing is dispatched until you set up the identity you want and ask me to go on")]}
   end) as $identity
| ("After each commit, everything on its worktree'\''s branch is pushed to `origin`"
	+ (if ($identities | length) == 0 then "; a remote that requires signed commits will refuse these pushes" else "" end)) as $yes
| {questions: [$identity]
	+ (if $has_origin == "yes" then
		[{header: "Auto-push", question: "Push each worker commit to the remote?", multiSelect: false,
		  options: [option("No (Recommended)"; "Commits stay local until you ask for a push"), option("Yes"; $yes)]}]
	   else [] end)}'

usage() {
	cat <<EOF
usage: sh ${PROG} --plan-file PATH [--repo DIR] | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label git-setup --effort FOLDER
       sh ${PROG} --plan-file PATH [--repo DIR] --question
       sh ${PROG} --help | -h

Prints the git setup gate as Markdown, or with --question its AskUserQuestion
input. stdin is never read, the plan file only read; no file is written.

--plan-file PATH  the plan identity-candidates.sh --plan-out wrote: one JSON
                  object {"identities": [...]}, at most ${MODULE}.jq's
                  settings_max_identities, each with a signing key, as
                  ${MODULE}.jq accepts them, their option labels unique
--repo DIR        the repository the session runs in: whether it has an
                  origin remote decides if Auto-push is asked; left out
                  when the session runs in no repository: no Auto-push
--question        print the gate's question instead of the gate
CLAUDE_CONFIG_DIR  holds the skills, in its skills/; default \$HOME/.claude

stdout on exit 0 only:
  a gate: its Markdown, with no gate marker
  --question: one line of JSON, {"questions": [...]}, for one AskUserQuestion
    as it is. Identity: one option per identity, labelled
    "<name> · <email> · GPG key <key>" or "<name> · <email> · SSH key
    <fingerprint>", in plan order, then "No, set up git first"; with none,
    "Set up git first (Recommended)" and "Type name and email". Auto-push,
    only with a repo that has an origin remote: "No (Recommended)" and "Yes"
stderr on exit 5: "${PROG}: install:", a prefix no other exit prints

exit codes:
  0  printed; pipe a gate into open-gate.sh, pass a question to one
     AskUserQuestion
  2  wrong command line; fix the call
  3  refused: the plan file or --repo; one stderr line per problem; fix
     what it names and rerun once, else show the human stderr
  4  stdout closed before the output was written; show the human the exit
     code, and stop
  5  an install fault; show the human stderr, and stop

needs: POSIX sh, jq 1.6+; git, with --repo; to print a gate, the ${RENDER_LIB}
skill's view.jq in the skills; ${MODULE}.jq and origin-lib.sh beside this
script
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
	plan_file='' repo='' want_question=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			-h | --help)
				usage
				exit 0
				;;
			--question)
				want_question=true
				shift
				;;
			--plan-file | --repo)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 VALUE"
				if [ "$1" = --plan-file ]; then
					[ -z "${plan_file}" ] || usage_error '--plan-file given twice; expected one'
					plan_file=$2
				else
					[ -z "${repo}" ] || usage_error '--repo given twice; expected one'
					repo=$2
				fi
				shift 2
				;;
			*)
				shown_option=$(printable "$1")
				usage_error "unknown option: ${shown_option}; expected --plan-file PATH, --repo DIR, --question or --help"
				;;
		esac
	done
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected the file identity-candidates.sh --plan-out wrote'
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
	[ -z "${repo}" ] || command -v git >/dev/null 2>&1 ||
		install_fault 'git missing; expected git on PATH; try installing it (macOS: xcode-select --install; Linux: the distro'\''s git package)'
	own_dir=$(script_dir)
	for neighbour in "${MODULE}.jq" origin-lib.sh; do
		[ -f "${own_dir}/${neighbour}" ] && [ -r "${own_dir}/${neighbour}" ] ||
			install_fault "${neighbour} missing; expected it beside ${PROG}; reinstall the procedure-git-setup skill"
	done
	# shellcheck source=origin-lib.sh
	. "${own_dir}/origin-lib.sh"
	render_lib_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills/${RENDER_LIB}"
	[ "${want_question}" = false ] || return 0
	[ -f "${render_lib_dir}/view.jq" ] && [ -r "${render_lib_dir}/view.jq" ] ||
		install_fault "layout module missing; expected ${render_lib_dir}/view.jq; install the ${RENDER_LIB} skill"
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

# Sets slurped to the plan file read into one array, so an empty file and
# several values are caught as one problem, then checks its shape.
load_plan() {
	shown_plan=$(printable "${plan_file}")
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		refuse_problems "plan file not readable: ${shown_plan}; expected a readable JSON file"
	slurped=$(jq -sc '.' "${plan_file}" </dev/null 2>/dev/null) ||
		refuse_problems "the plan file is not valid JSON: ${shown_plan}; expected the plan identity-candidates.sh --plan-out wrote; try running it again"
	plan_problems=$(run_jq "${PLAN_CHECK_JQ}")
	refuse_problems "${plan_problems}"
}

# Runs jq program $1 over the slurped plan; a jq failure exits 5.
run_jq() {
	printf '%s' "${slurped}" | jq -r -c -L "${own_dir}" -L "${render_lib_dir}" \
		--arg has_origin "${repo_has_origin}" "$1" ||
		install_fault "jq failed on valid JSON; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version, then rerun"
}

# yes or no for a repo's origin remote, none with no repo.
repo_has_origin=none
parse_args "$@"
load_dependencies
if [ -n "${repo}" ]; then
	remote=$(jq -nr -L "${own_dir}" 'include "settings"; settings_remote') ||
		install_fault "jq failed reading the remote; expected jq 1.6+ and ${MODULE}.jq beside ${PROG}; try jq --version, then rerun"
	check_repo_origin "${repo}" "${remote}"
fi
load_plan
if [ "${want_question}" = true ]; then
	output=$(run_jq "${QUESTION_JQ}")
else
	output=$(run_jq "${VIEW_JQ}")
fi
# Ignoring SIGPIPE turns a closed reader into a failed write this script can
# tell apart from a jq fault, rather than a silent kill.
trap '' PIPE
printf '%s\n' "${output}" 2>/dev/null || exit 4
