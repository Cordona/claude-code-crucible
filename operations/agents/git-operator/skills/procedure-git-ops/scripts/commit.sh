#!/usr/bin/env sh
#
# commit.sh — commit the CURRENTLY-STAGED index, with the message ALWAYS
#             supplied as a FILE, and fail-CLOSED unless the result is
#             verifiably signed.
#
# WHY --message-file only (no -m "$msg"): a commit message can be derived
# from a diff summary or an issue/PR body and can contain backticks/$() —
# the same command-injection sink `procedure-gh-issues` exists to eliminate
# for issue bodies. This script never constructs the message in a
# string/heredoc/$(), never eval's anything, and only ever passes a
# caller-supplied file straight through to `git commit -F`.
#
# WHAT THIS SCRIPT DOES NOT DO: it does not stage anything (the caller
# stages — staging IS the atomic-split decision, owned by standard-git-commit
# / the git-operator, not this script), and it does not resolve or confirm
# the signing identity (that is procedure-git-identity's job, run by the
# caller BEFORE this script). This script's ONLY jobs are: commit the
# already-staged index, and verify the result is actually signed.
#
# FAIL-CLOSED ON SIGNING: after committing, this script checks the new
# commit's signature status (`git log -1 --format=%G?`) and accepts ONLY
# 'G' (good) or 'U' (good, unknown validity) — every other code (bad,
# expired, revoked, unsigned, unverifiable) is a FAILURE. On failure, this
# script NEVER retries with `--no-gpg-sign`, and a failing hook is NEVER
# bypassed with `--no-verify`. If `git commit -S` itself already created a
# commit that then fails verification, the SHA is still reported (via
# GITOP_COMMIT_SHA) so the caller can inspect/undo it — this script does not
# auto-revert a bad commit, since undoing history is a mutating decision
# outside its narrow scope.
#
# Purpose:
#   Wraps `git commit` with the one check a direct git invocation would
#   skip: that the commit it just made is actually, verifiably signed —
#   never trusting `-S`'s own exit code alone as proof.
#
# Usage:
#   commit.sh --repo PATH --message-file PATH [-h|--help]
#
#     --repo PATH           The git repo to act in (required); this script
#                           cd's into it.
#     --message-file PATH     Path to the commit message (required). Must
#                           exist and be readable. There is deliberately NO
#                           -m/--message passthrough.
#     -h, --help                Show this help.
#
# Output:
#   GITOP_COMMIT_SHA=<sha>   printed whenever a commit object was actually
#                           created — INCLUDING when it then fails signature
#                           verification, so the caller always has the
#                           identifier needed to act.
#   Diagnostics go to stderr.
#
# Exit codes:
#   0  committed AND verified signed (%G? is G or U)
#   1  nothing staged / `git commit` itself failed (hook or signing
#      rejection) / the commit was created but failed signature verification
#   2  usage error (missing/invalid argument, unreadable message-file)
#
# NOT performed here (deliberately upstream): staging (the caller's atomic-
# split decision) and identity resolution/confirmation — that is
# `procedure-git-identity`'s job, run by the calling agent BEFORE this
# script (see this skill's SKILL.md).
#
# Portability: POSIX sh only (no bashisms). Every external binary is guarded
#   with `command -v`. Self-contained: sources nothing.
#
set -eu

LC_ALL=C
export LC_ALL

