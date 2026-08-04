#!/usr/bin/env sh
#
# push.sh — push a branch to a remote, refusing a protected branch outright
#           and detecting (never auto-fixing) a non-fast-forward rejection.
#
# PROTECTED-BRANCH REFUSAL (unconditional, checked FIRST): `main`, `master`,
# `develop`, and any `release/*` branch NEVER get a direct push from this
# script — force or not. Per standard-git-branch, those branches only move
# via a reviewed PR merge; this script enforces that client-side, ahead of
# whatever server-side ruleset also blocks it.
#
# NON-FAST-FORWARD: on a rejected push, this script DETECTS that specific
# cause and reports it plainly ("rebase onto base then retry") — it never
# rebases or force-pushes on the caller's behalf. Whether/how to resolve a
# non-ff is the calling agent's judgment, not this script's.
#
# --force-with-lease: only runs when explicitly passed, and only ever on a
# NON-protected branch (the unconditional refusal above already covers
# this — there is no separate force-specific protected check needed). Uses
# git's own `--force-with-lease` (a "the remote hasn't moved since I last
# saw it" stale-check), never a bare `--force`.
#
# OPTION-INJECTION GUARD: `--remote`/`--branch` are validated to reject a
# leading '-' (neither can legitimately start with one), AND a literal `--`
# end-of-options marker precedes them in every `git push` invocation below.
# Belt and suspenders: `git push` parses interspersed options, so a
# `-`-leading value could otherwise be taken as a flag (e.g. an attacker- or
# bug-supplied `--branch=--force` reaching `git push ... "$OPT_REMOTE"
# "--force"` unguarded) — over a destructive sink, both defenses apply.
#
# Purpose:
#   Wraps `git push` with the safety checks a direct git invocation would
#   skip: the protected-branch refusal, first-push-vs-subsequent detection,
#   an idempotent already-up-to-date short-circuit, and a specific
#   non-fast-forward diagnosis instead of a raw git error dump.
#
# Usage:
#   push.sh --repo PATH --remote NAME --branch NAME [--force-with-lease]
#           [-h|--help]
#
#     --repo PATH             The git repo to act in (required); this
#                             script cd's into it.
#     --remote NAME             The remote to push to (required).
#     --branch NAME               The branch to push (required).
#     --force-with-lease             Force-push using git's own stale-check.
#                             Refused outright on a protected branch (see
#                             above) — this flag never overrides that.
#     -h, --help                       Show this help.
#
# Output:
#   GITOP_PUSHED=true|false   true if this run actually transferred a new
#                             ref update; false on an idempotent no-op
#                             (already up to date) — both are SUCCESS.
#   GITOP_UPSTREAM=<remote>/<branch>
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  pushed, or already up to date (no-op)
#   1  the target branch is protected / a non-fast-forward rejection / `git
#      push` itself failed for another reason
#   2  usage error
#
# NOT performed here (deliberately upstream): the decision to push at all,
# and identity/signing — those are the calling agent's and
# `procedure-git-identity`'s, respectively (see this skill's SKILL.md).
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
Usage: $PROG --repo PATH --remote NAME --branch NAME [--force-with-lease]
              [-h|--help]

