#!/usr/bin/env bash
set -Eeuo pipefail
#
# merge-verdicts.sh — merge a swarm of skill-reviewer or agent-reviewer
#                     reports into one deterministic verdict
#                     (flow-harness-authoring, "Merging the swarm"
#                     steps 1-3). Read-only.
#
# WHY severity comes from the checklists, never the report: a reviewer can
# mislabel an item, and its own VERDICT line is a vote, not the result. Each
# item's MUST/SHOULD/MAY level is read from the rulebook's item lines
# ("- **<ID>** · <LEVEL> ·") in:
#   --kind skill  references/skills/[0-9]*.md + references/shared/lint-spec.md
#   --kind agent  references/agents/[0-9]*.md + references/skills/[0-9]*.md
#                 + references/shared/lint-spec.md (the skill checklists
#                 resolve the items an agent seat borrows: 02, STR-05/06,
#                 SAFE-01/03/07, checklist 10)
# An ID found in none of them is treated as MUST and listed as unknown-id, so
# a rulebook gap can never let a report pass silently. Every CONFORMANCE item
# is MUST.
#
# WHY a malformed report stops everything: a FAIL line the parser could not
# read would otherwise vanish from the verdict. So is a report that skips an
# item. Malformed means: an item line that breaks the grammar below; text
# between the header and the first item line; an item line after the
# VERDICT line, or in the ignored text after an end line; a CHECKLIST report
# missing a line for any item its own checklist file
# (references/skills/<nn>-*.md, or references/agents/<nn>-*.md for an
# agent-<nn> header) defines (extra IDs, such as borrowed items and LNT
# lines, are allowed); an end line naming another checklist than the header;
# or N/A, WAIVED or ALL N/A in a CONFORMANCE report.
#
# Item line: <ID> <STATUS>[ (<paren>)][ — <evidence>][ · Fix: <fix>]
#   PASS         any parenthetical; needs " — <evidence>"
#   FAIL         optional parts, tight FAIL(a,c) or spaced FAIL (a,c);
#                needs " — <evidence>"
#   N/A          needs (<why>); evidence optional
#   WAIVED       optional parenthetical; needs " — <waivers-file line>"
#   UNDECIDABLE  needs (<missing evidence>); evidence optional
#   CHANGED      needs (decision <ref>) and evidence; CONFORMANCE only
# Only FAIL may touch its parenthetical. A line starts an item only when its
# first token is an item ID and its second begins with a status keyword (or
# it is "ALL N/A — ..."); any other non-blank line between the header and
# the VERDICT line continues the item above it, and blank lines there are
# skipped. An item's location and status come from its first line.
#
# WAIVED is honoured only for a SHOULD or MAY item named by an owner line
# "<ID>: <reason> (owner)" in the --waivers file; any other WAIVED counts as
# a FAIL at its level, so a reviewer cannot waive a MUST item or forge one.
#
# One file may hold several reports (a combined agent seat): every report
# ends at its end line "=== END OF <checklist> ===". The last report's end
# line is optional, because the flow strips it before saving a reply. Text
# after an end line, up to the next line starting "CHECKLIST " or the end of
# the file, is ignored and reported as a warning: line.
#
# Tolerated wrappers, each only around the whole file: leading/trailing
# blank lines, trailing whitespace on a line, one wrapping ``` fence, the
# Claude Code hand-back frame (a first line "The text below is the final
# report of a subagent ... The report follows:" with every following line
# indented by two spaces), and "[harness: ...]" notice lines above the
# first header, with or without the frame, which are relayed as warning:
# lines. The frame is accepted only in that exact shape: a report line at
# column zero under it is malformed, since the harness indents every report
# line and an unindented one would be forged.
#
# Ownership dedupe tidies the listing and never changes the verdict: the
# VERDICT and blocking: lines are computed over every line, dropped or not.
# When FAIL lines from two or more different CHECKLIST reports cite the same
# file:line, the line ranked highest is kept and a lower-ranked line no more
# severe than it is listed as dropped-duplicate; a more severe one is kept
# too. Rank: any LNT-* ID first, then the report's checklist:
#   --kind skill  09 11 04 06 07 05 10 03 01 08 02 (the rulebook's "Which
#                 checklist owns a problem" table)
#   --kind agent  agent-01 ... agent-08 in number order. references/agents/
#                 README.md "Seating and ownership" assigns owners by topic
#                 (tool grants agent-02, write boundaries agent-07, backed
#                 claims agent-05, parseable reply agent-06), which gives no
#                 total order for two lines at one file:line, so number
#                 order is the stand-in.
# The match is on the file:line text exactly as written.
#
# Usage: see --help.
#
# Output (stdout, plain text, sorted, no timestamps):
#   VERDICT: PASS | VERDICT: BLOCKED (<sorted unique blocking IDs>)
#   report: <nn|agent-nn|CONFORMANCE> reviewer=<id> pass=N fail=N n/a=N|all
#           waived=N undecidable=N changed=N file=<report file>
#           target=<path @ sha>
#   blocking: <ID> <checklist> <file:line|-> <status>
#   should-fail: <ID> <SHOULD|MAY> <checklist> <file:line|-> <status>
#   unknown-id: <ID> <checklist> <file:line|-> <status>
#   dropped-duplicate: <ID> (kept <ID>) <checklist>-><checklist> <file:line>
#   warning: <report file>: <what>
#   TRUNCATED showing N of M lines
#           (only when --max-lines cut dropped-duplicate: and warning:
#           lines, the only lines it caps)
#   With --previous FILE, last:
#   progress: fixed <n> · still open <n> · new <n>
#   unchanged: yes          (only when fixed and new are both 0)
#   The two lines compare the first token of every blocking: and
#   should-fail: line here with those in FILE, as two ID sets.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0    PASS
#   1    BLOCKED
#   2    usage error (bad option, missing or bad --kind, a --max-lines
#        value that is not a whole number, no report file; a report, --waivers or --previous file missing, unreadable or with a
#        newline in its path; a --previous file with no "VERDICT: " line)
#   3    one or more malformed reports (each problem listed on stderr)
#   4    rulebook not found or unreadable (no references/ dir, no
#        lint-spec.md, no checklist files for the kind, or no item lines)
#   5    internal error (the message names the command), or a required tool
#        is missing
#   130  interrupted (INT)
#   143  terminated (TERM)
#
# Portability: Bash 3.2+ (macOS) and Linux. Needs only POSIX awk, cat,
#   dirname, mktemp and rm, checked at start; works with BSD awk, gawk and
#   mawk. LC_ALL=C throughout so matching and sorting are byte-wise and
#   identical everywhere.
#

