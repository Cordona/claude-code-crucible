# shellcheck shell=sh
#
# sonar.sh — the local SonarQube engine: availability detection, the scan, the
#            compute-engine wait, the quality gate, paged issue retrieval, and
#            sonar.json.
#
# =============================================================================
# Security — read before touching the token or curl code
# =============================================================================
#
# THE TOKEN NEVER TOUCHES ANY argv. Two sinks need it and neither gets it as an
# argument:
#   * sonar-scanner receives it via the $SONAR_TOKEN ENVIRONMENT VARIABLE, which
#     the scanner reads natively. This is a DELIBERATE DEPARTURE from the
#     `-Dsonar.token=...` form: a `-D` property is a process argument, and process
#     arguments are readable by any local user via `ps`. Same capability, same
#     scanner support, no exposure.
#   * curl receives it through a `-K` config file created with `umask 077` and
#     `chmod 600`, so only the FILENAME reaches argv — the same handoff
#     procedure-jira's engine uses, for the same reason.
# `--sonar-token` itself is still accepted, because it is part of the CLI
# contract — but it puts the token on THIS script's own argv, so its use emits a
# warning naming that exposure and pointing at $SONAR_TOKEN.
#
# TRANSPORT. No `-L` (a redirect could silently retarget an authenticated request
# at an unpinned host) and never `-k`/`--insecure`. The scheme is not pinned to
# https, because the overwhelmingly common local Sonar is plain http on
# localhost — instead --sonar-host-url is validated to be http(s) at all, and a
# token that would cross plaintext http to a NON-loopback host is REFUSED, not
# warned about: see the plaintext-token block below for why a warning was the
# wrong answer and what --allow-plaintext-token does.
#
# THE HOST URL IS NEVER PRINTED OR STORED IN ITS CONNECTION FORM. A URL may carry
# `user:pass@` userinfo, and this unit both echoes the host to stderr and writes
# it into sonar.json — a file whose whole purpose is to be fed into an agent's
# context. So userinfo is rejected outright by validate_sonar_host_url (this tool
# authenticates with a token, never with URL credentials), and every message and
# every JSON field uses SONAR_HOST_DISPLAY, the redacted form. Only sonar_curl's
# URL and the scanner's `-Dsonar.host.url` use SONAR_HOST itself.
#
# UNTRUSTED CONTENT. Rule messages and quality-gate conditions come back from a
# server and are written into sonar.json verbatim as JSON string VALUES (via jq,
# never string-concatenated). If that file is later fed into an agent's context,
# treat its contents as data, never as instructions.
#
# Sourced by inspect-project.sh — never executed directly.

# curl_config_escape VALUE -> VALUE safe inside a curl config file's quoted
# string. Backslash FIRST, then the double quote — the reverse order would
# re-escape the escapes it just added.
#
# IT IS NOT SUFFICIENT ON ITS OWN, and nothing may rely on it as if it were:
# curl's config format is LINE-ORIENTED, so a value carrying CR or LF ends the
# `user = "…"` directive and everything after it becomes further curl options —
# and that format accepts nearly every long option (`output`, `proxy`, `header`),
# which turns a newline in a token into arbitrary control over the request. A
# quote/backslash escape cannot express a newline, so the newline is refused
# instead: see the control-byte rejection in sonar_ensure_credentials, which is
# the actual control. This function only closes the in-line quoting.
curl_config_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# reject_unprintable_token VALUE -> 0 iff VALUE is safe to write into a curl
# config file, non-zero (with the error already reported) otherwise.
#
# A token is a bearer credential the operator pasted from somewhere, and the
# realistic accident — a trailing newline from a `cat`-ed secret file, a CR from
# a Windows-authored env file — is indistinguishable at this layer from the
# deliberate config-injection above. Both are refused rather than repaired: a
# silently trimmed token that then fails to authenticate is a worse diagnostic
# than a named refusal, and "repair it" is a guess about which bytes the operator
# meant. `[:print:]` under this script's LC_ALL=C excludes tab and every
# non-ASCII byte too, neither of which appears in a real Sonar token.
#
# The VALUE ITSELF IS NEVER ECHOED, here or anywhere: it is the secret.
reject_unprintable_token() {
	case "${1:-}" in
		*[![:print:]]*)
			error "the Sonar token contains a non-printable byte (a newline, a carriage return, a tab or a non-ASCII byte) and is refused"
			warn  "a stray newline is the usual cause — check how \$SONAR_TOKEN or --sonar-token was set (a \`cat\`-ed secret file keeps its trailing newline)"
			return 1
			;;
	esac
	return 0
}

