#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                procedure-github-auth script suite (gh-auth-status.sh +
#                manage_gh_accounts.sh).
#
# WHY a hand-rolled harness (not bats): the whole point of this suite is "runs
# on any machine with no dependencies". Requiring bats-core would contradict
# that. This harness needs only a POSIX sh plus the coreutils that already ship
# on macOS (BSD) and Linux (GNU).
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools the
#     scripts need (awk, grep, sed, ...) PLUS a STUB `gh` so no test ever
#     touches real auth, keyrings, or the network. The gh stub lives in its OWN
#     dir that tests opt into, so "gh absent" is exercised for real (by leaving
#     that dir off PATH).
#   * The gh stub is fully env-driven: tests set GH_STUB_* variables to script
#     the exact `gh auth status` text, api login, switch/login return codes, and
#     a mutable auth statefile — so every deterministic branch is covered.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR and is
#     cleaned up on exit. NO_COLOR=1 keeps captured output byte-clean.
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
STATUS="$SCRIPTS_DIR/gh-auth-status.sh"
MANAGE="$SCRIPTS_DIR/manage_gh_accounts.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/gh-auth-tests.XXXXXX")
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
for t in sh env awk sed grep cut head cat tr sort rm mkdir mktemp dirname uname; do
	link_tool "$t"
done

# ---------------------------------------------------------------------------
# gh stub — fully env-driven so tests script every deterministic branch.
#   GH_STUB_AUTHED=1        -> `gh auth status` succeeds (unless statefile set)
#   GH_STUB_STATEFILE=path  -> authed iff the file contains "1" (mutable across
#                              calls; `gh auth login` flips it to "1")
#   GH_STUB_STATUS=text     -> exact `gh auth status` body to print
#   GH_STUB_API_LOGIN=login -> `gh api user --jq .login` output
#   GH_STUB_SWITCH_RC / GH_STUB_LOGIN_RC -> return codes for those subcommands
#   GH_STUB_LOG=path        -> append a line per switch/login/logout invocation
# ---------------------------------------------------------------------------
cat > "$GHDIR/gh" <<'GH_STUB'
#!/usr/bin/env sh
set -eu
log_call() {
	if [ -n "${GH_STUB_LOG:-}" ]; then printf '%s\n' "$*" >> "$GH_STUB_LOG"; fi
}
is_authed() {
	if [ -n "${GH_STUB_STATEFILE:-}" ] && [ -f "$GH_STUB_STATEFILE" ]; then
		[ "$(cat "$GH_STUB_STATEFILE")" = "1" ]
	else
		[ "${GH_STUB_AUTHED:-0}" = "1" ]
	fi
}
case "${1:-}" in
	--version)
		printf 'gh version 2.50.0 (2024-01-01)\n'
		exit 0 ;;
	auth)
		case "${2:-}" in
			status)
				if is_authed; then
					printf '%s\n' "${GH_STUB_STATUS:-}"
					exit 0
				else
					printf 'You are not logged into any GitHub hosts. Run gh auth login.\n' >&2
					exit 1
				fi ;;
			switch)
				log_call "switch $*"
				exit "${GH_STUB_SWITCH_RC:-0}" ;;
			login)
				log_call "login $*"
				if [ -n "${GH_STUB_STATEFILE:-}" ]; then printf '1' > "$GH_STUB_STATEFILE"; fi
				exit "${GH_STUB_LOGIN_RC:-0}" ;;
			logout)
				log_call "logout $*"
				exit 0 ;;
			*) exit 0 ;;
		esac ;;
	api)
		# emulates `gh api user --jq '.login'`
		printf '%s\n' "${GH_STUB_API_LOGIN:-}"
		exit 0 ;;
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
STDIN_DATA=""      # set before a `run` to feed the script's stdin

