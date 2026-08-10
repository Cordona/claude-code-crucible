# shellcheck shell=sh
#
# inline-images.sh — own-line local `![alt](PATH)` images in a description or
#                    comment body: scan the markdown for them, upload each ONCE
#                    to the issue, resolve its media UUID, and return a
#                    {localPath: mediaUUID} map file for md-to-adf.sh to turn
#                    into mediaSingle blocks.
#
# This unit does the NETWORK half; md-to-adf.sh does the transform. Its fence
# FSM mirrors md-to-adf.sh's block parser exactly, so the two always agree on
# which lines are real images (an `![](local)` shown as example code inside a
# ``` fence is never uploaded).
#
# Sourced by jira.sh — never executed directly. Sets no shell options and
# runs no top-level work beyond its own declarations, so sourcing it always
# returns 0 under `set -e`.

# ---------------------------------------------------------------------------
# Inline images (Cycle B): local `![alt](PATH)` own-line images embedded in a
# description/comment body. The mechanism (probed live) is: upload the local
# file as an attachment (Cycle A), resolve its media UUID from the 303 the
# attachment/content endpoint returns, then reference that UUID from a
# mediaSingle ADF block (md-to-adf.sh emits the block from a media map this
# layer builds). This layer does the network; md-to-adf.sh does the transform.
# ---------------------------------------------------------------------------

# trim_ws VALUE -> VALUE with leading/trailing ASCII whitespace removed. Used
# by scan_inline_image_paths to classify a line the SAME way md-to-adf.sh's
# block parser does (it trims before matching), so the two agree on exactly
# which lines are own-line images.
trim_ws() {
	printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# scan_inline_image_paths MARKDOWN_FILE -> prints one own-line LOCAL image PATH
# per line (in document order; duplicates allowed — the caller dedups against
# the map). Matches md-to-adf.sh's block parser: a line that trims to SOLELY
# `![alt](PATH)` with a non-http(s) PATH. Lines inside a ``` fence are skipped
# (fence content is literal in md-to-adf.sh, so it is not a media line here).
scan_inline_image_paths() {
	sip_markdown_file=$1
	sip_fence=0
	while IFS= read -r sip_line || [ -n "$sip_line" ]; do
		sip_trimmed=$(trim_ws "$sip_line")
		# Fence FSM — mirror md-to-adf.sh's block parser EXACTLY (asymmetric,
		# never a blind toggle): while a fence is OPEN every line is literal
		# fence body and is skipped, and ONLY a line that trims to exactly
		# ``` closes it (a body line like ```foo is content, not a close);
		# while CLOSED, a line starting with ``` opens one. A blind toggle
		# would desync from md-to-adf and could treat an `![](local)` shown
		# as example code inside a fence as a real image to upload.
		if [ "$sip_fence" = "1" ]; then
			if [ "$sip_trimmed" = '```' ]; then sip_fence=0; fi
			continue
		fi
		case "$sip_trimmed" in
			'```'*) sip_fence=1; continue ;;
		esac
		case "$sip_trimmed" in
			'!['*']('*')')
				# Same glob + extraction md-to-adf.sh's image branch uses
				# (#'![', #*'](', %')'), then accept ONLY a line that is
				# EXACTLY one image and nothing else — md-to-adf turns solely
				# such a line into a mediaSingle. `%')'` strips just the FINAL
				# paren, so a SECOND image leaves an interior `](` and any
				# trailing text after the image's real close leaves an interior
				# `)`; either telltale means NOT-solely, so skip it (it degrades
				# to paragraph text downstream, exactly as md-to-adf renders it)
				# instead of extracting a garbled non-path that would then abort
				# the whole command at require_readable_file.
				sip_rest=${sip_trimmed#'!['}
				sip_after_alt=${sip_rest#*']('}
				sip_path=${sip_after_alt%')'}
				case "$sip_path" in
					*']('*|*')'*) continue ;;
				esac
				case "$sip_path" in
					http://*|https://*|'') : ;;
					*) printf '%s\n' "$sip_path" ;;
				esac
				;;
		esac
	done <"$sip_markdown_file"
}

