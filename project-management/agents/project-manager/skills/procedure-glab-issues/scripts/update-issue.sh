#!/usr/bin/env sh
#
# update-issue.sh — edit fields of an existing GitLab issue via
#                    `glab issue update`, with the body (when changed at all)
#                    always handed over by the caller as a FILE, never built in
#                    shell.
#
# CRITICAL — the body is touched ONLY if --body-file is given. When it is
# omitted, this script passes NOTHING description-related (no --description, no
# --body) to `glab issue update` — glab then leaves the existing description
# completely untouched. There is no code path here that reads the CURRENT
# description to "preserve" it (unlike link-children.sh, which must splice into
# an existing description); non-clobber is achieved STRUCTURALLY, by simply
# never emitting a description flag unless the caller explicitly asked to
# replace it. See the argv-building section below for the single guard that
# implements this. This mirrors procedure-glab-mr's update-mr.sh exactly.
#
# WHY THE CALLER-FACING FLAG IS `--body-file` BUT glab GETS
# `--description "$content"`:
#   `glab issue update` has no --description-file flag (verified against glab
#   1.112.0's --help: only `-d/--description <string>`, and setting it to
#   literally "-" opens an interactive editor), so this script reads the file
#   into ONE variable with the sentinel idiom
#       content=$(cat "$file" && printf x); content=${content%x}
#   (a plain $(cat file) would strip ALL trailing newlines) and passes it as ONE
#   double-quoted argv token in a command built from POSITIONAL PARAMETERS. That
#   is injection-safe for the same reason `--title` is: the bytes are never
#   re-interpreted by a shell — no heredoc, no eval, no concatenated command
#   string — so `$(...)`, backticks, quotes and newlines travel into execve as
#   inert data. The caller-facing flag keeps the file-based spelling on purpose:
#   it is the same contract as the GitHub sibling's --body-file.
#
# Purpose:
#   Wraps `glab issue update` so the caller never hand-authors the invocation or
#   the body construction, and can never accidentally wipe an issue's
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
#   update-issue.sh --repo PATH --issue N --confirmed-host HOST
#                    [--title STR] [--body-file PATH]
#                    [--add-label NAME]... [--remove-label NAME]...
#                    [--add-assignee LOGIN]... [--remove-assignee LOGIN]...
#                    [--milestone STR] [-h|--help]
#
#     --repo PATH              Target project path (required; subgroups allowed).
#     --confirmed-host HOST    The GitLab host the account gate already CONFIRMED
#                              (required) — e.g. gitlab.com or a self-managed
#                              hostname, spelled the way `glab auth status`
#                              reports it (bare host, optional ':port', no
#                              scheme). See "HOST PINNING" above.
#     --issue N                The issue iid to edit (required, positive
#                              integer). Forwarded to glab as the POSITIONAL
#                              <id> argument — `glab issue update` takes `<id>`
#                              positionally and has no `--issue`-style flag. The
#                              caller-facing spelling stays a flag for symmetry
#                              with the GitHub sibling.
#     --title STR              Replace the title.
#     --body-file PATH         Replace the body from this file (must exist, be
#                              readable, non-empty, and not the single character
#                              '-'). Omit to leave the body UNCHANGED — see the
#                              CRITICAL note above. There is deliberately NO
#                              --body/--description passthrough.
#     --add-label NAME         A label to add (glab `--label`). Repeatable
#                              and/or comma-separated. NOT pre-checked for
#                              existence — glab errors on an unknown one (run
#                              ensure-labels.sh first if the caller wants it
#                              created).
#     --remove-label NAME      A label to remove (glab `--unlabel` — glab does
#                              NOT mirror gh's --add-label/--remove-label
#                              naming). Repeatable and/or comma-separated.
#     --add-assignee LOGIN     An assignee to add. Repeatable and/or
#                              comma-separated.
#     --remove-assignee LOGIN  An assignee to remove. Repeatable and/or
#                              comma-separated.
#     --milestone STR          Replace the milestone (must already exist; NOT
#                              pre-checked here — glab errors on an unknown
#                              one). Pass `0` to UNASSIGN the milestone: that is
#                              glab's documented "set to 0 to unassign" value,
#                              and it is the only way to unassign through this
#                              wrapper, because an empty --milestone value is
#                              rejected as a missing argument.
#     -h, --help               Show this help.
#
#   At least ONE field flag is required — a bare --repo/--issue with nothing to
#   change is a usage error, not a silent no-op.
#
#   ASSIGNEE PREFIXES: glab's `--assignee` REPLACES the existing set unless a
#   value is prefixed — '+' adds, and (per glab's own help text) either '!' or
#   '-' removes. This script composes those prefixes for you, so an
#   --add-assignee/--remove-assignee pair can never accidentally replace the
#   whole set. It uses '!' (never '-') for removal on purpose, matching
#   procedure-glab-mr's update-mr.sh: a value starting with '-' looks like a
#   flag to an argument parser, while '!' is unambiguous and is inert in a
#   non-interactive shell (no history expansion). glab documents both, so '!'
#   costs nothing and removes a whole class of misparse risk.
#
# Output:
#   PM_ISSUE_URL=<url>   printed IF an issue URL for THIS --issue can be found in
#                        glab's output; a successful edit that prints no such URL
#                        still exits 0 with this key EMPTY — the URL is a
#                        courtesy, not the proof of success (glab's own exit code
#                        is that proof). The key is also left empty when the
#                        output is ambiguous (2+ distinct project-matching URLs)
#                        or when the one URL found names a DIFFERENT iid than
#                        --issue: a guess is never relayed.
#                        DELIBERATE DIVERGENCE from the GitHub sibling, which
#                        treats a missing URL as a hard failure: `gh issue edit`
#                        documents its URL output, whereas `glab issue update`
#                        supports no `--output json` and its printed decoration
#                        is not a documented contract, so demanding a URL would
#                        turn a successful edit into a false failure. Same
#                        contract as procedure-glab-mr's update-mr.sh.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  issue updated
#   1  glab/awk absent / not authenticated / `glab issue update` itself failed
#   2  usage error (missing/invalid argument, unreadable or unusable body-file,
#      or no field flag given at all)
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
# non-interactive script can never block on a prompt. NOTE: unlike
# `glab issue create`, `glab issue update` has NO `--yes` flag at all (verified
# against glab 1.112.0's --help), so GLAB_NO_PROMPT is the only prompt
# suppression available here — passing `--yes` would make glab reject the whole
# invocation as an unknown flag.
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
              [--title STR] [--body-file PATH]
              [--add-label NAME]... [--remove-label NAME]...
              [--add-assignee LOGIN]... [--remove-assignee LOGIN]...
              [--milestone STR] [-h|--help]

