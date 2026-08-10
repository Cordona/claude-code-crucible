#!/usr/bin/env sh
#
# update-mr.sh — edit fields of an existing GitLab merge request via
#                `glab mr update`, with the description (when changed at all)
#                always handed over by the caller as a FILE, never built in
#                shell.
#
# CRITICAL — the description is touched ONLY if --description-file is given.
# When it is omitted, this script passes NOTHING description-related (no
# --description, no --description-file) to `glab mr update` — glab then leaves
# the existing description completely untouched. There is no code path here that
# reads the CURRENT description to "preserve" it; non-clobber is achieved
# structurally, by simply never emitting a description flag unless the caller
# explicitly asked to replace it. This mirrors update-pr.sh's non-clobber
# mechanism exactly.
#
# WHY THE CALLER-FACING FLAG IS `--description-file` BUT glab GETS
# `--description "$content"`:
#   `glab mr update` has no --description-file flag (verified against glab
#   1.112.0: only `-d/--description <string>`), so this script reads the file
#   into ONE variable with the sentinel idiom
#       content=$(cat "$file" && printf x); content=${content%x}
#   (a plain $(cat file) would strip ALL trailing newlines) and passes it as ONE
#   double-quoted argv token in a command built from POSITIONAL PARAMETERS. That
#   is injection-safe for the same reason update-pr.sh's --title is: the bytes
#   are never re-interpreted by a shell — no heredoc, no eval, no concatenated
#   command string — so `$(...)`, backticks, quotes and newlines travel into
#   execve as inert data. See create-mr.sh's header for the full reasoning.
#   The caller-facing flag keeps the file-based spelling on purpose: it is the
#   same contract as update-pr.sh's --body-file, and it keeps drafted content out
#   of any command line the caller has to compose.
#
# Purpose:
#   Wraps `glab mr update` so the caller never hand-authors the invocation or
#   the description construction, and can never accidentally wipe an MR's
#   description by editing some OTHER field.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any write, but that confirmation used to bind to NOTHING here: this
#   script let `glab` resolve the target instance from ambient state (the cwd's
#   git remotes, an inherited $GITLAB_HOST, glab's own config). On a machine with
#   two configured instances — the very case the gate exists to disambiguate —
#   the gate could confirm host A while this EDIT silently landed on host B,
#   whenever the same --repo project path resolves on both. A live tracker write
#   is unretractable, and there was no error to notice.
#
#   The fix: the caller passes the ALREADY-CONFIRMED host, and this script
#   exports it as GITLAB_HOST for its OWN process before invoking glab. That is
#   glab's documented per-invocation host selector — glab's README: "you can
#   declare one for the current command with the GITLAB_HOST environment
#   variable"; `glab auth status --help`: the instance is "determined by your
#   current context (git remote, GITLAB_HOST environment variable, or
#   configuration)". Pinning it takes ambient config and glab's gitlab.com
#   default out of the decision, and when the cwd happens to be a checkout of a
#   DIFFERENT instance glab refuses outright ("none of the git remotes …
#   correspond to the GITLAB_HOST environment variable") instead of writing to
#   the wrong place — fail closed either way.
#
#   This script does NOT re-implement the account-confirmation UX; that stays
#   `procedure-gitlab-auth`'s job, upstream (see "NOT performed here" below).
#   The flag only ENFORCES that the write targets the host already confirmed.
#
# Usage:
#   update-mr.sh --repo PATH --mr N --confirmed-host HOST
#                [--title STR] [--description-file PATH] [--target-branch BRANCH]
#                [--add-label NAME]... [--remove-label NAME]...
#                [--add-assignee LOGIN]... [--remove-assignee LOGIN]...
#                [--add-reviewer LOGIN]... [--remove-reviewer LOGIN]...
#                [-h|--help]
#
#     --repo PATH              Target project path (required; subgroups allowed).
#     --confirmed-host HOST    The GitLab host the account gate already CONFIRMED
#                              (required) — e.g. gitlab.com or a self-managed
#                              hostname, spelled the way `glab auth status`
#                              reports it (bare host, optional ':port', no
#                              scheme). See "HOST PINNING" above.
#     --mr N                   The MR number (GitLab iid) to edit (required,
#                              positive integer). Forwarded to glab as the
#                              POSITIONAL <id> argument — `glab mr update` takes
#                              `[<id>|<branch>]` positionally and has no
#                              `--mr`-style flag. The caller-facing spelling
#                              stays a flag for symmetry with update-pr.sh --pr.
#     --title STR              Replace the title.
#     --description-file PATH  Replace the description from this file (must
#                              exist, be readable, non-empty, and not the single
#                              character '-'). Omit to leave the description
#                              UNCHANGED — see the CRITICAL note above. There is
#                              deliberately NO --description passthrough.
#     --target-branch BRANCH   Change the MR's target branch.
#     --add-label NAME         A label to add (glab `--label`). Repeatable
#                              and/or comma-separated. NOT pre-checked for
#                              existence — glab errors on an unknown one.
#     --remove-label NAME      A label to remove (glab `--unlabel` — glab does
#                              NOT mirror gh's --add-label/--remove-label
#                              naming). Repeatable and/or comma-separated.
#     --add-assignee LOGIN     An assignee to add. Repeatable and/or
#                              comma-separated.
#     --remove-assignee LOGIN  An assignee to remove. Repeatable and/or
#                              comma-separated.
#     --add-reviewer LOGIN     A reviewer to request. Repeatable and/or
#                              comma-separated.
#     --remove-reviewer LOGIN  A requested reviewer to remove. Repeatable and/or
#                              comma-separated.
#     -h, --help               Show this help.
#
#   At least ONE field flag is required — a bare --repo/--mr with nothing to
#   change is a usage error, not a silent no-op.
#
#   ASSIGNEE / REVIEWER PREFIXES: glab's `--assignee` and `--reviewer` REPLACE
#   the existing set unless a value is prefixed — '+' adds, and '!' or '-'
#   removes. This script composes those prefixes for you, so an --add-*/
#   --remove-* pair can never accidentally replace the whole set. It uses '!'
#   (never '-') for removal on purpose: a value starting with '-' looks like a
#   flag to glab's own argument parser, while '!' is unambiguous and is inert in
#   a non-interactive shell (no history expansion).
#
# Output:
#   PM_MR_URL=<url>   printed IF an MR URL for THIS --mr can be found in glab's
#                     output; a successful edit that prints no such URL still
#                     exits 0 with this key EMPTY — the URL is a courtesy, not
#                     the proof of success (glab's own exit code is that proof).
#                     Same contract as update-pr.sh. The key is also left empty
#                     when the output is ambiguous (2+ distinct project-matching
#                     URLs) or when the one URL found names a DIFFERENT iid than
#                     --mr: a guess is never relayed.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  MR updated
#   1  glab/awk absent / not authenticated / `glab mr update` itself failed
#   2  usage error (missing/invalid argument, unreadable or unusable
#      description-file, or no field flag given at all)
#
# NOT performed here (deliberately upstream): the GitLab-ACCOUNT confirmation
# gate — that is `procedure-gitlab-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md).
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

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --mr N --confirmed-host HOST
              [--title STR] [--description-file PATH] [--target-branch BRANCH]
              [--add-label NAME]... [--remove-label NAME]...
              [--add-assignee LOGIN]... [--remove-assignee LOGIN]...
              [--add-reviewer LOGIN]... [--remove-reviewer LOGIN]...
              [-h|--help]

