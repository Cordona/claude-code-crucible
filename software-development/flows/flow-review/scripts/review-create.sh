#!/usr/bin/env sh
#
# review-create.sh — create a NEW flow-review durable artifact (JSON) for one
#                     repo, at round 1. Refuses to overwrite an existing file.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §5c). The
# mkdir-lock dance capture.sh/process.sh need to protect a SHARED append-only
# log doesn't apply here. The only race this script actually guards is "does
# the target file already exist", and it guards it ATOMICALLY rather than by
# check-then-act: the early `[ -e ]` test is a fast, friendly diagnostic, but
# the authority is the O_EXCL claim on the destination (`set -C` noclobber)
# taken immediately before the publish. A concurrent creator that loses that
# claim gets a loud failure, never a silent overwrite.
#
# WHY findings' status/tracked_status/first_seen are ALWAYS decided here,
# never trusted from the caller: round 1 findings are, by definition, brand
# new. Accepting a caller-supplied status/tracked_status/first_seen would let
# a fields-file silently fabricate history (e.g. claim a finding was already
# RESOLVED before round 1 ever ran). Every finding is reconstructed field by
# field from the validated input — never passed through verbatim — which
# also keeps additionalProperties:false honest regardless of what extra keys
# a caller's finding entry carried.
#
# WHY review artifacts get no chmod 600/700 (unlike the GTD inbox): the GTD
# log is a private, personal capture stream under $HOME; a review artifact is
# an ordinary versioned repo document meant to be read (and likely committed)
# like any other doc under .crucible/docs/ — treating it as a secret would be
# wrong. The published mode is therefore 0666 masked by the CALLER'S OWN
# umask (0644 under the usual 022, tighter under a tighter umask) — never a
# forced 644, which would silently widen a deliberately-restrictive umask.
#
# WHY --diff-files, and --diff-hunks with a relates_to: a review covers the
# diff, and a finding is scoped by its effect on it. Every finding,
# speculative and handoff location names a file in the list diff-scope.sh
# wrote, or is anchored by its entry's relates_to — one location of the
# changed code that relies on or exposes the defect, its line or whole range
# inside one hunk the diff changed (diff-hunks.tsv); a fields-file citing
# any other file is rejected whole. The list is stored as the artifact's diff_files — as {path, sha}
# objects when given diff-files.tsv, so a later pass can tell which files
# are unchanged since this review.
#
# WHY an item set aside must carry its evidence, and the evidence must
# exist: an edge-case finding and every speculative entry give exactly one of
# proof (one line naming what shows it is rare or harmless) or unproven:
# true, so a dismissal without proof is visible as one. Under the security
# floor (lib/review-aggregates.jq, header WHY) only proof is accepted. A
# proof names a file:line whose file is a regular file under --repo-root
# and whose line is within it, or — in a test-plan review — a test number
# of the plan given as --plan; a reviewer has no shell, so a "ran ..." proof
# is recorded only through review-update-status.sh.
#
# WHY every category is checked against the vocabulary: the security floor
# turns on the category (contracts/review-category.schema.json), so one
# outside the reviewer's own vocabulary (x-reviewers; the union of every
# vocabulary for a reviewer it does not list) is rejected rather than read
# as not security. An item under the floor is recorded security_floor: true,
# so the later writers keep it there. A finding whose problem or trigger, or
# a speculative entry whose concern, names a security weakness
# (lib/security-terms.jq) is refused under a category that is not a security
# one, so a misfiled security concern cannot slip out from under the floor.
#
# WHY a report never sets ACK: ACK is the human's waiver, recorded through
# review-update-status.sh --status ACK, and a round-1 finding has never been
# waived. A finding entry giving status ACK is refused rather than stored
# NEW.
#
# WHY every rejection class is reported in one run: once the fields-file has
# its basic shape, each check runs and records its rejections, and the
# fields-file is refused after the last one, so a category error never hides
# a proof that points at nothing.
#
# WHY each speculative entry gets a key: the entry has no id, and a
# positional number moves when rounds add entries. Its key — the first 12
# hex digits of the SHA-256 of reviewer|location|concern — is the same in
# every round that repeats it, and is what render-md.sh's item map and
# review-update-status.sh --speculative-key name it by.
#
# WHY --plan-review: the same artifact records the review of a flow-testing
# test plan, whose findings are located in the plan as plan:<item>
# (plan:test-3, plan:not_tested-1, plan:B2). With the flag such a locator is
# in scope without naming a diff file, a proof may name a test of the plan
# (resolved against --plan), and the artifact is marked plan_review: true so
# review-add-round.sh and review-update-status.sh treat it the same way.
#
# Usage: see --help.
#
# Output:
#   On success, stdout carries the machine-parseable key:
#     REVIEW_JSON=<absolute path>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  created
#   1  jq absent / no SHA-256 tool (shasum, sha256sum, openssl) when the
#      fields-file has speculative entries / mkdir or write failed /
#      artifact already exists / the output directory escapes --repo-root
#   2  usage error (missing/invalid argument, invalid --repo-root/--slug,
#      malformed or structurally invalid --fields-file, a category outside
#      the vocabulary, a security concern (x-security-terms) under a
#      category that is not a security one, a finding giving status ACK, an
#      item set aside without its evidence, a proof that
#      names no real file line or no test of the plan, an invalid handoff, an
#      empty --diff-files, a location outside the diff that no in-diff
#      relates_to anchors, a relates_to off the changed lines, an invalid
#      --diff-hunks, --plan or --snapshot, two speculative entries sharing a
#      key)
#
# Env:
#   TMPDIR — optional; selects the directory of the private copies of the
#   inputs (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (awk, cat, chmod, date, mkdir, mktemp, mv, rm) are assumed
#   present, plus one of shasum, sha256sum or openssl for the speculative
#   keys. Reads lib/review-aggregates.jq, lib/security-terms.jq and
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
Usage: $PROG --repo-root PATH --slug SLUG --fields-file PATH
       --diff-files PATH [--diff-hunks PATH] [--snapshot SHA]
       [--plan-review [--plan PATH]] [-h|--help]

