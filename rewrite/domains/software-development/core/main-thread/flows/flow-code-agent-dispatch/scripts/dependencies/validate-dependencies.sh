#!/usr/bin/env sh
# Runs the install check for flow-code-agent-dispatch: its five other
# scripts, procedure-context's context.sh, procedure-effort's effort.sh,
# procedure-seat-run's seats.sh, iteration.sh, its card helper and its seat
# bind, report commit and block relay hook scripts, procedure-git-worktree's
# seat-move.sh, worktree-move.sh, catch-up.sh and its card helper, the crucible
# skill's space rules, the four context checks the
# scripts share and the context-handling template the inject hook sends, the
# dispatch plan check and its plugin list reader, the dispatch check, the
# plugin file helper and the dispatch names module, the crucible skill's prune
# module, which the plan and dispatch scripts and the inject hook load,
# human-view's view, title, line and gate modules, which the cards and the
# dispatch script load, human-view's show.sh, its card printer helper, its
# Stop hook and their store rules, the card templates of this skill,
# procedure-approval-gate, procedure-context, procedure-git-worktree and
# procedure-seat-run, procedure-approval-gate's
# open-gate.sh and its two hook scripts, crucible.sh and its events guard
# hook, jq, the run-time tools
# date, git, cmp, awk, sort, mktemp, mv, rm, wc and sha256sum or shasum, the nine hook
# entries in settings.json (the inject hook and the crucible skill's events
# guard hook, which must block on failure, human-view's Stop hook entry, the
# three gate hook entries, and
# procedure-seat-run's seat bind, report commit and async block relay
# hooks), the Crucible space in its additionalDirectories, its Edit allow
# rule and its events Edit deny rule, and the installed plugins. Every check
# runs, whatever an earlier one found, so one run names every fix; the
# result is printed at the end as one card, views/install-check.jq, through
# human-view's show.sh, which needs jq: with jq missing, a plain list of the
# Fix items is printed instead. It reads
# settings.json only through jq, and only those hook commands,
# permissions.additionalDirectories, permissions.allow and permissions.deny,
# which it counts or
# hashes and never prints: the file may hold secrets in its env block.
# A full pass is cached: the marker keeps a fingerprint of everything the checks
# depend on, and while that fingerprint is unchanged the checks are skipped.
# The marker is the only file it leaves (its temp file is removed on exit),
# show.sh's owed record aside;
# it holds no settings content.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../../../../../framework/core/engine/human-view/scripts/lib
set -eu

readonly PROG='validate-dependencies.sh'
readonly PROCEDURE='flow-code-agent-dispatch'
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
readonly VIEW_MODULE="${RENDER_LIB}/view.jq"
readonly TITLE_MODULE="${RENDER_LIB}/title.jq"
readonly LINE_MODULE="${RENDER_LIB}/line.jq"
readonly GATE_MODULE="${RENDER_LIB}/gate.jq"
readonly SHOW_SCRIPTS="${RENDER_LIB}/scripts"
readonly SHOW_STOP_SCRIPT="${SHOW_SCRIPTS}/show-stop-hook.sh"
# Relative to DIR/human-view/scripts/.
readonly OWED_SH_LIB='lib/owed.sh'
readonly OWED_JQ_LIB='lib/owed.jq'
readonly CARD_PRINTER_LIB='lib/render.sh'
# The result's card, and the lines --line may add after it, in views/ of
# this skill.
readonly CARD_NAME='install-check'
readonly LINE_TEMPLATE='lines'
readonly LINE_NAMES='ask_tool_missing confirm_hooks_loaded'
readonly GATE_QUESTION_SCRIPT="${GATE_PROCEDURE}/scripts/gate-question-hook.sh"
readonly GATE_ANSWER_SCRIPT="${GATE_PROCEDURE}/scripts/gate-answer-hook.sh"
readonly WORKTREE_PROCEDURE='procedure-git-worktree'
readonly SEAT_RUN_PROCEDURE='procedure-seat-run'
readonly SEAT_BIND_SCRIPT="${SEAT_RUN_PROCEDURE}/scripts/hooks/seat-bind-hook.sh"
readonly REPORT_COMMIT_SCRIPT="${SEAT_RUN_PROCEDURE}/scripts/hooks/report-commit-hook.sh"
readonly BLOCK_RELAY_SCRIPT="${SEAT_RUN_PROCEDURE}/scripts/hooks/block-relay-hook.sh"
# Relative to DIR/procedure-git-worktree/scripts/: what seat-move.sh and
# catch-up.sh print their cards through; relative to
# DIR/procedure-seat-run/scripts/: what seats.sh and iteration.sh print their
# lines through.
readonly CARDS_LIB='cards/cards-lib.sh'
readonly CRUCIBLE_SKILL='crucible'
readonly CRUCIBLE_SCRIPT='crucible.sh'
readonly EVENTS_SCRIPT='events.sh'
readonly EVENTS_GUARD_HOOK='events-guard-hook.sh'
readonly EVENTS_GUARD_SCRIPT="${CRUCIBLE_SKILL}/scripts/${EVENTS_GUARD_HOOK}"
# Relative to DIR/crucible/scripts/.
readonly CRUCIBLE_SPACE_LIB='lib/crucible-space.sh'
readonly PRUNE_MODULE='lib/prune.jq'
# The inject hook reads every plugin file of the dispatch, so its bound is
# generous; with "onFailure": "block" a timeout blocks the dispatch.
readonly HOOK_TIMEOUT=30
# The inject hook's and the events guard hook's entries must block their call
# when the hook fails or times out; Claude Code otherwise lets it through (the
# dispatch with its prompt untouched, the Bash command unchecked).
readonly HOOK_ON_FAILURE='block'

