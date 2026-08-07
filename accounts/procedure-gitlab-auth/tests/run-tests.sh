#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-gitlab-auth script suite (glab-auth-status.sh +
#                manage_glab_accounts.sh).
#
# WHY a hand-rolled harness (not bats): the whole point of this suite is "runs
# on any machine with no dependencies". Requiring bats-core would contradict
# that. This harness needs only a POSIX sh plus the coreutils that already ship
# on macOS (BSD) and Linux (GNU). Mirrors the sibling procedure-github-auth test
# harness exactly (same stub shape, same assertion helpers).
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools the
#     scripts need (awk, grep, sed, ...) PLUS a STUB `glab` so no test ever
#     touches real auth, keyrings, or the network. The glab stub lives in its
#     OWN dir that tests opt into, so "glab absent" is exercised for real (by
#     leaving that dir off PATH).
#   * The glab stub is fully env-driven: tests set GLAB_STUB_* variables to
#     script the exact `glab auth status` text, its exit code, whether `--all`
#     is supported, login return codes, and a mutable auth statefile — so every
#     deterministic branch is covered.
#   * MUTATING subcommands (login/logout) are logged to GLAB_STUB_LOG and READ
#     ones (status) to GLAB_STUB_STATUS_LOG, kept apart on purpose: several
#     assertions prove "nothing was mutated" by the mere ABSENCE of the mutation
#     log, which a shared log would defeat.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR and is
#     cleaned up on exit. NO_COLOR=1 keeps captured output byte-clean.
#
# STUB-ONLY CAVEAT (read this if a real `glab` release ever changes behavior):
#   These tests are entirely stub-driven — no real `glab` runs here, ever. The
#   `glab auth` surface this suite relies on (`status` with --all/--hostname,
#   `login` with --hostname, the "✓ Logged in to HOST as LOGIN (keyring)" line
#   shape, and the ABSENCE of an `auth switch` subcommand) was verified against
#   a real `glab auth --help` / `glab auth status` at BUILD time (glab 1.112.0),
#   not by this harness — the stub simply replays whatever a test scripts, so it
#   cannot detect a real `glab` release drifting from that contract. Catching a
#   real-glab drift needs an occasional real-glab smoke check against a scratch
#   account — deliberately out of scope for this harness, which exists to run
#   anywhere with zero dependencies (see above).
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
STATUS="$SCRIPTS_DIR/glab-auth-status.sh"
MANAGE="$SCRIPTS_DIR/manage_glab_accounts.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/glab-auth-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"      # real tools (glab is NEVER here)
GLABDIR="$WORK/glabbin"      # glab stub (only when a test opts in)
mkdir -p "$TOOLBOX" "$GLABDIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools we need. glab is NEVER here.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	tp=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$1" >&2; exit 1; }
	ln -s "$tp" "$TOOLBOX/$1"
}
for t in sh env awk sed grep cut head cat tr sort rm mkdir mktemp dirname uname; do
	link_tool "$t"
done

