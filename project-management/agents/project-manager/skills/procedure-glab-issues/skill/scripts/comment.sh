#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
#
# comment.sh — add a comment (a GitLab "note") to an existing GitLab issue,
#              with the comment BODY always handed over by the caller as a FILE
#              (--body-file) and never built in shell.
#
# WHY THE CALLER-FACING FLAG IS `--body-file` BUT glab GETS `-m/--message`:
#   The injection-safety rule is the same as the GitHub sibling's — a comment
#   body pulled from real repo content can contain a line that collides with a
#   heredoc delimiter, a `$(...)`, or a backtick, so it must never be
#   *constructed* in shell. But GitLab's comment subcommand is `glab issue note`
#   and it has NO --message-file/--body-file flag (verified against glab
#   1.112.0's own --help: only `-m/--message <string>`; OMITTING it opens an
#   interactive editor). So this script reads the caller's file into ONE shell
#   variable with the trailing-newline-preserving sentinel idiom
#       content=$(cat "$file" && printf x); content=${content%x}
#   (a plain $(cat file) strips ALL trailing newlines) and passes it as ONE
#   double-quoted argv token in a command built from POSITIONAL PARAMETERS. That
#   is injection-safe for the same reason `--title` is: the bytes are never
#   re-interpreted by a shell — no heredoc, no eval, no concatenated command
#   string — so `$(...)`, backticks, quotes and newlines travel into execve as
#   inert data. The caller-facing flag keeps the file-based spelling on purpose:
#   it is the same contract as the GitHub sibling's --body-file, and it keeps
#   drafted content out of any command line the caller has to compose.
#
# Purpose:
#   Wraps `glab issue note` so the caller never hand-authors the invocation or
#   the body construction.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any write, but that confirmation used to bind to NOTHING here: this
#   script let `glab` resolve the target instance from ambient state (the cwd's
#   git remotes, an inherited $GITLAB_HOST, glab's own config). On a machine with
#   two configured instances — the very case the gate exists to disambiguate —
#   the gate could confirm host A while this COMMENT silently landed on host B,
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
#   comment.sh --repo PATH --issue N --body-file PATH --confirmed-host HOST
#              [-h|--help]
#
#     --repo PATH       Target project path (required). One or more
#                       '/'-separated segments — GitLab subgroups are supported.
#     --confirmed-host HOST
#                       The GitLab host the account gate already CONFIRMED
#                       (required) — e.g. gitlab.com or a self-managed hostname,
#                       spelled the way `glab auth status` reports it (bare host,
#                       optional ':port', no scheme). See "HOST PINNING" above.
#     --issue N         The issue iid to comment on (required, positive integer).
#     --body-file PATH  Path to a file containing the comment body (required).
#                       Must exist, be readable, be non-empty, and not be the
#                       single character '-'. There is deliberately NO
#                       --body/--message passthrough.
#     -h, --help        Show this help.
#
# Output:
#   PM_COMMENT_URL=<url>   printed IF a note URL for THIS --issue can be found in
#                          glab's output; a successful post that prints no such
#                          URL still exits 0 with this key EMPTY — the URL is a
#                          courtesy, not the proof of success (glab's own exit
#                          code is that proof). Same contract as the GitHub
#                          sibling's. The key is also left empty when the output
#                          is ambiguous (2+ distinct project-matching URLs) or
#                          when the one URL found names a DIFFERENT issue iid
#                          than --issue: a guess is never relayed.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  comment posted
#   1  glab/awk absent / not authenticated / `glab issue note` itself failed
#   2  usage error (missing/invalid argument, unreadable or unusable body-file)
#
# NOT performed here (deliberately upstream): the GitLab-ACCOUNT confirmation
# gate — that is `procedure-gitlab-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`. Sources this skill's own lib/ (see the
#   PM_LIB_DIR preamble below); depends on nothing outside this skill directory.
#
set -eu

# Locate this skill's lib/ RELATIVE TO THIS SCRIPT, using only parameter
# expansion. Never dirname/readlink/realpath/basename: the test harness runs
# every command under a minimal PATH toolbox that deliberately excludes all
# four, so any of them would break the whole suite. The `*)` branch is
# unreachable in practice (the harness and SKILL.md always invoke these scripts
# by an absolute path) but exists so `set -u` can never see an unset
# PM_LIB_DIR.
case "$0" in
	*/*) PM_LIB_DIR=${0%/*}/../lib ;;
	*)   PM_LIB_DIR=../lib ;;
esac

for _pm_lib in pm-diag.sh pm-glab-env.sh pm-validate.sh pm-glab-preconditions.sh pm-glab-url.sh; do
	[ -r "$PM_LIB_DIR/$_pm_lib" ] || { printf '%s: error: cannot locate %s at %s (invoke this script by its absolute path)\n' "${0##*/}" "$_pm_lib" "$PM_LIB_DIR" >&2; exit 1; }
