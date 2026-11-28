#!/usr/bin/env sh
# Renders the spec gates, so the main thread never hand-formats them: the
# revision offer (revise the spec?) and the approval (approve the spec?), or
# with --question the gate's question. The
# approval view takes its Goal line and open points from the draft itself,
# and only while the draft is the one --approval-plan hashed.
# views/spec-offer.jq and views/spec-approval.jq lay them out and
# human-view's show.sh renders them. Pipe its stdout into
# procedure-approval-gate's open-gate.sh, which shows the gate.
# shellcheck source-path=SCRIPTDIR source-path=SCRIPTDIR/../../../../engine/crucible/scripts/lib
set -eu
umask 077

readonly PROG='render-spec-gate.sh'
readonly VIEW_LIB='human-view'
readonly RENDER_LIB='scripts/lib/render.sh'
readonly CRUCIBLE_SKILL='crucible'
readonly SPEC_LABEL='spec'
# The revision offer stays a glance: a few one-line reasons, each short
# enough to fit one terminal line beside its list number.
readonly MAX_REASONS=3
readonly MAX_REASON_CHARS=100
# A line is never cut, so a longer Goal line or open point is refused: the
# draft is rewritten instead. Past ten points the spec is not ready to approve.
readonly MAX_LINE_CHARS=200
readonly MAX_OPEN_POINTS=10
# The shell's pattern checks stay byte-wise on macOS and Linux; jq reads the
# plan and the draft as UTF-8 whatever the locale.
LC_ALL=C
export LC_ALL

# Definitions every program below starts with: the draft's parts, read from
# $draft (the draft's text; empty for a revision offer). A line inside a ``` or ~~~
# fence, its fence lines included, is never a heading. A section runs from its
# "## " heading (its name in any case, maybe followed by more words) to the
# next level 1 or 2 heading. In Open points, an item starts at a list mark in
# the first or second column of the raw line; a line right after it, or an
# indented one (a tab, or two spaces or more) after a blank line, continues
# it, a sub-bullet included; when there are items, any other text, before
# or after them, is stray.
# The programs are single-quoted on purpose: their $ signs are jq's.
# shellcheck disable=SC2016
readonly COMMON_JQ='
def trimmed: sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "");
def option($label; $description): {label: $label, description: $description};
def is_none: test("^none\\.?$"; "i");
def text: gsub("[[:cntrl:]\u2028\u2029]"; " ") | trimmed;
def fence_mark: if test("^ {0,3}(```|~~~)") then capture("^ {0,3}(?<mark>```|~~~)").mark else null end;
def draft_lines: $draft | gsub("\r\n"; "\n") | split("\n")
	| reduce .[] as $raw ({fence: null, lines: []};
		($raw | fence_mark) as $mark
		| if .fence == null and $mark == null then .lines += [{raw: $raw, fenced: false}]
		  else (if .fence == null then .fence = $mark elif $mark == .fence then .fence = null else . end)
			| .lines += [{raw: $raw, fenced: true}] end)
	| .lines;
