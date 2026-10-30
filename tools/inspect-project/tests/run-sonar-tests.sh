#!/usr/bin/env sh
#
# run-sonar-tests.sh — the SonarQube engine: three-way availability detection and
#                      the hard-fail/degrade split, the compute-engine poll, issue
#                      paging, the quality gate, the changed-only filter, and the
#                      token handoff.
#
# NO SERVER RUNS DURING THESE TESTS. lib/sonar.sh reaches the server only through
# sonar_curl -> curl, so `curl` IS the boundary, and lib/stubs.sh fakes it with a
# route-keyed canned-response stub. That is not merely convenient: a background stub
# server is a process that can outlive the run that started it, and no test in this
# repository is allowed to leave one behind.
#
# THE ROUTE STUB IN ONE PARAGRAPH. `curl_stub_route <url-substring> <body> <code>`
# answers any request whose URL contains that substring. Calling it twice with the
# same substring queues a SECOND response for that route, and the last queued
# response keeps being served once the queue is exhausted — which is what makes
# "IN_PROGRESS, IN_PROGRESS, then SUCCESS" and "the same page body for all 20 pages"
# both expressible without hand-counting a global call sequence.
#
# Usage:  sh run-sonar-tests.sh
#         VERBOSE=1 sh run-sonar-tests.sh
# Exit 0 = all passed, 1 = one or more failed.
#
set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=SCRIPTDIR/lib/harness.sh
. "$TESTS_DIR/lib/harness.sh"
# shellcheck source=SCRIPTDIR/lib/stubs.sh
. "$TESTS_DIR/lib/stubs.sh"
# shellcheck source=SCRIPTDIR/lib/rig.sh
. "$TESTS_DIR/lib/rig.sh"
# shellcheck source=SCRIPTDIR/lib/gitfixture.sh
. "$TESTS_DIR/lib/gitfixture.sh"

rig_setup "$TESTS_DIR" sonar

UNIT_DRIVER="$TESTS_DIR/lib/unit-driver.sh"

# run SELECTOR COMMAND... — the per-suite PATH map. Availability detection is a
# three-way AND over "scanner on PATH", "server reachable" and "project config
# present", so two of the three are expressed HERE, by leaving a stub directory
# off the path.
# $BIN_MKTEMP and $BIN_CHMOD are on every selector. Both stubs delegate to the real
# binary unless a test explicitly arms them (see lib/stubs.sh), so their presence
# changes nothing until one does — and both are needed by whichever selector the
# credential-file tests use, which is not knowable from here.
STUB_BINS="$BIN_MKTEMP:$BIN_CHMOD"
run() {
	r_selector=$1; shift
	case "$r_selector" in
		full)      r_path="$BIN_GIT:$BIN_DATE:$BIN_IDEA:$BIN_SCANNER:$BIN_CURL:$STUB_BINS:$TOOLBOX" ;;
		noscanner) r_path="$BIN_GIT:$BIN_DATE:$BIN_IDEA:$BIN_CURL:$STUB_BINS:$TOOLBOX" ;;
		nocurl)    r_path="$BIN_GIT:$BIN_DATE:$BIN_IDEA:$BIN_SCANNER:$STUB_BINS:$TOOLBOX" ;;
		*) printf 'FATAL: bad run() selector: %s\n' "$r_selector" >&2; exit 1 ;;
	esac
	harness_run "$r_path" "$@"
}

PROJECT_KEY='my:project'
TASK_ID='AXY-1'
REPORT_TASK="projectKey=$PROJECT_KEY
serverUrl=http://localhost:9000
ceTaskId=$TASK_ID"

# OUT/IJ_OUT — the two files the last run may have written.
OUT=""
IJ_OUT=""

# inspect SELECTOR RESULTS_TAG PROJECT [DEVIATION...] [CLI_FLAG...] — one run, with
# $OUT/$IJ_OUT pointed at its outputs. Also resets every stub log so each test's
# call counting starts at zero.
#
# EVERY STUB CONTROL IS RESET FIRST (rig.sh's rig_reset_stub_state) and every
# deviation is passed HERE, as an explicit argument. The suite used to carry the
# scope, the engine, the token and the scanner's canned report-task.txt as ambient
# globals set before a test and assigned back after it — so a test inserted between
# any such pair silently ran the previous test's scenario and still passed.
#
#   --scope SCOPE        default `all`
#   --engine ENGINE      default `sonar`
#   --report-task TEXT   the .scannerwork/report-task.txt the scanner stub writes
#   --scanner-exit N     the exit status the scanner stub ends with
#   --token VALUE        $SONAR_TOKEN for this run
#   --mktemp-fail        refuse the Sonar credential file's `mktemp`
#   --chmod-600 MODE     `fail`, or `readonly` to apply 400 instead of 600
# Anything else is passed through to inspect-project itself.
inspect() {
	i_selector=$1
	i_root=$(results_root "$2")
	i_project=$3
	shift 3
	rig_reset_stub_state
	SCANNER_STUB_REPORT_TASK="$REPORT_TASK"
	IDEA_STUB_EDIR_SRC="$FIXTURES/edir-basic"
	i_scope=all
	i_engine=sonar
	while [ $# -gt 0 ]; do
		case "$1" in
			--scope)        i_scope=$2; shift 2 ;;
			--engine)       i_engine=$2; shift 2 ;;
			--report-task)  SCANNER_STUB_REPORT_TASK=$2; shift 2 ;;
			--scanner-exit) SCANNER_STUB_EXIT=$2; shift 2 ;;
			--token)        SONAR_TOKEN=$2; shift 2 ;;
			--mktemp-fail)  MKTEMP_STUB_FAIL_CURL_CONFIG=1; shift ;;
			--chmod-600)    CHMOD_STUB_MODE_600=$2; shift 2 ;;
			*) break ;;
		esac
	done
	rig_reset_logs
	run "$i_selector" "$INSPECT" --project "$i_project" \
		--scope "$i_scope" --engine "$i_engine" \
		--output-root "$i_root" --idea-bin "$BIN_IDEA/idea" "$@"
	i_dir="$(run_dir_of "$i_root" "${i_project##*/}")"
	OUT="$i_dir/sonar.json"
	IJ_OUT="$i_dir/intellij.json"
}

# route_healthy_server / route_successful_task / route_passing_gate — the three
# responses every "and then Sonar worked" test needs. Named so each test states
# only the ONE thing it varies.
route_healthy_server() { curl_stub_route '/api/system/status' '{"id":"x","version":"10.6","status":"UP"}' 200; }
route_successful_task() {
	curl_stub_route '/api/ce/task' \
		'{"task":{"id":"AXY-1","status":"SUCCESS","analysisId":"AN-1"}}' 200
}
route_passing_gate() {
	curl_stub_route '/api/qualitygates/project_status' \
		'{"projectStatus":{"status":"OK","conditions":[{"status":"OK","metricKey":"new_coverage","comparator":"LT","errorThreshold":"80","actualValue":"91.0"}]}}' 200
}
# route_issues TOTAL BODY_ISSUES — one page of issue results.
route_issues() {
	curl_stub_route '/api/issues/search' \
		"{\"total\":$1,\"paging\":{\"pageIndex\":1,\"pageSize\":500,\"total\":$1},\"issues\":[$2]}" 200
}

