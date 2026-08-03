#!/usr/bin/env sh
#
# link-children.sh — wire child issues under an epic by appending a
#                     task-list, WITHOUT ever constructing the epic body in
#                     a shell string.
#
# Purpose:
#   Links child issues to an epic so the epic's body renders a checklist of
#   its children, wiring the parent/child relationship GitHub-side.
#
# Mechanism (v1, deliberate choice — see the skill's SKILL.md):
#   Appends `- [ ] #<child>` lines to the epic's body so GitHub renders a
#   progress checklist and cross-links each child. This was chosen over the
#   GitHub sub-issues REST API: that API needs the child's internal database
#   id (an extra round-trip per child to resolve number -> id), and its
#   exact contract cannot be exercised against a real repo in this
#   environment (no live `gh` in development/test). The task-list form
#   reuses the well-established, verifiable `gh issue edit --body-file`
#   path this skill already depends on. This is a documented limitation for
#   v1, not an oversight — a sub-issues variant can replace this mechanism
#   later behind the same PM_LINKED contract.
#
# INJECTION SAFETY: the epic's EXISTING body is untrusted repo content, so it
# is read straight to a FILE and never assigned to a shell variable or
# interpolated into a string/heredoc. The new checklist lines this script
# appends are built ONLY from --child values that were validated as plain
# positive integers — never from body content — so appending them (and
# splicing them into the body via awk, operating on files only) is safe.
#
# Usage:
#   link-children.sh --repo OWNER/REPO --epic N --child N [--child N ...] [-h|--help]
#
#     --repo OWNER/REPO   Target repository (required).
#     --epic N             The epic's issue number (required).
#     --child N             A child issue number to link. Repeatable; at
#                          least one is required.
#     -h, --help           Show this help.
#
# Output:
#   PM_LINKED=<n>   number of NEW child links actually appended this run
#                   (a child already present in the epic body — in EITHER
#                   checkbox state, "- [ ] #N" or "- [x] #N" — is skipped
#                   and NOT recounted; this script is idempotent).
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  epic updated (or already linked to every requested child — no-op)
#   1  gh/awk absent / not authenticated / epic not found / gh edit failed
#   2  usage error
#
# NOT performed here (deliberately upstream): the GitHub-ACCOUNT confirmation
# gate — that is `procedure-git-auth`'s job, run by the calling agent BEFORE
# this script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

warn()  { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
error() { printf '%s: error: %s\n'   "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo OWNER/REPO --epic N --child N [--child N ...] [-h|--help]

Link child issues under an epic by appending "- [ ] #<child>" lines to the
epic's body. Idempotent: a child already linked (in either checkbox state)
is skipped. Never builds the epic body in shell — the existing body is read
straight to a file.

Options:
  --repo OWNER/REPO   Target repository (required).
  --epic N            The epic's issue number (required).
  --child N           A child issue number to link. Repeatable, required
                       at least once.
  -h, --help          Show this help.

Prints:
  PM_LINKED=<n>   number of NEW links appended this run

Exit codes:
  0  updated (or already fully linked)
  1  gh/awk absent / not authenticated / epic not found / edit failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

is_positive_int() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

# is_valid_repo_slug VALUE — allow-list: letters, digits, '.', '_', '-', and
# EXACTLY ONE '/' separating owner/repo, with NO ".." path segment. VALUE is
# interpolated into `gh` arguments, so this rejects both disallowed
# characters and dot-segment path traversal (e.g. "o/..", "../r") before
# that ever happens.
is_valid_repo_slug() {
	case "$1" in
		*[!A-Za-z0-9._/-]*) return 1 ;;
		..|../*|*/..|*/../*) return 1 ;;
		*/*/*) return 1 ;;
		*/*) return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_EPIC=""
CHILDREN=""   # newline-separated accumulator (POSIX sh has no arrays)

while [ $# -gt 0 ]; do
	case "$1" in
		--repo) need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--epic) need_arg "$1" "${2:-}"; OPT_EPIC=$2; shift ;;
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
is_valid_repo_slug "$OPT_REPO" || { usage >&2; error "--repo must be OWNER/REPO (letters, digits, '.', '_', '-' only), got: $OPT_REPO"; exit 2; }

[ -n "$OPT_EPIC" ] || { usage >&2; error "--epic is required"; exit 2; }
is_positive_int "$OPT_EPIC" || { usage >&2; error "--epic must be a positive integer, got: $OPT_EPIC"; exit 2; }
[ -n "$CHILDREN" ] || { usage >&2; error "at least one --child is required"; exit 2; }

# ---------------------------------------------------------------------------
# Tooling preconditions
# ---------------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
	error "GitHub CLI (gh) is not installed"
	warn  "install it from https://cli.github.com/ then re-run"
	exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
	error "awk is not installed (required to splice the checklist into the epic body)"
	exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
	error "gh is installed but not authenticated"
	warn  "authenticate with: gh auth login"
	exit 1