Create a new flow-review durable artifact (round 1) for one repo, at
{repo-root}/.crucible/docs/reviews/{YYYY}/{MM}/{DD}/{slug}.json. Refuses to
overwrite an existing artifact.

Options:
  --repo-root PATH    Repo root the artifact is written under, and the root
                        every proof locator resolves under (required).
  --slug SLUG         Artifact id and file name; lowercase, hyphen-separated
                        (required).
  --fields-file PATH  ONE JSON object describing round 1 (required):
                        repo        non-empty string
                        spec_ref    optional non-empty string
                        reviewers   non-empty array of non-empty strings
                        findings    array (may be []) of {id (e.g. SEC-001;
                                    unique), reviewer, severity
                                    CRITICAL|HIGH|MEDIUM|LOW, category,
                                    locations (one-line strings), problem,
                                    fix}, each optionally with realism
                                    realistic|edge-case (absent: realistic),
                                    trigger, realism_reason, relates_to,
                                    and proof or unproven: true
                        speculative optional array of {reviewer, location,
                                    concern, why_speculative, category},
                                    each optionally with real_if and
                                    relates_to, and with proof or
                                    unproven: true
                        handoffs    optional array of {from, to, concern,
                                    location, ruling open|filed|rejected|
                                    out-of-scope}, optionally relates_to,
                                    with proof unless open and filed_as (a
                                    finding id here) when filed
                      status, tracked_status and first_seen are decided
                      here (status ACK, the human's waiver, is rejected);
                      realism_confirmed*, recheck, ack_reason,
                      promoted_to, security_floor and a speculative key
                      are rejected (the human's, or the writer's), and so
                      is a handoff ruled waived (the human's, via
                      review-update-status.sh).
  --diff-files PATH   diff-scope.sh's diff-files.tsv or diff-files.txt
                        (required). Every finding, speculative and handoff
                        location names a file in it, or its own entry's
                        relates_to does; out-of-diff observations nothing in
                        the diff relies on belong in the report notes as
                        pre-existing. Stored as diff_files.
  --diff-hunks PATH   diff-scope.sh's diff-hunks.tsv (required when an entry
                        gives relates_to): every relates_to, a line or a
                        whole range, lies inside one hunk the diff changed.
  --snapshot SHA      The diff-scope.sh --snapshot-out tree sha the diff was
                        taken since (optional); stored as snapshot.
  --plan-review       A test-plan review: plan:<item> locations (plan:test-3,
                        plan:not_tested-1, plan:B2) are in scope without
                        naming a diff file, and a proof may name a test of
                        the plan; stored as plan_review: true.
  --plan PATH         With --plan-review: the test plan under review
                        (required when a proof names a test number).
  -h, --help          Show this help.

Text rules: category is one from the reviewer's own vocabulary in
contracts/review-category.schema.json (x-reviewers; the union of every
vocabulary for a reviewer it does not list);
realism_reason, real_if and proof are one line of at most 100 characters,
and relates_to at most 300, with no control or invisible format character
(bidi, zero-width, soft hyphen, variation selector, tag). relates_to is ONE
file:LINE[-END] location whose line or whole range lies inside one hunk the
diff changed.

