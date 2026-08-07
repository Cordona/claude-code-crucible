#!/usr/bin/env sh
#
# create-issue.sh — create a GitLab issue via `glab`, with the artifact BODY
#                    always handed over by the caller as a FILE (--body-file)
#                    and never built in shell.
#
# WHY A FILE ON THE OUTSIDE BUT `--description` ON THE INSIDE (read this before
# changing anything here):
#   The injection-safety rule is the same as the GitHub sibling's — an issue
#   body pulled from real repo content (file paths, code snippets, existing
#   issue text) can contain a line that collides with a heredoc delimiter, a
#   `$(...)`, or a backtick, so it must never be *constructed* in shell. But
#   `glab issue create` has NO --description-file flag (verified against glab
#   1.112.0's own --help: only `-d/--description <string>`, and setting it to
#   literally "-" opens an interactive editor). So this script cannot pass a
#   path through the way procedure-gh-issues' create-issue.sh passes
#   --body-file.
#
#   The mechanism instead — identical to procedure-glab-mr's create-mr.sh,
#   which was built, live-tested and reviewed first: read the caller's file
#   into ONE shell variable, then pass that variable as ONE double-quoted argv
#   token to `--description`, with the whole command built as POSITIONAL
#   PARAMETERS (POSIX sh's array equivalent). This is injection-safe for
#   exactly the reason `--title` is safe: the bytes are never re-interpreted by
#   a shell. There is no heredoc, no eval, no string-concatenated command line
#   — the file's bytes travel as a single argv value straight into execve,
#   where `$(...)`, backticks, quotes and newlines are inert data. What must
#   NEVER be done here is to interpolate the body into a command STRING (or a
#   heredoc, or `sh -c`), which would hand those same bytes to a parser.
#
#   The read uses the sentinel idiom:
#       content=$(cat "$file" && printf x); content=${content%x}
#   because a plain `$(cat file)` strips ALL trailing newlines, not just one.
#   The sentinel makes the variable byte-identical to the file, so the
#   description GitLab stores is exactly what the caller drafted — trailing
#   blank lines included.
#
# Purpose:
#   Wraps `glab issue create` with the preconditions glab itself does NOT
#   check: an unknown --label or --milestone makes the create fail AFTER
#   everything else validated, creating nothing but wasting the round-trip with
#   a raw glab error. This script checks labels/milestone exist FIRST and fails
#   with a precise, actionable error naming what's missing. It never
#   auto-creates a label or a milestone.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any write, but that confirmation used to bind to NOTHING here: this
#   script let `glab` resolve the target instance from ambient state (the cwd's
#   git remotes, an inherited $GITLAB_HOST, glab's own config). On a machine with
#   two configured instances — the very case the gate exists to disambiguate —
#   the gate could confirm host A while this CREATE silently landed on host B,
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
#   create-issue.sh --repo PATH --title STR --body-file PATH
#                    --confirmed-host HOST
#                    [--label NAME]... [--milestone STR] [--assignee LOGIN]...
#                    [-h|--help]
#
#     --repo PATH        Target project path (required). One or more
#                        '/'-separated segments — GitLab subgroups are
#                        supported (e.g. group/subgroup/project).
#     --confirmed-host HOST
#                        The GitLab host the account gate already CONFIRMED
#                        (required) — e.g. gitlab.com or a self-managed
#                        hostname, spelled the way `glab auth status` reports it
#                        (bare host, optional ':port', no scheme). See "HOST
#                        PINNING" above.
#     --title STR        Issue title (required).
#     --body-file PATH   Path to a file containing the issue body (required).
#                        Must exist, be readable, be non-empty, and not be the
#                        single character '-' (which glab reads as "open an
#                        editor"). There is deliberately NO --body/--description
#                        passthrough — the caller always hands over a file.
#     --label NAME       A label to apply. Repeatable, and/or a
#                        comma-separated list in one occurrence. Pre-checked
#                        for existence; never auto-created (ensure-labels.sh
#                        is the separate, opt-in step for that).
#     --milestone STR    An EXISTING milestone TITLE (pre-checked). A numeric
#                        global milestone id — which raw glab also accepts — is
#                        deliberately NOT supported here; see the milestone
#                        precondition section below.
#     --assignee LOGIN   A GitLab username to assign. Repeatable and/or
#                        comma-separated.
#     -h, --help         Show this help.
#
#   Deliberately NOT exposed: glab's `--epic`. Epic linking is handled by
#   link-children.sh's task-list mechanism, on a plain issue acting as the
#   epic — GitLab's native epics are GROUP-level and a paid-tier feature that
#   may not exist on the target account, and `glab issue update` has no --epic
#   flag at all, so an epic wired at create time could never be re-wired later.
#   Keeping the two paths consistent beats exposing a flag only half of the
#   lifecycle can honor. Also not exposed: --confidential, --due-date,
#   --weight, --linked-issues, --linked-mr — out of this wrapper's contract
#   (which mirrors the GitHub sibling's), not blocked by any glab limitation.
#
# Output:
#   On success, stdout carries machine-parseable keys the caller can relay:
#     PM_ISSUE_NUMBER=<iid>
#     PM_ISSUE_URL=<url>
#   PM_ISSUE_NUMBER is GitLab's per-project **iid** (the `#123` number a human
#   sees, and the tail of the issue's URL) — never the globally unique `id`,
#   which is useless to a caller. `glab issue create` supports no
#   `--output json`, so the printed URL is the only machine-usable handle it
#   returns, and the iid is that URL's trailing segment.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  issue created
#   1  glab/awk absent / not authenticated / an unknown label or milestone /
#      a precondition lookup failed / `glab issue create` itself failed / no
#      issue URL could be found in glab's output
#   2  usage error (missing/invalid argument, unreadable or unusable body-file)
#
# NOT performed here (deliberately upstream): the GitLab-ACCOUNT confirmation
# gate (which login is active) — that is `procedure-gitlab-auth`'s job, run by
# the calling agent BEFORE this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Runs identically on macOS (BSD
#   userland / Bash 3.2) and Linux (GNU coreutils). Every external binary is
#   guarded with `command -v`. Self-contained: sources nothing.
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

