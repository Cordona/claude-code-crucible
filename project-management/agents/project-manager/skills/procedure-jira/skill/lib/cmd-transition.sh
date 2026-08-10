# shellcheck shell=sh
#
# cmd-transition.sh — `transition <KEY> --status TARGET`: walk the issue from
#                     its current status to TARGET along the BFS-shortest path
#                     over the project config's workflow graph, verifying the
#                     status after EVERY step.
#
# transition --plan (read this before wiring the P4 consent gate):
#   `transition <KEY> --status TARGET --plan` performs EXACTLY ONE network
#   call (fetch the issue's current status/type) and then computes the
#   BFS-shortest walk over the project config's workflow graph LOCALLY —
#   no transition/write endpoint is ever hit in --plan mode, verified by a
#   dedicated test asserting zero POSTs fire. `--plan --json` emits
#   {key, from, to, path, resolution, executed:false} — the SAME shape a
#   real walk's --json emits with executed:true — so the orchestrator can
#   run --plan first, show the human the exact path/resolution/injected
#   comment it discloses, and only THEN (on explicit consent) re-invoke
#   WITHOUT --plan to execute. Never assume the real walk will match the
#   plan byte-for-byte if the two invocations are far apart in time (Jira's
#   own workflow could have changed) — that risk is inherent to any
#   plan/execute split against a live remote system, not specific to this
#   script.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# transition — POST /rest/api/3/issue/<KEY>/transitions, BFS auto-walk
# ---------------------------------------------------------------------------

