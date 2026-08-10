# shellcheck shell=sh
#
# batch-report.sh — the plan / per-issue result / final summary rendering shared
#                   by the two batch commands (bulk, schedule).
#
# Each renderer routes itself to --json or human by $OPT_JSON, so a batch's
# three outputs can never drift into two different shapes between the two
# commands.
#
# COUPLING (accepted for this pass): the renderers read $OPT_JSON directly.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# render_batch_plan OP INTENT HEADER KEYS_FILE TOTAL TRUNCATED RESOLVED_LIMIT —
# the --plan/--dry-run disclosure: names every issue in the set + the single
# change that WOULD be applied, discloses any cap in effect, then states plainly
# that nothing was written.
#
# HEADER is the ALREADY-FORMATTED human header ("PLAN (schedule)" /
# "PLAN (bulk update)"), NOT a noun this function formats. That is the one real
# difference between the two commands' copies — bulk's header embeds its --op,
# schedule's does not — and unifying the two SHAPES into one conditional here
# would buy nothing and make both harder to read. The --json path was already
# byte-identical.
render_batch_plan() {
	rbp_op=$1
	rbp_intent=$2
	rbp_header=$3
	rbp_keys_file=$4
	rbp_total=$5
	rbp_truncated=$6
	rbp_resolved_limit=$7
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -n --arg op "$rbp_op" --arg intent "$rbp_intent" \
			--argjson total "$rbp_total" --argjson truncated "$rbp_truncated" \
			--argjson resolvedLimit "$rbp_resolved_limit" --rawfile keys_raw "$rbp_keys_file" \
			'{op: $op, plan: true, willWrite: false, intent: $intent,
			  total: $total, truncated: $truncated, resolvedLimit: $resolvedLimit,
			  keys: ($keys_raw | split("\n") | map(select(length > 0)))}'
		return 0
	fi
	printf '%s: would %s for %d issue(s):\n' "$rbp_header" "$rbp_intent" "$rbp_total"
	while IFS= read -r rbp_key; do
		[ -n "$rbp_key" ] || continue
		printf '  %s\n' "$rbp_key"
	done <"$rbp_keys_file"
	if [ "$rbp_truncated" = "true" ]; then
		printf 'NOTE: capped at --limit %s — additional matches may exist and are NOT in this set.\n' "$rbp_resolved_limit"
	fi
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

# record_batch_result PREFIX KEY STATUS RESULTS_FILE — ONE per-issue outcome:
# an appended {key,status} jsonl object (--json, later slurped into the summary)
# or a machine line (human mode).
#
# PREFIX is the machine line's name — JIRA_BULK_RESULT or JIRA_SCHEDULE_RESULT.
# That single token is the ONLY thing that differed between the two commands'
# copies of this: the --json path was already byte-identical.
record_batch_result() {
	rbr_prefix=$1
	rbr_key=$2
	rbr_status=$3
	rbr_file=$4
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -nc --arg key "$rbr_key" --arg status "$rbr_status" \
			'{key: $key, status: $status}' >>"$rbr_file"
	else
		printf '%s=%s:%s\n' "$rbr_prefix" "$rbr_key" "$rbr_status"
	fi
}

# render_batch_summary PREFIX OP RESULTS_FILE TOTAL OK TRUNCATED RESOLVED_LIMIT
# — the final batch summary: one --json object, or one machine line.
#
# PREFIX names the machine line (JIRA_BULK_SUMMARY / JIRA_SCHEDULE_SUMMARY) and
# OP is the op token the --json object reports; the two commands' copies of this
# differed in nothing else — the jq program was already byte-identical and both
# human branches matched modulo the prefix.
#
# The truncated branch is NEVER a bare "N/N succeeded": a summary over a capped
# set must disclose the cap inline, or it reads as complete success over a set
# that was never fully processed.
render_batch_summary() {
	rbs_prefix=$1
	rbs_op=$2
	rbs_file=$3
	rbs_total=$4
	rbs_ok=$5
	rbs_truncated=$6
	rbs_resolved_limit=$7
	if [ "$OPT_JSON" -eq 1 ]; then
		jq -s --arg op "$rbs_op" --argjson ok "$rbs_ok" --argjson total "$rbs_total" \
			--argjson truncated "$rbs_truncated" --argjson resolvedLimit "$rbs_resolved_limit" \
			'{op: $op, results: .,
			  summary: {ok: $ok, total: $total, failed: ($total - $ok),
			            truncated: $truncated, resolvedLimit: $resolvedLimit}}' \
			"$rbs_file"
	elif [ "$rbs_truncated" = "true" ]; then
		printf '%s=%d/%d succeeded (CAPPED at --limit %s; additional matches may exist and were NOT processed)\n' \
			"$rbs_prefix" "$rbs_ok" "$rbs_total" "$rbs_resolved_limit"
	else
		printf '%s=%d/%d succeeded\n' "$rbs_prefix" "$rbs_ok" "$rbs_total"
	fi
}
