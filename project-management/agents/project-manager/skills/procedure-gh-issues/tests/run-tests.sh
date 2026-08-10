#!/usr/bin/env sh
# shellcheck source-path=SCRIPTDIR
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-gh-issues script suite (create-issue.sh,
#                find-duplicate.sh, link-children.sh, ensure-labels.sh,
#                comment.sh, update-issue.sh, close-issue.sh).
#
# WHY a hand-rolled harness (not bats): the whole point of this suite is
# "runs on any machine with no dependencies". Requiring bats-core would
# contradict that. This harness needs only a POSIX sh plus the coreutils
# that already ship on macOS (BSD) and Linux (GNU).
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools
#     the scripts need (mktemp, grep, sed, awk, ...) PLUS a STUB `gh` so no
#     test ever touches a real repo, a real account, or the network. The gh
#     stub lives in its OWN dir that tests opt into, so "gh absent" is
#     exercised for real (by leaving that dir off PATH).
#   * The gh stub is fully env-driven: tests set GH_STUB_* variables to
#     script `gh auth status`, the labels/milestones/api lookups, `issue
#     create`/`list`/`view`/`edit`, and their return codes — so every
#     deterministic branch is covered without a real `gh`.
#   * The stub logs argv ONE TOKEN PER LINE (between ARGV_BEGIN/ARGV_END
#     markers), never space-joined — a joined "--search a b" string cannot
#     be told apart from four separate tokens `--search`, `a`, `b`, `` (a
#     word-splitting regression), but a token-per-line log can, and that
#     distinction is exactly what several assertions below rely on.
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
SCRIPTS_DIR=$(cd "$TESTS_DIR/../skill/scripts" && pwd)
# `2>/dev/null` + an explicit failure branch: without them a MISSING lib/ dir
# aborts right here under `set -e`, with a raw `cd` error, before the friendly
# per-file preflight below can ever run — i.e. the preflight could not fire in
# its single most likely failure mode.
LIB_DIR=$(cd "$TESTS_DIR/../skill/lib" 2>/dev/null && pwd) || { printf 'FATAL: missing lib dir: %s\n' "$TESTS_DIR/../skill/lib" >&2; exit 1; }
CREATE="$SCRIPTS_DIR/create-issue.sh"
FINDDUP="$SCRIPTS_DIR/find-duplicate.sh"
LINKKIDS="$SCRIPTS_DIR/link-children.sh"
ENSURELABELS="$SCRIPTS_DIR/ensure-labels.sh"
COMMENT="$SCRIPTS_DIR/comment.sh"
UPDATE="$SCRIPTS_DIR/update-issue.sh"
CLOSE="$SCRIPTS_DIR/close-issue.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-issues-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"      # real tools (gh is NEVER here)
GHDIR="$WORK/ghbin"          # gh stub (only when a test opts in)
mkdir -p "$TOOLBOX" "$GHDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# Some fixtures (chmod 000 for an unreadable-body test) have no effect under
# uid 0 — root can read/write regardless of permission bits — so that one
# test is skipped rather than producing a false failure/pass under root.
IS_ROOT=0
[ "$(id -u 2>/dev/null || printf '1')" = "0" ] && IS_ROOT=1

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools we need. gh is NEVER here.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh mktemp grep sed cat tr paste rm cp mv awk; do
	link_tool "$t"
done

# Every command script sources its libs at startup, so a missing lib file would
# surface as 300+ identical, unreadable failures. Fail once, loudly, instead —
# beside the link_tool fatals above and deliberately NOT counted in TESTS_RUN,
# so the check totals stay comparable.
for f in pm-diag.sh pm-validate.sh pm-gh-preconditions.sh pm-lists.sh; do
	[ -r "$LIB_DIR/$f" ] || { printf 'FATAL: missing lib file: %s\n' "$LIB_DIR/$f" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# gh stub — fully env-driven so tests script every deterministic branch.
#   GH_STUB_AUTHED=1              -> `gh auth status` succeeds
#   GH_STUB_API_RC=n              -> exit code for ANY `gh api ...` call
#   GH_STUB_LABELS=<nl-list>      -> `gh api .../labels` result (label names)
#   GH_STUB_MILESTONES=<nl-list>  -> `gh api .../milestones...` result (titles)
#   GH_STUB_CREATE_RC=n           -> exit code for `gh issue create`
#   GH_STUB_CREATE_URL=url        -> stdout for a successful `gh issue create`
#                                    (set-but-EMPTY is honored as empty output —
#                                    distinct from leaving it unset)
#   GH_STUB_CREATE_LOG=path       -> capture argv (token-per-line) + the
#                                    --body-file CONTENTS
#   GH_STUB_BODY_FILE_RAW=path    -> byte-exact raw COPY of the --body-file gh
#                                    received (honored by `gh issue create` and
#                                    `gh issue comment`). A channel entirely
#                                    separate from the marker block above, so a
#                                    byte-exact proof never has to survive
#                                    marker framing — see diff_body_raw.
#   GH_STUB_LIST_RC=n             -> exit code for `gh issue list`
#   GH_STUB_LIST_LOG=path         -> capture `gh issue list` argv (token-per-line)
#   GH_STUB_SEARCH_URLS=<nl-list> -> `gh issue list --json url --jq...` result
#   GH_STUB_VIEW_RC=n             -> exit code for `gh issue view`
#   GH_STUB_VIEW_BODY=text        -> `gh issue view --json body --jq...` result
#   GH_STUB_EDIT_RC=n             -> exit code for `gh issue edit`
#   GH_STUB_EDIT_LOG=path         -> copy of the --body-file CONTENTS passed
#                                    to `gh issue edit` (link-children.sh tests)
#   GH_STUB_EDIT_ARGV_LOG=path    -> capture `gh issue edit` argv (token-per-line;
#                                    update-issue.sh tests — kept separate from
#                                    GH_STUB_EDIT_LOG so existing link-children.sh
#                                    assertions on that file are unaffected)
#   GH_STUB_EDIT_URL=url          -> stdout for a successful `gh issue edit`
#                                    (${VAR-default} semantics, same as CREATE_URL)
#   GH_STUB_COMMENT_RC=n          -> exit code for `gh issue comment`
#   GH_STUB_COMMENT_URL=url       -> stdout for a successful `gh issue comment`
#                                    (${VAR-default} semantics)
#   GH_STUB_COMMENT_LOG=path      -> capture argv (token-per-line) + the
#                                    --body-file CONTENTS
#   GH_STUB_CLOSE_RC=n            -> exit code for `gh issue close`
#   GH_STUB_CLOSE_LOG=path        -> capture `gh issue close` argv (token-per-line)
#   GH_STUB_LABEL_CREATE_RC=n     -> exit code for EVERY `gh label create` call
#   GH_STUB_LABEL_CREATE_FAIL_LIST=<nl-list> -> exit 1 ONLY for a `gh label
#                                    create` call whose label NAME (the last
#                                    argv token) is listed here — lets a test
#                                    fail ONE label while others in the same
#                                    run still succeed (mixed best-effort case)
#   GH_STUB_LABEL_CREATE_LOG=path -> capture EACH `gh label create` call's argv
#                                    (token-per-line; ensure-labels.sh calls this
#                                    once per missing label, so this file
#                                    accumulates one ARGV_BEGIN/END block per call)
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
	# capture_body_file LOGFILE RAWFILE "$@" — scans argv for the value following
	# --body-file and records that file two ways: a verbatim copy of its CONTENTS
	# appended to LOGFILE between BODY_FILE_CONTENTS_START/END markers (readable,
	# scoped assertions), and — when RAWFILE is set — a byte-exact copy for a
	# strict diff. Either target may be empty; each is guarded independently.
	#
	# `awk '{ print }'`, NOT `cat`: awk terminates every record it prints with a
	# newline, so the closing BODY_FILE_CONTENTS_END marker always lands on its
	# OWN line. `cat` on a body file whose last byte is NOT a newline — a legal
	# file — glues the marker onto the final content line, which silently breaks
	# BOTH body_block's marker-range extraction (it swallows that last line) and
	# ARGV_SCOPE's payload suppression (in_payload never resets). A no-op for
	# already-newline-terminated input; mirrors procedure-glab-issues' raw channel.
	logtarget=$1
	rawtarget=$2
	shift 2
	prev=""
	for a in "$@"; do
		if [ "$prev" = "--body-file" ]; then
			if [ -n "$logtarget" ]; then
				{
					printf 'BODY_FILE_CONTENTS_START\n'
					awk '{ print }' "$a"
					printf 'BODY_FILE_CONTENTS_END\n'
				} >>"$logtarget"
			fi
			if [ -n "$rawtarget" ]; then
				cp "$a" "$rawtarget"
			fi
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
	api)
		if [ "${GH_STUB_API_RC:-0}" != "0" ]; then
			printf 'stub: forced api failure\n' >&2
			exit "${GH_STUB_API_RC:-1}"
		fi
		path=${2:-}
		case "$path" in
			*/labels)
				printf '%s\n' "${GH_STUB_LABELS:-}"
				exit 0 ;;
			*/milestones*)
				printf '%s\n' "${GH_STUB_MILESTONES:-}"
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	issue)
		case "${2:-}" in
			create)
				shift 2
				log_argv "${GH_STUB_CREATE_LOG:-}" "$@"
				capture_body_file "${GH_STUB_CREATE_LOG:-}" "${GH_STUB_BODY_FILE_RAW:-}" "$@"
				if [ "${GH_STUB_CREATE_RC:-0}" != "0" ]; then
					printf 'stub: forced create failure\n' >&2
					exit "${GH_STUB_CREATE_RC:-1}"
				fi
				# ${VAR-default}, NOT ${VAR:-default}: a test that sets
				# GH_STUB_CREATE_URL to the EMPTY string must see empty
				# output, distinct from leaving the var unset entirely.
				printf '%s\n' "${GH_STUB_CREATE_URL-https://github.com/octo/repo/issues/1}"
				exit 0 ;;
			list)
				shift 2
				log_argv "${GH_STUB_LIST_LOG:-}" "$@"
				if [ "${GH_STUB_LIST_RC:-0}" != "0" ]; then
					printf 'stub: forced list failure\n' >&2
					exit "${GH_STUB_LIST_RC:-1}"
				fi
				printf '%s\n' "${GH_STUB_SEARCH_URLS:-}"
				exit 0 ;;
			view)
				if [ "${GH_STUB_VIEW_RC:-0}" != "0" ]; then
					printf 'stub: forced view failure\n' >&2
					exit "${GH_STUB_VIEW_RC:-1}"
				fi
				printf '%s\n' "${GH_STUB_VIEW_BODY:-}"
				exit 0 ;;
			edit)
				shift 2
				log_argv "${GH_STUB_EDIT_ARGV_LOG:-}" "$@"
				if [ -n "${GH_STUB_EDIT_LOG:-}" ]; then
					prev=""
					for a in "$@"; do
						if [ "$prev" = "--body-file" ]; then
							cp "$a" "$GH_STUB_EDIT_LOG"
						fi
						prev=$a
					done
				fi
				if [ "${GH_STUB_EDIT_RC:-0}" != "0" ]; then
					printf 'stub: forced edit failure\n' >&2
					exit "${GH_STUB_EDIT_RC:-1}"
				fi
				# ${VAR-default}, NOT ${VAR:-default} — see GH_STUB_CREATE_URL.
				printf '%s\n' "${GH_STUB_EDIT_URL-https://github.com/octo/repo/issues/1}"
				exit 0 ;;
			comment)
				shift 2
				log_argv "${GH_STUB_COMMENT_LOG:-}" "$@"
				capture_body_file "${GH_STUB_COMMENT_LOG:-}" "${GH_STUB_BODY_FILE_RAW:-}" "$@"
				if [ "${GH_STUB_COMMENT_RC:-0}" != "0" ]; then
					printf 'stub: forced comment failure\n' >&2
					exit "${GH_STUB_COMMENT_RC:-1}"
				fi
				# ${VAR-default}, NOT ${VAR:-default} — see GH_STUB_CREATE_URL.
				printf '%s\n' "${GH_STUB_COMMENT_URL-https://github.com/octo/repo/issues/1#issuecomment-1}"
				exit 0 ;;
			close)
				shift 2
				log_argv "${GH_STUB_CLOSE_LOG:-}" "$@"
				if [ "${GH_STUB_CLOSE_RC:-0}" != "0" ]; then
					printf 'stub: forced close failure\n' >&2
					exit "${GH_STUB_CLOSE_RC:-1}"
				fi
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	label)
		case "${2:-}" in
			create)
				shift 2
				log_argv "${GH_STUB_LABEL_CREATE_LOG:-}" "$@"
				# The label NAME is always the LAST argv token (the caller
				# places it after a literal `--`, see ensure-labels.sh).
				label_name=""
				for a in "$@"; do label_name=$a; done
				if [ -n "${GH_STUB_LABEL_CREATE_FAIL_LIST:-}" ] && \
					printf '%s\n' "$GH_STUB_LABEL_CREATE_FAIL_LIST" | grep -Fxq -- "$label_name"; then
					printf 'stub: forced label create failure for %s\n' "$label_name" >&2
					exit 1
				fi
				if [ "${GH_STUB_LABEL_CREATE_RC:-0}" != "0" ]; then
					printf 'stub: forced label create failure\n' >&2
					exit "${GH_STUB_LABEL_CREATE_RC:-1}"
				fi
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
skip() { printf '  skip %s\n' "$1"; }

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

