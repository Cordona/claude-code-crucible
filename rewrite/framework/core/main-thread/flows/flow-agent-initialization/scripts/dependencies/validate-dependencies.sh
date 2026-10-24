#!/usr/bin/env sh
# Runs the install check for flow-agent-initialization: its five other
# scripts, procedure-context's context.sh, procedure-effort's effort.sh, the
# crucible skill's space rules, the four context checks the
# scripts share and the context-handling template the inject hook sends, the
# dispatch plan check and its plugin list reader, the dispatch check, the
# plugin file helper and the dispatch names module,
# human-view's path helpers, which the developer report renderer loads, and its
# view module, which every view of the flow loads, procedure-approval-gate's
# open-gate.sh and its two hook scripts, crucible.sh, jq, the run-time tools
# date, git, cmp, awk, sort, mktemp, mv, rm, wc and sha256sum or shasum, the three hook
# entries in settings.json (the inject hook, which must block on failure, and
# both gate hooks), the Crucible
# space in its additionalDirectories, and the installed plugins. Every check
# runs, whatever an earlier one found, so one run names every fix; the lines
# are kept and printed at the end, as a pass line, a view or the full
# checklist. It reads
# settings.json only through jq, and only those hook commands and
# permissions.additionalDirectories, which it counts or hashes and never
# prints: the file may hold secrets in its env block.
# A full pass is cached: the marker keeps a fingerprint of everything the checks
# depend on, and while that fingerprint is unchanged the checks are skipped.
# The marker is the only file it leaves (its temp file is removed on exit);
# it holds no settings content.
# Exit 3 means only the inject hook check failed: dispatch can't inject
# plugins, but direct implementation can go on. jq and the gate hooks are
# exit 1 failures, since the approval gate every plan goes through needs them.
set -eu

readonly PROG='validate-dependencies.sh'
readonly PROCEDURE='flow-agent-initialization'
readonly GATE_PROCEDURE='procedure-approval-gate'
readonly CONTEXT_PROCEDURE='procedure-context'
readonly EFFORT_PROCEDURE='procedure-effort'
readonly EFFORT_SCRIPT='effort.sh'
readonly SELF_SCRIPT='dependencies/validate-dependencies.sh'
readonly LIST_SCRIPT='dispatch-plan/list-plugins.sh'
readonly PLAN_RENDER_SCRIPT='dispatch-plan/render-dispatch-plan.sh'
readonly INJECT_SCRIPT='agent-prompt/prepare-agent-prompt.sh'
readonly HOOK_SCRIPT="${PROCEDURE}/scripts/${INJECT_SCRIPT}"
readonly CONTEXT_SCRIPT='context.sh'
readonly PLAN_GENERATOR_SCRIPT='dispatch-plan/generate-dispatch-plan.sh'
readonly PLAN_VALIDATOR_LIB='dispatch-plan/dispatch-plan-validator.jq'
readonly INSTALLED_PLUGINS_LIB='dispatch-plan/installed-plugins.jq'
readonly DISPATCH_GENERATOR_SCRIPT='agent-dispatch/generate-agent-dispatch.sh'
readonly DISPATCH_VALIDATOR_LIB='agent-dispatch/agent-dispatch-validator.jq'
readonly PLUGIN_FILES_LIB='agent-dispatch/plugin-files.sh'
readonly DISPATCH_NAMES_LIB='agent-dispatch/dispatch-names.jq'
# These four are in DIR/procedure-context/scripts/.
readonly CONTEXT_VALIDATOR_LIB='agent-context-validator.jq'
readonly CONTEXT_URL_LIB='agent-context-url.jq'
readonly CONTEXT_FILE_LIB='agent-context-file-checks.sh'
readonly CONTEXT_VERSIONS_LIB='context-versions.sh'
# Relative to DIR/procedure-context/, not to its scripts/.
readonly TEMPLATE_FILE='references/agent-context-rules.md'
# More symlink hops than any install chain needs; a longer chain is a loop.
readonly MAX_LINK_HOPS=40
readonly RENDER_LIB='human-view'
readonly PATHS_MODULE="${RENDER_LIB}/paths.jq"
readonly VIEW_NAME='view'
readonly VIEW_MODULE="${RENDER_LIB}/${VIEW_NAME}.jq"
readonly GATE_STOP_SCRIPT="${GATE_PROCEDURE}/scripts/gate-stop-hook.sh"
readonly GATE_QUESTION_SCRIPT="${GATE_PROCEDURE}/scripts/gate-question-hook.sh"
readonly CRUCIBLE_SKILL='crucible'
readonly CRUCIBLE_SCRIPT='crucible.sh'
# Relative to DIR/crucible/scripts/.
readonly CRUCIBLE_SPACE_LIB='lib/crucible-space.sh'
# The inject hook reads every plugin file of the dispatch, so its bound is
# generous; with "onFailure": "block" a timeout blocks the dispatch.
readonly HOOK_TIMEOUT=30
# The inject hook's entry must block the dispatch when the hook fails or times
# out; Claude Code otherwise lets the call through with its prompt untouched.
readonly HOOK_ON_FAILURE='block'

# The gate hooks read one small state file, and a timed-out one lets the stop
# or question through, so a stuck one is cut short.
readonly GATE_HOOK_TIMEOUT=10
# Printed unexpanded so the fix can be pasted into settings.json as is.
# shellcheck disable=SC2016
readonly HOOK_COMMAND_ROOT='${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills'
readonly JQ_FIX='install jq 1.6+ (macOS: brew install jq; Linux: the distro'\''s jq package), then rerun'
readonly MARKER_NAME='install-check'
# Base tools whose absence would make a check report the wrong thing (a missing
# grep reads as an empty template), so a run stops before any check without one.
readonly BASE_TOOLS='cat grep readlink tr'
# Tools the flow's scripts need when they run, beyond BASE_TOOLS, that no
# checked --help tests: list-plugins.sh (awk, sort) and context.sh (mktemp,
# mv, rm, wc) print theirs before their tool check. sha256sum or shasum is
# checked apart, since either one will do.
readonly RUN_TOOLS='date git cmp awk sort mktemp mv rm wc'
# prepare-agent-prompt.sh needs jq 1.6 for --rawfile (see its --help).
readonly JQ_MIN_MAJOR=1
readonly JQ_MIN_MINOR=6
# Emits each hook command under event $event (and matcher $matcher; "" accepts
# any) that runs $needle; every step tolerates a missing or mistyped level, so
# only a JSON parse error fails it.
# The program is single-quoted on purpose: its $ names are jq's.
# shellcheck disable=SC2016
readonly HOOK_COMMANDS_JQ='.hooks?[$event]?[]?
	| select(type == "object" and ($matcher == "" or .matcher == $matcher))
	| .hooks?[]?
	| select(type == "object")
	| .command?
	| select(type == "string" and contains($needle))'
