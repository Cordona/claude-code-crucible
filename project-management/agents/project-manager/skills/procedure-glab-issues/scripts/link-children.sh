#!/usr/bin/env sh
#
# link-children.sh — wire child issues under an epic-issue by appending a
#                     task-list, WITHOUT ever constructing the epic's
#                     description in a shell string, heredoc, or eval.
#
# Purpose:
#   Links child issues to an epic so the epic's description renders a checklist
#   of its children, cross-linking each child GitLab-side.
#
# WHY A PLAIN ISSUE AND NOT A NATIVE GITLAB EPIC (a deliberate design decision,
# not an oversight):
#   GitLab's native epics are GROUP-level objects and a paid-tier feature that
#   may not exist at all on the target account, and `glab issue update` has NO
#   `--epic` flag (verified against glab 1.112.0's own --help) — so there is no
#   plain-glab way to link an ALREADY-EXISTING child to an ALREADY-EXISTING
#   epic. This script therefore treats a PLAIN ISSUE as the epic (hence the
#   flag is `--epic-issue N`, never `--epic`, so nothing here implies GitLab's
#   native feature) and appends `- [ ] #<child>` lines to its description —
#   exactly the mechanism procedure-gh-issues' link-children.sh uses. GitLab
#   renders that as a progress checklist and turns each `#N` into a live
#   cross-link, and the whole path reuses the same `glab issue update
#   --description` mechanism this skill already depends on everywhere else.
#
# INJECTION SAFETY (read this before changing the description handling):
#   The epic's EXISTING description is untrusted repo content, so it is read
#   straight to a FILE and all splicing is done by awk on FILES — the untrusted
#   bytes are never interpolated into a string, a heredoc, or an eval. The new
#   checklist lines are built ONLY from --child values already validated as
#   plain positive integers, never from the description just read.
#
#   The one unavoidable difference from the GitHub sibling: `glab issue update`
#   has no `--description-file` flag (only `-d/--description <string>`), so the
#   FINAL spliced file is read into ONE shell variable with the
#   trailing-newline-preserving sentinel idiom and passed as ONE double-quoted
#   argv token. That is injection-safe for the same reason `--title` is: the
#   bytes travel into execve as a single argv value and are never re-parsed by
#   a shell. What must NEVER happen is the description becoming part of a
#   command STRING. See procedure-glab-mr's create-mr.sh header for the full
#   reasoning, and this skill's SKILL.md.
#
# HOST PINNING — WHY --confirmed-host IS REQUIRED (SEC-001):
#   `procedure-gitlab-auth`'s gate confirms an (account, HOST) pair with the user
#   before any write, but that confirmation used to bind to NOTHING here: this
#   script let `glab` resolve the target instance from ambient state (the cwd's
#   git remotes, an inherited $GITLAB_HOST, glab's own config). On a machine with
#   two configured instances — the very case the gate exists to disambiguate —
#   the gate could confirm host A while this REWRITE of an epic's description
#   silently landed on host B, whenever the same --repo project path resolves on
#   both. A live tracker write is unretractable, and there was no error to notice.
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
#   the wrong place — fail closed either way. It also keeps the READ (step 1) and
#   the WRITE (step 4) on ONE instance, which matters more here than anywhere
#   else in this skill: this script reads a description, splices it, and writes it
#   back, so a read and a write that resolved differently would overwrite one
#   epic with another epic's content.
#
#   This script does NOT re-implement the account-confirmation UX; that stays
#   `procedure-gitlab-auth`'s job, upstream (see "NOT performed here" below).
#   The flag only ENFORCES that the write targets the host already confirmed.
#
# Usage:
#   link-children.sh --repo PATH --epic-issue N --child N [--child N ...]
#                     --confirmed-host HOST [-h|--help]
#
#     --repo PATH       Target project path (required). One or more
#                       '/'-separated segments — GitLab subgroups are supported.
#     --confirmed-host HOST
#                       The GitLab host the account gate already CONFIRMED
#                       (required) — e.g. gitlab.com or a self-managed hostname,
#                       spelled the way `glab auth status` reports it (bare host,
#                       optional ':port', no scheme). See "HOST PINNING" above.
#     --epic-issue N    The epic ISSUE's iid (required, positive integer). A
#                       plain issue acting as the epic — NOT a native GitLab
#                       group epic (see above).
#     --child N         A child issue iid to link. Repeatable; at least one is
#                       required.
#     -h, --help        Show this help.
#
# Output:
#   PM_LINKED=<n>   number of NEW child links actually appended this run
#                   (a child already present in the epic's description — in
#                   EITHER checkbox state, "- [ ] #N" or "- [x] #N" — is
#                   skipped and NOT recounted; this script is idempotent).
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  epic updated (or already linked to every requested child — no-op)
#   1  glab/awk absent / not authenticated / the epic issue could not be read /
#      `glab issue update` itself failed
#   2  usage error
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
Usage: $PROG --repo PATH --epic-issue N --child N [--child N ...]
              --confirmed-host HOST [-h|--help]

