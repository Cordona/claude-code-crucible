#!/usr/bin/env sh
#
# close-issue.sh — close a GitLab issue, with an optional closing comment
#                  always handed over by the caller as a FILE, never built in
#                  shell.
#
# Mechanism for --comment-file (a deliberate choice, and here it is the ONLY
# option glab offers): `glab issue close` takes the issue id/URL positionally
# and has NO comment flag at all — its entire flag set is `-R/--repo` and
# `-h/--help` (verified against glab 1.112.0's own --help). So a closing comment
# is posted as a SEPARATE `glab issue note --message` call BEFORE the close, the
# same two-step shape the GitHub sibling uses (there for a rule-driven reason;
# here also because no one-step alternative exists).
#
# NO `--reason` FLAG EXISTS, AND THIS SCRIPT DOES NOT INVENT ONE. `gh issue
# close --reason completed|not_planned` has no GitLab counterpart: `glab issue
# close` has even less surface than gh's, and GitLab's issue model has no
# "not planned" close reason exposed through the CLI. That asymmetry is a
# documented GitHub-only feature with no GitLab mirror — not an omission to be
# "fixed" by faking one via a label or a note.
#
# WHY THE CALLER-FACING FLAG IS `--comment-file` BUT glab GETS
# `-m/--message "$content"`:
#   Same injection-safety rule, same GitLab mechanism as comment.sh: the caller
#   always hands over a FILE; the script reads it into ONE variable with the
#   trailing-newline-preserving sentinel idiom and passes it as ONE
#   double-quoted argv token in a command built from POSITIONAL PARAMETERS, so
#   the bytes are never re-interpreted by a shell. See comment.sh's header for
#   the full reasoning.
#
# Purpose:
#   Wraps `glab issue close` (plus an optional preceding note) so the caller
#   never hand-authors the invocation or the comment construction.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any write, but that confirmation used to bind to NOTHING here: this
#   script let `glab` resolve the target instance from ambient state (the cwd's
#   git remotes, an inherited $GITLAB_HOST, glab's own config). On a machine with
#   two configured instances — the very case the gate exists to disambiguate —
#   the gate could confirm host A while this CLOSE silently landed on host B,
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
#   the wrong place — fail closed either way. It also keeps the optional closing
#   NOTE and the CLOSE itself on one instance, so the two halves of this
#   two-step operation can never land on different servers.
#
#   This script does NOT re-implement the account-confirmation UX; that stays
#   `procedure-gitlab-auth`'s job, upstream (see "NOT performed here" below).
#   The flag only ENFORCES that the write targets the host already confirmed.
#
# Usage:
#   close-issue.sh --repo PATH --issue N --confirmed-host HOST
#                  [--comment-file PATH] [-h|--help]
#
#     --repo PATH          Target project path (required). One or more
#                          '/'-separated segments — GitLab subgroups are
#                          supported.
#     --confirmed-host HOST
#                          The GitLab host the account gate already CONFIRMED
#                          (required) — e.g. gitlab.com or a self-managed
#                          hostname, spelled the way `glab auth status` reports
#                          it (bare host, optional ':port', no scheme). See
#                          "HOST PINNING" above.
#     --issue N            The issue iid to close (required, positive integer).
#     --comment-file PATH  Path to a file containing an optional closing
#                          comment, posted BEFORE the close (must exist, be
#                          readable, non-empty, and not the single character '-'
#                          if given). There is deliberately NO inline --comment
#                          passthrough.
#     -h, --help           Show this help.
#
# Output: none on success beyond the exit code (diagnostics go to stderr) —
#   `glab issue close` returns no URL worth relaying, same as the GitHub
#   sibling's contract.
#
# Exit codes:
#   0  issue closed (and the closing comment, if any, was posted first)
#   1  glab absent / not authenticated / the comment post failed / `glab issue
#      close` itself failed
#   2  usage error (missing/invalid argument, unreadable or unusable
#      comment-file)
#
# NOT performed here (deliberately upstream): the GitLab-ACCOUNT confirmation
# gate — that is `procedure-gitlab-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays parseable and this
# non-interactive script can never block on a prompt. NOTE: neither
# `glab issue close` nor `glab issue note` has a `--yes` flag (verified against
# glab 1.112.0's --help), so GLAB_NO_PROMPT is the only prompt suppression
# available here — passing `--yes` would make glab reject the whole invocation as
# an unknown flag. Always passing `--message` is what keeps the note out of
# glab's editor.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --issue N --confirmed-host HOST
             [--comment-file PATH] [-h|--help]