# line_count_eq LOGFILE EXACT_LINE N — true iff EXACT_LINE appears in
# LOGFILE exactly N times (whole-line match). Used for idempotency: presence
# alone doesn't catch a double-append, an exact count does.
line_count_eq() {
	[ "$(grep -Fxc -- "$2" "$1" 2>/dev/null || true)" -eq "$3" ]
}

# ---------------------------------------------------------------------------
# argv assertions — the three helpers below share ONE scoping prelude.
#
# ARGV_SCOPE is the awk program prefix every argv assertion is built on. It
# reduces the stub's log to the tokens that genuinely came from log_argv, and
# maintains the per-block state the helpers read (in_argv, want, next_is_first),
# so each helper is left as nothing but its own comparison rule. Sharing ONE
# prelude is also what keeps the three sound in the same way — the previous
# per-helper copies had drifted, and the drift was a real hole (below).
#
# WHY THE PAYLOAD SUPPRESSION MUST COME FIRST, BEFORE the ARGV_BEGIN rule: the
# same log file also holds the stub's BODY_FILE_CONTENTS block, i.e. untrusted
# fixture payload bytes. Gating on ARGV_BEGIN/ARGV_END ALONE is NOT enough,
# because a payload line reading exactly `ARGV_BEGIN` re-opens that gate and
# hands the following payload lines to the comparison as though the script had
# passed them — a positive assertion would pass without being earned, and a
# negative one would be defeated. Skipping the payload block outright is what
# makes the gate sound; the "harness self-check" section below pins it.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # $0 here is awk's whole-line, not a shell parameter — single quotes are required
ARGV_SCOPE='
	$0 == "BODY_FILE_CONTENTS_START" { in_payload = 1; next }
	$0 == "BODY_FILE_CONTENTS_END"   { in_payload = 0; next }
	in_payload == 1 { next }
	$0 == "ARGV_BEGIN" { in_argv = 1; want = 0; next_is_first = 1; next }
	$0 == "ARGV_END"   { in_argv = 0; want = 0; next_is_first = 0; next }
	in_argv != 1 { next }
'

