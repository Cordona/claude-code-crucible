#!/usr/bin/env sh
#
# create-mr.sh — open a GitLab merge request via `glab`, with the artifact
#                DESCRIPTION always supplied as a FILE by the caller and never
#                built in shell.
#
# WHY A FILE ON THE OUTSIDE BUT `--description` ON THE INSIDE (read this before
# changing anything here):
#   The injection-safety rule is the same as create-pr.sh's — an MR description
#   pulled from real repo content (a diff summary, commit messages, linked issue
#   text) can contain a line that collides with a heredoc delimiter, a `$(...)`,
#   or a backtick, so it must never be *constructed* in shell. But `glab mr
#   create` has NO --description-file flag (verified against glab 1.112.0: only
#   `-d/--description <string>`, and passing literally "-" opens an interactive
#   editor). So this script cannot pass a path through the way create-pr.sh
#   passes --body-file.
#
#   The mechanism instead: read the caller's file into ONE shell variable, then
#   pass that variable as ONE double-quoted argv token to `--description`, with
#   the whole command built as POSITIONAL PARAMETERS (POSIX sh's array
#   equivalent). This is injection-safe for exactly the same reason
#   create-pr.sh's --title is safe: the bytes are never re-interpreted by a
#   shell. There is no heredoc, no eval, no string-concatenated command line —
#   the file's bytes travel as a single argv value straight into execve, where
#   `$(...)`, backticks, quotes and newlines are inert data. What must NEVER be
#   done here is to interpolate the description into a command STRING (or a
#   heredoc, or `sh -c`), which would hand those same bytes to a parser.
#
#   The read uses the sentinel idiom:
#       content=$(cat "$file" && printf x); content=${content%x}
#   because a plain `$(cat file)` strips ALL trailing newlines, not just one.
#   The sentinel makes the variable byte-identical to the file, so the
#   description GitLab stores is exactly what the caller drafted — trailing
#   blank lines included.
#
# WHY --repo-dir EXISTS AND IS REQUIRED (a real `glab` constraint, confirmed by
# live testing — do not "simplify" it away):
#   `glab mr create` has NO --hostname flag and no other host-selection flag at
#   all (probed directly: `glab mr create --hostname … ` -> "ERROR: Unknown
#   flag: --hostname"). It resolves WHICH GitLab host to talk to purely from the
#   git remotes of the INVOKING PROCESS'S CURRENT WORKING DIRECTORY, and it
#   needs local git state to relate the source branch to a remote. Run it from a
#   directory whose remotes are not GitLab and it fails outright:
#       "None of the git remotes configured for this repository point to a known
#        GitLab host. … Configured remotes: github.com."
#   even when --repo names a perfectly valid GitLab project. So the caller must
#   hand over the local working tree the source branch was pushed from, and this
#   script runs `glab mr create` from inside it.
#
#   --repo (the project path) is NOT a substitute: it selects the project, not
#   the host, and glab consults it only after host resolution has already
#   succeeded. This is also why the flag is `--repo-dir` and not a `git -C`
#   style option: `git -C` changes only git's directory, whereas glab needs the
#   real PROCESS cwd — hence the subshell `cd` at the create call below.
#
#   find-mr.sh and update-mr.sh deliberately have NO such flag: `glab mr list`
#   and `glab mr update` resolve the host from --repo's slug alone (verified
#   live from an unrelated repo's cwd), so only `create` carries this
#   dependency, and only `create` pays for it. Those two instead take a
#   `--confirmed-host` string and pin GITLAB_HOST with it; THIS script takes no
#   such flag on purpose, because --repo-dir already binds the host to a local
#   checkout whose remote IS the host — a stronger guarantee than a host string,
#   and one glab itself verifies. Adding a second, redundant host input here
#   could only introduce a way for the two to disagree.
#
#   What this script does NOT do: verify that --repo-dir's remotes actually
#   point at the right GitLab host. That is exactly the check `glab mr create`
#   already performs, and it reports it clearly (above) — duplicating it here
#   would only add a second, drifting copy. The validation below is a cheap
#   sanity check (exists / is a directory / is a git working tree) so an
#   obviously wrong path fails fast with a clear message instead of deep inside
#   glab.
#
# Purpose:
#   Wraps `glab mr create` with an idempotency pre-check `glab` itself does NOT
#   perform: opening an MR when one is already open for the same source branch
#   creates a confusing duplicate. This script checks FIRST and refuses to
#   create a duplicate, pointing the caller at update-mr.sh instead.
#
# Usage:
#   create-mr.sh --repo PATH --repo-dir PATH --source-branch BRANCH
#                --target-branch BRANCH --title STR --description-file PATH
#                [--draft] [--reviewer LOGIN]... [--label NAME]...
#                [--assignee LOGIN]... [-h|--help]
#
#     --repo PATH             Target project path (required). One or more
#                             '/'-separated segments — GitLab subgroups are
#                             supported (e.g. group/subgroup/project).
#     --repo-dir PATH         Local filesystem path to a git working tree whose
#                             remote points at the target GitLab host (required)
#                             — in practice the checkout --source-branch was
#                             pushed from. `glab mr create` is run from inside
#                             it; see "WHY --repo-dir EXISTS" above.
#     --source-branch BRANCH  The branch to merge FROM (required). GitLab's
#                             equivalent of a GitHub PR's "head".
#     --target-branch BRANCH  The branch to merge INTO (required). GitLab's
#                             equivalent of a GitHub PR's "base".
#     --title STR             MR title (required).
#     --description-file PATH Path to a file containing the MR description
#                             (required). Must exist and be readable. There is
#                             deliberately NO --description passthrough: the
#                             caller always hands over a file.
#     --draft                 Open as a draft MR.
#     --reviewer LOGIN        A reviewer to request. Repeatable, and/or a
#                             comma-separated list in one occurrence.
#     --label NAME            A label to apply. Repeatable and/or
#                             comma-separated. NOT pre-checked for existence —
#                             an unknown label surfaces as a plain glab failure.
#     --assignee LOGIN        A login to assign. Repeatable and/or
#                             comma-separated.
#     -h, --help              Show this help.
#
# Output:
#   On success, stdout carries machine-parseable keys the caller can relay:
#     PM_MR_NUMBER=<iid>
#     PM_MR_URL=<url>
#   PM_MR_NUMBER is GitLab's per-project **iid** (the `!123` number), parsed
#   from the URL's trailing segment — `glab mr create` supports no --output json
#   (verified against its --help), so the printed URL is the only machine-usable
#   handle it returns. Diagnostics go to stderr.
#
# Exit codes:
#   0  MR created
#   1  glab/awk/git absent / not authenticated / an open MR already exists for
#      this source branch / --repo-dir became unreachable after it was validated
#      (glab never ran) / `glab mr create` itself failed / no MR URL could be
#      found in glab's output
#   2  usage error (missing/invalid argument, unreadable or unusable
#      description-file, --repo-dir missing or not a git working tree — a BARE
#      repository is rejected here too: it has no working tree)
#
# NOT performed here (deliberately upstream): the GitLab-ACCOUNT confirmation
# gate (which login is active) — that is `procedure-gitlab-auth`'s job, run by
# the calling agent BEFORE this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`.
#
# Sources `lib/glab-mr-common.sh` + `lib/glab-mr-output.sh` from the sibling
#   lib/ directory (resolved from $0 by parameter expansion — see the preamble
#   below). The first holds diagnostics, glab's chattiness pins, argument
#   validators, `glab` preconditions and comma-list parsing; the second holds
#   the helpers that read glab's untrusted output. usage() and the `glab` argv
#   builder stay in THIS file. The libs are skill-local: nothing outside this
#   skill is ever sourced, so this skill still deploys and runs on its own.
#
set -eu

