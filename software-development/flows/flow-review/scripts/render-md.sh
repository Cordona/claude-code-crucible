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
# describes an arbitrary, possibly-adversarial target repo, and a string
# carrying embedded newlines could otherwise forge document STRUCTURE — a
# fabricated `### FAKE-ID — CRITICAL` block or a bogus `**Verdict:**` line
# that reads as the renderer's own output. Every interpolated string is
# therefore passed through `neutralize` (control characters, newlines
# included, collapsed to spaces) before it reaches the template, and the one
# value emitted at column 0 with no prefix of its own — a finding's `problem`
# — additionally goes through `defuse_block_marker`.
#
# What is guaranteed, precisely: an artifact value can never emit a NEW line,
# and a leading Markdown block marker on the `problem` line — the one value
# emitted at column 0 — is backslash-escaped. That is NOT a claim that the
# text renders inertly: INLINE Markdown (emphasis, a link, a mid-line
# backtick span) still renders as Markdown, by design. This is a human-facing
# document, not a sanitizer; the guarantee is about document STRUCTURE.
#
# WHY --summary recomputes the verdict and counts from findings[] instead of
# printing the stored summary/overall_verdict: --summary is the cheap "is this
# blocking?" gate, so the one thing it must never do is inherit a stale or
# forged aggregate. Full mode still renders the stored overall_verdict — it is
# a human-facing transcript of the document as persisted, and a disagreement
# between the two modes is itself a signal worth seeing.
#
# Usage:
#   render-md.sh [--summary] [-h|--help]
#
#     --summary    Emit ONLY the verdict + open counts by severity — no
#                    findings, no round history. A cheap short-circuit for a
#                    "is this blocking?" check that never requires reading
#                    the full render.
#     -h, --help   Show this help.
#
# Input (stdin):
#   ONE review-artifact JSON object (per review-artifact.schema.json).
#
# Output (stdout):
#   Deterministic Markdown, emitted as LIVE text (never fenced) with a single
#   trailing newline and no trailing blank lines. Lines inside the metadata
#   and finding blocks end with a CommonMark hard line break (two trailing
#   spaces) so each renders on its own line instead of collapsing into one
#   wrapped paragraph. Diagnostics go to stderr.
#
# Exit codes:
#   0  rendered
#   1  jq absent / stdin is not valid JSON / stdin is not a JSON object /
#      stdin is not shaped like a review artifact / the render itself failed
#   2  usage error (unknown/extra argument)
#
# Env:
#   TMPDIR — optional; selects the temp-file directory (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (cat, mktemp, rm) are assumed present. Reads its verdict
#   arithmetic from lib/review-aggregates.jq, resolved relative to this script
#   (see the REVIEW_LIB_DIR preamble below); depends on nothing else outside
#   this scripts/ directory.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

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
  --summary    Emit only the verdict + open counts by severity.
  -h, --help   Show this help.

Exit codes:
  0  rendered
  1  jq absent / stdin not valid JSON / stdin not a JSON object
  2  usage error
EOF
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

if [ ! -r "$REVIEW_AGGREGATES_JQ" ]; then
	error "cannot read the shared jq library: $REVIEW_AGGREGATES_JQ (invoke this script by its absolute path)"
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
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$TMP_FILE" ] || rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/review-render-md.XXXXXX")

cat >"$TMP_FILE"

if ! jq -e . "$TMP_FILE" >/dev/null 2>&1; then
	error "stdin is not valid JSON"
	exit 1
fi

if [ "$(jq -r 'type' "$TMP_FILE")" != "object" ]; then
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
# render follows (`.summary` included, even though --summary now recomputes
# its numbers rather than reading them), so a wrong-shaped input is a loud,
# documented exit 1 on both paths.
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

JQ_AGGREGATES=$(cat "$REVIEW_AGGREGATES_JQ")

# ---------------------------------------------------------------------------
# --summary: a cheap short-circuit, no findings/round-history rendering. The
# verdict and counts are RECOMPUTED from findings[] rather than read off the
# stored summary — see the header WHY block.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_SUMMARY="$JQ_AGGREGATES"'
summary(.findings) as $s
| "Verdict: " + verdict($s)
+ " — open: " + ($s.open.critical | tostring) + " critical"
+ ", "        + ($s.open.high     | tostring) + " high"
+ ", "        + ($s.open.medium   | tostring) + " medium"
+ ", "        + ($s.open.low      | tostring) + " low"
'

