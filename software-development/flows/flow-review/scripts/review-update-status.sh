#!/usr/bin/env sh
#
# review-update-status.sh — flip ONE finding's status/tracked_status/
#                            addressed_in_round/realism/evidence, confirm it
#                            as an edge case, record a re-check of one
#                            finding, speculative entry or handoff, promote
#                            a survived or escalated speculative entry to a
#                            finding, dismiss an escalated one, or
#                            rule an open handoff, on an existing
#                            flow-review durable artifact, then recompute
#                            summary/verdict fresh. Atomic same-directory
#                            rewrite.
#
# WHY no lock (unlike the GTD inbox log): a review artifact is a
# one-file-per-effort document written only by a single orchestrator turn —
# never concurrently by multiple writers (flow-review SKILL.md §5c). See
# review-create.sh's header for the full rationale.
#
# WHY assert exactly one match before writing anything: a typo'd --id must
# be a loud failure, never a silent success or a silent multi-flip. This
# mirrors process.sh's exact discipline: the match count is computed first,
# under no lock (none needed here — see above), and the real file is never
# touched unless the count is exactly 1. A speculative entry has no id: it is
# addressed by its key (the speculative:<key> of render-md.sh's item map),
# and a handoff by its 1-based place in handoffs (handoff:<N>); either must
# name an entry. A speculative entry stored without a key is given one here.
#
# WHY an edge case keeps its evidence: a finding set aside as an edge case
# carries exactly one of proof or unproven, proof alone under the security
# floor (lib/review-aggregates.jq, header WHY). A call that sets realism
# edge-case, confirms one, or gives --proof or --unproven is judged on the
# finding as it will be stored and rejected unless it holds that evidence,
# so a reclassification can never strip it.
#
# WHY RESOLVED needs the diff and a proof: a resolution is a claim that the
# fix was verified, so --status RESOLVED takes the diff the fix was checked
# against (--diff-files), which must cover one of the finding's stored files
# (locations and relates_to as stored), and --resolution-proof, the evidence
# the fix holds.
#
# WHY a re-check is recorded once: an item set aside (an edge-case finding, a
# speculative entry, a handoff) is looked at again before the review closes.
# --recheck records the outcome on the item with the newest round number:
# pending; survived or cleared with the proof of the outcome; or escalated
# to the human with the reason the re-check could not settle it (the
# verifier's or the adversary's unresolved disagreement), in plain words.
# Once an outcome is recorded the item takes no further re-check, so a
# second look cannot quietly replace the first. A realistic finding is not
# set aside and takes none.
#
# WHY an escalated speculative entry is closed by the human: an escalation
# hands the entry to the human, who either elects it (--promote-to-id, as
# for a survived one) or dismisses it (--recheck dismissed --reason, in
# their own words), which takes it off needs-your-decision. A security
# item is never dismissed by doubt: an entry under the security floor is
# waived only by promoting it and ACKing the finding.
#
# WHY a handoff is ruled here as well as by a round: the orchestrator rules a
# handoff the seat it went to has answered (or the review-arbiter ruled on)
# without running a new round, once, with the same ruling, proof and
# filed_as a round would record. Only here is a handoff waived: the human's
# ruling, carrying the human's reason in their words (--reason), not a proof.
#
# WHY the security floor holds here too: unproven is refused on a finding
# under the floor (lib/review-aggregates.jq, header WHY) whatever its
# realism, a speculative entry under it is promoted only into a security
# category, and every item under it is stored with security_floor: true.
#
# WHY only --proof and --resolution-proof may start "ran ": they are the
# orchestrator's own evidence, and the orchestrator can run a command and
# record what it showed. A re-check proof and a handoff ruling's proof carry
# the evidence of a reviewer or the review-arbiter, who have no shell, so
# they name a file:line (or, in a test-plan review, a test of the plan).
# Every proof points at something real: a file:line locator names a regular
# file under --repo-root and a line within it, and a test number a test of
# --plan.
#
# WHY a survived or escalated speculative entry is promoted here:
# --promote-to-id turns it into a NEW realistic finding (its concern the
# problem, its location and relates_to carried) and marks the entry
# promoted_to that id, so it is listed only as the finding. No round is
# added: the concern was raised in a round already recorded. Its trigger is
# --trigger, the concrete scenario in the human's or the reviewer's words,
# else a survived re-check's proof; an escalated entry has no proof to stand
# in for one, so its promotion requires --trigger. A concern or trigger
# naming a security weakness (x-security-terms) is promoted only into a
# security category, as the round writers file it.
#
# WHY ACK takes a reason: ACK is the human's waiver of a finding, so
# --status ACK records the human's reason, in their words, as ack_reason;
# a status other than ACK drops it.
#
# WHY a decision on an escalated finding is recorded: an escalated re-check
# hands the finding to the human. A later --confirm-edge-case, --realism
# realistic or --status ACK on it is that decision, so the re-check is
# marked decided and the finding leaves needs-your-decision; it still counts
# toward the verdict as its status, realism and severity say.
#
# Usage: see --help.
#
# Output:
#   On success, stdout carries machine-parseable keys:
#     REVIEW_UPDATED=<id>      or speculative:<key> for --speculative-key,
#                                handoff:<N> for --handoff-index
#     REVIEW_PROMOTED=<id>     with --promote-to-id: the new finding's id
#     REVIEW_MD=<path>         the SIBLING Markdown render, which this script
#                                does NOT write — it is now STALE and must be
#                                re-rendered via render-md.sh.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  updated
#   1  jq absent / no SHA-256 tool (shasum, sha256sum, openssl) when a
#      speculative entry is stored without a key / --json-file missing,
#      unreadable, or not a review artifact / not exactly one match / no
#      speculative entry with the key or handoff at the place / write failed
#   2  usage error (missing/invalid argument, no field given, contradictory
#      options, an invalid value, proof or reason, a proof that names no real
#      file line or no test of the plan, an out-of-range round, a finding
#      left without its edge-case evidence, unproven on a finding under the
#      security floor, a resolution the diff does not cover, a re-check on a
#      realistic finding or on an item whose outcome is recorded, a promotion
#      of an entry whose re-check neither survived nor escalated or that is
#      already promoted, an escalated entry promoted without --trigger, a
#      dismissal of an entry not escalated or under the security floor, a
#      promotion id already in use, a category outside the entry reviewer's vocabulary
#      or, under the security floor, not a security one, --confirm-edge-case
#      on a finding that is not an edge case, --status ACK without --reason,
#      a ruling of a handoff already ruled or one whose filed_as names no
#      finding)
#
# Env:
#   TMPDIR — optional; selects the directory of the private copies of the
#   inputs (defaults to /tmp).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). jq is the only
#   non-ubiquitous dependency and is guarded with `command -v`; standard
#   coreutils (awk, basename, cat, chmod, date, dirname, mktemp, mv, rm, sed)
#   are assumed present, plus one of shasum, sha256sum or openssl to key a
#   speculative entry stored without a key. Reads lib/review-aggregates.jq,
#   lib/security-terms.jq and lib/review-categories.json, resolved relative to this script (see the
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

DEFAULT_PROMOTED_FIX="not yet proposed"

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --json-file PATH --id FINDING_ID
           [--status VALUE [--diff-files PATH --resolution-proof TEXT]
                           [--reason TEXT (with ACK)]]
           [--tracked-status VALUE] [--addressed-in-round N]
           [--clear-addressed-in-round] [--realism VALUE]
           [--proof TEXT | --unproven] [--confirm-edge-case]
           [--recheck VALUE [--recheck-proof TEXT | --recheck-reason TEXT]]
           [--repo-root PATH] [--plan PATH]
       $PROG --json-file PATH --speculative-key KEY
           (--recheck VALUE [--recheck-proof TEXT | --recheck-reason TEXT]
            | --recheck dismissed --reason TEXT
            | --promote-to-id ID --severity VALUE --category TEXT
              [--trigger TEXT] [--fix TEXT])
           [--repo-root PATH] [--plan PATH]
       $PROG --json-file PATH --handoff-index N
           [--recheck VALUE [--recheck-proof TEXT | --recheck-reason TEXT]]
           [--ruling VALUE (--proof TEXT [--filed-as ID] | --reason TEXT)]
           [--repo-root PATH] [--plan PATH]
       [-h|--help]