# ---------------------------------------------------------------------------
# glab stub — fully env-driven so tests script every deterministic branch.
#   GLAB_STUB_AUTHED=1         -> `glab auth status` succeeds (unless statefile set)
#   GLAB_STUB_STATEFILE=path   -> authed iff the file contains "1" (mutable across
#                                 calls; `glab auth login` flips it to "1")
#   GLAB_STUB_STATUS=text      -> exact `glab auth status` body to print
#   GLAB_STUB_STATUS_RC=n      -> exit code for an AUTHED status call (default 0);
#                                 lets a test drive "non-zero rc, usable records"
#   GLAB_STUB_NO_ALL=1         -> reject `--all` as an unknown flag (an older glab)
#   GLAB_STUB_LOGIN_RC=n       -> return code for `glab auth login`
#   GLAB_STUB_LOG=path         -> append a line per MUTATING call (login/logout)
#   GLAB_STUB_STATUS_LOG=path  -> append a line per `auth status` call (read-only)
# ---------------------------------------------------------------------------
cat > "$GLABDIR/glab" <<'GLAB_STUB'
#!/usr/bin/env sh
set -eu
log_call() {
	if [ -n "${GLAB_STUB_LOG:-}" ]; then printf '%s\n' "$*" >> "$GLAB_STUB_LOG"; fi
}
log_status_call() {
	if [ -n "${GLAB_STUB_STATUS_LOG:-}" ]; then printf '%s\n' "$*" >> "$GLAB_STUB_STATUS_LOG"; fi
}
is_authed() {
	if [ -n "${GLAB_STUB_STATEFILE:-}" ] && [ -f "$GLAB_STUB_STATEFILE" ]; then
		[ "$(cat "$GLAB_STUB_STATEFILE")" = "1" ]
	else
		[ "${GLAB_STUB_AUTHED:-0}" = "1" ]
	fi
}
case "${1:-}" in
	--version)
		printf 'glab 1.112.0 (816e3a52)\n'
		exit 0 ;;
	auth)
		case "${2:-}" in
			status)
				shift 2
				log_status_call "status $*"
				if [ "${GLAB_STUB_NO_ALL:-0}" = "1" ] && [ "${1:-}" = "--all" ]; then
					printf 'unknown flag: --all\n' >&2
					exit 1
				fi
				if is_authed; then
					printf '%s\n' "${GLAB_STUB_STATUS:-}"
					exit "${GLAB_STUB_STATUS_RC:-0}"
				fi
				printf 'You are not logged in to any GitLab hosts. Run `glab auth login` to authenticate.\n' >&2
				exit 1 ;;
			login)
				log_call "login $*"
				if [ -n "${GLAB_STUB_STATEFILE:-}" ]; then printf '1' > "$GLAB_STUB_STATEFILE"; fi
				exit "${GLAB_STUB_LOGIN_RC:-0}" ;;
			logout)
				log_call "logout $*"
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	*) exit 0 ;;
esac
GLAB_STUB
chmod +x "$GLABDIR/glab"

# ---------------------------------------------------------------------------
# Runner primitives
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0
STDIN_DATA=""      # set before a `run` to feed the script's stdin

# run <with_glab:0|1> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> under the isolated toolbox PATH (+ glab stub only when
#   with_glab=1), with an isolated HOME/TMPDIR and NO_COLOR=1. Leading
#   VAR=VALUE arguments are passed straight to `env` (values may contain spaces
#   or newlines). stdin is fed from $STDIN_DATA (default empty). Captures
#   stdout, stderr, exit code.
run() {
	r_glab=$1; shift
	r_path="$TOOLBOX"
	[ "$r_glab" = "1" ] && r_path="$GLABDIR:$TOOLBOX"
	printf '%s' "$STDIN_DATA" > "$WORK/stdin"
	set +e
	env -i \
		HOME="$WORK/home" \
		PATH="$r_path" \
		TMPDIR="$WORK" \
		NO_COLOR=1 \
		"$@" <"$WORK/stdin" >"$WORK/out" 2>"$WORK/err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$WORK/out"); CUR_ERR=$(cat "$WORK/err")
	rm -f "$WORK/out" "$WORK/err" "$WORK/stdin"
	STDIN_DATA=""
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

stdout_lacks() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -- "$2"; then fail "$1" "stdout unexpectedly contains: $2"
	else pass "$1"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

# stdout_re — assert stdout matches an extended regex (used for exact-line
# checks like an EMPTY machine value: '^GLAB_ACTIVE_ACCOUNT=$').
stdout_re() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Eq -- "$2"; then pass "$1"
	else fail "$1" "stdout not matching /$2/"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# Fixtures — `glab auth status` bodies for the various states/formats. The