done
unset _pm_lib

# shellcheck source=../lib/pm-diag.sh
. "$PM_LIB_DIR/pm-diag.sh"
# shellcheck source=../lib/pm-glab-env.sh
. "$PM_LIB_DIR/pm-glab-env.sh"
# shellcheck source=../lib/pm-validate.sh
. "$PM_LIB_DIR/pm-validate.sh"
# shellcheck source=../lib/pm-glab-preconditions.sh
. "$PM_LIB_DIR/pm-glab-preconditions.sh"
# shellcheck source=../lib/pm-glab-url.sh
. "$PM_LIB_DIR/pm-glab-url.sh"

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --issue N --body-file PATH --confirmed-host HOST
             [-h|--help]

Add a comment (a GitLab note) to an issue via glab. The body is ALWAYS handed
over as a file (--body-file) — there is no --body/--message passthrough.

Example:
  $PROG --repo group/subgroup/project --issue 42 --body-file /tmp/note.md \\
        --confirmed-host gitlab.com

Options:
  --repo PATH       Target project path (required; subgroups allowed).
  --confirmed-host HOST
                    The GitLab host the account gate already confirmed
                     (required; bare hostname, optional ':port', no scheme).
                     Pins glab to that instance.
  --issue N         The issue iid to comment on (required).
  --body-file PATH  Path to the comment body (required; must exist, be
                     readable, non-empty, and not the single character '-').
  -h, --help        Show this help.

Prints (may be empty even on success):
  PM_COMMENT_URL=<url>

Exit codes:
  0  posted
  1  glab/awk absent / not authenticated / glab failure
  2  usage error
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_CONFIRMED_HOST=""
OPT_ISSUE=""
OPT_BODY_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)      need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--confirmed-host) need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		--issue)     need_arg "$1" "${2:-}"; OPT_ISSUE=$2; shift ;;
		--body-file) need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_ISSUE" ] || { usage >&2; error "--issue is required"; exit 2; }
is_positive_int "$OPT_ISSUE" || { usage >&2; error "--issue must be a positive integer (a GitLab iid), got: $OPT_ISSUE"; exit 2; }

[ -n "$OPT_BODY_FILE" ] || { usage >&2; error "--body-file is required"; exit 2; }
if [ ! -f "$OPT_BODY_FILE" ] || [ ! -r "$OPT_BODY_FILE" ]; then
	usage >&2
	error "--body-file does not exist or is not readable: $OPT_BODY_FILE"
	exit 2
fi

# Read the comment into ONE variable, byte-for-byte (sentinel idiom — see this
# file's header for why a plain $(cat) is wrong).
#
# `cat … && printf x`, NOT `cat …; printf x`: with the semicolon the command
# substitution takes ITS exit status from `printf`, which always succeeds, so a
# mid-read I/O failure on `cat` was invisible even under `set -e` — the caller
# then saw either a truncated comment posted to the tracker or the misleading "is
# empty" diagnostic below instead of an honest read failure.
if ! COMMENT=$(cat "$OPT_BODY_FILE" && printf x); then
	error "failed to read --body-file: $OPT_BODY_FILE"
	exit 2
fi
COMMENT=${COMMENT%x}

# COMMENT_PROBE is COMMENT with trailing newlines removed (command substitution
# strips them), used ONLY for the two guards below — the value actually sent to
# glab stays the untouched COMMENT.
COMMENT_PROBE=$(printf '%s' "$COMMENT")
if [ -z "$COMMENT_PROBE" ]; then
	usage >&2
	error "--body-file is empty: $OPT_BODY_FILE"
	exit 2
fi
if [ "$COMMENT_PROBE" = "-" ]; then
	usage >&2
	error "--body-file contains only '-', which glab may read as \"open an interactive editor\" — that would hang a non-interactive caller"
	exit 2
fi

[ -n "$OPT_CONFIRMED_HOST" ] || { usage >&2; error "--confirmed-host is required (the host procedure-gitlab-auth's account gate confirmed)"; exit 2; }
is_valid_confirmed_host "$OPT_CONFIRMED_HOST" || { usage >&2; error "--confirmed-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_CONFIRMED_HOST"; exit 2; }