# run <with_gh:0|1> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> under the isolated toolbox PATH (+ gh stub only when with_gh=1),
#   with an isolated HOME/TMPDIR and NO_COLOR=1. Leading VAR=VALUE arguments are
#   passed straight to `env` (values may contain spaces or newlines). stdin is
#   fed from $STDIN_DATA (default empty). Captures stdout, stderr, exit code.
run() {
	r_gh=$1; shift
	r_path="$TOOLBOX"
	[ "$r_gh" = "1" ] && r_path="$GHDIR:$TOOLBOX"
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
	if printf '%s\n' "$CUR_OUT" | grep -Fq "$2"; then pass "$1"
	else fail "$1" "stdout missing: $2"; fi
}

stdout_lacks() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq "$2"; then fail "$1" "stdout unexpectedly contains: $2"
	else pass "$1"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

# stdout_re — assert stdout matches an extended regex (used for exact-line
# checks like an EMPTY machine value: '^GH_ACTIVE_ACCOUNT=$').
stdout_re() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Eq "$2"; then pass "$1"
	else fail "$1" "stdout not matching /$2/"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# Fixtures — `gh auth status` bodies for the various states/formats.
# ---------------------------------------------------------------------------
STATUS_MODERN_SINGLE='github.com
  ✓ Logged in to github.com account octocat (keyring)
  - Active account: true
  - Git operations protocol: https
  - Token: gho_************************************'

STATUS_LEGACY_SINGLE='github.com
  ✓ Logged in to github.com as octocat (oauth_token)'

STATUS_MODERN_MULTI='github.com
  ✓ Logged in to github.com account octocat (keyring)
  - Active account: true
  - Git operations protocol: https
  ✓ Logged in to github.com account hubot (keyring)
  - Active account: false
  - Git operations protocol: https'

STATUS_ENTERPRISE_MULTI='ghe.example.com
  ✓ Logged in to ghe.example.com account octocat (keyring)
  - Active account: true
  - Git operations protocol: ssh
github.com
  ✓ Logged in to github.com account hubot (keyring)
  - Active account: false'

STATUS_NOMARKER_MULTI='github.com
  ✓ Logged in to github.com account octocat (keyring)
  ✓ Logged in to github.com account hubot (keyring)'

# A failure line ("X Failed to log in ...") must NOT be parsed as an account.
STATUS_WITH_FAILURE='github.com
  X Failed to log in to github.com account ghost (keyring)
  ✓ Logged in to github.com account octocat (keyring)
  - Active account: true'

# Two hosts, DIFFERENT logins, EACH active (gh keeps one active per host).
# The active account is genuinely ambiguous without a host.
STATUS_TWO_HOSTS_BOTH_ACTIVE='github.com
  ✓ Logged in to github.com account octocat (keyring)
  - Active account: true
ghe.example.com
  ✓ Logged in to ghe.example.com account hubot (keyring)
  - Active account: true'

# Two hosts, SAME login, each active. The other-host account must remain a
# valid switch target (must not be hidden by a login-only comparison).
STATUS_SAME_LOGIN_TWO_HOSTS='github.com
  ✓ Logged in to github.com account octocat (keyring)
  - Active account: true
ghe.example.com
  ✓ Logged in to ghe.example.com account octocat (keyring)
  - Active account: true'

# Two hosts, same login, NO active markers (legacy) -> api fallback must
# recover the host by PREFERRING github.com (the host `gh api user` queries).
STATUS_NOMARKER_TWOHOST='github.com
  ✓ Logged in to github.com account octocat (keyring)
ghe.example.com
  ✓ Logged in to ghe.example.com account octocat (keyring)'

# ===========================================================================
# gh-auth-status.sh
# ===========================================================================
section "gh-auth-status.sh — authenticated (single, modern format)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_SINGLE" sh "$STATUS"
expect_rc "status: single account -> exit 0" 0
stdout_has "status: GH_INSTALLED=true"        "GH_INSTALLED=true"
stdout_has "status: GH_AUTHENTICATED=true"    "GH_AUTHENTICATED=true"
stdout_has "status: active account octocat"   "GH_ACTIVE_ACCOUNT=octocat"
stdout_has "status: host github.com"          "GH_HOST=github.com"
stdout_has "status: accounts list"            "GH_ACCOUNTS=octocat"
stdout_has "status: human active marker"      "[active]"

