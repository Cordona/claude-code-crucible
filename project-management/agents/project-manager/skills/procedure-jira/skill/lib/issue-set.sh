# shellcheck shell=sh
#
# issue-set.sh — resolving a batch command's issue SET: --keys (a CSV) or --jql
#                (the reused search path) -> a file of shape-validated ticket
#                keys, one per line.
#
# Both bulk and schedule drive their whole batch from this one resolver, so
# neither can drift on how a set is selected, capped, or validated. EVERY
# resolved key is re-validated with validate_ticket_key before it can become a
# URL path segment — a --jql set is derived from a network response and is
# therefore untrusted.
#
# COUPLING (accepted for this pass): resolve_bulk_keys_file() reads
# OPT_KEYS/OPT_JQL/OPT_LIMIT/OPT_JSON directly, and calls BACK into
# cmd-search.sh's cmd_search to resolve a --jql set. That call direction
# (lib -> cmd) is a known, documented compromise of this split, kept because
# reusing cmd_search wholesale is precisely what guarantees a --jql batch uses
# the identical escaping, sender and pagination a plain `search` does.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# split_keys_csv CSV — emits each comma-separated key on its own line, trimmed
# of surrounding whitespace, empties dropped. Uses the engine's ESTABLISHED
# jq CSV idiom (see merge_labels_field / build_search_request_body's --fields),
# so --keys splits exactly as every other CSV in this engine does — one helper,
# one behaviour, no divergent tr/sed pipeline.
split_keys_csv() {
	jq -rn --arg csv "$1" \
		'$csv | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";"")) | .[] | select(length > 0)'
}

# resolve_bulk_keys_file OUT_FILE — writes the resolved, shape-validated issue
# keys (one per line) to OUT_FILE. Exactly one of --keys/--jql drives it
# (enforced up front). Every key — from BOTH sources — is re-validated with
# validate_ticket_key before it can become a URL path segment downstream.
resolve_bulk_keys_file() {
	bulk_keys_out_file=$1
	: >"$bulk_keys_out_file"

	if [ -n "$OPT_KEYS" ]; then
		# One key per line via the shared split helper. The values were already
		# shape-validated up front (usage error, exit 2); the re-validation loop
		# below is defense in depth before any URL use.
		split_keys_csv "$OPT_KEYS" >"$bulk_keys_out_file"
	else
		# --jql: resolve the set through the SAME search path cmd_search uses —
		# reuse cmd_search wholesale (its allow-listed JQL escaping, its sender,
		# its pagination), capturing its --json output and extracting the keys.
		# The resolve MUST cover the FULL matching set, never a silently truncated
		# prefix: with no explicit --limit we set SEARCH_UNBOUNDED so cmd_search
		# paginates to exhaustion; a user-supplied --limit stays an explicit,
		# intentional cap (its truncation is DISCLOSED downstream, see cmd_bulk).
		# OPT_JSON is flipped to 1 in THIS (parent) scope — not inside the
		# capture subshell — so cmd_search emits its {issues:[...]} structure
		# regardless of the user's own --json, then restored so the batch's own
		# later rendering honors the user's choice. ensure_workdir already ran
		# in the MAIN shell (see cmd_bulk), so cmd_search's inner ensure_workdir
		# is a no-op and the capture subshell orphans no WORKDIR. A failed
		# resolve (cmd_search exit 1) fails this assignment under set -e,
		# aborting the batch BEFORE any mutation — the desired fail-closed path
		# (OPT_JSON is not restored on that abort, but the process is exiting).
		if [ -n "$OPT_LIMIT" ]; then SEARCH_UNBOUNDED=0; else SEARCH_UNBOUNDED=1; fi
		bulk_saved_json=$OPT_JSON
		OPT_JSON=1
		bulk_search_json=$(cmd_search)
		OPT_JSON=$bulk_saved_json
		# shellcheck disable=SC2034  # restored for cmd-search.sh's pagination cap, which shellcheck cannot see from this unit
		SEARCH_UNBOUNDED=0
		printf '%s' "$bulk_search_json" | jq -r '.issues[].key // empty' >"$bulk_keys_out_file"
	fi

	# Shape-validate EVERY resolved key before it becomes a URL segment — a
	# --jql set is derived from a network response and is therefore untrusted.
	while IFS= read -r bulk_resolved_key; do
		[ -n "$bulk_resolved_key" ] || continue
		# The key reaches this diagnostic precisely BECAUSE it failed the shape
		# check, so it is arbitrary API-derived bytes — strip control/ANSI
		# sequences before it touches a terminal, the same treatment every other
		# rendered API value gets.
		validate_ticket_key "$bulk_resolved_key" || {
			bulk_resolved_key_safe=$(printf '%s' "$bulk_resolved_key" | strip_control_ansi)
			error "resolved an invalid ticket key: $bulk_resolved_key_safe"
			exit 1
		}
	done <"$bulk_keys_out_file"
}