LC_ALL=C
export LC_ALL
unset CDPATH

PROG=${0##*/}

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout carries only the merged verdict)
# ---------------------------------------------------------------------------
error() { printf '%s: error: %s\n' "${PROG}" "$*" >&2; }

# shellcheck disable=SC2329  # invoked indirectly via the ERR trap
internal_error() {
	# A failing command substitution reports once, from the parent shell,
	# which names the whole assignment.
	(( BASH_SUBSHELL == 0 )) || exit 5
	printf '%s: internal error at line %s: %s\n' "${PROG}" "$1" "$2" >&2
	printf '%s: expected that command to succeed; nothing was merged. Try: re-run with the same arguments, check free space in %s and that the rulebook files are readable; if it repeats, report the command above.\n' \
		"${PROG}" "${TMPDIR:-/tmp}" >&2
	exit 5
}
trap 'internal_error "${LINENO}" "${BASH_COMMAND}"' ERR

usage() {
	cat <<EOF
usage: ${PROG} [--rulebook DIR] [--waivers FILE] [--previous FILE]
                  [--max-lines N] --kind skill|agent REPORT_FILE... [-h|--help]

Merge skill-reviewer (--kind skill) or agent-reviewer (--kind agent)
reports into one verdict. Severity comes from the rulebook's checklists,
never from the reports; each report's own VERDICT line is recomputed and a
disagreement is printed as a warning. A file may hold several reports, each
ending with its "=== END OF <checklist> ===" line (a combined agent seat);
text after an end line, up to the next "CHECKLIST " line, is ignored with a
warning.

Item line: <ID> <STATUS>[ (<paren>)][ — <evidence>][ · Fix: <fix>]
  PASS (any paren) and FAIL / FAIL(a,c) / FAIL (a,c) need " — <evidence>";
  N/A (<why>) and UNDECIDABLE (<what is missing>) take evidence or not;
  WAIVED takes a paren or not, then " — <waivers-file line>";
  CHANGED (decision <ref>) needs evidence and is for CONFORMANCE only.
A non-blank line that does not start an item continues the item above it.

Options:
  --kind KIND      skill: levels from references/skills/; agent: from
                     references/agents/ plus references/skills/ (borrowed
                     items). Both also read references/shared/lint-spec.md.
  --rulebook DIR   The standard-harness-authoring root (holds references/).
                     Default: the directory above this script.
  --waivers FILE   The target's waivers file. A WAIVED item stands only when
                     it is SHOULD or MAY and FILE has its "<ID>: <reason>
                     (owner)" line; any other WAIVED counts as a FAIL at its
                     level, with a warning. Without it, every WAIVED does.
  --previous FILE  A previous run's saved output. Adds, last:
                     "progress: fixed <n> · still open <n> · new <n>" over
                     the blocking: and should-fail: IDs, and "unchanged: yes"
                     when nothing was fixed and nothing is new.
  --max-lines N    Print at most N dropped-duplicate: and warning: lines
                     (default 200; 0 prints all). When lines are cut, one
                     "TRUNCATED showing N of M lines" line follows them.
                     VERDICT, report:, blocking:, should-fail:, unknown-id:,
                     progress: and unchanged: are never cut.
  -h, --help       Show this help.

Output lines: VERDICT, report:, blocking:, should-fail:, unknown-id:,
dropped-duplicate:, warning: (sorted, plain text); TRUNCATED when
--max-lines cut lines; then progress: and unchanged: with --previous.

Required tools: awk, cat, dirname, mktemp, rm.

Exit codes:
  0    PASS
  1    BLOCKED
  2    usage error (bad option, missing or bad --kind, a --max-lines value
       that is not a whole number, no report; a report,
       --waivers or --previous file missing or unreadable; a --previous
       file that is not a ${PROG} output)
  3    malformed report(s): header, item lines or VERDICT line missing or
       bad, text before the first item, an own-checklist item missing, an
       item after VERDICT or after an end line, an end line that names
       another checklist, or a status CONFORMANCE does not allow
  4    rulebook not found or unreadable
  5    internal error, or a required tool is missing
  130  interrupted (INT)
  143  terminated (TERM)
EOF
}

usage_error() {
	usage >&2
	error "$*"
	exit 2
}

need_arg() {
	[[ -n "${2:-}" ]] || usage_error "option $1 requires an argument"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_RULEBOOK=""
OPT_KIND=""
OPT_WAIVERS=""
OPT_PREVIOUS=""
# 200, as lint.sh --max-lines: the listing stays readable in one Read;
# VERDICT and blocking: lines are never cut.
OPT_MAX_LINES=200
REPORTS=()

while [[ $# -gt 0 ]]; do
	case "$1" in
		--rulebook) need_arg "$1" "${2:-}"; OPT_RULEBOOK=$2; shift ;;
		--kind)     need_arg "$1" "${2:-}"; OPT_KIND=$2; shift ;;
		--waivers)  need_arg "$1" "${2:-}"; OPT_WAIVERS=$2; shift ;;
		--previous) need_arg "$1" "${2:-}"; OPT_PREVIOUS=$2; shift ;;
		--max-lines) need_arg "$1" "${2:-}"; OPT_MAX_LINES=$2; shift ;;
		-h|--help)  usage; exit 0 ;;
		--)         shift; break ;;
		-*)         usage_error "unknown option: $1" ;;
		*)          REPORTS+=("$1") ;;
	esac
	shift
done
while [[ $# -gt 0 ]]; do
	REPORTS+=("$1")
	shift
done

for tool in awk cat dirname mktemp rm; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		error "required tool missing: ${tool}; expected a POSIX base system that provides it; try fixing PATH or installing your OS's base utilities"
		exit 5
	fi
done

case "${OPT_KIND}" in
	skill|agent) ;;
	"") usage_error "--kind skill|agent is required" ;;
	*)  usage_error "--kind must be skill or agent, got: ${OPT_KIND}" ;;