PROG=${0##*/}

error() { printf '%s: error: %s\n' "$PROG" "$*" >&2; }

usage() {
	cat <<EOF
Usage: $PROG --repo PATH --message-file PATH [-h|--help]

Commit the CURRENTLY-STAGED index. The message is ALWAYS a file
(--message-file) — there is no -m/--message passthrough. Fails closed
unless the resulting commit is verifiably signed.

Options:
  --repo PATH           The git repo to act in (required).
  --message-file PATH   Path to the commit message (required; must
                         exist/readable).
  -h, --help             Show this help.

Prints (whenever a commit object was created, even one that then fails
verification):
  GITOP_COMMIT_SHA=<sha>

Exit codes:
  0  committed and verified signed
  1  nothing staged / commit itself failed / signature verification failed
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
OPT_MESSAGE_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
		--repo)         need_arg "$1" "${2:-}"; OPT_REPO=$2; shift ;;
		--message-file) need_arg "$1" "${2:-}"; OPT_MESSAGE_FILE=$2; shift ;;
		-h|--help)      usage; exit 0 ;;
		--)             shift; break ;;
		-*)             usage >&2; error "unknown option: $1"; exit 2 ;;
		*)              usage >&2; error "unexpected argument: $1"; exit 2 ;;
	esac
	shift
done
[ $# -eq 0 ] || { usage >&2; error "unexpected argument: $1"; exit 2; }

[ -n "$OPT_REPO" ] || { usage >&2; error "--repo is required"; exit 2; }

[ -n "$OPT_MESSAGE_FILE" ] || { usage >&2; error "--message-file is required"; exit 2; }
if [ ! -f "$OPT_MESSAGE_FILE" ] || [ ! -r "$OPT_MESSAGE_FILE" ]; then
	usage >&2
	error "--message-file does not exist or is not readable: $OPT_MESSAGE_FILE"
	exit 2
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

# ---------------------------------------------------------------------------
# Refuse a detached HEAD / an operation already in progress — commit.sh does
# not re-derive preflight's full logic; these two are cheap, direct checks
# worth repeating here since committing into either is actively dangerous.
# ---------------------------------------------------------------------------
if ! git symbolic-ref -q HEAD >/dev/null 2>&1; then
	error "HEAD is detached — refusing to commit"
	exit 1
fi

GIT_DIR=$(git rev-parse --absolute-git-dir)
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -f "$GIT_DIR/CHERRY_PICK_HEAD" ]; then
	error "an operation (rebase/merge/cherry-pick) is already in progress — refusing to commit"
	exit 1
fi

# ---------------------------------------------------------------------------
# Nothing staged -> fail. `git diff --cached --quiet` exits 0 when there is
# NO staged difference, which is the FAILURE case here — the `if` form is
# what keeps this safe under `set -e` regardless of which way it goes.
# ---------------------------------------------------------------------------
if git diff --cached --quiet 2>/dev/null; then
	error "nothing is staged to commit"
	exit 1
fi

TMP_ERR=$(mktemp "${TMPDIR:-/tmp}/gitop-commit.err.XXXXXX")
trap 'rm -f "$TMP_ERR"' EXIT

# ---------------------------------------------------------------------------
# Commit. The message is passed ONLY as a file path; it is never read into a
# shell variable or interpolated into a string here. Never --no-gpg-sign,
# never --no-verify.
# ---------------------------------------------------------------------------
if ! git commit -S --signoff -F "$OPT_MESSAGE_FILE" >/dev/null 2>"$TMP_ERR"; then
	error "git commit failed (hook rejection or signing failure)"
	sed 's/^/  /' "$TMP_ERR" >&2
	exit 1
fi

COMMIT_SHA=$(git rev-parse HEAD)
printf 'GITOP_COMMIT_SHA=%s\n' "$COMMIT_SHA"

# ---------------------------------------------------------------------------
# Fail-closed signature verification: ONLY 'G' (good) or 'U' (good, unknown
# validity) are acceptable. Everything else — including 'N' (no signature),
# 'B' (bad), 'E' (cannot check), 'X'/'Y' (expired), 'R' (revoked key) — is a
# failure. The commit above already exists; this never retries or bypasses
# anything, it only reports.
# ---------------------------------------------------------------------------
SIGN_STATUS=$(git log -1 --format='%G?' HEAD)
case "$SIGN_STATUS" in
	G|U) : ;;
	*)
		error "commit $COMMIT_SHA was created but FAILED signature verification (status: $SIGN_STATUS) — it was NOT retried unsigned; inspect/undo it before proceeding"
		exit 1
		;;
esac

exit 0
