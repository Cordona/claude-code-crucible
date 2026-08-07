#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-jira-auth script suite (jira-login.sh,
#                jira-auth-status.sh, jira-curl-config.sh, jira-accounts.sh).
#
# WHY a hand-rolled harness (not bats): same rationale as procedure-github-auth's
# sibling harness — the whole point of this suite is "runs on any machine
# with no dependencies". Requiring bats-core would contradict that.
#
# What it does:
#   * Builds an isolated PATH toolbox of symlinks to only the real coreutils
#     these scripts need (sed, mktemp, mkdir, chmod, mv, rm, cat, tr, sort,
#     cp, stty). NO NETWORK, NO KEYCHAIN — the credential store is a plain
#     directory under an isolated $JIRA_CRED_DIR per test, never the real
#     $HOME/.claude/crucible/jira/credentials.
#   * Every test runs under `env -i` with an isolated HOME/TMPDIR/
#     JIRA_CRED_DIR and NO_COLOR=1, so captured output is byte-clean and
#     nothing leaks between tests or touches the real machine.
#   * jira-login.sh is interactive; tests drive it by feeding
#     site\nemail\ntoken\n (or just email\ntoken\n when --site is given) on
#     stdin — the same "pipe a transcript" technique
#     procedure-github-auth/tests/run-tests.sh uses for manage_gh_accounts.sh.
#   * The load-bearing security assertion in this suite: every test that
#     handles a credential feeds a DISTINCTIVE token value and then greps
#     every script's captured stdout+stderr for it — it must never appear.
#     (It also never appears on argv by construction: no script here accepts
#     a token as a command-line flag, only via the login prompt.)
#   * A dedicated TOOLBOX WITHOUT `stty` exercises jira-login.sh's graceful
#     degrade path — `command -v stty` failing and the script falling back
#     to a plain `read`, still storing correctly.
#
# Known coverage gap (documented, not silently skipped): the real
# no-terminal-echo behavior of `stty -echo` can only be observed on an
# actual TTY. This harness always feeds stdin via a pipe/redirect (`[ -t 0 ]`
# is false), so that branch of stty_echo_off() never executes here — what
# IS covered is (a) the piped/non-TTY path itself (every login test in this
# file exercises it) and (b) `stty` being entirely ABSENT from PATH (the
# NOSTTY toolbox below), which exercises the `command -v stty` guard on its
# own. Actually toggling terminal echo needs a pty harness (e.g. `script`/
# `expect`), which would break this suite's "zero dependencies" premise —
# out of scope here.
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
LOGIN="$SCRIPTS_DIR/jira-login.sh"
STATUS="$SCRIPTS_DIR/jira-auth-status.sh"
CURLCFG="$SCRIPTS_DIR/jira-curl-config.sh"
ACCOUNTS="$SCRIPTS_DIR/jira-accounts.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jira-auth-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"
NOSTTY_TOOLBOX="$WORK/toolbox-nostty"   # every real tool EXCEPT stty
mkdir -p "$TOOLBOX" "$NOSTTY_TOOLBOX" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolboxes: symlink only the real tools these scripts need.
# ---------------------------------------------------------------------------
ORIG_PATH=$PATH
link_tool() {
	target_dir=$1
	tool_name=$2
	tp=$(PATH="$ORIG_PATH" command -v "$tool_name" 2>/dev/null || true)
	[ -n "$tp" ] || { printf 'FATAL: required tool not found: %s\n' "$tool_name" >&2; exit 1; }
	ln -s "$tp" "$target_dir/$tool_name"
}
for t in sh env sed mktemp mkdir chmod mv rm cat tr sort cp stty dirname; do
	link_tool "$TOOLBOX" "$t"
done
for t in sh env sed mktemp mkdir chmod mv rm cat tr sort cp dirname; do
	link_tool "$NOSTTY_TOOLBOX" "$t"
done

# ---------------------------------------------------------------------------
# Runner primitives (same shape as procedure-github-auth/tests/run-tests.sh).
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
CUR_OUT=""
CUR_ERR=""
CUR_RC=0
STDIN_DATA=""      # set before a `run` to feed the script's stdin
CRED_DIR=""        # set per-test-group; passed to run() as JIRA_CRED_DIR
RUN_TOOLBOX="$TOOLBOX"  # set before a `run` to swap in a different PATH toolbox (e.g. $NOSTTY_TOOLBOX); reset to $TOOLBOX after every call