Evidence: an edge-case finding and every speculative entry give exactly one
of proof or unproven: true; one from lens-security-reviewer, or in a
security category, gives proof. A proof names its evidence as a file:line
(src/a.rs:42, src/a.rs:42-50, Makefile:3; the file has an extension or a
"/", or is Makefile, Dockerfile, Justfile, Rakefile, Gemfile or Procfile)
that exists under --repo-root with that line, or in a test-plan review a
test of the plan (test 3); "ran ..." proofs are recorded only via
review-update-status.sh.

Security concerns: a finding whose problem or trigger, or a speculative
entry whose concern, names a security weakness of
contracts/review-category.schema.json (x-security-terms,
x-security-patterns) is rejected under a category that is not a security
one: the reviewer re-files it under one of its own security categories or,
if none fits, passes it to lens-security-reviewer as a handoff. Text is read
in clauses (split at . ; : , ! ? and a closing parenthesis) of whole
lowercase words, outside backtick code spans, an identifier holding "_" read
as one word. A weakness is named by: a term (sql injection, xss, path
traversal, ...), unless a mechanism word follows it (csrf token, sql
injection prevention) and no absence word (missing, not, disabled, bypassed,
only, ...) is in its clause; "injection" within 3 words of sql, command,
shell, ... but not after dependency, constructor, field, ...; an access
subject (auth*, login, password, role, admin, token, ...) with a bypass/skip
word in its clause, or followed by a mechanism word with an absence word in
its clause, unless what is skipped is a cache, lookup or other performance
object and no lost-access word (revoked, keeps, escalat*, ...) is there;
unauthenticated or unauthorized with reach, access or call; "../" with an
escape or traversal word, or a path joined unnormalized; text concatenated
or interpolated into a query, shell or command, or unescaped in one; a
token, secret or password compared with == or not in constant time; a
request treated as authenticated, or a default to admin; a revoked user
keeping access; a check that only verifies login while a clause says not the
role. An item from lens-test-quality-reviewer naming a security term,
auth*/unauth*, permission, access control, security, or a login, password or
credential check is filed as untested-security.

Every rejection class is checked and reported in one run once the
fields-file has its basic shape. An item under the security floor is
stored with security_floor: true.

On success, prints:
  REVIEW_JSON=<absolute path>

Exit codes:
  0  created
  1  jq absent / no SHA-256 tool / write failed / artifact already exists
  2  usage error (an invalid argument or input file, an invalid fields-file
     entry or category, a security concern under a category that is not a
     security one, a finding giving status ACK, missing or unreal evidence,
     an unanchored location outside the diff, a relates_to off the changed
     lines)
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
OPT_REPO_ROOT=""
OPT_SLUG=""
OPT_FIELDS_FILE=""
OPT_DIFF_FILES=""
OPT_DIFF_HUNKS=""
OPT_SNAPSHOT=""
OPT_PLAN=""
PLAN_REVIEW=false

while [ $# -gt 0 ]; do
	case "$1" in
		--repo-root)   need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--slug)        need_arg "$1" "${2:-}"; OPT_SLUG=$2; shift ;;
		--fields-file) need_arg "$1" "${2:-}"; OPT_FIELDS_FILE=$2; shift ;;
		--diff-files)  need_arg "$1" "${2:-}"; OPT_DIFF_FILES=$2; shift ;;
		--diff-hunks)  need_arg "$1" "${2:-}"; OPT_DIFF_HUNKS=$2; shift ;;
		--snapshot)    need_arg "$1" "${2:-}"; OPT_SNAPSHOT=$2; shift ;;
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

[ -n "$OPT_REPO_ROOT" ]   || usage_error "--repo-root is required"
[ -n "$OPT_SLUG" ]        || usage_error "--slug is required"
[ -n "$OPT_FIELDS_FILE" ] || usage_error "--fields-file is required"
[ -n "$OPT_DIFF_FILES" ]  || usage_error "--diff-files is required (diff-scope.sh's diff-files.tsv or diff-files.txt)"
[ -z "$OPT_PLAN" ] || [ "$PLAN_REVIEW" = true ] || usage_error "--plan is given only with --plan-review"

[ -d "$OPT_REPO_ROOT" ] || usage_error "--repo-root does not exist or is not a directory: $OPT_REPO_ROOT"

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

# The snapshot the diff was taken since: the full 40- or 64-hex tree sha
# diff-scope.sh --snapshot-out printed.
case "$OPT_SNAPSHOT" in
	*[!0-9a-f]*) usage_error "invalid --snapshot: $OPT_SNAPSHOT (expected the full 40- or 64-hex sha diff-scope.sh --snapshot-out printed)" ;;
	*) : ;;
