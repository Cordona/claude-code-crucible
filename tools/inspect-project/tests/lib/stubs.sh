# shellcheck shell=sh
#
# stubs.sh — the four external boundaries inspect-project.sh crosses, each faked
#            as a real executable placed in its OWN directory so a suite opts a
#            boundary IN by putting that directory on PATH and opts it OUT by
#            leaving it off. "sonar-scanner is not on PATH" is therefore exercised
#            for real, not simulated.
#
# WHY STUBS AND NOT THE REAL TOOLS. Three of the four are genuinely unrunnable in
# a test: the IntelliJ CLI needs a licensed IDE and minutes per invocation,
# sonar-scanner needs a SonarQube server, and `curl` would make a network call.
# The fourth, `date`, is the wall clock — stubbed so the run directory's
# YYYY/MM/DD/HH-MM-SS name is an assertable constant and so the same-second
# collision path is reachable at all. `git` is deliberately NOT stubbed: the index
# save/restore dance is the highest-risk logic in this tool and only real git
# semantics can verify it (see run-git-tests.sh).
#
# WHY A CANNED-RESPONSE `curl` AND NOT AN HTTP SERVER. sonar.sh reaches the server
# exclusively through sonar_curl -> curl, so curl IS the boundary; faking it needs
# no background process, which means no stub server can outlive a test run. It is
# also the shape procedure-jira's suites already established.
#
# EVERY STUB RECORDS WHAT IT WAS ASKED TO DO. The argv logs are how a test proves
# the exact invocation (`-changes` present or absent, the token NEVER an argv
# token), and the scanner's environment log is how the token's `$SONAR_TOKEN`
# handoff is proven positively rather than only by the absence of an argv match.
#
# Sourced by the test suites — never executed directly.

# ---------------------------------------------------------------------------
# The IntelliJ CLI
# ---------------------------------------------------------------------------
# init_idea_stub STUB_DIR — write a fake `idea` that stands in for the headless
# CLI. Controlled per test through the environment harness_run forwards:
#   IDEA_STUB_ARGV_LOG      where to append `CWD=<dir>`, then
#                           `EDIR_LOCK_PRESENT=yes|no`, then one argv token per
#                           line. The lock line is recorded because the moment the
#                           CLI is running is the ONLY moment the reservation can
#                           be observed at all — it is taken just before the launch
#                           and released just after, so nothing before or after the
#                           run can tell an atomic `mkdir` reservation apart from a
#                           bare `[ -e ]` check that creates nothing. Established
#                           by mutation: replacing the `mkdir` with `[ -e ]` left
#                           every other assertion in the suite green.
#   IDEA_STUB_ENV_LOG       where to append this child's OWN ENVIRONMENT: the
#                           `$SONAR_TOKEN` line first, then a full `env` dump
#                           between ENV_BEGIN/ENV_END markers. It is the only way
#                           to observe lib/intellij.sh's `unset SONAR_TOKEN`, which
#                           scopes the scrub to this child alone and so leaves no
#                           trace anywhere the parent process can be asked about.
#                           The full dump is what makes the claim "the token is in
#                           NO variable of this child" rather than only "not in the
#                           one variable this stub thought to look at".
#   IDEA_STUB_EDIR_SRC      a fixture directory copied to `./-e/` in the CWD;
#                           empty means "write no report directory at all"
#   IDEA_STUB_EDIR_AS_FILE  write `./-e` as a PLAIN FILE instead of a directory.
#                           Not a contrived shape: the script has reserved that
#                           name and armed its teardown by this point, so the
#                           question "does the teardown remove a node that is not
#                           the directory it expected" is only reachable by
#                           leaving one — and leaving it behind makes every later
#                           run on that project refuse until a human intervenes.
#   IDEA_STUB_EXIT          the exit status to end with (default 0)
#   IDEA_STUB_SIGNAL_PARENT a signal name to send to the invoking script before
#                           exiting, for the interrupted-run teardown tests
#
# It writes `./-e/` rather than the directory named by the output argument
# BECAUSE THAT IS WHAT THE REAL CLI DOES — the whole reason lib/intellij.sh reads
# from there. A stub that honoured the output argument would make the tests pass
# against a script that had lost the workaround.
init_idea_stub() {
	cat >"$1/idea" <<'IDEA_STUB'
#!/usr/bin/env sh
set -eu

if [ -n "${IDEA_STUB_ARGV_LOG:-}" ]; then
	lock_present=no
	if [ -d ./-e.lock ]; then lock_present=yes; fi
	{
		printf 'CWD=%s\n' "$PWD"
		printf 'EDIR_LOCK_PRESENT=%s\n' "$lock_present"
		for a in "$@"; do printf '%s\n' "$a"; done
	} >>"$IDEA_STUB_ARGV_LOG"
fi

if [ -n "${IDEA_STUB_ENV_LOG:-}" ]; then
	{
		printf 'SONAR_TOKEN=%s\n' "${SONAR_TOKEN:-<unset>}"
		printf 'ENV_BEGIN\n'
		env 2>/dev/null || true
		printf 'ENV_END\n'
	} >>"$IDEA_STUB_ENV_LOG"
fi

if [ -n "${IDEA_STUB_EDIR_AS_FILE:-}" ]; then
	printf 'the CLI left a file where a report directory was expected\n' >./-e
elif [ -n "${IDEA_STUB_EDIR_SRC:-}" ]; then
	mkdir -p ./-e
	cp -R "$IDEA_STUB_EDIR_SRC/." ./-e/
fi

if [ -n "${IDEA_STUB_SIGNAL_PARENT:-}" ]; then
	kill -"$IDEA_STUB_SIGNAL_PARENT" "$PPID"
fi

exit "${IDEA_STUB_EXIT:-0}"
IDEA_STUB
	chmod +x "$1/idea"
}

