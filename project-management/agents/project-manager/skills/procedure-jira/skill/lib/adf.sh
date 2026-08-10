# shellcheck shell=sh
#
# adf.sh — the handoff to the sibling md-to-adf.sh converter.
#
# Markdown content NEVER touches a shell variable or a jq program string on this
# path: it flows MARKDOWN_FILE -> md-to-adf.sh --file -> an ADF JSON FILE under
# $WORKDIR, which fields.sh then merges via --slurpfile. That is what keeps a
# description/summary containing $()/backticks/quotes completely inert.
#
# COUPLING (accepted for this pass): require_converter() reads the $MD_TO_ADF
# path jira.sh derives from $0.
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# require_converter — fails closed (exit 1) if md-to-adf.sh isn't sitting
# next to this script where it's expected (see SCRIPT_DIR/MD_TO_ADF above).
require_converter() {
	if [ ! -f "$MD_TO_ADF" ] || [ ! -r "$MD_TO_ADF" ]; then
		error "internal: md-to-adf.sh not found next to jira.sh: $MD_TO_ADF"
		exit 1
	fi
}

# convert_markdown_file_to_adf MARKDOWN_FILE -> prints the path to a NEW ADF
# JSON file under WORKDIR. The markdown content NEVER touches a shell
# variable or a jq program string here — it flows MARKDOWN_FILE -> (consumed
# by md-to-adf.sh via its own --file flag) -> ADF JSON written straight to a
# file, satisfying "stays inert" even for a description/summary containing
# `$()`/backticks/quotes: none of those bytes are ever interpreted, only
# ever read as file content or passed as --data @file to curl.
# An optional SECOND argument is a media-map file (localPath -> mediaUUID,
# built by resolve_inline_images below): when non-empty it is passed to the
# converter as --media-map, so own-line local `![alt](PATH)` images become ADF
# mediaSingle blocks. Existing single-argument callers are unaffected (no map).
convert_markdown_file_to_adf() {
	source_markdown_file=$1
	source_media_map=${2:-}
	require_converter
	ensure_workdir
	ADF_COUNTER=$((ADF_COUNTER + 1))
	adf_out_file="$WORKDIR/adf-$ADF_COUNTER.json"
	adf_err_file="$WORKDIR/adf-$ADF_COUNTER.err"
	if [ -n "$source_media_map" ]; then
		set -- --file "$source_markdown_file" --media-map "$source_media_map"
	else
		set -- --file "$source_markdown_file"
	fi
	if ! sh "$MD_TO_ADF" "$@" >"$adf_out_file" 2>"$adf_err_file"; then
		error "markdown-to-ADF conversion failed for: $source_markdown_file"
		sed 's/^/  /' "$adf_err_file" >&2 2>/dev/null || true
		exit 1
	fi
	printf '%s' "$adf_out_file"
}