def is_heading($pattern): (.fenced | not) and (.raw | test($pattern; "i"));
def section($lines; $name):
	(first(range(0; $lines | length) as $i | select($lines[$i] | is_heading("^##[ ]+\($name)([^[:alnum:]].*)?$")) | $i) // null) as $at
	| if $at == null then null
	  else $lines[($at + 1):] | .[:(first(range(0; length) as $i | select(.[$i] | is_heading("^#{1,2}( |$)")) | $i) // length)] end;
def list_parts:
	reduce .[] as $line ({items: [], prose: [], stray: 0, fenced: false, gap: false};
		if $line.fenced then .fenced = true
		elif $line.raw | test("^[[:space:]]*$") then .gap = true
		elif $line.raw | test("^ ?([-*+]|[0-9]{1,9}[.)])([ \t]|$)") then
			.items += [$line.raw | sub("^ ?([-*+]|[0-9]{1,9}[.)])"; "") | text] | .gap = false
		elif (.items | length) > 0 and (.gap == false or ($line.raw | test("^(\t|  )"))) then
			.items[(.items | length) - 1] += " " + ($line.raw | text) | .gap = false
		elif (.items | length) > 0 then .stray += 1
		else .prose += [$line.raw | text] end)
	| .items |= map(trimmed);
def draft:
	draft_lines as $lines
	| section($lines; "goal") as $goal
	| (section($lines; "open points") // [] | list_parts) as $parts
	| {goal_found: ($goal != null),
	   goal: (if $goal == null then null else first($goal[] | select(.fenced | not) | .raw | text | select(. != "")) // null end),
	   fenced: $parts.fenced,
	   stray: ($parts.stray + (if ($parts.items | length) > 0 then $parts.prose | length else 0 end)),
	   prose_only: (($parts.items | length) == 0 and ($parts.prose | length) > 0
		and (($parts.prose | length) == 1 and ($parts.prose[0] | is_none) | not)),
	   points: (if ($parts.items | length) == 1 and ($parts.items[0] | is_none) then [] else $parts.items end)};
def approve_label: if (draft | .points | length) > 0 then "Approve, leave them to the agents" else "Approve" end;
'

# Prints one line per problem of the slurped plan file; nothing when it is one
# plan object of a known case with the fields that case takes.
# shellcheck disable=SC2016
readonly PLAN_CHECK_JQ='
def expected_plan: "expected one JSON object {\"case\": \"revision\", \"reasons\": [str, ...]} or {\"case\": \"approval\", \"spec\": PATH, \"sha256\": HEX}";
def expected_reasons: "expected an array of 1 to \($max_reasons) strings";
def unknown_fields($allowed): (keys - $allowed)[] | "\(tojson) is an unknown field; expected only \($allowed | join(", "))";
def reason_problem:
	"reasons[\(.key)]" as $at
	| .value
	| if type != "string" then "\($at) is a JSON \(type); expected a string"
	  elif test("^[[:space:]]*$") then "\($at) is empty; expected one line of text; try saying why in a few words"
	  elif test("[[:cntrl:]\u2028\u2029]") then "\($at) holds a control character or a line or paragraph separator (such as a line break, tab or U+2028); expected one line of plain text; try joining it into one line"
	  elif length > $max_chars then "\($at) is \(length) characters; expected at most \($max_chars); try a shorter reason"
	  else empty end;
def reasons_problems:
	if has("reasons") | not then "reasons missing; \(expected_reasons)"
	elif (.reasons | type) != "array" then "reasons is a JSON \(.reasons | type); \(expected_reasons)"
	elif (.reasons | length) < 1 or (.reasons | length) > $max_reasons then "reasons holds \(.reasons | length) items; \(expected_reasons)"
	else .reasons | to_entries[] | reason_problem end;
def approval_problems:
	(if has("spec") | not then "spec missing; expected the draft'\''s absolute path; try running --approval-plan"
	 elif (.spec | type) != "string" then "spec is a JSON \(.spec | type); expected a string holding an absolute path; try running --approval-plan"
	 else empty end),
	(if has("sha256") | not then "sha256 missing; expected the draft'\''s sha256; try running --approval-plan"
	 elif (.sha256 | type) != "string" or (.sha256 | test("^[0-9a-f]{64}$") | not) then "sha256 is not 64 lowercase hex digits; expected the draft'\''s sha256; try running --approval-plan"
	 else empty end);
if length != 1 then "the plan file holds \(length) JSON values; \(expected_plan)"
elif (.[0] | type) != "object" then "the plan file holds a JSON \(.[0] | type); \(expected_plan)"
else .[0]
	| if has("case") | not then "case missing; \(expected_plan)"
	  elif .case == "approval" then unknown_fields(["case", "spec", "sha256"]), approval_problems
	  elif .case == "revision" then unknown_fields(["case", "reasons"]), reasons_problems
	  else "case is \(.case | tojson); expected \"revision\" or \"approval\"" end
end
'

# Prints one line per problem of the draft's parts; nothing when its approval
# view can be rendered whole.
# shellcheck disable=SC2016
readonly DRAFT_CHECK_JQ='
# A draft is written once, so a fix is a new draft and a new plan.
def again: "write a new draft, then run --approval-plan on it";
draft
| if .goal_found | not then "the draft has no ## Goal heading; expected a ## Goal section whose first non-blank line states the goal; try adding it: \(again)"
  elif .goal == null then "the draft'\''s ## Goal holds no text; expected its first non-blank line to state the goal; try writing it: \(again)"
  elif (.goal | length) > $max_line_chars then "the Goal'\''s first line is \(.goal | length) characters; expected at most \($max_line_chars); rewrite the Goal'\''s first line shorter: \(again)"
  else empty end,
  (if .fenced then "the draft'\''s ## Open points holds a code fence (``` or ~~~); expected plain list items; try removing the fence: \(again)" else empty end),
  (if .prose_only then "the draft'\''s ## Open points holds text but no list item; expected each open point as a list item, or None alone; try listing them: \(again)" else empty end),
  (if .stray > 0 then "the draft'\''s ## Open points holds \(.stray) line(s) of text outside its list items; expected only list items and their continuations; rewrite each open point as one list item: \(again)" else empty end),
  (.points | to_entries[] | select(.value == "") | "open point \(.key + 1) is empty; expected text after its list mark; try writing it or removing the mark: \(again)"),
  (if (.points | length) > $max_points then "the draft holds \(.points | length) open points; expected at most \($max_points); try settling some: \(again)"
   else .points | to_entries[] | select(.value | length > $max_line_chars)
	| "open point \(.key + 1) is \(.value | length) characters; expected at most \($max_line_chars); rewrite open point \(.key + 1) shorter: \(again)" end)
'

# The gate's data for its template: views/spec-offer.jq takes the trimmed
# reasons, views/spec-approval.jq the draft's Goal line, its open points and
# its path.
# shellcheck disable=SC2016
readonly VIEW_DATA_JQ='
.[0]
| if .case == "revision" then {reasons: (.reasons | map(trimmed))}
  else draft as $parts | {goal: $parts.goal, points: $parts.points, spec: .spec} end
'

# Prints the AskUserQuestion fields of the gate as one JSON object.
# shellcheck disable=SC2016
readonly QUESTION_JQ='
option("Change it: say what"; "Type the change; the spec comes back here.") as $change
| .[0]
| if .case == "revision" then
	{header: "Spec", question: "Revise the spec?",
	 options: [option("Revise it (Recommended)"; "Draft a revision; it then goes to the approval gate."),
		option("Keep it as it is"; "The approved spec stays.")]}
  elif (draft | .points | length) > 0 then
	{header: "Approval", question: "Approve the spec?",
	 options: [option("Answer the open points (Recommended)"; "Answer them in the chat; the spec is updated and comes back here."),
		option(approve_label; "Approved; the open points stay as the agents'\'' call."),
		$change]}
  else
	{header: "Approval", question: "Approve the spec?",
	 options: [option("\(approve_label) (Recommended)"; "Approved; the spec enters the context."), $change]}
  end
'

# Prints plan field $name, or nothing when absent, plus a trailing "." so
# command substitution keeps a trailing line break; a NUL, which a shell
# variable cannot hold, becomes U+0001 so the control-character check sees it.
# shellcheck disable=SC2016
readonly FIELD_JQ='.[0][$name] // "" | explode | map(if . == 0 then 1 else . end) | implode + "."'

usage() {
	print_page <<EOF
usage: sh ${PROG} --plan-file PATH | sh <skills>/procedure-approval-gate/scripts/open-gate.sh --label spec-offer
         (the approval: --label spec-approval --effort FOLDER)
       sh ${PROG} --plan-file PATH --question
       sh ${PROG} --approval-plan --spec PATH --plan-out PATH [--spec-needed] [--typed-approval]
       sh ${PROG} --help | -h

Prints a spec gate as Markdown, or with --question its question: the
revision offer (case revision) or the approval (case approval).
stdin is never read; only --approval-plan writes, to --plan-out.

Options:
  --plan-file PATH  one JSON object, no other field:
                    {"case": "revision", "reasons": [str, ...]}: 1 to
                      ${MAX_REASONS} one-line reasons, not blank, at most ${MAX_REASON_CHARS}
                      characters; written with the Write tool
                    {"case": "approval", "spec": PATH, "sha256": HEX}: only
                      as --approval-plan writes it
  --question        print the gate's question, not the gate
  --approval-plan   write the plan of draft --spec, with its sha256, to
                    --plan-out
  --spec PATH       the draft, a regular file, no symbolic link, no // or
                    /./: <effort>/drafts/main-thread/<ID>-${SPEC_LABEL}.md
  --plan-out PATH   absolute, not a folder or a link, in an existing
                    folder: the path open-gate.sh --plan-path printed
  --spec-needed     also print the line spec_needed
  --typed-approval  also print the line pick_approve_option
  CLAUDE_CONFIG_DIR  holds skills/; default \$HOME/.claude

The draft, for the approval case and its question: its sha256 must equal the
plan's. A section runs from its "## " heading (any letter case, maybe more
words after the name) to the next "# " or "## " heading; a line inside a
code fence (three backticks or tildes) is never a heading.
  ## Goal         required; its first non-blank line, trimmed, at most
                  ${MAX_LINE_CHARS} characters, is the Goal line
  ## Open points  each top-level list item (-, *, + or 1.) is one point, at
                  most ${MAX_LINE_CHARS} characters, at most ${MAX_OPEN_POINTS}; its following and
                  indented lines are joined in; none: no section, an empty
                  one or only "None"; refused: a code fence or text outside
                  the items
A longer line is refused, never cut: rewrite the draft.

stdout on exit 0 only:
  a gate: its Markdown, no gate marker
  --question: one JSON object {"header": str, "question": str, "options":
    [{"label": str, "description": str}, ...]}, the first option marked
    (Recommended):
    revision: Revise it / Keep it as it is
    approval with open points: Answer the open points / Approve, leave them
      to the agents / Change it: say what
    approval with no open points: Approve / Change it: say what
  --approval-plan: SPEC_SHA256: <the draft's sha256>; then each line asked
    for, printed through show.sh
stderr on exits 2 and 3: one "${PROG}: <what>; expected <x>[; try <y>]"
  line per problem; a plan field is named case, reasons[<i>] (from 0),
  spec or sha256
stderr on exit 5: "${PROG}: install:", a prefix no other exit
  prints; do not rerun; stop

Exit codes:
  0  printed; pipe a gate into open-gate.sh, copy a question into one
     AskUserQuestion
  2  usage error; fix the call and rerun once, else show the human stderr
  3  invalid plan or draft; fix what stderr names and rerun once, else show
     the human stderr. "the draft changed since its plan": run
     --approval-plan again
  4  --approval-plan could not write --plan-out, or stdout closed; stop and
     show the exit code and stderr
  5  an install fault
  129, 130, 143  stopped by HUP, INT or TERM; nothing written

Dependencies: POSIX sh, jq 1.6+; a gate or a line: ${VIEW_LIB}'s
  scripts/show.sh and scripts/lib/render.sh, views/spec-offer.jq,
  spec-approval.jq and lines.jq; a draft:
  ${CRUCIBLE_SKILL}'s lib/crucible-space.sh, agent-context-file-checks.sh beside
  this script, tr, sha256sum or shasum; --approval-plan: mktemp, mv.
EOF
}

# Prints stdin with builtins only, so the help page prints with cat missing.
print_page() {
	while IFS= read -r page_line; do
		printf '%s\n' "${page_line}"
	done
}

warn() {
	printf '%s: %s\n' "${PROG}" "$1" >&2
}

# Prints an install or host fault (a missing or failing tool, never a problem
# of the input) with the "install:" prefix and exits 5.
install_fault() {
	warn "install: $1"
	exit 5
}

usage_error() {
	warn "$1"
	printf "Try '%s --help'.\n" "${PROG}" >&2
	exit 2
}

# Prints problem lines $1, when any, to stderr and exits 3.
refuse_problems() {
	[ -n "$1" ] || return 0
	printf '%s\n' "$1" | while IFS= read -r problem; do warn "${problem}"; done
	exit 3
}

# Removes the temp file of --approval-plan, when one is left.
# shellcheck disable=SC2329 # invoked by the EXIT trap
clean_up() {
	[ -z "${temp_file}" ] || rm -f "${temp_file}"
}

# Sets mode (gate, question or approval-plan), plan_file, spec and plan_out
# from the arguments, and refuses a combination the modes don't take.
parse_args() {
	plan_file='' spec='' plan_out='' want_question=false want_approval_plan=false spec_needed=false typed_approval=false
	while [ "$#" -gt 0 ]; do
		case $1 in
			--help | -h)
				usage
				exit 0
				;;
			--question)
				want_question=true
				shift
				;;
			--approval-plan)
				want_approval_plan=true
				shift
				;;
			--spec-needed)
				spec_needed=true
				shift
				;;
			--typed-approval)
				typed_approval=true
				shift
				;;
			--plan-file | --spec | --plan-out)
				[ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 needs a value; expected $1 PATH"
				case $1 in
					--plan-file) plan_file=$2 ;;
					--spec) spec=$2 ;;
					*) plan_out=$2 ;;
				esac
				shift 2
				;;
			*) usage_error 'unknown argument; expected --plan-file PATH, --question, --approval-plan, --spec PATH, --plan-out PATH, --spec-needed, --typed-approval or --help' ;;
		esac
	done
	if [ "${want_approval_plan}" = true ]; then
		check_approval_plan_args
	else
		check_plan_file_args
	fi
}

