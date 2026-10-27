#!/usr/bin/env bash
set -Eeuo pipefail
#
# render-gate.sh — print the view of a flow-harness-authoring gate (G1-G4)
# or its Closing report from the run files. Read-only. Each view holds the
# decision only; the files it was built from close it as the Data block,
# the one place, with G4's source and link, where a path prints whole.
# --paths lists the files read.
#
# Every input is untrusted text written by agents: it is never evaluated,
# values reach awk only through ENVIRON or stdin (awk -v would expand
# backslash escapes), and text copied into the view loses every control
# character but tab, C1 controls included (read_clean).
#
# The whole view is built in memory and printed at the end, so a failed run
# prints nothing on stdout. No temp file, here-doc or here-string is used.
#
# Helpers that can stop the run (exit 3) set a global instead of printing, so
# they run in this shell rather than in a command substitution, whose exit
# would only leave the subshell.
#
# Usage: see --help.

LC_ALL=C
export LC_ALL
unset CDPATH

PROG=${0##*/}

# Swarm sizing, as the flow's SKILL.md (Reviewer swarm) sets it.
readonly SMALL_SEAT_MAX_ITEMS=30
readonly SMALL_SWARM_MAX_LINES=300
readonly AGENT_FEW_SEATS_BELOW_LINES=150
readonly AGENT_FEW_SEATS=$'agent-01+03\nagent-02\nagent-04\nagent-05\nagent-06+07+08'

# Author-report section names: skill-author's §0-§8 and agent-author's 0-7.
readonly REPORT_SECTIONS="Status|Files written|File written|Source trace|Script specs|Field table|Open points|Checklist self-check|Findings|Eval set"
readonly SHORT_LINE_MAX=140

readonly LIGHT_GATE="🔵"
readonly LIGHT_OWNER="🟡"
readonly LIGHT_BLOCKED="🔴"

# ---------------------------------------------------------------------------
# Diagnostics (stderr only)
# ---------------------------------------------------------------------------
error() { printf '%s: error: %s\n' "${PROG}" "$*" >&2; }
warning() { printf '%s: warning: %s\n' "${PROG}" "$*" >&2; }

# shellcheck disable=SC2329  # invoked indirectly via the ERR trap
internal_error() {
	printf '%s: internal error at line %s: %s\n' "${PROG}" "$1" "$2" >&2
	printf '%s: expected that command to succeed; nothing was printed. Try: re-run with the same arguments; if it repeats, report the command above.\n' "${PROG}" >&2
	exit 5
}
trap 'internal_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'error "interrupted"; exit 130' INT
trap 'error "terminated"; exit 143' TERM

# shellcheck disable=SC2016  # $HOME is printed literally on the help page
USAGE_TEXT='usage: PROG --gate g1|g2|g3|g4|closing --run-dir DIR --kind skill|agent
         --target PATH [gate options] [--paths]
       PROG -h|--help

Print the view of a flow-harness-authoring gate (G1-G4) or the Closing
report: only what the decision needs. Same input, same view. Text from run
files loses its control characters (tab kept); an absolute path in it is
cut to its repo-relative form (the repo is the nearest dir above --target
holding .git), or to its last part outside the repo. The view ends with
Data: the whole absolute path of each file it was built from. No other
path prints whole but G4'"'"'s source, link and link target.
  g1: the open questions; with --verify its counts, missing cards and
      WRONG LINE, UNSUPPORTED or UNDECIDABLE lines. Data: source, verify.
  g2: the target with its line, script and contract counts; the swarm
      options, recommended first, with their seats; the eval, field-row
      and open-point counts with their author-report section. Data: the
      author report.
  g3: the verdict; each blocking item (ID, seat, file:line, its Fix cut
      at the first sentence or 140 characters; with no "## Non-PASS item
      lines" section in --merged, no Fix and a warning on stderr, exit 0);
      each should-fail item (ID, file:line); invalid waivers, lint and help-check FAIL lines, failed
      or both-pass eval outcomes; the merge progress; counts of the rest.
      Data: merged report, lint, help-check.
  g4: the checks, the source, the link and what it holds now. Data: as g3.
  closing: the final verdict, fixed, waived and open IDs, files written,
      evals, how it ended, live validation, what was not run, what still
      needs the owner. Data: final merged report, state.md, waivers.
A zero count is left out. Every path given must be absolute, with no "~".
Reads only the files named below; writes no file.

Options:
  --gate GATE        g1, g2, g3, g4 or closing.
  --run-dir DIR      The run dir; must exist. g3 also reads its review/ and
                       runs/*-grade.md; closing its review-r<n>.md,
                       runs/*-grade.md, state.md and target-files.txt.
  --kind KIND        skill or agent.
  --target PATH      The target skill dir or agent file.
  --source FILE      g1, required: the source, with an "## ... Open
                       questions" section.
  --verify FILE      g1, refactor: the VERIFY check.
  --report FILE      g2, required: the author report.
  --checklists IDS   g2, required with --kind skill: checklist ids,
                       comma-separated (01,02,07).
  --rulebook DIR     g2: the standard-harness-authoring root. Default:
                       $HOME/.claude/skills/standard-harness-authoring
  --merged FILE      g3 and g4, required: the merged report review-r<n>.md.
  --lint FILE        g3 and g4, required: the lint.sh output.
  --help-check FILE  g3 and g4: the help-check.sh output, when it ran.
  --link PATH        g4, required: the deploy link path.
  --waivers FILE     closing: the target waivers file, when it exists.
  --paths            Print the status line and a numbered list of the
                       whole path of every file the view reads.
Any other option for the gate is a usage error.

Output (stdout): the view, or with --paths the file list; relayed as
printed. Diagnostics go to stderr.

Requires bash 3.2+ (macOS) or Linux, and awk, cat, find, readlink, sort,
tr, wc.

Exit codes:
  0    view printed; relay it word for word
  2    usage error; show the human stderr, and stop
  3    input file missing, unreadable or malformed; show the human stderr, and stop
  5    internal error or missing tool; show the human stderr, and stop
  130  interrupted; show the human stderr, and stop
  143  terminated; show the human stderr, and stop'

usage() { printf '%s\n' "${USAGE_TEXT//PROG/${PROG}}"; }

usage_error() {
	usage >&2
	error "$*"
	exit 2
}

input_error() {
	error "$*"
	exit 3
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_GATE="" OPT_RUN_DIR="" OPT_KIND="" OPT_TARGET="" OPT_SOURCE="" OPT_VERIFY=""
OPT_REPORT="" OPT_CHECKLISTS="" OPT_RULEBOOK="" OPT_MERGED="" OPT_LINT=""
OPT_HELP_CHECK="" OPT_LINK="" OPT_WAIVERS="" OPT_PATHS=0
GIVEN=" "

[[ $# -gt 0 ]] || usage_error "no arguments; expected at least --gate, --run-dir, --kind and --target"

# take_value OPTION VALUE — reject a repeat or a missing value; the caller
# stores VALUE.
take_value() {
	[[ "${GIVEN}" != *" $1 "* ]] || usage_error "option $1 given twice; expected it once"
	[[ -n "${2:-}" && "$2" != --* ]] || usage_error "option $1 requires a value"
	GIVEN="${GIVEN}$1 "
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help)    usage; exit 0 ;;
		--gate)       take_value "$1" "${2:-}"; OPT_GATE=$2; shift ;;
		--run-dir)    take_value "$1" "${2:-}"; OPT_RUN_DIR=$2; shift ;;
		--kind)       take_value "$1" "${2:-}"; OPT_KIND=$2; shift ;;
		--target)     take_value "$1" "${2:-}"; OPT_TARGET=$2; shift ;;
		--source)     take_value "$1" "${2:-}"; OPT_SOURCE=$2; shift ;;
		--verify)     take_value "$1" "${2:-}"; OPT_VERIFY=$2; shift ;;
		--report)     take_value "$1" "${2:-}"; OPT_REPORT=$2; shift ;;
		--checklists) take_value "$1" "${2:-}"; OPT_CHECKLISTS=$2; shift ;;
		--rulebook)   take_value "$1" "${2:-}"; OPT_RULEBOOK=$2; shift ;;
		--merged)     take_value "$1" "${2:-}"; OPT_MERGED=$2; shift ;;
		--lint)       take_value "$1" "${2:-}"; OPT_LINT=$2; shift ;;
		--help-check) take_value "$1" "${2:-}"; OPT_HELP_CHECK=$2; shift ;;
		--link)       take_value "$1" "${2:-}"; OPT_LINK=$2; shift ;;
		--waivers)    take_value "$1" "${2:-}"; OPT_WAIVERS=$2; shift ;;
		--paths)
			[[ "${OPT_PATHS}" -eq 0 ]] || usage_error "option --paths given twice; expected it once"
			OPT_PATHS=1 ;;
		*) usage_error "unknown argument: $1; expected one of the options in --help" ;;
	esac
	shift
done

for tool in awk cat find readlink sort tr wc; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		error "required tool missing: ${tool}; expected a POSIX base system that provides it; try fixing PATH or installing your OS's base utilities"
		exit 5
	fi
done

# set_gate_options — ALLOWED and REQUIRED: the gate options this --gate and
# --kind take and need, space-separated.
set_gate_options() {
	case "${OPT_GATE}" in
		g1) ALLOWED="--source --verify" REQUIRED="--source" ;;
		g2)
			if [[ "${OPT_KIND}" == skill ]]; then
				ALLOWED="--report --checklists --rulebook" REQUIRED="--report --checklists"
			else
				ALLOWED="--report --rulebook" REQUIRED="--report"
			fi ;;
		g3) ALLOWED="--merged --lint --help-check" REQUIRED="--merged --lint" ;;
		g4) ALLOWED="--merged --lint --help-check --link" REQUIRED="--merged --lint --link" ;;
		*)  ALLOWED="--waivers" REQUIRED="" ;;
	esac
}

# check_path OPTION VALUE — usage error unless VALUE is absolute, has no
# "~" and no control character.
check_path() {
	[[ -n "$2" ]] || return 0
	[[ "$2" == /* ]] || usage_error "$1 must be an absolute path, got: $2"
	[[ "$2" != *"~"* ]] || usage_error "$1 must not contain \"~\"; give the whole absolute path, got: $2"
	[[ "$2" != *[[:cntrl:]]* ]] || usage_error "$1 path contains a control character; expected a plain absolute path"
}

check_choice() {
	[[ -n "$2" ]] || usage_error "$1 is required ($3)"
	[[ " $3 " == *" $2 "* ]] || usage_error "$1 must be one of: $3; got: $2"
}

validate_args() {
	local opt
	check_choice --gate "${OPT_GATE}" "g1 g2 g3 g4 closing"
	[[ -n "${OPT_RUN_DIR}" ]] || usage_error "--run-dir is required"
	check_choice --kind "${OPT_KIND}" "skill agent"
	[[ -n "${OPT_TARGET}" ]] || usage_error "--target is required"

	set_gate_options
	for opt in --source --verify --report --checklists --rulebook --merged --lint --help-check --link --waivers; do
		if [[ "${GIVEN}" == *" ${opt} "* && " ${ALLOWED} " != *" ${opt} "* ]]; then
			usage_error "${opt} is not an option of --gate ${OPT_GATE} --kind ${OPT_KIND}; expected only: ${ALLOWED}"
		fi
	done
	for opt in ${REQUIRED}; do
		[[ "${GIVEN}" == *" ${opt} "* ]] || usage_error "--gate ${OPT_GATE} --kind ${OPT_KIND} requires ${opt}"
	done

	check_path --run-dir "${OPT_RUN_DIR}"
	check_path --target "${OPT_TARGET}"
	check_path --source "${OPT_SOURCE}"
	check_path --verify "${OPT_VERIFY}"
	check_path --report "${OPT_REPORT}"
	check_path --rulebook "${OPT_RULEBOOK}"
	check_path --merged "${OPT_MERGED}"
	check_path --lint "${OPT_LINT}"
	check_path --help-check "${OPT_HELP_CHECK}"
	check_path --link "${OPT_LINK}"
	check_path --waivers "${OPT_WAIVERS}"
	if [[ -n "${OPT_CHECKLISTS}" && ! "${OPT_CHECKLISTS}" =~ ^[0-9][0-9](,[0-9][0-9])*$ ]]; then
		usage_error "--checklists must be two-digit ids, comma-separated (01,02,07), got: ${OPT_CHECKLISTS}"
	fi
}

# strip_slashes VAR — drop trailing slashes from the named variable ("/"
# stays "/").
strip_slashes() {
	local path=${!1}
	while [[ "${path}" == */ && "${path}" != / ]]; do path=${path%/}; done
	printf -v "$1" '%s' "${path}"
}

