#!/usr/bin/env sh
#
# render-md.sh — the SOLE deterministic Markdown renderer for a flow-review
#                durable artifact. Reads ONE review-artifact JSON object on
#                stdin, writes structured Markdown on stdout. No mutation, no
#                network, no lock — a pure transform, byte-identical on
#                macOS and Linux.
#
# WHY a dedicated renderer (not inline agent prose): the human-facing
# rendering of a review artifact must be built from what is ACTUALLY on the
# document, the same way every time — not re-phrased per turn by an LLM.
# Mirrors the GTD inbox's render-md.sh discipline exactly: one authority, one
# place to fix a rendering bug.
#
# WHY every field reaches the output only as a jq VALUE inside a STATIC jq
# program (never concatenated into the program text): a `problem`/`fix`
# string containing $(...) or backticks is emitted as an inert value — it can
# never execute. Execution is only half the threat, though: finding text
# describes an arbitrary, possibly-adversarial target repo, and a value could
# otherwise forge document STRUCTURE (a fabricated `### Realistic` section or
# a bogus `**Approved**` line), hide or reorder what the human reads, or
# render live HTML and links. Every displayed value therefore goes through
# `neutralize` before it reaches the template: C0/C1 controls and the
# line/paragraph separators collapse to a space, and every other character of
# forbidden_characters (lib/review-aggregates.jq — bidi overrides and
# isolates, zero-width and other invisible format characters, the soft
# hyphen, variation selectors, tag characters) becomes U+FFFD. Replacing
# rather than stripping keeps a tampered value visible as tampered instead of
# silently reordered or rejoined, and rendering never fails on one.
#
# What is guaranteed, precisely: an artifact value can never emit a NEW line,
# and every line starts with literal template text (a heading, a list
# marker, or `**`); the one value that opens a list item's text with no
# template prefix of its own — a name in the Reviewers list — has a leading
# block marker backslash-escaped (`defuse_block_marker`). No value renders
# HTML, a link, an image or emphasis: `escape_inline` backslash-escapes `<`,
# `&` (so no character reference can decode into a hidden character), `](`,
# `![`, the emphasis and strikethrough characters `*`, `_` and `~`, and
# every backtick that does not close a code span inside the same value, so no
# code span can reach across into the template or the next value, and no
# value can bold, strike or hide what the human reads. Text inside a value's
# own code span is literal already and is left as written.
#
# WHY a proof shows each file:line by its file name: a proof names its
# evidence as a repo path, and the human reads every location in the render
# by the same rule — the file name and line in a code span, with the
# directory that tells it apart when another file shares the name. A proof
# is rendered with its locators replaced by those labels.
#
# WHY both modes recompute the verdict and counts from findings[] instead of
# printing the stored summary/overall_verdict: the verdict is what tells the
# human whether a change is blocked, so neither mode may inherit a stale or
# forged aggregate, and the two modes can never disagree.
#
# Usage: see --help.
#
# Input (stdin):
#   ONE review-artifact JSON object (per review-artifact.schema.json).
#
# Output (stdout):
#   Deterministic Markdown, emitted as LIVE text (never fenced) with a single
#   trailing newline and no trailing blank lines. Diagnostics go to stderr.
#
# Output (stderr, full mode only):
#   After the Markdown, one line per numbered item, mapping the number the
#   human answers with back to the artifact:
#     REVIEW_ITEM_<n>=<finding id>       a realistic or edge-case finding
#                                        (review-update-status.sh --id)
#     REVIEW_ITEM_<n>=speculative:<key>  a speculative entry
#                                        (--speculative-key)
#     REVIEW_ITEM_<n>=handoff:<N>        an open handoff, N its 1-based place
#                                        in handoffs (--handoff-index, and a
#                                        review-add-round.sh ruling's index)
#
# Exit codes:
#   0  rendered
#   1  jq absent / stdin is not valid JSON / stdin is not a JSON object /
#      stdin is not shaped like a review artifact / no SHA-256 tool
#      (shasum, sha256sum, openssl) to key a speculative entry stored
#      without a key / the render or the item map failed
#   2  usage error (unknown/extra argument)
#
# Env:
#   TMPDIR — optional; selects the temp-file directory (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (cat, mktemp, rm) are assumed present, plus one of shasum,
#   sha256sum or openssl when a speculative entry is stored without a key.
#   Reads lib/review-aggregates.jq, lib/security-terms.jq and
#   lib/review-categories.json, resolved relative to this script (see the
#   REVIEW_LIB_DIR preamble below); depends on nothing else outside this
#   scripts/ directory.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

TAB=$(printf '\t')