Flip one finding's status/tracked_status/addressed_in_round/realism/
evidence, record a re-check of one edge-case finding, speculative entry or
handoff, promote a survived or escalated speculative entry to a finding,
dismiss an escalated one, or rule an open handoff, on an existing review artifact, and recompute summary/verdict
fresh. Requires EXACTLY one match. Only the given fields change.

Options:
  --json-file PATH        Existing review-artifact JSON file (required).
  --id FINDING_ID          The finding's id.
  --speculative-key KEY    A speculative entry by its key: the 12 hex digits
                             of render-md.sh's REVIEW_ITEM_<n>=speculative:<key>.
                             Takes only a re-check (a dismissal included) or
                             a promotion.
  --handoff-index N        A handoff by its 1-based place in handoffs: the N
                             of REVIEW_ITEM_<n>=handoff:<N>. Takes a re-check,
                             a ruling, or both. Exactly one of --id,
                             --speculative-key and --handoff-index is
                             required.
  --ruling VALUE           filed|rejected|out-of-scope|waived, on an open
                             handoff, once. filed, rejected and out-of-scope
                             require --proof (the ruling's proof, a
                             file:line), and --filed-as exactly when filed;
                             waived is the human's ruling and requires
                             --reason, never --proof.
  --filed-as ID            With --ruling filed: the finding id it was filed
                             as (one the artifact holds).
  --reason TEXT            With --status ACK, --ruling waived, or --recheck
                             dismissed: the human's reason, in their words
                             (free text, not a proof; one line of at most
                             200 characters).
  --status VALUE           NEW|OPEN|RESOLVED|REGRESSED|ACK. RESOLVED requires
                             --diff-files and --resolution-proof: a carried
                             finding resolves only in a round whose diff
                             covers its file or its relates_to file. Any
                             other status drops a stored resolution_proof.
                             ACK is the human's waiver and requires
                             --reason, stored as ack_reason; any other
                             status drops it. On a finding whose re-check
                             escalated it to you, ACK records your decision
                             (it leaves needs your decision).
  --diff-files PATH        With RESOLVED: diff-scope.sh's diff-files.tsv or
                             diff-files.txt for the diff the fix was verified
                             against; one of the finding's stored files (a
                             location's file, or its relates_to file) must be
                             in it.
  --resolution-proof TEXT  With RESOLVED: the evidence the fix holds (a proof).
  --tracked-status VALUE   PENDING|IN_PROGRESS|APPROVED|APPROVED_WITH_FOLLOWUPS.
                             PENDING/IN_PROGRESS also clear addressed_in_round
                             (the schema requires it absent there), so they
                             take no --addressed-in-round.
  --addressed-in-round N   The round (integer >= 1, no newer than the newest
                             recorded round) the fix was verified in.
  --clear-addressed-in-round
                           Remove addressed_in_round from the finding.
                             Mutually exclusive with --addressed-in-round.
  --realism VALUE          realistic|edge-case. Only a realistic finding (and
                             an edge-case CRITICAL/HIGH awaiting
                             confirmation) counts toward the verdict, so
                             realistic is how the human elects an edge case
                             for fixing; it also drops a prior confirmation,
                             a stored unproven, and an edge case's
                             realism_reason, and on a finding whose re-check
                             escalated it to you records your decision.
                             edge-case needs the finding to hold its
                             evidence afterwards.
  --proof TEXT             The edge-case evidence (a proof, which may start
                             "ran "); replaces a stored unproven, and given
                             with --confirm-edge-case records the reason at
                             confirm time. With --handoff-index: the
                             ruling's proof (a file:line).
  --unproven               Set the finding aside without proof; replaces a
                             stored proof. Never accepted on a finding under
                             the security floor, edge case or not. Mutually
                             exclusive with --proof.
  --confirm-edge-case      Confirm an edge-case finding as one (its realism
                             after any --realism given alongside), so an
                             edge-case CRITICAL/HIGH stops blocking; records
                             the severity confirmed at, and a later severity
                             change re-arms the block. On a finding whose
                             re-check escalated it to you, it records your
                             decision.
  --recheck VALUE          pending|survived|cleared|escalated|dismissed, at
                             the newest round; only on an edge-case finding
                             (after any --realism given alongside), a
                             speculative entry or a handoff, and only while
                             the item has no recorded outcome. dismissed is
                             the human's closing of a speculative entry
                             whose re-check escalated it to them: it takes
                             --reason (never --recheck-proof or
                             --recheck-reason), takes the entry off needs
                             your decision, and is refused on an entry
                             under the security floor (promote it and ACK
                             the finding to waive it).
  --recheck-proof TEXT     Required for survived and cleared: the evidence of
                             the outcome, as a file:line (or in a test-plan
                             review a test of the plan).
  --recheck-reason TEXT    Required for escalated: why the re-check
                             escalated the item to the human (the verifier's
                             or the adversary's unresolved disagreement), in
                             plain words (one line of at most 200
                             characters).
  --promote-to-id ID       Promote a speculative entry whose re-check
                             survived, or escalated it to you, to a NEW
                             finding with this id (e.g. SEC-004), not already
                             in the artifact. Its trigger is --trigger, else
                             a survived re-check's proof.
  --severity VALUE         CRITICAL|HIGH|MEDIUM|LOW (with --promote-to-id).
  --category TEXT          With --promote-to-id: a category of the entry
                             reviewer's own vocabulary (x-reviewers in
                             contracts/review-category.schema.json; the union
                             for a reviewer it does not list), and a security
                             category when the entry is under the security
                             floor or its concern names a security weakness
                             (x-security-terms). The new finding keeps the
                             floor.
  --trigger TEXT           With --promote-to-id: the concrete trigger, in
                             the human's or the reviewer's words (one line
                             of at most 200 characters). Required for an
                             escalated entry; for a survived one it
                             replaces the proof as the trigger.
  --fix TEXT               One line (with --promote-to-id; default
                             "$DEFAULT_PROMOTED_FIX").
  --repo-root PATH         The repository top level every proof locator
                             resolves under (required with --proof,
                             --recheck-proof or --resolution-proof).
  --plan PATH              In a test-plan review: the test plan under review
                             (required when a proof names a test number).
  -h, --help               Show this help.

A proof is one line of at most 100 characters naming its evidence: a
file:line (src/a.rs:42, src/a.rs:42-50, Makefile:3; the file has an
extension or a "/", or is Makefile, Dockerfile, Justfile, Rakefile, Gemfile
or Procfile; never a URL or a bare number like 10:30) that exists under
--repo-root with that line; in a test-plan review a test of the plan
(test 3); or, for --proof on a finding and --resolution-proof only, "ran "
then the command and its result.

On success, prints:
  REVIEW_UPDATED=<id>     (speculative:<key> / handoff:<N> for the others)
  REVIEW_PROMOTED=<id>    (with --promote-to-id)
  REVIEW_MD=<path>        the sibling render, now stale — re-run render-md.sh

Exit codes:
  0  updated
  1  jq absent / no SHA-256 tool / --json-file missing or invalid / not
     exactly one match / no speculative entry with the key or handoff at
     the place / write failed
  2  usage error (no field given, contradictory options, an invalid value,
     proof or reason, a proof pointing at nothing real, a finding left
     without its edge-case evidence, unproven under the security floor, a
     resolution the diff does not cover, a re-check refused, a promotion
     refused, a ruling refused, --confirm-edge-case on a finding that is not
     an edge case, --status ACK without --reason)
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
OPT_ID=""
OPT_STATUS=""
OPT_TRACKED_STATUS=""
OPT_ADDRESSED_IN_ROUND=""
OPT_REALISM=""
OPT_SPECULATIVE_KEY=""
OPT_RECHECK=""
OPT_RECHECK_PROOF=""
OPT_RECHECK_REASON=""
OPT_REPO_ROOT=""
OPT_PLAN=""
OPT_PROOF=""
OPT_DIFF_FILES=""
OPT_RESOLUTION_PROOF=""
OPT_PROMOTE_TO_ID=""
OPT_SEVERITY=""
OPT_CATEGORY=""
OPT_FIX=""
OPT_TRIGGER=""
OPT_HANDOFF_INDEX=""
OPT_RULING=""
OPT_FILED_AS=""
OPT_REASON=""
HAS_STATUS=false
HAS_TRACKED_STATUS=false
HAS_ADDRESSED_IN_ROUND=false
CLEAR_ADDRESSED_IN_ROUND=false
HAS_REALISM=false
CONFIRM_EDGE_CASE=false
HAS_SPECULATIVE_KEY=false
HAS_RECHECK=false
HAS_RECHECK_PROOF=false
HAS_RECHECK_REASON=false
HAS_PROOF=false
SET_UNPROVEN=false
HAS_DIFF_FILES=false
HAS_RESOLUTION_PROOF=false
HAS_PROMOTE=false
HAS_SEVERITY=false
HAS_CATEGORY=false
HAS_FIX=false
HAS_TRIGGER=false
HAS_HANDOFF_INDEX=false
HAS_RULING=false
HAS_FILED_AS=false
HAS_REASON=false