Close a GitLab issue via glab. An optional closing comment is ALWAYS handed over
as a file (--comment-file), posted as a separate note BEFORE the close — there
is no inline --comment. There is deliberately no --reason flag: glab issue close
has no such option and GitLab exposes no close-reason through the CLI.

Example:
  $PROG --repo group/subgroup/project --issue 42 --confirmed-host gitlab.com \\
        --comment-file /tmp/closing-note.md

Options:
  --repo PATH          Target project path (required; subgroups allowed).
  --confirmed-host HOST
                       The GitLab host the account gate already confirmed
                        (required; bare hostname, optional ':port', no scheme).
                        Pins glab to that instance.
  --issue N            The issue iid to close (required).
  --comment-file PATH  An optional closing comment, posted before the close
                        (must exist, be readable, non-empty, and not the single
                        character '-' if given).
  -h, --help           Show this help.

Exit codes:
  0  closed
  1  glab absent / not authenticated / comment post failed / close failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the iid GitLab would echo back. Both used to slip through and
# surface as a confusing `glab` failure (exit 1) instead of the usage error
# (exit 2) they are.
is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;   # empty or a non-digit
		0*) return 1 ;;            # a bare '0', and any leading-zero form
		*) return 0 ;;
	esac
}

# is_valid_gitlab_project_path VALUE — allow-list: letters, digits, '.', '_',
# '-' per segment, and ONE OR MORE '/'-separated segments, with no empty
# segment and no '.'/'..' path segment.
#
# WHY this is NOT procedure-gh-issues' is_valid_repo_slug: a GitHub slug is
# always exactly OWNER/REPO (that validator hard-rejects a second '/'), but
# GitLab supports nested groups, so a real project path can be
# "group/subgroup/project" or deeper. Rejecting the extra segments would make
# every subgroup project unreachable. A LONE segment with no '/' at all is
# still rejected: a bare project name is never a valid full path.
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

# is_valid_confirmed_host VALUE — allow-list for the host the ACCOUNT GATE
# confirmed, before it becomes this process's GITLAB_HOST: letters, digits, '.',
# '-', '_' and an optional ':port'. Rejects whitespace, shell metacharacters, a
# leading '-', and any empty label. Spelled the way `glab auth status` reports a
# host — and the way manage_glab_accounts.sh's own is_valid_hostname accepts one
# — so the gate's answer can be passed straight through.
#
# A SCHEME-QUALIFIED value ("https://gitlab.com") is rejected on purpose: glab
# accepts both spellings, so allowing them here would let two different strings
# name one host, and the whole point of this flag is a single unambiguous target
# the caller and this script agree on.
is_valid_confirmed_host() {
	case "$1" in
		'') return 1 ;;
		*[!A-Za-z0-9._:-]*) return 1 ;;
		-*) return 1 ;;
		.*|*.|*..*) return 1 ;;
		*) return 0 ;;
	esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_CONFIRMED_HOST=""
OPT_ISSUE=""
OPT_COMMENT_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)          need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--confirmed-host) need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		--issue)         need_arg "$1" "${2:-}"; OPT_ISSUE=$2; shift ;;
		--comment-file)  need_arg "$1" "${2:-}"; OPT_COMMENT_FILE=$2; shift ;;
		-h|--help)       usage; exit 0 ;;
		--)              shift; break ;;
		-*)              usage >&2; error "unknown option: $1"; exit 2 ;;
		*)               usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_ISSUE" ] || { usage >&2; error "--issue is required"; exit 2; }
is_positive_int "$OPT_ISSUE" || { usage >&2; error "--issue must be a positive integer (a GitLab iid), got: $OPT_ISSUE"; exit 2; }