esac
[[ "${OPT_MAX_LINES}" =~ ^[0-9]+$ ]] || usage_error "--max-lines must be a whole number (0 prints all), got: ${OPT_MAX_LINES}"
[[ ${#REPORTS[@]} -gt 0 ]] || usage_error "at least one REPORT_FILE is required"

newline=$'\n'

# input_file_problem — print why PATH (described as WHAT) cannot be read, or
# nothing when it can.
input_file_problem() {
	local what=$1 path=$2
	if [[ "${path}" == *"${newline}"* ]]; then
		printf '%s path contains a newline: %s...' "${what}" "${path%%"${newline}"*}"
	elif [[ ! -f "${path}" || ! -r "${path}" ]]; then
		printf '%s does not exist or is not readable: %s' "${what}" "${path}"
	fi
}

bad_args=0
for report in "${REPORTS[@]}"; do
	problem=$(input_file_problem "report file" "${report}")
	if [[ -n "${problem}" ]]; then
		error "${problem}"
		bad_args=1
	fi
done
if [[ ${bad_args} -ne 0 ]]; then
	usage >&2
	exit 2
fi
if [[ -n "${OPT_WAIVERS}" ]]; then
	problem=$(input_file_problem "--waivers file" "${OPT_WAIVERS}")
	[[ -z "${problem}" ]] || usage_error "${problem}"
fi
if [[ -n "${OPT_PREVIOUS}" ]]; then
	problem=$(input_file_problem "--previous file" "${OPT_PREVIOUS}")
	[[ -z "${problem}" ]] || usage_error "${problem}"
	if ! awk 'index($0, "VERDICT: ") == 1 { found = 1; exit } END { exit !found }' <"${OPT_PREVIOUS}"; then
		usage_error "--previous file is not a ${PROG} output (no line starts 'VERDICT: '): ${OPT_PREVIOUS}"
	fi
fi

# ---------------------------------------------------------------------------
# Rulebook: resolve to an absolute path (awk would read a relative operand
# containing "=" as a variable assignment) and check it before any parsing.
# ---------------------------------------------------------------------------
readonly RULEBOOK_HINT="expected the standard-harness-authoring root holding references/skills/[0-9]*.md, references/agents/[0-9]*.md and references/shared/lint-spec.md; try --rulebook DIR"

rulebook_error() {
	error "$1; ${RULEBOOK_HINT}"
	exit 4
}

if [[ -z "${OPT_RULEBOOK}" ]]; then
	SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || rulebook_error "cannot resolve this script's directory"
	OPT_RULEBOOK=${SCRIPT_DIR%/*}
fi
if [[ ! -d "${OPT_RULEBOOK}" ]] || ! RULEBOOK=$(cd -P -- "${OPT_RULEBOOK}" && pwd -P); then
	rulebook_error "rulebook directory not found: ${OPT_RULEBOOK}"
fi
REFS_DIR="${RULEBOOK}/references"
LINT_SPEC="${REFS_DIR}/shared/lint-spec.md"
[[ -d "${REFS_DIR}" ]] || rulebook_error "rulebook has no references/ directory: ${RULEBOOK}"

shopt -s nullglob
SKILL_CHECKLISTS=("${REFS_DIR}"/skills/[0-9]*.md)
AGENT_CHECKLISTS=("${REFS_DIR}"/agents/[0-9]*.md)
shopt -u nullglob
[[ ${#SKILL_CHECKLISTS[@]} -gt 0 ]] || rulebook_error "rulebook has no skill checklist files (references/skills/[0-9]*.md): ${RULEBOOK}"
REF_FILES=("${SKILL_CHECKLISTS[@]}" "${LINT_SPEC}")
if [[ "${OPT_KIND}" == agent ]]; then
	[[ ${#AGENT_CHECKLISTS[@]} -gt 0 ]] || rulebook_error "rulebook has no agent checklist files (references/agents/[0-9]*.md): ${RULEBOOK}"
	REF_FILES+=("${AGENT_CHECKLISTS[@]}")
fi
for ref in "${REF_FILES[@]}"; do
	[[ -f "${ref}" && -r "${ref}" ]] || rulebook_error "rulebook file missing or unreadable: ${ref}"
done

# ---------------------------------------------------------------------------
# Cleanup: remove the private work dir on any exit path. INT/TERM trapped
# separately from EXIT so an interrupted run reports 130/143.
# ---------------------------------------------------------------------------
WORK_DIR=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[[ -z "${WORK_DIR}" ]] || rm -rf -- "${WORK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/merge-verdicts.XXXXXX")
WORK_DIR=$(cd -P -- "${WORK_DIR}" && pwd -P)

# Each report file is read exactly once, into a numbered private copy; awk
# keys the file by that number and takes its display name from names.txt.
NAMES_FILE="${WORK_DIR}/names.txt"
: >"${NAMES_FILE}"
COPIES=()
index=0
for report in "${REPORTS[@]}"; do
	index=$((index + 1))
	copy="${WORK_DIR}/report.${index}"
	if ! cat -- "${report}" >"${copy}"; then
		error "failed to read report file: ${report}; expected it to stay readable after the start-up check; try re-running, and check that nothing moved, truncated or re-permissioned it"
		exit 2
	fi
	printf '%s\n' "${report}" >>"${NAMES_FILE}"
	COPIES+=("${copy}")
done

# copy_input — read an optional input once into the work dir, so awk gets a
# path it cannot mistake for a variable assignment.
copy_input() {
	local what=$1 path=$2 copy=$3
	if ! cat -- "${path}" >"${copy}"; then
		error "failed to read ${what}: ${path}; expected it to stay readable after the start-up check; try re-running, and check that nothing moved, truncated or re-permissioned it"
		exit 2
	fi
}

OPTIONAL_ARGS=()
HAVE_WAIVERS=0
HAVE_PREVIOUS=0
if [[ -n "${OPT_WAIVERS}" ]]; then
	HAVE_WAIVERS=1
	copy_input "--waivers file" "${OPT_WAIVERS}" "${WORK_DIR}/waivers.txt"
	OPTIONAL_ARGS+=(phase=waivers "${WORK_DIR}/waivers.txt")
fi
if [[ -n "${OPT_PREVIOUS}" ]]; then
	HAVE_PREVIOUS=1
	copy_input "--previous file" "${OPT_PREVIOUS}" "${WORK_DIR}/previous.txt"
	OPTIONAL_ARGS+=(phase=previous "${WORK_DIR}/previous.txt")
fi

# ---------------------------------------------------------------------------
# The merge itself: one awk pass. Phase "names" reads display names,
# "skillrefs"/"agentrefs"/"lintrefs" the item levels, "files" the copies;
# END splits each file into reports, validates every report before computing
# anything, then prints the merged verdict.
#
# awk's own result codes are offset by AWK_CODE_BASE so a crashed awk (exit
# 1 or 2 on every awk) can never pass for PASS, BLOCKED or malformed.
# ---------------------------------------------------------------------------
readonly AWK_CODE_BASE=20
AWK_PROGRAM="${WORK_DIR}/merge.awk"
cat >"${AWK_PROGRAM}" <<'AWK'
BEGIN {
	DASH = " — "
	ITEM_SHAPE = "^(([A-Z]+-[0-9]+|FIELD-[^ ]+) (PASS|FAIL|N/A|WAIVED|UNDECIDABLE|CHANGED)|ALL N/A)"
	FRAME = "^ ?The text below is the final report of a subagent .*The report follows:$"
	END_LINE = "^=== END OF [^ ]+ ===$"
	HARNESS_NOTICE = "^\\[harness: .*\\]$"
	STATUS_START = "^(PASS|FAIL|N/A|WAIVED|UNDECIDABLE|CHANGED)"
	WAIVER_LINE = "^(- )?([A-Z][A-Z0-9]*-[0-9]+):[[:space:]]+(.*)[[:space:]][(]owner[)][[:space:]]*$"
	nprec = split("09 11 04 06 07 05 10 03 01 08 02", order, " ")
	for (i = 1; i <= nprec; i++) skill_prec[order[i]] = i
	LEVEL_RANK["MAY"] = 1; LEVEL_RANK["SHOULD"] = 2; LEVEL_RANK["MUST"] = 3
	nerr = 0; nlevels = 0; nreports = 0
	waivers_name = clean(ENVIRON["MV_WAIVERS_NAME"])
	rulebook_hint = ENVIRON["MV_RULEBOOK_HINT"]
}

phase == "names" { fname[FNR] = clean($0); next }

phase == "waivers" {
	if ($0 ~ WAIVER_LINE) {
		line = $0
		sub(/^- /, "", line)
		owner_waived[substr(line, 1, index(line, ":") - 1)] = 1
	}
	next
}

phase == "previous" {
	if (index($0, "blocking: ") == 1) previous_ids[first_token(substr($0, 11))] = 1
	else if (index($0, "should-fail: ") == 1) previous_ids[first_token(substr($0, 14))] = 1
	next
}

phase == "skillrefs" || phase == "agentrefs" || phase == "lintrefs" {
	if (FNR == 1) {
		base = FILENAME
		sub(/.*\//, "", base)
		ref_key = ""
		if (phase != "lintrefs" && base ~ /^[0-9][0-9]-/)
			ref_key = (phase == "agentrefs" ? "agent-" : "") substr(base, 1, 2)
		if (ref_key != "") known_chk[ref_key] = 1
	}
	line = rtrim($0)
	if (line ~ /^- \*\*[A-Z]+-[0-9]+\*\* · [A-Z]+ · /) {
		rest = substr(line, 5)
		id = substr(rest, 1, index(rest, "**") - 1)
		lvl = substr(rest, length(id) + 3 + length(" · "))
		lvl = substr(lvl, 1, index(lvl, " ") - 1)
		record_level(id, lvl)
		if (ref_key != "") own_ids[ref_key] = own_ids[ref_key] " " id
	}
	next
}

phase == "files" {
	f = FILENAME
	sub(/.*\./, "", f)
	f += 0
	nl[f] = FNR
	raw[f, FNR] = $0
	next
}

END {
	if (nlevels == 0) {
		print prog ": error: no checklist item lines found under the rulebook's references/; " rulebook_hint > "/dev/stderr"
		exit code_base + 4
	}
	for (f = 1; f <= nfiles; f++) split_file(f)
	for (r = 1; r <= nreports; r++) parse_report(r)
	if (nerr > 0) {
		for (i = 1; i <= nerr; i++) print prog ": error: " errs[i] > "/dev/stderr"
		print prog ": error: " nbad " malformed report(s) in " nfiles " file(s); re-dispatch them, nothing was merged" > "/dev/stderr"
		exit code_base + 3
	}
	sort_reports()
	check_own_verdicts()
	warn_waived_as_fail()
	dedupe()
	result = print_result()
	if (have_previous) print_progress()
	exit code_base + result
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function rtrim(s) { sub(/[ \t\r]+$/, "", s); return s }
function is_blank(s) { return s ~ /^[ \t\r]*$/ }
function first_token(s) { sub(/[ \t].*/, "", s); return s }

# clean — echo report text safely: control characters become "?" so a
# crafted report cannot forge or split output lines.
function clean(s) { gsub(/[[:cntrl:]]/, "?", s); return s }

function record_level(id, lvl) {
	if (!(lvl in LEVEL_RANK)) lvl = "MUST"
	if (!(id in level) || LEVEL_RANK[lvl] > LEVEL_RANK[level[id]]) level[id] = lvl
	nlevels++
}

function add_error(r, msg) {
	if (!bad[r]) nbad++
	bad[r] = 1
	errs[++nerr] = rname[r] ": " msg
}

# add_file_error — a problem that stops a whole file from being split into
# reports; it counts as one malformed report.
function add_file_error(f, msg) {
	nbad++
	errs[++nerr] = fname[f] ": " msg
}

function first_nonblank(f, from, to,   i) {
	for (i = from; i <= to; i++) if (!is_blank(raw[f, i])) return i
	return 0
}

function last_nonblank(f, from, to,   i) {
	for (i = to; i >= from; i--) if (!is_blank(raw[f, i])) return i
	return 0
}

function last_index(s, t,   p, q) {
	p = 0
	while ((q = index(substr(s, p + 1), t)) > 0) p += q
	return p
}

# close_paren — index of the ")" matching the "(" at position q, or 0.
function close_paren(s, q,   depth, i, c) {
	depth = 0
	for (i = q; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c == "(") depth++
		else if (c == ")" && --depth == 0) return i
	}
	return 0
}

function isort(a, n,   i, j, t) {
	for (i = 2; i <= n; i++) {
		t = a[i]
		for (j = i - 1; j >= 1 && (a[j] "") > (t ""); j--) a[j + 1] = a[j]
		a[j + 1] = t
	}
}

# sorted_ids — the space/comma-separated IDs in s, sorted, unique, ", "-joined.
function sorted_ids(s,   parts, n, i, out, prev) {
	gsub(/,/, " ", s)
	n = split(s, parts, " ")
	isort(parts, n)
	out = ""; prev = ""
	for (i = 1; i <= n; i++) {
		if (parts[i] == prev) continue
		out = out (out == "" ? "" : ", ") parts[i]
		prev = parts[i]
	}
	return out
}

# ---------------------------------------------------------------------------
# Splitting one file into reports
# ---------------------------------------------------------------------------
function split_file(f,   first, last, i, start, k, j, framed) {
	first = first_nonblank(f, 1, nl[f])
	if (!first) { add_file_error(f, "empty file: no header, no item lines, no VERDICT line"); return }
	last = last_nonblank(f, 1, nl[f])

	framed = rtrim(raw[f, first]) ~ FRAME
	if (framed) {
		raw[f, first] = ""
		for (i = first + 1; i <= nl[f]; i++) {
			if (is_blank(raw[f, i])) continue
			if (substr(raw[f, i], 1, 2) != "  ") {
				add_file_error(f, "line " i ": under the hand-back frame every report line is indented by two spaces; this one is not, so it is not part of the report")
				return
			}
			raw[f, i] = substr(raw[f, i], 3)
		}
		first = first_nonblank(f, first + 1, last)
	}
	while (first && rtrim(raw[f, first]) ~ HARNESS_NOTICE) {
		warns[++nwarn] = fname[f] ": harness notice above the report, relay it to the owner: " clean(rtrim(raw[f, first]))
		first = first_nonblank(f, first + 1, last)
	}
	if (!first) { add_file_error(f, (framed ? "hand-back frame" : "harness notice") " with no report under it"); return }

	if (rtrim(raw[f, first]) ~ /^```[A-Za-z0-9_-]*$/) {
		if (last == first || rtrim(raw[f, last]) != "```") {
			add_file_error(f, "line " first ": code fence opened, but the last non-blank line does not close it")
			return
		}
		first = first_nonblank(f, first + 1, last - 1)
		if (!first) { add_file_error(f, "empty report inside the code fence: no header, no item lines, no VERDICT line"); return }
		last = last_nonblank(f, first, last - 1)
	}

	start = first; k = 0
	for (i = first; i <= last; i++) {
		if (rtrim(raw[f, i]) !~ END_LINE) continue
		if (!first_nonblank(f, start, i - 1)) {
			add_file_error(f, "line " i ": end line with no report above it")
			nreports -= k
			return
		}
		new_report(f, start, i - 1, rtrim(raw[f, i]), i)
		k++
		start = skip_after_end(f, i, last)
		i = start - 1
	}
	if (first_nonblank(f, start, last)) { new_report(f, start, last, "", 0); k++ }
	for (j = nreports - k + 1; j <= nreports; j++)
		rname[j] = (k == 1) ? fname[f] : fname[f] " (report " (j - nreports + k) " of " k ")"
}