esac
if [ -n "$OPT_SNAPSHOT" ] && [ "${#OPT_SNAPSHOT}" -ne 40 ] && [ "${#OPT_SNAPSHOT}" -ne 64 ]; then
	usage_error "invalid --snapshot: $OPT_SNAPSHOT (expected the full 40- or 64-hex sha diff-scope.sh --snapshot-out printed)"
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

PHYSICAL_REPO_ROOT=$(cd -P "$OPT_REPO_ROOT" && pwd -P) || {
	error "cannot resolve --repo-root: $OPT_REPO_ROOT"
	exit 1
}

# ---------------------------------------------------------------------------
# Cleanup: remove every write-in-progress artefact on any exit path — the
# private copies of the inputs, the staged temp file, and the empty
# placeholder left by the atomic filename claim below.
#
# CLAIMED_FILE exists because the claim and the publishing `mv` are two
# separate steps: a signal landing between them would otherwise leave a real,
# 0-byte file at OUTPUT_FILE, which the next run's "refuse to overwrite an
# existing artifact" guard would then honour as a genuine prior artifact —
# permanently blocking every retry. It is set the instant the claim succeeds
# and cleared the instant the mv succeeds, so it names a placeholder only
# while one actually exists.
# ---------------------------------------------------------------------------
WORK_DIR=""
TMP_FILE=""
CLAIMED_FILE=""

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
	[ -z "$WORK_DIR" ]     || rm -rf "$WORK_DIR" 2>/dev/null || true
	[ -z "$TMP_FILE" ]     || rm -f "$TMP_FILE" 2>/dev/null || true
	[ -z "$CLAIMED_FILE" ] || rm -f "$CLAIMED_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/review-create.XXXXXX")
DIFF_FILES_JSON=$WORK_DIR/diff-files.json
DIFF_HUNKS_JSON=$WORK_DIR/diff-hunks.json
KEY_INPUTS=$WORK_DIR/key-inputs
KEY_MAP=$WORK_DIR/key-map.json
REJECTIONS=$WORK_DIR/rejections
: >"$REJECTIONS"

# ---------------------------------------------------------------------------
# --slug must match artifact-slug.schema.json's pattern. Travels via --arg,
# never concatenated into the program text. Anchored with \A…\z, not ^…$:
# jq's Oniguruma treats `$` as end-of-line, so `^…$` would accept a slug with
# a trailing newline — which then reaches a filename and the document's id.
# ---------------------------------------------------------------------------
if ! jq -n -e --arg s "$OPT_SLUG" '$s | test("\\A[a-z0-9]+(-[a-z0-9]+)*\\z")' >/dev/null 2>&1; then
	usage_error "invalid --slug: $OPT_SLUG (expected lowercase, hyphen-separated, e.g. service-api)"
fi

if ! jq -e . "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage_error "--fields-file is not valid JSON: $OPT_FIELDS_FILE"
fi

# ---------------------------------------------------------------------------
# Reject a MULTI-DOCUMENT --fields-file before validating anything about its
# contents. `jq -e FILTER file` reports the exit status of the LAST value it
# produced, while the build step below reads the FIRST document (via
# --slurpfile + $fields_arr[0]) — so a file holding {invalid}{valid} would
# pass validation on the second document and then be BUILT from the first,
# unvalidated one. Asserting exactly one document closes that gap at the
# source, for every check that follows.
# ---------------------------------------------------------------------------
if ! jq -s -e 'length == 1' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage_error "--fields-file must hold exactly ONE JSON document: $OPT_FIELDS_FILE"
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

# The names every check program reads its inputs by.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_CHECK_DEFS='
$diff_files_arr[0] as $diff_files | $hunks_arr[0] as $hunks |
'

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALUE_DEFS="$JQ_AGGREGATES"'
def severity_values: ["CRITICAL","HIGH","MEDIUM","LOW"];
def is_severity: type == "string" and (. as $v | severity_values | index($v) != null);
def is_finding_id: is_nonempty_string and test("\\A[A-Z]+-[0-9]{3,}\\z");
def is_nonempty_string_array: type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
def fields_proof_forms: reviewer_proof_forms($plan_review);
'

# One findings[] entry, judged alone. Its own def so the diagnostic below can
# name exactly the entries the predicate rejects.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_FINDING_ENTRY_DEF='
def is_valid_finding_entry:
  . as $e
  | ($e.id != null and ($e.id | is_finding_id))
  and ($e.reviewer != null and ($e.reviewer | is_nonempty_string))
  and ($e.severity != null and ($e.severity | is_severity))
  and ($e.category != null and ($e.category | is_nonempty_string))
  and ($e.locations != null and ($e.locations | is_one_line_text_array))
  and ($e.problem != null and ($e.problem | is_nonempty_string))
  and ($e.fix != null and ($e.fix | is_nonempty_string));
