#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-gh-pr script suite (find-pr.sh, create-pr.sh,
#                update-pr.sh).
#
# WHY a hand-rolled harness (not bats): the whole point of this suite is
# "runs on any machine with no dependencies". Requiring bats-core would
# contradict that. This harness needs only a POSIX sh plus the coreutils
# that already ship on macOS (BSD) and Linux (GNU). Mirrors the sibling
# procedure-gh-issues test harness exactly (same stub shape, same
# assertion helpers) — see that skill's tests/run-tests.sh for the
# original design notes.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools
#     the scripts need (mktemp, grep, sed, awk, ...) PLUS a STUB `gh` so no
#     test ever touches a real repo, a real account, or the network. The gh
#     stub lives in its OWN dir that tests opt into, so "gh absent" is
#     exercised for real (by leaving that dir off PATH).
#   * The gh stub is fully env-driven: tests set GH_STUB_* variables to
#     script `gh auth status`, `pr list`/`create`/`edit`, and their return
#     codes — so every deterministic branch is covered without a real `gh`.
#   * The stub logs argv ONE TOKEN PER LINE (between ARGV_BEGIN/ARGV_END
#     markers), never space-joined — a joined "--title a b" string cannot be
#     told apart from three separate tokens (a word-splitting regression),
#     but a token-per-line log can, and that distinction is exactly what
#     several assertions below rely on.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR and is
#     cleaned up on exit.
#
# STUB-ONLY CAVEAT (read this if a real `gh` release ever changes behavior):
#   These tests are entirely stub-driven — no real `gh` runs here, ever. The
#   `gh pr` flag spellings this suite relies on (create: --head/--base/
#   --title/--body-file/--draft/--reviewer/--label/--assignee; edit: <N> +
#   --title/--body-file/--base/--add-label/--remove-label/--add-reviewer/
#   --remove-reviewer; list: --head/--base/--state/--json), the
#   `--json number,url --jq '.[] | "\(.number)\t\(.url)"'` output shape, and
#   `--head`'s PLAIN-branch-only semantics (no `owner:branch` fork syntax)
#   were all verified against a real `gh pr --help` at BUILD time, not by
#   this harness — the stub simply echoes back whatever the scripts pass it,
#   so it cannot detect a real `gh` release drifting from that contract (this
#   is exactly the class of bug that shipped once already: the `close-issue
#   --reason` enum drifting from what `gh` actually accepts). Catching a
#   real-`gh` contract drift needs an occasional real-`gh` smoke check
#   against a scratch repo — deliberately out of scope for this harness,
#   which exists to run anywhere with zero dependencies (see above).
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
FINDPR="$SCRIPTS_DIR/find-pr.sh"
CREATEPR="$SCRIPTS_DIR/create-pr.sh"
UPDATEPR="$SCRIPTS_DIR/update-pr.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"      # real tools (gh is NEVER here)
GHDIR="$WORK/ghbin"          # gh stub (only when a test opts in)
mkdir -p "$TOOLBOX" "$GHDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools we need. gh is NEVER here.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh mktemp grep sed cat diff awk rm; do
	link_tool "$t"
done

# ---------------------------------------------------------------------------
# gh stub — fully env-driven so tests script every deterministic branch.
#   GH_STUB_AUTHED=1           -> `gh auth status` succeeds
#   GH_STUB_PR_LIST_RC=n       -> exit code for `gh pr list` (find-pr.sh AND
#                                 create-pr.sh's own duplicate pre-check both
#                                 call this identical subcommand shape)
#   GH_STUB_PR_LIST=<nl-list>  -> `gh pr list --json number,url --jq...`
#                                 result, lines of "number<TAB>url"
#   GH_STUB_PR_LIST_LOG=path   -> capture `gh pr list` argv (token-per-line)
#   GH_STUB_CREATE_RC=n        -> exit code for `gh pr create`
#   GH_STUB_CREATE_URL=url     -> stdout for a successful `gh pr create`
#                                 (set-but-EMPTY is honored as empty output —
#                                 distinct from leaving it unset)
#   GH_STUB_CREATE_LOG=path    -> capture argv (token-per-line) + the
#                                 --body-file CONTENTS
#   GH_STUB_EDIT_RC=n          -> exit code for `gh pr edit`
#   GH_STUB_EDIT_URL=url       -> stdout for a successful `gh pr edit`
#                                 (${VAR-default} semantics, same as CREATE_URL)
#   GH_STUB_EDIT_LOG=path      -> capture argv (token-per-line) + the
#                                 --body-file CONTENTS (only one log needed
#                                 here — unlike procedure-gh-issues, no OTHER
#                                 script in this suite also calls `gh pr edit`)
# ---------------------------------------------------------------------------
cat >"$GHDIR/gh" <<'GH_STUB'
#!/usr/bin/env sh
set -eu