section "gh-auth-status.sh — authenticated (single, LEGACY 'as' format)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_LEGACY_SINGLE" sh "$STATUS"
expect_rc "status(legacy): single account -> exit 0" 0
stdout_has "status(legacy): active via single-account inference" "GH_ACTIVE_ACCOUNT=octocat"
stdout_has "status(legacy): host resolved" "GH_HOST=github.com"

section "gh-auth-status.sh — authenticated (multiple accounts, active marked)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" sh "$STATUS"
expect_rc "status(multi): -> exit 0" 0
stdout_has "status(multi): active is octocat"      "GH_ACTIVE_ACCOUNT=octocat"
stdout_has "status(multi): full list octocat,hubot" "GH_ACCOUNTS=octocat,hubot"
stdout_has "status(multi): host github.com"        "GH_HOST=github.com"
run1=$CUR_OUT
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" sh "$STATUS"
check "status(multi): deterministic across identical runs" "output differed between runs" \
	"$( [ "$run1" = "$CUR_OUT" ] && echo 0 || echo 1 )"

section "gh-auth-status.sh — Enterprise host, active on ghe"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_ENTERPRISE_MULTI" sh "$STATUS"
expect_rc "status(ghe): -> exit 0" 0
stdout_has "status(ghe): active octocat"        "GH_ACTIVE_ACCOUNT=octocat"
stdout_has "status(ghe): Enterprise host wins"  "GH_HOST=ghe.example.com"
stdout_has "status(ghe): both accounts listed"  "GH_ACCOUNTS=octocat,hubot"

section "gh-auth-status.sh — no active marker -> gh api fallback"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_NOMARKER_MULTI" "GH_STUB_API_LOGIN=hubot" sh "$STATUS"
expect_rc "status(api-fallback): -> exit 0" 0
stdout_has "status(api-fallback): active from gh api" "GH_ACTIVE_ACCOUNT=hubot"
stdout_has "status(api-fallback): host recovered"     "GH_HOST=github.com"

section "gh-auth-status.sh — parsing robustness (failure line ignored)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_WITH_FAILURE" sh "$STATUS"
expect_rc "status(robust): -> exit 0" 0
stdout_has  "status(robust): real account parsed"   "GH_ACTIVE_ACCOUNT=octocat"
stdout_lacks "status(robust): failed 'ghost' not listed" "ghost"
stdout_has  "status(robust): accounts == octocat only" "GH_ACCOUNTS=octocat"

section "gh-auth-status.sh — not authenticated"
run 1 "GH_STUB_AUTHED=0" sh "$STATUS"
expect_rc "status(unauth): -> exit 1" 1
stdout_has "status(unauth): GH_AUTHENTICATED=false" "GH_AUTHENTICATED=false"
stdout_has "status(unauth): GH_INSTALLED still true" "GH_INSTALLED=true"
stderr_has "status(unauth): diagnostic" "not authenticated"

section "gh-auth-status.sh — gh absent"
run 0 sh "$STATUS"
expect_rc "status(no-gh): -> exit 1" 1
stdout_has "status(no-gh): GH_INSTALLED=false"     "GH_INSTALLED=false"
stdout_has "status(no-gh): GH_AUTHENTICATED=false" "GH_AUTHENTICATED=false"
stderr_has "status(no-gh): install hint" "cli.github.com"

section "gh-auth-status.sh — usage"
run 1 sh "$STATUS" -h
expect_rc "status(usage): -h -> exit 0" 0
stdout_has "status(usage): help text" "Usage:"
run 1 sh "$STATUS" --bogus
expect_rc "status(usage): unknown flag -> exit 2" 2
stderr_has "status(usage): unknown-flag diagnostic" "unknown option"
run 1 sh "$STATUS" extra
expect_rc "status(usage): positional arg -> exit 2" 2
run 1 sh "$STATUS" --host
expect_rc "status(usage): --host without value -> exit 2" 2