check_approval_plan_args() {
	mode=approval-plan
	[ -z "${plan_file}" ] && [ "${want_question}" = false ] ||
		usage_error '--approval-plan takes no --plan-file or --question; expected --approval-plan --spec PATH --plan-out PATH'
	[ -n "${spec}" ] || usage_error '--spec PATH missing; expected --approval-plan --spec PATH --plan-out PATH'
	[ -n "${plan_out}" ] || usage_error '--plan-out PATH missing; expected --approval-plan --spec PATH --plan-out PATH, the path open-gate.sh --plan-path printed'
	case ${plan_out} in
		*[[:cntrl:]]*) usage_error '--plan-out holds a control character (such as a line break or tab); expected one absolute path on one line' ;;
		/*) ;;
		*) usage_error '--plan-out is not absolute; expected the absolute path open-gate.sh --plan-path printed' ;;
	esac
	[ ! -L "${plan_out}" ] && [ ! -d "${plan_out}" ] ||
		usage_error '--plan-out is a folder or a symbolic link; expected a plain file path, the one open-gate.sh --plan-path printed'
}

check_plan_file_args() {
	mode=gate
	[ "${want_question}" = false ] || mode=question
	[ -z "${spec}" ] && [ -z "${plan_out}" ] && [ "${spec_needed}" = false ] && [ "${typed_approval}" = false ] ||
		usage_error '--spec, --plan-out, --spec-needed and --typed-approval go only with --approval-plan; expected --approval-plan --spec PATH --plan-out PATH'
	[ -n "${plan_file}" ] || usage_error '--plan-file PATH missing; expected --plan-file PATH naming the JSON file; stdin is not read'
}

# Exits 5 unless jq and, when printing a gate or a line, human-view's
# lib/render.sh and by it the templates and show.sh are in place; sets
# views_dir and show_script and sources lib/render.sh.
load_dependencies() {
	command -v jq >/dev/null 2>&1 ||
		install_fault 'jq missing; expected jq 1.6+ on PATH; try installing jq (macOS: brew install jq; Linux: the distro'\''s jq package)'
	skills_dir="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/skills"
	views_dir="$(script_dir)/../views"
	if [ "${mode}" = gate ]; then
		set -- spec-offer spec-approval
	elif [ "${spec_needed}" = true ] || [ "${typed_approval}" = true ]; then
		set -- lines
	else
		return 0
	fi
	render_lib="${skills_dir}/${VIEW_LIB}/${RENDER_LIB}"
	[ -f "${render_lib}" ] && [ -r "${render_lib}" ] ||
		install_fault "gate printer missing; expected ${render_lib}; install the ${VIEW_LIB} skill"
	# shellcheck source=../../../../engine/human-view/scripts/lib/render.sh
	. "${render_lib}"
	# shellcheck disable=SC2310 # its status is the answer; set -e is not relied on inside
	hv_check_printer "${skills_dir}/${VIEW_LIB}/scripts" "${views_dir}" "$@" || install_fault "${hv_printer_problem}"
	show_script=${hv_show}
}

# Sources the space rules and context.sh's path check and finds a sha256
# tool, once, before a draft is checked; exits 5 when one is missing.
load_draft_tools() {
	[ -z "${draft_tools_loaded}" ] || return 0
	command -v tr >/dev/null 2>&1 ||
		install_fault 'tr missing; expected it on PATH; install your base system'\''s tr'
	path_lib="$(script_dir)/agent-context-file-checks.sh"
	[ -f "${path_lib}" ] && [ -r "${path_lib}" ] ||
		install_fault "context path check missing; expected ${path_lib}; reinstall the procedure-context skill"
	# shellcheck source=agent-context-file-checks.sh
	. "${path_lib}"
	space_lib="${skills_dir}/${CRUCIBLE_SKILL}/scripts/lib/crucible-space.sh"
	[ -f "${space_lib}" ] && [ -r "${space_lib}" ] ||
		install_fault "space rules missing; expected ${space_lib}; install the ${CRUCIBLE_SKILL} skill"
	# shellcheck source=crucible-space.sh
	. "${space_lib}"
	if command -v sha256sum >/dev/null 2>&1; then
		digest_tool=sha256sum
	elif command -v shasum >/dev/null 2>&1; then
		digest_tool=shasum
	else
		install_fault 'sha256sum and shasum missing; expected one on PATH; try installing coreutils (Linux) or perl'\''s shasum (macOS: built in)'
	fi
	draft_tools_loaded=true
}

# Prints the folder this script was run from (".", when run by a bare name).
script_dir() {
	case $0 in
		*/*) printf '%s' "${0%/*}" ;;
		*) printf '.' ;;
	esac
}