# an_issue KEY FILE — one Sonar issue as the API returns it, with `component`
# spelled the way the server does: "<projectKey>:<path>".
an_issue() {
	printf '{"key":"%s","rule":"rust:S1","type":"CODE_SMELL","severity":"MAJOR","component":"%s:%s","line":7,"message":"tidy this up","status":"OPEN"}' \
		"$1" "$PROJECT_KEY" "$2"
}

SONAR_PROJECT=$(new_project sonarproj src/main.rs src/other.rs sonar-project.properties)

# ===========================================================================
section "availability: all three checks pass"
# ===========================================================================
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 2 "$(an_issue K1 src/main.rs),$(an_issue K2 src/other.rs)"
inspect full avail-ok "$SONAR_PROJECT"

expect_rc "available: exit 0" 0
stdout_has "available: sonar.json is announced on the machine channel" "INSPECT_SONAR_OUTPUT=$OUT"
stdout_not_has "available: nothing was skipped, so no skip reason is emitted" \
	"INSPECT_SONAR_SKIPPED_REASON"
json_eq "available: all three detection results are recorded in the metadata" \
	"$OUT" '.metadata.availability_checks' \
	'{"scanner_on_path":true,"server_up":true,"project_config_found":true}'
json_eq "available: the engine is named" "$OUT" '.metadata.engine' '"sonar-scanner"'
json_eq "available: the project key comes from the scanner's own report-task.txt" \
	"$OUT" '.metadata.project_key' "\"$PROJECT_KEY\""
json_eq "available: the analysis id comes from the compute-engine task" \
	"$OUT" '.metadata.analysis_id' '"AN-1"'
json_eq "available: the component prefix is stripped to a project-relative file" \
	"$OUT" '[.issues[].file]' '["src/main.rs","src/other.rs"]'
json_eq "available: each issue keeps the fields the contract names" \
	"$OUT" '.issues[0] | [.key,.rule,.type,.severity,.line,.message,.status] | @csv' \
	'"\"K1\",\"rust:S1\",\"CODE_SMELL\",\"MAJOR\",7,\"tidy this up\",\"OPEN\""'
# The whole document, against a committed golden. Every other assertion in this
# suite is a field probe and therefore blind to a metadata key silently added,
# removed or renamed — see harness.sh's json_golden.
json_golden "available: sonar.json matches the committed golden document, key for key" \
	"$OUT" "$FIXTURES/golden/sonar.json"
path_exists "available: the scanner's own .scannerwork is deliberately left in place" \
	"$SONAR_PROJECT/.scannerwork/report-task.txt"
rm -rf "$SONAR_PROJECT/.scannerwork"

# ===========================================================================
section "availability: each missing precondition, named individually"
# ===========================================================================
curl_stub_reset
route_healthy_server
inspect noscanner avail-noscanner "$SONAR_PROJECT"
expect_rc "no scanner: --engine sonar is a HARD failure, exit 1" 1
stderr_has "no scanner: the reason names the scanner" "sonar-scanner is not on PATH"
stderr_has "no scanner: and says the requested engine could not run" \
	"--engine sonar was requested but Sonar is not available"

curl_stub_reset
curl_stub_route '/api/system/status' '{"status":"DOWN"}' 200
inspect full avail-serverdown "$SONAR_PROJECT"
expect_rc "server not UP: exit 1" 1
stderr_has "server not UP: the host is named" "no SonarQube server reporting UP at"

curl_stub_reset
curl_stub_route '/api/system/status' '' TRANSPORT_FAILURE
inspect full avail-serverunreachable "$SONAR_PROJECT"
expect_rc "server unreachable: exit 1" 1
stderr_has "server unreachable: reported the same way as a DOWN one" \
	"no SonarQube server reporting UP at"

curl_stub_reset
inspect nocurl avail-nocurl "$SONAR_PROJECT"
expect_rc "no curl: exit 1" 1
stderr_has "no curl: curl's absence is reported as the SERVER check's reason" \
	"curl is not installed, so no SonarQube server can be reached"

NO_CONFIG=$(new_project noconfig src/main.rs)
curl_stub_reset
route_healthy_server
inspect full avail-noconfig "$NO_CONFIG"
expect_rc "no project config: exit 1" 1
stderr_has "no project config: every file it looked for is named" \
	"looked for sonar-project.properties, or Sonar plugin/projectKey config in pom.xml, build.gradle, build.gradle.kts"

# --- the best-effort build-file detection -----------------------------------
GRADLE_PROJECT=$(new_project gradleproj src/main.rs build.gradle)
printf 'plugins { id "org.sonarqube" version "4.0" }\n' >"$GRADLE_PROJECT/build.gradle"
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full avail-gradle "$GRADLE_PROJECT"
expect_rc "gradle config: a Sonar plugin mentioned in build.gradle counts as config" 0
json_eq "gradle config: recorded as found" "$OUT" '.metadata.availability_checks.project_config_found' 'true'
rm -rf "$GRADLE_PROJECT/.scannerwork"

# --- a host URL that is not an http(s) origin -------------------------------
curl_stub_reset
inspect full avail-badhost "$SONAR_PROJECT" --sonar-host-url 'ftp://example.invalid'
expect_rc "bad host URL: exit 1" 1
stderr_has "bad host URL: rejected before any request is built" \
	"the Sonar host URL is not a plain http(s) origin with no embedded credentials: ftp://example.invalid"
equals "bad host URL: and no request was made at all" "$(curl_call_count)" "0"

# --- a host URL carrying `user:pass@` userinfo ------------------------------
# This tool authenticates with a token and nothing else, so URL credentials buy no
# capability — while the host string is echoed to stderr AND persisted into
# sonar.json's `metadata.sonar_host_url`, a file whose whole purpose is to be fed
# into an agent's context. So the whole shape is refused, and the one remaining
# print of it (the refusal message itself) is the REDACTED form.
#
# The two halves are deliberately distinctive strings rather than `user:pass`, so
# the "it never appears" assertions cannot pass by accident on a substring of some
# other value in the transcript.
CRED_HOST='http://squ_urluser:squ_urlpass@sonar.example.invalid:9000'
CRED_HOST_REDACTED='http://***@sonar.example.invalid:9000'

# THE FULL HAPPY PATH IS ROUTED, deliberately, for a run that must never reach it.
# The stub routes on a URL SUBSTRING, so every one of them matches this host too —
# which means without the rejection this run would COMPLETE, and `expect_rc 1`
# therefore carries the claim itself instead of being satisfied by whichever
# unrouted call happened to fail first. Established by mutation: with only the
# server route configured, deleting the rejection left the exit code green.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full avail-userinfo "$SONAR_PROJECT" --sonar-host-url "$CRED_HOST"
expect_rc "userinfo host: refused outright, exit 1" 1
stderr_has "userinfo host: the refusal names the shape and shows the host REDACTED" \
	"the Sonar host URL is not a plain http(s) origin with no embedded credentials: $CRED_HOST_REDACTED"
stderr_not_has "userinfo host: the password never reaches the refusal message" "squ_urlpass"
stderr_not_has "userinfo host: nor does the username" "squ_urluser"
equals "userinfo host: and no request was built from it at all" "$(curl_call_count)" "0"
equals "userinfo host: stdout stays empty, so nothing machine-readable carries it either" \
	"$CUR_OUT" ""