Link child issues under an epic-issue by appending "- [ ] #<child>" lines to
its description. Idempotent: a child already linked (in either checkbox state)
is skipped. The existing description is read straight to a file and spliced by
awk — never built in a shell string.

Example:
  $PROG --repo group/subgroup/project --epic-issue 10 --child 11 --child 12 \\
        --confirmed-host gitlab.com

Options:
  --repo PATH       Target project path (required; subgroups allowed).
  --confirmed-host HOST
                    The GitLab host the account gate already confirmed
                     (required; bare hostname, optional ':port', no scheme).
                     Pins glab to that instance.
  --epic-issue N    The epic ISSUE's iid (required). A plain issue acting as
                     the epic — NOT a native GitLab group epic.
  --child N         A child issue iid to link. Repeatable, required at least
                     once.
  -h, --help        Show this help.

Prints:
  PM_LINKED=<n>   number of NEW links appended this run

Exit codes:
  0  updated (or already fully linked)
  1  glab/awk absent / not authenticated / epic not readable / update failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_positive_int VALUE — 0 only for a canonical positive decimal integer.
# Digits-only is NOT enough: a bare '0' is not positive, and a leading-zero form
# ('007') is not the iid GitLab would echo back. Both used to slip through — and
# here the consequence was worse than a confusing error: `--child 0` spliced a
# dead "- [ ] #0" line into the epic's description and reported PM_LINKED=1, a
# silently WRONG outcome, while `--child 007` would have linked issue 7. Both
# --epic-issue and --child validate through this one function.
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
OPT_EPIC_ISSUE=""
CHILDREN=""   # newline-separated accumulator (POSIX sh has no arrays)

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)       need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--confirmed-host) need_arg "$1" "${2:-}"; OPT_CONFIRMED_HOST=$2; shift ;;
		--epic-issue) need_arg "$1" "${2:-}"; OPT_EPIC_ISSUE=$2; shift ;;
		--child)
			need_arg "$1" "${2:-}"
			is_positive_int "$2" || { usage >&2; error "--child must be a positive integer, got: $2"; exit 2; }
			if [ -z "$CHILDREN" ]; then CHILDREN=$2
			else CHILDREN="$CHILDREN
$2"
			fi
			shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }
is_valid_gitlab_project_path "$OPT_REPO" || { usage >&2; error "--repo must be a GitLab project path with at least one '/' (letters, digits, '.', '_', '-' per segment; subgroups allowed), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_EPIC_ISSUE" ] || { usage >&2; error "--epic-issue is required"; exit 2; }
is_positive_int "$OPT_EPIC_ISSUE" || { usage >&2; error "--epic-issue must be a positive integer (a GitLab iid), got: $OPT_EPIC_ISSUE"; exit 2; }
[ -n "$CHILDREN" ] || { usage >&2; error "at least one --child is required"; exit 2; }

[ -n "$OPT_CONFIRMED_HOST" ] || { usage >&2; error "--confirmed-host is required (the host procedure-gitlab-auth's account gate confirmed)"; exit 2; }
is_valid_confirmed_host "$OPT_CONFIRMED_HOST" || { usage >&2; error "--confirmed-host must be a bare hostname with an optional ':port' and no scheme, got: $OPT_CONFIRMED_HOST"; exit 2; }