# The gate hooks and the card Stop hook read or write a few small records or
# one event, and a timed-out one lets the stop, question or answer through, so
# a stuck one is cut short.
readonly GATE_HOOK_TIMEOUT=10
# The seat bind hook runs one seats.sh change; the report commit hook checks a
# report and commits the worktree, so its bound is wider.
readonly SEAT_BIND_HOOK_TIMEOUT=10
readonly REPORT_COMMIT_HOOK_TIMEOUT=30
# The block relay hook waits for the report commit hook's outcome, up to two minutes, and must
# run async with asyncRewake: its exit 2 is what wakes the main thread.
readonly BLOCK_RELAY_HOOK_TIMEOUT=150
# The events guard hook runs one jq over the command text; with "onFailure":
# "block" a timed-out one blocks the Bash call, so a stuck one is cut short.
readonly EVENTS_GUARD_HOOK_TIMEOUT=10
readonly HOOK_ASYNC_REWAKE='rewake'
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
	| [.command, .onFailure?, .async?, .asyncRewake?]'
# Counts the hook entries under event $event and matcher $matcher that run
# $needle with "async" and "asyncRewake" both true.
# shellcheck disable=SC2016
readonly HOOK_ASYNC_REWAKE_COUNT_JQ='[.hooks?[$event]?[]?
	| select(type == "object" and ($matcher == "" or .matcher == $matcher))
	| .hooks?[]?
	| select(type == "object" and (.command? | type == "string" and contains($needle)) and .async? == true and .asyncRewake? == true)]
	| length'

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
# Emits the folder of each permissions.allow rule Edit(//<folder>/**), with
# its leading slash; a missing or mistyped level emits nothing. A Write rule
# alone does not let an agent edit its report draft in the space.
readonly EDIT_RULE_DIRS_JQ='.permissions?.allow?[]? | strings | capture("^Edit\\(/(?<dir>/.*[^/])/+\\*\\*\\)$")? | .dir'
# Counts the Edit rules whose folder is $dir or a parent of it, whole path
# components only, as SPACE_COUNT_JQ does.
# shellcheck disable=SC2016 # $dir is jq's
readonly EDIT_RULE_COUNT_JQ="(\$dir | sub(\"/+\$\"; \"\")) as \$space | [${EDIT_RULE_DIRS_JQ} | select(. as \$entry | \$space == \$entry or (\$space | startswith(\$entry + \"/\")))] | length"
# shellcheck disable=SC2016 # $dir is jq's
readonly EDIT_RULE_FRAGMENT_JQ='{permissions: {allow: ["Edit(/\($dir | sub("/+$"; ""))/**)"]}}'
# The permissions.deny rule that keeps Write and Edit calls out of every
# effort's events/ folder for space $dir, which the Edit allow rule above
# would otherwise let through: events are written only by their scripts.
# shellcheck disable=SC2016 # $dir is jq's
readonly EVENTS_DENY_RULE_JQ='"Edit(/\($dir | sub("/+$"; ""))/efforts/*/events/**)"'
# Counts the permissions.deny entries that are exactly that rule.
readonly EVENTS_DENY_COUNT_JQ="(${EVENTS_DENY_RULE_JQ}) as \$rule | [.permissions?.deny?[]? | strings | select(. == \$rule)] | length"
# Emits each permissions.deny Edit rule, for the fingerprint.
readonly EVENTS_DENY_RULES_JQ='.permissions?.deny?[]? | strings | select(startswith("Edit("))'
readonly EVENTS_DENY_FRAGMENT_JQ="{permissions: {deny: [${EVENTS_DENY_RULE_JQ}]}}"
# The C locale keeps pattern matching and sort byte-wise; the UTF-8 marks are
# printed as bytes.
LC_ALL=C
export LC_ALL
NL='
'
readonly NL
# Separates the card's items handed to jq; no check text holds it.
ITEM_SEPARATOR=$(printf '\036')
readonly ITEM_SEPARATOR
# Builds views/install-check.jq's data from the counts $failed and $total,
# the items $fixes, $warnings and $passed (separated by U+001E; $passed only
# when $verbose is 1), the cached pass time $since and the cache note $note
# ("" for none).
# shellcheck disable=SC2016 # the $ names are jq's
readonly CARD_DATA_JQ='
def items: split("\u001e") | map(select(length > 0));
def or_null: if . == "" then null else . end;
{failed: ($failed | tonumber), total: ($total | tonumber),
 fixes: ($fixes | items), warnings: ($warnings | items),
 passed: (if $verbose == "1" then $passed | items else null end),
 since: ($since | or_null), not_cached: ($note | or_null)}'

