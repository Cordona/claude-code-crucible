#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-git-ops script suite (preflight.sh,
#                create-branch.sh, commit.sh, push.sh, create-tag.sh).
#
# WHY a hand-rolled harness (not bats): the whole point of this suite is
# "runs on any machine with no dependencies". Requiring bats-core would
# contradict that. This harness needs only a POSIX sh plus the coreutils
# that already ship on macOS (BSD) and Linux (GNU). Mirrors the
# procedure-gh-issues/procedure-gh-pr test harnesses exactly (same stub
# shape, same assertion helpers).
#
# WHAT THIS LAYER DOES vs. DOES NOT PROVE: every `git` call here is a STUB —
# nothing in this file touches a real repository, a real remote, or real
# GPG/SSH signing. That is deliberate: it lets the DETERMINISTIC BRANCHING
# LOGIC (protected-branch refusal, non-ff detection, re-tag refusal,
# fail-closed signing checks, idempotency, argument validation, exit codes)
# be exercised exhaustively and fast, without a mutating operation ever
# touching anything real. It CANNOT prove the real git/gpg CONTRACT this
# suite relies on (e.g. that `git tag -v`'s exit code really means what this
# suite assumes, or that git's non-fast-forward rejection text really looks
# like what the grep pattern expects) — that is what the SEPARATE
# tests/smoke.sh (real git + a local bare remote + an ephemeral GPG key) is
# for. Run both; they prove different things.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools
#     the scripts need (mktemp, grep, sed, awk, ...) PLUS a STUB `git` so no
#     test ever touches a real repo, key, or remote. The stub lives in its
#     OWN dir that tests opt into, so "git absent" is exercised for real (by
#     leaving that dir off PATH).
#   * The stub logs argv ONE TOKEN PER LINE (between ARGV_BEGIN/ARGV_END
#     markers), never space-joined — the same word-splitting-proof rationale
#     as the sibling suites.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR and is
#     cleaned up on exit.
#
# Usage:  sh run-tests.sh              # run all tests
#         VERBOSE=1 sh run-tests.sh
#         (also runs green under dash: dash run-tests.sh)
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
PREFLIGHT="$SCRIPTS_DIR/preflight.sh"
CREATEBRANCH="$SCRIPTS_DIR/create-branch.sh"
COMMIT="$SCRIPTS_DIR/commit.sh"
PUSH="$SCRIPTS_DIR/push.sh"
CREATETAG="$SCRIPTS_DIR/create-tag.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-ops-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"      # real tools (git is NEVER here)
GITDIR_STUB_TARGET="$WORK/fake-gitdir"   # a fake .git dir preflight.sh can inspect
GITBIN="$WORK/gitbin"        # git stub (only when a test opts in)
mkdir -p "$TOOLBOX" "$GITBIN" "$WORK/home" "$GITDIR_STUB_TARGET"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools we need. git is NEVER here.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh mktemp grep sed cat awk rm mkdir; do
	link_tool "$t"
done

# ---------------------------------------------------------------------------
# git stub — fully env-driven so tests script every deterministic branch.
# See each GITOP_STUB_* var's use at its call site below; the shape mirrors
# the real subcommands the scripts issue (documented in each script's own
# header). All boolean vars are "1"/"0" (or unset, treated as documented).
# ---------------------------------------------------------------------------
cat >"$GITBIN/git" <<'GIT_STUB'
#!/usr/bin/env sh
set -eu

log_argv() {
	# log_argv LOGFILE "$@" — logs each argv token on its OWN line between
	# ARGV_BEGIN/ARGV_END markers (never space-joined — see run-tests.sh).
	logtarget=$1
	shift
	[ -n "$logtarget" ] || return 0
	{
		printf 'ARGV_BEGIN\n'
		for a in "$@"; do
			printf '%s\n' "$a"
		done
		printf 'ARGV_END\n'
	} >>"$logtarget"
}

capture_file_after_flag() {
	# capture_file_after_flag LOGFILE FLAGNAME "$@" — finds the value
	# following FLAGNAME in argv and, if a log target is set, appends a
	# verbatim copy of that file's CONTENTS between markers.
	logtarget=$1
	flagname=$2
	shift 2
	[ -n "$logtarget" ] || return 0
	prev=""
	for a in "$@"; do
		if [ "$prev" = "$flagname" ]; then
			{
				printf 'MSG_FILE_CONTENTS_START\n'
				cat "$a"
				printf 'MSG_FILE_CONTENTS_END\n'
			} >>"$logtarget"
		fi
		prev=$a
	done
}

