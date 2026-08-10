# shellcheck shell=sh
#
# cmd-discover.sh — `discover <PROJECT>`: introspect a Jira project and EMIT the
#                   project-config JSON this same engine consumes. The ONE place
#                   a project config is WRITTEN (--write); projectconfig.sh only
#                   ever reads one.
#
# discover (read this before wiring anything that consumes its output):
#   `discover <PROJECT>` INTROSPECTS a Jira project and EMITS the project-config
#   JSON this same engine already consumes (custom_fields/type_aliases/
#   issue_types/subtask_types/subtask_parent_types/workflows — the exact keys
#   read by try_load_project_config & friends). It is a READ command: it only
#   ever GETs, never writes to Jira. It walks the CURRENT split createmeta
#   endpoints (the old `GET /issue/createmeta?projectKeys=...&expand=...` is
#   removed in Jira Cloud): GET /issue/createmeta/<PROJECT>/issuetypes (the
#   project's issue types — paginated), then GET
#   /issue/createmeta/<PROJECT>/issuetypes/<id> per type (that type's
#   create-screen fields — paginated), then GET /field (the global field
#   catalog, a plain array — used to resolve each custom field's id to its
#   display NAME). custom_fields IS POPULATED (a name->id map, keyed by each
#   custom field's display name — the same key resolve_field_name looks up
#   from a --fields token), as are issue_types and subtask_types, all from live
#   data. The human-fill step for custom_fields is DISTINCT from the empty
#   slots: it means ADDING the SEMANTIC keys require_custom_field expects
#   (acceptance_criteria/review_notes/developer) as further ENTRIES into that
#   already-populated map — whereas type_aliases/subtask_parent_types/workflows
#   are emitted genuinely EMPTY because the API cannot infer a client's aliases
#   or workflow graph at all. Every discovered value (field names, ids, type
#   names) enters jq ONLY as data via --slurpfile — never concatenated into a
#   jq program — so an injection-shaped field name authored by another Jira
#   user (e.g. one containing `$()`/backticks/quotes) round-trips completely
#   inert into the config. discover's own output IS the config JSON, so --json
#   is a no-op for it (unlike every other command). Default: prints the config
#   to stdout. --write: saves/MERGES it under the projects dir (see --write
#   above — it preserves human curation and backs up before overwriting).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# discover <PROJECT> — introspect a project's issue types + create-screen
# fields and EMIT the project-config JSON this engine already consumes. A READ
# command (only GETs); see the header's "discover" note for the endpoints and
# the config shape. Uses the CURRENT split createmeta endpoints (the old
# combined `createmeta?projectKeys=...&expand=...` is removed in Jira Cloud).
# ---------------------------------------------------------------------------

# DISCOVER_PAGE_SIZE — Jira's per-request bean size for the createmeta
# endpoints (startAt/maxResults paging). 50 is Jira's own default page size.
DISCOVER_PAGE_SIZE=50

