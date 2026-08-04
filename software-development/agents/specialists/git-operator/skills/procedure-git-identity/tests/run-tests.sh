#!/usr/bin/env sh
#
# run-tests.sh — self-contained, zero-dependency POSIX test harness for the
#                standard-git-identity script suite.
#
# WHY a hand-rolled harness (not bats): the entire point of this suite is
# "works on any computer with no dependencies". Requiring bats-core would
# contradict that. This harness needs only a POSIX sh, git, and the coreutils
# that already ship on macOS and Linux.
#
# What it does:
#   * Builds an isolated PATH "toolbox" of symlinks to only the real tools we
#     need (git, awk, sed, ...) plus STUBS for gpg / gh so tests never touch
#     real keys, keyrings, or the network. The gh stub lives in its OWN dir that
#     tests opt into, so "--github with gh absent" is exercised for real.
#   * Runs each script against a throwaway `git init` repo under a temp dir,
#     with HOME + git config fully isolated. Everything is cleaned up on exit.
#
# Usage:  sh run-tests.sh            # run all tests
#         VERBOSE=1 sh run-tests.sh
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../scripts" && pwd)
RESOLVE="$SCRIPTS_DIR/resolve-identity.sh"
LIST="$SCRIPTS_DIR/list-identities.sh"
SWITCH="$SCRIPTS_DIR/switch-identity.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/git-identity-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"
STUBS="$WORK/stubs"      # gpg stub (always on PATH)
GHDIR="$WORK/ghbin"      # gh stub  (only when a test opts in)
mkdir -p "$TOOLBOX" "$STUBS" "$GHDIR"

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
for t in git sh env awk sed grep cut tr head cat sort rm mkdir dirname mktemp uname; do
	link_tool "$t"
done
sshkg=$(PATH="$ORIG_PATH" command -v ssh-keygen 2>/dev/null || true)
[ -n "$sshkg" ] && ln -s "$sshkg" "$TOOLBOX/ssh-keygen"

# ---------------------------------------------------------------------------
# Stubs
# ---------------------------------------------------------------------------
# gpg: emulates `gpg --list-secret-keys [--with-colons] [--] [KEYID]`.
# Keys are declared via GPG_KEYS as ';'-joined entries; each entry is
# '|'-separated:  keyid|fpr|Name <email>[|directive...]
# Directives (repeatable):
#   sub:<subfpr>   emit a subkey (ssb + its fpr) after the primary uid
#   r:<uid>        emit a revoked  UID (validity 'r')
#   e:<uid>        emit an expired  UID (validity 'e')
# A KEYID lookup matches by exact OR prefix of keyid/fpr (mimicking gpg's fuzzy
# match, so a short id can resolve to several keys -> ambiguity). Absent -> 2.
cat > "$STUBS/gpg" <<'GPG_STUB'
#!/usr/bin/env sh
set -eu
want=""
for a in "$@"; do
	case "$a" in
		--) ;;
		-*) ;;
		list-secret-keys) ;;
		*) want=$a ;;
	esac
done
[ -n "${GPG_KEYS:-}" ] || exit 2
matched=0
saved_ifs=$IFS
IFS=';'
for entry in $GPG_KEYS; do
	IFS='|'
	# shellcheck disable=SC2086  # deliberate split of the '|'-separated entry
	set -- $entry
	IFS=$saved_ifs
	[ -n "${1:-}" ] || { IFS=';'; continue; }
	kid=$1; fpr=$2; uid=$3
	shift 3 2>/dev/null || shift $#
	if [ -n "$want" ]; then
		case "$kid" in "$want"*) : ;; *)
			case "$fpr" in "$want"*) : ;; *) IFS=';'; continue ;; esac
		esac
	fi
	matched=1
	printf 'sec:u:255:22:%s:::::::::\n' "$kid"
	printf 'fpr:::::::::%s:\n' "$fpr"
	printf 'uid:u::::::::%s:::::::::0:\n' "$uid"
	for d in "$@"; do
		case "$d" in
			sub:*) printf 'ssb:u:255:22:SUB%s:::::::::\n' "$kid"
			       printf 'fpr:::::::::%s:\n' "${d#sub:}" ;;
			r:*)   printf 'uid:r::::::::%s:::::::::0:\n' "${d#r:}" ;;
			e:*)   printf 'uid:e::::::::%s:::::::::0:\n' "${d#e:}" ;;
		esac
	done
	IFS=';'