case "${1:-}" in
	rev-parse)
		shift
		case "${1:-}" in
			--is-inside-work-tree)
				if [ "${GITOP_STUB_WORKTREE:-1}" = "1" ]; then
					printf 'true\n'
					exit 0
				fi
				exit 1 ;;
			--absolute-git-dir)
				printf '%s\n' "${GITOP_STUB_GITDIR:-/nonexistent}"
				exit 0 ;;
			--abbrev-ref)
				shift
				if [ "${1:-}" = "--symbolic-full-name" ]; then
					if [ "${GITOP_STUB_HAS_UPSTREAM:-0}" = "1" ]; then
						printf '%s\n' "${GITOP_STUB_UPSTREAM_REF:-origin/x}"
						exit 0
					fi
					exit 1
				fi
				exit 0 ;;
			--verify)
				shift
				[ "${1:-}" != "--quiet" ] || shift
				ref=${1:-}
				case "$ref" in
					refs/tags/*)
						if [ "${GITOP_STUB_TAG_EXISTS:-0}" = "1" ]; then exit 0; fi
						exit 1 ;;
					*)
						if [ "${GITOP_STUB_REF_RESOLVES:-1}" = "1" ]; then exit 0; fi
						exit 1 ;;
				esac ;;
			HEAD)
				printf '%s\n' "${GITOP_STUB_COMMIT_SHA:-deadbeef}"
				exit 0 ;;
			*)
				printf '%s\n' "${GITOP_STUB_LOCAL_SHA:-cafebabe}"
				exit 0 ;;
		esac ;;
	symbolic-ref)
		if [ -n "${GITOP_STUB_BRANCH:-}" ]; then
			printf '%s\n' "$GITOP_STUB_BRANCH"
			exit 0
		fi
		exit 1 ;;
	status)
		printf '%s\n' "${GITOP_STUB_STATUS_PORCELAIN:-}"
		exit 0 ;;
	remote)
		printf '%s\n' "${GITOP_STUB_REMOTES:-}"
		exit 0 ;;
	show-ref)
		if [ "${GITOP_STUB_BRANCH_EXISTS:-0}" = "1" ]; then exit 0; fi
		exit 1 ;;
	branch)
		shift
		log_argv "${GITOP_STUB_BRANCH_LOG:-}" "$@"
		if [ "${GITOP_STUB_BRANCH_CREATE_RC:-0}" != "0" ]; then
			printf 'stub: forced branch create failure\n' >&2
			exit "${GITOP_STUB_BRANCH_CREATE_RC}"
		fi
		exit 0 ;;
	diff)
		# --cached --quiet: exit 1 means "there IS a staged diff" (git's real
		# semantics), which is why STAGED=1 (the default) maps to exit 1.
		if [ "${GITOP_STUB_STAGED:-1}" = "1" ]; then exit 1; fi
		exit 0 ;;
	commit)
		shift
		log_argv "${GITOP_STUB_COMMIT_LOG:-}" "$@"
		capture_file_after_flag "${GITOP_STUB_COMMIT_LOG:-}" "-F" "$@"
		if [ "${GITOP_STUB_COMMIT_RC:-0}" != "0" ]; then
			printf 'stub: forced commit failure\n' >&2
			exit "${GITOP_STUB_COMMIT_RC}"
		fi
		exit 0 ;;
	log)
		printf '%s\n' "${GITOP_STUB_SIGN_STATUS:-G}"
		exit 0 ;;
	ls-remote)
		shift
		log_argv "${GITOP_STUB_LSREMOTE_LOG:-}" "$@"
		if [ -n "${GITOP_STUB_REMOTE_SHA:-}" ]; then
			printf '%s\trefs/heads/x\n' "$GITOP_STUB_REMOTE_SHA"
		fi
		exit 0 ;;
	push)
		shift
		log_argv "${GITOP_STUB_PUSH_LOG:-}" "$@"
		if [ "${GITOP_STUB_PUSH_RC:-0}" != "0" ]; then
			printf '%s\n' "${GITOP_STUB_PUSH_STDERR:-stub: forced push failure}" >&2
			exit "${GITOP_STUB_PUSH_RC}"
		fi
		exit 0 ;;
	tag)
		shift
		case "${1:-}" in
			-s)
				shift
				log_argv "${GITOP_STUB_TAG_LOG:-}" -s "$@"
				capture_file_after_flag "${GITOP_STUB_TAG_LOG:-}" "-F" "$@"
				if [ "${GITOP_STUB_TAG_CREATE_RC:-0}" != "0" ]; then
					printf 'stub: forced tag create failure\n' >&2
					exit "${GITOP_STUB_TAG_CREATE_RC}"
				fi
				exit 0 ;;
			-v)
				if [ "${GITOP_STUB_TAG_VERIFY_RC:-0}" != "0" ]; then
					printf 'stub: forced tag verify failure\n' >&2
					exit "${GITOP_STUB_TAG_VERIFY_RC}"
				fi
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	*) exit 0 ;;
esac
GIT_STUB
chmod +x "$GITBIN/git"

# ---------------------------------------------------------------------------
# Runner primitives
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# run <with_git:0|1> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> under the isolated toolbox PATH (+ git stub only when
#   with_git=1), with an isolated HOME/TMPDIR. Leading VAR=VALUE arguments
#   are passed straight to `env`. Captures stdout, stderr, exit code.
run() {
	r_git=$1; shift
	r_path="$TOOLBOX"
	[ "$r_git" = "1" ] && r_path="$GITBIN:$TOOLBOX"
	set +e
	env -i \
		HOME="$WORK/home" \
		PATH="$r_path" \
		TMPDIR="$WORK" \
		"$@" >"$WORK/out" 2>"$WORK/err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$WORK/out"); CUR_ERR=$(cat "$WORK/err")
	rm -f "$WORK/out" "$WORK/err"
	if [ "${VERBOSE:-0}" = "1" ]; then
		printf '    rc=%s\n' "$CUR_RC"
		printf '%s\n' "$CUR_OUT" | sed 's/^/    out| /'
		printf '%s\n' "$CUR_ERR" | sed 's/^/    err| /'
	fi
}

pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; TESTS_FAIL=$((TESTS_FAIL + 1)); }

check() { TESTS_RUN=$((TESTS_RUN + 1)); if [ "$3" -eq 0 ]; then pass "$1"; else fail "$1" "$2"; fi; }

expect_rc() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq "$2" ]; then pass "$1"
	else fail "$1" "expected exit $2, got $CUR_RC; stderr: $CUR_ERR"; fi
}

stdout_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stdout missing: $2"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

file_missing() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ ! -f "$2" ]; then pass "$1"
	else fail "$1" "file unexpectedly exists: $2"; fi
}

# argv_has_pair LOGFILE FLAG VALUE — true iff FLAG appears immediately
# followed by VALUE as two CONSECUTIVE lines inside the log's token-per-line
# ARGV_BEGIN/ARGV_END block.
argv_has_pair() {
	awk -v flag="$2" -v value="$3" '
		$0 == flag { want = 1; next }
		want == 1 { if ($0 == value) { found = 1 }; want = 0 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

section() { printf '\n== %s ==\n' "$1"; }

# ===========================================================================
# preflight.sh
# ===========================================================================
section "preflight.sh — usage / argument errors"
run 1 sh "$PREFLIGHT" -h
expect_rc "preflight(usage): -h -> exit 0" 0
stdout_has "preflight(usage): help text" "Usage:"

run 1 sh "$PREFLIGHT"
expect_rc "preflight(missing --repo): -> exit 2" 2
stderr_has "preflight(missing --repo): diagnostic" "--repo is required"

run 1 sh "$PREFLIGHT" --bogus
expect_rc "preflight(unknown option): -> exit 2" 2

run 0 sh "$PREFLIGHT" --repo "$WORK"
expect_rc "preflight(no-git): -> exit 1" 1
stderr_has "preflight(no-git): diagnostic" "git is not installed"

section "preflight.sh — not a work tree"
run 1 "GITOP_STUB_WORKTREE=0" sh "$PREFLIGHT" --repo "$WORK"
expect_rc "preflight(not-worktree): -> exit 1" 1
stderr_has "preflight(not-worktree): diagnostic" "not a git work tree"

section "preflight.sh — clean, on a branch, ready"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" \
	"GITOP_STUB_STATUS_PORCELAIN=" sh "$PREFLIGHT" --repo "$WORK"
expect_rc "preflight(ready): -> exit 0" 0
stdout_has "preflight(ready): GITOP_CLEAN=true" "GITOP_CLEAN=true"
stdout_has "preflight(ready): GITOP_BRANCH=main" "GITOP_BRANCH=main"
stdout_has "preflight(ready): GITOP_DETACHED=false" "GITOP_DETACHED=false"
stdout_has "preflight(ready): GITOP_OP_IN_PROGRESS=none" "GITOP_OP_IN_PROGRESS=none"
stdout_has "preflight(ready): GITOP_DIRTY_FILES=0" "GITOP_DIRTY_FILES=0"

section "preflight.sh — detached HEAD blocks readiness"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" \
	sh "$PREFLIGHT" --repo "$WORK"
expect_rc "preflight(detached): -> exit 1" 1
stdout_has "preflight(detached): GITOP_DETACHED=true" "GITOP_DETACHED=true"
stderr_has "preflight(detached): diagnostic" "HEAD is detached"

section "preflight.sh — dirty files reported but NOT itself a readiness failure"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" \
	"GITOP_STUB_STATUS_PORCELAIN= M file1.txt
?? file2.txt" sh "$PREFLIGHT" --repo "$WORK"
expect_rc "preflight(dirty-not-blocking): -> exit 0 (dirty files alone never block readiness)" 0
stdout_has "preflight(dirty-not-blocking): GITOP_CLEAN=false" "GITOP_CLEAN=false"
stdout_has "preflight(dirty-not-blocking): GITOP_DIRTY_FILES=2" "GITOP_DIRTY_FILES=2"

section "preflight.sh — operation in progress (rebase marker) blocks readiness"
mkdir -p "$GITDIR_STUB_TARGET/rebase-merge"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" \
	sh "$PREFLIGHT" --repo "$WORK"
expect_rc "preflight(rebase-in-progress): -> exit 1" 1
stdout_has "preflight(rebase-in-progress): GITOP_OP_IN_PROGRESS=rebase" "GITOP_OP_IN_PROGRESS=rebase"
stderr_has "preflight(rebase-in-progress): diagnostic" "already in progress: rebase"
rm -rf "$GITDIR_STUB_TARGET/rebase-merge"

section "preflight.sh — --expect-branch mismatch blocks readiness"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" \
	sh "$PREFLIGHT" --repo "$WORK" --expect-branch develop
expect_rc "preflight(expect-branch-mismatch): -> exit 1" 1
stderr_has "preflight(expect-branch-mismatch): diagnostic" "expected branch 'develop'"

section "preflight.sh — --expect-remote not configured blocks readiness"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" \
	"GITOP_STUB_REMOTES=upstream" sh "$PREFLIGHT" --repo "$WORK" --expect-remote origin
expect_rc "preflight(expect-remote-missing): -> exit 1" 1
stderr_has "preflight(expect-remote-missing): diagnostic" "expected remote 'origin' is not configured"

# ===========================================================================
# create-branch.sh
# ===========================================================================
section "create-branch.sh — usage / argument errors"
run 1 sh "$CREATEBRANCH" -h
expect_rc "createbranch(usage): -h -> exit 0" 0

run 1 sh "$CREATEBRANCH" --repo "$WORK" --ticket 1 --desc x --base main
expect_rc "createbranch(missing --type): -> exit 2" 2

run 1 sh "$CREATEBRANCH" --repo "$WORK" --type bogus --ticket 1 --desc x --base main
expect_rc "createbranch(invalid --type): -> exit 2" 2
stderr_has "createbranch(invalid --type): diagnostic" "must be one of"

run 1 sh "$CREATEBRANCH" --repo "$WORK" --type feat --ticket '#1' --desc x --base main
expect_rc "createbranch(ticket has #): -> exit 2" 2
stderr_has "createbranch(ticket has #): diagnostic" "must not contain '#'"

run 1 sh "$CREATEBRANCH" --repo "$WORK" --type feat --ticket 1 --desc TokenRefresh --base main
expect_rc "createbranch(uppercase desc): -> exit 2" 2
stderr_has "createbranch(uppercase desc): diagnostic" "naming convention"

run 0 sh "$CREATEBRANCH" --repo "$WORK" --type feat --ticket 1 --desc x --base main
expect_rc "createbranch(no-git): -> exit 1" 1

section "create-branch.sh — creates a new branch"
BRANCH_LOG1="$WORK/branch-log1"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH_EXISTS=0" "GITOP_STUB_REF_RESOLVES=1" "GITOP_STUB_BRANCH_LOG=$BRANCH_LOG1" \
	sh "$CREATEBRANCH" --repo "$WORK" --type feat --ticket 1 --desc token-refresh --base main
expect_rc "createbranch(new): -> exit 0" 0
stdout_has "createbranch(new): GITOP_BRANCH" "GITOP_BRANCH=feat/1-token-refresh"
check "createbranch(new): git branch NAME BASE reached argv" "branch name/base missing from argv" \
	"$( grep -Fxq -- 'feat/1-token-refresh' "$BRANCH_LOG1" && grep -Fxq -- 'main' "$BRANCH_LOG1" && echo 0 || echo 1 )"

section "create-branch.sh — idempotent: already exists, no create attempted"
BRANCH_LOG2="$WORK/branch-log2"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH_EXISTS=1" "GITOP_STUB_BRANCH_LOG=$BRANCH_LOG2" \
	sh "$CREATEBRANCH" --repo "$WORK" --type feat --ticket 1 --desc token-refresh --base main
expect_rc "createbranch(idempotent): -> exit 0" 0
stdout_has "createbranch(idempotent): GITOP_BRANCH" "GITOP_BRANCH=feat/1-token-refresh"
file_missing "createbranch(idempotent): git branch never invoked" "$BRANCH_LOG2"

section "create-branch.sh — --base does not resolve"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH_EXISTS=0" "GITOP_STUB_REF_RESOLVES=0" \
	sh "$CREATEBRANCH" --repo "$WORK" --type feat --ticket 1 --desc x --base nonexistent
expect_rc "createbranch(bad-base): -> exit 1" 1
stderr_has "createbranch(bad-base): diagnostic" "does not resolve to a valid ref"

section "create-branch.sh — git branch itself fails"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH_EXISTS=0" "GITOP_STUB_REF_RESOLVES=1" "GITOP_STUB_BRANCH_CREATE_RC=1" \
	sh "$CREATEBRANCH" --repo "$WORK" --type feat --ticket 1 --desc x --base main
expect_rc "createbranch(gh-fail): -> exit 1" 1
stderr_has "createbranch(gh-fail): reports failure" "git branch failed"

# ===========================================================================
# commit.sh
# ===========================================================================
section "commit.sh — usage / argument errors"
run 1 sh "$COMMIT" -h
expect_rc "commit(usage): -h -> exit 0" 0

MSGFILE="$WORK/commit-msg.txt"
printf 'feat: add thing\n\nBody here.\n' >"$MSGFILE"

run 1 sh "$COMMIT" --message-file "$MSGFILE"
expect_rc "commit(missing --repo): -> exit 2" 2

run 1 sh "$COMMIT" --repo "$WORK"
expect_rc "commit(missing --message-file): -> exit 2" 2

run 1 sh "$COMMIT" --repo "$WORK" --message-file "$WORK/does-not-exist"
expect_rc "commit(nonexistent message-file): -> exit 2" 2

run 0 sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(no-git): -> exit 1" 1

section "commit.sh — refuses a detached HEAD"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=" sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(detached): -> exit 1" 1
stderr_has "commit(detached): diagnostic" "HEAD is detached"

section "commit.sh — refuses when an operation is already in progress"
mkdir -p "$GITDIR_STUB_TARGET/rebase-merge"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" \
	sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(op-in-progress): -> exit 1" 1
stderr_has "commit(op-in-progress): diagnostic" "already in progress"
rm -rf "$GITDIR_STUB_TARGET/rebase-merge"

section "commit.sh — nothing staged fails"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" "GITOP_STUB_STAGED=0" \
	sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(nothing-staged): -> exit 1" 1
stderr_has "commit(nothing-staged): diagnostic" "nothing is staged"

section "commit.sh — git commit itself fails (hook or signing rejection)"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" "GITOP_STUB_STAGED=1" \
	"GITOP_STUB_COMMIT_RC=1" sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(commit-fail): -> exit 1" 1
stderr_has "commit(commit-fail): diagnostic" "git commit failed"

section "commit.sh — committed but signature verification fails (fail-closed)"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" "GITOP_STUB_STAGED=1" \
	"GITOP_STUB_COMMIT_SHA=abc123" "GITOP_STUB_SIGN_STATUS=N" sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(unsigned): -> exit 1 (fail-closed)" 1
stdout_has "commit(unsigned): SHA still reported despite failure" "GITOP_COMMIT_SHA=abc123"
stderr_has "commit(unsigned): diagnostic names the bad status" "status: N"
stderr_has "commit(unsigned): explicitly states it was not retried unsigned" "NOT retried unsigned"

section "commit.sh — signature status B (bad) also fails closed"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" "GITOP_STUB_STAGED=1" \
	"GITOP_STUB_SIGN_STATUS=B" sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(bad-sig): -> exit 1" 1

section "commit.sh — success: status G (good)"
COMMIT_LOG1="$WORK/commit-log1"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" "GITOP_STUB_STAGED=1" \
	"GITOP_STUB_COMMIT_SHA=deadbeef42" "GITOP_STUB_SIGN_STATUS=G" "GITOP_STUB_COMMIT_LOG=$COMMIT_LOG1" \
	sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(success-good): -> exit 0" 0
stdout_has "commit(success-good): GITOP_COMMIT_SHA" "GITOP_COMMIT_SHA=deadbeef42"
check "commit(success-good): argv uses -S --signoff (never --no-gpg-sign, never --no-verify)" "expected -S/--signoff in argv, and no --no-gpg-sign/--no-verify" \
	"$( grep -Fxq -- '-S' "$COMMIT_LOG1" && grep -Fxq -- '--signoff' "$COMMIT_LOG1" \
	    && ! grep -Fxq -- '--no-gpg-sign' "$COMMIT_LOG1" && ! grep -Fxq -- '--no-verify' "$COMMIT_LOG1" && echo 0 || echo 1 )"
check "commit(success-good): -F is immediately followed by the message-file PATH" "expected -F directly followed by \$MSGFILE in argv" \
	"$( argv_has_pair "$COMMIT_LOG1" '-F' "$MSGFILE" && echo 0 || echo 1 )"
check "commit(success-good): message-file contents relayed verbatim" "message content missing" \
	"$( sed -n '/^MSG_FILE_CONTENTS_START$/,/^MSG_FILE_CONTENTS_END$/p' "$COMMIT_LOG1" | grep -Fq -- 'feat: add thing' && echo 0 || echo 1 )"

section "commit.sh — success: status U (good, unknown validity) also passes"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" "GITOP_STUB_STAGED=1" \
	"GITOP_STUB_SIGN_STATUS=U" sh "$COMMIT" --repo "$WORK" --message-file "$MSGFILE"
expect_rc "commit(success-unknown-validity): -> exit 0" 0

section "commit.sh — adversarial message-file content reaches git verbatim and inert"
ADVERSARIAL="$WORK/commit-adversarial.txt"
cat >"$ADVERSARIAL" <<'BODY_EOF'
feat: add export

PM_ARTIFACT_BODY
EOF
this line runs $(whoami) and `id` if the message were ever evaluated as shell
Signed-off-by: Test User <test@example.com>
BODY_EOF
COMMIT_LOG2="$WORK/commit-log2"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_BRANCH=main" "GITOP_STUB_GITDIR=$GITDIR_STUB_TARGET" "GITOP_STUB_STAGED=1" \
	"GITOP_STUB_SIGN_STATUS=G" "GITOP_STUB_COMMIT_LOG=$COMMIT_LOG2" sh "$COMMIT" --repo "$WORK" --message-file "$ADVERSARIAL"
expect_rc "commit(adversarial): -> exit 0" 0
check "commit(adversarial): message reached git BYTE-IDENTICAL to the source fixture" "adversarial message content diverged" \
	"$( sed -n '/^MSG_FILE_CONTENTS_START$/,/^MSG_FILE_CONTENTS_END$/p' "$COMMIT_LOG2" | sed '1d;$d' >"$WORK/adv_actual"; diff -q "$ADVERSARIAL" "$WORK/adv_actual" >/dev/null 2>&1 && echo 0 || echo 1 )"

# ===========================================================================
# push.sh
# ===========================================================================
section "push.sh — usage / argument errors"
run 1 sh "$PUSH" -h
expect_rc "push(usage): -h -> exit 0" 0

run 1 sh "$PUSH" --repo "$WORK" --branch feat/x
expect_rc "push(missing --remote): -> exit 2" 2

run 1 sh "$PUSH" --repo "$WORK" --remote origin
expect_rc "push(missing --branch): -> exit 2" 2

run 1 sh "$PUSH" --repo "$WORK" --remote -- --branch feat/x
expect_rc "push(leading-dash --remote): -> exit 2" 2
stderr_has "push(leading-dash --remote): diagnostic" "--remote must not start with '-'"

run 1 sh "$PUSH" --repo "$WORK" --remote origin --branch --force
expect_rc "push(leading-dash --branch): -> exit 2" 2
stderr_has "push(leading-dash --branch): diagnostic" "--branch must not start with '-'"

section "push.sh — refuses protected branches (main/master/develop/release/*)"
for b in main master develop release/1.0; do
	run 1 sh "$PUSH" --repo "$WORK" --remote origin --branch "$b"
	expect_rc "push(protected:$b): -> exit 1" 1
	stderr_has "push(protected:$b): diagnostic" "refusing to push directly to protected branch"
done

run 1 sh "$PUSH" --repo "$WORK" --remote origin --branch main --force-with-lease
expect_rc "push(protected-force): --force-with-lease does NOT bypass protection -> exit 1" 1

run 0 sh "$PUSH" --repo "$WORK" --remote origin --branch feat/x
expect_rc "push(no-git): -> exit 1" 1

section "push.sh — first push (no upstream)"
PUSH_LOG1="$WORK/push-log1"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_HAS_UPSTREAM=0" "GITOP_STUB_PUSH_LOG=$PUSH_LOG1" \
	sh "$PUSH" --repo "$WORK" --remote origin --branch feat/x
expect_rc "push(first-push): -> exit 0" 0
stdout_has "push(first-push): GITOP_PUSHED=true" "GITOP_PUSHED=true"
stdout_has "push(first-push): GITOP_UPSTREAM" "GITOP_UPSTREAM=origin/feat/x"
check "push(first-push): -u flag present" "expected -u in argv for a first push" \
	"$( grep -Fxq -- '-u' "$PUSH_LOG1" && echo 0 || echo 1 )"
check "push(first-push): a literal -- precedes the remote/branch positionals" "expected -- immediately before 'origin' immediately before 'feat/x' in argv" \
	"$( argv_has_pair "$PUSH_LOG1" '--' 'origin' && argv_has_pair "$PUSH_LOG1" 'origin' 'feat/x' && echo 0 || echo 1 )"

section "push.sh — subsequent push (upstream exists, remote sha differs)"
PUSH_LOG2="$WORK/push-log2"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_HAS_UPSTREAM=1" "GITOP_STUB_LOCAL_SHA=newsha" "GITOP_STUB_REMOTE_SHA=oldsha" \
	"GITOP_STUB_PUSH_LOG=$PUSH_LOG2" sh "$PUSH" --repo "$WORK" --remote origin --branch feat/x
expect_rc "push(subsequent): -> exit 0" 0
stdout_has "push(subsequent): GITOP_PUSHED=true" "GITOP_PUSHED=true"
check "push(subsequent): no -u flag (upstream already exists)" "unexpected -u in argv" \
	"$( grep -Fxq -- '-u' "$PUSH_LOG2" && echo 1 || echo 0 )"

section "push.sh — idempotent: already up to date, no-op, push never invoked"
PUSH_LOG3="$WORK/push-log3"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_HAS_UPSTREAM=1" "GITOP_STUB_LOCAL_SHA=samesha" "GITOP_STUB_REMOTE_SHA=samesha" \
	"GITOP_STUB_PUSH_LOG=$PUSH_LOG3" sh "$PUSH" --repo "$WORK" --remote origin --branch feat/x
expect_rc "push(idempotent): -> exit 0" 0
stdout_has "push(idempotent): GITOP_PUSHED=false" "GITOP_PUSHED=false"
file_missing "push(idempotent): git push never invoked" "$PUSH_LOG3"

section "push.sh — --force-with-lease on a non-protected branch reaches argv"
PUSH_LOG4="$WORK/push-log4"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_HAS_UPSTREAM=1" "GITOP_STUB_LOCAL_SHA=a" "GITOP_STUB_REMOTE_SHA=b" \
	"GITOP_STUB_PUSH_LOG=$PUSH_LOG4" sh "$PUSH" --repo "$WORK" --remote origin --branch feat/x --force-with-lease
expect_rc "push(force-with-lease): -> exit 0" 0
check "push(force-with-lease): --force-with-lease reached argv" "expected --force-with-lease in argv" \
	"$( grep -Fxq -- '--force-with-lease' "$PUSH_LOG4" && echo 0 || echo 1 )"

section "push.sh — non-fast-forward rejection is DETECTED and reported specifically"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_HAS_UPSTREAM=1" "GITOP_STUB_LOCAL_SHA=a" "GITOP_STUB_REMOTE_SHA=b" \
	"GITOP_STUB_PUSH_RC=1" "GITOP_STUB_PUSH_STDERR=! [rejected] feat/x -> feat/x (non-fast-forward)" \
	sh "$PUSH" --repo "$WORK" --remote origin --branch feat/x
expect_rc "push(non-ff): -> exit 1" 1
stderr_has "push(non-ff): specific diagnosis" "non-fast-forward — rebase onto base then retry"

section "push.sh — a non-non-ff push failure is reported generically (not misdiagnosed as non-ff)"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_HAS_UPSTREAM=1" "GITOP_STUB_LOCAL_SHA=a" "GITOP_STUB_REMOTE_SHA=b" \
	"GITOP_STUB_PUSH_RC=1" "GITOP_STUB_PUSH_STDERR=remote: permission denied" \
	sh "$PUSH" --repo "$WORK" --remote origin --branch feat/x
expect_rc "push(other-fail): -> exit 1" 1
stderr_has "push(other-fail): generic diagnosis" "git push failed"
check "push(other-fail): does NOT claim non-fast-forward" "a non-permission failure was misdiagnosed as non-ff" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'non-fast-forward — rebase' && echo 1 || echo 0 )"

# ===========================================================================
# create-tag.sh
# ===========================================================================
section "create-tag.sh — usage / argument errors"
run 1 sh "$CREATETAG" -h
expect_rc "createtag(usage): -h -> exit 0" 0

TAGMSGFILE="$WORK/tag-msg.txt"
printf 'Release v1.0.0\n' >"$TAGMSGFILE"

run 1 sh "$CREATETAG" --repo "$WORK" --sha abc --message-file "$TAGMSGFILE"
expect_rc "createtag(missing --version): -> exit 2" 2

run 1 sh "$CREATETAG" --repo "$WORK" --version "1.0" --sha abc --message-file "$TAGMSGFILE"
expect_rc "createtag(non-semver, too short): -> exit 2" 2
stderr_has "createtag(non-semver, too short): diagnostic" "must be SemVer"

run 1 sh "$CREATETAG" --repo "$WORK" --version "v1.a.0" --sha abc --message-file "$TAGMSGFILE"
expect_rc "createtag(non-semver, non-digit): -> exit 2" 2

run 1 sh "$CREATETAG" --repo "$WORK" --version "v1.0.0.0" --sha abc --message-file "$TAGMSGFILE"
expect_rc "createtag(non-semver, 4 components): -> exit 2" 2
stderr_has "createtag(non-semver, 4 components): diagnostic" "must be SemVer"

run 1 sh "$CREATETAG" --repo "$WORK" --version "v1.0.0-rc1" --sha abc --message-file "$TAGMSGFILE"
expect_rc "createtag(non-semver, prerelease suffix out of scope): -> exit 2" 2
stderr_has "createtag(non-semver, prerelease suffix out of scope): diagnostic" "must be SemVer"

run 1 sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha abc --message-file "$WORK/does-not-exist"
expect_rc "createtag(nonexistent message-file): -> exit 2" 2

run 0 sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha abc --message-file "$TAGMSGFILE"
expect_rc "createtag(no-git): -> exit 1" 1

section "create-tag.sh — accepts both vX.Y.Z and X.Y.Z"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_TAG_EXISTS=0" "GITOP_STUB_REF_RESOLVES=1" "GITOP_STUB_TAG_VERIFY_RC=0" \
	sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha abc123 --message-file "$TAGMSGFILE"
expect_rc "createtag(v-prefixed): -> exit 0" 0
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_TAG_EXISTS=0" "GITOP_STUB_REF_RESOLVES=1" "GITOP_STUB_TAG_VERIFY_RC=0" \
	sh "$CREATETAG" --repo "$WORK" --version "1.0.0" --sha abc123 --message-file "$TAGMSGFILE"
expect_rc "createtag(no-v-prefix): -> exit 0" 0

section "create-tag.sh — refuses to re-tag/move an existing tag"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_TAG_EXISTS=1" \
	sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha abc123 --message-file "$TAGMSGFILE"
expect_rc "createtag(re-tag): -> exit 1" 1
stderr_has "createtag(re-tag): diagnostic" "already exists — refusing to re-tag/move"

section "create-tag.sh — --sha does not resolve"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_TAG_EXISTS=0" "GITOP_STUB_REF_RESOLVES=0" \
	sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha bogus --message-file "$TAGMSGFILE"
expect_rc "createtag(bad-sha): -> exit 1" 1
stderr_has "createtag(bad-sha): diagnostic" "does not resolve to a commit"

section "create-tag.sh — git tag -s itself fails"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_TAG_EXISTS=0" "GITOP_STUB_REF_RESOLVES=1" "GITOP_STUB_TAG_CREATE_RC=1" \
	sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha abc123 --message-file "$TAGMSGFILE"
expect_rc "createtag(create-fail): -> exit 1" 1
stderr_has "createtag(create-fail): diagnostic" "git tag failed"

section "create-tag.sh — created but verification fails (fail-closed, not deleted automatically)"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_TAG_EXISTS=0" "GITOP_STUB_REF_RESOLVES=1" "GITOP_STUB_TAG_VERIFY_RC=1" \
	sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha abc123 --message-file "$TAGMSGFILE"
expect_rc "createtag(verify-fail): -> exit 1" 1
stderr_has "createtag(verify-fail): diagnostic" "FAILED verification"
stderr_has "createtag(verify-fail): explicitly states it was not auto-deleted" "NOT deleted automatically"

section "create-tag.sh — success: created and verified"
TAG_LOG1="$WORK/tag-log1"
run 1 "GITOP_STUB_WORKTREE=1" "GITOP_STUB_TAG_EXISTS=0" "GITOP_STUB_REF_RESOLVES=1" "GITOP_STUB_TAG_VERIFY_RC=0" \
	"GITOP_STUB_TAG_LOG=$TAG_LOG1" sh "$CREATETAG" --repo "$WORK" --version "v1.0.0" --sha abc123 --message-file "$TAGMSGFILE"
expect_rc "createtag(success): -> exit 0" 0
stdout_has "createtag(success): GITOP_TAG" "GITOP_TAG=v1.0.0"
check "createtag(success): -s is immediately followed by VERSION" "expected -s directly followed by v1.0.0 in argv" \
	"$( argv_has_pair "$TAG_LOG1" '-s' 'v1.0.0' && echo 0 || echo 1 )"
check "createtag(success): -F is immediately followed by the message-file PATH" "expected -F directly followed by \$TAGMSGFILE in argv" \
	"$( argv_has_pair "$TAG_LOG1" '-F' "$TAGMSGFILE" && echo 0 || echo 1 )"
check "createtag(success): SHA reached argv" "expected abc123 in argv" \
	"$( grep -Fxq -- 'abc123' "$TAG_LOG1" && echo 0 || echo 1 )"
check "createtag(success): message-file contents relayed verbatim" "message content missing" \
	"$( sed -n '/^MSG_FILE_CONTENTS_START$/,/^MSG_FILE_CONTENTS_END$/p' "$TAG_LOG1" | grep -Fq -- 'Release v1.0.0' && echo 0 || echo 1 )"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