Edit fields of an existing GitLab issue via glab. The body is changed ONLY if
--body-file is given (no flag at all leaves it untouched) — there is no
--body/--description passthrough. At least one field flag is required.

Example:
  $PROG --repo group/subgroup/project --issue 42 --confirmed-host gitlab.com \\
        --title "Export to CSV" --add-label type:story

Options:
  --repo PATH              Target project path (required; subgroups allowed).
  --confirmed-host HOST    The GitLab host the account gate already confirmed
                            (required; bare hostname, optional ':port', no
                            scheme). Pins glab to that instance.
  --issue N                The issue iid to edit (required).
  --title STR              Replace the title.
  --body-file PATH         Replace the body from this file. Omit to leave the
                            body UNCHANGED.
  --add-label NAME         A label to add. Repeatable and/or comma-separated.
  --remove-label NAME      A label to remove. Repeatable and/or comma-separated.
  --add-assignee LOGIN     An assignee to add. Repeatable and/or comma-separated.
  --remove-assignee LOGIN  An assignee to remove. Repeatable and/or comma-separated.
  --milestone STR          Replace the milestone (pass 0 to unassign).
  -h, --help               Show this help.

Prints (may be empty even on success):
  PM_ISSUE_URL=<url>

Exit codes:
  0  updated
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