# ---------------------------------------------------------------------------
# sonar-scanner
# ---------------------------------------------------------------------------
# init_scanner_stub STUB_DIR — write a fake `sonar-scanner`. Records its argv AND
# the `$SONAR_TOKEN` it was handed, which together are the two halves of the
# "the token never reaches any argv" claim: absent from one log, present in the
# other. Writes `.scannerwork/report-task.txt` in the CWD from
# SCANNER_STUB_REPORT_TASK, which is the scanner's own authoritative record and
# the only place lib/sonar.sh will look for the project key and the task id.
init_scanner_stub() {
	cat >"$1/sonar-scanner" <<'SCANNER_STUB'
#!/usr/bin/env sh
set -eu

if [ -n "${SCANNER_STUB_ARGV_LOG:-}" ]; then
	{
		printf 'CWD=%s\n' "$PWD"
		for a in "$@"; do printf '%s\n' "$a"; done
	} >>"$SCANNER_STUB_ARGV_LOG"
fi

if [ -n "${SCANNER_STUB_ENV_LOG:-}" ]; then
	printf 'SONAR_TOKEN=%s\n' "${SONAR_TOKEN:-<unset>}" >>"$SCANNER_STUB_ENV_LOG"
fi

if [ -n "${SCANNER_STUB_REPORT_TASK:-}" ]; then
	mkdir -p ./.scannerwork
	printf '%s\n' "$SCANNER_STUB_REPORT_TASK" >./.scannerwork/report-task.txt
fi

exit "${SCANNER_STUB_EXIT:-0}"
SCANNER_STUB
	chmod +x "$1/sonar-scanner"
}

