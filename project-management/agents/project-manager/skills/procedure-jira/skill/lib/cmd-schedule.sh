# shellcheck shell=sh
#
# cmd-schedule.sh — `schedule`: move a SET of issues onto a sprint, to a board's
#                   backlog, or under an epic (or clear the epic parent).
#
# A deliberate CLIENT-SIDE composition over the SAME set-resolution engine bulk
# uses (issue-set.sh), then ONE of two write shapes per the Agile ground truth:
#
#   --to-sprint ID   POST /rest/agile/1.0/sprint/<ID>/issue    {"issues":[K...]}
#   --to-backlog     POST /rest/agile/1.0/backlog/<BOARD>/issue {"issues":[K...]}
#                    (board-scoped form, REQUIRES --board — universal across
#                     team-managed AND company-managed; the global
#                     /backlog/issue is NOT team-managed-safe, so it is not used)
#   --to-epic KEY    PUT  /rest/api/3/issue/<K> {"fields":{"parent":{"key":KEY}}}
#   --from-epic      PUT  /rest/api/3/issue/<K> {"fields":{"parent":null}}
#
# Epic assign/remove uses the REST v3 `parent` field (NOT the Agile epic
# endpoint) — universal for both team-managed and modern company-managed Jira,
# and per-issue, so it LOOPS with per-issue partial-failure isolation exactly
# like bulk. Sprint/backlog take the whole issues[] array in ONE call, so their
# batch outcome (2xx -> all ok, non-2xx -> all failed) is reported across the
# set the same way.
#
# --dry-run (OPT_PLAN) discloses the plan and MUTATES NOTHING — for --keys it
# makes ZERO requests, for --jql only the read that resolves the set (via the
# reused search path); no POST/PUT is ever reached.
#
# JSON bodies are built ONLY via static jq programs: the issues[] array via
# `jq -n --rawfile` + split (the SAME idiom render_batch_plan uses), and the
# parent object via `jq -n --arg` — never string concatenation.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# schedule_op_name -> the short op token for the machine/json output.
schedule_op_name() {
	if   [ -n "$OPT_TO_SPRINT" ];     then printf 'to-sprint'
	elif [ "$OPT_TO_BACKLOG" -eq 1 ]; then printf 'to-backlog'
	elif [ -n "$OPT_TO_EPIC" ];       then printf 'to-epic'
	else                                   printf 'from-epic'
	fi
}

# schedule_intent_phrase -> one human phrase describing the change --plan/--dry-run
# would apply, per target op (the "intended change" the plan discloses).
schedule_intent_phrase() {
	if   [ -n "$OPT_TO_SPRINT" ];     then printf 'move to sprint %s' "$OPT_TO_SPRINT"
	elif [ "$OPT_TO_BACKLOG" -eq 1 ]; then printf 'move to backlog on board %s' "$OPT_BOARD"
	elif [ -n "$OPT_TO_EPIC" ];       then printf 'assign to epic %s' "$OPT_TO_EPIC"
	else                                   printf 'remove from epic (clear parent)'
	fi
}

# schedule_apply_epic_to_key KEY BODY_FILE — runs the per-issue epic PUT inside a
# SUBSHELL, returning that PUT's status (0 ok / non-0 failed) WITHOUT ever
# aborting the caller's batch loop — the SAME failure-isolation boundary
# apply_bulk_verb_to_key uses (a `( )` subshell does not run the parent's EXIT
# trap, so cleanup() never wipes WORKDIR mid-batch). The subshell's stderr flows
# to the operator so a per-issue diagnostic still surfaces; KEY was shape-validated
# up front before it can become this URL path segment.
schedule_apply_epic_to_key() {
	sched_epic_key=$1
	sched_epic_body_file=$2
	(
		sched_epic_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${sched_epic_key}"
		jira_curl PUT "$sched_epic_url" "$sched_epic_body_file"
		handle_http_status "$JIRA_HTTP_CODE" "set parent on $sched_epic_key"
	)
}