'

# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_VALIDATE_FIELDS="$JQ_VALUE_DEFS$JQ_FINDING_ENTRY_DEF"'
type == "object"
and (.repo != null and (.repo | is_nonempty_string))
and (.spec_ref == null or (.spec_ref | is_nonempty_string))
and (.reviewers != null and (.reviewers | is_nonempty_string_array))
and (.findings != null and (.findings | type == "array"))
and (.findings | all(.[]; is_valid_finding_entry))
'

# One line per failing conjunct of JQ_VALIDATE_FIELDS, each mirroring it: the
# top-level fields first, then every findings[] entry is_valid_finding_entry
# rejects. That def alone picks the entries, so every rejected entry is named
# and no accepted one is; an entry the field checks cannot explain still gets
# a line.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_FIELDS="$JQ_VALUE_DEFS$JQ_FINDING_ENTRY_DEF"'
def finding_required_keys: ["id","reviewer","severity","category","locations","problem","fix"];

def finding_field_ok($key):
  if $key == "id" then is_finding_id
  elif $key == "severity" then is_severity
  elif $key == "locations" then is_one_line_text_array
  else is_nonempty_string end;

def finding_field_problem($key):
  if $key == "id" then "id \(shown) does not match the id format (uppercase letters, a hyphen, 3+ digits, e.g. SEC-001)"
  elif $key == "severity" then "severity \(shown) is not one of \(severity_values | join(" | "))"
  elif $key == "locations" then one_line_array_problems($key)
  else "\($key) must be a non-empty string\(got)" end;

def finding_entry_problems($e):
  finding_required_keys[] as $key
  | if $e[$key] == null then presence_problem($e; $key)
    else $e[$key] | select(finding_field_ok($key) | not) | finding_field_problem($key)
    end;

def top_level_problems:
  . as $fields
  | (if .repo == null then presence_problem($fields; "repo")
     elif (.repo | is_nonempty_string) | not then "repo must be a non-empty string (got \(.repo | shown))"
     else empty end),
    (.spec_ref | select(. != null and (is_nonempty_string | not))
     | "spec_ref must be a non-empty string when given\(got)"),
    (if .reviewers == null then presence_problem($fields; "reviewers")
     else .reviewers | select(is_nonempty_string_array | not) | string_array_problems("reviewers") end),
    (if .findings == null then presence_problem($fields; "findings")
     elif (.findings | type) != "array" then "findings must be an array, may be [] (got \(.findings | shown))"
     else empty end);

def findings_problems:
  .findings
  | select(type == "array")
  | to_entries[]
  | .key as $index
  | .value as $e
  | select((try ($e | is_valid_finding_entry) catch false) | not)
  | if ($e | type) != "object" then "findings[\($index)] is not a JSON object (got \($e | shown))"
    else
      (if $e | has("id") then "id \($e.id | shown)" else "(no id)" end) as $label
      | [finding_entry_problems($e)] as $problems
      | (if $problems == [] then ["failed validation (no specific reason identified)"] else $problems end)[]
      | "findings[\($index)] \($label) — \(.)"
    end;

if type != "object" then "the top level must be a JSON object\(got)"
else top_level_problems, findings_problems
end
| "  " + .
'

if ! jq -e --argjson plan_review "$PLAN_REVIEW" "$JQ_VALIDATE_FIELDS" "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	usage >&2
	report_fields_file_rejection \
		"--fields-file failed validation (repo/reviewers/findings shape) — see $PROG --help" \
		--argjson plan_review "$PLAN_REVIEW" "$JQ_DIAGNOSE_FIELDS"
	exit 2
fi

# ---------------------------------------------------------------------------
# Past the shape check every rejection class runs, and each one that rejects
# adds its lines to REJECTIONS, so one run names every problem; the
# fields-file is refused once all have run (reject_if_any_rejection).
#
# Finding ids must be unique. A duplicate id persisted here is not a cosmetic
# problem: every sibling script keys on the id, so review-update-status.sh
# would refuse the finding outright ("not exactly one match") and
# review-add-round.sh would apply one update entry to both copies. The shape
# check above already proved every id a well-formed string.
# ---------------------------------------------------------------------------
# One line per repeated id, naming every entry that carries it.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_DIAGNOSE_DUPLICATE_IDS="$JQ_AGGREGATES"'
.findings
| to_entries
| group_by(.value.id)[]
| select(length > 1)
| (map(.key) | sort | map("findings[\(.)]")) as $refs
| "  \($refs[:-1] | join(", ")) and \($refs[-1]) share id \(.[0].value.id | shown)"
'

