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
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays parseable and this
# non-interactive script can never block on a prompt. GLAB_NO_PROMPT is a second
# belt alongside the mandatory `--yes` below: `--yes` skips the submission
# confirmation, GLAB_NO_PROMPT stops glab asking anything else.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

# The exit status the two `cd "$OPT_REPO_DIR" || exit …` subshells below use to
# say "--repo-dir became unreachable, glab never ran" — as opposed to "glab ran
# and failed", which needs a different diagnostic. Named once so the emitting
# `cd` and the checking `if` in BOTH subshell pairs cannot drift apart. The value
# 3 is deliberate: glab's own documented failure code is 1, so the collision is
# narrow (see the create call's header for that accepted ambiguity).
SUBSHELL_CD_FAILED=3

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

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

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_valid_gitlab_project_path VALUE — allow-list: letters, digits, '.', '_',
# '-' per segment, and ONE OR MORE '/'-separated segments, with no empty
# segment and no '.'/'..' path segment.
#
# WHY this is NOT procedure-gh-pr's is_valid_repo_slug: a GitHub slug is always
# exactly OWNER/REPO (that validator hard-rejects a second '/'), but GitLab
# supports nested groups, so a real project path can be
# "group/subgroup/project" or deeper. Rejecting the extra segments would make
# every subgroup project unreachable. A LONE segment with no '/' at all is still
# rejected: a bare project name is never a valid full path.
is_valid_gitlab_project_path() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;   # character allow-list
		*//*) return 1 ;;                 # empty segment
		/*|*/) return 1 ;;                # leading / trailing slash
		..|../*|*/..|*/../*) return 1 ;;  # parent-dir traversal segment
		.|./*|*/.|*/./*) return 1 ;;      # current-dir segment
		*/*) return 0 ;;                  # at least one separator: accept
		*) return 1 ;;                    # a single bare segment: reject
	esac
}

