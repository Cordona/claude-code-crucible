#!/usr/bin/env bash
#
# help-check.sh — runs the --help pages of one skill's entry-point scripts
# and checks them against section J of references/shared/lint-spec.md
# (LNT-74 – LNT-76). lint.sh stays static; this script is the only rulebook
# script that executes a target, and it runs nothing but "<script> --help"
# and "<script> <cmd> --help".
#
# Each page runs under env -i with a fixed PATH, a fresh HOME and cwd, stdin
# /dev/null and stderr discarded, so a page reads as it would on a fresh
# machine and a script that does more than print help writes only into
# throwaway dirs. The child runs in its own process group so a timeout kills
# it and every process it started, by that group's id, never by name.
#
set -Eeuo pipefail

LC_ALL=C
export LC_ALL
unset CDPATH

PROG=${0##*/}

# An unexpected failure exits 5, never 1: 1 means a MUST FAIL.
# shellcheck disable=SC2329  # invoked indirectly via the ERR trap
internal_error() {
	(( BASH_SUBSHELL == 0 )) || exit 5
	printf '%s: internal error at line %s: %s\n' "${PROG}" "$1" "$2" >&2
	printf '%s: expected that command to succeed on a readable skill dir or agent file. Try: re-run with "bash -x %s <target>" to see the failing step, and check that TMPDIR (%s) is writable.\n' \
		"${PROG}" "$0" "${TMPDIR:-/tmp}" >&2
	exit 5
}
trap 'internal_error "${LINENO}" "${BASH_COMMAND}"' ERR

# A --help page is static text: 5 s covers a cold interpreter start many
# times over, so only a hang or real work reaches it.
readonly PAGE_TIMEOUT_S=5
# 0.1 s polls: a fast page costs at most one poll of latency.
readonly POLL_INTERVAL_S=0.1
readonly POLLS_PER_SECOND=10
# 16 times the LNT-75 ceiling: measures any plausible page while bounding
# what a runaway script can write.
readonly STDOUT_CAP_BYTES=65536
# LNT-75's ceiling.
readonly PAGE_CEILING_BYTES=4096
# What a fresh macOS or Linux login has without a package manager.
readonly PAGE_PATH=/usr/bin:/bin
readonly PAGE_COLUMNS=80
# LNT-74's excerpt of a wrong line 1: enough to recognise it on one line.
readonly EXCERPT_CHARS=60
readonly REQUIRED_TOOLS="awk cat cmp cut env find grep head mkdir mkfifo mktemp rm sleep sort wc"

usage() {
	cat <<EOF
usage: ${PROG} [--report-only] [--root DIR]... [--rulebook DIR]
                    [--waivers FILE] [--max-lines N] TARGET

Run the --help pages of one skill's entry-point scripts and check them
against lint-spec.md section J (LNT-74 - LNT-76).

  TARGET            a skill dir, its SKILL.md, or an agent .md file (an
                    agent file has no scripts: N/A lines only)
  --report-only     exit 0 for findings; exits 2, 4 and 5 are unchanged
  --root DIR        printed paths are relative to it (repeatable); default:
                    git top-level of the rulebook dir
  --rulebook DIR    standard-harness-authoring root; default: the dir above
                    this script
  --waivers FILE    the TARGET's waivers file: "- <ID>: <reason> (owner)"
                    lines waive SHOULD/MAY items; without it none is waived
  --max-lines N     print at most N finding lines (default 200; 0 = no cap)
  -h, --help        show this help

Runs only "<script> --help" and, when a top-page usage line is exactly
"<script> <command> --help", "<script> <cmd> --help" for each bare
lowercase <cmd> the other usage lines name; without that line the top
page is the only page, and a usage line naming <command> in any other
shape is one LNT-74 SHOULD FAIL with no command page run. A usage line
may start with "sh" or "bash" before <script>; that word is skipped.
Each runs under env -i with PATH=${PAGE_PATH}, HOME and cwd fresh temp
dirs, stdin /dev/null, stderr discarded. It executes the target's code:
run it only on scripts already under review. It writes nothing itself
outside its own temp dir, removed on exit.

Output: lines as lint.sh's, sorted by file then item:
  LNT-NN PASS|FAIL|WARN|INFO <script>:1 <message>[ (<cmd> page)]
  a SHOULD FAIL has a "SHOULD:" prefix, a waived one is WARN "waived:
  <reason> (owner)"; a page that times out (${PAGE_TIMEOUT_S} s), exits non-zero or
  prints nothing is one LNT-74 WARN "not checked: <why>"; a target with
  no entry-point scripts gets PASS "(N/A)" lines at <target>:0.
  TRUNCATED INFO <target> showing <N> of <M> lines   (cut by --max-lines)
  SUMMARY must_fail=<n> should_fail=<n> warn=<n> skipped_must=<n> files=<n>

Runtime: up to ${PAGE_TIMEOUT_S} s per hanging page.

Dependencies:
  shell      bash 3.2+ (macOS /bin/bash works)
  required   awk cat cmp cut env find grep head mkdir mkfifo mktemp rm
             sleep sort (with -z) wc, in every macOS and Linux base system; git
             when no --root is given. A missing one exits 5, named
  rulebook   references/shared/lint-spec.md under --rulebook (item levels)

Exit codes:
  0  no MUST FAIL (always 0 for findings under --report-only); relay
  1  a MUST FAIL; send its FAIL lines to the script's owner to fix the page
  2  usage error; fix the call (stderr says what)
  4  rulebook not found or has no item levels; pass --rulebook DIR
  5  internal error or a required tool missing; stop and show stderr
  130/143  interrupted (INT/TERM); run again
EOF
}

main() {
	parse_args "$@"
	check_required_tools
	load_waivers
	resolve_rulebook
	load_item_levels
	resolve_roots
	resolve_target
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/help-check.XXXXXX") || \
		internal_failure "mktemp -d in ${TMPDIR:-/tmp}" "a writable temp dir" "setting TMPDIR to a writable directory"
	begin_target
	check_target
	flush_target
	printf 'SUMMARY must_fail=%d should_fail=%d warn=%d skipped_must=0 files=1\n' \
		"${MUST_FAIL}" "${SHOULD_FAIL}" "${WARN_COUNT}"
	if (( OPT_REPORT_ONLY )); then exit 0; fi
	if (( MUST_FAIL > 0 )); then exit 1; fi
	exit 0
}

# ---------------------------------------------------------------- setup

error() { printf '%s: error: %s\n' "${PROG}" "$*" >&2; }
die() { local code=$1; shift; error "$*"; exit "${code}"; }
usage_error() { usage >&2; die 2 "$*"; }

# internal_failure WHAT EXPECTED TRY — a step that should never fail did.
internal_failure() { die 5 "internal error: $1 failed; expected $2; try $3"; }

check_required_tools() {
	local tool
	for tool in ${REQUIRED_TOOLS}; do
		command -v "${tool}" >/dev/null 2>&1 || \
			die 5 "required tool missing: ${tool}. It ships with every macOS and Linux base system; install your OS's base utilities (Linux: coreutils, findutils, grep, gawk or mawk) or fix PATH."
	done
	return 0
}

OPT_REPORT_ONLY=0
OPT_RULEBOOK=""
OPT_WAIVERS=""
# 200, as lint.sh: one target's findings stay readable in a single Read.
OPT_MAX_LINES=200
OPT_ROOTS=()
ARGS=()

parse_args() {
	[[ $# -gt 0 ]] || { usage >&2; exit 2; }
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)     usage; exit 0 ;;
			--report-only) OPT_REPORT_ONLY=1 ;;
			--root|--rulebook|--waivers|--max-lines)
				[[ -n "${2:-}" ]] || usage_error "option $1 requires an argument"
				case "$1" in
					--root)      OPT_ROOTS+=("$2") ;;
					--rulebook)  OPT_RULEBOOK=$2 ;;
					--waivers)   OPT_WAIVERS=$2 ;;
					--max-lines) OPT_MAX_LINES=$2 ;;
					*) ;;
				esac
				shift ;;
			--)            shift; ARGS+=("$@"); break ;;
			-*)            usage_error "unknown option: $1" ;;
			*)             ARGS+=("$1") ;;
		esac
		shift
	done
	[[ ${#ARGS[@]} -eq 1 ]] || usage_error "give exactly one TARGET (got ${#ARGS[@]}); run once per skill dir or agent file"
	# At most 9 digits keeps N below 2^31 for awk's printf %d.
	[[ "${OPT_MAX_LINES}" =~ ^(0|[1-9][0-9]{0,8})$ ]] || usage_error "--max-lines needs a whole number 0-999999999, got: ${OPT_MAX_LINES}"
	return 0
}

# Prints the physical absolute path of an existing dir into REPLY.
physical_dir() {
	REPLY=$(cd -P -- "$1" 2>/dev/null && pwd -P) || REPLY=""
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

resolve_rulebook() {
	if [[ -z "${OPT_RULEBOOK}" ]]; then
		physical_dir "$(dirname -- "${BASH_SOURCE[0]}")"
		[[ -n "${REPLY}" ]] || rulebook_error "cannot resolve this script's directory"
		OPT_RULEBOOK=${REPLY%/*}
	fi
	physical_dir "${OPT_RULEBOOK}"
	[[ -n "${REPLY}" ]] || rulebook_error "rulebook dir not found: ${OPT_RULEBOOK}"
	RULEBOOK=${REPLY}
	SPEC_FILE="${RULEBOOK}/references/shared/lint-spec.md"
	[[ -f "${SPEC_FILE}" && -r "${SPEC_FILE}" ]] || rulebook_error "rulebook file missing or unreadable: ${SPEC_FILE}"
}

rulebook_error() {
	die 4 "$1; expected the standard-harness-authoring root holding references/shared/lint-spec.md; try --rulebook DIR"
}

# Reads "- **LNT-NN** · LEVEL ·" item lines into ITEM_LEVELS (" ID:LEVEL ...").
load_item_levels() {
	local records id level count=0
	records=$(awk '
		/^[ \t]*- \*\*LNT-[0-9]+\*\* · (MUST|SHOULD|MAY|INFO) ·/ {
			t = $0; sub(/^[ \t]*- \*\*/, "", t)
			id = t; sub(/\*\*.*/, "", id)
			level = t; sub(/^LNT-[0-9]+\*\* · /, "", level); sub(/ .*/, "", level)
			printf "%s\t%s\n", id, level
		}' "${SPEC_FILE}") || rulebook_error "cannot read ${SPEC_FILE}"
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

# Sets TARGET (physical path) and TARGET_IS_SKILL.
resolve_target() {
	local arg=${ARGS[0]}
	[[ "${arg}" != *$'\n'* ]] || usage_error "target path contains a newline"
	if [[ -d "${arg}" ]]; then
		physical_dir "${arg}"; TARGET=${REPLY}; TARGET_IS_SKILL=1
	elif [[ -f "${arg}" && -r "${arg}" && "${arg}" == *.md ]]; then
		physical_dir "$(dirname -- "${arg}")"
		if [[ "${arg##*/}" == SKILL.md ]]; then
			TARGET=${REPLY}; TARGET_IS_SKILL=1
		else
			TARGET="${REPLY}/${arg##*/}"; TARGET_IS_SKILL=0
		fi
	else
		usage_error "target is not a skill dir, a SKILL.md or a readable agent .md file: ${arg}"
	fi
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
	stop_page
	if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then rm -rf -- "${TMP_DIR}"; fi
}

# ---------------------------------------------------------------- output

MUST_FAIL=0
SHOULD_FAIL=0
WARN_COUNT=0
OUT_SEQ=0
OUT_BUF=""
STRIP=""
UNLEVELLED=" "

begin_target() {
	local root
	for root in "${ROOTS[@]}"; do
		if [[ "${TARGET}" == "${root}/"* ]]; then STRIP="${root}/"; break; fi
	done
}

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

# emit ID STATUS FILE LINE MESSAGE — STATUS is PASS|FAIL|WARN|INFO.
emit() {
	local id=$1 status=$2 file=$3 line=$4 msg=$5 level i
	item_level "${id}"; level=${REPLY}
	file=${file#"${STRIP}"}
	msg=${msg//[[:cntrl:]]/ }
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
		WARN) (( WARN_COUNT += 1 )) ;;
		*) ;;
	esac
	(( OUT_SEQ += 1 ))
	OUT_BUF+="${file}"$'\t'"${id}"$'\t'"${OUT_SEQ}"$'\t'"${id} ${status} ${file}:${line} ${msg}"$'\n'
}

# Prints the buffered lines, capped at --max-lines.
flush_target() {
	[[ -n "${OUT_BUF}" ]] || return 0
	printf '%s' "${OUT_BUF}" | sort -t $'\t' -k1,1 -k2,2 -k3,3n | cut -f4- \
		| HELP_SHOWN_TARGET=${TARGET#"${STRIP}"} awk -v max="${OPT_MAX_LINES}" '
			max == 0 || NR <= max { print }
			END { if (max > 0 && NR > max) printf "TRUNCATED INFO %s showing %d of %d lines\n", ENVIRON["HELP_SHOWN_TARGET"], max, NR }'
}

emit_not_applicable() {
	local id
	for id in LNT-74 LNT-75 LNT-76; do emit "${id}" PASS "$1" 0 "$2"; done
}

# ---------------------------------------------------------------- checks

check_target() {
	if (( ! TARGET_IS_SKILL )); then
		emit_not_applicable "${TARGET}" "agent file: no scripts (N/A)"
		return 0
	fi
	collect_entry_points
	if [[ ${#ENTRY_POINTS[@]} -eq 0 ]]; then
		emit_not_applicable "${TARGET}" "no entry-point scripts (N/A)"
		return 0
	fi
	local script
	for script in "${ENTRY_POINTS[@]}"; do
		check_script "${script}"
	done
}

# Entry points as LNT-27 finds them statically: a file under scripts/ or
# lib/ with a shebang whose text has a "usage:" line and -h/--help handling.
collect_entry_points() {
	local path rel first
	ENTRY_POINTS=()
	find "${TARGET}" \( -type d -name .git \) -prune -o -type f -print0 > "${TMP_DIR}/files" || \
		internal_failure "find in ${TARGET}" "a readable skill dir" "fixing the permissions find names above"
	sort -z "${TMP_DIR}/files" > "${TMP_DIR}/files.sorted" || \
		internal_failure "sort -z" "a sort that accepts -z (GNU or BSD)" "putting GNU or BSD sort first on PATH"
	while IFS= read -r -d '' path; do
		rel=${path#"${TARGET}/"}
		case "${rel}" in scripts/*|lib/*) ;; *) continue ;; esac
		first=$(head -c 2 -- "${path}" 2>/dev/null) || first=""
		[[ "${first}" == '#!' ]] || continue
		grep -qi 'usage:' -- "${path}" 2>/dev/null || continue
		grep -qE '(^|[^A-Za-z0-9_-])(-h|--help)([^A-Za-z0-9_-]|$)' -- "${path}" 2>/dev/null || continue
		if [[ "${path}" == *$'\n'* ]]; then
			emit LNT-74 WARN "${TARGET}" 0 "an entry-point path contains a newline; not run"
			continue
		fi
		ENTRY_POINTS+=("${path}")
	done < "${TMP_DIR}/files.sorted"
	return 0
}

# Runs the top page, then one page per command its usage lines name; a
# command page byte-identical to the top page is not a second page.
check_script() {
	local script=$1 cmd top_out
	set_interpreter "${script}"
	[[ ${#INTERPRETER[@]} -gt 0 ]] || return 0
	run_page "${script}" ""
	judge_page "${script}" ""
	(( PAGE_CHECKED )) || return 0
	top_out=${PAGE_OUT}
	collect_commands "${top_out}" "${script##*/}"
	if (( DECLARATION_MALFORMED )); then
		emit LNT-74 FAIL "${script}" 1 'per-command declaration malformed: expected exactly "<script> <command> --help"; command pages not checked'
	fi
	for cmd in ${COMMANDS[@]+"${COMMANDS[@]}"}; do
		run_page "${script}" "${cmd}"
		if (( ! PAGE_TIMED_OUT && PAGE_STATUS == 0 )) && cmp -s -- "${top_out}" "${PAGE_OUT}"; then continue; fi
		judge_page "${script}" "${cmd}"
	done
}

# Sets INTERPRETER (an array) from the shebang, empty when refused: a
# relative interpreter would resolve against the scrubbed PATH unpredictably.
set_interpreter() {
	local line
	IFS= read -r line < "$1" || true
	line=${line%$'\r'}; line=${line#\#!}
	read -r -a INTERPRETER <<< "${line}" || true
	if [[ ${#INTERPRETER[@]} -eq 0 || "${INTERPRETER[0]}" != /* || "${INTERPRETER[0]}" == *=* ]]; then
		emit LNT-74 WARN "$1" 1 "not run: the shebang names no absolute interpreter path"
		INTERPRETER=()
	fi
	return 0
}

PAGE_CHILD=""
PAGE_READER=""

# run_page SCRIPT CMD — runs the page; sets PAGE_OUT, PAGE_STATUS,
# PAGE_TIMED_OUT and PAGE_BYTES.
run_page() {
	local script=$1 cmd=$2 page_dir fifo polls=0 max_polls
	local -a argv=("${INTERPRETER[@]}" "${script}")
	[[ -z "${cmd}" ]] || argv+=("${cmd}")
	argv+=(--help)
	page_dir=$(mktemp -d "${TMP_DIR}/page.XXXXXX") || internal_failure "mktemp -d in ${TMP_DIR}" "a writable temp dir" "setting TMPDIR to a writable directory"
	mkdir -- "${page_dir}/home" "${page_dir}/cwd"
	fifo="${page_dir}/stdout.fifo"
	PAGE_OUT="${page_dir}/stdout"
	mkfifo -- "${fifo}"
	head -c "$(( STDOUT_CAP_BYTES + 1 ))" < "${fifo}" > "${PAGE_OUT}" &
	PAGE_READER=$!
	# Job control gives the child its own process group, so the timeout can
	# signal the child and everything it started at once.
	set -m
	( cd -- "${page_dir}/cwd" || exit 126
	  exec env -i PATH="${PAGE_PATH}" HOME="${page_dir}/home" LC_ALL=C COLUMNS="${PAGE_COLUMNS}" "${argv[@]}"
	) > "${fifo}" 2>/dev/null < /dev/null &
	PAGE_CHILD=$!
	set +m
	max_polls=$(( PAGE_TIMEOUT_S * POLLS_PER_SECOND ))
	PAGE_TIMED_OUT=1
	while (( polls <= max_polls )); do
		if ! kill -0 "${PAGE_CHILD}" 2>/dev/null && ! kill -0 "${PAGE_READER}" 2>/dev/null; then
			PAGE_TIMED_OUT=0; break
		fi
		(( polls < max_polls )) || break
		sleep "${POLL_INTERVAL_S}"
		(( polls += 1 ))
	done
	finish_page
	measure_page
}

# Collects the child's exit status, killing what is still running first.
finish_page() {
	stop_page
	PAGE_STATUS=0
	wait "${PAGE_CHILD}" 2>/dev/null || PAGE_STATUS=$?
	wait "${PAGE_READER}" 2>/dev/null || true
	PAGE_CHILD=""; PAGE_READER=""
}

# Signals the page's process group and reader by their own ids, never by name.
stop_page() {
	# The group outlives the child when a process it started still runs.
	if [[ -n "${PAGE_CHILD}" ]] && kill -0 -- "-${PAGE_CHILD}" 2>/dev/null; then
		kill -TERM -- "-${PAGE_CHILD}" 2>/dev/null || true
		sleep "${POLL_INTERVAL_S}"
		kill -KILL -- "-${PAGE_CHILD}" 2>/dev/null || true
	fi
	if [[ -n "${PAGE_READER}" ]] && kill -0 "${PAGE_READER}" 2>/dev/null; then
		kill -TERM "${PAGE_READER}" 2>/dev/null || true
	fi
	return 0
}

measure_page() {
	PAGE_BYTES=$(wc -c < "${PAGE_OUT}") || internal_failure "wc -c ${PAGE_OUT}" "a readable page file" "checking TMPDIR"
	PAGE_BYTES=${PAGE_BYTES//[[:space:]]/}
}

# judge_page SCRIPT CMD — emits the page's lines; PAGE_CHECKED=0 when the
# page could not be checked (one WARN instead).
judge_page() {
	local script=$1 page="${2:+ ($2 page)}" first
	PAGE_CHECKED=0
	if (( PAGE_TIMED_OUT )); then
		emit LNT-74 WARN "${script}" 1 "not checked: timed out after ${PAGE_TIMEOUT_S} s${page}"; return 0
	fi
	if (( PAGE_BYTES > STDOUT_CAP_BYTES )); then
		emit LNT-75 FAIL "${script}" 1 "more than ${STDOUT_CAP_BYTES} bytes, reading stopped (> ${PAGE_CEILING_BYTES})${page}"
		emit LNT-76 INFO "${script}" 1 "more than ${STDOUT_CAP_BYTES} bytes${page}"
		return 0
	fi
	if (( PAGE_STATUS != 0 )); then
		emit LNT-74 WARN "${script}" 1 "not checked: --help exited ${PAGE_STATUS}${page}"; return 0
	fi
	if (( PAGE_BYTES == 0 )); then
		emit LNT-74 WARN "${script}" 1 "not checked: --help printed nothing on stdout${page}"; return 0
	fi
	first=""
	IFS= read -r first < "${PAGE_OUT}" || true
	if [[ "${first}" == usage:* ]]; then
		emit LNT-74 PASS "${script}" 1 "line 1 starts with \"usage:\"${page}"
	else
		first=${first//[[:cntrl:]]/?}
		emit LNT-74 FAIL "${script}" 1 "line 1 does not start with lowercase \"usage:\": \"${first:0:EXCERPT_CHARS}\"${page}"
	fi
	if (( PAGE_BYTES <= PAGE_CEILING_BYTES )); then
		emit LNT-75 PASS "${script}" 1 "${PAGE_BYTES} bytes (<= ${PAGE_CEILING_BYTES})${page}"
	else
		emit LNT-75 FAIL "${script}" 1 "${PAGE_BYTES} bytes (> ${PAGE_CEILING_BYTES})${page}"
	fi
	emit LNT-76 INFO "${script}" 1 "${PAGE_BYTES} bytes${page}"
	PAGE_CHECKED=1
}

# collect_commands PAGE SCRIPT_NAME — sets COMMANDS from the usage lines
# (lint-spec.md section J): line 1, then each line up to the first blank one
# that starts with whitespace and the script's name, optionally after one
# interpreter word (sh or bash), which is skipped. The command is the next
# word, when it is a bare lowercase word. A script serves per-command
# pages only when one usage line is exactly "<script> <command> --help";
# without it COMMANDS stays empty and the top page is the only page. A usage
# line holding the word <command> in any other shape sets
# DECLARATION_MALFORMED and leaves COMMANDS empty, so the caller reports the
# skipped command pages instead of passing quietly.
collect_commands() {
	local page=$1 name=$2 line rest lineno=0 seen=" " has_command_pages=0
	local -a found=()
	local -a words
	COMMANDS=()
	DECLARATION_MALFORMED=0
	while IFS= read -r line || [[ -n "${line}" ]]; do
		line=${line%$'\r'}
		(( lineno += 1 ))
		if (( lineno == 1 )); then
			rest=${line#[Uu][Ss][Aa][Gg][Ee]:}
		else
			[[ "${line}" =~ [^[:space:]] ]] || break
			[[ "${line}" =~ ^[[:space:]]+(.+)$ ]] || continue
			rest=${BASH_REMATCH[1]}
		fi
		words=()
		read -r -a words <<< "${rest}" || true
		if [[ ${#words[@]} -gt 0 && ( "${words[0]}" == sh || "${words[0]}" == bash ) ]]; then
			words=("${words[@]:1}")
		fi
		[[ ${#words[@]} -ge 2 && "${words[0]##*/}" == "${name}" ]] || continue
		if [[ ${#words[@]} -eq 3 && "${words[1]}" == '<command>' && "${words[2]}" == --help ]]; then
			has_command_pages=1; continue
		fi
		if [[ " ${words[*]} " == *' <command> '* ]]; then
			DECLARATION_MALFORMED=1; continue
		fi
		[[ "${words[1]}" =~ ^[a-z][a-z0-9-]*$ ]] || continue
		[[ "${seen}" != *" ${words[1]} "* ]] || continue
		seen+="${words[1]} "
		found+=("${words[1]}")
	done < "${page}"
	if (( has_command_pages && ! DECLARATION_MALFORMED )); then COMMANDS=(${found[@]+"${found[@]}"}); fi
	return 0
}

main "$@"
