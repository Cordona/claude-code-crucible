# shellcheck shell=sh
#
# output.sh — where a run's results go and what a human is told about them: the
#             dated run directory, the human summary, and the machine-parseable
#             INSPECT_* lines.
#
# TWO CHANNELS, AND THE SPLIT IS LOAD-BEARING. The human summary goes to STDERR
# and the INSPECT_* lines to STDOUT. That is what lets the flag-driven path and
# the interactive path both print a summary while still producing BYTE-IDENTICAL
# stdout for the same effective inputs — an agent parsing stdout sees exactly the
# same bytes whichever way the values were collected.
#
# LOCAL TIME NAMES THE DIRECTORY; UTC STAMPS THE JSON. `generated_at` is UTC
# because it is a record other tools compare across machines, while the
# YYYY/MM/DD/HH-MM-SS path is what a human browses for "the run I did this
# afternoon" — and finding today's 23:30 run filed under tomorrow is the wrong
# kind of correct. The two are read from separate `date` calls, which is safe
# precisely because they are not required to agree.
#
# Sourced by inspect-project.sh — never executed directly.

# prepare_run_dir ROOT NAME -> sets RUN_DIR to
# ROOT/YYYY/MM/DD/NAME/HH-MM-SS, created fresh.
#
# NEVER OVERWRITES A PRIOR RUN, and the mechanism is `mkdir` itself rather than a
# `[ -d ]` test: an existence check followed by a create is a race a second
# concurrent run can win, whereas a bare `mkdir` fails atomically when the
# directory already exists. Two runs of one project inside the same second are
# separated by a `-2`, `-3`, ... suffix.
prepare_run_dir() {
	prd_root=$1
	prd_name=$2

	# One `date` call, split by parameter expansion — no word splitting, no
	# globbing, and no chance of the date and time halves straddling a second.
	prd_stamp=$(date '+%Y/%m/%d/%H-%M-%S')
	prd_datepath=${prd_stamp%/*}
	prd_time=${prd_stamp##*/}

	prd_base="$prd_root/$prd_datepath/$prd_name"
	if ! mkdir -p "$prd_base"; then
		error "could not create the results directory: $prd_base"
		return 1
	fi

	prd_attempt=1
	prd_dir="$prd_base/$prd_time"
	while ! mkdir "$prd_dir" 2>/dev/null; do
		if [ ! -d "$prd_dir" ]; then
			error "could not create the run directory: $prd_dir"
			return 1
		fi
		prd_attempt=$((prd_attempt + 1))
		if [ "$prd_attempt" -gt "$RUN_DIR_MAX_ATTEMPTS" ]; then
			error "could not find an unused run directory under $prd_base after $RUN_DIR_MAX_ATTEMPTS attempts"
			return 1
		fi
		prd_dir="$prd_base/$prd_time-$prd_attempt"
	done

	RUN_DIR=$prd_dir
}