done
IFS=$saved_ifs
[ -z "$want" ] || [ "$matched" -eq 1 ] || exit 2
exit 0
GPG_STUB
chmod +x "$STUBS/gpg"

# gh: emulates `gh auth status` and `gh api user/emails --jq ...`.
# GH_AUTHED=1 => authenticated. GH_VERIFIED_EMAILS = newline list of verified
# addresses (the stub prints exactly those, i.e. it applies the verified filter).
# GH_API_RC=<n> => `gh api` FAILS with exit <n> and prints nothing on stdout,
# reproducing the real failure modes (e.g. HTTP 404 when the token lacks the
# 'user' OAuth scope). This is what makes call-failed distinguishable from a
# successful-but-empty list: both yield empty stdout, only the rc differs.
# GH_ARGV_LOG=<path> => append the full argv of each invocation, so a test can
# assert HOW the endpoint was queried (e.g. that --paginate is passed).
#
# The `api` branch MODELS GitHub's pagination, it does not merely record the
# flag: user/emails defaults to per_page=30 and `gh api` does not auto-paginate,
# so without --paginate in its OWN argv the stub returns only the first 30
# addresses. That makes the pagination fix observable through BEHAVIOUR — a
# refactor that keeps the flag but breaks the query goes red.
cat > "$GHDIR/gh" <<'GH_STUB'
#!/usr/bin/env sh
set -eu
[ -z "${GH_ARGV_LOG:-}" ] || printf '%s\n' "$*" >> "$GH_ARGV_LOG"
case "${1:-}" in
	auth) [ "${GH_AUTHED:-0}" = "1" ] && exit 0 || exit 1 ;;
	api)
		if [ "${GH_API_RC:-0}" != "0" ]; then
			printf 'gh: HTTP 404 (missing scope)\n' >&2
			exit "${GH_API_RC}"
		fi
		case " $* " in
			*" --paginate "*) printf '%s\n' "${GH_VERIFIED_EMAILS:-}" ;;
			*)                printf '%s\n' "${GH_VERIFIED_EMAILS:-}" | head -n 30 ;;
		esac
		exit 0
		;;
esac
exit 0
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

# git_iso <repo> <args...>: run git for <repo> in the isolated environment.
git_iso() {
	gi_repo=$1; shift
	env -i HOME="$gi_repo/home" PATH="$TOOLBOX" GIT_CONFIG_NOSYSTEM=1 \
		git -C "$gi_repo" "$@"
}

# new_repo: create an isolated, initialised repo dir; echoes its path.
new_repo() {
	nr=$(mktemp -d "$WORK/repo.XXXXXX")
	mkdir -p "$nr/home"
	git_iso "$nr" init -q
	printf '%s\n' "$nr"
}