# SINGLE fixture is the real, observed glab 1.112.0 output verbatim.
# ---------------------------------------------------------------------------
STATUS_SINGLE='gitlab.com
  ✓ Logged in to gitlab.com as Cordona (keyring)
  ✓ Git operations for gitlab.com configured to use https protocol.
  ✓ API calls for gitlab.com are made over https protocol.
  ✓ REST API Endpoint: https://gitlab.com/api/v4/
  ✓ GraphQL Endpoint: https://gitlab.com/api/graphql/
  ✓ Token found in operating system keyring: **************************'

# Two instances, DIFFERENT logins — the account is genuinely ambiguous without
# a --hostname (glab keeps one credential per instance).
STATUS_TWO_HOSTS='gitlab.com
  ✓ Logged in to gitlab.com as Cordona (keyring)
  ✓ Git operations for gitlab.com configured to use https protocol.
gitlab.example.com
  ✓ Logged in to gitlab.example.com as worker (keyring)
  ✓ Git operations for gitlab.example.com configured to use ssh protocol.'

# Two instances, SAME login. Still two candidate accounts -> still ambiguous.
STATUS_SAME_LOGIN_TWO_HOSTS='gitlab.com
  ✓ Logged in to gitlab.com as Cordona (keyring)
gitlab.example.com
  ✓ Logged in to gitlab.example.com as Cordona (keyring)'

# The SAME host+login printed twice (a hypothetical glab that lists an instance
# once per config source). Dedup must keep this UNambiguous.
STATUS_DUPLICATE_LINES='gitlab.com
  ✓ Logged in to gitlab.com as Cordona (keyring)
gitlab.com
  ✓ Logged in to gitlab.com as Cordona (keyring)'

# Non-login noise that must NEVER be parsed as an account: a "Not logged in"
# line and a "Failed to log in" line (neither carries the capital-L "Logged in
# to" anchor), alongside one real account.
# shellcheck disable=SC2016  # the backticks are glab's own message punctuation, quoted on purpose: this fixture must reach the parser as literal bytes, never be expanded
STATUS_WITH_NOISE='gitlab.com
  ✓ Logged in to gitlab.com as Cordona (keyring)
ghost.example.com
  ✗ Not logged in to ghost.example.com. Run `glab auth login` to authenticate.
  ✗ Failed to log in to ghost.example.com as phantom (keyring)'

# ===========================================================================
# glab-auth-status.sh
# ===========================================================================
section "glab-auth-status.sh — authenticated (single account, real observed format)"
STATUS_LOG1="$WORK/statuslog1"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_STATUS_LOG=$STATUS_LOG1" sh "$STATUS"
expect_rc "status: single account -> exit 0" 0
stdout_has "status: GLAB_INSTALLED=true"      "GLAB_INSTALLED=true"
stdout_has "status: GLAB_AUTHENTICATED=true"  "GLAB_AUTHENTICATED=true"
stdout_has "status: active account Cordona"   "GLAB_ACTIVE_ACCOUNT=Cordona"
stdout_has "status: host gitlab.com"          "GLAB_HOST=gitlab.com"
stdout_has "status: accounts list"            "GLAB_ACCOUNTS=Cordona"
stdout_has "status: not ambiguous"            "GLAB_ACTIVE_AMBIGUOUS=false"
stdout_has "status: active set login@host"    "GLAB_ACTIVE_ACCOUNTS=Cordona@gitlab.com"
stdout_has "status: human active marker"      "[active]"
check "status: unscoped call asks glab for --all (a bare status would hide a 2nd instance)" \
	"--all missing from the glab auth status argv" \
	"$( grep -Fq -- 'status --all' "$STATUS_LOG1" && echo 0 || echo 1 )"
run1=$CUR_OUT
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" sh "$STATUS"
check "status: deterministic across identical runs" "output differed between runs" \
	"$( [ "$run1" = "$CUR_OUT" ] && echo 0 || echo 1 )"