# BFS_PROGRAM — a single static jq program (never built from data) computing
# the shortest path from $start to $goal over a GRAPH object shaped
# {status: [reachable, statuses, ...], ...} — the same shape as a project
# config's workflows.<issuetype> entry. Returns a JSON array of statuses
# EXCLUDING $start (path[-1] matches $goal), or `null` if unreachable. A
# plain queue+visited-set BFS; workflow graphs are a handful of nodes, so
# recursion depth here is trivial.
#
# the goal comparison is CASE-INSENSITIVE (`ascii_downcase` both
# sides) — a caller's `--status closed` must match a graph node literally
# spelled "Closed", or a spurious "no valid workflow path" results. The
# stored/returned path element is still $n — the GRAPH's own (canonically
# cased) node name — never $goal, so the walked path always displays in
# the config's own casing regardless of how the caller spelled --status.
# shellcheck disable=SC2016  # single-quoted on purpose: $graph/$start/etc below are jq syntax, not shell expansions
BFS_PROGRAM='
def bfs($graph; $start; $goal):
  {frontier: [{node: $start, path: []}], visited: {($start): true}} as $init
  | (
      def step(state):
        if (state.frontier | length) == 0 then null
        else
          (state.frontier[0]) as $cur
          | (state.frontier[1:]) as $rest
          | ($graph[$cur.node] // []) as $neighbors
          | (reduce $neighbors[] as $n
              ({frontier: $rest, visited: state.visited, found: null};
                if .found != null then .
                elif ($n | ascii_downcase) == ($goal | ascii_downcase) then .found = ($cur.path + [$n])
                elif (.visited[$n] // false) then .
                else
                  .visited = (.visited + {($n): true})
                  | .frontier = (.frontier + [{node: $n, path: ($cur.path + [$n])}])
                end
              )
            ) as $next
          | if $next.found != null then $next.found
            else step({frontier: $next.frontier, visited: $next.visited})
            end
        end;
      step($init)
    );
bfs($graph; $start; $goal)
'

# compute_transition_path OUT_FILE CONFIG_FILE ISSUE_TYPE CURRENT TARGET —
# writes a newline-separated walk path (CURRENT excluded, TARGET last) to
# OUT_FILE. No config, no workflow entry for ISSUE_TYPE, or an explicit
# `null` config value (a deliberately "flexible" workflow, e.g. Epic) all
# mean a DIRECT one-step transition (matches the oracle's fallback) — OUT_FILE
# is left EMPTY only when a real graph exists but no path was found.
compute_transition_path() {
	path_out_file=$1
	config_file_for_path=$2
	issue_type_for_path=$3
	current_status_for_path=$4
	target_status_for_path=$5

	workflow_graph_json="null"
	if [ -n "$config_file_for_path" ]; then
		workflow_graph_json=$(jq -c --arg t "$issue_type_for_path" '.workflows[$t] // null' "$config_file_for_path" 2>/dev/null || printf 'null')
		# One level of "@Alias" workflow-reference resolution (e.g. a config's
		# "Story": "@Task" — see the oracle's ProjectConfig._resolve_workflows).
		case "$workflow_graph_json" in
			'"@'*'"')
				alias_issue_type=$(printf '%s' "$workflow_graph_json" | jq -r '.[1:]')
				workflow_graph_json=$(jq -c --arg t "$alias_issue_type" '.workflows[$t] // null' "$config_file_for_path" 2>/dev/null || printf 'null')
				;;
		esac
	fi

	if [ "$workflow_graph_json" = "null" ]; then
		printf '%s\n' "$target_status_for_path" >"$path_out_file"
		return 0
	fi

	# -n is REQUIRED here: with no input filename/redirect, a `jq` invocation
	# without -n blocks reading stdin (it has no input of its own — every
	# value it needs travels via --argjson/--arg) instead of just running the
	# filter once and exiting.
	bfs_result_json=$(jq -nc --argjson graph "$workflow_graph_json" \
		--arg start "$current_status_for_path" --arg goal "$target_status_for_path" \
		"$BFS_PROGRAM" 2>/dev/null || printf 'null')
	if [ -z "$bfs_result_json" ] || [ "$bfs_result_json" = "null" ]; then
		: >"$path_out_file"
		return 0
	fi
	printf '%s' "$bfs_result_json" | jq -r '.[]' >"$path_out_file"
}

# split_tab_pair LINE — sets $TAB_PAIR_FIRST/$TAB_PAIR_SECOND from a
# "FIRST<TAB>SECOND" line (the shape find_transition_id_and_name emits) —
# the same tab-per-field idiom render_workflow_human already reads with
# `IFS="$(printf '\t')" read -r`, applied here to a captured variable
# instead of a piped stream.
split_tab_pair() {
	old_ifs=$IFS
	IFS="$(printf '\t')"
	set -f
	# shellcheck disable=SC2086  # deliberate tab-split; -f (above) blocks globbing
	set -- $1
	set +f
	IFS=$old_ifs
	TAB_PAIR_FIRST=$1
	TAB_PAIR_SECOND=${2:-}
}

# find_transition_id_and_name TICKET_KEY TARGET_STATUS_NAME -> prints
# "ID<TAB>CANONICAL_NAME" for the transition whose .to.name matches
# TARGET_STATUS_NAME case-insensitively (matches the oracle's
# `t['to']['name'].lower() == target_status.lower()`), or nothing if none
# match. Returning Jira's OWN canonically-cased .to.name — not the caller's
# possibly differently-cased TARGET_STATUS_NAME — lets verify_status_is
# compare against the exact string the API will report back after the
# write, so a caller's `--status closed` verifies correctly against the
# API's actual "Closed".
#
# F3 (live-testing note): a real workflow can legitimately offer TWO
# transitions with the SAME .to.name (seen live: two distinct "In
# Progress" transitions on one status). The match is DETERMINISTIC — the
# FIRST one in Jira's own `.transitions[]` response order, via jq's `[0]`
# over that array's original order, never re-sorted — but a silent pick
# between two same-named-but-different transitions is worth surfacing, so
# an ambiguous match gets a one-line stderr note naming the count.
find_transition_id_and_name() {
	transition_lookup_key=$1
	transition_target_name=$2
	transitions_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${transition_lookup_key}/transitions"
	jira_curl GET "$transitions_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch transitions for $transition_lookup_key"
	require_json_body "fetch transitions for $transition_lookup_key"

	matching_transition_count=$(jq -r --arg t "$transition_target_name" \
		'[.transitions[] | select((.to.name // "") | ascii_downcase == ($t | ascii_downcase))] | length' \
		"$JIRA_HTTP_BODY_FILE")
	if [ "$matching_transition_count" -gt 1 ]; then
		warn "$matching_transition_count transitions on $transition_lookup_key are named '$transition_target_name' — picking the first"
	fi

	jq -r --arg t "$transition_target_name" \
		'[.transitions[] | select((.to.name // "") | ascii_downcase == ($t | ascii_downcase))][0]
		 | if . == null then empty else "\(.id)\t\(.to.name)" end' \
		"$JIRA_HTTP_BODY_FILE"
}

# execute_plain_transition TICKET_KEY TRANSITION_ID — a step with no
# resolution attached. Jira returns 204 No Content on success — deliberately
# NO require_json_body call here (an empty body IS the correct success shape).
execute_plain_transition() {
	exec_ticket_key=$1
	exec_transition_id=$2
	ensure_workdir
	TRANS_COUNTER=$((TRANS_COUNTER + 1))
	transition_body_file="$WORKDIR/transition-body-$TRANS_COUNTER.json"
	jq -n --arg id "$exec_transition_id" '{transition: {id: $id}}' >"$transition_body_file"
	step_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${exec_ticket_key}/transitions"
	jira_curl POST "$step_url" "$transition_body_file"
	handle_http_status "$JIRA_HTTP_CODE" "transition $exec_ticket_key (id $exec_transition_id)"
}

# execute_transition_with_resolution TICKET_KEY TRANSITION_ID RESOLUTION —
# the FINAL-step variant (matches the oracle's _transition_with_resolution):
# sets fields.resolution AND appends a system-generated closing comment in
# the SAME request, via REST fields{}/update{} — not the oracle's acli shape.
execute_transition_with_resolution() {
	exec_ticket_key=$1
	exec_transition_id=$2
	exec_resolution=$3
	ensure_workdir
	TRANS_COUNTER=$((TRANS_COUNTER + 1))
	transition_body_file="$WORKDIR/transition-body-$TRANS_COUNTER.json"
	jq -n --arg id "$exec_transition_id" --arg resolution "$exec_resolution" \
		--arg comment_text "Closed with resolution: $exec_resolution" \
		'{transition: {id: $id},
		  fields: {resolution: {name: $resolution}},
		  update: {comment: [{add: {body: {type: "doc", version: 1,
		    content: [{type: "paragraph", content: [{type: "text", text: $comment_text}]}]}}}]}}' \
		>"$transition_body_file"
	step_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${exec_ticket_key}/transitions"
	jira_curl POST "$step_url" "$transition_body_file"
	handle_http_status "$JIRA_HTTP_CODE" "transition $exec_ticket_key with resolution '$exec_resolution'"
}