if ! jq -e '(.findings | map(.id) | unique | length) == (.findings | length)' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
	report_fields_file_rejection \
		"--fields-file has duplicate finding ids in findings[] — each id must appear at most once" \
		"$JQ_DIAGNOSE_DUPLICATE_IDS" 2>>"$REJECTIONS"
fi

# ---------------------------------------------------------------------------
# Each check below is a lib program whose predicate is "no problem lines", so
# a jq failure rejects; on a rejection the same program names each problem.
# check_fields_file HEADLINE PROBLEMS [HINT] — add the problems to REJECTIONS
# (and HINT after them) when the problem program PROBLEMS, which may read
# $diff_files and $hunks (null without --diff-hunks), prints a line.
# ---------------------------------------------------------------------------
check_fields_file() {
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	if ! jq -e --argjson plan_review "$PLAN_REVIEW" --slurpfile diff_files_arr "$DIFF_FILES_JSON" \
		--slurpfile hunks_arr "$DIFF_HUNKS_JSON" \
		"$JQ_VALUE_DEFS$JQ_CHECK_DEFS"'['"$2"'] == []' "$OPT_FIELDS_FILE" >/dev/null 2>&1; then
		# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
		report_fields_file_rejection "$1" --argjson plan_review "$PLAN_REVIEW" \
			--slurpfile diff_files_arr "$DIFF_FILES_JSON" --slurpfile hunks_arr "$DIFF_HUNKS_JSON" \
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

# The category, the realism fields and the evidence of each finding, and the
# speculative list (lib/review-aggregates.jq, section 3).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file \
	"--fields-file has an invalid category, realism or evidence field (category/realism/trigger/realism_reason/relates_to/proof/unproven/realism_confirmed*/recheck/speculative) — see $PROG --help" \
	'(.findings | to_entries[] | .key as $index | .value
	  | finding_optional_field_problems(fields_proof_forms) | "findings[\($index)] \(.)"),
	 speculative_problems(fields_proof_forms)'

# A security concern is filed under a security category (lib/review-aggregates.jq,
# section 4).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file files a security concern under a category that is not a security one — see $PROG --help" \
	'misfiled_security_problems([])'

# ACK is the human's waiver; a report never sets it on a new finding.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file sets a finding ACK — see $PROG --help" \
	'.findings | list_entries | .key as $index | .value | objects
	 | select(.status == "ACK")
	 | "findings[\($index)] id \(.id | shown) — \(report_ack_rule)"'

# The handoffs (section 6): a filed one names a finding of this fields-file.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file has an invalid handoffs list — see $PROG --help" \
	'handoffs_problems(null; [.findings[].id]; fields_proof_forms)'

# Diff scope (section 5).
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
check_fields_file "--fields-file cites locations outside the diff (--diff-files)" \
	'out_of_diff_problems($diff_files; []; $plan_review)' \
	"a location outside the diff needs a relates_to on its own entry naming the changed code that relies on or exposes it; an observation nothing in the diff relies on belongs in the report notes as pre-existing"

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