usage() {
	cat <<EOF
usage: sh ${PROG} [--skills-dir DIR] [--settings FILE]
                                   [--cache-dir CACHE] [--force] [--verbose]
                                   [--line NAME]...
       sh ${PROG} --help | -h

Checks the skills, tools, settings.json entries and plugins
  ${PROCEDURE} needs.

Options:
  --skills-dir DIR   the skills folder; default
                     \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills
  --settings FILE    the settings file; default
                     \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/settings.json
  --cache-dir CACHE  the cache folder; default
                     \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/cache/code-agent-dispatch
  --force            runs every check even when the cached pass holds
  --verbose          the card also lists every passed check (Passed)
  --line NAME        prints the line NAME of views/${LINE_TEMPLATE}.jq after
                     the card; repeatable; one of:
                     ask_tool_missing      AskUserQuestion is not in the
                                           main thread's tools
                     confirm_hooks_loaded  the human added or changed a hook
                                           entry

stdout: the card views/${CARD_NAME}.jq, printed by ${RENDER_LIB}'s show.sh
  and recorded as owed this session; then each --line line, the same way.
  The card's cases: passed, with the count of checks (no ⚠); a cached
  pass, with its time; blocked (any ✗), one Fix item per ✗ or ⚠ check;
  passed with warnings (only ⚠), one Warnings item per ⚠ check; and, when
  a pass can't be cached, a not-cached note with its reason, never a
  failure. Without jq, which show.sh needs: a plain list of the Fix items
  instead, and no line.

Cache: after a pass with no ⚠, leaves only CACHE/${MARKER_NAME} and
  reuses it until anything the checks read changes; a ✗ or ⚠ removes it.
settings.json: reads only its hook entries, permissions.additionalDirectories
  permissions.allow (for Edit(//<space>/**)) and permissions.deny (for
  Edit(//<space>/efforts/*/events/**)); never writes it or prints a value.

Exit codes:
  0  every check passed (a ⚠ included), or the cached pass holds; go on
  1  a check failed; stop: each Fix item names its fix
  2  usage error; reinstall ${PROCEDURE} and stop
  4  stdout closed before the card was printed; stop
  5  the card could not be printed: show.sh, ${CARD_PRINTER_LIB} or a template
     missing or failing; show the human stderr, which names what to install
  129, 130, 143  stopped by HUP, INT or TERM; tell the human it was stopped,
                 show the exit code, and stop

Environment:
  CLAUDE_CODE_SESSION_ID  set by the Bash tool; unset: the card is printed,
                 nothing is recorded
  CLAUDE_CONFIG_DIR  the Claude Code config folder; default \$HOME/.claude

Dependencies:
  POSIX sh; cat, grep, readlink, tr
  cksum, date, find, mkdir, mktemp, mv, rm, sort for the cache (a missing one
    leaves the result not cached)
  to print the card: jq ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR}+, ${RENDER_LIB}'s scripts/show.sh and
    scripts/${CARD_PRINTER_LIB} in the --skills-dir, and this skill's
    views/${CARD_NAME}.jq and views/${LINE_TEMPLATE}.jq
  jq ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR}+, date, git, cmp, awk, sort, mktemp, mv, rm, wc, sha256sum or
    shasum: checked, not required; each has its own check line
EOF
}

usage_error() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Sets skills_dir, settings_file and cache_dir (each absolute, so every Fix
# item names a whole path), force, verbose and line_names from the arguments.
parse_args() {
	config_dir="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
	skills_dir="${config_dir}/skills"
	settings_file="${config_dir}/settings.json"
	cache_dir="${config_dir}/cache/code-agent-dispatch"
	force=0
	verbose=0
	line_names=''
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
			--line)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "--line needs a value; expected --line NAME, one of: ${LINE_NAMES}"
				add_line_name "$2"
				shift 2
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
			*) usage_error "unknown argument: $1; expected --skills-dir, --settings, --cache-dir, --force, --verbose, --line or --help" ;;
		esac
	done
	skills_dir=$(absolute_path "${skills_dir}")
	settings_file=$(absolute_path "${settings_file}")
	cache_dir=$(absolute_path "${cache_dir}")
	procedure_dir="${skills_dir}/${PROCEDURE}"
	scripts_dir="${procedure_dir}/scripts"
	context_procedure_dir="${skills_dir}/${CONTEXT_PROCEDURE}"
	context_scripts_dir="${context_procedure_dir}/scripts"
	crucible_scripts_dir="${skills_dir}/${CRUCIBLE_SKILL}/scripts"
	gate_scripts_dir="${skills_dir}/${GATE_PROCEDURE}/scripts"
	marker="${cache_dir}/${MARKER_NAME}"
}

# Adds line name $1 to line_names, once, or exits 2 unless it is one of LINE_NAMES.
add_line_name() {
	case " ${LINE_NAMES} " in
		*" $1 "*) ;;
		*) usage_error "unknown --line name: $1; expected one of: ${LINE_NAMES}" ;;
	esac
	case " ${line_names} " in
		*" $1 "*) ;;
		*) line_names="${line_names}${line_names:+ }$1" ;;
	esac
}