Edit fields of an existing GitLab MR via glab. The description is changed ONLY
if --description-file is given (no flag at all leaves it untouched) — there is
no --description passthrough. At least one field flag is required.

Example:
  $PROG --repo group/subgroup/project --mr 42 --confirmed-host gitlab.com \\
        --title "Fix the export encoding" --add-label bug

Options:
  --repo PATH              Target project path (required; subgroups allowed).
  --mr N                   The MR number (iid) to edit (required).
  --confirmed-host HOST    The GitLab host the account gate already confirmed
                            (required; bare hostname, optional ':port', no
                            scheme). Pins glab to that instance.
  --title STR              Replace the title.
  --description-file PATH  Replace the description from this file. Omit to leave
                            the description UNCHANGED.
  --target-branch BRANCH   Change the MR's target branch.
  --add-label NAME         A label to add. Repeatable and/or comma-separated.
  --remove-label NAME      A label to remove. Repeatable and/or comma-separated.
  --add-assignee LOGIN     An assignee to add. Repeatable and/or comma-separated.
  --remove-assignee LOGIN  An assignee to remove. Repeatable and/or comma-separated.
  --add-reviewer LOGIN     A reviewer to request. Repeatable and/or comma-separated.
  --remove-reviewer LOGIN  A requested reviewer to remove. Repeatable and/or
                            comma-separated.
  -h, --help               Show this help.