section "gh-auth-status.sh — two hosts BOTH active -> ambiguous (no guess)"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_TWO_HOSTS_BOTH_ACTIVE" sh "$STATUS"
expect_rc "status(ambiguous): -> exit 1 (fail-closed)" 1
stdout_has "status(ambiguous): flag set"          "GH_ACTIVE_AMBIGUOUS=true"
stdout_re  "status(ambiguous): active account EMPTY (no guess)" '^GH_ACTIVE_ACCOUNT=$'
stdout_re  "status(ambiguous): host EMPTY (no guess)"           '^GH_HOST=$'
stdout_has "status(ambiguous): lists octocat@github.com" "octocat@github.com"
stdout_has "status(ambiguous): lists hubot@ghe.example.com" "hubot@ghe.example.com"
stderr_has "status(ambiguous): diagnostic" "multiple hosts have an active account"
run1=$CUR_OUT
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_TWO_HOSTS_BOTH_ACTIVE" sh "$STATUS"
check "status(ambiguous): deterministic active set ordering" "active set order differed between runs" \
	"$( [ "$run1" = "$CUR_OUT" ] && echo 0 || echo 1 )"

section "gh-auth-status.sh — --host disambiguates the multi-host case"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_TWO_HOSTS_BOTH_ACTIVE" sh "$STATUS" --host github.com
expect_rc "status(--host github.com): -> exit 0" 0
stdout_has "status(--host github.com): active octocat"     "GH_ACTIVE_ACCOUNT=octocat"
stdout_has "status(--host github.com): host github.com"    "GH_HOST=github.com"
stdout_has "status(--host github.com): not ambiguous"      "GH_ACTIVE_AMBIGUOUS=false"
stdout_has "status(--host github.com): accounts host-scoped" "GH_ACCOUNTS=octocat"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_TWO_HOSTS_BOTH_ACTIVE" sh "$STATUS" --host ghe.example.com
expect_rc "status(--host ghe): -> exit 0" 0
stdout_has "status(--host ghe): active hubot" "GH_ACTIVE_ACCOUNT=hubot"
stdout_has "status(--host ghe): host ghe"     "GH_HOST=ghe.example.com"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_TWO_HOSTS_BOTH_ACTIVE" sh "$STATUS" --host nope.example.com
expect_rc "status(--host unknown): -> exit 1" 1
stderr_has "status(--host unknown): diagnostic" "no active account resolved for host"

section "gh-auth-status.sh — api fallback prefers github.com for host recovery"
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_NOMARKER_TWOHOST" "GH_STUB_API_LOGIN=octocat" sh "$STATUS"
expect_rc "status(api-host-pref): -> exit 0" 0
stdout_has "status(api-host-pref): active octocat" "GH_ACTIVE_ACCOUNT=octocat"
stdout_has "status(api-host-pref): host is github.com (not ghe)" "GH_HOST=github.com"

# ===========================================================================
# manage_gh_accounts.sh
# ===========================================================================
section "manage_gh_accounts.sh — usage / gh absent"
run 1 sh "$MANAGE" -h
expect_rc "manage(usage): -h -> exit 0" 0
stdout_has "manage(usage): help text" "Usage:"
run 1 sh "$MANAGE" --bogus
expect_rc "manage(usage): unknown flag -> exit 1" 1
stderr_has "manage(usage): diagnostic" "unknown option"

run 0 sh "$MANAGE"
expect_rc "manage(no-gh): -> exit 1" 1
stderr_has "manage(no-gh): 'not installed' error" "not installed"
stdout_has "manage(no-gh): install hint" "cli.github.com"

section "manage_gh_accounts.sh — keep current account"
STDIN_DATA='3
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" "GH_STUB_LOG=$WORK/ghlog1" sh "$MANAGE"
expect_rc "manage(keep): -> exit 0" 0
stdout_has "manage(keep): keeps active octocat" "Keeping the current account: octocat"
check "manage(keep): no switch/login was invoked" "gh mutation happened on keep" \
	"$( [ ! -f "$WORK/ghlog1" ] && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — deterministic switch (gh auth switch)"