# extract_issue_url_candidates TEXT REPO — print every DISTINCT
# whitespace-delimited token in TEXT that is an issue URL OF THIS PROJECT, one per
# line, in first-appearance order. glab's update output decoration is not a
# documented contract, so the URL is located by SHAPE rather than by position. awk
# always exits 0, so this never trips `set -e`.
#
# WHY BOTH path segments are accepted: GitLab migrated issue URLs to the
# work-items path, and current `glab issue update` prints
# ".../-/work_items/<iid>" — live-confirmed against a real project, where
# matching only "/issues/" left PM_ISSUE_URL empty despite glab printing a
# perfectly good URL. The classic "/issues/<iid>" shape is kept rather than
# swapped out, because an older self-managed instance or a future glab talking to
# a differently-configured server may still emit it; accepting either is strictly
# safer than trading one hard assumption for another.
#
# THE ONE PLACE THE DEDUP/AMBIGUITY RATIONALE IS WRITTEN OUT — every call site
# below points here instead of restating it:
#   * glab prints the issue TITLE on the line BEFORE the URL, so a title that
#     merely LOOKS like an issue URL used to be picked up instead of the real one:
#     the first shape match in the whole captured output won, and PM_ISSUE_URL then
#     pointed at something else entirely.
#   * So a candidate must be a URL of the CONFIRMED --repo project, ALL distinct
#     candidates are reported, and the dedup keeps the FIRST occurrence of each
#     distinct value while dropping every later repeat.
#   * Therefore the output holds AT MOST ONE LINE PER DISTINCT URL. The caller
#     never chooses between occurrences: it either takes the single survivor, or
#     sees 2+ — which can only mean genuinely different URLs, i.e. ambiguity or a
#     spoof — and fails closed. Identical repeats collapse to one candidate, so a
#     title quoting the real URL verbatim is harmless.
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
# List accumulators (POSIX sh has no arrays; a newline-separated string is the
# portable stand-in). All four need IDENTICAL comma-split + trim + append
# behavior, so the whole job is TWO shared helpers — split_csv_list (tokenize) and
# accumulate (append, VALUE-RETURNING) — rather than four
# byte-identical-except-for-the-variable-name append functions.
#
# `accumulate` RETURNS the new list on stdout instead of mutating a global chosen
# by a name argument: `ADD_LABELS=$(accumulate "$ADD_LABELS" "$2")` keeps the
# target variable at the call site, where the reader can see it, and needs no
# `eval` and no string-keyed dispatcher — the pattern this codebase's own
# conventions reject.
# ---------------------------------------------------------------------------
ADD_LABELS=""
REMOVE_LABELS=""
ADD_ASSIGNEES=""
REMOVE_ASSIGNEES=""

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
# so a `--add-label ,,` cannot introduce a blank entry.
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
OPT_ISSUE=""
OPT_TITLE=""
OPT_BODY_FILE=""
OPT_MILESTONE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)             need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--confirmed-host)   need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		--issue)            need_arg "$1" "${2:-}"; OPT_ISSUE=$2; shift ;;
		--title)            need_arg "$1" "${2:-}"; OPT_TITLE=$2; shift ;;
		--body-file)        need_arg "$1" "${2:-}"; OPT_BODY_FILE=$2; shift ;;
		--add-label)        need_arg "$1" "${2:-}"; ADD_LABELS=$(accumulate "$ADD_LABELS" "$2"); shift ;;
		--remove-label)     need_arg "$1" "${2:-}"; REMOVE_LABELS=$(accumulate "$REMOVE_LABELS" "$2"); shift ;;
		--add-assignee)     need_arg "$1" "${2:-}"; ADD_ASSIGNEES=$(accumulate "$ADD_ASSIGNEES" "$2"); shift ;;
		--remove-assignee)  need_arg "$1" "${2:-}"; REMOVE_ASSIGNEES=$(accumulate "$REMOVE_ASSIGNEES" "$2"); shift ;;
		--milestone)        need_arg "$1" "${2:-}"; OPT_MILESTONE=$2; shift ;;
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