ALLOWED="" REQUIRED=""
validate_args
strip_slashes OPT_RUN_DIR
strip_slashes OPT_TARGET
[[ -d "${OPT_RUN_DIR}" ]] || input_error "--run-dir is not a directory: ${OPT_RUN_DIR}; expected the flow's run dir; check the path"

# ---------------------------------------------------------------------------
# Input reading
# ---------------------------------------------------------------------------
READ_FILES=()

# need_file WHAT PATH — exit 3 unless PATH is a readable regular file;
# record it as read by the view.
need_file() {
	[[ -f "$2" && -r "$2" ]] || input_error "$1 does not exist or is not readable: $2; expected a readable file; check the path"
	READ_FILES+=("$2")
}

# read_clean FILE — FILE's text with every control character but tab and
# newline removed, C1 controls (UTF-8 C2 80-9F) included. Its readers read to
# the end: one that exits early would fail the pipeline (SIGPIPE, pipefail).
read_clean() {
	tr -d '\000-\010\013-\037\177' <"$1" | awk '{ gsub(/\302[\200-\237]/, ""); print }'
}

# first_line_with PREFIX FILE — sets LINE to FILE's first clean line that
# starts with PREFIX, or to "" when there is none.
first_line_with() {
	LINE=$(read_clean "$2" | PREFIX=$1 awk '!found && index($0, ENVIRON["PREFIX"]) == 1 { print; found = 1 }')
}

# require_line PREFIX FILE WHAT — sets LINE as first_line_with; exit 3 when
# FILE has none.
require_line() {
	first_line_with "$1" "$2"
	[[ -n "${LINE}" ]] || input_error "no \"$1\" line in $2; expected $3; re-save it or re-run what writes it"
}

# CUT_AWK — awk function cut(s, max): s cut to max characters (UTF-8
# counted), "…" ending a cut line.
# shellcheck disable=SC2016  # awk program text, not shell expansions
readonly CUT_AWK='
	function cut(s, max,   i, j, len, chars) {
		len = length(s); chars = 0
		for (i = 1; i <= len; i++) if (substr(s, i, 1) !~ /[\200-\277]/ && ++chars == max) break
		if (i > len) return s
		for (j = i + 1; j <= len; j++) if (substr(s, j, 1) !~ /[\200-\277]/) break
		if (j > len) return s
		s = substr(s, 1, i - 1); sub(/[ \t]+$/, "", s)
		return s "…"
	}'

# ---------------------------------------------------------------------------
# View helpers
# ---------------------------------------------------------------------------
STATUS=""
BLOCKS=()
FIELDS=""
DATA=()

