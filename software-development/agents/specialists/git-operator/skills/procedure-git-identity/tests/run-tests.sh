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
#     need (git, awk, sed, ...) plus STUBS for gpg / gh / glab so tests never
#     touch real keys, keyrings, or the network. Each optional tool lives in its
#     OWN dir that a test opts into per run, so "--github with gh absent" and
#     "--gitlab with jq absent" are exercised for real rather than asserted from
#     a double that merely claims to be missing.
#   * jq is linked REAL, never stubbed. The --gitlab probes' JSON filters — the
#     array / user-object SHAPE GUARDS and the confirmed_at selection — ARE the
#     logic under test, so a fake jq would fake the very thing being verified.
#     Only the network boundary (glab) is stubbed; the parsing is real. jq lives
#     in an opt-in dir purely so the "jq is not installed" branch has a
#     genuinely jq-less PATH to run against.
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
STUBS="$WORK/stubs"      # gpg stub  (always on PATH)
GHDIR="$WORK/ghbin"      # gh stub   (only when a test opts in)
GLABDIR="$WORK/glabbin"  # glab stub (only when a test opts in)
JQDIR="$WORK/jqbin"      # REAL jq   (only when a test opts in)
mkdir -p "$TOOLBOX" "$STUBS" "$GHDIR" "$GLABDIR" "$JQDIR"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolbox: symlink only the real tools we need. gh, glab and jq are
# NEVER here — each is opt-in per run (see run_in) so its ABSENCE is testable.
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

# link_optional_tool <name> <dir>: link <name> into <dir> if the host has it.
# A host that lacks the tool is not an error here: that tool's ABSENCE is itself
# testable (see run_in), and where a whole section depends on it the section-skip
# arms below COUNT the lost coverage into the summary. Spelled as an `if` purely
# for legibility — `[ -n … ] && ln -s …` would behave identically under `set -e`,
# since a non-final command in an AND-OR list is exempt from errexit (that
# spelling is used in `fail` below).
link_optional_tool() {
	lot_path=$(PATH="$ORIG_PATH" command -v "$1" 2>/dev/null || true)
	if [ -n "$lot_path" ]; then ln -s "$lot_path" "$2/$1"; fi
}
link_optional_tool ssh-keygen "$TOOLBOX"
link_optional_tool jq "$JQDIR"

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

# glab: emulates the four invocations resolve-identity.sh makes —
#   glab auth status [--all]
#   glab config get skip_tls_verify [--host HOST]
#   glab api user/emails [--paginate]
#   glab api user
#
# EVERY invocation is appended to $GLAB_ARGV_LOG as 'argv=<args> host=<HOST>',
# where HOST is the $GITLAB_HOST the stub actually INHERITED. That log is what
# makes two otherwise-unobservable properties assertable: that --gitlab-host
# really reaches glab as GITLAB_HOST, and — the safety-critical direction — that
# a CAPPED branch makes NO api call at all, rather than making one and then
# discarding the answer.
#
# Control variables (all optional):
#   GLAB_AUTHED=1               `glab auth status` succeeds.
#   GLAB_AUTHED_ALL_ONLY=1      only `glab auth status --all` succeeds (the bare
#                               form fails), exercising the two-step fallback.
#   GLAB_SKIP_TLS=<v>           value printed by `glab config get skip_tls_verify`.
#   GLAB_SKIP_TLS_FOR_HOST=<v>  value printed by the --host-scoped read.
#   GLAB_CONFIG_RC=<n>          `glab config get` FAILS with exit <n>, printing on
#                               stderr like the real CLI. Both TLS reads in
#                               gitlab_tls_verification_disabled are deliberately
#                               tolerant (`|| true`), which collapses "the read
#                               FAILED" into "the key is UNSET" — a documented
#                               residual risk. Without this hook that collapse is
#                               unreachable from a test and its behaviour (proceed
#                               and query, rather than cap) is unpinned.
#   GLAB_EMAILS_CONFIRMED       newline list of CONFIRMED additional addresses.
#   GLAB_EMAILS_UNCONFIRMED     newline list of UNCONFIRMED additional addresses
#                               (rendered with "confirmed_at": null).
#   GLAB_PRIMARY_EMAIL          the account's primary address (GET /user .email).
#   GLAB_PRIMARY_CONFIRMED=0    that primary carries a null .confirmed_at.
#   GLAB_EMAILS_RC=<n> / GLAB_USER_RC=<n>
#                               that endpoint FAILS with exit <n>, printing on
#                               stderr like the real CLI. This is what makes
#                               call-failed distinguishable from a successful
#                               empty answer — the whole unknown/unverified split.
#   GLAB_EMAILS_BODY / GLAB_USER_BODY
#                               print this RAW body instead of a rendered one —
#                               the escape hatch for the blank, whitespace-only,
#                               wrong-shape and non-JSON cases. SET BUT EMPTY
#                               means an empty body, which is why the stub tests
#                               these with ${VAR+set} and not with -n.
#
# The `api` branch also MODELS glab's optional BANNER output rather than trusting
# it away: unless ALL THREE of GLAB_NO_PROMPT / GLAB_CHECK_UPDATE /
# GLAB_SHOW_WHATS_NEW arrive pinned in the environment it INHERITED, it prints an
# update notice ahead of the JSON body, exactly as an un-pinned real glab does.
# That is a BEHAVIOURAL check, not a flag-presence one, and it is emitted on the
# `api` branch specifically because that is the branch whose stdout the script
# CAPTURES AND PARSES — which is precisely why resolve-identity.sh calls those
# three pins CORRECTNESS rather than tidiness. Delete one of its top-level
# `export`s and the banner reaches jq, the parse fails, and a genuine 'verified'
# silently degrades to 'unknown'; every --gitlab case that expects a definite
# answer then goes red instead of passing quietly.
#
# Like the gh stub, the user/emails branch MODELS pagination instead of merely
# recording the flag: /user/emails is per_page=20 and `glab api` does not
# paginate on its own, so without --paginate in its OWN argv the stub returns
# page 1 only. It also reproduces glab's real --paginate output shape — ONE JSON
# ARRAY PER PAGE, CONCATENATED, not merged into one array — because surviving
# that stream is exactly what the script's jq filter has to do.
cat > "$GLABDIR/glab" <<'GLAB_STUB'
#!/usr/bin/env sh
set -eu
[ -z "${GLAB_ARGV_LOG:-}" ] || printf 'argv=%s host=%s\n' "$*" "${GITLAB_HOST:-}" >> "$GLAB_ARGV_LOG"

# output_pins_missing: true when this invocation did NOT inherit an environment
# that silences glab's optional banners. Each value is judged by what it MEANS to
# glab, not by mere presence, so the assertion this backs fails for the real
# reason: a pin spelled some other way that still suppresses the banner is
# correctly accepted.
output_pins_missing() {
	case "${GLAB_NO_PROMPT:-}" in
		true|TRUE|True|1|yes|YES|y|on) ;;
		*) return 0 ;;
	esac
	case "${GLAB_CHECK_UPDATE:-}" in
		false|FALSE|False|0|no|NO|n|off) ;;
		*) return 0 ;;
	esac
	case "${GLAB_SHOW_WHATS_NEW:-}" in
		false|FALSE|False|0|no|NO|n|off) ;;
		*) return 0 ;;
	esac
	return 1
}

# emit_banner_if_unpinned: the chatter a real, un-pinned glab writes to STDOUT
# ahead of the body it was asked for.
emit_banner_if_unpinned() {
	if output_pins_missing; then
		printf 'A new version of glab is available: 1.112.0 -> 1.113.0\n'
		printf "https://gitlab.com/gitlab-org/cli/-/releases/v1.113.0\n"
	fi
}

# emit_emails <paginate:0|1>: render /user/emails as JSON page arrays.
emit_emails() {
	{
		printf '%s\n' "${GLAB_EMAILS_CONFIRMED:-}"   | sed -n 's/^\(..*\)$/c \1/p'
		printf '%s\n' "${GLAB_EMAILS_UNCONFIRMED:-}" | sed -n 's/^\(..*\)$/u \1/p'
	} | awk -v paginate="$1" '
		NF == 2 { flag[++n] = $1; addr[n] = $2 }
		END {
			per = 20
			pages = int((n + per - 1) / per)
			if (pages < 1 || paginate != 1) pages = 1
			for (p = 1; p <= pages; p++) {
				line = "["
				sep = ""
				for (i = (p - 1) * per + 1; i <= n && i <= p * per; i++) {
					conf = (flag[i] == "c") ? "\"2020-01-01T00:00:00Z\"" : "null"
					line = line sep "{\"id\":" i ",\"email\":\"" addr[i] "\",\"confirmed_at\":" conf "}"
					sep = ","
				}
				print line "]"
			}
		}'
}