readonly HOOK_COUNT_JQ="[${HOOK_COMMANDS_JQ}] | length"
# Counts the hook entries under event $event and matcher $matcher that run
# $needle with "onFailure" set to $on_failure.
# shellcheck disable=SC2016
readonly HOOK_ON_FAILURE_COUNT_JQ='[.hooks?[$event]?[]?
	| select(type == "object" and ($matcher == "" or .matcher == $matcher))
	| .hooks?[]?
	| select(type == "object" and (.command? | type == "string" and contains($needle)) and .onFailure? == $on_failure)]
	| length'
# Emits each matching hook entry's command and onFailure, for the fingerprint.
# shellcheck disable=SC2016
readonly HOOK_FINGERPRINT_JQ='.hooks?[$event]?[]?
	| select(type == "object" and ($matcher == "" or .matcher == $matcher))
	| .hooks?[]?
	| select(type == "object" and (.command? | type == "string" and contains($needle)))
	| [.command, .onFailure?]'

# Emits each non-empty permissions.additionalDirectories entry, trailing
# slashes dropped (so "/" becomes ""); a missing or mistyped level emits nothing.
readonly ALLOWED_DIRS_JQ='.permissions?.additionalDirectories?[]? | strings | select(length > 0) | sub("/+$"; "")'
# Counts the entries that equal $dir or are a parent of it, whole path
# components only: an entry /a/b allows /a/b and /a/b/c, never /a/bc. Claude
# Code grants an entry and everything under it.
# Paths are compared as written: no symlink, ~, . or .. is resolved.
# shellcheck disable=SC2016 # $dir is jq's
readonly SPACE_COUNT_JQ="(\$dir | sub(\"/+\$\"; \"\")) as \$space | [${ALLOWED_DIRS_JQ} | select(. as \$entry | \$space == \$entry or (\$space | startswith(\$entry + \"/\")))] | length"
# shellcheck disable=SC2016 # $dir is jq's
readonly SPACE_FRAGMENT_JQ='{permissions: {additionalDirectories: [$dir]}}'
# The C locale keeps pattern matching and sort byte-wise; the UTF-8 marks are
# printed as bytes.
LC_ALL=C
export LC_ALL
NL='
'
readonly NL
# Separates the view items handed to jq; no check text holds it.
ITEM_SEPARATOR=$(printf '\036')
readonly ITEM_SEPARATOR
# Builds the view of a full run from $fixes and $warnings, items separated
# by U+001E, and the counts $failed and $total.
# shellcheck disable=SC2016 # the $ names are jq's
readonly RESULT_VIEW_JQ='
def items: split("\u001e") | map(select(length > 0) | gsub("[\u0000-\u001f\u007f]"; "?") | (.[:1] | ascii_upcase) + .[1:]);
($fixes | items) as $fix_items
| ($warnings | items) as $warning_items
| if ($failed | tonumber) > 0 then
	[status_line("blocked"; "Blocked · install check: \($failed) of \($total) checks failed"),
		section("Fix"; $fix_items)]
  elif ($warning_items | length) > 0 then
	[status_line("attention"; "Install check passed with \($warning_items | length) warning" + (if ($warning_items | length) == 1 then "" else "s" end)),
		section("Warning"; "Warnings"; $warning_items)]
  else [status_line("done"; "Install check passed"; "\($total) checks")]
  end
| blocks'
# Builds the pass line of a cached run from its pass time $since.
# shellcheck disable=SC2016 # the $ names are jq's
readonly CACHED_VIEW_JQ='status_line("done"; "Install check passed"; "unchanged since \($since)")'

usage() {
	cat <<EOF
usage: sh ${PROG} [--skills-dir DIR] [--settings FILE]
                                   [--cache-dir CACHE] [--force] [--verbose]
       sh ${PROG} --help | -h

Checks the skills, tools, settings.json entries and plugins
  ${PROCEDURE} needs; every check runs, so one run names every fix.

Options:
  --skills-dir DIR   the skills folder; default
                     \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills
  --settings FILE    the settings file; default
                     \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/settings.json
  --cache-dir CACHE  the cache folder; default
                     \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/agent-init
  --force            runs every check even when the cached pass holds
  --verbose          prints the full checklist: a header line, one line per
                     check (✓, ✗ <item>: <reason>. Fix: <action>, or
                     ⚠ <item>: <reason>), then a summary line

stdout, to relay as printed; its last line is "(result not cached: <reason>)"
  when a pass can't be cached (never a failure):
  🟢 **Install check passed** · <n> checks
                     a pass with no ⚠
  🟢 **Install check passed** · unchanged since <YYYY-MM-DD HH:MM>
                     a cached pass
  a view             any ✗: blocked, one Fix item per ✗ or ⚠ line, a hook
                     or space fix naming the exact settings.json entry to
                     add; only ⚠: passed, one Warnings item per ⚠ line
  without jq or ${VIEW_MODULE}: the --verbose output instead, a pass
                     without its header and check lines

Cache: leaves only CACHE/${MARKER_NAME}, replaced atomically, after a pass with
  no ⚠, and reuses it until anything the checks read changes; a ✗ or ⚠
  removes it. settings.json is never touched.
Reads only settings.json's hook entries and
  permissions.additionalDirectories; never prints a settings value.

Exit codes:
  0  every check passed (a ⚠ included), or the cached pass holds; go on
  1  a check failed, not only the inject hook; stop: each Fix item names its fix
  2  usage error; reinstall ${PROCEDURE} and stop
  3  only the inject hook check failed; dispatch nothing, direct
     implementation can go on
  129, 130, 143  stopped by HUP, INT or TERM; show it and stop

Dependencies:
  POSIX sh; cat, grep, readlink, tr (every macOS and Linux base system)
  cksum, date, find, mkdir, mktemp, mv, rm, sort for the cache (a missing one
    leaves the result not cached)
  jq ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR}+, date, git, cmp, awk, sort, mktemp, mv, rm, wc, sha256sum or
    shasum: checked, not required; each has its own check line