# run_in <repo> <with_gh:0|1> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> with cwd=<repo> under the isolated toolbox PATH (+ gpg stub, and
#   the gh stub only when with_gh=1). Any leading VAR=VALUE arguments are passed
#   straight to `env` as assignments (so values may contain spaces). Captures
#   stdout, stderr, and exit code.
run_in() {
	ri_repo=$1; ri_gh=$2; shift 2
	ri_path="$STUBS:$TOOLBOX"
	[ "$ri_gh" = "1" ] && ri_path="$GHDIR:$ri_path"
	ri_out="$WORK/out"; ri_err="$WORK/err"
	set +e
	(
		cd "$ri_repo" || exit 127
		# "$@" is: zero or more VAR=VALUE assignments followed by the command.
		# env consumes leading assignments and execs the rest.
		exec env -i \
			HOME="$ri_repo/home" \
			PATH="$ri_path" \
			GIT_CONFIG_NOSYSTEM=1 \
			TMPDIR="$WORK" \
			"$@"
	) >"$ri_out" 2>"$ri_err"
	CUR_RC=$?
	set -e
	CUR_OUT=$(cat "$ri_out"); CUR_ERR=$(cat "$ri_err")
	rm -f "$ri_out" "$ri_err"
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

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# cfg_gpg_identity <repo> <name> <email> <signingkey>
cfg_gpg_identity() {
	git_iso "$1" config user.name "$2"
	git_iso "$1" config user.email "$3"
	git_iso "$1" config user.signingkey "$4"
	git_iso "$1" config gpg.format openpgp
}

GPG_ALICE="GPG_KEYS=KEYALICE|FPRALICE0001|Alice Dev <alice@example.com>"
GPG_BOB="GPG_KEYS=KEYBOB|FPRBOB0002|Bob Dev <bob@example.com>"

# ===========================================================================
# resolve-identity.sh
# ===========================================================================
section "resolve-identity.sh"

# (a) all fields reconcile -> exit 0
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "$GPG_ALICE" sh "$RESOLVE"
expect_rc "resolve: reconciles -> exit 0" 0
stdout_has "resolve: status reconciled" "IDENTITY_STATUS=reconciled"
stdout_has "resolve: signoff line" "IDENTITY_SIGNOFF=Alice Dev <alice@example.com>"
stdout_has "resolve: key email matched" "IDENTITY_SIGNING_KEY_EMAIL=alice@example.com"

# (b) signing-key email != user.email -> exit 1
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "GPG_KEYS=KEYALICE|FPRALICE0001|Alice Dev <other@example.com>" sh "$RESOLVE"
expect_rc "resolve: key-email mismatch -> exit 1" 1
stdout_has "resolve: status mismatch" "IDENTITY_STATUS=mismatch"
stderr_has "resolve: mismatch diagnostic" "does not match user.email"

# (c) missing user.signingkey -> exit 1
repo=$(new_repo)
git_iso "$repo" config user.name "Alice Dev"
git_iso "$repo" config user.email "alice@example.com"
run_in "$repo" 0 "$GPG_ALICE" sh "$RESOLVE"
expect_rc "resolve: missing signingkey -> exit 1" 1
stderr_has "resolve: missing signingkey diagnostic" "user.signingkey is not set"

# (d) author != committer -> warning, git-local still reconciles (exit 0)
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "$GPG_ALICE" GIT_AUTHOR_EMAIL=bob@example.com sh "$RESOLVE"
expect_rc "resolve: author!=committer still exit 0" 0
stderr_has "resolve: author!=committer warning" "!= committer"
stdout_has "resolve: author-committer match false" "IDENTITY_AUTHOR_COMMITTER_MATCH=false"

# (e) --github with gh ABSENT -> skipped, not a failure (exit 0)
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "$GPG_ALICE" sh "$RESOLVE" --github
expect_rc "resolve: --github gh-absent -> exit 0" 0
stdout_has "resolve: github skipped" "IDENTITY_GITHUB=skipped"
stderr_has "resolve: github skip notice" "gh is not installed"

# (e2) --github, gh present + authed + verified email -> exit 0
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
GH_ARGV="$WORK/gh-argv"; rm -f "$GH_ARGV"
run_in "$repo" 1 "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS=alice@example.com \
	GH_ARGV_LOG="$GH_ARGV" sh "$RESOLVE" --github
expect_rc "resolve: --github verified -> exit 0" 0
stdout_has "resolve: github verified" "IDENTITY_GITHUB=verified"

# The flag is asserted on the user/emails invocation SPECIFICALLY: the argv log
# is append-mode and also holds the `auth status` call, so an unanchored grep
# would pass on a --paginate that landed anywhere.
check "resolve: the user/emails invocation carries --paginate" \
	"'gh api user/emails' was issued without --paginate" \
	"$( grep -q '^api user/emails .*--paginate' "$GH_ARGV" && echo 0 || echo 1 )"

# (e2b) The BEHAVIOURAL half of the pagination guard: 31 verified addresses with
# the committer's LAST. The stub truncates to 30 unless --paginate reaches it,
# so a query that stopped paginating returns a successful-but-truncated list and
# this case goes red as a false 'unverified'. The argv check above complements
# it; neither alone catches both failure shapes.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
many_emails=$(i=1
	while [ "$i" -le 30 ]; do printf 'filler%s@example.com\n' "$i"; i=$((i + 1)); done
	printf 'alice@example.com\n')
rm -f "$GH_ARGV"
run_in "$repo" 1 "$GPG_ALICE" GH_AUTHED=1 "GH_VERIFIED_EMAILS=$many_emails" \
	GH_ARGV_LOG="$GH_ARGV" sh "$RESOLVE" --github
expect_rc "resolve: --github verified on page 2 -> exit 0" 0
stdout_has "resolve: 31st address still resolves as verified" "IDENTITY_GITHUB=verified"

# (e2c) The email compare is `grep -Fxq`, i.e. CASE-SENSITIVE: an address that
# differs only in case does NOT reconcile. Pinned deliberately — the local part
# of an address is case-sensitive per RFC 5321, and GitHub returns addresses in
# their registered form, so a case-insensitive compare would be a behaviour
# CHANGE, not a bug fix. This test exists to make that change visible and
# deliberate if it is ever wanted; it does not endorse either direction.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 1 "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS=Alice@Example.com sh "$RESOLVE" --github
expect_rc "resolve: --github case-differing address does NOT verify -> exit 1" 1
stdout_has "resolve: case-differing address is unverified" "IDENTITY_GITHUB=unverified"

# (e2d) gh PRESENT but UNAUTHENTICATED -> skipped, exit 0. A different branch
# (and a different message) from gh-absent, which (e) covers.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 1 "$GPG_ALICE" sh "$RESOLVE" --github
expect_rc "resolve: --github gh-unauthenticated -> exit 0" 0
stdout_has "resolve: github skipped (unauthenticated)" "IDENTITY_GITHUB=skipped"
stderr_has "resolve: unauthenticated skip notice" "gh is not authenticated"

# (e3) --github, the query SUCCEEDS and omits the email -> unverified, exit 1.
# This is a real negative and MUST stay fatal.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 1 "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS=someone@else.com sh "$RESOLVE" --github
expect_rc "resolve: --github unverified -> exit 1" 1
stdout_has "resolve: github unverified" "IDENTITY_GITHUB=unverified"
stdout_has "resolve: github unverified -> status mismatch" "IDENTITY_STATUS=mismatch"
stderr_has "resolve: github unverified diagnostic" "is not a verified email"

# (e4) --github, the query SUCCEEDS but returns an EMPTY list -> still
# unverified + exit 1. Empty-but-successful is a genuine negative, NOT unknown:
# this is the case that forbids branching on output emptiness.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 1 "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS= sh "$RESOLVE" --github
expect_rc "resolve: --github empty-but-successful -> exit 1" 1
stdout_has "resolve: github empty list is unverified" "IDENTITY_GITHUB=unverified"

# (e5) --github, gh authed but the API CALL FAILS (e.g. token lacks the 'user'
# scope -> HTTP 404) -> unknown, NOT fatal. A question that could not be asked
# must never be answered "no": exit 0, status still reconciled, warn not error.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
# GH_VERIFIED_EMAILS is set to the MATCHING address on purpose: the stub returns
# before reading it when GH_API_RC != 0, so this pins that a failed query wins
# over a would-be match rather than falling through to 'verified'.
run_in "$repo" 1 "$GPG_ALICE" GH_AUTHED=1 GH_API_RC=1 GH_VERIFIED_EMAILS=alice@example.com sh "$RESOLVE" --github
expect_rc "resolve: --github api-failure -> exit 0" 0
stdout_has "resolve: github unknown" "IDENTITY_GITHUB=unknown"
stdout_has "resolve: human block annotates unknown" "GitHub email:    unknown (check could not run"
stdout_has "resolve: api failure does not block the commit" "IDENTITY_STATUS=reconciled"
stderr_has "resolve: unknown is a warning, not an error" "warning:"
stderr_has "resolve: unknown names the likely cause" "'user' OAuth scope"
stderr_has "resolve: unknown gives the remedy" "gh auth refresh -h github.com -s user"
# gh's OWN stderr is now captured and relayed as a second warn line, so the
# stub's failure message is observable — the deterministic sentence above is
# line 1, the real cause is line 2.
stderr_has "resolve: relays gh's own failure message" "gh reported: gh: HTTP 404 (missing scope)"
check "resolve: api failure never claims 'not a verified email'" "reported a definite negative from a failed query" \
	"$( printf '%s\n' "$CUR_ERR" | grep -q 'is not a verified email' && echo 1 || echo 0 )"

# (e6) A committer email containing a NEWLINE is rejected before it can reach a
# matcher. `grep -F` reads an embedded newline as a list of alternative fixed
# patterns, so such a value could satisfy a reconciliation grep against a line
# it does not equal. No valid address contains whitespace.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "$GPG_ALICE" sh "$RESOLVE" --email "bogus@example.com
alice@example.com"
expect_rc "resolve: newline in user.email -> exit 1" 1
stderr_has "resolve: newline-email diagnostic" "user.email contains whitespace"
check "resolve: newline email never reconciles" "a crafted multi-line email reconciled" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q 'IDENTITY_STATUS=reconciled' && echo 1 || echo 0 )"