while [ $# -gt 0 ]; do
	case "$1" in
		--json-file)          need_arg "$1" "${2:-}"; OPT_JSON_FILE=$2; shift ;;
		--id)                 need_arg "$1" "${2:-}"; OPT_ID=$2; shift ;;
		--status)              need_arg "$1" "${2:-}"; OPT_STATUS=$2; HAS_STATUS=true; shift ;;
		--tracked-status)      need_arg "$1" "${2:-}"; OPT_TRACKED_STATUS=$2; HAS_TRACKED_STATUS=true; shift ;;
		--addressed-in-round)  need_arg "$1" "${2:-}"; OPT_ADDRESSED_IN_ROUND=$2; HAS_ADDRESSED_IN_ROUND=true; shift ;;
		--clear-addressed-in-round) CLEAR_ADDRESSED_IN_ROUND=true ;;
		--realism)             need_arg "$1" "${2:-}"; OPT_REALISM=$2; HAS_REALISM=true; shift ;;
		--proof)               need_arg "$1" "${2:-}"; OPT_PROOF=$2; HAS_PROOF=true; shift ;;
		--unproven)            SET_UNPROVEN=true ;;
		--confirm-edge-case)   CONFIRM_EDGE_CASE=true ;;
		--diff-files)          need_arg "$1" "${2:-}"; OPT_DIFF_FILES=$2; HAS_DIFF_FILES=true; shift ;;
		--resolution-proof)    need_arg "$1" "${2:-}"; OPT_RESOLUTION_PROOF=$2; HAS_RESOLUTION_PROOF=true; shift ;;
		--speculative-key)     need_arg "$1" "${2:-}"; OPT_SPECULATIVE_KEY=$2; HAS_SPECULATIVE_KEY=true; shift ;;
		--recheck)             need_arg "$1" "${2:-}"; OPT_RECHECK=$2; HAS_RECHECK=true; shift ;;
		--recheck-proof)       need_arg "$1" "${2:-}"; OPT_RECHECK_PROOF=$2; HAS_RECHECK_PROOF=true; shift ;;
		--recheck-reason)      need_arg "$1" "${2:-}"; OPT_RECHECK_REASON=$2; HAS_RECHECK_REASON=true; shift ;;
		--repo-root)           need_arg "$1" "${2:-}"; OPT_REPO_ROOT=$2; shift ;;
		--plan)                need_arg "$1" "${2:-}"; OPT_PLAN=$2; shift ;;
		--promote-to-id)       need_arg "$1" "${2:-}"; OPT_PROMOTE_TO_ID=$2; HAS_PROMOTE=true; shift ;;
		--severity)            need_arg "$1" "${2:-}"; OPT_SEVERITY=$2; HAS_SEVERITY=true; shift ;;
		--category)            need_arg "$1" "${2:-}"; OPT_CATEGORY=$2; HAS_CATEGORY=true; shift ;;
		--fix)                 need_arg "$1" "${2:-}"; OPT_FIX=$2; HAS_FIX=true; shift ;;
		--trigger)             need_arg "$1" "${2:-}"; OPT_TRIGGER=$2; HAS_TRIGGER=true; shift ;;
		--handoff-index)       need_arg "$1" "${2:-}"; OPT_HANDOFF_INDEX=$2; HAS_HANDOFF_INDEX=true; shift ;;
		--ruling)              need_arg "$1" "${2:-}"; OPT_RULING=$2; HAS_RULING=true; shift ;;
		--filed-as)            need_arg "$1" "${2:-}"; OPT_FILED_AS=$2; HAS_FILED_AS=true; shift ;;
		--reason)              need_arg "$1" "${2:-}"; OPT_REASON=$2; HAS_REASON=true; shift ;;
		-h|--help)             usage; exit 0 ;;
		--)                    shift; break ;;
		-*)                    usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                     usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_JSON_FILE" ] || usage_error "--json-file is required"

# Exactly one addressed item: a finding by --id, a speculative entry by its
# key, or a handoff by its place.
ITEM_KIND=""
[ -z "$OPT_ID" ] || ITEM_KIND=finding
if [ "$HAS_SPECULATIVE_KEY" = true ]; then
	[ -z "$ITEM_KIND" ] || usage_error "--id, --speculative-key and --handoff-index are mutually exclusive"
	ITEM_KIND=speculative
fi
if [ "$HAS_HANDOFF_INDEX" = true ]; then
	[ -z "$ITEM_KIND" ] || usage_error "--id, --speculative-key and --handoff-index are mutually exclusive"
	ITEM_KIND=handoff
fi
[ -n "$ITEM_KIND" ] || usage_error "--id, --speculative-key or --handoff-index is required"

IS_FINDING=false
[ "$ITEM_KIND" != finding ] || IS_FINDING=true

# The finding-only options and the promotion options, as one flag each.
# --proof is shared: a finding's edge-case evidence, or a handoff ruling's
# proof; --reason too: a finding's ACK, a handoff's waiver, or a speculative
# entry's dismissal.
FINDING_OPTION_GIVEN=false
if [ "$HAS_STATUS" = true ] || [ "$HAS_TRACKED_STATUS" = true ] ||
	[ "$HAS_ADDRESSED_IN_ROUND" = true ] || [ "$CLEAR_ADDRESSED_IN_ROUND" = true ] ||
	[ "$HAS_REALISM" = true ] || [ "$CONFIRM_EDGE_CASE" = true ] ||
	[ "$SET_UNPROVEN" = true ] ||
	[ "$HAS_DIFF_FILES" = true ] || [ "$HAS_RESOLUTION_PROOF" = true ]; then
	FINDING_OPTION_GIVEN=true
fi
PROMOTION_OPTION_GIVEN=false
if [ "$HAS_PROMOTE" = true ] || [ "$HAS_SEVERITY" = true ] ||
	[ "$HAS_CATEGORY" = true ] || [ "$HAS_FIX" = true ] || [ "$HAS_TRIGGER" = true ]; then
	PROMOTION_OPTION_GIVEN=true
fi