EOF
}

usage_error() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Sets skills_dir, settings_file, cache_dir and force from the arguments.
parse_args() {
	config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
	skills_dir="${config_dir}/skills"
	settings_file="${config_dir}/settings.json"
	cache_dir="${config_dir}/cache/agent-init"
	force=0
	verbose=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--force)
				force=1
				shift
				;;
			--verbose)
				verbose=1
				shift
				;;
			--skills-dir | --settings | --cache-dir)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 PATH"
				case $1 in
					--settings) settings_file=$2 ;;
					--cache-dir) cache_dir=$2 ;;
					*) skills_dir=$2 ;;
				esac
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected --skills-dir, --settings, --cache-dir, --force, --verbose or --help" ;;
		esac
	done
	procedure_dir="${skills_dir}/${PROCEDURE}"
	scripts_dir="${procedure_dir}/scripts"
	context_procedure_dir="${skills_dir}/${CONTEXT_PROCEDURE}"
	context_scripts_dir="${context_procedure_dir}/scripts"
	crucible_scripts_dir="${skills_dir}/${CRUCIBLE_SKILL}/scripts"
	gate_scripts_dir="${skills_dir}/${GATE_PROCEDURE}/scripts"
	marker="${cache_dir}/${MARKER_NAME}"
}

# Sets fingerprint to one cksum line over everything the checks depend on, or
# leaves it empty and sets cache_note when that can't be computed.
compute_fingerprint() {
	fingerprint=''
	if ! command -v cksum >/dev/null 2>&1; then
		cache_note='cksum not found on PATH'
		return 0
	fi
	if ! command -v find >/dev/null 2>&1; then
		cache_note='find not found on PATH'
		return 0
	fi
	# shellcheck disable=SC2310 # every step in it has its own fallback line
	if fingerprint=$(fingerprint_input | cksum); then
		:
	else
		fingerprint=''
		cache_note='cksum failed'
	fi
}

# Prints what the fingerprint covers. Each step prints a fixed line when it
# fails, so a missing file or tool changes the fingerprint instead of stopping.
# The hook commands go only into the cksum pipe.
fingerprint_input() {
	printf 'paths\n%s\n%s\n' "${skills_dir}" "${settings_file}"
	printf 'scripts\n'
	cksum "${scripts_dir}/${LIST_SCRIPT}" \
		"${scripts_dir}/${INJECT_SCRIPT}" "${scripts_dir}/${SELF_SCRIPT}" \
		"${scripts_dir}/${PLAN_RENDER_SCRIPT}" \
		"${scripts_dir}/${PLAN_GENERATOR_SCRIPT}" "${scripts_dir}/${PLAN_VALIDATOR_LIB}" \
		"${scripts_dir}/${INSTALLED_PLUGINS_LIB}" "${scripts_dir}/${DISPATCH_GENERATOR_SCRIPT}" \
		"${scripts_dir}/${DISPATCH_VALIDATOR_LIB}" "${scripts_dir}/${PLUGIN_FILES_LIB}" \
		"${scripts_dir}/${DISPATCH_NAMES_LIB}" \
		"${context_scripts_dir}/${CONTEXT_SCRIPT}" \
		"${context_scripts_dir}/${CONTEXT_VALIDATOR_LIB}" "${context_scripts_dir}/${CONTEXT_URL_LIB}" \
		"${context_scripts_dir}/${CONTEXT_FILE_LIB}" \
		"${context_scripts_dir}/${CONTEXT_VERSIONS_LIB}" "${context_procedure_dir}/${TEMPLATE_FILE}" \
		"${skills_dir}/${PATHS_MODULE}" "${skills_dir}/${VIEW_MODULE}" \
		"${gate_scripts_dir}/open-gate.sh" \
		"${gate_scripts_dir}/gate-stop-hook.sh" "${gate_scripts_dir}/gate-question-hook.sh" \
		"${skills_dir}/${EFFORT_PROCEDURE}/scripts/${EFFORT_SCRIPT}" \
		"${crucible_scripts_dir}/${CRUCIBLE_SCRIPT}" "${crucible_scripts_dir}/${CRUCIBLE_SPACE_LIB}" 2>/dev/null ||
		printf 'scripts unreadable\n'
	fingerprint_hook PreToolUse Agent "${HOOK_SCRIPT}"
	fingerprint_hook Stop '' "${GATE_STOP_SCRIPT}"
	fingerprint_hook PreToolUse AskUserQuestion "${GATE_QUESTION_SCRIPT}"
	printf 'crucible space\n%s\n' "${crucible_home}"
	jq -c "${ALLOWED_DIRS_JQ}" "${settings_file}" </dev/null 2>/dev/null ||
		printf 'additional directories unreadable\n'
	printf 'jq\n'
	jq --version </dev/null 2>/dev/null || printf 'jq unavailable\n'
	printf 'tools\n'
	for tool in ${RUN_TOOLS} sha256sum shasum; do
		command -v "${tool}" 2>/dev/null || printf '%s missing\n' "${tool}"
	done
	printf 'plugins\n'
	fingerprint_plugins
}

# Prints the hook commands and their onFailure for event $1, matcher $2 (""
# any) and script $3, or a fixed line when they can't be read.
fingerprint_hook() {
	printf 'hook %s %s %s\n' "$1" "$2" "$3"
	jq -c --arg event "$1" --arg matcher "$2" --arg needle "$3" "${HOOK_FINGERPRINT_JQ}" "${settings_file}" </dev/null 2>/dev/null ||
		printf 'hook commands unreadable\n'
}