# ---------------------------------------------------------------------------
# curl — a ROUTE-keyed canned-response stub
# ---------------------------------------------------------------------------
# WHY ROUTES AND NOT A CALL-ORDER QUEUE (procedure-jira's shape): one Sonar run
# hits four different endpoints and the number of calls to two of them is exactly
# what several tests are about — a compute-engine poll repeats one URL an
# unpredictable number of times, and issue paging walks a different URL per page.
# Keying on the URL lets a test say "the poll is IN_PROGRESS twice then SUCCESS"
# and "page 2 exists" independently, instead of hand-counting a global sequence
# that a change in an unrelated call would shift.
#
# A route may hold a SEQUENCE of responses; the last one sticks once the sequence
# is exhausted, which is what makes an unbounded-poll test expressible.
#
# init_curl_stub STUB_DIR WORK_DIR — write the stub and point the control
# variables at WORK_DIR. STUB_DIR must contain nothing else, so a test can put
# exactly `curl` on PATH.
init_curl_stub() {
	ics_stub_dir=$1
	ics_work_dir=$2

	CURL_STUB_DIR="$ics_work_dir/curlroutes"
	CURL_STUB_ARGV_LOG="$ics_work_dir/curl-argv.log"
	CURL_STUB_COUNTER="$ics_work_dir/curl-counter"
	CURL_STUB_CONFIG_LOG="$ics_work_dir/curl-config.log"

	cat >"$ics_stub_dir/curl" <<'CURL_STUB'
#!/usr/bin/env sh
set -eu

n=0
if [ -f "$CURL_STUB_COUNTER" ]; then n=$(cat "$CURL_STUB_COUNTER"); fi
n=$((n + 1))
printf '%s' "$n" >"$CURL_STUB_COUNTER"

{
	printf 'CALL_%s_BEGIN\n' "$n"
	for a in "$@"; do printf '%s\n' "$a"; done
	printf 'CALL_%s_END\n' "$n"
} >>"$CURL_STUB_ARGV_LOG"

out_file=""
config_file=""
url=""
prev=""
for a in "$@"; do
	if [ "$prev" = "-o" ]; then out_file=$a; fi
	if [ "$prev" = "-K" ]; then config_file=$a; fi
	url=$a
	prev=$a
done

# The `-K` file's MODE and CONTENT are recorded because the script deletes the
# file on teardown, so this is the only moment either can be observed — and both
# are the substance of the "the token travels in a 600-mode config file" claim.
if [ -n "$config_file" ]; then
	{
		printf 'CALL_%s_CONFIG_MODE=%s\n' "$n" "$(ls -l "$config_file" | cut -d' ' -f1)"
		cat "$config_file"
	} >>"$CURL_STUB_CONFIG_LOG"
fi

route=0
matched=0
while IFS= read -r token; do
	route=$((route + 1))
	case "$url" in
		*"$token"*) matched=$route; break ;;
	esac
done <"$CURL_STUB_DIR/routes"

if [ "$matched" -eq 0 ]; then
	printf 'STUB curl: no route configured for url=%s\n' "$url" >&2
	exit 99
fi

seq_file="$CURL_STUB_DIR/r$matched.seq"
seq=0
if [ -f "$seq_file" ]; then seq=$(cat "$seq_file"); fi
seq=$((seq + 1))
printf '%s' "$seq" >"$seq_file"
# Clamp to the last configured response so an exhausted sequence keeps serving
# its final state rather than failing the call.
while [ ! -f "$CURL_STUB_DIR/r$matched.$seq.body" ] && [ "$seq" -gt 1 ]; do
	seq=$((seq - 1))
done

code=$(cat "$CURL_STUB_DIR/r$matched.$seq.code")
if [ "$code" = "TRANSPORT_FAILURE" ]; then
	printf 'STUB curl: simulated transport failure for url=%s\n' "$url" >&2
	exit 7
fi

if [ -n "$out_file" ]; then cat "$CURL_STUB_DIR/r$matched.$seq.body" >"$out_file"; fi
printf '%s' "$code"
CURL_STUB
	chmod +x "$ics_stub_dir/curl"
}

# curl_stub_reset — drop every route, response, counter and log. Call before
# EVERY test that uses curl, so no assertion can read a previous test's log.
curl_stub_reset() {
	rm -rf "$CURL_STUB_DIR"
	mkdir -p "$CURL_STUB_DIR"
	: >"$CURL_STUB_DIR/routes"
	: >"$CURL_STUB_ARGV_LOG"
	: >"$CURL_STUB_CONFIG_LOG"
	printf '0' >"$CURL_STUB_COUNTER"
}

# curl_stub_route URL_SUBSTRING BODY CODE — any request whose URL contains
# URL_SUBSTRING answers with BODY and CODE. Calling it repeatedly with the SAME
# substring appends to that route's response sequence. CODE may be the literal
# TRANSPORT_FAILURE to make curl itself fail (a down server, not an HTTP error).
curl_stub_route() {
	csr_token=$1
	csr_idx=$(grep -Fxn -- "$csr_token" "$CURL_STUB_DIR/routes" | head -n 1 | cut -d: -f1)
	if [ -z "$csr_idx" ]; then
		printf '%s\n' "$csr_token" >>"$CURL_STUB_DIR/routes"
		csr_idx=$(grep -c . "$CURL_STUB_DIR/routes")
	fi
	csr_seq=1
	while [ -f "$CURL_STUB_DIR/r$csr_idx.$csr_seq.body" ]; do
		csr_seq=$((csr_seq + 1))
	done
	printf '%s' "$2" >"$CURL_STUB_DIR/r$csr_idx.$csr_seq.body"
	printf '%s' "$3" >"$CURL_STUB_DIR/r$csr_idx.$csr_seq.code"
}