# Locate the shared jq library RELATIVE TO THIS SCRIPT with parameter
# expansion alone: `${0%/*}` costs no subprocess and needs neither
# `readlink -f` nor `realpath` (non-POSIX, and absent from the test harness's
# minimal PATH toolbox). A symlinked $0 is consequently NOT resolved — the
# library must sit beside the path this script was invoked as. The `*)` branch
# is unreachable in practice (SKILL.md and the harness always invoke by
# absolute path) but exists so `set -u` can never see an unset REVIEW_LIB_DIR.
case "$0" in
	*/*) REVIEW_LIB_DIR=${0%/*}/lib ;;
	*)   REVIEW_LIB_DIR=lib ;;
esac
REVIEW_AGGREGATES_JQ=$REVIEW_LIB_DIR/review-aggregates.jq
REVIEW_SECURITY_TERMS_JQ=$REVIEW_LIB_DIR/security-terms.jq
REVIEW_CATEGORIES_JSON=$REVIEW_LIB_DIR/review-categories.json

# Every jq program that includes the shared library names it with a search
# path pinned to the library's absolute directory (JQ_AGGREGATES, below): the
# library travels as a module, never as program text, so no argument grows
# with it, and an unpinned lookup would search the process's working
# directory first, where a reviewed repository could plant a same-named
# module.

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG [--summary] [-h|--help]

The sole deterministic Markdown renderer for a flow-review durable artifact.
Reads one review-artifact JSON object on stdin, writes Markdown on stdout.

Options:
  --summary    Emit only the verdict + open counts by severity (the findings
               that count toward the verdict), plus, each only when nonzero:
               an "Awaiting your decision" line (an edge-case CRITICAL/HIGH
               awaiting confirmation, an escalated re-check you have not
               decided, a confirmed edge case whose re-check survived), the
               uncounted open edge-case
               and speculative counts, the re-checks on open items (an
               escalated one you have decided counted as decided), and the
               open handoffs. A cheap "is this blocking?" check.
  -h, --help   Show this help.

Full mode also writes one line per numbered item to stderr:
  REVIEW_ITEM_<n>=<finding id>         (realistic and edge-case findings;
                                        review-update-status.sh --id)
  REVIEW_ITEM_<n>=speculative:<key>    (--speculative-key)
  REVIEW_ITEM_<n>=handoff:<N>          (1-based place in handoffs;
                                        --handoff-index)

Exit codes:
  0  rendered
  1  jq absent / stdin not valid JSON / stdin not a review artifact / no
     SHA-256 tool for an unkeyed speculative entry / render failed
  2  usage error
EOF
}

# sha256_hex — print the SHA-256 of stdin as 64 lowercase hex digits, using
# the first installed of shasum, sha256sum or openssl. Returns 1 when none is
# installed or the output is not a digest — the caller fails closed. The
# same copy is in every flow-review script that keys speculative entries
# (self-contained scripts, no sourcing between siblings).
sha256_hex() {
	if command -v shasum >/dev/null 2>&1; then
		sha256_line=$(shasum -a 256) || return 1
		sha256_digest=${sha256_line%% *}
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256_line=$(sha256sum) || return 1
		sha256_digest=${sha256_line%% *}
	elif command -v openssl >/dev/null 2>&1; then
		sha256_line=$(openssl dgst -sha256) || return 1
		sha256_digest=${sha256_line##* }
	else
		return 1
	fi
	case "$sha256_digest" in
		''|*[!0-9a-f]*) return 1 ;;
		*) : ;;
	esac
	[ "${#sha256_digest}" -eq 64 ] || return 1
	printf '%s\n' "$sha256_digest"
}

# speculative_key_map INPUTS MAP — write to MAP the JSON object mapping each
# speculative key input in INPUTS (one per line) to its key, the first 12 hex
# digits of the input's SHA-256 (lib/review-aggregates.jq, section 2). The
# same copy is in every flow-review script that keys speculative entries.
speculative_key_map() {
	key_lines=""
	while IFS= read -r key_input; do
		# shellcheck disable=SC2310  # sha256_hex returns an explicit status at every step; set -e is not relied on inside it
		key_digest=$(printf '%s' "$key_input" | sha256_hex) || return 1
		key_lines=$key_lines$(printf '%.12s' "$key_digest")$TAB$key_input"
"
	done <"$1"
	printf '%s' "$key_lines" | jq -R -s '
		split("\n") | map(select(length > 0) | capture("\\A(?<key>[0-9a-f]{12})\\t(?<input>.*)\\z") | {(.input): .key})
		| add // {}' >"$2"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_SUMMARY=0

while [ $# -gt 0 ]; do
	case "$1" in
		--summary) OPT_SUMMARY=1 ;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        usage >&2; error "unknown option: $1"; exit 2 ;;
		*)         usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

if [ ! -r "$REVIEW_AGGREGATES_JQ" ] || [ ! -r "$REVIEW_SECURITY_TERMS_JQ" ] || [ ! -r "$REVIEW_CATEGORIES_JSON" ]; then
	error "cannot read the shared library: $REVIEW_AGGREGATES_JQ, $REVIEW_SECURITY_TERMS_JQ and $REVIEW_CATEGORIES_JSON (invoke this script by its absolute path)"
	exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup trap registered BEFORE mktemp runs, so a signal in the narrow
# window between process start and temp-file creation can never leave a
# stray file behind. mktemp (never a fixed name) + a cleanup trap on every
# exit path; INT/TERM trapped separately from EXIT so an interrupted run
# reports the conventional 130/143 rather than whatever the last command
# before the signal happened to return.
# ---------------------------------------------------------------------------
WORK_DIR=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/review-render-md.XXXXXX")
TMP_FILE=$WORK_DIR/artifact.json
KEY_INPUTS=$WORK_DIR/key-inputs
KEY_MAP=$WORK_DIR/key-map.json

cat >"$TMP_FILE"

if ! jq -e . "$TMP_FILE" >/dev/null 2>&1; then
	error "stdin is not valid JSON"
	exit 1
fi

INPUT_TYPE=$(jq -r 'type' "$TMP_FILE")
if [ "$INPUT_TYPE" != "object" ]; then
	error "stdin must be one review-artifact JSON object (got an array or scalar)"
	exit 1
fi

# ---------------------------------------------------------------------------
# Input-shape precondition, checked ONCE for both render paths. "Is a JSON
# object" is not enough: an unrelated object flows straight through the
# templates below and renders plausible-looking garbage instead of failing —
# `Verdict:  — open: null critical, …` for --summary, which is precisely the
# blocking check a caller is trusting. This is an ARTIFACT-shape gate, not a
# per-mode one: it asserts the required top-level fields regardless of which
# render follows (`.summary` and `.overall_verdict` included, even though
# both modes recompute them rather than reading them), so a wrong-shaped
# input is a loud, documented exit 1 on both paths.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_IS_ARTIFACT_SHAPED='
(.findings | type == "array")
and (.rounds | type == "array")
and (.summary | type == "object")
and (.overall_verdict | type == "string")
and (.repo | type == "string")
and (.created | type == "string")
and (.last_updated | type == "string")
'

if ! jq -e "$JQ_IS_ARTIFACT_SHAPED" "$TMP_FILE" >/dev/null 2>&1; then
	error "stdin is not shaped like a review artifact (expected string repo/created/last_updated/overall_verdict, object summary, array findings/rounds — see review-artifact.schema.json)"
	exit 1
fi

# The shared lib, which leads every program that uses it.
REVIEW_LIB_DIR_ABS=$(CDPATH='' cd -P -- "$REVIEW_LIB_DIR" && pwd -P) || {
	error "cannot resolve the shared library directory: $REVIEW_LIB_DIR"
	exit 1
}
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_AGGREGATES=$(jq -n -r --arg lib_dir "$REVIEW_LIB_DIR_ABS" \
	'"include \"review-aggregates\" {search: \($lib_dir | tojson)};"') || {
	error "failed to build the shared library include"
	exit 1
}
JQ_AGGREGATES="$JQ_AGGREGATES
"

# ---------------------------------------------------------------------------
# --summary: a cheap short-circuit, no findings/round-history rendering. The
# verdict and counts are RECOMPUTED from findings[] rather than read off the
# stored summary — see the header WHY block.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_SUMMARY="$JQ_AGGREGATES"'
summary(.findings) as $s
| edge_case_open_count(.findings) as $edge_cases
| decision_tally as $decisions
| (unpromoted_speculative_entries | length) as $speculative
| ([.handoffs // [] | .[] | select(is_open_handoff)] | length) as $open_handoffs
| "Verdict: " + verdict($s)
+ " — open: " + ($s.open.critical | tostring) + " critical"
+ ", "        + ($s.open.high     | tostring) + " high"
+ ", "        + ($s.open.medium   | tostring) + " medium"
+ ", "        + ($s.open.low      | tostring) + " low"
+ (if $decisions.total > 0
   then "\nAwaiting your decision: \($decisions.total) ("
        + ([ (select($decisions["edge-case"] > 0) | "\($decisions["edge-case"]) edge-case CRITICAL/HIGH counted until confirmed"),
             (select($decisions.escalated > 0) | "\($decisions.escalated) escalated re-check"),
             (select($decisions.survived > 0) | "\($decisions.survived) confirmed edge case whose re-check survived") ]
           | join(", ")) + ")"
   else "" end)
+ (if $edge_cases > 0 or $speculative > 0
   then "\nNot counted toward the verdict: \($edge_cases) open edge-case, \($speculative) speculative"
   else "" end)
+ (recheck_tally as $rechecks
   | if $rechecks.total > 0
     then "\nRe-check: \($rechecks.total)"
          + ([recheck_tally_keys[] as $key | select($rechecks[$key] > 0) | "\($rechecks[$key]) \($key)"]
             | if . == [] then "" else " (" + join(", ") + ")" end)
     else "" end)
+ (if $open_handoffs > 0 then "\nOpen handoffs: \($open_handoffs)" else "" end)
'

if [ "$OPT_SUMMARY" -eq 1 ]; then
	jq -r "$JQ_SUMMARY" "$TMP_FILE" || {
		error "failed to render the summary line"
		exit 1
	}
	exit 0
fi

# The key of every speculative entry stored without one, for the item map.
if ! jq -r "$JQ_AGGREGATES"'unkeyed_speculative_key_inputs' "$TMP_FILE" >"$KEY_INPUTS"; then
	error "failed to read the speculative entries"
	exit 1
fi
# shellcheck disable=SC2310  # speculative_key_map returns an explicit status at every step; set -e is not relied on inside it
speculative_key_map "$KEY_INPUTS" "$KEY_MAP" || {
	error "cannot compute the speculative keys (install shasum, sha256sum, or openssl)"
	exit 1
}

# ---------------------------------------------------------------------------
# Full mode: the layout in flow-review/SKILL.md §5c. Built as an array of
# SECTIONS joined by a blank line ("\n\n"), empty ones omitted except the
# title, Verdict, Summary, Reviewers and Files:
#
#   title · Verdict · Summary · Spec (only with a spec_ref) · Reviewers ·
#   Files · Realistic · Edge cases · Speculative · Open handoffs · Resolved ·
#   Handoffs ruled · Acknowledged · Round history
#
# The verdict leads so the human reads the outcome first; Spec sits with
# Reviewers and Files as a note on what was reviewed. Summary rows, in this
# order, count the OPEN items of each list rendered below it, with the
# severity split in CRITICAL→LOW order and zero severities left out:
#   Realistic / Edge cases / Speculative — only when nonzero; Speculative has
#     no severity split and leaves out an entry promoted to a finding.
#   Open handoffs — the handoffs not yet ruled. Only when nonzero.
#   Re-check — the open findings, speculative entries and open handoffs
#     carrying a re-check, split pending → survived → cleared → escalated →
#     decided (an escalated one the human has decided) → dismissed, zeros
#     left out. Only when nonzero.
#   Needs your decision — always shown: the open items that return to the
#     human (decision_tally) — an edge-case CRITICAL/HIGH awaiting
#     confirmation, an item whose re-check was escalated and not decided
#     since, a confirmed edge case whose re-check survived. Each is marked
#     **needs your decision**.
#   Resolved this round — RESOLVED findings whose addressed_in_round is the
#     latest round, the only per-finding record of when a fix was verified; a
#     RESOLVED finding without it is not counted. Only when nonzero and the
#     artifact has more than one round.
#
# Realistic / Edge cases / Speculative / Open handoffs are ONE continuously
# numbered list (1..N across all four), so the human can answer "fix 1-4,
# 6"; the first three are grouped by reviewer, reviewers ordered by their
# highest severity, findings CRITICAL first within a reviewer, ties kept in
# findings[] order; open handoffs follow in handoffs[] order, each naming
# the seat it came from and the seat it went to. No finding id is rendered;
# the stderr item map (see Output above) carries them. A speculative entry
# promoted to a finding is listed only as that finding.
#
# An item's head: a finding's severity, then a bold Security marker when it
# is under the security floor (from lens-security-reviewer, or in a security
# category), then **needs your decision** when it returns to the human; a
# speculative entry opens with the same two markers. Its sub-lines, in order:
#   realistic   Trigger, Relates to, Re-check, Also at.
#   edge case   Trigger and Why edge case (an edge case needing a decision,
#               or under the floor, shows both; another shows Why edge case,
#               else Trigger), then Proof: <proof> or Not proven[: <reason>]
#               (fail closed: no proof reads as not proven), Relates to,
#               Re-check, Also at.
#   speculative Real if: <real_if> when it has one, else Why speculative,
#               then exactly one of Proof: <proof> or Not proven, then
#               Relates to and Re-check.
#   handoff     Relates to, Re-check.
# A Resolved line shows its resolution_proof as a Proof sub-line; an
# Acknowledged line ends with " — <ack_reason>" when the human gave one; a
# ruled handoff its "<Ruling>: <proof>" line ("Waived — <reason>" when the
# human waived it), then its re-check. A re-check shows its proof, or for an
# escalated one its reason, in parentheses, then " — decided by you" once the
# human decided the escalated finding; an entry the human dismissed shows
# "Dismissed by you — <reason>" instead.
#
# A location code span holds the file NAME and line, never a "/": a terminal
# styles a code span holding "/" as a path, so names would otherwise render
# inconsistently. When files in the artifact share a name, each is followed
# by " · " and, as plain text, the nearest directory of its own that no other
# same-name file has (`SKILL.md:123` · flow-review), else the shortest
# trailing directory path that is unique, or "repo root" for a top-level
# file. The same label is used everywhere — Files, relates_to, handoffs and
# every file:line inside a proof included; Files is sorted by file name. The
# Spec line names the spec file the same way, followed by its whole
# directory so the human can open it.
#
# Rules interpolated values go through:
#   neutralize   — see the header WHY block. Deliberately does NOT coerce a
#                    non-string: a malformed artifact makes gsub fail loudly
#                    rather than rendering the word "null" into the
#                    document. Applied to every value.
#   escape_inline
#                — see the header WHY block. Applied to every value shown
#                    outside a code span (`display` is both rules). One
#                    left-to-right pass: an existing backslash escape and a
#                    complete code span pass through unchanged; a lone
#                    trailing backslash is doubled.
#   escape_emphasis
#                — backslash-escapes `*`, `_`, backtick and backslash in a
#                    value set between `**` markers or shown as a plain-text
#                    directory.
#   code_span    — wraps a value in a fence one backtick longer than the
#                    longest backtick run inside it.
#   defuse_block_marker
#                — see the header WHY block. A backslash escape is the
#                    spec mechanism; do NOT "simplify" it to prepending a
#                    space: CommonMark allows 1-3 spaces of indentation
#                    before every block marker, which is also why leading
#                    whitespace is trimmed first.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_RENDER_DEFS="$JQ_AGGREGATES"'
def neutralize:
  gsub("[\\x{0}-\\x{1F}\\x{7F}-\\x{9F}\\x{2028}\\x{2029}]"; " ")
  | gsub(forbidden_characters; "\ufffd");
def escape_inline:
  gsub("(?<escaped>\\\\.)|(?<span>(?<run>`+)(?!`).*?(?<!`)\\k<run>(?!`))|(?<stray>`+)|(?<backslash>\\\\)|(?<lt><)|(?<amp>&)|(?<link>\\]\\()|(?<image>!\\[)|(?<emphasis>[*_~])";
    if .escaped != null then .escaped
    elif .span != null then .span
    elif .stray != null then .stray | gsub("`"; "\\`")
    elif .backslash != null then "\\\\"
    elif .lt != null then "\\<"
    elif .amp != null then "\\&"
    elif .link != null then "\\]("
    elif .image != null then "!\\["
    else "\\" + .emphasis end);
def display: neutralize | escape_inline;
def escape_emphasis: gsub("(?<c>[*_`\\\\])"; "\\\(.c)");
def defuse_block_marker:
  sub("\\A[[:space:]]+"; "")
  | if test("\\A[-#>+*`~=_<[]") then "\\" + .
    else sub("\\A(?<digits>[0-9]+)(?<delim>[.)])"; "\(.digits)\\\(.delim)") end;
def bold: "**" + . + "**";
def code_span:
  ([scan("`+") | length] | max // 0) as $longest
  | if $longest == 0 then "`" + . + "`"
    else ("`" * ($longest + 1)) as $fence | $fence + " " + . + " " + $fence end;

# Title Case display name: lens seats drop the -reviewer suffix
# (lens-security-reviewer -> Lens Security), tech seats keep it
# (rust-reviewer -> Rust Reviewer). A name made only of hyphens falls back to
# the raw value.
def reviewer_name:
  neutralize
  | . as $raw
  | (if startswith("lens-") then sub("-reviewer\\z"; "") else . end)
  | split("-") | map(select(. != "") | (.[:1] | ascii_upcase) + .[1:]) | join(" ")
  | (if . == "" then $raw else . end)
  | escape_emphasis | escape_inline;

def verdict_word:
  {CHANGES_REQUIRED: "Changes required",
   APPROVED_WITH_FOLLOWUPS: "Approved with follow-ups",
   APPROVED: "Approved"}[.];

def status_word:
  (if type == "string"
   then {NEW: "New", OPEN: "Tracking", REGRESSED: "Regressed",
         RESOLVED: "Resolved", ACK: "Acknowledged"}[.]
   else null end) // display;

def tracked_suffix:
  if .tracked_status == "PENDING" then ""
  else " · " + (.tracked_status | neutralize | ascii_downcase | gsub("_"; " ") | escape_inline) end;

# ---- File names and locations ----
def split_location: neutralize | capture("\\A(?<file>.*?)(?<line>:[0-9][0-9-]*)?\\z");

def path_name: sub("\\A.*/"; "");
def path_directory: sub("/?[^/]*\\z"; "");
def path_directories: path_directory | split("/") | map(select(. != ""));