fi

# Temp files: the EXIT trap is (re-)armed immediately after EVERY mktemp so a
# later mktemp failing under `set -e` can never leak an earlier temp file.
TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/pm-link-children.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

TMP_BODY=$(mktemp "${TMPDIR:-/tmp}/pm-link-children.body.XXXXXX")
trap 'rm -f "$TMP_ERR" "$TMP_BODY"' EXIT

# ---------------------------------------------------------------------------
# 1. Read the epic's CURRENT body straight to a file. Never into a shell
#    variable — it is untrusted repo content.
# ---------------------------------------------------------------------------
if ! gh issue view "$OPT_EPIC" --repo "$OPT_REPO" --json body --jq '.body // ""' >"$TMP_BODY" 2>"$TMP_ERR"; then
	error "could not read epic #$OPT_EPIC in repo '$OPT_REPO'"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 2. Determine which requested children are NEW. A child already present in
#    EITHER checkbox state ("- [ ] #N" or "- [x]/[X] #N") is idempotently
#    skipped — never re-appended, never recounted. SEEN additionally tracks
#    children already accepted THIS RUN, so a duplicate --child argument
#    (e.g. --child 11 --child 11) is linked at most once even when #11 is
#    absent from the body at the time both iterations check it — without
#    SEEN, neither iteration would see the other's pending addition (it
#    isn't written to TMP_BODY until step 3) and both would splice a
#    duplicate line. Everything built here comes ONLY from validated
#    integers, never from the body content just read.
# ---------------------------------------------------------------------------
LINKED_COUNT=0
NEW_LINES=""
SEEN=""
while IFS= read -r child; do
	[ -n "$child" ] || continue
	if printf '%s\n' "$SEEN" | grep -Fxq -- "$child"; then
		continue
	fi
	CHECK_RE="^- \[[ xX]\] #${child}\$"
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
# 3. Splice the new lines into the body:
#      - if "## Linked children" already exists, insert right after its LAST
#        existing checklist line (or right after the heading itself if it
#        has none yet) — NOT at end-of-file, which would orphan the new
#        lines below whatever section follows the heading;
#      - otherwise, append a fresh heading + the new lines at end-of-file.
#    awk operates on TMP_BODY and TMP_NEW_LINES as FILE arguments throughout;
#    the untrusted body content is never read into a shell variable.
#
#    NEW_LINES is written to a FILE (read back via getline), not passed as an
#    awk -v value: some awk implementations (BSD/macOS's "one true awk")
#    reject a literal embedded newline inside a -v assignment ("newline in
#    string"), and NEW_LINES is itself newline-separated. A file has no such
#    restriction.
# ---------------------------------------------------------------------------
TMP_NEW_LINES=$(mktemp "${TMPDIR:-/tmp}/pm-link-children.newlines.XXXXXX")
trap 'rm -f "$TMP_ERR" "$TMP_BODY" "$TMP_NEW_LINES"' EXIT
printf '%s\n' "$NEW_LINES" >"$TMP_NEW_LINES"

TMP_BODY_NEW=$(mktemp "${TMPDIR:-/tmp}/pm-link-children.newbody.XXXXXX")
trap 'rm -f "$TMP_ERR" "$TMP_BODY" "$TMP_NEW_LINES" "$TMP_BODY_NEW"' EXIT

awk -v newfile="$TMP_NEW_LINES" '
	BEGIN {
		n = 0
		while ((getline line < newfile) > 0) { n++; new_lines[n] = line }
		close(newfile)
		in_section = 0
		anchor_line = 0
	}
	{
		body[NR] = $0
		if ($0 == "## Linked children") { in_section = 1; anchor_line = NR; next }
		if (in_section == 1) {
			if ($0 ~ /^- \[[ xX]\] #[0-9]+$/) { anchor_line = NR }
			else { in_section = 0 }
		}
	}
	END {
		total = NR
		if (anchor_line == 0) {
			for (i = 1; i <= total; i++) print body[i]
			print ""
			print "## Linked children"
			for (i = 1; i <= n; i++) print new_lines[i]
		} else {
			for (i = 1; i <= anchor_line; i++) print body[i]
			for (i = 1; i <= n; i++) print new_lines[i]
			for (i = anchor_line + 1; i <= total; i++) print body[i]
		}
	}
' "$TMP_BODY" >"$TMP_BODY_NEW"

mv "$TMP_BODY_NEW" "$TMP_BODY"

# ---------------------------------------------------------------------------
# 4. Write the epic back — the body is passed ONLY as a file path.
# ---------------------------------------------------------------------------
if ! gh issue edit "$OPT_EPIC" --repo "$OPT_REPO" --body-file "$TMP_BODY" >/dev/null 2>"$TMP_ERR"; then
	error "gh issue edit failed for epic #$OPT_EPIC"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

printf 'PM_LINKED=%s\n' "$LINKED_COUNT"
exit 0