log_argv() {
	# log_argv LOGFILE "$@" — logs each argv token on its OWN line between
	# ARGV_BEGIN/ARGV_END markers. One-token-per-line (not a space-joined
	# string) so a caller can prove a value arrived as ONE argv token
	# (e.g. right after a flag) rather than being word-split into several.
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

capture_body_file() {
	# capture_body_file LOGFILE "$@" — scans argv for the value following
	# --body-file and, if a log target is set, appends a verbatim copy of
	# that file's CONTENTS between BODY_FILE_CONTENTS_START/END markers.
	logtarget=$1
	shift
	[ -n "$logtarget" ] || return 0
	prev=""
	for a in "$@"; do
		if [ "$prev" = "--body-file" ]; then
			{
				printf 'BODY_FILE_CONTENTS_START\n'
				cat "$a"
				printf 'BODY_FILE_CONTENTS_END\n'
			} >>"$logtarget"
		fi
		prev=$a
	done
}

case "${1:-}" in
	auth)
		case "${2:-}" in
			status)
				if [ "${GH_STUB_AUTHED:-0}" = "1" ]; then
					printf 'Logged in to github.com\n'
					exit 0
				else
					printf 'You are not logged into any GitHub hosts.\n' >&2
					exit 1
				fi ;;
			*) exit 0 ;;
		esac ;;
	pr)
		case "${2:-}" in
			list)
				shift 2
				log_argv "${GH_STUB_PR_LIST_LOG:-}" "$@"
				if [ "${GH_STUB_PR_LIST_RC:-0}" != "0" ]; then
					printf 'stub: forced pr list failure\n' >&2
					exit "${GH_STUB_PR_LIST_RC:-1}"
				fi
				printf '%s\n' "${GH_STUB_PR_LIST:-}"
				exit 0 ;;
			create)
				shift 2
				log_argv "${GH_STUB_CREATE_LOG:-}" "$@"
				capture_body_file "${GH_STUB_CREATE_LOG:-}" "$@"
				if [ "${GH_STUB_CREATE_RC:-0}" != "0" ]; then
					printf 'stub: forced create failure\n' >&2
					exit "${GH_STUB_CREATE_RC:-1}"
				fi
				# ${VAR-default}, NOT ${VAR:-default}: a test that sets
				# GH_STUB_CREATE_URL to the EMPTY string must see empty
				# output, distinct from leaving the var unset entirely.
				printf '%s\n' "${GH_STUB_CREATE_URL-https://github.com/octo/repo/pull/1}"
				exit 0 ;;
			edit)
				shift 2
				log_argv "${GH_STUB_EDIT_LOG:-}" "$@"
				capture_body_file "${GH_STUB_EDIT_LOG:-}" "$@"
				if [ "${GH_STUB_EDIT_RC:-0}" != "0" ]; then
					printf 'stub: forced edit failure\n' >&2
					exit "${GH_STUB_EDIT_RC:-1}"
				fi
				# ${VAR-default}, NOT ${VAR:-default} — see GH_STUB_CREATE_URL.
				printf '%s\n' "${GH_STUB_EDIT_URL-https://github.com/octo/repo/pull/1}"
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	*) exit 0 ;;
esac
GH_STUB
chmod +x "$GHDIR/gh"

# ---------------------------------------------------------------------------
# Runner primitives
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0