[ -n "$OPT_ISSUE" ] || { usage >&2; error "--issue is required"; exit 2; }
is_positive_int "$OPT_ISSUE" || { usage >&2; error "--issue must be a positive integer (a GitLab iid), got: $OPT_ISSUE"; exit 2; }

# The body is resolved ONLY when the caller asked to replace it. BODY stays
# empty otherwise, and the argv builder below keys the non-clobber guard off
# OPT_BODY_FILE, never off this value.
BODY=""
if [ -n "$OPT_BODY_FILE" ]; then
	if [ ! -f "$OPT_BODY_FILE" ] || [ ! -r "$OPT_BODY_FILE" ]; then
		usage >&2
		error "--body-file does not exist or is not readable: $OPT_BODY_FILE"
		exit 2
	fi
	# Sentinel idiom — a plain $(cat file) strips ALL trailing newlines.
	#
	# `cat … && printf x`, NOT `cat …; printf x`: with the semicolon the command
	# substitution takes ITS exit status from `printf`, which always succeeds, so
	# a mid-read I/O failure on `cat` was invisible even under `set -e` — the
	# caller then saw a truncated body written to the tracker, or the misleading
	# "is empty" diagnostic below, instead of an honest read failure.
	if ! BODY=$(cat "$OPT_BODY_FILE" && printf x); then
		error "failed to read --body-file: $OPT_BODY_FILE"
		exit 2
	fi
	BODY=${BODY%x}

	# BODY_PROBE is BODY with trailing newlines removed (command substitution
	# strips them), used ONLY for the two guards below — the value actually sent
	# to glab stays the untouched BODY.
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
fi

# At least one field must actually be requested — a bare --repo/--issue is a
# usage error, not a silent no-op that just prints the URL back.
if [ -z "$OPT_TITLE" ] && [ -z "$OPT_BODY_FILE" ] && [ -z "$ADD_LABELS" ] && \
   [ -z "$REMOVE_LABELS" ] && [ -z "$ADD_ASSIGNEES" ] && [ -z "$REMOVE_ASSIGNEES" ] && \
   [ -z "$OPT_MILESTONE" ]; then
	usage >&2
	error "at least one field to change is required (--title, --body-file, --add-label, --remove-label, --add-assignee, --remove-assignee, or --milestone)"
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
	error "awk is not installed (required to read the issue URL back)"
	exit 1
fi

# The bare form checks only the current context's instance, so --all is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr).
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-glab-update-issue.err.XXXXXX")
# TWO traps, not one combined `EXIT INT TERM`: a Ctrl-C during a slow `glab`
# call would otherwise leak the temp file, but a combined handler would clean up
# and then RESUME the interrupted command's error path, which goes on to read the
# file it just unlinked. The INT/TERM handler therefore terminates the script
# itself (130 = SIGINT's conventional status). The EXIT trap still runs after it,
# and a second `rm -f` on an already-removed path is a no-op.
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Build the `glab issue update` argv as POSITIONAL PARAMETERS — POSIX sh's array
# equivalent. THE non-clobber guard: --description is appended to argv ONLY when
# OPT_BODY_FILE is non-empty — if the caller never gave --body-file, NO
# description-related flag is ever added here, so `glab issue update` leaves the
# existing description exactly as it was.
#
# The issue iid goes in POSITIONALLY (glab takes `<id>`), and NO `--yes` is
# passed: `glab issue update` has no such flag (see the GLAB_NO_PROMPT note
# above).
# ---------------------------------------------------------------------------
set -- glab issue update "$OPT_ISSUE" --repo "$OPT_REPO"