# run [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> under the isolated toolbox PATH ($RUN_TOOLBOX, default
#   $TOOLBOX), with an isolated HOME/TMPDIR and NO_COLOR=1. Leading
#   VAR=VALUE arguments pass straight to `env`. stdin is fed from
#   $STDIN_DATA (default empty). Captures stdout, stderr, exit code.
run() {
	printf '%s' "$STDIN_DATA" > "$WORK/stdin"
	set +e
	env -i \
		HOME="$WORK/home" \
		PATH="$RUN_TOOLBOX" \
		TMPDIR="$WORK" \
		NO_COLOR=1 \
		JIRA_CRED_DIR="$CRED_DIR" \
		"$@" <"$WORK/stdin" >"$WORK/out" 2>"$WORK/err"
	CUR_RC=$?
	set -e
	RUN_TOOLBOX="$TOOLBOX"
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

stderr_lacks() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -- "$2"; then fail "$1" "stderr unexpectedly contains: $2"
	else pass "$1"; fi
}

# stdout_line_is NAME LINE — a WHOLE-LINE match (`grep -x`), unlike
# stdout_has's substring match. Load-bearing for asserting a machine field is
# EMPTY (e.g. "JIRA_AUTH_ACCOUNT=") — a substring check for that same string
# would also match "JIRA_AUTH_ACCOUNT=someone@example.com" and prove nothing.
stdout_line_is() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fxq -- "$2"; then pass "$1"
	else fail "$1" "no stdout line exactly matches: $2"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# fresh_cred_dir -> sets $CRED_DIR to a brand-new, not-yet-created credential
# dir under $WORK, unique per call, so test groups never see each other's
# state. Sets the global directly (not `fresh_cred_dir`) because
# a command substitution runs in a SUBSHELL — incrementing $FCD_N there would
# be lost the instant the subshell exits, silently handing every call the
# SAME directory.
FCD_N=0
fresh_cred_dir() {
	FCD_N=$((FCD_N + 1))
	CRED_DIR="$WORK/cred-$FCD_N"
}

TOKEN_MARKER='sekret-TOKEN-v9x8w7-do-not-leak'

# ===========================================================================
# jira-login.sh — storage, permissions, no-leak
# ===========================================================================
section "jira-login.sh — stores a credential (site prompted)"
fresh_cred_dir
STDIN_DATA="example.atlassian.net
qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN"
expect_rc "login: prompted flow -> exit 0" 0
stdout_has  "login: success message names the site" "example.atlassian.net"
stdout_lacks "login: token NEVER on stdout" "$TOKEN_MARKER"
stderr_lacks "login: token NEVER on stderr" "$TOKEN_MARKER"
check "login: cred file exists" "cred file missing" \
	"$( [ -f "$CRED_DIR/example.atlassian.net.cfg" ] && echo 0 || echo 1 )"
check "login: cred file mode 600" "wrong file mode" \
	"$( [ "$(stat -f '%Lp' "$CRED_DIR/example.atlassian.net.cfg" 2>/dev/null || stat -c '%a' "$CRED_DIR/example.atlassian.net.cfg")" = "600" ] && echo 0 || echo 1 )"
check "login: cred dir mode 700" "wrong dir mode" \
	"$( [ "$(stat -f '%Lp' "$CRED_DIR" 2>/dev/null || stat -c '%a' "$CRED_DIR")" = "700" ] && echo 0 || echo 1 )"
check "login: cred file contains curl -K 'user =' line" "unexpected format" \
	"$( grep -Fq 'user = "qa@example.com:' "$CRED_DIR/example.atlassian.net.cfg" && echo 0 || echo 1 )"
check "login: first site becomes the default" "default marker missing/wrong" \
	"$( [ -f "$CRED_DIR/default" ] && [ "$(cat "$CRED_DIR/default")" = "example.atlassian.net" ] && echo 0 || echo 1 )"
check "login: default marker mode 600" "wrong default-marker mode" \
	"$( [ "$(stat -f '%Lp' "$CRED_DIR/default" 2>/dev/null || stat -c '%a' "$CRED_DIR/default")" = "600" ] && echo 0 || echo 1 )"

section "jira-login.sh — --site skips the site prompt"
fresh_cred_dir
STDIN_DATA="dev@example.com
$TOKEN_MARKER
"
run sh "$LOGIN" --site "https://acme.atlassian.net/browse/FOO"
expect_rc "login(--site): -> exit 0" 0
check "login(--site): normalized (https:// + path stripped)" "site not normalized" \
	"$( [ -f "$CRED_DIR/acme.atlassian.net.cfg" ] && echo 0 || echo 1 )"