# Every proof points at something real: each file:line locator a file and
# line under --repo-root, and in a test-plan review each test number a test
# of --plan.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PROOF_TEST_PROBLEMS=$(jq -r --argjson plan_review "$PLAN_REVIEW" --argjson test_count "$PLAN_TEST_COUNT" "$JQ_AGGREGATES"'
	[fields_file_proofs] | (if $plan_review then proof_test_problems($test_count) else empty end)' "$OPT_FIELDS_FILE") || {
	error "failed to read the proofs in --fields-file"
	exit 1
}
PROOF_LOCATORS=$(jq -r "$JQ_AGGREGATES"'[fields_file_proofs] | proof_locator_lines' "$OPT_FIELDS_FILE") || {
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

# The key of every speculative entry, from its reviewer|location|concern.
if ! jq -r "$JQ_AGGREGATES"'fields_file_speculative_key_inputs' "$OPT_FIELDS_FILE" >"$KEY_INPUTS"; then
	error "failed to read the speculative entries in --fields-file"
	exit 1
fi
# shellcheck disable=SC2310  # speculative_key_map returns an explicit status at every step; set -e is not relied on inside it
speculative_key_map "$KEY_INPUTS" "$KEY_MAP" || {
	error "cannot compute the speculative keys (install shasum, sha256sum, or openssl)"
	exit 1
}

# ---------------------------------------------------------------------------
# created = last_updated = today's UTC date; ONE date call so every derived
# field (output path segments, round.generated, every finding's first_seen)
# agrees.
# ---------------------------------------------------------------------------
CREATED=$(date -u +%Y-%m-%d)
YEAR=${CREATED%%-*}
REST=${CREATED#*-}
MONTH=${REST%%-*}
DAY=${REST#*-}

ABS_REPO_ROOT=$(cd "$OPT_REPO_ROOT" && pwd) || {
	error "cannot resolve --repo-root: $OPT_REPO_ROOT"
	exit 1
}

OUTPUT_DIR="$ABS_REPO_ROOT/.crucible/docs/reviews/$YEAR/$MONTH/$DAY"
OUTPUT_FILE="$OUTPUT_DIR/$OPT_SLUG.json"

# A fast, friendly diagnostic only — NOT the exclusion guarantee. The
# authority is the atomic O_EXCL claim taken just before the publish below.
if [ -e "$OUTPUT_FILE" ]; then
	error "refusing to overwrite existing artifact: $OUTPUT_FILE"
	exit 1
fi

# ---------------------------------------------------------------------------
# Containment, in TWO phases around the mkdir. `mkdir -p` follows a symlinked
# path component silently, so a repo that ships .crucible (or any segment
# under it) as a symlink could redirect this write — and the directory
# CREATION itself — anywhere on the filesystem.
#
#   Phase 1, BEFORE mkdir: resolve the deepest ancestor of the output
#     directory that ALREADY exists (the only part of the path whose physical
#     location can be known before anything is created) and refuse if it lies
#     outside the repo root. A refusal here leaves nothing behind, which is
#     the whole point: a post-mkdir check alone would already have created
#     directories at the redirected location by the time it fired.
#   Phase 2, AFTER mkdir: re-resolve the now-existing output directory and
#     refuse again. Phase 1 can only judge what existed when it ran, so this
#     is the check that is authoritative about the path actually written to
#     (including a component created, or swapped for a symlink, in between).
#
# Only the CHECKS use physical paths — the write itself stays on the logical
# path the caller asked for, so the reported REVIEW_JSON= path is the one they
# can find again.
# ---------------------------------------------------------------------------

# Echoes the deepest ancestor of $2 that already exists, walking down from the
# root $1 one path segment at a time. Segments are derived from $2 rather than
# hardcoded, so the .crucible/docs/reviews/… layout is defined in exactly one
# place (OUTPUT_DIR, above).
deepest_existing_ancestor() {
	_ancestor=$1
	_remaining=${2#"$1"/}
	while [ -n "$_remaining" ]; do
		_segment=${_remaining%%/*}
		[ -d "$_ancestor/$_segment" ] || break
		_ancestor=$_ancestor/$_segment
		case "$_remaining" in
			*/*) _remaining=${_remaining#*/} ;;
			*)   _remaining="" ;;
		esac
	done
	printf '%s\n' "$_ancestor"
}

EXISTING_ANCESTOR=$(deepest_existing_ancestor "$ABS_REPO_ROOT" "$OUTPUT_DIR")
PHYSICAL_EXISTING_ANCESTOR=$(cd "$EXISTING_ANCESTOR" && pwd -P) || {
	error "cannot resolve the existing output-path ancestor: $EXISTING_ANCESTOR"
	exit 1
}

# Equality is accepted here, unlike phase 2: when nothing under .crucible
# exists yet, the deepest existing ancestor IS the repo root. Both phases
# open with the same "refusing to write outside the repo root" wording, the
# substring callers match on.
case "$PHYSICAL_EXISTING_ANCESTOR" in
	"$PHYSICAL_REPO_ROOT"|"$PHYSICAL_REPO_ROOT"/*) : ;;
	*)
		error "refusing to write outside the repo root: $EXISTING_ANCESTOR resolves to $PHYSICAL_EXISTING_ANCESTOR, which is not under $PHYSICAL_REPO_ROOT (a symlinked path component?); no directories were created"
		exit 1
		;;
esac

if ! mkdir -p "$OUTPUT_DIR"; then
	error "failed to create output directory: $OUTPUT_DIR"
	exit 1
fi

PHYSICAL_OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd -P) || {
	error "cannot resolve the output directory: $OUTPUT_DIR"
	exit 1
}

case "$PHYSICAL_OUTPUT_DIR" in
	"$PHYSICAL_REPO_ROOT"/*) : ;;
	*)
		error "refusing to write outside the repo root: $OUTPUT_DIR resolves to $PHYSICAL_OUTPUT_DIR, which is not under $PHYSICAL_REPO_ROOT (a symlinked path component?); inspect $OUTPUT_DIR — directories may already have been created at the resolved location"
		exit 1
		;;
esac

# Build the document — see the header's WHY block on why the caller's
# status/tracked_status/first_seen never survive this reconstruction.
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_BUILD="$JQ_AGGREGATES"'
def finding($created):
  { id: .id,
    reviewer: .reviewer,
    status: "NEW",
    tracked_status: "PENDING",
    severity: .severity }
  + (if has("realism") then { realism: .realism } else {} end)
  + (if has("trigger") then { trigger: .trigger } else {} end)
  + (if has("realism_reason") then { realism_reason: .realism_reason } else {} end)
  + (if has("proof") then { proof: .proof } else {} end)
  + (if has("unproven") then { unproven: .unproven } else {} end)
  + { category: .category,
    locations: .locations }
  + (if has("relates_to") then { relates_to: .relates_to } else {} end)
  + { first_seen: $created,
    problem: .problem,
    fix: .fix
  };
$fields_arr[0] as $doc
| ($doc.findings | map(finding($created))) as $findings
| summary($findings) as $sum
| merged_handoffs([]; $doc.handoffs // []) as $handoffs
| { schema_version: "1.0", id: $slug, repo: $doc.repo }
  + (if ($doc.spec_ref != null) then { spec_ref: $doc.spec_ref } else {} end)
  + { created: $created,
      last_updated: $created,
      diff_files: $diff_files_arr[0] }
  + (if $snapshot != "" then { snapshot: $snapshot } else {} end)
  + (if $plan_review then { plan_review: true } else {} end)
  + { rounds: [ { round: 1, generated: $created, reviewers: $doc.reviewers }
                + speculative_round_fields($doc; $key_map_arr[0]) ],
      overall_verdict: verdict($sum),
      summary: $sum,
      findings: $findings
    }
  + (if $handoffs == [] then {} else { handoffs: $handoffs } end)
| stamp_artifact_security_floor
'

TMP_FILE=$(mktemp "$OUTPUT_DIR/.tmp.$OPT_SLUG.XXXXXX")

if ! jq -n --arg slug "$OPT_SLUG" --arg created "$CREATED" --arg snapshot "$OPT_SNAPSHOT" \
	--argjson plan_review "$PLAN_REVIEW" --slurpfile key_map_arr "$KEY_MAP" \
	--slurpfile fields_arr "$OPT_FIELDS_FILE" --slurpfile diff_files_arr "$DIFF_FILES_JSON" "$JQ_BUILD" >"$TMP_FILE"; then
	error "failed to build the review artifact document"
	exit 1
fi

# Two speculative entries never share a key (section 2).
KEY_PROBLEMS=$(jq -r "$JQ_AGGREGATES"'speculative_key_collision_problems' "$TMP_FILE") || {
	error "failed to check the speculative keys"
	exit 1
}
[ -z "$KEY_PROBLEMS" ] || usage_error "--fields-file: $KEY_PROBLEMS"

# 0666 masked by the caller's own umask — see the header's WHY block on why
# this is neither 600 nor a forced 644.
CALLER_UMASK=$(umask)
FILE_MODE=$(printf '%03o' "$(( 0666 & ~0$CALLER_UMASK ))")

if ! chmod "$FILE_MODE" "$TMP_FILE"; then
	error "failed to set mode $FILE_MODE on the staged artifact: $TMP_FILE"
	exit 1
fi

# Claim the destination ATOMICALLY (noclobber => O_EXCL), in a subshell so
# `set -C` never leaks into the rest of the script. This — not the early
# [ -e ] test — is what makes "never overwrite" a guarantee instead of a
# check-then-act race. Claimed only now, after the document is fully built:
# claiming earlier would leave an empty file behind on a build failure and
# permanently block a retry.
if ! (set -C; : >"$OUTPUT_FILE") 2>/dev/null; then
	if [ -e "$OUTPUT_FILE" ]; then
		error "refusing to overwrite existing artifact: $OUTPUT_FILE"
	else
		error "failed to create the artifact file: $OUTPUT_FILE"
	fi
	exit 1
fi
CLAIMED_FILE=$OUTPUT_FILE

# Same-directory rename over our own placeholder: atomic content publish. On
# failure the placeholder is removed by cleanup(), which still holds it in
# CLAIMED_FILE — the same reason an interrupted run cannot strand one.
if ! mv "$TMP_FILE" "$OUTPUT_FILE"; then
	error "failed to publish the artifact to: $OUTPUT_FILE"
	exit 1
fi
TMP_FILE=""
CLAIMED_FILE=""

printf 'REVIEW_JSON=%s\n' "$OUTPUT_FILE"
exit 0