# sonar_token_value -> the effective token: the flag if given, else the
# environment, else empty. $SONAR_TOKEN is the preferred channel (see the
# security note above).
sonar_token_value() {
	printf '%s' "${OPT_SONAR_TOKEN:-${SONAR_TOKEN:-}}"
}

# sonar_ensure_credentials — build the `-K` config file once, if there is a token
# at all. Anonymous access to a local Sonar is normal, so no token is not an
# error; it simply means no config file and no auth header. Returns non-zero only
# when there IS a token and the file for it could not be created.
#
# EVERY STEP IS CHECKED, and CURL_CONFIG_FILE is published only once all of them
# succeeded. `set -e` is suspended throughout this function's call chain (it is
# reached from sonar_curl, which every caller invokes as `f || …`), so an
# unchecked `mktemp` would leave the carrier EMPTY and send the request out with
# no credentials at all — surfacing as a puzzling "HTTP 401" rather than as the
# real fault. The file is removed on a later step's failure for the same reason:
# nothing else knows about a path that never became CURL_CONFIG_FILE.
sonar_ensure_credentials() {
	[ -z "$CURL_CONFIG_FILE" ] || return 0
	sec_token=$(sonar_token_value)
	[ -n "$sec_token" ] || return 0
	# The enforcing sink for the config-file injection surface: this is the
	# function that writes the token into a line-oriented format, so the refusal
	# lives here even though detect_sonar checks the same thing earlier to produce
	# a better diagnostic. Cheap, and it cannot be bypassed by a future caller
	# reaching this function some other way.
	reject_unprintable_token "$sec_token" || return 1

	sec_prev_umask=$(umask)
	umask 077
	sec_file=$(mktemp "${TMPDIR:-/tmp}/inspect-project.curl.XXXXXX") || sec_file=""
	umask "$sec_prev_umask"
	if [ -z "$sec_file" ]; then
		error "could not create the curl config file that carries the Sonar token"
		return 1
	fi

	if ! chmod 600 "$sec_file"; then
		error "could not restrict the permissions of $sec_file — refusing to write the Sonar token to a world-readable file"
		rm -f -- "$sec_file" 2>/dev/null || true
		return 1
	fi

	# Sonar's token auth is HTTP basic with the token as the username and an
	# empty password.
	if ! printf 'user = "%s:"\n' "$(curl_config_escape "$sec_token")" >"$sec_file"; then
		error "could not write the Sonar token to $sec_file"
		rm -f -- "$sec_file" 2>/dev/null || true
		return 1
	fi

	CURL_CONFIG_FILE=$sec_file
}

# sonar_curl PATH_AND_QUERY -> 0 on a 2xx, with the body in $SONAR_BODY_FILE and
# the status in $SONAR_HTTP_CODE. Every response goes to a FRESH file, so a
# caller holding an earlier path stays valid after a later call.
#
# The `-K` comes FIRST, immediately after `curl -sS`, and every other flag after
# it: curl applies options left to right and a later one wins, so hardening
# placed after the config file can never be overridden from inside it.
sonar_curl() {
	sc_path=$1
	sc_url="$SONAR_HOST$sc_path"
	# A credential file that could not be built is a hard stop, never a silent
	# fall-through to an unauthenticated request. The status carrier is set to the
	# same `000` a failed transfer uses, so a caller's "(HTTP $SONAR_HTTP_CODE)"
	# message cannot report a previous call's code as this one's.
	if ! sonar_ensure_credentials; then
		SONAR_HTTP_CODE=000
		return 1
	fi

	RESP_COUNTER=$((RESP_COUNTER + 1))
	SONAR_BODY_FILE="$WORKDIR/sonar-resp-$RESP_COUNTER.json"

	set -- curl -sS
	if [ -n "$CURL_CONFIG_FILE" ]; then
		set -- "$@" -K "$CURL_CONFIG_FILE"
	fi
	set -- "$@" -H 'Accept: application/json' \
		-o "$SONAR_BODY_FILE" -w '%{http_code}' "$sc_url"

	if ! SONAR_HTTP_CODE=$("$@" 2>/dev/null); then
		SONAR_HTTP_CODE=000
		return 1
	fi
	case "$SONAR_HTTP_CODE" in
		2??) return 0 ;;
	esac
	return 1
}