# verify_status_is TICKET_KEY EXPECTED_STATUS — re-fetches the
# issue's CURRENT status after every write step and fails loud (exit 1) if
# it does not match, instead of trusting a 2xx/204 as proof the transition
# actually applied (a workflow condition/validator can reject silently).
verify_status_is() {
	verify_ticket_key=$1
	verify_expected_status=$2
	verify_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${verify_ticket_key}?fields=status"
	jira_curl GET "$verify_url"
	handle_http_status "$JIRA_HTTP_CODE" "verify status for $verify_ticket_key"
	require_json_body "verify status for $verify_ticket_key"
	verify_actual_status=$(jq -r '.fields.status.name // ""' "$JIRA_HTTP_BODY_FILE")
	if [ "$verify_actual_status" != "$verify_expected_status" ]; then
		error "transition to '$verify_expected_status' for $verify_ticket_key did not apply (status is still '$verify_actual_status')"
		exit 1
	fi
}

# walk_transition_path TICKET_KEY PATH_FILE RESOLUTION — walks each step of
# PATH_FILE in order, verifying status after EACH step. The LAST
# step, when RESOLUTION is non-empty, is submitted WITH the resolution (see
# execute_transition_with_resolution); every other step is a plain
# transition. Reads PATH_FILE via redirection (not a pipe) so the loop runs
# in THIS shell, not a subshell — matching md-to-adf.sh's own read-loop
# idiom — since `exit` inside a piped subshell would not reliably read as
# "this whole script failed" to every reader of this code.
walk_transition_path() {
	walk_ticket_key=$1
	walk_path_file=$2
	walk_resolution=$3

	walk_last_step=$(tail -n 1 "$walk_path_file")

	while IFS= read -r walk_step; do
		[ -n "$walk_step" ] || continue
		walk_id_and_name=$(find_transition_id_and_name "$walk_ticket_key" "$walk_step")
		if [ -z "$walk_id_and_name" ]; then
			error "no transition to '$walk_step' available for $walk_ticket_key"
			exit 1
		fi
		split_tab_pair "$walk_id_and_name"
		walk_transition_id=$TAB_PAIR_FIRST
		# verify against Jira's OWN canonical name for this step
		# (not $walk_step, which may carry the caller's original casing) —
		# see find_transition_id_and_name's header note.
		walk_canonical_name=$TAB_PAIR_SECOND

		if [ "$walk_step" = "$walk_last_step" ] && [ -n "$walk_resolution" ]; then
			execute_transition_with_resolution "$walk_ticket_key" "$walk_transition_id" "$walk_resolution"
		else
			execute_plain_transition "$walk_ticket_key" "$walk_transition_id"
		fi

		verify_status_is "$walk_ticket_key" "$walk_canonical_name"
	done <"$walk_path_file"
}