# ---------------------------------------------------------------------------
# Diagnostics (all to stderr — stdout stays machine-clean)
# ---------------------------------------------------------------------------
warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --title STR --body-file PATH --confirmed-host HOST
              [--label NAME]... [--milestone STR] [--assignee LOGIN]...
              [-h|--help]

Create a GitLab issue via glab. The body is ALWAYS handed over as a file
(--body-file) — there is no --body/--description passthrough.

Example:
  $PROG --repo group/subgroup/project --title "Export to CSV" \\
        --body-file /tmp/story.md --confirmed-host gitlab.com --label type:story

Options:
  --repo PATH        Target project path (required; subgroups allowed).
  --confirmed-host HOST
                     The GitLab host the account gate already confirmed
                      (required; bare hostname, optional ':port', no scheme).
                      Pins glab to that instance.
  --title STR        Issue title (required).
  --body-file PATH   Path to the issue body (required; must exist, be
                      readable, non-empty, and not the single character '-',
                      which glab reads as "open an editor").
  --label NAME       A label to apply. Repeatable and/or comma-separated.
                      Must already exist (run ensure-labels.sh first if it
                      does not) — never auto-created here.
  --milestone STR    An existing milestone TITLE (a numeric global id is not
                      supported by this wrapper).
  --assignee LOGIN   A username to assign. Repeatable and/or comma-separated.
  -h, --help         Show this help.

On success, prints:
  PM_ISSUE_NUMBER=<iid>
  PM_ISSUE_URL=<url>

Exit codes:
  0  created
  1  glab/awk absent / not authenticated / unknown label or milestone /
     glab failure / no issue URL found
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

