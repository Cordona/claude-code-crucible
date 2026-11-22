# Builds the would-be version's body, shared by context-fingerprint.sh and
# context-cut.sh, so what a plan pins and what a cut writes are the same.
# Needs context.sh and path-rule.sh sourced first, and cx_set run.
# Sourced, so it sets no shell option; its names start with bd_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # the cx_ locations are set by cx_set in context.sh

# What a docs folder may hold together: what an agent reads in a few calls.
bd_docs_max_bytes=1048576

# Prints the docs folder's file names, sorted, one per line.
bd_docs_names() {
	[ -d "${cx_docs}" ] || return 0
	for bd_file in "${cx_docs}"/* "${cx_docs}"/.[!.]*; do
		[ -e "${bd_file}" ] || [ -L "${bd_file}" ] || continue
		printf '%s\n' "${bd_file##*/}"
	done | LC_ALL=C sort
}

# Prints the first problem of the docs folder, led by its token (DOCS-NAME or
# DOCS-SIZE), or nothing.
bd_docs_problem() {
	bd_total=0
	for bd_name in $(bd_docs_names); do
		bd_file="${cx_docs}/${bd_name}"
		if [ -L "${bd_file}" ] || [ ! -f "${bd_file}" ]; then
			echo "DOCS-NAME: ${bd_name} is not a regular file"; return 0
		fi
		printf '%s' "${bd_name}" | grep -Eq '^(spec\.md|[A-Za-z0-9][A-Za-z0-9._-]*\.md|diff-[0-9a-f]{7,40}(\.\.[0-9a-f]{7,40})?\.patch)$' \
			|| { echo "DOCS-NAME: ${bd_name} may not be in a docs folder; expected spec.md, <name>.md or diff-<sha>.patch"; return 0; }
		bd_rule=$(pr_problem "${bd_file}")
		[ -z "${bd_rule}" ] || { echo "DOCS-NAME: ${bd_name} ${bd_rule}"; return 0; }
		bd_total=$((bd_total + $(wc -c <"${bd_file}")))
	done
	[ "${bd_total}" -le "${bd_docs_max_bytes}" ] \
		|| echo "DOCS-SIZE: the docs files hold ${bd_total} bytes; expected at most ${bd_docs_max_bytes}"
}

# Prints the digest of docs folder $1: the sha256 of its "<sha256>  <name>"
# lines, sorted by name.
bd_digest() {
	bd_list=$(mktemp)
	for bd_name in $(cx_docs="$1" bd_docs_names); do
		printf '%s  %s\n' "$(sh_sha256 "$1/${bd_name}")" "${bd_name}"
	done >"${bd_list}"
	sh_sha256 "${bd_list}"
	rm -f -- "${bd_list}"
}

# Prints the would-be version's body as one JSON object: the latest version's
# own body when nothing is new. Refuses (exit 2) with
# CONTEXT-NONE when there is nothing at all, NO-SPEC without a spec, or the
# docs folder's own problem.
bd_build() {
	bd_latest=$(cx_latest)
	bd_problem=$(bd_docs_problem)
	[ -z "${bd_problem}" ] || cx_refuse "${bd_problem}"
	bd_names=$(bd_docs_names)
	bd_prev='{"version": 0, "paths": [], "links": []}'
	[ -z "${bd_latest}" ] || bd_prev=$(jq -c '.body' "${bd_latest}")
	bd_pending='{"paths": [], "links": [], "retire": []}'
	[ ! -f "${cx_entries}" ] || bd_pending=$(cat -- "${cx_entries}")
	bd_docs_entry='null'
	if [ -n "${bd_names}" ]; then
		bd_next=$(($(printf '%s' "${bd_prev}" | jq '.version') + 1))
		bd_docs_entry=$(jq -cn --arg path "${cx_dir}/v${bd_next}" --arg sha "$(bd_digest "${cx_docs}")" \
			--argjson spec "$(printf '%s\n' "${bd_names}" | grep -qx 'spec.md' && echo true || echo false)" \
			'{path: $path, sha256: $sha, spec: $spec}')
	fi
	# shellcheck disable=SC2016 # the $ names are jq's
	bd_body=$(jq -cn --argjson prev "${bd_prev}" --argjson pending "${bd_pending}" --argjson docs "${bd_docs_entry}" '
		($pending.retire // [] | map(.path // .url)) as $gone
		| (($pending.paths // [] | length) + ($pending.links // [] | length) + ($pending.retire // [] | length)) as $changes
		| if $docs == null and $changes == 0 then {new: false, body: $prev}
		  else {new: true, body: {
			version: ($prev.version + 1),
			paths: ([$prev.paths[] | select(.path as $p | $gone | index([$p]) | not)]
				+ [$pending.paths[]?] + (if $docs then [{path: $docs.path, sha256: $docs.sha256}] else [] end)),
			links: ([$prev.links[]? | select(.url as $u | $gone | index([$u]) | not)] + [$pending.links[]?]),
			spec: (if $docs and $docs.spec then "\($docs.path)/spec.md" else $prev.spec end)}
			| if .links == [] then del(.links) else . end}
		  end')
	if [ "$(printf '%s' "${bd_body}" | jq -r '.new')" = false ] && [ -z "${bd_latest}" ]; then
		cx_refuse 'CONTEXT-NONE: nothing to cut: the docs folder is empty and nothing is pending'
	fi
	printf '%s' "${bd_body}" | jq -e '.body.spec | type == "string"' >/dev/null \
		|| cx_refuse 'NO-SPEC: no docs folder holds a spec.md; approve the spec first'
	# The spec must be the one the human approved: the newest spec.approved.
	bd_spec="${cx_docs}/spec.md"
	[ -f "${bd_spec}" ] || bd_spec=$(printf '%s' "${bd_body}" | jq -r '.body.spec')
	bd_approved=$(sh "${cx_reader}" --effort "${cx_effort}" --type spec.approved --paths | tail -n 1)
	[ -n "${bd_approved}" ] && [ "$(sh_sha256 "${bd_spec}")" = "$(jq -r '.body.sha256' "${bd_approved}")" ] \
		|| cx_refuse 'NOT-APPROVED: spec.md is not the spec the human approved last; approve it with crucible-spec'
	printf '%s' "${bd_body}" | jq -c '.body'
}

# Prints the fingerprint of body JSON $1: the sha256 of its jq -cS form.
bd_fingerprint() {
	bd_tmp=$(mktemp)
	printf '%s' "$1" | jq -cS . >"${bd_tmp}"
	sh_sha256 "${bd_tmp}"
	rm -f -- "${bd_tmp}"
}
