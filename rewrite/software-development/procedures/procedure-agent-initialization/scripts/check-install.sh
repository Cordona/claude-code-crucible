#!/usr/bin/env sh
# Prints the install checklist for procedure-agent-initialization: its four
# scripts, the two context checks they share and lib-render's path helpers,
# which a printed plan loads, procedure-approval-gate's
# open-gate.sh and its two hook scripts, jq, the three hook entries in
# settings.json (the inject hook and both gate hooks), and the installed
# plugins. Every check runs, whatever an earlier one found, so one run names
# every fix. It reads settings.json only through jq, and only those hook
# commands, which it counts or hashes and never prints: the file may hold
# secrets in its env block.
# A full pass is cached: the marker keeps a fingerprint of everything the checks
# depend on, and while that fingerprint is unchanged the checks are skipped.
# The marker is the only file it writes; it holds no settings content.
# Exit 3 means only the inject hook check failed: dispatch can't inject
# plugins, but direct implementation can go on. jq and the gate hooks are
# exit 1 failures, since the approval gate every plan goes through needs them.
set -eu

readonly PROG='check-install.sh'
readonly PROCEDURE='procedure-agent-initialization'
readonly GATE_PROCEDURE='procedure-approval-gate'
readonly HOOK_SCRIPT="${PROCEDURE}/scripts/inject-plugins.sh"
readonly CONTEXT_SHAPE_LIB='lib/context-shape.jq'
readonly CONTEXT_FILE_LIB='lib/context-file.sh'
readonly RENDER_LIB='lib-render'
readonly PATHS_MODULE="${RENDER_LIB}/paths.jq"
readonly GATE_STOP_SCRIPT="${GATE_PROCEDURE}/scripts/gate-stop-hook.sh"
readonly GATE_QUESTION_SCRIPT="${GATE_PROCEDURE}/scripts/gate-question-hook.sh"
# A timed-out inject hook lets the dispatch through with no plugins, and the
# hook reads every plugin file on the PLUGIN line, so its bound is generous.
readonly HOOK_TIMEOUT=30
# The gate hooks read one small state file, and a timed-out one lets the stop
# or question through, so a stuck one is cut short.
readonly GATE_HOOK_TIMEOUT=10
# Printed unexpanded so the fix can be pasted into settings.json as is.
# shellcheck disable=SC2016
readonly HOOK_COMMAND_ROOT='${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills'
readonly JQ_FIX='install jq 1.6+ (macOS: brew install jq; Linux: the distro'\''s jq package), then rerun'
readonly MARKER_NAME='install-check'
# inject-plugins.sh needs jq 1.6 for --rawfile (see inject-plugins.sh --help).
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
# The C locale keeps pattern matching and sort byte-wise; the UTF-8 marks are
# printed as bytes.
LC_ALL=C
export LC_ALL
NL='
'
readonly NL

usage() {
	cat <<EOF
Usage: sh ${PROG} [--skills-dir DIR] [--settings FILE] [--cache-dir CACHE]
                        [--force] [--help|-h]

Checks that ${PROCEDURE} is installed and ready, and prints one line per check:
  ✓ list-plugins.sh            the script is in DIR/${PROCEDURE}/scripts/
  ✓ render-plugin-line.sh      and its --help exits 0 with a Usage: line
  ✓ inject-plugins.sh
  ✓ render-dispatch-plan.sh
  ✓ open-gate.sh               the same, in DIR/${GATE_PROCEDURE}/scripts/
  ✓ gate-stop-hook.sh
  ✓ gate-question-hook.sh
  ✓ ${CONTEXT_SHAPE_LIB}       a readable file in DIR/${PROCEDURE}/scripts/
  ✓ ${CONTEXT_FILE_LIB}        the same
  ✓ ${PATHS_MODULE}        a readable file in DIR/${RENDER_LIB}/
  ✓ jq <version>               jq on PATH, version ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR} or newer
  ✓ inject hook registered (...)
                               FILE is valid JSON with a PreToolUse entry,
                               matcher "Agent", whose command runs ${HOOK_SCRIPT}
  ✓ gate Stop hook registered (...)
                               a Stop entry whose command runs
                               ${GATE_STOP_SCRIPT}
  ✓ gate question hook registered (...)
                               a PreToolUse entry, matcher "AskUserQuestion",
                               whose command runs ${GATE_QUESTION_SCRIPT}
  ✓ <N> plugins installed: <t> tech, <s> standards
                               from list-plugins.sh --max-lines 0
