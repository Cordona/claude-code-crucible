# shellcheck shell=sh
#
# projectconfig.sh — READING and RESOLVING a project config (the per-project
#                    JSON under $JIRA_PROJECTS_DIR): locating it, validating it
#                    is JSON, and resolving type aliases / custom field names
#                    through it.
#
# It deliberately does NOT WRITE a config — producing one is discover's job
# (cmd-discover.sh's save_discovered_config), so the read path a dozen commands
# depend on cannot be perturbed by the one command that authors configs.
#
# COUPLING (accepted for this pass): the loader sets the $PROJECT_CONFIG_FILE
# global its callers then read, per the engine's plain-globals convention.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# Project config loader (mirrors the jira.py oracle's ProjectConfig). The
# SCHEMA is generic; config INSTANCES (one JSON file per project key) live
# under $JIRA_PROJECTS_DIR, which defaults to a conventional path but is
# fully overridable (env or --projects-dir) since real instances belong to
# the private client layer, never this generic skill.
# ---------------------------------------------------------------------------

# try_load_project_config KEY — sets $PROJECT_CONFIG_FILE if
# $JIRA_PROJECTS_DIR/KEY.json exists and is valid JSON. Absence is NOT an
# error (most projects have no config; callers fall back to literal values).
# Malformed JSON in an EXISTING file IS an error — a broken config should
# never be silently ignored. KEY is shape-validated FIRST — this
# is the one place a project key becomes a file path, so the guard lives
# here rather than duplicated at every caller (--project on create/search,
# and the ticket-key-derived project on view/workflow/transition/update,
# which is already shape-guaranteed by validate_ticket_key upstream but
# costs nothing to re-check at the actual sink).
try_load_project_config() {
	tlpc_key=$1
	[ -n "$tlpc_key" ] || return 0
	if ! validate_project_key "$tlpc_key"; then
		error "invalid project key: $tlpc_key"
		exit 1
	fi
	tlpc_candidate="$JIRA_PROJECTS_DIR/${tlpc_key}.json"
	[ -f "$tlpc_candidate" ] && [ -r "$tlpc_candidate" ] || return 0
	if ! jq -e . "$tlpc_candidate" >/dev/null 2>&1; then
		error "project config is not valid JSON: $tlpc_candidate"
		exit 1
	fi
	# shellcheck disable=SC2034  # the loader's whole output: read by create/update/transition/search in their own units
	PROJECT_CONFIG_FILE=$tlpc_candidate
}

# resolve_type_alias CONFIG_FILE VALUE -> config's type_aliases[VALUE], or
# VALUE unchanged if there is no such alias / no config was loaded.
resolve_type_alias() {
	rta_config_file=$1
	rta_value=$2
	[ -n "$rta_config_file" ] || { printf '%s' "$rta_value"; return 0; }
	jq -r --arg v "$rta_value" '.type_aliases[$v] // $v' "$rta_config_file"
}

# resolve_field_name CONFIG_FILE NAME -> config's custom_fields[NAME] (a
# semantic name like "acceptance_criteria" -> "customfield_16102"), or NAME
# unchanged when there's no such mapping / no config.
resolve_field_name() {
	rfn_config_file=$1
	rfn_name=$2
	[ -n "$rfn_config_file" ] || { printf '%s' "$rfn_name"; return 0; }
	jq -r --arg n "$rfn_name" '.custom_fields[$n] // $n' "$rfn_config_file"
}

# resolve_fields_csv CONFIG_FILE CSV -> CSV with each token passed through
# resolve_field_name (empty CONFIG_FILE = passthrough unchanged).
resolve_fields_csv() {
	rfc_config_file=$1
	rfc_csv=$2
	[ -n "$rfc_config_file" ] || { printf '%s' "$rfc_csv"; return 0; }
	rfc_old_ifs=$IFS
	IFS=','
	set -f
	# shellcheck disable=SC2086  # deliberate comma-split; -f (above) blocks globbing
	set -- $rfc_csv
	set +f
	IFS=$rfc_old_ifs
	rfc_out=""
	for rfc_tok in "$@"; do
		rfc_trimmed=$(printf '%s' "$rfc_tok" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		[ -n "$rfc_trimmed" ] || continue
		rfc_resolved=$(resolve_field_name "$rfc_config_file" "$rfc_trimmed")
		if [ -z "$rfc_out" ]; then rfc_out=$rfc_resolved; else rfc_out="$rfc_out,$rfc_resolved"; fi
	done
	printf '%s' "$rfc_out"
}

# load_config_for_ticket_key KEY — the "derive the project from a ticket key,
# then load that project's config" prelude view/transition/update all open with.
# The reset is load-bearing, not tidiness: $PROJECT_CONFIG_FILE is a global that
# survives a bulk batch's per-issue subshells, so a stale value from an earlier
# key would otherwise leak into the next one.
load_config_for_ticket_key() {
	# shellcheck disable=SC2034  # reset here, then set + read by try_load_project_config on the next line and by the calling command in its own unit
	PROJECT_CONFIG_FILE=""
	try_load_project_config "$(extract_project_from_key "$1")"
}