cmd_schedule() {
	# Target op (exactly one), issue selector (exactly one), id/key shapes, and
	# --to-backlog's --board requirement are all validated up front — see the main
	# dispatch section's per-command block. ensure_workdir runs FIRST in the MAIN
	# shell so neither the cmd_search reuse (for --jql) nor any per-issue PUT
	# subshell below can create — and then orphan — a WORKDIR from a subshell.
	ensure_workdir

	# Resolve the issue set through the SAME engine bulk uses: --keys splits the
	# CSV; --jql resolves via the reused search path. Every resolved key is
	# re-validated (shape) inside resolve_bulk_keys_file before any URL use.
	sched_keys_file="$WORKDIR/schedule-keys.txt"
	resolve_bulk_keys_file "$sched_keys_file"

	sched_total=$(count_nonempty_lines "$sched_keys_file")

	if [ "$sched_total" -eq 0 ]; then
		error "schedule resolved ZERO issues (nothing to do)"
		exit 1
	fi

	# Truncation disclosure — the SAME load-bearing safety invariant as cmd_bulk:
	# never silently mutate a truncated set. A --jql resolve with no --limit
	# paginates to exhaustion (complete); an explicit --limit is an intentional
	# cap that MUST be disclosed if the resolved count reached it.
	compute_truncation schedule "$sched_total"
	sched_truncated=$BATCH_TRUNCATED
	sched_resolved_limit=$BATCH_RESOLVED_LIMIT

	if [ "$OPT_PLAN" -eq 1 ]; then
		render_batch_plan "$(schedule_op_name)" "$(schedule_intent_phrase)" 'PLAN (schedule)' \
			"$sched_keys_file" "$sched_total" "$sched_truncated" "$sched_resolved_limit"
		return 0
	fi

	# Real run: collect per-issue outcomes, then a summary; exit non-zero if ANY
	# failed (so a caller can detect partial failure). The loop reads the keys
	# file via REDIRECTION (not a pipe) so its counters survive each iteration.
	sched_results_file="$WORKDIR/schedule-results.jsonl"
	: >"$sched_results_file"
	sched_ok=0

	if [ "$OPT_FROM_EPIC" -eq 1 ] || [ -n "$OPT_TO_EPIC" ]; then
		# Per-issue PUT /rest/api/3/issue/<key>. The parent value does NOT depend on
		# the key, so the body is built ONCE and reused for every issue: a `parent`
		# ref object (assign) or a JSON null (remove) — both via a static jq -n
		# program (--arg for the epic key), never string-concatenated.
		sched_epic_body="$WORKDIR/schedule-epic-body.json"
		if [ "$OPT_FROM_EPIC" -eq 1 ]; then
			jq -n '{fields: {parent: null}}' >"$sched_epic_body"
		else
			jq -n --arg key "$OPT_TO_EPIC" '{fields: {parent: {key: $key}}}' >"$sched_epic_body"
		fi
		while IFS= read -r sched_key; do
			[ -n "$sched_key" ] || continue
			if schedule_apply_epic_to_key "$sched_key" "$sched_epic_body"; then
				sched_ok=$((sched_ok + 1))
				sched_outcome=ok
			else
				sched_outcome=failed
			fi
			record_batch_result JIRA_SCHEDULE_RESULT "$sched_key" "$sched_outcome" "$sched_results_file"
		done <"$sched_keys_file"
	else
		# Batch: ONE POST over the whole issues[] array (sprint | backlog). The
		# array is built from the validated keys file via `jq -n --rawfile` + split
		# — the SAME static idiom render_batch_plan uses, never string-concatenated.
		sched_issues_body="$WORKDIR/schedule-issues.json"
		jq -n --rawfile keys "$sched_keys_file" \
			'{issues: ($keys | split("\n") | map(select(length > 0)))}' >"$sched_issues_body"
		if [ -n "$OPT_TO_SPRINT" ]; then
			sched_batch_url="https://${CONFIRMED_HOST}/rest/agile/1.0/sprint/${OPT_TO_SPRINT}/issue"
			sched_batch_action="move issues to sprint $OPT_TO_SPRINT"
		else
			sched_batch_url="https://${CONFIRMED_HOST}/rest/agile/1.0/backlog/${OPT_BOARD}/issue"
			sched_batch_action="move issues to backlog on board $OPT_BOARD"
		fi
		# One call for the whole set; isolate it in a subshell so its non-2xx exit
		# (handle_http_status) is captured here as the batch outcome (its diagnostic
		# still reaches the operator via inherited stderr) rather than aborting.
		if ( jira_curl POST "$sched_batch_url" "$sched_issues_body"
		     handle_http_status "$JIRA_HTTP_CODE" "$sched_batch_action" ); then
			sched_batch_outcome=ok
		else
			sched_batch_outcome=failed
		fi
		while IFS= read -r sched_key; do
			[ -n "$sched_key" ] || continue
			if [ "$sched_batch_outcome" = "ok" ]; then sched_ok=$((sched_ok + 1)); fi
			record_batch_result JIRA_SCHEDULE_RESULT "$sched_key" "$sched_batch_outcome" "$sched_results_file"
		done <"$sched_keys_file"
	fi

	render_batch_summary JIRA_SCHEDULE_SUMMARY "$(schedule_op_name)" "$sched_results_file" \
		"$sched_total" "$sched_ok" "$sched_truncated" "$sched_resolved_limit"

	# Exit 0 iff ALL issues succeeded; non-zero if ANY failed. LAST statement, so
	# its status becomes cmd_schedule's return and thus the script's exit code.
	[ "$sched_ok" -eq "$sched_total" ]
}

