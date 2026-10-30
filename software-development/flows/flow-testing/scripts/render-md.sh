#!/usr/bin/env sh
#
# render-md.sh — the SOLE deterministic Markdown renderer for a flow-testing
#                test plan. Reads ONE test-plan JSON object on stdin, writes
#                the plan's Markdown on stdout. No mutation, no network, no
#                lock — a pure transform, byte-identical on macOS and Linux.
#
# WHY a dedicated renderer (not inline agent prose): the plan the human
# approves or trims must be built from what is ACTUALLY in the JSON, rendered
# the same way every time — never re-phrased per turn by an LLM. The human
# only ever sees this script's output (flow-testing §3d).
#
# WHY validate before rendering (fail closed): the renderer owns all
# punctuation and structure, so it relies on the validator's guarantees — no
# trailing periods, no backticks inside code spans, every guarded behavior
# id resolvable, every level-specific field present. Rendering an invalid
# plan would silently print a garbled or misleading plan, so an invalid one
# is refused, naming each failing field.
#
# WHY every string still goes through `neutralize`: defense in depth. The
# validator already rejects control, line-separator and invisible format
# characters, but the guarantee that no plan value can start a NEW line — and
# so forge a heading or bullet that reads as the renderer's own — must not
# depend on one upstream check. Every interpolated value sits behind literal
# template text on its line (`- **`, `  - Why: `, …), so none can open a
# Markdown block construct. Inline constructs that would make the plan render
# differently than it reads — HTML tags and comments, links and images,
# whitespace padding — are REJECTED by the validator rather than escaped here,
# since an escape would show the human stray backslashes. What remains is
# emphasis punctuation and code spans: free text is shown literally (see
# below), so only a code span stays live.
#
# WHY a digest of the INPUT bytes on stderr: the human approves what this
# script showed them, and the plan file stays writable until approval.
# TEST_PLAN_SHA256 lets test-plan-approve.sh (--expect-sha256) refuse a plan
# whose bytes changed between this render and the approval. It goes to stderr
# so stdout stays exactly the Markdown the human sees.
#
# WHY a sidecar re-check is matched by digest: each re-check is shown beside
# the not_tested entry whose digest equals its entry_sha256 (the entry as
# `jq -S -c` prints it, waiver keys removed), so a record for an entry since
# changed is not shown. The sidecar is read only for display;
# TEST_PLAN_SHA256 stays that of the plan bytes on stdin.
#
# WHY a plan amended after approval renders against a baseline (the change
# view): its tests may already be written, so showing every test as proposed
# misstates the change, and the human re-approving it needs only what moved.
# When the plan carries approved_baseline (test-plan-amend.sh records it from
# the approved plan it amends), or --baseline names the approved plan (for a
# plan amended without one), the plan is fingerprinted as approved_baseline
# is (lib/test-plan-validate.jq: each test, existing-test entry, Files and
# Fixtures entry, builds_on line, behavior and not_tested entry, and a digest
# each of run, existing_tests, the reviewer lines and the rejected
# proposals) and compared with it by name and digest. Both paths build the
# same fingerprint, so they render the same bytes. The change view is
# compact: it shows in full only what changed since approval and names the
# rest in one closing line, so it can be relayed whole. A baseline recorded
# without section fingerprints compares tests and existing-test entries only
# and shows the other sections whole. Both baselines at once is refused
# rather than one silently preferred. Without a baseline the plan is shown
# whole, with no change view.
#
# WHY free text and directories are escaped: emphasis left live lets text
# such as "__lmc ... __lmc" or "a * b" render as bold or italic, which
# garbles what the human reads. Every render shows each free-text value
# literally — Markdown punctuation outside a code span backslash-escaped —
# while a code span stays live. A directory shown as plain text is escaped
# the same way, a backslash included, so a builds_on path such as
# tests\unit/helper.ps1 shows its backslash. Plain text without such
# punctuation renders exactly as it is written.
#
# Usage: see --help.
#
# Input (stdin):
#   ONE test-plan JSON object (per test-plan.schema.json), as produced by
#   test-plan-create.sh / test-plan-challenge.sh / test-plan-amend.sh /
#   test-plan-approve.sh.
#
# Output (stdout):
#   Deterministic Markdown, emitted as LIVE text (never fenced) with a single
#   trailing newline and no trailing blank lines.
#
# Output (stderr):
#   On success, after the Markdown, the machine-parseable key:
#     TEST_PLAN_SHA256=<64 lowercase hex: SHA-256 of the exact stdin bytes>
#   Diagnostics also go to stderr.
#
#   Rendering rules (the layout the human approves at flow-testing §3d):
#     - A path is shown as its file name in a code span, never with a "/"
#       inside the span. Its directory follows as plain text after " · " when
#       the file name alone is ambiguous (the shortest directory suffix no
#       other path shares) and, in full, for a new file and a file whose test
#       is deleted. A file at the repo root shows "(repo root)" there.
#     - A field holding several items is a bulleted list under a bold label,
#       "- none" when empty. Counts are carried by the Behaviors, test-level
#       (Proposed end-to-end / integration / unit, or End-to-end /
#       Integration / Unit against a baseline), Removed since approval,
#       Rejected and Not tested headings and by the Reused / To repair / To
#       delete labels; no other heading or label has one. Against a
#       baseline, a test-level heading, an existing-tests label and, in the
#       compact view, the Behaviors and Not tested headings follow their
#       count with " · <k> new, <k> renamed, <k> changed" (zero parts
#       omitted, nothing when none).
#     - Header without a baseline: the test summary line (tests, then the
#       non-zero end-to-end / integration / unit / optional unit counts,
#       approx_lines, and the rejected count once challenged), Files (new
#       files and inline unit tests marked), Fixtures (the inputs tests read
#       and every new fixture file, a golden included), Builds on, Run.
#     - Header against a baseline: "**Change since approval (<date>):**"
#       over a list — the non-zero new / renamed / changed / removed /
#       unchanged test counts, the new / changed / removed reused, repair
#       and delete entries, then "<k> other changes (see Amendments since
#       approval)" for the later amendments naming neither a test nor
#       existing_tests — then "**<N> tests in plan:**" over a list of the
#       non-zero level counts, approx_lines and the rejected count when
#       non-zero. In the compact view Files, Fixtures and Builds on are
#       shown only with their new and changed entries, each tagged, and only
#       when they have one; Run only when changed, as "**Run (changed):**".
#     - A renamed test: an added amendment since approval whose renamed_from
#       names a test the baseline held and the plan no longer does, adding
#       a test new against the baseline. It is counted as renamed, its item
#       opens with **Renamed** (was `<old name>`) · , and the old name is
#       not listed as removed. Without renamed_from a rename reads as one
#       new and one removed test: the removed and added amendments it is
#       recorded as carry no other tie the renderer can trust.
#     - "### Behaviors to guard (B)": every behavior; in the compact view
#       only the new and changed ones, tagged, and the section only when
#       there is one.
#     - "### Existing tests": "- None: <none_reason>", or Reused / To repair /
#       To delete lists; every repair and delete entry names its file.
#       Against a baseline a new or changed entry opens with **New** ·  or
#       **Changed** · . In the compact view the section is omitted when
#       existing_tests is unchanged, and a list is shown only with its new
#       and changed entries.
#     - "### Proposed end-to-end tests", "### Proposed integration tests"
#       (only when the plan has one) and "### Proposed unit tests": one
#       numbered item per test (n, name, guards, a unit test's kind), then
#       Golden and Input (path and source) when present, Why, Why not e2e
#       for an integration or unit test, Fails if; or "- None proposed:
#       <reason>". The number shown is always n, which runs on across the
#       three sections. Against a baseline the sections are "### End-to-end
#       tests", "### Integration tests" and "### Unit tests": only new,
#       renamed and changed tests are shown in full, their item line opening
#       with their tag, then one "- Unchanged since approval: tests <n>, <n>"
#       line; a level with no test reads "- None: <reason>".
#     - "### Removed since approval (R)", only against a baseline that holds
#       an entry the plan no longer does: each by name, with "test", "reused
#       test", "repair" or "deletion", and in the compact view also "file in
#       <dir>", "fixture in <dir>", "builds-on line" (or "builds-on path in
#       <dir>"), "behavior" and "not-tested entry". A builds_on line is
#       named by its own text, so an edited line reads as a new one and a
#       removed one.
#     - "### Reviewer · Lens Test Quality" and "### Rejected (R)" are omitted
#       while status is draft, and in the compact view each when unchanged
#       since approval. Reviewer: the approved test numbers, one line per
#       change, then the no-end-to-end agreement. Rejected (always shown
#       once challenged): numbered on from the last test, so the human can
#       name one to restore; a restored test is listed with the tests.
#     - "### Amendments" is omitted when the plan carries none. Against a
#       baseline it is "### Amendments since approval": only the amendments
#       after the approved plan's count (approved_baseline.amendments, or the
#       --baseline plan's amendments), "- none" when there are none, then
#       "- **Before approval:** <k> amendments, not listed" when k > 0. A change or
#       amendment line names its test (by number while listed) else its
#       field — except a merge, which is told by its item and shown once
#       however many old tests it records. Against a baseline an item that
#       already names its test (it opens "test <that number>" or holds the
#       test name) is not given the label again.
#     - "### Not tested (K)": the entries numbered on after the tests and
#       the rejected proposals, so no two items of the plan share a number —
#       the number test-plan-amend.sh --waive-not-tested and
#       test-plan-recheck.sh --not-tested take — each "what: reason" with an
#       Accepting sub-line, then "Proof: <proof>", else "Not proven" (fail
#       closed: an entry naming neither proof nor unproven reads as not
#       proven), then for an entry that needs the human waiver (a required
#       test category, or unproven) "Waived by you: <waiver_reason>" or
#       "Needs your waiver: <category> is a required test category" /
#       "Needs your waiver: not proven", or for an entry without a category
#       "Legacy entry — not judged", and "Re-check: <status> (<proof or
#       reason>)" for each sidecar re-check (--recheck-file; a pending one
#       "Re-check: pending", as flow-review's render shows it; the human's
#       dismissal of an escalated one "Kept untested by you — <reason>");
#       an entry whose re-check escalated it to the human and that the human
#       has not dismissed opens with **needs your decision**, as
#       flow-review's render marks an escalated item; "- none" when empty.
#       In the compact view only the entries new or changed since approval
#       (tagged), still waiting on the human (a waiver needed and not given,
#       or no category) or with a re-check shown are listed, each under its
#       full-render number, and the section only when one is.
#     - The compact view ends with "**Unchanged since approval, not
#       shown:**" naming each section it left out as unchanged (files,
#       fixtures, builds on, run, behaviors, existing tests, reviewer,
#       rejected) and "<k> not-tested entries" for those it did not list.
#     - Free text and plain-text directories are shown literally: Markdown
#       punctuation (a backslash included) outside a code span is
#       backslash-escaped.
#     - Not shown (kept in the JSON): full paths (but a new or deleted
#       file's directory), change.under_test, a new file's justification,
#       reused / approved reasons, a rejected proposal's why and file, the
#       baseline digests (only the delta they give is shown).
#
# Exit codes:
#   0  rendered
#   1  jq absent / shared jq library unreadable / stdin is not valid JSON /
#      stdin is not exactly one JSON document / the plan fails validation
#      (each failing field is named on stderr) / the --recheck-file is not
#      valid JSON or not a sidecar of this plan / the --baseline is not one
#      valid JSON document, fails validation, is not approved, or is another
#      plan / no SHA-256 tool (shasum, sha256sum, openssl) is installed / an
#      entry digest could not be taken / the render itself failed
#   2  usage error (unknown option or unexpected argument, an unreadable
#      --recheck-file or --baseline, --baseline for a plan that carries
#      approved_baseline)
#
# Env:
#   TMPDIR — optional; selects the temp-file directory (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (awk, cat, mktemp, rm) are assumed present, plus one of shasum,
#   sha256sum or openssl for the digests (fails closed when none is). Reads
#   its validator from lib/test-plan-validate.jq
#   (with security-terms.jq and review-categories.json from the sibling
#   flow-review skill's scripts/lib), resolved relative to this script
#   (see the TEST_PLAN_LIB_DIR preamble below); depends on nothing else
#   outside this scripts/ directory and that one.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