# Prints path $1, a relative one taken from the current folder.
absolute_path() {
	case $1 in
		/*) printf '%s' "$1" ;;
		*) printf '%s' "${PWD}/${1#./}" ;;
	esac
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
		"${skills_dir}/${VIEW_MODULE}" \
		"${skills_dir}/${TITLE_MODULE}" \
		"${skills_dir}/${LINE_MODULE}" "${skills_dir}/${GATE_MODULE}" \
		"${gate_scripts_dir}/open-gate.sh" \
		"${skills_dir}/${SHOW_SCRIPTS}/show.sh" "${skills_dir}/${SHOW_STOP_SCRIPT}" \
		"${skills_dir}/${SHOW_SCRIPTS}/${OWED_SH_LIB}" "${skills_dir}/${SHOW_SCRIPTS}/${OWED_JQ_LIB}" \
		"${skills_dir}/${SHOW_SCRIPTS}/${CARD_PRINTER_LIB}" \
		"${skills_dir}/${WORKTREE_PROCEDURE}/scripts/${CARDS_LIB}" \
		"${skills_dir}/${SEAT_RUN_PROCEDURE}/scripts/${CARDS_LIB}" \
		"${gate_scripts_dir}/gate-question-hook.sh" \
		"${gate_scripts_dir}/gate-answer-hook.sh" \
		"${skills_dir}/${EFFORT_PROCEDURE}/scripts/${EFFORT_SCRIPT}" \
		"${skills_dir}/${SEAT_RUN_PROCEDURE}/scripts/seats/seats.sh" \
		"${skills_dir}/${SEAT_RUN_PROCEDURE}/scripts/seats/iteration.sh" \
		"${skills_dir}/${WORKTREE_PROCEDURE}/scripts/seats/seat-move.sh" \
		"${skills_dir}/${WORKTREE_PROCEDURE}/scripts/worktree/worktree-move.sh" \
		"${skills_dir}/${WORKTREE_PROCEDURE}/scripts/merge/catch-up.sh" \
		"${skills_dir}/${SEAT_BIND_SCRIPT}" "${skills_dir}/${REPORT_COMMIT_SCRIPT}" "${skills_dir}/${BLOCK_RELAY_SCRIPT}" \
		"${crucible_scripts_dir}/${CRUCIBLE_SCRIPT}" "${crucible_scripts_dir}/${EVENTS_SCRIPT}" \
		"${crucible_scripts_dir}/${EVENTS_GUARD_HOOK}" \
		"${crucible_scripts_dir}/${CRUCIBLE_SPACE_LIB}" \
		"${crucible_scripts_dir}/${PRUNE_MODULE}" 2>/dev/null ||
		printf 'scripts unreadable\n'
	printf 'templates\n'
	each_view_template fingerprint_templates
	fingerprint_hook PreToolUse Agent "${HOOK_SCRIPT}"
	fingerprint_hook Stop '' "${SHOW_STOP_SCRIPT}"
	fingerprint_hook PreToolUse AskUserQuestion "${GATE_QUESTION_SCRIPT}"
	fingerprint_hook PostToolUse AskUserQuestion "${GATE_ANSWER_SCRIPT}"
	fingerprint_hook UserPromptSubmit '' "${GATE_ANSWER_SCRIPT}"
	fingerprint_hook PostToolUse Agent "${SEAT_BIND_SCRIPT}"
	fingerprint_hook SubagentStop '' "${REPORT_COMMIT_SCRIPT}"
	fingerprint_hook SubagentStop '' "${BLOCK_RELAY_SCRIPT}"
	fingerprint_hook PreToolUse Bash "${EVENTS_GUARD_SCRIPT}"
	printf 'crucible space\n%s\n' "${crucible_home}"
	jq -c "${ALLOWED_DIRS_JQ}" "${settings_file}" </dev/null 2>/dev/null ||
		printf 'additional directories unreadable\n'
	jq -c "${EDIT_RULE_DIRS_JQ}" "${settings_file}" </dev/null 2>/dev/null ||
		printf 'edit rules unreadable\n'
	jq -c "${EVENTS_DENY_RULES_JQ}" "${settings_file}" </dev/null 2>/dev/null ||
		printf 'deny rules unreadable\n'
	printf 'jq\n'
	jq --version </dev/null 2>/dev/null || printf 'jq unavailable\n'
	printf 'tools\n'
	for tool in ${RUN_TOOLS} sha256sum shasum; do
		command -v "${tool}" 2>/dev/null || printf '%s missing\n' "${tool}"
	done
	printf 'plugins\n'
	fingerprint_plugins
}

# Calls $1 once per skill with that skill, then the templates (views/<name>.jq)
# its checked scripts print their cards and lines through: the one list both
# the template checks and the fingerprint are built from.
each_view_template() {
	"$1" "${PROCEDURE}" "${CARD_NAME}" dispatch-plan common denial "${LINE_TEMPLATE}"
	"$1" "${GATE_PROCEDURE}" gate lines
	"$1" "${CONTEXT_PROCEDURE}" lines
	"$1" "${WORKTREE_PROCEDURE}" seat-moved caught-up conflict common lines
	"$1" "${SEAT_RUN_PROCEDURE}" lines
}

# Prints one cksum line per template $2... of skill $1, or a fixed line for
# each one that can't be read.
# shellcheck disable=SC2329 # called by name through each_view_template
fingerprint_templates() {
	template_skill=$1
	shift
	for template in "$@"; do
		cksum "${skills_dir}/${template_skill}/views/${template}.jq" 2>/dev/null ||
			printf '%s views/%s.jq unreadable\n' "${template_skill}" "${template}"
	done
}

# Prints the hook commands and their onFailure for event $1, matcher $2 (""
# any) and script $3, or a fixed line when they can't be read.
fingerprint_hook() {
	printf 'hook %s %s %s\n' "$1" "$2" "$3"
	jq -c --arg event "$1" --arg matcher "$2" --arg needle "$3" "${HOOK_FINGERPRINT_JQ}" "${settings_file}" </dev/null 2>/dev/null ||
		printf 'hook commands unreadable\n'
}

# Prints each language-*/framework-*/standard-*/procedure-* folder name, then one cksum line per
# file in their SKILL.md and references/, sorted. Symlinks are followed: an
# installed plugin is usually a link to its source folder.
fingerprint_plugins() {
	set --
	for plugin_path in "${skills_dir}"/language-* "${skills_dir}"/framework-* \
		"${skills_dir}"/standard-* "${skills_dir}"/procedure-*; do
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

# Records passed check $1 as a Passed item, and counts it.
pass() {
	passed_items="${passed_items}${ITEM_SEPARATOR}$1"
	passed_count=$((passed_count + 1))
}

# Records failed check $1, reason $2 and fix $3 as a Fix item, and counts it.
fail() {
	add_fix_item "$1: $2. Fix: $3"
	failed_count=$((failed_count + 1))
}

add_fix_item() {
	fix_items="${fix_items}${ITEM_SEPARATOR}$1"
}

# Records warned check $1 and reason $2 as a Fix and a Warnings item, and counts it.
warn() {
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

# Checks that each card template $2... of skill $1 (views/<name>.jq) is readable.
# shellcheck disable=SC2329 # called by name through each_view_template
check_card_templates() {
	template_skill=$1
	shift
	for template in "$@"; do
		template_file="${skills_dir}/${template_skill}/views/${template}.jq"
		if [ -f "${template_file}" ] && [ -r "${template_file}" ]; then
			pass "${template_skill} views/${template}.jq"
		else
			fail "${template_skill} views/${template}.jq" "missing or unreadable in ${template_file%/*}" "reinstall ${template_skill} under ${skills_dir}"
		fi
	done
}

# Checks the template the inject hook sends word for word, by the hook's own
# test: a readable regular file inside the procedure-context folder after
# symlinks, holding more than whitespace. The hook refuses without it.
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
			run_tool_need='show.sh, the seat bind and report commit hooks and crucible.sh'
			set_coreutils_fix date /bin
			;;
		git)
			run_tool_need='the report commit hook'\''s commit'
			run_tool_fix='install git (macOS: xcode-select --install; Linux: the distro'\''s git package), then rerun'
			;;
		cmp)
			run_tool_need='the report commit hook'\''s commit check'
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

