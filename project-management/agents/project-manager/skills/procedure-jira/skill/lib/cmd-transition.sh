# shellcheck shell=sh
#
# cmd-transition.sh — `transition <KEY> --status TARGET`: walk the issue from
#                     its current status to TARGET along the BFS-shortest path
#                     over the project config's workflow graph, verifying the
#                     status after EVERY step. `transition <KEY>
#                     --transition-id N`: POST that one exact transition as a
#                     single step (no walk, no project config).
#
# transition --plan (read this before wiring the P4 consent gate):
#   `transition <KEY> --status TARGET --plan` performs ONE network call
#   (fetch the issue's current status/type) and then computes the
#   BFS-shortest walk over the project config's workflow graph LOCALLY —
#   no transition/write endpoint is ever hit in --plan mode, verified by a
#   dedicated test asserting zero POSTs fire. A SINGLE-step plan (and
#   `--transition-id`) adds ONE more READ, the transitions GET, which settles
#   before consent what the run would otherwise only learn at execution:
#   which transition it takes when 2+ reach the target (disclosed — see
#   plan_inspect_path), and whether a `--resolution` can be set on that step
#   (see check_transition_resolution). A MULTI-step path cannot be inspected
#   that way, because Jira lists only the transitions available from the
#   CURRENT status; its plan marks a resolution unverified and ambiguousSteps
#   null, and the walk checks immediately before each step instead.
#   `--plan --json` emits {key, from, to, path, resolution,
#   resolutionChecked, transitionId, ambiguousSteps, readBack,
#   executed:false, alreadyAtTarget} — the SAME shape a real
#   walk's --json emits with executed:true — so the orchestrator can
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

