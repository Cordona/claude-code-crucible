#!/usr/bin/env sh
#
# run-engine-tests.sh — zero-dependency POSIX test harness for jira.sh: the
#                        engine core + view/search/workflow.
#
# WHY a hand-rolled harness (not bats): same rationale as the sibling
# tests/run-tests.sh (md-to-adf.sh) and procedure-gh-issues/tests/run-tests.sh
# — the whole point of this suite is "runs on any machine with no
# dependencies beyond jq". Requiring bats-core would contradict that.
#
# The runner primitives and the curl stub live in tests/lib/harness.sh and
# tests/lib/curl-stub.sh, dot-sourced by all three Jira suites; this file owns
# only its own PATH-toolbox selector map and its assertions.
#
# What it does:
#   * Builds an isolated PATH toolbox of symlinks to only the real tools
#     jira.sh needs (jq, mktemp, sed, grep, tr, ...) PLUS a STUB `curl` so no
#     test ever makes a real network call. The curl stub lives in its OWN
#     dir that tests opt into via the run() selector, so "curl absent" and
#     "jq absent" are exercised for real by leaving the relevant tool off
#     PATH — same technique as the sibling harnesses.
#   * That stub is a canned-response QUEUE and records what each call was
#     handed (argv, `--data @file` bodies, `-K -` stdin configs) — which is how
#     a test proves the exact URL/method hit, the exact JSON body sent, and
#     that the token never appears as an argv token. lib/curl-stub.sh's own
#     header is the single statement of the mechanism and of why each record
#     exists; it is not restated here.
#   * Everything runs under `env -i` with an isolated HOME + TMPDIR, and the
#     jira.sh-relevant env vars (JIRA_EMAIL, JIRA_TOKEN, JIRA_SITE,
#     JIRA_CURL_CONFIG, JIRA_PROJECTS_DIR, JIRA_HOST_ALLOWLIST_PATTERN) are
#     passed through explicitly per test via `run()`'s VAR=VALUE args —
#     never inherited from the real environment.
#
# Usage:  sh run-engine-tests.sh              # run all tests
#         VERBOSE=1 sh run-engine-tests.sh
#         (also runs green under dash: dash run-engine-tests.sh)
#
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

# ---------------------------------------------------------------------------
# Locations
# ---------------------------------------------------------------------------
TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPTS_DIR=$(cd "$TESTS_DIR/../skill/scripts" && pwd)
JIRA="$SCRIPTS_DIR/jira.sh"

# Shared harness mechanics (runner primitives + the curl stub) — one copy for
# all three Jira suites; see lib/harness.sh's header for what stays local.
# shellcheck source=SCRIPTDIR/lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"
# shellcheck source=SCRIPTDIR/lib/curl-stub.sh
. "$TESTS_DIR/lib/curl-stub.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/jira-engine-tests.XXXXXX")
TOOLBOX="$WORK/toolbox"          # real tools, curl NEVER here
NOJQ_TOOLBOX="$WORK/nojq"        # real tools, jq deliberately OMITTED
STUBCURL_DIR="$WORK/stubcurl"    # ONLY the stub `curl`
mkdir -p "$TOOLBOX" "$NOJQ_TOOLBOX" "$STUBCURL_DIR" "$WORK/home"

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Isolated PATH toolboxes: symlink only the real tools jira.sh needs.
#
# dirname/readlink/realpath/basename are DELIBERATELY ABSENT, and that absence
# is a load-bearing regression guard, not an oversight: jira.sh resolves
# skill/lib/ and md-to-adf.sh from its own $0 with pure parameter expansion
# (see its Portability header), and a future regression to
# `SCRIPT_DIR=$(dirname "$0")` must break this suite loudly instead of passing
# green. Adding any of the four back here silently voids that claim.
#
# THREE TOOLS ARE PRESENT FOR `attach --download` ALONE, and each fails a
# DIFFERENT way without them — the distinction matters, because only two of the
# three break the feature:
#
#   * `ls` — runtime.sh's assert_safe_tmpdir reads ${TMPDIR:-/tmp}'s mode string
#     from `ls -ld DIR/.`, and any string it cannot read as a directory's —
#     an ABSENT `ls` included — fails CLOSED. It gates ensure_workdir AND
#     credentials.sh's own $TMPDIR `mktemp`, i.e. every invocation that creates a
#     temp file, so without this entry the whole suite refuses at startup rather
#     than only the download cases.
#   * `ln` — the install itself is `ln -n "$staged" "$dest"` (http.sh's
#     download_attachment_content), so without it every `attach --download` case
#     dies on a "command not found" install instead of on whatever it is about.
#   * `df` — runtime.sh's is_known_cross_device. This one does NOT break the
#     feature: that function is a COURTESY fast-fail and fails PERMISSIVE, so a
#     `df` it cannot run yields "no confident verdict" and the download proceeds
#     (the real cross-device refusal is `ln`'s own inability to hard-link across
#     filesystems). It is here because `df`'s stderr is deliberately unsuppressed
#     — a missing tool would leak "df: not found" into every download case's
#     stderr, where this suite makes exact stderr claims.
# ---------------------------------------------------------------------------
harness_init "$WORK"
for t in sh mktemp sed grep tr cat rm chmod cp mv tail mkdir date df ln ls id; do
	link_tool "$TOOLBOX" "$t"
	link_tool "$NOJQ_TOOLBOX" "$t"
done
link_tool "$TOOLBOX" jq

# A THIRD toolbox identical to TOOLBOX but with a FIXED-output `date` stub, so
# the backup-collision path is exercised DETERMINISTICALLY: two --write
# runs land in the "same UTC second" and must still produce two distinct
# backups (proving the mktemp uniquifier, not luck of the clock). Selected via
# run()'s `fixedtime`.
FIXEDDATE_TOOLBOX="$WORK/fixeddate"
mkdir -p "$FIXEDDATE_TOOLBOX"
for t in sh mktemp sed grep tr cat rm chmod cp mv tail mkdir df ln ls id jq; do
	link_tool "$FIXEDDATE_TOOLBOX" "$t"
done
cat >"$FIXEDDATE_TOOLBOX/date" <<'FIXED_DATE_STUB'
#!/usr/bin/env sh
# test stub: ignore args, always emit one fixed UTC stamp so two writes collide
printf '20260725T000000Z\n'
FIXED_DATE_STUB
chmod +x "$FIXEDDATE_TOOLBOX/date"

# A FOURTH toolbox identical to TOOLBOX but with a `mktemp` that REFUSES `-u`,
# so the engine's two name-minting sites (runtime.sh's stage_install_copy, which
# both installers reach, and cmd-discover.sh's config backup) can be exercised
# against an implementation that does not support the flag they depend on.
# Selected via run()'s `nomktempu`.
#
# IT DELEGATES EVERYTHING ELSE TO THE REAL `mktemp`, and that is what makes the
# two cases attributable rather than a startup failure: ensure_workdir's
# `mktemp -d` and credentials.sh's own `mktemp` must still work, or the run dies
# before it reaches a config install at all. The real path is resolved against
# the ORIGINAL PATH for the same reason link_tool does it — no toolbox exists on
# the isolated PATH to find it on.
NOMKTEMPU_TOOLBOX="$WORK/nomktempu"
mkdir -p "$NOMKTEMPU_TOOLBOX"
for t in sh sed grep tr cat rm chmod cp mv tail mkdir date df ln ls id jq; do
	link_tool "$NOMKTEMPU_TOOLBOX" "$t"
done
NOMKTEMPU_REAL_MKTEMP=$(PATH="$HARNESS_ORIG_PATH" command -v mktemp)
cat >"$NOMKTEMPU_TOOLBOX/mktemp" <<NO_MKTEMP_U_STUB
#!/usr/bin/env sh
# test stub: an implementation whose \`mktemp\` has no \`-u\`. Every other
# invocation delegates to the real one.
for stub_arg in "\$@"; do
	[ "\$stub_arg" = "-u" ] || continue
	printf 'mktemp: illegal option -- u\n' >&2
	exit 1
done
exec $NOMKTEMPU_REAL_MKTEMP "\$@"
NO_MKTEMP_U_STUB
chmod +x "$NOMKTEMPU_TOOLBOX/mktemp"

# A FIFTH toolbox identical to TOOLBOX but with an `ls` that reports a fabricated
# ACL MARKER for ONE named directory and delegates every other reading to the real
# one, so assert_safe_dir's ACL block can be reached from the CLI. Selected via
# run()'s `aclls`.
#
# WHY A STUB AND NOT A REAL ACL, which is the obvious idea and was tried: macOS
# `ls` prints ONE marker character and `@` (extended attributes) takes precedence
# over `+`, and on macOS 26 every freshly created directory carries an
# unremovable `com.apple.provenance` xattr — so a directory given a real ACL with
# `chmod +a` reads `drwx------@` and is NOT flagged. runtime.sh's ACL note
# documents exactly that limitation, and it was re-verified on this platform
# before this toolbox was written. A fabricated marker is therefore the only way
# to reach the block from the CLI here, and it is sound for the same reason the
# fabricated-owner override further down is: assert_safe_dir reads the marker, the
# mode bits and the owner uid out of that ONE `ls` line and consults the
# filesystem for nothing else.
#
# IT ALSO LOGS EVERY READING OF THAT DIRECTORY, and that log is what makes the
# memoization claim discriminating rather than vacuous: "exactly one warning" is
# equally true of a run that gated the directory ONCE, so the number of GATE
# READINGS has to be observable next to the number of warnings.
ACL_LS_TOOLBOX="$WORK/aclls"
mkdir -p "$ACL_LS_TOOLBOX"
for t in sh mktemp sed grep tr cat rm chmod cp mv tail mkdir date df ln id jq; do
	link_tool "$ACL_LS_TOOLBOX" "$t"
done
ACL_LS_PROJECTS_DIR="$WORK/install-cli-acl"
ACL_LS_READING_LOG="$WORK/install-cli-acl-ls-readings.log"
ACL_LS_REAL_LS=$(PATH="$HARNESS_ORIG_PATH" command -v ls)
cat >"$ACL_LS_TOOLBOX/ls" <<ACL_LS_STUB
#!/usr/bin/env sh
# test stub: report a fabricated ACL-marked mode for ONE directory and log the
# reading; delegate every other invocation to the real \`ls\`.
#
# THE LAST ARGUMENT IS WHAT IS MATCHED, because assert_safe_dir's own call is
# \`ls -ldn "\$DIR/."\` — the trailing \`/.\` included, which is why this pattern
# carries it too rather than matching the bare directory.
for stub_arg in "\$@"; do stub_last=\$stub_arg; done
if [ "\$stub_last" = '$ACL_LS_PROJECTS_DIR/.' ]; then
	printf '%s\n' "\$stub_last" >>'$ACL_LS_READING_LOG'
	printf 'drwx------+ 2 0 0 64 Jan 1 00:00 .\n'
	exit 0
fi
exec $ACL_LS_REAL_LS "\$@"
ACL_LS_STUB
chmod +x "$ACL_LS_TOOLBOX/ls"

# The canned-response-queue curl stub (lib/curl-stub.sh owns the mechanism).
init_curl_stub "$STUBCURL_DIR" "$WORK"

# run SELECTOR [VAR=VALUE...] COMMAND... — the PATH-toolbox selector map, the
# one part of the runner that is genuinely per-suite. Everything else lives in
# lib/harness.sh's harness_run.
run() {
	selector=$1; shift
	case "$selector" in
		full)      r_path="$STUBCURL_DIR:$TOOLBOX" ;;
		nocurl)    r_path="$TOOLBOX" ;;
		nojq)      r_path="$STUBCURL_DIR:$NOJQ_TOOLBOX" ;;
		fixedtime) r_path="$STUBCURL_DIR:$FIXEDDATE_TOOLBOX" ;;
		nomktempu) r_path="$STUBCURL_DIR:$NOMKTEMPU_TOOLBOX" ;;
		aclls)     r_path="$STUBCURL_DIR:$ACL_LS_TOOLBOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$selector" >&2; exit 1 ;;
	esac
	harness_run "$r_path" "$@"
}

# umask_run MASK SELECTOR [VAR=VALUE...] COMMAND... — one run() under an
# EXPLICIT process umask, restored immediately afterwards.
#
# WHY IT EXISTS: `env -i` isolates the environment but NOT the umask, which is
# process state and is inherited straight through. Two claims in this suite are
# about a file MODE the engine sets — `attach --download`'s installed 0600 and
# the workdir's own 0700 — and both would pass for the wrong reason under an
# ambient 077, where every file the engine creates is already 0600 whether or not
# it asked. Pinning the mask makes those assertions discriminating; the two
# callers each also assert what the pinned mask alone would have produced.
umask_run() {
	ur_mask=$1; shift
	ur_saved_umask=$(umask)
	umask "$ur_mask"
	run "$@"
	umask "$ur_saved_umask"
}

# ---------------------------------------------------------------------------
# Shared diagnostic needles
#
# PRIORITY_SCOPE_DIAG — jira.sh's --priority foreign-flag refusal (asserted at
# four sites below: view, and bulk's transition/comment/ordering cases; the
# transition site lives in the sibling run-write-tests.sh, which defines its own
# copy because the two suites are separate processes with no shared state).
#
# The `error: ` prefix is LOAD-BEARING, not decoration. Every exit-2 guard dumps
# the full usage() text to stderr BEFORE its diagnostic, and usage.sh's file-
# header COMMENT already documents this exact scoping rule in near-identical
# prose (not the printed usage() heredoc itself, which carries no "only valid"
# text today) — so if that comment's wording ever migrates into the heredoc, a
# needle made of the bare sentence alone would become satisfiable by the usage
# dump, proving only "some guard exited 2", not "THIS guard fired". Only
# runtime.sh's error() writer emits the `<prog>: error: <msg>` form; usage()
# can never carry it, today or after such a migration. The same prefix is what
# makes the stderr_not_has ordering assertion below meaningful: absence of the
# sentence is only evidence when usage()'s copy of it cannot satisfy the needle.
# ---------------------------------------------------------------------------
PRIORITY_SCOPE_DIAG="error: --priority is only valid with create, update, and bulk --op update"

# REVIEWER_SCOPE_DIAG — the same refusal for --reviewer, which shares --priority's
# three readers exactly (the `error: ` prefix is load-bearing for the reason stated
# above). A separate needle rather than a parameterised one because the FLAG NAME is
# the half of the message a regression would get wrong: the guard is one shared
# function taking both the flag and the owner list as arguments, so a copy-paste
# slip yields the right owner list under the wrong flag name.
REVIEWER_SCOPE_DIAG="error: --reviewer is only valid with create, update, and bulk --op update"

# DEVELOPER_SCOPE_DIAG — the same refusal for --developer, over a NARROWER owner set
# than --reviewer's: cmd_update is its only direct reader, so the owner list this
# needle pins is TWO commands and `create` is NOT among them. Reusing
# REVIEWER_SCOPE_DIAG for the bulk case below would assert a create-accepting owner
# list and pass only while the guard was wrong. The `error: ` prefix is load-bearing
# for the reason stated above.
DEVELOPER_SCOPE_DIAG="error: --developer is only valid with update, and bulk --op update"

# ASSIGNEE_SCOPE_DIAG — the same refusal for --assignee, over a WIDER owner set than
# --reviewer's: `search` reads it too (as an `assignee = ...` JQL clause), so the owner
# list this needle pins is FOUR commands, not three. Reusing REVIEWER_SCOPE_DIAG for
# the bulk case below would assert a search-less owner list and pass only while the
# guard was wrong. The `error: ` prefix is load-bearing for the reason stated above.
ASSIGNEE_SCOPE_DIAG="error: --assignee is only valid with create, update, search, and bulk --op update"

# DOWNLOAD_SCOPE_DIAG — the same refusal for --download, over a NARROWER owner set
# than --developer's: ONE command, `attach`. It is also the one whose silent drop would be
# worst, because the flag names a LOCAL DESTINATION — `view PROJ-1 --download out.json`
# would otherwise exit 0, print the issue to stdout, and leave the caller believing a
# file was written that nothing ever created. The `error: ` prefix is load-bearing for
# the reason stated above.
DOWNLOAD_SCOPE_DIAG="error: --download is only valid with attach"

# ===========================================================================
# usage / argument errors
# ===========================================================================
section "jira.sh — usage / command errors"

run nocurl sh "$JIRA" -h
expect_rc "usage: -h -> exit 0" 0
stdout_has "usage: help text" "Usage"
stdout_has "usage: mentions --confirmed-site" "--confirmed-site"

run nocurl sh "$JIRA"
expect_rc "missing command -> exit 2" 2
stderr_has "missing command: diagnostic" "missing command"

run nocurl sh "$JIRA" bogus
expect_rc "unknown command -> exit 2" 2
stderr_has "unknown command: diagnostic" "unknown command"

run nocurl sh "$JIRA" view PROJ-1
expect_rc "view without --confirmed-site -> exit 2" 2
stderr_has "view without --confirmed-site: diagnostic" "--confirmed-site is required"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view not-a-key --confirmed-site foo.atlassian.net
expect_rc "view with invalid ticket key -> exit 2" 2
stderr_has "invalid ticket key: diagnostic" "invalid ticket key"

# validate_ticket_key must reject an EMBEDDED/trailing newline, not
# just accept a `grep -Eq '^...$'` match against the first line of a
# multi-line value. These keys are built with a LITERAL newline byte (not
# via `$(...)`, which would strip a trailing one) so the test actually
# exercises the bypass the hardening closes.
EMBEDDED_NEWLINE_KEY="PROJ-1
foo"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view "$EMBEDDED_NEWLINE_KEY" --confirmed-site foo.atlassian.net
expect_rc "view with an embedded-newline ticket key -> exit 2" 2
stderr_has "embedded-newline ticket key: diagnostic" "invalid ticket key"

TRAILING_NEWLINE_KEY="PROJ-1
"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view "$TRAILING_NEWLINE_KEY" --confirmed-site foo.atlassian.net
expect_rc "view with a trailing-newline ticket key -> exit 2" 2
stderr_has "trailing-newline ticket key: diagnostic" "invalid ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow --confirmed-site foo.atlassian.net
expect_rc "workflow without a ticket key -> exit 2" 2
stderr_has "workflow without ticket key: diagnostic" "requires a ticket key"

# ===========================================================================
# site gate — fails closed, no curl call ever made. Uses
# the "full" toolbox (curl stub present, but the response queue stays EMPTY)
# so each assertion also proves the gate fired BEFORE any network call —
# curl/jq presence is checked first (see the script's dispatch ordering),
# so these tests must supply real tools to reach the gate at all.
# ===========================================================================
section "jira.sh — site gate (fail closed)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site evil.example.com
expect_rc "host outside allow-list -> exit 1" 1
stderr_has "host outside allow-list: diagnostic" "not in the allow-list"
equals "host outside allow-list: no network call was made" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_SITE=other.atlassian.net" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "intended-site != confirmed-site -> exit 1" 1
stderr_has "site mismatch: diagnostic" "site mismatch"
equals "site mismatch: no network call was made" "$(call_count)" "0"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_SITE=foo.atlassian.net" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site https://foo.atlassian.net/
expect_rc "intended-site == confirmed-site (scheme/slash normalized) does NOT fail the gate" 0

reset_curl_stub
run full "JIRA_CURL_CONFIG=$WORK/does-not-exist.curlrc" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "JIRA_CURL_CONFIG pointing nowhere -> exit 1" 1
stderr_has "missing JIRA_CURL_CONFIG: diagnostic" "missing/unreadable"
equals "missing JIRA_CURL_CONFIG: no network call was made" "$(call_count)" "0"

reset_curl_stub
run full sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "no credentials at all -> exit 1" 1
stderr_has "no credentials: diagnostic" "no credentials available"
equals "no credentials: no network call was made" "$(call_count)" "0"

# ===========================================================================
# credential handoff — the token NEVER touches argv
# ===========================================================================
section "jira.sh — credential handoff: token never on argv"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200

run full "JIRA_EMAIL=agent@example.com" "JIRA_TOKEN=super-secret-token-value" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "view with own-resolved credentials -> exit 0" 0
file_not_has "argv log never contains the raw token" "$CURL_STUB_ARGV_LOG" "super-secret-token-value"
file_not_has "argv log never contains -u/--user" "$CURL_STUB_ARGV_LOG" "-u"
argv_log_has_token "argv log DOES contain -K (the config-file handoff)" "-K"

section "jira.sh — credential handoff: JIRA_CURL_CONFIG passthrough is never deleted"

# The supplied file must be named `<confirmed-host>.cfg` — resolve_credential_config
# binds an external config to the site by its basename (the refusal of a
# mis-named one is the next section). It lives in its OWN directory so it cannot
# be confused with the other `foo.atlassian.net.cfg` fixture far below.
mkdir -p "$WORK/supplied-cfg"
OWN_CFG="$WORK/supplied-cfg/foo.atlassian.net.cfg"
printf 'user = "someone@example.com:their-token"\n' >"$OWN_CFG"
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_CURL_CONFIG=$OWN_CFG" sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "view via JIRA_CURL_CONFIG -> exit 0" 0
argv_log_has_token "JIRA_CURL_CONFIG: -K flag present" "-K"
argv_log_has_token "JIRA_CURL_CONFIG: curl was invoked with -K \$OWN_CFG (the exact path)" "$OWN_CFG"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$OWN_CFG" ]; then pass "pre-supplied curl-config file survives (not ours to delete)"
else fail "pre-supplied curl-config file survives" "file was removed"; fi

section "jira.sh — credential handoff: a JIRA_CURL_CONFIG not named for the confirmed site is refused before any request"

# Two mis-names, one per way a caller gets it wrong: a generic name that says
# nothing about its site, and a file named for a DIFFERENT site — the case the
# basename binding exists for. Both hold valid-looking credentials, so the
# refusal can only come from the name.
mkdir -p "$WORK/misnamed-cfg"
MISNAMED_GENERIC_CFG="$WORK/misnamed-cfg/preexisting.curlrc"
MISNAMED_OTHER_SITE_CFG="$WORK/misnamed-cfg/bar.atlassian.net.cfg"
printf 'user = "someone@example.com:their-token"\n' >"$MISNAMED_GENERIC_CFG"
printf 'user = "someone@example.com:their-token"\n' >"$MISNAMED_OTHER_SITE_CFG"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_CURL_CONFIG=$MISNAMED_GENERIC_CFG" sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "JIRA_CURL_CONFIG named preexisting.curlrc -> exit 1 (refused)" 1
stderr_has "JIRA_CURL_CONFIG generic name: the diagnostic names the file and the expected basename" \
	"basename 'preexisting.curlrc' does not match the confirmed site 'foo.atlassian.net.cfg'"
equals "JIRA_CURL_CONFIG generic name: ZERO curl calls (the credential never reached curl)" "$(call_count)" "0"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_CURL_CONFIG=$MISNAMED_OTHER_SITE_CFG" sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "JIRA_CURL_CONFIG named for ANOTHER site -> exit 1 (refused)" 1
stderr_has "JIRA_CURL_CONFIG other site: the diagnostic names the other site's file" \
	"basename 'bar.atlassian.net.cfg' does not match the confirmed site 'foo.atlassian.net.cfg'"
equals "JIRA_CURL_CONFIG other site: ZERO curl calls" "$(call_count)" "0"

# ===========================================================================
# view <KEY>
# ===========================================================================
section "jira.sh — view: --json passthrough"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"Fix the thing","status":{"name":"Open"},"issuetype":{"name":"Task"},"assignee":{"displayName":"A. Gent"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net --json
expect_rc "view --json -> exit 0" 0
VIEW_JSON_KEY=$(printf '%s' "$CUR_OUT" | jq -r '.key')
equals "view --json: raw body on stdout parses as JSON with the right key" "$VIEW_JSON_KEY" "PROJ-1"

section "jira.sh — view: human render strips control/ANSI from response text"

reset_curl_stub
ESC=$(printf '\033')
BEL=$(printf '\007')
SOH=$(printf '\001')
DIRTY_SUMMARY="Danger${ESC}[31m RED ${ESC}[0mtext${BEL}Bell${SOH}Ctrl"
set_stub_response 1 "$(jq -n -c --arg s "$DIRTY_SUMMARY" '{key:"PROJ-2",fields:{summary:$s,status:{name:"Open"},issuetype:{name:"Bug"},assignee:{displayName:"A"}}}')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-2 --confirmed-site foo.atlassian.net
expect_rc "view human render -> exit 0" 0
stdout_not_has "ANSI escape sequence stripped from render" "${ESC}["
stdout_not_has "bare C0 byte (BEL, \\007) stripped from render" "$BEL"
stdout_not_has "bare C0 byte (SOH, \\001) stripped from render" "$SOH"
stdout_has "underlying text survives the strip" "Danger"
stdout_has "underlying text survives the strip (RED)" "RED"
stdout_has "underlying text survives the strip (Bell)" "Bell"
stdout_has "underlying text survives the strip (Ctrl)" "Ctrl"

section "jira.sh — view: --fields resolves semantic names through the project config"

mkdir -p "$WORK/projects"
cat >"$WORK/projects/PROJ.json" <<'EOF'
{
  "key": "PROJ",
  "custom_fields": { "acceptance_criteria": "customfield_16102" },
  "type_aliases": { "subtask": "Sub-task" }
}
EOF
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-3","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" view PROJ-3 --confirmed-site foo.atlassian.net --fields acceptance_criteria,summary
expect_rc "view --fields with config alias -> exit 0" 0
file_has "request URL carries the RESOLVED custom field id" "$CURL_STUB_ARGV_LOG" "customfield_16102"

section "jira.sh — view: non-2xx fails with Jira's error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Issue does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-9 --confirmed-site foo.atlassian.net
expect_rc "view 404 -> exit 1" 1
stderr_has "view 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "view 404: Jira's own error message surfaced" "Issue does not exist"

section "jira.sh — view: a 2xx response with a non-JSON body fails as an API error, not a stray jq exit-2"

reset_curl_stub
set_stub_response 1 '<html>not json, e.g. an intermediary proxy error page</html>' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-9 --confirmed-site foo.atlassian.net
expect_rc "view 200-with-non-JSON-body -> exit 1 (NOT jq's own exit 2)" 1
stderr_has "view 200-with-non-JSON-body: diagnostic" "not valid JSON"

# jira.sh's --priority scoping block keys off the COMMAND NAME, not off the
# read/write classification readonlygate.sh owns, so a PURE READ must refuse the
# flag exactly as a write command does. view is that read: `view PROJ-1` is
# otherwise fully valid here (well-shaped key, validator passes), so the exit 2
# can only come from the scoping block and not from an unrelated usage error.
#
# Runs under `full` (the stub curl IS on PATH) and asserts ZERO calls, so
# "refused before the network" is a real observation rather than an artifact of
# curl being unavailable.
section "jira.sh — view: a stray --priority is refused before any network call (--priority belongs to create/update/bulk --op update)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --priority High --confirmed-site foo.atlassian.net
expect_rc "view + --priority -> exit 2" 2
stderr_has "view stray --priority: diagnostic names the three commands that DO support it" \
	"$PRIORITY_SCOPE_DIAG"
equals "view stray --priority: ZERO curl calls (the issue is never fetched)" "$(call_count)" "0"

# --download's guard is the newest member of that scoping block and the one with a
# LOCAL side effect to lose: `view` accepts the flag's carrier (every command shares
# OPT_DOWNLOAD) and cmd_view never reads it, so an unguarded stray --download would
# exit 0 having printed the issue while nothing wrote the file the caller named.
# Same structure as the --priority case above — `view PROJ-1` is otherwise fully
# valid, so the exit 2 can only come from the scoping block.
section "jira.sh — view: a stray --download is refused before any network call (--download belongs to attach)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --download "$WORK/view-stray-download.json" --confirmed-site foo.atlassian.net
expect_rc "view + --download -> exit 2" 2
stderr_has "view stray --download: diagnostic names --download and attach as its ONE owner" \
	"$DOWNLOAD_SCOPE_DIAG"
equals "view stray --download: ZERO curl calls (the issue is never fetched)" "$(call_count)" "0"

# ===========================================================================
# workflow <KEY>
# ===========================================================================
section "jira.sh — workflow: human render + available transitions"

reset_curl_stub
set_stub_response 1 '{"transitions":[{"id":"11","to":{"name":"In Progress"}},{"id":"21","to":{"name":"Done"}}]}' 200
set_stub_response 2 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workflow human render -> exit 0" 0
stdout_has "workflow: current status shown" "Open"
stdout_has "workflow: transition target shown" "In Progress"
stdout_has "workflow: second transition target shown" "Done"

section "jira.sh — workflow: --json makes exactly ONE call (no status lookup)"

reset_curl_stub
set_stub_response 1 '{"transitions":[{"id":"11","to":{"name":"In Progress"}}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net --json
expect_rc "workflow --json -> exit 0" 0
stdout_has "workflow --json: raw transitions body" '"to":{"name":"In Progress"}}'
equals "workflow --json: exactly one curl call" "$(call_count)" "1"

section "jira.sh — workflow: zero transitions"

reset_curl_stub
set_stub_response 1 '{"transitions":[]}' 200
set_stub_response 2 '{"fields":{"status":{"name":"Done"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workflow zero transitions -> exit 0" 0
stdout_has "workflow zero transitions: final-state message" "No transitions available"

section "jira.sh — workflow: each transition's id, name, target, screen and accepted resolutions"

# Four shapes a live transitions list mixes: a transition whose NAME differs
# from its TARGET, one with a resolution allow-list, one whose screen takes a
# resolution with no list, and one with no hasScreen at all.
reset_curl_stub
set_stub_response 1 '{"transitions":[{"id":"31","name":"Done","to":{"name":"TBD TO PREPROD"},"hasScreen":false,"fields":{}},{"id":"40","name":"Resolve","to":{"name":"Resolved"},"hasScreen":true,"fields":{"resolution":{"required":true,"allowedValues":[{"name":"Fixed"},{"name":"Won'"'"'t Fix"}]}}},{"id":"41","name":"Close","to":{"name":"Closed"},"hasScreen":true,"fields":{"resolution":{"required":false}}},{"id":"51","name":"Reopen","to":{"name":"Open"}}]}' 200
set_stub_response 2 '{"fields":{"status":{"name":"In Review"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workflow detailed render -> exit 0" 0
argv_log_has_token "workflow: transitions are fetched WITH their screen fields" \
	"https://foo.atlassian.net/rest/api/3/issue/PROJ-1/transitions?expand=transitions.fields"
equals "workflow: the transitions block, one row per transition + a resolution row where the screen takes one" \
	"$(printf '%s\n' "$CUR_OUT" | sed -n '/^Available transitions:$/,$p')" 'Available transitions:
  -> TBD TO PREPROD (id 31, transition "Done", screen: no)
  -> Resolved (id 40, transition "Resolve", screen: yes)
       resolution: Fixed, Won'"'"'t Fix
  -> Closed (id 41, transition "Close", screen: yes)
       resolution: settable
  -> Open (id 51, transition "Reopen", screen: unknown)'

reset_curl_stub
set_stub_response 1 '{"transitions":[{"id":"40","name":"Resolve","to":{"name":"Resolved"},"fields":{"resolution":{"allowedValues":[{"name":"Fixed"}]}}}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net --json
expect_rc "workflow --json with screen fields -> exit 0" 0
equals "workflow --json: the expanded body passes through untouched (allowedValues included)" \
	"$(printf '%s' "$CUR_OUT" | jq -r '.transitions[0].fields.resolution.allowedValues[0].name')" "Fixed"

section "jira.sh — workflow: API text cannot forge an output line (TAB/CR/LF folded, control bytes stripped)"

# Every rendered field is API text. A newline in any of them must stay inside
# its own row: a forged "  -> " row would advertise a transition that does not
# exist, and a forged "resolution:" row a resolution the step cannot take.
reset_curl_stub
set_stub_response 1 '{"transitions":[{"id":"31","name":"Done\n  -> Forged (id 999, transition \"x\", screen: no)","to":{"name":"Closed\r\n       resolution: Forged"},"hasScreen":false,"fields":{"resolution":{"allowedValues":[{"name":"Fixed\nJIRA_TRANSITIONED_TO=Closed"},{"name":"Tab\there"}]}}},{"id":"32","name":"Esc\u001b[31mRed","to":{"name":"Open"}}]}' 200
set_stub_response 2 '{"fields":{"status":{"name":"In Review"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workflow with newline/CR/TAB/ESC-bearing API text -> exit 0" 0
stdout_no_line_starting_with "workflow forgery: no forged transition row" "  -> Forged"
stdout_no_line_starting_with "workflow forgery: no forged resolution row" "       resolution: Forged"
stdout_no_line_starting_with "workflow forgery: no forged machine line" "JIRA_TRANSITIONED_TO="
equals "workflow forgery: every value stays on its own row, folded to spaces" \
	"$(printf '%s\n' "$CUR_OUT" | sed -n '/^Available transitions:$/,$p')" 'Available transitions:
  -> Closed         resolution: Forged (id 31, transition "Done   -> Forged (id 999, transition "x", screen: no)", screen: no)
       resolution: Fixed JIRA_TRANSITIONED_TO=Closed, Tab here
  -> Open (id 32, transition "EscRed", screen: unknown)'

# The multibyte line breaks, in all three rendered values (see the users
# multibyte case for why the byte's absence plus a SPACE in its place is the
# discriminating pair), next to non-ASCII text that must survive intact — each
# value carrying a character whose UTF-8 has a C1-range byte (ß = C3 9F,
# Ü = C3 9C, — = E2 80 94), the bytes a byte-deleting fold would destroy.
reset_curl_stub
set_stub_response 1 "$(jq -n -c \
	--arg name "Clôturer${UNI_NEL}  -> Forged (id 999, transition \"x\", screen: no)" \
	--arg to "Geschloßen${UNI_LS}x" \
	--arg res "Erledigt—Ü${UNI_PS}y" \
	'{transitions:[{id:"31",name:$name,to:{name:$to},hasScreen:true,fields:{resolution:{allowedValues:[{name:$res}]}}}]}')" 200
set_stub_response 2 '{"fields":{"status":{"name":"In Review"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" workflow PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workflow with NEL/U+2028/U+2029 and non-ASCII in API text -> exit 0" 0
stdout_not_has "workflow multibyte: no raw U+0085 (NEL) survives" "$UNI_NEL"
stdout_not_has "workflow multibyte: no raw U+2028 survives" "$UNI_LS"
stdout_not_has "workflow multibyte: no raw U+2029 survives" "$UNI_PS"
equals "workflow multibyte: each break became a SPACE inside its own row; non-ASCII intact" \
	"$(printf '%s\n' "$CUR_OUT" | sed -n '/^Available transitions:$/,$p')" 'Available transitions:
  -> Geschloßen x (id 31, transition "Clôturer   -> Forged (id 999, transition "x", screen: no)", screen: yes)
       resolution: Erledigt—Ü y'

# ===========================================================================
# search
# ===========================================================================
section "jira.sh — search: requires at least one filter"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net
expect_rc "search with no filters and no --jql -> exit 2" 2
stderr_has "search no filters: diagnostic" "requires at least one filter"

section "jira.sh — search: rejects a stray positional argument"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search PROJ-123 --confirmed-site foo.atlassian.net --status Open
expect_rc "search with a stray ticket-key positional -> exit 2" 2
stderr_has "search stray positional: diagnostic" "takes no positional argument"

section "jira.sh — search: builds the /search/jql endpoint with a POST"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-1","fields":{"summary":"a","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ
expect_rc "search basic -> exit 0" 0
file_has "search hits /rest/api/3/search/jql" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
file_has "search uses POST" "$CURL_STUB_ARGV_LOG" "POST"
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search JQL: project clause built correctly" "$JQL_SENT" 'project = "PROJ"'

section "jira.sh — search: defaults the field set when --fields is omitted (live Jira returns id-only otherwise)"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ
expect_rc "search without --fields -> exit 0" 0
SENT_FIELDS=$(jq -c '.fields' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search without --fields: request carries the DEFAULT_SEARCH_FIELDS set, key first" \
	"$SENT_FIELDS" '["key","summary","status","assignee","issuetype"]'

section "jira.sh — search: --fields still overrides the default"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --fields "key,summary,status"
expect_rc "search with explicit --fields -> exit 0" 0
SENT_FIELDS=$(jq -c '.fields' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search with explicit --fields: request carries EXACTLY the caller's list, not the default" \
	"$SENT_FIELDS" '["key","summary","status"]'

section "jira.sh — transport hardening: --proto '=https' present, -L/-k/--insecure absent"

argv_log_has_token "transport: --proto present" "--proto"
argv_log_has_token "transport: --proto value is '=https'" "=https"
argv_log_not_has_token "transport: -L (redirect-follow) absent" "-L"
argv_log_not_has_token "transport: -k (insecure) absent" "-k"
argv_log_not_has_token "transport: --insecure absent" "--insecure"

section "jira.sh — search: JQL escaping — quote+backslash escaped, not a broken-out clause"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --status 'x" OR project=SECRET'
expect_rc "search with injection-shaped --status -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search JQL: the quote is backslash-escaped, clause stays ONE string literal" \
	"$JQL_SENT" 'status = "x\" OR project=SECRET"'
TESTS_RUN=$((TESTS_RUN + 1))
case "$JQL_SENT" in
	*'OR project = "SECRET"'*|*'OR project=SECRET"'*'"'*)
		fail "search JQL: no broken-out OR clause escaped the string" "got: $JQL_SENT" ;;
	*) pass "search JQL: no broken-out OR clause escaped the string" ;;
esac

section "jira.sh — search: JQL escaping parameterized across --type"

# assert_field_escapes FLAG FIELD_NAME — a data-driven check that the SAME
# adversarial value, fed through FLAG, produces an escaped `FIELD_NAME =
# "..."` clause and never a broken-out OR clause. Covers the field-specific
# clause builders individually, not just the shared escape function status
# already exercises above — guards against a future per-field regression
# that bypasses jql_quoted() for one field only. --project is deliberately
# NOT parameterized here (see the dedicated allow-list test right below):
# --project is shape-validated to `^[A-Z][A-Z0-9]+$`
# BEFORE it ever reaches the JQL builder, so this exact adversarial value is
# rejected at that earlier gate and never gets a chance to need escaping —
# a stronger guarantee than escaping (the value can't exist at all), not a
# gap in this test.
assert_field_escapes() {
	flag_name=$1
	field_name=$2
	reset_curl_stub
	set_stub_response 1 '{"issues":[],"isLast":true}' 200
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" search --confirmed-site foo.atlassian.net "$flag_name" 'x" OR project=SECRET'
	expect_rc "search --$flag_name injection-shaped -> exit 0" 0
	sent_jql=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
	equals "search --$flag_name JQL: quote backslash-escaped, ONE string literal" \
		"$sent_jql" "$field_name = \"x\\\" OR project=SECRET\""
}
assert_field_escapes --type type

section "jira.sh — search: --project is shape-validated BEFORE it can reach any sink"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project 'x" OR project=SECRET'
expect_rc "search --project injection-shaped -> exit 1 (rejected before the JQL sink)" 1
stderr_has "search --project injection-shaped: diagnostic" "invalid project key"
equals "search --project injection-shaped: no network call was made" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project '../../etc/passwd'
expect_rc "search --project path-traversal-shaped -> exit 1" 1
stderr_has "search --project path-traversal-shaped: diagnostic" "invalid project key"

section "jira.sh — search: --assignee me uses currentUser() with NO lookup call"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --assignee me
expect_rc "search --assignee me -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
TESTS_RUN=$((TESTS_RUN + 1))
case "$JQL_SENT" in
	*'assignee = currentUser()'*) pass "search --assignee me: JQL uses currentUser()" ;;
	*) fail "search --assignee me: JQL uses currentUser()" "got: $JQL_SENT" ;;
esac
equals "search --assignee me: exactly one curl call (no /myself lookup)" "$(call_count)" "1"

section "jira.sh — search: --assignee @me resolves via GET /myself"

reset_curl_stub
set_stub_response 1 '{"accountId":"acc-self-123"}' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-token-me-flow" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee @me
expect_rc "search --assignee @me -> exit 0" 0
file_has "search --assignee @me: hits /myself first" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/myself"
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search --assignee @me: JQL quotes the resolved accountId" "$JQL_SENT" 'assignee = "acc-self-123"'
# the token must be absent from the ACCUMULATED argv log across
# BOTH calls in this flow (/myself, then /search/jql) — not just checked
# after a single call, since a multi-call flow gives the token two chances
# to leak.
file_not_has "search --assignee @me: token absent across the WHOLE 2-call flow" "$CURL_STUB_ARGV_LOG" "distinctive-token-me-flow"
argv_log_not_has_token "search --assignee @me: -u absent across the whole flow" "-u"
argv_log_not_has_token "search --assignee @me: --user absent across the whole flow" "--user"

section "jira.sh — search: --assignee EMAIL resolves via the stubbed GET /user/search"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-abc-999","emailAddress":"dev@example.com"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=distinctive-token-email-flow" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee dev@example.com
expect_rc "search --assignee EMAIL -> exit 0" 0
file_has "search --assignee EMAIL: hits /user/search" "$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query="
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search --assignee EMAIL: JQL quotes the resolved accountId" "$JQL_SENT" 'assignee = "acc-abc-999"'
file_not_has "search --assignee EMAIL: token absent across the WHOLE 2-call flow" "$CURL_STUB_ARGV_LOG" "distinctive-token-email-flow"
argv_log_not_has_token "search --assignee EMAIL: -u absent across the whole flow" "-u"
argv_log_not_has_token "search --assignee EMAIL: --user absent across the whole flow" "--user"

# regression check: build_jql()'s --assignee path resolves the
# accountId via resolve_account_id() -> jira_curl() -> ensure_workdir(),
# reached from INSIDE `jql=$(build_jql)` — a command-substitution SUBSHELL.
# Before the fix, WORKDIR was created only in that subshell and discarded
# when it exited, so cleanup()'s EXIT trap (running in the MAIN shell, where
# $WORKDIR was still "") never removed it — every such search orphaned a
# jira.work.XXXXXX dir under TMPDIR. Assert none survive this run.
TESTS_RUN=$((TESTS_RUN + 1))
LEAKED_WORKDIRS=$(find "$WORK" -maxdepth 1 -name 'jira.work.*' 2>/dev/null | wc -l | tr -d ' ')
if [ "$LEAKED_WORKDIRS" -eq 0 ]; then
	pass "search --assignee EMAIL: no jira.work.* dir survives (fix confirmed)"
else
	fail "search --assignee EMAIL: no jira.work.* dir survives (fix confirmed)" \
		"found $LEAKED_WORKDIRS leaked dir(s) under $WORK"
fi

section "jira.sh — search: --assignee adversarial value never reaches the JQL — only the resolved accountId does"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-safe-000"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee 'x" OR project=SECRET'
expect_rc "search --assignee injection-shaped -> exit 0" 0
# --assignee's raw text never reaches jql_quoted() directly: it is first
# consumed as a /user/search QUERY PARAMETER (urlencoded by urlencode()),
# and only the RESOLVED accountId is ever quoted into the JQL. So the
# equivalent safety property here is stronger than escaping: the injected
# text must be entirely ABSENT from both the request URL and the final JQL.
file_not_has "search --assignee injection-shaped: raw value absent from the /user/search URL" \
	"$CURL_STUB_ARGV_LOG" 'x" OR project=SECRET'
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search --assignee injection-shaped: JQL contains ONLY the resolved accountId" \
	"$JQL_SENT" 'assignee = "acc-safe-000"'

# ---------------------------------------------------------------------------
# resolve_account_id: a MULTI-match /user/search must not be resolved by
# position. The endpoint is a FUZZY, UNORDERED substring search, so taking
# .[0] picked a principal by coin flip — and every caller of this one resolver
# (search --assignee, watch --account, create/update --assignee/--developer/
# --reviewer) inherited that. These cases are asserted on `search --assignee`
# because it is the cheapest caller to drive: one resolve, then one POST that
# must NOT happen when the resolve fails.
# ---------------------------------------------------------------------------
section "jira.sh — resolve_account_id: 2+ fuzzy matches with NO exact match fails loud, before any query"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-sam-1","emailAddress":"sam@example.com","displayName":"Sam Okafor"},{"accountId":"acc-sam-2","emailAddress":"samantha@example.com","displayName":"Samantha Ruiz"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee sam
expect_rc "resolve ambiguous --assignee -> exit 1" 1
stderr_has "resolve ambiguous: diagnostic names the match COUNT" "2 Jira users matched 'sam'"
stderr_has "resolve ambiguous: diagnostic says what to do instead" "full email address"
# PII: EVERY matched user is a third party who never sees this stream, so both
# candidates are asserted absent, not just one. Naming a single candidate leaves
# a leak of the other invisible — and the diagnostic is built from ONE fixture,
# so a regression that starts rendering the match set would emit both at once.
# Neither value is derivable from the caller's own input here ('sam'), which is
# what makes both assertions non-vacuous.
stderr_not_has "resolve ambiguous: does NOT leak candidate #2's email" "samantha@example.com"
stderr_not_has "resolve ambiguous: does NOT leak candidate #2's display name" "Samantha Ruiz"
stderr_not_has "resolve ambiguous: does NOT leak candidate #1's email" "sam@example.com"
stderr_not_has "resolve ambiguous: does NOT leak candidate #1's display name" "Sam Okafor"
equals "resolve ambiguous: only the resolve fired, the search POST never ran" "$(call_count)" "1"

section "jira.sh — resolve_account_id: 2+ matches resolve when exactly ONE matches the value EXACTLY (case-insensitively)"

# The exact match is deliberately the SECOND result, so a pass cannot be the old
# .[0] behaviour agreeing by luck.
reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-sam-2","emailAddress":"samantha@example.com","displayName":"Samantha Ruiz"},{"accountId":"acc-sam-1","emailAddress":"sam@example.com","displayName":"Sam Okafor"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee SAM@EXAMPLE.COM
expect_rc "resolve exact-email-among-many -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "resolve exact-email-among-many: picks the EXACT match, not the first result" \
	"$JQL_SENT" 'assignee = "acc-sam-1"'

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-sam-2","emailAddress":"samantha@example.com","displayName":"Samantha Ruiz"},{"accountId":"acc-sam-1","emailAddress":"sam@example.com","displayName":"Sam Okafor"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee 'sam okafor'
expect_rc "resolve exact-displayName-among-many -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "resolve exact-displayName-among-many: displayName counts as an exact match too" \
	"$JQL_SENT" 'assignee = "acc-sam-1"'

section "jira.sh — resolve_account_id: TWO exact matches is still ambiguous (exactly one, not at least one)"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-dup-1","emailAddress":"dup@example.com","displayName":"First Dup"},{"accountId":"acc-dup-2","emailAddress":"other@example.com","displayName":"dup@example.com"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee dup@example.com
expect_rc "resolve two-exact-matches -> exit 1" 1
stderr_has "resolve two-exact-matches: refuses rather than picking one" "2 Jira users matched 'dup@example.com'"
# The PII floor holds on THIS refusal arm too, and it is a different code path
# from the no-exact-match one above (the exactly-one filter emitted nothing, not
# the zero-match branch). Asserted on the two values NOT derivable from the
# caller's own input: acc-dup-2's email and acc-dup-1's display name. acc-dup-2's
# displayName is deliberately the caller's own typed value, so it cannot be
# asserted absent without the assertion being about the input rather than a leak.
stderr_not_has "resolve two-exact-matches: does NOT leak the second match's email" "other@example.com"
stderr_not_has "resolve two-exact-matches: does NOT leak the first match's display name" "First Dup"
equals "resolve two-exact-matches: the search POST never ran" "$(call_count)" "1"

section "jira.sh — resolve_account_id: a SINGLE fuzzy match still resolves (the common case is unchanged)"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-only-1","emailAddress":"only@example.com","displayName":"Only Match"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee onl
expect_rc "resolve single fuzzy match -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "resolve single fuzzy match: a lone result needs no exact match" "$JQL_SENT" 'assignee = "acc-only-1"'

# ---------------------------------------------------------------------------
# resolve_account_id: the SATURATION boundary, both directions. The resolver
# REQUESTS maxResults=USER_SEARCH_MAX_RESULTS+1 (51) and refuses only when MORE
# than the cap comes back — the +1 is what separates "the whole set arrived and
# happens to be exactly 50" from "the set is truncated at 50 and a rival match
# may sit one row past it". Requesting exactly 50 would make those two byte-
# identical and refuse a genuinely unique email whenever the site held exactly 50
# fuzzy matches for it, which is the off-by-one these two cases pin.
#
# The fixtures are generated with `jq range` rather than hand-written, the same
# idiom the bulk paging fixtures below use: 51 literal user objects would bury the
# ONE element that carries the claim.
# ---------------------------------------------------------------------------
section "jira.sh — resolve_account_id: a COMPLETE page of exactly USER_SEARCH_MAX_RESULTS (50) still resolves"

RESOLVE_CAP_EMAIL="target@example.com"
# 49 fuzzy fillers + the exact match LAST, so a pass cannot be a `.[0]` regression
# agreeing by luck — the same arrangement the exact-match-among-many cases above use.
RESOLVE_CAP_PAGE=$(jq -nc --arg exact "$RESOLVE_CAP_EMAIL" \
	'[range(0;49) | {accountId:"acc-filler-\(.)", emailAddress:"filler\(.)@example.com", displayName:"Filler \(.)"}]
	 + [{accountId:"acc-exact-at-cap", emailAddress:$exact, displayName:"Exact Target"}]')
# The fixture's own size IS the boundary under test, so it is asserted rather than
# assumed: an off-by-one in the `range` above would silently move this case to 49
# and it would pass for a reason that proves nothing about the cap.
equals "resolve at-cap fixture: the stubbed page really holds exactly 50 users" \
	"$(printf '%s' "$RESOLVE_CAP_PAGE" | jq 'length')" "50"

reset_curl_stub
set_stub_response 1 "$RESOLVE_CAP_PAGE" 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee "$RESOLVE_CAP_EMAIL"
expect_rc "resolve at-cap (50 results, one exact) -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "resolve at-cap: a full-but-COMPLETE page is not a refusal — the exact match resolves" \
	"$JQL_SENT" 'assignee = "acc-exact-at-cap"'

section "jira.sh — resolve_account_id: one result PAST the cap (51) refuses — the set is not exhaustive"

# The same page plus one more filler: 51 back proves the true set is at least 51,
# so no unique match can be established from what arrived.
RESOLVE_OVER_CAP_PAGE=$(printf '%s' "$RESOLVE_CAP_PAGE" \
	| jq -c '. + [{accountId:"acc-filler-49", emailAddress:"filler49@example.com", displayName:"Filler 49"}]')
equals "resolve over-cap fixture: the stubbed page really holds exactly 51 users" \
	"$(printf '%s' "$RESOLVE_OVER_CAP_PAGE" | jq 'length')" "51"

reset_curl_stub
# A COUNTERFACTUAL search response, the same technique the bulk pre-resolve case
# below uses: with it queued, a regression that resolved the saturated set anyway
# would exit 0 here rather than dying on the stub's own missing-response error — so
# exit 1 can only mean the saturation guard refused it.
set_stub_response 1 "$RESOLVE_OVER_CAP_PAGE" 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee "$RESOLVE_CAP_EMAIL"
expect_rc "resolve over-cap (51 results) -> exit 1" 1
stderr_has "resolve over-cap: diagnostic names the cap that was exceeded and the caller's value" \
	"/user/search returned more than 50 results for 'target@example.com'"
stderr_has "resolve over-cap: diagnostic names the INCOMPLETENESS as the reason, not ambiguity" \
	"the match set is not exhaustive"
# The PII floor the two ambiguity refusal arms above assert holds on this third
# arm too, and it is its own code path: a regression that started rendering the
# match set would leak 51 third parties at once. filler0@example.com is not
# derivable from the caller's own input, which is what makes this non-vacuous.
stderr_not_has "resolve over-cap: does NOT leak a matched third party's email" "filler0@example.com"
equals "resolve over-cap: only the resolve fired, the search POST never ran" "$(call_count)" "1"
# The REQUEST side of the same off-by-one: the guard refuses at >50, so the URL
# must ask for 51 — asking for 50 would make this refusal fire on complete sets.
file_has "resolve over-cap: the request asked for CAP+1 rows, not CAP" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query=target%40example.com&maxResults=51"

# ---------------------------------------------------------------------------
# resolve_account_id: the two MALFORMED-SHAPE arms. /user/search is documented to
# answer with a bare array of user objects, and both guards below exist for the
# case where it does not. What they buy is the SCRIPT'S OWN exit contract: this
# engine documents 0/1/2, and an unguarded jq type error escapes with jq's own
# status 5, which no caller of jira.sh is written to interpret. So the claim each
# case makes is not merely "it fails" — it is "it fails with the documented code
# and the documented diagnostic".
# ---------------------------------------------------------------------------
section "jira.sh — resolve_account_id: a NON-ARRAY response body counts as ZERO matches, not a jq type error"

# A PAGINATED-WRAPPER body: the plausible wrong shape (Jira's own newer endpoints
# answer {values:[…],total:N}), and one that carries a real accountId, so a
# regression that unwrapped it would resolve a principal the caller never named.
#
# WHY NOT A BARE `{}`, the obvious non-array. `{} | length` is 0, so a guard-less
# `jq 'length'` would read zero for it and land in the SAME no-user-found branch —
# the fixture would pass whether the guard existed or not. A 2-key object reads 2
# without the guard and 0 with it, which is what makes this case discriminating.
RESOLVE_NONARRAY_BODY='{"values":[{"accountId":"acc-wrapped-000","emailAddress":"ghost@example.com","displayName":"Ghost User"}],"total":1}'
equals "resolve non-array fixture: really is a JSON object, not an array" \
	"$(printf '%s' "$RESOLVE_NONARRAY_BODY" | jq -r 'type')" "object"
equals "resolve non-array fixture: carries 2 keys, so a guard-less length would NOT coincidentally read zero" \
	"$(printf '%s' "$RESOLVE_NONARRAY_BODY" | jq 'length')" "2"

reset_curl_stub
# A COUNTERFACTUAL search response, the same technique the over-cap case above
# uses: with it queued, a regression that resolved this body anyway would exit 0
# here rather than dying on the stub's own missing-response error — so exit 1 can
# only mean the shape guard refused it.
set_stub_response 1 "$RESOLVE_NONARRAY_BODY" 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee ghost@example.com
expect_rc "resolve non-array body -> exit 1 (this engine's documented code, not jq's own 5)" 1
stderr_has "resolve non-array body: the STANDARD no-user-found diagnostic, naming the caller's value" \
	"no Jira user found for 'ghost@example.com'"
# The ambiguity arm's diagnostic asserted ABSENT: dropping the type test sends this
# body to the 2-match branch instead, which also exits 1 — so the rc alone cannot
# tell the two apart, and only this line proves WHICH guard fired.
stderr_not_has "resolve non-array body: did NOT fall through to the ambiguity arm" \
	"Jira users matched"
equals "resolve non-array body: only the resolve fired, the search POST never ran" "$(call_count)" "1"
file_not_has "resolve non-array body: the wrapped accountId was never unwrapped onto the wire" \
	"$CURL_STUB_ARGV_LOG" "acc-wrapped-000"

section "jira.sh — resolve_account_id: a NON-OBJECT element inside the match array is filtered out, not indexed into"

reset_curl_stub
# A bare string and a number mixed in beside ONE real user object. `| objects`
# drops both before .emailAddress/.displayName are read; without it, jq indexes a
# string and dies with its own status, outside this engine's 0/1/2 contract.
#
# The real match sits LAST, the same arrangement the exact-match-among-many cases
# above use, so a pass cannot be a `.[0]` regression agreeing by luck.
set_stub_response 1 '["not-an-object",42,{"accountId":"acc-real-mixed","emailAddress":"real@example.com","displayName":"Real Person"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee real@example.com
expect_rc "resolve mixed-element array -> exit 0" 0
equals "resolve mixed-element array: BOTH calls ran (the resolve completed, then the search)" "$(call_count)" "2"
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
# The 3-element set puts this on the AMBIGUITY branch (count > 1), so resolving at
# all means the two non-objects were filtered out rather than counted as rivals —
# a miscount there would have refused this exact-match value instead.
equals "resolve mixed-element array: the one real object's accountId reaches the wire" \
	"$JQL_SENT" 'assignee = "acc-real-mixed"'

section "jira.sh — resolve_account_id: a LONE non-object element degrades to no-user-found, not a jq type error"

# The SINGLE-match arm's own `| objects` guard, which the mixed-element case above
# cannot reach: three elements put that one on the ambiguity branch, so the guard
# it exercises is the `[ .[] | objects | select(...) ]` filter. A ONE-element array
# routes to `(.[0] | objects | .accountId) // empty` instead — a separate filter in
# a separate arm, and the only arm a lone malformed element can reach.
#
# What the guard buys is the SAME exit-contract claim the two malformed-shape cases
# above make: without it, `.[0].accountId` indexes a bare string and jq dies with
# its own status (5) through jira.sh's `set -e`, OUTSIDE this engine's documented
# 0/1/2. With it, the element is filtered out, `// empty` yields nothing, and the
# arm falls into the STANDARD no-user-found refusal.
RESOLVE_LONE_NONOBJECT_BODY='["not-an-object"]'
equals "resolve lone non-object fixture: really is a ONE-element array (the single-match arm, not the ambiguity one)" \
	"$(printf '%s' "$RESOLVE_LONE_NONOBJECT_BODY" | jq 'length')" "1"
equals "resolve lone non-object fixture: that one element really is a non-object" \
	"$(printf '%s' "$RESOLVE_LONE_NONOBJECT_BODY" | jq -r '.[0] | type')" "string"

reset_curl_stub
# A COUNTERFACTUAL search response, the same technique the over-cap and non-array
# cases above use: with it queued, a regression that resolved this body anyway would
# exit 0 rather than dying on the stub's own missing-response error.
set_stub_response 1 "$RESOLVE_LONE_NONOBJECT_BODY" 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee lone@example.com
expect_rc "resolve lone non-object -> exit 1 (this engine's documented code, not jq's own 5)" 1
stderr_has "resolve lone non-object: the STANDARD no-user-found diagnostic, naming the caller's value" \
	"no Jira user found for 'lone@example.com'"
# jq's OWN type error asserted ABSENT — the half that makes this non-vacuous. The rc
# alone cannot see the guard: dropping `| objects` leaves jq indexing a string, which
# also fails, just with status 5 and this text on stderr instead.
stderr_not_has "resolve lone non-object: jq never indexed the string (no type error escaped)" \
	"Cannot index string"
equals "resolve lone non-object: only the resolve fired, the search POST never ran" "$(call_count)" "1"

section "jira.sh — search: --labels builds an OR'd clause, each value escaped"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --labels 'a,b'
expect_rc "search --labels a,b -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --labels: builds the OR'd clause, AND'd with project" \
	"$JQL_SENT" 'project = "PROJ" AND (labels = "a" OR labels = "b")'

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --labels 'x" OR project=SECRET'
expect_rc "search --labels injection-shaped -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --labels injection-shaped: quote backslash-escaped inside the OR'd clause" \
	"$JQL_SENT" '(labels = "x\" OR project=SECRET")'

section "jira.sh — search: --assignee EMAIL with no matching user fails closed"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee nobody@example.com
expect_rc "search --assignee no match -> exit 1" 1
stderr_has "search --assignee no match: diagnostic" "no Jira user found"

section "jira.sh — search: --type resolves through the project config's type_aliases"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/projects" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --type subtask
expect_rc "search --type alias -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
TESTS_RUN=$((TESTS_RUN + 1))
case "$JQL_SENT" in
	*'type = "Sub-task"'*) pass "search --type: alias resolved to the config's canonical type" ;;
	*) fail "search --type: alias resolved to the config's canonical type" "got: $JQL_SENT" ;;
esac

section "jira.sh — search: raw --jql passthrough overrides other filters"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --status Open --jql 'assignee = currentUser() ORDER BY created DESC'
expect_rc "search --jql passthrough -> exit 0" 0
JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --jql: raw string used verbatim, other filters ignored" \
	"$JQL_SENT" 'assignee = currentUser() ORDER BY created DESC'

section "jira.sh — search: pagination via nextPageToken (NOT startAt)"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"P-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"P-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":false,"nextPageToken":"tok-page-2"}' 200
set_stub_response 2 '{"issues":[{"key":"P-3","fields":{"summary":"c","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 2 --limit 10 --json
expect_rc "search pagination -> exit 0" 0
equals "search pagination: TWO pages fetched" "$(call_count)" "2"
PAGE2_TOKEN=$(jq -r '.nextPageToken' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "search pagination: page 2 request carries the token from page 1" "$PAGE2_TOKEN" "tok-page-2"
TOTAL_ISSUES=$(printf '%s' "$CUR_OUT" | jq '.issues | length')
equals "search pagination: all 3 issues across both pages are merged" "$TOTAL_ISSUES" "3"

section "jira.sh — search: --limit bounds the total fetched (no unbounded reads)"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"P-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"P-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":false,"nextPageToken":"tok-2"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 2 --limit 2 --json
expect_rc "search --limit stops after the cap -> exit 0" 0
equals "search --limit: only ONE page fetched even though isLast=false" "$(call_count)" "1"

section "jira.sh — search: --limit/--page-size validation"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --limit abc
expect_rc "search --limit abc (non-numeric) -> exit 2" 2
stderr_has "search --limit abc: diagnostic" "must be a positive integer"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 0
expect_rc "search --page-size 0 -> exit 2" 2
stderr_has "search --page-size 0: diagnostic" "must be a positive integer"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
# --limit must be >= the clamped ceiling (100) here, or the per-page size
# would be bounded by the (lower) --limit/remaining-count math instead of
# by the --page-size clamp this test means to isolate.
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ --page-size 500 --limit 200
expect_rc "search --page-size 500 (over the ceiling) -> exit 0" 0
stderr_has "search --page-size 500: warns about the 100 ceiling" "capped at Jira's own 100-per-request ceiling"
SENT_MAX_RESULTS=$(jq -r '.maxResults' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "search --page-size 500: request body maxResults clamped to 100" "$SENT_MAX_RESULTS" "100"

section "jira.sh — search: non-2xx fails with Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["The JQL you have entered is not valid"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --jql 'bogus jql ((('
expect_rc "search 400 -> exit 1" 1
stderr_has "search 400: Jira's own error message surfaced" "is not valid"

section "jira.sh — search: human render strips control/ANSI"

reset_curl_stub
ESC=$(printf '\033')
DIRTY='Bad summary'"${ESC}"'[1mBOLD'"${ESC}"'[0m'
set_stub_response 1 "$(jq -n -c --arg s "$DIRTY" '{issues:[{key:"P-1",fields:{summary:$s,status:{name:"Open"}}}],isLast:true}')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ
expect_rc "search human render -> exit 0" 0
stdout_not_has "search render: ANSI stripped" "${ESC}["
stdout_has "search render: underlying text survives" "BOLD"

# ===========================================================================
# link-types — GET /rest/api/3/issueLinkType
# ===========================================================================
section "jira.sh — link-types: --json passthrough + human render"

reset_curl_stub
set_stub_response 1 '{"issueLinkTypes":[{"id":"10000","name":"Blocks","inward":"is blocked by","outward":"blocks"},{"id":"10001","name":"Relates","inward":"relates to","outward":"relates to"}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types --confirmed-site foo.atlassian.net --json
expect_rc "link-types --json -> exit 0" 0
LT_JSON_FIRST_NAME=$(printf '%s' "$CUR_OUT" | jq -r '.issueLinkTypes[0].name')
equals "link-types --json: raw body on stdout parses as JSON" "$LT_JSON_FIRST_NAME" "Blocks"
file_has "link-types: hits GET /rest/api/3/issueLinkType" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issueLinkType"

reset_curl_stub
set_stub_response 1 '{"issueLinkTypes":[{"id":"10000","name":"Blocks","inward":"is blocked by","outward":"blocks"}]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types --confirmed-site foo.atlassian.net
expect_rc "link-types human render -> exit 0" 0
stdout_has "link-types human: name shown" "Blocks"
stdout_has "link-types human: outward wording shown" "blocks"
stdout_has "link-types human: inward wording shown" "is blocked by"

section "jira.sh — link-types: takes no positional argument"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "link-types with a stray positional -> exit 2" 2
stderr_has "link-types stray positional: diagnostic" "takes no positional argument"

section "jira.sh — link-types: non-2xx fails with Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Not authorized"]}' 401
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" link-types --confirmed-site foo.atlassian.net
expect_rc "link-types 401 -> exit 1" 1
stderr_has "link-types 401: Jira's own error message surfaced" "Not authorized"

# ===========================================================================
# users --query STR — GET /rest/api/3/user/search, one row per match (READ)
# ===========================================================================

# QUERY_SCOPE_DIAG — the refusal of --query anywhere but `users`. The
# `error: ` prefix is load-bearing for the reason PRIORITY_SCOPE_DIAG's note
# gives.
QUERY_SCOPE_DIAG="error: --query is only valid with users"

# users_page_caveat LIMIT -> the note every NON-EMPTY users render ends with.
# /user/search filters its page AFTER fetching it, so no page length — full or
# short — proves the match set is exhausted; LIMIT is the page size that was
# asked for, which is how a test sees --limit reach the text.
users_page_caveat() {
	printf '(one page of at most %s rows: /user/search filters its page after fetching, so fewer rows than that do not prove there are no more matches — narrow --query to be sure)' "$1"
}

section "jira.sh — users: one row per match, the query urlencoded, the default page size"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-ann","displayName":"Ann Lee","active":true,"accountType":"atlassian"},{"accountId":"acc-bot","displayName":"Deploy Bot","active":false,"accountType":"app"},{"accountId":"acc-old","displayName":"Old User"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query "ann & co" --confirmed-site foo.atlassian.net
expect_rc "users --query -> exit 0" 0
argv_log_has_token "users: GET /user/search with the query urlencoded and the resolver's page size (50)" \
	"https://foo.atlassian.net/rest/api/3/user/search?query=ann%20%26%20co&maxResults=50"
argv_log_has_token "users: the request is a GET" "GET"
equals "users: the rendered list — count header, one row per user, active/type 'unknown' when absent, the page caveat" \
	"$CUR_OUT" "3 user(s):

  acc-ann  Ann Lee  (active: true, type: atlassian)
  acc-bot  Deploy Bot  (active: false, type: app)
  acc-old  Old User  (active: unknown, type: unknown)

$(users_page_caveat 50)"

section "jira.sh — users: --limit sets maxResults, and EVERY non-empty page — full or short — carries the one-page caveat"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-1","displayName":"One","active":true,"accountType":"atlassian"},{"accountId":"acc-2","displayName":"Two","active":true,"accountType":"atlassian"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query a --limit 2 --confirmed-site foo.atlassian.net
expect_rc "users --limit 2 with a full page -> exit 0" 0
argv_log_has_token "users --limit: maxResults=2 on the wire" \
	"https://foo.atlassian.net/rest/api/3/user/search?query=a&maxResults=2"
stdout_has "users --limit: a full page is disclosed as possibly partial, sized by --limit" \
	"$(users_page_caveat 2)"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-1","displayName":"One","active":true,"accountType":"atlassian"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query a --limit 2 --confirmed-site foo.atlassian.net
expect_rc "users --limit 2 with a short page -> exit 0" 0
stdout_has "users --limit: a SHORT page carries the caveat too (Jira filters after fetching, so short proves nothing)" \
	"$(users_page_caveat 2)"

section "jira.sh — users: no match is an answer (exit 0), not an error"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query nobody-here --confirmed-site foo.atlassian.net
expect_rc "users with zero matches -> exit 0" 0
equals "users zero matches: says so, naming the query — and nothing else (no page caveat)" "$CUR_OUT" "No users found for query: nobody-here"

# The query is the CALLER's text, echoed back: a U+009B (8-bit CSI) and a NEL in
# it fold to spaces, and its non-ASCII characters (ß = C3 9F, — = E2 80 94,
# Ü = C3 9C) survive intact rather than losing their C1-range bytes.
reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query "Jürgen Straße—Ünal${C1_CSI}31m${UNI_NEL}X" --confirmed-site foo.atlassian.net
expect_rc "users zero matches for a C1-bearing query -> exit 0" 0
equals "users zero matches C1: the echoed query folded, non-ASCII intact" \
	"$CUR_OUT" "No users found for query: Jürgen Straße—Ünal 31m X"

section "jira.sh — users --json: the raw response passes through"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-ann","displayName":"Ann Lee","emailAddress":"ann@example.com"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query ann --json --confirmed-site foo.atlassian.net
expect_rc "users --json -> exit 0" 0
equals "users --json: the body, untouched (fields the human render drops included)" \
	"$(printf '%s' "$CUR_OUT" | jq -c .)" '[{"accountId":"acc-ann","displayName":"Ann Lee","emailAddress":"ann@example.com"}]'

section "jira.sh — users: a non-array body and a non-2xx both fail loud"

reset_curl_stub
set_stub_response 1 '{"errorMessages":[],"values":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query ann --confirmed-site foo.atlassian.net
expect_rc "users with a 200 whose body is not an array -> exit 1" 1
stderr_has "users non-array: diagnostic" "search users failed: expected a JSON array of users"
stdout_not_has "users non-array: nothing rendered as if it were a user list" "user(s)"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["The query parameter is too long."]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query ann --confirmed-site foo.atlassian.net
expect_rc "users 400 -> exit 1" 1
stderr_has "users 400: Jira's own error message surfaced" "The query parameter is too long."

section "jira.sh — users: a display name cannot forge an output line"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-x","displayName":"Mallory\n  acc-admin  Site Admin  (active: true, type: atlassian)\u001b[2K","active":true,"accountType":"atlassian"},{"accountId":"acc-t\tab","displayName":"Tab","active":true,"accountType":"atlassian"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query m --confirmed-site foo.atlassian.net
expect_rc "users with a newline/ESC-bearing display name -> exit 0" 0
stdout_no_line_starting_with "users forgery: no forged user row" "  acc-admin"
equals "users forgery: each user stays on ONE row, TAB/LF folded to a space, ESC sequence stripped" \
	"$CUR_OUT" "2 user(s):

  acc-x  Mallory   acc-admin  Site Admin  (active: true, type: atlassian)  (active: true, type: atlassian)
  acc-t ab  Tab  (active: true, type: atlassian)

$(users_page_caveat 50)"

# The MULTIBYTE line breaks — NEL (U+0085), LINE SEPARATOR (U+2028), PARAGRAPH
# SEPARATOR (U+2029) — which `read`/`grep` do not split on, so a column-0
# assertion could not fail here (see the write suite's comment-edit MULTIBYTE
# section for the full argument). What discriminates: the raw bytes are gone,
# and a SPACE stands where each was. The same row carries non-ASCII text whose
# UTF-8 includes bytes in the C1 range (ß = C3 9F, Ü = C3 9C, — = E2 80 94): a
# fold that deleted those BYTES instead of the three CODEPOINTS would mangle it.
reset_curl_stub
set_stub_response 1 "$(jq -n -c --arg n "Zoë Straße—Ürsula${UNI_NEL}  acc-admin  Site Admin${UNI_LS}x${UNI_PS}y" \
	'[{accountId:"acc-z",displayName:$n,active:true,accountType:"atlassian"}]')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query z --confirmed-site foo.atlassian.net
expect_rc "users with NEL/U+2028/U+2029 and non-ASCII in a display name -> exit 0" 0
stdout_not_has "users multibyte: no raw U+0085 (NEL) survives" "$UNI_NEL"
stdout_not_has "users multibyte: no raw U+2028 survives" "$UNI_LS"
stdout_not_has "users multibyte: no raw U+2029 survives" "$UNI_PS"
equals "users multibyte: each break became a SPACE on the user's own row; the non-ASCII name is intact" \
	"$CUR_OUT" "1 user(s):

  acc-z  Zoë Straße—Ürsula   acc-admin  Site Admin x y  (active: true, type: atlassian)

$(users_page_caveat 50)"

section "jira.sh — users: usage errors (exit 2, ZERO calls) and --query's single owner"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --confirmed-site foo.atlassian.net
expect_rc "users without --query -> exit 2" 2
stderr_has "users without --query: diagnostic" "users requires --query STR"
equals "users without --query: ZERO calls" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users ann --query ann --confirmed-site foo.atlassian.net
expect_rc "users with a stray positional -> exit 2" 2
stderr_has "users stray positional: diagnostic points at --query" "users takes no positional argument, got: ann (use --query)"
equals "users stray positional: ZERO calls" "$(call_count)" "0"

# search is the case the guard exists for: `search --project P --query X`
# would otherwise run the project search with X silently ignored.
reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --project PROJ --query ann --confirmed-site foo.atlassian.net
expect_rc "search + --query -> exit 2" 2
stderr_has "search + --query: the scoping diagnostic fired" "$QUERY_SCOPE_DIAG"
equals "search + --query: ZERO calls (the search never ran)" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --query ann --confirmed-site foo.atlassian.net
expect_rc "view + --query -> exit 2" 2
stderr_has "view + --query: the scoping diagnostic fired" "$QUERY_SCOPE_DIAG"
equals "view + --query: ZERO calls" "$(call_count)" "0"

section "jira.sh — users: a READ, so it runs under \$JIRA_READ_ONLY"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-ann","displayName":"Ann Lee","active":true,"accountType":"atlassian"}]' 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" users --query ann --confirmed-site foo.atlassian.net
expect_rc "read-only users -> exit 0" 0
# shellcheck disable=SC2016  # single-quoted on purpose: the needle is the gate's own literal message, which spells the variable NAME — expanding it here would search for the VALUE
stderr_not_has "read-only users: the gate did not refuse it" '$JIRA_READ_ONLY is set: refusing'
stdout_has "read-only users: the user is rendered" "acc-ann  Ann Lee"


# ===========================================================================
# children <KEY> — reuses the search engine with a `parent = "KEY"` JQL
# ===========================================================================
section "jira.sh — children: builds parent = \"KEY\" and drives the search engine"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-2","fields":{"summary":"child one","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "children basic -> exit 0" 0
file_has "children hits /rest/api/3/search/jql (the SAME search endpoint)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
CHILDREN_JQL_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "children: JQL is parent = \"KEY\"" "$CHILDREN_JQL_SENT" 'parent = "PROJ-1"'
stdout_has "children human render: child ticket shown" "PROJ-2"

section "jira.sh — children: respects --fields/--limit/--page-size like search"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children PROJ-1 --confirmed-site foo.atlassian.net --fields "key,summary" --json
expect_rc "children --fields --json -> exit 0" 0
CHILDREN_FIELDS_SENT=$(jq -c '.fields' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "children --fields: request carries the caller's explicit field list" \
	"$CHILDREN_FIELDS_SENT" '["key","summary"]'

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children PROJ-1 --confirmed-site foo.atlassian.net --page-size 5 --json
expect_rc "children --page-size -> exit 0" 0
CHILDREN_MAX_RESULTS_SENT=$(jq -r '.maxResults' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "children --page-size: request body maxResults honors the caller's --page-size" \
	"$CHILDREN_MAX_RESULTS_SENT" "5"

section "jira.sh — children: the ticket key is escaped through the SAME JQL-sink control"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children 'not-a-key' --confirmed-site foo.atlassian.net
expect_rc "children invalid key -> exit 2 (rejected before it can reach the JQL sink)" 2
stderr_has "children invalid key: diagnostic" "invalid ticket key"

section "jira.sh — children: requires a ticket key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children --confirmed-site foo.atlassian.net
expect_rc "children without a ticket key -> exit 2" 2
stderr_has "children without ticket key: diagnostic" "requires a ticket key"

# ===========================================================================
# discover <PROJECT> — introspect createmeta + /field, emit the consumed config
# ===========================================================================

# An injection-shaped custom field name authored (in this stub) by "another
# Jira user": contains a command substitution, a backtick, and a double quote.
# It must round-trip completely INERT into the config (a literal JSON key), and
# must never be executed by any layer of discover's jq pipeline (the
# WRITE-COMMAND security note: every value enters jq only via --slurpfile).
# shellcheck disable=SC2016  # the $()/backtick are the injection FIXTURE — they must stay literal, never expand
INJ_NAME='inj$(touch pwned)`whoami`"end'

# queue_discover_responses — the SEVEN canned responses for one full discover
# walk, on the REAL createmeta shapes (captured from live Jira): issuetypes and
# per-type fields are OFFSET-paginated beans whose page array lives under
# `issueTypes` / `fields` respectively (NOT `.values`), carry `startAt` /
# `maxResults` / `total`, and have NO `isLast`. Call order: issuetypes page 1
# (startAt 0, total 3) + page 2 (startAt 2, the subtask type) — a page-1-only
# bug would MISS `Subtask`; then per-type create-screen fields — type 10001
# across TWO pages (total 3; a page-1-only bug MISSES `Acceptance Criteria`),
# types 10002 (the injection field + the OR-arm field) and 10003 one page each
# — then the global /field catalog (a plain array, authoritative names).
# Defined once because every discover --write scenario reuses it.
# Custom-detection OR-arm coverage: type-10002 carries customfield_20001 WITH a
# customfield_ id but NO schema.custom (exercises the OR-arm of the
# custom-detection predicate). The `assignee` field (schema.type user,
# non-custom) also proves non-custom exclusion.
# discover_field_catalog_json NAME_FOR_10016 -> the global /field catalog body
# (call 7), with customfield_10016's authoritative display NAME supplied by the
# caller. It is a parameter for exactly one case: the semantic-key collision
# section renames that field to the literal "reviewer" so discovery and curation
# collide on the SAME custom_fields key, which is the only way to tell the
# narrowed curated-wins rule from the blanket one. Every other caller passes the
# project's real "Story Points".
# shellcheck disable=SC2016  # $sp/$inj are read by jq via --arg; they must not shell-expand
discover_field_catalog_json() {
	jq -n -c --arg sp "$1" --arg inj "$INJ_NAME" '[{id:"customfield_10016",key:"customfield_10016",name:$sp,custom:true,schema:{type:"number"}},{id:"customfield_16102",key:"customfield_16102",name:"Acceptance Criteria",custom:true},{id:"customfield_20001",key:"customfield_20001",name:"Sprint",custom:true},{id:"customfield_99999",key:"customfield_99999",name:$inj,custom:true},{id:"summary",key:"summary",name:"Summary",custom:false},{id:"assignee",key:"assignee",name:"Assignee",custom:false}]'
}

# shellcheck disable=SC2016  # $inj holds the injection FIXTURE; jq reads it via --arg, it must not shell-expand
queue_discover_responses() {
	set_stub_response 1 '{"issueTypes":[{"id":"10001","name":"Task","subtask":false,"hierarchyLevel":0},{"id":"10002","name":"Story","subtask":false,"hierarchyLevel":0}],"startAt":0,"maxResults":50,"total":3}' 200
	set_stub_response 2 '{"issueTypes":[{"id":"10003","name":"Subtask","subtask":true,"hierarchyLevel":-1}],"startAt":2,"maxResults":50,"total":3}' 200
	set_stub_response 3 '{"fields":[{"fieldId":"assignee","name":"Assignee","required":false,"schema":{"type":"user"}},{"fieldId":"customfield_10016","name":"Story Points (createmeta)","required":false,"schema":{"type":"number","custom":"com.x","customId":10016}}],"startAt":0,"maxResults":50,"total":3}' 200
	set_stub_response 4 '{"fields":[{"fieldId":"customfield_16102","name":"Acceptance Criteria","required":false,"schema":{"type":"string","custom":"com.y","customId":16102}}],"startAt":2,"maxResults":50,"total":3}' 200
	set_stub_response 5 "$(jq -n -c --arg inj "$INJ_NAME" '{fields:[{fieldId:"summary",name:"Summary",required:true,schema:{type:"string"}},{fieldId:"customfield_20001",name:"Sprint (createmeta)",required:false,schema:{type:"array"}},{fieldId:"customfield_99999",name:$inj,required:false,schema:{type:"string",custom:"com.z",customId:99999}}],startAt:0,maxResults:50,total:3}')" 200
	set_stub_response 6 '{"fields":[{"fieldId":"summary","name":"Summary","required":true,"schema":{"type":"string"}}],"startAt":0,"maxResults":50,"total":1}' 200
	set_stub_response 7 "$(discover_field_catalog_json 'Story Points')" 200
}

section "jira.sh — discover: emits the consumed config shape; pagination pulls ALL types/fields"

reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover -> exit 0" 0

TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT" | jq -e . >/dev/null 2>&1; then pass "discover: stdout is valid JSON"
else fail "discover: stdout is valid JSON" "stdout was: $CUR_OUT"; fi

DISC_KEYS=$(printf '%s' "$CUR_OUT" | jq -c 'keys')
equals "discover: config carries EXACTLY the consumed shape's keys" \
	"$DISC_KEYS" '["custom_fields","issue_types","subtask_parent_types","subtask_types","type_aliases","workflows"]'

DISC_CF_SP=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields["Story Points"]')
equals "discover: custom_fields maps 'Story Points' -> id (name from the /field catalog, not createmeta)" \
	"$DISC_CF_SP" "customfield_10016"

DISC_CF_AC=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields["Acceptance Criteria"]')
equals "discover: OFFSET field paging pulled page 2 (Acceptance Criteria from type-10001 startAt=2)" \
	"$DISC_CF_AC" "customfield_16102"

DISC_TYPES=$(printf '%s' "$CUR_OUT" | jq -c '.issue_types')
equals "discover: OFFSET issuetype paging pulled page 2 (Subtask present alongside Task/Story)" \
	"$DISC_TYPES" '["Story","Subtask","Task"]'

DISC_SUB=$(printf '%s' "$CUR_OUT" | jq -c '.subtask_types')
equals "discover: subtask_types is exactly the subtask-flagged type" "$DISC_SUB" '["Subtask"]'

# A customfield_ id with NO schema.custom is still classified custom.
DISC_CF_SPRINT=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields["Sprint"]')
equals "discover: OR-arm — a customfield_ id with no schema.custom is classified custom" \
	"$DISC_CF_SPRINT" "customfield_20001"

# NON-custom fields must be excluded (guards over-inclusion).
DISC_CF_SUMMARY=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields.Summary // "ABSENT"')
equals "discover: non-custom field 'Summary' is EXCLUDED from custom_fields" "$DISC_CF_SUMMARY" "ABSENT"
DISC_CF_SUMMARY_LC=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields.summary // "ABSENT"')
equals "discover: non-custom fieldId 'summary' is EXCLUDED from custom_fields" "$DISC_CF_SUMMARY_LC" "ABSENT"
DISC_CF_ASSIGNEE=$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields.Assignee // "ABSENT"')
equals "discover: non-custom field 'Assignee' (schema.type user) is EXCLUDED from custom_fields" "$DISC_CF_ASSIGNEE" "ABSENT"

# Offset paging terminates by startAt>=total (there is NO isLast on these
# endpoints): exactly seven GETs — issuetypes x2 pages + fields for 3 types
# (type 10001 spans 2 pages) + /field.
equals "discover: seven GETs total (offset paging pulls every page, stops at startAt>=total)" \
	"$(call_count)" "7"

file_has "discover: hits the SPLIT createmeta issuetypes endpoint" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes?startAt=0"
file_has "discover: pages the issuetypes endpoint by OFFSET (a second GET at startAt=2)" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes?startAt=2"
file_has "discover: hits the per-type createmeta fields endpoint" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes/10001?"
file_has "discover: pages the per-type fields endpoint by OFFSET (a second GET at startAt=2)" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/issue/createmeta/PROJ/issuetypes/10001?startAt=2"
file_has "discover: hits the global /field catalog" \
	"$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/field"
file_not_has "discover: does NOT use the deprecated combined createmeta endpoint" \
	"$CURL_STUB_ARGV_LOG" "createmeta?projectKeys="

section "jira.sh — discover: an injection-shaped field name round-trips INERT"

DISC_INJ_ID=$(printf '%s' "$CUR_OUT" | jq -r --arg k "$INJ_NAME" '.custom_fields[$k] // "MISSING"')
equals "discover: injection-shaped field name is a literal config KEY -> its id (not executed/mangled)" \
	"$DISC_INJ_ID" "customfield_99999"
# shellcheck disable=SC2016  # asserting the LITERAL injection bytes survive — must not expand here either
stdout_has "discover: injection metacharacters survive verbatim in the config" 'inj$(touch pwned)'

section "jira.sh — discover --write: creates the config under the projects dir + prints the (created) machine line"

DISCOVER_PROJECTS_DIR="$WORK/discover-projects"   # deliberately NOT pre-created: --write's mkdir -p must create it
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$DISCOVER_PROJECTS_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (fresh target) -> exit 0" 0
stdout_has "discover --write: machine line names the (created) outcome" "JIRA_DISCOVERED=PROJ -> $DISCOVER_PROJECTS_DIR/PROJ.json (created)"
file_has "discover --write: config saved under the STUBBED projects dir" \
	"$DISCOVER_PROJECTS_DIR/PROJ.json" "customfield_10016"
WRITTEN_SP=$(jq -r '.custom_fields["Story Points"]' "$DISCOVER_PROJECTS_DIR/PROJ.json")
equals "discover --write: the written file maps 'Story Points' -> id" "$WRITTEN_SP" "customfield_10016"
TESTS_RUN=$((TESTS_RUN + 1))
if find "$DISCOVER_PROJECTS_DIR" -name 'PROJ.json.tmp.*' 2>/dev/null | grep -q .; then
	fail "discover --write: atomic write leaves no .tmp staging file" "a .tmp file remained"
else pass "discover --write: atomic write leaves no .tmp staging file"; fi

section "jira.sh — discover: the written config is CONSUMED by the engine's resolve_field_name (SELF-SEEDING round-trip)"

# self-seeding — this section discovers+writes into its OWN fresh dir
# FIRST (a real write through the merge/create path), THEN reads it back via a
# real `view --fields`, so it never depends on the prior --write test running.
ROUNDTRIP_DIR="$WORK/discover-roundtrip"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$ROUNDTRIP_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover round-trip: seed the config via --write -> exit 0" 0
file_has "discover round-trip: seed config present" "$ROUNDTRIP_DIR/PROJ.json" "customfield_10016"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-5","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-5 --confirmed-site foo.atlassian.net --projects-dir "$ROUNDTRIP_DIR" --fields "Story Points,summary"
expect_rc "discover round-trip: view --fields via the discovered config -> exit 0" 0
file_has "discover round-trip: view resolved 'Story Points' -> customfield_10016 through the written config" \
	"$CURL_STUB_ARGV_LOG" "customfield_10016"

# ===========================================================================
# discover --write: MERGE, never clobber a human-curated config
# ===========================================================================

# A human-curated existing config: curated type_aliases/subtask_parent_types/
# workflows, a semantic custom_fields key (acceptance_criteria), an extra
# top-level "key", and a STALE issue_types the discovery must refresh away.
write_curated_config() {
	cat >"$1" <<'EOF'
{
  "key": "PROJ",
  "custom_fields": { "acceptance_criteria": "customfield_16102", "developer": "customfield_20777" },
  "type_aliases": { "story": "Story" },
  "subtask_parent_types": ["Story"],
  "workflows": { "Task": { "Open": ["In Progress"], "In Progress": ["Done"] } },
  "issue_types": ["OLD_STALE_TYPE"],
  "subtask_types": []
}
EOF
}

section "jira.sh — discover --write: MERGES into an existing curated config (preserve curation + refresh facts + back up)"

MERGE_DIR="$WORK/discover-merge"
mkdir -p "$MERGE_DIR"
write_curated_config "$MERGE_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$MERGE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (existing target) -> exit 0" 0
stdout_has "discover --write merge: machine line names the (merged) outcome + backup" \
	"JIRA_DISCOVERED=PROJ -> $MERGE_DIR/PROJ.json (merged; backup "
equals "merge PRESERVES curated type_aliases" \
	"$(jq -c '.type_aliases' "$MERGE_DIR/PROJ.json")" '{"story":"Story"}'
equals "merge PRESERVES curated workflows" \
	"$(jq -c '.workflows.Task.Open' "$MERGE_DIR/PROJ.json")" '["In Progress"]'
equals "merge PRESERVES curated subtask_parent_types" \
	"$(jq -c '.subtask_parent_types' "$MERGE_DIR/PROJ.json")" '["Story"]'
equals "merge PRESERVES the human semantic custom_fields key" \
	"$(jq -r '.custom_fields.acceptance_criteria' "$MERGE_DIR/PROJ.json")" "customfield_16102"
equals "merge PRESERVES an extra top-level key discovery does not model" \
	"$(jq -r '.key' "$MERGE_DIR/PROJ.json")" "PROJ"
equals "merge REFRESHES issue_types to the discovered facts (stale type gone)" \
	"$(jq -c '.issue_types' "$MERGE_DIR/PROJ.json")" '["Story","Subtask","Task"]'
equals "merge ADDS the discovered display-name custom field" \
	"$(jq -r '.custom_fields["Story Points"]' "$MERGE_DIR/PROJ.json")" "customfield_10016"
MERGE_BACKUP=$(find "$MERGE_DIR" -name 'PROJ.json.bak-*' 2>/dev/null | head -1)
file_has "merge BACKS UP the original (stale type present in the backup)" "$MERGE_BACKUP" "OLD_STALE_TYPE"
TESTS_RUN=$((TESTS_RUN + 1))
if find "$MERGE_DIR" -name 'PROJ.json.tmp.*' 2>/dev/null | grep -q .; then
	fail "merge: atomic write leaves no .tmp staging file (correct merged content landed via mv)" "a .tmp file remained"
else pass "merge: atomic write leaves no .tmp staging file (correct merged content landed via mv)"; fi

section "jira.sh — discover --write: a custom_fields key collision keeps the CURATED id ONLY on the four semantic keys"

# See cmd-discover.sh's DISCOVER_MERGE_PROGRAM header for why curation wins a
# collision on ONLY the four semantic keys — this section proves the OTHER
# direction: a PLAIN display-name key REFRESHES from live discovery like every
# other discovered fact (the semantic half is proven in its own section below,
# where the stub discovers a field literally NAMED "reviewer"). "Story Points" is
# that plain key here (this project's stub really does discover it as
# customfield_10016), curated STALE at customfield_99001.
COLLIDE_DIR="$WORK/discover-collide"
mkdir -p "$COLLIDE_DIR"
cat >"$COLLIDE_DIR/PROJ.json" <<'EOF'
{
  "key": "PROJ",
  "custom_fields": { "reviewer": "customfield_26758", "Story Points": "customfield_99001" },
  "type_aliases": {},
  "subtask_parent_types": [],
  "workflows": {},
  "issue_types": [],
  "subtask_types": []
}
EOF
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$COLLIDE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (colliding custom_fields key) -> exit 0" 0
equals "display-name collision: the DISCOVERED id refreshes the stale curated one" \
	"$(jq -r '.custom_fields["Story Points"]' "$COLLIDE_DIR/PROJ.json")" "customfield_10016"
# This project's stub discovers NO field named "reviewer", so this fixture's
# `reviewer` key is not a collision at all — it is a curated key discovery is
# SILENT on, and its survival is the merge's `$curated`-as-base property, not the
# semantic-key override. Titled for what it really proves; the genuine semantic
# collision is the section below.
equals "collision: a curated semantic key discovery is SILENT on is untouched" \
	"$(jq -r '.custom_fields.reviewer' "$COLLIDE_DIR/PROJ.json")" "customfield_26758"
equals "collision: a NON-colliding discovered key is still ADDED" \
	"$(jq -r '.custom_fields["Acceptance Criteria"]' "$COLLIDE_DIR/PROJ.json")" "customfield_16102"
equals "collision: the live FACTS still win outside custom_fields (issue_types refreshed)" \
	"$(jq -c '.issue_types' "$COLLIDE_DIR/PROJ.json")" '["Story","Subtask","Task"]'

section "jira.sh — discover --write: a SEMANTIC-key collision keeps the CURATED id (discovery loses here, and only here)"

# The one collision the narrowed rule actually refuses, and the ONLY case that
# tells it apart from the blanket one: a live Jira field whose display NAME is
# literally one of the four semantic keys. With the discovered side winning here,
# the next `discover --write` silently retargets every --reviewer write onto that
# unrelated field and Jira answers 204.
#
# Its OWN projects dir, because the collision needs its own /field catalog: the
# stub's customfield_10016 is renamed to "reviewer" (see
# discover_field_catalog_json), so discovery emits reviewer -> customfield_10016
# against a config curating reviewer -> customfield_26758 — the same key from
# both namespaces, which is what the sibling section's display-name fixture
# cannot produce.
SEMANTIC_COLLIDE_DIR="$WORK/discover-semantic-collide"
mkdir -p "$SEMANTIC_COLLIDE_DIR"
cat >"$SEMANTIC_COLLIDE_DIR/PROJ.json" <<'EOF'
{
  "key": "PROJ",
  "custom_fields": { "reviewer": "customfield_26758" },
  "type_aliases": {},
  "subtask_parent_types": [],
  "workflows": {},
  "issue_types": [],
  "subtask_types": []
}
EOF

# First, prove the collision is REAL rather than vacuous: a bare `discover`
# (no --write, no merge, no existing config in play) must itself emit
# reviewer -> customfield_10016. Without this the --write assertion below would
# pass just as happily against a stub that never discovers the key at all.
reset_curl_stub
queue_discover_responses
set_stub_response 7 "$(discover_field_catalog_json reviewer)" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover (reviewer-named field) -> exit 0" 0
equals "semantic collision setup is REAL: bare discover emits reviewer -> the DISCOVERED id" \
	"$(printf '%s' "$CUR_OUT" | jq -r '.custom_fields.reviewer')" "customfield_10016"

reset_curl_stub
queue_discover_responses
set_stub_response 7 "$(discover_field_catalog_json reviewer)" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$SEMANTIC_COLLIDE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (semantic-key collision) -> exit 0" 0
equals "semantic collision: the CURATED reviewer id survives the id discovery just offered" \
	"$(jq -r '.custom_fields.reviewer' "$SEMANTIC_COLLIDE_DIR/PROJ.json")" "customfield_26758"
# The narrowing is per-KEY, not per-run: the same merge that refused the reviewer
# collision must still take every OTHER discovered fact from the live side.
equals "semantic collision: a non-semantic discovered key in the SAME merge is still added" \
	"$(jq -r '.custom_fields["Acceptance Criteria"]' "$SEMANTIC_COLLIDE_DIR/PROJ.json")" "customfield_16102"

section "jira.sh — discover --write: a curated key discovery is SILENT on survives the merge untouched"

# The narrowed rule moved `$live` ahead of `$curated` for every non-semantic key,
# so the direction that has to be re-proven is the OTHER one: a curated
# display-name key discovery does not return AT ALL must not be dropped.
# Discovery sees only fields present on some issue type's CREATE screen, so a
# mapped field sitting on none of them is invisible to it — and silently losing
# that mapping breaks the next --developer/--fields write with no diagnostic.
#
# "Legacy Field" is neither semantic nor discovered by this project's stub, so it
# travels only the `$curated`-as-merge-base path — distinct from both collision
# arms above.
SILENT_DIR="$WORK/discover-silent-curated"
mkdir -p "$SILENT_DIR"
cat >"$SILENT_DIR/PROJ.json" <<'EOF'
{
  "key": "PROJ",
  "custom_fields": { "Legacy Field": "customfield_31337" },
  "type_aliases": {},
  "subtask_parent_types": [],
  "workflows": {},
  "issue_types": [],
  "subtask_types": []
}
EOF
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$SILENT_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (curated key discovery never returns) -> exit 0" 0
equals "silent-curated: the undiscovered curated mapping survives at its curated id" \
	"$(jq -r '.custom_fields["Legacy Field"]' "$SILENT_DIR/PROJ.json")" "customfield_31337"
equals "silent-curated: the merge still ADDED the discovered keys alongside it" \
	"$(jq -r '.custom_fields["Story Points"]' "$SILENT_DIR/PROJ.json")" "customfield_10016"

section "jira.sh — discover --write --force: clean replace of an existing config (still backs up)"

FORCE_DIR="$WORK/discover-force"
mkdir -p "$FORCE_DIR"
write_curated_config "$FORCE_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$FORCE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write --force
expect_rc "discover --write --force -> exit 0" 0
stdout_has "discover --force: machine line names the (replaced) outcome + backup" \
	"JIRA_DISCOVERED=PROJ -> $FORCE_DIR/PROJ.json (replaced; backup "
equals "force RESETS type_aliases to the empty discovered slot" \
	"$(jq -c '.type_aliases' "$FORCE_DIR/PROJ.json")" '{}'
equals "force RESETS workflows to the empty discovered slot" \
	"$(jq -c '.workflows' "$FORCE_DIR/PROJ.json")" '{}'
equals "force DROPS the curated semantic custom_fields key" \
	"$(jq -r '.custom_fields.acceptance_criteria // "ABSENT"' "$FORCE_DIR/PROJ.json")" "ABSENT"
FORCE_BACKUP=$(find "$FORCE_DIR" -name 'PROJ.json.bak-*' 2>/dev/null | head -1)
file_has "force STILL backs up the original before replacing" "$FORCE_BACKUP" "OLD_STALE_TYPE"

section "jira.sh — discover --write: an INVALID existing config is backed up + replaced fresh with a WARNING"

INVALID_DIR="$WORK/discover-invalid"
mkdir -p "$INVALID_DIR"
printf '%s' 'this is { not valid json at all' >"$INVALID_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INVALID_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write (invalid existing) -> exit 0" 0
stderr_has "invalid existing: warns it is not valid JSON" "not valid JSON"
stdout_has "invalid existing: machine line names the (replaced) outcome + backup" \
	"JIRA_DISCOVERED=PROJ -> $INVALID_DIR/PROJ.json (replaced; backup "
equals "invalid existing: fresh config carries the discovered issue_types" \
	"$(jq -c '.issue_types' "$INVALID_DIR/PROJ.json")" '["Story","Subtask","Task"]'
INVALID_BACKUP=$(find "$INVALID_DIR" -name 'PROJ.json.bak-*' 2>/dev/null | head -1)
file_has "invalid existing: the unparseable original is preserved in the backup" "$INVALID_BACKUP" "not valid json"

section "jira.sh — discover --write: same-UTC-second re-writes never overwrite a backup"

# The `fixedtime` toolbox pins `date` to one stamp, so BOTH writes derive the
# SAME .bak-<UTC> base — the ONLY thing keeping them distinct is the mktemp
# suffix. Without the uniquifier these would collapse to a single backup file.
COLLIDE_DIR="$WORK/discover-collide"
mkdir -p "$COLLIDE_DIR"
write_curated_config "$COLLIDE_DIR/PROJ.json"
reset_curl_stub
queue_discover_responses
run fixedtime "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$COLLIDE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "collide: first --write (fixed UTC second) -> exit 0" 0
reset_curl_stub
queue_discover_responses
run fixedtime "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$COLLIDE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "collide: second --write (SAME fixed UTC second) -> exit 0" 0
COLLIDE_BACKUPS=$(find "$COLLIDE_DIR" -name 'PROJ.json.bak-20260725T000000Z.*' 2>/dev/null | wc -l | tr -d ' ')
equals "collide: two same-second writes produced TWO distinct backups (mktemp uniquifier — no overwrite)" \
	"$COLLIDE_BACKUPS" "2"

section "jira.sh — discover: a non-numeric issue-type id is skipped (id guard)"

reset_curl_stub
set_stub_response 1 "$(jq -n -c '{issueTypes:[{id:"10001",name:"Task",subtask:false},{id:"../evil",name:"Evil",subtask:false}],startAt:0,maxResults:50,total:2}')" 200
set_stub_response 2 '{"fields":[{"fieldId":"customfield_10016","name":"Story Points","schema":{"custom":"x","customId":10016}}],"startAt":0,"maxResults":50,"total":1}' 200
set_stub_response 3 '[{"id":"customfield_10016","name":"Story Points","custom":true}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover with a non-numeric type id -> exit 0" 0
stderr_has "discover: warns it is skipping the non-numeric id" "skipping issue type with an unexpected id shape"
equals "discover: only THREE GETs (issuetypes + fields for the ONE valid id + /field) — the bad id got no per-type fetch" \
	"$(call_count)" "3"
file_not_has "discover: NO per-type-fields GET for the traversal-shaped id" \
	"$CURL_STUB_ARGV_LOG" "issuetypes/../evil"

section "jira.sh — discover: duplicate custom-field display names are surfaced"

reset_curl_stub
set_stub_response 1 '{"issueTypes":[{"id":"10001","name":"Task","subtask":false}],"startAt":0,"maxResults":50,"total":1}' 200
set_stub_response 2 '{"fields":[{"fieldId":"customfield_100","name":"x"},{"fieldId":"customfield_200","name":"y"}],"startAt":0,"maxResults":50,"total":2}' 200
set_stub_response 3 '[{"id":"customfield_100","name":"Priority Score","custom":true},{"id":"customfield_200","name":"Priority Score","custom":true}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover with a duplicate display name -> exit 0" 0
stderr_has "discover: warns about the duplicate display name" "duplicate custom-field display name"
stderr_has "discover: names the colliding display name" "Priority Score"
DUP_CF_COUNT=$(printf '%s' "$CUR_OUT" | jq '.custom_fields | length')
equals "discover: the flat map keeps exactly one id under the collided name" "$DUP_CF_COUNT" "1"

section "jira.sh — discover: usage + failure paths"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover --confirmed-site foo.atlassian.net
expect_rc "discover without a PROJECT -> exit 2" 2
stderr_has "discover without PROJECT: diagnostic" "requires a PROJECT key"

run nocurl sh "$JIRA" discover PROJ
expect_rc "discover without --confirmed-site -> exit 2" 2
stderr_has "discover without --confirmed-site: diagnostic" "--confirmed-site is required"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/discover-traversal" \
	sh "$JIRA" discover '../../x' --confirmed-site foo.atlassian.net --write
expect_rc "discover traversal-shaped PROJECT -> exit 2 (rejected BEFORE any read/write)" 2
stderr_has "discover traversal PROJECT: diagnostic" "invalid project key"
equals "discover traversal PROJECT: no network call was made" "$(call_count)" "0"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -e "$WORK/discover-traversal" ]; then fail "discover traversal PROJECT: no projects dir was created" "dir exists"
else pass "discover traversal PROJECT: no file/dir written under the projects dir"; fi

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Project does not exist or you do not have permission"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net
expect_rc "discover createmeta 404 -> exit 1" 1
stderr_has "discover 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "discover 404: Jira's own error message surfaced" "Project does not exist"

# ===========================================================================
# version — project versions/releases (Phase-2d). Fixtures use the REAL live
# shapes: GET /project/<K>/versions is a PLAIN JSON ARRAY (NOT a paginated
# {values:[...]} envelope); a version object has a STRING id, `released`, and
# OPTIONAL releaseDate/startDate/overdue/userReleaseDate.
# ===========================================================================
section "jira.sh — version --list: parses the PLAIN ARRAY (human + --json)"

reset_curl_stub
set_stub_response 1 '[{"self":"https://foo.atlassian.net/rest/api/3/version/11751","id":"11751","name":"3.10.0","archived":false,"released":false,"releaseDate":"2026-07-06","startDate":"2026-06-29","overdue":true,"projectId":10521},{"id":"11752","name":"3.11.0","archived":false,"released":true}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list -> exit 0" 0
file_has "version --list: GET /rest/api/3/project/PSWS/versions" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/versions"
stdout_has "version --list: version name rendered" "3.10.0"
stdout_has "version --list: string id rendered" "id 11751"
stdout_has "version --list: released flag rendered" "released true"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0","released":false}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net --json
expect_rc "version --list --json -> exit 0" 0
VER_LIST_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.[0].id')
equals "version --list --json: raw PLAIN-ARRAY body passes through (string id)" "$VER_LIST_JSON_ID" "11751"
# Assert the id's JSON TYPE explicitly so the "string id" guarantee is real —
# a numeric id would fail here, where before nothing constrained the type.
VER_LIST_JSON_ID_TYPE=$(printf '%s' "$CUR_OUT" | jq -r '.[0].id | type')
equals "version --list --json: the id is a JSON string (not a number)" "$VER_LIST_JSON_ID_TYPE" "string"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list empty -> exit 0" 0
stdout_has "version --list empty: 'No versions.'" "No versions."

section "jira.sh — version --list: a NAME with an embedded TAB cannot misalign columns"

# A plain IFS=<tab> read split of jq's tab-joined line would let a tab INSIDE
# the name shift every following column (the id would end up holding the name's
# tail). strip_control_ansi runs after the split and removes neither tab nor
# newline, so it cannot save it — the renderer extracts each field by jq instead.
reset_curl_stub
DIRTY_TAB_NAME="Auth$(printf '\t')EVIL"
set_stub_response 1 "$(jq -n -c --arg n "$DIRTY_TAB_NAME" '[{id:"11751",name:$n,released:false}]')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list tab-in-name -> exit 0" 0
stdout_has "version --list: a tab in the name does NOT shift the id column (id 11751 intact)" "id 11751"
stdout_has "version --list: a tab in the name does NOT shift the released column" "released false"

section "jira.sh — version --list: a NAME with an embedded NEWLINE cannot split a row"

# A newline in the name would break the single record across two `read`
# iterations, rendering two bogus rows. Each object is now one compact JSON
# line and each field is extracted independently, so exactly ONE row renders.
reset_curl_stub
DIRTY_NL_NAME="Auth
EVIL"
set_stub_response 1 "$(jq -n -c --arg n "$DIRTY_NL_NAME" '[{id:"11751",name:$n,released:false}]')" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list newline-in-name -> exit 0" 0
NL_ID_ROWS=$(printf '%s\n' "$CUR_OUT" | grep -c '(id ')
TESTS_RUN=$((TESTS_RUN + 1))
if [ "$NL_ID_ROWS" -eq 1 ]; then
	pass "version --list: a newline in the name renders exactly ONE row, never split into two"
else
	fail "version --list: a newline in the name renders exactly ONE row, never split into two" "counted $NL_ID_ROWS rows"
fi

section "jira.sh — version --create: body project is the KEY STRING, never a numeric projectId (ground-truth guard)"

reset_curl_stub
set_stub_response 1 '{"id":"12000","name":"3.12.0","released":false,"archived":false}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 3.12.0 --description "next release" \
		--release-date 2026-12-31 --start-date 2026-06-01 --confirmed-site foo.atlassian.net
expect_rc "version --create -> exit 0" 0
file_has "version --create: POST /rest/api/3/version" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/version"
file_has "version --create: uses POST" "$CURL_STUB_ARGV_LOG" "POST"
VER_CREATE_PROJECT=$(jq -r '.project' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: body 'project' is the KEY STRING (the API rejects projectId)" "$VER_CREATE_PROJECT" "PSWS"
VER_CREATE_HAS_PROJECTID=$(jq -r 'has("projectId")' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: body carries NO numeric projectId" "$VER_CREATE_HAS_PROJECTID" "false"
VER_CREATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: body name" "$VER_CREATE_NAME" "3.12.0"
VER_CREATE_RELDATE=$(jq -r '.releaseDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: releaseDate carried" "$VER_CREATE_RELDATE" "2026-12-31"
VER_CREATE_STARTDATE=$(jq -r '.startDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create: startDate carried" "$VER_CREATE_STARTDATE" "2026-06-01"
stdout_has "version --create: machine line names the new id" "JIRA_VERSION_ID=12000"
stdout_has "version --create: machine line names the new name" "JIRA_VERSION_NAME=3.12.0"

section "jira.sh — version --create: minimal body is EXACTLY {name,project}; --released is a JSON boolean"

reset_curl_stub
set_stub_response 1 '{"id":"12002","name":"2.0"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 2.0 --confirmed-site foo.atlassian.net
expect_rc "version --create minimal -> exit 0" 0
VER_CREATE_MIN_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create minimal: body is exactly {name,project} (no empty optionals)" "$VER_CREATE_MIN_KEYS" '["name","project"]'

reset_curl_stub
set_stub_response 1 '{"id":"12001","name":"1.0","released":true}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 1.0 --released --confirmed-site foo.atlassian.net
expect_rc "version --create --released -> exit 0" 0
VER_CREATE_RELEASED=$(jq -r '.released' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create --released: released:true" "$VER_CREATE_RELEASED" "true"
VER_CREATE_RELEASED_TYPE=$(jq -r '.released | type' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --create --released: released is a JSON boolean, not the string \"true\"" "$VER_CREATE_RELEASED_TYPE" "boolean"

section "jira.sh — version --update / --release / --archive: PUT /version/<id> with a partial body"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.1","released":false}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --name 3.10.1 --confirmed-site foo.atlassian.net
expect_rc "version --update -> exit 0" 0
file_has "version --update: PUT /rest/api/3/version/11751" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/version/11751"
file_has "version --update: uses PUT" "$CURL_STUB_ARGV_LOG" "PUT"
VER_UPDATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update: body carries ONLY the changed field" "$VER_UPDATE_KEYS" '["name"]'
VER_UPDATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update: name value" "$VER_UPDATE_NAME" "3.10.1"
stdout_has "version --update: machine line" "JIRA_VERSION_ID=11751"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.0","released":true,"releaseDate":"2026-07-06"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --release --id 11751 --release-date 2026-07-06 --confirmed-site foo.atlassian.net
expect_rc "version --release -> exit 0" 0
VER_RELEASE_RELEASED=$(jq -r '.released' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --release: body released:true" "$VER_RELEASE_RELEASED" "true"
VER_RELEASE_DATE=$(jq -r '.releaseDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --release: releaseDate included when given" "$VER_RELEASE_DATE" "2026-07-06"

reset_curl_stub
set_stub_response 1 '{"id":"11751","released":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --release --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --release (no date) -> exit 0" 0
VER_RELEASE_NODATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --release without --release-date: body is exactly {released:true}" "$VER_RELEASE_NODATE_KEYS" '["released"]'

reset_curl_stub
set_stub_response 1 '{"id":"11751","archived":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --archive --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --archive -> exit 0" 0
VER_ARCHIVE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --archive: body is exactly {archived:true}" "$VER_ARCHIVE_KEYS" '["archived"]'
VER_ARCHIVE_VAL=$(jq -r '.archived' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --archive: archived is a JSON boolean true" "$VER_ARCHIVE_VAL" "true"

# ---------------------------------------------------------------------------
# version --delete — DELETE /version/<id> with up to TWO OPTIONAL, INDEPENDENT
# reassignment query params (moveFixIssuesTo / moveAffectedIssuesTo). Mirrors
# the component --delete section below: a 204 No Content response, a machine
# line in human mode, a SYNTHESIZED body under --json.
#
# Every URL assertion here is argv_log_has_token (an exact-LINE match against
# the argv log), NOT file_has (a substring match). That is load-bearing for
# this command specifically: the query string is built by appending, so a
# substring assertion on ".../version/11751" would pass just as happily against
# ".../version/11751?" or ".../version/11751?&moveAffectedIssuesTo=11753". The
# exact-line form is what makes "no query string at all", "no dangling &" and
# "no doubled ?" real assertions rather than wishful ones.
#
# The three ids are DELIBERATELY DISTINCT (11751 deleted, 11752 fix target,
# 11753 affected target) so a mapping that swapped the two params — the other
# way this can silently break — fails instead of matching by coincidence.
# ---------------------------------------------------------------------------
section "jira.sh — version --delete: DELETE /version/<id>, no query string when no move flag is given"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete -> exit 0" 0
argv_log_has_token "version --delete: URL is EXACTLY /rest/api/3/version/11751 (no trailing '?')" "https://foo.atlassian.net/rest/api/3/version/11751"
argv_log_has_token "version --delete: uses DELETE" "DELETE"
file_not_has "version --delete: no moveFixIssuesTo when not given" "$CURL_STUB_ARGV_LOG" "moveFixIssuesTo"
file_not_has "version --delete: no moveAffectedIssuesTo when not given" "$CURL_STUB_ARGV_LOG" "moveAffectedIssuesTo"
stdout_has "version --delete: machine line names the deleted id" "JIRA_VERSION_DELETED=11751"

section "jira.sh — version --delete: ONE move flag opens the query with '?', never a dangling separator"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "version --delete --move-fix-issues-to -> exit 0" 0
argv_log_has_token "version --delete --move-fix-issues-to: URL is EXACTLY .../version/11751?moveFixIssuesTo=11752" "https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752"
file_not_has "version --delete --move-fix-issues-to: the untouched param is absent" "$CURL_STUB_ARGV_LOG" "moveAffectedIssuesTo"

# The SECOND param given ALONE is the dangling-separator case: it is the one
# whose branch also emits the '&' joiner, so a joiner emitted unconditionally
# (rather than only when a first param already landed) produces `?&moveAffec…`.
# The exact-line match below is what rejects that, and a doubled '?' with it.
reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "version --delete --move-affected-issues-to -> exit 0" 0
argv_log_has_token "version --delete --move-affected-issues-to ALONE: URL is EXACTLY .../version/11751?moveAffectedIssuesTo=11753 (no leading '&', no doubled '?')" "https://foo.atlassian.net/rest/api/3/version/11751?moveAffectedIssuesTo=11753"
file_not_has "version --delete --move-affected-issues-to: the untouched param is absent" "$CURL_STUB_ARGV_LOG" "moveFixIssuesTo"

section "jira.sh — version --delete: BOTH move flags join with exactly one '&', in fix-then-affected order"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to 11752 --move-affected-issues-to 11753 \
	--confirmed-site foo.atlassian.net
expect_rc "version --delete with BOTH move flags -> exit 0" 0
argv_log_has_token "version --delete both flags: URL is EXACTLY .../version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753" "https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753"

section "jira.sh — version --delete --json: SYNTHESIZES a body (the 204 has none to pass through)"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net --json
expect_rc "version --delete --json -> exit 0" 0
# One compact, key-sorted compare pins the WHOLE synthesized object — the shape
# (exactly {id,deleted}, identical to component --delete's), the id's JSON
# STRING type, and the deleted flag's JSON BOOLEAN type — in a single
# diagnosable assertion. Parsing $CUR_OUT with jq at all is also what proves
# the empty 204 body was never fed to a parser.
VER_DELETE_JSON=$(printf '%s' "$CUR_OUT" | jq -cS '.')
equals "version --delete --json: SYNTHESIZED body is exactly {id:\"11751\",deleted:true}" "$VER_DELETE_JSON" '{"deleted":true,"id":"11751"}'

# ---------------------------------------------------------------------------
# version --delete's TWO OPT-IN pre-write safety nets: `--plan`/`--dry-run`
# (disclose, write nothing) and `--project KEY` (refuse unless the version
# really belongs to KEY). Both are backed by resolve_version_owner's TWO
# read-only GETs — /version/<id> for the name + numeric projectId, then
# /project/<projectId> for the KEY a human actually reads.
#
# WHY THE METHOD SEQUENCE IS THE LOAD-BEARING ASSERTION HERE, and not a URL
# one: the version GET and the DELETE address the SAME url
# (.../rest/api/3/version/11751), so no URL assertion can tell "read it" from
# "deleted it" apart. The ordered METHOD sequence can, and it is the only
# thing that proves --plan short-circuited BEFORE the write rather than after
# it, and that the cross-check refused BEFORE the write rather than alongside
# it. Every case below therefore pins the full sequence, not just a count.
# ---------------------------------------------------------------------------

# request_method_sequence (lib/curl-stub.sh) is what every case below asserts
# with — it was promoted out of this file once comment-edit's read-before-write
# ordering in the write suite needed the same proof.

# The owning project is reported by /version/<id> ONLY as a numeric projectId,
# which is exactly why a second GET exists; the two ids are deliberately
# distinct (version 11751, project 10042) so a mix-up cannot pass by accident.
VERSION_OWNER_BODY='{"id":"11751","name":"1.2.0","projectId":10042}'
VERSION_OWNER_PROJECT_BODY='{"id":"10042","key":"PSWS","name":"Platform Services"}'

# EVERY case below queues a 204 as its THIRD response, including the ones that
# must not write at all. That is deliberate and load-bearing: with no third
# response the stub errors out, so a guard that stopped working would fail the
# run for the wrong reason and the "no DELETE" assertions would be propped up by
# the fixture rather than by the code. With the 204 queued, a missing
# short-circuit or a missing cross-check produces a CLEAN, successful delete —
# and these assertions are the only thing standing in its way.

section "jira.sh — version --delete --plan: TWO read-only GETs, ZERO writes, plan disclosed"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan -> exit 0" 0
equals "version --delete --plan: exactly TWO curl calls (the owner resolve, nothing more)" "$(call_count)" "2"
equals "version --delete --plan: the two calls are GET/GET — the DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
argv_log_has_token "version --delete --plan: first read is GET /version/11751" "https://foo.atlassian.net/rest/api/3/version/11751"
argv_log_has_token "version --delete --plan: second read is GET /project/10042 (the key comes from the numeric projectId)" "https://foo.atlassian.net/rest/api/3/project/10042"
stdout_has "version --delete --plan: discloses the resolved name AND owning project" \
	'would delete version 11751 "1.2.0" in project PSWS'
stdout_has "version --delete --plan: discloses the exact request that WOULD be sent" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751"
stdout_has "version --delete --plan: ends on the engine-wide dry-run line" "NOTHING WAS WRITTEN"
stdout_not_has "version --delete --plan: NO success machine line (nothing was deleted)" "JIRA_VERSION_DELETED"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --json --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --json -> exit 0" 0
equals "version --delete --plan --json: still exactly TWO GETs, no write" \
	"$(request_method_sequence)" "GET/GET"
# One key-sorted compare pins the WHOLE synthesized plan object — the op tag, the
# plan/willWrite pair a consent gate machine-checks, and every resolved field —
# in a single diagnosable assertion, the same idiom the --json delete above uses.
VER_PLAN_JSON=$(printf '%s' "$CUR_OUT" | jq -cS '.')
equals "version --delete --plan --json: SYNTHESIZED plan object is exactly the documented shape" \
	"$VER_PLAN_JSON" \
	'{"id":"11751","name":"1.2.0","op":"version-delete","plan":true,"project":"PSWS","url":"https://foo.atlassian.net/rest/api/3/version/11751","willWrite":false}'

section "jira.sh — version --delete --plan + the move flags: the disclosed URL is the one that WOULD be sent"

# THE CONTRACT A PREVIEW MAKES: the URL it discloses is the URL the real request
# would carry — reassignment query and all. That only holds because the query is
# built BEFORE the --plan short-circuit; move the construction after it and the
# plan still prints, still says NOTHING WAS WRITTEN, and still exits 0, while
# quietly disclosing a bare .../version/11751 for a delete that would in fact
# re-point every issue's fixVersions. A caller reading that plan would approve a
# reassignment they were never shown.
#
# Each case pins the FULL URL as one substring, so a plan that dropped a param,
# swapped the two, or emitted a dangling separator fails here — the same
# exact-shape discipline the non-plan cases above apply to the argv log. The
# GET/GET method sequence alongside it is what proves the preview is still a
# preview: with a 204 queued as call 3, a lost short-circuit would delete for
# real and read as "GET/GET/DELETE".

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --move-fix-issues-to -> exit 0" 0
equals "version --delete --plan --move-fix-issues-to: still GET/GET — the reassigning DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
stdout_has "version --delete --plan --move-fix-issues-to: the disclosed URL carries the real ?moveFixIssuesTo=11752" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --move-affected-issues-to -> exit 0" 0
equals "version --delete --plan --move-affected-issues-to: still GET/GET — the reassigning DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
stdout_has "version --delete --plan --move-affected-issues-to ALONE: the disclosed URL opens with '?', not a dangling '&'" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751?moveAffectedIssuesTo=11753"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --move-fix-issues-to 11752 --move-affected-issues-to 11753 \
	--confirmed-site foo.atlassian.net
expect_rc "version --delete --plan with BOTH move flags -> exit 0" 0
equals "version --delete --plan both move flags: still GET/GET — the reassigning DELETE never happened" \
	"$(request_method_sequence)" "GET/GET"
# Same fix-then-affected order, same single '&', as the non-plan both-flags case
# above pins on the wire — which is the whole point: one construction, two
# consumers, so the preview cannot drift from the request.
stdout_has "version --delete --plan both move flags: the disclosed URL joins both params with exactly one '&', fix before affected" \
	"DELETE https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753"

# The machine-readable half of the same contract: a consent gate reads `url` from
# the synthesized object, not the human line, so it is pinned in full too.
reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --json --move-fix-issues-to 11752 --move-affected-issues-to 11753 \
	--confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --json with BOTH move flags -> exit 0" 0
equals "version --delete --plan --json both move flags: still GET/GET, no write" \
	"$(request_method_sequence)" "GET/GET"
VER_PLAN_MOVE_JSON=$(printf '%s' "$CUR_OUT" | jq -cS '.')
equals "version --delete --plan --json both move flags: the synthesized object's url carries BOTH query params" \
	"$VER_PLAN_MOVE_JSON" \
	'{"id":"11751","name":"1.2.0","op":"version-delete","plan":true,"project":"PSWS","url":"https://foo.atlassian.net/rest/api/3/version/11751?moveFixIssuesTo=11752&moveAffectedIssuesTo=11753","willWrite":false}'

section "jira.sh — version --delete --project: the ownership cross-check, under --plan and for real"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --project MATCHING -> exit 0" 0
equals "version --delete --plan --project MATCHING: ONE owner resolve serves both features (still just GET/GET)" \
	"$(request_method_sequence)" "GET/GET"
stdout_has "version --delete --plan --project MATCHING: the plan is still disclosed" \
	'would delete version 11751 "1.2.0" in project PSWS'
stdout_has "version --delete --plan --project MATCHING: states nothing was written" "NOTHING WAS WRITTEN"

# The cross-check must fire EVEN UNDER --plan: a mismatch means the plan would
# describe a version the caller did not mean, and printing it would read as
# confirmation of exactly the wrong thing.
reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --project OTHER --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan --project MISMATCHED -> exit 1" 1
equals "version --delete --plan --project MISMATCHED: still only the two reads, no write" \
	"$(request_method_sequence)" "GET/GET"
stderr_has "version --delete --plan --project MISMATCHED: diagnostic names BOTH the real owner and the asserted one" \
	"version 11751 belongs to project PSWS, not --project OTHER"
stdout_not_has "version --delete --plan --project MISMATCHED: the plan is NOT printed (it would confirm the wrong version)" \
	"would delete version 11751"
stdout_not_has "version --delete --plan --project MISMATCHED: no dry-run footer either" "NOTHING WAS WRITTEN"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --delete --project MATCHING (a real delete) -> exit 0" 0
equals "version --delete --project MATCHING: THREE requests" "$(call_count)" "3"
equals "version --delete --project MATCHING: in GET/GET/DELETE order — both reads precede the write" \
	"$(request_method_sequence)" "GET/GET/DELETE"
stdout_has "version --delete --project MATCHING: machine line names the deleted id" "JIRA_VERSION_DELETED=11751"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project OTHER --confirmed-site foo.atlassian.net
expect_rc "version --delete --project MISMATCHED (a real delete attempt) -> exit 1" 1
equals "version --delete --project MISMATCHED: only the two reads happened" "$(call_count)" "2"
# The whole point of the flag: the destructive request must never be issued at
# all, not merely be reported as failed afterwards. A 204 IS queued as call 3
# above, so a cross-check that ran too late would exit 0 here and this would fail.
argv_log_not_has_token "version --delete --project MISMATCHED: the DELETE was NEVER sent" "DELETE"
stderr_has "version --delete --project MISMATCHED: refusal diagnostic" \
	"version 11751 belongs to project PSWS, not --project OTHER — refusing to delete it"
stdout_not_has "version --delete --project MISMATCHED: no success machine line" "JIRA_VERSION_DELETED"

# REGRESSION GUARD for the DEFAULT path: neither opt-in flag given, the delete
# must behave EXACTLY as it did before --plan/--project existed — one request,
# the DELETE, and NO owner-resolution read bolted on. Pinning the full method
# sequence to a bare "DELETE" is what proves that: any GET added to this path
# (an unconditional resolve, a "cheap" pre-read) makes the sequence
# "GET/GET/DELETE" and fails here, where a call-count-only assertion could be
# quietly relaxed later.
section "jira.sh — version --delete with NEITHER opt-in flag: unchanged single-request default"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete (no --plan, no --project) -> exit 0" 0
equals "version --delete default: exactly ONE request" "$(call_count)" "1"
equals "version --delete default: that request is the DELETE and nothing precedes it" \
	"$(request_method_sequence)" "DELETE"
argv_log_has_token "version --delete default: URL is EXACTLY /rest/api/3/version/11751" "https://foo.atlassian.net/rest/api/3/version/11751"
file_not_has "version --delete default: no /project/ lookup was added to this path" "$CURL_STUB_ARGV_LOG" "/rest/api/3/project/"
stdout_has "version --delete default: machine line unchanged" "JIRA_VERSION_DELETED=11751"

section "jira.sh — version --delete: the owner resolve fails CLOSED on an unusable response"

# The resolve exists to make a delete SAFER, so an owner it cannot establish
# must be exit 1 — never a softer "unknown" that proceeds to the DELETE anyway.
reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"1.2.0"}' 200
set_stub_response 2 "$VERSION_OWNER_PROJECT_BODY" 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --plan --confirmed-site foo.atlassian.net
expect_rc "version --delete --plan, version response carries NO projectId -> exit 1" 1
equals "version --delete --plan, no projectId: stops after the first read" "$(call_count)" "1"
argv_log_not_has_token "version --delete --plan, no projectId: the DELETE was NEVER sent" "DELETE"
stderr_has "version --delete --plan, no projectId: diagnostic" \
	"could not determine which project version 11751 belongs to"

reset_curl_stub
set_stub_response 1 "$VERSION_OWNER_BODY" 200
set_stub_response 2 '{"id":"10042","name":"Platform Services"}' 200
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --delete --project, project response carries NO key -> exit 1" 1
equals "version --delete --project, no key: both reads ran, nothing more" "$(request_method_sequence)" "GET/GET"
argv_log_not_has_token "version --delete --project, no key: the DELETE was NEVER sent" "DELETE"
stderr_has "version --delete --project, no key: diagnostic names the unhelpful project" \
	"project 10042 reported no key"

section "jira.sh — version: mode-flag + argument validation"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version with ZERO mode flags -> exit 2" 2
stderr_has "version zero modes: diagnostic" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --create --project PSWS --name X --confirmed-site foo.atlassian.net
expect_rc "version with TWO mode flags -> exit 2" 2
stderr_has "version two modes: diagnostic" "exactly one mode"

# `version --list --delete` names TWO of version's OWN modes. It used to be
# rejected by NAME ("--delete is not a version mode") because --delete was then
# a component-only flag; --delete is now a version mode in its own right, so the
# exactly-one-mode count is what rejects the pair. The property under test is
# unchanged — you cannot give two version modes at once — only the diagnostic
# that enforces it, which is why this asserts the new message rather than being
# dropped. Shaped like the sibling `component --list --delete --id` case below.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --delete --id 11751 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --list + --delete (TWO modes) -> exit 2" 2
stderr_has "version --list --delete: diagnostic names the exactly-one-mode rule" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --create --project PSWS --name X --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete + --create (TWO modes) -> exit 2" 2
stderr_has "version --delete --create: diagnostic names the exactly-one-mode rule" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --confirmed-site foo.atlassian.net
expect_rc "version --delete without --id -> exit 2" 2
stderr_has "version --delete no id: diagnostic names --id as required" "--update/--release/--archive/--delete requires --id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id abc --confirmed-site foo.atlassian.net
expect_rc "version --delete with a NON-NUMERIC --id -> exit 2" 2
stderr_has "version --delete non-numeric id: diagnostic" "invalid --id (must be a numeric version id)"

# --project is OPTIONAL on --delete, so only its SHAPE is checked — but it IS
# checked, and at VALIDATION time. A malformed key left unchecked would reach
# the ownership comparison instead and fail as "belongs to another project"
# (exit 1), dressing a caller's own typo up as a Jira fact. Exit 2 AND zero
# curl calls together are what prove it was rejected before the network, which
# neither assertion establishes on its own.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --project psws --confirmed-site foo.atlassian.net
expect_rc "version --delete with a MALFORMED --project -> exit 2 (usage), not exit 1 (ownership)" 2
stderr_has "version --delete malformed project: diagnostic" "invalid project key: psws"
equals "version --delete malformed project: ZERO curl calls (rejected before the owner resolve)" "$(call_count)" "0"

# The two reassignment targets are INDEPENDENT guards in the validator — each
# is numeric-checked and mode-checked on its own — so each is asserted on its
# own. A shared assertion would let one guard be deleted and still pass.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to abc --confirmed-site foo.atlassian.net
expect_rc "version --delete NON-NUMERIC --move-fix-issues-to -> exit 2" 2
stderr_has "version non-numeric move-fix target: diagnostic names THAT flag" "invalid --move-fix-issues-to (must be a numeric version id)"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-affected-issues-to abc --confirmed-site foo.atlassian.net
expect_rc "version --delete NON-NUMERIC --move-affected-issues-to -> exit 2" 2
stderr_has "version non-numeric move-affected target: diagnostic names THAT flag" "invalid --move-affected-issues-to (must be a numeric version id)"

# Both reassignment flags are meaningful ONLY while deleting: paired with any
# other mode they must fail loud, never be silently ignored while that mode runs.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "version --list + --move-fix-issues-to -> exit 2" 2
stderr_has "version move-fix-issues-to misuse: diagnostic" "--move-fix-issues-to is only valid with version --delete"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PSWS --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "version --list + --move-affected-issues-to -> exit 2" 2
stderr_has "version move-affected-issues-to misuse: diagnostic" "--move-affected-issues-to is only valid with version --delete"

# --project means something in exactly THREE of version's six modes: it NAMES the
# project for --list/--create, and it is --delete's opt-in ownership cross-check.
# --update/--release/--archive address the version by --id alone and never read
# it, so an unguarded --project there would be SILENTLY dropped — and now that
# --project is a documented safety net on the sibling --delete, a caller has real
# reason to believe it bit. The guard is ONE call covering all three modes, but
# each mode is asserted on its own: a mode dropped from the guard's condition
# would otherwise still pass on the strength of its siblings.
#
# All three run under the `full` selector and assert ZERO calls, so "refused
# before the network" is observed rather than assumed.
for version_unscoped_mode in --update --release --archive; do
	reset_curl_stub
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" version "$version_unscoped_mode" --id 11751 --name X --project PSWS \
		--confirmed-site foo.atlassian.net
	expect_rc "version $version_unscoped_mode + --project -> exit 2" 2
	stderr_has "version $version_unscoped_mode --project: diagnostic names the three modes that DO read --project" \
		"--project is only valid with version --list/--create/--delete"
	equals "version $version_unscoped_mode --project: ZERO curl calls (the PUT is never sent)" "$(call_count)" "0"
done

# --plan/--dry-run is the SECOND of --delete's two opt-in pre-write safety nets,
# and the graver one to lose: --update/--release/--archive implement NO preview,
# so a silently-ignored --plan means a caller who believes they asked for a dry
# run gets a REAL write instead. Same one-guard-covering-three-modes shape as the
# --project loop above, and asserted the same way — per mode, so a mode dropped
# from the condition cannot ride on its siblings.
#
# BOTH spellings are exercised because two distinct pieces of production code
# must hold for the guard to bite: jira.sh's parser folding `--dry-run` into the
# same OPT_PLAN carrier as `--plan`, and the guard reading that carrier. The
# --plan cases alone would stay green if the `--dry-run` alias were dropped from
# the parser, leaving the friendlier spelling silently ignored — exactly the
# failure this guard exists to prevent. The nested loop is scenario
# parameterization over (spelling x mode); every label names both, so a red test
# identifies the exact pair.
#
# All six run under the `full` selector and assert ZERO calls, so "refused before
# the network" is observed rather than assumed.
for version_plan_spelling in --plan --dry-run; do
	for version_unpreviewable_mode in --update --release --archive; do
		reset_curl_stub
		run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
			sh "$JIRA" version "$version_unpreviewable_mode" --id 11751 --name X "$version_plan_spelling" \
			--confirmed-site foo.atlassian.net
		expect_rc "version $version_unpreviewable_mode + $version_plan_spelling -> exit 2" 2
		stderr_has "version $version_unpreviewable_mode $version_plan_spelling: diagnostic names the only version mode that previews, and warns this one writes for REAL" \
			"--plan/--dry-run is only valid with version --delete among the version modes — version --update/--release/--archive would write for REAL"
		equals "version $version_unpreviewable_mode $version_plan_spelling: ZERO curl calls (the PUT is never sent)" "$(call_count)" "0"
	done
done

# Regression guard for the guard: the LEGITIMATE --release (neither --plan nor
# --project) must still clear validation. Run WITHOUT the stub curl for the same
# reason as the component --update guard below — reaching the curl precondition
# is the observable proof that validate_version_args returned instead of
# exiting 2.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --release --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --release WITHOUT --plan/--project -> still passes validation (exit 1 at the tool check, not exit 2)" 1
stderr_has "version --release plain: got PAST validation to the curl precondition" "curl is not installed"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --confirmed-site foo.atlassian.net
expect_rc "version --list without --project -> exit 2" 2
stderr_has "version --list no project: diagnostic" "requires --project"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version --create without --name -> exit 2" 2
stderr_has "version --create no name: diagnostic" "requires --name"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id abc --name X --confirmed-site foo.atlassian.net
expect_rc "version --update with a NON-NUMERIC --id -> exit 2" 2
stderr_has "version non-numeric id: diagnostic" "numeric version id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --update with no field to change -> exit 2" 2
stderr_has "version --update no field: diagnostic" "at least one field"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list PROJ-1 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "version with a stray positional -> exit 2" 2
stderr_has "version stray positional: diagnostic" "takes no positional argument"

# ===========================================================================
# component — project components (Phase-2d). GET /project/<K>/components is a
# PLAIN JSON ARRAY (empty [] is valid); DELETE returns 204 No Content.
# ===========================================================================
section "jira.sh — component --list: parses the PLAIN ARRAY (incl. empty [])"

reset_curl_stub
set_stub_response 1 '[{"self":"https://foo.atlassian.net/rest/api/3/component/10500","id":"10500","name":"Auth","description":"authentication","assigneeType":"PROJECT_DEFAULT"},{"id":"10501","name":"API"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --list -> exit 0" 0
file_has "component --list: GET /rest/api/3/project/PSWS/components" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/components"
stdout_has "component --list: name rendered" "Auth"
stdout_has "component --list: string id rendered" "id 10500"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --confirmed-site foo.atlassian.net --json
expect_rc "component --list empty --json -> exit 0" 0
equals "component --list empty --json: raw [] passes through" "$CUR_OUT" "[]"

reset_curl_stub
set_stub_response 1 '[]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --list empty (human) -> exit 0" 0
stdout_has "component --list empty: 'No components.'" "No components."

section "jira.sh — component --create: body project is the KEY string"

reset_curl_stub
set_stub_response 1 '{"id":"10600","name":"Billing","description":"billing"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --project PSWS --name Billing --description "billing area" \
		--lead-account-id acc-lead-123 --confirmed-site foo.atlassian.net
expect_rc "component --create -> exit 0" 0
file_has "component --create: POST /rest/api/3/component" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component"
COMP_CREATE_PROJECT=$(jq -r '.project' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --create: body 'project' is the KEY string" "$COMP_CREATE_PROJECT" "PSWS"
COMP_CREATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --create: body name" "$COMP_CREATE_NAME" "Billing"
COMP_CREATE_LEAD=$(jq -r '.leadAccountId' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --create: leadAccountId carried" "$COMP_CREATE_LEAD" "acc-lead-123"
stdout_has "component --create: machine line names the new id" "JIRA_COMPONENT_ID=10600"

section "jira.sh — component --update: PUT /component/<id> with a partial body"

reset_curl_stub
set_stub_response 1 '{"id":"10500","name":"Auth v2"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name "Auth v2" --confirmed-site foo.atlassian.net
expect_rc "component --update -> exit 0" 0
file_has "component --update: PUT /rest/api/3/component/10500" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component/10500"
file_has "component --update: uses PUT" "$CURL_STUB_ARGV_LOG" "PUT"
COMP_UPDATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --update: body carries ONLY the changed field" "$COMP_UPDATE_KEYS" '["name"]'

section "jira.sh — component --delete: DELETE /component/<id>, optional ?moveIssuesTo="

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --confirmed-site foo.atlassian.net
expect_rc "component --delete -> exit 0" 0
file_has "component --delete: DELETE /rest/api/3/component/10500" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component/10500"
file_has "component --delete: uses DELETE" "$CURL_STUB_ARGV_LOG" "DELETE"
file_not_has "component --delete: NO ?moveIssuesTo= when not given" "$CURL_STUB_ARGV_LOG" "moveIssuesTo"
stdout_has "component --delete: machine line" "JIRA_COMPONENT_DELETED=10500"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --move-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --delete --move-issues-to -> exit 0" 0
file_has "component --delete: URL carries ?moveIssuesTo=10501" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/component/10500?moveIssuesTo=10501"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --confirmed-site foo.atlassian.net --json
expect_rc "component --delete --json -> exit 0" 0
COMP_DELETE_JSON=$(printf '%s' "$CUR_OUT" | jq -r '.deleted')
equals "component --delete --json: SYNTHESIZED {deleted:true} (no 204 body to pass through)" "$COMP_DELETE_JSON" "true"

section "jira.sh — component: mode-flag + argument validation"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component with ZERO mode flags -> exit 2" 2
stderr_has "component zero modes: diagnostic" "exactly one mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --delete --id 10500 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component with TWO mode flags -> exit 2" 2
stderr_has "component two modes: diagnostic" "exactly one mode"

# A version-only mode flag (--release) passed to `component` must be rejected by
# name, not silently ignored while the one own mode (--list) runs.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --release --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --list + foreign --release -> exit 2" 2
stderr_has "component foreign --release: diagnostic names it not a component mode" "not component modes"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name X --move-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --move-issues-to WITHOUT --delete -> exit 2" 2
stderr_has "component move-issues-to misuse: diagnostic" "only valid with component --delete"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id abc --confirmed-site foo.atlassian.net
expect_rc "component --delete NON-NUMERIC --id -> exit 2" 2
stderr_has "component non-numeric id: diagnostic" "numeric component id"

# The mirror image of `version --list --move-issues-to`'s rejection above: the
# two reassignment flags are VERSION --delete flags, and cmd_component never
# reads either. Without these guards `component --delete --id N
# --move-fix-issues-to M` would exit 0 having deleted the component and SILENTLY
# dropped the reassignment — destructive AND silent. Each flag is its own guard,
# so each gets its own case: a shared one would let either be deleted and pass.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --move-fix-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --delete + foreign --move-fix-issues-to -> exit 2" 2
stderr_has "component move-fix-issues-to misuse: diagnostic names the owning command" "--move-fix-issues-to is only valid with version --delete"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --move-affected-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --delete + foreign --move-affected-issues-to -> exit 2" 2
stderr_has "component move-affected-issues-to misuse: diagnostic names the owning command" "--move-affected-issues-to is only valid with version --delete"

# Distinct code path from the two above: this guard is NOT gated on component's
# active mode, so a non-delete mode must be rejected by the SAME diagnostic —
# never allowed to run its own mode while silently ignoring the foreign flag
# (the `component --list --release` failure shape, one flag over).
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --list --project PSWS --move-fix-issues-to 10501 --confirmed-site foo.atlassian.net
expect_rc "component --list + foreign --move-fix-issues-to (guard is mode-independent) -> exit 2" 2
stderr_has "component --list move-fix-issues-to misuse: same diagnostic as --delete" "--move-fix-issues-to is only valid with version --delete"

# `version --delete`'s TWO pre-write safety nets are NOT implemented by
# `component --delete`, which is destructive and irreversible — so each must be
# REFUSED rather than silently ignored. --plan is the graver of the two: a
# caller who believes they asked for a preview and instead gets a real delete
# has been actively misled by the tool. Each flag is its own guard (a 0/1 carrier
# vs. a string carrier — see require_flag_off's header on why they cannot share
# one), so each gets its own case.
#
# Both run under the `full` selector (the stub curl IS on PATH) and assert ZERO
# calls, so "refused before the network" is a real observation rather than an
# artifact of curl being unavailable — the same shape the attach cases below use.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --plan --confirmed-site foo.atlassian.net
expect_rc "component --delete + --plan -> exit 2" 2
stderr_has "component --delete --plan: diagnostic names the only --delete that previews, and warns this one is for REAL" \
	"--plan/--dry-run is only valid with version --delete among the delete commands — component --delete would delete for REAL"
equals "component --delete --plan: ZERO curl calls (the component is NOT deleted)" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --delete + --project -> exit 2" 2
# --project IS a component flag (--list/--create take it), so the diagnostic must
# name THOSE modes — not another command, as the move-flag guards above do.
stderr_has "component --delete --project: diagnostic names component's OWN modes that take --project" \
	"--project is only valid with component --list/--create"
equals "component --delete --project: ZERO curl calls (the component is NOT deleted)" "$(call_count)" "0"

# --update carries the SAME --project guard as --delete above, for the same
# reason and with the same diagnostic: --project NAMES the project in only two
# of this command's four modes (--list/--create), and --update addresses the
# component by --id alone. Unguarded, `component --update --id N --project
# WRONGKEY` would exit 0 having edited whatever project's component N really
# belongs to, with the scope the caller stated never checked against anything.
# The key is well-formed but WRONG on purpose: --update never runs
# validate_project_key, so a malformed key would prove nothing about this
# guard — only a valid-shaped, unread key does.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name X --project WRONGKEY --confirmed-site foo.atlassian.net
expect_rc "component --update + --project -> exit 2" 2
stderr_has "component --update --project: diagnostic names component's OWN modes that take --project" \
	"--project is only valid with component --list/--create"
equals "component --update --project: ZERO curl calls (the PUT is never sent)" "$(call_count)" "0"

# ORDERING, pinned deliberately: the --project guard sits AFTER the
# at-least-one-field check, so an --update carrying ONLY a bogus --project is
# told what it is actually missing rather than being lectured about --project.
# Both branches error-then-exit, so exactly ONE diagnostic reaches stderr —
# asserting the missing-field one therefore proves the ORDER, not merely that
# the message exists. Swap the two blocks in validate_component_args and this
# case fails while the case above still passes.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --project WRONGKEY --confirmed-site foo.atlassian.net
expect_rc "component --update + --project + NO field flag -> exit 2" 2
stderr_has "component --update --project no field: the MISSING-FIELD diagnostic wins over the --project one" \
	"component --update requires at least one field to change"
equals "component --update --project no field: ZERO curl calls" "$(call_count)" "0"

# Regression guard for the guard: the LEGITIMATE --update (a field flag, no
# --project) must still clear validation. Run WITHOUT the stub curl so the run
# stops at the first precondition AFTER validation — reaching "curl is not
# installed" (exit 1) is the observable proof that validate_component_args
# returned rather than exiting 2, which a happy-path exit-0 case cannot
# distinguish from a validator that never ran at all.
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name X --confirmed-site foo.atlassian.net
expect_rc "component --update --name WITHOUT --project -> still passes validation (exit 1 at the tool check, not exit 2)" 1
stderr_has "component --update no project: got PAST validation to the curl precondition" "curl is not installed"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --name X --confirmed-site foo.atlassian.net
expect_rc "component --create without --project -> exit 2" 2
stderr_has "component --create no project: diagnostic" "requires --project"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --project PSWS --confirmed-site foo.atlassian.net
expect_rc "component --create without --name -> exit 2" 2
stderr_has "component --create no name: diagnostic" "requires --name"

# ===========================================================================
# version / component — HTTP error paths surface Jira's own diagnostic
# ===========================================================================
section "jira.sh — version --create: a non-2xx surfaces the HTTP code + Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["A version with this name already exists in this project"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name dup --confirmed-site foo.atlassian.net
expect_rc "version --create 400 -> exit 1" 1
stderr_has "version --create 400: HTTP code in diagnostic" "HTTP 400"
stderr_has "version --create 400: Jira's own error message surfaced" "already exists in this project"

section "jira.sh — version --delete: a non-2xx surfaces the HTTP code + Jira's own error message"

# DELETE /version/<id> documents FOUR statuses (Atlassian's published OpenAPI
# spec, operation deleteVersion), and the three failures are distinct scenarios
# — covered one per case below, because collapsing them hides which one the
# script actually handles.
#
# 404 means exactly one thing here: "Returned if the version is not found" —
# the id does not exist. It is NOT the permission-denied response; that is 401
# (next case). The status check must fire BEFORE the 204 "no body to parse"
# branch — otherwise a failed delete would be reported as a successful one.
reset_curl_stub
set_stub_response 1 '{"errorMessages":["The version with id 11751 does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete 404 (version not found) -> exit 1" 1
stderr_has "version --delete 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "version --delete 404: Jira's own error message surfaced" "does not exist"
stdout_not_has "version --delete 404: NO success machine line on the error path" "JIRA_VERSION_DELETED"

# 401 is the PERMISSION-DENIED response: the spec folds "the authentication
# credentials are incorrect" and "the user does not have the required
# permissions" into this one status, so an account without "Administer
# Projects" on the version's project gets 401 — never 404. This is the failure
# a real caller hits with a project-scoped token, so the wording Jira sends is
# the only thing that tells them WHY, and it must reach stderr.
reset_curl_stub
set_stub_response 1 '{"errorMessages":["You do not have permission to edit versions in this project."]}' 401
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
expect_rc "version --delete 401 (permission denied) -> exit 1" 1
stderr_has "version --delete 401: HTTP code in diagnostic" "HTTP 401"
stderr_has "version --delete 401: Jira's own permission message surfaced" \
	"You do not have permission to edit versions in this project."
stdout_not_has "version --delete 401: NO success machine line on the error path" "JIRA_VERSION_DELETED"

# 400 ("Returned if the request is invalid") is reachable through a move target
# only the SERVER can reject: the spec requires the replacement version to be in
# the same project as the deleted one and to not BE the deleted one — neither of
# which jira.sh can know locally, its own guard checking numeric shape only.
# The body is the OTHER ErrorCollection shape — a per-field `errors` MAP instead
# of `errorMessages` — so this also pins handle_http_status's `errors` branch,
# which no other case in this suite reaches.
reset_curl_stub
set_stub_response 1 '{"errorMessages":[],"errors":{"moveFixIssuesTo":"The version with id 10999 is not in the same project as the version being deleted."}}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --move-fix-issues-to 10999 --confirmed-site foo.atlassian.net
expect_rc "version --delete 400 (invalid move target) -> exit 1" 1
stderr_has "version --delete 400: HTTP code in diagnostic" "HTTP 400"
stderr_has 'version --delete 400: per-field errors MAP surfaced as "field: message"' \
	"moveFixIssuesTo: The version with id 10999 is not in the same project"
stdout_not_has "version --delete 400: NO success machine line on the error path" "JIRA_VERSION_DELETED"

section "jira.sh — component --delete: a non-2xx surfaces the HTTP code + Jira's own error message"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["The component with id 10500 does not exist"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --delete --id 10500 --confirmed-site foo.atlassian.net
expect_rc "component --delete 404 -> exit 1" 1
stderr_has "component --delete 404: HTTP code in diagnostic" "HTTP 404"
stderr_has "component --delete 404: Jira's own error message surfaced" "does not exist"

# ===========================================================================
# version / component — --json passthrough round-trips the response body on the
# mutate (create/update) paths, not just the read paths
# ===========================================================================
section "jira.sh — version --create/--update --json: the response body round-trips"

reset_curl_stub
set_stub_response 1 '{"id":"12345","name":"9.9","released":false}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --create --project PSWS --name 9.9 --confirmed-site foo.atlassian.net --json
expect_rc "version --create --json -> exit 0" 0
VER_CREATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "version --create --json: passes the 201 body through (id round-trips)" "$VER_CREATE_JSON_ID" "12345"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.9","released":false}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --name 3.10.9 --confirmed-site foo.atlassian.net --json
expect_rc "version --update --json -> exit 0" 0
VER_UPDATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "version --update --json: passes the 200 body through (id round-trips)" "$VER_UPDATE_JSON_ID" "11751"

section "jira.sh — component --create/--update --json: the response body round-trips"

reset_curl_stub
set_stub_response 1 '{"id":"10600","name":"Billing"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --project PSWS --name Billing --confirmed-site foo.atlassian.net --json
expect_rc "component --create --json -> exit 0" 0
COMP_CREATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "component --create --json: passes the 201 body through (id round-trips)" "$COMP_CREATE_JSON_ID" "10600"

reset_curl_stub
set_stub_response 1 '{"id":"10500","name":"Auth v3"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name "Auth v3" --confirmed-site foo.atlassian.net --json
expect_rc "component --update --json -> exit 0" 0
COMP_UPDATE_JSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "component --update --json: passes the 200 body through (id round-trips)" "$COMP_UPDATE_JSON_ID" "10500"

# ===========================================================================
# version / component — multi-field --update sends exactly the changed keys
# ===========================================================================
section "jira.sh — version --update: a multi-field body carries EXACTLY the changed keys"

reset_curl_stub
set_stub_response 1 '{"id":"11751","name":"3.10.2"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --update --id 11751 --name 3.10.2 --description "point release" \
		--release-date 2026-08-01 --confirmed-site foo.atlassian.net
expect_rc "version --update multi-field -> exit 0" 0
VER_UPD_MULTI_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update multi: body keys are exactly description/name/releaseDate" \
	"$VER_UPD_MULTI_KEYS" '["description","name","releaseDate"]'
VER_UPD_MULTI_DESC=$(jq -r '.description' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update multi: description value" "$VER_UPD_MULTI_DESC" "point release"
VER_UPD_MULTI_RELDATE=$(jq -r '.releaseDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "version --update multi: releaseDate value" "$VER_UPD_MULTI_RELDATE" "2026-08-01"

section "jira.sh — component --update: a multi-field body carries EXACTLY the changed keys"

reset_curl_stub
set_stub_response 1 '{"id":"10500","name":"Auth v4"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --update --id 10500 --name "Auth v4" --description "auth area" \
		--lead-account-id acc-lead-9 --confirmed-site foo.atlassian.net
expect_rc "component --update multi-field -> exit 0" 0
COMP_UPD_MULTI_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --update multi: body keys are exactly description/leadAccountId/name" \
	"$COMP_UPD_MULTI_KEYS" '["description","leadAccountId","name"]'
COMP_UPD_MULTI_LEAD=$(jq -r '.leadAccountId' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "component --update multi: leadAccountId value" "$COMP_UPD_MULTI_LEAD" "acc-lead-9"

# ===========================================================================
# attach flags — create/update --fix-version / --affects-version / --component
# resolve NAME -> id against ONE list-GET per data axis (versions once,
# components once) and merge fixVersions/versions/components:[{id}].
# ===========================================================================
section "jira.sh — create --fix-version: resolves NAME -> id, ONE versions GET, builds fixVersions:[{id}]"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0","released":false},{"id":"11752","name":"3.11.0","released":true}]' 200
set_stub_response 2 '{"key":"PSWS-1","id":"1"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version 3.11.0 --confirmed-site foo.atlassian.net
expect_rc "create --fix-version -> exit 0" 0
file_has "create --fix-version: fetches GET /project/PSWS/versions" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/versions"
equals "create --fix-version: exactly TWO calls (one versions GET + the create POST)" "$(call_count)" "2"
CREATE_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create --fix-version: body fixVersions:[{id}] with the RESOLVED id (name 3.11.0 -> 11752)" "$CREATE_FIXV" '[{"id":"11752"}]'

section "jira.sh — create: all three attach axes share ONE versions GET + ONE components GET (versions NOT refetched for affects)"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0"},{"id":"11752","name":"3.11.0"}]' 200
set_stub_response 2 '[{"id":"10500","name":"Auth"},{"id":"10501","name":"API"}]' 200
set_stub_response 3 '{"key":"PSWS-2","id":"2"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version 3.10.0 --affects-version 3.11.0 \
		--component Auth --confirmed-site foo.atlassian.net
expect_rc "create with all three attach axes -> exit 0" 0
equals "create attach: exactly THREE calls (versions once + components once + POST) — versions NOT refetched for affects" "$(call_count)" "3"
CREATE_ALL_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "create attach: --fix-version -> fixVersions:[{id}]" "$CREATE_ALL_FIXV" '[{"id":"11751"}]'
CREATE_ALL_AFFV=$(jq -c '.fields.versions' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "create attach: --affects-version -> versions:[{id}]" "$CREATE_ALL_AFFV" '[{"id":"11752"}]'
CREATE_ALL_COMP=$(jq -c '.fields.components' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "create attach: --component -> components:[{id}]" "$CREATE_ALL_COMP" '[{"id":"10500"}]'

section "jira.sh — create: repeatable --component (line-per-value accumulation, names may contain spaces)"

reset_curl_stub
set_stub_response 1 '[{"id":"10500","name":"Auth Service"},{"id":"10501","name":"API"}]' 200
set_stub_response 2 '{"key":"PSWS-3","id":"3"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --component "Auth Service" --component API --confirmed-site foo.atlassian.net
expect_rc "create with two --component (one with a space) -> exit 0" 0
CREATE_MULTI_COMP=$(jq -c '.fields.components' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create: repeated --component builds a 2-element id array; the spaced name resolved" "$CREATE_MULTI_COMP" '[{"id":"10500"},{"id":"10501"}]'

section "jira.sh — create --fix-version: a NAME containing a space resolves correctly (line-per-value accumulation, never space-split)"

reset_curl_stub
set_stub_response 1 '[{"id":"11760","name":"Sprint 42 Release"},{"id":"11761","name":"3.11.0"}]' 200
set_stub_response 2 '{"key":"PSWS-8","id":"8"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version "Sprint 42 Release" --confirmed-site foo.atlassian.net
expect_rc "create --fix-version spaced name -> exit 0" 0
CREATE_SPACED_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create --fix-version spaced: resolves the spaced name to its id (not space-split into two lookups)" "$CREATE_SPACED_FIXV" '[{"id":"11760"}]'

section "jira.sh — create --affects-version: a NAME containing a space resolves correctly"

reset_curl_stub
set_stub_response 1 '[{"id":"11770","name":"Hotfix 1 0"},{"id":"11771","name":"3.12.0"}]' 200
set_stub_response 2 '{"key":"PSWS-10","id":"10"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --affects-version "Hotfix 1 0" --confirmed-site foo.atlassian.net
expect_rc "create --affects-version spaced name -> exit 0" 0
CREATE_SPACED_AFFV=$(jq -c '.fields.versions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "create --affects-version spaced: resolves the spaced name to its id" "$CREATE_SPACED_AFFV" '[{"id":"11770"}]'

section "jira.sh — create attach: an unknown NAME fails loud (exit 1, no create POST)"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --fix-version 9.9.9 --confirmed-site foo.atlassian.net
expect_rc "create --fix-version not found -> exit 1" 1
stderr_has "create attach not-found: names the missing name + project" "fix version '9.9.9' not found in project PSWS"
equals "create attach not-found: NO create POST issued (only the versions GET fired)" "$(call_count)" "1"

section "jira.sh — create attach: a DUPLICATE display name fails loud as ambiguous (exit 1, no create POST)"

reset_curl_stub
set_stub_response 1 '[{"id":"10500","name":"Auth"},{"id":"10501","name":"Auth"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --component Auth --confirmed-site foo.atlassian.net
expect_rc "create --component ambiguous -> exit 1" 1
stderr_has "create attach ambiguous: fails loud" "ambiguous"
equals "create attach ambiguous: no create POST issued" "$(call_count)" "1"

section "jira.sh — update: attach flags resolve against the TICKET's project; a lone attach flag is a valid change"

reset_curl_stub
set_stub_response 1 '[{"id":"11752","name":"3.11.0"}]' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-5 --fix-version 3.11.0 --confirmed-site foo.atlassian.net
expect_rc "update with ONLY --fix-version -> exit 0 (attach counts as a field to change)" 0
file_has "update --fix-version: fetches versions for the ticket's project (PSWS from PSWS-5)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/project/PSWS/versions"
UPDATE_FIXV=$(jq -c '.fields.fixVersions' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "update --fix-version: PUT body carries fixVersions:[{id}]" "$UPDATE_FIXV" '[{"id":"11752"}]'

section "jira.sh — update attach: an unknown component NAME fails loud (exit 1, no update PUT)"

reset_curl_stub
set_stub_response 1 '[{"id":"10500","name":"Auth"}]' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-6 --component Nonexistent --confirmed-site foo.atlassian.net
expect_rc "update --component not found -> exit 1" 1
stderr_has "update attach not-found: names the missing component + project" "component 'Nonexistent' not found in project PSWS"
equals "update attach not-found: NO update PUT issued (only the components GET fired)" "$(call_count)" "1"

# ===========================================================================
# attach — issue attachment upload / list / delete (Cycle A)
# Fixtures use the REAL live shapes: upload -> a JSON ARRAY (one obj per file),
# id is a STRING, `thumbnail` present ONLY for images; list -> .fields.attachment
# is a plain ARRAY (may be []); delete -> 204 No Content.
# ===========================================================================
# Real attachment objects (probed live). ATTACH_OBJ_PNG carries a thumbnail
# (image); ATTACH_OBJ_TXT does NOT (non-image) — matches live behavior.
ATTACH_OBJ_PNG='{"self":"https://foo.atlassian.net/rest/api/3/attachment/303980","id":"303980","filename":"diagram.png","author":{"accountId":"acc-1","displayName":"A. Gent"},"created":"2026-07-25T17:06:06.495+0200","size":43,"mimeType":"image/png","content":"https://foo.atlassian.net/rest/api/3/attachment/content/303980","thumbnail":"https://foo.atlassian.net/rest/api/3/attachment/thumbnail/303980"}'
ATTACH_OBJ_TXT='{"self":"https://foo.atlassian.net/rest/api/3/attachment/303981","id":"303981","filename":"notes.txt","author":{"accountId":"acc-1","displayName":"A. Gent"},"created":"2026-07-25T17:06:07.100+0200","size":128,"mimeType":"text/plain","content":"https://foo.atlassian.net/rest/api/3/attachment/content/303981"}'

section "jira.sh — attach upload: single file -> POST /issue/<KEY>/attachments, multipart, no JSON content-type"

reset_curl_stub
ATTACH_UP1="$WORK/upload-one.txt"
printf 'hello' >"$ATTACH_UP1"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP1" --confirmed-site foo.atlassian.net
expect_rc "attach upload single -> exit 0" 0
file_has "attach upload: POST goes to /issue/PSWS-1/attachments" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/attachments"
argv_log_has_token "attach upload: request method is POST" "POST"
argv_log_has_token "attach upload: carries X-Atlassian-Token: no-check" "X-Atlassian-Token: no-check"
argv_log_has_token "attach upload: one -F file part for the file" "file=@\"$ATTACH_UP1\""
argv_log_not_has_token "attach upload: NO JSON content-type header" "Content-Type: application/json"
equals "attach upload single: exactly ONE curl call" "$(call_count)" "1"
stdout_has "attach upload: machine line names the parsed STRING id from the array" "JIRA_ATTACHMENT_ID=303980"
stdout_has "attach upload: machine line names the filename" "JIRA_ATTACHMENT_FILENAME=diagram.png"

section "jira.sh — attach upload: multiple --file -> one -F part each, one POST, one machine line pair per file"

reset_curl_stub
ATTACH_UP_A="$WORK/multi-a.txt"
ATTACH_UP_B="$WORK/multi-b.png"
printf 'a' >"$ATTACH_UP_A"
printf 'b' >"$ATTACH_UP_B"
set_stub_response 1 "[$ATTACH_OBJ_PNG,$ATTACH_OBJ_TXT]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP_A" --file "$ATTACH_UP_B" --confirmed-site foo.atlassian.net
expect_rc "attach upload multi -> exit 0" 0
argv_log_has_token "attach upload multi: -F part for file A" "file=@\"$ATTACH_UP_A\""
argv_log_has_token "attach upload multi: -F part for file B" "file=@\"$ATTACH_UP_B\""
equals "attach upload multi: still exactly ONE curl call (all files in one request)" "$(call_count)" "1"
stdout_has "attach upload multi: id from array element 1" "JIRA_ATTACHMENT_ID=303980"
stdout_has "attach upload multi: id from array element 2" "JIRA_ATTACHMENT_ID=303981"

section "jira.sh — attach upload: a path containing ';'/',' is DOUBLE-QUOTED so curl can't split it into a form parameter"

reset_curl_stub
# A filename crafted to look like a curl -F parameter-injection: an unquoted
# `-F file=@/tmp/a;type=texthtml` would make curl set the part's mime, and a
# ',' would start a whole new form part. The path must be wrapped in double-
# quotes to neutralize BOTH the ';' and the ',' (no '/' here — that would be a
# real path separator, not part of the filename we are testing).
ATTACH_EVIL="$WORK/evil;type=texthtml,x.png"
printf 'x' >"$ATTACH_EVIL"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_EVIL" --confirmed-site foo.atlassian.net
expect_rc "attach upload with ';'/','-laden path -> exit 0" 0
argv_log_has_token "attach filename-safety: the -F value keeps the whole path DOUBLE-QUOTED as the filename" "file=@\"$ATTACH_EVIL\""
argv_log_not_has_token "attach filename-safety: the UNQUOTED (injectable) form is NOT what was built" "file=@$ATTACH_EVIL"

reset_curl_stub
# A path carrying a literal '"' (and a ',') is the sharper attack: the '"'
# is special INSIDE curl's OWN double-quoted -F value, so mere wrapping is not
# enough — an unescaped '"' would close the quotes early and the trailing ','
# would then start a second @-file part / mime override. The value must be
# ESCAPED (backslash first, then the quote) before wrapping. The expected token
# is derived with the SAME escaping the script applies, so this asserts the
# escaped+quoted form is what was built — and that the raw unescaped breakout
# form (which contains a bare '"' before the ',') was NOT.
ATTACH_QUOTE="$WORK/q\",x.png"
printf 'x' >"$ATTACH_QUOTE"
ATTACH_QUOTE_ESC=$(printf '%s' "$ATTACH_QUOTE" | sed 's/\\/\\\\/g; s/"/\\"/g')
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_QUOTE" --confirmed-site foo.atlassian.net
expect_rc "attach upload with a '\"'/','-laden path -> exit 0" 0
argv_log_has_token "attach filename-safety: the '\"' is ESCAPED then quoted in the -F value" "file=@\"$ATTACH_QUOTE_ESC\""
argv_log_not_has_token "attach filename-safety: the raw (breakout) '\"' form with a bare quote was NOT built" "file=@\"$ATTACH_QUOTE\""

section "jira.sh — attach upload --json: raw array passes through, NO machine line"

reset_curl_stub
ATTACH_UP_JSON="$WORK/upload-json.txt"
printf 'j' >"$ATTACH_UP_JSON"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP_JSON" --confirmed-site foo.atlassian.net --json
expect_rc "attach upload --json -> exit 0" 0
stdout_has "attach upload --json: raw array body passes through (the array element)" '"id":"303980"'
stdout_not_has "attach upload --json: NO machine line emitted (passthrough only)" "JIRA_ATTACHMENT_ID"

section "jira.sh — attach upload: a transport error (413) surfaces Jira's message + the HTTP code, exit 1"

reset_curl_stub
ATTACH_UP_413="$WORK/upload-413.txt"
printf 'big' >"$ATTACH_UP_413"
set_stub_response 1 '{"errorMessages":["The attachment exceeds the maximum size."]}' 413
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_UP_413" --confirmed-site foo.atlassian.net
expect_rc "attach upload 413 -> exit 1 (handle_http_status wired through jira_curl_multipart)" 1
stderr_has "attach upload 413: surfaces Jira's own error message" "The attachment exceeds the maximum size."
stderr_has "attach upload 413: names the HTTP code" "HTTP 413"

section "jira.sh — attach --list: parses .fields.attachment ARRAY (incl. empty [])"

reset_curl_stub
set_stub_response 1 "{\"fields\":{\"attachment\":[$ATTACH_OBJ_PNG,$ATTACH_OBJ_TXT]}}" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-2 --list --confirmed-site foo.atlassian.net
expect_rc "attach --list -> exit 0" 0
file_has "attach --list: GET /issue/PSWS-2?fields=attachment" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2?fields=attachment"
stdout_has "attach --list: string id rendered" "303980"
stdout_has "attach --list: filename rendered" "diagram.png"
stdout_has "attach --list: mimeType rendered" "text/plain"

reset_curl_stub
set_stub_response 1 "{\"fields\":{\"attachment\":[$ATTACH_OBJ_PNG]}}" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-2 --list --confirmed-site foo.atlassian.net --json
expect_rc "attach --list --json -> exit 0" 0
stdout_has "attach --list --json: raw body passes through (the array element)" '"id":"303980"'

reset_curl_stub
set_stub_response 1 '{"fields":{"attachment":[]}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-2 --list --confirmed-site foo.atlassian.net
expect_rc "attach --list empty -> exit 0" 0
stdout_has "attach --list empty: 'No attachments.'" "No attachments."

section "jira.sh — attach --delete: DELETE /attachment/<id>, 204 -> machine line; --json synthesized"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --delete -> exit 0" 0
file_has "attach --delete: DELETE /rest/api/3/attachment/303980" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/attachment/303980"
stdout_has "attach --delete: machine line" "JIRA_ATTACHMENT_DELETED=303980"

reset_curl_stub
set_stub_response 1 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --confirmed-site foo.atlassian.net --json
expect_rc "attach --delete --json -> exit 0" 0
ATTACH_DELETE_JSON=$(printf '%s' "$CUR_OUT" | jq -r '.deleted')
equals "attach --delete --json: SYNTHESIZED {deleted:true} (no 204 body to pass through)" "$ATTACH_DELETE_JSON" "true"
ATTACH_DELETE_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "attach --delete --json: SYNTHESIZED id echoes the deleted --id" "$ATTACH_DELETE_ID" "303980"

section "jira.sh — attach: mode-flag + argument validation (all before any network call)"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$WORK/does-not-exist.txt" --confirmed-site foo.atlassian.net
expect_rc "attach upload with an unreadable --file -> exit 2" 2
stderr_has "attach unreadable --file: diagnostic names the flag" "--file does not exist or is not readable"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id not-a-number --confirmed-site foo.atlassian.net
expect_rc "attach --delete with a NON-NUMERIC --id -> exit 2" 2

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --confirmed-site foo.atlassian.net
expect_rc "attach with ZERO modes (no --file/--list/--delete) -> exit 2" 2

reset_curl_stub
ATTACH_TWO="$WORK/two-mode.txt"
printf 'x' >"$ATTACH_TWO"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_TWO" --list --confirmed-site foo.atlassian.net
expect_rc "attach with TWO modes (--file + --list) -> exit 2" 2

# A foreign version/component mode flag on attach is rejected by name AND folded
# into the exactly-one count, so it can never slip past unnoticed.
ATTACH_FOREIGN="$WORK/foreign-mode.txt"
printf 'x' >"$ATTACH_FOREIGN"
for foreign_mode in --create --update --release --archive; do
	reset_curl_stub
	run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" attach PSWS-1 --file "$ATTACH_FOREIGN" "$foreign_mode" --confirmed-site foo.atlassian.net
	expect_rc "attach upload + foreign mode $foreign_mode -> exit 2" 2
	stderr_has "attach foreign-mode $foreign_mode: diagnostic names it as not an attach mode" "are not attach modes"
done

# --id belongs to the TWO modes that address an ATTACHMENT (--delete, --download),
# so the needle is the FULL widened sentence naming both: a regression that dropped
# --download from the message would still satisfy the bare
# "--id is only valid with attach --delete" prefix this case used to assert.
reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --list --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --id with neither --delete nor --download -> exit 2" 2
stderr_has "attach --id-outside-delete-or-download: the diagnostic names BOTH id-addressed modes" \
	"--id is only valid with attach --delete or attach --download"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --delete --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --delete WITH a stray ticket key -> exit 2 (delete addresses by --id, not KEY)" 2

# The three reassignment targets belong to version/component --delete. attach
# shares their OPT_* carriers but never reads one, so an unguarded
# `attach --delete --id N --move-…-to M` would exit 0 having DELETED the
# attachment and silently dropped the flag — destructive AND quiet, the worst
# pairing. Each flag is a SEPARATE guard naming a DIFFERENT owning command, so
# each gets its own case: a shared or looped assertion would let one guard be
# deleted, or one message be wrong, and still pass.
#
# Every case runs under the `full` selector (the stub curl IS on PATH) and
# asserts ZERO calls, so "rejected before the network" is a real observation
# rather than an artifact of curl being unavailable.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --move-fix-issues-to 11752 --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --move-fix-issues-to -> exit 2" 2
stderr_has "attach --move-fix-issues-to: diagnostic names THAT flag and its owning command" \
	"--move-fix-issues-to is only valid with version --delete"
equals "attach --move-fix-issues-to: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --move-affected-issues-to 11753 --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --move-affected-issues-to -> exit 2" 2
stderr_has "attach --move-affected-issues-to: diagnostic names THAT flag and its owning command" \
	"--move-affected-issues-to is only valid with version --delete"
equals "attach --move-affected-issues-to: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

# --move-issues-to is component --delete's, not version's — the diagnostic must
# name the command that actually accepts it, never a sibling's.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --move-issues-to 20501 --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --move-issues-to -> exit 2" 2
stderr_has "attach --move-issues-to: diagnostic names component --delete as the owner, not version" \
	"--move-issues-to is only valid with component --delete"
equals "attach --move-issues-to: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

# `attach --delete` is the third destructive delete in the engine and implements
# neither of `version --delete`'s pre-write safety nets, so it carries component
# --delete's identical pair of guards. The diagnostics are NOT identical to
# component's, and deliberately so: each names the command it is really talking
# about, so a caller is never pointed at a sibling's behaviour.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --plan --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --plan -> exit 2" 2
stderr_has "attach --delete --plan: diagnostic names attach --delete itself as the one that would delete for REAL" \
	"--plan/--dry-run is only valid with version --delete among the delete commands — attach --delete would delete for REAL"
equals "attach --delete --plan: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

# attach addresses an issue by KEY and an attachment by --id; it has no
# project-scoped mode at all, so --project can only ever be a mistake here — and
# the diagnostic says exactly that rather than naming modes attach does not have.
#
# THE GUARD SITS AT COMMAND SCOPE, so it must be asserted ONCE PER MODE, not once
# per command. Per-branch it covered --delete alone and left upload, --list and
# --download accepting the flag and silently dropping it, and a single case can
# never tell "one shared guard at command scope" from "one guard inside the
# --delete branch" — only four cases whose four different modes all refuse can.
# All four assert the SAME diagnostic, deliberately: one guard means one wording,
# and a per-mode phrase is how four copies silently stop agreeing.
ATTACH_PROJECT_SCOPE_DIAG="--project is only valid with project-scoped commands (attach addresses its target by KEY/--id)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "attach --delete + --project -> exit 2" 2
stderr_has "attach --delete --project: diagnostic states attach addresses its target by KEY/--id, never by project" \
	"$ATTACH_PROJECT_SCOPE_DIAG"
equals "attach --delete --project: ZERO curl calls (the attachment is NOT deleted)" "$(call_count)" "0"

# UPLOAD. The invocation has to be otherwise WELL-FORMED to reach a guard that
# runs last: the ticket key and a really-readable --file are what carry the run
# past validate_attach_args's own earlier refusals, so the diagnostic asserted
# below is unambiguously the --project one and not a missing-key or unreadable-
# file exit that happens to share exit 2.
reset_curl_stub
ATTACH_PROJECT_UPLOAD_FILE="$WORK/project-scope-upload.txt"
printf 'x' >"$ATTACH_PROJECT_UPLOAD_FILE"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --file "$ATTACH_PROJECT_UPLOAD_FILE" --project PSWS --confirmed-site foo.atlassian.net
expect_rc "attach upload + --project -> exit 2" 2
stderr_has "attach upload --project: the same command-scope diagnostic (the guard is not --delete's alone)" \
	"$ATTACH_PROJECT_SCOPE_DIAG"
equals "attach upload --project: ZERO curl calls (nothing was uploaded)" "$(call_count)" "0"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --list --project PSWS --confirmed-site foo.atlassian.net
expect_rc "attach --list + --project -> exit 2" 2
stderr_has "attach --list --project: the same command-scope diagnostic (a READ mode refuses it too)" \
	"$ATTACH_PROJECT_SCOPE_DIAG"
equals "attach --list --project: ZERO curl calls (the listing was never requested)" "$(call_count)" "0"

# The FOURTH mode's case is not here: --download's refusal carries an extra claim
# (the caller-named local file is absent) that needs the media-flow queue and
# assert_path_absent, both declared further down — so it lives with the other
# --download sections, under its own "the command-scope refusal reaches the
# fourth mode too" heading.

section "jira.sh — attach --download: target-shape validation (exit 2, before any network call)"

# --download is attach's FOURTH mode and its THIRD write (see the read-only
# block below). It addresses an attachment by --id exactly as --delete does,
# so each case below mirrors --delete's own equivalent above rather than
# inventing a new shape — the point being that the two id-addressed modes
# agree on what a well-formed target is.
#
# WHY NO ZERO-CALL ASSERTION on these, unlike --delete's guards above. Those
# guards each protect a DESTRUCTIVE mode, so "the attachment was not deleted"
# is a distinct claim worth its own assertion. --download mutates nothing at the
# site, and a `call_count` of 0 here would additionally be NON-DISCRIMINATING:
# every one of these invocations aborts inside validate_attach_args, which is
# reached long before the transport, so 0 is what a REMOVED guard reports too.
# The exit code plus the guard's OWN diagnostic are what separate the guards.
ATTACH_DL_DEST="$WORK/download-dest.bin"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_DEST" --list --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download + --list (TWO modes) -> exit 2" 2
stderr_has "attach --download + --list: the exactly-one-mode diagnostic names --download among the four modes" \
	"attach requires exactly one mode: --file PATH (upload), --list, --delete --id N, or --download PATH --id N"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PSWS-1 --download "$ATTACH_DL_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download WITH a stray ticket key -> exit 2 (download addresses by --id, not KEY)" 2
stderr_has "attach --download stray key: the diagnostic names --download (not --delete) and echoes the key" \
	"attach --download takes no ticket key (it downloads by --id): PSWS-1"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_DEST" --confirmed-site foo.atlassian.net
expect_rc "attach --download with NO --id -> exit 2" 2
stderr_has "attach --download without --id: diagnostic" "attach --download requires --id N"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_DEST" --id not-a-number --confirmed-site foo.atlassian.net
expect_rc "attach --download with a NON-NUMERIC --id -> exit 2" 2
stderr_has "attach --download non-numeric --id: diagnostic names the numeric-attachment-id requirement" \
	"invalid --id (must be a numeric attachment id): not-a-number"

section "jira.sh — attach --download: the destination's local preconditions (exit 2, before any network call)"

# REFUSING AN EXISTING DESTINATION IS THE WHOLE OVERWRITE POLICY — there is no
# --force. The refusal must therefore be asserted on both shapes the guard
# accepts, because they are two DIFFERENT tests of two different operators and
# only one of them is the obvious one:
#   * a real file, caught by `-e`;
#   * a DANGLING symlink, which `-e` reports as absent and only `-L` catches —
#     the case a `-e`-only guard would silently overwrite (following the link,
#     writing through it to wherever it points).
ATTACH_DL_EXISTING="$WORK/download-existing.bin"
printf 'do not clobber me' >"$ATTACH_DL_EXISTING"

reset_curl_stub
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_EXISTING" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download onto an EXISTING file -> exit 2" 2
stderr_has "attach --download existing dest: the diagnostic names the refusal AND echoes the path" \
	"--download destination already exists (refusing to overwrite it): $ATTACH_DL_EXISTING"
file_has "attach --download existing dest: the file's original content is untouched" \
	"$ATTACH_DL_EXISTING" "do not clobber me"

reset_curl_stub
ATTACH_DL_DANGLING="$WORK/download-dangling.bin"
ln -s "$WORK/target-that-does-not-exist" "$ATTACH_DL_DANGLING"
run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_DANGLING" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download onto a DANGLING SYMLINK -> exit 2 (the -L half, which -e misses)" 2
stderr_has "attach --download dangling symlink: the same already-exists refusal, naming the link path" \
	"--download destination already exists (refusing to overwrite it): $ATTACH_DL_DANGLING"

# ===========================================================================
# attach --download past validation: the TWO-REQUEST media flow.
#
# The mechanism, probed live and driven here exactly as Cycle B below drives its
# own identical first request: GET /attachment/content/<id> answers a 303 whose
# Location is https://api.media.atlassian.com/file/<UUID>/binary?token=<JWT>,
# the redirect is HELD (no -L), and only then is a SECOND GET aimed at that
# Location by the engine itself. The stub can hand a Location back at all
# because the request asks for a header dump (-D) — see lib/curl-stub.sh's
# set_stub_headers.
#
# WHY ITS OWN 303 CONSTANTS rather than Cycle B's MEDIA_303_HEADERS: that
# block's Location is consumed by resolve_media_uuid, which keeps the UUID and
# throws the rest away, so its JWT sentinel only ever has to prove NON-leakage.
# --download's Location is consumed by resolve_media_download_url and then SPENT
# on a real second request, so these cases assert the full URL reached the wire
# VERBATIM — and the untrusted-host case needs a hostile variant that has no
# reader anywhere else in the suite.
#
# WHERE "THE WIRE" IS FOR CALL 2, and why it is not the argv log. That
# token-bearing URL never appears in call 2's argv: download_attachment_content
# hands it to curl as a one-directive `-K -` STDIN config, under the same
# never-on-argv rule the site credential follows. So every claim about what call
# 2 was actually sent is made against $CURL_STUB_STDIN_LOG_DIR/call-2.stdin (see
# lib/curl-stub.sh's own note on why that record exists), and the argv log is
# where this block asserts the URL's ABSENCE instead.
# ===========================================================================
ATTACH_DL_UUID="abcdef01-2345-6789-abcd-ef0123456789"
ATTACH_DL_JWT="DOWNLOADJWT0xFEEDFACE"
ATTACH_DL_MEDIA_URL="https://api.media.atlassian.com/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_JWT"

# attach_dl_303_headers LOCATION -> a 303 header block whose Location is exactly
# LOCATION. Every case in this block drives the SAME first response and differs
# only in that one header, so it is built here instead of pasted per case — and
# it has eight call sites below, which is well past the point at which a literal
# per case stops being readable.
#
# EVERY LINE ENDS CRLF (\015\n), because real `curl -D` output does. The CR is
# not decoration: resolve_media_download_url strips it with `tr -d '\015'` before
# returning the Location, and that strip is the ONE place in the engine that
# reads raw CRLF (strip_control_ansi's own note turns on the fact that nothing
# else does). With an LF-only fixture the strip has nothing to remove, so
# DELETING IT ENTIRELY leaves the byte-exact stdin-config golden below passing —
# a fixture that quietly voided an assertion. The golden holds the CR-free URL,
# so with CRLF here the strip is specifically what keeps that compare green.
attach_dl_303_headers() {
	printf 'HTTP/2 303\015\nLocation: %s\015\ncontent-length: 0\015' "$1"
}

ATTACH_DL_303_HEADERS=$(attach_dl_303_headers "$ATTACH_DL_MEDIA_URL")
ATTACH_DL_UNTRUSTED_HOST="evil.example.com"
ATTACH_DL_UNTRUSTED_303_HEADERS=$(attach_dl_303_headers \
	"https://$ATTACH_DL_UNTRUSTED_HOST/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_JWT")

# The FOUR NEAR-MISS authorities, and why evil.example.com above cannot stand in
# for any of them: it fails an exact match, a suffix match, a prefix match and a
# substring match ALIKE, so every one of those pins — including three BROKEN ones
# — refuses it, and a case built on it therefore cannot tell a correct pin from a
# regressed one. Each authority here is refused by the real whole-string equality
# test while PASSING one specific weakening of it:
#   * evil-api.media.atlassian.com            passes `*api.media.atlassian.com`
#   * api.media.atlassian.com.evil.com        passes `api.media.atlassian.com*`
#   * api.media.atlassian.com@evil.example.com — a userinfo trick: the bytes
#     before the `@` are NOT the host curl would connect to, but they are exactly
#     what a "does it start with the media host" test sees
#   * api.media.atlassian.com?token=…         a BARE AUTHORITY with no path,
#     which is the shape resolve_media_download_url's own header warns about: the
#     `s#/.*##` host extraction finds no `/` to cut at, so the JWT lands INSIDE
#     the substring that function calls "the host" — hence the separate assertion
#     that the diagnostic still echoes neither.
ATTACH_DL_NEARMISS_SUFFIX="evil-api.media.atlassian.com"
ATTACH_DL_NEARMISS_PREFIX="api.media.atlassian.com.evil.com"
ATTACH_DL_NEARMISS_USERINFO="api.media.atlassian.com@evil.example.com"
ATTACH_DL_NEARMISS_BARE="api.media.atlassian.com?token=$ATTACH_DL_JWT"

# The generic media body most cases below queue. Deliberately NOT JSON: the
# media CDN's body is opaque bytes the engine must install verbatim and never
# parse.
#
# Same golden-FILE-is-the-source-of-truth shape as ATTACH_DL_CTRL_GOLDEN below,
# so the queued body and the expected bytes can never drift, and so every
# destination-fidelity claim over this payload can be a byte-exact `cmp` rather
# than a string compare (see assert_file_bytes_identical's own note). The payload
# carries no trailing newline, which is what keeps the read-back below faithful —
# command substitution would strip one.
ATTACH_DL_PAYLOAD_GOLDEN="$WORK/download-payload-golden.bin"
printf 'ATTACHMENT-BYTES-0xC0FFEE' >"$ATTACH_DL_PAYLOAD_GOLDEN"
ATTACH_DL_PAYLOAD=$(cat "$ATTACH_DL_PAYLOAD_GOLDEN")

# The happy path's own payload carries RAW CONTROL BYTES — a CR (\015) and two
# ESC (\033) sequences — because the claim under test is "opaque bytes, installed
# VERBATIM, never parsed or transformed", and a real attachment is typically
# binary. A printable-ASCII payload cannot distinguish a verbatim install from
# one that grew a strip_control_ansi (the transform every OTHER untrusted string
# in this engine legitimately passes through, including the filename and mimeType
# `attach --list` renders two sections above) on the downloaded body: both
# install those bytes identically.
#
# The golden FILE is the single source of truth and the payload string is read
# back from it, so the two can never drift; the compare is `cmp` against that
# file rather than `$(cat DEST)` for the reason assert_file_bytes_identical's own
# note gives.
ATTACH_DL_CTRL_GOLDEN="$WORK/download-ctrl-golden.bin"
printf 'BYTES\015CR\033[31mESC\033[0mEND' >"$ATTACH_DL_CTRL_GOLDEN"
ATTACH_DL_CTRL_PAYLOAD=$(cat "$ATTACH_DL_CTRL_GOLDEN")

# The EXACT bytes download_attachment_content must pipe into `-K -` for call 2:
# curl's config syntax is one `url = "<value>"` directive, newline-terminated,
# with the value run through curl_config_escape. This media URL contains neither
# a `"` nor a `\`, so the escape is an identity here and the golden can be built
# with a plain printf — which is the point: a regression that mangled, truncated
# or re-encoded the URL, dropped the quoting, or emitted a second directive
# (a `user = …` credential, say) fails a byte-for-byte compare against this file
# while still passing any substring needle over the same content.
ATTACH_DL_STDIN_GOLDEN="$WORK/download-stdin-golden.txt"
printf 'url = "%s"\n' "$ATTACH_DL_MEDIA_URL" >"$ATTACH_DL_STDIN_GOLDEN"

# queue_attach_download_media_flow MEDIA_BODY MEDIA_CODE — the stub queue every
# case that gets PAST the Location check drives: call 1 the 303 + a trusted
# media Location, call 2 the media fetch answered with MEDIA_BODY/MEDIA_CODE.
# It is the DEFAULT queue for this whole feature — most cases below share it and
# differ only in what that second call answers (or, for every pre-flight
# refusal, in the fact that the queue is a COUNTERFACTUAL the run must never
# consume). A raw call-site count is deliberately not stated: it has grown with
# every case added since, and a number in a comment nothing verifies is worth
# less than the rule. The cases that do NOT use it are exactly those whose FIRST
# call is the thing under test — a non-3xx status, a hostile/malformed/absent
# Location, a Location carrying different bytes, and the resolve's own network
# failure (which queues nothing at all) — and each queues its own.
queue_attach_download_media_flow() {
	set_stub_response 1 '' 303
	set_stub_headers 1 "$ATTACH_DL_303_HEADERS"
	set_stub_response 2 "$1" "$2"
}

# assert_path_absent NAME PATH — nothing exists at PATH: no file, no directory,
# no symlink. Deliberately not expressible as file_not_has, which passes BOTH
# when the path is absent and when it exists carrying something else — and "the
# destination was never created" is exactly the half of that a failed download
# has to prove. Same inline shape as the discover-traversal case above; a named
# helper because many cases below make the claim, and about TWO different kinds
# of path (no count is stated, for the reason
# queue_attach_download_media_flow's header gives):
#   * the caller-named DESTINATION, which a refused download must not create;
#   * lib/curl-stub.sh's per-call `-K -` STDIN CONFIG record, whose absence is
#     how a case proves the second request was never even handed its URL — the
#     one assertion that discriminates a working host pin from a removed one
#     (see assert_download_location_refused's header for why the argv needles
#     cannot).
assert_path_absent() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -e "$2" ] || [ -L "$2" ]; then fail "$1" "the path exists but should not: $2"
	else pass "$1"; fi
}

# assert_no_dest_siblings NAME DEST — the download left NOTHING next to DEST:
# no path whose name begins with DEST exists, other than DEST itself. A separate
# claim from assert_path_absent's, and the one that distinguishes "wrote nothing"
# from "wrote a truncated payload next to the destination and left it there" —
# litter a later caller could mistake for a real download.
#
# THE GLOB IS DELIBERATELY MECHANISM-AGNOSTIC — `"$DEST"*`, not a list of
# known staging-name infixes. download_attachment_content stages nothing beside
# the destination at all any more (it stages inside $WORKDIR; see the
# staging-location section below for the claim that pins that), so a name-shaped
# assertion could only pin the ABSENCE of a mechanism that no longer exists —
# green for every conceivable regression that invented a differently-named one.
# A prefix glob holds regardless of what a future staging scheme calls itself.
#
# `-e` plus an explicit `-L` arm, rather than `-d`/`-f`: an entity of any kind
# beside the destination is litter, a dangling symlink very much included.
assert_no_dest_siblings() {
	TESTS_RUN=$((TESTS_RUN + 1))
	ands_leftovers=""
	for ands_candidate in "$2"*; do
		[ "$ands_candidate" != "$2" ] || continue
		if [ -e "$ands_candidate" ] || [ -L "$ands_candidate" ]; then
			ands_leftovers="$ands_leftovers $ands_candidate"
		fi
	done
	if [ -n "$ands_leftovers" ]; then fail "$1" "leftover sibling(s) beside the destination:$ands_leftovers"
	else pass "$1"; fi
}

# assert_file_bytes_identical NAME DEST GOLDEN — DEST's bytes are EXACTLY
# GOLDEN's. `cmp` rather than an `equals` over `$(cat DEST)`, because the payload
# whose fidelity this asserts carries raw control bytes: command substitution
# strips trailing newlines and a shell variable cannot hold a NUL, so a string
# compare silently stops being byte-exact at precisely the point a binary
# attachment stops looking like text.
assert_file_bytes_identical() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -f "$2" ] && cmp -s "$2" "$3"; then pass "$1"
	else fail "$1" "the destination's bytes are not identical to the golden payload: $2"; fi
}

# argv_call_token_count (lib/curl-stub.sh) is the per-call exact-token count the
# download flow's call-2 claims below are built on: call 2 is the ONE request in
# the engine aimed at a host it did not build from $CONFIRMED_HOST, chosen from
# an untrusted response header, so its transport hardening is exactly the claim a
# log-wide assertion cannot make (call 1 legitimately carries -K, and either call
# carrying --proto satisfies a log-wide --proto needle).

# argv_call_flag_value N FLAG -> the argv token immediately FOLLOWING FLAG's
# first occurrence inside call N's own block, or nothing if FLAG is absent. FLAG
# must be free of regex metacharacters (every caller passes a bare `-X`-style
# option), and the `{n;p;q;}` form is request_method_sequence's, scoped to one
# call.
#
# WHY A COUNT IS NOT ENOUGH for the one caller that needs this: call 2 now
# carries `-K`, so `argv_call_token_count 2 -K` can no longer distinguish "-K -,
# the stdin config holding only the media URL" from "-K <the site credential
# file>" — which is precisely the regression that would send Jira's token to
# api.media.atlassian.com. Only the flag's VALUE separates them.
argv_call_flag_value() {
	sed -n "/^CALL_$1_BEGIN\$/,/^CALL_$1_END\$/p" "$CURL_STUB_ARGV_LOG" \
		| sed -n "/^$2\$/{n;p;q;}"
}

# argv_call_first_token N -> call N's FIRST argv token, or nothing when call N
# made no entry in the log. Line 1 of the extracted block is the CALL_N_BEGIN
# marker, so line 2 is argv[1] (lib/curl-stub.sh logs `"$@"`, never $0).
#
# POSITION, NOT PRESENCE, and only this helper can say it: argv_log_has_token
# "-q" cannot distinguish first from fifth. WHY first-vs-fifth decides anything
# is http.sh's own header (`-q` and the .curlrc read it suppresses) — not
# restated here.
argv_call_first_token() {
	sed -n "/^CALL_$1_BEGIN\$/,/^CALL_$1_END\$/p" "$CURL_STUB_ARGV_LOG" \
		| sed -n '2p'
}

# argv_call_token_index N TOKEN -> the 1-based position of TOKEN's first
# occurrence within call N's own argv, or nothing when TOKEN is absent from it.
# The `2,$p` drops the CALL_N_BEGIN marker so position 1 really is argv[1]; the
# match is the same exact-LINE grep argv_log_has_token uses, so a needle carrying
# a regex metacharacter cannot match something else.
#
# RELATIVE POSITION, which neither a count nor a first-token test can express, and
# the claim assert_argv_flag_order below builds on it for.
argv_call_token_index() {
	sed -n "/^CALL_$1_BEGIN\$/,/^CALL_$1_END\$/p" "$CURL_STUB_ARGV_LOG" \
		| sed -n '2,$p' | grep -Fxn -- "$2" | sed -n '1s/:.*//p'
}

# assert_argv_flag_order NAME N EARLIER LATER — within call N's argv, both flags
# are present AND EARLIER precedes LATER. Presence is asserted in the same step
# deliberately: an absent flag has no index, and "neither is there" must never
# read as "they are in the right order".
assert_argv_flag_order() {
	TESTS_RUN=$((TESTS_RUN + 1))
	aafo_first=$(argv_call_token_index "$2" "$3")
	aafo_second=$(argv_call_token_index "$2" "$4")
	if [ -z "$aafo_first" ] || [ -z "$aafo_second" ]; then
		fail "$1" "call $2 argv is missing one of the flags: $3 at '${aafo_first:-absent}', $4 at '${aafo_second:-absent}'"
	elif [ "$aafo_first" -lt "$aafo_second" ]; then
		pass "$1"
	else
		fail "$1" "call $2 argv has $3 at position $aafo_first, NOT before $4 at position $aafo_second"
	fi
}

# stdin_config_path N -> where lib/curl-stub.sh records call N's `-K -` stdin
# config. Named rather than pasted because the cases below read it BOTH ways:
# by content (the happy path's byte-for-byte compare) and by ABSENCE (every
# refusal case, where no such file is the proof the request was never sent).
stdin_config_path() { printf '%s/call-%s.stdin' "$CURL_STUB_STDIN_LOG_DIR" "$1"; }

# assert_download_location_refused NAME DEST HEADERS DIAG REJECTED — one hostile
# or malformed redirect Location, driven end to end: call 1 answers 303 + HEADERS
# and the run must stop DEAD there. Asserts the fail-closed exit, DIAG on stderr,
# exactly ONE call (the second host was never contacted), NO `-K -` stdin config
# for a second call, REJECTED absent from the argv log, the JWT neither spent on
# the wire nor echoed in the diagnostic, and nothing at all left at or beside
# DEST.
#
# The queued call-2 success is the COUNTERFACTUAL that makes the one-call claim
# discriminating (the evil.example.com case's own note states it in full): with
# the check removed the engine really would fetch those bytes and install them,
# so a regression reports a second call, a stdin config carrying the rejected
# authority, and a real file at the destination — the actual exploit — instead of
# the stub's own no-canned-response artifact.
#
# WHICH OF THESE ASSERTIONS ACTUALLY DISCRIMINATES A HOSTILE HOST, stated here
# because the answer changed and the misreading is expensive. The two argv
# needles below (REJECTED absent, the JWT absent) no longer separate a working
# host pin from a removed one: call 2's URL reaches curl through a `-K -` stdin
# config and NEVER appears in argv at all, so both needles pass universally, for
# a correct pin and a regressed one alike. They are kept because they still
# assert a real property — the never-on-argv rule holds on this path too, and a
# regression that moved the URL back onto argv would fail them — but they are NOT
# the host-pin's coverage. That rests entirely on the four claims that observe
# the request's absence directly: the exit code, the ONE-call count, the missing
# call-2 stdin config, and the absent destination.
#
# A shared helper rather than five pasted blocks because the cases differ ONLY
# in those five values, and the assertion SET is the part that must not drift
# between them: a per-case copy is how one near-miss ends up missing the
# no-second-call assertion that is the whole point of the case.
assert_download_location_refused() {
	adlr_name=$1
	adlr_dest=$2
	adlr_headers=$3
	adlr_diag=$4
	adlr_rejected=$5

	reset_curl_stub
	set_stub_response 1 '' 303
	set_stub_headers 1 "$adlr_headers"
	set_stub_response 2 "$ATTACH_DL_PAYLOAD" 200
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" attach --download "$adlr_dest" --id 303980 --confirmed-site foo.atlassian.net
	expect_rc "$adlr_name -> exit 1 (fail closed)" 1
	stderr_has "$adlr_name: the diagnostic names the check that refused it" "$adlr_diag"
	equals "$adlr_name: exactly ONE call — the rejected host was NEVER requested" "$(call_count)" "1"
	assert_path_absent "$adlr_name: NO -K stdin config for a second call — the hostile media fetch was never even handed its URL" \
		"$(stdin_config_path 2)"
	file_not_has "$adlr_name: the rejected authority never appears in the argv log" \
		"$CURL_STUB_ARGV_LOG" "$adlr_rejected"
	file_not_has "$adlr_name: the JWT was never spent on the wire" \
		"$CURL_STUB_ARGV_LOG" "$ATTACH_DL_JWT"
	stderr_not_has "$adlr_name: the diagnostic echoes neither the rejected authority nor the JWT" \
		"$adlr_rejected"
	stderr_not_has "$adlr_name: the diagnostic does not echo the JWT" "$ATTACH_DL_JWT"
	stdout_not_has "$adlr_name: the JWT never reaches stdout either" "$ATTACH_DL_JWT"
	assert_path_absent "$adlr_name: no destination file was created" "$adlr_dest"
	assert_no_dest_siblings "$adlr_name: nothing was left beside the destination" "$adlr_dest"
}

section "jira.sh — attach --download: the happy path (303 resolve -> media fetch -> the bytes land at the destination)"

ATTACH_DL_OK_DEST="$WORK/download-ok.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_CTRL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_OK_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download happy path -> exit 0" 0
equals "attach --download happy path: exactly TWO calls (the content resolve + the media fetch)" "$(call_count)" "2"
# Call 1's URL by an exact-LINE match: a substring needle also passes on an
# unintended LONGER url that merely contains the expected one.
argv_log_has_token "attach --download happy path: call 1 GETs /attachment/content/303980 on the CONFIRMED site" \
	"https://foo.atlassian.net/rest/api/3/attachment/content/303980"
# CALL 2's URL IS ASSERTED ON STDIN, NOT ARGV, and the pair below is one claim
# split across the two channels. The whole justification of the second request is
# that the token-bearing Location reached the wire UNCHANGED; it reaches it as a
# `-K -` config, so the compare is byte-for-byte against the golden directive
# (see its own note for what that catches and a substring needle would not),
# and the argv log is asserted to hold NEITHER the URL nor its token.
#
# The argv absence is the non-disclosure half and it is NOT redundant with the
# stdin half: `ps`/`/proc/<pid>/cmdline` expose argv to every local user for the
# life of the request, which is the entire reason the URL moved off it. Together
# they pin "sent, and sent only where it cannot be read" — either alone passes
# for a URL that went nowhere, or for one that went out in the clear.
assert_file_bytes_identical "attach --download happy path: call 2's -K stdin config is EXACTLY the one url directive, media Location and token intact" \
	"$(stdin_config_path 2)" "$ATTACH_DL_STDIN_GOLDEN"
argv_log_not_has_token "attach --download happy path: the media URL is NEVER an argv token (it travels by stdin config)" \
	"$ATTACH_DL_MEDIA_URL"
file_not_has "attach --download happy path: the JWT never appears anywhere in the argv log" \
	"$CURL_STUB_ARGV_LOG" "$ATTACH_DL_JWT"
# THE TRANSPORT HARDENING OF EACH CALL, PER CALL. Both claims are per-call rather
# than log-wide because the two requests are hardened for different reasons and a
# log-wide needle cannot separate them: call 1 is the resolve that must HOLD the
# 303 (an -L there would fetch the binary and put the token-bearing URL on the
# wire inside curl's own redirect), and call 2 is the ONE request in this engine
# aimed at a host it did not build from $CONFIRMED_HOST, chosen from an untrusted
# response header — for which a log-wide "--proto is present somewhere" would be
# satisfied by call 1 alone.
#
# Jira's site credential must never reach api.media.atlassian.com either: the
# media URL's own short-lived JWT is that host's authorization. BOTH calls carry
# a -K, and they carry DIFFERENT ones — call 1 the site credential file, call 2
# the bare `-` that means "the config is on stdin" — so the count alone cannot
# separate them and the -K VALUE is asserted per call (argv_call_flag_value's own
# note states the regression that distinction catches). Call 1's -K is asserted
# alongside so a broken extraction (an empty block -> a vacuous "") cannot pass
# the call-2 claim by accident.
equals "attach --download happy path: call 1 HOLDS the redirect (no -L on the resolve)" \
	"$(argv_call_token_count 1 -L)" "0"
equals "attach --download happy path: call 1 DOES carry -K (the per-call extraction is not vacuously empty)" \
	"$(argv_call_token_count 1 -K)" "1"
assert_path_absent "attach --download happy path: call 1's -K names a credential FILE, not stdin (no call-1 stdin config was captured)" \
	"$(stdin_config_path 1)"
equals "attach --download happy path: call 2 pins the scheme (--proto present)" \
	"$(argv_call_token_count 2 --proto)" "1"
equals "attach --download happy path: call 2's --proto value is '=https'" \
	"$(argv_call_token_count 2 '=https')" "1"
equals "attach --download happy path: call 2 never follows a redirect (-L absent)" \
	"$(argv_call_token_count 2 -L)" "0"
equals "attach --download happy path: call 2 is not insecure (-k absent)" \
	"$(argv_call_token_count 2 -k)" "0"
equals "attach --download happy path: call 2 is not insecure (--insecure absent)" \
	"$(argv_call_token_count 2 --insecure)" "0"
equals "attach --download happy path: call 2 carries exactly ONE -K" \
	"$(argv_call_token_count 2 -K)" "1"
equals "attach --download happy path: call 2's -K value is the bare '-' — the config is stdin, NOT Jira's credential file" \
	"$(argv_call_flag_value 2 -K)" "-"
stdout_has "attach --download happy path: the machine line names the id AND the destination path" \
	"JIRA_ATTACHMENT_DOWNLOADED=303980 -> $ATTACH_DL_OK_DEST"
# The token is on the WIRE by design (it is the media host's own authorization,
# asserted present in call 2's stdin config above) and must reach NO output
# channel from there — the machine line names the id and the path, never the URL
# it spent.
stdout_not_has "attach --download happy path: the JWT never reaches stdout" "$ATTACH_DL_JWT"
stderr_not_has "attach --download happy path: the JWT never reaches stderr" "$ATTACH_DL_JWT"
assert_file_bytes_identical "attach --download happy path: the destination's bytes are EXACTLY the stubbed media body, control bytes and all" \
	"$ATTACH_DL_OK_DEST" "$ATTACH_DL_CTRL_GOLDEN"
assert_no_dest_siblings "attach --download happy path: nothing but the destination file itself was left beside it" \
	"$ATTACH_DL_OK_DEST"

section "jira.sh — attach --download: the body stages inside the engine's own \$WORKDIR, and the DESTINATION DIRECTORY is never used as a staging location"

# THE FEATURE'S OTHER CORE SECURITY PROPERTY, and the one every case above can
# only speak about by the absence of litter AFTERWARDS. What matters is WHERE the
# in-flight body is written WHILE it is being fetched: curl re-opens its `-o` path
# BY NAME after a full round-trip to the media CDN, so a staging path sitting in
# the caller-named destination directory — which this mode's threat model assumes
# another local user may write — is a name that user can unlink and replace with a
# symlink in the window, making curl write the fetched bytes through it as the
# invoking user. http.sh's own header carries the full threat model, including why
# the staging entity's own MODE does not close that window and only its LOCATION
# does.
#
# HOW IT IS OBSERVED, with no override and no privileged fixture: the staging path
# IS call 2's `-o` argument, and lib/curl-stub.sh already logs every argv token.
# So the claim "the body is staged inside the engine's own 0700 $WORKDIR" is read
# straight off the wire the engine really used, not inferred from what survived.
# The run gets its OWN $TMPDIR so that prefix is exact: $WORKDIR is
# `mktemp -d "${TMPDIR:-/tmp}/jira.work.XXXXXX"` (runtime.sh's ensure_workdir), so
# a staged path under $TMPDIR/jira.work.* cannot be in the destination's directory.
#
# AND ITS CONVERSE, which needs the destination directory to be EMPTY to mean
# anything: both cases below own a fresh one, so the whole directory can be
# counted rather than probed by name — exactly ONE entry after a successful
# install (the destination file itself) and ZERO after a failed one. That is the
# strongest form of "the destination's directory is never a staging location",
# and it is blind to what any future staging scheme might be called.

# assert_path_prefix NAME VALUE PREFIX — VALUE begins with PREFIX, matched as a
# LITERAL via a quoted `case` pattern (same reasoning as assert_holds_literal: no
# grep/sed dialect gets to reinterpret a path that carries `.` or `[`). An absent
# VALUE — the shape a missing `-o` extraction produces — fails, rather than
# vacuously passing the way an empty-needle grep would.
assert_path_prefix() {
	TESTS_RUN=$((TESTS_RUN + 1))
	case $2 in
		"$3"*) pass "$1" ;;
		*)     fail "$1" "expected a path beginning '$3', got: $2" ;;
	esac
}

# assert_dir_entry_count NAME DIR COUNT — DIR holds exactly COUNT entries, and
# the diagnostic names the ones it found. Dotfiles are counted too (`.`/`..`
# skipped): a staging scheme that hid itself behind a leading dot would otherwise
# satisfy a `*`-only scan.
assert_dir_entry_count() {
	TESTS_RUN=$((TESTS_RUN + 1))
	adec_count=0
	adec_found=""
	for adec_entry in "$2"/* "$2"/.*; do
		case ${adec_entry##*/} in .|..) continue ;; esac
		[ -e "$adec_entry" ] || [ -L "$adec_entry" ] || continue
		adec_count=$((adec_count + 1))
		adec_found="$adec_found $adec_entry"
	done
	if [ "$adec_count" -eq "$3" ]; then pass "$1"
	else fail "$1" "expected $3 entr(ies) in $2, found $adec_count:$adec_found"; fi
}

# One $TMPDIR for both cases (the engine's $WORKDIR is created fresh per run, so
# the prefix is all that is shared), and a SEPARATE, initially EMPTY destination
# directory each — the successful install leaves a file in its own, which is
# precisely what the failing case must be able to count as zero.
ATTACH_DL_STAGE_TMPDIR="$WORK/download-stage-tmp"
ATTACH_DL_STAGE_OK_DIR="$WORK/download-stage-ok-dir"
ATTACH_DL_STAGE_FAIL_DIR="$WORK/download-stage-fail-dir"
mkdir -p "$ATTACH_DL_STAGE_TMPDIR" "$ATTACH_DL_STAGE_OK_DIR" "$ATTACH_DL_STAGE_FAIL_DIR"
ATTACH_DL_STAGE_OK_DEST="$ATTACH_DL_STAGE_OK_DIR/out.bin"
ATTACH_DL_STAGE_FAIL_DEST="$ATTACH_DL_STAGE_FAIL_DIR/out.bin"
# The fixtures' own emptiness IS half of each claim below, asserted for the same
# reason the unwritable-parent case asserts its chmod took: a directory that was
# never empty makes both counts meaningless.
assert_dir_entry_count "attach --download staging fixture: the success case's destination directory starts EMPTY" \
	"$ATTACH_DL_STAGE_OK_DIR" 0
assert_dir_entry_count "attach --download staging fixture: the failure case's destination directory starts EMPTY" \
	"$ATTACH_DL_STAGE_FAIL_DIR" 0

# (a) A SUCCESSFUL download. The body is staged in $WORKDIR and hard-linked into
# place, so the destination directory sees exactly one entry appear — the final
# file — and never the payload in flight.
reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "TMPDIR=$ATTACH_DL_STAGE_TMPDIR" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_STAGE_OK_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download staging location -> exit 0" 0
equals "attach --download staging location: TWO calls (the download really ran)" "$(call_count)" "2"
assert_path_prefix "attach --download staging location: call 2 wrote the fetched body INSIDE the engine's own \$WORKDIR, not beside the destination" \
	"$(argv_call_flag_value 2 -o)" "$ATTACH_DL_STAGE_TMPDIR/jira.work."
assert_dir_entry_count "attach --download staging location: the destination directory holds exactly ONE entry — the installed file, nothing else" \
	"$ATTACH_DL_STAGE_OK_DIR" 1
assert_file_bytes_identical "attach --download staging location: that one entry is the destination file, with the payload's exact bytes" \
	"$ATTACH_DL_STAGE_OK_DEST" "$ATTACH_DL_PAYLOAD_GOLDEN"

# (b) A FAILED download (403 from the media host), which is where a staging
# location in the destination's directory would leave its partial payload. The
# body still goes to $WORKDIR — the EXIT trap's `rm -rf "$WORKDIR"` is what
# reclaims it — so the caller's directory stays untouched, with nothing to
# mistake for a real download.
reset_curl_stub
queue_attach_download_media_flow 'FORBIDDEN-ERROR-PAGE-BYTES' 403
run full "TMPDIR=$ATTACH_DL_STAGE_TMPDIR" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_STAGE_FAIL_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download staging location on a FAILED fetch -> exit 1" 1
equals "attach --download staging location on a failed fetch: TWO calls (the fetch was made and rejected)" "$(call_count)" "2"
assert_path_prefix "attach --download staging location on a failed fetch: the partial body went INSIDE \$WORKDIR too (not beside the destination)" \
	"$(argv_call_flag_value 2 -o)" "$ATTACH_DL_STAGE_TMPDIR/jira.work."
assert_dir_entry_count "attach --download staging location on a failed fetch: the destination directory is still EMPTY — nothing was ever created there" \
	"$ATTACH_DL_STAGE_FAIL_DIR" 0

section "jira.sh — attach --download: the INSTALLED file's mode is exactly 0600"

# THE ONLY THING THAT SETS IT is the `umask 077` on the command substitution that
# runs curl: curl creates the staged body under that mask, and the install `ln`
# does not carry a mode across at all — the destination and the staged body ARE
# one inode, so the destination has that same mode by IDENTITY, not by a copy.
# http.sh's header says outright
# that this looks removable — it does NOT protect the staged body, which is
# already inside a 0700 $WORKDIR — and that deleting it silently publishes every
# downloaded attachment at the caller's own umask, 0644 on a default login. No
# case in this suite pinned the installed mode at all, so that deletion was
# invisible.
#
# THE RUN'S UMASK IS PINNED TO 022 (umask_run's own header gives the general
# reason). Here it is what makes the assertion discriminating in BOTH directions:
# under an ambient 077 the destination would be 0600 no matter what the engine
# did, and the probe below is the control that proves 022 really is in effect — a
# file the harness itself creates under the same mask, which must be 0644. If that
# probe ever reads `-rw-------`, the mode assertion beneath it has stopped proving
# anything.

# assert_path_mode NAME PATH EXPECTED — PATH's `ls -l` mode string is exactly
# EXPECTED (e.g. `-rw-------`, `drwx------`). Runs in the HARNESS process, not
# under run()'s isolated toolbox, so `ls` is available — the toolbox deliberately
# has none, and adding one would put a tool on PATH the engine could then start
# depending on. Also read by the workdir-mode claim in the download sink section
# far below.
assert_path_mode() {
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ ! -e "$2" ]; then
		fail "$1" "the path does not exist, so it has no mode to compare: $2"
		return 0
	fi
	# shellcheck disable=SC2012  # `ls` deliberately: the mode STRING is wanted for the diagnostic, and the portable alternatives cannot produce one (`find -printf` is GNU-only, `stat` takes -c on GNU and -f on BSD). SC2012's hazard is an exotic filename, and every path passed here is one this harness built itself.
	apm_mode=$(ls -ld "$2" | cut -c1-10)
	if [ "$apm_mode" = "$3" ]; then pass "$1"
	else fail "$1" "mode is '$apm_mode', expected '$3': $2"; fi
}

ATTACH_DL_MODE_DEST="$WORK/download-mode.bin"
ATTACH_DL_MODE_PROBE="$WORK/download-mode-umask-probe.bin"
(umask 022; printf 'probe' >"$ATTACH_DL_MODE_PROBE")
assert_path_mode "attach --download mode fixture: a file created under the run's own umask (022) is 0644, so a 0600 destination cannot come from the ambient mask" \
	"$ATTACH_DL_MODE_PROBE" "-rw-r--r--"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
umask_run 022 full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_MODE_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download installed mode -> exit 0" 0
equals "attach --download installed mode: TWO calls (the download really ran)" "$(call_count)" "2"
assert_file_bytes_identical "attach --download installed mode: the bytes landed at the destination" \
	"$ATTACH_DL_MODE_DEST" "$ATTACH_DL_PAYLOAD_GOLDEN"
assert_path_mode "attach --download installed mode: the installed file is exactly 0600 — readable by nobody but the caller" \
	"$ATTACH_DL_MODE_DEST" "-rw-------"

section "jira.sh — attach --download --json: the SYNTHESIZED {id,path,downloaded} object (the media body is the file, not JSON)"

ATTACH_DL_JSON_DEST="$WORK/download-json.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_JSON_DEST" --id 303980 --confirmed-site foo.atlassian.net --json
expect_rc "attach --download --json -> exit 0" 0
# One compact, key-sorted compare pins the WHOLE synthesized object, exactly as
# version --delete --json's does: the shape (precisely {id,path,downloaded}),
# the id's JSON STRING type, the path it echoes, and the flag's JSON BOOLEAN
# type — in a single diagnosable assertion.
# The `|| true` is load-bearing, not defensive noise: the regression this
# assertion exists to catch is stdout carrying the downloaded BYTES instead of
# the synthesized object, and those bytes are not JSON — so an unguarded jq here
# fails the command substitution and `set -e` kills the WHOLE harness, turning
# one diagnosable red assertion into a suite that never reports. Empty output
# compares cleanly against the expected object instead.
ATTACH_DL_JSON_OUT=$(printf '%s' "$CUR_OUT" | jq -cS '.' 2>/dev/null || true)
equals "attach --download --json: SYNTHESIZED body is exactly {id:\"303980\",path:DEST,downloaded:true}" \
	"$ATTACH_DL_JSON_OUT" "$(printf '{"downloaded":true,"id":"303980","path":"%s"}' "$ATTACH_DL_JSON_DEST")"
# The media CDN's body IS the file, so --json must synthesize rather than pass
# it through. Only the payload's ABSENCE from stdout separates the two.
stdout_not_has "attach --download --json: the media body is NOT echoed to stdout (synthesized, not passthrough)" \
	"$ATTACH_DL_PAYLOAD"
assert_file_bytes_identical "attach --download --json: the bytes still landed at the destination (--json changes the report, not the download)" \
	"$ATTACH_DL_JSON_DEST" "$ATTACH_DL_PAYLOAD_GOLDEN"
assert_no_dest_siblings "attach --download --json: nothing but the destination file itself was left beside it" \
	"$ATTACH_DL_JSON_DEST"

section "jira.sh — attach --download: a Location carrying a literal quote and backslash is curl_config_escape'd into the stdin config"

# WHY A SECOND HAPPY PATH. The first one's media URL contains neither a `"` nor a
# `\`, so curl_config_escape is an IDENTITY over it — deleting the escape call
# from download_attachment_content entirely leaves that byte-exact golden
# passing. This case is the one that makes the escape load-bearing: the token
# carries both bytes, so an unescaped value would break out of curl's quoted
# `url = "..."` parameter, and the golden below is the only thing that notices.
#
# THE EXPECTED STDIN IS HAND-WRITTEN, never generated by calling
# curl_config_escape here: a golden produced by the function under test compares
# the implementation against itself and passes for any escaping rule at all,
# including none. Single quotes throughout, so `\"` and `\\` below really are a
# backslash-quote and two backslashes and not a shell escape of something else.
#
# The extraction pipeline that hands these bytes over is grep/sed/tr over the raw
# header dump, none of which treats `"` or `\` specially — verified by this case
# passing at all, which is why the fixture's own bytes are asserted first.
# assert_holds_literal NAME VALUE BYTE — VALUE contains BYTE, matched as a
# LITERAL via a quoted `case` pattern. Deliberately not a grep/tr/sed pipeline:
# the two bytes under test here are a double quote and a BACKSLASH, and every one
# of those tools would need the byte re-escaped in its own dialect — re-escaping
# the byte a fixture check exists to confirm is how the check starts proving
# something other than what its name says. Same reasoning, and the same `case`
# remedy, as harness.sh's stdout_no_line_starting_with.
assert_holds_literal() {
	TESTS_RUN=$((TESTS_RUN + 1))
	case $2 in
		*"$3"*) pass "$1" ;;
		*)      fail "$1" "the value does not hold the expected byte: $2" ;;
	esac
}

ATTACH_DL_ESC_TOKEN='ESCAPE"ME\TOO'
ATTACH_DL_ESC_MEDIA_URL="https://api.media.atlassian.com/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_ESC_TOKEN"
assert_holds_literal "attach --download escaped Location fixture: the token really holds a raw double quote" \
	"$ATTACH_DL_ESC_TOKEN" '"'
assert_holds_literal "attach --download escaped Location fixture: the token really holds a raw backslash" \
	"$ATTACH_DL_ESC_TOKEN" "\\"

ATTACH_DL_ESC_STDIN_GOLDEN="$WORK/download-stdin-escaped-golden.txt"
ATTACH_DL_ESC_STDIN_LINE='url = "https://api.media.atlassian.com/file/abcdef01-2345-6789-abcd-ef0123456789/binary?token=ESCAPE\"ME\\TOO"'
printf '%s\n' "$ATTACH_DL_ESC_STDIN_LINE" >"$ATTACH_DL_ESC_STDIN_GOLDEN"
# The hand-written golden spells the UUID out, so it cannot silently agree with a
# regressed $ATTACH_DL_UUID; this asserts the two still describe the same URL.
file_has "attach --download escaped Location golden: the hand-written directive names the same media UUID the fixture does" \
	"$ATTACH_DL_ESC_STDIN_GOLDEN" "$ATTACH_DL_UUID"

ATTACH_DL_ESC_DEST="$WORK/download-escaped.bin"

reset_curl_stub
set_stub_response 1 '' 303
set_stub_headers 1 "$(attach_dl_303_headers "$ATTACH_DL_ESC_MEDIA_URL")"
set_stub_response 2 "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_ESC_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download escaped Location -> exit 0" 0
equals "attach --download escaped Location: exactly TWO calls (the quote/backslash did not derail the flow)" \
	"$(call_count)" "2"
assert_file_bytes_identical "attach --download escaped Location: call 2's stdin config is EXACTLY the hand-written escaped directive" \
	"$(stdin_config_path 2)" "$ATTACH_DL_ESC_STDIN_GOLDEN"
assert_file_bytes_identical "attach --download escaped Location: the bytes still landed at the destination" \
	"$ATTACH_DL_ESC_DEST" "$ATTACH_DL_PAYLOAD_GOLDEN"
assert_no_dest_siblings "attach --download escaped Location: nothing was left beside the destination" \
	"$ATTACH_DL_ESC_DEST"

section "jira.sh — attach --download: a destination whose PARENT DIRECTORY does not exist (exit 2, before any network call)"

# The SECOND of the destination's three local preconditions (the first is
# "already exists", two sections up; the third is "parent not writable", the
# section immediately below), and the one whose check must stay pure parameter
# expansion: the PATH toolbox deliberately omits dirname/readlink/realpath/
# basename (see this harness's toolbox header), so a regression to
# `dirname "$OPT_DOWNLOAD"` dies at rc 127 here rather than passing green.
#
# WHICH GUARD ACTUALLY FIRES NEXT WITH THIS ONE REMOVED — established by removing
# it and looking, because two earlier versions of this note guessed and both
# guessed wrong (one named runtime.sh's cross-device pre-check, one named the
# install `ln`). It is neither: it is the WRITABILITY guard on the very next lines
# of this same function. `[ ! -w DIR ]` is true for a directory that does not
# exist, so cmd-attach.sh refuses at exit 2 with zero curl calls either way.
#
# SO THE EXIT CODE AND THE CALL COUNT DO NOT DISCRIMINATE HERE. What separates
# this guard from its neighbour is only the WORDING, in both directions: this
# guard's own "does not exist" must be present, and the writability guard's must
# be ABSENT — the same paired-diagnostic technique the unwritable-parent case
# below uses in reverse, and the only thing that can express an ordering between
# two guards that share an exit code. The zero-call assertion is kept because it
# still pins "the media JWT was never spent", which is worth asserting even
# though no regression this case models would break it; the queued success flow
# is the counterfactual that would make it break if one ever did.
ATTACH_DL_NO_PARENT_DIR="$WORK/download-missing-dir"
ATTACH_DL_NO_PARENT_DEST="$ATTACH_DL_NO_PARENT_DIR/inside.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_NO_PARENT_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download into a NON-EXISTENT parent directory -> exit 2" 2
stderr_has "attach --download missing parent dir: the diagnostic names the DIRECTORY (not the destination path)" \
	"--download destination directory does not exist: $ATTACH_DL_NO_PARENT_DIR"
# The WRITABILITY diagnostic must be ABSENT, and this is the assertion that makes
# the ordering claim: `[ ! -w DIR ]` is also true for a directory that does not
# exist, so with this guard removed the next one refuses the very same path at the
# very same exit code — see this section's note.
stderr_not_has "attach --download missing parent dir: the WRITABILITY guard did not fire (this guard runs first, and both would refuse this path at exit 2)" \
	"--download destination directory is not writable"
equals "attach --download missing parent dir: ZERO curl calls (refused before the resolve)" "$(call_count)" "0"
assert_path_absent "attach --download missing parent dir: the parent directory was NOT created" \
	"$ATTACH_DL_NO_PARENT_DIR"

section "jira.sh — attach --download: a parent directory that EXISTS but is NOT WRITABLE (exit 2, before any network call)"

# The THIRD local precondition, and a genuinely separate operator from the `-d`
# test above: a directory can exist and still refuse the install link, in which
# case an existence-only pre-flight lets the run spend the media JWT, fetch the
# whole payload, and only then die on the `ln` — reported under this engine's
# install-failure diagnostic and exit 1 rather than as the caller's own usage
# error, which is exactly what this guard exists to turn it into.
#
# GUARDED ON EUID, because the `w` bit does not apply to root: uid 0 writes into
# a 0555 directory regardless, so under root this case would assert a refusal
# that correctly never comes. Skipped rather than inverted — "root can write
# anywhere" is the kernel's behavior, not this engine's, and asserting it here
# would test the kernel.
ATTACH_DL_RO_PARENT_DIR="$WORK/download-unwritable-dir"
ATTACH_DL_RO_PARENT_DEST="$ATTACH_DL_RO_PARENT_DIR/inside.bin"
mkdir -p "$ATTACH_DL_RO_PARENT_DIR"
if [ "$(id -u)" -ne 0 ]; then
	chmod 0555 "$ATTACH_DL_RO_PARENT_DIR"
	# The fixture's own state IS half the claim: a chmod that silently did not
	# take would leave every assertion below passing for the wrong reason.
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -d "$ATTACH_DL_RO_PARENT_DIR" ] && [ ! -w "$ATTACH_DL_RO_PARENT_DIR" ]; then
		pass "attach --download unwritable parent fixture: the directory really exists and is really not writable"
	else
		fail "attach --download unwritable parent fixture: the directory really exists and is really not writable" \
			"chmod did not take: $ATTACH_DL_RO_PARENT_DIR"
	fi

	reset_curl_stub
	# COUNTERFACTUAL, and here the zero-call assertion IS discriminating (unlike
	# the missing-parent case above): this directory exists and is on $WORKDIR's
	# filesystem, so with the writability check removed the run clears every
	# sink-side pre-check, spends the resolve and fetches the payload — TWO calls
	# and a failed install — instead of reporting a stub artifact.
	queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" attach --download "$ATTACH_DL_RO_PARENT_DEST" --id 303980 --confirmed-site foo.atlassian.net
	expect_rc "attach --download into an UNWRITABLE parent directory -> exit 2" 2
	stderr_has "attach --download unwritable parent dir: the diagnostic names WRITABILITY, not existence" \
		"--download destination directory is not writable: $ATTACH_DL_RO_PARENT_DIR"
	# The existence diagnostic must be ABSENT: both guards exit 2 over the same
	# path, so only the losing one's silence proves WHICH fired.
	stderr_not_has "attach --download unwritable parent dir: the EXISTENCE diagnostic did not fire (the directory is there)" \
		"--download destination directory does not exist"
	equals "attach --download unwritable parent dir: ZERO curl calls (refused before the resolve)" "$(call_count)" "0"
	assert_path_absent "attach --download unwritable parent dir: no destination file was created" \
		"$ATTACH_DL_RO_PARENT_DEST"
	chmod 0755 "$ATTACH_DL_RO_PARENT_DIR"
fi

section "jira.sh — attach --download: the read-only gate fires AFTER local validation, not before"

# THE ORDERING, VERIFIED IN jira.sh RATHER THAN ASSUMED: the dispatch runs
# validate_attach_args (the `case "$COMMAND" in ... attach) validate_attach_args`
# block) and only then require_write_allowed, whose own header states the reason
# — the gate's classification reads the same OPT_* carriers the command's
# validator has already enforced, and a caller's own typo should still surface as
# a usage error first. So a read-only --download with a BAD destination reports
# the destination, not the refusal.
#
# The read-only --download case in the gate section far below cannot observe this
# at all: its destination does not exist, so both orderings produce the gate's own
# refusal and the case passes either way. Only an ALREADY-EXISTING destination
# separates them — which is what makes the stderr_not_has below the whole point
# of this case rather than decoration.
ATTACH_DL_ORDER_DEST="$WORK/download-order-existing.bin"
printf 'do not clobber me either' >"$ATTACH_DL_ORDER_DEST"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_ORDER_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download read-only + existing destination -> exit 2 (the USAGE error, not the gate's exit 1)" 2
stderr_has "attach --download read-only + existing destination: local validation reported first" \
	"--download destination already exists (refusing to overwrite it): $ATTACH_DL_ORDER_DEST"
# shellcheck disable=SC2016  # single-quoted on purpose: the needle is the gate's own literal message, which spells the variable NAME — expanding it here would search for the VALUE
stderr_not_has "attach --download read-only + existing destination: the read-only refusal never fired (it runs later)" \
	'$JIRA_READ_ONLY is set: refusing'
equals "attach --download read-only + existing destination: ZERO curl calls either way" "$(call_count)" "0"
file_has "attach --download read-only + existing destination: the file's original content is untouched" \
	"$ATTACH_DL_ORDER_DEST" "do not clobber me either"

section "jira.sh — attach --download: --plan and --force are refused by name (neither is implemented on this mode)"

# Both flags are ACCEPTED by the shared parser and read by NOBODY on this path,
# so each would be SILENTLY DROPPED on a mode that creates a real local file —
# the destructive-and-quiet shape `attach --delete`'s own --plan guard closes,
# asserted there and, until now, nowhere for --download. --force is the sharper
# of the two: this mode's help text tells the caller outright that there is no
# --force, so accepting one would confirm an overwrite policy that does not
# exist.
#
# Each case queues the two-call success flow as a COUNTERFACTUAL: with the guard
# gone the run resolves, fetches and installs, so the regression shows real calls
# and a real file rather than the stub's no-canned-response artifact.
ATTACH_DL_PLAN_DEST="$WORK/download-plan.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_PLAN_DEST" --id 303980 --plan --confirmed-site foo.atlassian.net
expect_rc "attach --download + --plan -> exit 2" 2
stderr_has "attach --download --plan: the diagnostic names the preview-implementing commands and says --download writes for real" \
	"--plan/--dry-run is only valid with the commands that implement a preview (attach --download writes the file for real)"
equals "attach --download --plan: ZERO curl calls (nothing was resolved or fetched)" "$(call_count)" "0"
assert_path_absent "attach --download --plan: no destination file was created" "$ATTACH_DL_PLAN_DEST"

ATTACH_DL_FORCE_DEST="$WORK/download-force.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_FORCE_DEST" --id 303980 --force --confirmed-site foo.atlassian.net
expect_rc "attach --download + --force -> exit 2" 2
stderr_has "attach --download --force: the diagnostic names discover --write as the owner and denies an overwrite mode here" \
	"--force is only valid with discover --write (attach --download has no overwrite mode)"
equals "attach --download --force: ZERO curl calls (nothing was resolved or fetched)" "$(call_count)" "0"
assert_path_absent "attach --download --force: no destination file was created" "$ATTACH_DL_FORCE_DEST"

section "jira.sh — attach --download + --project: the command-scope refusal reaches the fourth mode too"

# The fourth mode of the --project command-scope guard asserted three sections
# above (see its own note for why one case per mode is the minimum) — here
# because --download's refusal carries the extra claim only this mode can make:
# the caller-named local file is absent. Counterfactual queue, same role as above.
ATTACH_PROJECT_DL_DEST="$WORK/project-scope-download.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_PROJECT_DL_DEST" --id 303980 --project PSWS --confirmed-site foo.atlassian.net
expect_rc "attach --download + --project -> exit 2" 2
stderr_has "attach --download --project: the same command-scope diagnostic the other three modes report" \
	"$ATTACH_PROJECT_SCOPE_DIAG"
equals "attach --download --project: ZERO curl calls (the media JWT was never spent)" "$(call_count)" "0"
assert_path_absent "attach --download --project: the caller-named destination was NEVER created" \
	"$ATTACH_PROJECT_DL_DEST"

section "jira.sh — attach --download: the leading-dash refusal tests the FIRST BYTE OF THE WHOLE PATH, not a component"

# cmd-attach.sh's guard states the rule and why it is neither narrower nor wider:
# the path reaches two option-parsed arguments — the install `mv`'s destination,
# and the `df` behind the same-filesystem pre-check, which is handed the DIRECTORY
# derived from this path — and "a filename-only test misses `-dir/out.bin` (there
# it is the DIRECTORY's own dash that gets read as an option), while a
# per-component test refuses `dir/-out.bin`, `./-out.bin` and every absolute path
# under a `-`-prefixed ancestor, all of which reach those tools with a harmless
# leading byte and work."
#
# So this block is FOUR cases and needs all four: two refusals and two
# ACCEPTANCES. The refusals alone would pass for a per-component check; the
# acceptances alone would pass for no check at all. Only the pair in each
# direction pins the rule the guard actually implements.
#
# ALL FOUR RUN FROM A SCRATCH DIRECTORY, none from the invoker's ambient cwd.
# Every path here is RELATIVE (that is the point — the guard reads the first byte
# of the path as typed), so an ambient cwd would resolve each of them against
# whatever happens to sit in the directory the suite was started from: a stray
# `-out.bin` or `-dir/` there would flip a case's outcome for a reason that has
# nothing to do with the engine. Case (d) is the one exception and states its own.
# The harness's own cwd is restored immediately after each run, following the P3
# cwd cases' precedent in the sibling write suite.
ATTACH_DL_DASH_DIAG="--download destination must not begin with '-' (it would be read as an option)"
ATTACH_DL_SAVED_CWD=$(pwd)

# The refusals' scratch directory. `-dir` is created INSIDE it so case (b)'s
# dash-prefixed DIRECTORY genuinely exists — see that case for why its own
# claim is unreachable without it.
ATTACH_DL_DASH_REFUSAL_DIR="$WORK/dashrefusal"
mkdir -p "$ATTACH_DL_DASH_REFUSAL_DIR"
mkdir -p -- "$ATTACH_DL_DASH_REFUSAL_DIR/-dir"
# The fixture's own state IS part of case (b)'s claim, exactly as the unwritable
# parent case asserts its chmod took: without a real `-dir`, the narrowed-check
# counterfactual below dies at the existence guard, with a different diagnostic,
# instead of reaching the tools that read the dash as an option.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -d "$ATTACH_DL_DASH_REFUSAL_DIR/-dir" ]; then
	pass "attach --download leading-dash fixture: the dash-prefixed DIRECTORY '-dir' really exists in the scratch cwd"
else
	fail "attach --download leading-dash fixture: the dash-prefixed DIRECTORY '-dir' really exists in the scratch cwd" \
		"not created: $ATTACH_DL_DASH_REFUSAL_DIR/-dir"
fi

# (a) REFUSED — a bare leading dash on the filename, the shape the guard's own
# comment names as the motivating case.
reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
cd "$ATTACH_DL_DASH_REFUSAL_DIR"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download -out.bin --id 303980 --confirmed-site foo.atlassian.net
cd "$ATTACH_DL_SAVED_CWD"
expect_rc "attach --download -out.bin -> exit 2 (refused)" 2
stderr_has "attach --download -out.bin: the diagnostic names the leading-dash refusal and echoes the path" \
	"$ATTACH_DL_DASH_DIAG: -out.bin"
equals "attach --download -out.bin: ZERO curl calls (refused before the resolve)" "$(call_count)" "0"

# (b) REFUSED — the CRITICAL REGRESSION GUARD. A filename-only check sees
# "out.bin", finds no leading dash, and lets this through: `-dir` exists and is
# writable, so the whole pre-flight clears — and the run then dies inside
# download_attachment_content instead, where `df -P "$WORKDIR" "-dir"` reads the
# destination directory as an OPTION, cannot answer, and fails closed into the
# cross-filesystem refusal: an exit-1 diagnostic about filesystems, entirely
# outside this mode's exit-2 destination contract, for a path whose real problem
# is its first byte. So what separates the guards here is the exit code and this
# guard's own wording, not the call count (both refuse before the resolve). The
# case is reachable ONLY because the fixture above creates `-dir` for real:
# without it the existence guard refuses first, with a DIFFERENT diagnostic, and
# this case would pass for the wrong reason. No other case in this block fails if
# the check narrows to the filename component.
reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
cd "$ATTACH_DL_DASH_REFUSAL_DIR"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download -dir/out.bin --id 303980 --confirmed-site foo.atlassian.net
cd "$ATTACH_DL_SAVED_CWD"
expect_rc "attach --download -dir/out.bin -> exit 2 (the case a filename-only check MISSES)" 2
stderr_has "attach --download -dir/out.bin: the diagnostic echoes the whole path, dash-prefixed DIRECTORY included" \
	"$ATTACH_DL_DASH_DIAG: -dir/out.bin"
equals "attach --download -dir/out.bin: ZERO curl calls (the media JWT was never spent)" "$(call_count)" "0"

# (c) ACCEPTED — the FALSE POSITIVE a per-component check would produce. The
# dash is on the filename but not on the whole path, so both `df` (handed
# "dashdir") and the install `mv` (handed "dashdir/-out.bin") see a harmless
# leading byte, and the download must work normally. Driven from inside the
# directory rather than by absolute path so the leading byte of the path really is
# the dash's own component's parent.
ATTACH_DL_DASHNAME_DIR="$WORK/dashname"
mkdir -p "$ATTACH_DL_DASHNAME_DIR/dashdir"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
cd "$ATTACH_DL_DASHNAME_DIR"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download dashdir/-out.bin --id 303980 --confirmed-site foo.atlassian.net
cd "$ATTACH_DL_SAVED_CWD"
expect_rc "attach --download dashdir/-out.bin -> exit 0 (a dash on the FILENAME is harmless)" 0
stderr_not_has "attach --download dashdir/-out.bin: the leading-dash guard did NOT fire (a per-component check would have)" \
	"$ATTACH_DL_DASH_DIAG"
equals "attach --download dashdir/-out.bin: TWO calls (the download really ran)" "$(call_count)" "2"
assert_file_bytes_identical "attach --download dashdir/-out.bin: the bytes landed at the dash-named file" \
	"$ATTACH_DL_DASHNAME_DIR/dashdir/-out.bin" "$ATTACH_DL_PAYLOAD_GOLDEN"

# (d) ACCEPTED — an ABSOLUTE path under a `-`-prefixed ANCESTOR directory, the
# other shape a per-component check wrongly refuses. The whole path begins with
# "/", so every option-parsed argument it reaches is safe, and the dash sits
# several components deep where nothing ever reads it as an option. This is the ONE case in the block that needs no cwd
# control: an absolute path resolves identically from anywhere, so there is no
# ambient state for a stray file to perturb.
ATTACH_DL_DASH_ANCESTOR_DIR="$WORK/-dashancestor/nested"
mkdir -p "$ATTACH_DL_DASH_ANCESTOR_DIR"
ATTACH_DL_DASH_ANCESTOR_DEST="$ATTACH_DL_DASH_ANCESTOR_DIR/out.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_DASH_ANCESTOR_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download under a '-'-prefixed ANCESTOR -> exit 0 (absolute, so the first byte is '/')" 0
stderr_not_has "attach --download dash ancestor: the leading-dash guard did NOT fire" \
	"$ATTACH_DL_DASH_DIAG"
equals "attach --download dash ancestor: TWO calls (the download really ran)" "$(call_count)" "2"
assert_file_bytes_identical "attach --download dash ancestor: the bytes landed under the dash-prefixed directory" \
	"$ATTACH_DL_DASH_ANCESTOR_DEST" "$ATTACH_DL_PAYLOAD_GOLDEN"

section "jira.sh — attach --download: the destination-directory derivation's two edge branches (a bare filename, and a root-only slash)"

# The derivation is pure parameter expansion with two cases `%/*` alone gets
# wrong, both of which cmd-attach.sh handles explicitly and neither of which any
# other destination in this suite reaches (every one is a `$WORK/...` path with a
# normal parent): a path with NO slash derives ".", and a path whose ONLY slash is
# the leading one derives "/", where `%/*` strips to the empty string.
#
# (a) A BARE FILENAME -> ".". Run from inside a scratch directory (the P3 cwd
# precedent again), so "." is that directory and a successful download proves the
# branch resolved to the cwd rather than to the empty string — which would make
# the `-d` test fail and exit 2.
ATTACH_DL_BARE_DIR="$WORK/barename"
mkdir -p "$ATTACH_DL_BARE_DIR"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
cd "$ATTACH_DL_BARE_DIR"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download bare.bin --id 303980 --confirmed-site foo.atlassian.net
cd "$ATTACH_DL_SAVED_CWD"
expect_rc "attach --download bare.bin (no slash) -> exit 0" 0
stderr_not_has "attach --download bare filename: no destination-directory diagnostic fired (the branch derived '.', not '')" \
	"--download destination directory"
equals "attach --download bare filename: TWO calls (the download really ran)" "$(call_count)" "2"
assert_file_bytes_identical "attach --download bare filename: the bytes landed in the CWD" \
	"$ATTACH_DL_BARE_DIR/bare.bin" "$ATTACH_DL_PAYLOAD_GOLDEN"

# (b) A ROOT-ONLY SLASH -> "/". The observable outcome is whatever "/" really
# permits for the euid running the suite, so the assertion is the one this run
# genuinely makes: unprivileged, "/" exists and is not writable, so the
# WRITABILITY guard fires (exit 2) and the existence one does not — which is
# itself the proof the branch derived "/" rather than the empty string, since an
# empty directory name would have failed `-d` and produced the OTHER diagnostic.
#
# GUARDED ON EUID for the same reason the unwritable-parent case is, and with a
# sharper consequence: under root the guard would correctly pass and the engine
# would create /out.bin on the machine running the tests. A suite may not do that.
if [ "$(id -u)" -ne 0 ]; then
	reset_curl_stub
	queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" attach --download /out.bin --id 303980 --confirmed-site foo.atlassian.net
	expect_rc "attach --download /out.bin (root-only slash) -> exit 2" 2
	stderr_has "attach --download root-only slash: the diagnostic names the derived directory as exactly '/'" \
		"--download destination directory is not writable: /"
	stderr_not_has "attach --download root-only slash: the EXISTENCE guard did not fire (the branch derived '/', not '')" \
		"--download destination directory does not exist"
	equals "attach --download root-only slash: ZERO curl calls" "$(call_count)" "0"
	assert_path_absent "attach --download root-only slash: nothing was created at /out.bin" "/out.bin"
fi

section "jira.sh — attach --download: a raw newline in the destination path cannot forge a line in a precondition diagnostic"

# All FOUR of --download's precondition diagnostics fold their disclosed path
# through one_line_display (runtime.sh); only the machine line's own disclosure
# did before.
# The three added ones share one fold call each, so a regression removes them
# independently — and this case drives the already-exists one, the only one of the
# three whose fixture can carry the byte AND be reached (a newline-bearing path is
# creatable, so `-e` sees it).
#
# Same fixture shape and same claim as the bulk --plan forgery cases further
# below: the fold turns the newline into a SPACE, so the forged tail arrives on
# the engine's own diagnostic line as inert data, and a needle spanning that one
# line is absent the moment the raw newline survives instead (grep matches a
# needle within ONE line).
ATTACH_DL_FORGED_DEST=$(printf '%s/forged\nFAKE-DOWNLOAD-LINE.bin' "$WORK")
printf 'x' >"$ATTACH_DL_FORGED_DEST"
equals "attach --download forged destination fixture: the PATH really holds exactly ONE raw newline" \
	"$(printf '%s' "$ATTACH_DL_FORGED_DEST" | wc -l | tr -d ' ')" "1"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -e "$ATTACH_DL_FORGED_DEST" ]; then
	pass "attach --download forged destination fixture: that newline-bearing path really exists (so -e reaches the fold)"
else
	fail "attach --download forged destination fixture: that newline-bearing path really exists (so -e reaches the fold)" \
		"not created: $ATTACH_DL_FORGED_DEST"
fi

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_FORGED_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download forged destination -> exit 2" 2
stderr_has "attach --download forged destination: the newline became a SPACE — the forged tail stays on the refusal's own line as inert data" \
	"--download destination already exists (refusing to overwrite it): $WORK/forged FAKE-DOWNLOAD-LINE.bin"
equals "attach --download forged destination: ZERO curl calls" "$(call_count)" "0"

section "jira.sh — attach --download: a NON-3xx first response fails loud (exit 1) and never reaches a second host"

ATTACH_DL_404_DEST="$WORK/download-404.bin"

reset_curl_stub
set_stub_response 1 '{"errorMessages":["Attachment not found"]}' 404
# COUNTERFACTUAL: with the 3xx check removed, an absent Location fails the
# https-shape check next and still stops at one call — so the queued 200 is what
# makes a DEEPER regression (one that fabricated or defaulted a media URL)
# visible as a second call instead of a stub error.
set_stub_response 2 "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_404_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download non-3xx resolve -> exit 1" 1
stderr_has "attach --download non-3xx resolve: the diagnostic names the expected 3xx AND the status received" \
	"expected a 3xx redirect, got HTTP 404"
equals "attach --download non-3xx resolve: exactly ONE call (no second host was contacted)" "$(call_count)" "1"
assert_path_absent "attach --download non-3xx resolve: no destination file was created" "$ATTACH_DL_404_DEST"
assert_no_dest_siblings "attach --download non-3xx resolve: nothing was left beside the destination" \
	"$ATTACH_DL_404_DEST"

section "jira.sh — attach --download: a Location pointing at an UNTRUSTED HOST is refused and NEVER fetched (the feature's core security property)"

# THE MOST IMPORTANT CASE IN THIS SECTION. --download is the engine's only
# egress to a host it did not build from $CONFIRMED_HOST, and the redirect that
# names that host is untrusted input. resolve_media_download_url pins it against
# the HARDCODED api.media.atlassian.com, so a hostile Location must stop the
# flow DEAD — one call, no second request, nothing written.
#
# The queued 200 is the COUNTERFACTUAL that makes the zero-second-call claim
# discriminating: with the pin removed the engine WOULD fetch from
# evil.example.com and install its bytes, so the assertions below would report a
# second call, a stdin config carrying the hostile host, and a real file at the
# destination — the actual exploit — instead of a stub no-response artifact.
#
# The two argv needles below are the NON-DISCRIMINATING pair
# assert_download_location_refused's header describes in full — read it there.
ATTACH_DL_UNTRUSTED_DEST="$WORK/download-untrusted.bin"

reset_curl_stub
set_stub_response 1 '' 303
set_stub_headers 1 "$ATTACH_DL_UNTRUSTED_303_HEADERS"
set_stub_response 2 "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_UNTRUSTED_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download untrusted Location -> exit 1 (fail closed)" 1
stderr_has "attach --download untrusted Location: the diagnostic names the media-host pin" \
	"the redirect Location does not point at Atlassian's media host (fail closed)"
equals "attach --download untrusted Location: exactly ONE call — the untrusted host was NEVER requested" \
	"$(call_count)" "1"
assert_path_absent "attach --download untrusted Location: NO -K stdin config for a second call — evil.example.com was never handed a URL to fetch" \
	"$(stdin_config_path 2)"
file_not_has "attach --download untrusted Location: the hostile host never appears in the argv log" \
	"$CURL_STUB_ARGV_LOG" "$ATTACH_DL_UNTRUSTED_HOST"
file_not_has "attach --download untrusted Location: the JWT was never spent on the wire" \
	"$CURL_STUB_ARGV_LOG" "$ATTACH_DL_JWT"
# resolve_media_download_url's own rule: every diagnostic names the attachment
# id alone and NOTHING extracted from the Location — not even the host it failed
# on, since a Location without a path would put the token inside the substring
# the function calls "the host".
stderr_not_has "attach --download untrusted Location: the diagnostic does not echo the hostile host" \
	"$ATTACH_DL_UNTRUSTED_HOST"
stderr_not_has "attach --download untrusted Location: the diagnostic does not echo the JWT" "$ATTACH_DL_JWT"
stdout_not_has "attach --download untrusted Location: the JWT never reaches stdout either" "$ATTACH_DL_JWT"
assert_path_absent "attach --download untrusted Location: no destination file was created" \
	"$ATTACH_DL_UNTRUSTED_DEST"
assert_no_dest_siblings "attach --download untrusted Location: nothing was left beside the destination" \
	"$ATTACH_DL_UNTRUSTED_DEST"

section "jira.sh — attach --download: four NEAR-MISS media hosts, each refused by the exact pin but admitted by a specific weakening of it"

# WHY THE evil.example.com CASE ABOVE IS NOT ENOUGH, and why these four exist.
# That host shares no bytes with api.media.atlassian.com, so it is refused by the
# correct whole-string equality pin AND by every plausible regression of it — a
# suffix glob, a prefix glob, a substring test. A suite whose only hostile host is
# that one therefore stays GREEN through the exact regression the pin exists to
# prevent. Each case below is the counter-example for one such regression, chosen
# so the near-miss host is refused today and ADMITTED the moment the pin is
# weakened in that one specific way (see the constants block for the mapping).
ATTACH_DL_NEARMISS_DIAG="the redirect Location does not point at Atlassian's media host (fail closed)"

assert_download_location_refused \
	"attach --download near-miss host (suffix-match bypass: $ATTACH_DL_NEARMISS_SUFFIX)" \
	"$WORK/download-nearmiss-suffix.bin" \
	"$(attach_dl_303_headers "https://$ATTACH_DL_NEARMISS_SUFFIX/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_JWT")" \
	"$ATTACH_DL_NEARMISS_DIAG" \
	"$ATTACH_DL_NEARMISS_SUFFIX"

assert_download_location_refused \
	"attach --download near-miss host (prefix-match bypass: $ATTACH_DL_NEARMISS_PREFIX)" \
	"$WORK/download-nearmiss-prefix.bin" \
	"$(attach_dl_303_headers "https://$ATTACH_DL_NEARMISS_PREFIX/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_JWT")" \
	"$ATTACH_DL_NEARMISS_DIAG" \
	"$ATTACH_DL_NEARMISS_PREFIX"

assert_download_location_refused \
	"attach --download near-miss host (userinfo trick: $ATTACH_DL_NEARMISS_USERINFO)" \
	"$WORK/download-nearmiss-userinfo.bin" \
	"$(attach_dl_303_headers "https://$ATTACH_DL_NEARMISS_USERINFO/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_JWT")" \
	"$ATTACH_DL_NEARMISS_DIAG" \
	"$ATTACH_DL_NEARMISS_USERINFO"

# The BARE-AUTHORITY case is the one resolve_media_download_url's own header
# singles out: with no `/` in the Location, the `s#/.*##` host extraction has
# nothing to cut, so the extracted "host" is the authority WITH the query string
# — the JWT included. That is precisely why every diagnostic in that function
# names the attachment id alone, and the helper's stderr assertions are what pin
# it: echoing "the host it failed on" here would disclose the token.
assert_download_location_refused \
	"attach --download near-miss host (bare authority, no path)" \
	"$WORK/download-nearmiss-bare.bin" \
	"$(attach_dl_303_headers "https://$ATTACH_DL_NEARMISS_BARE")" \
	"$ATTACH_DL_NEARMISS_DIAG" \
	"$ATTACH_DL_NEARMISS_BARE"

section "jira.sh — attach --download: the https-SHAPE check — an absent Location and an http DOWNGRADE both fail closed, before the host pin"

# resolve_media_download_url tests the Location's SHAPE (`https://*`) before it
# extracts a host, and that arm had no coverage at all: every case above supplies
# a well-formed https Location and fails the host pin instead. The two shapes the
# shape check owns are the two below, and they fail for DIFFERENT reasons that
# share one diagnostic — so each is driven separately rather than assumed.
ATTACH_DL_SHAPE_DIAG="the redirect Location was absent or not https (fail closed)"

# (a) A 303 whose header block carries NO Location at all. The engine must not
# fabricate, default, or reuse a media URL, and the ASSERTION that pins it is the
# missing call-2 stdin config: a fabricated URL would be piped into `-K -` and
# recorded there. The media-host needle over the argv log beside it is the
# non-discriminating kind assert_download_location_refused's header describes.
ATTACH_DL_NO_LOCATION_DEST="$WORK/download-no-location.bin"

reset_curl_stub
set_stub_response 1 '' 303
# CRLF, for the reason attach_dl_303_headers states — this one is built inline
# rather than through that helper precisely because it has no Location to pass.
set_stub_headers 1 "$(printf 'HTTP/2 303\015\ncontent-length: 0\015')"
# COUNTERFACTUAL, same role as every other case in this block: a regression that
# fabricated a media URL shows up as a SECOND call with real bytes installed,
# rather than as the stub's own no-canned-response artifact.
set_stub_response 2 "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_NO_LOCATION_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download 303 with NO Location header -> exit 1 (fail closed)" 1
stderr_has "attach --download absent Location: the diagnostic names the shape check" "$ATTACH_DL_SHAPE_DIAG"
equals "attach --download absent Location: exactly ONE call (no second request at all)" "$(call_count)" "1"
assert_path_absent "attach --download absent Location: NO -K stdin config for a second call — no media URL was fabricated to fetch from" \
	"$(stdin_config_path 2)"
file_not_has "attach --download absent Location: the media host is absent from the argv log too" \
	"$CURL_STUB_ARGV_LOG" "api.media.atlassian.com"
assert_path_absent "attach --download absent Location: no destination file was created" \
	"$ATTACH_DL_NO_LOCATION_DEST"
assert_no_dest_siblings "attach --download absent Location: nothing was left beside the destination" \
	"$ATTACH_DL_NO_LOCATION_DEST"

# (b) An http (not https) Location at the OTHERWISE CORRECT media host — a plaintext
# downgrade of the one request that carries the JWT in its query string. It must be
# refused by the shape check BEFORE the host pin ever sees it, which is why the
# needle is the shape diagnostic and not the media-host one.
assert_download_location_refused \
	"attach --download http DOWNGRADE at the real media host" \
	"$WORK/download-http-downgrade.bin" \
	"$(attach_dl_303_headers "http://api.media.atlassian.com/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_JWT")" \
	"$ATTACH_DL_SHAPE_DIAG" \
	"http://api.media.atlassian.com"

section "jira.sh — attach --download: a FAILED curl (network/TLS, not an HTTP status) on either request leaves nothing behind"

# NEITHER curl-failure branch had coverage, and they are the only two paths that
# can fail with no HTTP status to inspect — `curl` itself returning non-zero. The
# stub's own no-canned-response path exits 99, which is exactly that shape, so
# leaving a call UNqueued is how each branch is reached.
#
# The second one matters most: it is the only failure that happens after curl has
# been handed an output path, so it is the one path that could leave a partial
# payload anywhere — and the claim is that "anywhere" is never at or beside the
# caller's destination. (Where the partial body DOES go, and that the EXIT trap
# reclaims it, is the staging-location section's own claim.)
ATTACH_DL_RESOLVE_NETFAIL_DEST="$WORK/download-resolve-netfail.bin"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_RESOLVE_NETFAIL_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download resolve curl failure -> exit 1" 1
stderr_has "attach --download resolve curl failure: the diagnostic names the network/TLS failure and the attachment id" \
	"resolve media download url: curl request failed (network/TLS error) for attachment 303980"
equals "attach --download resolve curl failure: exactly ONE call (no media fetch was attempted)" "$(call_count)" "1"
assert_path_absent "attach --download resolve curl failure: no destination file was created" \
	"$ATTACH_DL_RESOLVE_NETFAIL_DEST"
# Non-vacuous despite every write living downstream of the resolve: this is the
# ORDERING guard — it is what fails if anything is ever created at or beside the
# destination before the status is known, which is the change that would turn a
# failed resolve into litter.
assert_no_dest_siblings "attach --download resolve curl failure: nothing was left beside the destination" \
	"$ATTACH_DL_RESOLVE_NETFAIL_DEST"

ATTACH_DL_MEDIA_NETFAIL_DEST="$WORK/download-media-netfail.bin"

reset_curl_stub
set_stub_response 1 '' 303
set_stub_headers 1 "$ATTACH_DL_303_HEADERS"
# Call 2 deliberately left UNqueued — the resolve succeeds, the media fetch fails
# as a failed curl rather than as an HTTP status.
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_MEDIA_NETFAIL_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download media-fetch curl failure -> exit 1" 1
stderr_has "attach --download media-fetch curl failure: the diagnostic names the network/TLS failure and the attachment id" \
	"download attachment 303980: curl request failed (network/TLS error)"
equals "attach --download media-fetch curl failure: TWO calls (the media fetch WAS attempted)" "$(call_count)" "2"
# NO stderr non-disclosure assertion on THIS case, deliberately, and it is the one
# case in the block that cannot carry one: the failure is manufactured by leaving
# call 2 unqueued, and the stub's own "no canned response configured for call #2
# (url=…)" message echoes whatever it was invoked with, straight to stderr. A
# stderr_not_has here would therefore measure the STUB rather than the engine —
# green or red depending on how the URL reaches curl, never on whether the
# engine's diagnostic leaked it. The engine's own diagnostic is pinned exactly by
# the stderr_has above (it names the id and the status, and nothing else), and
# stdout stays a clean channel the stub never writes to.
stdout_not_has "attach --download media-fetch curl failure: the JWT never reaches stdout" "$ATTACH_DL_JWT"
assert_path_absent "attach --download media-fetch curl failure: no destination file was created" \
	"$ATTACH_DL_MEDIA_NETFAIL_DEST"
assert_no_dest_siblings "attach --download media-fetch curl failure: nothing was left beside the destination (no partial payload)" \
	"$ATTACH_DL_MEDIA_NETFAIL_DEST"

section "jira.sh — attach --download: a NON-2xx from the MEDIA host leaves no file at all (exit 1, not even a partial)"

# The second request is the one that writes, so its failure is the only path that
# could leave a partial payload where the caller is looking. The body is staged
# inside $WORKDIR and installed only after the status is confirmed 2xx, so a 403
# must leave nothing AT the destination and nothing BESIDE it — two different
# claims about the caller's directory, which is why both absences are asserted.
ATTACH_DL_403_DEST="$WORK/download-403.bin"

reset_curl_stub
queue_attach_download_media_flow 'FORBIDDEN-ERROR-PAGE-BYTES' 403
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_403_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download media 403 -> exit 1" 1
stderr_has "attach --download media 403: the diagnostic names the attachment id and the HTTP status" \
	"download attachment 303980 failed (HTTP 403)"
equals "attach --download media 403: TWO calls (the media fetch WAS made, and rejected)" "$(call_count)" "2"
stderr_not_has "attach --download media 403: the diagnostic names the id, never the token-bearing URL" \
	"$ATTACH_DL_JWT"
stdout_not_has "attach --download media 403: the JWT never reaches stdout either" "$ATTACH_DL_JWT"
assert_path_absent "attach --download media 403: no destination file was created" "$ATTACH_DL_403_DEST"
assert_no_dest_siblings "attach --download media 403: nothing was left beside the destination (no partial payload)" \
	"$ATTACH_DL_403_DEST"

# `attach --download` under $JIRA_READ_ONLY is a REFUSAL, not a download, and its
# case lives with the other four attach/version/component/watch/vote refusals in
# the read-only gate section far below rather than here — it asserts the gate's
# wording and a zero call count, which is that section's assertion set and this
# section's helpers say nothing about. The destination path it must never create
# is declared here only because the whole $WORK/download-*.bin family is.
ATTACH_DL_READONLY_DEST="$WORK/download-read-only.bin"

# ===========================================================================
# Cycle B — inline images in description/comment bodies.
#
# The mechanism (probed live): upload the local image (Cycle A multipart) ->
# GET /attachment/content/<id> returns a 303 whose Location is
# https://api.media.atlassian.com/file/<UUID>/binary?token=<JWT> -> extract
# ONLY the UUID (never the JWT) -> md-to-adf.sh emits a mediaSingle block
# referencing that UUID (collection:"").
#
# The stub returns a REAL 303 + Location header (via -D) for the content GET,
# a REAL array upload body, and REAL 201/204 for the write. The Location's
# token is a distinctive sentinel so we can prove it never leaks to output.
# ===========================================================================
MEDIA_UUID="12345678-90ab-cdef-1234-567890abcdef"   # 36 chars, [a-f0-9-]
MEDIA_JWT="SECRETJWTTOKEN0xDEADBEEF"                # sentinel: must NEVER leak
MEDIA_LOCATION="Location: https://api.media.atlassian.com/file/$MEDIA_UUID/binary?token=$MEDIA_JWT&client=abc"
# CRLF line endings, matching real `curl -D` output for the same reason
# attach_dl_303_headers states — resolve_media_uuid's sed capture is CR-tolerant
# by construction (its trailing `.*` swallows one), so this fixture keeps the
# Cycle B cases honest about the bytes the engine really parses rather than
# carrying the CR-strip's coverage, which lives with --download's golden.
MEDIA_303_HEADERS=$(printf 'HTTP/2 303\015\n%s\015\ncontent-length: 0\015' "$MEDIA_LOCATION")

section "jira.sh — comment with an inline image: upload -> 303 media-UUID resolve -> mediaSingle in the comment body"

reset_curl_stub
INLINE_IMG1="$WORK/inline-diagram.png"
printf 'PNGDATA' >"$INLINE_IMG1"
COMMENT_IMG_MD="$WORK/comment-with-image.md"
printf 'Look at this.\n\n![a diagram](%s)\n\nThanks.\n' "$INLINE_IMG1" >"$COMMENT_IMG_MD"
# call 1: attachment upload (array body, id 303980)
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
# call 2: /attachment/content/303980 -> 303 + Location (media UUID + JWT)
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
# call 3: the comment POST
set_stub_response 3 '{"id":"10001"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "comment inline image -> exit 0" 0
equals "comment inline image: exactly THREE calls (upload + content-resolve + comment POST)" "$(call_count)" "3"
file_has "comment inline image: call 1 uploads to /issue/PSWS-1/attachments" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/attachments"
file_has "comment inline image: call 2 GETs /attachment/content/303980" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/attachment/content/303980"
argv_log_has_token "comment inline image: the resolver dumps headers (-D)" "-D"
argv_log_not_has_token "comment inline image: the resolver NEVER follows the redirect (-L absent)" "-L"
COMMENT_MEDIA_ID=$(jq -r '[.body.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "comment inline image: the comment body carries a mediaSingle referencing the resolved UUID" "$COMMENT_MEDIA_ID" "$MEDIA_UUID"
COMMENT_MEDIA_COLLECTION=$(jq -r '[.body.content[] | select(.type=="mediaSingle")][0].content[0].attrs.collection' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "comment inline image: media node collection is the EMPTY STRING (verified: null -> 400)" "$COMMENT_MEDIA_COLLECTION" ""
stdout_has "comment inline image: still emits the comment id machine line" "JIRA_COMMENT_ID=10001"
# SECURITY — the token-bearing Location must never reach any output channel.
stdout_not_has "comment inline image: the JWT never appears on stdout" "$MEDIA_JWT"
file_not_has "comment inline image: the JWT never appears in the argv log (off-argv, -K config only)" "$CURL_STUB_ARGV_LOG" "$MEDIA_JWT"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_ERR" | grep -Fq -- "$MEDIA_JWT"; then
	fail "comment inline image: the JWT never appears on stderr" "stderr leaked the JWT"
else
	pass "comment inline image: the JWT never appears on stderr"
fi
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT$CUR_ERR" | grep -Fq -- "api.media.atlassian.com"; then
	fail "comment inline image: the raw media Location host never appears in output" "output leaked the Location host"
else
	pass "comment inline image: the raw media Location host never appears in output"
fi

section "jira.sh — comment with NO inline images: unchanged single-call behavior (no upload, no resolve)"

reset_curl_stub
COMMENT_PLAIN_MD="$WORK/comment-plain.md"
printf 'Just a plain comment, no images.\n' >"$COMMENT_PLAIN_MD"
set_stub_response 1 '{"id":"10002"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_PLAIN_MD" --confirmed-site foo.atlassian.net
expect_rc "comment no images -> exit 0" 0
equals "comment no images: exactly ONE call (the comment POST — no upload, no resolve)" "$(call_count)" "1"
stdout_has "comment no images: comment id machine line" "JIRA_COMMENT_ID=10002"

section "jira.sh — comment inline image: an http(s) image is NOT uploaded (external URL, not a local file)"

reset_curl_stub
COMMENT_HTTP_MD="$WORK/comment-http-image.md"
printf 'Remote image:\n\n![x](https://example.com/x.png)\n' >"$COMMENT_HTTP_MD"
set_stub_response 1 '{"id":"10003"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_HTTP_MD" --confirmed-site foo.atlassian.net
expect_rc "comment http image -> exit 0" 0
equals "comment http image: exactly ONE call (an http(s) image is never uploaded)" "$(call_count)" "1"

section "jira.sh — comment inline image: a duplicate path is uploaded ONCE (dedup against the map)"

reset_curl_stub
INLINE_DUP="$WORK/dup.png"
printf 'DUP' >"$INLINE_DUP"
COMMENT_DUP_MD="$WORK/comment-dup.md"
printf '![one](%s)\n\nmiddle\n\n![two](%s)\n' "$INLINE_DUP" "$INLINE_DUP" >"$COMMENT_DUP_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 '{"id":"10004"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_DUP_MD" --confirmed-site foo.atlassian.net
expect_rc "comment dup image -> exit 0" 0
equals "comment dup image: same path uploaded ONCE -> THREE calls (one upload + one resolve + comment)" "$(call_count)" "3"
DUP_MEDIA_COUNT=$(jq -r '[.body.content[] | select(.type=="mediaSingle")] | length' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "comment dup image: BOTH own-line occurrences still render a mediaSingle (same UUID reused)" "$DUP_MEDIA_COUNT" "2"

section "jira.sh — resolve media UUID: a malformed Location UUID fails loud (exit 1), JWT never leaks"

reset_curl_stub
INLINE_BAD="$WORK/bad-uuid.png"
printf 'BAD' >"$INLINE_BAD"
COMMENT_BAD_MD="$WORK/comment-bad-uuid.md"
printf '![x](%s)\n' "$INLINE_BAD" >"$COMMENT_BAD_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$(printf 'HTTP/2 303\015\nLocation: https://api.media.atlassian.com/file/NOT-A-REAL-UUID/binary?token=%s\015' "$MEDIA_JWT")"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_BAD_MD" --confirmed-site foo.atlassian.net
expect_rc "resolve media uuid malformed -> exit 1" 1
stderr_has "resolve media uuid malformed: diagnostic names no UUID found" "no media UUID found"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT$CUR_ERR" | grep -Fq -- "$MEDIA_JWT"; then
	fail "resolve media uuid malformed: JWT never leaks even on the error path" "output leaked the JWT"
else
	pass "resolve media uuid malformed: JWT never leaks even on the error path"
fi
# Match the success-path assertions: the token is off-argv (in the -K config
# only) and the raw media host is never surfaced — hold the ERROR path to the
# same bar so a regression can't leak on failure while passing on success.
file_not_has "resolve media uuid malformed: JWT never appears in the argv log (off-argv, -K config only)" "$CURL_STUB_ARGV_LOG" "$MEDIA_JWT"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$CUR_OUT$CUR_ERR" | grep -Fq -- "api.media.atlassian.com"; then
	fail "resolve media uuid malformed: the raw media Location host never appears in output" "output leaked the Location host"
else
	pass "resolve media uuid malformed: the raw media Location host never appears in output"
fi

section "jira.sh — resolve media UUID: a non-3xx content response fails loud (exit 1)"

reset_curl_stub
INLINE_NON3XX="$WORK/non3xx.png"
printf 'X' >"$INLINE_NON3XX"
COMMENT_NON3XX_MD="$WORK/comment-non3xx.md"
printf '![x](%s)\n' "$INLINE_NON3XX" >"$COMMENT_NON3XX_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$COMMENT_NON3XX_MD" --confirmed-site foo.atlassian.net
expect_rc "resolve media uuid non-3xx -> exit 1" 1
stderr_has "resolve media uuid non-3xx: diagnostic names the expected 3xx" "expected a 3xx redirect"

section "jira.sh — update --description-file with an inline image: media map flows through to the PUT body"

reset_curl_stub
INLINE_UPD="$WORK/update-img.png"
printf 'UPD' >"$INLINE_UPD"
UPDATE_IMG_MD="$WORK/update-with-image.md"
printf 'New body.\n\n![shot](%s)\n' "$INLINE_UPD" >"$UPDATE_IMG_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-1 --description-file "$UPDATE_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "update --description-file inline image -> exit 0" 0
equals "update inline image: THREE calls (upload + resolve + PUT)" "$(call_count)" "3"
UPDATE_MEDIA_ID=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "update inline image: the PUT description carries a mediaSingle with the resolved UUID" "$UPDATE_MEDIA_ID" "$MEDIA_UUID"

section "jira.sh — create --description-file with an inline image: 2-step (create WITHOUT media, then follow-up description update WITH media)"

reset_curl_stub
INLINE_CREATE="$WORK/create-img.png"
printf 'CRT' >"$INLINE_CREATE"
CREATE_IMG_MD="$WORK/create-with-image.md"
printf 'Fresh issue.\n\n![figure](%s)\n' "$INLINE_CREATE" >"$CREATE_IMG_MD"
# call 1: create POST -> 201 with the new key
set_stub_response 1 '{"key":"PSWS-9","id":"90001","self":"https://foo.atlassian.net/rest/api/3/issue/90001"}' 201
# call 2: upload the inline image to the NEW key
set_stub_response 2 "[$ATTACH_OBJ_PNG]" 200
# call 3: resolve the media UUID (303 + Location)
set_stub_response 3 '' 303
set_stub_headers 3 "$MEDIA_303_HEADERS"
# call 4: follow-up description PUT
set_stub_response 4 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --description-file "$CREATE_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "create --description-file inline image -> exit 0" 0
equals "create inline image: FOUR calls (create + upload + resolve + follow-up PUT)" "$(call_count)" "4"
file_has "create inline image: call 1 is the create POST /rest/api/3/issue" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue"
CREATE_STEP1_MEDIA=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")] | length' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "create inline image: the INITIAL create body has NO media (issue did not exist yet -> empty map)" "$CREATE_STEP1_MEDIA" "0"
file_has "create inline image: call 4 PUTs the new key /rest/api/3/issue/PSWS-9" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-9"
CREATE_STEP2_MEDIA=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-4.body")
equals "create inline image: the follow-up PUT description carries the mediaSingle with the resolved UUID" "$CREATE_STEP2_MEDIA" "$MEDIA_UUID"
stdout_has "create inline image: still emits the issue-key machine line" "JIRA_ISSUE_KEY=PSWS-9"
stdout_has "create inline image: still emits the URL machine line" "JIRA_ISSUE_URL=https://foo.atlassian.net/browse/PSWS-9"

section "jira.sh — create --description-file with NO inline image: single create call, no follow-up PUT"

reset_curl_stub
CREATE_PLAIN_MD="$WORK/create-plain.md"
printf 'Plain description, no images.\n' >"$CREATE_PLAIN_MD"
set_stub_response 1 '{"key":"PSWS-10","id":"90002","self":"x"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --description-file "$CREATE_PLAIN_MD" --confirmed-site foo.atlassian.net
expect_rc "create no images -> exit 0" 0
equals "create no images: exactly ONE call (create only — no upload, resolve, or follow-up PUT)" "$(call_count)" "1"
stdout_has "create no images: issue-key machine line" "JIRA_ISSUE_KEY=PSWS-10"

section "jira.sh — update --append-file with an inline image: upload -> resolve -> fetch-existing -> PUT carries the mediaSingle (appended to the existing body)"

reset_curl_stub
INLINE_APPEND="$WORK/append-img.png"
printf 'APP' >"$INLINE_APPEND"
APPEND_IMG_MD="$WORK/append-with-image.md"
printf 'Appended note.\n\n![shot](%s)\n' "$INLINE_APPEND" >"$APPEND_IMG_MD"
# call 1: upload the inline image to the issue
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
# call 2: resolve the media UUID (303 + Location)
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
# call 3: fetch the existing description (append reads-extends-replaces)
set_stub_response 3 '{"fields":{"description":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"existing body"}]}]}}}' 200
# call 4: the whole-document description PUT
set_stub_response 4 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PSWS-1 --append-file "$APPEND_IMG_MD" --confirmed-site foo.atlassian.net
expect_rc "update --append-file inline image -> exit 0" 0
equals "update append inline image: FOUR calls (upload + resolve + fetch-existing + PUT)" "$(call_count)" "4"
file_has "update append inline image: call 4 PUTs /rest/api/3/issue/PSWS-1" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1"
APPEND_MEDIA_ID=$(jq -r '[.fields.description.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-4.body")
equals "update append inline image: the appended-description PUT body carries a mediaSingle with the resolved UUID" "$APPEND_MEDIA_ID" "$MEDIA_UUID"
APPEND_KEPT_OLD=$(jq -r '[.fields.description.content[] | select(.type=="paragraph") | .content[]?.text] | join(" ")' "$CURL_STUB_BODY_LOG_DIR/call-4.body")
TESTS_RUN=$((TESTS_RUN + 1))
case "$APPEND_KEPT_OLD" in
	*"existing body"*) pass "update append inline image: the existing description body is preserved ahead of the appended media" ;;
	*) fail "update append inline image: the existing description body is preserved ahead of the appended media" "got: $APPEND_KEPT_OLD" ;;
esac

section "jira.sh — inline-image scan agrees with md-to-adf: a fenced or trailing-text image is NOT uploaded; only a solely-image line is"

reset_curl_stub
INLINE_SOLELY="$WORK/solely.png"
printf 'SOLE' >"$INLINE_SOLELY"
# The fenced and trailing-text image paths deliberately DO NOT EXIST: if scan
# wrongly extracted either (the over-match / fence-desync regressions), require_readable_file
# would abort the whole command (exit 2) — so a clean exit 0 is itself proof
# neither was extracted. Only the solely-image line is a real, uploadable file.
SCAN_MD="$WORK/scan-mixed.md"
{
	printf 'Intro line.\n\n'
	printf '```text\n'
	printf '![in-fence](/nonexistent/in-fence.png)\n'
	printf '```\n\n'
	printf '![trailing](/nonexistent/trailing.png) (fig 1)\n\n'
	printf '![second](/nonexistent/a.png) ![third](/nonexistent/b.png)\n\n'
	printf '![real](%s)\n' "$INLINE_SOLELY"
} >"$SCAN_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 '{"id":"10009"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$SCAN_MD" --confirmed-site foo.atlassian.net
expect_rc "scan mixed images -> exit 0 (no garbled non-path aborts the command)" 0
equals "scan mixed images: exactly THREE calls — ONLY the solely-image line uploads (upload + resolve + comment)" "$(call_count)" "3"
SCAN_MEDIA_COUNT=$(jq -r '[.body.content[] | select(.type=="mediaSingle")] | length' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "scan mixed images: EXACTLY ONE mediaSingle in the comment body (fenced + trailing-text lines stayed text)" "$SCAN_MEDIA_COUNT" "1"
SCAN_MEDIA_ID=$(jq -r '[.body.content[] | select(.type=="mediaSingle")][0].content[0].attrs.id' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "scan mixed images: the one mediaSingle references the resolved UUID" "$SCAN_MEDIA_ID" "$MEDIA_UUID"

section "jira.sh — inline-image scan agrees with md-to-adf on CommonMark fences: nested, tilde, and longer fences hide their images"

# Each fenced image path deliberately does NOT EXIST (the same technique as the
# section above): a scan that treated any of them as a real image would abort
# the command at require_readable_file (exit 2). The two REAL images exist and
# must both upload — one of them sits right after a fence that only a LONGER run
# closes, so a scan that required an exact-length closer would still be inside
# that fence and skip it. Fence shapes the scan must read exactly as the
# converter does:
#   * a ```` fence CONTAINING a ``` fence — the inner ``` must not close it, so
#     the image AFTER the inner block is still fence content;
#   * a ~~~ fence, which the old scan did not recognize at all;
#   * a ~~~ fence containing ``` — only ~~~ (or longer) closes it;
#   * a ``` line carrying an info string (```js) inside an open ``` fence —
#     content, not a closer;
#   * a ``` fence containing ~~~ — a closer must be the OPENER's character;
#   * a ```` fence closed by ````` — a closer may be LONGER than the opener;
#   * a fence left unclosed by a SHORTER run — it runs to end of document.
reset_curl_stub
INLINE_FENCE_REAL="$WORK/fence-real.png"
printf 'REAL' >"$INLINE_FENCE_REAL"
INLINE_AFTER_LONGER_CLOSE="$WORK/after-longer-close.png"
printf 'AFTERLONGER' >"$INLINE_AFTER_LONGER_CLOSE"
FENCE_SCAN_MD="$WORK/scan-commonmark-fences.md"
{
	printf 'Before.\n\n'
	printf '````markdown\n'
	printf '```\n'
	printf '![inner](/nonexistent/inner.png)\n'
	printf '```\n'
	printf '![after-inner-close](/nonexistent/after-inner-close.png)\n'
	printf '````\n\n'
	printf '~~~\n'
	printf '![tilde](/nonexistent/tilde.png)\n'
	printf '~~~\n\n'
	printf '~~~text\n'
	printf '```\n'
	printf '![tilde-holds-backticks](/nonexistent/tilde-holds-backticks.png)\n'
	printf '```\n'
	printf '~~~\n\n'
	printf '```\n'
	printf '```js\n'
	printf '![after-info-line](/nonexistent/after-info-line.png)\n'
	printf '```\n\n'
	printf '```\n'
	printf '~~~\n'
	printf '![backticks-hold-tilde](/nonexistent/backticks-hold-tilde.png)\n'
	printf '~~~\n'
	printf '```\n\n'
	printf '````\n'
	printf '![inside-long](/nonexistent/inside-long.png)\n'
	printf '`````\n\n'
	printf '![after-longer-close](%s)\n\n' "$INLINE_AFTER_LONGER_CLOSE"
	printf '![real](%s)\n\n' "$INLINE_FENCE_REAL"
	printf '````\n'
	printf '```\n'
	printf '![unclosed](/nonexistent/unclosed.png)\n'
} >"$FENCE_SCAN_MD"
# calls 1-2: upload + resolve the image after the longer-closed fence;
# calls 3-4: the same for the last real image; call 5: the comment POST.
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 4 '' 303
set_stub_headers 4 "$MEDIA_303_HEADERS"
set_stub_response 5 '{"id":"10010"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$FENCE_SCAN_MD" --confirmed-site foo.atlassian.net
expect_rc "scan CommonMark fences -> exit 0 (no fenced path was extracted)" 0
equals "scan CommonMark fences: exactly FIVE calls — the TWO images outside every fence upload (2 x upload+resolve) + the comment" \
	"$(call_count)" "5"
equals "scan CommonMark fences: the image after the ````-closed-by-\`\`\`\`\` fence is the FIRST upload" \
	"$(argv_call_token_count 1 "file=@\"$INLINE_AFTER_LONGER_CLOSE\"")" "1"
equals "scan CommonMark fences: the converter agrees — both images are mediaSingle, in document order, and every fence is code" \
	"$(jq -c '[.body.content[] | .type | select(. == "mediaSingle" or . == "codeBlock")]' "$CURL_STUB_BODY_LOG_DIR/call-5.body")" \
	'["codeBlock","codeBlock","codeBlock","codeBlock","codeBlock","codeBlock","mediaSingle","mediaSingle","codeBlock"]'

section "jira.sh — inline-image scan agrees with md-to-adf: a backtick run with a backtick in its info string opens NO fence"

# ```a`b is paragraph text in CommonMark, not a fence opener, so the image line
# after it is a REAL image — uploaded by the scan, and rendered as media by the
# converter. A scan that opened a fence there would skip the upload while the
# converter still rendered the line, leaving the two disagreeing.
reset_curl_stub
INLINE_NOT_FENCED="$WORK/not-fenced.png"
printf 'NOTFENCED' >"$INLINE_NOT_FENCED"
NOT_A_FENCE_MD="$WORK/scan-not-a-fence.md"
{
	# shellcheck disable=SC2016  # the backticks are the markdown FIXTURE — they must stay literal, never expand
	printf '```a`b\n\n'
	printf '![after-non-fence](%s)\n' "$INLINE_NOT_FENCED"
} >"$NOT_A_FENCE_MD"
set_stub_response 1 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 2 '' 303
set_stub_headers 2 "$MEDIA_303_HEADERS"
set_stub_response 3 '{"id":"10011"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PSWS-1 --text-file "$NOT_A_FENCE_MD" --confirmed-site foo.atlassian.net
expect_rc "scan non-fence backtick line -> exit 0" 0
equals "scan non-fence backtick line: THREE calls — the image after it WAS uploaded" "$(call_count)" "3"
equals "scan non-fence backtick line: the converter renders it as media, and no code block" \
	"$(jq -c '[.body.content[] | .type]' "$CURL_STUB_BODY_LOG_DIR/call-3.body")" '["paragraph","mediaSingle"]'


section "jira.sh — create --json with an inline image: emitted JSON is the CREATE's 201 body (snapshot), NOT the follow-up 204 PUT"

reset_curl_stub
INLINE_CJSON="$WORK/cjson-img.png"
printf 'CJ' >"$INLINE_CJSON"
CJSON_MD="$WORK/create-json-with-image.md"
printf 'Body.\n\n![figure](%s)\n' "$INLINE_CJSON" >"$CJSON_MD"
# call 1: create POST -> 201 with the new key/id (the snapshot --json must echo)
set_stub_response 1 '{"key":"PSWS-9","id":"90001","self":"https://foo.atlassian.net/rest/api/3/issue/90001"}' 201
# call 2: upload · call 3: resolve · call 4: follow-up 204 PUT (must NOT be echoed)
set_stub_response 2 "[$ATTACH_OBJ_PNG]" 200
set_stub_response 3 '' 303
set_stub_headers 3 "$MEDIA_303_HEADERS"
set_stub_response 4 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PSWS --title "T" --description-file "$CJSON_MD" --json --confirmed-site foo.atlassian.net
expect_rc "create --json inline image -> exit 0" 0
equals "create --json inline image: FOUR calls (create + upload + resolve + follow-up PUT)" "$(call_count)" "4"
CJSON_KEY=$(printf '%s' "$CUR_OUT" | jq -r '.key')
equals "create --json inline image: emitted JSON .key is the CREATE's 201 body key" "$CJSON_KEY" "PSWS-9"
CJSON_ID=$(printf '%s' "$CUR_OUT" | jq -r '.id')
equals "create --json inline image: emitted JSON .id is the CREATE's 201 body id (the 204 PUT has no body)" "$CJSON_ID" "90001"

# ===========================================================================
# bulk — apply one existing verb to a SET of issues (client-side loop over the
# reviewed single-issue verbs). Real request/response shapes; curl stubbed.
# ===========================================================================

# --- validation (all exit 2, all BEFORE any network call) ------------------
section "jira.sh — bulk: validation (usage errors, exit 2, no network)"

# Reset the shared curl counter so the "ZERO curl calls" assertions below
# measure THIS section's calls, not a prior test's residue.
reset_curl_stub

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op frobnicate --keys "PSWS-1" --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk invalid --op -> exit 2" 2
stderr_has "bulk invalid --op: diagnostic" "invalid --op"
equals "bulk invalid --op: ZERO curl calls" "$(call_count)" "0"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --keys "PSWS-1" --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk missing --op -> exit 2" 2
stderr_has "bulk missing --op: diagnostic" "bulk requires --op"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --keys "PSWS-1" --jql "project = PSWS" --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk both --keys and --jql -> exit 2" 2
stderr_has "bulk both selectors: diagnostic" "exactly one of --keys or --jql"
equals "bulk both selectors: ZERO curl calls" "$(call_count)" "0"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --confirmed-site foo.atlassian.net
expect_rc "bulk neither selector -> exit 2" 2
stderr_has "bulk neither selector: diagnostic" "requires a set selector"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk transition without --status -> exit 2" 2
stderr_has "bulk transition no --status: diagnostic" "requires --status"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --keys "PSWS-1" --confirmed-site foo.atlassian.net
expect_rc "bulk comment without --text-file -> exit 2" 2
stderr_has "bulk comment no --text-file: diagnostic" "requires --text-file"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op update --keys "PSWS-1" --confirmed-site foo.atlassian.net
expect_rc "bulk update with no field -> exit 2" 2
stderr_has "bulk update no field: diagnostic" "at least one field"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,not-a-key,PSWS-3" --confirmed-site foo.atlassian.net
expect_rc "bulk invalid key in --keys -> exit 2" 2
stderr_has "bulk invalid key: diagnostic" "invalid ticket key in --keys"
equals "bulk invalid key: ZERO curl calls (validated before network)" "$(call_count)" "0"

run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk STRAY --op transition --status Done --keys "PSWS-1" --confirmed-site foo.atlassian.net
expect_rc "bulk stray positional -> exit 2" 2
stderr_has "bulk stray positional: diagnostic" "takes no positional"

# --- --priority is scoped to `--op update` ---------------------------------
# bulk reaches cmd_update — and therefore reads OPT_PRIORITY — ONLY for
# `--op update`. On every other op the flag would be accepted and SILENTLY
# DROPPED, so jira.sh's central scoping block refuses it there through the
# engine's own require_foreign_flag_unset. The `--op update` half of this
# contract is covered further down ("bulk --op update --priority: accepted ALONE
# by the guard, disclosed by --plan, and actually sent").
#
# Each op gets its OWN case rather than a loop: the ops carry different required
# args (--status vs --text-file), and one shared/looped assertion would let a
# single op's rejection regress while the section stayed green.
section "jira.sh — bulk --priority on a NON-update op: refused (exit 2) before any network call"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --keys "PSWS-1,PSWS-2" --status Done --priority High --confirmed-site foo.atlassian.net
expect_rc "bulk --op transition + --priority -> exit 2" 2
stderr_has "bulk transition stray --priority: diagnostic names the three commands that DO support it" \
	"$PRIORITY_SCOPE_DIAG"
equals "bulk transition stray --priority: ZERO curl calls (nothing was transitioned)" "$(call_count)" "0"

# The --text-file below is a REAL readable file, so the exit 2 cannot be coming
# from cmd_bulk's readability guard instead of the scoping block.
BULK_PRIORITY_MD="$WORK/bulk-priority-comment.md"
printf 'note\n' >"$BULK_PRIORITY_MD"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --keys "PSWS-1" --text-file "$BULK_PRIORITY_MD" --priority High --confirmed-site foo.atlassian.net
expect_rc "bulk --op comment + --priority -> exit 2" 2
stderr_has "bulk comment stray --priority: diagnostic names the three commands that DO support it" \
	"$PRIORITY_SCOPE_DIAG"
equals "bulk comment stray --priority: ZERO curl calls (no comment was posted)" "$(call_count)" "0"

# --- --reviewer is scoped to `--op update` the same way --------------------
# --reviewer has --priority's three readers exactly, but jira.sh's scoping block
# spends a SEPARATE `bulk)` case arm on it — `[ "$OPT_OP" != "update" ] || ... =1`
# — so the negation in that arm is its own failure surface: inverted, --reviewer
# would be ACCEPTED on every non-update op and then silently dropped, which is
# precisely the undisclosed write the guard exists to prevent. The transition arm's
# fall-through is covered by the sibling run-write-tests.sh; only the `bulk)` arm
# can exercise the negation.
section "jira.sh — bulk --reviewer on a NON-update op: refused (exit 2) before any network call"

# A REAL readable file, as above, so the exit 2 cannot be coming from cmd_bulk's
# readability guard instead of the scoping block.
BULK_REVIEWER_MD="$WORK/bulk-reviewer-comment.md"
printf 'note\n' >"$BULK_REVIEWER_MD"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --keys "PSWS-1" --text-file "$BULK_REVIEWER_MD" --reviewer rev@example.com --confirmed-site foo.atlassian.net
expect_rc "bulk --op comment + --reviewer -> exit 2" 2
stderr_has "bulk comment stray --reviewer: diagnostic names the three commands that DO support it" \
	"$REVIEWER_SCOPE_DIAG"
equals "bulk comment stray --reviewer: ZERO curl calls (no comment was posted, no accountId resolved)" "$(call_count)" "0"

# --- --developer is scoped to `--op update` the same way -------------------
# --developer spends its OWN `bulk)` case arm too — `[ "$OPT_OP" != "update" ] ||
# developer_is_supported=1` — so that arm's negation is its own failure surface, for
# the reason the --reviewer block one up states: inverted, --developer would be
# ACCEPTED on every non-update op and then silently dropped. Its four siblings'
# bulk arms are all covered here; this one was the gap, and it matters MORE than the
# rest rather than less, because --developer's owner list is the only one of the five
# that differs from --reviewer's (no `create`) — so a "make --developer match
# --reviewer" edit is the likely regression, and no bulk case could see it.
#
# The transition-arm fall-through for this flag lives in the sibling
# run-write-tests.sh (which defines its own copy of the needle, the two suites being
# separate processes); only the `bulk)` arm can exercise the negation.
section "jira.sh — bulk --developer on a NON-update op: refused (exit 2) before any network call"

# A REAL readable file, as on the two cases above, so the exit 2 cannot be coming
# from cmd_bulk's readability guard instead of the scoping block.
BULK_DEVELOPER_MD="$WORK/bulk-developer-comment.md"
printf 'note\n' >"$BULK_DEVELOPER_MD"

reset_curl_stub
# A COUNTERFACTUAL 201, not a response this run consumes (the zero-call assertion
# proves it never does). Queued for the same reason as --assignee's case below:
# without it, a guard regression still fails all three assertions (it exits 1 on
# the stub's own no-canned-response error, not 0), but WITH it, the failure output
# shows the actual dangerous behavior — the comment posted, --developer silently
# dropped, exit 0 — rather than a network-error artifact.
set_stub_response 1 '{"id":"10099"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --keys "PSWS-1" --text-file "$BULK_DEVELOPER_MD" --developer someone@example.com --confirmed-site foo.atlassian.net
expect_rc "bulk --op comment + --developer -> exit 2" 2
stderr_has "bulk comment stray --developer: the SAME update-only owner list, NOT a create-accepting one" \
	"$DEVELOPER_SCOPE_DIAG"
equals "bulk comment stray --developer: ZERO curl calls (no comment was posted, no accountId resolved)" "$(call_count)" "0"

# --- --assignee is scoped to `--op update` the same way --------------------
# --assignee spends its OWN `bulk)` case arm too — `[ "$OPT_OP" != "update" ] ||
# assignee_is_supported=1` — so that arm's negation is its own failure surface, for
# the reason the two blocks above state: inverted, --assignee would be ACCEPTED on
# every non-update op and then silently dropped. Its unguarded drop is also the most
# plausible real mistake of the five (the sibling run-write-tests.sh states why):
# "reassign it while you comment on it" is one natural sentence, and the caller would
# get the comment with the ticket still held by whoever had it, undisclosed.
#
# The single-command half of this contract (a stray --assignee on `transition`) lives
# in that sibling suite, which defines its own copy of the needle, the two suites being
# separate processes; only the `bulk)` arm can exercise the negation.
#
# No sibling who/priority flag is passed here on purpose: --assignee's guard runs LAST
# of the four in jira.sh, so passing one would let this case stay green with the
# --assignee arm missing entirely.
section "jira.sh — bulk --assignee on a NON-update op: refused (exit 2) before any network call"

# A REAL readable file, as on the three cases above, so the exit 2 cannot be coming
# from cmd_bulk's readability guard instead of the scoping block.
BULK_ASSIGNEE_MD="$WORK/bulk-assignee-comment.md"
printf 'note\n' >"$BULK_ASSIGNEE_MD"

reset_curl_stub
# A COUNTERFACTUAL 201, not a response this run consumes (the zero-call assertion
# proves it never does). It is queued so a guard regression lands on the exact
# behavior this case exists to forbid — the comment POSTED, the --assignee silently
# dropped, exit 0 — instead of on the stub's own no-canned-response error. Both ways
# were run against an inverted `bulk)` arm: without the queued response the regression
# exits 1 on that stub error, so all three assertions below fail either way, but only
# with it does the observed failure describe the undisclosed write itself.
set_stub_response 1 '{"id":"10099"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --keys "PSWS-1" --text-file "$BULK_ASSIGNEE_MD" --assignee someone@example.com --confirmed-site foo.atlassian.net
expect_rc "bulk --op comment + --assignee -> exit 2" 2
stderr_has "bulk comment stray --assignee: diagnostic names all FOUR commands that DO support it, search included" \
	"$ASSIGNEE_SCOPE_DIAG"
equals "bulk comment stray --assignee: ZERO curl calls (no comment was posted)" "$(call_count)" "0"

# --- ORDERING: per-command validation still runs FIRST ---------------------
# The scoping block sits AFTER the per-command validate_*_args dispatch on
# purpose: a caller whose REAL mistake is `--op frobnicate` must read THAT
# diagnostic, not a lecture about --priority. An `expect_rc 2` alone would pass
# whichever guard fired, so BOTH halves are asserted — the --op message present,
# the --priority message ABSENT.
#
# --keys IS given here on purpose, exactly as --status is on the transition case
# in run-write-tests.sh: it makes the invocation valid in every respect EXCEPT
# the --op, so the only two guards in play are the ones this ordering claim is
# about. Without it, "the --op error wins" would also be riding on
# validate_bulk_args' own INTERNAL order (its --op case at cmd-bulk.sh:163 runs
# before its set-selector requirement at :174) — an ordering this test never
# claims to assert, and whose reversal would silently change which diagnostic
# this case is really observing.
section "jira.sh — bulk: an invalid --op reports the --op error, NOT the --priority scoping error (validation order)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op frobnicate --keys "PSWS-1" --priority High --confirmed-site foo.atlassian.net
expect_rc "bulk invalid --op + --priority -> exit 2" 2
stderr_has "bulk invalid --op + --priority: the --op diagnostic is the one reported" \
	"invalid --op 'frobnicate' (must be transition|comment|update)"
stderr_not_has "bulk invalid --op + --priority: the --priority scoping diagnostic is NOT reported" \
	"$PRIORITY_SCOPE_DIAG"
equals "bulk invalid --op + --priority: ZERO curl calls" "$(call_count)" "0"

# --- --plan DRY RUN: --keys makes ZERO requests ----------------------------
section "jira.sh — bulk --plan (--keys): resolves + discloses, writes NOTHING, ZERO curl calls"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2,PSWS-3" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan --keys -> exit 0" 0
equals "bulk --plan --keys: ZERO curl calls (no read, no write)" "$(call_count)" "0"
stdout_has "bulk --plan: names the intended transition" "would transition to \"Done\""
stdout_has "bulk --plan: lists PSWS-1" "PSWS-1"
stdout_has "bulk --plan: lists PSWS-2" "PSWS-2"
stdout_has "bulk --plan: lists PSWS-3" "PSWS-3"
stdout_has "bulk --plan: states nothing was written" "NOTHING WAS WRITTEN"

# --plan --json: a structured disclosure that provably will NOT write
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2" --plan --json --confirmed-site foo.atlassian.net
expect_rc "bulk --plan --json --keys -> exit 0" 0
equals "bulk --plan --json: ZERO curl calls" "$(call_count)" "0"
PLAN_JSON="$CUR_OUT"
equals "bulk --plan --json: willWrite is false" "$(printf '%s' "$PLAN_JSON" | jq -r '.willWrite')" "false"
equals "bulk --plan --json: total is 2" "$(printf '%s' "$PLAN_JSON" | jq -r '.total')" "2"
equals "bulk --plan --json: keys array is the resolved set" "$(printf '%s' "$PLAN_JSON" | jq -c '.keys')" '["PSWS-1","PSWS-2"]'

# --- --plan DRY RUN: --jql makes ONLY the resolve read, no write -----------
section "jira.sh — bulk --plan (--jql): ONE read to resolve the set, ZERO writes"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PSWS-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"PSWS-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS AND status = Open" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan --jql -> exit 0" 0
equals "bulk --plan --jql: exactly ONE curl call (the JQL resolve)" "$(call_count)" "1"
file_has "bulk --plan --jql: the one call is the /search/jql read" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
# The transition verb writes via POST /transitions (never PUT), so a PUT-absent
# assertion would be vacuously true. Assert the actual write endpoint the op
# would hit is absent from the argv log — it would genuinely fail if --plan
# ever issued the transition verb.
file_not_has "bulk --plan --jql: the transition write endpoint was NOT hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/transitions"
stdout_has "bulk --plan --jql: lists the resolved PSWS-1" "PSWS-1"
stdout_has "bulk --plan --jql: lists the resolved PSWS-2" "PSWS-2"
stdout_has "bulk --plan --jql: states nothing was written" "NOTHING WAS WRITTEN"

# --- real bulk over --keys (transition): one 4-call walk per key -----------
section "jira.sh — bulk real (--keys, transition): a verb-request set per key + per-issue result lines"

reset_curl_stub
# PSWS-1 (calls 1-4): status -> transitions -> POST 204 -> verify
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-2 (calls 5-8)
set_stub_response 5 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 6 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 7 '' 204
set_stub_response 8 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-3 (calls 9-12)
set_stub_response 9 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 10 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 11 '' 204
set_stub_response 12 '{"fields":{"status":{"name":"Done"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2,PSWS-3" --confirmed-site foo.atlassian.net
expect_rc "bulk real --keys transition -> exit 0" 0
equals "bulk real --keys: 12 calls (3 keys x 4-call walk)" "$(call_count)" "12"
file_has "bulk real --keys: PSWS-1 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/transitions"
file_has "bulk real --keys: PSWS-2 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2/transitions"
file_has "bulk real --keys: PSWS-3 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-3/transitions"
stdout_has "bulk real --keys: PSWS-1 result line ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk real --keys: PSWS-2 result line ok" "JIRA_BULK_RESULT=PSWS-2:ok"
stdout_has "bulk real --keys: PSWS-3 result line ok" "JIRA_BULK_RESULT=PSWS-3:ok"
stdout_has "bulk real --keys: summary line" "JIRA_BULK_SUMMARY=3/3 succeeded"

# --- real bulk over --jql (transition): resolve, then a walk per key -------
section "jira.sh — bulk real (--jql, transition): JQL resolve first, then a verb-request set per resolved key"

reset_curl_stub
# call 1: the JQL resolve returns two keys
set_stub_response 1 '{"issues":[{"key":"PSWS-1","fields":{"summary":"a","status":{"name":"Open"}}},{"key":"PSWS-2","fields":{"summary":"b","status":{"name":"Open"}}}],"isLast":true}' 200
# PSWS-1 (calls 2-5)
set_stub_response 2 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 3 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 4 '' 204
set_stub_response 5 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-2 (calls 6-9)
set_stub_response 6 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 7 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 8 '' 204
set_stub_response 9 '{"fields":{"status":{"name":"Done"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS AND status = Open" --confirmed-site foo.atlassian.net
expect_rc "bulk real --jql transition -> exit 0" 0
equals "bulk real --jql: 9 calls (1 resolve + 2 keys x 4-call walk)" "$(call_count)" "9"
file_has "bulk real --jql: call 1 is the /search/jql resolve" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"
JQL_RESOLVE_SENT=$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "bulk real --jql: the resolve carried the caller's JQL verbatim" "$JQL_RESOLVE_SENT" "project = PSWS AND status = Open"
file_has "bulk real --jql: PSWS-1 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/transitions"
file_has "bulk real --jql: PSWS-2 transitions endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2/transitions"
stdout_has "bulk real --jql: PSWS-1 result line ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk real --jql: PSWS-2 result line ok" "JIRA_BULK_RESULT=PSWS-2:ok"
stdout_has "bulk real --jql: summary line" "JIRA_BULK_SUMMARY=2/2 succeeded"

# --- partial failure: issue #2 4xx does NOT abort the batch -----------------
section "jira.sh — bulk partial failure (--keys): #2 fails, #1 and #3 still processed, exit non-zero"

reset_curl_stub
# PSWS-1 (calls 1-4): succeeds
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Done"}}}' 200
# PSWS-2 (call 5): the very first request (status GET) 404s -> this issue fails
set_stub_response 5 '{"errorMessages":["Issue does not exist"]}' 404
# PSWS-3 (calls 6-9): STILL processed after #2 failed
set_stub_response 6 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 7 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 8 '' 204
set_stub_response 9 '{"fields":{"status":{"name":"Done"}}}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2,PSWS-3" --confirmed-site foo.atlassian.net
expect_rc "bulk partial failure -> exit 1 (any failure => non-zero)" 1
equals "bulk partial failure: 9 calls (4 ok + 1 failed-early + 4 ok)" "$(call_count)" "9"
stdout_has "bulk partial failure: PSWS-1 ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk partial failure: PSWS-2 failed" "JIRA_BULK_RESULT=PSWS-2:failed"
stdout_has "bulk partial failure: PSWS-3 ok (processed despite #2 failing)" "JIRA_BULK_RESULT=PSWS-3:ok"
stdout_has "bulk partial failure: accurate summary" "JIRA_BULK_SUMMARY=2/3 succeeded"
file_has "bulk partial failure: PSWS-3's transitions endpoint WAS still hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-3/transitions"

# --- real bulk over --keys (comment): one POST per issue -------------------
section "jira.sh — bulk real (--keys, comment): one comment POST per issue"

reset_curl_stub
BULK_COMMENT_MD="$WORK/bulk-comment.md"
printf 'Batch note to the team.\n' >"$BULK_COMMENT_MD"
set_stub_response 1 '{"id":"20001"}' 201
set_stub_response 2 '{"id":"20002"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_COMMENT_MD" --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real comment -> exit 0" 0
equals "bulk real comment: 2 calls (one POST per issue)" "$(call_count)" "2"
file_has "bulk real comment: PSWS-1 comment endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1/comment"
file_has "bulk real comment: PSWS-2 comment endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2/comment"
stdout_has "bulk real comment: PSWS-1 ok" "JIRA_BULK_RESULT=PSWS-1:ok"
stdout_has "bulk real comment: PSWS-2 ok" "JIRA_BULK_RESULT=PSWS-2:ok"
stdout_has "bulk real comment: summary" "JIRA_BULK_SUMMARY=2/2 succeeded"

# --- real bulk over --keys (update): one PUT per issue ---------------------
section "jira.sh — bulk real (--keys, update): one update PUT per issue"

reset_curl_stub
set_stub_response 1 '' 204
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op update --due-date 2026-12-31 --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real update -> exit 0" 0
equals "bulk real update: 2 calls (one PUT per issue)" "$(call_count)" "2"
argv_log_has_token "bulk real update: the write method is PUT" "PUT"
file_has "bulk real update: PSWS-1 issue endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1"
file_has "bulk real update: PSWS-2 issue endpoint hit" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2"
UPDATE_DUEDATE_SENT=$(jq -r '.fields.duedate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "bulk real update: PSWS-1 PUT body carries the due date" "$UPDATE_DUEDATE_SENT" "2026-12-31"
stdout_has "bulk real update: summary" "JIRA_BULK_SUMMARY=2/2 succeeded"

# --- --json: structured per-issue results + summary object -----------------
section "jira.sh — bulk --json (--keys, transition): array of results + a summary object"

reset_curl_stub
set_stub_response 1 '{"fields":{"status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
set_stub_response 2 '{"transitions":[{"id":"11","to":{"name":"Done"}}]}' 200
set_stub_response 3 '' 204
set_stub_response 4 '{"fields":{"status":{"name":"Done"}}}' 200
set_stub_response 5 '{"errorMessages":["nope"]}' 404
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Done --keys "PSWS-1,PSWS-2" --json --confirmed-site foo.atlassian.net
expect_rc "bulk --json partial -> exit 1" 1
BULK_JSON="$CUR_OUT"
equals "bulk --json: op field" "$(printf '%s' "$BULK_JSON" | jq -r '.op')" "transition"
equals "bulk --json: PSWS-1 status ok" "$(printf '%s' "$BULK_JSON" | jq -r '.results[0].status')" "ok"
equals "bulk --json: PSWS-2 status failed" "$(printf '%s' "$BULK_JSON" | jq -r '.results[1].status')" "failed"
equals "bulk --json: summary.ok" "$(printf '%s' "$BULK_JSON" | jq -r '.summary.ok')" "1"
equals "bulk --json: summary.total" "$(printf '%s' "$BULK_JSON" | jq -r '.summary.total')" "2"
equals "bulk --json: summary.failed" "$(printf '%s' "$BULK_JSON" | jq -r '.summary.failed')" "1"

# --- security: an injection-shaped JQL still routes through the escaped path -
section "jira.sh — bulk --jql: JQL flows through the SAME escaped search path (never concatenated)"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql 'project = PSWS AND summary ~ "x\" OR key=SECRET-1"' --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --jql injection-shaped -> exit 1 (zero issues resolved)" 1
equals "bulk --jql injection-shaped: still exactly ONE resolve call" "$(call_count)" "1"
file_has "bulk --jql injection-shaped: went through /search/jql (the escaped sender)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/search/jql"

# --- full-set resolution: --jql paginates to exhaustion, never caps at 50 ---
# A two-page resolve where page 1 alone holds 50 (== the OLD silent default):
# under the old code the batch would stop at 50 and misreport 50/50 complete.
# The set MUST resolve the full 60 across both pages, with truncated=false.
section "jira.sh — bulk --jql: resolves the FULL matching set (paginates to exhaustion), never silently caps at 50"

BULK_PAGE1=$(jq -nc '{issues: [range(1;51) | {key: ("PSWS-\(.)"), fields:{summary:"s",status:{name:"Open"}}}], isLast:false, nextPageToken:"PAGE2"}')
BULK_PAGE2=$(jq -nc '{issues: [range(51;61) | {key: ("PSWS-\(.)"), fields:{summary:"s",status:{name:"Open"}}}], isLast:true}')

reset_curl_stub
set_stub_response 1 "$BULK_PAGE1" 200
set_stub_response 2 "$BULK_PAGE2" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --plan --json --confirmed-site foo.atlassian.net
expect_rc "bulk --jql full-set --plan --json -> exit 0" 0
equals "bulk --jql full-set: paginated BOTH pages to exhaustion (2 resolve calls)" "$(call_count)" "2"
BULK_FULL_PLAN="$CUR_OUT"
equals "bulk --jql full-set: total is the FULL 60, not capped at 50" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.total')" "60"
equals "bulk --jql full-set: truncated is false (nothing capped)" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.truncated')" "false"
equals "bulk --jql full-set: resolvedLimit is null (no cap)" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.resolvedLimit')" "null"
equals "bulk --jql full-set: keys array holds all 60" "$(printf '%s' "$BULK_FULL_PLAN" | jq -r '.keys | length')" "60"
stdout_has "bulk --jql full-set: the set includes a page-2 key (PSWS-60)" "PSWS-60"

# The real run ACTS on the full multi-page set (comment op = one POST per issue,
# so 2 resolve pages + 60 POSTs). Proves the batch mutates all 60, not 50.
section "jira.sh — bulk --jql real: ACTS on the FULL multi-page set (not the first 50), reports the true count"

BULK_FULL_MD="$WORK/bulk-full.md"
printf 'Batch note.\n' >"$BULK_FULL_MD"
reset_curl_stub
set_stub_response 1 "$BULK_PAGE1" 200
set_stub_response 2 "$BULK_PAGE2" 200
bulk_full_n=3
while [ "$bulk_full_n" -le 62 ]; do
	set_stub_response "$bulk_full_n" '{"id":"9"}' 201
	bulk_full_n=$((bulk_full_n + 1))
done
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_FULL_MD" --jql "project = PSWS" --confirmed-site foo.atlassian.net
expect_rc "bulk --jql real full-set -> exit 0" 0
equals "bulk --jql real full-set: 62 calls (2 resolve pages + 60 comment POSTs)" "$(call_count)" "62"
stdout_has "bulk --jql real full-set: summary reports the TRUE 60, not 50" "JIRA_BULK_SUMMARY=60/60 succeeded"
stdout_not_has "bulk --jql real full-set: NOT flagged as capped (full set)" "CAPPED"
file_has "bulk --jql real full-set: a page-2 issue (PSWS-60) WAS acted on" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-60/comment"
stdout_has "bulk --jql real full-set: page-2 issue PSWS-60 result line" "JIRA_BULK_RESULT=PSWS-60:ok"

# --- disclosed cap: an explicit --limit is intentional but MUST be disclosed --
section "jira.sh — bulk --jql --limit: an explicit cap is DISCLOSED (truncated + resolvedLimit + warning), never a silent partial"

reset_curl_stub
# Page 1 alone fills the --limit 50 (isLast:false => more pages exist beyond it).
set_stub_response 1 "$BULK_PAGE1" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --limit 50 --plan --json --confirmed-site foo.atlassian.net
expect_rc "bulk --jql --limit --plan --json -> exit 0" 0
equals "bulk --jql --limit: honored the explicit cap — only ONE page fetched" "$(call_count)" "1"
BULK_CAP_PLAN="$CUR_OUT"
equals "bulk --jql --limit: total is the capped 50" "$(printf '%s' "$BULK_CAP_PLAN" | jq -r '.total')" "50"
equals "bulk --jql --limit: truncated is TRUE (cap in effect)" "$(printf '%s' "$BULK_CAP_PLAN" | jq -r '.truncated')" "true"
equals "bulk --jql --limit: resolvedLimit discloses the cap" "$(printf '%s' "$BULK_CAP_PLAN" | jq -r '.resolvedLimit')" "50"
stderr_has "bulk --jql --limit: warns that more matches may exist" "capped at --limit 50"

# A REAL capped run must never print a bare N/N succeeded — the cap is inline.
reset_curl_stub
BULK_CAP_PAGE=$(jq -nc '{issues: [range(1;3) | {key: ("PSWS-\(.)"), fields:{summary:"s",status:{name:"Open"}}}], isLast:false, nextPageToken:"MORE"}')
set_stub_response 1 "$BULK_CAP_PAGE" 200
set_stub_response 2 '{"id":"9"}' 201
set_stub_response 3 '{"id":"9"}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_FULL_MD" --jql "project = PSWS" --limit 2 --confirmed-site foo.atlassian.net
expect_rc "bulk --jql --limit real -> exit 0" 0
equals "bulk --jql --limit real: 3 calls (1 resolve + 2 comment POSTs)" "$(call_count)" "3"
stdout_has "bulk --jql --limit real: summary discloses the cap inline (never a bare N/N)" "CAPPED at --limit 2"
stderr_has "bulk --jql --limit real: warns more matches may exist" "capped at --limit 2"

# --- a resolved INVALID key fails closed BEFORE any verb request ------------
section "jira.sh — bulk --jql: a resolved invalid key (network-derived, untrusted) fails closed before any mutation"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"../evil","fields":{"summary":"s","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --confirmed-site foo.atlassian.net
expect_rc "bulk --jql resolved-invalid-key -> exit 1" 1
stderr_has "bulk --jql resolved-invalid-key: diagnostic" "resolved an invalid ticket key"
equals "bulk --jql resolved-invalid-key: only the resolve fired, ZERO verb requests" "$(call_count)" "1"

# --- --plan discloses update + comment intents too (not only transition) ----
section "jira.sh — bulk --plan (--keys): update + comment intents disclosed, ZERO curl"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op update --due-date 2026-12-31 --labels urgent,backend --keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan update -> exit 0" 0
equals "bulk --plan update: ZERO curl calls" "$(call_count)" "0"
stdout_has "bulk --plan update: names the update intent" "update field(s):"
stdout_has "bulk --plan update: field-summary lists the changed due-date aspect" "due-date"
stdout_has "bulk --plan update: field-summary lists the changed labels aspect" "labels"
stdout_has "bulk --plan update: states nothing was written" "NOTHING WAS WRITTEN"

reset_curl_stub
BULK_PLAN_MD="$WORK/bulk-plan-comment.md"
printf 'note\n' >"$BULK_PLAN_MD"
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_PLAN_MD" --keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan comment -> exit 0" 0
equals "bulk --plan comment: ZERO curl calls" "$(call_count)" "0"
stdout_has "bulk --plan comment: names the comment intent phrase" "add a comment from"
stdout_has "bulk --plan comment: states nothing was written" "NOTHING WAS WRITTEN"

# --- --priority flows through the update verb AND its own hand-kept surfaces --
# bulk delegates to cmd_update, so --priority reaches the wire for free. bulk's
# own at-least-one-field guard and its --plan disclosure both now derive from
# cmd-update.sh's update_field_summary()/has_update_field_request() — a single
# shared source, not two hand-maintained copies — and this test guards that the
# shared list actually reaches both surfaces for a real field, not just that
# they happen to agree today.
section "jira.sh — bulk --op update --priority: accepted ALONE by the guard, disclosed by --plan, and actually sent"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op update --priority High --keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan update --priority alone -> exit 0 (not the 'at least one field' usage error)" 0
equals "bulk --plan update --priority: ZERO curl calls" "$(call_count)" "0"
stdout_has "bulk --plan update --priority: the field-summary NAMES the priority change" "update field(s): priority"
stdout_has "bulk --plan update --priority: states nothing was written" "NOTHING WAS WRITTEN"

reset_curl_stub
set_stub_response 1 '' 204
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op update --priority High --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real update --priority -> exit 0" 0
equals "bulk real update --priority: 2 calls (one PUT per issue)" "$(call_count)" "2"
# The stdout channel is asserted BEFORE the body reads: a regression that makes
# the per-issue verb fail leaves no call-N.body at all, and reading one first
# would abort the suite before this line ever ran.
stdout_has "bulk real update --priority: both issues reported succeeded" "JIRA_BULK_SUMMARY=2/2 succeeded"
BULK_PRIORITY_SENT=$(jq -c '.fields.priority' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "bulk real update --priority: PSWS-1's PUT body carries {name: High}" "$BULK_PRIORITY_SENT" '{"name":"High"}'
BULK_PRIORITY_SENT_2=$(jq -c '.fields.priority' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "bulk real update --priority: PSWS-2's PUT body carries it too" "$BULK_PRIORITY_SENT_2" '{"name":"High"}'

# --- --reviewer flows through the update verb the same way -------------------
# Same shared-list claim as --priority above, for the one update field that costs a
# round trip of its own: --reviewer is a custom user-picker, so each issue's write
# is an accountId lookup THEN a PUT, against a project config that maps
# custom_fields.reviewer. The --plan half is the surface whose omission fails
# SILENTLY — a consent gate would name a set of changes that did not include the
# reviewer write, and the caller would approve a write they were never shown — and
# the real half is what proves the disclosed field actually reaches the wire.
section "jira.sh — bulk --op update --reviewer: accepted ALONE by the guard, disclosed by --plan, and actually sent"

# Its OWN projects dir, not the shared $WORK/projects: every other bulk test points
# at $WORK/noconfig deliberately, and mapping a custom field for PSWS in the shared
# dir would hand one to unrelated cases that assert the unconfigured behaviour.
BULK_REVIEWER_PROJECTS_DIR="$WORK/bulk-reviewer-projects"
mkdir -p "$BULK_REVIEWER_PROJECTS_DIR"
cat >"$BULK_REVIEWER_PROJECTS_DIR/PSWS.json" <<'EOF'
{
  "key": "PSWS",
  "custom_fields": { "reviewer": "customfield_26758" }
}
EOF

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$BULK_REVIEWER_PROJECTS_DIR" \
	sh "$JIRA" bulk --op update --reviewer rev@example.com --keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan update --reviewer alone -> exit 0 (not the 'at least one field' usage error)" 0
equals "bulk --plan update --reviewer: ZERO curl calls (not even the accountId lookup)" "$(call_count)" "0"
# The disclosure names the PRINCIPAL, not just the field: "update field(s):
# reviewer" tells a consent gate that a reviewer changes but never to whom, so
# approving it would authorize putting an unnamed person on every issue in the set.
stdout_has "bulk --plan update --reviewer: the field-summary names the reviewer AND the value" \
	"update field(s): reviewer=rev@example.com"
stdout_has "bulk --plan update --reviewer: states nothing was written" "NOTHING WAS WRITTEN"

# The SAME invocation minus --plan, so the only variable between the disclosure and
# the write is the flag itself.
reset_curl_stub
# ONE accountId lookup for the whole batch (call 1), then one PUT per issue
# (calls 2-3) — cmd_bulk pre-resolves each "who" flag before the loop, so the
# looped cmd_update reuses that id instead of repeating the lookup per issue.
# The call COUNT is the assertion that guards it: a regression that moved the
# lookup back inside the loop would need a 4th response here.
set_stub_response 1 '[{"accountId":"acc-rev-bulk-707"}]' 200
set_stub_response 2 '' 204
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$BULK_REVIEWER_PROJECTS_DIR" \
	sh "$JIRA" bulk --op update --reviewer rev@example.com --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real update --reviewer -> exit 0" 0
equals "bulk real update --reviewer: 3 calls (ONE shared accountId lookup + a PUT per issue)" "$(call_count)" "3"
# stdout before the body reads, for the reason stated on the --priority case above.
stdout_has "bulk real update --reviewer: both issues reported succeeded" "JIRA_BULK_SUMMARY=2/2 succeeded"
# The REAL run's own disclosure asymmetry, which only a bulk case can assert:
# cmd_update emits JIRA_USER_FIELDS_SET= when called directly (see
# run-write-tests.sh's update --reviewer case), but apply_bulk_verb_to_key
# discards each looped verb's stdout, so the line never reaches the caller here —
# exactly what SKILL.md's contract promises ("never surfaced by a REAL bulk --op
# update run"). It is non-vacuous because the SAME invocation's --plan half above
# IS the disclosing surface, and because the line is provably emitted by the verb
# this run loops; dropping the >/dev/null would surface it twice, once per issue.
stdout_not_has "bulk real update --reviewer: the per-issue who-field disclosure never reaches the caller's stdout" \
	"JIRA_USER_FIELDS_SET"
file_has "bulk real update --reviewer: the ONE lookup hit /user/search" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query=rev%40example.com"
BULK_REVIEWER_SENT=$(jq -c '.fields.customfield_26758' "$CURL_STUB_BODY_LOG_DIR/call-2.body")
equals "bulk real update --reviewer: PSWS-1's PUT body carries {accountId: ...} under the MAPPED field id" \
	"$BULK_REVIEWER_SENT" '{"accountId":"acc-rev-bulk-707"}'
BULK_REVIEWER_SENT_2=$(jq -c '.fields.customfield_26758' "$CURL_STUB_BODY_LOG_DIR/call-3.body")
equals "bulk real update --reviewer: PSWS-2's PUT body carries the SAME pre-resolved id (not a second lookup's)" \
	"$BULK_REVIEWER_SENT_2" '{"accountId":"acc-rev-bulk-707"}'

# --- the disclosed who-value is FOLDED onto one line (C1 controls included) ---
# The three who-values are the only ones update_field_summary quotes VERBATIM, and
# this --plan output is a consent gate a human reads line by line, so a crafted
# --reviewer must not be able to add a line to it. update_field_summary therefore
# folds each value through one_line_display (runtime.sh), which works on
# CODEPOINTS: TAB/LF/CR, the whole C1 range (U+0080–U+009F, NEL U+0085 included)
# and U+2028/U+2029 become a space, while legitimate UTF-8 — whose continuation
# bytes overlap \200-\237 — passes intact. A raw, INVALID byte such as a lone
# \205 is not a codepoint at all: jq's --arg decoding replaces it with U+FFFD.
#
# WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY DOES NOT — the same reasoning
# run-write-tests.sh's multibyte-terminator section states in full. A column-0
# assertion would be false confidence here: no tool in this harness splits a line
# on a raw \205, so `stdout_no_line_starting_with FAKE-LINE-HERE` could not fail
# even with the fold removed. Nor can the lone byte's ABSENCE be grepped — a
# lone \205 is an illegal UTF-8 sequence, so the assertion helpers' own `grep -F`
# exits 2 ("illegal byte sequence") on that needle and stdout_not_has would pass
# vacuously. What DOES discriminate: the byte-level count below (no byte in
# \200-\237 survives — the lone byte's replacement, U+FFFD, is EF BF BD), and the
# exact disclosure, U+FFFD standing where the invalid byte was.
section "jira.sh — bulk --plan update --reviewer: a raw C1 (NEL) byte in the who-value cannot forge a line in the consent disclosure"

# c1_byte_count TEXT -> how many raw bytes in \200-\237 TEXT holds. Counted, not
# grepped: a lone C1 byte is illegal UTF-8, which `grep -F` refuses as a needle.
# LC_ALL=C makes `tr` see bytes, not characters. Only meaningful for text whose
# legitimate content is ASCII or U+FFFD (EF BF BD) — a real ß (C3 9F) would count.
c1_byte_count() {
	printf '%s' "$1" | LC_ALL=C tr -dc '\200-\237' | wc -c | tr -d ' '
}

# c1_bytes_in_disclosed_line NEEDLE -> c1_byte_count of the ONE stdout line that
# carries NEEDLE (an ASCII anchor of the engine's own disclosure, e.g. "update
# field(s):"), or a "no line" message when none does, so a missing line can never
# count as zero. Scoped to that line rather than all of stdout so legitimate
# non-ASCII elsewhere in the engine's own template (an em dash is E2 80 94) cannot
# break the count for an unrelated reason. LC_ALL=C grep, because under a
# regression the line holds the very invalid bytes a UTF-8 grep refuses.
c1_bytes_in_disclosed_line() {
	cbidl_line=$(printf '%s\n' "$CUR_OUT" | LC_ALL=C grep -F -- "$1" || true)
	if [ -z "$cbidl_line" ]; then
		printf 'no stdout line contains: %s' "$1"
		return 0
	fi
	c1_byte_count "$cbidl_line"
}

# A RAW \205, not U+0085's two-byte UTF-8 form (\302\205): invalid UTF-8, the
# input a byte-level fold would have deleted and the codepoint fold must replace.
# (The valid two-byte form is covered by "bulk --plan update: all three who-values
# keep their UTF-8…" further below, whose --assignee carries a real U+0085.)
BULK_RAW_C1=$(printf '\205')
UNICODE_REPLACEMENT_CHAR=$(printf '\357\277\275')

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$BULK_REVIEWER_PROJECTS_DIR" \
	sh "$JIRA" bulk --op update --reviewer "sam${BULK_RAW_C1}FAKE-LINE-HERE" \
	--keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan update --reviewer with a raw C1 byte -> exit 0" 0
stdout_has "bulk --plan C1 reviewer: the invalid byte became U+FFFD — the forged text stays inside the engine's own disclosure as inert data" \
	"update field(s): reviewer=sam${UNICODE_REPLACEMENT_CHAR}FAKE-LINE-HERE for 2 issue(s):"
# The byte-level half, counted rather than grepped for the reason above, over the
# disclosure line itself.
equals "bulk --plan C1 reviewer: ZERO C1 bytes survive in the disclosure line" \
	"$(c1_bytes_in_disclosed_line 'update field(s):')" "0"
# Nor does the lone byte come out as the VALID two-byte NEL (\302\205) — a
# "repair" that re-encoded it instead of replacing it would still be a line break
# to a UTF-8 renderer.
stdout_not_has "bulk --plan C1 reviewer: the lone byte was not re-encoded as a valid U+0085" "$UNI_NEL"

# --- the OTHER TWO intent arms fold their own disclosed values ---------------
# The update arm's values arrive already folded, by update_field_summary (the C1
# case above). bulk_intent_phrase's transition and comment arms interpolate their
# OPT_* carriers THEMSELVES, so they carry their own one_line_display calls —
# and a fold that exists on one arm proves nothing about the other two, because
# there is no shared call site to regress.
#
# A RAW NEWLINE is the byte used here, not the C1 the update case needs: unlike
# \205, an LF genuinely does split a line for every tool in this harness, so
# BOTH channels below discriminate — the one-line needle (the fold turns the LF
# into a SPACE, so the forged text stays on the engine's own line) and the column-0 assertion the
# C1 case had to forgo as vacuous. The forged line is aimed at the plan's own
# closing "NOTHING WAS WRITTEN" row: a second one, above real keys, is exactly
# the consent-gate forgery the fold exists to stop.
section "jira.sh — bulk --plan transition: a raw newline in --status cannot forge a line in the consent disclosure"

# Command substitution strips only TRAILING newlines, so an INTERIOR one survives
# — the reason the byte is embedded via printf rather than a bash-only $'...'
# construct (this suite must also run green under dash).
BULK_FORGED_STATUS=$(printf 'Done\nFAKE-LINE-HERE')
# The fixture's own byte IS the thing under test, so it is asserted rather than
# assumed: a printf that lost the newline would leave every assertion below passing
# for a reason that proves nothing about the fold.
equals "bulk --plan forged --status fixture: really holds exactly ONE raw newline" \
	"$(printf '%s' "$BULK_FORGED_STATUS" | wc -l | tr -d ' ')" "1"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status "$BULK_FORGED_STATUS" \
	--keys "PSWS-1,PSWS-2" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan transition with a forged --status -> exit 0" 0
equals "bulk --plan forged --status: ZERO curl calls (no read, no write)" "$(call_count)" "0"
stdout_has "bulk --plan forged --status: the newline became a SPACE — the forged text stays inside the engine's own intent phrase as inert data" \
	'would transition to "Done FAKE-LINE-HERE" for 2 issue(s):'
stdout_no_line_starting_with "bulk --plan forged --status: the forged text never reaches column 0 of its own line" \
	"FAKE-LINE-HERE"

# The `(resolution: %s)` half of the same arm is a SECOND interpolation with its own
# fold call, so it regresses independently of the --status one asserted above.
section "jira.sh — bulk --plan transition: --resolution is folded too (a second interpolation, a second fold)"

BULK_FORGED_RESOLUTION=$(printf 'Fixed\nFAKE-RESOLUTION-LINE')

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status Closed --resolution "$BULK_FORGED_RESOLUTION" \
	--keys "PSWS-1" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan transition with a forged --resolution -> exit 0" 0
stdout_has "bulk --plan forged --resolution: the newline became a SPACE — the forged text stays inside the parenthesised clause" \
	'would transition to "Closed" (resolution: Fixed FAKE-RESOLUTION-LINE)'
stdout_no_line_starting_with "bulk --plan forged --resolution: the forged text never reaches column 0 of its own line" \
	"FAKE-RESOLUTION-LINE"

# The comment arm discloses --text-file's PATH, and a path may legitimately hold
# any byte but NUL and "/" — a newline included. The file must be REALLY readable
# under that name, because cmd_bulk's require_readable_file runs BEFORE the --plan
# branch, so a merely-crafted string would exit 2 there and never reach the fold.
section "jira.sh — bulk --plan comment: a raw newline in --text-file's PATH cannot forge a line either"

# The newline must sit INTERIOR to the printf format, exactly as on the two cases
# above — `"$WORK/note$(printf '\n')FAKE-PATH-LINE.md"` reads like it embeds one and
# embeds NOTHING, because command substitution strips the newline as trailing and
# yields the empty string. That version of this fixture passed every assertion below
# with the fold removed, which is what the size check guards against.
BULK_FORGED_TEXT_FILE=$(printf '%s/note\nFAKE-PATH-LINE.md' "$WORK")
printf 'note\n' >"$BULK_FORGED_TEXT_FILE"
equals "bulk --plan forged --text-file fixture: the PATH really holds exactly ONE raw newline" \
	"$(printf '%s' "$BULK_FORGED_TEXT_FILE" | wc -l | tr -d ' ')" "1"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -r "$BULK_FORGED_TEXT_FILE" ]; then
	pass "bulk --plan forged --text-file fixture: that newline-bearing path is a really readable file"
else
	fail "bulk --plan forged --text-file fixture: that newline-bearing path is a really readable file" \
		"not readable: $BULK_FORGED_TEXT_FILE"
fi

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op comment --text-file "$BULK_FORGED_TEXT_FILE" \
	--keys "PSWS-1" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan comment with a forged --text-file path -> exit 0" 0
equals "bulk --plan forged --text-file: ZERO curl calls (no comment was posted)" "$(call_count)" "0"
stdout_has "bulk --plan forged --text-file: the newline became a SPACE — the path's forged tail stays inside the intent phrase" \
	"note FAKE-PATH-LINE.md for 1 issue(s):"
stdout_no_line_starting_with "bulk --plan forged --text-file: the forged text never reaches column 0 of its own line" \
	"FAKE-PATH-LINE.md"

# ===========================================================================
# one_line_display at every former fold_disclosed_value caller: CODEPOINT
# folding. A line break or C1 control inside a disclosed value becomes a SPACE;
# legitimate UTF-8 — whose continuation bytes overlap \200-\237 — survives
# byte-for-byte; an INVALID byte becomes U+FFFD. The old byte-level fold
# (`tr -d '\200-\237'` under LC_ALL=C) deleted continuation bytes, so every
# fixture below carries characters whose UTF-8 includes one: ß = C3 9F,
# — = E2 80 94, Ü = C3 9C, À = C3 80.
# ===========================================================================

UTF8_WHO_PROJECTS_DIR="$WORK/utf8-who-projects"
mkdir -p "$UTF8_WHO_PROJECTS_DIR"
cat >"$UTF8_WHO_PROJECTS_DIR/PSWS.json" <<'EOF'
{
  "key": "PSWS",
  "custom_fields": { "developer": "customfield_25500", "reviewer": "customfield_26758" }
}
EOF

section "jira.sh — bulk --plan update: all three who-values keep their UTF-8, fold breaks to a SPACE, and lose only a literal comma"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$UTF8_WHO_PROJECTS_DIR" \
	sh "$JIRA" bulk --op update \
	--assignee "Jürgen Straße—Ünal${C1_CSI}31m${UNI_NEL}X" \
	--developer "Àlvaro${UNI_LS}Dev" \
	--reviewer "Straße, Ü${UNI_PS}Rev" \
	--keys "PSWS-1" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan update with UTF-8/C1/U+2028/U+2029/comma who-values -> exit 0" 0
equals "bulk --plan update UTF-8: ZERO curl calls (the plan resolves nothing)" "$(call_count)" "0"
stdout_has "bulk --plan update UTF-8: every who-value folded, its non-ASCII text intact, the comma gone — so the ', '-joined list holds exactly its THREE entries" \
	"would update field(s): assignee=Jürgen Straße—Ünal 31m X, developer=Àlvaro Dev, reviewer=Straße Ü Rev for 1 issue(s):"
stdout_not_has "bulk --plan update UTF-8: no raw U+009B" "$C1_CSI"
stdout_not_has "bulk --plan update UTF-8: no raw NEL" "$UNI_NEL"
stdout_not_has "bulk --plan update UTF-8: no raw U+2028" "$UNI_LS"
stdout_not_has "bulk --plan update UTF-8: no raw U+2029" "$UNI_PS"

section "jira.sh — bulk --plan transition/comment: --status, --resolution and the --text-file path keep their UTF-8"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status "Überprüfung${UNI_NEL}—ß" --resolution "Erledigt${UNI_LS}À" \
	--keys "PSWS-1" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan transition with UTF-8/NEL/U+2028 --status and --resolution -> exit 0" 0
stdout_has "bulk --plan transition UTF-8: --status and --resolution folded, non-ASCII intact" \
	'would transition to "Überprüfung —ß" (resolution: Erledigt À) for 1 issue(s):'
stdout_not_has "bulk --plan transition UTF-8: no raw NEL" "$UNI_NEL"
stdout_not_has "bulk --plan transition UTF-8: no raw U+2028" "$UNI_LS"

UTF8_TEXT_FILE="$WORK/Notiz—ß${UNI_PS}Überprüfung.md"
printf 'note\n' >"$UTF8_TEXT_FILE"
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op comment --text-file "$UTF8_TEXT_FILE" \
	--keys "PSWS-1" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan comment with a UTF-8/U+2029 --text-file path -> exit 0" 0
stdout_has "bulk --plan comment UTF-8: the path folded, non-ASCII intact" \
	"would add a comment from $WORK/Notiz—ß Überprüfung.md for 1 issue(s):"
stdout_not_has "bulk --plan comment UTF-8: no raw U+2029" "$UNI_PS"

section "jira.sh — bulk --plan transition: an INVALID byte (a lone \\233, the 8-bit CSI) becomes U+FFFD, never a raw C1 byte"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$WORK/noconfig" \
	sh "$JIRA" bulk --op transition --status "Done$(printf '\233')2JFAKE" \
	--keys "PSWS-1" --plan --confirmed-site foo.atlassian.net
expect_rc "bulk --plan transition with a lone \\233 in --status -> exit 0" 0
stdout_has "bulk --plan invalid byte: the lone \\233 became U+FFFD, the rest intact" \
	"would transition to \"Done${UNICODE_REPLACEMENT_CHAR}2JFAKE\" for 1 issue(s):"
equals "bulk --plan invalid byte: ZERO raw C1 bytes survive in the disclosure line" \
	"$(c1_bytes_in_disclosed_line 'would transition to')" "0"

section "jira.sh — resolve_account_id: its diagnostics keep the caller's UTF-8 and fold breaks/C1 to a SPACE"

# Each case also queues the search a NON-refusing resolver would go on to run
# (call 2), so the exit 1 can only come from the refusal itself.
reset_curl_stub
set_stub_response 1 '[]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee "Jürgen Straße—Ünal${C1_CSI}31m${UNI_NEL}X"
expect_rc "resolve --assignee UTF-8/C1 with no match -> exit 1" 1
stderr_has "resolve no-user UTF-8: the value folded, non-ASCII intact" "no Jira user found for 'Jürgen Straße—Ünal 31m X'"
equals "resolve no-user UTF-8: only the lookup ran — the search never did" "$(call_count)" "1"
stderr_not_has "resolve no-user UTF-8: no raw U+009B" "$C1_CSI"
stderr_not_has "resolve no-user UTF-8: no raw NEL" "$UNI_NEL"

reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-1","emailAddress":"j1@example.com","displayName":"Jürgen A"},{"accountId":"acc-2","emailAddress":"j2@example.com","displayName":"Jürgen B"}]' 200
set_stub_response 2 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --assignee "Jürgen—ß${UNI_LS}À"
expect_rc "resolve --assignee UTF-8/U+2028 with two fuzzy matches -> exit 1" 1
stderr_has "resolve ambiguous UTF-8: the value folded, non-ASCII intact" "2 Jira users matched 'Jürgen—ß À'"
equals "resolve ambiguous UTF-8: only the lookup ran — the search never did" "$(call_count)" "1"
stderr_not_has "resolve ambiguous UTF-8: no raw U+2028" "$UNI_LS"

section "jira.sh — attach --download: the receipt and a refusal keep the destination's UTF-8 and fold its breaks"

ATTACH_DL_UTF8_DEST="$WORK/Überprüfung—ß${UNI_NEL}Anhang.bin"
reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_CTRL_PAYLOAD" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_UTF8_DEST" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download to a UTF-8/NEL-named destination -> exit 0" 0
equals "attach --download UTF-8: the receipt names the path folded, non-ASCII intact" \
	"$CUR_OUT" "JIRA_ATTACHMENT_DOWNLOADED=303980 -> $WORK/Überprüfung—ß Anhang.bin"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$ATTACH_DL_UTF8_DEST" ]; then
	pass "attach --download UTF-8: the file was installed at the RAW path (the fold is display-only)"
else
	fail "attach --download UTF-8: the file was installed at the RAW path (the fold is display-only)" "missing: $ATTACH_DL_UTF8_DEST"
fi

ATTACH_DL_UTF8_EXISTING="$WORK/Vorhanden—ß${UNI_LS}Ü.bin"
printf 'x' >"$ATTACH_DL_UTF8_EXISTING"
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_UTF8_EXISTING" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download onto an existing UTF-8/U+2028-named file -> exit 2" 2
stderr_has "attach --download UTF-8 refusal: the path folded, non-ASCII intact" \
	"--download destination already exists (refusing to overwrite it): $WORK/Vorhanden—ß Ü.bin"
stderr_not_has "attach --download UTF-8 refusal: no raw U+2028" "$UNI_LS"
equals "attach --download UTF-8 refusal: ZERO curl calls" "$(call_count)" "0"

# The other three precondition refusals each fold their OWN interpolation. The
# leading-dash one is reached with a RELATIVE path (a leading "-" cannot be an
# absolute one); the directory ones name the DERIVED parent directory.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "-Überprüfung—ß${UNI_NEL}x.bin" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download of a '-'-leading UTF-8/NEL path -> exit 2" 2
stderr_has "attach --download UTF-8 leading-dash refusal: the path folded, non-ASCII intact" \
	"--download destination must not begin with '-' (it would be read as an option): -Überprüfung—ß x.bin"
stderr_not_has "attach --download UTF-8 leading-dash refusal: no raw NEL" "$UNI_NEL"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$WORK/Nicht—ß${UNI_LS}Da/out.bin" --id 303980 --confirmed-site foo.atlassian.net
expect_rc "attach --download into a missing UTF-8/U+2028-named directory -> exit 2" 2
stderr_has "attach --download UTF-8 missing-directory refusal: the directory folded, non-ASCII intact" \
	"--download destination directory does not exist: $WORK/Nicht—ß Da"
stderr_not_has "attach --download UTF-8 missing-directory refusal: no raw U+2028" "$UNI_LS"

# GUARDED ON EUID, like the ASCII unwritable-parent case above: root ignores the
# `w` bit, so under root this refusal correctly never comes.
ATTACH_DL_UTF8_READONLY_DIR="$WORK/Schreibgeschützt—Ü${UNI_PS}À"
mkdir -p "$ATTACH_DL_UTF8_READONLY_DIR"
if [ "$(id -u)" -ne 0 ]; then
	chmod 0555 "$ATTACH_DL_UTF8_READONLY_DIR"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -d "$ATTACH_DL_UTF8_READONLY_DIR" ] && [ ! -w "$ATTACH_DL_UTF8_READONLY_DIR" ]; then
		pass "attach --download UTF-8 unwritable-directory fixture: the directory really exists and is really not writable"
	else
		fail "attach --download UTF-8 unwritable-directory fixture: the directory really exists and is really not writable" \
			"chmod 0555 did not take on $ATTACH_DL_UTF8_READONLY_DIR"
	fi
	reset_curl_stub
	run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
		sh "$JIRA" attach --download "$ATTACH_DL_UTF8_READONLY_DIR/out.bin" --id 303980 --confirmed-site foo.atlassian.net
	expect_rc "attach --download into an unwritable UTF-8/U+2029-named directory -> exit 2" 2
	stderr_has "attach --download UTF-8 unwritable-directory refusal: the directory folded, non-ASCII intact" \
		"--download destination directory is not writable: $WORK/Schreibgeschützt—Ü À"
	stderr_not_has "attach --download UTF-8 unwritable-directory refusal: no raw U+2029" "$UNI_PS"
	chmod 0755 "$ATTACH_DL_UTF8_READONLY_DIR"
fi

section "jira.sh — assert_safe_dir: the refusal names a UTF-8 \$TMPDIR intact, its line breaks folded"

UTF8_UNSAFE_TMPDIR="$WORK/tmp—ß${UNI_PS}Ünsicher"
mkdir -p "$UTF8_UNSAFE_TMPDIR"
chmod 0777 "$UTF8_UNSAFE_TMPDIR"
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "TMPDIR=$UTF8_UNSAFE_TMPDIR" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "a world-writable UTF-8/U+2029-named \$TMPDIR -> exit 1 (refused)" 1
stderr_has "assert_safe_dir UTF-8: the directory folded, non-ASCII intact" \
	"the temp directory '$WORK/tmp—ß Ünsicher' is writable by other local users and has no sticky bit"
stderr_not_has "assert_safe_dir UTF-8: no raw U+2029" "$UNI_PS"
equals "assert_safe_dir UTF-8: ZERO curl calls" "$(call_count)" "0"

section "jira.sh — require_custom_field: a mis-shaped mapped id is named with its UTF-8 intact, its breaks folded"

UTF8_BADFIELD_PROJECTS_DIR="$WORK/utf8-badfield-projects"
mkdir -p "$UTF8_BADFIELD_PROJECTS_DIR"
printf '%s\n' '{"key":"BADFLD","custom_fields":{"reviewer":"Prüfer—ß Ü\u009bx"}}' >"$UTF8_BADFIELD_PROJECTS_DIR/BADFLD.json"
# The queued lookup + 204 are what an update that ACCEPTED the bad id would
# consume, so the exit 1 can only come from the shape refusal.
reset_curl_stub
set_stub_response 1 '[{"accountId":"acc-rev","emailAddress":"rev@example.com","displayName":"Rev"}]' 200
set_stub_response 2 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$UTF8_BADFIELD_PROJECTS_DIR" \
	sh "$JIRA" update BADFLD-1 --reviewer rev@example.com --confirmed-site foo.atlassian.net
expect_rc "update --reviewer mapped to a UTF-8/U+2028/U+009B-bearing field id -> exit 1" 1
stderr_has "mis-shaped field id UTF-8: the bad value folded, non-ASCII intact" \
	"resolved custom_fields.reviewer to 'Prüfer—ß Ü x', which is not a customfield_<digits> field id"
stderr_not_has "mis-shaped field id UTF-8: no raw U+2028" "$UNI_LS"
stderr_not_has "mis-shaped field id UTF-8: no raw U+009B" "$C1_CSI"
equals "mis-shaped field id UTF-8: ZERO curl calls" "$(call_count)" "0"


# --- all THREE "who" flags at once: the crossed-wire surface -----------------
# The hoist is three INDEPENDENT pre-resolves (BULK_RESOLVED_ASSIGNEE_ID /
# _DEVELOPER_ID / _REVIEWER_ID), each wired to its own cmd_update call site. A
# bug that crosses two of them — the reviewer's id read at the assignee site —
# changes NO call count and NO exit code, so the --reviewer-only case above
# passes green through it. Only three DISTINCT stub ids, asserted per field, can
# see it.
#
# It also pins the three SHAPES apart in one body: assignee is Jira's built-in
# {id: ...}, while developer and reviewer are custom user-pickers under
# {accountId: ...} at their OWN mapped field ids. Swapping a shape 400s live.
section "jira.sh — bulk --op update with all THREE who-flags: each pre-resolved id lands under its OWN field"

# Its own projects dir, for the reason the --reviewer case above states: mapping
# custom fields for PSWS in the shared dir would hand them to the sibling cases
# that assert the UNCONFIGURED behaviour. Two distinct custom field ids, so a
# developer/reviewer swap shows up as the wrong KEY as well as the wrong id.
BULK_WHO_PROJECTS_DIR="$WORK/bulk-who-projects"
mkdir -p "$BULK_WHO_PROJECTS_DIR"
cat >"$BULK_WHO_PROJECTS_DIR/PSWS.json" <<'EOF'
{
  "key": "PSWS",
  "custom_fields": { "developer": "customfield_25500", "reviewer": "customfield_26758" }
}
EOF

reset_curl_stub
# cmd_bulk pre-resolves in flag-declaration order — assignee, developer, reviewer
# (calls 1-3) — then one PUT per issue (calls 4-5). Each lookup answers with a
# DISTINCT id, so every per-field assertion below fails on a crossed wire instead
# of agreeing by coincidence.
set_stub_response 1 '[{"accountId":"acc-who-assignee-111"}]' 200
set_stub_response 2 '[{"accountId":"acc-who-developer-222"}]' 200
set_stub_response 3 '[{"accountId":"acc-who-reviewer-333"}]' 200
set_stub_response 4 '' 204
set_stub_response 5 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$BULK_WHO_PROJECTS_DIR" \
	sh "$JIRA" bulk --op update --assignee asg@example.com --developer dev@example.com \
	--reviewer rev@example.com --keys "PSWS-1,PSWS-2" --confirmed-site foo.atlassian.net
expect_rc "bulk real update all-three-who -> exit 0" 0
equals "bulk all-three-who: 5 calls (ONE lookup per distinct flag + a PUT per issue)" "$(call_count)" "5"
# stdout before the body reads, for the reason stated on the --priority case above.
stdout_has "bulk all-three-who: both issues reported succeeded" "JIRA_BULK_SUMMARY=2/2 succeeded"
file_has "bulk all-three-who: the assignee value was the one looked up" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query=asg%40example.com"
file_has "bulk all-three-who: the developer value was the one looked up" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query=dev%40example.com"
file_has "bulk all-three-who: the reviewer value was the one looked up" \
	"$CURL_STUB_ARGV_LOG" "/rest/api/3/user/search?query=rev%40example.com"
equals "bulk all-three-who: PSWS-1's assignee carries the ASSIGNEE id in the built-in {id} shape" \
	"$(jq -c '.fields.assignee' "$CURL_STUB_BODY_LOG_DIR/call-4.body")" '{"id":"acc-who-assignee-111"}'
equals "bulk all-three-who: PSWS-1's developer field carries the DEVELOPER id under {accountId}" \
	"$(jq -c '.fields.customfield_25500' "$CURL_STUB_BODY_LOG_DIR/call-4.body")" '{"accountId":"acc-who-developer-222"}'
equals "bulk all-three-who: PSWS-1's reviewer field carries the REVIEWER id under {accountId}" \
	"$(jq -c '.fields.customfield_26758' "$CURL_STUB_BODY_LOG_DIR/call-4.body")" '{"accountId":"acc-who-reviewer-333"}'
equals "bulk all-three-who: PSWS-2's assignee carries the same pre-resolved ASSIGNEE id" \
	"$(jq -c '.fields.assignee' "$CURL_STUB_BODY_LOG_DIR/call-5.body")" '{"id":"acc-who-assignee-111"}'
equals "bulk all-three-who: PSWS-2's developer field carries the same pre-resolved DEVELOPER id" \
	"$(jq -c '.fields.customfield_25500' "$CURL_STUB_BODY_LOG_DIR/call-5.body")" '{"accountId":"acc-who-developer-222"}'
equals "bulk all-three-who: PSWS-2's reviewer field carries the same pre-resolved REVIEWER id" \
	"$(jq -c '.fields.customfield_26758' "$CURL_STUB_BODY_LOG_DIR/call-5.body")" '{"accountId":"acc-who-reviewer-333"}'

# --- the hoist's actual SAFETY property: abort before ANY write --------------
# cmd_bulk places the pre-resolve AFTER the --plan return and BEFORE the loop
# precisely so an unresolvable value aborts the batch with NOTHING written,
# rather than failing once per issue after earlier ones already landed. Every
# existing assertion of that ordering is a code comment; this is the executable
# one, and it is a REAL run (not --plan), because --plan's own zero-request
# guarantee returns before the pre-resolve is ever reached.
section "jira.sh — bulk --op update: a FAILED pre-resolve aborts the whole batch before any issue is written"

reset_curl_stub
# Call 1 is the pre-resolve, answered with an EMPTY match set -> resolve_account_id
# fails loud. Calls 2-3 are COUNTERFACTUAL 204s: if the abort did not happen, both
# PUTs would SUCCEED and the count below would read 3 rather than the stub's own
# missing-response error — so exactly-1 can only mean neither issue was touched.
set_stub_response 1 '[]' 200
set_stub_response 2 '' 204
set_stub_response 3 '' 204
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$BULK_WHO_PROJECTS_DIR" \
	sh "$JIRA" bulk --op update --reviewer nobody@example.com --keys "PSWS-1,PSWS-2" \
	--confirmed-site foo.atlassian.net
expect_rc "bulk pre-resolve failure -> exit 1" 1
stderr_has "bulk pre-resolve failure: the resolver's own diagnostic surfaces" \
	"no Jira user found for 'nobody@example.com'"
equals "bulk pre-resolve failure: exactly ONE call (the failed lookup, ZERO PUTs)" "$(call_count)" "1"
file_not_has "bulk pre-resolve failure: PSWS-1 was never written" \
	"$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-1"
file_not_has "bulk pre-resolve failure: PSWS-2 was never written" \
	"$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/api/3/issue/PSWS-2"
# A partial batch would still have emitted its per-issue result lines and a
# summary; their ABSENCE is what separates "aborted before the loop" from
# "looped and every issue failed".
stdout_not_has "bulk pre-resolve failure: no per-issue result line was emitted" "JIRA_BULK_RESULT="
stdout_not_has "bulk pre-resolve failure: no batch summary was emitted" "JIRA_BULK_SUMMARY="

# --- empty-set boundaries: whitespace-only --keys and a zero-resolve --jql ---
section "jira.sh — bulk empty-set boundaries: whitespace-only --keys (exit 2) and zero-resolve --jql (exit 1)"

reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys " , ," --confirmed-site foo.atlassian.net
expect_rc "bulk --keys whitespace/comma-only -> exit 2" 2
stderr_has "bulk --keys empty: diagnostic" "contained no ticket keys"
equals "bulk --keys empty: ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --jql "project = PSWS" --confirmed-site foo.atlassian.net
expect_rc "bulk --jql zero-resolve -> exit 1" 1
stderr_has "bulk --jql zero-resolve: diagnostic" "resolved ZERO issues"

# ===========================================================================
# Agile (READ-only) — boards / board / sprints / sprint / backlog / epics / epic
# over /rest/agile/1.0/. Fixtures use the REAL live envelope shapes: the two
# distinct list envelopes (`values` vs `issues`), the epic values envelope that
# carries isLast but NO `total`, and the single-object configuration/detail
# reads. The load-bearing tests are the multi-page ones that prove FULL
# resolution across both pagination shapes.
# ===========================================================================
section "jira.sh — agile boards: real values envelope, human + --json, query params"

# Real board list element shape (id/self/name/type/location.projectKey).
AGILE_BOARDS='{"maxResults":50,"startAt":0,"total":2,"isLast":true,"values":[{"id":826,"self":"https://foo.atlassian.net/rest/agile/1.0/board/826","name":"PSWS board","type":"simple","location":{"projectKey":"PSWS"}},{"id":827,"self":"x","name":"Scrum board","type":"scrum","location":{"projectKey":"PSWS"}}]}'

reset_curl_stub
set_stub_response 1 "$AGILE_BOARDS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --project PSWS --type simple --confirmed-site foo.atlassian.net
expect_rc "boards: real envelope -> exit 0" 0
stdout_has "boards: header counts both boards" "2 board(s):"
stdout_has "boards: renders board id 826" "826"
stdout_has "boards: renders board name" "PSWS board"
stdout_has "boards: renders board type + project" "[simple]"
file_has "boards: URL carries projectKeyOrId query" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board?projectKeyOrId=PSWS&type=simple&startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_BOARDS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --json --confirmed-site foo.atlassian.net
expect_rc "boards --json -> exit 0" 0
equals "boards --json: collected array wrapped as {values:[...]}" "$(printf '%s' "$CUR_OUT" | jq -r '.values | length')" "2"
equals "boards --json: first board id" "$(printf '%s' "$CUR_OUT" | jq -r '.values[0].id')" "826"

# No filter -> no query string at all (just the paging params).
reset_curl_stub
set_stub_response 1 '{"maxResults":50,"startAt":0,"total":0,"isLast":true,"values":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --confirmed-site foo.atlassian.net
expect_rc "boards: empty set -> exit 0" 0
stdout_has "boards: empty set renders 'No boards.'" "No boards."
file_has "boards: no-filter URL has only paging params (leading ?)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board?startAt=0&maxResults=50"

section "jira.sh — agile board <id>: single configuration object (not paginated)"

AGILE_BOARD_CFG='{"id":826,"name":"PSWS board","type":"simple","columnConfig":{"columns":[{"name":"To Do","statuses":[{"id":"1"}]},{"name":"In Progress","statuses":[]},{"name":"Done","statuses":[]}]},"filter":{"id":"123"}}'
reset_curl_stub
set_stub_response 1 "$AGILE_BOARD_CFG" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" board 826 --confirmed-site foo.atlassian.net
expect_rc "board <id>: config -> exit 0" 0
equals "board <id>: single GET, no pagination" "$(call_count)" "1"
stdout_has "board <id>: header line" "Board 826: PSWS board (type simple)"
stdout_has "board <id>: lists a column" "To Do"
stdout_has "board <id>: lists another column" "In Progress"
file_has "board <id>: hits the configuration endpoint" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/configuration"

reset_curl_stub
set_stub_response 1 "$AGILE_BOARD_CFG" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" board 826 --json --confirmed-site foo.atlassian.net
expect_rc "board <id> --json -> exit 0" 0
equals "board <id> --json: raw body passthrough (columnConfig intact)" "$(printf '%s' "$CUR_OUT" | jq -r '.columnConfig.columns | length')" "3"

section "jira.sh — agile sprints <board>: real values envelope + --state query"

AGILE_SPRINTS='{"maxResults":50,"startAt":0,"total":2,"isLast":true,"values":[{"id":2212,"self":"x","state":"closed","name":"Sprint 1","startDate":"2026-01-01","endDate":"2026-01-14","completeDate":"2026-01-14","originBoardId":826,"goal":"ship"},{"id":2213,"self":"x","state":"active","name":"Sprint 2","originBoardId":826,"goal":""}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_SPRINTS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state active,closed --confirmed-site foo.atlassian.net
expect_rc "sprints: real envelope -> exit 0" 0
stdout_has "sprints: header counts both" "2 sprint(s):"
stdout_has "sprints: renders sprint id" "2212"
stdout_has "sprints: renders state" "[closed]"
stdout_has "sprints: a sprint with NO dates renders N/A window" "N/A -> N/A"
file_has "sprints: --state CSV is urlencoded into the query" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/sprint?state=active%2Cclosed&startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_SPRINTS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --json --confirmed-site foo.atlassian.net
expect_rc "sprints --json -> exit 0" 0
equals "sprints --json: collected array wrapped as {values:[...]}" "$(printf '%s' "$CUR_OUT" | jq -r '.values | length')" "2"

reset_curl_stub
set_stub_response 1 '{"maxResults":50,"startAt":0,"total":0,"isLast":true,"values":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --confirmed-site foo.atlassian.net
expect_rc "sprints: empty set -> exit 0" 0
stdout_has "sprints: empty set renders 'No sprints.'" "No sprints."

section "jira.sh — agile sprint <id>: detail (single object) vs --issues (issues envelope)"

AGILE_SPRINT_DETAIL='{"id":2212,"self":"x","state":"closed","name":"Sprint 1","startDate":"2026-01-01","endDate":"2026-01-14","goal":"ship it"}'
reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_DETAIL" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --confirmed-site foo.atlassian.net
expect_rc "sprint <id> detail -> exit 0" 0
equals "sprint <id> detail: single GET" "$(call_count)" "1"
stdout_has "sprint <id> detail: header" "Sprint 2212: Sprint 1 [closed]"
stdout_has "sprint <id> detail: goal line" "ship it"
file_has "sprint <id> detail: hits /sprint/<id>" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2212"

reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_DETAIL" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --json --confirmed-site foo.atlassian.net
expect_rc "sprint <id> detail --json -> exit 0" 0
equals "sprint <id> detail --json: raw single-object body passes straight through (goal intact)" "$(printf '%s' "$CUR_OUT" | jq -r '.goal')" "ship it"

AGILE_SPRINT_ISSUES='{"expand":"x","startAt":0,"maxResults":50,"total":2,"issues":[{"key":"PSWS-160","fields":{"summary":"do a thing","status":{"name":"Done"},"assignee":null}},{"key":"PSWS-161","fields":{"summary":"another","status":{"name":"Open"},"assignee":null}}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --issues --confirmed-site foo.atlassian.net
expect_rc "sprint <id> --issues -> exit 0" 0
stdout_has "sprint --issues: issue-envelope header" "2 issue(s):"
stdout_has "sprint --issues: renders an issue key" "PSWS-160"
stdout_has "sprint --issues: renders issue status" "[Done]"
file_has "sprint --issues: hits /sprint/<id>/issue" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2212/issue?startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_SPRINT_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2212 --issues --json --confirmed-site foo.atlassian.net
expect_rc "sprint --issues --json -> exit 0" 0
equals "sprint --issues --json: {issues:[...]} collected" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "2"

# ===========================================================================
# Agile WRITE (Cycle-2) — sprint lifecycle: create / update / start / close.
# Every case runs with a STUBBED curl (zero network) and proves the exact
# POST URL + method + JSON body shape sent, per the live-probed ground truth.
# ===========================================================================
section "jira.sh — sprint --create: POST /sprint, body carries name + integer originBoardId"

SPRINT_CREATED='{"id":2300,"self":"x","state":"future","name":"Cycle 2","originBoardId":826,"goal":"ship writes"}'
reset_curl_stub
set_stub_response 1 "$SPRINT_CREATED" 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name "Cycle 2" --goal "ship writes" \
		--start-date 2026-07-26T10:00:00.000Z --end-date 2026-08-02T10:00:00.000Z \
		--confirmed-site foo.atlassian.net
expect_rc "sprint --create -> exit 0" 0
file_has "sprint --create: POST /rest/agile/1.0/sprint" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint"
argv_log_has_token "sprint --create: uses POST" "POST"
SP_CREATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: body name" "$SP_CREATE_NAME" "Cycle 2"
SP_CREATE_BOARD=$(jq -r '.originBoardId' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: body originBoardId value" "$SP_CREATE_BOARD" "826"
SP_CREATE_BOARD_TYPE=$(jq -r '.originBoardId | type' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: originBoardId is a JSON NUMBER, not the string \"826\"" "$SP_CREATE_BOARD_TYPE" "number"
SP_CREATE_GOAL=$(jq -r '.goal' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: goal carried" "$SP_CREATE_GOAL" "ship writes"
SP_CREATE_START=$(jq -r '.startDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: startDate carried verbatim" "$SP_CREATE_START" "2026-07-26T10:00:00.000Z"
SP_CREATE_END=$(jq -r '.endDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create: endDate carried verbatim" "$SP_CREATE_END" "2026-08-02T10:00:00.000Z"
stdout_has "sprint --create: machine line names the new id" "JIRA_SPRINT_ID=2300"
stdout_has "sprint --create: machine line names the state" "JIRA_SPRINT_STATE=future"

section "jira.sh — sprint --create: minimal body is EXACTLY {name,originBoardId}"

reset_curl_stub
set_stub_response 1 '{"id":2301,"state":"future","name":"Minimal","originBoardId":826}' 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name "Minimal" --confirmed-site foo.atlassian.net
expect_rc "sprint --create minimal -> exit 0" 0
SP_CREATE_MIN_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --create minimal: body is exactly {name,originBoardId} (no empty optionals)" "$SP_CREATE_MIN_KEYS" '["name","originBoardId"]'

reset_curl_stub
set_stub_response 1 "$SPRINT_CREATED" 201
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name "Cycle 2" --json --confirmed-site foo.atlassian.net
expect_rc "sprint --create --json -> exit 0" 0
equals "sprint --create --json: raw sprint object passes straight through" "$(printf '%s' "$CUR_OUT" | jq -r '.state')" "future"

section "jira.sh — sprint --update: POST /sprint/<id>, PARTIAL body of only the changed fields"

reset_curl_stub
set_stub_response 1 '{"id":2300,"state":"future","name":"Renamed","originBoardId":826,"goal":"new goal"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --update 2300 --name "Renamed" --goal "new goal" --confirmed-site foo.atlassian.net
expect_rc "sprint --update -> exit 0" 0
file_has "sprint --update: POST /rest/agile/1.0/sprint/2300" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2300"
argv_log_has_token "sprint --update: uses POST" "POST"
SP_UPDATE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --update: body carries ONLY the changed fields" "$SP_UPDATE_KEYS" '["goal","name"]'
SP_UPDATE_NAME=$(jq -r '.name' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --update: name value" "$SP_UPDATE_NAME" "Renamed"
stdout_has "sprint --update: machine line" "JIRA_SPRINT_ID=2300"

section "jira.sh — sprint --start: body is state=active PLUS both dates (ground-truth: start needs both)"

reset_curl_stub
set_stub_response 1 '{"id":2300,"state":"active","name":"Cycle 2","originBoardId":826,"startDate":"2026-07-26T10:00:00.000Z","endDate":"2026-08-02T10:00:00.000Z"}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --end-date 2026-08-02T10:00:00.000Z \
		--confirmed-site foo.atlassian.net
expect_rc "sprint --start -> exit 0" 0
file_has "sprint --start: POST /rest/agile/1.0/sprint/2300" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2300"
SP_START_STATE=$(jq -r '.state' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --start: body state=active" "$SP_START_STATE" "active"
SP_START_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --start: body is exactly {endDate,startDate,state}" "$SP_START_KEYS" '["endDate","startDate","state"]'
SP_START_SD=$(jq -r '.startDate' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --start: startDate carried" "$SP_START_SD" "2026-07-26T10:00:00.000Z"
stdout_has "sprint --start: machine state line" "JIRA_SPRINT_STATE=active"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --confirmed-site foo.atlassian.net
expect_rc "sprint --start missing --end-date -> exit 2" 2
stderr_has "sprint --start missing end-date: diagnostic" "requires --end-date"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --end-date 2026-08-02T10:00:00.000Z --confirmed-site foo.atlassian.net
expect_rc "sprint --start missing --start-date -> exit 2" 2
stderr_has "sprint --start missing start-date: diagnostic" "requires --start-date"

section "jira.sh — sprint --close: body is EXACTLY {state:closed}"

reset_curl_stub
set_stub_response 1 '{"id":2300,"state":"closed","name":"Cycle 2","originBoardId":826}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --close 2300 --confirmed-site foo.atlassian.net
expect_rc "sprint --close -> exit 0" 0
file_has "sprint --close: POST /rest/agile/1.0/sprint/2300" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/sprint/2300"
SP_CLOSE_KEYS=$(jq -cS 'keys' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --close: body is exactly {state}" "$SP_CLOSE_KEYS" '["state"]'
SP_CLOSE_STATE=$(jq -r '.state' "$CURL_STUB_BODY_LOG_DIR/call-1.body")
equals "sprint --close: state=closed" "$SP_CLOSE_STATE" "closed"
stdout_has "sprint --close: machine state line" "JIRA_SPRINT_STATE=closed"

section "jira.sh — sprint write: mode mutual-exclusion, foreign-flag + date-format + id guards (NO network)"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --close --board 826 --name X --confirmed-site foo.atlassian.net
expect_rc "sprint: two write modes -> exit 2" 2
stderr_has "sprint: two write modes diagnostic" "exactly one write mode"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2300 --delete --confirmed-site foo.atlassian.net
expect_rc "sprint: foreign --delete mode -> exit 2" 2
stderr_has "sprint: foreign --delete diagnostic" "are not sprint modes"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --create missing --board -> exit 2" 2
stderr_has "sprint --create missing board: diagnostic" "requires --board"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --confirmed-site foo.atlassian.net
expect_rc "sprint --create missing --name -> exit 2" 2
stderr_has "sprint --create missing name: diagnostic" "requires --name"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board abc --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --create non-numeric --board -> exit 2" 2
stderr_has "sprint --create bad board: diagnostic" "invalid --board"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name X --start-date 2026-07-26 --confirmed-site foo.atlassian.net
expect_rc "sprint --create bad --start-date (date, no time) -> exit 2" 2
stderr_has "sprint --create bad start-date: diagnostic" "invalid --start-date"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name X --end-date "not-a-date" --confirmed-site foo.atlassian.net
expect_rc "sprint --create bad --end-date -> exit 2" 2
stderr_has "sprint --create bad end-date: diagnostic" "invalid --end-date"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --update abc --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --update non-numeric id -> exit 2" 2
stderr_has "sprint --update bad id: diagnostic" "invalid sprint id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --update 2300 --confirmed-site foo.atlassian.net
expect_rc "sprint --update with no fields -> exit 2" 2
stderr_has "sprint --update no fields: diagnostic" "at least one field"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 826 --name X --confirmed-site foo.atlassian.net PROJ-1
expect_rc "sprint --create with a stray positional -> exit 2" 2
stderr_has "sprint --create stray positional: diagnostic" "takes no positional"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --close 2300 --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --close with a field -> exit 2" 2
stderr_has "sprint --close with a field: diagnostic" "takes no fields"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint 2300 --goal "x" --confirmed-site foo.atlassian.net
expect_rc "sprint read with a write-only flag -> exit 2" 2
stderr_has "sprint read with write flag: diagnostic" "did you mean a write mode"

# A guard must make ZERO network calls — the usage error fires before dispatch.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --confirmed-site foo.atlassian.net
expect_rc "sprint --start guard fires before any network -> exit 2" 2
equals "sprint --start guard: no curl call was made" "$(call_count)" "0"

section "jira.sh — sprint --start: a 4xx WRITE surfaces the server's error body to stderr"

# A sprint WRITE that the server rejects (e.g. starting a sprint that is not in
# the 'future' state) must fail non-zero AND surface Jira's own error body — the
# same handle_http_status path the READ commands use, applied to a write.
reset_curl_stub
set_stub_response 1 '{"errorMessages":["Sprint can only be started from the future state"]}' 400
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --start 2300 --start-date 2026-07-26T10:00:00.000Z --end-date 2026-08-02T10:00:00.000Z \
		--confirmed-site foo.atlassian.net
expect_rc "sprint --start on a bad server state -> exit 1" 1
stderr_has "sprint --start 4xx: HTTP code in diagnostic" "HTTP 400"
stderr_has "sprint --start 4xx: Jira's own error body surfaced" "Sprint can only be started from the future state"

section "jira.sh — sprint --create: a leading-zero --board is a clean usage error, not a jq abort"

# A leading-zero numeric id ("0826") is JSON-invalid as an integer literal; fed to
# merge_int_field's `jq --argjson` it would abort jq mid-body. validate_numeric_id
# now rejects it up front as a usage error (exit 2) BEFORE any body build or
# network call — a clean failure, never jq's own exit code.
reset_curl_stub
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint --create --board 0826 --name X --confirmed-site foo.atlassian.net
expect_rc "sprint --create leading-zero --board -> exit 2 (usage, before any body build)" 2
stderr_has "sprint --create leading-zero board: diagnostic" "invalid --board"
equals "sprint --create leading-zero board: no network call was made" "$(call_count)" "0"

section "jira.sh — agile backlog <board>: issues envelope"

AGILE_BACKLOG='{"expand":"x","startAt":0,"maxResults":50,"total":1,"issues":[{"key":"PSWS-500","fields":{"summary":"backlog item","status":{"name":"Backlog"},"assignee":null}}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_BACKLOG" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" backlog 826 --confirmed-site foo.atlassian.net
expect_rc "backlog -> exit 0" 0
stdout_has "backlog: issue-envelope header" "1 issue(s):"
stdout_has "backlog: renders the item" "PSWS-500"
file_has "backlog: hits /board/<id>/backlog" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/backlog?startAt=0&maxResults=50"

section "jira.sh — agile epics <board>: values envelope with isLast and NO total"

# The epic element carries key/name/summary/done; the envelope has isLast but
# NO `total` — the exact quirk that breaks a total-only pagination loop.
AGILE_EPICS='{"maxResults":50,"startAt":0,"isLast":true,"values":[{"id":91591,"key":"PSWS-469","self":"x","name":"Auth epic","summary":"s","color":{"key":"c"},"done":false},{"id":91592,"key":"PSWS-470","self":"x","name":"Billing epic","summary":"s","color":{"key":"c"},"done":true}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_EPICS" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epics 826 --confirmed-site foo.atlassian.net
expect_rc "epics -> exit 0" 0
stdout_has "epics: header counts both" "2 epic(s):"
stdout_has "epics: renders epic key" "PSWS-469"
stdout_has "epics: renders done flag" "[done true]"
file_has "epics: hits /board/<id>/epic" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/epic?startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 '{"maxResults":50,"startAt":0,"total":0,"isLast":true,"values":[]}' 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epics 826 --confirmed-site foo.atlassian.net
expect_rc "epics: empty set -> exit 0" 0
stdout_has "epics: empty set renders 'No epics.'" "No epics."

section "jira.sh — agile epic <id> --issues: issues envelope"

AGILE_EPIC_ISSUES='{"expand":"x","startAt":0,"maxResults":50,"total":1,"issues":[{"key":"PSWS-471","fields":{"summary":"epic child","status":{"name":"In Progress"},"assignee":null}}]}'
reset_curl_stub
set_stub_response 1 "$AGILE_EPIC_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91591 --issues --confirmed-site foo.atlassian.net
expect_rc "epic --issues -> exit 0" 0
stdout_has "epic --issues: issue-envelope header" "1 issue(s):"
stdout_has "epic --issues: renders the child" "PSWS-471"
file_has "epic --issues: hits /epic/<id>/issue" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/epic/91591/issue?startAt=0&maxResults=50"

reset_curl_stub
set_stub_response 1 "$AGILE_EPIC_ISSUES" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91591 --issues --json --confirmed-site foo.atlassian.net
expect_rc "epic --issues --json -> exit 0" 0
equals "epic --issues --json: {issues:[...]} collected" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "1"

# ---- THE load-bearing pagination tests: FULL resolution across BOTH shapes ---
section "jira.sh — agile epics: MULTI-PAGE via isLast (NO total) resolves the FULL set, not page 1"

# Page 1: isLast:false and NO `total` at all -> a total-only loop would spin or
# stop wrong; the isLast:false must drive a second fetch.
AGILE_EPICS_P1=$(jq -nc '{maxResults:50,startAt:0,isLast:false,values:[range(1;51) | {id:(.), key:("PSWS-\(.)"), name:"e", summary:"s", done:false}]}')
AGILE_EPICS_P2=$(jq -nc '{maxResults:50,startAt:50,isLast:true,values:[range(51;61) | {id:(.), key:("PSWS-\(.)"), name:"e", summary:"s", done:false}]}')
reset_curl_stub
set_stub_response 1 "$AGILE_EPICS_P1" 200
set_stub_response 2 "$AGILE_EPICS_P2" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epics 826 --json --confirmed-site foo.atlassian.net
expect_rc "epics multi-page (isLast, no total) -> exit 0" 0
equals "epics multi-page: BOTH pages fetched (isLast:false drove page 2)" "$(call_count)" "2"
equals "epics multi-page: ALL 60 collected, not just page-1's 50" "$(printf '%s' "$CUR_OUT" | jq -r '.values | length')" "60"
stdout_has "epics multi-page: a page-2 epic (PSWS-60) is present" "PSWS-60"

section "jira.sh — agile issues envelope: MULTI-PAGE via total resolves the FULL set"

AGILE_ISSUES_P1=$(jq -nc '{startAt:0,maxResults:50,total:97,issues:[range(1;51) | {key:("PSWS-\(.)"), fields:{summary:"s", status:{name:"Open"}, assignee:null}}]}')
AGILE_ISSUES_P2=$(jq -nc '{startAt:50,maxResults:50,total:97,issues:[range(51;98) | {key:("PSWS-\(.)"), fields:{summary:"s", status:{name:"Open"}, assignee:null}}]}')
reset_curl_stub
set_stub_response 1 "$AGILE_ISSUES_P1" 200
set_stub_response 2 "$AGILE_ISSUES_P2" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" backlog 826 --json --confirmed-site foo.atlassian.net
expect_rc "backlog multi-page (total) -> exit 0" 0
equals "backlog multi-page: BOTH pages fetched" "$(call_count)" "2"
equals "backlog multi-page: ALL 97 collected across pages" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "97"
stdout_has "backlog multi-page: a page-2 issue (PSWS-97) is present" "PSWS-97"

section "jira.sh — agile --limit: an EXPLICIT cap is honored (never a silent over-fetch)"

reset_curl_stub
# The engine caps the REQUEST's maxResults to the remaining need and stops
# paging once the cap is reached (it relies on the server honoring maxResults,
# exactly like the existing search path — it does not truncate client-side).
# The fixture models a server that honors maxResults=10 (a 10-row page) while
# STILL reporting total:97 (more exist beyond the cap) — so the load-bearing
# proof is that only ONE page is fetched despite the larger total, and the
# request carried maxResults=10, never a silent over-fetch to exhaustion.
AGILE_ISSUES_LIM=$(jq -nc '{startAt:0,maxResults:10,total:97,issues:[range(1;11) | {key:("PSWS-\(.)"), fields:{summary:"s", status:{name:"Open"}, assignee:null}}]}')
set_stub_response 1 "$AGILE_ISSUES_LIM" 200
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" backlog 826 --limit 10 --json --confirmed-site foo.atlassian.net
expect_rc "backlog --limit 10 -> exit 0" 0
equals "backlog --limit: only ONE page fetched despite total:97 (cap stopped paging)" "$(call_count)" "1"
equals "backlog --limit: exactly the capped 10 rows kept" "$(printf '%s' "$CUR_OUT" | jq -r '.issues | length')" "10"
file_has "backlog --limit: maxResults request capped to the remaining need (10)" "$CURL_STUB_ARGV_LOG" "https://foo.atlassian.net/rest/agile/1.0/board/826/backlog?startAt=0&maxResults=10"

section "jira.sh — agile: id/flag validation (numeric ids, allow-listed --type/--state) -> exit 2"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" board PSWS-1 --confirmed-site foo.atlassian.net
expect_rc "board: non-numeric id -> exit 2" 2
stderr_has "board: non-numeric id diagnostic" "invalid board id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprint abc --confirmed-site foo.atlassian.net
expect_rc "sprint: non-numeric id -> exit 2" 2
stderr_has "sprint: non-numeric id diagnostic" "invalid sprint id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91x --issues --confirmed-site foo.atlassian.net
expect_rc "epic: non-numeric id -> exit 2" 2
stderr_has "epic: non-numeric id diagnostic" "invalid epic id"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" epic 91591 --confirmed-site foo.atlassian.net
expect_rc "epic: missing --issues -> exit 2" 2
stderr_has "epic: missing --issues diagnostic" "requires --issues"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --type bogus --confirmed-site foo.atlassian.net
expect_rc "boards: bad --type -> exit 2" 2
stderr_has "boards: bad --type diagnostic" "invalid --type"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards --project 'bad key' --confirmed-site foo.atlassian.net
expect_rc "boards: invalid --project -> exit 2" 2
stderr_has "boards: invalid --project diagnostic" "invalid project key"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state bogus --confirmed-site foo.atlassian.net
expect_rc "sprints: bad --state -> exit 2" 2
stderr_has "sprints: bad --state diagnostic" "invalid --state"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state active,bogus --confirmed-site foo.atlassian.net
expect_rc "sprints: one bad element in a --state CSV -> exit 2" 2
stderr_has "sprints: bad --state CSV element diagnostic" "invalid --state"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" sprints 826 --state active, --confirmed-site foo.atlassian.net
expect_rc "sprints: trailing-comma --state CSV (empty element) -> exit 2" 2
stderr_has "sprints: trailing-comma --state CSV diagnostic" "invalid --state"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" boards PSWS-1 --confirmed-site foo.atlassian.net
expect_rc "boards: stray positional -> exit 2" 2
stderr_has "boards: stray positional diagnostic" "takes no positional argument"

# ===========================================================================
# regression: the existing seven commands still parse/dispatch unchanged
# ===========================================================================
section "jira.sh — regression: pre-existing + new commands still recognized (-h short-circuits before dispatch, so this proves recognition, not routing)"

for pre_existing_command in view search workflow users create comment comment-edit transition update version component attach bulk boards board sprints sprint backlog epics epic; do
	run nocurl sh "$JIRA" "$pre_existing_command" -h
	expect_rc "regression: '$pre_existing_command -h' still exits 0 (command still recognized)" 0
	stdout_has "regression: '$pre_existing_command -h' still prints usage" "Usage"
done

# ===========================================================================
# preconditions: curl / jq absent
# ===========================================================================
section "jira.sh — preconditions"

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "curl absent -> exit 1" 1
stderr_has "curl absent: diagnostic" "curl is not installed"

run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "jq absent -> exit 1" 1
stderr_has "jq absent: diagnostic" "jq is not installed"

# THE jq PRECONDITION RUNS RIGHT AFTER argv PARSING — before the site-presence
# check and before any per-command validator — because several validators run
# jq themselves: issue-set.sh's --keys parse (bulk, schedule) and runtime.sh's
# one_line_display (update's and bulk's who-flag summary, attach --download's
# directory gate). Checked any later, a missing jq surfaced as a raw
# "jq: not found" line from inside a validator, and for --keys as a misleading
# exit-2 usage error. Every case below therefore asserts the SAME clean shape:
# exit 1, the missing-jq diagnostic, no shell "not found" line, no usage dump,
# and zero curl calls (the stub curl IS on this PATH, so zero is observed, not
# implied).

# assert_clean_missing_jq NAME — the shape above, for the run that just happened.
assert_clean_missing_jq() {
	expect_rc "jq absent, $1 -> exit 1 (the precondition)" 1
	stderr_has "jq absent, $1: the missing-jq diagnostic" "jq is not installed"
	stderr_not_has "jq absent, $1: no shell 'not found' line (no validator ran jq first)" "not found"
	stderr_not_has "jq absent, $1: no usage dump (not a usage error)" "Usage"
	equals "jq absent, $1: ZERO curl calls" "$(call_count)" "0"
}

reset_curl_stub
run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --reviewer x --confirmed-site foo.atlassian.net
assert_clean_missing_jq "update --reviewer"
stderr_not_has "jq absent, update --reviewer: NOT refused as a no-field update" "update requires at least one field to change"

reset_curl_stub
run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$WORK/nojq-download.bin" --id 1 --confirmed-site foo.atlassian.net
assert_clean_missing_jq "attach --download"
stderr_not_has "jq absent, attach --download: no destination refusal fired" "--download destination"

reset_curl_stub
run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op update --reviewer x --keys PSWS-1 --confirmed-site foo.atlassian.net
assert_clean_missing_jq "bulk --op update --reviewer --keys"

reset_curl_stub
run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" bulk --op transition --status Done --keys A-1,A-2 --confirmed-site foo.atlassian.net
assert_clean_missing_jq "bulk --op transition --keys"

reset_curl_stub
run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" schedule --keys PSWS-1 --to-sprint 5 --confirmed-site foo.atlassian.net
assert_clean_missing_jq "schedule --keys --to-sprint"

# BEFORE the site-presence check too: a command that omits --confirmed-site is
# told jq is missing (exit 1), not that the flag is (exit 2) — the one usage
# error that now ranks below the precondition.
reset_curl_stub
run nojq "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PSWS-1
expect_rc "jq absent, view WITHOUT --confirmed-site -> exit 1 (the precondition outranks the missing flag)" 1
stderr_has "jq absent, view without --confirmed-site: the missing-jq diagnostic" "jq is not installed"
stderr_not_has "jq absent, view without --confirmed-site: NOT the missing-site usage error" "--confirmed-site is required on every command"

# AFTER argv parsing, and not before it: help and the argv-level usage errors
# still need no jq at all.
run nojq sh "$JIRA" -h
expect_rc "jq absent, -h -> exit 0 (help needs no jq)" 0
stdout_has "jq absent, -h: prints usage" "Usage"
stderr_not_has "jq absent, -h: no missing-jq diagnostic" "jq is not installed"

run nojq sh "$JIRA" view -h
expect_rc "jq absent, view -h -> exit 0 (help needs no jq)" 0
stdout_has "jq absent, view -h: prints usage" "Usage"
stderr_not_has "jq absent, view -h: no missing-jq diagnostic" "jq is not installed"

run nojq sh "$JIRA" bogus
expect_rc "jq absent, unknown command -> exit 2 (a usage error, not the precondition)" 2
stderr_has "jq absent, unknown command: the usage diagnostic" "unknown command: bogus"
stderr_not_has "jq absent, unknown command: no missing-jq diagnostic" "jq is not installed"

run nojq sh "$JIRA" view PSWS-1 --bogus
expect_rc "jq absent, unknown option -> exit 2 (a usage error, not the precondition)" 2
stderr_has "jq absent, unknown option: the usage diagnostic" "unknown option: --bogus"
stderr_not_has "jq absent, unknown option: no missing-jq diagnostic" "jq is not installed"

# ===========================================================================
# The read-only gate ($JIRA_READ_ONLY) — its TWO halves, and the ONE exception.
#
# Half one is lib/readonlygate.sh's require_write_allowed, asserted at dispatch
# through the real CLI below: a read runs, a write is refused (exit 1) before any
# credential is opened or any curl call is made.
#
# Half two is lib/http.sh's own re-check at the network egress, and it is NOT a
# plain "GET only" rule: it permits GET plus ONE exactly-matched method/URL pair,
# POST /rest/api/3/search/jql, because Jira's REST v3 search takes its JQL in a
# JSON body. `search` and `children` are reads that POST, so without that
# exception the sink refused two of the five commands the read-only credential
# scope names.
#
# WHY BOTH HALVES ARE ASSERTED, AND WHY THE SINK GETS ITS OWN PROBES. An
# exception inside a fail-closed security check can fail in two opposite
# directions, and only one of them is visible from the CLI: too NARROW breaks
# `search` loudly (the end-to-end cases below catch it), while too WIDE — a
# prefix match, a dropped method test, a look-alike host — breaks nothing a
# passing command would notice. That direction is only observable by driving the
# predicate itself across the URLs a widened match would start admitting.
# ===========================================================================
section "jira.sh — read-only gate: search/children/view RUN under \$JIRA_READ_ONLY"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-1","fields":{"summary":"a","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" search --confirmed-site foo.atlassian.net --project PROJ
expect_rc "read-only search -> exit 0" 0
stdout_has "read-only search: the issue is rendered" "PROJ-1"
argv_log_has_token "read-only search: the request really was a POST" "POST"
argv_log_has_token "read-only search: to the exact permitted endpoint" \
	"https://foo.atlassian.net/rest/api/3/search/jql"
stderr_not_has "read-only search: no sink refusal on stderr" "refusing to send"

reset_curl_stub
set_stub_response 1 '{"issues":[{"key":"PROJ-2","fields":{"summary":"child","status":{"name":"Open"}}}],"isLast":true}' 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" children PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "read-only children -> exit 0" 0
stdout_has "read-only children: the child issue is rendered" "PROJ-2"
equals "read-only children: the parent JQL reached the wire" \
	"$(jq -r '.jql' "$CURL_STUB_BODY_LOG_DIR/call-1.body")" 'parent = "PROJ-1"'

# view is the CONTROL for the pair above: it is a GET, so it was permitted
# before the exception existed and must still be. Without it, "search works
# under read-only" could not be distinguished from "the gate stopped running".
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"a","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "read-only view (a plain GET read) -> exit 0" 0
argv_log_has_token "read-only view: the request really was a GET" "GET"

section "jira.sh — read-only gate: the exception did NOT widen — writes stay refused, before the network"

# assert_read_only_refusal NAME PHRASE — one write command's refusal: the
# fail-closed exit code, the phrase naming WHICH invocation was refused (a bare
# exit 1 is also what a network failure looks like), and ZERO curl calls. The
# call count is what makes "before any network call" an observation rather than
# a claim — every case runs under the `full` selector, so the stub curl IS on
# PATH and reachable.
assert_read_only_refusal() {
	expect_rc "read-only $1 -> exit 1 (refused)" 1
	stderr_has "read-only $1: the refusal names the invocation" "$2"
	equals "read-only $1: made ZERO curl calls" "$(call_count)" "0"
}

# assert_list_only_read_refusal NAME MODE_PHRASE — one write mode of one of the
# five commands sharing readonlygate.sh's
# `version|component|attach|watch|vote` arm: the refusal names MODE_PHRASE and
# offers that command's `--list` as its SOLE permitted read. The command name is
# taken from NAME's first word so the phrase's two halves cannot be spelled
# inconsistently at a call site — which is exactly the drift a per-command phrase
# constant used to allow.
#
# Exit 1, not 2, and that is the gate's documented choice rather than an
# accident: require_write_allowed fails CLOSED like the host allow-list, and
# reserves exit 2 for a caller's own usage errors. `attach --download`'s three
# LOCAL precondition refusals (destination exists, parent missing, unwritable)
# really are usage errors and really do exit 2 — asserted in the --download block
# far above. This gate fires before any of them.
assert_list_only_read_refusal() {
	alorr_command=${1%% *}
	assert_read_only_refusal "$1" "$2 — only '$alorr_command --list' is permitted"
}

READ_ONLY_TEXT_FILE="$WORK/read-only-comment.md"
printf 'a comment body\n' >"$READ_ONLY_TEXT_FILE"

reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" comment PROJ-1 --text-file "$READ_ONLY_TEXT_FILE" --confirmed-site foo.atlassian.net
assert_read_only_refusal comment "'comment' — that command has no read mode"

reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" update PROJ-1 --title x --confirmed-site foo.atlassian.net
assert_read_only_refusal update "'update' — that command has no read mode"

reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" create --project PROJ --title x --confirmed-site foo.atlassian.net
assert_read_only_refusal create "'create' — that command has no read mode"

section "jira.sh — read-only gate: all THREE attach writes refused, --list alone permitted (one shared arm with version/component/watch/vote)"

# `attach` is one of the five commands in readonlygate.sh's shared
# `version|component|attach|watch|vote` arm, whose single READ mode is `--list`;
# its own is_write_invocation comment states why the other three modes — the
# --file upload, --delete and --download — are all writes, --download included.
#
# The assertion set below pins that arm from BOTH sides, because it can fail in
# two opposite directions and only one of them is loud:
#   * TOO WIDE — any of attach's three writes starts being permitted, which is
#     the gate failing open for the one command whose write surface includes an
#     attachment upload and a caller-chosen local destination;
#   * TOO NARROW — `attach --list` (or `version --list`) becomes a refused write,
#     which every refusal case above would still pass, because they all assert a
#     refusal. The permitted-side cases further down are what catch it.
# All five commands share one arm and therefore one wording, so each case runs
# through the same assert_list_only_read_refusal below: a per-command phrase
# constant is how the five silently stop agreeing.

reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --delete --id 303980 --confirmed-site foo.atlassian.net
assert_list_only_read_refusal "attach --delete" "'attach --delete'"

reset_curl_stub
READ_ONLY_UPLOAD_FILE="$WORK/read-only-upload.txt"
printf 'payload\n' >"$READ_ONLY_UPLOAD_FILE"
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PROJ-1 --file "$READ_ONLY_UPLOAD_FILE" --confirmed-site foo.atlassian.net
assert_list_only_read_refusal "attach upload" "'attach --file'"

# --download's refusal carries TWO claims the other two writes cannot: the
# destination file it would have created is absent, and NOTHING was staged beside
# it. They are what separate "refused" from "refused after writing something",
# which is the whole consequence the reclassification exists to prevent.
#
# The full two-call success flow is queued as a COUNTERFACTUAL the run must never
# consume — the same role it plays in the --download block above. Without it the
# zero-call assertion would be far weaker: with the gate reverted the run really
# would resolve, fetch and install, so a regression shows TWO calls, a real file
# at the destination, and the download's own success line on stdout, instead of
# the stub's no-canned-response artifact.
reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach --download "$ATTACH_DL_READONLY_DEST" --id 303980 --confirmed-site foo.atlassian.net
assert_list_only_read_refusal "attach --download" "'attach --download'"
stdout_not_has "read-only attach --download: the download's own success line never printed" \
	"JIRA_ATTACHMENT_DOWNLOADED="
assert_path_absent "read-only attach --download: the caller-named destination was NEVER created (the local write the gate exists to refuse)" \
	"$ATTACH_DL_READONLY_DEST"
assert_no_dest_siblings "read-only attach --download: nothing was left beside the destination either" \
	"$ATTACH_DL_READONLY_DEST"

# assert_read_only_read_permitted NAME RENDERED — the POSITIVE half of the same
# arm, for a command whose `--list` read must survive the gate. Three claims a
# refusal test cannot make, and none of them is the exit code alone: the gate's
# own refusal is ABSENT from stderr (a bare exit 0 cannot tell "permitted" from
# "the gate stopped running"), exactly ONE curl call was made — so the permission
# really reached the TRANSPORT rather than merely being is_write_invocation's
# verdict — and the read actually rendered.
assert_read_only_read_permitted() {
	expect_rc "read-only $1 -> exit 0 (permitted)" 0
	# shellcheck disable=SC2016  # single-quoted on purpose: the needle is the gate's own literal message, which spells the variable NAME — expanding it here would search for the VALUE
	stderr_not_has "read-only $1: the gate's refusal never fired" '$JIRA_READ_ONLY is set: refusing'
	equals "read-only $1: made exactly ONE curl call (the read reached the transport)" "$(call_count)" "1"
	stdout_has "read-only $1: the read really rendered" "$2"
}

# The shared arm's ONE read, asserted from the PERMITTED side, for two of the
# five commands that share it. `attach --list` is the case that matters most
# here: with all three of attach's other modes classified as writes, a slip in
# the arm's single `OPT_LIST` condition (a dropped `-eq 1`, a carrier typo) turns
# attach into a command with NO usable mode under the gate at all — and every
# refusal case above would still pass, because they all assert a refusal.
# `version --list` pins the same condition through a second command, so a failure
# distinguishes "the arm's read broke" from "attach's own carriers broke".
reset_curl_stub
set_stub_response 1 "{\"fields\":{\"attachment\":[$ATTACH_OBJ_PNG]}}" 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" attach PROJ-1 --list --confirmed-site foo.atlassian.net
assert_read_only_read_permitted "attach --list" "diagram.png"

reset_curl_stub
set_stub_response 1 '[{"id":"11751","name":"3.10.0","released":false}]' 200
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --list --project PROJ --confirmed-site foo.atlassian.net
assert_read_only_read_permitted "version --list" "3.10.0"

reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" version --delete --id 11751 --confirmed-site foo.atlassian.net
assert_list_only_read_refusal "version --delete" "'version --delete'"

reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" component --create --project PROJ --name x --confirmed-site foo.atlassian.net
assert_list_only_read_refusal "component --create" "'component --create'"

# watch/vote's write is their DEFAULT (add) mode, not a flag, so write_mode_flag
# prints nothing and write_refusal_phrase takes its other branch — the arm's
# second wording, which no flag-carried mode above can reach.
reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" watch PROJ-1 --confirmed-site foo.atlassian.net
assert_list_only_read_refusal "watch add" "'watch' in its default (add) mode"

reset_curl_stub
run full "JIRA_READ_ONLY=1" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" vote PROJ-1 --confirmed-site foo.atlassian.net
assert_list_only_read_refusal "vote add" "'vote' in its default (add) mode"

# ===========================================================================
# The sink half, driven directly: lib/http.sh's read-only re-check.
#
# WHY A SECOND DRIVER, and not P4's. It looks like the P4 validator driver
# below and deliberately is not it, on three counts that do not co-change:
# it needs no OPT_* replay (the sink reads none); it must PROPAGATE the sink's
# own fail-closed `exit 1` as this process's exit status rather than catch and
# print it, because that exit IS the behavior under test; and it runs with the
# stub curl on PATH so a PERMITTED request can be observed reaching the
# transport instead of only inferred from silence.
# ===========================================================================
HTTP_SINK_DRIVER="$WORK/http-sink-driver.sh"
cat >"$HTTP_SINK_DRIVER" <<'HTTP_SINK_DRIVER_EOF'
#!/usr/bin/env sh
set -eu
hsd_script_dir=$1
hsd_case_file=$2
shift 2
SCRIPT_DIR=$hsd_script_dir
LIB_DIR="$hsd_script_dir/../lib"
MD_TO_ADF="$hsd_script_dir/md-to-adf.sh"
PROG=jira.sh
for hsd_unit in "$LIB_DIR"/*.sh; do
	. "$hsd_unit"
done
# The host both sinks pin every request against. $CURL_CONFIG_FILE deliberately
# keeps runtime.sh's empty default: the stub curl never reads its -K argument,
# and minting a credential file here would be scaffolding with no reader.
CONFIRMED_HOST=foo.atlassian.net
# The remaining arguments are the case's own ($1/$2 inside it) — a method and a
# URL travel as ARGUMENTS, never interpolated into the case text, so a
# traversal- or query-shaped URL can never become shell syntax.
. "$hsd_case_file"
HTTP_SINK_DRIVER_EOF

# The predicate case: prints its verdict rather than exiting with it, so a
# driver that died before reaching the predicate (empty stdout) can never be
# mistaken for a "refuse" — the failure mode a bare `expect_rc 1` would hide.
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters, expanded when the driver sources it, not this harness's
SINK_PREDICATE_CASE='if is_read_only_search_post "$1" "$2"; then printf "permit\n"; else printf "refuse\n"; fi'

# assert_search_post_verdict METHOD URL EXPECTED WHY — one is_read_only_search_post
# probe. No curl is reachable (`nocurl`): the predicate is pure.
assert_search_post_verdict() {
	printf '%s\n' "$SINK_PREDICATE_CASE" >"$WORK/sink-case.sh"
	run nocurl sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh" "$1" "$2"
	equals "sink: $1 $4 -> $3" "$CUR_OUT" "$3"
}

section "jira.sh — read-only sink: is_read_only_search_post admits ONE exact method/URL pair"

SEARCH_JQL_URL="https://foo.atlassian.net/rest/api/3/search/jql"

assert_search_post_verdict POST "$SEARCH_JQL_URL" permit "the exact search endpoint"

# The METHOD half. GET never consults this predicate in production (jira_curl
# short-circuits on it), so "refuse" here is the honest answer: this predicate's
# whole job is naming the ONE non-GET pair, and it must not become a second,
# looser opinion about GET.
assert_search_post_verdict GET    "$SEARCH_JQL_URL" refuse "the search endpoint"
assert_search_post_verdict PUT    "$SEARCH_JQL_URL" refuse "the search endpoint"
assert_search_post_verdict DELETE "$SEARCH_JQL_URL" refuse "the search endpoint"
assert_search_post_verdict post   "$SEARCH_JQL_URL" refuse "the search endpoint (method compare is case-SENSITIVE)"

# The URL half — every shape a prefix/substring/glob match would start admitting.
assert_search_post_verdict POST "$SEARCH_JQL_URL?maxResults=1" refuse "the search endpoint + a query string"
assert_search_post_verdict POST "$SEARCH_JQL_URL/" refuse "the search endpoint + a trailing slash"
assert_search_post_verdict POST "$SEARCH_JQL_URL/../../issue/PROJ-1" refuse "the search endpoint + a path-traversal tail"
assert_search_post_verdict POST "https://foo.atlassian.net/rest/api/3/search" refuse "a PREFIX of the search endpoint"
assert_search_post_verdict POST "https://foo.atlassian.net/rest/api/2/search/jql" refuse "the same path on API v2"
assert_search_post_verdict POST "https://evil.atlassian.net/rest/api/3/search/jql" refuse "the search path on ANOTHER host"
assert_search_post_verdict POST "https://foo.atlassian.net/rest/api/3/issue/PROJ-1/comment" refuse "an issue write"

# sink_case_run CASE_TEXT METHOD URL [VAR=VALUE...] — write CASE_TEXT to a case
# file and drive it once with METHOD/URL as its own $1/$2, under the stub-curl
# PATH. Shared by both transport helpers below: their cases differ only in which
# curl sender they call, so the run mechanics are one function, not two.
sink_case_run() {
	sink_case_text=$1; sink_method=$2; sink_url=$3; shift 3
	printf '%s\n' "$sink_case_text" >"$WORK/sink-case.sh"
	run full "$@" sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh" \
		"$sink_method" "$sink_url"
}

section "jira.sh — read-only sink: jira_curl's OWN composed check (not just the predicate it calls)"

# WHY THIS SECTION EXISTS, given the 12 predicate probes above. Those drive
# is_read_only_search_post as an isolated function; this drives the three-term
# composition that actually guards the transport —
#   is_read_only_requested && [ "$method" != GET ] && ! is_read_only_search_post
# — which nothing else in the suite can reach. Every CLI-level write is stopped
# by readonlygate.sh at DISPATCH with zero curl calls, so no command in the
# engine arrives here with a non-GET method under $JIRA_READ_ONLY. That is the
# point of the check (it is a fail-closed assertion against a FUTURE
# misclassification, per its own note) and also exactly what makes it invisible
# to a black-box test: deleting the whole if-block, or widening it to permit PUT
# as well, changes no observable CLI behavior today. The multipart sibling below
# already gets this treatment; this is the same treatment for the helper the
# change under test actually edited.
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_JIRA_CURL_CASE='jira_curl "$1" "$2"
printf "sent:%s\n" "$JIRA_HTTP_CODE"'

# The refusal wording is asserted, not just the exit code, because it is what
# distinguishes THIS sink's refusal from the multipart sibling's plain "GET
# only" — and because exit 1 alone is also what a transport error looks like.
SINK_JIRA_CURL_REFUSAL="read-only mode permits GET, plus POST to /rest/api/3/search/jql alone"
COMMENT_WRITE_URL="https://foo.atlassian.net/rest/api/3/issue/PROJ-1/comment"
# Shared with the multipart section below, which sends the same endpoint through
# the other curl helper.
ATTACHMENTS_URL="https://foo.atlassian.net/rest/api/3/issue/PROJ-1/attachments"

reset_curl_stub
sink_case_run "$SINK_JIRA_CURL_CASE" PUT "$COMMENT_WRITE_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: jira_curl PUT to an issue-comment URL under read-only -> exit 1" 1
stderr_has "sink: jira_curl's refusal names its own GET-plus-search policy" "$SINK_JIRA_CURL_REFUSAL"
equals "sink: the refused PUT made ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
sink_case_run "$SINK_JIRA_CURL_CASE" POST "$ATTACHMENTS_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: jira_curl POST to a non-search URL under read-only -> exit 1" 1
stderr_has "sink: the POST refusal carries the same GET-plus-search policy" "$SINK_JIRA_CURL_REFUSAL"
equals "sink: the refused POST made ZERO curl calls" "$(call_count)" "0"

# The METHOD term of the composition, isolated: the SAME URL the permit control
# below sends successfully, with only the method changed. A widening that drops
# or loosens the method test (permitting PUT alongside GET, say) is invisible to
# every other case in this section — the two refusals above target non-search
# URLs, so a method-only widening would still refuse them via the predicate.
reset_curl_stub
sink_case_run "$SINK_JIRA_CURL_CASE" PUT "$SEARCH_JQL_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: jira_curl PUT to the SEARCH URL under read-only -> exit 1 (the exception is POST-only)" 1
stderr_has "sink: the search URL earns no exception for a non-POST method" "$SINK_JIRA_CURL_REFUSAL"
equals "sink: the refused PUT to the search URL made ZERO curl calls" "$(call_count)" "0"

# Positive controls — the permitted pair. Without these, an if-block hardened to
# refuse everything would satisfy all three refusals above.
reset_curl_stub
set_stub_response 1 '{"issues":[],"isLast":true}' 200
sink_case_run "$SINK_JIRA_CURL_CASE" POST "$SEARCH_JQL_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: jira_curl POST to the search URL under read-only reaches the transport -> exit 0" 0
stdout_has "sink: the permitted search POST got the stubbed status back" "sent:200"
equals "sink: the permitted search POST made exactly one curl call" "$(call_count)" "1"

reset_curl_stub
set_stub_response 1 '{}' 200
sink_case_run "$SINK_JIRA_CURL_CASE" GET "$COMMENT_WRITE_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: jira_curl GET under read-only reaches the transport -> exit 0" 0
equals "sink: the permitted GET made exactly one curl call" "$(call_count)" "1"

section "jira.sh — read-only sink: jira_curl_multipart carries NO search exception (GET only)"

# WHY THIS SECTION EXISTS. jira_curl's exception is deliberately NOT repeated in
# the multipart helper: every caller there uploads an attachment, which is an
# unambiguous write, so copying it over would widen the permitted surface for
# zero capability. Nothing in the CLI can prove that — `attach` is classified a
# write and never reaches this sink under read-only — so the helper is driven
# directly. The second case is the one that bites: it sends the very URL
# jira_curl permits, so a "for symmetry" copy of the exception into this helper
# turns it green while every other test in the suite stays green too.
SINK_UPLOAD_FILE="$WORK/sink-upload.txt"
printf 'x\n' >"$SINK_UPLOAD_FILE"
# The one value this case DOES interpolate is the upload path, which the harness
# owns; the method and URL under test stay arguments (see the driver's note).
SINK_MULTIPART_CASE="jira_curl_multipart \"\$1\" \"\$2\" '$SINK_UPLOAD_FILE
'
printf 'sent:%s\\n' \"\$JIRA_HTTP_CODE\""

reset_curl_stub
sink_case_run "$SINK_MULTIPART_CASE" POST "$ATTACHMENTS_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: multipart POST to the attachments endpoint under read-only -> exit 1" 1
stderr_has "sink: multipart refusal says GET ONLY (not jira_curl's search-endpoint wording)" \
	"read-only mode permits GET only"
equals "sink: the refused multipart POST made ZERO curl calls" "$(call_count)" "0"

reset_curl_stub
sink_case_run "$SINK_MULTIPART_CASE" POST "$SEARCH_JQL_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: multipart POST to the SEARCH endpoint under read-only is refused too -> exit 1" 1
stderr_has "sink: the search-endpoint exception is absent from the multipart helper" \
	"read-only mode permits GET only"
equals "sink: the refused multipart search POST made ZERO curl calls" "$(call_count)" "0"

# Positive controls. Without these, a helper mutated to refuse EVERYTHING would
# satisfy both refusals above.
reset_curl_stub
set_stub_response 1 '[{"id":"99"}]' 200
sink_case_run "$SINK_MULTIPART_CASE" POST "$ATTACHMENTS_URL"
expect_rc "sink: multipart POST with read-only OFF reaches the transport -> exit 0" 0
stdout_has "sink: read-only OFF — the upload got the stubbed status back" "sent:200"
equals "sink: read-only OFF — exactly one curl call" "$(call_count)" "1"

reset_curl_stub
set_stub_response 1 '{}' 200
sink_case_run "$SINK_MULTIPART_CASE" GET "$ATTACHMENTS_URL" "JIRA_READ_ONLY=1"
expect_rc "sink: multipart GET under read-only is permitted (the guard is method-scoped) -> exit 0" 0
equals "sink: multipart GET under read-only — exactly one curl call" "$(call_count)" "1"

section "jira.sh — host-pin sink: assert_confirmed_host compares hostnames CASE-INSENSITIVELY, and still refuses a genuinely different host in any casing"

# assert_confirmed_host is the shared $CONFIRMED_HOST re-check of the three
# Jira-bound senders, and it had NO coverage at all — in either direction —
# because nothing the CLI can dispatch reaches it with a mismatching host: all
# three URLs are BUILT from $CONFIRMED_HOST, which is exactly what makes this an
# assertion against a future bug and exactly what makes it invisible to a
# black-box case. Deleting the function's whole `if` leaves every other test in
# this suite green. So it is driven through the same HTTP_SINK_DRIVER the
# read-only sink sections above use, which pins $CONFIRMED_HOST to
# foo.atlassian.net and passes the URL under test as an ARGUMENT.
#
# THE CASE FOLD IS A DELIBERATE, DISCLOSED BEHAVIOR CHANGE, not a cleanup
# side effect. The three copies this function replaced compared BYTE-EXACTLY, so
# a differently-cased-but-identical host was REFUSED; folding both sides (the
# `downcase` credentials.sh's own host-binding check and is_media_host already
# use) makes it ACCEPTED. That is the correct direction — hostnames are
# case-insensitive per DNS, and sitegate.sh's normalize_site preserves the
# caller's own casing, so a byte-exact pin refused a request that genuinely does
# belong to the confirmed site — but it is a widening, and a widening only stays
# safe while the OTHER half holds. Hence both halves below: the fold accepts a
# case variant of the SAME host, and refuses a DIFFERENT host however it is
# cased. A fold implemented as a substring/prefix test, or one that downcased
# only one side, passes the first half and fails the second.
#
# BOTH SENDERS, because the consolidation is what makes one test speak for three
# call sites: the function is shared, but each sender calls it itself, so a
# regression that dropped the call from ONE of them is invisible to a case that
# only drives the other. The third caller,
# fetch_attachment_content_redirect, cannot be given a mismatching host at all —
# it builds its URL internally from $CONFIRMED_HOST rather than taking one — so
# it is unreachable here by construction, not by omission.
SINK_HOST_PIN_DIAG_TAIL="does not match the confirmed site 'foo.atlassian.net' (fail closed)"
# The SAME host as the driver's $CONFIRMED_HOST, in a different casing. Every
# other byte of the URL is a path jira_curl sends unchanged.
SINK_HOST_CASED_URL="https://FOO.Atlassian.NET/rest/api/3/issue/PROJ-1"
SINK_HOST_CASED_ATTACHMENTS_URL="https://FOO.Atlassian.NET/rest/api/3/issue/PROJ-1/attachments"
# A GENUINELY different host, spelled in upper case so a fold that compared the
# wrong pair of values (or folded only one side) cannot slip through as a match.
SINK_HOST_OTHER_URL="https://EVIL.ATLASSIAN.NET/rest/api/3/issue/PROJ-1"
SINK_HOST_OTHER_ATTACHMENTS_URL="https://EVIL.ATLASSIAN.NET/rest/api/3/issue/PROJ-1/attachments"

# (a) ACCEPTED — jira_curl, a case variant of the confirmed host. The stubbed 200
# reaching stdout is what separates "permitted" from "the sender died quietly":
# an exit-0 alone would also be satisfied by a function that never sent anything.
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1"}' 200
sink_case_run "$SINK_JIRA_CURL_CASE" GET "$SINK_HOST_CASED_URL"
expect_rc "sink: jira_curl to a CASE-VARIANT of the confirmed host -> exit 0 (hostnames are case-insensitive)" 0
stdout_has "sink: the case-variant host got the stubbed status back (the request really went out)" "sent:200"
equals "sink: the case-variant host made exactly ONE curl call" "$(call_count)" "1"
stderr_not_has "sink: no host-pin refusal fired for the case variant" "$SINK_HOST_PIN_DIAG_TAIL"
# The URL is sent AS THE CALLER SPELLED IT: the fold is a comparison, not a
# rewrite. A regression that normalized the URL itself would still exit 0 here.
argv_log_has_token "sink: the case-variant URL reaches curl with its own casing intact (the fold compares, it does not rewrite)" \
	"$SINK_HOST_CASED_URL"

# (b) REFUSED — jira_curl, a different host. Upper-cased deliberately: this is
# the half that fails if the fold is ever loosened into something that is not an
# equality over two downcased hosts.
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1"}' 200
sink_case_run "$SINK_JIRA_CURL_CASE" GET "$SINK_HOST_OTHER_URL"
expect_rc "sink: jira_curl to a DIFFERENT host (upper-cased) -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal names the extracted host and the confirmed site" \
	"internal: refusing to send a request to 'EVIL.ATLASSIAN.NET' — it $SINK_HOST_PIN_DIAG_TAIL"
equals "sink: the refused host made ZERO curl calls" "$(call_count)" "0"
stdout_not_has "sink: the refused host never reported a status" "sent:"

# (c) ACCEPTED — the multipart sender, same case variant. Its call to the shared
# assert is its own; without this case a regression that dropped it from the
# multipart helper alone would stay green.
reset_curl_stub
set_stub_response 1 '[{"id":"99"}]' 200
sink_case_run "$SINK_MULTIPART_CASE" POST "$SINK_HOST_CASED_ATTACHMENTS_URL"
expect_rc "sink: jira_curl_multipart to a CASE-VARIANT of the confirmed host -> exit 0" 0
stdout_has "sink: the multipart case-variant host got the stubbed status back" "sent:200"
equals "sink: the multipart case-variant host made exactly ONE curl call" "$(call_count)" "1"

# (d) REFUSED — the multipart sender, a different host.
reset_curl_stub
set_stub_response 1 '[{"id":"99"}]' 200
sink_case_run "$SINK_MULTIPART_CASE" POST "$SINK_HOST_OTHER_ATTACHMENTS_URL"
expect_rc "sink: jira_curl_multipart to a DIFFERENT host (upper-cased) -> exit 1 (fail closed)" 1
stderr_has "sink: the multipart refusal carries the SAME shared diagnostic (one owner, not a per-sender copy)" \
	"internal: refusing to send a request to 'EVIL.ATLASSIAN.NET' — it $SINK_HOST_PIN_DIAG_TAIL"
equals "sink: the refused multipart host made ZERO curl calls" "$(call_count)" "0"
stdout_not_has "sink: the refused multipart host never reported a status" "sent:"

# ===========================================================================
# download_attachment_content's FIVE sink-side checks, driven directly.
#
# WHY THE CLI CANNOT REACH ANY OF THEM. All five are defense-in-depth against a
# FUTURE bug or an environment the pre-flight cannot see, so by construction
# nothing this engine can dispatch today arrives at them: dispatch refuses
# `attach --download` under $JIRA_READ_ONLY before any request,
# resolve_media_download_url pins the Location's host before this function ever
# sees it, every destination this suite can name is on the same filesystem as
# $WORKDIR, the install `ln` does not fail on a writable destination directory —
# which is the only kind cmd-attach.sh's pre-flight lets through — and that
# pre-flight also refuses any destination NAME that already exists, which is the
# only way either of the two entity-at-the-destination races (a symlink, or a real
# directory) can be set up. Every one of them can therefore be DELETED with no
# observable change to any CLI-level test — which is exactly why they are driven
# here, through the same HTTP_SINK_DRIVER the two read-only senders above use,
# rather than left to a black-box case that cannot fail.
#
# The driver's two trailing arguments become the case's own $1/$2, which are
# download_attachment_content's ATTACHMENT_ID and DEST_PATH — so the id and the
# destination path travel as ARGUMENTS and are never interpolated into the case
# text (the driver's own note gives the reason).
# ===========================================================================

# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_DOWNLOAD_CASE='download_attachment_content "$1" "$2"
printf "installed:%s\n" "$2"'

# sink_download_run OVERRIDE_TEXT ID DEST [VAR=VALUE...] — drive
# download_attachment_content once, with OVERRIDE_TEXT (a function definition, or
# the empty string) prepended to the case so it shadows a collaborator the sink
# calls. Prepended rather than pasted into one near-identical case string per
# caller, because the two body lines are the part that must NOT drift between
# them: a per-case copy is how one ends up not printing the marker that
# distinguishes "refused" from "installed".
sink_download_run() {
	sdr_override=$1; shift
	sink_case_run "$sdr_override$SINK_DOWNLOAD_CASE" "$@"
}

SINK_DOWNLOAD_ID=303980

section "jira.sh — download sink: \$JIRA_READ_ONLY is re-checked at the LOCAL WRITE, before the workdir or the resolve"

# The sink-side counterpart of jira.sh's one-shot require_write_allowed, and the
# one sender whose reasoning about this gate is neither of the other two shapes.
# Of the four curl senders, exactly TWO gate on "is the method a write" —
# jira_curl and jira_curl_multipart, the two that take a method as a PARAMETER.
# The third, fetch_attachment_content_redirect, is exempt outright rather than
# method-gated: its method is a literal GET and its whole effect is reading a
# redirect header, so there is no write for the gate to refuse. THIS function is
# the fourth, and it is exempt from neither: its dangerous effect is the LOCAL
# FILE WRITE — which is why readonlygate.sh classifies `attach --download` a
# write at all, and a GET method says nothing about it. http.sh's own note
# records that the classification has already been reverted once.
#
# The full two-call success flow is queued as a COUNTERFACTUAL the run must never
# consume: with this check deleted the sink resolves, fetches and installs, so the
# regression reports TWO calls, an "installed:" marker and a real file, instead of
# the stub's no-canned-response artifact.
SINK_DOWNLOAD_RO_DEST="$WORK/sink-download-read-only.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
sink_download_run "" "$SINK_DOWNLOAD_ID" "$SINK_DOWNLOAD_RO_DEST" "JIRA_READ_ONLY=1"
expect_rc "sink: download_attachment_content under read-only -> exit 1 (fail closed)" 1
stderr_has "sink: the download refusal names the LOCAL FILE WRITE, not a method" \
	"internal: \$JIRA_READ_ONLY is set: refusing the local file write for attachment $SINK_DOWNLOAD_ID (fail closed)"
equals "sink: the refused download made ZERO curl calls (the check precedes the resolve)" "$(call_count)" "0"
stdout_not_has "sink: the refused download never reported an install" "installed:"
assert_path_absent "sink: the refused download created no destination file" "$SINK_DOWNLOAD_RO_DEST"
assert_no_dest_siblings "sink: the refused download left nothing beside the destination" \
	"$SINK_DOWNLOAD_RO_DEST"

# POSITIVE CONTROL. Without it, a sink hardened to refuse unconditionally — or one
# whose read-only test was inverted — would satisfy every assertion above.
SINK_DOWNLOAD_OK_DEST="$WORK/sink-download-permitted.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
sink_download_run "" "$SINK_DOWNLOAD_ID" "$SINK_DOWNLOAD_OK_DEST"
expect_rc "sink: download_attachment_content with read-only OFF -> exit 0" 0
stdout_has "sink: read-only OFF — the sink reported the install" "installed:$SINK_DOWNLOAD_OK_DEST"
equals "sink: read-only OFF — TWO calls (resolve + media fetch)" "$(call_count)" "2"
assert_file_bytes_identical "sink: read-only OFF — the bytes landed at the destination" \
	"$SINK_DOWNLOAD_OK_DEST" "$ATTACH_DL_PAYLOAD_GOLDEN"

section "jira.sh — assert_safe_tmpdir: which \$TMPDIR the engine will stage in, and which it refuses"

# WHY THIS GUARD EXISTS AT ALL, because it reads like belt-and-braces and is not.
# $WORKDIR is a 0700 `mktemp -d`, and a 0700 directory protects everything created
# INSIDE it — but never its own directory ENTRY, which is the PARENT's permissions
# to decide. In a group- or other-writable $TMPDIR with no sticky bit, another
# local user can rename $WORKDIR away and leave their own directory (or a symlink)
# at the identical name, which is then where this engine writes AND READS BACK
# every API response body and every staged download. That is the same
# parent-governed race http.sh's staging relocation closed one level down, and it
# is a property all 45 units depend on.
#
# AND IT CLOSES A LOOP THE ENGINE OPENED ITSELF: the cross-device refusal two
# sections below tells the caller to point $TMPDIR somewhere else, so without this
# guard the engine's own remedy could walk a caller straight into recreating the
# staging race it had just been protected from.
#
# THE STICKY BIT IS THE OTHER HALF, not an afterthought — it is exactly what makes
# a world-writable /tmp safe, so the DEFAULT ${TMPDIR:-/tmp} has to pass on every
# real system while a $TMPDIR repointed at a shared directory does not. Both
# directions are therefore asserted: a guard that refused world-writable-with-
# sticky would break `attach --download` on every machine that has not set $TMPDIR.

# shellcheck disable=SC2016  # single-quoted on purpose: $1 is the CASE FILE's positional parameter (see the driver's note), not this harness's
SINK_TMPDIR_CASE='assert_safe_tmpdir "$1"
printf "safe\n"'

# sink_tmpdir_probe DIR — drive assert_safe_tmpdir once against DIR. Under
# `nocurl`, like the other pure-helper probes in this block: the function makes no
# request.
#
# THE TRAILING `printf` IS THE DISCRIMINATOR, and it is why this is not shaped like
# the verdict probes above. assert_safe_tmpdir is an ASSERT, not a predicate — it
# either returns or `exit`s 1 — so "accepted" and "refused" differ in the driver's
# EXIT STATUS. A marker printed after the call separates "it returned" from "it
# exited", which an exit-status assertion alone cannot do: the driver runs under
# `set -eu` and any other failure would also surface as a non-zero exit.
sink_tmpdir_probe() {
	printf '%s\n' "$SINK_TMPDIR_CASE" >"$WORK/sink-case.sh"
	run nocurl sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh" "$1"
}

# assert_tmpdir_accepted DIR WHY / assert_tmpdir_refused DIR WHY NEEDLE — the two
# outcomes, one helper each rather than one helper branching on an expected
# verdict: they assert genuinely different things (a return vs. an exit, and a
# diagnostic that exists only on one side), so a single parameterised helper would
# have to grow an `if` around which assertions run — the one shape that makes it
# impossible to tell from a green run what was actually verified.
assert_tmpdir_accepted() {
	sink_tmpdir_probe "$1"
	expect_rc "sink: assert_safe_tmpdir accepts $2" 0
	stdout_has "sink: assert_safe_tmpdir accepts $2 — it RETURNED rather than exiting" "safe"
}

assert_tmpdir_refused() {
	sink_tmpdir_probe "$1"
	expect_rc "sink: assert_safe_tmpdir refuses $2 -> exit 1 (fail closed)" 1
	stdout_not_has "sink: assert_safe_tmpdir refuses $2 — it EXITED rather than returning" "safe"
	stderr_has "sink: assert_safe_tmpdir refuses $2 — the diagnostic names the reason" "$3"
}

SINK_TMPDIR_UNREADABLE_DIAG="could not read the permissions of the temp directory"
SINK_TMPDIR_SHARED_DIAG="is writable by other local users and has no sticky bit"

# THE MODE FIXTURES, one directory per mode string the guard's three `case`
# patterns discriminate on. Built here rather than reused from elsewhere in the
# suite because the mode IS the fixture: `ls -ld` position 6 (group write),
# position 9 (other write) and position 10 (sticky) are three independent bits,
# and a mode that happens to be safe for two of them proves nothing about the
# third.
SINK_TMPDIR_FIXTURES="$WORK/tmpdir-modes"
mkdir -p "$SINK_TMPDIR_FIXTURES"
for sink_tmpdir_mode in 0700 0750 0770 0707 0777 1777 1776; do
	mkdir -p "$SINK_TMPDIR_FIXTURES/d$sink_tmpdir_mode"
	chmod "$sink_tmpdir_mode" "$SINK_TMPDIR_FIXTURES/d$sink_tmpdir_mode"
done
: >"$SINK_TMPDIR_FIXTURES/plainfile"
ln -s "$SINK_TMPDIR_FIXTURES/d0700" "$SINK_TMPDIR_FIXTURES/symlink-to-private"

# THE ACCEPTED SIDE. Without it a guard hardened to refuse everything would
# satisfy every refusal below while breaking every command in the engine — which
# is not hypothetical: an absent `ls` does exactly that, and did, before this
# suite's toolbox carried one.
# THE PRIVATE-DIRECTORY ARM IS SPELLED AS THIS HARNESS'S OWN $TMPDIR, not as a
# d0700 mode fixture, because the two are the same mode and the same equivalence
# class — one probe, not two. This spelling is the more honest of the pair: $WORK
# is what `mktemp -d` really produces and what every other test in this file
# passes under, so it states a dependency the suite actually has rather than a
# mode someone chose. (Inverting the writability test to refuse it does not
# produce a red line here at all — it collapses the whole suite, which is the
# strongest form the claim has.) The d0700 fixture still exists below, as the
# symlink arm's target.
assert_tmpdir_accepted "$WORK" \
	"a PRIVATE 0700 directory — specifically this harness's own \$TMPDIR, the verdict every other test in this file silently depends on"
assert_tmpdir_accepted "$SINK_TMPDIR_FIXTURES/d0750" \
	"a 0750 directory (group-READABLE is not group-writable)"
assert_tmpdir_accepted "$SINK_TMPDIR_FIXTURES/d1777" \
	"a world-writable directory WITH the sticky bit — the shape /tmp itself has"
# THE CAPITAL-`T` HALF of the sticky pattern, and the mode is chosen so this arm
# actually discriminates: the sticky bit prints as `T` instead of `t` when
# other-EXECUTE is off, so it needs a directory that is writable (or the
# writability check would let it through by fall-through and this arm would pass
# with the sticky pattern deleted — a 1700 fixture was tried first and did exactly
# that). 1776 is writable by group AND other, with no other-execute, so the
# `[tT]` pattern is the ONLY thing that can accept it.
assert_tmpdir_accepted "$SINK_TMPDIR_FIXTURES/d1776" \
	"a group+world-writable sticky directory with no other-execute (mode string 'T', not 't')"
# THE `/.` SUFFIX IS LOAD-BEARING, and only this arm can say so. `ls -ld` on a
# SYMLINK reports the LINK's own 0777 mode (`lrwxrwxrwx`), which matches neither
# the directory pattern nor the sticky one — so a guard that dropped the `/.`
# would fail CLOSED on any symlinked $TMPDIR, and /tmp is a symlink to
# /private/tmp on macOS. Every refusal arm below still refuses without the `/.`,
# just for the wrong reason; this is the arm that goes red.
assert_tmpdir_accepted "$SINK_TMPDIR_FIXTURES/symlink-to-private" \
	"a SYMLINK to a private directory (the \`ls -ld DIR/.\` form resolves it — /tmp is one on macOS)"

# THE REFUSED SIDE — the two writability bits separately, because they are two
# distinct `case` patterns and a single 0777 fixture would leave either one
# deletable with the suite still green.
assert_tmpdir_refused "$SINK_TMPDIR_FIXTURES/d0770" \
	"a GROUP-writable directory with no sticky bit" "$SINK_TMPDIR_SHARED_DIAG"
assert_tmpdir_refused "$SINK_TMPDIR_FIXTURES/d0707" \
	"an OTHER-writable directory with no sticky bit" "$SINK_TMPDIR_SHARED_DIAG"
assert_tmpdir_refused "$SINK_TMPDIR_FIXTURES/d0777" \
	"a world-writable directory with no sticky bit" "$SINK_TMPDIR_SHARED_DIAG"

# THE FAIL-CLOSED SIDE, where the mode string cannot be read as a directory's at
# all. A separate diagnostic from the two above, so these arms also pin WHICH of
# the guard's two refusals fired.
assert_tmpdir_refused "$WORK/no-such-tmpdir-at-all" \
	"a \$TMPDIR that does not exist" "$SINK_TMPDIR_UNREADABLE_DIAG"
assert_tmpdir_refused "$SINK_TMPDIR_FIXTURES/plainfile" \
	"a \$TMPDIR that is a FILE, not a directory" "$SINK_TMPDIR_UNREADABLE_DIAG"

section "jira.sh — assert_safe_tmpdir: it gates BOTH \$TMPDIR creation sites, not one shared one"

# TWO CALL SITES, TWO CASES, and neither can stand in for the other. The engine
# creates something directly in ${TMPDIR:-/tmp} in exactly two places —
# credentials.sh's `mktemp` for the curl `-K` config, and runtime.sh's
# ensure_workdir `mktemp -d` — and each calls assert_safe_tmpdir itself rather
# than inheriting one check, so that a future third site cannot be silently
# missed. Deleting EITHER call must therefore turn a case below red.
#
# THE HARD PART IS ATTRIBUTION, because both sites emit the SAME diagnostic and
# credentials.sh's runs FIRST on every CLI invocation that falls back to
# $JIRA_EMAIL/$JIRA_TOKEN. So the exit code and the message cannot say which one
# fired, and a case asserting only those stays green with either check deleted.
#
# WHAT DOES NOT WORK, recorded because it is the obvious idea and it was tried:
# scanning the unsafe directory afterwards for the artifact the OTHER check would
# have let through (a `jira.curlconfig.*` or a `jira.work.*`). Both are removed by
# runtime.sh's own EXIT trap — cleanup() takes $WORKDIR and, when the engine built
# it, the curl config too — so the directory is empty either way and such an
# assertion passes with the call deleted. Verified by deleting it.
#
# WHAT DOES WORK is reaching each site with the other one OFF the path, which
# takes a different technique per site — hence two differently-shaped cases below
# rather than one parameterised pair.

# (a) credentials.sh's SITE, driven DIRECTLY through the sink driver. That driver
# sources the lib units and nothing else, so resolve_credential_config can be
# called with no dispatch around it and ensure_workdir is never reached at all —
# which makes credentials.sh's call the ONLY assert_safe_tmpdir on the path, and
# a refusal here attributable to it alone. The CLI-level half of this site is the
# case that follows.
#
# THE MARKER IS THE DISCRIMINATOR, same shape and same reason as the probes in
# the section above: it prints only if resolve_credential_config RETURNED, so its
# absence separates "the guard exited" from "the function failed some other way",
# which the exit status alone cannot.
# shellcheck disable=SC2016  # single-quoted on purpose: $CURL_CONFIG_IS_OWN is the DRIVER's variable, expanded when it sources the case, not this harness's
SINK_CREDCONFIG_CASE='resolve_credential_config
printf "credconfig-built:%s\n" "$CURL_CONFIG_IS_OWN"'

SINK_TMPDIR_CRED_UNSAFE="$WORK/tmpdir-unsafe-cred"
mkdir -p "$SINK_TMPDIR_CRED_UNSAFE"
chmod 0777 "$SINK_TMPDIR_CRED_UNSAFE"

printf '%s\n' "$SINK_CREDCONFIG_CASE" >"$WORK/sink-case.sh"
run nocurl "TMPDIR=$SINK_TMPDIR_CRED_UNSAFE" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh"
expect_rc "credential site: resolve_credential_config under a world-writable \$TMPDIR -> exit 1 (fail closed)" 1
stderr_has "credential site: the diagnostic names the unsafe directory and the remedy" \
	"the temp directory '$SINK_TMPDIR_CRED_UNSAFE' $SINK_TMPDIR_SHARED_DIAG"
stdout_not_has "credential site: NO credential config was built — the guard refused before the mktemp, and ensure_workdir was never on this path" \
	"credconfig-built:"

# THE POSITIVE CONTROL for case (a). Without it, a resolve_credential_config that
# refused for any reason at all — a missing $JIRA_EMAIL, a driver that never
# sourced credentials.sh — would satisfy every assertion above.
printf '%s\n' "$SINK_CREDCONFIG_CASE" >"$WORK/sink-case.sh"
run nocurl "TMPDIR=$WORK" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh"
expect_rc "credential site control: the same call under a SAFE \$TMPDIR -> exit 0" 0
stdout_has "credential site control: the config really was built, on the OWN-config branch the guard sits in" \
	"credconfig-built:1"

# (a2) THE SAME SITE FROM THE CLI, which the direct probe above deliberately does
# not cover: it proves the refusal reaches a real invocation and that nothing is
# spent on the wire. It cannot ATTRIBUTE the refusal — either call would produce
# this exact output, which is why (a) exists — so it claims only what it can see.
reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "TMPDIR=$SINK_TMPDIR_CRED_UNSAFE" "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "CLI: a world-writable \$TMPDIR refuses an ordinary invocation -> exit 1 (fail closed)" 1
stderr_has "CLI: the diagnostic names the unsafe directory and the remedy" \
	"the temp directory '$SINK_TMPDIR_CRED_UNSAFE' $SINK_TMPDIR_SHARED_DIAG"
equals "CLI: ZERO curl calls — the refusal precedes every request" "$(call_count)" "0"
stdout_not_has "CLI: nothing was rendered (the run stopped at startup, not after a fetch)" "PROJ-1"

# (b) ensure_workdir's SITE, reached from the CLI by BYPASSING credentials.sh's.
# A supplied $JIRA_CURL_CONFIG takes resolve_credential_config's early `return 0`
# branch before its `mktemp` and its guard, leaving ensure_workdir's the first and
# only one on the path — so this case really does attribute, and the zero-call
# count is the half that does it: delete ensure_workdir's call and the run
# proceeds to the transport and exits 0. The config file must be named
# `<confirmed-host>.cfg` to clear resolve_credential_config's site binding, and
# lives OUTSIDE the unsafe directory.
SINK_TMPDIR_WORK_UNSAFE="$WORK/tmpdir-unsafe-workdir"
mkdir -p "$SINK_TMPDIR_WORK_UNSAFE"
chmod 0777 "$SINK_TMPDIR_WORK_UNSAFE"
SINK_TMPDIR_BOUND_CFG="$WORK/foo.atlassian.net.cfg"
printf 'user = "a@b.com:t"\n' >"$SINK_TMPDIR_BOUND_CFG"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "TMPDIR=$SINK_TMPDIR_WORK_UNSAFE" "JIRA_CURL_CONFIG=$SINK_TMPDIR_BOUND_CFG" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workdir site: a world-writable \$TMPDIR refuses the run -> exit 1 (fail closed)" 1
stderr_has "workdir site: the diagnostic names the unsafe directory and the remedy" \
	"the temp directory '$SINK_TMPDIR_WORK_UNSAFE' $SINK_TMPDIR_SHARED_DIAG"
equals "workdir site: ZERO curl calls — with credentials.sh's guard bypassed, only ensure_workdir's own call can have refused" \
	"$(call_count)" "0"
# THE POSITIVE CONTROL for case (b) specifically, since the supplied-config path
# is the unusual half of it: the SAME invocation against a SAFE $TMPDIR must
# succeed. Without this, a run that refused for some unrelated reason — a
# mis-named config, a broken site binding — would satisfy every assertion above.
SINK_TMPDIR_WORK_SAFE="$WORK/tmpdir-safe-workdir"
mkdir -p "$SINK_TMPDIR_WORK_SAFE"
chmod 1777 "$SINK_TMPDIR_WORK_SAFE"

reset_curl_stub
set_stub_response 1 '{"key":"PROJ-1","fields":{"summary":"s","status":{"name":"Open"},"issuetype":{"name":"Task"}}}' 200
run full "TMPDIR=$SINK_TMPDIR_WORK_SAFE" "JIRA_CURL_CONFIG=$SINK_TMPDIR_BOUND_CFG" \
	sh "$JIRA" view PROJ-1 --confirmed-site foo.atlassian.net
expect_rc "workdir site control: the SAME invocation under a sticky world-writable \$TMPDIR succeeds -> exit 0" 0
stdout_has "workdir site control: the issue really was fetched and rendered" "PROJ-1"
equals "workdir site control: ONE curl call (the run reached the transport)" "$(call_count)" "1"
stderr_not_has "workdir site control: no temp-directory refusal fired" "$SINK_TMPDIR_SHARED_DIAG"

# A REAL SECOND FILESYSTEM, discovered once and consumed twice — by the predicate
# section immediately below and by the end-to-end refusal section after it. No
# image is created and nothing is ever written there: both consumers stop before
# the install (the predicate never installs at all, and the refusal happens before
# the first request, which is precisely its claim), so an unwritable system mount
# is a perfectly good fixture.
#
# The candidate is CHOSEN by this harness's own crude device-column compare, not by
# runtime.sh's parser — a fixture selector, deliberately not a second
# implementation of the verdict under test. If it and the engine ever disagree,
# the cases below fail loudly, which is the right outcome.
sink_xdev_candidate_differs() {
	sxcd_rows=$(df -P "$WORK" "$1" 2>/dev/null | sed -n '2,3p')
	sxcd_a=$(printf '%s\n' "$sxcd_rows" | sed -n '1s/[[:space:]].*//p')
	sxcd_b=$(printf '%s\n' "$sxcd_rows" | sed -n '2s/[[:space:]].*//p')
	[ -n "$sxcd_a" ] && [ -n "$sxcd_b" ] && [ "$sxcd_a" != "$sxcd_b" ]
}

SINK_DOWNLOAD_XDEV_DIR=""
for sink_xdev_candidate in /dev /proc /run; do
	[ -d "$sink_xdev_candidate" ] || continue
	if sink_xdev_candidate_differs "$sink_xdev_candidate"; then
		SINK_DOWNLOAD_XDEV_DIR=$sink_xdev_candidate
		break
	fi
done

section "jira.sh — is_known_cross_device: a CONFIDENT cross-device verdict, and every unestablished answer PROCEEDING"

# WHY THE PREDICATE IS DRIVEN ON ITS OWN, ahead of the refusal it feeds — AND WHY
# ITS DIRECTION IS NOW THE OPPOSITE OF WHAT IT ONCE WAS. This function used to be
# `same_filesystem`, a genuine SAFETY boundary that had to fail CLOSED: the
# install was `mv -f`, and a cross-device `mv` is not a rename but a by-name COPY
# into the caller's own directory, so an answer that was never actually
# established had to be read as "different" or the staging race came straight
# back, non-atomically, for the length of the whole payload. The install is now
# `ln`, and link(2) CANNOT cross a filesystem at all — the kernel refuses with
# EXDEV at the instant of the install, with no window between deciding and acting
# — so the safety boundary moved into `ln` itself and this predicate was inverted
# into a pure COURTESY: all it buys is sparing an already-doomed destination the
# short-lived media JWT and a fetched payload.
#
# THAT IS WHY EVERY ARM BELOW WHERE `df` GIVES NO USABLE ANSWER READS "proceed",
# not "cross". Carrying forward the old fail-closed expectation would now assert a
# hazard that no longer exists, at the cost of a capability that does: a wrong
# "cross" refuses a download `ln` would have installed perfectly well, and a
# machine whose `df` this parser cannot read would lose `attach --download`
# outright.
#
# Only a CONFIDENT verdict may refuse, so the arms that matter are the two kinds
# of confidence — two devices that really are different, and two that really are
# the same — plus every shape of NON-confidence. None of the non-confident arms is
# reachable from the CLI: every destination this suite can name really is on
# $WORKDIR's filesystem.
#
# It is exercised through the same HTTP_SINK_DRIVER as the sinks around it, under
# `nocurl` — the predicate makes no request, and a toolbox with no curl at all is
# the strongest statement of that.
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_XDEV_CASE='if is_known_cross_device "$1" "$2"; then printf "cross\n"; else printf "proceed\n"; fi'

# assert_known_cross_device_verdict DIR_A DIR_B EXPECTED WHY [OVERRIDE] — one
# is_known_cross_device probe, printing its verdict rather than exiting with it
# for the same reason the is_read_only_search_post probes above do: a driver that
# died before reaching the predicate leaves empty stdout, which must not read as
# either answer. OVERRIDE is a function definition prepended to the case (the
# shape sink_download_run uses) for the arms whose `df` output has to be canned.
assert_known_cross_device_verdict() {
	printf '%s\n' "${5:-}$SINK_XDEV_CASE" >"$WORK/sink-case.sh"
	run nocurl sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh" "$1" "$2"
	equals "sink: is_known_cross_device $4 -> $3" "$CUR_OUT" "$3"
}

SINK_XDEV_SUBDIR="$WORK/xdev-subdir"
mkdir -p "$SINK_XDEV_SUBDIR"

# THE CONFIDENT "SAME" ARMS, on the real `df` of whatever machine runs this.
# Without them a predicate hardened to answer "cross" for everything — or one
# whose comparison never matches — would satisfy every refusal below, and `attach
# --download` would be broken outright on every machine.
assert_known_cross_device_verdict "$WORK" "$WORK" proceed "on one directory twice"
assert_known_cross_device_verdict "$WORK" "$SINK_XDEV_SUBDIR" proceed \
	"on two DIFFERENT directories of one filesystem (the ordinary case: \$WORKDIR and a destination under \$TMPDIR)"

# THE CONFIDENT "CROSS" ARM on real `df`, when this machine has a second
# filesystem mounted. The three canned-`df` arms below prove the PARSE; this one
# proves the parse is aimed at output a real `df` on a real machine actually
# emits. Skipped with a note where there is no second filesystem, exactly like
# the end-to-end case that shares this fixture.
if [ -n "$SINK_DOWNLOAD_XDEV_DIR" ]; then
	assert_known_cross_device_verdict "$WORK" "$SINK_DOWNLOAD_XDEV_DIR" cross \
		"on a genuinely different filesystem ($SINK_DOWNLOAD_XDEV_DIR), read from this machine's REAL df"
else
	printf '  note no second filesystem is mounted on this machine — the real-df CROSS verdict was skipped (the canned-df arms below still cover the comparison)\n'
fi

# THE THREE FIELD-PARSING ARMS, each driving a `df` shadow rather than the real
# tool, because none of the three can be produced on demand from a real machine:
# they need a device or mount-point field containing a SPACE, and whether such a
# filesystem is mounted is a property of whoever runs the suite, not of the code
# under test. Overridden rather than given a fifth PATH toolbox for the same
# reason the absent-`df` arm below is: the override reaches the same branch with
# nothing else changed.
#
# `%%` in each canned row is a printf-escaped `%` — these strings are written to
# the case file verbatim and only expanded when the driver sources it.

# (1) TWO DEVICES THAT SHARE THEIR FIRST TOKEN. This is the regression arm for a
# real bug the previous round shipped: the parse grabbed only the FIRST
# whitespace-token of the device field, so `map auto_home` and `map -hosts` — two
# genuinely different filesystems — both read as `map` and compared EQUAL. Nothing
# in the suite noticed, because a wrong "same" was invisible from the CLI. The
# whole device field is captured now, and only this shape can tell the difference.
SINK_XDEV_DF_SHARED_FIRST_TOKEN='df() {
	printf "Filesystem 512-blocks Used Available Capacity Mounted on\n"
	printf "map auto_home 0 0 0 100%% /System/Volumes/Data/home\n"
	printf "map -hosts 0 0 0 100%% /net\n"
}
'
assert_known_cross_device_verdict "$WORK" "$SINK_XDEV_SUBDIR" cross \
	"on two devices sharing their FIRST token but differing in full ('map auto_home' vs 'map -hosts')" \
	"$SINK_XDEV_DF_SHARED_FIRST_TOKEN"

# (2) A MOUNT POINT CONTAINING A SPACE, on two different devices. The mount point
# is not compared, but the pattern SPANS it to anchor the field split, so a parse
# that cannot absorb a spacey mount point captures no device at all — which would
# surface here as "proceed" (no confident verdict) on a pair that genuinely is
# cross-device.
SINK_XDEV_DF_SPACEY_MOUNT='df() {
	printf "Filesystem 512-blocks Used Available Capacity Mounted on\n"
	printf "/dev/disk3s5 100 50 50 50%% /Volumes/VS Code\n"
	printf "map auto_home 0 0 0 100%% /System/Volumes/Data/home\n"
}
'
assert_known_cross_device_verdict "$WORK" "$SINK_XDEV_SUBDIR" cross \
	"on two different devices whose MOUNT POINT carries a space ('/Volumes/VS Code')" \
	"$SINK_XDEV_DF_SPACEY_MOUNT"

# (3) A BIND-MOUNT SHAPE — one device, two mount points, both spacey. ONLY THE
# DEVICE DECIDES: `ln` works fine between two mount points of one filesystem, so
# flagging this as cross-device would refuse a legitimate download. It is also the
# other half of the previous round's parsing bug, which compared the mount-point
# field's LAST token as well — `Code` vs `Disk` — and would call this pair
# cross-device.
SINK_XDEV_DF_BIND_MOUNT='df() {
	printf "Filesystem 512-blocks Used Available Capacity Mounted on\n"
	printf "map auto_home 100 50 50 50%% /Volumes/VS Code\n"
	printf "map auto_home 100 50 50 50%% /Volumes/Other Disk\n"
}
'
assert_known_cross_device_verdict "$WORK" "$SINK_XDEV_SUBDIR" proceed \
	"on ONE device mounted at two different (spacey) mount points — a bind mount, where \`ln\` works" \
	"$SINK_XDEV_DF_BIND_MOUNT"

# THE NON-CONFIDENT ARMS, one per way `df` can leave the question unanswered.
# EVERY ONE OF THEM NOW READS "proceed" — this is the inverted half of this
# section, and the four assertions that a naive carry-forward of the previous
# round's `same_filesystem` expectations would have left asserting the old
# fail-closed direction.
assert_known_cross_device_verdict "$WORK" "$WORK/no-such-directory-here" proceed \
	"when one operand does not exist (df errors, so only one row parses — no verdict, so proceed)"
assert_known_cross_device_verdict "$WORK" "" proceed \
	"on an EMPTY operand (the shape a failed parent_dir derivation would hand it)"

# UNPARSEABLE OUTPUT — a `df` that runs and succeeds but emits nothing this
# parser recognizes, which is the shape a future platform's `df -P` could take.
# Distinct from the absent-`df` arm below: this one exercises the PARSE failing
# where that one exercises the TOOL failing, and only a `return 0`-style
# regression in the field extraction shows up here.
SINK_XDEV_DF_GARBAGE='df() {
	printf "this is not a df table\n"
	printf "neither is this\n"
	printf "nor this\n"
}
'
assert_known_cross_device_verdict "$WORK" "$SINK_XDEV_SUBDIR" proceed \
	"on output it cannot parse at all (no confident verdict, so proceed)" \
	"$SINK_XDEV_DF_GARBAGE"

# `df` ITSELF UNAVAILABLE — the arm runtime.sh names first. Under the OLD
# fail-closed contract this was the arm that mattered most, because a
# `return 0`-on-failure regression turned it into a silent cross-device install;
# under the new one it is the arm that proves the feature SURVIVES a toolbox
# without `df`, since the kernel's EXDEV is what actually guards the install.
# Overridden rather than removed from the toolbox: a fifth PATH toolbox would have
# to be built and threaded through run()'s selector map for one assertion, and the
# override reaches the same branch with nothing else changed.
SINK_XDEV_NODF_OVERRIDE='df() { printf "df: not found\n" >&2; return 127; }
'
assert_known_cross_device_verdict "$WORK" "$SINK_XDEV_SUBDIR" proceed \
	"when df cannot run at all (no verdict, so proceed — the install's own \`ln\` is the real boundary)" \
	"$SINK_XDEV_NODF_OVERRIDE"
# df's own stderr is deliberately NOT suppressed (runtime.sh's note): the
# function reports only a verdict, so a swallowed `df: not found` would leave the
# caller with no trace at all of why there was no verdict.
stderr_has "sink: is_known_cross_device lets df's OWN diagnostic through (a suppressed one would leave the missing verdict unexplainable)" \
	"df: not found"

section "jira.sh — download sink: a destination on ANOTHER FILESYSTEM is refused BEFORE any request"

# WHAT THE COURTESY REFUSAL BUYS, now that it is no longer the safety boundary.
# The install's `ln` refuses a cross-device destination on its own — link(2)
# cannot span a filesystem — so this check exists purely to reach that verdict
# BEFORE the network: without it the caller spends the short-lived media JWT and
# downloads the whole payload only to have the install refuse it anyway. THE
# ZERO-CALL ASSERTION IS THEREFORE THE WHOLE CLAIM of this section, not a
# side-observation: remove the check and the refusal still happens, with the same
# exit status, two calls later and with a different diagnostic.
SINK_DOWNLOAD_XDEV_DIAG="the destination directory is on a different filesystem than the engine's temp directory"
SINK_DOWNLOAD_XDEV_MECHANISM="the download is installed with a hard link, which cannot cross one"
# shellcheck disable=SC2016  # single-quoted on purpose: the needle is the diagnostic's own literal text, which spells the variable NAME as the caller's remedy — expanding it here would search for this harness's own $TMPDIR value
SINK_DOWNLOAD_XDEV_REMEDY='point $TMPDIR at a PRIVATE directory you own'

# assert_download_xdev_refused NAME DEST [OVERRIDE] — the refusal, driven end to
# end with the full two-call success flow queued as a COUNTERFACTUAL: with the
# check removed the sink resolves and fetches, so a regression reports TWO calls
# rather than the stub's own no-canned-response artifact. Shared by the two cases
# below because the assertion SET is what must not drift between them — only how
# the cross-device condition is produced differs.
assert_download_xdev_refused() {
	adxr_name=$1
	adxr_dest=$2
	reset_curl_stub
	queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
	sink_download_run "${3:-}" "$SINK_DOWNLOAD_ID" "$adxr_dest"
	expect_rc "$adxr_name -> exit 1" 1
	stderr_has "$adxr_name: the diagnostic names the cross-device condition" \
		"$SINK_DOWNLOAD_XDEV_DIAG"
	stderr_has "$adxr_name: the diagnostic names the HARD LINK as what cannot cross a filesystem" \
		"$SINK_DOWNLOAD_XDEV_MECHANISM"
	# The remedy must name a SAFE $TMPDIR, not merely another filesystem: steering
	# a caller at a shared directory is exactly the finding assert_safe_tmpdir was
	# added to close, so this needle is the one that would catch the remedy being
	# reworded back to the unqualified advice.
	stderr_has "$adxr_name: the remedy names \$TMPDIR and requires it be PRIVATE" \
		"$SINK_DOWNLOAD_XDEV_REMEDY"
	equals "$adxr_name: ZERO curl calls — the media JWT was never spent on a download the install would refuse anyway" \
		"$(call_count)" "0"
	stdout_not_has "$adxr_name: nothing was reported as installed" "installed:"
	assert_path_absent "$adxr_name: no destination file was created" "$adxr_dest"
	assert_no_dest_siblings "$adxr_name: nothing was left beside the destination" "$adxr_dest"
}

# (a) A REAL SECOND FILESYSTEM, on the fixture discovered above the predicate
# section. The sink driver is what makes it reachable (cmd-attach.sh's pre-flight
# would refuse an unwritable destination directory first, with a different
# diagnostic).
if [ -n "$SINK_DOWNLOAD_XDEV_DIR" ]; then
	assert_download_xdev_refused \
		"sink: a destination on a genuinely different filesystem ($SINK_DOWNLOAD_XDEV_DIR)" \
		"$SINK_DOWNLOAD_XDEV_DIR/jira-attach-download-xdev-probe.bin"
else
	printf '  note no second filesystem is mounted on this machine — the REAL cross-device case was skipped (case (b) below still covers the refusal)\n'
fi

# (b) THE SAME REFUSAL, PRODUCED DETERMINISTICALLY, so this claim has coverage on
# a machine with exactly one filesystem mounted — where case (a) silently skips
# and cannot be relied on. The predicate is overridden to report what a real
# cross-device destination reports; its own verdict is pinned by the section
# above, so what remains here is the CONSUMER's half: refuse, say why, and spend
# nothing. Same override shape, and the same narrowest-possible-swap reasoning, as
# the resolver override the media-host sink case uses.
#
# `return 0` IS THE CROSS-DEVICE ANSWER HERE, and the direction is worth reading
# twice: is_known_cross_device answers the question "is this KNOWN to be
# cross-device?", so success means "yes, refuse" — the exact inverse of the
# `return 1` the old `same_filesystem` override used to mean the same thing.
SINK_DOWNLOAD_XDEV_OVERRIDE='is_known_cross_device() { return 0; }
'
assert_download_xdev_refused \
	"sink: a cross-device verdict from is_known_cross_device" \
	"$WORK/sink-download-xdev.bin" \
	"$SINK_DOWNLOAD_XDEV_OVERRIDE"

# THE POSITIVE CONTROL for both cases above is the read-only section's own
# permitted run two sections up (and every happy path in the --download block):
# an ordinary destination under $TMPDIR is on $WORKDIR's filesystem, reaches the
# install, and exits 0 — so a check hardened to refuse everything does not pass
# this suite.

section "jira.sh — download sink: the media-host pin is re-asserted at the SINK, independently of the resolver's own"

# is_media_host is called TWICE on this path — once by resolve_media_download_url
# as it reads the Location, once here immediately before the URL is spent — and
# the defense is the two points of control flow, not the shared comparison. Every
# hostile-Location case in the --download block above is caught by the RESOLVER's
# call first, so the sink's own call has zero coverage there: deleting it leaves
# all of them green.
#
# The resolver is OVERRIDDEN to hand back a hostile URL — the only way to reach
# this check, and a swap of exactly the collaborator whose verdict the sink must
# not trust. The queued 200 is the COUNTERFACTUAL: with the sink's check removed
# the URL really is spent, so the regression shows a real request to the hostile
# host, an "installed:" marker and a real file at the destination — the actual
# exploit — rather than a stub artifact.
SINK_DOWNLOAD_HOSTILE_URL="https://$ATTACH_DL_UNTRUSTED_HOST/file/$ATTACH_DL_UUID/binary?token=$ATTACH_DL_JWT"
SINK_DOWNLOAD_HOSTILE_OVERRIDE="resolve_media_download_url() { printf '%s' '$SINK_DOWNLOAD_HOSTILE_URL'; }
"
SINK_DOWNLOAD_HOSTILE_DEST="$WORK/sink-download-hostile.bin"

reset_curl_stub
set_stub_response 1 "$ATTACH_DL_PAYLOAD" 200
sink_download_run "$SINK_DOWNLOAD_HOSTILE_OVERRIDE" "$SINK_DOWNLOAD_ID" "$SINK_DOWNLOAD_HOSTILE_DEST"
expect_rc "sink: a hostile URL from the resolver -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal names the media-host pin and the attachment id" \
	"internal: refusing the download request for attachment $SINK_DOWNLOAD_ID — its URL does not point at Atlassian's media host (fail closed)"
equals "sink: the hostile URL was NEVER requested (ZERO curl calls)" "$(call_count)" "0"
assert_path_absent "sink: no -K stdin config was written — the hostile URL was never even handed to curl" \
	"$(stdin_config_path 1)"
# The sink's diagnostic names the attachment id ALONE: a Location with no path
# would leave the JWT inside whatever an extraction calls "the host".
stderr_not_has "sink: the refusal does not echo the hostile host" "$ATTACH_DL_UNTRUSTED_HOST"
stderr_not_has "sink: the refusal does not echo the JWT" "$ATTACH_DL_JWT"
stdout_not_has "sink: the hostile URL never reported an install" "installed:"
assert_path_absent "sink: the hostile URL created no destination file" "$SINK_DOWNLOAD_HOSTILE_DEST"
assert_no_dest_siblings "sink: the hostile URL left nothing beside the destination" \
	"$SINK_DOWNLOAD_HOSTILE_DEST"

section "jira.sh — download sink: a FAILED install (ln) exits 1 and leaves no destination, not a reported success"

# THE CHECKED `ln -n`. What the guard buys is this engine's OWN uniform
# diagnostic and documented exit code in place of ln's raw message: swallow the
# failure instead (a bare `ln`, no error(), no exit) and the sink reports a
# successful download at a path holding nothing. That is the shape the three
# discriminating assertions below are aimed at — the exit code, the error()
# wording, and the ABSENCE of the install marker.
#
# A REAL FIXTURE, NOT AN `ln` OVERRIDE, and that became possible with the staging
# relocation: an UNWRITABLE destination directory makes the install link fail on
# its own, because nothing is staged in that directory any more — the payload
# comes from $WORKDIR, whose creation needs no permission there. (While the body
# staged beside the destination, that same permission was needed several lines
# earlier, so such a fixture died before the install under test was ever reached,
# and only a function override could get there.)
#
# WHY A GENERIC DIAGNOSTIC IS THE RIGHT ASSERTION. `ln` can fail here for a
# cross-device destination, a permission loss, a full filesystem, an entry
# appearing at the destination name, or an `ln` build with no `-n` — and neither
# its exit status nor its wording distinguishes those portably, so http.sh
# deliberately claims none of them. This case pins that one uniform line; the two
# sections below pin the two races that DO get their own distinct handling.
#
# THE SINK DRIVER IS WHAT MAKES IT REACHABLE. From the CLI this exact fixture is
# refused by cmd-attach.sh's own writability pre-flight with exit 2 — which the
# --download block above asserts as its own case — so the guard it concedes to
# (the destination directory losing write permission after the pre-flight passed)
# has no CLI-level path at all.
#
# GUARDED ON EUID, like every other permission fixture in this suite: uid 0 links
# into a 0555 directory regardless, so under root the install would succeed and
# this case would assert a failure that correctly never comes. The skip prints a
# NOTE rather than passing silently, for the same reason the real-cross-device
# case above does: a claim that quietly stopped being exercised is worse than one
# that never existed.
SINK_DOWNLOAD_LN_DIR="$WORK/sink-download-lnfail-dir"
SINK_DOWNLOAD_LN_DEST="$SINK_DOWNLOAD_LN_DIR/out.bin"
mkdir -p "$SINK_DOWNLOAD_LN_DIR"
if [ "$(id -u)" -ne 0 ]; then
	chmod 0555 "$SINK_DOWNLOAD_LN_DIR"
	# The fixture's own state IS half the claim (the unwritable-parent case above
	# asserts its chmod took for the same reason): a chmod that silently did not
	# take would leave the install succeeding and every assertion below red for a
	# reason that has nothing to do with the guard.
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ -d "$SINK_DOWNLOAD_LN_DIR" ] && [ ! -w "$SINK_DOWNLOAD_LN_DIR" ]; then
		pass "sink: failed-install fixture — the destination directory really exists and is really not writable"
	else
		fail "sink: failed-install fixture — the destination directory really exists and is really not writable" \
			"chmod did not take: $SINK_DOWNLOAD_LN_DIR"
	fi

	reset_curl_stub
	queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
	sink_download_run "" "$SINK_DOWNLOAD_ID" "$SINK_DOWNLOAD_LN_DEST"
	expect_rc "sink: a failed install -> exit 1 (never a silent success)" 1
	stderr_has "sink: the failed install reports through error(), naming the attachment id and the install step" \
		"download attachment $SINK_DOWNLOAD_ID: could not install the downloaded file at the destination"
	equals "sink: the failed install happened AFTER both requests (the payload really was fetched)" "$(call_count)" "2"
	stdout_not_has "sink: the failed install never reported success" "installed:"
	assert_path_absent "sink: the failed install left no destination file" "$SINK_DOWNLOAD_LN_DEST"
	assert_dir_entry_count "sink: the failed install left the destination directory EMPTY (no partial payload copied into it)" \
		"$SINK_DOWNLOAD_LN_DIR" 0
	chmod 0755 "$SINK_DOWNLOAD_LN_DIR"
else
	printf '  note running as uid 0, which links into a 0555 directory regardless — the failed-install case was skipped\n'
fi

section "jira.sh — download sink: a SYMLINK-TO-A-DIRECTORY raced in at the destination is REFUSED, never linked into (\`ln -n\`)"

# THE CORE SECURITY PROPERTY OF THE CURRENT INSTALL MECHANISM, and the reason the
# mechanism changed at all. An attacker who can write the caller's destination
# directory creates a directory of their own plus a SYMLINK to it at the
# destination name, in the window between cmd-attach.sh's pre-flight and the
# install. Both earlier mechanisms handed them the payload:
#   * `mv -f` STATS its destination, reads "symlink to a directory" as "move INTO
#     that directory", and exits 0;
#   * a bare `ln` — WITHOUT `-n` — does exactly the same thing, which the
#     production side confirmed by reconstructing this attack against it.
# `-n` (--no-dereference) makes `ln` operate on the LINK NAME instead, so link(2)
# finds an existing entry and refuses. That is a property of the syscall at the
# instant of the install, with no interval between deciding and acting.
#
# WHAT DISCRIMINATES A MISSING `-n` IS THE PAIR OF DIAGNOSTIC ASSERTIONS BELOW,
# and nothing else here — verified by deleting the `-n` and watching which
# assertions went red. This is counter-intuitive enough to be worth stating,
# because the obvious candidates all stay GREEN: the post-install directory check
# is reached with `-d` following the symlink, so it withdraws the misplaced link
# and refuses, which leaves the exit status 1, the install marker absent, and the
# attacker's directory empty — every outcome-shaped assertion satisfied by a
# mechanism that DID write the payload into the attacker's directory first.
#
# That window is real harm, not a technicality: for the length of it the attacker
# holds a hard link to the file and can link it away before the withdrawal. So the
# post-install check is a backstop for this race, never a substitute for `-n`, and
# the only thing that can tell the two apart is WHICH guard's diagnostic fired.
# The outcome assertions are kept anyway — they are what a future mechanism that
# refused for some unrelated reason while still leaking a copy would break, and
# they are blind to how the refusal is spelled.
#
# THE SINK DRIVER IS WHAT MAKES IT REACHABLE, and there is no CLI path at all:
# cmd-attach.sh's pre-flight refuses any destination that already exists —
# `-e` OR `-L`, so a symlink, including a dangling one — with exit 2 before any
# request. This case is the guard that pre-flight concedes to, for an entry that
# appears AFTER it passed.
SINK_DL_SYMDIR_ATTACKER="$WORK/sink-download-symdir-attacker"
SINK_DL_SYMDIR_DEST="$WORK/sink-download-symdir-dest"
mkdir -p "$SINK_DL_SYMDIR_ATTACKER"
ln -s "$SINK_DL_SYMDIR_ATTACKER" "$SINK_DL_SYMDIR_DEST"

# The fixture's own shape IS half the claim, on the same reasoning the unwritable
# -directory cases assert their chmod took: if the destination were not really a
# symlink to a really-empty directory, the entry count below would be measuring
# nothing.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_DL_SYMDIR_DEST" ] && [ -d "$SINK_DL_SYMDIR_DEST" ]; then
	pass "sink: symlink-to-directory fixture — the destination name really is a symlink, and it really resolves to a directory"
else
	fail "sink: symlink-to-directory fixture — the destination name really is a symlink, and it really resolves to a directory" \
		"not a symlink-to-directory: $SINK_DL_SYMDIR_DEST"
fi
assert_dir_entry_count "sink: symlink-to-directory fixture — the attacker's directory starts EMPTY" \
	"$SINK_DL_SYMDIR_ATTACKER" 0

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
sink_download_run "" "$SINK_DOWNLOAD_ID" "$SINK_DL_SYMDIR_DEST"
expect_rc "sink: a symlink-to-a-directory at the destination -> exit 1 (the install refuses it)" 1
stderr_has "sink: the refusal is the install's own uniform diagnostic" \
	"download attachment $SINK_DOWNLOAD_ID: could not install the downloaded file at the destination"
# The post-install directory check must NOT be what fired: `ln -n` refused before
# anything was created, so there is no misplaced link for it to clean up. Only
# this absence separates "the link was refused" from "the link succeeded into the
# directory and was then withdrawn".
stderr_not_has "sink: it was \`ln -n\` that refused, NOT the post-install directory check (that one never ran)" \
	"the destination became a directory while the file was being installed"
equals "sink: the refusal happened AFTER both requests, at the install (the payload really was fetched)" \
	"$(call_count)" "2"
stdout_not_has "sink: nothing was reported as installed" "installed:"
assert_dir_entry_count "sink: THE PAYLOAD IS NOT IN THE ATTACKER'S DIRECTORY — it is still empty (the whole point of \`-n\`)" \
	"$SINK_DL_SYMDIR_ATTACKER" 0
# The engine must also not have unlinked or replaced the entry it refused: a
# mechanism that "fixed" the destination by removing the symlink would pass every
# assertion above while destroying a path it was told not to touch.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_DL_SYMDIR_DEST" ]; then
	pass "sink: the symlink at the destination was left exactly as it was found (not unlinked, not replaced)"
else
	fail "sink: the symlink at the destination was left exactly as it was found (not unlinked, not replaced)" \
		"the symlink is gone: $SINK_DL_SYMDIR_DEST"
fi

section "jira.sh — download sink: a REAL DIRECTORY at the destination is caught AFTER the link, which is withdrawn from it"

# THE ONE RESIDUAL `-n` DOES NOT COVER, and the reason there is a post-install
# check at all. `-n` governs symlinks; against a REAL directory raced in at the
# destination name, `ln` links the payload INSIDE it and exits 0 — exactly as
# `mv -f` did — so the install genuinely succeeds and the only place left to catch
# it is immediately afterwards. http.sh's note is explicit that this is a
# VERIFICATION of what just happened rather than a re-check before acting, so it
# adds no TOCTOU gap of its own: it converts a false success into a refusal and
# takes the misplaced link back out.
#
# THREE THINGS SEPARATE THIS FROM THE SYMLINK CASE ABOVE, and all three are
# asserted: its OWN diagnostic (a distinct exit-1 path, not the generic install
# failure), the ABSENCE of the generic one (proving the `ln` really did succeed
# first), and the directory being EMPTY afterwards (proving the withdrawal
# happened, not merely that the run reported an error).
#
# THE EMPTY-DIRECTORY ASSERTION IS THE SECURITY CLAIM. Delete the check and the
# run exits 0, reports an install, and leaves the payload sitting in the
# attacker's directory — the staged copy in $WORKDIR is separately removed by the
# function's own closing `rm`, so the link inside the directory is all that
# survives. That is the exploit, and the count is what sees it.
SINK_DL_REALDIR_DEST="$WORK/sink-download-realdir-dest"
mkdir -p "$SINK_DL_REALDIR_DEST"

TESTS_RUN=$((TESTS_RUN + 1))
if [ -d "$SINK_DL_REALDIR_DEST" ] && [ ! -L "$SINK_DL_REALDIR_DEST" ]; then
	pass "sink: real-directory fixture — the destination name is a REAL directory, not a symlink to one"
else
	fail "sink: real-directory fixture — the destination name is a REAL directory, not a symlink to one" \
		"not a real directory: $SINK_DL_REALDIR_DEST"
fi
assert_dir_entry_count "sink: real-directory fixture — the destination directory starts EMPTY" \
	"$SINK_DL_REALDIR_DEST" 0

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
sink_download_run "" "$SINK_DOWNLOAD_ID" "$SINK_DL_REALDIR_DEST"
expect_rc "sink: a real directory at the destination -> exit 1 (the post-install check refuses it)" 1
stderr_has "sink: the refusal is the post-install check's OWN diagnostic, and it states nothing was left behind" \
	"download attachment $SINK_DOWNLOAD_ID: the destination became a directory while the file was being installed — the misplaced link inside it was removed (best effort), and nothing was installed at the destination itself"
# The generic install-failure diagnostic must be ABSENT: `ln -n` SUCCEEDED here
# (that is the whole premise), so its presence would mean this case is passing for
# the symlink case's reason instead of its own.
stderr_not_has "sink: the install \`ln\` itself did NOT fail — it succeeded into the directory, which is why a post-check is needed" \
	"could not install the downloaded file at the destination"
equals "sink: the refusal happened AFTER both requests (the payload really was fetched and really was linked)" \
	"$(call_count)" "2"
stdout_not_has "sink: nothing was reported as installed" "installed:"
assert_dir_entry_count "sink: THE MISPLACED LINK WAS WITHDRAWN — the directory is empty again, with no payload left in it" \
	"$SINK_DL_REALDIR_DEST" 0
# The directory itself must survive: the remedy is to remove the one misplaced
# entry, never to `rm -rf` a caller-named path the engine does not own.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -d "$SINK_DL_REALDIR_DEST" ]; then
	pass "sink: the destination directory itself still exists (only the misplaced link was removed)"
else
	fail "sink: the destination directory itself still exists (only the misplaced link was removed)" \
		"the directory was destroyed: $SINK_DL_REALDIR_DEST"
fi

section "jira.sh — download sink: a teardown \`rm\` that ITSELF fails changes neither the exit status nor the install (and the workdir it could not remove is 0700)"

# TWO CLAIMS, ONE RUN, and they share a fixture rather than duplicating it:
# everything below is an observation of the SAME successful-download-with-a-
# failing-teardown run, and each claim is broken by a DIFFERENT one-line change,
# so neither rides on the other.
#
# CLAIM 1 — `rm -rf "$WORKDIR" 2>/dev/null || true` inside runtime.sh's
# cleanup(). download_attachment_content itself removes nothing any more (its
# staged body lives in $WORKDIR, which the EXIT trap takes whole), so the last
# `rm` on this path is the trap's — and that `|| true` is load-bearing under this
# engine's `set -eu`: without it, an `rm` that fails aborts cleanup() BEFORE its
# `exit "$ec"`, and the process reports rm's status instead of the command's own.
# A SUCCESSFUL download is what makes that observable: exit 0 becomes exit 1
# purely because teardown could not delete a temp directory, on a download that
# completed and installed correctly. (A failing case could not say it — exit 1 is
# the answer either way.)
#
# `rm` IS OVERRIDDEN because nothing else can reach this branch: $WORKDIR is
# created 0700 under $TMPDIR by the engine's own mktemp -d, so no permission
# fixture a test may build makes its removal fail without also breaking the
# directory the whole run depends on. The override is the narrowest swap that
# leaves cleanup()'s ordering observable, exactly as the resolver override in the
# media-host case above is.
#
# CLAIM 2 — $WORKDIR's own 0700 mode, which the failing teardown makes observable
# for the first time: a cleanup that cannot delete leaves the directory in place
# for the harness to inspect. That mode is the whole reason the staged body is
# SAFE where it now lives (http.sh's header: the location closes the staging race,
# and it closes it because no other user can traverse an 0700 engine-owned
# directory), and a regression from `mktemp -d` to a plain `mkdir` of a
# predictable name would publish it at the caller's umask instead. Pinned under an
# explicit 022 (umask_run's header) so the assertion cannot pass by inheriting a
# restrictive ambient mask.
SINK_DOWNLOAD_RM_OVERRIDE='rm() { return 1; }
'
SINK_DOWNLOAD_RMFAIL_DEST="$WORK/sink-download-rmfail.bin"

# assert_workdir_is_0700 NAME TMPDIR — exactly ONE `jira.work.*` survived in
# TMPDIR and it is a 0700 DIRECTORY. Two steps with two diagnostics, because each
# fails for a different regression: the count catches a renamed or multiply-
# allocated workdir, and the mode catches one created by anything other than
# `mktemp -d`. The mode compare itself is assert_path_mode's, declared with the
# installed-mode section far above.
assert_workdir_is_0700() {
	awi_count=0
	awi_path=""
	for awi_candidate in "$2"/jira.work.*; do
		[ -d "$awi_candidate" ] || continue
		awi_count=$((awi_count + 1))
		awi_path=$awi_candidate
	done
	if [ "$awi_count" -ne 1 ]; then
		TESTS_RUN=$((TESTS_RUN + 1))
		fail "$1" "expected exactly ONE surviving '$2/jira.work.*' directory, found $awi_count"
		return 0
	fi
	assert_path_mode "$1" "$awi_path" "drwx------"
}

# A DEDICATED $TMPDIR FOR THIS ONE RUN, and it is containment as much as it is the
# scan target above. Disabling `rm` disables it for the WHOLE run, so everything
# runtime.sh's cleanup() would have removed leaks — including $WORKDIR, which
# normally lives directly under the harness's own $WORK. P2 further below asserts
# that NO `jira.work.*` survives there, and it means it: sweeping the leak away
# afterwards would work, but it would also mask a genuine leak from any earlier
# test, which is the one thing that gate exists to catch. Re-pointing $TMPDIR one
# level down keeps this fixture's debris out of P2's scan without touching P2's
# reach. It works because harness_run's `env -i` sets TMPDIR first and `env`
# honours the LAST assignment for a name.
SINK_DOWNLOAD_RMFAIL_TMPDIR="$WORK/rmfail-tmp"
mkdir -p "$SINK_DOWNLOAD_RMFAIL_TMPDIR"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
SINK_DOWNLOAD_RMFAIL_SAVED_UMASK=$(umask)
umask 022
sink_download_run "$SINK_DOWNLOAD_RM_OVERRIDE" "$SINK_DOWNLOAD_ID" "$SINK_DOWNLOAD_RMFAIL_DEST" \
	"TMPDIR=$SINK_DOWNLOAD_RMFAIL_TMPDIR"
umask "$SINK_DOWNLOAD_RMFAIL_SAVED_UMASK"
expect_rc "sink: a successful download whose teardown rm fails -> still exit 0" 0
stdout_has "sink: the failing teardown did not stop the install being reported" \
	"installed:$SINK_DOWNLOAD_RMFAIL_DEST"
equals "sink: the failing teardown did not stop the flow short (both requests were made)" "$(call_count)" "2"
assert_file_bytes_identical "sink: the failing teardown left the installed file intact" \
	"$SINK_DOWNLOAD_RMFAIL_DEST" "$ATTACH_DL_PAYLOAD_GOLDEN"
assert_workdir_is_0700 "sink: the workdir the teardown could not remove is exactly ONE 0700 directory (where the body staged)" \
	"$SINK_DOWNLOAD_RMFAIL_TMPDIR"
# The surviving workdir is the FIXTURE's doing, not the engine's, so this case
# clears it itself with the harness's own real `rm` — leaving debris a later case
# might reason about is how a fixture stops being local to the test that needs it.
rm -rf "$SINK_DOWNLOAD_RMFAIL_TMPDIR"

# ===========================================================================
# runtime.sh's CONFIG-INSTALL sequence, driven directly: assert_safe_install_dir,
# copy_to_new_file, the shared stage_install_copy, BOTH installers built on it
# (atomic_install for the replace paths, install_new_file for the create path) and
# assert_install_landed's own two branches.
#
# WHY IT EARNS A SINK BLOCK OF ITS OWN, next to the download install's. These
# functions replaced a `mktemp` + `cp` pair beside the destination that was
# a REAL local-file-tampering vulnerability: mktemp's own creation cannot be
# hijacked, but the `cp` RE-OPENED the staged name, so any local user able to
# write $JIRA_PROJECTS_DIR could unlink that entry and leave a symlink at it in
# between — the config write redirected to a path of their choosing, as the
# invoking user. It is the same vulnerability class the download install was
# rebuilt to close, and it shipped with no coverage at all.
#
# WHY THE CLI CANNOT REACH MOST OF WHAT IS BELOW. `discover --write` is the only
# caller, and by construction nothing it can dispatch arrives at the races: the
# staging name is minted by `mktemp -u`, so no test can predict it from outside
# the process, and a destination that is a symlink, a real directory, or gone by
# the time the rename lands is something only another process could produce. The
# sink driver is what makes each one reachable, exactly as it is for the
# download install's own two races above — and the CLI half that IS reachable
# (the $JIRA_PROJECTS_DIR gate, the installed modes, the `mktemp -u` dependency)
# has its own section at the end of this block.
#
# The driver's trailing arguments become the case's $1/$2 — a path travels as an
# ARGUMENT and is never interpolated into the case text (the driver's own note
# gives the reason).
# ===========================================================================

# The bytes every install case below installs, and the golden they are compared
# against. A FILE is the single source of truth (the download payload's own
# convention), so the source handed to the install and the expected result
# cannot drift; `cmp` rather than a string compare, for the reason
# assert_file_bytes_identical's note gives.
SINK_INSTALL_SRC="$WORK/install-source.json"
printf '{"custom_fields":{"Story Points":"customfield_10016"}}' >"$SINK_INSTALL_SRC"

# sink_install_run OVERRIDE_TEXT CASE_TEXT [ARG...] — drive one runtime.sh
# install helper, with OVERRIDE_TEXT (a function definition, or the empty string)
# prepended so it shadows a collaborator the helper calls. Under `nocurl`, like
# every other pure-helper probe in this block: none of these functions makes a
# request, and a toolbox with no curl at all is the strongest statement of that.
#
# THE SEPARATOR BETWEEN THE TWO IS THIS FUNCTION'S, not each caller's, because
# several overrides below are BUILT BY A FUNCTION and arrive through a `$( )` —
# which strips the trailing newline a literal would have carried, welding the
# override's closing `}` onto the case's first word. An empty override just
# yields a leading blank line, which is why this needs no branch.
#
# THE RUN'S UMASK IS PINNED TO 077's OPPOSITE, 022, for the reason umask_run's own
# header gives: `env -i` does not reset the process umask, so every 0600 mode
# claim below would pass for the wrong reason under an ambient 077. Pinning it
# here rather than at each of those cases keeps every probe in this block running
# under the same, realistic default-login mask.
sink_install_run() {
	sir_override=$1
	sir_case_text=$2
	shift 2
	printf '%s\n%s\n' "$sir_override" "$sir_case_text" >"$WORK/sink-case.sh"
	umask_run 022 nocurl sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh" "$@"
}

# THE PINNED MASK'S OWN CONTROL: a file this harness creates under the same 022
# must be 0644. If it ever reads `-rw-------`, every 0600 claim in this block has
# stopped proving anything.
SINK_INSTALL_UMASK_PROBE="$WORK/install-umask-probe.txt"
(umask 022; printf 'probe' >"$SINK_INSTALL_UMASK_PROBE")
assert_path_mode "install fixture: a file created under the probes' own umask (022) is 0644, so a 0600 install cannot come from the ambient mask" \
	"$SINK_INSTALL_UMASK_PROBE" "-rw-r--r--"

section "jira.sh — assert_safe_install_dir: which \$JIRA_PROJECTS_DIR the engine will install into, and which it refuses"

# THE SAME QUESTION assert_safe_tmpdir ASKS, ABOUT A DIFFERENT DIRECTORY, so the
# matrix below is deliberately the same one: the verdict is assert_safe_dir's
# shared core, and `ls -ld` position 6 (group write), 9 (other write) and 10
# (sticky) are three independent bits, so a mode that happens to be safe for two
# of them proves nothing about the third.
#
# WHAT IS NOT SHARED IS THE DIAGNOSTIC, and that is the whole reason this wrapper
# exists rather than a bare four-argument call: $JIRA_PROJECTS_DIR is the
# engine's OWN documented config location, so its remedy is a `chmod` of that
# directory, never the --download destination's "choose somewhere else" (a
# caller told to aim elsewhere has been handed a remedy for a choice they did not
# make). The wrapper-diagnostic case after the matrix is what pins that, and it
# is the ONLY thing in this file that can: every verdict arm below is satisfied
# by all three wrappers alike.
#
# WHAT IS ALSO NOT SHARED IS THE STICKY POLICY, which is the reason the matrix
# below is no longer arm-for-arm identical to the $TMPDIR one. assert_safe_dir
# takes an ENTRY_ATTACK argument, and this is the wrapper that passes the stricter
# `create-a-new-entry`: its attacker needs no removal at all, only the ability to
# CREATE an entry at $JIRA_PROJECTS_DIR/<KEY>.json — a name derived from a project
# key the caller hands the engine — and POSIX sticky semantics place no restriction
# whatever on creating a new entry. So the sticky EXEMPTION is withdrawn here and
# the write bits decide alone, while the other two wrappers keep it. The two
# sticky arms therefore land on the REFUSED side below, and the cross-wrapper
# section after this one is what proves the difference is a per-caller parameter
# rather than a global hardening.
#
# ITS OWN FIXTURES, not the $TMPDIR block's, for a reason beyond locality: the
# atomic_install cases further down WRITE into their destination directories, and
# a section that wrote into another section's mode fixtures would silently void
# that section's own claims.
SINK_INSTALL_FIXTURES="$WORK/install-dir-modes"
mkdir -p "$SINK_INSTALL_FIXTURES"
for sink_install_mode in 0700 0750 0770 0707 0777 1700 1777 1776; do
	mkdir -p "$SINK_INSTALL_FIXTURES/d$sink_install_mode"
	chmod "$sink_install_mode" "$SINK_INSTALL_FIXTURES/d$sink_install_mode"
done
: >"$SINK_INSTALL_FIXTURES/plainfile"
ln -s "$SINK_INSTALL_FIXTURES/d0700" "$SINK_INSTALL_FIXTURES/symlink-to-private"

# shellcheck disable=SC2016  # single-quoted on purpose: $1 is the CASE FILE's positional parameter (see the driver's note), not this harness's
SINK_INSTALL_DIR_CASE='assert_safe_install_dir "$1"
printf "safe\n"'

# THE TRAILING `printf` IS THE DISCRIMINATOR, the same shape and the same reason
# as the $TMPDIR probes above: assert_safe_install_dir is an ASSERT, not a
# predicate — it either returns or `exit`s 1 — and the driver runs under `set -eu`
# where any other failure also surfaces as a non-zero exit. A marker printed
# after the call is what separates "it returned" from "it exited".
#
# assert_install_dir_accepted DIR WHY [OVERRIDE] /
# assert_install_dir_refused DIR WHY NEEDLE [OVERRIDE] — one helper per outcome
# rather than one branching on an expected verdict: they assert genuinely
# different things (a return vs. an exit, and a diagnostic that exists only on
# one side), so a single parameterised helper would need an `if` around which
# assertions run — the one shape that makes a green run unreadable.
assert_install_dir_accepted() {
	sink_install_run "${3:-}" "$SINK_INSTALL_DIR_CASE" "$1"
	expect_rc "sink: assert_safe_install_dir accepts $2" 0
	stdout_has "sink: assert_safe_install_dir accepts $2 — it RETURNED rather than exiting" "safe"
}

assert_install_dir_refused() {
	sink_install_run "${4:-}" "$SINK_INSTALL_DIR_CASE" "$1"
	expect_rc "sink: assert_safe_install_dir refuses $2 -> exit 1 (fail closed)" 1
	stdout_not_has "sink: assert_safe_install_dir refuses $2 — it EXITED rather than returning" "safe"
	stderr_has "sink: assert_safe_install_dir refuses $2 — the diagnostic names the reason" "$3"
}

# The noun is part of every needle below, not just the reason: it is the only
# thing in a refusal that says WHICH of assert_safe_dir's three wrappers
# produced it, so a needle without it would be satisfied by the $TMPDIR gate's
# message just as happily.
SINK_INSTALL_NOUN="project-config directory"
SINK_INSTALL_UNREADABLE_DIAG="could not read the permissions of the $SINK_INSTALL_NOUN"
SINK_INSTALL_SHARED_TAIL="is writable by other local users and has no sticky bit"

# THE STRICTER POLICY'S OWN TAIL, and assert_safe_dir DERIVES it rather than
# pasting a second fixed message: under `create-a-new-entry` the sticky bit can be
# PRESENT and still exempt nothing, and a refusal that told the reader the
# directory "has no sticky bit" about a `drwxrwxrwt` one would send them to verify
# the single fact the refusal got wrong.
#
# IT IS ALSO THE NEEDLE THAT PINS THE POLICY TO THIS WRAPPER: the shared tail
# above is what the other two wrappers emit for these same two fixtures, so a
# needle made only of the prefix they have in common ("is writable by other local
# users") would be satisfied by either verdict.
SINK_INSTALL_STICKY_NOHELP_TAIL="is writable by other local users and its sticky bit does not help here — that bit restrains only REMOVING or RENAMING an entry, never CREATING a new one at a predictable name"

# THE OWNERSHIP DIAGNOSTIC, named here because several arms below assert its
# ABSENCE: under `create-a-new-entry` the write-bit refusal runs FIRST, so a
# sticky world-writable directory never reaches the owner half at all, and only
# the absence of this needle can say which of the two refusals fired.
SINK_INSTALL_OWNER_DIAG="carries the sticky bit but is owned by"

# THE ACCEPTED SIDE, which is also the answer to "does this new gate break
# ordinary use": a gate hardened to refuse everything satisfies every refusal
# below while making `discover --write` impossible on every machine. The private
# arm is spelled as a 0700 fixture AND, at the CLI section far below, as a real
# projects directory the engine created itself.
assert_install_dir_accepted "$SINK_INSTALL_FIXTURES/d0700" \
	"a PRIVATE 0700 directory — the mode \`discover --write\` creates a projects dir with"
assert_install_dir_accepted "$SINK_INSTALL_FIXTURES/d0750" \
	"a 0750 directory (group-READABLE is not group-writable)"
# STICKY BUT PRIVATE, and this arm is what says the stricter policy withdrew only
# the EXEMPTION rather than starting to refuse the BIT. 1700 carries the sticky bit
# with neither group nor other write, so there is nothing for an exemption to do:
# the write-bit check passes on its own merits, the directory then goes through the
# OWNER half of the sticky verdict (which runs under either policy), and the
# invoking user owns it — so it is accepted. It is also the only arm in this
# section that reaches assert_sticky_dir_owner through a REAL `ls` reading rather
# than a fabricated one.
assert_install_dir_accepted "$SINK_INSTALL_FIXTURES/d1700" \
	"a STICKY but PRIVATE directory (mode string 'T', no group or other write) — the bit itself is not what this gate refuses"
# THE `/.` SUFFIX IS LOAD-BEARING and only this arm can say so: `ls -ld` on a
# SYMLINK reports the LINK's own 0777 mode, which matches neither the directory
# pattern nor the sticky one, so a guard that dropped the `/.` would fail CLOSED
# on any symlinked projects dir. Every refusal arm below still refuses without
# it, just for the wrong reason.
assert_install_dir_accepted "$SINK_INSTALL_FIXTURES/symlink-to-private" \
	"a SYMLINK to a private directory (the \`ls -ldn DIR/.\` form resolves it)"

# THE REFUSED SIDE — the two writability bits separately, because they are two
# distinct `case` patterns and a single 0777 fixture would leave either one
# deletable with the suite still green.
assert_install_dir_refused "$SINK_INSTALL_FIXTURES/d0770" \
	"a GROUP-writable directory with no sticky bit" \
	"the $SINK_INSTALL_NOUN '$SINK_INSTALL_FIXTURES/d0770' $SINK_INSTALL_SHARED_TAIL"
assert_install_dir_refused "$SINK_INSTALL_FIXTURES/d0707" \
	"an OTHER-writable directory with no sticky bit" \
	"the $SINK_INSTALL_NOUN '$SINK_INSTALL_FIXTURES/d0707' $SINK_INSTALL_SHARED_TAIL"
assert_install_dir_refused "$SINK_INSTALL_FIXTURES/d0777" \
	"a world-writable directory with no sticky bit" \
	"the $SINK_INSTALL_NOUN '$SINK_INSTALL_FIXTURES/d0777' $SINK_INSTALL_SHARED_TAIL"

# THE STRICTER POLICY'S OWN TWO ARMS, which are THIS wrapper's alone: a sticky,
# world-writable directory (`--projects-dir /tmp`, say) is exactly the shape the
# other two wrappers ACCEPT and this one must not, because its attacker needs no
# removal — the name installed here is predictable from the project key, so they
# PRE-CREATE it and wait, and sticky restrains nothing about creating a new entry.
assert_install_dir_refused "$SINK_INSTALL_FIXTURES/d1777" \
	"a world-writable directory WITH the sticky bit, owned by the invoking user" \
	"the $SINK_INSTALL_NOUN '$SINK_INSTALL_FIXTURES/d1777' $SINK_INSTALL_STICKY_NOHELP_TAIL"
# THE REFUSAL MUST NOT MISREPORT THE BIT AS ABSENT — it is present on this
# fixture, and this absence is the only thing that separates the DERIVED sticky
# clause from the shared "has no sticky bit" one, which the same exit status and
# the same message prefix would otherwise satisfy.
stderr_not_has "sink: the sticky refusal does NOT claim the bit is missing (it is present, and says so)" \
	"has no sticky bit"
# WHICH OF THE TWO STICKY-RELATED REFUSALS FIRED IS NOT ASSERTED HERE, and the
# omission is deliberate: this fixture is owned by the invoking user, so the owner
# half would pass SILENTLY even if it ran first — an absence assertion over its
# diagnostic could never go red and would be pure decoration. The ordering arm at
# the end of the ownership section below fabricates a FOREIGN owner for exactly
# that reason, which is what makes the same claim falsifiable there.

# THE CAPITAL-`T` HALF of the sticky pattern, which still discriminates under the
# stricter policy — through the refusal's WORDING rather than an acceptance. 1776
# is group+world-writable with no other-execute, so `ls` prints `T`, and the
# derived clause asserted here is reachable ONLY when assert_safe_dir's `[tT]`
# pattern matched that `T`: delete the pattern and this fixture still refuses, but
# with the "has no sticky bit" tail instead. (A non-writable sticky fixture cannot
# make this claim — the $TMPDIR block records a 1700 one falling through the
# writability check and passing with the sticky pattern deleted.)
assert_install_dir_refused "$SINK_INSTALL_FIXTURES/d1776" \
	"a group+world-writable sticky directory with no other-execute (mode string 'T', not 't')" \
	"the $SINK_INSTALL_NOUN '$SINK_INSTALL_FIXTURES/d1776' $SINK_INSTALL_STICKY_NOHELP_TAIL"
stderr_not_has "sink: the capital-\`T\` refusal does not claim the bit is missing either" \
	"has no sticky bit"

# THE FAIL-CLOSED SIDE, where the mode string cannot be read as a directory's at
# all — a separate diagnostic, so these arms also pin WHICH refusal fired.
assert_install_dir_refused "$WORK/no-such-projects-dir-at-all" \
	"a projects dir that does not exist" "$SINK_INSTALL_UNREADABLE_DIAG"
assert_install_dir_refused "$SINK_INSTALL_FIXTURES/plainfile" \
	"a projects dir that is a FILE, not a directory" "$SINK_INSTALL_UNREADABLE_DIAG"

section "jira.sh — assert_safe_install_dir: the RISK and REMEDY that earn it a wrapper of its own"

# ONE PROBE, FOUR CLAIMS, and none of them is expressible through the matrix
# above: every verdict arm there passes identically for all three
# assert_safe_dir wrappers, so nothing yet distinguishes this one from a bare
# four-argument call that borrowed the --download or $TMPDIR fragments. Deleting
# this wrapper and calling assert_safe_download_dir instead — which is what a
# future "these are the same check, deduplicate them" edit looks like — leaves
# the whole matrix green and only these four lines red.
assert_install_dir_refused "$SINK_INSTALL_FIXTURES/d0777" \
	"the wrapper-diagnostic probe" \
	"the $SINK_INSTALL_NOUN '$SINK_INSTALL_FIXTURES/d0777' $SINK_INSTALL_SHARED_TAIL"
stderr_has "sink: the RISK names the config's post-install life — the field mappings a later WRITE pass trusts" \
	"replace the project config this engine reads back as its field mappings"
stderr_has "sink: the REMEDY is a \`chmod\` of THIS directory, because it is the engine's own documented config location" \
	"\`chmod go-w\` it"
stderr_not_has "sink: it is NOT the --download destination's remedy (which would tell the caller to aim somewhere they never chose)" \
	"choose a --download destination"
stderr_not_has "sink: it is NOT \$TMPDIR's remedy either" \
	"point \$TMPDIR at a PRIVATE directory"

section "jira.sh — assert_safe_dir: the sticky EXEMPTION is PER-CALLER, so ONE fixture earns THREE wrappers two different verdicts"

# THE CLAIM NO SINGLE-WRAPPER SECTION CAN MAKE, and the one that says the stricter
# install policy is a PARAMETER rather than a global hardening: the same
# world-writable sticky directory the matrix above now REFUSES for
# assert_safe_install_dir must still be ACCEPTED by the other two wrappers, whose
# attacker has to REMOVE or RENAME an entry this engine already created (an
# unpredictable `mktemp` name under $TMPDIR, a file `attach --download` has just
# installed) — which is precisely what the sticky bit restrains.
#
# COLLAPSE ENTRY_ATTACK TO ONE POLICY IN EITHER DIRECTION AND ONE SIDE OF THIS
# PAIR GOES RED, which is the whole reason it exists as a pair. Refuse-everywhere
# breaks the DEFAULT ${TMPDIR:-/tmp} — root-owned 1777 on every real system — and
# therefore every command in the engine; accept-everywhere re-opens the
# pre-created-entry hole at $JIRA_PROJECTS_DIR/<KEY>.json.
#
# ONE FIXTURE, THREE WRAPPERS, deliberately. A separate same-mode directory per
# wrapper would leave the contrast provable only by trusting that two `chmod`
# arguments are equal, which is exactly the assumption a mode typo hides inside.
#
# "IT ACCEPTED d1777" NEEDS A REFUSAL ARM BESIDE IT, because it is satisfied just
# as well by a wrapper that accepts everything — and that is not a hypothetical
# shape for these two, whose whole job is to refuse a shared directory. The
# $TMPDIR wrapper already has that control in its own matrix far above (a
# non-sticky world-writable fixture, refused), so only the --download wrapper
# needs one added here.
assert_tmpdir_accepted "$SINK_INSTALL_FIXTURES/d1777" \
	"the SAME world-writable sticky directory the install wrapper refuses — \$TMPDIR's own attacker must REMOVE an entry, which sticky restrains"

# THE --download WRAPPER HAD NO STICKY COVERAGE AT ALL before this section: every
# other case in this file drives it through `attach --download`'s pre-flight,
# which asserts the destination's existence and writability and never reaches a
# mode fixture. So it is probed directly, the same shape as the other two.
# shellcheck disable=SC2016  # single-quoted on purpose: $1 is the CASE FILE's positional parameter (see the driver's note), not this harness's
SINK_DOWNLOAD_DIR_CASE='assert_safe_download_dir "$1"
printf "safe\n"'

SINK_DOWNLOAD_DIR_NOUN="--download destination directory"

# sink_download_dir_probe DIR — one assert_safe_download_dir probe. The trailing
# marker is the discriminator, for the reason the $TMPDIR and install probes give.
sink_download_dir_probe() {
	printf '%s\n' "$SINK_DOWNLOAD_DIR_CASE" >"$WORK/sink-case.sh"
	run nocurl sh "$HTTP_SINK_DRIVER" "$SCRIPTS_DIR" "$WORK/sink-case.sh" "$1"
}

sink_download_dir_probe "$SINK_INSTALL_FIXTURES/d1777"
expect_rc "sink: assert_safe_download_dir accepts that same world-writable sticky directory too -> exit 0" 0
stdout_has "sink: assert_safe_download_dir accepted it — it RETURNED rather than exiting" "safe"
stderr_not_has "sink: and it did NOT emit the install wrapper's stricter sticky refusal" \
	"$SINK_INSTALL_STICKY_NOHELP_TAIL"

sink_download_dir_probe "$SINK_INSTALL_FIXTURES/d0777"
expect_rc "sink: assert_safe_download_dir refuses the non-sticky twin -> exit 1 (its acceptance above is not blanket)" 1
stdout_not_has "sink: the refused --download directory probe EXITED rather than returning" "safe"
stderr_has "sink: the refusal is the --download wrapper's own, naming its noun" \
	"the $SINK_DOWNLOAD_DIR_NOUN '$SINK_INSTALL_FIXTURES/d0777' $SINK_INSTALL_SHARED_TAIL"

section "jira.sh — assert_safe_install_dir: a STICKY projects dir is decided by its OWNER, not by its write bits"

# THE OTHER HALF OF THE STICKY VERDICT, which no real fixture can reach: POSIX
# sticky semantics restrain every user EXCEPT the directory's own owner, so a
# sticky directory an ATTACKER owns protects this engine from nobody — its owner
# may still rename an entry away and leave their own at the identical name. That
# arm needs a directory owned by another NON-ROOT uid, which a test cannot create
# without root, so `ls` is overridden to hand assert_safe_dir a fabricated
# `ls -ldn` reading instead. That is sound precisely because
# assert_sticky_dir_owner NEVER TOUCHES THE FILESYSTEM (its own header says so):
# every fact its verdict rests on comes out of that one line.
#
# THE FABRICATED MODE IS STICKY-BUT-PRIVATE (`drwx-----T`), NOT THE
# WORLD-WRITABLE `drwxrwxrwt` IT USED TO BE, and that change is what keeps this
# whole section meaningful under the `create-a-new-entry` policy. With the sticky
# exemption withdrawn for this wrapper, a sticky WORLD-WRITABLE directory is
# refused by the WRITE-BIT check and never reaches the owner half at all — so
# every arm below would have gone on passing while asserting an ownership
# diagnostic the engine no longer emits for that shape. A mode that is sticky with
# no group or other write clears the write-bit check on its own and arrives at the
# ownership question, which is the one under test here. (The ordering arm at the
# end of this section is where the world-writable shape is asserted, as a
# refusal.)
#
# The override is the narrowest swap that reaches the arm, the same shape as the
# `rm`/resolver overrides in the download sink sections above. `id -u` is left
# REAL, because the invoking user's own uid is half of the comparison under test.
#
# ASSERT_STICKY_DIR_OWNER ITSELF DID NOT CHANGE, and neither did any verdict below:
# what moved is only WHICH mode routes into it under this wrapper's policy.
SINK_INSTALL_STICKY_DIR="$SINK_INSTALL_FIXTURES/d1700"
SINK_INSTALL_SELF_UID=$(id -u)
# Derived from the real uid rather than a literal, so the "another user" arm
# cannot accidentally name the uid running the suite — on a machine where it did,
# the case would assert a refusal that correctly never comes.
SINK_INSTALL_FOREIGN_UID=$((SINK_INSTALL_SELF_UID + 4242))

# sink_install_ls_override UID -> an `ls` that reports a STICKY, otherwise PRIVATE
# directory owned by UID. Built by a function rather than pasted per case because
# the MODE STRING must be identical across the three arms: the only thing any of
# them varies is the owner, and a per-case copy is how one ends up also varying
# the bit under test.
sink_install_ls_override() {
	printf "ls() { printf 'drwx-----T 2 %s 20 64 Jan 1 00:00 .'; }\n" "$1"
}

assert_install_dir_refused "$SINK_INSTALL_STICKY_DIR" \
	"a sticky directory owned by ANOTHER non-root user (uid $SINK_INSTALL_FOREIGN_UID)" \
	"carries the sticky bit but is owned by ANOTHER user (uid $SINK_INSTALL_FOREIGN_UID — neither root nor you)" \
	"$(sink_install_ls_override "$SINK_INSTALL_FOREIGN_UID")"
stderr_has "sink: the foreign-owner refusal carries the INSTALL wrapper's own remedy, not another wrapper's" \
	"\`chmod go-w\` it"

# ROOT COUNTS AS SAFE, deliberately: root can defeat any check this engine could
# make, and the default /tmp is root-owned 1777 on every real system. Overridden
# rather than probed against the real /tmp so the arm holds on a machine whose
# /tmp is owned by anyone else.
assert_install_dir_accepted "$SINK_INSTALL_STICKY_DIR" \
	"a sticky directory owned by ROOT (uid 0)" \
	"$(sink_install_ls_override 0)"
assert_install_dir_accepted "$SINK_INSTALL_STICKY_DIR" \
	"a sticky directory owned by the INVOKING user (uid $SINK_INSTALL_SELF_UID)" \
	"$(sink_install_ls_override "$SINK_INSTALL_SELF_UID")"

# AN UNREADABLE OWNER ON A STICKY DIRECTORY MUST REFUSE, and this is the arm that
# says so: the sticky bit does not restrain the directory's own owner, so an
# owner that cannot be read is the precise case that must not be waved through.
# The fabricated line carries a NAME where `ls -ldn` guarantees a numeric uid,
# which is what the parser cannot use.
assert_install_dir_refused "$SINK_INSTALL_STICKY_DIR" \
	"a sticky directory whose owner uid cannot be read" \
	"could not read the owner of the $SINK_INSTALL_NOUN" \
	"$(printf "ls() { printf 'drwx-----T 2 someuser staff 64 Jan 1 00:00 .'; }\n")"

# THE ORDERING, WHICH IS A FOURTH THING THE OWNER CHECK IS NOT. Under
# `create-a-new-entry` the write bits refuse a sticky WORLD-WRITABLE directory
# outright, so the owner half is never consulted at all. Fabricated with the same
# shape as the arms above and with only the MODE changed, so the two claims differ
# in exactly one byte range.
#
# THE OWNER IS THE FOREIGN UID, NOT THE INVOKING USER'S, AND THAT IS WHAT MAKES
# THIS ARM FALSIFIABLE. An owner the check would ACCEPT passes silently, so an
# absence assertion over its diagnostic could never go red no matter how the two
# checks were ordered. With an owner it would REFUSE, the two orderings produce
# two different diagnostics — so the needle and its companion absence together
# pin which check ran first, which neither can do alone.
assert_install_dir_refused "$SINK_INSTALL_STICKY_DIR" \
	"a sticky WORLD-WRITABLE directory owned by ANOTHER user — refused by the WRITE BITS, before ownership is ever consulted" \
	"the $SINK_INSTALL_NOUN '$SINK_INSTALL_STICKY_DIR' $SINK_INSTALL_STICKY_NOHELP_TAIL" \
	"$(printf "ls() { printf 'drwxrwxrwt 2 %s 20 64 Jan 1 00:00 .'; }\n" "$SINK_INSTALL_FOREIGN_UID")"
stderr_not_has "sink: the owner half never ran — the write-bit refusal precedes it, even on a directory ownership would ALSO have refused" \
	"$SINK_INSTALL_OWNER_DIAG"

section "jira.sh — assert_safe_dir: the ACL WARNING is memoized per directory per process — the VERDICT never is"

# WHAT THE MEMO IS FOR. `discover --write` gates $JIRA_PROJECTS_DIR TWICE by
# design (save_discovered_config's own call, then the installer's through
# stage_install_copy), so an ACL-bearing projects directory used to print the
# same warning twice on one run — and a reader who sees a warning twice per
# invocation learns to skip it, which costs exactly the one thing a warn-not-
# refuse policy is buying.
#
# AND WHAT IT IS EMPHATICALLY NOT FOR. It memoizes the WARNING, never the
# VERDICT: every refusal still re-reads the directory's mode immediately before
# the write it guards, so this cannot widen any check-then-use window. Arms (a)
# and (b) pin the memo; arm (c) is the one that pins the non-memoized verdict, and
# it is the arm that matters — a "fix" that cached the whole verdict would satisfy
# (a) and (b) perfectly.
#
# DRIVEN THROUGH AN `ls` OVERRIDE for the reason the ownership section's arms are,
# with one extra: a REAL ACL cannot reach this block on macOS at all. `ls` prints
# ONE marker character and `@` (extended attributes) outranks `+`, and every
# directory on macOS 26 carries an unremovable `com.apple.provenance` xattr — so
# `chmod +a` yields `drwx------@` and is NOT flagged. runtime.sh discloses that,
# and it was re-verified here before these arms were written.
SINK_ACL_LS_OVERRIDE="ls() { printf 'drwx------+ 2 0 0 64 Jan 1 00:00 .'; }"
SINK_ACL_WARN_NEEDLE="carries an ACL or extended permissions"
SINK_ACL_DIR_A="$SINK_INSTALL_FIXTURES/d0700"
SINK_ACL_DIR_B="$SINK_INSTALL_FIXTURES/d0750"

# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_ACL_TWICE_CASE='assert_safe_install_dir "$1"
printf "gated:1\n"
assert_safe_install_dir "$1"
printf "gated:2\n"'

# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_ACL_TWO_DIRS_CASE='assert_safe_install_dir "$1"
printf "gated:1\n"
assert_safe_install_dir "$2"
printf "gated:2\n"'

# assert_stderr_occurrences NAME NEEDLE COUNT — NEEDLE appears on exactly COUNT
# lines of the last run's stderr. The one claim stderr_has cannot make: "the
# warning fired" is true of one warning and of five, so a presence assertion is
# green for precisely the regression this section exists to catch.
assert_stderr_occurrences() {
	TESTS_RUN=$((TESTS_RUN + 1))
	aso_count=$(printf '%s\n' "$CUR_ERR" | grep -Fc -- "$2" || true)
	if [ "$aso_count" -eq "$3" ]; then pass "$1"
	else fail "$1" "expected $3 occurrence(s) of '$2' on stderr, found $aso_count; stderr was: $CUR_ERR"; fi
}

# (a) THE SAME DIRECTORY, GATED TWICE IN ONE PROCESS — ONE warning. The
# `gated:2` marker is what separates this from a run that warned once because it
# only ever gated once: without it, deleting the second gate call satisfies the
# count perfectly.
sink_install_run "$SINK_ACL_LS_OVERRIDE" "$SINK_ACL_TWICE_CASE" "$SINK_ACL_DIR_A"
expect_rc "sink: an ACL-bearing directory gated twice -> exit 0 (the ACL is WARNED about, never refused)" 0
stdout_has "sink: BOTH gates ran — the second call really was made" "gated:2"
assert_stderr_occurrences "sink: THE WARNING FIRED ONCE, not once per gate" "$SINK_ACL_WARN_NEEDLE" 1
stderr_has "sink: the warning names the directory, this wrapper's noun and the mode it read" \
	"the $SINK_INSTALL_NOUN '$SINK_ACL_DIR_A' carries an ACL or extended permissions (drwx------+)"
stderr_has "sink: and it carries the install wrapper's own remedy, not another wrapper's" \
	"\`chmod go-w\` it"

# (b) TWO DIFFERENT DIRECTORIES — TWO warnings. The memo is a LIST keyed on the
# directory, not a process-wide "already warned" flag, and only this arm can tell
# those apart: a single-slot memo answers both of these calls with one warning and
# silently hides the second directory's ACL.
sink_install_run "$SINK_ACL_LS_OVERRIDE" "$SINK_ACL_TWO_DIRS_CASE" "$SINK_ACL_DIR_A" "$SINK_ACL_DIR_B"
expect_rc "sink: two ACL-bearing directories gated once each -> exit 0" 0
stdout_has "sink: both directories were gated" "gated:2"
assert_stderr_occurrences "sink: TWO directories warn TWICE — the memo is per-directory, not a one-shot" \
	"$SINK_ACL_WARN_NEEDLE" 2
stderr_has "sink: the first directory is named in its own warning" \
	"'$SINK_ACL_DIR_A' carries an ACL"
stderr_has "sink: the second directory is named in its own warning" \
	"'$SINK_ACL_DIR_B' carries an ACL"

# (c) THE VERDICT IS RE-READ, WHICH IS THE CLAIM THAT MATTERS. The override
# answers the FIRST reading with a private ACL-bearing mode and every later one
# with a world-writable ACL-bearing mode — the mode changing under the engine
# between two gates of the same directory, which is exactly the check-then-use
# window a verdict cache would open. The second gate must REFUSE.
#
# A PROBE FILE IS THE COUNTER because the override is a function in a sourced
# case file, so it has no variable of its own that survives between calls. Its
# path is interpolated into the override text (the `mktemp` overrides above set
# that precedent); it is removed first so a re-run cannot inherit the flipped
# state.
SINK_ACL_FLIP_PROBE="$WORK/install-acl-flip-probe"
rm -f "$SINK_ACL_FLIP_PROBE"
SINK_ACL_FLIP_OVERRIDE="ls() {
	if [ -e '$SINK_ACL_FLIP_PROBE' ]; then
		printf 'drwxrwxrwx+ 2 0 0 64 Jan 1 00:00 .'
	else
		: >'$SINK_ACL_FLIP_PROBE'
		printf 'drwx------+ 2 0 0 64 Jan 1 00:00 .'
	fi
}"
sink_install_run "$SINK_ACL_FLIP_OVERRIDE" "$SINK_ACL_TWICE_CASE" "$SINK_ACL_DIR_A"
expect_rc "sink: a directory that turns world-writable between two gates -> exit 1 (the second gate refuses)" 1
stdout_has "sink: the FIRST gate accepted, on the first reading's private mode" "gated:1"
stdout_not_has "sink: the SECOND gate REFUSED — the mode was re-read, not recalled" "gated:2"
stderr_has "sink: the refusal is the write-bit check's, on the mode the SECOND reading returned" \
	"the $SINK_INSTALL_NOUN '$SINK_ACL_DIR_A' $SINK_INSTALL_SHARED_TAIL"

section "jira.sh — copy_to_new_file: what noclobber refuses AT the name, and what the POST-WRITE check refuses instead"

# THE PRIMITIVE THE VULNERABILITY FIX IS BUILT ON, driven on its own. `set -C`
# (noclobber) makes the redirection an O_CREAT|O_EXCL open, so the create and the
# write are ONE operation with no re-openable name in between — which is what
# stops the old `mktemp` + `cp` pair's window from existing at all.
#
# BUT NOCLOBBER IS NARROWER THAN O_EXCL, AND THE ARMS BELOW ARE SPLIT ALONG THAT
# LINE. POSIX's NOCLOBBER is specified to fail only "if the file exists and is a
# REGULAR file", and both `bash`-as-`sh` and `dash` implement exactly that: they
# try O_CREAT|O_EXCL, and on EEXIST they `stat` the path and re-open WITHOUT
# O_EXCL when what is there is not a regular file. So:
#   * an existing regular file, a symlink resolving to one, and a DANGLING symlink
#     (whose `stat` fails) are all refused AT the name — arms (b), (c), (d);
#   * a symlink resolving to a DEVICE, FIFO or socket is NOT: the shell opens and
#     writes THROUGH it, and the refusal comes from the POST-WRITE verification
#     instead — arms (e) and (f). Both directions were re-verified against `sh`
#     and `dash` on this platform before these arms were written.
# A single needle covering both would therefore have asserted the wrong mechanism
# for half the fixtures, which is precisely the overclaim runtime.sh's own header
# records having made.
#
# EVERY ARM ASSERTS THE SAME TWO THINGS BESIDES THE VERDICT: that whatever the
# entry pointed AT is untouched (or, for a write that does complete, that the copy
# is refused rather than reported), and that the entry itself is left exactly as it
# was found — the refusal deliberately removes nothing it did not create.
#
# THE LABEL IS ASSERTED TOO, because it is a parameter: the diagnostic is
# prefixed with the operation its CALLER is performing, and the callers
# (stage_install_copy's staging, save_discovered_config's backup) are told apart
# by nothing else.
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_CTNF_CASE='copy_to_new_file "$1" "$2" "install probe"
printf "copied:%s\n" "$2"'

SINK_CTNF_REFUSAL="install probe: could not create"

# THE TWO REFUSALS' OWN NEEDLES, named because several arms below assert one and
# the ABSENCE of the other — which is the only thing that says WHICH mechanism
# fired, since both exit 1 under the same label.
SINK_CTNF_ENTRY_NEEDLE="an entry already at that name, which is refused rather than written through"
SINK_CTNF_POSTWRITE_NEEDLE="is not the regular file this copy created — the write went through something else"

SINK_CTNF_DIR="$WORK/install-ctnf"
mkdir -p "$SINK_CTNF_DIR"

# (a) A FRESH NAME — the positive control, without which every refusal below is
# satisfied by a primitive that simply never writes anything. It also carries the
# MODE claim: `umask 077` inside the subshell is the only thing that gives the
# file its 0600, and the probes run under a pinned 022 (sink_install_run's
# header), so dropping that umask publishes the config at the caller's own mask.
SINK_CTNF_FRESH="$SINK_CTNF_DIR/fresh.json"
sink_install_run "" "$SINK_CTNF_CASE" "$SINK_INSTALL_SRC" "$SINK_CTNF_FRESH"
expect_rc "sink: copy_to_new_file onto a fresh name -> exit 0" 0
stdout_has "sink: the fresh copy reported completing" "copied:$SINK_CTNF_FRESH"
assert_file_bytes_identical "sink: the fresh copy holds the source's exact bytes" \
	"$SINK_CTNF_FRESH" "$SINK_INSTALL_SRC"
assert_path_mode "sink: the fresh copy is exactly 0600 — the \`umask 077\` inside copy_to_new_file, not the caller's mask" \
	"$SINK_CTNF_FRESH" "-rw-------"

# (b) AN EXISTING REGULAR FILE. The weakest of the shapes, and the one that says
# `set -C` is present at all — it is also the arm that pins the PRESERVATION half
# of the failure path's cleanup. copy_to_new_file removes a DEST it created and
# deliberately leaves one that was already there, and the bytes-identical
# assertion below is what sees that distinction: it requires the entry still to
# exist, so a cleanup that removed what it had refused to overwrite turns this arm
# red rather than merely changing a mode.
SINK_CTNF_EXISTING="$SINK_CTNF_DIR/existing.json"
printf 'ORIGINAL-CONTENT' >"$SINK_CTNF_EXISTING"
SINK_CTNF_EXISTING_GOLDEN="$WORK/install-ctnf-existing-golden"
cp "$SINK_CTNF_EXISTING" "$SINK_CTNF_EXISTING_GOLDEN"
sink_install_run "" "$SINK_CTNF_CASE" "$SINK_INSTALL_SRC" "$SINK_CTNF_EXISTING"
expect_rc "sink: copy_to_new_file onto an EXISTING file -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal is prefixed with the CALLER's label and names the path" \
	"$SINK_CTNF_REFUSAL '$SINK_CTNF_EXISTING'"
stderr_has "sink: the refusal names the entry-at-the-name cause among its possibilities" \
	"$SINK_CTNF_ENTRY_NEEDLE"
stdout_not_has "sink: the refused copy never reported completing" "copied:"
assert_file_bytes_identical "sink: THE PRE-EXISTING FILE SURVIVES the refusal — it is neither overwritten, truncated, nor cleaned up as if this copy had created it" \
	"$SINK_CTNF_EXISTING" "$SINK_CTNF_EXISTING_GOLDEN"

# (c) A SYMLINK TO AN EXISTING FILE — THE VULNERABILITY ITSELF, at the primitive.
# This is the entry an attacker leaves at a staged name; the old `cp`-by-name
# wrote straight through it, as the invoking user. The claim that matters is the
# TARGET's bytes, not the exit code: a mechanism that refused for some unrelated
# reason after writing would satisfy an exit-status assertion alone.
SINK_CTNF_ATTACKER_TARGET="$SINK_CTNF_DIR/attacker-owned.txt"
printf 'ATTACKER-CONTENT' >"$SINK_CTNF_ATTACKER_TARGET"
SINK_CTNF_ATTACKER_GOLDEN="$WORK/install-ctnf-attacker-golden"
cp "$SINK_CTNF_ATTACKER_TARGET" "$SINK_CTNF_ATTACKER_GOLDEN"
SINK_CTNF_SYMLINK="$SINK_CTNF_DIR/symlink-staged-name"
ln -s "$SINK_CTNF_ATTACKER_TARGET" "$SINK_CTNF_SYMLINK"
sink_install_run "" "$SINK_CTNF_CASE" "$SINK_INSTALL_SRC" "$SINK_CTNF_SYMLINK"
expect_rc "sink: copy_to_new_file onto a SYMLINK to an existing file -> exit 1 (fail closed)" 1
stderr_has "sink: the symlink refusal states an entry at the name is refused rather than written through" \
	"$SINK_CTNF_ENTRY_NEEDLE"
# THE MECHANISM IS NOCLOBBER'S, NOT THE POST-WRITE CHECK'S, and only this absence
# says so: a symlink resolving to a REGULAR file is refused at the name, so the
# write never happens and the verification below it is never reached. The two
# refusals are otherwise indistinguishable — same exit status, same label.
stderr_not_has "sink: the POST-WRITE verification was never reached (noclobber refused the name first)" \
	"$SINK_CTNF_POSTWRITE_NEEDLE"
stdout_not_has "sink: the refused symlink copy never reported completing" "copied:"
assert_file_bytes_identical "sink: THE ATTACKER'S TARGET IS UNTOUCHED — nothing was written through the symlink" \
	"$SINK_CTNF_ATTACKER_TARGET" "$SINK_CTNF_ATTACKER_GOLDEN"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_CTNF_SYMLINK" ]; then
	pass "sink: the symlink was left exactly as it was found (the refusal removes nothing)"
else
	fail "sink: the symlink was left exactly as it was found (the refusal removes nothing)" \
		"the symlink is gone or was replaced: $SINK_CTNF_SYMLINK"
fi

# (d) A DANGLING SYMLINK, which is the shape that would CREATE a file at a path
# of the attacker's choosing rather than overwrite one — and the arm whose main
# proof is an ABSENCE. Noclobber refuses it too, though by a different route than
# the two above: the O_EXCL open fails EEXIST, and the `stat` the shell then makes
# to decide whether to retry cannot resolve a dangling link at all, so the
# redirection stays refused and the target is never brought into existence.
SINK_CTNF_DANGLING_TARGET="$SINK_CTNF_DIR/never-create-me.txt"
SINK_CTNF_DANGLING="$SINK_CTNF_DIR/dangling-staged-name"
ln -s "$SINK_CTNF_DANGLING_TARGET" "$SINK_CTNF_DANGLING"
sink_install_run "" "$SINK_CTNF_CASE" "$SINK_INSTALL_SRC" "$SINK_CTNF_DANGLING"
expect_rc "sink: copy_to_new_file onto a DANGLING symlink -> exit 1 (fail closed)" 1
stdout_not_has "sink: the refused dangling copy never reported completing" "copied:"
assert_path_absent "sink: THE DANGLING TARGET WAS NEVER CREATED — the write did not follow the link" \
	"$SINK_CTNF_DANGLING_TARGET"
# THE LINK ITSELF SURVIVES, and this arm is the ONLY one that can say it. The
# failure path's cleanup asks "did I create the entry at DEST" with `[ -e ] ||
# [ -L ]`, and `-e` is FALSE for a dangling symlink — so with the `-L` half
# dropped, the attribution flips to "mine", and the refusal unlinks the
# attacker's link as if tidying its own partial copy. Nothing else in this
# section distinguishes that: every other fixture satisfies `-e`.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_CTNF_DANGLING" ]; then
	pass "sink: the DANGLING link was left exactly as it was found — the cleanup's \`-L\` half is what keeps it attributed to the attacker, not to this copy"
else
	fail "sink: the DANGLING link was left exactly as it was found — the cleanup's \`-L\` half is what keeps it attributed to the attacker, not to this copy" \
		"the dangling symlink is gone or was replaced: $SINK_CTNF_DANGLING"
fi

# (e) A SYMLINK TO A CHARACTER DEVICE — THE SHAPE NOCLOBBER CONCEDES, and the arm
# the POST-WRITE verification exists for. /dev/null is not a regular file, so the
# shell's retry-without-O_EXCL path opens it and the write COMPLETES through the
# link; only the `[ -f ] && [ ! -L ]` check afterwards turns that into a refusal.
# Without it the copy reports success, and both installers then go on to publish
# a "config" that was never written to disk.
#
# /dev/null RATHER THAN A FIFO, deliberately, and the choice is a hard constraint
# rather than a preference: runtime.sh discloses that a FIFO with no reader makes
# the open BLOCK, so that fixture would hang this suite indefinitely instead of
# failing it. A character device reaches the identical branch with no reader to
# arrange, and the blocking-FIFO gap stays what runtime.sh says it is — disclosed,
# not covered.
SINK_CTNF_DEVLINK="$SINK_CTNF_DIR/symlink-to-device"
ln -s /dev/null "$SINK_CTNF_DEVLINK"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_CTNF_DEVLINK" ] && [ -c "$SINK_CTNF_DEVLINK" ]; then
	pass "sink: device-symlink fixture — the planted name really is a symlink, and it really resolves to a character device"
else
	fail "sink: device-symlink fixture — the planted name really is a symlink, and it really resolves to a character device" \
		"not a symlink-to-device: $SINK_CTNF_DEVLINK"
fi
sink_install_run "" "$SINK_CTNF_CASE" "$SINK_INSTALL_SRC" "$SINK_CTNF_DEVLINK"
expect_rc "sink: copy_to_new_file onto a SYMLINK TO A DEVICE -> exit 1 (the post-write verification refuses it)" 1
stderr_has "sink: the refusal is the POST-WRITE verification's, naming what the write went through" \
	"$SINK_CTNF_POSTWRITE_NEEDLE"
# NOCLOBBER DID NOT REFUSE THIS ONE, and only this absence says so — which is the
# whole point of splitting the two needles. A run that refused at the name would
# satisfy the exit status and the label identically while proving the opposite
# mechanism.
stderr_not_has "sink: noclobber did NOT refuse the name here — the create SUCCEEDED and the write went through" \
	"$SINK_CTNF_ENTRY_NEEDLE"
stdout_not_has "sink: the refused device-symlink copy never reported completing" "copied:"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_CTNF_DEVLINK" ] && [ -c "$SINK_CTNF_DEVLINK" ]; then
	pass "sink: the device symlink was left exactly as it was found — this refusal removes nothing, since what is at the path was not created by the engine"
else
	fail "sink: the device symlink was left exactly as it was found — this refusal removes nothing, since what is at the path was not created by the engine" \
		"the device symlink is gone or was replaced: $SINK_CTNF_DEVLINK"
fi

# (f) A NON-REGULAR DESTINATION THAT IS NOT A SYMLINK AT ALL, which is the other
# half of the post-write test and the only arm that isolates it. The check is
# `[ ! -f ] || [ -L ]`, and arm (e) satisfies BOTH halves at once — so with the
# `! -f` half deleted, (e) still goes red through `-L` and nothing notices. A
# character device AT the destination name satisfies only `! -f`.
sink_install_run "" "$SINK_CTNF_CASE" "$SINK_INSTALL_SRC" /dev/null
expect_rc "sink: copy_to_new_file onto a CHARACTER DEVICE itself -> exit 1 (the \`! -f\` half of the verification)" 1
stderr_has "sink: the refusal is the post-write verification's, for a destination that is no symlink" \
	"$SINK_CTNF_POSTWRITE_NEEDLE"
stdout_not_has "sink: the refused device copy never reported completing" "copied:"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -c /dev/null ]; then
	pass "sink: /dev/null is still a character device — the refusal removed nothing"
else
	fail "sink: /dev/null is still a character device — the refusal removed nothing" \
		"/dev/null is no longer a character device"
fi

# (g) A SOURCE THAT CANNOT BE OPENED leaves the caller nothing at the destination.
# A NET-BEHAVIOUR CLAIM, DELIBERATELY, because TWO independent layers now deliver
# it and either one alone satisfies this arm (mutating each in turn was how that
# was established, not inferred): SRC is opened FIRST, so an unopenable source
# creates no DEST at all; and the failure path withdraws a DEST this function did
# create. Read this arm as "the caller is never handed a stray file", never as a
# claim about which mechanism delivered that — (g2) is the arm that isolates one.
SINK_CTNF_NOSRC="$SINK_CTNF_DIR/no-such-source.json"
SINK_CTNF_NOSRC_DEST="$SINK_CTNF_DIR/nothing-should-appear-here.json"
sink_install_run "" "$SINK_CTNF_CASE" "$SINK_CTNF_NOSRC" "$SINK_CTNF_NOSRC_DEST"
expect_rc "sink: copy_to_new_file from an UNREADABLE source -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal names the source among its possible causes, rather than asserting one cause" \
	"a source that could not be read ('$SINK_CTNF_NOSRC')"
stdout_not_has "sink: the refused copy never reported completing" "copied:"
assert_path_absent "sink: NOTHING WAS LEFT AT THE DESTINATION for the caller to mistake for a real file" \
	"$SINK_CTNF_NOSRC_DEST"

# (g2) THE REDIRECTION ORDER, ISOLATED FROM THE CLEANUP THAT MASKS IT. The earlier
# `cat >DEST <SRC` spelling CREATED DEST before it ever tried to open SRC, leaving
# a stray empty file at a name the caller was then told already held "a leftover
# from an interrupted run" — a leftover this function had itself just made. (g)
# cannot see that regression, because the cleanup tidies the stray away; this arm
# removes the mask by overriding `rm` to FAIL, a condition runtime.sh's own
# cleanup idiom explicitly tolerates ("a failing `rm` must not change the reported
# reason"). With SRC opened first there is nothing for the cleanup to fail at at
# all; with DEST opened first the stray survives and the absence below goes red.
SINK_CTNF_ORDER_DEST="$SINK_CTNF_DIR/order-nothing-should-appear-here.json"
sink_install_run 'rm() { return 1; }' \
	"$SINK_CTNF_CASE" "$SINK_CTNF_NOSRC" "$SINK_CTNF_ORDER_DEST"
expect_rc "sink: copy_to_new_file from an unreadable source with an \`rm\` that FAILS -> exit 1 (a failing cleanup does not change the reason)" 1
stderr_has "sink: the failing \`rm\` did not change the reported reason — the source is still named" \
	"a source that could not be read ('$SINK_CTNF_NOSRC')"
stdout_not_has "sink: the refused copy never reported completing" "copied:"
assert_path_absent "sink: THE DESTINATION WAS NEVER CREATED IN THE FIRST PLACE — SRC is opened FIRST, so there is no stray for the (failing) cleanup to have to remove" \
	"$SINK_CTNF_ORDER_DEST"

# (h) A COPY THAT FAILS PART-WAY THROUGH, which is the counterpart to (b)'s
# preservation claim and the only arm that reaches the cleanup's other branch: a
# DEST this function created and then could not finish is WITHDRAWN. No fixture
# can produce a mid-copy failure on a destination the engine is allowed to write,
# so `cat` is overridden to emit bytes and then fail — the narrowest swap that
# reaches it, and one that leaves the noclobber create itself completely real.
SINK_CTNF_PARTIAL_DEST="$SINK_CTNF_DIR/partial.json"
sink_install_run 'cat() { printf "PARTIAL-BYTES"; return 1; }' \
	"$SINK_CTNF_CASE" "$SINK_INSTALL_SRC" "$SINK_CTNF_PARTIAL_DEST"
expect_rc "sink: copy_to_new_file whose copy fails part-way -> exit 1 (fail closed)" 1
stderr_has "sink: the partial copy reports through the same labelled refusal" \
	"$SINK_CTNF_REFUSAL '$SINK_CTNF_PARTIAL_DEST'"
stdout_not_has "sink: the partial copy never reported completing" "copied:"
assert_path_absent "sink: THE PARTIAL COPY WAS WITHDRAWN — a DEST this function created and could not finish leaves no litter a later reader could mistake for a real file" \
	"$SINK_CTNF_PARTIAL_DEST"

section "jira.sh — atomic_install: the destination DIRECTORY is gated inside the install, so every caller inherits it"

# WHY THIS IS NOT THE MATRIX SECTION AGAIN. Those probes prove the WRAPPER
# refuses; this one proves an atomic_install REACHES it — through the shared
# stage_install_copy, and before anything is staged. Delete the call from
# stage_install_copy and the matrix stays green in full, because
# save_discovered_config takes the same gate itself; only this case, the
# install_new_file case below and the CLI fresh-directory case at the end of this
# block go red.
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_AI_CASE='atomic_install "$1" "$2"
printf "installed:%s\n" "$2"'

SINK_AI_UNSAFE_DIR="$WORK/install-ai-unsafe"
mkdir -p "$SINK_AI_UNSAFE_DIR"
chmod 0777 "$SINK_AI_UNSAFE_DIR"
SINK_AI_UNSAFE_DEST="$SINK_AI_UNSAFE_DIR/PROJ.json"

sink_install_run "" "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_UNSAFE_DEST"
expect_rc "sink: atomic_install into a world-writable directory -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal is the project-config directory gate's own" \
	"the $SINK_INSTALL_NOUN '$SINK_AI_UNSAFE_DIR' $SINK_INSTALL_SHARED_TAIL"
stdout_not_has "sink: the refused install never reported installing" "installed:"
assert_path_absent "sink: the refused install created no destination file" "$SINK_AI_UNSAFE_DEST"
assert_dir_entry_count "sink: the refused install left the directory EMPTY — the gate precedes the staging, so not even a \`.tmp.\` entry appeared" \
	"$SINK_AI_UNSAFE_DIR" 0

section "jira.sh — atomic_install: a SYMLINK planted at the STAGING NAME is refused, and nothing is written through it"

# THE VULNERABILITY THIS FUNCTION WAS REBUILT TO CLOSE, reconstructed. The
# attacker's move is to leave a symlink at the name the install is about to
# stage into; the old `mktemp` + `cp` pair re-opened that name and wrote through
# it, so the config landed wherever the link pointed, as the invoking user.
#
# `mktemp` IS OVERRIDDEN, and nothing else can reach this case: the real
# `mktemp -u` mints an unpredictable name by design, so no test outside the
# process can plant an entry at it. The override emulates `-u` exactly —
# it prints a name and CREATES NOTHING — and ignores its arguments, which is
# safe here because atomic_install calls `mktemp` exactly once and never reaches
# ensure_workdir. The control case below is what proves the override really is
# the name the install uses.
SINK_AI_STAGE_DIR="$WORK/install-ai-staging"
mkdir -p "$SINK_AI_STAGE_DIR"
SINK_AI_STAGE_DEST="$SINK_AI_STAGE_DIR/PROJ.json"
SINK_AI_STAGE_NAME="$SINK_AI_STAGE_DEST.tmp.PREDICTED"
SINK_AI_STAGE_OVERRIDE="mktemp() { printf '%s\\n' '$SINK_AI_STAGE_NAME'; }"

SINK_AI_STAGE_ATTACKER="$SINK_AI_STAGE_DIR/attacker-target.txt"
printf 'ATTACKER-CONTENT' >"$SINK_AI_STAGE_ATTACKER"
SINK_AI_STAGE_ATTACKER_GOLDEN="$WORK/install-ai-attacker-golden"
cp "$SINK_AI_STAGE_ATTACKER" "$SINK_AI_STAGE_ATTACKER_GOLDEN"
ln -s "$SINK_AI_STAGE_ATTACKER" "$SINK_AI_STAGE_NAME"

# The fixture's own shape IS half the claim, on the same reasoning the download
# sink's symlink case asserts its fixture: if the planted entry were not really
# a symlink to the attacker's file, the bytes compare below would be measuring
# nothing.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_AI_STAGE_NAME" ] && [ -f "$SINK_AI_STAGE_NAME" ]; then
	pass "sink: staging-name fixture — the predicted staging name really is a symlink, and it really resolves to the attacker's file"
else
	fail "sink: staging-name fixture — the predicted staging name really is a symlink, and it really resolves to the attacker's file" \
		"not a symlink-to-file: $SINK_AI_STAGE_NAME"
fi

sink_install_run "$SINK_AI_STAGE_OVERRIDE" "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_STAGE_DEST"
expect_rc "sink: a symlink at the staging name -> exit 1 (the O_EXCL create refuses it)" 1
stderr_has "sink: the refusal is copy_to_new_file's, prefixed with atomic_install's own label" \
	"install $SINK_AI_STAGE_DEST: could not create '$SINK_AI_STAGE_NAME'"
stdout_not_has "sink: nothing was reported as installed" "installed:"
assert_file_bytes_identical "sink: THE ATTACKER'S TARGET IS UNTOUCHED — the config was not written through the planted symlink" \
	"$SINK_AI_STAGE_ATTACKER" "$SINK_AI_STAGE_ATTACKER_GOLDEN"
assert_path_absent "sink: the refused install created no destination config" "$SINK_AI_STAGE_DEST"

# THE CONTROL, and it is load-bearing twice over: without it an install that
# refused for ANY reason would satisfy every assertion above, and nothing would
# prove the overridden `mktemp` is the name the install actually stages into —
# the one fact the attack case rests on. Same override, same directory, with the
# planted symlink removed.
rm -f "$SINK_AI_STAGE_NAME"
sink_install_run "$SINK_AI_STAGE_OVERRIDE" "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_STAGE_DEST"
expect_rc "sink: staging control — the SAME install with no symlink planted -> exit 0" 0
stdout_has "sink: staging control — the install reported completing" "installed:$SINK_AI_STAGE_DEST"
assert_file_bytes_identical "sink: staging control — the config's exact bytes landed at the destination" \
	"$SINK_AI_STAGE_DEST" "$SINK_INSTALL_SRC"
assert_path_mode "sink: staging control — the installed config is 0600, and the mode SURVIVED the rename" \
	"$SINK_AI_STAGE_DEST" "-rw-------"
assert_path_absent "sink: staging control — the staged sibling is gone, renamed into place rather than copied" \
	"$SINK_AI_STAGE_NAME"

section "jira.sh — atomic_install: a SYMLINK-TO-A-DIRECTORY at the DESTINATION — the documented, ACCEPTED residual"

# THIS CASE ASSERTS A WEAKNESS, DELIBERATELY, AND THAT IS WHY IT IS WORDED THIS
# WAY. `mv -f` STATS its destination, so a symlink to a directory raced in at
# DEST makes it deposit the staged copy INSIDE that directory and exit 0 — where
# the download install's `ln -n` refuses the same shape outright. runtime.sh
# discloses this as an accepted residual rather than closing it: the only fix is
# an unlink-then-link, which opens a window where DEST does not exist at all,
# and that atomicity is what this function is named for (a concurrent reader
# must never see a half-written config, and a MISSING config reads as "no
# config", never an error).
#
# SO THE ASSERTIONS BELOW PIN TODAY'S BEHAVIOR IN BOTH DIRECTIONS: the operation
# is REFUSED (exit 1, no false success), AND the deposited copy is really in the
# attacker's directory. If anyone ever revisits the trade-off, the deposit
# assertions go RED and this section is the signal that the residual moved —
# which is the whole reason they are here rather than a comment saying "we
# accept this". A section that asserted only the refusal would pass either way
# and disclose nothing.
#
# NO OVERRIDE IS NEEDED: the deposited entry is found by scanning the attacker's
# directory, so the real `mktemp -u` name is never predicted — only its documented
# SHAPE (`<destination basename>.tmp.*`) is asserted, which is what makes the
# claim readable without pinning a random suffix.
SINK_AI_SYMDIR_PARENT="$WORK/install-ai-symdir"
mkdir -p "$SINK_AI_SYMDIR_PARENT"
SINK_AI_SYMDIR_ATTACKER="$SINK_AI_SYMDIR_PARENT/attacker-dir"
mkdir -p "$SINK_AI_SYMDIR_ATTACKER"
SINK_AI_SYMDIR_DEST="$SINK_AI_SYMDIR_PARENT/PROJ.json"
ln -s "$SINK_AI_SYMDIR_ATTACKER" "$SINK_AI_SYMDIR_DEST"

TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_AI_SYMDIR_DEST" ] && [ -d "$SINK_AI_SYMDIR_DEST" ]; then
	pass "sink: symlink-to-directory fixture — the destination name really is a symlink, and it really resolves to a directory"
else
	fail "sink: symlink-to-directory fixture — the destination name really is a symlink, and it really resolves to a directory" \
		"not a symlink-to-directory: $SINK_AI_SYMDIR_DEST"
fi
assert_dir_entry_count "sink: symlink-to-directory fixture — the attacker's directory starts EMPTY" \
	"$SINK_AI_SYMDIR_ATTACKER" 0

# assert_sole_entry_is NAME DIR EXPECTED_PREFIX GOLDEN — DIR holds exactly one
# entry, its basename begins EXPECTED_PREFIX, and its bytes are GOLDEN's. Three
# claims in one helper because they are one observation of one entry, and
# splitting them would mean three separate scans that could each find a
# different one.
assert_sole_entry_is() {
	TESTS_RUN=$((TESTS_RUN + 1))
	asei_found=""
	asei_count=0
	for asei_entry in "$2"/* "$2"/.*; do
		case ${asei_entry##*/} in .|..) continue ;; esac
		[ -e "$asei_entry" ] || [ -L "$asei_entry" ] || continue
		asei_count=$((asei_count + 1))
		asei_found=$asei_entry
	done
	if [ "$asei_count" -ne 1 ]; then
		fail "$1" "expected exactly ONE entry in $2, found $asei_count"
		return 0
	fi
	asei_name_matches=0
	case ${asei_found##*/} in "$3"*) asei_name_matches=1 ;; esac
	if [ "$asei_name_matches" -ne 1 ]; then
		fail "$1" "the sole entry's name does not begin '$3': $asei_found"
	elif ! cmp -s "$asei_found" "$4"; then
		fail "$1" "the sole entry's bytes are not the expected payload: $asei_found"
	else
		pass "$1"
	fi
}

sink_install_run "" "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_SYMDIR_DEST"
expect_rc "sink: a symlink-to-a-directory at the destination -> exit 1 (no false success)" 1
stderr_has "sink: the refusal is assert_install_landed's symlink branch, which deliberately removes nothing" \
	"install $SINK_AI_SYMDIR_DEST: a symlink replaced the destination while the file was being installed — refusing to follow it, and deliberately removing nothing"
# The real-directory branch must NOT be what fired: it runs an `rm` through the
# destination path, and `-L` is tested first precisely so that `rm` can never
# resolve through an attacker's symlink. Only this absence separates the two.
stderr_not_has "sink: the REAL-directory branch never ran (its \`rm\` must never resolve through a symlink)" \
	"the destination became a directory while the file was being installed"
stdout_not_has "sink: nothing was reported as installed" "installed:"
# THE RESIDUAL, asserted as the CURRENT behavior. Red here means the trade-off
# changed, not that the engine broke — see this section's header.
assert_sole_entry_is "sink: THE ACCEPTED RESIDUAL — \`mv -f\` deposited the staged config INSIDE the attacker's directory before the refusal caught it" \
	"$SINK_AI_SYMDIR_ATTACKER" "PROJ.json.tmp." "$SINK_INSTALL_SRC"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_AI_SYMDIR_DEST" ]; then
	pass "sink: the symlink at the destination was left exactly as it was found (not unlinked, not replaced)"
else
	fail "sink: the symlink at the destination was left exactly as it was found (not unlinked, not replaced)" \
		"the symlink is gone: $SINK_AI_SYMDIR_DEST"
fi

section "jira.sh — atomic_install: a REAL DIRECTORY raced in at the destination is caught after the rename, which is withdrawn from it"

# THE OTHER SHAPE `mv -f` CONCEDES, and the one the symlink branch above must not
# be confused with: against a REAL directory at DEST the rename moves the staged
# copy INSIDE it and exits 0, so the install genuinely succeeds and the only
# place left to catch it is immediately afterwards. This is the same residual the
# download install has, and the same branch of the same shared verification —
# but reached through `mv -f` rather than `ln -n`, and with the STRAY NOUN this
# caller passes rather than that one's.
#
# THREE THINGS SEPARATE IT FROM THE SYMLINK CASE, and all three are asserted: its
# OWN diagnostic, the ABSENCE of the symlink branch's (proving the rename really
# did succeed first), and the directory being EMPTY again (proving the withdrawal
# happened, not merely that the run reported an error). Delete the check and the
# run exits 0, reports an install, and leaves the config sitting in the
# attacker's directory — that is the exploit, and the entry count is what sees it.
SINK_AI_REALDIR_PARENT="$WORK/install-ai-realdir"
mkdir -p "$SINK_AI_REALDIR_PARENT"
SINK_AI_REALDIR_DEST="$SINK_AI_REALDIR_PARENT/PROJ.json"
mkdir -p "$SINK_AI_REALDIR_DEST"

TESTS_RUN=$((TESTS_RUN + 1))
if [ -d "$SINK_AI_REALDIR_DEST" ] && [ ! -L "$SINK_AI_REALDIR_DEST" ]; then
	pass "sink: real-directory fixture — the destination name is a REAL directory, not a symlink to one"
else
	fail "sink: real-directory fixture — the destination name is a REAL directory, not a symlink to one" \
		"not a real directory: $SINK_AI_REALDIR_DEST"
fi
assert_dir_entry_count "sink: real-directory fixture — the destination directory starts EMPTY" \
	"$SINK_AI_REALDIR_DEST" 0

sink_install_run "" "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_REALDIR_DEST"
expect_rc "sink: a real directory at the destination -> exit 1 (the post-install verification refuses it)" 1
# The NOUN is asserted with the message, because it is the one argument that
# differs between this caller and the download install's: a copy-paste slip that
# passed `link` here would leave a config install reporting a removed "link".
stderr_has "sink: the refusal is the real-directory branch's own, and it names the stray as a FILE (this caller's noun, not the hard-linked install's)" \
	"install $SINK_AI_REALDIR_DEST: the destination became a directory while the file was being installed — the misplaced file inside it was removed (best effort), and nothing was installed at the destination itself"
stderr_not_has "sink: the SYMLINK branch never ran (the destination is a real directory)" \
	"a symlink replaced the destination"
stderr_not_has "sink: the staging create and the rename both SUCCEEDED — neither reported a failure" \
	"could not move the staged copy into place"
stdout_not_has "sink: nothing was reported as installed" "installed:"
assert_dir_entry_count "sink: THE MISPLACED CONFIG WAS WITHDRAWN — the directory is empty again, with nothing left in it" \
	"$SINK_AI_REALDIR_DEST" 0
TESTS_RUN=$((TESTS_RUN + 1))
if [ -d "$SINK_AI_REALDIR_DEST" ]; then
	pass "sink: the destination directory itself still exists (only the misplaced entry was removed)"
else
	fail "sink: the destination directory itself still exists (only the misplaced entry was removed)" \
		"the directory was destroyed: $SINK_AI_REALDIR_DEST"
fi

section "jira.sh — atomic_install: a failed rename withdraws the staged sibling; a rename that lands NOTHING is refused, not reported"

# TWO BRANCHES NO FIXTURE CAN REACH, because on a directory this engine is
# allowed to install into, `mv` does not fail and does not lie — so `mv` itself
# is overridden, the narrowest swap that reaches each one.
#
# (a) THE RENAME FAILS. What the guard buys is this engine's own diagnostic and
# exit code in place of mv's raw message, plus the WITHDRAWAL: without it a
# refused install leaves a `.tmp.` entry in the caller's config directory, litter
# a later reader could mistake for a real config.
SINK_AI_MVFAIL_DIR="$WORK/install-ai-mvfail"
mkdir -p "$SINK_AI_MVFAIL_DIR"
SINK_AI_MVFAIL_DEST="$SINK_AI_MVFAIL_DIR/PROJ.json"

sink_install_run 'mv() { return 1; }' "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_MVFAIL_DEST"
expect_rc "sink: a failed rename -> exit 1 (never a silent success)" 1
stderr_has "sink: the failed rename reports through error(), naming the install it belongs to" \
	"install $SINK_AI_MVFAIL_DEST: could not move the staged copy into place"
stdout_not_has "sink: the failed rename never reported installing" "installed:"
assert_path_absent "sink: the failed rename left no destination config" "$SINK_AI_MVFAIL_DEST"
assert_no_dest_siblings "sink: THE STAGED SIBLING WAS WITHDRAWN — no \`.tmp.\` entry survived the refused install" \
	"$SINK_AI_MVFAIL_DEST"

# (b) THE RENAME REPORTS SUCCESS AND LANDS NOTHING — the generic third branch of
# assert_install_landed, which is exactly the state that cannot be
# characterized: the name was unlinked outright, or holds something that is not a
# regular file. It must refuse rather than report a completed install, and it
# must remove NOTHING, for the symlink branch's reason (whatever is at the path
# now was not created by this engine). The staging name is pinned by the same
# `mktemp` override the attack case uses, so the surviving staged entry can be
# asserted by name rather than inferred.
SINK_AI_MVNOOP_DIR="$WORK/install-ai-mvnoop"
mkdir -p "$SINK_AI_MVNOOP_DIR"
SINK_AI_MVNOOP_DEST="$SINK_AI_MVNOOP_DIR/PROJ.json"
SINK_AI_MVNOOP_STAGE="$SINK_AI_MVNOOP_DEST.tmp.PREDICTED"

sink_install_run "mv() { return 0; }
mktemp() { printf '%s\\n' '$SINK_AI_MVNOOP_STAGE'; }" "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_MVNOOP_DEST"
expect_rc "sink: a rename that reports success and lands nothing -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal is the generic branch's own — the destination is not the regular file the install created" \
	"install $SINK_AI_MVNOOP_DEST: the destination is not the regular file the install created"
stdout_not_has "sink: nothing was reported as installed" "installed:"
assert_path_absent "sink: no destination config exists (the rename really did nothing)" "$SINK_AI_MVNOOP_DEST"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -f "$SINK_AI_MVNOOP_STAGE" ]; then
	pass "sink: the staged copy SURVIVES — this branch deliberately removes nothing, since it cannot know what is at the path"
else
	fail "sink: the staged copy SURVIVES — this branch deliberately removes nothing, since it cannot know what is at the path" \
		"the staged copy is gone: $SINK_AI_MVNOOP_STAGE"
fi
rm -f "$SINK_AI_MVNOOP_STAGE"

section "jira.sh — atomic_install: an unusable \`mktemp\` fails CLOSED with a named diagnostic, not a raw tool error"

# `mktemp -u` IS A NEW HARD DEPENDENCY of this install sequence — it is what
# mints a staging name while CREATING NOTHING, so the create and the write can be
# one O_EXCL operation. GNU, BSD/macOS, busybox and toybox all support it, and
# this suite's own toolboxes symlink the real `mktemp`, so the flag is exercised
# by every `discover --write` case in this file. What has no other coverage is
# the implementation that does NOT support it: the guard must name the dependency
# instead of letting a raw "illegal option" reach the caller with the install
# half-attempted.
SINK_AI_NOMKTEMP_DIR="$WORK/install-ai-nomktemp"
mkdir -p "$SINK_AI_NOMKTEMP_DIR"
SINK_AI_NOMKTEMP_DEST="$SINK_AI_NOMKTEMP_DIR/PROJ.json"

sink_install_run 'mktemp() { return 1; }' "$SINK_AI_CASE" "$SINK_INSTALL_SRC" "$SINK_AI_NOMKTEMP_DEST"
expect_rc "sink: a \`mktemp\` that cannot mint a staging name -> exit 1 (fail closed)" 1
stderr_has "sink: the diagnostic names the dependency AND the flag, rather than surfacing mktemp's own message" \
	"install $SINK_AI_NOMKTEMP_DEST: could not derive a staging name beside the destination (is \`mktemp\` on \$PATH, and does it support \`-u\`?)"
stdout_not_has "sink: nothing was reported as installed" "installed:"
assert_path_absent "sink: nothing was installed at the destination" "$SINK_AI_NOMKTEMP_DEST"
assert_no_dest_siblings "sink: nothing was left beside the destination either" "$SINK_AI_NOMKTEMP_DEST"

section "jira.sh — install_new_file: the CREATE path's install REFUSES an existing destination instead of replacing it"

# THE SECOND INSTALLER, AND THE ONE THAT PAYS NEITHER OF atomic_install's TWO
# RENAME RESIDUALS. save_discovered_config's create path decides "no config is
# there" with a `[ ! -f ]` and installs some seven HTTP round-trips later, so
# `mv -f` would silently overwrite anything that appeared in between — human
# curation, with no backup taken, since the create path backs nothing up. `ln -n`
# turns that window into a refusal: link(2) will not follow or replace an existing
# destination name, so the clobber and the symlink-to-a-directory DEPOSIT are both
# refused outright rather than caught afterwards.
#
# THE SECTIONS ABOVE CANNOT STAND IN FOR THIS ONE. They drive atomic_install,
# whose `mv -f` genuinely concedes both shapes (the symlink-to-a-directory section
# ASSERTS that deposit as an accepted residual). Route the create path back
# through atomic_install "for symmetry" and every arm above stays green while the
# two arms below go red — which is the whole reason they are separate functions.
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_INF_CASE='install_new_file "$1" "$2"
printf "installed:%s\n" "$2"'

# (a) THE DESTINATION DIRECTORY IS GATED HERE TOO, inherited from the shared
# stage_install_copy rather than repeated at the call site. The atomic_install
# arm above cannot say this: the gate lives in the shared prefix, so only driving
# BOTH installers proves neither one bypasses it.
SINK_INF_UNSAFE_DIR="$WORK/install-inf-unsafe"
mkdir -p "$SINK_INF_UNSAFE_DIR"
chmod 0777 "$SINK_INF_UNSAFE_DIR"
SINK_INF_UNSAFE_DEST="$SINK_INF_UNSAFE_DIR/PROJ.json"

sink_install_run "" "$SINK_INF_CASE" "$SINK_INSTALL_SRC" "$SINK_INF_UNSAFE_DEST"
expect_rc "sink: install_new_file into a world-writable directory -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal is the project-config directory gate's own, reached through stage_install_copy" \
	"the $SINK_INSTALL_NOUN '$SINK_INF_UNSAFE_DIR' $SINK_INSTALL_SHARED_TAIL"
stdout_not_has "sink: the refused install never reported installing" "installed:"
assert_dir_entry_count "sink: the refused install left the directory EMPTY — the gate precedes the staging here as well" \
	"$SINK_INF_UNSAFE_DIR" 0

# (b) THE HAPPY PATH, without which every refusal below is satisfied by an
# installer that never installs anything. It carries three claims none of the
# refusals can: the bytes, the 0600 (`copy_to_new_file`'s `umask 077`, which
# survives the hard link because the destination and the staged copy ARE one
# inode), and the DROPPED STAGING LINK — `ln` leaves DEST as a second link to the
# staged copy, so an installer that forgot to withdraw the first would leave a
# permanent `.tmp.` sibling rather than a transient one.
SINK_INF_OK_DIR="$WORK/install-inf-ok"
mkdir -p "$SINK_INF_OK_DIR"
SINK_INF_OK_DEST="$SINK_INF_OK_DIR/PROJ.json"

sink_install_run "" "$SINK_INF_CASE" "$SINK_INSTALL_SRC" "$SINK_INF_OK_DEST"
expect_rc "sink: install_new_file onto a FRESH destination -> exit 0" 0
stdout_has "sink: the create install reported completing" "installed:$SINK_INF_OK_DEST"
assert_file_bytes_identical "sink: the created config holds the source's exact bytes" \
	"$SINK_INF_OK_DEST" "$SINK_INSTALL_SRC"
assert_path_mode "sink: the created config is exactly 0600 — the mode survives the hard link, which carries no mode of its own" \
	"$SINK_INF_OK_DEST" "-rw-------"
assert_no_dest_siblings "sink: THE STAGING LINK WAS DROPPED — the caller is left a single-link file, not one with a \`.tmp.\` sibling beside it" \
	"$SINK_INF_OK_DEST"
assert_dir_entry_count "sink: the destination directory holds exactly ONE entry — the installed config and nothing else" \
	"$SINK_INF_OK_DIR" 1

# (c) AN EXISTING REGULAR FILE AT THE DESTINATION — THE CLOBBER THIS FUNCTION
# EXISTS TO REFUSE. Under atomic_install's `mv -f` this same call overwrites the
# file and exits 0 with no backup anywhere, which on the create path means
# destroying exactly the curation save_discovered_config's contract promises never
# to touch. The bytes-identical assertion is the one that sees it: an exit-status
# assertion alone is satisfied by a refusal that overwrote first.
SINK_INF_EXIST_DIR="$WORK/install-inf-existing"
mkdir -p "$SINK_INF_EXIST_DIR"
SINK_INF_EXIST_DEST="$SINK_INF_EXIST_DIR/PROJ.json"
printf '{"custom_fields":{"Curated Field":"customfield_90210"}}' >"$SINK_INF_EXIST_DEST"
SINK_INF_EXIST_GOLDEN="$WORK/install-inf-existing-golden.json"
cp "$SINK_INF_EXIST_DEST" "$SINK_INF_EXIST_GOLDEN"

sink_install_run "" "$SINK_INF_CASE" "$SINK_INSTALL_SRC" "$SINK_INF_EXIST_DEST"
expect_rc "sink: install_new_file onto an EXISTING file -> exit 1 (fail closed)" 1
stderr_has "sink: the refusal is the \`ln\` guard's own, and it names the existing-destination cause FIRST" \
	"install $SINK_INF_EXIST_DEST: could not link the staged copy into place — the destination must not already exist, and an entry at that name is refused rather than replaced"
stdout_not_has "sink: the refused create install never reported installing" "installed:"
assert_file_bytes_identical "sink: THE EXISTING CONFIG WAS NOT CLOBBERED — byte-for-byte what it was, which \`mv -f\` would have destroyed silently" \
	"$SINK_INF_EXIST_DEST" "$SINK_INF_EXIST_GOLDEN"
assert_no_dest_siblings "sink: the staged copy was WITHDRAWN on the refusal — no \`.tmp.\` entry survived it" \
	"$SINK_INF_EXIST_DEST"

# (d) A SYMLINK-TO-A-DIRECTORY AT THE DESTINATION — THE RESIDUAL atomic_install
# DOCUMENTS AND THIS PATH DOES NOT CONCEDE. `mv -f` STATS its destination and
# reads this shape as "move INTO that directory", depositing the staged config in
# the attacker's directory on every platform (the atomic_install section above
# asserts exactly that deposit, deliberately). `ln -n` refuses the name instead,
# so the ZERO-ENTRY count in the attacker's directory is this arm's whole point —
# swap the installer back and that count becomes 1.
SINK_INF_SYMDIR_PARENT="$WORK/install-inf-symdir"
mkdir -p "$SINK_INF_SYMDIR_PARENT"
SINK_INF_SYMDIR_ATTACKER="$SINK_INF_SYMDIR_PARENT/attacker-dir"
mkdir -p "$SINK_INF_SYMDIR_ATTACKER"
SINK_INF_SYMDIR_DEST="$SINK_INF_SYMDIR_PARENT/PROJ.json"
ln -s "$SINK_INF_SYMDIR_ATTACKER" "$SINK_INF_SYMDIR_DEST"

# The fixture's own shape IS half the claim, the same reasoning the atomic_install
# residual section applies to its own: a planted entry that was not really a
# symlink-to-a-directory would make the entry count below measure nothing.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_INF_SYMDIR_DEST" ] && [ -d "$SINK_INF_SYMDIR_DEST" ]; then
	pass "sink: create-path symlink-to-directory fixture — the destination name really is a symlink, and it really resolves to a directory"
else
	fail "sink: create-path symlink-to-directory fixture — the destination name really is a symlink, and it really resolves to a directory" \
		"not a symlink-to-directory: $SINK_INF_SYMDIR_DEST"
fi
assert_dir_entry_count "sink: create-path symlink-to-directory fixture — the attacker's directory starts EMPTY" \
	"$SINK_INF_SYMDIR_ATTACKER" 0

sink_install_run "" "$SINK_INF_CASE" "$SINK_INSTALL_SRC" "$SINK_INF_SYMDIR_DEST"
expect_rc "sink: install_new_file onto a SYMLINK-TO-A-DIRECTORY -> exit 1 (\`ln -n\` refuses the name)" 1
stderr_has "sink: the refusal is \`ln\`'s guard, not a post-install verification" \
	"install $SINK_INF_SYMDIR_DEST: could not link the staged copy into place"
# assert_install_landed IS NEVER REACHED, and only this absence says so: the
# install was refused BEFORE anything landed, where atomic_install's own version
# of this case is caught AFTERWARDS and can only report a deposit it cannot undo.
stderr_not_has "sink: the post-install verification never ran — nothing was installed for it to verify" \
	"a symlink replaced the destination while the file was being installed"
stdout_not_has "sink: nothing was reported as installed" "installed:"
assert_dir_entry_count "sink: NOTHING WAS DEPOSITED IN THE ATTACKER'S DIRECTORY — the residual \`mv -f\` concedes is not conceded on the create path" \
	"$SINK_INF_SYMDIR_ATTACKER" 0
assert_no_dest_siblings "sink: the staged copy was withdrawn from beside the destination too" \
	"$SINK_INF_SYMDIR_DEST"
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$SINK_INF_SYMDIR_DEST" ]; then
	pass "sink: the symlink at the destination was left exactly as it was found (not unlinked, not replaced)"
else
	fail "sink: the symlink at the destination was left exactly as it was found (not unlinked, not replaced)" \
		"the symlink is gone: $SINK_INF_SYMDIR_DEST"
fi

section "jira.sh — save_discovered_config: a symlink planted at the BACKUP name is refused too (copy_to_new_file's OTHER call site)"

# THE SAME VULNERABILITY AT THE SIBLING CALL SITE. save_discovered_config's
# timestamped backup used to be the opposite pair of the install's — `mktemp`
# CREATED the backup and `cp` then RE-OPENED it by name — which in a directory
# another local user can write is an arbitrary local file write as the invoking
# user. It now mints the name with `mktemp -u` and fills it with the SAME
# copy_to_new_file, and this is the only case that reaches that call site with
# an entry already at the name: the primitive's own section above proves the
# mechanism, not that this caller uses it.
#
# save_discovered_config IS DRIVEN DIRECTLY, which the sink driver makes possible
# because this function's inputs are the engine's plain globals rather than
# argv: $JIRA_PROJECTS_DIR, $discover_project and $OPT_FORCE, set by the case,
# plus the discovered config as its one argument. That is also what lets the
# `mktemp` override reach the BACKUP's name — from the CLI the name carries a
# random suffix by design, so nothing outside the process can plant an entry at
# it.
# shellcheck disable=SC2016  # single-quoted on purpose: $1/$2 are the CASE FILE's positional parameters (see the driver's note), not this harness's
SINK_SDC_CASE='JIRA_PROJECTS_DIR=$1
discover_project=PROJ
OPT_FORCE=1
save_discovered_config "$2"
printf "saved\n"'

SINK_SDC_DIR="$WORK/install-sdc-backup"
mkdir -p "$SINK_SDC_DIR"
SINK_SDC_CONFIG="$SINK_SDC_DIR/PROJ.json"
printf '{"custom_fields":{"Legacy Field":"customfield_31337"}}' >"$SINK_SDC_CONFIG"
SINK_SDC_CONFIG_GOLDEN="$WORK/install-sdc-config-golden.json"
cp "$SINK_SDC_CONFIG" "$SINK_SDC_CONFIG_GOLDEN"

SINK_SDC_BACKUP_NAME="$SINK_SDC_CONFIG.bak-PREDICTED"
SINK_SDC_STAGE_NAME="$SINK_SDC_CONFIG.tmp.PREDICTED"
# THE OVERRIDE ANSWERS BY TEMPLATE, because this one function serves BOTH of the
# engine's name-minting sites and the control below reaches both: the backup's
# `mktemp -u "<config>.bak-<UTC>.XXXXXX"` and then atomic_install's
# `mktemp -u "<config>.tmp.XXXXXX"`. A single fixed answer hands the install the
# name the backup has just occupied, and the control fails on a collision the
# engine never had. The branch decides which FIXTURE NAME to hand back, never
# which assertion runs.
SINK_SDC_OVERRIDE="mktemp() {
	case \$2 in
		*.bak-*) printf '%s\\n' '$SINK_SDC_BACKUP_NAME' ;;
		*)       printf '%s\\n' '$SINK_SDC_STAGE_NAME' ;;
	esac
}"
SINK_SDC_ATTACKER="$SINK_SDC_DIR/attacker-target.txt"
printf 'ATTACKER-CONTENT' >"$SINK_SDC_ATTACKER"
SINK_SDC_ATTACKER_GOLDEN="$WORK/install-sdc-attacker-golden"
cp "$SINK_SDC_ATTACKER" "$SINK_SDC_ATTACKER_GOLDEN"
ln -s "$SINK_SDC_ATTACKER" "$SINK_SDC_BACKUP_NAME"

sink_install_run "$SINK_SDC_OVERRIDE" "$SINK_SDC_CASE" "$SINK_SDC_DIR" "$SINK_INSTALL_SRC"
expect_rc "sink: a symlink at the backup name -> exit 1 (the O_EXCL create refuses it)" 1
stderr_has "sink: the refusal carries the BACKUP's own label, not the install's" \
	"back up the existing project config: could not create '$SINK_SDC_BACKUP_NAME'"
stdout_not_has "sink: nothing was reported as saved" "saved"
assert_file_bytes_identical "sink: THE ATTACKER'S TARGET IS UNTOUCHED — the existing config was not copied through the planted symlink" \
	"$SINK_SDC_ATTACKER" "$SINK_SDC_ATTACKER_GOLDEN"
assert_file_bytes_identical "sink: the existing config is byte-for-byte untouched — the refusal precedes the install" \
	"$SINK_SDC_CONFIG" "$SINK_SDC_CONFIG_GOLDEN"

# THE CONTROL, load-bearing for the same two reasons the install's own is: it
# proves the overridden name really is the one the backup uses, and it rules out
# a save that refused for some unrelated reason. `--force` is on (the case sets
# OPT_FORCE=1), so the replace branch runs with no merge and no jq round-trip.
rm -f "$SINK_SDC_BACKUP_NAME"
sink_install_run "$SINK_SDC_OVERRIDE" "$SINK_SDC_CASE" "$SINK_SDC_DIR" "$SINK_INSTALL_SRC"
expect_rc "sink: backup control — the SAME save with no symlink planted -> exit 0" 0
stdout_has "sink: backup control — the save reported completing" "saved"
stdout_has "sink: backup control — the machine line names the (replaced) outcome and the backup it took" \
	"JIRA_DISCOVERED=PROJ -> $SINK_SDC_CONFIG (replaced; backup $SINK_SDC_BACKUP_NAME)"
assert_file_bytes_identical "sink: backup control — the backup holds the PREVIOUS config's exact bytes" \
	"$SINK_SDC_BACKUP_NAME" "$SINK_SDC_CONFIG_GOLDEN"
assert_file_bytes_identical "sink: backup control — the new config was installed over the old one" \
	"$SINK_SDC_CONFIG" "$SINK_INSTALL_SRC"
assert_path_mode "sink: backup control — the backup is 0600, the same O_EXCL primitive's \`umask 077\`" \
	"$SINK_SDC_BACKUP_NAME" "-rw-------"
assert_path_absent "sink: backup control — the install's own staged sibling is gone, renamed into place" \
	"$SINK_SDC_STAGE_NAME"

section "jira.sh — discover --write: the \$JIRA_PROJECTS_DIR gate, end to end (and it does NOT refuse an ordinary projects dir)"

# THE CLI HALF, which the sink cases above deliberately cannot make: that the
# gate is WIRED INTO the one command that installs a config, that an ordinary
# projects directory still passes it, and that the two writes
# save_discovered_config performs (its timestamped backup, and the install
# itself) land at the mode this engine intends.

# (a) THE ORDINARY SHAPE — a projects dir the engine creates itself. Every other
# `discover --write` case in this file depends on this verdict silently; this one
# states it, and adds the two claims none of them makes: the DIRECTORY's own mode
# and the installed config's.
#
# THE DIRECTORY'S 0700 IS A GATE OF ITS OWN MAKING. save_discovered_config
# creates it under `umask 077` rather than the caller's mask because a directory
# created 0775 under a umask of 002 — the default on several Linux distributions
# — is one assert_safe_install_dir would then REFUSE, a refusal the engine would
# have manufactured for itself. Under this run's pinned 022 a bare `mkdir -p`
# yields 0755, which the gate accepts, so the mode assertion is the only thing
# that can see that umask go missing.
INSTALL_CLI_FRESH_DIR="$WORK/install-cli-fresh"   # deliberately NOT pre-created
reset_curl_stub
queue_discover_responses
umask_run 022 full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INSTALL_CLI_FRESH_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write into a fresh projects dir -> exit 0 (the new gate does not refuse an ordinary one)" 0
stdout_has "discover --write: the machine line names the (created) outcome" \
	"JIRA_DISCOVERED=PROJ -> $INSTALL_CLI_FRESH_DIR/PROJ.json (created)"
stderr_not_has "discover --write: no project-config directory refusal fired" "$SINK_INSTALL_SHARED_TAIL"
assert_path_mode "discover --write: the projects dir the engine CREATED is 0700 — its own \`umask 077\`, not the caller's 022" \
	"$INSTALL_CLI_FRESH_DIR" "drwx------"
assert_path_mode "discover --write: the installed config is exactly 0600 — readable by nobody but the caller" \
	"$INSTALL_CLI_FRESH_DIR/PROJ.json" "-rw-------"
assert_no_dest_siblings "discover --write: no \`.tmp.\` staging entry survived the install" \
	"$INSTALL_CLI_FRESH_DIR/PROJ.json"

# (b) THE REPLACE PATH, which is the one that also writes a BACKUP — the second
# copy_to_new_file caller, and the only place its mode can be observed from the
# CLI. A second `--write` over the config created in (a) takes the merge branch.
reset_curl_stub
queue_discover_responses
umask_run 022 full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INSTALL_CLI_FRESH_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write over an EXISTING config -> exit 0" 0
stdout_has "discover --write: the machine line names the (merged) outcome + backup" \
	"JIRA_DISCOVERED=PROJ -> $INSTALL_CLI_FRESH_DIR/PROJ.json (merged; backup "
assert_path_mode "discover --write: the REPLACED config is still exactly 0600 (the mode survives the rename, every time)" \
	"$INSTALL_CLI_FRESH_DIR/PROJ.json" "-rw-------"
INSTALL_CLI_BACKUP=$(find "$INSTALL_CLI_FRESH_DIR" -name 'PROJ.json.bak-*' 2>/dev/null | head -1)
assert_path_mode "discover --write: the timestamped BACKUP is 0600 too — it goes through the same O_EXCL primitive as the install" \
	"$INSTALL_CLI_BACKUP" "-rw-------"

# (c) AN UNSAFE PROJECTS DIR THAT ALREADY HOLDS A CONFIG. This is the case that
# pins save_discovered_config's OWN gate call, the one atomic_install cannot
# stand in for: the backup is written BEFORE any atomic_install runs, so with
# that call deleted this run still refuses — but only after having copied the
# config into a directory another local user can read and replace. The
# no-backup-written assertion is the only thing that sees it.
INSTALL_CLI_UNSAFE_DIR="$WORK/install-cli-unsafe"
mkdir -p "$INSTALL_CLI_UNSAFE_DIR"
write_curated_config "$INSTALL_CLI_UNSAFE_DIR/PROJ.json"
chmod 0777 "$INSTALL_CLI_UNSAFE_DIR"
INSTALL_CLI_UNSAFE_GOLDEN="$WORK/install-cli-unsafe-golden.json"
cp "$INSTALL_CLI_UNSAFE_DIR/PROJ.json" "$INSTALL_CLI_UNSAFE_GOLDEN"

reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INSTALL_CLI_UNSAFE_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write into a world-writable projects dir -> exit 1 (fail closed)" 1
stderr_has "discover --write: the refusal names the projects dir, the reason and the \`chmod\` remedy" \
	"the $SINK_INSTALL_NOUN '$INSTALL_CLI_UNSAFE_DIR' $SINK_INSTALL_SHARED_TAIL"
stdout_not_has "discover --write: no machine line claimed an outcome" "JIRA_DISCOVERED="
assert_dir_entry_count "discover --write: NO BACKUP AND NO STAGING ENTRY was written — the gate precedes the backup, so only the pre-existing config is there" \
	"$INSTALL_CLI_UNSAFE_DIR" 1
assert_file_bytes_identical "discover --write: the existing config is byte-for-byte untouched" \
	"$INSTALL_CLI_UNSAFE_DIR/PROJ.json" "$INSTALL_CLI_UNSAFE_GOLDEN"
# The refusal is LOCAL and deliberately late: discover is a read command, so the
# seven introspection GETs have all happened by the time the config is saved.
# Stated rather than left ambiguous — a future move of the gate to pre-flight
# would change this number, and that should be a visible decision.
equals "discover --write: the refusal happened AFTER the seven read GETs (the gate guards the local write, not the reads)" \
	"$(call_count)" "7"

# (d) THE SAME UNSAFE DIR WITH NO CONFIG IN IT, which is the arm that pins the
# CREATE path's own gate from the CLI: with no existing file there is no backup
# and no merge, so save_discovered_config goes straight to install_new_file — a
# different installer from (c)'s, reaching the same gate through the
# stage_install_copy prefix they share.
INSTALL_CLI_UNSAFE_EMPTY="$WORK/install-cli-unsafe-empty"
mkdir -p "$INSTALL_CLI_UNSAFE_EMPTY"
chmod 0777 "$INSTALL_CLI_UNSAFE_EMPTY"

reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INSTALL_CLI_UNSAFE_EMPTY" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write into an EMPTY world-writable projects dir -> exit 1 (fail closed)" 1
stderr_has "discover --write: the same refusal fires on the create path" \
	"the $SINK_INSTALL_NOUN '$INSTALL_CLI_UNSAFE_EMPTY' $SINK_INSTALL_SHARED_TAIL"
stdout_not_has "discover --write: no machine line claimed a created config" "JIRA_DISCOVERED="
assert_dir_entry_count "discover --write: the unsafe directory is still EMPTY — no config, no staging entry" \
	"$INSTALL_CLI_UNSAFE_EMPTY" 0

section "jira.sh — discover --write: a SYMLINK-TO-A-DIRECTORY at a fresh config's name deposits NOTHING (the create path's \`ln -n\`)"

# THE VULNERABILITY THE CREATE PATH WAS MOVED OFF `mv -f` TO CLOSE, reconstructed
# END TO END rather than at the primitive. `mv -f` STATS its destination, so this
# shape makes it deposit the whole discovered config INSIDE the attacker's
# directory and exit 0 — the deposit the atomic_install section above asserts as
# an accepted residual, which on the REPLACE paths buys atomicity and on the create
# path bought nothing at all (there is nothing to replace). `install_new_file`'s
# `ln -n` refuses the name instead.
#
# THIS IS REACHABLE FROM THE CLI, unlike the install races above, because the
# planted entry sits at the DESTINATION — a name derived from the project key, not
# a `mktemp -u` name no test can predict. That is the same fact that makes the
# attack real: an attacker who can write the directory knows this name in advance.
#
# THE PROJECTS DIR IS 0700, deliberately, so the directory gate ACCEPTS it and the
# run reaches the install. A world-writable one would refuse earlier and prove
# nothing about the installer.
INSTALL_CLI_SYMDIR_DIR="$WORK/install-cli-symdir"
mkdir -p "$INSTALL_CLI_SYMDIR_DIR"
chmod 0700 "$INSTALL_CLI_SYMDIR_DIR"
INSTALL_CLI_SYMDIR_ATTACKER="$INSTALL_CLI_SYMDIR_DIR/attacker-dir"
mkdir -p "$INSTALL_CLI_SYMDIR_ATTACKER"
INSTALL_CLI_SYMDIR_DEST="$INSTALL_CLI_SYMDIR_DIR/PROJ.json"
ln -s "$INSTALL_CLI_SYMDIR_ATTACKER" "$INSTALL_CLI_SYMDIR_DEST"

# The fixture's own shape IS half the claim, and here it carries a second one: a
# symlink resolving to a DIRECTORY fails save_discovered_config's `[ ! -f ]` test,
# which is what routes this run down the CREATE path rather than the replace one.
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$INSTALL_CLI_SYMDIR_DEST" ] && [ -d "$INSTALL_CLI_SYMDIR_DEST" ] && [ ! -f "$INSTALL_CLI_SYMDIR_DEST" ]; then
	pass "discover --write symdir fixture — the config name is a symlink to a directory, so \`[ ! -f ]\` sends the run down the CREATE path"
else
	fail "discover --write symdir fixture — the config name is a symlink to a directory, so \`[ ! -f ]\` sends the run down the CREATE path" \
		"not a symlink-to-directory: $INSTALL_CLI_SYMDIR_DEST"
fi
assert_dir_entry_count "discover --write symdir fixture: the attacker's directory starts EMPTY" \
	"$INSTALL_CLI_SYMDIR_ATTACKER" 0

reset_curl_stub
queue_discover_responses
run full "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INSTALL_CLI_SYMDIR_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write onto a symlinked config name -> exit 1 (fail closed)" 1
stderr_has "discover --write: the refusal is the create path's \`ln\` guard, naming the existing-destination cause" \
	"install $INSTALL_CLI_SYMDIR_DEST: could not link the staged copy into place"
stdout_not_has "discover --write: no machine line claimed a created config" "JIRA_DISCOVERED="
assert_dir_entry_count "discover --write: NOTHING WAS DEPOSITED IN THE ATTACKER'S DIRECTORY — which is exactly what the old \`mv -f\` create path did deposit" \
	"$INSTALL_CLI_SYMDIR_ATTACKER" 0
assert_no_dest_siblings "discover --write: the staged copy was withdrawn from beside the destination too" \
	"$INSTALL_CLI_SYMDIR_DEST"
assert_dir_entry_count "discover --write: the projects dir holds only what it started with — the attacker's directory and the symlink, no backup and no staging entry" \
	"$INSTALL_CLI_SYMDIR_DIR" 2
TESTS_RUN=$((TESTS_RUN + 1))
if [ -L "$INSTALL_CLI_SYMDIR_DEST" ]; then
	pass "discover --write: the planted symlink was left exactly as it was found (not unlinked, not replaced)"
else
	fail "discover --write: the planted symlink was left exactly as it was found (not unlinked, not replaced)" \
		"the symlink is gone: $INSTALL_CLI_SYMDIR_DEST"
fi

section "jira.sh — discover --write: the ACL warning fires ONCE even though the projects dir is gated TWICE"

# THE MEMOIZATION'S REAL CALL PATTERN, which the sink arms above deliberately
# simulate and only this case actually performs: save_discovered_config gates
# $JIRA_PROJECTS_DIR itself (its backup writes there before any installer runs),
# and the installer gates it again through stage_install_copy. Two readings, one
# warning.
#
# THE READING LOG IS WHAT MAKES THAT DISCRIMINATING. "Exactly one warning" is
# equally true of a run that gated the directory once, so deleting either gate
# call would satisfy a warning-count assertion on its own; the `ls` stub logs
# every reading of this one directory, and the count of readings is asserted
# beside the count of warnings. See the `aclls` toolbox's own header for why the
# marker is fabricated rather than a real ACL on this platform.
mkdir -p "$ACL_LS_PROJECTS_DIR"
chmod 0700 "$ACL_LS_PROJECTS_DIR"
: >"$ACL_LS_READING_LOG"

reset_curl_stub
queue_discover_responses
umask_run 022 aclls "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$ACL_LS_PROJECTS_DIR" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write into an ACL-bearing projects dir -> exit 0 (WARNED about, never refused)" 0
stdout_has "discover --write: the machine line names the (created) outcome — the ACL did not block the install" \
	"JIRA_DISCOVERED=PROJ -> $ACL_LS_PROJECTS_DIR/PROJ.json (created)"
equals "discover --write: THE DIRECTORY WAS GATED TWICE — save_discovered_config's own call and the installer's, through stage_install_copy" \
	"$(grep -c . "$ACL_LS_READING_LOG")" "2"
assert_stderr_occurrences "discover --write: THE ACL WARNING FIRED ONCE across those two gates" \
	"carries an ACL or extended permissions" 1
stderr_has "discover --write: the warning names this directory, the wrapper's noun and the mode read" \
	"the $SINK_INSTALL_NOUN '$ACL_LS_PROJECTS_DIR' carries an ACL or extended permissions (drwx------+)"
assert_path_mode "discover --write: the config still installed at exactly 0600 (a warning is not a refusal)" \
	"$ACL_LS_PROJECTS_DIR/PROJ.json" "-rw-------"

section "jira.sh — discover --write: an implementation whose \`mktemp\` has no \`-u\` fails loud at BOTH name-minting sites"

# THE DEPENDENCY, EXERCISED FOR REAL rather than through a shell override. The
# `nomktempu` toolbox carries a `mktemp` that refuses `-u` and delegates
# everything else to the real one, so the engine's workdir and credential
# `mktemp`s still work and ONLY the two name-minting sites fail. That is what
# makes the two cases below attributable: they are the same command against the
# same toolbox, and the only thing that differs is whether a config is already
# there — which decides which site is reached FIRST.
INSTALL_NOMKTEMPU_FRESH="$WORK/install-nomktempu-fresh"
reset_curl_stub
queue_discover_responses
run nomktempu "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INSTALL_NOMKTEMPU_FRESH" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write with no \`mktemp -u\` (fresh target) -> exit 1" 1
stderr_has "no \`mktemp -u\` (fresh target): the CREATE path's staging site (install_new_file's, through the shared stage_install_copy) is the one that fails, and it names the flag" \
	"could not derive a staging name beside the destination (is \`mktemp\` on \$PATH, and does it support \`-u\`?)"
stdout_not_has "no \`mktemp -u\` (fresh target): no machine line claimed a created config" "JIRA_DISCOVERED="
assert_dir_entry_count "no \`mktemp -u\` (fresh target): the projects dir the engine created is EMPTY — nothing was installed" \
	"$INSTALL_NOMKTEMPU_FRESH" 0

INSTALL_NOMKTEMPU_EXISTING="$WORK/install-nomktempu-existing"
mkdir -p "$INSTALL_NOMKTEMPU_EXISTING"
write_curated_config "$INSTALL_NOMKTEMPU_EXISTING/PROJ.json"
INSTALL_NOMKTEMPU_GOLDEN="$WORK/install-nomktempu-golden.json"
cp "$INSTALL_NOMKTEMPU_EXISTING/PROJ.json" "$INSTALL_NOMKTEMPU_GOLDEN"
reset_curl_stub
queue_discover_responses
run nomktempu "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" "JIRA_PROJECTS_DIR=$INSTALL_NOMKTEMPU_EXISTING" \
	sh "$JIRA" discover PROJ --confirmed-site foo.atlassian.net --write
expect_rc "discover --write with no \`mktemp -u\` (existing target) -> exit 1" 1
stderr_has "no \`mktemp -u\` (existing target): the BACKUP's own site fails first, with its own diagnostic" \
	"could not derive a backup name for $INSTALL_NOMKTEMPU_EXISTING/PROJ.json (is \`mktemp\` on \$PATH, and does it support \`-u\`?)"
stderr_not_has "no \`mktemp -u\` (existing target): the install's staging site was never reached — the backup precedes it" \
	"could not derive a staging name beside the destination"
assert_file_bytes_identical "no \`mktemp -u\` (existing target): the existing config is byte-for-byte untouched" \
	"$INSTALL_NOMKTEMPU_EXISTING/PROJ.json" "$INSTALL_NOMKTEMPU_GOLDEN"
assert_dir_entry_count "no \`mktemp -u\` (existing target): no backup and no staging entry was created" \
	"$INSTALL_NOMKTEMPU_EXISTING" 1

section "jira.sh — transport hardening: FLAG ORDER on all FOUR curl senders — \`-q\` literally first, and \`-K\` before \`--proto\`"

# TWO POSITIONAL RULES, ONE SECTION, because both are properties of the same argv
# and both are invisible to every presence-based assertion in this file. http.sh's
# header owns WHY each one matters (the .curlrc read `-q` suppresses; the
# left-to-right precedence that lets a later option beat an earlier one, which is
# why an externally-supplied `-K` config must be processed BEFORE the hardening
# flags it must not be able to override). What is local here:
#   * `-q` FIRST — position, not presence: a token count cannot say first-vs-fifth.
#   * `-K` BEFORE `--proto` — RELATIVE order, not presence: both flags are already
#     asserted present elsewhere in this suite, and every one of those assertions
#     stays green if they swap places. `--proto` ahead of `-K` would let a
#     directive inside $JIRA_CURL_CONFIG — or, on the media fetch, inside the
#     stdin config — replace the scheme pin, which is the whole reason the order
#     is fixed.
#
# ALL FOUR SENDERS, because both rules are per-invocation and there is no shared
# helper to place the flags for them: they are four separate literals in http.sh,
# so a new sender written without one — or an existing one whose flags get
# reordered — is a per-call regression only a per-call assertion catches. Two are
# driven through the sink driver (the two that take a method), and the other two
# are calls 1 and 2 of one real download flow: fetch_attachment_content_redirect
# resolves, download_attachment_content fetches.

reset_curl_stub
set_stub_response 1 '{}' 200
sink_case_run "$SINK_JIRA_CURL_CASE" GET "$COMMENT_WRITE_URL"
expect_rc "hardening: the jira_curl probe reached the transport -> exit 0" 0
equals "hardening: jira_curl puts -q FIRST on argv" "$(argv_call_first_token 1)" "-q"
assert_argv_flag_order "hardening: jira_curl puts -K BEFORE --proto (a config directive cannot override the scheme pin)" \
	1 -K --proto

reset_curl_stub
set_stub_response 1 '[{"id":"99"}]' 200
sink_case_run "$SINK_MULTIPART_CASE" POST "$ATTACHMENTS_URL"
expect_rc "hardening: the jira_curl_multipart probe reached the transport -> exit 0" 0
equals "hardening: jira_curl_multipart puts -q FIRST on argv" "$(argv_call_first_token 1)" "-q"
assert_argv_flag_order "hardening: jira_curl_multipart puts -K BEFORE --proto" \
	1 -K --proto

SINK_DOWNLOAD_QFLAG_DEST="$WORK/sink-download-qflag.bin"

reset_curl_stub
queue_attach_download_media_flow "$ATTACH_DL_PAYLOAD" 200
sink_download_run "" "$SINK_DOWNLOAD_ID" "$SINK_DOWNLOAD_QFLAG_DEST"
expect_rc "hardening: the download probe ran both requests -> exit 0" 0
equals "hardening: the download probe really made TWO calls (neither assertion below is vacuous)" \
	"$(call_count)" "2"
equals "hardening: fetch_attachment_content_redirect puts -q FIRST on argv (call 1)" \
	"$(argv_call_first_token 1)" "-q"
equals "hardening: download_attachment_content puts -q FIRST on argv (call 2 — the JWT-bearing media fetch)" \
	"$(argv_call_first_token 2)" "-q"
assert_argv_flag_order "hardening: fetch_attachment_content_redirect puts -K BEFORE --proto (call 1)" \
	1 -K --proto
assert_argv_flag_order "hardening: download_attachment_content puts -K BEFORE --proto (call 2 — the stdin config, whose one directive this engine writes itself)" \
	2 -K --proto

# ===========================================================================
# Split-parity assertions (P1, P2, P4, P5)
#
# These cover gaps the split of jira.sh into 45 sourced units could silently
# open and that the pre-split suite had no reason to check. They assert the
# SHAPE of the split, not any command's behavior — the rest of this file
# already covers behavior.
# ===========================================================================
section "jira.sh — split parity (dispatcher identity, temp files, unit containment)"

# P1 — a usage error must still be prefixed with the DISPATCHER's own name.
# $PROG is ${0##*/}, so if a unit were ever EXECUTED instead of sourced the
# prefix would silently become that unit's filename ("cmd-view.sh: error: ...")
# and every caller that greps this prefix would break. Anchored deliberately:
# the harness's substring stderr_has would also match a mid-line occurrence.
run nocurl sh "$JIRA" bogus
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_ERR" | grep -q '^jira\.sh: error:'; then
	pass "P1: a usage error is prefixed exactly 'jira.sh: error:'"
else
	fail "P1: a usage error is prefixed exactly 'jira.sh: error:'" "stderr was: $CUR_ERR"
fi

run nocurl "JIRA_EMAIL=a@b.com" "JIRA_TOKEN=t" \
	sh "$JIRA" view not-a-key --confirmed-site foo.atlassian.net
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s\n' "$CUR_ERR" | grep -q '^jira\.sh: error:'; then
	pass "P1: a per-command validation error is prefixed exactly 'jira.sh: error:'"
else
	fail "P1: a per-command validation error is prefixed exactly 'jira.sh: error:'" "stderr was: $CUR_ERR"
fi

# P2 — the no-arg and -h paths must leave NO temp artifacts behind. Sourcing 43
# units runs more top-level code before argv parsing than the monolith did, so a
# unit that created a workdir or a credential config at LOAD time would leak one
# on every single --help.
count_jira_tmp_artifacts() {
	find "$WORK" -maxdepth 1 \
		\( -name 'jira.work.*' -o -name 'jira.curlconfig.*' \) 2>/dev/null |
		wc -l | tr -d ' '
}

run nocurl sh "$JIRA"
TESTS_RUN=$((TESTS_RUN + 1))
p2_leaked=$(count_jira_tmp_artifacts)
if [ "$p2_leaked" -eq 0 ]; then
	pass "P2: no-args leaves zero jira.work.*/jira.curlconfig.* temp files"
else
	fail "P2: no-args leaves zero jira.work.*/jira.curlconfig.* temp files" "found $p2_leaked under $WORK"
fi

run nocurl sh "$JIRA" -h
TESTS_RUN=$((TESTS_RUN + 1))
p2_leaked=$(count_jira_tmp_artifacts)
if [ "$p2_leaked" -eq 0 ]; then
	pass "P2: -h leaves zero jira.work.*/jira.curlconfig.* temp files"
else
	fail "P2: -h leaves zero jira.work.*/jira.curlconfig.* temp files" "found $p2_leaked under $WORK"
fi

# P4 — every command's validate_<cmd>_args() must ACCEPT a valid argument set
# (returning 0) AND REJECT an invalid one (exiting 2). The split turned one
# 513-line `case` into 27 functions, and a function that falls off its end
# returning the status of its last test would abort the dispatcher under
# `set -e` before the command ever ran. Each wrapper therefore ends with an
# explicit `return 0`, and this asserts all 27 do.
#
# EVERY ACCEPT CASE IS PAIRED WITH A REJECT CASE, deliberately: an accept-only
# set would pass in full against a validator gutted to `return 0`, which is the
# exact regression this gate exists to catch. The reject half proves the guard
# still fires; the accept half proves it does not over-fire.
#
# The driver sources the units exactly as jira.sh does and REPLAYS jira.sh's own
# OPT_* initializer block rather than keeping a hand-written copy of the
# defaults, so this test cannot drift from the engine it is checking. It brackets
# that block on the STABLE MARKER COMMENTS jira.sh carries (not on the names of
# the first and last variables, which a behaviour-preserving rename or reorder
# would silently invalidate — emptying the range and turning all 26 checks into
# unbound-variable noise), and it FAILS LOUDLY if the extraction comes back
# empty.
P4_DRIVER="$WORK/validate-driver.sh"
cat >"$P4_DRIVER" <<'P4_DRIVER_EOF'
#!/usr/bin/env sh
set -eu
p4_script_dir=$1
p4_case_file=$2
SCRIPT_DIR=$p4_script_dir
LIB_DIR="$p4_script_dir/../lib"
MD_TO_ADF="$p4_script_dir/md-to-adf.sh"
PROG=jira.sh
for p4_unit in "$LIB_DIR"/*.sh; do
	. "$p4_unit"
done
p4_opts=$(mktemp "${TMPDIR:-/tmp}/jira-p4-opts.XXXXXX")
sed -n '/OPT DEFAULTS BEGIN/,/OPT DEFAULTS END/p' "$p4_script_dir/jira.sh" >"$p4_opts"
# A non-empty extraction is the driver's own precondition: if the markers ever
# stop matching, say so in one clear line instead of failing 52 times with an
# unbound-variable error that names the wrong culprit.
if [ ! -s "$p4_opts" ]; then
	printf 'P4 DRIVER: the OPT DEFAULTS marker block in jira.sh extracted EMPTY\n' >&2
	rm -f "$p4_opts"
	exit 90
fi
. "$p4_opts"
rm -f "$p4_opts"
set +e
. "$p4_case_file"
p4_rc=$?
set -e
printf '%s\n' "$p4_rc"
P4_DRIVER_EOF

P4_FILE="$WORK/p4-attachment.txt"
printf 'x\n' >"$P4_FILE"

# $P4_COVERED_LOG records every validator the cases below actually drove, so the
# completeness gate after them can compare that against the set declared in
# lib/*.sh instead of trusting this file's hand-written list.
P4_COVERED_LOG="$WORK/p4-covered.txt"
: >"$P4_COVERED_LOG"

# p4_run COMMAND ASSIGNMENTS — write one case file and run the driver on it.
p4_run() {
	p4_case_file="$WORK/p4-case.sh"
	{
		printf 'COMMAND=%s\n' "$1"
		printf '%s\n' "$2"
		printf 'validate_%s_args\n' "$(printf '%s' "$1" | tr '-' '_')"
	} >"$p4_case_file"
	p4_fn="validate_$(printf '%s' "$1" | tr '-' '_')_args"
	printf '%s\n' "$p4_fn" >>"$P4_COVERED_LOG"
	run nocurl sh "$P4_DRIVER" "$SCRIPTS_DIR" "$p4_case_file"
}

# p4_accept COMMAND ASSIGNMENTS — the wrapper must return 0 for a VALID set.
p4_accept() {
	p4_run "$1" "$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq 0 ] && [ "$CUR_OUT" = "0" ]; then
		pass "P4: $p4_fn accepts a valid argument set (\$? = 0)"
	else
		fail "P4: $p4_fn accepts a valid argument set (\$? = 0)" \
			"driver rc=$CUR_RC stdout='$CUR_OUT' stderr='$CUR_ERR'"
	fi
}

# p4_reject COMMAND ASSIGNMENTS WHY — the wrapper must exit 2 (usage error) for
# an INVALID set. The validators exit rather than return, so the exit status
# lands on the driver process itself; rc 90 is the driver's own marker-block
# precondition failure and is reported separately so it can never be mistaken
# for a validator verdict.
p4_reject() {
	p4_run "$1" "$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$CUR_RC" -eq 2 ]; then
		pass "P4: $p4_fn rejects $3 (exit 2)"
	else
		fail "P4: $p4_fn rejects $3 (exit 2)" \
			"driver rc=$CUR_RC stdout='$CUR_OUT' stderr='$CUR_ERR'"
	fi
}

p4_accept view       'TICKET_KEY=PROJ-1'
p4_reject view       ':' 'a missing ticket key'
p4_accept search     'OPT_PROJECT=PROJ'
p4_reject search     ':' 'a filterless query'
p4_accept workflow   'TICKET_KEY=PROJ-1'
p4_reject workflow   'TICKET_KEY=not-a-key' 'a malformed ticket key'
p4_accept create     'OPT_PROJECT=PROJ
OPT_TITLE="A title"'
p4_reject create     'OPT_TITLE="A title"' 'a missing --project'
p4_accept comment    "TICKET_KEY=PROJ-1
OPT_TEXT_FILE=$P4_FILE"
p4_reject comment    'TICKET_KEY=PROJ-1' 'a missing --text-file'
p4_accept comment-edit "TICKET_KEY=PROJ-1
OPT_COMMENT_ID=10501
OPT_TEXT_FILE=$P4_FILE"
p4_reject comment-edit "TICKET_KEY=PROJ-1
OPT_TEXT_FILE=$P4_FILE" 'a missing --comment-id'
# --comment-id becomes a REST URL PATH SEGMENT, so its SHAPE is validated here
# and nowhere downstream; presence alone is not enough. Both rejected forms are
# what validate_numeric_id refuses.
p4_reject comment-edit "TICKET_KEY=PROJ-1
OPT_COMMENT_ID=abc
OPT_TEXT_FILE=$P4_FILE" 'a non-numeric --comment-id'
p4_reject comment-edit "TICKET_KEY=PROJ-1
OPT_COMMENT_ID=0105
OPT_TEXT_FILE=$P4_FILE" 'a leading-zero --comment-id'
p4_reject comment-edit 'TICKET_KEY=PROJ-1
OPT_COMMENT_ID=10501' 'a missing --text-file'
p4_accept transition 'TICKET_KEY=PROJ-1
OPT_STATUS=Done'
p4_reject transition 'TICKET_KEY=PROJ-1' 'a missing --status'
# --transition-id is transition's second selector, with its own early `return 0`.
p4_accept transition 'TICKET_KEY=PROJ-1
OPT_TRANSITION_ID=31'
p4_reject transition 'TICKET_KEY=PROJ-1
OPT_TRANSITION_ID=31
OPT_STATUS=Done' 'both --status and --transition-id'
p4_accept update     'TICKET_KEY=PROJ-1
OPT_TITLE="A title"'
p4_reject update     'OPT_TITLE="A title"' 'a missing ticket key'
p4_accept link       'TICKET_KEY=PROJ-1
OPT_TO=PROJ-2
OPT_LINK_TYPE=Blocks'
p4_reject link       'TICKET_KEY=PROJ-1
OPT_TO=PROJ-2' 'a missing --link-type'
# link --remove returns from its own branch (require_link_remove_selector), once
# per selector — each return is asserted.
p4_accept link       'TICKET_KEY=PROJ-1
OPT_REMOVE=1
OPT_LINK_ID=10500'
p4_accept link       'TICKET_KEY=PROJ-1
OPT_REMOVE=1
OPT_TO=PROJ-2
OPT_LINK_TYPE=Blocks'
p4_reject link       'TICKET_KEY=PROJ-1
OPT_REMOVE=1' 'a --remove with no selector'
p4_accept link-types ':'
p4_reject link-types 'TICKET_KEY=PROJ-1' 'a stray positional'
p4_accept users      'OPT_QUERY=ann'
p4_reject users      ':' 'a missing --query'
p4_accept children   'TICKET_KEY=PROJ-1'
p4_reject children   ':' 'a missing ticket key'
p4_accept discover   'TICKET_KEY=PROJ'
p4_reject discover   'TICKET_KEY=../../etc' 'a traversal-shaped project key'
p4_accept worklog    'TICKET_KEY=PROJ-1
OPT_TIME_SPENT=2h'
p4_reject worklog    'TICKET_KEY=PROJ-1' 'a missing --time-spent'
p4_accept watch      'TICKET_KEY=PROJ-1'
p4_reject watch      'TICKET_KEY=PROJ-1
OPT_LIST=1
OPT_REMOVE=1' 'mutually exclusive --list --remove'
p4_accept vote       'TICKET_KEY=PROJ-1'
p4_reject vote       'TICKET_KEY=PROJ-1
OPT_LIST=1
OPT_REMOVE=1' 'mutually exclusive --list --remove'
p4_accept version    'OPT_LIST=1
OPT_PROJECT=PROJ'
p4_reject version    'OPT_PROJECT=PROJ' 'no mode flag at all'
p4_accept component  'OPT_LIST=1
OPT_PROJECT=PROJ'
p4_reject component  'OPT_LIST=1
OPT_RELEASE=1
OPT_PROJECT=PROJ' 'a foreign (version) mode flag'
p4_accept attach     "TICKET_KEY=PROJ-1
OPT_FILES='$P4_FILE
'"
p4_reject attach     'TICKET_KEY=PROJ-1' 'no mode flag at all'
p4_accept bulk       'OPT_OP=transition
OPT_KEYS=PROJ-1
OPT_STATUS=Done'
p4_reject bulk       'OPT_KEYS=PROJ-1
OPT_STATUS=Done' 'a missing --op'
p4_accept boards     ':'
p4_reject boards     'TICKET_KEY=826' 'a stray positional'
p4_accept board      'TICKET_KEY=826'
p4_reject board      'TICKET_KEY=not-numeric' 'a non-numeric board id'
p4_accept sprints    'TICKET_KEY=826'
p4_reject sprints    'TICKET_KEY=826
OPT_STATE=bogus' 'an out-of-allow-list --state'
p4_accept sprint     'TICKET_KEY=2212'
p4_reject sprint     'TICKET_KEY=2212
OPT_CREATE=1
OPT_UPDATE=1' 'two write modes at once'
p4_accept backlog    'TICKET_KEY=826'
p4_reject backlog    'TICKET_KEY=not-numeric' 'a non-numeric board id'
p4_accept epics      'TICKET_KEY=826'
p4_reject epics      ':' 'a missing board id'
p4_accept epic       'TICKET_KEY=91591
OPT_ISSUES=1'
p4_reject epic       'TICKET_KEY=91591' 'a missing --issues'
p4_accept schedule   'OPT_TO_SPRINT=2212
OPT_KEYS=PROJ-1'
p4_reject schedule   'OPT_TO_SPRINT=2212
OPT_TO_BACKLOG=1
OPT_KEYS=PROJ-1' 'two target ops at once'

# P4-COMPLETENESS — the case list above is HAND-WRITTEN, and until this gate
# nothing made a MISSING entry fail. That is not hypothetical: when comment-edit
# landed, `validate_comment_edit_args` sat unasserted and the whole suite stayed
# green — it was found by diffing grep output by hand, which is exactly the check
# a suite is supposed to perform for you. Every SIBLING structural gate here
# already self-checks its own coverage rather than trusting a list (P5 counts
# curl invocations from source; check-variable-collisions.sh aborts on an empty
# derived table), so this one does too: derive the validator set from lib/*.sh,
# compare it against what p4_run actually drove, and fail on a divergence in
# EITHER direction.
#
# The pattern demands the `()` of a definition rather than matching a bare
# line-initial name, so a future line-initial CALL cannot inflate the declared
# set into a phantom "uncovered" validator.
P4_DECLARED_VALIDATORS="$WORK/p4-declared.txt"
grep -ho '^validate_[a-z_]*_args()' "$SCRIPTS_DIR"/../lib/*.sh \
	| sed 's/()$//' | sort -u >"$P4_DECLARED_VALIDATORS"
sort -u "$P4_COVERED_LOG" >"$WORK/p4-covered-unique.txt"

# Non-emptiness is its OWN assertion, not an implementation detail: if both
# derivations broke, two empty sets would compare equal and this gate would
# report "complete" forever — a broken analyzer and a fully-covered engine
# producing identical output, the same silent degradation
# check-variable-collisions.sh's empty-table guard exists to stop.
TESTS_RUN=$((TESTS_RUN + 1))
p4_declared_count=$(grep -c . "$P4_DECLARED_VALIDATORS" || true)
if [ "$p4_declared_count" -gt 0 ]; then
	pass "P4-COMPLETENESS: the validator set was derived from lib/*.sh ($p4_declared_count found)"
else
	fail "P4-COMPLETENESS: the validator set was derived from lib/*.sh" \
		"the definition grep over lib/*.sh matched NOTHING — the GATE is broken, not (necessarily) the engine"
fi

# Each direction's divergence is kept in a FILE and tested with `[ -s ]` rather
# than captured into a variable: the diagnostic is only ever expanded on the
# failure path, so a quoting slip there stays invisible on every green run. One
# did — an em dash abutting the expansion made this very message die under
# `set -u`, and only a mutation run reached it.
comm -23 "$P4_DECLARED_VALIDATORS" "$WORK/p4-covered-unique.txt" >"$WORK/p4-unasserted.txt"
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -s "$WORK/p4-unasserted.txt" ]; then
	pass "P4-COMPLETENESS: every validator defined in lib/*.sh is driven by a case above"
else
	fail "P4-COMPLETENESS: every validator defined in lib/*.sh is driven by a case above" \
		"never driven (add a p4_accept/p4_reject pair for each): $(tr '\n' ' ' <"$WORK/p4-unasserted.txt")"
fi

# The other direction: a typo'd or stale p4_* entry names a function that does
# not exist, which the driver would report as some unrelated failure rather than
# as the bookkeeping error it is.
comm -13 "$P4_DECLARED_VALIDATORS" "$WORK/p4-covered-unique.txt" >"$WORK/p4-phantom.txt"
TESTS_RUN=$((TESTS_RUN + 1))
if [ ! -s "$WORK/p4-phantom.txt" ]; then
	pass "P4-COMPLETENESS: every case above names a validator that really exists"
else
	fail "P4-COMPLETENESS: every case above names a validator that really exists" \
		"named but undefined: $(tr '\n' ' ' <"$WORK/p4-phantom.txt")"
fi

# P5 — every `curl` invocation must live in lib/http.sh, and there must be
# exactly four of them: jira_curl, jira_curl_multipart,
# fetch_attachment_content_redirect and download_attachment_content.
# This is the split's single most load-bearing structural claim: the transport's
# security properties (token off argv, host pinned, --proto '=https', no -L) are
# reviewed ONCE because there is only one place to review. A fifth call site
# anywhere else silently voids that.
#
# The COUNT and the LOCATION are two separate assertions, and only the location
# one is invariant. The count has moved in BOTH directions: `attach --download`
# grew it from three to five, then folding resolve_media_uuid's and
# resolve_media_download_url's identical request into the one shared
# fetch_attachment_content_redirect primitive brought it back to four. Both
# changes stayed INSIDE http.sh, so the location assertion below never moved.
# Adjusting this number is therefore the expected cost of adding or merging an
# egress; moving a `curl` out of http.sh is not.
#
# The gate matches the INVOCATION PATTERN — `curl` in command position followed
# by the start of an ARGUMENT — rather than the literal string 'curl -sS'. A
# future call written with an extra space, a reordered flag, or a different
# first option is still an UNCOUNTED transport, and an exact-string gate would
# wave it through. Three shapes count as an argument start: an option (`-`), a
# quoted word (`"` or `'`), and an expansion (`$`). The last two exist because a
# call whose URL precedes every flag — `curl "$url" -o f` — is just as much a
# transport as `curl -o f "$url"`, and a `-`-only matcher would miss it.
#
# Two normalizations run BEFORE the match:
#   * comment lines are stripped, so a unit header that TALKS about curl is not
#     miscounted as a call;
#   * line continuations are FOLDED, so a call split as `curl \` + flags on the
#     next line is seen as the single logical command it is. Without the fold,
#     that reformatting alone evades the gate — a false negative, the exact
#     opposite of what a structural guard may do.
# `command -v curl` (jira.sh's dependency probe) stays excluded by construction:
# what follows it is a redirection or end-of-line, never an argument start.
P5_LIB_DIR=$(cd "$SCRIPTS_DIR/../lib" && pwd)
P5_INVOCATION_RE='(^|[^A-Za-z0-9_])curl[[:space:]]+["$'"'"'-]'

# p5_fold_continuations — join each backslash-continued line with its successor,
# so a multi-line command is matched as one line. awk, not sed: folding needs an
# embedded newline in a substitution, which BSD and GNU sed spell differently.
p5_fold_continuations() {
	awk '
		{ p5_line = p5_line $0 }
		/\\$/  { sub(/\\$/, "", p5_line); next }
		       { print p5_line; p5_line = "" }
		END    { if (p5_line != "") print p5_line }
	'
}

# p5_invocations FILE -> that file's curl-invocation lines (comments stripped,
# continuations folded).
p5_invocations() {
	grep -v '^[[:space:]]*#' "$1" | p5_fold_continuations | grep -E "$P5_INVOCATION_RE" || true
}

P5_HITS=""
P5_COUNT=0
for p5_file in "$P5_LIB_DIR"/*.sh "$SCRIPTS_DIR"/*.sh; do
	[ -f "$p5_file" ] || continue
	p5_n=$(p5_invocations "$p5_file" | grep -c . | tr -d ' ')
	[ "$p5_n" -gt 0 ] || continue
	P5_COUNT=$((P5_COUNT + p5_n))
	P5_HITS="$P5_HITS $p5_file"
done
P5_HITS=${P5_HITS# }

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$P5_COUNT" -eq 4 ]; then
	pass "P5: exactly 4 curl invocations across every unit"
else
	fail "P5: exactly 4 curl invocations across every unit" "found $P5_COUNT in: $P5_HITS"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if [ "$P5_HITS" = "$P5_LIB_DIR/http.sh" ]; then
	pass "P5: every curl invocation lives in lib/http.sh"
else
	fail "P5: every curl invocation lives in lib/http.sh" "files with a hit: $P5_HITS"
fi

# The gate must itself be falsifiable: a synthetic unit carrying a curl call the
# gate is claimed to catch has to actually be counted. Without these probes, a
# matcher that stopped matching anything would report the expected count forever
# — a broken analyzer looking identical to a clean tree. Each probe below is one
# rewriting an uncounted transport could plausibly arrive in.
P5_PROBE="$WORK/p5-probe.sh"

# p5_probe_count TEXT -> how many curl invocations the gate finds in TEXT.
p5_probe_count() {
	printf '%s\n' "$1" >"$P5_PROBE"
	p5_invocations "$P5_PROBE" | grep -c . | tr -d ' '
}

# shellcheck disable=SC2016  # every probe below is literal shell TEXT written to a file, not an expansion this script wants performed
equals "P5: the gate counts a REFORMATTED curl invocation (and not the comment)" \
	"$(p5_probe_count '# a comment mentioning curl -sS must NOT be counted
p5_probe() { curl  --proto "=https" -sS -o /dev/null "$1"; }')" "1"

# shellcheck disable=SC2016  # see the SC2016 note on the first probe
equals "P5: the gate counts a curl invocation whose flags sit on a CONTINUATION line" \
	"$(p5_probe_count 'p5_probe() {
	curl \
		--proto "=https" \
		-sS -o /dev/null "$1"
}')" "1"

# shellcheck disable=SC2016  # see the SC2016 note on the first probe
equals "P5: the gate counts a curl invocation whose URL precedes every flag" \
	"$(p5_probe_count 'p5_probe() { curl "$1" -o /dev/null; }')" "1"

# The widened matcher must not swing the other way: `command -v curl` is the
# dependency probe every entry point runs, and counting it would report one more
# transport than exists — noise that trains the reader to ignore P5.
equals "P5: the gate does NOT count the command -v curl dependency probe" \
	"$(p5_probe_count 'command -v curl >/dev/null 2>&1 || { error "curl is not installed"; exit 1; }')" "0"

# ===========================================================================
# Summary
# ===========================================================================
printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAIL"
[ "$TESTS_FAIL" -eq 0 ]