section "glab-auth-status.sh — duplicate identical login lines are deduped (NOT ambiguous)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_DUPLICATE_LINES" sh "$STATUS"
expect_rc "status(dedup): -> exit 0" 0
stdout_has "status(dedup): single account resolved" "GLAB_ACTIVE_ACCOUNT=Cordona"
stdout_has "status(dedup): inventory not doubled"   "GLAB_ACCOUNTS=Cordona"
stdout_has "status(dedup): not ambiguous"           "GLAB_ACTIVE_AMBIGUOUS=false"

section "glab-auth-status.sh — parsing robustness (non-login lines ignored)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_WITH_NOISE" sh "$STATUS"
expect_rc "status(noise): -> exit 0" 0
stdout_has  "status(noise): real account parsed"          "GLAB_ACTIVE_ACCOUNT=Cordona"
stdout_lacks "status(noise): 'phantom' never parsed"      "phantom"
stdout_lacks "status(noise): failed host never parsed"    "ghost.example.com"
stdout_has  "status(noise): accounts == Cordona only"     "GLAB_ACCOUNTS=Cordona"

section "glab-auth-status.sh — two instances -> ambiguous (no guess)"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" sh "$STATUS"
expect_rc "status(ambiguous): -> exit 1 (fail-closed)" 1
stdout_has "status(ambiguous): flag set"        "GLAB_ACTIVE_AMBIGUOUS=true"
stdout_re  "status(ambiguous): active account EMPTY (no guess)" '^GLAB_ACTIVE_ACCOUNT=$'
stdout_re  "status(ambiguous): host EMPTY (no guess)"           '^GLAB_HOST=$'
stdout_has "status(ambiguous): lists Cordona@gitlab.com"        "Cordona@gitlab.com"
stdout_has "status(ambiguous): lists worker@gitlab.example.com" "worker@gitlab.example.com"
stdout_has "status(ambiguous): full inventory still reported"   "GLAB_ACCOUNTS=Cordona,worker"
stderr_has "status(ambiguous): diagnostic"       "several accounts are configured"
stderr_has "status(ambiguous): points at --hostname" "re-run with --hostname"
run1=$CUR_OUT
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" sh "$STATUS"
check "status(ambiguous): deterministic candidate-set ordering" "candidate set order differed between runs" \
	"$( [ "$run1" = "$CUR_OUT" ] && echo 0 || echo 1 )"

section "glab-auth-status.sh — same login on two instances is STILL ambiguous"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SAME_LOGIN_TWO_HOSTS" sh "$STATUS"
expect_rc "status(same-login): -> exit 1" 1
stdout_has "status(same-login): ambiguous flag" "GLAB_ACTIVE_AMBIGUOUS=true"
# The candidate set is LC_ALL=C sorted, so "gitlab.com" precedes
# "gitlab.example.com" ('c' < 'e' at the deciding byte) — asserting the exact
# string is what proves the ordering is pinned rather than glab-output-dependent.
stdout_has "status(same-login): both hosts named, C-sorted" "Cordona@gitlab.com,Cordona@gitlab.example.com"

section "glab-auth-status.sh — --hostname disambiguates the multi-instance case"
STATUS_LOG2="$WORK/statuslog2"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" "GLAB_STUB_STATUS_LOG=$STATUS_LOG2" \
	sh "$STATUS" --hostname gitlab.com
expect_rc "status(--hostname gitlab.com): -> exit 0" 0
stdout_has "status(--hostname gitlab.com): active Cordona"     "GLAB_ACTIVE_ACCOUNT=Cordona"
stdout_has "status(--hostname gitlab.com): host gitlab.com"    "GLAB_HOST=gitlab.com"
stdout_has "status(--hostname gitlab.com): not ambiguous"      "GLAB_ACTIVE_AMBIGUOUS=false"
stdout_has "status(--hostname gitlab.com): inventory scoped"   "GLAB_ACCOUNTS=Cordona"
check "status(--hostname): forwarded to glab as its own flag" "--hostname missing from the glab argv" \
	"$( grep -Fq -- 'status --hostname gitlab.com' "$STATUS_LOG2" && echo 0 || echo 1 )"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" sh "$STATUS" --hostname gitlab.example.com