# skip_after_end — ignore the text after the end line at line e, up to the
# next "CHECKLIST " line or the file's last line; warn when any of it is
# non-blank, and refuse an item line there, which would otherwise drop out
# of the verdict unseen. Return the line the next report starts at.
function skip_after_end(f, e, last,   next_start, from, to, i, checklist) {
	for (next_start = e + 1; next_start <= last; next_start++)
		if (raw[f, next_start] ~ /^CHECKLIST /) break
	from = first_nonblank(f, e + 1, next_start - 1)
	if (!from) return next_start
	to = last_nonblank(f, from, next_start - 1)
	checklist = rtrim(raw[f, e])
	sub(/^=== END OF /, "", checklist)
	sub(/ ===$/, "", checklist)
	warns[++nwarn] = fname[f] ": " (to - from + 1) " line(s) after the end line of " clean(checklist) " ignored"
	for (i = from; i <= to; i++)
		if (rtrim(raw[f, i]) ~ ITEM_SHAPE)
			add_file_error(f, "line " i ": item line after the end line of " clean(checklist) "; every item belongs above its report's VERDICT line")
	return next_start
}

function new_report(f, from, to, end_line, end_at) {
	nreports++
	rfile[nreports] = f
	rfrom[nreports] = from
	rto[nreports] = to
	rend[nreports] = end_line
	rend_at[nreports] = end_at
}

