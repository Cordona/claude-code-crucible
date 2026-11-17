# The build seat's title as the build card shows it, for the gates whose plan
# file holds no title: "<language> build agent[ with <frameworks>]", its
# plugins the language and frameworks of the dispatch.made event that the
# seat's newest build.committed names, each by its metadata.label; "Generic
# build agent" when there is no such dispatch. Sourced, so it sets no shell
# option; its names start with st_. The sourcing script defines
# install_fault (prints the install: line, exits 5) and refuse_problems
# (prints each problem line, exits 3 on any), and sets st_skills_dir.
# shellcheck shell=sh
# shellcheck disable=SC2034 # its st_title is read by the sourcing scripts
# shellcheck disable=SC2154 # st_skills_dir is the sourcing script's

readonly ST_EVENTS='crucible/scripts/events.sh'
readonly ST_TITLE_LIB='human-view'
readonly ST_BUILD_TYPE='build.committed'
readonly ST_DISPATCH_TYPE='dispatch.made'
readonly ST_NEWLINE='
'

# The language's plugin name, then each framework's, one per line, of the
# dispatch with id $id. Input: the dispatch.made events.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly ST_PLUGINS_JQ='map(select(.body.id == $id)) | last // empty
| .body.plugins // {} | (.language.name // ""), (.frameworks // [] | .[] | .name // empty)'

# The title from the labels, one per line, the language's first. Input: none.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $ signs are jq's
readonly ST_TITLE_JQ='include "title";
($labels | split("\n")) as $names
| {language: $names[0], frameworks: ($names[1:] | map(select(. != "")))} | title($role)'

# Prints a plugin SKILL.md's metadata.label by flow-code-agent-dispatch's
# list-plugins.sh rules, as the build card reads it: the frontmatter opens
# on line 1 and is closed by ---; a "  label:" line under a "metadata:" line
# (a trailing comment allowed), the last one counting; a ` # comment` after
# an unquoted value dropped, one pair of quotes removed and tabs made
# spaces. Prints nothing when the frontmatter is not closed.
# shellcheck disable=SC2016 # the program is single-quoted on purpose: its $0 is awk's
readonly ST_PLUGIN_LABEL_AWK='
function clean(value) {
	sub(/^[ \t]+/, "", value)
	if (value !~ /^["\047]/) sub(/[ \t]+#.*$/, "", value)
	sub(/[ \t]+$/, "", value)
	if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) value = substr(value, 2, length(value) - 2)
	sub(/^[ \t]+/, "", value)
	sub(/[ \t]+$/, "", value)
	gsub(/\t/, " ", value)
	return value
}
{ sub(/\r$/, "") }
NR == 1 { if ($0 != "---") exit; next }
$0 == "---" { closed = 1; exit }
/^[^ \t#]/ { in_metadata = ($0 ~ /^metadata:[ \t]*(#.*)?$/); next }
in_metadata && /^  label:/ { label = clean(substr($0, index($0, ":") + 1)) }
END { if (closed) print label }
'

# Sets st_title to the title of build seat $2 of effort folder $1, the role
# word $3 in it; exits 3 when events.sh refuses the effort or the seat has
# no build.committed, 5 when a tool is missing or fails. $2 is a seat name
# by seats.jq, so it is safe in a jq string.
st_derive_title() {
	st_effort=$1
	st_events_script="${st_skills_dir}/${ST_EVENTS}"
	[ -f "${st_events_script}" ] && [ -r "${st_events_script}" ] ||
		install_fault "events.sh missing; expected ${st_events_script}; install the ${ST_EVENTS%%/*} skill"
	st_events latest --type "${ST_BUILD_TYPE}" --where ".seat == \"$2\""
	[ -n "${st_events_out}" ] ||
		refuse_problems "seat $2 has no ${ST_BUILD_TYPE} event in ${st_effort}; expected the build its card showed, or the plan file's title"
	st_dispatch=$(jq -r '.dispatch // "" | tostring' "${st_events_out}" </dev/null) ||
		install_fault "jq could not read the event ${st_events_out}; expected the JSON events.sh wrote"
	st_read_labels
	st_title=$(jq -nr -L "${st_skills_dir}/${ST_TITLE_LIB}" --arg labels "${st_labels}" --arg role "$3" "${ST_TITLE_JQ}") ||
		install_fault 'jq failed building the title; expected jq 1.6+ and human-view'\''s title.jq'
}

# Sets st_events_out to events.sh's stdout for the arguments, on effort
# st_effort; its refusal of the effort is an input problem.
st_events() {
	st_events_rc=0
	st_command=$1
	shift
	st_events_out=$(sh "${st_events_script}" "${st_command}" --effort "${st_effort}" "$@" </dev/null) || st_events_rc=$?
	case ${st_events_rc} in
		0) ;;
		2 | 3) refuse_problems "events.sh refused --effort (exit ${st_events_rc}, its stderr is above); expected the effort folder, absolute" ;;
		*) install_fault "events.sh ${st_command} failed (exit ${st_events_rc}, its stderr is above)" ;;
	esac
}

# Sets st_labels: the language's label, then each framework's, one per
# line, of dispatch st_dispatch; none without its dispatch.made event.
st_read_labels() {
	st_labels=''
	[ -n "${st_dispatch}" ] || return 0
	st_events slurp --type "${ST_DISPATCH_TYPE}"
	st_names=$(printf '%s\n' "${st_events_out}" | jq -r --arg id "${st_dispatch}" "${ST_PLUGINS_JQ}") ||
		install_fault 'jq could not read the dispatch.made events events.sh slurp printed'
	[ -n "${st_names}" ] || return 0
	st_first=yes
	while IFS= read -r st_name; do
		st_label=$(st_plugin_label "${st_name}")
		if [ "${st_first}" = yes ]; then
			st_labels=${st_label} st_first=no
		else
			st_labels="${st_labels}${ST_NEWLINE}${st_label}"
		fi
	done <<EOF
${st_names}
EOF
}

# Prints plugin $1's metadata.label, or $1 when it is not installed or has
# none; a name that is no skill name is never looked up as a path.
st_plugin_label() {
	st_found=''
	case $1 in
		'' | *[!a-z0-9-]* | -* | *-) ;;
		*)
			st_skill_file="${st_skills_dir}/$1/SKILL.md"
			[ ! -f "${st_skill_file}" ] || st_found=$(awk "${ST_PLUGIN_LABEL_AWK}" "${st_skill_file}" 2>/dev/null) || st_found=''
			;;
	esac
	printf '%s' "${st_found:-$1}" | tr '[:cntrl:]' ' '
}
