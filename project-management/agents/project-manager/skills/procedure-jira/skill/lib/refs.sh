# shellcheck shell=sh
#
# refs.sh — resolving a caller-given NAME to the id Jira wants: an issue's own
#           type, and the project's versions/components (--fix-version /
#           --affects-version / --component).
#
# The versions list is fetched ONCE per invocation and shared by fixVersions +
# versions; components once — so a create/update carrying all three flags makes
# at most TWO extra GETs, never one per flag or one per name. An unmatched name
# fails loud; an ambiguous one (duplicate display names DO occur in Jira) fails
# loud too, never a silent last-wins pick.
#
# COUPLING (accepted for this pass): merge_attach_flags() reads the
# OPT_FIX_VERSIONS/OPT_AFFECTS_VERSIONS/OPT_COMPONENTS globals directly.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# resolve_issue_type_of TICKET_KEY -> the issue's current issuetype name, via
# GET. Used only for subtask-parent-type validation on create.
resolve_issue_type_of() {
	lookup_ticket_key=$1
	lookup_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${lookup_ticket_key}?fields=issuetype"
	jira_curl GET "$lookup_url"
	handle_http_status "$JIRA_HTTP_CODE" "look up issue type for $lookup_ticket_key"
	require_json_body "look up issue type for $lookup_ticket_key"
	jq -r '.fields.issuetype.name // ""' "$JIRA_HTTP_BODY_FILE"
}

# fetch_project_collection PROJECT COLLECTION -> prints the path to a WORKDIR
# file holding the collection's PLAIN JSON ARRAY. COLLECTION is "versions" or
# "components". Fetched ONCE per data axis (see merge_named_refs /
# merge_attach_flags below): --fix-version and --affects-version are two FIELDS but
# ONE axis (versions), so the versions list is fetched a single time and shared
# — never once per field, never once per name. Both endpoints return a PLAIN
# array (NOT a paginated {values:[...]} envelope) — verified against live Jira.
# PROJECT is already shape-validated by the caller before it reaches this URL.
fetch_project_collection() {
	fpc_project=$1
	fpc_collection=$2
	fpc_url="https://${CONFIRMED_HOST}/rest/api/3/project/${fpc_project}/${fpc_collection}"
	jira_curl GET "$fpc_url"
	handle_http_status "$JIRA_HTTP_CODE" "list $fpc_collection for $fpc_project"
	require_json_body "list $fpc_collection for $fpc_project"
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	fpc_array_file="$WORKDIR/attach-$fpc_collection-$MERGE_COUNTER.array.json"
	cp "$JIRA_HTTP_BODY_FILE" "$fpc_array_file"
	printf '%s' "$fpc_array_file"
}

# merge_named_refs ACC_FILE NAMES_NL ARRAY_FILE JSON_KEY LABEL PROJECT —
# resolves each caller-given NAME to its id against the already-fetched
# ARRAY_FILE and merges {JSON_KEY: [{"id":"..."}, ...]} into ACC_FILE. Used for
# create/update's --fix-version (fixVersions) / --affects-version (versions) /
# --component (components) flags.
#
#   NAMES_NL   newline-delimited names (repeatable flag accumulation); EMPTY is
#              a no-op (the flag was never given).
#   ARRAY_FILE the collection array from fetch_project_collection (resolved
#              LOCALLY, so NO extra network call per name).
#   JSON_KEY   "fixVersions" | "versions" | "components" — the fields{} key.
#   LABEL      human noun for diagnostics, e.g. "fix version" / "component".
#
# EXACT name match. Zero matches -> fail loud (exit 1). >1 match (duplicate
# display names DO occur in Jira) -> fail loud as ambiguous, never a silent
# last-wins pick.
#
# Each NAME enters jq ONLY as an --arg VALUE in a static program, and
# each resolved id is emitted as a jq-built {id: .} object — no name or id is
# ever concatenated into a jq program or a URL. The name-reading loop reads from
# a FILE redirect (never a `... | while` pipe), so it runs in THIS shell — its
# `exit 1` on a bad name actually terminates the script (a pipe subshell's
# would not) and no resolved id is lost to subshell scope.
merge_named_refs() {
	mnr_acc_file=$1
	mnr_names=$2
	mnr_array_file=$3
	mnr_json_key=$4
	mnr_label=$5
	mnr_project=$6

	[ -n "$mnr_names" ] || return 0

	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	mnr_names_file="$WORKDIR/attach-$mnr_json_key-$MERGE_COUNTER.names.txt"
	printf '%s' "$mnr_names" >"$mnr_names_file"
	mnr_ids_file="$WORKDIR/attach-$mnr_json_key-$MERGE_COUNTER.ids.txt"
	: >"$mnr_ids_file"

	while IFS= read -r mnr_name; do
		[ -n "$mnr_name" ] || continue
		mnr_match_count=$(jq --arg n "$mnr_name" \
			'[.[] | select(.name == $n)] | length' "$mnr_array_file")
		if [ "$mnr_match_count" -eq 0 ]; then
			error "$mnr_label '$mnr_name' not found in project $mnr_project"
			exit 1
		fi
		if [ "$mnr_match_count" -gt 1 ]; then
			error "$mnr_label '$mnr_name' is ambiguous in project $mnr_project ($mnr_match_count with that exact name) — resolve by picking a unique name"
			exit 1
		fi
		jq -r --arg n "$mnr_name" \
			'first(.[] | select(.name == $n) | .id)' "$mnr_array_file" >>"$mnr_ids_file"
	done <"$mnr_names_file"

	mnr_ref_file="$WORKDIR/attach-$mnr_json_key-$MERGE_COUNTER.ref.json"
	jq -R -n '[inputs | {id: .}]' <"$mnr_ids_file" >"$mnr_ref_file"
	merge_json_field "$mnr_acc_file" "$mnr_json_key" "$mnr_ref_file"
}

# merge_attach_flags ACC_FILE PROJECT — the shared create/update attach step:
# resolves --fix-version/--affects-version/--component names to id-refs and
# merges them into ACC_FILE's fields{} accumulator. The versions list is
# fetched ONCE and shared by fixVersions + versions; components once — so a
# create/update carrying all three flags makes at most TWO extra GETs, never
# one-per-flag or one-per-name. PROJECT is already shape-validated by the
# caller (create: OPT_PROJECT via try_load_project_config; update: the ticket
# key's extracted prefix) before it reaches fetch_project_collection's URL.
merge_attach_flags() {
	maf_acc_file=$1
	maf_project=$2

	if [ -n "$OPT_FIX_VERSIONS" ] || [ -n "$OPT_AFFECTS_VERSIONS" ]; then
		maf_versions_file=$(fetch_project_collection "$maf_project" versions)
		merge_named_refs "$maf_acc_file" "$OPT_FIX_VERSIONS"     "$maf_versions_file" fixVersions "fix version"     "$maf_project"
		merge_named_refs "$maf_acc_file" "$OPT_AFFECTS_VERSIONS" "$maf_versions_file" versions    "affects version" "$maf_project"
	fi
	if [ -n "$OPT_COMPONENTS" ]; then
		maf_components_file=$(fetch_project_collection "$maf_project" components)
		merge_named_refs "$maf_acc_file" "$OPT_COMPONENTS" "$maf_components_file" components "component" "$maf_project"
	fi
}
