#!/usr/bin/env sh
#
# review-add-round.sh — append a new review round onto an EXISTING flow-review
#                        durable artifact: merge in this round's findings
#                        (new + partial updates to existing ones), recompute
#                        summary/verdict fresh, atomic same-directory rewrite.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §5c). See
# review-create.sh's header for the full rationale.
#
# WHY summary/overall_verdict are recomputed FRESH from the whole post-merge
# findings[] every time, never patched incrementally: an incremental patch
# can only drift further from the truth round over round; recomputing from
# scratch means the summary can never be wrong as long as findings[] is
# right.
#
# WHY a fields-file finding entry is resolved to "update" or "new" by looking
# it up by id in the artifact's CURRENT findings (not by any flag the caller
# sets): the caller already knows whether it's describing a finding that
# exists or one that doesn't — matching by id is the one mechanical, race-free
# way to make that same decision here, and it can never disagree with what's
# actually already on the document.
#
# WHY every carried-over finding still marked NEW is flipped to OPEN before
# this round's updates are applied: `status: NEW` means "first reported THIS
# round" (review-artifact.schema.json / finding-status.schema.json). Once a
# further round exists, a finding from an earlier one is no longer new — left
# alone it would claim NEW forever and inflate summary.new. The flip happens
# BEFORE the caller's own entries merge on top, so an entry that deliberately
# re-asserts "status": "NEW" still wins.
#
# WHY --diff-files, and --diff-hunks with a relates_to: a review covers
# the diff, and a finding is scoped by its effect on it, so every location
# this round's fields-file introduces (a NEW finding's, one an UPDATE adds, a
# speculative entry's, a new handoff's) names a file in the list
# diff-scope.sh wrote, or is anchored by its own entry's relates_to — one
# location of the changed code that relies on or exposes the defect, its
# line or whole range inside one hunk the diff changed (diff-hunks.tsv) — or
# the fields-file is rejected whole. An UPDATE that adds a location outside the diff gives its own
# relates_to. A carried finding was checked when it was written and is not
# re-checked, so its status can still be updated after its file leaves the
# diff.
#
# WHY diff_files is CUMULATIVE and each round records its own list: the diff
# can change between rounds (a fix touches a new file), and every round's
# files stay part of what the review covered, so the artifact keeps the
# union by path (the newest sha winning) and rounds[].diff_files keeps the
# list this round was given. An artifact without diff_files gains it here.
#
# WHY a carried finding cannot be RESOLVED by a round whose diff misses it: a
# resolution is a claim that the fix was verified, and a round verifies only
# what its diff covers. An UPDATE that moves a stored finding to RESOLVED
# while none of its stored files (locations, relates_to — not ones the same
# update adds) is in this round's diff is rejected, naming the finding;
# carrying it as OPEN is always accepted. An entry that sets RESOLVED also
# carries resolution_proof, the evidence the fix holds; a finding moved off
# RESOLVED loses it.
#
# WHY an item set aside must carry its evidence, and the evidence must
# exist: an edge-case finding and every speculative entry give exactly one of
# proof or unproven: true; under the security floor (lib/review-aggregates.jq,
# header WHY) proof alone. A proof the fields-file gives names a file:line
# whose file is a regular file under --repo-root and whose line is within
# it, or — in a test-plan review — a test of the plan given as --plan; a
# reviewer has no shell, so a "ran ..." proof is recorded only through
# review-update-status.sh. A NEW finding is held to it, and so is an UPDATE
# that gives an evidence field (realism, trigger, realism_reason, proof,
# unproven) or category, judged on the finding as it will be stored, under
# the floor when the stored OR the updated category is a security one; an
# UPDATE never changes the reviewer. An UPDATE that gives none of them
# carries a stored finding as it was written.
#
# WHY an UPDATE re-supplies the evidence whole: the report entry is the
# reviewer's current view of the finding, so an UPDATE that gives any
# evidence field replaces all of them, and one it omits is removed rather
# than kept from the stored copy — a finding re-filed as realistic keeps no
# stale unproven or proof. relates_to is scope, not evidence: it anchors the
# stored locations outside the diff, so an UPDATE replaces it only by giving
# one (checked against this round's hunks), and a later RESOLVED is judged
# on the files it names.
#
# WHY every category is checked against the vocabulary, a security concern
# is refused under a category that is not a security one, and speculative
# entries are keyed: see review-create.sh's header. A stored entry without a
# key is given one here. An UPDATE's category is checked against the stored
# reviewer's own vocabulary, and an UPDATE giving problem, trigger or
# category is judged as it will be stored.
#
# WHY an item under the security floor stays there: every finding and
# speculative entry under it is recorded security_floor: true (a stored one
# included), and an UPDATE, or a speculative repeat of an earlier round's
# entry (same reviewer, location and concern), that changes a floored item's
# category to a non-security one is rejected, as is unproven on a finding
# that is or becomes floored, whatever its realism.
#
# WHY a report never sets ACK: ACK is the human's waiver, recorded through
# review-update-status.sh --status ACK. An entry giving status ACK is
# accepted only on a finding already stored ACK.
#
# WHY an evidence change takes the re-check and the confirmation with it: a
# re-check and an edge-case confirmation judged the evidence as it stood. An
# UPDATE that changes a finding's locations, problem, trigger, realism, proof
# or unproven, relates_to or category drops its recheck, realism_confirmed
# and realism_confirmed_severity.
#
# WHY every rejection class is reported in one run: once the fields-file has
# its basic shape and its round is the next one, each check runs and records
# its rejections, and the fields-file is refused after the last one.
#
# WHY --plan-review must match the artifact: an artifact created with
# review-create.sh --plan-review records a test-plan review, whose plan:<item>
# locations are in scope without naming a diff file and count as covered
# for a resolution. Every round of it passes --plan-review, and no other
# artifact takes it, so a round can never change what the artifact is.
#
# Usage: see --help.
#
# Output:
#   On success, stdout carries two machine-parseable keys:
#     REVIEW_JSON=<path>
#     REVIEW_MD=<path>     the SIBLING Markdown render, which this script does
#                            NOT write — it is now STALE and must be
#                            re-rendered via render-md.sh.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  round appended
#   1  jq absent / no SHA-256 tool (shasum, sha256sum, openssl) when the
#      artifact or fields-file has speculative entries without a key /
#      --json-file missing, unreadable, or not a review artifact / the round
#      number already exists or is not newer than the newest recorded round /
#      write failed
#   2  usage error (missing/invalid argument, malformed or structurally
#      invalid --fields-file, an entry's shape invalid for its new/update
#      classification, a category outside the reviewer's vocabulary, an
#      UPDATE changing the reviewer, a status ACK on a finding not stored
#      ACK, a security-floored item's category changed to a non-security one
#      or set unproven, a security concern (x-security-terms) under a
#      category that is not a security one, an item set aside without its
#      evidence, a proof that
#      names no real file line or no test of the plan, an empty --diff-files,
#      an unanchored location outside the diff, a relates_to off the changed
#      lines, a carried finding set RESOLVED in a round whose diff misses it,
#      a RESOLVED entry without its resolution_proof, an invalid handoff or
#      ruling, --plan-review given or missing against the artifact's
#      plan_review, an invalid --diff-hunks or --plan, two speculative
#      entries sharing a key)
#
# Env:
#   TMPDIR — optional; selects the directory of the private copies of the
#   inputs (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (awk, basename, cat, chmod, date, dirname, mktemp, mv, rm, sed)
#   are assumed present, plus one of shasum, sha256sum or openssl for the
#   speculative keys. Reads lib/review-aggregates.jq, lib/security-terms.jq
#   and lib/review-categories.json, resolved relative to this script (see the
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
Usage: $PROG --json-file PATH --fields-file PATH --diff-files PATH
       [--diff-hunks PATH] [--repo-root PATH] [--plan-review [--plan PATH]]
       [-h|--help]

Append a new round onto an existing flow-review durable artifact: merge in
this round's findings (new + partial updates to existing ones), recompute
summary/verdict fresh, atomic same-directory rewrite.