# curl_call_count -> how many curl calls the last run made.
curl_call_count() { cat "$CURL_STUB_COUNTER" 2>/dev/null || printf '0'; }

# ---------------------------------------------------------------------------
# git — a PASS-THROUGH recorder, not a fake
# ---------------------------------------------------------------------------
# init_git_recorder STUB_DIR — a `git` that logs its argv and then EXECS THE REAL
# GIT. It is not a stub in the sense the other four are: every command still runs
# for real, so the index tests keep real git semantics (see gitfixture.sh for why
# that is non-negotiable here). It buys two things a real git cannot:
#
#   * a negative claim becomes assertable. "`--scope all` never touches git" is
#     provable only by observing that NO git command ran — an empty log — which no
#     before/after comparison of repository state can establish, since an
#     `add` followed by a perfect `reset` also leaves state unchanged.
#   * a restore FAILURE becomes constructable. lib/gitscope.sh promises a failed
#     restore exits non-zero even on an otherwise-successful run, and the real
#     causes (a refusing hook, a full disk, a concurrent index.lock) cannot be
#     induced from a test. GIT_STUB_FAIL_TOKENS names the command to fail: the
#     stub fails when EVERY listed token appears in the argv, which is what lets a
#     test target the re-stage `add` (`add <path>`) without also failing the
#     stage-all `add` (`add -A -- .`).
init_git_recorder() {
	igr_real=$(real_tool git)
	cat >"$1/git" <<GIT_RECORDER
#!/usr/bin/env sh
set -eu

if [ -n "\${GIT_STUB_ARGV_LOG:-}" ]; then
	{
		printf 'GIT_CALL_BEGIN\n'
		for a in "\$@"; do printf '%s\n' "\$a"; done
		printf 'GIT_CALL_END\n'
	} >>"\$GIT_STUB_ARGV_LOG"
fi

if [ -n "\${GIT_STUB_FAIL_TOKENS:-}" ]; then
	all_present=1
	for want in \$GIT_STUB_FAIL_TOKENS; do
		found=0
		for a in "\$@"; do
			if [ "\$a" = "\$want" ]; then found=1; break; fi
		done
		if [ "\$found" -eq 0 ]; then all_present=0; break; fi
	done
	if [ "\$all_present" -eq 1 ]; then
		printf 'STUB git: injected failure for: %s\n' "\$GIT_STUB_FAIL_TOKENS" >&2
		exit 128
	fi
fi

exec '$igr_real' "\$@"
GIT_RECORDER
	chmod +x "$1/git"
}

# ---------------------------------------------------------------------------
# date — the wall clock
# ---------------------------------------------------------------------------
# init_date_stub STUB_DIR — answer the two formats inspect-project asks for with
# fixed values (DATE_STUB_LOCAL for the run directory's YYYY/MM/DD/HH-MM-SS,
# DATE_STUB_UTC for the JSON `generated_at`) and delegate anything else to the
# real binary, whose path is baked in here rather than passed through the
# environment so a test cannot accidentally un-set it.
init_date_stub() {
	ids_real=$(real_tool date)
	cat >"$1/date" <<DATE_STUB
#!/usr/bin/env sh
set -eu
case "\$*" in
	*'+%Y/%m/%d/%H-%M-%S'*)  printf '%s\n' "\$DATE_STUB_LOCAL" ;;
	*'+%Y-%m-%dT%H:%M:%SZ'*) printf '%s\n' "\$DATE_STUB_UTC" ;;
	*) exec '$ids_real' "\$@" ;;
esac
DATE_STUB
	chmod +x "$1/date"
}