# Checks that the settings file registers the nine hooks, allows the
# Crucible space and has its Edit allow and events deny rules; a settings
# file jq can't read fails once for all twelve.
check_settings() {
	if ! command -v jq >/dev/null 2>&1; then
		fail 'hooks not checked' 'jq is missing, and settings.json is read only through jq' "${JQ_FIX}"
		return 0
	fi
	if [ ! -e "${settings_file}" ]; then
		hook_entries=''
		each_hook append_hook_entry
		set_space_fix
		set_edit_rule_fix
		set_events_deny_fix
		fail 'hooks not registered' "no settings file at ${settings_file}" "create it with ${hook_entries}; ${space_fix}; ${edit_rule_fix}; and ${events_deny_fix}, then run /hooks or restart"
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
	check_edit_rule
	check_events_deny_rule
}

# Calls $1 once per hook entry with: item name, event, matcher ("" any), script,
# timeout, onFailure ("" not required), async ("rewake": async and
# asyncRewake required; "" not). The one list both the check and its fix text
# are built from.
each_hook() {
	"$1" 'inject hook' PreToolUse Agent "${HOOK_SCRIPT}" "${HOOK_TIMEOUT}" "${HOOK_ON_FAILURE}" ''
	"$1" 'card Stop hook' Stop '' "${SHOW_STOP_SCRIPT}" "${GATE_HOOK_TIMEOUT}" '' ''
	"$1" 'gate question hook' PreToolUse AskUserQuestion "${GATE_QUESTION_SCRIPT}" "${GATE_HOOK_TIMEOUT}" '' ''
	"$1" 'gate answer hook' PostToolUse AskUserQuestion "${GATE_ANSWER_SCRIPT}" "${GATE_HOOK_TIMEOUT}" '' ''
	"$1" 'gate dashboard answer hook' UserPromptSubmit '' "${GATE_ANSWER_SCRIPT}" "${GATE_HOOK_TIMEOUT}" '' ''
	"$1" 'seat bind hook' PostToolUse Agent "${SEAT_BIND_SCRIPT}" "${SEAT_BIND_HOOK_TIMEOUT}" '' ''
	"$1" 'report commit hook' SubagentStop '' "${REPORT_COMMIT_SCRIPT}" "${REPORT_COMMIT_HOOK_TIMEOUT}" '' ''
	"$1" 'block relay hook' SubagentStop '' "${BLOCK_RELAY_SCRIPT}" "${BLOCK_RELAY_HOOK_TIMEOUT}" '' "${HOOK_ASYNC_REWAKE}"
	"$1" 'events guard hook' PreToolUse Bash "${EVENTS_GUARD_SCRIPT}" "${EVENTS_GUARD_HOOK_TIMEOUT}" "${HOOK_ON_FAILURE}" ''
}

# Appends the settings entry for hook $2..$7 (each_hook's arguments) to hook_entries.
# shellcheck disable=SC2329 # called by name through each_hook
append_hook_entry() {
	hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5" "$6" "$7")
	hook_entries="${hook_entries}${hook_entries:+; }${hook_entry}"
}

# Prints the settings entry for event $1, matcher $2 ("" none), script $3,
# timeout $4, onFailure $5 ("" none) and async $6 ("rewake", "" none).
# shellcheck disable=SC2329 # called from each_hook's callbacks, which shellcheck can't trace
hook_entry_text() {
	matcher_text=''
	[ -z "$2" ] || matcher_text=" (matcher $2)"
	on_failure_text=''
	[ -z "$5" ] || on_failure_text=", \"onFailure\": \"$5\""
	async_text=''
	[ -z "${6-}" ] || async_text=', "async": true, "asyncRewake": true'
	printf 'a %s hook%s with command sh "%s/%s", timeout %s%s%s' "$1" "${matcher_text}" "${HOOK_COMMAND_ROOT}" "$3" "$4" "${on_failure_text}" "${async_text}"
}