# Pin glab's target instance to the CONFIRMED host. Exported so every `glab`
# child of THIS process inherits it — which is also what keeps the read in step 1
# and the write in step 4 on ONE instance; nothing outside this process is
# touched. See "HOST PINNING" in this file's header.
GITLAB_HOST=$OPT_CONFIRMED_HOST
export GITLAB_HOST

# ---------------------------------------------------------------------------
# Tooling preconditions
# ---------------------------------------------------------------------------
if ! command -v glab >/dev/null 2>&1; then
	error "GitLab CLI (glab) is not installed"
	warn  "install it from https://gitlab.com/gitlab-org/cli then re-run"
	exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required to splice the checklist into the epic's description)"
	exit 1
fi

# The bare form checks only the current context's instance, so --all is the
# fallback before declaring glab unauthenticated (same as procedure-glab-mr).
if ! glab auth status >/dev/null 2>&1 && ! glab auth status --all >/dev/null 2>&1; then
	error "glab is installed but not authenticated"
	warn  "authenticate with: glab auth login"
	exit 1
fi

# Temp files: BOTH traps are (re-)armed immediately after EVERY mktemp so a later
# mktemp failing under `set -e` can never leak an earlier temp file.
#
# TWO traps per arming, not one combined `EXIT INT TERM`: a Ctrl-C during a slow
# `glab` call would otherwise leak the temp files, but a combined handler would
# clean up and then RESUME the interrupted command's error path, which goes on to
# read the files it just unlinked. The INT/TERM handler therefore terminates the
# script itself (130 = SIGINT's conventional status). The EXIT trap still runs
# after it, and a second `rm -f` on an already-removed path is a no-op.
TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-glab-link-children.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT
trap 'rm -f "$TMP_ERR"; exit 130' INT TERM

TMP_BODY=$(mktemp "${TMPDIR:-/tmp}/pm-glab-link-children.body.XXXXXX")
trap 'rm -f "$TMP_ERR" "$TMP_BODY"' EXIT
trap 'rm -f "$TMP_ERR" "$TMP_BODY"; exit 130' INT TERM

# ---------------------------------------------------------------------------
# 1. Read the epic issue's CURRENT description straight to a FILE. Never into a
#    shell variable at this stage — it is untrusted repo content and everything
#    that INSPECTS or SPLICES it works on files only.
# ---------------------------------------------------------------------------
if ! glab issue view "$OPT_EPIC_ISSUE" --repo "$OPT_REPO" --output json \
	--jq '.description // ""' >"$TMP_BODY" 2>"$TMP_ERR"; then
	error "could not read epic issue #$OPT_EPIC_ISSUE in project '$OPT_REPO'"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 2. Determine which requested children are NEW. A child already present in
#    EITHER checkbox state ("- [ ] #N" or "- [x]/[X] #N") is idempotently
#    skipped — never re-appended, never recounted. SEEN additionally tracks
#    children already accepted THIS RUN, so a duplicate --child argument (e.g.
#    --child 11 --child 11) is linked at most once even when #11 is absent from
#    the description at the time both iterations check it — without SEEN,
#    neither iteration would see the other's pending addition (it isn't written
#    to TMP_BODY until step 3) and both would splice a duplicate line.
#    Everything built here comes ONLY from validated integers, never from the
#    description content just read.
#
#    THE PROBE TOLERATES SURROUNDING WHITESPACE (SHELL-002). An EXACT-line anchor
#    ("^- \[[ xX]\] #N$") only recognizes the lines THIS script wrote. A human
#    editing the epic in the GitLab web UI can perfectly reasonably leave a
#    trailing space, indent the item under a parent bullet, or save through a
#    client that writes CRLF — and every one of those made the probe MISS a child
#    that IS linked, so the line was appended a SECOND time and PM_LINKED
#    over-reported it as new. `[[:space:]]` covers the CR of a CRLF ending too (it
#    is a member of the POSIX space class in both grep and awk), so no separate
#    \r alternative is needed. The splice anchors below are loosened the same way,
#    and for the same reason: the probe and the anchors must agree on what counts
#    as an existing checklist line, or the new lines land in the wrong place.
#
#    The tolerance cannot over-match: "#${child}" is followed only by whitespace
#    up to end-of-line, so #5 never matches a "- [ ] #55" line.
# ---------------------------------------------------------------------------
LINKED_COUNT=0
NEW_LINES=""
SEEN=""
while IFS= read -r child; do
	[ -n "$child" ] || continue
	if printf '%s\n' "$SEEN" | grep -Fxq -- "$child"; then
		continue
	fi
	CHECK_RE="^[[:space:]]*- \[[ xX]\] #${child}[[:space:]]*$"
	if grep -Eq -- "$CHECK_RE" "$TMP_BODY" 2>/dev/null; then
		continue
	fi
	if [ -z "$SEEN" ]; then SEEN="$child"
	else SEEN="$SEEN