# --- and the ONE path on which the rejected host reaches the machine channel --
# `--engine both` degrades rather than failing, and publishes the reason on stdout
# as INSPECT_SONAR_SKIPPED_REASON — which is a stdout sink for the host string, and
# stdout is the channel this tool's agent caller actually parses. It carries the
# redacted form because the reason is built from SONAR_HOST_DISPLAY.
#
# IT ALSO CLOSES THE `sonar.json` SINK STRUCTURALLY, which is why the absent-file
# assertion is here: a credential-bearing host cannot be persisted into a results
# file, because the rejection happens before any run that would write one.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full avail-userinfo-both "$SONAR_PROJECT" --engine both --sonar-host-url "$CRED_HOST"
expect_rc "userinfo host, --engine both: degrades to IntelliJ alone, exit 0" 0
stdout_has "userinfo host, --engine both: the machine channel carries the REDACTED host" \
	"INSPECT_SONAR_SKIPPED_REASON=the Sonar host URL is not a plain http(s) origin with no embedded credentials: $CRED_HOST_REDACTED"
stdout_not_has "userinfo host, --engine both: and never the password" "squ_urlpass"
stdout_not_has "userinfo host, --engine both: nor the username" "squ_urluser"
path_absent "userinfo host, --engine both: no sonar.json exists to have persisted it into" "$OUT"

# ===========================================================================
section "--engine both DEGRADES where --engine sonar hard-fails"
# ===========================================================================
curl_stub_reset
route_healthy_server
inspect noscanner degrade "$SONAR_PROJECT" --engine both
expect_rc "degrade: exit 0 — IntelliJ still ran" 0
stderr_has "degrade: the fallback is announced with its reason" \
	"Sonar is unavailable, running IntelliJ alone: sonar-scanner is not on PATH"
stdout_has "degrade: an agent reading only stdout learns why" \
	"INSPECT_SONAR_SKIPPED_REASON=sonar-scanner is not on PATH"
stdout_not_has "degrade: and there is no sonar.json key to mislead it" "INSPECT_SONAR_OUTPUT"
path_exists "degrade: intellij.json was still written" "$IJ_OUT"
stderr_has "degrade: the human summary says Sonar was skipped" "Sonar       : SKIPPED"

# --- and the flag is NOT set when Sonar was never asked for -----------------
# The interactive menu probes Sonar on every run just to label its own option, so
# a skip REASON exists even when nothing was skipped. Reporting one to a caller who
# asked for --engine intellij would be both noise and untrue.
inspect noscanner degrade-not-requested "$SONAR_PROJECT" --engine intellij
expect_rc "engine intellij: exit 0" 0
stdout_not_has "engine intellij: no skip reason, because nothing was skipped" \
	"INSPECT_SONAR_SKIPPED_REASON"
stderr_not_has "engine intellij: and the summary says nothing about Sonar" "Sonar       : SKIPPED"

# ===========================================================================
section "the compute-engine poll: bounded, early-returning, loud on failure"
# ===========================================================================
curl_stub_reset
route_healthy_server
curl_stub_route '/api/ce/task' '{"task":{"status":"IN_PROGRESS"}}' 200
curl_stub_route '/api/ce/task' '{"task":{"status":"PENDING"}}' 200
curl_stub_route '/api/ce/task' '{"task":{"status":"SUCCESS","analysisId":"AN-9"}}' 200
route_passing_gate
route_issues 1 "$(an_issue K1 src/main.rs)"
inspect full poll-progress "$SONAR_PROJECT"
expect_rc "poll: IN_PROGRESS then PENDING then SUCCESS completes the run" 0
json_eq "poll: the analysis id from the SUCCESS response is the one recorded" \
	"$OUT" '.metadata.analysis_id' '"AN-9"'
equals "poll: exactly four calls — status, three polls — plus gate and issues" \
	"$(curl_call_count)" "6"
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
curl_stub_route '/api/ce/task' '{"task":{"status":"FAILED"}}' 200
inspect full poll-failed "$SONAR_PROJECT"
expect_rc "poll: FAILED aborts, exit 1" 1
stderr_has "poll: FAILED names the task and the status" "ended FAILED"

curl_stub_reset
route_healthy_server
curl_stub_route '/api/ce/task' '{"task":{"status":"CANCELED"}}' 200
inspect full poll-canceled "$SONAR_PROJECT"
expect_rc "poll: CANCELED aborts, exit 1" 1
stderr_has "poll: CANCELED names the status" "ended CANCELED"

curl_stub_reset
route_healthy_server
curl_stub_route '/api/ce/task' '{"task":{"status":"REJIGGERED"}}' 200
inspect full poll-unknown "$SONAR_PROJECT"
expect_rc "poll: an unrecognized status aborts rather than polling forever" 1
stderr_has "poll: the unrecognized status is quoted back" \
	"unexpected Sonar compute-engine task status"

curl_stub_reset
route_healthy_server
curl_stub_route '/api/ce/task' '{"task":{"status":"SUCCESS"}}' 200
inspect full poll-no-analysis-id "$SONAR_PROJECT"
expect_rc "poll: SUCCESS without an analysisId is a failure, not an empty gate" 1
stderr_has "poll: and says exactly that" "succeeded but reported no analysisId"

curl_stub_reset
route_healthy_server
curl_stub_route '/api/ce/task' '{"errors":[{"msg":"nope"}]}' 500
inspect full poll-http-error "$SONAR_PROJECT"
expect_rc "poll: a non-2xx task lookup aborts, exit 1" 1
stderr_has "poll: the HTTP status is reported" \
	"Sonar compute-engine task lookup failed (HTTP 500)"

# --- the upper bound, exercised through lib/unit-driver.sh ------------------
# See that file for why this one property cannot be reached through the CLI: the
# production bound is 90 attempts at 2s, so an e2e version would take three
# minutes. The function, the units around it and the curl boundary are all the
# production ones; only the two constants move.
# wait_for_task [--attempts N] [--interval N] — one unit-driver call, with every
# stub control reset first and each overridden constant passed explicitly. Same
# rule as inspect(): an override may not outlive the run it was written for. An
# override that is NOT passed keeps its PRODUCTION value, which is what lets the
# test below assert against the real interval.
wait_for_task() {
	rig_reset_stub_state
	while [ $# -gt 0 ]; do
		case "$1" in
			--attempts) UNIT_SONAR_POLL_MAX_ATTEMPTS=$2; shift 2 ;;
			--interval) UNIT_SONAR_POLL_INTERVAL=$2; shift 2 ;;
			*) printf 'FATAL: bad wait_for_task deviation: %s\n' "$1" >&2; exit 1 ;;
		esac
	done
	rig_reset_logs
	harness_run "$BIN_CURL:$TOOLBOX" sh "$UNIT_DRIVER" "$TOOL_DIR/lib" \
		sonar_wait_for_task "$TASK_ID"
}

curl_stub_reset
curl_stub_route '/api/ce/task' '{"task":{"status":"IN_PROGRESS"}}' 200
wait_for_task --interval 0
expect_rc "poll bound: a task that never finishes fails instead of hanging" 1
stderr_has "poll bound: the timeout is reported" "did not finish within"
equals "poll bound: it gave up after exactly SONAR_POLL_MAX_ATTEMPTS (90) polls" \
	"$(curl_call_count)" "90"