# Checks one entry: item name $1, event $2, matcher $3 ("" any), script $4,
# timeout $5, onFailure $6 ("" not required), async $7 ("rewake", "" not
# required).
# shellcheck disable=SC2329 # called by name through each_hook
check_hook_entry() {
	where=$2
	[ -z "$3" ] || where="$2 › $3"
	if hook_count=$(jq --arg event "$2" --arg matcher "$3" --arg needle "$4" "${HOOK_COUNT_JQ}" "${settings_file}" </dev/null 2>/dev/null); then
		:
	else
		fail "$1 not checked" "jq could not read the hook entries in ${settings_file}" "check it with jq, then rerun"
		return 0
	fi
	case ${hook_count} in
		'' | *[!0-9]* | 0)
			hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5" "$6" "$7")
			fail "$1 not registered" "no ${where} entry runs ${4##*/}" "add ${hook_entry}, in settings.json, then run /hooks or restart"
			;;
		*)
			# shellcheck disable=SC2310 # it reports its own failure; its status only says whether to go on
			check_on_failure "$@" || return 0
			# shellcheck disable=SC2310 # it reports its own failure; its status only says whether to go on
			check_async_rewake "$@" || return 0
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
		fail "$1 not checked" "jq could not read the hook entries in ${settings_file}" "check it with jq, then rerun"
		return 1
	fi
	case ${blocking_count} in
		'' | *[!0-9]* | 0)
			hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5" "$6" "$7")
			fail "$1 does not block on failure" "the ${where} entry that runs ${4##*/} has no \"onFailure\": \"$6\", so a failing or timed-out hook lets its call through unchecked" "make it ${hook_entry}, in settings.json, then run /hooks or restart"
			return 1
			;;
		*) return 0 ;;
	esac
}

# Fails hook $1..$7 (check_hook_entry's arguments) when async $7 is required
# and no entry running its script is async with asyncRewake; returns 1 then.
# shellcheck disable=SC2329 # called from check_hook_entry, which each_hook calls by name
check_async_rewake() {
	[ -n "$7" ] || return 0
	if rewake_count=$(jq --arg event "$2" --arg matcher "$3" --arg needle "$4" \
		"${HOOK_ASYNC_REWAKE_COUNT_JQ}" "${settings_file}" </dev/null 2>/dev/null); then
		:
	else
		fail "$1 not checked" "jq could not read the hook entries in ${settings_file}" "check it with jq, then rerun"
		return 1
	fi
	case ${rewake_count} in
		'' | *[!0-9]* | 0)
			hook_entry=$(hook_entry_text "$2" "$3" "$4" "$5" "$6" "$7")
			fail "$1 does not wake the main thread" "the $2 entry that runs ${4##*/} is not \"async\": true with \"asyncRewake\": true, so a developer that handed back never hears why its stop was blocked" "make it ${hook_entry}, in settings.json, then run /hooks or restart"
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

# Checks that permissions.allow holds Edit(//<space>/**), or the rule for a
# folder the space lies inside, so an agent writes its report draft under
# <space>/efforts/<effort>/drafts/agents/<seat>/ without a prompt.
check_edit_rule() {
	if [ -n "${crucible_home_problem}" ]; then
		fail 'Crucible space Edit rule not checked' "${crucible_home_problem}" 'fix what it names (CRUCIBLE_HOME, or the crucible skill), then rerun'
		return 0
	fi
	if edit_rule_count=$(jq --arg dir "${crucible_home}" "${EDIT_RULE_COUNT_JQ}" "${settings_file}" </dev/null 2>/dev/null); then
		:
	else
		fail 'Crucible space Edit rule not checked' "jq could not read permissions.allow in ${settings_file}" "check it with jq, then rerun"
		return 0
	fi
	case ${edit_rule_count} in
		'' | *[!0-9]* | 0)
			set_edit_rule_fix
			fail 'Crucible space Edit rule missing' "permissions.allow in ${settings_file} has no Edit(//<folder>/**) rule whose folder is ${crucible_home} or a folder it lies inside" "${edit_rule_fix}, then restart Claude Code"
			;;
		*) pass "Crucible space Edit rule allowed (Edit(/${crucible_home%/}/**) in permissions.allow)" ;;
	esac
}

# Checks that permissions.deny holds Edit(//<space>/efforts/*/events/**), so
# no Write or Edit call writes an event the Edit allow rule would let through.
check_events_deny_rule() {
	if [ -n "${crucible_home_problem}" ]; then
		fail 'Crucible events Edit deny rule not checked' "${crucible_home_problem}" 'fix what it names (CRUCIBLE_HOME, or the crucible skill), then rerun'
		return 0
	fi
	if events_deny_count=$(jq --arg dir "${crucible_home}" "${EVENTS_DENY_COUNT_JQ}" "${settings_file}" </dev/null 2>/dev/null); then
		:
	else
		fail 'Crucible events Edit deny rule not checked' "jq could not read permissions.deny in ${settings_file}" "check it with jq, then rerun"
		return 0
	fi
	case ${events_deny_count} in
		'' | *[!0-9]* | 0)
			set_events_deny_fix
			fail 'Crucible events Edit deny rule missing' "permissions.deny in ${settings_file} has no Edit(//<space>/efforts/*/events/**) rule for the space ${crucible_home}" "${events_deny_fix}, then restart Claude Code"
			;;
		*) pass "Crucible events Edit rule denied (Edit(/${crucible_home%/}/efforts/*/events/**) in permissions.deny)" ;;
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