# (f) bad usage -> exit 2
repo=$(new_repo)
run_in "$repo" 0 sh "$RESOLVE" --bogus
expect_rc "resolve: bad flag -> exit 2" 2
run_in "$repo" 0 sh "$RESOLVE" -- extra
expect_rc "resolve: trailing arg after -- -> exit 2" 2

# override: --email/--name/--signingkey reconciles a SPECIFIED identity
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "$GPG_BOB" sh "$RESOLVE" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB
expect_rc "resolve: override identity reconciles -> exit 0" 0
stdout_has "resolve: override committer email" "IDENTITY_COMMITTER_EMAIL=bob@example.com"
stdout_has "resolve: override signoff" "IDENTITY_SIGNOFF=Bob Dev <bob@example.com>"

# GPG primary-vs-subkey fingerprint guard: reported fpr must be the PRIMARY's.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "GPG_KEYS=KEYALICE|FPRPRIMARY01|Alice Dev <alice@example.com>|sub:FPRSUBKEY99" sh "$RESOLVE"
expect_rc "resolve: subkey present still reconciles -> exit 0" 0
stdout_has "resolve: reports PRIMARY fingerprint" "IDENTITY_SIGNING_KEY_FPR=FPRPRIMARY01"
check "resolve: does NOT report subkey fingerprint" "subkey fpr leaked into output" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q 'FPRSUBKEY99' && echo 1 || echo 0 )"