Options:
  --json-file PATH    Existing review-artifact JSON file (required).
  --fields-file PATH  One JSON object (exactly one document):
                        round      required; integer >= 1, newer than
                                   every recorded round
                        reviewers  required; non-empty array of
                                   non-empty strings
                        findings   required; array of entries (shape
                                   below), may be []
                        speculative
                                   optional; array (may be []) of objects
                                   with exactly reviewer, location,
                                   concern, why_speculative, category
                                   (one-line strings), plus optionally
                                   real_if (as realism_reason below) and
                                   relates_to, and exactly one of proof
                                   or unproven (proof alone from
                                   lens-security-reviewer or in a security
                                   category); the writer adds its key
                        handoffs   optional; array of new handoffs {from,
                                   to, concern, location, relates_to?,
                                   ruling, proof unless open, filed_as when
                                   filed} or rulings {index, ruling, proof,
                                   filed_as when filed} of a stored open
                                   handoff, index its 1-based place in the
                                   artifact handoffs (the <N> of
                                   render-md.sh's REVIEW_ITEM_<n>=handoff:<N>);
                                   a handoff is ruled once, and never
                                   waived here (the human's ruling, via
                                   review-update-status.sh)
  --diff-files PATH   diff-scope.sh's diff-files.tsv or diff-files.txt
                        (required). Every location a NEW entry gives,
                        every location an UPDATE adds, every speculative
                        location and every new handoff location names a
                        file in it, or its own entry's relates_to does;
                        out-of-diff observations nothing in the diff relies
                        on belong in the report notes as pre-existing.
                        Recorded as this round's diff_files and merged by
                        path into the artifact's cumulative diff_files. A
                        carried finding is set RESOLVED only when one of its
                        stored files (a location's file, or its relates_to
                        file) is in it.
  --diff-hunks PATH   diff-scope.sh's diff-hunks.tsv (required when an entry
                        gives relates_to): every relates_to, a line or a
                        whole range, lies inside one hunk the diff changed.
  --repo-root PATH    The repository top level every proof locator resolves
                        under (required when the fields-file gives a proof
                        or resolution_proof).
  --plan-review       Required exactly when the artifact is a test-plan
                        review (plan_review: true): plan:<item> locations
                        are in scope without naming a diff file, and a proof
                        may name a test of the plan.
  --plan PATH         With --plan-review: the test plan under review
                        (required when a proof names a test number).
  -h, --help          Show this help.