# A speculative entry carries no status, tracking, realism or evidence the
# human sets: it takes a re-check (a dismissal with the human's --reason
# included), or is promoted. A handoff takes a re-check and a ruling. A
# finding takes neither promotion nor ruling.
case "$ITEM_KIND" in
	speculative)
		if [ "$FINDING_OPTION_GIVEN" = true ] || [ "$HAS_PROOF" = true ] ||
			[ "$HAS_RULING" = true ] || [ "$HAS_FILED_AS" = true ]; then
			usage_error "--speculative-key takes only --recheck/--recheck-proof/--recheck-reason (--reason with --recheck dismissed) or --promote-to-id/--severity/--category/--trigger/--fix"
		fi
		if [ "$HAS_REASON" = true ] && [ "$OPT_RECHECK" != dismissed ]; then
			usage_error "--reason with --speculative-key is given only with --recheck dismissed (the human's reason, in their words)"
		fi
		if [ "$HAS_RECHECK" = true ] && [ "$PROMOTION_OPTION_GIVEN" = true ]; then
			usage_error "--recheck and --promote-to-id are separate calls: record the survived re-check first, then promote"
		fi
		if [ "$HAS_RECHECK" = false ] && [ "$PROMOTION_OPTION_GIVEN" = false ]; then
			usage_error "--speculative-key needs --recheck or --promote-to-id"
		fi
		case "$OPT_SPECULATIVE_KEY" in
			*[!0-9a-f]*) speculative_key_is_hex=false ;;
			*)           speculative_key_is_hex=true ;;
		esac
		if [ "$speculative_key_is_hex" = false ] || [ "${#OPT_SPECULATIVE_KEY}" -ne 12 ]; then
			usage_error "invalid --speculative-key: $OPT_SPECULATIVE_KEY (expected the 12 hex digits of REVIEW_ITEM_<n>=speculative:<key>)"
		fi
		;;
	handoff)
		if [ "$FINDING_OPTION_GIVEN" = true ] || [ "$PROMOTION_OPTION_GIVEN" = true ]; then
			usage_error "--handoff-index takes only --recheck/--recheck-proof/--recheck-reason and --ruling/--proof/--filed-as/--reason"
		fi
		if [ "$HAS_RECHECK" = false ] && [ "$HAS_RULING" = false ]; then
			usage_error "--handoff-index needs --recheck or --ruling"
		fi
		case "$OPT_HANDOFF_INDEX" in
			''|*[!0-9]*|0*)
				usage_error "invalid --handoff-index: $OPT_HANDOFF_INDEX (expected the 1-based N of REVIEW_ITEM_<n>=handoff:<N>, no leading zeros)"
				;;
			*) : ;;
		esac
		if [ "$HAS_RULING" = true ]; then
			case "$OPT_RULING" in
				filed|rejected|out-of-scope|waived) : ;;
				*) usage_error "invalid --ruling: $OPT_RULING (expected filed|rejected|out-of-scope|waived)" ;;
			esac
			if [ "$OPT_RULING" = waived ]; then
				[ "$HAS_REASON" = true ] ||
					usage_error "--ruling waived requires --reason (the human's reason, in their words)"
				[ "$HAS_PROOF" = false ] ||
					usage_error "--ruling waived takes --reason (the human's words), not --proof"
			else
				[ "$HAS_PROOF" = true ] || usage_error "--ruling $OPT_RULING requires --proof (the evidence behind the ruling)"
				[ "$HAS_REASON" = false ] || usage_error "--reason is given only with --ruling waived"
			fi
			if [ "$OPT_RULING" = filed ] && [ "$HAS_FILED_AS" = false ]; then
				usage_error "--ruling filed requires --filed-as (the id of the finding it was filed as)"
			fi
			if [ "$OPT_RULING" != filed ] && [ "$HAS_FILED_AS" = true ]; then
				usage_error "--filed-as is given only with --ruling filed"
			fi
		else
			[ "$HAS_PROOF" = false ] || usage_error "--proof with --handoff-index is the ruling's proof: it requires --ruling"
			[ "$HAS_FILED_AS" = false ] || usage_error "--filed-as requires --ruling filed"
			[ "$HAS_REASON" = false ] || usage_error "--reason requires --ruling waived"
		fi
		;;
	*)
		[ "$PROMOTION_OPTION_GIVEN" = false ] ||
			usage_error "--promote-to-id/--severity/--category/--trigger/--fix take --speculative-key, not --id"
		[ "$HAS_RULING" = false ] && [ "$HAS_FILED_AS" = false ] ||
			usage_error "--ruling/--filed-as take --handoff-index, not --id"
		if [ "$OPT_STATUS" = ACK ]; then
			[ "$HAS_REASON" = true ] ||
				usage_error "--status ACK requires --reason (your reason for waiving the finding, in your words)"
		elif [ "$HAS_REASON" = true ]; then
			usage_error "--reason with --id is given only with --status ACK (your reason for waiving the finding)"
		fi
		if [ "$FINDING_OPTION_GIVEN" = false ] && [ "$HAS_PROOF" = false ] && [ "$HAS_RECHECK" = false ]; then
			usage_error "at least one of --status/--tracked-status/--addressed-in-round/--clear-addressed-in-round/--realism/--proof/--unproven/--confirm-edge-case/--recheck is required"
		fi
		;;
esac

if [ "$PROMOTION_OPTION_GIVEN" = true ]; then
	[ "$HAS_PROMOTE" = true ] || usage_error "--severity/--category/--trigger/--fix require --promote-to-id"
	[ "$HAS_SEVERITY" = true ] || usage_error "--promote-to-id requires --severity"
	[ "$HAS_CATEGORY" = true ] || usage_error "--promote-to-id requires --category"
	case "$OPT_SEVERITY" in
		CRITICAL|HIGH|MEDIUM|LOW) : ;;
		*) usage_error "invalid --severity: $OPT_SEVERITY (expected CRITICAL|HIGH|MEDIUM|LOW)" ;;
	esac
	[ "$HAS_FIX" = true ] || OPT_FIX=$DEFAULT_PROMOTED_FIX
fi

if [ "$HAS_PROOF" = true ] && [ "$SET_UNPROVEN" = true ]; then
	usage_error "--proof and --unproven are mutually exclusive: give exactly one"
fi

if { [ "$HAS_RECHECK_PROOF" = true ] || [ "$HAS_RECHECK_REASON" = true ]; } && [ "$HAS_RECHECK" = false ]; then
	usage_error "--recheck-proof and --recheck-reason require --recheck"
fi

# A pending re-check has no outcome; survived and cleared carry the proof of
# theirs, escalated the reason the re-check escalated the item to the human.
if [ "$HAS_RECHECK" = true ]; then
	case "$OPT_RECHECK" in
		pending)
			[ "$HAS_RECHECK_PROOF" = false ] && [ "$HAS_RECHECK_REASON" = false ] ||
				usage_error "--recheck pending takes no --recheck-proof or --recheck-reason (a pending re-check has no outcome yet)"
			;;
		survived|cleared)
			[ "$HAS_RECHECK_PROOF" = true ] ||
				usage_error "--recheck $OPT_RECHECK requires --recheck-proof (the file:line evidence of the outcome)"
			[ "$HAS_RECHECK_REASON" = false ] ||
				usage_error "--recheck-reason is given only with --recheck escalated"
			;;
		escalated)
			[ "$HAS_RECHECK_REASON" = true ] ||
				usage_error "--recheck escalated requires --recheck-reason (why the re-check escalated it to the human: the verifier's or the adversary's unresolved disagreement, in plain words)"
			[ "$HAS_RECHECK_PROOF" = false ] ||
				usage_error "--recheck escalated takes --recheck-reason, not --recheck-proof"
			;;
		dismissed)
			[ "$ITEM_KIND" = speculative ] ||
				usage_error "--recheck dismissed applies only to a speculative entry (--speculative-key) whose re-check escalated it to you"
			[ "$HAS_REASON" = true ] ||
				usage_error "--recheck dismissed requires --reason (your reason, in your words)"
			[ "$HAS_RECHECK_PROOF" = false ] && [ "$HAS_RECHECK_REASON" = false ] ||
				usage_error "--recheck dismissed takes --reason (your words), not --recheck-proof or --recheck-reason"
			;;
		*) usage_error "invalid --recheck: $OPT_RECHECK (expected pending|survived|cleared|escalated|dismissed)" ;;
	esac
fi

if [ "$HAS_ADDRESSED_IN_ROUND" = true ] && [ "$CLEAR_ADDRESSED_IN_ROUND" = true ]; then
	usage_error "--addressed-in-round and --clear-addressed-in-round are mutually exclusive"
fi

if [ "$HAS_STATUS" = true ]; then
	case "$OPT_STATUS" in
		NEW|OPEN|RESOLVED|REGRESSED|ACK) : ;;
		*) usage_error "invalid --status: $OPT_STATUS (expected NEW|OPEN|RESOLVED|REGRESSED|ACK)" ;;
	esac
fi

# RESOLVED is verified against a diff and carries its proof; the two
# options mean nothing for any other status.
if [ "$OPT_STATUS" = RESOLVED ]; then
	[ "$HAS_DIFF_FILES" = true ] ||
		usage_error "--status RESOLVED requires --diff-files (diff-scope.sh's diff-files.tsv for the diff the fix was verified against)"
	[ "$HAS_RESOLUTION_PROOF" = true ] ||
		usage_error "--status RESOLVED requires --resolution-proof (the evidence the fix holds)"