# emit_user: render GET /user as the single JSON OBJECT that endpoint returns
# (not a list) — .email is the primary address, .confirmed_at is top-level.
emit_user() {
	if [ "${GLAB_PRIMARY_CONFIRMED:-1}" = "0" ]; then
		eu_confirmed=null
	else
		eu_confirmed='"2020-01-01T00:00:00Z"'
	fi
	printf '{"id":7,"username":"stub","email":"%s","confirmed_at":%s}\n' \
		"${GLAB_PRIMARY_EMAIL:-}" "$eu_confirmed"
}

case "${1:-}" in
	auth)
		case " $* " in
			*" --all "*)
				if [ "${GLAB_AUTHED:-0}" = "1" ] || [ "${GLAB_AUTHED_ALL_ONLY:-0}" = "1" ]; then
					exit 0
				fi
				exit 1 ;;
			*)
				[ "${GLAB_AUTHED:-0}" = "1" ] || exit 1
				exit 0 ;;
		esac
		;;
	config)
		if [ "${GLAB_CONFIG_RC:-0}" != "0" ]; then
			printf 'glab: failed to read config: no such key\n' >&2
			exit "$GLAB_CONFIG_RC"
		fi
		case " $* " in
			*" --host "*) printf '%s\n' "${GLAB_SKIP_TLS_FOR_HOST:-}" ;;
			*)            printf '%s\n' "${GLAB_SKIP_TLS:-}" ;;
		esac
		exit 0
		;;
	api)
		emit_banner_if_unpinned
		case "${2:-}" in
			user/emails)
				if [ "${GLAB_EMAILS_RC:-0}" != "0" ]; then
					printf 'glab: 401 Unauthorized (insufficient_scope)\n' >&2
					exit "$GLAB_EMAILS_RC"
				fi
				if [ -n "${GLAB_EMAILS_BODY+set}" ]; then
					printf '%s' "$GLAB_EMAILS_BODY"
				else
					case " $* " in
						*" --paginate "*) emit_emails 1 ;;
						*)                emit_emails 0 ;;
					esac
				fi
				exit 0 ;;
			user)
				if [ "${GLAB_USER_RC:-0}" != "0" ]; then
					printf 'glab: 401 Unauthorized (insufficient_scope)\n' >&2
					exit "$GLAB_USER_RC"
				fi
				if [ -n "${GLAB_USER_BODY+set}" ]; then
					printf '%s' "$GLAB_USER_BODY"
				else
					emit_user
				fi
				exit 0 ;;
		esac
		exit 0 ;;
esac
exit 0
GLAB_STUB
chmod +x "$GLABDIR/glab"

# ---------------------------------------------------------------------------
# Runner primitives
# ---------------------------------------------------------------------------
TESTS_RUN=0
TESTS_FAIL=0
TESTS_SKIPPED_SECTIONS=0
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

# run_in <repo> <tools> [VAR=VALUE ...] <cmd> [args...]
#   Runs <cmd> with cwd=<repo> under the isolated toolbox PATH (+ the gpg stub,
#   which is always present). <tools> selects which OPT-IN tool dirs join that
#   PATH: 'none', or a '+'-joined list of 'gh', 'glab', 'jq' (e.g. 'glab+jq',
#   'gh+glab+jq'). Naming a tool is the ONLY way it becomes visible to the script
#   under test, so a test that needs a tool ABSENT simply does not name it — that
#   is what makes the "gh is not installed" / "jq is not installed" branches real
#   rather than simulated. An unknown selector is a hard error, not a silent
#   no-op, so a typo cannot quietly hide a tool and turn a green test vacuous.
#   Any leading VAR=VALUE arguments are passed straight to `env` as assignments
#   (so values may contain spaces). Captures stdout, stderr, and exit code.
run_in() {
	ri_repo=$1; ri_tools=$2; shift 2
	ri_path="$STUBS:$TOOLBOX"
	ri_saved_ifs=$IFS
	IFS='+'
	for ri_tool in $ri_tools; do
		IFS=$ri_saved_ifs
		case "$ri_tool" in
			none) ;;
			gh)   ri_path="$GHDIR:$ri_path" ;;
			glab) ri_path="$GLABDIR:$ri_path" ;;
			jq)   ri_path="$JQDIR:$ri_path" ;;
			*) printf 'FATAL: run_in: unknown tool selector: %s\n' "$ri_tool" >&2; exit 1 ;;
		esac
		IFS='+'
	done
	IFS=$ri_saved_ifs
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

# The needle goes to grep via `-e` in every assertion helper below, for the same
# reason resolve-identity.sh does it: a needle that BEGINS WITH '-' is read as an
# option otherwise, and several diagnostics under test quote a flag name
# ("--gitlab-host requires --gitlab"). Without -e those assertions fail on a
# grep usage error rather than on the behaviour they are asserting.
stdout_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_OUT" | grep -Fq -e "$2"; then pass "$1"
	else fail "$1" "stdout missing: $2"; fi
}

stderr_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s\n' "$CUR_ERR" | grep -Fq -e "$2"; then pass "$1"
	else fail "$1" "stderr missing: $2"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# skip_section <name> <reason>: report a whole section that could not run on this
# host, and COUNT it.
#
# The count exists because a silently skipped section is indistinguishable from a
# clean pass. A machine without jq skips the entire --gitlab state machine — the
# largest and most safety-critical body of coverage here — and would otherwise
# still print 'ALL TESTS PASSED' and exit 0, with only the raw check total (which
# nobody compares against a remembered number) hinting that anything was missing.
# The summary therefore states the skip count explicitly and withholds the
# unqualified pass line. Exit status stays 0: a host legitimately lacking an
# optional tool has not FAILED anything, it has verified less.
skip_section() {
	TESTS_SKIPPED_SECTIONS=$((TESTS_SKIPPED_SECTIONS + 1))
	printf '  SKIP SECTION: %s -- %s\n' "$1" "$2"
}

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
run_in "$repo" none "$GPG_ALICE" sh "$RESOLVE"
expect_rc "resolve: reconciles -> exit 0" 0
stdout_has "resolve: status reconciled" "IDENTITY_STATUS=reconciled"
stdout_has "resolve: signoff line" "IDENTITY_SIGNOFF=Alice Dev <alice@example.com>"
stdout_has "resolve: key email matched" "IDENTITY_SIGNING_KEY_EMAIL=alice@example.com"
# Both platform lines are a CONSUMED contract: they print UNCONDITIONALLY, so a
# parser may read them without first knowing which flags the caller passed, and
# 'skipped' is their value when the check did not run. This run passes NEITHER
# --github nor --gitlab, which is exactly the case where a `printf` accidentally
# made conditional on its own flag would drop the line entirely — a MISSING line,
# which no assertion on a flagged run can catch. Matched as whole lines (-Fx) so a
# present-but-differently-valued line cannot satisfy them.
check "resolve: IDENTITY_GITHUB prints even with no --github, defaulting to skipped" \
	"the IDENTITY_GITHUB=skipped line is absent from a no-flags run" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITHUB=skipped' && echo 0 || echo 1 )"
check "resolve: IDENTITY_GITLAB prints even with no --gitlab, defaulting to skipped" \
	"the IDENTITY_GITLAB=skipped line is absent from a no-flags run" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=skipped' && echo 0 || echo 1 )"

# (b) signing-key email != user.email -> exit 1
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" none "GPG_KEYS=KEYALICE|FPRALICE0001|Alice Dev <other@example.com>" sh "$RESOLVE"
expect_rc "resolve: key-email mismatch -> exit 1" 1
stdout_has "resolve: status mismatch" "IDENTITY_STATUS=mismatch"
stderr_has "resolve: mismatch diagnostic" "does not match user.email"

# (c) missing user.signingkey -> exit 1
repo=$(new_repo)
git_iso "$repo" config user.name "Alice Dev"
git_iso "$repo" config user.email "alice@example.com"
run_in "$repo" none "$GPG_ALICE" sh "$RESOLVE"
expect_rc "resolve: missing signingkey -> exit 1" 1
stderr_has "resolve: missing signingkey diagnostic" "user.signingkey is not set"