# argv_has_pair LOGFILE FLAG VALUE — true iff FLAG appears immediately
# followed by VALUE as two CONSECUTIVE lines inside the log's token-per-line
# ARGV_BEGIN/ARGV_END block. Proves VALUE reached gh as ONE argv token right
# after FLAG — a word-splitting regression would show as extra lines instead.
#
# FLAG and VALUE travel through the ENVIRONMENT, not through `awk -v`, because
# `-v` assignment performs ESCAPE PROCESSING: a backslash sequence inside an
# expected value (a label of 'a\tb' is legal input here) would silently become a
# real tab in awk and never match the literal backslash-t the script actually
# passed. ENVIRON does no such rewriting.
#
# Each comparison concatenates "" onto BOTH sides. `$0` and ENVIRON values are awk
# STRNUMs: when both look numeric, `==` compares them NUMERICALLY, so a logged token
# of `007` would match an expected value of `7` — and an issue number is exactly the
# kind of numeric-looking argv this suite asserts on. Concatenation forces the
# BYTE-EXACT string comparison these argv assertions actually mean.
argv_has_pair() {
	ARGV_FLAG=$2 ARGV_VALUE=$3 awk "$ARGV_SCOPE"'
		($0 "") == (ENVIRON["ARGV_FLAG"] "") { want = 1; next }
		want == 1 { if (($0 "") == (ENVIRON["ARGV_VALUE"] "")) { found = 1 }; want = 0 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# argv_has_token LOGFILE TOKEN — true iff TOKEN appears as a WHOLE LINE inside an
# ARGV_BEGIN/ARGV_END block. The scoped replacement for a bare
# `grep -Fxq -- 'TOKEN' logfile`, which scanned the BODY_FILE_CONTENTS payload
# block too: an assertion that "no bare --body token was passed" must not be
# defeated by a fixture whose issue body happens to contain a line reading
# exactly `--body`. TOKEN travels via ENVIRON for the same no-escape-processing
# reason as argv_has_pair's, and is compared with the same ""-concatenation on both
# sides for the same strnum reason.
argv_has_token() {
	ARGV_TOKEN=$2 awk "$ARGV_SCOPE"'
		($0 "") == (ENVIRON["ARGV_TOKEN"] "") { found = 1 }
		END { exit(found ? 0 : 1) }
	' "$1"
}

# argv_first_is LOGFILE VALUE — true iff VALUE is the FIRST token of an argv
# block, i.e. it was passed POSITIONALLY rather than behind a flag. This is what
# proves close-issue.sh forwards the issue number the way gh takes it (positional
# <number>), and — more to the point — that it forwards the number the CALLER
# named rather than some other value that happens to be in scope. Every other
# argv assertion in this file checks a FLAG's presence or value; none of them can
# see the positional at all.
#
# The stub `shift 2`s past `issue close` / `issue comment` before logging, so the
# first logged token IS the positional. Deliberately anchored to the first token
# rather than scanning the block: an off-by-one that emitted the right number in
# some other argv slot must not satisfy this.
#
# VALUE travels via ENVIRON and is compared with the same ""-concatenation on both
# sides as argv_has_pair/argv_has_token, for the same two reasons — and this helper
# is where BOTH bite hardest, because the value it asserts is an issue number. A
# bare `==` between two strnum operands compares NUMERICALLY: a regression that
# logged `042` where the test searched `42` (or `42.0`, or `+42`) would compare
# equal and pass an assertion it never earned. Concatenating "" forces a byte
# comparison. Mirrors procedure-glab-issues' helper of the same name.
argv_first_is() {
	ARGV_FIRST_VALUE=$2 awk "$ARGV_SCOPE"'
		next_is_first == 1 { if (($0 "") == (ENVIRON["ARGV_FIRST_VALUE"] "")) { found = 1 }; next_is_first = 0 }
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

# diff_body_raw FIXTURE RAWCOPY — strict byte-for-byte compare of the stub's raw
# copy of the file gh actually received (GH_STUB_BODY_FILE_RAW) against the
# original fixture. The authoritative proof that a body reached gh completely
# unaltered: evaluation, truncation (a real heredoc stopping early), or
# reordering would all change the captured bytes.
#
# Deliberately reads the RAW channel rather than body_block's marker-extracted
# text. Marker framing has to re-serialise the content line by line, so a fixture
# whose last byte is not a newline can never be compared byte-exactly through it
# — the framing must add one. Diffing a plain `cp` sidesteps the whole question,
# which makes this proof independent of the log format entirely. Writes the diff
# to $WORK/body_raw_diff. Mirrors procedure-glab-issues' diff_value_file.
diff_body_raw() {
	diff -u "$1" "$2" >"$WORK/body_raw_diff" 2>&1
}

section() { printf '\n== %s ==\n' "$1"; }

# ===========================================================================
# Harness self-check — the argv helpers are NOT fooled by payload bytes
#
# WHY A TEST OF THE TEST HARNESS. argv_has_pair / argv_has_token /
# argv_first_is are the primitives roughly a hundred assertions below are
# expressed in, so a false positive in one of them silently disarms every
# assertion built on it — the suite stays green while verifying nothing. That
# failure mode is invisible from the outside, which is exactly why it gets a
# direct test rather than trust.
#
# The fixture is a genuine argv block followed by a body payload that IMPERSONATES
# a second one: a payload line reading exactly `ARGV_BEGIN`, followed by lines the
# assertions below search for. Before ARGV_SCOPE gained its payload suppression,
# that impersonation re-opened the argv gate and every negative check here passed
# a value the script never sent.
# ===========================================================================
section "harness self-check — argv helpers ignore the body payload block"

ARGV_POISON_LOG="$WORK/argv-poison-log"
cat >"$ARGV_POISON_LOG" <<'POISON_EOF'
ARGV_BEGIN
9
--repo
o/r
ARGV_END
BODY_FILE_CONTENTS_START
ARGV_BEGIN
42
--body
--reason
not planned
BODY_FILE_CONTENTS_END
POISON_EOF

check "self-check: argv_first_is still finds the REAL positional '9'" "the helper stopped seeing a genuine first token" \
	"$( argv_first_is "$ARGV_POISON_LOG" '9' && echo 0 || echo 1 )"
check "self-check: argv_first_is does NOT accept '42' from the payload's fake ARGV_BEGIN" "a body line was mistaken for a positional argument" \
	"$( argv_first_is "$ARGV_POISON_LOG" '42' && echo 1 || echo 0 )"
check "self-check: argv_has_pair still finds the REAL --repo o/r" "the helper stopped seeing a genuine flag/value pair" \
	"$( argv_has_pair "$ARGV_POISON_LOG" '--repo' 'o/r' && echo 0 || echo 1 )"
check "self-check: argv_has_pair does NOT accept a flag/value pair from the payload" "two body lines were mistaken for a flag and its value" \
	"$( argv_has_pair "$ARGV_POISON_LOG" '--reason' 'not planned' && echo 1 || echo 0 )"
check "self-check: argv_has_token does NOT accept a token from the payload" "a body line was mistaken for an argv token" \
	"$( argv_has_token "$ARGV_POISON_LOG" '--body' && echo 1 || echo 0 )"

# ===========================================================================
# lib/pm-validate.sh — DIRECT unit coverage of the pure predicates
#
# WHY THIS BLOCK EXISTS, AND WHY IT IS THE ONLY ONE THAT SOURCES A LIB.
# Every other test in this file is black-box: it invokes a script through the
# isolated toolbox and asserts on stdout/stderr/exit code. That is the right
# altitude for a CLI — but it can only reach a predicate through whatever
# inputs some command's argument parser happens to forward, so most of each
# predicate's truth table is simply unreachable from out there (a CLI test can
# show that "o/.." is rejected; it cannot cheaply enumerate "a/b/c", "g//p",
# "./p", "" and the rest).
#
# pm-validate.sh is sourceable here precisely BECAUSE its functions are pure:
# no $PROG, no usage(), no exiting, no globals, no binary on PATH. Sourcing it
# into the harness's own shell costs nothing and pins the full truth table
# directly — including the edge inputs above, which is where a rewrite of a
# `case` pattern actually goes wrong.
#
# This block deliberately does NOT run under `run` / `env -i`: there is no
# subprocess and no PATH involved, so the toolbox is irrelevant to it.
# ===========================================================================
section "lib/pm-validate.sh — pure predicate truth tables (unit)"

# shellcheck source=../skill/lib/pm-validate.sh
. "$LIB_DIR/pm-validate.sh"

# pred_true NAME FN VALUE — assert FN accepts VALUE (exit 0).
pred_true() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if "$2" "$3"; then pass "$1"
	else fail "$1" "$2 rejected a value it must accept: [$3]"; fi
}

# pred_false NAME FN VALUE — assert FN rejects VALUE (exit 1).
pred_false() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if "$2" "$3"; then fail "$1" "$2 accepted a value it must reject: [$3]"
	else pass "$1"; fi
}

pred_true  "is_positive_int: '1'"            is_positive_int 1
pred_true  "is_positive_int: '42'"           is_positive_int 42
pred_true  "is_positive_int: '10'"           is_positive_int 10
pred_false "is_positive_int: '0' (not positive)"        is_positive_int 0
pred_false "is_positive_int: '007' (leading zero)"      is_positive_int 007
pred_false "is_positive_int: '' (empty)"                is_positive_int ""
pred_false "is_positive_int: '1x' (trailing non-digit)" is_positive_int 1x
pred_false "is_positive_int: 'abc'"                     is_positive_int abc
pred_false "is_positive_int: '-1' (negative)"           is_positive_int "-1"
pred_false "is_positive_int: '1 2' (embedded space)"    is_positive_int "1 2"

pred_true  "is_valid_repo_slug: 'o/r'"                  is_valid_repo_slug o/r
pred_true  "is_valid_repo_slug: 'octo/repo'"            is_valid_repo_slug octo/repo
pred_true  "is_valid_repo_slug: dots/dashes/underscores" is_valid_repo_slug my-org.x/my_repo.js
pred_false "is_valid_repo_slug: 'a/b/c' (GitHub takes exactly one '/')" is_valid_repo_slug a/b/c
pred_false "is_valid_repo_slug: 'o/..' (dot-segment)"   is_valid_repo_slug 'o/..'
pred_false "is_valid_repo_slug: '../r' (dot-segment)"   is_valid_repo_slug '../r'
pred_false "is_valid_repo_slug: '..' (bare dot-segment)" is_valid_repo_slug '..'
pred_false "is_valid_repo_slug: 'noslash'"              is_valid_repo_slug noslash
pred_false "is_valid_repo_slug: '' (empty)"             is_valid_repo_slug ""
pred_false "is_valid_repo_slug: 'o/r; rm -rf /' (metachars)" is_valid_repo_slug 'o/r; rm -rf /'
pred_false "is_valid_repo_slug: 'o r/x' (space)"        is_valid_repo_slug 'o r/x'
# 'g//p', '/g/p' and 'g/p/' are all rejected — but by the EXACTLY-ONE-'/' rule
# (*/*/*), not by any empty-segment rule: this predicate has none. That
# distinction is the point of the three cases below, and of the two after them.
pred_false "is_valid_repo_slug: 'g//p' (caught by the two-slash rule)"  is_valid_repo_slug 'g//p'
pred_false "is_valid_repo_slug: '/g/p' (caught by the two-slash rule)"  is_valid_repo_slug '/g/p'
pred_false "is_valid_repo_slug: 'g/p/' (caught by the two-slash rule)"  is_valid_repo_slug 'g/p/'
pred_false "is_valid_repo_slug: '.' (bare current-dir segment)"         is_valid_repo_slug '.'
# CURRENT BEHAVIOR, PINNED AS-IS — NOT an endorsement. With only ONE slash there
# is no */*/* match and no ".." to catch, so a LEADING slash and a leading "./"
# both slip through: '/gp' and './p' are ACCEPTED. The GitLab sibling rejects the
# equivalents outright (it has explicit leading/trailing-slash and current-dir
# rules). Neither is a traversal — '.' resolves to the same path, so the REST
# sink just 404s — which is why this refactor PRESERVES the behavior rather than
# "fixing" it: silently tightening a validator mid-refactor is exactly the kind
# of riding-along change that must be a separate, deliberate decision. These two
# assertions exist so that decision, if it ever comes, has to be explicit.
pred_true  "is_valid_repo_slug: '/gp' ACCEPTED (leading slash unscreened — pinned, see note)" is_valid_repo_slug '/gp'
pred_true  "is_valid_repo_slug: './p' ACCEPTED (leading './' unscreened — pinned, see note)"  is_valid_repo_slug './p'

pred_true  "is_valid_hex_color: 'ff0000'"               is_valid_hex_color ff0000
pred_true  "is_valid_hex_color: 'FF00aa' (mixed case)"  is_valid_hex_color FF00aa
pred_true  "is_valid_hex_color: '000000'"               is_valid_hex_color 000000
pred_false "is_valid_hex_color: '#ff0000' (gh wants NO leading '#')" is_valid_hex_color '#ff0000'
pred_false "is_valid_hex_color: 'zzzzzz' (non-hex)"     is_valid_hex_color zzzzzz
pred_false "is_valid_hex_color: 'ff00' (too short)"     is_valid_hex_color ff00
pred_false "is_valid_hex_color: 'ff00000' (too long)"   is_valid_hex_color ff00000
pred_false "is_valid_hex_color: '' (empty)"             is_valid_hex_color ""

# ===========================================================================
# create-issue.sh
# ===========================================================================
section "create-issue.sh — usage / argument errors"
run 1 sh "$CREATE" -h
expect_rc "create(usage): -h -> exit 0" 0
stdout_has "create(usage): help text" "Usage:"

BODY1="$WORK/body1.md"
printf '## Story\nAs a user...\n' >"$BODY1"

run 1 sh "$CREATE" --title x --body-file /nope
expect_rc "create(missing --repo): -> exit 2" 2
stderr_has "create(missing --repo): diagnostic" "--repo is required"

run 1 sh "$CREATE" --repo o/r --body-file /nope
expect_rc "create(missing --title): -> exit 2" 2
stderr_has "create(missing --title): diagnostic" "--title is required"

run 1 sh "$CREATE" --repo o/r --title x
expect_rc "create(missing --body-file): -> exit 2" 2
stderr_has "create(missing --body-file): diagnostic" "--body-file is required"

run 1 sh "$CREATE" --repo o/r --title x --body-file "$WORK/does-not-exist"
expect_rc "create(nonexistent body-file): -> exit 2" 2
stderr_has "create(nonexistent body-file): diagnostic" "does not exist or is not readable"

if [ "$IS_ROOT" -eq 1 ]; then
	skip "create(unreadable body-file): running as root — chmod 000 has no effect"
else
	UNREADABLE="$WORK/unreadable-body.md"
	printf 'body\n' >"$UNREADABLE"
	chmod 000 "$UNREADABLE"
	run 1 sh "$CREATE" --repo o/r --title x --body-file "$UNREADABLE"
	expect_rc "create(unreadable body-file): -> exit 2" 2
	stderr_has "create(unreadable body-file): diagnostic" "does not exist or is not readable"
	chmod 644 "$UNREADABLE"
fi

run 1 sh "$CREATE" --repo not-owner-slash-repo --title x --body-file "$BODY1"
expect_rc "create(malformed --repo, no slash): -> exit 2" 2
stderr_has "create(malformed --repo, no slash): diagnostic" "OWNER/REPO"

run 1 sh "$CREATE" --repo 'a/b/c' --title x --body-file "$BODY1"
expect_rc "create(malformed --repo, extra slash): -> exit 2" 2
stderr_has "create(malformed --repo, extra slash): diagnostic" "OWNER/REPO"

run 1 sh "$CREATE" --repo 'o/r; rm -rf /' --title x --body-file "$BODY1"
expect_rc "create(malformed --repo, disallowed chars): -> exit 2" 2
stderr_has "create(malformed --repo, disallowed chars): diagnostic" "OWNER/REPO"

run 1 sh "$CREATE" --repo 'o/..' --title x --body-file "$BODY1"
expect_rc "create(malformed --repo, dot-segment): -> exit 2" 2
stderr_has "create(malformed --repo, dot-segment): diagnostic" "OWNER/REPO"

run 1 sh "$CREATE" --bogus
expect_rc "create(unknown option): -> exit 2" 2
stderr_has "create(unknown option): diagnostic" "unknown option"

section "create-issue.sh — gh absent / not authenticated"
run 0 sh "$CREATE" --repo o/r --title x --body-file "$BODY1"
expect_rc "create(no-gh): -> exit 1" 1
stderr_has "create(no-gh): install hint" "cli.github.com"

run 1 "GH_STUB_AUTHED=0" sh "$CREATE" --repo o/r --title x --body-file "$BODY1"
expect_rc "create(unauth): -> exit 1" 1
stderr_has "create(unauth): diagnostic" "not authenticated"

section "create-issue.sh — missing label detected (no create attempted)"
CREATE_LOG1="$WORK/create-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LABELS=type:story
area:billing" "GH_STUB_CREATE_LOG=$CREATE_LOG1" \
	sh "$CREATE" --repo o/r --title x --body-file "$BODY1" --label "type:story,area:reporting"
expect_rc "create(missing-label): -> exit 1" 1
stderr_has "create(missing-label): names the missing label" "area:reporting"
file_missing "create(missing-label): gh issue create never invoked" "$CREATE_LOG1"

section "create-issue.sh — missing milestone detected (no create attempted)"
CREATE_LOG2="$WORK/create-log2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_MILESTONES=Q1
Q2" "GH_STUB_CREATE_LOG=$CREATE_LOG2" \
	sh "$CREATE" --repo o/r --title x --body-file "$BODY1" --milestone "Q3"
expect_rc "create(missing-milestone): -> exit 1" 1
stderr_has "create(missing-milestone): names it" "Q3"
file_missing "create(missing-milestone): gh issue create never invoked" "$CREATE_LOG2"

section "create-issue.sh — gh api (label lookup) itself fails (no create attempted)"
CREATE_LOG5="$WORK/create-log5"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_API_RC=1" "GH_STUB_CREATE_LOG=$CREATE_LOG5" \
	sh "$CREATE" --repo o/r --title x --body-file "$BODY1" --label "type:story"
expect_rc "create(api-fail-labels): -> exit 1" 1
stderr_has "create(api-fail-labels): reports failure" "failed to look up labels"
file_missing "create(api-fail-labels): gh issue create never invoked" "$CREATE_LOG5"

section "create-issue.sh — gh api (milestone lookup) itself fails (no create attempted)"
CREATE_LOG6="$WORK/create-log6"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_API_RC=1" "GH_STUB_CREATE_LOG=$CREATE_LOG6" \
	sh "$CREATE" --repo o/r --title x --body-file "$BODY1" --milestone "Q3"
expect_rc "create(api-fail-milestone): -> exit 1" 1
stderr_has "create(api-fail-milestone): reports failure" "failed to look up milestones"
file_missing "create(api-fail-milestone): gh issue create never invoked" "$CREATE_LOG6"

section "create-issue.sh — successful create (labels + milestone + assignees)"
CREATE_LOG3="$WORK/create-log3"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LABELS=type:story
area:billing" "GH_STUB_MILESTONES=Q3" \
	"GH_STUB_CREATE_URL=https://github.com/octo/repo/issues/42" "GH_STUB_CREATE_LOG=$CREATE_LOG3" \
	sh "$CREATE" --repo octo/repo --title "As a user, I can export" --body-file "$BODY1" \
		--label "type:story,area:billing" --milestone "Q3" --assignee alice --assignee bob
expect_rc "create(success): -> exit 0" 0
stdout_has "create(success): PM_ISSUE_URL" "PM_ISSUE_URL=https://github.com/octo/repo/issues/42"
stdout_has "create(success): PM_ISSUE_NUMBER" "PM_ISSUE_NUMBER=42"
check "create(success): --label type:story passed as one token" "label missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG3" '--label' 'type:story' && echo 0 || echo 1 )"
check "create(success): --label area:billing passed as one token" "label missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG3" '--label' 'area:billing' && echo 0 || echo 1 )"
check "create(success): --milestone Q3 passed as one token" "milestone missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG3" '--milestone' 'Q3' && echo 0 || echo 1 )"
check "create(success): --assignee alice passed as one token" "assignee missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG3" '--assignee' 'alice' && echo 0 || echo 1 )"
check "create(success): --assignee bob passed as one token" "assignee missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG3" '--assignee' 'bob' && echo 0 || echo 1 )"
check "create(success): argv uses --body-file (the injection-safety mechanism)" "no --body-file token in argv" \
	"$( argv_has_token "$CREATE_LOG3" '--body-file' && echo 0 || echo 1 )"
check "create(success): argv has NO bare --body token" "a bare --body flag was found in argv" \
	"$( argv_has_token "$CREATE_LOG3" '--body' && echo 1 || echo 0 )"
check "create(success): body-file contents relayed verbatim (body-only text, not the title)" "body content missing" \
	"$( body_block "$CREATE_LOG3" | grep -Fq -- '## Story' && echo 0 || echo 1 )"