# Pin glab's target instance to the CONFIRMED host. Exported so every `glab`
# child of THIS process inherits it; nothing outside this process is touched.
# This must happen before the auth precondition below, so even that check asks
# about the host the caller confirmed. See "HOST PINNING" in this file's header.
pm_pin_gitlab_host "$OPT_CONFIRMED_HOST"

# ---------------------------------------------------------------------------
# glab preconditions
# ---------------------------------------------------------------------------
require_glab_cli

require_awk "read the note URL back"

require_glab_auth

init_tmp_err pm-glab-comment

# ---------------------------------------------------------------------------
# Post the comment. The body is ONE argv token; it is never interpolated into a
# command string here. The issue iid goes in POSITIONALLY — `glab issue note`
# takes `<issue-id>` positionally and has no `--issue`-style flag; the
# caller-facing spelling stays a flag for symmetry with the GitHub sibling.
# ---------------------------------------------------------------------------
set -- glab issue note "$OPT_ISSUE" --repo "$OPT_REPO" --message "$COMMENT"

if ! NOTE_OUT=$("$@" 2>"$TMP_ERR"); then
	error "glab issue note failed"
	emit_captured_stderr
	exit 1
fi

# BOTH captured streams are scanned as ONE pool, in a SINGLE pass, never
# stdout-first-with-a-stderr-fallback: glab may put the real URL on stderr, and
# with a fallback an adversarial COMMENT or issue TITLE echoed on stdout was then
# the only candidate the ambiguity guard ever saw (SEC-003). Pooling means the
# spoof and the genuine URL are seen together — two distinct candidates — and fail
# closed. An absent URL is NOT a failure (courtesy contract): the key prints empty.
COMMENT_URL_CANDIDATES=$(extract_note_url_candidates \
	"$(printf '%s\n%s\n' "$NOTE_OUT" "$(cat "$TMP_ERR")")" "$OPT_REPO" "$OPT_CONFIRMED_HOST")

# FAIL CLOSED on ambiguity — see extract_note_url_candidates's header: at most one
# candidate per distinct URL, so 2+ means genuine ambiguity or a spoof. THE
# PER-SITE DELTA: this script does NOT invent a failure exit the way
# create-issue.sh does — the note was already posted and PM_COMMENT_URL is a
# documented courtesy field, so ambiguity leaves the key EMPTY and warns instead of
# failing a completed post.
#
# THE iid CROSS-CHECK (SEC-003): unlike create-issue.sh — which is extracting an iid
# it does not yet know — this script was HANDED the iid it just commented on, already
# validated as a positive integer. That makes --issue authoritative ground truth, so
# the surviving candidate's own iid segment must equal it literally. A
# project-matching URL for some OTHER issue (a URL-shaped comment or title naming a
# different iid) therefore cannot be relayed as this note's URL. A mismatch is
# treated exactly like "no candidate found": empty key + warn, still exit 0.
# pm_url_matching_iid (lib/pm-glab-url.sh) owns that comparison — including
# stripping the optional '#note_<id>' anchor FIRST, so the segment compared is the
# ISSUE iid and not the note id — and update-issue.sh calls the same helper.
COMMENT_URL=""
if [ "$(count_lines "$COMMENT_URL_CANDIDATES")" -gt 1 ]; then
	warn "glab issue note printed MORE THAN ONE distinct issue/note URL for project '$OPT_REPO'; refusing to guess, so PM_COMMENT_URL is left empty — resolve it with find-duplicate.sh (a comment or TITLE that looks like a URL produces this)"
	printf '%s\n' "$COMMENT_URL_CANDIDATES" | sed 's/^/  /' >&2
elif [ -n "$COMMENT_URL_CANDIDATES" ]; then
	# The one surviving candidate — the guard above rejected 2+, so this is the
	# whole value (see extract_note_url_candidates's header).
	COMMENT_URL=$(pm_url_matching_iid "$COMMENT_URL_CANDIDATES" "$OPT_ISSUE")
	if [ -z "$COMMENT_URL" ]; then
		warn "glab issue note printed a URL for issue #$(pm_url_iid "$COMMENT_URL_CANDIDATES"), not the issue that was commented on (#$OPT_ISSUE), so PM_COMMENT_URL is left empty — resolve it with find-duplicate.sh (a comment or TITLE that looks like a URL produces this)"
		printf '%s\n' "$COMMENT_URL_CANDIDATES" | sed 's/^/  /' >&2
	fi
fi

printf 'PM_COMMENT_URL=%s\n' "$COMMENT_URL"
exit 0