Prints (may be empty even on success):
  PM_MR_URL=<url>

Exit codes:
  0  updated
  1  glab/awk absent / not authenticated / glab failure
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
ADD_LABELS=""
REMOVE_LABELS=""
ADD_ASSIGNEES=""
REMOVE_ASSIGNEES=""
ADD_REVIEWERS=""
REMOVE_REVIEWERS=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_MR=""
OPT_CONFIRMED_HOST=""
OPT_TITLE=""
OPT_DESCRIPTION_FILE=""
OPT_TARGET_BRANCH=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)             need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--mr)               need_arg "$1" "${2:-}"; OPT_MR=$2; shift ;;
		--confirmed-host)   need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		--title)            need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--description-file) need_arg "$1" "${2:-}"; OPT_DESCRIPTION_FILE=$2; shift ;;
		--target-branch)    need_arg "$1" "${2:-}"; OPT_TARGET_BRANCH=$2; shift ;;
		--add-label)        need_arg "$1" "${2:-}"; ADD_LABELS=$(accumulate "$ADD_LABELS" "$2"); shift ;;
		--remove-label)     need_arg "$1" "${2:-}"; REMOVE_LABELS=$(accumulate "$REMOVE_LABELS" "$2"); shift ;;
		--add-assignee)     need_arg "$1" "${2:-}"; ADD_ASSIGNEES=$(accumulate "$ADD_ASSIGNEES" "$2"); shift ;;
		--remove-assignee)  need_arg "$1" "${2:-}"; REMOVE_ASSIGNEES=$(accumulate "$REMOVE_ASSIGNEES" "$2"); shift ;;
		--add-reviewer)     need_arg "$1" "${2:-}"; ADD_REVIEWERS=$(accumulate "$ADD_REVIEWERS" "$2"); shift ;;
		--remove-reviewer)  need_arg "$1" "${2:-}"; REMOVE_REVIEWERS=$(accumulate "$REMOVE_REVIEWERS" "$2"); shift ;;
		-h|--help)          usage; exit 0 ;;
		--)                 shift; break ;;
		-*)                 usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_MR" ] || { usage >&2; error "--mr is required"; exit 2; }
is_positive_int "$OPT_MR" || { usage >&2; error "--mr must be a positive integer (a GitLab iid), got: $OPT_MR"; exit 2; }

[ -n "$OPT_CONFIRMED_HOST" ] || { usage >&2; error "--confirmed-host is required (the host procedure-gitlab-auth's account gate confirmed)"; exit 2; }
is_valid_confirmed_host "$OPT_CONFIRMED_HOST" || { usage >&2; error "--confirmed-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_CONFIRMED_HOST"; exit 2; }