section "create-issue.sh — --project reaches gh as an argv token (repeatable)"
CREATE_LOG7="$WORK/create-log7"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_URL=https://github.com/octo/repo/issues/7" "GH_STUB_CREATE_LOG=$CREATE_LOG7" \
	sh "$CREATE" --repo octo/repo --title x --body-file "$BODY1" --project "Roadmap" --project "Q3 Goals"
expect_rc "create(project): -> exit 0" 0
check "create(project): --project 'Roadmap' passed as one token" "project missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG7" '--project' 'Roadmap' && echo 0 || echo 1 )"
check "create(project): --project 'Q3 Goals' passed as one token" "project missing/misplaced in argv" \
	"$( argv_has_pair "$CREATE_LOG7" '--project' 'Q3 Goals' && echo 0 || echo 1 )"

# NOTE on "no --project pre-check" (design, not a gap): an unknown --project
# is deliberately NOT distinguished from any other gh failure — --project is
# just another argv token (proven above), so it hits the exact same
# generic-failure code path as this test exercises. A separate
# "unknown --project" test would be identical to this one in every assertion
# and is intentionally not duplicated here.
section "create-issue.sh — a comma-list with SPACES and EMPTY elements"
# add_label trims each token and drops empty ones, but no fixture in THIS harness
# contained a space or an empty element, so both behaviors were unexercised here
# (the GitLab sibling has covered them all along). A dropped trim would send gh
# the label " urgent" — a DIFFERENT label, which the existence pre-check would
# then reject — and a dropped empty-skip would send an empty argv value.
CREATE_LOG_TRIM="$WORK/create-log-trim"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LABELS=bug
urgent" "GH_STUB_CREATE_LOG=$CREATE_LOG_TRIM" \
	sh "$CREATE" --repo octo/repo --title x --body-file "$BODY1" --label "bug, urgent ,,"
expect_rc "create(csv trim): -> exit 0 (the trimmed names passed the existence pre-check)" 0
check "create(csv trim): 'bug' arrived clean" "the first token was mangled" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' 'bug' && echo 0 || echo 1 )"
check "create(csv trim): ' urgent ' arrived TRIMMED to 'urgent'" "surrounding whitespace was not trimmed" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' 'urgent' && echo 0 || echo 1 )"
check "create(csv trim): the UNTRIMMED ' urgent ' never reached argv" "an untrimmed token was passed to gh" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' ' urgent ' && echo 1 || echo 0 )"
check "create(csv trim): the empty elements produced NO empty --label value" "an empty label value was passed to gh" \
	"$( argv_has_pair "$CREATE_LOG_TRIM" '--label' '' && echo 1 || echo 0 )"

section "create-issue.sh — --assignee/--project DO comma-split (unified with update-issue.sh)"
# A DELIBERATE, DOCUMENTED BEHAVIOR CHANGE, pinned here in its new direction.
# --assignee and --project used to append their value verbatim while --label
# comma-split and update-issue.sh's --add-assignee comma-split — so the identical
# string `alice,bob` meant ONE assignee on create and TWO on update. All three
# create flags now route through the same csv_accumulate primitive (lib/
# pm-lists.sh, which carries the full rationale), so the asymmetry is resolved in
# favour of splitting: the more capable direction, and the one the real `gh` CLI's
# repeatable string-slice flags take.
#
# The cost of that uniformity is that a value CONTAINING a comma can no longer be
# expressed through these flags — which is precisely what the "never reached argv"
# assertions below pin, so a silent revert to the verbatim append cannot pass.
CREATE_LOG_SPLIT="$WORK/create-log-split"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_URL=https://github.com/octo/repo/issues/8" "GH_STUB_CREATE_LOG=$CREATE_LOG_SPLIT" \
	sh "$CREATE" --repo octo/repo --title x --body-file "$BODY1" \
		--assignee "alice,bob" --project "A,B"
expect_rc "create(split): -> exit 0" 0
check "create(split): --assignee 'alice,bob' WAS split into its own 'alice' token" \
	"--assignee stopped comma-splitting" \
	"$( argv_has_pair "$CREATE_LOG_SPLIT" '--assignee' 'alice' && echo 0 || echo 1 )"
check "create(split): --assignee 'alice,bob' WAS split into its own 'bob' token" \
	"--assignee dropped the second half of the comma-list" \
	"$( argv_has_pair "$CREATE_LOG_SPLIT" '--assignee' 'bob' && echo 0 || echo 1 )"
check "create(split): the unsplit 'alice,bob' NEVER reached argv as one token" \
	"--assignee passed the comma-list through verbatim (the pre-unification behavior)" \
	"$( argv_has_pair "$CREATE_LOG_SPLIT" '--assignee' 'alice,bob' && echo 1 || echo 0 )"
check "create(split): --project 'A,B' WAS split into its own 'A' token" \
	"--project stopped comma-splitting" \
	"$( argv_has_pair "$CREATE_LOG_SPLIT" '--project' 'A' && echo 0 || echo 1 )"
check "create(split): --project 'A,B' WAS split into its own 'B' token" \
	"--project dropped the second half of the comma-list" \
	"$( argv_has_pair "$CREATE_LOG_SPLIT" '--project' 'B' && echo 0 || echo 1 )"
check "create(split): the unsplit 'A,B' NEVER reached argv as one token" \
	"--project passed the comma-list through verbatim (the pre-unification behavior)" \
	"$( argv_has_pair "$CREATE_LOG_SPLIT" '--project' 'A,B' && echo 1 || echo 0 )"

section "create-issue.sh — --assignee/--project also ACCUMULATE across repeats"
# The other half of the same change: each occurrence is appended to what earlier
# occurrences contributed, so a repeat and a comma-list are interchangeable AND
# combinable. Deliberately the MIXED spelling (one comma-list occurrence plus a
# second plain one) rather than a plain repeat: a plain repeat of each flag is
# already pinned by the create(success) and create(project) sections above, so a
# third copy of it would verify nothing new — whereas splitting AND accumulating
# in the SAME invocation is reachable no other way, and is what a rewrite that
# handles only one of the two would break.
CREATE_LOG_ACCUM="$WORK/create-log-accum"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_URL=https://github.com/octo/repo/issues/8" "GH_STUB_CREATE_LOG=$CREATE_LOG_ACCUM" \
	sh "$CREATE" --repo octo/repo --title x --body-file "$BODY1" \
		--assignee "alice,bob" --assignee carol --project "A,B" --project C
expect_rc "create(accumulate): -> exit 0" 0
check "create(accumulate): --assignee kept 'alice' from the comma-list occurrence" \
	"a later --assignee occurrence REPLACED the earlier one instead of accumulating" \
	"$( argv_has_pair "$CREATE_LOG_ACCUM" '--assignee' 'alice' && echo 0 || echo 1 )"
check "create(accumulate): --assignee kept 'bob' from the comma-list occurrence" \
	"a later --assignee occurrence REPLACED the earlier one instead of accumulating" \
	"$( argv_has_pair "$CREATE_LOG_ACCUM" '--assignee' 'bob' && echo 0 || echo 1 )"
check "create(accumulate): --assignee appended 'carol' from the repeated occurrence" \
	"the repeated --assignee occurrence was dropped" \
	"$( argv_has_pair "$CREATE_LOG_ACCUM" '--assignee' 'carol' && echo 0 || echo 1 )"
check "create(accumulate): --project kept 'A' from the comma-list occurrence" \
	"a later --project occurrence REPLACED the earlier one instead of accumulating" \
	"$( argv_has_pair "$CREATE_LOG_ACCUM" '--project' 'A' && echo 0 || echo 1 )"
check "create(accumulate): --project kept 'B' from the comma-list occurrence" \
	"a later --project occurrence REPLACED the earlier one instead of accumulating" \
	"$( argv_has_pair "$CREATE_LOG_ACCUM" '--project' 'B' && echo 0 || echo 1 )"
check "create(accumulate): --project appended 'C' from the repeated occurrence" \
	"the repeated --project occurrence was dropped" \
	"$( argv_has_pair "$CREATE_LOG_ACCUM" '--project' 'C' && echo 0 || echo 1 )"

section "create-issue.sh — gh issue create itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_RC=1" sh "$CREATE" --repo o/r --title x --body-file "$BODY1"
expect_rc "create(gh-fail): -> exit 1" 1
stderr_has "create(gh-fail): reports failure" "gh issue create failed"

section "create-issue.sh — gh issue create succeeds but returns NO URL"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_URL=" sh "$CREATE" --repo o/r --title x --body-file "$BODY1"
expect_rc "create(no-url): -> exit 1" 1
stderr_has "create(no-url): diagnostic" "returned no URL"

section "create-issue.sh — gh issue create returns a URL with a non-numeric tail"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_URL=https://github.com/octo/repo/issues/not-a-number" \
	sh "$CREATE" --repo o/r --title x --body-file "$BODY1"
expect_rc "create(non-numeric-tail): -> exit 0 (create still succeeded)" 0
stdout_has "create(non-numeric-tail): PM_ISSUE_URL still printed" "PM_ISSUE_URL=https://github.com/octo/repo/issues/not-a-number"
stdout_re "create(non-numeric-tail): PM_ISSUE_NUMBER empty (parse-warn, not a hard failure)" '^PM_ISSUE_NUMBER=$'
stderr_has "create(non-numeric-tail): warns about the unparseable number" "could not parse an issue number"

section "create-issue.sh — adversarial body-file content: the flagship injection-safety proof"
ADVERSARIAL="$WORK/adversarial-body.md"
cat >"$ADVERSARIAL" <<'BODY_EOF'
## Story
As a user, I want the export so that I stop re-keying data.

PM_ARTIFACT_BODY
EOF
this line runs $(whoami) and `id` if the body were ever evaluated as shell
## Out of scope
- nothing else
BODY_EOF
CREATE_LOG4="$WORK/create-log4"
CREATE_RAW4="$WORK/create-raw4"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_URL=https://github.com/octo/repo/issues/99" "GH_STUB_CREATE_LOG=$CREATE_LOG4" \
	"GH_STUB_BODY_FILE_RAW=$CREATE_RAW4" \
	sh "$CREATE" --repo octo/repo --title "adversarial body test" --body-file "$ADVERSARIAL"
expect_rc "create(adversarial): -> exit 0 (the file path carried it, not shell)" 0
stdout_has "create(adversarial): still succeeds normally" "PM_ISSUE_URL=https://github.com/octo/repo/issues/99"

# The authoritative proof: what gh received is BYTE-IDENTICAL to the source
# fixture. This alone subsumes "the delimiter lines survived", "the
# $(...)/backtick line is inert", and "trailing content wasn't truncated" —
# any evaluation, truncation, or reordering would show up as a diff line.
# Deliberately does NOT depend on the live test-runner's actual username (an
# earlier version grepped for `$(whoami)`'s real output, which is both
# unnecessary — the comparison is against the static fixture file, never a
# computed value — and was host-coupled: a coincidental username substring
# could have false-failed the assertion on some machines).
if diff_body_raw "$ADVERSARIAL" "$CREATE_RAW4"; then BODY_DIFF_RC=0; else BODY_DIFF_RC=1; fi
check "create(adversarial): body-file contents reached gh BYTE-IDENTICAL to the source fixture" \
	"$(cat "$WORK/body_raw_diff" 2>/dev/null)" \
	"$BODY_DIFF_RC"

# Pin the MECHANISM, not just the content: a regression to
# `--body "$(cat file)"` would still pass every content assertion above
# (command substitution's OWN output isn't re-evaluated either) — only
# checking the actual argv shape catches that regression.
check "create(adversarial): argv uses --body-file (the injection-safety mechanism)" "no --body-file token in argv" \
	"$( argv_has_token "$CREATE_LOG4" '--body-file' && echo 0 || echo 1 )"
check "create(adversarial): argv has NO bare --body token" "a bare --body flag was found in argv" \
	"$( argv_has_token "$CREATE_LOG4" '--body' && echo 1 || echo 0 )"