$child"
	fi
	LINKED_COUNT=$((LINKED_COUNT + 1))
	if [ -z "$NEW_LINES" ]; then NEW_LINES="- [ ] #$child"
	else NEW_LINES="$NEW_LINES
- [ ] #$child"
	fi
done <<EOF
$CHILDREN
EOF

if [ "$LINKED_COUNT" -eq 0 ]; then
	printf 'PM_LINKED=0\n'
	exit 0
fi

# ---------------------------------------------------------------------------
# 3. Splice the new lines into the description:
#      - if "## Linked children" already exists, insert right after its LAST
#        existing checklist line (or right after the heading itself if it has
#        none yet) — NOT at end-of-file, which would orphan the new lines below
#        whatever section follows the heading;
#      - otherwise, append a fresh heading + the new lines at end-of-file.
#    awk operates on TMP_BODY and TMP_NEW_LINES as FILE arguments throughout;
#    the untrusted description content is never read into a shell variable here.
#
#    NEW_LINES is written to a FILE, not passed as an awk -v value: some awk
#    implementations (BSD/macOS's "one true awk") reject a literal embedded
#    newline inside a -v assignment ("newline in string"), and NEW_LINES is itself
#    newline-separated. A file has no such restriction.
#
#    THE FILE ARRIVES AS AN ARGV OPERAND, NOT VIA `-v` (SHELL-003). Two reasons,
#    and both were live hazards:
#      * `-v` assignment performs ESCAPE PROCESSING, so a TMPDIR containing a
#        backslash yielded a mangled path that simply did not open — and
#        `while ((getline line < f) > 0)` cannot tell "could not open" (-1) from
#        "end of file" (0), so the loop ended with ZERO new lines, the epic was
#        rewritten with an EMPTY checklist, and PM_LINKED still reported success.
#      * As an operand the path is taken verbatim, and it is read by the ordinary
#        record loop, whose read failures awk itself reports and exits non-zero
#        for — the `if !` wrapper below then catches them.
#    The two operands are told apart by the standard `NR == FNR` idiom, and the
#    new-lines file is listed FIRST so `new_lines[]` is fully populated before the
#    first body record. That idiom needs the first file to be NON-EMPTY, which is
#    guaranteed here (this splice only runs with LINKED_COUNT > 0, so NEW_LINES
#    holds at least one line) — and END refuses to emit anything at all if it
#    somehow read none, so the failure mode is a refused write, never a wiped
#    checklist.
# ---------------------------------------------------------------------------
TMP_NEW_LINES=$(mktemp "${TMPDIR:-/tmp}/pm-glab-link-children.newlines.XXXXXX")
trap 'rm -f "$TMP_ERR" "$TMP_BODY" "$TMP_NEW_LINES"' EXIT
trap 'rm -f "$TMP_ERR" "$TMP_BODY" "$TMP_NEW_LINES"; exit 130' INT TERM
printf '%s\n' "$NEW_LINES" >"$TMP_NEW_LINES"

TMP_BODY_NEW=$(mktemp "${TMPDIR:-/tmp}/pm-glab-link-children.newbody.XXXXXX")
trap 'rm -f "$TMP_ERR" "$TMP_BODY" "$TMP_NEW_LINES" "$TMP_BODY_NEW"' EXIT
trap 'rm -f "$TMP_ERR" "$TMP_BODY" "$TMP_NEW_LINES" "$TMP_BODY_NEW"; exit 130' INT TERM