# normalize_mr_rows VALUE — print the `glab mr list --jq` result as clean
# "iid<TAB>web_url" lines, dropping empties. See find-mr.sh for the full
# rationale (duplicated on purpose so this script stays standalone).
normalize_mr_rows() {
	printf '%s\n' "$1" | awk '
		{
			gsub(/\\t/, "\t")
			gsub(/"/, "")
			if ($0 != "") print
		}
	'
}

# extract_mr_url_candidates TEXT REPO — print every DISTINCT whitespace-delimited
# token in TEXT that is a merge-request URL OF THIS PROJECT, one per line, in
# first-appearance order. Prints nothing when there is no such token.
#
# `glab mr create` prints a human-oriented block, and its exact decoration is not
# a documented contract, so the URL is located by SHAPE rather than by line or
# column position. awk always exits 0, so this never trips `set -e`.
#
# THE ONE PLACE THE DEDUP/AMBIGUITY RATIONALE IS WRITTEN OUT — every call site
# below points here instead of restating it:
#   * glab prints the MR TITLE on the line BEFORE the URL, so a title that merely
#     LOOKS like an MR URL (adversarial, or one that just quotes a link) used to be
#     picked up instead of the real URL: the first shape match in the whole captured
#     output won, and PM_MR_URL/PM_MR_NUMBER then pointed at something the caller
#     never created.
#   * So a candidate must be a URL of the CONFIRMED --repo project, ALL distinct
#     candidates are reported, and the dedup keeps the FIRST occurrence of each
#     distinct value while dropping every later repeat.
#   * Therefore the output holds AT MOST ONE LINE PER DISTINCT URL. The caller never
#     chooses between occurrences: it either has exactly one surviving line and takes
#     it, or it has 2+ — which can only mean genuinely different URLs, i.e. ambiguity
#     or a spoof — and fails closed. Identical repeats collapse to one candidate, so
#     a title quoting the real URL verbatim is harmless.
#
# HOW THE PROJECT MATCH IS ANCHORED (SEC-002): the repo path must follow the HOST
# DIRECTLY. An unanchored `index($i, "/" repo "/")` substring test accepted the
# project path at ANY depth under ANY host, so
# "https://attacker.example/x/<repo>/-/merge_requests/5" qualified — the ambiguity
# guard usually caught it (a genuine URL is normally present too, making 2+
# candidates), but the filter must not lean on that backstop alone. So: scheme +
# host are stripped, the remainder's LITERAL prefix must be "<repo>/", and what
# follows must be GitLab's own MR route. The prefix test is a literal string
# compare, never a regex, so a '.' in a project path cannot act as a wildcard and
# no metacharacter escaping is needed.
extract_mr_url_candidates() {
	printf '%s\n' "$1" | awk -v repo="$2" '
		{
			for (i = 1; i <= NF; i++) {
				tok = $i
				if (tok !~ /^https?:\/\/[^\/]+\//) continue
				path = tok
				sub(/^https?:\/\/[^\/]+\//, "", path)
				if (substr(path, 1, length(repo) + 1) != repo "/") continue
				rest = substr(path, length(repo) + 2)
				if (rest !~ /^(-\/)?merge_requests\/[0-9]+$/) continue
				if (tok in seen) continue
				seen[tok] = 1
				print tok
			}
		}
	'
}

# count_lines TEXT — number of lines in TEXT, 0 for the empty string. awk's
# END{print NR} counts RECORDS, so a final line with no trailing newline still
# counts (unlike `wc -l`, which counts newline BYTES), and it always exits 0.
count_lines() {
	[ -n "$1" ] || { printf '0\n'; return 0; }
	printf '%s\n' "$1" | awk 'END { print NR }'
}

# ---------------------------------------------------------------------------
# List accumulators (POSIX sh has no arrays; a newline-separated string is
# the portable stand-in). All three need IDENTICAL comma-split + trim + append
# behavior, so the whole job is TWO shared helpers — split_csv_list (tokenize)
# and accumulate (append, VALUE-RETURNING) — rather than three
# byte-identical-except-for-the-variable-name append functions.
#
# `accumulate` RETURNS the new list on stdout instead of mutating a global chosen
# by a name argument: `LABELS=$(accumulate "$LABELS" "$2")` keeps the target
# variable at the call site, where the reader can see it, and needs no `eval` and
# no string-keyed dispatcher — the pattern this codebase's own conventions reject.
# ---------------------------------------------------------------------------
REVIEWERS=""
LABELS=""
ASSIGNEES=""

# split_csv_list VALUE — print each comma-separated, trimmed, non-empty token in
# VALUE on its own line (stdout).
#
# `accumulate` below reads this through a HEREDOC, never by piping into its
# `while read`: the loop must stay in accumulate's OWN shell so its `acc`
# variable survives to the final printf. Piping would put the loop in a further
# subshell and lose every appended token.
split_csv_list() {
	value=$1
	old_ifs=$IFS
	IFS=','
	set -f
	# shellcheck disable=SC2086  # deliberate split of a comma-list on IFS=','; -f (above) blocks globbing
	set -- $value
	set +f
	IFS=$old_ifs
	for tok in "$@"; do
		tok=$(printf '%s' "$tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$tok" ] || continue
		printf '%s\n' "$tok"
	done
}

# accumulate CURRENT VALUE — print CURRENT with every comma-separated token of
# VALUE appended as its own line. CURRENT may be empty (then the result is just
# the new tokens). VALUE contributing no usable token leaves CURRENT unchanged,
# so a `--label ,,` cannot introduce a blank entry.
accumulate() {
	acc=$1
	while IFS= read -r tok; do
		[ -n "$tok" ] || continue
		if [ -z "$acc" ]; then acc=$tok
		else acc="$acc
$tok"
		fi
	done <<EOF
$(split_csv_list "$2")
EOF
	printf '%s' "$acc"
}

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
if ! command -v glab >/dev/null 2>&1; then
	error "GitLab CLI (glab) is not installed"
	warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
	exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required for the duplicate-MR pre-check)"
	exit 1
fi

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

# See find-mr.sh: the bare form checks only the current context's instance, so
# --all is the fallback before declaring glab unauthenticated.
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-create-mr.err.XXXXXX")
# Make the path ABSOLUTE. mktemp echoes back the template it was given, so a
# RELATIVE $TMPDIR yields a relative path — and this script redirects into
# $TMP_ERR from inside a subshell that has cd'd to --repo-dir, which would drop
# a stray file in the user's checkout while the cleanup trap unlinked a
# different (cwd-relative) path. Normalizing here keeps both ends on one file.
case $TMP_ERR in
	/*) ;;
	*) TMP_ERR="$PWD/$TMP_ERR" ;;
esac
# INT/TERM as well as EXIT: a Ctrl-C during a slow `glab mr list`/`create` would
# otherwise leak the temp file (the auth scripts and both test harnesses in this
# body of work already trap all three).
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

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
	sed 's/^/  /' "$TMP_ERR" >&2
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
	sed 's/^/  /' "$TMP_ERR" >&2
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
	sed 's/^/  /' "$TMP_ERR" >&2
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