section "create-issue.sh — a body-file whose last byte is NOT a newline"
# Every other body fixture in this harness is heredoc- or printf-with-\n-written
# and therefore newline-terminated, so an unterminated file — perfectly legal,
# and what any editor-less generator can emit — went unexercised. It is the one
# shape that breaks a `cat`-based capture in the gh stub: the closing
# BODY_FILE_CONTENTS_END marker glues onto the final content line instead of
# standing alone, which silently corrupts body_block's marker-range extraction
# (it drops that last line) and ARGV_SCOPE's payload suppression (in_payload
# never resets, so payload bytes leak into every argv assertion downstream).
# Built with printf precisely BECAUSE a heredoc always terminates its last line.
NO_EOL_BODY="$WORK/no-trailing-newline-body.md"
printf '## Story\nA final line deliberately left unterminated' >"$NO_EOL_BODY"
CREATE_LOG_NO_EOL="$WORK/create-log-no-eol"
CREATE_RAW_NO_EOL="$WORK/create-raw-no-eol"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CREATE_URL=https://github.com/octo/repo/issues/77" \
	"GH_STUB_CREATE_LOG=$CREATE_LOG_NO_EOL" "GH_STUB_BODY_FILE_RAW=$CREATE_RAW_NO_EOL" \
	sh "$CREATE" --repo octo/repo --title "unterminated body test" --body-file "$NO_EOL_BODY"
expect_rc "create(no-eol body): -> exit 0" 0
if diff_body_raw "$NO_EOL_BODY" "$CREATE_RAW_NO_EOL"; then NO_EOL_DIFF_RC=0; else NO_EOL_DIFF_RC=1; fi
check "create(no-eol body): reached gh BYTE-IDENTICAL, absent trailing newline and all" \
	"$(cat "$WORK/body_raw_diff" 2>/dev/null)" \
	"$NO_EOL_DIFF_RC"
check "create(no-eol body): the stub's BODY_FILE_CONTENTS_END marker stands on its OWN line" \
	"the closing marker was glued onto the unterminated last content line — the log framing is corrupt" \
	"$( line_count_eq "$CREATE_LOG_NO_EOL" 'BODY_FILE_CONTENTS_END' 1 && echo 0 || echo 1 )"
check "create(no-eol body): body_block still extracts the unterminated last line" \
	"the marker-range extraction swallowed the final line" \
	"$( body_block "$CREATE_LOG_NO_EOL" | grep -Fq -- 'A final line deliberately left unterminated' && echo 0 || echo 1 )"

# ===========================================================================
# find-duplicate.sh
# ===========================================================================
section "find-duplicate.sh — usage / argument errors"
run 1 sh "$FINDDUP" -h
expect_rc "finddup(usage): -h -> exit 0" 0
stdout_has "finddup(usage): help text" "Usage:"

run 1 sh "$FINDDUP" --title x
expect_rc "finddup(missing --repo): -> exit 2" 2

run 1 sh "$FINDDUP" --repo o/r
expect_rc "finddup(missing --title/--search): -> exit 2" 2
stderr_has "finddup(missing --title/--search): diagnostic" "--title or --search is required"

run 1 sh "$FINDDUP" --repo o/r --title x --search y
expect_rc "finddup(both --title and --search): -> exit 2" 2
stderr_has "finddup(both): diagnostic" "mutually exclusive"

run 1 sh "$FINDDUP" --repo not-owner-slash-repo --title x
expect_rc "finddup(malformed --repo): -> exit 2" 2
stderr_has "finddup(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$FINDDUP" --repo 'o/..' --title x
expect_rc "finddup(malformed --repo, dot-segment): -> exit 2" 2
stderr_has "finddup(malformed --repo, dot-segment): diagnostic" "OWNER/REPO"

run 1 sh "$FINDDUP" --bogus
expect_rc "finddup(unknown option): -> exit 2" 2
stderr_has "finddup(unknown option): diagnostic" "unknown option"

section "find-duplicate.sh — gh absent / not authenticated"
run 0 sh "$FINDDUP" --repo o/r --title x
expect_rc "finddup(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$FINDDUP" --repo o/r --title x
expect_rc "finddup(unauth): -> exit 1" 1

section "find-duplicate.sh — hit (duplicates found)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_SEARCH_URLS=https://github.com/o/r/issues/1
https://github.com/o/r/issues/2" \
	sh "$FINDDUP" --repo o/r --title "export to csv"
expect_rc "finddup(hit): -> exit 0" 0
stdout_has "finddup(hit): count 2" "PM_DUPLICATE_COUNT=2"
stdout_has "finddup(hit): urls include #1" "issues/1"
stdout_has "finddup(hit): urls include #2" "issues/2"

section "find-duplicate.sh — miss (no duplicates)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_SEARCH_URLS=" sh "$FINDDUP" --repo o/r --search "csv export"
expect_rc "finddup(miss): -> exit 0 (zero is not a failure)" 0
stdout_has "finddup(miss): count 0" "PM_DUPLICATE_COUNT=0"
stdout_re "finddup(miss): urls empty" '^PM_DUPLICATE_URLS=$'

section "find-duplicate.sh — composed query reaches gh verbatim (--title mode)"
LIST_LOG1="$WORK/list-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_SEARCH_URLS=" "GH_STUB_LIST_LOG=$LIST_LOG1" \
	sh "$FINDDUP" --repo octo/repo --title "export to csv"
expect_rc "finddup(query-title): -> exit 0" 0
check "finddup(query-title): --repo octo/repo passed as one token" "--repo octo/repo missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--repo' 'octo/repo' && echo 0 || echo 1 )"
check "finddup(query-title): --state all passed as one token" "--state all missing/misplaced in argv" \
	"$( argv_has_pair "$LIST_LOG1" '--state' 'all' && echo 0 || echo 1 )"
check "finddup(query-title): --search composed as ONE token 'export to csv in:title'" \
	"a word-split --search value would show as separate argv lines, not one token" \
	"$( argv_has_pair "$LIST_LOG1" '--search' 'export to csv in:title' && echo 0 || echo 1 )"

section "find-duplicate.sh — composed query reaches gh verbatim (--search mode)"
LIST_LOG2="$WORK/list-log2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_SEARCH_URLS=" "GH_STUB_LIST_LOG=$LIST_LOG2" \
	sh "$FINDDUP" --repo octo/repo --search "csv export tool"
expect_rc "finddup(query-search): -> exit 0" 0
check "finddup(query-search): --search composed as ONE token 'csv export tool in:title'" \
	"a word-split --search value would show as separate argv lines, not one token" \
	"$( argv_has_pair "$LIST_LOG2" '--search' 'csv export tool in:title' && echo 0 || echo 1 )"

section "find-duplicate.sh — gh query itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LIST_RC=1" sh "$FINDDUP" --repo o/r --title x
expect_rc "finddup(gh-fail): -> exit 1" 1
stderr_has "finddup(gh-fail): reports failure" "gh issue list failed"

# ===========================================================================
# link-children.sh
# ===========================================================================
section "link-children.sh — usage / argument errors"
run 1 sh "$LINKKIDS" -h
expect_rc "linkkids(usage): -h -> exit 0" 0
stdout_has "linkkids(usage): help text" "Usage:"

run 1 sh "$LINKKIDS" --epic 1 --child 2
expect_rc "linkkids(missing --repo): -> exit 2" 2

run 1 sh "$LINKKIDS" --repo o/r --child 2
expect_rc "linkkids(missing --epic): -> exit 2" 2

run 1 sh "$LINKKIDS" --repo o/r --epic 1
expect_rc "linkkids(missing --child): -> exit 2" 2
stderr_has "linkkids(missing --child): diagnostic" "at least one --child is required"

run 1 sh "$LINKKIDS" --repo o/r --epic abc --child 2
expect_rc "linkkids(non-numeric --epic): -> exit 2" 2

run 1 sh "$LINKKIDS" --repo o/r --epic 1 --child abc
expect_rc "linkkids(non-numeric --child): -> exit 2" 2

# CONS-005: digits-only is NOT enough. A bare '0' is not a positive number and a
# leading-zero form is not the number GitHub echoes back, so both must be the
# usage error (exit 2) this script's header documents rather than a raw `gh`
# failure (exit 1). `--child 0` is the worse of the two: it used to SPLICE a dead
# "- [ ] #0" line into the epic and report PM_LINKED=1 — a silently WRONG outcome —
# while `--child 007` would have linked issue 7. Same guard, same wording as the
# GitLab sibling's.
KIDS_EDIT_LOG_ZERO="$WORK/kids-edit-log-zero"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_ARGV_LOG=$KIDS_EDIT_LOG_ZERO" \
	sh "$LINKKIDS" --repo o/r --epic 10 --child 0
expect_rc "linkkids(--child 0): -> exit 2, not a raw gh failure" 2
stderr_has "linkkids(--child 0): diagnostic" "--child must be a positive integer"
file_missing "linkkids(--child 0): the epic was never edited with a dead '#0' link" "$KIDS_EDIT_LOG_ZERO"

run 1 sh "$LINKKIDS" --repo o/r --epic 10 --child 007
expect_rc "linkkids(--child 007): -> exit 2 (007 would have linked issue 7)" 2
stderr_has "linkkids(--child 007): diagnostic" "--child must be a positive integer"

run 1 sh "$LINKKIDS" --repo o/r --epic 0 --child 2
expect_rc "linkkids(--epic 0): -> exit 2" 2
stderr_has "linkkids(--epic 0): diagnostic" "positive integer"

run 1 sh "$LINKKIDS" --repo o/r --epic 007 --child 2
expect_rc "linkkids(--epic 007): -> exit 2" 2
stderr_has "linkkids(--epic 007): diagnostic" "positive integer"

run 1 sh "$LINKKIDS" --repo not-owner-slash-repo --epic 1 --child 2
expect_rc "linkkids(malformed --repo): -> exit 2" 2
stderr_has "linkkids(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$LINKKIDS" --repo 'o/..' --epic 1 --child 2
expect_rc "linkkids(malformed --repo, dot-segment): -> exit 2" 2
stderr_has "linkkids(malformed --repo, dot-segment): diagnostic" "OWNER/REPO"

run 1 sh "$LINKKIDS" --bogus
expect_rc "linkkids(unknown option): -> exit 2" 2
stderr_has "linkkids(unknown option): diagnostic" "unknown option"

section "link-children.sh — gh absent / not authenticated"
run 0 sh "$LINKKIDS" --repo o/r --epic 1 --child 2
expect_rc "linkkids(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$LINKKIDS" --repo o/r --epic 1 --child 2
expect_rc "linkkids(unauth): -> exit 1" 1

section "link-children.sh — happy path (two new children)"
EDIT_LOG1="$WORK/edit-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_BODY=## Outcome
Ship CSV export." "GH_STUB_EDIT_LOG=$EDIT_LOG1" \
	sh "$LINKKIDS" --repo octo/repo --epic 10 --child 11 --child 12
expect_rc "linkkids(happy): -> exit 0" 0
stdout_has "linkkids(happy): PM_LINKED=2" "PM_LINKED=2"
check "linkkids(happy): original body preserved" "original content lost" \
	"$( [ -f "$EDIT_LOG1" ] && grep -Fq 'Ship CSV export.' "$EDIT_LOG1" && echo 0 || echo 1 )"
check "linkkids(happy): child 11 appended exactly once" "expected exactly one '- [ ] #11' line" \
	"$( line_count_eq "$EDIT_LOG1" '- [ ] #11' 1 && echo 0 || echo 1 )"
check "linkkids(happy): child 12 appended exactly once" "expected exactly one '- [ ] #12' line" \
	"$( line_count_eq "$EDIT_LOG1" '- [ ] #12' 1 && echo 0 || echo 1 )"

section "link-children.sh — idempotent (one already linked, one new)"
EDIT_LOG2="$WORK/edit-log2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_BODY=## Outcome
Ship CSV export.

## Linked children
- [ ] #11" "GH_STUB_EDIT_LOG=$EDIT_LOG2" \
	sh "$LINKKIDS" --repo octo/repo --epic 10 --child 11 --child 13
expect_rc "linkkids(idempotent): -> exit 0" 0
stdout_has "linkkids(idempotent): PM_LINKED=1 (only the new child counted)" "PM_LINKED=1"
check "linkkids(idempotent): child 13 appended exactly once" "expected exactly one '- [ ] #13' line" \
	"$( line_count_eq "$EDIT_LOG2" '- [ ] #13' 1 && echo 0 || echo 1 )"