# Prints each tech-*/standard-*/procedure-* folder name, then one cksum line per
# file in their SKILL.md and references/, sorted. Symlinks are followed: an
# installed plugin is usually a link to its source folder.
fingerprint_plugins() {
	set --
	for plugin_path in "${skills_dir}"/tech-* "${skills_dir}"/standard-* "${skills_dir}"/procedure-*; do
		[ -d "${plugin_path}" ] || continue
		printf 'plugin %s\n' "${plugin_path##*/}"
		for part in SKILL.md references; do
			if [ -e "${plugin_path}/${part}" ]; then set -- "$@" "${plugin_path}/${part}"; fi
		done
	done
	[ "$#" -gt 0 ] || return 0
	find -L "$@" -type f -exec cksum {} + 2>/dev/null | sort || printf 'plugin files unreadable\n'
}

# True when the marker holds a pass for the current fingerprint; sets
# cached_time and cached_checks from it.
cached_pass_holds() {
	[ -n "${fingerprint}" ] && [ -f "${marker}" ] || return 1
	marker_text=$(cat "${marker}" 2>/dev/null) || return 1
	marker_fingerprint=''
	cached_time=''
	cached_checks=''
	while IFS= read -r line; do
		case ${line} in
			'fingerprint '*) marker_fingerprint=${line#fingerprint } ;;
			'passed '*) cached_time=${line#passed } ;;
			'checks '*) cached_checks=${line#checks } ;;
			*) ;;
		esac
	done <<EOF
${marker_text}
EOF
	[ "${marker_fingerprint}" = "${fingerprint}" ] || return 1
	case ${cached_time} in
		[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' '[0-9][0-9]:[0-9][0-9]) ;;
		*) return 1 ;;
	esac
	case ${cached_checks} in
		'' | *[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Adds line $1 to the full checklist.
add_line() {
	checklist="${checklist}$1${NL}"
}

pass() {
	add_line "✓ $1"
	passed_count=$((passed_count + 1))
}

# Records a failed line for item $1, reason $2 and fix $3 as a Fix item, and counts it.
fail() {
	add_line "✗ $1: $2. Fix: $3"
	add_fix_item "$1: $2. Fix: $3"
	failed_count=$((failed_count + 1))
}

add_fix_item() {
	fix_items="${fix_items}${ITEM_SEPARATOR}$1"
}

# Fails a hook entry check for script $1 like fail with $2..$4, and counts a
# failed inject hook check, the one failure that blocks only dispatch.
# shellcheck disable=SC2329 # called from check_hook_entry, which each_hook calls by name
fail_hook() {
	hook_script=$1
	shift
	fail "$@"
	[ "${hook_script}" != "${HOOK_SCRIPT}" ] || inject_failed_count=$((inject_failed_count + 1))
}

# Records a warning line for item $1 and reason $2 as a Fix and a Warnings item, and counts it.
warn() {
	add_line "⚠ $1: $2"
	add_fix_item "$1: $2"
	warning_items="${warning_items}${ITEM_SEPARATOR}$1: $2"
	warning_count=$((warning_count + 1))
}

# Checks that script $2 of skill $1 is installed and answers --help with a
# line starting "Usage:" or "usage:".
check_script() {
	# shellcheck disable=SC2310 # it reports its own failure; its status only says whether to go on
	read_help "$1" "$2" || return 0
	case ${NL}${help_text} in
		*"${NL}Usage:"* | *"${NL}usage:"*) pass "$2" ;;
		*) fail "$2" "--help printed no Usage: line" "${reinstall}" ;;
	esac
}

# Checks that script $2 of skill $1 is installed and its --help exits 0.
check_runnable() {
	# shellcheck disable=SC2310 # it reports its own failure; its status only says whether to go on
	read_help "$1" "$2" || return 0
	pass "$2"
}

# Sets help_text to the --help output of script $2 of skill $1, and reinstall
# to the fix for it; fails the check for $2 and returns 1 when the script is
# missing or its --help exits non-zero.
read_help() {
	script_dir="${skills_dir}/$1/scripts"
	script="${script_dir}/$2"
	reinstall="reinstall $1 under ${skills_dir}"
	if [ ! -f "${script}" ] || [ ! -r "${script}" ]; then
		fail "$2" "missing from ${script_dir}" "${reinstall}"
		return 1
	fi
	# stderr is kept with stdout: a --help that fails on a tool missing from
	# PATH names it there, and that cause, not a reinstall, is the fix.
	if help_text=$(sh "${script}" --help </dev/null 2>&1); then
		return 0
	else
		help_status=$?
	fi
	help_cause=$(printf '%s' "${help_text%%"${NL}"*}" | tr -d '\001-\037\177')
	if [ -n "${help_cause}" ]; then
		fail "$2" "--help exited ${help_status}, expected 0: ${help_cause}" "fix what it names (a tool missing from PATH: install it), or ${reinstall}"
	else
		fail "$2" "--help exited ${help_status}, expected 0" "${reinstall}"
	fi
	return 1
}

# Checks that file $1 in folder $2, which the scripts load, is readable; $3
# is the skill to reinstall when it isn't.
check_lib_file() {
	lib_file="$2/$1"
	if [ -f "${lib_file}" ] && [ -r "${lib_file}" ]; then
		pass "$1"
	else
		fail "$1" "missing or unreadable in $2" "reinstall $3 under ${skills_dir}"
	fi
}

# Checks the template the inject hook sends word for word, by the hook's own
# test: a readable regular file inside the procedure-context folder after
# symlinks, holding more than whitespace. Both the hook and --direct refuse
# without it.
check_template() {
	template="${context_procedure_dir}/${TEMPLATE_FILE}"
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	if is_template_usable; then
		pass "${TEMPLATE_FILE}"
	else
		fail "${TEMPLATE_FILE}" "missing or empty in ${template%/*}" "reinstall ${CONTEXT_PROCEDURE} under ${skills_dir}"
	fi
}