# status_line LIGHT TITLE [TAIL]
status_line() {
	if [[ -n "${3:-}" ]]; then
		printf '%s **%s** · %s' "$1" "$2" "$3"
	else
		printf '%s **%s**' "$1" "$2"
	fi
}

# heading NAME
heading() { printf '**%s**' "$1"; }

# heading_item NAME ITEM — a heading holding one item.
heading_item() { printf '**%s:** %s' "$1" "$2"; }

# numbered_list ITEM...
numbered_list() {
	local index=0 item
	for item in "$@"; do
		index=$((index + 1))
		printf '%d. %s\n' "${index}" "${item}"
	done
}

set_status() {
	STATUS=$(status_line "$@")
}

add_block() {
	if [[ -n "$1" ]]; then BLOCKS+=("$1"); fi
}

# field NAME VALUE — queue the field line "NAME: VALUE" with a hard break;
# flush_fields makes the queued lines one block.
field() { FIELDS="${FIELDS}${FIELDS:+$'\n'}$1: $2  "; }

flush_fields() {
	add_block "${FIELDS}"
	FIELDS=""
}

# count_field NAME COUNT — a field line for COUNT; nothing when it is 0.
count_field() {
	(( $2 > 0 )) || return 0
	field "$1" "$2"
}

# add_data KIND PATH — name PATH, whole, in the Data block.
add_data() { DATA+=("$1: $2"); }

# list_block NAME LINES — a heading holding one non-blank line, a heading and
# a numbered list for two or more, nothing for none. A line's own leading
# list marker ("- ", "* ", "+ ", "1. ", "1) ") is dropped, so no marker prints
# beside the label or after a number.
list_block() {
	local name=$1 line block title list
	local marker_re='^[0-9]+[.)][[:space:]]+(.*)$'
	local -a items=()
	while IFS= read -r line; do
		line=${line#[-*+] }
		if [[ "${line}" =~ ${marker_re} ]]; then line=${BASH_REMATCH[1]}; fi
		if [[ -n "${line}" ]]; then items+=("${line}"); fi
	done < <(printf '%s\n' "$2")
	case ${#items[@]} in
		0) ;;
		1) block=$(heading_item "${name}" "${items[0]}"); add_block "${block}" ;;
		*)
			title=$(heading "${name}")
			list=$(numbered_list "${items[@]}")
			add_block "${title}"$'\n'"${list}" ;;
	esac
}

# blocks — the status line, then every block, one blank line between each.
blocks() {
	local block
	printf '%s\n' "${STATUS}"
	for block in "${BLOCKS[@]+"${BLOCKS[@]}"}"; do
		printf '\n%s\n' "${block}"
	done
}

# data_block — "**Data · Kind:** path" for one file, a heading and a
# numbered list for two or more.
data_block() {
	local title list
	case ${#DATA[@]} in
		0) ;;
		1)
			title=$(heading_item "Data · ${DATA[0]%%: *}" "${DATA[0]#*: }")
			printf '\n%s\n' "${title}" ;;
		*)
			title=$(heading Data)
			list=$(numbered_list "${DATA[@]}")
			printf '\n%s\n%s\n' "${title}" "${list}" ;;
	esac
}

print_paths() {
	local files
	BLOCKS=()
	files=$(printf '%s\n' "${READ_FILES[@]+"${READ_FILES[@]}"}" | awk 'NF && !seen[$0]++')
	list_block "Files" "${files}"
	blocks
}

# ---------------------------------------------------------------------------
# Shared run-dir readers
# ---------------------------------------------------------------------------

# latest_seat_files — the absolute path of each seat's latest report in
# <run-dir>/review/: the highest -r<n> per seat, a bare name counting as
# round 1; sorted by seat.
latest_seat_files() {
	local dir="${OPT_RUN_DIR}/review" file
	[[ -d "${dir}" ]] || return 0
	for file in "${dir}"/*.md; do
		if [[ -f "${file}" ]]; then printf '%s\n' "${file}"; fi
	done | awk '{
		name = $0; sub(/.*\//, "", name); sub(/\.md$/, "", name)
		round = 1; seat = name
		if (match(name, /-r[0-9]+$/)) { seat = substr(name, 1, RSTART - 1); round = substr(name, RSTART + 2) + 0 }
		if (!(seat in best) || round > best[seat]) { best[seat] = round; path[seat] = $0 }
	} END { for (s in path) print s "\t" path[s] }' | sort | awk -F '\t' '{ print $2 }'
}

# merged_reports — <run-dir>/review-r<n>.md paths, in round order.
merged_reports() {
	local file
	for file in "${OPT_RUN_DIR}"/review-r*.md; do
		if [[ -f "${file}" && "${file##*/}" =~ ^review-r[0-9]+\.md$ ]]; then printf '%s\n' "${file}"; fi
	done | awk '{ n = $0; sub(/.*review-r/, "", n); sub(/\.md$/, "", n); print (n + 0) "\t" $0 }' |
		sort -n | awk -F '\t' '{ print $2 }'
}

grade_files() {
	local file
	for file in "${OPT_RUN_DIR}"/runs/*-grade.md; do
		if [[ -f "${file}" ]]; then printf '%s\n' "${file}"; fi
	done
}

# set_eval_id FILE — sets EVAL_ID from FILE's "EVAL <id> · " line; exit 3
# without one.
set_eval_id() {
	require_line "EVAL " "$1" "an eval-grader reply"
	EVAL_ID=${LINE#EVAL }
	EVAL_ID=${EVAL_ID%% *}
}

# OUTCOME_AWK — awk functions over an eval-grader outcome line
# "O<n> · NEW <status> — … · BASE <status> — …".
# shellcheck disable=SC2016  # awk program text, not shell expansions
readonly OUTCOME_AWK='
	function new_status(s) { sub(/^O[0-9]+ · NEW /, "", s); sub(/ .*/, "", s); return s }
	function base_status(s,   p, q) {
		p = 0
		while ((q = index(substr(s, p + 1), " · BASE ")) > 0) p += q
		if (!p) return "missing"
		s = substr(s, p + length(" · BASE ")); sub(/ .*/, "", s); return s
	}'