# ---------------------------------------------------------------------------
# tr — a PASS-THROUGH recorder that can fail ONE specific translation
# ---------------------------------------------------------------------------
# init_tr_stub STUB_DIR — a `tr` that delegates every call to the real binary
# except the NUL-to-newline decode, which it can be made to fail on a chosen
# occurrence.
#
# WHY A STUB AND NOT A REAL CONDITION. lib/gitscope.sh checks the status of both
# its `tr '\0' '\n'` calls because a failed decode leaves an EMPTY file that is
# indistinguishable from "the work tree is clean" (collect_changed_files) or from
# "nothing was staged" (stage_all_changes) — a false-clean run and a discarded
# staging area respectively. The real causes are an exhausted TMPDIR or a killed
# child; neither is inducible from a test without also breaking the ~30 other
# temp files the run needs, which would fail the run for the wrong reason.
#
# NARROWLY SCOPED, DELIBERATELY: only the exact `\0` `\n` argument pair is
# eligible to fail, so the three OTHER `tr` calls a run makes
# (count_changed_files' `tr -d`, sanitize_path_component's `tr -c`,
# csv_to_lines' `tr ','`) keep working and cannot mask which check fired.
#
#   TR_STUB_FAIL_NUL_CALL   which NUL-decode occurrence to fail: `1` is
#                           collect_changed_files', `2` is stage_all_changes'.
#                           Empty disables the injection entirely.
#   TR_STUB_NUL_COUNTER     the file the occurrence count is kept in.
init_tr_stub() {
	its_real=$(real_tool tr)
	cat >"$1/tr" <<TR_STUB
#!/usr/bin/env sh
set -eu

if [ "\${1:-}" = '\\0' ] && [ "\${2:-}" = '\\n' ] && [ -n "\${TR_STUB_FAIL_NUL_CALL:-}" ]; then
	tr_n=0
	if [ -f "\$TR_STUB_NUL_COUNTER" ]; then tr_n=\$(cat "\$TR_STUB_NUL_COUNTER"); fi
	tr_n=\$((tr_n + 1))
	printf '%s' "\$tr_n" >"\$TR_STUB_NUL_COUNTER"
	if [ "\$tr_n" = "\$TR_STUB_FAIL_NUL_CALL" ]; then
		printf 'STUB tr: injected failure on NUL-decode call %s\n' "\$tr_n" >&2
		exit 1
	fi
fi

exec '$its_real' "\$@"
TR_STUB
	chmod +x "$1/tr"
}

# ---------------------------------------------------------------------------
# mktemp — a PASS-THROUGH recorder that can fail the Sonar credential file
# ---------------------------------------------------------------------------
# init_mktemp_stub STUB_DIR — a `mktemp` that delegates to the real binary but
# can refuse the ONE template lib/sonar.sh's sonar_ensure_credentials uses, and
# records the path it handed out for that template.
#
# Narrowly scoped for the same reason the `tr` stub is: `mktemp -d` also creates
# the run's whole WORKDIR, and a blanket failure would abort the run before the
# credential code is ever reached.
#
# The RECORDED PATH is what makes "the file is removed when a later step fails"
# assertable at all — the script deletes it and nothing else ever learns its name.
#
#   MKTEMP_STUB_FAIL_CURL_CONFIG  non-empty: refuse that template
#   MKTEMP_STUB_LOG               where the handed-out path is appended
init_mktemp_stub() {
	ims_real=$(real_tool mktemp)
	cat >"$1/mktemp" <<MKTEMP_STUB
#!/usr/bin/env sh
set -eu

mk_is_curl_config=0
for mk_a in "\$@"; do
	case "\$mk_a" in
		*inspect-project.curl.*) mk_is_curl_config=1 ;;
	esac
done

if [ "\$mk_is_curl_config" -eq 1 ] && [ -n "\${MKTEMP_STUB_FAIL_CURL_CONFIG:-}" ]; then
	printf 'STUB mktemp: injected failure for the Sonar credential template\n' >&2
	exit 1
fi

mk_out=\$('$ims_real' "\$@")
if [ "\$mk_is_curl_config" -eq 1 ] && [ -n "\${MKTEMP_STUB_LOG:-}" ]; then
	printf '%s\n' "\$mk_out" >>"\$MKTEMP_STUB_LOG"
fi
printf '%s\n' "\$mk_out"
MKTEMP_STUB
	chmod +x "$1/mktemp"
}