# url_authority URL -> the authority component of URL: everything after `://` up
# to the first `/`, `?` or `#`. Pure parameter expansion. A value with no `://`
# is treated as authority-first rather than as having none, because this is also
# reached for a MALFORMED value on its way into a rejection message, and
# `user:tok@host` typed without a scheme still carries a credential to redact.
url_authority() {
	case "$1" in
		*://*) ua_rest=${1#*://} ;;
		*)     ua_rest=$1 ;;
	esac
	ua_rest=${ua_rest%%/*}
	ua_rest=${ua_rest%%\?*}
	printf '%s' "${ua_rest%%#*}"
}

# redact_url_userinfo URL -> URL with any `user[:pass]@` in the authority
# replaced by `***@`, and control bytes stripped. The result is a DISPLAY and
# STORAGE form only — never hand it to curl or the scanner.
#
# The `***@` marker is left in place rather than removed entirely so a rejected
# URL's error message tells the operator WHY it was rejected; a host that looked
# identical to what they typed would read as a nonsense refusal.
redact_url_userinfo() {
	ruu_url=$1
	ruu_authority=$(url_authority "$ruu_url")
	case "$ruu_authority" in
		*@*) : ;;
		*) sanitize_for_terminal "$ruu_url"; return 0 ;;
	esac
	# The shortest prefix ending at the authority, i.e. the scheme and separator
	# when there is one and nothing when there is not.
	ruu_prefix=${ruu_url%%"$ruu_authority"*}
	ruu_tail=${ruu_url#"$ruu_prefix$ruu_authority"}
	sanitize_for_terminal "$ruu_prefix***@${ruu_authority#*@}$ruu_tail"
}

# validate_sonar_host_url URL -> 0 iff URL starts with `http://`/`https://`,
# contains only printable, space-free ASCII (`!`-`~`), and carries NO `user@` /
# `user:pass@` userinfo in its authority. That — and ONLY that — is what it
# enforces: it rejects a `file://` URL, a bare host, an empty value, a
# whitespace-bearing value, any non-ASCII or control byte, and a credential-
# bearing authority, before the value is used to build a request.
#
# WHY USERINFO IS REJECTED RATHER THAN CARRIED. This tool authenticates to Sonar
# with a token and nothing else — sonar-scanner would not use URL credentials at
# all, and curl's own `-K`-supplied `user` already wins over them — so accepting
# them buys no capability. What they cost is real: the host string is echoed to
# stderr and persisted into sonar.json's `metadata.sonar_host_url`, a file this
# tool exists to have fed into an agent's context, so a URL like
# `http://squ_xxx@sonar.corp:9000` would write a live credential into a results
# file. Rejecting the whole shape is the smallest fix that removes the sink; the
# redaction above then covers the one remaining print, the refusal message
# itself.
#
# IT IS NOT AN INJECTION CONTROL, and nothing may be built on the assumption that
# it is. `;`, `&`, `|`, `$` and a backtick are all inside the accepted `!`-`~`
# range and pass it. The URL is safe because it NEVER becomes part of a shell
# string: it reaches curl only as a single quoted argument, and sonar-scanner only
# as a single quoted `-D` property. Keep it that way — do not `eval` it, do not
# interpolate it into a `sh -c` string, and do not treat this function as
# permission to.
validate_sonar_host_url() {
	case "${1:-}" in
		http://*|https://*) : ;;
		*) return 1 ;;
	esac
	case "$1" in
		*[!!-~]*) return 1 ;;
	esac
	case "$(url_authority "$1")" in
		*@*) return 1 ;;
	esac
	return 0
}

# sonar_token_crosses_plaintext -> 0 iff there is a token AND the configured host
# is plaintext http to something other than loopback, i.e. the token would be
# readable by anything on the path.
sonar_token_crosses_plaintext() {
	[ -n "$(sonar_token_value)" ] || return 1
	case "$SONAR_HOST" in
		https://*) return 1 ;;
		http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*|http://\[::1\]|http://\[::1\]:*) return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# The plaintext-token decision — REFUSED by default, not warned about
#
# WHY THIS IS NOT A WARNING ANY MORE. It used to be one, on the reasoning that
# the server is the caller's own and the risk is theirs to accept. That reasoning
# holds for a human reading stderr and fails for the caller this tool is built
# for: an agent, which this script's own contract documents as parsing STDOUT and
# not stderr. So a host named in an instruction an agent picked up while
# processing the inspected repository could exfiltrate the operator's Sonar token
# to it, with the machine channel showing nothing wrong — fail-open on a
# credential-transport decision, decided by the channel least likely to be read.
#
# So the default is refusal, and the escape hatch is an explicit flag
# (--allow-plaintext-token) that an operator on a trusted internal network can
# pass deliberately. When it IS passed, the condition is additionally published
# on stdout as INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING, so neither branch leaves the
# machine channel silent about a credential in the clear.
#
# THE REFUSAL IS EXPRESSED AS "SONAR IS UNAVAILABLE", WHICH IS DELIBERATE, and it
# reuses this script's existing engine-availability policy rather than adding a
# second exit path with different semantics: `--engine sonar` becomes a HARD
# FAILURE (exit 1, with this reason as the error — the refusal the finding asks
# for), while `--engine both` degrades to IntelliJ alone and carries the reason
# out on stdout as INSPECT_SONAR_SKIPPED_REASON. Degrading is not fail-open here:
# the token is never sent, and the machine channel says why Sonar did not run.
# ---------------------------------------------------------------------------

# sonar_server_is_up -> 0 iff the configured host answers with status UP.
sonar_server_is_up() {
	sonar_curl "/api/system/status" || return 1
	ssiu_status=$(jq -r '.status // ""' "$SONAR_BODY_FILE" 2>/dev/null || printf '')
	[ "$ssiu_status" = "UP" ]
}

# sonar_project_config_found -> 0 iff the project carries Sonar configuration.
#
# The properties file is authoritative; the build-file grep is explicitly
# best-effort (the plugin id or a projectKey property mentioned anywhere in
# pom.xml / build.gradle / build.gradle.kts). It answers only "is this project
# set up for Sonar at all" — the project KEY itself is read after the scan from
# report-task.txt, which is the scanner's own authoritative record and cannot
# drift from what was actually analyzed.
sonar_project_config_found() {
	[ ! -f "$OPT_PROJECT/sonar-project.properties" ] || return 0
	for spcf_file in pom.xml build.gradle build.gradle.kts; do
		if [ -f "$OPT_PROJECT/$spcf_file" ] && grep -q \
			-e 'sonar\.projectKey' -e 'org\.sonarqube' -e 'sonar-maven-plugin' -e 'sonarqube' \
			"$OPT_PROJECT/$spcf_file" 2>/dev/null
		then
			return 0
		fi
	done
	return 1
}

# detect_sonar — run all three availability checks and record each one's result,
# whatever the overall verdict. Idempotent: the interactive menu calls it to
# label the `sonar` option, and the run then reuses that verdict rather than
# re-probing the server.
detect_sonar() {
	[ "$SONAR_DETECTED" -eq 0 ] || return 0
	SONAR_DETECTED=1

	SONAR_HOST=$(strip_trailing_slashes "${OPT_SONAR_HOST_URL:-${SONAR_HOST_URL:-$SONAR_HOST_URL_DEFAULT}}")
	# Derived BEFORE the validation below, because the rejection message is itself
	# a print of the host and the value being rejected is exactly the kind that
	# carries a credential.
	SONAR_HOST_DISPLAY=$(redact_url_userinfo "$SONAR_HOST")

	ds_missing=""

	if ! validate_sonar_host_url "$SONAR_HOST"; then
		SONAR_AVAILABLE=0
		SONAR_SKIP_REASON="the Sonar host URL is not a plain http(s) origin with no embedded credentials: $SONAR_HOST_DISPLAY"
		return 0
	fi

	# Both of these make Sonar UNAVAILABLE rather than being repaired or warned
	# about, so the script's existing availability policy turns them into a hard
	# exit 1 for `--engine sonar` and a stdout-disclosed degrade for `--engine
	# both`. Neither ever sends the token: they are checked before the first
	# sonar_server_is_up probe, which would otherwise be the first thing to carry
	# it out. See the plaintext-token block above.
	if ! reject_unprintable_token "$(sonar_token_value)"; then
		SONAR_AVAILABLE=0
		SONAR_SKIP_REASON="the Sonar token contains a non-printable byte and was refused"
		return 0
	fi
	if sonar_token_crosses_plaintext; then
		if [ "$OPT_ALLOW_PLAINTEXT_TOKEN" -ne 1 ]; then
			SONAR_AVAILABLE=0
			SONAR_SKIP_REASON="refusing to send the Sonar token in the clear to the non-loopback plaintext host $SONAR_HOST_DISPLAY — use an https host, drop the token, or pass --allow-plaintext-token to accept the exposure deliberately"
			return 0
		fi
		SONAR_PLAINTEXT_TOKEN_WARNING="the Sonar token was sent over plaintext http to the non-loopback host $SONAR_HOST_DISPLAY because --allow-plaintext-token was given"
		warn "$SONAR_PLAINTEXT_TOKEN_WARNING"
	fi

	for ds_candidate in sonar-scanner sonar-scanner.bat; do
		if ds_path=$(command -v "$ds_candidate" 2>/dev/null); then
			SONAR_SCANNER_BIN=$ds_path
			SONAR_CHECK_SCANNER=true
			break
		fi
	done
	if [ "$SONAR_CHECK_SCANNER" != true ]; then
		ds_missing="${ds_missing}sonar-scanner is not on PATH; "
	fi

	# curl's absence is recorded as the SERVER check's reason rather than as a
	# separate precondition, so this function stays the single place that decides
	# Sonar availability: the interactive menu labels its `sonar` option from this
	# verdict, and a caller-facing "sonar unavailable" reason produced anywhere else
	# would make the two entry paths disagree about why.
	if ! command -v curl >/dev/null 2>&1; then
		ds_missing="${ds_missing}curl is not installed, so no SonarQube server can be reached; "
	elif sonar_server_is_up; then
		SONAR_CHECK_SERVER=true
	else
		ds_missing="${ds_missing}no SonarQube server reporting UP at $SONAR_HOST_DISPLAY; "
	fi

	if sonar_project_config_found; then
		SONAR_CHECK_CONFIG=true
	else
		ds_missing="${ds_missing}no Sonar project config under $OPT_PROJECT (looked for sonar-project.properties, or Sonar plugin/projectKey config in pom.xml, build.gradle, build.gradle.kts); "
	fi

	# shellcheck disable=SC2034  # SONAR_AVAILABLE/SONAR_SKIP_REASON are read by inspect-project.sh's engine-availability decision and lib/menu.sh/lib/output.sh; shellcheck lints each unit in isolation and cannot see a reader in a sibling
	if [ "$SONAR_CHECK_SCANNER" = true ] && [ "$SONAR_CHECK_SERVER" = true ] && [ "$SONAR_CHECK_CONFIG" = true ]; then
		SONAR_AVAILABLE=1
		SONAR_SKIP_REASON=""
	else
		SONAR_AVAILABLE=0
		SONAR_SKIP_REASON=${ds_missing%"; "}
	fi
}

# run_sonar_scan — the scan itself, from the project root.
run_sonar_scan() {
	rss_log="$WORKDIR/sonar-scanner.log"
	rss_token=$(sonar_token_value)

	note "Running sonar-scanner against $SONAR_HOST_DISPLAY — this can take several minutes..."

	rss_rc=0
	(
		cd "$OPT_PROJECT" || exit 1
		umask "$ORIG_UMASK"
		# The token enters the scanner's ENVIRONMENT, never its argv. Exported
		# inside this subshell only, so it is not inherited by anything else this
		# script runs afterwards.
		if [ -n "$rss_token" ]; then
			SONAR_TOKEN=$rss_token
			export SONAR_TOKEN
		fi
		exec "$SONAR_SCANNER_BIN" \
			"-Dsonar.host.url=$SONAR_HOST" \
			"-Dsonar.projectBaseDir=$OPT_PROJECT"
	) >"$rss_log" 2>&1 || rss_rc=$?

	if [ "$rss_rc" -ne 0 ]; then
		error "sonar-scanner failed (exit $rss_rc)"
		report_log_tail "$rss_log"
		return 1
	fi
}

# sonar_report_task_value KEY -> the value of KEY in the scanner's
# .scannerwork/report-task.txt. KEY is always an internal literal
# (`ceTaskId`/`projectKey`), never caller input, which is what makes
# interpolating it into a sed program safe here.
sonar_report_task_value() {
	srtv_key=$1
	srtv_file="$OPT_PROJECT/.scannerwork/report-task.txt"
	[ -r "$srtv_file" ] || return 1
	srtv_value=$(sed -n "s/^${srtv_key}=//p" "$srtv_file" 2>/dev/null | sed -n '1p' | tr -d '\r')
	[ -n "$srtv_value" ] || return 1
	printf '%s' "$srtv_value"
}

# sonar_wait_for_task TASK_ID -> sets SONAR_ANALYSIS_ID once the compute engine
# reports SUCCESS. A bounded, early-returning poll: it never waits forever, and
# FAILED/CANCELED/an unrecognized status all fail loudly rather than time out.
sonar_wait_for_task() {
	swft_task_id=$1
	swft_attempt=0
	swft_query="/api/ce/task?id=$(urlencode "$swft_task_id")"

	while [ "$swft_attempt" -lt "$SONAR_POLL_MAX_ATTEMPTS" ]; do
		swft_attempt=$((swft_attempt + 1))
		if ! sonar_curl "$swft_query"; then
			error "Sonar compute-engine task lookup failed (HTTP $SONAR_HTTP_CODE) for task $swft_task_id"
			return 1
		fi
		swft_status=$(jq -r '.task.status // ""' "$SONAR_BODY_FILE" 2>/dev/null || printf '')
		case "$swft_status" in
			SUCCESS)
				SONAR_ANALYSIS_ID=$(jq -r '.task.analysisId // ""' "$SONAR_BODY_FILE" 2>/dev/null || printf '')
				if [ -z "$SONAR_ANALYSIS_ID" ]; then
					error "the Sonar analysis of task $swft_task_id succeeded but reported no analysisId"
					return 1
				fi
				return 0
				;;
			FAILED|CANCELED)
				error "the Sonar compute-engine task $swft_task_id ended $swft_status"
				return 1
				;;
			PENDING|IN_PROGRESS)
				: ;;
			*)
				error "unexpected Sonar compute-engine task status for $swft_task_id: '${swft_status:-<none>}'"
				return 1
				;;
		esac
		sleep "$SONAR_POLL_INTERVAL"
	done

	error "the Sonar compute-engine task $swft_task_id did not finish within $((SONAR_POLL_MAX_ATTEMPTS * SONAR_POLL_INTERVAL))s"
	return 1
}

# sonar_fetch_quality_gate — the whole-project gate for this analysis, kept at a
# stable path for the assembling jq program.
sonar_fetch_quality_gate() {
	if ! sonar_curl "/api/qualitygates/project_status?analysisId=$(urlencode "$SONAR_ANALYSIS_ID")"; then
		error "the Sonar quality-gate lookup failed (HTTP $SONAR_HTTP_CODE) for analysis $SONAR_ANALYSIS_ID"
		return 1
	fi
	cp "$SONAR_BODY_FILE" "$WORKDIR/sonar-gate.json"
}

# sonar_fetch_issues -> one compact JSON issue per line in
# $WORKDIR/sonar-issues.jsonl, plus SONAR_TOTAL_PROJECT_WIDE from the first
# page's paging block.
#
# Paging is bounded at SONAR_ISSUES_MAX_PAGES, which is Sonar's own reachable
# ceiling rather than an arbitrary cut-off. Hitting it is WARNED about, because
# total_issues_project_wide would then exceed what the issues array actually
# holds and a silent discrepancy there is indistinguishable from a clean result.
sonar_fetch_issues() {
	sfi_out="$WORKDIR/sonar-issues.jsonl"
	: >"$sfi_out"
	sfi_page=1
	sfi_component=$(urlencode "$SONAR_PROJECT_KEY")

	while [ "$sfi_page" -le "$SONAR_ISSUES_MAX_PAGES" ]; do
		if ! sonar_curl "/api/issues/search?componentKeys=$sfi_component&ps=$SONAR_ISSUES_PAGE_SIZE&p=$sfi_page"; then
			error "the Sonar issue search failed (HTTP $SONAR_HTTP_CODE) on page $sfi_page"
			return 1
		fi

		if ! jq -c --arg key "$SONAR_PROJECT_KEY" '
			(.issues // [])[]
			| {
				key: (.key // ""),
				rule: (.rule // ""),
				type: (.type // ""),
				severity: (.severity // ""),
				file: ((.component // "") | ltrimstr($key + ":")),
				line: (.line | if type == "number" then . else null end),
				message: (.message // ""),
				status: (.status // "")
			}' "$SONAR_BODY_FILE" >>"$sfi_out"
		then
			error "could not parse the Sonar issue search response (page $sfi_page)"
			return 1
		fi

		if [ "$sfi_page" -eq 1 ]; then
			SONAR_TOTAL_PROJECT_WIDE=$(jq -r '(.paging.total // .total // 0) | tostring' "$SONAR_BODY_FILE" 2>/dev/null || printf '0')
			case "$SONAR_TOTAL_PROJECT_WIDE" in
				''|*[!0-9]*) SONAR_TOTAL_PROJECT_WIDE=0 ;;
			esac
		fi

		sfi_page_size=$(jq -r '(.paging.pageSize // 0) | tostring' "$SONAR_BODY_FILE" 2>/dev/null || printf '0')
		case "$sfi_page_size" in
			''|*[!0-9]*|0)
				# No usable paging block — one page is all there is to read.
				return 0 ;;
		esac
		if [ "$((sfi_page * sfi_page_size))" -ge "$SONAR_TOTAL_PROJECT_WIDE" ]; then
			return 0
		fi
		sfi_page=$((sfi_page + 1))
	done

	warn "stopped reading Sonar issues after $SONAR_ISSUES_MAX_PAGES pages of $SONAR_ISSUES_PAGE_SIZE — sonar.json's issues[] is truncated relative to total_issues_project_wide ($SONAR_TOTAL_PROJECT_WIDE)"
}

# write_sonar_json OUTFILE — assemble metadata + (for changed-only, filtered)
# issues.
#
# quality_gate_failed_conditions is COMPOSED, not copied: the API returns each
# condition as metricKey/comparator/errorThreshold/actualValue with no prose
# field, so the human-readable description the contract asks for is built from
# those four.
#
# total_issues is the length of the array actually written and
# total_issues_project_wide is the server's own count. For `all` scope they agree,
# except when paging truncated the read — in which case they deliberately
# disagree, and that disagreement is the honest record of it (with the warning
# above naming it explicitly).
#
# `changed_only_filter_matched_nothing` IS THE FALSE-CLEAN DETECTOR for the
# changed-only filter below. That filter is a strict equality join between two
# independently-derived path bases — git's project-rebased list, and Sonar's
# `component` with the project key trimmed off — and nothing validates that they
# actually agree. Any layout where they do not (multi-module scanner keys, a
# `sonar.projectBaseDir` that differs from --project) drops EVERY issue and
# reports `total_issues: 0`, which is indistinguishable from a genuinely clean
# diff. The flag does not fix the join; it makes the one signature of that
# failure — a non-empty pre-filter set reduced to an empty post-filter set —
# explicit in the machine-readable channel, with run_sonar_engine warning on it.
#
# `sonar_host_url` is SONAR_HOST_DISPLAY, never SONAR_HOST. With userinfo now
# rejected outright the two are always equal in a run that gets this far, so this
# is belt-and-braces rather than a behaviour change — but it is what keeps the
# credential-bearing form structurally unable to reach a results file a consumer
# feeds to an agent.
#
# `availability_checks` records the three detection results in the metadata, per
# the contract's "record each check's result in metadata regardless". It is
# additive to the documented field list rather than a change to it, so a consumer
# reading only the documented keys is unaffected.
write_sonar_json() {
	wsj_out=$1
	wsj_filter=false
	[ "$OPT_SCOPE" != changed-only ] || wsj_filter=true

	jq -n \
		--slurpfile raw "$WORKDIR/sonar-issues.jsonl" \
		--slurpfile gate "$WORKDIR/sonar-gate.json" \
		--rawfile changed "$CHANGED_FILES_FILE" \
		--argjson filter_to_changed "$wsj_filter" \
		--argjson total_project_wide "$SONAR_TOTAL_PROJECT_WIDE" \
		--arg project "$OPT_PROJECT" \
		--arg project_name "$PROJECT_NAME" \
		--arg project_key "$SONAR_PROJECT_KEY" \
		--arg scope "$OPT_SCOPE" \
		--arg generated_at "$GENERATED_AT" \
		--arg host "$SONAR_HOST_DISPLAY" \
		--arg analysis_id "$SONAR_ANALYSIS_ID" \
		--argjson scanner_on_path "$SONAR_CHECK_SCANNER" \
		--argjson server_up "$SONAR_CHECK_SERVER" \
		--argjson config_found "$SONAR_CHECK_CONFIG" \
		'
		(($gate[0] // {}).projectStatus // {}) as $ps
		| ($changed | split("\n") | map(select(length > 0))) as $ch
		| (if $filter_to_changed
			then ($raw | map(select(.file as $f | ($ch | index($f)) != null)))
			else $raw
			end) as $kept
		| {
			metadata: {
				engine: "sonar-scanner",
				project: $project,
				project_name: $project_name,
				project_key: $project_key,
				scope: $scope,
				scope_note: "quality gate and full scan are always whole-project; only issues[] below is filtered to files in the current diff",
				generated_at: $generated_at,
				sonar_host_url: $host,
				analysis_id: $analysis_id,
				quality_gate_status: (($ps.status // "") | if . == "" then "UNKNOWN" else . end),
				quality_gate_failed_conditions: [
					($ps.conditions // [])[]
					| select((.status // "") == "ERROR" or (.status // "") == "WARN")
					| ((.metricKey // "?") | tostring)
						+ " " + ((.comparator // "?") | tostring)
						+ " " + ((.errorThreshold // "?") | tostring)
						+ " (actual: " + ((.actualValue // "?") | tostring)
						+ ", " + ((.status // "?") | tostring) + ")"
				],
				total_issues: ($kept | length),
				total_issues_project_wide: $total_project_wide,
				changed_only_filter_matched_nothing: (
					(($raw | length) > 0)
					and (($kept | length) == 0)
				),
				availability_checks: {
					scanner_on_path: $scanner_on_path,
					server_up: $server_up,
					project_config_found: $config_found
				}
			},
			issues: $kept
		}
		' >"$wsj_out"
}

# warn_if_changed_filter_matched_nothing FILE — say out loud what
# write_sonar_json recorded: the scan found issues and the changed-only filter
# kept none of them. Read back from the written JSON rather than recomputed here,
# so the warning and the metadata flag can never disagree.
warn_if_changed_filter_matched_nothing() {
	wicfmn_file=$1
	wicfmn_flag=$(jq -r '.metadata.changed_only_filter_matched_nothing // false' "$wicfmn_file" 2>/dev/null || printf 'false')
	[ "$wicfmn_flag" = true ] || return 0
	warn "Sonar reported issues but NONE of them matched the changed-file list, so sonar.json's issues[] is empty"
	warn "that is what a project-key/base-directory mismatch looks like (a multi-module scanner key, or a sonar.projectBaseDir that is not $OPT_PROJECT) — treat this run as \"not filtered\", not as \"clean\"; re-run with --scope all to see the full result"
}

# run_sonar_engine — the unit's one entry point.
run_sonar_engine() {
	run_sonar_scan || return 1

	if ! SONAR_PROJECT_KEY=$(sonar_report_task_value projectKey); then
		error "no projectKey in $OPT_PROJECT/.scannerwork/report-task.txt — cannot identify the analyzed project"
		return 1
	fi
	if ! rse_task_id=$(sonar_report_task_value ceTaskId); then
		error "no ceTaskId in $OPT_PROJECT/.scannerwork/report-task.txt — cannot follow the analysis"
		return 1
	fi

	note "Waiting for the Sonar analysis of $SONAR_PROJECT_KEY (task $rse_task_id)..."
	sonar_wait_for_task "$rse_task_id" || return 1
	sonar_fetch_quality_gate || return 1
	sonar_fetch_issues || return 1

	rse_out="$RUN_DIR/sonar.json"
	if ! write_sonar_json "$rse_out"; then
		error "could not write $rse_out"
		return 1
	fi
	warn_if_changed_filter_matched_nothing "$rse_out"
	# shellcheck disable=SC2034  # read by lib/output.sh's print_run_summary()/print_machine_keys(); see the SC2034 note in detect_sonar above
	SONAR_OUTPUT=$rse_out
}