# (d) author != committer -> warning, git-local still reconciles (exit 0)
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" none "$GPG_ALICE" GIT_AUTHOR_EMAIL=bob@example.com sh "$RESOLVE"
expect_rc "resolve: author!=committer still exit 0" 0
stderr_has "resolve: author!=committer warning" "!= committer"
stdout_has "resolve: author-committer match false" "IDENTITY_AUTHOR_COMMITTER_MATCH=false"

# (e) --github with gh ABSENT -> skipped, not a failure (exit 0)
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" none "$GPG_ALICE" sh "$RESOLVE" --github
expect_rc "resolve: --github gh-absent -> exit 0" 0
stdout_has "resolve: github skipped" "IDENTITY_GITHUB=skipped"
stderr_has "resolve: github skip notice" "gh is not installed"

# (e2) --github, gh present + authed + verified email -> exit 0
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
GH_ARGV="$WORK/gh-argv"; rm -f "$GH_ARGV"
run_in "$repo" gh "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS=alice@example.com \
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
run_in "$repo" gh "$GPG_ALICE" GH_AUTHED=1 "GH_VERIFIED_EMAILS=$many_emails" \
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
run_in "$repo" gh "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS=Alice@Example.com sh "$RESOLVE" --github
expect_rc "resolve: --github case-differing address does NOT verify -> exit 1" 1
stdout_has "resolve: case-differing address is unverified" "IDENTITY_GITHUB=unverified"

# (e2d) gh PRESENT but UNAUTHENTICATED -> skipped, exit 0. A different branch
# (and a different message) from gh-absent, which (e) covers.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" gh "$GPG_ALICE" sh "$RESOLVE" --github
expect_rc "resolve: --github gh-unauthenticated -> exit 0" 0
stdout_has "resolve: github skipped (unauthenticated)" "IDENTITY_GITHUB=skipped"
stderr_has "resolve: unauthenticated skip notice" "gh is not authenticated"

# (e3) --github, the query SUCCEEDS and omits the email -> unverified, exit 1.
# This is a real negative and MUST stay fatal.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" gh "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS=someone@else.com sh "$RESOLVE" --github
expect_rc "resolve: --github unverified -> exit 1" 1
stdout_has "resolve: github unverified" "IDENTITY_GITHUB=unverified"
stdout_has "resolve: github unverified -> status mismatch" "IDENTITY_STATUS=mismatch"
stderr_has "resolve: github unverified diagnostic" "is not a verified email"

# (e4) --github, the query SUCCEEDS but returns an EMPTY list -> still
# unverified + exit 1. Empty-but-successful is a genuine negative, NOT unknown:
# this is the case that forbids branching on output emptiness.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" gh "$GPG_ALICE" GH_AUTHED=1 GH_VERIFIED_EMAILS= sh "$RESOLVE" --github
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
run_in "$repo" gh "$GPG_ALICE" GH_AUTHED=1 GH_API_RC=1 GH_VERIFIED_EMAILS=alice@example.com sh "$RESOLVE" --github
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
run_in "$repo" none "$GPG_ALICE" sh "$RESOLVE" --email "bogus@example.com
alice@example.com"
expect_rc "resolve: newline in user.email -> exit 1" 1
stderr_has "resolve: newline-email diagnostic" "user.email contains whitespace"
check "resolve: newline email never reconciles" "a crafted multi-line email reconciled" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q 'IDENTITY_STATUS=reconciled' && echo 1 || echo 0 )"

# (e7) An address BEGINNING WITH '-' is rejected before any matcher sees it, and
# the case is built as the ATTACK the guard exists to stop rather than as generic
# odd input. Read as a bare grep OPERAND, "--regexp=" makes the effective pattern
# EMPTY, and `grep -Fx` matches an empty pattern against the blank line an EMPTY
# LIST prints — so an account with NO verified addresses at all answers
# 'verified'.
#
# Everything ELSE about this fixture reconciles on purpose (the signing key
# advertises that same value, and the verified list is empty): with the guard
# gone the run comes back exit 0 / reconciled / GitHub-verified off an empty
# list, so each assertion below actually discriminates instead of passing on the
# unrelated mismatch a less careful fixture would produce.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Odd Config" "placeholder@example.com" "KEYODD"
run_in "$repo" gh "GPG_KEYS=KEYODD|FPRODD0001|Odd Config <--regexp=>" \
	GH_AUTHED=1 GH_VERIFIED_EMAILS= sh "$RESOLVE" --github --email "--regexp="
expect_rc "resolve: option-shaped user.email -> exit 1" 1
stderr_has "resolve: option-shaped email diagnostic" "user.email begins with '-'"
check "resolve: an option-shaped email cannot forge a verified answer" \
	"an empty grep pattern matched an EMPTY verified list and reported 'verified'" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITHUB=verified' && echo 1 || echo 0 )"
check "resolve: an option-shaped email never reconciles" "an option-shaped address reconciled" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_STATUS=reconciled' && echo 1 || echo 0 )"

# The ordinary leading-dash spelling takes the same arm, and its diagnostic
# ECHOES the value — safe only because whitespace and control bytes were already
# rejected above it, which is why that arm is tested last in the function. The
# signing key advertises this address too, so the run would otherwise reconcile:
# without the guard this exits 0, which is what the exit assertion detects.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Odd Config" "placeholder@example.com" "KEYODD"
run_in "$repo" none "GPG_KEYS=KEYODD|FPRODD0001|Odd Config <-alice@example.com>" \
	sh "$RESOLVE" --email "-alice@example.com"
expect_rc "resolve: leading-dash user.email -> exit 1" 1
stderr_has "resolve: leading-dash email diagnostic names the value" \
	"user.email begins with '-' (not a valid address): -alice@example.com"

# (e8) THE forged-line attack the control-character guard exists to stop, tested
# as an ATTACK and not just as a rejection: a user.name carrying a literal
# newline followed by 'IDENTITY_GITLAB=verified' would print as an extra line in
# the machine-parseable block that a consumer cannot tell from a real one — a
# fail-open manufactured out of a config value. The run is deliberately made
# WITHOUT --gitlab, where the only legitimate value of that key is 'skipped', so
# an exact-line match on the forged spelling is unambiguous evidence of forgery.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" none "$GPG_ALICE" sh "$RESOLVE" --name "Alice Dev
IDENTITY_GITLAB=verified"
expect_rc "resolve: control character in user.name -> exit 1" 1
stderr_has "resolve: user.name control-character diagnostic" "user.name contains a control character"
check "resolve: a newline in user.name cannot forge an IDENTITY_* line" "a forged IDENTITY_GITLAB=verified line reached stdout" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=verified' && echo 1 || echo 0 )"
check "resolve: the diagnostic does not echo the control bytes back" "the rejected value was echoed into the diagnostic stream" \
	"$( printf '%s\n' "$CUR_ERR" | grep -Fq 'IDENTITY_GITLAB=verified' && echo 1 || echo 0 )"

# (e9) The same guard on the OTHER value that reaches the output block. Run on the
# SSH signing path deliberately: an INLINE ssh key legitimately contains spaces,
# so only control characters are rejected there — and it is the path where the
# forgery is actually REACHABLE, because everything else about this fixture
# reconciles (the allowed-signers principal IS user.email). With the guard gone
# the run therefore exits 0 having printed a forged 'IDENTITY_GITLAB=verified'
# line that no --gitlab flag ever produced.
repo=$(new_repo)
git_iso "$repo" config user.name "Alice Dev"
git_iso "$repo" config user.email "alice@example.com"
git_iso "$repo" config gpg.format ssh
printf 'alice@example.com ssh-ed25519 AAAAFAKEBLOB alice-key\n' > "$repo/allowed"
git_iso "$repo" config gpg.ssh.allowedSignersFile "$repo/allowed"
run_in "$repo" none sh "$RESOLVE" --signingkey "ssh-ed25519 AAAAFAKEBLOB
IDENTITY_GITLAB=verified"
expect_rc "resolve: control character in user.signingkey -> exit 1" 1
stderr_has "resolve: user.signingkey control-character diagnostic" "user.signingkey contains a control character"
check "resolve: a newline in user.signingkey cannot forge an IDENTITY_* line" "a forged IDENTITY_GITLAB=verified line reached stdout" \
	"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=verified' && echo 1 || echo 0 )"