expect_rc "status(--hostname self-managed): -> exit 0" 0
stdout_has "status(--hostname self-managed): active worker" "GLAB_ACTIVE_ACCOUNT=worker"
stdout_has "status(--hostname self-managed): host"          "GLAB_HOST=gitlab.example.com"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" sh "$STATUS" --hostname nope.example.com
expect_rc "status(--hostname unknown): -> exit 1" 1
stderr_has "status(--hostname unknown): diagnostic" "not authenticated to host 'nope.example.com'"

section "glab-auth-status.sh — an older glab without --all falls back to a bare status"
STATUS_LOG3="$WORK/statuslog3"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_NO_ALL=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_STATUS_LOG=$STATUS_LOG3" \
	sh "$STATUS"
expect_rc "status(no --all): -> exit 0 (not mis-reported as logged out)" 0
stdout_has "status(no --all): account still resolved" "GLAB_ACTIVE_ACCOUNT=Cordona"
# `^status *$`, NOT a fixed-string match on 'status ' with its INVISIBLE trailing
# space: the stub logs `status $*`, so a bare call leaves exactly one trailing
# space — and any editor with trim-trailing-whitespace-on-save would have silently
# turned that assertion into a match for 'status', which the `status --all` line
# does not equal either, so the check would have started passing for the wrong
# reason (or failing for no visible one). The regex says what is meant: the word
# `status` with nothing but optional blanks after it.
check "status(no --all): the bare-status retry actually happened" "no bare 'status' call recorded" \
	"$( grep -Eq '^status *$' "$STATUS_LOG3" && echo 0 || echo 1 )"

section "glab-auth-status.sh — non-zero glab exit WITH usable records: proceed + warn"
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_STATUS_RC=1" sh "$STATUS"
expect_rc "status(rc1-with-records): -> exit 0 (one unhealthy instance must not hide a good one)" 0
stdout_has "status(rc1-with-records): account resolved" "GLAB_ACTIVE_ACCOUNT=Cordona"
stderr_has "status(rc1-with-records): warns about the non-zero status" "may be unhealthy"

section "glab-auth-status.sh — not authenticated"
run 1 "GLAB_STUB_AUTHED=0" sh "$STATUS"
expect_rc "status(unauth): -> exit 1" 1
stdout_has "status(unauth): GLAB_AUTHENTICATED=false"  "GLAB_AUTHENTICATED=false"
stdout_has "status(unauth): GLAB_INSTALLED still true" "GLAB_INSTALLED=true"
stdout_re  "status(unauth): no account invented"       '^GLAB_ACTIVE_ACCOUNT=$'
stderr_has "status(unauth): diagnostic" "not authenticated to any host"
# OBS-001: a non-zero `glab auth status` exit is AMBIGUOUS — it is what a
# logged-out glab returns AND what a locked keyring / unreachable self-managed
# host returns. The verdict stays "do not act", but the operator must be told the
# reason is not established, or they retry a login that cannot fix the real
# problem. The stub's logged-out path exits 1, so this is that branch.
stderr_has "status(unauth): says the non-zero exit may mean glab could not answer at all" \
	"may not have been ABLE to answer"
stderr_has "status(unauth): names the exit status it saw" "exited 1"
stderr_has "status(unauth): still gives the actionable next step" "manage_glab_accounts.sh"

section "glab-auth-status.sh — glab exits 0 with UNPARSEABLE output (OBS-001)"
# A future glab that renames its login line, or any output shape this parser does
# not recognize, produces zero records with a CLEAN exit and non-empty output.
# Reporting that as a flat "logged out" is the misattribution OBS-001 is about:
# no login will fix a parser that needs updating.
STATUS_UNPARSEABLE='gitlab.com
  ✓ Authenticated as Cordona via keyring
  ✓ REST API Endpoint: https://gitlab.com/api/v4/'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_UNPARSEABLE" sh "$STATUS"