curl_stub_reset
curl_stub_route '/api/ce/task' '{"task":{"status":"IN_PROGRESS"}}' 200
wait_for_task --attempts 3 --interval 1
expect_rc "poll bound: the ceiling is attempts x interval" 1
stderr_has "poll bound: and is reported in seconds, not in attempts" "did not finish within 3s"
equals "poll bound: with the attempt count honoured" "$(curl_call_count)" "3"

# --- the PRODUCTION interval, not an overridden one -------------------------
# Both tests above override SONAR_POLL_INTERVAL, so between them the shipped value
# was never asserted at all: changing it from 2 to anything else left this whole
# section green. This run overrides only the attempt count and leaves the interval
# where lib/runtime.sh sets it, so `2 x 2 = 4s` is a claim about the real constant.
# It therefore really does sleep ~4s — the price of asserting the shipped value
# rather than a test's own.
curl_stub_reset
curl_stub_route '/api/ce/task' '{"task":{"status":"IN_PROGRESS"}}' 200
wait_for_task --attempts 2
expect_rc "poll interval: a run at the PRODUCTION interval still gives up" 1
stderr_has "poll interval: and the ceiling reflects the shipped 2s interval, not a test's" \
	"did not finish within 4s"
equals "poll interval: with the overridden attempt count honoured" "$(curl_call_count)" "2"

# ===========================================================================
section "issue paging"
# ===========================================================================
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 2 "$(an_issue K1 src/main.rs),$(an_issue K2 src/other.rs)"
inspect full page-single "$SONAR_PROJECT"
expect_rc "paging: a result set inside one page succeeds" 0
equals "paging: and asks for exactly one page" \
	"$(grep -c 'p=1$' "$CURL_STUB_ARGV_LOG")" "1"
stderr_not_has "paging: no truncation warning for a complete read" "issues[] is truncated"
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
curl_stub_route '&p=1' \
	"{\"paging\":{\"pageIndex\":1,\"pageSize\":500,\"total\":501},\"issues\":[$(an_issue P1 src/main.rs)]}" 200
curl_stub_route '&p=2' \
	"{\"paging\":{\"pageIndex\":2,\"pageSize\":500,\"total\":501},\"issues\":[$(an_issue P2 src/other.rs)]}" 200
inspect full page-two "$SONAR_PROJECT"
expect_rc "paging: a result set over the page size reads a second page" 0
json_eq "paging: both pages' issues land in ONE array" \
	"$OUT" '[.issues[].key]' '["P1","P2"]'
json_eq "paging: the server's own total is reported as the project-wide count" \
	"$OUT" '.metadata.total_issues_project_wide' '501'
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
curl_stub_route '/api/issues/search' \
	"{\"paging\":{\"pageIndex\":1,\"pageSize\":500,\"total\":100000},\"issues\":[$(an_issue CAP src/main.rs)]}" 200
inspect full page-cap "$SONAR_PROJECT"
expect_rc "paging: an oversized result set still completes" 0
equals "paging: it stops at SONAR_ISSUES_MAX_PAGES (20), not at the server's total" \
	"$(grep -c 'api/issues/search' "$CURL_STUB_ARGV_LOG")" "20"
json_eq "paging: the truncation is visible as a totals disagreement, not hidden" \
	"$OUT" '[(.issues | length), .metadata.total_issues_project_wide]' '[20,100000]'
stderr_has "paging: and is warned about in words" \
	"stopped reading Sonar issues after 20 pages of 500"
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
curl_stub_route '/api/issues/search' \
	"{\"total\":1,\"issues\":[$(an_issue NOPAGING src/main.rs)]}" 200
inspect full page-nopaging "$SONAR_PROJECT"
expect_rc "paging: a response with no paging block is read as a single page" 0
equals "paging: so exactly one request is made" \
	"$(grep -c 'api/issues/search' "$CURL_STUB_ARGV_LOG")" "1"
json_eq "paging: the top-level total is used as the fallback project-wide count" \
	"$OUT" '.metadata.total_issues_project_wide' '1'
rm -rf "$SONAR_PROJECT/.scannerwork"

# ===========================================================================
section "the quality gate"
# ===========================================================================
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full gate-ok "$SONAR_PROJECT"
json_eq "gate OK: the status is carried through" "$OUT" '.metadata.quality_gate_status' '"OK"'
json_eq "gate OK: a passing condition is not reported as failed" \
	"$OUT" '.metadata.quality_gate_failed_conditions' '[]'
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
route_successful_task
curl_stub_route '/api/qualitygates/project_status' '{"projectStatus":{"status":"ERROR","conditions":[
	{"status":"OK","metricKey":"new_bugs","comparator":"GT","errorThreshold":"0","actualValue":"0"},
	{"status":"ERROR","metricKey":"new_coverage","comparator":"LT","errorThreshold":"80","actualValue":"42.5"},
	{"status":"WARN","metricKey":"new_duplicated_lines_density","comparator":"GT","errorThreshold":"3","actualValue":"4.1"}
]}}' 200
route_issues 0 ''
inspect full gate-error "$SONAR_PROJECT"
json_eq "gate ERROR: the status is carried through" "$OUT" '.metadata.quality_gate_status' '"ERROR"'
json_eq "gate ERROR: only the non-OK conditions are collected, as readable prose" \
	"$OUT" '.metadata.quality_gate_failed_conditions' \
	'["new_coverage LT 80 (actual: 42.5, ERROR)","new_duplicated_lines_density GT 3 (actual: 4.1, WARN)"]'
stderr_has "gate ERROR: each failed condition reaches the human summary" \
	"failed: new_coverage LT 80 (actual: 42.5, ERROR)"
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
route_successful_task
curl_stub_route '/api/qualitygates/project_status' '{}' 200
route_issues 0 ''
inspect full gate-missing "$SONAR_PROJECT"
json_eq "gate absent: reported as UNKNOWN rather than as an empty pass" \
	"$OUT" '.metadata.quality_gate_status' '"UNKNOWN"'
json_eq "gate absent: with no invented conditions" \
	"$OUT" '.metadata.quality_gate_failed_conditions' '[]'
rm -rf "$SONAR_PROJECT/.scannerwork"

# ===========================================================================
section "changed-only filters issues[] but never the quality gate"
# ===========================================================================
# The gate is a whole-project verdict and filtering it would report a project as
# passing on the strength of one clean file. Only issues[] is narrowed — and the
# two totals are what make the narrowing visible.
CHANGED_REPO="$WORK/projects/changedrepo"
git_init_repo "$CHANGED_REPO"
mkdir -p "$CHANGED_REPO/src"
printf 'fn main() {}\n' >"$CHANGED_REPO/src/main.rs"
printf 'fn other() {}\n' >"$CHANGED_REPO/src/other.rs"
: >"$CHANGED_REPO/sonar-project.properties"
git_fix "$CHANGED_REPO" add -A
git_fix "$CHANGED_REPO" commit -q -m seed
printf '// touched\n' >>"$CHANGED_REPO/src/main.rs"