check "linkkids(idempotent): child 11 still appears exactly once (not duplicated)" "expected exactly one '- [ ] #11' line" \
	"$( line_count_eq "$EDIT_LOG2" '- [ ] #11' 1 && echo 0 || echo 1 )"

section "link-children.sh — idempotent regardless of checkbox state"
EDIT_LOG7="$WORK/edit-log7"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_BODY=## Linked children
- [x] #11" "GH_STUB_EDIT_LOG=$EDIT_LOG7" \
	sh "$LINKKIDS" --repo octo/repo --epic 10 --child 11 --child 14
expect_rc "linkkids(checked-box): -> exit 0" 0
stdout_has "linkkids(checked-box): PM_LINKED=1 (checked #11 not re-counted)" "PM_LINKED=1"
check "linkkids(checked-box): checked #11 NOT duplicated as an unchecked line" "an unwanted duplicate '- [ ] #11' line was appended" \
	"$( line_count_eq "$EDIT_LOG7" '- [ ] #11' 0 && echo 0 || echo 1 )"
check "linkkids(checked-box): #11 still appears exactly once, still checked" "expected exactly one '- [x] #11' line" \
	"$( line_count_eq "$EDIT_LOG7" '- [x] #11' 1 && echo 0 || echo 1 )"
check "linkkids(checked-box): child 14 appended exactly once" "expected exactly one '- [ ] #14' line" \
	"$( line_count_eq "$EDIT_LOG7" '- [ ] #14' 1 && echo 0 || echo 1 )"

section "link-children.sh — heading exists but is NOT the last section"
EDIT_LOG8="$WORK/edit-log8"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_BODY=## Outcome
Ship it.

## Linked children
- [ ] #11

## Non-goals
- nothing else" "GH_STUB_EDIT_LOG=$EDIT_LOG8" \
	sh "$LINKKIDS" --repo octo/repo --epic 10 --child 12
expect_rc "linkkids(mid-doc-heading): -> exit 0" 0
stdout_has "linkkids(mid-doc-heading): PM_LINKED=1" "PM_LINKED=1"
check "linkkids(mid-doc-heading): child 12 appended exactly once" "expected exactly one '- [ ] #12' line" \
	"$( line_count_eq "$EDIT_LOG8" '- [ ] #12' 1 && echo 0 || echo 1 )"
check "linkkids(mid-doc-heading): '## Non-goals' still follows the checklist (not orphaned above it)" \
	"the new line landed at EOF, below '## Non-goals', instead of under '## Linked children'" \
	"$( awk '/^- \[ \] #12$/{c=NR} /^## Non-goals$/{g=NR} END{exit(c>0 && g>c ? 0 : 1)}' "$EDIT_LOG8" && echo 0 || echo 1 )"
check "linkkids(mid-doc-heading): heading not duplicated" "expected exactly one '## Linked children' line" \
	"$( line_count_eq "$EDIT_LOG8" '## Linked children' 1 && echo 0 || echo 1 )"

section "link-children.sh — duplicate --child arguments are linked at most once"
EDIT_LOG9="$WORK/edit-log9"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_BODY=## Outcome
Ship it." "GH_STUB_EDIT_LOG=$EDIT_LOG9" \
	sh "$LINKKIDS" --repo octo/repo --epic 10 --child 11 --child 11
expect_rc "linkkids(dup-child-arg): -> exit 0" 0
stdout_has "linkkids(dup-child-arg): PM_LINKED=1 (not inflated by the duplicate arg)" "PM_LINKED=1"
check "linkkids(dup-child-arg): #11 appended exactly once, not twice" "expected exactly one '- [ ] #11' line" \
	"$( line_count_eq "$EDIT_LOG9" '- [ ] #11' 1 && echo 0 || echo 1 )"

section "link-children.sh — already fully linked (no-op, no gh edit call)"
EDIT_LOG3="$WORK/edit-log3"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_BODY=## Linked children
- [ ] #11" "GH_STUB_EDIT_LOG=$EDIT_LOG3" \
	sh "$LINKKIDS" --repo octo/repo --epic 10 --child 11
expect_rc "linkkids(no-op): -> exit 0" 0
stdout_has "linkkids(no-op): PM_LINKED=0" "PM_LINKED=0"
file_missing "linkkids(no-op): gh issue edit never invoked" "$EDIT_LOG3"

section "link-children.sh — epic not found"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_RC=1" sh "$LINKKIDS" --repo o/r --epic 999 --child 1
expect_rc "linkkids(epic-not-found): -> exit 1" 1
stderr_has "linkkids(epic-not-found): diagnostic" "could not read epic"

section "link-children.sh — gh issue edit itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_VIEW_BODY=body" "GH_STUB_EDIT_RC=1" \
	sh "$LINKKIDS" --repo o/r --epic 10 --child 1
expect_rc "linkkids(edit-fail): -> exit 1" 1
stderr_has "linkkids(edit-fail): reports failure" "gh issue edit failed"

# ===========================================================================
# ensure-labels.sh
# ===========================================================================
section "ensure-labels.sh — usage / argument errors"
run 1 sh "$ENSURELABELS" -h
expect_rc "ensurelabels(usage): -h -> exit 0" 0
stdout_has "ensurelabels(usage): help text" "Usage:"

run 1 sh "$ENSURELABELS" --label bug
expect_rc "ensurelabels(missing --repo): -> exit 2" 2
stderr_has "ensurelabels(missing --repo): diagnostic" "--repo is required"

run 1 sh "$ENSURELABELS" --repo o/r
expect_rc "ensurelabels(missing --label): -> exit 2" 2
stderr_has "ensurelabels(missing --label): diagnostic" "at least one --label is required"

run 1 sh "$ENSURELABELS" --repo 'o/..' --label bug
expect_rc "ensurelabels(malformed --repo): -> exit 2" 2
stderr_has "ensurelabels(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$ENSURELABELS" --repo o/r --label bug --color zzzzzz
expect_rc "ensurelabels(invalid --color): -> exit 2" 2
stderr_has "ensurelabels(invalid --color): diagnostic" "6 hex digits"

run 1 sh "$ENSURELABELS" --bogus
expect_rc "ensurelabels(unknown option): -> exit 2" 2
stderr_has "ensurelabels(unknown option): diagnostic" "unknown option"

section "ensure-labels.sh — gh absent / not authenticated (fail-closed)"
run 0 sh "$ENSURELABELS" --repo o/r --label bug
expect_rc "ensurelabels(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$ENSURELABELS" --repo o/r --label bug
expect_rc "ensurelabels(unauth): -> exit 1" 1
stderr_has "ensurelabels(unauth): diagnostic" "not authenticated"

section "ensure-labels.sh — gh api (labels lookup) itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_API_RC=1" sh "$ENSURELABELS" --repo o/r --label bug
expect_rc "ensurelabels(api-fail): -> exit 1" 1
stderr_has "ensurelabels(api-fail): reports failure" "failed to look up labels"

section "ensure-labels.sh — creates only missing labels, idempotent across duplicates"
LABEL_LOG1="$WORK/label-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LABELS=type:story" "GH_STUB_LABEL_CREATE_LOG=$LABEL_LOG1" \
	sh "$ENSURELABELS" --repo octo/repo --label "type:story,area:billing" --label "area:billing" \
		--color ff0000 --description "auto-created"
expect_rc "ensurelabels(idempotent): -> exit 0" 0
stdout_has "ensurelabels(idempotent): created only area:billing" "PM_LABELS_CREATED=area:billing"
stdout_has "ensurelabels(idempotent): existing reports type:story" "PM_LABELS_EXISTING=type:story"
check "ensurelabels(idempotent): exactly ONE gh label create call (deduped)" "expected exactly one ARGV_BEGIN block" \
	"$( [ "$(grep -Fxc -- 'ARGV_BEGIN' "$LABEL_LOG1")" -eq 1 ] && echo 0 || echo 1 )"
check "ensurelabels(idempotent): --color passed as one token" "color missing/misplaced in argv" \
	"$( argv_has_pair "$LABEL_LOG1" '--color' 'ff0000' && echo 0 || echo 1 )"
check "ensurelabels(idempotent): --description passed as one token" "description missing/misplaced in argv" \
	"$( argv_has_pair "$LABEL_LOG1" '--description' 'auto-created' && echo 0 || echo 1 )"

section "ensure-labels.sh — adversarial label name reaches gh verbatim and inert"
LABEL_LOG2="$WORK/label-log2"
# shellcheck disable=SC2016  # deliberate: the single-quoted $(...)/`...` text is
# the literal adversarial label we assert was NEVER expanded — quoting it any
# other way would defeat the assertion.
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LABELS=" "GH_STUB_LABEL_CREATE_LOG=$LABEL_LOG2" \
	sh "$ENSURELABELS" --repo octo/repo --label '$(whoami) `id`'
expect_rc "ensurelabels(adversarial-label): -> exit 0" 0
# shellcheck disable=SC2016  # same deliberate literal as above
stdout_has "ensurelabels(adversarial-label): reported created verbatim" 'PM_LABELS_CREATED=$(whoami) `id`'
# shellcheck disable=SC2016  # same deliberate literal as above
check "ensurelabels(adversarial-label): the literal label text reached gh's argv (inert, never evaluated)" \
	"literal \$(whoami)/backtick label text missing from gh's logged argv" \
	"$( argv_has_token "$LABEL_LOG2" '$(whoami) `id`' && echo 0 || echo 1 )"

section "ensure-labels.sh — a create failure is best-effort, not all-or-nothing"
LABEL_LOG3="$WORK/label-log3"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LABELS=" "GH_STUB_LABEL_CREATE_RC=1" "GH_STUB_LABEL_CREATE_LOG=$LABEL_LOG3" \
	sh "$ENSURELABELS" --repo o/r --label "bug,feature"
expect_rc "ensurelabels(create-fail): -> exit 1" 1
stderr_has "ensurelabels(create-fail): reports which label failed" "failed to create label 'bug'"
check "ensurelabels(create-fail): both create calls were still attempted" "expected 2 ARGV_BEGIN blocks (best-effort, not abort-on-first-failure)" \
	"$( [ "$(grep -Fxc -- 'ARGV_BEGIN' "$LABEL_LOG3")" -eq 2 ] && echo 0 || echo 1 )"

section "ensure-labels.sh — the flagship MIXED case: one label fails, the other still succeeds"
LABEL_LOG4="$WORK/label-log4"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_LABELS=" "GH_STUB_LABEL_CREATE_FAIL_LIST=feature" "GH_STUB_LABEL_CREATE_LOG=$LABEL_LOG4" \
	sh "$ENSURELABELS" --repo o/r --label "bug,feature"
expect_rc "ensurelabels(mixed): -> exit 1 (the one failure taints the exit code)" 1
stdout_has "ensurelabels(mixed): the SUCCEEDING label is still reported created" "PM_LABELS_CREATED=bug"
stdout_re "ensurelabels(mixed): PM_LABELS_EXISTING is empty (neither label pre-existed)" '^PM_LABELS_EXISTING=$'
stderr_has "ensurelabels(mixed): names the ONE label that failed" "failed to create label 'feature'"
check "ensurelabels(mixed): 'bug' create call was NOT also reported as failed" "the succeeding label's create was unexpectedly flagged as failed" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- "failed to create label 'bug'" && echo 1 || echo 0 )"
check "ensurelabels(mixed): both create calls were attempted (best-effort continues past the failure)" "expected 2 ARGV_BEGIN blocks" \
	"$( [ "$(grep -Fxc -- 'ARGV_BEGIN' "$LABEL_LOG4")" -eq 2 ] && echo 0 || echo 1 )"

# ===========================================================================
# comment.sh
# ===========================================================================
section "comment.sh — usage / argument errors"
run 1 sh "$COMMENT" -h
expect_rc "comment(usage): -h -> exit 0" 0
stdout_has "comment(usage): help text" "Usage:"

CBODY="$WORK/comment-body.md"
printf 'Thanks for the report!\n' >"$CBODY"

run 1 sh "$COMMENT" --issue 1 --body-file "$CBODY"
expect_rc "comment(missing --repo): -> exit 2" 2