# Wrapped in an `if !`: a bare `awk … > file` failing under `set -e` exited 1 with
# a COMPLETELY EMPTY stderr, leaving the calling agent no way to tell what went
# wrong — or whether the epic had already been modified (it has not: the write-back
# below is the only mutation, and it is downstream of this splice).
if ! awk '
	BEGIN {
		n = 0
		body_total = 0
		in_section = 0
		anchor_line = 0
	}
	NR == FNR { n++; new_lines[n] = $0; next }
	{
		body_total++
		body[body_total] = $0
		if ($0 ~ /^[[:space:]]*## Linked children[[:space:]]*$/) {
			in_section = 1
			anchor_line = body_total
			next
		}
		if (in_section == 1) {
			if ($0 ~ /^[[:space:]]*- \[[ xX]\] #[0-9]+[[:space:]]*$/) { anchor_line = body_total }
			else { in_section = 0 }
		}
	}
	END {
		# Refuse to write anything if the new-lines file yielded no records. The
		# caller only reaches this splice with at least one child to link, so n==0
		# can only mean the file was unreadable or empty — and the old getline form
		# turned exactly that into a SILENT epic-wipe (empty checklist, PM_LINKED
		# still reporting success). Exiting before the first print leaves the output
		# file empty, so the shell error path below refuses the write-back.
		if (n == 0) { exit 1 }
		if (anchor_line == 0) {
			for (i = 1; i <= body_total; i++) print body[i]
			print ""
			print "## Linked children"
			for (i = 1; i <= n; i++) print new_lines[i]
		} else {
			for (i = 1; i <= anchor_line; i++) print body[i]
			for (i = 1; i <= n; i++) print new_lines[i]
			for (i = anchor_line + 1; i <= body_total; i++) print body[i]
		}
	}
' "$TMP_NEW_LINES" "$TMP_BODY" >"$TMP_BODY_NEW"; then
	error "failed to splice the checklist into epic issue #$OPT_EPIC_ISSUE's description"
	exit 1
fi

mv "$TMP_BODY_NEW" "$TMP_BODY"

# ---------------------------------------------------------------------------
# 4. Write the epic issue back.
#
#    ONLY HERE does the description enter a shell variable, and only because
#    `glab issue update` has no --description-file flag. The sentinel read
#    (`$(cat f && printf x)` then strip the x) keeps it byte-identical to the file
#    — a plain $(cat f) would strip ALL trailing newlines — and the value is
#    passed as ONE double-quoted argv token in a command built from positional
#    parameters, so the bytes are never re-parsed by a shell.
#
#    The spliced description can never be empty or the single character '-'
#    (it always contains at least the "## Linked children" heading and one
#    checklist line), so create-issue.sh's two body guards would be dead code
#    here and are deliberately not duplicated.
# ---------------------------------------------------------------------------
#    `cat … && printf x`, NOT `cat …; printf x`: with the semicolon the command
#    substitution takes ITS exit status from `printf`, which always succeeds, so a
#    mid-read I/O failure on `cat` was invisible even under `set -e` — and here
#    that would have written a TRUNCATED description over the epic's real one.
#    Exit 1, not 2: the unreadable file is this script's own temp file, not
#    something the caller passed.
if ! DESCRIPTION=$(cat "$TMP_BODY" && printf x); then
	error "failed to read back the spliced description for epic issue #$OPT_EPIC_ISSUE"
	warn  "the epic was NOT modified; re-run once the temporary directory is readable again"
	exit 1
fi
DESCRIPTION=${DESCRIPTION%x}

set -- glab issue update "$OPT_EPIC_ISSUE" --repo "$OPT_REPO" --description "$DESCRIPTION"

if ! "$@" >/dev/null 2>"$TMP_ERR"; then
	error "glab issue update failed for epic issue #$OPT_EPIC_ISSUE"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

printf 'PM_LINKED=%s\n' "$LINKED_COUNT"
exit 0
