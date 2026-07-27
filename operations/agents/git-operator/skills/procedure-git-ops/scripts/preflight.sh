#!/usr/bin/env sh
#
# preflight.sh — READ-ONLY readiness check BEFORE any git-mutating operation
#                (create-branch.sh / commit.sh / push.sh / create-tag.sh).
#
# Purpose:
#   Verifies the repo is in a sane state to act on: a real git work tree,
#   HEAD on an actual branch (not detached), no rebase/merge/cherry-pick in
#   progress, and — if the caller expects a specific branch/remote — that
#   reality matches. Reports the current branch and every dirty file, so the
#   caller can visually confirm none of them are unrelated to what it is
#   about to do before it stages anything. NEVER writes to the repo.
#
# Usage:
#   preflight.sh --repo PATH [--expect-branch NAME] [--expect-remote NAME]
#                [-h|--help]
#
#     --repo PATH            The git repo to check (required); this script
#                            cd's into it.
#     --expect-branch NAME    Fail readiness if HEAD is not this branch.
#     --expect-remote NAME    Fail readiness if this remote is not configured.
#     -h, --help                Show this help.
#
# Output:
#   A human-readable block, THEN machine-parseable GITOP_*=VALUE lines:
#     GITOP_CLEAN=true|false          no dirty files at all
#     GITOP_BRANCH=<name>             empty if detached
#     GITOP_DETACHED=true|false
#     GITOP_OP_IN_PROGRESS=<kind>     rebase | merge | cherry-pick | none
#     GITOP_DIRTY_FILES=<n>           count of modified/untracked paths
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  ready (a git work tree, HEAD on a branch, no operation in progress,
#      and any --expect-* given matches)
#   1  not ready — reasons are printed to stderr (dirty files ALONE do not
#      block readiness; they are reported, never treated as a failure — a
#      caller routinely runs this before it has staged anything yet)
#   2  usage error
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
Usage: $PROG --repo PATH [--expect-branch NAME] [--expect-remote NAME]
              [-h|--help]

Read-only readiness check before any git-mutating operation. Never writes.

Options:
  --repo PATH            The git repo to check (required).
  --expect-branch NAME   Fail readiness if HEAD is not this branch.
  --expect-remote NAME   Fail readiness if this remote is not configured.
  -h, --help             Show this help.

Prints:
  GITOP_CLEAN=true|false
  GITOP_BRANCH=<name>
  GITOP_DETACHED=true|false
  GITOP_OP_IN_PROGRESS=rebase|merge|cherry-pick|none
  GITOP_DIRTY_FILES=<n>

Exit codes:
  0  ready
  1  not ready (see stderr for reasons)
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_EXPECT_BRANCH=""
OPT_EXPECT_REMOTE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)           need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--expect-branch)  need_arg "$1" "${2:-}"; OPT_EXPECT_BRANCH=$2; shift ;;
		--expect-remote)  need_arg "$1" "${2:-}"; OPT_EXPECT_REMOTE=$2; shift ;;
		-h|--help)        usage; exit 0 ;;
		--)               shift; break ;;
		-*)               usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }

if ! command -v git >/dev/null 2>&1; then
	error "git is not installed"
	exit 1
fi

cd "$OPT_REPO" 2>/dev/null || { error "--repo does not exist or is not accessible: $OPT_REPO"; exit 1; }

NOT_READY=0

# ---------------------------------------------------------------------------
# 1. Must be a real git work tree.
# ---------------------------------------------------------------------------
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]; then
	error "not a git work tree: $OPT_REPO"
	# Nothing else below is meaningful without a work tree — report and stop.
	printf 'GITOP_CLEAN=false\n'
	printf 'GITOP_BRANCH=\n'
	printf 'GITOP_DETACHED=true\n'
	printf 'GITOP_OP_IN_PROGRESS=none\n'
	printf 'GITOP_DIRTY_FILES=0\n'
	exit 1
fi

# ---------------------------------------------------------------------------
# 2. HEAD must be on a real branch, not detached.
# ---------------------------------------------------------------------------
BRANCH=""
DETACHED=false
if BRANCH=$(git symbolic-ref -q --short HEAD 2>/dev/null); then
	:
else
	DETACHED=true
	NOT_READY=1
	error "HEAD is detached — not on a branch"
fi

# ---------------------------------------------------------------------------
# 3. No rebase/merge/cherry-pick in progress. These are plain filesystem
#    markers (git has no single query for "an operation is in progress");
#    checking them directly is the standard, git-version-independent way.
# ---------------------------------------------------------------------------
GIT_DIR=$(git rev-parse --absolute-git-dir)
OP_IN_PROGRESS=none
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ]; then
	OP_IN_PROGRESS=rebase
elif [ -f "$GIT_DIR/MERGE_HEAD" ]; then
	OP_IN_PROGRESS=merge
elif [ -f "$GIT_DIR/CHERRY_PICK_HEAD" ]; then
	OP_IN_PROGRESS=cherry-pick
fi
if [ "$OP_IN_PROGRESS" != "none" ]; then
	NOT_READY=1
	error "an operation is already in progress: $OP_IN_PROGRESS"
fi

# ---------------------------------------------------------------------------
# 4. --expect-branch / --expect-remote, if given.
# ---------------------------------------------------------------------------
if [ -n "$OPT_EXPECT_BRANCH" ] && [ "$BRANCH" != "$OPT_EXPECT_BRANCH" ]; then
	NOT_READY=1
	error "expected branch '$OPT_EXPECT_BRANCH', HEAD is on '${BRANCH:-<detached>}'"
fi

if [ -n "$OPT_EXPECT_REMOTE" ]; then
	if ! git remote 2>/dev/null | grep -Fxq -- "$OPT_EXPECT_REMOTE"; then
		NOT_READY=1
		error "expected remote '$OPT_EXPECT_REMOTE' is not configured"
	fi
fi

# ---------------------------------------------------------------------------
# 5. Dirty files — reported, never itself a readiness failure. Listed so the
#    caller can see at a glance whether any of them are unrelated to what it
#    is about to stage.
# ---------------------------------------------------------------------------
DIRTY_LIST=$(git status --porcelain 2>/dev/null || true)
DIRTY_COUNT=0
CLEAN=true
if [ -n "$DIRTY_LIST" ]; then
	CLEAN=false
	DIRTY_COUNT=$(printf '%s\n' "$DIRTY_LIST" | awk 'END { print NR }')
	warn "$DIRTY_COUNT dirty file(s) present:"
	printf '%s\n' "$DIRTY_LIST" | sed 's/^/  /' >&2
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
printf 'Git Preflight\n'
printf '  Repo:            %s\n' "$OPT_REPO"
printf '  Branch:          %s\n' "${BRANCH:-<detached>}"
printf '  Detached:        %s\n' "$DETACHED"
printf '  Op in progress:  %s\n' "$OP_IN_PROGRESS"
printf '  Clean:           %s\n' "$CLEAN"
printf '  Dirty files:     %s\n' "$DIRTY_COUNT"
printf '\n'
printf 'GITOP_CLEAN=%s\n'            "$CLEAN"
printf 'GITOP_BRANCH=%s\n'           "$BRANCH"
printf 'GITOP_DETACHED=%s\n'         "$DETACHED"
printf 'GITOP_OP_IN_PROGRESS=%s\n'   "$OP_IN_PROGRESS"
printf 'GITOP_DIRTY_FILES=%s\n'      "$DIRTY_COUNT"

[ "$NOT_READY" -eq 0 ] || exit 1
exit 0