# Pin glab's target instance to the CONFIRMED host. Exported so every `glab`
# child of THIS process inherits it; nothing outside this process is touched.
# This must happen before the auth precondition below, so even that check asks
# about the host the caller confirmed. See "HOST PINNING" in this file's header.
GITLAB_HOST=$OPT_CONFIRMED_HOST
export GITLAB_HOST

# The description is resolved ONLY when the caller asked to replace it. DESCRIPTION
# stays unset-empty otherwise, and the argv builder below keys the non-clobber
# guard off OPT_DESCRIPTION_FILE, never off this value.
DESCRIPTION=""
if [ -n "$OPT_DESCRIPTION_FILE" ]; then
	if [ ! -f "$OPT_DESCRIPTION_FILE" ] || [ ! -r "$OPT_DESCRIPTION_FILE" ]; then
		usage >&2
		error "--description-file does not exist or is not readable: $OPT_DESCRIPTION_FILE"
		exit 2
	fi
	# Sentinel idiom — a plain $(cat file) strips ALL trailing newlines.
	#
	# `cat … && printf x`, NOT `cat …; printf x`: with the semicolon the command
	# substitution takes ITS exit status from `printf`, which always succeeds, so
	# a mid-read I/O failure on `cat` was invisible even under `set -e` — the
	# caller then saw a truncated description or the misleading "is empty"
	# diagnostic below instead of an honest read failure.
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
fi

# At least one field must actually be requested — a bare --repo/--mr is a
# usage error, not a silent no-op that just prints the URL back.
if [ -z "$OPT_TITLE" ] && [ -z "$OPT_DESCRIPTION_FILE" ] && [ -z "$OPT_TARGET_BRANCH" ] && \
   [ -z "$ADD_LABELS" ] && [ -z "$REMOVE_LABELS" ] && \
   [ -z "$ADD_ASSIGNEES" ] && [ -z "$REMOVE_ASSIGNEES" ] && \
   [ -z "$ADD_REVIEWERS" ] && [ -z "$REMOVE_REVIEWERS" ]; then
	usage >&2
	error "at least one field to change is required (--title, --description-file, --target-branch, --add-label, --remove-label, --add-assignee, --remove-assignee, --add-reviewer, or --remove-reviewer)"
	exit 2
fi

# ---------------------------------------------------------------------------
# glab preconditions
# ---------------------------------------------------------------------------
require_glab

require_awk "required to read the MR URL back"

require_glab_auth

init_tmp_err pm-update-mr

# ---------------------------------------------------------------------------
# Build the `glab mr update` argv as POSITIONAL PARAMETERS — POSIX sh's array
# equivalent. THE non-clobber guard: --description is appended to argv ONLY
# when OPT_DESCRIPTION_FILE is non-empty — if the caller never gave
# --description-file, NO description-related flag is ever added here, so
# `glab mr update` leaves the existing description exactly as it was.
#
# The MR number goes in POSITIONALLY (glab takes `[<id>|<branch>]`), and `--yes`
# is MANDATORY: without it glab prompts for confirmation and would hang.
# ---------------------------------------------------------------------------
set -- glab mr update "$OPT_MR" --repo "$OPT_REPO" --yes

[ -z "$OPT_TITLE" ]            || set -- "$@" --title "$OPT_TITLE"
[ -z "$OPT_DESCRIPTION_FILE" ] || set -- "$@" --description "$DESCRIPTION"
[ -z "$OPT_TARGET_BRANCH" ]    || set -- "$@" --target-branch "$OPT_TARGET_BRANCH"