# validate_schedule_args() — `schedule`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_schedule_args() {
	# schedule takes NO positional — the issue set is named by --keys/--jql
	# (same reasoning as bulk); a stray positional fails loud rather than
	# being silently ignored.
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "schedule takes no positional argument, got: $TICKET_KEY (use --keys or --jql)"
		exit 2
	fi
	# EXACTLY ONE target op: --to-sprint | --to-backlog | --to-epic | --from-epic.
	schedule_op_count=0
	[ -n "$OPT_TO_SPRINT" ]     && schedule_op_count=$((schedule_op_count + 1))
	[ "$OPT_TO_BACKLOG" -eq 1 ] && schedule_op_count=$((schedule_op_count + 1))
	[ -n "$OPT_TO_EPIC" ]       && schedule_op_count=$((schedule_op_count + 1))
	[ "$OPT_FROM_EPIC" -eq 1 ]  && schedule_op_count=$((schedule_op_count + 1))
	if [ "$schedule_op_count" -ne 1 ]; then
		usage >&2
		error "schedule requires exactly one target op: --to-sprint ID | --to-backlog --board ID | --to-epic KEY | --from-epic"
		exit 2
	fi
	# EXACTLY ONE issue selector: --keys XOR --jql (same as bulk).
	if [ -n "$OPT_KEYS" ] && [ -n "$OPT_JQL" ]; then
		usage >&2
		error "schedule requires exactly one of --keys or --jql, not both"
		exit 2
	fi
	if [ -z "$OPT_KEYS" ] && [ -z "$OPT_JQL" ]; then
		usage >&2
		error "schedule requires an issue selector: --keys CSV or --jql QUERY"
		exit 2
	fi
	# Every --keys entry is shape-validated HERE (usage error, exit 2) before
	# it can become a URL path segment (epic PUT) or a JSON issues[] element —
	# via the SAME split_keys_csv helper resolve_bulk_keys_file uses. An empty
	# CSV (only whitespace/commas) is a usage error.
	if [ -n "$OPT_KEYS" ]; then
		validate_keys_csv_or_die
	fi
	# Target-op-specific validation — every id/key that becomes a URL path
	# segment is shape-checked BEFORE any network call. Sprint/board ids via
	# validate_numeric_id (rejects leading-zero/non-digit); the epic key via
	# validate_ticket_key (the issue-key allow-list ^[A-Z][A-Z0-9]+-[0-9]+$).
	if [ -n "$OPT_TO_SPRINT" ]; then
		validate_numeric_id "$OPT_TO_SPRINT" || { usage >&2; error "invalid --to-sprint (must be a numeric sprint id): $OPT_TO_SPRINT"; exit 2; }
	fi
	if [ "$OPT_TO_BACKLOG" -eq 1 ]; then
		[ -n "$OPT_BOARD" ] || { usage >&2; error "schedule --to-backlog requires --board BOARD_ID"; exit 2; }
		validate_numeric_id "$OPT_BOARD" || { usage >&2; error "invalid --board (must be a numeric board id): $OPT_BOARD"; exit 2; }
	fi
	if [ -n "$OPT_TO_EPIC" ]; then
		validate_ticket_key "$OPT_TO_EPIC" || { usage >&2; error "invalid --to-epic (must be an issue key, e.g. PROJ-12): $OPT_TO_EPIC"; exit 2; }
	fi
	# --board is meaningful ONLY for --to-backlog; reject it elsewhere so a
	# stray --board on a sprint/epic op fails loud instead of being ignored.
	if [ -n "$OPT_BOARD" ] && [ "$OPT_TO_BACKLOG" -ne 1 ]; then
		usage >&2
		error "--board is only valid with schedule --to-backlog"
		exit 2
	fi
	return 0
}