# render_transition_summary_json KEY FROM TO PATH_FILE RESOLUTION EXECUTED
# [ALREADY_AT_TARGET] — the ONE --json shape for --plan (EXECUTED=false), a
# real walk (EXECUTED=true), AND the already-at-target no-op — all
# three routed through this single renderer so they can never
# drift into three different ad-hoc object shapes. ALREADY_AT_TARGET
# defaults to "false" when the caller omits it (--plan / a real walk always
# have a genuine path to walk, so they never need to pass it explicitly).
render_transition_summary_json() {
	summary_key=$1
	summary_from=$2
	summary_to=$3
	summary_path_file=$4
	summary_resolution=$5
	summary_executed=$6
	summary_already_at_target=${7:-false}
	jq -n --arg key "$summary_key" --arg from "$summary_from" --arg to "$summary_to" \
		--arg resolution "$summary_resolution" --rawfile path_raw "$summary_path_file" \
		--argjson executed "$summary_executed" --argjson alreadyAtTarget "$summary_already_at_target" \
		'{key: $key, from: $from, to: $to,
		  path: ($path_raw | split("\n") | map(select(length > 0))),
		  resolution: (if ($resolution | length) > 0 then $resolution else null end),
		  executed: $executed,
		  alreadyAtTarget: $alreadyAtTarget}'
}