# Sets digest to the sha256 of file $1, or exits 5 when the tool fails.
file_sha256() {
	if [ "${digest_tool}" = shasum ]; then
		digest_output=$(shasum -a 256 <"$1") || install_fault "shasum failed on $1; expected its sha256; try shasum -a 256 on it, then rerun"
	else
		digest_output=$(sha256sum <"$1") || install_fault "sha256sum failed on $1; expected its sha256; try sha256sum on it, then rerun"
	fi
	digest=${digest_output%% *}
	case ${digest} in
		*[!0-9a-f]*) install_fault "${digest_tool} printed no sha256 for $1; expected 64 lowercase hex digits; try ${digest_tool} on it, then rerun" ;;
		*) ;;
	esac
	[ "${#digest}" -eq 64 ] ||
		install_fault "${digest_tool} printed no sha256 for $1; expected 64 lowercase hex digits; try ${digest_tool} on it, then rerun"
}

# Prints one line per problem of draft path $2, named $1 (--spec or spec);
# nothing when it names a readable spec draft of an effort in the one form
# context.sh's --path takes and its gate.spec-approval.answered event matches.
spec_problems() {
	shared_problem=$(context_path_problem "$2")
	if [ -n "${shared_problem}" ]; then
		shown_path=$(printf '%s' "$2" | tr '[:cntrl:]' '?')
		printf '%s\n' "$1 ${shown_path}: ${shared_problem}; expected ${context_path_expected}"
		return 0
	fi
	case $2 in
		*//* | */./*)
			printf '%s\n' "$1 has a // or /./ segment: $2; expected the draft's path in its plain form, as crucible.sh new printed it"
			return 0
			;;
		*) ;;
	esac
	if [ ! -f "$2" ] || [ -L "$2" ]; then
		printf '%s\n' "$1 is not a regular file, or is a symbolic link: $2; expected an existing spec draft"
	elif [ ! -r "$2" ]; then
		printf '%s\n' "$1 is not readable: $2; expected a readable spec draft"
	fi
	draft_dir=${2%/*}
	effort_folder=${draft_dir%/drafts/main-thread}
	# shellcheck disable=SC2310 # pure tests; their status is the answer
	if ! crucible_split_id "${2##*/}" || [ "${crucible_name_rest}" != "${SPEC_LABEL}.md" ] ||
		[ "${effort_folder}" = "${draft_dir}" ] || ! crucible_is_effort_name "${effort_folder##*/}"; then
		printf '%s\n' "$1 is not named as a spec draft: $2; expected <effort folder>/drafts/main-thread/<ID>-${SPEC_LABEL}.md, ID <YYYYMMDDTHHMMSS>-<4 lowercase hex>"
	fi
}

