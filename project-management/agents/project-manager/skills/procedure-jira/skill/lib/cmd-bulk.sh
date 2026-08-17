# shellcheck shell=sh
#
# cmd-bulk.sh — `bulk`: apply ONE existing verb (transition|comment|update) to a
#               SET of issues, synchronously, in a single invocation. A
#               deliberate CLIENT-SIDE loop that COMPOSES over the
#               already-reviewed single-issue verbs — NOT Jira's native async
#               bulk API (intentionally out of scope).
#
# FAILURE-ISOLATION APPROACH (subshell, not core-extraction): each issue's verb
# runs inside a `( ... )` subshell — apply_bulk_verb_to_key below — so a
# per-issue `exit 1` (a 4xx, an unreachable transition, an unresolvable field)
# isolates to THAT iteration and never aborts the batch. This was chosen over
# factoring a status-returning core out of each cmd_* precisely because it
# leaves the single-issue verbs (and every one of their existing tests)
# BYTE-FOR-BYTE unchanged: the isolation is a property of the subshell boundary,
# not of any edit to the verbs. Verified: a `( )` subshell does NOT run the
# parent's EXIT trap on its own exit, so cleanup() never wipes WORKDIR
# mid-batch. The subshell also gets its OWN COPY of every WORKDIR temp-file
# counter (RESP_COUNTER/TRANS_COUNTER/...), so each iteration reuses the same
# fixed temp-file names and overwrites them SEQUENTIALLY — no cross-iteration
# collision, since the prior subshell has already exited before the next runs.
#
# --plan is the batch-safety mechanism: it resolves + validates the set, prints
# exactly what WOULD change, and MUTATES NOTHING — for --keys it makes ZERO
# requests; for --jql it makes ONLY the read that resolves the set (via the
# reused search path). No write verb (POST/PUT) is ever reached under --plan.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# bulk_intent_phrase -> one human phrase describing the change --plan would
# apply, per --op (the "intended change" the plan discloses).
#
# The update arm's field list comes from cmd-update.sh's update_field_summary —
# the ONE enumeration of the update verb's fields, shared with the
# at-least-one-field guard (see that function's header). bulk loops the single
# verb, so it discloses the verb's own list rather than a copy that could drift
# from what the loop actually writes.
bulk_intent_phrase() {
	case "$OPT_OP" in
		transition)
			if [ -n "$OPT_RESOLUTION" ]; then
				printf 'transition to "%s" (resolution: %s)' "$OPT_STATUS" "$OPT_RESOLUTION"
			else
				printf 'transition to "%s"' "$OPT_STATUS"
			fi
			;;
		comment) printf 'add a comment from %s' "$OPT_TEXT_FILE" ;;
		update)  printf 'update field(s): %s' "$(update_field_summary)" ;;
	esac
}

# apply_bulk_verb_to_key KEY — runs the selected verb against ONE issue inside
# a SUBSHELL, returning that verb's status (0 ok / non-0 failed) WITHOUT ever
# aborting the caller's batch loop. Only TICKET_KEY is overridden per issue;
# the op-specific OPT_* (OPT_STATUS/OPT_TEXT_FILE/the update fields) are already
# the globals the single verb reads. The subshell's stdout is discarded (this
# batch emits its OWN machine lines and OPT_JSON only affects that discarded
# output, so it need not be forced off; OPT_PLAN is already 0 on this real-run
# path), while stderr is left to flow so a per-issue failure's diagnostic still
# reaches the operator.
apply_bulk_verb_to_key() {
	apply_bulk_key=$1
	(
		# shellcheck disable=SC2030  # the subshell scoping IS the mechanism: overriding TICKET_KEY per issue must NOT leak back into the batch loop (see this file's header)
		TICKET_KEY=$apply_bulk_key
		case "$OPT_OP" in
			transition) cmd_transition ;;
			comment)    cmd_comment ;;
			update)     cmd_update ;;
		esac
	) >/dev/null
}