curl_stub_reset
route_healthy_server
route_successful_task
curl_stub_route '/api/qualitygates/project_status' '{"projectStatus":{"status":"ERROR","conditions":[
	{"status":"ERROR","metricKey":"new_bugs","comparator":"GT","errorThreshold":"0","actualValue":"3"}
]}}' 200
route_issues 2 "$(an_issue CHANGED src/main.rs),$(an_issue UNCHANGED src/other.rs)"
inspect full changed-filter "$CHANGED_REPO" --scope changed-only
expect_rc "changed-only: exit 0" 0
json_eq "changed-only: only issues in the current diff are kept" \
	"$OUT" '[.issues[].key]' '["CHANGED"]'
json_eq "changed-only: total_issues is the filtered count, project-wide is the server's" \
	"$OUT" '[.metadata.total_issues, .metadata.total_issues_project_wide]' '[1,2]'
json_eq "changed-only: the gate is NOT filtered — it stays the whole-project verdict" \
	"$OUT" '.metadata.quality_gate_status' '"ERROR"'
json_eq "changed-only: and the failed condition survives the filter too" \
	"$OUT" '.metadata.quality_gate_failed_conditions | length' '1'
json_eq "changed-only: the metadata says out loud what was and was not filtered" \
	"$OUT" '.metadata.scope_note' \
	'"quality gate and full scan are always whole-project; only issues[] below is filtered to files in the current diff"'
json_eq "changed-only: a filter that KEPT something does not raise the false-clean flag" \
	"$OUT" '.metadata.changed_only_filter_matched_nothing' 'false'
stderr_not_has "changed-only: nor warn about one" \
	"NONE of them matched the changed-file list"
rm -rf "$CHANGED_REPO/.scannerwork"

# --- the two path shapes the changed-file list's flags exist for -------------
# `-z` and `--untracked-files=all` are load-bearing in collect_changed_files and
# this is the ONLY place their effect is observable end to end: the filter is a
# literal path comparison, so a path git named differently than Sonar does drops
# its issue silently. Without `-z`, `has space.rs` arrives C-QUOTED as
# `"has space.rs"`; without `--untracked-files=all`, `fresh/nested.rs` is never
# named at all, only its directory. Either way the issue vanishes and the run
# reports a FALSE CLEAN for that file.
printf 'fn spaced() {}\n' >"$CHANGED_REPO/has space.rs"
mkdir -p "$CHANGED_REPO/fresh"
printf 'fn nested() {}\n' >"$CHANGED_REPO/fresh/nested.rs"

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 3 "$(an_issue SPACED 'has space.rs'),$(an_issue NESTED fresh/nested.rs),$(an_issue UNCHANGED src/other.rs)"
inspect full changed-hostile-paths "$CHANGED_REPO" --scope changed-only
expect_rc "changed-only path shapes: exit 0" 0
stderr_has "changed-only path shapes: all three changed paths are counted per-file" \
	"changed-only scope: 3 changed file(s)"
json_eq "changed-only path shapes: an issue on a path with a SPACE is kept, not silently dropped" \
	"$OUT" '[.issues[].key] | index("SPACED") != null' 'true'
json_eq "changed-only path shapes: and one inside a NEW untracked directory is kept too" \
	"$OUT" '[.issues[].key] | index("NESTED") != null' 'true'
json_eq "changed-only path shapes: while the unchanged file's issue is still filtered out" \
	"$OUT" '[.issues[].key] | sort' '["NESTED","SPACED"]'
rm -rf "$CHANGED_REPO/.scannerwork"

# ===========================================================================
section "a changed-only filter that matched NOTHING is disclosed, not reported clean"
# ===========================================================================
# The filter is a strict equality join between two independently-derived path
# bases, and nothing validates that they agree. Any layout where they do not (a
# multi-module scanner key, a `sonar.projectBaseDir` that differs from --project)
# drops EVERY issue and reports `total_issues: 0` — indistinguishable from a
# genuinely clean diff. The flag does not fix the join; it makes the one signature
# of that failure explicit in the channel an agent actually reads.
#
# THE TRIGGER HAS THREE CONDITIONS and all three are asserted, here and in the two
# adjacent cases below that must stay `false`: filtering active, a NON-EMPTY
# pre-filter set, and an EMPTY post-filter set.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 1 "$(an_issue ONLY_UNCHANGED src/other.rs)"
inspect full filter-matched-nothing "$CHANGED_REPO" --scope changed-only
expect_rc "matched nothing: the run still succeeds — this is a disclosure, not a fault" 0
json_eq "matched nothing: the flag fires in the machine-readable metadata" \
	"$OUT" '.metadata.changed_only_filter_matched_nothing' 'true'
json_eq "matched nothing: total_issues really is 0 while the server's count is not" \
	"$OUT" '[.metadata.total_issues, .metadata.total_issues_project_wide]' '[0,1]'
stderr_has "matched nothing: and it is said out loud" \
	"Sonar reported issues but NONE of them matched the changed-file list"
stderr_has "matched nothing: with the likely cause named" \
	"that is what a project-key/base-directory mismatch looks like"
stderr_has "matched nothing: and the reading the caller must NOT take" \
	"treat this run as \"not filtered\", not as \"clean\""
rm -rf "$CHANGED_REPO/.scannerwork"

# --- `all` scope with genuinely zero issues must stay false ------------------
# No filter ran, so an empty result set here means what it says. Reporting the flag
# would tell a caller to distrust a clean project.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full filter-all-scope-empty "$CHANGED_REPO"
expect_rc "all scope, zero issues: exit 0" 0
json_eq "all scope, zero issues: the flag stays false — nothing was filtered" \
	"$OUT" '.metadata.changed_only_filter_matched_nothing' 'false'
json_eq "all scope, zero issues: and both totals honestly agree on zero" \
	"$OUT" '[.metadata.total_issues, .metadata.total_issues_project_wide]' '[0,0]'
stderr_not_has "all scope, zero issues: no false-clean warning is printed" \
	"NONE of them matched the changed-file list"
rm -rf "$CHANGED_REPO/.scannerwork"

# --- changed-only with genuinely zero issues must stay false too -------------
# The third condition, isolated: filtering IS active and the post-filter set IS
# empty, but the PRE-filter set was empty too. There is no mismatch to disclose.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full filter-changed-empty-prefilter "$CHANGED_REPO" --scope changed-only
expect_rc "changed-only, zero issues found at all: exit 0" 0
json_eq "changed-only, zero issues found at all: the flag stays false — there was nothing to drop" \
	"$OUT" '.metadata.changed_only_filter_matched_nothing' 'false'
stderr_not_has "changed-only, zero issues found at all: and no warning" \
	"NONE of them matched the changed-file list"
rm -rf "$CHANGED_REPO/.scannerwork"

# --- the same repository at `all` scope: no filtering ------------------------
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 2 "$(an_issue CHANGED src/main.rs),$(an_issue UNCHANGED src/other.rs)"
inspect full all-nofilter "$CHANGED_REPO"
json_eq "all scope: nothing is filtered out" "$OUT" '[.issues[].key]' '["CHANGED","UNCHANGED"]'
json_eq "all scope: so the two totals agree" \
	"$OUT" '[.metadata.total_issues, .metadata.total_issues_project_wide]' '[2,2]'
rm -rf "$CHANGED_REPO/.scannerwork"