# Sets slurped to the plan file read into one array, so an empty file and
# several values are caught as one problem, or exits 3 when it is unreadable
# or not JSON.
read_plan() {
	[ -f "${plan_file}" ] && [ -r "${plan_file}" ] ||
		refuse_problems "plan file not readable: ${plan_file}; expected a readable JSON file"
	slurped=$(jq -s '.' "${plan_file}" </dev/null 2>/dev/null) ||
		refuse_problems 'the plan file is not valid JSON; expected one JSON object; try checking its quotes, commas and brackets, then rerun'
}

# Runs jq program $1 over the slurped plan with draft file $2 (/dev/null for
# a revision offer) and the limits; a jq failure exits 5.
run_jq() {
	printf '%s' "${slurped}" | jq -rc --rawfile draft "$2" \
		--argjson max_reasons "${MAX_REASONS}" --argjson max_chars "${MAX_REASON_CHARS}" \
		--argjson max_line_chars "${MAX_LINE_CHARS}" --argjson max_points "${MAX_OPEN_POINTS}" "$1" ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
}

# Checks the plan file's shape, and for the approval case its draft: the path,
# the sha256 and the parts the view shows. Sets plan_case and draft_file.
load_plan() {
	read_plan
	shape_problems=$(run_jq "${PLAN_CHECK_JQ}" /dev/null)
	refuse_problems "${shape_problems}"
	plan_case=$(printf '%s' "${slurped}" | jq -r '.[0].case') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	draft_file=/dev/null
	[ "${plan_case}" = approval ] || return 0
	load_draft_tools
	plan_spec=$(printf '%s' "${slurped}" | jq -r --arg name spec "${FIELD_JQ}") ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	plan_spec=${plan_spec%.}
	path_problems=$(spec_problems spec "${plan_spec}")
	refuse_problems "${path_problems}"
	plan_sha256=$(printf '%s' "${slurped}" | jq -r '.[0].sha256') ||
		install_fault 'jq failed on valid JSON; expected jq 1.6+; try jq --version, then rerun'
	file_sha256 "${plan_spec}"
	[ "${digest}" = "${plan_sha256}" ] ||
		refuse_problems "the draft changed since its plan: ${plan_spec}; expected the draft as --approval-plan hashed it; run --approval-plan again"
	draft_file=${plan_spec}
	draft_problems=$(run_jq "${COMMON_JQ}${DRAFT_CHECK_JQ}" "${draft_file}")
	refuse_problems "${draft_problems}"
}