# Revoked UID email must NOT reconcile (guard against a dead UID).
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" 0 "GPG_KEYS=KEYALICE|FPRALICE0001|Alice New <new@example.com>|r:Alice Old <alice@example.com>" sh "$RESOLVE"
expect_rc "resolve: revoked-UID email does not reconcile -> exit 1" 1
stdout_has "resolve: revoked-UID status mismatch" "IDENTITY_STATUS=mismatch"

# Ambiguous fuzzy match (short id resolves to two keys) -> exit 1, no blending.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Amb User" "amb@example.com" "AMBI"
run_in "$repo" 0 "GPG_KEYS=AMBI1|FPRAMBI0001|Amb One <amb@example.com>;AMBI2|FPRAMBI0002|Amb Two <amb2@example.com>" sh "$RESOLVE"
expect_rc "resolve: ambiguous key match -> exit 1" 1
stderr_has "resolve: ambiguity diagnostic" "matches 2 secret keys"

# SSH signing path (only if ssh-keygen is available in the toolbox)
if [ -e "$TOOLBOX/ssh-keygen" ]; then
	repo=$(new_repo)
	env -i HOME="$repo/home" PATH="$TOOLBOX" \
		ssh-keygen -t ed25519 -N '' -C 'ssh-user@example.com' -q -f "$repo/id"
	pub_line=$(cat "$repo/id.pub")   # includes a trailing comment field
	git_iso "$repo" config user.name "SSH User"
	git_iso "$repo" config user.email "ssh-user@example.com"
	git_iso "$repo" config gpg.format ssh
	git_iso "$repo" config user.signingkey "$repo/id.pub"
	# allowed_signers line carries a TRAILING COMMENT (the full pub line) -> the
	# key must be found by keytype pattern, not by $NF (which is the comment).
	printf 'ssh-user@example.com %s\n' "$pub_line" > "$repo/allowed"
	git_iso "$repo" config gpg.ssh.allowedSignersFile "$repo/allowed"
	run_in "$repo" 0 sh "$RESOLVE"
	expect_rc "resolve(ssh): principal matches (trailing comment) -> exit 0" 0
	stdout_has "resolve(ssh): method ssh" "IDENTITY_SIGNING_METHOD=ssh"
	stdout_has "resolve(ssh): key email matched" "IDENTITY_SIGNING_KEY_EMAIL=ssh-user@example.com"
	stdout_has "resolve(ssh): key id is keytype" "IDENTITY_SIGNING_KEY_ID=ssh-ed25519"

	# Comma-separated multi-principal entry: user.email is one of several.
	sk_blob=$(cut -d' ' -f1,2 "$repo/id.pub")
	printf 'first@example.com,ssh-user@example.com,last@example.com %s trailing-comment\n' "$sk_blob" > "$repo/allowed"
	run_in "$repo" 0 sh "$RESOLVE"
	expect_rc "resolve(ssh): multi-principal list matches -> exit 0" 0
	stdout_has "resolve(ssh): multi-principal reconciled" "IDENTITY_STATUS=reconciled"

	# principal != user.email -> exit 1
	printf 'other@example.com %s\n' "$sk_blob" > "$repo/allowed"
	run_in "$repo" 0 sh "$RESOLVE"
	expect_rc "resolve(ssh): principal mismatch -> exit 1" 1
	stdout_has "resolve(ssh): status mismatch" "IDENTITY_STATUS=mismatch"
