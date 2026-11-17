#!/usr/bin/env bash
# The jq and awk programs are single-quoted on purpose: their $ signs are theirs.
# shellcheck disable=SC2016
set -Eeuo pipefail
#
# Two steps for a flow-harness-authoring gate (G1-G4) or its Closing report.
# The generator reads the run files and writes the gate's plan JSON; the
# renderer reads only that JSON and prints the view through human-view's
# view.jq and paths.jq, for procedure-approval-gate's open-gate.sh.
#
# Every input is untrusted text written by agents: it is never evaluated,
# values reach awk only through ENVIRON or stdin (awk -v would expand
# backslash escapes) and jq only through --arg, and text copied into the plan
# loses every control character, C1 controls included (read_clean, then
# clean_strings). The renderer refuses a plan string holding one.
#
# Helpers that can stop the run (exit 3) set a global instead of printing, so
# they run in this shell rather than in a command substitution, whose exit
# would only leave the subshell.

LC_ALL=C
export LC_ALL
unset CDPATH

PROG=${0##*/}
CONFIG_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}
readonly HUMAN_VIEW_DIR="${CONFIG_DIR}/skills/human-view"

# Swarm sizing, as the flow's SKILL.md (Reviewer swarm) sets it.
readonly SMALL_SEAT_MAX_ITEMS=30
readonly SMALL_SWARM_MAX_LINES=300
readonly AGENT_FEW_SEATS_BELOW_LINES=150
readonly AGENT_FEW_SEATS='agent-01+03 agent-02 agent-04 agent-05 agent-06+07+08'

# Author-report section names: skill-author's §0-§8 and agent-author's 0-7.
readonly REPORT_SECTIONS="Status|Files written|File written|Source trace|Script specs|Field table|Open points|Checklist self-check|Findings|Eval set"
readonly SHORT_LINE_MAX=140
readonly MAX_TARGETS=4

error() { printf '%s: error: %s\n' "${PROG}" "$*" >&2; }
warning() { printf '%s: warning: %s\n' "${PROG}" "$*" >&2; }

# shellcheck disable=SC2329  # invoked indirectly via the ERR trap
internal_error() {
	printf '%s: internal error at line %s: %s\n' "${PROG}" "$1" "$2" >&2
	printf '%s: expected that command to succeed; nothing was written or printed. Try: re-run with the same arguments; if it repeats, report the command above.\n' "${PROG}" >&2
	exit 5
}
trap 'internal_error "${LINENO}" "${BASH_COMMAND}"' ERR
trap 'error "interrupted"; exit 130' INT
trap 'error "terminated"; exit 143' TERM

USAGE_TEXT='usage: PROG --gate g1|g2|g3|g4|closing --run-dir DIR --kind skill|agent
         --target PATH [gate options] --plan-out PATH [--append]
       PROG --plan-file PATH [--paths]
       PROG -h|--help