# Writes the approval plan of the draft to plan_out through a temp file
# beside it, so the plan is whole or absent, and prints the draft's sha256.
write_approval_plan() {
	load_draft_tools
	path_problems=$(spec_problems --spec "${spec}")
	refuse_problems "${path_problems}"
	file_sha256 "${spec}"
	plan_json=$(jq -nc --arg spec "${spec}" --arg sha256 "${digest}" '{case: "approval", spec: $spec, sha256: $sha256}' </dev/null) ||
		install_fault 'jq failed writing the plan; expected jq 1.6+; try jq --version, then rerun'
	plan_dir=${plan_out%/*}
	temp_file=$(mktemp "${plan_dir:-/}/.${plan_out##*/}.XXXXXX" 2>/dev/null) || {
		temp_file=''
		warn "could not create a temp file beside ${plan_out}; expected a writable existing folder; try open-gate.sh --plan-path again, then rerun"
		exit 4
	}
	{ printf '%s\n' "${plan_json}" >"${temp_file}" && mv -f "${temp_file}" "${plan_out}"; } 2>/dev/null || {
		warn "could not write the plan to ${plan_out}; expected the plan file written; try checking the folder's permissions and free space, then rerun"
		exit 4
	}
	temp_file=''
	print_output "SPEC_SHA256: ${digest}"
	[ "${spec_needed}" = false ] || show_line spec_needed
	[ "${typed_approval}" = false ] || show_pick_approve_option
}