# True when template is a readable regular file, resolves inside
# context_procedure_dir and holds a character other than whitespace.
is_template_usable() {
	[ -f "${template}" ] && [ -r "${template}" ] || return 1
	# shellcheck disable=SC2310 # a pure test; its status is the answer
	is_inside_context_procedure "${template}" || return 1
	grep -q '[^[:space:]]' "${template}" 2>/dev/null
}

# True when file $1, its symlinks followed, lies under context_procedure_dir's
# physical path, so a link can't make the hook send a file from elsewhere.
is_inside_context_procedure() {
	procedure_real=$(cd -P "${context_procedure_dir}" 2>/dev/null && pwd -P) || return 1
	link_path=$1
	link_hops=0
	while [ -h "${link_path}" ]; do
		link_hops=$((link_hops + 1))
		[ "${link_hops}" -le "${MAX_LINK_HOPS}" ] || return 1
		link_target=$(readlink "${link_path}" 2>/dev/null) || return 1
		case ${link_target} in
			/*) link_path=${link_target} ;;
			*) link_path="${link_path%/*}/${link_target}" ;;
		esac
	done
	link_dir=$(cd -P "${link_path%/*}" 2>/dev/null && pwd -P) || return 1
	case ${link_dir}/ in
		"${procedure_real}"/*) return 0 ;;
		*) return 1 ;;
	esac
}

# Checks that jq is on PATH and at least JQ_MIN_MAJOR.JQ_MIN_MINOR.
check_jq() {
	if ! command -v jq >/dev/null 2>&1; then
		fail jq 'not found on PATH' "${JQ_FIX}"
		return 0
	fi
	jq_version=$(jq --version </dev/null 2>/dev/null) || jq_version=''
	jq_version=${jq_version#jq-}
	jq_version=${jq_version#jq version }
	jq_major=${jq_version%%.*}
	jq_minor=${jq_version#*.}
	jq_minor=${jq_minor%%[!0-9]*}
	# shellcheck disable=SC2310 # a pure case test; its status is the answer
	if ! is_version_readable; then
		fail jq 'version not readable from jq --version' "${JQ_FIX}"
		return 0
	fi
	if [ "${jq_major}" -gt "${JQ_MIN_MAJOR}" ] ||
		{ [ "${jq_major}" -eq "${JQ_MIN_MAJOR}" ] && [ "${jq_minor}" -ge "${JQ_MIN_MINOR}" ]; }; then
		pass "jq ${jq_version}"
	else
		fail "jq ${jq_version}" "older than ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR}" "${JQ_FIX}"
	fi
}

# True when jq_version holds only version characters and jq_major and jq_minor
# are both non-empty digit strings, so the numeric tests below can't error.
is_version_readable() {
	case ${jq_version} in
		'' | *[!0-9A-Za-z.+_-]*) return 1 ;;
		*.*) ;;
		*) return 1 ;;
	esac
	case ${jq_major}:${jq_minor} in
		:* | *: | *[!0-9:]*) return 1 ;;
		*) return 0 ;;
	esac
}

# Checks the tools the flow's scripts need at run time, which their --help
# doesn't test, so a pass here can't be followed by a stop on a missing one.
check_run_tools() {
	for tool in ${RUN_TOOLS}; do
		if command -v "${tool}" >/dev/null 2>&1; then
			pass "${tool}"
			continue
		fi
		set_run_tool_hint "${tool}"
		fail "${tool}" "not found on PATH; expected it for ${run_tool_need}" "${run_tool_fix}"
	done
	if command -v sha256sum >/dev/null 2>&1; then
		pass sha256sum
	elif command -v shasum >/dev/null 2>&1; then
		pass shasum
	else
		fail 'sha256sum or shasum' 'neither is on PATH; expected one for the context, plan and dispatch generators, render-dispatch-plan.sh and the inject hook' \
			'install coreutils (Linux), or put the system shasum back on PATH (macOS: it ships in /usr/bin), then rerun'
	fi
}

# Sets run_tool_need to the scripts that need run-time tool $1, and
# run_tool_fix to how to get it back.
set_run_tool_hint() {
	case $1 in
		date)
			run_tool_need='open-gate.sh, both gate hooks, the inject hook, generate-agent-dispatch.sh and crucible.sh'
			set_coreutils_fix date /bin
			;;
		git)
			run_tool_need='generate-agent-dispatch.sh and the inject hook'\''s baseline'
			run_tool_fix='install git (macOS: xcode-select --install; Linux: the distro'\''s git package), then rerun'
			;;
		cmp)
			run_tool_need='open-gate.sh'
			run_tool_fix='put cmp back on PATH (macOS: it ships in /usr/bin; Linux: the distro'\''s diffutils package), then rerun'
			;;
		awk)
			run_tool_need='list-plugins.sh'
			run_tool_fix='put awk back on PATH (macOS: it ships in /usr/bin; Linux: the distro'\''s gawk or mawk package), then rerun'
			;;
		sort)
			run_tool_need='list-plugins.sh'
			set_coreutils_fix sort /usr/bin
			;;
		mktemp | wc)
			run_tool_need='context.sh'
			set_coreutils_fix "$1" /usr/bin
			;;
		*)
			run_tool_need='context.sh'
			set_coreutils_fix "$1" /bin
			;;
	esac
}

# Sets run_tool_fix for coreutils tool $1, which macOS ships in folder $2.
set_coreutils_fix() {
	run_tool_fix="put $1 back on PATH (macOS: it ships in $2; Linux: the distro's coreutils package), then rerun"
}

# Checks that the settings file registers the inject hook and both gate hooks
# and allows the Crucible space; a settings file jq can't read fails once for
# all four.
check_settings() {
	if ! command -v jq >/dev/null 2>&1; then
		fail 'hooks not checked' 'jq is missing, and settings.json is read only through jq' "${JQ_FIX}"
		return 0
	fi
	if [ ! -e "${settings_file}" ]; then
		hook_entries=''
		each_hook append_hook_entry
		set_space_fix
		fail 'hooks not registered' "no settings file at ${settings_file}" "create it with ${hook_entries}; and ${space_fix}, then run /hooks or restart"
		return 0
	fi
	if [ ! -f "${settings_file}" ] || [ ! -r "${settings_file}" ]; then
		fail 'hooks not checked' "${settings_file} is not a readable file" "make it readable by your user, then rerun"
		return 0
	fi
	if ! jq empty "${settings_file}" </dev/null >/dev/null 2>&1; then
		fail 'hooks not checked' "${settings_file} is not valid JSON" "repair its JSON syntax, then rerun"
		return 0
	fi
	each_hook check_hook_entry
	check_space_allowed
}

# Calls $1 once per hook entry with: item name, event, matcher ("" any), script,
# timeout, onFailure ("" not required). The one list both the check and its
# fix text are built from.
each_hook() {
	"$1" 'inject hook' PreToolUse Agent "${HOOK_SCRIPT}" "${HOOK_TIMEOUT}" "${HOOK_ON_FAILURE}"
	"$1" 'gate Stop hook' Stop '' "${GATE_STOP_SCRIPT}" "${GATE_HOOK_TIMEOUT}" ''
	"$1" 'gate question hook' PreToolUse AskUserQuestion "${GATE_QUESTION_SCRIPT}" "${GATE_HOOK_TIMEOUT}" ''
}

# Appends the settings entry for hook $2..$6 (each_hook's arguments) to hook_entries.
# shellcheck disable=SC2329 # called by name through each_hook
append_hook_entry() {
	hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5" "$6")
	hook_entries="${hook_entries}${hook_entries:+; }${hook_entry}"
}

# Prints the settings entry for event $1, matcher $2 ("" none), script $3,
# timeout $4 and onFailure $5 ("" none).
# shellcheck disable=SC2329 # called from each_hook's callbacks, which shellcheck can't trace
hook_entry_text() {
	matcher_text=''
	[ -z "$2" ] || matcher_text=" (matcher $2)"
	on_failure_text=''
	[ -z "$5" ] || on_failure_text=", \"onFailure\": \"$5\""
	printf 'a %s hook%s with command sh "%s/%s", timeout %s%s' "$1" "${matcher_text}" "${HOOK_COMMAND_ROOT}" "$3" "$4" "${on_failure_text}"
}

# Checks one entry: item name $1, event $2, matcher $3 ("" any), script $4,
# timeout $5, onFailure $6 ("" not required).
# shellcheck disable=SC2329 # called by name through each_hook
check_hook_entry() {
	where=$2
	[ -z "$3" ] || where="$2 › $3"
	if hook_count=$(jq --arg event "$2" --arg matcher "$3" --arg needle "$4" "${HOOK_COUNT_JQ}" "${settings_file}" </dev/null 2>/dev/null); then
		:
	else
		fail_hook "$4" "$1 not checked" "jq could not read the hook entries in ${settings_file}" "check it with jq, then rerun"
		return 0
	fi
	case ${hook_count} in
		'' | *[!0-9]* | 0)
			hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5" "$6")
			fail_hook "$4" "$1 not registered" "no ${where} entry runs ${4##*/}" "add ${hook_entry}, in settings.json, then run /hooks or restart"
			;;
		*)
			# shellcheck disable=SC2310 # it reports its own failure; its status only says whether to go on
			check_on_failure "$@" || return 0
			pass "$1 registered (${where} in settings.json)"
			;;
	esac
}

