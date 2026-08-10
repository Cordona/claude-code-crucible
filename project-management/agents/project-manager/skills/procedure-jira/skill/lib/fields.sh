# shellcheck shell=sh
#
# fields.sh — the typed field-merge accumulator: every REST `fields{}` envelope
#             this engine sends is built by folding one key at a time into a
#             $WORKDIR JSON file ("the accumulator IS the file").
#
# SECURITY INVARIANT — do not weaken it: every merge_*_field runs a STATIC,
# HARDCODED jq program fed via --arg/--argjson/--slurpfile. A jq PROGRAM is
# never accepted as a parameter and never string-concatenated from data. That is
# why the six merge_*_field functions are NOT collapsed into one parameterized
# helper: collapsing them requires passing the program as a variable, which is
# exactly the thing this invariant forbids.
#
# Every dynamic object KEY (a config-resolved custom field id like
# "customfield_16102") is still only ever a jq VALUE, via --arg + jq's
# `{($k): $v}` computed-key syntax — never program text.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# init_fields_accumulator OUT_FILE — creates an empty `{}` accumulator that
# merge_*_field() below fold new keys into, one call at a time.
init_fields_accumulator() {
	ifa_out_file=$1
	printf '{}' >"$ifa_out_file"
}

# merge_string_field ACC_FILE JSON_KEY VALUE — merges {JSON_KEY: VALUE} (a
# plain string field: summary, duedate, ...) into ACC_FILE in place.
merge_string_field() {
	target_acc_file=$1
	json_key=$2
	string_value=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --arg v "$string_value" \
		'. + {($k): $v}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_ref_field ACC_FILE JSON_FIELD INNER_KEY INNER_VALUE — merges
# {JSON_FIELD: {INNER_KEY: INNER_VALUE}} into ACC_FILE in place. This is the
# ONE shape Jira uses for every "reference by X" field: project/parent by
# "key", issuetype by "name", assignee by "id", a custom user-picker field
# (e.g. "developer") by "accountId" — one helper, four real call sites,
# genuinely the same structural pattern (not a premature abstraction).
merge_ref_field() {
	target_acc_file=$1
	json_field=$2
	inner_key=$3
	inner_value=$4
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg f "$json_field" --arg ik "$inner_key" --arg iv "$inner_value" \
		'. + {($f): {($ik): $iv}}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_json_field ACC_FILE JSON_KEY VALUE_FILE — merges {JSON_KEY: <value
# parsed from VALUE_FILE>} into ACC_FILE in place, via --slurpfile (per the
# brief: read the ADF file with --slurpfile/--argjson, never string-concat).
# JSON_KEY may be a config-resolved custom field id ("customfield_16102") —
# it is still only ever a jq *value* (via --arg), never program text.
merge_json_field() {
	target_acc_file=$1
	json_key=$2
	value_file=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --slurpfile v "$value_file" \
		'. + {($k): $v[0]}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_labels_field ACC_FILE CSV — merges {labels: [...]} into ACC_FILE in
# place, splitting/trimming CSV the same way build_search_request_body()
# already does for --fields (consistent idiom, not a new one).
merge_labels_field() {
	target_acc_file=$1
	labels_csv=$2
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg csv "$labels_csv" \
		'. + {labels: ($csv | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$";"")) | map(select(length > 0)))}' \
		"$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_bool_field ACC_FILE JSON_KEY BOOL — merges {JSON_KEY: <true|false>}
# into ACC_FILE in place. BOOL is a bare `true`/`false` literal read via
# --argjson (so it lands as a JSON boolean, not the string "true"). Used by the
# FLAT /version bodies (released/archived), the one place this engine writes a
# boolean field — the same static-program/--argjson discipline as merge_*_field
# above, just for a scalar boolean instead of a string/object.
merge_bool_field() {
	target_acc_file=$1
	json_key=$2
	bool_value=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --argjson v "$bool_value" \
		'. + {($k): $v}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# merge_int_field ACC_FILE JSON_KEY INT — merges {JSON_KEY: <INT as a JSON
# number>} into ACC_FILE in place. INT is fed via --argjson so it lands as a
# JSON integer, not the string "826" — the Agile sprint API expects
# originBoardId as a NUMBER (ground-truth-verified). The CALLER must guarantee
# INT is a bare run of digits (validate_numeric_id upstream) so --argjson never
# sees a non-numeric literal; same static-program/--argjson discipline as
# merge_bool_field, just for an integer scalar.
merge_int_field() {
	target_acc_file=$1
	json_key=$2
	int_value=$3
	MERGE_COUNTER=$((MERGE_COUNTER + 1))
	merge_tmp_file="$WORKDIR/merge-$MERGE_COUNTER.json"
	jq -c --arg k "$json_key" --argjson v "$int_value" \
		'. + {($k): $v}' "$target_acc_file" >"$merge_tmp_file"
	cp "$merge_tmp_file" "$target_acc_file"
}

# require_custom_field CONFIG_FILE SEMANTIC_NAME FLAG_NAME -> prints the
# config's custom_fields[SEMANTIC_NAME] field id, or fails closed (exit 1)
# if there is no config or no such mapping. DELIBERATE DIVERGENCE from the
# jira.py oracle: the oracle SILENTLY DROPS an --acceptance/--review update
# when the field isn't configured (no field id -> the whole block is
# skipped, no error, no write, no warning) — a user-requested update that
# silently does nothing is a defect (build-core: don't copy an anti-pattern
# to "stay consistent"), so this fails loud instead, naming exactly what's
# missing.
require_custom_field() {
	rcf_config_file=$1
	rcf_semantic_field_name=$2
	rcf_flag_name=$3
	if [ -z "$rcf_config_file" ]; then
		error "$rcf_flag_name requires a project config with custom_fields.$rcf_semantic_field_name mapped, but no project config was found"
		exit 1
	fi
	rcf_resolved_field_id=$(jq -r --arg n "$rcf_semantic_field_name" '.custom_fields[$n] // empty' "$rcf_config_file")
	if [ -z "$rcf_resolved_field_id" ]; then
		error "$rcf_flag_name requires custom_fields.$rcf_semantic_field_name to be mapped in the project config, but it is not"
		exit 1
	fi
	printf '%s' "$rcf_resolved_field_id"
}