# (f) bad usage -> exit 2
repo=$(new_repo)
run_in "$repo" none sh "$RESOLVE" --bogus
expect_rc "resolve: bad flag -> exit 2" 2
run_in "$repo" none sh "$RESOLVE" -- extra
expect_rc "resolve: trailing arg after -- -> exit 2" 2

# override: --email/--name/--signingkey reconciles a SPECIFIED identity
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" none "$GPG_BOB" sh "$RESOLVE" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB
expect_rc "resolve: override identity reconciles -> exit 0" 0
stdout_has "resolve: override committer email" "IDENTITY_COMMITTER_EMAIL=bob@example.com"
stdout_has "resolve: override signoff" "IDENTITY_SIGNOFF=Bob Dev <bob@example.com>"

# GPG primary-vs-subkey fingerprint guard: reported fpr must be the PRIMARY's.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" none "GPG_KEYS=KEYALICE|FPRPRIMARY01|Alice Dev <alice@example.com>|sub:FPRSUBKEY99" sh "$RESOLVE"
expect_rc "resolve: subkey present still reconciles -> exit 0" 0
stdout_has "resolve: reports PRIMARY fingerprint" "IDENTITY_SIGNING_KEY_FPR=FPRPRIMARY01"
check "resolve: does NOT report subkey fingerprint" "subkey fpr leaked into output" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q 'FPRSUBKEY99' && echo 1 || echo 0 )"

# Revoked UID email must NOT reconcile (guard against a dead UID).
repo=$(new_repo)
cfg_gpg_identity "$repo" "Alice Dev" "alice@example.com" "KEYALICE"
run_in "$repo" none "GPG_KEYS=KEYALICE|FPRALICE0001|Alice New <new@example.com>|r:Alice Old <alice@example.com>" sh "$RESOLVE"
expect_rc "resolve: revoked-UID email does not reconcile -> exit 1" 1
stdout_has "resolve: revoked-UID status mismatch" "IDENTITY_STATUS=mismatch"

# Ambiguous fuzzy match (short id resolves to two keys) -> exit 1, no blending.
repo=$(new_repo)
cfg_gpg_identity "$repo" "Amb User" "amb@example.com" "AMBI"
run_in "$repo" none "GPG_KEYS=AMBI1|FPRAMBI0001|Amb One <amb@example.com>;AMBI2|FPRAMBI0002|Amb Two <amb2@example.com>" sh "$RESOLVE"
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
	run_in "$repo" none sh "$RESOLVE"
	expect_rc "resolve(ssh): principal matches (trailing comment) -> exit 0" 0
	stdout_has "resolve(ssh): method ssh" "IDENTITY_SIGNING_METHOD=ssh"
	stdout_has "resolve(ssh): key email matched" "IDENTITY_SIGNING_KEY_EMAIL=ssh-user@example.com"
	stdout_has "resolve(ssh): key id is keytype" "IDENTITY_SIGNING_KEY_ID=ssh-ed25519"

	# Comma-separated multi-principal entry: user.email is one of several.
	sk_blob=$(cut -d' ' -f1,2 "$repo/id.pub")
	printf 'first@example.com,ssh-user@example.com,last@example.com %s trailing-comment\n' "$sk_blob" > "$repo/allowed"
	run_in "$repo" none sh "$RESOLVE"
	expect_rc "resolve(ssh): multi-principal list matches -> exit 0" 0
	stdout_has "resolve(ssh): multi-principal reconciled" "IDENTITY_STATUS=reconciled"

	# principal != user.email -> exit 1
	printf 'other@example.com %s\n' "$sk_blob" > "$repo/allowed"
	run_in "$repo" none sh "$RESOLVE"
	expect_rc "resolve(ssh): principal mismatch -> exit 1" 1
	stdout_has "resolve(ssh): status mismatch" "IDENTITY_STATUS=mismatch"
else
	skip_section "resolve(ssh) signing path" "ssh-keygen not available"
fi

# ===========================================================================
# resolve-identity.sh --gitlab  —  helpers shared by both --gitlab sections
# ===========================================================================
GL_HOST=gitlab.example.com
GLAB_ARGV="$WORK/glab-argv"
GLAB_AUTH="GLAB_AUTHED=1"
GLAB_LOG="GLAB_ARGV_LOG=$GLAB_ARGV"

# new_gitlab_repo [name] [email] [signingkey]: an isolated repo carrying a GPG
# identity — Alice's unless overridden — with a freshly TRUNCATED glab invocation
# log. Truncating per case is what makes the "no api call was made" assertions
# trustworthy: a log left over from an earlier case would otherwise decide them
# for the wrong reason.
#
# The identity is PARAMETERISED so that a case needing a different one still comes
# through this helper. The log is a single global path truncated only here, so a
# case that built its own fixture would also have to hand-roll the truncation —
# and one that forgot would silently assert against the previous case's log. Since
# nothing outside this helper truncates, that failure mode is unreachable.
new_gitlab_repo() {
	ngr=$(new_repo)
	cfg_gpg_identity "$ngr" "${1:-Alice Dev}" "${2:-alice@example.com}" "${3:-KEYALICE}"
	: > "$GLAB_ARGV"
	printf '%s\n' "$ngr"
}

# glab_log_has / glab_log_lacks <check-name> <fixed-string>: assert on the glab
# stub's invocation log, one 'argv=<args> host=<GITLAB_HOST>' line per call. Same
# shape as stdout_has / stderr_has above.
glab_log_has() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -Fq -e "$2" "$GLAB_ARGV"; then pass "$1"
	else fail "$1" "glab invocation log missing: $2 (log: $(tr '\n' ';' < "$GLAB_ARGV"))"; fi
}
glab_log_lacks() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -Fq -e "$2" "$GLAB_ARGV"; then fail "$1" "glab invocation log unexpectedly holds: $2"
	else pass "$1"; fi
}

# no_glab_api_call <check-name>: the safety-critical assertion — glab was never
# asked anything OVER THE NETWORK on this run. Wherever glab is EXPECTED to have
# run (the two capped branches, and the unauthenticated skip) the case pairs this
# with a glab_log_has on the non-api call it did make, because otherwise an empty
# log would satisfy this for the wrong reason — glab never invoked at all, or the
# log never wired up. The jq-absent case is the one exception, and deliberately
# so: there glab is CORRECTLY never invoked, and it is IDENTITY_GITLAB=skipped
# that shows the branch was reached.
no_glab_api_call() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -q '^argv=api ' "$GLAB_ARGV"; then
		fail "$1" "a 'glab api' call WAS made: $(grep '^argv=api ' "$GLAB_ARGV" | tr '\n' ';')"
	else pass "$1"; fi
}

# ===========================================================================
# resolve-identity.sh --gitlab — preconditions & --gitlab-host usage
#
# Nothing here parses JSON, so these run whether or not the host has jq.
# ===========================================================================
section "resolve-identity.sh --gitlab (preconditions & usage)"

# (g1) glab ABSENT -> skipped, never fatal. jq IS on PATH, which also pins the
# ORDER: glab's absence is reported, not jq's.
repo=$(new_gitlab_repo)
run_in "$repo" jq "$GPG_ALICE" sh "$RESOLVE" --gitlab
expect_rc "resolve: --gitlab glab-absent -> exit 0" 0
stdout_has "resolve: gitlab skipped (glab absent)" "IDENTITY_GITLAB=skipped"
stderr_has "resolve: gitlab glab-absent notice" "glab is not installed"

# (g2) jq ABSENT while glab is present -> skipped, and the diagnostic must NAME
# jq: `glab api` genuinely has no --jq flag (unlike `gh api`), so jq is a real
# precondition rather than decoration, and a user reading the warning has to know
# which tool to install. No api call may be attempted either.
repo=$(new_gitlab_repo)
run_in "$repo" glab "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
	sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
expect_rc "resolve: --gitlab jq-absent -> exit 0" 0
stdout_has "resolve: gitlab skipped (jq absent)" "IDENTITY_GITLAB=skipped"
stderr_has "resolve: jq-absent notice names jq as the reason" "jq is not installed"
stderr_has "resolve: jq-absent notice says why jq is required" "which has no --jq flag"
no_glab_api_call "resolve: --gitlab queries nothing when jq is absent"