expect_rc "status(unparseable): -> exit 1 (fail closed: no account was resolved)" 1
stdout_has "status(unparseable): GLAB_AUTHENTICATED=false" "GLAB_AUTHENTICATED=false"
stdout_re  "status(unparseable): no account invented"      '^GLAB_ACTIVE_ACCOUNT=$'
stderr_has "status(unparseable): names the parser as a suspect, not the credential" \
	"the parser may need updating for this glab version"
stderr_has "status(unparseable): tells the operator how to see what it could not read" \
	"run 'glab auth status --all' yourself"
check "status(unparseable): does NOT claim glab failed (it exited 0)" \
	"the non-zero-exit diagnostic was printed for a clean exit" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'may not have been ABLE to answer' && echo 1 || echo 0 )"
# The captured `glab auth status` output can carry token material, so it must
# never be echoed back — only its EMPTINESS is ever reported.
check "status(unparseable): the captured glab output is never echoed" \
	"glab's own status output leaked into this script's diagnostics" \
	"$( printf '%s\n%s\n' "$CUR_OUT" "$CUR_ERR" | grep -Fq -- 'Authenticated as Cordona via keyring' && echo 1 || echo 0 )"

section "glab-auth-status.sh — a --hostname miss names its own limitation (OBS-001)"
# With --hostname, parse_records ALSO drops every line for another host, so zero
# records is the expected result for a host that simply has no login — the parser
# warning above would be a lie here. The scoped branch says exactly that instead.
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" sh "$STATUS" --hostname nope.example.com
expect_rc "status(--hostname miss): -> exit 1" 1
stderr_has "status(--hostname miss): still names the host" "not authenticated to host 'nope.example.com'"
stderr_has "status(--hostname miss): admits a scoped query cannot tell the two causes apart" \
	"cannot tell \"this host has no login\" apart"
check "status(--hostname miss): does NOT blame the parser (the filter is the reason)" \
	"the unscoped parser diagnostic was printed for a scoped query" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq -- 'the parser may need updating' && echo 1 || echo 0 )"

section "glab-auth-status.sh — glab absent"
run 0 sh "$STATUS"
expect_rc "status(no-glab): -> exit 1" 1
stdout_has "status(no-glab): GLAB_INSTALLED=false"     "GLAB_INSTALLED=false"
stdout_has "status(no-glab): GLAB_AUTHENTICATED=false" "GLAB_AUTHENTICATED=false"
stderr_has "status(no-glab): install hint" "gitlab-org/cli"

section "glab-auth-status.sh — usage"
run 1 sh "$STATUS" -h
expect_rc "status(usage): -h -> exit 0" 0
stdout_has "status(usage): help text" "Usage:"
run 1 sh "$STATUS" --bogus
expect_rc "status(usage): unknown flag -> exit 2" 2
stderr_has "status(usage): unknown-flag diagnostic" "unknown option"
run 1 sh "$STATUS" extra
expect_rc "status(usage): positional arg -> exit 2" 2
run 1 sh "$STATUS" --hostname
expect_rc "status(usage): --hostname without value -> exit 2" 2
stderr_has "status(usage): missing-value diagnostic" "requires an argument"
run 1 sh "$STATUS" --host gitlab.com
expect_rc "status(usage): gh's --host spelling is NOT accepted -> exit 2" 2

# ===========================================================================
# manage_glab_accounts.sh
# ===========================================================================
section "manage_glab_accounts.sh — usage / glab absent"
run 1 sh "$MANAGE" -h
expect_rc "manage(usage): -h -> exit 0" 0
stdout_has "manage(usage): help text" "Usage:"
stdout_has "manage(usage): explains why there is no switch action" "no 'auth switch' subcommand"
run 1 sh "$MANAGE" --bogus
expect_rc "manage(usage): unknown flag -> exit 1" 1
stderr_has "manage(usage): diagnostic" "unknown option"