A failed check prints "✗ <item>: <reason>. Fix: <action>" instead (invalid
plugins add list-plugins.sh's report lines, indented). No plugins at all is a
warning, not a failure: "⚠ no plugins installed: ...". The last line is
"All checks passed." (plus " (1 warning)" after a warning),
"<n> check(s) failed: dispatch needs the inject hook; direct implementation can
go on." when only the inject hook check failed, or "<n> check(s) failed."
otherwise.
When jq is missing or FILE is missing, unreadable or not JSON, one line covers
all three hook checks.

Cache: a full pass with no warning writes CACHE/${MARKER_NAME}, holding a
fingerprint of the five procedure scripts, ${CONTEXT_SHAPE_LIB}, ${CONTEXT_FILE_LIB},
${PATHS_MODULE}, ${GATE_PROCEDURE}'s three (open-gate.sh and both gate
hook scripts), the three hook entries' commands (hashed), the jq version, and each
tech-*/standard-* folder's name, SKILL.md and references/ files. While the fingerprint is unchanged, a run prints only:
  ✓ Install unchanged since <YYYY-MM-DD HH:MM>: <n> checks passed
A failed run or a warning removes the marker. When the result can't be cached,
the checklist ends with "(result not cached: <reason>)"; that never fails it.

  DIR    the skills folder; defaults to \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills
  FILE   the settings file; defaults to \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/settings.json
  CACHE  the marker folder; defaults to \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/agent-init
  --force  runs every check even when the fingerprint is unchanged

Exit codes:
  0  every check passed (a warning included), or the cached pass still holds
  1  a script, plugin, jq or gate hook check failed (whatever else failed
     too); jq and both gate hooks are needed by the approval gate
  2  usage error
  3  only the inject hook check failed: direct implementation can go on,
     dispatch can't

Dependencies: POSIX sh, tr; cksum, find, sort, date, mkdir, mktemp, mv and rm
for the cache; jq is a check, not a requirement.
Runtime: about 0.12 s for a full pass, 0.03 s cached; measured on macOS (average of 5 runs).
Reads only: settings.json through jq (the hook commands, counted or hashed,
never printed). Writes only: CACHE/${MARKER_NAME}.
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
			--skills-dir | --settings | --cache-dir)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 PATH"
				case $1 in
					--settings) settings_file=$2 ;;
					--cache-dir) cache_dir=$2 ;;
					*) skills_dir=$2 ;;
				esac
				shift 2
				;;
			*) usage_error "unknown argument: $1; expected --skills-dir, --settings, --cache-dir, --force or --help" ;;
		esac
	done
	scripts_dir="${skills_dir}/${PROCEDURE}/scripts"
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
	cksum "${scripts_dir}/list-plugins.sh" "${scripts_dir}/render-plugin-line.sh" \
		"${scripts_dir}/inject-plugins.sh" "${scripts_dir}/check-install.sh" \
		"${scripts_dir}/render-dispatch-plan.sh" "${scripts_dir}/${CONTEXT_SHAPE_LIB}" "${scripts_dir}/${CONTEXT_FILE_LIB}" \
		"${skills_dir}/${PATHS_MODULE}" \
		"${gate_scripts_dir}/open-gate.sh" \
		"${gate_scripts_dir}/gate-stop-hook.sh" "${gate_scripts_dir}/gate-question-hook.sh" 2>/dev/null ||
		printf 'scripts unreadable\n'
	fingerprint_hook PreToolUse Agent "${HOOK_SCRIPT}"
	fingerprint_hook Stop '' "${GATE_STOP_SCRIPT}"
	fingerprint_hook PreToolUse AskUserQuestion "${GATE_QUESTION_SCRIPT}"
	printf 'jq\n'
	jq --version </dev/null 2>/dev/null || printf 'jq unavailable\n'
	printf 'plugins\n'
	fingerprint_plugins
}

