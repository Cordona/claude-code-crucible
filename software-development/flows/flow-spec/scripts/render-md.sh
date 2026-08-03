#!/usr/bin/env sh
#
# render-md.sh — the SOLE deterministic Markdown renderer for a flow-spec
#                document. Reads ONE spec-document JSON object on stdin,
#                writes structured Markdown on stdout. No mutation, no
#                network, no lock — a pure transform, byte-identical on
#                macOS and Linux.
#
# WHY a dedicated renderer (not inline agent prose): the spec every parallel
# `flow-implementation` pair is briefed against, and the gate the human
# approves, must be built from what is ACTUALLY in the JSON artifact,
# rendered the same way every time — not re-phrased per turn by an LLM. This
# implements the exact template specified in flow-spec/SKILL.md §4,
# field-mapped 1:1 to spec-document.schema.json.
#
# WHY no lock (unlike the GTD inbox scripts): this is a pure read-only
# transform of a single already-written document, never a writer of
# anything — there is nothing to mutually exclude.
#
# Usage:
#   render-md.sh [-h|--help]
#
# Input (stdin):
#   A single spec-document JSON object (as produced by spec-create.sh /
#   spec-approve.sh), conforming to spec-document.schema.json.
#
# Output (stdout):
#   Deterministic Markdown, emitted as LIVE text (never fenced) with a single
#   trailing newline and no trailing blank lines. Diagnostics go to stderr.
#
#   Rendering rules (per flow-spec/SKILL.md §4):
#     - "Approved by" line: rendered only when both approved_by AND
#       approved_at are present (i.e. never while status is "draft").
#     - "Decision log": the literal line
#       "(none — no flow-decision panel ran for this spec)" when
#       decision_log is empty; otherwise one line per entry:
#       "**<fork>:** <decision> — <why>".
#     - Interface contract: one "### <repo> (<tech>)" subheading per
#       interface_contracts[] entry, tech looked up by matching repo
#       against repos_in_scope; an empty exposes/consumes list renders as
#       "(none)" rather than a dangling empty sub-list.
#     - non_goals/constraints/open_questions: the WHOLE section (heading +
#       body) is omitted when the key is absent from the input entirely.
#       goal/interface_contracts/repos_in_scope are always required by the
#       schema, so always rendered.
#
# Exit codes:
#   0  rendered
#   1  jq absent / stdin is not valid JSON / stdin is not a single JSON
#      object
#   2  usage error (unknown option or unexpected argument)
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
Usage: $PROG [-h|--help]

Read ONE spec-document JSON object on stdin, write the flow-spec §4
Markdown template on stdout.

Options:
  -h, --help   Show this help.

Exit codes:
  0  rendered
  1  jq absent / stdin not valid JSON / stdin not a single JSON object
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing — no options besides -h/--help.
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
	case "$1" in
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

TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/spec-render-md.XXXXXX")

cat >"$TMP_FILE"

if ! jq -e . "$TMP_FILE" >/dev/null 2>&1; then
	error "stdin is not valid JSON"
	exit 1
fi

if [ "$(jq -r 'type' "$TMP_FILE")" != "object" ]; then
	error "stdin must be a single spec-document JSON object"
	exit 1
fi

# ---------------------------------------------------------------------------
# The renderer. Every field reaches the output ONLY as a jq value inside
# this STATIC jq program — nothing is ever concatenated into the program
# text or handed to a shell.
#
# has_val:      field-present-and-non-null guard (same idiom as the GTD
#               inbox render-md.sh).
# bullet_list:  renders a labelled sub-list; an empty array renders
#               "- Label: (none)" instead of a dangling empty sub-list.
# interface_section: one "### repo (tech)" subheading per
#               interface_contracts[] entry; tech is looked up by matching
#               repo against repos_in_scope.
# optional_section: renders "## Heading\n<body>" only when the given key is
#               present in the input at all; omits the WHOLE section
#               (heading included) when the key is absent, per has_val.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: $r/$k/etc. below are jq syntax, not shell expansions
JQ_RENDER='
def has_val($k): has($k) and (.[$k] != null);

def repos_line:
  (.repos_in_scope | map(.repo + " (" + .tech + ")") | join(" · "));

def bullet_list($label; $items):
  if ($items | length) == 0
  then "- " + $label + ": (none)"
  else "- " + $label + ":\n" + ($items | map("  - " + .) | join("\n"))
  end;

def interface_section:
  (.repos_in_scope | map({(.repo): .tech}) | add // {}) as $tech_by_repo
  | (.interface_contracts
     | map(
         "### " + .repo + " (" + ($tech_by_repo[.repo] // "") + ")\n"
         + bullet_list("Exposes"; .exposes) + "\n"
         + bullet_list("Consumes"; .consumes)
       )
     | join("\n\n"));

def decision_log_section:
  if (.decision_log | length) == 0
  then "(none — no flow-decision panel ran for this spec)"
  else (.decision_log | map("**" + .fork + ":** " + .decision + " — " + .why) | join("\n"))
  end;

def optional_section($key; $heading):
  if has_val($key)
  then "\n\n## " + $heading + "\n"
       + (if (.[$key] | length) == 0
          then "(none)"
          else (.[$key] | map("- " + .) | join("\n"))
          end)
  else ""
  end;

def header_block:
  "# Spec: " + .title + "\n\n"
  + "**Status:** " + .status + "\n"
  + "**Created:** " + .created + "\n"
  + (if has_val("approved_by") and has_val("approved_at")
     then "**Approved by:** " + .approved_by + ", " + .approved_at + "\n"
     else "" end)
  + "**Repos in scope:** " + repos_line;

header_block
+ "\n\n## Goal\n" + .goal
+ optional_section("non_goals"; "Non-goals")
+ "\n\n## Interface contract\n\n" + interface_section
+ optional_section("constraints"; "Constraints")
+ "\n\n## Decision log\n" + decision_log_section
+ optional_section("open_questions"; "Open questions")
'

jq -r "$JQ_RENDER" "$TMP_FILE"

exit 0