# ---------------------------------------------------------------------------
# Parsing one report
# ---------------------------------------------------------------------------
function parse_report(r,   f, first, last, i, l, e, start, stop, scan_end, allna, started, v) {
	f = rfile[r]
	first = first_nonblank(f, rfrom[r], rto[r])
	last = last_nonblank(f, rfrom[r], rto[r])

	l = rtrim(raw[f, first])
	e = parse_header(r, l)
	if (e != "") add_error(r, "line " first ": " e)
	start = (l ~ /^CHECKLIST /) ? first + 1 : first
	if (e == "" && rend[r] != "" && rend[r] != "=== END OF " chk[r] " ===")
		add_error(r, "line " rend_at[r] ": end line '" clean(rend[r]) "' does not match the header's checklist " chk[r])

	stop = 0
	for (i = start; i <= last; i++) if (raw[f, i] ~ /^VERDICT:/) { stop = i; break }
	scan_end = stop ? stop - 1 : last
	if (!stop) for (i = start; i <= last; i++) if (raw[f, i] ~ /^(Notes|Checklist feedback|KIND|FLOWS):/) { scan_end = i - 1; break }

	nitems[r] = 0; allna = 0; started = 0
	for (i = start; i <= scan_end; i++) {
		l = rtrim(raw[f, i])
		if (l == "") continue
		if (l ~ /^ALL N\/A — [^ ]/) { allna++; started = 1; continue }
		if (starts_item(l)) {
			started = 1
			e = parse_item(r, l)
			if (e != "") add_error(r, "line " i ": " e)
		} else if (!started) {
			add_error(r, "line " i ": text before the first item line, so it continues no item: '" clean(l) "'")
		}
	}
	allna_report[r] = allna
	if (allna > 1) add_error(r, "more than one ALL N/A line")
	if (allna && mode[r] == "CONFORMANCE") add_error(r, "ALL N/A is not valid in a CONFORMANCE report")
	if (allna && kind == "agent") add_error(r, "ALL N/A is not valid in an agent-reviewer report; it writes one N/A line per item")
	if (allna && nitems[r] > 0) add_error(r, "ALL N/A must be the only line between the header and the VERDICT line")
	if (!allna && nitems[r] == 0) add_error(r, "no item lines (and no ALL N/A line)")
	if (!allna && nitems[r] > 0 && mode[r] == "CHECKLIST") check_coverage(r)

	if (!stop) { add_error(r, "no VERDICT line"); return }
	for (i = stop + 1; i <= last; i++)
		if (rtrim(raw[f, i]) ~ ITEM_SHAPE)
			add_error(r, "line " i ": item line after the VERDICT line; every item belongs above it (or an end line is missing between two reports)")
	v = rtrim(raw[f, stop])
	if (v == "VERDICT: PASS") {
		claimed[r] = "PASS"
	} else if (v ~ /^VERDICT: BLOCKED \(.*[^ ,].*\)$/) {
		claimed[r] = "BLOCKED (" sorted_ids(substr(v, 19, length(v) - 19)) ")"
	} else {
		add_error(r, "line " stop ": malformed VERDICT line; expected 'VERDICT: PASS' or 'VERDICT: BLOCKED (<IDs>)'")
	}
}