# The comment is resolved ONLY when the caller asked for one.
COMMENT=""
if [ -n "$OPT_COMMENT_FILE" ]; then
	if [ ! -f "$OPT_COMMENT_FILE" ] || [ ! -r "$OPT_COMMENT_FILE" ]; then
		usage >&2
		error "--comment-file does not exist or is not readable: $OPT_COMMENT_FILE"
		exit 2
	fi
	# Sentinel idiom — a plain $(cat file) strips ALL trailing newlines.
	#
	# `cat … && printf x`, NOT `cat …; printf x`: with the semicolon the command
	# substitution takes ITS exit status from `printf`, which always succeeds, so
	# a mid-read I/O failure on `cat` was invisible even under `set -e` — the
	# caller then saw a truncated closing comment posted to the tracker, or the
	# misleading "is empty" diagnostic below, instead of an honest read failure.
	if ! COMMENT=$(cat "$OPT_COMMENT_FILE" && printf x); then
		error "failed to read --comment-file: $OPT_COMMENT_FILE"
		exit 2
	fi
	COMMENT=${COMMENT%x}

	# COMMENT_PROBE is COMMENT with trailing newlines removed (command
	# substitution strips them), used ONLY for the two guards below — the value
	# actually sent to glab stays the untouched COMMENT.
	COMMENT_PROBE=$(printf '%s' "$COMMENT")
	if [ -z "$COMMENT_PROBE" ]; then
		usage >&2
		error "--comment-file is empty: $OPT_COMMENT_FILE"
		exit 2
	fi
	if [ "$COMMENT_PROBE" = "-" ]; then
		usage >&2
		error "--comment-file contains only '-', which glab may read as \"open an interactive editor\" — that would hang a non-interactive caller"
		exit 2
	fi
fi

[ -n "$OPT_CONFIRMED_HOST" ] || { usage >&2; error "--confirmed-host is required (the host procedure-gitlab-auth's account gate confirmed)"; exit 2; }
is_valid_confirmed_host "$OPT_CONFIRMED_HOST" || { usage >&2; error "--confirmed-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_CONFIRMED_HOST"; exit 2; }

# Pin glab's target instance to the CONFIRMED host. Exported so every `glab`
# child of THIS process inherits it — which is also what keeps the optional
# closing note and the close itself on ONE instance; nothing outside this process
# is touched. See "HOST PINNING" in this file's header.
GITLAB_HOST=$OPT_CONFIRMED_HOST
export GITLAB_HOST

# ---------------------------------------------------------------------------
# glab preconditions
# ---------------------------------------------------------------------------
if ! command -v glab >/dev/null 2>&1; then
	error "GitLab CLI (glab) is not installed"
	warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
	exit 1
fi

# The bare form checks only the current context's instance, so --all is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr).
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-glab-close-issue.err.XXXXXX")
# TWO traps, not one combined `EXIT INT TERM`: a Ctrl-C during a slow `glab`
# call would otherwise leak the temp file, but a combined handler would clean up
# and then RESUME the interrupted command's error path, which goes on to read the
# file it just unlinked. The INT/TERM handler therefore terminates the script
# itself (130 = SIGINT's conventional status). The EXIT trap still runs after it,
# and a second `rm -f` on an already-removed path is a no-op.
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# 1. Post the closing comment FIRST, if requested — as a separate note, the
#    same mechanism comment.sh uses. If it fails, the close is NEVER attempted:
#    no partial "commented but didn't close" surprise from a script that
#    silently continued past a failure.
# ---------------------------------------------------------------------------
COMMENT_POSTED=0
if [ -n "$OPT_COMMENT_FILE" ]; then
	set -- glab issue note "$OPT_ISSUE" --repo "$OPT_REPO" --message "$COMMENT"
	if ! "$@" >/dev/null 2>"$TMP_ERR"; then
		error "failed to post closing comment on issue #$OPT_ISSUE"
		sed 's/^/  /' "$TMP_ERR" >&2
		exit 1
	fi
	COMMENT_POSTED=1
fi

# ---------------------------------------------------------------------------
# 2. Close. The issue iid goes in POSITIONALLY — `glab issue close` takes
#    `<id>|<url>` positionally, and --repo is its only other flag.
# ---------------------------------------------------------------------------
set -- glab issue close "$OPT_ISSUE" --repo "$OPT_REPO"

if ! "$@" >/dev/null 2>"$TMP_ERR"; then
	error "glab issue close failed for issue #$OPT_ISSUE"
	# If the comment already posted, a bare retry would post it AGAIN — say so
	# explicitly so the caller retries without --comment-file.
	if [ "$COMMENT_POSTED" -eq 1 ]; then
		warn "the closing comment was ALREADY POSTED — retry WITHOUT --comment-file to avoid posting it twice"
	fi
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

exit 0