run 0 sh "$MANAGE"
expect_rc "manage(no-glab): -> exit 1" 1
stderr_has "manage(no-glab): 'not installed' error" "not installed"
stdout_has "manage(no-glab): install hint" "gitlab-org/cli"

section "manage_glab_accounts.sh — keep current account"
STDIN_DATA='3
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog1" sh "$MANAGE"
expect_rc "manage(keep): -> exit 0" 0
stdout_has "manage(keep): keeps active Cordona" "Keeping the current account: Cordona"
check "manage(keep): no login/logout was invoked" "glab mutation happened on keep" \
	"$( [ ! -f "$WORK/glablog1" ] && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — authenticate a configured instance (--hostname)"
STDIN_DATA='1
1
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog2" sh "$MANAGE"
expect_rc "manage(host): -> exit 0" 0
stdout_has "manage(host): announces the target" "glab auth login --hostname gitlab.com"
check "manage(host): invoked glab auth login" "login not recorded" \
	"$( [ -f "$WORK/glablog2" ] && grep -Fq 'login' "$WORK/glablog2" && echo 0 || echo 1 )"
check "manage(host): --hostname gitlab.com passed" "--hostname missing" \
	"$( grep -Fq -- '--hostname gitlab.com' "$WORK/glablog2" && echo 0 || echo 1 )"
stdout_has "manage(host): now-active reported" "Now active: Cordona (gitlab.com)"

section "manage_glab_accounts.sh — authenticate a NEW, typed hostname"
STDIN_DATA='1
2
gitlab.example.com
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog3" sh "$MANAGE"
expect_rc "manage(new-host): -> exit 0" 0
check "manage(new-host): --hostname gitlab.example.com passed" "typed hostname missing from argv" \
	"$( grep -Fq -- '--hostname gitlab.example.com' "$WORK/glablog3" && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — a rejected hostname never reaches glab"
STDIN_DATA='1
2
bad host!
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog4" sh "$MANAGE"
expect_rc "manage(bad-host): -> exit 1" 1
stderr_has "manage(bad-host): diagnostic" "Not a usable hostname"
check "manage(bad-host): no login attempted" "login attempted with a rejected hostname" \
	"$( [ ! -f "$WORK/glablog4" ] && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — host selection cancelled"
STDIN_DATA='1
c
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog5" sh "$MANAGE"
expect_rc "manage(host-cancel): -> exit 1" 1
stdout_has "manage(host-cancel): says cancelled" "Cancelled."
check "manage(host-cancel): no login invoked" "login invoked despite cancel" \
	"$( [ ! -f "$WORK/glablog5" ] && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — host selection: retries exhausted"
STDIN_DATA='1
9
9
9
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog6" sh "$MANAGE"
expect_rc "manage(host-retries): -> exit 1" 1
stderr_has "manage(host-retries): max-retries diagnostic" "Maximum retries reached"
check "manage(host-retries): no login invoked" "login invoked after exhausted retries" \
	"$( [ ! -f "$WORK/glablog6" ] && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — menu 2: glab's own interactive host detection"
STDIN_DATA='2
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog7" sh "$MANAGE"
expect_rc "manage(login): -> exit 0" 0
check "manage(login): invoked glab auth login" "login not recorded" \
	"$( grep -Fq 'login' "$WORK/glablog7" && echo 0 || echo 1 )"
check "manage(login): NO --hostname forced onto glab" "--hostname passed even though the user chose detection" \
	"$( grep -Fq -- '--hostname' "$WORK/glablog7" && echo 1 || echo 0 )"