else
	if [ "$HAS_DIFF_FILES" = true ] || [ "$HAS_RESOLUTION_PROOF" = true ]; then
		usage_error "--diff-files and --resolution-proof are given only with --status RESOLVED"
	fi
fi

if [ "$HAS_TRACKED_STATUS" = true ]; then
	case "$OPT_TRACKED_STATUS" in
		PENDING|IN_PROGRESS|APPROVED|APPROVED_WITH_FOLLOWUPS) : ;;
		*) usage_error "invalid --tracked-status: $OPT_TRACKED_STATUS (expected PENDING|IN_PROGRESS|APPROVED|APPROVED_WITH_FOLLOWUPS)" ;;
	esac

	# addressed_in_round must be OMITTED while the fix is PENDING or
	# IN_PROGRESS (review-artifact.schema.json), so moving into either state
	# clears it. A caller asserting both at once is contradicting itself —
	# reject rather than silently drop the value they supplied.
	case "$OPT_TRACKED_STATUS" in
		PENDING|IN_PROGRESS)
			[ "$HAS_ADDRESSED_IN_ROUND" = false ] ||
				usage_error "--addressed-in-round cannot be combined with --tracked-status $OPT_TRACKED_STATUS (the schema requires addressed_in_round to be absent in that state)"
			CLEAR_ADDRESSED_IN_ROUND=true
			;;
		*) : ;;
	esac
fi

if [ "$HAS_REALISM" = true ]; then
	case "$OPT_REALISM" in
		realistic|edge-case) : ;;
		*) usage_error "invalid --realism: $OPT_REALISM (expected realistic|edge-case)" ;;
	esac
	if [ "$OPT_REALISM" = realistic ] && [ "$CONFIRM_EDGE_CASE" = true ]; then
		usage_error "--confirm-edge-case cannot be combined with --realism realistic"
	fi
fi

if [ "$HAS_ADDRESSED_IN_ROUND" = true ]; then
	case "$OPT_ADDRESSED_IN_ROUND" in
		''|*[!0-9]*|0*)
			usage_error "invalid --addressed-in-round: $OPT_ADDRESSED_IN_ROUND (expected an integer >= 1, no leading zeros)"
			;;
		*) : ;;
	esac
fi

if [ ! -f "$OPT_JSON_FILE" ] || [ ! -r "$OPT_JSON_FILE" ]; then
	error "--json-file does not exist or is not readable: $OPT_JSON_FILE"
	exit 1
fi

if [ "$HAS_DIFF_FILES" = true ] && { [ ! -f "$OPT_DIFF_FILES" ] || [ ! -r "$OPT_DIFF_FILES" ]; }; then
	usage_error "--diff-files does not exist or is not readable: $OPT_DIFF_FILES"
fi

if [ -n "$OPT_PLAN" ] && { [ ! -f "$OPT_PLAN" ] || [ ! -r "$OPT_PLAN" ]; }; then
	usage_error "--plan does not exist or is not readable: $OPT_PLAN"
fi

# Every proof's file:line locators resolve under --repo-root.
if [ "$HAS_PROOF" = true ] || [ "$HAS_RECHECK_PROOF" = true ] || [ "$HAS_RESOLUTION_PROOF" = true ]; then
	[ -n "$OPT_REPO_ROOT" ] ||
		usage_error "--repo-root is required with --proof, --recheck-proof or --resolution-proof (a proof's file:line locators resolve under it)"
fi
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
# --json-file must already be a well-formed review artifact. Checked by TYPE,
# not merely for presence: a `findings` that is an object rather than an array
# would satisfy `!= null` and then break the `map` below. The rounds[] ENTRY
# assertion exists because the addressed_in_round bound below reads
# `[.rounds[].round] | max`: an entry with no (or a non-numeric) `.round`
# would make that max null or wrong and silently defeat the bound, so
# asserting it here is what lets the max be trusted with no `// 0` fallback.
# ---------------------------------------------------------------------------
if ! jq -e 'type == "object"
	and (.findings | type == "array")
	and (.rounds | type == "array") and ((.rounds | length) > 0)
	and (.rounds | all(.[]; .round | type == "number" and (floor == .) and . >= 1))
	and (.id | type == "string")' \
	"$OPT_JSON_FILE" >/dev/null 2>&1; then
	error "not a valid review artifact JSON file: $OPT_JSON_FILE (expected an object with a string id, a findings[] array, and a non-empty rounds[] whose every entry carries an integer round >= 1)"
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

PLAN_REVIEW=$(jq -r '.plan_review == true' "$OPT_JSON_FILE") || {
	error "failed to read plan_review from $OPT_JSON_FILE"
	exit 1
}

# check_value OPTION JQ_PROBLEMS VALUE — reject VALUE (exit 2) when the lib
# program JQ_PROBLEMS, run with VALUE as its input, prints a problem line.
# The value travels via --arg and is never echoed back.
check_value() {
	check_option=$1
	check_problems=$(jq -n -r --argjson plan_review "$PLAN_REVIEW" --arg value "$3" \
		"$JQ_AGGREGATES"' $value | '"$2") || {
		error "failed to check $check_option"
		exit 1
	}
	[ -z "$check_problems" ] || usage_error "invalid $check_option: it $check_problems"
}

# Every proof: one short line, in a form its source may record (see the
# header WHY on "ran ").
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
if [ "$HAS_RECHECK_PROOF" = true ]; then
	check_value --recheck-proof 'proof_problems(""; reviewer_proof_forms($plan_review)) | ltrimstr(" ")' "$OPT_RECHECK_PROOF"
fi
if [ "$HAS_RECHECK_REASON" = true ]; then
	check_value --recheck-reason 'select(is_reason_text | not) | reason_text_rule' "$OPT_RECHECK_REASON"
fi
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
if [ "$HAS_PROOF" = true ] && [ "$ITEM_KIND" = handoff ]; then
	check_value --proof 'proof_problems(""; reviewer_proof_forms($plan_review)) | ltrimstr(" ")' "$OPT_PROOF"
elif [ "$HAS_PROOF" = true ]; then
	check_value --proof 'proof_problems(""; orchestrator_proof_forms($plan_review)) | ltrimstr(" ")' "$OPT_PROOF"
fi
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
if [ "$HAS_RESOLUTION_PROOF" = true ]; then
	check_value --resolution-proof 'proof_problems(""; orchestrator_proof_forms($plan_review)) | ltrimstr(" ")' "$OPT_RESOLUTION_PROOF"
fi
if [ "$HAS_REASON" = true ]; then
	check_value --reason 'select(is_reason_text | not) | reason_text_rule' "$OPT_REASON"
fi
if [ "$HAS_FILED_AS" = true ]; then
	check_value --filed-as 'select(is_finding_id_text | not) | "must be a finding id: uppercase letters, a hyphen, 3+ digits (e.g. SEC-004)"' "$OPT_FILED_AS"
fi
if [ "$HAS_PROMOTE" = true ]; then
	check_value --promote-to-id 'select(is_finding_id_text | not) | "must be a finding id: uppercase letters, a hyphen, 3+ digits (e.g. SEC-004)"' "$OPT_PROMOTE_TO_ID"
	check_value --category 'select(is_review_category | not) | review_category_rule' "$OPT_CATEGORY"
	check_value --fix 'select(is_one_line_text | not) | one_line_rule' "$OPT_FIX"
fi
if [ "$HAS_TRIGGER" = true ]; then
	check_value --trigger 'select(is_reason_text | not) | reason_text_rule' "$OPT_TRIGGER"
fi

# Every proof points at something real: each file:line locator a file and
# line under --repo-root, and in a test-plan review each test number a test
# of --plan.
PLAN_TEST_COUNT=null
if [ -n "$OPT_PLAN" ]; then
	[ "$PLAN_REVIEW" = true ] || usage_error "--plan is given only for a test-plan review artifact (plan_review: true)"
	PLAN_TEST_COUNT=$(jq -e '.tests | if type == "array" then length else error end' "$OPT_PLAN" 2>/dev/null) ||
		usage_error "--plan is not a test plan (no tests array): $OPT_PLAN"