# find_transition_for_status TICKET_KEY TARGET_STATUS_NAME — publishes, as
# TRANSITION_MATCH_ID/TRANSITION_MATCH_NAME, the transition whose .to.name
# matches TARGET_STATUS_NAME case-insensitively (matches the oracle's
# `t['to']['name'].lower() == target_status.lower()`), or two empty values if
# none match. Publishing Jira's OWN canonically-cased .to.name — not the
# caller's possibly differently-cased TARGET_STATUS_NAME — lets verify_status_is
# compare against the exact string the API will report back after the write,
# so a caller's `--status closed` verifies correctly against "Closed".
#
# Called in THIS shell, never inside `$(...)`: the transitions body it leaves in
# $JIRA_HTTP_BODY_FILE is what check_transition_resolution reads next.
#
# F3 (live-testing note): a real workflow can legitimately offer TWO
# transitions with the SAME .to.name (seen live: "In Progress" and "Dev in
# progress" both reaching "In Progress"). The match is DETERMINISTIC — the
# FIRST one in Jira's own `.transitions[]` response order, never re-sorted —
# but a silent pick between two different transitions is worth surfacing, so
# an ambiguous match gets a one-line stderr note naming every candidate and
# pointing at --transition-id, which selects one exactly — and is appended to
# TRANSITION_AMBIGUITY_JSON, which --json reports as ambiguousSteps and a
# --plan discloses on stdout BEFORE consent (a live run once warned about a
# choice its approved plan had never mentioned).
find_transition_for_status() {
	ftfs_key=$1
	ftfs_target=$2
	fetch_issue_transitions "$ftfs_key"
	# ONE pass over the response summarizes every match (jq only — the
	# engine's test toolbox, and so its dependency list, has no head/cut/awk).
	ftfs_summary=$(jq -c --arg t "$ftfs_target" \
		'[.transitions[] | select((.to.name // "") | ascii_downcase == ($t | ascii_downcase))]
		 | {count: length, id: (.[0].id // ""), name: (.[0].to.name // ""),
		    candidates: (map("\(.id) (\(.name // ""))") | join(", ")),
		    candidateList: map({id: (.id // ""), name: (.name // "")})}' \
		"$JIRA_HTTP_BODY_FILE")
	TRANSITION_MATCH_ID=$(printf '%s' "$ftfs_summary" | jq -r '.id')
	TRANSITION_MATCH_NAME=$(printf '%s' "$ftfs_summary" | jq -r '.name')
	ftfs_count=$(printf '%s' "$ftfs_summary" | jq -r '.count')
	if [ "$ftfs_count" -le 1 ]; then
		return 0
	fi
	TRANSITION_AMBIGUITY_JSON=$(jq -c -n --argjson seen "$TRANSITION_AMBIGUITY_JSON" --argjson s "$ftfs_summary" \
		'($seen // []) + [{to: $s.name, pickedId: $s.id, candidates: $s.candidateList}]')
	# --plan discloses the same choice on stdout (render_transition_plan_human),
	# where the consent gate reads it — a stderr copy there is only noise.
	if [ "$OPT_PLAN" -eq 0 ]; then
		ftfs_candidates=$(printf '%s' "$ftfs_summary" | jq -r '.candidates')
		warn "$ftfs_count transitions on $ftfs_key are named '$(one_line_display "$ftfs_target")' — picking the first (id $(one_line_display "$TRANSITION_MATCH_ID")); candidates: $(one_line_display "$ftfs_candidates") — pass --transition-id N instead of --status to choose one explicitly"
	fi
}

# find_transition_by_id TICKET_KEY TRANSITION_ID — publishes the transition
# with exactly that id as TRANSITION_MATCH_ID/TRANSITION_MATCH_NAME (its
# .to.name), or two empty values when it is not CURRENTLY available on the
# issue. Leaves the transitions body in $JIRA_HTTP_BODY_FILE, like its sibling.
find_transition_by_id() {
	ftbi_key=$1
	ftbi_id=$2
	fetch_issue_transitions "$ftbi_key"
	TRANSITION_MATCH_NAME=$(jq -r --arg id "$ftbi_id" \
		'[.transitions[] | select(.id == $id)][0] | if . == null then "" else (.to.name // "") end' \
		"$JIRA_HTTP_BODY_FILE")
	if [ -n "$TRANSITION_MATCH_NAME" ]; then
		TRANSITION_MATCH_ID=$ftbi_id
	else
		TRANSITION_MATCH_ID=""
	fi
}

# check_transition_resolution TICKET_KEY RESOLUTION [WALK_NOTE] — run right after one of the
# two finders above, against the transitions body it left behind (fetched with
# ?expand=transitions.fields): confirms transition TRANSITION_MATCH_ID can take
# a resolution at all, and — when Jira lists allowedValues — that RESOLUTION is
# one of them, case-insensitively. Publishes the value to SEND as
# TRANSITION_RESOLUTION_TO_SEND: the allowed value's own canonical spelling when
# one matched, RESOLUTION untouched otherwise.
#
# WHY IT FAILS CLOSED BEFORE THE POST. Verified live: a CLOSED transition with
# no screen answered `--resolution "Won't Do"` with HTTP 400 ("Field
# 'resolution' cannot be set. It is not on the appropriate screen, or
# unknown.") — AFTER a --plan had promised the caller that resolution. Checking
# here makes the plan honest and turns the 400 into a named refusal before any
# write. Every API string in the diagnostics is folded onto its one line.
# WALK_NOTE, when given, is appended to either refusal: a multi-step walk only
# reaches this check at its LAST step, and the caller must learn that the
# earlier steps have already been applied.
check_transition_resolution() {
	ctr_key=$1
	ctr_resolution=$2
	ctr_walk_note=${3:-}
	ctr_transition_file="$WORKDIR/transition-checked.json"
	jq --arg id "$TRANSITION_MATCH_ID" '[.transitions[] | select(.id == $id)][0]' \
		"$JIRA_HTTP_BODY_FILE" >"$ctr_transition_file"
	ctr_name=$(jq -r '.name // ""' "$ctr_transition_file")
	ctr_label="transition '$(one_line_display "$ctr_name")' (id $(one_line_display "$TRANSITION_MATCH_ID"), -> '$(one_line_display "$TRANSITION_MATCH_NAME")') on $ctr_key"
	if ! jq -e '.fields.resolution != null' "$ctr_transition_file" >/dev/null; then
		error "$ctr_label accepts no resolution — its screen has no resolution field, so Jira would reject --resolution '$(one_line_display "$ctr_resolution")' with a 400. Re-run without --resolution (the workflow may set one itself).$ctr_walk_note"
		exit 1
	fi
	ctr_allowed_count=$(jq '(.fields.resolution.allowedValues // []) | length' "$ctr_transition_file")
	if [ "$ctr_allowed_count" -eq 0 ]; then
		TRANSITION_RESOLUTION_TO_SEND=$ctr_resolution
		return 0
	fi
	TRANSITION_RESOLUTION_TO_SEND=$(jq -r --arg r "$ctr_resolution" \
		'[.fields.resolution.allowedValues[] | objects | .name // empty
		  | select(ascii_downcase == ($r | ascii_downcase))][0] // ""' \
		"$ctr_transition_file")
	if [ -z "$TRANSITION_RESOLUTION_TO_SEND" ]; then
		ctr_allowed=$(jq -r '[.fields.resolution.allowedValues[] | objects | .name // empty] | join(", ")' "$ctr_transition_file")
		error "$ctr_label does not accept resolution '$(one_line_display "$ctr_resolution")' — allowed: $(one_line_display "$ctr_allowed").$ctr_walk_note"
		exit 1
	fi
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
# The same GET also carries resolution + assignee, published as
# VERIFIED_BODY_FILE, so the read-back after the LAST step costs no extra call.
verify_status_is() {
	verify_ticket_key=$1
	verify_expected_status=$2
	verify_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${verify_ticket_key}?fields=status,resolution,assignee"
	jira_curl GET "$verify_url"
	handle_http_status "$JIRA_HTTP_CODE" "verify status for $verify_ticket_key"
	require_json_body "verify status for $verify_ticket_key"
	verify_actual_status=$(jq -r '.fields.status.name // ""' "$JIRA_HTTP_BODY_FILE")
	if [ "$verify_actual_status" != "$verify_expected_status" ]; then
		error "transition to '$verify_expected_status' for $verify_ticket_key did not apply (status is still '$verify_actual_status')"
		exit 1
	fi
	VERIFIED_BODY_FILE=$JIRA_HTTP_BODY_FILE
}

# walk_transition_path TICKET_KEY PATH_FILE RESOLUTION — walks each step of
# PATH_FILE in order, verifying status after EACH step. The LAST
# step, when RESOLUTION is non-empty, is first checked (check_transition_
# resolution — the earliest point its transitions are listable) and then
# submitted WITH the resolution (see execute_transition_with_resolution);
# every other step is a plain transition. Reads PATH_FILE via redirection (not
# a pipe) so the loop runs in THIS shell, not a subshell — matching
# md-to-adf.sh's own read-loop idiom — since `exit` inside a piped subshell
# would not reliably read as "this whole script failed" to every reader of
# this code.
walk_transition_path() {
	walk_ticket_key=$1
	walk_path_file=$2
	walk_resolution=$3

	walk_last_step=$(tail -n 1 "$walk_path_file")
	walk_reached=""

	while IFS= read -r walk_step; do
		[ -n "$walk_step" ] || continue
		find_transition_for_status "$walk_ticket_key" "$walk_step"
		if [ -z "$TRANSITION_MATCH_ID" ]; then
			error "no transition to '$walk_step' available for $walk_ticket_key"
			exit 1
		fi
		# verify against Jira's OWN canonical name for this step (not
		# $walk_step, which may carry the caller's original casing) — see
		# find_transition_for_status's header note.
		walk_transition_id=$TRANSITION_MATCH_ID
		walk_canonical_name=$TRANSITION_MATCH_NAME

		if [ "$walk_step" = "$walk_last_step" ] && [ -n "$walk_resolution" ]; then
			walk_note=""
			[ -z "$walk_reached" ] || walk_note=" The walk's earlier steps HAVE been applied: $walk_ticket_key is now in '$(one_line_display "$walk_reached")' and stays there."
			check_transition_resolution "$walk_ticket_key" "$walk_resolution" "$walk_note"
			TRANSITION_RESOLUTION_CHECKED=true
			execute_transition_with_resolution "$walk_ticket_key" "$walk_transition_id" "$TRANSITION_RESOLUTION_TO_SEND"
		else
			execute_plain_transition "$walk_ticket_key" "$walk_transition_id"
		fi

		verify_status_is "$walk_ticket_key" "$walk_canonical_name"
		walk_reached=$walk_canonical_name
	done <"$walk_path_file"
}

# render_transition_summary_json KEY FROM TO PATH_FILE RESOLUTION EXECUTED
# [ALREADY_AT_TARGET] — the ONE --json shape for --plan (EXECUTED=false), a
# real walk (EXECUTED=true), AND the already-at-target no-op — all
# three routed through this single renderer so they can never
# drift into three different ad-hoc object shapes. ALREADY_AT_TARGET
# defaults to "false" when the caller omits it (--plan / a real walk always
# have a genuine path to walk, so they never need to pass it explicitly).
#
# Four keys come from the TRANSITION_* globals cmd_transition resets per run
# rather than from more positional parameters: ambiguousSteps (each step where
# 2+ transitions reach the same status: {to, pickedId, candidates[{id,name}]};
# [] when none, null when a multi-step --plan could not look), transitionId (the
# --transition-id used, else null), resolutionChecked (true once
# check_transition_resolution passed, false when a --plan could not check a
# multi-step path's final step, null with no --resolution) and readBack (the
# post-walk read-back, null unless a write ran).
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
		--arg transitionId "$TRANSITION_ID_USED" --argjson resolutionChecked "$TRANSITION_RESOLUTION_CHECKED" \
		--argjson readBack "$TRANSITION_READBACK_JSON" --argjson ambiguousSteps "$TRANSITION_AMBIGUITY_JSON" \
		'{key: $key, from: $from, to: $to,
		  path: ($path_raw | split("\n") | map(select(length > 0))),
		  resolution: (if ($resolution | length) > 0 then $resolution else null end),
		  resolutionChecked: $resolutionChecked,
		  transitionId: (if ($transitionId | length) > 0 then $transitionId else null end),
		  ambiguousSteps: $ambiguousSteps,
		  readBack: $readBack,
		  executed: $executed,
		  alreadyAtTarget: $alreadyAtTarget}'
}

# render_transition_plan_human KEY FROM TO PATH_FILE RESOLUTION — the
# --plan human render: the FULL walked path + any injected resolution,
# WITHOUT writing anything (what the P4 consent gate discloses). FROM, a
# --transition-id's TO/step and a checked RESOLUTION are Jira's own text, so
# every value goes through one_line_display (runtime.sh): no crafted status
# name can forge a consent-gate row, and non-ASCII names stay intact. A resolution
# the plan could NOT verify (TRANSITION_RESOLUTION_CHECKED=false — a multi-step
# path) is disclosed as unverified, never promised.
render_transition_plan_human() {
	plan_key=$1
	plan_from=$2
	plan_to=$3
	plan_path_file=$4
	plan_resolution=$5
	printf 'PLAN for %s: %s -> %s\n' "$plan_key" "$(one_line_display "$plan_from")" "$(one_line_display "$plan_to")"
	plan_step_num=0
	while IFS= read -r plan_step; do
		[ -n "$plan_step" ] || continue
		plan_step_num=$((plan_step_num + 1))
		printf '  step %d: -> %s\n' "$plan_step_num" "$(one_line_display "$plan_step")"
	done <"$plan_path_file"
	if [ -n "$TRANSITION_ID_USED" ]; then
		printf 'Via transition id %s (exactly that transition, no walk).\n' "$TRANSITION_ID_USED"
	fi
	render_plan_ambiguity_human
	if [ -n "$plan_resolution" ]; then
		plan_resolution_shown=$(one_line_display "$plan_resolution")
		printf 'Will set resolution: %s\n' "$plan_resolution_shown"
		printf 'Will add a system comment: "Closed with resolution: %s"\n' "$plan_resolution_shown"
		if [ "$TRANSITION_RESOLUTION_CHECKED" = false ]; then
			printf 'RESOLUTION NOT VERIFIED: Jira lists only the transitions available from the CURRENT status, so whether the final step accepts a resolution is checked only immediately before that step runs. If it does not, the walk stops there — AFTER the earlier steps have been applied.\n'
		fi
	fi
	printf 'NOTHING WAS WRITTEN (dry-run / --plan).\n'
}

# render_plan_ambiguity_human — what the plan knows about WHICH transition
# each step takes. For every ambiguous step it could see
# (TRANSITION_AMBIGUITY_JSON): the transition the run WOULD take, every
# candidate, and the --transition-id way to choose. When it could not look
# (null — a multi-step path, whose later steps are not listable from the
# current status) it says so rather than printing nothing, since silence reads
# as "no ambiguity". API names fold through JQ_ONE_LINE_DEF (runtime.sh), then
# strip_control_ansi.
render_plan_ambiguity_human() {
	if [ "$TRANSITION_AMBIGUITY_JSON" = null ]; then
		printf 'TRANSITIONS NOT VERIFIED: Jira lists only the transitions available from the CURRENT status, so which transition each step of this walk takes is decided as it runs — where 2+ transitions reach a step'"'"'s status the walk takes the first (and warns). Use --transition-id N, one step at a time, to control each choice.\n'
		return 0
	fi
	printf '%s\n' "$TRANSITION_AMBIGUITY_JSON" \
		| jq -r "$JQ_ONE_LINE_DEF"'.[] | "AMBIGUOUS STEP: \(.candidates | length) transitions lead to \"\(.to | one_line)\" — would take id \(.pickedId | one_line) (\(.candidates[0].name | one_line)); candidates: \(.candidates | map("\(.id | one_line) (\(.name | one_line))") | join(", ")). Pass --transition-id N instead of --status to choose one explicitly."' \
		| strip_control_ansi
}

cmd_transition() {
	# TICKET_KEY and exactly one of --status/--transition-id are validated up
	# front — see the main dispatch section's per-command validation.
	#
	# ensure_workdir runs FIRST, unconditionally — every branch below
	# (including the already-at-target no-op) needs a WORKDIR file at some
	# point, and calling it once here (rather than deep in one branch only)
	# is what the fix pattern in cmd_create/cmd_comment establishes:
	# have it ready before any subshell call could reach jira_curl() first.
	ensure_workdir

	# Per-run state, reset HERE because `bulk --op transition` runs this
	# function once per issue and must never carry one issue's read-back into
	# the next issue's summary.
	TRANSITION_ID_USED=""
	TRANSITION_RESOLUTION_CHECKED=null
	TRANSITION_READBACK_JSON=null
	TRANSITION_AMBIGUITY_JSON='[]'

	TRANSITION_RESOLUTION_TO_SEND=$OPT_RESOLUTION

	# --transition-id names ONE exact transition, so it needs no workflow
	# graph — and must not fail on a malformed config it never reads.
	if [ -z "$OPT_TRANSITION_ID" ]; then
		load_config_for_ticket_key "$TICKET_KEY"
	fi

	fetch_pre_transition_state

	if [ -n "$OPT_TRANSITION_ID" ]; then
		transition_by_id
	else
		transition_to_status
	fi
}

# fetch_pre_transition_state — the ONE initial read: status + issue type (the
# walk's start and graph key) and resolution + assignee (the "before" half of
# the post-walk read-back), published as the PRE_TRANSITION_* globals.
fetch_pre_transition_state() {
	fpts_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${TICKET_KEY}?fields=status,issuetype,resolution,assignee"
	jira_curl GET "$fpts_url"
	handle_http_status "$JIRA_HTTP_CODE" "fetch current status for $TICKET_KEY"
	require_json_body "fetch current status for $TICKET_KEY"
	PRE_TRANSITION_STATUS=$(jq -r '.fields.status.name // ""' "$JIRA_HTTP_BODY_FILE")
	PRE_TRANSITION_ISSUE_TYPE=$(jq -r '.fields.issuetype.name // ""' "$JIRA_HTTP_BODY_FILE")
	PRE_TRANSITION_STATE_FILE=$JIRA_HTTP_BODY_FILE
	if [ -z "$PRE_TRANSITION_STATUS" ]; then
		error "could not determine current status for $TICKET_KEY"
		exit 1
	fi
}

# transition_to_status — `--status TARGET`: plan or walk the BFS path.
transition_to_status() {
	current_status=$PRE_TRANSITION_STATUS
	current_issue_type=$PRE_TRANSITION_ISSUE_TYPE
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
		plan_inspect_path "$transition_path_file" "$transition_resolution"
		transition_resolution=$TRANSITION_RESOLUTION_TO_SEND
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
	report_transition_read_back

	if [ "$OPT_JSON" -eq 1 ]; then
		# SYNTHESIZED — each individual transition POST in the walk
		# returns 204 No Content (nothing to pass through); this summarizes
		# the whole multi-step walk this script just performed.
		render_transition_summary_json "$TICKET_KEY" "$current_status" "$target_status" "$transition_path_file" "$TRANSITION_RESOLUTION_TO_SEND" true
	else
		printf 'JIRA_TRANSITIONED_TO=%s\n' "$target_status"
		print_transition_read_back_lines
	fi
}

# plan_inspect_path PATH_FILE RESOLUTION — what --plan can verify about the
# step(s) before consent. A ONE-step path's transition is listable right now,
# so ONE transitions GET settles both things the real run would otherwise only
# learn at execution: WHICH transition it takes (a duplicate target is
# recorded by find_transition_for_status and disclosed by the plan) and, when
# RESOLUTION is given, whether that step can take it (a refusal here is a
# refusal of the plan itself). A step not available from the current status
# fails the plan, exactly as it would fail the run. A MULTI-step path's later
# steps are not listable until the walk reaches them, so nothing is fetched:
# ambiguousSteps is null (unchecked) and a resolution is marked unverified.
plan_inspect_path() {
	pip_path_file=$1
	pip_resolution=$2
	if [ "$(grep -c . "$pip_path_file" || true)" -gt 1 ]; then
		TRANSITION_AMBIGUITY_JSON=null
		[ -z "$pip_resolution" ] || TRANSITION_RESOLUTION_CHECKED=false
		return 0
	fi
	pip_step=$(grep . "$pip_path_file")
	find_transition_for_status "$TICKET_KEY" "$pip_step"
	if [ -z "$TRANSITION_MATCH_ID" ]; then
		error "no transition to '$pip_step' available for $TICKET_KEY"
		exit 1
	fi
	if [ -n "$pip_resolution" ]; then
		check_transition_resolution "$TICKET_KEY" "$pip_resolution"
		TRANSITION_RESOLUTION_CHECKED=true
	fi
}

# transition_by_id — `--transition-id N`: ONE direct step, POSTing exactly
# transition N. It must be available from the issue's CURRENT status (Jira's
# own transitions list is the authority; nothing is looked up in a project
# config), and the status afterwards must equal that transition's to.name.
# There is no already-at-target short-circuit: a transition whose target is
# the current status (a self-loop such as "Reopen") is a real transition the
# caller named on purpose.
transition_by_id() {
	find_transition_by_id "$TICKET_KEY" "$OPT_TRANSITION_ID"
	if [ -z "$TRANSITION_MATCH_ID" ]; then
		error "transition id $OPT_TRANSITION_ID is not available on $TICKET_KEY from its current status '$(one_line_display "$PRE_TRANSITION_STATUS")' — run \`workflow $TICKET_KEY\` to list the transitions it offers now"
		exit 1
	fi
	TRANSITION_ID_USED=$TRANSITION_MATCH_ID
	tbi_target=$TRANSITION_MATCH_NAME
	if [ -n "$OPT_RESOLUTION" ]; then
		check_transition_resolution "$TICKET_KEY" "$OPT_RESOLUTION"
		TRANSITION_RESOLUTION_CHECKED=true
	fi
	tbi_path_file="$WORKDIR/transition-path.txt"
	# The path file is LINE-oriented (one step per line, for the plan render
	# and --json's .path), and tbi_target is Jira's own to.name: written raw, a
	# newline inside it would become a second, forged step. So the file gets
	# the one-line display copy; the raw value stays what verify_status_is
	# compares and what --json reports as "to".
	printf '%s\n' "$(one_line_display "$tbi_target")" >"$tbi_path_file"

	if [ "$OPT_PLAN" -eq 1 ]; then
		if [ "$OPT_JSON" -eq 1 ]; then
			render_transition_summary_json "$TICKET_KEY" "$PRE_TRANSITION_STATUS" "$tbi_target" "$tbi_path_file" "$TRANSITION_RESOLUTION_TO_SEND" false
		else
			render_transition_plan_human "$TICKET_KEY" "$PRE_TRANSITION_STATUS" "$tbi_target" "$tbi_path_file" "$TRANSITION_RESOLUTION_TO_SEND"
		fi
		return 0
	fi

	if [ -n "$OPT_RESOLUTION" ]; then
		execute_transition_with_resolution "$TICKET_KEY" "$TRANSITION_ID_USED" "$TRANSITION_RESOLUTION_TO_SEND"
	else
		execute_plain_transition "$TICKET_KEY" "$TRANSITION_ID_USED"
	fi
	verify_status_is "$TICKET_KEY" "$tbi_target"
	report_transition_read_back

	if [ "$OPT_JSON" -eq 1 ]; then
		render_transition_summary_json "$TICKET_KEY" "$PRE_TRANSITION_STATUS" "$tbi_target" "$tbi_path_file" "$TRANSITION_RESOLUTION_TO_SEND" true
	else
		# tbi_target is Jira's own to.name: folded for this machine line, while
		# the raw value is what verify_status_is compared and --json carries.
		printf 'JIRA_TRANSITIONED_TO=%s\n' "$(one_line_display "$tbi_target")"
		print_transition_read_back_lines
	fi
}

# report_transition_read_back — compares the issue's resolution and assignee
# BEFORE the walk (fetch_pre_transition_state) with AFTER its last step
# (verify_status_is's VERIFIED_BODY_FILE) and WARNS — never fails — on what a
# workflow post-function changed on its own. Seen live: closing without
# --resolution let a post-function set resolution=Done, and another site's
# post-function cleared the assignee. Neither is an error (the transition did
# apply), but neither was asked for, so the caller is told. Publishes
# TRANSITION_READBACK_JSON for --json and the READBACK_* values
# print_transition_read_back_lines renders in human mode.
report_transition_read_back() {
	TRANSITION_READBACK_JSON=$(jq -c -n --slurpfile before "$PRE_TRANSITION_STATE_FILE" \
		--slurpfile after "$VERIFIED_BODY_FILE" --arg requested "$OPT_RESOLUTION" \
		'def res: .fields.resolution.name // null;
		 def who: .fields.assignee.accountId // null;
		 def whoName: .fields.assignee.displayName // null;
		 ($before[0]) as $b | ($after[0]) as $a
		 | {status: ($a.fields.status.name // null),
		    resolution: {before: ($b | res), after: ($a | res),
		                 changedByWorkflow: (($requested | length) == 0 and ($b | res) != ($a | res))},
		    assignee: {before: ($b | who), after: ($a | who),
		               beforeName: ($b | whoName), afterName: ($a | whoName),
		               changed: (($b | who) != ($a | who))}}')
	READBACK_RESOLUTION_LINE=""
	READBACK_ASSIGNEE_LINE=""
	if [ "$(printf '%s' "$TRANSITION_READBACK_JSON" | jq -r '.resolution.changedByWorkflow')" = true ]; then
		READBACK_RESOLUTION_LINE=$(printf '%s' "$TRANSITION_READBACK_JSON" \
			| jq -r '"\(.resolution.before // "none") -> \(.resolution.after // "none")"')
		READBACK_RESOLUTION_LINE=$(one_line_display "$READBACK_RESOLUTION_LINE")
		warn "the workflow changed $TICKET_KEY's resolution ($READBACK_RESOLUTION_LINE) — --resolution was not given, so a workflow post-function did it"
	fi
	if [ "$(printf '%s' "$TRANSITION_READBACK_JSON" | jq -r '.assignee.changed')" = true ]; then
		READBACK_ASSIGNEE_LINE=$(printf '%s' "$TRANSITION_READBACK_JSON" \
			| jq -r '"\(.assignee.beforeName // .assignee.before // "unassigned") -> \(.assignee.afterName // .assignee.after // "unassigned")"')
		READBACK_ASSIGNEE_LINE=$(one_line_display "$READBACK_ASSIGNEE_LINE")
		warn "the workflow changed $TICKET_KEY's assignee ($READBACK_ASSIGNEE_LINE) — this engine did not ask for that; a post-function did it"
	fi
}

# print_transition_read_back_lines — human mode's machine-parseable half of
# report_transition_read_back, printed after JIRA_TRANSITIONED_TO and only for
# a side effect that actually happened. Both values were folded onto one line
# when they were built.
print_transition_read_back_lines() {
	[ -z "$READBACK_RESOLUTION_LINE" ] || printf 'JIRA_RESOLUTION_CHANGED=%s\n' "$READBACK_RESOLUTION_LINE"
	[ -z "$READBACK_ASSIGNEE_LINE" ] || printf 'JIRA_ASSIGNEE_CHANGED=%s\n' "$READBACK_ASSIGNEE_LINE"
	return 0
}

# validate_transition_args() — `transition`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_transition_args() {
	require_ticket_positional transition
	if [ -n "$OPT_TRANSITION_ID" ]; then
		[ -z "$OPT_STATUS" ] || { usage >&2; error "transition takes --status TARGET or --transition-id N, not both"; exit 2; }
		validate_numeric_id "$OPT_TRANSITION_ID" || { usage >&2; error "invalid --transition-id (must be a numeric transition id): $OPT_TRANSITION_ID"; exit 2; }
		return 0
	fi
	[ -n "$OPT_STATUS" ] || { usage >&2; error "transition requires --status TARGET (or --transition-id N)"; exit 2; }
	return 0
}