else
	printf '  skip resolve(ssh): ssh-keygen not available\n'
fi

# ===========================================================================
# list-identities.sh
# ===========================================================================
section "list-identities.sh"

repo=$(new_repo)
ALLOWED_FILE="$repo/allowed_signers"
{
	printf 'zoe@example.com ssh-ed25519 AAAAZZZZ zoe-key\n'
	printf 'amy@example.com ssh-ed25519 AAAAAMY1 amy-key\n'
} > "$ALLOWED_FILE"
git_iso "$repo" config gpg.ssh.allowedSignersFile "$ALLOWED_FILE"
BOTH_KEYS="GPG_KEYS=KEYALICE|FPRALICE0001|Alice Dev <alice@example.com>;KEYBOB|FPRBOB0002|Bob Dev <bob@example.com>"
run_in "$repo" 0 "$BOTH_KEYS" sh "$LIST"
expect_rc "list: found identities -> exit 0" 0
stdout_has "list: gpg alice present" "alice@example.com"
stdout_has "list: gpg bob present" "bob@example.com"
stdout_has "list: ssh amy present" "amy@example.com"
stdout_has "list: ssh zoe present" "zoe@example.com"
stdout_has "list: identity count is 4" "IDENTITY_COUNT=4"
check "list: gpg ordered before ssh (IDENTITY_1 is gpg)" "IDENTITY_1 was not gpg" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q '^IDENTITY_1_METHOD=gpg' && echo 0 || echo 1 )"
run1=$CUR_OUT
run_in "$repo" 0 "$BOTH_KEYS" sh "$LIST"
check "list: deterministic across identical runs" "output differed between runs" \
	"$( [ "$run1" = "$CUR_OUT" ] && echo 0 || echo 1 )"