# Fails hook $1..$6 (check_hook_entry's arguments) when onFailure $6 is
# required and no entry running its script sets it; returns 1 then.
# shellcheck disable=SC2329 # called from check_hook_entry, which each_hook calls by name
check_on_failure() {
	[ -n "$6" ] || return 0
	if blocking_count=$(jq --arg event "$2" --arg matcher "$3" --arg needle "$4" --arg on_failure "$6" \
		"${HOOK_ON_FAILURE_COUNT_JQ}" "${settings_file}" </dev/null 2>/dev/null); then
		:
	else
		fail_hook "$4" "$1 not checked" "jq could not read the hook entries in ${settings_file}" "check it with jq, then rerun"
		return 1
	fi
	case ${blocking_count} in
		'' | *[!0-9]* | 0)
			hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5" "$6")
			fail_hook "$4" "$1 does not block on failure" "the ${where} entry that runs ${4##*/} has no \"onFailure\": \"$6\", so a failing or timed-out hook lets the dispatch through unprepared" "make it ${hook_entry}, in settings.json, then run /hooks or restart"
			return 1
			;;
		*) return 0 ;;
	esac
}

# Checks that permissions.additionalDirectories holds the Crucible space or a
# folder it lies inside, so
# the main thread and agents read and write there without a prompt.
check_space_allowed() {
	if [ -n "${crucible_home_problem}" ]; then
		fail 'Crucible space not checked' "${crucible_home_problem}" 'fix what it names (CRUCIBLE_HOME, or the crucible skill), then rerun'
		return 0
	fi
	if space_count=$(jq --arg dir "${crucible_home}" "${SPACE_COUNT_JQ}" "${settings_file}" </dev/null 2>/dev/null); then
		:
	else
		fail 'Crucible space not checked' "jq could not read permissions.additionalDirectories in ${settings_file}" "check it with jq, then rerun"
		return 0
	fi
	case ${space_count} in
		'' | *[!0-9]* | 0)
			set_space_fix
			fail 'Crucible space not allowed' "permissions.additionalDirectories in ${settings_file} has no entry that is ${crucible_home} or a folder it lies inside" "${space_fix}, then restart Claude Code"
			;;
		*) pass "Crucible space allowed (${crucible_home} in permissions.additionalDirectories)" ;;
	esac
}