run 1 sh "$COMMENT" --repo o/r --body-file "$CBODY"
expect_rc "comment(missing --issue): -> exit 2" 2

run 1 sh "$COMMENT" --repo o/r --issue 1
expect_rc "comment(missing --body-file): -> exit 2" 2

run 1 sh "$COMMENT" --repo o/r --issue abc --body-file "$CBODY"
expect_rc "comment(non-numeric --issue): -> exit 2" 2

# CONS-005 — see the link-children.sh block above for the rationale. Digits-only
# let '0' and '007' through to `gh` as a raw failure (exit 1) instead of the usage
# error (exit 2) this script's header documents.
COMMENT_LOG_ZERO="$WORK/comment-log-zero"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_LOG=$COMMENT_LOG_ZERO" \
	sh "$COMMENT" --repo o/r --issue 0 --body-file "$CBODY"
expect_rc "comment(--issue 0): -> exit 2, not a raw gh failure" 2
stderr_has "comment(--issue 0): diagnostic" "positive integer"
file_missing "comment(--issue 0): gh issue comment never invoked" "$COMMENT_LOG_ZERO"

run 1 sh "$COMMENT" --repo o/r --issue 007 --body-file "$CBODY"
expect_rc "comment(--issue 007): -> exit 2 (007 is not the number GitHub echoes back)" 2
stderr_has "comment(--issue 007): diagnostic" "positive integer"

run 1 sh "$COMMENT" --repo o/r --issue 1 --body-file "$WORK/does-not-exist"
expect_rc "comment(nonexistent body-file): -> exit 2" 2

run 1 sh "$COMMENT" --repo 'o/..' --issue 1 --body-file "$CBODY"
expect_rc "comment(malformed --repo): -> exit 2" 2
stderr_has "comment(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$COMMENT" --bogus
expect_rc "comment(unknown option): -> exit 2" 2
stderr_has "comment(unknown option): diagnostic" "unknown option"

section "comment.sh — gh absent / not authenticated"
run 0 sh "$COMMENT" --repo o/r --issue 1 --body-file "$CBODY"
expect_rc "comment(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$COMMENT" --repo o/r --issue 1 --body-file "$CBODY"
expect_rc "comment(unauth): -> exit 1" 1

section "comment.sh — successful comment"
COMMENT_LOG1="$WORK/comment-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_URL=https://github.com/octo/repo/issues/1#issuecomment-42" "GH_STUB_COMMENT_LOG=$COMMENT_LOG1" \
	sh "$COMMENT" --repo octo/repo --issue 1 --body-file "$CBODY"
expect_rc "comment(success): -> exit 0" 0
stdout_has "comment(success): PM_COMMENT_URL" "PM_COMMENT_URL=https://github.com/octo/repo/issues/1#issuecomment-42"
check "comment(success): argv uses --body-file" "no --body-file token in argv" \
	"$( argv_has_token "$COMMENT_LOG1" '--body-file' && echo 0 || echo 1 )"
check "comment(success): argv has NO bare --body token" "a bare --body flag was found in argv" \
	"$( argv_has_token "$COMMENT_LOG1" '--body' && echo 1 || echo 0 )"

section "comment.sh — successful comment with NO URL returned (still success)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_URL=" sh "$COMMENT" --repo o/r --issue 1 --body-file "$CBODY"
expect_rc "comment(empty-url): -> exit 0 (the URL is a courtesy, not proof of success)" 0
stdout_re "comment(empty-url): PM_COMMENT_URL is empty" '^PM_COMMENT_URL=$'

section "comment.sh — gh issue comment itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_RC=1" sh "$COMMENT" --repo o/r --issue 1 --body-file "$CBODY"
expect_rc "comment(gh-fail): -> exit 1" 1
stderr_has "comment(gh-fail): reports failure" "gh issue comment failed"

section "comment.sh — adversarial body-file content stays inert (golden-diff)"
CADVERSARIAL="$WORK/comment-adversarial.md"
cat >"$CADVERSARIAL" <<'BODY_EOF'
Thanks for the report.

PM_ARTIFACT_BODY
EOF
this line runs $(whoami) and `id` if the body were ever evaluated as shell
Closing as a duplicate of #4.
BODY_EOF
COMMENT_LOG2="$WORK/comment-log2"
COMMENT_RAW2="$WORK/comment-raw2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_URL=https://github.com/octo/repo/issues/1#issuecomment-99" "GH_STUB_COMMENT_LOG=$COMMENT_LOG2" \
	"GH_STUB_BODY_FILE_RAW=$COMMENT_RAW2" \
	sh "$COMMENT" --repo octo/repo --issue 1 --body-file "$CADVERSARIAL"
expect_rc "comment(adversarial): -> exit 0" 0
if diff_body_raw "$CADVERSARIAL" "$COMMENT_RAW2"; then COMMENT_DIFF_RC=0; else COMMENT_DIFF_RC=1; fi
check "comment(adversarial): body-file contents reached gh BYTE-IDENTICAL to the source fixture" \
	"$(cat "$WORK/body_raw_diff" 2>/dev/null)" \
	"$COMMENT_DIFF_RC"

# ===========================================================================
# update-issue.sh
# ===========================================================================
section "update-issue.sh — usage / argument errors"
run 1 sh "$UPDATE" -h
expect_rc "update(usage): -h -> exit 0" 0
stdout_has "update(usage): help text" "Usage:"

run 1 sh "$UPDATE" --issue 1 --title x
expect_rc "update(missing --repo): -> exit 2" 2

run 1 sh "$UPDATE" --repo o/r --title x
expect_rc "update(missing --issue): -> exit 2" 2

run 1 sh "$UPDATE" --repo o/r --issue abc --title x
expect_rc "update(non-numeric --issue): -> exit 2" 2

# CONS-005 — see the link-children.sh block above for the rationale.
UPDATE_ARGV_LOG_ZERO="$WORK/update-argv-log-zero"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_ARGV_LOG=$UPDATE_ARGV_LOG_ZERO" \
	sh "$UPDATE" --repo o/r --issue 0 --title x
expect_rc "update(--issue 0): -> exit 2, not a raw gh failure" 2
stderr_has "update(--issue 0): diagnostic" "positive integer"
file_missing "update(--issue 0): gh issue edit never invoked" "$UPDATE_ARGV_LOG_ZERO"

run 1 sh "$UPDATE" --repo o/r --issue 007 --title x
expect_rc "update(--issue 007): -> exit 2 (007 is not the number GitHub echoes back)" 2
stderr_has "update(--issue 007): diagnostic" "positive integer"

run 1 sh "$UPDATE" --repo o/r --issue 1
expect_rc "update(no fields given): -> exit 2" 2
stderr_has "update(no fields given): diagnostic" "at least one field to change is required"

run 1 sh "$UPDATE" --repo o/r --issue 1 --body-file "$WORK/does-not-exist"
expect_rc "update(nonexistent body-file): -> exit 2" 2

run 1 sh "$UPDATE" --repo 'o/..' --issue 1 --title x
expect_rc "update(malformed --repo): -> exit 2" 2
stderr_has "update(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$UPDATE" --bogus
expect_rc "update(unknown option): -> exit 2" 2
stderr_has "update(unknown option): diagnostic" "unknown option"

section "update-issue.sh — gh absent / not authenticated"
run 0 sh "$UPDATE" --repo o/r --issue 1 --title x
expect_rc "update(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$UPDATE" --repo o/r --issue 1 --title x
expect_rc "update(unauth): -> exit 1" 1

section "update-issue.sh — body NOT clobbered when --body-file omitted"
UPDATE_ARGV_LOG1="$WORK/update-argv-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=https://github.com/octo/repo/issues/5" "GH_STUB_EDIT_ARGV_LOG=$UPDATE_ARGV_LOG1" \
	sh "$UPDATE" --repo octo/repo --issue 5 --title "renamed" --add-label "bug,urgent" \
		--remove-label stale --add-assignee alice --remove-assignee bob --milestone "Q3"
expect_rc "update(no-body-clobber): -> exit 0" 0
stdout_has "update(no-body-clobber): PM_ISSUE_URL" "PM_ISSUE_URL=https://github.com/octo/repo/issues/5"
check "update(no-body-clobber): argv has NO --body-file token" "a --body-file token was found even though none was given — this would CLOBBER the body" \
	"$( argv_has_token "$UPDATE_ARGV_LOG1" '--body-file' && echo 1 || echo 0 )"
check "update(no-body-clobber): argv has NO bare --body token either" "a bare --body flag was found" \
	"$( argv_has_token "$UPDATE_ARGV_LOG1" '--body' && echo 1 || echo 0 )"
check "update(no-body-clobber): --title passed as one token" "title missing/misplaced in argv" \
	"$( argv_has_pair "$UPDATE_ARGV_LOG1" '--title' 'renamed' && echo 0 || echo 1 )"
check "update(no-body-clobber): --add-label bug passed" "add-label bug missing from argv" \
	"$( argv_has_pair "$UPDATE_ARGV_LOG1" '--add-label' 'bug' && echo 0 || echo 1 )"
check "update(no-body-clobber): --add-label urgent passed" "add-label urgent missing from argv" \
	"$( argv_has_pair "$UPDATE_ARGV_LOG1" '--add-label' 'urgent' && echo 0 || echo 1 )"
check "update(no-body-clobber): --remove-label stale passed" "remove-label missing from argv" \
	"$( argv_has_pair "$UPDATE_ARGV_LOG1" '--remove-label' 'stale' && echo 0 || echo 1 )"
check "update(no-body-clobber): --add-assignee alice passed" "add-assignee missing from argv" \
	"$( argv_has_pair "$UPDATE_ARGV_LOG1" '--add-assignee' 'alice' && echo 0 || echo 1 )"
check "update(no-body-clobber): --remove-assignee bob passed" "remove-assignee missing from argv" \
	"$( argv_has_pair "$UPDATE_ARGV_LOG1" '--remove-assignee' 'bob' && echo 0 || echo 1 )"
check "update(no-body-clobber): --milestone Q3 passed" "milestone missing from argv" \
	"$( argv_has_pair "$UPDATE_ARGV_LOG1" '--milestone' 'Q3' && echo 0 || echo 1 )"

section "update-issue.sh — body IS replaced when --body-file is given"
UBODY="$WORK/update-body.md"
printf '## Updated\nNew content.\n' >"$UBODY"
UPDATE_ARGV_LOG2="$WORK/update-argv-log2"
UPDATE_BODY_LOG2="$WORK/update-body-log2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=https://github.com/octo/repo/issues/5" \
	"GH_STUB_EDIT_ARGV_LOG=$UPDATE_ARGV_LOG2" "GH_STUB_EDIT_LOG=$UPDATE_BODY_LOG2" \
	sh "$UPDATE" --repo octo/repo --issue 5 --body-file "$UBODY"
expect_rc "update(body-replace): -> exit 0" 0
check "update(body-replace): argv HAS --body-file token" "expected a --body-file token in argv" \
	"$( argv_has_token "$UPDATE_ARGV_LOG2" '--body-file' && echo 0 || echo 1 )"
check "update(body-replace): body-file contents relayed verbatim" "body content missing" \
	"$( grep -Fq -- '## Updated' "$UPDATE_BODY_LOG2" && echo 0 || echo 1 )"

section "update-issue.sh — comma-list trimming and empty-skip"
# The update-side twin of create's csv-trim section above: add_add_label routes
# through split_csv_list, whose trim + empty-skip had no fixture exercising them
# in this harness.
UPDATE_LOG_TRIM="$WORK/update-log-trim"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=https://github.com/octo/repo/issues/5" \
	"GH_STUB_EDIT_ARGV_LOG=$UPDATE_LOG_TRIM" \
	sh "$UPDATE" --repo octo/repo --issue 5 --add-label "bug, urgent ,,"
expect_rc "update(csv trim): -> exit 0" 0
check "update(csv trim): 'bug' arrived clean" "the first token was mangled" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--add-label' 'bug' && echo 0 || echo 1 )"
check "update(csv trim): ' urgent ' arrived TRIMMED to 'urgent'" "surrounding whitespace was not trimmed" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--add-label' 'urgent' && echo 0 || echo 1 )"
check "update(csv trim): the UNTRIMMED ' urgent ' never reached argv" "an untrimmed token was passed to gh" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--add-label' ' urgent ' && echo 1 || echo 0 )"
check "update(csv trim): the empty elements produced NO empty --add-label value" "an empty label value was passed to gh" \
	"$( argv_has_pair "$UPDATE_LOG_TRIM" '--add-label' '' && echo 1 || echo 0 )"