# check_coverage — every item its own checklist file defines needs a line;
# extra IDs (borrowed items, LNT lines) are allowed.
function check_coverage(r,   ids, n, i, missing) {
	n = split(own_ids[chk[r]], ids, " ")
	missing = ""
	for (i = 1; i <= n; i++) if (!((r, ids[i]) in seen_id)) missing = missing " " ids[i]
	if (missing != "") add_error(r, "missing item line(s) for checklist " chk[r] ": " sorted_ids(missing))
}

# parse_header — fill mode/chk/rank/reviewer/target for report r; return ""
# or the reason the header is bad.
function parse_header(r, l,   rest, c, sep, rv, at, tgt, sha, unc, e) {
	mode[r] = ""
	if (l !~ /^CHECKLIST [^ ]+ · REVIEWER [^ ]+ · TARGET .+ @ .+$/)
		return "missing or malformed header; expected 'CHECKLIST <" (kind == "agent" ? "agent-nn" : "nn|CONFORMANCE") "> · REVIEWER <id> · TARGET <path> @ <sha>[ (uncommitted)]'"
	rest = substr(l, length("CHECKLIST ") + 1)
	c = substr(rest, 1, index(rest, " ") - 1)
	rest = substr(rest, length(c) + 1)
	sep = " · REVIEWER "
	if (substr(rest, 1, length(sep)) != sep) return "header: expected ' · REVIEWER <id>' after the checklist"
	rest = substr(rest, length(sep) + 1)
	rv = substr(rest, 1, index(rest, " ") - 1)
	rest = substr(rest, length(rv) + 1)
	sep = " · TARGET "
	if (substr(rest, 1, length(sep)) != sep) return "header: expected ' · TARGET <path> @ <sha>' after the reviewer"
	rest = substr(rest, length(sep) + 1)
	at = last_index(rest, " @ ")
	tgt = substr(rest, 1, at - 1)
	sha = substr(rest, at + 3)
	unc = ""
	if (sha ~ / \(uncommitted\)$/) { unc = " (uncommitted)"; sha = substr(sha, 1, length(sha) - length(unc)) }
	# 7 = git's shortest abbreviation, 64 = a full SHA-256.
	if (sha != "unknown" && (sha !~ /^[0-9a-f]+$/ || length(sha) < 7 || length(sha) > 64))
		return "header: the sha must be 7-64 lowercase hex digits or 'unknown', got '" clean(sha) "'"

	e = (kind == "agent") ? agent_checklist(r, c) : skill_checklist(r, c)
	if (e != "") return e
	chk[r] = c
	reviewer[r] = clean(rv)
	target[r] = clean(tgt) " @ " sha unc
	return ""
}

function skill_checklist(r, c) {
	if (c == "CONFORMANCE") { mode[r] = "CONFORMANCE"; return "" }
	if (c !~ /^[0-9][0-9]$/) return "header: the checklist must be two digits or CONFORMANCE for --kind skill, got '" clean(c) "'"
	if (!(c in skill_prec)) return "header: checklist " c " has no ownership rank in this script"
	if (!(c in known_chk)) return "header: checklist " c " has no references/skills/" c "-*.md in the rulebook"
	mode[r] = "CHECKLIST"
	rank[r] = skill_prec[c]
	return ""
}

function agent_checklist(r, c) {
	if (c !~ /^agent-[0-9][0-9]$/) return "header: the checklist must read agent-<nn> for --kind agent, got '" clean(c) "'"
	if (!(c in known_chk)) return "header: checklist " c " has no references/agents/" substr(c, 7) "-*.md in the rulebook"
	mode[r] = "CHECKLIST"
	rank[r] = substr(c, 7) + 0
	return ""
}

function valid_id(id, m) {
	if (m == "CHECKLIST") return id ~ /^[A-Z]+-[0-9]+$/
	if (m == "CONFORMANCE") return id ~ /^(RULE-[0-9]+|STEP-[0-9]+|FIELD-[^ .]+\.[^ ]+)$/
	return id ~ /^[A-Z]+-[0-9]+$/ || id ~ /^(RULE-[0-9]+|STEP-[0-9]+|FIELD-[^ .]+\.[^ ]+)$/
}

# starts_item — whether line l opens an item: an item ID of any report mode,
# then a status keyword. The ID is checked against the report's own mode in
# parse_item, so an item line with a wrong-mode ID is malformed rather than
# read as a continuation and dropped.
function starts_item(l,   sp) {
	sp = index(l, " ")
	return sp > 1 && valid_id(substr(l, 1, sp - 1), "") && substr(l, sp + 1) ~ STATUS_START
}