# Sets crucible_home to the space crucible.sh root prints, by the crucible
# skill's space rules, or crucible_home_problem to why it can't be had.
resolve_crucible_home() {
	crucible_home='' crucible_home_problem=''
	crucible_script="${crucible_scripts_dir}/${CRUCIBLE_SCRIPT}"
	if [ ! -f "${crucible_script}" ]; then
		crucible_home_problem="${CRUCIBLE_SCRIPT} is missing from ${crucible_scripts_dir}"
		return 0
	fi
	if crucible_home=$(sh "${crucible_script}" root </dev/null 2>&1); then
		return 0
	fi
	crucible_home_problem="${CRUCIBLE_SCRIPT} root failed: $(printf '%s' "${crucible_home%%"${NL}"*}" | tr -d '\001-\037\177')"
	crucible_home=''
}

# Sets space_fix to the fix that adds the Crucible space: the JSON to merge
# into settings.json, built by jq so the path is escaped.
set_space_fix() {
	if space_fragment=$(jq -cn --arg dir "${crucible_home}" "${SPACE_FRAGMENT_JQ}" </dev/null 2>/dev/null); then
		space_fix="merge ${space_fragment} into settings.json (append the path when additionalDirectories exists)"
	else
		space_fix="add ${crucible_home} to permissions.additionalDirectories in settings.json"
	fi
}

# Checks the plugin listing. list-plugins.sh's stdout and stderr are captured
# together, so nothing is written: a plugin line starts with its kind and a tab,
# and every other line is a report.
check_plugins() {
	list_script="${scripts_dir}/${LIST_SCRIPT}"
	if [ ! -f "${list_script}" ] || [ ! -r "${list_script}" ]; then
		fail 'plugins not checked' 'list-plugins.sh is missing' "reinstall ${PROCEDURE} under ${skills_dir}"
		return 0
	fi
	if listing=$(sh "${list_script}" --max-lines 0 --skills-dir "${skills_dir}" </dev/null 2>&1); then
		list_status=0
	else
		list_status=$?
	fi
	split_listing
	case ${list_status} in
		0) report_counts ;;
		1) warn 'no plugins installed' 'every code part becomes "no plugin fits"' ;;
		3)
			fail 'invalid plugins' 'list-plugins.sh reported invalid plugins' 'fix or reinstall each one, then rerun'
			add_reports
			;;
		*)
			fail 'plugins not listed' "list-plugins.sh exited ${list_status}" "fix what it reports, or reinstall ${PROCEDURE}"
			add_reports
			;;
	esac
}

# Sets tech_count, standard_count, procedure_count and reports (the non-plugin
# lines) from listing.
split_listing() {
	tech_count=0
	standard_count=0
	procedure_count=0
	reports=''
	tab=$(printf '\t')
	while IFS= read -r line; do
		case ${line} in
			'') ;;
			"tech${tab}"*) tech_count=$((tech_count + 1)) ;;
			"standard${tab}"*) standard_count=$((standard_count + 1)) ;;
			"procedure${tab}"*) procedure_count=$((procedure_count + 1)) ;;
			*) reports="${reports}${line}${NL}" ;;
		esac
	done <<EOF
${listing}
EOF
}

report_counts() {
	plugin_count=$((tech_count + standard_count + procedure_count))
	if [ -n "${reports}" ] || [ "${plugin_count}" -eq 0 ]; then
		fail 'plugins not listed' 'list-plugins.sh exited 0 with an unexpected listing' "rerun it with --max-lines 0 and fix what it reports"
		add_reports
		return 0
	fi
	pass "${plugin_count} plugins installed: ${tech_count} tech, ${standard_count} standards, ${procedure_count} procedures"
}

# Adds each report line, its tabs as spaces and other control characters
# dropped, so a line from list-plugins.sh can't forge a checklist line:
# indented to the checklist, and joined by "; " to the last Fix item.
add_reports() {
	[ -n "${reports}" ] || return 0
	clean_reports=$(printf '%s' "${reports}" | tr '\011' ' ' | tr -d '\001-\010\013-\037\177')
	reported=''
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		add_line "  ${line}"
		reported="${reported}${reported:+; }${line}"
	done <<EOF
${clean_reports}
EOF
	[ -z "${reported}" ] || fix_items="${fix_items} (reported: ${reported})"
}

# Writes the marker after a clean pass and removes it after a failure or a
# warning, so only a clean pass is ever skipped. Problems go to cache_note.
record_result() {
	if [ "${failed_count}" -gt 0 ] || [ "${warning_count}" -gt 0 ]; then
		cache_note=''
		rm -f "${marker}" 2>/dev/null || cache_note="the old result at ${marker} could not be removed"
		return 0
	fi
	[ -n "${fingerprint}" ] || return 0
	write_marker
}

# Replaces the marker atomically: a temp file in the same folder, then mv.
write_marker() {
	if ! mkdir -p "${cache_dir}" 2>/dev/null; then
		cache_note="cannot create ${cache_dir}"
		return 0
	fi
	if ! marker_tmp=$(mktemp "${cache_dir}/${MARKER_NAME}.XXXXXX" 2>/dev/null); then
		marker_tmp=''
		cache_note="cannot write to ${cache_dir}"
		return 0
	fi
	if ! pass_time=$(date '+%Y-%m-%d %H:%M'); then
		cache_note='date failed'
		return 0
	fi
	if printf 'fingerprint %s\npassed %s\nchecks %s\n' "${fingerprint}" "${pass_time}" "${passed_count}" >"${marker_tmp}" &&
		mv -f "${marker_tmp}" "${marker}" 2>/dev/null; then
		marker_tmp=''
	else
		cache_note="cannot replace ${marker}"
	fi
}

# Fails one line per base tool missing from PATH, then ends the run with the
# summary and exit 1, since the checks below would misreport without them.
check_base_tools() {
	for tool in ${BASE_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 && continue
		case ${tool} in
			grep) base_package='grep' ;;
			*) base_package='coreutils' ;;
		esac
		fail "${tool}" 'not found on PATH; expected the base system tool every check uses' \
			"put ${tool} back on PATH (macOS: it ships in /usr/bin; Linux: the distro's ${base_package} package), then rerun"
	done
	[ "${failed_count}" -gt 0 ] || return 0
	record_result
	print_result
	exit 1
}

