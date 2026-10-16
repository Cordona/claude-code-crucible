#!/usr/bin/env bash
#
# lint.sh — read-only mechanical lint of one skill or one agent at a time,
# implementing the per-artifact items of references/shared/lint-spec.md.
# Collection items (LNT-08, LNT-35, LNT-42, LNT-46, LNT-65 and LNT-59's
# uniqueness clause) are not run here; a reviewer hand-checks the target's
# own part of each (lint-spec.md, Scope).
#
# Writes nothing but stdout, stderr and one private temp dir removed on exit.
# Never executes a script it lints: LNT-27's usage check is static.
#
# Waivers come only from the file named by --waivers, which applies to the
# single target being linted; without it no SHOULD/MAY FAIL is waived.
#
# Dependencies (also listed by --help):
#   required    awk, basename, cat, cut, dirname, find, grep, head, mkdir,
#               mktemp, rm, sed, sort (with -z: GNU or BSD), tr. Checked at
#               start-up; a missing one exits 5 naming it.
#   required without --root   git, to find the default root; a missing git
#               exits 5 naming it.
#   rulebook    references/agents/07-agent-safety.md (canonical blocks and
#               quote-safely line) and references/shared/lint-spec.md (item
#               levels), under --rulebook; missing or unparsable exits 4.
#   optional    jq (LNT-38, LNT-39, LNT-51 json, LNT-52, LNT-54, LNT-56,
#               LNT-57), shellcheck (LNT-29, LNT-51 shell), ruby (LNT-03 and
#               LNT-59 YAML cross-check, LNT-51 yaml), python3 (LNT-51
#               python). A missing one skips its items with WARN "skipped:
#               <tool> missing" (the YAML cross-check only prints INFO); a
#               skipped MUST item exits 3.
#
# Exit codes: see --help.
#
set -Eeuo pipefail

LC_ALL=C
export LC_ALL
unset CDPATH