# parse_item — store one item line of report r; return "" or the reason it
# is not a well-formed item line.
function parse_item(r, l,   sp, id, rest, kw, p, q, e, tight, has_paren, paren, tail, ev, loc, k) {
	sp = index(l, " ")
	id = substr(l, 1, sp - 1)
	rest = substr(l, sp + 1)
	if (!valid_id(id, mode[r]))
		return "bad ID '" clean(id) "'" (mode[r] == "" ? "" : " for a " mode[r] " report") ": '" clean(l) "'"

	match(rest, STATUS_START)
	kw = substr(rest, 1, RLENGTH)
	if (kw == "CHANGED" && mode[r] == "CHECKLIST") return id ": CHANGED is only valid in a CONFORMANCE report"
	if ((kw == "N/A" || kw == "WAIVED") && mode[r] == "CONFORMANCE") return id ": " kw " is not valid in a CONFORMANCE report"

	p = length(kw) + 1
	tight = 0; has_paren = 0; paren = ""; q = 0
	if (substr(rest, p, 1) == "(") { tight = 1; q = p }
	else if (substr(rest, p, 2) == " (") q = p + 1
	if (q) {
		e = close_paren(rest, q)
		if (!e) return id ": unbalanced parenthesis in the status"
		has_paren = 1
		paren = substr(rest, q + 1, e - q - 1)
		p = e + 1
	}
	tail = substr(rest, p)
	ev = ""
	if (tail == "") {
		if (kw == "WAIVED") return id ": WAIVED needs ' — <waivers-file line>'"
		if (kw != "N/A" && kw != "UNDECIDABLE") return id ": " kw " needs ' — <file>:<line> <evidence>'"
	} else if (substr(tail, 1, length(DASH)) != DASH) {
		return id ": expected ' — ' after the status '" clean(substr(rest, 1, p - 1)) "'"
	} else {
		ev = substr(tail, length(DASH) + 1)
		if (ev ~ /^[ \t]*$/) return id ": nothing after ' — '"
	}

	if (tight && kw != "FAIL") return id ": put a space between " kw " and its parenthetical"
	if (has_paren && paren ~ /^[ \t]*$/) return id ": empty parenthetical after " kw
	if (kw == "FAIL" && has_paren && paren !~ /^[a-z0-9]+( *, *[a-z0-9]+)*$/) return id ": FAIL parts must read like FAIL(a,c)"
	if ((kw == "N/A" || kw == "UNDECIDABLE" || kw == "CHANGED") && !has_paren) return id ": " kw " needs a parenthetical, e.g. " kw " (<why>)"
	if (kw == "CHANGED" && paren !~ /^decision/) return id ": CHANGED must read 'CHANGED (decision <ref>)'"

	loc = ev
	sub(/[ \t].*/, "", loc)
	gsub(/`/, "", loc)
	sub(/[,;]+$/, "", loc)
	if (loc !~ /^[^ :]+:[0-9]+(-[0-9]+)?$/) loc = "-"

	k = ++nitems[r]
	if ((r, id) in seen_id) warns[++nwarn] = rname[r] ": item " id " appears more than once"
	seen_id[r, id] = 1
	item_id[r, k] = id
	item_kw[r, k] = kw
	item_paren[r, k] = paren
	item_status[r, k] = clean(substr(rest, 1, p - 1))
	item_loc[r, k] = clean(loc)
	return ""
}

# ---------------------------------------------------------------------------
# Computing the merge
# ---------------------------------------------------------------------------
function severity(r, id) {
	if (mode[r] == "CONFORMANCE") return "MUST"
	if (id in level) return level[id]
	return "UNKNOWN"
}

# waived_as_fail — why item k of report r, a WAIVED line, counts as a FAIL
# at its level; "" when the waiver stands or the line is not WAIVED.
function waived_as_fail(r, k,   id, sev) {
	if (item_kw[r, k] != "WAIVED") return ""
	id = item_id[r, k]
	sev = severity(r, id)
	if (sev == "MUST") return "MUST item"
	if (sev == "UNKNOWN") return "unknown item"
	if (!have_waivers) return "no owner waiver line for " id ": no --waivers file given"
	if (!(id in owner_waived)) return "no owner waiver line for " id " in " waivers_name
	return ""
}

function counts_as_fail(r, k) {
	return item_kw[r, k] == "FAIL" || waived_as_fail(r, k) != ""
}

function blocks(r, k,   sev) {
	sev = severity(r, item_id[r, k])
	if (sev != "MUST" && sev != "UNKNOWN") return 0
	return counts_as_fail(r, k) || (item_kw[r, k] == "UNDECIDABLE" && item_paren[r, k] !~ /^needs shell/)
}

function warn_waived_as_fail(   r, k, why) {
	for (r = 1; r <= nreports; r++)
		for (k = 1; k <= nitems[r]; k++)
			if ((why = waived_as_fail(r, k)) != "")
				warns[++nwarn] = rname[r] ": " item_id[r, k] " WAIVED counted as FAIL (" why ")"
}

# sort_reports — ord[1..nreports]: by checklist (CONFORMANCE last), then
# file name, then position.
function sort_reports(   r, keys, n, i, parts) {
	for (r = 1; r <= nreports; r++)
		keys[r] = (mode[r] == "CONFORMANCE" ? "~" : chk[r]) SUBSEP fname[rfile[r]] SUBSEP sprintf("%06d", r)
	isort(keys, nreports)
	for (i = 1; i <= nreports; i++) {
		n = split(keys[i], parts, SUBSEP)
		ord[i] = parts[n] + 0
	}
}

function check_own_verdicts(   r, k, ids, mine) {
	for (r = 1; r <= nreports; r++) {
		ids = ""
		for (k = 1; k <= nitems[r]; k++) if (blocks(r, k)) ids = ids " " item_id[r, k]
		mine = (ids == "") ? "PASS" : "BLOCKED (" sorted_ids(ids) ")"
		if (mine != claimed[r])
			warns[++nwarn] = rname[r] ": its VERDICT says " claimed[r] ", recomputed " mine
	}
}

function line_rank(r, k) { return item_id[r, k] ~ /^LNT-/ ? 0 : rank[r] }

# line_level — 3 for MUST (an unknown ID counts as MUST), 2 SHOULD, 1 MAY.
function line_level(r, k,   sev) {
	sev = severity(r, item_id[r, k])
	return (sev in LEVEL_RANK) ? LEVEL_RANK[sev] : LEVEL_RANK["MUST"]
}

# dedupe — mark dropped[r,k] for FAIL lines at a file:line shared by two or
# more CHECKLIST reports, keeping the highest-ranked line(s). A line is
# dropped only when the kept line is at least as severe; dropping only tidies
# the listing, since the verdict and blocking: are computed over every line.
function dedupe(   i, r, k, loc, nlocs, locs, members, n, m, parts, rk, rr, kk, j, best, nreps, rep_seen, min, winner, wkey, key, primary, pkey, plevel) {
	nlocs = 0
	for (i = 1; i <= nreports; i++) {
		r = ord[i]
		if (mode[r] != "CHECKLIST") continue
		for (k = 1; k <= nitems[r]; k++) {
			if (item_kw[r, k] != "FAIL" || item_loc[r, k] == "-") continue
			loc = item_loc[r, k]
			if (!(loc in members)) { locs[++nlocs] = loc; members[loc] = "" }
			members[loc] = members[loc] " " r ":" k
		}
	}
	for (j = 1; j <= nlocs; j++) {
		loc = locs[j]
		n = split(substr(members[loc], 2), m, " ")
		nreps = 0
		split("", rep_seen)
		min = 99
		for (i = 1; i <= n; i++) {
			split(m[i], parts, ":"); rr = parts[1] + 0; kk = parts[2] + 0
			if (!(rr in rep_seen)) { rep_seen[rr] = 1; nreps++ }
			rk = line_rank(rr, kk)
			if (rk < min) min = rk
		}
		if (nreps < 2) continue

		# Among min-ranked lines keep one per ID (best report rank, then the
		# earliest in report order); primary is the most severe kept line.
		split("", winner); split("", wkey)
		primary = ""; pkey = ""; plevel = 0
		for (i = 1; i <= n; i++) {
			split(m[i], parts, ":"); rr = parts[1] + 0; kk = parts[2] + 0
			if (line_rank(rr, kk) != min) continue
			key = sprintf("%02d%06d", rank[rr], i)
			if (!(item_id[rr, kk] in winner) || key < wkey[item_id[rr, kk]]) {
				winner[item_id[rr, kk]] = m[i]
				wkey[item_id[rr, kk]] = key
			}
			if (line_level(rr, kk) > plevel || (line_level(rr, kk) == plevel && key < pkey)) {
				primary = m[i]; pkey = key; plevel = line_level(rr, kk)
			}
		}
		for (i = 1; i <= n; i++) {
			split(m[i], parts, ":"); rr = parts[1] + 0; kk = parts[2] + 0
			if (line_rank(rr, kk) == min && winner[item_id[rr, kk]] == m[i]) continue
			best = (line_rank(rr, kk) == min) ? winner[item_id[rr, kk]] : primary
			split(best, parts, ":")
			if (line_level(rr, kk) > line_level(parts[1] + 0, parts[2] + 0)) continue
			dropped[rr, kk] = 1
			drops[++ndrop] = item_id[rr, kk] " (kept " item_id[parts[1] + 0, parts[2] + 0] ") " \
				chk[rr] "->" chk[parts[1] + 0] " " loc
		}
	}
}

# collect — append arr[1..n], sorted, unique and prefixed, to the global
# listed[]; return the new count of listed lines.
function collect(prefix, arr, n, nlisted,   i, prev) {
	isort(arr, n)
	prev = ""
	for (i = 1; i <= n; i++) {
		if (i > 1 && arr[i] == prev) continue
		listed[++nlisted] = prefix arr[i]
		prev = arr[i]
	}
	return nlisted
}

# print_listed — print listed[1..n], at most cap of them when cap > 0, then a
# TRUNCATED line when any were cut.
function print_listed(n, cap,   i, shown) {
	shown = (cap > 0 && n > cap) ? cap : n
	for (i = 1; i <= shown; i++) print listed[i]
	if (shown < n) print "TRUNCATED showing " shown " of " n " lines"
}

function emit(prefix, arr, n) {
	split("", listed)
	print_listed(collect(prefix, arr, n, 0), 0)
}

# print_result — print the merged verdict; return 0 for PASS, 1 for BLOCKED.
function print_result(   i, r, k, sev, label, ids, nblock, block, nshould, should, nunk, unk, c, na) {
	nblock = 0; nshould = 0; nunk = 0; ids = ""
	for (i = 1; i <= nreports; i++) {
		r = ord[i]
		label = chk[r]
		split("", c)
		for (k = 1; k <= nitems[r]; k++) {
			c[item_kw[r, k]]++
			sev = severity(r, item_id[r, k])
			if (sev == "UNKNOWN") unk[++nunk] = item_id[r, k] " " label " " item_loc[r, k] " " item_status[r, k]
			if (blocks(r, k)) {
				block[++nblock] = item_id[r, k] " " label " " item_loc[r, k] " " item_status[r, k]
				ids = ids " " item_id[r, k]
				current_ids[item_id[r, k]] = 1
			} else if (!dropped[r, k] && counts_as_fail(r, k) && (sev == "SHOULD" || sev == "MAY")) {
				should[++nshould] = item_id[r, k] " " sev " " label " " item_loc[r, k] " " item_status[r, k]
				current_ids[item_id[r, k]] = 1
			}
		}
		na = allna_report[r] ? "all" : c["N/A"] + 0
		rows[i] = label " reviewer=" reviewer[r] " pass=" c["PASS"] + 0 " fail=" c["FAIL"] + 0 \
			" n/a=" na " waived=" c["WAIVED"] + 0 " undecidable=" c["UNDECIDABLE"] + 0 \
			" changed=" c["CHANGED"] + 0 " file=" fname[rfile[r]] " target=" target[r]
	}

	print (ids == "") ? "VERDICT: PASS" : "VERDICT: BLOCKED (" sorted_ids(ids) ")"
	for (i = 1; i <= nreports; i++) print "report: " rows[i]
	emit("blocking: ", block, nblock)
	emit("should-fail: ", should, nshould)
	emit("unknown-id: ", unk, nunk)
	split("", listed)
	print_listed(collect("warning: ", warns, nwarn, collect("dropped-duplicate: ", drops, ndrop, 0)), max_lines + 0)
	return (ids == "") ? 0 : 1
}

# print_progress — compare this merge's blocking:/should-fail: IDs with the
# --previous file's.
function print_progress(   id, fixed, still_open, new_ids) {
	fixed = 0; still_open = 0; new_ids = 0
	for (id in previous_ids) if (id in current_ids) still_open++; else fixed++
	for (id in current_ids) if (!(id in previous_ids)) new_ids++
	print "progress: fixed " fixed " · still open " still_open " · new " new_ids
	if (fixed == 0 && new_ids == 0) print "unchanged: yes"
}
AWK

REF_ARGS=(phase=skillrefs "${SKILL_CHECKLISTS[@]}")
if [[ "${OPT_KIND}" == agent ]]; then
	REF_ARGS+=(phase=agentrefs "${AGENT_CHECKLISTS[@]}")
fi
REF_ARGS+=(phase=lintrefs "${LINT_SPEC}")

# The waivers path reaches awk through the environment: -v would rewrite any
# backslash in it.
awk_status=0
MV_WAIVERS_NAME=${OPT_WAIVERS} MV_RULEBOOK_HINT=${RULEBOOK_HINT} \
awk -v prog="${PROG}" -v kind="${OPT_KIND}" -v nfiles="${#COPIES[@]}" \
	-v code_base="${AWK_CODE_BASE}" -v max_lines="${OPT_MAX_LINES}" \
	-v have_waivers="${HAVE_WAIVERS}" -v have_previous="${HAVE_PREVIOUS}" \
	-f "${AWK_PROGRAM}" \
	phase=names "${NAMES_FILE}" \
	"${REF_ARGS[@]}" \
	${OPTIONAL_ARGS[@]+"${OPTIONAL_ARGS[@]}"} \
	phase=files "${COPIES[@]}" || awk_status=$?

case "${awk_status}" in
	"$((AWK_CODE_BASE + 0))") exit 0 ;;
	"$((AWK_CODE_BASE + 1))") exit 1 ;;
	"$((AWK_CODE_BASE + 3))") exit 3 ;;
	"$((AWK_CODE_BASE + 4))") exit 4 ;;
	*)
		error "internal error: awk exited ${awk_status} while merging; expected one of its result codes ${AWK_CODE_BASE}, $((AWK_CODE_BASE + 1)), $((AWK_CODE_BASE + 3)) or $((AWK_CODE_BASE + 4)). Try: read awk's message above; re-run with another awk (gawk or mawk) on PATH to rule out an awk bug."
		exit 5
		;;
esac