Push a branch to a remote. Refuses a direct push to a protected branch
(main, master, develop, release/*) outright — force or not. Detects (never
auto-fixes) a non-fast-forward rejection.

Options:
  --repo PATH          The git repo to act in (required).
  --remote NAME        The remote to push to (required).
  --branch NAME        The branch to push (required).
  --force-with-lease   Force-push with git's own stale-check. Refused on a
                       protected branch.
  -h, --help           Show this help.

Prints:
  GITOP_PUSHED=true|false
  GITOP_UPSTREAM=<remote>/<branch>

Exit codes:
  0  pushed (or already up to date)
  1  protected branch / non-fast-forward / push itself failed
  2  usage error
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

# is_protected_branch VALUE — main, master, develop, or any release/*. These
# never take a direct push from this script (standard-git-branch: only a
# reviewed PR merge moves them).
is_protected_branch() {
	case "$1" in
		main|master|develop|release/*) return 0 ;;
		*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_REMOTE=""
OPT_BRANCH=""
OPT_FORCE=0

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)              need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--remote)            need_arg "$1" "${2:-}"; OPT_REMOTE=$2; shift ;;
		--branch)            need_arg "$1" "${2:-}"; OPT_BRANCH=$2; shift ;;
		--force-with-lease)  OPT_FORCE=1 ;;
		-h|--help)           usage; exit 0 ;;
		--)                  shift; break ;;
		-*)                  usage >&2; error "unknown option: $1"; exit 2 ;;
		*)                   usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ]   || { usage >&2; error "--repo is required"; exit 2; }
[ -n "$OPT_REMOTE" ] || { usage >&2; error "--remote is required"; exit 2; }
[ -n "$OPT_BRANCH" ] || { usage >&2; error "--branch is required"; exit 2; }

# Neither a remote nor a branch name can legitimately start with '-' — reject
# it here as a usage error, before it can ever reach `git push`'s own option
# parser (see the OPTION-INJECTION GUARD note above).
case "$OPT_REMOTE" in
	-*) usage >&2; error "--remote must not start with '-': $OPT_REMOTE"; exit 2 ;;
esac
case "$OPT_BRANCH" in
	-*) usage >&2; error "--branch must not start with '-': $OPT_BRANCH"; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Protected-branch refusal — unconditional, checked before touching git at
# all. Force or not makes no difference; this is not a --force-specific
# check.
# ---------------------------------------------------------------------------
if is_protected_branch "$OPT_BRANCH"; then
	error "refusing to push directly to protected branch '$OPT_BRANCH' (main/master/develop/release/* only move via a reviewed PR merge)"
	exit 1
fi

if ! command -v git >/dev/null 2>&1; then
	error "git is not installed"
	exit 1
fi

cd "$OPT_REPO" 2>/dev/null || { error "--repo does not exist or is not accessible: $OPT_REPO"; exit 1; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	error "not a git work tree: $OPT_REPO"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/gitop-push.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

# ---------------------------------------------------------------------------
# First push (no upstream yet) vs subsequent push.
# ---------------------------------------------------------------------------
HAS_UPSTREAM=1
if ! git rev-parse --abbrev-ref --symbolic-full-name "$OPT_BRANCH@{upstream}" >/dev/null 2>&1; then
	HAS_UPSTREAM=0
fi

# ---------------------------------------------------------------------------
# Idempotency pre-check: skip the push entirely if the remote already points
# at the same commit as local — a true no-op, not merely "git decided there
# was nothing to do". Only meaningful once an upstream already exists.
# ---------------------------------------------------------------------------
if [ "$HAS_UPSTREAM" -eq 1 ]; then
	LOCAL_SHA=$(git rev-parse "$OPT_BRANCH")
	REMOTE_SHA=$(git ls-remote "$OPT_REMOTE" "refs/heads/$OPT_BRANCH" 2>"$TMP_ERR" | awk '{print $1}')
	if [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" = "$LOCAL_SHA" ]; then
		warn "already up to date, no-op: $OPT_REMOTE/$OPT_BRANCH"
		printf 'GITOP_PUSHED=false\n'
		printf 'GITOP_UPSTREAM=%s/%s\n' "$OPT_REMOTE" "$OPT_BRANCH"
		exit 0
	fi
fi

# ---------------------------------------------------------------------------
# Build the push argv as POSITIONAL PARAMETERS — POSIX sh's array equivalent.
# The literal `--` marks the end of options: even if a `-`-leading remote/
# branch value somehow reached this point, git would treat it as a plain
# positional, never as a flag.
# ---------------------------------------------------------------------------
set -- git push
[ "$HAS_UPSTREAM" -eq 1 ] || set -- "$@" -u
[ "$OPT_FORCE" -eq 0 ]    || set -- "$@" --force-with-lease
set -- "$@" -- "$OPT_REMOTE" "$OPT_BRANCH"

if "$@" >/dev/null 2>"$TMP_ERR"; then
	printf 'GITOP_PUSHED=true\n'
	printf 'GITOP_UPSTREAM=%s/%s\n' "$OPT_REMOTE" "$OPT_BRANCH"
	exit 0
fi

# ---------------------------------------------------------------------------
# Push failed — diagnose non-fast-forward specifically; git's own rejection
# text is stable enough to match on. Anything else is reported generically
# with git's raw error attached.
# ---------------------------------------------------------------------------
if grep -Eq -- 'non-fast-forward|fetch first|tip of your current branch is behind' "$TMP_ERR"; then
	error "non-fast-forward — rebase onto base then retry"
else
	error "git push failed"
fi
sed 's/^/  /' "$TMP_ERR" >&2
exit 1