# Sets edit_rule_fix to the fix that adds the space's Edit rule: the JSON to
# merge into settings.json, built by jq so the path is escaped.
set_edit_rule_fix() {
	if edit_rule_fragment=$(jq -cn --arg dir "${crucible_home}" "${EDIT_RULE_FRAGMENT_JQ}" </dev/null 2>/dev/null); then
		edit_rule_fix="merge ${edit_rule_fragment} into settings.json (append the rule when allow exists)"
	else
		edit_rule_fix="add Edit(/${crucible_home%/}/**) to permissions.allow in settings.json"
	fi
}

# Sets events_deny_fix to the fix that adds the space's events deny rule: the
# JSON to merge into settings.json, built by jq so the path is escaped.
set_events_deny_fix() {
	if events_deny_fragment=$(jq -cn --arg dir "${crucible_home}" "${EVENTS_DENY_FRAGMENT_JQ}" </dev/null 2>/dev/null); then
		events_deny_fix="merge ${events_deny_fragment} into settings.json (append the rule when deny exists)"
	else
		events_deny_fix="add Edit(/${crucible_home%/}/efforts/*/events/**) to permissions.deny in settings.json"
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
		1) warn 'no plugins installed' 'every code part stops: it has no installed plugin' ;;
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

# Sets language_count, framework_count, standard_count, procedure_count and
# reports (the non-plugin lines) from listing.
split_listing() {
	language_count=0
	framework_count=0
	standard_count=0
	procedure_count=0
	reports=''
	tab=$(printf '\t')
	while IFS= read -r line; do
		case ${line} in
			'') ;;
			"language${tab}"*) language_count=$((language_count + 1)) ;;
			"framework${tab}"*) framework_count=$((framework_count + 1)) ;;
			"standard${tab}"*) standard_count=$((standard_count + 1)) ;;
			"procedure${tab}"*) procedure_count=$((procedure_count + 1)) ;;
			*) reports="${reports}${line}${NL}" ;;
		esac
	done <<EOF
${listing}
EOF
}

report_counts() {
	plugin_count=$((language_count + framework_count + standard_count + procedure_count))
	if [ -n "${reports}" ] || [ "${plugin_count}" -eq 0 ]; then
		fail 'plugins not listed' 'list-plugins.sh exited 0 with an unexpected listing' "rerun it with --max-lines 0 and fix what it reports"
		add_reports
		return 0
	fi
	kind_counts=''
	add_kind_count "${language_count}" language
	add_kind_count "${framework_count}" framework
	add_kind_count "${standard_count}" standard
	add_kind_count "${procedure_count}" procedure
	plugins_text=$(counted "${plugin_count}" plugin)
	pass "${plugins_text} installed: ${kind_counts}"
}

