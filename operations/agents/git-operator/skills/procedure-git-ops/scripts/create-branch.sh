#!/usr/bin/env sh
#
# create-branch.sh — create a `type/ticket-desc` branch off a base branch,
#                    idempotently.
#
# Purpose:
#   Builds the branch name from its parts, validates it against the naming
#   convention (standard-git-branch: lowercase, hyphen-separated, no '#', no
#   spaces), and creates it off --base. Creation ONLY — it never checks the
#   new branch out, so the caller's current branch/working tree is
#   untouched; switching to it (if wanted) is a separate, explicit step.
#
# Usage:
#   create-branch.sh --repo PATH --type TYPE --ticket ID --desc SLUG
#                     --base BRANCH [-h|--help]
#
#     --repo PATH   The git repo to act on (required); this script cd's
#                   into it.
#     --type TYPE     One of: feat, fix, refactor, perf, docs, chore, hotfix,
#                   release, test, build, ci (required — mirrors the commit
#                   types in standard-git-commit).
#     --ticket ID       The ticket id/number, no leading '#' (required).
#     --desc SLUG        A short, lowercase, hyphen-separated description
#                   (required) — e.g. "token-refresh".
#     --base BRANCH        The branch to create FROM (required). Must
#                   already resolve to a valid ref.
#     -h, --help              Show this help.
#
#   The resulting branch name is: TYPE/TICKET-DESC (e.g. "feat/1-token-refresh").
#
# Output:
#   GITOP_BRANCH=<name>   the resulting branch name (created, or already
#                         existed — idempotent either way).
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  branch exists (freshly created, or already existed — idempotent no-op)
#   1  --base does not resolve to a valid ref / `git branch` itself failed
#   2  usage error (missing argument, or the built name fails the naming
#      convention: uppercase, '#', spaces, or any non lowercase-kebab
#      character)
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
Usage: $PROG --repo PATH --type TYPE --ticket ID --desc SLUG --base BRANCH
              [-h|--help]

Create a "TYPE/TICKET-DESC" branch off --base, idempotently. Never checks
the branch out.

Options:
  --repo PATH     The git repo to act on (required).
  --type TYPE     feat|fix|refactor|perf|docs|chore|hotfix|release|test|build|ci
                  (required).
  --ticket ID     The ticket id/number, no leading '#' (required).
  --desc SLUG     A lowercase, hyphen-separated description (required).
  --base BRANCH   The branch to create FROM (required).
  -h, --help      Show this help.

Prints:
  GITOP_BRANCH=<name>

Exit codes:
  0  branch exists (created, or already existed)
  1  --base not found / git branch itself failed
  2  usage error / branch name fails the naming convention
EOF
}

need_arg() {
	[ -n "${2:-}" ] || { usage >&2; error "option $1 requires an argument"; exit 2; }
}

is_valid_type() {
	case "$1" in
		feat|fix|refactor|perf|docs|chore|hotfix|release|test|build|ci) return 0 ;;
		*) return 1 ;;
	esac
}

# is_valid_branch_name VALUE — lowercase, digits, '/', '-' only; no '#', no
# spaces, no uppercase, no other punctuation. Mirrors standard-git-branch's
# naming rule.
is_valid_branch_name() {
	case "$1" in
		*[!a-z0-9/-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
OPT_REPO=""
OPT_TYPE=""
OPT_TICKET=""
OPT_DESC=""
OPT_BASE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)   need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--type)   need_arg "$1" "${2:-}"; OPT_TYPE=$2; shift ;;
		--ticket) need_arg "$1" "${2:-}"; OPT_TICKET=$2; shift ;;
		--desc)   need_arg "$1" "${2:-}"; OPT_DESC=$2; shift ;;
		--base)   need_arg "$1" "${2:-}"; OPT_BASE=$2; shift ;;
		-h|--help) usage; exit 0 ;;
		--) shift; break ;;
		-*) usage >&2; error "unknown option: $1"; exit 2 ;;
		*)  usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ]   || { usage >&2; error "--repo is required"; exit 2; }
[ -n "$OPT_TYPE" ]   || { usage >&2; error "--type is required"; exit 2; }
[ -n "$OPT_TICKET" ] || { usage >&2; error "--ticket is required"; exit 2; }
[ -n "$OPT_DESC" ]   || { usage >&2; error "--desc is required"; exit 2; }
[ -n "$OPT_BASE" ]   || { usage >&2; error "--base is required"; exit 2; }

is_valid_type "$OPT_TYPE" || { usage >&2; error "--type must be one of feat|fix|refactor|perf|docs|chore|hotfix|release|test|build|ci, got: $OPT_TYPE"; exit 2; }

case "$OPT_TICKET" in
	*'#'*) usage >&2; error "--ticket must not contain '#': $OPT_TICKET"; exit 2 ;;
esac

BRANCH_NAME="$OPT_TYPE/$OPT_TICKET-$OPT_DESC"
is_valid_branch_name "$BRANCH_NAME" || { usage >&2; error "the built branch name fails the naming convention (lowercase, digits, '/', '-' only): $BRANCH_NAME"; exit 2; }

if ! command -v git >/dev/null 2>&1; then
	error "git is not installed"
	exit 1
fi

cd "$OPT_REPO" 2>/dev/null || { error "--repo does not exist or is not accessible: $OPT_REPO"; exit 1; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	error "not a git work tree: $OPT_REPO"
	exit 1
fi

# ---------------------------------------------------------------------------
# Idempotent: if the branch already exists, this is a no-op success.
# ---------------------------------------------------------------------------
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
	warn "branch already exists, no-op: $BRANCH_NAME"
	printf 'GITOP_BRANCH=%s\n' "$BRANCH_NAME"
	exit 0
fi

# ---------------------------------------------------------------------------
# --base must resolve to a valid ref before we branch from it.
# ---------------------------------------------------------------------------
if ! git rev-parse --verify --quiet "$OPT_BASE^{commit}" >/dev/null 2>&1; then
	error "--base does not resolve to a valid ref: $OPT_BASE"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/gitop-create-branch.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

if ! git branch "$BRANCH_NAME" "$OPT_BASE" 2>"$TMP_ERR"; then
	error "git branch failed"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

printf 'GITOP_BRANCH=%s\n' "$BRANCH_NAME"
exit 0