[ -z "$OPT_TITLE" ]     || set -- "$@" --title "$OPT_TITLE"
[ -z "$OPT_BODY_FILE" ] || set -- "$@" --description "$BODY"
[ -z "$OPT_MILESTONE" ] || set -- "$@" --milestone "$OPT_MILESTONE"

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

# '+'/'!' prefixes: without one, glab REPLACES the whole assignee set. '!' (not
# '-') is used for removal so the value can never be mistaken for a flag by an
# argument parser — see this file's header.
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

# ---------------------------------------------------------------------------
# Update.
# ---------------------------------------------------------------------------
if ! UPDATE_OUT=$("$@" 2>"$TMP_ERR"); then
	error "glab issue update failed for issue #$OPT_ISSUE"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# BOTH captured streams are scanned as ONE pool, in a SINGLE pass, never
# stdout-first-with-a-stderr-fallback: glab may put the real URL on stderr, and
# with a fallback an adversarial TITLE echoed on stdout was then the only candidate
# the ambiguity guard ever saw (SEC-003). Pooling means the spoof and the genuine
# URL are seen together — two distinct candidates — and fail closed. An absent URL
# is NOT a failure (courtesy contract): the key prints empty.
ISSUE_URL_CANDIDATES=$(extract_issue_url_candidates \
	"$(printf '%s\n%s\n' "$UPDATE_OUT" "$(cat "$TMP_ERR")")" "$OPT_REPO")

# FAIL CLOSED on ambiguity — see extract_issue_url_candidates's header: at most one
# candidate per distinct URL, so 2+ means genuine ambiguity or a spoof. THE
# PER-SITE DELTA: this script does NOT invent a failure exit the way
# create-issue.sh does — the edit already succeeded and PM_ISSUE_URL is a
# documented courtesy field, so ambiguity leaves the key EMPTY and warns instead of
# failing a completed edit.
#
# THE iid CROSS-CHECK (SEC-003): unlike create-issue.sh — which is extracting an iid
# it does not yet know — this script was HANDED the iid it just updated, already
# validated as a positive integer. That makes --issue authoritative ground truth, so
# the surviving candidate's own trailing iid segment must equal it literally. A
# project-matching URL for some OTHER issue (a URL-shaped title naming a different
# iid) therefore cannot be relayed as this issue's URL. A mismatch is treated
# exactly like "no candidate found": empty key + warn, still exit 0.
ISSUE_URL=""
if [ "$(count_lines "$ISSUE_URL_CANDIDATES")" -gt 1 ]; then
	warn "glab issue update printed MORE THAN ONE distinct issue URL for project '$OPT_REPO'; refusing to guess, so PM_ISSUE_URL is left empty — resolve it with find-duplicate.sh (an issue TITLE that looks like a URL produces this)"
	printf '%s\n' "$ISSUE_URL_CANDIDATES" | sed 's/^/  /' >&2
elif [ -n "$ISSUE_URL_CANDIDATES" ]; then
	# The one surviving candidate — the guard above rejected 2+, so this is the
	# whole value (see extract_issue_url_candidates's header).
	CANDIDATE_IID=${ISSUE_URL_CANDIDATES##*/}
	if [ "$CANDIDATE_IID" = "$OPT_ISSUE" ]; then
		ISSUE_URL=$ISSUE_URL_CANDIDATES
	else
		warn "glab issue update printed an issue URL for iid #$CANDIDATE_IID, not the issue that was updated (#$OPT_ISSUE), so PM_ISSUE_URL is left empty — resolve it with find-duplicate.sh (an issue TITLE that looks like a URL produces this)"
		printf '%s\n' "$ISSUE_URL_CANDIDATES" | sed 's/^/  /' >&2
	fi
fi

printf 'PM_ISSUE_URL=%s\n' "$ISSUE_URL"
exit 0