section "update-issue.sh — --add-assignee DOES comma-split (the update half of the unified behavior)"
# The update-side twin of create-issue.sh's split section: the very same
# comma-list, handed to --add-assignee, is split into separate argv tokens. Both
# ends now agree — every caller-facing list flag in this skill splits — so this
# pins the update half of that uniformity: a change that reverted only this flag
# to a verbatim append would leave create's section green and this one red.
UPDATE_LOG_SPLIT="$WORK/update-log-split"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=https://github.com/octo/repo/issues/5" \
	"GH_STUB_EDIT_ARGV_LOG=$UPDATE_LOG_SPLIT" \
	sh "$UPDATE" --repo octo/repo --issue 5 --add-assignee "alice,bob"
expect_rc "update(assignee-split): -> exit 0" 0
check "update(assignee-split): --add-assignee 'alice,bob' WAS split into 'alice'" \
	"--add-assignee stopped comma-splitting" \
	"$( argv_has_pair "$UPDATE_LOG_SPLIT" '--add-assignee' 'alice' && echo 0 || echo 1 )"
check "update(assignee-split): --add-assignee 'alice,bob' WAS split into 'bob'" \
	"--add-assignee stopped comma-splitting" \
	"$( argv_has_pair "$UPDATE_LOG_SPLIT" '--add-assignee' 'bob' && echo 0 || echo 1 )"
check "update(assignee-split): the unsplit 'alice,bob' never reached argv" \
	"--add-assignee passed the comma-list through verbatim" \
	"$( argv_has_pair "$UPDATE_LOG_SPLIT" '--add-assignee' 'alice,bob' && echo 1 || echo 0 )"

section "update-issue.sh — gh issue edit itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_RC=1" sh "$UPDATE" --repo o/r --issue 1 --title x
expect_rc "update(gh-fail): -> exit 1" 1
stderr_has "update(gh-fail): reports failure" "gh issue edit failed"

section "update-issue.sh — gh issue edit succeeds but returns NO URL"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_EDIT_URL=" sh "$UPDATE" --repo o/r --issue 1 --title x
expect_rc "update(no-url): -> exit 1" 1
stderr_has "update(no-url): diagnostic" "returned no URL"

# ===========================================================================
# close-issue.sh
# ===========================================================================
section "close-issue.sh — usage / argument errors"
run 1 sh "$CLOSE" -h
expect_rc "close(usage): -h -> exit 0" 0
stdout_has "close(usage): help text" "Usage:"

run 1 sh "$CLOSE" --issue 1
expect_rc "close(missing --repo): -> exit 2" 2

run 1 sh "$CLOSE" --repo o/r
expect_rc "close(missing --issue): -> exit 2" 2

run 1 sh "$CLOSE" --repo o/r --issue abc
expect_rc "close(non-numeric --issue): -> exit 2" 2

# CONS-005 — see the link-children.sh block above for the rationale. BOTH writes
# this script can make are asserted absent: the close AND the optional preceding
# comment, so a rejected iid cannot leave a comment behind on issue 0.
CLOSE_LOG_ZERO="$WORK/close-log-zero"
CLOSE_COMMENT_LOG_ZERO="$WORK/close-comment-log-zero"
# Its OWN fixture, not the comment.sh section's $CBODY: this section must not
# depend on a file another section happens to create above it (see the harness
# header on shared fixtures created far from their consumers).
CLOSE_ZERO_COMMENT="$WORK/close-zero-comment.md"
printf 'Closing as done.\n' >"$CLOSE_ZERO_COMMENT"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CLOSE_LOG=$CLOSE_LOG_ZERO" "GH_STUB_COMMENT_LOG=$CLOSE_COMMENT_LOG_ZERO" \
	sh "$CLOSE" --repo o/r --issue 0 --comment-file "$CLOSE_ZERO_COMMENT"
expect_rc "close(--issue 0): -> exit 2, not a raw gh failure" 2
stderr_has "close(--issue 0): diagnostic" "positive integer"
file_missing "close(--issue 0): gh issue close never invoked" "$CLOSE_LOG_ZERO"
file_missing "close(--issue 0): no closing comment was posted either" "$CLOSE_COMMENT_LOG_ZERO"

run 1 sh "$CLOSE" --repo o/r --issue 007
expect_rc "close(--issue 007): -> exit 2 (007 is not the number GitHub echoes back)" 2
stderr_has "close(--issue 007): diagnostic" "positive integer"

run 1 sh "$CLOSE" --repo o/r --issue 1 --reason wontfix
expect_rc "close(invalid --reason): -> exit 2" 2
stderr_has "close(invalid --reason): diagnostic" "completed"

run 1 sh "$CLOSE" --repo o/r --issue 1 --comment-file "$WORK/does-not-exist"
expect_rc "close(nonexistent comment-file): -> exit 2" 2

run 1 sh "$CLOSE" --repo 'o/..' --issue 1
expect_rc "close(malformed --repo): -> exit 2" 2
stderr_has "close(malformed --repo): diagnostic" "OWNER/REPO"

run 1 sh "$CLOSE" --bogus
expect_rc "close(unknown option): -> exit 2" 2
stderr_has "close(unknown option): diagnostic" "unknown option"

section "close-issue.sh — gh absent / not authenticated"
run 0 sh "$CLOSE" --repo o/r --issue 1
expect_rc "close(no-gh): -> exit 1" 1

run 1 "GH_STUB_AUTHED=0" sh "$CLOSE" --repo o/r --issue 1
expect_rc "close(unauth): -> exit 1" 1

section "close-issue.sh — happy path, no comment, reason enum accepted"
CLOSE_LOG1="$WORK/close-log1"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CLOSE_LOG=$CLOSE_LOG1" \
	sh "$CLOSE" --repo octo/repo --issue 9 --reason not_planned
expect_rc "close(happy-no-comment): -> exit 0" 0
check "close(happy-no-comment): --reason not_planned is translated to gh's 'not planned'" "reason missing/mistranslated in argv" \
	"$( argv_has_pair "$CLOSE_LOG1" '--reason' 'not planned' && echo 0 || echo 1 )"

section "close-issue.sh — reason 'completed' accepted"
run 1 "GH_STUB_AUTHED=1" sh "$CLOSE" --repo o/r --issue 9 --reason completed
expect_rc "close(reason-completed): -> exit 0" 0

section "close-issue.sh — bare close (no --reason) never injects a default reason token"
CLOSE_LOG4="$WORK/close-log4"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CLOSE_LOG=$CLOSE_LOG4" sh "$CLOSE" --repo octo/repo --issue 9
expect_rc "close(bare): -> exit 0" 0
check "close(bare): argv has NO --reason token" "a --reason token was found even though none was requested (a silently-injected default)" \
	"$( argv_has_token "$CLOSE_LOG4" '--reason' && echo 1 || echo 0 )"

section "close-issue.sh — --comment-file posts a comment BEFORE closing"
CCOMMENT="$WORK/close-comment.md"
printf 'Closing as resolved.\n' >"$CCOMMENT"
CLOSE_COMMENT_LOG="$WORK/close-comment-log"
CLOSE_LOG2="$WORK/close-log2"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_LOG=$CLOSE_COMMENT_LOG" "GH_STUB_CLOSE_LOG=$CLOSE_LOG2" \
	sh "$CLOSE" --repo octo/repo --issue 9 --comment-file "$CCOMMENT" --reason completed
expect_rc "close(with-comment): -> exit 0" 0
check "close(with-comment): the comment was posted" "no comment call was logged" \
	"$( [ -f "$CLOSE_COMMENT_LOG" ] && echo 0 || echo 1 )"
check "close(with-comment): comment body-file contents relayed verbatim" "comment content missing" \
	"$( body_block "$CLOSE_COMMENT_LOG" | grep -Fq -- 'Closing as resolved.' && echo 0 || echo 1 )"
check "close(with-comment): the issue was also closed" "no close call was logged" \
	"$( [ -f "$CLOSE_LOG2" ] && echo 0 || echo 1 )"

section "close-issue.sh — BOTH legs target the exact issue and repo the caller named"
# Until now every close-issue.sh assertion above checked a FLAG (--reason present,
# absent, translated) or merely that SOME call was logged — nothing pinned WHICH
# issue in WHICH repo either leg actually acted on. A leg-local corruption (a
# hardcoded number, the wrong variable, a dropped/duplicated --repo) would have
# been invisible, and this script makes TWO writes, so each leg needs its own
# proof: the comment leg posting on a different issue than the one being closed
# is precisely the silent mis-target this covers.
#
# ONE invocation, asserted across the two distinct observable channels (the
# comment log and the close log) — that is what lets the comment leg's positional
# be asserted to be the SAME number the close leg used, which two separate runs
# could not establish. Issue 42 (not 1) and owner/repo-a (not the ambiguous
# octo/repo used elsewhere) so an off-by-one or a wrong-repo substitution is
# actually detectable rather than colliding with a plausible default.
CLOSE_TARGET_COMMENT_LOG="$WORK/close-target-comment-log"
CLOSE_TARGET_CLOSE_LOG="$WORK/close-target-close-log"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_LOG=$CLOSE_TARGET_COMMENT_LOG" "GH_STUB_CLOSE_LOG=$CLOSE_TARGET_CLOSE_LOG" \
	sh "$CLOSE" --repo owner/repo-a --issue 42 --comment-file "$CCOMMENT"
expect_rc "close(target): -> exit 0" 0
check "close(target): the CLOSE leg's positional is exactly issue 42" "gh issue close acted on some other issue number" \
	"$( argv_first_is "$CLOSE_TARGET_CLOSE_LOG" '42' && echo 0 || echo 1 )"
check "close(target): the CLOSE leg's --repo is exactly owner/repo-a" "gh issue close targeted the wrong repo" \
	"$( argv_has_pair "$CLOSE_TARGET_CLOSE_LOG" '--repo' 'owner/repo-a' && echo 0 || echo 1 )"
check "close(target): the pre-close NOTE leg's positional is the SAME issue 42" "the closing comment was posted on a different issue than the one closed" \
	"$( argv_first_is "$CLOSE_TARGET_COMMENT_LOG" '42' && echo 0 || echo 1 )"
check "close(target): the pre-close NOTE leg's --repo is exactly owner/repo-a" "the closing comment was posted in the wrong repo" \
	"$( argv_has_pair "$CLOSE_TARGET_COMMENT_LOG" '--repo' 'owner/repo-a' && echo 0 || echo 1 )"

section "close-issue.sh — comment post failure aborts BEFORE closing"
CLOSE_LOG3="$WORK/close-log3"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_COMMENT_RC=1" "GH_STUB_CLOSE_LOG=$CLOSE_LOG3" \
	sh "$CLOSE" --repo o/r --issue 9 --comment-file "$CCOMMENT"
expect_rc "close(comment-fail): -> exit 1" 1
stderr_has "close(comment-fail): reports failure" "failed to post closing comment"
file_missing "close(comment-fail): gh issue close never invoked" "$CLOSE_LOG3"

section "close-issue.sh — gh issue close itself fails"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CLOSE_RC=1" sh "$CLOSE" --repo o/r --issue 9
expect_rc "close(gh-fail): -> exit 1" 1
stderr_has "close(gh-fail): reports failure" "gh issue close failed"
check "close(gh-fail): NO already-posted warning when no comment was ever posted" "the warning appeared even though --comment-file was never given" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'ALREADY POSTED' && echo 1 || echo 0 )"

section "close-issue.sh — close fails AFTER a comment already posted: warns against a double-post retry"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_CLOSE_RC=1" sh "$CLOSE" --repo o/r --issue 9 --comment-file "$CCOMMENT"
expect_rc "close(gh-fail-after-comment): -> exit 1" 1
stderr_has "close(gh-fail-after-comment): reports the close failure" "gh issue close failed"
stderr_has "close(gh-fail-after-comment): warns the comment was already posted" "ALREADY POSTED"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