PROG=${0##*/}

# An unexpected failure exits 5, never 1: 1 means a MUST FAIL.
# shellcheck disable=SC2329  # invoked indirectly via the ERR trap
internal_error() {
	# A failing command substitution reports once, from the parent shell,
	# which names the whole command.
	(( BASH_SUBSHELL == 0 )) || exit 5
	printf '%s: internal error at line %s: %s\n' "${PROG}" "$1" "$2" >&2
	printf '%s: expected that command to succeed on a readable skill dir or agent file. Try: re-run on that one target with "bash -x %s <target>" to see the failing step, and check that TMPDIR (%s) is writable.\n' \
		"${PROG}" "$0" "${TMPDIR:-/tmp}" >&2
	exit 5
}
trap 'internal_error "${LINENO}" "${BASH_COMMAND}"' ERR

readonly SKILL_KEYS="name description when_to_use argument-hint arguments disable-model-invocation user-invocable allowed-tools disallowed-tools model effort context agent background hooks paths shell license compatibility metadata"
readonly AGENT_ONLY_KEYS="tools disallowedTools skills maxTurns permissionMode mcpServers version"
readonly SKILL_BOOL_KEYS="disable-model-invocation user-invocable background"
readonly SKILL_REQUIRED="name description"
readonly AGENT_KEYS="name description tools disallowedTools model permissionMode maxTurns skills mcpServers hooks memory background omitClaudeMd effort isolation color initialPrompt experimental"
readonly AGENT_REQUIRED="name description tools model effort maxTurns"
readonly HOUSE_PREFIXES="flow- procedure- standard- review- build- harness- code-development- code-review- tech-"
readonly GENERIC_WORDS="helper utils tools documents data files"
readonly GATE_EVENTS="PreToolUse UserPromptSubmit UserPromptExpansion Stop SubagentStop"
readonly REQUIRED_TOOLS="awk basename cat cut dirname find grep head mkdir mktemp rm sed sort tr"

usage() {
	cat <<EOF
usage: ${PROG} [options] (--all | TARGET...)

Lint one skill or one agent at a time against the per-artifact items of
references/shared/lint-spec.md. Read-only.

  TARGET              a skill dir, its SKILL.md, or an agent .md file;
                      each target is linted on its own
  --all               lint every skill dir and agent file under the roots,
                      one by one (no collection aggregates)
  --report-only       print every finding but exit 0 for findings (a MUST
                      FAIL or a skipped MUST); usage, rulebook and internal
                      errors keep their exit codes
  --root DIR          where skill dirs and agent files live (repeatable);
                      default: git top-level of the rulebook dir
  --rulebook DIR      standard-harness-authoring root; default: the dir
                      above this script
  --claude-home DIR   default: \$HOME/.claude (skills/ symlinks give
                      deployed names and resolve preloads)
  --waivers FILE      waive SHOULD/MAY items for the one TARGET: lines
                      "- <ID>: <reason> (owner)" (the "- " is optional;
                      other lines are ignored). Not allowed with --all or
                      several targets. Without it nothing is waived
  --max-lines N       print at most N finding lines per target (default
                      200; 0 = no cap); SUMMARY still counts every finding
  -h, --help          show this help

Output: LNT-NN PASS|FAIL|WARN|INFO <file>:<line> <message>, sorted by file
then item; a SHOULD/MAY failure prints FAIL with a "SHOULD:"/"MAY:" prefix
and never fails the run; a waived one prints WARN "waived: <reason>"; a
skipped item prints WARN "skipped: <tool> missing". A target cut by
--max-lines ends with "TRUNCATED INFO <target> showing <N> of <M> lines".
Last line:
SUMMARY must_fail=<n> should_fail=<n> warn=<n> skipped_must=<n> files=<n>

Dependencies:
  required   awk basename cat cut dirname find grep head mkdir mktemp rm sed
             sort (with -z) tr; git when no --root is given
  optional   jq, shellcheck, ruby, python3 (their items are skipped when the
             tool is missing)
  rulebook   under --rulebook: references/agents/07-agent-safety.md
             (canonical blocks and quote-safely line) and
             references/shared/lint-spec.md (item levels)

Exit codes:
  0  no MUST FAIL (always 0 for findings under --report-only)
  1  at least one MUST FAIL
  2  usage error (bad option, no target, unreadable target, no root,
     unreadable --waivers file, --waivers with more than one target)
  3  no MUST FAIL, but a MUST item was skipped for a missing optional tool
  4  rulebook files not found, or their canonical text or item levels
     missing
  5  internal error, or a required tool is missing
  130/143  interrupted (INT/TERM)
EOF
}

main() {
	parse_args "$@"
	check_required_tools
	load_waivers
	resolve_rulebook
	load_canonical_blocks
	load_item_levels
	resolve_roots
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lint.XXXXXX") || internal_failure "mktemp -d in ${TMPDIR:-/tmp}" "a writable temp dir" "setting TMPDIR to a writable directory"
	collect_targets
	local target
	for target in "${TARGETS[@]}"; do
		lint_target "${target}"
	done
	printf 'SUMMARY must_fail=%d should_fail=%d warn=%d skipped_must=%d files=%d\n' \
		"${MUST_FAIL}" "${SHOULD_FAIL}" "${WARN_COUNT}" "${SKIPPED_MUST}" "${#TARGETS[@]}"
	if (( OPT_REPORT_ONLY )); then exit 0; fi
	if (( MUST_FAIL > 0 )); then exit 1; fi
	if (( SKIPPED_MUST > 0 )); then exit 3; fi
	exit 0
}

# ---------------------------------------------------------------- setup

error() { printf '%s: error: %s\n' "${PROG}" "$*" >&2; }
die() { local code=$1; shift; error "$*"; exit "${code}"; }
usage_error() { usage >&2; die 2 "$*"; }

# internal_failure WHAT EXPECTED TRY — a step that should never fail did.
internal_failure() { die 5 "internal error: $1 failed; expected $2; try $3"; }

# awk_failed WHAT — an awk pass failed; awk's own message is already on stderr.
awk_failed() { internal_failure "awk $1" "a readable text file and a POSIX awk" "re-running on that one target and reading awk's message above"; }

sort_failed() { internal_failure "sort" "a sort that accepts -z and -u (GNU or BSD)" "putting GNU or BSD sort first on PATH"; }

skill_find_failed() { internal_failure "find in ${SKILL_DIR}" "a readable skill dir" "fixing the permissions find names above"; }

check_required_tools() {
	local tool
	for tool in ${REQUIRED_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 || \
			die 5 "required tool missing: ${tool}. It ships with every macOS and Linux base system; install your OS's base utilities (Linux: coreutils, findutils, grep, sed, gawk or mawk) or fix PATH."
	done
	return 0
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
	if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then rm -rf -- "${TMP_DIR}"; fi
}

OPT_REPORT_ONLY=0
OPT_ALL=0
OPT_RULEBOOK=""
OPT_CLAUDE_HOME=""
OPT_WAIVERS=""
# 200: one target's findings stay readable in a single Read and short in a caller's context; SUMMARY still counts every finding.
OPT_MAX_LINES=200
OPT_ROOTS=()
ARGS=()

parse_args() {
	[[ $# -gt 0 ]] || { usage >&2; exit 2; }
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)     usage; exit 0 ;;
			--all)         OPT_ALL=1 ;;
			--report-only) OPT_REPORT_ONLY=1 ;;
			--root|--rulebook|--claude-home|--waivers|--max-lines)
				[[ -n "${2:-}" ]] || usage_error "option $1 requires an argument"
				case "$1" in
					--root)        OPT_ROOTS+=("$2") ;;
					--rulebook)    OPT_RULEBOOK=$2 ;;
					--claude-home) OPT_CLAUDE_HOME=$2 ;;
					--waivers)     OPT_WAIVERS=$2 ;;
					--max-lines)   OPT_MAX_LINES=$2 ;;
					*) ;;
				esac
				shift ;;
			--)            shift; ARGS+=("$@"); break ;;
			-*)            usage_error "unknown option: $1" ;;
			*)             ARGS+=("$1") ;;
		esac
		shift
	done
	if (( OPT_ALL )) && [[ ${#ARGS[@]} -gt 0 ]]; then usage_error "--all takes no TARGET"; fi
	if (( ! OPT_ALL )) && [[ ${#ARGS[@]} -eq 0 ]]; then usage_error "give --all or at least one TARGET"; fi
	if [[ -n "${OPT_WAIVERS}" ]] && (( OPT_ALL || ${#ARGS[@]} > 1 )); then
		usage_error "--waivers applies to one TARGET; it cannot be combined with --all or several targets"
	fi
	# At most 9 digits keeps N below 2^31, so every awk's printf %d in
	# flush_artifact prints it exactly.
	[[ "${OPT_MAX_LINES}" =~ ^(0|[1-9][0-9]{0,8})$ ]] || usage_error "--max-lines needs a whole number 0-999999999, got: ${OPT_MAX_LINES}"
	return 0
}

# Prints the physical absolute path of an existing dir into REPLY.
physical_dir() {
	REPLY=$(cd -P -- "$1" 2>/dev/null && pwd -P) || REPLY=""
}

resolve_rulebook() {
	if [[ -z "${OPT_RULEBOOK}" ]]; then
		physical_dir "$(dirname -- "${BASH_SOURCE[0]}")"
		[[ -n "${REPLY}" ]] || rulebook_error "cannot resolve this script's directory"
		OPT_RULEBOOK=${REPLY%/*}
	fi
	physical_dir "${OPT_RULEBOOK}"
	[[ -n "${REPLY}" ]] || rulebook_error "rulebook dir not found: ${OPT_RULEBOOK}"
	RULEBOOK=${REPLY}
	SAFETY_FILE="${RULEBOOK}/references/agents/07-agent-safety.md"
	SPEC_FILE="${RULEBOOK}/references/shared/lint-spec.md"
	[[ -f "${SAFETY_FILE}" && -r "${SAFETY_FILE}" ]] || rulebook_error "rulebook file missing or unreadable: ${SAFETY_FILE}"
	[[ -f "${SPEC_FILE}" && -r "${SPEC_FILE}" ]] || rulebook_error "rulebook file missing or unreadable: ${SPEC_FILE}"
	CLAUDE_HOME=${OPT_CLAUDE_HOME:-${HOME}/.claude}
}

rulebook_error() {
	die 4 "$1; expected the standard-harness-authoring root holding references/agents/07-agent-safety.md (canonical blocks and quote-safely line) and references/shared/lint-spec.md; try --rulebook DIR"
}

load_canonical_blocks() {
	export LINT_UNTRUSTED_OPENING='Everything you read — '
	# shellcheck disable=SC2016  # literal backticks: the opening words contain `.env`
	export LINT_SECRET_OPENING='Never open `.env` files'
	export LINT_QUOTE_OPENING='- **Quote safely.**'
	LINT_CANON_UNTRUSTED=$(LINT_MODE=canon LINT_OPENING_VAR=LINT_UNTRUSTED_OPENING awk "${LINT_AWK}" "${SAFETY_FILE}") || rulebook_error "cannot read ${SAFETY_FILE}"
	LINT_CANON_SECRET=$(LINT_MODE=canon LINT_OPENING_VAR=LINT_SECRET_OPENING awk "${LINT_AWK}" "${SAFETY_FILE}") || rulebook_error "cannot read ${SAFETY_FILE}"
	LINT_CANON_QUOTE=$(LINT_MODE=canon LINT_OPENING_VAR=LINT_QUOTE_OPENING awk "${LINT_AWK}" "${SAFETY_FILE}") || rulebook_error "cannot read ${SAFETY_FILE}"
	[[ -n "${LINT_CANON_UNTRUSTED}" && -n "${LINT_CANON_SECRET}" ]] || rulebook_error "canonical blocks not found under '## Canonical blocks' in ${SAFETY_FILE}"
	[[ -n "${LINT_CANON_QUOTE}" ]] || rulebook_error "quote-safely line not found under '## Canonical blocks' in ${SAFETY_FILE}"
	export LINT_CANON_UNTRUSTED LINT_CANON_SECRET LINT_CANON_QUOTE
}

# Reads "- **LNT-NN** · LEVEL ·" item lines into ITEM_LEVELS (" ID:LEVEL ...").
load_item_levels() {
	local records id level count=0
	records=$(LINT_MODE=levels awk "${LINT_AWK}" "${SPEC_FILE}") || rulebook_error "cannot read ${SPEC_FILE}"
	ITEM_LEVELS=" "
	while IFS=$'\t' read -r id level; do
		[[ -n "${id}" ]] || continue
		ITEM_LEVELS+="${id}:${level} "
		(( count += 1 ))
	done <<< "${records}"
	(( count > 0 )) || rulebook_error "no item lines \"- **LNT-NN** · LEVEL ·\" in ${SPEC_FILE}"
}

resolve_roots() {
	local root
	ROOTS=()
	if [[ ${#OPT_ROOTS[@]} -eq 0 ]]; then
		command -v git >/dev/null 2>&1 || \
			die 5 "required tool missing: git (finds the default root when no --root is given). Install git (macOS: xcode-select --install; Linux: your package manager) or pass --root DIR."
		root=$(git -C "${RULEBOOK}" rev-parse --show-toplevel 2>/dev/null) || root=""
		[[ -n "${root}" ]] && OPT_ROOTS+=("${root}")
		[[ ${#OPT_ROOTS[@]} -gt 0 ]] || usage_error "no --root given and the rulebook dir is not in a git work tree"
	fi
	for root in "${OPT_ROOTS[@]}"; do
		physical_dir "${root}"
		[[ -n "${REPLY}" ]] || usage_error "root is not a directory: ${root}"
		ROOTS+=("${REPLY}")
	done
}

collect_targets() {
	local arg newline=$'\n'
	TARGETS=()
	if (( OPT_ALL )); then
		discover_artifacts
		TARGETS=(${ALL_SKILL_DIRS[@]+"${ALL_SKILL_DIRS[@]}"} ${ALL_AGENT_FILES[@]+"${ALL_AGENT_FILES[@]}"})
		[[ ${#TARGETS[@]} -gt 0 ]] || usage_error "no skill dir or agent file found under the roots"
		return 0
	fi
	for arg in "${ARGS[@]}"; do
		[[ "${arg}" != *"${newline}"* ]] || usage_error "target path contains a newline"
		if [[ -d "${arg}" ]]; then
			physical_dir "${arg}"; TARGETS+=("${REPLY}")
		elif [[ -f "${arg}" && -r "${arg}" && "${arg}" == *.md ]]; then
			physical_dir "$(dirname -- "${arg}")"
			if [[ "${arg##*/}" == SKILL.md ]]; then TARGETS+=("${REPLY}"); else TARGETS+=("${REPLY}/${arg##*/}"); fi
		else
			usage_error "target is not a skill dir, a SKILL.md or a readable agent .md file: ${arg}"
		fi
	done
}

# ------------------------------------------------------- collection index
# Discovery and indexes are built once per run and only when an item needs
# them; they are read-only inputs to single-artifact judgements.

DISCOVERED=0
ALL_SKILL_DIRS=()
ALL_AGENT_FILES=()
ALL_SCHEMAS=()

discover_artifacts() {
	if (( DISCOVERED )); then return 0; fi
	DISCOVERED=1
	local root path first skill_dir inside candidates=()
	for root in "${ROOTS[@]}"; do
		find "${root}" \( -type d \( -name '.?*' -o -name node_modules \) \) -prune -o \
			-type f \( -name SKILL.md -o -name '*.schema.json' -o \( -path '*/agents/*' -name '*.md' \) \) -print0 \
			> "${TMP_DIR}/found" || internal_failure "find under ${root}" "every dir under the root to be readable" "fixing the permissions find names above, or a narrower --root"
		sort -z "${TMP_DIR}/found" > "${TMP_DIR}/found.sorted" || sort_failed
		while IFS= read -r -d '' path; do
			case "${path}" in
				*/SKILL.md)       ALL_SKILL_DIRS+=("${path%/SKILL.md}") ;;
				*.schema.json)    ALL_SCHEMAS+=("${path}") ;;
				*/agents/*.md)    candidates+=("${path}") ;;
				*) ;;
			esac
		done < "${TMP_DIR}/found.sorted"
	done
	# A skill dir named `skill` sits in a container that also holds its tests
	# and fixtures; the container counts as the skill dir for this exclusion.
	for path in ${candidates[@]+"${candidates[@]}"}; do
		inside=0
		for skill_dir in ${ALL_SKILL_DIRS[@]+"${ALL_SKILL_DIRS[@]}"}; do
			[[ "${skill_dir##*/}" == skill ]] && skill_dir=${skill_dir%/*}
			if [[ "${path}" == "${skill_dir}/"* ]]; then inside=1; break; fi
		done
		(( inside )) && continue
		first=""
		IFS= read -r first < "${path}" || true
		[[ "${first%$'\r'}" == "---" ]] && ALL_AGENT_FILES+=("${path}")
	done
	return 0
}

SKILL_INDEX_BUILT=0
IDX_NAME=()
IDX_DIR=()

# name -> physical skill dir; ~/.claude/skills entries first, then repo dirs
# under their deployed-name rule (Terms: dir basename, or parent of `skill`).
build_skill_index() {
	if (( SKILL_INDEX_BUILT )); then return 0; fi
	SKILL_INDEX_BUILT=1
	discover_artifacts
	local entry dir known i
	for entry in "${CLAUDE_HOME}"/skills/*; do
		[[ -f "${entry}/SKILL.md" ]] || continue
		physical_dir "${entry}"
		IDX_NAME+=("${entry##*/}"); IDX_DIR+=("${REPLY}")
	done
	for dir in ${ALL_SKILL_DIRS[@]+"${ALL_SKILL_DIRS[@]}"}; do
		known=0
		for (( i = 0; i < ${#IDX_DIR[@]}; i++ )); do
			if [[ "${IDX_DIR[i]}" == "${dir}" ]]; then known=1; break; fi
		done
		(( known )) && continue
		repo_skill_name "${dir}"
		IDX_NAME+=("${REPLY}"); IDX_DIR+=("${dir}")
	done
	return 0
}

repo_skill_name() {
	local dir=$1 base=${1##*/}
	if [[ "${base}" == skill ]]; then dir=${dir%/*}; base=${dir##*/}; fi
	# A plugin's folder has no prefix; it deploys as tech-<folder> or standard-<folder>.
	if [[ "${dir%/*}" == */plugins/tech ]]; then base="tech-${base}"; fi
	if [[ "${dir%/*}" == */plugins/standards ]]; then base="standard-${base}"; fi
	# The plugin loader lives at plugins/load and deploys as load-plugin.
	if [[ "${dir}" == */plugins/load ]]; then base="load-plugin"; fi
	REPLY=${base}
}

# Sets REPLY to the dir of the skill named $1, or "".
resolve_skill_name() {
	build_skill_index
	local i
	REPLY=""
	for (( i = 0; i < ${#IDX_NAME[@]}; i++ )); do
		if [[ "${IDX_NAME[i]}" == "$1" ]]; then REPLY=${IDX_DIR[i]}; return 0; fi
	done
	return 0
}

# Sets REPLY to the deployed name of skill dir $1 and DEPLOYED_FROM to its source.
deployed_name() {
	build_skill_index
	local i
	for (( i = 0; i < ${#IDX_DIR[@]}; i++ )); do
		if [[ "${IDX_DIR[i]}" == "$1" && -e "${CLAUDE_HOME}/skills/${IDX_NAME[i]}" ]]; then
			REPLY=${IDX_NAME[i]}; DEPLOYED_FROM="symlink in ${CLAUDE_HOME}/skills"; return 0
		fi
	done
	repo_skill_name "$1"
	DEPLOYED_FROM="dir name (not deployed)"
}

PRELOADS_BUILT=0
PRELOADED_NAMES=" "

build_preload_index() {
	if (( PRELOADS_BUILT )); then return 0; fi
	PRELOADS_BUILT=1
	discover_artifacts
	[[ ${#ALL_AGENT_FILES[@]} -gt 0 ]] || return 0
	local records typ file name
	records=$(LINT_MODE=preloads awk "${LINT_AWK}" "${ALL_AGENT_FILES[@]}") || awk_failed "building the preload index from the agent files"
	while IFS=$'\t' read -r typ file name; do
		[[ "${typ}" == A && -n "${name}" ]] && PRELOADED_NAMES+="${name} "
	done <<< "${records}"
	return 0
}

# ---------------------------------------------------------------- emitting

MUST_FAIL=0
SHOULD_FAIL=0
WARN_COUNT=0
SKIPPED_MUST=0
OUT_BUF=""
OUT_SEQ=0
SEEN=" "
ADVISORY_WARNS=" "
UNLEVELLED=" "
STRIP=""
WAIVER_IDS=()
WAIVER_REASONS=()

# Sets REPLY to the lint-spec.md level of item $1; an unlisted ID is MUST.
item_level() {
	if [[ "${ITEM_LEVELS}" == *" $1:"* ]]; then
		REPLY=${ITEM_LEVELS#*" $1:"}; REPLY=${REPLY%% *}
		return 0
	fi
	if [[ "${UNLEVELLED}" != *" $1 "* ]]; then
		UNLEVELLED+="$1 "
		printf '%s: warning: %s has no level in lint-spec.md; treated as MUST\n' "${PROG}" "$1" >&2
	fi
	REPLY=MUST
}

# emit ID STATUS FILE LINE MESSAGE — STATUS is PASS|FAIL|WARN|INFO|SKIP.
emit() {
	local id=$1 status=$2 file=$3 line=$4 msg=$5 level i marks_seen=1
	item_level "${id}"; level=${REPLY}
	file=${file#"${STRIP}"}
	msg=${msg//$'\t'/ }; msg=${msg//$'\n'/ }
	case "${status}" in
		FAIL)
			if [[ "${level}" == MUST ]]; then
				(( MUST_FAIL += 1 ))
			else
				for (( i = 0; i < ${#WAIVER_IDS[@]}; i++ )); do
					if [[ "${WAIVER_IDS[i]}" == "${id}" ]]; then
						status=WARN; msg="waived: ${WAIVER_REASONS[i]} (owner) — ${msg}"; break
					fi
				done
				if [[ "${status}" == FAIL ]]; then msg="${level}: ${msg}"; (( SHOULD_FAIL += 1 )); else (( WARN_COUNT += 1 )); fi
			fi ;;
		SKIP)
			status=WARN; (( WARN_COUNT += 1 ))
			[[ "${level}" == MUST ]] && (( SKIPPED_MUST += 1 )) ;;
		WARN) (( WARN_COUNT += 1 )); marks_seen=0; ADVISORY_WARNS+="${id} " ;;
		INFO) marks_seen=0 ;;
		*) ;;
	esac
	if (( marks_seen )); then SEEN+="${id} "; fi
	(( OUT_SEQ += 1 ))
	OUT_BUF+="${file}"$'\t'"${id}"$'\t'"${OUT_SEQ}"$'\t'"${id} ${status} ${file}:${line} ${msg}"$'\n'
}

# An item with only advisory WARNs still gets its PASS, worded after them.
pass_unless_seen() {
	[[ "${SEEN}" != *" $1 "* ]] || return 0
	local rest=${ADVISORY_WARNS} warns=0
	while [[ "${rest}" == *" $1 "* ]]; do rest=${rest#*" $1"}; (( warns += 1 )); done
	if (( warns > 0 )); then
		emit "$1" PASS "$2" "${3:-0}" "no FAIL; ${warns} WARN above"
	else
		emit "$1" PASS "$2" "${3:-0}" "$4"
	fi
}

count_lines() {
	local line
	REPLY=0
	while IFS= read -r line; do [[ -n "${line}" ]] && (( REPLY += 1 )); done <<< "$1"
	return 0
}

skip_tool() {
	emit "$1" SKIP "$2" 0 "skipped: $3 missing"
}

# Emits every "R<TAB>id<TAB>status<TAB>file<TAB>line<TAB>msg" record in $1.
emit_records() {
	local typ id st file line msg
	while IFS=$'\t' read -r typ id st file line msg; do
		[[ "${typ}" == R ]] || continue
		emit "${id}" "${st}" "${file}" "${line}" "${msg}"
	done <<< "$1"
}

# flush_artifact TARGET — prints the buffered lines, capped at --max-lines.
flush_artifact() {
	if [[ -n "${OUT_BUF}" ]]; then
		printf '%s' "${OUT_BUF}" | sort -t $'\t' -k1,1 -k2,2 -k3,3n | cut -f4- \
			| LINT_SHOWN_TARGET=${1#"${STRIP}"} awk -v max="${OPT_MAX_LINES}" '
				max == 0 || NR <= max { print }
				END { if (max > 0 && NR > max) printf "TRUNCATED INFO %s showing %d of %d lines\n", ENVIRON["LINT_SHOWN_TARGET"], max, NR }'
	fi
	OUT_BUF=""
}

begin_artifact() {
	local path=$1 root
	OUT_BUF=""; SEEN=" "; ADVISORY_WARNS=" "; STRIP=""
	for root in "${ROOTS[@]}"; do
		if [[ "${path}" == "${root}/"* ]]; then STRIP="${root}/"; break; fi
	done
	export LINT_STRIP=${STRIP}
}

load_waivers() {
	local text line re='^(- )?([A-Z][A-Z0-9]*-[0-9]+):[[:space:]]+(.*)[[:space:]][(]owner[)][[:space:]]*$'
	WAIVER_IDS=(); WAIVER_REASONS=()
	[[ -n "${OPT_WAIVERS}" ]] || return 0
	[[ -f "${OPT_WAIVERS}" ]] || usage_error "--waivers file does not exist or is not a regular file: ${OPT_WAIVERS}"
	text=$(cat -- "${OPT_WAIVERS}" 2>/dev/null) || usage_error "--waivers file is not readable: ${OPT_WAIVERS}"
	while IFS= read -r line; do
		line=${line%$'\r'}
		if [[ "${line}" =~ ${re} ]]; then
			WAIVER_IDS+=("${BASH_REMATCH[2]}"); WAIVER_REASONS+=("${BASH_REMATCH[3]}")
		fi
	done <<< "${text}"
	return 0
}

# ------------------------------------------------------------- frontmatter

FM_END=0
FMK=(); FML=(); FMKIND=(); FMLEN=(); FMVAL=()
FLK=(); FLI=()
FMC_KEY=(); FMC_CHILD=(); FMC_KIND=(); FMC_LINE=()
FME_LINE=(); FME_MSG=()

parse_frontmatter() {
	local file=$1 records typ a b c d e
	FM_END=0
	FMK=(); FML=(); FMKIND=(); FMLEN=(); FMVAL=(); FLK=(); FLI=()
	FMC_KEY=(); FMC_CHILD=(); FMC_KIND=(); FMC_LINE=(); FME_LINE=(); FME_MSG=()
	records=$(LINT_MODE=fm awk "${LINT_AWK}" "${file}") || awk_failed "parsing the frontmatter of ${file}"
	while IFS=$'\t' read -r typ a b c d e; do
		case "${typ}" in
			X) FM_END=${a} ;;
			K) FMK+=("${a}"); FML+=("${b}"); FMKIND+=("${c}"); FMLEN+=("${d}"); FMVAL+=("${e//$'\036'/$'\n'}") ;;
			L) FLK+=("${a}"); FLI+=("${c}") ;;
			M) FMC_KEY+=("${a}"); FMC_LINE+=("${b}"); FMC_CHILD+=("${c}"); FMC_KIND+=("${d}") ;;
			E) FME_LINE+=("${a}"); FME_MSG+=("${b}") ;;
			*) ;;
		esac
	done <<< "${records}"
	return 0
}

# Sets FM_I (-1 if absent), FM_V, FM_KD, FM_LN, FM_LEN for key $1.
fm_get() {
	local i
	FM_I=-1; FM_V=""; FM_KD=""; FM_LN=0; FM_LEN=0
	for (( i = 0; i < ${#FMK[@]}; i++ )); do
		if [[ "${FMK[i]}" == "$1" ]]; then
			FM_I=${i}; FM_V=${FMVAL[i]}; FM_KD=${FMKIND[i]}; FM_LN=${FML[i]}; FM_LEN=${FMLEN[i]}
			return 0
		fi
	done
	return 0
}

# Sets REPLY=1 when key $1 is present with a non-empty value (booleans count).
fm_nonempty() {
	fm_get "$1"
	REPLY=0
	(( FM_I >= 0 )) || return 0
	case "${FM_KD}" in
		empty) return 0 ;;
		plain) [[ "${FM_V}" =~ ^(null|Null|NULL|~)?$ ]] && return 0 ;;
		*)     [[ -z "${FM_V}" ]] && return 0 ;;
	esac
	REPLY=1
}

# Sets FM_LIST to the items of key $1 (list items, or a scalar split on commas).
fm_list() {
	local i item
	FM_LIST=()
	for (( i = 0; i < ${#FLK[@]}; i++ )); do
		[[ "${FLK[i]}" == "$1" ]] && FM_LIST+=("${FLI[i]}")
	done
	[[ ${#FM_LIST[@]} -gt 0 ]] && return 0
	fm_get "$1"
	[[ "${FM_KD}" == plain || "${FM_KD}" == quoted ]] || return 0
	local IFS=,
	for item in ${FM_V}; do
		item=${item#"${item%%[![:space:]]*}"}; item=${item%"${item##*[![:space:]]}"}
		[[ -n "${item}" ]] && FM_LIST+=("${item}")
	done
	return 0
}

is_yaml_bool() {
	case "$1" in
		[Tt][Rr][Uu][Ee]|[Ff][Aa][Ll][Ss][Ee]|[Yy][Ee][Ss]|[Nn][Oo]|[Oo][Nn]|[Oo][Ff][Ff]|1|0) REPLY=1 ;;
		*) REPLY=0 ;;
	esac
}

is_yaml_true() {
	case "$1" in
		[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]|1) REPLY=1 ;;
		*) REPLY=0 ;;
	esac
}

# Splits an allowed-tools / tools value into TOOLS, keeping "Name(args)" whole.
split_tools() {
	local s=$1 re='^[[:space:],]*([A-Za-z_][A-Za-z0-9_]*([(][^)]*[)])?)'
	TOOLS=()
	while [[ "${s}" =~ ${re} ]]; do
		TOOLS+=("${BASH_REMATCH[1]}")
		s=${s:${#BASH_REMATCH[0]}}
	done
	return 0
}

# Shared by LNT-03 (skills) and LNT-59 (agents): structural parse problems,
# plus a real YAML parse through ruby when it is installed.
frontmatter_parse_findings() {
	local id=$1 file=$2 i out
	for (( i = 0; i < ${#FME_LINE[@]}; i++ )); do
		emit "${id}" FAIL "${file}" "${FME_LINE[i]}" "${FME_MSG[i]}"
	done
	(( FM_END > 2 )) || return 0
	if ! command -v ruby >/dev/null 2>&1; then
		emit "${id}" INFO "${file}" 1 "ruby missing: YAML cross-check not run (subset parser only)"
		return 0
	fi
	# shellcheck disable=SC2016  # ruby program is single-quoted on purpose
	out=$(sed -n "2,$((FM_END - 1))p" "${file}" | ruby -E UTF-8 -ryaml -rdate -e '
		begin
			d = YAML.safe_load($stdin.read, permitted_classes: [Date, Time, Symbol], aliases: true)
			puts(d.is_a?(Hash) ? "OK" : "frontmatter is not a mapping (#{d.class})")
		rescue Psych::Exception => e
			puts "YAML parse error: #{e.message.sub(/^\(<unknown>\): /, "")} (line numbers count from line 2)"
		end' 2>&1) || out="ruby failed: ${out}"
	[[ "${out}" == OK ]] || emit "${id}" FAIL "${file}" 1 "${out}"
	return 0
}

# ------------------------------------------------------------- dispatching

lint_target() {
	local target=$1
	begin_artifact "${target}"
	if [[ -d "${target}" ]]; then lint_skill "${target}"; else lint_agent "${target}"; fi
	flush_artifact "${target}"
}

# ------------------------------------------------------------------ skills

lint_skill() {
	SKILL_DIR=$1
	SKILL_MD="${SKILL_DIR}/SKILL.md"
	local name
	collect_skill_files
	if [[ ! -f "${SKILL_MD}" ]]; then
		emit LNT-01 FAIL "${SKILL_DIR}" 0 "no file named exactly SKILL.md"
		check_junk; check_secrets "${SKILL_DIR}" ${SK_TEXT_FILES[@]+"${SK_TEXT_FILES[@]}"}
		return 0
	fi
	emit LNT-01 PASS "${SKILL_DIR}" 0 "SKILL.md present"
	parse_frontmatter "${SKILL_MD}"
	fm_get name; name=${FM_V}
	deployed_name "${SKILL_DIR}"; SKILL_DEPLOYED=${REPLY}
	build_preload_index
	SKILL_PRELOADED=0
	[[ "${PRELOADED_NAMES}" == *" ${SKILL_DEPLOYED} "* || ( -n "${name}" && "${PRELOADED_NAMES}" == *" ${name} "* ) ]] && SKILL_PRELOADED=1

	check_skill_frontmatter_structure
	check_skill_name "${name}"
	check_skill_description
	check_skill_keys
	check_skill_text
	check_skill_paths
	check_skill_bang_commands
	check_orphans
	check_junk
	check_scripts
	check_hooks skill "${SKILL_MD}"
	check_evals
	check_parse_examples
	check_secrets "${SKILL_DIR}" ${SK_TEXT_FILES[@]+"${SK_TEXT_FILES[@]}"}
	check_contracts
	if (( SKILL_PRELOADED )); then
		check_schema_mentions "${SKILL_MD}" "${SKILL_MD}"
	else
		emit LNT-53 PASS "${SKILL_MD}" 0 "not preloaded by any agent (N/A)"
	fi
}

collect_skill_files() {
	local path rel
	SK_FILES=(); SK_MD=(); SK_TOPDIRS=" "; SK_TEXT_FILES=()
	[[ -d "${SKILL_DIR}" ]] || return 0
	find "${SKILL_DIR}" \( -type d -name .git \) -prune -o -type f -print0 > "${TMP_DIR}/files" || skill_find_failed
	sort -z "${TMP_DIR}/files" > "${TMP_DIR}/files.sorted" || sort_failed
	while IFS= read -r -d '' path; do
		rel=${path#"${SKILL_DIR}/"}
		SK_FILES+=("${rel}")
		[[ "${rel}" == *.md ]] && SK_MD+=("${rel}")
	done < "${TMP_DIR}/files.sorted"
	for path in "${SKILL_DIR}"/*/; do
		[[ -d "${path}" ]] && SK_TOPDIRS+="$(basename -- "${path}") "
	done
	for rel in ${SK_FILES[@]+"${SK_FILES[@]}"}; do
		grep -Iq '' "${SKILL_DIR}/${rel}" 2>/dev/null && SK_TEXT_FILES+=("${SKILL_DIR}/${rel}")
	done
	return 0
}

check_skill_frontmatter_structure() {
	if (( FM_END > 0 )); then
		emit LNT-02 PASS "${SKILL_MD}" 1 "frontmatter delimited by line 1 and line ${FM_END}"
	else
		emit LNT-02 FAIL "${SKILL_MD}" 1 "line 1 is not --- or no later --- line closes the frontmatter"
	fi
	frontmatter_parse_findings LNT-03 "${SKILL_MD}"
	pass_unless_seen LNT-03 "${SKILL_MD}" 1 "frontmatter parses as a mapping; no unquoted ': ' in plain scalars"
}

check_skill_name() {
	local name=$1 ln lower
	fm_get name; ln=${FM_LN}
	fm_get description
	if [[ -z "${name}" || "${name}" =~ ^(null|Null|NULL|~)$ ]]; then
		emit LNT-04 FAIL "${SKILL_MD}" "${ln}" "name is missing or empty"
	elif [[ "${FM_KD}" == empty || -z "${FM_V}" ]]; then
		emit LNT-04 FAIL "${SKILL_MD}" "${FM_LN}" "description is missing or empty"
	elif [[ "${name}" =~ ^(true|false|[0-9.]+)$ ]]; then
		emit LNT-04 FAIL "${SKILL_MD}" "${ln}" "name \"${name}\" is not a string"
	else
		emit LNT-04 PASS "${SKILL_MD}" "${ln}" "name and description present"
	fi
	if [[ "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#name} -le 64 ]]; then
		emit LNT-05 PASS "${SKILL_MD}" "${ln}" "name \"${name}\" is kebab-case, ${#name} chars"
	else
		emit LNT-05 FAIL "${SKILL_MD}" "${ln}" "name \"${name}\" must match ^[a-z0-9]+(-[a-z0-9]+)*\$ and be <= 64 chars (is ${#name})"
	fi
	if [[ "${name}" == "${SKILL_DEPLOYED}" ]]; then
		emit LNT-06 PASS "${SKILL_MD}" "${ln}" "name equals deployed name (${DEPLOYED_FROM})"
	else
		emit LNT-06 FAIL "${SKILL_MD}" "${ln}" "name \"${name}\" differs from deployed name \"${SKILL_DEPLOYED}\" (${DEPLOYED_FROM})"
	fi
	lower=$(printf '%s' "${name}" | tr '[:upper:]' '[:lower:]')
	repo_skill_name "${SKILL_DIR}"
	local dirname_lower
	dirname_lower=$(printf '%s' "${REPLY}" | tr '[:upper:]' '[:lower:]')
	if [[ "${lower}" == *anthropic* || "${lower}" == *claude* ]]; then
		emit LNT-07 FAIL "${SKILL_MD}" "${ln}" "name contains a reserved word (anthropic/claude)"
	elif [[ "${dirname_lower}" == synced || "${dirname_lower}" == anthropic-skills ]]; then
		emit LNT-07 FAIL "${SKILL_DIR}" 0 "dir name \"${REPLY}\" is reserved"
	else
		emit LNT-07 PASS "${SKILL_MD}" "${ln}" "no reserved word in name or dir"
	fi
	check_house_name "${name}" "${ln}"
	check_tech_plugin "${name}"
}

# LNT-72: a plugin carries metadata.label; a tech plugin's metadata.base names
# a sibling plugin that has no base of its own; a standard plugin has no base.
tech_meta() {
	awk -v key="$2" '
		NR == 1 && $0 != "---" { exit }
		NR > 1 && $0 == "---" { exit }
		/^metadata:/ { m = 1; next }
		m && /^[^ ]/ { m = 0 }
		m && $0 ~ "^  " key ":" { sub("^  " key ":[ ]*", ""); gsub(/^["\047]|["\047][ ]*$/, ""); print NR "\t" $0; exit }
	' "$1"
}

check_tech_plugin() {
	local name=$1 rec label base base_md
	local kind=tech
	if [[ "${name}" == standard-* && "${SKILL_DIR%/*}" == */plugins/standards ]]; then kind=standard
	elif [[ "${name}" != tech-* ]]; then return 0; fi
	if ! awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { exit 1 } /^disable-model-invocation:[ ]*"?true"?[ ]*$/ { f = 1; exit } END { exit !f }' "${SKILL_MD}"; then
		emit LNT-72 FAIL "${SKILL_MD}" 1 "${kind} plugin does not set disable-model-invocation: true (list-plugins.sh would skip or reject it)"
		return 0
	fi
	if [[ ! -f "${SKILL_DIR}/references/development.md" ]]; then
		emit LNT-72 FAIL "${SKILL_MD}" 1 "${kind} plugin has no references/development.md"
		return 0
	fi
	rec=$(tech_meta "${SKILL_MD}" label)
	label=${rec#*$'\t'}
	if [[ -z "${rec}" || -z "${label}" ]]; then
		emit LNT-72 FAIL "${SKILL_MD}" 1 "${kind} plugin has no metadata.label"
		return 0
	fi
	rec=$(tech_meta "${SKILL_MD}" base)
	if [[ "${kind}" == standard && -n "${rec}" ]]; then
		emit LNT-72 FAIL "${SKILL_MD}" "${rec%%$'\t'*}" "a standard plugin takes no metadata.base"
		return 0
	fi
	if [[ -z "${rec}" ]]; then
		emit LNT-72 PASS "${SKILL_MD}" 1 "metadata.label \"${label}\"; no base"
		return 0
	fi
	base=${rec#*$'\t'}
	base_md="$(dirname "${SKILL_DIR}")/${base}/SKILL.md"
	[[ -f "${base_md}" ]] || base_md="${CLAUDE_HOME}/skills/tech-${base}/SKILL.md"
	if [[ ! -f "${base_md}" ]]; then
		emit LNT-72 FAIL "${SKILL_MD}" "${rec%%$'\t'*}" "metadata.base \"${base}\" names no tech plugin"
	elif [[ -n "$(tech_meta "${base_md}" base)" ]]; then
		emit LNT-72 FAIL "${SKILL_MD}" "${rec%%$'\t'*}" "base \"${base}\" has a base of its own (one level only)"
	else
		emit LNT-72 PASS "${SKILL_MD}" 1 "metadata.label \"${label}\"; base ${base}"
	fi
}

check_house_name() {
	local name=$1 ln=$2 prefix has_prefix=0 word rest all_generic=1
	for prefix in ${HOUSE_PREFIXES}; do
		[[ "${name}" == "${prefix}"* ]] && { has_prefix=1; rest=${name#"${prefix}"}; }
	done
	if (( ! has_prefix )); then
		emit LNT-40 FAIL "${SKILL_MD}" "${ln}" "name \"${name}\" lacks a house prefix (${HOUSE_PREFIXES})"
		return 0
	fi
	local IFS=-
	for word in ${rest}; do
		[[ " ${GENERIC_WORDS} " == *" ${word} "* ]] || all_generic=0
	done
	if (( all_generic )); then
		emit LNT-40 FAIL "${SKILL_MD}" "${ln}" "name \"${name}\" has only generic words after its prefix"
	else
		emit LNT-40 PASS "${SKILL_MD}" "${ln}" "house prefix and a specific name"
	fi
}

check_skill_description() {
	local desc dlen dln wlen records
	fm_get description; desc=${FM_V}; dlen=${FM_LEN}; dln=${FM_LN}
	fm_get when_to_use; wlen=${FM_LEN}
	if (( dlen <= 1024 )); then emit LNT-09 PASS "${SKILL_MD}" "${dln}" "description ${dlen} chars (<= 1024)"
	else emit LNT-09 FAIL "${SKILL_MD}" "${dln}" "description ${dlen} chars (> 1024)"; fi
	if [[ "${desc}" == *[\<\>]* ]]; then emit LNT-10 FAIL "${SKILL_MD}" "${dln}" "description contains < or >"
	else emit LNT-10 PASS "${SKILL_MD}" "${dln}" "no < or > in description"; fi
	if (( dlen + wlen <= 1536 )); then emit LNT-11 PASS "${SKILL_MD}" "${dln}" "description + when_to_use $(( dlen + wlen )) chars (<= 1536)"
	else emit LNT-11 FAIL "${SKILL_MD}" "${dln}" "description + when_to_use $(( dlen + wlen )) chars (> 1536)"; fi
	records=$(LINT_MODE=firstperson LINT_TEXT=${desc} LINT_FILE=${SKILL_MD} LINT_LINE=${dln} awk "${LINT_AWK}" /dev/null) || awk_failed "checking the description of ${SKILL_MD}"
	emit_records "${records}"
	pass_unless_seen LNT-14 "${SKILL_MD}" "${dln}" "description is third person"
	if (( dlen >= 50 )); then emit LNT-49 PASS "${SKILL_MD}" "${dln}" "description ${dlen} chars (>= 50)"
	else emit LNT-49 FAIL "${SKILL_MD}" "${dln}" "description ${dlen} chars (< 50)"; fi
	if (( dlen <= 500 )); then emit LNT-63 PASS "${SKILL_MD}" "${dln}" "description ${dlen} chars (<= 500)"
	else emit LNT-63 FAIL "${SKILL_MD}" "${dln}" "description ${dlen} chars (> 500)"; fi
}

check_skill_keys() {
	local i key absent="" item
	for (( i = 0; i < ${#FMK[@]}; i++ )); do
		key=${FMK[i]}
		if [[ " ${AGENT_ONLY_KEYS} " == *" ${key} "* ]]; then
			emit LNT-12 FAIL "${SKILL_MD}" "${FML[i]}" "key \"${key}\" is agent-only or not a skill field"
		elif [[ " ${SKILL_KEYS} " != *" ${key} "* ]]; then
			emit LNT-12 FAIL "${SKILL_MD}" "${FML[i]}" "unknown key \"${key}\" (Claude Code ignores it silently)"
		elif [[ " ${SKILL_BOOL_KEYS} " == *" ${key} "* ]]; then
			is_yaml_bool "${FMVAL[i]}"
			[[ "${FMKIND[i]}" == plain && "${REPLY}" == 1 ]] || emit LNT-12 FAIL "${SKILL_MD}" "${FML[i]}" "\"${key}\" must be a boolean (true/false/yes/no/on/off/1/0), is \"${FMVAL[i]}\""
		fi
	done
	pass_unless_seen LNT-12 "${SKILL_MD}" 1 "every key is a known skill field"

	fm_get compatibility
	if (( FM_I >= 0 )) && (( FM_LEN < 1 || FM_LEN > 500 )); then
		emit LNT-13 FAIL "${SKILL_MD}" "${FM_LN}" "compatibility is ${FM_LEN} chars (1-500)"
	fi
	fm_get metadata
	if (( FM_I >= 0 )); then
		if [[ "${FM_KD}" != map ]]; then
			emit LNT-13 WARN "${SKILL_MD}" "${FM_LN}" "metadata is not a string-to-string map"
		fi
		for (( i = 0; i < ${#FMC_KEY[@]}; i++ )); do
			[[ "${FMC_KEY[i]}" == metadata ]] || continue
			[[ "${FMC_KIND[i]}" == scalar ]] || emit LNT-13 WARN "${SKILL_MD}" "${FMC_LINE[i]}" "metadata.${FMC_CHILD[i]} is not a string value"
			[[ " ${SKILL_KEYS} " != *" ${FMC_CHILD[i]} "* ]] || emit LNT-13 WARN "${SKILL_MD}" "${FMC_LINE[i]}" "metadata key \"${FMC_CHILD[i]}\" reuses a field name"
		done
	fi
	pass_unless_seen LNT-13 "${SKILL_MD}" 1 "compatibility and metadata valid or absent"

	fm_get allowed-tools
	if (( FM_I >= 0 )); then
		local ln=${FM_LN}
		fm_list allowed-tools
		split_tools "$(printf '%s ' ${FM_LIST[@]+"${FM_LIST[@]}"})"
		for item in ${TOOLS[@]+"${TOOLS[@]}"}; do
			case "${item}" in
				Bash|'Bash(*)'|'Bash(* *)') emit LNT-41 FAIL "${SKILL_MD}" "${ln}" "allowed-tools pre-approves unscoped ${item}" ;;
				Write|Edit)                 emit LNT-41 WARN "${SKILL_MD}" "${ln}" "allowed-tools pre-approves unscoped ${item}" ;;
				*) ;;
			esac
		done
	fi
	pass_unless_seen LNT-41 "${SKILL_MD}" 1 "no unscoped Bash in allowed-tools"

	for key in ${SKILL_REQUIRED}; do
		fm_nonempty "${key}"
		(( REPLY )) || emit LNT-64 FAIL "${SKILL_MD}" "${FM_LN:-1}" "required key \"${key}\" is missing or empty"
	done
	pass_unless_seen LNT-64 "${SKILL_MD}" 1 "required keys present: ${SKILL_REQUIRED}"

	for key in ${SKILL_KEYS}; do
		fm_get "${key}"
		(( FM_I >= 0 )) || absent+="${absent:+, }${key}"
	done
	emit LNT-71 INFO "${SKILL_MD}" 1 "unset optional fields: ${absent:-none} (defaults apply)"
}

# One awk pass over SKILL.md and every other .md: LNT-15/16/18/19/20/21/23/
# 24/25/26/37/43/49/70 records, plus path (P), bang (B) and code-block (C)
# candidates consumed by later checks.
check_skill_text() {
	local md_abs=() rel argnames="" item
	for rel in ${SK_MD[@]+"${SK_MD[@]}"}; do
		[[ "${rel}" == SKILL.md ]] || md_abs+=("${SKILL_DIR}/${rel}")
	done
	fm_list arguments
	for item in ${FM_LIST[@]+"${FM_LIST[@]}"}; do
		item=${item#name:}; item=${item//[\"\' ]/}
		[[ "${item}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && argnames+="${item} "
	done
	mkdir -p "${TMP_DIR}/blocks"
	rm -f "${TMP_DIR}"/blocks/b*
	SK_TEXT_RECORDS=$(LINT_MODE=md LINT_SKILL_DIR=${SKILL_DIR} LINT_SKILL_MD=${SKILL_MD} \
		LINT_TOPDIRS=${SK_TOPDIRS} LINT_MDFILES="$(printf '%s\n' ${SK_MD[@]+"${SK_MD[@]}"})" \
		LINT_ARGNAMES=${argnames} LINT_PRELOADED=${SKILL_PRELOADED} LINT_BLKDIR="${TMP_DIR}/blocks" \
		awk "${LINT_AWK}" "${SKILL_MD}" ${md_abs[@]+"${md_abs[@]}"}) || awk_failed "scanning the .md files of ${SKILL_DIR}"
	emit_records "${SK_TEXT_RECORDS}"
	pass_unless_seen LNT-18 "${SKILL_DIR}" 0 "no reference links to another reference .md"
	pass_unless_seen LNT-19 "${SKILL_DIR}" 0 "every reference over 100 lines has a contents list"
	pass_unless_seen LNT-20 "${SKILL_DIR}" 0 "no backslash-separated paths"
	pass_unless_seen LNT-21 "${SKILL_MD}" 0 "no unescaped argument placeholder"
	pass_unless_seen LNT-24 "${SKILL_DIR}" 0 "no time-sensitive wording"
	pass_unless_seen LNT-26 "${SKILL_DIR}" 0 "no reference over 10,000 words without a grep pattern"
	pass_unless_seen LNT-37 "${SKILL_DIR}" 0 "no cwd-relative script commands"
	pass_unless_seen LNT-43 "${SKILL_DIR}" 0 "no Server:tool MCP names"
	pass_unless_seen LNT-60 "${SKILL_DIR}" 0 "every quote-safely line canonical (or none)"
}

check_skill_paths() {
	local typ kind file line path name rest base found b
	local -a bases
	while IFS=$'\t' read -r typ kind file line path; do
		[[ "${typ}" == P ]] || continue
		case "${kind}" in
			link)     bases=("${file%/*}" "${SKILL_DIR}" "${SKILL_DIR}/scripts") ;;
			rel)      bases=("${SKILL_DIR}" "${SKILL_DIR}/scripts") ;;
			skilldir) bases=("${SKILL_DIR}") ;;
			named)
				name=${path%%/*}
				if [[ "${path}" == */* ]]; then rest=${path#*/}; else rest=""; fi
				if [[ "${name}" == *[\<\>\{\}\$*]* ]]; then
					emit LNT-30 WARN "${file}" "${line}" "ambiguous skill name in ~/.claude/skills/${path}; not checked"; continue
				fi
				resolve_skill_name "${name}"
				if [[ -z "${REPLY}" ]]; then
					emit LNT-30 WARN "${file}" "${line}" "skill \"${name}\" not found in ${CLAUDE_HOME}/skills or the roots; ${path} not checked"; continue
				fi
				bases=("${REPLY}"); path=${rest} ;;
			*) continue ;;
		esac
		if [[ "${path}" == *[\<\>\{\}\$]* || "${path}" == *…* ]]; then
			emit LNT-30 WARN "${file}" "${line}" "path ${path} holds a placeholder; not checked"; continue
		fi
		found=0
		for b in "${bases[@]}"; do
			base="${b}/${path}"
			if [[ "${path}" == *[*?]* ]]; then
				compgen -G "${base}" >/dev/null 2>&1 && { found=1; break; }
			elif [[ -z "${path}" || -e "${base}" ]]; then
				found=1; break
			fi
		done
		(( found )) || emit LNT-30 FAIL "${file}" "${line}" "path does not exist: ${path}"
	done <<< "${SK_TEXT_RECORDS}"
	pass_unless_seen LNT-30 "${SKILL_DIR}" 0 "every referenced path exists"
}

check_skill_bang_commands() {
	local typ file line cmd s pat allowed=() ok re='Bash[(]([^)]*)[)]'
	fm_list allowed-tools
	s=$(printf '%s ' ${FM_LIST[@]+"${FM_LIST[@]}"})
	while [[ "${s}" =~ ${re} ]]; do
		allowed+=("${BASH_REMATCH[1]}")
		s=${s#*"${BASH_REMATCH[0]}"}
	done
	while IFS=$'\t' read -r typ file line cmd; do
		[[ "${typ}" == B ]] || continue
		ok=0
		for pat in ${allowed[@]+"${allowed[@]}"}; do
			if [[ "${pat}" == *:\* ]]; then
				[[ "${cmd}" == "${pat%:\*}" || "${cmd}" == "${pat%:\*} "* ]] && { ok=1; break; }
			else
				# shellcheck disable=SC2053  # the allowed-tools entry is deliberately a glob
				[[ "${cmd}" == ${pat} ]] && { ok=1; break; }
			fi
		done
		(( ok )) || emit LNT-31 FAIL "${file}" "${line}" "!-command \"${cmd}\" matches no allowed-tools Bash(<glob>)"
	done <<< "${SK_TEXT_RECORDS}"
	pass_unless_seen LNT-31 "${SKILL_MD}" 0 "every !-command is pre-approved (or none)"
}

check_orphans() {
	local records
	records=$(LINT_MODE=orphans LINT_SKILL_DIR=${SKILL_DIR} LINT_FILES="$(printf '%s\n' ${SK_FILES[@]+"${SK_FILES[@]}"})" \
		awk "${LINT_AWK}" /dev/null) || awk_failed "listing unnamed files in ${SKILL_DIR}"
	emit_records "${records}"
	pass_unless_seen LNT-17 "${SKILL_DIR}" 0 "every bundled file is named in SKILL.md or a named script"
}

check_junk() {
	local path rel base stem content
	if [[ -d "${SKILL_DIR}" ]]; then
		find "${SKILL_DIR}" -mindepth 1 \( -name .git -prune \) -o -print0 > "${TMP_DIR}/junk" || skill_find_failed
		while IFS= read -r -d '' path; do
			rel=${path#"${SKILL_DIR}/"}; base=${path##*/}
			if [[ -d "${path}" ]]; then
				case "${base}" in
					__pycache__|node_modules) emit LNT-22 FAIL "${path}" 0 "build junk dir ${rel}" ;;
					*) compgen -G "${path}/*" >/dev/null || compgen -G "${path}/.[!.]*" >/dev/null || emit LNT-22 FAIL "${path}" 0 "empty dir ${rel}" ;;
				esac
				continue
			fi
			case "${base}" in
				.DS_Store|*.pyc) emit LNT-22 FAIL "${path}" 0 "build junk ${rel}"; continue ;;
				*) ;;
			esac
			stem=$(printf '%s' "${base%.*}" | tr '[:upper:]' '[:lower:]') || stem=""
			[[ "${stem}" =~ ^(file|doc|misc|utils?|helpers?|tools?|stuff|temp|tmp|untitled)[0-9]*$ ]] && emit LNT-22 FAIL "${path}" 0 "generic file name ${rel}"
			# LNT-22: a placeholder-only file is short; 256 bytes hold any of
			# the placeholder words, so reading more cannot change the result.
			content=$(head -c 256 "${path}" | tr -d '[:space:]') || content=""
			if [[ -z "${content}" ]]; then
				emit LNT-22 FAIL "${path}" 0 "empty or whitespace-only file ${rel}"
			elif [[ "${content}" =~ ^(TODO|TBD|todo|tbd|[Pp]laceholder)[.:!]?$ ]]; then
				emit LNT-22 FAIL "${path}" 0 "placeholder-only file ${rel}"
			fi
		done < "${TMP_DIR}/junk"
	fi
	pass_unless_seen LNT-22 "${SKILL_DIR}" 0 "no empty dirs, generic names, placeholders or build junk"
}

check_scripts() {
	local rel scripts=() records typ file kind out first
	for rel in ${SK_FILES[@]+"${SK_FILES[@]}"}; do
		case "${rel}" in
			scripts/*|lib/*) scripts+=("${SKILL_DIR}/${rel}") ;;
			*) ;;
		esac
	done
	if [[ ${#scripts[@]} -eq 0 ]]; then
		for rel in LNT-27 LNT-28 LNT-29 LNT-32; do emit "${rel}" PASS "${SKILL_DIR}" 0 "no scripts (N/A)"; done
		return 0
	fi
	records=$(LINT_MODE=scripts awk "${LINT_AWK}" "${scripts[@]}") || awk_failed "scanning the scripts of ${SKILL_DIR}"
	emit_records "${records}"
	while IFS=$'\t' read -r typ file kind; do
		[[ "${typ}" == S ]] || continue
		first=$(head -c 2 "${file}") || first=""
		if [[ "${first}" == '#!' && ! -x "${file}" ]]; then
			emit LNT-27 FAIL "${file}" 1 "has a shebang but is not executable"
		fi
		[[ "${kind}" == bash || "${kind}" == sh || "${kind}" == shell ]] || continue
		if ! command -v shellcheck >/dev/null 2>&1; then
			skip_tool LNT-29 "${file}" shellcheck; continue
		fi
		local -a sc_args=(-x -P SCRIPTDIR -f gcc)
		[[ "${kind}" == shell ]] && sc_args+=(-s bash)
		out=$(shellcheck "${sc_args[@]}" "${file}" 2>&1) && continue
		count_lines "${out}"
		emit LNT-29 FAIL "${file}" 0 "shellcheck reports ${REPLY} issue(s); first: ${out%%$'\n'*}"
	done <<< "${records}"
	pass_unless_seen LNT-27 "${SKILL_DIR}" 0 "scripts executable, entry points print usage"
	pass_unless_seen LNT-28 "${SKILL_DIR}" 0 "no interactive input in scripts"
	pass_unless_seen LNT-29 "${SKILL_DIR}" 0 "shell scripts use strict mode and pass shellcheck"
	pass_unless_seen LNT-32 "${SKILL_DIR}" 0 "no literal /tmp paths; every mktemp has an EXIT trap"
}

# LNT-33 on the hooks: block of $2; LNT-34 on the scripts its gate hooks run.
check_hooks() {
	local kind=$1 file=$2 records typ event line cmd tok path base_dir found=0 out
	records=$(LINT_MODE=hooks LINT_ART_KIND=${kind} awk "${LINT_AWK}" "${file}") || awk_failed "reading the hooks of ${file}"
	emit_records "${records}"
	if [[ "${kind}" == skill ]]; then base_dir=${SKILL_DIR}; else base_dir=${file%/*}; fi
	while IFS=$'\t' read -r typ event line cmd; do
		[[ "${typ}" == H ]] || continue
		found=1
		[[ " ${GATE_EVENTS} " == *" ${event} "* ]] || continue
		for tok in ${cmd}; do
			tok=${tok//\"/}; tok=${tok//\'/}
			# shellcheck disable=SC2016  # the literal variable name as written in the hook command
			case "${tok}" in
				'${CLAUDE_SKILL_DIR}/'*) path="${base_dir}/${tok#*/}" ;;
				/*)                      path=${tok} ;;
				*/*)                     path="${base_dir}/${tok#./}" ;;
				*)                       continue ;;
			esac
			[[ -f "${path}" ]] || continue
			out=$(LINT_MODE=hookscript LINT_HOOK_EVENT=${event} awk "${LINT_AWK}" "${path}") || awk_failed "checking the hook script ${path}"
			emit_records "${out}"
		done
	done <<< "${records}"
	pass_unless_seen LNT-33 "${file}" 1 "hooks valid (or none)"
	if (( found )); then
		pass_unless_seen LNT-34 "${file}" 1 "gate-hook scripts exit 0/2 only and fail closed"
	else
		emit LNT-34 PASS "${file}" 1 "no hooks (N/A)"
	fi
}

check_evals() {
	local evals="${SKILL_DIR}/evals" case_dirs=() d n out has_json=0 trig
	if [[ ! -d "${evals}" ]]; then
		emit LNT-38 PASS "${SKILL_DIR}" 0 "no evals/ (N/A)"
		emit LNT-39 PASS "${SKILL_DIR}" 0 "no evals/ (N/A)"
		emit LNT-45 PASS "${SKILL_DIR}" 0 "no plugin evals (N/A)"
		return 0
	fi
	[[ -f "${evals}/evals.json" ]] && has_json=1
	for d in "${evals}"/*/; do
		[[ -d "${d}" && "${d}" != */results/ ]] && case_dirs+=("${d%/}")
	done
	if (( has_json )) && [[ ${#case_dirs[@]} -gt 0 ]]; then
		emit LNT-38 FAIL "${evals}" 0 "both evals/evals.json and plugin-eval case dirs; use one format"
	fi
	if (( has_json )); then
		if ! command -v jq >/dev/null 2>&1; then
			skip_tool LNT-38 "${evals}/evals.json" jq; skip_tool LNT-39 "${evals}/evals.json" jq
		else
			out=$(jq -r '
				if type != "object" then "top level is not an object"
				else
				  (if (.skill_name | type) != "string" then "skill_name missing" else empty end),
				  (if (.evals | type) != "array" then "evals[] missing" else
				    (.evals | to_entries[] | .key as $i | .value
				      | (if type != "object" then "evals[\($i)] is not an object" else
				          (["id","prompt","expected_output"][] as $k | select(has($k) | not) | "evals[\($i)] lacks \($k)"),
				          (keys[] | select(test("assert") and . != "assertions") | "evals[\($i)] uses \(.) instead of assertions")
				        end))
				  end)
				end' "${evals}/evals.json" 2>&1) || out="not valid JSON: ${out}"
			while IFS= read -r d; do [[ -n "${d}" ]] && emit LNT-38 FAIL "${evals}/evals.json" 0 "${d}"; done <<< "${out}"
			n=$(jq '(.evals // []) | length' "${evals}/evals.json" 2>/dev/null || echo 0)
			(( n >= 3 )) || emit LNT-39 FAIL "${evals}/evals.json" 0 "${n} eval case(s) (< 3)"
			fm_get disable-model-invocation; is_yaml_true "${FM_V}"
			if (( ! REPLY )); then
				trig=$(jq -r '[.. | objects | select(has("should_trigger")) | .should_trigger | tostring] | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "${evals}/evals.json" 2>/dev/null || echo "")
				[[ "${trig}" =~ true=([89]|[1-9][0-9]+) && "${trig}" =~ false=([89]|[1-9][0-9]+) ]] || \
					emit LNT-39 FAIL "${evals}/evals.json" 0 "trigger queries per should_trigger class < 8 (${trig:-none})"
			fi
		fi
	fi
	for d in ${case_dirs[@]+"${case_dirs[@]}"}; do
		[[ -f "${d}/prompt.md" || -f "${d}/case.yaml" ]] || emit LNT-38 FAIL "${d}" 0 "case has neither prompt.md nor case.yaml"
		if [[ -f "${d}/case.yaml" ]]; then
			grep -Eq '^schema_version:[[:space:]]*"1\.1"' "${d}/case.yaml" || emit LNT-38 FAIL "${d}/case.yaml" 0 "schema_version is not \"1.1\""
			grep -Eq '^name:[[:space:]]*[^[:space:]]' "${d}/case.yaml" || emit LNT-38 FAIL "${d}/case.yaml" 0 "name missing"
			if awk '/^env:/ { e = 1; next } /^[^ \t]/ { e = 0 } e && /^[ \t]+[A-Za-z_]/ { k = $1; sub(/:.*/, "", k); if (k !~ /^EVAL_[A-Z0-9_]*$/) print k }' "${d}/case.yaml" | grep -q .; then
				emit LNT-38 FAIL "${d}/case.yaml" 0 "env key not EVAL_[A-Z0-9_]*"
			fi
		fi
		grep -rqF '(?' "${d}" 2>/dev/null && emit LNT-38 FAIL "${d}" 0 "inline regex flag (? found"
		compgen -G "${d}/*[Gg]rader*" >/dev/null || grep -qi grader "${d}/case.yaml" 2>/dev/null || emit LNT-38 FAIL "${d}" 0 "no grader found"
	done
	if [[ ${#case_dirs[@]} -gt 0 ]]; then
		(( ${#case_dirs[@]} >= 3 )) || emit LNT-39 FAIL "${evals}" 0 "${#case_dirs[@]} eval case(s) (< 3)"
		emit LNT-38 INFO "${evals}" 0 "prompt.md frontmatter keys not checked: the documented key list is not pinned"
		check_results_ignored
	else
		emit LNT-45 PASS "${SKILL_DIR}" 0 "no plugin evals (N/A)"
	fi
	pass_unless_seen LNT-38 "${evals}" 0 "evals format valid"
	pass_unless_seen LNT-39 "${evals}" 0 "enough eval cases"
}

check_results_ignored() {
	local dir=${SKILL_DIR}
	while [[ "${dir}" != / && ! -e "${dir}/.git" ]]; do dir=${dir%/*}; [[ -n "${dir}" ]] || dir=/; done
	if [[ -f "${dir}/.gitignore" ]] && grep -q 'evals/results' "${dir}/.gitignore"; then
		emit LNT-45 PASS "${dir}/.gitignore" 0 "evals/results/ ignored"
	else
		emit LNT-45 FAIL "${dir}/.gitignore" 0 "plugin evals exist but evals/results/ is not in .gitignore"
	fi
}

# LNT-51: example/asset files and tagged fenced blocks must parse.
check_parse_examples() {
	local typ tag file line path rel
	for rel in ${SK_FILES[@]+"${SK_FILES[@]}"}; do
		case "${rel}" in
			examples/*|assets/*)
				case "${rel}" in
					*.json) parse_block json "${SKILL_DIR}/${rel}" 0 "${SKILL_DIR}/${rel}" ;;
					*.yaml|*.yml) parse_block yaml "${SKILL_DIR}/${rel}" 0 "${SKILL_DIR}/${rel}" ;;
					*.sh|*.bash) parse_block bash "${SKILL_DIR}/${rel}" 0 "${SKILL_DIR}/${rel}" ;;
					*.py) parse_block python "${SKILL_DIR}/${rel}" 0 "${SKILL_DIR}/${rel}" ;;
					*) ;;
				esac ;;
			*) ;;
		esac
	done
	while IFS=$'\t' read -r typ tag file line path; do
		[[ "${typ}" == C ]] || continue
		parse_block "${tag}" "${file}" "${line}" "${path}"
	done <<< "${SK_TEXT_RECORDS}"
	pass_unless_seen LNT-51 "${SKILL_DIR}" 0 "examples, assets and tagged code blocks parse"
}

PARSE_SKIPPED=" "

parse_block() {
	local tag=$1 file=$2 line=$3 path=$4 tool out shell="bash"
	case "${tag}" in
		json)        tool=jq ;;
		yaml|yml)    tool=ruby ;;
		bash|shell)  tool="bash" ;;
		sh)          tool="bash"; shell="sh" ;;
		python|py)   tool=python3 ;;
		*)           return 0 ;;
	esac
	if ! command -v "${tool}" >/dev/null 2>&1; then
		[[ "${PARSE_SKIPPED}" == *" ${tool} "* ]] || { PARSE_SKIPPED+="${tool} "; skip_tool LNT-51 "${file}" "${tool}"; }
		return 0
	fi
	case "${tool}" in
		jq)      out=$(jq . "${path}" 2>&1 >/dev/null) || { emit LNT-51 FAIL "${file}" "${line}" "json does not parse: ${out%%$'\n'*}"; return 0; } ;;
		ruby)    out=$(ruby -E UTF-8 -ryaml -rdate -e 'YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Date, Time, Symbol], aliases: true)' "${path}" 2>&1) || { emit LNT-51 FAIL "${file}" "${line}" "yaml does not parse: ${out%%$'\n'*}"; return 0; } ;;
		python3) out=$(python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' "${path}" 2>&1) || { emit LNT-51 FAIL "${file}" "${line}" "python does not parse: ${out##*$'\n'}"; return 0; } ;;
		bash)
			out=$(bash -n "${path}" 2>&1) || { emit LNT-51 FAIL "${file}" "${line}" "bash -n: ${out%%$'\n'*}"; return 0; }
			if ! command -v shellcheck >/dev/null 2>&1; then
				[[ "${PARSE_SKIPPED}" == *" shellcheck "* ]] || { PARSE_SKIPPED+="shellcheck "; skip_tool LNT-51 "${file}" shellcheck; }
				return 0
			fi
			# A snippet has no shebang and borrows variables from its prose context,
			# so SC2148/SC2154/SC2034 would only report that it is a snippet.
			out=$(shellcheck -s "${shell}" -S warning -e SC2148,SC2154,SC2034 -f gcc "${path}" 2>&1) || \
				emit LNT-51 FAIL "${file}" "${line}" "shellcheck: ${out%%$'\n'*}" ;;
		*) ;;
	esac
	return 0
}

check_secrets() {
	local owner=$1; shift
	if [[ $# -gt 0 ]]; then
		local records
		records=$(LINT_MODE=secrets awk "${LINT_AWK}" "$@") || awk_failed "scanning ${owner} for secrets"
		emit_records "${records}"
	fi
	pass_unless_seen LNT-47 "${owner}" 0 "no secret-shaped values"
}

# ------------------------------------------------------- contracts (H)

# Contract set: *.schema.json inside the skill dir plus every schema basename
# SKILL.md or a bundled script names, resolved under the roots. References are
# left out: they name schemas as examples, not as files the skill reads.
check_contracts() {
	local names path base schema set=() i lnt52_failed=0 out agent card contract found
	discover_artifacts
	local sources=("${SKILL_MD}")
	for path in ${SK_FILES[@]+"${SK_FILES[@]}"}; do
		case "${path}" in
			*.schema.json)   set+=("${SKILL_DIR}/${path}") ;;
			scripts/*|lib/*) sources+=("${SKILL_DIR}/${path}") ;;
			*) ;;
		esac
	done
	names=$(grep -ohE '[A-Za-z0-9][A-Za-z0-9_.-]*\.schema\.json' "${sources[@]}" 2>/dev/null) || names=""
	names=$(printf '%s\n' "${names}" | sort -u) || sort_failed
	while IFS= read -r base; do
		[[ -n "${base}" ]] || continue
		found=0
		for schema in ${ALL_SCHEMAS[@]+"${ALL_SCHEMAS[@]}"}; do
			[[ "${schema##*/}" == "${base}" ]] || continue
			found=1
			[[ " ${set[*]-} " == *" ${schema} "* ]] || set+=("${schema}")
		done
		(( found )) || emit LNT-52 WARN "${SKILL_MD}" 0 "named schema ${base} not found under the roots"
	done <<< "${names}"
	if [[ ${#set[@]} -eq 0 ]]; then
		for i in LNT-52 LNT-54 LNT-55 LNT-56 LNT-57 LNT-58; do pass_unless_seen "${i}" "${SKILL_DIR}" 0 "no contract set (N/A)"; done
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		for i in LNT-52 LNT-54 LNT-56 LNT-57; do skip_tool "${i}" "${SKILL_DIR}" jq; done
		return 0
	fi
	for schema in "${set[@]}"; do
		out=$(jq -r "${JQ_X_WRITER}" "${schema}" 2>&1) || { emit LNT-52 FAIL "${schema}" 0 "not valid JSON"; lnt52_failed=1; continue; }
		while IFS= read -r i; do
			[[ -n "${i}" ]] || continue
			emit LNT-52 FAIL "${schema}" 0 "property \"${i}\" lacks a valid x-writer (script|orchestrator|agent:<name>)"; lnt52_failed=1
		done <<< "${out}"
	done
	pass_unless_seen LNT-52 "${SKILL_DIR}" 0 "every payload property carries a valid x-writer (${#set[@]} schema(s))"
	for schema in "${set[@]}"; do
		contract=${schema##*/}; contract=${contract%.schema.json}
		while IFS= read -r agent; do
			[[ -n "${agent}" ]] || continue
			card="${schema%/*}/cards/${contract}.${agent}.md"
			if (( lnt52_failed )); then
				emit LNT-54 WARN "${schema}" 0 "UNDECIDABLE (blocked by LNT-52) for agent:${agent}"
			elif [[ ! -f "${card}" ]]; then
				emit LNT-54 FAIL "${schema}" 0 "no agent card ${card#"${STRIP}"}"
			else
				emit LNT-54 SKIP "${card}" 0 "skipped: card generator missing (identity diff not run)"
				emit LNT-58 SKIP "${card}" 0 "skipped: card generator missing (determinism diff not run)"
				check_card "${card}"
			fi
		done <<< "$(jq -r '[.. | objects | .["x-writer"]? // empty | (if type == "array" then .[] else . end) | strings | select(startswith("agent:")) | ltrimstr("agent:")] | unique | .[]' "${schema}" 2>/dev/null || true)"
		jq -r --argjson unmarked "${lnt52_failed}" "${JQ_BOUNDS}" "${schema}" > "${TMP_DIR}/bounds" 2>/dev/null || : > "${TMP_DIR}/bounds"
		out=$(LINT_MODE=bounds LINT_FILE=${schema} awk "${LINT_AWK}" "${TMP_DIR}/bounds") || awk_failed "reading the LNT-57 records of ${schema}"
		emit_records "${out}"
	done
	: > "${TMP_DIR}/descriptions"
	for schema in "${set[@]}"; do
		jq -r --arg f "${schema}" "${JQ_DESCRIPTIONS}" "${schema}" >> "${TMP_DIR}/descriptions" 2>/dev/null || true
	done
	out=$(LINT_MODE=descriptions awk "${LINT_AWK}" "${TMP_DIR}/descriptions") || awk_failed "reading the LNT-56 records of ${SKILL_DIR}"
	emit_records "${out}"
	for i in LNT-54 LNT-55 LNT-56 LNT-57 LNT-58; do pass_unless_seen "${i}" "${SKILL_DIR}" 0 "contract set checks pass (${#set[@]} schema(s))"; done
}

check_card() {
	local card=$1 chars
	chars=$(LINT_MODE=chars awk "${LINT_AWK}" "${card}") || chars=0
	(( chars <= 8000 )) || emit LNT-55 FAIL "${card}" 0 "card is ${chars} chars (> 8,000)"
	local hit
	hit=$(grep -nE '[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}:[0-9]{2}|(/Users/|/home/|/private/|/tmp/)' "${card}") || hit=""
	[[ -z "${hit}" ]] || emit LNT-58 FAIL "${card}" "${hit%%:*}" "card holds a date, time or absolute path"
	return 0
}

# LNT-53: an agent (and what it preloads) must not see a contract's schema file.
check_schema_mentions() {
	local owner=$1 path hit; shift
	for path in "$@"; do
		[[ -f "${path}" ]] || continue
		while IFS= read -r hit; do
			[[ -n "${hit}" ]] && emit LNT-53 FAIL "${path}" "${hit%%:*}" "names schema file ${hit#*:}"
		done < <(grep -noE '[A-Za-z0-9][A-Za-z0-9_.-]*\.schema\.json' "${path}" 2>/dev/null || true)
	done
	pass_unless_seen LNT-53 "${owner}" 0 "no schema file named where an agent reads it"
}

# ------------------------------------------------------------------ agents

lint_agent() {
	local file=$1 name stem base records body_chars key absent="" ln
	local -a seen_by_agent
	base=${file##*/}; stem=${base%.md}
	parse_frontmatter "${file}"
	fm_get name; name=${FM_V}

	check_agent_frontmatter "${file}"
	fm_get name; ln=${FM_LN:-1}
	if [[ ! "${name}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then emit LNT-48 FAIL "${file}" "${ln}" "name \"${name}\" is not kebab-case [a-z0-9-]"
	elif (( ${#name} < 3 || ${#name} > 50 )); then emit LNT-48 FAIL "${file}" "${ln}" "name is ${#name} chars (3-50)"
	elif [[ "${name}" != "${stem}" ]]; then emit LNT-48 FAIL "${file}" "${ln}" "name \"${name}\" differs from file stem \"${stem}\""
	else emit LNT-48 PASS "${file}" "${ln}" "name \"${name}\" valid"; fi

	check_agent_tools "${file}" "${name}" "${stem}"

	fm_get omitClaudeMd; is_yaml_true "${FM_V}"
	if (( REPLY )); then emit LNT-62 PASS "${file}" "${FM_LN}" "omitClaudeMd: true"
	else emit LNT-62 FAIL "${file}" "${FM_LN:-1}" "frontmatter lacks omitClaudeMd: true"; fi

	for key in ${AGENT_REQUIRED}; do
		fm_nonempty "${key}"
		(( REPLY )) || emit LNT-66 FAIL "${file}" "${FM_LN:-1}" "required key \"${key}\" is missing or empty"
	done
	pass_unless_seen LNT-66 "${file}" 1 "required keys present: ${AGENT_REQUIRED}"

	fm_get description
	if (( FM_LEN <= 400 )); then emit LNT-67 PASS "${file}" "${FM_LN}" "description ${FM_LEN} chars (<= 400)"
	else emit LNT-67 FAIL "${file}" "${FM_LN}" "description ${FM_LEN} chars (> 400)"; fi

	for key in ${AGENT_KEYS}; do
		fm_get "${key}"
		(( FM_I >= 0 )) || absent+="${absent:+, }${key}"
	done
	emit LNT-71 INFO "${file}" 1 "unset optional fields: ${absent:-none} (defaults apply)"

	records=$(LINT_MODE=agent awk "${LINT_AWK}" "${file}") || awk_failed "scanning the body of ${file}"
	emit_records "${records}"
	body_chars=$(printf '%s\n' "${records}" | awk -F '\t' '$1 == "Z" { print $2 }')
	body_chars=${body_chars:-0}
	if (( body_chars <= 6000 )); then emit LNT-68 PASS "${file}" 0 "body ${body_chars} chars (<= 6,000)"
	else emit LNT-68 FAIL "${file}" 0 "body ${body_chars} chars (> 6,000)"; fi

	check_agent_preloads "${file}" "${body_chars}"
	check_hooks agent "${file}"
	check_secrets "${file}" "${file}"
	seen_by_agent=("${file}" ${PRELOAD_FILES[@]+"${PRELOAD_FILES[@]}"})
	check_schema_mentions "${file}" "${seen_by_agent[@]}"
}

check_agent_frontmatter() {
	local file=$1 i key v
	if (( FM_END == 0 )); then emit LNT-59 FAIL "${file}" 1 "no frontmatter between the first two --- lines"; fi
	frontmatter_parse_findings LNT-59 "${file}"
	for (( i = 0; i < ${#FMK[@]}; i++ )); do
		key=${FMK[i]}; v=${FMVAL[i]}
		if [[ " ${AGENT_KEYS} " != *" ${key} "* ]]; then
			emit LNT-59 FAIL "${file}" "${FML[i]}" "unknown key \"${key}\" (Claude Code ignores it silently)"; continue
		fi
		case "${key}" in
			effort)         [[ "${v}" =~ ^(low|medium|high|xhigh|max)$ ]] || emit LNT-59 FAIL "${file}" "${FML[i]}" "effort \"${v}\" not in low|medium|high|xhigh|max" ;;
			color)          [[ "${v}" =~ ^(red|blue|green|yellow|purple|orange|pink|cyan)$ ]] || emit LNT-59 FAIL "${file}" "${FML[i]}" "color \"${v}\" not in red|blue|green|yellow|purple|orange|pink|cyan" ;;
			model)          [[ "${v}" =~ ^(sonnet|opus|haiku|fable|inherit|claude-[a-z0-9-]+)$ ]] || emit LNT-59 FAIL "${file}" "${FML[i]}" "model \"${v}\" not an alias or a claude-* model ID" ;;
			permissionMode) [[ "${v}" =~ ^(default|acceptEdits|auto|dontAsk|bypassPermissions|plan|manual)$ ]] || emit LNT-59 FAIL "${file}" "${FML[i]}" "permissionMode \"${v}\" not a documented mode" ;;
			isolation)      [[ "${v}" == worktree ]] || emit LNT-59 FAIL "${file}" "${FML[i]}" "isolation \"${v}\" is not worktree" ;;
			memory)         [[ "${v}" =~ ^(user|project|local)$ ]] || emit LNT-59 FAIL "${file}" "${FML[i]}" "memory \"${v}\" not in user|project|local" ;;
			background|omitClaudeMd)
				is_yaml_bool "${v}"
				[[ "${FMKIND[i]}" == plain && "${REPLY}" == 1 ]] || emit LNT-59 FAIL "${file}" "${FML[i]}" "${key} \"${v}\" is not a boolean" ;;
			*) ;;
		esac
	done
	for key in name description; do
		fm_nonempty "${key}"
		(( REPLY )) || emit LNT-59 FAIL "${file}" "${FM_LN:-1}" "${key} is missing or empty"
	done
	pass_unless_seen LNT-59 "${file}" 1 "frontmatter parses; keys and values valid"
}

check_agent_tools() {
	local file=$1 name=$2 stem=$3 item bad=""
	if [[ "${file}" != */agents/reviewers/* && ! "${stem}" =~ -(reviewer|arbiter|grader)$ && ! "${name}" =~ -(reviewer|arbiter|grader)$ ]]; then
		emit LNT-50 PASS "${file}" 1 "not a read-only agent class (N/A)"; return 0
	fi
	fm_nonempty tools
	if (( ! REPLY )); then
		emit LNT-50 FAIL "${file}" "${FM_LN:-1}" "read-only agent names no tools, so it inherits every tool"; return 0
	fi
	fm_list tools
	split_tools "$(printf '%s ' ${FM_LIST[@]+"${FM_LIST[@]}"})"
	for item in ${TOOLS[@]+"${TOOLS[@]}"}; do
		case "${item%%(*}" in Write|Edit|NotebookEdit|Bash) bad+="${bad:+, }${item}" ;; *) ;; esac
	done
	fm_get tools
	if [[ -n "${bad}" ]]; then emit LNT-50 FAIL "${file}" "${FM_LN}" "read-only agent grants ${bad}"
	else emit LNT-50 PASS "${file}" "${FM_LN}" "read-only agent has no write tools"; fi
}

# LNT-36 (each skills: entry resolves) and LNT-69 (body + preloaded bodies).
check_agent_preloads() {
	local file=$1 total=$2 skill chars unresolved="" ln
	PRELOAD_FILES=()
	fm_get skills; ln=${FM_LN:-1}
	fm_list skills
	if [[ ${#FM_LIST[@]} -eq 0 ]]; then
		emit LNT-36 PASS "${file}" "${ln}" "no skills: preloads (N/A)"
	else
		for skill in "${FM_LIST[@]}"; do
			resolve_skill_name "${skill}"
			if [[ -z "${REPLY}" ]]; then
				emit LNT-36 FAIL "${file}" "${ln}" "skills: entry \"${skill}\" resolves to no skill in ${CLAUDE_HOME}/skills or the roots"
				unresolved+="${unresolved:+, }${skill}"; continue
			fi
			PRELOAD_FILES+=("${REPLY}/SKILL.md")
			chars=$(LINT_MODE=bodychars awk "${LINT_AWK}" "${REPLY}/SKILL.md")
			total=$(( total + chars ))
		done
		pass_unless_seen LNT-36 "${file}" "${ln}" "every skills: entry resolves"
	fi
	local msg="body + preloads ${total} chars"
	[[ -z "${unresolved}" ]] || msg+="; unresolved, not counted: ${unresolved}"
	if (( total <= 12000 )); then emit LNT-69 PASS "${file}" 0 "${msg} (<= 12,000)"
	else emit LNT-69 FAIL "${file}" 0 "${msg} (> 12,000)"; fi
}

# ----------------------------------------------------------------- jq code

# LNT-52: top-level payload properties lacking a valid x-writer, one per line.
# shellcheck disable=SC2016  # jq program, single-quoted on purpose
JQ_X_WRITER='
def wok: (if type == "array" then . else [.] end) as $a
  | ($a | length) > 0 and all($a[]; type == "string" and test("^(script|orchestrator|agent:[a-z0-9]+(-[a-z0-9]+)*)$"));
([.] + ((.oneOf // []) + (.anyOf // []) + (.allOf // [])))
| [ .[] | objects | (.properties // {}) | to_entries[]
    | select((.value | type) == "object")
    | select((.value | has("x-writer") | not) or (.value["x-writer"] | wok | not)) | .key ]
| unique | .[]'

# LNT-57: agent-written strings without a bound (S), arrays without maxItems
# (A), external refs not followed (R). Unmarked fields count as agent-written
# while LNT-52 fails ($unmarked == 1).
# shellcheck disable=SC2016  # jq program, single-quoted on purpose
JQ_BOUNDS='
def tlist: (.type // []) | if type == "array" then . else [.] end;
def bounded: test("(^|[^\\\\])[*+]|\\{[0-9]+,\\}") | not;
# Depth caps stop a $ref cycle or a runaway nesting: 32 $ref hops per node
# and 24 nesting levels exceed any real contract (LNT-57).
def deref($root; $d):
  if type == "object" and ((.["$ref"] | type) == "string") and (.["$ref"] | startswith("#/")) and $d < 32 then
    (.["$ref"][2:] | split("/")) as $p | ((($root | getpath($p)) // {}) | deref($root; $d + 1)) as $t
    | ($t + del(.["$ref"]))
  else . end;
def flat($root): deref($root; 0)
  | if (.allOf | type) == "array" then reduce (.allOf[] | deref($root; 0)) as $s (del(.allOf); $s + .) else . end;
def isagent: [.] | flatten | any(.[]; type == "string" and startswith("agent:"));
def walkw($root; $w; $path; $d):
  if $d > 24 or (type != "object") then empty else
  flat($root) as $n
  | ( if ((.["$ref"] | type) == "string") and ((.["$ref"] | startswith("#/")) | not) then "R\t\($path)\t\(.["$ref"])" else empty end ),
    ( if $w and ($n | tlist | index("string")) and
         ((($n | has("maxLength") or has("enum") or has("const")) or ((($n.pattern | type) == "string") and ($n.pattern | bounded))) | not)
      then "S\t\($path)" else empty end ),
    ( if $w and ($n | tlist | index("array")) and ($n | has("maxItems") | not) then "A\t\($path)" else empty end ),
    ( ($n.properties // {}) | to_entries[] | .key as $k | .value as $v
      | (if $d == 0 then (if (($v | type) == "object") and ($v | has("x-writer")) then ($v["x-writer"] | isagent) else $w end) else $w end) as $cw
      | $v | walkw($root; $cw; "\($path)/\($k)"; $d + 1) ),
    ( ($n.items // null) | if type == "object" then walkw($root; $w; "\($path)/items"; $d + 1)
                           elif type == "array" then .[] | walkw($root; $w; "\($path)/items"; $d + 1) else empty end ),
    ( ($n.additionalProperties // null) | objects | walkw($root; $w; "\($path)/additionalProperties"; $d + 1) ),
    ( (($n.oneOf // []) + ($n.anyOf // []))[] | walkw($root; $w; $path; $d) )
  end;
. as $root | walkw($root; ($unmarked == 1); ""; 0)'

# LNT-56: every description (D) and pattern (P) string with its path.
# shellcheck disable=SC2016  # jq program, single-quoted on purpose
JQ_DESCRIPTIONS='
paths(type == "string") as $p
| select(($p[-1] == "description" or $p[-1] == "pattern") and (($p | length) < 2 or $p[-2] != "properties"))
| getpath($p) as $v
| (if $p[-1] == "description" then "D" else "P" end) as $t
| "\($t)\t\($f)\t\($p | map(tostring) | join("/"))\t\($v | length)\t\($v | gsub("[\\t\\n\\r ]+"; " "))"'

# ---------------------------------------------------------------- awk code

# read returns 1 at the end of the heredoc; that is its normal end.
IFS= read -r -d '' LINT_AWK <<'AWK' || true
# ---- shared helpers
function ulen(s) { gsub(/[\200-\277]/, "", s); return length(s) }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function disp(f) { return (STRIP != "" && index(f, STRIP) == 1) ? substr(f, length(STRIP) + 1) : f }
function rec(id, st, f, ln, msg) { gsub(/[\t\r\n]/, " ", msg); printf "R\t%s\t%s\t%s\t%d\t%s\n", id, st, f, ln, msg }
function clip(s, n) { return length(s) > n ? substr(s, 1, n) "..." : s }
function uncomment(v) { v = trim(v); sub(/[ \t]+#.*$/, "", v); return v ~ /^#/ ? "" : v }
function basename(p) { sub(/.*\//, "", p); return p }
function dirname_(p) { if (p !~ /\//) return ""; sub(/\/[^\/]*$/, "", p); return p }
function normpath(p,   n, a, i, out, k, st) {
	n = split(p, a, "/"); k = 0
	for (i = 1; i <= n; i++) {
		if (a[i] == "" || a[i] == ".") continue
		if (a[i] == "..") { if (k > 0) k--; else st[++k] = ".."; continue }
		st[++k] = a[i]
	}
	out = ""; for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") st[i]
	return out
}
function scalar(v,   q, k) {
	v = trim(v); q = substr(v, 1, 1)
	if (q == "\"" || q == "\047") { k = qclose(v, q); return k ? unq(substr(v, 2, k - 2), q) : substr(v, 2) }
	return uncomment(v)
}
function qclose(v, q,   j, c, n) {
	n = length(v)
	for (j = 2; j <= n; j++) {
		c = substr(v, j, 1)
		if (q == "\"" && c == "\\") { j++; continue }
		if (c == q) { if (q == "\047" && substr(v, j + 1, 1) == q) { j++; continue } return j }
	}
	return 0
}
function unq(s, q) { if (q == "\047") gsub(/\047\047/, "\047", s); else { gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s) } return s }
function rep(s, n,   r) { r = ""; while (n-- > 0) r = r s; return r }

# Line classes for Markdown: "fm" (frontmatter), "fence" (a fence line),
# "code" (inside a fence) or "text". State resets on each file's line 1.
function classify(l, ln,   t, m) {
	if (ln == 1) { in_fm = 0; fence = ""; fence_info = ""; in_html = 0; body_start = 1; if (l ~ /^---[ \t]*$/) { in_fm = 1; return "fm" } }
	if (in_fm) { if (l ~ /^---[ \t]*$/) { in_fm = 0; body_start = ln + 1 } return "fm" }
	if (fence != "") {
		t = trim(l)
		if (index(t, fence) == 1 && t ~ /^(`+|~+)$/) { fence = ""; return "fence" }
		return "code"
	}
	if (match(l, /^[ \t]*(```+|~~~+)/)) {
		m = trim(substr(l, RSTART, RLENGTH)); fence = m
		fence_info = trim(substr(l, RSTART + RLENGTH)); return "fence"
	}
	return "text"
}
function strip_spans(l) { gsub(/``[^`]+``/, " ", l); gsub(/`[^`]*`/, " ", l); return l }
function strip_html(l,   k, out) {
	out = ""
	while (l != "") {
		if (in_html) { k = index(l, "-->"); if (!k) return out; l = substr(l, k + 3); in_html = 0; continue }
		k = index(l, "<!--"); if (!k) return out l
		out = out substr(l, 1, k - 1); l = substr(l, k + 4); in_html = 1
	}
	return out
}
function heading_level(l,   m) { if (match(l, /^#+[ \t]/)) return RLENGTH - 1; if (l ~ /^#+$/) return length(l); return 0 }

# ---- LNT-70 sentence statistics (shared by md and agent modes)
function sent_reset() { ns = 0; s_words = 0; delete sc }
function sent_flush() { if (s_words > 0) sc[++ns] = s_words; s_words = 0 }
function sent_add(text,   n, w, i, tok, lw) {
	n = split(text, w, /[ \t]+/)
	for (i = 1; i <= n; i++) {
		tok = w[i]
		if (tok == "") continue
		if (tok ~ /[A-Za-z0-9\200-\377]/) s_words++
		if (tok ~ /[.!?][\042\047)\]*_]*$/) {
			lw = tolower(tok); gsub(/^[(\042\047\[*_]+/, "", lw); sub(/[\042\047)\]*_]+$/, "", lw)
			if (lw !~ /^(e\.g\.|i\.e\.|etc\.|vs\.)$/) sent_flush()
		}
	}
}
# Feeds one classified line to the sentence splitter.
function sent_line(l, c,   x) {
	if (c != "text") { sent_flush(); return }
	x = strip_html(l)
	if (heading_level(x) || x ~ /^[ \t]*\|/ || trim(x) == "") { sent_flush(); return }
	x = strip_spans(x)
	sub(/^[ \t]*(>[ \t]*)+/, "", x)
	if (x ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/) { sent_flush(); sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", x) }
	sent_add(x)
}
function sent_report(f,   i, j, t, med) {
	sent_flush()
	for (i = 2; i <= ns; i++) { t = sc[i]; for (j = i - 1; j >= 1 && sc[j] > t; j--) sc[j + 1] = sc[j]; sc[j + 1] = t }
	med = ns == 0 ? 0 : (ns % 2 ? sc[(ns + 1) / 2] : (sc[ns / 2] + sc[ns / 2 + 1]) / 2)
	rec("LNT-70", "INFO", f, 0, sprintf("median sentence %s words over %d sentences", med, ns))
	if (med > 25) rec("LNT-70", "FAIL", f, 0, sprintf("median sentence %s words (> 25)", med))
	else rec("LNT-70", "PASS", f, 0, sprintf("median sentence %s words (<= 25)", med))
}

BEGIN {
	mode = ENVIRON["LINT_MODE"]; STRIP = ENVIRON["LINT_STRIP"]
	QO = ENVIRON["LINT_QUOTE_OPENING"]; QC = ENVIRON["LINT_CANON_QUOTE"]; sub(/[ \t]+$/, "", QC)
	if (mode == "md") md_begin_run()
	if (mode == "secrets") nsecret = 0
	# LNT-28 patterns are assembled from fragments so this file's own source
	# never matches them.
	I_READ = "(^|[^A-Za-z0-9_])re" "ad[ \t]+(-[A-Za-z]+[ \t]+)*-[A-Za-z]*[ps]"
	I_SELECT = "(^|[^A-Za-z0-9_])sel" "ect[ \t].*[ \t]in([ \t]|$)"
	I_CALL = "(^|[^A-Za-z0-9_.])(inp" "ut|pro" "mpt|con" "firm)[(]"
	I_TTY = "/dev/" "tty"; I_GETPASS = "get" "pass"; I_READLINE = "readline." "createInterface"
}
{ sub(/\r$/, "") }
mode == "canon"      { canon_line(); next }
mode == "levels"     { lv_line(); next }
mode == "fm"         { fl[NR] = $0; next }
mode == "hooks"      { fl[NR] = $0; next }
mode == "agent"      { lines[NR] = $0; next }
mode == "md"         { md_line(); next }
mode == "scripts"    { sc_line(); next }
mode == "hookscript" { hs_line(); next }
mode == "secrets"    { se_line(); next }
mode == "preloads"   { pl_line(); next }
mode == "bodychars"  { bc_line(); next }
mode == "chars"      { nchars += ulen($0) + 1; next }
mode == "bounds"     { bd_line(); next }
mode == "descriptions" { ds_line(); next }
END {
	if (mode == "canon") canon_end()
	else if (mode == "fm") fm_parse()
	else if (mode == "hooks") hk_parse()
	else if (mode == "agent") ag_end()
	else if (mode == "md") md_end()
	else if (mode == "scripts") sc_finish()
	else if (mode == "hookscript") hs_end()
	else if (mode == "bodychars") print bchars + 0
	else if (mode == "chars") print nchars + 0
	else if (mode == "orphans") orphans()
	else if (mode == "firstperson") firstperson()
	else if (mode == "descriptions") ds_end()
}

# ---- canon: the "> "-quoted paragraph under "## Canonical blocks" opening
# with the words in env var $LINT_OPENING_VAR.
function canon_line() {
	if ($0 ~ /^## /) { in_canon = ($0 ~ /^## Canonical blocks/); return }
	if (!in_canon || found_canon) return
	if ($0 ~ /^> /) { para = (para == "" ? "" : para "\n") substr($0, 3); return }
	if (index(para, ENVIRON[ENVIRON["LINT_OPENING_VAR"]]) == 1) { print para; found_canon = 1 }
	para = ""
}
function canon_end() { if (!found_canon && index(para, ENVIRON[ENVIRON["LINT_OPENING_VAR"]]) == 1) print para }

# ---- levels: "ID<TAB>LEVEL" for every lint-spec item line.
function lv_line(   t, id, level) {
	if ($0 !~ /^[ \t]*- \*\*LNT-[0-9]+\*\* · (MUST|SHOULD|MAY|INFO) ·/) return
	t = $0; sub(/^[ \t]*- \*\*/, "", t)
	id = t; sub(/\*\*.*/, "", id)
	level = t; sub(/^LNT-[0-9]+\*\* · /, "", level); sub(/ .*/, "", level)
	printf "%s\t%s\n", id, level
}

# ---- LNT-60 quote-safely line: "" when line l is not one or is canonical,
# else the mismatch message.
function quote_diff(l,   d) {
	sub(/^[ \t]+/, "", l); sub(/[ \t]+$/, "", l)
	if (QO == "" || index(l, QO) != 1 || l == QC) return ""
	d = first_diff(l, QC)
	return "quote-safely line differs from canonical at byte " d ": \"" substr(l, (d > 10 ? d - 10 : 1), 40) "\""
}

# ---- fm: frontmatter subset parser. Records:
#   X fm_end nlines | K key line kind len value | L key line item
#   M key line child kind | E line message
function perr(ln, msg) { printf "E\t%d\t%s\n", ln, msg }
function fm_parse(   i, l, t, key, rest, end_) {
	if (fl[1] ~ /^---[ \t]*$/) for (i = 2; i <= NR; i++) if (fl[i] ~ /^---[ \t]*$/) { end_ = i; break }
	printf "X\t%d\t%d\n", end_ + 0, NR
	if (!end_) return
	key = ""
	for (i = 2; i < end_; i++) {
		l = fl[i]; t = trim(l)
		if (l ~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:([ \t]|$)/) {
			fm_flush(key)
			key = l; sub(/[ \t]*:.*/, "", key); rest = l; sub(/^[^:]*:/, "", rest)
			if (key in kline) perr(i, "duplicate key " key)
			kline[key] = i
			fm_start(key, rest, i)
			continue
		}
		if (t == "") { if (kkind[key] == "block") bl[key, ++bn[key]] = ""; continue }
		if (t ~ /^#/ && kkind[key] != "block") continue
		if (key == "" || l !~ /^[ \t]/ && l !~ /^- /) { perr(i, "unparseable frontmatter line"); continue }
		fm_cont(key, l, t, i)
	}
	fm_flush(key)
}
function plain_check(v, ln) {
	if (v ~ /: / || v ~ /:$/) perr(ln, "plain scalar contains \": \"; quote the value")
	if (v ~ /^[`@]/) perr(ln, "plain scalar starts with a reserved indicator (` or @); quote the value")
}
function fm_start(key, rest, ln,   v, q, k, after, inner, n, it, j) {
	v = trim(rest)
	if (v == "" || v ~ /^#/) { kkind[key] = "empty"; kval[key] = ""; return }
	q = substr(v, 1, 1)
	if (v ~ /^[|>][-+0-9]*([ \t]+#.*)?$/) {
		kkind[key] = "block"; bstyle[key] = q; bn[key] = 0; bind[key] = -1
		bchomp[key] = (v ~ /^.[0-9]*-/) ? "strip" : ((v ~ /^.[0-9]*\+/) ? "keep" : "clip")
		return
	}
	if (q == "\"" || q == "\047") {
		k = qclose(v, q)
		if (k) {
			kkind[key] = "quoted"; kval[key] = unq(substr(v, 2, k - 2), q)
			after = trim(substr(v, k + 1)); if (after != "" && after !~ /^#/) perr(ln, "text after the closing quote")
		} else { kkind[key] = "qopen"; kq[key] = q; kval[key] = substr(v, 2) }
		return
	}
	if (q == "[") {
		kkind[key] = "flow"; kval[key] = v
		if (v !~ /\][ \t]*(#.*)?$/) { perr(ln, "unterminated flow sequence"); return }
		inner = v; sub(/^\[/, "", inner); sub(/\][ \t]*(#.*)?$/, "", inner)
		n = split(inner, it, ",")
		for (j = 1; j <= n; j++) { it[j] = scalar(it[j]); if (it[j] != "") printf "L\t%s\t%d\t%s\n", key, ln, it[j] }
		return
	}
	if (q == "{") { kkind[key] = "flow"; kval[key] = v; return }
	v = uncomment(v); kkind[key] = "plain"; kval[key] = v; plain_check(v, ln)
}
function fm_cont(key, l, t, ln,   k, ind, item, ck, cv, p) {
	k = kkind[key]; ind = match(l, /[^ \t]/) - 1
	if (k == "block") { if (bind[key] < 0) bind[key] = ind; bl[key, ++bn[key]] = substr(l, bind[key] + 1); return }
	if (k == "qopen") {
		p = qclose(kq[key] t, kq[key])
		if (p) { kval[key] = unq(kval[key] " " substr(t, 1, p - 2), kq[key]); kkind[key] = "quoted" }
		else kval[key] = kval[key] " " t
		return
	}
	if (k == "plain") { t = uncomment(t); kval[key] = kval[key] " " t; plain_check(t, ln); return }
	if (k == "empty" || k == "list" || k == "map") {
		if (t ~ /^-([ \t]|$)/) {
			if (lind[key] == "") lind[key] = ind
			if (ind != lind[key] || k == "map") return
			kkind[key] = "list"; item = trim(substr(t, 2))
			item = (item ~ /^["\047]/) ? scalar(item) : uncomment(item)
			kval[key] = kval[key] (kval[key] == "" ? "" : ", ") item
			printf "L\t%s\t%d\t%s\n", key, ln, item
			return
		}
		if (t ~ /^[A-Za-z0-9_"\047-][^:]*:([ \t]|$)/) {
			if (k == "list") return
			if (cind[key] == "") cind[key] = ind
			if (ind != cind[key]) return
			kkind[key] = "map"; kval[key] = "{map}"
			ck = t; sub(/[ \t]*:.*/, "", ck); gsub(/["\047]/, "", ck)
			cv = t; sub(/^[^:]*:/, "", cv); cv = uncomment(cv)
			printf "M\t%s\t%d\t%s\t%s\n", key, ln, ck, (cv == "" ? "nested" : (cv ~ /^[\[{]/ ? "flow" : "scalar"))
			return
		}
		if (k == "empty") perr(ln, "unparseable frontmatter line")
		return
	}
	perr(ln, "unexpected continuation line")
}
function fm_fold(key,   n, j, x, s, nlc, total) {
	total = bn[key]; n = total
	while (n > 0 && bl[key, n] == "") n--
	s = ""; nlc = 0
	for (j = 1; j <= n; j++) {
		x = bl[key, j]
		if (bstyle[key] == "|") { s = (j == 1 ? x : s "\n" x); continue }
		if (x == "") { nlc++; continue }
		if (s != "") s = s (nlc ? rep("\n", nlc) : " ")
		s = s x; nlc = 0
	}
	if (s != "" && bchomp[key] != "strip") s = s "\n"
	if (s != "" && bchomp[key] == "keep") s = s rep("\n", total - n)
	return s
}
function fm_flush(key,   v, vv) {
	if (key == "") return
	if (kkind[key] == "qopen") { perr(kline[key], "unterminated quoted scalar"); kkind[key] = "quoted" }
	v = (kkind[key] == "block") ? fm_fold(key) : kval[key]
	vv = v; gsub(/\t/, " ", vv); gsub(/\n/, "\036", vv)
	printf "K\t%s\t%d\t%s\t%d\t%s\n", key, kline[key], kkind[key], ulen(v), vv
}

# ---- firstperson: LNT-14 on the description in $LINT_TEXT.
function firstperson(   d, lo, hits, re) {
	d = ENVIRON["LINT_TEXT"]
	gsub(/\342\200\234[^\342]*\342\200\235/, " ", d)
	gsub(/"[^"]*"/, " ", d); gsub(/`[^`]*`/, " ", d)
	gsub(/(^|[ (\[])\047[^\047]*\047/, " ", d)
	lo = " " tolower(d) " "
	gsub(/(^|[^a-z])i\.e\./, " ", lo)
	hits = ""
	if (lo ~ /[^a-z0-9_]i[^a-z0-9_\/]/) hits = hits " I"
	if (lo ~ /[^a-z0-9_]i\047(m|ll|ve)[^a-z0-9_]/) hits = hits " I'm/I'll/I've"
	if (lo ~ /[^a-z0-9_]my[^a-z0-9_]/) hits = hits " my"
	if (lo ~ /[^a-z0-9_]we[^a-z0-9_]/) hits = hits " we"
	if (lo ~ /[^a-z0-9_]our[^a-z0-9_]/) hits = hits " our"
	if (lo ~ /[^a-z0-9_]you can[^a-z0-9_]/) hits = hits " \"you can\""
	if (lo ~ /[^a-z0-9_]you could[^a-z0-9_]/) hits = hits " \"you could\""
	if (hits != "") rec("LNT-14", "FAIL", disp(ENVIRON["LINT_FILE"]), ENVIRON["LINT_LINE"], "description is not third person:" hits)
}

# ---- md: one pass over SKILL.md (first) and the other .md files.
function md_begin_run(   n, a, i) {
	SKD = ENVIRON["LINT_SKILL_DIR"]; SKMD = ENVIRON["LINT_SKILL_MD"]; TOPDIRS = " " ENVIRON["LINT_TOPDIRS"] " "
	PRE = ENVIRON["LINT_PRELOADED"] + 0; BLKDIR = ENVIRON["LINT_BLKDIR"]
	n = split(ENVIRON["LINT_MDFILES"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") mdset[a[i]] = 1
	nargs = split(ENVIRON["LINT_ARGNAMES"], argn, " ")
	grep_lines = ""
}
function md_file_begin() {
	cur = FILENAME; isk = (cur == SKMD); rel = substr(cur, length(SKD) + 2); reldir = dirname_(rel)
	bchars = 0; blines = 0; nonhead = 0; words = 0; caps = 0; words_all = 0
	inv_found = 0; inv_lvl = 0; inv_end = -1; inv_line = 0
	exempt_lvl = 0; nhead = 0; nbul = 0; contents_head = 0; capturing = 0; bang_fence = 0; prev_nb = ""
	delete hd_line; delete hd_text; delete bul_line; delete bul_text
	sent_reset()
}
function md_line(   l, c, lvl, x, prose, lo, tk, n, i) {
	if (FNR == 1) { if (cur != "") md_file_end(); md_file_begin() }
	l = $0; flines = FNR; c = classify(l, FNR)
	if (c == "fm") return
	if (isk) { blines++; line_off = bchars; bchars += ulen(l) + 1; if (l ~ /grep/) grep_lines = grep_lines "\n" l }
	n = split(l, tk, /[ \t]+/); for (i = 1; i <= n; i++) if (tk[i] ~ /[A-Za-z0-9]/) words_all++
	lnt20(l); if (isk) lnt21(l); lnt30(l); lnt43(l)
	sent_line(l, c)
	if (c == "fence") { md_fence(); return }
	if (c == "code") { md_code(l); prev_nb = l; return }
	if ((x = quote_diff(l)) != "") rec("LNT-60", "FAIL", disp(cur), FNR, x)
	lvl = heading_level(l)
	x = l
	if (isk && trim(l) != "" && !lvl) nonhead++
	if (lvl) md_heading(l, lvl)
	# LNT-19: a contents list must sit in the first 20 lines.
	if (!isk && FNR <= 20 && l ~ /^[ \t]*[-*+][ \t]+/) { bul_line[++nbul] = FNR; bul_text[nbul] = tolower(l) }
	if (!isk) lnt18(l)
	lnt37_spans(l)
	if (isk && l ~ /(^|[ \t])!`[^`]+`/) md_bang_inline(l)
	if (PRE && index(l, "${CLAUDE_SKILL_DIR}") && l !~ /(^|[ \t])!`/) rec("LNT-37", "FAIL", disp(cur), FNR, "${CLAUDE_SKILL_DIR} in a preloaded skill outside a ! line")
	prose = strip_spans(l)
	if (isk && !lvl) lnt23(prose)
	if (!exempt_lvl) lnt24(prose)
	if (trim(l) != "") prev_nb = l
}
function md_heading(l, lvl,   t) {
	t = tolower(l); sub(/^#+[ \t]*/, "", t); t = trim(t)
	hd_line[++nhead] = FNR; hd_text[nhead] = t
	if (FNR <= 20 && t ~ /contents/) contents_head = 1
	if (exempt_lvl && lvl <= exempt_lvl) exempt_lvl = 0
	if (t ~ /old patterns|version|ledger|changelog/) exempt_lvl = lvl
	if (!isk) return
	if (inv_found && inv_end < 0 && lvl <= inv_lvl) inv_end = line_off
	if (!inv_found && t ~ /^([0-9]+\.[ \t]*)?(invariants|constraints)([^a-z0-9_]|$)/) { inv_found = 1; inv_lvl = lvl; inv_line = FNR }
}
function md_fence(   tag) {
	if (fence == "") {
		if (capturing) { close(blkf); printf "C\t%s\t%s\t%d\t%s\n", blk_tag, cur, blk_line, blkf; capturing = 0 }
		bang_fence = 0; return
	}
	bang_fence = (fence_info ~ /^!/)
	tag = tolower(fence_info); sub(/[ \t{].*/, "", tag)
	if (BLKDIR != "" && tag ~ /^(json|yaml|yml|bash|sh|shell|python|py)$/ && fence_info !~ /illustrative/ && prev_nb !~ /<!--.*illustrative/) {
		blkf = BLKDIR "/b" (++nblk); blk_tag = tag; blk_line = FNR; capturing = 1; printf "" > blkf
	}
}
function md_code(l,   t) {
	if (capturing) print l > blkf
	t = trim(l)
	if (bang_fence && isk) { if (t != "") printf "B\t%s\t%d\t%s\n", cur, FNR, t; return }
	if (lnt37_cmd(t, 1)) rec("LNT-37", "FAIL", disp(cur), FNR, "command runs " clip(t, 60) " relative to the cwd; use $HOME/.claude/skills/<name>/scripts/")
	if (PRE && index(l, "${CLAUDE_SKILL_DIR}")) rec("LNT-37", "FAIL", disp(cur), FNR, "${CLAUDE_SKILL_DIR} in a preloaded skill outside a ! line")
}
function md_bang_inline(l,   s, c) {
	s = l
	while (match(s, /(^|[ \t])!`[^`]+`/)) {
		c = substr(s, RSTART, RLENGTH); sub(/^[ \t]*!`/, "", c); sub(/`$/, "", c)
		printf "B\t%s\t%d\t%s\n", cur, FNR, trim(c)
		s = substr(s, RSTART + RLENGTH)
	}
}
function md_file_end(   i, j, hits, tok) {
	if (capturing) { close(blkf); printf "C\t%s\t%s\t%d\t%s\n", blk_tag, cur, blk_line, blkf; capturing = 0 }
	sent_report(disp(cur))
	if (isk) {
		tok = int((bchars + 3) / 4)  # LNT-15: tokens = ceil(chars / 4) (lint-spec Terms)
		rec("LNT-15", tok <= 5000 ? "PASS" : "FAIL", disp(cur), 0, sprintf("body %d tokens (%d chars; limit 5,000 tokens)", tok, bchars))
		rec("LNT-16", blines <= 500 ? "PASS" : "FAIL", disp(cur), 0, sprintf("body %d lines (limit 500)", blines))
		if (nonhead < 1) rec("LNT-49", "FAIL", disp(cur), 0, "body has no non-heading text line")
		rec("LNT-23", (words && caps * 100 / words > 1) ? "FAIL" : "PASS", disp(cur), 0, sprintf("%d emphasis caps in %d words = %.2f per 100 (limit 1)", caps, words, words ? caps * 100 / words : 0))
		if (inv_found && inv_end < 0) inv_end = bchars
		if (bchars <= 20000) rec("LNT-25", "PASS", disp(cur), inv_line, sprintf("body %d chars (<= 20,000)", bchars))
		else if (!inv_found) rec("LNT-25", "FAIL", disp(cur), 0, sprintf("body %d chars (> 20,000) with no Invariants/Constraints heading", bchars))
		else rec("LNT-25", inv_end <= 20000 ? "PASS" : "FAIL", disp(cur), inv_line, sprintf("Invariants/Constraints section ends at char %d (limit 20,000)", inv_end))
		return
	}
	if (flines > 100 && !contents_head) {
		hits = 0
		for (i = 1; i <= nbul; i++) for (j = 1; j <= nhead; j++)
			if (hd_line[j] > bul_line[i] && hd_text[j] != "" && index(bul_text[i], hd_text[j])) { hits++; break }
		if (hits < 3) rec("LNT-19", "FAIL", disp(cur), 1, sprintf("%d lines and no contents list in the first 20 lines", flines))
	}
	if (words_all > 10000 && !md_grep_names(basename(cur))) rec("LNT-26", "FAIL", disp(cur), 0, sprintf("%d words and no grep pattern naming it in SKILL.md", words_all))
}
function md_grep_names(b) { return index(grep_lines, b) > 0 }
function md_end() { if (cur != "") md_file_end() }

function lnt20(l,   n, tk, i, t) {
	n = split(l, tk, /[ \t`"\047(),;<>\[\]]+/)
	for (i = 1; i <= n; i++) {
		t = tk[i]
		if (!index(t, "\\") || t !~ /^([A-Za-z0-9_.-]+\\)+[A-Za-z0-9_.-]+$/ || t ~ /\\[^A-Za-z0-9_]/) continue
		if (t ~ /\.(sh|py|js|ts|md|json|jq|yaml)$/ || t ~ /^(scripts|references|assets|examples|lib)\\/)
			rec("LNT-20", "FAIL", disp(cur), FNR, "backslash path separator in " t)
	}
}
function lnt21(l,   s, p, off, nxt, hit, j, bs, a, exempt) {
	exempt = (!PRE && index(l, "<!-- lint: placeholder -->"))
	s = l; off = 0
	while ((p = index(s, "$")) > 0) {
		nxt = substr(s, p + 1); hit = ""
		if (nxt ~ /^[0-9]/) hit = "$" substr(nxt, 1, 1)
		else if (nxt ~ /^ARGUMENTS([^A-Za-z0-9_]|$)/) hit = "$ARGUMENTS"
		else for (a = 1; a <= nargs; a++) if (argn[a] != "" && index(nxt, argn[a]) == 1 && substr(nxt, length(argn[a]) + 1, 1) !~ /[A-Za-z0-9_]/) { hit = "$" argn[a]; break }
		if (hit != "" && !exempt) {
			bs = 0; j = off + p - 1
			while (j >= 1 && substr(l, j, 1) == "\\") { bs++; j-- }
			if (bs != 1) rec("LNT-21", "FAIL", disp(cur), FNR, hit " is substituted at load" (PRE ? " (preloaded skill: blanked)" : "") "; escape a literal as \\" hit)
		}
		off += p; s = substr(s, p + 1)
	}
}
function p30(kind, path, ln) {
	if (path == "" || ((ln, path) in seen30)) return
	seen30[ln, path] = 1
	printf "P\t%s\t%s\t%d\t%s\n", kind, cur, ln, path
}
function lnt30(l,   s, tgt, n, tk, i, t, u, first) {
	s = strip_spans(l)
	while (match(s, /\]\([^)]+\)/)) {
		tgt = trim(substr(s, RSTART + 2, RLENGTH - 3)); s = substr(s, RSTART + RLENGTH)
		sub(/^</, "", tgt); sub(/>$/, "", tgt); sub(/[ \t]+".*$/, "", tgt)
		if (tgt ~ /^(https?:|mailto:|#|\/|~|\$)/ || index(tgt, "://")) continue
		sub(/#.*$/, "", tgt)
		p30("link", tgt, FNR)
	}
	n = split(l, tk, /[ \t`"\047()\[\]]+/)
	for (i = 1; i <= n; i++) {
		t = tk[i]
		sub(/[.,;:!?]+$/, "", t); sub(/:[0-9]+(-[0-9]+)?$/, "", t); sub(/#[A-Za-z0-9_-]*$/, "", t)
		if (index(t, "${CLAUDE_SKILL_DIR}/") == 1) { p30("skilldir", substr(t, 21), FNR); continue }
		if (match(t, /^(\$HOME|\$\{HOME\}|~)\/\.claude\/skills\//)) { p30("named", substr(t, RLENGTH + 1), FNR); continue }
		u = t; sub(/^\.\//, "", u)
		if (!index(u, "/")) continue
		first = u; sub(/\/.*/, "", first)
		if (first != "" && index(TOPDIRS, " " first " ")) p30("rel", u, FNR)
	}
}
function lnt43(l,   n, tk, i, t) {
	n = split(l, tk, /[ \t`"\047()\[\],;]+/)
	for (i = 1; i <= n; i++) {
		t = tk[i]; sub(/[.:!?]+$/, "", t)
		if (t ~ /^[A-Z][A-Za-z0-9-]*:[a-z][a-z0-9]*(_[a-z0-9]+)+$/) rec("LNT-43", "FAIL", disp(cur), FNR, "MCP tool written " t "; use mcp__<server>__<tool>")
	}
}
function lnt18(l,   s, tgt, n, tk, i, t, cand, nc, r1, r2, j, seen) {
	nc = 0; s = strip_spans(l)
	while (match(s, /\]\([^)]+\)/)) { tgt = trim(substr(s, RSTART + 2, RLENGTH - 3)); s = substr(s, RSTART + RLENGTH); sub(/#.*$/, "", tgt); if (tgt ~ /\.md$/) cand[++nc] = tgt }
	n = split(l, tk, /[ \t`"\047()\[\],;]+/)
	for (i = 1; i <= n; i++) { t = tk[i]; sub(/[.,;:!?]+$/, "", t); sub(/#.*$/, "", t); if (t ~ /\.md$/) cand[++nc] = t }
	for (j = 1; j <= nc; j++) {
		t = cand[j]
		if (t ~ /[<>*{}]/ || basename(t) == "SKILL.md" || t ~ /^(https?:|\/|~|\$)/ || (t in seen)) continue
		seen[t] = 1
		r1 = normpath((reldir == "" ? "" : reldir "/") t); r2 = normpath(t)
		if (((r1 in mdset) && r1 != rel) || ((r2 in mdset) && r2 != rel && r2 != "SKILL.md"))
			rec("LNT-18", "FAIL", disp(cur), FNR, "reference points to another reference: " t)
	}
}
# A fenced line starting scripts/ is a command; an inline span is one only
# with an interpreter or arguments, else it is a path mention.
function lnt37_cmd(t, fenced) {
	sub(/^\$[ \t]+/, "", t)
	if (t ~ /^(bash|sh|zsh|python3?|node|ruby|perl|deno|bun)[ \t]+(\.\/)?scripts\//) return 1
	if (t ~ /^(\.\/)?scripts\// && (fenced || t ~ /[ \t]/)) return 1
	return 0
}
function lnt37_spans(l,   s, c) {
	s = l
	while (match(s, /`[^`]+`/)) {
		c = trim(substr(s, RSTART + 1, RLENGTH - 2)); s = substr(s, RSTART + RLENGTH)
		if (lnt37_cmd(c, 0)) rec("LNT-37", "FAIL", disp(cur), FNR, "command runs " clip(c, 60) " relative to the cwd; use $HOME/.claude/skills/<name>/scripts/")
	}
}
function lnt23(x,   n, w, i, t) {
	n = split(x, w, /[ \t]+/)
	for (i = 1; i <= n; i++) {
		if (w[i] !~ /[A-Za-z0-9]/) continue
		words++; t = w[i]; gsub(/[^A-Za-z]/, "", t)
		if (t ~ /^(MUST|NEVER|ALWAYS|ONLY|NOT|NO|CRITICAL|IMPORTANT|REQUIRED)$/) caps++
	}
}
function lnt24(x,   lo, what) {
	what = ""
	if (match(x, /(^|[^A-Za-z])([Aa]s of|[Bb]efore|[Aa]fter|[Uu]ntil|[Ss]ince)[ \t]+(January|February|March|April|May|June|July|August|September|October|November|December|20[0-9][0-9])/)) what = trim(substr(x, RSTART, RLENGTH))
	lo = tolower(x)
	if (what == "" && match(lo, /(^|[^a-z])(currently|recently|nowadays|new in)([^a-z]|$)/)) what = trim(substr(x, RSTART, RLENGTH))
	if (what == "" && match(x, /(^|[^0-9])[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]([^0-9]|$)/)) what = trim(substr(x, RSTART, RLENGTH))
	if (what != "") rec("LNT-24", "FAIL", disp(cur), FNR, "time-sensitive wording: " clip(what, 40))
}

# ---- agent: LNT-60, LNT-61, LNT-70 and the body size (Z record).
function ag_end(   i, fm_end, c, bchars) {
	F = disp(FILENAME)
	if (lines[1] ~ /^---[ \t]*$/) for (i = 2; i <= NR; i++) if (lines[i] ~ /^---[ \t]*$/) { fm_end = i; break }
	UO = ENVIRON["LINT_UNTRUSTED_OPENING"]; SO = ENVIRON["LINT_SECRET_OPENING"]
	ag_fm_end = fm_end + 0
	sent_reset(); bchars = 0
	for (i = 1; i <= NR; i++) {
		c = classify(lines[i], i)
		if (i > ag_fm_end) bchars += ulen(lines[i]) + 1
		if (c != "fm" && i > ag_fm_end) sent_line(lines[i], c)
	}
	printf "Z\t%d\n", bchars
	sent_report(F)
	check_blocks(); check_ask()
}
function check_blocks() {
	check_block(UO, ENVIRON["LINT_CANON_UNTRUSTED"], "untrusted")
	check_block(SO, ENVIRON["LINT_CANON_SECRET"], "secret")
	check_quote_lines()
	if (bfail != "") rec("LNT-60", "FAIL", F, bfail_line, bfail)
	else if (bwarn != "") rec("LNT-60", "WARN", F, first_copy["untrusted"], bwarn)
	else rec("LNT-60", "PASS", F, first_copy["untrusted"], "both canonical blocks verbatim; every quote-safely line canonical (or none)")
}
function check_quote_lines(   i, msg) {
	for (i = ag_fm_end + 1; i <= NR; i++) if ((msg = quote_diff(lines[i])) != "") block_fail(i, msg)
}
# Both canonical blocks are one line, so a non-blank line directly below a
# copy means the block was extended.
function check_block(opening, canon, kind,   i, l, want, got, d, copies) {
	want = strip_slot(kind, canon)
	for (i = ag_fm_end + 1; i <= NR; i++) {
		l = lines[i]; sub(/^[ \t>*+-]+/, "", l)
		if (index(l, opening) != 1) continue
		if (!copies++) first_copy[kind] = i
		if (i < NR && lines[i + 1] !~ /^[ \t]*$/) { block_fail(i, kind " block at line " i " continues on line " (i + 1)); continue }
		got = strip_slot(kind, l)
		if (got == want) continue
		d = first_diff(got, want)
		block_fail(i, kind " block at line " i " differs from canonical at byte " d ": \"" substr(got, (d > 10 ? d - 10 : 1), 40) "\"")
	}
	if (!copies) block_fail(1, kind " block missing (opening \"" opening "\" not found)")
	else if (copies > 1) bwarn = bwarn (bwarn == "" ? "" : "; ") kind " block appears " copies " times"
}
function block_fail(ln, msg) { if (bfail == "") bfail_line = ln; bfail = bfail (bfail == "" ? "" : "; ") msg }
function strip_slot(kind, s,   rest, k, i) {
	if (kind == "untrusted") { rest = substr(s, length(UO) + 1); k = index(rest, " — "); return k ? UO substr(rest, k) : "" }
	sub(/[ \t]+$/, "", s)
	for (i = 1; i <= length(s) - 1; i++) if (substr(s, i, 2) == ". ") k = i
	return k ? substr(s, 1, k) : s
}
function first_diff(a, b,   i) { for (i = 1; i <= length(a) && substr(a, i, 1) == substr(b, i, 1); i++); return i }
function check_ask(   i, hits, first_hit) {
	ntok = split("AskUserQuestion EnterPlanMode ExitPlanMode ScheduleWakeup Workflow(", tok, " ")
	nphr = split("ask the user|ask the human|ask the owner|confirm with the user", phr, "|")
	for (i = ag_fm_end + 1; i <= NR; i++) if (unexempted_hit(lines[i]) && !hits++) first_hit = i
	if (hits) rec("LNT-61", "FAIL", F, first_hit, hits " line(s) use a main-thread-only tool or ask the user; first at this line")
	else rec("LNT-61", "PASS", F, ag_fm_end + 1, "no main-thread-only tool or ask-the-user phrase")
}
function unexempted_hit(l,   lo, j) {
	lo = tolower(l)
	for (j = 1; j <= ntok; j++) if (hit_in(l, l, tok[j])) return 1
	for (j = 1; j <= nphr; j++) if (hit_in(lo, l, phr[j])) return 1
	return 0
}
function hit_in(hay, l, pat,   off, k) {
	while ((k = index(substr(hay, off + 1), pat)) > 0) { off += k; if (!negated(substr(l, 1, off - 1))) return 1 }
	return 0
}
# A hit inside a quoted forbidding rule is exempt: never, not, no or dont is
# one of the 4 words before it in the same clause.
function negated(pre,   n, w, i, k, seen) {
	if (match(pre, /.*[.,;:!?()]/)) pre = substr(pre, RLENGTH + 1)
	if (match(pre, /.*\342\200\224/)) pre = substr(pre, RLENGTH + 1)
	n = split(tolower(pre), w, /[ \t]+/)
	for (i = n; i >= 1 && seen < 4; i--) {
		k = w[i]; gsub(/[^a-z]/, "", k)
		if (k == "") continue
		seen++
		if (k ~ /^(never|not|dont|no)$/) return 1
	}
	return 0
}

# ---- bodychars: chars of a file after its frontmatter.
function bc_line() {
	if (FNR == 1 && $0 ~ /^---[ \t]*$/) { bc_fm = 1; return }
	if (bc_fm) { if ($0 ~ /^---[ \t]*$/) bc_fm = 0; return }
	bchars += ulen($0) + 1
}

# ---- preloads: "A<TAB>file<TAB>skill" for every agent skills: entry.
function pl_line(   v, n, it, j) {
	if (FNR == 1) { pl_fm = ($0 ~ /^---[ \t]*$/); pl_sk = 0; return }
	if (!pl_fm) return
	if ($0 ~ /^---[ \t]*$/) { pl_fm = 0; return }
	if ($0 ~ /^skills[ \t]*:/) {
		v = $0; sub(/^skills[ \t]*:/, "", v); v = uncomment(v)
		pl_sk = (v == "")
		gsub(/^\[|\]$/, "", v); n = split(v, it, ",")
		for (j = 1; j <= n; j++) if (scalar(it[j]) != "") printf "A\t%s\t%s\n", FILENAME, scalar(it[j])
		return
	}
	if (pl_sk && $0 ~ /^[ \t]*-[ \t]+/) { v = $0; sub(/^[ \t]*-[ \t]+/, "", v); printf "A\t%s\t%s\n", FILENAME, scalar(v); return }
	if ($0 ~ /^[A-Za-z]/) pl_sk = 0
}

# ---- orphans: LNT-17. A file is named when its relative path or basename
# appears in SKILL.md or in a script that is itself named.
function slurp(f,   line, s) { s = ""; while ((getline line < f) > 0) s = s line "\n"; close(f); return s }
function named_in(text, s,   p, off, before) {
	off = 0
	while ((p = index(substr(text, off + 1), s)) > 0) {
		off += p; before = off > 1 ? substr(text, off - 1, 1) : ""
		if (before !~ /[A-Za-z0-9_-]/) return 1
	}
	return 0
}
function orphans(   n, f, i, changed, text, skd) {
	skd = ENVIRON["LINT_SKILL_DIR"]
	n = split(ENVIRON["LINT_FILES"], f, "\n")
	text = slurp(skd "/SKILL.md"); mark(text, f, n)
	do {
		changed = 0
		for (i = 1; i <= n; i++) if (named[i] && !scanned[i] && f[i] ~ /^(scripts|lib)\//) { scanned[i] = 1; mark(slurp(skd "/" f[i]), f, n); changed = 1 }
	} while (changed)
	for (i = 1; i <= n; i++) {
		if (f[i] == "" || f[i] == "SKILL.md" || f[i] ~ /(^|\/)\./ || f[i] ~ /^evals\// || f[i] ~ /(^|\/)__pycache__\// || f[i] ~ /(^|\/)node_modules\//) continue
		if (!named[i]) rec("LNT-17", "FAIL", disp(skd "/" f[i]), 0, "not named in SKILL.md or in a script it names")
	}
}
function mark(text, f, n,   i) { for (i = 1; i <= n; i++) if (f[i] != "" && !named[i] && (named_in(text, f[i]) || named_in(text, basename(f[i])))) named[i] = 1 }

# ---- scripts: LNT-27 (usage), LNT-28, LNT-29 (strict mode), LNT-32.
# Emits "S<TAB>file<TAB>kind" (bash|sh|shell|other) for the shell-side checks.
function sc_begin() {
	sf = FILENAME; sd = disp(sf); s_shebang = ""; s_strict = 0; s_marker = 0; s_usage = 0; s_help = 0
	s_mktemp = 0; s_trap = 0
}
function sc_end_file(   kind, f) {
	f = sd
	kind = "other"
	if (s_shebang ~ /bash/) kind = "bash"
	else if (s_shebang ~ /(\/|env[ \t]+)(da|k)?sh([ \t]|$)/) kind = "sh"
	else if (s_shebang == "" && sf ~ /\.(sh|bash)$/) kind = "shell"
	printf "S\t%s\t%s\n", sf, kind
	if (s_shebang != "" && sf ~ /\/scripts\// && !(s_usage && s_help)) rec("LNT-27", "FAIL", f, 1, "entry point shows no usage: line or -h/--help handling (static check)")
	if ((kind == "bash" || kind == "sh") && !s_strict && !s_marker) rec("LNT-29", "FAIL", f, 1, (kind == "bash" ? "no set -euo pipefail" : "no set -eu") " in the first 30 lines")
	if (s_mktemp && !s_trap) rec("LNT-32", "FAIL", f, s_mktemp, "mktemp without a trap ... EXIT")
}
function sc_finish() { if (sf != "") sc_end_file() }
function sc_line(   l, t, flags) {
	if (FNR == 1) { if (sf != "") sc_end_file(); sc_begin(); if ($0 ~ /^#!/) s_shebang = $0 }
	l = $0; t = trim(l)
	if (index(l, "lint: no-strict-mode")) s_marker = 1
	if (tolower(l) ~ /usage:/) s_usage = 1
	if (l ~ /(^|[^A-Za-z0-9_-])(-h|--help)([^A-Za-z0-9_-]|$)/) s_help = 1
	# LNT-29: strict mode must appear in the first 30 lines.
	if (FNR <= 30 && match(l, /^[ \t]*set[ \t]+-[A-Za-z]+/)) {
		flags = substr(l, RSTART, RLENGTH); sub(/.*-/, "", flags)
		if (s_shebang ~ /bash/) { if (flags ~ /e/ && flags ~ /u/ && flags ~ /o/ && l ~ /pipefail/) s_strict = 1 }
		else if (flags ~ /e/ && flags ~ /u/) s_strict = 1
	}
	if (FNR <= 30 && l ~ /errexit/ && l ~ /nounset/ && (l ~ /pipefail/ || s_shebang !~ /bash/)) s_strict = 1
	if (t ~ /^(#|\/\/)/) return
	if (l ~ I_READ || index(l, I_TTY) || l ~ I_SELECT || index(l, I_GETPASS) || l ~ I_CALL || index(l, I_READLINE))
		rec("LNT-28", "FAIL", sd, FNR, "interactive input: " clip(t, 60))
	if (l ~ /(^|[^A-Za-z0-9_.])\/tmp\/[A-Za-z0-9_.]/) rec("LNT-32", "FAIL", sd, FNR, "literal /tmp path; use mktemp")
	if (l ~ /(^|[^A-Za-z0-9_-])mktemp([^A-Za-z0-9_-]|$)/ && !s_mktemp) s_mktemp = FNR
	if (l ~ /(^|[^A-Za-z0-9_])trap[ \t].*EXIT/) s_trap = 1
}

# ---- hooks: LNT-33 on the frontmatter hooks: block; H records for LNT-34.
function hk_parse(   i, end_, l, t, ind, k, v, ev_ind, ev, start, kind) {
	kind = ENVIRON["LINT_ART_KIND"]; HF = disp(FILENAME)
	if (fl[1] !~ /^---[ \t]*$/) return
	for (i = 2; i <= NR; i++) if (fl[i] ~ /^---[ \t]*$/) { end_ = i; break }
	for (i = 2; i < end_; i++) if (fl[i] ~ /^hooks[ \t]*:/) { start = i; break }
	if (!start) return
	v = fl[start]; sub(/^hooks[ \t]*:/, "", v); v = uncomment(v)
	if (v != "") { rec("LNT-33", "WARN", HF, start, "flow-style hooks: not parsed; check by hand"); return }
	nevents = split("SessionStart Setup UserPromptSubmit UserPromptExpansion PreToolUse PermissionRequest PermissionDenied PostToolUse PostToolUseFailure PostToolBatch Notification MessageDisplay SubagentStart SubagentStop TaskCreated TaskCompleted Stop StopFailure TeammateIdle InstructionsLoaded ConfigChange CwdChanged DirectoryAdded FileChanged WorktreeCreate WorktreeRemove PreCompact PostCompact PreModelSwitch PostModelSwitch Elicitation ElicitationResult SessionEnd", evs, " ")
	for (i = 1; i <= nevents; i++) evok[evs[i]] = 1
	ev_ind = -1; ev = ""
	for (i = start + 1; i < end_; i++) {
		l = fl[i]; t = trim(l)
		if (l !~ /^[ \t]/) break
		if (t == "" || t ~ /^#/) continue
		ind = match(l, /[^ \t]/) - 1
		if (t ~ /^-[ \t]+/) { sub(/^-[ \t]+/, "", t); ind += 2 }
		if (t !~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:/) continue
		k = t; sub(/[ \t]*:.*/, "", k); v = t; sub(/^[^:]*:/, "", v); v = scalar(v)
		if (ev_ind < 0) ev_ind = ind
		if (ind == ev_ind) {
			ev = k
			if (!(k in evok)) rec("LNT-33", "FAIL", HF, i, "undocumented hook event " k)
			continue
		}
		if (k == "matcher") hk_matcher(ev, v, i)
		else if (k == "type") hk_type(ev, v, i)
		else if (k == "if" && ev !~ /^(PreToolUse|PostToolUse|PostToolUseFailure|PermissionRequest|PermissionDenied)$/) rec("LNT-33", "FAIL", HF, i, "if: on non-tool event " ev " (never runs)")
		else if (k == "once" && kind != "skill") rec("LNT-33", "FAIL", HF, i, "once: is honoured only in skill frontmatter")
		else if (k == "command") printf "H\t%s\t%d\t%s\n", ev, i, v
	}
}
function hk_matcher(ev, m, ln,   allowed) {
	if (ev ~ /^(UserPromptSubmit|Stop|PostToolBatch|TaskCreated|TaskCompleted|TeammateIdle|Worktree.*|MessageDisplay|CwdChanged)$/) { rec("LNT-33", "FAIL", HF, ln, "matcher on " ev ", which ignores matchers"); return }
	if (m ~ /^mcp__[^_]+(__)?$/) { rec("LNT-33", "FAIL", HF, ln, "matcher " m " matches no tool; use mcp__<server>__.*"); return }
	allowed = (ev ~ /^(FileChanged|StopFailure)$/) ? (m ~ /^[A-Za-z0-9_|]*$/) : (m ~ /^[A-Za-z0-9_ ,|-]*$/)
	if (!allowed && m !~ /^mcp__[A-Za-z0-9-]+__\.\*$/ && m !~ /^\^.*\$$/) rec("LNT-33", "FAIL", HF, ln, "regex matcher " m " is not anchored ^...$")
}
function hk_type(ev, ty, ln) {
	if (ty !~ /^(command|http|mcp_tool|prompt|agent)$/) { rec("LNT-33", "FAIL", HF, ln, "unknown handler type " ty); return }
	if (ev ~ /^(SessionStart|Setup)$/ && ty !~ /^(command|mcp_tool)$/) rec("LNT-33", "FAIL", HF, ln, ev " allows only command or mcp_tool handlers")
	else if (ev ~ /^(SubagentStart|ConfigChange|PreCompact)$/ && ty ~ /^(prompt|agent)$/) rec("LNT-33", "FAIL", HF, ln, ev " allows no " ty " handler")
	else if (ev == "PermissionRequest" && ty == "agent") rec("LNT-33", "FAIL", HF, ln, "PermissionRequest allows no agent handler")
}

# ---- hookscript: LNT-34 on one gate-hook script ($LINT_HOOK_EVENT).
function hs_line(   l, t, n) {
	l = $0; t = trim(l)
	if (t ~ /^#/) return
	hlines[FNR] = l
	if (match(l, /(^|[^A-Za-z0-9_])exit[ \t]+[0-9]+/)) { n = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", n); if (n != "0" && n != "2") rec("LNT-34", "FAIL", disp(FILENAME), FNR, "exit " n " in a gate hook (only 0 or 2)") }
	if (l ~ /^[ \t]*set[ \t]+-[A-Za-z]*e/ || l ~ /set[ \t]+-o[ \t]+errexit/) h_sete = 1
	if (l ~ /^[ \t]*set[ \t]+-[A-Za-z]*E/ || l ~ /set[ \t]+-o[ \t]+errtrace/) h_setE = 1
	if (l ~ /trap[ \t].*ERR/ && l ~ /exit[ \t]+2/) h_trap2 = FNR
	if (index(l, "stop_hook_active") && !h_sha) h_sha = FNR
	if ((l ~ /command[ \t]+-v/ || l ~ /(^|[^A-Za-z0-9_-])jq([^A-Za-z0-9_-]|$)/) && !h_dep) h_dep = FNR
	if (l ~ /(echo|printf)[ \t]+\047\{/) rec("LNT-34", "FAIL", disp(FILENAME), FNR, "hand-built JSON output; use jq")
	if (index(l, "\"allow\"") || index(l, "updatedInput")) rec("LNT-34", "WARN", disp(FILENAME), FNR, "\"allow\"/updatedInput in output (HK-12)")
}
function hs_end(   ev, f, i, ok) {
	ev = ENVIRON["LINT_HOOK_EVENT"]; f = disp(FILENAME)
	if (h_sete && !(h_setE && h_trap2)) rec("LNT-34", "FAIL", f, 1, "set -e without set -E and an ERR trap that exits 2")
	if (ev ~ /^(Stop|SubagentStop)$/) {
		ok = 0
		# LNT-34: the "exit 0 when true" must sit within 5 lines of reading
		# stop_hook_active, the span of an if/then/exit/fi guard.
		if (h_sha && (!h_dep || h_sha < h_dep)) for (i = h_sha; i <= h_sha + 5; i++) if (hlines[i] ~ /exit[ \t]+0/) ok = 1
		if (!ok) rec("LNT-34", "FAIL", f, h_sha, "must read stop_hook_active before its first dependency check and exit 0 when true")
	}
	if (ev ~ /^(UserPromptSubmit|Stop)$/ && h_trap2) rec("LNT-34", "WARN", f, h_trap2, "matcher-less event: confirm the ERR trap exits 2 only after an in-script guard matched")
}

# ---- secrets: LNT-47 over text files; matches are masked in the output.
function mask(s) { return substr(s, 1, 4) "****" }
function se_hit(what, s) { rec("LNT-47", "FAIL", disp(FILENAME), FNR, "possible " what " (" mask(s) ")") }
function se_line(   l, lo, v, nd, i, c, seen) {
	l = $0
	if (index(l, "lint: example-secret")) return
	if (match(l, /-----BEGIN [A-Z ]*PRIVATE KEY/)) { se_hit("private key", substr(l, RSTART + 11, 8)); return }
	if (match(l, /AKIA[0-9A-Z]{16}/)) { se_hit("AWS access key", substr(l, RSTART, RLENGTH)); return }
	if (match(l, /gh[pousr]_[A-Za-z0-9]{36}/)) { se_hit("GitHub token", substr(l, RSTART, RLENGTH)); return }
	if (match(l, /glpat-[A-Za-z0-9_-]{20}/)) { se_hit("GitLab token", substr(l, RSTART, RLENGTH)); return }
	if (match(l, /xox[baprs]-/)) { se_hit("Slack token", substr(l, RSTART, RLENGTH + 4)); return }
	lo = tolower(l)
	if (match(lo, /(token|secret|password|api_key)[a-z0-9_]*["\047]?[ \t]*[:=][ \t]*["\047]?[a-z0-9+\/_=.-]{20,}/)) {
		v = substr(l, RSTART, RLENGTH); sub(/^[^:=]*[:=][ \t]*["\047]?/, "", v)
		if (v ~ /[0-9]/ && v ~ /[A-Za-z]/ && v !~ /^[a-z_]+[0-9]*$/ && v !~ /^[A-Z_]+[0-9]*$/) {
			nd = 0; delete seen
			for (i = 1; i <= length(v); i++) { c = substr(v, i, 1); if (!(c in seen)) { seen[c] = 1; nd++ } }
			# LNT-47 "high-entropy": 12+ distinct chars; below that, words and
			# repeated IDs pass as non-secrets.
			if (nd >= 12) se_hit("secret value", v)
		}
	}
}

# ---- bounds: LNT-57 records from JQ_BOUNDS.
function bd_line(   a) {
	split($0, a, "\t"); F57 = disp(ENVIRON["LINT_FILE"])
	if (a[1] == "S") rec("LNT-57", "FAIL", F57, 0, "agent-written string " (a[2] == "" ? "/" : a[2]) " has no maxLength, enum, const or bounded pattern")
	else if (a[1] == "A") rec("LNT-57", "FAIL", F57, 0, "agent-written array " (a[2] == "" ? "/" : a[2]) " has no maxItems")
	else if (a[1] == "R") rec("LNT-57", "WARN", F57, 0, "external $ref " a[3] " at " a[2] " not followed")
}

# ---- descriptions: LNT-56 over JQ_DESCRIPTIONS records of the contract set.
function ds_line(   a) {
	split($0, a, "\t")
	if (a[1] == "D") {
		if (a[3] == "description" && a[4] > 400) rec("LNT-56", "FAIL", disp(a[2]), 0, "root description " a[4] " chars (> 400)")
		else if (a[3] != "description" && a[4] > 200) rec("LNT-56", "FAIL", disp(a[2]), 0, "description at " a[3] " is " a[4] " chars (> 200)")
		if ((a[5] in dsee) && dsee[a[5]] != a[2] "#" a[3]) rec("LNT-56", "FAIL", disp(a[2]), 0, "description at " a[3] " duplicates " dsee[a[5]])
		else dsee[a[5]] = a[2] "#" a[3]
	} else if (a[1] == "P" && length(a[5]) >= 100) { np++; pat[np] = a[5]; patw[np] = disp(a[2]) "#" a[3] }  # LNT-56: a shared 100-char run marks a copied pattern
}
function ds_end(   i, j, k) {
	for (i = 1; i <= np; i++) for (j = i + 1; j <= np; j++)
		for (k = 1; k + 99 <= length(pat[i]); k++) if (index(pat[j], substr(pat[i], k, 100))) { rec("LNT-56", "FAIL", patw[i], 0, "pattern shares 100 chars with " patw[j]); break }
}
AWK

main "$@"