section "manage_glab_accounts.sh — the login subcommand fails"
STDIN_DATA='2
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOGIN_RC=1" sh "$MANAGE"
expect_rc "manage(login-fail): -> exit 1" 1
stderr_has "manage(login-fail): reports failure" "Login was cancelled or failed"

section "manage_glab_accounts.sh — not authenticated, user declines login"
STDIN_DATA='n
'
run 1 "GLAB_STUB_AUTHED=0" sh "$MANAGE"
expect_rc "manage(unauth-decline): -> exit 0" 0
stdout_has "manage(unauth-decline): no changes" "No changes made"

section "manage_glab_accounts.sh — not authenticated, user logs in (statefile flips)"
printf '0' > "$WORK/state1"
STDIN_DATA='y
'
run 1 "GLAB_STUB_STATEFILE=$WORK/state1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog8" sh "$MANAGE"
expect_rc "manage(unauth-login): -> exit 0" 0
check "manage(unauth-login): invoked glab auth login" "login not recorded" \
	"$( [ -f "$WORK/glablog8" ] && grep -Fq 'login' "$WORK/glablog8" && echo 0 || echo 1 )"
stdout_has "manage(unauth-login): now-authed account shown" "Cordona"

section "manage_glab_accounts.sh — unauthenticated + stdin EOF -> fail-safe decline"
STDIN_DATA=''
run 1 "GLAB_STUB_AUTHED=0" "GLAB_STUB_LOG=$WORK/glablog9" sh "$MANAGE"
expect_rc "manage(unauth-eof): -> exit 0 (no silent login)" 0
stderr_has "manage(unauth-eof): EOF declined" "declining"
stdout_has "manage(unauth-eof): no changes" "No changes made"
check "manage(unauth-eof): login NOT attempted" "login attempted on EOF" \
	"$( [ ! -f "$WORK/glablog9" ] && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — stdin EOF at the authenticated menu -> keep"
STDIN_DATA=''
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog10" sh "$MANAGE"
expect_rc "manage(menu-eof): -> exit 0" 0
stdout_has "manage(menu-eof): keeps current" "Keeping the current account: Cordona"
check "manage(menu-eof): no mutation" "glab mutated on EOF" \
	"$( [ ! -f "$WORK/glablog10" ] && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — exhausted retries at the menu -> exit 1"
STDIN_DATA='x
x
x
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_SINGLE" "GLAB_STUB_LOG=$WORK/glablog11" sh "$MANAGE"
expect_rc "manage(menu-retries): -> exit 1" 1
stderr_has "manage(menu-retries): max-retries diagnostic" "Maximum retries reached"

section "manage_glab_accounts.sh — several instances: no account is claimed active"
STDIN_DATA='3
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" "GLAB_STUB_LOG=$WORK/glablog12" sh "$MANAGE"
expect_rc "manage(multi): -> exit 0" 0
stdout_has "manage(multi): surfaces the several-accounts state" "several accounts configured"
stdout_has "manage(multi): both accounts listed" "worker (gitlab.example.com)"
stdout_has "manage(multi): keep stays honest" "several accounts remain configured"
stdout_has "manage(multi): points the gate at --hostname" "--hostname HOST"
check "manage(multi): nothing mutated" "glab mutated while several accounts were configured" \
	"$( [ ! -f "$WORK/glablog12" ] && echo 0 || echo 1 )"

section "manage_glab_accounts.sh — several instances: host list offers BOTH + a new one"
STDIN_DATA='1
2
'
run 1 "GLAB_STUB_AUTHED=1" "GLAB_STUB_STATUS=$STATUS_TWO_HOSTS" "GLAB_STUB_LOG=$WORK/glablog13" sh "$MANAGE"
expect_rc "manage(multi-host-pick): -> exit 0" 0
check "manage(multi-host-pick): the 2nd configured host was selectable" "self-managed host was not offered as row 2" \
	"$( grep -Fq -- '--hostname gitlab.example.com' "$WORK/glablog13" && echo 0 || echo 1 )"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