# Prints the result: the full checklist with --verbose, the pass line on a
# clean pass, else the view, or the full checklist when it can't be rendered;
# then the cache note.
print_result() {
	# shellcheck disable=SC2310 # render_view's status picks the fallback checklist
	if [ "${verbose}" -eq 1 ]; then
		print_checklist
	elif result_view=$(render_view); then
		printf '%s\n' "${result_view}"
	else
		[ "${failed_count}" -eq 0 ] && [ "${warning_count}" -eq 0 ] || verbose=1
		print_checklist
	fi
	[ -z "${cache_note}" ] || printf '(result not cached: %s)\n' "${cache_note}"
}

# Prints the header and check lines with --verbose, then the summary line.
print_checklist() {
	[ "${verbose}" -eq 0 ] || printf '%s' "${checklist}"
	print_summary
}

# Prints the view of a full run; fails when it can't be built.
render_view() {
	render_with_view "${RESULT_VIEW_JQ}" --arg fixes "${fix_items}" --arg warnings "${warning_items}" \
		--arg failed "${failed_count}" --arg total "$((passed_count + failed_count + warning_count))"
}

# Prints the cached pass: its view, the full checklist's line with --verbose,
# or that line when the view can't be built.
print_cached_pass() {
	# shellcheck disable=SC2310 # render_with_view's status picks the fallback line
	if [ "${verbose}" -eq 0 ] && cached_view=$(render_with_view "${CACHED_VIEW_JQ}" --arg since "${cached_time}"); then
		printf '%s\n' "${cached_view}"
		return 0
	fi
	[ "${verbose}" -eq 0 ] || printf '%s' "${checklist}"
	printf '✓ Install unchanged since %s: %s checks passed\n' "${cached_time}" "${cached_checks}"
}

# Prints jq program $1, given the further jq arguments, run after human-view's
# view module; fails when jq or the module is missing or jq fails.
render_with_view() {
	command -v jq >/dev/null 2>&1 || return 1
	render_lib_dir="${skills_dir}/${RENDER_LIB}"
	[ -f "${render_lib_dir}/${VIEW_NAME}.jq" ] && [ -r "${render_lib_dir}/${VIEW_NAME}.jq" ] || return 1
	view_program=$1
	shift
	jq -nr -L "${render_lib_dir}" "$@" "include \"${VIEW_NAME}\"; ${view_program}" </dev/null 2>/dev/null
}

print_summary() {
	if [ "${failed_count}" -eq 0 ]; then
		case ${warning_count} in
			0) printf 'All checks passed.\n' ;;
			1) printf 'All checks passed. (1 warning)\n' ;;
			*) printf 'All checks passed. (%s warnings)\n' "${warning_count}" ;;
		esac
	elif [ "${failed_count}" -eq "${inject_failed_count}" ]; then
		printf '%s check(s) failed: dispatch needs the inject hook; direct implementation can go on.\n' "${failed_count}"
	else
		printf '%s check(s) failed.\n' "${failed_count}"
	fi
}

passed_count=0
failed_count=0
inject_failed_count=0
warning_count=0
checklist=''
fix_items=''
warning_items=''
cache_note=''
marker_tmp=''
trap '[ -z "${marker_tmp}" ] || rm -f "${marker_tmp}"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
add_line 'Agent initialization: install check'
check_base_tools
resolve_crucible_home
compute_fingerprint
# shellcheck disable=SC2310 # a pure test of the marker; its status is the answer
if [ "${force}" -eq 0 ] && cached_pass_holds; then
	print_cached_pass
	exit 0
fi
check_script "${PROCEDURE}" "${LIST_SCRIPT}"
check_script "${PROCEDURE}" "${INJECT_SCRIPT}"
check_script "${PROCEDURE}" "${PLAN_RENDER_SCRIPT}"
check_script "${PROCEDURE}" "${PLAN_GENERATOR_SCRIPT}"
check_script "${PROCEDURE}" "${DISPATCH_GENERATOR_SCRIPT}"
check_script "${CONTEXT_PROCEDURE}" "${CONTEXT_SCRIPT}"
check_script "${EFFORT_PROCEDURE}" "${EFFORT_SCRIPT}"
check_script "${GATE_PROCEDURE}" open-gate.sh
check_script "${GATE_PROCEDURE}" gate-stop-hook.sh
check_script "${GATE_PROCEDURE}" gate-question-hook.sh
check_runnable "${CRUCIBLE_SKILL}" "${CRUCIBLE_SCRIPT}"
check_lib_file "${CRUCIBLE_SPACE_LIB}" "${crucible_scripts_dir}" "${CRUCIBLE_SKILL}"
check_lib_file "${PLAN_VALIDATOR_LIB}" "${scripts_dir}" "${PROCEDURE}"
check_lib_file "${INSTALLED_PLUGINS_LIB}" "${scripts_dir}" "${PROCEDURE}"
check_lib_file "${DISPATCH_VALIDATOR_LIB}" "${scripts_dir}" "${PROCEDURE}"
check_lib_file "${PLUGIN_FILES_LIB}" "${scripts_dir}" "${PROCEDURE}"
check_lib_file "${DISPATCH_NAMES_LIB}" "${scripts_dir}" "${PROCEDURE}"
check_lib_file "${CONTEXT_VALIDATOR_LIB}" "${context_scripts_dir}" "${CONTEXT_PROCEDURE}"
check_lib_file "${CONTEXT_URL_LIB}" "${context_scripts_dir}" "${CONTEXT_PROCEDURE}"
check_lib_file "${CONTEXT_FILE_LIB}" "${context_scripts_dir}" "${CONTEXT_PROCEDURE}"
check_lib_file "${CONTEXT_VERSIONS_LIB}" "${context_scripts_dir}" "${CONTEXT_PROCEDURE}"
check_template
check_lib_file "${PATHS_MODULE}" "${skills_dir}" "${RENDER_LIB}"
check_lib_file "${VIEW_MODULE}" "${skills_dir}" "${RENDER_LIB}"
check_jq
check_run_tools
check_settings
check_plugins
record_result
print_result
if [ "${failed_count}" -eq 0 ]; then exit 0; fi
if [ "${failed_count}" -eq "${inject_failed_count}" ]; then exit 3; fi
exit 1