# Shortest trailing suffix of this path that no other path in $paths equals
# or ends with; the full path when every suffix collides.
def shortest_unique_suffix($paths):
  . as $path
  | (split("/")) as $segments
  | first(
      (range(1; ($segments | length) + 1) as $k
       | ($segments[-$k:] | join("/")) as $suffix
       | select(all($paths[]; . == $path or (. != $suffix and (endswith("/" + $suffix) | not))))
       | $suffix),
      $path);

# The directory that tells this path apart from $others (same file name):
# its nearest directory name found in none of them, else the shortest unique
# trailing directory path; "" for a file at the top.
def distinguishing_directory($others):
  path_directories as $own
  | ([$others[] | path_directories[]] | unique) as $taken
  | first(($own | reverse[] | select(. as $name | any($taken[]; . == $name) | not)),
          ($own | join("/") | shortest_unique_suffix([$others[] | path_directories | join("/")])));

# Every proof the artifact records: findings, speculative entries and
# handoffs, their re-checks included.
def artifact_proofs:
  ((.findings[] | .proof, .resolution_proof, (.recheck | objects | .proof)),
   (speculative_entries[] | .proof, (.recheck | objects | .proof)),
   (.handoffs // [] | .[] | .proof, (.recheck | objects | .proof)))
  | strings;

# {path: {name, directory}} for every file the artifact names, in a location,
# a relates_to or a proof; directory is null unless another file shares the
# name.
def file_labels:
  ([(.findings[] | .locations[], (.relates_to // empty)),
    (speculative_entries[] | .location, (.relates_to // empty)),
    (.handoffs // [] | .[] | .location, (.relates_to // empty))]
   | map(split_location.file)) as $location_files
  | ([artifact_proofs | neutralize | proof_locators[] | .file]) as $proof_files
  | ($location_files + $proof_files | unique) as $files
  | reduce $files[] as $path ({};
      ($path | path_name) as $name
      | [$files[] | select(. != $path and path_name == $name)] as $others
      | .[$path] = {name: $name,
                    directory: (if $others == [] then null
                                else $path | distinguishing_directory($others) end)});

def directory_note:
  if . == null then ""
  else " · " + (if . == "" then "repo root" else escape_emphasis | escape_inline end) end;

def file_label($labels): $labels[.] // {name: path_name, directory: null};
def labelled_file: (.name | code_span) + (.directory | directory_note);

def location_label($labels):
  split_location as $l
  | ($l.file | file_label($labels)) as $f
  | (($f.name + ($l.line // "")) | code_span) + ($f.directory | directory_note);

# A proof with every file:line locator shown as its location label and the
# text around them displayed.
def proof_display($labels):
  neutralize as $text
  | [match(file_line_locator_pattern; "g")
     | select(.captures[0].string | is_path_like_file)] as $locators
  | (reduce $locators[] as $locator ({shown: "", from: 0};
       .shown += ($text[.from:$locator.offset] | escape_inline)
                 + ($locator.string | location_label($labels))
       | .from = $locator.offset + $locator.length)) as $built
  | $built.shown + ($text[$built.from:] | escape_inline);

def spec_section:
  if .spec_ref == null then []
  else (.spec_ref | neutralize) as $spec
    | [ ("Spec:" | bold) + " " + ($spec | path_name | code_span)
        + ($spec | path_directory | if . == "" then "" else " · " + (escape_emphasis | escape_inline) end) ]
  end;

# ---- Numbered, reviewer-grouped lists ----
def severity_rank: severity_bucket | {critical: 0, high: 1, medium: 2, low: 3}[.];

# Input: entries in artifact order. Output: [{reviewer, items}] — reviewers
# by their best rank, then first appearance; items by rank, then appearance.
def reviewer_groups(rank):
  to_entries
  | map({position: .key, entry: .value, rank: (.value | rank)})
  | group_by(.entry.reviewer)
  | map({reviewer: .[0].entry.reviewer,
         best: (map(.rank) | min),
         first: (map(.position) | min),
         items: (sort_by(.rank, .position) | map(.entry))})
  | sort_by(.best, .first)
  | map({reviewer, items});

# The four numbered lists, in numbering order. An open handoff carries
# handoff_place, its 1-based place in handoffs, for the item map. A promoted
# speculative entry is listed only as its finding.
def review_lists:
  { realistic: ([.findings[] | select(is_open_finding and (is_edge_case_finding | not))]
                | reviewer_groups(.severity | severity_rank)),
    edge_cases: ([.findings[] | select(is_open_finding and is_edge_case_finding)]
                 | reviewer_groups(.severity | severity_rank)),
    speculative: (unpromoted_speculative_entries | reviewer_groups(0)),
    handoffs: (.handoffs // [] | to_entries | map(.value + {handoff_place: (.key + 1)})
               | map(select(is_open_handoff))) };

def group_count: map(.items | length) | add // 0;
'

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_FULL="$JQ_RENDER_DEFS"'
# One list item: "N. head" plus indented sub-bullets aligned under the head
# text. Each sub is {text, depth}; depth 1 nests under the previous sub.
def list_item($n; $head; $subs):
  ("\($n). ") as $marker
  | [$marker + $head]
    + ($subs | map((" " * (($marker | length) + 2 * .depth)) + "- " + .text))
  | join("\n");

def also_at_subs($labels):
  if (.locations | length) > 1
  then [{text: "Also at:", depth: 0}]
       + (.locations[1:] | map({text: location_label($labels), depth: 1}))
  else [] end;

def trigger_subs:
  if .trigger != null then [{text: ("Trigger: " + (.trigger | display)), depth: 0}] else [] end;

# An edge case without proof shows its reason on the Not proven line instead.
def realism_reason_subs:
  if .realism_reason != null and .proof != null
  then [{text: ("Why edge case: " + (.realism_reason | display)), depth: 0}] else [] end;

# The evidence of an edge case: its proof, else Not proven with $reason
# (null when it has none) — fail closed: no proof reads as not proven.
def evidence_subs($reason; $labels):
  if .proof != null then [{text: ("Proof: " + (.proof | proof_display($labels))), depth: 0}]
  else [{text: ("Not proven" + (if $reason != null then ": " + ($reason | display) else "" end)), depth: 0}] end;

def relates_to_subs($labels):
  if .relates_to != null then [{text: ("Relates to: " + (.relates_to | location_label($labels))), depth: 0}] else [] end;

def recheck_text($labels):
  if .status == "dismissed"
  then "Dismissed by you — " + (if .reason != null then .reason | display else "no reason recorded" end)
  else
    "Re-check: " + (.status | display)
    + (if .proof != null then " (" + (.proof | proof_display($labels)) + ")"
       elif .reason != null then " (" + (.reason | display) + ")"
       else "" end)
    + (if .decided == true then " — decided by you" else "" end)
  end;

def recheck_subs($labels):
  if .recheck == null then [] else [{text: (.recheck | recheck_text($labels)), depth: 0}] end;

def security_marker: "Security" | bold;
def decision_marker: if needs_decision then " · " + ("needs your decision" | bold) else "" end;

# A finding head: severity, then the Security and decision markers.
def finding_markers:
  (.severity | neutralize | escape_emphasis | escape_inline | bold)
  + (if is_security_concern then " · " + security_marker else "" end)
  + decision_marker;

def realistic_item($n; $labels):
  list_item($n;
    finding_markers
      + " · " + (.status | status_word)
      + " · " + (.locations[0] | location_label($labels)) + ": " + (.problem | display)
      + " → " + (.fix | display) + tracked_suffix;
    trigger_subs + relates_to_subs($labels) + recheck_subs($labels) + also_at_subs($labels));

# An edge case that needs a decision from the human, or is under the
# security floor, shows its trigger too: the human decides it by location
# and trigger.
def edge_case_item($n; $labels):
  (needs_decision or is_security_concern) as $shows_trigger
  | list_item($n;
      finding_markers
        + " · " + (.locations[0] | location_label($labels)) + ": " + (.problem | display)
        + tracked_suffix;
      (if $shows_trigger then trigger_subs + realism_reason_subs
       elif .realism_reason != null then realism_reason_subs
       else trigger_subs end)
        + evidence_subs(.realism_reason; $labels)
        + relates_to_subs($labels) + recheck_subs($labels) + also_at_subs($labels));

def speculative_item($n; $labels):
  list_item($n;
      (if is_security_concern then security_marker + " · " else "" end)
        + (if needs_decision then ("needs your decision" | bold) + " · " else "" end)
        + (.location | location_label($labels)) + ": " + (.concern | display);
      (if .real_if != null then [{text: ("Real if: " + (.real_if | display)), depth: 0}]
       else [{text: ("Why speculative: " + (.why_speculative | display)), depth: 0}] end)
        + (if .proof != null then [{text: ("Proof: " + (.proof | proof_display($labels))), depth: 0}]
           else [{text: "Not proven", depth: 0}] end)
        + relates_to_subs($labels) + recheck_subs($labels));

# A handoff: who passed the concern to which seat, where, and what; an open
# one that needs a decision from the human is marked between the seats and
# the location, as the other items are.
def handoff_head($labels; $marker):
  (.from | reviewer_name | bold) + " → " + (.to | reviewer_name | bold) + $marker
  + " · " + (.location | location_label($labels)) + ": " + (.concern | display);

def handoff_item($n; $labels):
  list_item($n; handoff_head($labels; decision_marker); relates_to_subs($labels) + recheck_subs($labels));

def handoff_ruling_word:
  {filed: "Filed", rejected: "Rejected", "out-of-scope": "Out of scope", waived: "Waived"}[.] // display;

# Input: reviewer groups. Each group is a bold reviewer line, a blank line,
# then its items numbered on from $start; render_item reads {n, entry}.
def numbered_groups($start; render_item):
  reduce .[] as $group ({next: $start, blocks: []};
    .next as $n
    | .blocks += [ ([($group.reviewer | reviewer_name | bold), ""]
                    + [$group.items | to_entries[] | {n: (.key + $n), entry: .value} | render_item])
                   | join("\n") ]
    | .next += ($group.items | length))
  | .blocks | join("\n\n");

def handoffs_section($handoffs; $start; $labels):
  if ($handoffs | length) == 0 then []
  else [ "### Open handoffs (\($handoffs | length))\n\n"
         + ($handoffs | to_entries | map(.key as $k | .value | handoff_item($start + $k; $labels)) | join("\n")) ] end;

def numbered_section($heading; $groups; $start; render_item):
  if ($groups | group_count) == 0 then []
  else [ ($heading | sub("<N>"; ($groups | group_count | tostring))) + "\n\n"
         + ($groups | numbered_groups($start; render_item)) ] end;

# ---- Closed findings, ruled handoffs and history ----
# A closed finding is one line, followed by " — <reason>" when it carries
# the field $reason_key names (the ack_reason the human gave); $proof_key
# names the field shown as its Proof sub-line when the finding carries it
# (a resolution_proof).
def closed_section($heading; $findings; text; $reason_key; $proof_key; $labels):
  if ($findings | length) == 0 then []
  else [ "\($heading) (\($findings | length))\n\n"
         + ($findings | map("- " + (.reviewer | reviewer_name | bold) + " · "
                            + (.locations[0] | location_label($labels)) + ": " + (text | display)
                            + (if $reason_key != null and .[$reason_key] != null
                               then " — " + (.[$reason_key] | display) else "" end)
                            + (if $proof_key != null and .[$proof_key] != null
                               then "\n  - Proof: " + (.[$proof_key] | proof_display($labels)) else "" end))
            | join("\n")) ] end;

# Each ruled handoff: its head line, then "<Ruling>: <proof>" ("Waived —
# <reason>" for a waiver by the human), then its re-check.
def ruled_handoffs_section($labels):
  [.handoffs // [] | .[] | select(is_open_handoff | not)] as $ruled
  | if ($ruled | length) == 0 then []
    else [ "### Handoffs ruled (\($ruled | length))\n\n"
           + ($ruled | map("- " + handoff_head($labels; "")
                           + "\n  - " + (.ruling | handoff_ruling_word)
                           + (if .ruling == "waived"
                              then " — " + (if .reason != null then .reason | display else "no reason recorded" end)
                              else ": " + (if .proof != null then .proof | proof_display($labels) else "no proof recorded" end) end)
                           + (recheck_subs($labels) | map("\n  - " + .text) | join("")))
              | join("\n")) ] end;

def round_history_section:
  [ "### Round history\n"
    + (.rounds | map("- Round " + (.round | tostring | display) + ": "
                     + (.reviewers | map(reviewer_name) | join(", ")))
       | join("\n")) ];

# "1 MEDIUM · 11 LOW": the count per severity bucket, zeros omitted.
def severity_split:
  reduce .[] as $finding ({critical: 0, high: 0, medium: 0, low: 0};
    .[$finding.severity | severity_bucket] += 1)
  | [ ("critical", "high", "medium", "low") as $bucket
      | select(.[$bucket] > 0) | "\(.[$bucket]) \($bucket | ascii_upcase)" ]
  | join(" · ");

def summary_section($rows):
  [ ("Summary:" | bold) + "\n" + ($rows | map("- " + .) | join("\n")) ];

def bulleted_block($label; $items):
  ($label | bold) + "\n" + (if $items == [] then "- none" else $items | map("- " + .) | join("\n") end);

def ordered_unique: reduce .[] as $item ([]; if any(.[]; . == $item) then . else . + [$item] end);

keyed_speculative_rounds($key_map_arr[0])
| file_labels as $labels
| review_lists as $lists
| $lists.realistic as $realistic
| $lists.edge_cases as $edge_cases
| $lists.speculative as $speculative
| $lists.handoffs as $open_handoffs
| ($realistic | group_count) as $realistic_count
| ($edge_cases | group_count) as $edge_case_count
| ($speculative | group_count) as $speculative_count
| (.rounds | if length == 0 then null else last | .round end) as $latest_round
| ([.findings[] | select(.status == "RESOLVED" and .addressed_in_round == $latest_round)]
   | length) as $resolved_this_round
| recheck_tally as $rechecks
| [ (select($realistic_count > 0)
     | "Realistic: \($realistic_count) (\([$realistic[].items[]] | severity_split))"),
    (select($edge_case_count > 0)
     | "Edge cases: \($edge_case_count) (\([$edge_cases[].items[]] | severity_split))"),
    (select($speculative_count > 0) | "Speculative: \($speculative_count)"),
    (select(($open_handoffs | length) > 0) | "Open handoffs: \($open_handoffs | length)"),
    (select($rechecks.total > 0)
     | "Re-check: \($rechecks.total)"
       + ([recheck_tally_keys[] as $key | select($rechecks[$key] > 0) | "\($rechecks[$key]) \($key)"]
          | if . == [] then "" else " (" + join(" · ") + ")" end)),
    "Needs your decision: \(decision_tally.total)",
    (select($resolved_this_round > 0 and (.rounds | length) > 1)
     | "Resolved this round: \($resolved_this_round)")
  ] as $summary_rows
| ( [ "## 🔍 Code Review · " + (.repo | display) + " · round "
        + (if $latest_round == null then "0" else $latest_round | tostring | display end),
      ("Verdict:" | bold) + " " + (verdict(summary(.findings)) | verdict_word) ]
    + summary_section($summary_rows)
    + spec_section
    + [ bulleted_block("Reviewers:"; [.rounds[].reviewers[]] | ordered_unique
                                      | map(reviewer_name | defuse_block_marker)),
        bulleted_block("Files:"; [($realistic, $edge_cases)[].items[].locations[] | split_location.file]
                                  | unique | map(file_label($labels))
                                  | sort_by((.name | ascii_downcase), .name, (.directory // "")) | map(labelled_file))
      ]
    + numbered_section("### Realistic (<N>)"; $realistic; 1;
                       .n as $n | .entry | realistic_item($n; $labels))
    + numbered_section("### Edge cases (<N>)"; $edge_cases;
                       $realistic_count + 1; .n as $n | .entry | edge_case_item($n; $labels))
    + numbered_section("### Speculative (<N>)"; $speculative;
                       $realistic_count + $edge_case_count + 1;
                       .n as $n | .entry | speculative_item($n; $labels))
    + handoffs_section($open_handoffs; $realistic_count + $edge_case_count + $speculative_count + 1; $labels)
    + closed_section("### Resolved"; [.findings[] | select(.status == "RESOLVED")]; .fix; null; "resolution_proof"; $labels)
    + ruled_handoffs_section($labels)
    + closed_section("### Acknowledged"; [.findings[] | select(.status == "ACK")]; .problem; "ack_reason"; null; $labels)
    + round_history_section
  ) | join("\n\n")
'

# The number-to-item map, in the same order review_lists numbers the items.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_ITEM_MAP="$JQ_RENDER_DEFS"'
keyed_speculative_rounds($key_map_arr[0])
| review_lists
| [ ((.realistic, .edge_cases)[].items[] | .id | neutralize),
    (.speculative[].items[] | "speculative:\(.key | neutralize)"),
    (.handoffs[] | "handoff:\(.handoff_place)") ]
| to_entries[]
| "REVIEW_ITEM_\(.key + 1)=\(.value)"
'

jq -r --slurpfile key_map_arr "$KEY_MAP" "$JQ_FULL" "$TMP_FILE" || {
	error "failed to render the review artifact (a field is missing or not a string — see review-artifact.schema.json)"
	exit 1
}
jq -r --slurpfile key_map_arr "$KEY_MAP" "$JQ_ITEM_MAP" "$TMP_FILE" >&2 || {
	error "failed to write the item map (a finding id or speculative key is missing or not a string — see review-artifact.schema.json)"
	exit 1
}
exit 0