# extract_issue_url_candidates TEXT REPO — print every DISTINCT
# whitespace-delimited token in TEXT that is an issue URL OF THIS PROJECT, one
# per line, in first-appearance order.
#
# `glab issue create` prints a human-oriented block and its exact decoration is
# not a documented contract, so the URL is located by SHAPE rather than by line
# or column position. awk always exits 0, so this never trips `set -e`.
#
# WHY BOTH path segments are accepted: GitLab migrated issue URLs to the
# work-items path, and current `glab issue create` prints
# ".../-/work_items/<iid>" — live-confirmed against a real project, where
# matching only "/issues/" made this function return nothing and the caller
# below abort with "reported success but printed no issue URL" even though the
# issue HAD been created. The classic "/issues/<iid>" shape is kept rather than
# swapped out, because an older self-managed instance or a future glab talking
# to a differently-configured server may still emit it; accepting either is
# strictly safer than trading one hard assumption for another.
#
# THE ONE PLACE THE DEDUP/AMBIGUITY RATIONALE IS WRITTEN OUT — every call site
# below points here instead of restating it:
#   * glab prints the issue TITLE on the line BEFORE the URL, so a title that
#     merely LOOKS like an issue URL (adversarial, or one that just quotes a link)
#     used to be picked up instead of the real URL: the first shape match in the
#     whole captured output won, and PM_ISSUE_URL/PM_ISSUE_NUMBER then pointed at
#     something the caller never created, which a follow-up comment.sh or
#     link-children.sh would then target.
#   * So a candidate must be a URL of the CONFIRMED --repo project, ALL distinct
#     candidates are reported, and the dedup keeps the FIRST occurrence of each
#     distinct value while dropping every later repeat.
#   * Therefore the output holds AT MOST ONE LINE PER DISTINCT URL. The caller
#     never chooses between occurrences: it either has exactly one surviving line
#     and takes it, or it has 2+ — which can only mean genuinely different URLs,
#     i.e. ambiguity or a spoof — and fails closed. Identical repeats collapse to
#     one candidate, so a title quoting the real URL verbatim is harmless.
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
extract_issue_url_candidates() {
	printf '%s\n' "$1" | awk -v repo="$2" '
		{
			for (i = 1; i <= NF; i++) {
				tok = $i
				if (tok !~ /^https?:\/\/[^\/]+\//) continue
				path = tok
				sub(/^https?:\/\/[^\/]+\//, "", path)
				if (substr(path, 1, length(repo) + 1) != repo "/") continue
				rest = substr(path, length(repo) + 2)
				if (rest !~ /^(-\/)?(issues|work_items)\/[0-9]+$/) continue
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
# Label lookup paging.
#
# `glab label list` has NO `--paginate` equivalent (unlike `gh api`, which the
# GitHub sibling uses) and its own default page size is only 30 — so a single
# bare call would silently MISS every label past the first page and report a
# perfectly real label as "not found", refusing a legitimate create. Hence an
# explicit page walk with the API's maximum page size.
# ---------------------------------------------------------------------------
LABELS_PER_PAGE=100
LABELS_MAX_PAGES=50

# list_all_labels REPO — print every label name in REPO, one per line, walking
# `glab label list` a page at a time until a SHORT page proves the last page
# was reached. Returns 1 if any page query fails; glab's own diagnostics
# accumulate in $TMP_ERR, which must already exist.
#
# Each page is normalized with awk: a SURROUNDING PAIR of double quotes glab's
# --jq may apply to a string result is stripped and blank lines dropped, the same
# defensive normalization procedure-glab-mr applies to its own --jq rows.
#
# A SURROUNDING PAIR only, never `gsub(/"/)`: a global strip removed EVERY quote
# anywhere in the value, so a label legitimately named `say "hi"` came back as
# `say hi`, failed the exact-match lookup below, and produced a "not found" error
# for a label that actually exists. Only the surrounding pair is glab's, so only
# the surrounding pair is removed — and only when BOTH ends carry one (`/^".*"$/`
# is checked FIRST): stripping the two ends independently would eat the closing
# quote of that same `say "hi"` name, which ends with a quote without starting
# with one.
list_all_labels() {
	_repo=$1
	_page=1
	while [ "$_page" -le "$LABELS_MAX_PAGES" ]; do
		if ! _raw=$(glab label list --repo "$_repo" --output json \
			--per-page "$LABELS_PER_PAGE" --page "$_page" \
			--jq '.[].name' 2>>"$TMP_ERR"); then
			return 1
		fi
		_clean=$(printf '%s\n' "$_raw" | awk '{ if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") } if ($0 != "") print }')
		[ -n "$_clean" ] || return 0
		printf '%s\n' "$_clean"
		_count=$(printf '%s\n' "$_clean" | awk 'END { print NR }')
		[ "$_count" -ge "$LABELS_PER_PAGE" ] || return 0
		_page=$((_page + 1))
	done
	warn "label lookup stopped after $LABELS_MAX_PAGES pages — a label beyond the first $((LABELS_MAX_PAGES * LABELS_PER_PAGE)) may be misreported as missing"
	return 0
}

# ---------------------------------------------------------------------------
# List accumulators (POSIX sh has no arrays; a newline-separated string is the
# portable stand-in). Both need IDENTICAL comma-split + trim + append behavior,
# so the whole job is TWO shared helpers — split_csv_list (tokenize) and
# accumulate (append, VALUE-RETURNING) — rather than two
# byte-identical-except-for-the-variable-name append functions.
#
# `accumulate` RETURNS the new list on stdout instead of mutating a global chosen
# by a name argument: `LABELS=$(accumulate "$LABELS" "$2")` keeps the target
# variable at the call site, where the reader can see it, and needs no `eval` and
# no string-keyed dispatcher — the pattern this codebase's own conventions reject.
# ---------------------------------------------------------------------------
LABELS=""       # newline-separated
ASSIGNEES=""    # newline-separated

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
OPT_CONFIRMED_HOST=""
OPT_TITLE=""
OPT_BODY_FILE=""
OPT_MILESTONE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)           need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--confirmed-host) need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		--title)     need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--body-file) need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		--label)     need_arg "$1" "${2:-}"; LABELS=$(accumulate "$LABELS" "$2"); shift ;;
		--milestone) need_arg "$1" "${2:-}"; OPT_MILESTONE=$2; shift ;;
		--assignee)  need_arg "$1" "${2:-}"; ASSIGNEES=$(accumulate "$ASSIGNEES" "$2"); shift ;;
		-h|--help)   usage; exit 0 ;;
		--)          shift; break ;;
		-*)          usage >&2; error "unknown option: $1"; exit 2 ;;
		*)           usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