Writes a flow-harness-authoring gate'"'"'s plan JSON from the run files, or
prints its view from that JSON. Pipe the view into procedure-approval-gate'"'"'s
open-gate.sh --label harness-g1|harness-g2|harness-g3|harness-g4|
harness-closing (crucible.sh item labels).
Views: g1 open questions; with --verify its counts, missing cards and WRONG
LINE, UNSUPPORTED or UNDECIDABLE lines. g2 target with its line, script and
contract counts; swarm options, recommended first; each eval prompt and
field-table row (cut at 140 chars); Left unset; open-point count. g3 a
blocking count; blocking items (ID, seat, file:line, Fix cut at its first
sentence or 140 chars; none without "## Non-PASS item lines" in --merged,
warned on stderr); should-fail items; invalid waivers; merge warning:
lines in full; lint and help-check FAIL lines; failed or both-pass eval
outcomes; merge progress; other counts. g4 checks, source, link, what the
link holds now. closing verdict; fixed, waived, open IDs; target files;
evals; Ended and Live validation from state.md "- Ended:"/"- Live:" ("see
state.md" when only a free-form line names them); not run; still needing
the human: the deploy, live validation (each until "done"), open items.
Notices, under the first line: each state.md line after its last
"- Gate shown: <gate>" line shaped "- Notice: <text>" or "- Not run: <seat>
<why>" (closing lists Not run in full instead). Appended views share one
first line ("<n> targets") and one Notices section; each target sits under
a "Target:" line. A zero count is left out; paths in text are shortened.

Generator (every path absolute, no "~"):
  --gate GATE, --run-dir DIR (exists), --kind KIND, --target PATH
  --source FILE      g1, required: an Open questions section, a "## ..."
                       heading or an "<n>. **Open questions.**" item
  --verify FILE      g1: the VERIFY check
  --report FILE      g2, required: the author report
  --checklists IDS   g2, required for a skill: 01,02,07
  --rulebook DIR     g2; default ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/
                       standard-harness-authoring
  --merged FILE, --lint FILE   g3, g4, required
  --help-check FILE  g3, g4
  --link PATH        g4, required
  --waivers FILE     closing
  --plan-out PATH    required: the plan file, as open-gate.sh --plan-path
                       prints; replaced whole, its folder must exist
  --append           add this view to the plan at --plan-out (same gate),
                       at most '"${MAX_TARGETS}"' targets per gate (more: exit 2)
  Every gate reads state.md in --run-dir when it exists; g3 also review/,
  runs/*-grade.md and each eval'"'"'s runs/<id>-new.md and -base.md; closing
  review-r<n>.md, runs/*-grade.md, state.md (required), target-files.txt.
  stdout: PLAN_FILE: <path>. Writes only --plan-out.
Renderer:
  --plan-file PATH   the plan JSON, checked by one jq validator
  --paths            print the status line and every file read, numbered
  stdout: the view, without the gate marker. Writes no file.

Exit codes:
  0  done; pipe the view into open-gate.sh
  2  usage error; show the human stderr, and stop
  3  input missing, unreadable or malformed (a bad plan names its field);
     show the human stderr, and stop
  5  internal error or missing dependency; show the human stderr, and stop
  130, 143  interrupted, terminated; show the human stderr, and stop

Dependencies: bash 3.2+; awk, cat, find, mktemp, mv, readlink, rm, sort,
tr, wc; jq 1.6+ (macOS: brew install jq; Linux: the distro'"'"'s jq); the
human-view skill (view.jq, paths.jq) in ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/
skills; procedure-approval-gate'"'"'s open-gate.sh and the crucible skill to
open the gate.'

usage() { printf '%s\n' "${USAGE_TEXT//PROG/${PROG}}"; }

usage_error() {
	error "$*"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

input_error() {
	error "$*"
	exit 3
}

missing_dependency() {
	error "$*"
	exit 5
}

# ---------------------------------------------------------------------------
# The plan JSON's one validator. Input: the plan file slurped (jq -s).
# Output: one "<field>: <problem>" line per problem; nothing for a good plan.
# ---------------------------------------------------------------------------
readonly VALIDATOR_JQ='
def is_text: type == "string" and (test("[[:cntrl:]]") | not);
def is_path: is_text and startswith("/");
def maybe_text: . == null or is_text;
def is_count: type == "number" and . >= 0 and . == floor;
def is_texts: type == "array" and all(.[]; is_text);
def need($at; ok; $want): if ok then empty else "\($at) is missing or not \($want)" end;
def texts($key): need(".\($key)"; .[$key] | is_texts; "an array of strings without control characters");
def count($key): need(".\($key)"; .[$key] | is_count; "a whole number, 0 or more");
def flag($key): need(".\($key)"; .[$key] | type == "boolean"; "a boolean");
def each($key; check):
	if (.[$key] | type) != "array" then ".\($key) is missing or not an array"
	else .[$key] | to_entries[] | .key as $i | .value
		| (if type == "object" then check else " is not an object" end) | ".\($key)[\($i)]" + .
	end;
def common:
	need(".target"; .target | is_path; "an absolute path"),
	need(".files_read"; .files_read | type == "array" and all(.[]; is_path); "an array of absolute paths"),
	texts("notices");
def g1: texts("open_questions"), texts("verify");
def g2:
	count("target_lines"), count("scripts"), count("contracts"),
	each("swarm"; need(".size"; .size | . == null or . == "Large" or . == "Small"; "null, \"Large\" or \"Small\""),
		flag("recommended"), need(".why"; .why | maybe_text; "null or a string without control characters"), texts("seats"), flag("conformance")),
	texts("evals"), texts("field_rows"), need(".left_unset"; .left_unset | maybe_text; "null or a string without control characters"),
	count("open_points"), texts("unparsed");
def g3:
	need(".verdict"; .verdict | is_text; "a string without control characters"),
	each("blocking"; need(".id"; .id | is_text; "a string without control characters"),
		(.seat, .location, .fix | select(maybe_text | not) | " has a seat, location or fix that is not null or a string")),
	each("should_fix"; need(".id"; .id | is_text; "a string without control characters"), need(".location"; .location | maybe_text; "null or a string without control characters")),
	texts("invalid_waivers"), texts("warnings"), texts("eval_outcomes"),
	each("check_fails"; need(".name"; .name | is_text; "a string without control characters"), texts("lines")),
	need(".fields"; .fields | type == "array" and all(.[]; type == "array" and length == 2 and (.[0] | is_text) and (.[1] | is_text or is_count));
		"an array of [label, string or count] pairs");
def g4:
	texts("checks"), need(".source"; .source | is_path; "an absolute path"), need(".link"; .link | is_path; "an absolute path"),
	need(".link_now"; .link_now | type == "object" and (.kind | IN("source", "symlink", "other", "absent")) and (.points_to | maybe_text);
		"an object {\"kind\": \"source\"|\"symlink\"|\"other\"|\"absent\", \"points_to\": null or str}");
def state_value($key): need(".\($key)"; .[$key] | type == "object" and (.value | maybe_text) and (.free_form | type == "boolean");
	"an object {\"value\": null or str, \"free_form\": bool}");
def closing:
	need(".verdict"; .verdict | maybe_text; "null or a string without control characters"),
	texts("fixed"), texts("waived"), texts("open"), texts("not_run"),
	need(".target_files"; .target_files | . == null or is_count; "null or a whole number"),
	need(".evals"; .evals | type == "object" and (.runs | is_count) and (.outcomes | is_count) and (.failed | is_count);
		"an object {\"runs\", \"outcomes\", \"failed\"} of whole numbers"),
	state_value("ended"), state_value("live"), flag("deploy_done");
def view($gate):
	common,
	(if $gate == "g1" then g1 elif $gate == "g2" then g2 elif $gate == "g3" then g3
	 elif $gate == "g4" then g4 else closing end);
if length != 1 then "the file holds \(length) JSON values, not one object"
elif (.[0] | type) != "object" then "the plan is a JSON \(.[0] | type), not an object"
else .[0]
	| (.gate | if IN("g1", "g2", "g3", "g4", "closing") then empty else "gate is missing or not one of g1, g2, g3, g4, closing" end),
	  (if (.views | type) != "array" or (.views | length) == 0 then "views is missing or not a non-empty array"
	   elif (.gate | IN("g1", "g2", "g3", "g4", "closing") | not) then empty
	   else .gate as $gate | .views | to_entries[] | .key as $i | .value
		| (if type == "object" then view($gate) else " is not an object" end) | "views[\($i)]" + .
	   end)
end
'

# ---------------------------------------------------------------------------
# The renderer's view program; human-view's modules give the layout.
# ---------------------------------------------------------------------------
readonly RENDER_JQ='
include "view";
include "paths";
# Each absolute path inside a line of text (a word opening with "/" and holding
# two or more parts), shortened for recognition.
def shown: gsub("(?<![A-Za-z0-9._~$/-])(?<path>/[^ \t/]+/[^ \t]*)"; .path | short_path($home));
def items: map(shown | plain_line);
def kept_once: reduce .[] as $item ([]; if any(.[]; . == $item) then . else . + [$item] end);
def counted($one; $many): if . == 1 then "1 \($one)" else "\(.) \($many)" end;
def needs:
	(if .deploy_done then [] else ["The deploy"] end)
	+ (if (.live.value // "") | startswith("done") then [] else ["Live validation"] end)
	+ (.open | length | if . == 0 then [] else [counted("open item"; "open items")] end);
def title($gate):
	{g1: "G1 Approve the source", g2: "G2 Approve the evals, the field table and the swarm size",
	 g3: "G3 Choose what to fix", g4: "G4 Deploy", closing: "Closing report"}[$gate];
# Light and tail of one view: only Closing can be blocked or done; G1-G4 ask.
def light($gate):
	if $gate != "closing" then "decision"
	elif (.verdict // "") | startswith("BLOCKED") then "blocked"
	elif (needs | length) > 0 then "attention"
	else "done" end;
def tail($gate):
	if $gate == "g3" then .blocking | length | if . == 0 then "" else "\(.) blocking" end
	elif $gate == "closing" then needs | length | if . == 0 then "" else "\(.) need you" end
	else "" end;
def strongest:
	if any(. == "blocked") then "blocked" elif any(. == "decision") then "decision"
	elif any(. == "attention") then "attention" else "done" end;
def first_line:
	.gate as $gate
	| if (.views | length) == 1 then .views[0] | status_line(light($gate); title($gate); tail($gate))
	  else status_line(.views | map(light($gate)) | strongest; title($gate); "\(.views | length) targets") end;
def notices: section("Notice"; "Notices"; [.views[].notices[]] | kept_once | map(plain_line));
def seat_summary:
	(.seats | length) as $count
	| "\($count) seat\(if $count == 1 then "" else "s" end)\(if .conformance then " + CONFORMANCE" else "" end): \(.seats | join(" · "))";
def swarm_line:
	if .size == null then seat_summary + (if .why == null then "" else " (\(.why))" end)
	else .size + (if .recommended then " (recommended: \(.why))" else "" end) + " — " + seat_summary end;
def present: map(select(. != null and . != ""));
def state_text: .value // (if .free_form then "see state.md" else "not recorded" end);
def evals_text:
	if .runs == 0 then "none run"
	else ["\(.runs) run", (if .outcomes > 0 then "\(.outcomes) outcomes" else null end),
		(if .failed > 0 then "\(.failed) NEW not PASS" else null end)] | present | join(" · ") end;
def link_now_text:
	if .kind == "source" then "symlink to the source"
	elif .kind == "symlink" then "symlink to " + (.points_to | path_text)
	elif .kind == "other" then "exists, not a symlink"
	else "does not exist" end;
# value($name; $text): a one-item "**Name:** text" section.
def value($name; $text): section($name; [$text]);
def body($gate):
	if $gate == "g1" then
		[section("Open questions"; .open_questions | items), section("Verify"; .verify | items)]
	elif $gate == "g2" then
		[value("Target"; [(.target | path_text), "\(.target_lines) lines",
			(if .scripts > 0 then "\(.scripts) scripts" else null end),
			(if .contracts > 0 then "\(.contracts) contracts" else null end)] | present | join(" · ")),
		 section("Swarm"; .swarm | map(swarm_line) | items),
		 section("Eval set"; .evals | items), section("Field table"; .field_rows | items),
		 (if .left_unset == null then "" else value("Left unset"; .left_unset | shown | plain_line) end),
		 field_lines([["Open points", .open_points]])]
		+ [.unparsed[] | value(.; "see the author report")]
	elif $gate == "g3" then
		[section("Blocking"; .blocking | map([.id, .seat, .location, .fix] | present | join(" · ")) | items),
		 section("Should fix"; .should_fix | map([.id, .location] | present | join(" · ")) | items),
		 section("Invalid waivers"; .invalid_waivers | items),
		 section("Warning"; "Warnings"; .warnings | map(plain_line))]
		+ [.check_fails[] | section("\(.name) FAIL"; .lines | items)]
		+ [section("Eval outcomes"; .eval_outcomes | items)]
		+ [.fields[] | select(.[1] | type == "string" and . != "") | section(.[0]; [.[1]] | items)]
		+ [field_lines(.fields | map(select(.[1] | type == "number")))]
	elif $gate == "g4" then
		[section("Checks"; .checks | items), value("Source"; .source | path_text),
		 value("Link"; .link | path_text), value("Link now"; .link_now | link_now_text)]
	else
		[section("Verdict"; [.verdict // "not recorded"] | items),
		 section("Fixed"; .fixed | items), section("Waived"; .waived | items), section("Open"; .open | items),
		 (if .target_files == null then value("Target files"; "not recorded")
		  else field_lines([["Target files", .target_files]]) end),
		 value("Evals"; .evals | evals_text),
		 section("Ended"; [.ended | state_text] | items), section("Live validation"; [.live | state_text] | items),
		 section("Not run"; .not_run | items),
		 section("Still needs the human"; needs)]
	end;
# A G2 body opens with its own Target line.
def target_blocks($gate; $several):
	(if $several and $gate != "g2" then [value("Target"; .target | path_text)] else [] end) + body($gate);
if $paths then [first_line, section("Files"; [.views[].files_read[]] | kept_once | map(path_text))]
else .gate as $gate | ((.views | length) > 1) as $several
	| [first_line, notices] + [.views[] | target_blocks($gate; $several)[]] end
| blocks
'

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_GATE="" OPT_RUN_DIR="" OPT_KIND="" OPT_TARGET="" OPT_SOURCE="" OPT_VERIFY=""
OPT_REPORT="" OPT_CHECKLISTS="" OPT_RULEBOOK="" OPT_MERGED="" OPT_LINT=""
OPT_HELP_CHECK="" OPT_LINK="" OPT_WAIVERS="" OPT_PLAN_OUT="" OPT_PLAN_FILE=""
OPT_APPEND=0 OPT_PATHS=0
GIVEN=" "

[[ $# -gt 0 ]] || usage_error "no arguments; expected --plan-file PATH, or --gate, --run-dir, --kind, --target and --plan-out"

# take_value OPTION VALUE — reject a repeat or a missing value; the caller
# stores VALUE.
take_value() {
	[[ "${GIVEN}" != *" $1 "* ]] || usage_error "option $1 given twice; expected it once"
	[[ -n "${2:-}" && "$2" != --* ]] || usage_error "option $1 requires a value"
	GIVEN="${GIVEN}$1 "
}

# take_flag OPTION — reject a repeat.
take_flag() {
	[[ "${GIVEN}" != *" $1 "* ]] || usage_error "option $1 given twice; expected it once"
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
		--plan-out)   take_value "$1" "${2:-}"; OPT_PLAN_OUT=$2; shift ;;
		--plan-file)  take_value "$1" "${2:-}"; OPT_PLAN_FILE=$2; shift ;;
		--append)     take_flag "$1"; OPT_APPEND=1 ;;
		--paths)      take_flag "$1"; OPT_PATHS=1 ;;
		*) usage_error "unknown argument: $1; expected one of the options in --help" ;;
	esac
	shift
done

for tool in awk cat find jq mktemp mv readlink rm sort tr wc; do
	if ! command -v "${tool}" >/dev/null 2>&1; then
		missing_dependency "required tool missing: ${tool}; expected it on PATH; try installing it (jq: brew install jq on macOS, the distro's jq package on Linux) or fixing PATH"
	fi
done

# check_path OPTION VALUE — usage error unless VALUE is absolute, has no
# "~" and no control character.
check_path() {
	[[ -n "$2" ]] || return 0
	[[ "$2" == /* ]] || usage_error "$1 must be an absolute path, got: $2"
	[[ "$2" != *"~"* ]] || usage_error "$1 must not contain \"~\"; give the whole absolute path, got: $2"
	[[ "$2" != *[[:cntrl:]]* ]] || usage_error "$1 path contains a control character; expected a plain absolute path"
}

# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

# plan_problems FILE — sets PROBLEMS to the validator's lines for FILE; exit 3
# when FILE is missing, unreadable or not JSON.
plan_problems() {
	[[ -f "$1" && -r "$1" ]] || input_error "plan file does not exist or is not readable: $1; expected the file render-gate.sh --plan-out wrote; check the path"
	PROBLEMS=$(jq -rs "${VALIDATOR_JQ}" "$1" 2>/dev/null || exit 1) ||
		input_error "plan file is not valid JSON: $1; expected the plan render-gate.sh --plan-out writes; run the generator again"
}

render_plan() {
	local opt module view line paths=false
	for opt in --gate --run-dir --kind --target --source --verify --report --checklists --rulebook --merged --lint --help-check --link --waivers --plan-out --append; do
		[[ "${GIVEN}" != *" ${opt} "* ]] || usage_error "${opt} is a generator option; expected only --plan-file PATH [--paths]"
	done
	check_path --plan-file "${OPT_PLAN_FILE}"
	for module in view paths; do
		[[ -f "${HUMAN_VIEW_DIR}/${module}.jq" && -r "${HUMAN_VIEW_DIR}/${module}.jq" ]] ||
			missing_dependency "human-view module missing: ${HUMAN_VIEW_DIR}/${module}.jq; expected the human-view skill in \${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/skills; install it"
	done
	plan_problems "${OPT_PLAN_FILE}"
	if [[ -n "${PROBLEMS}" ]]; then
		while IFS= read -r line; do
			error "${OPT_PLAN_FILE}: ${line}; expected the plan render-gate.sh --plan-out writes"
		done <<<"${PROBLEMS}"
		exit 3
	fi
	if [[ "${OPT_PATHS}" -eq 1 ]]; then paths=true; fi
	view=$(jq -r -L "${HUMAN_VIEW_DIR}" --arg home "${HOME:-}" --argjson paths "${paths}" "${RENDER_JQ}" "${OPT_PLAN_FILE}")
	printf '%s\n' "${view}"
}

if [[ -n "${OPT_PLAN_FILE}" ]]; then
	render_plan
	exit 0
fi

# ---------------------------------------------------------------------------
# Generator: arguments
# ---------------------------------------------------------------------------

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

check_choice() {
	[[ -n "$2" ]] || usage_error "$1 is required ($3)"
	[[ " $3 " == *" $2 "* ]] || usage_error "$1 must be one of: $3; got: $2"
}

validate_args() {
	local opt
	[[ "${OPT_PATHS}" -eq 0 ]] || usage_error "--paths is a renderer option; expected --plan-file PATH --paths"
	check_choice --gate "${OPT_GATE}" "g1 g2 g3 g4 closing"
	[[ -n "${OPT_RUN_DIR}" ]] || usage_error "--run-dir is required"
	check_choice --kind "${OPT_KIND}" "skill agent"
	[[ -n "${OPT_TARGET}" ]] || usage_error "--target is required"
	[[ -n "${OPT_PLAN_OUT}" ]] || usage_error "--plan-out is required; expected the plan file open-gate.sh --plan-path prints"

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
	check_path --plan-out "${OPT_PLAN_OUT}"
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
[[ -d "${OPT_PLAN_OUT%/*}/" ]] || input_error "--plan-out folder does not exist: ${OPT_PLAN_OUT%/*}; expected the folder open-gate.sh --plan-path made; run it first"
[[ ! -L "${OPT_PLAN_OUT}" ]] || input_error "--plan-out is a symbolic link: ${OPT_PLAN_OUT}; expected a plain file or none; remove the link, then rerun"

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

# read_clean FILE — FILE's text with every control character but newline
# removed, C1 controls (UTF-8 C2 80-9F) included, and each tab a space. Its
# readers read to the end: one that exits early would fail the pipeline
# (SIGPIPE, pipefail).
read_clean() {
	tr -d '\000-\010\013-\037\177' <"$1" | tr '\011' ' ' | awk '{ gsub(/\302[\200-\237]/, ""); print }'
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

# list_items TEXT — TEXT's non-empty lines, each without its indent and its
# own leading list marker ("- ", "* ", "+ ", "1. ", "1) "), so no marker
# prints beside a heading or after a number.
list_items() {
	printf '%s\n' "$1" | awk '{
		sub(/^[ \t]+/, "")
		sub(/^[-*+] /, "")
		if (match($0, /^[0-9]+[.)][ \t]+/)) $0 = substr($0, RLENGTH + 1)
		if ($0 != "") print
	}'
}

# CUT_AWK — awk function cut(s, max): s cut to max characters (UTF-8
# counted), "…" ending a cut line.
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
# Plan building
# ---------------------------------------------------------------------------

# Definitions every view program starts with: lines splits a newline-joined
# list, records a list of tab-joined fields; clean_strings turns any control
# character left in a string into a space.
readonly VIEW_COMMON_JQ='
def lines: split("\n") | map(select(. != ""));
def records: lines | map(split("\t"));
def or_null: if . == "" then null else . end;
def clean_strings: walk(if type == "string" then gsub("[[:cntrl:]]"; " ") else . end);
def common: {target: $target,
	files_read: ($files | lines | reduce .[] as $file ([]; if any(.[]; . == $file) then . else . + [$file] end)),
	notices: ($notices | lines)};
'

# build_view PROGRAM [JQ ARGS...] — sets VIEW to the view object PROGRAM
# builds, merged over the target, the files read and NOTICES.
build_view() {
	local program=$1 files
	shift
	files=$(printf '%s\n' "${READ_FILES[@]+"${READ_FILES[@]}"}")
	VIEW=$(jq -nc --arg target "${OPT_TARGET}" --arg files "${files}" --arg notices "${NOTICES}" "$@" \
		"${VIEW_COMMON_JQ} common + (${program}) | clean_strings")
}

# write_plan — writes the plan holding VIEW to --plan-out, or with --append
# adds VIEW to the plan there; the result passes the validator first.
write_plan() {
	local plan temp
	if [[ "${OPT_APPEND}" -eq 1 ]]; then
		plan_problems "${OPT_PLAN_OUT}"
		[[ -z "${PROBLEMS}" ]] || input_error "--append: the plan at ${OPT_PLAN_OUT} is malformed (${PROBLEMS%%$'\n'*}); expected a plan this script wrote; rerun without --append"
		plan=$(jq -c --arg gate "${OPT_GATE}" --argjson view "${VIEW}" \
			'if .gate == $gate then .views += [$view] else error("gate") end' "${OPT_PLAN_OUT}" 2>/dev/null || exit 1) ||
			input_error "--append: the plan at ${OPT_PLAN_OUT} is for another gate; expected --gate as when it was written; rerun without --append"
		check_target_limit
	else
		plan=$(jq -nc --arg gate "${OPT_GATE}" --argjson view "${VIEW}" '{gate: $gate, views: [$view]}')
	fi
	PROBLEMS=$(printf '%s\n' "${plan}" | jq -rs "${VALIDATOR_JQ}")
	if [[ -n "${PROBLEMS}" ]]; then
		error "built plan fails its own check: ${PROBLEMS%%$'\n'*}"
		exit 5
	fi
	temp=$(mktemp "${OPT_PLAN_OUT%/*}/.plan.XXXXXX")
	PLAN_TEMP=${temp}
	printf '%s\n' "${plan}" >"${temp}"
	mv -f "${temp}" "${OPT_PLAN_OUT}"
	PLAN_TEMP=""
	printf 'PLAN_FILE: %s\n' "${OPT_PLAN_OUT}"
}

# check_target_limit — usage error when the plan at --plan-out already holds
# MAX_TARGETS views.
check_target_limit() {
	local held
	held=$(jq -r '.views | length' "${OPT_PLAN_OUT}")
	if (( held >= MAX_TARGETS )); then
		usage_error "--append: the plan at ${OPT_PLAN_OUT} already holds ${held} targets, the limit is ${MAX_TARGETS} targets per gate; open this gate for these ${held} targets, then write a new plan for the rest"
	fi
}

# shellcheck disable=SC2329  # invoked by the EXIT trap
remove_plan_temp() {
	if [[ -n "${PLAN_TEMP}" ]]; then rm -f "${PLAN_TEMP}"; fi
}
PLAN_TEMP=""
trap remove_plan_temp EXIT

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

# set_notices — NOTICES: the notice lines in <run-dir>/state.md after its
# last "- Gate shown:" line, one per line: "- Notice: <text>" as <text>, and,
# except at Closing (whose Not run section lists every one), "- Not run:
# <seat> <why>" as "Not run: <seat> <why>". "" when there is no state.md.
set_notices() {
	local state="${OPT_RUN_DIR}/state.md"
	NOTICES=""
	[[ -e "${state}" ]] || return 0
	need_file "state.md" "${state}"
	NOTICES=$(read_clean "${state}" | GATE=${OPT_GATE} awk '
		/^- Gate shown:/ { n = 0; next }
		/^- Notice:/ { s = $0; sub(/^- Notice:[ \t]*/, "", s); if (s != "") item[++n] = s; next }
		/^- Not run:/ && ENVIRON["GATE"] != "closing" { s = $0; sub(/^- /, "", s); item[++n] = s }
		END { for (i = 1; i <= n; i++) print item[i] }')
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
gen_g1() {
	local section checks="" questions verify
	need_file "--source file" "${OPT_SOURCE}"
	# The section opens at a "## " heading or a numbered bold item
	# ("8. **Open questions.**", text after the bold being its first line)
	# naming open questions. A heading section runs to the next "## "
	# heading; an item section to the next item of that shape (bold text
	# ending in "."), a line opening in bold, or a heading. Either ends at an
	# end line. The first output line says whether the section exists.
	section=$(read_clean "${OPT_SOURCE}" | awk '
		function is_item(s) { return s ~ /^[0-9]+\. \*\*[^*]+\.\*\*/ }
		done { next }
		in_section && (/^## / || index($0, "=== END OF ") == 1 || (shape == "item" && (is_item($0) || /^\*\*/))) { done = 1; next }
		in_section { if (NF) body[++n] = $0; next }
		/^## / && tolower($0) ~ /open questions/ { in_section = found = 1; shape = "heading"; next }
		tolower($0) ~ /^[0-9]+\. \*\*[^*]*open questions[^*]*\*\*/ {
			in_section = found = 1; shape = "item"
			rest = $0; sub(/^[0-9]+\. \*\*[^*]+\*\*[ \t]*/, "", rest)
			if (rest != "") body[++n] = rest
		}
		END { print (found ? "found" : "missing"); for (i = 1; i <= n; i++) print body[i] }')
	[[ "${section%%$'\n'*}" == found ]] || input_error "no Open questions section in ${OPT_SOURCE}; expected a \"## \" heading or an \"<n>. **Open questions.**\" item matching /open questions/i; send the source back to its writer"
	section=${section#found}
	section=${section#$'\n'}

	if [[ -n "${OPT_VERIFY}" ]]; then
		need_file "--verify file" "${OPT_VERIFY}"
		require_line "Counts:" "${OPT_VERIFY}" "the analyst's VERIFY check"
		require_line "Missing cards:" "${OPT_VERIFY}" "the analyst's VERIFY check"
		checks=$(read_clean "${OPT_VERIFY}" | awk '
			/^Counts:/ && counts == "" { counts = $0; next }
			/^Missing cards:/ && missing == "" { missing = $0; next }
			{ n = split($0, f, " · "); if (n >= 2 && (f[2] == "WRONG LINE" || f[2] == "UNSUPPORTED" || f[2] == "UNDECIDABLE")) items[++k] = $0 }
			END { print counts; print missing; for (i = 1; i <= k; i++) print items[i] }')
	fi
	questions=$(list_items "${section:-none}")
	verify=$(list_items "${checks}")
	build_view '{open_questions: ($questions | lines), verify: ($verify | lines)}' \
		--arg questions "${questions}" --arg verify "${verify}"
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

# small_seats IDS COUNTS SCRIPTS — Small swarm seats, space-separated: ids in
# number order grouped up to SMALL_SEAT_MAX_ITEMS items, 09 and 12 each
# alone, 07 alone too when the target has scripts (SCRIPTS > 0), then
# CONFORMANCE.
small_seats() {
	IDS=$1 COUNTS=$2 SCRIPTS=$3 MAX=${SMALL_SEAT_MAX_ITEMS} awk 'BEGIN {
		n = split(ENVIRON["IDS"], id, " "); split(ENVIRON["COUNTS"], cnt, " "); max = ENVIRON["MAX"] + 0
		scripts = ENVIRON["SCRIPTS"] + 0
		for (i = 1; i <= n; i++) {
			alone = (id[i] == "09" || id[i] == "12" || (id[i] == "07" && scripts > 0))
			if (group != "" && (alone || total + cnt[i] > max)) { out = out group " "; group = ""; total = 0 }
			if (alone) { out = out id[i] " "; continue }
			group = (group == "" ? id[i] : group "+" id[i]); total += cnt[i]
		}
		if (group != "") out = out group " "
		print out "CONFORMANCE"
	}'
}

# count_lines TEXT — the number of non-blank lines in TEXT.
count_lines() {
	printf '%s\n' "$1" | awk 'NF { n++ } END { print n + 0 }'
}

# swarm_option SIZE RECOMMENDED WHY SEATS — one swarm option record: SIZE
# Large, Small or "", RECOMMENDED 1 or 0, WHY its reason or "", SEATS
# space-separated with CONFORMANCE among them when it sits.
swarm_option() {
	SWARM="${SWARM}$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\n'
}

gen_swarm_skill() {
	local files file sorted_ids id count ids="" counts="" large="" small reason=""
	local -a file_list=()
	[[ -d "${OPT_TARGET}" ]] || input_error "--target is not a directory: ${OPT_TARGET}; expected the target skill dir for --kind skill"
	files=$(target_files)
	while IFS= read -r file; do
		if [[ -n "${file}" ]]; then file_list+=("${file}"); READ_FILES+=("${file}"); fi
	done < <(printf '%s\n' "${files}")
	[[ ${#file_list[@]} -gt 0 ]] || input_error "the target dir holds no file: ${OPT_TARGET}; expected a skill dir"
	set_line_total "${file_list[@]}"
	SCRIPT_COUNT=$(printf '%s\n' "${files}" | TARGET="${OPT_TARGET}" awk 'index($0, ENVIRON["TARGET"] "/scripts/") == 1 { n++ } END { print n + 0 }')
	CONTRACT_COUNT=$(printf '%s\n' "${files}" | TARGET="${OPT_TARGET}" awk '/\.json$/ && index($0, ENVIRON["TARGET"] "/evals/") != 1 { n++ } END { print n + 0 }')

	sorted_ids=$(printf '%s\n' "${OPT_CHECKLISTS//,/$'\n'}" | sort -u)
	while IFS= read -r id; do
		[[ -n "${id}" ]] || continue
		set_checklist_file skills "${id}"
		need_file "checklist file" "${CHECKLIST_FILE}"
		count=$(count_items "${CHECKLIST_FILE}")
		ids="${ids}${id} " counts="${counts}${count} " large="${large}${id} "
	done < <(printf '%s\n' "${sorted_ids}")
	large="${large}CONFORMANCE"
	small=$(small_seats "${ids}" "${counts}" "${SCRIPT_COUNT}")

	if (( LINE_TOTAL <= SMALL_SWARM_MAX_LINES )) && (( SCRIPT_COUNT == 0 && CONTRACT_COUNT == 0 )); then
		swarm_option Small 1 "${SMALL_SWARM_MAX_LINES} lines or fewer, no scripts or contracts" "${small}"
		swarm_option Large 0 "" "${large}"
		return 0
	fi
	if (( LINE_TOTAL > SMALL_SWARM_MAX_LINES )); then reason="over ${SMALL_SWARM_MAX_LINES} lines"; fi
	if (( SCRIPT_COUNT > 0 && CONTRACT_COUNT > 0 )); then
		reason="${reason:+${reason}, }has scripts and contracts"
	elif (( SCRIPT_COUNT > 0 )); then
		reason="${reason:+${reason}, }has scripts"
	elif (( CONTRACT_COUNT > 0 )); then
		reason="${reason:+${reason}, }has contracts"
	fi
	swarm_option Large 1 "${reason}" "${large}"
	swarm_option Small 0 "" "${small}"
}

gen_swarm_agent() {
	local seats="" file
	need_file "--target agent file" "${OPT_TARGET}"
	set_line_total "${OPT_TARGET}"
	if (( LINE_TOTAL < AGENT_FEW_SEATS_BELOW_LINES )); then
		swarm_option "" 0 "under ${AGENT_FEW_SEATS_BELOW_LINES} lines" "${AGENT_FEW_SEATS}"
		return 0
	fi
	for file in "${RULEBOOK}"/references/agents/[0-9]*.md; do
		if [[ -f "${file}" ]]; then
			READ_FILES+=("${file}")
			file=${file##*/}
			seats="${seats}${seats:+ }agent-${file%%-*}"
		fi
	done
	[[ -n "${seats}" ]] || input_error "no agent checklist under ${RULEBOOK}/references/agents/; expected [0-9]*.md files; check --rulebook"
	swarm_option "" 0 "${AGENT_FEW_SEATS_BELOW_LINES} lines or more" "${seats}"
}

# set_report_section NAME — sets SECTION to the author report's NAME
# section, verbatim, outer blank lines trimmed; exit 3 when it is missing.
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
			if ($0 ~ /^[0-9]+\. \*\*/) { rest = $0; sub(/^[0-9]+\. \*\*[^*]+\*\*[ \t]*/, "", rest); if (rest != "") body[++n] = rest }
		}
		END {
			print (found ? "found" : "missing")
			first = 1; while (first <= n && body[first] ~ /^[ \t]*$/) first++
			last = n; while (last >= first && body[last] ~ /^[ \t]*$/) last--
			for (i = first; i <= last; i++) print body[i]
		}')
	[[ "${SECTION%%$'\n'*}" == found ]] || input_error "report section not found: $1 in ${OPT_REPORT}; expected a \"## §<n> $1\" or \"<n>. **$1:**\" line; send the report back to its author"
	if [[ "${SECTION}" == found ]]; then SECTION=""; else SECTION=${SECTION#found$'\n'}; fi
}

# section_records NAME TAG — SECTION's display records, tab-joined, each
# kind after TAG:
#   <TAG>I item    an Eval set "E<n>" item line, or a Field table "- " row,
#                  without its "- " and cut to SHORT_LINE_MAX characters;
#   <TAG>U list    the Field table's "Left unset:" list, unless empty or none;
#   <TAG>P count   the Open points' top-level "<n>." item count, when not 0;
#   X NAME         alone, when the section has text but none of these
#                  shapes and its first text, after a leading "(...)" mode
#                  condition, does not start with "none".
section_records() {
	printf '%s\n' "${SECTION}" | NAME=$1 TAG=$2 MAX=${SHORT_LINE_MAX} awk "${CUT_AWK}"'
		function item(s) { sub(/^- /, "", s); print ENVIRON["TAG"] "I\t" cut(s, ENVIRON["MAX"] + 0); shapes++ }
		ENVIRON["NAME"] == "Eval set" && /^(- )?E[0-9]+[ :(]/ { item($0) }
		ENVIRON["NAME"] == "Field table" && /^- / { item($0) }
		ENVIRON["NAME"] == "Field table" && /^Left unset:/ {
			shapes++; s = $0; sub(/^Left unset:[ \t]*/, "", s); sub(/[ \t.]+$/, "", s)
			if (s != "" && s != "none") print ENVIRON["TAG"] "U\t" s
		}
		ENVIRON["NAME"] == "Open points" && /^[0-9]+[.)] / { points++ }
		!have_first && NF { s = $0; sub(/^\([^)]*\)[ \t]*/, "", s); if (s != "") { first = s; have_first = 1 } }
		END {
			if (points) print ENVIRON["TAG"] "P\t" points
			if (!shapes && !points && have_first && first !~ /^none([ .(]|$)/) print "X\t" ENVIRON["NAME"]
		}'
}

gen_g2() {
	local section records="" tag
	if [[ -z "${OPT_RULEBOOK}" && -z "${HOME:-}" && -z "${CLAUDE_CONFIG_DIR:-}" ]]; then usage_error "HOME is not set; give --rulebook DIR"; fi
	RULEBOOK=${OPT_RULEBOOK:-${CONFIG_DIR}/skills/standard-harness-authoring}
	strip_slashes RULEBOOK
	check_path --rulebook "${RULEBOOK}"
	need_file "--report file" "${OPT_REPORT}"
	SCRIPT_COUNT=0 CONTRACT_COUNT=0 SWARM=""
	if [[ "${OPT_KIND}" == skill ]]; then gen_swarm_skill; else gen_swarm_agent; fi
	for section in "Eval set" "Field table" "Open points"; do
		set_report_section "${section}"
		case "${section}" in
			"Eval set") tag=E ;;
			"Field table") tag=F ;;
			*) tag=O ;;
		esac
		records="${records}$(section_records "${section}" "${tag}")"$'\n'
	done
	build_view '($sections | records) as $all | {target_lines: $lines, scripts: $scripts, contracts: $contracts,
		swarm: ($swarm | records | map((.[3] | split(" ") | map(select(. != ""))) as $seats
			| {size: (.[0] | or_null), recommended: (.[1] == "1"), why: (.[2] | or_null),
			   seats: ($seats | map(select(. != "CONFORMANCE"))), conformance: ($seats | any(. == "CONFORMANCE"))})),
		evals: ($all | map(select(.[0] == "EI") | .[1] // "")),
		field_rows: ($all | map(select(.[0] == "FI") | .[1] // "")),
		left_unset: ($all | map(select(.[0] == "FU") | .[1] // "") | first // null),
		open_points: ($all | map(select(.[0] == "OP") | .[1] | tonumber) | add // 0),
		unparsed: ($all | map(select(.[0] == "X") | .[1]))}' \
		--argjson lines "${LINE_TOTAL}" --argjson scripts "${SCRIPT_COUNT}" --argjson contracts "${CONTRACT_COUNT}" \
		--arg swarm "${SWARM}" --arg sections "${records}"
}

# ---------------------------------------------------------------------------
# G3 Choose what to fix
# ---------------------------------------------------------------------------

# merged_records — the decision lines of --merged above "## Non-PASS item
# lines", each a tab-joined record:
#   B id seat location fix   a blocking: item, its Fix from its item line
#      below the heading cut at its first sentence or SHORT_LINE_MAX
#      characters ("not given" when there is none), "" when the report has
#      no such heading; a seat or location "-" is "";
#   S id location            a should-fail: item;
#   I text                   an invalid-waiver: line without its tag, cut;
#   W text                   a warning: line without its tag, whole;
#   F label value            progress: and unchanged:;
#   C label count            each other kind of line, in the order first seen;
#   N                        alone, when the heading is missing.
# An item's continuation lines join it; with several items for one ID, the
# one citing the merged line's location wins.
merged_records() {
	read_clean "${OPT_MERGED}" | MAX=${SHORT_LINE_MAX} awk "${CUT_AWK}"'
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
		function part(s) { return s == "-" ? "" : s }
		function kind_label(t) {
			if (t == "waived:") return "Waived"
			if (t == "possible-duplicate:") return "Possible duplicates"
			if (t == "TRUNCATED") return "Truncated"
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
					printf "B\t%s\t%s\t%s\t%s\n", w[2], part(w[3]), part(w[4]), fix_for(w[2], w[4])
				} else if (w[1] == "should-fail:") {
					printf "S\t%s\t%s\n", w[2], part(w[5])
				} else if (w[1] == "invalid-waiver:") {
					s = line[i]; sub(/^invalid-waiver:[ \t]*/, "", s); print "I\t" cut(s, max)
				} else if (w[1] == "warning:") {
					s = line[i]; sub(/^warning:[ \t]*/, "", s); print "W\t" s
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

# check_records NAME FILE — a "K<tab>NAME<tab>line" record per FAIL line of
# FILE, cut to SHORT_LINE_MAX, then "C<tab>NAME WARN<tab><count>".
check_records() {
	read_clean "$2" | NAME=$1 MAX=${SHORT_LINE_MAX} awk "${CUT_AWK}"'
		$2 == "FAIL" { print "K\t" ENVIRON["NAME"] "\t" cut($0, ENVIRON["MAX"] + 0) }
		$2 == "WARN" { warn++ }
		END { printf "C\t%s WARN\t%d\n", ENVIRON["NAME"], warn }'
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

# eval_outcome_records — per grade file, an "E<tab>line" record for each
# outcome NEW failed or both arms passed, cut to SHORT_LINE_MAX; sets
# OTHER_OUTCOMES and FEEDBACK to the counts of the other outcomes and of the
# Outcome feedback lines other than "none". Records as read each grade file
# runs/<id>-grade.md and that eval's runs/<id>-new.md and runs/<id>-base.md
# when present.
eval_outcome_records() {
	local grades file view counts run_id arm
	OTHER_OUTCOMES=0 FEEDBACK=0 OUTCOMES=""
	grades=$(grade_files)
	while IFS= read -r file; do
		[[ -n "${file}" ]] || continue
		READ_FILES+=("${file}")
		run_id=${file%-grade.md}
		for arm in new base; do
			if [[ -f "${run_id}-${arm}.md" ]]; then READ_FILES+=("${run_id}-${arm}.md"); fi
		done
		set_eval_id "${file}"
		view=$(read_clean "${file}" | ID=${EVAL_ID} MAX=${SHORT_LINE_MAX} awk "${OUTCOME_AWK}${CUT_AWK}"'
			/^O[0-9]+ · NEW / { new = new_status($0); if (new != "PASS" || base_status($0) == "PASS") print "E\t" cut(ENVIRON["ID"] " " $0, ENVIRON["MAX"] + 0); else other++; next }
			index($0, "Outcome feedback:") == 1 { in_fb = 1; s = $0; sub(/^Outcome feedback:[ \t]*/, "", s); if (s != "none") feedback++; next }
			/^(Claims|Notes|Gaps):/ || index($0, "=== END OF ") == 1 { in_fb = 0; next }
			in_fb && NF { feedback++ }
			END { printf "\036%d %d", other, feedback }')
		OUTCOMES="${OUTCOMES}${view%%$'\036'*}"
		counts=${view##*$'\036'}
		OTHER_OUTCOMES=$((OTHER_OUTCOMES + ${counts% *}))
		FEEDBACK=$((FEEDBACK + ${counts#* }))
	done < <(printf '%s\n' "${grades}")
}

gen_g3() {
	local verdict records
	need_file "--merged file" "${OPT_MERGED}"
	need_file "--lint file" "${OPT_LINT}"
	require_line "VERDICT: " "${OPT_MERGED}" "a merge-verdicts.sh output saved as review-r<n>.md"
	verdict=${LINE#VERDICT: }
	verdict=${verdict%% *}
	require_line "SUMMARY " "${OPT_LINT}" "a whole lint.sh output"
	records=$(merged_records)
	if [[ $'\n'"${records}"$'\n' == *$'\nN\n'* ]]; then
		warning "${OPT_MERGED} has no \"## Non-PASS item lines\" section; Fix lines not shown"
	fi
	records="${records}"$'\n'$(check_records "Lint" "${OPT_LINT}")
	if [[ -n "${OPT_HELP_CHECK}" ]]; then
		need_file "--help-check file" "${OPT_HELP_CHECK}"
		require_line "SUMMARY " "${OPT_HELP_CHECK}" "a whole help-check.sh output"
		records="${records}"$'\n'$(check_records "Help check" "${OPT_HELP_CHECK}")
	fi
	eval_outcome_records
	set_seat_counts
	records="${records}"$'\n'"${OUTCOMES}"
	records="${records}"$'\n'"C"$'\t'"Not read in full"$'\t'"${NOT_READ}"
	records="${records}"$'\n'"C"$'\t'"Seat notes"$'\t'"${NOTES}"
	records="${records}"$'\n'"C"$'\t'"Other eval outcomes"$'\t'"${OTHER_OUTCOMES}"
	records="${records}"$'\n'"C"$'\t'"Outcome feedback"$'\t'"${FEEDBACK}"
	build_view '($records | records) as $all
		| ($all | any(.[0] == "N")) as $no_fix
		| def tagged($tag): $all | map(select(.[0] == $tag));
		{verdict: $verdict,
		 blocking: (tagged("B") | map({id: .[1], seat: (.[2] // "" | or_null), location: (.[3] // "" | or_null),
			fix: (if $no_fix then null else (.[4] // "" | or_null) end)})),
		 should_fix: (tagged("S") | map({id: .[1], location: (.[2] // "" | or_null)})),
		 invalid_waivers: (tagged("I") | map(.[1] // "")),
		 warnings: (tagged("W") | map(.[1] // "")),
		 check_fails: (tagged("C") | map(.[1] | select(endswith(" WARN")) | rtrimstr(" WARN"))
			| map(. as $name | {name: $name, lines: ($all | map(select(.[0] == "K" and .[1] == $name) | .[2] // ""))})),
		 eval_outcomes: (tagged("E") | map(.[1] // "")),
		 fields: ($all | map(select(.[0] == "F" or .[0] == "C")
			| if .[0] == "F" then [.[1], (.[2] // "")] else [.[1], (.[2] | tonumber)] end))}' \
		--arg verdict "${verdict}" --arg records "${records}"
}

# ---------------------------------------------------------------------------
# G4 Deploy
# ---------------------------------------------------------------------------

# set_link_now — sets LINK_KIND and LINK_TO to what the --link path holds
# now: a symlink to the source, a symlink elsewhere (LINK_TO its target,
# cleaned), something else, or nothing.
set_link_now() {
	LINK_TO=""
	if [[ -L "${OPT_LINK}" ]]; then
		LINK_TO=$(readlink -- "${OPT_LINK}" | tr -d '\000-\037\177')
		if [[ "${LINK_TO}" == "${OPT_TARGET}" ]]; then LINK_KIND=source LINK_TO=""; else LINK_KIND=symlink; fi
	elif [[ -e "${OPT_LINK}" ]]; then
		LINK_KIND=other
	else
		LINK_KIND=absent
	fi
}

gen_g4() {
	local checks
	need_file "--merged file" "${OPT_MERGED}"
	need_file "--lint file" "${OPT_LINT}"
	require_line "SUMMARY " "${OPT_LINT}" "a whole lint.sh output"
	checks="lint.sh: ${LINE}"
	if [[ -n "${OPT_HELP_CHECK}" ]]; then
		need_file "--help-check file" "${OPT_HELP_CHECK}"
		require_line "SUMMARY " "${OPT_HELP_CHECK}" "a whole help-check.sh output"
		checks="${checks}"$'\n'"help-check.sh: ${LINE}"
	fi
	require_line "VERDICT: " "${OPT_MERGED}" "a merge-verdicts.sh output saved as review-r<n>.md"
	checks="${checks}"$'\n'"merge-verdicts.sh: ${LINE}"
	set_link_now
	build_view '{checks: ($checks | lines), source: $target, link: $link,
		link_now: {kind: $kind, points_to: ($to | or_null)}}' \
		--arg checks "${checks}" --arg link "${OPT_LINK}" --arg kind "${LINK_KIND}" --arg to "${LINK_TO}"
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
# should-fail: ID neither open nor waived. A waiver line is
# "[- ]<ID>: <reason> (owner)", as merge-verdicts.sh reads it.
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

# set_merged — sets LAST_MERGED, LAST_VERDICT and EARLIER_MERGED from the
# run dir's review-r<n>.md files.
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
	if [[ ${#merged[@]} -gt 1 ]]; then EARLIER_MERGED=("${merged[@]:0:${#merged[@]}-1}"); fi
}

# set_findings — FINDINGS: finding_ids' table, "" without a merged report.
set_findings() {
	FINDINGS=""
	[[ -n "${LAST_MERGED}" ]] || return 0
	if [[ -n "${OPT_WAIVERS}" ]]; then need_file "--waivers file" "${OPT_WAIVERS}"; fi
	FINDINGS=$(finding_ids "${LAST_MERGED}" "${EARLIER_MERGED[@]+"${EARLIER_MERGED[@]}"}")
}

# set_target_files — TARGET_FILES: target-files.txt's line count, or ""
# when the run dir has none.
set_target_files() {
	local list="${OPT_RUN_DIR}/target-files.txt" files
	TARGET_FILES=""
	[[ -e "${list}" ]] || return 0
	need_file "target-files.txt" "${list}"
	files=$(read_clean "${list}")
	TARGET_FILES=$(count_lines "${files}")
}

# set_evals — EVAL_RUNS, EVAL_OUTCOMES and EVAL_FAILED over the grade files:
# their count, their outcome count and how many NEW did not pass.
set_evals() {
	local grades file counts
	EVAL_RUNS=0 EVAL_OUTCOMES=0 EVAL_FAILED=0
	grades=$(grade_files)
	while IFS= read -r file; do
		[[ -n "${file}" ]] || continue
		READ_FILES+=("${file}")
		set_eval_id "${file}"
		counts=$(read_clean "${file}" | awk "${OUTCOME_AWK}"'
			/^O[0-9]+ · NEW / { n++; if (new_status($0) != "PASS") failed++ }
			END { printf "%d %d", n, failed }')
		EVAL_RUNS=$((EVAL_RUNS + 1))
		EVAL_OUTCOMES=$((EVAL_OUTCOMES + ${counts% *}))
		EVAL_FAILED=$((EVAL_FAILED + ${counts#* }))
	done < <(printf '%s\n' "${grades}")
}

# set_state — from state.md's "- <Key>: <value>" lines: NOT_RUN (every
# "- Not run:" value, one per line), ENDED, LIVE and DEPLOY (each the first
# value). With no "- Ended:" line, ENDED_FREE is 1 when another line names
# how the run ended: one holding the word "ended", or a "step:" line holding
# the word "closed". With no "- Live:" line, LIVE_FREE is 1 when another line
# holds "live validation" or the word "live" before a ":". Case is ignored.
set_state() {
	local state="${OPT_RUN_DIR}/state.md" values
	need_file "state.md" "${state}"
	# One record per key, separated by RS (octal 036), which read_clean
	# has already removed from the text.
	values=$(read_clean "${state}" | awk '
		function value(s) { sub(/^- [A-Za-z ]+:[ \t]*/, "", s); return s }
		function word(s, w) { return s ~ ("(^|[^a-z])" w "([^a-z]|$)") }
		/^- Not run:/ { not_run = not_run value($0) "\n"; next }
		/^- Ended:/ { if (!has_ended) ended = value($0); has_ended = 1; next }
		/^- Deploy:/ && deploy == "" { deploy = value($0); next }
		/^- Live:/ { if (!has_live) live = value($0); has_live = 1; next }
		{
			lower = tolower($0)
			if (word(lower, "ended") || (lower ~ /^(- )?step:/ && word(lower, "closed"))) ended_free = 1
			if (index(lower, "live validation") || lower ~ /(^|[^a-z])live:/) live_free = 1
		}
		END {
			printf "%s\036%s\036%s\036%s\036%d\036%d", not_run, ended, live, deploy,
				(!has_ended && ended_free), (!has_live && live_free)
		}')
	NOT_RUN=${values%%$'\036'*}; values=${values#*$'\036'}
	ENDED=${values%%$'\036'*}; values=${values#*$'\036'}
	LIVE=${values%%$'\036'*}; values=${values#*$'\036'}
	DEPLOY=${values%%$'\036'*}; values=${values#*$'\036'}
	ENDED_FREE=${values%%$'\036'*}; LIVE_FREE=${values#*$'\036'}
}

gen_closing() {
	local not_run
	set_merged
	set_state
	set_findings
	set_target_files
	set_evals
	not_run=$(list_items "${NOT_RUN}")
	build_view '($findings | records) as $table
		| def ids($kind): $table | map(select(.[0] == $kind) | .[1]);
		{verdict: ($verdict | or_null), fixed: ids("fixed"), waived: ids("waived"), open: ids("open"),
		 target_files: (if $target_files == "" then null else ($target_files | tonumber) end),
		 evals: {runs: $runs, outcomes: $outcomes, failed: $failed},
		 ended: {value: ($ended | or_null), free_form: ($ended_free == "1")},
		 live: {value: ($live | or_null), free_form: ($live_free == "1")},
		 not_run: ($not_run | lines), deploy_done: ($deploy | startswith("done"))}' \
		--arg verdict "${LAST_VERDICT}" --arg findings "${FINDINGS}" --arg target_files "${TARGET_FILES}" \
		--argjson runs "${EVAL_RUNS}" --argjson outcomes "${EVAL_OUTCOMES}" --argjson failed "${EVAL_FAILED}" \
		--arg ended "${ENDED}" --arg ended_free "${ENDED_FREE}" --arg live "${LIVE}" --arg live_free "${LIVE_FREE}" \
		--arg not_run "${not_run}" --arg deploy "${DEPLOY}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
RULEBOOK="" LINE="" LINE_TOTAL="" CHECKLIST_FILE="" SECTION="" EVAL_ID=""
LAST_VERDICT="" LAST_MERGED="" PROBLEMS="" VIEW="" NOTICES=""
EARLIER_MERGED=()

set_notices
case "${OPT_GATE}" in
	g1) gen_g1 ;;
	g2) gen_g2 ;;
	g3) gen_g3 ;;
	g4) gen_g4 ;;
	*)  gen_closing ;;
esac
write_plan