# run <with_gh:0|1> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> under the isolated toolbox PATH (+ gh stub only when
#   with_gh=1), with an isolated HOME/TMPDIR. Leading VAR=VALUE arguments are
#   passed straight to `env` (values may contain spaces or newlines).
#   Captures stdout, stderr, exit code.
run() {
	r_gh=$1; shift
	r_path="$TOOLBOX"
	[ "$r_gh" = "1" ] && r_path="$GHDIR:$TOOLBOX"
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

stdout_re() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Eq -- "$2"; then pass "$1"
	else fail "$1" "stdout not matching /$2/"; fi
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
# ARGV_BEGIN/ARGV_END block. Proves VALUE reached gh as ONE argv token right
# after FLAG — a word-splitting regression would show as extra lines instead.
argv_has_pair() {
	awk -v flag="$2" -v value="$3" '
		$0 == flag { want = 1; next }
		want == 1 { if ($0 == value) { found = 1 }; want = 0 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# body_block LOGFILE — prints only the lines between the stub's
# BODY_FILE_CONTENTS_START/END markers (exclusive), so an assertion can be
# scoped to what the SCRIPT wrote into the body file, never to the ARGV
# lines or anything else the stub logged.
body_block() {
	sed -n '/^BODY_FILE_CONTENTS_START$/,/^BODY_FILE_CONTENTS_END$/p' "$1" | sed '1d;$d'
}

# diff_body_block LOGFILE EXPECTEDFILE — strict byte-for-byte compare of what
# gh actually received (body_block of LOGFILE) against the original fixture
# file. The authoritative proof that a body reached gh completely unaltered:
# evaluation, truncation (a real heredoc stopping early), or reordering would
# all change the captured bytes. Writes the diff to $WORK/body_block_diff.
diff_body_block() {
	body_block "$1" >"$WORK/body_block_actual"
	diff -u "$2" "$WORK/body_block_actual" >"$WORK/body_block_diff" 2>&1
}

section() { printf '\n== %s ==\n' "$1"; }

# ===========================================================================
# find-pr.sh
# ===========================================================================
section "find-pr.sh — usage / argument errors"
run 1 sh "$FINDPR" -h
expect_rc "findpr(usage): -h -> exit 0" 0
stdout_has "findpr(usage): help text" "Usage:"

run 1 sh "$FINDPR" --head feat/x
expect_rc "findpr(missing --repo): -> exit 2" 2
stderr_has "findpr(missing --repo): diagnostic" "--repo is required"

run 1 sh "$FINDPR" --repo o/r
expect_rc "findpr(missing --head): -> exit 2" 2
stderr_has "findpr(missing --head): diagnostic" "--head is required"

run 1 sh "$FINDPR" --repo 'o/..' --head feat/x
expect_rc "findpr(malformed --repo): -> exit 2" 2
stderr_has "findpr(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$FINDPR" --bogus
expect_rc "findpr(unknown option): -> exit 2" 2
stderr_has "findpr(unknown option): diagnostic" "unknown option"

section "find-pr.sh — gh absent / not authenticated"
run 0 sh "$FINDPR" --repo o/r --head feat/x
expect_rc "findpr(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$FINDPR" --repo o/r --head feat/x
expect_rc "findpr(unauth): -> exit 1" 1

section "find-pr.sh — hit (exactly one open PR)"
LIST_LOG1="$WORK/pr-list-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=42	https://github.com/octo/repo/pull/42" "GH_STUB_PR_LIST_LOG=$LIST_LOG1" \
	sh "$FINDPR" --repo octo/repo --head feat/x
expect_rc "findpr(hit): -> exit 0" 0
stdout_has "findpr(hit): PM_PR_COUNT=1" "PM_PR_COUNT=1"
stdout_has "findpr(hit): PM_PR_NUMBER=42" "PM_PR_NUMBER=42"
stdout_has "findpr(hit): PM_PR_URL" "PM_PR_URL=https://github.com/octo/repo/pull/42"
check "findpr(hit): --repo passed as one token" "repo missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--repo' 'octo/repo' && echo 0 || echo 1 )"
check "findpr(hit): --head passed as one token" "head missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--head' 'feat/x' && echo 0 || echo 1 )"
check "findpr(hit): --state open passed as one token" "state missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--state' 'open' && echo 0 || echo 1 )"

section "find-pr.sh — miss (no open PR, count 0 is success)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=" sh "$FINDPR" --repo o/r --head feat/y
expect_rc "findpr(miss): -> exit 0 (zero is not a failure)" 0
stdout_has "findpr(miss): PM_PR_COUNT=0" "PM_PR_COUNT=0"
check "findpr(miss): no PM_PR_NUMBER line printed" "PM_PR_NUMBER was printed despite zero results" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_PR_NUMBER=' && echo 1 || echo 0 )"
check "findpr(miss): no PM_PR_URL line printed" "PM_PR_URL was printed despite zero results" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_PR_URL=' && echo 1 || echo 0 )"

section "find-pr.sh — ambiguous (2 open PRs): count reported, no number/URL fabricated"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=42	https://github.com/octo/repo/pull/42
43	https://github.com/octo/repo/pull/43" \
	sh "$FINDPR" --repo octo/repo --head feat/shared
expect_rc "findpr(count-2): -> exit 0 (still a clean query)" 0
stdout_has "findpr(count-2): PM_PR_COUNT=2" "PM_PR_COUNT=2"
check "findpr(count-2): no PM_PR_NUMBER line printed (only emitted when count==1)" "PM_PR_NUMBER was printed despite count=2" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_PR_NUMBER=' && echo 1 || echo 0 )"
check "findpr(count-2): no PM_PR_URL line printed (only emitted when count==1)" "PM_PR_URL was printed despite count=2" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fq -- 'PM_PR_URL=' && echo 1 || echo 0 )"

section "find-pr.sh — gh pr list itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST_RC=1" sh "$FINDPR" --repo o/r --head feat/x
expect_rc "findpr(gh-fail): -> exit 1" 1
stderr_has "findpr(gh-fail): reports failure" "gh pr list failed"

# ===========================================================================
# create-pr.sh
# ===========================================================================
section "create-pr.sh — usage / argument errors"
run 1 sh "$CREATEPR" -h
expect_rc "createpr(usage): -h -> exit 0" 0
stdout_has "createpr(usage): help text" "Usage:"

PRBODY="$WORK/pr-body.md"
printf '## Summary\nDoes the thing.\n' >"$PRBODY"

run 1 sh "$CREATEPR" --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(missing --repo): -> exit 2" 2
stderr_has "createpr(missing --repo): diagnostic" "--repo is required"

run 1 sh "$CREATEPR" --repo o/r --base main --title t --body-file "$PRBODY"
expect_rc "createpr(missing --head): -> exit 2" 2
stderr_has "createpr(missing --head): diagnostic" "--head is required"

run 1 sh "$CREATEPR" --repo o/r --head feat/x --title t --body-file "$PRBODY"
expect_rc "createpr(missing --base): -> exit 2" 2
stderr_has "createpr(missing --base): diagnostic" "--base is required"

run 1 sh "$CREATEPR" --repo o/r --head feat/x --base main --body-file "$PRBODY"
expect_rc "createpr(missing --title): -> exit 2" 2
stderr_has "createpr(missing --title): diagnostic" "--title is required"

run 1 sh "$CREATEPR" --repo o/r --head feat/x --base main --title t
expect_rc "createpr(missing --body-file): -> exit 2" 2
stderr_has "createpr(missing --body-file): diagnostic" "--body-file is required"

run 1 sh "$CREATEPR" --repo o/r --head feat/x --base main --title t --body-file "$WORK/does-not-exist"
expect_rc "createpr(nonexistent body-file): -> exit 2" 2
stderr_has "createpr(nonexistent body-file): diagnostic" "does not exist or is not readable"

run 1 sh "$CREATEPR" --repo 'o/..' --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(malformed --repo): -> exit 2" 2
stderr_has "createpr(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$CREATEPR" --bogus
expect_rc "createpr(unknown option): -> exit 2" 2
stderr_has "createpr(unknown option): diagnostic" "unknown option"

section "create-pr.sh — gh absent / not authenticated (fail-closed)"
run 0 sh "$CREATEPR" --repo o/r --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$CREATEPR" --repo o/r --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(unauth): -> exit 1" 1
stderr_has "createpr(unauth): diagnostic" "not authenticated"

section "create-pr.sh — duplicate-exists pre-check refuses to create (no create attempted)"
CREATE_LOG1="$WORK/pr-create-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=42	https://github.com/octo/repo/pull/42" "GH_STUB_CREATE_LOG=$CREATE_LOG1" \
	sh "$CREATEPR" --repo octo/repo --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(duplicate): -> exit 1" 1
stderr_has "createpr(duplicate): names the existing PR URL" "https://github.com/octo/repo/pull/42"
stderr_has "createpr(duplicate): points at update-pr.sh" "update-pr.sh"
file_missing "createpr(duplicate): gh pr create never invoked" "$CREATE_LOG1"

section "create-pr.sh — the duplicate pre-check query itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST_RC=1" sh "$CREATEPR" --repo o/r --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(precheck-fail): -> exit 1" 1
stderr_has "createpr(precheck-fail): reports failure" "failed to check for an existing PR"

section "create-pr.sh — successful create (draft, reviewers, labels, assignees)"
CREATE_LOG2="$WORK/pr-create-log2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=" "GH_STUB_CREATE_URL=https://github.com/octo/repo/pull/7" "GH_STUB_CREATE_LOG=$CREATE_LOG2" \
	sh "$CREATEPR" --repo octo/repo --head feat/x --base main --title "Add the export feature" \
		--body-file "$PRBODY" --draft --reviewer "alice,bob" --label "type:feature,needs-review" --assignee carol
expect_rc "createpr(success): -> exit 0" 0
stdout_has "createpr(success): PM_PR_NUMBER" "PM_PR_NUMBER=7"
stdout_has "createpr(success): PM_PR_URL" "PM_PR_URL=https://github.com/octo/repo/pull/7"
check "createpr(success): --head passed as one token" "head missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--head' 'feat/x' && echo 0 || echo 1 )"
check "createpr(success): --base passed as one token" "base missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--base' 'main' && echo 0 || echo 1 )"
check "createpr(success): --title passed as one token (even multi-word)" "title missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--title' 'Add the export feature' && echo 0 || echo 1 )"
check "createpr(success): --draft flag present" "no --draft token in argv" \
	"$( grep -Fxq -- '--draft' "$CREATE_LOG2" && echo 0 || echo 1 )"
check "createpr(success): --reviewer alice passed" "reviewer alice missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--reviewer' 'alice' && echo 0 || echo 1 )"
check "createpr(success): --reviewer bob passed" "reviewer bob missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--reviewer' 'bob' && echo 0 || echo 1 )"
check "createpr(success): --label type:feature (from a comma-list) passed" "label missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--label' 'type:feature' && echo 0 || echo 1 )"
check "createpr(success): --label needs-review (from the SAME comma-list) also passed" "second comma-split label missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--label' 'needs-review' && echo 0 || echo 1 )"
check "createpr(success): --assignee carol passed" "assignee missing from argv" \
	"$( argv_has_pair "$CREATE_LOG2" '--assignee' 'carol' && echo 0 || echo 1 )"
check "createpr(success): argv uses --body-file (the injection-safety mechanism)" "no --body-file token in argv" \
	"$( grep -Fxq -- '--body-file' "$CREATE_LOG2" && echo 0 || echo 1 )"
check "createpr(success): argv has NO bare --body token" "a bare --body flag was found in argv" \
	"$( grep -Fxq -- '--body' "$CREATE_LOG2" && echo 1 || echo 0 )"

section "create-pr.sh — non-draft create: --draft is ABSENT from argv (symmetry with no-body-clobber)"
CREATE_LOG4="$WORK/pr-create-log4"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=" "GH_STUB_CREATE_LOG=$CREATE_LOG4" \
	sh "$CREATEPR" --repo octo/repo --head feat/y --base main --title t --body-file "$PRBODY"
expect_rc "createpr(non-draft): -> exit 0" 0
check "createpr(non-draft): argv has NO --draft token (an always-draft regression would fail this)" "a --draft token was found even though --draft was never requested" \
	"$( grep -Fxq -- '--draft' "$CREATE_LOG4" && echo 1 || echo 0 )"

section "create-pr.sh — gh pr create itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=" "GH_STUB_CREATE_RC=1" \
	sh "$CREATEPR" --repo o/r --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(gh-fail): -> exit 1" 1
stderr_has "createpr(gh-fail): reports failure" "gh pr create failed"

section "create-pr.sh — gh pr create succeeds but returns NO URL"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=" "GH_STUB_CREATE_URL=" \
	sh "$CREATEPR" --repo o/r --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(no-url): -> exit 1" 1
stderr_has "createpr(no-url): diagnostic" "returned no URL"

section "create-pr.sh — gh pr create returns a URL with a non-numeric tail"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=" "GH_STUB_CREATE_URL=https://github.com/octo/repo/pull/not-a-number" \
	sh "$CREATEPR" --repo o/r --head feat/x --base main --title t --body-file "$PRBODY"
expect_rc "createpr(non-numeric-tail): -> exit 0 (create still succeeded)" 0
stdout_has "createpr(non-numeric-tail): PM_PR_URL still printed" "PM_PR_URL=https://github.com/octo/repo/pull/not-a-number"
stdout_re "createpr(non-numeric-tail): PM_PR_NUMBER empty (parse-warn, not a hard failure)" '^PM_PR_NUMBER=$'
stderr_has "createpr(non-numeric-tail): warns about the unparseable number" "could not parse a PR number"

section "create-pr.sh — adversarial body-file content reaches gh verbatim and inert"
ADVERSARIAL="$WORK/pr-adversarial-body.md"
cat >"$ADVERSARIAL" <<'BODY_EOF'
## Summary
Adds the CSV export.

PM_ARTIFACT_BODY
EOF
this line runs $(whoami) and `id` if the body were ever evaluated as shell
## Test plan
- [x] unit tests
BODY_EOF
CREATE_LOG3="$WORK/pr-create-log3"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_PR_LIST=" "GH_STUB_CREATE_URL=https://github.com/octo/repo/pull/99" "GH_STUB_CREATE_LOG=$CREATE_LOG3" \
	sh "$CREATEPR" --repo octo/repo --head feat/x --base main --title "adversarial body test" --body-file "$ADVERSARIAL"
expect_rc "createpr(adversarial): -> exit 0 (the file path carried it, not shell)" 0
stdout_has "createpr(adversarial): still succeeds normally" "PM_PR_URL=https://github.com/octo/repo/pull/99"
if diff_body_block "$CREATE_LOG3" "$ADVERSARIAL"; then BODY_DIFF_RC=0; else BODY_DIFF_RC=1; fi
check "createpr(adversarial): body-file contents reached gh BYTE-IDENTICAL to the source fixture" \
	"$(cat "$WORK/body_block_diff" 2>/dev/null)" \
	"$BODY_DIFF_RC"
check "createpr(adversarial): argv uses --body-file (the injection-safety mechanism)" "no --body-file token in argv" \
	"$( grep -Fxq -- '--body-file' "$CREATE_LOG3" && echo 0 || echo 1 )"
check "createpr(adversarial): argv has NO bare --body token" "a bare --body flag was found in argv" \
	"$( grep -Fxq -- '--body' "$CREATE_LOG3" && echo 1 || echo 0 )"

# ===========================================================================
# update-pr.sh
# ===========================================================================
section "update-pr.sh — usage / argument errors"
run 1 sh "$UPDATEPR" -h
expect_rc "updatepr(usage): -h -> exit 0" 0
stdout_has "updatepr(usage): help text" "Usage:"

run 1 sh "$UPDATEPR" --pr 1 --title x
expect_rc "updatepr(missing --repo): -> exit 2" 2

run 1 sh "$UPDATEPR" --repo o/r --title x
expect_rc "updatepr(missing --pr): -> exit 2" 2

run 1 sh "$UPDATEPR" --repo o/r --pr abc --title x
expect_rc "updatepr(non-numeric --pr): -> exit 2" 2

run 1 sh "$UPDATEPR" --repo o/r --pr 1
expect_rc "updatepr(no fields given): -> exit 2" 2
stderr_has "updatepr(no fields given): diagnostic" "at least one field to change is required"

run 1 sh "$UPDATEPR" --repo o/r --pr 1 --body-file "$WORK/does-not-exist"
expect_rc "updatepr(nonexistent body-file): -> exit 2" 2

run 1 sh "$UPDATEPR" --repo 'o/..' --pr 1 --title x
expect_rc "updatepr(malformed --repo): -> exit 2" 2
stderr_has "updatepr(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$UPDATEPR" --bogus
expect_rc "updatepr(unknown option): -> exit 2" 2
stderr_has "updatepr(unknown option): diagnostic" "unknown option"

section "update-pr.sh — gh absent / not authenticated"
run 0 sh "$UPDATEPR" --repo o/r --pr 1 --title x
expect_rc "updatepr(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$UPDATEPR" --repo o/r --pr 1 --title x
expect_rc "updatepr(unauth): -> exit 1" 1

section "update-pr.sh — body NOT clobbered when --body-file omitted"
EDIT_LOG1="$WORK/pr-edit-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=https://github.com/octo/repo/pull/5" "GH_STUB_EDIT_LOG=$EDIT_LOG1" \
	sh "$UPDATEPR" --repo octo/repo --pr 5 --title "renamed" --base develop \
		--add-label "bug,urgent" --remove-label stale --add-reviewer alice --remove-reviewer bob
expect_rc "updatepr(no-body-clobber): -> exit 0" 0
stdout_has "updatepr(no-body-clobber): PM_PR_URL" "PM_PR_URL=https://github.com/octo/repo/pull/5"
check "updatepr(no-body-clobber): argv has NO --body-file token" "a --body-file token was found even though none was given — this would CLOBBER the body" \
	"$( grep -Fxq -- '--body-file' "$EDIT_LOG1" && echo 1 || echo 0 )"
check "updatepr(no-body-clobber): argv has NO bare --body token either" "a bare --body flag was found" \
	"$( grep -Fxq -- '--body' "$EDIT_LOG1" && echo 1 || echo 0 )"
check "updatepr(no-body-clobber): --title passed as one token" "title missing/misplaced in argv" \
	"$( argv_has_pair "$EDIT_LOG1" '--title' 'renamed' && echo 0 || echo 1 )"
check "updatepr(no-body-clobber): --base passed as one token" "base missing/misplaced in argv" \
	"$( argv_has_pair "$EDIT_LOG1" '--base' 'develop' && echo 0 || echo 1 )"
check "updatepr(no-body-clobber): --add-label bug passed" "add-label bug missing from argv" \
	"$( argv_has_pair "$EDIT_LOG1" '--add-label' 'bug' && echo 0 || echo 1 )"
check "updatepr(no-body-clobber): --add-label urgent passed" "add-label urgent missing from argv" \
	"$( argv_has_pair "$EDIT_LOG1" '--add-label' 'urgent' && echo 0 || echo 1 )"
check "updatepr(no-body-clobber): --remove-label stale passed" "remove-label missing from argv" \
	"$( argv_has_pair "$EDIT_LOG1" '--remove-label' 'stale' && echo 0 || echo 1 )"
check "updatepr(no-body-clobber): --add-reviewer alice passed" "add-reviewer missing from argv" \
	"$( argv_has_pair "$EDIT_LOG1" '--add-reviewer' 'alice' && echo 0 || echo 1 )"
check "updatepr(no-body-clobber): --remove-reviewer bob passed" "remove-reviewer missing from argv" \
	"$( argv_has_pair "$EDIT_LOG1" '--remove-reviewer' 'bob' && echo 0 || echo 1 )"

section "update-pr.sh — body IS replaced when --body-file is given"
UBODY="$WORK/pr-update-body.md"
printf '## Updated\nNew content.\n' >"$UBODY"
EDIT_LOG2="$WORK/pr-edit-log2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=https://github.com/octo/repo/pull/5" "GH_STUB_EDIT_LOG=$EDIT_LOG2" \
	sh "$UPDATEPR" --repo octo/repo --pr 5 --body-file "$UBODY"
expect_rc "updatepr(body-replace): -> exit 0" 0
check "updatepr(body-replace): argv HAS --body-file token" "expected a --body-file token in argv" \
	"$( grep -Fxq -- '--body-file' "$EDIT_LOG2" && echo 0 || echo 1 )"
check "updatepr(body-replace): body-file contents relayed verbatim" "body content missing" \
	"$( body_block "$EDIT_LOG2" | grep -Fq -- '## Updated' && echo 0 || echo 1 )"

section "update-pr.sh — gh pr edit itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_RC=1" sh "$UPDATEPR" --repo o/r --pr 1 --title x
expect_rc "updatepr(gh-fail): -> exit 1" 1
stderr_has "updatepr(gh-fail): reports failure" "gh pr edit failed"

section "update-pr.sh — successful edit with NO URL returned (still success, courtesy contract)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=" sh "$UPDATEPR" --repo o/r --pr 1 --title x
expect_rc "updatepr(empty-url): -> exit 0 (the URL is a courtesy, not proof of success)" 0
stdout_re "updatepr(empty-url): PM_PR_URL is empty" '^PM_PR_URL=$'

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
