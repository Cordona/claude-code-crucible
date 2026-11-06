#!/usr/bin/env sh
#
# create-branch.sh — create a `type/ticket-desc` branch off a base branch,
#                    idempotently.
#
# Purpose:
#   Builds the branch name from its parts, validates it against the naming
#   convention (standard-git-branch: type and description lowercase,
#   hyphen-separated, no '#', no spaces; the ticket is lowercase too, or a
#   tracker key — ^[A-Z][A-Z0-9]+-[0-9]+$, e.g. PSWS-1313 — which Jira needs
#   in uppercase to link the branch), and creates it off --base. Creation
#   ONLY — it never checks the new branch out, so the caller's current
#   branch/working tree is untouched; switching to it (if wanted) is a
#   separate, explicit step.
#
#   Case twins: a local branch whose name differs from the built name only
#   in letter case (feat/psws-1-x vs feat/PSWS-1-x) is refused on EVERY
#   filesystem, including case-sensitive ones where git would store both:
#   on a case-insensitive filesystem (macOS, Windows) the two refs collide,
#   so a twin breaks every clone made there.
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
#                   Lowercase, or a tracker key such as PSWS-1313.
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
#   GITOP_CREATED=true|false  true if this run created the branch off --base;
#                         false on an idempotent no-op (the exact name
#                         already existed, and --base was not checked) —
#                         both are SUCCESS.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  branch exists (freshly created, or already existed — idempotent no-op)
#   1  --base does not resolve to a valid ref / a branch differing only in
#      case already exists / the local branches cannot be listed / `git
#      branch` itself failed
#   2  usage error (missing argument, or the built name fails the naming
#      convention: '#', spaces, uppercase in the type or description,
#      uppercase in a ticket that is not a tracker key, or any other non
#      lowercase-kebab character)
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
                  Lowercase, or a tracker key such as PSWS-1313.
  --desc SLUG     A lowercase, hyphen-separated description (required;
                  never uppercase).
  --base BRANCH   The branch to create FROM (required).
  -h, --help      Show this help.

Prints:
  GITOP_BRANCH=<name>
  GITOP_CREATED=true|false   (false only on the idempotent no-op; both are
                             success)

Exit codes:
  0  branch exists (created, or already existed)
  1  --base not found / a branch differing only in case exists /
     git branch itself failed
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
# spaces, no other punctuation. Mirrors standard-git-branch's rule for the
# type and description. A tracker-key ticket is admitted by the caller
# validating the name with that key lowercased, never by loosening this check.
is_valid_branch_name() {
	case "$1" in
		*[!a-z0-9/-]*) return 1 ;;
		*) return 0 ;;
	esac
}

# is_tracker_key VALUE — true when VALUE is a tracker key,
# ^[A-Z][A-Z0-9]+-[0-9]+$ (e.g. PSWS-1313, AB2-7). The letters and digits are
# spelled out rather than written as ranges: a range like A-Z is
# collation-dependent and can match lowercase letters under some locales.
is_tracker_key() {
	case "$1" in
		*-*-*) return 1 ;;
		[ABCDEFGHIJKLMNOPQRSTUVWXYZ][ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]*-[0123456789]*) ;;
		*) return 1 ;;
	esac
	case "${1%-*}" in
		*[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789]*) return 1 ;;
		*) ;;
	esac
	case "${1#*-}" in
		*[!0123456789]*) return 1 ;;
		*) return 0 ;;
	esac
}

# sed's y/// takes literal lists, so lowercasing with it is locale-independent.
readonly ASCII_TO_LOWER='y/ABCDEFGHIJKLMNOPQRSTUVWXYZ/abcdefghijklmnopqrstuvwxyz/'

# to_lower_ascii VALUE — prints VALUE with ASCII A-Z mapped to a-z.
to_lower_ascii() {
	printf '%s\n' "$1" | sed "$ASCII_TO_LOWER"
}

# branches_named_ignoring_case LOWERCASED_BRANCH REFS — prints each branch in
# REFS (a newline-separated `refs/heads/...` list) whose ASCII-lowercased name
# equals LOWERCASED_BRANCH. sed pairs every name with its lowercased form; awk
# compares by plain string equality, never a pattern built from a branch name.
# Ref names cannot contain spaces, so a space is a safe separator.
branches_named_ignoring_case() {
	printf '%s\n' "$2" |
		sed -e 's,^refs/heads/,,' -e 'h' -e "$ASCII_TO_LOWER" -e 'G' -e 's/\n/ /' |
		GITOP_WANTED=$1 awk '($1 "") == (ENVIRON["GITOP_WANTED"] "") { print $2 }'
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
NAME_TO_VALIDATE=$BRANCH_NAME
if is_tracker_key "$OPT_TICKET"; then
	NAME_TO_VALIDATE="$OPT_TYPE/$(to_lower_ascii "$OPT_TICKET")-$OPT_DESC"
fi
is_valid_branch_name "$NAME_TO_VALIDATE" || { usage >&2; error "the built branch name fails the naming convention (lowercase, digits, '/', '-' only; the ticket may instead be a tracker key such as PSWS-1313): $BRANCH_NAME"; exit 2; }

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
# Idempotent: if the branch already exists, this is a no-op success; a case
# twin is refused. Existence comes from the ref names git lists, never from a
# ref lookup such as `git show-ref --verify`: on a case-insensitive filesystem
# that lookup opens a loose feat/psws-1-x file for refs/heads/feat/PSWS-1-x.
# ---------------------------------------------------------------------------
LOCAL_BRANCH_REFS=$(git for-each-ref --format='%(refname)' refs/heads/) || { error "could not list local branches"; exit 1; }
BRANCH_NAME_LOWER=$(to_lower_ascii "$BRANCH_NAME")
CASE_MATCHES=$(branches_named_ignoring_case "$BRANCH_NAME_LOWER" "$LOCAL_BRANCH_REFS")

if printf '%s\n' "$CASE_MATCHES" | grep -Fxq -- "$BRANCH_NAME"; then
	warn "branch already exists, no-op: $BRANCH_NAME"
	printf 'GITOP_BRANCH=%s\n' "$BRANCH_NAME"
	printf 'GITOP_CREATED=false\n'
	exit 0
fi

if [ -n "$CASE_MATCHES" ]; then
	CASE_TWIN=$(printf '%s\n' "$CASE_MATCHES" | sed -n 1p)
	error "a branch differing only in case exists: $CASE_TWIN (refusing to create $BRANCH_NAME)"
	exit 1
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
printf 'GITOP_CREATED=true\n'
exit 0