STDIN_DATA='1
1
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" "GH_STUB_LOG=$WORK/ghlog2" sh "$MANAGE"
expect_rc "manage(switch): -> exit 0" 0
stdout_has "manage(switch): announces target" "Switching to hubot on github.com"
check "manage(switch): invoked gh auth switch" "switch not recorded" \
	"$( [ -f "$WORK/ghlog2" ] && grep -Fq 'switch' "$WORK/ghlog2" && echo 0 || echo 1 )"
check "manage(switch): --user hubot passed" "--user hubot missing" \
	"$( grep -Fq -- '--user hubot' "$WORK/ghlog2" && echo 0 || echo 1 )"
check "manage(switch): --hostname github.com passed" "--hostname missing" \
	"$( grep -Fq -- '--hostname github.com' "$WORK/ghlog2" && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — switch to Enterprise account uses its host"
STDIN_DATA='1
1
'
# Active is octocat@ghe; the only other account is hubot@github.com.
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_ENTERPRISE_MULTI" "GH_STUB_LOG=$WORK/ghlog3" sh "$MANAGE"
expect_rc "manage(switch-ghe): -> exit 0" 0
check "manage(switch-ghe): switched to hubot on github.com" "wrong host/user" \
	"$( grep -Fq -- '--user hubot' "$WORK/ghlog3" && grep -Fq -- '--hostname github.com' "$WORK/ghlog3" && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — switch cancelled"
STDIN_DATA='1
c
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" "GH_STUB_LOG=$WORK/ghlog4" sh "$MANAGE"
expect_rc "manage(switch-cancel): -> exit 1" 1
check "manage(switch-cancel): no switch invoked" "switch invoked despite cancel" \
	"$( [ ! -f "$WORK/ghlog4" ] && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — switch requested but no other accounts"
STDIN_DATA='1
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_SINGLE" "GH_STUB_LOG=$WORK/ghlog5" sh "$MANAGE"
expect_rc "manage(switch-none): -> exit 1" 1
stderr_has "manage(switch-none): explains no candidates" "No other logged-in accounts"

section "manage_gh_accounts.sh — switch subcommand fails"
STDIN_DATA='1
1
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" "GH_STUB_SWITCH_RC=1" "GH_STUB_LOG=$WORK/ghlog6" sh "$MANAGE"
expect_rc "manage(switch-fail): -> exit 1" 1
stderr_has "manage(switch-fail): reports failure" "gh auth switch failed"

section "manage_gh_accounts.sh — not authenticated, user declines login"
STDIN_DATA='n
'
run 1 "GH_STUB_AUTHED=0" sh "$MANAGE"
expect_rc "manage(unauth-decline): -> exit 0" 0
stdout_has "manage(unauth-decline): no changes" "No changes made"

section "manage_gh_accounts.sh — not authenticated, user logs in (statefile flips)"
printf '0' > "$WORK/state1"
STDIN_DATA='y
'
run 1 "GH_STUB_STATEFILE=$WORK/state1" "GH_STUB_STATUS=$STATUS_MODERN_SINGLE" "GH_STUB_LOG=$WORK/ghlog7" sh "$MANAGE"
expect_rc "manage(login): -> exit 0" 0
check "manage(login): invoked gh auth login" "login not recorded" \
	"$( [ -f "$WORK/ghlog7" ] && grep -Fq 'login' "$WORK/ghlog7" && echo 0 || echo 1 )"
stdout_has "manage(login): now-active reported" "octocat"

section "manage_gh_accounts.sh — authenticated, choose login (new account)"
printf '1' > "$WORK/state2"   # already authed; login adds/keeps auth
STDIN_DATA='2
'
run 1 "GH_STUB_STATEFILE=$WORK/state2" "GH_STUB_STATUS=$STATUS_MODERN_SINGLE" "GH_STUB_LOG=$WORK/ghlog8" sh "$MANAGE"
expect_rc "manage(menu-login): -> exit 0" 0
check "manage(menu-login): invoked gh auth login" "login not recorded" \
	"$( grep -Fq 'login' "$WORK/ghlog8" && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — gh api fallback branch (no markers)"