stdout_lacks "login(--site): token NEVER on stdout" "$TOKEN_MARKER"
stderr_lacks "login(--site): token NEVER on stderr" "$TOKEN_MARKER"  # symmetry with the stdout check above

section "jira-login.sh — rejects a site outside the allow-list"
fresh_cred_dir
STDIN_DATA="not-a-jira-host.example.com
"
run sh "$LOGIN"
expect_rc "login(bad-site): retries then cancels -> exit 1" 1
stderr_has "login(bad-site): diagnostic" "not in the allowed shape"
check "login(bad-site): no cred file written" "cred file written despite bad site" \
	"$( [ ! -d "$CRED_DIR" ] || [ -z "$(ls -A "$CRED_DIR" 2>/dev/null)" ] && echo 0 || echo 1 )"

section "jira-login.sh — --site with a disallowed host fails closed immediately"
fresh_cred_dir
STDIN_DATA=""
run sh "$LOGIN" --site "evil.example.com"
expect_rc "login(--site bad): -> exit 1" 1
stderr_has "login(--site bad): diagnostic" "not in the allowed shape"

section "jira-login.sh — path-traversal / char-guard rejection"
# A traversal-shaped --site is defused TWO ways: normalize_site() strips
# everything from the first "/" onward (so a "/../../x" suffix never
# survives to reach a filename), and assert_host_allowed()'s allow-list
# glob then rejects whatever remains unless it happens to end in
# ".atlassian.net". Each case below proves one of the two defenses.
fresh_cred_dir
STDIN_DATA="qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN" --site "evil.atlassian.net/../../x"
expect_rc "login(traversal slash-path): the /../../x suffix is stripped before validation -> a NORMAL login for the bare host -> exit 0" 0
check "login(traversal slash-path): file lands EXACTLY at CRED_DIR/evil.atlassian.net.cfg — nowhere else (the /../../x never reached a path)" \
	"traversal payload affected the write path" \
	"$( [ -f "$CRED_DIR/evil.atlassian.net.cfg" ] && [ "$(find "$CRED_DIR" -maxdepth 1 -type f -name '*.cfg' | wc -l | tr -d ' ')" = "1" ] && echo 0 || echo 1 )"

fresh_cred_dir
STDIN_DATA=""
run sh "$LOGIN" --site ".."
expect_rc "login(dot-dot only): passes the char-guard (only dots) but fails the allow-list glob -> exit 1" 1
stderr_has "login(dot-dot only): diagnostic" "not in the allowed shape"
check "login(dot-dot only): no file written" "unexpected file(s) present" \
	"$( [ ! -d "$CRED_DIR" ] || [ -z "$(ls -A "$CRED_DIR" 2>/dev/null)" ] && echo 0 || echo 1 )"

fresh_cred_dir
STDIN_DATA=""
run sh "$LOGIN" --site "evil space.atlassian.net"
expect_rc "login(space in site): char-guard rejects -> exit 1" 1
stderr_has "login(space in site): diagnostic" "not in the allowed shape"
check "login(space in site): no file written" "unexpected file(s) present" \
	"$( [ ! -d "$CRED_DIR" ] || [ -z "$(ls -A "$CRED_DIR" 2>/dev/null)" ] && echo 0 || echo 1 )"

fresh_cred_dir
STDIN_DATA=""
BACKTICK_SITE="evil\`touch $WORK/pwned\`.atlassian.net"
run sh "$LOGIN" --site "$BACKTICK_SITE"
expect_rc "login(backtick in site): char-guard rejects, and the backtick is NEVER shell-evaluated -> exit 1" 1
stderr_has "login(backtick in site): diagnostic" "not in the allowed shape"
check "login(backtick in site): the backtick payload never executed (no pwned file)" "command substitution executed!" \
	"$( [ ! -e "$WORK/pwned" ] && echo 0 || echo 1 )"

fresh_cred_dir
NEWLINE_SITE="evil.atlassian.net
injected-line.atlassian.net"
STDIN_DATA=""
run sh "$LOGIN" --site "$NEWLINE_SITE"
expect_rc "login(embedded newline in site, reachable half): char-guard rejects -> exit 1" 1
stderr_has "login(embedded newline in site): diagnostic" "not in the allowed shape"
check "login(embedded newline in site): no file written" "unexpected file(s) present" \
	"$( [ ! -d "$CRED_DIR" ] || [ -z "$(ls -A "$CRED_DIR" 2>/dev/null)" ] && echo 0 || echo 1 )"