# render_transition_plan_human KEY FROM TO PATH_FILE RESOLUTION — the
# --plan human render: the FULL walked path + any injected resolution,
# WITHOUT writing anything (what the P4 consent gate discloses).
render_transition_plan_human() {
	plan_key=$1
	plan_from=$2
	plan_to=$3
	plan_path_file=$4
	plan_resolution=$5
	printf 'PLAN for %s: %s -> %s\n' "$plan_key" "$plan_from" "$plan_to"
	plan_step_num=0
	while IFS= read -r plan_step; do
		[ -n "$plan_step" ] || continue
		plan_step_num=$((plan_step_num + 1))
		printf '  step %d: -> %s\n' "$plan_step_num" "$plan_step"
	done <"$plan_path_file"
	if [ -n "$plan_resolution" ]; then
		printf 'Will set resolution: %s\n' "$plan_resolution"
		printf 'Will add a system comment: "Closed with resolution: %s"\n' "$plan_resolution"
	fi
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

cmd_transition() {
	# TICKET_KEY/--status presence is validated up front — see the main
	# dispatch section's per-command required-argument validation.
	#
	# ensure_workdir runs FIRST, unconditionally — every branch below
	# (including the already-at-target no-op) needs a WORKDIR file at some
	# point, and calling it once here (rather than deep in one branch only)
	# is what the fix pattern in cmd_create/cmd_comment establishes:
	# have it ready before any subshell call could reach jira_curl() first.
	ensure_workdir

	load_config_for_ticket_key "$TICKET_KEY"

	current_status_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=status,issuetype"
	jira_curl GET "$current_status_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch current status for $TICKET_KEY"
	require_json_body "fetch current status for $TICKET_KEY"
	current_status=$(jq -r '.fields.status.name // ""' "$JIRA_HTTP_BODY_FILE")
	current_issue_type=$(jq -r '.fields.issuetype.name // ""' "$JIRA_HTTP_BODY_FILE")
	if [ -z "$current_status" ]; then
		error "could not determine current status for $TICKET_KEY"
		exit 1
	fi

	target_status=$OPT_STATUS
	# Live-testing defect: resolution is STRICTLY OPT-IN — set ONLY
	# when the caller explicitly passes --resolution. This engine used to
	# auto-default resolution="Resolved" whenever the target was (case-
	# insensitively) "Closed", but a workflow whose Closed screen has NO
	# resolution field then gets a live HTTP 400 ("Field 'resolution'
	# cannot be set. It is not on the appropriate screen, or unknown.") —
	# confirmed against a real Jira site. A workflow that genuinely
	# REQUIRES a resolution still 400s clearly and the caller re-runs with
	# --resolution; this engine no longer guesses on the caller's behalf.
	transition_resolution=$OPT_RESOLUTION

	# compare case-insensitively — current_status is Jira's own
	# canonical casing; target_status is whatever the caller typed
	# (`--status closed` is exactly as valid as `--status Closed`). Display
	# uses current_status (the authoritative value) for both from/to, so
	# the message never shows two different spellings of the same status.
	if [ "$(downcase "$current_status")" = "$(downcase "$target_status")" ]; then
		already_at_target_path_file="$WORKDIR/transition-empty-path.txt"
		: >"$already_at_target_path_file"
		if [ "$OPT_JSON" -eq 1 ]; then
			# routed through the SAME shared renderer
			# --plan and a real walk use — see render_transition_summary_json's
			# header note on why a third hand-built shape is a defect.
			render_transition_summary_json "$TICKET_KEY" "$current_status" "$current_status" \
				"$already_at_target_path_file" "" false true
		else
			printf '%s is already "%s"\n' "$TICKET_KEY" "$current_status"
		fi
		return 0
	fi

	transition_path_file="$WORKDIR/transition-path.txt"
	compute_transition_path "$transition_path_file" "$PROJECT_CONFIG_FILE" "$current_issue_type" "$current_status" "$target_status"

	if [ ! -s "$transition_path_file" ]; then
		error "no valid workflow path from '$current_status' to '$target_status' for issue type '$current_issue_type'"
		exit 1
	fi

	if [ "$OPT_PLAN" -eq 1 ]; then
		if [ "$OPT_JSON" -eq 1 ]; then
			# SYNTHESIZED, not passthrough — --plan never calls the
			# transitions-write endpoint at all (that is the whole point of
			# --plan), so there is no Jira response to pass through; this is
			# the locally-computed disclosure the P4 consent gate shows.
			render_transition_summary_json "$TICKET_KEY" "$current_status" "$target_status" "$transition_path_file" "$transition_resolution" false
		else
			render_transition_plan_human "$TICKET_KEY" "$current_status" "$target_status" "$transition_path_file" "$transition_resolution"
		fi
		return 0
	fi

	walk_transition_path "$TICKET_KEY" "$transition_path_file" "$transition_resolution"

	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED — each individual transition POST in the walk
		# returns 204 No Content (nothing to pass through); this summarizes
		# the whole multi-step walk this script just performed.
		render_transition_summary_json "$TICKET_KEY" "$current_status" "$target_status" "$transition_path_file" "$transition_resolution" true
	else
		printf 'JIRA_TRANSITIONED_TO=%s\n' "$target_status"
	fi
}

# validate_transition_args() — `transition`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_transition_args() {
	require_ticket_positional transition
	[ -n "$OPT_STATUS" ] || { usage >&2; error "transition requires --status TARGET"; exit 2; }
	return 0
}