# --- a project that is a SUBDIRECTORY of the repository ---------------------
# Three path bases are in play at once here: `git status` reports repo-relative
# paths, Sonar reports project-relative ones, and the filter is a literal
# comparison between them. Conflating them filters every issue away and reports a
# FALSE CLEAN result — which is why this test asserts a NON-empty issues[].
SUB_REPO="$WORK/projects/subrepo"
git_init_repo "$SUB_REPO"
mkdir -p "$SUB_REPO/mod-a/src" "$SUB_REPO/mod-b"
printf 'fn a() {}\n' >"$SUB_REPO/mod-a/src/a.rs"
printf 'fn b() {}\n' >"$SUB_REPO/mod-b/b.rs"
: >"$SUB_REPO/mod-a/sonar-project.properties"
git_fix "$SUB_REPO" add -A
git_fix "$SUB_REPO" commit -q -m seed
printf '// touched\n' >>"$SUB_REPO/mod-a/src/a.rs"
printf '// touched elsewhere\n' >>"$SUB_REPO/mod-b/b.rs"

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 2 "$(an_issue SUBTREE src/a.rs),$(an_issue ELSEWHERE ../mod-b/b.rs)"
inspect full changed-subtree "$SUB_REPO/mod-a" --scope changed-only
expect_rc "subtree changed-only: exit 0" 0
json_eq "subtree changed-only: the repo-relative diff is rebased onto the project, so the match holds" \
	"$OUT" '[.issues[].key]' '["SUBTREE"]'
stderr_has "subtree changed-only: only the subtree's change is counted" \
	"changed-only scope: 1 changed file(s)"
rm -rf "$SUB_REPO/mod-a/.scannerwork"

# ===========================================================================
section "the token never reaches any argv"
# ===========================================================================
# Two sinks need the token and neither gets it as an argument: sonar-scanner reads
# $SONAR_TOKEN from its environment, and curl reads a 600-mode `-K` config file. The
# assertions below prove BOTH halves — absent from each argv, present in the
# channel it is supposed to travel in — because either one alone is satisfied by a
# token that simply never arrived.
SECRET='squ_s3cr3t_t0ken'

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full token-flag "$SONAR_PROJECT" --sonar-token "$SECRET"
expect_rc "token via --sonar-token: exit 0" 0
stderr_has "token via --sonar-token: the argv exposure is warned about" \
	"--sonar-token puts the token on this process's argv"
file_not_has "token: it appears NOWHERE in any curl argv, not even inside a longer token" \
	"$CURL_STUB_ARGV_LOG" "$SECRET"
log_has_token "token: curl gets a -K config file instead" "$CURL_STUB_ARGV_LOG" "-K"
file_has "token: whose content is the HTTP-basic user line Sonar expects" \
	"$CURL_STUB_CONFIG_LOG" "user = \"$SECRET:\""
file_has "token: and which is created readable by its owner only" \
	"$CURL_STUB_CONFIG_LOG" "CONFIG_MODE=-rw-------"
file_not_has "token: nor anywhere in the scanner's argv" \
	"$SCANNER_STUB_ARGV_LOG" "$SECRET"
log_has_token "token: the scanner receives it through its ENVIRONMENT" \
	"$SCANNER_STUB_ENV_LOG" "SONAR_TOKEN=$SECRET"
json_eq "token: and it is never written into sonar.json" \
	"$OUT" "[paths(scalars) as \$p | getpath(\$p) | tostring | contains(\"$SECRET\")] | any" 'false'
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full token-env "$SONAR_PROJECT" --token "$SECRET"
expect_rc "token via \$SONAR_TOKEN: exit 0" 0
stderr_not_has "token via \$SONAR_TOKEN: the preferred channel earns no warning" \
	"puts the token on this process's argv"
file_has "token via \$SONAR_TOKEN: still handed to curl in the config file" \
	"$CURL_STUB_CONFIG_LOG" "user = \"$SECRET:\""
file_not_has "token via \$SONAR_TOKEN: and still nowhere in any argv" \
	"$CURL_STUB_ARGV_LOG" "$SECRET"
log_has_token "token via \$SONAR_TOKEN: and to the scanner in its environment" \
	"$SCANNER_STUB_ENV_LOG" "SONAR_TOKEN=$SECRET"
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full token-none "$SONAR_PROJECT"
expect_rc "no token: anonymous access to a local Sonar is not an error" 0
log_not_has_token "no token: no config file is built at all" "$CURL_STUB_ARGV_LOG" "-K"
log_has_token "no token: and the scanner is told nothing" \
	"$SCANNER_STUB_ENV_LOG" "SONAR_TOKEN=<unset>"
rm -rf "$SONAR_PROJECT/.scannerwork"

# ===========================================================================
section "a token that would cross plaintext http is REFUSED, not warned about"
# ===========================================================================
# THIS SECTION USED TO ASSERT THE OPPOSITE, and the inversion is the whole point.
# It previously pinned "a token to a non-loopback http host is warned about", i.e.
# permitted with a note on stderr. That reasoning ("the server is the caller's own
# and the risk is theirs") holds for a human reading stderr and fails for the
# caller this tool is built for: an agent, which this script's own contract
# documents as parsing STDOUT and not stderr. A host named in an instruction an
# agent picked up while processing the inspected repository could therefore
# exfiltrate the operator's Sonar token, with the machine channel showing nothing
# wrong. So the default is now REFUSAL.
#
# THE REFUSAL REUSES THE ENGINE-AVAILABILITY POLICY rather than adding a second
# exit path, so it has the two shapes that policy already has, and both are
# asserted below: `--engine sonar` is a hard exit 1, `--engine both` degrades and
# discloses the reason on stdout. In BOTH shapes the load-bearing claim is the same
# one, and it is the assertion that the check happens EARLY: zero curl calls and an
# unlaunched scanner mean the token was never sent anywhere, which is the property
# a "we refused" message on its own does not establish.
PLAINTEXT_HOST='http://sonar.example.invalid:9000'

# The full happy path is routed for the same reason the userinfo section above
# gives: without the refusal this run would COMPLETE, so the exit code is a claim
# about the refusal rather than about whichever call was left unrouted.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full token-plaintext-refused "$SONAR_PROJECT" --token "$SECRET" \
	--sonar-host-url "$PLAINTEXT_HOST"
expect_rc "plaintext refusal: --engine sonar is a HARD failure, exit 1" 1
stderr_has "plaintext refusal: the refusal names the host and the exposure" \
	"refusing to send the Sonar token in the clear to the non-loopback plaintext host $PLAINTEXT_HOST"
stderr_has "plaintext refusal: with all three remedies named" \
	"use an https host, drop the token, or pass --allow-plaintext-token to accept the exposure deliberately"
equals "plaintext refusal: NOT ONE request was sent, so the token never crossed" \
	"$(curl_call_count)" "0"
equals "plaintext refusal: and the scanner — the other sink that gets the token — never ran" \
	"$(grep -c . "$SCANNER_STUB_ARGV_LOG" || true)" "0"
equals "plaintext refusal: stdout carries nothing, because the run failed" "$CUR_OUT" ""

curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full token-plaintext-degrade "$SONAR_PROJECT" --engine both --token "$SECRET" \
	--sonar-host-url "$PLAINTEXT_HOST"