if [ -n "$ADD_LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --label "$lbl"
	done <<EOF
$ADD_LABELS
EOF
fi

if [ -n "$REMOVE_LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --unlabel "$lbl"
	done <<EOF
$REMOVE_LABELS
EOF
fi

# '+'/'!' prefixes: without one, glab REPLACES the whole assignee/reviewer set.
# '!' (not '-') is used for removal so the value can never be mistaken for a
# flag by glab's argument parser — see this file's header.
if [ -n "$ADD_ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --assignee "+$asg"
	done <<EOF
$ADD_ASSIGNEES
EOF
fi

if [ -n "$REMOVE_ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --assignee "!$asg"
	done <<EOF
$REMOVE_ASSIGNEES
EOF
fi

if [ -n "$ADD_REVIEWERS" ]; then
	while IFS= read -r rev; do
		[ -n "$rev" ] || continue
		set -- "$@" --reviewer "+$rev"
	done <<EOF
$ADD_REVIEWERS
EOF
fi

if [ -n "$REMOVE_REVIEWERS" ]; then
	while IFS= read -r rev; do
		[ -n "$rev" ] || continue
		set -- "$@" --reviewer "!$rev"
	done <<EOF
$REMOVE_REVIEWERS
EOF
fi

# ---------------------------------------------------------------------------
# Update.
# ---------------------------------------------------------------------------
if ! UPDATE_OUT=$("$@" 2>"$TMP_ERR"); then
	error "glab mr update failed for MR !$OPT_MR"
	emit_captured_stderr
	exit 1
fi

# BOTH captured streams are scanned as ONE pool, in a SINGLE pass, never
# stdout-first-with-a-stderr-fallback: glab may put the real URL on stderr, and
# with a fallback an adversarial TITLE echoed on stdout was then the only
# candidate the ambiguity guard ever saw (SEC-003). Pooling means the spoof and
# the genuine URL are seen together — two distinct candidates — and fail closed.
MR_URL_CANDIDATES=$(extract_mr_url_candidates \
	"$(printf '%s\n%s\n' "$UPDATE_OUT" "$(cat "$TMP_ERR")")" "$OPT_REPO")

# FAIL CLOSED on ambiguity — see extract_mr_url_candidates's header: at most one
# candidate per distinct URL, so 2+ means genuine ambiguity or a spoof. THE
# PER-SITE DELTA: this script does NOT invent a failure exit the way create-mr.sh
# does — the edit already succeeded and PM_MR_URL is a documented courtesy field,
# so ambiguity leaves the key EMPTY and warns instead of failing a completed edit.
#
# THE iid CROSS-CHECK (SEC-003): unlike create-mr.sh — which is extracting an iid it
# does not yet know — this script was HANDED the iid it just updated, already
# validated as a positive integer. That makes --mr authoritative ground truth, so
# the surviving candidate's own trailing iid segment must equal it literally. A
# project-matching URL for some OTHER MR (a URL-shaped title naming a different iid)
# therefore cannot be relayed as this MR's URL. A mismatch is treated exactly like
# "no candidate found": empty key + warn, still exit 0.
MR_URL=""
if [ "$(count_lines "$MR_URL_CANDIDATES")" -gt 1 ]; then
	warn "glab mr update printed MORE THAN ONE distinct merge-request URL for project '$OPT_REPO'; refusing to guess, so PM_MR_URL is left empty — resolve it with find-mr.sh (an MR TITLE that looks like a URL produces this)"
	printf '%s\n' "$MR_URL_CANDIDATES" | sed 's/^/  /' >&2
elif [ -n "$MR_URL_CANDIDATES" ]; then
	# The one surviving candidate — the guard above rejected 2+, so this is the
	# whole value (see extract_mr_url_candidates's header).
	CANDIDATE_IID=${MR_URL_CANDIDATES##*/}
	if [ "$CANDIDATE_IID" = "$OPT_MR" ]; then
		MR_URL=$MR_URL_CANDIDATES
	else
		warn "glab mr update printed a merge-request URL for iid !$CANDIDATE_IID, not the MR that was updated (!$OPT_MR), so PM_MR_URL is left empty — resolve it with find-mr.sh (an MR TITLE that looks like a URL produces this)"
		printf '%s\n' "$MR_URL_CANDIDATES" | sed 's/^/  /' >&2
	fi
fi

printf 'PM_MR_URL=%s\n' "$MR_URL"
exit 0