# fetch_paginated_values OUT_FILE URL_BASE ARRAY_KEY ACTION — pages the
# createmeta split endpoints, whose CURRENT Jira Cloud shape is a plain
# OFFSET-paginated bean: `{ "<ARRAY_KEY>": [ ... ], "startAt": N,
# "maxResults": M, "total": T }`. ARRAY_KEY is the page's array field —
# "issueTypes" for the issuetypes call, "fields" for the per-type call — NOT
# ".values" (that key does not exist on these endpoints; reading it returned
# an EMPTY config against real Jira). There is NO "isLast" field here, so
# pagination is by OFFSET: start at 0, GET a page, append it, advance startAt
# by the number of rows returned, and STOP when a page comes back empty (the
# infinite-loop guard) OR startAt has reached `total`. Each row is appended to
# OUT_FILE as one compact JSON object per line; OUT_FILE is never truncated
# (the caller resets it with `: >file` before the first call), so several
# types' field pages accumulate into one aggregate file.
fetch_paginated_values() {
	fpv_out_file=$1
	fpv_url_base=$2
	fpv_array_key=$3
	fpv_action=$4
	fpv_start=0
	while :; do
		case "$fpv_url_base" in
			*\?*) fpv_sep='&' ;;
			*)    fpv_sep='?' ;;
		esac
		fpv_url="${fpv_url_base}${fpv_sep}startAt=${fpv_start}&maxResults=${DISCOVER_PAGE_SIZE}"
		jira_curl GET "$fpv_url"
		handle_http_status "$JIRA_HTTP_CODE" "$fpv_action"
		require_json_body "$fpv_action"
		jq -c --arg k "$fpv_array_key" '.[$k][]?' "$JIRA_HTTP_BODY_FILE" >>"$fpv_out_file"
		fpv_page_count=$(jq --arg k "$fpv_array_key" '(.[$k] // []) | length' "$JIRA_HTTP_BODY_FILE")
		fpv_total=$(jq '.total // 0' "$JIRA_HTTP_BODY_FILE")
		fpv_start=$((fpv_start + fpv_page_count))
		# Stop on an empty page (guards against a missing/short `total`) OR once
		# startAt has caught up to the reported total (all rows collected).
		if [ "$fpv_page_count" -eq 0 ] || [ "$fpv_start" -ge "$fpv_total" ]; then
			break
		fi
	done
}