# The allowed_signers fixture lines carry a trailing comment (zoe-key/amy-key).
# After the keytype-pattern fix, the SSH KEY_ID must be the keytype, not the
# base64 blob, and the comment must never be mistaken for the key.
stdout_has "list: ssh KEY_ID is keytype" "IDENTITY_3_METHOD=ssh"
stdout_has "list: ssh KEY_ID value is ssh-ed25519" "IDENTITY_3_KEY_ID=ssh-ed25519"
check "list: base64 blob NOT used as key id/type" "blob leaked into KEY_ID" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q 'KEY_ID=AAAA' && echo 1 || echo 0 )"
check "list: comment NOT used as key/fpr" "comment leaked into a field" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Eq '(KEY_ID|FPR)=(zoe-key|amy-key)' && echo 1 || echo 0 )"

# Comma-separated multi-principal entry -> one record per principal.
repo=$(new_repo)
MP_FILE="$repo/allowed_signers"
printf 'p1@example.com,p2@example.com ssh-ed25519 AAAAMULTI multi-comment\n' > "$MP_FILE"
git_iso "$repo" config gpg.ssh.allowedSignersFile "$MP_FILE"
run_in "$repo" 0 "GPG_KEYS=" sh "$LIST"
expect_rc "list(multi-principal): -> exit 0" 0
stdout_has "list(multi-principal): first principal listed" "p1@example.com"
stdout_has "list(multi-principal): second principal listed" "p2@example.com"
stdout_has "list(multi-principal): count is 2" "IDENTITY_COUNT=2"

# Revoked UID must not be offered by list either.
repo=$(new_repo)
run_in "$repo" 0 "GPG_KEYS=KEYALICE|FPRALICE0001|Alice New <new@example.com>|r:Alice Old <revoked@example.com>" sh "$LIST"
expect_rc "list(revoked-uid): -> exit 0" 0
check "list(revoked-uid): revoked email not listed" "revoked UID email was offered" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q 'revoked@example.com' && echo 1 || echo 0 )"
stdout_has "list(revoked-uid): live UID listed" "new@example.com"

# gpg.format=ssh + user.signingkey=<path> branch (only with ssh-keygen).
if [ -e "$TOOLBOX/ssh-keygen" ]; then
	repo=$(new_repo)
	env -i HOME="$repo/home" PATH="$TOOLBOX" \
		ssh-keygen -t ed25519 -N '' -C 'cfgkey@example.com' -q -f "$repo/id"
	git_iso "$repo" config gpg.format ssh
	git_iso "$repo" config user.signingkey "$repo/id.pub"
	run_in "$repo" 0 "GPG_KEYS=" sh "$LIST"
	expect_rc "list(cfg ssh key path): -> exit 0" 0
	stdout_has "list(cfg ssh key path): comment email listed" "cfgkey@example.com"
	stdout_has "list(cfg ssh key path): keytype as KEY_ID" "IDENTITY_1_KEY_ID=ssh-ed25519"
	check "list(cfg ssh key path): real SHA256 fingerprint" "fingerprint is not a SHA256" \
		"$( printf '%s\n' "$CUR_OUT" | grep -q 'IDENTITY_1_FPR=SHA256:' && echo 0 || echo 1 )"
else
	printf '  skip list(cfg ssh key path): ssh-keygen not available\n'
fi

# No identities at all -> exit 1
repo=$(new_repo)
run_in "$repo" 0 "GPG_KEYS=" sh "$LIST"
expect_rc "list: none found -> exit 1" 1

# ===========================================================================
# switch-identity.sh
# ===========================================================================
section "switch-identity.sh"

# Sets repo-local config; validates key exists first
repo=$(new_repo)
run_in "$repo" 0 "$GPG_BOB" sh "$SWITCH" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB --format gpg
expect_rc "switch: valid key applied -> exit 0" 0
stdout_has "switch: status applied" "SWITCH_STATUS=applied"
got_email=$(git_iso "$repo" config user.email 2>/dev/null || true)
check "switch: user.email persisted" "expected bob@example.com, got $got_email" \
	"$( [ "$got_email" = "bob@example.com" ] && echo 0 || echo 1 )"