expect_rc "plaintext refusal, --engine both: degrades to IntelliJ alone, exit 0" 0
stdout_has "plaintext refusal, --engine both: an agent reading only stdout learns the reason" \
	"INSPECT_SONAR_SKIPPED_REASON=refusing to send the Sonar token in the clear to the non-loopback plaintext host $PLAINTEXT_HOST"
stdout_not_has "plaintext refusal, --engine both: and there is no sonar.json key to mislead it" \
	"INSPECT_SONAR_OUTPUT"
stdout_not_has "plaintext refusal, --engine both: nor an exposure warning, because nothing was exposed" \
	"INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING"
equals "plaintext refusal, --engine both: degrading is not fail-open — no request was sent" \
	"$(curl_call_count)" "0"

# --- --allow-plaintext-token accepts the exposure, and SAYS SO ON STDOUT -----
# The escape hatch for an operator on a trusted internal network. It is not a
# silent one: the condition is published as a machine-readable key, because stderr
# — where the matching warning goes — is documented as a channel an agent caller
# does not parse, and a credential-transport decision that only ever surfaces there
# is exactly the fail-open the refusal above exists to close.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full token-plaintext-allowed "$SONAR_PROJECT" --token "$SECRET" \
	--sonar-host-url "$PLAINTEXT_HOST" --allow-plaintext-token
expect_rc "plaintext allowed: the run proceeds, exit 0" 0
stdout_has "plaintext allowed: the exposure reaches the MACHINE channel as its own key" \
	"INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING=the Sonar token was sent over plaintext http to the non-loopback host $PLAINTEXT_HOST because --allow-plaintext-token was given"
stdout_has "plaintext allowed: alongside the sonar.json the run really did produce" \
	"INSPECT_SONAR_OUTPUT=$OUT"
stderr_has "plaintext allowed: and the human channel warns about it too" \
	"the Sonar token was sent over plaintext http to the non-loopback host $PLAINTEXT_HOST"
file_has "plaintext allowed: the token really did travel, so this is a disclosure not a refusal" \
	"$CURL_STUB_CONFIG_LOG" "user = \"$SECRET:\""
rm -rf "$SONAR_PROJECT/.scannerwork"

# --- the two exemptions, each asserted for the reason it exists --------------
# Both are asserted by the REFUSAL BEING ABSENT plus the run reaching the SERVER
# PROBE, which is the next step after the plaintext gate. The second half is what
# makes these falsifiable: "the refusal message is absent" alone would also pass if
# the run had failed one step earlier for an unrelated reason.
curl_stub_reset
curl_stub_route '/api/system/status' '{"status":"DOWN"}' 200
inspect full token-loopback "$SONAR_PROJECT" --token "$SECRET" --sonar-host-url 'http://127.0.0.1:9000'
stderr_not_has "loopback is exempt: no refusal, because that is the normal local setup" \
	"refusing to send the Sonar token in the clear"
stderr_has "loopback is exempt: and the run went on to probe the server" \
	"no SonarQube server reporting UP at http://127.0.0.1:9000"

curl_stub_reset
curl_stub_route '/api/system/status' '{"status":"DOWN"}' 200
inspect full token-https "$SONAR_PROJECT" --token "$SECRET" \
	--sonar-host-url 'https://sonar.example.invalid'
stderr_not_has "https is exempt: an encrypted transport is not an exposure" \
	"refusing to send the Sonar token in the clear"
stderr_has "https is exempt: and the run went on to probe the server" \
	"no SonarQube server reporting UP at https://sonar.example.invalid"

# ===========================================================================
section "a token carrying a non-printable byte is refused EARLY, and by name"
# ===========================================================================
# The realistic accident is a trailing newline from a `cat`-ed secret file or a CR
# from a Windows-authored env file; the deliberate version is config injection,
# since curl's `-K` format is LINE-ORIENTED and a newline in the token ends the
# `user = "…"` directive and turns everything after it into further curl options.
# Both are refused rather than repaired.
#
# WHY "EARLY" IS PART OF THE CLAIM. sonar_ensure_credentials is the enforcing sink,
# but detect_sonar checks the same thing first so the operator gets a NAMED
# diagnostic instead of a misleading downstream one — a token that reached the
# request would surface as "no server reporting UP", which points at the server.
# The stderr_not_has below is what makes that an ordering claim rather than two
# independent passes.

# assert_token_refused TAG BYTE_LABEL TOKEN — the same five claims for each control
# byte a real token can plausibly carry. Parameterized rather than written twice:
# the scenario is identical and only the byte differs, so two hand-copied blocks
# would be a place for the two to drift apart.
assert_token_refused() {
	atr_tag=$1
	atr_label=$2
	atr_token=$3
	# The full happy path, for a run that must never reach it — see the userinfo
	# section for why an unrouted call would otherwise be what the exit code
	# actually measures.
	curl_stub_reset
	route_healthy_server
	route_successful_task
	route_passing_gate
	route_issues 0 ''
	inspect full "$atr_tag" "$SONAR_PROJECT" --token "$atr_token"
	expect_rc "$atr_label token: exit 1" 1
	stderr_has "$atr_label token: the byte class is named, and so is what to check" \
		"the Sonar token contains a non-printable byte (a newline, a carriage return, a tab or a non-ASCII byte) and is refused"
	stderr_has "$atr_label token: with the usual cause named as a remedy" \
		"a stray newline is the usual cause"
	stderr_not_has "$atr_label token: and NOT the misleading downstream diagnostic" \
		"no SonarQube server reporting UP"
	equals "$atr_label token: no request was sent, so it never reached the -K config file" \
		"$(curl_call_count)" "0"
	stderr_not_has "$atr_label token: the token's own value is never echoed" "squ_bad"
}

assert_token_refused token-cr 'a carriage-return-bearing' "$(printf 'squ_bad\rtoken')"
assert_token_refused token-lf 'a newline-bearing' "$(printf 'squ_bad\ntoken')"

# ===========================================================================
section "the token is scrubbed from the IntelliJ child but kept for the scanner"
# ===========================================================================
# $SONAR_TOKEN is the channel this tool RECOMMENDS over --sonar-token, so an
# operator who followed that advice has it exported in the shell that runs this
# script — and importing a project into IntelliJ evaluates the project's OWN build
# logic (Gradle/Maven) and loads its plugins. Inheriting the token there would hand
# the inspected repository's code a live credential it has no use for.
#
# ONE RUN, BOTH CHILDREN, which is why this lives in the Sonar suite rather than
# the IntelliJ one: `--engine both` launches the scrubbed child and the child that
# genuinely needs the token from the same process, with the same token, so the two
# assertions cannot be satisfied by a token that simply never arrived.
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full token-child-scrub "$SONAR_PROJECT" --engine both --token "$SECRET"
expect_rc "child scrub: exit 0 — both engines ran" 0
log_has_token "child scrub: the IntelliJ child sees NO token" \
	"$IDEA_STUB_ENV_LOG" "SONAR_TOKEN=<unset>"
file_not_has "child scrub: and it is in no OTHER variable of that child's environment either" \
	"$IDEA_STUB_ENV_LOG" "$SECRET"
log_has_token "child scrub: while the scanner in the SAME run still receives it" \
	"$SCANNER_STUB_ENV_LOG" "SONAR_TOKEN=$SECRET"
rm -rf "$SONAR_PROJECT/.scannerwork"