# The OTHER half (documented, not tested here — and not a gap):
# store_credential() ALSO rejects a newline embedded in $ACCOUNT_EMAIL or
# $API_TOKEN (`case "$X" in *"$NL"*) ...`). That guard cannot be exercised
# through THIS script's actual entry points: both fields are populated
# exclusively via `IFS= read -r`, which by POSIX definition always returns
# at most one line — a `read` result can never itself contain an embedded
# "\n". The guard is intentional defense-in-depth for a future non-prompt
# caller (e.g. a programmatic/env-var credential path), not dead code to
# delete, but a test claiming to feed it a "newline-containing token" via
# this CLI would be asserting something the harness cannot actually
# produce — exactly the false-confidence failure mode standard-testing
# warns against. The reachable half of this concern — a newline in --site,
# a plain argv string that CAN contain one — is the case directly above.

section "jira-login.sh — declines to overwrite without confirmation"
fresh_cred_dir
STDIN_DATA="example.atlassian.net
qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN"
expect_rc "login(seed): -> exit 0" 0
STDIN_DATA="example.atlassian.net
n
"
run sh "$LOGIN"
expect_rc "login(overwrite-decline): -> exit 0 (no changes)" 0
stdout_has "login(overwrite-decline): no-changes message" "No changes made"
check "login(overwrite-decline): original email preserved" "credential was overwritten" \
	"$( grep -Fq 'qa@example.com' "$CRED_DIR/example.atlassian.net.cfg" && echo 0 || echo 1 )"