got_key=$(git_iso "$repo" config user.signingkey 2>/dev/null || true)
check "switch: signingkey persisted" "expected KEYBOB, got $got_key" \
	"$( [ "$got_key" = "KEYBOB" ] && echo 0 || echo 1 )"

# Idempotent: same args -> same resulting config
before=$(git_iso "$repo" config --local --list 2>/dev/null | LC_ALL=C sort)
run_in "$repo" 0 "$GPG_BOB" sh "$SWITCH" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB --format gpg
after=$(git_iso "$repo" config --local --list 2>/dev/null | LC_ALL=C sort)
check "switch: idempotent (config unchanged on re-run)" "config changed on identical re-run" \
	"$( [ "$before" = "$after" ] && echo 0 || echo 1 )"

# Rejects a non-existent key -> exit 1, nothing written
repo=$(new_repo)
run_in "$repo" 0 "$GPG_ALICE" sh "$SWITCH" --email nobody@example.com --name "No Body" --signingkey KEYMISSING --format gpg
expect_rc "switch: missing key -> exit 1" 1
stderr_has "switch: missing key diagnostic" "no GPG secret key found"
wrote=$(git_iso "$repo" config user.email 2>/dev/null || true)
check "switch: nothing written on invalid key" "config was written despite invalid key" \
	"$( [ -z "$wrote" ] && echo 0 || echo 1 )"

# --scope global: value lands in $HOME/.gitconfig, NOT in repo-local config.
repo=$(new_repo)
run_in "$repo" 0 "$GPG_BOB" sh "$SWITCH" --email global@example.com --name "Global User" --signingkey KEYBOB --format gpg --scope global
expect_rc "switch(global): applied -> exit 0" 0
stdout_has "switch(global): scope reported" "SWITCH_SCOPE=global"
global_email=$(git_iso "$repo" config --global user.email 2>/dev/null || true)
check "switch(global): written to global config" "expected global@example.com, got $global_email" \
	"$( [ "$global_email" = "global@example.com" ] && echo 0 || echo 1 )"
check "switch(global): global .gitconfig file exists" "no $HOME/.gitconfig created" \
	"$( [ -f "$repo/home/.gitconfig" ] && echo 0 || echo 1 )"
local_email=$(git_iso "$repo" config --local user.email 2>/dev/null || true)
check "switch(global): NOT written to repo-local config" "leaked into repo-local config" \
	"$( [ -z "$local_email" ] && echo 0 || echo 1 )"

# SSH structural validation: an empty/garbage key file must be rejected.
repo=$(new_repo)
: > "$repo/empty.pub"
run_in "$repo" 0 sh "$SWITCH" --email x@example.com --name "X" --signingkey "$repo/empty.pub" --format ssh
expect_rc "switch(ssh): empty key file rejected -> exit 1" 1
stderr_has "switch(ssh): empty-file diagnostic" "no valid key line"
printf 'this is not a key\n' > "$repo/garbage.pub"
run_in "$repo" 0 sh "$SWITCH" --email x@example.com --name "X" --signingkey "$repo/garbage.pub" --format ssh
expect_rc "switch(ssh): garbage key file rejected -> exit 1" 1

# Trailing positional args after '--' are a usage error.
repo=$(new_repo)
run_in "$repo" 0 sh "$SWITCH" --email x@example.com --name "X" --signingkey KEYBOB --format gpg -- extra
expect_rc "switch: trailing arg after -- -> exit 2" 2

# Bad usage: missing required args -> exit 2
repo=$(new_repo)
run_in "$repo" 0 sh "$SWITCH" --email x@example.com
expect_rc "switch: missing --name/--signingkey -> exit 2" 2

# switch -> resolve round-trip
repo=$(new_repo)
run_in "$repo" 0 "$GPG_BOB" sh "$SWITCH" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB --format gpg
run_in "$repo" 0 "$GPG_BOB" sh "$RESOLVE"
expect_rc "round-trip: resolve after switch -> exit 0" 0
stdout_has "round-trip: reconciled" "IDENTITY_STATUS=reconciled"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
printf 'ALL TESTS PASSED\n'
exit 0