# validate_keys_csv_or_die — shape-validate EVERY --keys entry as a USAGE error
# (exit 2), before any of them can become a URL path segment or a JSON issues[]
# element. bulk and schedule open with this identically; the split into two
# command files is what would otherwise have duplicated it.
#
# It goes through the SAME split_keys_csv the resolver itself uses, so the set a
# caller is told is valid and the set actually processed can never diverge. A
# --keys that contains only whitespace/commas yields nothing and is a usage
# error too — silently doing nothing to zero issues is not a success.
#
# COUPLING (accepted for this pass): reads $OPT_KEYS directly, per the engine's
# plain-globals convention.
validate_keys_csv_or_die() {
	vkc_seen=0
	while IFS= read -r vkc_key; do
		[ -n "$vkc_key" ] || continue
		vkc_seen=1
		validate_ticket_key "$vkc_key" || { usage >&2; error "invalid ticket key in --keys: $vkc_key"; exit 2; }
	done <<-VKC_KEYS_EOF
	$(split_keys_csv "$OPT_KEYS")
	VKC_KEYS_EOF
	[ "$vkc_seen" -eq 1 ] || { usage >&2; error "--keys contained no ticket keys"; exit 2; }
	return 0
}

# count_nonempty_lines FILE -> the number of non-empty lines in FILE, printed.
# A plain read loop, deliberately NOT `wc -l`: wc is kept off this skill's test
# toolboxes on purpose, and a counter that only works outside the harness is
# worse than no helper at all.
count_nonempty_lines() {
	cnl_total=0
	while IFS= read -r cnl_line; do
		[ -n "$cnl_line" ] || continue
		cnl_total=$((cnl_total + 1))
	done <"$1"
	printf '%s' "$cnl_total"
}

# compute_truncation LABEL TOTAL — the truncation disclosure bulk and schedule
# share, and a load-bearing safety invariant rather than a nicety: a batch must
# NEVER silently mutate a truncated set, nor claim complete success over one.
#
# A --jql resolve with no --limit paginates to exhaustion, so that set is
# complete. An explicit --limit is an intentional cap, but MUST be disclosed
# when the resolved count actually reached it — deliberately conservative, so it
# can over-disclose but never under-disclose. LABEL is the command's own name,
# so the warning reads exactly as it did when each command inlined this.
#
# Publishes $BATCH_TRUNCATED and $BATCH_RESOLVED_LIMIT (see runtime.sh) rather
# than printing, because it must run in THIS shell: the warning goes to stderr
# and a command substitution would strand it in a subshell.
compute_truncation() {
	BATCH_TRUNCATED=false
	BATCH_RESOLVED_LIMIT=null
	if [ -n "$OPT_JQL" ] && [ -n "$OPT_LIMIT" ] && [ "$2" -ge "$OPT_LIMIT" ]; then
		# This pair IS this function's output; both batch commands read it back
		# from their own units, which shellcheck cannot see from here.
		# shellcheck disable=SC2034
		BATCH_TRUNCATED=true
		# shellcheck disable=SC2034
		BATCH_RESOLVED_LIMIT=$OPT_LIMIT
		warn "$1 --jql resolved $2 issue(s), capped at --limit $OPT_LIMIT — additional matches may exist and were NOT included in this batch"
	fi
}