cmd_bulk() {
	# --op validity, exactly-one-of --keys/--jql, per-key shape, and the
	# op-specific required args are all validated up front — see the main
	# dispatch section's per-command block.
	#
	# ensure_workdir runs FIRST in the MAIN shell so neither the cmd_search
	# reuse (for --jql) nor any per-issue verb subshell below can create — and
	# then orphan — a WORKDIR from inside a subshell (the same leak already
	# guarded in cmd_search/cmd_comment/cmd_transition).
	ensure_workdir

	# comment's --text-file is the SAME file for every issue — assert it is
	# readable ONCE, up front, before any network I/O (usage-class failure).
	if [ "$OPT_OP" = "comment" ]; then
		require_readable_file "$OPT_TEXT_FILE" "--text-file"
	fi

	bulk_keys_file="$WORKDIR/bulk-keys.txt"
	resolve_bulk_keys_file "$bulk_keys_file"

	bulk_total=$(count_nonempty_lines "$bulk_keys_file")

	if [ "$bulk_total" -eq 0 ]; then
		error "bulk --op $OPT_OP resolved ZERO issues (nothing to do)"
		exit 1
	fi

	# Truncation disclosure — the load-bearing safety invariant: a bulk MUST NEVER silently mutate
	# a truncated set nor claim complete success over one. A --jql resolve with no
	# --limit paginates to exhaustion, so the set is complete (truncated=false).
	# When the caller passes an explicit --limit, that cap is intentional but MUST
	# be disclosed: if the resolved count reached the cap, more matches may exist
	# beyond it, so flag it as truncated (conservative — never under-discloses).
	compute_truncation bulk "$bulk_total"
	bulk_truncated=$BATCH_TRUNCATED
	bulk_resolved_limit=$BATCH_RESOLVED_LIMIT

	if [ "$OPT_PLAN" -eq 1 ]; then
		render_batch_plan "$OPT_OP" "$(bulk_intent_phrase)" "PLAN (bulk $OPT_OP)" \
			"$bulk_keys_file" "$bulk_total" "$bulk_truncated" "$bulk_resolved_limit"
		return 0
	fi

	# Real run: apply the verb to each issue, isolating per-issue failure and
	# collecting outcomes. The loop reads the keys file via REDIRECTION (not a
	# pipe) so it runs in THIS shell and its counters survive each iteration.
	bulk_ok=0
	bulk_failed=0
	bulk_results_file="$WORKDIR/bulk-results.jsonl"
	: >"$bulk_results_file"

	while IFS= read -r bulk_key; do
		[ -n "$bulk_key" ] || continue
		if apply_bulk_verb_to_key "$bulk_key"; then
			bulk_ok=$((bulk_ok + 1))
			bulk_outcome=ok
		else
			bulk_failed=$((bulk_failed + 1))
			bulk_outcome=failed
		fi
		record_batch_result JIRA_BULK_RESULT "$bulk_key" "$bulk_outcome" "$bulk_results_file"
	done <"$bulk_keys_file"

	render_batch_summary JIRA_BULK_SUMMARY "$OPT_OP" "$bulk_results_file" \
		"$bulk_total" "$bulk_ok" "$bulk_truncated" "$bulk_resolved_limit"

	# Exit 0 iff ALL issues succeeded; non-zero if ANY failed (so a caller can
	# detect partial failure). This is the LAST statement, so its status
	# becomes cmd_bulk's return and thus the script's exit code.
	[ "$bulk_failed" -eq 0 ]
}

# validate_bulk_args() — `bulk`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_bulk_args() {
	# bulk takes NO positional — the set is named by --keys/--jql, so a
	# stray positional (e.g. a copy-pasted ticket key) fails loud rather
	# than being silently ignored (same reasoning as search/version).
	#
	# shellcheck disable=SC2031  # a false positive of file-local flow analysis: this validator runs from the DISPATCHER, strictly before cmd_bulk and therefore before apply_bulk_verb_to_key's subshell has ever executed
	if [ -n "$TICKET_KEY" ]; then
		usage >&2
		error "bulk takes no positional argument, got: $TICKET_KEY (use --keys or --jql)"
		exit 2
	fi
	# --op is required and must name one of the three loopable verbs.
	case "$OPT_OP" in
		transition|comment|update) : ;;
		'') usage >&2; error "bulk requires --op transition|comment|update"; exit 2 ;;
		*)  usage >&2; error "invalid --op '$OPT_OP' (must be transition|comment|update)"; exit 2 ;;
	esac
	# Exactly one set selector: --keys XOR --jql.
	if [ -n "$OPT_KEYS" ] && [ -n "$OPT_JQL" ]; then
		usage >&2
		error "bulk requires exactly one of --keys or --jql, not both"
		exit 2
	fi
	if [ -z "$OPT_KEYS" ] && [ -z "$OPT_JQL" ]; then
		usage >&2
		error "bulk requires a set selector: --keys CSV or --jql QUERY"
		exit 2
	fi
	# Every --keys entry is shape-validated HERE (usage error, exit 2)
	# before it can ever become a URL path segment downstream — via the
	# SAME split_keys_csv helper resolve_bulk_keys_file uses (one idiom,
	# no divergence). An empty CSV (only whitespace/commas) is a usage error.
	if [ -n "$OPT_KEYS" ]; then
		validate_keys_csv_or_die
	fi
	# Op-specific required arguments — the SAME preconditions the single
	# verb enforces, asserted up front so a batch never starts before its
	# per-issue change is fully specified.
	case "$OPT_OP" in
		transition)
			[ -n "$OPT_STATUS" ] || { usage >&2; error "bulk --op transition requires --status TARGET"; exit 2; }
			;;
		comment)
			[ -n "$OPT_TEXT_FILE" ] || { usage >&2; error "bulk --op comment requires --text-file PATH"; exit 2; }
			;;
		update)
			# The SAME predicate `update` itself uses (cmd-update.sh's
			# has_update_field_request), so the batch can never accept a
			# field set the single verb would reject, or vice versa.
			if ! has_update_field_request; then
				usage >&2
				error "bulk --op update requires at least one field to change"
				exit 2
			fi
			if [ -n "$OPT_DESCRIPTION_FILE" ] && [ -n "$OPT_APPEND_FILE" ]; then
				usage >&2
				error "--description-file and --append-file are mutually exclusive"
				exit 2
			fi
			;;
	esac
	return 0
}
