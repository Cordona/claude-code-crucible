#!/usr/bin/env sh
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
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

# Pin glab's own optional output/behavior so stdout stays parseable and this
# non-interactive script can never block on a prompt. NOTE: `glab issue note`
# has NO `--yes` flag (verified against glab 1.112.0's --help), so
# GLAB_NO_PROMPT is the only prompt suppression available here — passing `--yes`
# would make glab reject the whole invocation as an unknown flag. Always passing
# `--message` is what keeps glab out of its editor.
GLAB_NO_PROMPT=true
GLAB_CHECK_UPDATE=false
GLAB_SHOW_WHATS_NEW=false
export GLAB_NO_PROMPT GLAB_CHECK_UPDATE GLAB_SHOW_WHATS_NEW

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

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

# extract_note_url_candidates TEXT REPO — print every DISTINCT
# whitespace-delimited token in TEXT that is an issue-note URL (or a plain issue
# URL) OF THIS PROJECT, one per line, in first-appearance order. glab's note
# output decoration is not a documented contract, so the URL is located by SHAPE
# (a GitLab issue route, optionally with a #note_<digits> anchor) rather than by
# position. awk always exits 0, so this never trips `set -e`.
#
# WHY BOTH path segments are accepted: GitLab migrated issue URLs to the
# work-items path, and current `glab issue note` prints
# ".../-/work_items/<iid>#note_<id>" — live-confirmed against a real project,
# where matching only "/issues/" left PM_COMMENT_URL empty despite glab printing
# a perfectly good URL. The classic "/issues/<iid>" shape is kept rather than
# swapped out, because an older self-managed instance or a future glab talking to
# a differently-configured server may still emit it; accepting either is strictly
# safer than trading one hard assumption for another.
#
# THE ONE PLACE THE DEDUP/AMBIGUITY RATIONALE IS WRITTEN OUT — every call site
# below points here instead of restating it:
#   * glab decorates its note output, and a shape-matching token that comes from
#     the COMMENT or the issue TITLE rather than from glab's own URL line used to
#     win, because the first shape match anywhere in the captured output was taken
#     — leaving PM_COMMENT_URL pointing at something that is not this note.
#   * So a candidate must be a URL of the CONFIRMED --repo project, ALL distinct
#     candidates are reported, and the dedup keeps the FIRST occurrence of each
#     distinct value while dropping every later repeat.
#   * Therefore the output holds AT MOST ONE LINE PER DISTINCT URL. The caller
#     never chooses between occurrences: it either takes the single survivor, or
#     sees 2+ — which can only mean genuinely different URLs, i.e. ambiguity or a
#     spoof — and fails closed. Identical repeats collapse to one candidate.
#
# HOW THE PROJECT MATCH IS ANCHORED (SEC-002): the repo path must follow the HOST
# DIRECTLY. An unanchored `index($i, "/" repo "/")` substring test accepted the
# project path at ANY depth under ANY host, so
# "https://attacker.example/x/<repo>/-/issues/5" qualified — the ambiguity guard
# usually caught it (a genuine URL is normally present too, making 2+
# candidates), but the filter must not lean on that backstop alone. So: scheme +
# host are stripped, the remainder's LITERAL prefix must be "<repo>/", and what
# follows must be one of GitLab's own issue routes. The prefix test is a literal
# string compare, never a regex, so a '.' in a project path cannot act as a
# wildcard and no metacharacter escaping is needed.
extract_note_url_candidates() {
	printf '%s\n' "$1" | awk -v repo="$2" '
		{
			for (i = 1; i <= NF; i++) {
				tok = $i
				if (tok !~ /^https?:\/\/[^\/]+\//) continue
				path = tok
				sub(/^https?:\/\/[^\/]+\//, "", path)
				if (substr(path, 1, length(repo) + 1) != repo "/") continue
				rest = substr(path, length(repo) + 2)
				if (rest !~ /^(-\/)?(issues|work_items)\/[0-9]+(#note_[0-9]+)?$/) continue
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

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required to read the note URL back)"
	exit 1
fi

# The bare form checks only the current context's instance, so --all is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr).
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-glab-comment.err.XXXXXX")
# TWO traps, not one combined `EXIT INT TERM`: a Ctrl-C during a slow `glab`
# call would otherwise leak the temp file, but a combined handler would clean up
# and then RESUME the interrupted command's error path, which goes on to read the
# file it just unlinked. The INT/TERM handler therefore terminates the script
# itself (130 = SIGINT's conventional status). The EXIT trap still runs after it,
# and a second `rm -f` on an already-removed path is a no-op.
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Post the comment. The body is ONE argv token; it is never interpolated into a
# command string here. The issue iid goes in POSITIONALLY — `glab issue note`
# takes `<issue-id>` positionally and has no `--issue`-style flag; the
# caller-facing spelling stays a flag for symmetry with the GitHub sibling.
# ---------------------------------------------------------------------------
set -- glab issue note "$OPT_ISSUE" --repo "$OPT_REPO" --message "$COMMENT"

if ! NOTE_OUT=$("$@" 2>"$TMP_ERR"); then
	error "glab issue note failed"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# BOTH captured streams are scanned as ONE pool, in a SINGLE pass, never
# stdout-first-with-a-stderr-fallback: glab may put the real URL on stderr, and
# with a fallback an adversarial COMMENT or issue TITLE echoed on stdout was then
# the only candidate the ambiguity guard ever saw (SEC-003). Pooling means the
# spoof and the genuine URL are seen together — two distinct candidates — and fail
# closed. An absent URL is NOT a failure (courtesy contract): the key prints empty.
COMMENT_URL_CANDIDATES=$(extract_note_url_candidates \
	"$(printf '%s\n%s\n' "$NOTE_OUT" "$(cat "$TMP_ERR")")" "$OPT_REPO")

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
# treated exactly like "no candidate found": empty key + warn, still exit 0. The
# optional '#note_<id>' anchor is stripped FIRST, so the segment compared is the
# ISSUE iid and not the note id.
COMMENT_URL=""
if [ "$(count_lines "$COMMENT_URL_CANDIDATES")" -gt 1 ]; then
	warn "glab issue note printed MORE THAN ONE distinct issue/note URL for project '$OPT_REPO'; refusing to guess, so PM_COMMENT_URL is left empty — resolve it with find-duplicate.sh (a comment or TITLE that looks like a URL produces this)"
	printf '%s\n' "$COMMENT_URL_CANDIDATES" | sed 's/^/  /' >&2
elif [ -n "$COMMENT_URL_CANDIDATES" ]; then
	# The one surviving candidate — the guard above rejected 2+, so this is the
	# whole value (see extract_note_url_candidates's header).
	CANDIDATE_IID=${COMMENT_URL_CANDIDATES%%#*}
	CANDIDATE_IID=${CANDIDATE_IID##*/}
	if [ "$CANDIDATE_IID" = "$OPT_ISSUE" ]; then
		COMMENT_URL=$COMMENT_URL_CANDIDATES
	else
		warn "glab issue note printed a URL for issue #$CANDIDATE_IID, not the issue that was commented on (#$OPT_ISSUE), so PM_COMMENT_URL is left empty — resolve it with find-duplicate.sh (a comment or TITLE that looks like a URL produces this)"
		printf '%s\n' "$COMMENT_URL_CANDIDATES" | sed 's/^/  /' >&2
	fi
fi

printf 'PM_COMMENT_URL=%s\n' "$COMMENT_URL"
exit 0