# ---------------------------------------------------------------------------
# Required-argument validation
# ---------------------------------------------------------------------------
[ -n "$OPT_REPO" ]  || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_TITLE" ] || { usage >&2; error "--title is required"; exit 2; }

[ -n "$OPT_BODY_FILE" ] || { usage >&2; error "--body-file is required"; exit 2; }
if [ ! -f "$OPT_BODY_FILE" ] || [ ! -r "$OPT_BODY_FILE" ]; then
	usage >&2
	error "--body-file does not exist or is not readable: $OPT_BODY_FILE"
	exit 2
fi

# Read the body into ONE variable, byte-for-byte (sentinel idiom — see this
# file's header for why a plain $(cat) is wrong).
#
# `cat … && printf x`, NOT `cat …; printf x`: with the semicolon the command
# substitution takes ITS exit status from `printf`, which always succeeds, so a
# mid-read I/O failure on `cat` was invisible even under `set -e` — the caller
# then saw either a truncated body posted to the tracker or the misleading "is
# empty" diagnostic below instead of an honest read failure. With `&&` the
# substitution's status is `cat`'s, so the `if` below actually catches it.
if ! BODY=$(cat "$OPT_BODY_FILE" && printf x); then
	error "failed to read --body-file: $OPT_BODY_FILE"
	exit 2
fi
BODY=${BODY%x}