# (g3) --gitlab-host SHAPE validation -> usage error (exit 2), never exit 1: a
# malformed pin must be unmistakable from "identity mismatch, do not commit".
# Each spelling below is a DISTINCT arm of is_valid_confirmed_host — a scheme,
# a leading '-' (glab would read it as a flag), a leading dot, a trailing dot, an
# empty label, whitespace, and a path separator. The loop is uniform: one
# invocation, one assertion, no branching.
repo=$(new_repo)
for bad_host in 'https://gitlab.com' '-gitlab.com' '.gitlab.com' 'gitlab.com.' \
		'gitlab..com' 'git lab.com' 'gitlab.com/api/v4'; do
	run_in "$repo" none sh "$RESOLVE" --gitlab --gitlab-host "$bad_host"
	expect_rc "resolve: --gitlab-host rejects '$bad_host' -> exit 2" 2
done

# A bare host with an optional ':port' is ACCEPTED — the negative loop above
# would also pass if the allow-list rejected everything.
repo=$(new_gitlab_repo)
run_in "$repo" jq "$GPG_ALICE" sh "$RESOLVE" --gitlab --gitlab-host gitlab.example.com:8443
expect_rc "resolve: --gitlab-host accepts a bare host with a port -> exit 0" 0
stdout_has "resolve: accepted host reaches the glab-absent skip" "IDENTITY_GITLAB=skipped"

# (g4) --gitlab-host WITHOUT --gitlab is a usage error by design, not a
# silently-ignored no-op: pinning an instance nothing queries is exactly the
# mistake the flag exists to prevent.
repo=$(new_repo)
run_in "$repo" none sh "$RESOLVE" --gitlab-host "$GL_HOST"
expect_rc "resolve: --gitlab-host without --gitlab -> exit 2" 2
stderr_has "resolve: --gitlab-host-alone diagnostic" "--gitlab-host requires --gitlab"

# (g5) --gitlab-host with no value at all -> exit 2 (the empty host is rejected
# by need_arg before is_valid_confirmed_host ever sees it).
repo=$(new_repo)
run_in "$repo" none sh "$RESOLVE" --gitlab --gitlab-host ""
expect_rc "resolve: --gitlab-host with an empty value -> exit 2" 2
stderr_has "resolve: empty --gitlab-host diagnostic" "requires an argument"

# ===========================================================================
# resolve-identity.sh --gitlab — the four-state machine
#
# jq is a genuine precondition of every case below (`glab api` has no --jq flag),
# and it is deliberately NOT stubbed: the filters' shape guards ARE the logic
# under test. On a host without jq these are SKIPPED rather than faked, exactly
# as the ssh-keygen cases above are.
# ===========================================================================
section "resolve-identity.sh --gitlab (four states)"