# Prints the hook commands for event $1, matcher $2 ("" any) and script $3, or
# a fixed line when they can't be read.
fingerprint_hook() {
	printf 'hook %s %s %s\n' "$1" "$2" "$3"
	jq -c --arg event "$1" --arg matcher "$2" --arg needle "$3" "${HOOK_COMMANDS_JQ}" "${settings_file}" </dev/null 2>/dev/null ||
		printf 'hook commands unreadable\n'
}

# Prints each tech-*/standard-* folder name, then one cksum line per file in
# their SKILL.md and references/, sorted. Symlinks are followed: an installed
# plugin is usually a link to its source folder.
fingerprint_plugins() {
	set --
	for plugin_path in "${skills_dir}"/tech-* "${skills_dir}"/standard-*; do
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

pass() {
	printf '✓ %s\n' "$1"
	passed_count=$((passed_count + 1))
}

# Prints a failed line for item $1, reason $2 and fix $3, and counts it.
fail() {
	printf '✗ %s: %s. Fix: %s\n' "$1" "$2" "$3"
	failed_count=$((failed_count + 1))
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

# Prints a warning line for item $1 and reason $2, and counts it.
warn() {
	printf '⚠ %s: %s\n' "$1" "$2"
	warning_count=$((warning_count + 1))
}

# Checks that script $2 of procedure $1 is installed and answers --help with a
# Usage: line.
check_script() {
	script_dir="${skills_dir}/$1/scripts"
	script="${script_dir}/$2"
	reinstall="reinstall $1 under ${skills_dir}"
	shift
	if [ ! -f "${script}" ] || [ ! -r "${script}" ]; then
		fail "$1" "missing from ${script_dir}" "${reinstall}"
		return 0
	fi
	if help_text=$(sh "${script}" --help </dev/null 2>/dev/null); then
		help_status=0
	else
		help_status=$?
	fi
	if [ "${help_status}" -ne 0 ]; then
		fail "$1" "--help exited ${help_status}, expected 0" "${reinstall}"
		return 0
	fi
	case ${NL}${help_text} in
		*"${NL}Usage:"*) pass "$1" ;;
		*) fail "$1" "--help printed no Usage: line" "${reinstall}" ;;
	esac
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

# Checks that the settings file registers the inject hook and both gate hooks;
# a settings file jq can't read fails once for all three.
check_hooks() {
	if ! command -v jq >/dev/null 2>&1; then
		fail 'hooks not checked' 'jq is missing, and settings.json is read only through jq' "${JQ_FIX}"
		return 0
	fi
	if [ ! -e "${settings_file}" ]; then
		hook_entries=''
		each_hook append_hook_entry
		fail 'hooks not registered' "no settings file at ${settings_file}" "create it with ${hook_entries}, then run /hooks or restart"
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
}

# Calls $1 once per hook entry with: item name, event, matcher ("" any), script,
# timeout. The one list both the check and its fix text are built from.
each_hook() {
	"$1" 'inject hook' PreToolUse Agent "${HOOK_SCRIPT}" "${HOOK_TIMEOUT}"
	"$1" 'gate Stop hook' Stop '' "${GATE_STOP_SCRIPT}" "${GATE_HOOK_TIMEOUT}"
	"$1" 'gate question hook' PreToolUse AskUserQuestion "${GATE_QUESTION_SCRIPT}" "${GATE_HOOK_TIMEOUT}"
}

# Appends the settings entry for hook $2..$5 (each_hook's arguments) to hook_entries.
# shellcheck disable=SC2329 # called by name through each_hook
append_hook_entry() {
	hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5")
	hook_entries="${hook_entries}${hook_entries:+; }${hook_entry}"
}

# Prints the settings entry for event $1, matcher $2 ("" none), script $3, timeout $4.
# shellcheck disable=SC2329 # called from each_hook's callbacks, which shellcheck can't trace
hook_entry_text() {
	matcher_text=''
	[ -z "$2" ] || matcher_text=" (matcher $2)"
	printf 'a %s hook%s with command sh "%s/%s", timeout %s' "$1" "${matcher_text}" "${HOOK_COMMAND_ROOT}" "$3" "$4"
}

# Checks one entry: item name $1, event $2, matcher $3 ("" any), script $4, timeout $5.
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
			hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5")
			fail_hook "$4" "$1 not registered" "no ${where} entry runs ${4##*/}" "add ${hook_entry}, in settings.json, then run /hooks or restart"
			;;
		*) pass "$1 registered (${where} in settings.json)" ;;
	esac
}

