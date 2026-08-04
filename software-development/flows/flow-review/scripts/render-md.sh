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
# string containing $(...), backticks, or markdown-breaking characters is
# emitted as an inert value — it can neither execute nor alter the document
# structure.
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
#   trailing newline and no trailing blank lines. Diagnostics go to stderr.
#
# Exit codes:
#   0  rendered
#   1  jq absent / stdin is not valid JSON / stdin is not a JSON object
#   2  usage error (unknown/extra argument)
#
# Env:
#   None.
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (mktemp, rm, cat) are assumed present. Self-contained: sources
#   nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

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
# --summary: a cheap short-circuit, no findings/round-history rendering.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_SUMMARY='
"Verdict: " + .overall_verdict
+ " — open: " + (.summary.open.critical | tostring) + " critical"
+ ", "        + (.summary.open.high     | tostring) + " high"
+ ", "        + (.summary.open.medium   | tostring) + " medium"
+ ", "        + (.summary.open.low      | tostring) + " low"
'

if [ "$OPT_SUMMARY" -eq 1 ]; then
	jq -r "$JQ_SUMMARY" "$TMP_FILE"
	exit 0
fi

# ---------------------------------------------------------------------------
# Full mode: the exact template in flow-review/SKILL.md §4c, field-mapped
# 1:1 to the schema. Built as an array of SECTIONS joined by a blank line
# ("\n\n"); each section's own lines are joined by "\n" (no blank line
# inside a section). Findings render in findings[] order, one per section.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_FULL='
def metadata_block:
  [ "**Repo:** " + .repo ]
  + (if (.spec_ref != null) then [ "**Spec:** " + .spec_ref ] else [] end)
  + [ "**Started:** " + .created + " · **Last updated:** " + .last_updated,
      "**Round:** " + (.rounds | length | tostring) + " (of 3 max)",
      "**Verdict:** " + .overall_verdict
    ]
  | join("\n");
def round_history_block:
  ( [ "## Round history" ]
    + (.rounds | map("- Round " + (.round | tostring) + ": " + (.reviewers | join(", "))))
  ) | join("\n");
def finding_block($f):
  [ "### " + $f.id + " — " + $f.severity,
    "**Tracked status:** " + ($f.tracked_status | ascii_downcase)
      + " · **Finding status:** " + ($f.status | ascii_downcase),
    "**Reviewer:** " + $f.reviewer,
    "**File:** " + ($f.locations[0]),
    "",
    $f.problem,
    "→ Fix: " + $f.fix
  ] | join("\n");
( [ "# Review: " + .repo, metadata_block, round_history_block, "## Findings" ]
  + [ .findings[] | finding_block(.) ]
) | join("\n\n")
'

jq -r "$JQ_FULL" "$TMP_FILE"
exit 0