# ===========================================================================
section "a credential file that could not be built is a HARD STOP"
# ===========================================================================
# `set -e` is suspended throughout sonar_ensure_credentials' call chain, so before
# each step was checked an unchecked failure left CURL_CONFIG_FILE EMPTY and the
# request went out with no credentials at all — surfacing as a puzzling
# "HTTP 401" from the server rather than as the real fault. Each of the three steps
# is forced in turn, and the claim in every case is the same and is the one that
# matters: the NAMED error is printed AND no request is sent.
CRED_SECRET='squ_cred_t0ken'

curl_stub_reset
route_healthy_server
inspect full cred-mktemp-fails "$SONAR_PROJECT" --token "$CRED_SECRET" --mktemp-fail
expect_rc "credential mktemp fails: exit 1" 1
stderr_has "credential mktemp fails: the real fault is named" \
	"could not create the curl config file that carries the Sonar token"
equals "credential mktemp fails: and NOT ONE request was sent, credential-less or otherwise" \
	"$(curl_call_count)" "0"
stderr_not_has "credential mktemp fails: so no HTTP status is reported to mislead the reader" \
	"HTTP 401"

curl_stub_reset
route_healthy_server
inspect full cred-chmod-fails "$SONAR_PROJECT" --token "$CRED_SECRET" --chmod-600 fail
expect_rc "credential chmod fails: exit 1" 1
stderr_has "credential chmod fails: the refusal names what it refuses to do" \
	"refusing to write the Sonar token to a world-readable file"
equals "credential chmod fails: and no request was sent" "$(curl_call_count)" "0"
# NOT ASSERTED HERE, and the omission is deliberate: "the half-built file is
# removed". It reads like the natural companion claim, but it cannot fail. The step
# removes the file on its own; and when the removal is mutated away, cleanup()
# removes it anyway once CURL_CONFIG_FILE has been published — so a `path_absent`
# on it passes whether the behaviour works or not. Caught by mutation while writing
# this section, and left out rather than shipped as false confidence.

# The token WRITE is reached by leaving the file read-only rather than by faking the
# write: `chmod 400` succeeds, so the step under test fails on a real filesystem
# permission error. See lib/stubs.sh's init_chmod_stub.
curl_stub_reset
route_healthy_server
inspect full cred-write-fails "$SONAR_PROJECT" --token "$CRED_SECRET" --chmod-600 readonly
expect_rc "credential write fails: exit 1" 1
stderr_has "credential write fails: the file it could not write to is named" \
	"could not write the Sonar token to"
equals "credential write fails: and no request was sent" "$(curl_call_count)" "0"
equals "credential write fails: the file really was created, so the WRITE is what failed" \
	"$(grep -c 'inspect-project.curl' "$MKTEMP_STUB_LOG" || true)" "1"

# --- transport hardening ----------------------------------------------------
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full transport "$SONAR_PROJECT"
log_not_has_token "transport: never follows redirects (-L would retarget an authenticated request)" \
	"$CURL_STUB_ARGV_LOG" "-L"
log_not_has_token "transport: never disables certificate verification" \
	"$CURL_STUB_ARGV_LOG" "-k"
log_not_has_token "transport: nor its long form" "$CURL_STUB_ARGV_LOG" "--insecure"
rm -rf "$SONAR_PROJECT/.scannerwork"

# ===========================================================================
section "the scanner's own invocation"
# ===========================================================================
curl_stub_reset
route_healthy_server
route_successful_task
route_passing_gate
route_issues 0 ''
inspect full scanner-argv "$SONAR_PROJECT" --sonar-host-url 'http://localhost:9000'
log_has_token "scanner: it is told which host to publish to" \
	"$SCANNER_STUB_ARGV_LOG" "-Dsonar.host.url=http://localhost:9000"
log_has_token "scanner: and which directory is the project base" \
	"$SCANNER_STUB_ARGV_LOG" "-Dsonar.projectBaseDir=$SONAR_PROJECT"
log_has_token "scanner: and it runs WITH the project as its cwd" \
	"$SCANNER_STUB_ARGV_LOG" "CWD=$(cd "$SONAR_PROJECT" && pwd)"
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
inspect full scanner-fails "$SONAR_PROJECT" --scanner-exit 17
expect_rc "scanner failure: exit 1" 1
stderr_has "scanner failure: the exit status is reported" "sonar-scanner failed (exit 17)"

curl_stub_reset
route_healthy_server
inspect full scanner-no-key "$SONAR_PROJECT" --report-task 'serverUrl=http://localhost:9000'
expect_rc "no projectKey in report-task.txt: exit 1" 1
stderr_has "no projectKey: the file that should have carried it is named" \
	"no projectKey in $SONAR_PROJECT/.scannerwork/report-task.txt"
rm -rf "$SONAR_PROJECT/.scannerwork"

curl_stub_reset
route_healthy_server
inspect full scanner-no-task "$SONAR_PROJECT" --report-task "projectKey=$PROJECT_KEY"
expect_rc "no ceTaskId in report-task.txt: exit 1" 1
stderr_has "no ceTaskId: the analysis cannot be followed, and it says so" \
	"cannot follow the analysis"
rm -rf "$SONAR_PROJECT/.scannerwork"

# ===========================================================================
section "the machine channel is byte-exact where the human channel is filtered"
# ===========================================================================
# lib/runtime.sh filters the C0 control bytes out of every DIAGNOSTIC, because a
# maliciously named file or directory in an inspected repository is a
# terminal-injection sink: ESC starts an ANSI/OSC sequence that can rewrite what is
# already on screen or plant text in the operator's input buffer.
#
# STDOUT IS DELIBERATELY NOT FILTERED, and this test exists so that stays a
# DELIBERATE choice rather than an accident either way. It is the machine channel:
# a consumer parsing `INSPECT_SONAR_SKIPPED_REASON=<text>` needs the path it names
# to be the path that is really on disk, and silently rewriting bytes out of it
# would hand that consumer a path that does not exist.
#
# THE PROJECT PATH IS THE VEHICLE because it is the one caller-supplied string that
# reaches BOTH channels in the same run: `--engine both` with Sonar unavailable
# warns the reason to stderr and publishes the same reason to stdout, and the
# reason quotes --project verbatim. The stderr counterpart of this test — a report
# FILENAME through the warn() writer — lives in run-intellij-tests.sh.
ESC=$(printf '\033')
ESC_PROJECT=$(new_project "evil${ESC}[31mproj" src/main.rs)

curl_stub_reset
route_healthy_server
inspect noscanner esc-channels "$ESC_PROJECT" --engine both
expect_rc "ESC in the project path: the run still succeeds, degraded to IntelliJ" 0
equals "ESC in the project path: stderr carries ZERO control bytes — every diagnostic is filtered" \
	"$(control_byte_count "$CUR_ERR")" "0"
stderr_has "ESC in the project path: while the surrounding text and the printable remainder survive intact" \
	"no Sonar project config under $WORK/projects/evil[31mproj"
equals "ESC in the project path: stdout carries exactly the one ESC byte, unfiltered" \
	"$(control_byte_count "$CUR_OUT")" "1"
stdout_has "ESC in the project path: because the machine channel reports the path that is really on disk" \
	"no Sonar project config under $ESC_PROJECT"

summarize