# BODY_PROBE is BODY with trailing newlines removed (command substitution
# strips them), used ONLY for the two guards below — the value actually sent to
# glab stays the untouched BODY.
BODY_PROBE=$(printf '%s' "$BODY")
if [ -z "$BODY_PROBE" ]; then
	usage >&2
	error "--body-file is empty: $OPT_BODY_FILE"
	exit 2
fi
if [ "$BODY_PROBE" = "-" ]; then
	usage >&2
	error "--body-file contains only '-', which glab reads as \"open an interactive editor\" — that would hang a non-interactive caller"
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
	error "awk is not installed (required to page the label lookup and read the issue URL back)"
	exit 1
fi

# The bare form checks only the current context's instance, so --all is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr).
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

# ---------------------------------------------------------------------------
# Temp file (mktemp, cleaned up on exit) — used only for glab's OWN stderr.
# NEVER used for the issue body, which travels as one argv value.
# ---------------------------------------------------------------------------
TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-glab-create-issue.err.XXXXXX")
# TWO traps, not one combined `EXIT INT TERM`: a Ctrl-C during a slow `glab`
# call would otherwise leak the temp file, but a combined handler would clean up
# and then RESUME the interrupted command's error path, which goes on to read the
# file it just unlinked. The INT/TERM handler therefore terminates the script
# itself (130 = SIGINT's conventional status). The EXIT trap still runs after it,
# and a second `rm -f` on an already-removed path is a no-op.
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Precondition: every requested label must already exist. glab does not
# auto-create one, and fails the WHOLE create if any single label is unknown.
# ---------------------------------------------------------------------------
if [ -n "$LABELS" ]; then
	if ! EXISTING_LABELS=$(list_all_labels "$OPT_REPO"); then
		error "failed to look up labels for project '$OPT_REPO'"
		sed 's/^/  /' "$TMP_ERR" >&2
		exit 1
	fi

	MISSING_LABELS=""
	while IFS= read -r want_label; do
		[ -n "$want_label" ] || continue
		if ! printf '%s\n' "$EXISTING_LABELS" | grep -Fxq -- "$want_label"; then
			if [ -z "$MISSING_LABELS" ]; then MISSING_LABELS=$want_label
			else MISSING_LABELS="$MISSING_LABELS, $want_label"
			fi
		fi
	done <<EOF
$LABELS
EOF

	if [ -n "$MISSING_LABELS" ]; then
		error "label(s) not found in project '$OPT_REPO': $MISSING_LABELS"
		warn  "create them first (never done automatically) with ensure-labels.sh, or drop the flag"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# Precondition: an explicit milestone must already exist.
#
# `glab milestone list --title` filters SERVER-side on the exact title, so this
# needs no page walk (unlike the label lookup above) — a hit means the exact
# title exists, an empty result means it does not.
#
# DELIBERATE CONTRACT NARROWING: raw `glab issue create --milestone` also
# accepts a numeric global milestone id, which this title-only pre-check would
# reject. That mirrors the GitHub sibling's contract (--milestone is a TITLE),
# keeps the pre-check exact, and fails CLOSED (a clear "milestone not found"
# before anything is created) rather than open. Pass the title.
# ---------------------------------------------------------------------------
if [ -n "$OPT_MILESTONE" ]; then
	if ! MILESTONE_RAW=$(glab milestone list --repo "$OPT_REPO" --title "$OPT_MILESTONE" \
		--output json --jq '.[].title' 2>"$TMP_ERR"); then
		error "failed to look up milestones for project '$OPT_REPO'"
		sed 's/^/  /' "$TMP_ERR" >&2
		exit 1
	fi
	# Surrounding-pair strip only, never a global one — a milestone title may
	# legitimately contain a double quote (see list_all_labels above).
	MILESTONE_TITLES=$(printf '%s\n' "$MILESTONE_RAW" | awk '{ if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") } if ($0 != "") print }')

	if ! printf '%s\n' "$MILESTONE_TITLES" | grep -Fxq -- "$OPT_MILESTONE"; then
		error "milestone not found in project '$OPT_REPO': $OPT_MILESTONE"
		warn  "create it first (never done automatically) via the project's Issues > Milestones page, and pass its TITLE (not a numeric id)"
		exit 1
	fi