Findings entries:
  Each entry is classified by its id. An id NOT yet in the artifact's
  findings makes the entry NEW; an id already there makes it an UPDATE.
  An update-shaped entry whose id is not yet in the artifact is therefore
  NEW and must carry the full NEW shape. Each id may appear in at most
  one entry per fields file.

  NEW     required: id (uppercase letters, a hyphen, 3+ digits, e.g.
          SEC-001), reviewer, tracked_status, severity, category,
          locations (non-empty array of one-line strings), problem, fix.
          optional: status (default NEW), first_seen (YYYY-MM-DD,
          default today in UTC), addressed_in_round, realism, trigger,
          realism_reason, relates_to, proof, unproven, resolution_proof.
  UPDATE  required: id. Any subset of the other fields, each well-formed
          if given; reviewer, when given, is the stored one (a finding
          never changes seat). first_seen is ignored. An UPDATE that gives
          any of realism, trigger, realism_reason, proof or unproven
          re-supplies the evidence whole: each of them it omits is removed
          from the stored finding (absent realism is realistic). A
          relates_to it gives replaces the stored one; one it omits is
          kept. A location it adds outside the diff needs its own
          relates_to.

  An entry that sets status RESOLVED on a finding not stored RESOLVED
  carries resolution_proof; resolution_proof is given only with status
  RESOLVED. status ACK is the human waiver (review-update-status.sh --status
  ACK): an entry gives it only on a finding already stored ACK.

  A category is one of its reviewer's own vocabulary (x-reviewers in
  contracts/review-category.schema.json; the union of every vocabulary for
  a reviewer x-reviewers does not list); an UPDATE's reviewer is the stored
  one. A finding or speculative entry under the security floor is stored
  with security_floor: true and stays there: a later category change to a
  non-security category (an UPDATE, or a speculative entry repeating an
  earlier round's reviewer, location and concern) is rejected, and so is
  unproven on it, edge case or not.

  A finding whose problem or trigger, or a speculative entry whose concern,
  names a security weakness of contracts/review-category.schema.json
  (x-security-terms, x-security-patterns) is rejected under a category that
  is not a security one: the reviewer re-files it under one of its own
  security categories or, if none fits, passes it to lens-security-reviewer
  as a handoff. Text is read in clauses (split at . ; : , ! ? and a closing
  parenthesis) of whole lowercase words, outside backtick code spans, an
  identifier holding "_" read as one word. A weakness is named by: a term
  (sql injection, xss, path traversal, ...), unless a mechanism word follows
  it (csrf token, sql injection prevention) and no absence word (missing,
  not, disabled, bypassed, only, ...) is in its clause; "injection" within 3
  words of sql, command, shell, ... but not after dependency, constructor,
  field, ...; an access subject (auth*, login, password, role, admin, token,
  ...) with a bypass/skip word in its clause, or followed by a mechanism
  word with an absence word in its clause, unless what is skipped is a
  cache, lookup or other performance object and no lost-access word
  (revoked, keeps, escalat*, ...) is there; unauthenticated or unauthorized
  with reach, access or call; "../" with an escape or traversal word, or a
  path joined unnormalized; text concatenated or interpolated into a query,
  shell or command, or unescaped in one; a token, secret or password
  compared with == or not in constant time; a request treated as
  authenticated, or a default to admin; a revoked user keeping access; a
  check that only verifies login while a clause says not the role. An item
  from lens-test-quality-reviewer naming a security term, auth*/unauth*,
  permission, access control, security, or a login, password or credential
  check is filed as untested-security. Judged for a NEW entry, an UPDATE
  giving problem, trigger or category, and every speculative entry.

  An UPDATE that changes locations, problem, trigger, realism, proof,
  unproven, relates_to or category drops the finding's recheck,
  realism_confirmed and realism_confirmed_severity.

  An entry may carry only the fields named here; any other key (e.g. a
  misspelled field name) is rejected. realism_confirmed and
  realism_confirmed_severity are human-only: set them with
  review-update-status.sh --confirm-edge-case; recheck likewise, with
  review-update-status.sh --recheck, and ack_reason with --status ACK
  --reason. security_floor is the writer's.

  Evidence: an edge-case finding as stored holds exactly one of proof or
  unproven; one whose reviewer is lens-security-reviewer, or whose stored
  or updated category is a security category, holds proof. Judged for a
  NEW entry and for an UPDATE giving an evidence field or category.

  reviewer, problem and fix are non-empty strings. A field set to an
  explicit null counts as given and is rejected, except an UPDATE's
  first_seen, which is ignored whatever its value.
    category            a category from
                        contracts/review-category.schema.json
    severity            CRITICAL | HIGH | MEDIUM | LOW
    tracked_status      PENDING | IN_PROGRESS | APPROVED |
                        APPROVED_WITH_FOLLOWUPS
    status              NEW | OPEN | RESOLVED | REGRESSED | ACK
    realism             realistic | edge-case (absent means realistic)
    trigger             non-empty single-line string, no control
                        characters
    realism_reason      as trigger, at most 100 characters, and no
                        invisible format character (bidi, zero-width,
                        soft hyphen, variation selector, tag)
    relates_to          one file:LINE[-END] location whose line or whole
                        range lies inside one changed hunk, as trigger, at
                        most 300 characters, no invisible format character
    proof               as realism_reason, naming its evidence as a
                        file:line (src/a.rs:42, Makefile:3; the file has
                        an extension or a "/", or is Makefile, Dockerfile,
                        Justfile, Rakefile, Gemfile or Procfile) that
                        exists under --repo-root with that line, or in a
                        test-plan review a test of the plan (test 3);
                        "ran ..." proofs are recorded only via
                        review-update-status.sh
    resolution_proof    as proof
    unproven            true
    addressed_in_round  integer from 1 to this round's number; omit it
                        when the same entry sets tracked_status to
                        PENDING or IN_PROGRESS

  Merge semantics (NEW-to-OPEN carry-over, summary and verdict recompute)
  are described in the header comment at the top of $PROG.

Once the fields-file has its basic shape and the next round number, every
rejection class is checked and reported in one run.

On success, prints:
  REVIEW_JSON=<path>
  REVIEW_MD=<path>    the sibling render, now stale — re-run render-md.sh

Exit codes:
  0  round appended
  1  jq absent / no SHA-256 tool / --json-file missing or invalid /
     duplicate or out-of-order round / write failed
  2  usage error (an invalid argument or input file, a malformed
     fields-file or entry, a category outside the reviewer's vocabulary, a
     reviewer change, an ACK the artifact does not hold, a floored item's
     category or unproven, a security concern under a category that is not
     a security one, missing or unreal evidence, an unanchored location
     outside the diff, a relates_to off the changed lines, an unverified
     resolution, an invalid handoff or ruling, --plan-review not matching
     the artifact)
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

usage_error() {
	usage >&2
	error "$*"
	exit 2
}

# report_fields_file_rejection HEADLINE JQ_ARG... — explain a --fields-file a
# validation predicate has ALREADY rejected, by running the given diagnostic
# jq program over it. The detail is best-effort: if that pass fails or prints
# nothing, HEADLINE alone is printed, so a rejection is never silent.
report_fields_file_rejection() {
	rejection_headline=$1
	shift
	if rejection_details=$(jq -r "$@" "$OPT_FIELDS_FILE" 2>/dev/null) \
		&& [ -n "$rejection_details" ]; then
		error "$rejection_headline:"
		printf '%s\n' "$rejection_details" >&2
	else
		error "$rejection_headline"
	fi
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

# proof_locator_problems — read "<field><TAB><file><TAB><start><TAB><end>"
# lines on stdin (lib/review-aggregates.jq, proof_locator_lines) and print one
# line per locator that does not point at a real line: its file is not a
# regular file inside --repo-root (a symlink is not followed), or its line is
# 0, runs backwards, or is past the file's end. The same copy is in every
# flow-review writer that records a proof.
proof_locator_problems() {
	while IFS="$TAB" read -r locator_field locator_file locator_start locator_end; do
		locator=$locator_file:$locator_start
		[ "$locator_start" = "$locator_end" ] || locator=$locator-$locator_end
		case "/$locator_file/" in
			//*|*/../*|*/./*)
				printf '%s: %s does not name a repo-relative file (--repo-root)\n' "$locator_field" "$locator"
				continue
				;;
			*) : ;;
		esac
		case "$locator_file" in
			*/*) locator_directory=$PHYSICAL_REPO_ROOT/${locator_file%/*} ;;
			*)   locator_directory=$PHYSICAL_REPO_ROOT ;;
		esac
		physical_locator_directory=$(cd -P "$locator_directory" 2>/dev/null && pwd -P) || physical_locator_directory=""
		locator_path=$physical_locator_directory/${locator_file##*/}
		case "$physical_locator_directory" in
			"$PHYSICAL_REPO_ROOT"|"$PHYSICAL_REPO_ROOT"/*) : ;;
			*) locator_path="" ;;
		esac
		if [ -z "$locator_path" ] || [ -L "$locator_path" ] || [ ! -f "$locator_path" ]; then
			printf '%s: %s names no regular file in the repo (--repo-root)\n' "$locator_field" "$locator"
			continue
		fi
		if [ "${#locator_start}" -gt 9 ] || [ "${#locator_end}" -gt 9 ]; then
			printf '%s: %s names a line past the end of %s\n' "$locator_field" "$locator" "$locator_file"
			continue
		fi
		line_count=$(awk 'END { print NR }' "$locator_path") || line_count=0
		if [ "$locator_start" -lt 1 ] || [ "$locator_end" -lt "$locator_start" ]; then
			printf '%s: %s names line 0 or a range that runs backwards\n' "$locator_field" "$locator"
		elif [ "$locator_end" -gt "$line_count" ]; then
			printf '%s: %s names a line past the end of %s (%s lines)\n' "$locator_field" "$locator" "$locator_file" "$line_count"
		fi
	done
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_JSON_FILE=""
OPT_FIELDS_FILE=""
OPT_DIFF_FILES=""
OPT_DIFF_HUNKS=""
OPT_REPO_ROOT=""
OPT_PLAN=""
PLAN_REVIEW=false

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)   need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--fields-file) need_arg "$1" "${2:-}"; OPT_FIELDS_FILE=$2; shift ;;
		--diff-files)  need_arg "$1" "${2:-}"; OPT_DIFF_FILES=$2; shift ;;
		--diff-hunks)  need_arg "$1" "${2:-}"; OPT_DIFF_HUNKS=$2; shift ;;
		--repo-root)   need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--plan)        need_arg "$1" "${2:-}"; OPT_PLAN=$2; shift ;;
		--plan-review) PLAN_REVIEW=true ;;
		-h|--help)     usage; exit 0 ;;
		--)            shift; break ;;
		-*)            usage >&2; error "unknown option: $1"; exit 2 ;;
		*)             usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || usage_error "unexpected argument: $1"

[ -n "$OPT_JSON_FILE" ]   || usage_error "--json-file is required"
[ -n "$OPT_FIELDS_FILE" ] || usage_error "--fields-file is required"
[ -n "$OPT_DIFF_FILES" ]  || usage_error "--diff-files is required (diff-scope.sh's diff-files.tsv or diff-files.txt)"
[ -z "$OPT_PLAN" ] || [ "$PLAN_REVIEW" = true ] || usage_error "--plan is given only with --plan-review"

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
	exit 1
fi

for input_option in --fields-file --diff-files --diff-hunks --plan; do
	case "$input_option" in
		--fields-file) input_path=$OPT_FIELDS_FILE ;;
		--diff-files)  input_path=$OPT_DIFF_FILES ;;
		--diff-hunks)  input_path=$OPT_DIFF_HUNKS ;;
		*)             input_path=$OPT_PLAN ;;
	esac
	if [ -n "$input_path" ] && { [ ! -f "$input_path" ] || [ ! -r "$input_path" ]; }; then
		usage_error "$input_option does not exist or is not readable: $input_path"
	fi
done

PHYSICAL_REPO_ROOT=""
if [ -n "$OPT_REPO_ROOT" ]; then
	[ -d "$OPT_REPO_ROOT" ] || usage_error "--repo-root does not exist or is not a directory: $OPT_REPO_ROOT"
	PHYSICAL_REPO_ROOT=$(cd -P "$OPT_REPO_ROOT" && pwd -P) || {
		error "cannot resolve --repo-root: $OPT_REPO_ROOT"
		exit 1
	}
fi

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
# Cleanup: remove the private copies of the inputs and the write-in-progress
# temp file on any exit path.
# ---------------------------------------------------------------------------
WORK_DIR=""
TMP_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR" 2>/dev/null || true
	[ -z "$TMP_FILE" ] || rm -f "$TMP_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/review-add-round.XXXXXX")
DIFF_FILES_JSON=$WORK_DIR/diff-files.json
DIFF_HUNKS_JSON=$WORK_DIR/diff-hunks.json
KEY_INPUTS=$WORK_DIR/key-inputs
KEY_MAP=$WORK_DIR/key-map.json
REJECTIONS=$WORK_DIR/rejections
: >"$REJECTIONS"

# ---------------------------------------------------------------------------
# --json-file must already be a well-formed review artifact — a precondition
# on existing state, not a usage error about caller-supplied input. Checked by
# TYPE, not merely for presence: a `findings` that is an object rather than an
# array would satisfy `!= null` and then break every `map`/`reduce` below.
#
# Two of these assertions exist because a guard further down is VACUOUS
# without them, so they belong here rather than at their point of use:
#
#   rounds[] ENTRY types — the monotonicity check below reads
#     `[.rounds[].round] | max`. An entry with no (or a non-numeric) `.round`
#     makes that max null or wrong, silently defeating the check; asserting
#     every entry carries an integer round >= 1 is what lets the max be
#     trusted with no `// 0` fallback papering over it.
#   findings[] id UNIQUENESS — review-create.sh refuses duplicate ids at
#     creation, but this script MUTATES an artifact it did not create (a
#     hand-edited one, or one written by another tool). `upsert_finding`
#     below merges by id via `map(if .id == $e.id …)`, so a duplicate would
#     apply one caller entry to BOTH copies. review-update-status.sh already
#     refuses this case via its exactly-one-match assertion; this matches it.
# ---------------------------------------------------------------------------
if ! jq -e 'type == "object"
	and (.findings | type == "array")
	and ((.findings | map(.id) | unique | length) == (.findings | length))
	and (.rounds | type == "array") and ((.rounds | length) > 0)
	and (.rounds | all(.[]; .round | type == "number" and (floor == .) and . >= 1))
	and (.id | type == "string")' \
	"$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "not a valid review artifact JSON file: $OPT_JSON_FILE (expected an object with a string id, a non-empty rounds[] whose every entry carries an integer round >= 1, and a findings[] array with no duplicate ids)"
	exit 1
fi

# A test-plan review artifact takes --plan-review on every round, and no
# other artifact takes it.
ARTIFACT_PLAN_REVIEW=$(jq -r '.plan_review == true' "$OPT_JSON_FILE") || {
	error "failed to read plan_review from $OPT_JSON_FILE"
	exit 1
}
if [ "$ARTIFACT_PLAN_REVIEW" != "$PLAN_REVIEW" ]; then
	usage >&2
	if [ "$PLAN_REVIEW" = true ]; then
		error "--plan-review is given only for a test-plan review artifact (one created with review-create.sh --plan-review): $OPT_JSON_FILE"
	else
		error "$OPT_JSON_FILE is a test-plan review artifact (plan_review: true): pass --plan-review"
	fi
	exit 2
fi

if ! jq -e . "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file is not valid JSON: $OPT_FIELDS_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Reject a MULTI-DOCUMENT --fields-file before validating anything about its
# contents. `jq -e FILTER file` reports the exit status of the LAST value it
# produced, while the merge below reads the FIRST document (via --slurpfile +
# $fields_arr[0]) — so a file holding {invalid}{valid} would pass validation
# on the second document and then be MERGED from the first, unvalidated one.
# Asserting exactly one document closes that gap for every check that follows.
# ---------------------------------------------------------------------------
if ! jq -s -e 'length == 1' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	error "--fields-file must hold exactly ONE JSON document: $OPT_FIELDS_FILE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Value-domain checks. review-create.sh carries a SUBSET of these (round 1
# has no status/tracked_status/date fields to check); the realism fields,
# the category vocabulary and the verdict arithmetic are shared, via
# lib/review-aggregates.jq.
#
# The id/date patterns are anchored with \A…\z, not ^…$: jq's Oniguruma
# treats `$` as end-of-line, so `^…$` would accept a finding id with a
# trailing newline — which then reaches the merged document.
#
# The enum checks require a STRING before testing membership: jq's
# `index($v)` treats an ARRAY $v as a subsequence to search for, so without
# the type guard ["HIGH"] would pass as a severity and persist as an array.
# ---------------------------------------------------------------------------
# field_keys is the ONE list of keys a findings entry may carry. The per-entry
# validator rejects any other key and the merge's pick_known_* allow-lists are
# derived from it, so both read this single definition and cannot drift. The
# optional realism fields are their own group so the unknown-field diagnostic
# can name them separately from the core finding fields.
JQ_FIELD_KEYS_DEF='
def core_field_keys:
  ["id","reviewer","status","tracked_status","severity","category","locations","relates_to","first_seen","problem","fix","addressed_in_round","resolution_proof"];
def realism_field_keys: ["realism","trigger","realism_reason","proof","unproven"];
def field_keys: core_field_keys + realism_field_keys;
'

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
# --diff-files (and --diff-hunks), read ONCE into private JSON copies that
# every later step reads, so the list checked is the list stored.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
if ! jq -R -s "$JQ_AGGREGATES"'diff_file_list' "$OPT_DIFF_FILES" >"$DIFF_FILES_JSON"; then
	error "failed to read --diff-files: $OPT_DIFF_FILES"
	exit 1
fi
if ! jq -e 'length > 0' "$DIFF_FILES_JSON" >/dev/null 2>&1; then
	usage_error "--diff-files lists no paths: $OPT_DIFF_FILES (nothing in the diff to review)"
fi
if [ -n "$OPT_DIFF_HUNKS" ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	if ! jq -R -s -e "$JQ_AGGREGATES"'diff_hunk_list' "$OPT_DIFF_HUNKS" >"$DIFF_HUNKS_JSON" 2>/dev/null; then
		usage_error "--diff-hunks is not a diff-hunks.tsv (<path><TAB><start><TAB><end> lines): $OPT_DIFF_HUNKS"
	fi
else
	printf 'null\n' >"$DIFF_HUNKS_JSON"
fi

# The number of tests in --plan, which a test-number proof is resolved
# against; null without --plan.
PLAN_TEST_COUNT=null
if [ -n "$OPT_PLAN" ]; then
	PLAN_TEST_COUNT=$(jq -e '.tests | if type == "array" then length else error end' "$OPT_PLAN" 2>/dev/null) ||
		usage_error "--plan is not a test plan (no tests array): $OPT_PLAN"
fi

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALUE_DEFS="$JQ_AGGREGATES$JQ_FIELD_KEYS_DEF"'
def severity_values: ["CRITICAL","HIGH","MEDIUM","LOW"];
def tracked_status_values: ["PENDING","IN_PROGRESS","APPROVED","APPROVED_WITH_FOLLOWUPS"];
def finding_status_values: ["NEW","OPEN","RESOLVED","REGRESSED","ACK"];
def is_severity: type == "string" and (. as $v | severity_values | index($v) != null);
def is_tracked_status: type == "string" and (. as $v | tracked_status_values | index($v) != null);
def is_finding_status: type == "string" and (. as $v | finding_status_values | index($v) != null);
def is_finding_id: is_nonempty_string and test("\\A[A-Z]+-[0-9]{3,}\\z");
def is_nonempty_string_array: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
def is_addressed_in_round: type == "number" and (floor == .) and . >= 1;
def is_iso_date: type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}\\z");
def is_unproven: . == true;
'

# ---------------------------------------------------------------------------
# Basic fields-file shape: round/reviewers/findings.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE_SHAPE="$JQ_VALUE_DEFS"'
type == "object"
and (.round != null and (.round | type == "number") and ((.round | floor) == .round) and .round >= 1)
and (.reviewers != null and (.reviewers | is_nonempty_string_array))
and (.findings != null and (.findings | type == "array"))
'

# One line per failing conjunct of JQ_VALIDATE_SHAPE, each mirroring it.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_SHAPE="$JQ_VALUE_DEFS"'
if type != "object" then "the top level must be a JSON object\(got)"
else
  . as $fields
  | (if .round == null then presence_problem($fields; "round")
     elif (.round | type == "number" and floor == . and . >= 1) | not
       then "round must be an integer >= 1 (got \(.round | shown))"
     else empty end),
    (if .reviewers == null then presence_problem($fields; "reviewers")
     else .reviewers | select(is_nonempty_string_array | not) | string_array_problems("reviewers") end),
    (if .findings == null then presence_problem($fields; "findings")
     elif (.findings | type) != "array" then "findings must be an array, may be [] (got \(.findings | shown))"
     else empty end)
end
| "  " + .
'

if ! jq -e "$JQ_VALIDATE_SHAPE" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	report_fields_file_rejection \
		"--fields-file failed validation (round/reviewers/findings shape) — see $PROG --help" \
		"$JQ_DIAGNOSE_SHAPE"
	exit 2
fi

# ---------------------------------------------------------------------------
# Past the shape and round checks every rejection class runs, and each one
# that rejects adds its lines to REJECTIONS, so one run names every problem;
# the fields-file is refused once all have run (reject_if_any_rejection).
#
# Each check below is a lib program whose predicate is "no problem lines", so
# a jq failure rejects; on a rejection the same program names each problem.
# check_fields_file HEADLINE PROBLEMS [HINT] — add the problems to REJECTIONS
# (and HINT after them) when the problem program PROBLEMS, which may read
# $artifact (the stored artifact), $diff_files and $hunks (null without
# --diff-hunks), prints a line.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_CHECK_DEFS='
def fields_proof_forms: reviewer_proof_forms($plan_review);
$artifact_arr[0] as $artifact | $diff_files_arr[0] as $diff_files | $hunks_arr[0] as $hunks |
'
check_fields_file() {
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	if ! jq -e --argjson plan_review "$PLAN_REVIEW" --slurpfile artifact_arr "$OPT_JSON_FILE" \
		--slurpfile diff_files_arr "$DIFF_FILES_JSON" --slurpfile hunks_arr "$DIFF_HUNKS_JSON" \
		"$JQ_VALUE_DEFS$JQ_CHECK_DEFS"'['"$2"'] == []' \
		"$OPT_FIELDS_FILE" >/dev/null 2>&1; then
		# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
		report_fields_file_rejection "$1" --argjson plan_review "$PLAN_REVIEW" \
			--slurpfile artifact_arr "$OPT_JSON_FILE" --slurpfile diff_files_arr "$DIFF_FILES_JSON" \
			--slurpfile hunks_arr "$DIFF_HUNKS_JSON" \
			"$JQ_VALUE_DEFS$JQ_CHECK_DEFS"'('"$2"') | "  " + .' 2>>"$REJECTIONS"
		[ -z "${3:-}" ] || printf '%s: hint: %s\n' "$PROG" "$3" >>"$REJECTIONS"
	fi
}

# reject_if_any_rejection — refuse the fields-file (exit 2) with every
# rejection the checks above recorded.
reject_if_any_rejection() {
	[ -s "$REJECTIONS" ] || return 0
	usage >&2
	cat "$REJECTIONS" >&2
	exit 2
}

ROUND=$(jq -r '.round' "$OPT_FIELDS_FILE") || {
	error "failed to read the round number from --fields-file: $OPT_FIELDS_FILE"
	exit 1
}

# ---------------------------------------------------------------------------
# Round history may only grow FORWARD: no duplicate, and nothing older than
# what is already recorded (appending round 2 after round 7 would make
# rounds[] disagree with its own documented ordering, and any
# addressed_in_round pointing at the newest round would then outrun it).
#
# Both checks CAPTURE jq's answer into a variable and branch on the value.
# `if jq -e …; then error; fi` would be fail-OPEN: a jq failure (bad argument,
# non-array .rounds, runtime error) is indistinguishable from "not a
# duplicate", and the script would append anyway. Capturing makes a jq failure
# a reported failure instead.
#
# Both COMPARISONS also happen inside jq, never with shell `[ … -le … ]`: a
# round number that clears the schema (1e30, a 20-digit integer) is not
# guaranteed to fit a machine int, and POSIX `test` ERRORS on such an operand
# — which the enclosing `if` then reads as a passed check, failing open. jq
# compares JSON numbers natively. MAX_ROUND is read separately for the
# diagnostic only; the DECISION is jq's.
# ---------------------------------------------------------------------------
ROUND_IS_DUPLICATE=$(jq -r --argjson round "$ROUND" '([.rounds[].round] | index($round)) != null' "$OPT_JSON_FILE") || {
	error "failed to read the recorded round numbers from $OPT_JSON_FILE"
	exit 1
}

if [ "$ROUND_IS_DUPLICATE" = "true" ]; then
	error "round $ROUND already exists in $OPT_JSON_FILE"
	exit 1
fi

# The precondition above proved rounds[] non-empty with an integer round on
# every entry, so this max is always a number — no `// 0` fallback, which
# would have turned an unreadable max into a silently permissive 0.
MAX_ROUND=$(jq -r '[.rounds[].round] | max' "$OPT_JSON_FILE") || {
	error "failed to read the newest recorded round number from $OPT_JSON_FILE"
	exit 1
}

# Asserted POSITIVELY ("must be affirmatively newer") so any answer other
# than jq's own literal `true` — including one this script did not anticipate
# — stops the append rather than permitting it.
ROUND_IS_NEWER=$(jq -r --argjson round "$ROUND" '$round > ([.rounds[].round] | max)' "$OPT_JSON_FILE") || {
	error "failed to compare round $ROUND against the newest recorded round in $OPT_JSON_FILE"
	exit 1
}

if [ "$ROUND_IS_NEWER" != "true" ]; then
	error "round $ROUND is not newer than the newest recorded round ($MAX_ROUND) in $OPT_JSON_FILE; rounds must be appended in ascending order"
	exit 1
fi

# The speculative list (lib/review-aggregates.jq, section 3). Its own check,
# after the shape check, so the shape headline above keeps meaning exactly
# round/reviewers/findings.
check_fields_file "--fields-file has an invalid speculative list — see $PROG --help" \
	'speculative_problems(fields_proof_forms)'

# The handoffs (section 6): a new handoff, or an entry with index ruling the
# stored open handoff at that 1-based place. A filed handoff names a finding
# the artifact holds after this round.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file has an invalid handoffs list — see $PROG --help" \
	'([$artifact.findings[].id] + [.findings[] | objects | .id | strings] | unique) as $finding_ids
	 | handoffs_problems($artifact.handoffs // []; $finding_ids; fields_proof_forms)'

# ---------------------------------------------------------------------------
# One entry per finding per round: a string id may appear in at most one
# findings entry, NEW or UPDATE alike — the same rule review-create.sh
# enforces. Classification below looks an id up only in the artifact's
# CURRENT findings, so two entries sharing a not-yet-recorded id would BOTH
# pass as NEW and the merge would then apply the second onto the first (a HIGH
# finding silently replaced by a LOW one); two UPDATEs to one id would apply
# in order, the last silently winning.
#
# A cross-entry rule, so it cannot live in the per-entry predicate below,
# which judges each entry alone. It is reported FIRST of the finding checks
# because a repeated id makes the merge apply one entry onto another, so the
# later lines about those entries read in its light. Non-string ids are left
# to the per-entry check.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_STRING_ID_DEFS='
def string_id_entries:
  [.findings | to_entries[]
   | select((.value | type) == "object" and (.value.id | type) == "string")
   | {index: .key, id: .value.id}];
'

JQ_VALIDATE_UNIQUE_IDS="$JQ_STRING_ID_DEFS"'
string_id_entries | map(.id) | (unique | length) == length
'

# One line per repeated id, naming every entry that carries it.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_DUPLICATE_IDS="$JQ_VALUE_DEFS$JQ_STRING_ID_DEFS"'
string_id_entries
| group_by(.id)[]
| select(length > 1)
| (map(.index) | sort | map("findings[\(.)]")) as $refs
| "  \($refs[:-1] | join(", ")) and \($refs[-1]) share id \(.[0].id | shown) — each id may appear at most once per fields file"
'

if ! jq -e "$JQ_VALIDATE_UNIQUE_IDS" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	report_fields_file_rejection \
		"--fields-file repeats a finding id — one entry per finding per round (see $PROG --help)" \
		"$JQ_DIAGNOSE_DUPLICATE_IDS" 2>>"$REJECTIONS"
fi

# ---------------------------------------------------------------------------
# Per-entry validation: an entry is a NEW finding (full shape, only
# status/first_seen defaultable) or an UPDATE to an existing finding (id
# must match; any subset of the other fields, but each given value must be
# well-formed if present). Classification is by id membership in the
# artifact's CURRENT findings — never a caller-set flag.
# ---------------------------------------------------------------------------
EXISTING_IDS=$(jq -c '[.findings[].id]' "$OPT_JSON_FILE")

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_ENTRY_DEFS='
# optional_ok: an update-branch field is well-formed if the KEY IS ABSENT
# ("not given" — left untouched by the merge) OR its value passes `ok`.
# Deliberately keyed on has($key), never on ($e[$key] == null): an entry
# that explicitly sets a key to null (e.g. "fix": null) still HAS that key,
# so it must still pass `ok` — otherwise an explicit null slips through
# validation and pick_known() merges the literal null onto the persisted
# finding.
def optional_ok($e; $key; ok):
  ($e | has($key) | not) or ($e[$key] | ok);

# An entry is an UPDATE only when its id is a STRING already in the artifact.
# The type guard matters because `index` treats an ARRAY id as a subsequence
# to search for, so ["SEC-001"] would otherwise be "found".
def is_update_entry($e):
  ($e.id | type == "string") and ($existing_ids | index($e.id)) != null;

# Keys outside field_keys, in the order the entry lists them. The merge would strip
# them, so a misspelled key ("Status", "tracked-status") would turn the
# intended change into a silent no-op reported as success. A non-object entry
# has none; the NEW/UPDATE branches already reject it.
def unknown_keys($e):
  if ($e | type) == "object" then ($e | keys_unsorted) - field_keys else [] end;

# An addressed_in_round may cite THIS round (the fix was verified by the
# round being appended right now) but never a round that has not run — the
# bound is $round, which the monotonicity check above already proved to be
# the newest round in existence.
def is_round_that_has_run: is_addressed_in_round and . <= $round;

# addressed_in_round must be OMITTED while tracked_status is PENDING or
# IN_PROGRESS (review-artifact.schema.json). A caller asserting both at once
# in the SAME entry is contradicting itself — reject rather than silently
# drop the value they supplied, mirroring the reject-both-set behavior
# review-update-status.sh already has for the identical combination.
def contradicts_addressed_in_round($e):
  ($e.tracked_status // null) as $ts
  | ($ts == "PENDING" or $ts == "IN_PROGRESS") and ($e | has("addressed_in_round"));
'

# The predicate alone, so the diagnostic below can run it inside its own
# program (an include may only lead a program, never sit inside one).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_ENTRIES_PREDICATE='
.findings | all(.[];
  . as $e
  | if is_update_entry($e) then
      # first_seen is deliberately NOT validated here: an update entry can
      # never change the first_seen already on an existing finding
      # (pick_known_update below excludes the key from the merge entirely),
      # so any value the caller supplies is inert and there is nothing to
      # validate.
      ($e.id != null and ($e.id | is_nonempty_string))
      and optional_ok($e; "status"; is_finding_status)
      and optional_ok($e; "tracked_status"; is_tracked_status)
      and optional_ok($e; "severity"; is_severity)
      and optional_ok($e; "locations"; is_one_line_text_array)
      and optional_ok($e; "reviewer"; is_nonempty_string)
      and optional_ok($e; "category"; is_review_category)
      and optional_ok($e; "problem"; is_nonempty_string)
      and optional_ok($e; "fix"; is_nonempty_string)
      and optional_ok($e; "addressed_in_round"; is_round_that_has_run)
      and optional_ok($e; "realism"; is_realism)
      and optional_ok($e; "trigger"; is_one_line_text)
      and optional_ok($e; "realism_reason"; is_short_one_line_text)
      and optional_ok($e; "relates_to"; is_relates_to)
      and optional_ok($e; "proof"; is_short_one_line_text)
      and optional_ok($e; "unproven"; is_unproven)
      and optional_ok($e; "resolution_proof"; is_short_one_line_text)
      and (contradicts_addressed_in_round($e) | not)
    else
      ($e.id != null and ($e.id | is_finding_id))
      and ($e.reviewer != null and ($e.reviewer | is_nonempty_string))
      and ($e.tracked_status != null and ($e.tracked_status | is_tracked_status))
      and ($e.severity != null and ($e.severity | is_severity))
      and ($e.category != null and ($e.category | is_review_category))
      and ($e.locations != null and ($e.locations | is_one_line_text_array))
      and ($e.problem != null and ($e.problem | is_nonempty_string))
      and ($e.fix != null and ($e.fix | is_nonempty_string))
      and optional_ok($e; "status"; is_finding_status)
      and optional_ok($e; "first_seen"; is_iso_date)
      and optional_ok($e; "addressed_in_round"; is_round_that_has_run)
      and optional_ok($e; "realism"; is_realism)
      and optional_ok($e; "trigger"; is_one_line_text)
      and optional_ok($e; "realism_reason"; is_short_one_line_text)
      and optional_ok($e; "relates_to"; is_relates_to)
      and optional_ok($e; "proof"; is_short_one_line_text)
      and optional_ok($e; "unproven"; is_unproven)
      and optional_ok($e; "resolution_proof"; is_short_one_line_text)
      and (contradicts_addressed_in_round($e) | not)
    end
  and (unknown_keys($e) == [])
)
'
JQ_VALIDATE_ENTRIES="$JQ_VALUE_DEFS$JQ_ENTRY_DEFS$JQ_ENTRIES_PREDICATE"

# Which entries to report is decided by re-running JQ_ENTRIES_PREDICATE itself
# on each entry alone (exact: the predicate is an all() over entries), so
# every rejected entry is named and no accepted one is. The field checks
# below only supply the reasons; an entry they cannot explain still gets a
# line.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_ENTRIES="$JQ_VALUE_DEFS$JQ_ENTRY_DEFS"'
def entry_passes: {findings: [.]} | (
'"$JQ_ENTRIES_PREDICATE"'
);

def field_ok($key; $is_update):
  if $key == "id" then (if $is_update then is_nonempty_string else is_finding_id end)
  elif $key == "severity" then is_severity
  elif $key == "tracked_status" then is_tracked_status
  elif $key == "status" then is_finding_status
  elif $key == "locations" then is_one_line_text_array
  elif $key == "first_seen" then is_iso_date
  elif $key == "addressed_in_round" then is_round_that_has_run
  elif $key == "realism" then is_realism
  elif $key == "trigger" then is_one_line_text
  elif $key == "realism_reason" or $key == "proof" or $key == "resolution_proof" then is_short_one_line_text
  elif $key == "relates_to" then is_relates_to
  elif $key == "unproven" then is_unproven
  elif $key == "category" then is_review_category
  else is_nonempty_string end;

def not_one_of($key; $allowed): "\($key) \(shown) is not one of \($allowed | join(" | "))";

def addressed_in_round_problem:
  if (type == "number" and floor == .) | not then "addressed_in_round must be an integer\(got)"
  elif . < 1 then "addressed_in_round \(.) is below the minimum of 1"
  else "addressed_in_round \(.) is above the maximum of \($round) (the round being appended)" end;

def field_problem($key; $is_update):
  if $key == "id" and $is_update then "id must be a non-empty string\(got)"
  elif $key == "id" then "id \(shown) does not match the id format (uppercase letters, a hyphen, 3+ digits, e.g. SEC-001)"
  elif $key == "severity" then not_one_of($key; severity_values)
  elif $key == "tracked_status" then not_one_of($key; tracked_status_values)
  elif $key == "status" then not_one_of($key; finding_status_values)
  elif $key == "locations" then one_line_array_problems($key)
  elif $key == "first_seen" then "first_seen must be a YYYY-MM-DD date string\(got)"
  elif $key == "addressed_in_round" then addressed_in_round_problem
  elif $key == "realism" then not_one_of($key; realism_values)
  elif $key == "trigger" then "trigger \(one_line_rule)\(got)"
  elif $key == "realism_reason" or $key == "proof" or $key == "resolution_proof" then "\($key) \(short_one_line_rule)\(got)"
  elif $key == "relates_to" then "relates_to \(relates_to_rule)\(got)"
  elif $key == "unproven" then "unproven must be true when given (omit it otherwise)\(got)"
  elif $key == "category" then "category \(review_category_rule)\(got)"
  else "\($key) must be a non-empty string\(got)" end;

# Mirrors the NEW / UPDATE branches of JQ_VALIDATE_ENTRIES: NEW requires the
# first eight keys; UPDATE requires only id and ignores first_seen.
def entry_problems($e; $is_update):
  (unknown_keys($e)[]
   | if IN(human_only_confirmation_keys[]) then human_only_confirmation_rule
     else "unknown field \(shown) (known fields: \(core_field_keys | join(", "))) (realism fields: \(realism_field_keys | join(", ")))" end),
  (["id","reviewer","tracked_status","severity","category","locations","problem","fix",
    "status","first_seen","addressed_in_round","realism","trigger","realism_reason",
    "relates_to","proof","unproven","resolution_proof"][] as $key
   | select(($is_update and $key == "first_seen") | not)
   | (if $is_update then $key == "id"
      else (["status","first_seen","addressed_in_round","realism","trigger","realism_reason",
             "relates_to","proof","unproven","resolution_proof"] | index($key)) == null end) as $required
   | if $e[$key] == null then
       (if $required or ($e | has($key)) then presence_problem($e; $key) else empty end)
     else $e[$key] | select(field_ok($key; $is_update) | not) | field_problem($key; $is_update)
     end),
  (select(contradicts_addressed_in_round($e))
   | "addressed_in_round must be omitted while tracked_status is \($e.tracked_status | shown)");

def classification($e; $is_update):
  if ($e | has("id")) | not then "NEW (no id given)"
  elif ($e.id | type) != "string" then "NEW (id is not a string)"
  elif $is_update then "UPDATE (id already in artifact)"
  else "NEW (id not in artifact)" end;

.findings
| to_entries[]
| .key as $index
| .value as $e
| select((try ($e | entry_passes) catch false) | not)
| if ($e | type) != "object" then "findings[\($index)] is not a JSON object (got \($e | shown))"
  else
    is_update_entry($e) as $is_update
    | (if $e | has("id") then "id \($e.id | shown)" else "(no id)" end) as $label
    | [entry_problems($e; $is_update)] as $problems
    | (if $problems == [] then ["failed validation (no specific reason identified)"] else $problems end)[]
    | "findings[\($index)] \($label) — \(classification($e; $is_update)): \(.)"
  end
| "  " + .
'

if ! jq -e --argjson existing_ids "$EXISTING_IDS" --argjson round "$ROUND" \
	"$JQ_VALIDATE_ENTRIES" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	report_fields_file_rejection \
		"--fields-file has an invalid finding entry (see $PROG --help for the new-vs-update shape)" \
		--argjson existing_ids "$EXISTING_IDS" --argjson round "$ROUND" "$JQ_DIAGNOSE_ENTRIES" 2>>"$REJECTIONS"
fi

# An UPDATE never changes the reviewer: the finding stays with the seat that
# raised it, and so under the security floor once it is there.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file changes a finding's reviewer — see $PROG --help" \
	'.findings | list_entries | .key as $index | .value | objects | . as $e
	 | select(has("reviewer"))
	 | ([$artifact.findings[] | select(.id == $e.id)] | first) as $stored
	 | select($stored != null and $stored.reviewer != $e.reviewer)
	 | "findings[\($index)] id \($e.id | shown) — reviewer cannot change on an update (stored: \($stored.reviewer | shown))"'

# A category is one of its reviewer's own vocabulary (lib/review-aggregates.jq,
# section 3): an UPDATE's reviewer is the stored one. A category outside
# every vocabulary is the entry check's.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file gives a category outside its reviewer's vocabulary — see $PROG --help" \
	'.findings | list_entries | .key as $index | .value | objects | . as $e
	 | select(has("category") and (.category | is_review_category))
	 | ($e.reviewer // ([$artifact.findings[] | select(.id == $e.id)] | first | .reviewer)) as $reviewer
	 | select(.category | is_reviewer_category($reviewer) | not)
	 | "findings[\($index)] id \($e.id | shown) — category \(reviewer_category_rule($reviewer))"'

# ACK is the human's waiver, recorded through review-update-status.sh; a
# report repeats it only on a finding already ACK.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file sets a finding ACK — see $PROG --help" \
	'.findings | list_entries | .key as $index | .value | objects | . as $e
	 | select(.status == "ACK")
	 | ([$artifact.findings[] | select(.id == $e.id)] | first) as $stored
	 | select($stored == null or $stored.status != "ACK")
	 | "findings[\($index)] id \($e.id | shown) — \(report_ack_rule)"'

# A security concern is filed under a security category (lib/review-aggregates.jq,
# section 4).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file files a security concern under a category that is not a security one — see $PROG --help" \
	'misfiled_security_problems($artifact.findings)'

# An item under the security floor stays there (lib/review-aggregates.jq,
# header WHY).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file takes an item out from under the security floor — see $PROG --help" \
	'floored_item_problems($artifact.findings; [$artifact.rounds[] | .speculative | arrays | .[]])'

# Diff scope (see the header WHY; lib/review-aggregates.jq, section 5). A
# location that is not a string counts as outside, beside the entry check's
# own line for it.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file cites locations outside the diff (--diff-files)" \
	'out_of_diff_problems($diff_files; $artifact.findings; $plan_review)' \
	"a NEW finding, a location an update adds, a speculative entry and a new handoff name a file in the diff, or carry their own relates_to on the changed code that relies on or exposes it; out-of-diff observations belong in the report notes as pre-existing"

# Every relates_to points at changed lines (section 5).
if jq -e "$JQ_AGGREGATES"'fields_file_has_relates_to' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	if [ -n "$OPT_DIFF_HUNKS" ]; then
		# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
		check_fields_file "--fields-file gives a relates_to off the changed lines (--diff-hunks)" \
			'off_hunk_relates_to_problems($hunks)'
	else
		error "--diff-hunks is required: the fields-file gives a relates_to (diff-scope.sh's diff-hunks.tsv)" 2>>"$REJECTIONS"
	fi
fi

# Evidence (section 3): every finding entry judged as it will be stored (an
# UPDATE merged onto its stored finding, as the merge below does), under the
# security floor when the stored or the merged finding is under it; see the
# header WHY. Speculative entries were judged with the speculative list.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file sets aside a finding without its evidence (proof or unproven) — see $PROG --help" \
	'.findings | list_entries | .key as $index | .value | objects | . as $e
	 | ([$artifact.findings[] | select(.id == $e.id)] | first) as $stored
	 | select($stored == null or ($e | gives_evidence) or ($e | has("category")))
	 | (if $stored == null then $e else $stored | updated_finding($e) end)
	 | finding_evidence_problems(if $e | has("proof") then fields_proof_forms else carried_proof_forms end;
	                             is_security_concern or ($stored != null and ($stored | is_security_concern)))
	 | "findings[\($index)] id \($e.id | shown) — \(.)"'

# A resolution is verified against this round's diff (see the header WHY).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file sets a carried finding RESOLVED in a round whose diff (--diff-files) does not cover it" \
	'unverified_resolution_problems($diff_files; $artifact.findings; $plan_review)'

# A RESOLVED entry carries its resolution_proof (see the header WHY).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file sets a finding RESOLVED without its resolution_proof — see $PROG --help" \
	'resolution_proof_problems($artifact.findings; fields_proof_forms)'

# Every proof points at something real: each file:line locator a file and
# line under --repo-root, and in a test-plan review each test number a test
# of --plan.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PROOF_LOCATORS=$(jq -r "$JQ_AGGREGATES"'[fields_file_proofs] | proof_locator_lines' "$OPT_FIELDS_FILE") || {
	error "failed to read the proofs in --fields-file"
	exit 1
}
if [ -z "$PHYSICAL_REPO_ROOT" ] && jq -e "$JQ_AGGREGATES"'[fields_file_proofs] != []' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	error "--repo-root is required: the fields-file gives a proof (its file:line locators resolve under the repo root)" 2>>"$REJECTIONS"
	PROOF_LOCATORS=""
fi
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PROOF_TEST_PROBLEMS=$(jq -r --argjson plan_review "$PLAN_REVIEW" --argjson test_count "$PLAN_TEST_COUNT" "$JQ_AGGREGATES"'
	[fields_file_proofs] | (if $plan_review then proof_test_problems($test_count) else empty end)' "$OPT_FIELDS_FILE") || {
	error "failed to read the proofs in --fields-file"
	exit 1
}
PROOF_PROBLEMS=$(
	printf '%s\n' "$PROOF_TEST_PROBLEMS"
	printf '%s\n' "$PROOF_LOCATORS" | sed '/^$/d' | proof_locator_problems
)
PROOF_PROBLEMS=$(printf '%s\n' "$PROOF_PROBLEMS" | sed '/^$/d')
if [ -n "$PROOF_PROBLEMS" ]; then
	{
		error "--fields-file has a proof that points at nothing real:"
		printf '%s\n' "$PROOF_PROBLEMS" | sed 's/^/  /' >&2
	} 2>>"$REJECTIONS"
fi

reject_if_any_rejection

# The key of every speculative entry this round records, and of every stored
# one without a key.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
if ! jq -r -n --slurpfile fields_arr "$OPT_FIELDS_FILE" --slurpfile artifact_arr "$OPT_JSON_FILE" "$JQ_AGGREGATES"'
	[($fields_arr[0] | fields_file_speculative_key_inputs), ($artifact_arr[0] | unkeyed_speculative_key_inputs)]
	| unique[]' >"$KEY_INPUTS"; then
	error "failed to read the speculative entries"
	exit 1
fi
# shellcheck disable=SC2310  # speculative_key_map returns an explicit status at every step; set -e is not relied on inside it
speculative_key_map "$KEY_INPUTS" "$KEY_MAP" || {
	error "cannot compute the speculative keys (install shasum, sha256sum, or openssl)"
	exit 1
}

TODAY=$(date -u +%Y-%m-%d)

# ---------------------------------------------------------------------------
# Merge + recompute, all in one static jq program. `pick_known_by_keys`
# restricts an entry to an explicit key allow-list — defense in depth behind
# the validator's unknown-key rejection, so a stray key can never leak into
# the artifact. Two allow-lists, both DERIVED from the shared `field_keys`
# (JQ_FIELD_KEYS_DEF, also read by the validator) so a future schema field can
# never be added to one and silently stripped by the other:
#
#   pick_known_new()    — a brand-new finding: first_seen IS a legal key
#                          (caller-settable, defaulted below if absent).
#   pick_known_update() — an update to an EXISTING finding: field_keys MINUS
#                          first_seen, full stop. first_seen is "frozen at
#                          creation" per software-development/contracts/review-artifact.schema.json
#                          — an update entry must never be able to overwrite
#                          it, regardless of what value it supplies. This
#                          mirrors review-create.sh's own precedent of never
#                          trusting a caller for a field that is fixed at a
#                          specific lifecycle point.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_MERGE="$JQ_AGGREGATES$JQ_FIELD_KEYS_DEF"'
def pick_known_by_keys($e; $keys):
  $e
  | to_entries
  | map(select(.key as $k | ($keys | index($k)) != null))
  | from_entries;
def pick_known_new($e):
  pick_known_by_keys($e; field_keys);
def pick_known_update($e):
  pick_known_by_keys($e; field_keys - ["first_seen"]);

# What a re-check and an edge-case confirmation judged: an update that
# changes any of it takes both with it.
def judged_evidence: {locations, problem, trigger, realism: (.realism // "realistic"), proof, unproven, relates_to, category};
def drop_stale_judgements($stored):
  if judged_evidence == ($stored | judged_evidence) then .
  else del(.recheck, .realism_confirmed, .realism_confirmed_severity) end;

# Input: the findings array. Output: that array with $e either merged onto the
# finding sharing its id, or appended as a brand-new finding.
def upsert_finding($e):
  (if any(.[]; .id == $e.id)
   then map(if .id == $e.id
            then . as $stored | drop_resupplied_evidence($e) + pick_known_update($e) | drop_stale_judgements($stored)
            else . end)
   else . + [ (pick_known_new($e)
               | .status = (.status // "NEW")
               | .first_seen = (.first_seen // $today)) ]
   end)
  # addressed_in_round must be OMITTED while tracked_status is PENDING or
  # IN_PROGRESS (review-artifact.schema.json). The validation above rejects
  # an entry that sets both explicitly in the SAME call; this normalizes the
  # other route to the same invalid state — an update that moves
  # tracked_status to PENDING/IN_PROGRESS without touching addressed_in_round,
  # leaving a stale value from an earlier round sitting alongside it.
  | map(if (.tracked_status // null) as $ts | ($ts == "PENDING" or $ts == "IN_PROGRESS")
        then del(.addressed_in_round)
        else . end)
  # An update that reclassifies a confirmed edge case away from edge-case, or
  # changes its severity, takes the human confirmation with it; a finding
  # moved off RESOLVED takes its resolution_proof with it, and one moved off
  # ACK the ack_reason the human gave.
  | map(drop_stale_confirmation)
  | map(if .status == "RESOLVED" then . else del(.resolution_proof) end)
  | map(if .status == "ACK" then . else del(.ack_reason) end);

# A finding carried over from an earlier round is no longer "first reported
# this round" — see the header WHY block on the NEW -> OPEN flip.
def carried_over: if .status == "NEW" then .status = "OPEN" else . end;
$fields_arr[0] as $fields
| $key_map_arr[0] as $keys
| (reduce $fields.findings[] as $e
     ((.findings | map(carried_over)); upsert_finding($e))
  ) as $merged_findings
| .findings = $merged_findings
| keyed_speculative_rounds($keys)
| .rounds += [ { round: $fields.round, generated: $today, reviewers: $fields.reviewers,
                 diff_files: $diff_files_arr[0] }
               + speculative_round_fields($fields; $keys) ]
| .last_updated = $today
| .diff_files = cumulative_diff_files(.diff_files; $diff_files_arr[0])
| merged_handoffs(.handoffs // []; $fields.handoffs // []) as $handoffs
| (if $handoffs == [] then del(.handoffs) else .handoffs = $handoffs end)
| stamp_artifact_security_floor
| (summary(.findings)) as $sum
| .summary = $sum
| .overall_verdict = verdict($sum)
'

TARGET_DIR=$(dirname "$OPT_JSON_FILE")
TMP_FILE=$(mktemp "$TARGET_DIR/.tmp.$(basename "$OPT_JSON_FILE").XXXXXX")

if ! jq --arg today "$TODAY" --slurpfile fields_arr "$OPT_FIELDS_FILE" --slurpfile key_map_arr "$KEY_MAP" \
	--slurpfile diff_files_arr "$DIFF_FILES_JSON" "$JQ_MERGE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to merge the new round into the review artifact"
	exit 1
fi

# Two speculative entries never share a key (section 2).
KEY_PROBLEMS=$(jq -r "$JQ_AGGREGATES"'speculative_key_collision_problems' "$TMP_FILE") || {
	error "failed to check the speculative keys"
	exit 1
}
[ -z "$KEY_PROBLEMS" ] || usage_error "--fields-file: $KEY_PROBLEMS"

# Advisory-only, never fatal: warn when an entry explicitly supplied
# addressed_in_round but upsert_finding's post-merge normalization (above)
# silently cleared it because that finding's resulting tracked_status is
# PENDING/IN_PROGRESS. The SAME-call combination is rejected loudly by the
# validation above; this is the OTHER route to the same invalid state — the
# finding was already PENDING/IN_PROGRESS before this call, so the caller's
# freshly-supplied value is discarded rather than rejected. The artifact
# stays schema-valid either way; this just tells the caller their value
# didn't stick.
DROPPED_ADDRESSED_IDS=$(jq -nr --slurpfile fields_arr "$OPT_FIELDS_FILE" --slurpfile merged "$TMP_FILE" '
  ($fields_arr[0].findings // []) as $entries
  | ($merged[0].findings // []) as $mf
  | [$entries[] | select(has("addressed_in_round")) | .id] as $claimed
  | [$mf[] | select(has("addressed_in_round") | not) | .id] as $missing
  | (($claimed - ($claimed - $missing)) | unique)[]
') || DROPPED_ADDRESSED_IDS=""

if [ -n "$DROPPED_ADDRESSED_IDS" ]; then
	printf '%s\n' "$DROPPED_ADDRESSED_IDS" | while IFS= read -r dropped_id; do
		[ -n "$dropped_id" ] || continue
		warn "addressed_in_round supplied for $dropped_id was dropped — tracked_status is PENDING/IN_PROGRESS on that finding (review-artifact.schema.json forbids the combination)"
	done
fi

# 0666 masked by the caller's own umask — never a forced 644, which would
# silently widen a deliberately-restrictive umask (see review-create.sh's
# header WHY block for why a review artifact is not treated as a secret).
CALLER_UMASK=$(umask)
FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$CALLER_UMASK ))")

if ! chmod "$FILE_MODE" "$TMP_FILE"; then
	error "failed to set mode $FILE_MODE on the staged artifact: $TMP_FILE"
	exit 1
fi

if ! mv "$TMP_FILE" "$OPT_JSON_FILE"; then
	error "failed to publish the updated artifact to: $OPT_JSON_FILE"
	exit 1
fi
TMP_FILE=""

# The sibling render is now stale: this script writes JSON only. Naming the
# path is what stops a caller from forgetting to re-render it.
printf 'REVIEW_JSON=%s\n' "$OPT_JSON_FILE"
printf 'REVIEW_MD=%s\n' "${OPT_JSON_FILE%.json}.md"
exit 0