if [ -e "$JQDIR/jq" ]; then
	# --- skipped: glab + jq present, but glab is UNAUTHENTICATED --------------
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_LOG" \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab glab-unauthenticated -> exit 0" 0
	stdout_has "resolve: gitlab skipped (unauthenticated)" "IDENTITY_GITLAB=skipped"
	stderr_has "resolve: gitlab unauthenticated notice" "glab is not authenticated"
	no_glab_api_call "resolve: --gitlab queries nothing when glab is unauthenticated"
	glab_log_has "resolve: the auth precondition was actually consulted" "argv=auth status"

	# glab_authenticated's TWO-STEP: the bare `auth status` fails and `--all`
	# succeeds -> the check must proceed, not skip. The real case is a
	# self-managed instance consulted from an unrelated cwd.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" GLAB_AUTHED_ALL_ONLY=1 "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice@example.com \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab authenticated only via 'auth status --all' -> exit 0" 0
	stdout_has "resolve: the --all fallback does not skip the check" "IDENTITY_GITLAB=verified"
	glab_log_has "resolve: the bare auth probe ran first" "argv=auth status host=$GL_HOST"
	glab_log_has "resolve: the --all fallback ran after it" "argv=auth status --all host=$GL_HOST"

	# --- verified via the PRIMARY probe (GET /user) ---------------------------
	# The most common real configuration: user.email IS the account's primary
	# address, which GET /user/emails does NOT list. A single-probe
	# implementation answers 'unverified' here and refuses the commit on
	# essentially every real GitLab repo — this is the headline case, not an edge.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab primary-confirmed -> exit 0" 0
	stdout_has "resolve: verified via the PRIMARY address" "IDENTITY_GITLAB=verified"
	stdout_has "resolve: a verified gitlab answer does not block the commit" "IDENTITY_STATUS=reconciled"
	stdout_has "resolve: the human block reports the gitlab state" "GitLab email:    verified"
	glab_log_has "resolve: the secondary probe queried /user/emails with --paginate" \
		"argv=api user/emails --paginate host=$GL_HOST"
	glab_log_has "resolve: the primary probe queried /user after it" "argv=api user host=$GL_HOST"
	glab_log_has "resolve: --gitlab-host is exported as GITLAB_HOST before the auth check too" \
		"argv=auth status host=$GL_HOST"

	# --- verified via the SECONDARY probe, and the primary probe SHORT-CIRCUITS
	# The primary is stocked with a NON-matching confirmed address rather than
	# made to fail: that way it would answer a clean NEGATIVE if it were ever
	# consulted, so losing the secondary path turns this run into a FATAL
	# 'unverified' and the exit assertion detects it. The log assertion is the
	# direct proof that the second call never happened at all.
	gl_two=$(printf 'extra@example.com\nalice@example.com\n')
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		"GLAB_EMAILS_CONFIRMED=$gl_two" \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab secondary-confirmed -> exit 0" 0
	stdout_has "resolve: verified via an ADDITIONAL confirmed address" "IDENTITY_GITLAB=verified"
	# The positive assertion comes FIRST and is what licenses the negative one
	# below: an EMPTY log satisfies glab_log_lacks vacuously, so proof that this
	# run's log genuinely captured the call that DID happen is what rules out
	# "$GLAB_LOG was dropped from the invocation" as the reason it passed. Every
	# other lacks/no-api-call case in this file is paired the same way.
	glab_log_has "resolve: the secondary probe did run, so the log is live" \
		"argv=api user/emails --paginate host=$GL_HOST"
	glab_log_lacks "resolve: a secondary match short-circuits the primary probe" \
		"argv=api user host="

	# --- unverified: BOTH probes answered cleanly and NEITHER listed it -> FATAL
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED=other@example.com \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab unverified -> exit 1" 1
	stdout_has "resolve: gitlab unverified" "IDENTITY_GITLAB=unverified"
	stdout_has "resolve: gitlab unverified -> status mismatch" "IDENTITY_STATUS=mismatch"
	stderr_has "resolve: gitlab unverified diagnostic" "is not a confirmed email on the GitLab account"
	stderr_has "resolve: the diagnostic says BOTH address sets were checked" \
		"checked both the account's primary address"
	glab_log_has "resolve: the secondary probe ran before declaring a negative" "argv=api user/emails"
	glab_log_has "resolve: the primary probe ran before declaring a negative" "argv=api user host="

	# A primary that MATCHES but is NOT confirmed is still unverified: GitLab
	# marks confirmation with a non-null .confirmed_at, and dropping that filter
	# would accept an address the account never proved it owns.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=0 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab unconfirmed PRIMARY -> exit 1" 1
	stdout_has "resolve: an unconfirmed primary does not verify" "IDENTITY_GITLAB=unverified"

	# The same rule on the additional-addresses list.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_UNCONFIRMED=alice@example.com \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab unconfirmed SECONDARY -> exit 1" 1
	stdout_has "resolve: an unconfirmed additional address does not verify" "IDENTITY_GITLAB=unverified"

	# --- a failed SECONDARY probe must never suppress the PRIMARY answer -----
	# The regression this pins was a real HIGH finding in this build: GET
	# /user/emails FAILS outright while GET /user matches, and the answer must
	# still be 'verified'. Degrading here (to unknown, or worse to unverified)
	# would block a legitimate commit on a probe that never held the answer.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_RC=1 GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: failed secondary probe + matching primary -> exit 0" 0
	stdout_has "resolve: a failed secondary probe does not suppress the primary answer" \
		"IDENTITY_GITLAB=verified"
	check "resolve: a failed secondary probe never degrades a real primary match" \
		"a failing /user/emails probe overrode a confirmed PRIMARY match" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Eq '^IDENTITY_GITLAB=(unknown|unverified)$' && echo 1 || echo 0 )"
	glab_log_has "resolve: the primary probe still ran after the secondary failed" "argv=api user host="

	# --- unknown: BOTH probes FAIL (nonzero exit) ----------------------------
	# The primary address is set to the MATCHING one on purpose: the stub returns
	# before reading it, so this pins that a failed query WINS over a would-be
	# match rather than falling through to 'verified'.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_RC=1 GLAB_USER_RC=1 GLAB_PRIMARY_EMAIL=alice@example.com \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab both probes failed -> exit 0" 0
	stdout_has "resolve: gitlab unknown" "IDENTITY_GITLAB=unknown"
	stdout_has "resolve: the human block annotates gitlab unknown" \
		"GitLab email:    unknown (check could not run"
	stdout_has "resolve: a failed gitlab query does not block the commit" "IDENTITY_STATUS=reconciled"
	stderr_has "resolve: gitlab unknown is a warning, not an error" "warning:"
	stderr_has "resolve: gitlab unknown names the likely cause" "'read_user' or 'api'"
	stderr_has "resolve: gitlab unknown gives the remedy" "glab auth login"
	stderr_has "resolve: relays glab's own failure message" "glab reported: glab: 401 Unauthorized"
	check "resolve: a failed gitlab query never claims 'not a confirmed email'" \
		"reported a definite negative from a query that failed" \
		"$( printf '%s\n' "$CUR_ERR" | grep -q 'is not a confirmed email' && echo 1 || echo 0 )"

	# --- unknown: a query SUCCEEDS but returns a BLANK body ------------------
	# jq exits 0 on empty input and prints nothing, which is indistinguishable
	# from "answered: no match" unless the blank body is caught first.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_BODY= GLAB_USER_BODY= \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab blank bodies -> exit 0" 0
	stdout_has "resolve: a blank body is unknown, not a negative" "IDENTITY_GITLAB=unknown"
	stderr_has "resolve: blank secondary body diagnostic" \
		"'glab api user/emails' succeeded but returned a blank body"
	stderr_has "resolve: blank primary body diagnostic" \
		"'glab api user' succeeded but returned a blank body"

	# WHITESPACE-ONLY is the same case and the sharper one: command substitution
	# strips only TRAILING newlines, so a body of blanks slips past a plain
	# emptiness test, reaches jq, and returns empty at exit 0 — i.e. as a
	# definite negative. The PRIMARY here answers a clean negative, so treating
	# the blank-ish body as an answer would make this run a FATAL 'unverified'.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		"GLAB_EMAILS_BODY=   " GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab whitespace-only body -> exit 0" 0
	stdout_has "resolve: a whitespace-only body is unknown" "IDENTITY_GITLAB=unknown"
	check "resolve: a whitespace-only body never becomes a fatal negative" \
		"a blank-ish body was read as a definite 'unverified'" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=unverified' && echo 1 || echo 0 )"

	# --- unknown: a query SUCCEEDS with the WRONG SHAPE ---------------------
	# An error document served with a 0 exit is exactly what the shape guards
	# exist for. Without `type != "array"` a bare `.[]` iterates an OBJECT's
	# values too, yields nothing, and reads as a definite negative — so the
	# PRIMARY here answers a clean negative, making the whole run a FATAL false
	# 'unverified' the moment that guard is gone.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		'GLAB_EMAILS_BODY={"message":"401 Unauthorized"}' \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab non-array secondary body -> exit 0" 0
	stdout_has "resolve: a non-array body is unknown" "IDENTITY_GITLAB=unknown"
	stderr_has "resolve: non-array shape diagnostic" "did not parse as the expected JSON array"
	check "resolve: an error document is never read as a definite negative" \
		"a 200-with-error-body was reported as 'unverified'" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=unverified' && echo 1 || echo 0 )"

	# The `type != "array"` guard's OWN two cases, isolated. The error document
	# above does not actually isolate it — `select(.confirmed_at)` on a string
	# errors with or without the guard — so these two bodies, which a bare `.[]`
	# consumes WITHOUT erroring, are what make the guard's removal observable.
	#
	# First and sharpest: an OBJECT whose values are email objects. A bare `.[]`
	# iterates those values happily and the filter matches, so a body that is not
	# the documented shape at all MANUFACTURES a 'verified' — a fail-open, not
	# merely a misread negative.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		'GLAB_EMAILS_BODY={"0":{"email":"alice@example.com","confirmed_at":"2020-01-01T00:00:00Z"}}' \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab object-wrapped secondary body -> exit 0" 0
	stdout_has "resolve: an object-wrapped body is unknown" "IDENTITY_GITLAB=unknown"
	check "resolve: a wrong-shaped body can never manufacture 'verified'" \
		"an object-wrapped response was accepted as a confirmed-address list" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=verified' && echo 1 || echo 0 )"

	# The same guard failing the OTHER way: an object with a null value yields NO
	# output at exit 0 (jq indexes null without erroring), which reads as
	# "answered: no confirmed addresses". With the primary answering a clean
	# negative that is a FATAL false 'unverified'.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		'GLAB_EMAILS_BODY={"message":null}' \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab null-valued object body -> exit 0" 0
	stdout_has "resolve: a null-valued object body is unknown" "IDENTITY_GITLAB=unknown"
	check "resolve: a wrong-shaped body is never read as 'no confirmed addresses'" \
		"an object body was read as an answered, empty list" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=unverified' && echo 1 || echo 0 )"

	# The primary probe's own shape guard (`.id | type`), isolated: an error
	# document has a null .confirmed_at, so without the guard it is filtered out
	# and reads as "answered: the primary is not confirmed". The secondary here
	# answers cleanly with no addresses, so that misreading is again FATAL.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED= 'GLAB_USER_BODY={"message":"401 Unauthorized"}' \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab non-user-object primary body -> exit 0" 0
	stdout_has "resolve: a non-user-object body is unknown" "IDENTITY_GITLAB=unknown"
	stderr_has "resolve: non-user-object shape diagnostic" \
		"did not parse as the expected JSON user object"
	check "resolve: an error document on /user is never a definite negative" \
		"a 200-with-error-body on /user was reported as 'unverified'" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Fxq 'IDENTITY_GITLAB=unverified' && echo 1 || echo 0 )"

	# Not JSON at all (a proxy's HTML error page) -> unknown as well.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		'GLAB_EMAILS_BODY=<html>503 Service Unavailable</html>' \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab non-JSON body -> exit 0" 0
	stdout_has "resolve: a non-JSON body is unknown" "IDENTITY_GITLAB=unknown"

	# --- the three top-level glab output pins, BEHAVIOURALLY -----------------
	# GLAB_NO_PROMPT / GLAB_CHECK_UPDATE / GLAB_SHOW_WHATS_NEW are exported at
	# resolve-identity.sh's file top level and documented there as CORRECTNESS, not
	# cosmetics: an update notice or a what's-new banner lands in the CAPTURED
	# stdout of a `glab api` call, jq then fails on the leading prose, and a real
	# 'verified' degrades to 'unknown' — the script fails SAFE but refuses to
	# confirm an identity it could have confirmed.
	#
	# The stub prints that banner unless it INHERITS all three pins (see
	# output_pins_missing), so this otherwise-ordinary run reaching a definite
	# 'verified' is positive evidence the production exports are actually doing the
	# suppressing. Delete any one of them and this case — and every other --gitlab
	# case expecting a definite answer — goes red rather than passing quietly.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab with glab's banners pinned off -> exit 0" 0
	stdout_has "resolve: the output pins keep the parsed body clean (verified)" \
		"IDENTITY_GITLAB=verified"
	check "resolve: no glab banner ever reaches the jq parse" \
		"a glab banner leaked into the captured body and broke the parse — check that GLAB_NO_PROMPT, GLAB_CHECK_UPDATE and GLAB_SHOW_WHATS_NEW are still exported at resolve-identity.sh top level" \
		"$( printf '%s\n' "$CUR_ERR" | grep -Fq 'did not parse as the expected JSON' && echo 1 || echo 0 )"

	# --- THE CAP: --gitlab WITHOUT --gitlab-host ----------------------------
	# The most safety-critical behaviour in the feature. glab resolves its
	# instance from ambient state, so neither definite answer would be about a
	# KNOWN account — and the cap is enforced by NOT ASKING, not by asking and
	# discarding the reply. The primary is the MATCHING address on purpose: the
	# cap has to win over a would-be 'verified'.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab
	expect_rc "resolve: --gitlab unpinned -> exit 0" 0
	stdout_has "resolve: unpinned --gitlab is capped at unknown" "IDENTITY_GITLAB=unknown"
	stdout_has "resolve: the cap does not block the commit" "IDENTITY_STATUS=reconciled"
	stderr_has "resolve: the cap names the missing pin" "--gitlab-host was not given"
	stderr_has "resolve: the cap states that nothing was queried" "no query was made"
	no_glab_api_call "resolve: unpinned --gitlab makes ZERO api calls"
	glab_log_has "resolve: glab WAS invoked, so the zero-api-call proof is not vacuous" \
		"argv=auth status"
	check "resolve: an unpinned run never reports a definite state" \
		"an unpinned run produced a definite verified/unverified" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Eq '^IDENTITY_GITLAB=(verified|unverified)$' && echo 1 || echo 0 )"

	# --- THE CAP: TLS verification disabled ---------------------------------
	# The same untrustworthy-channel rule applied to the TRANSPORT: with
	# skip_tls_verify on, an on-path attacker can answer /user, so a 'verified'
	# would assert nothing. Identical proof technique — capped by NOT ASKING.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_SKIP_TLS=true GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab with skip_tls_verify -> exit 0" 0
	stdout_has "resolve: a TLS-skipping channel is capped at unknown" "IDENTITY_GITLAB=unknown"
	stdout_has "resolve: the TLS cap does not block the commit" "IDENTITY_STATUS=reconciled"
	stderr_has "resolve: the TLS cap names the reason" "SKIP TLS certificate verification"
	stderr_has "resolve: the TLS cap names the host it applies to" "for $GL_HOST"
	stderr_has "resolve: the TLS cap gives the remedy" "glab config set skip_tls_verify false"
	no_glab_api_call "resolve: a TLS-unverified channel is never queried"
	glab_log_has "resolve: skip_tls_verify WAS read, so the zero-api-call proof is not vacuous" \
		"argv=config get skip_tls_verify host=$GL_HOST"
	check "resolve: a TLS-unverified run never reports a definite state" \
		"a skip_tls_verify run produced a definite verified/unverified" \
		"$( printf '%s\n' "$CUR_OUT" | grep -Eq '^IDENTITY_GITLAB=(verified|unverified)$' && echo 1 || echo 0 )"

	# The HOST-SCOPED read is a SECOND probe: a per-host skip_tls_verify entry
	# does not surface in the default lookup, so an instance-specific setting
	# must degrade the answer too.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_SKIP_TLS= GLAB_SKIP_TLS_FOR_HOST=yes \
		GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab with a host-scoped skip_tls_verify -> exit 0" 0
	stdout_has "resolve: a host-scoped TLS skip is capped at unknown" "IDENTITY_GITLAB=unknown"
	no_glab_api_call "resolve: a host-scoped TLS skip is never queried"
	glab_log_has "resolve: the host-scoped skip_tls_verify read happened" \
		"argv=config get skip_tls_verify --host $GL_HOST host=$GL_HOST"

	# An UNRECOGNISED config value is NOT affirmative — degrading on a value
	# nobody can interpret would warn on noise, so the check proceeds normally.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_SKIP_TLS=perhaps GLAB_SKIP_TLS_FOR_HOST=perhaps \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: an uninterpretable skip_tls_verify value -> exit 0" 0
	stdout_has "resolve: an uninterpretable TLS value does not cap the answer" "IDENTITY_GITLAB=verified"
	glab_log_has "resolve: the query proceeded past the TLS advisory" "argv=api user host=$GL_HOST"

	# An explicit skip_tls_verify=FALSE is the affirmative check's other side, and
	# it is not covered by the 'perhaps' case above: 'false' is a value the config
	# CAN legitimately carry and that a reader might plausibly mishandle (a guard
	# testing mere non-emptiness would cap here), whereas 'perhaps' is noise. TLS
	# verification is ON, so the answer must be definite.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_SKIP_TLS=false GLAB_SKIP_TLS_FOR_HOST=false \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: an explicit skip_tls_verify=false -> exit 0" 0
	stdout_has "resolve: skip_tls_verify=false does not cap the answer" "IDENTITY_GITLAB=verified"
	glab_log_has "resolve: skip_tls_verify=false was actually read" \
		"argv=config get skip_tls_verify host=$GL_HOST"
	glab_log_has "resolve: the query proceeded on a TLS-verified channel" \
		"argv=api user host=$GL_HOST"

	# A FAILED config read is NOT the same event as an unset key, but both TLS
	# reads are deliberately tolerant (`|| true`), so the failure arrives as an
	# empty value and the two collapse into "not affirmative, proceed" — the known
	# residual risk of that design. This pins the behaviour that collapse PRODUCES,
	# so a future change of mind there (capping on an unreadable config instead) is
	# a visible, deliberate decision rather than a silent one.
	#
	# Asserting 'verified' rather than merely "not capped" is what makes it
	# discriminating: the run reaches the network probes and answers definitely.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_CONFIG_RC=1 \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: a FAILED skip_tls_verify read -> exit 0" 0
	stdout_has "resolve: a failed TLS config read does not cap the answer" "IDENTITY_GITLAB=verified"
	stdout_has "resolve: a failed TLS config read does not block the commit" "IDENTITY_STATUS=reconciled"
	# Both reads are proven ATTEMPTED (the stub logs before it fails), which is what
	# shows the failing path was genuinely traversed rather than skipped: the
	# host-scoped probe only runs because the first read came back non-affirmative.
	glab_log_has "resolve: the default TLS read was attempted and failed" \
		"argv=config get skip_tls_verify host=$GL_HOST"
	glab_log_has "resolve: the host-scoped TLS read was attempted after it failed" \
		"argv=config get skip_tls_verify --host $GL_HOST host=$GL_HOST"
	glab_log_has "resolve: an unreadable TLS config still queries rather than capping" \
		"argv=api user host=$GL_HOST"
	check "resolve: a failed TLS config read is never reported as a TLS cap" \
		"an unreadable skip_tls_verify was treated as affirmative and capped the answer" \
		"$( printf '%s\n' "$CUR_ERR" | grep -Fq 'SKIP TLS certificate verification' && echo 1 || echo 0 )"

	# --- case folding, DELIBERATELY asymmetric with --github ----------------
	# GitLab down-cases the addresses it stores (Devise case_insensitive_keys),
	# so a mixed-case git config user.email would never match its own confirmed
	# address and would be refused. This is the MIRROR IMAGE of (e2c) above,
	# which pins --github staying CASE-SENSITIVE because GitHub returns
	# addresses in their registered form. Both directions are intentional.
	repo=$(new_gitlab_repo "Mixed Case" "Alice.Dev@Example.COM" "KEYMIXED")
	run_in "$repo" glab+jq "GPG_KEYS=KEYMIXED|FPRMIXED0001|Mixed Case <Alice.Dev@Example.COM>" \
		"$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED= GLAB_PRIMARY_EMAIL=alice.dev@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab case-differing address DOES verify -> exit 0" 0
	stdout_has "resolve: gitlab compares addresses case-insensitively" "IDENTITY_GITLAB=verified"

	# ...and the fold covers the ACCOUNT side too: an upper-case stored address
	# matches a lower-case user.email.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		GLAB_EMAILS_CONFIRMED=ALICE@EXAMPLE.COM \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab folds the ACCOUNT side too -> exit 0" 0
	stdout_has "resolve: an upper-case stored address still matches" "IDENTITY_GITLAB=verified"

	# --- pagination, BEHAVIOURALLY ------------------------------------------
	# /user/emails is per_page=20 and `glab api` does not paginate on its own, so
	# 21 confirmed addresses with the committer's LAST goes red as a false
	# 'unverified' the moment --paginate stops reaching the query. It also pins
	# that the jq filter survives glab's real --paginate output shape: ONE ARRAY
	# PER PAGE, concatenated, never merged into a single array.
	gl_many=$(i=1
		while [ "$i" -le 20 ]; do printf 'gl-filler%s@example.com\n' "$i"; i=$((i + 1)); done
		printf 'alice@example.com\n')
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		"GLAB_EMAILS_CONFIRMED=$gl_many" \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: --gitlab verified on page 2 -> exit 0" 0
	stdout_has "resolve: the 21st confirmed address still verifies" "IDENTITY_GITLAB=verified"

	# --- --github and --gitlab are INDEPENDENT ------------------------------
	# Each reports its OWN account's state; neither may leak into the other. Here
	# gh says NOT verified while glab says confirmed.
	repo=$(new_gitlab_repo)
	run_in "$repo" gh+glab+jq "$GPG_ALICE" \
		GH_AUTHED=1 GH_VERIFIED_EMAILS=someone@else.com \
		"$GLAB_AUTH" "$GLAB_LOG" GLAB_EMAILS_CONFIRMED= \
		GLAB_PRIMARY_EMAIL=alice@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --github --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: github-unverified + gitlab-verified -> exit 1" 1
	stdout_has "resolve: the github line reports its own negative" "IDENTITY_GITHUB=unverified"
	stdout_has "resolve: the gitlab line is not dragged down with it" "IDENTITY_GITLAB=verified"
	stdout_has "resolve: a github negative alone is still fatal" "IDENTITY_STATUS=mismatch"

	# The mirror image: gh verified, glab NOT confirmed.
	repo=$(new_gitlab_repo)
	run_in "$repo" gh+glab+jq "$GPG_ALICE" \
		GH_AUTHED=1 GH_VERIFIED_EMAILS=alice@example.com \
		"$GLAB_AUTH" "$GLAB_LOG" GLAB_EMAILS_CONFIRMED=other@example.com \
		GLAB_PRIMARY_EMAIL=primary@example.com GLAB_PRIMARY_CONFIRMED=1 \
		sh "$RESOLVE" --github --gitlab --gitlab-host "$GL_HOST"
	expect_rc "resolve: github-verified + gitlab-unverified -> exit 1" 1
	stdout_has "resolve: the github line keeps its own positive" "IDENTITY_GITHUB=verified"
	stdout_has "resolve: the gitlab line reports its own negative" "IDENTITY_GITLAB=unverified"

	# The SPECULATIVE both-flags case the optional pin exists for: gh absent
	# (skipped) + --gitlab unpinned (capped) -> two distinct non-fatal states.
	repo=$(new_gitlab_repo)
	run_in "$repo" glab+jq "$GPG_ALICE" "$GLAB_AUTH" "$GLAB_LOG" \
		sh "$RESOLVE" --github --gitlab
	expect_rc "resolve: speculative --github --gitlab -> exit 0" 0
	stdout_has "resolve: absent gh reports skipped" "IDENTITY_GITHUB=skipped"
	stdout_has "resolve: unpinned gitlab reports unknown" "IDENTITY_GITLAB=unknown"
	stdout_has "resolve: neither speculative check blocks the commit" "IDENTITY_STATUS=reconciled"