# DISCOVER_CUSTOM_ENTRIES_PROGRAM — a single STATIC jq program (never built
# from data) that derives the deduped-by-id custom-field (id, name) entries
# ONCE, so both the config assembler AND the duplicate-name detector consume
# the SAME derivation (no drift). $fields is the array of createmeta value
# objects; $catalog is [<the /field array>], so $catalog[0] is that array.
# Every field name/id enters ONLY as one of these slurped values — never as
# program text — so an injection-shaped field name stays inert data. A field is
# "custom" when its schema.custom is set OR its fieldId starts with
# "customfield_"; its display NAME is taken from the /field catalog
# (authoritative), falling back to the createmeta name. Output: an array of
# {id, name}, one per distinct custom field id.
# shellcheck disable=SC2016  # single-quoted on purpose: $fields/$catalog below are jq syntax, not shell expansions
DISCOVER_CUSTOM_ENTRIES_PROGRAM='
($catalog[0] // [])
  | map(select(.id != null))
  | map({key: .id, value: (.name // .id)})
  | from_entries
  as $id_to_name
| $fields
  | map(select(((.schema.custom // null) != null)
               or (((.fieldId // "") | startswith("customfield_")))))
  | map({id: (.fieldId // ""), name: (($id_to_name[.fieldId]) // .name // .fieldId)})
  | map(select((.id | length) > 0))
  | unique_by(.id)
'

# DISCOVER_COLLISIONS_PROGRAM — the flat custom_fields name->id map can
# hold only ONE id per display name, so two distinct ids sharing a name would
# collapse (last-wins) silently. Given the {id,name} entries array, this emits
# a readable "<name> -> [id, id]" line per colliding name (empty when none), so
# discover can WARN which mapping was dropped rather than hide the collision.
# shellcheck disable=SC2016  # single-quoted on purpose: the jq body below is jq syntax, not shell expansions
DISCOVER_COLLISIONS_PROGRAM='
group_by(.name)
| map(select(length > 1))
| map("\"" + .[0].name + "\" -> [" + ([.[].id] | join(", ")) + "]")
| join("; ")
'

# DISCOVER_CONFIG_PROGRAM — assembles the consumed config shape from the
# pre-derived custom-field $entries (see above) and the $types array. $entries
# is [<the entries array>], so $entries[0] is that array.
# type_aliases/subtask_parent_types/workflows are emitted as EMPTY slots the
# human fills — the API cannot infer them (see the header note); custom_fields
# IS populated (keyed by display name).
# shellcheck disable=SC2016  # single-quoted on purpose: $entries/$types below are jq syntax, not shell expansions
DISCOVER_CONFIG_PROGRAM='
{
  custom_fields: ($entries[0] | map({key: .name, value: .id}) | from_entries),
  type_aliases: {},
  issue_types: ($types | map(.name // empty) | unique),
  subtask_types: ($types | map(select(.subtask == true) | .name // empty) | unique),
  subtask_parent_types: [],
  workflows: {}
}
'

# DISCOVER_MERGE_PROGRAM — fold a freshly-DISCOVERED config into a
# human-CURATED existing one without clobbering curation. $existing/$discovered
# are each [<the config object>]. Rules: REPLACE issue_types/subtask_types with
# the discovered facts; MERGE custom_fields (existing first, then discovered
# display-name entries add/refresh — preserving human-added semantic keys like
# acceptance_criteria/review_notes/developer); PRESERVE the existing
# type_aliases/subtask_parent_types/workflows (discovery emits these empty, so
# `//` keeps a present existing value — even an empty one — over the discovered
# empty). Starting from `$old + {...}` also preserves any EXTRA keys a human
# added (e.g. a "key" field) that discovery does not model.
# shellcheck disable=SC2016  # single-quoted on purpose: $existing/$discovered below are jq syntax, not shell expansions
DISCOVER_MERGE_PROGRAM='
$existing[0] as $old
| $discovered[0] as $new
| $old + {
    custom_fields: (($old.custom_fields // {}) + ($new.custom_fields // {})),
    type_aliases: ($old.type_aliases // $new.type_aliases),
    issue_types: $new.issue_types,
    subtask_types: $new.subtask_types,
    subtask_parent_types: ($old.subtask_parent_types // $new.subtask_parent_types),
    workflows: ($old.workflows // $new.workflows)
  }
'

# atomic_install SRC DEST — install SRC at DEST atomically: copy SRC to an
# mktemp sibling in DEST's OWN directory (same filesystem, so `mv` is an atomic
# rename) then rename it into place. An interrupted write can never leave a
# truncated/partial DEST — a reader sees either the old file or the whole new
# one, never a half-written config. DEST's directory must already exist (the
# caller mkdir -p's the projects dir first).
atomic_install() {
	ai_src=$1
	ai_dest=$2
	ai_tmp=$(mktemp "${ai_dest}.tmp.XXXXXX")
	cp "$ai_src" "$ai_tmp"
	mv "$ai_tmp" "$ai_dest"
}

# save_discovered_config CONFIG_FILE — persist the discovered
# CONFIG_FILE to $JIRA_PROJECTS_DIR/<discover_project>.json without CLOBBERING
# human curation. A fresh target is written as-is (created). An existing target
# is BACKED UP to a timestamped sibling FIRST, then: --force writes the pure
# discovered config (replaced); a valid existing file is MERGED (merged, via
# DISCOVER_MERGE_PROGRAM); an invalid/unreadable existing file is replaced with
# a fresh config plus a stderr WARNING. Every write into place goes through
# atomic_install (no truncated config on interrupt). Prints the machine line
# naming the outcome + any backup path. Uses
# $discover_project/$JIRA_PROJECTS_DIR/$OPT_FORCE globals (the script's
# plain-globals convention).
save_discovered_config() {
	sdc_config_file=$1
	[ -d "$JIRA_PROJECTS_DIR" ] || mkdir -p "$JIRA_PROJECTS_DIR"
	# discover_project is [A-Z0-9]+ (validated in cmd_discover), so
	# this join cannot contain a '/' or '..' — the path stays pinned under
	# $JIRA_PROJECTS_DIR, the SAME guarantee try_load_project_config relies on.
	sdc_out_path="$JIRA_PROJECTS_DIR/${discover_project}.json"

	if [ ! -f "$sdc_out_path" ]; then
		atomic_install "$sdc_config_file" "$sdc_out_path"
		printf 'JIRA_DISCOVERED=%s -> %s (created)\n' "$discover_project" "$sdc_out_path"
		return 0
	fi

	# Existing file: back it up before touching it, whichever branch follows.
	# the backup name is uniquified via mktemp (not a bare
	# .bak-<UTC>) so two --write runs in the SAME UTC second get DISTINCT
	# backups — mktemp both guarantees a fresh name (never overwriting an
	# existing backup) and creates it atomically. cp then fills it with the
	# pristine original.
	sdc_backup_path=$(mktemp "${sdc_out_path}.bak-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
	cp "$sdc_out_path" "$sdc_backup_path"

	if [ "$OPT_FORCE" -eq 1 ]; then
		atomic_install "$sdc_config_file" "$sdc_out_path"
		printf 'JIRA_DISCOVERED=%s -> %s (replaced; backup %s)\n' "$discover_project" "$sdc_out_path" "$sdc_backup_path"
		return 0
	fi

	if jq -e . "$sdc_backup_path" >/dev/null 2>&1; then
		# MERGE from the pristine backup (never read-then-write the same path):
		# both inputs enter jq only via --slurpfile, no value concatenated in.
		ensure_workdir
		sdc_merged_file="$WORKDIR/discover-merged.json"
		jq -n \
			--slurpfile existing "$sdc_backup_path" \
			--slurpfile discovered "$sdc_config_file" \
			"$DISCOVER_MERGE_PROGRAM" >"$sdc_merged_file"
		atomic_install "$sdc_merged_file" "$sdc_out_path"
		printf 'JIRA_DISCOVERED=%s -> %s (merged; backup %s)\n' "$discover_project" "$sdc_out_path" "$sdc_backup_path"
		return 0
	fi

	warn "existing $sdc_out_path is not valid JSON — backed it up and wrote a fresh discovered config (curated slots will be empty)"
	atomic_install "$sdc_config_file" "$sdc_out_path"
	printf 'JIRA_DISCOVERED=%s -> %s (replaced; backup %s)\n' "$discover_project" "$sdc_out_path" "$sdc_backup_path"
}

cmd_discover() {
	# The PROJECT positional presence/shape is validated up front — see the
	# main dispatch section's per-command validation (validate_project_key,
	# which rejects a traversal-shaped value like "../../x" with exit 2 before
	# any network or filesystem access).
	#
	# ensure_workdir runs FIRST, unconditionally — fetch_paginated_values and
	# the field-catalog GET below both reach jira_curl(), and the per-type
	# field loop calls fetch_paginated_values from a redirection-fed loop in
	# THIS shell (never a `cmd | while` subshell), so RESP_COUNTER and WORKDIR
	# stay coherent (the discipline the other commands establish).
	ensure_workdir

	discover_project=$TICKET_KEY
	# Defense-in-depth at the sink: the positional already passed
	# validate_project_key (^[A-Z][A-Z0-9]+$) at the dispatch stage, so it
	# holds only A-Z0-9 — no '/', '.', or newline that could retarget the
	# createmeta URL path or (on --write) escape the projects dir. Re-checked
	# here with an opaque whole-string case guard (the same "re-check at the
	# actual sink" posture try_load_project_config takes for its file-path
	# build), which — unlike grep's line-anchored ^/$ — also rejects an
	# embedded newline.
	case "$discover_project" in
		''|*[!A-Z0-9]*) error "invalid project key: $discover_project"; exit 1 ;;
	esac

	# 1. The project's issue types (the page array is under `issueTypes`,
	#    OFFSET-paginated).
	discover_types_jsonl="$WORKDIR/discover-types.jsonl"
	: >"$discover_types_jsonl"
	discover_issuetypes_url="https://${CONFIRMED_HOST}/rest/api/3/issue/createmeta/${discover_project}/issuetypes"
	fetch_paginated_values "$discover_types_jsonl" "$discover_issuetypes_url" issueTypes \
		"discover issue types for $discover_project"

	# 2. Each issue type's create-screen fields (the page array is under
	#    `fields`, OFFSET-paginated — `total` can exceed one page), accumulated
	#    into ONE aggregate JSONL. The loop reads type ids via redirection (not
	#    a pipe) so it runs in THIS shell — matching walk_transition_path's idiom.
	discover_fields_jsonl="$WORKDIR/discover-fields.jsonl"
	: >"$discover_fields_jsonl"
	discover_type_ids_file="$WORKDIR/discover-type-ids.txt"
	jq -r '.id // empty' "$discover_types_jsonl" >"$discover_type_ids_file"
	while IFS= read -r discover_type_id; do
		[ -n "$discover_type_id" ] || continue
		# A createmeta issue-type id is Jira-issued and numeric; it becomes a
		# URL path segment, so reject any non-digit shape up front
		# (defense-in-depth) rather than trusting the value blindly.
		# The id reaches this diagnostic precisely BECAUSE it failed the shape
		# check, so it is arbitrary API-derived bytes — strip control/ANSI
		# sequences before it touches a terminal, the same treatment every other
		# rendered API value gets.
		case "$discover_type_id" in
			*[!0-9]*)
				discover_type_id_safe=$(printf '%s' "$discover_type_id" | strip_control_ansi)
				warn "skipping issue type with an unexpected id shape: $discover_type_id_safe"
				continue
				;;
		esac
		discover_type_fields_url="https://${CONFIRMED_HOST}/rest/api/3/issue/createmeta/${discover_project}/issuetypes/${discover_type_id}"
		fetch_paginated_values "$discover_fields_jsonl" "$discover_type_fields_url" fields \
			"discover fields for issue type $discover_type_id in $discover_project"
	done <"$discover_type_ids_file"

	# 3. The global field catalog — a plain JSON ARRAY, NOT a paginated bean,
	#    so it is fetched with a single GET (no fetch_paginated_values).
	discover_catalog_file="$WORKDIR/discover-field-catalog.json"
	discover_field_catalog_url="https://${CONFIRMED_HOST}/rest/api/3/field"
	jira_curl GET "$discover_field_catalog_url"
	handle_http_status "$JIRA_HTTP_CODE" "discover the global field catalog"
	require_json_body "discover the global field catalog"
	cp "$JIRA_HTTP_BODY_FILE" "$discover_catalog_file"

	# 4a. Derive the deduped-by-id custom-field (id, name) entries ONCE, so the
	#     config assembler and the collision detector share one derivation.
	discover_custom_entries_file="$WORKDIR/discover-custom-entries.json"
	jq -n \
		--slurpfile fields "$discover_fields_jsonl" \
		--slurpfile catalog "$discover_catalog_file" \
		"$DISCOVER_CUSTOM_ENTRIES_PROGRAM" >"$discover_custom_entries_file"

	# 4b. Warn (to stderr) on any display NAME shared by two distinct
	#     field ids — the flat name->id map keeps only one, so surface which was
	#     dropped. The collision string is API-authored text, so it passes
	#     through strip_control_ansi before it reaches the diagnostic.
	discover_name_collisions=$(jq -r "$DISCOVER_COLLISIONS_PROGRAM" "$discover_custom_entries_file" | strip_control_ansi)
	[ -z "$discover_name_collisions" ] || \
		warn "duplicate custom-field display name(s) — only one id kept per name in custom_fields: $discover_name_collisions"

	# 4c. Assemble the config from the pre-derived entries + the issue types.
	discover_config_file="$WORKDIR/discover-config.json"
	jq -n \
		--slurpfile types "$discover_types_jsonl" \
		--slurpfile entries "$discover_custom_entries_file" \
		"$DISCOVER_CONFIG_PROGRAM" >"$discover_config_file"

	if [ "$OPT_WRITE" -eq 1 ]; then
		save_discovered_config "$discover_config_file"
	else
		cat "$discover_config_file"
	fi
}

# validate_discover_args() — `discover`'s per-command argument validation, called by
# jira.sh BEFORE any tool/site/credential check so a caller's own typo
# surfaces as a usage error (exit 2) first.
validate_discover_args() {
	# discover's positional is a bare PROJECT key (not a ticket key) — it
	# becomes a URL path segment AND (on --write) a config file path, so it
	# is shape-validated here with validate_project_key, the SAME guard
	# try_load_project_config uses for --project. A traversal-shaped value
	# (e.g. "../../x") is rejected with exit 2 here, BEFORE any read/write.
	[ -n "$TICKET_KEY" ] || { usage >&2; error "discover requires a PROJECT key, e.g.: discover PROJ"; exit 2; }
	validate_project_key "$TICKET_KEY" || { usage >&2; error "invalid project key: $TICKET_KEY"; exit 2; }
	return 0
}