fi
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
GIVEN_PROOFS=$(jq -n -c \
	--argjson has_proof "$HAS_PROOF" --arg proof "$OPT_PROOF" \
	--argjson has_recheck_proof "$HAS_RECHECK_PROOF" --arg recheck_proof "$OPT_RECHECK_PROOF" \
	--argjson has_resolution_proof "$HAS_RESOLUTION_PROOF" --arg resolution_proof "$OPT_RESOLUTION_PROOF" '
	[ (select($has_proof) | {path: "--proof", proof: $proof}),
	  (select($has_recheck_proof) | {path: "--recheck-proof", proof: $recheck_proof}),
	  (select($has_resolution_proof) | {path: "--resolution-proof", proof: $resolution_proof}) ]') || {
	error "failed to read the proofs"
	exit 1
}
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PROOF_TEST_PROBLEMS=$(jq -n -r --argjson proofs "$GIVEN_PROOFS" --argjson plan_review "$PLAN_REVIEW" \
	--argjson test_count "$PLAN_TEST_COUNT" "$JQ_AGGREGATES"'
	$proofs | (if $plan_review then proof_test_problems($test_count) else empty end)') || {
	error "failed to read the proofs"
	exit 1
}
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
PROOF_LOCATORS=$(jq -n -r --argjson proofs "$GIVEN_PROOFS" "$JQ_AGGREGATES"'$proofs | proof_locator_lines') || {
	error "failed to read the proofs"
	exit 1
}
PROOF_PROBLEMS=$(
	printf '%s\n' "$PROOF_TEST_PROBLEMS"
	printf '%s\n' "$PROOF_LOCATORS" | sed '/^$/d' | proof_locator_problems
)
PROOF_PROBLEMS=$(printf '%s\n' "$PROOF_PROBLEMS" | sed '/^$/d')
if [ -n "$PROOF_PROBLEMS" ]; then
	usage >&2
	error "a proof points at nothing real; no changes made:"
	printf '%s\n' "$PROOF_PROBLEMS" | sed 's/^/  /' >&2
	exit 2
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

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/review-update-status.XXXXXX")
DIFF_FILES_JSON=$WORK_DIR/diff-files.json
KEY_INPUTS=$WORK_DIR/key-inputs
KEY_MAP=$WORK_DIR/key-map.json

# The key of every speculative entry stored without one, so the entries are
# addressed, and written back, by key.
if ! jq -r "$JQ_AGGREGATES"'unkeyed_speculative_key_inputs' "$OPT_JSON_FILE" >"$KEY_INPUTS"; then
	error "failed to read the speculative entries in $OPT_JSON_FILE"
	exit 1
fi
# shellcheck disable=SC2310  # speculative_key_map returns an explicit status at every step; set -e is not relied on inside it
speculative_key_map "$KEY_INPUTS" "$KEY_MAP" || {
	error "cannot compute the speculative keys (install shasum, sha256sum, or openssl)"
	exit 1
}

# A finding cannot have been addressed in a round that never ran.
#
# The COMPARISON happens inside jq, never with shell `[ … -gt … ]`: --addressed-in-round
# is only validated as digits-with-no-leading-zero, so a 20-digit value reaches
# here, and POSIX `test` ERRORS on an operand that large — which the enclosing
# `if` then reads as a passed check, failing open. Asserted POSITIVELY ("must
# be affirmatively within the bound") so any answer other than jq's own literal
# `true` rejects rather than permits. MAX_ROUND is read separately for the
# diagnostic only; the DECISION is jq's.
if [ "$HAS_ADDRESSED_IN_ROUND" = true ]; then
	MAX_ROUND=$(jq -r '[.rounds[].round] | max' "$OPT_JSON_FILE") || {
		error "failed to read the newest recorded round number from $OPT_JSON_FILE"
		exit 1
	}
	ADDRESSED_ROUND_HAS_RUN=$(jq -r --argjson round "$OPT_ADDRESSED_IN_ROUND" \
		'$round <= ([.rounds[].round] | max)' "$OPT_JSON_FILE") || {
		error "failed to compare --addressed-in-round $OPT_ADDRESSED_IN_ROUND against the newest recorded round in $OPT_JSON_FILE"
		exit 1
	}
	if [ "$ADDRESSED_ROUND_HAS_RUN" != "true" ]; then
		usage_error "invalid --addressed-in-round: $OPT_ADDRESSED_IN_ROUND exceeds the newest recorded round ($MAX_ROUND) in $OPT_JSON_FILE"
	fi
fi