# Resolve the sibling lib/ from THIS script's own location — see find-mr.sh for
# why this uses parameter expansion instead of dirname/readlink/realpath.
case $0 in
	*/*) MR_LIB_DIR=${0%/*}/../lib ;;
	*)   MR_LIB_DIR=../lib ;;
esac
# GUARD THE SOURCES: a `.` on an unreadable file aborts with a raw `.: not found`
# that names neither this script nor the path it tried — worst of all via the
# `*)` bare-name arm above, which resolves against an arbitrary cwd. warn() and
# error() live in the lib and do not exist yet, so this is the ONE diagnostic in
# this file that formats itself; everything after this line uses the lib's.
# The loop variable is PREFIXED and unset immediately after: this script and the
# libs it sources share ONE flat POSIX namespace, so a bare, never-unset `lib`
# would silently collide with any same-named variable a lib introduces later.
# Same shape as the PM families' `_pm_lib`.
for _mr_lib in glab-mr-common.sh glab-mr-output.sh; do
	[ -r "$MR_LIB_DIR/$_mr_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_mr_lib" "$MR_LIB_DIR" >&2; exit 1; }
done
unset _mr_lib
# shellcheck source=SCRIPTDIR/../lib/glab-mr-common.sh
. "$MR_LIB_DIR/glab-mr-common.sh"
# shellcheck source=SCRIPTDIR/../lib/glab-mr-output.sh
. "$MR_LIB_DIR/glab-mr-output.sh"

# The exit status the two `cd "$OPT_REPO_DIR" || exit …` subshells below use to
# say "--repo-dir became unreachable, glab never ran" — as opposed to "glab ran
# and failed", which needs a different diagnostic. Named once so the emitting
# `cd` and the checking `if` in BOTH subshell pairs cannot drift apart. The value
# 3 is deliberate: glab's own documented failure code is 1, so the collision is
# narrow (see the create call's header for that accepted ambiguity).
SUBSHELL_CD_FAILED=3

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --repo-dir PATH --source-branch BRANCH
              --target-branch BRANCH --title STR --description-file PATH
              [--draft] [--reviewer LOGIN]... [--label NAME]...
              [--assignee LOGIN]... [-h|--help]

Open a GitLab MR via glab. The description is ALWAYS handed over as a file —
there is no --description passthrough. Refuses to create a duplicate: if an open
MR already exists for --source-branch, this fails and points you at
update-mr.sh instead.

Options:
  --repo PATH             Target project path (required; subgroups allowed).
  --repo-dir PATH         Local git working tree whose remote points at the
                           target GitLab host (required) — normally the checkout
                           --source-branch was pushed from. glab mr create has
                           no host flag: it resolves the GitLab host from the
                           invoking directory's git remotes, so it is run from
                           inside this directory.
  --source-branch BRANCH  The branch to merge FROM (required).
  --target-branch BRANCH  The branch to merge INTO (required).
  --title STR             MR title (required).
  --description-file PATH Path to the MR description (required; must exist and
                           be readable, non-empty, and not the single character
                           '-', which glab reads as "open an editor").
  --draft                 Open as a draft MR.
  --reviewer LOGIN        A reviewer to request. Repeatable and/or comma-separated.
  --label NAME            A label to apply. Repeatable and/or comma-separated.
                           NOT pre-checked for existence.
  --assignee LOGIN        A login to assign. Repeatable and/or comma-separated.
  -h, --help              Show this help.

On success, prints:
  PM_MR_NUMBER=<iid>
  PM_MR_URL=<url>

Exit codes:
  0  created
  1  glab/awk/git absent / not authenticated / an MR already exists for
     --source-branch / glab failure
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# List accumulators (POSIX sh has no arrays; a newline-separated string is the
# portable stand-in). The comma-split + trim + append behavior they all share
# lives in the lib's split_csv_list + accumulate; each list keeps its own
# variable at the call site below, so no `eval` and no name-keyed dispatcher is
# ever needed.
# ---------------------------------------------------------------------------
REVIEWERS=""
LABELS=""
ASSIGNEES=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_REPO_DIR=""
OPT_SOURCE_BRANCH=""
OPT_TARGET_BRANCH=""
OPT_TITLE=""
OPT_DESCRIPTION_FILE=""
OPT_DRAFT=0

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)             need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--repo-dir)         need_arg "$1" "${2:-}"; OPT_REPO_DIR=$2; shift ;;
		--source-branch)    need_arg "$1" "${2:-}"; OPT_SOURCE_BRANCH=$2; shift ;;
		--target-branch)    need_arg "$1" "${2:-}"; OPT_TARGET_BRANCH=$2; shift ;;
		--title)            need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--description-file) need_arg "$1" "${2:-}"; OPT_DESCRIPTION_FILE=$2; shift ;;
		--draft)            OPT_DRAFT=1 ;;
		--reviewer)         need_arg "$1" "${2:-}"; REVIEWERS=$(accumulate "$REVIEWERS" "$2"); shift ;;
		--label)            need_arg "$1" "${2:-}"; LABELS=$(accumulate "$LABELS" "$2"); shift ;;
		--assignee)         need_arg "$1" "${2:-}"; ASSIGNEES=$(accumulate "$ASSIGNEES" "$2"); shift ;;
		-h|--help)          usage; exit 0 ;;
		--)                 shift; break ;;
		-*)                 usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

# ---------------------------------------------------------------------------
# Required-argument validation
# ---------------------------------------------------------------------------
[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

# --repo-dir: cheap, local sanity checks only. The "do its remotes point at the
# right GitLab host?" question is deliberately left to `glab mr create` itself
# (see this file's header). The git-working-tree probe lives further down, with
# the other tool-dependent checks, because it needs `git`.
[ -n "$OPT_REPO_DIR" ] || { usage >&2; error "--repo-dir is required"; exit 2; }
if [ ! -d "$OPT_REPO_DIR" ]; then
	usage >&2
	error "--repo-dir does not exist or is not a directory: $OPT_REPO_DIR"
	exit 2
fi

[ -n "$OPT_SOURCE_BRANCH" ] || { usage >&2; error "--source-branch is required"; exit 2; }
[ -n "$OPT_TARGET_BRANCH" ] || { usage >&2; error "--target-branch is required"; exit 2; }
[ -n "$OPT_TITLE" ]         || { usage >&2; error "--title is required"; exit 2; }

[ -n "$OPT_DESCRIPTION_FILE" ] || { usage >&2; error "--description-file is required"; exit 2; }
if [ ! -f "$OPT_DESCRIPTION_FILE" ] || [ ! -r "$OPT_DESCRIPTION_FILE" ]; then
	usage >&2
	error "--description-file does not exist or is not readable: $OPT_DESCRIPTION_FILE"
	exit 2
fi

# Read the description into ONE variable, byte-for-byte (sentinel idiom — see
# this file's header for why a plain $(cat) is wrong).
#
# `cat … && printf x`, NOT `cat …; printf x`: with the semicolon the command
# substitution takes ITS exit status from `printf`, which always succeeds, so a
# mid-read I/O failure on `cat` was invisible even under `set -e` — the caller
# then saw either a truncated description or the misleading "is empty" diagnostic
# below instead of an honest read failure. With `&&` the substitution's status is
# `cat`'s, so the `if` below actually catches it.
if ! DESCRIPTION=$(cat "$OPT_DESCRIPTION_FILE" && printf x); then
	error "failed to read --description-file: $OPT_DESCRIPTION_FILE"
	exit 2
fi
DESCRIPTION=${DESCRIPTION%x}

# DESC_PROBE is DESCRIPTION with trailing newlines removed (command
# substitution strips them), used ONLY for the two guards below — the value
# actually sent to glab stays the untouched DESCRIPTION.
DESC_PROBE=$(printf '%s' "$DESCRIPTION")
if [ -z "$DESC_PROBE" ]; then
	usage >&2
	error "--description-file is empty: $OPT_DESCRIPTION_FILE"
	exit 2
fi
if [ "$DESC_PROBE" = "-" ]; then
	usage >&2
	error "--description-file contains only '-', which glab reads as \"open an interactive editor\" — that would hang a non-interactive caller"
	exit 2
fi

# ---------------------------------------------------------------------------
# glab preconditions
# ---------------------------------------------------------------------------
require_glab

require_awk "required for the duplicate-MR pre-check"

if ! command -v git >/dev/null 2>&1; then
	error "git is not installed (required to sanity-check --repo-dir)"
	exit 1
fi

# The second half of --repo-dir's validation (the first half — required, exists,
# is a directory — ran with the other argument checks above). Still a USAGE
# error, exit 2: the path the caller passed is wrong, not the environment. It is
# only down here because it needs the `git` guarded immediately above.
#
# --is-inside-work-tree, NOT --git-dir: `rev-parse --git-dir` also SUCCEEDS in a
# BARE repository, which has no working tree at all — so the check would pass a
# directory its own diagnostic says it rejects, and glab (which needs local
# branch state) would then fail deep inside. This asks the question the message
# promises.
if [ "$(git -C "$OPT_REPO_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
	usage >&2
	error "--repo-dir is not a git working tree: $OPT_REPO_DIR"
	exit 2
fi

require_glab_auth

init_tmp_err pm-create-mr

# ---------------------------------------------------------------------------
# Idempotency pre-check: refuse to open a duplicate MR for this source branch.
# The query is EXACTLY the one find-mr.sh runs (open MRs are glab mr list's
# default, so no state flag is passed).
#
# RUN FROM INSIDE --repo-dir, in the SAME subshell shape the create call below
# uses — this is not cosmetic symmetry. `glab` resolves WHICH GitLab host to talk
# to from the invoking process's cwd (its git remotes); the create call therefore
# runs inside --repo-dir. A pre-check left in the INVOKING cwd would resolve a
# possibly DIFFERENT instance, so with two instances hosting the same project
# path the guard could clear against instance A while the create opened an MR on
# instance B — defeating the duplicate guard entirely. Both calls now resolve the
# identical host.
#
# `cd … || exit "$SUBSHELL_CD_FAILED"` — see the create call's header note for why
# the distinct exit code matters and for the narrow, accepted ambiguity with a
# `glab mr list` that itself exits with the same code. $TMP_ERR was normalized to
# an absolute path at its mktemp, so the redirect below is unaffected by the cd.
# ---------------------------------------------------------------------------
PRECHECK_RC=0
PRECHECK_RAW=$( cd "$OPT_REPO_DIR" 2>/dev/null || exit "$SUBSHELL_CD_FAILED"
	glab mr list --repo "$OPT_REPO" --source-branch "$OPT_SOURCE_BRANCH" \
		--output json --jq '.[] | "\(.iid)\t\(.web_url)"' 2>"$TMP_ERR" ) || PRECHECK_RC=$?
if [ "$PRECHECK_RC" -eq "$SUBSHELL_CD_FAILED" ]; then
	error "--repo-dir became unreachable before the duplicate-MR pre-check could run: $OPT_REPO_DIR"
	warn  "no MR was created; re-run once the working tree is reachable again"
	exit 1
fi
if [ "$PRECHECK_RC" -ne 0 ]; then
	error "failed to check for an existing MR on source branch '$OPT_SOURCE_BRANCH'"
	emit_captured_stderr
	exit 1
fi

PRECHECK=$(normalize_mr_rows "$PRECHECK_RAW")

if [ -n "$PRECHECK" ]; then
	# EVERY matching row is listed, not just the first. GitLab allows several open
	# MRs to share ONE source branch as long as their TARGET branches differ (a
	# backport fanning out to release branches is the ordinary example), where
	# GitHub permits one open PR per head branch — so naming only row 1 silently
	# dropped real MRs the operator has to decide between.
	PRECHECK_COUNT=$(printf '%s\n' "$PRECHECK" | awk 'END { print NR }')
	error "$PRECHECK_COUNT open MR(s) already exist for source branch '$OPT_SOURCE_BRANCH' in project '$OPT_REPO':"
	printf '%s\n' "$PRECHECK" | awk -F'\t' '{ printf "  !%s  %s\n", $1, $2 }' >&2
	warn  "use update-mr.sh to modify one of them instead of creating a duplicate"
	exit 1
fi

# ---------------------------------------------------------------------------
# Build the `glab mr create` argv as POSITIONAL PARAMETERS — POSIX sh's array
# equivalent (see standard-shell-script: build commands as arrays, never as
# strings). The description and the title are each ONE argv token; neither is
# ever built via a heredoc/string. `--yes` is MANDATORY here, not optional:
# without it glab prompts for submission confirmation and would hang.
# ---------------------------------------------------------------------------
set -- glab mr create \
	--repo "$OPT_REPO" \
	--source-branch "$OPT_SOURCE_BRANCH" \
	--target-branch "$OPT_TARGET_BRANCH" \
	--title "$OPT_TITLE" \
	--description "$DESCRIPTION" \
	--yes

[ "$OPT_DRAFT" -eq 0 ] || set -- "$@" --draft

if [ -n "$REVIEWERS" ]; then
	while IFS= read -r rev; do
		[ -n "$rev" ] || continue
		set -- "$@" --reviewer "$rev"
	done <<EOF
$REVIEWERS
EOF
fi

if [ -n "$LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --label "$lbl"
	done <<EOF
$LABELS
EOF
fi

if [ -n "$ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --assignee "$asg"
	done <<EOF
$ASSIGNEES
EOF
fi

# ---------------------------------------------------------------------------
# Create — from INSIDE --repo-dir, because `glab mr create` resolves the GitLab
# host from the invoking directory's git remotes and has no flag to say it
# otherwise (see this file's header).
#
# The cd is confined to a SUBSHELL rather than done at the top of the script on
# purpose: everything before this point (notably --description-file, and
# --repo-dir itself) may be a RELATIVE path, and an early cd would silently
# re-resolve those against the wrong directory. $TMP_ERR was normalized to an
# absolute path at its mktemp, so it is unaffected by this cd.
#
# `cd … || exit "$SUBSHELL_CD_FAILED"` — not an unchecked cd (SC2164), and the
# DISTINCT exit code is the point: --repo-dir was validated further up, so if it
# has become unreachable in the meantime (TOCTOU) glab never ran at all.
# Attributing that to "glab mr create failed" alongside an empty captured-stderr
# block would be a misleading diagnostic, so the two failures are told apart
# below. (A `glab mr create` that itself exited with that same code would be read
# as the cd failure; that is an accepted, narrow ambiguity — glab's documented
# failure code is 1, and the alternative, a marker on stdout, would collide with
# the output the URL is parsed from.)
# ---------------------------------------------------------------------------
CREATE_RC=0
CREATE_OUT=$( cd "$OPT_REPO_DIR" 2>/dev/null || exit "$SUBSHELL_CD_FAILED"; "$@" 2>"$TMP_ERR" ) || CREATE_RC=$?
if [ "$CREATE_RC" -eq "$SUBSHELL_CD_FAILED" ]; then
	error "--repo-dir became unreachable before glab mr create could run: $OPT_REPO_DIR"
	warn  "no MR was created; re-run once the working tree is reachable again"
	exit 1
fi
if [ "$CREATE_RC" -ne 0 ]; then
	error "glab mr create failed"
	emit_captured_stderr
	exit 1
fi

# BOTH captured streams are scanned as ONE pool, in a SINGLE pass, never
# stdout-first-with-a-stderr-fallback: glab may put the real URL on stderr, and
# with a fallback an adversarial TITLE echoed on stdout was then the only
# candidate the ambiguity guard ever saw (SEC-003). Pooling means the spoof and
# the genuine URL are seen together — two distinct candidates — and fail closed.
MR_URL_CANDIDATES=$(extract_mr_url_candidates \
	"$(printf '%s\n%s\n' "$CREATE_OUT" "$(cat "$TMP_ERR")")" "$OPT_REPO")

# FAIL CLOSED on ambiguity — see extract_mr_url_candidates's header: at most one
# candidate per distinct URL, so 2+ means genuine ambiguity or a spoof. THE
# PER-SITE DELTA: this URL is LOAD-BEARING (PM_MR_NUMBER is derived from it and
# every follow-up operation is keyed off that), so ambiguity is EXIT 1 here —
# update-mr.sh, whose URL is a courtesy field, only empties the key and warns.
if [ "$(count_lines "$MR_URL_CANDIDATES")" -gt 1 ]; then
	error "glab mr create printed MORE THAN ONE distinct merge-request URL for project '$OPT_REPO' — refusing to guess which one is the new MR"
	printf '%s\n' "$MR_URL_CANDIDATES" | sed 's/^/  /' >&2
	warn  "the MR may nonetheless have been created — verify with find-mr.sh before retrying (an MR TITLE that looks like a URL produces this)"
	exit 1
fi

if [ -z "$MR_URL_CANDIDATES" ]; then
	error "glab mr create reported success but printed no merge-request URL for project '$OPT_REPO'"
	warn  "the MR may nonetheless have been created — check with find-mr.sh before retrying"
	emit_captured_stderr
	exit 1
fi

# The one surviving candidate — the two guards above rejected 2+ and 0, so this is
# the whole value (see extract_mr_url_candidates's header).
MR_URL=$MR_URL_CANDIDATES

# The iid is the URL's trailing segment. No numeric re-check is needed (and one
# would be dead code): extract_mr_url_candidates only accepts a token whose final path
# segment is ALL digits, so a non-numeric tail can never reach here. That is
# also why this script has no create-pr.sh-style "unparseable number" warning —
# the shape matcher rejects such a token outright instead of accepting the URL
# and shipping an empty number.
MR_NUMBER=${MR_URL##*/}

printf 'PM_MR_NUMBER=%s\n' "$MR_NUMBER"
printf 'PM_MR_URL=%s\n'    "$MR_URL"
exit 0