# Checks the plugin listing. list-plugins.sh's stdout and stderr are captured
# together, so nothing is written: a plugin line starts with its kind and a tab,
# and every other line is a report.
check_plugins() {
	list_script="${scripts_dir}/list-plugins.sh"
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
			fail 'invalid plugins' 'list-plugins.sh reported the plugins below' 'fix or reinstall each one, then rerun'
			print_reports
			;;
		*)
			fail 'plugins not listed' "list-plugins.sh exited ${list_status}" "fix what it reports below, or reinstall ${PROCEDURE}"
			print_reports
			;;
	esac
}

# Sets tech_count, standard_count and reports (the non-plugin lines) from listing.
split_listing() {
	tech_count=0
	standard_count=0
	reports=''
	tab=$(printf '\t')
	while IFS= read -r line; do
		case ${line} in
			'') ;;
			"tech${tab}"*) tech_count=$((tech_count + 1)) ;;
			"standard${tab}"*) standard_count=$((standard_count + 1)) ;;
			*) reports="${reports}${line}${NL}" ;;
		esac
	done <<EOF
${listing}
EOF
}

report_counts() {
	plugin_count=$((tech_count + standard_count))
	if [ -n "${reports}" ] || [ "${plugin_count}" -eq 0 ]; then
		fail 'plugins not listed' 'list-plugins.sh exited 0 with an unexpected listing' "rerun it with --max-lines 0 and fix what it reports below"
		print_reports
		return 0
	fi
	pass "${plugin_count} plugins installed: ${tech_count} tech, ${standard_count} standards"
}

# Prints each report line indented, its tabs as spaces and other control
# characters dropped, so a line from list-plugins.sh can't forge a checklist line.
print_reports() {
	[ -n "${reports}" ] || return 0
	printf '%s' "${reports}" | tr '\011' ' ' | tr -d '\001-\010\013-\037\177' | while IFS= read -r line; do
		printf '  %s\n' "${line}"
	done
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
	[ -z "${cache_note}" ] || printf '(result not cached: %s)\n' "${cache_note}"
}

passed_count=0
failed_count=0
inject_failed_count=0
warning_count=0
cache_note=''
marker_tmp=''
trap '[ -z "${marker_tmp}" ] || rm -f "${marker_tmp}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
printf 'Agent initialization: install check\n'
compute_fingerprint
# shellcheck disable=SC2310 # a pure test of the marker; its status is the answer
if [ "${force}" -eq 0 ] && cached_pass_holds; then
	printf '✓ Install unchanged since %s: %s checks passed\n' "${cached_time}" "${cached_checks}"
	exit 0
fi
check_script "${PROCEDURE}" list-plugins.sh
check_script "${PROCEDURE}" render-plugin-line.sh
check_script "${PROCEDURE}" inject-plugins.sh
check_script "${PROCEDURE}" render-dispatch-plan.sh
check_script "${GATE_PROCEDURE}" open-gate.sh
check_script "${GATE_PROCEDURE}" gate-stop-hook.sh
check_script "${GATE_PROCEDURE}" gate-question-hook.sh
check_lib_file "${CONTEXT_SHAPE_LIB}" "${scripts_dir}" "${PROCEDURE}"
check_lib_file "${CONTEXT_FILE_LIB}" "${scripts_dir}" "${PROCEDURE}"
check_lib_file "${PATHS_MODULE}" "${skills_dir}" "${RENDER_LIB}"
check_jq
check_hooks
check_plugins
record_result
print_summary
if [ "${failed_count}" -eq 0 ]; then exit 0; fi
if [ "${failed_count}" -eq "${inject_failed_count}" ]; then exit 3; fi
exit 1