# ---------------------------------------------------------------------------
# G1 Approve the source
# ---------------------------------------------------------------------------
render_g1() {
	local section checks
	set_status "${LIGHT_GATE}" "G1 Approve the source"
	need_file "--source file" "${OPT_SOURCE}"
	add_data "Source" "${OPT_SOURCE}"
	# The first output line says whether the section exists.
	section=$(read_clean "${OPT_SOURCE}" | awk '
		done { next }
		/^## / { if (in_section) { done = 1; next } if (tolower($0) ~ /open questions/) { in_section = found = 1; next } }
		in_section && NF { body[++n] = $0 }
		END { print (found ? "found" : "missing"); for (i = 1; i <= n; i++) print body[i] }')
	[[ "${section%%$'\n'*}" == found ]] || input_error "no \"## ... Open questions\" section in ${OPT_SOURCE}; expected a heading matching /open questions/i; send the source back to its writer"
	section=${section#found}
	section=${section#$'\n'}
	list_block "Open questions" "${section:-none}"

	[[ -n "${OPT_VERIFY}" ]] || return 0
	need_file "--verify file" "${OPT_VERIFY}"
	add_data "Verify" "${OPT_VERIFY}"
	require_line "Counts:" "${OPT_VERIFY}" "the analyst's VERIFY check"
	require_line "Missing cards:" "${OPT_VERIFY}" "the analyst's VERIFY check"
	checks=$(read_clean "${OPT_VERIFY}" | awk '
		/^Counts:/ && counts == "" { counts = $0; next }
		/^Missing cards:/ && missing == "" { missing = $0; next }
		{ n = split($0, f, " · "); if (n >= 2 && (f[2] == "WRONG LINE" || f[2] == "UNSUPPORTED" || f[2] == "UNDECIDABLE")) items[++k] = $0 }
		END { print counts; print missing; for (i = 1; i <= k; i++) print items[i] }')
	list_block "Verify" "${checks}"
}

# ---------------------------------------------------------------------------
# G2 Approve the evals, the field table and the swarm size
# ---------------------------------------------------------------------------

# target_files — every regular file under the target dir, sensitive files
# (.git/, .env*, id_*, keys, certificates and key stores) left out; sorted.
target_files() {
	find -H "${OPT_TARGET}" -name .git -prune -o -type f \
		! -name '.env*' ! -name 'id_*' ! -name '*.pem' ! -name '*.key' \
		! -name '*.p12' ! -name '*.pfx' ! -name '*.crt' ! -name '*.cer' \
		! -name '*.der' ! -name '*.jks' ! -name '*.keystore' -print | sort
}

# set_line_total FILE... — sets LINE_TOTAL to the files' total newline count.
set_line_total() {
	LINE_TOTAL=$(cat -- "$@" | wc -l)
	LINE_TOTAL=${LINE_TOTAL//[[:space:]]/}
	[[ "${LINE_TOTAL}" =~ ^[0-9]+$ ]] || { error "wc printed no line count for the target files"; exit 5; }
}

# set_checklist_file KIND_DIR ID — sets CHECKLIST_FILE to the one rulebook
# checklist file for ID; exit 3 on none or several.
set_checklist_file() {
	local -a matches=()
	local file
	for file in "${RULEBOOK}/references/$1/$2"-*.md; do
		if [[ -f "${file}" ]]; then matches+=("${file}"); fi
	done
	[[ ${#matches[@]} -eq 1 ]] || input_error "expected one checklist file ${RULEBOOK}/references/$1/$2-*.md, found ${#matches[@]}; check --checklists and --rulebook"
	CHECKLIST_FILE=${matches[0]}
}

count_items() {
	awk '/^- \*\*[A-Z]+-[0-9]+\*\*/ { n++ } END { print n + 0 }' <"$1"
}

# small_seats IDS COUNTS SCRIPTS — Small swarm seats: ids in number order
# grouped up to SMALL_SEAT_MAX_ITEMS items, 09 and 12 each alone, 07 alone
# too when the target has scripts (SCRIPTS > 0), then CONFORMANCE.
small_seats() {
	IDS=$1 COUNTS=$2 SCRIPTS=$3 MAX=${SMALL_SEAT_MAX_ITEMS} awk 'BEGIN {
		n = split(ENVIRON["IDS"], id, " "); split(ENVIRON["COUNTS"], cnt, " "); max = ENVIRON["MAX"] + 0
		scripts = ENVIRON["SCRIPTS"] + 0
		for (i = 1; i <= n; i++) {
			alone = (id[i] == "09" || id[i] == "12" || (id[i] == "07" && scripts > 0))
			if (group != "" && (alone || total + cnt[i] > max)) { print group; group = ""; total = 0 }
			if (alone) { print id[i]; continue }
			group = (group == "" ? id[i] : group "+" id[i]); total += cnt[i]
		}
		if (group != "") print group
		print "CONFORMANCE"
	}'
}

# count_lines TEXT — the number of non-blank lines in TEXT.
count_lines() {
	printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'
}

# seat_summary SEATS — "<n> seats + CONFORMANCE: a · b · …" from one seat per
# line; CONFORMANCE is named once, outside the count.
seat_summary() {
	printf '%s\n' "$1" | awk '
		$0 == "CONFORMANCE" { conformance = 1; next }
		NF { list = list (n++ ? " · " : "") $0 }
		END { printf "%d seat%s%s: %s\n", n, (n == 1 ? "" : "s"), (conformance ? " + CONFORMANCE" : ""), list }'
}

# target_field TAIL — the Target field line: the target and TAIL, which
# names counts as " · <n> <noun>" with a zero count left out.
target_field() {
	field "Target" "${OPT_TARGET} · ${LINE_TOTAL} lines$1"
	flush_fields
}

render_swarm_skill() {
	local files file scripts contracts sorted_ids id count ids="" counts="" large small
	local script_count contract_count reason="" small_line large_line tail=""
	local -a file_list=()
	[[ -d "${OPT_TARGET}" ]] || input_error "--target is not a directory: ${OPT_TARGET}; expected the target skill dir for --kind skill"
	files=$(target_files)
	while IFS= read -r file; do
		if [[ -n "${file}" ]]; then file_list+=("${file}"); READ_FILES+=("${file}"); fi
	done < <(printf '%s\n' "${files}")
	[[ ${#file_list[@]} -gt 0 ]] || input_error "the target dir holds no file: ${OPT_TARGET}; expected a skill dir"
	set_line_total "${file_list[@]}"
	scripts=$(printf '%s\n' "${files}" | TARGET="${OPT_TARGET}" awk 'index($0, ENVIRON["TARGET"] "/scripts/") == 1')
	contracts=$(printf '%s\n' "${files}" | TARGET="${OPT_TARGET}" awk '/\.json$/ && index($0, ENVIRON["TARGET"] "/evals/") != 1')
	script_count=$(count_lines "${scripts}")
	contract_count=$(count_lines "${contracts}")

	sorted_ids=$(printf '%s\n' "${OPT_CHECKLISTS//,/$'\n'}" | sort -u)
	large=""
	while IFS= read -r id; do
		[[ -n "${id}" ]] || continue
		set_checklist_file skills "${id}"
		need_file "checklist file" "${CHECKLIST_FILE}"
		count=$(count_items "${CHECKLIST_FILE}")
		ids="${ids}${id} " counts="${counts}${count} " large="${large}${id}"$'\n'
	done < <(printf '%s\n' "${sorted_ids}")
	large="${large}CONFORMANCE"
	small=$(small_seats "${ids}" "${counts}" "${script_count}")
	small_line=$(seat_summary "${small}")
	large_line=$(seat_summary "${large}")

	if (( script_count > 0 )); then tail="${tail} · ${script_count} scripts"; fi
	if (( contract_count > 0 )); then tail="${tail} · ${contract_count} contracts"; fi
	target_field "${tail}"
	if (( LINE_TOTAL <= SMALL_SWARM_MAX_LINES )) && (( script_count == 0 && contract_count == 0 )); then
		list_block "Swarm" "Small (recommended: ${SMALL_SWARM_MAX_LINES} lines or fewer, no scripts or contracts) — ${small_line}"$'\n'"Large — ${large_line}"
		return 0
	fi
	if (( LINE_TOTAL > SMALL_SWARM_MAX_LINES )); then reason="over ${SMALL_SWARM_MAX_LINES} lines"; fi
	if (( script_count > 0 && contract_count > 0 )); then
		reason="${reason:+${reason}, }has scripts and contracts"
	elif (( script_count > 0 )); then
		reason="${reason:+${reason}, }has scripts"
	elif (( contract_count > 0 )); then
		reason="${reason:+${reason}, }has contracts"
	fi
	list_block "Swarm" "Large (recommended: ${reason}) — ${large_line}"$'\n'"Small — ${small_line}"
}

render_swarm_agent() {
	local seats="" file reason summary
	need_file "--target agent file" "${OPT_TARGET}"
	set_line_total "${OPT_TARGET}"
	if (( LINE_TOTAL < AGENT_FEW_SEATS_BELOW_LINES )); then
		seats=${AGENT_FEW_SEATS}
		reason="under ${AGENT_FEW_SEATS_BELOW_LINES} lines"
	else
		for file in "${RULEBOOK}"/references/agents/[0-9]*.md; do
			if [[ -f "${file}" ]]; then
				READ_FILES+=("${file}")
				file=${file##*/}
				seats="${seats}agent-${file%%-*}"$'\n'
			fi
		done
		[[ -n "${seats}" ]] || input_error "no agent checklist under ${RULEBOOK}/references/agents/; expected [0-9]*.md files; check --rulebook"
		reason="${AGENT_FEW_SEATS_BELOW_LINES} lines or more"
	fi
	summary=$(seat_summary "${seats}")
	target_field ""
	list_block "Swarm" "${summary} (${reason})"
}

# set_report_section NAME — sets SECTION to the author report's NAME
# section, verbatim, outer blank lines trimmed, and SECTION_REF to where its
# heading puts it ("§8" or "item 5"); exit 3 when it is missing.
# A section starts at "## §<n> <name>" (skill-author) or "<n>. **<name>:**"
# (agent-author; text after the bold is its first line) and runs to the next
# line of either shape or an end line. Only a REPORT_SECTIONS name starts an
# agent-author section, so a numbered open point opening in bold does not.
set_report_section() {
	SECTION=$(read_clean "${OPT_REPORT}" | NAME=$1 KNOWN=${REPORT_SECTIONS} awk '
		BEGIN { known_count = split(ENVIRON["KNOWN"], known, "|") }
		function item_name(s,   rest, k) {
			if (s !~ /^[0-9]+\. \*\*/) return ""
			rest = s; sub(/^[0-9]+\. \*\*/, "", rest)
			for (k = 1; k <= known_count; k++)
				if (index(rest, known[k] ":**") == 1 || index(rest, known[k] "**") == 1) return known[k]
			return ""
		}
		function is_start(s) { return s ~ /^## §[0-9]+ / || item_name(s) != "" }
		function names_section(s,   rest) {
			if (s ~ /^## §[0-9]+ /) { rest = s; sub(/^## §[0-9]+ /, "", rest); return rest == ENVIRON["NAME"] || index(rest, ENVIRON["NAME"] " ") == 1 }
			return item_name(s) == ENVIRON["NAME"]
		}
		done { next }
		in_section && (is_start($0) || index($0, "=== END OF ") == 1) { done = 1; next }
		in_section { body[++n] = $0; next }
		names_section($0) {
			in_section = found = 1
			number = $0; sub(/^## §/, "", number); sub(/[^0-9].*/, "", number)
			ref = ($0 ~ /^## §/ ? "§" number : "item " number)
			if ($0 ~ /^[0-9]+\. \*\*/) { rest = $0; sub(/^[0-9]+\. \*\*[^*]+\*\*[ \t]*/, "", rest); if (rest != "") body[++n] = rest }
		}
		END {
			print (found ? "found\t" ref : "missing")
			first = 1; while (first <= n && body[first] ~ /^[ \t]*$/) first++
			last = n; while (last >= first && body[last] ~ /^[ \t]*$/) last--
			for (i = first; i <= last; i++) print body[i]
		}')
	[[ "${SECTION%%$'\n'*}" == found$'\t'* ]] || input_error "report section not found: $1 in ${OPT_REPORT}; expected a \"## §<n> $1\" or \"<n>. **$1:**\" line; send the report back to its author"
	SECTION_REF=${SECTION%%$'\n'*}
	SECTION_REF=${SECTION_REF#found$'\t'}
	SECTION=${SECTION#*$'\n'}
	if [[ "${SECTION}" == found$'\t'* ]]; then SECTION=""; fi
}

# section_count NAME — the count for an author-report section, or "" when
# the section's shape gives none; a zero part is left out. Eval set: "E<n>"
# item lines, a near-miss one naming "near-miss" anywhere in that line.
# Field table: "- " rows and the "Left unset:" list. Open points: top-level
# "<n>." items. A Field table or Open points section whose first text, after
# a leading "(...)" mode condition, starts with "none" counts as none.
section_count() {
	printf '%s\n' "${SECTION}" | NAME=$1 awk '
		ENVIRON["NAME"] == "Eval set" && /^(- )?E[0-9]+[ :(]/ { evals++; if (tolower($0) ~ /near[- ]miss/) near++ }
		ENVIRON["NAME"] == "Field table" && /^- / { rows++ }
		ENVIRON["NAME"] == "Field table" && /^Left unset:/ {
			unset_seen = 1; s = $0; sub(/^Left unset:[ \t]*/, "", s); sub(/[ \t.]+$/, "", s)
			unset = (s == "" || s == "none") ? 0 : split(s, parts, /,[ \t]*/)
		}
		ENVIRON["NAME"] == "Open points" && /^[0-9]+[.)] / { points++ }
		!have_first && NF { s = $0; sub(/^\([^)]*\)[ \t]*/, "", s); if (s != "") { first = s; have_first = 1 } }
		function part(n, noun, out) { return n ? out (out == "" ? "" : ", ") n " " noun : out }
		END {
			if (ENVIRON["NAME"] == "Eval set" && evals) {
				parts_text = part(near, "near-miss", part(evals - near, "prompts", ""))
				printf "%d (%s)\n", evals, parts_text
			}
			if (ENVIRON["NAME"] == "Field table") {
				parts_text = part(unset, "left unset", part(rows, (rows == 1 ? "row set" : "rows set"), ""))
				if (parts_text != "") print parts_text
				else if (unset_seen || first ~ /^none([ .(]|$)/) print "none"
			}
			if (ENVIRON["NAME"] == "Open points") { if (points) print points; else if (first ~ /^none([ .(]|$)/) print "none" }
		}'
}

# render_report_pointers — one field line per decision section: its count
# and where it sits in the author report.
render_report_pointers() {
	local section count
	for section in "Eval set" "Field table" "Open points"; do
		set_report_section "${section}"
		count=$(section_count "${section}")
		field "${section}" "${count:+${count} · }${SECTION_REF}"
	done
}

render_g2() {
	set_status "${LIGHT_GATE}" "G2 Approve the evals, the field table and the swarm size"
	if [[ -z "${OPT_RULEBOOK}" && -z "${HOME:-}" ]]; then usage_error "HOME is not set; give --rulebook DIR"; fi
	RULEBOOK=${OPT_RULEBOOK:-${HOME}/.claude/skills/standard-harness-authoring}
	strip_slashes RULEBOOK
	check_path --rulebook "${RULEBOOK}"
	need_file "--report file" "${OPT_REPORT}"
	add_data "Author report" "${OPT_REPORT}"
	if [[ "${OPT_KIND}" == skill ]]; then render_swarm_skill; else render_swarm_agent; fi
	render_report_pointers
}

# ---------------------------------------------------------------------------
# G3 Choose what to fix
# ---------------------------------------------------------------------------

# merged_view — the decision lines of --merged above "## Non-PASS item
# lines", paths already shortened, each as "<tag><tab><text>":
#   B  a blocking: item, "<ID> · <seat> · <file:line> · <Fix>", the Fix from
#      its item line below the heading cut at its first sentence or
#      SHORT_LINE_MAX characters ("not given" when there is none), or no
#      Fix part when the report has no such heading;
#   S  a should-fail: item, "<ID> · <file:line>";
#   I  an invalid-waiver: line without its tag, cut to SHORT_LINE_MAX;
#   F  "<label><tab><value>" for progress: and unchanged:;
#   C  "<label><tab><count>" for each other kind of line, in the order
#      first seen;
#   N  a lone tag when the heading is missing.
# An item's continuation lines join it; with several items for one ID, the
# one citing the merged line's location wins. A location "-" is left out.
merged_view() {
	read_clean "${OPT_MERGED}" | short_paths | MAX=${SHORT_LINE_MAX} awk "${CUT_AWK}"'
		function is_item(s) { return s ~ /^[A-Z][A-Za-z0-9]*-[^ ]+ (PASS|FAIL|N\/A|WAIVED|UNDECIDABLE|CHANGED)([ (]|$)/ }
		function fix_for(want, loc,   k, pick, p) {
			if (!head) return ""
			for (k = 1; k <= n; k++) if (id[k] == want) {
				if (!pick) pick = k
				if (loc != "-" && index(text[k], loc)) { pick = k; break }
			}
			if (!pick) return "not given"
			p = index(text[pick], " · Fix: ")
			return p ? first_sentence(substr(text[pick], p + length(" · Fix: "))) : "not given"
		}
		function first_sentence(s,   p, shown) {
			p = index(s, ". ")
			if (p) s = substr(s, 1, p - 1)
			shown = cut(s, max)
			return (p && shown == s) ? s "…" : shown
		}
		function joined(a, b, c, d,   out) {
			out = a
			if (b != "" && b != "-") out = out " · " b
			if (c != "" && c != "-") out = out " · " c
			if (d != "") out = out " · " d
			return out
		}
		function kind_label(t) {
			if (t == "waived:") return "Waived"
			if (t == "possible-duplicate:") return "Possible duplicates"
			if (t == "TRUNCATED") return "Truncated"
			if (t == "warning:") return "Warnings"
			if (t == "unknown-id:") return "Unknown IDs"
			if (t == "report:") return "Seat reports"
			return "Other lines"
		}
		BEGIN { max = ENVIRON["MAX"] + 0 }
		{ line[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++) if (line[i] == "## Non-PASS item lines") { head = i; break }
			last = head ? head - 1 : NR
			for (i = head + 1; head && i <= NR; i++) {
				if (is_item(line[i])) { split(line[i], w, " "); id[++n] = w[1]; text[n] = line[i] }
				else if (n && line[i] !~ /^[ \t]*$/) text[n] = text[n] " " line[i]
			}
			for (i = 1; i <= last; i++) {
				if (line[i] ~ /^[ \t]*$/ || line[i] ~ /^VERDICT: /) continue
				split(line[i], w, " ")
				if (w[1] == "blocking:") {
					print "B\t" joined(w[2], w[3], w[4], fix_for(w[2], w[4]))
				} else if (w[1] == "should-fail:") {
					print "S\t" joined(w[2], w[5], "", "")
				} else if (w[1] == "invalid-waiver:") {
					s = line[i]; sub(/^invalid-waiver:[ \t]*/, "", s); print "I\t" cut(s, max)
				} else if (w[1] == "progress:" || w[1] == "unchanged:") {
					s = line[i]; sub(/^[a-z]+:[ \t]*/, "", s)
					print "F\t" (w[1] == "progress:" ? "Progress" : "Unchanged") "\t" s
				} else {
					k = kind_label(w[1])
					if (!(k in count)) order[++kinds] = k
					count[k]++
				}
			}
			for (j = 1; j <= kinds; j++) printf "C\t%s\t%d\n", order[j], count[order[j]]
			if (!head) print "N"
		}'
}

# tag_lines TAG TEXT — the TEXT of each "TAG<tab>TEXT" line.
tag_lines() {
	printf '%s\n' "$2" | TAG=$1 awk -F '\t' '$1 == ENVIRON["TAG"] { print substr($0, length($1) + 2) }'
}

# render_merged — the Blocking, Should fix and Invalid waivers lists; queues
# the progress field lines and sets MERGED_COUNTS to the "<label><tab>
# <count>" lines for the field block.
render_merged() {
	local view lines label value
	view=$(merged_view)
	if [[ $'\n'"${view}"$'\n' == *$'\nN\n'* ]]; then
		warning "${OPT_MERGED} has no \"## Non-PASS item lines\" section; Fix lines not shown"
	fi
	lines=$(tag_lines B "${view}")
	list_block "Blocking" "${lines}"
	lines=$(tag_lines S "${view}")
	list_block "Should fix" "${lines}"
	lines=$(tag_lines I "${view}")
	list_block "Invalid waivers" "${lines}"
	lines=$(tag_lines F "${view}")
	while IFS=$'\t' read -r label value; do
		if [[ -n "${label}" ]]; then field "${label}" "${value}"; fi
	done < <(printf '%s\n' "${lines}")
	MERGED_COUNTS=$(tag_lines C "${view}")
}

# check_block NAME FILE — FILE's FAIL lines, each cut to SHORT_LINE_MAX, as
# a list; adds the count of its WARN lines to CHECK_WARNS.
check_block() {
	local view
	view=$(read_clean "$2" | short_paths | MAX=${SHORT_LINE_MAX} awk "${CUT_AWK}"'
		$2 == "FAIL" { print cut($0, ENVIRON["MAX"] + 0) } $2 == "WARN" { warn++ } END { printf "\036%d", warn }')
	list_block "$1 FAIL" "${view%%$'\036'*}"
	CHECK_WARNS="${CHECK_WARNS}$1 WARN"$'\t'"${view##*$'\036'}"$'\n'
}

# set_seat_counts — over each seat's latest report, NOT_READ: the count of
# Not checked entries that say a file was not read in full ("lines a-b
# only", "read only lines", "Grep only", "only Grepped", "not read"), and
# NOTES: the count of Notes entries other than "none". An entry is the
# section's first line or one of its continuation lines; Notes ends at Not
# checked, and either ends at Checklist feedback or an end line.
set_seat_counts() {
	local seat_files file pair
	NOT_READ=0 NOTES=0
	seat_files=$(latest_seat_files)
	while IFS= read -r file; do
		[[ -n "${file}" ]] || continue
		READ_FILES+=("${file}")
		pair=$(read_clean "${file}" | awk '
			function entry(s) { return s != "" && s != "none" }
			function partial(s) {
				s = tolower(s)
				return s ~ /lines [0-9]+ ?(–|-) ?[0-9]+ only/ || s ~ /read only lines? [0-9]/ ||
				index(s, "grep only") || index(s, "grepped only") || index(s, "only grepped") || index(s, "not read")
			}
			index($0, "Notes:") == 1 { section = "notes"; s = $0; sub(/^Notes:[ \t]*/, "", s); if (entry(s)) notes++; next }
			index($0, "Not checked:") == 1 { section = "checked"; s = $0; sub(/^Not checked:[ \t]*/, "", s); if (entry(s) && partial(s)) not_read++; next }
			index($0, "Checklist feedback:") == 1 || index($0, "=== END OF ") == 1 { section = ""; next }
			section == "notes" && NF { notes++ }
			section == "checked" && NF && partial($0) { not_read++ }
			END { printf "%d %d\n", notes, not_read }')
		NOTES=$((NOTES + ${pair% *}))
		NOT_READ=$((NOT_READ + ${pair#* }))
	done < <(printf '%s\n' "${seat_files}")
}

# render_eval_outcomes — per grade file, each outcome NEW failed or both arms
# passed, cut to SHORT_LINE_MAX; sets OTHER_OUTCOMES and FEEDBACK to the
# counts of the other outcomes and of the Outcome feedback lines other than
# "none".
render_eval_outcomes() {
	local grades file view outcomes="" counts
	OTHER_OUTCOMES=0 FEEDBACK=0
	grades=$(grade_files)
	while IFS= read -r file; do
		[[ -n "${file}" ]] || continue
		READ_FILES+=("${file}")
		set_eval_id "${file}"
		view=$(read_clean "${file}" | short_paths | ID=${EVAL_ID} MAX=${SHORT_LINE_MAX} awk "${OUTCOME_AWK}${CUT_AWK}"'
			/^O[0-9]+ · NEW / { new = new_status($0); if (new != "PASS" || base_status($0) == "PASS") print cut(ENVIRON["ID"] " " $0, ENVIRON["MAX"] + 0); else other++; next }
			index($0, "Outcome feedback:") == 1 { in_fb = 1; s = $0; sub(/^Outcome feedback:[ \t]*/, "", s); if (s != "none") feedback++; next }
			/^(Claims|Notes|Gaps):/ || index($0, "=== END OF ") == 1 { in_fb = 0; next }
			in_fb && NF { feedback++ }
			END { printf "\036%d %d", other, feedback }')
		outcomes="${outcomes}${view%%$'\036'*}"$'\n'
		counts=${view##*$'\036'}
		OTHER_OUTCOMES=$((OTHER_OUTCOMES + ${counts% *}))
		FEEDBACK=$((FEEDBACK + ${counts#* }))
	done < <(printf '%s\n' "${grades}")
	list_block "Eval outcomes" "${outcomes}"
}

# count_fields LINES — a count field line for each "<label><tab><count>".
count_fields() {
	local label count
	while IFS=$'\t' read -r label count; do
		if [[ -n "${label}" ]]; then count_field "${label}" "${count}"; fi
	done < <(printf '%s\n' "$1")
}

render_g3() {
	local verdict light="${LIGHT_GATE}"
	need_file "--merged file" "${OPT_MERGED}"
	need_file "--lint file" "${OPT_LINT}"
	add_data "Merged report" "${OPT_MERGED}"
	add_data "Lint" "${OPT_LINT}"
	require_line "VERDICT: " "${OPT_MERGED}" "a merge-verdicts.sh output saved as review-r<n>.md"
	verdict=${LINE#VERDICT: }
	verdict=${verdict%% *}
	require_line "SUMMARY " "${OPT_LINT}" "a whole lint.sh output"
	if [[ "${verdict}" == BLOCKED ]]; then light="${LIGHT_BLOCKED}"; fi
	set_status "${light}" "G3 Choose what to fix" "${verdict}"
	render_merged
	check_block "Lint" "${OPT_LINT}"
	if [[ -n "${OPT_HELP_CHECK}" ]]; then
		need_file "--help-check file" "${OPT_HELP_CHECK}"
		add_data "Help check" "${OPT_HELP_CHECK}"
		require_line "SUMMARY " "${OPT_HELP_CHECK}" "a whole help-check.sh output"
		check_block "Help check" "${OPT_HELP_CHECK}"
	fi
	render_eval_outcomes
	set_seat_counts
	count_fields "${MERGED_COUNTS}"
	count_fields "${CHECK_WARNS}"
	count_field "Not read in full" "${NOT_READ}"
	count_field "Seat notes" "${NOTES}"
	count_field "Other eval outcomes" "${OTHER_OUTCOMES}"
	count_field "Outcome feedback" "${FEEDBACK}"
}

# ---------------------------------------------------------------------------
# G4 Deploy
# ---------------------------------------------------------------------------

# set_link_now — sets LINK_NOW to what the --link path holds now; a symlink
# pointing anywhere but the source names its target whole.
set_link_now() {
	local points_to
	if [[ -L "${OPT_LINK}" ]]; then
		points_to=$(readlink -- "${OPT_LINK}" | tr -d '\000-\010\013-\037\177')
		if [[ "${points_to}" == "${OPT_TARGET}" ]]; then points_to="the source"; fi
		LINK_NOW="symlink to ${points_to}"
	elif [[ -e "${OPT_LINK}" ]]; then
		LINK_NOW="exists, not a symlink"
	else
		LINK_NOW="does not exist"
	fi
}

render_g4() {
	local checks
	set_status "${LIGHT_GATE}" "G4 Deploy"
	need_file "--merged file" "${OPT_MERGED}"
	need_file "--lint file" "${OPT_LINT}"
	add_data "Merged report" "${OPT_MERGED}"
	add_data "Lint" "${OPT_LINT}"
	require_line "SUMMARY " "${OPT_LINT}" "a whole lint.sh output"
	checks="lint.sh: ${LINE}"
	if [[ -n "${OPT_HELP_CHECK}" ]]; then
		need_file "--help-check file" "${OPT_HELP_CHECK}"
		add_data "Help check" "${OPT_HELP_CHECK}"
		require_line "SUMMARY " "${OPT_HELP_CHECK}" "a whole help-check.sh output"
		checks="${checks}"$'\n'"help-check.sh: ${LINE}"
	fi
	require_line "VERDICT: " "${OPT_MERGED}" "a merge-verdicts.sh output saved as review-r<n>.md"
	checks="${checks}"$'\n'"merge-verdicts.sh: ${LINE}"
	set_link_now
	checks=$(printf '%s\n' "${checks}" | short_paths)
	list_block "Checks" "${checks}"
	field "Source" "${OPT_TARGET}"
	field "Link" "${OPT_LINK}"
	field "Link now" "${LINK_NOW}"
}

# ---------------------------------------------------------------------------
# Closing report
# ---------------------------------------------------------------------------

# tagged FILE TAG — FILE's clean lines, each prefixed with "TAG<tab>".
tagged() {
	read_clean "$1" | TAG=$2 awk '{ print ENVIRON["TAG"] "\t" $0 }'
}

# finding_ids LAST EARLIER... — "open|waived|fixed<tab>ID" lines. Open is
# LAST's blocking: IDs and its should-fail: IDs the waivers file does not
# waive; waived is LAST's waived: IDs plus every should-fail: ID, in LAST or
# EARLIER, the waivers file waives; fixed is every EARLIER blocking: or
# should-fail: ID neither open nor waived. A waiver line is "[- ]<ID>: <reason> (owner)", as merge-verdicts.sh
# reads it.
finding_ids() {
	local last=$1 file
	shift
	{
		tagged "${last}" L
		for file in "$@"; do tagged "${file}" E; done
		if [[ -n "${OPT_WAIVERS}" ]]; then tagged "${OPT_WAIVERS}" W; fi
	} | awk -F '\t' '
		{ text = substr($0, index($0, "\t") + 1) }
		$1 == "W" {
			if (text ~ /^(- )?[A-Z][A-Z0-9]*-[0-9]+:[ \t]+.*[ \t][(]owner[)][ \t]*$/) { sub(/^- /, "", text); owner[substr(text, 1, index(text, ":") - 1)] = 1 }
			next
		}
		{ split(text, w, " ") }
		$1 == "L" && w[1] == "blocking:" { open[w[2]] = 1 }
		$1 == "L" && w[1] == "should-fail:" { should[w[2]] = 1 }
		$1 == "L" && w[1] == "waived:" { waived[w[2]] = 1 }
		$1 == "E" && (w[1] == "blocking:" || w[1] == "should-fail:") { earlier[w[2]] = 1 }
		$1 == "E" && w[1] == "should-fail:" && !(w[2] in should) { should_before[w[2]] = 1 }
		END {
			for (i in should) if (i in owner) waived[i] = 1; else open[i] = 1
			for (i in should_before) if (i in owner && !(i in open)) waived[i] = 1
			for (i in open) print "open\t" i
			for (i in waived) if (!(i in open)) print "waived\t" i
			for (i in earlier) if (!(i in open) && !(i in waived)) print "fixed\t" i
		}' | sort -u
}

# ids_field NAME KIND TABLE — the TABLE IDs of KIND as one ", "-joined
# field line; nothing when there is none.
ids_field() {
	local ids
	ids=$(printf '%s\n' "$3" | KIND=$2 awk -F '\t' '$1 == ENVIRON["KIND"] { out = out (out == "" ? "" : ", ") $2 } END { print out }')
	if [[ -n "${ids}" ]]; then field "$1" "${ids}"; fi
}

# set_merged — sets LAST_MERGED, LAST_VERDICT and EARLIER_MERGED from the
# run dir's review-r<n>.md files; names the last one in the Data block.
set_merged() {
	local merged_files file
	local -a merged=()
	merged_files=$(merged_reports)
	while IFS= read -r file; do
		if [[ -n "${file}" ]]; then merged+=("${file}"); READ_FILES+=("${file}"); fi
	done < <(printf '%s\n' "${merged_files}")
	[[ ${#merged[@]} -gt 0 ]] || return 0
	LAST_MERGED=${merged[${#merged[@]} - 1]}
	require_line "VERDICT: " "${LAST_MERGED}" "a merge-verdicts.sh output"
	LAST_VERDICT=${LINE#VERDICT: }
	add_data "Merged report" "${LAST_MERGED}"
	if [[ ${#merged[@]} -gt 1 ]]; then EARLIER_MERGED=("${merged[@]:0:${#merged[@]}-1}"); fi
}

render_findings() {
	local table
	[[ -n "${LAST_MERGED}" ]] || return 0
	if [[ -n "${OPT_WAIVERS}" ]]; then need_file "--waivers file" "${OPT_WAIVERS}"; fi
	table=$(finding_ids "${LAST_MERGED}" "${EARLIER_MERGED[@]+"${EARLIER_MERGED[@]}"}")
	ids_field "Fixed" fixed "${table}"
	ids_field "Waived" waived "${table}"
	ids_field "Open" open "${table}"
}

files_written_field() {
	local list="${OPT_RUN_DIR}/target-files.txt" files count
	if [[ -e "${list}" ]]; then
		need_file "target-files.txt" "${list}"
		files=$(read_clean "${list}")
		count=$(count_lines "${files}")
		field "Files written" "${count}"
	else
		field "Files written" "not recorded"
	fi
}

# evals_field — "Evals: none run", or the grade files' count with their
# outcome count and how many NEW did not pass, a zero count left out.
evals_field() {
	local grades file counts runs=0 outcomes=0 failed=0 value
	grades=$(grade_files)
	while IFS= read -r file; do
		[[ -n "${file}" ]] || continue
		READ_FILES+=("${file}")
		set_eval_id "${file}"
		counts=$(read_clean "${file}" | awk "${OUTCOME_AWK}"'
			/^O[0-9]+ · NEW / { n++; if (new_status($0) != "PASS") failed++ }
			END { printf "%d %d", n, failed }')
		runs=$((runs + 1))
		outcomes=$((outcomes + ${counts% *}))
		failed=$((failed + ${counts#* }))
	done < <(printf '%s\n' "${grades}")
	if (( runs == 0 )); then field "Evals" "none run"; return 0; fi
	value="${runs} run"
	if (( outcomes > 0 )); then value="${value} · ${outcomes} outcomes"; fi
	if (( failed > 0 )); then value="${value} · ${failed} NEW not PASS"; fi
	field "Evals" "${value}"
}

# set_state — NOT_RUN, ENDED, LIVE and DEPLOY from state.md.
set_state() {
	local state="${OPT_RUN_DIR}/state.md" values
	need_file "state.md" "${state}"
	add_data "State" "${state}"
	# One record per key, separated by RS (octal 036), which read_clean
	# has already removed from the text.
	values=$(read_clean "${state}" | awk '
		function value(s) { sub(/^- [A-Za-z ]+:[ \t]*/, "", s); return s }
		/^- Not run:/ { not_run = not_run value($0) "\n"; next }
		/^- Ended:/ && ended == "" { ended = value($0); next }
		/^- Deploy:/ && deploy == "" { deploy = value($0); next }
		/^- Live:/ && live == "" { live = value($0); next }
		END { printf "%s\036%s\036%s\036%s", not_run, ended, live, deploy }')
	NOT_RUN=${values%%$'\036'*}; values=${values#*$'\036'}
	ENDED=${values%%$'\036'*}; values=${values#*$'\036'}
	LIVE=${values%%$'\036'*}; DEPLOY=${values#*$'\036'}
}

render_closing() {
	local needs="The commit" count=1
	set_merged
	set_state
	field "Verdict" "${LAST_VERDICT:-not recorded}"
	render_findings
	files_written_field
	evals_field
	field "Ended" "${ENDED:-not recorded}"
	field "Live validation" "${LIVE:-not recorded}"
	flush_fields
	list_block "Not run" "${NOT_RUN}"
	if [[ "${DEPLOY}" != done* ]]; then needs="${needs}"$'\n'"The deploy"; count=2; fi
	list_block "Still needs the owner" "${needs}"
	if [[ -n "${OPT_WAIVERS}" ]]; then add_data "Waivers" "${OPT_WAIVERS}"; fi
	if [[ "${LAST_VERDICT}" == BLOCKED* ]]; then
		set_status "${LIGHT_BLOCKED}" "Closing report"
	else
		set_status "${LIGHT_OWNER}" "Closing report" "${count} need you"
	fi
}

# ---------------------------------------------------------------------------
# Path shortening (all text but the Data block and G4's source and link)
# ---------------------------------------------------------------------------

# set_repo_root — sets REPO_ROOT to the nearest dir at or above the target
# (an agent file: its dir) holding .git, or "" when there is none.
set_repo_root() {
	local dir=${OPT_TARGET}
	if [[ ! -d "${dir}" ]]; then dir=${dir%/*}; fi
	while [[ -n "${dir}" ]]; do
		if [[ -e "${dir}/.git" ]]; then REPO_ROOT=${dir}; return 0; fi
		dir=${dir%/*}
	done
	REPO_ROOT=""
}

# short_paths — stdin with each absolute path (a word opening with "/" and
# holding two or more parts) cut to its REPO_ROOT-relative form, or to its
# last part outside REPO_ROOT. A path already cut is left as it is.
short_paths() {
	ROOT=${REPO_ROOT} awk '
		function short(t,   root, tail) {
			root = ENVIRON["ROOT"]
			if (root != "" && index(t, root "/") == 1) return substr(t, length(root) + 2)
			tail = ""
			if (t ~ /\/$/) { tail = "/"; sub(/\/+$/, "", t) }
			sub(/.*\//, "", t)
			return t tail
		}
		{
			s = $0; out = ""
			while (match(s, /\/[^ \t\/]+\/[^ \t]*/)) {
				if (RSTART > 1 && substr(s, RSTART - 1, 1) ~ /[A-Za-z0-9._~$\/-]/) {
					out = out substr(s, 1, RSTART); s = substr(s, RSTART + 1); continue
				}
				out = out substr(s, 1, RSTART - 1) short(substr(s, RSTART, RLENGTH))
				s = substr(s, RSTART + RLENGTH)
			}
			print out s
		}'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
RULEBOOK="" LINE="" LINE_TOTAL="" CHECKLIST_FILE="" SECTION="" SECTION_REF="" EVAL_ID=""
LINK_NOW="" LAST_VERDICT="" LAST_MERGED="" DEPLOY="" REPO_ROOT="" MERGED_COUNTS="" CHECK_WARNS=""
NOT_READ=0 NOTES=0 OTHER_OUTCOMES=0 FEEDBACK=0 NOT_RUN="" ENDED="" LIVE=""
EARLIER_MERGED=()

set_repo_root
case "${OPT_GATE}" in
	g1) render_g1 ;;
	g2) render_g2 ;;
	g3) render_g3 ;;
	g4) render_g4 ;;
	*)  render_closing ;;
esac
flush_fields

if [[ "${OPT_PATHS}" -eq 1 ]]; then
	output=$(print_paths)
elif [[ "${OPT_GATE}" == g4 ]]; then
	output=$(blocks; data_block)
else
	output=$(blocks | short_paths; data_block)
fi
printf '%s\n' "${output}"