else
	skip_section "resolve --gitlab (four states)" "jq not available"
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
run_in "$repo" none "$BOTH_KEYS" sh "$LIST"
expect_rc "list: found identities -> exit 0" 0
stdout_has "list: gpg alice present" "alice@example.com"
stdout_has "list: gpg bob present" "bob@example.com"
stdout_has "list: ssh amy present" "amy@example.com"
stdout_has "list: ssh zoe present" "zoe@example.com"
stdout_has "list: identity count is 4" "IDENTITY_COUNT=4"
check "list: gpg ordered before ssh (IDENTITY_1 is gpg)" "IDENTITY_1 was not gpg" \
	"$( printf '%s\n' "$CUR_OUT" | grep -q '^IDENTITY_1_METHOD=gpg' && echo 0 || echo 1 )"
run1=$CUR_OUT
run_in "$repo" none "$BOTH_KEYS" sh "$LIST"
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
run_in "$repo" none "GPG_KEYS=" sh "$LIST"
expect_rc "list(multi-principal): -> exit 0" 0
stdout_has "list(multi-principal): first principal listed" "p1@example.com"
stdout_has "list(multi-principal): second principal listed" "p2@example.com"
stdout_has "list(multi-principal): count is 2" "IDENTITY_COUNT=2"

# Revoked UID must not be offered by list either.
repo=$(new_repo)
run_in "$repo" none "GPG_KEYS=KEYALICE|FPRALICE0001|Alice New <new@example.com>|r:Alice Old <revoked@example.com>" sh "$LIST"
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
	run_in "$repo" none "GPG_KEYS=" sh "$LIST"
	expect_rc "list(cfg ssh key path): -> exit 0" 0
	stdout_has "list(cfg ssh key path): comment email listed" "cfgkey@example.com"
	stdout_has "list(cfg ssh key path): keytype as KEY_ID" "IDENTITY_1_KEY_ID=ssh-ed25519"
	check "list(cfg ssh key path): real SHA256 fingerprint" "fingerprint is not a SHA256" \
		"$( printf '%s\n' "$CUR_OUT" | grep -q 'IDENTITY_1_FPR=SHA256:' && echo 0 || echo 1 )"