# Prints "<count> <noun>", the noun plural unless the count is 1.
counted() {
	if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# Appends "<count> <kind>" to kind_counts, joined by ", "; a kind with none is left out.
add_kind_count() {
	[ "$1" -gt 0 ] || return 0
	kind_counts="${kind_counts:+${kind_counts}, }$(counted "$1" "$2")"
}

# Adds each report line, its tabs as spaces and other control characters
# dropped, so a line from list-plugins.sh can't forge a Fix item: joined by
# "; " to the last Fix item.
add_reports() {
	[ -n "${reports}" ] || return 0
	clean_reports=$(printf '%s' "${reports}" | tr '\011' ' ' | tr -d '\001-\010\013-\037\177')
	reported=''
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
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

# Fails one check per base tool missing from PATH, then ends the run with the
# card and exit 1, since the checks below would misreport without them.
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

# Prints the card of a full run, then the --line lines.
print_result() {
	print_card "$((passed_count + failed_count + warning_count))" ''
}

# Prints the card of the cached pass, then the --line lines.
print_cached_pass() {
	print_card "${cached_checks}" "${cached_time}"
}

# Prints the card for total $1 checks, cached at time $2 ("" for a full run),
# and each --line line, through show.sh; without jq, which show.sh needs,
# the plain result instead. Exits 5 when a card can't be printed.
print_card() {
	if ! command -v jq >/dev/null 2>&1; then
		print_plain_result "$1"
		return 0
	fi
	card_data=$(jq -cn --arg failed "${failed_count}" --arg total "$1" \
		--arg fixes "${fix_items}" --arg warnings "${warning_items}" \
		--arg passed "${passed_items}" --arg verbose "${verbose}" \
		--arg since "$2" --arg note "${cache_note}" "${CARD_DATA_JQ}" </dev/null) ||
		install_fault "jq could not build the card's data; expected jq ${JQ_MIN_MAJOR}.${JQ_MIN_MINOR}+; try jq --version, then rerun"
	load_card_printer
	# A closed stdout exits 4 before show.sh records a card nobody can see.
	{ true 3>&1; } 2>/dev/null || exit 4
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_card "${show_script}" "${views_dir}" "${CARD_NAME}" '' "${card_data}" || card_fault "views/${CARD_NAME}.jq"
	for line_name in ${line_names}; do
		# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
		hv_show_line "${show_script}" "${views_dir}" "${line_name}" '' || card_fault "${line_name} of views/${LINE_TEMPLATE}.jq"
	done
}

# Sets views_dir and show_script and sources human-view's card printer lib,
# which checks that show.sh and the templates are in place; exits 5 when one
# of them is missing.
load_card_printer() {
	# The logical path, links kept as named: show.sh names the card's skill after it.
	own_dir=$(script_dir)
	views_dir=$(CDPATH='' cd -- "${own_dir}/../../views" 2>/dev/null && pwd) ||
		install_fault "this skill's views folder could not be entered; expected views/ beside scripts/; reinstall ${PROCEDURE}"
	card_printer="${skills_dir}/${SHOW_SCRIPTS}/${CARD_PRINTER_LIB}"
	[ -f "${card_printer}" ] && [ -r "${card_printer}" ] ||
		install_fault "card printer lib missing; expected ${card_printer}; install the ${RENDER_LIB} skill"
	# shellcheck source=../../../../../../../../framework/core/engine/human-view/scripts/lib/render.sh
	. "${card_printer}"
	set -- "${CARD_NAME}"
	[ -z "${line_names}" ] || set -- "$@" "${LINE_TEMPLATE}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${skills_dir}/${SHOW_SCRIPTS}" "${views_dir}" "$@" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
}

# Prints this script's folder: the path it was run by, links kept.
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Exits 5 after show.sh failed printing $1, its stderr already above.
card_fault() {
	install_fault "${hv_render_problem}; expected $1 printed; try reinstalling ${PROCEDURE} and ${RENDER_LIB}"
}

install_fault() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
	exit 5
}

# Prints the result with no jq, which show.sh needs: the counts of total $1
# checks, then one "- " line per Fix item, then the cache note. The only
# result not printed by show.sh, and no --line line goes with it.
print_plain_result() {
	printf 'Install check: %s of %s checks failed; jq is missing, so this list is plain text.\n' "${failed_count}" "$1"
	plain_items=${fix_items#"${ITEM_SEPARATOR}"}
	while [ -n "${plain_items}" ]; do
		printf -- '- %s\n' "${plain_items%%"${ITEM_SEPARATOR}"*}"
		case ${plain_items} in
			*"${ITEM_SEPARATOR}"*) plain_items=${plain_items#*"${ITEM_SEPARATOR}"} ;;
			*) plain_items='' ;;
		esac
	done
	[ -z "${cache_note}" ] || printf '(result not cached: %s)\n' "${cache_note}"
}

passed_count=0
failed_count=0
warning_count=0
passed_items=''
fix_items=''
warning_items=''
cache_note=''
marker_tmp=''
trap '[ -z "${marker_tmp}" ] || rm -f "${marker_tmp}"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
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
check_script "${SEAT_RUN_PROCEDURE}" seats/seats.sh
check_script "${SEAT_RUN_PROCEDURE}" seats/iteration.sh
check_script "${WORKTREE_PROCEDURE}" seats/seat-move.sh
check_script "${WORKTREE_PROCEDURE}" worktree/worktree-move.sh
check_script "${WORKTREE_PROCEDURE}" merge/catch-up.sh
check_script "${SEAT_RUN_PROCEDURE}" hooks/seat-bind-hook.sh
check_script "${SEAT_RUN_PROCEDURE}" hooks/report-commit-hook.sh
check_script "${SEAT_RUN_PROCEDURE}" hooks/block-relay-hook.sh
check_lib_file "${CARDS_LIB}" "${skills_dir}/${WORKTREE_PROCEDURE}/scripts" "${WORKTREE_PROCEDURE}"
check_lib_file "${CARDS_LIB}" "${skills_dir}/${SEAT_RUN_PROCEDURE}/scripts" "${SEAT_RUN_PROCEDURE}"
check_script "${GATE_PROCEDURE}" open-gate.sh
check_script "${RENDER_LIB}" show.sh
check_script "${RENDER_LIB}" show-stop-hook.sh
check_lib_file "${OWED_SH_LIB}" "${skills_dir}/${SHOW_SCRIPTS}" "${RENDER_LIB}"
check_lib_file "${OWED_JQ_LIB}" "${skills_dir}/${SHOW_SCRIPTS}" "${RENDER_LIB}"
check_lib_file "${CARD_PRINTER_LIB}" "${skills_dir}/${SHOW_SCRIPTS}" "${RENDER_LIB}"
check_script "${GATE_PROCEDURE}" gate-question-hook.sh
check_script "${GATE_PROCEDURE}" gate-answer-hook.sh
check_runnable "${CRUCIBLE_SKILL}" "${CRUCIBLE_SCRIPT}"
check_script "${CRUCIBLE_SKILL}" "${EVENTS_SCRIPT}"
check_script "${CRUCIBLE_SKILL}" "${EVENTS_GUARD_HOOK}"
check_lib_file "${CRUCIBLE_SPACE_LIB}" "${crucible_scripts_dir}" "${CRUCIBLE_SKILL}"
check_lib_file "${PRUNE_MODULE}" "${crucible_scripts_dir}" "${CRUCIBLE_SKILL}"
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
check_lib_file "${VIEW_MODULE}" "${skills_dir}" "${RENDER_LIB}"
check_lib_file "${TITLE_MODULE}" "${skills_dir}" "${RENDER_LIB}"
check_lib_file "${LINE_MODULE}" "${skills_dir}" "${RENDER_LIB}"
check_lib_file "${GATE_MODULE}" "${skills_dir}" "${RENDER_LIB}"
each_view_template check_card_templates
check_jq
check_run_tools
check_settings
check_plugins
record_result
print_result
if [ "${failed_count}" -eq 0 ]; then exit 0; fi
exit 1