if [ "$OPT_SUMMARY" -eq 1 ]; then
	jq -r "$JQ_SUMMARY" "$TMP_FILE" || {
		error "failed to render the summary line"
		exit 1
	}
	exit 0
fi

# ---------------------------------------------------------------------------
# Full mode: the exact template in flow-review/SKILL.md §5c, field-mapped
# 1:1 to the schema. Built as an array of SECTIONS joined by a blank line
# ("\n\n"); each section's own lines are joined by "\n" (no blank line
# inside a section). Findings render in findings[] order, one per section.
#
# Three rules interpolated values go through:
#   neutralize   — strips control characters (see the header WHY block); the
#                    reason `problem`/`fix` cannot emit a second line at all.
#                    Deliberately does NOT coerce a non-string: a malformed
#                    artifact makes gsub fail loudly rather than rendering the
#                    word "null" into the document. Applied to every value.
#   defuse_block_marker
#                — escapes a leading Markdown block marker so it cannot open a
#                    heading/quote/list/fence/thematic-break/HTML block, or a
#                    link reference definition (`[a]: url` — a block construct
#                    that renders as NOTHING, silently suppressing the text,
#                    and whose label would stay live for the whole document).
#                    Applied to the ONE value emitted at column 0 with no
#                    prefix of its own — a finding's `problem`; every other
#                    interpolated value already sits behind literal template
#                    text and so can never start a line.
#
#                    Do NOT "simplify" this to prepending a space: CommonMark
#                    permits 1-3 spaces of indentation before every one of
#                    those constructs (and reads 4+ as an indented code
#                    block), so padding defuses nothing. A backslash escape is
#                    the spec's own mechanism; the leading-whitespace trim
#                    denies the marker the indentation the escape would
#                    otherwise sit behind. Both verified against a CommonMark
#                    reference implementation.
#   hard_break   — appends CommonMark's two-space hard line break to any line
#                    whose successor must start a NEW line. Without it
#                    Repo/Spec/Started/Round/Verdict render as one wrapped
#                    paragraph. Not applied to a heading, to a line followed
#                    by a blank one, or to a block's last line, none of which
#                    need it.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_FULL='
def neutralize: gsub("[[:cntrl:]]"; " ");
def defuse_block_marker:
  sub("\\A[[:space:]]+"; "")
  | if test("\\A[-#>+*`~=_<[]") then "\\" + .
    else sub("\\A(?<digits>[0-9]+)(?<delim>[.)])"; "\(.digits)\\\(.delim)") end;
def hard_break($line): $line + "  ";
def metadata_block:
  [ hard_break("**Repo:** " + (.repo | neutralize)) ]
  + (if (.spec_ref != null) then [ hard_break("**Spec:** " + (.spec_ref | neutralize)) ] else [] end)
  + [ hard_break("**Started:** " + (.created | neutralize) + " · **Last updated:** " + (.last_updated | neutralize)),
      hard_break("**Round:** " + (.rounds | length | tostring)),
      "**Verdict:** " + (.overall_verdict | neutralize)
    ]
  | join("\n");
def round_history_block:
  ( [ "## Round history" ]
    + (.rounds | map("- Round " + (.round | tostring | neutralize) + ": "
                     + (.reviewers | map(neutralize) | join(", "))))
  ) | join("\n");
def finding_block($f):
  [ "### " + ($f.id | neutralize) + " — " + ($f.severity | neutralize),
    hard_break("**Tracked status:** " + ($f.tracked_status | neutralize | ascii_downcase)
      + " · **Finding status:** " + ($f.status | neutralize | ascii_downcase)),
    hard_break("**Reviewer:** " + ($f.reviewer | neutralize)),
    "**File:** " + ($f.locations[0] | neutralize),
    "",
    hard_break($f.problem | neutralize | defuse_block_marker),
    "→ Fix: " + ($f.fix | neutralize)
  ] | join("\n");
( [ "# Review: " + (.repo | neutralize), metadata_block, round_history_block, "## Findings" ]
  + [ .findings[] | finding_block(.) ]
) | join("\n\n")
'

jq -r "$JQ_FULL" "$TMP_FILE" || {
	error "failed to render the review artifact (a field is missing or not a string — see review-artifact.schema.json)"
	exit 1
}
exit 0