# Two accounts on one host, NO active markers -> manage must resolve the active
# via `gh api user` (its own duplicated fallback branch).
STDIN_DATA='3
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_NOMARKER_MULTI" "GH_STUB_API_LOGIN=octocat" "GH_STUB_LOG=$WORK/ghlog9" sh "$MANAGE"
expect_rc "manage(api-fallback): -> exit 0" 0
stdout_has "manage(api-fallback): resolved active octocat" "Keeping the current account: octocat"
check "manage(api-fallback): no mutation on keep" "gh mutated on keep" \
	"$( [ ! -f "$WORK/ghlog9" ] && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — same login on two hosts: other-host is offered"
# octocat active on BOTH hosts -> ambiguous. User picks github.com as current,
# then switches: the ONLY candidate must be octocat on ghe.example.com (it must
# NOT be excluded just because the login matches the active one).
STDIN_DATA='1
1
1
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_SAME_LOGIN_TWO_HOSTS" "GH_STUB_LOG=$WORK/ghlog10" sh "$MANAGE"
expect_rc "manage(same-login): -> exit 0" 0
check "manage(same-login): switched to octocat on ghe.example.com" "other-host account was hidden" \
	"$( grep -Fq -- '--user octocat' "$WORK/ghlog10" && grep -Fq -- '--hostname ghe.example.com' "$WORK/ghlog10" && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — two hosts both active: ambiguity surfaced"
# Different logins active on two hosts -> manage must PRESENT the choice, not
# silently resolve. User picks, then keeps.
STDIN_DATA='1
3
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_TWO_HOSTS_BOTH_ACTIVE" "GH_STUB_LOG=$WORK/ghlog11" sh "$MANAGE"
expect_rc "manage(ambiguous): -> exit 0" 0
stdout_has "manage(ambiguous): ambiguity surfaced" "Select which account is current"
stderr_has "manage(ambiguous): per-host warning" "Multiple hosts have an active account"
stdout_has "manage(ambiguous): user pick honored (octocat kept)" "Keeping the current account: octocat"
check "manage(ambiguous): nothing mutated" "gh mutated during ambiguity resolution" \
	"$( [ ! -f "$WORK/ghlog11" ] && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — stdin EOF at the authenticated menu -> keep"
STDIN_DATA=''
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" "GH_STUB_LOG=$WORK/ghlog12" sh "$MANAGE"
expect_rc "manage(menu-eof): -> exit 0" 0
stdout_has "manage(menu-eof): keeps current" "Keeping the current account: octocat"
check "manage(menu-eof): no mutation" "gh mutated on EOF" \
	"$( [ ! -f "$WORK/ghlog12" ] && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — unauthenticated + stdin EOF -> fail-safe decline"
STDIN_DATA=''
run 1 "GH_STUB_AUTHED=0" "GH_STUB_LOG=$WORK/ghlog13" sh "$MANAGE"
expect_rc "manage(unauth-eof): -> exit 0 (no silent login)" 0
stderr_has "manage(unauth-eof): EOF declined" "declining"
stdout_has "manage(unauth-eof): no changes" "No changes made"
check "manage(unauth-eof): login NOT attempted" "login attempted on EOF" \
	"$( [ ! -f "$WORK/ghlog13" ] && echo 0 || echo 1 )"

section "manage_gh_accounts.sh — exhausted retries at the menu -> exit 1"
STDIN_DATA='x
x
x
'
run 1 "GH_STUB_AUTHED=1" "GH_STUB_STATUS=$STATUS_MODERN_MULTI" "GH_STUB_LOG=$WORK/ghlog14" sh "$MANAGE"
expect_rc "manage(retries): -> exit 1" 1
stderr_has "manage(retries): max-retries diagnostic" "Maximum retries reached"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