# merge_media_map MAP_FILE PATH UUID — folds {PATH: UUID} into MAP_FILE in
# place. PATH + UUID reach jq only as --arg VALUES in a static program (never
# concatenated into jq source) — the same discipline as merge_*_field.
merge_media_map() {
	mmm_map_file=$1
	mmm_path=$2
	mmm_uuid=$3
	MEDIA_COUNTER=$((MEDIA_COUNTER + 1))
	mmm_tmp_file="$WORKDIR/media-map-$MEDIA_COUNTER.json"
	jq -c --arg p "$mmm_path" --arg u "$mmm_uuid" \
		'. + {($p): $u}' "$mmm_map_file" >"$mmm_tmp_file"
	cp "$mmm_tmp_file" "$mmm_map_file"
}

# media_map_has_entries MAP_FILE -> 0 iff the map has at least one entry.
media_map_has_entries() {
	mmh_map_file=$1
	[ -n "$mmh_map_file" ] && [ -f "$mmh_map_file" ] || return 1
	mmh_count=$(jq -r 'length' "$mmh_map_file" 2>/dev/null || printf '0')
	[ "$mmh_count" -gt 0 ]
}

# lookup_path_in_map MAP_FILE PATH -> prints the mapped UUID or nothing. PATH
# via --arg into a static program (never concatenated into jq source). Defined
# above its sole caller resolve_inline_images (define-before-use), matching the
# ordering of the other Cycle B helpers.
lookup_path_in_map() {
	lpm_map_file=$1
	lpm_path=$2
	jq -rn --slurpfile m "$lpm_map_file" --arg p "$lpm_path" '($m[0][$p]) // ""'
}

# resolve_inline_images KEY MARKDOWN_FILE -> prints the path to a media-map
# file {localPath: mediaUUID} for every UNIQUE own-line local image in
# MARKDOWN_FILE. For each: require_readable_file -> upload to KEY (Cycle A
# multipart) -> attachment id -> resolve_media_uuid -> UUID -> merge into map.
# An empty `{}` map is returned when there are no inline images (behavior is
# then exactly as before this feature: convert with an empty map == no media).
# KEY is a shape-validated ticket key (safe URL path segment) at every call site.
resolve_inline_images() {
	rii_key=$1
	rii_markdown_file=$2
	ensure_workdir
	MEDIA_COUNTER=$((MEDIA_COUNTER + 1))
	rii_paths_file="$WORKDIR/inline-images-$MEDIA_COUNTER.paths"
	rii_map_file="$WORKDIR/inline-images-$MEDIA_COUNTER.map.json"

	scan_inline_image_paths "$rii_markdown_file" >"$rii_paths_file"
	printf '{}' >"$rii_map_file"

	# No inline images -> empty map, no uploads (identical to pre-feature).
	if [ ! -s "$rii_paths_file" ]; then
		printf '%s' "$rii_map_file"
		return 0
	fi

	rii_upload_url="https://${CONFIRMED_HOST}/rest/api/3/issue/${rii_key}/attachments"
	# Read from a FILE (not a pipe) so this loop runs in THIS shell and the
	# map accumulation survives (subshell-scope-loss trap).
	while IFS= read -r rii_path; do
		[ -n "$rii_path" ] || continue
		# Dedup: a path already in the map was uploaded on an earlier line.
		rii_existing=$(lookup_path_in_map "$rii_map_file" "$rii_path")
		[ -z "$rii_existing" ] || continue

		require_readable_file "$rii_path" "inline image"
		jira_curl_multipart POST "$rii_upload_url" "$(printf '%s\n' "$rii_path")"
		handle_http_status "$JIRA_HTTP_CODE" "upload inline image '$rii_path' to $rii_key"
		require_json_body "upload inline image '$rii_path' to $rii_key"
		if ! jq -e 'type == "array" and length >= 1' "$JIRA_HTTP_BODY_FILE" >/dev/null 2>&1; then
			error "upload inline image '$rii_path' to $rii_key: response was not a non-empty JSON array"
			exit 1
		fi
		rii_attach_id=$(jq -r '.[0].id // ""' "$JIRA_HTTP_BODY_FILE")
		validate_numeric_id "$rii_attach_id" || {
			error "upload inline image '$rii_path' to $rii_key: attachment id was not numeric"
			exit 1
		}
		rii_uuid=$(resolve_media_uuid "$rii_attach_id")
		merge_media_map "$rii_map_file" "$rii_path" "$rii_uuid"
	done <"$rii_paths_file"

	printf '%s' "$rii_map_file"
}