fi

# ---------------------------------------------------------------------------
# Build the `glab issue create` argv as POSITIONAL PARAMETERS — POSIX sh's
# array equivalent (see standard-shell-script: build commands as arrays, never
# as strings). The body and the title are each ONE argv token; neither is ever
# built via a heredoc/string. `--yes` is MANDATORY here, not optional: without
# it glab prompts for submission confirmation and would hang.
# ---------------------------------------------------------------------------
set -- glab issue create \
	--repo "$OPT_REPO" \
	--title "$OPT_TITLE" \
	--description "$BODY" \
	--yes

if [ -n "$LABELS" ]; then
	while IFS= read -r lbl; do
		[ -n "$lbl" ] || continue
		set -- "$@" --label "$lbl"
	done <<EOF
$LABELS
EOF
fi

[ -z "$OPT_MILESTONE" ] || set -- "$@" --milestone "$OPT_MILESTONE"

if [ -n "$ASSIGNEES" ]; then
	while IFS= read -r asg; do
		[ -n "$asg" ] || continue
		set -- "$@" --assignee "$asg"
	done <<EOF
$ASSIGNEES
EOF
fi

# ---------------------------------------------------------------------------
# Create.
# ---------------------------------------------------------------------------
if ! CREATE_OUT=$("$@" 2>"$TMP_ERR"); then
	error "glab issue create failed"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# BOTH captured streams are scanned as ONE pool, in a SINGLE pass, never
# stdout-first-with-a-stderr-fallback: glab may put the real URL on stderr, and
# with a fallback an adversarial TITLE echoed on stdout was then the only
# candidate the ambiguity guard ever saw (SEC-003). Pooling means the spoof and
# the genuine URL are seen together — two distinct candidates — and fail closed.
ISSUE_URL_CANDIDATES=$(extract_issue_url_candidates \
	"$(printf '%s\n%s\n' "$CREATE_OUT" "$(cat "$TMP_ERR")")" "$OPT_REPO")

# FAIL CLOSED on ambiguity — see extract_issue_url_candidates's header: at most
# one candidate per distinct URL, so 2+ means genuine ambiguity or a spoof. THE
# PER-SITE DELTA: this URL is LOAD-BEARING (PM_ISSUE_NUMBER is derived from it and
# every follow-up operation is keyed off that), so ambiguity is EXIT 1 here —
# update-issue.sh and comment.sh, whose URLs are courtesy fields, only empty the
# key and warn.
if [ "$(count_lines "$ISSUE_URL_CANDIDATES")" -gt 1 ]; then
	error "glab issue create printed MORE THAN ONE distinct issue URL for project '$OPT_REPO' — refusing to guess which one is the new issue"
	printf '%s\n' "$ISSUE_URL_CANDIDATES" | sed 's/^/  /' >&2
	warn  "the issue may nonetheless have been created — verify with find-duplicate.sh before retrying (an issue TITLE that looks like a URL produces this)"
	exit 1
fi

if [ -z "$ISSUE_URL_CANDIDATES" ]; then
	error "glab issue create reported success but printed no issue URL for project '$OPT_REPO'"
	warn  "the issue may nonetheless have been created — check with find-duplicate.sh before retrying"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# The one surviving candidate — the two guards above rejected 2+ and 0, so this is
# the whole value (see extract_issue_url_candidates's header).
ISSUE_URL=$ISSUE_URL_CANDIDATES

# The iid is the URL's trailing segment. No numeric re-check is needed (and one
# would be dead code): extract_issue_url_candidates only accepts a token whose
# final path segment is ALL digits, so a non-numeric tail can never reach here.
ISSUE_NUMBER=${ISSUE_URL##*/}

printf 'PM_ISSUE_NUMBER=%s\n' "$ISSUE_NUMBER"
printf 'PM_ISSUE_URL=%s\n'    "$ISSUE_URL"
exit 0