# Assert EXACTLY ONE match before anything is written — see the header's WHY
# block. A speculative key must name an entry of the deduplicated list, and
# a handoff place one of handoffs; the comparison happens inside jq, so a
# place too large for shell arithmetic fails closed.
if [ "$ITEM_KIND" = speculative ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	SPECULATIVE_ENTRY_EXISTS=$(jq -r --arg key "$OPT_SPECULATIVE_KEY" --slurpfile key_map_arr "$KEY_MAP" \
		"$JQ_AGGREGATES"'keyed_speculative_rounds($key_map_arr[0]) | any(speculative_entries[]; .key == $key)' "$OPT_JSON_FILE") || {
		error "failed to read the speculative entries in $OPT_JSON_FILE"
		exit 1
	}
	if [ "$SPECULATIVE_ENTRY_EXISTS" != "true" ]; then
		error "no speculative entry with key $OPT_SPECULATIVE_KEY in $OPT_JSON_FILE (see render-md.sh's REVIEW_ITEM_<n>=speculative:<key> map); no changes made"
		exit 1
	fi
elif [ "$ITEM_KIND" = handoff ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	HANDOFF_EXISTS=$(jq -r --argjson place "$OPT_HANDOFF_INDEX" \
		'(.handoffs | type == "array") and $place <= (.handoffs | length) and (.handoffs[$place - 1] | type == "object")' "$OPT_JSON_FILE") || {
		error "failed to read the handoffs in $OPT_JSON_FILE"
		exit 1
	}
	if [ "$HANDOFF_EXISTS" != "true" ]; then
		error "no handoff $OPT_HANDOFF_INDEX in $OPT_JSON_FILE (see render-md.sh's REVIEW_ITEM_<n>=handoff:<N> map); no changes made"
		exit 1
	fi
else
	MATCH_COUNT=$(jq --arg id "$OPT_ID" '[.findings[] | select(.id == $id)] | length' "$OPT_JSON_FILE") || {
		error "failed to count findings with id '$OPT_ID' in $OPT_JSON_FILE"
		exit 1
	}

	if [ "$MATCH_COUNT" -ne 1 ]; then
		error "expected exactly one finding with id '$OPT_ID' in $OPT_JSON_FILE, found $MATCH_COUNT; no changes made"
		exit 1
	fi
fi

# item_refusal JQ_REFUSAL — print the refusal JQ_REFUSAL finds for the
# addressed item (empty when it accepts the call). JQ_REFUSAL reads $item
# (the matched finding, the speculative entry as speculative_entries shows
# it, or the handoff), $kind, $is_finding and the --recheck value $recheck,
# plus the realism the finding will carry.
item_refusal() {
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	jq -r --arg id "$OPT_ID" --arg kind "$ITEM_KIND" --argjson is_finding "$IS_FINDING" \
		--arg key "$OPT_SPECULATIVE_KEY" --argjson place "${OPT_HANDOFF_INDEX:-0}" \
		--slurpfile key_map_arr "$KEY_MAP" \
		--argjson has_realism "$HAS_REALISM" --arg realism "$OPT_REALISM" \
		--arg category "$OPT_CATEGORY" --arg recheck "$OPT_RECHECK" \
		--argjson has_trigger "$HAS_TRIGGER" --arg trigger "$OPT_TRIGGER" \
		"$JQ_AGGREGATES"'
		keyed_speculative_rounds($key_map_arr[0])
		| (if $kind == "finding" then first(.findings[] | select(.id == $id))
		 elif $kind == "speculative" then first(speculative_entries[] | select(.key == $key))
		 else .handoffs[$place - 1] end) as $item
		| (if $is_finding and $has_realism then $realism else $item.realism end) as $realism_after
		| '"$1" "$OPT_JSON_FILE"
}

# refuse_if REFUSAL_PROGRAM — exit 2 with the refusal when there is one.
refuse_if() {
	# shellcheck disable=SC2310  # item_refusal is one jq command, so its status is that command's
	refusal=$(item_refusal "$1") || {
		error "failed to read the addressed item in $OPT_JSON_FILE"
		exit 1
	}
	[ -z "$refusal" ] || usage_error "$refusal; no changes made"
}

# A finding under the security floor is never set aside without proof,
# whatever its realism.
if [ "$SET_UNPROVEN" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	refuse_if 'select($item | is_security_concern) | "--unproven on finding \($id | tojson): \(floored_unproven_rule)"'
fi

# Only an edge case can be confirmed as one, judged on the realism the
# finding will carry after this call (a --realism given alongside wins).
if [ "$CONFIRM_EDGE_CASE" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	refuse_if 'select($realism_after != "edge-case") | "--confirm-edge-case requires finding \($id | tojson) to be an edge case (its realism is not edge-case)"'
fi

# A re-check is for an item set aside — an edge-case finding, a speculative
# entry not yet promoted, or a handoff — and is recorded until an outcome is.
# A dismissal closes only an escalated speculative entry outside the floor.
if [ "$HAS_RECHECK" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	refuse_if '
		if $is_finding and $realism_after != "edge-case"
		then "--recheck applies only to an edge-case finding, a speculative entry or a handoff (finding \($id | tojson) is realistic)"
		elif $kind == "speculative" and ($item | is_promoted_speculative)
		then "--recheck: the speculative entry was promoted to a finding"
		elif $recheck == "dismissed" and ($item | has_recheck_status("escalated") | not)
		then "--recheck dismissed: only an entry whose re-check escalated it to you is dismissed (its re-check is \(if $item.recheck | type == "object" then $item.recheck.status | tostring else "not recorded" end))"
		elif $recheck == "dismissed" and ($item | is_security_concern)
		then "--recheck dismissed: the entry is under the security floor, and a security item is never dismissed by doubt; to waive it, promote it (--promote-to-id) and ACK the finding (--status ACK)"
		elif $recheck == "dismissed" then empty
		elif $item | has_terminal_recheck
		then "--recheck: the item already has a recorded re-check outcome (\($item.recheck.status)); an outcome is recorded once"
		else empty end'
fi

# A promotion takes a speculative entry whose re-check survived or escalated
# it to the human, once, to an id no finding has, in a category the round
# writers would accept for it; an escalated one carries the human's or the
# reviewer's --trigger.
if [ "$HAS_PROMOTE" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	refuse_if '
		if $item | is_promoted_speculative then "--promote-to-id: the speculative entry is already promoted"
		elif ($item | has_recheck_status("survived") or has_recheck_status("escalated")) | not
		then "--promote-to-id requires the re-check of the speculative entry to have survived, or escalated it to you (record it with --recheck first)"
		elif ($item | has_recheck_status("escalated")) and ($has_trigger | not)
		then "--promote-to-id on an escalated entry requires --trigger TEXT (the concrete trigger, as you or the reviewer state it): an escalated re-check has no proof to stand in for one"
		elif $category | is_reviewer_category($item.reviewer) | not then "invalid --category: it \(reviewer_category_rule($item.reviewer))"
		elif ($item | is_security_concern) and ($category | is_security_category | not) then "invalid --category: \(floored_category_rule)"
		else $item | .category = $category
		  | (if $has_trigger then .trigger = $trigger else . end)
		  | misfiled_security_problem(["concern", "trigger"]) | "invalid --category: \(.)" end'
	PROMOTE_ID_TAKEN=$(jq -r --arg promote_id "$OPT_PROMOTE_TO_ID" 'any(.findings[]; .id == $promote_id)' "$OPT_JSON_FILE") || {
		error "failed to read the finding ids in $OPT_JSON_FILE"
		exit 1
	}
	[ "$PROMOTE_ID_TAKEN" = false ] || usage_error "--promote-to-id $OPT_PROMOTE_TO_ID is already a finding id in $OPT_JSON_FILE; no changes made"
fi

# A handoff is ruled once, while open.
if [ "$HAS_RULING" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	refuse_if 'select($item | is_open_handoff | not) | "--ruling: the handoff is already ruled (\($item.ruling | tostring)); a ruling is recorded once"'
fi

TODAY=$(date -u +%Y-%m-%d)

# A resolution is verified against the given diff: one of the finding's
# STORED files must be in it (lib/review-aggregates.jq, section 5). Read once
# into a private copy, as the round writers do.
if [ "$HAS_DIFF_FILES" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	if ! jq -R -s "$JQ_AGGREGATES"'diff_file_list' "$OPT_DIFF_FILES" >"$DIFF_FILES_JSON"; then
		error "failed to read --diff-files: $OPT_DIFF_FILES"
		exit 1
	fi
	jq -e 'length > 0' "$DIFF_FILES_JSON" >/dev/null 2>&1 ||
		usage_error "--diff-files lists no paths: $OPT_DIFF_FILES"
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	RESOLUTION_PROBLEMS=$(jq -r --arg id "$OPT_ID" --slurpfile diff_files_arr "$DIFF_FILES_JSON" \
		"$JQ_AGGREGATES"'. as $artifact
		| {findings: [{id: $id, status: "RESOLVED"}]}
		| unverified_resolution_problems($diff_files_arr[0]; $artifact.findings; $artifact.plan_review == true)
		| sub("\\Afindings\\[0\\] "; "")' "$OPT_JSON_FILE") || {
		error "failed to check the resolution against --diff-files"
		exit 1
	}
	[ -z "$RESOLUTION_PROBLEMS" ] || usage_error "$RESOLUTION_PROBLEMS; no changes made"
fi

# ---------------------------------------------------------------------------
# Apply only the given field(s) to the one matched item, then recompute
# summary/overall_verdict fresh from the WHOLE post-flip findings[]. The
# has_* booleans gate which fields actually apply — same static-program/
# conditional-merge idiom capture.sh uses for its optional session_id. The
# clear step runs LAST so it wins over anything already on the finding.
# Every speculative entry is keyed first; the addressed one is written where
# speculative_entry_refs says its newest copy is stored, and a promotion
# appends the new finding built from it. A handoff takes its re-check and
# ruling, rebuilt by stored_handoff.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
JQ_UPDATE="$JQ_AGGREGATES"'
def promoted_finding($entry):
  {id: $promote_id, reviewer: $entry.reviewer, status: "NEW", tracked_status: "PENDING",
   severity: $severity}
  + (if $has_trigger then {trigger: $trigger}
     elif $entry.recheck.proof != null then {trigger: $entry.recheck.proof}
     else {} end)
  + {category: $category, locations: [$entry.location]}
  + (if $entry | has("relates_to") then {relates_to: $entry.relates_to} else {} end)
  + {first_seen: $today, problem: $entry.concern, fix: $fix}
  + (if $entry | is_security_concern then {security_floor: true} else {} end);

([.rounds[].round] | max) as $newest_round
| ($confirm_edge_case or ($has_realism and $realism == "realistic") or ($has_status and $status == "ACK"))
  as $decides_escalation
| ({status: $recheck}
   + (if $has_recheck_proof then {proof: $recheck_proof} else {} end)
   + (if $has_recheck_reason then {reason: $recheck_reason} else {} end)
   + (if $recheck == "dismissed" then {reason: $reason} else {} end)
   + {round: $newest_round}) as $recheck_record
| keyed_speculative_rounds($key_map_arr[0])
| if $has_speculative_key then
    first(speculative_entry_refs[] | select(.entry.key == $speculative_key)) as $ref
    | if $has_promote then
        .rounds[$ref.position].speculative[$ref.index].promoted_to = $promote_id
        | .findings += [promoted_finding($ref.entry)]
      else
        .rounds[$ref.position].speculative[$ref.index].recheck = $recheck_record
      end
  elif $has_handoff_index then
    .handoffs[$handoff_index - 1] |= (
      (if $has_recheck then .recheck = $recheck_record else . end)
      | (if $has_ruling and $ruling == "waived" then .ruling = $ruling | .reason = $reason | del(.proof)
         elif $has_ruling then .ruling = $ruling | .proof = $proof
         else . end)
      | (if $has_filed_as then .filed_as = $filed_as else . end)
      | stored_handoff)
  else . end
| .findings |= map(
    if $is_finding and .id == $id then
      has_recheck_status("escalated") as $was_escalated
      | is_edge_case_finding as $was_edge_case
      | . + (if $has_status then {status: $status} else {} end)
        + (if $has_tracked_status then {tracked_status: $tracked_status} else {} end)
        + (if $has_addressed_in_round then {addressed_in_round: $addressed_in_round} else {} end)
        + (if $has_realism then {realism: $realism} else {} end)
        + (if $confirm_edge_case then {realism_confirmed: true} else {} end)
        + (if $has_recheck then {recheck: $recheck_record} else {} end)
        + (if $has_resolution_proof then {resolution_proof: $resolution_proof} else {} end)
        + (if $has_status and $status == "ACK" then {ack_reason: $reason} else {} end)
      | (if $has_realism and $realism == "realistic"
         then del(.unproven) | (if $was_edge_case then del(.realism_reason) else . end)
         else . end)
      | (if $has_proof then .proof = $proof | del(.unproven) else . end)
      | (if $set_unproven then .unproven = true | del(.proof) else . end)
      | (if .status == "RESOLVED" then . else del(.resolution_proof) end)
      | (if .status == "ACK" then . else del(.ack_reason) end)
      | (if $was_escalated and $decides_escalation then .recheck.decided = true else . end)
      | (if $confirm_edge_case then .realism_confirmed_severity = .severity else . end)
      | (if $clear_addressed_in_round then del(.addressed_in_round) else . end)
      | drop_stale_confirmation
    else . end
  )
| .last_updated = $today
| stamp_artifact_security_floor
| (summary(.findings)) as $sum
| .summary = $sum
| .overall_verdict = verdict($sum)
'

TARGET_DIR=$(dirname "$OPT_JSON_FILE")
TMP_FILE=$(mktemp "$TARGET_DIR/.tmp.$(basename "$OPT_JSON_FILE").XXXXXX")

if ! jq --arg id "$OPT_ID" --arg today "$TODAY" \
	--argjson has_status "$HAS_STATUS" --arg status "$OPT_STATUS" \
	--argjson has_tracked_status "$HAS_TRACKED_STATUS" --arg tracked_status "$OPT_TRACKED_STATUS" \
	--argjson has_addressed_in_round "$HAS_ADDRESSED_IN_ROUND" --argjson addressed_in_round "${OPT_ADDRESSED_IN_ROUND:-0}" \
	--argjson clear_addressed_in_round "$CLEAR_ADDRESSED_IN_ROUND" \
	--argjson has_realism "$HAS_REALISM" --arg realism "$OPT_REALISM" \
	--argjson confirm_edge_case "$CONFIRM_EDGE_CASE" \
	--argjson has_proof "$HAS_PROOF" --arg proof "$OPT_PROOF" \
	--argjson set_unproven "$SET_UNPROVEN" \
	--argjson has_resolution_proof "$HAS_RESOLUTION_PROOF" --arg resolution_proof "$OPT_RESOLUTION_PROOF" \
	--argjson is_finding "$IS_FINDING" \
	--argjson has_speculative_key "$HAS_SPECULATIVE_KEY" --arg speculative_key "$OPT_SPECULATIVE_KEY" \
	--slurpfile key_map_arr "$KEY_MAP" \
	--argjson has_handoff_index "$HAS_HANDOFF_INDEX" --argjson handoff_index "${OPT_HANDOFF_INDEX:-0}" \
	--argjson has_ruling "$HAS_RULING" --arg ruling "$OPT_RULING" \
	--argjson has_filed_as "$HAS_FILED_AS" --arg filed_as "$OPT_FILED_AS" --arg reason "$OPT_REASON" \
	--argjson has_recheck "$HAS_RECHECK" --arg recheck "$OPT_RECHECK" \
	--argjson has_recheck_proof "$HAS_RECHECK_PROOF" --arg recheck_proof "$OPT_RECHECK_PROOF" \
	--argjson has_recheck_reason "$HAS_RECHECK_REASON" --arg recheck_reason "$OPT_RECHECK_REASON" \
	--argjson has_promote "$HAS_PROMOTE" --arg promote_id "$OPT_PROMOTE_TO_ID" \
	--arg severity "$OPT_SEVERITY" --arg category "$OPT_CATEGORY" --arg fix "$OPT_FIX" \
	--argjson has_trigger "$HAS_TRIGGER" --arg trigger "$OPT_TRIGGER" \
	"$JQ_UPDATE" "$OPT_JSON_FILE" >"$TMP_FILE"; then
	error "failed to apply the status update"
	exit 1
fi

# A ruled handoff is judged as staged (lib/review-aggregates.jq,
# handoff_problems): its filed_as names a finding the artifact holds. The
# problem lines never echo a caller value.
if [ "$HAS_RULING" = true ]; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	HANDOFF_PROBLEMS=$(jq -r --argjson place "$OPT_HANDOFF_INDEX" --argjson plan_review "$PLAN_REVIEW" \
		"$JQ_AGGREGATES"'[.findings[].id] as $finding_ids
		| .handoffs[$place - 1] | handoff_problems($finding_ids; reviewer_proof_forms($plan_review))' "$TMP_FILE") || {
		error "failed to check the handoff ruling"
		exit 1
	}
	[ -z "$HANDOFF_PROBLEMS" ] || usage_error "invalid ruling of handoff $OPT_HANDOFF_INDEX: it $HANDOFF_PROBLEMS; no changes made"
fi

# An edge case keeps its evidence (see the header WHY), judged on the finding
# as staged; the problem lines never echo a caller value.
if [ "$IS_FINDING" = true ] && { [ "$HAS_REALISM" = true ] || [ "$CONFIRM_EDGE_CASE" = true ] ||
	[ "$HAS_PROOF" = true ] || [ "$SET_UNPROVEN" = true ]; }; then
	# shellcheck disable=SC2016  # single-quoted on purpose: jq syntax, not shell expansions
	EVIDENCE_PROBLEMS=$(jq -r --arg id "$OPT_ID" --argjson has_proof "$HAS_PROOF" --argjson plan_review "$PLAN_REVIEW" \
		"$JQ_AGGREGATES"'.findings[] | select(.id == $id)
		| finding_evidence_problems(if $has_proof then orchestrator_proof_forms($plan_review) else carried_proof_forms end;
		                            is_security_concern)' "$TMP_FILE") || {
		error "failed to check the finding evidence"
		exit 1
	}
	if [ -n "$EVIDENCE_PROBLEMS" ]; then
		usage >&2
		error "finding '$OPT_ID' would be left without its edge-case evidence (give --proof TEXT, or --unproven outside the security floor); no changes made:"
		printf '  %s\n' "$EVIDENCE_PROBLEMS" >&2
		exit 2
	fi
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
if [ "$ITEM_KIND" = handoff ]; then
	printf 'REVIEW_UPDATED=handoff:%s\n' "$OPT_HANDOFF_INDEX"
elif [ "$ITEM_KIND" = speculative ]; then
	if [ "$OPT_RECHECK" = survived ]; then
		printf '%s: note: speculative:%s survived its re-check; promote it with --speculative-key %s --promote-to-id ID --severity VALUE --category TEXT\n' \
			"$PROG" "$OPT_SPECULATIVE_KEY" "$OPT_SPECULATIVE_KEY" >&2
	elif [ "$OPT_RECHECK" = escalated ]; then
		printf '%s: note: speculative:%s is escalated to the human; close it with --speculative-key %s and --promote-to-id ID --severity VALUE --category TEXT --trigger TEXT, or, outside the security floor, --recheck dismissed --reason TEXT\n' \
			"$PROG" "$OPT_SPECULATIVE_KEY" "$OPT_SPECULATIVE_KEY" >&2
	fi
	printf 'REVIEW_UPDATED=speculative:%s\n' "$OPT_SPECULATIVE_KEY"
	[ "$HAS_PROMOTE" = false ] || printf 'REVIEW_PROMOTED=%s\n' "$OPT_PROMOTE_TO_ID"
else
	printf 'REVIEW_UPDATED=%s\n' "$OPT_ID"
fi
printf 'REVIEW_MD=%s\n' "${OPT_JSON_FILE%.json}.md"
exit 0
