# The step catalogue, read from every flow-step.json beside this component: the
# one reader, used by flow-candidates.sh, flow-card.sh, flow-agree.sh and
# flow-change.sh. Sourced after flow.sh, so it sets no shell option; its
# names start with ct_.
# shellcheck shell=sh
# shellcheck disable=SC2154 # fl_here and fl_lib are set by flow.sh

. "${fl_here}/../../crucible-events/scripts/lib/beside.sh"
. "${fl_here}/../../crucible-events/scripts/lib/listing.sh"

# Prints the catalogue as one JSON object, {entries, rejected}, as
# catalogue.jq's catalogue sets. Every flow script sits in scripts/.
ct_catalogue() {
	ct_components=$(bs_components "$0" 1) || fl_refuse 'the components folder beside crucible-dynamic-flow is not there'
	ct_files=$(mktemp)
	ct_rules=$(mktemp)
	# Each flow-step.json as {component, file, entries}, or invalid when not JSON.
	for ct_file in "${ct_components}"/*/flow-step.json; do
		[ -f "${ct_file}" ] || continue
		ct_component=${ct_file%/flow-step.json}
		ct_component=${ct_component##*/}
		if jq -e . "${ct_file}" >/dev/null 2>&1; then
			jq -c --arg c "${ct_component}" --arg f "${ct_file}" '{component: $c, file: $f, entries: .}' "${ct_file}"
		else
			jq -cn --arg c "${ct_component}" --arg f "${ct_file}" '{component: $c, file: $f, invalid: true}'
		fi
	done | jq -s . >"${ct_files}"
	# The number of rule files for each event type a step names.
	jq -r '.[].entries? | arrays | .[] | objects | .ends_with? | objects | .event? | strings' "${ct_files}" \
		| LC_ALL=C sort -u | while IFS= read -r ct_type; do
			ls_is_type "${ct_type}" || continue
			ct_count=0
			for ct_rule in "${ct_components}"/*/events/"${ct_type}.jq"; do
				[ -f "${ct_rule}" ] && ct_count=$((ct_count + 1))
			done
			jq -cn --arg t "${ct_type}" --argjson n "${ct_count}" '{($t): $n}'
		done | jq -s 'add // {}' >"${ct_rules}"
	ct_rc=0
	# The installed skills: the components beside that hold a SKILL.md.
	ct_skills=$(for ct_skill in "${ct_components}"/*/SKILL.md; do
		[ -f "${ct_skill}" ] || continue
		ct_skill=${ct_skill%/SKILL.md}
		printf '%s\n' "${ct_skill##*/}"
	done | jq -Rsc 'split("\n") | map(select(. != ""))')
	jq -c -L "${fl_lib}" --slurpfile rules "${ct_rules}" --argjson skills "${ct_skills}" \
		'include "catalogue"; catalogue($rules[0]; $skills)' "${ct_files}" || ct_rc=$?
	rm -f -- "${ct_files}" "${ct_rules}"
	return "${ct_rc}"
}

# Resolves flow steps against catalogue $1 (JSON): reads a JSON array of
# {id, step} on stdin, prints {steps: [{id, step, does, skills, ends_with}],
# problems: [<line>]}.
ct_resolve() {
	jq -c --argjson cat "$1" '
		($cat.entries | map({key: .key, value: .}) | from_entries) as $by
		| ($cat.rejected | map(select(.key)) | group_by(.key) | map({key: .[0].key, value: (map(.problem) | join("; "))}) | from_entries) as $why
		| {steps: [.[] | . as $s | $by[$s.step] | select(. != null)
			| {id: $s.id, step: $s.step, does: .does, skills: .skills, ends_with: .ends_with}],
		   problems: [.[] | . as $s | select($by[$s.step] == null)
			| if $why[$s.step] then "step \($s.id): \($s.step) was left out of the catalogue: \($why[$s.step])"
			  else "step \($s.id): \($s.step) is not a declared step; run flow-candidates.sh to see them" end]}'
}