# Locate the shared jq library RELATIVE TO THIS SCRIPT with parameter
# expansion alone (no readlink -f/realpath — non-POSIX). A symlinked $0 is
# NOT resolved: the library must sit beside the path this script was invoked
# as. The security matcher and the category vocabulary are flow-review's,
# read from the flow-review skill beside this one (flows/ in the repo,
# skills/ when deployed); the kernel resolves the `..` through a symlinked
# skill directory, so a skill linked into skills/ still finds its sibling.
# The `*)` branch keeps `set -u` from ever seeing an unset variable.
case "$0" in
	*/*) TEST_PLAN_SCRIPTS_DIR=${0%/*} ;;
	*)   TEST_PLAN_SCRIPTS_DIR=. ;;
esac
TEST_PLAN_LIB_DIR=$TEST_PLAN_SCRIPTS_DIR/lib
REVIEW_LIB_DIR=$TEST_PLAN_SCRIPTS_DIR/../../flow-review/scripts/lib
TEST_PLAN_VALIDATE_JQ=$TEST_PLAN_LIB_DIR/test-plan-validate.jq
TEST_PLAN_SECURITY_TERMS_JQ=$REVIEW_LIB_DIR/security-terms.jq
TEST_PLAN_CATEGORIES_JSON=$REVIEW_LIB_DIR/review-categories.json

# Every jq program that includes the library names it with a search path
# pinned to the library's absolute directory (JQ_VALIDATE, below), and the
# library reaches flow-review's by a path relative to its own directory: the
# libraries travel as modules, never as program text, so no argument grows
# with them, and an unpinned lookup would search the process's working
# directory first, where the repository under test could plant a same-named
# module.

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG [--recheck-file PATH] [--baseline PATH] [-h|--help]

The sole deterministic Markdown renderer for a flow-testing test plan.
Reads one test-plan JSON object on stdin, validates it, writes Markdown on
stdout.

Options:
  --recheck-file PATH  The plan's <id>.recheck.json sidecar
                         (test-plan-recheck.sh): each re-check is shown
                         beside the not_tested entry it re-checked, matched
                         by the entry's digest, so a record for an entry
                         since changed is not shown.
  --baseline PATH      The plan as it was approved (an earlier copy of this
                         plan's JSON, status approved): the render shows
                         what changed since then. For a plan amended
                         without approved_baseline; refused when the plan
                         carries one, which is used instead.
  -h, --help           Show this help.

On success, also prints on stderr:
  TEST_PLAN_SHA256=<SHA-256 of the stdin bytes>  (pass to test-plan-approve.sh)

Exit codes:
  0  rendered
  1  jq absent / stdin not valid JSON or not one document / plan invalid /
     --recheck-file not this plan's sidecar / --baseline invalid, not
     approved or another plan / no SHA-256 tool
  2  usage error (bad option, unreadable --recheck-file or --baseline,
     --baseline for a plan that carries approved_baseline)
EOF
}

# sha256_of FILE — print FILE's SHA-256 as 64 lowercase hex digits, using the
# first installed of shasum (macOS, most Linux), sha256sum (GNU/busybox) or
# openssl. Returns 1 when none is installed or the tool's output is not a
# digest — the caller fails closed. Duplicated verbatim in
# test-plan-approve.sh, test-plan-verify.sh and test-plan-recheck.sh
# (self-contained scripts, no sourcing between siblings).
sha256_of() {
	if command -v shasum >/dev/null 2>&1; then
		_digest_line=$(shasum -a 256 <"$1") || return 1
		_digest=${_digest_line%% *}
	elif command -v sha256sum >/dev/null 2>&1; then
		_digest_line=$(sha256sum <"$1") || return 1
		_digest=${_digest_line%% *}
	elif command -v openssl >/dev/null 2>&1; then
		_digest_line=$(openssl dgst -sha256 <"$1") || return 1
		_digest=${_digest_line##* }
	else
		return 1
	fi
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	is_sha256_hex "$_digest" || return 1
	printf '%s\n' "$_digest"
}

# is_sha256_hex VALUE — true when VALUE is exactly 64 lowercase hex digits.
is_sha256_hex() {
	case "$1" in
		*[!0-9a-f]*) return 1 ;;
		*) : ;;
	esac
	[ "${#1}" -eq 64 ]
}

# digest_lines_json PROGRAM FILE — the SHA-256 of each line `jq -S -c`
# prints for the library program PROGRAM over FILE (one value per line), as
# a JSON array in order. The lines are staged in ENTRIES_FILE, each copied
# with its trailing newline to its own file in ENTRY_DIR, and all are hashed
# by one run of the hasher (sha256_each), so a plan's hundred-odd entries
# cost one process, not one each. Returns 1 when jq, the split or the hash
# fails, or the digests do not match the lines one for one — the caller
# fails closed. The same copy is in test-plan-amend.sh.
digest_lines_json() {
	jq -S -c "$JQ_VALIDATE$1" "$2" >"$ENTRIES_FILE" || return 1
	rm -f "$ENTRY_DIR"/line.* || return 1
	# The directory reaches awk through ENVIRON: -v would expand backslash
	# escapes in it.
	ENTRY_DIR=$ENTRY_DIR awk '{ path = sprintf("%s/line.%08d", ENVIRON["ENTRY_DIR"], NR); print > path; close(path) }' \
		"$ENTRIES_FILE" || return 1
	_line_count=$(awk 'END { print NR }' "$ENTRIES_FILE") || return 1
	if [ "$_line_count" -eq 0 ]; then
		printf '[]\n'
		return 0
	fi
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	_entry_digests=$(sha256_each "$ENTRY_DIR"/line.*) || return 1
	_digests="["
	_digest_count=0
	while IFS= read -r _entry_digest; do
		[ "$_digests" = "[" ] || _digests="$_digests,"
		_digests="$_digests\"$_entry_digest\""
		_digest_count=$((_digest_count + 1))
	done <<EOF
$_entry_digests
EOF
	[ "$_digest_count" -eq "$_line_count" ] || return 1
	printf '%s]\n' "$_digests"
}

# sha256_each FILE... — print each FILE's SHA-256, one per line in argument
# order, from one run of the first installed of shasum, sha256sum or openssl
# (as sha256_of picks). Returns 1 when none is installed or a line is not a
# digest. shasum and sha256sum print "<digest>  <name>", prefixed with "\"
# when the name holds a backslash; openssl prints "...(<name>)= <digest>".
sha256_each() {
	if command -v shasum >/dev/null 2>&1; then
		_hash_lines=$(shasum -a 256 "$@") || return 1
		_digest_at=start
	elif command -v sha256sum >/dev/null 2>&1; then
		_hash_lines=$(sha256sum "$@") || return 1
		_digest_at=start
	elif command -v openssl >/dev/null 2>&1; then
		_hash_lines=$(openssl dgst -sha256 "$@") || return 1
		_digest_at=end
	else
		return 1
	fi
	while IFS= read -r _hash_line; do
		if [ "$_digest_at" = start ]; then
			_hash_line=${_hash_line#\\}
			_digest=${_hash_line%% *}
		else
			_digest=${_hash_line##* }
		fi
		# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
		is_sha256_hex "$_digest" || return 1
		printf '%s\n' "$_digest"
	done <<EOF
$_hash_lines
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_RECHECK_FILE=""
OPT_BASELINE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--recheck-file)
			[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
			OPT_RECHECK_FILE=$2
			shift
			;;
		--baseline)
			[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
			OPT_BASELINE=$2
			shift
			;;
		-h|--help) usage; exit 0 ;;
		--)        shift; break ;;
		-*)        usage >&2; error "unknown option: $1"; exit 2 ;;
		*)         usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

if [ -n "$OPT_RECHECK_FILE" ] && { [ ! -f "$OPT_RECHECK_FILE" ] || [ ! -r "$OPT_RECHECK_FILE" ]; }; then
	usage >&2
	error "--recheck-file does not exist or is not readable: $OPT_RECHECK_FILE"
	exit 2
fi

if [ -n "$OPT_BASELINE" ] && { [ ! -f "$OPT_BASELINE" ] || [ ! -r "$OPT_BASELINE" ]; }; then
	usage >&2
	error "--baseline does not exist or is not readable: $OPT_BASELINE"
	exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
	error "jq is not installed"
	warn  "install it (e.g. https://jqlang.org) then re-run"
	exit 1
fi

if [ ! -r "$TEST_PLAN_VALIDATE_JQ" ] || [ ! -r "$TEST_PLAN_SECURITY_TERMS_JQ" ] || [ ! -r "$TEST_PLAN_CATEGORIES_JSON" ]; then
	error "cannot read the shared jq library: $TEST_PLAN_VALIDATE_JQ, $TEST_PLAN_SECURITY_TERMS_JQ and $TEST_PLAN_CATEGORIES_JSON (the last two are the flow-review skill's, which must be installed beside flow-testing; invoke this script by its absolute path)"
	exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup trap registered BEFORE mktemp runs, so a signal in the narrow
# window between process start and temp-file creation can never leave a
# stray file behind. INT/TERM trapped separately from EXIT so an interrupted
# run reports the conventional 130/143.
# ---------------------------------------------------------------------------
TMP_FILE=""
ENTRIES_FILE=""
ENTRY_DIR=""
BASELINE_COPY=""
BASELINE_JSON=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$TMP_FILE" ]      || rm -f "$TMP_FILE" 2>/dev/null || true
	[ -z "$ENTRIES_FILE" ]  || rm -f "$ENTRIES_FILE" 2>/dev/null || true
	[ -z "$ENTRY_DIR" ]     || rm -rf "$ENTRY_DIR" 2>/dev/null || true
	[ -z "$BASELINE_COPY" ] || rm -f "$BASELINE_COPY" 2>/dev/null || true
	[ -z "$BASELINE_JSON" ] || rm -f "$BASELINE_JSON" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/test-plan-render-md.XXXXXX")

cat >"$TMP_FILE"

if ! jq -e . "$TMP_FILE" >/dev/null 2>&1; then
	error "stdin is not valid JSON"
	exit 1
fi

# `jq FILTER file` runs once per document, so {invalid}{valid} on stdin
# would otherwise validate one and render both.
if ! jq -s -e 'length == 1' "$TMP_FILE" >/dev/null 2>&1; then
	error "stdin must hold exactly ONE JSON document"
	exit 1
fi

TEST_PLAN_LIB_DIR_ABS=$(CDPATH='' cd -P -- "$TEST_PLAN_LIB_DIR" && pwd -P) || {
	error "cannot resolve the jq library directory: $TEST_PLAN_LIB_DIR"
	exit 1
}
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE=$(jq -n -r --arg lib_dir "$TEST_PLAN_LIB_DIR_ABS" \
	'"include \"test-plan-validate\" {search: \($lib_dir | tojson)};"') || {
	error "failed to build the jq library include"
	exit 1
}
JQ_VALIDATE="$JQ_VALIDATE
"

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
VALIDATION_ERRORS=$(jq -r "$JQ_VALIDATE"' plan_document_errors[]' "$TMP_FILE") || {
	error "failed to run the plan validator"
	exit 1
}
if [ -n "$VALIDATION_ERRORS" ]; then
	printf '%s\n' "$VALIDATION_ERRORS" | while IFS= read -r validation_error; do
		error "invalid test plan: $validation_error"
	done
	exit 1
fi

# The sidecar, when given, must be this plan's: its re-checks are shown
# beside the entries they name, and nothing else of it is read.
RECHECK_ARG=/dev/null
if [ -n "$OPT_RECHECK_FILE" ]; then
	PLAN_ID=$(jq -r '.id' "$TMP_FILE")
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	SIDECAR_ERRORS=$(jq -r --arg plan_id "$PLAN_ID" \
		"$JQ_VALIDATE"' recheck_sidecar_errors($plan_id)[]' "$OPT_RECHECK_FILE" 2>/dev/null) || SIDECAR_ERRORS="(root): not valid JSON"
	if [ -n "$SIDECAR_ERRORS" ]; then
		printf '%s\n' "$SIDECAR_ERRORS" | while IFS= read -r validation_error; do
			error "invalid --recheck-file: $validation_error"
		done
		exit 1
	fi
	RECHECK_ARG=$OPT_RECHECK_FILE
fi

# The approved plan this render compares with: --baseline, or the plan's own
# approved_baseline. Both at once is refused rather than one silently
# preferred.
PLAN_HAS_BASELINE=$(jq -r 'has("approved_baseline")' "$TMP_FILE")
if [ -n "$OPT_BASELINE" ] && [ "$PLAN_HAS_BASELINE" = true ]; then
	usage >&2
	error "--baseline given for a plan that records its own approved_baseline; render it without --baseline"
	exit 2
fi

# The --baseline plan, read once into a private copy: one valid document,
# approved, with this plan's id.
if [ -n "$OPT_BASELINE" ]; then
	BASELINE_COPY=$(mktemp "${TMPDIR:-/tmp}/test-plan-render-md.baseline.XXXXXX")
	if ! cat "$OPT_BASELINE" >"$BASELINE_COPY"; then
		error "failed to read --baseline: $OPT_BASELINE"
		exit 1
	fi
	if ! jq -s -e 'length == 1' "$BASELINE_COPY" >/dev/null 2>&1; then
		error "--baseline is not valid JSON or not exactly ONE JSON document: $OPT_BASELINE"
		exit 1
	fi
	PLAN_ID=$(jq -r '.id' "$TMP_FILE")
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	BASELINE_ERRORS=$(jq -r --arg plan_id "$PLAN_ID" "$JQ_VALIDATE"'
		plan_document_errors as $errors
		| if $errors != [] then $errors[]
		  elif .status != "approved" then "status: is \(.status | tojson), not \"approved\" (the baseline is the plan as it was approved)"
		  elif .id != $plan_id then "id: names a different plan than the one rendered"
		  else empty end' "$BASELINE_COPY") || {
		error "failed to run the plan validator"
		exit 1
	}
	if [ -n "$BASELINE_ERRORS" ]; then
		printf '%s\n' "$BASELINE_ERRORS" | while IFS= read -r validation_error; do
			error "invalid --baseline: $validation_error"
		done
		exit 1
	fi
fi

if [ -n "$OPT_RECHECK_FILE" ] || [ -n "$OPT_BASELINE" ] || [ "$PLAN_HAS_BASELINE" = true ]; then
	ENTRIES_FILE=$(mktemp "${TMPDIR:-/tmp}/test-plan-render-md.entries.XXXXXX")
	ENTRY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-plan-render-md.entry.XXXXXX")
fi

# The digest of each not_tested entry, in order, as test-plan-recheck.sh
# takes it: the entry as `jq -S -c` prints it (one line, so one entry per
# line), waiver keys removed. Taken only when a sidecar is shown.
ENTRY_DIGESTS="[]"
if [ -n "$OPT_RECHECK_FILE" ]; then
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	ENTRY_DIGESTS=$(digest_lines_json ' .not_tested[] | not_tested_digest_input' "$TMP_FILE") || {
		error "cannot compute the not_tested entries' SHA-256 (install shasum, sha256sum, or openssl)"
		exit 1
	}
fi

# Against a baseline, the fingerprint digests of the plan's own tests,
# existing-test entries and sections (baseline_digest_inputs), and the
# --baseline plan's
# approved_baseline, built from its digests the way test-plan-amend.sh
# builds the stored one.
CURRENT_DIGESTS="[]"
BASELINE_ARG=/dev/null
if [ -n "$OPT_BASELINE" ] || [ "$PLAN_HAS_BASELINE" = true ]; then
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	CURRENT_DIGESTS=$(digest_lines_json ' baseline_digest_inputs' "$TMP_FILE") || {
		error "cannot compute the tests' SHA-256 (install shasum, sha256sum, or openssl)"
		exit 1
	}
fi
if [ -n "$OPT_BASELINE" ]; then
	# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
	BASELINE_DIGESTS=$(digest_lines_json ' baseline_digest_inputs' "$BASELINE_COPY") || {
		error "cannot compute the --baseline tests' SHA-256 (install shasum, sha256sum, or openssl)"
		exit 1
	}
	BASELINE_JSON=$(mktemp "${TMPDIR:-/tmp}/test-plan-render-md.baseline-json.XXXXXX")
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	if ! jq -c --argjson digests "$BASELINE_DIGESTS" "$JQ_VALIDATE"' approved_baseline($digests)' "$BASELINE_COPY" >"$BASELINE_JSON"; then
		error "failed to fingerprint --baseline"
		exit 1
	fi
	BASELINE_ARG=$BASELINE_JSON
fi

# The change view: any baseline. Compact when the baseline fingerprints the
# sections too — always for --baseline (fingerprinted here), and for a
# stored approved_baseline recorded with them.
CHANGE_VIEW=false
COMPACT_VIEW=false
if [ -n "$OPT_BASELINE" ]; then
	CHANGE_VIEW=true
	COMPACT_VIEW=true
elif [ "$PLAN_HAS_BASELINE" = true ]; then
	CHANGE_VIEW=true
	COMPACT_VIEW=$(jq -r '.approved_baseline | has("sections")' "$TMP_FILE")
fi

# ---------------------------------------------------------------------------
# The renderer. Every field reaches the output ONLY as a jq value inside this
# STATIC jq program — nothing is concatenated into the program text or handed
# to a shell. The validator library is prepended so `neutralize` replaces
# exactly the character set the validator rejects (forbidden_characters).
# Integers are floored before printing so an integral float (3.0) renders as
# 3. Built as an array of SECTIONS joined by one blank line; a section is its
# heading and its blocks, each separated by a blank line.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_RENDER="$JQ_VALIDATE"'
def neutralize: gsub(forbidden_characters; " ");
def code_span: "`" + neutralize + "`";
def number: floor | tostring;
def section($heading; $blocks): [$heading] + $blocks | join("\n\n");

# The Markdown punctuation that would style text rather than show it: a
# backslash, emphasis, link, HTML, entity, strikethrough and table
# characters, and an underscore that is not between two letters or digits
# (one between them cannot open emphasis, so snake_case stays unescaped).
def markdown_punctuation: "[\\\\\\[\\]*<>&~|]|(?<![A-Za-z0-9])_|_(?![A-Za-z0-9])";
# A code span, matched as the validator matches one (outside_code_spans).
def code_span_run: "(?<![`\\\\])(?<run>`+)(?!`).*?(?<!`)\\k<run>(?!`)";

# A directory is plain text, so the terminal does not style it as a path. It
# always follows " · " on its line, so it cannot open a block construct; its
# punctuation, a backslash included, is backslash-escaped so it shows as
# typed.
def plain_text: neutralize | gsub("(?<c>" + markdown_punctuation + ")"; "\\\(.c)");

# Free text: its punctuation outside a code span is escaped as in a
# directory, so "__lmc" or "*" shows as typed; a code span stays live.
def prose:
  neutralize
  | gsub("(?<span>" + code_span_run + ")|(?<c>" + markdown_punctuation + ")";
      if .span != null then .span else "\\" + .c end);

# A bold label over a bulleted list, "- none" when the list is empty.
def labeled_list($label; $items):
  ["**" + $label + ":**"] + (if $items == [] then ["- none"] else $items | map("- " + .) end) | join("\n");
def counted_list($label; $items): labeled_list($label + " (" + ($items | length | tostring) + ")"; $items);

# An ordered-list item with its sub-bullets indented to the item text, so a
# two-digit number still nests them.
def numbered_item($n; $title; $details):
  (($n | tostring) + ". ") as $marker
  | [$marker + $title] + ($details | map(($marker | gsub("."; " ")) + "- " + .)) | join("\n");

# A bulleted item that carries its number as bold text.
def explicitly_numbered_item($n; $title; $details):
  ["- **" + ($n | tostring) + ".** " + $title] + ($details | map("  - " + .)) | join("\n");

# Items {n, title, details} shown with their own numbers. Markdown numbers an
# ordered list on from its first item whatever the later markers say, so a
# list whose numbers skip (a stored plan with a unit test between two
# end-to-end tests, or the change view leaving entries out) is shown as
# bullets with explicit numbers instead.
def numbered_list:
  (map(.n)) as $numbers
  | if $numbers == [range($numbers[0]; $numbers[0] + length)]
    then map(numbered_item(.n; .title; .details))
    else map(explicitly_numbered_item(.n; .title; .details)) end
  | join("\n");

def level_label: {"e2e": "end-to-end", "integration": "integration", "unit": "unit"}[.] // neutralize;
def unit_kind_label: {"required": " · required", "optional": " · *optional, you decide*", "accepted": " · *accepted*"}[.];
def action_label:
  {"restored": "Restored", "accepted": "Accepted", "removed": "Removed", "merged": "Merged",
   "added": "Added", "to-unit": "To unit", "to-integration": "To integration", "to-e2e": "To end-to-end",
   "changed": "Changed", "waived": "Waived"}[.];

# A builds_on entry may be a path or a short description naming one ("helper
# in tests/x.sh"); only a whitespace-free entry is taken as a path.
def is_builds_on_path: test(space_characters) | not;
def builds_on_paths: (.builds_on // [])[] | select(is_builds_on_path);

# Every path the plan carries, wherever it sits — the uniqueness of a shown
# name is judged against all of them, shown or not.
def plan_paths:
  def test_paths: .file, (.input // empty | .path), (.golden // empty | .path);
  [ .files.existing[], .files.new[].path, builds_on_paths,
    (.existing_tests.repair[], .existing_tests.delete[] | .file),
    (.tests[] | test_paths), (.reviewer // {} | .rejected // [] | .[].test | test_paths) ]
  | unique;

# Each path maps to its shortest trailing run of non-empty segments no OTHER
# path ends with — the file name unless two paths share one. Empty segments
# are skipped so a builds_on entry like "tests/helpers/" never shows as "". A
# path with no unique suffix ("/", or "a/b/" beside "a/b") keeps its whole
# self. A shown suffix of k segments can equal another whole path only when
# that path also has k segments, which is exactly the suffix the uniqueness
# check compared, so the names shown stay distinct.
def path_segments: split("/") | map(select(. != ""));

def directory_text($segments): if $segments == [] then "(repo root)" else $segments | join("/") end;

def display_names:
  . as $paths
  | def suffix($k): path_segments | .[-$k:] | join("/");
    reduce $paths[] as $path ({};
      ($path | path_segments) as $segments
      | .[$path] = {
          name: ($segments | last // $path),
          where: first(
            (range(1; ($segments | length) + 1) as $k
             | ($path | suffix($k)) as $shown
             | select(all($paths[]; . == $path or suffix($k) != $shown))
             | if $k == 1 then null else $segments[-$k:-1] | join("/") end),
            directory_text($segments[:-1])) });

def full_directory: directory_text(path_segments[:-1]);

def location($directory): if $directory == null then "" else " · " + ($directory | plain_text) end;

# A plan path as its file name, then $marker, then its directory when shown.
# An entry not in $names (a builds_on description) is shown whole.
def path_label($names; $marker; $directory):
  if $names[.] == null then code_span + $marker
  else ($names[.].name | code_span) + $marker + location($directory) end;

def path_span($names): path_label($names; ""; $names[.].where);
def located_path_span($names; $marker): path_label($names; $marker; full_directory);

# Planned tests are numbered by n; a rejected one by its continued number.
def test_numbers:
  (shown_rejected | map({key: .test.name, value: .shown_n}) | from_entries)
  + (.tests | map({key: .name, value: .n}) | from_entries);

# --- against an approved baseline (approved_baseline or --baseline) ---------

# The state of each fingerprint against the baseline fingerprints of the same
# list: an equal digest is unchanged, the same name changed, else new.
def fingerprint_states($before):
  map(.sha256 as $sha | .name as $name
      | if any($before[]; .sha256 == $sha) then "unchanged"
        elif any($before[]; .name == $name) then "changed"
        else "new" end);
def removed_names($before; $after):
  ($after | map(.name)) as $kept | [ $before[] | select(.name | member($kept) | not) | .name ];

# A change since approval that names neither a test nor existing_tests (a
# waiver, a behavior or not_tested edit, ...), so the test and entry counts
# do not show it.
def is_other_change: (has("test") | not) and .field != "existing_tests";

# The tests renamed since approval, new name to old: an added amendment
# since approval whose renamed_from names a test the baseline held and the
# plan no longer does, for a test that is new against the baseline. Each old
# name pairs with one new test, the first that claims it.
def renamed_tests($later; $new_names; $removed):
  reduce ($later[] | select(.action == "added" and has("renamed_from"))) as $added ({};
    if ($added.test | member($new_names)) and ($added.renamed_from | member($removed))
       and .[$added.test] == null and ([.[]] | index([$added.renamed_from])) == null
    then .[$added.test] = $added.renamed_from else . end);

# Per section list, the state of each entry and the names removed; per
# section digest, whether it is unchanged. null for a baseline recorded
# without sections.
def section_delta($baseline; $current):
  if $baseline.sections == null then null
  else
    { lists: (reduce baseline_section_lists[] as $list ({};
        .[$list] = { states: ($current.sections[$list] | fingerprint_states($baseline.sections[$list])),
                     removed: removed_names($baseline.sections[$list]; $current.sections[$list]) })),
      unchanged: (reduce baseline_section_digests[] as $key ({}; .[$key] = ($current.sections[$key] == $baseline.sections[$key]))) }
  end;

# The delta the render shows: a state per test and per existing-test entry,
# by position (a renamed test "renamed"), the names the plan no longer holds
# (an old name of a renamed test aside), how many amendments were made before
# approval, how many later ones are other changes, and the delta of the
# sections.
def baseline_delta($baseline; $current):
  ((.amendments // [])[$baseline.amendments:]) as $later
  | ($current.tests | fingerprint_states($baseline.tests)) as $test_states
  | removed_names($baseline.tests; $current.tests) as $removed
  | [ range(0; $test_states | length) as $i | select($test_states[$i] == "new") | .tests[$i].name ] as $new_names
  | renamed_tests($later; $new_names; $removed) as $renamed
  | { approved_at: $baseline.approved_at,
      earlier_amendments: $baseline.amendments,
      other_changes: ($later | map(select(is_other_change)) | length),
      tests: [ range(0; $test_states | length) as $i
               | if $renamed[.tests[$i].name] != null then "renamed" else $test_states[$i] end ],
      renamed: $renamed,
      removed_tests: ($removed - [$renamed[]]),
      existing: (reduce baseline_lists[] as $list ({};
        .[$list] = { states: ($current.existing_tests[$list] | fingerprint_states($baseline.existing_tests[$list])),
                     removed: removed_names($baseline.existing_tests[$list]; $current.existing_tests[$list]) })),
      sections: section_delta($baseline; $current) };

# The section lists and digests the change view leaves out: unchanged
# since approval, with nothing in them new, changed or removed.
def list_unchanged($delta; $list):
  $delta.sections.lists[$list] | (.states | all(. == "unchanged")) and .removed == [];
def section_unchanged($delta; $key): $delta.sections.unchanged[$key];

def capitalized: (.[:1] | ascii_upcase) + .[1:];
def state_tag: {"new": "**New** · ", "changed": "**Changed** · "}[. // ""] // "";
def test_state_tag($delta; $name):
  if . == "renamed" then "**Renamed** (was " + ($delta.renamed[$name] | code_span) + ") · " else state_tag end;
def state_count($state): map(select(. == $state)) | length;
def counted($count; $one; $many): ($count | tostring) + " " + (if $count == 1 then $one else $many end);

# " · 6 new, 1 renamed, 2 changed" after a count-carrying heading or label;
# zero parts omitted, nothing when no entry is new, renamed or changed.
def delta_suffix:
  [ (state_count("new") | select(. > 0) | tostring + " new"),
    (state_count("renamed") | select(. > 0) | tostring + " renamed"),
    (state_count("changed") | select(. > 0) | tostring + " changed") ]
  | if . == [] then "" else " · " + join(", ") end;

def existing_nouns: {reused: ["reused test", "reused tests"], repair: ["repair", "repairs"], delete: ["deletion", "deletions"]};

# Items with their states: all of them, each tagged, or in the change view
# only the new and changed ones.
def tagged_items($items; $states):
  [ range(0; $items | length) as $i | select(($states | length) > $i)
    | select(($states[$i] != "unchanged") or ($compact | not)) | ($states[$i] | state_tag) + $items[$i] ];

def baselined_list($label; $items; $states):
  labeled_list($label + " (" + ($items | length | tostring) + ")" + ($states | delta_suffix); tagged_items($items; $states));

# What changed since approval, as a list: tests first, then the
# existing-test entries, then the other amendments; zero parts omitted.
def change_summary($delta):
  [ ($delta.tests | state_count("new") | select(. > 0) | counted(.; "new test"; "new tests")),
    ($delta.tests | state_count("renamed") | select(. > 0) | counted(.; "test renamed"; "tests renamed")),
    ($delta.tests | state_count("changed") | select(. > 0) | counted(.; "test changed"; "tests changed")),
    ($delta.removed_tests | length | select(. > 0) | counted(.; "test removed"; "tests removed")),
    ($delta.tests | state_count("unchanged") | select(. > 0) | counted(.; "test unchanged"; "tests unchanged")),
    ( baseline_lists[] as $list | existing_nouns[$list] as [$one, $many] | $delta.existing[$list] as $entries
      | ($entries.states | state_count("new") | select(. > 0) | counted(.; "new " + $one; "new " + $many)),
        ($entries.states | state_count("changed") | select(. > 0) | counted(.; $one + " changed"; $many + " changed")),
        ($entries.removed | length | select(. > 0) | counted(.; $one + " removed"; $many + " removed")) ),
    ($delta.other_changes | select(. > 0) | counted(.; "other change"; "other changes") + " (see Amendments since approval)") ]
  | labeled_list("Change since approval (" + ($delta.approved_at | neutralize) + ")"; .);

# The test counts of the plan: one line without a baseline, a list against one.
def summary_parts:
  ([.tests[] | select(.level == "e2e")] | length) as $e2e
  | ([.tests[] | select(.level == "integration")] | length) as $integration
  | ([.tests[] | select(.level == "unit" and .unit_kind != "optional")] | length) as $unit
  | ([.tests[] | select(.unit_kind == "optional")] | length) as $optional
  | [ (if $e2e > 0 then ($e2e | tostring) + " end-to-end" else empty end),
      (if $integration > 0 then ($integration | tostring) + " integration" else empty end),
      (if $unit > 0 then ($unit | tostring) + " unit" else empty end),
      (if $optional > 0 then ($optional | tostring) + " optional unit" else empty end),
      "~" + (.approx_lines | number) + " lines" ];

def test_total: (.tests | length) as $total | ($total | tostring) + (if $total == 1 then " test" else " tests" end);

def summary_line:
  "**" + test_total + "**: "
  + ( summary_parts + (if has("reviewer") then [(shown_rejected | length | tostring) + " rejected"] else [] end)
      | join(" · ") );

def summary_list:
  labeled_list(test_total + " in plan";
    summary_parts + (if has("reviewer") then [shown_rejected | length | select(. > 0) | tostring + " rejected"] else [] end));

# A unit test written into the source file it tests is marked, so the human
# sees which production files the plan edits.
def file_marker:
  if .new == "harness" then " (new harness)"
  elif .new != null then " (new)"
  elif .inline_units then " (unit tests inline)"
  else "" end;

# A new file shows where it lands.
def listed_file($names):
  file_marker as $marker
  | if .new != null then .path | located_path_span($names; $marker)
    else .path | path_label($names; $marker; $names[.].where) end;

# A Files, Fixtures or Builds on list: whole without a baseline; against
# one, tagged; in the change view only when changed, with only its new and
# changed entries — a list that only lost entries shows them under Removed
# since approval.
def change_list($label; $items; $delta; $list):
  if $compact | not then [ labeled_list($label; $items) ]
  else tagged_items($items; $delta.sections.lists[$list].states) as $shown
    | if $shown == [] then [] else [ labeled_list($label; $shown) ] end end;

def run_line($delta):
  if $compact | not then [ "**Run:** " + (.run | code_span) ]
  elif section_unchanged($delta; "run") then []
  else [ "**Run (changed):** " + (.run | code_span) ] end;

def summary_section($names; $roles; $delta):
  section("## 🧪 Test Plan · " + (.change.subject | prose);
    (if $delta == null then [ summary_line ] else [ change_summary($delta), summary_list ] end)
    + change_list("Files"; $roles | map(select(.role == "file") | listed_file($names)); $delta; "files")
    + change_list("Fixtures"; $roles | map(select(.role == "fixture") | listed_file($names)); $delta; "fixtures")
    + change_list("Builds on"; (.builds_on // []) | map(path_span($names)); $delta; "builds_on")
    + run_line($delta));

def behavior_line: "**" + (.id | neutralize) + "** " + (.text | prose);

def behaviors_sections($delta):
  if $compact | not then
    [ section("### Behaviors to guard (" + (.behaviors | length | tostring) + ")";
        [ .behaviors | map("- " + behavior_line) | join("\n") ]) ]
  else
    $delta.sections.lists.behaviors.states as $states
    | tagged_items(.behaviors | map(behavior_line); $states) as $shown
    | if $shown == [] then []
      else [ section("### Behaviors to guard (" + (.behaviors | length | tostring) + ")" + ($states | delta_suffix);
               [ $shown | map("- " + .) | join("\n") ]) ] end
  end;

# Every repair or delete entry names its file, so moving the test to another
# file changes what the human approves; the file of a deleted test shows where
# it lives.
def repair_entries($names):
  map((.name | code_span) + " in " + (.file | path_span($names)) + ": " + (.reason | prose));
def delete_entries($names):
  map((.name | code_span) + " in " + (.file | located_path_span($names; "")) + ": " + (.reason | prose));

# In the change view a list with no new or changed entry is left out, and
# the section with it when every list is.
def existing_blocks($names; $delta):
  .existing_tests as $existing
  | [ ["Reused", "reused", ($existing.reused | map(.name | code_span))],
      ["To repair", "repair", ($existing.repair | repair_entries($names))],
      ["To delete", "delete", ($existing.delete | delete_entries($names))] ][]
  | . as [$label, $list, $items]
  | if $delta == null then counted_list($label; $items)
    else $delta.existing[$list].states as $states
      | select(($compact | not) or ($states | any(. != "unchanged")))
      | baselined_list($label; $items; $states) end;

def existing_sections($names; $delta):
  if $compact and section_unchanged($delta; "existing_tests") then []
  elif (.existing_tests | has("none_reason")) then
    [ section("### Existing tests"; [ "- None: " + (.existing_tests.none_reason | prose) ]) ]
  else [ existing_blocks($names; $delta) ] as $blocks
    | if $blocks == [] then [] else [ section("### Existing tests"; $blocks) ] end
  end;

def guards_text: (.guards | map(neutralize) | join(" "));

# A fixture is named on the lines of the test that reads it: approval binds
# each golden and input to its test, so a swap must not render the same.
def fixture_details($names):
  (if has("golden") then "Golden: " + (.golden.path | path_span($names)) + " (from: " + (.golden.from | prose) + ")" else empty end),
  (if has("input") then "Input: " + (.input.path | path_span($names)) + " (from: " + (.input.from | prose) + ")" else empty end);

def e2e_item($names):
  {n: (.n | floor), title: ((.name | code_span) + " · " + guards_text),
   details: [ fixture_details($names), "Why: " + (.why | prose), "Fails if: " + (.fails_if | prose) ]};

def integration_item($names):
  {n: (.n | floor), title: ((.name | code_span) + " · " + guards_text),
   details: [ fixture_details($names), "Why: " + (.why | prose), "Why not e2e: " + (.why_not_e2e | prose),
              "Fails if: " + (.fails_if | prose) ]};

def unit_item($names):
  {n: (.n | floor), title: ((.name | code_span) + " · " + guards_text + (.unit_kind | unit_kind_label)),
   details: [ fixture_details($names), "Why: " + (.why | prose), "Why not e2e: " + (.why_not_e2e | prose),
              "Fails if: " + (.fails_if | prose) ]};

def level_section($level; $none_reason_key; item):
  [ .tests[] | select(.level == $level) ] as $tests
  | section("### Proposed " + ($level | level_label) + " tests (" + ($tests | length | tostring) + ")";
      if $tests == [] then [ "- None proposed: " + (.[$none_reason_key] | prose) ]
      else [ $tests | map(item) | numbered_list ] end);

# Against a baseline, a level lists its new, renamed and changed tests in
# full, each tagged, and names its unchanged tests on one line by number, so
# every test keeps its number n and the plan does not read as all proposed.
def baselined_level_section($level; $none_reason_key; item; $delta):
  [ .tests | to_entries[] | select(.value.level == $level) | {state: $delta.tests[.key], test: .value} ] as $tests
  | [ $tests[] | select(.state != "unchanged") ] as $shown
  | [ $tests[] | select(.state == "unchanged") | .test.n | number ] as $unchanged
  | section("### " + ($level | level_label | capitalized) + " tests (" + ($tests | length | tostring) + ")"
            + ($tests | map(.state) | delta_suffix);
      if $tests == [] then [ "- None: " + (.[$none_reason_key] | prose) ]
      else
        (if $shown == [] then []
         else [ $shown | map(.state as $state | .test.name as $name | .test | item
                             | .title = ($state | test_state_tag($delta; $name)) + .title) | numbered_list ] end)
        + (if $unchanged == [] then []
           else [ "- Unchanged since approval: " + (if ($unchanged | length) == 1 then "test " else "tests " end) + ($unchanged | join(", ")) ] end)
      end);

def test_level_section($level; $none_reason_key; item; $delta):
  if $delta == null then level_section($level; $none_reason_key; item)
  else baselined_level_section($level; $none_reason_key; item; $delta) end;

# Integration tests are optional and carry no none-reason, so their section
# is shown only when the plan has one.
def integration_sections($names; $delta):
  if has_level("integration")
  then [ test_level_section("integration"; null; integration_item($names); $delta) ]
  else [] end;

# A removed path as its file name and, in plain text, its directory.
def removed_path($kind):
  (path_segments | last // "") as $name
  | ($name | code_span) + " · " + $kind + " in " + (full_directory | plain_text);

def removed_builds_on: if is_builds_on_path then removed_path("builds-on path") else code_span + " · builds-on line" end;

# The entries the baseline holds and the plan no longer does, by name (a
# renamed test under its old name aside); omitted when there are none.
def removed_sections($delta):
  if $delta == null then []
  else
    ([ $delta.removed_tests[] | code_span + " · test" ]
     + [ baseline_lists[] as $list | $delta.existing[$list].removed[] | code_span + " · " + existing_nouns[$list][0] ]
     + (if $delta.sections == null then []
        else $delta.sections.lists as $lists
          | [ $lists.files.removed[] | removed_path("file") ]
            + [ $lists.fixtures.removed[] | removed_path("fixture") ]
            + [ $lists.builds_on.removed[] | removed_builds_on ]
            + [ $lists.behaviors.removed[] | "**" + neutralize + "** · behavior" ]
            + [ $lists.not_tested.removed[] | "**" + prose + "** · not-tested entry" ] end)) as $items
    | if $items == [] then []
      else [ section("### Removed since approval (" + ($items | length | tostring) + ")"; [ $items | map("- " + .) | join("\n") ]) ] end
  end;

# A change names its test (by number while it is listed, else by name) or
# its field, so two entries sharing an item and reason stay told apart. A
# merge is recorded once per old test under one item, so it is told by that
# item alone and its identical lines shown once. In the change view an item
# that already names its test ("test 24, ...", or the test name) is not
# given the label again.
# $token occurs in the string as a whole token: no letter, digit or
# underscore right before or after it, so test_store is not found inside
# test_store_refuses. Split rather than indices: string offsets differ
# between jq versions.
def contains_token($token):
  split($token) as $parts
  | any(range(0; ($parts | length) - 1);
      ($parts[.] | test("[A-Za-z0-9_]\\z") | not) and ($parts[. + 1] | test("\\A[A-Za-z0-9_]") | not));

def item_names_test($label_number):
  .test as $test
  | (.item | contains_token($test))
    or ($label_number != null and (.item | test("\\Atest " + $label_number + "(?![0-9])")));

def change_label($numbers):
  if has("test") then
    (if $numbers[.test] then $numbers[.test] | number else null end) as $label_number
    | if $change_view and item_names_test($label_number) then ""
      elif $label_number != null then "test " + $label_number + " "
      else (.test | code_span) + " " end
  elif has("field") then (.field | code_span) + " "
  else "" end;

def change_lines($numbers):
  map({merged: (.action == "merged"),
       line: ("- **" + (.action | action_label) + ":** "
              + (if .action == "merged" then "" else change_label($numbers) end)
              + (.item | prose) + ": " + (.reason | prose))})
  | reduce .[] as $change ([];
      . as $shown
      | if $change.merged and ($change.line | member($shown)) then $shown else $shown + [$change.line] end);

# An approved name that is no current test (removed by an amendment) is
# listed by name.
def approved_line($numbers):
  "- **Approved:** " + (map(if $numbers[.name] then $numbers[.name] | number else .name | code_span end) | join(", "));

# The reviewer is always lens-test-quality-reviewer (flow-testing §3c);
# lens seats are titled without "-reviewer" (review-report-standards).
def reviewer_heading: "### Reviewer · Lens Test Quality";

# Omitted while draft (no reviewer yet), and in the change view each of the
# two sections when it is unchanged since approval. Never empty after a
# challenge: the challenge requires every test in reviewer.approved, and an
# amend never shrinks reviewer.approved.
def reviewer_sections($numbers; $delta):
  if has("reviewer") | not then []
  else
    .reviewer as $reviewer
    | shown_rejected as $rejected
    | (if $compact and section_unchanged($delta; "reviewer") then []
       else [ section(reviewer_heading;
          [ (if ($reviewer.approved | length) > 0 then [ $reviewer.approved | approved_line($numbers) ] else [] end)
            + ($reviewer.changes | change_lines($numbers))
            + (if ($reviewer | has("no_e2e_agreed"))
               then [ "- **No end-to-end test agreed:** " + ($reviewer.no_e2e_agreed | prose) ] else [] end)
            | join("\n") ]) ] end)
      + (if $compact and section_unchanged($delta; "rejected") then []
         else [ section("### Rejected (" + ($rejected | length | tostring) + ")";
          [ if $rejected == [] then "- none"
            else $rejected
                 | map({n: .shown_n, title: ((.test.name | code_span) + " · " + (.test.level | level_label) + " · " + (.test | guards_text)),
                        details: [ "Rejected: " + (.reason | prose) ]})
                 | numbered_list
            end ]) ] end)
  end;

# Against a baseline only the amendments made since approval are listed; the
# earlier ones, already approved, are counted on one line.
def amendments_section($numbers; $delta):
  if has("amendments") | not then []
  elif $delta == null then [ section("### Amendments"; [ .amendments | change_lines($numbers) | join("\n") ]) ]
  else
    .amendments[$delta.earlier_amendments:] as $later
    | [ section("### Amendments since approval";
          [ (if $later == [] then ["- none"] else $later | change_lines($numbers) end)
            + (if $delta.earlier_amendments > 0
               then ["- **Before approval:** " + counted($delta.earlier_amendments; "amendment"; "amendments") + ", not listed"]
               else [] end)
            | join("\n") ]) ]
  end;

def recheck_line:
  if .status == "dismissed" then "Kept untested by you — " + (.reason | prose)
  else
    "Re-check: " + (.status | neutralize)
    + (if has("proof") then " (" + (.proof | prose) + ")"
       elif has("reason") then " (" + (.reason | prose) + ")"
       else "" end)
  end;

# The evidence of an exclusion: its proof, else Not proven — fail closed, so
# an entry naming neither proof nor unproven reads as not proven. An entry
# that needs the human waiver (needs_waiver) shows it, or that it needs one;
# an entry without a category is marked as not judged. Each sidecar record
# whose entry_sha256 is this entry digest ($digest) follows.
def exclusion_evidence_lines($rechecks; $digest):
  (if has("proof") then ["Proof: " + (.proof | prose)] else ["Not proven"] end)
  + (if is_unjudged_exclusion then ["Legacy entry — not judged"]
     elif .waived_by_human == true then ["Waived by you: " + (.waiver_reason | prose)]
     elif needs_waiver and .category != "other"
     then ["Needs your waiver: " + (.category | neutralize) + " is a required test category"]
     elif needs_waiver then ["Needs your waiver: not proven"]
     else [] end)
  + [ $rechecks[] | select(.entry_sha256 == $digest) | recheck_line ];

# An entry whose re-check escalated it to the human is marked as the
# flow-review render marks an escalated item, until the human dismisses it.
def decision_marker($rechecks; $digest):
  ([$rechecks[] | select(.entry_sha256 == $digest) | .status] | last) as $latest
  | if $latest == "escalated" then "**needs your decision** · " else "" end;

# In the change view an entry is listed when it is new or changed since
# approval, still waits on the human (a waiver it needs and lacks, or no
# category yet), or has a re-check shown: the human never misses one they
# must answer.
def awaits_the_human($rechecks; $digest):
  is_unjudged_exclusion or (needs_waiver and .waived_by_human != true)
  or any($rechecks[]; .entry_sha256 == $digest);

# The not_tested entries the section lists, each with its number — numbered
# on after the tests and the rejected proposals, the number the waiver and
# re-check scripts take, whichever entries the change view leaves out — and
# its state against the baseline (null without section fingerprints).
def listed_not_tested($rechecks; $digests; $delta):
  not_tested_number_offset as $offset
  | (if $compact then $delta.sections.lists.not_tested.states else [] end) as $states
  | [ .not_tested | to_entries[]
      | {n: ($offset + .key + 1), index: .key, entry: .value, state: $states[.key]}
      | select(($compact | not) or .state != "unchanged"
               or ($digests[.index] as $digest | .entry | awaits_the_human($rechecks; $digest))) ];

def not_tested_sections($listed; $rechecks; $digests; $delta):
  if $compact and $listed == [] then []
  else
    [ section("### Not tested (" + (.not_tested | length | tostring) + ")"
              + (if $compact then $delta.sections.lists.not_tested.states | delta_suffix else "" end);
        [ if $listed == [] then "- none"
          else $listed
               | map(.index as $index | .state as $state
                     | {n, title: (($state | state_tag) + (.entry | decision_marker($rechecks; $digests[$index]))
                                   + "**" + (.entry.what | prose) + ":** " + (.entry.reason | prose)),
                        details: ([ "Accepting: " + (.entry.accepting | prose) ]
                                  + (.entry | exclusion_evidence_lines($rechecks; $digests[$index])))})
               | numbered_list
          end ]) ]
  end;

# The change view closes with what it left out as unchanged since approval:
# each section by name, and how many not_tested entries it did not list.
def unchanged_sections($listed; $delta):
  if $compact | not then []
  else
    ((.not_tested | length) - ($listed | length)) as $unlisted
    | [ (select(list_unchanged($delta; "files")) | "files"),
        (select(list_unchanged($delta; "fixtures")) | "fixtures"),
        (select(list_unchanged($delta; "builds_on")) | "builds on"),
        (select(section_unchanged($delta; "run")) | "run"),
        (select(list_unchanged($delta; "behaviors")) | "behaviors"),
        (select(section_unchanged($delta; "existing_tests")) | "existing tests"),
        (select(has("reviewer") and section_unchanged($delta; "reviewer")) | "reviewer"),
        (select(has("reviewer") and section_unchanged($delta; "rejected")) | "rejected"),
        ($unlisted | select(. > 0) | counted(.; "not-tested entry"; "not-tested entries")) ]
    | if . == [] then [] else [ "**Unchanged since approval, not shown:** " + join(", ") ] end
  end;

(($sidecar_arr[0] // {}) | .rechecks // []) as $rechecks
| (plan_paths | display_names) as $names
| file_roles as $roles
| test_numbers as $numbers
| (($baseline_arr[0] // .approved_baseline) // null) as $baseline
| (if $baseline == null then null else baseline_delta($baseline; baseline_fingerprints($current_digests)) end) as $delta
| listed_not_tested($rechecks; $entry_digests; $delta) as $listed
| ( [ summary_section($names; $roles; $delta) ]
    + behaviors_sections($delta)
    + existing_sections($names; $delta)
    + [ test_level_section("e2e"; "no_e2e_reason"; e2e_item($names); $delta) ]
    + integration_sections($names; $delta)
    + [ test_level_section("unit"; "no_unit_reason"; unit_item($names); $delta) ]
    + removed_sections($delta)
    + reviewer_sections($numbers; $delta)
    + amendments_section($numbers; $delta)
    + not_tested_sections($listed; $rechecks; $entry_digests; $delta)
    + unchanged_sections($listed; $delta)
  ) | join("\n\n")
'

# Digest before any output, so a missing hasher fails closed with nothing
# rendered rather than with a plan the caller cannot bind an approval to.
# shellcheck disable=SC2310  # the helper returns an explicit status at every step; set -e is not relied on inside it
PLAN_SHA256=$(sha256_of "$TMP_FILE") || {
	error "cannot compute the plan's SHA-256 (install shasum, sha256sum, or openssl)"
	exit 1
}

jq -r --slurpfile sidecar_arr "$RECHECK_ARG" --argjson entry_digests "$ENTRY_DIGESTS" \
	--slurpfile baseline_arr "$BASELINE_ARG" --argjson current_digests "$CURRENT_DIGESTS" \
	--argjson change_view "$CHANGE_VIEW" --argjson compact "$COMPACT_VIEW" "$JQ_RENDER" "$TMP_FILE" || {
	error "failed to render the test plan"
	exit 1
}
printf 'TEST_PLAN_SHA256=%s\n' "$PLAN_SHA256" >&2
exit 0