section "jira-login.sh — curl_config_escape round-trips a token containing \" and \\"
# curl_config_escape() escapes backslash FIRST, then the double quote (order
# matters — see its header comment). A token containing BOTH must produce a
# well-formed `user = "..."` line (every embedded quote/backslash escaped,
# no premature terminator) AND the email half must still recover correctly
# through jira-auth-status.sh.
fresh_cred_dir
TOKEN_WITH_SPECIALS='tok"with\backslash-and-quote'
STDIN_DATA="qa@escape.example.com
$TOKEN_WITH_SPECIALS
"
run sh "$LOGIN" --site example.atlassian.net
expect_rc "escape(seed): -> exit 0" 0
check "escape: stored file is well-formed curl -K (escaped \\\" and \\\\ inside the quoted value)" \
	"not well-formed -K after escaping" \
	"$( grep -Eq '^user = "([^"\\]|\\.)*"$' "$CRED_DIR/example.atlassian.net.cfg" && echo 0 || echo 1 )"
stdout_lacks "escape: raw unescaped token never on stdout" "$TOKEN_WITH_SPECIALS"
stderr_lacks "escape: raw unescaped token never on stderr" "$TOKEN_WITH_SPECIALS"

run sh "$STATUS" --site example.atlassian.net
expect_rc "escape: status resolves despite the special-char token -> exit 0" 0
stdout_line_is "escape: email recovers exactly, unaffected by the token's quote/backslash" \
	"JIRA_AUTH_ACCOUNT=qa@escape.example.com"

section "jira-login.sh — degrades gracefully when stty is entirely unavailable"
# stty_echo_off() guards `stty` with `command -v`; when stty is absent from
# PATH the guard must simply no-op (falls back to a plain, echoing `read`)
# rather than erroring the whole login. (The actual echo-suppression on a
# real TTY is a separate, pty-only concern — see the file header note.)
fresh_cred_dir
RUN_TOOLBOX="$NOSTTY_TOOLBOX"
STDIN_DATA="qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN" --site example.atlassian.net
expect_rc "nostty: login still succeeds without stty on PATH -> exit 0" 0
check "nostty: credential stored correctly" "cred file missing" \
	"$( [ -f "$CRED_DIR/example.atlassian.net.cfg" ] && echo 0 || echo 1 )"
stdout_lacks "nostty: token NEVER on stdout" "$TOKEN_MARKER"
stderr_lacks "nostty: token NEVER on stderr" "$TOKEN_MARKER"

section "jira-login.sh — usage"
fresh_cred_dir
run sh "$LOGIN" -h
expect_rc "login(usage): -h -> exit 0" 0
stdout_has "login(usage): help text" "Usage:"
run sh "$LOGIN" --bogus
expect_rc "login(usage): unknown flag -> exit 2" 2

# ===========================================================================
# jira-auth-status.sh — read-only reporting, no token leak
# ===========================================================================
section "jira-auth-status.sh — reports the default site + account"
fresh_cred_dir
STDIN_DATA="example.atlassian.net
qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN"
expect_rc "status(seed login): -> exit 0" 0

run sh "$STATUS"
expect_rc "status: default resolved -> exit 0" 0
stdout_has  "status: JIRA_AUTH_CONFIGURED=true"        "JIRA_AUTH_CONFIGURED=true"
stdout_has  "status: JIRA_AUTH_SITES lists it"          "JIRA_AUTH_SITES=example.atlassian.net"
stdout_has  "status: JIRA_AUTH_DEFAULT_SITE"            "JIRA_AUTH_DEFAULT_SITE=example.atlassian.net"
stdout_has  "status: JIRA_AUTH_SITE resolved to default" "JIRA_AUTH_SITE=example.atlassian.net"
stdout_has  "status: JIRA_AUTH_SITE_CONFIGURED=true"    "JIRA_AUTH_SITE_CONFIGURED=true"
stdout_has  "status: JIRA_AUTH_ACCOUNT is the email"    "JIRA_AUTH_ACCOUNT=qa@example.com"
stdout_lacks "status: token NEVER on stdout"            "$TOKEN_MARKER"
stderr_lacks "status: token NEVER on stderr"            "$TOKEN_MARKER"

section "jira-auth-status.sh — --site overrides the default"
# self-contained (its OWN fresh_cred_dir + both sites reseeded)
# rather than relying on the previous section's leftover state — this
# section's assertions hold no matter what ran before it.
fresh_cred_dir
STDIN_DATA="example.atlassian.net
qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN"
expect_rc "status(seed 1st site): -> exit 0" 0
STDIN_DATA="dev@example.com
$TOKEN_MARKER-2
"
run sh "$LOGIN" --site acme.atlassian.net
expect_rc "status(seed 2nd site): -> exit 0" 0

run sh "$STATUS" --site acme.atlassian.net
expect_rc "status(--site): -> exit 0" 0
stdout_has "status(--site): reports the requested site, not the default" "JIRA_AUTH_SITE=acme.atlassian.net"
stdout_has "status(--site): account matches that site" "JIRA_AUTH_ACCOUNT=dev@example.com"
stdout_has "status(--site): default still example" "JIRA_AUTH_DEFAULT_SITE=example.atlassian.net"
stdout_has "status(--site): both sites listed" "JIRA_AUTH_SITES=acme.atlassian.net,example.atlassian.net"

section "jira-auth-status.sh — GATING regression: a token containing a colon must not leak into the reported email"
# The bug: a GREEDY `s/^user = "\(.*\):.*"$/\1/p` splits on the LAST colon,
# so a token like "abc:def:ghi" would splice "abc:def" into
# JIRA_AUTH_ACCOUNT instead of just the email. curl itself splits
# "user:password" on the FIRST colon — this asserts the fix matches that.
fresh_cred_dir
TOKEN_WITH_COLONS="ATATT3xFfGF0:abc123:xyz789-colon-laden-token"
STDIN_DATA="colon-victim@example.com
$TOKEN_WITH_COLONS
"
run sh "$LOGIN" --site example.atlassian.net
expect_rc "sec001(seed): -> exit 0" 0

run sh "$STATUS" --site example.atlassian.net
expect_rc "sec001: -> exit 0" 0
stdout_line_is "sec001: JIRA_AUTH_ACCOUNT is EXACTLY the email, not spliced with token bytes" \
	"JIRA_AUTH_ACCOUNT=colon-victim@example.com"
stdout_lacks "sec001: no token fragment ('abc123') leaked into stdout" "abc123"
stderr_lacks "sec001: no token fragment ('abc123') leaked into stderr" "abc123"
stdout_lacks "sec001: full token NEVER on stdout" "$TOKEN_WITH_COLONS"
stderr_lacks "sec001: full token NEVER on stderr" "$TOKEN_WITH_COLONS"

section "jira-auth-status.sh — a dangling default marker is never reported as active"
# Simulate drift: the marker still names a site whose credential file was
# removed by some OTHER means (not jira-accounts.sh remove, which itself
# keeps the marker consistent — see the dedicated test for that path).
fresh_cred_dir
STDIN_DATA="example.atlassian.net
qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN"
expect_rc "sh003(seed): -> exit 0" 0
rm -f "$CRED_DIR/example.atlassian.net.cfg"   # drift: delete out from under the marker

run sh "$STATUS"
expect_rc "sh003: dangling default -> exit 1 (not silently trusted)" 1
stdout_line_is "sh003: JIRA_AUTH_DEFAULT_SITE is EMPTY, not the dangling site" "JIRA_AUTH_DEFAULT_SITE="
stderr_has "sh003: diagnostic" "no default site is configured"

section "jira-auth-status.sh — unconfigured site fails closed"
fresh_cred_dir  # self-contained — an entirely empty store is
                # sufficient (and clearer) for "this ONE site is unconfigured"
run sh "$STATUS" --site unknown.atlassian.net
expect_rc "status(unknown): -> exit 1" 1
stdout_has "status(unknown): JIRA_AUTH_SITE_CONFIGURED=false" "JIRA_AUTH_SITE_CONFIGURED=false"
stdout_line_is "status(unknown): JIRA_AUTH_ACCOUNT is EMPTY (whole-line, not substring)" "JIRA_AUTH_ACCOUNT="
stderr_has "status(unknown): diagnostic" "no credential configured"

section "jira-auth-status.sh — nothing configured at all"
fresh_cred_dir
run sh "$STATUS"
expect_rc "status(empty): -> exit 1" 1
stdout_has "status(empty): JIRA_AUTH_CONFIGURED=false" "JIRA_AUTH_CONFIGURED=false"
stderr_has "status(empty): diagnostic" "no default site is configured"

section "jira-auth-status.sh — usage"
run sh "$STATUS" -h
expect_rc "status(usage): -h -> exit 0" 0
run sh "$STATUS" --bogus
expect_rc "status(usage): unknown flag -> exit 2" 2

# ===========================================================================
# jira-curl-config.sh — the engine handoff contract
# ===========================================================================
section "jira-curl-config.sh — prints the stored file's path"
fresh_cred_dir
STDIN_DATA="qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN" --site example.atlassian.net
expect_rc "curlcfg(seed): -> exit 0" 0

run sh "$CURLCFG" --site example.atlassian.net
expect_rc "curlcfg: -> exit 0" 0
check "curlcfg: printed path IS the stored file" "path mismatch" \
	"$( [ "$CUR_OUT" = "$CRED_DIR/example.atlassian.net.cfg" ] && echo 0 || echo 1 )"
stdout_lacks "curlcfg: token NEVER on stdout" "$TOKEN_MARKER"
stderr_lacks "curlcfg: token NEVER on stderr" "$TOKEN_MARKER"  # symmetry with the stdout check above
check "curlcfg: printed file is -K shaped (user = \"...\")" "not curl -K shaped" \
	"$( grep -Eq '^user = "[^"]+"$' "$CUR_OUT" && echo 0 || echo 1 )"
check "curlcfg: printed file mode 600" "wrong mode" \
	"$( [ "$(stat -f '%Lp' "$CUR_OUT" 2>/dev/null || stat -c '%a' "$CUR_OUT")" = "600" ] && echo 0 || echo 1 )"

section "jira-curl-config.sh — --copy produces an independent 600 temp file"
run sh "$CURLCFG" --site example.atlassian.net --copy
expect_rc "curlcfg(--copy): -> exit 0" 0
COPY_PATH=$CUR_OUT
check "curlcfg(--copy): path DIFFERS from the stored original" "copy path == original" \
	"$( [ "$COPY_PATH" != "$CRED_DIR/example.atlassian.net.cfg" ] && echo 0 || echo 1 )"
check "curlcfg(--copy): copy mode 600" "wrong mode" \
	"$( [ "$(stat -f '%Lp' "$COPY_PATH" 2>/dev/null || stat -c '%a' "$COPY_PATH")" = "600" ] && echo 0 || echo 1 )"
check "curlcfg(--copy): copy content matches the original" "content mismatch" \
	"$( diff -q "$COPY_PATH" "$CRED_DIR/example.atlassian.net.cfg" >/dev/null 2>&1 && echo 0 || echo 1 )"
rm -f "$COPY_PATH"

section "jira-curl-config.sh — normalizes https:// + trailing path"
run sh "$CURLCFG" --site "https://example.atlassian.net/some/path"
expect_rc "curlcfg(normalize): -> exit 0" 0
check "curlcfg(normalize): resolves to the same stored file" "normalization failed" \
	"$( [ "$CUR_OUT" = "$CRED_DIR/example.atlassian.net.cfg" ] && echo 0 || echo 1 )"

section "jira-curl-config.sh — FAILS CLOSED for an unconfigured site"
run sh "$CURLCFG" --site never-logged-in.atlassian.net
expect_rc "curlcfg(unconfigured): -> exit 1 (fail closed)" 1
stderr_has "curlcfg(unconfigured): clear message" "no credential stored for site"
check "curlcfg(unconfigured): NOTHING printed to stdout" "stdout not empty on failure" \
	"$( [ -z "$CUR_OUT" ] && echo 0 || echo 1 )"

section "jira-curl-config.sh — fails closed for a disallowed-shape site (defense-in-depth at this SINK, not just at login time)"
run sh "$CURLCFG" --site ".."
expect_rc "curlcfg(dot-dot): rejected by the sink's OWN allow-list check -> exit 1" 1
stderr_has "curlcfg(dot-dot): diagnostic" "not in the allowed shape"
check "curlcfg(dot-dot): NOTHING printed to stdout" "stdout not empty on rejection" \
	"$( [ -z "$CUR_OUT" ] && echo 0 || echo 1 )"
run sh "$CURLCFG" --site "evil space.atlassian.net"
expect_rc "curlcfg(space): rejected -> exit 1" 1
stderr_has "curlcfg(space): diagnostic" "not in the allowed shape"

section "jira-curl-config.sh — usage"
run sh "$CURLCFG" -h
expect_rc "curlcfg(usage): -h -> exit 0" 0
run sh "$CURLCFG"
expect_rc "curlcfg(usage): missing --site -> exit 2" 2
stderr_has "curlcfg(usage): diagnostic" "--site is required"

# ===========================================================================
# jira-accounts.sh — list / default / set-default / remove
# ===========================================================================

# seed_two_sites — helper: makes every section below self-contained
# (its own fresh_cred_dir + explicit reseed) instead of silently depending
# on whatever the PRECEDING section left behind. Always leaves
# example.atlassian.net as the default (the first site logged in).
seed_two_sites() {
	fresh_cred_dir
	STDIN_DATA="qa@example.com
$TOKEN_MARKER
"
	run sh "$LOGIN" --site example.atlassian.net
	STDIN_DATA="dev@example.com
$TOKEN_MARKER-2
"
	run sh "$LOGIN" --site acme.atlassian.net
}

section "jira-accounts.sh — list (human + json) and default"
seed_two_sites

run sh "$ACCOUNTS" list
expect_rc "accounts(list): -> exit 0" 0
stdout_has  "accounts(list): both sites"        "acme.atlassian.net"
stdout_has  "accounts(list): default marked"    "* example.atlassian.net [default]"
stdout_has  "accounts(list): machine sites line" "JIRA_ACCOUNTS_SITES=acme.atlassian.net,example.atlassian.net"
stdout_lacks "accounts(list): token NEVER on stdout" "$TOKEN_MARKER"
stderr_lacks "accounts(list): token NEVER on stderr" "$TOKEN_MARKER"  # symmetry with the stdout check above

run sh "$ACCOUNTS" list --json
expect_rc "accounts(list --json): -> exit 0" 0
stdout_has "accounts(list --json): valid-looking JSON array" '[{"site":'
stdout_has "accounts(list --json): default true for example" '"site":"example.atlassian.net","default":true'
stdout_has "accounts(list --json): default false for acme" '"site":"acme.atlassian.net","default":false'

run sh "$ACCOUNTS" default
expect_rc "accounts(default): -> exit 0" 0
stdout_has "accounts(default): reports example" "JIRA_ACCOUNTS_DEFAULT=example.atlassian.net"

section "jira-accounts.sh — set-default switches the active site"
seed_two_sites
run sh "$ACCOUNTS" set-default --site acme.atlassian.net
expect_rc "accounts(set-default): -> exit 0" 0
run sh "$ACCOUNTS" default
stdout_has "accounts(set-default): now acme" "JIRA_ACCOUNTS_DEFAULT=acme.atlassian.net"
run sh "$STATUS"
stdout_has "accounts(set-default): jira-auth-status agrees" "JIRA_AUTH_DEFAULT_SITE=acme.atlassian.net"

section "jira-accounts.sh — set-default fails closed for an unconfigured site"
seed_two_sites
run sh "$ACCOUNTS" set-default --site never-logged-in.atlassian.net
expect_rc "accounts(set-default unconfigured): -> exit 1" 1
stderr_has "accounts(set-default unconfigured): diagnostic" "no credential stored for site"

section "jira-accounts.sh — set-default/remove fail closed for a disallowed-shape site (this SINK's own check, not just login's)"
seed_two_sites
run sh "$ACCOUNTS" set-default --site ".."
expect_rc "accounts(set-default dot-dot): rejected by the sink's OWN allow-list check -> exit 1" 1
stderr_has "accounts(set-default dot-dot): diagnostic" "not in the allowed shape"
run sh "$ACCOUNTS" remove --site "evil space.atlassian.net" --force
expect_rc "accounts(remove space): rejected -> exit 1" 1
stderr_has "accounts(remove space): diagnostic" "not in the allowed shape"

section "jira-accounts.sh — remove requires --force"
seed_two_sites
run sh "$ACCOUNTS" remove --site example.atlassian.net
expect_rc "accounts(remove no-force): -> exit 2" 2
stderr_has "accounts(remove no-force): diagnostic" "--force to confirm"
check "accounts(remove no-force): credential NOT removed" "credential removed without --force" \
	"$( [ -f "$CRED_DIR/example.atlassian.net.cfg" ] && echo 0 || echo 1 )"

section "jira-accounts.sh — remove (with --force) clears the default if it was active"
seed_two_sites
run sh "$ACCOUNTS" set-default --site acme.atlassian.net
expect_rc "accounts(remove-active-default seed): -> exit 0" 0
run sh "$ACCOUNTS" remove --site acme.atlassian.net --force
expect_rc "accounts(remove): -> exit 0" 0
check "accounts(remove): credential file gone" "credential still present" \
	"$( [ ! -f "$CRED_DIR/acme.atlassian.net.cfg" ] && echo 0 || echo 1 )"
run sh "$ACCOUNTS" default
expect_rc "accounts(remove): default now unset -> exit 1" 1

section "jira-accounts.sh — removing a NON-default site leaves the default untouched"
seed_two_sites
# Default is example.atlassian.net (seed_two_sites' first login); remove the
# OTHER (non-default) site and confirm the default marker survives intact.
run sh "$ACCOUNTS" remove --site acme.atlassian.net --force
expect_rc "accounts(remove-non-default): -> exit 0" 0
check "accounts(remove-non-default): the removed site's file is gone" "credential still present" \
	"$( [ ! -f "$CRED_DIR/acme.atlassian.net.cfg" ] && echo 0 || echo 1 )"
run sh "$ACCOUNTS" default
expect_rc "accounts(remove-non-default): default SURVIVES -> exit 0" 0
stdout_has "accounts(remove-non-default): still example" "JIRA_ACCOUNTS_DEFAULT=example.atlassian.net"
run sh "$STATUS"
stdout_has "accounts(remove-non-default): jira-auth-status agrees" "JIRA_AUTH_DEFAULT_SITE=example.atlassian.net"

section "jira-accounts.sh — usage / errors"
run sh "$ACCOUNTS"
expect_rc "accounts(usage): no subcommand -> exit 2" 2
run sh "$ACCOUNTS" bogus-subcommand
expect_rc "accounts(usage): unknown subcommand -> exit 2" 2
run sh "$ACCOUNTS" -h
expect_rc "accounts(usage): -h -> exit 0" 0

section "jira-accounts.sh — empty store"
fresh_cred_dir
run sh "$ACCOUNTS" list
expect_rc "accounts(empty list): -> exit 1" 1
stdout_has "accounts(empty list): none message" "(none — run jira-login.sh)"
run sh "$ACCOUNTS" default
expect_rc "accounts(empty default): -> exit 1" 1

# ===========================================================================
# End-to-end: login -> curl-config path is exactly what jira.sh's
# $JIRA_CURL_CONFIG contract expects (a `-K`-shaped file), and the whole
# round trip never leaks the token anywhere outside the file itself.
# ===========================================================================
section "end-to-end — full round trip leaves the token ONLY in the credential file"
fresh_cred_dir
STDIN_DATA="example.atlassian.net
qa@example.com
$TOKEN_MARKER
"
run sh "$LOGIN"
ALL_OUT_1="$CUR_OUT $CUR_ERR"
run sh "$STATUS"
ALL_OUT_2="$CUR_OUT $CUR_ERR"
run sh "$CURLCFG" --site example.atlassian.net
ALL_OUT_3="$CUR_OUT $CUR_ERR"
run sh "$ACCOUNTS" list
ALL_OUT_4="$CUR_OUT $CUR_ERR"
check "e2e: token absent across every command's captured output" "token leaked somewhere" \
	"$( printf '%s\n%s\n%s\n%s\n' "$ALL_OUT_1" "$ALL_OUT_2" "$ALL_OUT_3" "$ALL_OUT_4" | grep -Fq "$TOKEN_MARKER" && echo 1 || echo 0 )"
check "e2e: token present exactly once, in the credential file" "unexpected token occurrence count" \
	"$( [ "$(grep -Frl "$TOKEN_MARKER" "$CRED_DIR" | wc -l | tr -d ' ')" = "1" ] && echo 0 || echo 1 )"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
