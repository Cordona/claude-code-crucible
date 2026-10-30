# shellcheck shell=sh
# The files of the named plugins, in load order, for an agent role, the one
# definition generate-agent-dispatch.sh resolves a dispatch's plugins with.
# Sourced, so it sets no shell option; its variables and functions start with
# plugin_ or name it.

# Reads list-plugins.sh's lines on stdin and the requested names as operands;
# prints the plugin file paths one per line in load order (want=paths), or the
# LABELS line (want=labels); or one stderr line per name problem (a name given
# twice or not installed) and exit 3. Load order is the language plugin, then
# the framework plugins, then the standard plugins, then the procedure
# plugins, each kind in plugin-line order, which list-plugins.sh keeps in name
# order. The LABELS line is "LABELS: Language: <label> · Frameworks: <labels>
# · Standards: <labels> · Procedures: <labels>", a kind with no loaded plugin
# left out ("LABELS:" alone when none is loaded); each list is in plugin-line
# order, joined by ", ". The plugin rules (at most one language, frameworks
# with a language, standard-testing by mode) are the plan validator's, checked
# before this runs. A plugin line is <kind> <name> <label> <description>
# <paths...>, so the paths start at field 5. The names are taken out of ARGV,
# each operand split on whitespace, so awk reads stdin.
# The program is single-quoted on purpose: its $ signs are awk's.
# shellcheck disable=SC2016,SC2034 # read by select_plugin_lines below
plugin_select_awk='
function shown(name) { gsub(/[[:cntrl:]]/, "?", name); return name }
function problem(text) { printf "%s: %s\n", prog, text > "/dev/stderr"; failed = 1 }
function add_label(list, label) { return list (list == "" ? "" : ", ") shown(label) }
function add_part(parts, title, labels) { return labels == "" ? parts : parts (parts == "" ? "" : " \302\267 ") title ": " labels }
function request(name) {
	if (name in requested) {
		if (!(name in reported_twice)) problem("name " shown(name) " given twice; expected each plugin once; drop the repeat")
		reported_twice[name] = 1
		return
	}
	requested[name] = 1
	order[++count] = name
}
BEGIN {
	FS = "\t"
	for (i = 1; i < ARGC; i++) {
		pieces = split(ARGV[i], piece, /[ \t\n]+/)
		delete ARGV[i]
		for (j = 1; j <= pieces; j++)
			if (piece[j] != "") request(piece[j])
	}
}
!($2 in requested) || !($1 ~ /^(language|framework|standard|procedure)$/) { next }
{
	installed[$2] = 1
	for (i = 5; i <= NF; i++) paths[$1] = paths[$1] $i "\n"
	labels[$1] = add_label(labels[$1], $3)
}
END {
	for (i = 1; i <= count; i++)
		if (!(order[i] in installed))
			problem("name " shown(order[i]) " is not an installed plugin; expected a <NAME> that list-plugins.sh prints, such as language-shell or standard-security; run list-plugins.sh --max-lines 0 to see them")
	if (failed) exit 3
	if (want == "labels") {
		parts = add_part("", "Language", labels["language"])
		parts = add_part(parts, "Frameworks", labels["framework"])
		parts = add_part(parts, "Standards", labels["standard"])
		parts = add_part(parts, "Procedures", labels["procedure"])
		print "LABELS:" (parts == "" ? "" : " " parts)
		exit 0
	}
	printf "%s%s%s%s", paths["language"], paths["framework"], paths["standard"], paths["procedure"]
}
'

# Prints plugin_select_awk's output for want $1 (paths or labels) and problem
# prefix $2 over list-plugins.sh's lines $3, for the names after them; returns
# awk's status, 3 for a name problem (one stderr line each).
select_plugin_lines() {
	plugin_want=$1
	plugin_prog=$2
	plugin_listing=$3
	shift 3
	printf '%s' "${plugin_listing}" |
		awk -v prog="${plugin_prog}" -v want="${plugin_want}" "${plugin_select_awk}" "$@"
}

# Sets plugin_paths to the files role $1 (developer or reviewer) loads from the
# selected paths $2, one per line: for reviewer each references/development.md
# becomes references/review.md, dropped when that is not a readable file; for
# developer each references/development.md is followed by every readable
# references/*-template.md file of that plugin, in the glob's byte order under
# the C locale. Returns 3 with plugin_problem set when a template name holds a
# comma or control character.
resolve_role_paths() {
	plugin_paths=''
	plugin_problem=''
	while IFS= read -r plugin_path; do
		[ -n "${plugin_path}" ] || continue
		case $1:${plugin_path} in
			reviewer:*/references/development.md)
				plugin_path="${plugin_path%development.md}review.md"
				[ -f "${plugin_path}" ] && [ -r "${plugin_path}" ] || continue
				add_plugin_path "${plugin_path}"
				;;
			developer:*/references/development.md)
				add_plugin_path "${plugin_path}"
				# shellcheck disable=SC2310 # its status is the template check; the caller acts on it
				add_plugin_templates "${plugin_path%development.md}" || return 3
				;;
			*) add_plugin_path "${plugin_path}" ;;
		esac
	done <<EOF
$2
EOF
}

add_plugin_path() {
	plugin_paths="${plugin_paths}${plugin_paths:+
}$1"
}

# Adds every readable *-template.md file in the references folder $1 (it ends
# in "/"); fails with plugin_problem set on a file name holding a comma or
# control character.
add_plugin_templates() {
	for plugin_template in "$1"*-template.md; do
		[ -f "${plugin_template}" ] && [ -r "${plugin_template}" ] || continue
		case ${plugin_template} in
			*,* | *[[:cntrl:]]*)
				plugin_problem="template file name holds a comma or control character: ${plugin_template}; expected a name with no comma or control character; rename the file and reinstall the plugin"
				return 1
				;;
			*) add_plugin_path "${plugin_template}" ;;
		esac
	done
}