# Prints the line pick_approve_option, naming the approve option the draft's
# approval question offers.
show_pick_approve_option() {
	approve_option=$(jq -rn --rawfile draft "${spec}" "${COMMON_JQ}approve_label" </dev/null) ||
		install_fault 'jq failed reading the draft; expected jq 1.6+; try jq --version, then rerun'
	show_line pick_approve_option --arg option "${approve_option}"
}

# Prints line $1, with its --arg options after it, for the human after the
# machine line, recorded as owed.
show_line() {
	line_name=$1
	shift
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_show_line "${show_script}" "${views_dir}" "${line_name}" "$@" ||
		install_fault "${hv_render_problem}; expected the line ${line_name} printed from views/lines.jq; try reinstalling procedure-context and ${VIEW_LIB}"
}

# Prints $1 to stdout; exits 4 when stdout is closed. Ignoring SIGPIPE turns a
# closed reader into a failed write this script can tell apart from a jq
# fault, rather than a silent kill.
print_output() {
	trap '' PIPE
	printf '%s\n' "$1" 2>/dev/null || exit 4
}

# Renders the plan's gate through its template to stdout: the revision offer
# or the approval; a show.sh fault is an install fault.
render_gate() {
	view_data=$(run_jq "${COMMON_JQ}${VIEW_DATA_JQ}" "${draft_file}")
	view_name='spec-approval'
	[ "${plan_case}" = approval ] || view_name='spec-offer'
	# shellcheck disable=SC2310 # its status names the fault; set -e is not relied on inside
	hv_render_gate "${show_script}" "${views_dir}" "${view_name}" "${view_data}" ||
		install_fault "${hv_render_problem}; expected the gate rendered from views/${view_name}.jq; try reinstalling procedure-context and ${VIEW_LIB}"
}

temp_file='' draft_tools_loaded=''
trap clean_up EXIT
# A signal exits through the EXIT trap, so the temp file goes on every path.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
parse_args "$@"
load_dependencies
if [ "${mode}" = approval-plan ]; then
	write_approval_plan
	exit 0
fi
load_plan
if [ "${mode}" = question ]; then
	output=$(run_jq "${COMMON_JQ}${QUESTION_JQ}" "${draft_file}")
	print_output "${output}"
else
	render_gate
fi