# ---------------------------------------------------------------------------
# chmod — a PASS-THROUGH recorder that can subvert the `chmod 600`
# ---------------------------------------------------------------------------
# init_chmod_stub STUB_DIR — a `chmod` that delegates to the real binary except
# for the `600` lib/sonar.sh applies to its credential file, which it can either
# FAIL or quietly apply as `400` instead.
#
# The `400` mode is how the THIRD credential step is reached: with the file left
# read-only, sonar_ensure_credentials' own `printf > "$sec_file"` genuinely fails
# on a real filesystem, so the token-write check is exercised by a real write
# error rather than by faking the write itself.
#
#   CHMOD_STUB_MODE_600   `fail` — exit non-zero on the `600` call
#                         `readonly` — apply 400 instead, and succeed
#                         empty — delegate everything
init_chmod_stub() {
	ics_real=$(real_tool chmod)
	cat >"$1/chmod" <<CHMOD_STUB
#!/usr/bin/env sh
set -eu

if [ "\${1:-}" = 600 ] && [ -n "\${CHMOD_STUB_MODE_600:-}" ]; then
	case "\$CHMOD_STUB_MODE_600" in
		fail)
			printf 'STUB chmod: injected failure for mode 600\n' >&2
			exit 1
			;;
		readonly)
			shift
			exec '$ics_real' 400 "\$@"
			;;
	esac
fi

exec '$ics_real' "\$@"
CHMOD_STUB
	chmod +x "$1/chmod"
}

# ---------------------------------------------------------------------------
# uname — the OS identity
# ---------------------------------------------------------------------------
# init_uname_stub STUB_DIR — `uname -s` answers UNAME_STUB_S. lib/runtime.sh
# reads it once into $OS_NAME, and is_macos() is what selects between the two
# IntelliJ-launcher strategies, so this is the only way to reach the non-macOS
# branch from a macOS test machine (and the macOS branch from a Linux one).
init_uname_stub() {
	ius_real=$(real_tool uname)
	cat >"$1/uname" <<UNAME_STUB
#!/usr/bin/env sh
set -eu
case "\${1:-}" in
	-s) printf '%s\n' "\$UNAME_STUB_S" ;;
	*) exec '$ius_real' "\$@" ;;
esac
UNAME_STUB
	chmod +x "$1/uname"
}

# ---------------------------------------------------------------------------
# ps — the process table
# ---------------------------------------------------------------------------
# init_ps_stub STUB_DIR — serve a FIXTURE process table to lib/intellij.sh's
# single-instance preflight, in the shape `ps -A -o pid= -o args=` emits: a
# right-aligned pid, then the whole command line.
#
# WHY A FIXTURE TABLE AND NOT REAL PROCESSES. Every claim about that preflight is
# a claim about WHICH command lines match the resolved binary path and — mostly —
# which deliberately do not: one that merely CONTAINS that path further along,
# one that extends it without a separator, one truncated short of it. Reaching
# those with real processes needs an executable per case and a live background
# process for the length of every run, and the table would STILL hold every other
# process on the machine, including this suite's own — whose argv carries the
# resolved path via --idea-bin, which is the precise false positive the anchoring
# exists to avoid. A fixture table is what lets a test state a negative about the
# WHOLE table.
#
# `ps` ITSELF is faked rather than only the table it reads, because "`ps` is not
# on PATH" and "`ps` ran and failed" are two separately-reached outcomes of the
# preflight (see refuse_if_idea_already_running) and the first is only reachable
# by leaving this directory off PATH — the same opt-in-by-PATH shape as every
# other stub here.
#
# It answers ANY argv rather than only the one form the tool asks for, so a
# changed request fails the argv assertion that names it instead of quietly
# serving an empty table that every other assertion then reads as "nothing is
# running".
#
#   PS_STUB_TABLE     file whose contents are served as the process table; empty
#                     means an empty table, in which nothing matches anything
#   PS_STUB_FAIL      non-empty: exit non-zero and serve nothing, which is the
#                     `ps` a hardened or minimal container host gives
#   PS_STUB_ARGV_LOG  where argv is appended, one token per line
init_ps_stub() {
	cat >"$1/ps" <<'PS_STUB'
#!/usr/bin/env sh
set -eu

if [ -n "${PS_STUB_ARGV_LOG:-}" ]; then
	{ for a in "$@"; do printf '%s\n' "$a"; done } >>"$PS_STUB_ARGV_LOG"
fi

if [ -n "${PS_STUB_FAIL:-}" ]; then
	printf 'STUB ps: injected process-table failure\n' >&2
	exit 1
fi

if [ -n "${PS_STUB_TABLE:-}" ]; then cat "$PS_STUB_TABLE"; fi
PS_STUB
	chmod +x "$1/ps"
}