else
	skip_section "list(cfg ssh key path)" "ssh-keygen not available"
fi

# No identities at all -> exit 1
repo=$(new_repo)
run_in "$repo" none "GPG_KEYS=" sh "$LIST"
expect_rc "list: none found -> exit 1" 1

# ===========================================================================
# switch-identity.sh
# ===========================================================================
section "switch-identity.sh"

# Sets repo-local config; validates key exists first
repo=$(new_repo)
run_in "$repo" none "$GPG_BOB" sh "$SWITCH" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB --format gpg
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
run_in "$repo" none "$GPG_BOB" sh "$SWITCH" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB --format gpg
after=$(git_iso "$repo" config --local --list 2>/dev/null | LC_ALL=C sort)
check "switch: idempotent (config unchanged on re-run)" "config changed on identical re-run" \
	"$( [ "$before" = "$after" ] && echo 0 || echo 1 )"

# Rejects a non-existent key -> exit 1, nothing written
repo=$(new_repo)
run_in "$repo" none "$GPG_ALICE" sh "$SWITCH" --email nobody@example.com --name "No Body" --signingkey KEYMISSING --format gpg
expect_rc "switch: missing key -> exit 1" 1
stderr_has "switch: missing key diagnostic" "no GPG secret key found"
wrote=$(git_iso "$repo" config user.email 2>/dev/null || true)
check "switch: nothing written on invalid key" "config was written despite invalid key" \
	"$( [ -z "$wrote" ] && echo 0 || echo 1 )"

# --scope global: value lands in $HOME/.gitconfig, NOT in repo-local config.
repo=$(new_repo)
run_in "$repo" none "$GPG_BOB" sh "$SWITCH" --email global@example.com --name "Global User" --signingkey KEYBOB --format gpg --scope global
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
run_in "$repo" none sh "$SWITCH" --email x@example.com --name "X" --signingkey "$repo/empty.pub" --format ssh
expect_rc "switch(ssh): empty key file rejected -> exit 1" 1
stderr_has "switch(ssh): empty-file diagnostic" "no valid key line"
printf 'this is not a key\n' > "$repo/garbage.pub"
run_in "$repo" none sh "$SWITCH" --email x@example.com --name "X" --signingkey "$repo/garbage.pub" --format ssh
expect_rc "switch(ssh): garbage key file rejected -> exit 1" 1

# Trailing positional args after '--' are a usage error.
repo=$(new_repo)
run_in "$repo" none sh "$SWITCH" --email x@example.com --name "X" --signingkey KEYBOB --format gpg -- extra
expect_rc "switch: trailing arg after -- -> exit 2" 2

# Bad usage: missing required args -> exit 2
repo=$(new_repo)
run_in "$repo" none sh "$SWITCH" --email x@example.com
expect_rc "switch: missing --name/--signingkey -> exit 2" 2

# switch -> resolve round-trip
repo=$(new_repo)
run_in "$repo" none "$GPG_BOB" sh "$SWITCH" --email bob@example.com --name "Bob Dev" --signingkey KEYBOB --format gpg
run_in "$repo" none "$GPG_BOB" sh "$RESOLVE"
expect_rc "round-trip: resolve after switch -> exit 0" 0
stdout_has "round-trip: reconciled" "IDENTITY_STATUS=reconciled"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n== summary ==\n'
printf 'ran %s checks, %s failed, %s section(s) skipped\n' \
	"$TESTS_RUN" "$TESTS_FAIL" "$TESTS_SKIPPED_SECTIONS"
[ "$TESTS_FAIL" -eq 0 ] || exit 1
if [ "$TESTS_SKIPPED_SECTIONS" -eq 0 ]; then
	printf 'ALL TESTS PASSED\n'
else
	printf '!! %s SECTION(S) SKIPPED -- that coverage did NOT run on this host; see the\n' \
		"$TESTS_SKIPPED_SECTIONS"
	printf '!! "SKIP SECTION" lines above and install the named tool for a full run.\n'
	printf 'PASSED WHAT RAN (NOT a full pass: %s section(s) skipped)\n' "$TESTS_SKIPPED_SECTIONS"
fi
exit 0