# print_severity_breakdown FILE — one indented "SEVERITY: N" line per severity
# present, highest count first.
#
# The jq call is WRAPPED IN A GROUP whose stdout is redirected, rather than
# carrying `2>/dev/null >&2` itself: those two redirections in that order send
# stdout to /dev/null, because `>&2` dups whatever stderr points at BY THEN — which
# is /dev/null. Redirecting the group makes the intent (jq's output to stderr, jq's
# own complaints discarded) independent of that ordering trap.
#
# FILTERED like every other line this script writes to a terminal: a severity
# string is copied from an external tool's report, so it is not this script's own
# text. See lib/runtime.sh's strip_control_bytes. jq's own escaping protects the
# JSON channel, not this one.
print_severity_breakdown() {
	psb_file=$1
	{
		jq -r '
			.issues
			| group_by(.severity)
			| map({severity: (.[0].severity // "UNKNOWN"), count: length})
			| sort_by(-.count)[]
			| "      \(.severity): \(.count)"
		' "$psb_file" 2>/dev/null | strip_control_bytes || true
	} >&2
}

# print_run_summary — the human-readable close-out: counts, the quality-gate
# verdict, the honesty signals, and the exact paths written. Never a raw JSON
# dump.
print_run_summary() {
	printf '\n' >&2
	note "Inspection complete."
	note "  Project     : $PROJECT_NAME  ($OPT_PROJECT)"
	note "  Scope       : $OPT_SCOPE"
	if [ "$OPT_SCOPE" = changed-only ]; then
		note "  Changed     : $(count_changed_files) file(s) vs HEAD"
	fi
	note "  Results dir : $RUN_DIR"

	if [ -n "$INTELLIJ_OUTPUT" ]; then
		prs_total=$(jq -r '.metadata.total_issues' "$INTELLIJ_OUTPUT" 2>/dev/null || printf '?')
		prs_excluded=$(jq -r '.metadata.excluded_count' "$INTELLIJ_OUTPUT" 2>/dev/null || printf '?')
		prs_profile=$(jq -r '.metadata.inspection_profile' "$INTELLIJ_OUTPUT" 2>/dev/null || printf 'unknown')
		printf '\n' >&2
		note "  IntelliJ    : $prs_total issue(s) kept, $prs_excluded excluded (profile: $prs_profile)"
		print_severity_breakdown "$INTELLIJ_OUTPUT"
		# The honesty signal, surfaced where a human will actually read it: a
		# zero-Sonar-findings result means nothing if Sonar's rules were never in
		# the profile.
		if [ "$SONARLINT_RULES_REGISTERED" != true ]; then
			note "      note: no SonarLint rules were registered in this profile — a zero-Sonar result here means \"not checked\", not \"clean\""
		fi
		note "      -> $INTELLIJ_OUTPUT"
	fi

	if [ -n "$SONAR_OUTPUT" ]; then
		prs_gate=$(jq -r '.metadata.quality_gate_status' "$SONAR_OUTPUT" 2>/dev/null || printf '?')
		prs_stotal=$(jq -r '.metadata.total_issues' "$SONAR_OUTPUT" 2>/dev/null || printf '?')
		prs_swide=$(jq -r '.metadata.total_issues_project_wide' "$SONAR_OUTPUT" 2>/dev/null || printf '?')
		printf '\n' >&2
		note "  Sonar       : quality gate $prs_gate — $prs_stotal issue(s) in scope, $prs_swide project-wide"
		# Grouped-and-redirected for the ordering reason print_severity_breakdown
		# documents.
		# Filtered for the reason print_severity_breakdown documents: a gate
		# condition is the server's text, not this script's.
		{ jq -r '.metadata.quality_gate_failed_conditions[] | "      failed: \(.)"' "$SONAR_OUTPUT" 2>/dev/null | strip_control_bytes || true; } >&2
		print_severity_breakdown "$SONAR_OUTPUT"
		note "      -> $SONAR_OUTPUT"
	elif [ "$SONAR_DEGRADED" -eq 1 ]; then
		printf '\n' >&2
		note "  Sonar       : SKIPPED — $SONAR_SKIP_REASON"
	fi

	printf '\n' >&2
}

# print_machine_keys — the ONLY thing this script writes to stdout, and the whole
# reason every other message in it goes to stderr.
print_machine_keys() {
	printf 'INSPECT_RUN_DIR=%s\n' "$RUN_DIR"
	[ -z "$INTELLIJ_OUTPUT" ] || printf 'INSPECT_INTELLIJ_OUTPUT=%s\n' "$INTELLIJ_OUTPUT"
	[ -z "$SONAR_OUTPUT" ] || printf 'INSPECT_SONAR_OUTPUT=%s\n' "$SONAR_OUTPUT"
	# Emitted only on a degraded `--engine both`, so an agent reading stdout alone
	# learns WHY there is no sonar.json instead of having to infer it from a
	# missing key. Gated on SONAR_DEGRADED, never on SONAR_SKIP_REASON — see that
	# flag's note in lib/runtime.sh.
	if [ -z "$SONAR_OUTPUT" ] && [ "$SONAR_DEGRADED" -eq 1 ]; then
		printf 'INSPECT_SONAR_SKIPPED_REASON=%s\n' "$SONAR_SKIP_REASON"
	fi
	# Emitted whenever --allow-plaintext-token actually let a token cross plaintext
	# http, INDEPENDENTLY of whether Sonar went on to produce output: the exposure
	# happened either way, and stderr — where the matching warning goes — is
	# documented as a channel an agent caller does not parse. A credential-transport
	# decision that only ever surfaces on the unread channel is the fail-open this
	# key exists to close.
	if [ -n "$SONAR_PLAINTEXT_TOKEN_WARNING" ]; then
		printf 'INSPECT_SONAR_PLAINTEXT_TOKEN_WARNING=%s\n' "$SONAR_PLAINTEXT_TOKEN_WARNING"
	fi
}
